import UIKit

/// Principal class of the share extension (NSExtensionPrincipalClass). Placeholder: completes immediately (F064).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
