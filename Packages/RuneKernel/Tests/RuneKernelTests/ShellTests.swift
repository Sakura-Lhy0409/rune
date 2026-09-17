import Testing
import Foundation
@testable import RuneKernel

// MARK: - 自研 shell 的测试
//
// 这一组守的东西很具体：**模型一定会写出我们不支持的语法**。
// 那时代码不能只是"失败"，而要给出**可执行的替代** ——
// 否则它只会换个写法再试一次，来回烧 token，最后还是不行。

private func parse(_ command: String) -> ShellScript? {
    switch ShellParser.parse(command) {
    case .success(let script): return script
    case .failure: return nil
    }
}

private func parseError(_ command: String) -> ShellParseError? {
    switch ShellParser.parse(command) {
    case .success: return nil
    case .failure(let error): return error
    }
}

// MARK: - 分词与语法

@Suite("ShellParser —— 词法（引号与转义）")

struct ShellTokenizerTests {

    @Test("简单命令")
    func simpleCommand() throws {
        let script = try #require(parse("git status --short"))
        #expect(script.pipelines.count == 1)
        let command = try #require(script.pipelines[0].commands.first)
        #expect(command.executable == "git")
        #expect(command.arguments == ["status", "--short"])
    }

    @Test("⭐ 单引号内一切都是字面（包括空格与双引号）")
    func singleQuotesAreLiteral() throws {
        let script = try #require(parse(#"echo '你好 世界 "带引号"' "#))
        let command = try #require(script.pipelines[0].commands.first)
        #expect(command.arguments == [#"你好 世界 "带引号""#])
    }

    @Test("⭐ 单引号里不能转义（POSIX 语义：`'\''` 才是插入单引号的办法）")
    func singleQuoteCannotBeEscaped() throws {
        let script = try #require(parse(#"echo 'a\'"#))
        let command = try #require(script.pipelines[0].commands.first)
        // 反斜杠是字面量，引号在 `\` 之后就闭合了 → 参数是 `a\`
        #expect(command.arguments == [#"a\"#])
    }

    @Test("双引号里 \\\" 与 \\\\ 是转义，其余反斜杠保留")
    func doubleQuoteEscapes() throws {
        let script = try #require(parse(#"echo "a\"b\\c\d""#))
        let command = try #require(script.pipelines[0].commands.first)
        #expect(command.arguments == [#"a"b\c\d"#])
    }

    @Test("引号外的反斜杠转义空格")
    func backslashEscapesSpace() throws {
        let script = try #require(parse(#"cat my\ file.txt"#))
        let command = try #require(script.pipelines[0].commands.first)
        #expect(command.arguments == ["my file.txt"])
    }

    @Test("空引号会产生一个空参数，而不是被丢掉")
    func emptyQuotesProduceEmptyArgument() throws {
        let script = try #require(parse(#"echo "" ''"#))
        let command = try #require(script.pipelines[0].commands.first)
        #expect(command.arguments == ["", ""])
    }

    @Test("⚠️ 引号没闭合要明确报错，并说清怎么补")
    func unterminatedQuote() throws {
        let error = try #require(parseError("echo '没闭合"))
        #expect(error.kind == .unterminatedQuote)
        #expect(error.suggestion?.contains("'") == true)
    }

    @Test("`#` 只在词首才是注释（`a#b` 里的井号是普通字符）")
    func hashIsCommentOnlyAtWordStart() throws {
        let withComment = try #require(parse("ls -la # 这是注释"))
        #expect(withComment.pipelines[0].commands[0].arguments == ["-la"])

        let asLiteral = try #require(parse("echo a#b"))
        #expect(asLiteral.pipelines[0].commands[0].arguments == ["a#b"])
    }

    @Test("中文参数（手机上很常见）")
    func chineseArguments() throws {
        let script = try #require(parse("grep -n 退款 src/money.py"))
        #expect(script.pipelines[0].commands[0].arguments == ["-n", "退款", "src/money.py"])
    }
}

@Suite("ShellParser —— 管道 / 连接符 / 重定向")

