import CoreGraphics
import Foundation

struct CommentSessionID: Hashable, Codable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum CommentSubjectDTO: Hashable {
    case answer(Int64)
    case article(Int64)
    case question(Int64)
    case pin(Int64)
    case segment(contentID: String, contentTypeRaw: String, segmentID: String)
}

enum CommentLevelKey: Hashable {
    case root
    case replies(rootCommentID: String)
}

struct CommentShareContextDTO: Hashable {
    let title: String
    let excerpt: String?
    let sourceURL: URL
}

struct CommentThreadRouteDTO: Hashable {
    let subject: CommentSubjectDTO
    let initialLevel: CommentLevelKey
    let shareContext: CommentShareContextDTO?

    init(
        subject: CommentSubjectDTO,
        initialLevel: CommentLevelKey = .root,
        shareContext: CommentShareContextDTO? = nil
    ) {
        self.subject = subject
        self.initialLevel = initialLevel
        self.shareContext = shareContext
    }
}

enum CommentSortDTO: String, CaseIterable, Hashable, Identifiable {
    case score
    case time

    var id: Self { self }

    var title: String {
        switch self {
        case .score: return "最热"
        case .time: return "最新"
        }
    }

    var queryValue: String {
        switch self {
        case .score: return "score"
        case .time: return "ts"
        }
    }
}

struct CommentPageAcceptanceKey: Hashable {
    let sessionID: CommentSessionID
    let level: CommentLevelKey
    let generation: UInt64
}

struct CommentAuthorDTO: Hashable {
    let memberID: String
    let urlToken: String
    let displayName: String
    let avatarURL: URL?

    var personRoute: PersonRoutePayload? {
        PersonRoutePayload(
            memberID: memberID,
            urlToken: urlToken,
            displayName: displayName,
            initialTab: .answers
        )
    }
}

enum CommentMediaKind: String, Hashable {
    case image
    case animatedImage
    case sticker
}

struct CommentMediaDTO: Hashable, Identifiable {
    let kind: CommentMediaKind
    let url: URL

    var id: String { "\(kind.rawValue):\(url.absoluteString)" }
}

struct CommentDTO: Hashable, Identifiable {
    let id: String
    let contentHTML: String
    let createdTimeSeconds: Int64
    let author: CommentAuthorDTO
    let replyToAuthor: CommentAuthorDTO?
    let isLiked: Bool
    let likeCount: Int
    let childCommentCount: Int
    let embeddedReplies: [CommentDTO]
    let media: [CommentMediaDTO]

    func replacingLikeState(isLiked: Bool, likeCount: Int) -> Self {
        Self(
            id: id,
            contentHTML: contentHTML,
            createdTimeSeconds: createdTimeSeconds,
            author: author,
            replyToAuthor: replyToAuthor,
            isLiked: isLiked,
            likeCount: max(0, likeCount),
            childCommentCount: childCommentCount,
            embeddedReplies: embeddedReplies,
            media: media
        )
    }

    func appendingEmbeddedReply(_ reply: CommentDTO, incrementingCount: Bool) -> Self {
        var replies = embeddedReplies.filter { $0.id != reply.id }
        replies.append(reply)
        return Self(
            id: id,
            contentHTML: contentHTML,
            createdTimeSeconds: createdTimeSeconds,
            author: author,
            replyToAuthor: replyToAuthor,
            isLiked: isLiked,
            likeCount: likeCount,
            childCommentCount: max(replies.count, childCommentCount + (incrementingCount ? 1 : 0)),
            embeddedReplies: replies,
            media: media
        )
    }
}

enum CommentInitialLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum CommentNextPageState: Equatable {
    case idle
    case loading
    case failed(String)
}

struct CommentLikeMutationDTO: Equatable {
    let operationID: UInt64
    let acceptanceKey: CommentPageAcceptanceKey
    let commentID: String
    let targetIsLiked: Bool
}

struct CommentPageState {
    var acceptanceKey: CommentPageAcceptanceKey
    var initialLoad: CommentInitialLoadState = .idle
    var nextPage: CommentNextPageState = .idle
    var isEnd = false
    var items: [CommentDTO] = []
    var nextURL: URL?
    var activeLikeMutation: CommentLikeMutationDTO?

    init(acceptanceKey: CommentPageAcceptanceKey) {
        self.acceptanceKey = acceptanceKey
    }
}

enum CommentSubmissionState: Equatable {
    case idle
    case submitting(operationID: UInt64)
    case failed(operationID: UInt64, message: String)
}

