import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

@MainActor
final class CommentHostModel: ObservableObject, Identifiable {
    let id: CommentSessionID
    let store: CommentSessionStore
    @Published private(set) var personModel: PersonHostModel?

    private let accountStore: AccountJSONStore
    private let onPersonNavigate: (PersonNavigationIntent) -> Void

    init(
        route: CommentThreadRouteDTO,
        accountStore: AccountJSONStore,
        repository: CommentRepository? = nil,
        onPersonNavigate: @escaping (PersonNavigationIntent) -> Void
    ) {
        let sessionID = CommentSessionID()
        id = sessionID
        self.accountStore = accountStore
        self.onPersonNavigate = onPersonNavigate
        var openPerson: ((PersonRoutePayload) -> Void)?
        store = CommentSessionStore(
            route: route,
            repository: repository ?? URLSessionCommentRepository(
                client: ZhihuAPIClient(accountStore: accountStore)
            ),
            sessionID: sessionID,
            onOpenPerson: { payload in openPerson?(payload) }
        )
        openPerson = { [weak self] payload in self?.presentPerson(payload) }
    }

    deinit {
        MainActor.assumeIsolated {
            dispose()
        }
    }

    func dispose() {
        personModel?.dispose()
        personModel = nil
        store.dispose()
    }

    func personBindingChanged(isPresented: Bool) {
        guard !isPresented else { return }
        personModel?.dispose()
        personModel = nil
    }

    private func presentPerson(_ payload: PersonRoutePayload) {
        personModel?.dispose()
        personModel = PersonHostModel(
            routeEntry: PersonRouteEntry(payload: payload),
            accountStore: accountStore,
            onNavigate: onPersonNavigate
        )
    }
}

@available(iOS 16.0, *)
struct CommentNavigationPage: View {
    @ObservedObject var model: CommentHostModel

    var body: some View {
        CommentThreadContainer(
            store: model.store,
            personModel: model.personModel,
            personBindingChanged: model.personBindingChanged
        )
        .accessibilityIdentifier("comment_navigation_page")
    }
}

@available(iOS 16.0, *)
private struct CommentThreadContainer: View {
    @ObservedObject var store: CommentSessionStore
    let personModel: PersonHostModel?
    let personBindingChanged: (Bool) -> Void

    var body: some View {
        CommentLevelView(store: store, level: .root, close: nil)
            .navigationDestination(isPresented: rootPersonBinding) {
                if let personModel { PersonNativeView(model: personModel) }
            }
        .modifier(CommentMediaGalleryPresentationModifier(store: store, level: .root))
        .sheet(item: replyDestinationBinding, onDismiss: closeReplies) { destination in
            CommentReplySheetView(
                store: store,
                level: destination.level,
                personModel: personModel,
                personBindingChanged: personBindingChanged,
                close: closeReplies
            )
        }
        .alert(
            item: Binding(
                get: { store.message },
                set: { store.messageBindingChanged(to: $0) }
            )
        ) { message in
            Alert(
                title: Text("操作未完成"),
                message: Text(message.text),
                dismissButton: .default(Text("知道了"))
            )
        }
        .task { store.start() }
    }

    private var rootPersonBinding: Binding<Bool> {
        Binding(
            get: { personModel != nil && store.activeLevel == .root },
            set: { isPresented in
                if !isPresented, store.activeLevel == .root {
                    personBindingChanged(false)
                }
            }
        )
    }

    private var replyDestinationBinding: Binding<CommentReplySheetDestination?> {
        Binding(
            get: { CommentReplySheetDestination(level: store.activeLevel) },
            set: { destination in
                if destination == nil { closeReplies() }
            }
        )
    }

    private func closeReplies() {
        personBindingChanged(false)
        store.dismissReplies()
    }
}

private struct CommentReplySheetDestination: Identifiable {
    let level: CommentLevelKey

    init?(level: CommentLevelKey) {
        guard case let .replies(rootCommentID) = level else { return nil }
        self.level = level
        id = rootCommentID
    }

    let id: String
}

