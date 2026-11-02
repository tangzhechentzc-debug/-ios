import Foundation

struct RecoveryJournal {
    let url: URL
    var needsRecovery: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func applicationJournal() throws -> RecoveryJournal {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true)
        return RecoveryJournal(url: directory.appendingPathComponent("location-needs-recovery"))
    }

    func markBeforeSending() throws {
        try Data("needs-recovery\n".utf8).write(to: url, options: .atomic)
    }

    func clearAfterRestorationConfirmation() throws {
        if needsRecovery { try FileManager.default.removeItem(at: url) }
    }
}
