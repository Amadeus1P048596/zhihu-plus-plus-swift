import CoreGraphics
import XCTest
@testable import iosApp

final class NativeMediaGalleryTests: XCTestCase {
    func testAnimatedImagePolicyRecognizesSupportedFormats() {
        XCTAssertTrue(NativeRemoteMediaPolicy.isAnimatedImage(
            URL(string: "https://pic.zhimg.com/demo.gif?source=answer")!
        ))
        XCTAssertTrue(NativeRemoteMediaPolicy.isAnimatedImage(
            URL(string: "https://pic.zhimg.com/demo.webp")!
        ))
        XCTAssertTrue(NativeRemoteMediaPolicy.isAnimatedImage(
            URL(string: "https://pic.zhimg.com/demo.apng")!
        ))
        XCTAssertFalse(NativeRemoteMediaPolicy.isAnimatedImage(
            URL(string: "https://pic.zhimg.com/demo.jpg")!
        ))
    }

    func testGalleryDestinationPreservesAllMediaAndSelectedIdentity() throws {
        let media = [
            CommentMediaDTO(kind: .image, url: URL(string: "https://pic.zhimg.com/one.jpg")!),
            CommentMediaDTO(kind: .image, url: URL(string: "https://pic.zhimg.com/two.jpg")!),
            CommentMediaDTO(kind: .sticker, url: URL(string: "https://pic.zhimg.com/three.png")!),
        ]

        let destination = try XCTUnwrap(
            CommentMediaGalleryDestination(
                media: media,
                selectedID: media[1].id,
                sourceLevel: .replies(rootCommentID: "root")
            )
        )

        XCTAssertEqual(destination.sourceLevel, .replies(rootCommentID: "root"))
        XCTAssertEqual(destination.urls, media.map(\.url))
        XCTAssertEqual(destination.initialIndex, 1)
    }

    func testVerticalDismissalAcceptsUpAndDownAtOneScalePolicyBoundary() {
        XCTAssertFalse(NativeMediaDismissalPolicy.isVertical(CGSize(width: 120, height: 30)))
        XCTAssertTrue(
            NativeMediaDismissalPolicy.shouldDismiss(
                translation: CGSize(width: 4, height: -150),
                predictedEndTranslation: CGSize(width: 6, height: -190),
                viewportHeight: 800
            )
        )
        XCTAssertTrue(
            NativeMediaDismissalPolicy.shouldDismiss(
                translation: CGSize(width: 4, height: 50),
                predictedEndTranslation: CGSize(width: 6, height: 230),
                viewportHeight: 800
            )
        )
        XCTAssertFalse(
            NativeMediaDismissalPolicy.shouldDismiss(
                translation: CGSize(width: 4, height: 30),
                predictedEndTranslation: CGSize(width: 6, height: 50),
                viewportHeight: 800
            )
        )
    }

    func testPagingUsesViewportWidthAndStopsAtBothBoundaries() {
        XCTAssertEqual(
            NativeMediaPagingPolicy.targetIndex(
                currentIndex: 1,
                pageCount: 3,
                translationWidth: -90,
                predictedEndTranslationWidth: -120,
                pageWidth: 400
            ),
            2
        )
        XCTAssertEqual(
            NativeMediaPagingPolicy.targetIndex(
                currentIndex: 0,
                pageCount: 3,
                translationWidth: 120,
                predictedEndTranslationWidth: 180,
                pageWidth: 400
            ),
            0
        )
        XCTAssertEqual(
            NativeMediaPagingPolicy.targetIndex(
                currentIndex: 2,
                pageCount: 3,
                translationWidth: -120,
                predictedEndTranslationWidth: -180,
                pageWidth: 400
            ),
            2
        )
        XCTAssertEqual(
            NativeMediaPagingPolicy.targetIndex(
                currentIndex: 1,
                pageCount: 3,
                translationWidth: 30,
                predictedEndTranslationWidth: 40,
                pageWidth: 400
            ),
            1
        )
    }

    @MainActor
    func testGalleryFeedbackOnlyEmitsForChangedPageAndCommittedVerticalDismiss() {
        var events: [NativeHapticFeedbackEvent] = []
        let action = NativeHapticFeedbackAction(configuration: .init()) { event, _ in
            events.append(event)
        }
        let feedback = NativeMediaGalleryFeedback(action: action)

        feedback.pageDidCommit(from: 1, to: 1)
        feedback.verticalDismissDidCommit(false)
        feedback.pageDidCommit(from: 1, to: 2)
        feedback.verticalDismissDidCommit(true)

        XCTAssertEqual(events, [.selection, .dismiss])
    }
}