struct ShellGrammarTests {

    @Test("管道")
    func pipeline() throws {
        let script = try #require(parse("git log --oneline | head -20"))
        #expect(script.pipelines.count == 1)
        #expect(script.pipelines[0].commands.map(\.executable) == ["git", "head"])
    }

    @Test("三段管道")
    func longPipeline() throws {
        let script = try #require(parse("cat a.txt | grep x | wc -l"))
        #expect(script.pipelines[0].commands.map(\.executable) == ["cat", "grep", "wc"])
    }

    @Test("操作符不需要空格")
    func operatorsWithoutSpaces() throws {
        let script = try #require(parse("cat a|grep x|wc -l"))
        #expect(script.pipelines[0].commands.map(\.executable) == ["cat", "grep", "wc"])

        let redirect = try #require(parse("ls>out.txt"))
        #expect(redirect.pipelines[0].commands[0].redirections.first?.target == "out.txt")
    }

    @Test("⭐ 短路连接符：`&&` 与 `||` 会被解析成不同的分隔符")
    func separators() throws {
        let script = try #require(parse("make && ./run || echo 失败"))
        #expect(script.pipelines.count == 3)
        #expect(script.separators == [.and, .or])
    }

    @Test("`;` 无条件继续")
    func semicolon() throws {
        let script = try #require(parse("cd a ; ls ; pwd"))
        #expect(script.pipelines.count == 3)
        #expect(script.separators == [.always, .always])
    }

    @Test("重定向：> >> 2> 2>> &> <")
    func redirections() throws {
        let script = try #require(parse("run > out.txt 2> err.txt < in.txt"))
        let kinds = script.pipelines[0].commands[0].redirections.map(\.kind)
        #expect(kinds == [.stdout, .stderr, .stdin])

        let append = try #require(parse("run >> log.txt 2>> err.txt &> all.txt"))
        #expect(append.pipelines[0].commands[0].redirections.map(\.kind)
                == [.stdoutAppend, .stderrAppend, .stdoutAndStderr])
    }

    @Test("重定向只作用于它所在的那条命令")
    func redirectionIsPerCommand() throws {
        let script = try #require(parse("cat a | grep x > hits.txt | wc -l"))
        #expect(script.pipelines[0].commands[0].redirections.isEmpty)
        #expect(script.pipelines[0].commands[1].redirections.count == 1)
        #expect(script.pipelines[0].commands[2].redirections.isEmpty)
    }

    @Test("重定向缺目标要明确报错")
    func redirectionWithoutTarget() throws {
        let error = try #require(parseError("ls >"))
        #expect(error.kind == .redirectionWithoutTarget)
        #expect(error.suggestion?.contains("目标路径") == true)
    }

    @Test("重定向出现在命令名之前要报错")
    func redirectionBeforeCommand() throws {
        #expect(try #require(parseError("> out.txt ls")).kind == .unexpectedToken)
    }

    @Test("管道开头 / 连接符开头 / 结尾连接符都要报错")
    func danglingOperators() throws {
        #expect(try #require(parseError("| ls")).kind == .unexpectedToken)
        #expect(try #require(parseError("&& ls")).kind == .unexpectedToken)
        #expect(try #require(parseError("ls &&")).kind == .trailingOperator)
        #expect(try #require(parseError("ls ||")).kind == .trailingOperator)
    }

    @Test("空命令要报错")
    func emptyCommand() throws {
        #expect(try #require(parseError("   ")).kind == .empty)
    }

    @Test("命令回显会把带空格的参数加引号（审计要能看清）")
    func displayString() throws {
        let script = try #require(parse(#"grep "hello world" a.txt > out.txt"#))
        let display = script.pipelines[0].commands[0].displayString
        #expect(display.contains("'hello world'"))
        #expect(display.contains("> out.txt"))
    }
}

// MARK: - 不支持的语法：给替代做法

@Suite("ShellParser —— 不支持的语法必须给可执行的替代")

struct ShellUnsupportedTests {

