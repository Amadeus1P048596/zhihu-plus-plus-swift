import CryptoKit
import SwiftUI
import UIKit
import WebKit

enum QAKaTeXRenderError: LocalizedError, Equatable {
    case emptyFormula
    case formulaTooLong
    case invalidPointSize
    case invalidScale
    case missingResource(String)
    case rendererUnavailable
    case renderingFailed(String)
    case outputTooLarge
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .emptyFormula: return "公式内容为空"
        case .formulaTooLong: return "公式内容过长"
        case .invalidPointSize: return "公式字号无效"
        case .invalidScale: return "显示缩放无效"
        case let .missingResource(name): return "缺少公式渲染资源：\(name)"
        case .rendererUnavailable: return "公式渲染器暂时不可用"
        case let .renderingFailed(message): return "公式渲染失败：\(message)"
        case .outputTooLarge: return "公式渲染尺寸过大"
        case .invalidOutput: return "公式渲染结果无效"
        }
    }
}

enum QAKaTeXRenderPolicy {
    static let maximumLatexUTF8Bytes = 16_384
    static let minimumPointSize: CGFloat = 8
    static let maximumPointSize: CGFloat = 96
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 3
    static let maximumLogicalDimension: CGFloat = 4_096
    static let maximumPixelCount: CGFloat = 16_000_000
    static let cacheCountLimit = 128
    static let cacheCostLimit = 24 * 1_024 * 1_024

    static func validate(_ request: QAKaTeXRenderRequest) throws {
        guard !request.latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QAKaTeXRenderError.emptyFormula
        }
        guard request.latex.lengthOfBytes(using: .utf8) <= maximumLatexUTF8Bytes else {
            throw QAKaTeXRenderError.formulaTooLong
        }
        guard request.pointSize.isFinite,
              (minimumPointSize...maximumPointSize).contains(request.pointSize)
        else {
            throw QAKaTeXRenderError.invalidPointSize
        }
        guard request.scale.isFinite,
              (minimumScale...maximumScale).contains(request.scale)
        else {
            throw QAKaTeXRenderError.invalidScale
        }
    }

    static func validateOutput(
        width: CGFloat,
        height: CGFloat,
        scale: CGFloat,
        baselineFromTop: CGFloat
    ) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw QAKaTeXRenderError.invalidOutput
        }
        guard baselineFromTop.isFinite,
              baselineFromTop > 0,
              baselineFromTop <= height
        else {
            throw QAKaTeXRenderError.invalidOutput
        }
        guard width <= maximumLogicalDimension,
              height <= maximumLogicalDimension,
              width * height * scale * scale <= maximumPixelCount
        else {
            throw QAKaTeXRenderError.outputTooLarge
        }
    }

    static func shouldCacheImage(cost: Int) -> Bool {
        cost > 0 && cost <= cacheCostLimit
    }
}

struct QAKaTeXRenderColor: Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    static let lightForeground = Self(red: 0, green: 0, blue: 0, alpha: 255)
    static let darkForeground = Self(red: 255, green: 255, blue: 255, alpha: 255)

    var cssValue: String {
        let opacity = String(format: "%.4f", Double(alpha) / 255)
        return "rgba(\(red),\(green),\(blue),\(opacity))"
    }
}

struct QAKaTeXRenderRequest: Hashable, Sendable {
    let latex: String
    let pointSize: CGFloat
    let color: QAKaTeXRenderColor
    let scale: CGFloat
    let isDarkMode: Bool
    let displayMode: Bool

    init(
        latex: String,
        pointSize: CGFloat,
        color: QAKaTeXRenderColor,
        scale: CGFloat,
        isDarkMode: Bool,
        displayMode: Bool
    ) {
        self.latex = latex
        self.pointSize = pointSize
        self.color = color
        self.scale = scale
        self.isDarkMode = isDarkMode
        self.displayMode = displayMode
    }

