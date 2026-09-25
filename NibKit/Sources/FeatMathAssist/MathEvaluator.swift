import Foundation
import NibContracts

// The on-device maths engine (F061), part 2: exact numbers, matrices, page definitions and the evaluator. Numbers stay
// exact fractions while they fit in 64 bits and become Doubles otherwise; calculus is numeric (adaptive Gauss–Kronrod
// integrals, central differences with a Richardson step for derivatives).

// MARK: - Exact fractions

/// A fraction in lowest terms with a positive denominator. Arithmetic returns nil on 64-bit overflow and the caller
/// falls back to a `Double`.
struct Rational: Hashable {
    let numerator: Int
    let denominator: Int

    static let zero = Rational(integer: 0)
    static let one = Rational(integer: 1)

    /// Nil when the denominator is 0 or a part is Int.min (its magnitude doesn't fit in an Int).
    init?(_ numerator: Int, _ denominator: Int) {
        guard denominator != 0, numerator != Int.min, denominator != Int.min else { return nil }
        let g = Rational.gcd(numerator, denominator)
        let sign = denominator < 0 ? -1 : 1
        self.numerator = sign * numerator / g
        self.denominator = sign * denominator / g
    }

    init(integer: Int) {
        numerator = integer
        denominator = 1
    }

    private init(normalized numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a.magnitude
        var y = b.magnitude
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 || x > UInt(Int.max) ? 1 : Int(x)
    }

    static func integerPower(_ base: Int, _ exponent: Int) -> Int? {
        guard exponent >= 0 else { return nil }
        var result = 1
        for _ in 0..<exponent {
            let (r, overflow) = result.multipliedReportingOverflow(by: base)
            if overflow { return nil }
            result = r
        }
        return result
    }

    /// The exact q-th root of a non-negative Int, when there is one.
    static func integerRoot(_ value: Int, _ q: Int) -> Int? {
        guard value >= 0, q >= 1 else { return nil }
        let guess = Int(pow(Double(value), 1 / Double(q)).rounded())
        for candidate in max(0, guess - 1)...(guess + 1) where integerPower(candidate, q) == value {
            return candidate
        }
        return nil
    }

    var isInteger: Bool { denominator == 1 }
    var doubleValue: Double { Double(numerator) / Double(denominator) }
    var negated: Rational { Rational(normalized: -numerator, denominator) }
    /// Nil for zero.
    var reciprocal: Rational? { Rational(denominator, numerator) }

    func adding(_ o: Rational) -> Rational? {
        let g = Rational.gcd(denominator, o.denominator)
        let (lcm, o1) = (denominator / g).multipliedReportingOverflow(by: o.denominator)
        let (x, o2) = numerator.multipliedReportingOverflow(by: o.denominator / g)
        let (y, o3) = o.numerator.multipliedReportingOverflow(by: denominator / g)
        let (sum, o4) = x.addingReportingOverflow(y)
        guard !o1, !o2, !o3, !o4 else { return nil }
        return Rational(sum, lcm)
    }

    func multiplying(_ o: Rational) -> Rational? {
        let g1 = Rational.gcd(numerator, o.denominator)
        let g2 = Rational.gcd(o.numerator, denominator)
        let (n, o1) = (numerator / g1).multipliedReportingOverflow(by: o.numerator / g2)
        let (d, o2) = (denominator / g2).multipliedReportingOverflow(by: o.denominator / g1)
        guard !o1, !o2 else { return nil }
        return Rational(n, d)
    }

    func power(_ exponent: Int) -> Rational? {
        guard exponent != Int.min else { return nil }
        if exponent < 0 { return reciprocal?.power(-exponent) }
        var result = Rational.one
        var base = self
        var e = exponent
        while e > 0 {
            if e & 1 == 1 {
                guard let r = result.multiplying(base) else { return nil }
                result = r
            }
            e >>= 1
            if e > 0 {
                guard let b = base.multiplying(base) else { return nil }
                base = b
            }
        }
        return result
    }

    /// The exact q-th root when numerator and denominator are perfect q-th powers (odd q allows negatives).
    func root(_ q: Int) -> Rational? {
        if numerator < 0 {
            guard q % 2 == 1, let r = negated.root(q) else { return nil }
            return r.negated
        }
        guard let n = Rational.integerRoot(numerator, q), let d = Rational.integerRoot(denominator, q) else { return nil }
        return Rational(n, d)
    }

    /// The first continued-fraction convergent of `x` within `tolerance` whose denominator is at most `maxDenominator`
    /// (sin 30° = 0.49999999999999994 → 1/2).
    static func approximating(_ x: Double, maxDenominator: Int, tolerance: Double) -> Rational? {
        guard x.isFinite, abs(x) < 1e12 else { return nil }
        var h0 = 0, h1 = 1, k0 = 1, k1 = 0
        var value = x
        for _ in 0..<40 {
            let a = value.rounded(.down)
            guard abs(a) < 1e12 else { return nil }
            let ai = Int(a)
            let (product, overflow1) = ai.multipliedReportingOverflow(by: k1)
            let (k2, overflow2) = product.addingReportingOverflow(k0)
            if overflow1 || overflow2 || k2 > maxDenominator { return nil }
            let h2 = ai * h1 + h0
            (h0, h1, k0, k1) = (h1, h2, k1, k2)
            if abs(Double(h1) / Double(k1) - x) <= tolerance { return Rational(h1, k1) }
            let fraction = value - a
            if fraction == 0 { return nil }
            value = 1 / fraction
        }
        return nil
    }
}

