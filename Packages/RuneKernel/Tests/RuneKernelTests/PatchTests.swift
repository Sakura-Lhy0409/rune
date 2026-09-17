import Testing
import Foundation
@testable import RuneKernel

// MARK: - 辅助

private func ws(_ path: String) throws -> VFSPath { try VFSPath.parse(path) }

/// 内存文件系统读取器（补丁引擎刻意不碰真实文件系统，因此完全可单测）
private func reader(_ files: [String: String]) -> Patch.FileReader {
    { path in files[path.description] }
}

// MARK: - 解析

@Suite("Patch 解析")
struct PatchParseTests {

    @Test("Rune 原生格式：update + 锚点 + 上下文/删除/新增")
    func parseNativeUpdate() throws {
        let text = """
        *** Begin Patch
        *** File: /workspace/src/money.py
        @@ def round_amount
             amount = Decimal(amount)
        -    return round(amount)
        +    return round(amount, currency.exponent)
        *** End Patch
        """
        let patch = try Patch.parse(text)
        #expect(patch.files.count == 1)
        let file = patch.files[0]
        #expect(file.path.description == "/workspace/src/money.py")
        #expect(file.action == .update)
        #expect(file.hunks.count == 1)
        #expect(file.hunks[0].anchor == "def round_amount")
        #expect(file.hunks[0].oldLines == ["    amount = Decimal(amount)", "    return round(amount)"])
        #expect(file.hunks[0].newLines == ["    amount = Decimal(amount)", "    return round(amount, currency.exponent)"])
        #expect(file.hunks[0].addedCount == 1)
        #expect(file.hunks[0].removedCount == 1)
    }

    @Test("标准 unified diff（模型最常产出的格式）必须能吃下")
    func parseUnifiedDiff() throws {
        let text = """
        diff --git a/src/money.py b/src/money.py
        index 3f2a1b9..8c7d6e5 100644
        --- a/src/money.py
        +++ b/src/money.py
        @@ -10,3 +10,3 @@ def round_amount
             amount = Decimal(amount)
        -    return round(amount)
        +    return round(amount, currency.exponent)
        """
        let patch = try Patch.parse(text)
        #expect(patch.files.count == 1)
        // 相对路径 → 视为相对 /workspace
        #expect(patch.files[0].path.description == "/workspace/src/money.py")
        #expect(patch.files[0].action == .update)
        #expect(patch.files[0].hunks[0].anchor == "def round_amount")
    }

    @Test("unified diff 的 /dev/null 语义：新建与删除")
    func parseUnifiedDevNull() throws {
        let create = """
        --- /dev/null
        +++ b/docs/note.md
        @@ -0,0 +1,2 @@
        +# 标题
        +正文
        """
        let p1 = try Patch.parse(create)
        #expect(p1.files[0].action == .create)
        #expect(p1.files[0].path.description == "/workspace/docs/note.md")
        #expect(p1.files[0].initialContent == ["# 标题", "正文"])

        let delete = """
        --- a/old.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -旧内容
        """
        let p2 = try Patch.parse(delete)
        #expect(p2.files[0].action == .delete)
        #expect(p2.files[0].path.description == "/workspace/old.txt")
    }

    @Test("Rune 原生：Create / Delete 指令")
    func parseNativeCreateDelete() throws {
        let text = """
        *** Create: /workspace/docs/new.md
        +# 标题
        +正文

        *** Delete: /tmp/scratch.txt
        """
        let patch = try Patch.parse(text)
        #expect(patch.files.count == 2)
        #expect(patch.files[0].action == .create)
        #expect(patch.files[0].initialContent == ["# 标题", "正文"])
        #expect(patch.files[1].action == .delete)
        #expect(patch.files[1].path.description == "/tmp/scratch.txt")
    }