    var cacheKey: String {
        let digest = SHA256.hash(data: Data(latex.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let pointSizeKey = Int((pointSize * 100).rounded())
        let scaleKey = Int((scale * 100).rounded())
        return [
            "katex-0.18.1",
            digest,
            String(pointSizeKey),
            "\(color.red)-\(color.green)-\(color.blue)-\(color.alpha)",
            String(scaleKey),
            isDarkMode ? "dark" : "light",
            displayMode ? "display" : "inline",
        ].joined(separator: "|")
    }
}

struct QAKaTeXRenderResult {
    let image: UIImage
    let baselineFromTop: CGFloat
}

enum QAKaTeXResourceLocator {
    static let directoryName = "KaTeXResources"
    static let requiredRelativePaths = [
        "renderer.html",
        "renderer.css",
        "renderer.js",
        "katex.min.js",
        "katex.min.css",
        "LICENSE",
        "fonts/KaTeX_AMS-Regular.woff2",
        "fonts/KaTeX_Caligraphic-Bold.woff2",
        "fonts/KaTeX_Caligraphic-Regular.woff2",
        "fonts/KaTeX_Fraktur-Bold.woff2",
        "fonts/KaTeX_Fraktur-Regular.woff2",
        "fonts/KaTeX_Main-Bold.woff2",
        "fonts/KaTeX_Main-BoldItalic.woff2",
        "fonts/KaTeX_Main-Italic.woff2",
        "fonts/KaTeX_Main-Regular.woff2",
        "fonts/KaTeX_Math-BoldItalic.woff2",
        "fonts/KaTeX_Math-Italic.woff2",
        "fonts/KaTeX_SansSerif-Bold.woff2",
        "fonts/KaTeX_SansSerif-Italic.woff2",
        "fonts/KaTeX_SansSerif-Regular.woff2",
        "fonts/KaTeX_Script-Regular.woff2",
        "fonts/KaTeX_Size1-Regular.woff2",
        "fonts/KaTeX_Size2-Regular.woff2",
        "fonts/KaTeX_Size3-Regular.woff2",
        "fonts/KaTeX_Size4-Regular.woff2",
        "fonts/KaTeX_Typewriter-Regular.woff2",
    ]

    static func directoryURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: directoryName, withExtension: nil)
    }

    static func missingResources(in bundle: Bundle = .main) -> [String] {
        guard let directoryURL = directoryURL(in: bundle) else {
            return [directoryName]
        }
        return requiredRelativePaths.filter { relativePath in
            !FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent(relativePath).path
            )
        }
    }
}

@MainActor
final class QAKaTeXRenderService {
    static let shared = QAKaTeXRenderService()

    private struct WorkItem {
        let id: UUID
        let request: QAKaTeXRenderRequest
        let continuation: CheckedContinuation<QAKaTeXRenderResult, Error>
    }

    private final class CachedResult: NSObject {
        let value: QAKaTeXRenderResult

        init(_ value: QAKaTeXRenderResult) {
            self.value = value
        }
    }

    private let cache = NSCache<NSString, CachedResult>()
    private let engine: QAKaTeXWebEngine
    private var queue: [WorkItem] = []
    private var cancelledWorkIDs: Set<UUID> = []
    private var isDraining = false

    init(bundle: Bundle = .main) {
        cache.countLimit = QAKaTeXRenderPolicy.cacheCountLimit
        cache.totalCostLimit = QAKaTeXRenderPolicy.cacheCostLimit
        engine = QAKaTeXWebEngine(bundle: bundle)
    }

    func render(_ request: QAKaTeXRenderRequest) async throws -> QAKaTeXRenderResult {
        try QAKaTeXRenderPolicy.validate(request)
        if let cached = cache.object(forKey: request.cacheKey as NSString) {
            return cached.value
        }

        let workID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(WorkItem(id: workID, request: request, continuation: continuation))
                startDrainingIfNeeded()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(workID)
            }
        }
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    private func cancel(_ workID: UUID) {
        cancelledWorkIDs.insert(workID)
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            if cancelledWorkIDs.remove(item.id) != nil {
                item.continuation.resume(throwing: CancellationError())
                continue
            }
            if let cached = cache.object(forKey: item.request.cacheKey as NSString) {
                item.continuation.resume(returning: cached.value)
                continue
            }

            do {
                let result = try await engine.render(item.request)
                if cancelledWorkIDs.remove(item.id) != nil {
                    item.continuation.resume(throwing: CancellationError())
                    continue
                }
                let image = result.image
                let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                if QAKaTeXRenderPolicy.shouldCacheImage(cost: cost) {
                    cache.setObject(
                        CachedResult(result),
                        forKey: item.request.cacheKey as NSString,
                        cost: cost
                    )
                }
                item.continuation.resume(returning: result)
            } catch {
                cancelledWorkIDs.remove(item.id)
                item.continuation.resume(throwing: error)
            }
        }
        isDraining = false
        if !queue.isEmpty {
            startDrainingIfNeeded()
        }
    }
}

@MainActor
private final class QAKaTeXWebEngine: NSObject, WKNavigationDelegate, WKUIDelegate {
    private struct RenderMetrics {
        let width: CGFloat
        let height: CGFloat
        let baselineFromTop: CGFloat
    }

    private let resourceDirectoryURL: URL?
    private let webView: WKWebView
    private var isLoaded = false
    private var loadContinuation: CheckedContinuation<Void, Error>?