    private func check(_ command: String, expectKind: ShellParseError.Kind = .unsupported,
                       expectToken: String, expectSuggestion: String) throws {
        let error = try #require(parseError(command), "「\(command)」本应被拒绝")
        #expect(error.kind == expectKind, "「\(command)」的错误类型不对：\(error.kind)")
        #expect(error.token.contains(expectToken), "「\(command)」应指向 `\(expectToken)`，实际 `\(error.token)`")
        #expect(error.suggestion?.contains(expectSuggestion) == true,
                "「\(command)」的建议里应提到 `\(expectSuggestion)`，实际：\(error.suggestion ?? "nil")")
    }

    @Test("⭐ 命令替换 → 建议分两次调用")
    func commandSubstitution() throws {
        try check("echo $(date)", expectToken: "$(", expectSuggestion: "分两次")
        try check("echo `date`", expectToken: "`", expectSuggestion: "分两次")
    }

    @Test("⭐ 裸 `$VAR` 必须被拒（放过去会得到静默的错误答案）")
    func variableExpansion() throws {
        // 放过去的后果：模型以为 `$HOME` 会展开，命令实际收到字面量字符串 `$HOME`，
        // 然后以一种完全看不懂的方式失败。拒绝 + 说清"没有变量"好得多。
        try check("echo $HOME", expectToken: "$", expectSuggestion: "没有变量")
        try check("cat $_path", expectToken: "$", expectSuggestion: "没有变量")
        // 双引号里也一样（POSIX 会展开，我们不展开 → 同样是静默错误答案）
        try check(#"echo "$HOME""#, expectToken: "$", expectSuggestion: "单引号")
    }

    @Test("只想要字面量 `$` 时用单引号，能通过")
    func literalDollarInSingleQuotes() throws {
        let script = try #require(parse(#"echo '$HOME'"#))
        #expect(script.pipelines[0].commands[0].arguments == ["$HOME"])
    }

    @Test("${} 形式")
    func braceExpansion() throws {
        try check("echo ${HOME}", expectToken: "${", expectSuggestion: "没有变量")
    }

    @Test("⚠️ 算术展开要给 `$((` 而不是 `$(` 的建议（顺序敏感）")
    func arithmeticOrdering() throws {
        try check("echo $((1+2))", expectToken: "$((", expectSuggestion: "run_python")
    }

    @Test("heredoc → 建议先写文件")
    func heredoc() throws {
        try check("cat <<EOF", expectToken: "<<", expectSuggestion: "write_file")
    }

    @Test("here-string 要在 heredoc 之前被识别")
    func hereString() throws {
        try check("cat <<< hello", expectToken: "<<<", expectSuggestion: "管道")
    }

    @Test("后台执行 `&` → 建议用 start_job")
    func background() throws {
        try check("sleep 10 &", expectToken: "&", expectSuggestion: "start_job")
    }

    @Test("子 shell → 建议顺序写出来")
    func subshell() throws {
        try check("(cd a; ls)", expectToken: "(", expectSuggestion: "顺序")
    }

    @Test("管道取反")
    func negation() throws {
        try check("! grep x a.txt", expectToken: "!", expectSuggestion: "run_python")
    }

    @Test("`~` 家目录展开（只在词首）")
    func tilde() throws {
        try check("cat ~/notes.txt", expectToken: "~", expectSuggestion: "相对路径")
    }

    @Test("⚠️ 但 `a~b` 里的波浪号是普通字符，不能误伤")
    func tildeInsideWordIsLiteral() throws {
        let script = try #require(parse("cat a~b.txt"))
        #expect(script.pipelines[0].commands[0].arguments == ["a~b.txt"])
    }

    @Test("⭐ 控制流关键字要给「改用 run_python」的建议")
    func controlFlow() throws {
        for keyword in ["if", "for", "while", "case", "function"] {
            let error = try #require(parseError("\(keyword) x; do y; done"), "\(keyword) 本应被拒绝")
            #expect(error.kind == .unsupported)
            #expect(error.suggestion?.contains("run_python") == true, "\(keyword) 的建议不对：\(error.suggestion ?? "nil")")
        }
    }

    @Test("⚠️ 控制关键字只在**命令名位置**才算关键字（作为参数时要放行）")
    func controlKeywordOnlyAtCommandPosition() throws {
        // `grep if file` 里的 `if` 是搜索词，不是关键字
        let script = try #require(parse("grep if src/a.txt"))
        #expect(script.pipelines[0].commands[0].arguments == ["if", "src/a.txt"])
    }
}

