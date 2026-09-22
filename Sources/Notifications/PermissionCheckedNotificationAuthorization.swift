import Permissions

/// The `check`-then-maybe-`request`-then-compare-to-`.granted` decision for
/// notification authorization. This depends only on `PermissionChecking`, so
/// unlike `post(_:)` — which really does call `UNUserNotificationCenter` —
/// it doesn't need to live in the untestable `App/` adapter.
public struct PermissionCheckedNotificationAuthorization: Sendable {
    private let permissionChecker: any PermissionChecking

    public init(permissionChecker: any PermissionChecking) {
        self.permissionChecker = permissionChecker
    }

    /// Always refreshes first: a post can happen while auricle is
    /// backgrounded, and `PermissionChecker`'s memo only invalidates on our
    /// own app regaining focus — without this, a grant made in System
    /// Settings while auricle stays backgrounded would leave every
    /// notification silently suppressed by a stale memoized `.denied`.
    public func isAuthorized() async -> Bool {
        await permissionChecker.refresh()
        var status = await permissionChecker.check(.notifications)
        if status == .notDetermined {
            status = await permissionChecker.request(.notifications)
        }
        return status == .granted
    }
}
