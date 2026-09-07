import Crypto
import Foundation
import NIOCore
import XCTest
@testable import FynnCloudServer

final class FileTemplatesTests: XCTestCase {
    func testDocxTemplateIsValid() throws {
        let data = try FileTemplates.loadTemplateData(for: .document)
        XCTAssertEqual(data.count, 1219)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "40d7fc3a53bc73edb2c3a80a04cc64f157dcd2b06f4ca16ce34a65f80f7cabef")
    }

    func testXlsxTemplateIsValid() throws {
        let data = try FileTemplates.loadTemplateData(for: .spreadsheet)
        XCTAssertEqual(data.count, 1576)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "755f7acded44e1f22d03dac1ac9f7cd2cfa492b0dbac435b2422f2be570a1c61")
    }

    func testPptxTemplateIsValid() throws {
        let data = try FileTemplates.loadTemplateData(for: .presentation)
        XCTAssertEqual(data.count, 3807)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "e3b2ed39e78a3f0f379dae3cb2e542cbd3b0b582f1ec473bb37c58e27411419b")
    }

    func testNewFileTypeBuffers() throws {
        XCTAssertEqual(NewFileType.document.fileExtension, "docx")
        let docxBuf = try NewFileType.document.initialBuffer()
        let docxData = try NewFileType.document.initialData()
        XCTAssertEqual(docxBuf.readableBytes, 1219)
        XCTAssertEqual(docxData.count, 1219)

        XCTAssertEqual(NewFileType.spreadsheet.fileExtension, "xlsx")
        let xlsxBuf = try NewFileType.spreadsheet.initialBuffer()
        let xlsxData = try NewFileType.spreadsheet.initialData()
        XCTAssertEqual(xlsxBuf.readableBytes, 1576)
        XCTAssertEqual(xlsxData.count, 1576)

        XCTAssertEqual(NewFileType.presentation.fileExtension, "pptx")
        let pptxBuf = try NewFileType.presentation.initialBuffer()
        let pptxData = try NewFileType.presentation.initialData()
        XCTAssertEqual(pptxBuf.readableBytes, 3807)
        XCTAssertEqual(pptxData.count, 3807)

        XCTAssertEqual(NewFileType.text.fileExtension, "txt")
        let txtBuf = try NewFileType.text.initialBuffer()
        let txtData = try NewFileType.text.initialData()
        XCTAssertEqual(txtBuf.readableBytes, 0)
        XCTAssertEqual(txtData.count, 0)
    }
}
