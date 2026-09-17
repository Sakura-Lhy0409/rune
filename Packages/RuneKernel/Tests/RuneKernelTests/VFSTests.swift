import Testing
import Foundation
@testable import RuneKernel

// MARK: - VFS 一致性测试
//
// 这一组的关键设计：**同一套断言跑在两个实现上**（内存 / 真实文件系统）。
//
// 为什么值得这么做：VFS 的四条语义（钳制在根内、原子写、换行跟随、写不蕴含删）
// 如果只在内存实现上验证，真实实现里任何一条走样都不会被发现 ——
// 而真实实现才是 App 里跑的那个。反过来，只在真实文件系统上验证的话，
// 那些"沙箱逃逸"的用例很难构造。
//
// 两边都过，才叫"契约成立"。

/// 在临时目录里建一个真实的 FileManagerVFS
func makeTempVFS(normalization: FilenameNormalization = .none) -> (any VFS, () -> Void) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("rune-vfs-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let vfs = FileManagerVFS(baseURL: base, normalization: normalization)
    return (vfs, { try? FileManager.default.removeItem(at: base) })
}

/// 同一套种子数据，喂给两个实现
func seed(_ vfs: any VFS) throws {
    _ = try vfs.write(path("/workspace/src/money.py"),
                      content: "def round_amount(a):\n    return round(a)\n",
                      options: WriteOptions(createParents: true))
    _ = try vfs.write(path("/workspace/src/util.py"), content: "x = 1\n")
    _ = try vfs.write(path("/workspace/tests/test_money.py"), content: "assert True\n")
    _ = try vfs.write(path("/workspace/README.md"), content: "# 项目\n")
}

func path(_ raw: String) -> VFSPath {
    // 测试里写的是 VFS 路径字面量，解析失败就是测试写错了
    guard let p = VFSPath.parseOrNil(raw) else {
        fatalError("测试用了非法路径：\(raw)")
    }
    return p
}

// MARK: - 一致性：两个实现都要过的断言

@Suite("VFS 契约 —— 内存实现")
struct MemoryVFSConformanceTests {
    private func fresh() -> any VFS { MemoryVFS(files: [:], directories: []) }
    private func seeded() throws -> any VFS {
        let vfs = fresh()
        try seed(vfs)
        return vfs
    }

    @Test("读写往返") func readWrite() throws { try assertReadWrite(try seeded()) }
    @Test("列目录") func listing() throws { try assertListing(try seeded()) }
    @Test("文件不存在给候选") func notFound() throws { try assertNotFound(try seeded()) }
    @Test("目录当文件读会被拒") func notAFile() throws { try assertNotAFile(try seeded()) }
    @Test("按行读取") func ranges() throws { try assertLineRanges(try seeded()) }
    @Test("⭐ 换行风格跟随原文件") func newline() throws { try assertNewlineFidelity(try seeded()) }
    @Test("⭐ 写不蕴含删") func writeIsNotDelete() throws { try assertWriteDoesNotDelete(try seeded()) }
    @Test("唯一替换") func editUnique() throws { try assertUniqueReplace(try seeded()) }
    @Test("删除默认进回收站") func trash() throws { try assertTrashByDefault(try seeded()) }
    @Test("永久删除需要显式要求") func permanent() throws { try assertPermanentDelete(try seeded()) }
    @Test("空目录不递归不能删") func notEmpty() throws { try assertNonEmptyDirectoryGuard(try seeded()) }
    @Test("移动与复制") func moveCopy() throws { try assertMoveAndCopy(try seeded()) }
    @Test("建目录幂等") func makeDir() throws { try assertMakeDirectory(try seeded()) }
    @Test("快照与回滚") func snapshot() throws { try assertSnapshotRestore(try seeded()) }
    @Test("二进制被拒") func binary() throws { let vfs = fresh(); _ = try vfs.write(path("/workspace/a.bin"), content: "a\u{0}b"); try assertBinaryRejected(vfs) }
    @Test("越出挂载点被拒") func outside() throws { try assertOutsideRootRejected(try seeded()) }
    @Test("空文件") func empty() throws { try assertEmptyFile(fresh()) }
}

