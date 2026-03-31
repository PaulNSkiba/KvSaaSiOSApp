import SwiftUI
import WebKit
import CoreNFC

// 1. Мозг сканера с логикой DE/EN
class NFCReader: NSObject, NFCTagReaderSessionDelegate, ObservableObject {
    @Published var lastID = ""
    var session: NFCTagReaderSession?
    var currentLanguage: String = "en"

    func scan(language: String) {
        self.currentLanguage = language
        session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil)
        
        if language == "de" {
            session?.alertMessage = "Halten Sie Ihr iPhone an das NFC-Tag"
        } else {
            session?.alertMessage = "Hold your iPhone near the NFC tag"
        }
        session?.begin()
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        DispatchQueue.main.async {
            let code = (error as NSError).code
            if code != 200 && code != 201 {
                print("NFC Error: \(error.localizedDescription)")
            }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        
        session.connect(to: tag) { error in
            if error != nil {
                session.invalidate(errorMessage: self.currentLanguage == "de" ? "Verbindungsfehler" : "Connection Error")
                return
            }
            
            var id = ""
            if case let .miFare(mTag) = tag {
                id = mTag.identifier.map { String(format: "%02hhX", $0) }.joined(separator: ":")
            } else if case let .iso7816(isoTag) = tag {
                id = isoTag.identifier.map { String(format: "%02hhX", $0) }.joined(separator: ":")
            } else if case let .feliCa(fTag) = tag {
                id = fTag.currentIDm.map { String(format: "%02hhX", $0) }.joined(separator: ":")
            } else if case let .iso15693(iTag) = tag {
                id = iTag.identifier.map { String(format: "%02hhX", $0) }.joined(separator: ":")
            }
            
            DispatchQueue.main.async {
                self.lastID = id
                session.alertMessage = self.currentLanguage == "de" ? "Erfolgreich!" : "Success!"
                session.invalidate()
            }
        }
    }
}

// 2. Обновленный WebViewContainer (исправлен для iOS 18)
struct WebViewContainer: UIViewRepresentable {
    let url: URL
    @ObservedObject var nfc: NFCReader

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "nfcHandler")
        config.userContentController = controller
        
        // Настройки для корректной работы в iOS 18
        config.allowsInlineMediaPlayback = true
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        
        // Прямая загрузка сразу при создании
        let request = URLRequest(url: url)
        webView.load(request)
        
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Отправка данных в JS при получении ID
        if !nfc.lastID.isEmpty {
            let jsCode = "if (typeof onNFCRead === 'function') { onNFCRead('\(nfc.lastID)'); }"
            uiView.evaluateJavaScript(jsCode) { (result, error) in
                if let error = error {
                    print("JS Injection Error: \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                nfc.lastID = ""
            }
        }
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: WebViewContainer
        init(_ parent: WebViewContainer) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "nfcHandler", let body = message.body as? String, body == "scan" {
                // Если в URL есть .de - шлем немецкий, иначе английский
                let isGerman = parent.url.absoluteString.contains(".de")
                parent.nfc.scan(language: isGerman ? "de" : "en")
            }
        }
    }
}

// 3. Главный экран
struct ContentView: View {
    @StateObject var nfc = NFCReader()
    private let url = URL(string: "https://mdev.kvsaas.de/")!

    var body: some View {
        WebViewContainer(url: url, nfc: nfc)
            .edgesIgnoringSafeArea(.all)
    }
}
