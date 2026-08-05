import AppKit
import ApplicationServices
import Foundation
import KeyestroDomain

public enum WindowLayoutAction: String, Codable, CaseIterable, Sendable {
    case focus
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case maximize
    case center
    case restore
    case nextDisplay
}

public struct AccessibleWindowRecord: Equatable, Identifiable, Sendable {
    public let id: String
    public let processIdentifier: pid_t
    public let applicationName: String
    public let bundleIdentifier: String?
    public let title: String
    public let isMinimized: Bool
    public let frame: CGRect?
    public let screenIdentifier: String?
    public let screenName: String?

    public init(
        id: String,
        processIdentifier: pid_t,
        applicationName: String,
        bundleIdentifier: String?,
        title: String,
        isMinimized: Bool,
        frame: CGRect?,
        screenIdentifier: String?,
        screenName: String? = nil
    ) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.isMinimized = isMinimized
        self.frame = frame
        self.screenIdentifier = screenIdentifier
        self.screenName = screenName
    }
}

public enum AccessibilityServiceError: Error, Equatable, Sendable {
    case permissionDenied
    case windowNotFound
    case unsupported
    case operationFailed(code: Int32)

    public var descriptor: ErrorDescriptor {
        switch self {
        case .permissionDenied:
            ErrorDescriptor(
                code: "accessibility.permissionDenied",
                message: "Accessibility permission is required for window management.",
                recoverySuggestion: "Open Settings → Permissions to grant access, then refresh."
            )
        case .windowNotFound:
            ErrorDescriptor(code: "accessibility.windowNotFound", message: "The window is no longer available.")
        case .unsupported:
            ErrorDescriptor(code: "accessibility.unsupported", message: "This window does not support that operation.")
        case let .operationFailed(code):
            ErrorDescriptor(code: "accessibility.operation.\(code)", message: "The window operation failed.")
        }
    }
}

public protocol AccessibilityServicing: Sendable {
    func isTrusted() async -> Bool
    func windows() async throws -> [AccessibleWindowRecord]
    func perform(_ action: WindowLayoutAction, windowID: String) async throws
}