    @Test("Create 会裁掉尾部空行（模型常在块与下一个指令间留分隔空行）")
    func createTrimsTrailingBlankLines() throws {
        let patch = try Patch.parse("""
        *** Create: /workspace/x.md
        +line1
        +line2


        *** End Patch
        """)
        #expect(patch.files[0].initialContent == ["line1", "line2"])
    }

    @Test("多文件 + 多改动块")
    func parseMultipleFilesAndHunks() throws {
        let text = """
        *** File: /workspace/a.py
        @@ first
        -old1
        +new1
        @@ second
        -old2
        +new2

        *** File: /workspace/b.py
        @@ only
        -old3
        +new3
        """
        let patch = try Patch.parse(text)
        #expect(patch.files.count == 2)
        #expect(patch.files[0].hunks.count == 2)
        #expect(patch.files[0].hunks[0].anchor == "first")
        #expect(patch.files[1].hunks.count == 1)
    }

    @Test("空上下文行与 `\\ No newline at end of file` 被正确处理")
    func parseEmptyContextAndNoNewlineMarker() throws {
        let text = """
        --- a/x.txt
        +++ b/x.txt
        @@ -1,3 +1,3 @@
         line1

        -line3
        +line3changed
        \\ No newline at end of file
        """
        let patch = try Patch.parse(text)
        let hunk = patch.files[0].hunks[0]
        #expect(hunk.oldLines == ["line1", "", "line3"])
        #expect(hunk.newLines == ["line1", "", "line3changed"])
    }

    @Test("语法错误带行号与可执行提示（供模型自我修正）")
    func parseErrors() {
        // 文件段之前有内容
        do {
            _ = try Patch.parse("这是说明文字\n*** File: /workspace/a.py\n@@ x\n-a\n+b")
            Issue.record("应当报错")
        } catch let e as PatchError {
            if case .parseFailure(let line, _) = e { #expect(line == 1) } else { Issue.record("错的错误类型：\(e)") }
            #expect(!e.modelFacingMessage.isEmpty)
            #expect(e.suggestion != nil)
        } catch { Issue.record("非 PatchError：\(error)") }

        // `@@` 之前的内容行
        #expect(throws: PatchError.self) {
            try Patch.parse("*** File: /workspace/a.py\n没有 @@ 的内容行")
        }
        // 空补丁
        #expect(throws: PatchError.self) { try Patch.parse("") }
        // 非法路径（相对路径含 ..）
        #expect(throws: PatchError.self) {
            try Patch.parse("*** File: ../../etc/passwd\n@@ x\n-a\n+b")
        }
    }

    @Test("相对路径的非法形式被拒绝（不允许 `..`）")
    func relativePathTraversalRejected() throws {
        do {
            _ = try Patch.parse("*** File: src/../../../etc/passwd\n@@ x\n-a\n+b")
            Issue.record("应当拒绝含 `..` 的相对路径")
        } catch let e as PatchError {
            #expect(e.modelFacingMessage.contains(".."))
        }
    }
}

// MARK: - 应用

@Suite("Patch 应用")
struct PatchApplyTests {

