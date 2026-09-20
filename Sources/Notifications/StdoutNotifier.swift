import Core
import Foundation

/// The CLI's notifier: the note path, then its Obsidian URL, one per line.
/// The CLI posts no system notification.
public struct StdoutNotifier: Notifier {
    public typealias Sink = @Sendable (String) -> Void

    private let vaultRoot: URL
    private let sink: Sink
    private let log: Log

    /// The default sink writes to standard output directly: `print` is barred
    /// outside the verbs whose stdout is their output, and `Log` is not stdout.
    public init(
        vaultRoot: URL,
        sink: @escaping Sink = { line in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        },
        log: Log = Log(category: "notifications"),
    ) {
        self.vaultRoot = vaultRoot
        self.sink = sink
        self.log = log
    }

    public func fire(meetingID: MeetingID, title _: String, vaultPath: String) async {
        sink(vaultPath)
        if let url = ObsidianURL.make(notePath: vaultPath, vaultRoot: vaultRoot) {
            sink(url.absoluteString)
        } else {
            log.warn("could not build an obsidian URL for the note", ["meetingID": .publicSafe(meetingID)])
        }
    }
}
