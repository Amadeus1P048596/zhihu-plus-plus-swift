import Foundation

enum QAContentKind: String, Hashable, Sendable {
    case answer
    case article
}

struct QuestionRouteDTO: Hashable, Sendable {
    let questionID: Int64
    let provisionalTitle: String

    init(questionID: Int64, provisionalTitle: String = "") {
        self.questionID = questionID
        self.provisionalTitle = provisionalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AnswerRouteDTO: Hashable, Sendable {
    let contentID: Int64
    let kind: QAContentKind
    let questionID: Int64?
    let provisionalTitle: String
    let source: AnswerPageSourceDTO?

    init(
        contentID: Int64,
        kind: QAContentKind,
        questionID: Int64? = nil,
        provisionalTitle: String = "",
        source: AnswerPageSourceDTO? = nil
    ) {
        self.contentID = contentID
        self.kind = kind
        self.questionID = questionID
        self.provisionalTitle = provisionalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
    }
}

struct AnswerPageSourceDTO: Hashable, Sendable {
    let sourceName: String
    let questionID: Int64
    let order: QuestionAnswerSort
    let orderedAnswers: [AnswerPreviewDTO]
    let selectedAnswerID: Int64
    let nextURL: URL?

    init(
        sourceName: String = "此问题",
        questionID: Int64,
        order: QuestionAnswerSort,
        orderedAnswers: [AnswerPreviewDTO],
        selectedAnswerID: Int64,
        nextURL: URL?
    ) {
        self.sourceName = sourceName
        self.questionID = questionID
        self.order = order
        self.orderedAnswers = orderedAnswers
        self.selectedAnswerID = selectedAnswerID
        self.nextURL = nextURL
    }
}

enum QuestionAnswerSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    case `default`
    case updated

    var id: Self { self }
    var title: String { self == .default ? "默认" : "最新" }
}

struct QAAuthorDTO: Hashable, Sendable {
    let memberID: String
    let urlToken: String
    let displayName: String
    let headline: String
    let avatarURL: URL?

    var personIntent: QANavigationIntent? {
        guard !memberID.isEmpty || !urlToken.isEmpty else { return nil }
        guard let payload = PersonRoutePayload(
            memberID: memberID,
            urlToken: urlToken,
            displayName: displayName,
            initialTab: .answers
        ) else { return nil }
        return .person(payload)
    }
}

struct QuestionDTO: Hashable, Sendable {
    let id: Int64
    let title: String
    let detailHTML: String
    let detailBlocks: [QABodyBlock]
    let answerCount: Int
    let visitCount: Int
    let commentCount: Int
    let followerCount: Int
    let isFollowing: Bool
    let author: QAAuthorDTO?
    let topics: [QATopicDTO]

    func replacingFollow(isFollowing: Bool, followerCount: Int) -> Self {
        Self(
            id: id,
            title: title,
            detailHTML: detailHTML,
            detailBlocks: detailBlocks,
            answerCount: answerCount,
            visitCount: visitCount,
            commentCount: commentCount,
            followerCount: max(0, followerCount),
            isFollowing: isFollowing,
            author: author,
            topics: topics
        )
    }
}

struct QATopicDTO: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL?
}

struct AnswerPreviewDTO: Identifiable, Hashable, Sendable {
    let answerID: Int64
    let questionID: Int64
    let questionTitle: String
    let author: QAAuthorDTO
    let excerpt: String
    let voteUpCount: Int
    let commentCount: Int

    var id: Int64 { answerID }
}

struct QuestionAnswerPageDTO: Sendable {
    let items: [AnswerPreviewDTO]
    let nextURL: URL?
    let isEnd: Bool
}

enum QAVoteState: String, Hashable, Sendable {
    case neutral
    case up
    case down
}

enum QAFavoriteState: Hashable, Sendable {
    case unknown
    case notFavorited
    case favorited
}

enum QAMetadataEdge: Hashable, Sendable {
    case leading
    case trailing
}

struct QAMetadataPlacement: Hashable, Sendable {
    let dateEdge: QAMetadataEdge
    let ipEdge: QAMetadataEdge = .trailing

    init(pinAnswerDate: Bool) {
        dateEdge = pinAnswerDate ? .leading : .trailing
    }
}

struct QACollectionDTO: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let isFavorited: Bool
}

struct QAEndorsementDTO: Identifiable, Hashable, Sendable {
    let text: String
    let actionURL: URL?
    let leadingIconKey: String?

    var id: String { "\(text)|\(actionURL?.absoluteString ?? "")|\(leadingIconKey ?? "")" }
}

struct QAAttachmentVideoDTO: Hashable, Sendable {
    let videoID: Int64
    let thumbnailURL: URL?
    let destinationURL: URL?
    let playbackURL: URL?

