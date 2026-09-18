import Foundation

// MARK: - 挂载点

/// 虚拟文件系统的挂载点。模型看到的是一个稳定的 Unix 风格世界，
/// 底层映射（真实容器路径、用户授权目录、iCloud 未下载…）由 VFS 层隐藏。
/// 见 docs/05-工具系统与执行沙箱.md §4.1。
public enum MountPoint: String, Sendable, Codable, Hashable, CaseIterable {
    /// 主工作区（用户用文件选择器授权的目录，通常是 Git 仓库）
    case workspace
    /// 用户授权的其他目录（可多挂载）
    case userDocs = "user-docs"
    /// 分享收件箱
    case inbox
    /// 大产物与大输出（不参与 Git，不受 .gitignore 影响）
    case artifacts
    /// 临时目录（系统可随时清理）
    case tmp
    /// 技能与 Workflow 定义
    case runes
    /// 记忆库（数据库 + 嵌入向量）
    case memory
    /// 只读：运行时版本、设备能力、限额、已授予能力清单
    case sys

    public var isReadOnly: Bool {
        switch self {
        case .sys, .memory: return true
        case .workspace, .userDocs, .inbox, .artifacts, .tmp, .runes: return false
        }
    }
}

// MARK: - 虚拟路径

/// 虚拟路径：`/<mount>/<component>/<component>…`
///
/// ⚠️ 这是**安全边界**。所有文件访问必须经这里规范化，
/// 且必须拒绝：`..` 逃逸、NUL 字节、空组件、过深路径。
public struct VFSPath: Sendable, Hashable, Codable, CustomStringConvertible, Comparable {
    public let mount: MountPoint
    /// 已规范化的组件（不含挂载点本身），保证非空、无 "." / ".."
    public let components: [String]

    public init(mount: MountPoint, components: [String] = []) {
        self.mount = mount
        self.components = components.filter { !$0.isEmpty && $0 != "." }
    }

    public var description: String {
        "/" + mount.rawValue + (components.isEmpty ? "" : "/" + components.joined(separator: "/"))
    }

    /// 用于权限判定的比较键（大小写不敏感 + 组件级比较）
    public var matchKey: String {
        description.lowercased()
    }

    public static func < (lhs: VFSPath, rhs: VFSPath) -> Bool {
        lhs.description < rhs.description
    }

