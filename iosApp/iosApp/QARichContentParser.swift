import Foundation

/// Projects Zhihu's HTML into the immutable block vocabulary consumed by SwiftUI.
/// Unknown tags retain their text instead of becoming tappable or being flattened into a WebView.
enum QARichContentParser {
    static func blocks(from html: String) -> [QABodyBlock] {
        var parser = Parser(html: html)
        let blocks = parser.parse()
        if !blocks.isEmpty { return blocks }
        let fallback = plainText(html)
        return fallback.isEmpty ? [] : [.paragraph(UUID(), [QAInlineRun(text: fallback)])]
    }

    static func plainText(_ html: String) -> String {
        html
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(
                of: "(?i)</(?:p|div|li|h[1-6]|blockquote|pre|figure)>",
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(of: "(?s)<[^>]*>", with: "", options: .regularExpression)
            .decodedHTMLEntities
            .replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Parser {
        let html: String
        var blocks: [QABodyBlock] = []
        var runs: [QAInlineRun] = []
        var style: QAInlineStyle = []
        var links: [QALinkDestination] = []
        var currentBlock: BlockContext = .paragraph
        var listStack: [ListContext] = []
        var segmentID: String?
        var spanSegmentScopes: [Bool] = []
        var spanFormulaScopes: [Bool] = []
        var formulaSpanDepth = 0
        var preformatted = false
        var preLanguage: String?
        var ignoreDepth = 0
        var figureImageIndex: Int?
        var caption = ""
        var capturingCaption = false
        var videoBox: VideoBoxContext?

        mutating func parse() -> [QABodyBlock] {
            let expression = try? NSRegularExpression(pattern: "(?s)<[^>]*>|[^<]+")
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in expression?.matches(in: html, range: range) ?? [] {
                guard let tokenRange = Range(match.range, in: html) else { continue }
                consume(String(html[tokenRange]))
            }
            while !listStack.isEmpty { finishList() }
            flushBlock()
            return blocks
        }

        mutating func consume(_ token: String) {
            guard token.hasPrefix("<") else {
                guard ignoreDepth == 0 else { return }
                guard formulaSpanDepth == 0 else { return }
                let value = decodeText(token, preserveWhitespace: preformatted)
                if capturingCaption { caption += value; return }
                appendText(value)
                return
            }
            let tag = HTMLTag(token)
            guard !tag.name.isEmpty else { return }
            if tag.name == "noscript" {
                ignoreDepth += tag.isClosing ? -1 : 1
                ignoreDepth = max(0, ignoreDepth)
                return
            }
            guard ignoreDepth == 0 else { return }
            tag.isClosing ? close(tag) : open(tag)
        }

        mutating func open(_ tag: HTMLTag) {
            switch tag.name {
            case "p": startBlock(.paragraph, segment: tag.segmentID)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                startBlock(.heading(Int(tag.name.dropFirst()) ?? 2), segment: tag.segmentID)
            case "blockquote": startBlock(.quote, segment: tag.segmentID)
            case "pre":
                flushBlock()
                preformatted = true
                preLanguage = tag.attributes["data-language"]
                currentBlock = .code
            case "ul": startList(.unordered, startIndex: 1)
            case "ol": startList(
                .ordered,
                startIndex: tag.attributes["start"].flatMap(Int.init) ?? 1
            )
            case "li": startListItem()
            case "strong", "b": style.insert(.strong)
            case "em", "i": style.insert(.emphasis)
            case "s", "del": style.insert(.strikethrough)
            case "code":
                if preformatted {
                    preLanguage = preLanguage ?? tag.attributes["class"]?.replacingOccurrences(of: "language-", with: "")
                } else {
                    style.insert(.code)
                }
            case "a":
                if tag.attributes["class"]?.contains("video-box") == true,
                   let context = videoBoxContext(tag) {
                    flushBlock()
                    videoBox = context
                } else if let href = tag.attributes["href"], let destination = resolveLink(href) {
                    links.append(destination)
                }
            case "br": appendText("\n")
            case "hr":
                flushBlock()
                blocks.append(.divider(UUID()))
            case "figure":
                flushBlock()
                figureImageIndex = nil
                caption = ""
            case "figcaption": capturingCaption = true
            case "img": appendImageOrFormula(tag)
            case "span":
                if let segment = tag.segmentID {
                    flushBlock()
                    segmentID = segment
                    currentBlock = .paragraph
                    spanSegmentScopes.append(true)
                } else {
                    spanSegmentScopes.append(false)
                }
                let spanLatex = tag.attributes["class"]?.contains("ztext-math") == true
                    ? (tag.attributes["data-tex"] ?? tag.attributes["data-formula"])?.nilIfBlank
                    : nil
                let isFormula = spanLatex != nil
                spanFormulaScopes.append(isFormula)
                if let latex = spanLatex {
                    appendInlineFormula(latex)
                    formulaSpanDepth += 1
                }
            case "video":
                let source = tag.attributes["src"].flatMap(trustedRemoteURL)
                let poster = tag.attributes["poster"].flatMap(trustedRemoteURL)
                if let source {
                    flushBlock()
                    blocks.append(.video(UUID(), QAAttachmentVideoDTO(
                        videoID: 0,
                        thumbnailURL: poster,
                        destinationURL: nil,
                        playbackURL: source
                    )))
                }
            default: break
            }
        }

        mutating func close(_ tag: HTMLTag) {
            switch tag.name {
            case "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote":
                flushBlock()
                segmentID = nil
                // Invalid upstream markup must not let a missing formula-span
                // close tag suppress all text in the following block.
                formulaSpanDepth = 0
            case "pre":
                flushBlock()
                preformatted = false
                preLanguage = nil
                currentBlock = .paragraph
            case "ul", "ol": finishList()
            case "li": finishListItem()
            case "strong", "b": style.remove(.strong)
            case "em", "i": style.remove(.emphasis)
            case "s", "del": style.remove(.strikethrough)
            case "code": if !preformatted { style.remove(.code) }
            case "a":
                if let video = videoBox {
                    blocks.append(.video(UUID(), QAAttachmentVideoDTO(
                        videoID: video.videoID,
                        thumbnailURL: video.thumbnailURL,
                        destinationURL: video.destinationURL
                    )))
                    videoBox = nil
                } else if !links.isEmpty {
                    links.removeLast()
                }
            case "span":
                if spanFormulaScopes.popLast() == true {
                    formulaSpanDepth = max(0, formulaSpanDepth - 1)
                }
                if spanSegmentScopes.popLast() == true {
                    flushBlock()
                    segmentID = nil
                }
            case "figcaption": capturingCaption = false
            case "figure": applyCaptionToFigureImage()
            default: break
            }
        }

        mutating func startBlock(_ block: BlockContext, segment: String?) {
            if !listStack.isEmpty {
                appendListLineBreakIfNeeded()
                return
            }
            flushBlock()
            currentBlock = block
            segmentID = segment
        }

        mutating func startList(_ kind: QAListKind, startIndex: Int) {
            if listStack.isEmpty {
                flushBlock()
            }
            listStack.append(ListContext(kind: kind, startIndex: startIndex))
        }

        mutating func finishList() {
            guard !listStack.isEmpty else { return }
            finishListItem()
            let completed = listStack.removeLast()
            guard !completed.items.isEmpty else { return }
            let group = QAListGroup(
                kind: completed.kind,
                startIndex: completed.startIndex,
                items: completed.items
            )
            guard !listStack.isEmpty else {
                blocks.append(.list(UUID(), kind: group.kind, items: group.items))
                return
            }
            attachNestedList(group)
        }

        mutating func startListItem() {
            guard !listStack.isEmpty else {
                startList(.unordered, startIndex: 1)
                return startListItem()
            }
            finishListItem()
            listStack[listStack.count - 1].hasOpenItem = true
        }

        mutating func finishListItem() {
            guard !listStack.isEmpty else { return }
            let index = listStack.count - 1
            guard listStack[index].hasOpenItem else { return }
            let normalized = normalizedRuns(listStack[index].runs) ?? []
            let nestedLists = listStack[index].nestedLists
            if !normalized.isEmpty || !nestedLists.isEmpty {
                let ordinal = listStack[index].kind == .ordered
                    ? listStack[index].startIndex + listStack[index].items.count
                    : nil
                listStack[index].items.append(
                    QAListItem(runs: normalized, ordinal: ordinal, nestedLists: nestedLists)
                )
            }
            listStack[index].runs = []
            listStack[index].nestedLists = []
            listStack[index].hasOpenItem = false
        }

        mutating func attachNestedList(_ group: QAListGroup) {
            let parentIndex = listStack.count - 1
            if listStack[parentIndex].hasOpenItem {
                listStack[parentIndex].nestedLists.append(group)
            } else if !listStack[parentIndex].items.isEmpty {
                let lastIndex = listStack[parentIndex].items.count - 1
                let last = listStack[parentIndex].items[lastIndex]
                listStack[parentIndex].items[lastIndex] = QAListItem(
                    id: last.id,
                    runs: last.runs,
                    ordinal: last.ordinal,
                    nestedLists: last.nestedLists + [group]
                )
            } else {
                // Zhihu occasionally emits `<ul><ul>…</ul></ul>`. With no
                // preceding item there is no semantic parent, so keep the
                // nested items in source order instead of dropping them.
                listStack[parentIndex].items.append(contentsOf: group.items)
            }
        }

        mutating func appendListLineBreakIfNeeded() {
            guard !listStack.isEmpty else { return }
            let index = listStack.count - 1
            guard listStack[index].hasOpenItem,
                  let last = listStack[index].runs.last,
                  !last.text.hasSuffix("\n")
            else { return }
            listStack[index].runs.append(
                QAInlineRun(text: "\n", style: style, link: links.last)
            )
        }

        mutating func appendText(_ value: String) {
            guard !value.isEmpty else { return }
            let run = QAInlineRun(text: value, style: style, link: links.last)
            if listStack.isEmpty {
                runs.append(run)
            } else {
                let index = listStack.count - 1
                if !listStack[index].hasOpenItem,
                   value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }
                if !listStack[index].hasOpenItem {
                    listStack[index].hasOpenItem = true
                }
                listStack[index].runs.append(run)
            }
        }

        mutating func appendInlineFormula(_ latex: String) {
            let run = QAInlineRun(formulaLatex: latex, style: style, link: links.last)
            if listStack.isEmpty {
                runs.append(run)
            } else {
                let index = listStack.count - 1
                if !listStack[index].hasOpenItem {
                    listStack[index].hasOpenItem = true
                }
                listStack[index].runs.append(run)
            }
        }

        mutating func flushBlock() {
            guard let normalized = normalizedRuns(), !normalized.isEmpty else {
                runs = []
                return
            }
            let id = UUID()
            if let segmentID {
                blocks.append(.segment(id, segmentID: segmentID, runs: normalized))
            } else {
                switch currentBlock {
                case .paragraph:
                    if normalized.count == 1, let latex = normalized[0].formulaLatex {
                        blocks.append(.formula(id, latex: latex))
                    } else {
                        blocks.append(.paragraph(id, normalized))
                    }
                case let .heading(level): blocks.append(.heading(id, level: level, runs: normalized))
                case .quote: blocks.append(.quote(id, normalized))
                case .code:
                    blocks.append(.code(id, language: preLanguage?.nilIfBlank, text: normalized.map(\.text).joined()))
                }
            }
            runs = []
            currentBlock = .paragraph
        }

        func normalizedRuns() -> [QAInlineRun]? {
            normalizedRuns(runs)
        }

        func normalizedRuns(_ sourceRuns: [QAInlineRun]) -> [QAInlineRun]? {
            guard !sourceRuns.isEmpty else { return nil }
            if preformatted { return sourceRuns }
            var result = sourceRuns
            while let first = result.first,
                  first.formulaLatex == nil,
                  first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.removeFirst()
            }
            while let last = result.last,
                  last.formulaLatex == nil,
                  last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.removeLast()
            }
            guard !result.isEmpty else { return nil }
            return result.enumerated().compactMap { index, run in
                if run.formulaLatex != nil { return run }
                var text = run.text.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
                if index == 0 {
                    text = text.replacingOccurrences(of: "^ +", with: "", options: .regularExpression)
                }
                if index == result.count - 1 {
                    text = text.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
                }
                guard !text.isEmpty else { return nil }
                return QAInlineRun(id: run.id, text: text, style: run.style, link: run.link)
            }
        }