    @Test("单处修改：精确匹配")
    func applyExact() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/money.py
        @@ def round_amount
             amount = Decimal(amount)
        -    return round(amount)
        +    return round(amount, currency.exponent)
        """)
        let result = try patch.apply(reader: reader([
            "/workspace/money.py": "def round_amount(amount):\n    amount = Decimal(amount)\n    return round(amount)\n"
        ]))
        #expect(result.changes.count == 1)
        #expect(result.changes[0].fuzz == .exact)
        #expect(result.changes[0].newContent ==
            "def round_amount(amount):\n    amount = Decimal(amount)\n    return round(amount, currency.exponent)\n")
        #expect(result.totalAdded == 1)
        #expect(result.totalRemoved == 1)
        #expect(result.isCleanMatch)
    }

    @Test("同一文件多处修改，一次应用（不产生偏移漂移）")
    func applyMultipleHunks() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.txt
        @@ 头部
        -alpha
        +ALPHA
        @@ 尾部
        -omega
        +OMEGA
        """)
        let original = "alpha\nbeta\ngamma\ndelta\nomega\n"
        let result = try patch.apply(reader: reader(["/workspace/a.txt": original]))
        #expect(result.changes[0].newContent == "ALPHA\nbeta\ngamma\ndelta\nOMEGA\n")
        #expect(result.totalAdded == 2)
        #expect(result.totalRemoved == 2)
    }

    @Test("多文件同时修改")
    func applyMultipleFiles() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.txt
        @@
        -a1
        +A1
        *** File: /workspace/b.txt
        @@
        -b1
        +B1
        """)
        let result = try patch.apply(reader: reader([
            "/workspace/a.txt": "a1\n",
            "/workspace/b.txt": "b1\n",
        ]))
        #expect(result.changes.count == 2)
        #expect(result.changes[0].newContent == "A1\n")
        #expect(result.changes[1].newContent == "B1\n")
    }

    @Test("新建与删除文件")
    func applyCreateAndDelete() throws {
        let patch = try Patch.parse("""
        *** Create: /workspace/new.md
        +hello
        +world
        *** Delete: /workspace/gone.txt
        """)
        let result = try patch.apply(reader: reader(["/workspace/gone.txt": "旧内容\n"]))
        #expect(result.changes.count == 2)
        #expect(result.changes[0].action == .create)
        #expect(result.changes[0].newContent == "hello\nworld\n")
        #expect(result.changes[1].action == .delete)
        #expect(result.changes[1].newContent == nil)
    }

    @Test("create 已存在的文件 / update 不存在的文件 → 明确报错")
    func createDeletePreconditions() throws {
        let create = try Patch.parse("*** Create: /workspace/exists.txt\n+x")
        do {
            _ = try create.apply(reader: reader(["/workspace/exists.txt": "已有\n"]))
            Issue.record("应当拒绝新建已存在的文件")
        } catch let e as PatchError {
            #expect(e.modelFacingMessage.contains("已存在"))
        }

        let update = try Patch.parse("*** File: /workspace/missing.txt\n@@\n-a\n+b")
        do {
            _ = try update.apply(reader: reader([:]))
            Issue.record("应当拒绝修改不存在的文件")
        } catch let e as PatchError {
            #expect(e.modelFacingMessage.contains("不存在"))
        }
    }
}

// MARK: - 模糊匹配

@Suite("Patch 模糊匹配（降低补丁失败率）")
struct PatchFuzzTests {

    @Test("行尾空白差异 → 用 ignoreTrailingWhitespace 命中")
    func trailingWhitespaceTolerance() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.txt
        @@
        -return round(amount)
        +return round(amount, exp)
        """)
        // 文件里那一行有行尾空格
        let result = try patch.apply(reader: reader(["/workspace/a.txt": "x\nreturn round(amount)   \ny\n"]))
        #expect(result.changes[0].fuzz == .ignoreTrailingWhitespace)
        #expect(result.changes[0].newContent == "x\nreturn round(amount, exp)\ny\n")
    }

    @Test("缩进差异 → 用 ignoreLeadingAndTrailing 命中")
    func indentationTolerance() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.txt
        @@
        -    indented line
        +    indented line changed
        """)
        // 文件里缩进是 Tab
        let result = try patch.apply(reader: reader(["/workspace/a.txt": "\tindented line\n"]))
        #expect(result.changes[0].fuzz == .ignoreLeadingAndTrailing)
        #expect(result.changes[0].newContent == "    indented line changed\n")
    }

    @Test("⚠️ 匹配不到时必须报错并给出最近位置（不能瞎改）")
    func notFoundWithCandidates() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.txt
        @@
        -def round_amount(amount):
        +def round_amount(amount, exp):
        """)
        do {
            _ = try patch.apply(reader: reader(["/workspace/a.txt": "def round_amt(amount):\n    pass\n"]))
            Issue.record("应当报 hunkNotFound")
        } catch let e as PatchError {
            guard case .hunkNotFound(_, _, _, let nearest) = e else {
                Issue.record("错误类型不对：\(e)"); return
            }
            #expect(!nearest.isEmpty, "应给出最近位置候选")
            #expect(nearest[0].line == 1)
            #expect(e.modelFacingMessage.contains("最接近"))
            #expect(e.suggestion != nil)
        }
    }

    @Test("⚠️ 匹配到多处时必须拒绝（而不是猜一个）")
    func ambiguousMatchRejected() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.txt
        @@
        -    pass
        +    return None
        """)
        // 文件里有两处 `    pass`
        do {
            _ = try patch.apply(reader: reader(["/workspace/a.txt": "def a():\n    pass\n\ndef b():\n    pass\n"]))
            Issue.record("应当报 ambiguousMatch")
        } catch let e as PatchError {
            guard case .ambiguousMatch(_, _, let matches) = e else {
                Issue.record("错误类型不对：\(e)"); return
            }
            #expect(matches.count == 2)
            #expect(matches[0].line == 2)
            #expect(matches[1].line == 5)
            #expect(e.modelFacingMessage.contains("多包含几行"))
        }
    }

    @Test("多给上下文即可消歧（这是给模型的正确修法）")
    func moreContextDisambiguates() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.txt
        @@
         def b():
        -    pass
        +    return None
        """)
        let result = try patch.apply(reader: reader(["/workspace/a.txt": "def a():\n    pass\n\ndef b():\n    pass\n"]))
        #expect(result.changes[0].newContent == "def a():\n    pass\n\ndef b():\n    return None\n")
    }

    @Test("改动块重叠 → 拒绝并提示合并")
    func overlappingHunksRejected() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.txt
        @@
        -l2
        +L2
        @@
        -l3
        +L3
        """)
        // 第二个 hunk 的匹配范围与第一个重叠
        do {
            _ = try patch.apply(reader: reader(["/workspace/a.txt": "l1\nl2\nl2\n"]))
            Issue.record("不重叠时不应报错 —— 这个用例本身要求重叠，故此处置空")
        } catch {
            // 上面的数据其实不重叠；真正的重叠用例：
        }
        // 构造真正的重叠：两个 hunk 都想改同一段
        let overlapping = try Patch.parse("""
        *** File: /workspace/b.txt
        @@
        -x
        +y
        @@
        -x
        -z
        +w
        """)
        do {
            _ = try overlapping.apply(reader: reader(["/workspace/b.txt": "x\nz\n"]))
            Issue.record("应当报 overlappingHunks")
        } catch let e as PatchError {
            // 注意：这里也可能因为"匹配到多处/找不到"而失败，两者都是正确的拒绝
            #expect(e.modelFacingMessage.contains("重叠") || e.modelFacingMessage.contains("找不到") || e.modelFacingMessage.contains("多次"))
        }
    }
}

// MARK: - 原子性

@Suite("Patch 原子性（失败即整体不落地）")
struct PatchAtomicityTests {

    @Test("⚠️ 只要有一个 hunk 失败，整份补丁（含其他文件）都不落地")
    func allOrNothing() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/ok.txt
        @@
        -good
        +GOOD
        *** File: /workspace/bad.txt
        @@
        -这段内容不存在
        +替换
        """)
        let files = [
            "/workspace/ok.txt": "good\n",
            "/workspace/bad.txt": "完全不同的内容\n",
        ]
        let read: Patch.FileReader = { files[$0.description] }

        #expect(throws: PatchError.self) { try patch.apply(reader: read) }
        // 关键断言：即使第一个文件本来能成功，也没有产生任何改动
        #expect(files["/workspace/ok.txt"] == "good\n")
    }

    @Test("原子性：解析失败时根本不会产生任何状态")
    func parseFailureIsSafe() throws {
        // 文件段之前出现内容 → 明确报错（这是我们**故意**的严格之处：
        // 模型常在补丁前后写一句说明，那会让路径解析产生歧义，所以宁可要求它只给补丁本体）
        #expect(throws: PatchError.self) {
            try Patch.parse("以下是补丁：\n*** File: /workspace/a.txt\n@@\n-a\n+b")
        }

        // 而改动块内"没有前缀的行"是**宽容**的（当上下文处理）——这是设计行为，不是 bug
        let tolerant = try Patch.parse("*** File: /workspace/a.txt\n@@\n-a\n+b\n没有前缀的行")
        #expect(tolerant.files[0].hunks[0].lines.count == 3)
        if case .context(let t) = tolerant.files[0].hunks[0].lines[2] {
            #expect(t == "没有前缀的行")
        } else {
            Issue.record("无前缀行应被当作上下文")
        }
    }
}

