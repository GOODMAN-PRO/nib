import UIKit

/// An opaque confirmation in the editor's view hierarchy. Both actions are real controls in every size class;
/// this does not depend on a modal presenter, a popover's implicit Cancel, or an application singleton.
public final class NibConfirmationPanel: UIView {
    private let panel = UIView()
    private let textScroll = UIScrollView()
    private let heading = UILabel()
    private let message = UILabel()
    private let cancel = UIButton(type: .system)
    private let confirm = UIButton(type: .system)
    private var decision: ((Bool) -> Void)?

    public init(title: String, message: String, confirmTitle: String, onDecision: @escaping (Bool) -> Void) {
        decision = onDecision
        super.init(frame: .zero)
        backgroundColor = NibUIColor.scrim
        accessibilityViewIsModal = true
        panel.backgroundColor = NibUIColor.backgroundSecondary
        panel.layer.cornerRadius = NibRadius.sheet
        panel.layer.cornerCurve = .continuous
        addSubview(panel)
        panel.addSubview(textScroll)
        heading.text = title
        heading.accessibilityTraits.insert(.header)
        self.message.text = message
        for label in [heading, self.message] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            textScroll.addSubview(label)
        }
        configure(cancel, title: String(localized: "Cancel", bundle: .module), destructive: false)
        configure(confirm, title: confirmTitle, destructive: true)
        cancel.accessibilityIdentifier = "confirmation.cancel"
        confirm.accessibilityIdentifier = "confirmation.confirm"
        cancel.addAction(UIAction { [weak self] _ in self?.finish(confirmed: false) }, for: .touchUpInside)
        confirm.addAction(UIAction { [weak self] _ in self?.finish(confirmed: true) }, for: .touchUpInside)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: NibConfirmationPanel, _: UITraitCollection) in view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure(_ button: UIButton, title: String, destructive: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = destructive ? NibUIColor.destructive : NibUIColor.accent
        configuration.background.backgroundColor = destructive ? NibUIColor.fill3 : .clear
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: NibSpacing.s, leading: NibSpacing.l,
                                                               bottom: NibSpacing.s, trailing: NibSpacing.l)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak button] attributes in
            var attributes = attributes
            (button?.traitCollection ?? .current).performAsCurrent { attributes.font = NibUIFont.button }
            return attributes
        }
        button.configuration = configuration
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        panel.addSubview(button)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        heading.font = NibUIFont.title3
        heading.textColor = NibUIColor.label
        message.font = NibUIFont.body
        message.textColor = NibUIColor.labelSecondary
        let available = safeAreaLayoutGuide.layoutFrame.insetBy(dx: NibSpacing.l, dy: NibSpacing.l)
        let preferredWidth = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            ? NibMetrics.panelWidthAccessibility : NibMetrics.panelWidth
        let width = max(0, min(preferredWidth, available.width))
        let innerWidth = max(0, width - NibSpacing.xl * 2)
        let fitting = CGSize(width: innerWidth, height: .greatestFiniteMagnitude)
        let titleHeight = heading.sizeThatFits(fitting).height
        let messageHeight = message.sizeThatFits(fitting).height
        let textHeight = titleHeight + NibSpacing.m + messageHeight
        let cancelHeight = max(NibMetrics.hitTarget, cancel.sizeThatFits(fitting).height)
        let confirmHeight = max(NibMetrics.hitTarget, confirm.sizeThatFits(fitting).height)
        let actionsHeight = confirmHeight + NibSpacing.s + cancelHeight
        let height = min(available.height, textHeight + actionsHeight + NibSpacing.xl * 3)
        panel.frame = CGRect(x: available.midX - width / 2, y: available.midY - height / 2,
                             width: width, height: height)
        let visibleTextHeight = max(0, height - actionsHeight - NibSpacing.xl * 3)
        textScroll.frame = CGRect(x: NibSpacing.xl, y: NibSpacing.xl, width: innerWidth, height: visibleTextHeight)
        heading.frame = CGRect(x: 0, y: 0, width: innerWidth, height: titleHeight)
        message.frame = CGRect(x: 0, y: titleHeight + NibSpacing.m, width: innerWidth, height: messageHeight)
        textScroll.contentSize = CGSize(width: innerWidth, height: textHeight)
        confirm.frame = CGRect(x: NibSpacing.xl, y: textScroll.frame.maxY + NibSpacing.xl,
                               width: innerWidth, height: confirmHeight)
        cancel.frame = CGRect(x: NibSpacing.xl, y: confirm.frame.maxY + NibSpacing.s,
                              width: innerWidth, height: cancelHeight)
    }

    /// Drop callbacks even when the owning editor disappears without a button press.
    public func invalidate() { decision = nil }

    private func finish(confirmed: Bool) {
        let callback = decision
        decision = nil
        callback?(confirmed)
    }

    @objc private func cancelPressed() { finish(confirmed: false) }

    public override func accessibilityPerformEscape() -> Bool {
        finish(confirmed: false)
        return true
    }

    public override var canBecomeFirstResponder: Bool { true }
    public override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelPressed))]
    }
}
