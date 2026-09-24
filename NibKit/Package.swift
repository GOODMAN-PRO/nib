// swift-tools-version:5.10
// GENERATED from docs/forge-spec.json (module list). Edit the spec, not this file, when adding a module.
import PackageDescription

let zip: Target.Dependency = .product(name: "ZIPFoundation", package: "ZIPFoundation")
let swiftMath: Target.Dependency = .product(name: "SwiftMath", package: "SwiftMath")
// Reserved design system (tokens, droplet/"liquid" components, Metal shaders), filled by a later design stage.
// Every ui/fullstack feature module depends on it; core modules do not (ARCHITECTURE.md §3).
let design: Target.Dependency = "NibDesign"

struct Module {
    let name: String
    var deps: [Target.Dependency] = []
    var resources: [Resource] = []
    var testResources: [Resource] = []
}

let modules: [Module] = [
    Module(name: "NibStore"),
    Module(name: "NibLibrary"),
    Module(name: "FeatQuery"),
    Module(name: "NibRender"),
    Module(name: "NibTemplates"),
    Module(name: "FeatCanvas", deps: [design]),
    Module(name: "FeatPen", deps: [design]),
    Module(name: "FeatPresets", deps: [design]),
    Module(name: "FeatHighlighter", deps: [design]),
    Module(name: "FeatEraser", deps: [design]),
    Module(name: "FeatLasso", deps: [design]),
    Module(name: "FeatTransform", deps: [design]),
    Module(name: "FeatObjectMenu", deps: [design]),
    Module(name: "FeatClipboard", deps: [design]),
    Module(name: "FeatUndoUI", deps: [design]),
    Module(name: "FeatToolbar", deps: [design]),
    Module(name: "FeatDocChrome", deps: [design]),
    Module(name: "FeatWindows", deps: [design]),
    Module(name: "FeatLibraryUI", deps: [design]),
    Module(name: "FeatLibraryOrganize", deps: [design]),
    Module(name: "FeatCreate", deps: [design]),
    Module(name: "FeatPages", deps: [design]),
    Module(name: "FeatSidebar", deps: [design]),
    Module(name: "NibPDF"),
    Module(name: "NibSync"),
    Module(name: "FeatTextBox", deps: [design]),
    Module(name: "FeatSettings", deps: [design]),
    Module(name: "FeatPageText", deps: [design]),
    Module(name: "FeatLinks", deps: [design]),
    Module(name: "FeatShapeRecognition", deps: [design]),
    Module(name: "FeatShapes", deps: [design]),
    Module(name: "FeatDiagrams", deps: [design]),
    Module(name: "FeatTape", deps: [design]),
    Module(name: "FeatImages", deps: [design]),
    Module(name: "FeatElements", deps: [design, zip]),
    Module(name: "FeatSticky", deps: [design]),
    Module(name: "FeatComments", deps: [design]),
    Module(name: "FeatZoomWindow", deps: [design]),
    Module(name: "FeatRuler", deps: [design]),
    Module(name: "FeatLaser", deps: [design]),
    Module(name: "FeatLayers", deps: [design]),
    Module(name: "FeatReadOnly", deps: [design]),
    Module(name: "FeatPencilHardware", deps: [design]),
    Module(name: "FeatWhiteboard", deps: [design]),
    Module(name: "FeatTemplateUI", deps: [design]),
    Module(name: "FeatOutline", deps: [design]),
    Module(name: "FeatTextDoc", deps: [design]),
    Module(name: "FeatTextDocTables", deps: [design]),
    Module(name: "FeatStudyEditor", deps: [design]),
    Module(name: "FeatStudySession", deps: [design]),
    Module(name: "FeatStudyIO"),
    Module(name: "FeatAudio", deps: [design]),
    Module(name: "FeatReplay", deps: [design]),
    Module(name: "FeatTranscription", deps: [design]),
    Module(name: "NibIndex"),
    Module(name: "FeatSearchUI", deps: [design]),
    Module(name: "FeatConvertText", deps: [design]),
    Module(name: "FeatSmartInk", deps: [design]),
    Module(name: "FeatInkSynth", deps: [design]),
    Module(name: "FeatMath", deps: [design, swiftMath]),
    Module(name: "FeatMathAssist", deps: [design]),
    Module(name: "FeatTimeKeeper", deps: [design]),
    Module(name: "FeatPresentation", deps: [design]),
    Module(name: "FeatImport", deps: [design, zip]),
    Module(name: "FeatScan", deps: [design]),
    Module(name: "NibExport", deps: [zip]),
    Module(name: "FeatExportUI", deps: [design]),
    Module(name: "FeatBackup", deps: [design, zip]),
    Module(name: "FeatWebDAV"),
    Module(name: "FeatSyncUI", deps: [design]),
    Module(name: "FeatLock", deps: [design]),
    Module(name: "FeatCollab", deps: [design, zip]),
    Module(name: "FeatKeyboard", deps: [design]),
    Module(name: "FeatSystemIntegration", deps: [design]),
    Module(name: "FeatCalendar", deps: [design]),
    Module(name: "FeatDiagnostics", deps: [design]),
    Module(name: "NibPluginRuntime", resources: [.copy("Resources/prelude.js")]),
    Module(name: "NibPluginHost"),
    Module(name: "FeatPluginInstall", deps: [design, zip]),
    Module(name: "FeatPluginManager", deps: [design]),
    Module(name: "FeatPluginPanels", deps: [design]),
    Module(name: "NibAIProviders", testResources: [.copy("Fixtures")]),
    Module(name: "NibAIAgent"),
    Module(name: "FeatAIChat", deps: [design]),
    Module(name: "FeatAISettings", deps: [design]),
    Module(name: "FeatAIActions"),
    Module(name: "FeatAIMath", deps: [design]),
    Module(name: "FeatMeetingAI", deps: [design]),
    Module(name: "NibBridge"),
    Module(name: "FeatBridgeUI", deps: [design]),
    Module(name: "FeatRelay"),
    Module(name: "FeatOnboarding", deps: [design]),
    Module(name: "FeatAppearance", deps: [design]),
    Module(name: "FeatA11y", deps: [design]),
    Module(name: "FeatManagedConfig"),
    Module(name: "FeatAbout", deps: [design]),
    Module(name: "FeatTeacher", deps: [design]),
    Module(name: "FeatPerformance"),
]

