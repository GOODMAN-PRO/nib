import SwiftUI
import UIKit

/// A continuous timeline uses a real native slider so assistive input receives
/// both the adjustable value and the on-screen track's endpoints.
public struct NibTimelineSlider: UIViewRepresentable {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let label: String
    private let spokenValue: String

    public init(value: Binding<Double>, in range: ClosedRange<Double>, label: String, spokenValue: String) {
        self._value = value
        self.range = range
        self.label = label
        self.spokenValue = spokenValue
    }

    public func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    public func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.isContinuous = true
        slider.minimumTrackTintColor = NibUIColor.label
        slider.maximumTrackTintColor = NibUIColor.fill1
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return slider
    }

    public func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.value = $value
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(min(max(value, range.lowerBound), range.upperBound))
        slider.accessibilityLabel = label
        slider.accessibilityValue = spokenValue
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        CGSize(width: max(NibMetrics.hitTarget, proposal.width ?? NibMetrics.hitTarget), height: NibMetrics.hitTarget)
    }

    public final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ slider: UISlider) { value.wrappedValue = Double(slider.value) }
    }
}