        mutating func appendImageOrFormula(_ tag: HTMLTag) {
            if let latex = legacyFormulaLatex(tag) {
                appendInlineFormula(latex)
                return
            }
            if let formula = zhihuEquationFormula(tag) {
                if formula.isDisplay, listStack.isEmpty {
                    flushBlock()
                    blocks.append(.formula(UUID(), latex: formula.latex))
                } else {
                    appendInlineFormula(formula.latex)
                }
                return
            }
            let rawURL = tag.attributes["data-original"] ?? tag.attributes["data-actualsrc"] ?? tag.attributes["src"]
            guard let url = rawURL.flatMap(trustedRemoteURL) else { return }
            if videoBox != nil {
                videoBox?.thumbnailURL = url
                return
            }
            flushBlock()
            let image = QAImageDTO(
                url: url,
                altText: tag.attributes["alt"]?.nilIfBlank,
                dimensions: imageDimensions(tag)
            )
            blocks.append(.image(image))
            figureImageIndex = blocks.count - 1
        }

        private func legacyFormulaLatex(_ tag: HTMLTag) -> String? {
            let attributes = tag.attributes
            let explicitlyTagged = attributes["data-formula"] ?? attributes["data-tex"]
            if let explicitlyTagged {
                return explicitlyTagged.nilIfBlank
            }
            guard attributes["class"]?.contains("ztext-math") == true else { return nil }
            return attributes["alt"]?.nilIfBlank
        }

