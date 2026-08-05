import Darwin
import Foundation
import KeyestroDomain

/// Stable lifecycle, isolation, deadline, and capability failures from the extension supervisor.
public enum ExtensionSupervisorError: Error, Equatable, Sendable {
    case disabled
    case incompatibleProtocol
    case incompatibleHost
    case launchFailed(Int32)
    case processGroupUnavailable
    case terminated
    case timedOut(String)
    case circuitOpen
    case protocolViolation
    case remoteError(Int, String)
    case actionNotPublished
    case capabilityDenied
    case invalidArguments

    public var descriptor: ErrorDescriptor {
        switch self {
        case .disabled:
            ErrorDescriptor(code: "extension.disabled", message: "The extension is disabled.")
        case .incompatibleProtocol:
            ErrorDescriptor(code: "extension.incompatibleProtocol", message: "The extension uses an incompatible protocol version.")
        case .incompatibleHost:
            ErrorDescriptor(code: "extension.incompatibleHost", message: "The extension requires a newer version of Keyestro.")
        case let .launchFailed(code):
            ErrorDescriptor(code: "extension.launchFailed.\(code)", message: "The extension process could not be launched.")
        case .processGroupUnavailable:
            ErrorDescriptor(
                code: "extension.processGroupUnavailable", message: "The extension could not be isolated in its own process group.")
        case .terminated:
            ErrorDescriptor(code: "extension.terminated", message: "The extension process ended unexpectedly.")
        case let .timedOut(method):
            ErrorDescriptor(code: "extension.timeout.\(method)", message: "The extension did not respond before the deadline.")
        case .circuitOpen:
            ErrorDescriptor(
                code: "extension.circuitOpen", message: "The extension crashed repeatedly and is disabled for this session.",
                recoverySuggestion: "Retry it manually from Extensions settings.")
        case .protocolViolation:
            ErrorDescriptor(
                code: "extension.protocolViolation",
                message: "The extension sent invalid protocol data.",
                recoverySuggestion: "Disable the extension or retry it from Extensions settings after updating it."
            )
        case let .remoteError(code, _):
            ErrorDescriptor(code: "extension.remote.\(code)", message: "The extension reported an error.")
        case .actionNotPublished:
            ErrorDescriptor(
                code: "extension.actionNotPublished", message: "The extension action is no longer available.",
                recoverySuggestion: "Run the search again.")
        case .capabilityDenied:
            ErrorDescriptor(code: "extension.capabilityDenied", message: "The extension is not authorized for that operation.")
        case .invalidArguments:
            ErrorDescriptor(code: "extension.invalidArguments", message: "The extension action arguments are invalid.")
        }
    }
}

/// Handles the small set of declarative requests an extension may send to the host.
/// Implementations remain responsible for presenting user-visible effects on the correct actor.
public protocol ExtensionHostRequestHandling: Sendable {
    func showHUD(extensionID: String, message: String) async
    func openURL(extensionID: String, url: URL) async -> Bool
    func readPreference(extensionID: String, name: String) async -> JSONValue?
    func log(extensionID: String, level: String, message: String) async
}

/// A host-request handler that exposes no optional capabilities.
public struct DenyingExtensionHostHandler: ExtensionHostRequestHandling {
    public init() {}
    public func showHUD(extensionID: String, message: String) async {}
    public func openURL(extensionID: String, url: URL) async -> Bool { false }
    public func readPreference(extensionID: String, name: String) async -> JSONValue? { nil }
    public func log(extensionID: String, level: String, message: String) async {}
}

private enum ExtensionMailboxMatch: Sendable {
    case response(JSONRPCID)
    case responseOrPublish(responseID: JSONRPCID, requestID: String)

    func matches(_ envelope: JSONRPCEnvelope) -> Bool {
        switch self {
        case let .response(id):
            return envelope.method == nil && envelope.id == id
        case let .responseOrPublish(responseID, requestID):
            if envelope.method == nil, envelope.id == responseID { return true }
            guard envelope.method == "publishItems",
                let object = envelope.params?.objectValue,
                object["requestId"]?.stringValue == requestID
            else { return false }
            return true
        }
    }
}