@Suite("VFS 契约 —— 真实文件系统实现")
struct FileManagerVFSConformanceTests {
    private func fresh() -> any VFS { makeTempVFS().0 }
    private func seeded() throws -> any VFS {
        let (vfs, _) = makeTempVFS()
        try seed(vfs)
        return vfs
    }

    @Test("读写往返") func readWrite() throws { try assertReadWrite(try seeded()) }
    @Test("列目录") func listing() throws { try assertListing(try seeded()) }
    @Test("文件不存在给候选") func notFound() throws { try assertNotFound(try seeded()) }
    @Test("目录当文件读会被拒") func notAFile() throws { try assertNotAFile(try seeded()) }
    @Test("按行读取") func ranges() throws { try assertLineRanges(try seeded()) }
    @Test("⭐ 换行风格跟随原文件") func newline() throws { try assertNewlineFidelity(try seeded()) }
    @Test("⭐ 写不蕴含删") func writeIsNotDelete() throws { try assertWriteDoesNotDelete(try seeded()) }
    @Test("唯一替换") func editUnique() throws { try assertUniqueReplace(try seeded()) }
    @Test("删除默认进回收站") func trash() throws { try assertTrashByDefault(try seeded()) }
    @Test("永久删除需要显式要求") func permanent() throws { try assertPermanentDelete(try seeded()) }
    @Test("空目录不递归不能删") func notEmpty() throws { try assertNonEmptyDirectoryGuard(try seeded()) }
    @Test("移动与复制") func moveCopy() throws { try assertMoveAndCopy(try seeded()) }
    @Test("建目录幂等") func makeDir() throws { try assertMakeDirectory(try seeded()) }
    @Test("快照与回滚") func snapshot() throws { try assertSnapshotRestore(try seeded()) }
    @Test("二进制被拒") func binary() throws { let vfs = fresh(); _ = try vfs.write(path("/workspace/a.bin"), content: "a\u{0}b"); try assertBinaryRejected(vfs) }
    @Test("越出挂载点被拒") func outside() throws { try assertOutsideRootRejected(try seeded()) }
    @Test("空文件") func empty() throws { try assertEmptyFile(fresh()) }
}

// MARK: - 共用断言（两个 suite 共用同一份实现）

func assertReadWrite(_ vfs: any VFS) throws {
    let content = try vfs.read(path("/workspace/src/money.py"))
    #expect(content.text.contains("round_amount"))
    #expect(content.totalLines == 2)   // 末尾换行不算一行（LineTable 的语义）
    #expect(!content.wasTruncated)

    // 覆盖写
    let report = try vfs.write(path("/workspace/src/money.py"), content: "全改了\n")
    #expect(report.wasCreated == false)
    let rewritten = try vfs.read(path("/workspace/src/money.py")).text
    #expect(rewritten == "全改了\n", "实际读到的是：\(rewritten.debugDescription)")

    // 新建
    let created = try vfs.write(path("/workspace/new.txt"), content: "新文件")
    #expect(created.wasCreated == true)
    #expect(try vfs.exists(path("/workspace/new.txt")))
}

func assertListing(_ vfs: any VFS) throws {
    let top = try vfs.list(path("/workspace"), options: ListOptions())
    let names = Set(top.map(\.name))
    #expect(names.contains("src"))
    #expect(names.contains("tests"))
    #expect(names.contains("README.md"))
    #expect(top.first { $0.name == "src" }?.kind == .directory)

    // 递归
    let all = try vfs.list(path("/workspace"), options: ListOptions(recursive: true, maxDepth: 8))
    let paths = all.map(\.path.description)
    #expect(paths.contains("/workspace/src/money.py"))
    #expect(paths.contains("/workspace/tests/test_money.py"))

    // 非递归时不含深层文件
    #expect(!top.contains { $0.path.description == "/workspace/src/money.py" })

    // 上限生效
    let limited = try vfs.list(path("/workspace"), options: ListOptions(recursive: true, maxDepth: 8, limit: 2))
    #expect(limited.count <= 2)

    // 列表必须确定性（同一批内容两次列出顺序一致）
    let again = try vfs.list(path("/workspace"), options: ListOptions(recursive: true, maxDepth: 8))
    #expect(all.map(\.path.description) == again.map(\.path.description))
}

