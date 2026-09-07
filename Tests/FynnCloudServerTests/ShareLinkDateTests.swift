import XCTest
import Vapor
@testable import FynnCloudServer

final class ShareLinkDateTests: XCTestCase {
    func testISO8601DateDecoding() throws {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .customISO8601

        let jsonWithFractional = """
        {
            "linkType": "view_only",
            "expiresAt": "2026-08-08T11:01:04.820Z"
        }
        """.data(using: .utf8)!

        let decoded1 = try jsonDecoder.decode(CreateShareLinkInput.self, from: jsonWithFractional)
        XCTAssertNotNil(decoded1.expiresAt)
        XCTAssertEqual(decoded1.linkType, .viewOnly)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components1 = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: decoded1.expiresAt!)
        XCTAssertEqual(components1.year, 2026)
        XCTAssertEqual(components1.month, 8)
        XCTAssertEqual(components1.day, 8)
        XCTAssertEqual(components1.hour, 11)
        XCTAssertEqual(components1.minute, 1)
        XCTAssertEqual(components1.second, 4)

        let jsonWithoutFractional = """
        {
            "linkType": "collaborative",
            "expiresAt": "2026-08-08T11:01:04Z"
        }
        """.data(using: .utf8)!

        let decoded2 = try jsonDecoder.decode(CreateShareLinkInput.self, from: jsonWithoutFractional)
        XCTAssertNotNil(decoded2.expiresAt)
        XCTAssertEqual(decoded2.linkType, .collaborative)
    }

    func testISO8601DateEncoding() throws {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .customISO8601

        let testDate = Date(timeIntervalSince1970: 1786186864.820) // 2026-08-08T11:01:04.820Z
        let input = CreateShareLinkInput(expiresAt: testDate, password: nil, linkType: .viewOnly)

        let encodedData = try jsonEncoder.encode(input)
        let jsonString = String(data: encodedData, encoding: .utf8)!

        XCTAssertTrue(jsonString.contains("2026-08-08T11:01:04.820Z") || jsonString.contains("2026-08-08T11:01:04"))
    }
}
