import Core
import Foundation
import State

/// Opens the note a clicked notification points at. Opening is all it does:
/// verification is a separate act, and must not hinge on Obsidian opening.
public struct NotificationClickHandler: Sendable {
    public typealias Opener = @Sendable (URL) async throws -> Void

    private let vaultRoot: URL
    private let stateStore: StateStore
    private let opener: Opener
    private let log: Log

    public init(
        vaultRoot: URL,
        stateStore: StateStore,
        opener: @escaping Opener,
        log: Log = Log(category: "notifications"),
    ) {
        self.vaultRoot = vaultRoot
        self.stateStore = stateStore
        self.opener = opener
        self.log = log
    }

    public func handle(userInfo: [AnyHashable: Any]) async {
        await handle(payload: NotificationPayload(userInfo: userInfo))
    }

    /// Takes the already-decoded payload so a caller holding a non-`Sendable`
    /// `userInfo` can decode it before crossing into a `Task`.
    public func handle(payload: NotificationPayload?) async {
        guard let payload else {
            log.warn("notification click carried no recognizable payload")
            return
        }
        guard payload.payloadVersion == NotificationPayload.currentPayloadVersion else {
            log.warn("notification click carried an unsupported payload version", [
                "payloadVersion": .publicSafe(payload.payloadVersion),
            ])
            return
        }
        let notePath: String?
        do {
            notePath = try await stateStore.fetchMeeting(id: payload.meetingID)?.vaultNotePath
        } catch {
            log.warn("notification click could not read the meeting", ["rawID": .publicSafe(payload.meetingID)])
            return
        }
        guard let notePath, let url = ObsidianURL.make(notePath: notePath, vaultRoot: vaultRoot) else {
            log.warn("notification click found no note to open", ["rawID": .publicSafe(payload.meetingID)])
            return
        }
        do {
            try await opener(url)
        } catch {
            log.warn("opening the note in Obsidian failed", ["rawID": .publicSafe(payload.meetingID)])
        }
    }
}
