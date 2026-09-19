import Foundation
import Summarize
import Testing

@Test func bareStrategyNamesParseWithNoPromptDir() throws {
    #expect(try StrategyComparisonArmSpec.parse("citations") == StrategyComparisonArmSpec(kind: .citations))
    #expect(try StrategyComparisonArmSpec.parse("substring") == StrategyComparisonArmSpec(kind: .substring))
}

@Test func substringWithAnAbsolutePromptDirParsesAndLabelsByDirectoryName() throws {
    let spec = try StrategyComparisonArmSpec.parse("substring:/tmp/prompts/tighter")

    #expect(spec.kind == .substring)
    #expect(spec.promptDir?.path == "/tmp/prompts/tighter")
    #expect(spec.label == "substring:tighter")
}

@Test func aLeadingTildeExpandsToTheHomeDirectory() throws {
    let spec = try StrategyComparisonArmSpec.parse("substring:~/prompts/v2")

    #expect(spec.promptDir?.path == (NSHomeDirectory() as NSString).appendingPathComponent("prompts/v2"))
}

@Test func anUnknownStrategyThrows() {
    #expect(throws: StrategyComparisonArmSpec.ParseError.unknownStrategy("gemini")) {
        try StrategyComparisonArmSpec.parse("gemini")
    }
}

@Test func citationsWithAPromptDirThrows() {
    #expect(throws: StrategyComparisonArmSpec.ParseError.promptDirUnsupported(strategy: "citations")) {
        try StrategyComparisonArmSpec.parse("citations:/tmp/p")
    }
}

@Test func aRelativePromptDirThrows() {
    #expect(throws: StrategyComparisonArmSpec.ParseError.promptDirNotAbsolute("prompts/v2")) {
        try StrategyComparisonArmSpec.parse("substring:prompts/v2")
    }
}

@Test func noArgumentsMeansTheDecisionPair() throws {
    let specs = try StrategyComparisonArmSpec.parseAll([])

    #expect(specs.map(\.label) == ["citations", "substring"])
}

@Test func armsKeepTheOrderGiven() throws {
    let specs = try StrategyComparisonArmSpec.parseAll(["substring:/tmp/b", "substring", "substring:/tmp/a"])

    #expect(specs.map(\.label) == ["substring:b", "substring", "substring:a"])
}

@Test func twoArmsWithTheSameLabelThrow() {
    #expect(throws: StrategyComparisonArmSpec.ParseError.duplicateLabel("substring")) {
        try StrategyComparisonArmSpec.parseAll(["substring", "substring"])
    }
    #expect(throws: StrategyComparisonArmSpec.ParseError.duplicateLabel("substring:v")) {
        try StrategyComparisonArmSpec.parseAll(["substring:/a/v", "substring:/b/v"])
    }
}
