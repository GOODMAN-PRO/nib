import Foundation
import NibContracts

// The on-device maths engine (F061), part 1: lexer and parser. Input is what people type (plain text with × ÷ − ² √ π)
// or the LaTeX that math.recognize (F060) returns; both become one `MathNode` tree. The overlay (F106) and graphs
// (F107) in this module reach the engine through `MathEngine` (MathEngineCommands.swift).

// MARK: - Errors

/// Every engine error is a `NibError`. Bad input and maths errors (division by zero, √ of a negative) are
/// `invalid_params`; input the evaluator cannot work out is `unsupported`, with a hint that points to AI Solve (F088).
enum MathFailure {
    static let aiSolveHint = "try AI Solve: call math.solve {latex: '…', mode: 'solve'}"

    static func syntax(_ message: String) -> NibError {
        NibError(.invalidParams, message,
                 hint: "write maths like '2(3+4)^2 =', 'x^2-5x+6=0' or LaTeX such as '\\frac{1}{2}+\\sqrt{9}'")
    }

    static func math(_ message: String) -> NibError { NibError(.invalidParams, message) }

    static func unsupported(_ what: String) -> NibError {
        NibError(.unsupported, "On-device maths can't handle \(what)", hint: aiSolveHint)
    }

    static func undefined(_ name: String) -> NibError {
        NibError(.invalidParams, "\(name) isn't defined",
                 hint: "define it on the page (e.g. '\(name) = 3') or pass it in variables")
    }

    static func undefinedFunction(_ name: String) -> NibError {
        NibError(.invalidParams, "\(name)(…) isn't defined",
                 hint: "define it on the page (e.g. '\(name)(x) = x^2') or pass it in variables")
    }
}

// MARK: - Tokens

enum MathToken: Equatable {
    case number(String)
    /// One name: a letter ("x", "π", "θ") or a function word ("sin", "sqrt", "sum").
    case word(String)
    /// Operators and brackets, normalised: "*" for × · \cdot, "/" for ÷, "-" for −, plus "∑ ∏ ∫ √ ± ° ' & _ ^".
    case symbol(String)
    /// A LaTeX construct the parser reads itself: "frac", "sqrt", "begin:pmatrix", "end:pmatrix".
    case command(String)
    /// Unicode superscripts: "x²" is x ^ "2", "A⁻¹" is A ^ "-1".
    case superscript(String)
    /// A line break or LaTeX "\\": separates the equations of a system and the rows of a matrix.
    case newline

    var display: String {
        switch self {
        case .number(let s), .word(let s), .symbol(let s), .superscript(let s): return s
        case .command(let c): return "\\" + c
        case .newline: return "line break"
        }
    }
}

// MARK: - Lexer

enum MathLexer {
    /// Function names found inside runs of letters, longest first ("sinx" is sin x); every other letter stands
    /// alone, so "xy" is x·y and "dx" is d x.
    static let functionWords = ["arcsin", "arccos", "arctan", "sqrt", "asin", "acos", "atan", "prod", "diff",
                                "sin", "cos", "tan", "abs", "det", "inv", "exp", "sum", "int", "log", "ln", "pi"]
    static let canonicalWords = ["arcsin": "asin", "arccos": "acos", "arctan": "atan", "pi": "π"]

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ",
        "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    /// Spacing, sizing and style hints ("\left" and "\right" are handled on their own).
    static let ignoredCommands: Set<String> = [
        ",", ";", ":", "!", " ", ">", "quad", "qquad", "enspace", "thinspace", "medspace", "thickspace",
        "negthinspace", "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "middle", "big", "Big",
        "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr",
    ]

    /// Wrappers whose braces are dropped so the content reads as plain maths: \mathrm{d}x, \operatorname{det}.
    static let wrapperCommands: Set<String> = [
        "mathrm", "mathbf", "mathit", "mathsf", "mathnormal", "operatorname", "text", "textrm", "textit", "textbf",
        "mbox", "boldsymbol", "bm",
    ]

    static let symbolCommands: [String: String] = [
        "cdot": "*", "times": "*", "ast": "*", "bullet": "*", "div": "/", "pm": "±", "{": "(", "}": ")",
        "lbrace": "(", "rbrace": ")", "lbrack": "[", "rbrack": "]", "%": "%", "|": "|", "vert": "|", "lvert": "|",
        "rvert": "|", "mid": "|", "sum": "∑", "prod": "∏", "int": "∫", "circ": "°", "degree": "°", "prime": "'",
    ]

    static let wordCommands: [String: String] = [
        "pi": "π", "infty": "∞", "sin": "sin", "cos": "cos", "tan": "tan", "ln": "ln", "log": "log", "det": "det",
        "exp": "exp", "arcsin": "asin", "arccos": "acos", "arctan": "atan",
    ]

    /// LaTeX the evaluator knows it cannot do, with the words used in the error.
    static let unsupportedCommands: [String: String] = [
        "lim": "limits", "to": "limits", "rightarrow": "limits", "neq": "inequalities", "ne": "inequalities",
        "leq": "inequalities", "le": "inequalities", "geq": "inequalities", "ge": "inequalities",
        "lt": "inequalities", "gt": "inequalities", "approx": "approximations", "partial": "partial derivatives",
        "nabla": "vector calculus", "cdots": "sequences with '…'", "ldots": "sequences with '…'",
        "dots": "sequences with '…'", "sinh": "hyperbolic functions", "cosh": "hyperbolic functions",
        "tanh": "hyperbolic functions", "sec": "sec, csc and cot", "csc": "sec, csc and cot",
        "cot": "sec, csc and cot", "binom": "binomial coefficients", "choose": "binomial coefficients",
        "mod": "modular arithmetic", "bmod": "modular arithmetic", "pmod": "modular arithmetic",
        "iint": "multiple integrals", "iiint": "multiple integrals", "oint": "contour integrals",
    ]

