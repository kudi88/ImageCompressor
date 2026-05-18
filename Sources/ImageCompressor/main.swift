import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO

// MARK: - Data Models

enum OutputFormat: String, CaseIterable {
    case jpeg = "JPEG"
    case png = "PNG"
    case original = "保持原格式"

    var uti: String? {
        switch self {
        case .jpeg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .original: return nil
        }
    }

    var extensionName: String? {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .original: return nil
        }
    }
}

enum CompressStatus: Equatable {
    case pending
    case compressing
    case done
    case failed(String)

    var isPendingOrFailed: Bool {
        switch self {
        case .pending, .failed: return true
        default: return false
        }
    }

    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}

struct ImageItem: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let originalSize: Int64
    var compressedSize: Int64? = nil
    var status: CompressStatus = .pending
    var outputURL: URL? = nil

    var originalSizeStr: String {
        ByteCountFormatter.string(fromByteCount: originalSize, countStyle: .file)
    }

    var compressedSizeStr: String {
        if let s = compressedSize {
            return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
        }
        return "-"
    }

    var ratioStr: String {
        guard let s = compressedSize, originalSize > 0 else { return "-" }
        let r = Double(s) / Double(originalSize)
        return String(format: "%.0f%%", (1 - r) * 100)
    }

    var fileExt: String {
        url.pathExtension.lowercased()
    }

    var isImageFile: Bool {
        let exts: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "webp"]
        return exts.contains(fileExt)
    }
}

// MARK: - Compressor Engine

