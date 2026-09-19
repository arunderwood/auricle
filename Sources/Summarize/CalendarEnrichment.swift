import CalendarInterface
import Core
import Foundation

/// What the summarize stage learned from the calendar: a matched event's
/// title and attendees, or the degraded variant that leaves the note
/// unenriched. Every way a lookup can go wrong lands on `degraded`; the one
/// thing `resolve` does not absorb is cancellation, which must still stop the
/// stage.
///
/// The stage sets no deadline on a lookup: racing the call against a timer
/// cannot preempt an await that never checks for cancellation, so a lookup
/// that never returns is the source's to bound (`CalendarSource.fetchActiveEvent`).
struct CalendarEnrichment: Sendable, Equatable {
    /// A usable event, already shaped for each place it is used. Attendee
    /// emails do not appear here, so nothing built from a `Match` can carry one.
    struct Match: Sendable, Equatable {
        let eventID: String
        let title: String
        /// `[[Name]]`, one per attendee with a usable name; the note's attendees.
        let attendeeWikilinks: [String]
        /// The owner's `[[Name]]`, so filename slugging can leave the owner out.
        let selfWikilink: String?
        /// Plain names in the same order, for the prompt.
        let attendeeNames: [String]
    }

    let match: Match?
    let artifact: CalendarArtifact

    static let degraded = CalendarEnrichment(match: nil, artifact: CalendarArtifact(degraded: true, event: nil))

    private static let log = Log(category: "calendar-enrichment")

    /// Characters that would end, retarget or alias a wikilink or a Markdown
    /// heading or block reference if they survived into `[[Name]]`.
    private static let linkSyntax: Set<Unicode.Scalar> = ["[", "]", "|", "#", "^", "\\"]

    /// `nil` source, a `nil` result, a blank title and every thrown error but
    /// cancellation all resolve to `degraded`. Only a case or type name is
    /// logged for an error: a foreign error's own message can embed a URL, a
    /// response body or an attendee's address.
    static func resolve(using source: (any CalendarSource)?, at captureStartedAt: Date) async throws -> CalendarEnrichment {
        guard let source else { return .degraded }
        let event: CalendarEvent?
        do {
            event = try await source.fetchActiveEvent(at: captureStartedAt)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // A task cancelled mid-lookup surfaces as whatever error the
            // transport chose (`URLError(.cancelled)`, say); it must still
            // stop the stage, not degrade and carry on into the summarizer.
            try Task.checkCancellation()
            log.warn("calendar lookup failed, continuing without an event", ["error": .publicSafe(errorName(error))])
            return .degraded
        }
        guard let event, let enrichment = enriched(from: event) else { return .degraded }
        return enrichment
    }

    /// The display name as it may appear inside `[[…]]`, or `nil` when nothing
    /// usable is left. Whitespace-like controls become spaces before the rest
    /// are dropped, so `Ben\tSmith` stays two words. A name containing `@` is
    /// an email address someone typed into the name field, so it is unusable:
    /// an address must not reach a prompt, an artifact or a note by that route.
    static func sanitizedName(_ raw: String) -> String? {
        guard !raw.contains("@") else { return nil }
        var kept = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where !linkSyntax.contains(scalar) {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                kept.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                kept.append(scalar)
            }
        }
        let collapsed = String(kept).split(separator: " ").joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func enriched(from event: CalendarEvent) -> CalendarEnrichment? {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let attendees = event.attendees.map { (name: $0.displayName.flatMap(sanitizedName), isSelf: $0.isSelf) }
        let names = attendees.compactMap(\.name)
        let selfName = attendees.first { $0.isSelf && $0.name != nil }?.name

        let artifact = CalendarArtifact(
            degraded: false,
            event: CalendarEventArtifact(
                eventID: event.id,
                title: title,
                start: ISO8601UTC.string(from: event.start),
                end: ISO8601UTC.string(from: event.end),
                attendees: attendees.map { CalendarAttendeeArtifact(displayName: $0.name, isSelf: $0.isSelf) },
            ),
        )
        let match = Match(
            eventID: event.id,
            title: title,
            attendeeWikilinks: names.map(wikilink),
            selfWikilink: selfName.map(wikilink),
            attendeeNames: names,
        )
        return CalendarEnrichment(match: match, artifact: artifact)
    }

    private static func wikilink(_ name: String) -> String {
        "[[\(name)]]"
    }

    static func errorName(_ error: Error) -> String {
        switch error as? CalendarError {
        case .authorizationExpired: "CalendarError.authorizationExpired"
        case .unreachable: "CalendarError.unreachable"
        case nil: String(reflecting: type(of: error))
        }
    }
}