    init(
        videoID: Int64,
        thumbnailURL: URL?,
        destinationURL: URL?,
        playbackURL: URL? = nil
    ) {
        self.videoID = videoID
        self.thumbnailURL = thumbnailURL
        self.destinationURL = destinationURL
        self.playbackURL = playbackURL
    }
}

struct AnswerDTO: Hashable, Sendable {
    let route: AnswerRouteDTO
    let title: String
    let questionID: Int64?
    let author: QAAuthorDTO
    let blocks: [QABodyBlock]
    let attachment: QAAttachmentVideoDTO?
    let sourceURL: URL
    let voteUpCount: Int
    let favoriteCount: Int
    let commentCount: Int
    let voteState: QAVoteState
    let favoriteState: QAFavoriteState
    let createdTimeSeconds: Int64
    let updatedTimeSeconds: Int64
    let ipLocation: String?
    let invitationPreface: String?
    let endorsements: [QAEndorsementDTO]

    func replacingVote(_ state: QAVoteState, count: Int) -> Self {
        Self(
            route: route, title: title, questionID: questionID, author: author, blocks: blocks,
            attachment: attachment, sourceURL: sourceURL, voteUpCount: max(0, count),
            favoriteCount: favoriteCount, commentCount: commentCount, voteState: state,
            favoriteState: favoriteState, createdTimeSeconds: createdTimeSeconds,
            updatedTimeSeconds: updatedTimeSeconds, ipLocation: ipLocation,
            invitationPreface: invitationPreface, endorsements: endorsements
        )
    }

    func replacingFavorite(_ state: QAFavoriteState, count: Int) -> Self {
        Self(
            route: route, title: title, questionID: questionID, author: author, blocks: blocks,
            attachment: attachment, sourceURL: sourceURL, voteUpCount: voteUpCount,
            favoriteCount: max(0, count), commentCount: commentCount, voteState: voteState,
            favoriteState: state, createdTimeSeconds: createdTimeSeconds,
            updatedTimeSeconds: updatedTimeSeconds, ipLocation: ipLocation,
            invitationPreface: invitationPreface, endorsements: endorsements
        )
    }
}

struct QAMarkdownDocument: Hashable, Sendable {
    let title: String
    let authorName: String
    let sourceURL: URL
    let markdown: String
    let suggestedFileName: String
}

enum QAMarkdownSharePayload: Equatable, Sendable {
    case text(String)
    case file(contents: String, suggestedFileName: String)
}

enum QAMarkdownSharePayloadBuilder {
    static let inlineTextByteLimit = 120_000

    static func payload(
        for document: QAMarkdownDocument,
        inlineTextByteLimit: Int = inlineTextByteLimit
    ) -> QAMarkdownSharePayload {
        if document.markdown.utf8.count <= max(0, inlineTextByteLimit) {
            return .text(document.markdown)
        }
        return .file(
            contents: document.markdown,
            suggestedFileName: document.suggestedFileName
        )
    }
}

enum QAMarkdownConverter {
    static func document(from answer: AnswerDTO) -> QAMarkdownDocument {
        let authorName = answer.author.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .qaNilIfEmpty ?? "匿名用户"
        var visibleBlocks = answer.blocks
        if let attachment = answer.attachment {
            visibleBlocks.append(.video(UUID(), attachment))
        }
        let body = blocks(visibleBlocks)
        let title = answer.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = [
            "# \(escapeText(title.qaNilIfEmpty ?? "知乎正文"))",
            "作者：\(escapeText(authorName))",
            "原文：[\(answer.sourceURL.absoluteString)](\(answer.sourceURL.absoluteString))",
        ].joined(separator: "\n\n")
        return QAMarkdownDocument(
            title: title.qaNilIfEmpty ?? "知乎正文",
            authorName: authorName,
            sourceURL: answer.sourceURL,
            markdown: [header, body].filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n",
            suggestedFileName: suggestedFileName(title: title.qaNilIfEmpty ?? "知乎正文")
        )
    }

