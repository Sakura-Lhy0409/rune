#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文档体检：内部 markdown 链接是否都指得到真实文件。

为什么需要这个脚本（而不是"某次顺手查过一遍"）：
  本项目把文档当交付物，且每次改 `PROJECT_STATE.md` / `进度日志.md` 都会动链接。
  "上次查过 217 条链接都没坏"是**一次性事实**，不会自己保持；
  而坏链接的后果是**新会话读不到该读的东西** —— 恰恰是这个续接机制最怕的失败。

判据只有一条：`[文字](相对路径)` 里的路径，在仓库里必须存在。
⚠️ 只查**相对路径**：`http(s)://` 要联网，`#锚点` 要解析标题，两者都会让这个脚本变脆；
   它们不是本脚本要防的风险（本脚本防的是"文档搬家后链接没跟着改"）。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent

# [text](target) —— 排除图片（! 前缀）由下面的负向环视处理
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")


def markdown_files() -> list[Path]:
    files = [ROOT / "README.md", ROOT / "PROJECT_STATE.md"]
    files += sorted((ROOT / "docs").rglob("*.md"))
    return [f for f in files if f.is_file()]


def check(path: Path) -> list[str]:
    problems: list[str] = []
    text = path.read_text(encoding="utf-8")
    for lineno, line in enumerate(text.splitlines(), 1):
        for raw in LINK.findall(line):
            target = raw.strip()
            if target.startswith(("http://", "https://", "mailto:")):
                continue  # 联网目标不归这里管
            if target.startswith("#"):
                continue  # 同页锚点，不查
            # 去掉锚点与查询串，再 URL 解码（中文文件名常被写成 %E4%B8%AD）
            bare = target.split("#", 1)[0].split("?", 1)[0]
            if not bare:
                continue
            resolved = (path.parent / unquote(bare)).resolve()
            if not resolved.exists():
                problems.append(f"{path.relative_to(ROOT)}:{lineno}: 链接指不到 → {target}")
    return problems


def main() -> int:
    files = markdown_files()
    all_problems: list[str] = []
    total_links = 0
    for f in files:
        text = f.read_text(encoding="utf-8")
        total_links += sum(
            1
            for line in text.splitlines()
            for t in LINK.findall(line)
            if not t.startswith(("http://", "https://", "mailto:", "#"))
        )
        all_problems += check(f)

    if all_problems:
        print(f"❌ 文档里有 {len(all_problems)} 条坏链接：")
        for p in all_problems:
            print("   " + p)
            if "GITHUB_ACTIONS" in __import__("os").environ:
                print(f"::error file={p.split(':')[0]}::{p}")
        return 1

    print(f"✅ 文档内部链接全部可达（{len(files)} 个文件 / {total_links} 条相对链接）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