    public var isMountRoot: Bool { components.isEmpty }
    public var fileName: String? { components.last }
    public var fileExtension: String? {
        guard let name = fileName, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    // MARK: 解析（严格）

    public enum ParseError: Error, Equatable, Sendable {
        case notAbsolute(String)
        case unknownMount(String)
        case emptyComponent(index: Int)
        case parentTraversal(index: Int)
        case containsNullByte
        case componentTooLong(index: Int, length: Int)
        case pathTooDeep(depth: Int)
        case pathTooLong(length: Int)

        public var modelFacingMessage: String {
            switch self {
            case .notAbsolute(let p):
                return "路径必须是绝对路径（以 / 开头），收到的是「\(p)」。请使用例如 /workspace/src/main.swift 的形式。"
            case .unknownMount(let m):
                return "未知的挂载点「\(m)」。可用的挂载点：\(MountPoint.allCases.map(\.rawValue).joined(separator: ", "))。"
            case .emptyComponent(let i):
                return "路径第 \(i + 1) 段为空（可能出现了连续的 //）。"
            case .parentTraversal(let i):
                return "路径第 \(i + 1) 段是 `..`。出于安全考虑，Rune 不接受含 `..` 的路径；请改用绝对路径。"
            case .containsNullByte:
                return "路径包含非法的空字节。"
            case .componentTooLong(let i, let l):
                return "路径第 \(i + 1) 段长度为 \(l)，超过上限 255。"
            case .pathTooDeep(let d):
                return "路径深度为 \(d)，超过上限 \(Self.maxDepth)。"
            case .pathTooLong(let l):
                return "路径总长度为 \(l)，超过上限 \(Self.maxLength)。"
            }
        }

        static let maxDepth = 64
        static let maxLength = 4096
        static let maxComponentLength = 255
    }

    /// 严格解析。**任何来自模型或不可信内容的路径都必须走这个入口。**
    ///
    /// 规范化行为：
    ///   * Windows 风格反斜杠会被转成 `/`（模型经常这么写；iOS 上文件名几乎不可能含反斜杠）
    ///   * 重复斜杠会被折叠
    ///   * 尾部斜杠会被忽略
    ///   * 挂载点名称大小写不敏感（`/Workspace` → `/workspace`）
    public static func parse(_ raw: String) throws -> VFSPath {
        guard !raw.utf8.contains(0) else { throw ParseError.containsNullByte }
        guard raw.utf8.count <= ParseError.maxLength else { throw ParseError.pathTooLong(length: raw.utf8.count) }

        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        guard unified.hasPrefix("/") else { throw ParseError.notAbsolute(raw) }

        var rawComponents = unified.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        guard let mountRaw = rawComponents.first else {
            throw ParseError.unknownMount("(空路径)")
        }
        rawComponents.removeFirst()

        guard let mount = MountPoint.allCases.first(where: { $0.rawValue.lowercased() == mountRaw.lowercased() }) else {
            throw ParseError.unknownMount(mountRaw)
        }

        var components: [String] = []
        for (index, comp) in rawComponents.enumerated() {
            if comp == "." { continue }
            if comp == ".." { throw ParseError.parentTraversal(index: index) }
            if comp.isEmpty { throw ParseError.emptyComponent(index: index) }
            if comp.utf8.count > ParseError.maxComponentLength {
                throw ParseError.componentTooLong(index: index, length: comp.utf8.count)
            }
            components.append(comp)
        }

        guard components.count <= ParseError.maxDepth else {
            throw ParseError.pathTooDeep(depth: components.count)
        }

        return VFSPath(mount: mount, components: components)
    }

    /// 宽松解析：失败时返回 nil（用于 UI 输入框等场景，不抛错）
    public static func parseOrNil(_ raw: String) -> VFSPath? {
        try? parse(raw)
    }

    // MARK: 组合

    public func appending(_ name: String) -> VFSPath {
        guard name != ".", name != "..", !name.isEmpty else { return self }
        return VFSPath(mount: mount, components: components + [name])
    }

    public func appending(components more: [String]) -> VFSPath {
        more.reduce(self) { $0.appending($1) }
    }

    public var parent: VFSPath? {
        guard !components.isEmpty else { return nil }
        return VFSPath(mount: mount, components: Array(components.dropLast()))
    }

    /// 相对路径解析（用于 `@引用`、`cd` 语义）。
    ///
    /// 与 `parse` 的差别：允许 `..`，但**钳制在挂载点内，绝不逃逸**；调用方会知道是否发生了钳制。
    public static func resolve(base: VFSPath, relative: String) -> (path: VFSPath, clamped: Bool) {
        let unified = relative.replacingOccurrences(of: "\\", with: "/")
        if unified.hasPrefix("/") {
            if let absolute = parseOrNil(unified) { return (absolute, false) }
            // 绝对但非法（例如含 ..）→ 退化为组件级解析
        }
        var stack = base.components
        var clamped = false
        for comp in unified.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch comp {
            case ".":
                continue
            case "..":
                if stack.isEmpty {
                    clamped = true
                } else {
                    stack.removeLast()
                }
            default:
                stack.append(comp)
            }
        }
        return (VFSPath(mount: base.mount, components: stack), clamped)
    }

    // MARK: 权限判定

    /// 自己是否位于给定前缀之内（**组件级比较，防 `/workspace-other` 冒名 `/workspace`**）
    public func isWithin(_ prefix: VFSPath) -> Bool {
        guard mount == prefix.mount else { return false }
        guard components.count >= prefix.components.count else { return false }
        let head = components.prefix(prefix.components.count)
        return zip(head, prefix.components).allSatisfy { lhs, rhs in
            lhs.lowercased() == rhs.lowercased()
        }
    }
}

// MARK: - 能力范围

/// 路径权限范围
public struct PathScope: Sendable, Codable, Hashable {
    public enum Access: String, Sendable, Codable, Hashable {
        case readOnly
        case write
        case delete

        /// 权限蕴含关系：delete ⊃ write ⊃ readOnly
        public func implies(_ other: Access) -> Bool {
            switch (self, other) {
            case (.delete, _): return true
            case (.write, .write), (.write, .readOnly): return true
            case (.readOnly, .readOnly): return true
            default: return false
            }
        }
    }

    public let path: VFSPath
    public let access: Access

    public init(path: VFSPath, access: Access) {
        self.path = path
        self.access = access
    }

    public func covers(_ target: VFSPath, requiring need: Access) -> Bool {
        access.implies(need) && target.isWithin(path)
    }
}

/// 网络出口规则
public struct EgressRule: Sendable, Codable, Hashable {
    /// 精确域名，例如 "api.github.com"
    public let host: String?
    /// 域名后缀，例如 ".githubusercontent.com"（首字符必须是点，避免 evil-github.com 冒名）
    public let hostSuffix: String?
    public let methods: Set<String>
    public let maxBytes: Int?
    public let reason: String

    public init(
        host: String? = nil,
        hostSuffix: String? = nil,
        methods: Set<String> = ["GET"],
        maxBytes: Int? = nil,
        reason: String
    ) {
        self.host = host
        self.hostSuffix = hostSuffix
        self.methods = methods
        self.maxBytes = maxBytes
        self.reason = reason
    }