// MARK: - 校验：把跑不通的命令变成建议

@Suite("ShellValidator —— 该用工具的地方要说出来")

struct ShellValidatorTests {

    private func issues(_ command: String) -> [ShellIssue] {
        guard let script = parse(command) else { return [] }
        return ShellValidator.validate(script, original: command)
    }

    @Test("⭐ 网络命令 → 指向对应的工具")
    func networkCommands() throws {
        let curl = try #require(issues("curl https://example.com").first)
        #expect(curl.kind == .redirectedToTool)
        #expect(curl.suggestion?.contains("fetch_url") == true)
        #expect(curl.detail.contains("没有网络"))

        let wget = try #require(issues("wget https://example.com/a.zip").first)
        #expect(wget.suggestion?.contains("download_file") == true)
    }

    @Test("⭐ 解释器命令 → 指向 run_python / run_javascript")
    func interpreterCommands() throws {
        #expect(issues("python script.py").first?.suggestion?.contains("run_python") == true)
        #expect(issues("node index.js").first?.suggestion?.contains("run_javascript") == true)
        #expect(issues("bash script.sh").first?.suggestion?.contains("shell") == true)
    }

    @Test("⭐ `cd` 要说清「我们的 shell 没有持久工作目录」")
    func cdIsRedirected() throws {
        let issue = try #require(issues("cd src && ls").first)
        #expect(issue.kind == .redirectedToTool)
        #expect(issue.suggestion?.contains("cwd") == true)
    }

    @Test("⚠️ git 的写操作要指向带审批的工具")
    func gitWriteRedirected() throws {
        let issue = try #require(issues("git push origin main").first)
        #expect(issue.kind == .gitWriteInShell)
        #expect(issue.suggestion?.contains("git_push") == true)
        // 只读的 git 子命令要放行
        #expect(issues("git status --short").isEmpty)
        #expect(issues("git log --oneline -5").isEmpty)
    }

    @Test("⚠️ `sed -i` 就地改写要被拦（没有检查点）")
    func sedInPlace() throws {
        let issue = try #require(issues("sed -i 's/a/b/' src/a.py").first { $0.kind == .dangerousInShell })
        #expect(issue.suggestion?.contains("edit_file") == true)
        // 不就地改写的 sed 放行
        #expect(!issues("sed 's/a/b/' src/a.py").contains { $0.kind == .dangerousInShell })
    }

    @Test("未知命令给最接近的名字")
    func unknownCommand() throws {
        let issue = try #require(issues("grop -n x a.txt").first)
        #expect(issue.kind == .unknownCommand)
        #expect(issue.suggestion?.contains("grep") == true)
    }

    @Test("差太远就不猜，改成指向可用命令清单")
    func unknownCommandFarAway() throws {
        let issue = try #require(issues("zzzzzzz --x").first)
        #expect(issue.kind == .unknownCommand)
        #expect(issue.suggestion?.contains("run_python") == true || issue.suggestion?.contains("说明") == true)
    }

    @Test("⚠️ 重定向写文件只是「知情」，不算阻断（合法用法，走审批即可）")
    func redirectionIsInformational() throws {
        let all = issues("ls > out.txt")
        #expect(all.contains { $0.kind == .writesFileNeedsApproval })
        #expect(ShellValidator.blockingIssues(all).isEmpty, "重定向不该被当成错误拦下来")
    }