    static let superscripts: [Unicode.Scalar: String] = [
        "\u{2070}": "0", "\u{00B9}": "1", "\u{00B2}": "2", "\u{00B3}": "3", "\u{2074}": "4", "\u{2075}": "5",
        "\u{2076}": "6", "\u{2077}": "7", "\u{2078}": "8", "\u{2079}": "9", "\u{207B}": "-", "\u{207A}": "+",
    ]

    static let subscripts: [Unicode.Scalar: String] = [
        "\u{2080}": "0", "\u{2081}": "1", "\u{2082}": "2", "\u{2083}": "3", "\u{2084}": "4", "\u{2085}": "5",
        "\u{2086}": "6", "\u{2087}": "7", "\u{2088}": "8", "\u{2089}": "9",
    ]

    static func tokenize(_ source: String) throws -> [MathToken] {
        let s = Array(source.unicodeScalars)
        var tokens: [MathToken] = []
        var letters = ""
        var droppedClosers = Set<Int>()

        func flushLetters() {
            guard !letters.isEmpty else { return }
            tokens += splitLetters(letters).map { MathToken.word($0) }
            letters = ""
        }

        var i = 0
        while i < s.count {
            let c = s[i]
            if isLetter(c) {
                letters.unicodeScalars.append(c)
                i += 1
                continue
            }
            flushLetters()
            if c == "\n" || c == "\r" {
                tokens.append(.newline)
                i += 1
            } else if c.properties.isWhitespace || c == "~" {
                i += 1
            } else if isDigit(c) || (c == "." && i + 1 < s.count && isDigit(s[i + 1])) {
                var text = ""
                var seenDot = false
                while i < s.count, isDigit(s[i]) || (s[i] == "." && !seenDot) {
                    if s[i] == "." { seenDot = true }
                    text.unicodeScalars.append(s[i])
                    i += 1
                }
                tokens.append(.number(text))
            } else if c == "\\" {
                i = try readCommand(s, from: i + 1, into: &tokens, droppedClosers: &droppedClosers)
            } else if c == "}", droppedClosers.contains(i) {
                i += 1
            } else if let first = superscripts[c] {
                var text = first
                i += 1
                while i < s.count, let more = superscripts[s[i]] {
                    text += more
                    i += 1
                }
                tokens.append(.superscript(text))
            } else if let first = subscripts[c] {
                var text = first
                i += 1
                while i < s.count, let more = subscripts[s[i]] {
                    text += more
                    i += 1
                }
                tokens += [.symbol("_"), .number(text)]
            } else {
                let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
                tokens += try symbol(c, next: next)
                i += 1
            }
        }
        flushLetters()
        return mergeDegreeMarks(tokens)
    }

    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }

    static func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122)
    }

    static func isLetter(_ c: Unicode.Scalar) -> Bool {
        if isASCIILetter(c) { return true }
        switch c.value {
        case 0x3A0, 0x3A3: return false                        // Π and Σ are ∏ and ∑
        case 0x391...0x3A9, 0x3B1...0x3C9, 0x221E: return true // Greek letters and ∞
        default: return false
        }
    }

    /// "sinxy" → ["sin", "x", "y"]; "pi" → ["π"].
    static func splitLetters(_ run: String) -> [String] {
        let chars = Array(run)
        var words: [String] = []
        var i = 0
        while i < chars.count {
            var matched: String? = nil
            for name in functionWords where i + name.count <= chars.count && String(chars[i..<(i + name.count)]) == name {
                matched = name
                break
            }
            if let name = matched {
                words.append(canonicalWords[name] ?? name)
                i += name.count
            } else {
                words.append(String(chars[i]))
                i += 1
            }
        }
        return words
    }

    private static func symbol(_ c: Unicode.Scalar, next: Unicode.Scalar?) throws -> [MathToken] {
        switch c {
        case "+", "^", "_", "=", "(", ")", "[", "]", "{", "}", "|", "%", ",", ";", "&", "\u{00B1}", "\u{221A}",
             "\u{222B}", "\u{00B0}":
            return [.symbol(String(Character(c)))]
        case "-", "\u{2212}", "\u{2013}":
            return [.symbol("-")]
        case "*", "\u{00D7}", "\u{00B7}", "\u{22C5}", "\u{2219}":
            return [.symbol("*")]
        case "/", "\u{00F7}", "\u{2215}":
            return [.symbol("/")]
        case "!":
            if let n = next, n == "=" { throw MathFailure.unsupported("inequalities") }
            return [.symbol("!")]
        case "'", "\u{2032}":
            return [.symbol("'")]
        case "\u{2033}":
            return [.symbol("'"), .symbol("'")]
        case "\u{2211}", "\u{03A3}":
            return [.symbol("∑")]
        case "\u{220F}", "\u{03A0}":
            return [.symbol("∏")]
        case "<", ">", "\u{2264}", "\u{2265}", "\u{2260}", "\u{2248}":
            throw MathFailure.unsupported("inequalities")
        case "?":
            return []
        case "\u{2026}", "\u{22EF}":
            throw MathFailure.unsupported("sequences with '…'")
        default:
            throw MathFailure.syntax("I can't read '\(Character(c))'")
        }
    }

    /// Reads the LaTeX command after a backslash; returns the index just past it.
    private static func readCommand(_ s: [Unicode.Scalar], from start: Int, into tokens: inout [MathToken],
                                    droppedClosers: inout Set<Int>) throws -> Int {
        guard start < s.count else { throw MathFailure.syntax("A '\\' at the end has no command") }
        var i = start
        var name = ""
        if isASCIILetter(s[i]) {
            while i < s.count, isASCIILetter(s[i]) {
                name.unicodeScalars.append(s[i])
                i += 1
            }
        } else {
            name = String(Character(s[i]))
            i += 1
        }
        switch name {
        case "\\":
            tokens.append(.newline)
        case "left", "right":
            // "\left." is an invisible delimiter; "\left\{ … \right." wraps a system of equations.
            let j = skipSpaces(s, from: i)
            if j < s.count, s[j] == "." { return j + 1 }
            if j + 1 < s.count, s[j] == "\\", s[j + 1] == "{" || s[j + 1] == "}" { return j + 2 }
        case "begin", "end":
            guard let env = braced(s, from: i) else { throw MathFailure.syntax("\\\(name) needs an environment name") }
            i = env.next
            if name == "begin", env.text == "array", let columns = braced(s, from: i) { i = columns.next }
            tokens.append(.command(name + ":" + env.text))
        case "frac", "dfrac", "tfrac", "cfrac":
            tokens.append(.command("frac"))
        case "sqrt":
            tokens.append(.command("sqrt"))
        default:
            if ignoredCommands.contains(name) { break }
            if wrapperCommands.contains(name) {
                let j = skipSpaces(s, from: i)
                if j < s.count, s[j] == "{", let close = matchingBrace(s, from: j) {
                    droppedClosers.insert(close)
                    return j + 1
                }
                break
            }
            if let symbol = symbolCommands[name] {
                tokens.append(.symbol(symbol))
            } else if let word = wordCommands[name] ?? greek[name] {
                tokens.append(.word(word))
            } else if let what = unsupportedCommands[name] {
                throw MathFailure.unsupported(what)
            } else {
                throw MathFailure.unsupported("the LaTeX command \\\(name)")
            }
        }
        return i
    }

    private static func skipSpaces(_ s: [Unicode.Scalar], from start: Int) -> Int {
        var j = start
        while j < s.count, s[j] == " " { j += 1 }
        return j
    }

    private static func braced(_ s: [Unicode.Scalar], from start: Int) -> (text: String, next: Int)? {
        let open = skipSpaces(s, from: start)
        guard open < s.count, s[open] == "{", let close = matchingBrace(s, from: open) else { return nil }
        var text = ""
        for k in (open + 1)..<close { text.unicodeScalars.append(s[k]) }
        return (text.trimmingCharacters(in: .whitespaces), close + 1)
    }

    private static func matchingBrace(_ s: [Unicode.Scalar], from open: Int) -> Int? {
        var depth = 0
        var k = open
        while k < s.count {
            if s[k] == "\\" {
                k += 2
                continue
            }
            if s[k] == "{" { depth += 1 }
            if s[k] == "}" {
                depth -= 1
                if depth == 0 { return k }
            }
            k += 1
        }
        return nil
    }

    /// "^\circ" and "^{\circ}" are the degree sign.
    private static func mergeDegreeMarks(_ tokens: [MathToken]) -> [MathToken] {
        var out: [MathToken] = []
        var i = 0
        while i < tokens.count {
            if tokens[i] == .symbol("^") {
                if i + 1 < tokens.count, tokens[i + 1] == .symbol("°") {
                    out.append(.symbol("°"))
                    i += 2
                    continue
                }
                if i + 3 < tokens.count, tokens[i + 1] == .symbol("{"), tokens[i + 2] == .symbol("°"),
                   tokens[i + 3] == .symbol("}") {
                    out.append(.symbol("°"))
                    i += 4
                    continue
                }
            }
            out.append(tokens[i])
            i += 1
        }
        return out
    }
}

