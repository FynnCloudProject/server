import Foundation
import Vapor

extension JSONDecoder.DateDecodingStrategy {
    /// Custom ISO8601 date decoding strategy supporting ISO8601 strings with fractional seconds
    /// (e.g. "2026-08-08T11:01:04.820Z"), standard ISO8601 strings ("2026-08-08T11:01:04Z"),
    /// and unix timestamp numbers (seconds/milliseconds).
    public static let customISO8601 = custom { decoder in
        let container = try decoder.singleValueContainer()

        if let dateString = try? container.decode(String.self) {
            let isoWithFractional = ISO8601DateFormatter()
            isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoWithFractional.date(from: dateString) {
                return date
            }

            let isoStandard = ISO8601DateFormatter()
            isoStandard.formatOptions = [.withInternetDateTime]
            if let date = isoStandard.date(from: dateString) {
                return date
            }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)

            let formats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ",
                "yyyy-MM-dd'T'HH:mm:ssZ"
            ]
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: dateString) {
                    return date
                }
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date format string: \(dateString)"
            )
        }

        if let doubleValue = try? container.decode(Double.self) {
            if doubleValue > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: doubleValue / 1000.0)
            }
            return Date(timeIntervalSince1970: doubleValue)
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected Date represented as ISO8601 string or Double timestamp"
        )
    }
}

extension JSONEncoder.DateEncodingStrategy {
    public static let customISO8601 = custom { date, encoder in
        var container = encoder.singleValueContainer()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: date))
    }
}
