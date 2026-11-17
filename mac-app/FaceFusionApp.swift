// FaceFusion — a native macOS front end.
//
// The Python engine does the work; this app owns the interface. It calls
// mac-app/ff_helper.py to read the video and find faces, and facefusion.py
// headless-run to render, so nothing here duplicates the engine's logic.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Paths and process helpers

enum Engine {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("facefusion")
    static let python = root.appendingPathComponent(".venv/bin/python")
    static let helper = root.appendingPathComponent("mac-app/ff_helper.py")

    /// yt-dlp, wherever Homebrew or pipx put it. GUI apps get no login PATH.
    static var downloader: URL? {
        let candidates = [ "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/yt-dlp").path,
                           root.appendingPathComponent(".venv/bin/yt-dlp").path ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Where downloaded videos land, so they survive a restart and can be re-opened.
    static var downloadFolder: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/FaceFusion Downloads")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Everything the engine prints also goes here, so a failure is readable
    /// after the fact and can be opened in any editor.
    static var logFile: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("facefusion-app.log")
    }

    /// Downloads get their own log, appended and never truncated, so an
    /// intermittent failure can still be read after later work.
    static var downloadLogFile: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("facefusion-downloads.log")
    }

    static func appendDownloadLog(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: downloadLogFile) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: downloadLogFile)
        }
    }

    static func appendLog(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logFile)
        }
    }

    static func startLog(_ header: String) {
        try? Data().write(to: logFile)
        appendLog(header + "\n\n")
    }

    static func binary(_ name: String) -> URL? {
        let candidates = [ "/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/" ].map { $0 + name }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The video codec of a file, as ffprobe reports it ("h264", "vp9", "av1"…).
    nonisolated static func videoCodec(of path: String) -> String? {
        guard let ffprobe = binary("ffprobe") else { return nil }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [ "-v", "error", "-select_streams", "v:0",
                              "-show_entries", "stream=codec_name", "-of", "csv=p=0", path ]
        process.environment = environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// QuickTime decodes H.264 and HEVC; VP9 and AV1 open as a blank window even
    /// inside an .mp4. Re-encodes to H.264 in place when that is the case.
    nonisolated static func makeQuickTimePlayable(_ path: String) -> Bool {
        guard let codec = videoCodec(of: path) else { return true }
        if [ "h264", "avc1", "hevc", "h265" ].contains(codec) { return true }
        guard let ffmpeg = binary("ffmpeg") else { return false }
        let source = URL(fileURLWithPath: path)
        let temporary = source.deletingLastPathComponent()
            .appendingPathComponent(".ff-convert-" + UUID().uuidString + ".mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [ "-y", "-i", path,
                              "-c:v", "h264_videotoolbox", "-b:v", "8M",
                              "-c:a", "aac", "-b:a", "192k",
                              "-movflags", "+faststart", "-tag:v", "avc1",
                              temporary.path ]
        process.environment = environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int,
              size > 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(source, withItemAt: temporary)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: python.path) && FileManager.default.fileExists(atPath: helper.path)
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }

    /// Runs the helper and decodes its JSON. Returns nil when the helper fails.
    static func helperJSON(_ arguments: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = python
        process.arguments = [ helper.path ] + arguments
        process.currentDirectoryURL = root
        process.environment = environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Model

/// Mutable path shared between the read handler and the termination handler.
final class PathBox: @unchecked Sendable {
    var path: String?
    var lastError: String?
}

struct DetectedFace: Identifiable, Hashable {
    let id: Int          // slot number, 1-based, matching the engine's --face-map
    let thumbPath: String
    var sourcePath: String?

    var thumbnail: NSImage? { NSImage(contentsOfFile: thumbPath) }
    var sourceImage: NSImage? { sourcePath.flatMap { NSImage(contentsOfFile: $0) } }
}

/// One control for the three settings that actually cost time.
enum RenderSpeed: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case best = "Best"

    var id: String { rawValue }

    var pixelBoost: String {
        switch self {
        case .fast: return "128x128"
        case .balanced: return "256x256"
        case .best: return "512x512"
        }
    }

    var enhancer: Bool { self == .best }
    var steady: Bool { self == .best }
    var threads: Int {
        switch self {
        case .fast: return 8
        case .balanced: return 6
        case .best: return 4
        }
    }

    var blurb: String {
        switch self {
        case .fast: return "About 6× faster than Best. Good enough for a first look."
        case .balanced: return "Roughly 3× faster than Best. The sensible default."
        case .best: return "Sharpest and steadiest, and by far the slowest."
        }
    }
}

enum Section: String, CaseIterable, Identifiable {
    case faces = "Faces"
    case quality = "Quality"
    case output = "Output"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .faces: return "person.2.crop.square.stack"
        case .quality: return "slider.horizontal.3"
        case .output: return "film"
        }
    }
}

