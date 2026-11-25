#!/bin/bash
# セッションジャーナルに書かれた「次回に持ち越すつもりの学び」を抽出する。
#
#   使い方:
#     audit-carryover.sh                 # 全ジャーナル
#     audit-carryover.sh --since 2026-07-01
#     audit-carryover.sh --repo example-api
#
# ジャーナルは作業記録であって参照先ではないため、ここに書いただけの学びは次のセッションでは効かない。
# 出た行を skill / knowledge に還流したか突き合わせるのが目的（/reflect の仕上げから呼ぶ）。
set -euo pipefail

KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-$HOME/.claude/knowledge}"
SESSIONS="$KNOWLEDGE_DIR/sessions"
SINCE=""
REPO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since に YYYY-MM-DD が必要}"; shift 2 ;;
        --repo)  REPO="${2:?--repo に repo 名が必要}"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "不明な引数: $1" >&2; exit 2 ;;
    esac
done

[ -d "$SESSIONS" ] || { echo "sessions が見つかりません: $SESSIONS" >&2; exit 1; }

# 「今は書き留めるだけ、後で効かせる」を表す言い回しに絞る。
# 「横展開」「follow-up」は単体だと作業記録にも頻出するので、持ち越しを示す語形だけを拾う。
PATTERN='チェックリストに(入れる|追加)|教訓|次回(の|から|は)|今後は|横展開(候補|の余地|しておく|が必要)|follow-up ?(候補|とする)|フォローアップ候補|将来同種|次に同種|別 ?issue (候補|化)'

found=0
for f in "$SESSIONS"/*.md; do
    base="$(basename "$f")"
    [ "$base" = "INDEX.md" ] && continue
    [ -n "$SINCE" ] && [ "${base:0:10}" \< "$SINCE" ] && continue
    if [ -n "$REPO" ] && ! grep -qE "^  repo:.*$REPO" "$f"; then continue; fi

    # frontmatter（description に本文と同じ語が入る）は対象外。行番号は保つ
    fm_end="$(awk '/^---[[:space:]]*$/ {c++; if (c==2) {print NR; exit}}' "$f")"
    hits="$(grep -nE "$PATTERN" "$f" | awk -F: -v s="${fm_end:-0}" '$1 > s' | cut -c1-220 || true)"
    [ -z "$hits" ] && continue

    echo "=== $base ==="
    printf '%s\n' "$hits" | sed 's/^/  /'
    echo
    found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
    echo "該当なし。"
    exit 0
fi

cat <<'EOS'
---
この一覧は「ジャーナルに書いた学び」であって「効いている学び」ではない。
各行について、対応する skill / knowledge に入っているかを確認する:

  grep -rl "<キーワード>" ~/.claude/skills/ ~/.claude/knowledge/global/ ~/.claude/knowledge/projects/ ~/.claude/knowledge/tech/

入っていなければ /reflect の振り分け表に従って移す。
EOS
