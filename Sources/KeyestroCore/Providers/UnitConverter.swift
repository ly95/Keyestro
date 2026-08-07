import Foundation

private enum UnitDimension: Sendable {
    case length
    case area
    case volume
    case mass
    case temperature
    case time
    case data
}

private struct UnitDefinition: Sendable {
    let dimension: UnitDimension
    let symbol: String
    let multiplier: Double
    let offset: Double

    func valueInBaseUnit(_ value: Double) -> Double {
        (value + offset) * multiplier
    }

    func valueFromBaseUnit(_ value: Double) -> Double {
        value / multiplier - offset
    }
}

/// Converts bounded, explicit expressions such as `10 km to mi` without evaluating code or using a network service.
public struct UnitConverter: Sendable {
    public init() {}

    public static func looksLikeConversion(_ source: String) -> Bool {
        let lowercased = source.lowercased()
        return lowercased.contains(" to ") || lowercased.contains(" in ") || source.contains("→")
    }

    public func convert(_ source: String, locale: Locale = .current) throws -> CalculationResult {
        let bounded = source.limitedToUnicodeScalars(512).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = Self.split(bounded) else { throw CalculatorError.incomplete }
        let (value, sourceToken) = try Self.parseValueAndUnit(parts.source)
        guard let sourceUnit = Self.units[Self.normalize(sourceToken)],
            let targetUnit = Self.units[Self.normalize(parts.target)]
        else { throw CalculatorError.unsupportedUnit }
        guard sourceUnit.dimension == targetUnit.dimension else { throw CalculatorError.incompatibleUnits }

        let baseValue = sourceUnit.valueInBaseUnit(value)
        let converted = targetUnit.valueFromBaseUnit(baseValue)
        guard converted.isFinite else { throw CalculatorError.overflow }

        let exactNumber = String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), converted)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumSignificantDigits = 15
        formatter.usesSignificantDigits = true
        let displayNumber = formatter.string(from: NSNumber(value: converted)) ?? exactNumber
        return CalculationResult(
            value: converted,
            exactText: "\(exactNumber) \(targetUnit.symbol)",
            displayText: "\(displayNumber) \(targetUnit.symbol)"
        )
    }

    private static func split(_ source: String) -> (source: String, target: String)? {
        for separator in [" to ", " in ", "→"] {
            guard let range = source.range(of: separator, options: [.caseInsensitive]) else { continue }
            let lhs = source[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = source[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lhs.isEmpty, !rhs.isEmpty else { return nil }
            return (lhs, rhs)
        }
        return nil
    }

    private static func parseValueAndUnit(_ source: String) throws -> (Double, String) {
        let characters = Array(source)
        var index = 0
        let numberStart = index
        while index < characters.count, "+-−.0123456789eE".contains(characters[index]) { index += 1 }
        let numberText = String(characters[numberStart..<index]).replacingOccurrences(of: "−", with: "-")
        let unitText = String(characters[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(numberText), value.isFinite, !unitText.isEmpty else {
            throw CalculatorError.invalidToken(position: numberStart)
        }
        return (value, unitText)
    }

    private static func normalize(_ source: String) -> String {
        source
            .lowercased()
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "²", with: "2")
            .replacingOccurrences(of: "³", with: "3")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    private static func linear(_ dimension: UnitDimension, _ symbol: String, _ multiplier: Double) -> UnitDefinition {
        UnitDefinition(dimension: dimension, symbol: symbol, multiplier: multiplier, offset: 0)
    }

    private static let units: [String: UnitDefinition] = {
        let entries: [(aliases: [String], definition: UnitDefinition)] = [
            (["mm", "millimeter", "millimeters"], linear(.length, "mm", 0.001)),
            (["cm", "centimeter", "centimeters"], linear(.length, "cm", 0.01)),
            (["m", "meter", "meters", "metre", "metres"], linear(.length, "m", 1)),
            (["km", "kilometer", "kilometers", "kilometre", "kilometres"], linear(.length, "km", 1_000)),
            (["in", "inch", "inches"], linear(.length, "in", 0.0254)),
            (["ft", "foot", "feet"], linear(.length, "ft", 0.3048)),
            (["yd", "yard", "yards"], linear(.length, "yd", 0.9144)),
            (["mi", "mile", "miles"], linear(.length, "mi", 1_609.344)),
            (["mm2", "sqmm"], linear(.area, "mm²", 0.000_001)),
            (["cm2", "sqcm"], linear(.area, "cm²", 0.0001)),
            (["m2", "sqm"], linear(.area, "m²", 1)),
            (["km2", "sqkm"], linear(.area, "km²", 1_000_000)),
            (["in2", "sqin"], linear(.area, "in²", 0.000_645_16)),
            (["ft2", "sqft"], linear(.area, "ft²", 0.092_903_04)),
            (["acre", "acres"], linear(.area, "ac", 4_046.856_422_4)),
            (["ha", "hectare", "hectares"], linear(.area, "ha", 10_000)),
            (["ml", "milliliter", "milliliters", "millilitre", "millilitres"], linear(.volume, "mL", 0.001)),
            (["l", "liter", "liters", "litre", "litres"], linear(.volume, "L", 1)),
            (["m3"], linear(.volume, "m³", 1_000)),
            (["tsp", "teaspoon", "teaspoons"], linear(.volume, "tsp", 0.004_928_921_593_75)),
            (["tbsp", "tablespoon", "tablespoons"], linear(.volume, "tbsp", 0.014_786_764_781_25)),
            (["cup", "cups"], linear(.volume, "cup", 0.236_588_236_5)),
            (["pt", "pint", "pints"], linear(.volume, "pt", 0.473_176_473)),
            (["qt", "quart", "quarts"], linear(.volume, "qt", 0.946_352_946)),
            (["gal", "gallon", "gallons"], linear(.volume, "gal", 3.785_411_784)),
            (["mg", "milligram", "milligrams"], linear(.mass, "mg", 0.000_001)),
            (["g", "gram", "grams"], linear(.mass, "g", 0.001)),
            (["kg", "kilogram", "kilograms"], linear(.mass, "kg", 1)),
            (["oz", "ounce", "ounces"], linear(.mass, "oz", 0.028_349_523_125)),
            (["lb", "lbs", "pound", "pounds"], linear(.mass, "lb", 0.453_592_37)),
            (["t", "tonne", "tonnes", "metricton"], linear(.mass, "t", 1_000)),
            (["c", "celsius"], UnitDefinition(dimension: .temperature, symbol: "°C", multiplier: 1, offset: 0)),
            (["f", "fahrenheit"], UnitDefinition(dimension: .temperature, symbol: "°F", multiplier: 5 / 9, offset: -32)),
            (["k", "kelvin"], UnitDefinition(dimension: .temperature, symbol: "K", multiplier: 1, offset: -273.15)),
            (["ms", "millisecond", "milliseconds"], linear(.time, "ms", 0.001)),
            (["s", "sec", "second", "seconds"], linear(.time, "s", 1)),
            (["min", "minute", "minutes"], linear(.time, "min", 60)),
            (["h", "hr", "hour", "hours"], linear(.time, "h", 3_600)),
            (["d", "day", "days"], linear(.time, "d", 86_400)),
            (["wk", "week", "weeks"], linear(.time, "wk", 604_800)),
            (["b", "byte", "bytes"], linear(.data, "B", 1)),
            (["kb", "kilobyte", "kilobytes"], linear(.data, "KB", 1_000)),
            (["mb", "megabyte", "megabytes"], linear(.data, "MB", 1_000_000)),
            (["gb", "gigabyte", "gigabytes"], linear(.data, "GB", 1_000_000_000)),
            (["tb", "terabyte", "terabytes"], linear(.data, "TB", 1_000_000_000_000)),
            (["kib", "kibibyte", "kibibytes"], linear(.data, "KiB", 1_024)),
            (["mib", "mebibyte", "mebibytes"], linear(.data, "MiB", 1_048_576)),
            (["gib", "gibibyte", "gibibytes"], linear(.data, "GiB", 1_073_741_824)),
            (["tib", "tebibyte", "tebibytes"], linear(.data, "TiB", 1_099_511_627_776)),
        ]
        var output: [String: UnitDefinition] = [:]
        for entry in entries {
            for alias in entry.aliases { output[normalize(alias)] = entry.definition }
        }
        return output
    }()
}