@MainActor
final class SwapModel: ObservableObject {
    @Published var videoPath: String? { didSet { reloadVideo() } }
    @Published var faces: [DetectedFace] = []
    @Published var previewPath: String?
    @Published var frameNumber: Int = 0
    @Published var frameCount: Int = 0
    @Published var isVideo = false

    @Published var swapperModel = "inswapper_128"
    @Published var swapWeight: Double = 1.0
    @Published var pixelBoost = "256x256"
    @Published var useEnhancer = false
    @Published var steadyMode = false
    @Published var threadCount = 6
    @Published var speed: RenderSpeed = .balanced { didSet { applySpeed() } }

    private func applySpeed() {
        pixelBoost = speed.pixelBoost
        useEnhancer = speed.enhancer
        steadyMode = speed.steady
        threadCount = speed.threads
    }

    @Published var isDetecting = false
    @Published var isRendering = false
    @Published var progress: Double = 0
    @Published var statusLine = "Choose a video or photo to begin."
    @Published var log: String = ""
    @Published var outputPath: String?

    @Published var urlText: String = ""
    @Published var isDownloading = false
    @Published var savedDownloadPath: String?
    @Published var isConverting = false
    @Published var downloadProgress: Double = 0

    private var renderProcess: Process?
    private var downloadProcess: Process?

    var canRender: Bool { videoPath != nil && faces.contains { $0.sourcePath != nil } && !isRendering }
    var assignedCount: Int { faces.filter { $0.sourcePath != nil }.count }

    // MARK: video + faces

    func reloadVideo() {
        guard let path = videoPath else { return }
        faces = []
        outputPath = nil
        frameNumber = 0
        statusLine = "Reading \(URL(fileURLWithPath: path).lastPathComponent)…"
        Task.detached { [weak self] in
            let info = Engine.helperJSON([ "info", "--target", path ])
            await MainActor.run {
                guard let self else { return }
                self.isVideo = info?["isVideo"] as? Bool ?? false
                self.frameCount = info?["frameCount"] as? Int ?? 0
                self.frameNumber = self.isVideo ? min(30, max(0, self.frameCount - 1)) : 0
            }
            await self?.refreshFrame()
        }
    }

