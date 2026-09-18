import Foundation
import Testing
@testable import RuneKernel

// MARK: - 统一 diff 渲染
//
// ⚠️ 这一组里最要紧的不是"能输出 diff"，而是 **`@@` 头的行号必须精确**。
//    模型拿到 `@@ -12,3 +12,4 @@` 之后会照着它去定位、去改文件 ——
//    行号偏一行，它就会改错地方，而且是**静默地改错**（补丁应用成功、内容不对）。
//    所以下面每一条都在钉行号，而不只是钉"有没有 +/- 行"。

private func diff(_ old: String, _ new: String, context: Int = 3) -> String {
    GitDiff.unified(old: old, new: new, oldLabel: "a/f.txt", newLabel: "b/f.txt",
                    options: GitDiffOptions(contextLines: context))
}

@Suite("统一 diff —— 基本形态")
struct GitDiffBasicsTests {

    @Test("相同内容 → 空 diff（不是空 hunk 头）")
    func identicalProducesNothing() {
        #expect(diff("a\nb\n", "a\nb\n").isEmpty)
        #expect(diff("", "").isEmpty)
    }

    @Test("⭐ 纯插入：只有 + 行，且 @@ 头必须对")
    func pureInsertion() {
        let result = diff("a\nb\nc\n", "a\nb\nNEW\nc\n")
        #expect(result.contains("--- a/f.txt"))
        #expect(result.contains("+++ b/f.txt"))
        #expect(result.contains("+NEW"))
        #expect(!result.contains("\n-NEW"))
        // 改动发生在第 3 行（NEW 插在 b 之后），上下文 3 行 → 整个文件都在一个 hunk 里
        #expect(result.contains("@@ -1,3 +1,4 @@"), "实际输出：\n\(result)")
    }

    @Test("⭐ 纯删除：只有 - 行")
    func pureDeletion() {
        let result = diff("a\nb\nc\n", "a\nc\n")
        #expect(result.contains("-b"))
        #expect(result.contains("@@ -1,3 +1,2 @@"), "实际输出：\n\(result)")
    }

    @Test("⭐ 改动：- 旧 + 新成对出现")
    func modification() {
        let result = diff("a\nb\nc\n", "a\nB\nc\n")
        #expect(result.contains("-b"))
        #expect(result.contains("+B"))
        #expect(result.contains("@@ -1,3 +1,3 @@"), "实际输出：\n\(result)")
    }

    @Test("⭐ 新文件（老内容为空）：用 /dev/null 当旧标签")
    func newFile() {
        let result = GitDiff.unified(old: "", new: "hello\n", oldLabel: "/dev/null", newLabel: "b/f.txt")
        #expect(result.contains("--- /dev/null"))
        #expect(result.contains("+hello"))
        #expect(result.contains("@@ -0,0 +1,1 @@"), "新文件的旧侧应当是 -0,0，实际输出：\n\(result)")
    }

    @Test("⭐ 删空文件：用 /dev/null 当新标签")
    func deletedFile() {
        let result = GitDiff.unified(old: "hello\n", new: "", oldLabel: "a/f.txt", newLabel: "/dev/null")
        #expect(result.contains("+++ /dev/null"))
        #expect(result.contains("-hello"))
    }
}

@Suite("统一 diff —— 行号必须精确")
struct GitDiffLineNumberTests {

    @Test("⭐⭐ 远处改动：@@ 头的新旧行号都要对（错一行模型就会改错地方）")
    func distantChange() {
        // 20 行文件，改第 15 行；上下文 2 行 → hunk 覆盖 13..17
        let old = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...20).map { "line\($0)" }
        lines[14] = "CHANGED"
        let new = lines.joined(separator: "\n") + "\n"