    /// 是否允许该请求。
    ///
    /// ⚠️ **安全要点**：后缀匹配必须先转小写并按点边界比较，
    /// 否则 `evil-githubusercontent.com` 会被 `.githubusercontent.com` 放行。
    public func allows(host targetHost: String, method: String, bytes: Int) -> Bool {
        let h = targetHost.lowercased()
        let m = method.uppercased()
        guard methods.contains(m) || methods.contains("*") else { return false }
        if let maxBytes, bytes > maxBytes { return false }

        if let host, host.lowercased() == h { return true }
        if let hostSuffix {
            let suffix = hostSuffix.lowercased()
            if h.hasSuffix(suffix) {
                // suffix 以 "." 开头时天然满足点边界；否则额外要求前一个字符是点或是整体相等
                if suffix.hasPrefix(".") { return h.count > suffix.count }
                return h == suffix || h.hasSuffix("." + suffix)
            }
        }
        return false
    }
}

/// iOS 原生能力
public enum NativeAPI: String, Sendable, Codable, Hashable, CaseIterable {
    case photos
    case camera
    case calendar
    case reminders
    case contacts
    case location
    case health
    case clipboard
    case speech
    case notifications
    case shortcuts

    /// 默认是否关闭（隐私敏感项：默认关闭，用户显式开启）
    public var isOptInByDefault: Bool {
        switch self {
        case .photos, .camera, .calendar, .reminders, .clipboard, .notifications: return false
        case .contacts, .location, .health, .speech, .shortcuts: return true
        }
    }

    public var displayName: String {
        switch self {
        case .photos: return "相册"
        case .camera: return "相机"
        case .calendar: return "日历"
        case .reminders: return "提醒事项"
        case .contacts: return "通讯录"
        case .location: return "定位"
        case .health: return "健康数据"
        case .clipboard: return "剪贴板"
        case .speech: return "语音识别"
        case .notifications: return "通知"
        case .shortcuts: return "快捷指令"
        }
    }
}

/// 沙箱运行时种类
public enum SandboxRuntime: String, Sendable, Codable, Hashable, CaseIterable {
    /// 原生 CPython（XCFramework + no-fork 垫片）
    case python
    /// JavaScriptCore / quickjs-ng
    case javascript
    /// 自研命令解释器（命令表映射到原生实现或 WASM 模块）
    case shell
    /// WasmKit 沙箱
    case wasm

    public var displayName: String {
        switch self {
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .shell: return "Shell"
        case .wasm: return "WebAssembly"
        }
    }
}

// MARK: - 能力令牌

