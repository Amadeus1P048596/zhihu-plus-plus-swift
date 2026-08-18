import AVKit
import SwiftUI
import UIKit

struct QABodyView: View {
    let blocks: [QABodyBlock]
    let segmentSubject: CommentSubjectDTO?
    let onNavigate: (QANavigationIntent) -> Void
    @Environment(\.nativeContentPresentation) private var presentation
    @ScaledMetric(relativeTo: .body) private var bodyPointSize: CGFloat = 17
    @ScaledMetric(relativeTo: .callout) private var calloutPointSize: CGFloat = 16

    init(
        blocks: [QABodyBlock],
        segmentSubject: CommentSubjectDTO? = nil,
        onNavigate: @escaping (QANavigationIntent) -> Void
    ) {
        self.blocks = blocks
        self.segmentSubject = segmentSubject
        self.onNavigate = onNavigate
    }

    private var galleryImages: [QAImageDTO] {
        blocks.compactMap { block in
            guard case let .image(image) = block else { return nil }
            return image
        }
    }

    private var galleryURLs: [URL] { galleryImages.map(\.url) }

    var body: some View {
        // Keep the complete document in one selection hierarchy. A LazyVStack
        // recycles off-screen Text views, which truncates Select All/copy for
        // long answers after scrolling.
        VStack(alignment: .leading, spacing: presentation.blockSpacing()) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let destination = QABodyLinkResolver.resolve(url) else { return .discarded }
            onNavigate(.link(destination))
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: QABodyBlock) -> some View {
        switch block {
        case let .paragraph(_, runs):
            inlineText(
                runs,
                font: bodyFont,
                uiFont: bodyUIFont,
                lineSpacing: bodyLineSpacing
            )
        case let .heading(_, level, runs):
            inlineText(
                runs,
                font: headingFont(level),
                uiFont: headingUIFont(level),
                fontWeight: .bold
            )
                .padding(.top, level <= 2 ? 8 : 2)
        case let .quote(_, runs):
            HStack(alignment: .top, spacing: 12) {
                Capsule().fill(.secondary.opacity(0.38)).frame(width: 3)
                inlineText(
                    runs,
                    font: bodyFont,
                    uiFont: bodyUIFont,
                    foregroundColor: .secondary,
                    uiForegroundColor: .secondaryLabel,
                    lineSpacing: bodyLineSpacing
                )
            }
        case let .list(_, kind, items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(listRows(kind: kind, items: items)) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.marker)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(
                            row.runs,
                            font: bodyFont,
                            uiFont: bodyUIFont,
                            lineSpacing: bodyLineSpacing
                        )
                    }
                    .padding(.leading, CGFloat(row.depth) * 20)
                }
            }
        case let .code(_, language, text):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    if let language, !language.isEmpty {
                        Text(language.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(text)
                        .font(.system(size: calloutPointSize * presentation.fontScale, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(14)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        case let .formula(_, latex):
            QAKaTeXFormulaView(
                latex: latex,
                pointSize: bodyPointSize * presentation.fontScale
            )
        case let .image(image):
            Button {
                let index = galleryImages.firstIndex { $0.id == image.id } ?? 0
                onNavigate(.images(urls: galleryURLs, initialIndex: index))
            } label: {
                VStack(spacing: 7) {
                    QABodyRemoteImage(image: image)
                    if let caption = image.caption ?? image.altText, !caption.isEmpty {
                        Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(image.altText ?? image.caption ?? "查看图片")
        case let .segment(_, segmentID, runs):
            if let segmentSubject,
               let subject = segmentCommentSubject(segmentSubject, segmentID: segmentID) {
                HStack(alignment: .bottom, spacing: 7) {
                    inlineText(
                        runs,
                        font: bodyFont,
                        uiFont: bodyUIFont,
                        lineSpacing: bodyLineSpacing
                    )
                    Button {
                        onNavigate(.segmentComments(CommentThreadRouteDTO(subject: subject)))
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看本段评论")
                }
            } else {
                HStack(alignment: .bottom, spacing: 7) {
                    inlineText(
                        runs,
                        font: bodyFont,
                        uiFont: bodyUIFont,
                        lineSpacing: bodyLineSpacing
                    )
                }
            }
        case let .video(_, video):
            if video.playbackURL != nil {
                QANativeVideoPlayer(video: video)
            } else {
                QAVideoAttachmentView(video: video) {
                    onNavigate(.video(videoRoute(video)))
                }
            }
        case .divider:
            Divider()
        }
    }

    private var bodyFont: Font {
        .system(size: bodyPointSize * presentation.fontScale)
    }

    private var bodyUIFont: UIFont {
        .systemFont(ofSize: bodyPointSize * presentation.fontScale)
    }

    private var bodyLineSpacing: CGFloat {
        presentation.extraLineSpacing(for: bodyPointSize * presentation.fontScale)
    }

    private func headingFont(_ level: Int) -> Font {
        let scale = presentation.fontScale
        switch level {
        case 1: return .system(size: 22 * scale, weight: .bold)
        case 2: return .system(size: 20 * scale, weight: .bold)
        case 3: return .system(size: 17 * scale, weight: .semibold)
        default: return .system(size: bodyPointSize * scale, weight: .semibold)
        }
    }

    private func headingUIFont(_ level: Int) -> UIFont {
        let scale = presentation.fontScale
        switch level {
        case 1: return .systemFont(ofSize: 22 * scale, weight: .bold)
        case 2: return .systemFont(ofSize: 20 * scale, weight: .bold)
        case 3: return .systemFont(ofSize: 17 * scale, weight: .bold)
        default: return .systemFont(ofSize: bodyPointSize * scale, weight: .bold)
        }
    }

    @ViewBuilder
    private func inlineText(
        _ runs: [QAInlineRun],
        font: Font,
        uiFont: UIFont,
        fontWeight: Font.Weight? = nil,
        foregroundColor: Color = .primary,
        uiForegroundColor: UIColor = .label,
        lineSpacing: CGFloat = 0
    ) -> some View {
        if runs.contains(where: { $0.formulaLatex != nil }) {
            QASelectableInlineFormulaText(
                runs: runs,
                font: uiFont,
                foregroundColor: uiForegroundColor,
                lineSpacing: lineSpacing
            ) { url in
                guard let destination = QABodyLinkResolver.resolve(url) else { return }
                onNavigate(.link(destination))
            }
        } else {
            Text(QARichTextFormatter.attributed(runs))
                .font(font)
                .fontWeight(fontWeight)
                .foregroundStyle(foregroundColor)
                .lineSpacing(lineSpacing)
                .tint(.accentColor)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
    }

    private func listRows(kind: QAListKind, items: [QAListItem]) -> [QAListDisplayRow] {
        flattenList(QAListGroup(kind: kind, items: items), depth: 0)
    }

    private func flattenList(_ group: QAListGroup, depth: Int) -> [QAListDisplayRow] {
        group.items.enumerated().flatMap { index, item in
            let number = item.ordinal ?? group.startIndex + index
            let marker = group.kind == .ordered ? "\(number)." : "•"
            let row = QAListDisplayRow(
                id: item.id,
                marker: marker,
                depth: depth,
                runs: item.runs
            )
            return [row] + item.nestedLists.flatMap {
                flattenList($0, depth: depth + 1)
            }
        }
    }

    private func segmentCommentSubject(
        _ subject: CommentSubjectDTO,
        segmentID: String
    ) -> CommentSubjectDTO? {
        switch subject {
        case let .answer(id): return .segment(contentID: String(id), contentTypeRaw: "answer", segmentID: segmentID)
        case let .article(id): return .segment(contentID: String(id), contentTypeRaw: "article", segmentID: segmentID)
        case let .question(id): return .segment(contentID: String(id), contentTypeRaw: "question", segmentID: segmentID)
        case let .pin(id): return .segment(contentID: String(id), contentTypeRaw: "pin", segmentID: segmentID)
        case .segment: return nil
        }
    }

    private func videoRoute(_ video: QAAttachmentVideoDTO) -> NativeVideoRouteDTO {
        let contentID: Int64
        let contentType: NativeVideoContentType
        switch segmentSubject {
        case let .answer(id):
            contentID = id
            contentType = .answer
        case let .article(id):
            contentID = id
            contentType = .article
        case let .question(id):
            contentID = id
            contentType = .question
        case let .pin(id):
            contentID = id
            contentType = .zvideo
        case .segment, .none:
            contentID = video.videoID
            contentType = .zvideo
        }
        return NativeVideoRouteDTO(
            contentID: contentID,
            videoID: video.videoID,
            contentType: contentType,
            thumbnailURL: video.thumbnailURL,
            playbackURL: video.playbackURL,
            webURL: video.destinationURL
        )
    }
}

private struct QAListDisplayRow: Identifiable {
    let id: UUID
    let marker: String
    let depth: Int
    let runs: [QAInlineRun]
}

private struct QASelectableInlineFormulaText: View {
    let runs: [QAInlineRun]
    let font: UIFont
    let foregroundColor: UIColor
    let lineSpacing: CGFloat
    let onOpenURL: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var renderedFormulas: [UUID: QAKaTeXRenderResult] = [:]
    @State private var failedFormulaIDs: Set<UUID> = []

    private var formulaRuns: [QAInlineRun] {
        runs.filter { $0.formulaLatex != nil }
    }

    private func renderColor(for run: QAInlineRun) -> QAKaTeXRenderColor {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let baseColor = run.link == nil ? foregroundColor : UIColor(Color.accentColor)
        let resolved = baseColor.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return colorScheme == .dark ? .darkForeground : .lightForeground
        }
        return QAKaTeXRenderColor(
            red: UInt8((red * 255).rounded().clamped(to: 0...255)),
            green: UInt8((green * 255).rounded().clamped(to: 0...255)),
            blue: UInt8((blue * 255).rounded().clamped(to: 0...255)),
            alpha: UInt8((alpha * 255).rounded().clamped(to: 0...255))
        )
    }

    private var renderTaskID: String {
        formulaRuns.map { run in
            guard let request = renderRequest(for: run) else { return run.id.uuidString }
            return "\(run.id.uuidString):\(request.cacheKey)"
        }.joined(separator: "|")
    }

    private var contentRevision: Int {
        var hasher = Hasher()
        hasher.combine(runs)
        hasher.combine(renderTaskID)
        hasher.combine(font.fontName)
        hasher.combine(font.fontDescriptor.symbolicTraits.rawValue)
        hasher.combine(lineSpacing)
        for id in renderedFormulas.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            hasher.combine(id)
        }
        for id in failedFormulaIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            hasher.combine(id)
        }
        return hasher.finalize()
    }

    var body: some View {
        QAInlineFormulaTextView(
            attributedText: QAInlineFormulaAttributedText.make(
                runs: runs,
                renderedFormulas: renderedFormulas,
                failedFormulaIDs: failedFormulaIDs,
                font: font,
                foregroundColor: foregroundColor,
                lineSpacing: lineSpacing
            ),
            contentRevision: contentRevision,
            onOpenURL: onOpenURL
        )
        .fixedSize(horizontal: false, vertical: true)
        .task(id: renderTaskID) {
            await renderInlineFormulas()
        }
    }

    private func renderRequest(for run: QAInlineRun) -> QAKaTeXRenderRequest? {
        guard let latex = run.formulaLatex else { return nil }
        return QAKaTeXRenderRequest(
            latex: latex,
            pointSize: font.pointSize.clamped(
                to: QAKaTeXRenderPolicy.minimumPointSize...QAKaTeXRenderPolicy.maximumPointSize
            ),
            color: renderColor(for: run),
            scale: displayScale.clamped(
                to: QAKaTeXRenderPolicy.minimumScale...QAKaTeXRenderPolicy.maximumScale
            ),
            isDarkMode: colorScheme == .dark,
            displayMode: false
        )
    }

    @MainActor
    private func renderInlineFormulas() async {
        renderedFormulas = [:]
        failedFormulaIDs = []

        for run in formulaRuns {
            guard let request = renderRequest(for: run) else { continue }
            do {
                let result = try await QAKaTeXRenderService.shared.render(request)
                try Task.checkCancellation()
                renderedFormulas[run.id] = result
            } catch is CancellationError {
                return
            } catch {
                failedFormulaIDs.insert(run.id)
            }
        }
    }
}

private struct QAInlineFormulaTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let contentRevision: Int
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(contentRevision: contentRevision, onOpenURL: onOpenURL)
    }

    func makeUIView(context: Context) -> UITextView {
        // The attachment overrides the TextKit 1 bounds callback so its
        // measured KaTeX baseline can participate in line layout on iOS 16+.
        let textView = UITextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = false
        textView.dataDetectorTypes = []
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.attributedText = attributedText
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        guard context.coordinator.contentRevision != contentRevision else { return }
        let selection = textView.selectedRange
        textView.attributedText = attributedText
        context.coordinator.contentRevision = contentRevision
        let location = selection.location == NSNotFound
            ? 0
            : min(selection.location, attributedText.length)
        textView.selectedRange = NSRange(
            location: location,
            length: min(selection.length, attributedText.length - location)
        )
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fittingSize.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var contentRevision: Int
        var onOpenURL: (URL) -> Void

        init(contentRevision: Int, onOpenURL: @escaping (URL) -> Void) {
            self.contentRevision = contentRevision
            self.onOpenURL = onOpenURL
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            onOpenURL(URL)
            return false
        }
    }
}

private final class QAInlineFormulaAttachment: NSTextAttachment {
    var baselineFromTop: CGFloat = 0

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFragment: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let availableWidth = lineFragment.width.isFinite && lineFragment.width > 0
            ? lineFragment.width
            : image.size.width
        let scale = min(1, availableWidth / image.size.width)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // Attachment y is its bottom edge relative to the text baseline.
        return CGRect(
            x: 0,
            y: baselineFromTop * scale - size.height,
            width: size.width,
            height: size.height
        )
    }
}

