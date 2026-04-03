import SwiftUI
import WebKit
import CoreNFC
import Vision
import VisionKit

// MARK: - 1. Configuration
struct Config {
    static let prodURL = "https://mapp.kvsaas.de/"
    static let devURL = "https://mdev.kvsaas.de/"
    static let switchYear = 2026
    static let switchMonth = 4
    static let switchDay = 12
    static let storageKey = "user_selected_url"
}

// MARK: - 2. NFC Service
class NFCReader: NSObject, NFCTagReaderSessionDelegate, ObservableObject {
    @Published var lastID = ""
    var session: NFCTagReaderSession?
    
    func scan(language: String) {
        session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil)
        session?.alertMessage = "NFC Tag scannen"
        session?.begin()
    }
    
    func stop() { session?.invalidate(); session = nil }
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {}
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { error in
            var id = ""
            if case let .miFare(mTag) = tag { id = mTag.identifier.map { String(format: "%02hhX", $0) }.joined(separator: ":") }
            else if case let .iso7816(isoTag) = tag { id = isoTag.identifier.map { String(format: "%02hhX", $0) }.joined(separator: ":") }
            DispatchQueue.main.async { self.lastID = id; session.invalidate() }
        }
    }
}

// MARK: - 3. Scanner (iOS 16+)
@available(iOS 16.0, *)
struct ModernScannerView: UIViewControllerRepresentable {
    @Binding var text: String
    @Binding var qr: String
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let dc = DataScannerViewController(recognizedDataTypes: [.text(), .barcode()], qualityLevel: .accurate, isHighFrameRateTrackingEnabled: true, isHighlightingEnabled: true)
        dc.delegate = context.coordinator; try? dc.startScanning()
        return dc
    }
    
    func updateUIViewController(_ uiVC: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: ModernScannerView
        init(_ parent: ModernScannerView) { self.parent = parent }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            switch item {
            case .text(let t): self.parent.text = t.transcript
            case .barcode(let b): self.parent.qr = b.payloadStringValue ?? ""
            @unknown default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.parent.presentationMode.wrappedValue.dismiss() }
        }
    }
}

// MARK: - 4. WebView Container
struct WebViewContainer: UIViewRepresentable {
    let url: URL
    @ObservedObject var nfc: NFCReader
    @Binding var text: String
    @Binding var qr: String
    @Binding var isPDFActive: Bool
    var onReq: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "appHandler")
        config.userContentController.add(context.coordinator, name: "nfcHandler")
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.uiDelegate = context.coordinator
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Управление кнопкой назад
        NotificationCenter.default.removeObserver(context.coordinator, name: NSNotification.Name("goBack"), object: nil)
        NotificationCenter.default.addObserver(forName: NSNotification.Name("goBack"), object: nil, queue: .main) { _ in
            if uiView.canGoBack { uiView.goBack() }
        }
        
        // ПЕРЕДАЧА ДАННЫХ (Исправлено: вызываем JS немедленно)
        if !nfc.lastID.isEmpty {
            uiView.evaluateJavaScript("if(window.onNFCRead) onNFCRead('\(nfc.lastID)')")
            let tempID = nfc.lastID; DispatchQueue.main.async { if nfc.lastID == tempID { nfc.lastID = "" } }
        }
        if !text.isEmpty {
            uiView.evaluateJavaScript("if(window.onCameraRead) onCameraRead('\(text)')")
            let tempText = text; DispatchQueue.main.async { if text == tempText { text = "" } }
        }
        if !qr.isEmpty {
            uiView.evaluateJavaScript("if(window.onQRCodeRead) onQRCodeRead('\(qr)')")
            let tempQR = qr; DispatchQueue.main.async { if qr == tempQR { qr = "" } }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
        var p: WebViewContainer
        init(_ p: WebViewContainer) { self.p = p }
        
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                // Включаем кнопку возврата для PDF (используем async только для UI-флага)
                DispatchQueue.main.async { self.p.isPDFActive = true }
                webView.load(navigationAction.request)
            }
            return nil
        }
        
        func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let body = m.body as? String else { return }
            if body == "openCamera" { self.p.nfc.stop(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.p.onReq() } }
            else if body == "scan" || body == "scanNFC" { self.p.nfc.scan(language: "en") }
        }
    }
}

// MARK: - 5. Main View
struct ContentView: View {
    @StateObject var nfc = NFCReader()
    @State private var recognizedText = ""
    @State private var recognizedQR = ""
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var currentUrl = ""
    @State private var isPDFActive = false

    init() { _currentUrl = State(initialValue: Self.getInitialURL()) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let url = URL(string: currentUrl) {
                    WebViewContainer(url: url, nfc: nfc, text: $recognizedText, qr: $recognizedQR, isPDFActive: $isPDFActive) {
                        showCamera = true
                    }
                }
            }
            .edgesIgnoringSafeArea(.top)

            if isPDFActive {
                HStack {
                    Button(action: {
                        withAnimation(.spring()) {
                            self.isPDFActive = false
                        }
                        NotificationCenter.default.post(name: NSNotification.Name("goBack"), object: nil)
                    }) {
                        HStack {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                            Text("Вернуться / Back").fontWeight(.bold)
                        }
                        .padding(.horizontal, 25)
                        .padding(.vertical, 14)
                        .foregroundColor(.white)
                        .background(Color.blue)
                        .cornerRadius(15)
                        .shadow(radius: 5)
                    }
                    .padding(.leading, 20)
                    .padding(.bottom, 12)
                    Spacer()
                }
                .frame(height: 80)
                .background(Color(.systemBackground))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isPDFActive)
        .sheet(isPresented: $showCamera) {
            if #available(iOS 16.0, *) {
                ModernScannerView(text: $recognizedText, qr: $recognizedQR).edgesIgnoringSafeArea(.all)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(); showSettings = true
        }
        .actionSheet(isPresented: $showSettings) {
            ActionSheet(title: Text("Server Settings"), buttons: [
                .default(Text("Production")) { updateURL(Config.prodURL) },
                .default(Text("Development")) { updateURL(Config.devURL) },
                .cancel()
            ])
        }
    }
    
    static func getInitialURL() -> String {
        if let saved = UserDefaults.standard.string(forKey: Config.storageKey) { return saved }
        let deadline = Calendar.current.date(from: DateComponents(year: Config.switchYear, month: Config.switchMonth, day: Config.switchDay))!
        return Date() >= deadline ? Config.prodURL : Config.devURL
    }
    
    func updateURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: Config.storageKey)
        currentUrl = url
    }
}

// MARK: - 6. Shake Gesture Support
extension NSNotification.Name { static let deviceDidShake = NSNotification.Name("deviceDidShake") }
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
    }
}

