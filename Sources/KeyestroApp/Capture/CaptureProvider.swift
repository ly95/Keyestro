import Foundation
import KeyestroCore
import KeyestroDomain

struct CaptureProvider: LauncherProvider {
    static let providerID = ProviderID("builtin.capture")
    let descriptor = ProviderDescriptor(
        id: providerID,
        displayName: "Capture",
        supportedModes: [.all, .commands],
        supportsEmptyQuery: true
    )

    private let coordinator: CaptureCoordinator

    init(coordinator: CaptureCoordinator) {
        self.coordinator = coordinator
    }

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let query = request.normalizedText
        let commands: [(CaptureOperation, String, String, String)] = [
            (.copyImage, "Capture Area to Clipboard", "Select a region across any display", "camera.viewfinder"),
            (.savePNG, "Capture Area to PNG File", "Select a region and choose where to save it", "square.and.arrow.down"),
            (.recognizeText, "Capture Area and Recognize Text", "Vision OCR runs entirely on this Mac", "text.viewfinder"),
        ]
        let items = commands.filter { command in
            query.isEmpty || TextNormalizer.normalize("\(command.1) \(command.2) screenshot ocr").contains(query)
        }.map { operation, title, subtitle, symbol in
            let itemID = ItemID(providerID: Self.providerID, providerStableID: operation.rawValue)
            let action = ActionDescriptor(id: "run", title: title, icon: .systemSymbol(symbol), risk: .safe)
            return LauncherItem(
                id: itemID,
                providerID: Self.providerID,
                title: title,
                subtitle: subtitle,
                icon: .systemSymbol(symbol),
                canonicalResource: .command("capture:\(operation.rawValue)"),
                keywords: ["screenshot", "capture", "ocr", "screen"],
                actions: [action],
                defaultActionID: action.id,
                scoreFeatures: ScoreFeatures(providerPrior: 0.15)
            )
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.items(items, isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult {
        guard request.actionID == "run",
            let operation = CaptureOperation(rawValue: request.itemID.providerStableID)
        else { return .failure(ErrorDescriptor(code: "capture.invalidAction", message: "The capture action is unavailable.")) }
        return await coordinator.perform(operation)
    }
}
