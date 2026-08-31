import Foundation
import XCTest
@testable import iosApp

@MainActor
final class CommentStoreTests: XCTestCase {
    func testInitialLoadPublishesUniqueRowsAndDefaultScoreSort() async {
        let comment = fixtureComment(id: "root")
        let repository = CommentRepositoryStub(
            pages: [.success(CommentPageResult(items: [comment, comment], nextURL: nil, isEnd: true))]
        )
        let store = makeStore(repository: repository)

        store.start()
        await waitUntil { store.pages[.root]?.initialLoad == .loaded }

        XCTAssertEqual(store.rootSort, .score)
        XCTAssertEqual(store.pages[.root]?.items.map(\.id), ["root"])
        XCTAssertTrue(store.pages[.root]?.isEnd == true)
    }

    func testChangingRootSortInvalidatesPageAndRequestsLatestSort() async {
        let repository = CommentRepositoryStub(pages: [
            .success(CommentPageResult(items: [fixtureComment(id: "hot")], nextURL: nil, isEnd: true)),
            .success(CommentPageResult(items: [fixtureComment(id: "latest")], nextURL: nil, isEnd: true)),
        ])
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.items.first?.id == "hot" }
        let scoreGeneration = store.pages[.root]?.acceptanceKey.generation

        store.changeSort(.time)
        await waitUntil { store.pages[.root]?.items.first?.id == "latest" }

