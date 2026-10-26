import Foundation
import RayPlacementCore

/// An explicit, local Search conversion. Unsupported or cross-dimension units
/// return nil instead of guessing or sending the expression to an AI provider.
enum SearchMeasurementConversion {
    struct Result: Equatable {
        let rawValue: Double
        let formatted: String
    }

    static func convert(_ query: String) -> Result? {
        let parts = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 4, parts[2].lowercased() == "to",
              let value = Double(parts[0].replacingOccurrences(of: ",", with: "")),
              value.isFinite else { return nil }
        let source = parts[1].lowercased()
        let destination = parts[3].lowercased()

        if let from = lengthUnit(source), let to = lengthUnit(destination) {
            let result = Measurement(value: value, unit: from).converted(to: to)
            return formattedResult(result.value, symbol: to.symbol)
        }
        if let from = massUnit(source), let to = massUnit(destination) {
            let result = Measurement(value: value, unit: from).converted(to: to)
            return formattedResult(result.value, symbol: to.symbol)
        }
        if let from = temperatureUnit(source), let to = temperatureUnit(destination) {
            let result = Measurement(value: value, unit: from).converted(to: to)
            return formattedResult(result.value, symbol: to.symbol)
        }
        return nil
    }

    private static func formattedResult(_ value: Double, symbol: String) -> Result? {
        guard value.isFinite else { return nil }
        return Result(rawValue: value, formatted: "\(Calculator.formatted(value)) \(symbol)")
    }

    private static func lengthUnit(_ name: String) -> UnitLength? {
        switch name {
        case "mi", "mile", "miles": return .miles
        case "km", "kilometer", "kilometers", "kilometre", "kilometres": return .kilometers
        case "m", "meter", "meters", "metre", "metres": return .meters
        case "ft", "foot", "feet": return .feet
        case "in", "inch", "inches": return .inches
        case "cm", "centimeter", "centimeters", "centimetre", "centimetres": return .centimeters
        default: return nil
        }
    }

    private static func massUnit(_ name: String) -> UnitMass? {
        switch name {
        case "kg", "kilogram", "kilograms": return .kilograms
        case "g", "gram", "grams": return .grams
        case "lb", "lbs", "pound", "pounds": return .pounds
        default: return nil
        }
    }

    private static func temperatureUnit(_ name: String) -> UnitTemperature? {
        switch name {
        case "c", "°c", "celsius": return .celsius
        case "f", "°f", "fahrenheit": return .fahrenheit
        case "k", "kelvin": return .kelvin
        default: return nil
        }
    }
}
