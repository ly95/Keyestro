import Foundation
import KeyestroDomain

public enum CalculatorError: Error, Equatable, Sendable {
    case empty
    case invalidToken(position: Int)
    case unexpectedToken
    case divisionByZero
    case overflow
    case tooComplex
    case incomplete
    case unsupportedUnit
    case incompatibleUnits

    public var descriptor: ErrorDescriptor {
        switch self {
        case .empty:
            ErrorDescriptor(code: "calculator.empty", message: "Enter a calculation.")
        case let .invalidToken(position):
            ErrorDescriptor(code: "calculator.invalidToken", message: "Invalid token at position \(position).")
        case .unexpectedToken:
            ErrorDescriptor(code: "calculator.unexpectedToken", message: "The expression contains an unexpected token.")
        case .divisionByZero:
            ErrorDescriptor(code: "calculator.divisionByZero", message: "Division by zero is undefined.")
        case .overflow:
            ErrorDescriptor(code: "calculator.overflow", message: "The result is outside the supported numeric range.")
        case .tooComplex:
            ErrorDescriptor(code: "calculator.tooComplex", message: "The expression is too long or deeply nested.")
        case .incomplete:
            ErrorDescriptor(code: "calculator.incomplete", message: "The expression is incomplete.")
        case .unsupportedUnit:
            ErrorDescriptor(code: "calculator.unsupportedUnit", message: "One of the units is not supported.")
        case .incompatibleUnits:
            ErrorDescriptor(code: "calculator.incompatibleUnits", message: "Those units measure different kinds of values.")
        }
    }
}

public struct CalculationResult: Equatable, Sendable {
    public let value: Double
    public let exactText: String
    public let displayText: String

    public init(value: Double, exactText: String, displayText: String) {
        self.value = value
        self.exactText = exactText
        self.displayText = displayText
    }
}

public struct CalculatorEngine: Sendable {
    public let maximumTokens: Int
    public let maximumDepth: Int

    public init(maximumTokens: Int = 256, maximumDepth: Int = 64) {
        self.maximumTokens = maximumTokens
        self.maximumDepth = maximumDepth
    }

    public func evaluate(_ expression: String, locale: Locale = .current) throws -> CalculationResult {
        let bounded = expression.limitedToUnicodeScalars(DomainLimits.queryUnicodeScalars)
        if UnitConverter.looksLikeConversion(bounded) {
            return try UnitConverter().convert(bounded, locale: locale)
        }
        let tokens = try Tokenizer(source: bounded, maximumTokens: maximumTokens).tokenize()
        var parser = Parser(tokens: tokens, maximumDepth: maximumDepth)
        let value = try parser.parse()
        guard value.isFinite else { throw CalculatorError.overflow }

        let exact = String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumSignificantDigits = 15
        formatter.usesSignificantDigits = true
        let display = formatter.string(from: NSNumber(value: value)) ?? exact
        return CalculationResult(value: value, exactText: exact, displayText: display)
    }
}

private enum Token: Equatable {
    case number(Double)
    case identifier(String)
    case plus
    case minus
    case multiply
    case divide
    case modulo
    case power
    case leftParen
    case rightParen
    case end
}

private struct Tokenizer {
    let source: String
    let maximumTokens: Int

    func tokenize() throws -> [Token] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalculatorError.empty
        }
        let characters = Array(source)
        var index = 0
        var output: [Token] = []

        func append(_ token: Token) throws {
            guard output.count < maximumTokens else { throw CalculatorError.tooComplex }
            output.append(token)
        }

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character.isNumber || character == "." {
                let start = index
                var hasDecimal = false
                while index < characters.count {
                    let current = characters[index]
                    if current == "." {
                        if hasDecimal { break }
                        hasDecimal = true
                        index += 1
                    } else if current.isNumber {
                        index += 1
                    } else {
                        break
                    }
                }
                if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                    index += 1
                    if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                        index += 1
                    }
                    let exponentStart = index
                    while index < characters.count, characters[index].isNumber { index += 1 }
                    guard exponentStart != index else { throw CalculatorError.incomplete }
                }
                let literal = String(characters[start..<index])
                guard let number = Double(literal), number.isFinite else {
                    throw CalculatorError.invalidToken(position: start)
                }
                try append(.number(number))
                continue
            }
            if character.isLetter {
                let start = index
                while index < characters.count, characters[index].isLetter { index += 1 }
                try append(.identifier(String(characters[start..<index]).lowercased()))
                continue
            }

            switch character {
            case "+": try append(.plus)
            case "-", "−": try append(.minus)
            case "*", "×": try append(.multiply)
            case "/", "÷": try append(.divide)
            case "%": try append(.modulo)
            case "^": try append(.power)
            case "(": try append(.leftParen)
            case ")": try append(.rightParen)
            default: throw CalculatorError.invalidToken(position: index)
            }
            index += 1
        }
        try append(.end)
        return output
    }
}

private struct Parser {
    let tokens: [Token]
    let maximumDepth: Int
    var index = 0
    var depth = 0

    mutating func parse() throws -> Double {
        let value = try parseAddition()
        guard current == .end else { throw CalculatorError.unexpectedToken }
        return value
    }

    private var current: Token { tokens[index] }

    @discardableResult
    private mutating func advance() -> Token {
        let token = current
        index = min(index + 1, tokens.count - 1)
        return token
    }

    private mutating func parseAddition() throws -> Double {
        var lhs = try parseMultiplication()
        while true {
            switch current {
            case .plus:
                advance()
                lhs += try parseMultiplication()
            case .minus:
                advance()
                lhs -= try parseMultiplication()
            default:
                return try checked(lhs)
            }
        }
    }

    private mutating func parseMultiplication() throws -> Double {
        var lhs = try parsePower()
        while true {
            switch current {
            case .multiply:
                advance()
                lhs *= try parsePower()
            case .divide:
                advance()
                let rhs = try parsePower()
                guard rhs != 0 else { throw CalculatorError.divisionByZero }
                lhs /= rhs
            case .modulo:
                advance()
                let rhs = try parsePower()
                guard rhs != 0 else { throw CalculatorError.divisionByZero }
                lhs.formTruncatingRemainder(dividingBy: rhs)
            default:
                return try checked(lhs)
            }
        }
    }

    private mutating func parsePower() throws -> Double {
        let lhs = try parseUnary()
        guard current == .power else { return lhs }
        advance()
        let rhs = try parsePower()
        return try checked(pow(lhs, rhs))
    }

    private mutating func parseUnary() throws -> Double {
        switch current {
        case .plus:
            advance()
            return try parseUnary()
        case .minus:
            advance()
            return try checked(-parseUnary())
        default:
            return try parsePrimary()
        }
    }

    private mutating func parsePrimary() throws -> Double {
        switch advance() {
        case let .number(value):
            return value
        case let .identifier(identifier):
            switch identifier {
            case "pi": return .pi
            case "e": return M_E
            case "tau": return .pi * 2
            default: throw CalculatorError.unexpectedToken
            }
        case .leftParen:
            depth += 1
            guard depth <= maximumDepth else { throw CalculatorError.tooComplex }
            let value = try parseAddition()
            guard current == .rightParen else { throw CalculatorError.incomplete }
            advance()
            depth -= 1
            return value
        case .end:
            throw CalculatorError.incomplete
        default:
            throw CalculatorError.unexpectedToken
        }
    }

    private func checked(_ value: Double) throws -> Double {
        guard value.isFinite else { throw CalculatorError.overflow }
        return value
    }
}
