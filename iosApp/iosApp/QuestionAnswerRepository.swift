import Foundation

struct QAVoteMutationResult: Equatable, Sendable {
    let state: QAVoteState
    let voteUpCount: Int
}

struct QACollectionsResult: Sendable {
    let items: [QACollectionDTO]
    let favoriteState: QAFavoriteState
}

protocol QuestionAnswerRepository: Sendable {
    func fetchQuestion(_ route: QuestionRouteDTO) async throws -> QuestionDTO
    func fetchQuestionAnswers(
        questionID: Int64,
        sort: QuestionAnswerSort,
        after nextURL: URL?
    ) async throws -> QuestionAnswerPageDTO
    func setQuestionFollowing(_ following: Bool, questionID: Int64) async throws
    func fetchAnswer(_ route: AnswerRouteDTO) async throws -> AnswerDTO
    func setVote(_ state: QAVoteState, route: AnswerRouteDTO) async throws -> QAVoteMutationResult
    func fetchCollections(route: AnswerRouteDTO) async throws -> QACollectionsResult
    func setCollection(
        _ selected: Bool,
        collectionID: String,
        route: AnswerRouteDTO
    ) async throws
    func recordReadHistory(contentToken: String, contentType: String) async
}

extension QuestionAnswerRepository {
    func recordReadHistory(contentToken: String, contentType: String) async {}
}

protocol NativeVideoRepository: Sendable {
    func resolvePlaybackURL(for route: NativeVideoRouteDTO) async throws -> URL
}

enum NativeVideoRepositoryError: LocalizedError, Equatable {
    case invalidRequest
    case playbackUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "视频信息无效"
        case .playbackUnavailable:
            return "暂时无法获取视频播放地址"
        }
    }
}