@available(iOS 16.0, *)
private struct CommentReplySheetView: View {
    @ObservedObject var store: CommentSessionStore
    let level: CommentLevelKey
    let personModel: PersonHostModel?
    let personBindingChanged: (Bool) -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeHapticFeedback) private var hapticFeedback

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                CommentLevelView(store: store, level: level, close: close)
                    .navigationDestination(isPresented: personBinding) {
                        if let personModel { PersonNativeView(model: personModel) }
                    }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(edgeDismissGesture(containerWidth: geometry.size.width))
        }
        .modifier(CommentMediaGalleryPresentationModifier(store: store, level: level))
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .modifier(CommentSheetPresentationModifier())
        .accessibilityIdentifier("comment_reply_sheet")
    }

    private var personBinding: Binding<Bool> {
        Binding(
            get: { personModel != nil && store.activeLevel == level },
            set: { isPresented in
                if !isPresented, store.activeLevel == level {
                    personBindingChanged(false)
                }
            }
        )
    }

    private func edgeDismissGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: CommentReplySheetSwipePolicy.minimumDistance)
            .onEnded { value in
                guard CommentReplySheetSwipePolicy.shouldDismiss(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    containerWidth: containerWidth
                ) else { return }
                CommentReplySheetFeedback(action: hapticFeedback).edgeDismissDidCommit(true)
                var transaction = Transaction()
                transaction.disablesAnimations = reduceMotion
                withTransaction(transaction, close)
            }
    }
}

private struct CommentMediaGalleryPresentationModifier: ViewModifier {
    @ObservedObject var store: CommentSessionStore
    let level: CommentLevelKey

    func body(content: Content) -> some View {
        content.fullScreenCover(
            item: Binding(
                get: { store.galleryDestination(for: level) },
                set: { store.galleryBindingChanged(to: $0, for: level) }
            )
        ) { destination in
            NativeMediaGallery(
                urls: destination.urls,
                initialIndex: destination.initialIndex,
                accessibilityPrefix: "comment_media"
            )
        }
    }
}

@MainActor
struct CommentReplySheetFeedback {
    let action: NativeHapticFeedbackAction

    func edgeDismissDidCommit(_ committed: Bool) {
        guard committed else { return }
        action(.dismiss)
    }
}

struct CommentReplySheetSwipePolicy {
    static let minimumDistance: CGFloat = 14
    static let leadingEdgeWidth: CGFloat = 44
    static let horizontalIntentRatio: CGFloat = 1.25
    static let minimumCommitDistance: CGFloat = 72
    static let commitWidthRatio: CGFloat = 0.22

    static func shouldDismiss(
        startLocation: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        containerWidth: CGFloat
    ) -> Bool {
        guard containerWidth > 0,
              startLocation.x <= leadingEdgeWidth,
              translation.width > 0,
              translation.width > abs(translation.height) * horizontalIntentRatio
        else { return false }

        let threshold = max(minimumCommitDistance, containerWidth * commitWidthRatio)
        return translation.width >= threshold || predictedEndTranslation.width >= threshold
    }
}

private struct CommentSheetPresentationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.clear)
        } else if #available(iOS 16, *) {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}

@available(iOS 16.0, *)
private struct CommentLevelView: View {
    @ObservedObject var store: CommentSessionStore
    let level: CommentLevelKey
    let close: (() -> Void)?
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var scrollView: UIScrollView?
    @State private var posterDocument: NativeContentPosterDocument?

