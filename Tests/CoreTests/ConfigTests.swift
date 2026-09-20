@testable import Core
import Foundation
import Testing

/// A directory that stands in for the user's home, so no test reads the real
/// `~/.auricle`.
private func makeFakeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("config-tests-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func writeConfig(_ text: String, inHome home: URL) throws -> URL {
    let file = Config.defaultFileURL(homeDirectory: home)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try AtomicWriter.write(Data(text.utf8), to: file)
    return file
}

private let home = URL(fileURLWithPath: "/fake/home", isDirectory: true)

@Test func defaultFileLivesUnderDotAuricleInTheGivenHome() {
    let url = Config.defaultFileURL(homeDirectory: home)

    #expect(url.path == "/fake/home/.auricle/config.toml")
}

@Test func parsesEveryKnownKey() throws {
    let config = try Config.parse(
        """
        vault_path = "/vaults/notes"
        meetings_subdir = "Work/Meetings"

        [google_calendar]
        client_id = "abc.apps.googleusercontent.com"
        client_secret = "shh"
        """,
        homeDirectory: home,
    )

    #expect(config.vaultPath?.path == "/vaults/notes")
    #expect(config.meetingsSubdir == "Work/Meetings")
    #expect(config.googleCalendar.clientID == "abc.apps.googleusercontent.com")
    #expect(config.googleCalendar.clientSecret == "shh")
}

@Test func emptyDocumentYieldsDefaultsWithNoVaultPath() throws {
    let config = try Config.parse("", homeDirectory: home)

    #expect(config == Config())
    #expect(config.vaultPath == nil)
    #expect(config.meetingsSubdir == "Meetings")
    #expect(config.googleCalendar.clientID == nil)
    #expect(config.googleCalendar.clientSecret == nil)
}

@Test func emptyStringsAreTreatedAsUnset() throws {
    let config = try Config.parse(
        """
        vault_path = ""
        meetings_subdir = ""

        [google_calendar]
        client_id = ""
        client_secret = ""
        """,
        homeDirectory: home,
    )

    #expect(config == Config())
}

@Test func leadingTildeExpandsToTheInjectedHome() throws {
    let config = try Config.parse(#"vault_path = "~/notes/vault""#, homeDirectory: home)

    #expect(config.vaultPath?.path == "/fake/home/notes/vault")
}

@Test func bareTildeExpandsToTheInjectedHome() throws {
    let config = try Config.parse(#"vault_path = "~""#, homeDirectory: home)

    #expect(config.vaultPath?.path == "/fake/home")
}

@Test func relativeVaultPathIsRejected() {
    #expect(throws: ConfigError.invalidValue(key: "vault_path", reason: "must be an absolute path or start with ~/")) {
        try Config.parse(#"vault_path = "notes/vault""#, homeDirectory: home)
    }
}

@Test func otherUsersTildeFormIsRejectedRatherThanTreatedAsRelative() {
    #expect(throws: ConfigError.self) {
        try Config.parse(#"vault_path = "~someone/vault""#, homeDirectory: home)
    }
}

@Test(arguments: ["/etc", "../escape", "a/../../b"])
func meetingsSubdirCannotBeAbsoluteOrClimbOutOfTheVault(value: String) {
    #expect(throws: ConfigError.invalidValue(key: "meetings_subdir", reason: "must be a relative path inside the vault")) {
        try Config.parse("meetings_subdir = \"\(value)\"", homeDirectory: home)
    }
}

@Test func unknownKeysAndTablesAreIgnored() throws {
    let config = try Config.parse(
        """
        vault_path = "/vaults/notes"
        future_key = 3

        [future_table]
        nested = true
        """,
        homeDirectory: home,
    )

    #expect(config.vaultPath?.path == "/vaults/notes")
}

@Test func syntaxErrorIsMalformedWithItsLine() {
    #expect(throws: ConfigError.malformed(line: 2)) {
        try Config.parse("vault_path = \"/ok\"\nthis is not toml", homeDirectory: home)
    }
}

@Test func wrongTypeNamesTheOffendingKey() {
    #expect(throws: ConfigError.invalidValue(key: "vault_path", reason: "has the wrong type")) {
        try Config.parse("vault_path = 7", homeDirectory: home)
    }
}

@Test func wrongTypeInsideTableUsesDottedKey() {
    #expect(throws: ConfigError.invalidValue(key: "google_calendar.client_id", reason: "has the wrong type")) {
        try Config.parse("[google_calendar]\nclient_id = 7", homeDirectory: home)
    }
}

@Test func scalarWhereTableExpectedNamesTheTable() {
    #expect(throws: ConfigError.invalidValue(key: "google_calendar", reason: "has the wrong type")) {
        try Config.parse(#"google_calendar = "nope""#, homeDirectory: home)
    }
}

