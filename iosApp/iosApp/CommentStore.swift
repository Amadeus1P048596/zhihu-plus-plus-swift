import Foundation

enum CommentComposerPresentation: Equatable {
    case hidden
    case active(level: CommentLevelKey)

    func isActive(for level: CommentLevelKey) -> Bool {
        self == .active(level: level)
    }
}

@MainActor
final class CommentSessionStore: ObservableObject {
    let sessionID: CommentSessionID
    let route: CommentThreadRouteDTO

    @Published private(set) var pages: [CommentLevelKey: CommentPageState]
    @Published var navigationPath: [CommentLevelKey]
    @Published private(set) var rootSort: CommentSortDTO = .score
    @Published var draft = CommentComposerDraft()
    @Published private(set) var message: CommentUserMessage?
    @Published private(set) var galleryDestination: CommentMediaGalleryDestination?
    @Published private(set) var scrollToStartLevel: CommentLevelKey?
    @Published private(set) var composerPresentation: CommentComposerPresentation = .hidden

    private let repository: CommentRepository
    private let onOpenPerson: (PersonRoutePayload) -> Void
    private var anchors: [CommentLevelKey: CommentScrollAnchor] = [:]
    private var drafts: [CommentLevelKey: CommentComposerDraft] = [:]
    private var pageTasks: [CommentLevelKey: Task<Void, Never>] = [:]
    private var likeTasks: [CommentLevelKey: Task<Void, Never>] = [:]
    private var submissionTask: Task<Void, Never>?
    private var operationID: UInt64 = 0
    private var isDisposed = false

    init(
        route: CommentThreadRouteDTO,
        repository: CommentRepository,
        sessionID: CommentSessionID = CommentSessionID(),
        onOpenPerson: @escaping (PersonRoutePayload) -> Void
    ) {
        self.route = route
        self.repository = repository
        self.sessionID = sessionID
        self.onOpenPerson = onOpenPerson
        let rootKey = CommentPageAcceptanceKey(sessionID: sessionID, level: .root, generation: 0)
        var pages: [CommentLevelKey: CommentPageState] = [.root: CommentPageState(acceptanceKey: rootKey)]
        switch route.initialLevel {
        case .root:
            navigationPath = []
        case let .replies(rootCommentID):
            let level = CommentLevelKey.replies(rootCommentID: rootCommentID)
            pages[level] = CommentPageState(
                acceptanceKey: CommentPageAcceptanceKey(sessionID: sessionID, level: level, generation: 0)
            )
            navigationPath = [level]
        }
        self.pages = pages
    }

    var activeLevel: CommentLevelKey { navigationPath.last ?? .root }

    var activePage: CommentPageState {
        pages[activeLevel] ?? newPage(for: activeLevel, generation: 0)
    }

    var activeReplyTargetName: String? {
        guard let id = draft.replyTargetCommentID else { return nil }
        return commentInSession(withID: id)?.author.displayName
    }

    func rootComment(for level: CommentLevelKey) -> CommentDTO? {
        guard case let .replies(rootCommentID) = level else { return nil }
        return comment(withID: rootCommentID, in: pages[.root]?.items ?? [])
    }

    func start() {
        guard !isDisposed else { return }
        loadInitial(level: activeLevel, invalidating: false)
    }

    func changeSort(_ sort: CommentSortDTO) {
        guard !isDisposed, rootSort != sort else { return }
        rootSort = sort
        anchors[.root] = nil
        loadInitial(level: .root, invalidating: true)
    }

    func retryInitial(level: CommentLevelKey? = nil) {
        loadInitial(level: level ?? activeLevel, invalidating: true)
    }

    func refresh(level: CommentLevelKey? = nil) async {
        let level = level ?? activeLevel
        loadInitial(level: level, invalidating: true)
        await pageTasks[level]?.value
    }

    func loadNextIfNeeded(after commentID: String, level: CommentLevelKey? = nil) {
        let level = level ?? activeLevel
        guard pages[level]?.items.suffix(3).contains(where: { $0.id == commentID }) == true else { return }
        loadNext(level: level)
    }

    func retryNext(level: CommentLevelKey? = nil) {
        loadNext(level: level ?? activeLevel)
    }

