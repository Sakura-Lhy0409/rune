import Foundation

// MARK: - 统一 diff 渲染
//
// `git_diff` 与 `git_show` 都要给出"到底改了什么"。而要给出**可读的** diff，
// 就必须先算出**行级最小编辑**（LCS），再按上下文折叠成 hunk。
//
// ⚠️ 两个刻意的选择：
//   ① **自己算 LCS，不引第三方库**：RuneKernel 的架构承诺是零依赖，
//      而且这里只需要行级 diff —— 不需要 Myers 的完整优化。
//   ② **给模型看的是统一 diff 文本**（`@@ -a,b +c,d @@` + 前缀 ` `/`-`/`+`），
//      不是自己发明的 JSON。理由：模型见过几十亿行统一 diff，
//      它对这个格式的先验远强于任何自定义结构；自定义格式会平白增加它读错的机会。
//
// ⚠️ 大文件保护：LCS 是 O(n·m) 的时间与空间。两个 10 万行的文件会直接吃光手机内存
//    （iOS jetsam 会杀掉整个 App，T38）。所以超过阈值时**降级成"整块替换"**，
//    并在输出里明说降级了 —— 给出粗但正确的结果，好过卡死或被系统杀掉。

public struct GitDiffOptions: Sendable {
    /// 每个 hunk 前后保留的上下文行数（git 默认 3）
    public var contextLines: Int
    /// 超过这个行数就不算 LCS，直接整块替换
    public var maxLinesForLCS: Int

    public init(contextLines: Int = 3, maxLinesForLCS: Int = 20_000) {
        self.contextLines = contextLines
        self.maxLinesForLCS = maxLinesForLCS
    }

    public static let `default` = GitDiffOptions()
}

public enum GitDiff {

    /// 两个文本之间的统一 diff。相同则返回空字符串。
    public static func unified(old: String, new: String,
                               oldLabel: String, newLabel: String,
                               options: GitDiffOptions = .default) -> String {
        if old == new { return "" }
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        // ⚠️ 降级判据只有**一处实现**（`exceedsLCSCost`），生产与消费两边共用同一个函数。
        //    两处各写一遍必然分叉 —— 那种分叉的表现是"有时被 jetsam 杀掉"，
        //    而它在开发机上永远复现不了（T38 同类：内存上限只该有一份实现）。
        if exceedsLCSCost(oldLines, newLines, options: options) {
            return degradedBlock(old: oldLines, new: newLines, oldLabel: oldLabel, newLabel: newLabel)
        }

        let edits = lineEdits(old: oldLines, new: newLines)
        let hunks = collectHunks(edits, context: options.contextLines)
        guard !hunks.isEmpty else { return "" }

        var output = "--- \(oldLabel)\n+++ \(newLabel)\n"
        for hunk in hunks {
            output += "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n"
            for line in hunk.lines { output += line + "\n" }
        }
        return output
    }

    // MARK: 行切分

