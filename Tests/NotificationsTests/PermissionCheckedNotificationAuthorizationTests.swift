import Foundation
@testable import Notifications
import os
import Permissions
import Testing

private struct FakePermissionCheckerState {
    let checkResult: PermissionStatus
    let requestResult: PermissionStatus
    var calls: [String] = []
}

private final class FakePermissionChecker: PermissionChecking {
    private let state: OSAllocatedUnfairLock<FakePermissionCheckerState>

    init(checkResult: PermissionStatus, requestResult: PermissionStatus = .granted) {
        state = OSAllocatedUnfairLock(initialState: FakePermissionCheckerState(checkResult: checkResult, requestResult: requestResult))
    }

    var calls: [String] {
        state.withLock { $0.calls }
    }

    func check(_: TCCCategory) async -> PermissionStatus {
        state.withLock {
            $0.calls.append("check")
            return $0.checkResult
        }
    }

    func request(_: TCCCategory) async -> PermissionStatus {
        state.withLock {
            $0.calls.append("request")
            return $0.requestResult
        }
    }

    func refresh() async {
        state.withLock { $0.calls.append("refresh") }
    }

    func remediationDeepLink(for _: TCCCategory) -> URL? {
        nil
    }
}

struct PermissionCheckedNotificationAuthorizationTests {
    @Test func alreadyGrantedIsAuthorized() async {
        let checker = FakePermissionChecker(checkResult: .granted)
        let authorized = await PermissionCheckedNotificationAuthorization(permissionChecker: checker).isAuthorized()
        #expect(authorized)
        #expect(checker.calls == ["refresh", "check"])
    }

    @Test func deniedIsNotAuthorized() async {
        let checker = FakePermissionChecker(checkResult: .denied)
        let authorized = await PermissionCheckedNotificationAuthorization(permissionChecker: checker).isAuthorized()
        #expect(!authorized)
        #expect(checker.calls == ["refresh", "check"])
    }

    @Test func notDeterminedRequestsAndFollowsTheResult() async {
        let granted = FakePermissionChecker(checkResult: .notDetermined, requestResult: .granted)
        #expect(await PermissionCheckedNotificationAuthorization(permissionChecker: granted).isAuthorized())
        #expect(granted.calls == ["refresh", "check", "request"])

        let denied = FakePermissionChecker(checkResult: .notDetermined, requestResult: .denied)
        #expect(await !PermissionCheckedNotificationAuthorization(permissionChecker: denied).isAuthorized())
        #expect(denied.calls == ["refresh", "check", "request"])
    }

    /// The fix this type exists to preserve: a stale memoized `.denied` from
    /// before a System-Settings grant must not suppress a notification, so
    /// every call has to refresh before it checks.
    @Test func refreshHappensBeforeCheck() async {
        let checker = FakePermissionChecker(checkResult: .granted)
        _ = await PermissionCheckedNotificationAuthorization(permissionChecker: checker).isAuthorized()
        #expect(checker.calls.first == "refresh")
    }
}
