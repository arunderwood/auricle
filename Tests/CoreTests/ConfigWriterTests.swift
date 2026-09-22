@testable import Core
import Foundation
import Testing

/// A directory that stands in for the user's home, so no test reads or
/// writes the real `~/.auricle`.
private func makeFakeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("config-writer-tests-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func writeConfig(_ text: String, inHome home: URL) throws -> URL {
    let file = Config.defaultFileURL(homeDirectory: home)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try AtomicWriter.write(Data(text.utf8), to: file)
    return file
}

private func readFile(_ url: URL) throws -> String {
    guard let text = try String(bytes: Data(contentsOf: url), encoding: .utf8) else {
        Issue.record("file at \(url.path) was not valid UTF-8")
        return ""
    }
    return text
}

@Test func setChangesOnlyTheTargetTopLevelKey() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("# a comment\nvault_path = \"/old\"\nmeetings_subdir = \"Meetings\"\n", inHome: home)

    try ConfigWriter.set("vault_path", to: "/new", homeDirectory: home)

    #expect(try readFile(file) == "# a comment\nvault_path = \"/new\"\nmeetings_subdir = \"Meetings\"\n")
    #expect(try Config.parse(readFile(file), homeDirectory: home).vaultPath?.path == "/new")
}

@Test func setChangesAnExistingKeyInATableSectionLeavingItsCommentAndSiblingsAlone() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("# picked at onboarding\n[self]\nwikilink = \"[[Old]]\"\n", inHome: home)

    try ConfigWriter.set("self.wikilink", to: "[[New]]", homeDirectory: home)

    #expect(try readFile(file) == "# picked at onboarding\n[self]\nwikilink = \"[[New]]\"\n")
}

@Test func setChangesAnExistingFullyDottedLineWithoutCreatingATableSection() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("self.wikilink = \"[[Old]]\"\n", inHome: home)

    try ConfigWriter.set("self.wikilink", to: "[[New]]", homeDirectory: home)

    let text = try readFile(file)
    #expect(text == "self.wikilink = \"[[New]]\"\n")
    #expect(!text.contains("[self]"))
}

@Test func setAppendsANewSectionWhenTheTableDoesNotExist() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("vault_path = \"/x\"\n", inHome: home)

    try ConfigWriter.set("self.wikilink", to: "[[Jordan]]", homeDirectory: home)

    #expect(try readFile(file) == "vault_path = \"/x\"\n\n[self]\nwikilink = \"[[Jordan]]\"\n")
}

@Test func setAppendsIntoAnExistingTableThatLacksTheKey() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("[self]\nother_key = \"y\"\n", inHome: home)

    try ConfigWriter.set("self.wikilink", to: "[[Jordan]]", homeDirectory: home)

    #expect(try readFile(file) == "[self]\nother_key = \"y\"\nwikilink = \"[[Jordan]]\"\n")
}

@Test func setCreatesTheDirectoryAndFileWhenNeitherExists() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = Config.defaultFileURL(homeDirectory: home)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    try ConfigWriter.set("self.wikilink", to: "[[Jordan]]", homeDirectory: home)

    #expect(try readFile(file) == "[self]\nwikilink = \"[[Jordan]]\"\n")
}

@Test func setPreservesATrailingInlineCommentOnTheEditedLine() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("[self]\nwikilink = \"[[Old]]\" # picked at onboarding\n", inHome: home)

    try ConfigWriter.set("self.wikilink", to: "[[New]]", homeDirectory: home)

    #expect(try readFile(file) == "[self]\nwikilink = \"[[New]]\" # picked at onboarding\n")
}

@Test func setReplacesAnExistingBracketedArrayValueEntirely() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("[self]\nkey = [1, 2, 3]\nother_key = \"y\"\n", inHome: home)

    try ConfigWriter.set("self.key", to: "new", homeDirectory: home)

    #expect(try readFile(file) == "[self]\nkey = \"new\"\nother_key = \"y\"\n")
}

@Test func setRecognizesAnExistingHeaderCarryingATrailingComment() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("[self] # note\nwikilink = \"[[Old]]\"\n", inHome: home)

    try ConfigWriter.set("self.wikilink", to: "[[New]]", homeDirectory: home)

    #expect(try readFile(file) == "[self] # note\nwikilink = \"[[New]]\"\n")
}

@Test func setRecognizesAnExistingHeaderWithNonCanonicalSpacing() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("[ self ]\nwikilink = \"[[Old]]\"\n", inHome: home)

    try ConfigWriter.set("self.wikilink", to: "[[New]]", homeDirectory: home)

    #expect(try readFile(file) == "[ self ]\nwikilink = \"[[New]]\"\n")
}

@Test func setEscapesAValueContainingAQuoteAndABackslashAndItRoundTrips() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let value = "a\"b\\c"

    try ConfigWriter.set("self.wikilink", to: value, homeDirectory: home)

    let file = Config.defaultFileURL(homeDirectory: home)
    #expect(try Config.parse(readFile(file), homeDirectory: home).selfWikilink == value)
}

@Test func selfWikilinkRoundTripsThroughConfigLoad() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try ConfigWriter.set("self.wikilink", to: "[[Jordan]]", homeDirectory: home)

    #expect(try Config.load(homeDirectory: home).selfWikilink == "[[Jordan]]")
}

@Test(arguments: ["", ".", "self.", ".wikilink", "a b", "self.wiki link", "a[b]"])
func invalidKeyThrowsBeforeTouchingAnyFile(key: String) throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = try writeConfig("vault_path = \"/x\"\n", inHome: home)

    #expect(throws: ConfigWriter.WriterError.invalidKey(key: key)) {
        try ConfigWriter.set(key, to: "value", homeDirectory: home)
    }
    #expect(try readFile(file) == "vault_path = \"/x\"\n")
}

@Test func invalidKeyDoesNotCreateTheConfigDirectoryWhenNoFileExists() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let auricleDirectory = home.appendingPathComponent(".auricle", isDirectory: true)

    #expect(throws: ConfigWriter.WriterError.invalidKey(key: "self.")) {
        try ConfigWriter.set("self.", to: "value", homeDirectory: home)
    }
    #expect(!FileManager.default.fileExists(atPath: auricleDirectory.path))
}

@Test func nonUTF8ExistingFileThrowsMalformed() throws {
    let home = try makeFakeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let file = Config.defaultFileURL(homeDirectory: home)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try AtomicWriter.write(Data([0xFF, 0xFE, 0x00]), to: file)

    #expect(throws: ConfigWriter.WriterError.malformed) {
        try ConfigWriter.set("vault_path", to: "/new", homeDirectory: home)
    }
}