    func refreshFrame() async {
        guard let path = videoPath else { return }
        let frame = frameNumber
        isDetecting = true
        statusLine = "Finding faces…"
        let previous = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0.sourcePath) })

        let result: ([DetectedFace], String?) = await Task.detached {
            let previewOut = NSTemporaryDirectory() + "ff-preview.png"
            _ = Engine.helperJSON([ "preview", "--target", path, "--frame", String(frame), "--out", previewOut ])
            let faceJSON = Engine.helperJSON([ "faces", "--target", path, "--frame", String(frame),
                                               "--out", NSTemporaryDirectory() + "ff-faces" ])
            let rows = (faceJSON?["faces"] as? [[String: Any]]) ?? []
            let faces: [DetectedFace] = rows.compactMap { row in
                guard let slot = row["slot"] as? Int, let thumb = row["thumb"] as? String else { return nil }
                return DetectedFace(id: slot, thumbPath: thumb, sourcePath: nil)
            }
            return (faces, FileManager.default.fileExists(atPath: previewOut) ? previewOut : nil)
        }.value

        // Keep assignments across frame changes when the face count matches.
        faces = result.0.map { face in
            var face = face
            if result.0.count == previous.count { face.sourcePath = previous[face.id] ?? nil }
            return face
        }
        previewPath = result.1.map { $0 + "?\(frame)" }
        isDetecting = false
        statusLine = faces.isEmpty ? "No faces found in this frame. Try another frame."
                                   : "\(faces.count) face\(faces.count == 1 ? "" : "s") found. Assign a photo to each face you want replaced."
    }

    func assign(_ sourcePath: String?, to slot: Int) {
        guard let index = faces.firstIndex(where: { $0.id == slot }) else { return }
        faces[index].sourcePath = sourcePath
        statusLine = assignedCount == 0 ? "No faces assigned yet."
                                        : "\(assignedCount) of \(faces.count) faces will be replaced."
    }

    /// Opens the file picker as a sheet on the window.
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ .movie, .video, .mpeg4Movie, .quickTimeMovie, .image ]
        panel.allowsMultipleSelection = false
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK, let url = panel.url { self?.videoPath = url.path }
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    /// Why the swap button is unavailable, in plain words. nil means it is ready.
    var blockedReason: String? {
        if isRendering { return "Rendering…" }
        if isDownloading { return "Downloading…" }
        if videoPath == nil { return "Open a video or photo first" }
        if faces.isEmpty { return "No faces found — try another frame" }
        if assignedCount == 0 { return "Pick a photo for at least one face" }
        return nil
    }

    /// Clears everything and starts a fresh swap, without restarting the app.
    func reset() {
        cancelRender()
        cancelDownload()
        faces = []
        previewPath = nil
        outputPath = nil
        frameNumber = 0
        frameCount = 0
        isVideo = false
        progress = 0
        log = ""
        urlText = ""
        savedDownloadPath = nil
        // Assigned last: its didSet would otherwise reload the old file.
        videoPath = nil
        statusLine = "New swap. Open a video or photo, or paste a link."
    }

    // MARK: download from a link

    /// Asks where to save, then pulls the video down with yt-dlp. The file is
    /// only saved — it is never loaded into the app, so the swap stays a
    /// deliberate second step. The link is passed as an argument, never a shell.
    func downloadFromURL(_ text: String? = nil) {
        let raw = (text ?? urlText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isDownloading, !isRendering else { return }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            statusLine = "That does not look like a web link."
            return
        }
        guard let tool = Engine.downloader else {
            statusLine = "yt-dlp is not installed. Run: brew install yt-dlp"
            log += "\nyt-dlp not found in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin or the venv.\n"
            return
        }

        isDownloading = true
        downloadProgress = 0
        statusLine = "Reading \(url.host ?? "the link")…"

        // Probe first: a dead link, a private post or a broken extractor is
        // better reported now than after the save panel.
        Task.detached { [weak self] in
            let probe = Self.probe(tool: tool, link: raw)
            await MainActor.run {
                guard let self else { return }
                self.isDownloading = false
                switch probe {
                case .success(let title):
                    self.askWhereToSave(tool: tool, link: raw, suggested: title + ".mp4")
                case .needsSignIn:
                    self.statusLine = "That post needs a sign-in. Trying your browser cookies…"
                    self.askWhereToSave(tool: tool, link: raw, suggested: "video.mp4", useCookies: true)
                case .failure(let reason):
                    self.statusLine = reason
                }
            }
        }
    }

    enum Probe {
        case success(String)
        case needsSignIn
        case failure(String)
    }

    /// Asks yt-dlp for the title, and turns a failure into something readable.
    nonisolated static func probe(tool: URL, link: String) -> Probe {
        let process = Process()
        process.executableURL = tool
        process.arguments = [ "--no-playlist", "--no-warnings", "--restrict-filenames",
                              "--socket-timeout", "20", "--retries", "3",
                              "--print", "%(title).80B", "--skip-download", "--", link ]
        process.environment = Engine.environment()
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failure("Could not start yt-dlp.") }
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let errorText = String(data: errData, encoding: .utf8) ?? ""
        Engine.appendDownloadLog("\n--- probe \(Date()) \(link)\n" + errorText)

        if process.terminationStatus == 0 {
            let title = String(data: outData, encoding: .utf8)?
                .components(separatedBy: .newlines).first?
                .trimmingCharacters(in: .whitespaces)
            return .success((title?.isEmpty ?? true) ? "video" : title!)
        }

        let lowered = errorText.lowercased()
        if lowered.contains("login") || lowered.contains("sign in") || lowered.contains("cookies")
            || lowered.contains("private") || lowered.contains("rate-limit") || lowered.contains("429") {
            return .needsSignIn
        }
        if lowered.contains("unsupported url") {
            return .failure("yt-dlp does not know that site.")
        }
        if lowered.contains("unavailable") || lowered.contains("404") || lowered.contains("removed") {
            return .failure("That video is unavailable or has been removed.")
        }
        // Fall back to yt-dlp's own last ERROR line, which is usually the clearest.
        let lastError = errorText.components(separatedBy: .newlines)
            .last { $0.contains("ERROR") }?
            .replacingOccurrences(of: "ERROR: ", with: "")
        return .failure(lastError.map { String($0.prefix(140)) } ?? "Download failed — press View log to see why.")
    }

    nonisolated private static func fetchTitle(tool: URL, link: String) -> String? {
        let process = Process()
        process.executableURL = tool
        process.arguments = [ "--no-playlist", "--no-warnings", "--restrict-filenames",
                              "--print", "%(title).80B", "--skip-download", "--", link ]
        process.environment = Engine.environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let title = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces)
        return (title?.isEmpty ?? true) ? nil : title
    }

    private func askWhereToSave(tool: URL, link: String, suggested: String, useCookies: Bool = false) {
        let panel = NSSavePanel()
        panel.title = "Save video"
        panel.message = "Choose where to save the downloaded video."
        panel.nameFieldStringValue = suggested
        panel.directoryURL = Engine.downloadFolder
        panel.canCreateDirectories = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else {
                self?.statusLine = "Download cancelled."
                return
            }
            self?.startDownload(tool: tool, link: link, destination: destination, useCookies: useCookies)
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func startDownload(tool: URL, link: String, destination: URL, useCookies: Bool = false) {
        isDownloading = true
        downloadProgress = 0
        statusLine = "Downloading to \(destination.lastPathComponent)…"
        Engine.startLog("$ yt-dlp -> " + destination.path)
        Engine.appendDownloadLog("\n--- download \(Date()) \(link) -> \(destination.path)\n")

        let process = Process()
        process.executableURL = tool
        process.arguments = [
            "--no-playlist", "--newline", "--no-colors", "--force-overwrites",
            // Flaky networks and throttled CDNs are the usual cause of a failed run.
            "--retries", "10", "--fragment-retries", "10", "--socket-timeout", "20",
            "--concurrent-fragments", "4",
            "--merge-output-format", "mp4",
            // H.264 first: VP9/AV1 sit happily in an .mp4 but QuickTime cannot decode them.
            "-f", "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[vcodec^=avc1][height<=1080]/bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b",
            "--print", "after_move:FFPATH %(filepath)s",
            "-o", destination.path, "--", link
        ]
        if useCookies {
            // The user's own browser session, read locally; nothing is sent anywhere.
            process.arguments?.insert(contentsOf: [ "--cookies-from-browser", "chrome" ], at: 0)
        }
        process.currentDirectoryURL = destination.deletingLastPathComponent()
        process.environment = Engine.environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let box = PathBox()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                if line.hasPrefix("FFPATH ") {
                    box.path = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                }
                if let match = line.range(of: #"([0-9]+(\.[0-9]+)?)%"#, options: .regularExpression) {
                    let value = Double(line[match].dropLast()) ?? 0
                    DispatchQueue.main.async { self?.downloadProgress = value / 100 }
                }
            }
            Engine.appendLog(text)
            Engine.appendDownloadLog(text)
            for line in text.components(separatedBy: .newlines) where line.contains("ERROR") {
                box.lastError = line.replacingOccurrences(of: "ERROR: ", with: "")
            }
            DispatchQueue.main.async { self?.log += text }
        }

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.isDownloading = false
                self.downloadProcess = nil
                self.downloadProgress = 0
                if finished.terminationStatus != 0 {
                    if finished.terminationStatus == 15 {
                        self.statusLine = "Download cancelled."
                    } else if let reason = box.lastError {
                        self.statusLine = String(reason.prefix(140))
                    } else {
                        self.statusLine = "Download failed — press View log to see why."
                    }
                    return
                }
                // yt-dlp may land on a different extension than the panel asked for.
                let candidates = [ box.path, destination.path ].compactMap { $0 }
                guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                    self.statusLine = "Download finished but the file could not be found."
                    return
                }
                self.urlText = ""
                let name = URL(fileURLWithPath: path).lastPathComponent
                self.isConverting = true
                self.statusLine = "Checking \(name) plays everywhere…"
                Task.detached {
                    let ok = Engine.makeQuickTimePlayable(path)
                    await MainActor.run {
                        self.isConverting = false
                        self.savedDownloadPath = path
                        self.statusLine = ok ? "Saved \(name). Open it when you are ready."
                                             : "Saved \(name), but it could not be converted to H.264 — QuickTime may not play it."
                    }
                }
            }
        }

        downloadProcess = process
        do { try process.run() } catch {
            isDownloading = false
            statusLine = "Could not start yt-dlp."
        }
    }

    func cancelDownload() {
        downloadProcess?.terminate()
    }

    /// Fallback when --print gives nothing (e.g. an already-downloaded file).
    private func newestDownload() -> String? {
        let folder = Engine.downloadFolder
        let keys: [URLResourceKey] = [ .contentModificationDateKey ]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { ![ "part", "ytdl" ].contains($0.pathExtension) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return da < db
            }?.path
    }

    // MARK: render

    func render() {
        guard let target = videoPath, canRender else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultOutputName(for: target)
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.startRender(target: target, destination: destination)
        }
    }

    private func defaultOutputName(for target: String) -> String {
        let url = URL(fileURLWithPath: target)
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        return url.deletingPathExtension().lastPathComponent + "-swapped." + ext
    }

    private func startRender(target: String, destination: URL) {
        var arguments = [ "facefusion.py", "headless-run", "-t", target, "-o", destination.path,
                          "--face-swapper-model", swapperModel,
                          "--face-swapper-weight", String(format: "%.2f", swapWeight),
                          "--face-swapper-pixel-boost", pixelBoost,
                          "--reference-frame-number", String(frameNumber),
                          "--execution-providers", "coreml",
                          "--execution-thread-count", String(threadCount),
                          // Hardware encode, and H.264 so the result opens anywhere.
                          "--output-video-encoder", "h264_videotoolbox",
                          "--output-video-preset", "veryfast" ]
        arguments += [ "--processors", "face_swapper" ] + (useEnhancer ? [ "face_enhancer" ] : [])
        arguments += steadyMode ? [ "--face-tracker-score", "0.3", "--face-detector-model", "many", "--face-landmarker-model", "many" ]
                                : [ "--face-tracker-score", "0.0" ]
        let mapping = faces.compactMap { face in face.sourcePath.map { "\(face.id)=\($0)" } }
        if !mapping.isEmpty { arguments += [ "--face-map" ] + mapping }

        log = ""
        Engine.startLog("$ " + ([ Engine.python.path ] + arguments).joined(separator: " "))

        let process = Process()
        process.executableURL = Engine.python
        process.arguments = arguments
        process.currentDirectoryURL = Engine.root
        process.environment = Engine.environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.isRendering = false
                self.renderProcess = nil
                if finished.terminationStatus == 0 && FileManager.default.fileExists(atPath: destination.path) {
                    self.outputPath = destination.path
                    self.progress = 1
                    self.statusLine = "Done — saved to \(destination.lastPathComponent)."
                } else {
                    self.statusLine = finished.terminationStatus == 15 ? "Render cancelled."
                                                                      : "Render failed — press View log to see why."
                }
            }
        }
        log = ""
        progress = 0
        isRendering = true
        statusLine = "Rendering…"
        outputPath = nil
        do { try process.run(); renderProcess = process } catch {
            isRendering = false
            statusLine = "Could not start the engine: \(error.localizedDescription)"
        }
    }

    func cancelRender() {
        renderProcess?.terminate()
    }

    /// Engine output is progress-bar heavy; keep the tail and read the percentage.
    private func consume(_ text: String) {
        log = String((log + text).suffix(6000))
        Engine.appendLog(text)
        for line in text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
            if let percentRange = line.range(of: #"(\d+)%"#, options: .regularExpression) {
                let digits = line[percentRange].dropLast()
                if let value = Double(digits) { progress = value / 100 }
            }
            if line.contains("processing to video succeeded") || line.contains("processing to image succeeded") {
                progress = 1
            }
        }
    }
}

