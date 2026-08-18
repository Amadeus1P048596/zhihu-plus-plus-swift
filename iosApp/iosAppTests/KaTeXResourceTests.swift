import CryptoKit
import Foundation
import JavaScriptCore
import UIKit
import XCTest
@testable import iosApp

final class KaTeXResourceTests: XCTestCase {
    private static let officialJavaScriptSHA256 =
        "68b9115510b8cedb9909a10de7799c94c0707481296f755c0a8888cb8fcde216"
    private static let officialLicenseSHA256 =
        "766ccc1f306c885aa45542a9846bbd0a505b27a0374f146778171c2254ce18e3"
    private static let officialFontSetSHA256 =
        "06cd6df3f41a0cf18d7f581ed02ca93bb66084bcac6723d54cfbb30ddad59b09"
    private static let vendoredStyleSheetSHA256 =
        "298436a5b0801958d2db79c3cb173c24670ab8e882e83e27b8cd2a555b327a15"

    func testVendoredFilesMatchKaTeX0181AndWoff2FontSet() throws {
        let resources = sourceResourcesURL
        let script = try Data(contentsOf: resources.appendingPathComponent("katex.min.js"))
        let license = try Data(contentsOf: resources.appendingPathComponent("LICENSE"))
        let styleSheet = try Data(contentsOf: resources.appendingPathComponent("katex.min.css"))

        XCTAssertEqual(sha256(script), Self.officialJavaScriptSHA256)
        XCTAssertEqual(sha256(license), Self.officialLicenseSHA256)
        XCTAssertEqual(sha256(styleSheet), Self.vendoredStyleSheetSHA256)

        let fontDirectory = resources.appendingPathComponent("fonts", isDirectory: true)
        let fontURLs = try FileManager.default.contentsOfDirectory(
            at: fontDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "woff2" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertEqual(fontURLs.count, 20)
        XCTAssertEqual(try digest(fileSet: fontURLs, relativeTo: resources), Self.officialFontSetSHA256)
        XCTAssertFalse(String(decoding: license, as: UTF8.self).isEmpty)
        XCTAssertTrue(String(decoding: license, as: UTF8.self).contains("The MIT License"))
    }

    func testStyleSheetUsesOnlyBundledResourcesAndHasNoMissingReferences() throws {
        let resources = sourceResourcesURL
        let styleSheet = try String(
            contentsOf: resources.appendingPathComponent("katex.min.css"),
            encoding: .utf8
        )
        let references = try resourceReferences(in: styleSheet)

        XCTAssertEqual(references.count, 20)
        XCTAssertTrue(references.allSatisfy { $0.hasSuffix(".woff2") })
        XCTAssertFalse(styleSheet.contains("http://"))
        XCTAssertFalse(styleSheet.contains("https://"))
        XCTAssertFalse(styleSheet.contains("data:"))

        for reference in references {
            let resourceURL = resources.appendingPathComponent(reference)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: resourceURL.path),
                "Missing KaTeX CSS resource: \(reference)"
            )
        }
    }

    func testKaTeXDirectoryIsPreservedInApplicationBundle() throws {
        let script = try XCTUnwrap(
            Bundle.main.url(
                forResource: "katex.min",
                withExtension: "js",
                subdirectory: "KaTeXResources"
            )
        )
        let styleSheet = try XCTUnwrap(
            Bundle.main.url(
                forResource: "katex.min",
                withExtension: "css",
                subdirectory: "KaTeXResources"
            )
        )
        let font = try XCTUnwrap(
            Bundle.main.url(
                forResource: "KaTeX_Main-Regular",
                withExtension: "woff2",
                subdirectory: "KaTeXResources/fonts"
            )
        )

        XCTAssertEqual(sha256(try Data(contentsOf: script)), Self.officialJavaScriptSHA256)
        XCTAssertEqual(sha256(try Data(contentsOf: styleSheet)), Self.vendoredStyleSheetSHA256)
        XCTAssertFalse(try Data(contentsOf: font).isEmpty)
    }

    func testRendererIsOfflineOnlyAndKeepsKaTeXTrustDisabled() throws {
        let resources = sourceResourcesURL
        let page = try String(
            contentsOf: resources.appendingPathComponent("renderer.html"),
            encoding: .utf8
        )
        let script = try String(
            contentsOf: resources.appendingPathComponent("renderer.js"),
            encoding: .utf8
        )

        XCTAssertTrue(page.contains("default-src 'none'"))
        XCTAssertTrue(page.contains("script-src 'self'"))
        XCTAssertTrue(page.contains("style-src 'self'"))
        XCTAssertTrue(page.contains("font-src 'self'"))
        XCTAssertTrue(page.contains("connect-src 'none'"))
        XCTAssertTrue(page.contains("media-src 'none'"))
        XCTAssertTrue(page.contains("frame-src 'none'"))
        XCTAssertTrue(page.contains("object-src 'none'"))
        XCTAssertTrue(page.contains("base-uri 'none'"))
        XCTAssertTrue(page.contains("form-action 'none'"))
        XCTAssertFalse(page.contains("http://"))
        XCTAssertFalse(page.contains("https://"))

        XCTAssertTrue(script.contains("trust: false"))
        XCTAssertTrue(script.contains("maxExpand: 1000"))
        XCTAssertTrue(script.contains("maxSize: 100"))
        XCTAssertTrue(script.contains("throwOnError: true"))
        XCTAssertTrue(script.contains("displayMode: request.displayMode"))
        XCTAssertTrue(script.contains("baselineFromTop"))
        XCTAssertFalse(script.contains("displayMode: true"))
        XCTAssertFalse(script.contains("fetch("))
        XCTAssertFalse(script.contains("XMLHttpRequest"))
    }

    func testUntrustedKaTeXCommandsCannotCreateLinksImagesOrCustomHTML() throws {
        let link = try renderToHTML(#"\href{https://evil.example}{click}"#)
        XCTAssertTrue(link.succeeded)
        XCTAssertFalse(link.html.contains("href="))

        let image = try renderToHTML(#"\includegraphics{https://evil.example/a.png}"#)
        XCTAssertTrue(image.succeeded)
        XCTAssertFalse(image.html.contains("<img"))
        XCTAssertFalse(image.html.contains("src="))

        let customClass = try renderToHTML(#"\htmlClass{evil}{x}"#)
        XCTAssertTrue(customClass.succeeded)
        XCTAssertFalse(customClass.html.contains(#"class="evil""#))
    }

    func testMalformedAndRunawayTeXFailWithinConfiguredBounds() throws {
        let malformed = try renderToHTML(#"\frac{1}{"#)
        XCTAssertFalse(malformed.succeeded)
        XCTAssertTrue(malformed.error.contains("parse error"))

        let runaway = try renderToHTML(#"\def\x{\x}\x"#)
        XCTAssertFalse(runaway.succeeded)
        XCTAssertTrue(runaway.error.contains("Too many expansions"))
    }

    func testRenderPolicyRejectsOversizedInputAndInvalidOutput() throws {
        let oversized = QAKaTeXRenderRequest(
            latex: String(repeating: "x", count: QAKaTeXRenderPolicy.maximumLatexUTF8Bytes + 1),
            pointSize: 17,
            color: .lightForeground,
            scale: 2,
            isDarkMode: false,
            displayMode: true
        )
        XCTAssertThrowsError(try QAKaTeXRenderPolicy.validate(oversized)) { error in
            XCTAssertEqual(error as? QAKaTeXRenderError, .formulaTooLong)
        }

        XCTAssertThrowsError(
            try QAKaTeXRenderPolicy.validateOutput(
                width: QAKaTeXRenderPolicy.maximumLogicalDimension + 1,
                height: 20,
                scale: 2,
                baselineFromTop: 15
            )
        ) { error in
            XCTAssertEqual(error as? QAKaTeXRenderError, .outputTooLarge)
        }
        XCTAssertThrowsError(
            try QAKaTeXRenderPolicy.validateOutput(
                width: 100,
                height: 20,
                scale: 2,
                baselineFromTop: 21
            )
        ) { error in
            XCTAssertEqual(error as? QAKaTeXRenderError, .invalidOutput)
        }

        XCTAssertEqual(QAKaTeXRenderPolicy.cacheCountLimit, 128)
        XCTAssertEqual(QAKaTeXRenderPolicy.cacheCostLimit, 24 * 1_024 * 1_024)
        XCTAssertTrue(QAKaTeXRenderPolicy.shouldCacheImage(cost: 4_096))
        XCTAssertFalse(QAKaTeXRenderPolicy.shouldCacheImage(cost: 0))
        XCTAssertFalse(
            QAKaTeXRenderPolicy.shouldCacheImage(
                cost: QAKaTeXRenderPolicy.cacheCostLimit + 1
            )
        )
    }

    func testCacheKeySeparatesThemeColorPointSizeAndScale() {
        let baseline = renderRequest()
        XCTAssertNotEqual(baseline.cacheKey, renderRequest(pointSize: 18).cacheKey)
        XCTAssertNotEqual(baseline.cacheKey, renderRequest(scale: 3).cacheKey)
        XCTAssertNotEqual(
            baseline.cacheKey,
            renderRequest(color: .darkForeground, isDarkMode: true).cacheKey
        )
        XCTAssertNotEqual(baseline.cacheKey, renderRequest(displayMode: false).cacheKey)
    }

    func testMissingResourceIsReportedBeforeRendering() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = temporaryRoot.appendingPathComponent("MissingKaTeX.bundle", isDirectory: true)
        let resourceURL = bundleURL.appendingPathComponent("KaTeXResources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.github.kangyun1994.zhplus.katex-tests",
            "CFBundleName": "MissingKaTeX",
            "CFBundlePackageType": "BNDL",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: bundleURL.appendingPathComponent("Info.plist"))

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let missing = QAKaTeXResourceLocator.missingResources(in: bundle)
        XCTAssertTrue(missing.contains("renderer.html"))
        XCTAssertTrue(missing.contains("katex.min.js"))
        XCTAssertTrue(missing.contains("fonts/KaTeX_Main-Regular.woff2"))
    }

    @MainActor
    func testRenderServiceProducesBoundedImageAndUsesMemoryCache() async throws {
        let service = QAKaTeXRenderService(bundle: .main)
        let request = renderRequest()
        let first = try await service.render(request)
        let second = try await service.render(request)
        let firstImage = first.image
        let secondImage = second.image

        XCTAssertGreaterThan(firstImage.size.width, 0)
        XCTAssertGreaterThan(firstImage.size.height, 0)
        XCTAssertLessThanOrEqual(firstImage.size.width, QAKaTeXRenderPolicy.maximumLogicalDimension)
        XCTAssertLessThanOrEqual(firstImage.size.height, QAKaTeXRenderPolicy.maximumLogicalDimension)
        XCTAssertEqual(firstImage.scale, request.scale)
        XCTAssertGreaterThan(first.baselineFromTop, 0)
        XCTAssertLessThanOrEqual(first.baselineFromTop, firstImage.size.height)
        XCTAssertEqual(first.baselineFromTop, second.baselineFromTop)
        XCTAssertTrue(firstImage === secondImage)
        XCTAssertLessThan(try alphaAtTopLeft(of: firstImage), 16)
    }

    @MainActor
    func testInlineRenderProducesImageWithMeasuredBaseline() async throws {
        let service = QAKaTeXRenderService(bundle: .main)
        let request = renderRequest(
            latex: #"J^{PC}=0^{-+}"#,
            pointSize: 17,
            displayMode: false
        )
        let result = try await service.render(request)

        XCTAssertFalse(request.displayMode)
        XCTAssertGreaterThan(result.image.size.width, 0)
        XCTAssertGreaterThan(result.image.size.height, 0)
        XCTAssertEqual(result.image.scale, request.scale)
        XCTAssertTrue(result.baselineFromTop.isFinite)
        XCTAssertGreaterThan(result.baselineFromTop, 0)
        XCTAssertLessThan(result.baselineFromTop, result.image.size.height)

        let displayResult = try await service.render(
            renderRequest(latex: request.latex, pointSize: request.pointSize)
        )
        XCTAssertFalse(result.image === displayResult.image)
        XCTAssertEqual(displayResult.baselineFromTop, displayResult.image.size.height)
    }

    private var sourceResourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("iosApp", isDirectory: true)
            .appendingPathComponent("KaTeXResources", isDirectory: true)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func digest(fileSet urls: [URL], relativeTo root: URL) throws -> String {
        var hasher = SHA256()
        for url in urls {
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: url))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func resourceReferences(in styleSheet: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"url\((?:["']?)([^)"']+)"#)
        let range = NSRange(styleSheet.startIndex..., in: styleSheet)
        return expression.matches(in: styleSheet, range: range).compactMap { match in
            guard let swiftRange = Range(match.range(at: 1), in: styleSheet) else { return nil }
            return String(styleSheet[swiftRange])
        }
    }

    private func renderRequest(
        latex: String = #"x^2+\frac{1}{2}"#,
        pointSize: CGFloat = 17,
        color: QAKaTeXRenderColor = .lightForeground,
        scale: CGFloat = 2,
        isDarkMode: Bool = false,
        displayMode: Bool = true
    ) -> QAKaTeXRenderRequest {
        QAKaTeXRenderRequest(
            latex: latex,
            pointSize: pointSize,
            color: color,
            scale: scale,
            isDarkMode: isDarkMode,
            displayMode: displayMode
        )
    }

    private func alphaAtTopLeft(of image: UIImage) throws -> UInt8 {
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixel = try XCTUnwrap(
            cgImage.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        )
        var rgba = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: &rgba,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rgba[3]
    }

    private func renderToHTML(_ latex: String) throws -> JavaScriptRenderResult {
        let context = try XCTUnwrap(JSContext())
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }
        let script = try String(
            contentsOf: sourceResourcesURL.appendingPathComponent("katex.min.js"),
            encoding: .utf8
        )
        context.evaluateScript(script)
        XCTAssertNil(exceptionMessage)
        context.setObject(latex, forKeyedSubscript: "__testTeX" as NSString)
        let rawResult = try XCTUnwrap(
            context.evaluateScript(
                """
                JSON.stringify((function () {
                  try {
                    return {
                      succeeded: true,
                      html: katex.renderToString(__testTeX, {
                        displayMode: true,
                        throwOnError: true,
                        strict: "ignore",
                        trust: false,
                        maxExpand: 1000,
                        maxSize: 100,
                        output: "htmlAndMathml"
                      }),
                      error: ""
                    };
                  } catch (error) {
                    return {
                      succeeded: false,
                      html: "",
                      error: String(error && error.message ? error.message : error)
                    };
                  }
                })())
                """
            )?.toString()
        )
        return try JSONDecoder().decode(JavaScriptRenderResult.self, from: Data(rawResult.utf8))
    }
}

private struct JavaScriptRenderResult: Decodable {
    let succeeded: Bool
    let html: String
    let error: String
}
