#!/usr/bin/env python3
"""打一版可侧载的预览包，并生成**诚实**的 manifest。

⚠️ 为什么 manifest 要由工具生成、而不是手填：
   上一版的 manifest 里有两处**已经过时**——`tests` 停在 1101（真实是 1275）、
   `cloud_inference_verified: false`（C46 已经打通真实云端推理）。
   手填的数字会腐烂，而一个"看起来精确"的过期数字比没有数字更误导：
   读它的人会据此判断"这个版本验证到什么程度"。
   所以这份 manifest 的每个数字都是**现场测出来的**，测不出就写 null 并说明原因。

用法：
    python3 Tools/make_release.py --version 0.3.0 [--build 3]
    python3 Tools/make_release.py --version 0.3.0 --skip-tests   # 复用已有 ipa，不重跑测试
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import zipfile
from datetime import date

ROOT = pathlib.Path(__file__).resolve().parent.parent
RELEASES = ROOT / "output" / "releases"
APP_IPA = ROOT / "Apps" / "Rune" / "Rune-unsigned.ipa"


def run(cmd: list[str], cwd: pathlib.Path | None = None, timeout: int = 1800) -> tuple[int, str]:
    """跑一个命令，返回 (退出码, 输出)。**不抛异常** —— 让调用方决定怎么处理失败。"""
    try:
        result = subprocess.run(cmd, cwd=cwd or ROOT, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return 124, f"超时（{timeout}s）"
    except FileNotFoundError as error:
        return 127, f"找不到命令：{error}"


def count_tests() -> tuple[int | None, str | None]:
    """跑全部包的测试，数出**真实**通过数。

    ⚠️ 用 `ci.sh all` 而不是 `swift test`：前者是与 CI **同一个脚本**，
       所以这里的数字与 CI 上跑的是同一件事（T59 的教训：检查要跑在唯一入口上）。
    """
    print("  跑全量测试（ci.sh all）…", flush=True)
    code, output = run(["bash", "Tools/ci.sh", "all"])
    if code != 0:
        return None, f"测试未全绿（退出码 {code}）"
    counts = [int(n) for n in re.findall(r"Test run with (\d+) tests", output)]
    return (sum(counts) if counts else None), None


def ui_test_count() -> int | None:
    """数一下 UI 测试用例数（从源码静态数，不跑模拟器 —— 那要几分钟）。"""
    path = ROOT / "Apps" / "Rune" / "UITests" / "RuneSmokeTests.swift"
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8")
    return len(re.findall(r"func test\w+\s*\(", text))


def git_facts() -> dict[str, str]:
    facts: dict[str, str] = {}
    for key, cmd in (("commit", ["git", "rev-parse", "HEAD"]),
                     ("branch", ["git", "rev-parse", "--abbrev-ref", "HEAD"]),
                     ("dirty", ["git", "status", "--porcelain"])):
        _, out = run(cmd)
        facts[key] = out.strip()
    return facts


def channel_facts() -> tuple[bool, str | None]:
    """真实渠道联调到底验过没有 —— **看 `.env.pinai` 在不在，且记下验过的模型**。

    ⚠️ 这里不能写死 true：`cloud_inference_verified` 上一版写的是 false（已过时），
       但"改成 true"也不对 —— 它只被**一个**渠道（PinAI）的一个模型验过。
       所以如实写清"验过什么、没验什么"。
    """
    env_file = ROOT / ".env.pinai"
    if env_file.exists():
        return True, "PinAI / gpt-5.5（C46 端到端验收：真实模型 → 工具 → 审批 → 改盘 → 落盘验链）"
    return False, None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True, help="例如 0.3.0")
    parser.add_argument("--build", default=None, help="构建号，缺省用日期")
    parser.add_argument("--label", default="preview", help="版本标签，缺省 preview")
    parser.add_argument("--skip-tests", action="store_true", help="不重跑测试（复用上一次数字）")
    parser.add_argument("--skip-build", action="store_true", help="复用现有 ipa")
    args = parser.parse_args()

    print(f"打包 Rune {args.version}")
    build = args.build or date.today().strftime("%Y%m%d")

    # ① 构建 ipa
    if args.skip_build:
        if not APP_IPA.exists():
            print("  ❌ 没有现成 ipa，去掉 --skip-build", file=sys.stderr)
            return 1
        print("  复用现有 ipa")
    else:
        print("  构建 App + 打 ipa（ci.sh ipa）…", flush=True)
        code, output = run(["bash", "Tools", "ci.sh", "ipa"])
        if code != 0:
            print("  ❌ 构建失败：", output[-1500:], file=sys.stderr)
            return 1

    # ② 测试数字
    if args.skip_tests:
        tests, note = None, "本次跳过了测试（--skip-tests），未重新计数"
    else:
        tests, note = count_tests()
        if tests is None:
            print(f"  ❌ {note}", file=sys.stderr)
            return 1

    # ③ 归档
    RELEASES.mkdir(parents=True, exist_ok=True)
    stem = f"Rune-{args.version}-{args.label}-{date.today().strftime('%Y%m%d')}"
    ipa_path = RELEASES / f"{stem}-unsigned.ipa"
    shutil.copy2(APP_IPA, ipa_path)

    payload = ipa_path.read_bytes()
    with zipfile.ZipFile(ipa_path) as archive:
        names = archive.namelist()
    extensions = [n for n in names if n.endswith(".appex/Info.plist")]

    facts = git_facts()
    verified, verified_detail = channel_facts()

    manifest = {
        "file": ipa_path.name,
        "version": args.version,
        "build": build,
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "signed": False,
        "minimum_ios": "18.0",
        "extensions": extensions,
        "commit": facts.get("commit", "")[:12],
        "branch": facts.get("branch", ""),
        # ⚠️ 工作区脏就意味着"这个包对应的代码不在仓库里" —— 必须标出来，
        #    否则拿到包的人无法复现它。
        "worktree_clean": facts.get("dirty", "") == "",
        "tests": {
            "swiftpm": tests,
            "ui_full": ui_test_count(),
            "note": note,
        },
        "cloud_inference_verified": verified,
        "cloud_inference_detail": verified_detail,
        "whole_project_complete": False,
        "remaining_scope": "PROJECT_STATE.md §6（下一步）；docs/19 §5 是完整的剩余项清单",
        "how_to_install": [
            "用 Sideloadly（Windows/macOS）加载这个 ipa，用自己的 Apple ID 签名",
            "免费 Apple ID 的签名有效期是 7 天，到期需要重签",
            "首次启动需要在「设置 → 渠道与模型」里添加渠道并填入 API Key（密钥只存本机钥匙串）",
        ],
    }
    manifest_path = RELEASES / f"{stem}-manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print()
    print(f"  ✅ {ipa_path.relative_to(ROOT)}  ({len(payload) / 1_048_576:.1f} MB)")
    print(f"  ✅ {manifest_path.relative_to(ROOT)}")
    print(f"     commit {manifest['commit']} · 工作区{'干净' if manifest['worktree_clean'] else '⚠️ 有未提交改动'}")
    print(f"     测试 {tests if tests is not None else '未计数'} · UI 用例 {manifest['tests']['ui_full']}")
    print(f"     云端联调 {'已验：' + (verified_detail or '') if verified else '未验'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
