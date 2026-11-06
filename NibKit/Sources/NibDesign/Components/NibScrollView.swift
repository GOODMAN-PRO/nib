import SwiftUI

/// A bounded list with a persistent overflow cue outside its controls. Native indicators
/// disappear at rest; fading the last row alone can look like a damaged label or switch.
/// Use one axis, and give the content its usual stack and insets.
public struct NibScrollView<Content: View>: View {
    private let axis: Axis
    private let label: String?
    private let content: Content
    @Namespace private var scrollSpace
    @State private var contentSize = CGSize.zero
    @State private var hasMore = false
    @State private var viewport = CGSize.zero
    @State private var scrollSize = CGSize.zero
    @Environment(\.layoutDirection) private var direction

    /// - Parameter label: names the scroll view itself for accessibility. A popover passes its title, so the title
    ///   stays on the scroll view as it was before the cue lane existed; a label on a view around the scroller and
    ///   the cue would become a second, anonymous container instead.
    public init(_ axis: Axis = .vertical, label: String? = nil, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.label = label
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
        NibScrollOverflow.exceeds(content: axis == .vertical ? contentSize.height : contentSize.width,
                                  viewport: axis == .vertical ? viewport.height : viewport.width)
    }

    private var scroller: some View {
        ScrollView(axis == .vertical ? .vertical : .horizontal) {
            content
                .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
                .onGeometryChange(for: Bool.self) { proxy in
                    NibScrollOverflow.hasMore(contentFrame: proxy.frame(in: .named(scrollSpace)),
                                              viewport: scrollSize, axis: axis, direction: direction)
                } action: { hasMore = $0 }
        }
        .coordinateSpace(name: scrollSpace)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { scrollSize = $0 }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(trigger: overflows)
        .nibScrollLabel(label)
    }

    private var cue: some View {
        // A drawn chevron, not a symbol image. An image is an accessibility element of its own: VoiceOver read
        // this one as "Go Down", hiding it did not take it out of the tree, and once the panel's title moved to
        // the scroller its frame grew to the whole panel and covered the rows (UI run 42116137406, Canvas class).
        NibScrollCue()
            .stroke(NibColor.labelSecondary, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            .frame(width: 10, height: 5)
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

/// The overflow cue: a chevron pointing down in its own bounds.
private struct NibScrollCue: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private extension View {
    @ViewBuilder func nibScrollLabel(_ label: String?) -> some View {
        if let label {
            accessibilityElement(children: .contain).accessibilityLabel(label)
        } else {
            self
        }
    }
}

enum NibScrollOverflow {
    static func hasMore(contentFrame: CGRect, viewport: CGSize, axis: Axis, direction: LayoutDirection) -> Bool {
        if axis == .vertical { return contentFrame.maxY > viewport.height + 1 }
        return direction == .rightToLeft ? contentFrame.minX < -1 : contentFrame.maxX > viewport.width + 1
    }

    static func exceeds(content: CGFloat, viewport: CGFloat) -> Bool {
        content.isFinite && viewport.isFinite && viewport > 0 && content > viewport + 1
    }
}