    @Test("⚠️ 真正的错误要在 blockingIssues 里")
    func blockingIssues() throws {
        #expect(!ShellValidator.blockingIssues(issues("curl https://x")).isEmpty)
        #expect(!ShellValidator.blockingIssues(issues("grop x")).isEmpty)
        #expect(ShellValidator.blockingIssues(issues("git status")).isEmpty)
    }

    @Test("命令条数与长度上限")
    func sizeLimits() throws {
        let long = (0..<30).map { "echo \($0)" }.joined(separator: "; ")
        #expect(!issues(long).filter { $0.kind == .tooManyCommands }.isEmpty)

        let huge = "echo " + String(repeating: "x", count: 9_000)
        #expect(!issues(huge).filter { $0.kind == .tooManyCommands }.isEmpty)
    }

    @Test("⭐ 表里每条命令都有一句话说明（UI 与帮助要用）")
    func everyEntryIsDocumented() {
        for entry in ShellCommandTable.entries {
            #expect(!entry.summary.isEmpty, "\(entry.name) 没有说明")
        }
        // 子集必须标出来，否则模型会以为它是完整的
        for name in ["sed", "grep", "find", "tar"] {
            #expect(ShellCommandTable.byName[name]?.isSubset == true, "\(name) 是子集实现，必须标出来")
        }
    }
}

// MARK: - 执行

/// 可编排的命令实现（测试用）
final class ScriptedCommands: ShellCommandImplementation, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: (ShellInvocation) -> ShellIOResult] = [:]
    private(set) var invocations: [ShellInvocation] = []

    init(_ handlers: [String: (ShellInvocation) -> ShellIOResult] = [:]) {
        self.handlers = handlers
    }

    func set(_ name: String, _ handler: @escaping (ShellInvocation) -> ShellIOResult) {
        lock.lock(); handlers[name] = handler; lock.unlock()
    }

    func run(_ invocation: ShellInvocation) throws -> ShellIOResult {
        lock.lock()
        invocations.append(invocation)
        let handler = handlers[invocation.command.executable]
        lock.unlock()
        guard let handler else {
            return ShellIOResult(stderr: Data("未注册的命令：\(invocation.command.executable)".utf8), exitCode: 127)
        }
        return handler(invocation)
    }

    var executedNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return invocations.map(\.command.executable)
    }
}

/// 把"一个能跑所有命令的调度器"包成 provider（测试用）
struct DispatcherProvider: ShellCommandProvider {
    let dispatcher: ScriptedCommands
    init(_ dispatcher: ScriptedCommands) { self.dispatcher = dispatcher }
    func implementation(for name: String) -> (any ShellCommandImplementation)? { dispatcher }
}

/// 内存重定向落点
final class MemoryRedirectionSink: ShellRedirectionSink, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    init(_ files: [String: String] = [:]) {
        self.files = files.mapValues { Data($0.utf8) }
    }

    func read(_ path: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[path] else { return Data() }
        return data
    }

    func write(_ path: String, data: Data, append: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if append, let existing = files[path] {
            files[path] = existing + data
        } else {
            files[path] = data
        }
    }

    func text(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[path].map { String(decoding: $0, as: UTF8.self) }
    }
}

@Suite("ShellInterpreter —— 管道 / 短路 / 重定向 / 退出码")

struct ShellInterpreterTests {

    private func commands() -> ScriptedCommands {
        let commands = ScriptedCommands()
        commands.set("echo") { ShellIOResult.text($0.command.arguments.joined(separator: " ") + "\n") }
        commands.set("cat") { invocation in
            ShellIOResult(stdout: invocation.stdin)   // 把 stdin 原样吐出来（便于验证管道）
        }
        commands.set("true") { _ in ShellIOResult() }
        commands.set("false") { _ in ShellIOResult(exitCode: 1) }
        commands.set("fail") { _ in ShellIOResult(stderr: Data("炸了".utf8), exitCode: 2) }
        return commands
    }

    private func run(_ source: String, commands: ScriptedCommands,
                     sink: MemoryRedirectionSink? = nil,
                     options: ShellRunOptions = .agentDefault,
                     limits: ShellRunLimits = .mobile) throws -> ShellRunResult {
        let script = try #require(parse(source), "解析失败：\(source)")
        return ShellInterpreter.run(script, provider: DispatcherProvider(commands), redirections: sink,
                                    limits: limits, options: options)
    }