        let result = diff(old, new, context: 2)
        // 第 15 行 → 上下文 2 → 从第 13 行开始，覆盖 13,14,15,16,17 = 5 行
        #expect(result.contains("@@ -13,5 +13,5 @@"), "实际输出：\n\(result)")
        // 上下文行必须带正确的行号内容
        #expect(result.contains(" line13"))
        #expect(result.contains(" line14"))
        #expect(result.contains("-line15"))
        #expect(result.contains("+CHANGED"))
        #expect(result.contains(" line16"))
        #expect(result.contains(" line17"))
        // 第 12 行与第 18 行不该出现（上下文只有 2）
        #expect(!result.contains(" line12"))
        #expect(!result.contains(" line18"))
    }

    @Test("⭐⭐ 两处相距很远的改动 → 两个独立 hunk，行号各自正确")
    func twoSeparateHunks() {
        var lines = (1...40).map { "line\($0)" }
        lines[2] = "FIRST"      // 第 3 行
        lines[36] = "SECOND"    // 第 37 行
        let new = lines.joined(separator: "\n") + "\n"
        let old = (1...40).map { "line\($0)" }.joined(separator: "\n") + "\n"

        let result = diff(old, new, context: 1)
        let hunkHeaders = result.split(separator: "\n").filter { $0.hasPrefix("@@") }
        #expect(hunkHeaders.count == 2, "相距很远的改动必须是两个 hunk，实际：\n\(result)")
        // 第一处：第 3 行，上下文 1 → 从第 2 行起，覆盖 2,3,4
        #expect(result.contains("@@ -2,3 +2,3 @@"), "第一个 hunk 头错了：\n\(result)")
        // 第二处：第 37 行，上下文 1 → 从第 36 行起
        #expect(result.contains("@@ -36,3 +36,3 @@"), "第二个 hunk 头错了：\n\(result)")
    }

    @Test("⭐ 文件开头的改动：@@ 从第 1 行开始，不能出现 0 或负数")
    func changeAtVeryStart() {
        // 3 行文件、context=1、改在第 1 行 → hunk 只覆盖第 1、2 行（共 2 行），
        // 不是 3 行。**期望值必须自己算清楚**，不能照着"看着差不多"写。
        let result = diff("OLD\nb\nc\n", "NEW\nb\nc\n", context: 1)
        #expect(result.contains("@@ -1,2 +1,2 @@"), "实际输出：\n\(result)")
        // ⚠️ 断言要针对**@@ 头里的行号**，不能笼统地查全文有没有 "-0" ——
        //    被删掉的代码行本身可能就含 "0"（例如 "-old0"），那种断言会假红。
        let headers = result.split(separator: "\n").filter { $0.hasPrefix("@@") }
        #expect(headers.count == 1, "实际：\(headers)")
        #expect(headers.first?.contains("-0,") == false, "行号不能从 0 开始：\(headers)")
        #expect(headers.first?.contains("+0,") == false, "行号不能从 0 开始：\(headers)")
    }

    @Test("⭐ 文件结尾的改动：行数要算对（不能多算一行）")
    func changeAtVeryEnd() {
        let result = diff("a\nb\nOLD\n", "a\nb\nNEW\n", context: 3)
        #expect(result.contains("@@ -1,3 +1,3 @@"), "实际输出：\n\(result)")
        #expect(result.contains("-OLD"))
        #expect(result.contains("+NEW"))
    }
}

@Suite("统一 diff —— 边界与陷阱")
struct GitDiffEdgeCaseTests {

    @Test("⚠️ CRLF 文本必须能正确切行（Swift 把 \\r\\n 当单个字素簇，T8）")
    func crlfIsHandled() {
        // ⚠️ 不归一化的话，`components(separatedBy: "\n")` 在 CRLF 文本上**根本不分割**，
        //    整个文件会被当成一行 → diff 变成"整文件替换"，噪音巨大且误导。
        let result = diff("a\r\nb\r\nc\r\n", "a\r\nB\r\nc\r\n")
        #expect(!result.contains("整块替换"), "CRLF 不该触发降级")
        #expect(result.contains("-b"), "实际输出：\n\(result)")
        #expect(result.contains("+B"))
        // 切行正确时 hunk 只覆盖 3 行，而不是整个文件
        #expect(result.contains("@@ -1,3 +1,3 @@"), "实际输出：\n\(result)")
    }

