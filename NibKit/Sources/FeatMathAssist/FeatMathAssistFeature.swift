import NibContracts

/// The on-device maths engine (F061): `math.evaluate`. No UI of its own; the Math Assist overlay and graphs in this
/// module build on `MathEngine`.
public enum FeatMathAssistFeature: NibFeature {
    public static let id = "mathassist"

    public static func register(_ app: NibApp) {
        app.commands.register(MathEvaluate.self)
    }
}