    @Test("单条命令")
    func singleCommand() throws {
        let result = try run("echo 你好", commands: commands())
        #expect(result.exitCode == 0)
        #expect(result.combinedStdout == "你好\n")
        #expect(result.succeeded)
    }

    @Test("⭐ 管道把上游的 stdout 喂给下游的 stdin")
    func pipelineFeedsStdin() throws {
        let commands = commands()
        commands.set("upper") { invocation in
            ShellIOResult(stdout: Data(String(decoding: invocation.stdin, as: UTF8.self).uppercased().utf8))
        }
        let result = try run("echo hello | upper", commands: commands)
        #expect(result.combinedStdout == "HELLO\n")
    }

    @Test("⭐ 管道退出码取最后一条（POSIX 语义）")
    func pipelineExitCodeIsLast() throws {
        // 上游失败但下游成功 → 整条成功
        let commands = commands()
        commands.set("drain") { _ in ShellIOResult(stdout: Data("ok\n".utf8)) }
        let result = try run("fail | drain", commands: commands)
        #expect(result.exitCode == 0)
    }

    @Test("⭐ `&&`：成功才继续")
    func andShortCircuits() throws {
        let failing = try run("false && echo 不该跑", commands: commands())
        #expect(failing.executedCount == 1)
        #expect(failing.skipped.contains { $0.contains("echo") })

        let passing = try run("true && echo 应该跑", commands: commands())
        #expect(passing.executedCount == 2)
        #expect(passing.combinedStdout == "应该跑\n")
    }

    @Test("⭐ `||`：失败才继续（成功时跳过）")
    func orShortCircuits() throws {
        let success = try run("true || echo 不该跑", commands: commands())
        #expect(success.executedCount == 1)

        let failure = try run("false || echo 兜底", commands: commands())
        #expect(failure.executedCount == 2)
        #expect(failure.combinedStdout == "兜底\n")
    }

    @Test("⭐ `;` 本身是无条件继续（关掉 stopOnError 时就是 POSIX 语义）")
    func semicolonAlwaysContinues() throws {
        let result = try run("false ; echo 继续", commands: commands(),
                             options: ShellRunOptions(stopOnError: false))
        #expect(result.executedCount == 2)
        #expect(result.combinedStdout == "继续\n")
        // 整体退出码是最后一条的
        #expect(result.exitCode == 0)
    }

    @Test("⚠️ 但 Agent 默认叠了一层「失败即停」——`;` 也不例外")
    func defaultStopsEvenOnSemicolon() throws {
        // 这是刻意的：`rm -rf build ; make` 里前半失败却继续跑后半，是很容易造成损失的一类事故。
        let result = try run("false ; echo 不该跑", commands: commands())
        #expect(result.executedCount == 1)
        #expect(result.stoppedEarly)
    }

    @Test("⚠️ 失败即停（默认开启）：`;` 序列里前一条失败就停下")
    func stopOnError() throws {
        let result = try run("fail ; echo 不该跑", commands: commands())
        #expect(result.executedCount == 1)
        #expect(result.stoppedEarly)
        #expect(result.exitCode == 2)
        #expect(result.skipped.contains { $0.contains("echo") })
    }

    @Test("⚠️ 但 `||` 后面的错误处理路径必须照跑（它不是「提前停止」）")
    func stopOnErrorStillRunsErrorHandler() throws {
        let result = try run("fail || echo 补救", commands: commands())
        #expect(result.executedCount == 2)
        #expect(result.combinedStdout == "补救\n")
    }

    @Test("关掉 stopOnError 后按 POSIX 语义继续")
    func canDisableStopOnError() throws {
        let result = try run("fail ; echo 继续", commands: commands(),
                             options: ShellRunOptions(stopOnError: false))
        #expect(result.executedCount == 2)
    }

