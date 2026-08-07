import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test(arguments: [
    ("1 + 2 * 3", 7.0),
    ("(1 + 2) * 3", 9.0),
    ("2 ^ 3 ^ 2", 512.0),
    ("-2 ^ 2", 4.0),
    ("10 % 4", 2.0),
    ("pi * 2", Double.pi * 2),
])
func calculatorEvaluatesExpressions(expression: String, expected: Double) throws {
    let result = try CalculatorEngine().evaluate(expression)
    #expect(abs(result.value - expected) < 0.000_000_1)
}

@Test func calculatorRejectsDivisionByZero() {
    #expect(throws: CalculatorError.divisionByZero) {
        try CalculatorEngine().evaluate("1 / 0")
    }
}

@Test func calculatorLimitsDepth() {
    #expect(throws: CalculatorError.tooComplex) {
        try CalculatorEngine(maximumDepth: 2).evaluate("(((1)))")
    }
}

@Test func calculatorCoversFiveHundredFixedVectors() throws {
    let engine = CalculatorEngine()
    for index in 0..<500 {
        let a = Double((index * 17) % 101) - 50
        let b = Double((index * 29) % 37) + 1
        let c = Double((index * 43) % 19) - 9
        let expression = "(\(a) + \(b)) * \(c) - \(b) / 2"
        let expected = (a + b) * c - b / 2
        let actual = try engine.evaluate(expression)
        #expect(abs(actual.value - expected) < 0.000_000_1, "vector \(index): \(expression)")
    }
}

@Test(arguments: [
    ("10 km to mi", 6.213_711_922_373_339, "mi"),
    ("32 °F to °C", 0, "°C"),
    ("2.5 acres to m2", 10_117.141_056, "m²"),
    ("1 gallon to ml", 3_785.411_784, "mL"),
    ("16 oz to lb", 1, "lb"),
    ("2 days to hours", 48, "h"),
    ("1 GiB to MiB", 1_024, "MiB"),
])
func calculatorConvertsCommonUnits(expression: String, expected: Double, symbol: String) throws {
    let result = try CalculatorEngine().evaluate(expression, locale: Locale(identifier: "en_US"))
    #expect(abs(result.value - expected) < 0.000_000_1)
    #expect(result.exactText.hasSuffix(" \(symbol)"))
}

@Test func calculatorRejectsIncompatibleUnitDimensions() {
    #expect(throws: CalculatorError.incompatibleUnits) {
        try CalculatorEngine().evaluate("1 kg to m")
    }
}

@Test func unitConverterRejectsEveryMalformedBoundaryAndOverflow() {
    let converter = KeyestroCore.UnitConverter()
    #expect(KeyestroCore.UnitConverter.looksLikeConversion("1 m → cm"))
    #expect(KeyestroCore.UnitConverter.looksLikeConversion("1 m in cm"))
    #expect(!KeyestroCore.UnitConverter.looksLikeConversion("1 m"))
    #expect(throws: CalculatorError.incomplete) { try converter.convert("1 m") }
    #expect(throws: CalculatorError.incomplete) { try converter.convert("→m") }
    #expect(throws: CalculatorError.invalidToken(position: 0)) { try converter.convert("word m to cm") }
    #expect(throws: CalculatorError.invalidToken(position: 0)) { try converter.convert("1e999 m to cm") }
    #expect(throws: CalculatorError.invalidToken(position: 0)) { try converter.convert("1 to cm") }
    #expect(throws: CalculatorError.unsupportedUnit) { try converter.convert("1 mystery to cm") }
    #expect(throws: CalculatorError.overflow) { try converter.convert("1e308 km to mm") }
}

@Test func calculatorCoversSeededPropertyCorpusAndUnicodeOperators() throws {
    let engine = CalculatorEngine()
    var random = DeterministicCalculatorRandom(seed: 0x4B_45_59_45_53_54_52_4F)
    for index in 0..<1_000 {
        let a = Double(random.next(in: -50...50))
        let b = Double(random.next(in: -25...25))
        let c = Double(random.next(in: 1...12))
        let divisor = Double(random.next(in: 1...9))
        let expression: String
        let expected: Double
        switch index % 5 {
        case 0:
            expression = "\(a) + \(b) * \(c)"
            expected = a + b * c
        case 1:
            expression = "(\(a) - \(b)) * (\(c) + 1)"
            expected = (a - b) * (c + 1)
        case 2:
            expression = "-(\(a)) + \(b) ^ 2"
            expected = -a + pow(b, 2)
        case 3:
            expression = "(\(a) * \(b)) % \(divisor)"
            expected = (a * b).truncatingRemainder(dividingBy: divisor)
        default:
            expression = "\(a) / \(divisor) + \(c)"
            expected = a / divisor + c
        }
        let actual = try engine.evaluate(expression)
        #expect(abs(actual.value - expected) < 0.000_000_1, "seeded vector \(index): \(expression)")
    }

    #expect(try engine.evaluate("6 × 7").value == 42)
    #expect(try engine.evaluate("8 ÷ 2").value == 4)
    #expect(try engine.evaluate("−5 + 2").value == -3)
}

@Test func calculatorExtremeAndHostileInputsFailWithinOneHundredMilliseconds() {
    let engine = CalculatorEngine()
    let hostile = [
        String(repeating: "(", count: 10_000) + "1" + String(repeating: ")", count: 10_000),
        String(repeating: "1+", count: 10_000),
        "1e308 * 1e308",
        "1 / 0",
        "💥 + 1",
        "1; /usr/bin/touch /tmp/keyestro-must-not-exist",
        "$(open https://example.invalid)",
        "`id`",
    ]
    let started = ContinuousClock.now
    for input in hostile {
        do {
            _ = try engine.evaluate(input)
            Issue.record("Expected hostile calculator input to fail: \(input.prefix(40))")
        } catch is CalculatorError {
            // Every failure is a bounded domain error.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
    #expect(started.duration(to: .now) < .milliseconds(100))
}

@Test @MainActor func calculatorCopiesTheExactUnformattedResultThroughThePasteboardBoundary() async throws {
    let pasteboard = FakePasteboardService()
    let provider = CalculatorProvider(pasteboard: pasteboard)
    let request = QueryRequest(
        generation: 1,
        rawText: "1000 + 2",
        normalizedText: "1000 + 2",
        mode: .calculator
    )
    var item: LauncherItem?
    for try await event in provider.search(request: request) {
        if case let .items(items, _) = event { item = items.first }
    }
    let resultItem = try #require(item)
    let outcome = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: resultItem.id,
            actionID: resultItem.defaultActionID,
            arguments: [:]
        )
    )

    guard case .success = outcome else {
        Issue.record("Expected the calculator copy action to succeed")
        return
    }
    #expect(pasteboard.content == .text("1002"))
}

private struct DeterministicCalculatorRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int((state >> 16) % width)
    }
}
