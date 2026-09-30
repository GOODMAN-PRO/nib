import NibContracts

/// Appearance & app icons (F094: D-078, P-067, P-068, P-113).
///
/// - Settings › General › Appearance: the Liquid choice (Full · Calm · Off, `NibSettings.liquidMode`, written through
///   `settings.set` so plugins, the assistant and the bridge change it the same way), how dark mode treats the page,
///   and the app icon.
/// - Dark mode follows the system; paper and ink are never inverted (`DarkModeAudit`, run in debug builds).
/// - The light, dark and tinted app icons are drawn at build time by Scripts/make_icons.swift into the app's asset
///   catalog, next to the Pool AccentColor.
/// - Liquid Glass and every material come from NibDesign (`.droplet`, `nibGlass`); this module draws none.
///
/// Registers no commands of its own: its one user action is `settings.set {name: "appearance.liquid", value}`.
public enum FeatAppearanceFeature: NibFeature {
    public static let id = "appearance"

    public static func register(_ app: NibApp) {
        app.settings.declare(NibSettings.liquidMode,
                             summary: "Liquid chrome: full, calm (half the stretch, no necks) or off (solid chrome, no motion).",
                             owner: id, schema: LiquidChoice.schema)
        app.ui.settingsPages.register(AppearancePage.descriptor(owner: id))
    }

    public static func start(_ app: NibApp) async {
        #if DEBUG
        if !NibApp.isHostlessTest { DarkModeAudit.startWatching() }
        #endif
    }
}
