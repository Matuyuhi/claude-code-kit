---
name: review-watch
description: 指定 repo の open PR のうち、自分以外が author で、自分がまだレビューしていないもの・自分に re-review が依頼されたものを、review-pr で 1 件ずつレビューしてローカルの md に書き出し、終わったらデスクトップ通知する。`/loop /review-watch [repo の絶対パス]` で起動すると 30 分ごとに見回る。ユーザーが「PR を見張って」「未レビューの PR を全部回して」「review-watch」と言った時に使う。GitHub には何も投稿しない。
---

# review-watch

open PR を見回り、まだ見ていない PR を review-pr でレビューして、結果をローカルに置く。投稿するかどうかはユーザーが結果を読んでから決める。

## 起動

- `/loop /review-watch <repo の絶対パス>` — 30 分ごとに見回る（1 周ごとに ScheduleWakeup で次を予約する）
- `/review-watch <repo の絶対パス>` — 1 周だけ回す
- repo を省略したら cwd の repo を対象にする

1 時間未満の間隔なので、cron や launchd ではなく会話の中で回す（短い間隔では、スケジューラの管理や停止の手間の方が大きい）。セッションを閉じる・Mac がスリープすると止まる。

## 置き場所

`DIR=~/.cache/review-watch/<owner>_<repo>`（sandbox で書ける場所）

- `state.json` — PR ごとに最後にレビューした head と結果。`{"123": {"head": "<sha>", "verdict": "Comment", "must": 0, "should": 3, "file": "...", "at": "2026-11-16T10:00"}}`
- `reviews/<PR番号>-<head 先頭 9 桁>.md` — review-pr のステップ 4 形式の全文
- `reviews/<PR番号>-<head 先頭 9 桁>.comments.md` — GitHub にそのまま貼れる投稿文面（本文 + inline。投稿文面用の skill を持っていればそれに準拠）。前提を確かめた指摘だけを載せる
- `summary.md` — 表形式の一覧（日時 / PR / author / タイトル / 総合評価 / Must・Should 件数 / 文面のファイルパス）。1 行ずつ末尾に足す。ユーザーはまずここを開き、文面のファイルを読んで投稿するかを決める

## 1 周の手順

### 1. 対象を選ぶ

```bash
cd <repo>
SLUG=$(gh repo view --json nameWithOwner --jq '.nameWithOwner | sub("/"; "_")')
DIR=~/.cache/review-watch/$SLUG; mkdir -p "$DIR/reviews"
bash "${CLAUDE_SKILL_DIR}/pick.sh" "$DIR/state.json"
```

pick.sh の選び方（詳細はスクリプト冒頭）:

- new: 自分が GitHub でまだレビューしておらず、review-watch でもまだ回していない
- rereview: 自分個人に re-review が依頼されていて、前回見た head から commit が進んでいる

0 件なら手順 5 へ。

### 2. PR の head を取ってくる

subagent は ssh で fetch できない（sandbox が `~/.ssh` を読ませない）。メインで HTTPS と gh の認証を使って取る:

```bash
git -c credential.helper= -c credential.helper='!gh auth git-credential' \
  fetch -q "https://github.com/<owner>/<repo>.git" "refs/pull/<N>/head:refs/review-watch/pr-<N>" \
  "refs/heads/<base>:refs/review-watch/base-<N>"
```

Bash の `allowed_domains` に `github.com` を渡す。シェルは zsh なので、変数をループで埋める時は `${b}` と波括弧で囲む（`$b:refs` は zsh の `:r` 修飾子として解釈され、ref 名が壊れる）。`for x in "N base"` の `$x` も zsh では単語分割されないので `while read -r n b` で回す。取れなかった PR はその周では飛ばし、summary.md に「取得失敗」と 1 行書く。

### 3. 1 PR ずつ subagent でレビューする

Agent ツールで、PR ごとに 1 体を background で起動する。同時に動かすのは 3 体まで。残りは前の agent が終わってから起動する。worktree は使わない（checkout せず `git show` で読むので、後片付けが要らない）。

依頼文（`<>` を埋める）:

```
<repo の絶対パス> の PR #<N>（head <sha>、base <base>）を、review-pr skill の手順どおりにレビューしてください。全ステップを省略しない。

作業のしかた:
- この repo のクローンでのみ作業する。git checkout・git switch・git worktree はしない（ユーザーの作業ブランチを動かさない）
- ファイルは `git show <sha>:<path>`、検索は `git grep -n <語> <sha> -- <path>`、差分は `git diff refs/review-watch/base-<N>...<sha>` で読む。android studio のシンボル検索は使わない（ユーザーが開いている別ブランチを見てしまう）
- Codex 並走（ステップ 2.2）は subagent の sandbox では動かないので試さず、「外部レビュー: 未実施（subagent の sandbox）」と書く

外部への書き込み禁止:
- GitHub への投稿（gh pr comment / gh pr review / gh api の POST 等）は一切しない。ステップ 5 は飛ばす

前提の検証（文面にする前に、指摘ごとに必ず行う）:
- 指摘が依存する前提を 1 行で書き出し、一次情報で確かめる。API の挙動は spec の説明文ではなくサーバー実装（<workspace> 配下の該当 repo）を読む。他 repo は読むだけで、checkout しない
- 「既存の〜で足りる」「〜が出ない」系の指摘は、既存側の実データの粒度（1 件 / 全件、どの単位で返るか）を確かめてから書く
- 確かめられなかった前提に乗る指摘は、文面には載せず、全文 md の「未検証」に残す
- persona skill の基準（型で不正状態を排除する 等）と repo の既存パターンがぶつかったら persona を優先する。「既存も同じ形」を理由に指摘を外さない
- Compose の差分は、recompose と安定性を必ず見る（recompose・キャッシュ・安定性は値ごとに辿って確かめる）。新しい Composable ごとに、`remember` / `drawWithCache` / `derivedStateOf` / Modifier の lambda が取り込む値を表にし、各値が recompose で同じインスタンスか・equals が値比較か（getter で毎回作っていないか、data class / `@Immutable` か、`List` の中身が `ImmutableList` か）を全文 md に残す。影響が小さくても見た結果は残し、外すなら理由を書く。直し方のコードはコンパイルが通るか（`@Composable` を `remember { }` の中で呼んでいない等）も確かめる

成果物:
1. ステップ 4 形式の全文を <DIR>/reviews/<N>-<sha 先頭 9 桁>.md に書く。指摘ごとに「前提: … / 確認: <file:line or 未確認>」を添える
2. 投稿文面用の skill（あれば）を読み、検証済みの指摘だけで投稿文面を <DIR>/reviews/<N>-<sha 先頭 9 桁>.comments.md に書く。形:
   - 先頭に `review: <Approve|Comment|Request Changes>` と本文（1〜2 行）
   - inline は `<repo 相対パス>:<head での行番号>` の見出し + コードブロックの文面。1 コメント 1 論点、症状 → 理由 1 文 → 提案の順で短く。機械的に直せるものだけ suggestion ブロック
   - inline の行は `git diff <base>...<head> -- <path>` の @@ hunk 内にあることを確かめる。原因の行が hunk 外なら hunk 内の一番関係する行に付け（複数行なら `:<start>-<end>`）、本文で原因の `ファイル:行` を示す
   - Must / Should には直し方を最初から添える（diff 内の機械的修正は suggestion、diff 外・設計の話は「イメージ」の code fence + 他への影響）。PR 本文に挙動が書かれていれば `>` で引用する
   - nit・任意寄りは原則載せない（載せるなら nit: を付けて 2 件まで）
   - 末尾に「載せなかった指摘」を 1 行ずつ（理由付き）
3. 最終報告は次の 1 行だけ: `verdict=<Approve|Comment|Request Changes> must=<件数> should=<件数> nice=<件数> posted=<文面に載せた件数> top=<Must か Should の先頭 1 件を 60 字以内>`
```

`<workspace>` は repo の親ディレクトリ。

agent の種類は general-purpose。レビューは判断を伴うので model は省略してメインと同じにする。

レビュー agent が中で呼ぶ agent（review-checklist-builder・regression-verifier 等）の報告は、呼んだ agent ではなくメインに届くことがある。メインに届いたら、どの PR 用かを本文から特定し、SendMessage でそのレビュー agent（`rw-<N>`）に要点を転送する。転送しないと、レビュー agent はチェックリストや verdict を持たないまま進むか、取り直しに時間を使う。名前で送れるよう、レビュー agent は `rw-<N>` の name で起動する。

### 4. 結果を記録する

agent が終わるたびに:

- 最終報告の 1 行を読み、`state.json` の該当 PR を更新する（`jq` で書き換える）
- `summary.md` の末尾に 1 行足す（ファイル列は comments.md のパス）
- comments.md の inline の `パス:行` を 2〜3 件抜き取り、`git show <sha>:<path> | sed -n <行>p` で指している行が文面の内容と合うかを確かめる。ずれていたら summary の行に「行番号要確認」と書く
- 同じ agent が転送を受けて報告を出し直したら（件数が変わる）、state と summary の該当行を直す
- 報告の形が崩れていたら、reviews の md を開いて総合評価と件数を自分で拾う。md が無ければ state は更新せず（次の周でやり直す）、summary.md に「失敗」と書く

### 5. 通知と次の予約

- この周で 1 件以上レビューしたら、全部終わった時点で PushNotification を 1 回だけ送る。内容は件数と、Request Changes / Must ありの PR 番号。例: `review-watch: 3件完了。Must あり #87(2) #81(1)。~/.cache/review-watch/…/summary.md`
- 0 件なら通知しない
- `/loop` から起動されている時は、ScheduleWakeup で 1800 秒後を予約する（prompt は起動時の `/review-watch <repo>` をそのまま渡す。0 件の周は `noop: true`）。agent が動いている間は予約しない（終了通知で起こされる）

## やらないこと

- GitHub への投稿・approve・re-request。comments.md を読んで投稿するかはユーザーが決める
- 自分の PR と draft のレビュー
- push されただけの PR の再レビュー（re-review の依頼が来るまで待つ）