        private func zhihuEquationFormula(_ tag: HTMLTag) -> (latex: String, isDisplay: Bool)? {
            guard let marker = tag.attributes["eeimg"], marker == "1" || marker == "2" else {
                return nil
            }
            let candidates = [
                tag.attributes["data-original"],
                tag.attributes["data-actualsrc"],
                tag.attributes["src"],
            ].compactMap { $0 }
            guard let latex = candidates.compactMap(equationLatex).first else { return nil }
            return (latex, marker == "2")
        }

        mutating func applyCaptionToFigureImage() {
            guard let index = figureImageIndex,
                  blocks.indices.contains(index),
                  case let .image(image) = blocks[index]
            else { return }
            blocks[index] = .image(
                QAImageDTO(
                    id: image.id,
                    url: image.url,
                    caption: caption.nilIfBlank,
                    altText: image.altText,
                    dimensions: image.dimensions
                )
            )
            figureImageIndex = nil
            caption = ""
        }

        private func videoBoxContext(_ tag: HTMLTag) -> VideoBoxContext? {
            let href = tag.attributes["href"]
            let linkedURL = href.flatMap(normalizedRemoteURL)
            let targetURL = linkedURL.flatMap(unwrappedZhihuTarget) ?? linkedURL
            let targetVideoID = targetURL.flatMap(videoID)
            guard let id = targetVideoID
                ?? tag.attributes["data-lens-id"].flatMap(Int64.init)
            else { return nil }
            return VideoBoxContext(
                videoID: id,
                thumbnailURL: nil,
                destinationURL: targetURL ?? URL(string: "https://www.zhihu.com/video/\(id)")!
            )
        }