private enum QAInlineFormulaAttributedText {
    static func make(
        runs: [QAInlineRun],
        renderedFormulas: [UUID: QAKaTeXRenderResult],
        failedFormulaIDs: Set<UUID>,
        font: UIFont,
        foregroundColor: UIColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let value = NSMutableAttributedString(string: "")
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .natural
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = lineSpacing

        for run in runs {
            let attributes = attributes(
                for: run,
                baseFont: font,
                foregroundColor: foregroundColor,
                paragraphStyle: paragraphStyle
            )
            if let latex = run.formulaLatex {
                if let rendered = renderedFormulas[run.id] {
                    let attachment = QAInlineFormulaAttachment()
                    attachment.image = rendered.image
                    attachment.baselineFromTop = rendered.baselineFromTop
                    attachment.accessibilityLabel = "公式 \(QALatexReadableText.render(latex))"
                    let formula = NSMutableAttributedString(
                        attributedString: NSAttributedString(attachment: attachment)
                    )
                    formula.addAttributes(attributes, range: NSRange(location: 0, length: formula.length))
                    value.append(formula)
                } else {
                    let readable = QALatexReadableText.render(latex)
                    var fallbackAttributes = attributes
                    fallbackAttributes[.font] = UIFont.monospacedSystemFont(
                        ofSize: font.pointSize,
                        weight: .regular
                    )
                    if !failedFormulaIDs.contains(run.id), run.link == nil {
                        fallbackAttributes[.foregroundColor] = UIColor.secondaryLabel
                    }
                    value.append(NSAttributedString(
                        string: readable.isEmpty ? latex : readable,
                        attributes: fallbackAttributes
                    ))
                }
            } else {
                value.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return value
    }

    private static func attributes(
        for run: QAInlineRun,
        baseFont: UIFont,
        foregroundColor: UIColor,
        paragraphStyle: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: styledFont(base: baseFont, style: run.style),
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraphStyle,
        ]
        if run.style.contains(.strikethrough) {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if run.style.contains(.code) {
            result[.backgroundColor] = UIColor.secondarySystemBackground
        }
        if let link = run.link, let url = QABodyLinkResolver.url(link) {
            result[.link] = url
            result[.foregroundColor] = UIColor(Color.accentColor)
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return result
    }

    private static func styledFont(base: UIFont, style: QAInlineStyle) -> UIFont {
        let font: UIFont
        if style.contains(.code) {
            font = .monospacedSystemFont(
                ofSize: base.pointSize,
                weight: style.contains(.strong) ? .bold : .regular
            )
        } else {
            font = base
        }

        var traits = font.fontDescriptor.symbolicTraits
        if style.contains(.strong) { traits.insert(.traitBold) }
        if style.contains(.emphasis) { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private struct QABodyRemoteImage: View {
    let image: QAImageDTO

    var body: some View {
        Group {
            if let dimensions = image.dimensions {
                content
                    .aspectRatio(CGFloat(dimensions.aspectRatio), contentMode: .fit)
            } else {
                content
                    .frame(minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if NativeRemoteMediaPolicy.isAnimatedImage(image.url) {
            NativeAnimatedRemoteImage(url: image.url)
        } else {
            AsyncImage(url: image.url) { phase in
                switch phase {
                case let .success(value):
                    value.resizable().scaledToFit()
                case .failure:
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("图片加载失败").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                @unknown default:
                    EmptyView()
                }
            }
        }
    }
}

enum QARichTextFormatter {
    static func attributed(_ runs: [QAInlineRun]) -> AttributedString {
        runs.reduce(into: AttributedString()) { value, run in
            var part = AttributedString(run.text)
            var presentation: InlinePresentationIntent = []
            if run.style.contains(.strong) { presentation.insert(.stronglyEmphasized) }
            if run.style.contains(.emphasis) { presentation.insert(.emphasized) }
            if !presentation.isEmpty { part.inlinePresentationIntent = presentation }
            if run.style.contains(.strikethrough) { part.strikethroughStyle = .single }
            if run.style.contains(.code) {
                part.font = .body.monospaced()
                part.backgroundColor = Color(uiColor: .secondarySystemBackground)
            }
            if let link = run.link {
                part.link = QABodyLinkResolver.url(link)
                part.foregroundColor = .accentColor
                part.underlineStyle = .single
            }
            value.append(part)
        }
    }
}

private struct QANativeVideoPlayer: View {
    let video: QAAttachmentVideoDTO
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if let thumbnailURL = video.thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().tint(.white)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            guard player == nil, let playbackURL = video.playbackURL else { return }
            player = AVPlayer(url: playbackURL)
        }
        .onDisappear { player?.pause() }
        .accessibilityLabel("视频播放器")
    }
}

private struct QAVideoAttachmentView: View {
    let video: QAAttachmentVideoDTO
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                AsyncImage(url: video.thumbnailURL) { phase in
                    switch phase {
                    case let .success(image): image.resizable().scaledToFill()
                    case .failure:
                        Color(uiColor: .secondarySystemBackground)
                            .overlay(Image(systemName: "video.slash").foregroundStyle(.secondary))
                    case .empty:
                        Color(uiColor: .secondarySystemBackground)
                            .overlay(ProgressView())
                    @unknown default:
                        Color(uiColor: .secondarySystemBackground)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white, .black.opacity(0.34))
                    .shadow(radius: 8)
                VStack {
                    Spacer()
                    HStack {
                        Label("视频", systemImage: "play.rectangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(10)
                    .background(.black.opacity(0.38))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放视频")
    }
}

struct NativeVideoPlayerScreen: View {
    let route: NativeVideoRouteDTO
    let repository: NativeVideoRepository
    let openExternal: (URL) -> Void

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let thumbnailURL = route.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFit()
                        case .failure:
                            Color.black
                        case .empty:
                            ProgressView().tint(.white)
                        @unknown default:
                            Color.black
                        }
                    }
                }
                if isLoading {
                    ProgressView("正在载入视频")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.title2)
                    Text("视频加载失败")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                    if let webURL = route.webURL {
                        Button("在浏览器中打开") { openExternal(webURL) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route) { await load() }
        .onDisappear { player?.pause() }
    }

    @MainActor
    private func load() async {
        player?.pause()
        player = nil
        errorMessage = nil
        isLoading = true
        do {
            let playbackURL = try await repository.resolvePlaybackURL(for: route)
            guard !Task.isCancelled else { return }
            let player = AVPlayer(url: playbackURL)
            self.player = player
            isLoading = false
            player.play()
        } catch {
            guard !error.isNativeRequestCancellation else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

enum QABodyLinkResolver {
    static func url(_ destination: QALinkDestination) -> URL? {
        switch destination {
        case let .answer(id): return URL(string: "zhihu://answers/\(id)")
        case let .article(id): return URL(string: "zhihu://articles/\(id)")
        case let .question(id): return URL(string: "zhihu://questions/\(id)")
        case let .pin(id): return URL(string: "zhihu://pin/\(id)")
        case let .person(token): return URL(string: "zhihu://people/\(token)")
        case let .external(url): return url
        }
    }

    static func resolve(_ url: URL) -> QALinkDestination? {
        if let destination = NativeContentDestinationResolver.resolve(url.absoluteString) {
            switch destination {
            case let .article(id, kind):
                return kind == .answer ? .answer(id) : .article(id)
            case let .question(id):
                return .question(id)
            case let .person(_, token, _):
                return .person(urlToken: token)
            case let .pin(id):
                return .pin(id)
            case .special, .column:
                return .external(url)
            case .search:
                break
            case let .external(externalURL):
                return .external(externalURL)
            }
        }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        return .external(url)
    }
}