var targets: [Target] = [
    .target(name: "NibContracts"),
    .target(name: "NibDesign"),
    .target(name: "NibTesting", dependencies: ["NibContracts"]),
    .testTarget(name: "NibContractsTests", dependencies: ["NibContracts", "NibTesting"]),
    .testTarget(name: "ConformanceTests",
                dependencies: ["NibContracts", "NibTesting"] + modules.map { Target.Dependency.target(name: $0.name) }),
    // Example plugins call doc.create, card.add, ink.writeText, panels and nib.ai, so they run against every module
    // (with NibTesting's FakeAIService); cross-feature acceptance scenarios live in IntegrationTests (F111).
    .testTarget(name: "ExamplePluginsTests",
                dependencies: ["NibContracts", "NibTesting"] + modules.map { Target.Dependency.target(name: $0.name) }),
    .testTarget(name: "IntegrationTests",
                dependencies: ["NibContracts", "NibTesting"] + modules.map { Target.Dependency.target(name: $0.name) }),
]

for m in modules {
    targets.append(.target(name: m.name, dependencies: ["NibContracts"] + m.deps,
                           resources: m.resources.isEmpty ? nil : m.resources))
    targets.append(.testTarget(name: m.name + "Tests",
                               dependencies: [.target(name: m.name), "NibContracts", "NibTesting"],
                               resources: m.testResources.isEmpty ? nil : m.testResources))
}

let package = Package(
    name: "NibKit",
    platforms: [.iOS(.v17)],
    // Two products, so Xcode always generates the aggregate "NibKit-Package" scheme CI tests with.
    products: [.library(name: "NibKit", targets: ["NibContracts", "NibDesign"] + modules.map { $0.name }),
               .library(name: "NibTesting", targets: ["NibTesting"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.0.0"),
    ],
    targets: targets
)