        let requestedSorts = await repository.requestedSorts()
        XCTAssertEqual(requestedSorts, [.score, .time])
        XCTAssertEqual(store.pages[.root]?.acceptanceKey.generation, scoreGeneration.map { $0 + 1 })
    }

    func testNextPageFailureRetainsRowsAndRetryContinuesSamePage() async {
        let next = URL(string: "https://www.zhihu.com/api/v4/comment_v5/answers/1/root_comment?page=2")!
        let repository = CommentRepositoryStub(pages: [
            .success(CommentPageResult(items: [fixtureComment(id: "one")], nextURL: next, isEnd: false)),
            .failure(CommentTestFailure.network),
            .success(CommentPageResult(items: [fixtureComment(id: "two")], nextURL: nil, isEnd: true)),
        ])
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.items.count == 1 }

        store.loadNextIfNeeded(after: "one")
        await waitUntil {
            if case .some(.failed) = store.pages[.root]?.nextPage { return true }
            return false
        }
        XCTAssertEqual(store.pages[.root]?.items.map(\.id), ["one"])

        store.retryNext()
        await waitUntil { store.pages[.root]?.items.count == 2 }
        XCTAssertEqual(store.pages[.root]?.items.map(\.id), ["one", "two"])
    }

    func testLikeTargetComesFromAuthoritativeRowAndFailureDoesNotMutateIt() async {
        let repository = CommentRepositoryStub(
            pages: [.success(CommentPageResult(items: [fixtureComment(id: "one", liked: false, likes: 7)], nextURL: nil, isEnd: true))],
            likes: [.failure(CommentTestFailure.network)]
        )
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.items.count == 1 }

        store.toggleLike(commentID: "one")
        await waitUntil { store.pages[.root]?.activeLikeMutation == nil }

        XCTAssertEqual(store.pages[.root]?.items.first?.isLiked, false)
        XCTAssertEqual(store.pages[.root]?.items.first?.likeCount, 7)
        let targets = await repository.likeTargets()
        XCTAssertEqual(targets, [true])
    }

    func testSubmissionFailurePreservesDraftAndRetryPrependsReturnedComment() async {
        let submitted = fixtureComment(id: "submitted")
        let repository = CommentRepositoryStub(
            pages: [.success(CommentPageResult(items: [fixtureComment(id: "old")], nextURL: nil, isEnd: true))],
            submissions: [.failure(CommentTestFailure.network), .success(submitted)]
        )
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.items.count == 1 }
        store.setDraftText("<&\"'>")

        store.submitDraft()
        await waitUntil {
            if case .failed = store.draft.submissionState { return true }
            return false
        }
        XCTAssertEqual(store.draft.text, "<&\"'>")

        store.retrySubmission()
        await waitUntil { store.pages[.root]?.items.first?.id == "submitted" }
        XCTAssertEqual(store.draft, CommentComposerDraft())
        XCTAssertEqual(store.scrollToStartLevel, .root)
    }

    func testReplySheetUsesReplyLevelAndTargetsRootComment() async {
        let root = fixtureComment(id: "root", childCount: 1)
        let repository = CommentRepositoryStub(
            pages: [
                .success(CommentPageResult(items: [root], nextURL: nil, isEnd: true)),
                .success(CommentPageResult(items: [], nextURL: nil, isEnd: true)),
            ],
            submissions: [.success(fixtureComment(id: "reply"))]
        )
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.items.count == 1 }
        store.openReplies(rootCommentID: "root")
        await waitUntil { store.pages[.replies(rootCommentID: "root")]?.initialLoad == .loaded }
        XCTAssertEqual(store.navigationPath, [.replies(rootCommentID: "root")])
        store.beginReply(to: "root")
        XCTAssertEqual(
            store.composerPresentation,
            .active(level: .replies(rootCommentID: "root"))
        )
        store.setDraftText("回复内容")

        store.submitDraft()
        await waitUntil {
            store.pages[.replies(rootCommentID: "root")]?.items.last?.id == "reply"
        }

        let snapshots = await repository.submissionSnapshots()
        XCTAssertEqual(snapshots.first?.replyToCommentID, "root")
        XCTAssertEqual(snapshots.first?.level, .replies(rootCommentID: "root"))
        XCTAssertEqual(store.pages[.root]?.items.first?.id, "root")
        XCTAssertEqual(store.pages[.root]?.items.first?.childCommentCount, 2)
        XCTAssertEqual(store.pages[.root]?.items.first?.embeddedReplies.last?.id, "reply")
    }

    func testReplySheetDismissClearsTargetAndHidesComposerWhilePreservingDraftText() async {
        let root = fixtureComment(id: "root", childCount: 1)
        let repository = CommentRepositoryStub(pages: [
            .success(CommentPageResult(items: [root], nextURL: nil, isEnd: true)),
            .success(CommentPageResult(items: [], nextURL: nil, isEnd: true)),
        ])
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.initialLoad == .loaded }
        store.setDraftText("一级草稿")
        store.beginReply(to: "root")

        store.openReplies(rootCommentID: "root")
        XCTAssertEqual(store.activeLevel, .replies(rootCommentID: "root"))
        XCTAssertEqual(store.composerPresentation, .hidden)
        XCTAssertNil(store.draft.replyTargetCommentID)
        store.setDraftText("二级草稿")
        store.beginReply(to: "root")
        XCTAssertEqual(store.draft.replyTargetCommentID, "root")

        store.dismissReplies()
        XCTAssertEqual(store.activeLevel, .root)
        XCTAssertEqual(store.draft.text, "一级草稿")
        XCTAssertNil(store.draft.replyTargetCommentID)
        XCTAssertEqual(store.composerPresentation, .hidden)

        store.openReplies(rootCommentID: "root")
        XCTAssertEqual(store.draft.text, "二级草稿")
        XCTAssertNil(store.draft.replyTargetCommentID)
        XCTAssertEqual(store.composerPresentation, .hidden)
    }

    func testReplyMediaGalleryIsScopedToReplySheetAndClearedWhenRepliesDismiss() async throws {
        let rootMedia = CommentMediaDTO(
            kind: .image,
            url: URL(string: "https://pic.zhimg.com/root.jpg")!
        )
        let replyMedia = CommentMediaDTO(
            kind: .image,
            url: URL(string: "https://pic.zhimg.com/reply.jpg")!
        )
        let root = fixtureComment(id: "root", childCount: 1, media: [rootMedia])
        let reply = fixtureComment(id: "reply", media: [replyMedia])
        let repository = CommentRepositoryStub(pages: [
            .success(CommentPageResult(items: [root], nextURL: nil, isEnd: true)),
            .success(CommentPageResult(items: [reply], nextURL: nil, isEnd: true)),
        ])
        let store = makeStore(repository: repository)
        let replyLevel = CommentLevelKey.replies(rootCommentID: "root")

        store.start()
        await waitUntil { store.pages[.root]?.initialLoad == .loaded }
        store.openMedia(commentID: "root", mediaID: rootMedia.id, level: .root)

        XCTAssertEqual(store.galleryDestination(for: .root)?.urls, [rootMedia.url])
        XCTAssertNil(store.galleryDestination(for: replyLevel))
        store.galleryBindingChanged(to: nil, for: replyLevel)
        XCTAssertNotNil(store.galleryDestination(for: .root))
        store.galleryBindingChanged(to: nil, for: .root)

        store.openReplies(rootCommentID: "root")
        await waitUntil { store.pages[replyLevel]?.initialLoad == .loaded }
        store.openMedia(commentID: "reply", mediaID: replyMedia.id, level: replyLevel)

        XCTAssertNil(store.galleryDestination(for: .root))
        XCTAssertEqual(
            try XCTUnwrap(store.galleryDestination(for: replyLevel)).urls,
            [replyMedia.url]
        )
        store.galleryBindingChanged(to: nil, for: .root)
        XCTAssertNotNil(store.galleryDestination(for: replyLevel))
        store.galleryBindingChanged(to: nil, for: replyLevel)
        XCTAssertEqual(store.activeLevel, replyLevel)

        store.openMedia(commentID: "reply", mediaID: replyMedia.id, level: replyLevel)
        store.dismissReplies()

        XCTAssertEqual(store.activeLevel, .root)
        XCTAssertNil(store.galleryDestination(for: replyLevel))
        XCTAssertNil(store.galleryDestination(for: .root))
    }

    func testCancelTargetedReplyClearsTargetAndHidesComposer() async {
        let repository = CommentRepositoryStub(pages: [
            .success(CommentPageResult(items: [fixtureComment(id: "root")], nextURL: nil, isEnd: true)),
        ])
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.initialLoad == .loaded }

        store.beginReply(to: "root")
        XCTAssertEqual(store.draft.replyTargetCommentID, "root")
        XCTAssertEqual(store.composerPresentation, .active(level: .root))

        store.dismissComposer(for: .root)
        XCTAssertNil(store.draft.replyTargetCommentID)
        XCTAssertEqual(store.composerPresentation, .hidden)
    }

    func testReplyActionTargetsCommentWithoutOpeningReplySheet() async {
        let repository = CommentRepositoryStub(pages: [
            .success(CommentPageResult(items: [fixtureComment(id: "root")], nextURL: nil, isEnd: true)),
        ])
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.initialLoad == .loaded }

        store.beginReply(to: "root", level: .root)

        XCTAssertEqual(store.activeLevel, .root)
        XCTAssertEqual(store.navigationPath, [])
        XCTAssertEqual(store.draft.replyTargetCommentID, "root")
        XCTAssertEqual(store.composerPresentation, .active(level: .root))
    }

    func testReplySheetSwipeDismissRequiresLeadingEdgeAndHorizontalIntent() {
        XCTAssertTrue(CommentReplySheetSwipePolicy.shouldDismiss(
            startLocation: CGPoint(x: 20, y: 200),
            translation: CGSize(width: 120, height: 20),
            predictedEndTranslation: CGSize(width: 150, height: 24),
            containerWidth: 390
        ))
        XCTAssertFalse(CommentReplySheetSwipePolicy.shouldDismiss(
            startLocation: CGPoint(x: 20, y: 200),
            translation: CGSize(width: 40, height: 120),
            predictedEndTranslation: CGSize(width: 80, height: 180),
            containerWidth: 390
        ))
        XCTAssertFalse(CommentReplySheetSwipePolicy.shouldDismiss(
            startLocation: CGPoint(x: 100, y: 200),
            translation: CGSize(width: 140, height: 10),
            predictedEndTranslation: CGSize(width: 180, height: 12),
            containerWidth: 390
        ))
    }

    func testReplySheetFeedbackOnlyEmitsAfterCustomEdgeDismissCommit() {
        var events: [NativeHapticFeedbackEvent] = []
        let action = NativeHapticFeedbackAction(configuration: .init()) { event, _ in
            events.append(event)
        }
        let feedback = CommentReplySheetFeedback(action: action)

        feedback.edgeDismissDidCommit(false)
        feedback.edgeDismissDidCommit(true)

        XCTAssertEqual(events, [.dismiss])
    }

    func testInlineReplyNextPageAppendsInServerOrderAndPublishesPagingStates() async {
        let next = URL(string: "https://www.zhihu.com/api/v4/comment_v5/comment/root/child_comment?page=2")!
        let root = fixtureComment(id: "root", childCount: 4)
        let repository = CommentRepositoryStub(pages: [
            .success(CommentPageResult(items: [root], nextURL: nil, isEnd: true)),
            .success(CommentPageResult(
                items: [fixtureComment(id: "reply-1"), fixtureComment(id: "reply-2")],
                nextURL: next,
                isEnd: false
            )),
            .success(CommentPageResult(
                items: [
                    fixtureComment(id: "reply-2"),
                    fixtureComment(id: "reply-3"),
                    fixtureComment(id: "reply-4"),
                ],
                nextURL: nil,
                isEnd: true
            )),
        ], yieldCount: 1)
        let store = makeStore(repository: repository)
        let replyLevel = CommentLevelKey.replies(rootCommentID: "root")
        store.start()
        await waitUntil { store.pages[.root]?.initialLoad == .loaded }
        store.openReplies(rootCommentID: "root")
        await waitUntil { store.pages[replyLevel]?.initialLoad == .loaded }

        XCTAssertEqual(store.pages[replyLevel]?.items.map(\.id), ["reply-1", "reply-2"])
        XCTAssertFalse(store.pages[replyLevel]?.isEnd ?? true)

        store.loadNextIfNeeded(after: "reply-2", level: replyLevel)
        XCTAssertEqual(store.pages[replyLevel]?.nextPage, .loading)
        await waitUntil { store.pages[replyLevel]?.isEnd == true }

        XCTAssertEqual(
            store.pages[replyLevel]?.items.map(\.id),
            ["reply-1", "reply-2", "reply-3", "reply-4"]
        )
        XCTAssertEqual(store.pages[replyLevel]?.nextPage, .idle)
        XCTAssertNil(store.pages[replyLevel]?.nextURL)
    }

    func testImageOnlyDraftCanBeSubmittedAndPreservesSelectedDataInSnapshot() async {
        let imageData = Data([0x01, 0x02, 0x03])
        let repository = CommentRepositoryStub(
            pages: [.success(CommentPageResult(items: [], nextURL: nil, isEnd: true))],
            submissions: [.success(fixtureComment(id: "image-comment"))]
        )
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.initialLoad == .loaded }
        store.setDraftImage(imageData)

        store.submitDraft()
        await waitUntil { store.pages[.root]?.items.first?.id == "image-comment" }

        let snapshots = await repository.submissionSnapshots()
        XCTAssertEqual(snapshots.first?.imageData, imageData)
        XCTAssertEqual(snapshots.first?.text, "")
    }

    func testAnchorsAreSignedPerLevelAndMissingIdentityIsExplicit() async {
        let root = fixtureComment(id: "root", childCount: 1)
        let repository = CommentRepositoryStub(
            pages: [
                .success(CommentPageResult(items: [root], nextURL: nil, isEnd: true)),
                .success(CommentPageResult(items: [fixtureComment(id: "reply")], nextURL: nil, isEnd: true)),
            ]
        )
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.pages[.root]?.items.count == 1 }
        let rootAnchor = CommentScrollAnchor(commentID: "root", offsetFromViewportTopPoints: -12)
        store.updateAnchor(rootAnchor, for: .root)
        store.openReplies(rootCommentID: "root")
        await waitUntil { store.pages[.replies(rootCommentID: "root")]?.items.count == 1 }
        let replyAnchor = CommentScrollAnchor(commentID: "reply", offsetFromViewportTopPoints: 9)
        store.updateAnchor(replyAnchor, for: .replies(rootCommentID: "root"))

        XCTAssertEqual(store.anchorRestorationResult(for: .root), .restored(rootAnchor))
        XCTAssertEqual(
            store.anchorRestorationResult(for: .replies(rootCommentID: "root")),
            .restored(replyAnchor)
        )
        let missing = CommentScrollAnchor(commentID: "gone", offsetFromViewportTopPoints: 4)
        store.updateAnchor(missing, for: .root)
        XCTAssertEqual(store.anchorRestorationResult(for: .root), .missingAnchor(missing))
    }

    func testDisposeRejectsLatePagePublication() async {
        let repository = CommentRepositoryStub(
            pages: [.success(CommentPageResult(items: [fixtureComment(id: "late")], nextURL: nil, isEnd: true))],
            yieldCount: 20
        )
        let store = makeStore(repository: repository)
        store.start()
        store.dispose()
        for _ in 0..<30 { await Task.yield() }

        XCTAssertTrue(store.pages[.root]?.items.isEmpty == true)
    }

    private func makeStore(repository: CommentRepository) -> CommentSessionStore {
        CommentSessionStore(
            route: CommentThreadRouteDTO(subject: .answer(1)),
            repository: repository,
            onOpenPerson: { _ in }
        )
    }

    private func fixtureComment(
        id: String,
        liked: Bool = false,
        likes: Int = 0,
        childCount: Int = 0,
        media: [CommentMediaDTO] = []
    ) -> CommentDTO {
        CommentDTO(
            id: id,
            contentHTML: "<p>\(id)</p>",
            createdTimeSeconds: 1,
            author: CommentAuthorDTO(memberID: "member", urlToken: "token", displayName: "作者", avatarURL: nil),
            replyToAuthor: nil,
            isLiked: liked,
            likeCount: likes,
            childCommentCount: childCount,
            embeddedReplies: [],
            media: media
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }
}

