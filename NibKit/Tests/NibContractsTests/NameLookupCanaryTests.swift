// Compiles every public NibContracts name UNQUALIFIED next to every framework a feature may import. A clash such as
// Combine.Empty, SwiftUI.Transaction, SwiftUI.ShapeStyle or the iOS 18 Vision RecognizedText only shows up in a
// client module that imports both, so this file must compile before contracts-v1 is tagged (green baseline).
// If a line fails with "is ambiguous for type lookup", rename the contract type (e.g. Point/Rect → PagePoint/PageRect).
import XCTest
import SwiftUI
import UIKit
import Combine
import CoreGraphics
import Vision
import VisionKit
import PDFKit
import PencilKit
import JavaScriptCore
import WebKit
import Network
import Speech
import AVFoundation
import EventKit
import MultipeerConnectivity
import NaturalLanguage
import AppIntents
import Charts
import BackgroundTasks
import UserNotifications
import LocalAuthentication
import PhotosUI
import NibContracts
import NibTesting

enum NameLookupCanary {
    static let types: [Any.Type] = [
        JSONValue.self, NibFormat.self, NibLimits.self, NibID.self, Rev.self,
        HLCClock.self, FractionalIndex.self, RGBA.self, AssetRef.self, Point.self,
        Rect.self, Frame.self, Affine.self, Geo.self, InkTool.self,
        PenStyle.self, StrokePattern.self, InkStyle.self, StrokePoint.self, Stroke.self,
        InkModel.self, TextLink.self, TextAttributes.self, TextRun.self, ParagraphAlignment.self,
        ListKind.self, Paragraph.self, RichText.self, ItemKind.self, ShapeKind.self,
        ShapeItemStyle.self, ShapeItem.self, ConnectorEnd.self, ConnectorRoute.self, ConnectorItem.self,
        TextBoxStyle.self, TextBoxItem.self, ImageItem.self, StickyItem.self, MathItem.self,
        CommentMessage.self, CommentItem.self, DisplayOpKind.self, DisplayOp.self, DisplayList.self,
        CustomItem.self, Item.self, LWW.self, DocumentKind.self, ScrollDirection.self,
        LayerInfo.self, PageSize.self, TemplateRef.self, BackgroundKind.self, Background.self,
        DocumentMeta.self, PageRecord.self, OutlineEntry.self, TranscriptSegment.self, AudioClip.self,
        BlockKind.self, TableCell.self, TableMerge.self, TableData.self, CustomBlock.self,
        BlockComment.self, TextBlock.self, CardFaceKind.self, CardFace.self, SRSState.self,
        StudyCard.self, PagePosition.self, DocumentContent.self, PresetSwatch.self, ToolPresets.self,
        FolderStyle.self, LibraryNodeKind.self, SyncBadge.self, LibraryNode.self, NodeRef.self,
        NibError.self, Principal.self, Effect.self, CommandTarget.self, Scope.self,
        Exposure.self, JSONSchema.self, CommandDescriptor.self, NoResult.self, CommandRegistry.self,
        CommandIDs.self, ChangeSummary.self, Mutation.self, Changeset.self, DocumentPatch.self,
        DocumentPersistence.self, InMemoryPersistence.self, Workspace.self, DocTransaction.self, UndoEntry.self,
        UndoHistory.self, NibEventType.self, NibEvent.self, EventSubscription.self, EventBus.self,
        Invocation.self, CommandHookDescriptor.self, InvocationResult.self, CommandContext.self, CommandBus.self,
        ConfirmationPolicy.self, ConfirmationRequest.self, ConfirmationDecision.self, ConfirmationPresenter.self, Gateway.self,
        Selection.self, ReplayMode.self, ReplayState.self, StylusMode.self, EditorSession.self,
        SessionRegistry.self, LibraryService.self, PackageLocator.self, AssetStore.self, RenderRequest.self,
        RenderResult.self, PageRenderer.self, TextRecognition.self, TextRecognizer.self, PDFLinkInfo.self,
        PDFOutlineNode.self, PDFService.self, LockService.self, NibServices.self, AIMode.self,
        AIScopeKind.self, AIScope.self, AIMessage.self, AIRequest.self, AIUsage.self,
        AIResponse.self, AIStreamEvent.self, AIChatSummary.self, AIService.self, ToolCatalog.self,
        ServiceKeys.self, PluginNetwork.self, PluginCommandContribution.self, PluginWhen.self, PluginMenuContribution.self,
        PluginToolbarContribution.self, PluginToolContribution.self, PluginPanelContribution.self, PluginTemplateContribution.self, PluginKeybinding.self,
        PluginAIAction.self, PluginAIGuidance.self, PluginFileHandler.self, PluginItemType.self, PluginTapHandler.self,
        PluginToolOptions.self, PluginBlockContribution.self, PluginStrokeProcessor.self, PluginPencilAction.self, PluginCommandHook.self,
        PluginElementCollection.self, PluginTapePattern.self, PluginBoardTemplate.self, PluginContributions.self, PluginManifest.self,
        PluginInfo.self, PluginRuntimeHandle.self, PluginRuntimeProviding.self, PluginHosting.self, AIProviderKind.self,
        AIProviderConfig.self, ChatRole.self, ChatPart.self, ChatMessage.self, ToolSpec.self,
        ChatRequest.self, ChatEvent.self, AIProvider.self, AIProviderStore.self, CollabPeer.self,
        CollabTransport.self, SettingKey<Bool>.self, SyncedSettingsBackend.self, SettingDescriptor.self, SettingsStore.self,
        NibSettings.self, SecretStore.self, SystemKeychainStore.self, Keychain.self, DeviceIdentity.self,
        AppGroup.self, Registrable.self, Registry<TemplateDefinition>.self, TemplateParam.self, TemplateRender.self,
        TemplateDefinition.self, DrawContext.self, ItemDrawer.self, ItemDrawerEntry.self, ImportTarget.self,
        ImporterDescriptor.self, ExportRequest.self, ExporterDescriptor.self, AIActionDescriptor.self, StrokeProcessor.self,
        StrokeProcessorEntry.self, KeyModifiers.self, KeyShortcut.self, KeyScope.self, KeyCommandDescriptor.self,
        BackgroundTaskKind.self, BackgroundTaskDescriptor.self, CanvasGesture.self, TapHandlerDescriptor.self, BoardTemplateDescriptor.self,
        TapePatternDescriptor.self, ElementEntry.self, ElementCollectionDescriptor.self, BlockKindDescriptor.self, CustomItemTypeDescriptor.self,
        PencilActionDescriptor.self, ContentRegistries.self, PKBridge.self, RichTextBridge.self, CanvasInputMode.self,
        CanvasSample.self, CanvasHost.self, CanvasTool.self, CanvasAttachment.self, CanvasAttachmentDescriptor.self,
        PencilEventHandler.self, DocumentEditing.self, ToolbarGroup.self, ToolbarItemDescriptor.self, MenuLocation.self,
        MenuContext.self, MenuItemDescriptor.self, PanelPlacement.self, PanelContext.self, PanelDescriptor.self,
        SettingsSection.self, SettingsPageDescriptor.self, InspectorContext.self, InspectorDescriptor.self, ToolMenuDescriptor.self,
        BlockViewContext.self, BlockViewDescriptor.self, PluginPanelFactory.self, CanvasToolDescriptor.self, DocumentEditorDescriptor.self,
        OpenMode.self, SceneNavigator.self, SceneHooks.self, ScreenRegistry.self, UIRegistries.self,
        NibFeature.self, NibApp.self, SafeMode.self, InkOutline.self, FakeCanvasHost.self,
        InMemoryCollabTransport.self
    ]

    /// Protocols with associated types / Self requirements are checked as generic constraints.
    static func constraints<C: NibCommand, R: LWWRecord>(_ command: C.Type, _ record: R.Type) {}
}

/// A SwiftUI view in the same file as commands, the way feature modules are written.
@MainActor
struct CanaryView: View {
    let app: NibApp

    var body: some View {
        Button("Undo") { app.perform(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"]) }
    }
}

@MainActor
struct CanaryCommand: NibCommand {
    struct Params: Codable { var page: String }
    struct Output: Codable { var ok: Bool }
    static let descriptor = CommandDescriptor(id: "canary.check", title: "Canary", summary: "Name lookup canary.",
                                              params: .obj(["page": .ref], required: ["page"]), effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let r: Result<Int, Error> = .success(1)                       // Swift.Result stays usable
        _ = r
        _ = NoResult()
        return Output(ok: true)
    }
}

@MainActor
final class NameLookupCanaryTests: XCTestCase {
    func testEveryContractNameResolves() {
        XCTAssertGreaterThan(NameLookupCanary.types.count, 200)
        NameLookupCanary.constraints(CanaryCommand.self, OutlineEntry.self)
        let h = Harness()
        _ = CanaryView(app: h.app).body
    }
}
