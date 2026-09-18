import Foundation
import PDFKit
import Vision
import ImageIO
import RuneKernel

/// 只读、端侧文档工具。文件字节必须由宿主的授权 VFS 提供，工具自身没有任意磁盘入口。
public struct DocumentToolExecutor: ToolExecuting, Sendable {
    public static let names = [ToolName.readPDF, ToolName.ocrImage, ToolName.readTable]
    public static let specifications: [String: ToolSpec] = {
        var result = ToolRegistry.byName.filter { names.contains($0.key) }
        for (name, spec) in result {
            let description = name == ToolName.readTable
                ? "读取 CSV/TSV 的列和前 N 行，支持引号与换行；不支持 Excel，请先导出 CSV。"
                : name == ToolName.ocrImage ? "使用端侧 Vision 识别图片中的文字，按观察顺序返回；不保证表格结构。" : spec.description
            result[name] = ToolSpec(name: name, description: description, inputSchema: spec.inputSchema,
                pathParameters: spec.pathParameters, example: spec.example, concurrency: .exclusive,
                isIdempotent: true, riskLevel: .safe, needsApproval: .never,
                outputShape: spec.outputShape, requirements: [.fsRead])
        }
        return result
    }()
    private let read: @Sendable (VFSPath, Int) throws -> Data
    private let artifacts: any ArtifactStore
    public init(read: @escaping @Sendable (VFSPath, Int) throws -> Data, artifacts: any ArtifactStore) {
        self.read = read; self.artifacts = artifacts
    }
    public func execute(_ call: ToolCall) throws -> ToolResult {
        guard let spec = Self.specifications[call.name] else { throw ToolError(kind: .unknownTool, modelFacingMessage: "没有此文档工具。") }
        let args = try call.arguments()
        guard SchemaValidator.validate(args, against: spec.inputSchema), let raw = args.value(at: ["path"])?.stringValue else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "文档工具参数不符合契约。")
        }
        let absolute = raw.hasPrefix("/") ? raw : "/workspace/" + raw
        let path = try VFSPath.parse(absolute)
        let bytes = try read(path, call.name == ToolName.readTable ? 2 * 1024 * 1024 : 20 * 1024 * 1024)
        let text: String
        switch call.name {
        case ToolName.readPDF: text = try pdf(bytes, args: args)
        case ToolName.ocrImage: text = try ocr(bytes, args: args)
        default:
            guard ["csv", "tsv"].contains((raw as NSString).pathExtension.lowercased()), let source = String(data: bytes, encoding: .utf8) else {
                throw ToolError(kind: .invalidArguments, modelFacingMessage: "当前支持 UTF-8 CSV/TSV，请先将 Excel 导出为 CSV。")
            }
            let rows = try DelimitedText.parse(source, separator: raw.lowercased().hasSuffix(".tsv") ? "\t" : ",", limit: min(1001, (args.value(at: ["max_rows"])?.intValue ?? 20) + 1))
            text = JSONValue.object(["rows": .array(rows.map { .array($0.map(JSONValue.string)) }), "returned_rows": .int(rows.count), "note": .string("第一行按原文件保留；结果最多包含请求行数加表头。")]).canonicalString()
        }
        if text.utf8.count <= 16_384 { return .ok(callID: call.id, summary: text) }
        let artifact = try artifacts.store(text, suggestedName: "document-text.txt", kind: .document)
        return .ok(callID: call.id, summary: String(text.prefix(4000)) + "\n[全文：\(artifact.relPath)]", artifacts: [artifact])
    }
    private func pdf(_ bytes: Data, args: JSONValue) throws -> String {
        guard let document = PDFDocument(data: bytes), !document.isLocked else { throw ToolError(kind: .invalidArguments, modelFacingMessage: "PDF 损坏或被密码锁定。") }
        let start = args.value(at: ["start_page"])?.intValue ?? 1
        guard start > 0, start <= document.pageCount else { throw ToolError(kind: .invalidArguments, modelFacingMessage: "页码不在文档范围内（共 \(document.pageCount) 页）。") }
        let end = min(document.pageCount, min(start + 19, args.value(at: ["end_page"])?.intValue ?? start + 19))
        guard end >= start else { throw ToolError(kind: .invalidArguments, modelFacingMessage: "结束页不能小于起始页。") }
        var text = "PDF 共 \(document.pageCount) 页；本次 \(start)–\(end) 页。\n"
        for index in (start - 1)..<end {
            text += "\n--- 第 \(index + 1) 页 ---\n" + (document.page(at: index)?.string ?? "（无文字层，请使用图像 OCR）")
            if text.utf8.count > 1_000_000 { text = String(text.prefix(200_000)) + "\n（输出达到上限，请缩小页码范围。）"; break }
        }
        return text
    }
    private func ocr(_ bytes: Data, args: JSONValue) throws -> String {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 24_000_000 else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "无法识别图像，或像素超过 2400 万上限。")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let languages = args.value(at: ["languages"])?.arrayValue?.compactMap(\.stringValue) ?? ["zh-Hans", "en-US"]
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = Array(languages.filter { supported.contains($0) }.prefix(4))
        let handler = VNImageRequestHandler(data: bytes, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.isEmpty ? "图片中未识别到文字。" : observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

public enum DelimitedText {
    public static func parse(_ source: String, separator: Character, limit: Int) throws -> [[String]] {
        guard limit > 0 else { return [] }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let chars = Array(normalized.hasPrefix("\u{FEFF}") ? String(normalized.dropFirst()) : normalized)
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else if quoted { quoted = false }
                else if field.isEmpty { quoted = true }
                else { field.append(char) }
            } else if !quoted && char == separator { row.append(field); field = "" }
            else if !quoted && char == "\n" {
                row.append(field); rows.append(row); row = []; field = ""
                if rows.count == limit { return rows }
            } else { field.append(char) }
            guard field.utf8.count < 1_000_000, row.count < 10_000 else { throw ToolError(kind: .invalidArguments, modelFacingMessage: "表格单元格或列数超过上限。") }
            i += 1
        }
        guard !quoted else { throw ToolError(kind: .invalidArguments, modelFacingMessage: "CSV 引号未闭合。") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
