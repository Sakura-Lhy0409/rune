#!/usr/bin/env python3
"""校验 CI 配置的结构。

⚠️ 为什么需要它：本机没有 GitHub Actions 可以跑（网络不通、也没有仓库凭据），
所以"这两个 workflow 对不对"只能靠**静态检查**。它能抓的是结构性问题：
没有 runs-on、步骤既没有 uses 也没有 run、action 没写版本号、job 依赖指向不存在的 job。
它**不能**替代真跑一次 —— 那是 docs/16 §4 里说的"第一次失败是正常的"。

用法：python Tools/check_ci.py
"""
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("需要 pyyaml：python -m pip install pyyaml")
    sys.exit(2)

# ⚠️ GitHub Actions 里的 action 必须锁定版本（`@v4`）。
#    写 `@main` 之类的浮动引用会让某天上游一改、构建就莫名其妙地红。
REQUIRED_ACTIONS = {
    "actions/checkout": {"v4", "v5"},
    "actions/upload-artifact": {"v4", "v5"},
    "maxim-lobanov/setup-xcode": {"v1"},
}


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    problems: list[str] = []
    workflows = sorted((root / ".github" / "workflows").glob("*.yml"))
    if not workflows:
        print("❌ 没有找到任何 workflow")
        return 1

    for path in workflows:
        rel = path.relative_to(root)
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(doc, dict):
            problems.append(f"{rel}: 顶层不是映射")
            continue

        # YAML 1.1 会把 `on:` 解析成布尔 True，两种都要认
        triggers = doc.get("on", doc.get(True))
        if triggers is None:
            problems.append(f"{rel}: 缺少 on: 触发条件")

        jobs = doc.get("jobs") or {}
        if not jobs:
            problems.append(f"{rel}: 缺少 jobs")

        print(f"{rel}")
        print(f"  触发: {list(triggers.keys()) if isinstance(triggers, dict) else triggers}")

        for job_name, job in jobs.items():
            if "uses" not in job and "runs-on" not in job:
                problems.append(f"{rel}: job `{job_name}` 没有 runs-on")

            for need in job.get("needs", []) if isinstance(job.get("needs"), list) else [job.get("needs")]:
                if need and need not in jobs:
                    problems.append(f"{rel}: job `{job_name}` 依赖了不存在的 job `{need}`")

            steps = job.get("steps") or []
            if not steps:
                problems.append(f"{rel}: job `{job_name}` 没有 steps")

            for index, step in enumerate(steps, start=1):
                where = f"{rel}: job `{job_name}` 第 {index} 步"
                if "uses" not in step and "run" not in step:
                    problems.append(f"{where} 既没有 uses 也没有 run")
                if "uses" in step:
                    uses = str(step["uses"])
                    if "@" not in uses:
                        problems.append(f"{where} 的 action 没写版本号：{uses}")
                    else:
                        name, _, version = uses.partition("@")
                        allowed = REQUIRED_ACTIONS.get(name)
                        if allowed is not None and version not in allowed:
                            problems.append(
                                f"{where} 用了未预期的 action 版本：{uses}（已知可用：{sorted(allowed)}）"
                            )
                if "run" in step and not step.get("name"):
                    problems.append(f"{where} 没有 name（CI 报告里会显示成裸命令，不好定位）")

            print(
                f"  job {job_name}: runs-on={job.get('runs-on')} "
                f"steps={len(steps)} needs={job.get('needs')} "
                f"continue-on-error={job.get('continue-on-error')}"
            )

    # ---------- project.yml ----------
    project = root / "Apps" / "Rune" / "project.yml"
    if project.exists():
        spec = yaml.safe_load(project.read_text(encoding="utf-8"))
        print(f"\n{project.relative_to(root)}")
        targets = spec.get("targets") or {}
        print(f"  targets: {list(targets.keys())}")
        packages = spec.get("packages") or {}
        for name, entry in packages.items():
            package_path = (project.parent / entry["path"]).resolve()
            if not (package_path / "Package.swift").exists():
                problems.append(f"project.yml: 包 `{name}` 指向的路径没有 Package.swift -> {entry['path']}")
        for tname, target in targets.items():
            for dep in target.get("dependencies") or []:
                if "package" in dep and dep["package"] not in packages:
                    problems.append(f"project.yml: target `{tname}` 依赖了未声明的包 `{dep['package']}`")
                if "target" in dep and dep["target"] not in targets:
                    problems.append(f"project.yml: target `{tname}` 依赖了未声明的 target `{dep['target']}`")
        for sname, scheme in (spec.get("schemes") or {}).items():
            if sname not in targets:
                problems.append(f"project.yml: scheme `{sname}` 没有对应的 target")
            for t in (scheme.get("build") or {}).get("targets", {}) or {}:
                if t not in targets:
                    problems.append(f"project.yml: scheme `{sname}` 引用了不存在的 target `{t}`")

    # ---------- 引用的脚本文件是否存在 ----------
    for path in workflows:
        text = path.read_text(encoding="utf-8")
        for referenced in ["Tools/ci.sh", "Apps/Rune/project.yml"]:
            if referenced in text and not (root / referenced).exists():
                problems.append(f"{path.relative_to(root)}: 引用了不存在的文件 {referenced}")

    print()
    if problems:
        print(f"❌ 发现 {len(problems)} 个问题：")
        for problem in problems:
            print("  -", problem)
        return 1
    print("✅ CI 配置结构检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
