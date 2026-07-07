import Cocoa

// Live-tail / file-watching for the transcript pane: a DispatchSource watches
// the JSONL file and reads whatever was appended, parsing complete lines into
// entries (a write can land mid-line; the tail fragment waits in `remainder`).

extension TranscriptPaneContent {
    func watch(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // Recreated file (e.g. session resumed): start over if it's back.
                self.stopWatching()
                self.entries = []
                self.entrySourceLines = []
                self.lineCounter = 0
                self.readOffset = 0
                self.remainder = Data()
                if FileManager.default.fileExists(atPath: path) {
                    self.readAppended()
                    self.watch(path: path)
                    self.render()
                }
                return
            }
            self.readAppended()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }

    func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    // Reads everything past readOffset, parses complete lines (a write can land
    // mid-line; the tail fragment waits in `remainder` for the next event), and
    // appends the new entries.
    func readAppended() {
        guard let transcriptPath, let handle = FileHandle(forReadingAtPath: transcriptPath) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < readOffset {
            // Truncated in place: start over.
            entries = []
            entrySourceLines = []
            lineCounter = 0
            readOffset = 0
            remainder = Data()
        }
        guard size > readOffset else { return }
        try? handle.seek(toOffset: readOffset)
        guard let data = try? handle.readToEnd() else { return }
        readOffset = size

        var buffer = remainder
        buffer.append(data)
        var newEntries: [TranscriptEntry] = []
        var newSourceLines: [Int] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            lineCounter += 1
            if let line = String(data: lineData, encoding: .utf8) {
                let parsed = parseTranscriptLine(line)
                newEntries.append(contentsOf: parsed)
                newSourceLines.append(contentsOf: Array(repeating: lineCounter, count: parsed.count))
            }
        }
        remainder = Data(buffer)

        guard !newEntries.isEmpty else { return }
        entries.append(contentsOf: newEntries)
        entrySourceLines.append(contentsOf: newSourceLines)
        if entries.count > Self.maxEntries {
            let drop = entries.count - Self.maxEntries
            entries.removeFirst(drop)
            entrySourceLines.removeFirst(drop)
            render()
        } else {
            append(attributed: attributedString(for: newEntries))
        }
    }
}