// MARK: - Design system

enum Surface {
    static let card = Color(NSColor.windowBackgroundColor)
    static let canvas = Color(NSColor.underPageBackgroundColor)
    static let border = Color(NSColor.separatorColor).opacity(0.5)
    static let radius: CGFloat = 6
}

extension View {
    func cardStyle() -> some View {
        padding(12)
            .background(Surface.card)
            .overlay(RoundedRectangle(cornerRadius: Surface.radius).stroke(Surface.border))
            .clipShape(RoundedRectangle(cornerRadius: Surface.radius))
    }
}

// MARK: - Views

struct RootView: View {
    @StateObject private var model = SwapModel()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var section: Section? = .faces

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 250)
        } content: {
            Group {
                switch section ?? .faces {
                case .faces: FaceListColumn(model: model)
                case .quality: QualityColumn(model: model)
                case .output: OutputColumn(model: model)
                }
            }
            .listStyle(.inset)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            DetailCanvas(model: model)
        }
        .navigationTitle("FaceFusion")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Hide or show the sidebar")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    model.reset()
                    section = .faces
                } label: {
                    Label("New swap", systemImage: "plus.square.on.square")
                }
                .help("Clear everything and start a new swap (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    chooseVideo()
                } label: {
                    Label("Open video or photo", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isRendering {
                    Button(role: .destructive) { model.cancelRender() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                } else {
                    Button { model.render() } label: {
                        Label("Swap faces", systemImage: "wand.and.stars")
                    }
                    .disabled(!model.canRender)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    private func chooseVideo() { model.openFile() }
}

struct FaceListColumn: View {
    @ObservedObject var model: SwapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isDetecting {
                HStack { ProgressView().controlSize(.small); Text("Finding faces…") }
                    .padding(12)
            }
            if model.faces.isEmpty && !model.isDetecting {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.videoPath == nil ? "No file open" : "No faces in this frame")
                        .font(.headline)
                    Text(model.videoPath == nil ? "Open a video or photo to start."
                                                : "Move to another frame on the right.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(12)
            }
            List(model.faces) { face in
                FaceRow(face: face, model: model)
                    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
            }
            .listStyle(.inset)
        }
        .navigationTitle("Faces")
    }
}

struct FaceRow: View {
    let face: DetectedFace
    @ObservedObject var model: SwapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                thumb(face.thumbnail)
                Image(systemName: "arrow.right")
                    .foregroundStyle(face.sourcePath == nil ? .tertiary : .primary)
                // A real Button, not a tap gesture: inside a List the row swallows taps.
                Button(action: pickSource) {
                    thumb(face.sourceImage, placeholder: "plus")
                }
                .buttonStyle(.plain)
                .help("Choose the photo to put on this face")
                .onDrop(of: [ .fileURL ], isTargeted: nil) { providers in
                    guard let provider = providers.first, provider.canLoadObject(ofClass: URL.self) else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, url.isFileURL else { return }
                        DispatchQueue.main.async { model.assign(url.path, to: face.id) }
                    }
                    return true
                }
            }
            HStack {
                Text("Face \(face.id)").font(.callout.weight(.medium))
                Spacer()
                if face.sourcePath == nil {
                    Button("Choose photo…", action: pickSource)
                        .controlSize(.small)
                } else {
                    Button("Remove") { model.assign(nil, to: face.id) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .cardStyle()
    }

    private func thumb(_ image: NSImage?, placeholder: String = "person.fill") -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Surface.radius).fill(Surface.canvas)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: Surface.radius))
            } else {
                Image(systemName: placeholder).foregroundStyle(.secondary)
            }
        }
        .frame(width: 78, height: 78)
        .overlay(RoundedRectangle(cornerRadius: Surface.radius).stroke(Surface.border))
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ .image ]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the face to put on Face \(face.id)"
        let slot = face.id
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { model.assign(url.path, to: slot) }
        }
        // Sheet on the window when there is one; otherwise a standalone modal run,
        // which also keeps the panel from being released before it is answered.
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }
}