// MARK: - Numbers

/// A number: an exact fraction, or a Double once exactness is lost (irrational functions, overflow, numeric calculus).
enum Scalar: Equatable {
    case exact(Rational)
    case real(Double)

    static let zero = Scalar.exact(.zero)
    static let one = Scalar.exact(.one)

    init(_ integer: Int) {
        if let r = Rational(integer, 1) {
            self = .exact(r)
        } else {
            self = .real(Double(integer))
        }
    }

    var doubleValue: Double {
        switch self {
        case .exact(let r): return r.doubleValue
        case .real(let d): return d
        }
    }

    var rational: Rational? {
        if case .exact(let r) = self { return r }
        return nil
    }

    var isZero: Bool {
        switch self {
        case .exact(let r): return r.numerator == 0
        case .real(let d): return d == 0
        }
    }

    /// A whole number: exact, or a Double that is exactly integral and small enough to count with.
    var integerValue: Int? {
        switch self {
        case .exact(let r): return r.isInteger ? r.numerator : nil
        case .real(let d): return d == d.rounded() && abs(d) < 1e15 ? Int(d) : nil
        }
    }

    var magnitude: Scalar {
        switch self {
        case .exact(let r): return .exact(r.numerator < 0 ? r.negated : r)
        case .real(let d): return .real(abs(d))
        }
    }

    /// Zero for exact numbers; within 10⁻¹² of `scale` for Doubles (rounding noise in elimination).
    func isNegligible(scale: Double) -> Bool {
        switch self {
        case .exact(let r): return r.numerator == 0
        case .real(let d): return abs(d) <= 1e-12 * scale
        }
    }

    static func nearlyEqual(_ a: Scalar, _ b: Scalar) -> Bool {
        if case .exact(let x) = a, case .exact(let y) = b { return x == y }
        let x = a.doubleValue
        let y = b.doubleValue
        return abs(x - y) <= 1e-9 * max(1, abs(x), abs(y))
    }

    static func + (a: Scalar, b: Scalar) -> Scalar {
        if case .exact(let x) = a, case .exact(let y) = b, let r = x.adding(y) { return .exact(r) }
        return .real(a.doubleValue + b.doubleValue)
    }

    static prefix func - (a: Scalar) -> Scalar {
        switch a {
        case .exact(let r): return .exact(r.negated)
        case .real(let d): return .real(-d)
        }
    }

    static func - (a: Scalar, b: Scalar) -> Scalar { a + (-b) }

    static func * (a: Scalar, b: Scalar) -> Scalar {
        if case .exact(let x) = a, case .exact(let y) = b, let r = x.multiplying(y) { return .exact(r) }
        return .real(a.doubleValue * b.doubleValue)
    }

    func divided(by b: Scalar) throws -> Scalar {
        if b.isZero { throw MathFailure.math("Division by zero") }
        if case .exact(let x) = self, case .exact(let y) = b, let inverse = y.reciprocal, let r = x.multiplying(inverse) {
            return .exact(r)
        }
        return .real(doubleValue / b.doubleValue)
    }

    /// Exact for fractions to whole powers and for perfect roots (8^(2/3) = 4); real otherwise.
    func raised(to exponent: Scalar) throws -> Scalar {
        if case .exact(let b) = self, case .exact(let e) = exponent {
            if b.numerator == 0 && e.numerator < 0 { throw MathFailure.math("Division by zero") }
            if e.isInteger {
                if let r = b.power(e.numerator) { return .exact(r) }
            } else if e.denominator <= 12, let root = b.root(e.denominator), let r = root.power(e.numerator) {
                return .exact(r)
            }
        }
        let b = doubleValue
        let x = exponent.doubleValue
        if b == 0 && x < 0 { throw MathFailure.math("Division by zero") }
        if b >= 0 || x == x.rounded() { return .real(pow(b, x)) }
        // A negative base is real only under a fractional power with an odd denominator: (−8)^(1/3) = −2.
        if case .exact(let e) = exponent, e.denominator % 2 == 1 {
            let magnitude = pow(-b, x)
            return .real(e.numerator % 2 == 0 ? magnitude : -magnitude)
        }
        throw MathFailure.math("A negative number to a fractional power isn't a real number")
    }
}

// MARK: - Matrices

struct Matrix: Equatable {
    var rows: [[Scalar]]

    var rowCount: Int { rows.count }
    var columnCount: Int { rows.first?.count ?? 0 }
    var isSquare: Bool { rowCount == columnCount }
    var sizeText: String { "\(rowCount)×\(columnCount)" }

    static func identity(_ n: Int) -> Matrix {
        var rows: [[Scalar]] = []
        for i in 0..<n {
            var row = Array(repeating: Scalar.zero, count: n)
            row[i] = .one
            rows.append(row)
        }
        return Matrix(rows: rows)
    }