actor URLSessionNativeVideoRepository: NativeVideoRepository {
    private let client: ZhihuAPIClient
    private let decoder: JSONDecoder

    init(client: ZhihuAPIClient) {
        self.client = client
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func resolvePlaybackURL(for route: NativeVideoRouteDTO) async throws -> URL {
        if let playbackURL = route.playbackURL,
           let trustedURL = trustedPlaybackURL(playbackURL.absoluteString) {
            return trustedURL
        }
        guard route.contentID > 0, route.videoID > 0,
              var components = URLComponents(string: "https://www.zhihu.com/api/v4/video/play_info")
        else { throw NativeVideoRepositoryError.invalidRequest }
        components.queryItems = [URLQueryItem(name: "r", value: String(route.videoID))]
        guard let url = components.url else { throw NativeVideoRepositoryError.invalidRequest }

        let request = NativeVideoPlayRequest(
            contentID: String(route.contentID),
            contentTypeString: route.contentType.rawValue,
            videoID: String(route.videoID),
            sceneCode: route.contentType.sceneCode,
            isOnlyVideo: true
        )
        guard let body = try? JSONEncoder().encode(request) else {
            throw NativeVideoRepositoryError.invalidRequest
        }
        let data = try await client.data(
            for: url,
            method: "POST",
            body: body,
            additionalHeaders: [
                "Content-Type": "application/json",
                "x-app-za": "OS=webplayer",
                "x-referer": "",
            ],
            authentication: .accountIfAvailable
        )
        guard let response = try? decoder.decode(NativeVideoPlayResponse.self, from: data),
              let playbackURL = response.highestQualityURL
        else { throw NativeVideoRepositoryError.playbackUnavailable }
        return playbackURL
    }
}

private struct NativeVideoPlayRequest: Encodable {
    let contentID: String
    let contentTypeString: String
    let videoID: String
    let sceneCode: String
    let isOnlyVideo: Bool

    enum CodingKeys: String, CodingKey {
        case contentID = "content_id"
        case contentTypeString = "content_type_str"
        case videoID = "video_id"
        case sceneCode = "scene_code"
        case isOnlyVideo = "is_only_video"
    }
}

private struct NativeVideoPlayResponse: Decodable {
    let videoPlay: VideoPlay?

    struct VideoPlay: Decodable {
        let playlist: Playlist?
    }

    struct Playlist: Decodable {
        let mp4: [Playback]?
    }

    struct Playback: Decodable {
        let bitrate: Double?
        let url: [String]?
    }

    var highestQualityURL: URL? {
        videoPlay?.playlist?.mp4?
            .compactMap { playback -> (Double, URL)? in
                guard let url = playback.url?.compactMap(trustedPlaybackURL).first else { return nil }
                return (playback.bitrate ?? 0, url)
            }
            .max { $0.0 < $1.0 }?
            .1
    }
}

actor URLSessionQuestionAnswerRepository: QuestionAnswerRepository {
    private static let questionInclude =
        "read_count,visit_count,answer_count,voteup_count,comment_count,follower_count,detail,excerpt,author,relationship.is_following,topics"
    private static let questionFeedInclude =
        "data[*].content,excerpt,headline,target.author.badge_v2"
    private static let answerInclude =
        ".settings,content,editable_content,paid_info,can_comment,excerpt,thanks_count,favlists_count,voteup_count,comment_count,visited_count,attachment,reaction,relationship,ip_info,pagination_info,endorsements,question.topics,reaction.relation.voting,author.badge_v2,settings.table_of_contents.enabled"
    private static let articleInclude =
        "content,topics,paid_info,can_comment,excerpt,favlists_count,voteup_count,comment_count,visited_count,relationship,ip_info,relationship.vote,author.badge_v2"

    private let client: ZhihuAPIClient
    private let decoder: JSONDecoder

    init(client: ZhihuAPIClient) {
        self.client = client
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func fetchQuestion(_ route: QuestionRouteDTO) async throws -> QuestionDTO {
        let url = try endpoint(
            path: "/api/v4/questions/\(route.questionID)",
            query: [URLQueryItem(name: "include", value: Self.questionInclude)]
        )
        let data = try await client.data(for: url, authentication: .accountRequired)
        do {
            let question = try decoder.decode(QuestionResponse.self, from: data).dto()
            guard question.id == route.questionID else {
                throw QuestionAnswerRepositoryError.malformedQuestion
            }
            return question
        } catch {
            throw QuestionAnswerRepositoryError.malformedQuestion
        }
    }

    func fetchQuestionAnswers(
        questionID: Int64,
        sort: QuestionAnswerSort,
        after nextURL: URL?
    ) async throws -> QuestionAnswerPageDTO {
        let url: URL
        if let nextURL {
            let validated = try continuation(
                nextURL,
                requiredPrefix: "/api/v4/questions/\(questionID)/feeds"
            )
            guard var components = URLComponents(url: validated, resolvingAgainstBaseURL: false) else {
                throw QuestionAnswerRepositoryError.invalidURL
            }
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "include" }
            queryItems.append(URLQueryItem(name: "include", value: Self.questionFeedInclude))
            components.queryItems = queryItems
            guard let continuationURL = components.url else {
                throw QuestionAnswerRepositoryError.invalidURL
            }
            url = continuationURL
        } else {
            url = try endpoint(
                path: "/api/v4/questions/\(questionID)/feeds",
                query: [
                    URLQueryItem(name: "limit", value: "20"),
                    URLQueryItem(name: "order", value: sort.rawValue),
                    URLQueryItem(
                        name: "include",
                        value: Self.questionFeedInclude
                    ),
                ]
            )
        }
        let data = try await client.data(for: url, authentication: .accountRequired)
        do {
            let response = try decoder.decode(QuestionAnswersResponse.self, from: data)
            var seen = Set<Int64>()
            let items = response.data
                .compactMap(\.value)
                .compactMap(\.answerPreview)
                .filter { $0.questionID == questionID && seen.insert($0.answerID).inserted }
            let continuationURL = try response.paging?.next.flatMap(URL.init(string:)).map {
                try continuation($0, requiredPrefix: "/api/v4/questions/\(questionID)/feeds")
            }
            return QuestionAnswerPageDTO(
                items: items,
                nextURL: continuationURL,
                isEnd: response.paging?.isEnd == true || continuationURL == nil
            )
        } catch let error as QuestionAnswerRepositoryError {
            throw error
        } catch {
            throw QuestionAnswerRepositoryError.malformedAnswerPage
        }
    }

    func setQuestionFollowing(_ following: Bool, questionID: Int64) async throws {
        let url = try endpoint(path: "/api/v4/questions/\(questionID)/followers")
        _ = try await client.data(
            for: url,
            method: following ? "POST" : "DELETE",
            authentication: .accountRequired
        )
    }

    func fetchAnswer(_ route: AnswerRouteDTO) async throws -> AnswerDTO {
        let path = route.kind == .answer
            ? "/api/v4/answers/\(route.contentID)"
            : "/api/v4/articles/\(route.contentID)"
        let include = route.kind == .answer ? Self.answerInclude : Self.articleInclude
        let data = try await client.data(
            for: endpoint(path: path, query: [URLQueryItem(name: "include", value: include)]),
            authentication: .accountRequired
        )
        do {
            switch route.kind {
            case .answer:
                let response = try decoder.decode(AnswerResponse.self, from: data)
                return try response.dto(route: route)
            case .article:
                return try decoder.decode(ArticleResponse.self, from: data).dto(route: route)
            }
        } catch {
            throw QuestionAnswerRepositoryError.malformedContent
        }
    }

    func recordReadHistory(contentToken: String, contentType: String) async {
        await client.recordReadHistory(contentToken: contentToken, contentType: contentType)
    }

    func setVote(_ state: QAVoteState, route: AnswerRouteDTO) async throws -> QAVoteMutationResult {
        guard route.kind == .answer || state != .down else {
            throw QuestionAnswerRepositoryError.unsupportedAction
        }
        let path = route.kind == .answer
            ? "/api/v4/answers/\(route.contentID)/voters"
            : "/api/v4/articles/\(route.contentID)/voters"
        let payload: [String: Any] = route.kind == .answer
            ? ["type": state.answerRequestValue]
            : ["voting": state == .up ? 1 : 0]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let data = try await client.data(
            for: endpoint(path: path),
            method: "POST",
            body: body,
            additionalHeaders: ["Content-Type": "application/json"],
            authentication: .accountRequired
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = root["voteup_count"] as? Int
        else { throw QuestionAnswerRepositoryError.malformedMutation }
        return QAVoteMutationResult(state: state, voteUpCount: count)
    }

    func fetchCollections(route: AnswerRouteDTO) async throws -> QACollectionsResult {
        let type = route.kind.rawValue
        let url = try apiEndpoint(
            host: "api.zhihu.com",
            path: "/collections/contents/\(type)/\(route.contentID)",
            query: [URLQueryItem(name: "limit", value: "50")]
        )
        let data = try await client.data(for: url, authentication: .accountRequired)
        do {
            let response = try decoder.decode(CollectionsResponse.self, from: data)
            let items = response.data.compactMap(\.value).map(\.dto)
            guard response.data.isEmpty || !items.isEmpty else {
                throw QuestionAnswerRepositoryError.malformedCollections
            }
            return QACollectionsResult(
                items: items,
                favoriteState: items.contains(where: \.isFavorited) ? .favorited : .notFavorited
            )
        } catch {
            throw QuestionAnswerRepositoryError.malformedCollections
        }
    }

    func setCollection(
        _ selected: Bool,
        collectionID: String,
        route: AnswerRouteDTO
    ) async throws {
        guard !collectionID.isEmpty,
              collectionID.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" || $0 == "_" })
        else { throw QuestionAnswerRepositoryError.invalidIdentifier }
        let url = try apiEndpoint(
            host: "api.zhihu.com",
            path: "/collections/contents/\(route.kind.rawValue)/\(route.contentID)"
        )
        let key = selected ? "add_collections" : "remove_collections"
        let body = Data("\(key)=\(collectionID)".utf8)
        _ = try await client.data(
            for: url,
            method: "PUT",
            body: body,
            additionalHeaders: ["Content-Type": "application/x-www-form-urlencoded"],
            authentication: .accountRequired
        )
    }

    private func endpoint(path: String, query: [URLQueryItem] = []) throws -> URL {
        try apiEndpoint(host: "www.zhihu.com", path: path, query: query)
    }

    private func apiEndpoint(host: String, path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, ZhihuAPIURLPolicy.allows(url) else {
            throw QuestionAnswerRepositoryError.invalidURL
        }
        return url
    }

    private func continuation(_ source: URL, requiredPrefix: String) throws -> URL {
        let url: URL
        do {
            guard let validated = try ZhihuAPIURLPolicy.validatedPagingURL(source) else {
                throw QuestionAnswerRepositoryError.untrustedContinuation
            }
            url = validated
        } catch {
            throw QuestionAnswerRepositoryError.untrustedContinuation
        }
        guard
              url.user == nil,
              url.password == nil,
              url.path == requiredPrefix
        else { throw QuestionAnswerRepositoryError.untrustedContinuation }
        return url
    }
}

enum QuestionAnswerRepositoryError: LocalizedError, Equatable {
    case invalidURL
    case invalidIdentifier
    case untrustedContinuation
    case malformedQuestion
    case malformedAnswerPage
    case malformedContent
    case malformedMutation
    case malformedCollections
    case unsupportedAction

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请求地址无效"
        case .invalidIdentifier: return "内容标识无效"
        case .untrustedContinuation: return "分页地址不可信"
        case .malformedQuestion: return "问题数据格式无法识别"
        case .malformedAnswerPage: return "回答列表格式无法识别"
        case .malformedContent: return "正文数据格式无法识别"
        case .malformedMutation: return "操作结果格式无法识别"
        case .malformedCollections: return "收藏夹数据格式无法识别"
        case .unsupportedAction: return "当前内容不支持这个操作"
        }
    }
}