// MARK: - Syntax tree

enum MathOperator: Equatable {
    case add, subtract, multiply, divide, power
    /// The k-th ± of a statement: evaluated with + and with − for every combination of signs.
    case plusMinus(Int)
}

enum MathPostfix: Equatable { case factorial, percent, degrees }

enum MathFunction: String, Equatable {
    case sin, cos, tan, asin, acos, atan, ln, log, exp, sqrt, abs, det, inv
    /// log_b x: arguments [b, x].
    case logBase
    /// \sqrt[n]{x}: arguments [n, x].
    case root
}

indirect enum MathNode: Equatable {
    case number(Scalar)
    case variable(String)
    case negate(MathNode)
    case binary(MathOperator, MathNode, MathNode)
    case postfix(MathPostfix, MathNode)
    case function(MathFunction, [MathNode])
    /// A page function f/g/h/F/G/H; `primes` is the derivative order (f'(2), f''(1)).
    case call(String, [MathNode], primes: Int)
    case matrix([[MathNode]])
    case bigOperator(product: Bool, variable: String, from: MathNode, to: MathNode, body: MathNode)
    case integral(variable: String, from: MathNode, to: MathNode, body: MathNode)
    /// A numeric derivative at `at` (or at the variable's page value when `at` is nil).
    case derivative(variable: String, order: Int, body: MathNode, at: MathNode?)
}

/// One line: an expression to evaluate (rhs nil, also for "2+3 =") or an equation lhs = rhs.
struct MathStatement {
    var lhs: MathNode
    var rhs: MathNode?
    var plusMinusCount: Int
}

// MARK: - Parser

