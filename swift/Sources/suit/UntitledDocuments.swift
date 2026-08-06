import Foundation

// Naming for the ⌘N scratch buffers — documents that exist as an editable tab
// before they exist as a file.
//
// The rule is "lowest free index", not "one past the highest ever handed out".
// Open three, close Untitled-2, press ⌘N again and you get Untitled-2 back. The
// number is only there so two unsaved buffers can be told apart on a tab strip;
// it is not a serial number anyone is meant to remember. Reusing a freed slot is
// what keeps the strip readable — a window that has churned through a dozen
// scratch buffers still reads Untitled-1, Untitled-2 rather than Untitled-9,
// Untitled-13.
//
// Foundation-only and free of app types, so scripts/untitled-documents-test.sh
// can compile it on its own.
enum UntitledDocuments {

    // The stem every scratch name starts with. It labels only a buffer with no
    // file behind it: the moment one is saved it is called whatever the user
    // saved it as, and stops competing for a slot.
    static let namePrefix = "Untitled-"

    // The index encoded in a scratch name, or nil for anything else.
    //
    // The strictness is the point. Callers hand us *every* open tab title, so a
    // real file that happens to start with the prefix — Untitled-1.txt, the
    // saved-then-reopened Untitled-draft — must not reserve a scratch slot and
    // push the next ⌘N to a higher number. Only a bare prefix plus ASCII digits
    // with no leading zero counts, which keeps name → index a bijection: without
    // the zero rule both "Untitled-1" and "Untitled-01" would claim index 1 and
    // the freed-slot search could hand out a name that is already on the strip.
    static func index(ofName name: String) -> Int? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let digits = name.dropFirst(namePrefix.count)
        guard !digits.isEmpty, digits.first != "0",
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits) else { return nil }
        return value
    }

    // The name for the next scratch buffer, given the titles already open.
    // Callers pass whole tab titles rather than pre-filtered ones — deciding
    // what counts as a scratch name is this type's job, not the caller's.
    static func nextName(takenNames: [String]) -> String {
        let taken = Set(takenNames.compactMap(index(ofName:)))
        var candidate = 1
        while taken.contains(candidate) { candidate += 1 }
        return "\(namePrefix)\(candidate)"
    }
}
