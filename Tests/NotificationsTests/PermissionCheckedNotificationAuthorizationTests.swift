import Foundation
@testable import Notifications
import Permissions
import Testing
import TestSupport

struct PermissionCheckedNotificationAuthorizationTests {
    @Test func alreadyGrantedIsAuthorized() async {
        let checker = FakePermissionChecker(checkResult: .granted)
        let authorized = await PermissionCheckedNotificationAuthorization(permissionChecker: checker).isAuthorized()
        #expect(authorized)
        #expect(checker.calls == [.refresh, .check(.notifications)])
    }

    @Test func deniedIsNotAuthorized() async {
        let checker = FakePermissionChecker(checkResult: .denied)
        let authorized = await PermissionCheckedNotificationAuthorization(permissionChecker: checker).isAuthorized()
        #expect(!authorized)
        #expect(checker.calls == [.refresh, .check(.notifications)])
    }

    @Test func notDeterminedRequestsAndFollowsTheResult() async {
        let granted = FakePermissionChecker(checkResult: .notDetermined, requestResult: .granted)
        #expect(await PermissionCheckedNotificationAuthorization(permissionChecker: granted).isAuthorized())
        #expect(granted.calls == [.refresh, .check(.notifications), .request(.notifications)])

        let denied = FakePermissionChecker(checkResult: .notDetermined, requestResult: .denied)
        #expect(await !PermissionCheckedNotificationAuthorization(permissionChecker: denied).isAuthorized())
        #expect(denied.calls == [.refresh, .check(.notifications), .request(.notifications)])
    }

    /// The fix this type exists to preserve: a stale memoized `.denied` from
    /// before a System-Settings grant must not suppress a notification, so
    /// every call has to refresh before it checks.
    @Test func refreshHappensBeforeCheck() async {
        let checker = FakePermissionChecker(checkResult: .granted)
        _ = await PermissionCheckedNotificationAuthorization(permissionChecker: checker).isAuthorized()
        #expect(checker.calls.first == .refresh)
    }
}
