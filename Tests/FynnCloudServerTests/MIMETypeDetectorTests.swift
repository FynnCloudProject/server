import XCTest
@testable import FynnCloudServer

final class MIMETypeDetectorTests: XCTestCase {
    func testMIMETypeDetectionFromExtension() {
        XCTAssertEqual(MIMETypeDetector.detect(filename: "image.png"), "image/png")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "photo.JPEG"), "image/jpeg")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "document.pdf"), "application/pdf")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "archive.tar.gz"), "application/gzip")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "script.js"), "text/javascript")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "style.css"), "text/css")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "notes.txt"), "text/plain")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "song.mp3"), "audio/mpeg")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "video.mp4"), "video/mp4")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "auth.key"), "application/x-pem-file")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "presentation.keynote"), "application/vnd.apple.keynote")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "config.yaml"), "text/yaml")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "app.ts"), "application/typescript")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "cert.pem"), "application/x-pem-file")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "id_rsa.pub"), "text/plain")
        XCTAssertEqual(MIMETypeDetector.detect(filename: "query.sql"), "application/sql")
    }

    func testFallbackContentType() {
        XCTAssertEqual(
            MIMETypeDetector.detect(filename: "unknown.foo12345bar", fallback: "application/x-custom"),
            "application/x-custom"
        )
        XCTAssertEqual(
            MIMETypeDetector.detect(filename: "noextension", fallback: "text/plain"),
            "text/plain"
        )
        XCTAssertEqual(
            MIMETypeDetector.detect(filename: "image.png", fallback: "application/octet-stream"),
            "image/png"
        )
    }
}
