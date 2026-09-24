// GENERATED from docs/forge-spec.json. Registration order = this order (services first; the second half of a
// split feature right after its first half).
import NibContracts
import NibStore
import NibLibrary
import FeatQuery
import NibRender
import NibTemplates
import FeatCanvas
import FeatPen
import FeatPresets
import FeatHighlighter
import FeatEraser
import FeatLasso
import FeatTransform
import FeatObjectMenu
import FeatClipboard
import FeatUndoUI
import FeatToolbar
import FeatDocChrome
import FeatWindows
import FeatLibraryUI
import FeatLibraryOrganize
import FeatCreate
import FeatPages
import FeatSidebar
import NibPDF
import NibSync
import FeatTextBox
import FeatSettings
import FeatPageText
import FeatLinks
import FeatShapeRecognition
import FeatShapes
import FeatDiagrams
import FeatTape
import FeatImages
import FeatElements
import FeatSticky
import FeatComments
import FeatZoomWindow
import FeatRuler
import FeatLaser
import FeatLayers
import FeatReadOnly
import FeatPencilHardware
import FeatWhiteboard
import FeatTemplateUI
import FeatOutline
import FeatTextDoc
import FeatTextDocTables
import FeatStudyEditor
import FeatStudySession
import FeatStudyIO
import FeatAudio
import FeatReplay
import FeatTranscription
import NibIndex
import FeatSearchUI
import FeatConvertText
import FeatSmartInk
import FeatInkSynth
import FeatMath
import FeatMathAssist
import FeatTimeKeeper
import FeatPresentation
import FeatImport
import FeatScan
import NibExport
import FeatExportUI
import FeatBackup
import FeatWebDAV
import FeatSyncUI
import FeatLock
import FeatCollab
import FeatKeyboard
import FeatSystemIntegration
import FeatCalendar
import FeatDiagnostics
import NibPluginRuntime
import NibPluginHost
import FeatPluginInstall
import FeatPluginManager
import FeatPluginPanels
import NibAIProviders
import NibAIAgent
import FeatAIChat
import FeatAISettings
import FeatAIActions
import FeatAIMath
import FeatMeetingAI
import NibBridge
import FeatBridgeUI
import FeatRelay
import FeatOnboarding
import FeatAppearance
import FeatA11y
import FeatManagedConfig
import FeatAbout
import FeatTeacher
import FeatPerformance

enum FeatureList {
    static let all: [NibFeature.Type] = [
        NibStoreFeature.self,
        NibLibraryFeature.self,
        FeatQueryFeature.self,
        NibRenderFeature.self,
        NibTemplatesFeature.self,
        FeatCanvasFeature.self,
        FeatCanvasInputFeature.self,
        FeatPenFeature.self,
        FeatPresetsFeature.self,
        FeatHighlighterFeature.self,
        FeatEraserFeature.self,
        FeatLassoFeature.self,
        FeatTransformFeature.self,
        FeatObjectMenuFeature.self,
        FeatClipboardFeature.self,
        FeatUndoUIFeature.self,
        FeatToolbarFeature.self,
        FeatDocChromeFeature.self,
        FeatWindowsFeature.self,
        FeatLibraryUIFeature.self,
        FeatLibraryOrganizeFeature.self,
        FeatCreateFeature.self,
        FeatPagesFeature.self,
        FeatSidebarFeature.self,
        NibPDFFeature.self,
        NibSyncFeature.self,
        FeatTextBoxFeature.self,
        FeatSettingsFeature.self,
        FeatPageTextFeature.self,
        FeatLinksFeature.self,
        FeatShapeRecognitionFeature.self,
        FeatShapesFeature.self,
        FeatDiagramsFeature.self,
        FeatTapeFeature.self,
        FeatImagesFeature.self,
        FeatElementsFeature.self,
        FeatStickyFeature.self,
        FeatCommentsFeature.self,
        FeatZoomWindowFeature.self,
        FeatRulerFeature.self,
        FeatLaserFeature.self,
        FeatLayersFeature.self,
        FeatReadOnlyFeature.self,
        FeatPencilHardwareFeature.self,
        FeatWhiteboardFeature.self,
        FeatTemplateUIFeature.self,
        FeatOutlineFeature.self,
        FeatTextDocFeature.self,
        FeatTextDocEditingFeature.self,
        FeatTextDocExtrasFeature.self,
        FeatTextDocTablesFeature.self,
        FeatStudyEditorFeature.self,
        FeatStudySessionFeature.self,
        FeatStudyIOFeature.self,
        FeatAudioFeature.self,
        FeatReplayFeature.self,
        FeatTranscriptionFeature.self,
        NibIndexFeature.self,
        FeatSearchUIFeature.self,
        FeatConvertTextFeature.self,
        FeatSmartInkFeature.self,
        FeatInkSynthFeature.self,
        FeatSpellcheckFeature.self,
        FeatRestyleFeature.self,
        FeatMathFeature.self,
        FeatMathAssistFeature.self,
        FeatMathAssistOverlayFeature.self,
        FeatMathGraphFeature.self,
        FeatTimeKeeperFeature.self,
        FeatPresentationFeature.self,
        FeatImportFeature.self,
        FeatScanFeature.self,
        NibExportFeature.self,
        FeatExportUIFeature.self,
        FeatBackupFeature.self,
        FeatWebDAVFeature.self,
        FeatSyncUIFeature.self,
        FeatLockFeature.self,
        FeatCollabFeature.self,
        FeatCollabPresenceFeature.self,
        FeatKeyboardFeature.self,
        FeatSystemIntegrationFeature.self,
        FeatCalendarFeature.self,
        FeatDiagnosticsFeature.self,
        NibPluginRuntimeFeature.self,
        NibPluginHostFeature.self,
        FeatPluginInstallFeature.self,
        FeatPluginManagerFeature.self,
        FeatPluginPanelsFeature.self,
        NibAIProvidersFeature.self,
        NibAIAgentFeature.self,
        FeatAIChatFeature.self,
        FeatAISettingsFeature.self,
        FeatAIActionsFeature.self,
        FeatAIMathFeature.self,
        FeatMeetingAIFeature.self,
        NibBridgeFeature.self,
        FeatBridgeUIFeature.self,
        FeatRelayFeature.self,
        FeatOnboardingFeature.self,
        FeatAppearanceFeature.self,
        FeatA11yFeature.self,
        FeatManagedConfigFeature.self,
        FeatAboutFeature.self,
        FeatTeacherFeature.self,
        FeatTeacherLessonsFeature.self,
        FeatTeacherInsightsFeature.self,
        FeatPerformanceFeature.self
    ]
}
