import Foundation

// The find/replace engine behind the file viewer's ⌘F bar, factored out of the
// Cocoa pane so it can be unit-tested standalone (the FileEdit / RoadmapParser /
// Recipes pattern — Foundation-only, no app or UI dependencies).
//
// This owns every decision the find bar renders: which ranges match, which match
// is "current" as you step through them, and what text a replacement produces.
// The Cocoa half (FileViewerPane+Find) owns the NSTextView, the widget chrome and
// the highlight attributes; it asks this for answers and never re-derives them.
//
// Ranges are NSRange (UTF-16 offsets) throughout, because that is the coordinate
// system NSTextStorage, the syntax highlighter and `lineStarts` already speak —
// converting to String.Index at this boundary would only mean converting back.

// One find bar's search settings. Mirrors the three VS Code toggles (Aa / ab| /
// .*) plus the query text itself.
struct FindQuery: Equatable {
    var text: String = ""
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
    var regex: Bool = false

    init(text: String = "", caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }

    // An empty query matches nothing (rather than everything); the bar shows "No
    // results" and the highlight layer stays clear.
    var isEmpty: Bool { text.isEmpty }
}

enum FindReplace {
    // MARK: - Matching

    // Every non-overlapping match of `query` in `text`, in document order.
    //
    // Empty queries and malformed regexes yield no matches — an in-progress regex
    // like "foo(" is a normal intermediate state while typing, not an error worth
    // surfacing as a failure; `isValid` is what the bar uses to tint the field.
    static func matchRanges(in text: String, query: FindQuery) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        let found = query.regex
            ? regexMatchRanges(in: ns, query: query)
            : literalMatchRanges(in: ns, query: query)
        guard query.wholeWord else { return found }
        return found.filter { isWholeWord($0, in: ns) }
    }

    // Whether the query compiles. Only meaningful in regex mode: a literal query
    // is always valid, so the bar only ever tints the field red for a bad pattern.
    static func isValid(_ query: FindQuery) -> Bool {
        guard query.regex, !query.isEmpty else { return true }
        return makeRegex(query) != nil
    }

    private static func literalMatchRanges(in ns: NSString, query: FindQuery) -> [NSRange] {
        var options: NSString.CompareOptions = [.literal]
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        let needle = query.text as NSString
        var ranges: [NSRange] = []
        var start = 0
        while start < ns.length {
            let searchRange = NSRange(location: start, length: ns.length - start)
            let found = ns.range(of: needle as String, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            // A literal match is never empty, but guard anyway: a zero-length step
            // would spin here forever.
            start = found.location + max(found.length, 1)
        }
        return ranges
    }

    private static func regexMatchRanges(in ns: NSString, query: FindQuery) -> [NSRange] {
        guard let regex = makeRegex(query) else { return [] }
        let full = NSRange(location: 0, length: ns.length)
        // NSRegularExpression already skips overlaps and advances past zero-length
        // matches (a pattern like "^" or "a*"), so this can't loop.
        return regex.matches(in: ns as String, options: [], range: full).map(\.range)
    }

    private static func makeRegex(_ query: FindQuery) -> NSRegularExpression? {
        var options: NSRegularExpression.Options = []
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: query.text, options: options)
    }

    // MARK: - Whole-word filtering

    // Whole-word is applied by filtering matches on their neighbours rather than by
    // wrapping the pattern in \b. \b is defined against the *pattern's* edges, so
    // "\bfoo(\b" never matches "foo(" — the boundary after "(" wants a word
    // character and finds none. Checking the characters either side of the match
    // instead behaves the way a user expects for any query, symbols included.
    private static func isWholeWord(_ range: NSRange, in ns: NSString) -> Bool {
        !isWordCharacter(ns, at: range.location - 1)
            && !isWordCharacter(ns, at: range.location + range.length)
    }

    private static func isWordCharacter(_ ns: NSString, at index: Int) -> Bool {
        guard index >= 0, index < ns.length else { return false }
        // Step out to the full composed character: `index` may land on half of a
        // surrogate pair when the neighbouring character is non-BMP (an emoji).
        let composed = ns.rangeOfComposedCharacterSequence(at: index)
        guard let scalar = ns.substring(with: composed).unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    // MARK: - Stepping between matches

    // Which match to make current when the bar opens or the query changes: the
    // first one at or after the caret, wrapping to the top when the caret sits
    // past the last match. Nil only when there are no matches at all.
    //
    // This is why ⌘F from the middle of a file selects the match *below* you
    // rather than jumping back to line 1.
    static func initialIndex(for ranges: [NSRange], caret: Int) -> Int? {
        guard !ranges.isEmpty else { return nil }
        return ranges.firstIndex { $0.location >= caret } ?? 0
    }

    // Step to the next/previous match, wrapping at both ends (⌘G past the last
    // match returns to the first). Returns nil when there is nothing to step to.
    static func step(from index: Int, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        let delta = forward ? 1 : -1
        return ((index + delta) % count + count) % count
    }

    // MARK: - Replacing

    // The text one match expands to.
    //
    // In regex mode the template is a real template: "$1" and friends interpolate
    // capture groups, matching VS Code. In literal mode the template is inserted
    // verbatim — a replacement of "$1" means the characters "$1", which is what
    // someone typing into a non-regex field means by it.
    static func replacementText(in text: String, matchRange: NSRange, query: FindQuery, template: String) -> String {
        guard query.regex, let regex = makeRegex(query) else { return template }
        // Re-match, anchored to this range, to recover the capture groups. Cheaper
        // and simpler than threading NSTextCheckingResults up through the UI, and
        // the range came from this same regex so the match is guaranteed.
        guard let match = regex.firstMatch(in: text, options: [.anchored], range: matchRange) else {
            return template
        }
        return regex.replacementString(for: match, in: text, offset: 0, template: template)
    }

    // Every match replaced in one pass, plus how many there were (the bar reports
    // "Replaced 12 occurrences"). Returns the original text unchanged when nothing
    // matches, so the caller can skip dirtying the buffer.
    //
    // Built forward into a new string rather than by mutating in place: each
    // replacement shifts every later range, and rebuilding sidesteps the offset
    // bookkeeping that shifting invites bugs into.
    static func replaceAll(in text: String, query: FindQuery, template: String) -> (text: String, count: Int) {
        let ranges = matchRanges(in: text, query: query)
        guard !ranges.isEmpty else { return (text, 0) }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for range in ranges {
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            result += replacementText(in: text, matchRange: range, query: query, template: template)
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        return (result, ranges.count)
    }
}