private actor ExtensionEnvelopeMailbox {
    private struct Waiter {
        let match: ExtensionMailboxMatch
        let continuation: CheckedContinuation<JSONRPCEnvelope, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private var queue: [JSONRPCEnvelope] = []
    private var waiters: [UUID: Waiter] = [:]
    private var terminalError: ExtensionSupervisorError?
    private let maximumQueuedEnvelopes = 256
    private let clock: any ClockServicing

    init(clock: any ClockServicing) {
        self.clock = clock
    }

    func push(_ envelope: JSONRPCEnvelope) {
        guard terminalError == nil else { return }
        if let entry = waiters.first(where: { $0.value.match.matches(envelope) }) {
            let waiter = waiters.removeValue(forKey: entry.key)
            waiter?.timeoutTask.cancel()
            waiter?.continuation.resume(returning: envelope)
            return
        }
        guard queue.count < maximumQueuedEnvelopes else {
            fail(.protocolViolation)
            return
        }
        queue.append(envelope)
    }

    func wait(matching match: ExtensionMailboxMatch, timeout: Duration) async throws -> JSONRPCEnvelope {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        if let index = queue.firstIndex(where: match.matches) {
            return queue.remove(at: index)
        }
        guard timeout > .zero else { throw ExtensionProtocolError.timeout }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    guard let self else { return }
                    try? await clock.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self.expire(token)
                }
                waiters[token] = Waiter(match: match, continuation: continuation, timeoutTask: timeoutTask)
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
    }

    func fail(_ error: ExtensionSupervisorError) {
        guard terminalError == nil else { return }
        terminalError = error
        queue.removeAll(keepingCapacity: false)
        let pending = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    private func expire(_ token: UUID) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume(throwing: ExtensionProtocolError.timeout)
    }

    private func cancel(_ token: UUID) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// The imported file-handle types do not conform to Sendable. This box is safe because all
/// mutation is confined to ExtensionSupervisor; background closures only read immutable handles.
private final class ExtensionProcessBox: @unchecked Sendable {
    let pid: pid_t
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle
    let mailbox: ExtensionEnvelopeMailbox
    var expectedTermination = false
    var nextRequestID: Int64 = 1
    var readerTask: Task<Void, Never>?
    var errorTask: Task<Void, Never>?
    var memoryTask: Task<Void, Never>?
    var overMemorySince: ContinuousClock.Instant?
    var acceptedLogBytes = 0
    var acceptedLogMessages = 0

    init(
        pid: pid_t,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle,
        clock: any ClockServicing
    ) {
        self.pid = pid
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
        mailbox = ExtensionEnvelopeMailbox(clock: clock)
    }

    func closeHandles() {
        standardOutput.readabilityHandler = nil
        standardError.readabilityHandler = nil
        try? standardInput.close()
        try? standardOutput.close()
        try? standardError.close()
    }
}

private enum ExtensionSpawner {
    static func spawn(
        executable: URL,
        root: URL,
        environment: [String: String],
        clock: any ClockServicing
    ) throws -> ExtensionProcessBox {
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw ExtensionSupervisorError.launchFailed(errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let inputRead = input.fileHandleForReading.fileDescriptor
        let inputWrite = input.fileHandleForWriting.fileDescriptor
        let outputRead = output.fileHandleForReading.fileDescriptor
        let outputWrite = output.fileHandleForWriting.fileDescriptor
        let errorRead = error.fileHandleForReading.fileDescriptor
        let errorWrite = error.fileHandleForWriting.fileDescriptor
        let actionStatuses = [
            posix_spawn_file_actions_adddup2(&actions, inputRead, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, inputWrite),
            posix_spawn_file_actions_addclose(&actions, outputRead),
            posix_spawn_file_actions_addclose(&actions, errorRead),
        ]
        guard actionStatuses.allSatisfy({ $0 == 0 }) else {
            throw ExtensionSupervisorError.launchFailed(actionStatuses.first(where: { $0 != 0 }) ?? EINVAL)
        }
        let chdirStatus = root.path.withCString { path in
            if #available(macOS 26.0, *) {
                posix_spawn_file_actions_addchdir(&actions, path)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, path)
            }
        }
        guard chdirStatus == 0 else { throw ExtensionSupervisorError.launchFailed(chdirStatus) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else { throw ExtensionSupervisorError.processGroupUnavailable }

        let arguments = [executable.path]
        let environmentEntries = environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withMutableCStringArray(arguments) { argv in
            withMutableCStringArray(environmentEntries) { envp in
                executable.path.withCString { executablePath in
                    posix_spawn(&pid, executablePath, &actions, &attributes, argv, envp)
                }
            }
        }
        guard status == 0 else { throw ExtensionSupervisorError.launchFailed(status) }

        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        error.fileHandleForWriting.closeFile()
        _ = fcntl(inputWrite, F_SETNOSIGPIPE, 1)
        guard getpgid(pid) == pid else {
            Darwin.kill(pid, SIGKILL)
            throw ExtensionSupervisorError.processGroupUnavailable
        }
        return ExtensionProcessBox(
            pid: pid,
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading,
            clock: clock
        )
    }

    private static func withMutableCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var terminated = pointers + [nil]
        return terminated.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

/// Owns isolated extension process groups, JSON-RPC lifecycles, deadlines, and circuit breakers.
public actor ExtensionSupervisor {
    public static let protocolMajor = 1
    public static let protocolMinor = 0
    public static let maximumResidentBytes: UInt64 = 256 * 1_024 * 1_024

    private let store: any ExtensionStoring
    private let hostHandler: any ExtensionHostRequestHandling
    private let hostVersion: String
    private let initializationTimeout: Duration
    private let searchTimeout: Duration
    private let shutdownTimeout: Duration
    private let cancellationGrace: Duration
    private let terminationGrace: Duration
    private let performance: any PerformanceRecording
    private let clock: any ClockServicing
    private var sessions: [String: ExtensionProcessBox] = [:]
    private var registrations: [String: ExtensionRegistration] = [:]
    private var activeSearches: [String: UUID] = [:]
    private var publishedActions: [String: [String: Set<String>]] = [:]
    private var crashHistory: [String: [Date]] = [:]
    private var openCircuits = Set<String>()

    public init(
        store: any ExtensionStoring,
        hostVersion: String = "0.1.0",
        hostHandler: any ExtensionHostRequestHandling = DenyingExtensionHostHandler(),
        initializationTimeout: Duration = .seconds(2),
        searchTimeout: Duration = .seconds(2),
        shutdownTimeout: Duration = .seconds(2),
        cancellationGrace: Duration = .milliseconds(500),
        terminationGrace: Duration = .milliseconds(500),
        performance: any PerformanceRecording = PerformanceRecorder.shared,
        clock: any ClockServicing = SystemClockService()
    ) {
        self.store = store
        self.hostVersion = hostVersion
        self.hostHandler = hostHandler
        self.initializationTimeout = initializationTimeout
        self.searchTimeout = searchTimeout
        self.shutdownTimeout = shutdownTimeout
        self.cancellationGrace = cancellationGrace
        self.terminationGrace = terminationGrace
        self.performance = performance
        self.clock = clock
    }

    deinit {
        for session in sessions.values {
            Darwin.kill(-session.pid, SIGKILL)
        }
    }

    public func installedExtensions() async throws -> [ExtensionRegistration] {
        try await store.allExtensions()
    }

    public func retry(extensionID: String) {
        openCircuits.remove(extensionID)
        crashHistory[extensionID] = []
    }

    public func isCircuitOpen(extensionID: String) -> Bool {
        openCircuits.contains(extensionID)
    }

    func hasActiveProcess(extensionID: String) -> Bool {
        guard let session = sessions[extensionID] else { return false }
        return isAlive(session.pid)
    }

    public func search(
        registration: ExtensionRegistration,
        request: QueryRequest,
        commandID: String? = nil
    ) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        let task = Task {
            do {
                try await performSearch(
                    registration: registration,
                    request: request,
                    commandID: commandID,
                    continuation: continuation
                )
                continuation.finish()
            } catch is CancellationError {
                await cancelSearch(extensionID: registration.id, requestID: request.id)
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func execute(
        registration: ExtensionRegistration,
        itemStableID: String,
        actionID: String,
        arguments: [String: ArgumentValue]
    ) async -> ActionResult {
        guard publishedActions[registration.id]?[itemStableID]?.contains(actionID) == true else {
            return .failure(ExtensionSupervisorError.actionNotPublished.descriptor)
        }
        do {
            guard arguments.count <= 50,
                arguments.keys.allSatisfy({
                    !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\u{0}")
                })
            else { throw ExtensionSupervisorError.invalidArguments }
            let session = try await session(for: registration)
            var argumentObject: [String: JSONValue] = [:]
            for (name, value) in arguments {
                switch value {
                case let .text(text):
                    guard !text.contains("\u{0}"), text.unicodeScalars.count <= 8_192 else {
                        throw ExtensionSupervisorError.invalidArguments
                    }
                    argumentObject[name] = .string(text)
                case let .file(url):
                    guard registration.manifest.capabilities.contains("filesystem.read") else {
                        throw ExtensionSupervisorError.capabilityDenied
                    }
                    let path = url.standardizedFileURL.path
                    guard url.isFileURL,
                        path.hasPrefix("/"),
                        !path.contains("\u{0}"),
                        path.utf8.count <= 4_096
                    else { throw ExtensionSupervisorError.invalidArguments }
                    argumentObject[name] = .string(path)
                }
            }
            let executionRequestID = UUID().uuidString.lowercased()
            let response = try await withTaskCancellationHandler {
                try await request(
                    session: session,
                    extensionID: registration.id,
                    method: "execute",
                    params: .object([
                        "requestId": .string(executionRequestID),
                        "itemId": .string(itemStableID),
                        "actionId": .string(actionID),
                        "arguments": .object(argumentObject),
                    ]),
                    timeout: .seconds(registration.manifest.executeTimeoutSeconds)
                )
            } onCancel: {
                Task {
                    await self.cancelExecution(
                        extensionID: registration.id,
                        requestID: executionRequestID,
                        sessionPID: session.pid
                    )
                }
            }
            if let remote = response.error {
                throw ExtensionSupervisorError.remoteError(remote.code, remote.message)
            }
            guard let result = response.result?.objectValue,
                let status = result["status"]?.stringValue
            else { throw ExtensionSupervisorError.protocolViolation }
            switch status {
            case "success":
                return .success(message: result["message"]?.stringValue?.limitedToUnicodeScalars(512))
            case "cancelled":
                return .cancelled
            case "failure":
                return .failure(
                    ErrorDescriptor(
                        code: "extension.executeFailed",
                        message: "The extension could not complete the action.",
                        recoverySuggestion: result["recovery"]?.stringValue?.limitedToUnicodeScalars(512)
                    )
                )
            default:
                throw ExtensionSupervisorError.protocolViolation
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as ExtensionSupervisorError {
            return .failure(error.descriptor)
        } catch {
            return .failure(ErrorDescriptor(code: "extension.executeFailed", message: "The extension action failed."))
        }
    }

    public func shutdown(extensionID: String) async {
        guard let session = sessions[extensionID] else { return }
        session.expectedTermination = true
        do {
            _ = try await request(
                session: session,
                extensionID: extensionID,
                method: "shutdown",
                params: .object([:]),
                timeout: shutdownTimeout,
                timeoutTerminationIsExpected: true
            )
            try send(JSONRPCEnvelope(method: "exit", params: .object([:])), to: session)
            try? await clock.sleep(for: .milliseconds(150))
        } catch {}
        if isAlive(session.pid) {
            await terminate(session: session, extensionID: extensionID, expected: true)
        }
    }

    public func shutdownAll() async {
        let ids = Array(sessions.keys)
        for id in ids { await shutdown(extensionID: id) }
    }

    public func disable(extensionID: String) async {
        guard let session = sessions[extensionID] else { return }
        await terminate(session: session, extensionID: extensionID, expected: true)
    }

    /// Notifies an already-running extension. Secret declarations are filtered at this boundary
    /// even if a caller accidentally supplies one.
    public func preferencesChanged(extensionID: String, values: [String: JSONValue]) {
        guard let session = sessions[extensionID], let registration = registrations[extensionID] else { return }
        let nonSecretNames = Set(
            registration.manifest.preferences
                .filter { $0.type != .password }
                .map(\.name)
        )
        let filtered = values.filter { nonSecretNames.contains($0.key) }
        guard !filtered.isEmpty else { return }
        try? send(
            JSONRPCEnvelope(
                method: "preferencesChanged",
                params: .object(["values": .object(filtered)])
            ),
            to: session
        )
    }

    private func performSearch(
        registration: ExtensionRegistration,
        request query: QueryRequest,
        commandID: String?,
        continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
    ) async throws {
        let session = try await session(for: registration)
        if let prior = activeSearches[registration.id], prior != query.id {
            try? send(
                JSONRPCEnvelope(method: "cancel", params: .object(["requestId": .string(prior.uuidString.lowercased())])),
                to: session
            )
        }
        activeSearches[registration.id] = query.id
        defer {
            if activeSearches[registration.id] == query.id { activeSearches[registration.id] = nil }
        }
        let rpcID = nextRequestID(session)
        let requestID = query.id.uuidString.lowercased()
        var params: [String: JSONValue] = [
            "requestId": .string(requestID),
            "query": .string(query.normalizedText),
            "limit": .integer(Int64(min(query.limit, DomainLimits.itemsPerBatch))),
        ]
        if let commandID { params["commandId"] = .string(commandID) }
        if registration.manifest.capabilities.contains("context.frontmostApplication"),
            let bundleID = query.context.frontmostBundleIdentifier
        {
            params["context"] = .object(["frontmostBundleIdentifier": .string(bundleID)])
        }
        try send(JSONRPCEnvelope(id: rpcID, method: "search", params: .object(params)), to: session)

        let deadline = await clock.now() + searchTimeout
        var emittedFinal = false
        while !emittedFinal {
            try Task.checkCancellation()
            let remaining = await clock.now().duration(to: deadline)
            let envelope: JSONRPCEnvelope
            do {
                envelope = try await session.mailbox.wait(
                    matching: .responseOrPublish(responseID: rpcID, requestID: requestID),
                    timeout: remaining
                )
            } catch ExtensionProtocolError.timeout {
                await terminate(session: session, extensionID: registration.id, expected: false)
                throw ExtensionSupervisorError.timedOut("search")
            }
            if let error = envelope.error {
                throw ExtensionSupervisorError.remoteError(error.code, error.message)
            }
            let payloadValue: JSONValue?
            if envelope.method == "publishItems" {
                payloadValue = envelope.params
            } else if let result = envelope.result, result != .null {
                payloadValue = result
            } else {
                payloadValue = nil
            }
            guard let payloadValue else {
                continuation.yield(.items([], isFinal: true))
                emittedFinal = true
                continue
            }
            let validated: ValidatedExtensionItems
            do {
                let payload = try payloadValue.decode(ExtensionPublishItems.self)
                validated = try ExtensionResultValidator.validate(
                    payload,
                    expectedRequestID: query.id,
                    manifest: registration.manifest,
                    extensionRoot: URL(fileURLWithPath: registration.installPath, isDirectory: true),
                    providerID: ExtensionProvider.providerID
                )
            } catch {
                await protocolViolation(extensionID: registration.id, pid: session.pid)
                throw ExtensionSupervisorError.protocolViolation
            }
            var extensionActions = publishedActions[registration.id] ?? [:]
            for item in validated.items {
                let stableID = Self.extensionItemID(from: item.id.providerStableID) ?? item.id.providerStableID
                extensionActions[stableID] = Set(item.actions.map(\.id.rawValue))
            }
            publishedActions[registration.id] = extensionActions
            continuation.yield(.items(validated.items, isFinal: validated.isFinal))
            emittedFinal = validated.isFinal
        }
    }

    private func cancelSearch(extensionID: String, requestID: UUID) async {
        guard let session = sessions[extensionID] else { return }
        if let activeRequestID = activeSearches[extensionID] {
            guard activeRequestID == requestID else { return }
            try? send(
                JSONRPCEnvelope(method: "cancel", params: .object(["requestId": .string(requestID.uuidString.lowercased())])),
                to: session
            )
            activeSearches[extensionID] = nil
        }
        let sessionPID = session.pid
        try? await clock.sleep(for: cancellationGrace)
        guard sessions[extensionID]?.pid == sessionPID, activeSearches[extensionID] == nil else { return }
        await terminate(session: session, extensionID: extensionID, expected: true)
    }

    private func session(for registration: ExtensionRegistration) async throws -> ExtensionProcessBox {
        guard registration.enabled else { throw ExtensionSupervisorError.disabled }
        guard !openCircuits.contains(registration.id) else { throw ExtensionSupervisorError.circuitOpen }
        guard Self.compareSemVer(hostVersion, registration.manifest.minimumHostVersion) >= 0 else {
            throw ExtensionSupervisorError.incompatibleHost
        }
        if let session = sessions[registration.id], isAlive(session.pid) { return session }
        let startedAt = await clock.now()
        let root = URL(fileURLWithPath: registration.installPath, isDirectory: true).standardizedFileURL
        let executable = try registration.manifest.validate(root: root)
        let environment = FoundationProcessService.minimumEnvironment(overrides: [
            "KEYESTRO_EXTENSION_ID": registration.id,
            "KEYESTRO_PROTOCOL_VERSION": "1.0",
        ])
        let spawned = try ExtensionSpawner.spawn(
            executable: executable,
            root: root,
            environment: environment,
            clock: clock
        )
        sessions[registration.id] = spawned
        registrations[registration.id] = registration
        startIO(for: registration.id, session: spawned)
        startExitWait(for: registration.id, session: spawned)
        startMemoryMonitoring(for: registration.id, session: spawned)
        do {
            let response = try await request(
                session: spawned,
                extensionID: registration.id,
                method: "initialize",
                params: .object([
                    "protocolVersion": .object(["major": .integer(1), "minor": .integer(0)]),
                    "hostVersion": .string(hostVersion),
                    "locale": .string(Locale.current.identifier),
                    "theme": .string("system"),
                    "authorizedCapabilities": .array(registration.manifest.capabilities.map(JSONValue.string)),
                ]),
                timeout: initializationTimeout
            )
            if let remote = response.error {
                throw ExtensionSupervisorError.remoteError(remote.code, remote.message)
            }
            guard Self.acceptsProtocol(response.result) else {
                throw ExtensionSupervisorError.incompatibleProtocol
            }
            try send(JSONRPCEnvelope(method: "initialized", params: .object([:])), to: spawned)
            await performance.record(.extensionStart, duration: startedAt.duration(to: await clock.now()))
            PerformanceSignposts.extensionStarted()
            return spawned
        } catch {
            await terminate(session: spawned, extensionID: registration.id, expected: true)
            throw error
        }
    }

    private func request(
        session: ExtensionProcessBox,
        extensionID: String,
        method: String,
        params: JSONValue,
        timeout: Duration,
        timeoutTerminationIsExpected: Bool = false
    ) async throws -> JSONRPCEnvelope {
        let id = nextRequestID(session)
        try send(JSONRPCEnvelope(id: id, method: method, params: params), to: session)
        do {
            return try await session.mailbox.wait(matching: .response(id), timeout: timeout)
        } catch ExtensionProtocolError.timeout {
            await terminate(
                session: session,
                extensionID: extensionID,
                expected: timeoutTerminationIsExpected
            )
            throw ExtensionSupervisorError.timedOut(method)
        }
    }

    private func cancelExecution(extensionID: String, requestID: String, sessionPID: pid_t) async {
        guard let session = sessions[extensionID], session.pid == sessionPID else { return }
        try? send(
            JSONRPCEnvelope(method: "cancel", params: .object(["requestId": .string(requestID)])),
            to: session
        )
        try? await clock.sleep(for: cancellationGrace)
        guard sessions[extensionID]?.pid == sessionPID else { return }
        await terminate(session: session, extensionID: extensionID, expected: true)
    }

    private func nextRequestID(_ session: ExtensionProcessBox) -> JSONRPCID {
        let value = session.nextRequestID
        session.nextRequestID &+= 1
        return .integer(value)
    }

    private func send(_ envelope: JSONRPCEnvelope, to session: ExtensionProcessBox) throws {
        guard isAlive(session.pid) else { throw ExtensionSupervisorError.terminated }
        do {
            try session.standardInput.write(contentsOf: JSONRPCFramer.frame(envelope))
        } catch {
            throw ExtensionSupervisorError.terminated
        }
    }

    private func startIO(for extensionID: String, session: ExtensionProcessBox) {
        let (bytes, byteContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        session.standardOutput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                byteContinuation.finish()
            } else {
                byteContinuation.yield(data)
            }
        }
        session.readerTask = Task { [weak self] in
            var framer = JSONRPCFramer()
            var consecutiveInvalidPayloads = 0
            do {
                for await chunk in bytes {
                    let frames = try framer.append(chunk)
                    for frame in frames {
                        do {
                            let envelope = try JSONRPCFramer.decode(frame)
                            consecutiveInvalidPayloads = 0
                            await self?.receive(envelope, extensionID: extensionID, pid: session.pid)
                        } catch ExtensionProtocolError.invalidJSON, ExtensionProtocolError.invalidUTF8 {
                            consecutiveInvalidPayloads += 1
                            if consecutiveInvalidPayloads >= 3 {
                                throw ExtensionSupervisorError.protocolViolation
                            }
                        }
                    }
                }
            } catch {
                await self?.protocolViolation(extensionID: extensionID, pid: session.pid)
            }
        }

        let (errors, errorContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(32))
        session.standardError.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errorContinuation.finish()
            } else {
                errorContinuation.yield(data)
            }
        }
        session.errorTask = Task { [weak self] in
            for await chunk in errors {
                let message = String(decoding: chunk, as: UTF8.self)
                    .replacingOccurrences(of: "\u{0}", with: "")
                    .limitedToUnicodeScalars(2_048)
                await self?.acceptLog(
                    extensionID: extensionID,
                    pid: session.pid,
                    level: "stderr",
                    message: message,
                    sourceByteCount: chunk.count
                )
            }
        }
    }

    private func startExitWait(for extensionID: String, session: ExtensionProcessBox) {
        let pid = session.pid
        Task.detached { [weak self] in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            await self?.processExited(extensionID: extensionID, pid: pid, status: status)
        }
    }

    private func startMemoryMonitoring(for extensionID: String, session: ExtensionProcessBox) {
        let pid = session.pid
        session.memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await clock.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await sampleMemory(extensionID: extensionID, pid: pid)
            }
        }
    }

    private func receive(_ envelope: JSONRPCEnvelope, extensionID: String, pid: pid_t) async {
        guard let session = sessions[extensionID], session.pid == pid else { return }
        guard let method = envelope.method else {
            await session.mailbox.push(envelope)
            return
        }
        let object = envelope.params?.objectValue ?? [:]
        switch method {
        case "log", "host/log":
            let level = object["level"]?.stringValue?.limitedToUnicodeScalars(32) ?? "info"
            let message = object["message"]?.stringValue?.limitedToUnicodeScalars(2_048) ?? ""
            await acceptLog(
                extensionID: extensionID,
                pid: pid,
                level: level,
                message: message,
                sourceByteCount: message.utf8.count
            )
        case "showHUD":
            guard let message = object["message"]?.stringValue, !message.isEmpty else {
                await respondInvalidParams(to: envelope, session: session)
                return
            }
            await hostHandler.showHUD(extensionID: extensionID, message: message.limitedToUnicodeScalars(512))
            await respond(result: .object(["shown": .bool(true)]), to: envelope, session: session)
        case "openURL":
            guard registrationAllows(extensionID, capability: "url.open"),
                let rawURL = object["url"]?.stringValue,
                rawURL.utf8.count <= 16_384,
                !rawURL.contains("\u{0}"),
                let url = URL(string: rawURL),
                let scheme = url.scheme?.lowercased(),
                ["https", "http", "mailto"].contains(scheme),
                url.user == nil,
                url.password == nil,
                (!["https", "http"].contains(scheme) || url.host?.isEmpty == false)
            else {
                await respond(error: JSONRPCErrorObject(code: -32001, message: "Capability denied"), to: envelope, session: session)
                return
            }
            let opened = await hostHandler.openURL(extensionID: extensionID, url: url)
            await respond(result: .object(["opened": .bool(opened)]), to: envelope, session: session)
        case "readPreference":
            guard let name = object["name"]?.stringValue,
                registrations[extensionID]?.manifest.preferences.contains(where: { $0.name == name }) == true
            else {
                await respondInvalidParams(to: envelope, session: session)
                return
            }
            let value = await hostHandler.readPreference(extensionID: extensionID, name: name) ?? .null
            await respond(result: value, to: envelope, session: session)
        case "publishItems":
            await session.mailbox.push(envelope)
        default:
            if envelope.id != nil {
                await respond(error: JSONRPCErrorObject(code: -32601, message: "Method not found"), to: envelope, session: session)
            }
        }
    }

    private func respond(result: JSONValue, to request: JSONRPCEnvelope, session: ExtensionProcessBox) async {
        guard let id = request.id else { return }
        try? send(JSONRPCEnvelope(id: id, result: result), to: session)
    }

    private func respond(error: JSONRPCErrorObject, to request: JSONRPCEnvelope, session: ExtensionProcessBox) async {
        guard let id = request.id else { return }
        try? send(JSONRPCEnvelope(id: id, error: error), to: session)
    }

    private func respondInvalidParams(to request: JSONRPCEnvelope, session: ExtensionProcessBox) async {
        await respond(error: JSONRPCErrorObject(code: -32602, message: "Invalid params"), to: request, session: session)
    }

    private func registrationAllows(_ extensionID: String, capability: String) -> Bool {
        registrations[extensionID]?.manifest.capabilities.contains(capability) == true
    }

    private func acceptLog(
        extensionID: String,
        pid: pid_t,
        level: String,
        message: String,
        sourceByteCount: Int
    ) async {
        guard let session = sessions[extensionID], session.pid == pid else { return }
        session.acceptedLogMessages += 1
        session.acceptedLogBytes += max(0, sourceByteCount)
        guard session.acceptedLogMessages <= 256,
            session.acceptedLogBytes <= 64 * 1_024
        else {
            await protocolViolation(extensionID: extensionID, pid: pid)
            return
        }
        await hostHandler.log(extensionID: extensionID, level: level, message: message)
    }

    private func protocolViolation(extensionID: String, pid: pid_t) async {
        guard let session = sessions[extensionID], session.pid == pid else { return }
        await session.mailbox.fail(.protocolViolation)
        await terminate(session: session, extensionID: extensionID, expected: false)
    }

    private func processExited(extensionID: String, pid: pid_t, status: Int32) async {
        guard let session = sessions[extensionID], session.pid == pid else { return }
        sessions[extensionID] = nil
        activeSearches[extensionID] = nil
        session.readerTask?.cancel()
        session.errorTask?.cancel()
        session.memoryTask?.cancel()
        session.closeHandles()
        await session.mailbox.fail(.terminated)
        if !session.expectedTermination {
            recordCrash(extensionID: extensionID, at: await clock.wallTime())
        }
        _ = status
    }

    private func sampleMemory(extensionID: String, pid: pid_t) async {
        guard let session = sessions[extensionID], session.pid == pid else { return }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return }
        if info.pti_resident_size > Self.maximumResidentBytes {
            let now = await clock.now()
            if let since = session.overMemorySince {
                if since.duration(to: now) >= .seconds(5) {
                    await terminate(session: session, extensionID: extensionID, expected: false)
                }
            } else {
                session.overMemorySince = now
            }
        } else {
            session.overMemorySince = nil
        }
    }

    private func terminate(session: ExtensionProcessBox, extensionID: String, expected: Bool) async {
        guard sessions[extensionID]?.pid == session.pid else { return }
        session.expectedTermination = expected
        Darwin.kill(-session.pid, SIGTERM)
        try? await clock.sleep(for: terminationGrace)
        if isAlive(session.pid) { Darwin.kill(-session.pid, SIGKILL) }
    }

    private func recordCrash(extensionID: String, at date: Date) {
        let cutoff = date.addingTimeInterval(-60)
        var events = (crashHistory[extensionID] ?? []).filter { $0 >= cutoff }
        events.append(date)
        crashHistory[extensionID] = events
        if events.count >= 3 { openCircuits.insert(extensionID) }
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private static func acceptsProtocol(_ result: JSONValue?) -> Bool {
        guard let object = result?.objectValue else { return false }
        if let version = object["protocolVersion"]?.objectValue,
            version["major"]?.integerValue == Int64(protocolMajor)
        {
            return true
        }
        if object["protocolVersion"]?.integerValue == Int64(protocolMajor) { return true }
        if let string = object["protocolVersion"]?.stringValue,
            string.split(separator: ".").first == Substring(String(protocolMajor))
        {
            return true
        }
        return false
    }

    private static func compareSemVer(_ lhs: String, _ rhs: String) -> Int {
        func core(_ value: String) -> [Int] {
            value.split(separator: "-", maxSplits: 1)[0].split(separator: ".").map { Int($0) ?? 0 }
        }
        let left = core(lhs)
        let right = core(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    static func extensionItemID(from providerStableID: String) -> String? {
        let parts = providerStableID.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return String(parts[1])
    }
}
