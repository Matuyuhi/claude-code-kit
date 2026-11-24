---
name: wip
description: 「手元の差分が何者か」「今手元にある差分は？」「今の状態」「stash にあると思うので復帰して再開」「現状教えて」「作業前に状態を見て」と言われた時、およびセッション冒頭で作業 branch を触る前・commit / push の前に使う。repo の branch・未 commit 差分・stash・worktree・紐づく PR を「何者か」の 1 行付きで一覧にし、再開するなら stash の復帰まで行う。
---

# wip — 手元の作業状態の棚卸し

ユーザーは複数 repo・複数 clone・worktree・stash をまたいで作業し、別セッションや数日後に「手元の差分が何者か」「stash にあるやつを復帰して再開」と戻ってくる（2026-09〜10 に 9 セッション）。毎回 `git status` を読んで推測し直しているので、見る順序と報告の形を固定する。

## 1. 対象 repo を決める

- 指示に repo・パスがあればそれ。無ければカレントの repo
- 同じ repo の clone が複数ある環境（`~/work/`, `~/work/feature*/` 等）では、どの clone を見ているかをパスで明示する。他 clone は頼まれた時だけ見る
- 「全部」と言われたら、作業用ディレクトリ（例: `~/work/`）直下の各 repo を順に見る

## 2. 見るもの（この順で、読み取りのみ）

```sh
git -C "$R" rev-parse --abbrev-ref HEAD                       # branch
git -C "$R" rev-parse --abbrev-ref --symbolic-full-name @{u}   # upstream（無ければ未 push）
git -C "$R" status --short                                    # 未 commit（staged / unstaged / untracked）
git -C "$R" log --oneline @{u}..HEAD                          # push していない commit
git -C "$R" stash list --format='%gd %cr %s'                  # stash
git -C "$R" worktree list                                     # worktree
gh pr list --repo <owner/repo> --head "$(git -C "$R" rev-parse --abbrev-ref HEAD)" --state all --json number,title,state,isDraft,url
```

- stash は `git stash show -p stash@{N} --stat` で中身の要約を取る（apply はしない）
- 差分の「何者か」は、diff の中身とファイル名・branch 名・直近 commit の subject・stash の message から 1 行で言う。分からないものは「不明（diff: 〜）」と書き、推測で意味付けしない
- `git fetch` は、PR 状態や base との乖離を聞かれた時だけ行う（ネットワークを伴うので一言添える）

## 3. 報告の形

repo ごとに 1 ブロック。各行に「何者か」を付ける。

```
example-app-android（~/work/example-app-android）
- branch: work/profile-edit → origin 同名、未 push 2 commit（PR #24 draft）
- 未 commit: 3 ファイル — プロフィール編集を設定画面から開く変更（commit 前にビルド未確認）
- stash@{0}（2 日前）: "WIP r8 keep rules" — ui モジュールの proguard 変更 4 ファイル。r8 サイズ縮小の作業
- worktree: ../feature2/example-app-android（work/r8-keep-rules-cleanup）
```

- 何も無ければ「clean（develop と同一）」の 1 行
- 判断が要るもの（捨てて良さそうな stash・remote が正で消して良さそうな差分）は、報告の最後に番号付きで「どうするか」を聞く。勝手に捨てない・apply しない

## 4. 「復帰して再開」と言われた時

1. 上の棚卸しを出し、どの stash / branch を指しているかを確認する（候補が 1 つなら確認なしで進めて良い）
2. 対象 branch へ checkout（未 commit 差分があれば先に扱いを聞く）
3. `git stash apply stash@{N}`（`pop` ではなく `apply`。コンフリクトや取り違えでも stash が残る）
4. コンフリクトが出たら解決せず止まって報告
5. 復帰後に `git status --short` を出し、「ここから再開」の作業内容を、stash の中身と knowledge/sessions（`/sessions <キーワード>`）から 2〜3 行で復元して示す

## 5. 他 skill との関係

- `publish` の手順 1 はこの skill の出力をそのまま使う
- 「base が離れている」「rebase したい」は、手元の origin ref が古い可能性があるので `git fetch` してから判断する
- セッション記録の検索は `sessions`