    var body: some View {
        List {
            if level == .root {
                sortControl
                    .listRowSeparator(.hidden)
            }
            pageContent
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemBackground))
        .coordinateSpace(name: coordinateSpaceName)
        .background(CommentScrollViewAccessor { scrollView = $0 })
        .onPreferenceChange(CommentRowOffsetPreference.self) { updateAnchor($0) }
        .onChange(of: store.scrollToStartLevel) { target in
            guard target == level else { return }
            DispatchQueue.main.async {
                guard let scrollView else { return }
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                    animated: true
                )
                store.consumeScrollToStart(for: level)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CommentComposerBar(store: store, level: level)
        }
        .navigationTitle(level == .root ? "评论" : "回复")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let close {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(level == .root ? "关闭评论" : "关闭回复")
                    .accessibilityIdentifier(level == .root ? "comment_close" : "comment_reply_close")
                }
            }
        }
        .accessibilityIdentifier(level == .root ? "comment_root" : "comment_direct_replies")
        .sheet(item: $posterDocument) { document in
            NativeContentPosterShareView(document: document)
        }
    }

    private var coordinateSpaceName: String {
        switch level {
        case .root: return "comment-list-root"
        case let .replies(rootCommentID): return "comment-list-replies-\(rootCommentID)"
        }
    }

    private var sortControl: some View {
        Picker("评论排序", selection: Binding(
            get: { store.rootSort },
            set: store.changeSort
        )) {
            ForEach(CommentSortDTO.allCases) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("comment_sort")
    }

    @ViewBuilder
    private var pageContent: some View {
        let page = store.pages[level] ?? store.activePage
        switch page.initialLoad {
        case .idle where page.items.isEmpty, .loading where page.items.isEmpty:
            HStack { Spacer(); ProgressView("正在加载评论"); Spacer() }
                .listRowSeparator(.hidden)
        case let .failed(message) where page.items.isEmpty:
            CommentUnavailableView(
                title: "评论加载失败",
                message: message,
                actionTitle: "重试"
            ) { store.retryInitial(level: level) }
            .listRowSeparator(.hidden)
        case .loaded where page.items.isEmpty:
            CommentUnavailableView(
                title: level == .root ? "暂无评论" : "暂无回复",
                message: level == .root ? "成为第一个发表评论的人" : "这条评论还没有回复",
                actionTitle: nil,
                action: nil
            )
            .listRowSeparator(.hidden)
        default:
            ForEach(page.items) { comment in
                CommentRow(
                    store: store,
                    comment: comment,
                    interactionLevel: level,
                    onShare: { presentSharePoster(for: comment) }
                )
                    .id(comment.id)
                    .background(CommentRowOffsetReader(commentID: comment.id, coordinateSpaceName: coordinateSpaceName))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            store.beginReply(to: comment.id, level: level)
                        } label: {
                            Label("回复", systemImage: "arrowshape.turn.up.left.fill")
                        }
                        .tint(Color.accentColor)
                        .accessibilityLabel("回复 @\(comment.author.displayName)")
                        .accessibilityIdentifier("comment_swipe_reply_\(comment.id)")

                        Button {
                            presentSharePoster(for: comment)
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .tint(.indigo)
                        .accessibilityLabel("分享 \(comment.author.displayName) 的评论")
                        .accessibilityIdentifier("comment_swipe_share_\(comment.id)")
                    }
                    .onAppear { store.loadNextIfNeeded(after: comment.id, level: level) }
            }
            pageFooter(page)
        }
    }

    private func presentSharePoster(for comment: CommentDTO) {
        hapticFeedback(.commit)
        let context = store.route.shareContext ?? store.route.subject.fallbackShareContext
        var blocks: [NativeContentPosterBlock] = []
        if let excerpt = context.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !excerpt.isEmpty {
            blocks.append(.text("正文摘要：\(excerpt)", style: .caption))
            blocks.append(.divider)
        }

        let commentText = CommentPlainText.value(from: comment.contentHTML)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !commentText.isEmpty {
            blocks.append(.text(commentText, style: .body))
        }
        blocks.append(contentsOf: comment.media.map {
            .image($0.url, caption: $0.kind == .sticker ? "表情" : nil)
        })

        let replyContext = comment.replyToAuthor.map { "回复 @\($0.displayName)" } ?? ""
        posterDocument = NativeContentPosterDocument(
            title: context.title,
            authorName: comment.author.displayName,
            authorHeadline: replyContext,
            authorAvatarURL: comment.author.avatarURL,
            sourceURL: context.sourceURL,
            metadata: "\(CommentDateFormatter.string(seconds: comment.createdTimeSeconds)) · \(comment.likeCount) 赞",
            blocks: blocks
        )
    }

    @ViewBuilder
    private func pageFooter(_ page: CommentPageState) -> some View {
        switch page.nextPage {
        case .loading:
            HStack { Spacer(); ProgressView("正在加载更多"); Spacer() }
                .font(.caption)
                .listRowSeparator(.hidden)
        case let .failed(message):
            CommentUnavailableView(title: "未能加载更多", message: message, actionTitle: "重试") {
                store.retryNext(level: level)
            }
            .listRowSeparator(.hidden)
        case .idle where page.isEnd && !page.items.isEmpty:
            Text(level == .root ? "已显示全部评论" : "已显示全部回复")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        default:
            EmptyView()
        }
    }

    private func updateAnchor(_ offsets: [String: CGFloat]) {
        guard !offsets.isEmpty else { return }
        let first = offsets.filter { $0.value >= 0 }.min(by: { $0.value < $1.value })
            ?? offsets.max(by: { $0.value < $1.value })
        guard let first else { return }
        store.updateAnchor(
            CommentScrollAnchor(commentID: first.key, offsetFromViewportTopPoints: first.value),
            for: level
        )
    }

}

