// Native window for FaceFusion. Starts the local server if it isn't already
// running, then shows it in a WKWebView window instead of a browser tab.
import Cocoa
import WebKit

let port = 7870
let url = URL(string: "http://127.0.0.1:\(port)")!
let home = FileManager.default.homeDirectoryForCurrentUser
let root = home.appendingPathComponent("facefusion")

func serverIsUp() -> Bool {
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5
    let semaphore = DispatchSemaphore(value: 0)
    var ok = false
    URLSession.shared.dataTask(with: request) { _, response, _ in
        ok = (response as? HTTPURLResponse) != nil
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 2)
    return ok
}

func startServer() {
    let process = Process()
    process.executableURL = root.appendingPathComponent(".venv/bin/python")
    process.arguments = [ "facefusion.py", "run" ]
    process.currentDirectoryURL = root
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    env["GRADIO_SERVER_PORT"] = String(port)
    process.environment = env
    let log = home.appendingPathComponent("Library/Logs/facefusion.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    if let handle = try? FileHandle(forWritingTo: log) {
        process.standardOutput = handle
        process.standardError = handle
    }
    try? process.run()
}

class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var splash: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fit the window to the screen (the old fixed 1500x1000 could be larger than the display).
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 0, y: 0, width: max(950, min(1500, visible.width - 40)), height: max(600, min(1000, visible.height - 40)))
        window = NSWindow(contentRect: frame,
                          styleMask: [ .titled, .closable, .miniaturizable, .resizable ],
                          backing: .buffered, defer: false)
        window.title = "FaceFusion"
        // Unified header: no title bar of its own, content runs to the top edge.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 950, height: 600)
        window.center()
        window.setFrameAutosaveName("FaceFusionWindow")
        // Never restore a saved frame that is off-screen or bigger than the screen it is on.
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(window.frame) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            let fitted = window.frame.intersection(area)
            if fitted.width < 950 || fitted.height < 600 { window.setFrame(frame, display: false); window.center() }
            else { window.setFrame(fitted, display: false) }
        }

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // With a hidden title bar the content would run under the window buttons,
        // so inset the web view by the title bar height and leave that strip draggable.
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor, constant: max(28, titleBarHeight)),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container

        splash = NSTextField(labelWithString: "Starting FaceFusion…")
        splash.alignment = .center
        splash.font = NSFont.systemFont(ofSize: 18)
        splash.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splash)
        NSLayoutConstraint.activate([
            splash.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            splash.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.global().async {
            if !serverIsUp() {
                startServer()
                for _ in 0..<120 {
                    if serverIsUp() { break }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
            DispatchQueue.main.async {
                self.splash.isHidden = true
                self.webView.load(URLRequest(url: url))
            }
        }
    }

    // MARK: file pickers — without this, clicking an upload box does nothing in WKWebView.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    // Links that want a new tab/window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = action.request.url {
            if target.host == "127.0.0.1" { webView.load(action.request) } else { NSWorkspace.shared.open(target) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    // MARK: navigation — external links open in the browser, download links save to ~/Downloads.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let target = action.request.url, target.host != "127.0.0.1", target.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(target)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = downloads.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            dest = downloads.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let dest = download.progress.fileURL { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
    }

    // A dropped connection (e.g. server restart) would otherwise leave a blank window.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
