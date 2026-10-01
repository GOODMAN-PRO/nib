import Foundation
import NibContracts

enum MathMode: String, Codable, CaseIterable { case solve, teach }
enum MathAction: String, Codable {
    case recognize, solve, approach, hint, skip, reveal, expand, check, explain, alternative, edit
}

struct MathStep: Codable, Equatable {
    var title: String
    var detail: String
}

struct MathPlan: Codable, Equatable {
    var steps: [MathStep] = []
    var hints: [String] = []
    var answer: String

    static func parse(_ text: String, mode: MathMode) throws -> MathPlan {
        guard text.utf8.count <= 131_072 else { throw protocolError() }
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("```json\n"), raw.hasSuffix("```") {
            raw = String(raw.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if raw.hasPrefix("```\n"), raw.hasSuffix("```") {
            raw = String(raw.dropFirst(4).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let json = try? JSONValue.parse(raw), let answer = json["answer"]?.stringValue,
              validText(answer) else { throw protocolError() }
        switch mode {
        case .solve:
            guard let rows = json["steps"]?.arrayValue, !rows.isEmpty, rows.count <= 40 else { throw protocolError() }
            let steps = try rows.map { row -> MathStep in
                guard let title = row["title"]?.stringValue, let detail = row["detail"]?.stringValue,
                      validText(title), validText(detail) else { throw protocolError() }
                return MathStep(title: title, detail: detail)
            }
            return MathPlan(steps: steps, answer: answer)
        case .teach:
            guard let rows = json["hints"]?.arrayValue, !rows.isEmpty, rows.count <= 40 else { throw protocolError() }
            let hints = try rows.map { row -> String in
                guard let hint = row.stringValue, validText(hint) else { throw protocolError() }
                return hint
            }
            return MathPlan(hints: hints, answer: answer)
        }
    }

    static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 16_384
    }

    static func protocolError() -> NibError {
        NibError(.invalidParams, String(localized: "The AI response did not contain a valid maths explanation."),
                 path: "$.response", hint: "Retry math.solve; expected {steps:[{title,detail}],answer} or {hints:[string],answer}.")
    }
}

enum MathVerification: String, Codable { case verified, mismatch, unverified, symbolic }

struct MathSession: Codable, Equatable {
    var equations: [String] = []
    var mode: MathMode = .solve
    var plan: MathPlan?
    var approach: String = ""
    var hintCount: Int = 0
    var revealed: Bool = false
    var expanded: [Int] = []
    var verification: MathVerification = .unverified
    var feedback: String?
    var teacherRef: String?
    var teacherHints: [String] = []
    var skipped: Int = 0
    var teacherHintCount: Int?
    var recognitionSource: String?
    var recognitionWarning: String?
}

enum MathTutor {
    static let approaches = ["Understand the idea", "Work step by step", "Try it yourself"]

    /// F099 stores its AnswerZone record in CustomItem.data.
    static func teacherHints(_ node: JSONValue) throws -> (hints: [String], revealed: Int) {
        let item = node["custom"] ?? node
        guard item["owner"]?.stringValue == "nib.answerZone", item["type"]?.stringValue == "zone",
              let data = item["data"], let rows = data["hints"]?.arrayValue,
              rows.count <= 40, rows.allSatisfy({ $0.stringValue.map(MathPlan.validText) == true }) else {
            throw NibError.unsupported("This item does not expose teacher-owned answer-zone hints through query.get")
        }
        let count = data["revealed"]?.intValue ?? 0
        return (rows.compactMap(\.stringValue), min(rows.count, max(0, count)))
    }

    /// Local presentation transitions remain callable through math.solve by every principal.
    static func transition(_ action: MathAction, state: MathSession, index: Int? = nil,
                           approach: String? = nil) throws -> MathSession {
        var next = state
        switch action {
        case .approach:
            guard let approach, approaches.contains(approach) else {
                throw NibError.invalid("Choose a tutoring approach.", path: "$.approach")
            }
            next.approach = approach
            next.plan = nil
            next.hintCount = 0
            next.revealed = false
        case .hint, .skip:
            let count = state.plan?.hints.count ?? state.teacherHints.count
            guard count > 0 else { throw NibError.invalid("Request a lesson before revealing a hint.", path: "$.state") }
            next.hintCount = min(count, max(0, state.hintCount) + 1)
            if action == .skip { next.skipped += 1 }
        case .reveal:
            guard state.plan != nil else { throw NibError.invalid("Request a solution first.", path: "$.state") }
            next.revealed = true
        case .expand:
            guard let index, let steps = state.plan?.steps, steps.indices.contains(index) else {
                throw NibError.invalid("Choose an existing step.", path: "$.index")
            }
            if next.expanded.contains(index) { next.expanded.removeAll { $0 == index } }
            else { next.expanded.append(index) }
        case .edit:
            next.plan = nil
            next.revealed = false
            next.hintCount = 0
            next.expanded = []
            next.feedback = nil
            next.verification = .unverified
        default: throw NibError.invalid("This action needs the maths service.", path: "$.action")
        }
        return next
    }

    /// Parse one numeric term; lists of roots are parsed by numericTerms.
    static func numericAnswer(_ answer: String) -> (variable: String?, value: Double)? {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\\("), text.hasSuffix("\\)") { text = String(text.dropFirst(2).dropLast(2)) }
        if text.hasPrefix("$"), text.hasSuffix("$") { text = String(text.dropFirst().dropLast()) }
        let parts = text.components(separatedBy: "=")
        guard parts.count <= 2 else { return nil }
        var variable: String?
        if parts.count == 2 {
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[a-zA-Z]$", options: .regularExpression) != nil else { return nil }
            variable = name
            text = parts[1]
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.range(of: #"^\\frac\{[+-]?[0-9]+(?:\.[0-9]+)?\}\{[+-]?[0-9]+(?:\.[0-9]+)?\}$"#, options: .regularExpression) {
            let fractionText = String(text[match]).replacingOccurrences(of: "\\frac{", with: "")
                .replacingOccurrences(of: "}{", with: "/").replacingOccurrences(of: "}", with: "")
            text = fractionText
        }
        if let value = Double(text), value.isFinite { return (variable, value) }
        let fraction = text.components(separatedBy: "/")
        if fraction.count == 2, let a = Double(fraction[0]), let b = Double(fraction[1]), b != 0,
           (a / b).isFinite { return (variable, a / b) }
        return nil
    }

    static func scalar(_ result: JSONValue) -> Double? {
        let value = result.doubleValue ?? result["value"]?.doubleValue ?? result["result"]?.doubleValue
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func assignments(_ answer: String) -> [String: Double]? {
        let parts = answer.components(separatedBy: ",")
        guard !parts.isEmpty, parts.count <= 10 else { return nil }
        var values: [String: Double] = [:]
        for part in parts {
            guard let parsed = numericAnswer(part), let variable = parsed.variable, values[variable] == nil else { return nil }
            values[variable] = parsed.value
        }
        return values
    }

    static func numericValue(_ answer: String) -> JSONValue? {
        if let scalar = numericAnswer(answer), scalar.variable == nil { return .number(scalar.value) }
        guard let value = try? JSONValue.parse(answer), isNumeric(value) else { return nil }
        return value
    }

    static func isNumeric(_ value: JSONValue, depth: Int = 0) -> Bool {
        if let number = value.doubleValue { return number.isFinite }
        guard depth < 4, let rows = value.arrayValue, !rows.isEmpty, rows.count <= 100 else { return false }
        return rows.allSatisfy { isNumeric($0, depth: depth + 1) }
    }

    struct NumericTerm {
        var variable: String?
        var value: Double
        var tolerance: Double
    }

    /// Integers and fractions are exact; decimals specify rounding to their last written place.
    static func precision(_ text: String) -> Double {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.contains("/"), !raw.contains("\\frac"),
              let number = Double(raw), number.isFinite else { return 0 }
        let parts = raw.lowercased().components(separatedBy: "e")
        let exponent = parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
        guard let dot = parts[0].firstIndex(of: ".") else { return 0 }
        let places = parts[0].distance(from: parts[0].index(after: dot), to: parts[0].endIndex)
        let tolerance = 0.5 * pow(10, Double(exponent - places))
        return tolerance.isFinite ? tolerance : 0
    }

    static func numericTerms(_ answer: String) -> [NumericTerm]? {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\\("), text.hasSuffix("\\)") { text = String(text.dropFirst(2).dropLast(2)) }
        if text.hasPrefix("$"), text.hasSuffix("$") { text = String(text.dropFirst().dropLast()) }
        text = text.replacingOccurrences(of: #"\s+or\s+"#, with: ",", options: .regularExpression)
        let parts = text.components(separatedBy: ",")
        guard parts.count <= 100 else { return nil }
        var terms: [NumericTerm] = []
        for part in parts {
            guard let parsed = numericAnswer(part) else { return nil }
            let digits = part.components(separatedBy: "=").last ?? part
            terms.append(NumericTerm(variable: parsed.variable, value: parsed.value, tolerance: precision(digits)))
        }
        return terms.isEmpty ? nil : terms
    }

    static func equalValues(_ a: JSONValue, _ b: JSONValue, candidateText: String = "", exact: Bool = true) -> Bool {
        let regex = try? NSRegularExpression(pattern: #"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?"#)
        let range = NSRange(candidateText.startIndex..., in: candidateText)
        var tolerances = regex?.matches(in: candidateText, range: range).compactMap { match in
            Range(match.range, in: candidateText).map { precision(String(candidateText[$0])) }
        } ?? []
        // Fractions are exact, including decimal numerators and denominators.
        if candidateText.contains("/") || candidateText.contains("\\frac") { tolerances = [] }
        var index = 0
        func compare(_ x: JSONValue, _ y: JSONValue) -> Bool {
            if let lhs = x.doubleValue, let rhs = y.doubleValue {
                defer { index += 1 }
                let tolerance = index < tolerances.count ? tolerances[index] : 0
                return close(lhs, rhs, tolerance: tolerance, exact: exact)
            }
            guard let xs = x.arrayValue, let ys = y.arrayValue, xs.count == ys.count else { return false }
            return zip(xs, ys).allSatisfy { compare($0, $1) }
        }
        return compare(a, b)
    }

    static func close(_ a: Double, _ b: Double, tolerance: Double = 0, exact: Bool = true) -> Bool {
        abs(a - b) <= tolerance + (exact ? 1e-9 : 1e-6) * max(1, abs(a), abs(b))
    }

    static func spoken(_ latex: String) -> String {
        var text = latex
        let replacements = [(#"\frac"#, " fraction "), (#"\sqrt"#, " square root "),
                            (#"\times"#, " times "), (#"\cdot"#, " times "), (#"\div"#, " divided by "),
                            (#"\int"#, " integral "), (#"\pi"#, " pi "), (#"\infty"#, " infinity "),
                            (#"\approx"#, " approximately equals "), ("=", " equals "),
                            ("^", " to the power of "), ("+", " plus "), ("-", " minus ")]
        for (command, phrase) in replacements { text = text.replacingOccurrences(of: command, with: phrase) }
        text = text.replacingOccurrences(of: #"\\[a-zA-Z]+"#, with: " ", options: .regularExpression)
        for delimiter in ["{", "}", "$", #"\("#, #"\)"#] { text = text.replacingOccurrences(of: delimiter, with: " ") }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