private struct CommentRow: View {
    @ObservedObject var store: CommentSessionStore
    let comment: CommentDTO
    let interactionLevel: CommentLevelKey?
    let onShare: () -> Void

    init(
        store: CommentSessionStore,
        comment: CommentDTO,
        interactionLevel: CommentLevelKey? = nil,
        onShare: @escaping () -> Void = {}
    ) {
        self.store = store
        self.comment = comment
        self.interactionLevel = interactionLevel
        self.onShare = onShare
    }

    var body: some View {
        rowContent
            .contextMenu {
                Button(action: beginReply) {
                    Label("回复 @\(comment.author.displayName)", systemImage: "arrowshape.turn.up.left")
                }
                Button {
                    UIPasteboard.general.string = CommentPlainText.value(from: comment.contentHTML)
                } label: {
                    Label("复制评论", systemImage: "doc.on.doc")
                }
                Button(action: onShare) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("comment_context_share_\(comment.id)")
            }
            .accessibilityIdentifier("comment_row_\(comment.id)")
            .accessibilityHint("长按或左滑可回复、复制或分享")
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button { store.openAuthor(commentID: comment.id) } label: {
                    AsyncImage(url: comment.author.avatarURL) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开 \(comment.author.displayName) 的主页")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Button(comment.author.displayName) { store.openAuthor(commentID: comment.id) }
                            .buttonStyle(.plain)
                            .font(.headline)
                        if let reply = comment.replyToAuthor {
                            Text("回复").foregroundStyle(.secondary)
                            Button(reply.displayName) {
                                store.openAuthor(commentID: comment.id, replyToAuthor: true)
                            }
                            .buttonStyle(.plain)
                            .font(.headline)
                        }
                    }
                    Text(CommentDateFormatter.string(seconds: comment.createdTimeSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            CommentRichText(html: comment.contentHTML)
                .contentShape(Rectangle())

            if !comment.media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(comment.media) { media in
                            Button {
                                store.openMedia(
                                    commentID: comment.id,
                                    mediaID: media.id,
                                    level: interactionLevel
                                )
                            } label: {
                                Group {
                                    if media.kind == .animatedImage ||
                                        NativeRemoteMediaPolicy.isAnimatedImage(media.url) {
                                        NativeAnimatedRemoteImage(url: media.url, contentMode: .fill)
                                    } else {
                                        AsyncImage(url: media.url) { phase in
                                            if case let .success(image) = phase {
                                                image.resizable().scaledToFill()
                                            } else {
                                                ZStack {
                                                    Color.secondary.opacity(0.12)
                                                    ProgressView()
                                                }
                                            }
                                        }
                                    }
                                }
                                .frame(width: 120, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看评论图片")
                        }
                    }
                }
            }

            HStack(spacing: 18) {
                Button {
                    store.toggleLike(commentID: comment.id, level: interactionLevel)
                } label: {
                    Label("\(comment.likeCount)", systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .disabled(store.pages[interactionLevel ?? store.activeLevel]?.activeLikeMutation != nil)

                Spacer(minLength: 12)

                if interactionLevel == .root, comment.childCommentCount > 0 {
                    Button {
                        store.openReplies(rootCommentID: comment.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text("共 \(comment.childCommentCount) 条回复")
                            Image(systemName: "chevron.right")
                        }
                    }
                    .fontWeight(.medium)
                    .accessibilityIdentifier("reply_count_open_\(comment.id)")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.tint)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func beginReply() {
        store.beginReply(to: comment.id, level: interactionLevel)
    }
}

private struct CommentComposerBar: View {
    @ObservedObject var store: CommentSessionStore
    let level: CommentLevelKey
    @State private var showsEmojiPicker = false
    @State private var showsPhotoPicker = false
    @State private var photoError: String?
    @FocusState private var isDraftFocused: Bool

    var body: some View {
        Group {
            if store.composerPresentation.isActive(for: level) {
                activeComposer
            } else {
                collapsedComposer
            }
        }
        .background(CommentComposerBackground())
        .onChange(of: store.composerPresentation) { presentation in
            isDraftFocused = presentation.isActive(for: level)
        }
        .onAppear {
            isDraftFocused = store.composerPresentation.isActive(for: level)
        }
        .onDisappear { isDraftFocused = false }
        .sheet(isPresented: $showsEmojiPicker) {
            CommentEmojiPicker { emoji in
                store.appendEmoji(emoji.placeholder)
                showsEmojiPicker = false
            }
        }
        .sheet(isPresented: $showsPhotoPicker) {
            CommentPhotoPicker(isPresented: $showsPhotoPicker) { result in
                switch result {
                case let .success(data): store.setDraftImage(data)
                case let .failure(error): photoError = error.localizedDescription
                }
            }
        }
        .alert("无法选择图片", isPresented: Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )) {
            Button("知道了", role: .cancel) { photoError = nil }
        } message: {
            Text(photoError ?? "请稍后重试")
        }
    }

    private var collapsedComposer: some View {
        Button {
            store.beginComment(level: level)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
                Text(level == .root ? "写评论…" : "回复这条评论…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("comment_composer_open")
    }

    private var activeComposer: some View {
        VStack(spacing: 6) {
            if let target = store.activeReplyTargetName {
                HStack {
                    Text("回复 \(target)").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { dismissComposer() }
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            if let imageData = store.draft.imageData, let image = UIImage(data: imageData) {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("待发送图片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("移除", role: .destructive) { store.setDraftImage(nil) }
                        .font(.caption)
                }
                .padding(.horizontal, 12)
            }
            HStack(alignment: .center, spacing: 6) {
                Button { showsEmojiPicker = true } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("选择表情")
                .accessibilityIdentifier("comment_emoji_picker")

                Button { showsPhotoPicker = true } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("选择图片")
                .accessibilityIdentifier("comment_photo_picker")

                CommentDraftField(store: store, isFocused: $isDraftFocused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    if case .failed = store.draft.submissionState {
                        store.retrySubmission()
                    } else {
                        store.submitDraft()
                    }
                } label: {
                    if case .submitting = store.draft.submissionState {
                        ProgressView().frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 25, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                .disabled(
                    (store.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        store.draft.imageData == nil) ||
                        store.draft.submissionState.isSubmitting
                )
                .accessibilityLabel("发送评论")
                .accessibilityIdentifier("comment_submit")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func dismissComposer() {
        isDraftFocused = false
        store.dismissComposer(for: level)
    }
}

private struct CommentEmojiPicker: View {
    let onSelect: (CommentEmoji) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(CommentEmojiCatalog.entries) { emoji in
                        Button { onSelect(emoji) } label: {
                            VStack(spacing: 3) {
                                Text(emoji.symbol).font(.title2)
                                Text(emoji.placeholder.dropFirst().dropLast())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("插入\(emoji.placeholder)")
                    }
                }
                .padding(16)
            }
            .navigationTitle("选择表情")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .modifier(CommentEmojiPresentationModifier())
    }
}

private struct CommentEmojiPresentationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content
                .presentationDetents([.height(340), .medium])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}

private struct CommentPhotoPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let completion: (Result<Data, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: CommentPhotoPicker

        init(parent: CommentPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false
            guard let provider = results.first?.itemProvider else { return }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                DispatchQueue.main.async {
                    if let data {
                        self.parent.completion(.success(data))
                    } else {
                        self.parent.completion(.failure(error ?? CommentPhotoPickerError.unreadableImage))
                    }
                }
            }
        }
    }
}

private enum CommentPhotoPickerError: LocalizedError {
    case unreadableImage

    var errorDescription: String? { "无法读取所选图片" }
}

private struct CommentComposerBackground: View {
    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                Divider()
            }
    }
}

private struct CommentRichText: View {
    let html: String
    @Environment(\.nativeContentPresentation) private var contentPresentation
    @ScaledMetric(relativeTo: .body) private var bodyPointSize: CGFloat = 17

    var body: some View {
        let pointSize = bodyPointSize * contentPresentation.fontScale
        let bodyFont = Font.system(size: pointSize)
        Text(CommentAttributedText.value(from: html, bodyFont: bodyFont))
            .font(bodyFont)
            .lineSpacing(contentPresentation.extraLineSpacing(for: pointSize))
            .environment(\.openURL, OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                    return .discarded
                }
                guard !CommentAttributedText.isKnownInternalZhihuURL(url) else { return .discarded }
                return .systemAction(url)
            })
    }
}

private enum CommentAttributedText {
    static func value(from html: String, bodyFont: Font) -> AttributedString {
        let source = CommentHTMLMediaParser.project(html).textHTML
        var result = AttributedString()
        for block in QARichContentParser.blocks(from: source) {
            if !result.characters.isEmpty { result.append(AttributedString("\n")) }
            switch block {
            case let .paragraph(_, runs), let .heading(_, _, runs), let .quote(_, runs), let .segment(_, _, runs):
                append(runs, bodyFont: bodyFont, to: &result)
            case let .list(_, kind, items):
                append(
                    list: QAListGroup(kind: kind, items: items),
                    depth: 0,
                    bodyFont: bodyFont,
                    to: &result
                )
            case let .code(_, _, text), let .formula(_, text):
                var code = AttributedString(text)
                code.font = bodyFont.monospaced()
                result.append(code)
            case .image, .video, .divider:
                break
            }
        }
        return result.characters.isEmpty
            ? AttributedString(CommentEmojiCatalog.renderedText(QARichContentParser.plainText(source)))
            : result
    }

    private static func append(_ runs: [QAInlineRun], bodyFont: Font, to result: inout AttributedString) {
        for run in runs {
            var part = AttributedString(CommentEmojiCatalog.renderedText(run.text))
            var presentation: InlinePresentationIntent = []
            if run.style.contains(.strong) { presentation.insert(.stronglyEmphasized) }
            if run.style.contains(.emphasis) { presentation.insert(.emphasized) }
            if !presentation.isEmpty { part.inlinePresentationIntent = presentation }
            if run.style.contains(.strikethrough) { part.strikethroughStyle = .single }
            if run.style.contains(.code) { part.font = bodyFont.monospaced() }
            if let destination = run.link,
               let url = QABodyLinkResolver.url(destination),
               !isKnownInternalZhihuURL(url) {
                part.link = url
            }
            result.append(part)
        }
    }

    private static func append(
        list: QAListGroup,
        depth: Int,
        bodyFont: Font,
        to result: inout AttributedString
    ) {
        for (index, item) in list.items.enumerated() {
            if !result.characters.isEmpty { result.append(AttributedString("\n")) }
            let number = item.ordinal ?? list.startIndex + index
            let marker = list.kind == .ordered ? "\(number). " : "• "
            result.append(AttributedString(String(repeating: "  ", count: depth) + marker))
            append(item.runs, bodyFont: bodyFont, to: &result)
            for nestedList in item.nestedLists {
                append(list: nestedList, depth: depth + 1, bodyFont: bodyFont, to: &result)
            }
        }
    }

    static func isKnownInternalZhihuURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "zhihu.com" || host.hasSuffix(".zhihu.com")
    }
}

private struct CommentDraftField: View {
    @ObservedObject var store: CommentSessionStore
    let isFocused: FocusState<Bool>.Binding

    @ViewBuilder
    var body: some View {
        if #available(iOS 16, *) {
            TextField("发表评论", text: draftBinding, axis: .vertical)
                .lineLimit(1...5)
                .focused(isFocused)
        } else {
            TextField("发表评论", text: draftBinding)
                .focused(isFocused)
        }
    }

    private var draftBinding: Binding<String> {
        Binding(get: { store.draft.text }, set: store.setDraftText)
    }
}

private enum CommentPlainText {
    static func value(from html: String) -> String {
        CommentEmojiCatalog.renderedText(QARichContentParser.plainText(html))
    }
}

private extension CommentSubmissionState {
    var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }
}

private enum CommentDateFormatter {
    static func string(seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

private extension CommentSubjectDTO {
    var fallbackShareContext: CommentShareContextDTO {
        switch self {
        case let .answer(id):
            return CommentShareContextDTO(
                title: "回答 #\(id)",
                excerpt: nil,
                sourceURL: URL(string: "https://www.zhihu.com/answer/\(id)")!
            )
        case let .article(id):
            return CommentShareContextDTO(
                title: "文章 #\(id)",
                excerpt: nil,
                sourceURL: URL(string: "https://zhuanlan.zhihu.com/p/\(id)")!
            )
        case let .question(id):
            return CommentShareContextDTO(
                title: "问题 #\(id)",
                excerpt: nil,
                sourceURL: URL(string: "https://www.zhihu.com/question/\(id)")!
            )
        case let .pin(id):
            return CommentShareContextDTO(
                title: "想法 #\(id)",
                excerpt: nil,
                sourceURL: URL(string: "https://www.zhihu.com/pin/\(id)")!
            )
        case let .segment(contentID, contentTypeRaw, _):
            let title: String
            let sourceURL: URL
            switch contentTypeRaw {
            case "answer":
                title = "回答 #\(contentID)"
                sourceURL = URL(string: "https://www.zhihu.com/answer/\(contentID)")!
            case "article":
                title = "文章 #\(contentID)"
                sourceURL = URL(string: "https://zhuanlan.zhihu.com/p/\(contentID)")!
            case "question":
                title = "问题 #\(contentID)"
                sourceURL = URL(string: "https://www.zhihu.com/question/\(contentID)")!
            case "pin":
                title = "想法 #\(contentID)"
                sourceURL = URL(string: "https://www.zhihu.com/pin/\(contentID)")!
            default:
                title = "知乎内容"
                sourceURL = URL(string: "https://www.zhihu.com")!
            }
            return CommentShareContextDTO(title: title, excerpt: nil, sourceURL: sourceURL)
        }
    }
}

private struct CommentUnavailableView: View {
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right").font(.largeTitle)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct CommentScrollViewAccessor: UIViewRepresentable {
    let resolve: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.resolve = resolve
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.resolve = resolve
        uiView.findScrollView()
    }

    final class ProbeView: UIView {
        var resolve: ((UIScrollView?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            findScrollView()
        }

        func findScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var candidate = superview
                while let view = candidate {
                    if let scrollView = view as? UIScrollView {
                        resolve?(scrollView)
                        return
                    }
                    candidate = view.superview
                }
                resolve?(nil)
            }
        }
    }
}

private struct CommentRowOffsetPreference: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct CommentRowOffsetReader: View {
    let commentID: String
    let coordinateSpaceName: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: CommentRowOffsetPreference.self,
                value: [commentID: geometry.frame(in: .named(coordinateSpaceName)).minY]
            )
        }
    }
}
