@testable import FynnCloudServer
import XCTest

final class FilenameValidatorTests: XCTestCase {

    func testValidFilenames() {
        let validNames = [
            "document.pdf",
            "My Folder 2026",
            "archive.tar.gz",
            "file-with_dashes-and_underscores.txt",
            "résumé_français.docx",
            "日本語ドキュメント.pdf",
            "äöü_schweiz.png",
            "A.B.C.D.txt",
            "12345.json",
        ]

        for name in validNames {
            XCTAssertTrue(FilenameValidator.isValid(filename: name), "Expected '\(name)' to be valid")
            XCTAssertNoThrow(try FilenameValidator.validate(filename: name))
        }
    }

    func testEmptyAndWhitespaceFilenames() {
        let invalidNames = [
            "",
            " ",
            "   \t\n  ",
        ]

        for name in invalidNames {
            XCTAssertFalse(FilenameValidator.isValid(filename: name), "Expected '\(name)' to be invalid")
            XCTAssertThrowsError(try FilenameValidator.validate(filename: name))
        }
    }

    func testRelativeDirectoryNames() {
        let invalidNames = [
            ".",
            "..",
            " . ",
            " .. ",
        ]

        for name in invalidNames {
            XCTAssertFalse(FilenameValidator.isValid(filename: name), "Expected '\(name)' to be invalid")
            XCTAssertThrowsError(try FilenameValidator.validate(filename: name))
        }
    }

    func testIllegalCharacters() {
        let invalidNames = [
            "folder/file.txt",
            "folder\\file.txt",
            "file:name.txt",
            "file*name.txt",
            "file?name.txt",
            "file\"name.txt",
            "file<name.txt",
            "file>name.txt",
            "file|name.txt",
            "file\0name.txt",
            "file\nname.txt",
            "file\rname.txt",
        ]

        for name in invalidNames {
            XCTAssertFalse(FilenameValidator.isValid(filename: name), "Expected '\(name)' to be invalid")
            XCTAssertThrowsError(try FilenameValidator.validate(filename: name))
        }
    }

    func testTrailingDotOrSpace() {
        let invalidNames = [
            "filename.",
            "filename..",
            "filename ",
            "filename  ",
        ]

        for name in invalidNames {
            XCTAssertFalse(FilenameValidator.isValid(filename: name), "Expected '\(name)' to be invalid")
            XCTAssertThrowsError(try FilenameValidator.validate(filename: name))
        }
    }

    func testWindowsReservedDeviceNames() {
        let reservedNames = [
            "CON",
            "con",
            "con.txt",
            "PRN",
            "prn.pdf",
            "AUX",
            "aux.png",
            "NUL",
            "nul.tar.gz",
            "COM1",
            "com1.doc",
            "COM9",
            "LPT1",
            "lpt1.txt",
            "LPT9",
        ]

        for name in reservedNames {
            XCTAssertFalse(FilenameValidator.isValid(filename: name), "Expected '\(name)' to be invalid")
            XCTAssertThrowsError(try FilenameValidator.validate(filename: name))
        }
    }

    func testLengthLimits() {
        let exactly255 = String(repeating: "a", count: 251) + ".txt"
        XCTAssertEqual(exactly255.utf8.count, 255)
        XCTAssertTrue(FilenameValidator.isValid(filename: exactly255))

        let tooLong256 = String(repeating: "a", count: 252) + ".txt"
        XCTAssertEqual(tooLong256.utf8.count, 256)
        XCTAssertFalse(FilenameValidator.isValid(filename: tooLong256))
        XCTAssertThrowsError(try FilenameValidator.validate(filename: tooLong256))
    }

    func testSanitize() {
        XCTAssertEqual(FilenameValidator.sanitize(filename: "hello/world/test.txt"), "test.txt")
        XCTAssertEqual(FilenameValidator.sanitize(filename: "C:\\Users\\admin\\document.pdf"), "document.pdf")
        XCTAssertEqual(FilenameValidator.sanitize(filename: "file:name?*<>|test.txt"), "file_name_____test.txt")
        XCTAssertEqual(FilenameValidator.sanitize(filename: "con.txt"), "_con.txt")
        XCTAssertEqual(FilenameValidator.sanitize(filename: "trailing.dot."), "trailing.dot")
        XCTAssertEqual(FilenameValidator.sanitize(filename: "   spaced name   "), "spaced name")
        XCTAssertEqual(FilenameValidator.sanitize(filename: ""), "unnamed")
        XCTAssertEqual(FilenameValidator.sanitize(filename: "."), "unnamed")
        XCTAssertEqual(FilenameValidator.sanitize(filename: ".."), "unnamed")

        let hugeName = String(repeating: "x", count: 300) + ".pdf"
        let sanitizedHuge = FilenameValidator.sanitize(filename: hugeName)
        XCTAssertLessThanOrEqual(sanitizedHuge.utf8.count, 255)
        XCTAssertTrue(sanitizedHuge.hasSuffix(".pdf"))
        XCTAssertTrue(FilenameValidator.isValid(filename: sanitizedHuge))
    }
}