    func openReplies(rootCommentID: String) {
        guard !isDisposed,
              activeLevel == .root,
              comment(withID: rootCommentID, in: pages[.root]?.items ?? []) != nil
        else { return }
        let level = CommentLevelKey.replies(rootCommentID: rootCommentID)
        navigationPathChanged([level])
        if pages[level] == nil {
            pages[level] = newPage(for: level, generation: 0)
        }
        loadInitial(level: level, invalidating: false)
    }

    func dismissReplies() {
        guard activeLevel != .root else { return }
        navigationPathChanged([])
    }

    func navigationPathChanged(_ path: [CommentLevelKey]) {
        guard !isDisposed else { return }
        let previousLevel = activeLevel
        let nextPath = Array(path.prefix(1))
        let nextLevel = nextPath.last ?? .root
        cancelActiveSubmissionForLevelChange()
        dismissComposer(for: activeLevel)
        preserveActiveDraft()
        if previousLevel != nextLevel,
           galleryDestination?.sourceLevel == previousLevel {
            galleryDestination = nil
        }
        navigationPath = nextPath
        draft = drafts[nextLevel] ?? CommentComposerDraft()
        draft.replyTargetCommentID = nil
    }

    func setDraftText(_ text: String) {
        guard !isDisposed else { return }
        draft.text = text
        if case .failed = draft.submissionState {
            draft.submissionState = .idle
        }
    }

    func appendEmoji(_ placeholder: String) {
        setDraftText(draft.text + placeholder)
    }

    func setDraftImage(_ data: Data?) {
        guard !isDisposed else { return }
        draft.imageData = data
        if case .failed = draft.submissionState {
            draft.submissionState = .idle
        }
    }

    func beginReply(to commentID: String, level requestedLevel: CommentLevelKey? = nil) {
        let level = requestedLevel ?? activeLevel
        guard !isDisposed,
              level == activeLevel,
              (comment(withID: commentID, in: pages[level]?.items ?? []) != nil
                || commentInSession(withID: commentID) != nil)
        else { return }
        draft.replyTargetCommentID = commentID
        composerPresentation = .active(level: level)
    }

    func beginComment(level requestedLevel: CommentLevelKey? = nil) {
        let level = requestedLevel ?? activeLevel
        guard !isDisposed, level == activeLevel else { return }
        switch level {
        case .root:
            draft.replyTargetCommentID = nil
        case let .replies(rootCommentID):
            guard commentInSession(withID: rootCommentID) != nil else { return }
            draft.replyTargetCommentID = rootCommentID
        }
        composerPresentation = .active(level: level)
    }

    func dismissComposer(for requestedLevel: CommentLevelKey? = nil) {
        let level = requestedLevel ?? activeLevel
        guard level == activeLevel else { return }
        draft.replyTargetCommentID = nil
        composerPresentation = .hidden
    }

