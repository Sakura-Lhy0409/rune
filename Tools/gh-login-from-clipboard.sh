#!/usr/bin/env bash
#
# 从**剪贴板**里取一个 GitHub token，用 `gh` 登进去，然后逐项验收。
#
# ⚠️ 为什么要有这个脚本（而不是让你把 token 贴进对话）：
#    贴进对话 = token 会留在会话记录里。剪贴板 → `gh auth login` 这条路径
#    让 token **只经过管道、不经过任何日志**（下面的 `set -x` 会把它打出来，
#    所以这个脚本里**故意不开启** trace）。
#
# 用法：先把 token 复制到剪贴板，然后 `bash Tools/gh-login-from-clipboard.sh`

set -uo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✅ %s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m❌ %s\033[0m\n' "$*"; }
warn() { printf '  \033[33m⚠️  %s\033[0m\n' "$*"; }

bold "1. 从剪贴板读取 token"

TOKEN="$(pbpaste 2>/dev/null | tr -d '\r\n[:space:]')"

# ⚠️ 只报长度与前缀，**永远不打印 token 本身** —— 脚本的输出经常被贴来贴去。
if [ -z "$TOKEN" ]; then
  bad "剪贴板是空的。请先在浏览器里生成 token 并复制"
  echo "    申请页（scope 已预勾好）："
  echo "    https://github.com/settings/tokens/new?scopes=repo,read:org,gist,workflow&description=Rune%20macOS%20push%20CI"
  exit 1
fi

case "$TOKEN" in
  ghp_*|github_pat_*|gho_*|ghu_*|ghs_*) ;;
  *) warn "前缀不像 GitHub token（期望 ghp_ / github_pat_ / gho_ …），仍会尝试" ;;
esac
ok "读到 ${#TOKEN} 个字符（前缀 ${TOKEN%%_*}_，内容不打印）"

bold "2. 这一步会用到这个 token 的 scope"
echo "    需要：repo（推代码）· workflow（改 .github/workflows/）"
echo "    建议：read:org 与 gist（gh 的推荐最小集）"
echo

bold "3. gh auth login --with-token"
if printf '%s' "$TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token 2>/tmp/gh_login_err.txt; then
  ok "登录成功"
else
  bad "登录失败："
  sed 's/^/    /' /tmp/gh_login_err.txt
  rm -f /tmp/gh_login_err.txt
  exit 1
fi
rm -f /tmp/gh_login_err.txt

bold "4. 验收（光是「登录成功」不算数，要逐条对上）"

# 4.1 活跃账号必须是 Sakura-Lhy0409
ACTIVE="$(gh api user --jq .login 2>/dev/null)"
if [ "$ACTIVE" = "Sakura-Lhy0409" ]; then
  ok "活跃账号 = Sakura-Lhy0409"
else
  bad "活跃账号是 $ACTIVE —— 不是 Sakura-Lhy0409。用 gh auth switch 切换"
fi

# 4.2 scope 必须含 repo 与 workflow
SCOPES="$(gh auth status 2>&1 | grep -i 'Token scopes' | head -1)"
echo "    $SCOPES"
for need in repo workflow; do
  if printf '%s' "$SCOPES" | grep -q "$need"; then
    ok "scope 含 $need"
  else
    bad "scope 缺 $need —— 推 .github/workflows/ 会被 GitHub 拒绝"
  fi
done

# 4.3 ⭐ 真正的验收标准：对这个仓库有没有 push 权限
PERM="$(gh api repos/Sakura-Lhy0409/rune --jq '.permissions.push' 2>/dev/null)"
if [ "$PERM" = "true" ]; then
  ok "对 Sakura-Lhy0409/rune 有 push 权限（⭐ 这一条才是真正的验收标准）"
else
  bad "push 权限 = $PERM —— 登录成功了但仍然推不上去，需要在该仓库 Settings → Collaborators 里加权限"
fi

bold "5. 收尾"
echo "    当前登录的账号列表："
gh auth status 2>&1 | grep -E 'Logged in|Active account' | sed 's/^/      /'
echo
echo "    Gu3hi 的登录**没有被删除**，随时可以切回："
echo "      gh auth switch            # 交互式选择"
echo "      gh auth switch -u Gu3hi   # 直接切到 Gu3hi"
