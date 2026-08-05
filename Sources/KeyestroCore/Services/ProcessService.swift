import Darwin
import Foundation
import KeyestroDomain

public struct ProcessExecutionRequest: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL?
    public let timeout: Duration
    public let maximumOutputBytes: Int

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL? = nil,
        timeout: Duration = .seconds(30),
        maximumOutputBytes: Int = 1_024 * 1_024
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = Swift.min(Swift.max(timeout, .milliseconds(1)), .seconds(300))
        self.maximumOutputBytes = Swift.min(Swift.max(0, maximumOutputBytes), 1_024 * 1_024)
    }
}

public enum ProcessTermination: Equatable, Sendable {
    case exited(Int32)
    case signalled(Int32)
    case timedOut
}

public struct ProcessExecutionResult: Equatable, Sendable {
    public let termination: ProcessTermination
    public let standardOutput: Data
    public let standardError: Data
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool
    public let duration: Duration

    public init(
        termination: ProcessTermination,
        standardOutput: Data,
        standardError: Data,
        standardOutputTruncated: Bool,
        standardErrorTruncated: Bool,
        duration: Duration
    ) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
        self.duration = duration
    }
}

public protocol ProcessServicing: Sendable {
    func run(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult
}

public enum ProcessServiceError: Error, Equatable, Sendable {
    case invalidExecutable
    case invalidRequest
    case launchFailed

    public var descriptor: ErrorDescriptor {
        switch self {
        case .invalidExecutable:
            ErrorDescriptor(code: "process.invalidExecutable", message: "The executable is missing or is not executable.")
        case .invalidRequest:
            ErrorDescriptor(code: "process.invalidRequest", message: "The process request contains an invalid argument.")
        case .launchFailed:
            ErrorDescriptor(code: "process.launchFailed", message: "The process could not be launched.")
        }
    }
}

private final class BoundedOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let available = max(0, limit - data.count)
        if available > 0 { data.append(chunk.prefix(available)) }
        if chunk.count > available { truncated = true }
    }

    func snapshot() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, truncated)
    }
}

private struct SpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    let standardOutput: FileHandle
    let standardError: FileHandle
}

private struct ChildWaitResult: Sendable {
    let pid: pid_t
    let status: Int32
}