class CompressorEngine {
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "webp"]

    static func compress(
        sourceURL: URL,
        outputDir: URL,
        quality: Double,
        outputFormat: OutputFormat
    ) throws -> (outputURL: URL, compressedSize: Int64) {
        // Determine output format & extension
        let sourceExt = sourceURL.pathExtension.lowercased()
        let outUTI: String
        let outExt: String
        let isPNGOutput: Bool

        switch outputFormat {
        case .jpeg:
            outUTI = UTType.jpeg.identifier
            outExt = "jpg"
            isPNGOutput = false
        case .png:
            outUTI = UTType.png.identifier
            outExt = "png"
            isPNGOutput = true
        case .original:
            if sourceExt == "jpg" || sourceExt == "jpeg" {
                outUTI = UTType.jpeg.identifier
                outExt = "jpg"
                isPNGOutput = false
            } else if sourceExt == "png" {
                outUTI = UTType.png.identifier
                outExt = "png"
                isPNGOutput = true
            } else {
                // Default to JPEG for other formats
                outUTI = UTType.jpeg.identifier
                outExt = "jpg"
                isPNGOutput = false
            }
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputFileName = "\(baseName).\(outExt)"
        let outputURL = outputDir.appendingPathComponent(outputFileName)

        // Handle file name collision
        var finalURL = outputURL
        var counter = 1
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        while FileManager.default.fileExists(atPath: finalURL.path) {
            let renamed = "\(baseName)_\(counter).\(outExt)"
            finalURL = outputDir.appendingPathComponent(renamed)
            counter += 1
        }

        // PNG path: use pngquant for real lossy PNG compression (color quantization)
        if isPNGOutput {
            return try compressPNG(
                sourceURL: sourceURL,
                outputURL: finalURL,
                quality: quality
            )
        }

        // JPEG path: decode, handle alpha, re-encode with quality
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CompressError.unsupportedFormat
        }

        guard let dest = CGImageDestinationCreateWithURL(finalURL as CFURL, outUTI as CFString, 1, nil) else {
            throw CompressError.destinationCreateFailed
        }

        // For JPEG, we need to handle alpha channel by drawing on white background
        let finalImage: CGImage
        if cgImage.alphaInfo == .first || cgImage.alphaInfo == .last || cgImage.alphaInfo == .premultipliedFirst || cgImage.alphaInfo == .premultipliedLast {
            // Has alpha, composite on white
            let width = cgImage.width
            let height = cgImage.height
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw CompressError.contextCreateFailed
            }
            ctx.setFillColor(CGColor.white)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let composed = ctx.makeImage() else {
                throw CompressError.contextCreateFailed
            }
            finalImage = composed
        } else {
            finalImage = cgImage
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1
        ]

        CGImageDestinationAddImage(dest, finalImage, options as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw CompressError.finalizeFailed
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: finalURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        return (finalURL, fileSize)
    }

    enum CompressError: LocalizedError {
        case unsupportedFormat
        case destinationCreateFailed
        case contextCreateFailed
        case finalizeFailed
        case pngquantFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "不支持的图片格式"
            case .destinationCreateFailed: return "无法创建输出文件"
            case .contextCreateFailed: return "图片处理失败"
            case .finalizeFailed: return "压缩写入失败"
            case .pngquantFailed(let msg): return "PNG压缩失败: \(msg)"
            }
        }
    }

    // MARK: - PNG Compression via pngquant

    /// Compress PNG using pngquant (lossy color quantization).
    /// Quality is 0.0-1.0 (passed from slider value / 100).
    private static func compressPNG(
        sourceURL: URL,
        outputURL: URL,
        quality: Double
    ) throws -> (outputURL: URL, compressedSize: Int64) {
        let pngquantPath = "/opt/homebrew/bin/pngquant"

        // Check pngquant availability
        guard FileManager.default.isExecutableFile(atPath: pngquantPath) else {
            // Fallback: copy original if pngquant not installed
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = (attrs[.size] as? Int64) ?? 0
            return (outputURL, fileSize)
        }

        // quality is 0.0~1.0, convert to pngquant params
        // Higher quality → more colors, higher pngquant quality range
        let pct = quality * 100.0  // back to 0-100 scale

        // pngquant --quality=min-max (0-100 scale)
        // pct=100 → --quality=85-100, 256 colors
        // pct=50  → --quality=20-55,  128 colors
        // pct=10  → --quality=5-15,   32 colors
        let minQ = Int(max(5, pct * 0.4))
        let maxQ = Int(max(Double(minQ) + 10, min(100, pct * 1.1)))

        // Map to color count
        let maxColors = Int(max(16, 256 * quality))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pngquantPath)
        process.arguments = [
            "--quality=\(minQ)-\(maxQ)",
            "\(maxColors)",
            "--force",
            "--output", outputURL.path,
            "--",
            sourceURL.path
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: outputURL.path) {
            let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let _ = String(data: errorData, encoding: .utf8) ?? "unknown"

            // pngquant returns exit code 2 when it can't achieve the requested quality
            // Fallback: just use 256 colors without quality constraint
            let retryProcess = Process()
            retryProcess.executableURL = URL(fileURLWithPath: pngquantPath)
            retryProcess.arguments = [
                "256",
                "--force",
                "--output", outputURL.path,
                "--",
                sourceURL.path
            ]
            let retryErrPipe = Pipe()
            retryProcess.standardError = retryErrPipe
            try retryProcess.run()
            retryProcess.waitUntilExit()

            if retryProcess.terminationStatus != 0 || !FileManager.default.fileExists(atPath: outputURL.path) {
                // Final fallback: copy original
                try? FileManager.default.removeItem(at: outputURL)
                try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            }
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        return (outputURL, fileSize)
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @Published var imageItems: [ImageItem] = []
    @Published var quality: Double = UserDefaults.standard.double(forKey: "compress_quality") {
        didSet { UserDefaults.standard.set(quality, forKey: "compress_quality") }
    }
    @Published var outputFormat: OutputFormat = {
        if let raw = UserDefaults.standard.string(forKey: "output_format"),
           let fmt = OutputFormat(rawValue: raw) {
            return fmt
        }
        return .jpeg
    }() {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: "output_format") }
    }
    @Published var outputDirectory: String = UserDefaults.standard.string(forKey: "output_directory") ?? "" {
        didSet { UserDefaults.standard.set(outputDirectory, forKey: "output_directory") }
    }
    @Published var isCompressing: Bool = false
    @Published var progress: Double = 0
    @Published var isDropTargeted: Bool = false

    init() {
        // First launch default: 50%
        if UserDefaults.standard.object(forKey: "compress_quality") == nil {
            quality = 50
        }
    }

    var totalCount: Int { imageItems.count }
    var doneCount: Int { imageItems.filter { if case .done = $0.status { return true } else { return false } }.count }
    var totalOriginalSize: Int64 { imageItems.reduce(0) { $0 + $1.originalSize } }
    var totalCompressedSize: Int64 { imageItems.compactMap { $0.compressedSize }.reduce(0, +) }

    var totalRatioStr: String {
        let orig = totalOriginalSize
        guard orig > 0, totalCompressedSize > 0 else { return "-" }
        let r = Double(totalCompressedSize) / Double(orig)
        return String(format: "%.0f%%", (1 - r) * 100)
    }

    var canCompress: Bool {
        !imageItems.isEmpty && !isCompressing && imageItems.contains { $0.status.isPendingOrFailed }
    }

    func addImages(from urls: [URL]) {
        var newItems: [ImageItem] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

            if isDir.boolValue {
                // Directory: scan for images
                if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    for fileURL in contents {
                        let ext = fileURL.pathExtension.lowercased()
                        if CompressorEngine.supportedExtensions.contains(ext) {
                            addItem(fileURL, to: &newItems)
                        }
                    }
                }
            } else {
                let ext = url.pathExtension.lowercased()
                if CompressorEngine.supportedExtensions.contains(ext) {
                    addItem(url, to: &newItems)
                }
            }
        }
        imageItems.append(contentsOf: newItems)

        // Auto set output dir to first image's parent + /compressed
        if outputDirectory.isEmpty, let first = imageItems.first {
            let parent = first.url.deletingLastPathComponent()
            outputDirectory = parent.appendingPathComponent("compressed").path
        }
    }

    private func addItem(_ url: URL, to items: inout [ImageItem]) {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        items.append(ImageItem(
            url: url,
            fileName: url.lastPathComponent,
            originalSize: size
        ))
    }

    func removeItem(at offsets: IndexSet) {
        imageItems.remove(atOffsets: offsets)
    }

    func clearAll() {
        imageItems.removeAll()
        progress = 0
    }

    func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择输出目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }

    func selectFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择图片"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .image,
            .png,
            .jpeg,
            .tiff,
            .bmp,
            .heic,
        ]

        if panel.runModal() == .OK {
            addImages(from: panel.urls)
        }
    }

    func startCompress() {
        guard canCompress else { return }
        isCompressing = true
        progress = 0

        let pendingItems = imageItems.filter { $0.status.isPendingOrFailed }
        let total = Double(pendingItems.count)
        let q = quality / 100.0
        let fmt = outputFormat
        let outDir = outputDirectory

        var completed = 0.0

        Task.detached { [weak self] in
            guard let self = self else { return }
            for item in pendingItems {
                let idx = await self.imageItems.firstIndex(where: { $0.id == item.id })
                guard let i = idx else { continue }

                await self.updateItem(i) { $0.status = .compressing }

                let outputDirURL = URL(fileURLWithPath: outDir)
                do {
                    let result = try CompressorEngine.compress(
                        sourceURL: item.url,
                        outputDir: outputDirURL,
                        quality: q,
                        outputFormat: fmt
                    )
                    await self.updateItem(i) {
                        $0.status = .done
                        $0.compressedSize = result.compressedSize
                        $0.outputURL = result.outputURL
                    }
                } catch {
                    await self.updateItem(i) {
                        $0.status = .failed(error.localizedDescription)
                    }
                }

                completed += 1
                await MainActor.run {
                    self.progress = completed / total
                }
            }

            await MainActor.run {
                self.isCompressing = false
            }
        }
    }

    private func updateItem(_ index: Int, _ update: (inout ImageItem) -> Void) async {
        update(&imageItems[index])
    }

    func openOutputDir() {
        guard !outputDirectory.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: outputDirectory))
    }

    func revealInFinder(_ item: ImageItem) {
        if let url = item.outputURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

// MARK: - Views

struct DropZoneView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(state.isDropTargeted ? Color.accentColor : .secondary)

            Text(state.isDropTargeted ? "释放以添加图片" : "拖拽图片到此处")
                .font(.title3)
                .foregroundStyle(state.isDropTargeted ? Color.accentColor : .primary)

            Text("或点击选择文件 / 文件夹")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("选择文件") {
                state.selectFiles()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .foregroundStyle(state.isDropTargeted ? Color.accentColor : .secondary.opacity(0.5))
        )
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(state.isDropTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
        )
        .onDrop(of: [.fileURL], isTargeted: $state.isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, error in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                urls.append(url)
            }
        }

        group.notify(queue: .main) {
            state.addImages(from: urls)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Quality
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("压缩质量")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(state.quality))%")
                        .font(.title3.monospacedDigit().bold())
                        .foregroundStyle(Color.accentColor)
                }
                Slider(value: $state.quality, in: 10...100, step: 5) {
                    Text("质量")
                }
                HStack {
                    Text("低质量 · 小文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("高质量 · 大文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Output format
            VStack(alignment: .leading, spacing: 6) {
                Text("输出格式")
                    .font(.headline)
                Picker("输出格式", selection: $state.outputFormat) {
                    ForEach(OutputFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            // Output directory
            VStack(alignment: .leading, spacing: 6) {
                Text("输出目录")
                    .font(.headline)
                HStack {
                    TextField("输出路径", text: $state.outputDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button("选择") {
                        state.selectOutputDirectory()
                    }
                    Button {
                        state.openOutputDir()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("在 Finder 中打开")
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ImageRowView: View {
    let item: ImageItem
    var onReveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .frame(width: 20)

            // File name
            Text(item.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 180, alignment: .leading)

            Spacer()

            // Original size
            Text(item.originalSizeStr)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
                .monospacedDigit()

            // Arrow
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)

            // Compressed size
            Text(item.compressedSizeStr)
                .foregroundStyle(item.status.isDone ? .green : .secondary)
                .frame(width: 80, alignment: .trailing)
                .monospacedDigit()

            // Ratio
            Text(item.ratioStr)
                .foregroundStyle(ratioColor)
                .bold()
                .frame(width: 60, alignment: .trailing)
                .monospacedDigit()

            // Reveal button
            if item.status.isDone {
                Button {
                    onReveal()
                } label: {
                    Image(systemName: "folder.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .compressing:
            ProgressView()
                .scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let msg):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(msg)
        }
    }

    private var ratioColor: Color {
        guard let s = item.compressedSize, item.originalSize > 0 else { return .secondary }
        let r = Double(s) / Double(item.originalSize)
        if r < 0.3 { return .green }
        if r < 0.6 { return .orange }
        return .red
    }
}

struct ResultListView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("文件名")
                    .frame(minWidth: 180, alignment: .leading)
                Spacer()
                Text("原大小")
                    .frame(width: 80, alignment: .trailing)
                Text("→")
                    .frame(width: 20, alignment: .center)
                Text("压缩后")
                    .frame(width: 80, alignment: .trailing)
                Text("压缩率")
                    .frame(width: 60, alignment: .trailing)
                Color.clear.frame(width: 26)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)

            Divider()

            // List
            if state.imageItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("暂无图片")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.imageItems) { item in
                            ImageRowView(item: item) {
                                state.revealInFinder(item)
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                }
            }

            Divider()

            // Summary bar
            HStack {
                Text("已选 \(state.totalCount) 张图片")
                    .foregroundStyle(.secondary)

                Spacer()

                if state.totalCompressedSize > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: state.totalOriginalSize, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: state.totalCompressedSize, countStyle: .file))")
                        .foregroundStyle(.secondary)

                    Text("节省 \(state.totalRatioStr)")
                        .bold()
                        .foregroundStyle(.green)
                }
            }
            .font(.callout)
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                // Drop zone
                DropZoneView(state: state)

                // Settings
                SettingsView(state: state)

                // Action buttons
                HStack {
                    Button("清空列表") {
                        state.clearAll()
                    }
                    .disabled(state.imageItems.isEmpty || state.isCompressing)

                    Spacer()

                    if state.isCompressing {
                        ProgressView(value: state.progress)
                            .frame(width: 120)
                        Text("\(Int(state.progress * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        state.startCompress()
                    } label: {
                        Label("开始压缩", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canCompress)
                    .controlSize(.large)
                }

                // Result list
                ResultListView(state: state)
            }
            .padding(20)
            .frame(minWidth: 680)
        }
        .frame(minWidth: 680, minHeight: 400)
    }
}

// MARK: - App Entry

@main
struct ImageCompressorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 700, height: 700)
    }
}