struct CommentComposerDraft: Equatable {
    var text = ""
    var imageData: Data?
    var replyTargetCommentID: String?
    var submissionState: CommentSubmissionState = .idle
}

struct CommentSubmissionSnapshotDTO: Equatable {
    let operationID: UInt64
    let acceptanceKey: CommentPageAcceptanceKey
    let subject: CommentSubjectDTO
    let level: CommentLevelKey
    let text: String
    let imageData: Data?
    let replyToCommentID: String?
}

struct CommentEmoji: Identifiable, Hashable {
    let placeholder: String
    let symbol: String

    var id: String { placeholder }
}

enum CommentEmojiCatalog {
    static let entries: [CommentEmoji] = [
        .init(placeholder: "[微笑]", symbol: "😊"),
        .init(placeholder: "[大笑]", symbol: "😄"),
        .init(placeholder: "[笑哭]", symbol: "😂"),
        .init(placeholder: "[飙泪笑]", symbol: "🤣"),
        .init(placeholder: "[害羞]", symbol: "☺️"),
        .init(placeholder: "[捂脸]", symbol: "🤦"),
        .init(placeholder: "[捂嘴]", symbol: "🤭"),
        .init(placeholder: "[思考]", symbol: "🤔"),
        .init(placeholder: "[好奇]", symbol: "🧐"),
        .init(placeholder: "[酷]", symbol: "😎"),
        .init(placeholder: "[白眼]", symbol: "🙄"),
        .init(placeholder: "[惊讶]", symbol: "😮"),
        .init(placeholder: "[流泪]", symbol: "😢"),
        .init(placeholder: "[大哭]", symbol: "😭"),
        .init(placeholder: "[生气]", symbol: "😠"),
        .init(placeholder: "[发火]", symbol: "🤬"),
        .init(placeholder: "[调皮]", symbol: "😜"),
        .init(placeholder: "[尴尬]", symbol: "😅"),
        .init(placeholder: "[可怜]", symbol: "🥺"),
        .init(placeholder: "[口罩]", symbol: "😷"),
        .init(placeholder: "[爱]", symbol: "😍"),
        .init(placeholder: "[红心]", symbol: "❤️"),
        .init(placeholder: "[赞]", symbol: "👍"),
        .init(placeholder: "[赞同]", symbol: "👍"),
        .init(placeholder: "[握手]", symbol: "🤝"),
        .init(placeholder: "[感谢]", symbol: "🙏"),
        .init(placeholder: "[拜托]", symbol: "🙏"),
        .init(placeholder: "[耶]", symbol: "✌️"),
        .init(placeholder: "[吃瓜]", symbol: "🍉"),
        .init(placeholder: "[柠檬]", symbol: "🍋"),
        .init(placeholder: "[蹲]", symbol: "🧎"),
        .init(placeholder: "[潜水]", symbol: "🤿"),
        .init(placeholder: "[嘘]", symbol: "🤫"),
        .init(placeholder: "[发呆]", symbol: "😶"),
        .init(placeholder: "[魔性笑]", symbol: "😆"),
        .init(placeholder: "[开心]", symbol: "🥳"),
    ]

    static func renderedText(_ source: String) -> String {
        entries.reduce(source) { text, entry in
            text.replacingOccurrences(of: entry.placeholder, with: entry.symbol)
        }
    }
}

struct CommentScrollAnchor: Hashable {
    let commentID: String
    let offsetFromViewportTopPoints: CGFloat
}

struct CommentRestorationContext {
    let sessionID: CommentSessionID
    let level: CommentLevelKey
    let rootSort: CommentSortDTO
    let rootAnchor: CommentScrollAnchor?
    let replyAnchors: [String: CommentScrollAnchor]
    let activeDraft: CommentComposerDraft
}

enum CommentAnchorRestorationResult: Equatable {
    case restored(CommentScrollAnchor)
    case noAnchor
    case missingAnchor(CommentScrollAnchor)
}

struct CommentUserMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

struct CommentMediaGalleryDestination: Identifiable, Equatable {
    let id = UUID()
    let sourceLevel: CommentLevelKey
    let urls: [URL]
    let initialIndex: Int

    init?(
        media: [CommentMediaDTO],
        selectedID: CommentMediaDTO.ID,
        sourceLevel: CommentLevelKey
    ) {
        let urls = media.map(\.url)
        guard !urls.isEmpty,
              let initialIndex = media.firstIndex(where: { $0.id == selectedID })
        else { return nil }
        self.sourceLevel = sourceLevel
        self.urls = urls
        self.initialIndex = initialIndex
    }
}