/// Executes a trusted local executable without invoking a shell.
///
/// The child starts as the leader of a new process group, so cancellation and timeout always
/// terminate the complete descendant tree. Standard output and standard error are drained
/// concurrently and independently bounded to one MiB.
public actor FoundationProcessService: ProcessServicing {
    private let clock: any ClockServicing
    private let fileSystem: any FileSystemServicing

    public init(
        clock: any ClockServicing = SystemClockService(),
        fileSystem: any FileSystemServicing = LocalFileSystemService()
    ) {
        self.clock = clock
        self.fileSystem = fileSystem
    }

    public func run(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        guard Self.validRequest(request) else { throw ProcessServiceError.invalidRequest }
        let executableMetadata = try await fileSystem.metadata(at: request.executableURL)
        guard request.executableURL.isFileURL,
            executableMetadata?.isRegularFile == true,
            executableMetadata?.isSymbolicLink != true,
            executableMetadata?.isExecutable == true
        else { throw ProcessServiceError.invalidExecutable }

        if let workingDirectory = request.workingDirectoryURL {
            let workingDirectoryMetadata = try await fileSystem.metadata(at: workingDirectory)
            guard workingDirectory.isFileURL,
                workingDirectoryMetadata?.isDirectory == true,
                workingDirectoryMetadata?.isSymbolicLink != true
            else { throw ProcessServiceError.launchFailed }
        }

        let spawned = try Self.spawn(request)
        let outputLimit = request.maximumOutputBytes
        let outputCollector = BoundedOutputCollector(limit: outputLimit)
        let errorCollector = BoundedOutputCollector(limit: outputLimit)
        spawned.standardOutput.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outputCollector.append(chunk) }
        }
        spawned.standardError.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errorCollector.append(chunk) }
        }

        let clock = self.clock
        let startedAt = await clock.now()
        let waitTask = Task.detached(priority: .utility) {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(spawned.pid, &status, 0) } while result == -1 && errno == EINTR
            return ChildWaitResult(pid: result, status: status)
        }

        enum Race: Sendable { case exited, timeout, cancelled }
        let race = await withTaskCancellationHandler {
            await withTaskGroup(of: Race.self) { group in
                group.addTask {
                    _ = await waitTask.value
                    return .exited
                }
                group.addTask {
                    do {
                        try await clock.sleep(for: request.timeout)
                        return .timeout
                    } catch {
                        return .cancelled
                    }
                }
                let first = await group.next() ?? .cancelled
                if first != .exited {
                    Self.sendToProcessGroup(spawned.pid, signal: SIGTERM)
                    let graceDeadline = await clock.now() + .seconds(2)
                    while Self.processGroupExists(spawned.pid) {
                        guard await clock.now() < graceDeadline else { break }
                        try? await clock.sleep(for: .milliseconds(50))
                    }
                    if Self.processGroupExists(spawned.pid) {
                        Self.sendToProcessGroup(spawned.pid, signal: SIGKILL)
                    }
                    _ = await waitTask.value
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            Self.sendToProcessGroup(spawned.pid, signal: SIGTERM)
        }

        // Background descendants are not allowed to outlive their script leader.
        if Self.processGroupExists(spawned.pid) {
            Self.sendToProcessGroup(spawned.pid, signal: SIGTERM)
            try? await clock.sleep(for: .milliseconds(100))
            if Self.processGroupExists(spawned.pid) {
                Self.sendToProcessGroup(spawned.pid, signal: SIGKILL)
                try? await clock.sleep(for: .milliseconds(20))
            }
        }
        let waitResult = await waitTask.value

        spawned.standardOutput.readabilityHandler = nil
        spawned.standardError.readabilityHandler = nil
        outputCollector.append(spawned.standardOutput.readDataToEndOfFile())
        errorCollector.append(spawned.standardError.readDataToEndOfFile())
        try? spawned.standardOutput.close()
        try? spawned.standardError.close()
        let (output, outputTruncated) = outputCollector.snapshot()
        let (errorOutput, errorTruncated) = errorCollector.snapshot()

        if race == .cancelled || Task.isCancelled { throw CancellationError() }
        let termination: ProcessTermination
        if race == .timeout {
            termination = .timedOut
        } else if waitResult.pid < 0 {
            termination = .signalled(SIGKILL)
        } else {
            let signal = waitResult.status & 0x7f
            termination =
                signal == 0
                ? .exited((waitResult.status >> 8) & 0xff)
                : .signalled(signal)
        }
        return ProcessExecutionResult(
            termination: termination,
            standardOutput: output,
            standardError: errorOutput,
            standardOutputTruncated: outputTruncated,
            standardErrorTruncated: errorTruncated,
            duration: startedAt.duration(to: await clock.now())
        )
    }

    public static func minimumEnvironment(overrides: [String: String]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(),
            "KEYESTRO_PROTOCOL_VERSION": "1",
        ]
        for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = inherited[key] { environment[key] = value }
        }
        let allowedOverrides: Set<String> = [
            "LANG", "LC_ALL", "LC_CTYPE", "KEYESTRO_INVOCATION_ID", "KEYESTRO_FRONTMOST_BUNDLE_ID",
        ]
        for (key, value) in overrides where allowedOverrides.contains(key) && Self.validEnvironmentName(key) {
            if Self.validCString(value, maximumUTF8Bytes: 8_192) { environment[key] = value }
        }
        return environment
    }

    private static func validRequest(_ request: ProcessExecutionRequest) -> Bool {
        guard request.executableURL.isFileURL,
            request.executableURL.path.hasPrefix("/"),
            validCString(request.executableURL.path, maximumUTF8Bytes: 4_096),
            request.arguments.count <= 256,
            request.environment.count <= 64,
            request.arguments.allSatisfy({ validCString($0, maximumUTF8Bytes: 64 * 1_024) }),
            request.environment.allSatisfy({ key, value in
                validEnvironmentName(key) && validCString(value, maximumUTF8Bytes: 8_192)
            })
        else { return false }
        let argumentBytes = request.arguments.reduce(into: 0) { total, value in
            total = Swift.min(1_024 * 1_024 + 1, total + value.utf8.count + 1)
        }
        guard argumentBytes <= 1_024 * 1_024 else { return false }
        if let workingDirectory = request.workingDirectoryURL {
            guard workingDirectory.isFileURL,
                workingDirectory.path.hasPrefix("/"),
                validCString(workingDirectory.path, maximumUTF8Bytes: 4_096)
            else { return false }
        }
        return true
    }

    private static func validCString(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        !value.contains("\u{0}") && value.utf8.count <= maximumUTF8Bytes
    }

    private static func spawn(_ request: ProcessExecutionRequest) throws -> SpawnedProcess {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw ProcessServiceError.launchFailed
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let outputRead = outputPipe.fileHandleForReading.fileDescriptor
        let outputWrite = outputPipe.fileHandleForWriting.fileDescriptor
        let errorRead = errorPipe.fileHandleForReading.fileDescriptor
        let errorWrite = errorPipe.fileHandleForWriting.fileDescriptor
        let nullStatus = "/dev/null".withCString { path in
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDONLY, 0)
        }
        let actionStatuses = [
            nullStatus,
            posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, outputRead),
            posix_spawn_file_actions_addclose(&actions, errorRead),
            posix_spawn_file_actions_addclose(&actions, outputWrite),
            posix_spawn_file_actions_addclose(&actions, errorWrite),
        ]
        guard actionStatuses.allSatisfy({ $0 == 0 }) else { throw ProcessServiceError.launchFailed }

        if let workingDirectory = request.workingDirectoryURL {
            let chdirStatus = workingDirectory.path.withCString { path in
                if #available(macOS 26.0, *) {
                    posix_spawn_file_actions_addchdir(&actions, path)
                } else {
                    posix_spawn_file_actions_addchdir_np(&actions, path)
                }
            }
            guard chdirStatus == 0 else { throw ProcessServiceError.launchFailed }
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else { throw ProcessServiceError.launchFailed }

        let argumentEntries = [request.executableURL.path] + request.arguments
        let environmentEntries = minimumEnvironment(overrides: request.environment)
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = try withMutableCStringArray(argumentEntries) { argv in
            try withMutableCStringArray(environmentEntries) { envp in
                request.executableURL.path.withCString { path in
                    posix_spawn(&pid, path, &actions, &attributes, argv, envp)
                }
            }
        }
        guard status == 0, getpgid(pid) == pid else {
            if status == 0 { Darwin.kill(pid, SIGKILL) }
            throw ProcessServiceError.launchFailed
        }

        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
        return SpawnedProcess(
            pid: pid,
            standardOutput: outputPipe.fileHandleForReading,
            standardError: errorPipe.fileHandleForReading
        )
    }

    private static func withMutableCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> R
    ) throws -> R {
        let pointers = strings.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw ProcessServiceError.launchFailed
        }
        defer { pointers.forEach { free($0) } }
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: pointers.count + 1)
        defer { buffer.deallocate() }
        for (index, pointer) in pointers.enumerated() { buffer[index] = pointer }
        buffer[pointers.count] = nil
        return try body(buffer)
    }

    private static func validEnvironmentName(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter, value.count <= 128 else { return false }
        return value.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func sendToProcessGroup(_ pid: pid_t, signal: Int32) {
        _ = Darwin.kill(-pid, signal)
    }

    private static func processGroupExists(_ pid: pid_t) -> Bool {
        Darwin.kill(-pid, 0) == 0 || errno == EPERM
    }
}