private struct FlexibleID: Decodable, Hashable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string; return }
        if let integer = try? container.decode(Int64.self) { value = String(integer); return }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or integer ID")
        )
    }
}

private struct AuthorResponse: Decodable {
    let id: String?
    let urlToken: String?
    let name: String
    let headline: String?
    let avatarUrl: String?

    var dto: QAAuthorDTO {
        QAAuthorDTO(
            memberID: id ?? "",
            urlToken: urlToken ?? "",
            displayName: name,
            headline: headline ?? "",
            avatarURL: avatarUrl.flatMap(trustedImageURL)
        )
    }
}

private struct QuestionResponse: Decodable {
    let id: FlexibleID
    let title: String
    let detail: String?
    let answerCount: Int?
    let visitCount: Int?
    let commentCount: Int?
    let followerCount: Int?
    let relationship: Relationship?
    let author: AuthorResponse?
    let topics: [Topic]?

    struct Relationship: Decodable { let isFollowing: Bool? }
    struct Topic: Decodable {
        let id: FlexibleID
        let name: String
        let url: String?
    }

    func dto() throws -> QuestionDTO {
        guard let numericID = Int64(id.value) else {
            throw QuestionAnswerRepositoryError.malformedQuestion
        }
        return QuestionDTO(
            id: numericID,
            title: title,
            detailHTML: detail ?? "",
            detailBlocks: QARichContentParser.blocks(from: detail ?? ""),
            answerCount: answerCount ?? 0,
            visitCount: visitCount ?? 0,
            commentCount: commentCount ?? 0,
            followerCount: followerCount ?? 0,
            isFollowing: relationship?.isFollowing ?? false,
            author: author?.dto,
            topics: (topics ?? []).map {
                QATopicDTO(id: $0.id.value, name: $0.name, url: $0.url.flatMap(trustedActionURL))
            }
        )
    }
}

