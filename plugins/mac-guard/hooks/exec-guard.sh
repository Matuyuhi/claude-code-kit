#!/bin/bash

# PreToolUse(Bash / Write / Edit / MultiEdit / NotebookEdit) hook: AI がこの Mac で実行・書き込みする操作のうち、
# 攻撃の形をしたもの（取得して実行・隔離属性の除去・常駐の設置・認証情報の持ち出し・痕跡消し）を deny し、
# 設定変更・依存取得など「人の確認が要る」ものを ask に回す。
# permissions の文字列パターンでは引用符・変数・パイプ越しの書き方を取りこぼすので、ここで正規表現で見る。
# 変数で分割した難読化（c="cu"; $c"rl" …）には負ける。それは sandbox と security-audit の baseline が受け持つ。
#
# deny はモデルが上書きできない。必要なら人が自分の端末で実行する。
# 対象外のツール・一致しないコマンドには何も出さない（permissions の判定に任せる）。

# 判定に使う python3 / jq は純正を使う。.envrc や差し替えられた PATH の同名コマンドで判定を乗っ取られないため
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

input=$(cat)

case "$input" in
    *'"tool_name"'*) ;;
    *) exit 0 ;;
esac

# この hook と macguard / security-audit の実体がある repo。ここへの書き込みは guard 自身の無効化なので ask に回す
GUARD_REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." 2>/dev/null && pwd -P)"
export GUARD_REPO

ask() {
    jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
    exit 0
}

# /usr/bin/python3 は xcrun の shim で、書けない環境ではキャッシュ作成のエラーを stderr に出す。
# CLT の実体を直接使い、stderr は判定に混ぜない（rc だけ見る）
PY3=/Library/Developer/CommandLineTools/usr/bin/python3
[ -x "$PY3" ] || PY3=$(command -v python3) || ask "exec guard: python3 が無いので判定できない"

