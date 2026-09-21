import Foundation

@main
enum WorkflowMCPFakeBackend {
    static func main() {
        while let line = readLine() {
            guard let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = payload["method"] as? String
            else {
                writeRaw("not-json")
                continue
            }

            let id = payload["id"]
            switch method {
            case "initialize":
                if ProcessInfo.processInfo.environment["WORKFLOW_MCP_FAKE_UNPERMITTED_FAILURE"] == "1" {
                    writeRaw("not-json")
                    continue
                }
                if ProcessInfo.processInfo.environment["WORKFLOW_MCP_FAKE_SLOW_START"] == "1" {
                    Thread.sleep(forTimeInterval: 1)
                }
                respond(id: id, result: ["protocolVersion": "2025-03-26", "capabilities": [:]])
            case "notifications/initialized":
                continue
            case "tools/list":
                respond(id: id, result: [
                    "tools": [
                        ["name": "echo"],
                        ["name": "backend_error"],
                        ["name": "malformed"],
                        ["name": "oversized"],
                        ["name": "hang"],
                    ],
                ])
            case "tools/call":
                let parameters = payload["params"] as? [String: Any] ?? [:]
                let name = parameters["name"] as? String ?? ""
                handleTool(name: name, id: id, arguments: parameters["arguments"] ?? [:])
            default:
                respondError(id: id, code: -32601, message: "unknown method \(method)", data: nil)
            }
        }
    }

    private static func handleTool(name: String, id: Any?, arguments: Any) {
        switch name {
        case "echo":
            FileHandle.standardError.write(Data("fake-backend diagnostic\\n".utf8))
            respond(id: id, result: ["content": [["type": "text", "text": "echo"]], "arguments": arguments])
        case "backend_error":
            respondError(id: id, code: 424, message: "backend refused", data: ["reason": "fixture"])
        case "malformed":
            writeRaw("not-json")
        case "oversized":
            respond(id: id, result: ["payload": String(repeating: "x", count: 4096)])
        case "hang":
            Thread.sleep(forTimeInterval: 5)
            respond(id: id, result: [:])
        default:
            respondError(id: id, code: -32601, message: "unknown tool \(name)", data: nil)
        }
    }

    private static func respond(id: Any?, result: [String: Any]) {
        write([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ])
    }

    private static func respondError(id: Any?, code: Int, message: String, data: [String: Any]?) {
        var error: [String: Any] = [
            "code": code,
            "message": message,
        ]
        if let data {
            error["data"] = data
        }
        write([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": error,
        ])
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        writeRaw(text)
    }

    private static func writeRaw(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