struct MathParser {
    static let userFunctionNames: Set<String> = ["f", "g", "h", "F", "G", "H"]
    static let functionWordSet: Set<String> = ["sin", "cos", "tan", "asin", "acos", "atan", "ln", "log", "exp",
                                               "sqrt", "abs", "det", "inv", "sum", "prod", "int", "diff"]
    static let matrixEnvironments: Set<String> = ["matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
                                                  "smallmatrix", "array"]
    static let inverseTrig = ["sin": "asin", "cos": "acos", "tan": "atan"]

    private var tokens: [MathToken]
    private var pos = 0
    /// Tokens at or after `limit` are invisible (an integral's body ends at its dx).
    private var limit: Int
    /// Open |…| bars: inside them a '|' closes rather than multiplies.
    private var absDepth = 0
    private(set) var plusMinusCount: Int

    init(tokens: [MathToken], plusMinusCount: Int = 0) {
        self.tokens = tokens
        self.limit = tokens.count
        self.plusMinusCount = plusMinusCount
    }

    // MARK: Statements

    /// Parses every line (line breaks, ';', LaTeX '\\', cases/aligned rows, and top-level commas between equations).
    static func statements(_ source: String) throws -> [MathStatement] {
        let tokens = try MathLexer.tokenize(source)
        var result: [MathStatement] = []
        for piece in split(tokens) {
            result.append(try parseStatement(piece))
        }
        return result
    }

    static func parseStatement(_ tokens: [MathToken]) throws -> MathStatement {
        var sides = splitTopLevel(tokens, at: .symbol("="))
        if sides.count > 1, sides[sides.count - 1].isEmpty { sides.removeLast() }   // "2+3 =" asks for the value
        guard sides.count <= 2 else { throw MathFailure.syntax("Use one '=' per line") }
        guard !sides[0].isEmpty else { throw MathFailure.syntax("Something is missing before '='") }
        var count = 0
        var nodes: [MathNode] = []
        for side in sides {
            var parser = MathParser(tokens: side, plusMinusCount: count)
            nodes.append(try parser.parseAll())
            count = parser.plusMinusCount
        }
        return MathStatement(lhs: nodes[0], rhs: nodes.count > 1 ? nodes[1] : nil, plusMinusCount: count)
    }

    static func split(_ tokens: [MathToken]) -> [[MathToken]] {
        // System environments (cases, aligned, an array of equations) dissolve into lines; '&' there only aligns.
        var flat: [MathToken] = []
        var matrixStack: [Bool] = []
        for (i, t) in tokens.enumerated() {
            if case .command(let c) = t, c.hasPrefix("begin:") {
                let env = String(c.dropFirst("begin:".count))
                let isMatrix = matrixEnvironments.contains(env) && !(env == "array" && arrayHoldsEquations(tokens, from: i))
                matrixStack.append(isMatrix)
                if isMatrix { flat.append(t) }
            } else if case .command(let c) = t, c.hasPrefix("end:") {
                if matrixStack.popLast() ?? true { flat.append(t) }
            } else if t == .symbol("&"), !(matrixStack.last ?? false) {
                continue
            } else {
                flat.append(t)
            }
        }
        var lines: [[MathToken]] = []
        for line in splitTopLevel(flat, at: .newline) {
            lines += splitTopLevel(line, at: .symbol(";"))
        }
        var result: [[MathToken]] = []
        for line in lines where !line.isEmpty {
            let parts = splitTopLevel(line, at: .symbol(","))
            if parts.count > 1, parts.allSatisfy({ splitTopLevel($0, at: .symbol("=")).count > 1 }) {
                result += parts.filter { !$0.isEmpty }
            } else {
                result.append(line)
            }
        }
        return result
    }

    static func splitTopLevel(_ tokens: [MathToken], at separator: MathToken) -> [[MathToken]] {
        var parts: [[MathToken]] = [[]]
        var depth = 0
        for t in tokens {
            switch t {
            case .symbol("("), .symbol("["), .symbol("{"): depth += 1
            case .symbol(")"), .symbol("]"), .symbol("}"): depth -= 1
            case .command(let c) where c.hasPrefix("begin:"): depth += 1
            case .command(let c) where c.hasPrefix("end:"): depth -= 1
            default: break
            }
            if depth == 0 && t == separator {
                parts.append([])
            } else {
                parts[parts.count - 1].append(t)
            }
        }
        return parts
    }

    private static func arrayHoldsEquations(_ tokens: [MathToken], from start: Int) -> Bool {
        var depth = 0
        for t in tokens[start...] {
            if case .command(let c) = t {
                if c.hasPrefix("begin:") {
                    depth += 1
                } else if c.hasPrefix("end:") {
                    depth -= 1
                    if depth == 0 { return false }
                }
            } else if t == .symbol("=") {
                return true
            }
        }
        return false
    }

    /// Numerals are exact: "0.1" is 1/10. Numbers too long for 64-bit fractions become decimals.
    static func number(_ text: String) throws -> Scalar {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !text.isEmpty else { throw MathFailure.syntax("'\(text)' isn't a number") }
        let whole = String(parts[0])
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        if fraction.count <= 18, let n = Int((whole.isEmpty ? "0" : whole) + fraction),
           let scale = Rational.integerPower(10, fraction.count), let r = Rational(n, scale) {
            return .exact(r)
        }
        guard let d = Double(text) else { throw MathFailure.syntax("'\(text)' isn't a number") }
        return .real(d)
    }

    static func isSingleLetter(_ word: String) -> Bool {
        word.count == 1 && word != "π" && word != "∞"
    }

    // MARK: Token access

    private func peek(_ offset: Int = 0) -> MathToken? {
        pos + offset < limit ? tokens[pos + offset] : nil
    }

