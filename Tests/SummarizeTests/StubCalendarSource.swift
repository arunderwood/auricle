import CalendarInterface
import Foundation

/// Answers `fetchActiveEvent` with a fixed result and records how it was
/// called, so a test can prove the stage did, or never did, reach the
/// calendar and with which capture time, and whether it was ever asked to
/// authorize, which the stage must not do.
actor StubCalendarSource: CalendarSource {
    private let result: Result<CalendarEvent?, any Error>
    private(set) var fetchCount = 0
    private(set) var authorizeCount = 0
    private(set) var requestedDates: [Date] = []

    init(_ result: Result<CalendarEvent?, any Error>) {
        self.result = result
    }

    func authorize() async throws {
        authorizeCount += 1
    }

    func fetchActiveEvent(at date: Date) async throws -> CalendarEvent? {
        fetchCount += 1
        requestedDates.append(date)
        return try result.get()
    }

    func upcomingEvents(in _: TimeInterval) async throws -> [CalendarEvent] {
        []
    }
}
