#!/bin/bash
# review-watch の 1 周分で、レビューすべき open PR を選ぶ。gh の参照系だけを使い、GitHub には何も書かない。
#
#   使い方（対象 repo の中で実行）:
#     pick.sh <state.json>
#
#   選ぶ条件（draft と自分の PR は除く）:
#     new       自分が GitHub でまだレビューしておらず、review-watch でもまだ回していない
#     rereview  自分個人に re-review が依頼されていて、review-watch が最後に見た head から commit が進んでいる
#   push されただけの PR は、re-review を依頼されるまで回し直さない（同じ PR を何度も回すコストを避ける）。
#   チーム宛ての依頼は個人の依頼として扱わない（チームの自動アサインで件数が膨らむため）。
#
#   出力: 1 行 1 PR の TSV（number, headRefOid, baseRefName, reason, author, title）
#   state.json は {"<number>": {"head": "<sha>", ...}} の形。無ければ空として扱う。
set -euo pipefail

state=${1:?state.json のパスを渡す}
[ -f "$state" ] || state=/dev/null

me=$(gh api user --jq .login)

# reviews を取るとノード数が増えるので --limit は控えめにする（GraphQL の上限 50 万ノード）
gh pr list --state open --limit 60 \
  --json number,title,author,isDraft,headRefOid,baseRefName,reviewRequests,reviews \
  | jq -r --arg me "$me" --slurpfile st <(cat "$state" 2>/dev/null || echo '{}') '
    ($st[0] // {}) as $s
    | .[]
    | select(.isDraft | not)
    | select(.author.login != $me)
    | ($s[(.number | tostring)].head // null) as $seen
    | (any(.reviews[]; .author.login == $me)) as $reviewed
    | (any(.reviewRequests[]; .login == $me)) as $requested
    | (if $seen == null and ($reviewed | not) then "new"
       elif $requested and $seen != .headRefOid then "rereview"
       else empty end) as $reason
    | [.number, .headRefOid, .baseRefName, $reason, .author.login, .title] | @tsv'