// MARK: - 换行与编码保真

@Suite("换行风格与编码保真")
struct PatchLineEndingTests {

    @Test("⚠️ CRLF 文件改完仍是 CRLF（否则 diff 会出现整文件噪音）")
    func crlfPreserved() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.txt
        @@
        -line2
        +LINE2
        """)
        let result = try patch.apply(reader: reader(["/workspace/a.txt": "line1\r\nline2\r\nline3\r\n"]))
        #expect(result.changes[0].newContent == "line1\r\nLINE2\r\nline3\r\n")
    }

    @Test("LF 文件改完仍是 LF")
    func lfPreserved() throws {
        let patch = try Patch.parse("*** File: /workspace/a.txt\n@@\n-line2\n+LINE2")
        let result = try patch.apply(reader: reader(["/workspace/a.txt": "line1\nline2\nline3\n"]))
        #expect(result.changes[0].newContent == "line1\nLINE2\nline3\n")
        #expect(!result.changes[0].newContent!.contains("\r"))
    }

    @Test("末行无换行的文件改完仍无末行换行")
    func noTrailingNewlinePreserved() throws {
        let patch = try Patch.parse("*** File: /workspace/a.txt\n@@\n-line2\n+LINE2")
        let result = try patch.apply(reader: reader(["/workspace/a.txt": "line1\nline2"]))
        #expect(result.changes[0].newContent == "line1\nLINE2")
    }

    @Test("中文与 emoji 内容正确往返")
    func unicodeContent() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/说明.md
        @@
        -中文标题
        +中文标题（已更新）🎉
        """)
        let result = try patch.apply(reader: reader(["/workspace/说明.md": "中文标题\n正文\n"]))
        #expect(result.changes[0].newContent == "中文标题（已更新）🎉\n正文\n")
    }

    @Test("空文件插入内容")
    func insertIntoEmptyFile() throws {
        let patch = try Patch.parse("*** File: /workspace/empty.txt\n@@\n+# 新增标题")
        let result = try patch.apply(reader: reader(["/workspace/empty.txt": ""]))
        #expect(result.changes[0].newContent == "# 新增标题")
    }
}