    private mutating func advance() { pos += 1 }

    private mutating func take(_ symbol: String) -> Bool {
        guard peek() == .symbol(symbol) else { return false }
        pos += 1
        return true
    }

    private mutating func expect(_ symbol: String) throws {
        guard take(symbol) else {
            if let t = peek() { throw MathFailure.syntax("Expected '\(symbol)' before '\(t.display)'") }
            throw MathFailure.syntax("A '\(symbol)' is missing")
        }
    }

    // MARK: Grammar
    //   expression := term (('+' | '-' | '±') term)*
    //   term       := factor (('*' | '/' | implicit) factor)*
    //   factor     := ('-' | '+' | '±') factor | power
    //   power      := postfix ('^' exponent)?          exponents are right-associative: x^2^3 = x^(2^3)
    //   postfix    := primary ('!' | '%' | '°' | superscript)*

    mutating func parseAll() throws -> MathNode {
        let node = try parseExpression()
        if let t = peek() { throw MathFailure.syntax("Unexpected '\(t.display)'") }
        return node
    }

    private mutating func nextPlusMinus() -> Int {
        let k = plusMinusCount
        plusMinusCount += 1
        return k
    }

    private mutating func parseExpression() throws -> MathNode {
        var node = try parseTerm()
        while true {
            if take("+") {
                let rhs = try parseTerm()
                node = .binary(.add, node, rhs)
            } else if take("-") {
                let rhs = try parseTerm()
                node = .binary(.subtract, node, rhs)
            } else if take("±") {
                let k = nextPlusMinus()
                let rhs = try parseTerm()
                node = .binary(.plusMinus(k), node, rhs)
            } else {
                return node
            }
        }
    }

    private mutating func parseTerm() throws -> MathNode {
        var node = try parseFactor()
        while true {
            if take("*") {
                let rhs = try parseFactor()
                node = .binary(.multiply, node, rhs)
            } else if take("/") {
                let rhs = try parseFactor()
                node = .binary(.divide, node, rhs)
            } else if startsImplicitFactor() {
                if case .number? = peek(), pos > 0, case .number = tokens[pos - 1] {
                    throw MathFailure.syntax("Two numbers in a row: put an operator between them")
                }
                let rhs = try parseFactor()
                node = .binary(.multiply, node, rhs)
            } else {
                return node
            }
        }
    }

    private mutating func parseFactor() throws -> MathNode {
        if take("-") {
            let inner = try parseFactor()
            return .negate(inner)
        }
        if take("+") { return try parseFactor() }
        if take("±") {
            let k = nextPlusMinus()
            let inner = try parseFactor()
            return .binary(.plusMinus(k), .number(.zero), inner)
        }
        return try parsePower()
    }

    private mutating func parsePower() throws -> MathNode {
        let base = try parsePostfix()
        guard take("^") else { return base }
        let exponent = try parseExponentChain()
        return .binary(.power, base, exponent)
    }

    /// The exponent after '^': signed and right-associative ("e^-x^2" is e^(-(x^2))).
    private mutating func parseExponentChain() throws -> MathNode {
        if take("-") {
            let inner = try parseExponentChain()
            return .negate(inner)
        }
        if take("+") { return try parseExponentChain() }
        let base = try parsePostfix()
        guard take("^") else { return base }
        let exponent = try parseExponentChain()
        return .binary(.power, base, exponent)
    }

    /// One script argument of '_' or '^' in bounds and on function names: a {group}, a number, a letter or a
    /// (group), optionally signed. It never swallows the next '^', so "\int_0^1" reads as lower 0, upper 1.
    private mutating func parseScript() throws -> MathNode {
        if take("-") {
            let inner = try parseScript()
            return .negate(inner)
        }
        if take("+") { return try parseScript() }
        return try parsePostfix()
    }

    private mutating func parsePostfix() throws -> MathNode {
        var node = try parsePrimary()
        while let t = peek() {
            switch t {
            case .symbol("!"):
                advance()
                node = .postfix(.factorial, node)
            case .symbol("%"):
                advance()
                node = .postfix(.percent, node)
            case .symbol("°"):
                advance()
                node = .postfix(.degrees, node)
            case .superscript(let s):
                advance()
                let exponent = try MathParser.superscriptExponent(s)
                node = .binary(.power, node, exponent)
            default:
                return node
            }
        }
        return node
    }

    private static func superscriptExponent(_ s: String) throws -> MathNode {
        var text = s
        var negative = false
        if text.hasPrefix("-") {
            negative = true
            text.removeFirst()
        } else if text.hasPrefix("+") {
            text.removeFirst()
        }
        guard let n = Int(text), let r = Rational(n, 1) else {
            throw MathFailure.syntax("I can't read the superscript '\(s)'")
        }
        return negative ? .negate(.number(.exact(r))) : .number(.exact(r))
    }

    /// True when the next token starts an operand, so "2x", "3(x+1)", "x y" and "2\sqrt{2}" multiply.
    private func startsImplicitFactor() -> Bool {
        guard let t = peek() else { return false }
        switch t {
        case .number, .word:
            return true
        case .command(let c):
            return !c.hasPrefix("end:")
        case .symbol(let s):
            if ["(", "{", "[", "√", "∑", "∏", "∫"].contains(s) { return true }
            if s == "|" { return absDepth == 0 && peek(1) != .symbol("_") }
            return false
        default:
            return false
        }
    }

    private func startsFunction() -> Bool {
        switch peek() {
        case .word(let w)?: return MathParser.functionWordSet.contains(w)
        case .symbol(let s)?: return s == "∑" || s == "∏" || s == "∫"
        default: return false
        }
    }

