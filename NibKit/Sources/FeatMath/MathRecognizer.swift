import Foundation
import UIKit
import Vision
import NibContracts

/// Deliberately conservative fallback for Vision's plain text. It never pretends to be a symbolic OCR model.
enum MathNormalizer {
    static func line(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("\\") { return text }
        let substitutions = ["−": "-", "–": "-", "×": "\\times ", "·": "\\cdot ", "÷": "\\div ",
                             "≤": "\\leq ", "≥": "\\geq ", "≠": "\\neq ", "π": "\\pi ", "∞": "\\infty "]
        let superscripts: [Character: String] = ["⁰":"0", "¹":"1", "²":"2", "³":"3", "⁴":"4", "⁵":"5", "⁶":"6",
                                                   "⁷":"7", "⁸":"8", "⁹":"9", "⁻":"-", "⁺":"+", "ⁿ":"n"]
        var output = "", power = ""
        func flush() { if !power.isEmpty { output += "^{" + power + "}"; power = "" } }
        for character in text {
            if let digit = superscripts[character] { power += digit }
            else { flush(); output.append(character) }
        }
        flush()
        text = output
        for (from, to) in substitutions { text = text.replacingOccurrences(of: from, with: to) }
        text = text.replacingOccurrences(of: #"\^(-?\d+|[a-zA-Z])"#, with: "^{$1}", options: .regularExpression)
        // Only simple atoms or explicitly grouped terms are unambiguous slash fractions.
        if text.range(of: #"/\s*(?:\\[a-zA-Z]+|[a-zA-Z]+|\d+(?:\.\d+)?)\s*/"#, options: .regularExpression) != nil {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: #"(?<![\\\w}./])(\d*\\[a-zA-Z]+|[a-zA-Z]+|\d+(?:\.\d+)?|\([^()]+\))\s*/\s*(\d*\\[a-zA-Z]+|[a-zA-Z]+|\d+(?:\.\d+)?|\([^()]+\))(?![\w./])"#,
                                        with: #"\\frac{$1}{$2}"#, options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lines(_ input: [String]) -> [String] {
        let nonempty = input.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var out: [String] = [], index = 0
        while index < nonempty.count {
            if index + 2 < nonempty.count, nonempty[index + 1].range(of: #"^[-−―_—–]+$"#, options: .regularExpression) != nil {
                out.append("\\frac{" + line(nonempty[index]) + "}{" + line(nonempty[index + 2]) + "}")
                index += 3
            } else { out.append(line(nonempty[index])); index += 1 }
        }
        return out
    }
}

struct MathRecognition: Codable {
    var lines: [String]
    var source: String
    var warning: String?
    var revs: [Rev]? = nil
}

@MainActor
enum MathRecognizer {
    static func recognize(_ selection: MathSelection, _ ctx: CommandContext) async throws -> MathRecognition {
        let region = selection.bounds
        let pageRef = NodeRef.page(selection.doc, selection.page).description
        let layers = Set(selection.items.map(\.layer))
        let result = try await ctx.execute(CommandIDs.renderPage,
                                          ["page": .string(pageRef), "region": try JSONValue.from([region.x, region.y, region.width, region.height]), "background": true, "layers": try JSONValue.from(layers.sorted())])
        guard let name = result["asset"]?.stringValue else { throw NibError(.internalError, "render.page returned no image") }
        let url = try await ctx.inputFile(name)
        let image = try await Task.detached(priority: .userInitiated) {
            guard let loaded = UIImage(contentsOfFile: url.path)?.cgImage else { throw NibError(.internalError, "The selection image could not be read") }
            return loaded
        }.value
        let asset = AssetRef(name.hasPrefix("tmp:") ? String(name.dropFirst(4)) : name)
        try Task.checkCancellation()
        var warning: String?
        if let ai = ctx.services.ai, ai.isConfigured, ai.supportsVision {
            do {
                let request = AIRequest(system: "Transcribe only the selected handwritten mathematics. Return JSON {\"lines\":[\"LaTeX\"]}, one entry per line. Do not solve, explain or call tools.",
                                        messages: [AIMessage(role: "user", text: "Convert this handwriting to LaTeX.", images: [asset])],
                                        tools: [], mode: .ask,
                                        scope: AIScope(kind: .selection, doc: selection.doc, page: selection.page, refs: selection.refs),
                                        principal: ctx.principal, maxSteps: 1, jsonOutput: true)
                let response = try await ai.complete(request)
                try Task.checkCancellation()
                struct Response: Decodable { var lines: [String] }
                let parsed = try JSONValue.parse(response.text).decode(Response.self)
                try await Task.detached(priority: .userInitiated) { try MathTypesetter.shared.validate(parsed.lines) }.value
                return MathRecognition(lines: parsed.lines, source: "ai", warning: nil, revs: selection.items.map(\.rev))
            } catch is CancellationError { throw CancellationError() }
            catch { warning = String(localized: "Your provider could not recognise this selection. Check the on-device result before converting.") }
        }
        let text: [String]
        if let recognizer = ctx.services.recognizer {
            text = try await recognizer.recognize(image: image, language: "en-US").map(\.text)
        } else {
            text = try await Task.detached(priority: .userInitiated) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                return (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                    .compactMap { $0.topCandidates(1).first?.string }
            }.value
        }
        try Task.checkCancellation()
        let lines = MathNormalizer.lines(text)
        guard !lines.isEmpty else {
            throw NibError(.unavailable, String(localized: "No maths was recognised. Try selecting a clearer equation."),
                           hint: "call math.convert with explicit latex, or edit the LaTeX in the preview")
        }
        try await Task.detached(priority: .userInitiated) { try MathTypesetter.shared.validate(lines) }.value
        return MathRecognition(lines: lines, source: "offline", warning: warning ?? String(localized: "On-device recognition handles simple maths. Check each line before converting."), revs: selection.items.map(\.rev))
    }
}