    init(bundle: Bundle) {
        resourceDirectoryURL = QAKaTeXResourceLocator.directoryURL(in: bundle)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 120), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
    }

    func render(_ request: QAKaTeXRenderRequest) async throws -> QAKaTeXRenderResult {
        try Task.checkCancellation()
        try await ensureLoaded()
        try Task.checkCancellation()

        let metrics = try await renderMetrics(for: request)
        try QAKaTeXRenderPolicy.validateOutput(
            width: metrics.width,
            height: metrics.height,
            scale: request.scale,
            baselineFromTop: metrics.baselineFromTop
        )
        webView.frame = CGRect(origin: .zero, size: CGSize(width: metrics.width, height: metrics.height))
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        await Task.yield()
        try Task.checkCancellation()

        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let snapshot = try await webView.takeSnapshot(configuration: configuration)
        try Task.checkCancellation()
        guard snapshot.size.width > 0, snapshot.size.height > 0 else {
            throw QAKaTeXRenderError.invalidOutput
        }
        let image = normalizedImage(snapshot, size: webView.bounds.size, scale: request.scale)
        return QAKaTeXRenderResult(
            image: image,
            baselineFromTop: metrics.baselineFromTop
        )
    }

    private func ensureLoaded() async throws {
        if isLoaded { return }
        guard let resourceDirectoryURL else {
            throw QAKaTeXRenderError.missingResource(QAKaTeXResourceLocator.directoryName)
        }
        let missing = QAKaTeXResourceLocator.requiredRelativePaths.first { relativePath in
            !FileManager.default.fileExists(
                atPath: resourceDirectoryURL.appendingPathComponent(relativePath).path
            )
        }
        if let missing {
            throw QAKaTeXRenderError.missingResource(missing)
        }
        guard loadContinuation == nil else {
            throw QAKaTeXRenderError.rendererUnavailable
        }

        let pageURL = resourceDirectoryURL.appendingPathComponent("renderer.html")
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.loadFileURL(pageURL, allowingReadAccessTo: resourceDirectoryURL)
        }
    }

    private func renderMetrics(for request: QAKaTeXRenderRequest) async throws -> RenderMetrics {
        let arguments: [String: Any] = [
            "request": [
                "latex": request.latex,
                "pointSize": request.pointSize,
                "color": request.color.cssValue,
                "accessibilityLabel": QALatexReadableText.render(request.latex),
                "displayMode": request.displayMode,
            ],
        ]
        let value = try await webView.callAsyncJavaScript(
            "return await window.renderFormula(request);",
            arguments: arguments,
            in: nil,
            contentWorld: .page
        )
        guard let result = value as? [String: Any],
              let succeeded = result["ok"] as? Bool
        else {
            throw QAKaTeXRenderError.invalidOutput
        }
        if !succeeded {
            let message = (result["error"] as? String).map { String($0.prefix(240)) } ?? "未知错误"
            throw QAKaTeXRenderError.renderingFailed(message)
        }
        guard let width = number(result["width"]),
              let height = number(result["height"]),
              let baselineFromTop = number(result["baselineFromTop"])
        else {
            throw QAKaTeXRenderError.invalidOutput
        }
        return RenderMetrics(
            width: width,
            height: height,
            baselineFromTop: baselineFromTop
        )
    }

    private func number(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
        if let number = value as? Double { return CGFloat(number) }
        return nil
    }

    private func normalizedImage(_ image: UIImage, size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(with: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        finishLoading(with: QAKaTeXRenderError.rendererUnavailable)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url,
              let resourceDirectoryURL,
              url.isFileURL,
              url.standardizedFileURL
                == resourceDirectoryURL
                    .appendingPathComponent("renderer.html")
                    .standardizedFileURL
        else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    private func finishLoading(with error: Error) {
        isLoaded = false
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}

private enum QAKaTeXFormulaPhase {
    case loading
    case rendered(QAKaTeXRenderResult)
    case fallback
}

struct QAKaTeXFormulaView: View {
    let latex: String
    let pointSize: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var phase = QAKaTeXFormulaPhase.loading

    private var request: QAKaTeXRenderRequest {
        QAKaTeXRenderRequest(
            latex: latex,
            pointSize: min(
                max(pointSize, QAKaTeXRenderPolicy.minimumPointSize),
                QAKaTeXRenderPolicy.maximumPointSize
            ),
            color: colorScheme == .dark ? .darkForeground : .lightForeground,
            scale: min(
                max(displayScale, QAKaTeXRenderPolicy.minimumScale),
                QAKaTeXRenderPolicy.maximumScale
            ),
            isDarkMode: colorScheme == .dark,
            displayMode: true
        )
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button {
                UIPasteboard.general.string = latex
                hapticFeedback(.longPress)
            } label: {
                Label("复制原始 TeX", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("公式 \(QALatexReadableText.render(latex))")
        .accessibilityHint("长按可复制原始 TeX")
        .task(id: request.cacheKey) {
            phase = .loading
            do {
                phase = .rendered(try await QAKaTeXRenderService.shared.render(request))
            } catch is CancellationError {
                return
            } catch {
                phase = .fallback
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(minWidth: 32, minHeight: pointSize * 1.5)
                .accessibilityLabel("正在渲染公式")
        case let .rendered(result):
            Image(uiImage: result.image)
                .resizable()
                .interpolation(.high)
                .frame(width: result.image.size.width, height: result.image.size.height)
        case .fallback:
            Text(QALatexReadableText.render(latex))
                .font(.system(size: pointSize, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