    @Test("⭐ 重定向写文件：stdout 进文件，不回灌上下文")
    func stdoutRedirection() throws {
        let sink = MemoryRedirectionSink()
        let result = try run("echo 内容 > out.txt", commands: commands(), sink: sink)
        #expect(sink.text("/workspace/out.txt") == "内容\n")
        // ⚠️ 被重定向的输出不该再出现在上下文里（否则同一份内容付两次钱）
        #expect(result.combinedStdout.isEmpty)
    }

    @Test("`>>` 追加，`>` 覆盖")
    func appendVsOverwrite() throws {
        let sink = MemoryRedirectionSink(["/workspace/log.txt": "旧的\n"])
        _ = try run("echo 新的 >> log.txt", commands: commands(), sink: sink)
        #expect(sink.text("/workspace/log.txt") == "旧的\n新的\n")

        _ = try run("echo 覆盖 > log.txt", commands: commands(), sink: sink)
        #expect(sink.text("/workspace/log.txt") == "覆盖\n")
    }

    @Test("`<` 读文件当 stdin")
    func stdinRedirection() throws {
        let sink = MemoryRedirectionSink(["/workspace/in.txt": "来自文件\n"])
        let result = try run("cat < in.txt", commands: commands(), sink: sink)
        #expect(result.combinedStdout == "来自文件\n")
    }

    @Test("⚠️ 没有重定向能力时要如实说明，而不是静默丢掉输出")
    func redirectionWithoutSink() throws {
        let result = try run("echo 内容 > out.txt", commands: commands(), sink: nil)
        #expect(result.exitCode != 0)
        #expect(result.combinedStderr.contains("不支持") || result.combinedStderr.contains("重定向"))
    }

    @Test("未注册的命令 → 退出码 127（与 POSIX 一致）")
    func unknownCommandAtRuntime() throws {
        let result = try run("nosuchcmd --x", commands: commands())
        #expect(result.exitCode == 127)
        #expect(result.combinedStderr.contains("nosuchcmd"))
    }

    @Test("⭐ 输出截断要**保头也保尾**（结论通常在最后几行）")
    func truncationKeepsHeadAndTail() {
        let text = (1...2000).map { "第 \($0) 行" }.joined(separator: "\n")
        var limits = ShellRunLimits.mobile
        limits.maxOutputBytesPerCommand = 400
        let (data, truncated) = ShellInterpreter.truncate(Data(text.utf8), to: limits.maxOutputBytesPerCommand)
        let result = String(decoding: data, as: UTF8.self)
        #expect(truncated)
        #expect(result.contains("第 1 行"), "头部要留住（结论往往在开头）")
        #expect(result.contains("第 2000 行"), "尾部必须留住 —— 只保头会把最有用的信息扔掉")
        #expect(result.contains("省略"))
    }

    @Test("⚠️ 输出总量上限：17 条命令各吐 2MB 会撑爆内存")
    func totalOutputLimit() throws {
        let commands = commands()
        commands.set("spam") { _ in ShellIOResult(stdout: Data(repeating: 0x41, count: 200_000)) }
        var limits = ShellRunLimits.mobile
        limits.maxTotalOutputBytes = 400_000
        let result = try run("spam ; spam ; spam", commands: commands, limits: limits)
        #expect(result.wasTruncated)
        #expect(result.stoppedEarly)
        #expect(result.combinedStdout.utf8.count <= 500_000)
    }

    @Test("安全阀：命令条数上限")
    func commandCountLimit() throws {
        let many = (0..<30).map { "echo \($0)" }.joined(separator: "; ")
        var limits = ShellRunLimits.mobile
        limits.maxCommands = 5
        let result = try run(many, commands: commands(), limits: limits)
        #expect(result.executedCount == 5)
        #expect(result.stoppedEarly)
        #expect(!result.skipped.isEmpty)
    }

    @Test("⭐ 给模型的摘要：失败时突出失败的那条 + 它的 stderr")
    func modelFacingSummary() throws {
        let result = try run("echo 开始 ; fail", commands: commands())
        let summary = result.modelFacingSummary
        #expect(summary.contains("失败"))
        #expect(summary.contains("炸了"))
        #expect(summary.contains("退出码 2"))
    }