    func toggleLike(commentID: String, level requestedLevel: CommentLevelKey? = nil) {
        let level = requestedLevel ?? activeLevel
        guard !isDisposed,
              var page = pages[level],
              page.activeLikeMutation == nil,
              let current = comment(withID: commentID, in: page.items)
        else { return }
        operationID &+= 1
        let mutation = CommentLikeMutationDTO(
            operationID: operationID,
            acceptanceKey: page.acceptanceKey,
            commentID: commentID,
            targetIsLiked: !current.isLiked
        )
        page.activeLikeMutation = mutation
        pages[level] = page
        likeTasks[level]?.cancel()
        likeTasks[level] = Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.setLiked(mutation.targetIsLiked, commentID: commentID)
                guard accepts(mutation, level: level), var acceptedPage = pages[level] else { return }
                acceptedPage.items = replacingComment(
                    commentID,
                    in: acceptedPage.items
                ) { comment in
                    comment.replacingLikeState(
                        isLiked: mutation.targetIsLiked,
                        likeCount: comment.likeCount + (mutation.targetIsLiked ? 1 : -1)
                    )
                }
                acceptedPage.activeLikeMutation = nil
                pages[level] = acceptedPage
            } catch is CancellationError {
                return
            } catch {
                guard accepts(mutation, level: level), var acceptedPage = pages[level] else { return }
                acceptedPage.activeLikeMutation = nil
                pages[level] = acceptedPage
                show(error)
            }
        }
    }

    func submitDraft() {
        let level = activeLevel
        guard !isDisposed,
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.imageData != nil,
              case .idle = draft.submissionState,
              let page = pages[level]
        else { return }
        operationID &+= 1
        let effectiveTarget: String?
        switch level {
        case .root:
            effectiveTarget = draft.replyTargetCommentID
        case let .replies(rootCommentID):
            effectiveTarget = draft.replyTargetCommentID ?? rootCommentID
        }
        let snapshot = CommentSubmissionSnapshotDTO(
            operationID: operationID,
            acceptanceKey: page.acceptanceKey,
            subject: route.subject,
            level: level,
            text: draft.text,
            imageData: draft.imageData,
            replyToCommentID: effectiveTarget
        )
        let replyRootCommentID = effectiveTarget.flatMap { target in
            rootCommentID(containing: target, activeLevel: level)
        }
        draft.submissionState = .submitting(operationID: operationID)
        submissionTask?.cancel()
        submissionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let comment = try await repository.submit(snapshot)
                guard accepts(snapshot), var acceptedPage = pages[level] else { return }
                if let rootCommentID = replyRootCommentID {
                    let wasKnown = commentInSession(withID: comment.id) != nil
                    appendSubmittedReply(
                        comment,
                        rootCommentID: rootCommentID,
                        activePage: &acceptedPage,
                        activeLevel: level,
                        incrementingCount: !wasKnown
                    )
                    pages[level] = acceptedPage
                } else {
                    acceptedPage.items.removeAll { $0.id == comment.id }
                    acceptedPage.items.insert(comment, at: 0)
                    pages[level] = acceptedPage
                    scrollToStartLevel = level
                }
                draft = CommentComposerDraft()
                drafts[level] = draft
            } catch is CancellationError {
                return
            } catch {
                guard accepts(snapshot) else { return }
                draft.submissionState = .failed(operationID: snapshot.operationID, message: displayMessage(error))
                show(error)
            }
        }
    }

    func retrySubmission() {
        guard case .failed = draft.submissionState else { return }
        draft.submissionState = .idle
        submitDraft()
    }

    func openAuthor(commentID: String, replyToAuthor: Bool = false) {
        guard !isDisposed,
              let comment = commentInSession(withID: commentID),
              let route = (replyToAuthor ? comment.replyToAuthor : comment.author)?.personRoute
        else { return }
        preserveActiveDraft()
        onOpenPerson(route)
    }

    func openMedia(
        commentID: String,
        mediaID: CommentMediaDTO.ID,
        level requestedLevel: CommentLevelKey? = nil
    ) {
        let level = requestedLevel ?? activeLevel
        guard !isDisposed,
              level == activeLevel,
              let comment = commentInSession(withID: commentID),
              let destination = CommentMediaGalleryDestination(
                media: comment.media,
                selectedID: mediaID,
                sourceLevel: level
              )
        else { return }
        galleryDestination = destination
    }

    func galleryDestination(for level: CommentLevelKey) -> CommentMediaGalleryDestination? {
        guard galleryDestination?.sourceLevel == level else { return nil }
        return galleryDestination
    }

    func galleryBindingChanged(
        to destination: CommentMediaGalleryDestination?,
        for level: CommentLevelKey
    ) {
        if destination == nil, galleryDestination?.sourceLevel == level {
            galleryDestination = nil
        }
    }

    func updateAnchor(_ anchor: CommentScrollAnchor?, for level: CommentLevelKey) {
        anchors[level] = anchor
    }

    func restorationContext() -> CommentRestorationContext {
        preserveActiveDraft()
        var replyAnchors: [String: CommentScrollAnchor] = [:]
        for (level, anchor) in anchors {
            if case let .replies(rootCommentID) = level {
                replyAnchors[rootCommentID] = anchor
            }
        }
        return CommentRestorationContext(
            sessionID: sessionID,
            level: activeLevel,
            rootSort: rootSort,
            rootAnchor: anchors[.root],
            replyAnchors: replyAnchors,
            activeDraft: draft
        )
    }

    func anchorRestorationResult(for level: CommentLevelKey) -> CommentAnchorRestorationResult {
        guard let anchor = anchors[level] else { return .noAnchor }
        guard pages[level]?.items.contains(where: { $0.id == anchor.commentID }) == true else {
            return .missingAnchor(anchor)
        }
        return .restored(anchor)
    }

    func consumeScrollToStart(for level: CommentLevelKey) {
        if scrollToStartLevel == level { scrollToStartLevel = nil }
    }

    func messageBindingChanged(to message: CommentUserMessage?) {
        if message == nil { self.message = nil }
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        composerPresentation = .hidden
        draft.replyTargetCommentID = nil
        pageTasks.values.forEach { $0.cancel() }
        likeTasks.values.forEach { $0.cancel() }
        submissionTask?.cancel()
        pageTasks.removeAll()
        likeTasks.removeAll()
        galleryDestination = nil
    }

    private func loadInitial(level: CommentLevelKey, invalidating: Bool) {
        guard !isDisposed else { return }
        pageTasks[level]?.cancel()
        var page = pages[level] ?? newPage(for: level, generation: 0)
        if !invalidating, page.initialLoad == .loaded || page.initialLoad == .loading { return }
        let generation = invalidating ? page.acceptanceKey.generation &+ 1 : page.acceptanceKey.generation
        page.acceptanceKey = CommentPageAcceptanceKey(
            sessionID: sessionID,
            level: level,
            generation: generation
        )
        page.initialLoad = .loading
        page.nextPage = .idle
        page.isEnd = false
        page.items = []
        page.nextURL = nil
        page.activeLikeMutation = nil
        pages[level] = page
        likeTasks[level]?.cancel()
        let acceptanceKey = page.acceptanceKey
        pageTasks[level] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.fetchPage(
                    route: route,
                    level: level,
                    sort: rootSort,
                    nextURL: nil
                )
                guard accepts(acceptanceKey), var acceptedPage = pages[level] else { return }
                acceptedPage.items = unique(result.items)
                acceptedPage.nextURL = result.nextURL
                acceptedPage.isEnd = result.isEnd
                acceptedPage.initialLoad = .loaded
                acceptedPage.nextPage = .idle
                pages[level] = acceptedPage
            } catch is CancellationError {
                return
            } catch {
                guard accepts(acceptanceKey), var acceptedPage = pages[level] else { return }
                acceptedPage.initialLoad = .failed(displayMessage(error))
                pages[level] = acceptedPage
            }
        }
    }

    private func loadNext(level: CommentLevelKey) {
        guard !isDisposed,
              var page = pages[level],
              page.initialLoad == .loaded,
              page.nextPage != .loading,
              !page.isEnd,
              let nextURL = page.nextURL
        else { return }
        page.nextPage = .loading
        pages[level] = page
        let acceptanceKey = page.acceptanceKey
        pageTasks[level]?.cancel()
        pageTasks[level] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.fetchPage(
                    route: route,
                    level: level,
                    sort: rootSort,
                    nextURL: nextURL
                )
                guard accepts(acceptanceKey), var acceptedPage = pages[level] else { return }
                var seen = Set(acceptedPage.items.map(\.id))
                acceptedPage.items.append(contentsOf: result.items.filter { seen.insert($0.id).inserted })
                acceptedPage.nextURL = result.nextURL
                acceptedPage.isEnd = result.isEnd
                acceptedPage.nextPage = .idle
                pages[level] = acceptedPage
            } catch is CancellationError {
                return
            } catch {
                guard accepts(acceptanceKey), var acceptedPage = pages[level] else { return }
                acceptedPage.nextPage = .failed(displayMessage(error))
                pages[level] = acceptedPage
            }
        }
    }

    private func newPage(for level: CommentLevelKey, generation: UInt64) -> CommentPageState {
        CommentPageState(
            acceptanceKey: CommentPageAcceptanceKey(
                sessionID: sessionID,
                level: level,
                generation: generation
            )
        )
    }

    private func accepts(_ key: CommentPageAcceptanceKey) -> Bool {
        !isDisposed && pages[key.level]?.acceptanceKey == key
    }

    private func accepts(_ mutation: CommentLikeMutationDTO, level: CommentLevelKey) -> Bool {
        !isDisposed && pages[level]?.activeLikeMutation == mutation && accepts(mutation.acceptanceKey)
    }

    private func accepts(_ snapshot: CommentSubmissionSnapshotDTO) -> Bool {
        guard !isDisposed,
              accepts(snapshot.acceptanceKey),
              case let .submitting(operationID) = draft.submissionState
        else { return false }
        return operationID == snapshot.operationID && activeLevel == snapshot.level
    }

    private func preserveActiveDraft() {
        drafts[activeLevel] = draft
    }

    private func cancelActiveSubmissionForLevelChange() {
        submissionTask?.cancel()
        submissionTask = nil
        if case .submitting = draft.submissionState {
            draft.submissionState = .idle
        }
    }

    private func comment(withID id: String, in comments: [CommentDTO]) -> CommentDTO? {
        for candidate in comments {
            if candidate.id == id { return candidate }
            if let nested = comment(withID: id, in: candidate.embeddedReplies) { return nested }
        }
        return nil
    }

    private func commentInSession(withID id: String) -> CommentDTO? {
        for page in pages.values {
            if let comment = comment(withID: id, in: page.items) { return comment }
        }
        return nil
    }

    private func rootCommentID(containing commentID: String, activeLevel: CommentLevelKey) -> String? {
        if case let .replies(rootCommentID) = activeLevel { return rootCommentID }
        for root in pages[.root]?.items ?? [] {
            if root.id == commentID || comment(withID: commentID, in: root.embeddedReplies) != nil {
                return root.id
            }
            let replyLevel = CommentLevelKey.replies(rootCommentID: root.id)
            if comment(withID: commentID, in: pages[replyLevel]?.items ?? []) != nil {
                return root.id
            }
        }
        return nil
    }

    private func appendSubmittedReply(
        _ reply: CommentDTO,
        rootCommentID: String,
        activePage: inout CommentPageState,
        activeLevel: CommentLevelKey,
        incrementingCount: Bool
    ) {
        if activeLevel == .root {
            activePage.items = replacingComment(rootCommentID, in: activePage.items) { root in
                root.appendingEmbeddedReply(reply, incrementingCount: incrementingCount)
            }
        } else if var rootPage = pages[.root] {
            rootPage.items = replacingComment(rootCommentID, in: rootPage.items) { root in
                root.appendingEmbeddedReply(reply, incrementingCount: incrementingCount)
            }
            pages[.root] = rootPage
        }

        let replyLevel = CommentLevelKey.replies(rootCommentID: rootCommentID)
        if activeLevel == replyLevel {
            activePage.items.removeAll { $0.id == reply.id }
            activePage.items.append(reply)
        } else if var replyPage = pages[replyLevel], replyPage.initialLoad == .loaded {
            replyPage.items.removeAll { $0.id == reply.id }
            replyPage.items.append(reply)
            pages[replyLevel] = replyPage
        }
    }

    private func replacingComment(
        _ id: String,
        in comments: [CommentDTO],
        transform: (CommentDTO) -> CommentDTO
    ) -> [CommentDTO] {
        comments.map { comment in
            if comment.id == id { return transform(comment) }
            let replies = replacingComment(id, in: comment.embeddedReplies, transform: transform)
            guard replies != comment.embeddedReplies else { return comment }
            return CommentDTO(
                id: comment.id,
                contentHTML: comment.contentHTML,
                createdTimeSeconds: comment.createdTimeSeconds,
                author: comment.author,
                replyToAuthor: comment.replyToAuthor,
                isLiked: comment.isLiked,
                likeCount: comment.likeCount,
                childCommentCount: comment.childCommentCount,
                embeddedReplies: replies,
                media: comment.media
            )
        }
    }

    private func unique(_ comments: [CommentDTO]) -> [CommentDTO] {
        var seen = Set<String>()
        return comments.filter { seen.insert($0.id).inserted }
    }

    private func show(_ error: Error) {
        message = CommentUserMessage(text: displayMessage(error))
    }

    private func displayMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