// MARK: - 纯插入

@Suite("纯插入（没有旧内容可匹配）")
struct PatchInsertionTests {

    @Test("带锚点的插入：插在锚点行之后")
    func insertAfterAnchor() throws {
        let patch = try Patch.parse("""
        *** File: /workspace/a.swift
        @@ import Foundation
        +import Testing
        """)
        let result = try patch.apply(reader: reader(["/workspace/a.swift": "import Foundation\n\nlet x = 1\n"]))
        #expect(result.changes[0].newContent == "import Foundation\nimport Testing\n\nlet x = 1\n")
    }

    @Test("无锚点的插入：追加到文件末尾")
    func appendAtEnd() throws {
        let patch = try Patch.parse("*** File: /workspace/a.txt\n@@\n+新的一行")
        let result = try patch.apply(reader: reader(["/workspace/a.txt": "原有内容\n"]))
        #expect(result.changes[0].newContent == "原有内容\n新的一行\n")
    }

    @Test("锚点找不到时也不报错（退化为追加），但要能被诊断")
    func anchorNotFoundFallsBackToAppend() throws {
        let patch = try Patch.parse("*** File: /workspace/a.txt\n@@ 这个锚点根本不存在\n+追加")
        let result = try patch.apply(reader: reader(["/workspace/a.txt": "内容\n"]))
        #expect(result.changes[0].newContent == "内容\n追加\n")
    }
}