private struct QuestionAnswersResponse: Decodable {
    let data: [LossyResponse<Entry>]
    let paging: Paging?

    struct Paging: Decodable { let isEnd: Bool; let next: String? }
    struct Entry: Decodable {
        let target: Target?
        let object: Target?
        var answerPreview: AnswerPreviewDTO? { (target ?? object)?.answerPreview }
    }
    struct Target: Decodable {
        let type: String
        let id: FlexibleID
        let excerpt: String?
        let voteupCount: Int?
        let commentCount: Int?
        let author: AuthorResponse?
        let question: Question?

        struct Question: Decodable { let id: FlexibleID; let title: String?; let name: String? }

        var answerPreview: AnswerPreviewDTO? {
            guard type == "answer",
                  let answerID = Int64(id.value),
                  let question,
                  let questionID = Int64(question.id.value),
                  let author
            else { return nil }
            return AnswerPreviewDTO(
                answerID: answerID,
                questionID: questionID,
                questionTitle: question.title ?? question.name ?? "",
                author: author.dto,
                excerpt: QARichContentParser.plainText(excerpt ?? ""),
                voteUpCount: voteupCount ?? 0,
                commentCount: commentCount ?? 0
            )
        }
    }
}

private struct LossyResponse<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

private struct RelationshipResponse: Decodable {
    let voting: Int?
    let vote: String?
    let isFavorited: Bool?
}

