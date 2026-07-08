import Foundation

// Standalone logic test for the Phase 33 symbol-index core. Compiled with only
// swift/Sources/suit/SymbolIndexCore.swift (Foundation-only, no app deps), the
// RoadmapParser/FeedbackRouting pattern. Exercises the pure ctags-tag parser,
// the identifier-under-caret extraction, the definition lookup and the
// reference regex against fixtures with known answers — and, when a universal
// ctags is present, an end-to-end pass over a real Swift/Go fixture asserting
// go-to-def lands on the right file:line for single- and multi-definition
// symbols. Prints PASS/FAIL/SKIP and exits non-zero on any failure.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// MARK: - Tag line parsing

do {
    // Classic universal-ctags line with --fields=+n: name, file, exCmd;", kind, line:N.
    let line = "User\tsrc/User.swift\t/^struct User {$/;\"\ts\tline:12"
    let def = SymbolIndexCore.parseTagLine(line)
    check("tagLine: name", def?.name == "User")
    check("tagLine: path", def?.relativePath == "src/User.swift")
    check("tagLine: line", def?.lineNumber == 12)
    check("tagLine: kind", def?.kind == "s")

    // Full-word kind field variant (`kind:function`).
    let line2 = "greet\tmain.go\t/^func greet() {$/;\"\tkind:function\tline:4"
    let def2 = SymbolIndexCore.parseTagLine(line2)
    check("tagLine: kind:full", def2?.kind == "function" && def2?.lineNumber == 4)

    // Bare-number exCmd fallback (--excmd=number, no line: field).
    let line3 = "Server\tsrv.go\t7;\"\tt"
    let def3 = SymbolIndexCore.parseTagLine(line3)
    check("tagLine: bare-number exCmd → line", def3?.lineNumber == 7 && def3?.kind == "t")

    check("tagLine: pseudo-tag skipped", SymbolIndexCore.parseTagLine("!_TAG_FILE_FORMAT\t2\t/x/") == nil)
    check("tagLine: too few columns → nil", SymbolIndexCore.parseTagLine("lonely") == nil)
    check("tagLine: no line info → nil", SymbolIndexCore.parseTagLine("x\ty.swift\t/^x$/;\"\tv") == nil)
}

// MARK: - parseTags grouping + dedupe

do {
    let output = """
    !_TAG_FILE_FORMAT\t2\t/x/
    greet\ta.swift\t/^func greet$/;"\tf\tline:3
    greet\tb.go\t/^func greet$/;"\tf\tline:9
    greet\ta.swift\t/^func greet$/;"\tf\tline:3
    User\ta.swift\t/^struct User$/;"\ts\tline:1
    """
    let byName = SymbolIndexCore.parseTags(output)
    check("parseTags: two names", Set(byName.keys) == ["greet", "User"])
    check("parseTags: greet deduped to 2", byName["greet"]?.count == 2)
    // Sorted by (path, line): a.swift:3 before b.go:9.
    check("parseTags: greet sorted", byName["greet"]?.first?.relativePath == "a.swift"
        && byName["greet"]?.first?.lineNumber == 3)
    check("parseTags: User single", byName["User"]?.count == 1 && byName["User"]?.first?.lineNumber == 1)
}

// MARK: - Identifier under the caret

do {
    let line = "    let userName = fetchUser(id)"
    // Offsets: "    let userName..." — 'u' of userName at index 8.
    check("identifier: mid-word", SymbolIndexCore.identifier(in: line, atUTF16Offset: 10) == "userName")
    check("identifier: word start", SymbolIndexCore.identifier(in: line, atUTF16Offset: 8) == "userName")
    // Trailing edge (offset just past the last char of userName) resolves via the char before.
    let end = ("    let userName" as NSString).length
    check("identifier: trailing edge", SymbolIndexCore.identifier(in: line, atUTF16Offset: end) == "userName")
    // Trailing edge resolves via the char-before rule, so a true "no identifier"
    // needs non-identifier chars on both sides (a gap between two spaces).
    check("identifier: in a gap → nil", SymbolIndexCore.identifier(in: "a  b", atUTF16Offset: 2) == nil)
    check("identifier: keyword still a word", SymbolIndexCore.identifier(in: line, atUTF16Offset: 5) == "let")
    check("identifier: fetchUser", SymbolIndexCore.identifier(in: line, atUTF16Offset: 20) == "fetchUser")
    check("identifier: pure number → nil", SymbolIndexCore.identifier(in: "x = 12345", atUTF16Offset: 6) == nil)
    check("identifier: underscore/digits", SymbolIndexCore.identifier(in: "foo_bar2 = 1", atUTF16Offset: 2) == "foo_bar2")
    check("identifier: empty line → nil", SymbolIndexCore.identifier(in: "", atUTF16Offset: 0) == nil)
    check("identifier: out of range → nil", SymbolIndexCore.identifier(in: "ab", atUTF16Offset: 9) == nil)
}

