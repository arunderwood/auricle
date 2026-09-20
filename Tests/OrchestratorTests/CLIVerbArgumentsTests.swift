import ArgumentParser
import Orchestrator
import Testing

// The flags Decision 1.5 and `epics.md` (Stories 4.7, 9.5) document for the
// ten MVP verbs, parsed through the types the `auricle-cli` verbs read their
// command line with. A flag that stops parsing under its documented
// kebab-case name fails here rather than in whichever story first reads it.

private let meetingID = "01HZ7K9999999999999999999A"

// MARK: - record

@Test func recordTakesAnOptionalIDAndDefaultsEveryFlagOff() throws {
    let bare = try RecordArguments.parse([])
    #expect(bare.id == nil)
    #expect(!bare.replace)
    #expect(!bare.quiet)

    let withID = try RecordArguments.parse([meetingID])
    #expect(withID.id == meetingID)
}

@Test func recordParsesReplaceAndQuiet() throws {
    let parsed = try RecordArguments.parse([meetingID, "--replace", "--quiet"])

    #expect(parsed.id == meetingID)
    #expect(parsed.replace)
    #expect(parsed.quiet)
}

// MARK: - stop, discard, keep

@Test func stopParsesQuiet() throws {
    #expect(try !StopArguments.parse([]).quiet)
    #expect(try StopArguments.parse(["--quiet"]).quiet)
}

@Test func discardRequiresAnIDAndParsesQuiet() throws {
    #expect(throws: (any Error).self) { try DiscardArguments.parse([]) }

    let parsed = try DiscardArguments.parse([meetingID, "--quiet"])
    #expect(parsed.id == meetingID)
    #expect(parsed.quiet)
    #expect(try !DiscardArguments.parse([meetingID]).quiet)
}

@Test func keepRequiresAnIDAndParsesQuiet() throws {
    #expect(throws: (any Error).self) { try KeepArguments.parse([]) }

    let parsed = try KeepArguments.parse([meetingID, "--quiet"])
    #expect(parsed.id == meetingID)
    #expect(parsed.quiet)
    #expect(try !KeepArguments.parse([meetingID]).quiet)
}

// MARK: - run

@Test func runRequiresAnIDAndDefaultsEveryFlagOff() throws {
    #expect(throws: (any Error).self) { try RunArguments.parse([]) }

    let parsed = try RunArguments.parse([meetingID])
    #expect(parsed.id == meetingID)
    #expect(!parsed.force)
    #expect(parsed.from == nil)
    #expect(parsed.to == nil)
    #expect(parsed.only == nil)
    #expect(!parsed.reattribute)
    #expect(!parsed.publishAnyway)
}

/// One flag per parse: Story 4.7 rejects `--from` with `--only` and
/// `--publish-anyway` with `--from attribute` at parse time, so combining them
/// here would fail for a reason unrelated to the spelling under test.
@Test func runParsesForce() throws {
    #expect(try RunArguments.parse([meetingID, "--force"]).force)
}

@Test func runParsesFromAndToTogether() throws {
    let parsed = try RunArguments.parse([meetingID, "--from", "transcribe", "--to", "summarize"])

    #expect(parsed.from == "transcribe")
    #expect(parsed.to == "summarize")
    #expect(parsed.only == nil)
}

@Test func runParsesOnly() throws {
    let parsed = try RunArguments.parse([meetingID, "--only", "summarize"])

    #expect(parsed.only == "summarize")
    #expect(parsed.from == nil)
}

@Test func runParsesReattribute() throws {
    #expect(try RunArguments.parse([meetingID, "--reattribute"]).reattribute)
}

@Test func runParsesPublishAnywayUnderItsKebabCaseName() throws {
    #expect(try RunArguments.parse([meetingID, "--publish-anyway"]).publishAnyway)
}

@Test(arguments: ["--publishAnyway", "--publish_anyway", "--publishanyway"])
func runRejectsEveryOtherSpellingOfPublishAnyway(spelling: String) {
    #expect(throws: (any Error).self) { try RunArguments.parse([meetingID, spelling]) }
}

@Test(arguments: ["--from", "--to", "--only"])
func aRunStageOptionWithNoValueDoesNotParse(option: String) {
    #expect(throws: (any Error).self) { try RunArguments.parse([meetingID, option]) }
}

// MARK: - attribute

@Test func attributeRequiresAnIDAndParsesBatch() throws {
    #expect(throws: (any Error).self) { try AttributeArguments.parse([]) }

    #expect(try !AttributeArguments.parse([meetingID]).batch)
    let parsed = try AttributeArguments.parse([meetingID, "--batch"])
    #expect(parsed.id == meetingID)
    #expect(parsed.batch)
}

// MARK: - list, status

@Test func listParsesAllAndJSONIndependently() throws {
    let bare = try ListArguments.parse([])
    #expect(!bare.all)
    #expect(!bare.json)

    let all = try ListArguments.parse(["--all"])
    #expect(all.all)
    #expect(!all.json)

    let json = try ListArguments.parse(["--json"])
    #expect(!json.all)
    #expect(json.json)

    let both = try ListArguments.parse(["--all", "--json"])
    #expect(both.all)
    #expect(both.json)
}

@Test func statusRequiresAnIDAndParsesJSON() throws {
    #expect(throws: (any Error).self) { try StatusArguments.parse([]) }

    #expect(try !StatusArguments.parse([meetingID]).json)
    let parsed = try StatusArguments.parse([meetingID, "--json"])
    #expect(parsed.id == meetingID)
    #expect(parsed.json)
}

// MARK: - config

@Test func configGetTakesAnOptionalKey() throws {
    #expect(try ConfigGetArguments.parse([]).key == nil)
    #expect(try ConfigGetArguments.parse(["vault_path"]).key == "vault_path")
}

@Test func configSetRequiresAKeyAndAValue() throws {
    #expect(throws: (any Error).self) { try ConfigSetArguments.parse([]) }
    #expect(throws: (any Error).self) { try ConfigSetArguments.parse(["vault_path"]) }

    let parsed = try ConfigSetArguments.parse(["vault_path", "/vaults/notes"])
    #expect(parsed.key == "vault_path")
    #expect(parsed.value == "/vaults/notes")
}

// MARK: - __internal-import

@Test func importRequiresAnAudioFileAndParsesItsOptionalFlags() throws {
    #expect(throws: (any Error).self) { try ImportArguments.parse([]) }

    let bare = try ImportArguments.parse(["call.m4a"])
    #expect(bare.audioFile == "call.m4a")
    #expect(bare.startedAt == nil)
    #expect(bare.title == nil)

    let full = try ImportArguments.parse(["call.m4a", "--started-at", "2026-09-19T14:30:00Z", "--title", "Standup"])
    #expect(full.startedAt == "2026-09-19T14:30:00Z")
    #expect(full.title == "Standup")
}