@Test func missingFileYieldsDefaultsNotAnError() throws {
    let fakeHome = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: fakeHome) }

    let config = try Config.load(homeDirectory: fakeHome)

    #expect(config == Config())
}

@Test func loadReadsTheDefaultFileUnderTheInjectedHome() throws {
    let fakeHome = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: fakeHome) }
    _ = try writeConfig(#"vault_path = "~/vault""#, inHome: fakeHome)

    let config = try Config.load(homeDirectory: fakeHome)

    #expect(config.vaultPath?.path == fakeHome.path + "/vault")
}

@Test func loadReadsAnExplicitFileLocation() throws {
    let fakeHome = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: fakeHome) }
    let file = fakeHome.appendingPathComponent("elsewhere.toml")
    try AtomicWriter.write(Data(#"vault_path = "/vaults/explicit""#.utf8), to: file)

    let config = try Config.load(from: file, homeDirectory: fakeHome)

    #expect(config.vaultPath?.path == "/vaults/explicit")
}

@Test func loadOfMalformedFileThrowsMalformed() throws {
    let fakeHome = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: fakeHome) }
    _ = try writeConfig("vault_path = ", inHome: fakeHome)

    #expect(throws: ConfigError.malformed(line: 1)) {
        try Config.load(homeDirectory: fakeHome)
    }
}

@Test func loadOfNonUTF8FileThrowsMalformedWithoutALine() throws {
    let fakeHome = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: fakeHome) }
    let file = Config.defaultFileURL(homeDirectory: fakeHome)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try AtomicWriter.write(Data([0xFF, 0xFE, 0x00]), to: file)

    #expect(throws: ConfigError.malformed(line: nil)) {
        try Config.load(homeDirectory: fakeHome)
    }
}

@Test func loadOfADirectoryAtTheConfigPathThrowsUnreadable() throws {
    let fakeHome = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: fakeHome) }
    let file = Config.defaultFileURL(homeDirectory: fakeHome)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

    #expect(throws: ConfigError.self) {
        try Config.load(homeDirectory: fakeHome)
    }
}

@Test func snippetDurationDefaultsToEightSeconds() throws {
    #expect(try Config.parse("", homeDirectory: home).attribution.snippetDurationSeconds == 8)
    #expect(try Config.parse("[attribution]\n", homeDirectory: home).attribution.snippetDurationSeconds == 8)
}

@Test func snippetDurationIsReadFromTheAttributionTable() throws {
    let config = try Config.parse("[attribution]\nsnippet_duration_seconds = 6\n", homeDirectory: home)

    #expect(config.attribution.snippetDurationSeconds == 6)
}

@Test func aSnippetDurationOutsideTheClampRangeIsKeptForTheStageToClamp() throws {
    #expect(try Config.parse("[attribution]\nsnippet_duration_seconds = 20\n", homeDirectory: home).attribution.snippetDurationSeconds == 20)
}

@Test(arguments: ["0", "-3", "\"long\"", "2.5"])
func anUnusableSnippetDurationThrowsInvalidValue(_ value: String) {
    #expect(throws: ConfigError.self) {
        try Config.parse("[attribution]\nsnippet_duration_seconds = \(value)\n", homeDirectory: home)
    }
}

@Test func aNonPositiveSnippetDurationNamesItsKey() {
    #expect(throws: ConfigError.invalidValue(key: "attribution.snippet_duration_seconds", reason: "must be a positive number of seconds")) {
        try Config.parse("[attribution]\nsnippet_duration_seconds = 0\n", homeDirectory: home)
    }
}

@Test func diarizationReviewDefaultsToOffWithHaikuModel() throws {
    let config = try Config.parse("", homeDirectory: home)

    #expect(config.diarizationReview == Config.DiarizationReview(enabled: false, model: "claude-haiku-4-5"))
}

@Test func parsesDiarizationReviewKeys() throws {
    let config = try Config.parse("[diarization_review]\nenabled = true\nmodel = \"claude-sonnet-4-5\"\n", homeDirectory: home)

    #expect(config.diarizationReview.enabled)
    #expect(config.diarizationReview.model == "claude-sonnet-4-5")
}

@Test func blankDiarizationReviewModelFallsBackToTheDefault() throws {
    let config = try Config.parse("[diarization_review]\nmodel = \"\"\n", homeDirectory: home)

    #expect(config.diarizationReview.model == Config.DiarizationReview.defaultModel)
    #expect(!config.diarizationReview.enabled)
}

@Test func wrongTypeForDiarizationReviewEnabledIsInvalid() {
    #expect(throws: ConfigError.self) {
        try Config.parse("[diarization_review]\nenabled = \"yes\"\n", homeDirectory: home)
    }
}