        private func imageDimensions(_ tag: HTMLTag) -> QAImageDimensions? {
            let fallbackWidth = tag.attributes["width"].flatMap(Int.init)
            let fallbackHeight = tag.attributes["height"].flatMap(Int.init)
            let preferredWidth = tag.attributes["data-rawwidth"].flatMap(Int.init) ?? fallbackWidth
            let preferredHeight = tag.attributes["data-rawheight"].flatMap(Int.init) ?? fallbackHeight
            if let preferredWidth, let preferredHeight,
               let dimensions = QAImageDimensions(width: preferredWidth, height: preferredHeight) {
                return dimensions
            }
            guard let fallbackWidth, let fallbackHeight else { return nil }
            return QAImageDimensions(width: fallbackWidth, height: fallbackHeight)
        }
    }

    private enum BlockContext {
        case paragraph
        case heading(Int)
        case quote
        case code
    }

    private struct ListContext {
        let kind: QAListKind
        let startIndex: Int
        var items: [QAListItem]
        var runs: [QAInlineRun]
        var nestedLists: [QAListGroup]
        var hasOpenItem: Bool

        init(kind: QAListKind, startIndex: Int) {
            self.kind = kind
            self.startIndex = max(1, startIndex)
            items = []
            runs = []
            nestedLists = []
            hasOpenItem = false
        }
    }

    private struct VideoBoxContext {
        let videoID: Int64
        var thumbnailURL: URL?
        let destinationURL: URL
    }

    private struct HTMLTag {
        let name: String
        let attributes: [String: String]
        let isClosing: Bool

        init(_ raw: String) {
            let trimmed = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            isClosing = trimmed.hasPrefix("/")
            let content = isClosing ? trimmed.dropFirst().trimmingCharacters(in: .whitespaces) : trimmed
            name = content.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            var parsed: [String: String] = [:]
            let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let string = String(content)
                let range = NSRange(string.startIndex..<string.endIndex, in: string)
                for match in expression.matches(in: string, range: range) {
                    guard let keyRange = Range(match.range(at: 1), in: string) else { continue }
                    let value = (2...4).compactMap { index -> String? in
                        guard match.range(at: index).location != NSNotFound,
                              let range = Range(match.range(at: index), in: string) else { return nil }
                        return String(string[range])
                    }.first ?? ""
                    parsed[String(string[keyRange]).lowercased()] = decodeText(value, preserveWhitespace: true)
                }
            }
            attributes = parsed
        }

        var segmentID: String? {
            (attributes["data-segment-id"] ?? attributes["data-seg-id"])?.nilIfBlank
        }
    }

    private static func resolveLink(_ raw: String) -> QALinkDestination? {
        let normalized = raw.hasPrefix("//") ? "https:\(raw)" : raw
        let url = normalized.hasPrefix("/")
            ? URL(string: normalized, relativeTo: URL(string: "https://www.zhihu.com"))?.absoluteURL
            : URL(string: normalized)
        return url.flatMap(QABodyLinkResolver.resolve)
    }

    private static func trustedRemoteURL(_ raw: String) -> URL? {
        let value = raw.hasPrefix("//") ? "https:\(raw)" : raw
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil
        else { return nil }
        return url
    }

    private static func normalizedRemoteURL(_ raw: String) -> URL? {
        let value: String
        if raw.hasPrefix("//") {
            value = "https:\(raw)"
        } else if raw.hasPrefix("/") {
            value = "https://www.zhihu.com\(raw)"
        } else {
            value = raw
        }
        return trustedRemoteURL(value)
    }

    private static func equationLatex(_ raw: String) -> String? {
        let value = raw.hasPrefix("//") ? "https:\(raw)" : raw
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path == "/equation",
              let host = components.host?.lowercased(),
              host == "zhihu.com" || host == "www.zhihu.com",
              let query = components.percentEncodedQuery
        else { return nil }

        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  String(pair[0]).removingPercentEncoding == "tex"
            else { continue }
            let formEncoded = String(pair[1]).replacingOccurrences(of: "+", with: "%20")
            guard let latex = formEncoded.removingPercentEncoding,
                  !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return latex
        }
        return nil
    }

    private static func unwrappedZhihuTarget(_ url: URL) -> URL? {
        guard url.host?.lowercased() == "link.zhihu.com" else { return url }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "target" })?
            .value
            .flatMap(normalizedRemoteURL)
    }

    private static func videoID(_ url: URL) -> Int64? {
        let segments = url.path.split(separator: "/")
        guard let marker = segments.firstIndex(where: { $0 == "video" || $0 == "zvideo" }),
              segments.indices.contains(marker + 1)
        else { return nil }
        return Int64(segments[marker + 1])
    }

    private static func decodeText(_ value: String, preserveWhitespace: Bool) -> String {
        let decoded = value.decodedHTMLEntities
        return preserveWhitespace ? decoded : decoded.replacingOccurrences(of: "\u{00a0}", with: " ")
    }
}