private enum CommentTestFailure: LocalizedError, Equatable {
    case missingStub
    case network

    var errorDescription: String? { self == .network ? "网络失败" : "缺少测试响应" }
}

private actor CommentRepositoryStub: CommentRepository {
    private var pages: [Result<CommentPageResult, Error>]
    private var likes: [Result<Void, Error>]
    private var submissions: [Result<CommentDTO, Error>]
    private let yieldCount: Int
    private var recordedLikeTargets: [Bool] = []
    private var recordedSnapshots: [CommentSubmissionSnapshotDTO] = []
    private var recordedSorts: [CommentSortDTO] = []

    init(
        pages: [Result<CommentPageResult, Error>],
        likes: [Result<Void, Error>] = [],
        submissions: [Result<CommentDTO, Error>] = [],
        yieldCount: Int = 0
    ) {
        self.pages = pages
        self.likes = likes
        self.submissions = submissions
        self.yieldCount = yieldCount
    }

    func fetchPage(
        route: CommentThreadRouteDTO,
        level: CommentLevelKey,
        sort: CommentSortDTO,
        nextURL: URL?
    ) async throws -> CommentPageResult {
        recordedSorts.append(sort)
        for _ in 0..<yieldCount { await Task.yield() }
        try Task.checkCancellation()
        guard !pages.isEmpty else { throw CommentTestFailure.missingStub }
        return try pages.removeFirst().get()
    }

    func setLiked(_ target: Bool, commentID: String) async throws {
        recordedLikeTargets.append(target)
        guard !likes.isEmpty else { return }
        try likes.removeFirst().get()
    }

    func submit(_ snapshot: CommentSubmissionSnapshotDTO) async throws -> CommentDTO {
        recordedSnapshots.append(snapshot)
        guard !submissions.isEmpty else { throw CommentTestFailure.missingStub }
        return try submissions.removeFirst().get()
    }

    func likeTargets() -> [Bool] { recordedLikeTargets }
    func submissionSnapshots() -> [CommentSubmissionSnapshotDTO] { recordedSnapshots }
    func requestedSorts() -> [CommentSortDTO] { recordedSorts }
}