    var transposed: Matrix {
        var out: [[Scalar]] = []
        for j in 0..<columnCount {
            var row: [Scalar] = []
            for i in 0..<rowCount { row.append(rows[i][j]) }
            out.append(row)
        }
        return Matrix(rows: out)
    }

    func map(_ transform: (Scalar) throws -> Scalar) rethrows -> Matrix {
        var out: [[Scalar]] = []
        for row in rows { out.append(try row.map(transform)) }
        return Matrix(rows: out)
    }

    func scaled(by s: Scalar) -> Matrix { map { $0 * s } }

    func adding(_ o: Matrix, subtract: Bool) throws -> Matrix {
        guard rowCount == o.rowCount, columnCount == o.columnCount else {
            throw MathFailure.math("A \(sizeText) and a \(o.sizeText) matrix can't be \(subtract ? "subtracted" : "added")")
        }
        var out = rows
        for i in 0..<rowCount {
            for j in 0..<columnCount {
                out[i][j] = subtract ? rows[i][j] - o.rows[i][j] : rows[i][j] + o.rows[i][j]
            }
        }
        return Matrix(rows: out)
    }

    func multiplied(by o: Matrix) throws -> Matrix {
        guard columnCount == o.rowCount else {
            throw MathFailure.math("A \(sizeText) matrix can't multiply a \(o.sizeText) matrix (columns must match rows)")
        }
        var out: [[Scalar]] = []
        for i in 0..<rowCount {
            var row: [Scalar] = []
            for j in 0..<o.columnCount {
                var sum = Scalar.zero
                for k in 0..<columnCount { sum = sum + rows[i][k] * o.rows[k][j] }
                row.append(sum)
            }
            out.append(row)
        }
        return Matrix(rows: out)
    }

    func determinant() throws -> Scalar {
        guard isSquare else { throw MathFailure.math("Only square matrices have a determinant; this one is \(sizeText)") }
        let reduced = try Matrix.rowReduce(rows, columns: columnCount)
        return reduced.pivots.count == rowCount ? reduced.determinant : .zero
    }

    func inverse() throws -> Matrix {
        guard isSquare else { throw MathFailure.math("Only square matrices have an inverse; this one is \(sizeText)") }
        let n = rowCount
        let identity = Matrix.identity(n)
        var augmented: [[Scalar]] = []
        for i in 0..<n { augmented.append(rows[i] + identity.rows[i]) }
        let reduced = try Matrix.rowReduce(augmented, columns: n)
        guard reduced.pivots.count == n else {
            throw MathFailure.math("This matrix has no inverse (its determinant is 0)")
        }
        return Matrix(rows: reduced.rows.map { Array($0[n...]) })
    }

    func power(_ n: Int) throws -> Matrix {
        guard isSquare else { throw MathFailure.math("Only square matrices have powers; this one is \(sizeText)") }
        if n < 0 { return try inverse().power(-n) }
        var result = Matrix.identity(rowCount)
        var base = self
        var e = n
        while e > 0 {
            if e & 1 == 1 { result = try result.multiplied(by: base) }
            e >>= 1
            if e > 0 { base = try base.multiplied(by: base) }
        }
        return result
    }

    struct Reduction {
        var rows: [[Scalar]]
        /// The pivot column of each leading row, in order.
        var pivots: [Int]
        /// The determinant of the first `columns` columns (meaningful when every column has a pivot).
        var determinant: Scalar
    }

    /// Gauss–Jordan elimination on the first `columns` columns, with partial pivoting. Exact while every entry is a
    /// fraction; with Doubles, entries within 10⁻¹² of the largest entry count as zero.
    static func rowReduce(_ input: [[Scalar]], columns: Int) throws -> Reduction {
        var m = input
        var pivots: [Int] = []
        var determinant = Scalar.one
        var scale = 0.0
        for row in m {
            for x in row { scale = max(scale, abs(x.doubleValue)) }
        }
        var r = 0
        for c in 0..<columns {
            guard r < m.count else { break }
            var best: Int? = nil
            for i in r..<m.count where !m[i][c].isNegligible(scale: scale) {
                if let b = best, abs(m[i][c].doubleValue) <= abs(m[b][c].doubleValue) { continue }
                best = i
            }
            guard let p = best else {
                determinant = .zero
                continue
            }
            if p != r {
                m.swapAt(p, r)
                determinant = -determinant
            }
            let pivot = m[r][c]
            determinant = determinant * pivot
            m[r] = try m[r].map { try $0.divided(by: pivot) }
            for i in 0..<m.count where i != r {
                let factor = m[i][c]
                if factor.isZero { continue }
                for k in 0..<m[i].count { m[i][k] = m[i][k] - factor * m[r][k] }
                m[i][c] = .zero
            }
            pivots.append(c)
            r += 1
        }
        return Reduction(rows: m, pivots: pivots, determinant: determinant)
    }
}

// MARK: - Values

enum MathValue: Equatable {
    case scalar(Scalar)
    case matrix(Matrix)