// MARK: - Lookup + reference regex

do {
    let byName = SymbolIndexCore.parseTags("""
    greet\ta.swift\t/^x$/;"\tf\tline:3
    greet\tb.go\t/^x$/;"\tf\tline:9
    User\ta.swift\t/^x$/;"\ts\tline:1
    """)
    check("lookup: single def", SymbolIndexCore.definitions(named: "User", in: byName).count == 1)
    check("lookup: multi def", SymbolIndexCore.definitions(named: "greet", in: byName).count == 2)
    check("lookup: unknown → empty", SymbolIndexCore.definitions(named: "Nope", in: byName).isEmpty)

    check("refRegex: word-bounded", SymbolIndexCore.referenceRegex(for: "User") == "\\bUser\\b")
    check("refRegex: escapes metachars", SymbolIndexCore.referenceRegex(for: "a.b") == "\\ba\\.b\\b")
}

// MARK: - End-to-end over a real universal-ctags (skipped when absent)

func findCtags() -> String? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["SUIT_CTAGS_PATH"], fm.isExecutableFile(atPath: env) {
        return env
    }
    for candidate in ["/opt/homebrew/bin/ctags", "/usr/local/bin/ctags"] where fm.isExecutableFile(atPath: candidate) {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: candidate)
        probe.arguments = ["--version"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { continue }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        probe.waitUntilExit()
        if String(decoding: data, as: UTF8.self).contains("Universal Ctags") { return candidate }
    }
    return nil
}

if let ctags = findCtags() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("suit-symbol-fixture-\(getpid())")
    try? fm.createDirectory(at: dir.appendingPathComponent("swift"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: dir.appendingPathComponent("go"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    // swift/User.swift: `User` at line 1, `greet` at line 5 (first definition).
    let swiftSource = """
    struct User {
        let name: String
    }

    func greet(_ user: User) {}
    """
    // go/user.go: `Server` at line 3, `greet` at line 5 (second definition).
    let goSource = """
    package main

    type Server struct{}

    func greet() {}
    """
    try? swiftSource.write(to: dir.appendingPathComponent("swift/User.swift"), atomically: true, encoding: .utf8)
    try? goSource.write(to: dir.appendingPathComponent("go/user.go"), atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ctags)
    process.arguments = ["-f", "-", "--fields=+n", "--sort=no", "-L", "-"]
    process.currentDirectoryURL = dir
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()
    try? process.run()
    stdin.fileHandleForWriting.write(Data("swift/User.swift\ngo/user.go\n".utf8))
    try? stdin.fileHandleForWriting.close()
    let out = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    let byName = SymbolIndexCore.parseTags(String(decoding: out, as: UTF8.self))

    let user = SymbolIndexCore.definitions(named: "User", in: byName)
    check("e2e: User single def", user.count == 1)
    check("e2e: User at swift/User.swift:1", user.first?.relativePath == "swift/User.swift" && user.first?.lineNumber == 1)

    let server = SymbolIndexCore.definitions(named: "Server", in: byName)
    check("e2e: Server at go/user.go:3", server.first?.relativePath == "go/user.go" && server.first?.lineNumber == 3)

    let greet = SymbolIndexCore.definitions(named: "greet", in: byName)
    check("e2e: greet multi def (2)", greet.count == 2)
    check("e2e: greet spans both files", Set(greet.map { $0.relativePath }) == ["swift/User.swift", "go/user.go"])
    check("e2e: greet grouped/sorted by path", greet.first?.relativePath == "go/user.go")
} else {
    print("SKIP: universal-ctags not found — end-to-end ctags assertions skipped (set SUIT_CTAGS_PATH)")
}

print(failures == 0 ? "\nAll symbol-index assertions passed." : "\n\(failures) assertion(s) FAILED.")
exit(failures == 0 ? 0 : 1)
