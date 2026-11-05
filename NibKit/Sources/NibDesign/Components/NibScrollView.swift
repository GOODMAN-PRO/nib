import SwiftUI

/// A bounded list with a persistent overflow cue outside its controls. Native indicators
/// disappear at rest; fading the last row alone can look like a damaged label or switch.
/// Use one axis, and give the content its usual stack and insets.
public struct NibScrollView<Content: View>: View {
    private let axis: Axis
    private let content: Content
    @Namespace private var scrollSpace
    @State private var contentFrame = CGRect.zero
    @State private var viewport = CGSize.zero
    @State private var scrollSize = CGSize.zero
    @Environment(\.layoutDirection) private var direction

    public init(_ axis: Axis = .vertical, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.content = content()
    }

    public var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 0) {
                    scroller
                    if overflows { cue.frame(height: NibSpacing.l) }
                }
            } else {
                HStack(spacing: 0) {
                    scroller
                    if overflows { cue.frame(width: NibSpacing.l) }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
    }

    private var overflows: Bool {
        NibScrollOverflow.exceeds(content: axis == .vertical ? contentFrame.height : contentFrame.width,
                                  viewport: axis == .vertical ? viewport.height : viewport.width)
    }

    private var hasMore: Bool {
        if axis == .vertical { return contentFrame.maxY > scrollSize.height + 1 }
        return direction == .rightToLeft ? contentFrame.minX < -1 : contentFrame.maxX > scrollSize.width + 1
    }

    private var scroller: some View {
        ScrollView(axis == .vertical ? .vertical : .horizontal) {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(scrollSpace)) } action: { contentFrame = $0 }
        }
        .coordinateSpace(name: scrollSpace)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { scrollSize = $0 }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(trigger: overflows)
    }

    private var cue: some View {
        Image(nib: .chevronDown)
            .font(NibFont.caption1Emphasis)
            .foregroundStyle(NibColor.labelSecondary)
            .rotationEffect(.degrees(cueAngle))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var cueAngle: Double {
        if axis == .vertical { return hasMore ? 0 : 180 }
        let forward = direction == .rightToLeft ? 90.0 : -90.0
        return hasMore ? forward : forward + 180
    }
}

enum NibScrollOverflow {
    static func exceeds(content: CGFloat, viewport: CGFloat) -> Bool {
        content.isFinite && viewport.isFinite && viewport > 0 && content > viewport + 1
    }
}
