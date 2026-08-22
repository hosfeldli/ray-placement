import Foundation

public enum CalculatorError: Error, LocalizedError {
    case invalidExpression
    case divisionByZero
    case unknownIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExpression: return "Invalid expression"
        case .divisionByZero: return "Division by zero"
        case .unknownIdentifier(let name): return "Unknown value: \(name)"
        }
    }
}

public enum Calculator {
    public static func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(expression)
        let value = try parser.parseExpression()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw CalculatorError.invalidExpression }
        guard value.isFinite else { throw CalculatorError.invalidExpression }
        return value
    }

    public static func formatted(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < Double(Int64.max) {
            return String(Int64(value))
        }
        return value.formatted(.number.precision(.fractionLength(0...10)))
    }

    private struct Parser {
        private let characters: [Character]
        private(set) var index = 0

        init(_ source: String) {
            self.characters = Array(source.replacingOccurrences(of: ",", with: ""))
        }

        var isAtEnd: Bool { index >= characters.count }

        mutating func skipWhitespace() {
            while !isAtEnd, characters[index].isWhitespace { index += 1 }
        }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while true {
                skipWhitespace()
                if consume("+") {
                    value += try parseTerm()
                } else if consume("-") {
                    value -= try parseTerm()
                } else {
                    return value
                }
            }
        }

        private mutating func parseTerm() throws -> Double {
            var value = try parsePower()
            while true {
                skipWhitespace()
                if consume("*") {
                    value *= try parsePower()
                } else if consume("/") {
                    let divisor = try parsePower()
                    guard divisor != 0 else { throw CalculatorError.divisionByZero }
                    value /= divisor
                } else if consume("%") {
                    let divisor = try parsePower()
                    guard divisor != 0 else { throw CalculatorError.divisionByZero }
                    value.formTruncatingRemainder(dividingBy: divisor)
                } else {
                    return value
                }
            }
        }

        private mutating func parsePower() throws -> Double {
            var value = try parseUnary()
            skipWhitespace()
            if consume("^") {
                value = Foundation.pow(value, try parsePower())
            }
            return value
        }

        private mutating func parseUnary() throws -> Double {
            skipWhitespace()
            if consume("+") { return try parseUnary() }
            if consume("-") { return -(try parseUnary()) }
            return try parsePrimary()
        }

        private mutating func parsePrimary() throws -> Double {
            skipWhitespace()
            if consume("(") {
                let value = try parseExpression()
                skipWhitespace()
                guard consume(")") else { throw CalculatorError.invalidExpression }
                return value
            }

            if let number = parseNumber() { return number }
            if let name = parseIdentifier() {
                switch name.lowercased() {
                case "pi", "π": return .pi
                case "e": return M_E
                default: throw CalculatorError.unknownIdentifier(name)
                }
            }
            throw CalculatorError.invalidExpression
        }

        private mutating func parseNumber() -> Double? {
            skipWhitespace()
            let start = index
            var seenDot = false
            while !isAtEnd {
                let character = characters[index]
                if character.isNumber {
                    index += 1
                } else if character == ".", !seenDot {
                    seenDot = true
                    index += 1
                } else {
                    break
                }
            }
            guard index > start else { return nil }
            return Double(String(characters[start..<index]))
        }

        private mutating func parseIdentifier() -> String? {
            skipWhitespace()
            let start = index
            while !isAtEnd, characters[index].isLetter || characters[index] == "π" { index += 1 }
            guard index > start else { return nil }
            return String(characters[start..<index])
        }

        private mutating func consume(_ character: Character) -> Bool {
            guard !isAtEnd, characters[index] == character else { return false }
            index += 1
            return true
        }
    }
}
