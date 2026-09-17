#!/usr/bin/env python3
r"""抓「中文出现在代码位置」—— 也就是把中文引号打成了 ASCII 引号。

## 为什么需要它

写 Swift 时手打一个 ASCII 双引号，会**提前闭合字符串字面量**：

    @Test("（用户要能问"它到底往外发了什么"）")
              ^ 这里闭合了           ^ 这里又开了一个

于是 `它到底往外发了什么` 变成了**代码**，而编译器报的是
`expected ',' separator` 与 `cannot find '...' in scope` —— 和真实原因毫不相干。
本项目为此浪费过五次完整的编译往返。

## 为什么不能"数引号"

试过，两个方向都错：
  * 报 11 个假阳性（原始字符串、字符串里的注释符号）；
  * **漏掉真正的错** —— 上面那行引号数量是 4（偶数），数不出来。

## 判据：中文字符出现在字符串与注释之外

这一条精确命中上面那类错误，同时守住了本项目自己的约定
（`PROJECT_STATE §4.1`：代码标识符用英文，中文只出现在字符串与注释里）。

难点是**字符串插值**：`"写入：\(xs.joined(separator: "、"))"` 里那个 `、` 在
**插值内部的字符串**里，是合法的。所以扫描器要真的跟踪
`字符串 → 插值（代码）→ 插值里的字符串` 这三层，而不是平坦地数引号。

用法：python Tools/lint_quotes.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

TRIPLE = '"' * 3
RAW_STRING = re.compile(r'#"(?:[^"]|"(?!#))*"#')
CJK = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")

# 显式登记的例外：{相对路径: {行号}}。本仓库目前为空 ——
# 留着是为了让"要不要破例"变成一个**需要写下来的决定**，而不是随手加个 pragma。
ALLOW: dict[str, set[int]] = {}


def _skip_string(line: str, start: int) -> int:
    """`line[start]` 是开引号；返回配对引号之后的下标。"""
    index = start + 1
    while index < len(line):
        char = line[index]
        if char == "\\":
            index += 2
            continue
        if char == '"':
            return index + 1
        index += 1
    return len(line)


def code_outside_literals(line: str) -> str:
    """把字符串（含插值内部）与注释挖掉，只留真正的代码字符。"""
    line = RAW_STRING.sub('""', line)
    out: list[str] = []
    index = 0
    in_string = False
    interpolation_depth = 0

    while index < len(line):
        char = line[index]

        # ---------- 在字符串里 ----------
        if in_string:
            if char == "\\":
                if index + 1 < len(line) and line[index + 1] == "(":
                    # 进入插值：接下来是代码
                    in_string = False
                    interpolation_depth = 1
                    index += 2
                    continue
                index += 2          # 其它转义：跳过
                continue
            if char == '"':
                in_string = False
            index += 1
            continue

        # ---------- 在插值里（代码，但 `)` 会把我们送回外层字符串）----------
        if interpolation_depth > 0:
            if char == "(":
                interpolation_depth += 1
                index += 1
                continue
            if char == ")":
                interpolation_depth -= 1
                index += 1
                if interpolation_depth == 0:
                    in_string = True     # 回到外层字符串
                continue
            if char == '"':
                # 插值内部的字符串：整段跳过（它的内容不该参与判定）
                index = _skip_string(line, index)
                continue
            out.append(char)
            index += 1
            continue

        # ---------- 顶层代码 ----------
        if char == '"':
            in_string = True
            index += 1
            continue
        if char == "/" and index + 1 < len(line) and line[index + 1] == "/":
            break                        # 注释：后面不用看了
        out.append(char)
        index += 1

    return "".join(out)


def scan(path: Path) -> list[tuple[int, str, str]]:
    problems: list[tuple[int, str, str]] = []
    in_multiline = False
    allowed = ALLOW.get(str(path), set())

    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if raw.count(TRIPLE) % 2 == 1:
            in_multiline = not in_multiline
            continue
        if in_multiline or TRIPLE in raw:
            continue
        if number in allowed:
            continue
        found = CJK.findall(code_outside_literals(raw))
        if found:
            problems.append((number, raw.rstrip(), "".join(dict.fromkeys(found))))

    return problems


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    targets: list[Path] = []
    for pattern in ("Packages/*/Sources/**/*.swift", "Packages/*/Tests/**/*.swift", "Apps/**/*.swift"):
        targets.extend(sorted(root.glob(pattern)))

    if not targets:
        print("没有找到 .swift 文件")
        return 0

    total = 0
    for path in targets:
        problems = scan(path)
        if not problems:
            continue
        rel = path.relative_to(root)
        for number, line, found in problems:
            total += 1
            print(f"{rel}:{number}: 字符串与注释之外出现了中文：{found}")
            print(f"    {line.strip()}")
            print("    最常见的原因：中文文案里手打了 ASCII 双引号，把后半个字面量挤到了代码位置。")
            print("    改法：中文引号一律用「」。")

    print()
    if total:
        print(f"❌ {total} 处（检查了 {len(targets)} 个文件）")
        return 1
    print(f"✅ 中文只出现在字符串与注释里（检查了 {len(targets)} 个文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())