func assertNotFound(_ vfs: any VFS) throws {
    do {
        _ = try vfs.read(path("/workspace/src/monye.py"))   // 故意拼错
        Issue.record("读了不存在的文件却没有报错")
    } catch let failure as VFSFailure {
        #expect(failure.kind == .notFound)
        // ⚠️ 候选必须给出来（模型靠它自己改对），且要包含拼对的那个
        #expect(failure.candidates.contains { $0.hasSuffix("money.py") },
                "候选里应当有相近的真实路径，实际：\(failure.candidates)")
        #expect(failure.isSelfCorrectable)
        #expect(failure.modelFacingText.contains("候选"))
    }
}

func assertNotAFile(_ vfs: any VFS) throws {
    do {
        _ = try vfs.read(path("/workspace/src"))
        Issue.record("把目录当文件读却没有报错")
    } catch let failure as VFSFailure {
        #expect(failure.kind == .notAFile)
        // 这个错误模型改不了（路径就是目录），不该让它重试
        #expect(!failure.isSelfCorrectable)
    }
}

func assertLineRanges(_ vfs: any VFS) throws {
    _ = try vfs.write(path("/workspace/lines.txt"),
                      content: (1...20).map { "第 \($0) 行" }.joined(separator: "\n"))

    let head = try vfs.read(path("/workspace/lines.txt"), options: ReadOptions(startLine: 1, endLine: 3))
    #expect(head.text.components(separatedBy: "\n").count == 3)
    #expect(head.returnedLines == 1...3)
    #expect(head.totalLines == 20)      // ⚠️ 只取一段也必须给出总行数

    let middle = try vfs.read(path("/workspace/lines.txt"), options: ReadOptions(startLine: 5, endLine: 7))
    #expect(middle.text.contains("第 5 行"))
    #expect(!middle.text.contains("第 4 行"))

    let tail = try vfs.read(path("/workspace/lines.txt"), options: ReadOptions(tailLines: 2))
    #expect(tail.text.contains("第 20 行"))
    #expect(tail.text.contains("第 19 行"))
    #expect(!tail.text.contains("第 18 行"))
    #expect(tail.returnedLines == 19...20)

    // ⚠️ 行号必须对应**文件里的真实行号**（模型要拿它去打补丁）
    let numbered = middle.numberedText
    #expect(numbered.contains("5│第 5 行"), "行号应当从 5 开始：\(numbered)")
}

func assertNewlineFidelity(_ vfs: any VFS) throws {
    // 造一个 CRLF 文件
    _ = try vfs.write(path("/workspace/crlf.txt"), content: "第一行\r\n第二行\r\n",
                      options: WriteOptions(newlineStyle: .crlf))
    let before = try vfs.read(path("/workspace/crlf.txt"))
    #expect(before.newline == "\r\n", "读出来应当如实报告 CRLF")

    // ⚠️ 写回时默认 `.preserve`：不跟随的话，CRLF 文件会被整篇改写成 LF，
    //    diff 里出现"整个文件都变了"的噪音（T9）
    _ = try vfs.write(path("/workspace/crlf.txt"), content: "第一行\n改过的第二行\n")
    let after = try vfs.read(path("/workspace/crlf.txt"))
    #expect(after.newline == "\r\n", "写回后应当仍是 CRLF")
    #expect(!after.text.contains("\r\n\r\n"))
}

func assertWriteDoesNotDelete(_ vfs: any VFS) throws {
    // ⚠️ 这是 docs/05 §4.2 的硬语义：写一个文件绝不允许顺手清掉别的路径
    let before = try vfs.list(path("/workspace"), options: ListOptions(recursive: true, maxDepth: 8))
        .map(\.path.description).sorted()

    _ = try vfs.write(path("/workspace/src/money.py"), content: "改过了\n")

    let after = try vfs.list(path("/workspace"), options: ListOptions(recursive: true, maxDepth: 8))
        .map(\.path.description).sorted()
    #expect(after == before, "写文件改变了文件清单：\(Set(after).symmetricDifference(before))")
    #expect(try vfs.exists(path("/workspace/src/util.py")))
    #expect(try vfs.exists(path("/workspace/README.md")))
}