    @Test("成功的摘要只给最后一条的输出（中间过程对模型没用）")
    func summaryOnSuccess() throws {
        let result = try run("echo 中间 | cat | echo 结果", commands: commands())
        #expect(result.modelFacingSummary.contains("结果"))
        #expect(!result.modelFacingSummary.contains("中间"))
    }

    @Test("重定向目标按工作区根解析（iOS 上没有可用的进程 cwd）")
    func redirectionResolvesAgainstBase() throws {
        let sink = MemoryRedirectionSink()
        let provider = DispatcherProvider(commands())
        let result = try #require(parse("echo x > sub/out.txt"))
        _ = ShellInterpreter.run(result, provider: provider, redirections: sink)
        #expect(sink.text("/workspace/sub/out.txt") == "x\n")

        // 绝对路径原样使用
        let absolute = try #require(parse("echo y > /workspace/abs.txt"))
        _ = ShellInterpreter.run(absolute, provider: provider, redirections: sink)
        #expect(sink.text("/workspace/abs.txt") == "y\n")
    }
}

// MARK: - 与工具注册表对齐

@Suite("Shell × 工具注册表 —— 两边不能各说各话")

struct ShellToolAlignmentTests {

    @Test("⭐ 每条被重定向的命令，建议里提到的工具都必须真实存在")
    func redirectedSuggestionsExist() {
        for (name, redirect) in ShellCommandTable.redirectedCommands {
            // 从建议里抽出反引号包起来的工具名
            let mentioned = matches(in: redirect.suggestion)
            guard !mentioned.isEmpty else { continue }
            for tool in mentioned where ToolName.all.contains(tool) {
                // 提到的工具确实在注册表里 → 好
                #expect(ToolRegistry.byName[tool] != nil, "\(name) 建议了 `\(tool)`，但注册表里没有")
            }
        }
    }

    @Test("⭐ 命令表里 preferTool 指向的工具都必须真实存在")
    func preferToolsExist() {
        for entry in ShellCommandTable.entries {
            guard let tool = entry.preferTool else { continue }
            #expect(ToolName.all.contains(tool), "\(entry.name) 推荐了不存在的工具 `\(tool)`")
            #expect(ToolRegistry.byName[tool] != nil, "\(entry.name) 推荐了没有 spec 的工具 `\(tool)`")
        }
    }

    @Test("⭐ git 写操作的替代工具必须走策略引擎的 git 作用域（shell 那条路既没有作用域也没有审计）")
    func gitReplacementsDeclareCapability() {
        for (subcommand, tool) in shellForbiddenGitSubcommands {
            let spec = ToolRegistry.byName[tool]
            #expect(spec != nil, "git \(subcommand) 指向了不存在的工具 `\(tool)`")
            // ⚠️ 这里**不**断言"必须要求审批"：在已授权的仓库里改东西靠的是
            //    能力令牌的作用域 + 计划批准，不是逐次弹窗（见 docs/05 §8.1）。
            //    但**必须**声明 gitWrite —— 否则策略引擎的 git 作用域判定会被跳过，
            //    那才是把 shell 禁令的意义抹掉的那一步。
            #expect(spec?.requirements.contains(.gitWrite) == true,
                    "`\(tool)` 没声明 gitWrite → 策略引擎不会做 git 作用域判定")
        }
        // 真正危险的那两个仍然必须每次确认
        #expect(ToolRegistry.byName[ToolName.gitPush]?.needsApproval == .always)
    }

    private func matches(in text: String) -> [String] {
        var found: [String] = []
        var current: String?
        for character in text {
            if character == "`" {
                if let name = current { found.append(name); current = nil } else { current = "" }
            } else if current != nil {
                current?.append(character)
            }
        }
        return found
    }
}

// 便于断言的小工具
extension ShellRunResult {
    var executedCount: Int { outputs.count }
}



