import Foundation
import os
import Permissions

/// A `PermissionChecking` with no TCC state and no OS prompt, for every test
/// target that needs one. `check` and `request` answer from a per-category
/// table, falling back to one status for categories the table leaves out.
/// Every call lands in `calls`, in order, so a test can assert what was
/// asked and when.
///
/// The results are fixed at init; only the call log changes, and it sits
/// behind a lock because the checker is called from whatever task the code
/// under test runs on.
public final class FakePermissionChecker: PermissionChecking {
    public enum Call: Sendable, Equatable {
        case check(TCCCategory)
        case request(TCCCategory)
        case refresh
    }

    private let checkResults: [TCCCategory: PermissionStatus]
    private let checkFallback: PermissionStatus
    private let requestResults: [TCCCategory: PermissionStatus]
    private let requestFallback: PermissionStatus
    private let deepLinks: [TCCCategory: URL]
    private let log = OSAllocatedUnfairLock<[Call]>(initialState: [])

    /// `checkResult` and `requestResult` answer every category the
    /// per-category tables leave out. The defaults describe a Mac that has
    /// asked nothing yet and grants whatever it is asked.
    public init(
        checkResult: PermissionStatus = .notDetermined,
        requestResult: PermissionStatus = .granted,
        checkResults: [TCCCategory: PermissionStatus] = [:],
        requestResults: [TCCCategory: PermissionStatus] = [:],
        deepLinks: [TCCCategory: URL] = [:],
    ) {
        checkFallback = checkResult
        requestFallback = requestResult
        self.checkResults = checkResults
        self.requestResults = requestResults
        self.deepLinks = deepLinks
    }

    public var calls: [Call] {
        log.withLock { $0 }
    }

    public var categoriesRequested: [TCCCategory] {
        calls.compactMap { call in
            if case let .request(category) = call {
                return category
            }
            return nil
        }
    }

    public func check(_ category: TCCCategory) async -> PermissionStatus {
        log.withLock { $0.append(.check(category)) }
        return checkResults[category] ?? checkFallback
    }

    public func request(_ category: TCCCategory) async -> PermissionStatus {
        log.withLock { $0.append(.request(category)) }
        return requestResults[category] ?? requestFallback
    }

    public func refresh() async {
        log.withLock { $0.append(.refresh) }
    }

    public func remediationDeepLink(for category: TCCCategory) -> URL? {
        deepLinks[category]
    }
}