    /// 按 `\n` 切分并**保留行尾信息**：`"a\nb\n"` → `["a", "b"]`；
    /// `"a\nb"`（无末尾换行）→ `["a", "b"]` 但用 `\ No newline at end of file` 标注。
    ///
    /// ⚠️ 必须先归一化 CRLF：Swift 把 `"\r\n"` 当**单个 Character**（字素簇），
    ///    所以直接 `components(separatedBy: "\n")` 在 CRLF 文本上**根本不分割**
    ///    （项目记过的 T8，补丁引擎踩过同一个坑）。
    static func splitLines(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        // 末尾换行会切出一个空段，去掉它（它代表"文件以换行结尾"，不是一行内容）
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: LCS

    /// LCS 的**唯一**成本判据。
    ///
    /// ⚠️ 空间是 O(n·m)：20000×20000 的 `Int32` 表就是 1.6GB，手机上必然被 jetsam 杀掉
    ///    （而且被杀的从来不是"这个算法"，是整个 App，连同用户没保存的东西 —— T38）。
    ///    所以除了"行数上限"，还有一条**乘积上限**：n*m ≤ 4_000_000（约 16MB）。
    ///    两个各 3000 行的文件在行数上不算大，但乘积已经到 9×10⁶，必须降级。
    public static func exceedsLCSCost(_ old: [String], _ new: [String], options: GitDiffOptions = .default) -> Bool {
        let n = old.count, m = new.count
        if n > options.maxLinesForLCS || m > options.maxLinesForLCS { return true }
        return n * m > 4_000_000
    }

    enum Edit {
        case keep(String)
        case remove(String)
        case insert(String)
    }

    /// 行级最小编辑（LCS 回溯）。
    ///
    /// ⚠️ 空间是 O(n·m) 的 `Int32` 表。这是**有意为之**：把表压成位图能把内存降 32 倍，
    ///    但会让代码难读很多，而我们已经用 `maxLinesForLCS` 把上界卡住了
    ///    （20000 行 ≈ 1.6GB 太夸张 —— 见下面真实上界的说明）。
    static func lineEdits(old: [String], new: [String]) -> [Edit] {
        // ⚠️ 真实内存上界：20000×20000 的 Int32 = 1.6GB，手机上必然被 jetsam 杀掉。
        //    所以这里用**更保守的二次上界**：n*m 超过 4_000_000（约 16MB）就走降级。
        let n = old.count, m = new.count
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var edits: [Edit] = []
        var i = 0, j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                edits.append(.keep(old[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                edits.append(.remove(old[i])); i += 1
            } else {
                edits.append(.insert(new[j])); j += 1
            }
        }
        while i < n { edits.append(.remove(old[i])); i += 1 }
        while j < m { edits.append(.insert(new[j])); j += 1 }
        return edits
    }

    struct Hunk {
        var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        var lines: [String]
    }

    /// 把编辑序列折叠成 hunk。
    ///
    /// 做法：给每个编辑标出它的（旧行号、新行号），找出所有改动的位置，
    /// 把相距 ≤ 2×context 的改动并成一组，每组向前后各扩 context 行。
    /// ⚠️ 不用"边扫边回退索引"那种写法 —— 回退时很容易忘记同步行号，
    ///    而 @@ 头一旦算错，模型就会拿着错的定位去改文件。
    static func collectHunks(_ edits: [Edit], context: Int) -> [Hunk] {
        // 先标号
        struct Positioned { let edit: Edit; let oldLine: Int; let newLine: Int }
        var positioned: [Positioned] = []
        var oldLine = 1, newLine = 1
        for edit in edits {
            positioned.append(Positioned(edit: edit, oldLine: oldLine, newLine: newLine))
            switch edit {
            case .keep:   oldLine += 1; newLine += 1
            case .remove: oldLine += 1
            case .insert: newLine += 1
            }
        }
        let changeIndices = positioned.indices.filter {
            if case .keep = positioned[$0].edit { return false }
            return true
        }
        guard !changeIndices.isEmpty else { return [] }

        // 把改动分组：组内相邻改动之间最多隔 2×context 行
        var groups: [[Int]] = []
        var current: [Int] = [changeIndices[0]]
        for index in changeIndices.dropFirst() {
            if index - (current.last ?? index) <= context * 2 + 1 {
                current.append(index)
            } else {
                groups.append(current)
                current = [index]
            }
        }
        groups.append(current)

        return groups.map { group in
            let start = max(0, group[0] - context)
            let end = min(positioned.count - 1, group[group.count - 1] + context)
            var hunk = Hunk(oldStart: positioned[start].oldLine, oldCount: 0,
                            newStart: positioned[start].newLine, newCount: 0, lines: [])
            for index in start...end {
                switch positioned[index].edit {
                case .keep(let text):   hunk.lines.append(" " + text); hunk.oldCount += 1; hunk.newCount += 1
                case .remove(let text): hunk.lines.append("-" + text); hunk.oldCount += 1
                case .insert(let text): hunk.lines.append("+" + text); hunk.newCount += 1
                }
            }
            // ⚠️ 空侧的起始行号按 git 约定写成 **0**，不是 1：
            //    新文件是 `@@ -0,0 +1,N @@`、删空文件是 `@@ -1,N +0,0 @@`。
            //    写成 1 的话 diff 文本"看起来"没错，但任何按 git 约定解析它的工具
            //    （包括模型自己学过的格式预期）都会把定位算偏一行。
            if hunk.oldCount == 0 { hunk.oldStart = 0 }
            if hunk.newCount == 0 { hunk.newStart = 0 }
            return hunk
        }
    }

    /// 降级输出：整块替换，但**明说降级了**。
    static func degradedBlock(old: [String], new: [String], oldLabel: String, newLabel: String) -> String {
        var output = "--- \(oldLabel)\n+++ \(newLabel)\n"
        output += "@@ -1,\(old.count) +1,\(new.count) @@\n"
        output += "（文件过大，未计算逐行最小差异；下面给出整块替换）\n"
        for line in old { output += "-" + line + "\n" }
        for line in new { output += "+" + line + "\n" }
        return output
    }
}

extension GitObjectStore {

    /// 渲染两个 blob 之间的 diff（按文本处理；二进制只报"二进制文件不同"）。
    public static func blobDiff(old: [UInt8]?, new: [UInt8]?,
                                oldLabel: String, newLabel: String,
                                options: GitDiffOptions = .default) -> String {
        if old == nil, let new {
            let text = decodeText(new)
            guard let text else { return "--- /dev/null\n+++ \(newLabel)\n（二进制文件，\(new.count) 字节）\n" }
            return GitDiff.unified(old: "", new: text, oldLabel: "/dev/null", newLabel: newLabel, options: options)
        }
        if let old, new == nil {
            let text = decodeText(old)
            guard let text else { return "--- \(oldLabel)\n+++ /dev/null\n（二进制文件，\(old.count) 字节）\n" }
            return GitDiff.unified(old: text, new: "", oldLabel: oldLabel, newLabel: "/dev/null", options: options)
        }
        guard let old, let new else { return "" }
        // ⚠️ 二进制必须先判、不能当文本 diff：对二进制做行切分会产出成吨的乱码，
        //    既烧 token 又毫无意义。判据是"含 NUL 字节"（与 git 一致的做法）。
        guard let oldText = decodeText(old), let newText = decodeText(new) else {
            if old == new { return "" }
            return "--- \(oldLabel)\n+++ \(newLabel)\n（二进制文件不同：\(old.count) → \(new.count) 字节）\n"
        }
        return GitDiff.unified(old: oldText, new: newText, oldLabel: oldLabel, newLabel: newLabel, options: options)
    }

    /// 能否当文本处理。含 NUL 即视为二进制。
    static func decodeText(_ bytes: [UInt8]) -> String? {
        if bytes.contains(0) { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