struct QualityColumn: View {
    @ObservedObject var model: SwapModel

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Speed", selection: $model.speed) {
                    ForEach(RenderSpeed.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.speed.blurb).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Model", selection: $model.swapperModel) {
                Text("inswapper_128 — strongest identity").tag("inswapper_128")
                Text("hyperswap_1a_256").tag("hyperswap_1a_256")
                Text("simswap_256").tag("simswap_256")
                Text("uniface_256").tag("uniface_256")
            }
            VStack(alignment: .leading) {
                Text("Strength \(model.swapWeight, specifier: "%.2f")")
                Slider(value: $model.swapWeight, in: 0...1, step: 0.05)
            }
            Picker("Detail", selection: $model.pixelBoost) {
                Text("128 — fastest").tag("128x128")
                Text("256").tag("256x256")
                Text("512 — sharpest").tag("512x512")
            }
            Toggle("Sharpen faces afterwards", isOn: $model.useEnhancer)
            Toggle("Steadier in video (slower)", isOn: $model.steadyMode)
            Stepper("Threads: \(model.threadCount)", value: $model.threadCount, in: 1...12)
            Text("Changing these on their own overrides the Speed preset above.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("Quality")
    }
}

struct OutputColumn: View {
    @ObservedObject var model: SwapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let output = model.outputPath {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last result").font(.headline)
                    Text(URL(fileURLWithPath: output).lastPathComponent)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: output)) }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([ URL(fileURLWithPath: output) ])
                        }
                    }
                }
                .cardStyle()
            } else {
                Text("Nothing rendered yet.").foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            Text("Engine log").font(.headline)
            ScrollView {
                Text(model.log.isEmpty ? "—" : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .cardStyle()
            Spacer()
        }
        .padding(12)
        .navigationTitle("Output")
    }
}