    @Test("⚠️ 没有末尾换行的文件也要能处理")
    func missingTrailingNewline() {
        let result = diff("a\nb", "a\nB")
        #expect(result.contains("-b"))
        #expect(result.contains("+B"))
    }

    @Test("⚠️ 空文件 ↔ 非空：不能崩，也不能给出空 diff")
    func emptyToNonEmpty() {
        let result = diff("", "hello\n")
        #expect(result.contains("+hello"))
        let reverse = diff("hello\n", "")
        #expect(reverse.contains("-hello"))
    }

    @Test("⚠️ 纯空白改动要能看出来（不是「没有改动」）")
    func whitespaceOnlyChange() {
        let result = diff("a\n  b\n", "a\n\tb\n")
        #expect(!result.isEmpty, "只改空白也是改动，不能报成无差异")
        #expect(result.contains("-  b"))
        #expect(result.contains("+\tb"))
    }

    @Test("⭐⭐ 大文件必须降级，而且**明说降级了**")
    func largeFileDegradesExplicitly() {
        // ⚠️ 静默降级比降级本身更糟：模型会以为「改动就这么大」，
        //    从而对改动规模做出错误判断。所以降级输出里必须写明。
        let old = (1...9000).map { "line\($0)" }.joined(separator: "\n") + "\n"
        let new = old + "extra\n"
        let result = diff(old, new)
        #expect(result.contains("整块替换"), "超上限时必须走降级路径，实际：\n\(result.prefix(200))")
    }

    @Test("⭐ 乘积上限只该有一处实现（生产与消费共用同一个判据）")
    func singleCostJudge() {
        let small = (1...10).map { "l\($0)" }
        let big = (1...3000).map { "l\($0)" }
        #expect(GitDiff.exceedsLCSCost(small, small) == false)
        // 3000×3000 = 9×10⁶ > 4×10⁶ → 必须降级（虽然单个文件行数不大）
        #expect(GitDiff.exceedsLCSCost(big, big) == true, "乘积上限必须生效，否则 3000 行文件就吃 36MB")
    }
}

@Suite("统一 diff —— 二进制与内容类型")
struct GitDiffBinaryTests {

    @Test("⚠️ 含 NUL 的字节必须是二进制（对二进制做行切分会产出成吨乱码）")
    func binaryIsDetected() {
        let binary: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]
        #expect(GitObjectStore.decodeText(binary) == nil)
        let result = GitObjectStore.blobDiff(old: binary, new: [0x89, 0x50, 0x4E, 0x47, 0x00, 0x03],
                                             oldLabel: "a/x.png", newLabel: "b/x.png")
        #expect(result.contains("二进制"), "实际输出：\n\(result)")
    }

    @Test("⚠️ 二进制相同 → 空 diff（不能报「二进制文件不同」）")
    func identicalBinaryIsEmpty() {
        let binary: [UInt8] = [0x00, 0x01, 0x02]
        #expect(GitObjectStore.blobDiff(old: binary, new: binary, oldLabel: "a", newLabel: "b").isEmpty)
    }

    @Test("⭐ 文本 blob 走正常 diff 路径")
    func textBlobDiffs() {
        let result = GitObjectStore.blobDiff(old: Array("a\nb\n".utf8), new: Array("a\nc\n".utf8),
                                             oldLabel: "a/f.txt", newLabel: "b/f.txt")
        #expect(result.contains("-b"))
        #expect(result.contains("+c"))
    }

    @Test("⭐ 新增文件（旧为 nil）走 /dev/null 且是二进制时只说大小")
    func addedBinaryFile() {
        let result = GitObjectStore.blobDiff(old: nil, new: [0x00, 0xFF], oldLabel: "/dev/null", newLabel: "b/x.bin")
        #expect(result.contains("二进制"))
        #expect(result.contains("2 字节"))
    }
}
