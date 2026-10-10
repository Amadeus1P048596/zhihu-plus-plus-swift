import ImageIO
import Photos
import SwiftUI
import UIKit

struct NativeMediaGallery: View {
    let urls: [URL]
    let initialIndex: Int
    let accessibilityPrefix: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedIndex: Int
    @StateObject private var imageStore = NativeMediaImageStore()
    @State private var isCurrentImageZoomed = false
    @State private var pageDragOffset: CGFloat = 0
    @State private var dismissOffset: CGFloat = 0
    @State private var shareItems: NativeMediaActivityItems?
    @State private var message: NativeMediaMessage?
    @State private var isSaving = false

    init(urls: [URL], initialIndex: Int, accessibilityPrefix: String = "media_gallery") {
        self.urls = urls
        self.initialIndex = min(max(0, initialIndex), max(0, urls.count - 1))
        self.accessibilityPrefix = accessibilityPrefix
        _selectedIndex = State(initialValue: min(max(0, initialIndex), max(0, urls.count - 1)))
    }

    var body: some View {
        GeometryReader { safeGeometry in
            GeometryReader { geometry in
                ZStack {
                    Color.black
                        .opacity(backgroundOpacity(viewportHeight: geometry.size.height))

                    HStack(spacing: 0) {
                        ForEach(urls.indices, id: \.self) { index in
                            NativeZoomableRemoteImage(
                                url: urls[index],
                                store: imageStore,
                                isActive: index == selectedIndex,
                                reduceMotion: reduceMotion,
                                accessibilityIdentifier: "\(accessibilityPrefix)_image_\(index)",
                                onZoomChanged: { isZoomed in
                                    guard index == selectedIndex else { return }
                                    isCurrentImageZoomed = isZoomed
                                    if isZoomed { resetNavigationOffsets(animated: false) }
                                },
                                onDismiss: {
                                    guard index == selectedIndex else { return }
                                    dismiss()
                                },
                                onNavigationChanged: { axis, translation in
                                    guard index == selectedIndex else { return }
                                    navigationChanged(axis, translation: translation, pageWidth: geometry.size.width)
                                },
                                onNavigationEnded: { axis, translation, predictedTranslation in
                                    guard index == selectedIndex else { return }
                                    navigationEnded(
                                        axis,
                                        translation: translation,
                                        predictedTranslation: predictedTranslation,
                                        viewport: geometry.size
                                    )
                                },
                                onNavigationCancelled: {
                                    guard index == selectedIndex else { return }
                                    resetNavigationOffsets(animated: false)
                                }
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                    .offset(
                        x: -CGFloat(selectedIndex) * geometry.size.width + pageDragOffset,
                        y: dismissOffset
                    )

                    if urls.count > 1 {
                        VStack {
                            Spacer()
                            Text("\(selectedIndex + 1) / \(urls.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 54)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .modifier(NativeMediaIndicatorSurface())
                                .padding(.bottom, 18 + safeGeometry.safeAreaInsets.bottom)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .clipped()
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { topControls }
        .preferredColorScheme(.dark)
        .sheet(item: $shareItems) { items in
            NativeMediaActivityView(activityItems: items.values)
        }
        .alert(item: $message) { message in
            Alert(
                title: Text("操作结果"),
                message: Text(message.text),
                dismissButton: .default(Text("知道了"))
            )
        }
        .onChange(of: selectedIndex) { _ in
            isCurrentImageZoomed = false
            resetNavigationOffsets(animated: false)
        }
        .accessibilityIdentifier(accessibilityPrefix)
    }

    @ViewBuilder
    private var topControls: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 10) {
                controls
            }
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            NativeMediaControlButton(
                systemImage: "xmark",
                accessibilityLabel: "关闭图片",
                action: dismiss.callAsFunction
            )
            .accessibilityIdentifier("\(accessibilityPrefix)_close")

            Spacer()

            Menu {
                if let currentImage {
                    Button {
                        shareItems = NativeMediaActivityItems(values: [currentImage])
                    } label: {
                        Label("分享图片文件", systemImage: "square.and.arrow.up")
                    }
                }

                if #available(iOS 16, *), let currentURL {
                    ShareLink(item: currentURL) {
                        Label("分享图片链接", systemImage: "link")
                    }
                }

                Button(action: copyCurrentImage) {
                    Label("复制图片", systemImage: "doc.on.doc")
                }

                Button(action: saveCurrentImage) {
                    Label(isSaving ? "正在保存" : "保存到照片", systemImage: "square.and.arrow.down")
                }
                .disabled(currentImage == nil || isSaving)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .modifier(NativeMediaControlSurface())
            }
            .foregroundStyle(.white)
            .accessibilityLabel("图片操作")
            .accessibilityIdentifier("\(accessibilityPrefix)_actions")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var currentURL: URL? {
        urls.indices.contains(selectedIndex) ? urls[selectedIndex] : nil
    }

    private var currentImage: UIImage? {
        currentURL.flatMap { imageStore.exportImage(for: $0) }
    }

    private func backgroundOpacity(viewportHeight: CGFloat) -> Double {
        let fadeDistance = max(viewportHeight * 0.3, 1)
        return 1 - min(abs(dismissOffset) / fadeDistance, 1) * 0.55
    }

    private func navigationChanged(
        _ axis: NativeMediaNavigationAxis,
        translation: CGSize,
        pageWidth: CGFloat
    ) {
        guard !isCurrentImageZoomed else { return }
        switch axis {
        case .horizontal:
            guard pageWidth > 0 else { return }
            let pastFirst = selectedIndex == 0 && translation.width > 0
            let pastLast = selectedIndex == urls.count - 1 && translation.width < 0
            pageDragOffset = translation.width * (pastFirst || pastLast ? 0.25 : 1)
            dismissOffset = 0
        case .vertical:
            dismissOffset = translation.height
            pageDragOffset = 0
        }
    }

    private func navigationEnded(
        _ axis: NativeMediaNavigationAxis,
        translation: CGSize,
        predictedTranslation: CGSize,
        viewport: CGSize
    ) {
        guard !isCurrentImageZoomed else {
            resetNavigationOffsets()
            return
        }
        switch axis {
        case .horizontal:
            let target = NativeMediaPagingPolicy.targetIndex(
                currentIndex: selectedIndex,
                pageCount: urls.count,
                translationWidth: translation.width,
                predictedEndTranslationWidth: predictedTranslation.width,
                pageWidth: viewport.width
            )
            let previousIndex = selectedIndex
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                selectedIndex = target
                pageDragOffset = 0
                dismissOffset = 0
            }
            NativeMediaGalleryFeedback(action: hapticFeedback).pageDidCommit(
                from: previousIndex,
                to: target
            )
        case .vertical:
            if NativeMediaDismissalPolicy.shouldDismiss(
                translation: translation,
                predictedEndTranslation: predictedTranslation,
                viewportHeight: viewport.height
            ) {
                NativeMediaGalleryFeedback(action: hapticFeedback)
                    .verticalDismissDidCommit(true)
                dismiss()
            } else {
                resetNavigationOffsets()
            }
        }
    }

    private func resetNavigationOffsets(animated: Bool = true) {
        withAnimation(animated && !reduceMotion ? .spring(response: 0.28, dampingFraction: 0.85) : nil) {
            pageDragOffset = 0
            dismissOffset = 0
        }
    }

    private func copyCurrentImage() {
        if let currentImage {
            UIPasteboard.general.image = currentImage
            message = NativeMediaMessage(text: "已复制图片")
        } else if let currentURL {
            UIPasteboard.general.url = currentURL
            message = NativeMediaMessage(text: "图片尚未加载完成，已复制图片链接")
        } else {
            message = NativeMediaMessage(text: "当前图片不可用")
        }
    }

    private func saveCurrentImage() {
        guard let currentImage, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await NativePhotoLibrary.save(currentImage)
                message = NativeMediaMessage(text: "已保存到照片")
            } catch {
                message = NativeMediaMessage(text: "无法保存图片，请检查照片权限后重试")
            }
        }
    }
}

private struct NativeMediaControlButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .modifier(NativeMediaControlSurface())
        }
        .foregroundStyle(.white)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct NativeMediaControlSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

private struct NativeMediaIndicatorSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

private enum NativeMediaNavigationAxis {
    case horizontal
    case vertical

    func translation(_ point: CGPoint) -> CGSize {
        switch self {
        case .horizontal: return CGSize(width: point.x, height: 0)
        case .vertical: return CGSize(width: 0, height: point.y)
        }
    }
}

private struct NativeZoomableRemoteImage: View {
    let url: URL
    @ObservedObject var store: NativeMediaImageStore
    let isActive: Bool
    let reduceMotion: Bool
    let accessibilityIdentifier: String
    let onZoomChanged: (Bool) -> Void
    let onDismiss: () -> Void
    let onNavigationChanged: (NativeMediaNavigationAxis, CGSize) -> Void
    let onNavigationEnded: (NativeMediaNavigationAxis, CGSize, CGSize) -> Void
    let onNavigationCancelled: () -> Void

    var body: some View {
        ZStack {
            NativeMediaZoomSurface(
                image: store.image(for: url),
                url: url,
                didFail: store.didFail(url),
                isActive: isActive,
                reduceMotion: reduceMotion,
                accessibilityIdentifier: accessibilityIdentifier,
                onZoomChanged: onZoomChanged,
                onDismiss: onDismiss,
                onNavigationChanged: onNavigationChanged,
                onNavigationEnded: onNavigationEnded,
                onNavigationCancelled: onNavigationCancelled
            )

            if store.image(for: url) == nil {
                if store.didFail(url) {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        Text("图片加载失败")
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        Button("重试") { Task { await store.load(url) } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("\(accessibilityIdentifier)_retry")
                    }
                    .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .tint(.white)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(!isActive)
        .task(id: url) { await store.load(url) }
    }
}

private struct NativeMediaZoomSurface: UIViewRepresentable {
    let image: UIImage?
    let url: URL
    let didFail: Bool
    let isActive: Bool
    let reduceMotion: Bool
    let accessibilityIdentifier: String
    let onZoomChanged: (Bool) -> Void
    let onDismiss: () -> Void
    let onNavigationChanged: (NativeMediaNavigationAxis, CGSize) -> Void
    let onNavigationEnded: (NativeMediaNavigationAxis, CGSize, CGSize) -> Void
    let onNavigationCancelled: () -> Void

    func makeUIView(context: Context) -> NativeMediaZoomScrollView {
        NativeMediaZoomScrollView(frame: .zero)
    }

    func updateUIView(_ uiView: NativeMediaZoomScrollView, context: Context) {
        uiView.configure(with: self)
    }

    static func dismantleUIView(_ uiView: NativeMediaZoomScrollView, coordinator: ()) {
        uiView.tearDown()
    }
}

@MainActor
private final class NativeMediaZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var configuration: NativeMediaZoomSurface?
    private var viewportSize: CGSize = .zero
    private var hasDeferredViewportResize = false
    private var needsFitReset = false
    private var isLayingOutImage = false
    private var isProgrammaticZoom = false
    private var navigationAxis: NativeMediaNavigationAxis?
    private var navigationRevision = 0
    private var reportedZoomed = false
    private var zoomReportRevision = 0
    private lazy var navigationPan = UIPanGestureRecognizer(target: self, action: #selector(handleNavigation(_:)))
    private lazy var singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
    private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    private lazy var galleryGestureDelegate = GalleryGestureDelegate(owner: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        delegate = self
        backgroundColor = .clear
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        navigationPan.minimumNumberOfTouches = 1
        navigationPan.maximumNumberOfTouches = 1
        navigationPan.delegate = galleryGestureDelegate
        addGestureRecognizer(navigationPan)
        pinchGestureRecognizer?.addTarget(self, action: #selector(handleGalleryPinch(_:)))

        doubleTap.numberOfTapsRequired = 2
        singleTap.delegate = galleryGestureDelegate
        doubleTap.delegate = galleryGestureDelegate
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
        singleTap.require(toFail: doubleTap)
        for tap in [singleTap, doubleTap] {
            tap.require(toFail: navigationPan)
            tap.require(toFail: panGestureRecognizer)
            if let pinchGestureRecognizer { tap.require(toFail: pinchGestureRecognizer) }
        }
        isAccessibilityElement = true
    }

    func configure(with configuration: NativeMediaZoomSurface) {
        let previous = self.configuration
        let imageChanged = imageView.image !== configuration.image
        let identityChanged = previous?.url != configuration.url
        let becameInactive = previous?.isActive == true && !configuration.isActive
        self.configuration = configuration
        isUserInteractionEnabled = configuration.isActive
        isScrollEnabled = configuration.isActive && configuration.image != nil
        accessibilityElementsHidden = !configuration.isActive
        accessibilityIdentifier = configuration.accessibilityIdentifier

        if identityChanged || becameInactive {
            isProgrammaticZoom = false
            cancelNavigation(deferCallback: true)
        }
        if imageChanged {
            imageView.stopAnimating()
            imageView.image = configuration.image
        }
        if imageChanged || identityChanged || becameInactive {
            needsFitReset = true
            setNeedsLayout()
        }
        if configuration.isActive {
            if imageChanged || previous?.isActive != true { imageView.startAnimating() }
        } else {
            imageView.stopAnimating()
        }
        if imageChanged || previous?.didFail != configuration.didFail || previous?.isActive != configuration.isActive {
            updateAccessibility()
        }
    }

    func tearDown() {
        configuration = nil
        navigationPan.isEnabled = false
        imageView.stopAnimating()
        delegate = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, configuration?.isActive == true {
            imageView.startAnimating()
        } else {
            imageView.stopAnimating()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isLayingOutImage, bounds.width > 0, bounds.height > 0,
              needsFitReset || viewportSize != bounds.size || hasDeferredViewportResize
        else { return }
        guard !isZooming, !isPinching, !isProgrammaticZoom else {
            if viewportSize != bounds.size { hasDeferredViewportResize = true }
            return
        }
        isLayingOutImage = true
        defer { isLayingOutImage = false }

        // Native zooming may have continued in the resized bounds while layout was deferred.
        let anchorViewportSize = hasDeferredViewportResize ? bounds.size : viewportSize
        let oldImageSize = imageView.bounds.size
        let oldVisibleCenter = CGPoint(
            x: contentOffset.x + anchorViewportSize.width / 2,
            y: contentOffset.y + anchorViewportSize.height / 2
        )
        let oldImageCenter = imageView.convert(oldVisibleCenter, from: self)
        let normalizedCenter = CGPoint(
            x: oldImageSize.width > 0 ? oldImageCenter.x / oldImageSize.width : 0.5,
            y: oldImageSize.height > 0 ? oldImageCenter.y / oldImageSize.height : 0.5
        )
        let resetToFit = needsFitReset
        needsFitReset = false
        if resetToFit {
            isProgrammaticZoom = false
            if zoomScale != minimumZoomScale { setZoomScale(minimumZoomScale, animated: false) }
        }
        viewportSize = bounds.size
        hasDeferredViewportResize = false
        let imageSize = imageView.image?.size ?? .zero
        let fitScale = imageSize.width > 0 && imageSize.height > 0
            ? min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
            : 0
        let baseSize = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
        imageView.bounds = CGRect(origin: .zero, size: baseSize)
        let scaledSize = CGSize(width: baseSize.width * zoomScale, height: baseSize.height * zoomScale)
        imageView.center = CGPoint(x: scaledSize.width / 2, y: scaledSize.height / 2)
        contentSize = scaledSize
        centerContent()
        let center = resetToFit ? CGPoint(x: 0.5, y: 0.5) : normalizedCenter
        let offset = CGPoint(
            x: center.x * scaledSize.width - viewportSize.width / 2,
            y: center.y * scaledSize.height - viewportSize.height / 2
        )
        setContentOffset(boundedOffset(offset), animated: false)
        reportZoomState()
    }

    private var isPinching: Bool {
        pinchGestureRecognizer?.state == .began || pinchGestureRecognizer?.state == .changed
    }

    private var canNavigate: Bool {
        configuration?.isActive == true &&
            zoomScale <= minimumZoomScale + 0.001 &&
            !isZooming && !isPinching && !isDecelerating && !isProgrammaticZoom
    }

    private func centerContent() {
        let size = CGSize(
            width: imageView.bounds.width * zoomScale,
            height: imageView.bounds.height * zoomScale
        )
        let horizontal = max((bounds.width - size.width) / 2, 0)
        let vertical = max((bounds.height - size.height) / 2, 0)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != insets { contentInset = insets }
    }

    private func boundedOffset(_ offset: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(offset.x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
            y: min(max(offset.y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom))
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView.image == nil ? nil : imageView
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        cancelNavigation()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isLayingOutImage else { return }
        centerContent()
        reportZoomState()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isProgrammaticZoom = false
        centerContent()
        reportZoomState()
        setNeedsLayout()
    }

    private func reportZoomState() {
        let isZoomed = configuration?.isActive == true && imageView.image != nil && zoomScale > minimumZoomScale + 0.001
        guard isZoomed != reportedZoomed else { return }
        reportedZoomed = isZoomed
        zoomReportRevision += 1
        let revision = zoomReportRevision
        updateAccessibility()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.zoomReportRevision == revision,
                  let configuration = self.configuration, configuration.isActive
            else { return }
            configuration.onZoomChanged(isZoomed)
        }
    }

    private func shouldBeginGalleryGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard configuration?.isActive == true else { return false }
        if gestureRecognizer === doubleTap {
            return imageView.image != nil
        }
        if gestureRecognizer === singleTap { return true }
        guard gestureRecognizer === navigationPan else { return false }
        guard canNavigate, navigationPan.numberOfTouches == 1 else { return false }
        let translation = navigationPan.translation(in: window)
        let size = CGSize(width: translation.x, height: translation.y)
        if NativeMediaDismissalPolicy.isVertical(size) {
            navigationAxis = .vertical
        } else if abs(translation.x) > abs(translation.y) {
            navigationAxis = .horizontal
        } else {
            return false
        }
        navigationRevision += 1
        return true
    }

    // Keep UIKit's pan/pinch arbitration on UIScrollView untouched.
    @MainActor
    private final class GalleryGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        private weak var owner: NativeMediaZoomScrollView?

        init(owner: NativeMediaZoomScrollView) {
            self.owner = owner
            super.init()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            owner?.shouldBeginGalleryGesture(gestureRecognizer) ?? false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let owner else { return false }
            if gestureRecognizer === owner.navigationPan {
                return otherGestureRecognizer === owner.panGestureRecognizer ||
                    otherGestureRecognizer === owner.pinchGestureRecognizer
            }
            if otherGestureRecognizer === owner.navigationPan {
                return gestureRecognizer === owner.panGestureRecognizer ||
                    gestureRecognizer === owner.pinchGestureRecognizer
            }
            return false
        }
    }

    @objc private func handleNavigation(_ recognizer: UIPanGestureRecognizer) {
        guard let axis = navigationAxis else { return }
        switch recognizer.state {
        case .began, .changed:
            guard canNavigate, recognizer.numberOfTouches == 1 else {
                cancelNavigation()
                return
            }
            configuration?.onNavigationChanged(axis, axis.translation(recognizer.translation(in: window)))
        case .ended:
            navigationAxis = nil
            guard canNavigate, recognizer.numberOfTouches <= 1 else {
                configuration?.onNavigationCancelled()
                return
            }
            let translation = recognizer.translation(in: window)
            let velocity = recognizer.velocity(in: window)
            let rate = UIScrollView.DecelerationRate.normal.rawValue
            let projection = rate / (1 - rate) / 1_000
            let predicted = CGPoint(
                x: translation.x + velocity.x * projection,
                y: translation.y + velocity.y * projection
            )
            configuration?.onNavigationEnded(axis, axis.translation(translation), axis.translation(predicted))
        case .cancelled, .failed:
            navigationAxis = nil
            configuration?.onNavigationCancelled()
        default:
            break
        }
    }

    private func cancelNavigation(deferCallback: Bool = false) {
        guard navigationAxis != nil else { return }
        navigationAxis = nil
        navigationRevision += 1
        let revision = navigationRevision
        navigationPan.isEnabled = false
        navigationPan.isEnabled = true
        if deferCallback {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.navigationRevision == revision,
                      let configuration = self.configuration, configuration.isActive
                else { return }
                configuration.onNavigationCancelled()
            }
        } else {
            configuration?.onNavigationCancelled()
        }
    }

    // UIScrollView owns handlePinch:; do not shadow its native zoom handler.
    @objc private func handleGalleryPinch(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began {
            isProgrammaticZoom = false
            cancelNavigation()
        } else if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            setNeedsLayout()
        }
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, configuration?.isActive == true else { return }
        configuration?.onDismiss()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        toggleZoom(at: recognizer.location(in: imageView))
    }

    private func toggleZoom(at point: CGPoint) {
        guard configuration?.isActive == true, imageView.image != nil, !isPinching else { return }
        cancelNavigation()
        let animated = configuration?.reduceMotion == false && !UIAccessibility.isReduceMotionEnabled
        isProgrammaticZoom = animated
        if zoomScale > minimumZoomScale + 0.001 {
            setZoomScale(minimumZoomScale, animated: animated)
        } else {
            let targetScale: CGFloat = 2.5
            let center = CGPoint(
                x: min(max(point.x, 0), imageView.bounds.width),
                y: min(max(point.y, 0), imageView.bounds.height)
            )
            let size = CGSize(width: bounds.width / targetScale, height: bounds.height / targetScale)
            zoom(to: CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            ), animated: animated)
        }
        if !animated {
            centerContent()
            reportZoomState()
        }
    }

    private func updateAccessibility() {
        guard let configuration else { return }
        let hasImage = imageView.image != nil
        accessibilityLabel = hasImage
            ? (NativeRemoteMediaPolicy.isAnimatedImage(configuration.url) ? "动图" : "图片")
            : (configuration.didFail ? "图片加载失败" : "图片正在加载")
        accessibilityTraits = hasImage ? .image : .button
        accessibilityHint = hasImage ? "双击可切换缩放，也可使用关闭图片操作退出" : "双击关闭图片"
        var actions = [UIAccessibilityCustomAction(name: "关闭图片", target: self, selector: #selector(accessibilityClose))]
        if hasImage {
            actions.insert(UIAccessibilityCustomAction(
                name: reportedZoomed ? "缩小图片" : "放大图片",
                target: self,
                selector: #selector(accessibilityToggleZoom)
            ), at: 0)
        }
        accessibilityCustomActions = actions
    }

    override func accessibilityPerformEscape() -> Bool {
        accessibilityClose()
    }

    override func accessibilityActivate() -> Bool {
        imageView.image == nil ? accessibilityClose() : accessibilityToggleZoom()
    }

    @objc private func accessibilityClose() -> Bool {
        guard configuration?.isActive == true else { return false }
        configuration?.onDismiss()
        return true
    }

    @objc private func accessibilityToggleZoom() -> Bool {
        guard configuration?.isActive == true, imageView.image != nil else { return false }
        toggleZoom(at: CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY))
        return true
    }
}

enum NativeRemoteMediaPolicy {
    static func isAnimatedImage(_ url: URL) -> Bool {
        ["gif", "webp", "apng"].contains(url.pathExtension.lowercased())
    }
}

struct NativeAnimatedRemoteImage: View {
    let url: URL
    let contentMode: ContentMode

    @StateObject private var loader = NativeAnimatedImageLoader()

    init(url: URL, contentMode: ContentMode = .fit) {
        self.url = url
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if let image = loader.image {
                NativeAnimatedUIImageView(image: image, contentMode: contentMode)
                    .aspectRatio(
                        image.size.height > 0 ? image.size.width / image.size.height : 1,
                        contentMode: contentMode
                    )
            } else if loader.didFail {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    ProgressView()
                }
            }
        }
        .task(id: url) { await loader.load(url) }
        .accessibilityLabel("动图")
    }
}

private struct NativeAnimatedUIImageView: UIViewRepresentable {
    let image: UIImage
    let contentMode: ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        guard uiView.image !== image else { return }
        uiView.stopAnimating()
        uiView.image = image
        uiView.startAnimating()
    }
}

@MainActor
private final class NativeAnimatedImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var didFail = false
    private var loadedURL: URL?