    static func blocks(_ blocks: [QABodyBlock]) -> String {
        blocks.compactMap(block).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func block(_ block: QABodyBlock) -> String? {
        switch block {
        case let .paragraph(_, runs):
            return inline(runs)
        case let .heading(_, level, runs):
            return "\(String(repeating: "#", count: min(max(level, 1), 6))) \(inline(runs))"
        case let .quote(_, runs):
            return inline(runs)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
        case let .list(_, kind, items):
            return list(QAListGroup(kind: kind, items: items), depth: 0)
        case let .code(_, language, text):
            let fence = codeFence(for: text)
            let language = sanitizedCodeLanguage(language)
            return "\(fence)\(language)\n\(text)\n\(fence)"
        case let .formula(_, latex):
            return "$$\n\(latex)\n$$"
        case let .image(image):
            let alt = escapeImageAlt(image.altText ?? image.caption ?? "图片")
            let imageMarkdown = "![\(alt)](\(image.url.absoluteString))"
            guard let caption = image.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !caption.isEmpty,
                  caption != image.altText
            else { return imageMarkdown }
            return "\(imageMarkdown)\n\n_\(escapeText(caption))_"
        case let .segment(_, _, runs):
            return inline(runs)
        case let .video(_, video):
            let target = video.destinationURL ?? video.playbackURL
            let cover = video.thumbnailURL.map {
                "![视频封面](\($0.absoluteString))"
            }
            let link = target.map {
                "[视频](\($0.absoluteString))"
            }
            return [cover, link].compactMap { $0 }.joined(separator: "\n\n").qaNilIfEmpty
        case .divider:
            return "---"
        }
    }

    private static func list(_ group: QAListGroup, depth: Int) -> String {
        group.items.enumerated().flatMap { index, item -> [String] in
            let number = item.ordinal ?? group.startIndex + index
            let marker = group.kind == .ordered ? "\(number)." : "-"
            let indentation = String(repeating: "    ", count: depth)
            let continuation = indentation + "    "
            let contentLines = inline(item.runs)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            var lines = [
                "\(indentation)\(marker) \(contentLines.first ?? "")"
            ]
            lines.append(contentsOf: contentLines.dropFirst().map { continuation + $0 })
            for nestedList in item.nestedLists {
                let nested = list(nestedList, depth: depth + 1)
                if !nested.isEmpty { lines.append(nested) }
            }
            return lines
        }.joined(separator: "\n")
    }

    private static func inline(_ runs: [QAInlineRun]) -> String {
        runs.map(inline).joined()
    }

    private static func inline(_ run: QAInlineRun) -> String {
        if let latex = run.formulaLatex {
            return "$\(latex)$"
        }
        let characters = Array(run.text)
        guard let firstContent = characters.firstIndex(where: { !$0.isWhitespace }),
              let lastContent = characters.lastIndex(where: { !$0.isWhitespace })
        else { return run.text }
        let leading = String(characters[..<firstContent])
        let trailing = String(characters[(lastContent + 1)...])
        let content = String(characters[firstContent...lastContent])
        var value: String
        if run.style.contains(.code) {
            value = inlineCode(content)
        } else {
            value = escapeText(content)
        }
        if run.style.contains(.strong) { value = "**\(value)**" }
        if run.style.contains(.emphasis) { value = "*\(value)*" }
        if run.style.contains(.strikethrough) { value = "~~\(value)~~" }
        if let link = run.link, let url = markdownURL(link) {
            value = "[\(value)](\(url.absoluteString))"
        }
        return leading + value + trailing
    }

    private static func markdownURL(_ destination: QALinkDestination) -> URL? {
        switch destination {
        case let .answer(id):
            return URL(string: "https://www.zhihu.com/answer/\(id)")
        case let .article(id):
            return URL(string: "https://zhuanlan.zhihu.com/p/\(id)")
        case let .question(id):
            return URL(string: "https://www.zhihu.com/question/\(id)")
        case let .pin(id):
            return URL(string: "https://www.zhihu.com/pin/\(id)")
        case let .person(token):
            return URL(string: "https://www.zhihu.com/people/\(token)")
        case let .external(url):
            return url
        }
    }

    private static func inlineCode(_ source: String) -> String {
        let fence = String(repeating: "`", count: max(1, longestBacktickRun(in: source) + 1))
        let padding = source.hasPrefix("`") || source.hasSuffix("`") ? " " : ""
        return "\(fence)\(padding)\(source)\(padding)\(fence)"
    }

    private static func codeFence(for source: String) -> String {
        String(repeating: "`", count: max(3, longestBacktickRun(in: source) + 1))
    }

    private static func longestBacktickRun(in source: String) -> Int {
        var longestRun = 0
        var currentRun = 0
        for character in source {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return longestRun
    }

    private static func sanitizedCodeLanguage(_ language: String?) -> String {
        guard let language else { return "" }
        return String(language.prefix { $0.isLetter || $0.isNumber || "_+-".contains($0) })
    }

    private static func escapeText(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_{}[]<>#+-.!|~".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    private static func escapeImageAlt(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func suggestedFileName(title: String) -> String {
        let safeCharacters = title.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(safeCharacters)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let base = String((collapsed.qaNilIfEmpty ?? "zhihu-content").prefix(64))
        return "\(base).md"
    }
}

private extension String {
    var qaNilIfEmpty: String? { isEmpty ? nil : self }
}

struct QAInlineStyle: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let strong = Self(rawValue: 1 << 0)
    static let emphasis = Self(rawValue: 1 << 1)
    static let strikethrough = Self(rawValue: 1 << 2)
    static let code = Self(rawValue: 1 << 3)
}

struct QAInlineRun: Identifiable, Hashable, Sendable {
    enum Content: Hashable, Sendable {
        case text(String)
        case formula(latex: String)
    }

