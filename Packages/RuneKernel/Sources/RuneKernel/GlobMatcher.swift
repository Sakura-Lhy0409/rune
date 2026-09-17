import Foundation

// MARK: - Glob 模式
//
// 这是 `glob` 工具与 `grep_search` 的 include/exclude 过滤共用的匹配核心。
//
// 支持的语法（覆盖模型实际会用到的全部形态）：
//   *          组件内任意字符（**不跨目录分隔符**）
//   ?          组件内单个字符
//   [abc]      字符类；[!abc] / [^abc] 取反；支持 [a-z] 范围
//   {a,b}      花括号择一（支持嵌套一层展开）
//   **         跨任意层目录
//   前导 /     锚定到挂载点根
//   结尾 /     只匹配目录
//
// 大小写：**默认不区分**。理由见 docs/05 §4.2 —— iOS/APFS 默认大小写不敏感，
// 若我们按大小写敏感匹配，会出现"在 Mac 上能跑、在 iOS 上跑不了"的诡异差异。

public struct GlobPattern: Sendable, Hashable {
    public let raw: String
    /// 是否为"锚定到根"的模式（以 `/` 开头，或模式中含 `/`）
    public let isAnchored: Bool
    /// 是否只匹配目录（以 `/` 结尾）
    public let directoryOnly: Bool
    public let caseSensitive: Bool

    let segments: [Segment]

    enum Segment: Sendable, Hashable {
        case literal(String)
        case wildcard(String)
        case doubleStar
    }

    public init(_ raw: String, caseSensitive: Bool = false) {
        self.raw = raw
        self.caseSensitive = caseSensitive

        var text = raw.trimmingCharacters(in: .whitespaces)
        var anchored = false
        var dirOnly = false

        if text.hasPrefix("/") {
            anchored = true
            text = String(text.dropFirst())
        }
        if text.hasSuffix("/") {
            dirOnly = true
            text = String(text.dropLast())
        }
        // 中间含 `/` 的 gitignore 语义是"相对根锚定"；对 glob 工具来说也一样
        if text.contains("/") { anchored = true }

        self.isAnchored = anchored
        self.directoryOnly = dirOnly
        self.segments = text
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { comp -> Segment in
                let s = String(comp)
                if s == "**" { return .doubleStar }
                if s.contains("*") || s.contains("?") || s.contains("[") || s.contains("{") {
                    return .wildcard(s)
                }
                return .literal(s)
            }
    }

    /// 模式是否合法（当前只拒绝空模式）
    public var isValid: Bool { !segments.isEmpty }

    // MARK: 匹配

    /// 匹配一个路径（components 不含挂载点；`isDirectory` 表示该路径本身是否目录）
    public func matches(components: [String], isDirectory: Bool = false) -> Bool {
        if directoryOnly && !isDirectory { return false }

        // 未锚定的模式（如 `*.swift`）在任意深度都可能匹配：
        // 实现方式是允许在开头跳过任意数量的组件。
        if !isAnchored {
            // 先尝试在每一层起始位置匹配（`*.swift` 应命中 `a/b/c.swift`）
            for start in 0...components.count {
                if Self.match(Array(components[start...]), segments, caseSensitive: caseSensitive) {
                    return true
                }
            }
            return false
        }
        return Self.match(components, segments, caseSensitive: caseSensitive)
    }

    public func matches(_ path: VFSPath, isDirectory: Bool = false) -> Bool {
        matches(components: path.components, isDirectory: isDirectory)
    }

    /// 递归匹配（含 `**` 的零或多层语义）
    static func match(_ components: [String], _ segments: [Segment], caseSensitive: Bool) -> Bool {
        var ci = 0
        var si = 0

        while si < segments.count {
            switch segments[si] {
            case .doubleStar:
                // `**` 匹配零或多层 → 尝试每一个可能的消耗量
                // 尾部的 `**` 直接成功（吃掉剩余全部）
                if si == segments.count - 1 { return true }
                for skip in ci...components.count {
                    if match(Array(components[skip...]), Array(segments[(si + 1)...]), caseSensitive: caseSensitive) {
                        return true
                    }
                }
                return false

            case .literal(let lit):
                guard ci < components.count else { return false }
                let a = caseSensitive ? lit : lit.lowercased()
                let b = caseSensitive ? components[ci] : components[ci].lowercased()
                guard a == b else { return false }
                ci += 1
                si += 1

            case .wildcard(let pattern):
                guard ci < components.count else { return false }
                guard matchComponent(pattern: pattern, name: components[ci], caseSensitive: caseSensitive) else {
                    return false
                }
                ci += 1
                si += 1
            }
        }
        return ci == components.count
    }

    // MARK: 组件内匹配