    static func add(_ a: MathValue, _ b: MathValue, subtract: Bool) throws -> MathValue {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)):
            return .scalar(subtract ? x - y : x + y)
        case let (.matrix(x), .matrix(y)):
            return .matrix(try x.adding(y, subtract: subtract))
        default:
            throw MathFailure.math("A number and a matrix can't be \(subtract ? "subtracted" : "added")")
        }
    }

    static func multiply(_ a: MathValue, _ b: MathValue) throws -> MathValue {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)):
            return .scalar(x * y)
        case let (.scalar(s), .matrix(m)), let (.matrix(m), .scalar(s)):
            return .matrix(m.scaled(by: s))
        case let (.matrix(x), .matrix(y)):
            return .matrix(try x.multiplied(by: y))
        }
    }

    static func divide(_ a: MathValue, _ b: MathValue) throws -> MathValue {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)):
            return .scalar(try x.divided(by: y))
        case let (.matrix(m), .scalar(y)):
            return .matrix(try m.map { try $0.divided(by: y) })
        case (_, .matrix):
            throw MathFailure.math("Dividing by a matrix isn't defined: multiply by its inverse, e.g. A·B^{-1}")
        }
    }

    static func power(_ a: MathValue, _ b: MathValue) throws -> MathValue {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)):
            return .scalar(try x.raised(to: y))
        case let (.matrix(m), .scalar(y)):
            guard let n = y.integerValue, abs(n) <= 10_000 else {
                throw MathFailure.math("A matrix can only be raised to a whole-number power")
            }
            return .matrix(try m.power(n))
        case (_, .matrix):
            throw MathFailure.math("A power can't be a matrix")
        }
    }

    static func nearlyEqual(_ a: MathValue, _ b: MathValue) -> Bool {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)):
            return Scalar.nearlyEqual(x, y)
        case let (.matrix(x), .matrix(y)):
            guard x.rowCount == y.rowCount, x.columnCount == y.columnCount else { return false }
            for i in 0..<x.rowCount {
                for j in 0..<x.columnCount where !Scalar.nearlyEqual(x.rows[i][j], y.rows[i][j]) { return false }
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Page definitions

struct MathFunctionDefinition: Equatable {
    var parameters: [String]
    var body: MathNode
}

/// A page's variables (kept as expressions, evaluated when used) and its functions f, g, h, F, G, H. Later definitions
/// replace earlier ones, which is how "the latest definition wins".
struct MathDefinitions {
    static let constants: Set<String> = ["π", "e"]

    var variables: [String: MathNode] = [:]
    var functions: [String: MathFunctionDefinition] = [:]

    /// Names in `node` that neither the page nor a binder (∑ index, integration variable, parameter) defines: the
    /// unknowns of an equation. Page variables and functions are followed; `symbolic` names (the parameters of a
    /// function being expanded) count as free.
    func freeNames(_ node: MathNode, symbolic: Set<String> = []) -> Set<String> {
        var found = Set<String>()
        var visited = Set<String>()
        collectFree(node, bound: [], symbolic: symbolic, found: &found, visited: &visited)
        return found
    }

    private func collectFree(_ node: MathNode, bound: Set<String>, symbolic: Set<String>, found: inout Set<String>,
                             visited: inout Set<String>) {
        switch node {
        case .number:
            return
        case .variable(let name):
            if bound.contains(name) { return }
            if symbolic.contains(name) {
                found.insert(name)
                return
            }
            if let definition = variables[name] {
                if visited.insert("var " + name).inserted {
                    collectFree(definition, bound: [], symbolic: [], found: &found, visited: &visited)
                }
                return
            }
            if !MathDefinitions.constants.contains(name) { found.insert(name) }
        case .negate(let inner), .postfix(_, let inner):
            collectFree(inner, bound: bound, symbolic: symbolic, found: &found, visited: &visited)
        case .binary(let op, let lhs, let rhs):
            collectFree(lhs, bound: bound, symbolic: symbolic, found: &found, visited: &visited)
            if op == .power, case .variable("T") = rhs, !bound.contains("T"), !symbolic.contains("T"),
               variables["T"] == nil {
                return   // A^T is a transpose, not a power
            }
            collectFree(rhs, bound: bound, symbolic: symbolic, found: &found, visited: &visited)
        case .function(_, let args):
            for a in args { collectFree(a, bound: bound, symbolic: symbolic, found: &found, visited: &visited) }
        case .call(let name, let args, _):
            for a in args { collectFree(a, bound: bound, symbolic: symbolic, found: &found, visited: &visited) }
            if let fn = functions[name] {
                if visited.insert("fn " + name).inserted {
                    collectFree(fn.body, bound: Set(fn.parameters), symbolic: [], found: &found, visited: &visited)
                }
            } else if variables[name] != nil || bound.contains(name) || symbolic.contains(name) {
                collectFree(.variable(name), bound: bound, symbolic: symbolic, found: &found, visited: &visited)
            }
        case .matrix(let rows):
            for row in rows {
                for x in row { collectFree(x, bound: bound, symbolic: symbolic, found: &found, visited: &visited) }
            }
        case .bigOperator(_, let v, let from, let to, let body), .integral(let v, let from, let to, let body):
            collectFree(from, bound: bound, symbolic: symbolic, found: &found, visited: &visited)
            collectFree(to, bound: bound, symbolic: symbolic, found: &found, visited: &visited)
            collectFree(body, bound: bound.union([v]), symbolic: symbolic, found: &found, visited: &visited)
        case .derivative(let v, _, let body, let at):
            collectFree(at ?? .variable(v), bound: bound, symbolic: symbolic, found: &found, visited: &visited)
            collectFree(body, bound: bound.union([v]), symbolic: symbolic, found: &found, visited: &visited)
        }
    }
}

extension MathNode {
    /// True when `name` appears as a variable anywhere in the tree.
    func mentions(_ name: String) -> Bool {
        switch self {
        case .number:
            return false
        case .variable(let n):
            return n == name
        case .negate(let a), .postfix(_, let a):
            return a.mentions(name)
        case .binary(_, let a, let b):
            return a.mentions(name) || b.mentions(name)
        case .function(_, let args), .call(_, let args, _):
            return args.contains { $0.mentions(name) }
        case .matrix(let rows):
            return rows.contains { row in row.contains { $0.mentions(name) } }
        case .bigOperator(_, _, let from, let to, let body), .integral(_, let from, let to, let body):
            return from.mentions(name) || to.mentions(name) || body.mentions(name)
        case .derivative(_, _, let body, let at):
            return body.mentions(name) || (at?.mentions(name) ?? false)
        }
    }
}

// MARK: - Evaluator

/// Evaluates syntax trees against page definitions. One instance per request: it caches page variables' values and
/// records whether numeric calculus (an approximation) was used. Not thread-safe; it runs on one task at a time.
final class MathEvaluator {
    static let stepBudget = 3_000_000
    static let maxTerms = 100_000
    static let maxDepth = 100

    let definitions: MathDefinitions
    /// True once an integral or derivative was worked out numerically.
    private(set) var approximate = false
    private var locals: [String: MathValue] = [:]
    private var signs: [Int: Bool] = [:]
    private var cache: [String: MathValue] = [:]
    private var resolving: Set<String> = []
    private var depth = 0
    private var steps = 0

    init(definitions: MathDefinitions) {
        self.definitions = definitions
    }

    /// Evaluates one side of a statement; `signs[k] == true` takes − for its k-th ±.
    func evaluate(_ node: MathNode, signs: [Int: Bool] = [:]) throws -> MathValue {
        self.signs = signs
        locals = [:]
        steps = 0
        return try value(node)
    }

    /// The value of `node` with `variable` = x, as a Double (graphs).
    func sample(_ node: MathNode, variable: String, at x: Double) throws -> Double {
        signs = [:]
        locals = [variable: .scalar(.real(x))]
        steps = 0
        return try realValue(value(node))
    }

    private func value(_ node: MathNode) throws -> MathValue {
        steps += 1
        if steps > MathEvaluator.stepBudget { throw MathFailure.unsupported("calculations this long") }
        switch node {
        case .number(let s):
            return .scalar(s)
        case .variable(let name):
            return try lookUp(name)
        case .negate(let inner):
            let v = try value(inner)
            switch v {
            case .scalar(let s): return .scalar(-s)
            case .matrix(let m): return .matrix(m.map { -$0 })
            }
        case .binary(let op, let lhs, let rhs):
            return try binary(op, lhs, rhs)
        case .postfix(let op, let inner):
            return try checked(applyPostfix(op, value(inner)))
        case .function(let f, let args):
            return try checked(applyFunction(f, args))
        case .call(let name, let args, let primes):
            return try callFunction(name, args, primes: primes)
        case .matrix(let rows):
            var out: [[Scalar]] = []
            for row in rows {
                var entries: [Scalar] = []
                for x in row { entries.append(try scalarValue(value(x), "A matrix entry")) }
                out.append(entries)
            }
            return .matrix(Matrix(rows: out))
        case .bigOperator(let product, let v, let from, let to, let body):
            return try sumOrProduct(product: product, variable: v, from: from, to: to, body: body)
        case .integral(let v, let from, let to, let body):
            return try definiteIntegral(variable: v, from: from, to: to, body: body)
        case .derivative(let v, let order, let body, let at):
            return try derivativeValue(variable: v, order: order, body: body, at: at)
        }
    }

    private func scalarValue(_ v: MathValue, _ what: String) throws -> Scalar {
        guard case .scalar(let s) = v else { throw MathFailure.math("\(what) must be a number, not a matrix") }
        return s
    }

    private func realValue(_ v: MathValue) throws -> Double {
        try scalarValue(v, "The value").doubleValue
    }

    private func checked(_ v: MathValue) throws -> MathValue {
        switch v {
        case .scalar(let s):
            try MathEvaluator.checkFinite(s)
        case .matrix(let m):
            for row in m.rows {
                for x in row { try MathEvaluator.checkFinite(x) }
            }
        }
        return v
    }

    static func checkFinite(_ s: Scalar) throws {
        guard case .real(let d) = s else { return }
        if d.isNaN { throw MathFailure.math("The result isn't a real number") }
        if d.isInfinite { throw MathFailure.math("The result is too large to work out") }
    }

    // MARK: Names

    private func lookUp(_ name: String) throws -> MathValue {
        if let v = locals[name] { return v }
        if let v = cache[name] { return v }
        if let node = definitions.variables[name] {
            guard !resolving.contains(name) else { throw MathFailure.math("\(name) is defined in terms of itself") }
            resolving.insert(name)
            let saved = locals
            locals = [:]   // a page definition sees the page, not the caller's ∑ indices or parameters
            defer {
                locals = saved
                resolving.remove(name)
            }
            let v = try value(node)
            cache[name] = v
            return v
        }
        switch name {
        case "π": return .scalar(.real(Double.pi))
        case "e": return .scalar(.real(exp(1.0)))
        default: throw MathFailure.undefined(name)
        }
    }

    // MARK: Operators

    private func binary(_ op: MathOperator, _ lhs: MathNode, _ rhs: MathNode) throws -> MathValue {
        let a = try value(lhs)
        if op == .power, case .variable("T") = rhs, case .matrix(let m) = a, locals["T"] == nil,
           definitions.variables["T"] == nil {
            return .matrix(m.transposed)
        }
        let b = try value(rhs)
        switch op {
        case .add: return try checked(MathValue.add(a, b, subtract: false))
        case .subtract: return try checked(MathValue.add(a, b, subtract: true))
        case .plusMinus(let k): return try checked(MathValue.add(a, b, subtract: signs[k] ?? false))
        case .multiply: return try checked(MathValue.multiply(a, b))
        case .divide: return try checked(MathValue.divide(a, b))
        case .power: return try checked(MathValue.power(a, b))
        }
    }

    private func applyPostfix(_ op: MathPostfix, _ v: MathValue) throws -> MathValue {
        switch op {
        case .percent: return try MathValue.divide(v, .scalar(Scalar(100)))
        case .degrees: return try MathValue.multiply(v, .scalar(.real(Double.pi / 180)))
        case .factorial: return .scalar(try MathEvaluator.factorial(scalarValue(v, "A factorial")))
        }
    }

    static func factorial(_ s: Scalar) throws -> Scalar {
        guard let n = s.integerValue, n >= 0 else { throw MathFailure.math("Factorials need a whole number of at least 0") }
        guard n <= 170 else { throw MathFailure.math("\(n)! is too large to work out") }
        var result = Scalar.one
        if n >= 2 {
            for k in 2...n { result = result * Scalar(k) }
        }
        return result
    }

    // MARK: Functions

    private func applyFunction(_ f: MathFunction, _ args: [MathNode]) throws -> MathValue {
        let expected = f == .logBase || f == .root ? 2 : 1
        guard args.count == expected else { throw MathFailure.syntax("\(f.rawValue) takes \(expected) argument(s)") }
        var values: [MathValue] = []
        for a in args { values.append(try value(a)) }
        switch f {
        case .det:
            guard case .matrix(let m) = values[0] else { throw MathFailure.math("det needs a matrix") }
            return .scalar(try m.determinant())
        case .inv:
            switch values[0] {
            case .matrix(let m): return .matrix(try m.inverse())
            case .scalar(let s): return .scalar(try Scalar.one.divided(by: s))
            }
        case .abs:
            switch values[0] {
            case .matrix(let m): return .scalar(try m.determinant())   // |A| is the determinant
            case .scalar(let s): return .scalar(s.magnitude)
            }
        case .logBase:
            let base = try scalarValue(values[0], "A logarithm's base").doubleValue
            let x = try scalarValue(values[1], "A logarithm").doubleValue
            guard base > 0, base != 1 else { throw MathFailure.math("A logarithm's base must be positive and not 1") }
            guard x > 0 else { throw MathFailure.math("Logarithms need a positive number") }
            return .scalar(.real(log(x) / log(base)))
        case .root:
            guard let n = try scalarValue(values[0], "A root's index").integerValue, n >= 2 else {
                throw MathFailure.math("A root's index must be a whole number of at least 2")
            }
            let x = try scalarValue(values[1], "A root")
            if x.doubleValue < 0 && n % 2 == 0 {
                throw MathFailure.math("An even root of a negative number isn't a real number")
            }
            return .scalar(try x.raised(to: Scalar.one.divided(by: Scalar(n))))
        default:
            return .scalar(try elementary(f, scalarValue(values[0], f.rawValue)))
        }
    }

    private func elementary(_ f: MathFunction, _ x: Scalar) throws -> Scalar {
        let d = x.doubleValue
        switch f {
        case .sqrt:
            if case .exact(let r) = x, let root = r.root(2) { return .exact(root) }
            guard d >= 0 else { throw MathFailure.math("The square root of a negative number isn't a real number") }
            return .real(d.squareRoot())
        case .sin:
            return .real(MathEvaluator.snapped(sin(d)))
        case .cos:
            return .real(MathEvaluator.snapped(cos(d)))
        case .tan:
            guard abs(cos(d)) > 1e-14 else { throw MathFailure.math("tan is undefined at odd multiples of π/2") }
            return .real(MathEvaluator.snapped(tan(d)))
        case .asin, .acos:
            guard abs(d) <= 1 + 1e-12 else { throw MathFailure.math("\(f.rawValue) needs a value between −1 and 1") }
            let clamped = min(1, max(-1, d))
            return .real(f == .asin ? asin(clamped) : acos(clamped))
        case .atan:
            return .real(atan(d))
        case .ln, .log:
            guard d > 0 else { throw MathFailure.math("Logarithms need a positive number") }
            return .real(f == .ln ? log(d) : log10(d))
        case .exp:
            return .real(exp(d))
        default:
            throw MathFailure.syntax("\(f.rawValue) needs different arguments")
        }
    }

    /// sin π is 1.2·10⁻¹⁶ in Doubles: trigonometric values that small are the rounding of an exact 0.
    static func snapped(_ x: Double) -> Double { abs(x) < 1e-14 ? 0 : x }

    /// f(2), g(1, 3), f'(2): parameters are bound to the arguments; the body sees the page, not the caller.
    private func callFunction(_ name: String, _ args: [MathNode], primes: Int) throws -> MathValue {
        guard let fn = definitions.functions[name] else {
            // "f = 3" on the page, then "f(2)": a variable times a bracket.
            if primes == 0, args.count == 1, locals[name] != nil || definitions.variables[name] != nil {
                return try checked(MathValue.multiply(lookUp(name), value(args[0])))
            }
            throw MathFailure.undefinedFunction(name)
        }
        guard args.count == fn.parameters.count else {
            throw MathFailure.math("\(name) takes \(fn.parameters.count) argument\(fn.parameters.count == 1 ? "" : "s")")
        }
        var arguments: [MathValue] = []
        for a in args { arguments.append(try value(a)) }
        guard depth < MathEvaluator.maxDepth else { throw MathFailure.math("\(name) calls itself too deeply") }
        depth += 1
        let saved = locals
        defer {
            locals = saved
            depth -= 1
        }
        if primes == 0 {
            var bound: [String: MathValue] = [:]
            for (i, parameter) in fn.parameters.enumerated() { bound[parameter] = arguments[i] }
            locals = bound
            return try value(fn.body)
        }
        guard fn.parameters.count == 1 else {
            throw MathFailure.unsupported("derivatives of functions of several variables")
        }
        guard primes <= 4 else { throw MathFailure.unsupported("derivatives of order \(primes)") }
        let x = try realValue(arguments[0])
        let parameter = fn.parameters[0]
        approximate = true
        let d = try MathEvaluator.differentiate(order: primes, at: x) { t in
            self.locals = [parameter: .scalar(.real(t))]
            return try self.realValue(self.value(fn.body))
        }
        return .scalar(.real(d))
    }

    // MARK: Sums, products, integrals, derivatives

    private func sumOrProduct(product: Bool, variable v: String, from: MathNode, to: MathNode,
                              body: MathNode) throws -> MathValue {
        let symbol = product ? "∏" : "∑"
        guard let lo = try scalarValue(value(from), "The bound of \(symbol)").integerValue,
              let hi = try scalarValue(value(to), "The bound of \(symbol)").integerValue else {
            throw MathFailure.math("The bounds of \(symbol) must be whole numbers")
        }
        if hi < lo { return .scalar(product ? .one : .zero) }
        let (span, overflow) = hi.subtractingReportingOverflow(lo)
        guard !overflow, span < MathEvaluator.maxTerms else {
            throw MathFailure.unsupported("\(symbol) with more than \(MathEvaluator.maxTerms) terms")
        }
        let saved = locals[v]
        defer { locals[v] = saved }
        var total: MathValue? = nil
        for i in lo...hi {
            locals[v] = .scalar(Scalar(i))
            let term = try value(body)
            if let t = total {
                total = try checked(product ? MathValue.multiply(t, term) : MathValue.add(t, term, subtract: false))
            } else {
                total = term
            }
        }
        return total ?? .scalar(product ? .one : .zero)
    }

    private func definiteIntegral(variable v: String, from: MathNode, to: MathNode, body: MathNode) throws -> MathValue {
        let a = try realValue(value(from))
        let b = try realValue(value(to))
        approximate = true
        let saved = locals[v]
        defer { locals[v] = saved }
        let result = try MathEvaluator.integrate(from: a, to: b) { x in
            self.locals[v] = .scalar(.real(x))
            return try self.realValue(self.value(body))
        }
        return .scalar(.real(result))
    }

    private func derivativeValue(variable v: String, order: Int, body: MathNode, at: MathNode?) throws -> MathValue {
        guard (1...4).contains(order) else { throw MathFailure.unsupported("derivatives of order \(order)") }
        let x: Double
        if let at = at {
            x = try realValue(value(at))
        } else {
            do {
                x = try realValue(lookUp(v))
            } catch {
                throw NibError(.invalidParams, "Say where to take the derivative",
                               hint: "write d/dx(x^2)|_{x=3}, diff(x^2, x, 3), or define \(v) on the page")
            }
        }
        approximate = true
        let saved = locals[v]
        defer { locals[v] = saved }
        let d = try MathEvaluator.differentiate(order: order, at: x) { t in
            self.locals[v] = .scalar(.real(t))
            return try self.realValue(self.value(body))
        }
        return .scalar(.real(d))
    }

    // MARK: Numeric calculus

    /// The order-th derivative at x: central differences with one Richardson step (error O(h⁴)), rounded to 9
    /// significant digits, which is what Doubles carry through a difference quotient.
    static func differentiate(order n: Int, at x: Double, _ f: (Double) throws -> Double) throws -> Double {
        let h = pow(Double.ulpOfOne, 1 / Double(n + 4)) * max(1, abs(x))
        let coarse = try centralDifference(order: n, at: x, step: h, f)
        let fine = try centralDifference(order: n, at: x, step: h / 2, f)
        let d = (4 * fine - coarse) / 3
        guard d.isFinite else { throw MathFailure.math("The derivative doesn't exist there") }
        return roundedToSignificant(d, 9)
    }

    private static func centralDifference(order n: Int, at x: Double, step h: Double,
                                          _ f: (Double) throws -> Double) throws -> Double {
        var sum = 0.0
        var binomial = 1.0
        for k in 0...n {
            let fx = try f(x + (Double(n) / 2 - Double(k)) * h)
            sum += (k % 2 == 0 ? binomial : -binomial) * fx
            binomial = binomial * Double(n - k) / Double(k + 1)
        }
        return sum / pow(h, Double(n))
    }

    static func roundedToSignificant(_ x: Double, _ digits: Int) -> Double {
        guard x != 0, x.isFinite else { return x }
        return Double(String(format: "%.\(digits)g", x)) ?? x
    }

    private struct Segment {
        var lo: Double
        var hi: Double
        var value: Double
        var error: Double
    }

    /// ∫ₐᵇ f by adaptive 15-point Gauss–Kronrod (the endpoints are never sampled, so 1/√x on [0, 1] works). Splits the
    /// worst segment until the error estimate is below 10⁻¹¹ relative, at most 400 times.
    static func integrate(from a: Double, to b: Double, _ f: (Double) throws -> Double) throws -> Double {
        guard a.isFinite, b.isFinite else { throw MathFailure.unsupported("improper integrals") }
        if a == b { return 0 }
        // Errors on the first pass (an undefined name, 1/x at the centre) are reported as they are.
        let first = try kronrod(f, a, b)
        var segments = [Segment(lo: a, hi: b, value: first.value, error: first.error)]
        do {
            for _ in 0..<400 {
                let total = segments.reduce(0.0) { $0 + $1.value }
                let error = segments.reduce(0.0) { $0 + $1.error }
                if error <= max(1e-12, 1e-11 * abs(total)) { return total }
                var worst = 0
                for i in segments.indices where segments[i].error > segments[worst].error { worst = i }
                let s = segments.remove(at: worst)
                let mid = (s.lo + s.hi) / 2
                let left = try kronrod(f, s.lo, mid)
                let right = try kronrod(f, mid, s.hi)
                segments.append(Segment(lo: s.lo, hi: mid, value: left.value, error: left.error))
                segments.append(Segment(lo: mid, hi: s.hi, value: right.value, error: right.error))
            }
        } catch let error as NibError where error.code == .invalidParams {
            throw MathFailure.math("The function isn't defined everywhere on the interval, so the integral doesn't exist")
        }
        let total = segments.reduce(0.0) { $0 + $1.value }
        let error = segments.reduce(0.0) { $0 + $1.error }
        guard total.isFinite, error <= 1e-7 * max(1, abs(total)) else {
            throw MathFailure.unsupported("this integral (it may not converge)")
        }
        return total
    }

    private static let kronrodNodes: [Double] = [
        0.991455371120812639206854697526329, 0.949107912342758524526189684047851, 0.864864423359769072789712788640926,
        0.741531185599394439863864773280788, 0.586087235467691130294144845693013, 0.405845151377397166906606412076961,
        0.207784955007898467600689403773245, 0.0,
    ]
    private static let kronrodWeights: [Double] = [
        0.022935322010529224963732008058970, 0.063092092629978553290700663189204, 0.104790010322250183839876322541518,
        0.140653259715525918745189590510238, 0.169004726639267902826583426598550, 0.190350578064785409913256402421014,
        0.204432940075298892414161999234649, 0.209482141084727828012999174891714,
    ]
    /// Weights of the embedded 7-point Gauss rule at kronrodNodes[1], [3], [5] and the centre.
    private static let gaussWeights: [Double] = [
        0.129484966168869693270611432679082, 0.279705391489276667901467771423780, 0.381830050505118944950369775488975,
        0.417959183673469387755102040816327,
    ]

    private static func kronrod(_ f: (Double) throws -> Double, _ lo: Double,
                                _ hi: Double) throws -> (value: Double, error: Double) {
        let center = (lo + hi) / 2
        let half = (hi - lo) / 2
        let fc = try f(center)
        var k15 = fc * kronrodWeights[7]
        var g7 = fc * gaussWeights[3]
        for j in 0..<7 {
            let dx = half * kronrodNodes[j]
            let f1 = try f(center - dx)
            let f2 = try f(center + dx)
            k15 += (f1 + f2) * kronrodWeights[j]
            if j % 2 == 1 { g7 += (f1 + f2) * gaussWeights[j / 2] }
        }
        return (k15 * half, abs((k15 - g7) * half))
    }
}