func assertUniqueReplace(_ vfs: any VFS) throws {
    let edit = try TextEdit.replaceUnique(
        in: try vfs.read(path("/workspace/src/money.py")).text,
        find: "round(a)", replace: "round(a, 2)"
    )
    _ = try vfs.write(path("/workspace/src/money.py"), content: edit)
    #expect(try vfs.read(path("/workspace/src/money.py")).text.contains("round(a, 2)"))

    // ⚠️ 匹配多处必须拒绝（绝不悄悄全改）
    _ = try vfs.write(path("/workspace/dup.txt"), content: "x\nx\n")
    do {
        _ = try TextEdit.replaceUnique(in: try vfs.read(path("/workspace/dup.txt")).text, find: "x", replace: "y")
        Issue.record("匹配多处却没有报错")
    } catch {
        // 预期
    }
}

func assertTrashByDefault(_ vfs: any VFS) throws {
    let report = try vfs.delete(path("/workspace/README.md"), options: DeleteOptions())
    #expect(report.movedToTrash, "默认删除必须进回收站（手机上真删是不可逆的）")
    #expect(!(try vfs.exists(path("/workspace/README.md"))))
    // 回收站里能找到它
    #expect(report.trashPath != nil)
    let trashed = try vfs.list(path("/workspace/.rune/trash"), options: ListOptions(includeHidden: true))
    #expect(!trashed.isEmpty, "回收站里应当能列到刚删掉的东西")
}

func assertPermanentDelete(_ vfs: any VFS) throws {
    let report = try vfs.delete(path("/workspace/README.md"), options: DeleteOptions(permanent: true))
    #expect(!report.movedToTrash)
    #expect(!(try vfs.exists(path("/workspace/README.md"))))

    // 其它文件一个都不能少
    #expect(try vfs.exists(path("/workspace/src/money.py")))
}

func assertNonEmptyDirectoryGuard(_ vfs: any VFS) throws {
    do {
        _ = try vfs.delete(path("/workspace/src"), options: DeleteOptions(permanent: true, recursive: false))
        Issue.record("删非空目录却没有报错")
    } catch let failure as VFSFailure {
        #expect(failure.kind == .notEmpty)
        // 提示要能指导模型（明确要求递归）
        #expect(failure.detail.contains("递归"))
    }
    // 递归删除要成功
    let report = try vfs.delete(path("/workspace/src"), options: DeleteOptions(permanent: true, recursive: true))
    #expect(!report.movedToTrash)
    #expect(!(try vfs.exists(path("/workspace/src/money.py"))))
    #expect(try vfs.exists(path("/workspace/README.md")))
}

func assertMoveAndCopy(_ vfs: any VFS) throws {
    try vfs.move(path("/workspace/README.md"), to: path("/workspace/docs/README.md"), overwrite: false)
    #expect(!(try vfs.exists(path("/workspace/README.md"))))
    #expect(try vfs.read(path("/workspace/docs/README.md")).text.contains("项目"))

    try vfs.copy(path("/workspace/docs/README.md"), to: path("/workspace/docs/README.bak"), overwrite: false)
    #expect(try vfs.read(path("/workspace/docs/README.bak")).text.contains("项目"))
    // 原件还在
    #expect(try vfs.exists(path("/workspace/docs/README.md")))

    // ⚠️ 目标已存在时必须拒绝（不覆盖别人的东西）
    do {
        try vfs.copy(path("/workspace/docs/README.md"), to: path("/workspace/docs/README.bak"), overwrite: false)
        Issue.record("覆盖了已存在的文件却没有报错")
    } catch let failure as VFSFailure {
        #expect(failure.kind == .alreadyExists)
        #expect(failure.detail.contains("覆盖"))
    }
}

