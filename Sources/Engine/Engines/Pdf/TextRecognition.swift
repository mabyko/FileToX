// On-device text recognition (OCR) with Apple's Vision framework, for the pages of a PDF that have no text to extract:
// scans, and through PDF also pictures (PDF → TXT reads its pages, see PdfDocumentReader.readText).

import CoreGraphics
import Foundation
import Vision

enum TextRecognition {
    /// A recognized line: its words in reading order, each with its box (normalized to the image, origin lower left).
    typealias Line = [(text: String, box: CGRect)]

    /// Vision reads with the script model of the first language only, and its Chinese, Japanese and Korean models also read
    /// Latin text while the Latin one cannot read theirs: the user's languages Vision supports, those first, English last.
    /// Automatic detection is not used: its first use took 20–40 s per model, and it read a mostly English page's Korean
    /// line as Latin letters.
    static let userLanguages = languages(Locale.preferredLanguages, supported: request(nil).supportedRecognitionLanguages)

    static func languages(_ preferred: [String], supported: [Locale.Language]) -> [Locale.Language] {
        func key(_ language: Locale.Language) -> (code: String?, script: String?) {
            let full = Locale.Language(identifier: language.maximalIdentifier)
            return (full.languageCode?.identifier, full.script?.identifier)
        }
        var chosen: [Locale.Language] = []
        for identifier in preferred + ["en-US"] {
            let wanted = key(Locale.Language(identifier: identifier))
            if let match = supported.first(where: { key($0) == wanted }), !chosen.contains(match) { chosen.append(match) }
        }
        let cjk: Set = ["Hans", "Hant", "Jpan", "Kore"]
        return chosen.filter { cjk.contains(key($0).script ?? "") } + chosen.filter { !cjk.contains(key($0).script ?? "") }
    }

    private static func request(_ languages: [Locale.Language]?) -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Measured on 200–300 dpi pages: the default, 1/32 of the image height, garbled 6–8 pt text, and 0.005 or less
        // misread 11 pt text of an upscaled scan; 0.01 read both.
        request.minimumTextHeightFraction = 0.01
        if let languages { request.recognitionLanguages = languages }
        return request
    }

    /// The lines of text in `image`, and whether the page lies on its side. Vision also reads a page turned by 90°, 180° or
    /// 270°, and each line's corners follow its text: most of the text decides the page's turn, and the boxes are given
    /// as on the page turned upright (`sideways`: its width and height are the image's height and width). Words are the
    /// line's text split at spaces, so a word and its particle ("English가") stay together.
    static func lines(in image: CGImage, languages: [Locale.Language] = userLanguages) async throws -> (lines: [Line], sideways: Bool) {
        try Task.checkCancellation()
        let observations = try await request(languages).perform(on: image)
        try Task.checkCancellation()
        let read = observations.compactMap { observation in observation.topCandidates(1).first.map { (observation, $0) } }
        var votes = [0, 0, 0, 0]
        for (observation, best) in read {
            let (from, to) = (observation.bottomLeft.cgPoint, observation.bottomRight.cgPoint)
            votes[quarterTurns((to.x - from.x) * CGFloat(image.width), (to.y - from.y) * CGFloat(image.height))] += best.string.count
        }
        let turns = votes.firstIndex(of: votes.max()!)!
        return (read.compactMap { observation, best -> Line? in
            let text = best.string, line = upright(observation.boundingBox.cgRect, turns)
            var words: Line = []
            var index = text.startIndex
            for word in text.split(whereSeparator: \.isWhitespace) {
                guard let range = text.range(of: word, range: index..<text.endIndex) else { continue }
                index = range.upperBound
                // Without a box of its own, a word gets its share of the line by its place in the text.
                let share = { (at: String.Index) in line.minX + line.width * CGFloat(text.distance(from: text.startIndex, to: at))
                    / CGFloat(max(1, text.count)) }
                let box = (best.boundingBox(for: range)?.boundingBox.cgRect).map { upright($0, turns) }
                    ?? CGRect(x: share(range.lowerBound), y: line.minY, width: share(range.upperBound) - share(range.lowerBound), height: line.height)
                words.append((String(word), box))
            }
            return words.isEmpty ? nil : words
        }, turns % 2 == 1)
    }

    /// The quarter turns (counter-clockwise) of a text direction: 0 runs right, 1 up, 2 left, 3 down.
    static func quarterTurns(_ dx: CGFloat, _ dy: CGFloat) -> Int {
        abs(dx) >= abs(dy) ? (dx >= 0 ? 0 : 2) : (dy >= 0 ? 1 : 3)
    }

    /// A normalized box of a page turned by `turns` quarter turns, on the page turned back upright.
    static func upright(_ box: CGRect, _ turns: Int) -> CGRect {
        switch turns {
        case 1: CGRect(x: box.minY, y: 1 - box.maxX, width: box.height, height: box.width)
        case 2: CGRect(x: 1 - box.maxX, y: 1 - box.maxY, width: box.width, height: box.height)
        case 3: CGRect(x: 1 - box.maxY, y: box.minX, width: box.height, height: box.width)
        default: box
        }
    }
}