/// 一枚具体的能力授权。
///
/// 三条硬规则（docs/09 §3.1）：
///   1. **令牌不继承**：子代理、Workflow 子任务、MCP 工具调用各自按需申请
///   2. **令牌不累积**：每轮 Turn 重新计算，过期即失效
///   3. **申请必须可解释**：携带 reason，UI 用它解释"为什么需要"
public struct CapabilityToken: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    /// 为哪个 Turn 签发
    public let issuedForTurn: UUID
    public let scopes: Set<Scope>
    public let issuedAt: Date
    /// 默认 = Turn 结束 + 5 分钟
    public let expiresAt: Date
    /// 每工具调用次数上限
    public var maxInvocations: [String: Int]
    public let requiresBiometric: Bool
    /// 谁申请的：用户 / 计划批准 / 策略豁免
    public let grantedBy: GrantedBy
    /// 申请理由（来自计划步骤的 toolHints）
    public let reason: String

    public init(
        id: UUID = UUID(),
        issuedForTurn: UUID,
        scopes: Set<Scope>,
        issuedAt: Date = Date(),
        expiresAt: Date,
        maxInvocations: [String: Int] = [:],
        requiresBiometric: Bool = false,
        grantedBy: GrantedBy,
        reason: String
    ) {
        self.id = id
        self.issuedForTurn = issuedForTurn
        self.scopes = scopes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.maxInvocations = maxInvocations
        self.requiresBiometric = requiresBiometric
        self.grantedBy = grantedBy
        self.reason = reason
    }

    public enum GrantedBy: String, Sendable, Codable, Hashable {
        /// 用户在 UI 上点的
        case userTap
        /// 计划批准时批量授予
        case planApproval
        /// 信任档位/策略文件豁免
        case policy
        /// 生物识别确认
        case biometric
    }

    /// 能力范围
    public enum Scope: Sendable, Codable, Hashable {
        case fsRead(VFSPath)
        case fsWrite(VFSPath)
        case fsDelete(VFSPath)
        case exec(runtime: SandboxRuntime)
        case egress(EgressRule)
        case native(NativeAPI)
        case mcp(server: String, tool: String)
        case gitWrite(remote: String?)

        /// 面向人与模型的说明。
        ///
        /// ⚠️ 审计事件必须**能被人读懂**：只把 scope 的 `Debug` 描述塞进事件里，
        ///    用户在审计面板上看到的是 `fsWrite(RuneKernel.VFSPath(...))` ——
        ///    那等于没有审计。这段话会进事件 payload，也会进"已授予能力清单"。
        public var auditText: String {
            switch self {
            case .fsRead(let path):   return "读取 \(path.description)"
            case .fsWrite(let path):  return "写入 \(path.description)"
            case .fsDelete(let path): return "删除 \(path.description)"
            case .exec(let runtime):  return "执行（\(runtime.rawValue) 沙箱）"
            case .egress(let rule):
                // ⚠️ 出口规则要报清"到哪、什么方法"：只写"网络出口"等于没审计 ——
                //    用户最想知道的是**它能把数据发到哪个域名**。
                let target = rule.host ?? (rule.hostSuffix.map { "*\($0)" } ?? "任意主机")
                let methods = rule.methods.sorted().joined(separator: "/")
                return "网络出口（\(target) \(methods)）"
            case .native(let api):    return "原生能力（\(api.rawValue)）"
            case .mcp(let server, let tool): return "MCP：\(server)/\(tool)"
            case .gitWrite(let remote): return remote.map { "Git 写操作（推送到 \($0)）" } ?? "Git 本地写操作"
            }
        }
    }

    public func isExpired(asOf now: Date = Date()) -> Bool {
        now >= expiresAt
    }

    /// 校验一个文件访问是否被授权。
    ///
    /// 权限蕴含关系（**故意设计为最小蕴含**）：
    ///   * `fsWrite` 蕴含读（要改先要读），但**不蕴含删除**
    ///   * `fsDelete` 只授权删除本身
    /// 理由：删除比写入破坏性大得多，不能因为"能写"就"能删"。
    public func authorizeFile(_ target: VFSPath, need: PathScope.Access, asOf now: Date = Date()) -> Bool {
        guard !isExpired(asOf: now) else { return false }
        return scopes.contains { scope in
            switch scope {
            case .fsRead(let prefix):
                return need == .readOnly && target.isWithin(prefix)
            case .fsWrite(let prefix):
                return (need == .readOnly || need == .write) && target.isWithin(prefix)
            case .fsDelete(let prefix):
                return need == .delete && target.isWithin(prefix)
            default:
                return false
            }
        }
    }

    /// 校验一次网络出口是否被授权
    public func authorizeEgress(host: String, method: String, bytes: Int, asOf now: Date = Date()) -> Bool {
        guard !isExpired(asOf: now) else { return false }
        return scopes.contains { scope in
            if case .egress(let rule) = scope {
                return rule.allows(host: host, method: method, bytes: bytes)
            }
            return false
        }
    }

    public func authorizeExec(runtime: SandboxRuntime, asOf now: Date = Date()) -> Bool {
        guard !isExpired(asOf: now) else { return false }
        return scopes.contains { if case .exec(let r) = $0 { return r == runtime } else { return false } }
    }

    public func authorizeNative(_ api: NativeAPI, asOf now: Date = Date()) -> Bool {
        guard !isExpired(asOf: now) else { return false }
        return scopes.contains { if case .native(let a) = $0 { return a == api } else { return false } }
    }
}

// MARK: - 判定结果

/// 策略引擎的判定结果。**每一个分支都要能被解释**——用户随时可以问"为什么这次被拦了"。
public enum CapabilityDecision: Sendable, Equatable {
    case allowed
    /// 需要人工确认（携带面向用户的一句话理由与风险等级）
    case requiresApproval(reason: String, risk: ToolSpec.RiskLevel)
    /// 直接拒绝
    case denied(reason: String, suggestion: String?)
    /// 命中人类专属区（单独的 case，因为要额外记录安全事件）
    case humanOnly(zone: HumanOnlyZone)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var isDenied: Bool {
        if case .denied = self { return true }
        return false
    }

    /// 转换为可回灌给模型的错误（拒绝时）
    public func asToolError() -> ToolError? {
        switch self {
        case .allowed:
            return nil
        case .requiresApproval(let reason, _):
            return ToolError(
                kind: .capabilityDenied,
                modelFacingMessage: "该操作需要用户确认后才能执行：\(reason)",
                suggestion: "请先向用户说明你打算做什么以及为什么，等待用户确认后再重试。"
            )
        case .denied(let reason, let suggestion):
            return ToolError(kind: .capabilityDenied, modelFacingMessage: reason, suggestion: suggestion)
        case .humanOnly(let zone):
            return ToolError(
                kind: .humanOnlyZone,
                modelFacingMessage: zone.denialReason,
                suggestion: "请不要尝试修改这些内容；如果需要，请在回复中说明理由，由用户手动处理。"
            )
        }
    }
}
