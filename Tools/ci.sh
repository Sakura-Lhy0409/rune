#!/usr/bin/env bash
#
# Rune 在 macOS / Linux 上的构建与测试入口。
#
# ⚠️ 与 `Tools/rune.ps1` 的分工要说清楚（见 PROJECT_STATE §3 E1）：
#   * `Tools/rune.ps1`（Windows）—— 本机 SwiftPM 的**子进程执行层是坏的**，
#     所以那个脚本直接用 swiftc 驱动构建与测试。它只在 Windows 上有意义。
#   * `Tools/ci.sh`（本文件）—— 在**正常的** SwiftPM 上跑标准命令。
#     CI 与将来的 macOS 都走这条。
#
# 这个分工本身也是一条检查：**如果哪天内核在标准 SwiftPM 下构建不过，
# 说明它已经悄悄依赖上了 rune.ps1 里那些手工参数** —— 那是要立刻修的。
#
# 用法：
#   Tools/ci.sh build            # 构建所有包
#   Tools/ci.sh test             # 测试所有包（有 Tests/ 的）
#   Tools/ci.sh audit            # 零依赖审计（不 import Apple 框架、不声明外部依赖）+ 文档链接检查
#   Tools/ci.sh ios              # 生成 Xcode 工程并构建 App（需要 macOS + XcodeGen）
#   Tools/ci.sh ipa              # 构建并打包成可侧载的未签名 ipa（需要 macOS）
#   Tools/ci.sh all              # build + test + audit
#   Tools/ci.sh kernel           # 只跑零依赖核心（构建 + 测试 + 审计）

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✅ %s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m❌ %s\033[0m\n' "$*"; }
# ⚠️ 「跳过了」既不是通过也不是失败。没有这一档的话，被跳过的检查
#    会安静地消失，而报告上看起来一切正常 —— 那是最坏的一种"绿"。
warn() { printf '  \033[33m⚠️  %s\033[0m\n' "$*"; }

# ---------- 构建 ----------

cmd_build() {
  bold "构建所有包"
  local failed=0
  for dir in Packages/*/; do
    [ -f "$dir/Package.swift" ] || continue
    printf '\n--- %s ---\n' "$dir"
    if (cd "$dir" && swift build); then
      ok "$dir"
    else
      bad "$dir 构建失败"
      failed=1
    fi
  done
  return $failed
}

# ---------- 测试 ----------

cmd_test() {
  bold "测试所有包"
  local failed=0
  for dir in Packages/*/; do
    [ -d "$dir/Tests" ] || continue
    printf '\n--- %s ---\n' "$dir"
    if (cd "$dir" && swift test --parallel); then
      ok "$dir"
    else
      bad "$dir 测试失败"
      failed=1
    fi
  done
  return $failed
}

# ---------- 零依赖审计 ----------
#
# ⚠️ 这一节把一句**架构承诺**变成了断言（docs/03 §3）：
#   RuneKernel 只依赖 Foundation 与标准库。
# 它同时也是"能在任意平台验证"这句话的守卫 ——
# 没有 CI 的话，这条承诺只能靠人记得。

cmd_audit() {
  bold "零依赖审计（RuneKernel）"
  local dir="Packages/RuneKernel"
  local failed=0

  if grep -qE '\.package\(' "$dir/Package.swift"; then
    bad "Package.swift 声明了外部依赖"
    grep -n '\.package(' "$dir/Package.swift"
    failed=1
  else
    ok "没有外部依赖"
  fi

  local forbidden='UIKit|SwiftUI|AppKit|CryptoKit|Security|CoreML|Vision|AVFoundation|CoreLocation|Photos|HealthKit|UserNotifications|BackgroundTasks|WidgetKit|ActivityKit|SwiftData|CoreData|Combine|WebKit|JavaScriptCore|Metal|Accelerate|LocalAuthentication|StoreKit'
  if grep -rnE "^[[:space:]]*import ($forbidden)" "$dir/Sources/"; then
    bad "出现了 Apple 专属框架的 import"
    failed=1
  else
    ok "没有 Apple 专属框架"
  fi

  # 这几条是 Linux 构建**抓不到**的：它们在 macOS/Linux 上存在，但在 iOS 上不存在。
  if grep -rnE '(^|[^A-Za-z])Process[[:space:]]*\(' "$dir/Sources/"; then
    bad "用了 Process —— iOS 上不存在，且违反「无 fork/exec」铁律"
    failed=1
  else
    ok "没有 Process"
  fi

  # 文档链接也归这里管：坏链接意味着**新会话读不到该读的东西**，
  # 而这恰恰是续接机制最怕的失败（一次"查过了"不会自己保持）。
  if command -v python3 >/dev/null || command -v python >/dev/null; then
    local py; py="$(command -v python3 || command -v python)"
    if "$py" Tools/check_docs.py; then
      ok "文档内部链接可达"
    else
      failed=1
    fi
  else
    warn "没有 python，跳过文档链接检查"
  fi

  return $failed
}

# ---------- iOS ----------

cmd_ios() {
  command -v xcodegen >/dev/null || { bad "没装 XcodeGen（brew install xcodegen）"; return 1; }
  bold "生成 Xcode 工程并构建 App"
  (cd Apps/Rune && xcodegen generate)
  xcodebuild build \
    -project Apps/Rune/Rune.xcodeproj \
    -scheme Rune \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath Apps/Rune/build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
  ok "App 构建完成（未签名）"
}

cmd_ipa() {
  cmd_ios
  bold "打包成可侧载的 ipa"
  local app
  app=$(find Apps/Rune/build/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' | head -1)
  [ -n "$app" ] || { bad "没有找到 .app 产物"; return 1; }
  rm -rf Apps/Rune/ipa
  mkdir -p Apps/Rune/ipa/Payload
  cp -R "$app" Apps/Rune/ipa/Payload/
  # 清掉自带的（无效）签名：Sideloadly 要签的是干净产物
  rm -rf Apps/Rune/ipa/Payload/*.app/_CodeSignature \
         Apps/Rune/ipa/Payload/*.app/embedded.mobileprovision || true
  (cd Apps/Rune/ipa && zip -qry ../Rune-unsigned.ipa Payload)
  ok "Apps/Rune/Rune-unsigned.ipa"
  echo
  echo "下一步（Windows）：用 Sideloadly 加载这个 ipa，用你的 Apple ID 签名后装到手机上。"
  echo "⚠️ 免费 Apple ID 的签名有效期是 7 天，到期需要重签。详见 docs/16。"
}

# ---------- 入口 ----------

# ---------- 只跑内核（CI 的主力检查）----------

cmd_kernel() {
  bold "RuneKernel 构建与测试（零依赖核心）"
  (cd Packages/RuneKernel && swift build -v) || { bad "构建失败"; return 1; }
  ok "构建通过"
  (cd Packages/RuneKernel && swift test --parallel) || { bad "测试失败"; return 1; }
  ok "测试通过"
  cmd_audit
}

case "${1:-all}" in
  kernel) cmd_kernel ;;
  build) cmd_build ;;
  test)  cmd_test ;;
  audit) cmd_audit ;;
  ios)   cmd_ios ;;
  ipa)   cmd_ipa ;;
  all)   cmd_build && cmd_test && cmd_audit ;;
  *)     echo "用法: Tools/ci.sh [kernel|build|test|audit|ios|ipa|all]"; exit 2 ;;
esac

