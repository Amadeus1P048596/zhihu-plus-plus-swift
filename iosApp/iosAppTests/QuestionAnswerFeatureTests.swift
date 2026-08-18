import Foundation
import UIKit
import XCTest
@testable import iosApp

final class QuestionAnswerFeatureTests: XCTestCase {
    override func tearDown() {
        QAURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testReadingPreferencesIgnoreLegacyAnswerSwitchMode() throws {
        let suiteName = "QuestionAnswerFeatureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let baseline = QAReadingPreferences(defaults: defaults)
        defaults.set("off", forKey: "answerSwitchMode")

        XCTAssertEqual(QAReadingPreferences(defaults: defaults), baseline)
    }

    func testAnswerPagerGestureArbitrationPrioritizesSystemBackAtLeadingEdge() {
        let right = CGPoint(x: 120, y: 10)
        let left = CGPoint(x: -120, y: 10)
        let vertical = CGPoint(x: 10, y: 120)

        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: right,
            velocity: .zero,
            startLocationX: 20,
            containerWidth: 390,
            hasPreviousAnswer: true,
            canNavigateBack: true,
            layoutDirection: .leftToRight
        ), .systemBack)
        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: right,
            velocity: .zero,
            startLocationX: 120,
            containerWidth: 390,
            hasPreviousAnswer: true,
            canNavigateBack: true,
            layoutDirection: .leftToRight
        ), .pager)
        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: right,
            velocity: .zero,
            startLocationX: 120,
            containerWidth: 390,
            hasPreviousAnswer: false,
            canNavigateBack: true,
            layoutDirection: .leftToRight
        ), .systemBack)
        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: left,
            velocity: .zero,
            startLocationX: 20,
            containerWidth: 390,
            hasPreviousAnswer: false,
            canNavigateBack: true,
            layoutDirection: .leftToRight
        ), .pager)
        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: vertical,
            velocity: .zero,
            startLocationX: 20,
            containerWidth: 390,
            hasPreviousAnswer: false,
            canNavigateBack: true,
            layoutDirection: .leftToRight
        ), .undecided)

        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: right,
            velocity: .zero,
            startLocationX: 20,
            containerWidth: 390,
            hasPreviousAnswer: true,
            canNavigateBack: false,
            layoutDirection: .leftToRight
        ), .pager)
    }

    func testAnswerPagerGestureArbitrationUsesLeadingDirectionInRTL() {
        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: CGPoint(x: -120, y: 5),
            velocity: .zero,
            startLocationX: 370,
            containerWidth: 390,
            hasPreviousAnswer: true,
            canNavigateBack: true,
            layoutDirection: .rightToLeft
        ), .systemBack)
        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: CGPoint(x: -120, y: 5),
            velocity: .zero,
            startLocationX: 260,
            containerWidth: 390,
            hasPreviousAnswer: true,
            canNavigateBack: true,
            layoutDirection: .rightToLeft
        ), .pager)

        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: CGPoint(x: -120, y: 5),
            velocity: .zero,
            startLocationX: 370,
            containerWidth: 390,
            hasPreviousAnswer: false,
            canNavigateBack: false,
            layoutDirection: .rightToLeft
        ), .pager)

        XCTAssertEqual(AnswerPagerGestureArbitrationPolicy.owner(
            translation: CGPoint(x: 120, y: 5),
            velocity: .zero,
            startLocationX: 370,
            containerWidth: 390,
            hasPreviousAnswer: false,
            canNavigateBack: true,
            layoutDirection: .rightToLeft
        ), .pager)
    }

    @MainActor
    func testInteractivePopObserverPreservesDelegateAcrossRepeatedInstallation() {
        let navigationController = UINavigationController(rootViewController: UIViewController())
        let observer = NativeAnswerInteractivePopObserverController()
        navigationController.pushViewController(observer, animated: false)

        let gesture = UIPanGestureRecognizer()
        let originalDelegate = GestureDelegateSpy(shouldBegin: false)
        gesture.delegate = originalDelegate

        observer.observeInteractivePopGesture(gesture)
        observer.observeInteractivePopGesture(gesture)

        XCTAssertTrue(gesture.delegate === observer)
        XCTAssertFalse(observer.gestureRecognizerShouldBegin(gesture))
        XCTAssertEqual(originalDelegate.shouldBeginCallCount, 1)

        observer.stopObservingInteractivePopGesture()
        XCTAssertTrue(gesture.delegate === originalDelegate)
    }

    @MainActor
    func testAnswerPagerFeedbackOnlyEmitsForSemanticCompletion() {
        var events: [NativeHapticFeedbackEvent] = []
        let action = NativeHapticFeedbackAction(configuration: .init()) { event, _ in
            events.append(event)
        }
        let feedback = NativeAnswerPagerFeedback(action: action)

        feedback.pageDidCommit(false)
        feedback.forwardBoundaryDidPublish(false)
        feedback.pageDidCommit(true)
        feedback.forwardBoundaryDidPublish(true)

        XCTAssertEqual(events, [.selection, .navigationBoundary])
    }

    func testRichContentParserProjectsSemanticBlocksAndPreservesTypedLinks() throws {
        let html = """
        <h2>标题</h2>
        <p data-segment-id="seg-1">正文 <strong>加粗</strong> <a href="/question/7">问题</a></p>
        <blockquote>引用</blockquote>
        <ol><li>第一项</li><li><em>第二项</em></li></ol>
        <pre><code class="language-swift">let value = 1</code></pre>
        <span class="ztext-math" data-tex="x^2+y^2"></span>
        <figure><img data-actualsrc="https://pic.zhimg.com/a.jpg" alt="图像"><figcaption>图注</figcaption></figure>
        """

        let blocks = QARichContentParser.blocks(from: html)

        XCTAssertTrue(blocks.contains { if case .heading(_, 2, _) = $0 { return true }; return false })
        let segment = try XCTUnwrap(blocks.first { if case .segment = $0 { return true }; return false })
        if case let .segment(_, id, runs) = segment {
            XCTAssertEqual(id, "seg-1")
            XCTAssertTrue(runs.contains { $0.style.contains(.strong) })
            XCTAssertTrue(runs.contains { $0.link == .question(7) })
        }
        XCTAssertTrue(blocks.contains { if case .quote = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains { if case .list(_, .ordered, let items) = $0 { return items.count == 2 }; return false })
        XCTAssertTrue(blocks.contains { if case .code(_, "swift", let text) = $0 { return text.contains("let value") }; return false })
        XCTAssertTrue(blocks.contains { if case .formula(_, "x^2+y^2") = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains {
            if case let .image(image) = $0 { return image.caption == "图注" && image.url.host == "pic.zhimg.com" }
            return false
        })
    }

    func testParserRecognizesCurrentZhihuEquationImagesAsInlineAndDisplayFormula() throws {
        let blocks = QARichContentParser.blocks(from: """
        <p>前文 <img eeimg="1" src="https://www.zhihu.com/equation?tex=q%5Cbar+q" alt="q bar q"> 后文</p>
        <p> \n <img eeimg="1" src="//zhihu.com/equation?tex=x%2By" alt="x+y"> \n </p>
        <img eeimg="2" src="https://www.zhihu.com/equation?tex=%5Csum_%7Bi%3D1%7D%5En" alt="sum">
        """)

        XCTAssertEqual(blocks.count, 3)
        guard case let .paragraph(_, runs) = blocks[0] else {
            return XCTFail("expected mixed inline paragraph")
        }
        XCTAssertEqual(runs.compactMap(\.formulaLatex), [#"q\bar q"#])
        XCTAssertEqual(runs.map(\.text).joined(), #"前文 q\bar q 后文"#)
        XCTAssertEqual(runs.first(where: { $0.formulaLatex != nil })?.content, .formula(latex: #"q\bar q"#))
        XCTAssertTrue(runs.first(where: { $0.formulaLatex == nil })?.content == .text("前文 "))
        XCTAssertTrue(blocks.contains { if case .formula(_, "x+y") = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains { if case .formula(_, #"\sum_{i=1}^n"#) = $0 { return true }; return false })
        XCTAssertFalse(blocks.contains { if case .image = $0 { return true }; return false })
    }

    func testParserKeepsCurrentEquationInlineInsideListItem() throws {
        let blocks = QARichContentParser.blocks(from: """
        <ul><li>左侧<img eeimg="1" src="//www.zhihu.com/equation?tex=a%2Bb">右侧</li></ul>
        """)

        guard case let .list(_, .unordered, items) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected list")
        }
        let runs = try XCTUnwrap(items.first).runs
        XCTAssertEqual(runs.compactMap(\.formulaLatex), ["a+b"])
        XCTAssertEqual(runs.map(\.text).joined(), "左侧a+b右侧")
        XCTAssertFalse(blocks.contains { if case .formula = $0 { return true }; return false })
    }

    func testParserMatchesReportedAnswerFormulaShape() {
        let formulas: [(tex: String, sole: Bool)] = [
            ("X%282370%29", false),
            ("J%5E%7BPC%7D%3D0%5E%7B-%2B%7D", false),
            ("q%5Cbar+q", false),
            ("X%282370%29", false),
            ("+X%282370%29", false),
            ("J%2F%5Cpsi%5Cto%5Cgamma%5Cpi%5E%2B%5Cpi%5E-%5Ceta%27", true),
            ("+X%282370%29", false),
            ("+6.4%5Csigma", false),
            ("+J%2F%5Cpsi", false),
            ("J%2F%5Cpsi%5Cto%5Cgamma+K_S%5E0K_S%5E0%5Ceta%27", true),
            ("+X%282370%29", false),
        ]
        let html = formulas.enumerated().map { index, formula in
            let image = #"<img eeimg="1" src="https://www.zhihu.com/equation?tex=\#(formula.tex)"/>"#
            return formula.sole
                ? #"<p data-pid="sole-\#(index)">\#(image) </p>"#
                : #"<p data-pid="mixed-\#(index)">正文 \#(image) 后文</p>"#
        }.joined()

        let blocks = QARichContentParser.blocks(from: html)
        let inlineFormulaCount = blocks.reduce(into: 0) { count, block in
            guard case let .paragraph(_, runs) = block else { return }
            count += runs.compactMap(\.formulaLatex).count
        }
        let blockFormulaCount = blocks.reduce(into: 0) { count, block in
            if case .formula = block { count += 1 }
        }
        let imageCount = blocks.reduce(into: 0) { count, block in
            if case .image = block { count += 1 }
        }

        XCTAssertEqual(inlineFormulaCount, 9)
        XCTAssertEqual(blockFormulaCount, 2)
        XCTAssertEqual(imageCount, 0)
    }

    func testParserPreservesOldFormulaMarkupAndDecodesHTMLEntitiesOnce() throws {
        let blocks = QARichContentParser.blocks(from: """
        <p>旧格式 <span class="ztext-math" data-tex="a&amp;amp;b"></span>
        和 <img data-formula="c&amp;d"> <span data-tex="普通元数据">保留正文</span></p>
        <p><span class="ztext-math" data-tex="x^2">不应重复的 fallback</span></p>
        """)

        guard case let .paragraph(_, runs) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(runs.compactMap(\.formulaLatex), ["a&amp;b", "c&d"])
        XCTAssertTrue(runs.map(\.text).joined().contains("保留正文"))
        XCTAssertFalse(runs.map(\.text).joined().contains("普通元数据"))
        XCTAssertTrue(blocks.contains { if case .formula(_, "x^2") = $0 { return true }; return false })
        XCTAssertFalse(blocks.contains { block in
            guard case let .paragraph(_, values) = block else { return false }
            return values.map(\.text).joined().contains("不应重复")
        })
    }

    func testParserContainsUnclosedLegacyFormulaFallbackToItsBlock() {
        let blocks = QARichContentParser.blocks(from: """
        <p><span class="ztext-math" data-tex="x^2">fallback</p>
        <p>后续正文仍然保留</p>
        """)

        XCTAssertTrue(blocks.contains { if case .formula(_, "x^2") = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains { block in
            guard case let .paragraph(_, runs) = block else { return false }
            return runs.map(\.text).joined().contains("后续正文仍然保留")
        })
    }

    func testParserFormDecodesEquationQueryOnceAndRejectsSpoofedEndpoints() {
        let valid = QARichContentParser.blocks(from: """
        <p><img eeimg="1" src="https://www.zhihu.com/equation?other=1&amp;tex=a%26b%252B"></p>
        """)
        XCTAssertTrue(valid.contains { if case .formula(_, "a&b%2B") = $0 { return true }; return false })
        XCTAssertFalse(valid.contains { if case .image = $0 { return true }; return false })

        let leadingSpace = QARichContentParser.blocks(from: """
        <p>行内<img eeimg="1" src="https://www.zhihu.com/equation?tex=+X%282370%29"></p>
        """)
        guard let firstLeadingSpaceBlock = leadingSpace.first,
              case let .paragraph(_, leadingSpaceRuns) = firstLeadingSpaceBlock
        else {
            return XCTFail("expected inline formula paragraph")
        }
        XCTAssertEqual(leadingSpaceRuns.compactMap(\.formulaLatex), [" X(2370)"])

        let spoofed = QARichContentParser.blocks(from: """
        <img eeimg="1" src="https://www.zhihu.com.evil/equation?tex=x">
        <img eeimg="2" src="https://zhihu.com:443/equation?tex=y">
        <img eeimg="1" src="https://www.zhihu.com/equation/extra?tex=z">
        <img eeimg="1" src="http://www.zhihu.com/equation?tex=ignored">
        """)
        XCTAssertFalse(spoofed.contains { if case .formula = $0 { return true }; return false })
        XCTAssertEqual(spoofed.compactMap { block -> URL? in
            guard case let .image(image) = block else { return nil }
            return image.url
        }.count, 3)
    }

    func testParserIgnoresNoscriptDuplicateAndRejectsDataImage() {
        let blocks = QARichContentParser.blocks(
            from: #"<figure><noscript><img src="https://pic.zhimg.com/duplicate.jpg"></noscript><img src="data:image/svg+xml,x" data-actualsrc="https://pic.zhimg.com/real.jpg"></figure>"#
        )
        let images = blocks.compactMap { block -> QAImageDTO? in
            guard case let .image(image) = block else { return nil }
            return image
        }
        XCTAssertEqual(images.map(\.url.absoluteString), ["https://pic.zhimg.com/real.jpg"])
    }

    func testParserPreservesTrustedZhihuImageDimensionsBeforeLoading() throws {
        let blocks = QARichContentParser.blocks(from: """
        <figure>
          <img
            src="https://pic.zhimg.com/example.jpg"
            data-rawwidth="1200"
            data-rawheight="880"
            width="300"
            height="200"
          />
          <figcaption>尺寸图</figcaption>
        </figure>
        """)

        guard case let .image(image) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected image")
        }
        XCTAssertEqual(image.dimensions, QAImageDimensions(width: 1200, height: 880))
        XCTAssertEqual(
            try XCTUnwrap(image.dimensions).aspectRatio,
            1200.0 / 880.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(image.caption, "尺寸图")
    }

    func testParserFallsBackToWidthHeightAndRejectsUntrustedImageDimensions() {
        let blocks = QARichContentParser.blocks(from: """
        <img src="https://pic.zhimg.com/fallback.jpg"
             data-rawwidth="unknown" data-rawheight="unknown"
             width="640" height="480" />
        <img src="https://pic.zhimg.com/invalid.jpg" data-rawwidth="-1" data-rawheight="999999999" />
        """)
        let images = blocks.compactMap { block -> QAImageDTO? in
            guard case let .image(image) = block else { return nil }
            return image
        }

        XCTAssertEqual(images.first?.dimensions, QAImageDimensions(width: 640, height: 480))
        XCTAssertNil(images.last?.dimensions)
    }

    func testParserPreservesNestedAndSiblingListHierarchyAndOrderedStart() throws {
        let blocks = QARichContentParser.blocks(from: """
        <ol start="3">
          <li>继续跳票。</li>
          <li>在较短时间内推出，但是</li>
          <ol>
            <li>分词器和灰测表现不一致</li>
            <ol>
              <li>正式版性能约等于 Fable。</li>
              <li>正式版性能远不及 Fable。</li>
            </ol>
            <li>分词器和灰测表现一致</li>
          </ol>
        </ol>
        """)

        guard case let .list(_, .ordered, items) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected ordered list")
        }
        XCTAssertEqual(items.map(\.ordinal), [3, 4])
        XCTAssertEqual(items.map { $0.runs.map(\.text).joined() }, ["继续跳票。", "在较短时间内推出，但是"])
        let secondLevel = try XCTUnwrap(items[1].nestedLists.first)
        XCTAssertEqual(secondLevel.kind, .ordered)
        XCTAssertEqual(secondLevel.items.count, 2)
        XCTAssertEqual(secondLevel.items[0].nestedLists.first?.items.count, 2)
    }

    func testParserKeepsItemsFromMalformedNestedListWithoutPrecedingItem() throws {
        let blocks = QARichContentParser.blocks(from: """
        <h3>1.2 国际带宽分配</h3>
        <ul><ul>
          <li>电信的国际带宽总量最大，约为7.7T</li>
          <li>带宽分配较为均衡，各省都有一定的国际带宽</li>
        </ul></ul>
        """)

        let list = try XCTUnwrap(blocks.first { block in
            if case .list = block { return true }
            return false
        })
        guard case let .list(_, .unordered, items) = list else {
            return XCTFail("expected unordered list")
        }
        XCTAssertEqual(
            items.map { $0.runs.map(\.text).joined() },
            ["电信的国际带宽总量最大，约为7.7T", "带宽分配较为均衡，各省都有一定的国际带宽"]
        )
    }

    func testSelectableRichTextKeepsStrikethroughAndTypedLinkInOneTextRun() throws {
        let blocks = QARichContentParser.blocks(
            from: #"<p><a href="/question/7"><del>可选择的划线链接</del></a></p>"#
        )
        guard case let .paragraph(_, runs) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(runs.first?.link, .question(7))
        XCTAssertTrue(try XCTUnwrap(runs.first).style.contains(.strikethrough))

        let attributed = QARichTextFormatter.attributed(runs)
        XCTAssertEqual(String(attributed.characters), "可选择的划线链接")
        XCTAssertEqual(attributed.runs.first?.link, URL(string: "zhihu://questions/7"))
        XCTAssertNotNil(attributed.runs.first?.strikethroughStyle)
    }

    func testLatexReadableFallbackSupportsEscapesSpacingAndConsecutiveScripts() {
        XCTAssertEqual(
            QALatexReadableText.render("\\{ \\} \\$ \\% \\# \\& \\_ \\| \\backslash"),
            "{ } $ % # & _ ‖ \\"
        )
        XCTAssertEqual(QALatexReadableText.render("a_ib_jx^{i+j}"), "aᵢbⱼxⁱ⁺ʲ")
        XCTAssertEqual(
            QALatexReadableText.render(#"\frac{a}{b}"#),
            #"\frac{a}{b}"#,
            "unknown commands must remain lossless"
        )
        XCTAssertEqual(
            QALatexReadableText.render(#"a\ b\,c\:d\>e\;f\quad g\qquad h"#),
            "a b\u{2009}c\u{2005}d\u{2005}e\u{2004}f\u{2003}g\u{2003}\u{2003}h"
        )
    }

    func testMarkdownConverterProjectsSemanticBlocksWithoutReparsingDisplayText() {
        let nested = QAListGroup(
            kind: .ordered,
            startIndex: 3,
            items: [
                QAListItem(runs: [QAInlineRun(text: "内层一")], ordinal: 3),
                QAListItem(
                    runs: [QAInlineRun(text: "内层二")],
                    ordinal: 4,
                    nestedLists: [
                        QAListGroup(
                            kind: .unordered,
                            items: [QAListItem(runs: [QAInlineRun(text: "三级")])]
                        ),
                    ]
                ),
            ]
        )
        let blocks: [QABodyBlock] = [
            .paragraph(UUID(), [
                QAInlineRun(text: "普通 * 文本 "),
                QAInlineRun(formulaLatex: "E=mc^2"),
                QAInlineRun(text: " "),
                QAInlineRun(text: "加粗", style: .strong),
                QAInlineRun(text: " 强调", style: .emphasis),
                QAInlineRun(text: " 删除", style: .strikethrough, link: .question(7)),
                QAInlineRun(text: " code`value", style: .code),
            ]),
            .heading(UUID(), level: 3, runs: [QAInlineRun(text: "小节")]),
            .quote(UUID(), [QAInlineRun(text: "引用\n第二行")]),
            .list(
                UUID(),
                kind: .unordered,
                items: [
                    QAListItem(
                        runs: [QAInlineRun(text: "外层")],
                        nestedLists: [nested]
                    ),
                ]
            ),
            .code(UUID(), language: "swift unsafe", text: "let fence = ```"),
            .formula(UUID(), latex: "a_ib_j"),
            .image(QAImageDTO(
                url: URL(string: "https://pic.zhimg.com/a.jpg")!,
                caption: "说明",
                altText: "图]像"
            )),
            .segment(UUID(), segmentID: "seg", runs: [QAInlineRun(text: "划线正文")]),
            .divider(UUID()),
        ]

        XCTAssertEqual(
            QAMarkdownConverter.blocks(blocks),
            """
            普通 \\* 文本 $E=mc^2$ **加粗** *强调* [~~删除~~](https://www.zhihu.com/question/7) ``code`value``

            ### 小节

            > 引用
            > 第二行

            - 外层
                3. 内层一
                4. 内层二
                    - 三级

            ````swift
            let fence = ```
            ````

            $$
            a_ib_j
            $$

            ![图\\]像](https://pic.zhimg.com/a.jpg)

            _说明_

            划线正文

            ---
            """
        )
    }

    func testMarkdownDocumentIncludesTitleAuthorSourceAndOnlyLoadedBlocks() {
        let answer = QAFixtures.answerDTO
        let document = QAMarkdownConverter.document(from: answer)

        XCTAssertEqual(document.title, "原生问题")
        XCTAssertEqual(document.authorName, "作者")
        XCTAssertEqual(document.sourceURL, answer.sourceURL)
        XCTAssertEqual(document.suggestedFileName, "原生问题.md")
        XCTAssertEqual(
            document.markdown,
            "# 原生问题\n\n作者：作者\n\n" +
                "原文：[https://www.zhihu.com/question/7/answer/42]" +
                "(https://www.zhihu.com/question/7/answer/42)\n\n正文\n"
        )

        let article = AnswerDTO(
            route: .init(contentID: 9, kind: .article),
            title: "文章 / 标题",
            questionID: nil,
            author: answer.author,
            blocks: [.paragraph(UUID(), [QAInlineRun(text: "当前已加载内容")])],
            attachment: nil,
            sourceURL: URL(string: "https://zhuanlan.zhihu.com/p/9")!,
            voteUpCount: 0,
            favoriteCount: 0,
            commentCount: 0,
            voteState: .neutral,
            favoriteState: .unknown,
            createdTimeSeconds: 0,
            updatedTimeSeconds: 0,
            ipLocation: nil,
            invitationPreface: nil,
            endorsements: []
        )
        let articleDocument = QAMarkdownConverter.document(from: article)
        XCTAssertTrue(articleDocument.markdown.contains("当前已加载内容"))
        XCTAssertFalse(articleDocument.markdown.contains("未加载"))
        XCTAssertEqual(articleDocument.suggestedFileName, "文章-标题.md")
    }

    func testMarkdownSharePayloadUsesTextThenSafeTemporaryFileForLongContent() throws {
        let short = QAMarkdownDocument(
            title: "短文",
            authorName: "作者",
            sourceURL: URL(string: "https://www.zhihu.com/answer/1")!,
            markdown: "短正文",
            suggestedFileName: "短文.md"
        )
        XCTAssertEqual(
            QAMarkdownSharePayloadBuilder.payload(for: short, inlineTextByteLimit: 100),
            .text("短正文")
        )

        let long = QAMarkdownDocument(
            title: "长文",
            authorName: "作者",
            sourceURL: short.sourceURL,
            markdown: String(repeating: "长", count: 101),
            suggestedFileName: "../../不可覆盖.md"
        )
        XCTAssertEqual(
            QAMarkdownSharePayloadBuilder.payload(for: long, inlineTextByteLimit: 100),
            .file(contents: long.markdown, suggestedFileName: "../../不可覆盖.md")
        )

        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(
            "QAMarkdownTemporaryFileStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: base) }
        let sibling = base.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)

        let temporary = try QAMarkdownTemporaryFileStore.write(
            contents: long.markdown,
            suggestedFileName: "../../不可覆盖.md",
            baseDirectory: base,
            fileManager: fileManager
        )
        XCTAssertEqual(temporary.fileURL.lastPathComponent, "不可覆盖.md")
        XCTAssertEqual(try String(contentsOf: temporary.fileURL), long.markdown)
        XCTAssertTrue(fileManager.fileExists(atPath: sibling.path))

        temporary.cleanup(fileManager: fileManager)
        XCTAssertFalse(fileManager.fileExists(atPath: temporary.directoryURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: sibling.path))
    }

    func testParserProjectsZhihuVideoBoxInsteadOfTreatingCoverAsImage() throws {
        let blocks = QARichContentParser.blocks(from: """
        <a class="video-box" href="https://link.zhihu.com/?target=https%3A//www.zhihu.com/video/2029631316597973958" data-lens-id="2029631316597973958">
          <img src="https://pic.zhimg.com/video-cover.jpg" />
        </a>
        """)

        XCTAssertEqual(blocks.count, 1)
        guard case let .video(_, video) = try XCTUnwrap(blocks.first) else {
            return XCTFail("video-box should become a native video block")
        }
        XCTAssertEqual(video.videoID, 2_029_631_316_597_973_958)
        XCTAssertEqual(video.thumbnailURL?.absoluteString, "https://pic.zhimg.com/video-cover.jpg")
        XCTAssertEqual(video.destinationURL?.absoluteString, "https://www.zhihu.com/video/2029631316597973958")
    }

    func testParserNormalizesSchemeRelativeExternalLink() throws {
        let blocks = QARichContentParser.blocks(
            from: #"<p><a href="//example.com/path">外部链接</a></p>"#
        )
        guard case let .paragraph(_, runs) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(runs.first?.link, .external(URL(string: "https://example.com/path")!))
    }

    func testAppViewLinksResolveToTypedQADestinations() throws {
        XCTAssertEqual(
            QABodyLinkResolver.resolve(URL(string: "https://www.zhihu.com/appview/pin/11")!),
            .pin(11)
        )
        XCTAssertEqual(
            QABodyLinkResolver.resolve(URL(string: "https://www.zhihu.com/appview/answer/12")!),
            .answer(12)
        )
        XCTAssertEqual(
            QABodyLinkResolver.resolve(URL(string: "https://www.zhihu.com/appview/p/13")!),
            .article(13)
        )

        let external = URL(string: "https://attacker.example/appview/answer/12")!
        XCTAssertEqual(QABodyLinkResolver.resolve(external), .external(external))
    }

    func testRichContentParserUsesUnifiedAppViewResolver() throws {
        let blocks = QARichContentParser.blocks(
            from: #"<p><a href="/appview/pin/22">站内想法</a></p>"#
        )
        guard case let .paragraph(_, runs) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(runs.first?.link, .pin(22))
    }

    func testPinDateNeverMovesIPFromTrailingMetadata() {
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: true).dateEdge, .leading)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: true).ipEdge, .trailing)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: false).dateEdge, .trailing)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: false).ipEdge, .trailing)
    }

    func testQuestionRepositoryBuildsSortContractAndMapsFullQuestion() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            if request.url?.path.hasSuffix("/feeds") == true {
                return (200, QAFixtures.answerPage(next: nil), [:])
            }
            return (200, QAFixtures.question, [:])
        }
        let repository = makeRepository()

        let question = try await repository.fetchQuestion(QuestionRouteDTO(questionID: 7))
        let page = try await repository.fetchQuestionAnswers(questionID: 7, sort: .updated, after: nil)

        XCTAssertEqual(question.title, "原生问题")
        XCTAssertEqual(question.detailBlocks.count, 1)
        XCTAssertTrue(question.isFollowing)
        XCTAssertEqual(page.items.map(\.answerID), [42])
        let feedRequest = try XCTUnwrap(recorder.requests.first { $0.url?.path.hasSuffix("/feeds") == true })
        XCTAssertTrue(feedRequest.url?.query?.contains("order=updated") == true)
        XCTAssertTrue(feedRequest.url?.query?.contains("include=") == true)
    }

    func testQuestionAndAnswerReadRequestsUseAuthenticatedSignature() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            switch request.url?.path {
            case "/api/v4/questions/7":
                return (200, QAFixtures.question, [:])
            case "/api/v4/questions/7/feeds":
                return (200, QAFixtures.answerPage(next: nil), [:])
            default:
                return (200, QAFixtures.answer, [:])
            }
        }
        let repository = makeRepository()

        _ = try await repository.fetchQuestion(QuestionRouteDTO(questionID: 7))
        _ = try await repository.fetchQuestionAnswers(questionID: 7, sort: .default, after: nil)
        _ = try await repository.fetchAnswer(
            AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7)
        )

        XCTAssertEqual(recorder.requests.count, 3)
        for request in recorder.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "d_c0=device; z_c0=login")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
            XCTAssertTrue(request.value(forHTTPHeaderField: "x-zse-96")?.hasPrefix("2.0_") == true)
        }
    }

    func testVideoRepositoryPostsWebPlayerContractAndChoosesHighestTrustedBitrate() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (
                200,
                Data(
                    #"{"video_play":{"playlist":{"mp4":[{"bitrate":100,"url":["https://video.vzuu.com/low.mp4"]},{"bitrate":300,"url":["https://video.vzuu.com/high.mp4"]}]}}}"#.utf8
                ),
                [:]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QAURLProtocol.self]
        let client = ZhihuAPIClient(
            accountStore: QAAccountStore(),
            session: URLSession(configuration: configuration)
        )
        let repository = URLSessionNativeVideoRepository(client: client)
        let route = NativeVideoRouteDTO(
            contentID: 42,
            videoID: 99,
            contentType: .answer
        )

        let playbackURL = try await repository.resolvePlaybackURL(for: route)

        XCTAssertEqual(playbackURL, URL(string: "https://video.vzuu.com/high.mp4"))
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v4/video/play_info")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "r" })?.value,
            "99"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-app-za"), "OS=webplayer")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["content_id"] as? String, "42")
        XCTAssertEqual(json["content_type_str"] as? String, "answer")
        XCTAssertEqual(json["video_id"] as? String, "99")
        XCTAssertEqual(json["scene_code"] as? String, "answer_detail_web")
        XCTAssertEqual(json["is_only_video"] as? Bool, true)
    }

    func testVideoRepositoryRejectsUntrustedPlaybackHost() async {
        QAURLProtocol.setHandler { _ in
            (
                200,
                Data(
                    #"{"video_play":{"playlist":{"mp4":[{"bitrate":300,"url":["https://attacker.example/video.mp4"]}]}}}"#.utf8
                ),
                [:]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QAURLProtocol.self]
        let client = ZhihuAPIClient(
            accountStore: QAAccountStore(),
            session: URLSession(configuration: configuration)
        )
        let repository = URLSessionNativeVideoRepository(client: client)

        do {
            _ = try await repository.resolvePlaybackURL(for: .init(
                contentID: 42,
                videoID: 99,
                contentType: .answer
            ))
            XCTFail("Expected untrusted playback URL to be rejected")
        } catch {
            XCTAssertEqual(error as? NativeVideoRepositoryError, .playbackUnavailable)
        }
    }

    func testQuestionAndAnswerReadRequestsRejectMissingAccountBeforeNetwork() async {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data(), [:])
        }
        let repository = makeRepository(accountStore: QAAccountStore(json: nil))

        do {
            _ = try await repository.fetchQuestion(QuestionRouteDTO(questionID: 7))
            XCTFail("Expected question authentication failure")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }
        do {
            _ = try await repository.fetchQuestionAnswers(
                questionID: 7,
                sort: .default,
                after: nil
            )
            XCTFail("Expected question feed authentication failure")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }
        do {
            _ = try await repository.fetchAnswer(
                AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7)
            )
            XCTFail("Expected answer authentication failure")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testAnswerRepositoryMapsBlocksEndorsementMetadataAndUnknownFavorite() async throws {
        QAURLProtocol.setHandler { _ in (200, QAFixtures.answer, [:]) }
        let repository = makeRepository()

        let answer = try await repository.fetchAnswer(
            AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7)
        )

        XCTAssertEqual(answer.title, "原生问题")
        XCTAssertEqual(answer.author.displayName, "作者")
        XCTAssertEqual(answer.voteState, .up)
        XCTAssertEqual(answer.favoriteState, .unknown)
        XCTAssertEqual(answer.ipLocation, "江苏")
        XCTAssertEqual(answer.endorsements.first?.text, "周刊收录")
        XCTAssertEqual(answer.endorsements.first?.actionURL?.path, "/column/c_1533471233991028736")
        XCTAssertEqual(
            answer.sourceURL.absoluteString,
            "https://www.zhihu.com/question/7/answer/42"
        )
        XCTAssertNil(answer.invitationPreface, "thanks_count must never be guessed as the user-visible 谢邀 preface")
        XCTAssertTrue(answer.blocks.contains { if case .paragraph = $0 { return true }; return false })
    }

    func testAnswerRepositoryMergesAttachmentPlaybackIntoMatchingVideoBoxWithoutDuplicate() async throws {
        let payload = Data(#"""
        {
          "id":42,
          "content":"<a class=\"video-box\" data-lens-id=\"99\" href=\"https://www.zhihu.com/video/99\"><img src=\"https://pic.zhimg.com/cover.jpg\"></a>",
          "author":{"id":"member","url_token":"author","name":"作者","headline":"","avatar_url":"https://pic.zhimg.com/avatar.jpg"},
          "question":{"id":7,"title":"原生问题"},
          "attachment":{"type":"video","attachment_id":"99","video":{"video_info":{"thumbnail":"https://pic.zhimg.com/cover.jpg","playlist":{"hd":{"play_url":"https://vdn1.vzuu.com/video.mp4"}}}}},
          "voteup_count":1,"comment_count":0,"created_time":1,"updated_time":1
        }
        """#.utf8)
        QAURLProtocol.setHandler { _ in (200, payload, [:]) }

        let answer = try await makeRepository().fetchAnswer(
            AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7)
        )
        let videos = answer.blocks.compactMap { block -> QAAttachmentVideoDTO? in
            guard case let .video(_, video) = block else { return nil }
            return video
        }

        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.videoID, 99)
        XCTAssertEqual(videos.first?.playbackURL?.absoluteString, "https://vdn1.vzuu.com/video.mp4")
        XCTAssertNil(answer.attachment)
    }

    func testUntrustedQuestionContinuationIsRejectedBeforeSecondRequest() async throws {
        QAURLProtocol.setHandler { _ in
            (200, QAFixtures.answerPage(next: "https://attacker.example/steal"), [:])
        }
        let repository = makeRepository()

        do {
            _ = try await repository.fetchQuestionAnswers(questionID: 7, sort: .default, after: nil)
            XCTFail("Expected continuation rejection")
        } catch QuestionAnswerRepositoryError.untrustedContinuation {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testQuestionContinuationKeepsFeedIncludeContract() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            let isContinuation = request.url?.query?.contains("offset=20") == true
            return (
                200,
                QAFixtures.answerPage(
                    next: isContinuation
                        ? nil
                        : "https://www.zhihu.com/api/v4/questions/7/feeds?limit=20&order=updated&offset=20"
                ),
                [:]
            )
        }
        let repository = makeRepository()

        let firstPage = try await repository.fetchQuestionAnswers(
            questionID: 7,
            sort: .updated,
            after: nil
        )
        _ = try await repository.fetchQuestionAnswers(
            questionID: 7,
            sort: .updated,
            after: try XCTUnwrap(firstPage.nextURL)
        )

        let continuation = try XCTUnwrap(
            recorder.requests.first { $0.url?.query?.contains("offset=20") == true }
        )
        XCTAssertTrue(
            continuation.url?.query?.contains(
                "include=data%5B*%5D.content,excerpt,headline,target.author.badge_v2"
            ) == true
        )
    }

    func testVoteUsesAnswerStatePayloadAndPublishesServerCount() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data(#"{"voteup_count":101}"#.utf8), [:])
        }
        let repository = makeRepository()

        let result = try await repository.setVote(
            .down,
            route: AnswerRouteDTO(contentID: 42, kind: .answer)
        )

        XCTAssertEqual(result, QAVoteMutationResult(state: .down, voteUpCount: 101))
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v4/answers/42/voters")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: String])?["type"], "down")
    }

    func testReadHistoryUsesOfficialAddEndpointAndPayload() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data(#"{}"#.utf8), [:])
        }
        let repository = makeRepository()

        await repository.recordReadHistory(contentToken: "42", contentType: "answer")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://www.zhihu.com/api/v4/read_history/add")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(payload["content_token"], "42")
        XCTAssertEqual(payload["content_type"], "answer")
    }

    func testReadHistoryIgnoresUnsupportedContentType() async {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data(#"{}"#.utf8), [:])
        }
        let repository = makeRepository()

        await repository.recordReadHistory(contentToken: "42", contentType: "advertisement")

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    @MainActor
    func testQuestionRefreshFailurePreservesPreviouslyVisibleQuestionAndAnswers() async {
        let repository = StubQuestionAnswerRepository()
        repository.questionResult = .success(QAFixtures.questionDTO)
        repository.answerPageResults = [.success(QAFixtures.answerPageDTO)]
        let store = QuestionStore(route: QuestionRouteDTO(questionID: 7), repository: repository)
        await store.refresh()
        repository.questionResult = .failure(QAStubError.failed)
        repository.answerPageResults = [.failure(QAStubError.failed)]

        await store.refresh()

        XCTAssertEqual(store.question?.title, "原生问题")
        XCTAssertEqual(store.answers.map(\.answerID), [42])
        XCTAssertEqual(store.initialLoad, .failed("测试失败"))
    }

    @MainActor
    func testQuestionSourcePreservesClickedPositionForPager() {
        let repository = StubQuestionAnswerRepository()
        let answers = [40, 41, 42, 43].map(QAFixtures.preview)
        let route = AnswerRouteDTO(
            contentID: 42,
            kind: .answer,
            questionID: 7,
            source: AnswerPageSourceDTO(
                questionID: 7,
                order: .updated,
                orderedAnswers: answers,
                selectedAnswerID: 42,
                nextURL: nil
            )
        )

        let pager = AnswerPagerStore(
            route: route,
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        XCTAssertEqual(pager.current.id, 42)
        XCTAssertEqual(pager.previous?.id, 41)
        XCTAssertEqual(pager.next?.id, 43)
    }

    @MainActor
    func testPagerContinuesAcrossPagesUntilItFindsAnUnopenedAnswer() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        repository.answerPageResults = [
            .success(
                QuestionAnswerPageDTO(
                    items: [QAFixtures.preview(43)],
                    nextURL: URL(string: "https://www.zhihu.com/api/v4/questions/7/feeds?offset=20"),
                    isEnd: false
                )
            ),
            .success(
                QuestionAnswerPageDTO(
                    items: [QAFixtures.preview(44)],
                    nextURL: nil,
                    isEnd: true
                )
            ),
        ]
        let pager = AnswerPagerStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: repository,
            openedHistory: StubOpenedHistory(opened: [43])
        )

        await pager.prepare()

        XCTAssertEqual(pager.next?.id, 44)
    }

    @MainActor
    func testPagerKeepsPublishingNeighborsAcrossInitialAndLoadedPages() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        repository.answerPageResults = [
            .success(
                QuestionAnswerPageDTO(
                    items: [44, 45, 46].map(QAFixtures.preview),
                    nextURL: nil,
                    isEnd: true
                )
            ),
        ]
        let initial = [40, 41, 42, 43].map(QAFixtures.preview)
        let pager = AnswerPagerStore(
            route: AnswerRouteDTO(
                contentID: 40,
                kind: .answer,
                questionID: 7,
                source: AnswerPageSourceDTO(
                    questionID: 7,
                    order: .default,
                    orderedAnswers: initial,
                    selectedAnswerID: 40,
                    nextURL: URL(string: "https://www.zhihu.com/api/v4/questions/7/feeds?offset=4")
                )
            ),
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        await pager.prepare()
        XCTAssertEqual(pager.next?.id, 41)
        for expected in [41, 42, 43, 44, 45, 46] {
            await pager.didDisplay(answerID: Int64(expected))
            XCTAssertEqual(pager.current.id, Int64(expected))
            XCTAssertEqual(pager.next?.id, expected == 46 ? nil : Int64(expected + 1))
        }
    }

    @MainActor
    func testPagerDistinguishesLoadingAvailableEndAndFailedForwardStates() async {
        let availableRepository = StubQuestionAnswerRepository()
        let availableRoute = AnswerRouteDTO(
            contentID: 42,
            kind: .answer,
            questionID: 7,
            source: AnswerPageSourceDTO(
                questionID: 7,
                order: .default,
                orderedAnswers: [42, 43].map(QAFixtures.preview),
                selectedAnswerID: 42,
                nextURL: nil
            )
        )
        let availablePager = AnswerPagerStore(
            route: availableRoute,
            repository: availableRepository,
            openedHistory: StubOpenedHistory()
        )
        XCTAssertEqual(availablePager.forwardAvailability, .available)

        let endRepository = StubQuestionAnswerRepository()
        endRepository.answerResult = .success(QAFixtures.answerDTO)
        endRepository.answerPageResults = [
            .success(QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true)),
        ]
        let endPager = AnswerPagerStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: endRepository,
            openedHistory: StubOpenedHistory()
        )
        XCTAssertEqual(endPager.forwardAvailability, .loading)
        XCTAssertFalse(endPager.reportForwardBoundaryReached())
        XCTAssertNil(endPager.boundaryNotice)
        await endPager.prepare()
        XCTAssertEqual(endPager.forwardAvailability, .end)
        XCTAssertTrue(endPager.reportForwardBoundaryReached())
        XCTAssertEqual(endPager.boundaryNotice, "没有更多了")
        XCTAssertFalse(endPager.reportForwardBoundaryReached())

        let failedRepository = StubQuestionAnswerRepository()
        failedRepository.answerResult = .success(QAFixtures.answerDTO)
        failedRepository.answerPageResults = [.failure(QAStubError.failed)]
        let failedPager = AnswerPagerStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: failedRepository,
            openedHistory: StubOpenedHistory()
        )
        await failedPager.prepare()
        XCTAssertEqual(failedPager.forwardAvailability, .failed("测试失败"))
    }

    @MainActor
    func testPagerCommitsDisplayedAnswerBeforeAsyncPreparation() {
        let repository = StubQuestionAnswerRepository()
        let route = AnswerRouteDTO(
            contentID: 40,
            kind: .answer,
            questionID: 7,
            source: AnswerPageSourceDTO(
                questionID: 7,
                order: .default,
                orderedAnswers: [40, 41, 42].map(QAFixtures.preview),
                selectedAnswerID: 40,
                nextURL: nil
            )
        )
        let pager = AnswerPagerStore(
            route: route,
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        XCTAssertTrue(pager.commitDisplayedAnswer(answerID: 41))

        XCTAssertEqual(pager.current.id, 41)
        XCTAssertEqual(pager.previous?.id, 40)
        XCTAssertEqual(pager.next?.id, 42)
    }

    private func makeRepository(
        accountStore: AccountJSONStore = QAAccountStore()
    ) -> URLSessionQuestionAnswerRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QAURLProtocol.self]
        let client = ZhihuAPIClient(
            accountStore: accountStore,
            session: URLSession(configuration: configuration)
        )
        return URLSessionQuestionAnswerRepository(client: client)
    }
}

private final class GestureDelegateSpy: NSObject, UIGestureRecognizerDelegate {
    private let shouldBegin: Bool
    private(set) var shouldBeginCallCount = 0

    init(shouldBegin: Bool) {
        self.shouldBegin = shouldBegin
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBeginCallCount += 1
        return shouldBegin
    }
}

private enum QAFixtures {
    static let question = Data(
        #"{"id":7,"title":"原生问题","detail":"<p>问题描述</p>","answer_count":1,"visit_count":20,"comment_count":3,"follower_count":4,"relationship":{"is_following":true},"author":{"id":"owner","url_token":"owner","name":"提问者","headline":"","avatar_url":"https://pic.zhimg.com/owner.jpg"},"topics":[{"id":"9","name":"iOS","url":"https://www.zhihu.com/topic/9"}]}"#.utf8
    )

    static let answer = Data(
        #"{"id":42,"content":"<p>回答正文</p>","author":{"id":"member","url_token":"author","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"},"question":{"id":7,"title":"原生问题"},"attachment":null,"voteup_count":100,"favlists_count":2,"comment_count":3,"thanks_count":99,"created_time":1000,"updated_time":2000,"ip_info":"江苏","url":"https://www.zhihu.com/question/7/answer/42","reaction":{"relation":{"vote":"UP"}},"endorsements":[{"action_url":"https://www.zhihu.com/column/c_1533471233991028736","elements":[{"type":"IMAGE","image_key":"seal"},{"type":"TEXT","content":"周刊收录"},{"type":"IMAGE","image_key":"arrow"}]}]}"#.utf8
    )

    static func answerPage(next: String?) -> Data {
        let nextValue = next.map { "\"\($0)\"" } ?? "null"
        return Data(
            (#"{"data":[{"target":{"type":"answer","id":42,"excerpt":"<p>摘要</p>","voteup_count":8,"comment_count":2,"author":{"id":"member","url_token":"author","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"},"question":{"id":7,"title":"原生问题"}}}],"paging":{"is_end":false,"next":"# + nextValue + "}}").utf8
        )
    }

    static let author = QAAuthorDTO(
        memberID: "member",
        urlToken: "author",
        displayName: "作者",
        headline: "简介",
        avatarURL: URL(string: "https://pic.zhimg.com/avatar.jpg")
    )

    static let questionDTO = QuestionDTO(
        id: 7,
        title: "原生问题",
        detailHTML: "<p>问题描述</p>",
        detailBlocks: [.paragraph(UUID(), [QAInlineRun(text: "问题描述")])],
        answerCount: 1,
        visitCount: 20,
        commentCount: 3,
        followerCount: 4,
        isFollowing: false,
        author: nil,
        topics: []
    )

    static func preview(_ id: Int) -> AnswerPreviewDTO {
        AnswerPreviewDTO(
            answerID: Int64(id),
            questionID: 7,
            questionTitle: "原生问题",
            author: author,
            excerpt: "摘要",
            voteUpCount: id,
            commentCount: 1
        )
    }

    static let answerPageDTO = QuestionAnswerPageDTO(items: [preview(42)], nextURL: nil, isEnd: true)

    static let answerDTO = AnswerDTO(
        route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
        title: "原生问题",
        questionID: 7,
        author: author,
        blocks: [.paragraph(UUID(), [QAInlineRun(text: "正文")])],
        attachment: nil,
        sourceURL: URL(string: "https://www.zhihu.com/question/7/answer/42")!,
        voteUpCount: 1,
        favoriteCount: 0,
        commentCount: 0,
        voteState: .neutral,
        favoriteState: .unknown,
        createdTimeSeconds: 1,
        updatedTimeSeconds: 1,
        ipLocation: nil,
        invitationPreface: nil,
        endorsements: []
    )
}

private final class QARequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [URLRequest] = []
    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func record(_ request: URLRequest) {
        let captured = URLRequestBodyCapture.capture(request)
        lock.lock(); value.append(captured); lock.unlock()
    }
}

private final class QAURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    private static let lock = NSLock()
    private static var handler: Handler?

    static func setHandler(_ value: Handler?) {
        lock.lock(); handler = value; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: QAStubError.failed)
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class QAAccountStore: AccountJSONStore, @unchecked Sendable {
    private let lock = NSLock()
    private var json: String?
    init(json: String? = #"{"cookies":{"d_c0":"device","z_c0":"login"},"userAgent":"qa-test"}"#) {
        self.json = json
    }
    func load() throws -> String? { lock.lock(); defer { lock.unlock() }; return json }
    func save(_ value: String) throws { lock.lock(); json = value; lock.unlock() }
    func clear() throws { lock.lock(); json = nil; lock.unlock() }
    func update(_ transform: (String?) throws -> String?) throws {
        lock.lock(); defer { lock.unlock() }
        json = try transform(json)
    }
}

private enum QAStubError: LocalizedError { case failed; var errorDescription: String? { "测试失败" } }

private final class StubQuestionAnswerRepository: QuestionAnswerRepository, @unchecked Sendable {
    var questionResult: Result<QuestionDTO, Error> = .failure(QAStubError.failed)
    var answerPageResults: [Result<QuestionAnswerPageDTO, Error>] = []
    var answerResult: Result<AnswerDTO, Error> = .failure(QAStubError.failed)

    func fetchQuestion(_ route: QuestionRouteDTO) async throws -> QuestionDTO { try questionResult.get() }
    func fetchQuestionAnswers(questionID: Int64, sort: QuestionAnswerSort, after nextURL: URL?) async throws -> QuestionAnswerPageDTO {
        guard !answerPageResults.isEmpty else { return QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true) }
        return try answerPageResults.removeFirst().get()
    }
    func setQuestionFollowing(_ following: Bool, questionID: Int64) async throws {}
    func fetchAnswer(_ route: AnswerRouteDTO) async throws -> AnswerDTO { try answerResult.get() }
    func setVote(_ state: QAVoteState, route: AnswerRouteDTO) async throws -> QAVoteMutationResult {
        QAVoteMutationResult(state: state, voteUpCount: 1)
    }
    func fetchCollections(route: AnswerRouteDTO) async throws -> QACollectionsResult {
        QACollectionsResult(items: [], favoriteState: .notFavorited)
    }
    func setCollection(_ selected: Bool, collectionID: String, route: AnswerRouteDTO) async throws {}
}

private actor StubOpenedHistory: AnswerOpenedHistory {
    var opened: Set<Int64>
    init(opened: Set<Int64> = []) { self.opened = opened }
    func openedAnswerIDs(questionID: Int64) -> Set<Int64> { opened }
    func markOpened(answerID: Int64, questionID: Int64) { opened.insert(answerID) }
}