    private mutating func parsePrimary() throws -> MathNode {
        guard let t = peek() else { throw MathFailure.syntax("The expression is incomplete") }
        switch t {
        case .number(let text):
            advance()
            return .number(try MathParser.number(text))
        case .symbol("("):
            advance()
            return try parseGroup(closing: ")")
        case .symbol("{"):
            advance()
            return try parseGroup(closing: "}")
        case .symbol("["):
            advance()
            return try parseBracket()
        case .symbol("|"):
            advance()
            absDepth += 1
            let inner = try parseExpression()
            try expect("|")
            absDepth -= 1
            return .function(.abs, [inner])
        case .symbol("√"):
            advance()
            let radicand = try parsePower()
            return .function(.sqrt, [radicand])
        case .symbol("∑"), .symbol("∏"):
            advance()
            return try parseBigOperator(product: t == .symbol("∏"))
        case .symbol("∫"):
            advance()
            return try parseIntegral()
        case .command(let name):
            advance()
            return try parseCommand(name)
        case .word(let word):
            advance()
            return try parseWord(word)
        default:
            throw MathFailure.syntax("Unexpected '\(t.display)'")
        }
    }

    /// The inside of (…) or {…}; a '|' in there never closes an outer |…|.
    private mutating func parseGroup(closing: String) throws -> MathNode {
        let saved = absDepth
        absDepth = 0
        let inner = try parseExpression()
        try expect(closing)
        absDepth = saved
        return inner
    }

    private mutating func parseList() throws -> [MathNode] {
        var items = [try parseExpression()]
        while take(",") {
            items.append(try parseExpression())
        }
        return items
    }

    private mutating func parseParenthesisedList() throws -> [MathNode] {
        try expect("(")
        let saved = absDepth
        absDepth = 0
        let items = try parseList()
        try expect(")")
        absDepth = saved
        return items
    }

    /// After '[': "[x+1]" only groups; "[[1,2],[3,4]]", "[1,2;3,4]", "[1,2,3]" and "[1;2]" are matrices.
    private mutating func parseBracket() throws -> MathNode {
        let saved = absDepth
        absDepth = 0
        var rows: [[MathNode]] = []
        if peek() == .symbol("[") {
            repeat {
                try expect("[")
                rows.append(try parseList())
                try expect("]")
            } while take(",")
            try expect("]")
        } else {
            var row = [try parseExpression()]
            while true {
                if take(",") {
                    row.append(try parseExpression())
                } else if take(";") {
                    rows.append(row)
                    row = [try parseExpression()]
                } else {
                    break
                }
            }
            rows.append(row)
            try expect("]")
            if rows.count == 1 && rows[0].count == 1 {
                absDepth = saved
                return rows[0][0]
            }
        }
        absDepth = saved
        return try MathParser.matrixNode(rows)
    }

    static func matrixNode(_ rows: [[MathNode]]) throws -> MathNode {
        guard let width = rows.first?.count, width > 0, rows.allSatisfy({ $0.count == width }) else {
            throw MathFailure.syntax("Every row of a matrix needs the same number of entries")
        }
        return .matrix(rows)
    }

    private mutating func parseCommand(_ name: String) throws -> MathNode {
        switch name {
        case "frac":
            if let head = matchFracDerivative() { return try parseDerivativeBody(head) }
            if isLeibnizQuotient() { throw MathFailure.unsupported("implicit derivatives such as dy/dx") }
            let numerator = try parseLatexArgument()
            let denominator = try parseLatexArgument()
            return .binary(.divide, numerator, denominator)
        case "sqrt":
            if take("[") {
                let index = try parseGroup(closing: "]")
                let radicand = try parseLatexArgument()
                return .function(.root, [index, radicand])
            }
            let radicand = try parseLatexArgument()
            return .function(.sqrt, [radicand])
        default:
            if name.hasPrefix("begin:") { return try parseEnvironment(String(name.dropFirst("begin:".count))) }
            throw MathFailure.syntax("Unexpected '\\\(name)'")
        }
    }

    /// A LaTeX argument: "{…}" or a single token ("\frac12" is 1/2).
    private mutating func parseLatexArgument() throws -> MathNode {
        if take("{") { return try parseGroup(closing: "}") }
        if case .number(let text)? = peek(), text.count > 1 {
            let first = String(text.prefix(1))
            tokens[pos] = .number(String(text.dropFirst()))
            return .number(try MathParser.number(first))
        }
        return try parsePrimary()
    }

    /// \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}; vmatrix is the determinant.
    private mutating func parseEnvironment(_ env: String) throws -> MathNode {
        guard MathParser.matrixEnvironments.contains(env) else {
            throw MathFailure.syntax("\\begin{\(env)} can't be used here")
        }
        let saved = absDepth
        absDepth = 0
        var rows: [[MathNode]] = []
        var row: [MathNode] = []
        while true {
            if case .command(let c)? = peek(), c == "end:" + env {
                advance()
                break
            }
            guard peek() != nil else { throw MathFailure.syntax("\\end{\(env)} is missing") }
            row.append(try parseExpression())
            if take("&") { continue }
            if peek() == .newline {
                advance()
                rows.append(row)
                row = []
            }
        }
        if !row.isEmpty { rows.append(row) }
        absDepth = saved
        let matrix = try MathParser.matrixNode(rows)
        return env == "vmatrix" || env == "Vmatrix" ? .function(.det, [matrix]) : matrix
    }

