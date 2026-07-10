import Cocoa

// File History section: reveal a file's commits under a
// "File History" section, loaded async off the main thread.
extension GitView {
    // Show File History for a file: reveal its commits under
    // a "File History" section. Loaded async off the main thread; a later call
    // for another file supersedes an in-flight one via the generation guard.
    func showFileHistory(absolutePath: String) {
        historyPath = absolutePath
        historyCommits = []
        historyGeneration += 1
        let generation = historyGeneration
        reload()
        GitFileHistory.compute(filePath: absolutePath) { [weak self] _, commits in
            guard let self, self.historyGeneration == generation else { return }
            self.historyCommits = commits
            self.reload()
        }
    }
}