private struct ReactionResponse: Decodable {
    let relation: RelationshipResponse?
}

private struct AnswerQuestionResponse: Decodable {
    let id: FlexibleID
    let title: String
}

private struct EndorsementResponse: Decodable {
    let actionUrl: String?
    let elements: [Element]?

    struct Element: Decodable {
        let type: String?
        let content: String?
        let imageKey: String?
    }

    var dto: QAEndorsementDTO? {
        let elements = elements ?? []
        let text = elements
            .filter { $0.type == "TEXT" }
            .compactMap(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return QAEndorsementDTO(
            text: text,
            actionURL: actionUrl.flatMap(trustedActionURL),
            leadingIconKey: elements.first { $0.type == "IMAGE" && $0.imageKey?.contains("arrow") != true }?.imageKey
        )
    }
}

private struct AttachmentResponse: Decodable {
    let type: String?
    let attachmentId: FlexibleID?
    let video: Video?

    struct Video: Decodable {
        let videoInfo: VideoInfo?
        struct VideoInfo: Decodable { let thumbnail: String?; let playlist: Playlist? }
        struct Playlist: Decodable { let hd: Play?; let sd: Play? }
        struct Play: Decodable { let playUrl: String? }
    }

    var dto: QAAttachmentVideoDTO? {
        guard type == "video", let rawID = attachmentId?.value, let id = Int64(rawID) else { return nil }
        return QAAttachmentVideoDTO(
            videoID: id,
            thumbnailURL: video?.videoInfo?.thumbnail.flatMap(trustedImageURL),
            destinationURL: URL(string: "https://www.zhihu.com/zvideo/\(id)"),
            playbackURL: (
                video?.videoInfo?.playlist?.hd?.playUrl ??
                    video?.videoInfo?.playlist?.sd?.playUrl
            ).flatMap(trustedPlaybackURL)
        )
    }
}

private struct AnswerResponse: Decodable {
    let id: FlexibleID
    let content: String
    let author: AuthorResponse
    let question: AnswerQuestionResponse
    let attachment: AttachmentResponse?
    let voteupCount: Int?
    let favlistsCount: Int?
    let commentCount: Int?
    let createdTime: Int64?
    let updatedTime: Int64?
    let ipInfo: String?
    let url: String?
    let relationship: RelationshipResponse?
    let reaction: ReactionResponse?
    let endorsements: [EndorsementResponse]?