    private mutating func parseWord(_ word: String) throws -> MathNode {
        switch word {
        case "sin", "cos", "tan", "asin", "acos", "atan", "ln", "log", "exp", "sqrt", "abs", "det", "inv":
            return try parseFunction(word)
        case "sum", "prod":
            if peek() == .symbol("(") { return try parseBigOperatorCall(product: word == "prod") }
            return try parseBigOperator(product: word == "prod")
        case "int":
            if peek() == .symbol("(") { return try parseIntegralCall() }
            return try parseIntegral()
        case "diff":
            return try parseDerivativeCall()
        case "d":
            if let head = matchSlashDerivative() { return try parseDerivativeBody(head) }
            return try variable(named: word)
        case "∞":
            throw MathFailure.unsupported("infinity")
        default:
            if MathParser.userFunctionNames.contains(word), peek() == .symbol("(") || peek() == .symbol("'") {
                var primes = 0
                while take("'") { primes += 1 }
                let args = try parseParenthesisedList()
                return .call(word, args, primes: primes)
            }
            return try variable(named: word)
        }
    }

    /// A variable with an optional subscript: x_1, x_{12}, a_n.
    private mutating func variable(named name: String) throws -> MathNode {
        guard take("_") else { return .variable(name) }
        if take("{") {
            var text = ""
            while let t = peek(), t != .symbol("}") {
                switch t {
                case .number(let s), .word(let s): text += s
                default: throw MathFailure.syntax("A subscript can only hold letters and digits")
                }
                advance()
            }
            try expect("}")
            guard !text.isEmpty else { throw MathFailure.syntax("The subscript of \(name) is empty") }
            return .variable(name + "_" + text)
        }
        switch peek() {
        case .number(let s)?, .word(let s)?:
            advance()
            return .variable(name + "_" + s)
        default:
            throw MathFailure.syntax("'_' after \(name) needs a subscript")
        }
    }

    private mutating func parseFunction(_ word: String) throws -> MathNode {
        var name = word
        var base: MathNode? = nil
        if name == "log", take("_") { base = try parseScript() }
        var power: MathNode? = nil
        if take("^") {
            power = try parseScript()
        } else if case .superscript(let s)? = peek() {
            advance()
            power = try MathParser.superscriptExponent(s)
        }
        if power == .negate(.number(.one)), let inverse = MathParser.inverseTrig[name] {
            name = inverse          // sin^{-1} x is arcsin x
            power = nil
        }
        let args = try parseFunctionArguments()
        guard args.count == 1 else { throw MathFailure.syntax("\(word) takes one argument") }
        var node: MathNode
        if let b = base {
            node = .function(.logBase, [b, args[0]])
        } else if let function = MathFunction(rawValue: name) {
            node = .function(function, args)
        } else {
            throw MathFailure.syntax("Unknown function \(word)")
        }
        if let p = power { node = .binary(.power, node, p) }   // sin^2 x is (sin x)^2
        return node
    }

    /// "(…)", "{…}", or an implicit argument: "sin 2x" is sin(2x), "sin x cos x" is sin(x)·cos(x).
    private mutating func parseFunctionArguments() throws -> [MathNode] {
        if peek() == .symbol("(") { return try parseParenthesisedList() }
        if take("{") { return [try parseGroup(closing: "}")] }
        guard peek() != nil else { throw MathFailure.syntax("A function is missing its argument") }
        var node = try parseFactor()
        while startsImplicitFactor(), !startsFunction() {
            let next = try parsePower()
            node = .binary(.multiply, node, next)
        }
        return [node]
    }

    // MARK: Sums, products, integrals, derivatives

    /// ∑_{i=1}^{n} body (either script order); the body is the following term, so ∑ i^2 + 1 is (∑ i^2) + 1.
    private mutating func parseBigOperator(product: Bool) throws -> MathNode {
        let symbol = product ? "∏" : "∑"
        var variable: String? = nil
        var from: MathNode? = nil
        var to: MathNode? = nil
        for _ in 0..<2 {
            if take("_") {
                let braced = take("{")
                guard case .word(let v)? = peek(), MathParser.isSingleLetter(v) else {
                    throw MathFailure.syntax("\(symbol) needs an index such as i=1 under it")
                }
                advance()
                try expect("=")
                variable = v
                if braced {
                    from = try parseExpression()
                    try expect("}")
                } else {
                    from = try parseScript()
                }
            } else if take("^") {
                to = try parseScript()
            }
        }
        guard let v = variable, let lower = from, let upper = to else {
            throw MathFailure.syntax("\(symbol) needs its range, e.g. \\sum_{i=1}^{n}")
        }
        let body = try parseTerm()
        return .bigOperator(product: product, variable: v, from: lower, to: upper, body: body)
    }

    /// sum(body, i, from, to) and prod(body, i, from, to).
    private mutating func parseBigOperatorCall(product: Bool) throws -> MathNode {
        let args = try parseParenthesisedList()
        guard args.count == 4, case .variable(let v) = args[1] else {
            throw MathFailure.syntax("Write \(product ? "prod" : "sum")(expression, i, from, to)")
        }
        return .bigOperator(product: product, variable: v, from: args[2], to: args[3], body: args[0])
    }

