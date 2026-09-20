import Foundation
@testable import Notifications
import Testing

struct ObsidianURLTests {
    let vault = URL(fileURLWithPath: "/Users/x/My Vault")

    @Test func encodesSpacesAndDropsMdExtension() throws {
        let url = try #require(ObsidianURL.make(notePath: "/Users/x/My Vault/Meetings/a b.md", vaultRoot: vault))
        #expect(url.absoluteString == "obsidian://open?vault=My%20Vault&file=Meetings/a%20b")
    }

    @Test func encodesNonASCIIAndQueryDelimiters() throws {
        let url = try #require(ObsidianURL.make(notePath: "/Users/x/My Vault/Meetings/café & co=1+2#3.md", vaultRoot: vault))
        #expect(url.absoluteString == "obsidian://open?vault=My%20Vault&file=Meetings/caf%C3%A9%20%26%20co%3D1%2B2%233")
    }

    @Test func noteOutsideVaultFallsBackToPath() throws {
        let url = try #require(ObsidianURL.make(notePath: "/elsewhere/n.md", vaultRoot: vault))
        #expect(url.absoluteString == "obsidian://open?path=/elsewhere/n.md")
    }

    @Test func siblingDirectoryWithSharedPrefixIsOutside() throws {
        let url = try #require(ObsidianURL.make(notePath: "/Users/x/My Vault2/n.md", vaultRoot: vault))
        #expect(url.absoluteString.hasPrefix("obsidian://open?path="))
    }

    @Test func payloadRoundTripsSnakeCaseKeys() throws {
        let payload = NotificationPayload(meetingID: "01ABC")
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["meeting_id", "schema_version", "payload_version"])
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["payload_version"] as? Int == 1)
        #expect(try JSONDecoder().decode(NotificationPayload.self, from: data) == payload)
        #expect(NotificationPayload(userInfo: payload.userInfo) == payload)
    }
}