    func load(_ url: URL) async {
        guard loadedURL != url || image == nil else { return }
        loadedURL = url
        image = nil
        didFail = false
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  data.count <= 40 * 1_024 * 1_024,
                  let decoded = NativeAnimatedImageDecoder.decode(data)
            else { throw URLError(.cannotDecodeContentData) }
            guard loadedURL == url else { return }
            image = decoded
        } catch is CancellationError {
        } catch {
            guard loadedURL == url else { return }
            didFail = true
        }
    }
}

enum NativeAnimatedImageDecoder {
    private static let maximumFrameCount = 60
    private static let maximumTotalPixels = 24_000_000
    private static let maximumPixelSize = 1_600

    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return UIImage(data: data) }

        let stride = max(1, Int(ceil(Double(frameCount) / Double(maximumFrameCount))))
        let decodedFrameCount = Int(ceil(Double(frameCount) / Double(stride)))
        let memoryBoundPixelSize = Int(
            sqrt(Double(maximumTotalPixels) / Double(max(decodedFrameCount, 1)))
        )
        let thumbnailPixelSize = min(maximumPixelSize, max(memoryBoundPixelSize, 320))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        var frames: [UIImage] = []
        frames.reserveCapacity(min(frameCount, maximumFrameCount))
        var duration = 0.0

        for index in 0 ..< frameCount {
            duration += frameDuration(source: source, index: index)
            guard index % stride == 0,
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options)
            else { continue }
            frames.append(UIImage(cgImage: cgImage))
        }

        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let clamped = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let value = unclamped ?? clamped ?? 0.1
        return value < 0.02 ? 0.1 : value
    }
}