    /// 单组件匹配（支持 `*` `?` `[...]` `{a,b}`）。使用经典的回溯算法，无正则、无堆分配。
    public static func matchComponent(pattern: String, name: String, caseSensitive: Bool) -> Bool {
        for expanded in expandBraces(pattern) {
            if matchComponentSingle(pattern: expanded, name: name, caseSensitive: caseSensitive) {
                return true
            }
        }
        return false
    }

    /// 展开 `{a,b}`（支持一层嵌套）
    static func expandBraces(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{") else { return [pattern] }
        var depth = 0
        var close: String.Index?
        var index = open
        while index < pattern.endIndex {
            let ch = pattern[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { close = index; break }
            }
            index = pattern.index(after: index)
        }
        guard let close else { return [pattern] }

        let prefix = String(pattern[pattern.startIndex..<open])
        let suffix = String(pattern[pattern.index(after: close)...])
        let body = String(pattern[pattern.index(after: open)..<close])

        // 按顶层逗号切分
        var alternatives: [String] = []
        var current = ""
        var level = 0
        for ch in body {
            if ch == "{" { level += 1 }
            if ch == "}" { level -= 1 }
            if ch == "," && level == 0 {
                alternatives.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        alternatives.append(current)

        return alternatives.flatMap { expandBraces(prefix + $0 + suffix) }
    }

    static func matchComponentSingle(pattern: String, name: String, caseSensitive: Bool) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let s = Array(name.unicodeScalars)
        var pi = 0, si = 0
        var starPi = -1, starSi = 0

        while si < s.count {
            var advanced = false
            if pi < p.count {
                switch p[pi] {
                case "*":
                    starPi = pi
                    starSi = si
                    pi += 1
                    continue
                case "?":
                    pi += 1; si += 1; advanced = true
                case "[":
                    if let cls = parseCharClass(p, from: pi) {
                        if cls.contains(s[si], caseSensitive: caseSensitive) {
                            pi = cls.endIndex; si += 1; advanced = true
                        }
                    } else if equal(p[pi], s[si], caseSensitive: caseSensitive) {
                        // 非法的 `[` → 当字面量
                        pi += 1; si += 1; advanced = true
                    }
                default:
                    if equal(p[pi], s[si], caseSensitive: caseSensitive) {
                        pi += 1; si += 1; advanced = true
                    }
                }
            }
            if !advanced {
                guard starPi >= 0 else { return false }
                pi = starPi + 1
                starSi += 1
                si = starSi
            }
        }
        // 允许模式尾部剩余的全是 `*`
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private static func equal(_ a: UnicodeScalar, _ b: UnicodeScalar, caseSensitive: Bool) -> Bool {
        if a == b { return true }
        guard !caseSensitive else { return false }
        return String(a).lowercased() == String(b).lowercased()
    }

    struct CharClass {
        var negated: Bool
        var ranges: [(UnicodeScalar, UnicodeScalar)]
        /// 指向 `]` 之后的第一个位置
        var endIndex: Int

        func contains(_ sc: UnicodeScalar, caseSensitive: Bool) -> Bool {
            let target = caseSensitive ? sc : UnicodeScalar(String(sc).lowercased()) ?? sc
            for (lo, hi) in ranges {
                let l = caseSensitive ? lo : (UnicodeScalar(String(lo).lowercased()) ?? lo)
                let h = caseSensitive ? hi : (UnicodeScalar(String(hi).lowercased()) ?? hi)
                if target >= l && target <= h { return !negated }
            }
            return negated
        }
    }

    /// 从 `[` 处解析字符类；非法则返回 nil
    static func parseCharClass(_ scalars: [UnicodeScalar], from start: Int) -> CharClass? {
        var i = start + 1
        guard i < scalars.count else { return nil }
        var negated = false
        if scalars[i] == "!" || scalars[i] == "^" {
            negated = true
            i += 1
        }
        var ranges: [(UnicodeScalar, UnicodeScalar)] = []
        var first = true
        while i < scalars.count {
            let ch = scalars[i]
            if ch == "]" && !first {
                return CharClass(negated: negated, ranges: ranges, endIndex: i + 1)
            }
            first = false
            // 范围 a-z
            if i + 2 < scalars.count, scalars[i + 1] == "-", scalars[i + 2] != "]" {
                ranges.append((ch, scalars[i + 2]))
                i += 3
            } else {
                ranges.append((ch, ch))
                i += 1
            }
        }
        return nil   // 没有闭合的 `]`
    }
}

// MARK: - 便捷入口

extension GlobPattern {
    /// 解析一串模式；无效模式被丢弃（调用方应另行校验并提示用户）
    public static func parseAll(_ raws: [String], caseSensitive: Bool = false) -> [GlobPattern] {
        raws.map { GlobPattern($0, caseSensitive: caseSensitive) }.filter(\.isValid)
    }
}
