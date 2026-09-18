import Foundation
import Testing
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import RuneKernel
@testable import RuneTools

@Suite("端侧文档工具")
struct DocumentToolsTests {
    @Test("CSV 识别嵌套引号、字段内逗号和换行")
    func quotedCSV() throws {
        let source = "name,note\r\nA,\"first, second\"\r\nB,\"line1\nline2 \"\"quoted\"\"\"\r\n"
        let rows = try DelimitedText.parse(source, separator: ",", limit: 20)
        #expect(rows == [["name", "note"], ["A", "first, second"], ["B", "line1\nline2 \"quoted\""]])
    }
    @Test("CSV 未闭合引号拒绝；TSV 与 BOM 支持")
    func invalidAndTSV() throws {
        #expect(throws: ToolError.self) { try DelimitedText.parse("a,\"open", separator: ",", limit: 10) }
        #expect(try DelimitedText.parse("\u{FEFF}a\tb\n1\t2", separator: "\t", limit: 1) == [["a", "b"]])
    }
    @Test("表格通过授权字节入口读取，只回传请求范围")
    func tableTool() throws {
        let store = InMemoryArtifactStore()
        let tool = DocumentToolExecutor(read: { path, _ in
            #expect(path.description == "/workspace/test.csv")
            return Data("a,b\n1,2\n3,4\n5,6".utf8)
        }, artifacts: store)
        let result = try tool.execute(.init(id: "t", name: ToolName.readTable,
            argumentsJSON: Data("{\"path\":\"test.csv\",\"max_rows\":1}".utf8)))
        #expect(result.status == .ok)
        let json = try JSONValue.parse(result.summary)
        #expect(json.value(at: ["returned_rows"])?.intValue == 2)
        #expect(!result.summary.contains("5"))
    }
    @Test("PDF 提取真实文字层并保留页号")
    func pdfTool() throws {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = CGDataConsumer(data: bytes as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Rune PDF verification", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
        context.textPosition = CGPoint(x: 20, y: 100); CTLineDraw(line, context)
        context.endPDFPage(); context.closePDF()
        let data = bytes as Data
        let tool = DocumentToolExecutor(read: { _, _ in data }, artifacts: InMemoryArtifactStore())
        let result = try tool.execute(.init(id: "pdf", name: ToolName.readPDF, argumentsJSON: Data("{\"path\":\"test.pdf\"}".utf8)))
        #expect(result.summary.contains("Rune PDF verification"))
        #expect(result.summary.contains("第 1 页"))
    }
    @Test("非图像输入不能假装 OCR 成功")
    func invalidOCR() throws {
        let tool = DocumentToolExecutor(read: { _, _ in Data("not an image".utf8) }, artifacts: InMemoryArtifactStore())
        #expect(throws: ToolError.self) { try tool.execute(.init(id: "ocr", name: ToolName.ocrImage, argumentsJSON: Data("{\"path\":\"a.png\"}".utf8))) }
    }
    @Test("OCR 注册为只读，不要求未使用的原生授权")
    func readOnlySpec() throws {
        let spec = try #require(DocumentToolExecutor.specifications[ToolName.ocrImage])
        #expect(spec.requirements == [.fsRead])
        #expect(spec.riskLevel == .safe)
    }
    @Test("Vision 在本机识别真实图片中的文字")
    func actualOCR() throws {
        let context = CGContext(data: nil, width: 900, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 900, height: 180))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "RUNE LOCAL OCR", attributes: [.font: NSFont.systemFont(ofSize: 60), .foregroundColor: NSColor.black]))
        context.textPosition = CGPoint(x: 40, y: 65); CTLineDraw(line, context)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = data as Data
        let tool = DocumentToolExecutor(read: { _, _ in image }, artifacts: InMemoryArtifactStore())
        let result = try tool.execute(.init(id: "ocr", name: ToolName.ocrImage,
            argumentsJSON: Data("{\"path\":\"image.png\",\"languages\":[\"en-US\"]}".utf8)))
        #expect(result.summary.uppercased().contains("RUNE LOCAL OCR"), "实际 OCR：\(result.summary)")
    }

}