@MainActor
struct NativeMediaGalleryFeedback {
    let action: NativeHapticFeedbackAction

    func pageDidCommit(from previousIndex: Int, to selectedIndex: Int) {
        guard previousIndex != selectedIndex else { return }
        action(.selection)
    }

    func verticalDismissDidCommit(_ committed: Bool) {
        guard committed else { return }
        action(.dismiss)
    }
}

struct NativeMediaDismissalPolicy {
    static func isVertical(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width) * 1.15
    }

    static func shouldDismiss(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        viewportHeight: CGFloat
    ) -> Bool {
        guard isVertical(translation) else { return false }
        let threshold = max(viewportHeight * 0.16, 72)
        return abs(translation.height) >= threshold ||
            abs(predictedEndTranslation.height) >= threshold * 1.35
    }
}

struct NativeMediaPagingPolicy {
    static func targetIndex(
        currentIndex: Int,
        pageCount: Int,
        translationWidth: CGFloat,
        predictedEndTranslationWidth: CGFloat,
        pageWidth: CGFloat
    ) -> Int {
        guard pageCount > 0, pageWidth > 0, pageCount > currentIndex, currentIndex >= 0 else {
            return currentIndex
        }
        let threshold = pageWidth * 0.18
        if (translationWidth <= -threshold || predictedEndTranslationWidth <= -threshold * 1.35),
           currentIndex < pageCount - 1 {
            return currentIndex + 1
        }
        if (translationWidth >= threshold || predictedEndTranslationWidth >= threshold * 1.35),
           currentIndex > 0 {
            return currentIndex - 1
        }
        return currentIndex
    }
}

