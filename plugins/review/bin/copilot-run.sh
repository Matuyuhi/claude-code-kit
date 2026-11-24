#!/bin/bash
# Copilot CLI を用途別の固定フラグで非対話起動する。agent（copilot-reviewer 等）は
# フラグを自分で組み立てず、必ずこのラッパーを通す。許可・拒否の組み合わせはここ 1 箇所で管理し、
# 変えたら末尾の「検証記録」も更新する。
#
#   使い方:
#     bin/copilot-run.sh review-diff  --cwd <repo> --diff <patch>  [--prompt-file <f>]   # diff を読み取り専用でレビュー
#     bin/copilot-run.sh investigate  --repo <path> [--repo <path> ...] [--prompt-file <f>]
#                                                                                         # 複数 repo を fleet で並列調査（読み取り専用）
#     bin/copilot-run.sh implement    ...                                                 # 未検証。exit 2 で止まる
#     bin/copilot-run.sh show <mode>                                                      # そのモードが渡すフラグを表示して終了
#
#   プロンプトは --prompt-file か標準入力で渡す（引数に直接は書かせない。長文と引用符の事故を避ける）。
#   実際に実行したコマンドを stderr に 1 行出すので、呼び出し元は Verification にそれを写せる。
#   Copilot の本体出力は stdout にそのまま出る。終了コードは copilot のものを返す。
#
#   どのモードも付けないもの（付けると cwd や --add-dir 先の .github/ の hooks・MCP・plugin を信頼済みとして読み込む）:
#     --trust-folder / --allow-all-paths / 環境変数 COPILOT_ALLOW_ALL
#   --allow-all-tools は非対話モードの必須条件で、--deny-tool が常に優先される（copilot help permissions）。
#   そのため読み取り専用は「--allow-all-tools + --deny-tool shell + --deny-tool write」で表す。
#   --add-dir は各ディレクトリの .github/skills と .github/agents を信頼済み設定として読むので、
#   渡すのは自分の管理下にある repo と、自分が書いた diff の置き場だけ。
#
#   Copilot の runtime は ~/.copilot に書くので、Claude Code の sandbox 内からは動かない。

set -u

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

die() { echo "copilot-run: $*" >&2; exit 2; }

# 共通: 読み取り専用セット。モードごとの差分はこの後ろに足す
RO_FLAGS=(-s --allow-all-tools --deny-tool shell --deny-tool write --output-format text)

mode="${1:-}"; [ -n "$mode" ] || { usage; exit 2; }; shift
case "$mode" in
  -h|--help) usage; exit 0;;
  review-diff|investigate|implement|show) ;;
  *) die "不明なモード: ${mode}（review-diff / investigate / implement / show）";;   # bash 3.2 は $mode（ を 1 つの変数名と読む
esac

if [ "$mode" = show ]; then
  case "${1:-}" in
    review-diff) echo "copilot -C <cwd> --add-dir <dirname(patch)> -p <prompt> ${RO_FLAGS[*]}";;
    investigate) echo "copilot -C <repo1> --add-dir <repo2> ... -p <prompt> --fleet ${RO_FLAGS[*]}";;
    implement)   echo "implement: 未検証。書き込みを許すセットはまだ決めていない";;
    *) die "show <review-diff|investigate|implement>";;
  esac
  exit 0
fi

command -v copilot >/dev/null 2>&1 || die "copilot が PATH に無い"
[ -z "${COPILOT_ALLOW_ALL:-}" ] || die "COPILOT_ALLOW_ALL が設定されている。外してから実行する（cwd を無条件に信頼してしまう）"

cwd="" diff="" prompt_file="" repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)  cwd="${2:-}"; shift 2;;
    --diff) diff="${2:-}"; shift 2;;
    --repo) repos+=("${2:-}"); shift 2;;
    --prompt-file) prompt_file="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "不明な引数: $1";;
  esac
done

abs() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }
require_git_repo() { git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1 || die "git repo ではない: $1"; }

if [ -n "$prompt_file" ]; then
  [ -r "$prompt_file" ] || die "prompt file が読めない: $prompt_file"
  prompt="$(cat "$prompt_file")"
else
  [ ! -t 0 ] || die "プロンプトを --prompt-file か標準入力で渡す"
  prompt="$(cat)"
fi
[ -n "$prompt" ] || die "プロンプトが空"

case "$mode" in
  review-diff)
    [ -n "$cwd" ] && [ -n "$diff" ] || die "review-diff には --cwd と --diff が要る"
    [ -d "$cwd" ] || die "cwd が無い: $cwd"
    [ -s "$diff" ] || die "diff が無いか空: $diff"
    require_git_repo "$cwd"
    diff_abs="$(abs "$diff")"
    cmd=(copilot -C "$cwd" --add-dir "$(dirname "$diff_abs")" -p "$prompt" "${RO_FLAGS[@]}")
    ;;
  investigate)
    [ "${#repos[@]}" -ge 1 ] || die "investigate には --repo が 1 つ以上要る"
    for r in "${repos[@]}"; do [ -d "$r" ] || die "repo が無い: $r"; require_git_repo "$r"; done
    cmd=(copilot -C "${repos[0]}")
    for r in "${repos[@]:1}"; do cmd+=(--add-dir "$r"); done
    cmd+=(-p "$prompt" --fleet "${RO_FLAGS[@]}")
    ;;
  implement)
    die "implement は未検証。書き込みを許すフラグのセットを決めて検証してから有効にする"
    ;;
esac

# 実行したコマンドを stderr に残す（プロンプト本文は長いので <prompt> に置き換える）
{
  printf 'copilot-run[%s]:' "$mode"
  skip=0
  for a in "${cmd[@]}"; do
    if [ "$skip" = 1 ]; then printf ' <prompt>'; skip=0; continue; fi
    [ "$a" = "-p" ] && skip=1
    printf ' %q' "$a"
  done
  echo
} >&2

exec "${cmd[@]}"

# 検証記録
#   2026-11-09 review-diff 相当（-C scratch repo, --add-dir diff 置き場, RO_FLAGS）: AGENTS.md と persona を読み、
#              shell / write 無しで完走。--trust-folder 無しでも動くことを同日確認
#   2026-11-09 investigate 相当（-C <repo> --add-dir <他の repo> --fleet, RO_FLAGS）: 複数 repo を並列で読み、
#              引用した file:line が実ファイルと一致
#   implement: 未検証