/// A dependency-free readability pass for the TeX source Zhihu embeds in HTML.
///
/// This intentionally does not claim to be a complete TeX layout engine. It
/// handles the compatibility cases supported by the upstream client (escaped
/// punctuation, spacing commands, and consecutive unbraced scripts), while
/// preserving unknown commands verbatim so richer rendering can replace it
/// without losing source information.
enum QALatexReadableText {
    static func render(_ latex: String) -> String {
        var parser = Parser(characters: Array(latex))
        return parser.renderSequence()
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        mutating func renderSequence(until terminator: Character? = nil) -> String {
            var result = ""
            while index < characters.count {
                let character = characters[index]
                if let terminator, character == terminator {
                    index += 1
                    break
                }
                switch character {
                case "\\":
                    result += renderCommand()
                case "^", "_":
                    index += 1
                    result += renderScript(isSuperscript: character == "^")
                default:
                    result.append(character)
                    index += 1
                }
            }
            return result
        }

        mutating func renderCommand() -> String {
            index += 1
            guard index < characters.count else { return "\\" }
            let character = characters[index]
            if character.isLetter {
                let start = index
                while index < characters.count, characters[index].isLetter {
                    index += 1
                }
                let command = String(characters[start..<index])
                while index < characters.count, characters[index].isWhitespace {
                    index += 1
                }
                switch command {
                case "backslash": return "\\"
                case "quad": return "\u{2003}"
                case "qquad": return "\u{2003}\u{2003}"
                default: return "\\\(command)"
                }
            }
            index += 1
            switch character {
            case "{", "}", "$", "%", "#", "&", "_": return String(character)
            case "|": return "‖"
            case " ": return " "
            case ",": return "\u{2009}"
            case ":", ">": return "\u{2005}"
            case ";": return "\u{2004}"
            default: return "\\\(character)"
            }
        }

        mutating func renderScript(isSuperscript: Bool) -> String {
            guard index < characters.count else {
                return isSuperscript ? "^" : "_"
            }
            let atom: String
            if characters[index] == "{" {
                index += 1
                atom = renderSequence(until: "}")
            } else if characters[index] == "\\" {
                atom = renderCommand()
            } else {
                atom = String(characters[index])
                index += 1
            }
            return scriptCharacters(atom, isSuperscript: isSuperscript)
                ?? "\(isSuperscript ? "^" : "_")(\(atom))"
        }

        private func scriptCharacters(_ value: String, isSuperscript: Bool) -> String? {
            let table = isSuperscript ? Self.superscriptCharacters : Self.subscriptCharacters
            var result = ""
            for character in value {
                guard let replacement = table[character] else { return nil }
                result += replacement
            }
            return result
        }

        private static let superscriptCharacters: [Character: String] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "i": "ⁱ", "j": "ʲ", "n": "ⁿ",
        ]

        private static let subscriptCharacters: [Character: String] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
            "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
            "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
            "v": "ᵥ", "x": "ₓ",
        ]
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var decodedHTMLEntities: String {
        var value = self
            .replacingOccurrences(of: "&nbsp;", with: "\u{00a0}", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
        let expression = try? NSRegularExpression(pattern: "&#(?:x([0-9A-Fa-f]+)|([0-9]+));")
        let matches = expression?.matches(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) ?? []
        for match in matches.reversed() {
            let radix = match.range(at: 1).location == NSNotFound ? 10 : 16
            let group = radix == 16 ? match.range(at: 1) : match.range(at: 2)
            guard let groupRange = Range(group, in: value),
                  let scalarValue = UInt32(value[groupRange], radix: radix),
                  let scalar = UnicodeScalar(scalarValue),
                  let matchRange = Range(match.range, in: value)
            else { continue }
            value.replaceSubrange(matchRange, with: String(Character(scalar)))
        }
        return value.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }
}