    func dto(route: AnswerRouteDTO) throws -> AnswerDTO {
        guard let contentID = Int64(id.value), contentID == route.contentID,
              let questionID = Int64(question.id.value)
        else { throw QuestionAnswerRepositoryError.malformedContent }
        let source = URL(string: "https://www.zhihu.com/question/\(questionID)/answer/\(contentID)")!
        let relation = reaction?.relation ?? relationship
        let parsedAttachment = attachment?.dto
        var consumedAttachment = false
        let blocks = QARichContentParser.blocks(from: content).map { block -> QABodyBlock in
            guard let parsedAttachment,
                  case let .video(id, embedded) = block,
                  embedded.videoID == parsedAttachment.videoID
            else { return block }
            consumedAttachment = true
            return .video(id, parsedAttachment)
        }
        return AnswerDTO(
            route: AnswerRouteDTO(
                contentID: contentID,
                kind: .answer,
                questionID: questionID,
                provisionalTitle: question.title,
                source: route.source
            ),
            title: question.title,
            questionID: questionID,
            author: author.dto,
            blocks: blocks,
            attachment: consumedAttachment ? nil : parsedAttachment,
            sourceURL: source,
            voteUpCount: voteupCount ?? 0,
            favoriteCount: favlistsCount ?? 0,
            commentCount: commentCount ?? 0,
            voteState: voteState(relation),
            favoriteState: relation?.isFavorited.map { $0 ? .favorited : .notFavorited } ?? .unknown,
            createdTimeSeconds: createdTime ?? 0,
            updatedTimeSeconds: updatedTime ?? createdTime ?? 0,
            ipLocation: ipInfo?.nilIfBlank,
            invitationPreface: nil,
            endorsements: (endorsements ?? []).compactMap(\.dto)
        )
    }
}

private struct ArticleResponse: Decodable {
    let id: FlexibleID
    let title: String
    let content: String
    let author: AuthorResponse
    let voteupCount: Int?
    let favlistsCount: Int?
    let commentCount: Int?
    let created: Int64?
    let updated: Int64?
    let ipInfo: String?
    let url: String?
    let relationship: RelationshipResponse?

    func dto(route: AnswerRouteDTO) throws -> AnswerDTO {
        guard let contentID = Int64(id.value), contentID == route.contentID else {
            throw QuestionAnswerRepositoryError.malformedContent
        }
        return AnswerDTO(
            route: AnswerRouteDTO(
                contentID: contentID,
                kind: .article,
                provisionalTitle: title,
                source: route.source
            ),
            title: title,
            questionID: nil,
            author: author.dto,
            blocks: QARichContentParser.blocks(from: content),
            attachment: nil,
            sourceURL: URL(string: "https://zhuanlan.zhihu.com/p/\(contentID)")!,
            voteUpCount: voteupCount ?? 0,
            favoriteCount: favlistsCount ?? 0,
            commentCount: commentCount ?? 0,
            voteState: voteState(relationship),
            favoriteState: relationship?.isFavorited.map { $0 ? .favorited : .notFavorited } ?? .unknown,
            createdTimeSeconds: created ?? 0,
            updatedTimeSeconds: updated ?? created ?? 0,
            ipLocation: ipInfo?.nilIfBlank,
            invitationPreface: nil,
            endorsements: []
        )
    }
}

private struct CollectionsResponse: Decodable {
    let data: [LossyResponse<Collection>]
    struct Collection: Decodable {
        let id: FlexibleID
        let title: String
        let isFavorited: Bool?
        var dto: QACollectionDTO {
            QACollectionDTO(id: id.value, title: title, isFavorited: isFavorited ?? false)
        }
    }
}

private func voteState(_ relationship: RelationshipResponse?) -> QAVoteState {
    if relationship?.voting == 1 || relationship?.vote?.uppercased() == "UP" { return .up }
    if relationship?.voting == -1 || relationship?.vote?.uppercased() == "DOWN" { return .down }
    return .neutral
}

private func trustedImageURL(_ raw: String) -> URL? {
    let value = raw.hasPrefix("//") ? "https:\(raw)" : raw
    guard let url = URL(string: value),
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil
    else { return nil }
    return url
}

private func trustedActionURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
    if scheme == "zhihu" { return url }
    return scheme == "https" && url.user == nil && url.password == nil ? url : nil
}

private func trustedPlaybackURL(_ raw: String) -> URL? {
    let value = raw.hasPrefix("//") ? "https:\(raw)" : raw
    guard let url = URL(string: value),
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          let host = url.host?.lowercased(),
          host == "vzuu.com" || host.hasSuffix(".vzuu.com") ||
          host == "zhimg.com" || host.hasSuffix(".zhimg.com") ||
          host == "zhihu.com" || host.hasSuffix(".zhihu.com")
    else { return nil }
    return url
}

private extension QAVoteState {
    var answerRequestValue: String {
        switch self {
        case .neutral: return "neutral"
        case .up: return "up"
        case .down: return "down"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