    let id: UUID
    let content: Content
    let style: QAInlineStyle
    let link: QALinkDestination?

    var text: String {
        switch content {
        case let .text(value), let .formula(value): return value
        }
    }

    var formulaLatex: String? {
        guard case let .formula(latex) = content else { return nil }
        return latex
    }

    init(id: UUID = UUID(), text: String, style: QAInlineStyle = [], link: QALinkDestination? = nil) {
        self.id = id
        content = .text(text)
        self.style = style
        self.link = link
    }

    init(id: UUID = UUID(), formulaLatex: String, style: QAInlineStyle = [], link: QALinkDestination? = nil) {
        self.id = id
        content = .formula(latex: formulaLatex)
        self.style = style
        self.link = link
    }
}

enum QALinkDestination: Hashable, Sendable {
    case answer(Int64)
    case article(Int64)
    case question(Int64)
    case pin(Int64)
    case person(urlToken: String)
    case external(URL)
}

enum QAListKind: Hashable, Sendable {
    case ordered
    case unordered
}

struct QAListItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let runs: [QAInlineRun]
    let ordinal: Int?
    let nestedLists: [QAListGroup]

    init(
        id: UUID = UUID(),
        runs: [QAInlineRun],
        ordinal: Int? = nil,
        nestedLists: [QAListGroup] = []
    ) {
        self.id = id
        self.runs = runs
        self.ordinal = ordinal
        self.nestedLists = nestedLists
    }
}

struct QAListGroup: Hashable, Sendable {
    let kind: QAListKind
    let startIndex: Int
    let items: [QAListItem]

    init(kind: QAListKind, startIndex: Int = 1, items: [QAListItem]) {
        self.kind = kind
        self.startIndex = max(1, startIndex)
        self.items = items
    }
}

struct QAImageDimensions: Hashable, Sendable {
    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard (1...100_000).contains(width),
              (1...100_000).contains(height)
        else { return nil }
        let ratio = Double(width) / Double(height)
        guard (0.02...50).contains(ratio) else { return nil }
        self.width = width
        self.height = height
    }

    var aspectRatio: Double { Double(width) / Double(height) }
}

struct QAImageDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let caption: String?
    let altText: String?
    let dimensions: QAImageDimensions?

    init(
        id: UUID = UUID(),
        url: URL,
        caption: String? = nil,
        altText: String? = nil,
        dimensions: QAImageDimensions? = nil
    ) {
        self.id = id
        self.url = url
        self.caption = caption
        self.altText = altText
        self.dimensions = dimensions
    }
}

enum QABodyBlock: Identifiable, Hashable, Sendable {
    case paragraph(UUID, [QAInlineRun])
    case heading(UUID, level: Int, runs: [QAInlineRun])
    case quote(UUID, [QAInlineRun])
    case list(UUID, kind: QAListKind, items: [QAListItem])
    case code(UUID, language: String?, text: String)
    case formula(UUID, latex: String)
    case image(QAImageDTO)
    case segment(UUID, segmentID: String, runs: [QAInlineRun])
    case video(UUID, QAAttachmentVideoDTO)
    case divider(UUID)

    var id: UUID {
        switch self {
        case let .paragraph(id, _), let .heading(id, _, _), let .quote(id, _), let .list(id, _, _),
             let .code(id, _, _), let .formula(id, _), let .segment(id, _, _), let .video(id, _),
             let .divider(id): return id
        case let .image(image): return image.id
        }
    }
}

enum QANavigationIntent: Hashable {
    case person(PersonRoutePayload)
    case question(QuestionRouteDTO)
    case answer(AnswerRouteDTO)
    case writeAnswer(WriteAnswerRouteDTO)
    case comments(CommentThreadRouteDTO)
    case images(urls: [URL], initialIndex: Int)
    case link(QALinkDestination)
    case endorsement(URL)
    case segmentComments(CommentThreadRouteDTO)
    case video(NativeVideoRouteDTO)
    case share(URL)
}

enum QAInitialLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum QANextPageState: Equatable {
    case idle
    case loading
    case failed(String)
}

struct QAUserMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