    /// ∫_a^b body dx. Without both bounds it is an indefinite (symbolic) integral.
    private mutating func parseIntegral() throws -> MathNode {
        var lower: MathNode? = nil
        var upper: MathNode? = nil
        for _ in 0..<2 {
            if take("_") {
                lower = try parseScript()
            } else if take("^") {
                upper = try parseScript()
            }
        }
        guard let from = lower, let to = upper else { throw MathFailure.unsupported("indefinite integrals") }
        guard let d = findDifferential(), case .word(let v) = tokens[d + 1] else {
            throw MathFailure.syntax("Add the variable of integration, e.g. dx")
        }
        var body: MathNode = .number(.one)
        if d > pos {
            let savedLimit = limit
            limit = d
            body = try parseExpression()
            if let t = peek() { throw MathFailure.syntax("Unexpected '\(t.display)' in the integral") }
            limit = savedLimit
        }
        pos = d + 2
        return .integral(variable: v, from: from, to: to, body: body)
    }

    /// int(body, x, a, b).
    private mutating func parseIntegralCall() throws -> MathNode {
        let args = try parseParenthesisedList()
        guard args.count == 4, case .variable(let v) = args[1] else {
            throw MathFailure.syntax("Write int(expression, x, from, to)")
        }
        return .integral(variable: v, from: args[2], to: args[3], body: args[0])
    }

    /// The index of the "d" of the integral's "dx" (at the same bracket depth as the body).
    private func findDifferential() -> Int? {
        var depth = 0
        var i = pos
        while i + 1 < limit {
            switch tokens[i] {
            case .symbol("("), .symbol("["), .symbol("{"): depth += 1
            case .symbol(")"), .symbol("]"), .symbol("}"): depth -= 1
            case .command(let c) where c.hasPrefix("begin:"): depth += 1
            case .command(let c) where c.hasPrefix("end:"): depth -= 1
            case .word("d"):
                if depth == 0, case .word(let v) = tokens[i + 1], MathParser.isSingleLetter(v) { return i }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// diff(body, x, at) or diff(body, x).
    private mutating func parseDerivativeCall() throws -> MathNode {
        let args = try parseParenthesisedList()
        guard args.count == 2 || args.count == 3, case .variable(let v) = args[1] else {
            throw MathFailure.syntax("Write diff(expression, x, at)")
        }
        return .derivative(variable: v, order: 1, body: args[0], at: args.count == 3 ? args[2] : nil)
    }

    private struct DerivativeHead {
        var variable: String
        var order: Int
        /// Tokens the head spans from `pos`.
        var length: Int
    }

    /// "d/dx" or "d^2/dx^2", with `pos` just past the leading d.
    private func matchSlashDerivative() -> DerivativeHead? {
        var i = pos
        var order = 1
        if let o = readOrder(at: i) {
            order = o.order
            i = o.next
        }
        guard i + 2 < limit, tokens[i] == .symbol("/"), tokens[i + 1] == .word("d"), case .word(let v) = tokens[i + 2],
              MathParser.isSingleLetter(v) else { return nil }
        i += 3
        if let o = readOrder(at: i) {
            guard o.order == order else { return nil }
            i = o.next
        }
        return DerivativeHead(variable: v, order: order, length: i - pos)
    }

    /// "{d}{dx}" or "{d^2}{dx^2}" right after \frac.
    private func matchFracDerivative() -> DerivativeHead? {
        var i = pos
        guard i + 1 < limit, tokens[i] == .symbol("{"), tokens[i + 1] == .word("d") else { return nil }
        i += 2
        var order = 1
        if let o = readOrder(at: i) {
            order = o.order
            i = o.next
        }
        guard i + 3 < limit, tokens[i] == .symbol("}"), tokens[i + 1] == .symbol("{"), tokens[i + 2] == .word("d"),
              case .word(let v) = tokens[i + 3], MathParser.isSingleLetter(v) else { return nil }
        i += 4
        if let o = readOrder(at: i) {
            guard o.order == order else { return nil }
            i = o.next
        }
        guard i < limit, tokens[i] == .symbol("}") else { return nil }
        return DerivativeHead(variable: v, order: order, length: i + 1 - pos)
    }

    /// "{dy}{dx}" right after \frac.
    private func isLeibnizQuotient() -> Bool {
        guard pos + 5 < limit, tokens[pos] == .symbol("{"), tokens[pos + 1] == .word("d"),
              case .word(let v) = tokens[pos + 2], MathParser.isSingleLetter(v), tokens[pos + 3] == .symbol("}"),
              tokens[pos + 4] == .symbol("{"), tokens[pos + 5] == .word("d") else { return false }
        return true
    }

    /// "^2", "^{2}" or "²" at index i.
    private func readOrder(at i: Int) -> (order: Int, next: Int)? {
        guard i < limit else { return nil }
        if case .superscript(let s) = tokens[i], let n = Int(s) { return (n, i + 1) }
        guard tokens[i] == .symbol("^"), i + 1 < limit else { return nil }
        if case .number(let s) = tokens[i + 1], let n = Int(s) { return (n, i + 2) }
        if tokens[i + 1] == .symbol("{"), i + 3 < limit, case .number(let s) = tokens[i + 2], let n = Int(s),
           tokens[i + 3] == .symbol("}") {
            return (n, i + 4)
        }
        return nil
    }

    /// The operand of d/dx (the following term), then an optional evaluation bar |_{x=2}.
    private mutating func parseDerivativeBody(_ head: DerivativeHead) throws -> MathNode {
        pos += head.length
        let body = try parseTerm()
        var at: MathNode? = nil
        if peek() == .symbol("|"), peek(1) == .symbol("_") {
            pos += 2
            let braced = take("{")
            if case .word(let v)? = peek(), v == head.variable, peek(1) == .symbol("=") { pos += 2 }
            if braced {
                at = try parseExpression()
                try expect("}")
            } else {
                at = try parseScript()
            }
        }
        return .derivative(variable: head.variable, order: head.order, body: body, at: at)
    }
}
