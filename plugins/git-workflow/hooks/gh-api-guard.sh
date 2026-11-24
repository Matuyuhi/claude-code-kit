#!/bin/bash

# PreToolUse(Bash) hook: gh api を「GET と確定できるもの」だけ通し、それ以外は確認に回す。
# permissions の allow に Bash(gh api *) を置き、書き込みの判定はここで行う。
# 文字列パターンでは -X=POST・引用符・変数経由の書き方を取りこぼすため、引数を shell の規則で分解して判定する。
# 判定できない書き方は ask に倒す。gh api を含まないコマンドには何も出さない（permissions の判定に任せる）。

input=$(cat)

case "$input" in
    *gh*api*) ;;
    *) exit 0 ;;
esac

ask() {
    jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
    exit 0
}

command -v python3 >/dev/null || ask "gh api guard: python3 が無いので判定できない"

reason=$(HOOK_INPUT="$input" python3 -I -c '
import json, os, shlex, sys

def ask(reason):
    print(reason)
    sys.exit(1)

cmd = json.loads(os.environ["HOOK_INPUT"]).get("tool_input", {}).get("command", "")

lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
lex.whitespace_split = True
try:
    tokens = list(lex)
except ValueError as e:
    ask(f"引数を分解できない（{e}）")

SEPARATORS = {";", ";;", "&", "&&", "|", "||", "|&", "(", ")"}
segments, cur = [], []
for t in tokens:
    if t in SEPARATORS:
        segments.append(cur)
        cur = []
    else:
        cur.append(t)
segments.append(cur)

BOOL_LONG = {"--paginate", "--slurp", "--include", "--silent", "--verbose", "--allow-escape-sequences"}
VALUE_LONG = {"--method", "--header", "--jq", "--template", "--hostname", "--preview", "--cache"}
WRITE_LONG = {"--field", "--raw-field", "--input"}
BOOL_SHORT = {"i"}
VALUE_SHORT = {"X": "--method", "H": "--header", "q": "--jq", "t": "--template", "p": "--preview"}
WRITE_SHORT = {"f", "F"}

def check(args):
    method = "GET"
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a.isdigit() and i + 1 < len(args) and args[i + 1][:1] in "<>":
            i += 1
            continue
        if a[:1] in "<>":
            i += 2
            continue
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            if name in WRITE_LONG:
                ask(f"{name} は body を送る（-X なしだと POST になる）")
            if name in BOOL_LONG:
                i += 1
                continue
            if name not in VALUE_LONG:
                ask(f"判定対象外のフラグ {name}")
            if not eq:
                if i + 1 >= len(args):
                    ask(f"{name} の値が無い")
                i += 1
                val = args[i]
            if name == "--method":
                method = val
            if name == "--header" and "method-override" in val.lower():
                ask("メソッドを上書きするヘッダがある")
            i += 1
            continue
        if a.startswith("-") and len(a) > 1:
            j = 1
            while j < len(a):
                c = a[j]
                if c in WRITE_SHORT:
                    ask(f"-{c} は body を送る（-X なしだと POST になる）")
                if c in BOOL_SHORT:
                    j += 1
                    continue
                if c not in VALUE_SHORT:
                    ask(f"判定対象外のフラグ -{c}")
                val = a[j + 1:]
                if val.startswith("="):
                    val = val[1:]
                if not val:
                    if i + 1 >= len(args):
                        ask(f"-{c} の値が無い")
                    i += 1
                    val = args[i]
                if c == "X":
                    method = val
                if c == "H" and "method-override" in val.lower():
                    ask("メソッドを上書きするヘッダがある")
                break
            i += 1
            continue
        positional.append(a)
        i += 1
    if method != "GET":
        ask(f"メソッドが GET ではない（{method}）")
    if len(positional) != 1:
        ask("endpoint 以外の引数がある")
    if positional[0] == "graphql":
        ask("graphql は query と mutation をフラグの字面で区別できない")

for seg in segments:
    k = 0
    while k < len(seg) and "=" in seg[k] and not seg[k].startswith("-") and seg[k].split("=", 1)[0].isidentifier():
        k += 1
    seg = seg[k:]
    if not seg or os.path.basename(seg[0]) != "gh":
        continue
    if len(seg) < 2 or seg[1] != "api":
        if "api" in seg:
            ask("gh と api の間に別の引数がある")
        continue
    args = seg[2:]
    if any("$" in a or "`" in a for a in args):
        ask("変数・コマンド置換を含む（展開後の引数が分からない）")
    check(args)
' 2>&1) && exit 0

ask "gh api guard: GET と確定できない — $(printf '%s' "$reason" | tail -n 1)"
