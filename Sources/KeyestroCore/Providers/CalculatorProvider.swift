import Foundation
import KeyestroDomain

public struct CalculatorProvider: LauncherProvider {
    public let descriptor = ProviderDescriptor(
        id: "calculator",
        displayName: "Calculator",
        supportedModes: [.all, .calculator],
        supportsEmptyQuery: false
    )
    private let engine: CalculatorEngine
    private let pasteboard: any PasteboardServicing

    public init(
        engine: CalculatorEngine = CalculatorEngine(),
        pasteboard: any PasteboardServicing = MacPasteboardService()
    ) {
        self.engine = engine
        self.pasteboard = pasteboard
    }

    public func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let task = Task {
            guard request.mode == .calculator || looksLikeExpression(request.normalizedText) else {
                continuation.yield(.items([], isFinal: true))
                continuation.finish()
                return
            }
            do {
                let result = try engine.evaluate(request.normalizedText)
                let itemID = ItemID(
                    providerID: descriptor.id,
                    providerStableID: "expression:\(request.normalizedText)"
                )
                let copy = ActionDescriptor(
                    id: "copy",
                    title: "Copy Result",
                    icon: .systemSymbol("doc.on.doc"),
                    behavior: .closeLauncher
                )
                let item = LauncherItem(
                    id: itemID,
                    providerID: descriptor.id,
                    title: result.displayText,
                    subtitle: request.rawText,
                    icon: .systemSymbol("function"),
                    canonicalResource: .command("calculator:\(request.normalizedText)"),
                    keywords: ["calculate", "calculator"],
                    accessories: [.text("Copy")],
                    actions: [copy],
                    defaultActionID: copy.id,
                    scoreFeatures: ScoreFeatures(providerPrior: 0.9)
                )
                continuation.yield(.items([item], isFinal: true))
            } catch let error as CalculatorError {
                if request.mode == .calculator, error != .incomplete {
                    continuation.yield(.status(.failed(error.descriptor)))
                }
                continuation.yield(.items([], isFinal: true))
            } catch {
                continuation.yield(
                    .status(
                        .failed(
                            ErrorDescriptor(
                                code: "calculator.unknown",
                                message: "The calculation could not be completed."
                            )
                        )
                    )
                )
                continuation.yield(.items([], isFinal: true))
            }
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func execute(request: ProviderActionRequest) async -> ActionResult {
        guard request.actionID == "copy",
            request.itemID.providerID == descriptor.id,
            request.itemID.providerStableID.hasPrefix("expression:")
        else {
            return .failure(
                ErrorDescriptor(code: "calculator.invalidAction", message: "The calculation action is invalid.")
            )
        }
        let expression = String(request.itemID.providerStableID.dropFirst("expression:".count))
        do {
            let result = try engine.evaluate(expression)
            guard await pasteboard.write(.text(result.exactText)) else {
                return .failure(
                    ErrorDescriptor(code: "calculator.copyFailed", message: "The result could not be copied.")
                )
            }
            return .success(message: "Result copied")
        } catch let error as CalculatorError {
            return .failure(error.descriptor)
        } catch {
            return .failure(
                ErrorDescriptor(code: "calculator.executionFailed", message: "The result could not be copied.")
            )
        }
    }

    private func looksLikeExpression(_ text: String) -> Bool {
        guard text.contains(where: \Character.isNumber) else { return false }
        return UnitConverter.looksLikeConversion(text) || text.contains { "+-−*×/÷%^()".contains($0) }
    }
}
