import SwiftUI
import UIKit
import Vision
import VisionKit
import NibContracts
import NibDesign

// The QR reader: DataScannerViewController full screen (the camera is this screen's page), with Nib's chrome floating
// over it in the screen's one droplet container: a Clear bar (Close, title) and, once a code is read, a Deep panel
// that shows the code in full and asks before anything opens. Nothing opens by itself.

enum QRCameraProblem: Equatable {
    /// Camera access is off (or restricted) for Nib.
    case denied
    /// The camera is busy or cannot scan right now.
    case unavailable
}

/// Presents the reader and waits for it: the code the person chose to open, or nil when they closed it.
@MainActor
enum QRScannerSession {
    static func run(from presenter: UIViewController, problem: QRCameraProblem?, liquidMode: String) async -> String? {
        await withCheckedContinuation { continuation in
            let model = QRScannerModel(problem: problem)
            // A presented controller does not inherit the app root's environment: pass the Appearance › Liquid
            // setting on, so the reader's container keeps (and never overrides) the app-wide Liquid mode.
            let liquid = NibLiquidMode(rawValue: liquidMode) ?? .full
            let host = UIHostingController(rootView: QRScannerScreen(model: model).nibLiquidMode(liquid))
            host.modalPresentationStyle = .fullScreen
            model.onFinish = { [weak host] result in
                // Return once the reader is gone, so whatever opens next (a notebook, Safari) is not under it.
                guard let host, host.presentingViewController != nil, !host.isBeingDismissed else {
                    continuation.resume(returning: result)
                    return
                }
                host.dismiss(animated: true) { continuation.resume(returning: result) }
            }
            presenter.present(host, animated: true)
        }
    }
}

/// The reader's state: the code on screen, what the camera can do, and the one-shot result.
@MainActor
final class QRScannerModel: ObservableObject {
    @Published private(set) var code: QRPayload?
    @Published var problem: QRCameraProblem?
    /// Called exactly once, with the code to open or nil.
    var onFinish: ((String?) -> Void)?

    init(problem: QRCameraProblem?) {
        self.problem = problem
    }

    /// A code came into view (or was tapped): it replaces the one on screen. True when the panel changed.
    @discardableResult
    func found(_ raw: String?) -> Bool {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let payload = QRPayload(raw)
        guard payload != code else { return false }
        code = payload
        return true
    }

    /// Puts the code away and keeps reading (the panel's Close).
    func dismissCode() {
        code = nil
    }

    /// Opens (or copies) the code on screen.
    func confirm() {
        guard let code else { return }
        finish(code.raw)
    }

    func finish(_ result: String?) {
        guard let done = onFinish else { return }
        onFinish = nil
        done(result)
    }
}

struct QRScannerScreen: View {
    @ObservedObject var model: QRScannerModel

    var body: some View {
        ZStack {
            if let problem = model.problem {
                NibColor.background.ignoresSafeArea()
                QRProblemView(problem: problem) { model.problem = nil }
                    .padding(.horizontal, NibMetrics.chromeInset)
            } else {
                QRCameraView(model: model).ignoresSafeArea()
            }
            NibDropletContainer {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        NibBarGroup(id: "scan.qr.bar") {
                            NibToolbarItem(.xmark, label: String(localized: "Close"), shortcut: .cancelAction) {
                                model.finish(nil)
                            }
                            NibBarSeparator()
                            NibBarTitle(title: String(localized: "Scan QR Code"),
                                        subtitle: model.problem == nil ? String(localized: "Point the camera at a code") : nil)
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    if let code = model.code, model.problem == nil {
                        QRResultPanel(payload: code, onClose: { model.dismissCode() }, action: { model.confirm() })
                    }
                }
                .padding(.horizontal, NibMetrics.chromeInset)
                .padding(.top, NibMetrics.barTopGap)
                .padding(.bottom, NibSpacing.xxl)
            }
        }
        .onChange(of: model.code) { _, code in
            guard let code else { return }
            NibHaptics.play(.select)
            AccessibilityNotification.Announcement(String(localized: "QR code found: \(code.display)")).post()
        }
        .onDisappear { model.finish(nil) }
    }
}

