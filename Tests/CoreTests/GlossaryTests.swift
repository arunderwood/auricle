@testable import Core
import Foundation
import Testing

@Test func glossaryRoundTripsAndUsesSnakeCaseKeys() throws {
    let value = Glossary(
        people: ["Ben"],
        projects: ["Auricle"],
        concepts: ["meshcore"],
        uncategorized: ["misc"],
    )

    let data = try JSONEncoder().encode(value)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"people\""))
    #expect(json.contains("\"projects\""))
    #expect(json.contains("\"concepts\""))
    #expect(json.contains("\"uncategorized\""))

    let decoded = try JSONDecoder().decode(Glossary.self, from: data)
    #expect(decoded == value)
}

@Test func glossaryDefaultInitYieldsEmptyLists() {
    let value = Glossary()

    #expect(value.people.isEmpty)
    #expect(value.projects.isEmpty)
    #expect(value.concepts.isEmpty)
    #expect(value.uncategorized.isEmpty)
}