@MainActor
private final class NativeMediaImageStore: ObservableObject {
    private struct LoadOperation {
        let id = UUID()
        let task: Task<Data, Error>
    }

    @Published private var images: [URL: UIImage] = [:]
    @Published private var failedURLs: Set<URL> = []
    private var exportImages: [URL: UIImage] = [:]
    private var operations: [URL: LoadOperation] = [:]

    func image(for url: URL) -> UIImage? { images[url] }
    func exportImage(for url: URL) -> UIImage? { exportImages[url] }
    func didFail(_ url: URL) -> Bool { failedURLs.contains(url) }

    func load(_ url: URL) async {
        guard images[url] == nil else { return }
        let operation: LoadOperation
        if let existing = operations[url] {
            operation = existing
        } else {
            failedURLs.remove(url)
            operation = LoadOperation(task: Task {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode)
                else { throw URLError(.badServerResponse) }
                guard !NativeRemoteMediaPolicy.isAnimatedImage(url) || data.count <= 40 * 1_024 * 1_024
                else { throw URLError(.cannotDecodeContentData) }
                return data
            })
            operations[url] = operation
        }
        do {
            let data = try await operation.task.value
            try Task.checkCancellation()
            if images[url] == nil {
                guard let originalImage = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                let playbackImage = NativeRemoteMediaPolicy.isAnimatedImage(url)
                    ? NativeAnimatedImageDecoder.decode(data)
                    : originalImage
                guard let playbackImage else { throw URLError(.cannotDecodeContentData) }
                // Exports retain original pixels; only animated playback uses bounded frames.
                exportImages[url] = originalImage
                images[url] = playbackImage
            }
            failedURLs.remove(url)
        } catch is CancellationError {
            // A second visible page may still await the shared operation.
        } catch {
            failedURLs.insert(url)
        }
        if operations[url]?.id == operation.id { operations.removeValue(forKey: url) }
    }
}

private enum NativePhotoLibrary {
    static func save(_ image: UIImage) async throws {
        let status = await authorizationStatus()
        guard status == .authorized || status == .limited else {
            throw NativePhotoLibraryError.permissionDenied
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { succeeded, error in
                if let error { continuation.resume(throwing: error) }
                else if succeeded { continuation.resume() }
                else { continuation.resume(throwing: NativePhotoLibraryError.saveFailed) }
            }
        }
    }

    private static func authorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private enum NativePhotoLibraryError: Error {
    case permissionDenied
    case saveFailed
}

private struct NativeMediaActivityItems: Identifiable {
    let id = UUID()
    let values: [Any]
}

private struct NativeMediaActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct NativeMediaMessage: Identifiable {
    let id = UUID()
    let text: String
}
