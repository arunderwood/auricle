import Foundation
import Notifications

/// The CLI never posts a system notification, so its composition root always
/// gets the stdout conformer.
func makeCLINotifier(vaultRoot: URL) -> any Notifier {
    StdoutNotifier(vaultRoot: vaultRoot)
}