# python の本体は引用符付き heredoc で渡す（正規表現に ' や " を含むため bash の引用に巻き込ませない）
out=$(HOOK_INPUT="$input" "$PY3" -I - <<'PY' 2>/dev/null
import json, os, re, sys

inp = json.loads(os.environ["HOOK_INPUT"])
tool = inp.get("tool_name", "")
ti = inp.get("tool_input", {}) or {}
home = os.path.expanduser("~")

def emit(decision, reason):
    print(json.dumps({"decision": decision, "reason": reason}, ensure_ascii=False))
    sys.exit(0)

# ---------------- Bash ----------------
SH = r"(?:sudo\s+)?(?:ba|z|da|k)?sh\b"
INTERP = r"(?:sudo\s+)?(?:(?:ba|z|da|k)?sh|python3?|perl|ruby|node|osascript)\b"
FETCH = r"(?:curl|wget)\b"

DENY = [
    # 取得して実行（ClickFix / AMOS の入口）
    (FETCH + r"[^|]*\|\s*" + INTERP,                       "取得したものをそのまま実行する形"),
    (SH + r"\s+<\(\s*" + FETCH,                           "取得したものをそのまま実行する形"),
    (r"(?:eval|source|\.)\s+[\"']?\$\(\s*" + FETCH,       "取得したものをそのまま実行する形"),
    (r"base64\s+(?:-d|-D|--decode)\b[^|]*\|\s*" + INTERP, "復号したものをそのまま実行する形"),
    (r"python3?\s+-c\s+(?=.*(?:urlopen|requests\.|socket\.))(?=.*(?:exec\(|eval\(|subprocess|os\.system))", "取得したコードを python で実行する形"),
    (r"\|\s*(?:sudo\s+)?nc\b|/dev/tcp/",                   "ネットワークへ直接流す形"),
    # Gatekeeper / 隔離属性の無効化
    # 除去（-d）と書き換え（-w）だけ。-p / -l の読み取りは監査で使う
    (r"xattr\s+(?:-\S+\s+)*-[a-zA-Z]*[dw][a-zA-Z]*\s+[^;&|]*com\.apple\.quarantine", "隔離属性（quarantine）の除去・書き換え"),
    (r"xattr\s+-c",                                       "拡張属性の一括除去（quarantine を含む）"),
    (r"spctl\s+--(?:master|global)-disable",              "Gatekeeper の無効化"),
    (r"csrutil\s+(?:disable|enable|clear)|nvram\s+\S+=|fdesetup\s+disable", "SIP / FileVault / NVRAM の変更"),
    (r"defaults\s+write\s+.*LSQuarantine",                "隔離属性の無効化"),
    (r"defaults\s+write\s+(?:/Library/Preferences|.*com\.apple\.(?:loginwindow|security|LaunchServices))", "システム領域の設定変更"),
    # 常駐の設置
    (r"launchctl\s+(?:load|bootstrap|submit|enable)\b",   "launchd への登録"),
    (r"(?:cp|mv|ln|tee|install|plutil\s+-create|defaults\s+write|>+)\s+[^;&|]*(?:LaunchAgents|LaunchDaemons|PrivilegedHelperTools|StartupItems)/", "常駐（LaunchAgents / LaunchDaemons）の書き込み"),
    (r"crontab\s+(?!-l\b)",                               "cron の変更"),
    (r"DYLD_INSERT_LIBRARIES",                            "dylib 注入"),
    (r"git\s+config\s+.*(?:core\.hooksPath|core\.sshCommand|core\.pager|core\.fsmonitor|diff\.external|credential\.helper|url\..*insteadOf)", "git 設定でコード実行経路を差し替える形"),
    # 認証情報の読み出し・持ち出し
    (r"security\s+(?:dump-keychain|export|find-(?:generic|internet)-password\b.*\s-[gw]\b)", "キーチェーンから秘密を読み出す"),
    (r"sqlite3\s+.*(?:/Cookies|Login Data|TCC\.db|Web Data)",  "ブラウザ / TCC のデータベース読み出し"),
    (r"(?:cat|cp|scp|rsync|curl|base64|zip|tar|open)\b[^;&|]*(?:\.ssh/id_[a-z0-9]+|\.aws/credentials|\.netrc|\.docker/config\.json|login\.keychain|\.config/gcloud/.*credentials)", "認証情報ファイルの複製・送信"),
    (r"dscl\s+\.\s+-authonly",                            "パスワードの検証（総当たりの形）"),
    (r"(?:tccutil\s+reset|sqlite3\s+.*TCC)",              "TCC（プライバシー権限）の変更"),
    # 痕跡消し・防御の停止
    (r"history\s+-c|unset\s+HISTFILE|rm\s+[^;&|]*\.(?:zsh|bash)_history|log\s+erase", "履歴・ログの消去"),
    (r"(?:killall|pkill|kill)\b[^;&|]*(?:wdav|mdatp|Defender)|mdatp\s+(?:config|exclusion|--disable)", "EDR の停止・設定変更"),
    (r"osascript\s+-e\s+.*administrator privileges",      "管理者権限ダイアログの偽装"),
    (r"sudo\s+(?:launchctl|spctl|csrutil|nvram|profiles|systemsetup|pfctl|dscl|security|defaults\s+write\s+/Library)", "root でのシステム設定変更"),
    (r"rm\s+-[a-zA-Z]*r[a-zA-Z]*f?\s+(?:/|~|\$HOME|\"\$HOME\")(?:\s|$|/\s|/$)|dd\s+.*of=/dev/|diskutil\s+(?:erase|reformat)", "ディスク・ホームの破壊"),
]

ASK = [
    (r"\b(?:npx|bunx|uvx|pipx\s+run)\s+(?:-y|--yes|-p|--package|@?[a-z0-9-]+@|https?://)", "未検証のパッケージを取得して実行する"),
    (r"\bpnpm\s+dlx\b",                                   "未検証のパッケージを取得して実行する"),
    (r"\b(?:pip3?|npm|yarn|pnpm|gem|cargo|go|brew|uv)\s+(?:install|add|get|tool\s+install)\b", "依存の追加（supply chain 確認が要る）"),
    (r"curl\b[^;&|]*(?:\s-T\s|--upload-file|\s-F\s+[^ ]*@|--data-binary\s+@|\s-d\s+@)", "ファイルを外部へ送信する"),
    (r"\b(?:ngrok|cloudflared\s+tunnel|bore\b|localtunnel|ssh\s+-R)\b", "外部から到達できるトンネルを開く"),
    (r"(?:>>?|tee\s+(?:-a\s+)?)\s*\"?~?/?[^ ]*\.(?:zshrc|zprofile|zshenv|zlogin|bashrc|bash_profile|profile|gitconfig|npmrc|netrc)\b", "シェル・ツールの起動設定を書き換える"),
    (r"git\s+config\s+--global\b",                        "git のグローバル設定変更"),
    (r"launchctl\s+(?:bootout|unload|remove|disable)\b",  "常駐の停止・削除"),
    (r"(?:LaunchAgents|LaunchDaemons)/",                  "常駐の置き場に触る"),
    (r"chmod\s+[^;&|]*\+x\s+[^;&|]*(?:/tmp/|/private/tmp/|Downloads/|Application Support/)", "一時領域のファイルに実行権限を付ける"),
    (r"\bopen\s+[^;&|]*Downloads/[^;&|]*\.(?:dmg|pkg|mpkg|app|zip|command)\b", "ダウンロードしたインストーラを開く（macguard.sh gate を通す）"),
    (r"osascript\s+-e",                                   "AppleScript のインライン実行"),
    (r"\bmacguard\.sh\s+(?:install|uninstall|release)\b", "macguard の常駐・保留の変更"),
    (r"(?:\.ssh/|\.aws/|\.config/gcloud/|\.netrc|\.npmrc|login\.keychain)", "認証情報のある場所に触る"),
    (r"\bsqlite3\s+.*(?:History|Bookmarks|Local State)",  "ブラウザのデータ読み出し"),
]

# guard 自身（この hook・macguard・security-audit）の実体。書き換えは guard の無効化と同じなので ask
repo = os.environ.get("GUARD_REPO") or ""
GUARD_FILES = r"(?:hooks/[^/\s]+\.sh|bin/(?:macguard|security-audit)[^/\s]*\.sh)"
WRITE_VERB = r"(?:>+|sed\s+-[a-zA-Z]*i|perl\s+-[a-zA-Z]*[pi]|tee\b|cp\b|mv\b|rm\b|chmod\b|truncate\b|install\b|ln\b)"

def is_guard_source(p):
    if not repo:
        return False
    rp = os.path.realpath(p)
    return rp.startswith(repo + "/") and re.search("^" + re.escape(repo) + "/" + GUARD_FILES + "$", rp) is not None

def check_bash(cmd):
    flat = re.sub(r"\s+", " ", cmd)
    for pat, why in DENY:
        if re.search(pat, flat, re.IGNORECASE):
            emit("deny", f"exec guard: {why}。必要なら人が自分の端末で実行する")
    if repo and re.search(WRITE_VERB, flat):
        cwd_in_repo = os.path.realpath(inp.get("cwd") or os.getcwd()).startswith(repo)
        if re.search(re.escape(repo) + "/" + GUARD_FILES, flat) or (cwd_in_repo and re.search(r"(?:^|[\s\"'=])" + GUARD_FILES, flat)):
            emit("ask", "exec guard: guard 自身のソース（hooks / macguard / security-audit）を書き換える")
    for pat, why in ASK:
        if re.search(pat, flat, re.IGNORECASE):
            emit("ask", f"exec guard: {why}")

# ---------------- Write / Edit ----------------
def norm(p):
    if not p:
        return ""
    p = os.path.expanduser(p)
    if not os.path.isabs(p):
        p = os.path.join(inp.get("cwd") or os.getcwd(), p)
    return os.path.normpath(p)

H = re.escape(home)
DENY_PATH = [
    (r"^/Library/(?:LaunchAgents|LaunchDaemons|PrivilegedHelperTools|StartupItems|Security/SecurityAgentPlugins)/", "システムの常駐・認可プラグインの置き場"),
    (H + r"/(?:Library/LaunchAgents?|LaunchAgents)/",       "ユーザーの常駐の置き場"),
    (r"^/(?:etc|private/etc)/(?:sudoers|pam\.d|hosts|ssh|profile|zshrc|bashrc)", "システムの認証・ネットワーク設定"),
    (H + r"/\.ssh/(?:authorized_keys|config|id_[a-z0-9]+)", "SSH の鍵・設定"),
    (r"/NativeMessagingHosts/",                            "ブラウザの NativeMessagingHost（拡張からの実行経路）"),
    (H + r"/\.claude/(?:hooks/|settings\.json$)",          "Claude Code の hook・設定（人が自分の端末で反映する）"),
    (H + r"/\.claude\.json$",                              "Claude Code の MCP 登録"),
    (r"/\.git/hooks/|" + H + r"/\.git-templates/hooks/",  "git hook（checkout や commit で実行される）"),
    (H + r"/Library/Preferences/com\.apple\.(?:loginwindow|security)", "ログイン・セキュリティの設定"),
]
ASK_PATH = [
    (H + r"/\.(?:zshrc|zprofile|zshenv|zlogin|bashrc|bash_profile|profile|gitconfig|npmrc|netrc|pip/pip\.conf|docker/config\.json)$", "シェル・ツールの起動設定"),
    (H + r"/\.(?:aws|config/gcloud|kube)/",                "クラウドの認証情報"),
    (r"/\.envrc$|/\.mcp\.json$|/\.claude/settings(?:\.local)?\.json$", "repo を開くだけで読まれる設定（direnv / MCP / Claude Code）"),
    (r"/\.vscode/(?:tasks|settings)\.json$|/\.idea/workspace\.xml$", "IDE が自動で実行する設定"),
    (r"/\.github/workflows/",                              "CI 設定"),
    (H + r"/Library/LaunchAgents?/|/Library/Preferences/", "常駐・設定の置き場"),
]

def check_path(p):
    p = norm(p)
    if not p:
        return
    # symlink 経由でも plugin の直接パスでも、guard のソースは ask
    if is_guard_source(p):
        emit("ask", "exec guard: guard 自身のソースへの書き込み（hooks / macguard / security-audit / permissions 定義）")
    for pat, why in DENY_PATH:
        if re.search(pat, p):
            emit("deny", f"exec guard: {why} への書き込み。必要なら人が自分の端末で行う")
    for pat, why in ASK_PATH:
        if re.search(pat, p):
            emit("ask", f"exec guard: {why} への書き込み")

if tool == "Bash":
    check_bash(ti.get("command", "") or "")
elif tool in ("Write", "Edit", "MultiEdit"):
    check_path(ti.get("file_path", "") or "")
elif tool == "NotebookEdit":
    check_path(ti.get("notebook_path", "") or "")
PY
)
rc=$?
[ "$rc" -eq 0 ] || ask "exec guard: 判定に失敗した（python3 が rc=$rc。hooks/exec-guard.sh を手で実行して確認）"
[ -n "$out" ] || exit 0

decision=$(printf '%s' "$out" | jq -r '.decision')
reason=$(printf '%s' "$out" | jq -r '.reason')
jq -nc --arg d "$decision" --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
