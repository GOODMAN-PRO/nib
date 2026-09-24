import SwiftUI
import Observation

/// Settings › Appearance › Liquid. Calm halves every stretch cap and drops necks; Off uses the Reduce Motion and
/// Reduce Transparency fallbacks whatever the system settings say.
public enum NibLiquidMode: String, CaseIterable, Sendable {
    case full, calm, off
}

public enum NibLiquid {
    /// The coordinate space every droplet, drag and bud uses. `NibDropletContainer` defines it.
    public static let space = NamedCoordinateSpace.named("nib.droplets")
    /// Opacity of a receding droplet while the Pencil is down.
    public static let recedeOpacity: Double = 0.22
    /// A droplet within this distance of the stroke's bounds recedes even when it is off the page (DESIGN.md §10.8).
    public static let recedeReach: CGFloat = 24
}

/// The Pencil state. The canvas delegate writes it (begin/end using tool, and the stroke's bounds in the container's
/// coordinates as the stroke grows); only `NibDropletContainer(inking:)` reads it, so a Pencil down or up never
/// re-evaluates the editor's body at the moment the first ink frame is produced.
@Observable
public final class NibInkingState {
    public var isInking = false
    /// The current stroke's bounds, `.null` between strokes.
    public var strokeBounds: CGRect = .null

    public init() {}
}

/// Merge geometry per size class (DESIGN.md §10.4). `minimumNeck` is the thinnest bridge the field threshold can hold,
/// so a neck's logical break and its visual pinch land on the same frame.
public struct DropletMetrics: Equatable, Sendable {
    public var mergeDistance: CGFloat
    public var fieldBlur: CGFloat
    public var iso: Float
    public var budNeckOff: CGFloat

    public static let regular = DropletMetrics(mergeDistance: 11, fieldBlur: 8, iso: 0.479, budNeckOff: 21)
    public static let compact = DropletMetrics(mergeDistance: 9, fieldBlur: 6.5, iso: 0.479, budNeckOff: 17)

    public var minimumNeck: CGFloat { 1.27 * fieldBlur + 0.6 }
}

private struct NibLiquidModeKey: EnvironmentKey {
    static let defaultValue: NibLiquidMode = .full
}

private struct NibIsInkingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NibBackdropKey: EnvironmentKey {
    static let defaultValue: [CGRect] = []
}

private struct NibDropletIsLiftedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NibGlassNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

struct NibBudRequest {
    let source: String
    let isPresented: Binding<Bool>
    let instant: Bool
}

private struct NibBudKey: EnvironmentKey {
    static let defaultValue: NibBudRequest? = nil
}

public extension EnvironmentValues {
    var nibLiquidMode: NibLiquidMode {
        get { self[NibLiquidModeKey.self] }
        set { self[NibLiquidModeKey.self] = newValue }
    }

    /// True for content of a droplet that is being dragged (covers hide their titles, shadows deepen).
    var nibDropletIsLifted: Bool {
        get { self[NibDropletIsLiftedKey.self] }
        set { self[NibDropletIsLiftedKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// Set by the container while backdrop sampling is frozen (the Pencil is down): glass becomes `.identity`, frost
    /// is not drawn.
    var nibIsInking: Bool {
        get { self[NibIsInkingKey.self] }
        set { self[NibIsInkingKey.self] = newValue }
    }

    var nibBackdrop: [CGRect] {
        get { self[NibBackdropKey.self] }
        set { self[NibBackdropKey.self] = newValue }
    }

    var nibGlassNamespace: Namespace.ID? {
        get { self[NibGlassNamespaceKey.self] }
        set { self[NibGlassNamespaceKey.self] = newValue }
    }

    var nibBud: NibBudRequest? {
        get { self[NibBudKey.self] }
        set { self[NibBudKey.self] = newValue }
    }
}

public extension View {
    /// The app root passes the Appearance › Liquid setting here.
    func nibLiquidMode(_ mode: NibLiquidMode) -> some View { environment(\.nibLiquidMode, mode) }

    /// The frames of light paper (luminance > 0.6) under the container, in its coordinates: the editor passes its
    /// visible pages, never dark papers. Droplets over them get edge and caustic (DESIGN.md §3.3), dark-mode Clear
    /// thickens to 80 %, and they recede while the Pencil is down.
    func nibBackdrop(_ pages: [CGRect]) -> some View { environment(\.nibBackdrop, pages) }
}
