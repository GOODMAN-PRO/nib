import NibContracts

public enum FeatCanvasInputFeature: NibFeature {
    public static let id = "canvasinput"

    public static func register(_ app: NibApp) {
        CanvasInputHooks.install = { host in
            let input = WetInkController(host: host)
            host.inputController = input
            input.install()
        }
    }
}