func assertMakeDirectory(_ vfs: any VFS) throws {
    try vfs.makeDirectory(path("/workspace/a/b/c"), intermediates: true)
    #expect(try vfs.stat(path("/workspace/a/b/c")).isDirectory)
    // 幂等
    try vfs.makeDirectory(path("/workspace/a/b/c"), intermediates: true)

    // 不建中间层时父目录必须存在
    do {
        try vfs.makeDirectory(path("/workspace/nope/deep"), intermediates: false)
        Issue.record("父目录不存在却没有报错")
    } catch let failure as VFSFailure {
        #expect(failure.kind == .parentMissing)
    }
}

func assertSnapshotRestore(_ vfs: any VFS) throws {
    let snapshot = try vfs.snapshot(label: "重构前", now: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(snapshot.fileCount >= 4)
    let originalReadme = try vfs.read(path("/workspace/README.md")).text

    // 搞破坏
    _ = try vfs.write(path("/workspace/README.md"), content: "被改坏了\n")
    _ = try vfs.write(path("/workspace/新文件.txt"), content: "不该存在")
    #expect(try vfs.exists(path("/workspace/新文件.txt")))

    try vfs.restore(snapshot)
    #expect(try vfs.read(path("/workspace/README.md")).text == originalReadme, "回滚后原内容应当恢复")
}

func assertBinaryRejected(_ vfs: any VFS) throws {
    do {
        _ = try vfs.read(path("/workspace/a.bin"))
        Issue.record("读了二进制文件却没有报错")
    } catch let failure as VFSFailure {
        #expect(failure.kind == .isBinary)
        // ⚠️ 提示要给出正确的替代做法，而不是只说"不行"
        #expect(failure.detail.contains("ocr_image") || failure.detail.contains("read_pdf"))
        #expect(!failure.isSelfCorrectable)
    }
    // 显式允许时能读
    let allowed = try vfs.read(path("/workspace/a.bin"), options: ReadOptions(allowBinary: true))
    #expect(allowed.text.contains("a"))
}

func assertOutsideRootRejected(_ vfs: any VFS) throws {
    // `..` 在 VFSPath 层就被拒绝了（构造不出这样的路径）
    #expect(VFSPath.parseOrNil("/workspace/../etc/passwd") == nil)

    // 换个挂载点也要被拒
    if let other = VFSPath.parseOrNil("/sandbox/x") {
        do {
            _ = try vfs.read(other)
            Issue.record("读了别的挂载点却没有报错")
        } catch let failure as VFSFailure {
            #expect(failure.kind == .outsideRoot || failure.kind == .notFound)
        }
    }
}

func assertEmptyFile(_ vfs: any VFS) throws {
    _ = try vfs.write(path("/workspace/empty.txt"), content: "")
    let content = try vfs.read(path("/workspace/empty.txt"))
    #expect(content.text.isEmpty)
    #expect(content.totalLines == 0)
    #expect(content.returnedLines == nil)
}

// MARK: - 只属于真实文件系统的安全测试

@Suite("FileManagerVFS —— 沙箱边界")

struct FileManagerVFSSecurityTests {

    @Test("⭐ 符号链接指向根目录之外 → 必须拒绝（沙箱逃逸）")
    func symlinkEscapeRejected() throws {
        let (vfs, cleanup) = makeTempVFS()
        defer { cleanup() }

        let fm = FileManager.default
        let baseURL = (vfs as! FileManagerVFS).baseURL

        // 建一个外面的目录与文件
        let outside = fm.temporaryDirectory.appendingPathComponent("rune-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try "机密内容".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        // 在工作区里建一个指向外面的符号链接
        let link = baseURL.appendingPathComponent("escape")
        let created = (try? fm.createSymbolicLink(at: link, withDestinationURL: outside)) != nil
        guard created else {
            // Windows 上创建符号链接需要开发者模式或管理员权限 —— 跳过而不是假装通过
            return
        }

        // 通过链接去读外面的文件：必须在符号链接解析阶段被拦住
        do {
            _ = try vfs.read(path("/workspace/escape/secret.txt"))
            Issue.record("⚠️ 通过符号链接读到了工作区之外的文件 —— 沙箱被架空")
        } catch let failure as VFSFailure {
            #expect(failure.kind == .symlinkEscape || failure.kind == .notFound || failure.kind == .outsideRoot,
                    "实际：\(failure.kind) —— \(failure.detail)")
        }
    }

    @Test("符号链接本身要被报告为链接，而不是被当普通文件跟随")
    func symlinkReportedAsLink() throws {
        let (vfs, cleanup) = makeTempVFS()
        defer { cleanup() }
        try seed(vfs)
        let fm = FileManager.default
        let baseURL = (vfs as! FileManagerVFS).baseURL
        let link = baseURL.appendingPathComponent("src/link.py")
        guard (try? fm.createSymbolicLink(at: link, withDestinationURL: baseURL.appendingPathComponent("src/money.py"))) != nil else {
            return   // 平台不支持建链接 → 跳过
        }
        let listing = try vfs.list(path("/workspace/src"), options: ListOptions())
        #expect(listing.first { $0.name == "link.py" }?.kind == .symlink)
    }
}

// MARK: - 文件名比较（含一个被测试纠正过来的误判）

/// 这个平台上的 Foundation 是否真的实现了 Unicode 规范化分解。
///
/// ⚠️ 不能拿 `==` 去判断 —— Swift 的字符串相等是规范等价的，"café" 与它的分解形式
///    永远相等。要看**字节数**：NFC 是 5 字节，NFD 是 6 字节。
var platformSupportsDecomposition: Bool {
    "café".decomposedStringWithCanonicalMapping.utf8.count
        != "café".precomposedStringWithCanonicalMapping.utf8.count
}

@Suite("文件名比较 —— iOS 上真正会咬人的是「大小写不敏感」")

struct FilenameComparisonTests {

    // ⚠️ 这一组测试的来历值得记一下：
    //
    // 我一开始的假设是"iOS 上文件名会因 NFC/NFD 不一致而读不到"，并据此写了断言。
    // 结果 `#expect(nfc != nfd)` **直接挂了** —— 因为 Swift 的 `String ==` 本身就是
    // 按 Unicode 规范等价比较的。顺着查下去还发现 APFS 也是规范化不敏感的。
    // **也就是说那个"坑"在 Swift + APFS 上基本不存在。**
    //
    // 下面保留了对规范化的断言（它仍然有价值：跨语言、跨文件系统时要确定字节形式），
    // 但把重点放在**真正会咬人的那条**上：大小写不敏感。

    @Test("⭐ Swift 的字符串相等本身就是规范等价的（所以去重天生没问题）")
    func swiftEqualityIsCanonicallyAware() {
        let nfc = "café"
        let nfd = "cafe\u{0301}"
        #expect(nfc == nfd, "Swift 按规范等价比较 —— 这条成立的话，Set<String> 去重就不需要额外处理")
        #expect(Set([nfc, nfd]).count == 1)
    }

    @Test("canonical 在两种风格下都幂等（写进 JSON / SQLite 时要确定字节形式）")
    func canonicalIsStable() {
        let name = "café"
        #expect(FilenameNormalization.normalizationInsensitive.canonical(name)
                == FilenameNormalization.normalizationInsensitive.canonical(
                    FilenameNormalization.normalizationInsensitive.canonical(name)))
        #expect(FilenameNormalization.none.canonical(name) == name)
    }

    @Test("查找形式：不做规范化只试一种；规范化不敏感时列出**字节不同**的几种")
    func lookupForms() {
        #expect(FilenameNormalization.none.lookupForms("café.txt") == ["café.txt"])

        let forms = FilenameNormalization.normalizationInsensitive.lookupForms("café.txt")
        #expect(forms.first == "café.txt")

        if platformSupportsDecomposition {
            // ⭐ 关键断言：**按字节**必须列出两种形式。
            //
            //    这里曾经写成"只断言 forms.first"，于是漏掉了一个真 bug：
            //    去重用的 `forms.contains(decomposed)` 因为 Swift 的规范等价比较**永远为真**，
            //    分解形式永远加不进来 —— 兜底逻辑从来没生效过，而测试还是绿的。
            //
            //    ⚠️ 用**显式码位**构造两种形式，不要指望源文件里那个字面量是什么形式：
            //    编辑器/工具链可能把它存成任何一种，而两者的字节长度只差 1。
            let composed = "caf\u{00E9}.txt"        // é 单码位（NFC）
            let decomposed = "cafe\u{0301}.txt"     // e + 组合重音（NFD）
            #expect(composed.utf8.count != decomposed.utf8.count, "前提：NFC 5 字节、NFD 6 字节")

            let listed = FilenameNormalization.normalizationInsensitive.lookupForms(composed)
            let listedBytes = Set(listed.map { Array($0.utf8) })
            #expect(listedBytes.count == 2, "应当列出两种字节形式，实际 \(listedBytes.count) 种")
            #expect(listed.contains { Array($0.utf8) == Array(decomposed.utf8) }, "必须包含分解形式 —— 这正是那个 bug 漏掉的")
        }
    }

    @Test("⭐ 大小写不敏感时，两个只有大小写不同的名字是**同一个文件**")
    func caseInsensitiveCollision() {
        let insensitive = FilenameComparison.caseInsensitive
        #expect(insensitive.matches("README.md", "readme.md"))
        #expect(!FilenameComparison.caseSensitive.matches("README.md", "readme.md"))
    }

    @Test("⭐ 「新建」可能是「覆盖」：必须能找出只有大小写不同的既有文件")
    func detectsCollidingEntry() {
        let existing = ["readme.md", "src", "CHANGELOG.md"]
        // iOS（大小写不敏感）：模型要新建 README.md，磁盘上已有 readme.md → 这是覆盖！
        #expect(FilenameComparison.caseInsensitive.collidingEntry(named: "README.md", among: existing) == "readme.md")
        // Windows/Linux：不冲突，真的是新建
        #expect(FilenameComparison.caseSensitive.collidingEntry(named: "README.md", among: existing) == nil)
        // 完全同名的情况两边都能找到
        #expect(FilenameComparison.caseSensitive.collidingEntry(named: "CHANGELOG.md", among: existing) == "CHANGELOG.md")
    }

    @Test("大小写不敏感时目录里不会同时存在两个只差大小写的文件")
    func noCoexistingCaseVariants() {
        // 这条是上面那条的推论：如果磁盘上真有两个，说明它是大小写**敏感**的卷
        // （外接盘、或者开发者手动改过格式）—— 那时代码必须能处理，不能假设只有一个。
        let existing = ["a.txt", "A.txt"]
        let collision = FilenameComparison.caseInsensitive.collidingEntry(named: "a.txt", among: existing)
        #expect(collision != nil)
    }
}