public enum WindowFrameCalculator {
    public static func frame(
        for action: WindowLayoutAction,
        current: CGRect,
        visibleFrame: CGRect
    ) -> CGRect? {
        let halfWidth = floor(visibleFrame.width / 2)
        let halfHeight = floor(visibleFrame.height / 2)
        let rightWidth = visibleFrame.width - halfWidth
        let topHeight = visibleFrame.height - halfHeight
        let result: CGRect
        switch action {
        case .leftHalf:
            result = CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
        case .rightHalf:
            result = CGRect(x: visibleFrame.minX + halfWidth, y: visibleFrame.minY, width: rightWidth, height: visibleFrame.height)
        case .topHalf:
            result = CGRect(x: visibleFrame.minX, y: visibleFrame.minY + halfHeight, width: visibleFrame.width, height: topHeight)
        case .bottomHalf:
            result = CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: halfHeight)
        case .topLeftQuarter:
            result = CGRect(x: visibleFrame.minX, y: visibleFrame.minY + halfHeight, width: halfWidth, height: topHeight)
        case .topRightQuarter:
            result = CGRect(x: visibleFrame.minX + halfWidth, y: visibleFrame.minY + halfHeight, width: rightWidth, height: topHeight)
        case .bottomLeftQuarter:
            result = CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            result = CGRect(x: visibleFrame.minX + halfWidth, y: visibleFrame.minY, width: rightWidth, height: halfHeight)
        case .maximize:
            result = visibleFrame
        case .center:
            let width = min(current.width, visibleFrame.width)
            let height = min(current.height, visibleFrame.height)
            result = CGRect(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.midY - height / 2,
                width: width,
                height: height
            )
        case .focus, .restore, .nextDisplay:
            return nil
        }
        return clamp(result, to: visibleFrame)
    }

    public static func clamp(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let width = min(max(1, frame.width), visibleFrame.width)
        let height = min(max(1, frame.height), visibleFrame.height)
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct RunningApplicationSummary: Sendable {
    let processIdentifier: pid_t
    let name: String
    let bundleIdentifier: String?
}

private struct ScreenGeometry: Sendable {
    let identifier: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
}

struct AccessibilityCircuitBreaker: Sendable {
    private struct State: Sendable {
        var consecutiveFailures: Int
        var openedUntil: Date?
        var updatedAt: Date
    }

    private var states: [pid_t: State] = [:]
    private let failureThreshold: Int
    private let cooldown: TimeInterval
    private let maximumProcesses: Int

    init(failureThreshold: Int = 2, cooldown: TimeInterval = 30, maximumProcesses: Int = 256) {
        self.failureThreshold = max(1, failureThreshold)
        self.cooldown = min(max(1, cooldown), 300)
        self.maximumProcesses = min(max(1, maximumProcesses), 1_024)
    }

    mutating func allows(_ processIdentifier: pid_t, at now: Date) -> Bool {
        guard var state = states[processIdentifier] else { return true }
        if let openedUntil = state.openedUntil {
            guard now >= openedUntil else { return false }
            state.consecutiveFailures = 0
            state.openedUntil = nil
            state.updatedAt = now
            states[processIdentifier] = state
        }
        return true
    }

    mutating func recordFailure(_ processIdentifier: pid_t, at now: Date) {
        var state = states[processIdentifier] ?? State(consecutiveFailures: 0, openedUntil: nil, updatedAt: now)
        state.consecutiveFailures += 1
        state.updatedAt = now
        if state.consecutiveFailures >= failureThreshold {
            state.openedUntil = now.addingTimeInterval(cooldown)
        }
        states[processIdentifier] = state
        pruneIfNeeded()
    }

    mutating func recordSuccess(_ processIdentifier: pid_t) {
        states[processIdentifier] = nil
    }

    mutating func removeMissingProcesses(_ active: Set<pid_t>) {
        states = states.filter { active.contains($0.key) }
    }

    private mutating func pruneIfNeeded() {
        guard states.count > maximumProcesses else { return }
        for key in states.sorted(by: { $0.value.updatedAt < $1.value.updatedAt })
            .prefix(states.count - maximumProcesses).map(\.key)
        {
            states[key] = nil
        }
    }
}

public actor MacAccessibilityService: AccessibilityServicing {
    private enum Attribute {
        static let windows = "AXWindows"
        static let title = "AXTitle"
        static let minimized = "AXMinimized"
        static let position = "AXPosition"
        static let size = "AXSize"
        static let focused = "AXFocused"
        static let main = "AXMain"
        static let fullScreen = "AXFullScreen"
        static let raise = "AXRaise"
    }

    private var elements: [String: AXUIElement] = [:]
    private var records: [String: AccessibleWindowRecord] = [:]
    private var previousFrames: [String: CGRect] = [:]
    private var circuitBreaker = AccessibilityCircuitBreaker()
    private var scanGeneration: UInt64 = 0
    private let clock: any ClockServicing

    public init(clock: any ClockServicing = SystemClockService()) {
        self.clock = clock
    }

    public func isTrusted() -> Bool { AXIsProcessTrusted() }

    public func windows() async throws -> [AccessibleWindowRecord] {
        scanGeneration &+= 1
        let generation = scanGeneration
        guard AXIsProcessTrusted() else { throw AccessibilityServiceError.permissionDenied }
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> RunningApplicationSummary? in
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                    app.activationPolicy != .prohibited,
                    let name = app.localizedName
                else { return nil }
                return RunningApplicationSummary(
                    processIdentifier: app.processIdentifier,
                    name: name,
                    bundleIdentifier: app.bundleIdentifier
                )
            }
        }
        let screens = await Self.screenGeometries()
        let primaryTop = await Self.primaryScreenTop()
        let now = await clock.wallTime()
        guard generation == scanGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        circuitBreaker.removeMissingProcesses(Set(running.map(\.processIdentifier)))
        var newElements: [String: AXUIElement] = [:]
        var newRecords: [String: AccessibleWindowRecord] = [:]

        for app in running {
            try Task.checkCancellation()
            guard circuitBreaker.allows(app.processIdentifier, at: now) else { continue }
            let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(applicationElement, 0.2)
            let windowResult: (value: [AXUIElement]?, status: AXError) = copyResult(
                Attribute.windows,
                from: applicationElement
            )
            guard let windowElements = windowResult.value else {
                if windowResult.status == .cannotComplete {
                    circuitBreaker.recordFailure(app.processIdentifier, at: now)
                }
                continue
            }
            circuitBreaker.recordSuccess(app.processIdentifier)
            for (index, window) in windowElements.prefix(100).enumerated() {
                if index.isMultiple(of: 25) { try Task.checkCancellation() }
                let hash = CFHash(window)
                let id = "\(app.processIdentifier):\(hash)"
                let title: String = copy(Attribute.title, from: window) ?? app.name
                let minimized: Bool = copy(Attribute.minimized, from: window) ?? false
                let cocoaFrame = axFrame(window).map { Self.cocoaFrame(fromAX: $0, primaryTop: primaryTop) }
                let screen = cocoaFrame.flatMap { frame in
                    screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
                }
                let record = AccessibleWindowRecord(
                    id: id,
                    processIdentifier: app.processIdentifier,
                    applicationName: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    title: title.isEmpty ? app.name : title,
                    isMinimized: minimized,
                    frame: cocoaFrame,
                    screenIdentifier: screen?.identifier,
                    screenName: screen?.name
                )
                newElements[id] = window
                newRecords[id] = record
            }
        }
        elements = newElements
        records = newRecords
        return newRecords.values.sorted {
            if $0.applicationName != $1.applicationName {
                return $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public func perform(_ action: WindowLayoutAction, windowID: String) async throws {
        guard AXIsProcessTrusted() else { throw AccessibilityServiceError.permissionDenied }
        guard let element = elements[windowID], let record = records[windowID] else {
            throw AccessibilityServiceError.windowNotFound
        }
        if action == .focus {
            try focus(element: element, record: record)
            return
        }
        let isFullScreen: Bool = copy(Attribute.fullScreen, from: element) ?? false
        guard !isFullScreen,
            isSettable(Attribute.position, element: element),
            isSettable(Attribute.size, element: element),
            let currentAXFrame = axFrame(element)
        else { throw AccessibilityServiceError.unsupported }

        let screens = await Self.screenGeometries()
        let primaryTop = await Self.primaryScreenTop()
        let current = Self.cocoaFrame(fromAX: currentAXFrame, primaryTop: primaryTop)
        guard
            let currentIndex = screens.firstIndex(where: {
                $0.frame.contains(CGPoint(x: current.midX, y: current.midY))
            }) ?? screens.indices.first
        else {
            throw AccessibilityServiceError.unsupported
        }

        let desired: CGRect
        switch action {
        case .restore:
            guard let previous = previousFrames[windowID] else { throw AccessibilityServiceError.unsupported }
            desired = WindowFrameCalculator.clamp(previous, to: screens[currentIndex].visibleFrame)
        case .nextDisplay:
            guard screens.count > 1 else { throw AccessibilityServiceError.unsupported }
            let target = screens[(currentIndex + 1) % screens.count]
            let currentScreen = screens[currentIndex]
            let relativeX = (current.minX - currentScreen.visibleFrame.minX) / max(1, currentScreen.visibleFrame.width)
            let relativeY = (current.minY - currentScreen.visibleFrame.minY) / max(1, currentScreen.visibleFrame.height)
            desired = WindowFrameCalculator.clamp(
                CGRect(
                    x: target.visibleFrame.minX + relativeX * target.visibleFrame.width,
                    y: target.visibleFrame.minY + relativeY * target.visibleFrame.height,
                    width: min(current.width, target.visibleFrame.width),
                    height: min(current.height, target.visibleFrame.height)
                ),
                to: target.visibleFrame
            )
        default:
            guard
                let frame = WindowFrameCalculator.frame(
                    for: action,
                    current: current,
                    visibleFrame: screens[currentIndex].visibleFrame
                )
            else { throw AccessibilityServiceError.unsupported }
            desired = frame
        }
        if action != .restore { previousFrames[windowID] = current }
        let axDesired = Self.axFrame(fromCocoa: desired, primaryTop: primaryTop)
        try setFrame(axDesired, element: element)
    }

    private func focus(element: AXUIElement, record: AccessibleWindowRecord) throws {
        if record.isMinimized, isSettable(Attribute.minimized, element: element) {
            let status = AXUIElementSetAttributeValue(element, Attribute.minimized as CFString, false as CFBoolean)
            guard status == .success else { throw AccessibilityServiceError.operationFailed(code: status.rawValue) }
        }
        AXUIElementSetAttributeValue(element, Attribute.main as CFString, true as CFBoolean)
        AXUIElementSetAttributeValue(element, Attribute.focused as CFString, true as CFBoolean)
        let status = AXUIElementPerformAction(element, Attribute.raise as CFString)
        guard status == .success else { throw AccessibilityServiceError.operationFailed(code: status.rawValue) }
        let pid = record.processIdentifier
        Task { @MainActor in NSRunningApplication(processIdentifier: pid)?.activate() }
    }

    private func setFrame(_ frame: CGRect, element: AXUIElement) throws {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { throw AccessibilityServiceError.unsupported }
        let positionStatus = AXUIElementSetAttributeValue(element, Attribute.position as CFString, positionValue)
        let sizeStatus = AXUIElementSetAttributeValue(element, Attribute.size as CFString, sizeValue)
        guard positionStatus == .success, sizeStatus == .success else {
            throw AccessibilityServiceError.operationFailed(
                code: positionStatus != .success ? positionStatus.rawValue : sizeStatus.rawValue
            )
        }
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copy(Attribute.position, from: element),
            let sizeValue: AXValue = copy(Attribute.size, from: element)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
            AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func copy<T>(_ attribute: String, from element: AXUIElement) -> T? {
        copyResult(attribute, from: element).value
    }

    private func copyResult<T>(_ attribute: String, from element: AXUIElement) -> (value: T?, status: AXError) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return (nil, status) }
        return (value as? T, status)
    }

    private func isSettable(_ attribute: String, element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @MainActor
    private static func screenGeometries() -> [ScreenGeometry] {
        NSScreen.screens.map { screen in
            let number =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
                ?? "screen-\(screen.frame.origin.x)-\(screen.frame.origin.y)"
            return ScreenGeometry(
                identifier: number,
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    @MainActor
    private static func primaryScreenTop() -> CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private static func cocoaFrame(fromAX frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func axFrame(fromCocoa frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }
}
