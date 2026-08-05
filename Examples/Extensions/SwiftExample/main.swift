import Foundation

final class MessageReader {
    private let handle = FileHandle.standardInput
    private let delimiter = Data("\r\n\r\n".utf8)
    private var buffer = Data()

    func readMessage() throws -> [String: Any]? {
        while buffer.range(of: delimiter) == nil {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
        guard let headerRange = buffer.range(of: delimiter),
            let header = String(data: buffer.prefix(headerRange.lowerBound), encoding: .ascii)
        else { return nil }
        let contentLength = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first
        guard let contentLength else { return nil }
        let bodyStart = headerRange.upperBound
        while buffer.count < bodyStart + contentLength {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        buffer.removeSubrange(0..<(bodyStart + contentLength))
        return try JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

func send(_ message: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: message, options: [])
    try FileHandle.standardOutput.write(contentsOf: Data("Content-Length: \(data.count)\r\n\r\n".utf8))
    try FileHandle.standardOutput.write(contentsOf: data)
}

func respond(_ request: [String: Any], result: Any = NSNull()) throws {
    guard let id = request["id"] else { return }
    try send(["jsonrpc": "2.0", "id": id, "result": result])
}

let reader = MessageReader()
while let request = try reader.readMessage() {
    let method = request["method"] as? String
    let params = request["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        try respond(request, result: ["protocolVersion": ["major": 1, "minor": 0]])
    case "initialized", "cancel":
        continue
    case "search":
        let query = params["query"] as? String ?? ""
        let item: [String: Any] = [
            "id": "symbol:\(query.isEmpty ? "command" : query)",
            "title": query.isEmpty ? "Swift.Command" : "Swift.\(query)",
            "subtitle": "Returned by the bundled Swift contract example",
            "icon": ["type": "symbol", "name": "swift"],
            "keywords": ["swift", "example"],
            "actions": [[
                "id": "select",
                "title": "Select Symbol",
                "risk": "safe",
                "behavior": "keepLauncherOpen",
            ]],
            "defaultActionId": "select",
        ]
        try send([
            "jsonrpc": "2.0",
            "method": "publishItems",
            "params": ["requestId": params["requestId"] as Any, "items": [item], "isFinal": true],
        ])
        try respond(request)
    case "execute":
        try respond(request, result: ["status": "success", "message": "Swift example action completed"])
    case "shutdown":
        try respond(request)
    case "exit":
        exit(0)
    default:
        if let id = request["id"] {
            try send([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "Method not found"],
            ])
        }
    }
}