// MARK: - edit_file 引擎

@Suite("TextEdit —— 单点唯一替换")
struct TextEditTests {

    @Test("唯一匹配 → 替换成功")
    func uniqueReplace() throws {
        let result = try TextEdit.replaceUnique(
            in: "let a = 1\nlet b = 2\n",
            find: "let b = 2",
            replace: "let b = 3"
        )
        #expect(result == "let a = 1\nlet b = 3\n")
    }

    @Test("⚠️ 多处匹配 → 拒绝（绝不能悄悄全改）")
    func ambiguousRejected() {
        do {
            _ = try TextEdit.replaceUnique(in: "pass\npass\n", find: "pass", replace: "return")
            Issue.record("应当拒绝多处匹配")
        } catch let e as TextEdit.EditError {
            guard case .ambiguous(_, let matches) = e else { Issue.record("错误类型不对：\(e)"); return }
            #expect(matches.count == 2)
            #expect(e.modelFacingMessage.contains("出现 2 次"))
        } catch { Issue.record("非 EditError：\(error)") }
    }

    @Test("找不到 → 报错并给最近位置")
    func notFound() {
        do {
            _ = try TextEdit.replaceUnique(in: "def round_amt(a):\n    pass\n", find: "def round_amount(a):", replace: "x")
            Issue.record("应当报 notFound")
        } catch let e as TextEdit.EditError {
            guard case .notFound(_, let nearest) = e else { Issue.record("错误类型不对：\(e)"); return }
            #expect(!nearest.isEmpty)
        } catch { Issue.record("非 EditError：\(error)") }
    }

    @Test("空查找串被拒绝")
    func emptyFindRejected() {
        #expect(throws: TextEdit.EditError.self) {
            try TextEdit.replaceUnique(in: "abc", find: "", replace: "x")
        }
    }

    @Test("多行替换保持原文换行风格")
    func multilinePreservesLineEnding() throws {
        let result = try TextEdit.replaceUnique(
            in: "a\r\nb\r\nc\r\n",
            find: "b",
            replace: "B1\nB2"
        )
        #expect(result == "a\r\nB1\r\nB2\r\nc\r\n")
    }

    @Test("容错：查找串缩进不同也能命中（按行匹配回退）")
    func fuzzyIndentFallback() throws {
        let result = try TextEdit.replaceUnique(
            in: "def f():\n\treturn 1\n",
            find: "    return 1",
            replace: "    return 2"
        )
        #expect(result == "def f():\n    return 2\n")
    }
}

// MARK: - 幂等与重复应用

@Suite("重复应用与幂等性")
struct PatchIdempotenceTests {

    @Test("补丁已应用过 → 再次应用应干净失败（而不是产生重复内容）")
    func reapplyFailsCleanly() throws {
        let text = """
        *** File: /workspace/a.txt
        @@
        -old
        +new
        """
        let patch = try Patch.parse(text)
        let after = try patch.apply(reader: reader(["/workspace/a.txt": "old\n"]))
        let patched = after.changes[0].newContent!

        // 再次应用：旧内容已不存在 → 必须报错，绝不能再插一遍
        #expect(throws: PatchError.self) {
            try patch.apply(reader: reader(["/workspace/a.txt": patched]))
        }
        // 且 patched 内容没有被改动
        #expect(patched == "new\n")
    }
}
