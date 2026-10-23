import Foundation

/// Tiny arithmetic/comparison expression evaluator for the `eval:` search function.
/// Grammar: or := and ('||' and)* ; and := cmp ('&&' cmp)* ; cmp := add (op add)? ; add := mul (('+'|'-') mul)* ;
/// mul := unary (('*'|'/'|'%') unary)* ; unary := '-' unary | '!' unary | primary ; primary := number | string | '(' or ')'
/// This is a pure data evaluator (no code execution): it only folds literal numbers that were already substituted
/// into the expression text.
public struct Expression {
    public enum Value: Equatable { case number(Double), string(String) }
    public enum EvalError: Error, Equatable { case syntax(String) }

    private let tokens: [String]
    private var pos = 0

    public init(_ text: String) {
        tokens = Expression.tokenize(text)
    }

    public static func evaluate(_ text: String) throws -> Value {
        var e = Expression(text)
        let v = try e.parseOr()
        if e.pos != e.tokens.count { throw EvalError.syntax("unexpected token \(e.tokens[e.pos])") }
        return v
    }

    public static func isTrue(_ text: String) -> Bool {
        guard let v = try? evaluate(text) else { return false }
        switch v {
        case .number(let d): return d != 0
        case .string(let s): return !s.isEmpty
        }
    }

    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var n = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "_" { if chars[i] != "_" { n.append(chars[i]) }; i += 1 }
                // size units
                var unit = ""
                while i < chars.count, chars[i].isLetter { unit.append(chars[i]); i += 1 }
                if !unit.isEmpty, let m = ValueParser.sizeUnit(unit.lowercased(), standard: .jedec), let d = Double(n) { out.append(String(d * Double(m))) }
                else { out.append(n); if !unit.isEmpty { out.append("\"" + unit + "\"") } }
                continue
            }
            if c == "\"" || c == "'" {
                var j = i + 1; var str = ""
                while j < chars.count, chars[j] != c { str.append(chars[j]); j += 1 }
                out.append("\"" + str + "\""); i = j + 1; continue
            }
            if c.isLetter {
                var w = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber { w.append(chars[i]); i += 1 }
                switch w.lowercased() {
                case "true": out.append("1")
                case "false": out.append("0")
                case "and": out.append("&&")
                case "or": out.append("||")
                case "not": out.append("!")
                default: out.append("\"" + w + "\"")
                }
                continue
            }
            let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
            if ["<=", ">=", "==", "!=", "&&", "||"].contains(two) { out.append(two); i += 2; continue }
            out.append(String(c)); i += 1
        }
        return out
    }

    private mutating func peek() -> String? { pos < tokens.count ? tokens[pos] : nil }
    private mutating func next() -> String? { defer { pos += 1 }; return peek() }

    private mutating func parseOr() throws -> Value {
        var l = try parseAnd()
        while peek() == "||" { _ = next(); let r = try parseAnd(); l = .number((truthy(l) || truthy(r)) ? 1 : 0) }
        return l
    }
    private mutating func parseAnd() throws -> Value {
        var l = try parseCmp()
        while peek() == "&&" { _ = next(); let r = try parseCmp(); l = .number((truthy(l) && truthy(r)) ? 1 : 0) }
        return l
    }
    private mutating func parseCmp() throws -> Value {
        let l = try parseAdd()
        guard let op = peek(), ["<", "<=", ">", ">=", "==", "=", "!="].contains(op) else { return l }
        _ = next()
        let r = try parseAdd()
        let result: Bool
        switch (l, r) {
        case (.number(let a), .number(let b)):
            switch op { case "<": result = a < b; case "<=": result = a <= b; case ">": result = a > b; case ">=": result = a >= b; case "!=": result = a != b; default: result = a == b }
        default:
            let a = string(l), b = string(r)
            let c = a.compare(b, options: [.caseInsensitive, .numeric])
            switch op { case "<": result = c == .orderedAscending; case "<=": result = c != .orderedDescending; case ">": result = c == .orderedDescending; case ">=": result = c != .orderedAscending; case "!=": result = c != .orderedSame; default: result = c == .orderedSame }
        }
        return .number(result ? 1 : 0)
    }
    private mutating func parseAdd() throws -> Value {
        var l = try parseMul()
        while let op = peek(), op == "+" || op == "-" {
            _ = next(); let r = try parseMul()
            if op == "+", case .string = l { l = .string(string(l) + string(r)); continue }
            l = .number(op == "+" ? number(l) + number(r) : number(l) - number(r))
        }
        return l
    }
    private mutating func parseMul() throws -> Value {
        var l = try parseUnary()
        while let op = peek(), op == "*" || op == "/" || op == "%" {
            _ = next(); let r = try parseUnary()
            let b = number(r)
            switch op {
            case "*": l = .number(number(l) * b)
            case "/": l = .number(b == 0 ? 0 : number(l) / b)
            default: l = .number(b == 0 ? 0 : number(l).truncatingRemainder(dividingBy: b))
            }
        }
        return l
    }
    private mutating func parseUnary() throws -> Value {
        if peek() == "-" { _ = next(); return .number(-number(try parseUnary())) }
        if peek() == "!" { _ = next(); return .number(truthy(try parseUnary()) ? 0 : 1) }
        return try parsePrimary()
    }
    private mutating func parsePrimary() throws -> Value {
        guard let t = next() else { throw EvalError.syntax("unexpected end") }
        if t == "(" { let v = try parseOr(); guard next() == ")" else { throw EvalError.syntax("expected )") }; return v }
        if t.hasPrefix("\"") { return .string(String(t.dropFirst().dropLast())) }
        if let d = Double(t) { return .number(d) }
        throw EvalError.syntax("unexpected \(t)")
    }

    private func truthy(_ v: Value) -> Bool { switch v { case .number(let d): return d != 0; case .string(let s): return !s.isEmpty } }
    private func number(_ v: Value) -> Double { switch v { case .number(let d): return d; case .string(let s): return Double(s) ?? 0 } }
    private func string(_ v: Value) -> String { switch v { case .number(let d): return d == d.rounded() ? String(Int64(d)) : String(d); case .string(let s): return s } }
}
