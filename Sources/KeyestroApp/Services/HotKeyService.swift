import Carbon
import AppKit
import Foundation

struct HotKeyShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let optionSpace = Self(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    static let optionShiftV = Self(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | shiftKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allowedCarbonModifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        let required = UInt32(controlKey | optionKey | cmdKey)
        guard carbonModifiers & required != 0,
            event.keyCode != UInt16(kVK_Escape),
            event.keyCode != UInt16(kVK_Tab)
        else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
    }

    var isValid: Bool {
        let required = UInt32(controlKey | optionKey | cmdKey)
        return modifiers & required != 0 && modifiers & ~Self.allowedCarbonModifiers == 0
    }

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyNames[keyCode] ?? "Key \(keyCode)"
        return result
    }

    private static let allowedCarbonModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return", UInt32(kVK_Delete): "Delete",
        UInt32(kVK_ForwardDelete): "Forward Delete", UInt32(kVK_Home): "Home", UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up", UInt32(kVK_PageDown): "Page Down", UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}

enum HotKeyAction: UInt32, CaseIterable, Hashable, Sendable {
    case launcher = 1
    case clipboardHistory = 2
    case quickPaste = 3
}

enum HotKeyRegistrationState: Equatable, Sendable {
    case registered
    case unavailable(status: OSStatus)
}

struct HotKeyStatusPresentation: Equatable, Sendable {
    let menuTitle: String
    let errorMessage: String?

    init(action: HotKeyAction = .launcher, state: HotKeyRegistrationState, shortcut: HotKeyShortcut) {
        let statusKey =
            switch action {
            case .launcher: "launcher.shortcut.status"
            case .clipboardHistory: "clipboard.shortcut.status"
            case .quickPaste: "quickPaste.shortcut.status"
            }
        let unavailableKey =
            switch action {
            case .launcher: "launcher.shortcut.unavailable"
            case .clipboardHistory: "clipboard.shortcut.unavailable"
            case .quickPaste: "quickPaste.shortcut.unavailable"
            }
        switch state {
        case .registered:
            menuTitle = L10n.format(statusKey, shortcut.displayName)
            errorMessage = nil
        case let .unavailable(status):
            let message = L10n.format(unavailableKey, status)
            menuTitle = message
            errorMessage = message
        }
    }
}

@MainActor
protocol HotKeyRegistrationBackend: AnyObject {
    var onInvocation: ((HotKeyAction) -> Void)? { get set }
    func register(_ shortcut: HotKeyShortcut, for action: HotKeyAction) -> OSStatus
    func suspend()
    func stop()
}

private func keyestroHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, let action = HotKeyAction(rawValue: identifier.id) else {
        return OSStatus(eventNotHandledErr)
    }
    let address = Int(bitPattern: userData)
    return MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else {
            return OSStatus(eventNotHandledErr)
        }
        let backend = Unmanaged<CarbonHotKeyRegistrationBackend>.fromOpaque(pointer).takeUnretainedValue()
        backend.handleInvocation(action)
        return noErr
    }
}

@MainActor
private final class CarbonHotKeyRegistrationBackend: HotKeyRegistrationBackend {
    var onInvocation: ((HotKeyAction) -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [HotKeyAction: EventHotKeyRef] = [:]

    func register(_ shortcut: HotKeyShortcut, for action: HotKeyAction) -> OSStatus {
        unregister(action)

        if eventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let handlerStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                keyestroHotKeyCallback,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
            guard handlerStatus == noErr else {
                return handlerStatus
            }
        }

        let identifier = EventHotKeyID(signature: OSType(0x4B_45_59_53), id: action.rawValue)  // KEYS
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if status == noErr, let hotKey {
            hotKeys[action] = hotKey
        }
        return status
    }

    func stop() {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    func suspend() {
        unregisterAll()
    }

    fileprivate func handleInvocation(_ action: HotKeyAction) {
        guard hotKeys[action] != nil else { return }
        onInvocation?(action)
    }

    private func unregister(_ action: HotKeyAction) {
        if let hotKey = hotKeys.removeValue(forKey: action) {
            UnregisterEventHotKey(hotKey)
        }
    }

    private func unregisterAll() {
        for action in HotKeyAction.allCases { unregister(action) }
    }
}

@MainActor
final class HotKeyService {
    var onInvocation: ((HotKeyAction) -> Void)?
    var onStateChange: ((HotKeyAction, HotKeyRegistrationState) -> Void)?

    private let backend: any HotKeyRegistrationBackend

    init(backend: any HotKeyRegistrationBackend = CarbonHotKeyRegistrationBackend()) {
        self.backend = backend
        backend.onInvocation = { [weak self] action in self?.onInvocation?(action) }
    }

    func register(_ shortcut: HotKeyShortcut, for action: HotKeyAction) {
        let status = backend.register(shortcut, for: action)
        onStateChange?(action, status == noErr ? .registered : .unavailable(status: status))
    }

    func stop() {
        backend.stop()
    }

    func suspend() {
        backend.suspend()
    }
}