/// The code, in full, and the one action it gets. Deep, because it carries body text.
struct QRResultPanel: View {
    let payload: QRPayload
    let onClose: () -> Void
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NibPanelHeader(title: QRResultPanel.kindTitle(payload.kind), symbol: QRResultPanel.symbol(payload.kind),
                           onClose: onClose)
            Text(payload.display)
                .font(NibFont.callout)
                .foregroundStyle(NibColor.labelSecondary)
                .lineLimit(typeSize.isAccessibilitySize ? 8 : 4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NibSpacing.l)
            NibButton(QRResultPanel.actionTitle(payload.kind), kind: .primary, expands: true, shortcut: .defaultAction,
                      action: action)
                .padding(NibSpacing.l)
        }
        .frame(maxWidth: NibMetrics.panelWidth(typeSize))
        .droplet("scan.qr.result", style: .panel)
        .accessibilityElement(children: .contain)
    }

    static func symbol(_ kind: QRPayloadKind) -> NibSymbol {
        switch kind {
        case .web: return .externalLink
        case .nib: return .notebook
        case .text: return .copy
        }
    }

    static func kindTitle(_ kind: QRPayloadKind) -> String {
        switch kind {
        case .web: return String(localized: "Link")
        case .nib: return String(localized: "Nib Link")
        case .text: return String(localized: "Text")
        }
    }

    static func actionTitle(_ kind: QRPayloadKind) -> String {
        switch kind {
        case .web: return String(localized: "Open Link")
        case .nib: return String(localized: "Open in Nib")
        case .text: return String(localized: "Copy Text")
        }
    }
}

/// Camera off or busy: what happened and what to do next.
struct QRProblemView: View {
    let problem: QRCameraProblem
    let retry: () -> Void

    var body: some View {
        switch problem {
        case .denied:
            NibEmptyState(symbol: .camera, title: String(localized: "Camera access is off"),
                          message: String(localized: "Allow Nib to use the camera in Settings to scan QR codes."),
                          primary: NibAction(String(localized: "Open Settings")) { CameraAccess.openSettings() })
        case .unavailable:
            NibEmptyState(symbol: .camera, title: String(localized: "The camera is not available"),
                          message: String(localized: "Another app may be using it. Close that app, then try again."),
                          primary: NibAction(String(localized: "Try Again"), handler: retry))
        }
    }
}

/// DataScannerViewController reading QR codes, with the system's own highlights, guidance and pinch to zoom.
struct QRCameraView: UIViewControllerRepresentable {
    let model: QRScannerModel

    func makeUIViewController(context: Context) -> QRCameraController {
        QRCameraController(model: model)
    }

    func updateUIViewController(_ controller: QRCameraController, context: Context) {}
}

/// Hosts the scanner and starts it once it is on screen (it does not scan before it has a window).
final class QRCameraController: UIViewController, DataScannerViewControllerDelegate {
    private let model: QRScannerModel
    private let scanner: DataScannerViewController

    init(model: QRScannerModel) {
        self.model = model
        scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                            qualityLevel: .balanced, recognizesMultipleItems: true,
                                            isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
                                            isGuidanceEnabled: true, isHighlightingEnabled: true)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        scanner.delegate = self
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            scanLog.error("QR scanner did not start: \(error.localizedDescription, privacy: .public)")
            model.problem = .unavailable
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        for item in addedItems {
            if model.found(QRCameraController.payload(item)) { break }
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        model.found(QRCameraController.payload(item))
    }

    func dataScanner(_ dataScanner: DataScannerViewController,
                     becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        scanLog.error("QR scanner became unavailable: \(String(describing: error), privacy: .public)")
        model.problem = .unavailable
    }

    static func payload(_ item: RecognizedItem) -> String? {
        if case .barcode(let barcode) = item { return barcode.payloadStringValue }
        return nil
    }
}