struct LinkBar: View {
    @ObservedObject var model: SwapModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField("Paste a video link (YouTube, X, TikTok, Vimeo…)", text: $model.urlText)
                .textFieldStyle(.plain)
                .onSubmit { model.downloadFromURL() }
                .disabled(model.isDownloading)
            if model.isConverting {
                ProgressView().controlSize(.small)
                Text("Converting…").font(.callout).foregroundStyle(.secondary)
            } else if model.isDownloading {
                ProgressView(value: model.downloadProgress).frame(width: 90)
                Button(role: .destructive) { model.cancelDownload() } label: { Text("Stop") }
                    .buttonStyle(.borderless)
            } else {
                Button("Download") { model.downloadFromURL() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .overlay(alignment: .bottomLeading) { EmptyView() }
        .padding(10)
        .background(Surface.card)
        .overlay(RoundedRectangle(cornerRadius: Surface.radius).stroke(Surface.border))
        .clipShape(RoundedRectangle(cornerRadius: Surface.radius))
    }
}

struct LogSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine log").font(.headline)
            ScrollView {
                Text(text.isEmpty ? "Nothing logged yet." : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Surface.canvas)
            .overlay(RoundedRectangle(cornerRadius: Surface.radius).stroke(Surface.border))
            .clipShape(RoundedRectangle(cornerRadius: Surface.radius))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Reveal log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([ Engine.logFile ])
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 720, height: 460)
    }
}

