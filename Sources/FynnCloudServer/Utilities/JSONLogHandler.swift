import Logging
import Vapor

struct JSONLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]
    let label: String

    private static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata callMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = Date().formatted(Self.timestampFormat)
        var fields = [
            "\"timestamp\":\"\(timestamp)\"",
            "\"level\":\"\(level.rawValue)\"",
            "\"label\":\(Self.jsonString(label))",
            "\"message\":\(Self.jsonString(message.description))",
        ]

        let mergedMetadata = self.metadata.merging(callMetadata ?? [:]) { _, new in new }
        if !mergedMetadata.isEmpty {
            let body = mergedMetadata.keys.sorted()
                .map { "\(Self.jsonString($0)):\(Self.jsonFragment(for: mergedMetadata[$0]!))" }
                .joined(separator: ",")
            fields.append("\"metadata\":{\(body)}")
        }

        // Access log lines (subsystem "http") always come from the same call site
        // (RequestLoggingMiddleware.respond), so file/function/line are always identical and add nothing.
        // This filters them out to reduce log noise.
        if case .string("http") = mergedMetadata["subsystem"] {
            print("{\(fields.joined(separator: ","))}")
            return
        }

        fields.append(contentsOf: [
            "\"file\":\(Self.jsonString(file))",
            "\"function\":\(Self.jsonString(function))",
            "\"line\":\(line)",
        ])

        print("{\(fields.joined(separator: ","))}")
    }

    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for char in value {
            switch char {
            case "\"": result.append("\\\"")
            case "\\": result.append("\\\\")
            case "\n": result.append("\\n")
            case "\r": result.append("\\r")
            case "\t": result.append("\\t")
            case "\u{08}": result.append("\\b")
            case "\u{0C}": result.append("\\f")
            default:
                if let ascii = char.asciiValue, ascii < 0x20 {
                    result.append(String(format: "\\u%04x", ascii))
                } else {
                    result.append(char)
                }
            }
        }
        result.append("\"")
        return result
    }

    private static func jsonFragment(for value: Logger.MetadataValue) -> String {
        switch value {
        case .string(let string):
            return jsonString(string)
        case .stringConvertible(let convertible):
            if let boolVal = convertible as? Bool {
                return boolVal ? "true" : "false"
            } else if let intVal = convertible as? any FixedWidthInteger {
                return "\(intVal)"
            } else if let doubleVal = convertible as? any BinaryFloatingPoint {
                return doubleVal.isFinite ? "\(doubleVal)" : "null"
            }
            return jsonString("\(convertible)")
        case .array(let array):
            return "[" + array.map { jsonFragment(for: $0) }.joined(separator: ",") + "]"
        case .dictionary(let dictionary):
            let body = dictionary.keys.sorted()
                .map { "\(jsonString($0)):\(jsonFragment(for: dictionary[$0]!))" }
                .joined(separator: ",")
            return "{\(body)}"
        }
    }
}