@Suite("文件名规范化 —— 磁盘上是 NFD、给的是 NFC 时仍能读到")

struct FilenameNormalizationTests {


    @Test("⚠️ 规范化不敏感的文件系统上，两种写法都能读到同一个文件")
    func readsDespiteNormalizationMismatch() throws {
        // 某些 corelibs-foundation（Windows）没有实现规范化分解 → 兜底能力不存在。
        // 这不算失败，只是那条纵深防御在这个平台上不起作用；**如实跳过，而不是假装通过**。
        guard platformSupportsDecomposition else { return }

        let (vfs, cleanup) = makeTempVFS(normalization: .normalizationInsensitive)
        defer { cleanup() }

        let nfdName = "cafe\u{0301}.txt"     // 磁盘上的形式（分解）
        let nfcName = "caf\u{00E9}.txt"      // 模型给的形式（合成）
        _ = try vfs.write(path("/workspace/\(nfdName)"), content: "内容")

        // 两种写法都要能读到（靠 lookupForms 兜底；Apple 平台上文件系统自己也会兜）
        #expect(try vfs.read(path("/workspace/\(nfcName)")).text == "内容")
        #expect(try vfs.read(path("/workspace/\(nfdName)")).text == "内容")
    }

    @Test("中文文件名同样处理")
    func chineseNames() throws {
        let (vfs, cleanup) = makeTempVFS(normalization: .normalizationInsensitive)
        defer { cleanup() }
        _ = try vfs.write(path("/workspace/报告.txt"), content: "数据")
        #expect(try vfs.read(path("/workspace/报告.txt")).text == "数据")
    }
}
// MARK: - 与上层模块的接口