struct DetailCanvas: View {
    @ObservedObject var model: SwapModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            LinkBar(model: model)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
            if let saved = model.savedDownloadPath {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved \(URL(fileURLWithPath: saved).lastPathComponent)")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ URL(fileURLWithPath: saved) ])
                    }
                    Button("Use this video") { model.videoPath = saved }
                        .buttonStyle(.borderedProminent)
                    Button {
                        model.savedDownloadPath = nil
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                .font(.callout)
                .padding(10)
                .background(Surface.card)
                .overlay(RoundedRectangle(cornerRadius: Surface.radius).stroke(Surface.border))
                .clipShape(RoundedRectangle(cornerRadius: Surface.radius))
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            ZStack {
                Surface.canvas
                if let preview = model.previewPath?.components(separatedBy: "?").first,
                   let image = NSImage(contentsOfFile: preview) {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fit)
                        .padding(16)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "film").font(.system(size: 42)).foregroundStyle(.tertiary)
                        Text("Open a file, or drop a video link above")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Drop a link straight onto the canvas: a dragged link, or selected text.
            .onDrop(of: [ .url, .fileURL, .plainText ], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async {
                            if url.isFileURL { model.videoPath = url.path } else { model.downloadFromURL(url.absoluteString) }
                        }
                    }
                    return true
                }
                if provider.canLoadObject(ofClass: NSString.self) {
                    _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                        guard let text = text as? String else { return }
                        DispatchQueue.main.async { model.downloadFromURL(text) }
                    }
                    return true
                }
                return false
            }

            VStack(spacing: 10) {
                if model.isVideo && model.frameCount > 1 {
                    HStack(spacing: 12) {
                        Text("Frame").font(.callout)
                        Slider(value: Binding(
                            get: { Double(model.frameNumber) },
                            set: { model.frameNumber = Int($0) }
                        ), in: 0...Double(max(1, model.frameCount - 1)), step: 1) { editing in
                            if !editing { Task { await model.refreshFrame() } }
                        }
                        Text("\(model.frameNumber)").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                HStack(spacing: 12) {
                    if model.isRendering {
                        ProgressView(value: model.progress).frame(width: 180)
                        Text("\(Int(model.progress * 100))%").monospacedDigit()
                    }
                    Text(model.statusLine).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("View log") { showLog = true }
                        .help("What the engine printed, including any error")
                    Button("Open file…") { model.openFile() }
                    Button("New") { model.reset() }
                    if model.isRendering {
                        Button(role: .destructive) { model.cancelRender() } label: { Text("Cancel") }
                    } else {
                        Button {
                            model.render()
                        } label: {
                            Label("Swap faces", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.blockedReason != nil)
                        .help(model.blockedReason ?? "Render the swap")
                    }
                }
                if let reason = model.blockedReason, !model.isRendering, !model.isDownloading {
                    HStack {
                        Spacer()
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Surface.card)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Surface.border), alignment: .top)
        }
        .sheet(isPresented: $showLog) {
            LogSheet(text: model.log.isEmpty ? ((try? String(contentsOf: Engine.logFile, encoding: .utf8)) ?? "") : model.log)
        }
    }
}

// MARK: - App

@main
struct FaceFusionApp: App {
    var body: some Scene {
        WindowGroup {
            Group {
                if Engine.isInstalled {
                    RootView()
                } else {
                    VStack(spacing: 10) {
                        Text("FaceFusion engine not found").font(.title3.weight(.semibold))
                        Text("Expected it at \(Engine.root.path)").foregroundStyle(.secondary)
                    }
                    .padding(40)
                }
            }
            .frame(minWidth: 950, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}
