import NibContracts

public enum FeatReadOnlyFeature: NibFeature {
    public static let id = "readonly"
    public static func register(_ app: NibApp) {}
}