@Suite("VFS × 其他模块 —— 它得能接上")

struct VFSIntegrationTests {

    @Test("⭐ 补丁引擎可以直接跑在 VFS 上（apply_patch 的实现路径）")
    func patchAppliesThroughVFS() throws {
        let (vfs, cleanup) = makeTempVFS()
        defer { cleanup() }
        try seed(vfs)

        let patchText = """
        *** File: src/money.py
        @@
        -    return round(a)
        +    return round(a, 2)
        """
        let patch = try Patch.parse(patchText)
        // ⚠️ `Patch.apply(reader:)` 拿到的已经是**绝对 VFS 路径**（`VFSPath`），
        //    所以直接用，不要再拼前缀；闭包是**非抛出**的，所以用 `try?`。
        let applied = try patch.apply { absolute in (try? vfs.read(absolute))?.text }
        let change = try #require(applied.changes.first)
        let newContent = try #require(change.newContent)

        let report = try vfs.write(path("/workspace/src/money.py"), content: newContent)
        #expect(report.wasCreated == false)
        #expect(try vfs.read(path("/workspace/src/money.py")).text.contains("round(a, 2)"))
        #expect(applied.isCleanMatch)
    }

    @Test("⚠️ 幂等重做：补丁已应用过时不能再改一遍（虚拟机的重试逻辑靠它）")
    func patchIsIdempotentThroughVFS() throws {
        let (vfs, cleanup) = makeTempVFS()
        defer { cleanup() }
        try seed(vfs)

        let patch = try Patch.parse("*** File: src/money.py\n@@\n-    return round(a)\n+    return round(a, 2)")
        // 第一次
        let first = try patch.apply { absolute in (try? vfs.read(absolute))?.text }
        _ = try vfs.write(path("/workspace/src/money.py"), content: try #require(first.changes.first?.newContent))

        // 第二次（模拟崩溃后的重做）：源码里已经没有旧内容了
        do {
            _ = try patch.apply { absolute in (try? vfs.read(absolute))?.text }
            Issue.record("重做时找不到旧内容却没有报错 —— 那会让恢复流程误判失败")
        } catch let error as PatchError {
            // 预期：找不到锚点。真实实现要先检查"目标状态是否已达成"再决定报错
            #expect(error.modelFacingMessage.contains("找不到") || error.modelFacingMessage.contains("匹配"))
        }
    }

    @Test("检索与 VFS 对上：列出来的路径能被读回")
    func listingPathsAreReadable() throws {
        let (vfs, cleanup) = makeTempVFS()
        defer { cleanup() }
        try seed(vfs)

        let entries = try vfs.list(path("/workspace"), options: ListOptions(recursive: true, maxDepth: 8))
        for entry in entries where entry.kind == .file {
            #expect(throws: Never.self) { _ = try vfs.read(entry.path) }
        }
    }

    @Test("⭐ 工具注册表声明的路径参数，提取出来的路径能直接在 VFS 上解析")
    func registryPathsResolveOnVFS() throws {
        let (vfs, cleanup) = makeTempVFS()
        defer { cleanup() }
        try seed(vfs)

        let call = ToolCall(id: "c1", name: ToolName.readFile,
                            argumentsJSON: Data(#"{"path": "src/money.py"}"#.utf8))
        let spec = try #require(ToolRegistry.byName[ToolName.readFile])
        let extraction = CallPaths.extract(from: call, spec: spec)
        let extracted = try #require(extraction.paths.first)

        // 策略引擎判定的路径 == VFS 实际操作的路径（**不能是两条路**）
        #expect(try vfs.stat(extracted).kind == .file)
        #expect(try vfs.read(extracted).text.contains("round_amount"))
    }
}








