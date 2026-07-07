import Foundation

// Autopilot budget math (ROADMAP Phase 32), separate from the engine so it is
// pure and tested standalone: given a usage snapshot, the configured budget
// mode and "now", decide whether a new run may start. Budget gates *starting*
// only — an in-flight run always finishes.

// The user-switchable budget modes (Settings ▸ Autopilot; persisted as the
// rawValue under the `autopilotMode` defaults key).
enum AutopilotBudgetMode: String, CaseIterable, Codable {
    case paceToReset = "pace"   // spread the weekly budget evenly across the window
    case maxOut = "max"         // run whenever under the ceilings
    case nightShift = "night"   // maxOut, but only inside the configured night hours

    var displayName: String {
        switch self {
        case .paceToReset: return "Pace to reset"
        case .maxOut: return "Max out"
        case .nightShift: return "Night shift"
        }
    }
}

// The scheduler's view of ~/.suit/claude-status.json: raw percentages plus the
// parsed resets_at dates, *without* the UI's 30-min staleness gate — the
// scheduler's staleness policy is the resets_at rollover in `effectivePct`.
// Codable so the engine can mirror the last snapshot into state.json (a
// relaunch can still show "next run ~03:40"). The engine builds it from
// `ClaudeUsage` (`modelWeeklyMaxPct` = the largest `seven_day_<model>` value;
// the scheduler doesn't care which model binds, only the worst case).
struct UsageSnapshot: Codable, Equatable {
    var fiveHourPct: Double?
    var sevenDayPct: Double?
    var modelWeeklyMaxPct: Double?
    var fiveHourResetsAt: Date?
    var sevenDayResetsAt: Date?
    var capturedAt: Date

    init(fiveHourPct: Double? = nil, sevenDayPct: Double? = nil,
         modelWeeklyMaxPct: Double? = nil,
         fiveHourResetsAt: Date? = nil, sevenDayResetsAt: Date? = nil,
         capturedAt: Date = Date()) {
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
        self.modelWeeklyMaxPct = modelWeeklyMaxPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
        self.capturedAt = capturedAt
    }
}

// The §2.10 tunables the math needs; the engine fills it from the AppDelegate
// settings, tests construct it directly. Percentages are 0–100.
struct AutopilotSchedulerConfig {
    var fiveHourCeiling: Double = 85    // hard gate, all modes
    var weeklyCeiling: Double = 95      // maxOut / nightShift soft ceiling
    var weeklyHardStop: Double = 98     // hard gate, all modes
    var paceTargetPct: Double = 100     // where the pace line ends at reset
    var nightStart: Int = 22            // hour, inclusive
    var nightEnd: Int = 7               // hour, exclusive; start > end wraps midnight
}

// `until` is the earliest moment the answer could flip (nil when unknown, e.g.
// no resets_at in the snapshot); `why` feeds the sidebar footer row verbatim.
enum AutopilotScheduleDecision: Equatable {
    case go
    case wait(until: Date?, why: String)
}

enum AutopilotScheduler {
    private static let weekLength: TimeInterval = 7 * 24 * 60 * 60

    // A percentage is only meaningful for the window it was captured in:
    // never measured → 0 (optimistic; the interactive worker refreshes the
    // snapshot within ~1 min of starting), window rolled over since capture
    // → 0, else the captured value.
    static func effectivePct(_ pct: Double?, resetsAt: Date?, now: Date) -> Double {
        guard let pct else { return 0 }
        if let resetsAt, now >= resetsAt { return 0 }
        return pct
    }

    static func mayStartRun(mode: AutopilotBudgetMode, snapshot: UsageSnapshot?,
                            now: Date, config: AutopilotSchedulerConfig) -> AutopilotScheduleDecision {
        // No snapshot at all = never measured: same optimism as a nil pct.
        let five = effectivePct(snapshot?.fiveHourPct, resetsAt: snapshot?.fiveHourResetsAt, now: now)
        // The model-scoped weekly shares the seven-day window, and can bind first.
        let week = max(
            effectivePct(snapshot?.sevenDayPct, resetsAt: snapshot?.sevenDayResetsAt, now: now),
            effectivePct(snapshot?.modelWeeklyMaxPct, resetsAt: snapshot?.sevenDayResetsAt, now: now)
        )

        // Hard gates, all modes.
        if week >= config.weeklyHardStop {
            return .wait(until: snapshot?.sevenDayResetsAt,
                         why: "weekly usage \(Int(week))% ≥ hard stop \(Int(config.weeklyHardStop))%")
        }
        if five >= config.fiveHourCeiling {
            return .wait(until: snapshot?.fiveHourResetsAt,
                         why: "5h usage \(Int(five))% ≥ ceiling \(Int(config.fiveHourCeiling))%")
        }

        switch mode {
        case .maxOut:
            return underWeeklyCeiling(week: week, snapshot: snapshot, config: config)

        case .paceToReset:
            // Pace needs to know where the week stands; without resets_at the
            // engine logs the fallback and this behaves as maxOut.
            guard let resetsAt = snapshot?.sevenDayResetsAt, config.paceTargetPct > 0 else {
                return underWeeklyCeiling(week: week, snapshot: snapshot, config: config)
            }
            let weekStart = resetsAt.addingTimeInterval(-weekLength)
            let elapsed = now.timeIntervalSince(weekStart)
            let allowed = min(max(elapsed / weekLength, 0), 1) * config.paceTargetPct
            if week < allowed { return .go }
            // The pace line crosses the current usage at week/target of the
            // window — that's when the answer flips (feeds "next run ~03:40").
            let eligible = weekStart.addingTimeInterval(week / config.paceTargetPct * weekLength)
            return .wait(until: min(eligible, resetsAt),
                         why: "pacing: weekly usage \(Int(week))% ahead of the \(Int(allowed))% pace line")

        case .nightShift:
            let hour = Calendar.current.component(.hour, from: now)
            guard inNightWindow(hour: hour, start: config.nightStart, end: config.nightEnd) else {
                return .wait(until: nextNightStart(after: now, startHour: config.nightStart),
                             why: "outside night window (\(config.nightStart)–\(config.nightEnd)h)")
            }
            return underWeeklyCeiling(week: week, snapshot: snapshot, config: config)
        }
    }

    // maxOut's core, shared by nightShift (inside the window) and pace's
    // no-resets_at fallback: go while under the weekly ceiling.
    private static func underWeeklyCeiling(week: Double, snapshot: UsageSnapshot?,
                                           config: AutopilotSchedulerConfig) -> AutopilotScheduleDecision {
        if week < config.weeklyCeiling { return .go }
        return .wait(until: snapshot?.sevenDayResetsAt,
                     why: "weekly usage \(Int(week))% ≥ ceiling \(Int(config.weeklyCeiling))%")
    }

    // [start, end) with midnight wrap (default 22→7). start == end would be an
    // empty window, which just disables Autopilot silently — read it as the
    // whole day instead.
    static func inNightWindow(hour: Int, start: Int, end: Int) -> Bool {
        if start == end { return true }
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }

    // The next moment the night window opens (today's start hour if still
    // ahead, otherwise tomorrow's).
    static func nextNightStart(after now: Date, startHour: Int) -> Date? {
        Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: startHour, minute: 0, second: 0),
            matchingPolicy: .nextTime
        )
    }
}
