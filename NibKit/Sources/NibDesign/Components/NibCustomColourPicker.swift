import SwiftUI

/// The native colour-ring row shared by pen and highlighter settings.
/// Keep the visible title as the accessibility label so callers can locate Custom….
public struct NibCustomColourPicker: View {
    let title: String
    @Binding private var selection: Color

    public init(_ title: String, selection: Binding<Color>) {
        self.title = title
        self._selection = selection
    }

    public var body: some View {
        ColorPicker(title, selection: $selection, supportsOpacity: false)
            .font(NibFont.body)
            .foregroundStyle(NibColor.label)
            .frame(minHeight: NibMetrics.hitTarget)
    }
}
