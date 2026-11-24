---
name: publish
description: 「commit」「push」「draft pr」「pr出して」「commit push」「pushだけ」「分けてcommit」「commitはせず」「A,Bそれぞれdraftで」のような一言の publish 指示を受けた時に必ず使う。指示の語から「どこまで（commit / push / PR）・どの範囲（全部 / 分ける / 一部）・どの形（draft / ready / trailer なし）」を読み取り、commit → pre-push-quality-checks → PR 作成の順に既存 skill を呼んで、指示された所で止まる。「/publish」で手動実行も可。Claude Code 組み込みの /ship（PR を merge まで見張る）とは別物。
---

# publish — 一言の publish 指示を既存 skill の連鎖に落とす

ユーザーは commit〜PR を「commit」「push」「prで」のような 1〜3 語で指示する（2026-09〜10 の 90 セッション中 21 セッションで出現）。毎回この語を解釈して手順を組み立て直しているので、ここに固定する。

前提: この skill を呼ぶ時点で、指示された範囲の publish は承認済み。改めて「commit して良いですか」とは聞かない。ただし指示に無い段階（「commit」と言われて push する等）には進まない。

## 1. 指示を 3 軸に分解する

| 軸 | 語 | 解釈 |
|---|---|---|
| どこまで | `commit` / `commitして` / `commitだけ` | commit で止まる。push しない |
| | `push` / `pushだけ` / `pushして` | commit（未 commit があれば）→ push。PR は作らない。既に PR がある branch なら push で PR が更新される |
| | `pr` / `prで` / `draft pr` / `pr出して` / `pushからのdraft prまで` | commit → push → PR 作成 |
| 範囲 | 無指定 | 今回のタスクに関係する変更すべて |
| | `分けてcommit` / `それぞれ分けて` / `1戻す 2 分けてcommit` | 意味の単位ごとに複数 commit。分け方を 1 行ずつ示してから実行 |
| | `〜だけ先にpush` / `work/xxx だけ` | 指定 branch・指定ファイルのみ。他は触らない |
| 形 | `draft` / 無指定 | PR は draft で作る（既定） |
| | `ready` / `draft外して` / `reviewに出す` | ready for review |
| | `co-authのtrailerなしで` / `trailerなし` | commit の Co-Authored-By を付けない |
| | `commentはせず` / `コメントなし` | PR コメント・issue コメントは書かない |
| | `issueへのlink追加しつつ` | PR 本文に issue リンクを入れる |

複数の指示が並ぶ（例: `A,Bそれぞれdraftのままで出して`）時は、対象ごとに上の表を当てる。

読み取れない語があれば、作業に入る前に 1 行で確認する（「`それで` は push まで、で合っていますか？」）。

## 2. 実行順（止まる位置は 1 で決めた所）

1. 手元の状態を見る: `git status --short` / `git stash list` / 現在 branch と upstream。無関係な差分・untracked・stash があれば、含めるかを先に 1 行で聞く（`/wip` skill の出力形式で良い）
2. 対象 branch を確認する: default branch 上にいる時は、その repo の直近の log を見る。PR の merge を経ずに default branch へ直接 commit している repo なら、そのまま commit する。PR 経由の repo なら、repo の命名（`work/...` 等、`git branch -r | head` で確認）に合わせて作業 branch を切ってから commit する
3. Codex レビュー: commit する差分にコードが含まれる時、Codex の built-in review に見せる（下の「3. Codex レビュー」）。指摘があれば表にして止まる。無ければ黙って次へ。md・設定の文面だけの差分は飛ばし、報告に「Codex: 対象外（文面のみ）」と 1 行書く
4. commit: `commit` skill を Skill ツールで呼ぶ（コメントチェック・message 規約はそこに任せる）。「分けて」の時は commit 単位ごとに呼ぶ
5. push 前チェック: push 以上に進む時は `pre-push-quality-checks` を呼ぶ。エラーが残る間は push しない。修正が自分の変更以外に及ぶなら止まって報告
6. push: `git push -u origin <branch>`。force は使わない。non-fast-forward で拒否されたら、原因（remote の先行 commit・rebase 済み等）を示して止まり、`--force-with-lease` で良いかを聞く
7. PR: PR 本文用の skill があれば呼び、無ければ repo の PR テンプレートと過去の PR に合わせてタイトル・本文を作り、`gh pr create --draft`（ready 指定時は `--draft` なし）。base は repo の慣習（develop / main / 親 PR の branch）を `gh pr list` や既存 PR から確認する。スタック PR なら親 branch を base にする
8. 報告: 1 行ずつ。commit hash と subject / push 先 / PR URL。Codex レビューの結果（指摘なし / 指摘 n 件のうち採用 m 件）。止めた理由があればそれも

## 3. Codex レビュー（commit の直前）

この skill は「publish は承認済み」が前提で、途中で止まるのは pre-push-quality-checks のエラー・push の non-fast-forward と、この Codex の指摘の 3 つ。目的は、挙動を変える差分に別モデルの目を commit 前に 1 回通すこと。Codex の built-in review は `~/.codex/AGENTS.md`（CLAUDE.md）と persona・各 guide の skill を自分で読むので、基準の指示文は渡さなくてよい（`external-review-brief` の試走記録）。

```sh
COMPANION=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | tail -1)
node "$COMPANION" review --wait --scope working-tree
```

出力は本文テキスト。先頭に要約、続いて `Review comment:` の下に `- [P1] 見出し — path:line-line` の形で指摘が並ぶ（P0 が最重、P3 が最軽）。`--json` を付けても `codex.stdout` に同じ本文が入るだけで `verdict` / `findings` は無い（構造化 JSON は `adversarial-review` のみ）。

- 対象は未 commit の差分全体（staged + unstaged + untracked）。「分けて commit」の時は 1 回だけ全体に走らせ、指摘を commit 単位に振り分ける
- 「〜だけ」「指定ファイルのみ」の時も working tree 全体が見られる。対象外ファイルへの指摘は報告に含めず捨てる
- Codex の runtime は `~/.codex` に書くので sandbox 内では動かない。実行を拒否されたら、上の 2 行をユーザーに渡して結果を貼ってもらう
- 常に `--wait` で待つ（小さな差分で約 1 分）。この時点で手順 1〜2 は済んでいて並行できる作業が無いので background にしない。companion の `--background` は `review` では detach しない（detach するのは `task` のみ）
- Codex が使えない（未ログイン・CLI 不在・タイムアウト）時はこの手順を飛ばし、報告にその旨を 1 行書く。publish を止めない

結果の扱い:

- `[P0]`〜`[P3]` の行が 1 つも無い: 何も表示せず commit へ
- 指摘がある: 次の表を出して止まる。採否はユーザー。「進めて」で commit へ、「直して」なら修正後にもう一度この手順から

| # | 優先度 | file:line | 指摘 | 裏取り | 判断案 |
|---|---|---|---|---|---|

- 「裏取り」は Claude が確かめた結果を書く。diff 外の事情（先行 commit・既存の同種実装・仕様）で成立しない指摘はそう書き、判断案を「見送り」にする（`external-review-brief` の「返ってきた指摘の扱い」）。確かめられなかったものは「未確認」
- 指摘を元に修正した場合も commit message には書かない（`commit` skill の禁止事項）

## 4. やらないこと

- 指示に無い段階へ進む（「commit」で push、「push」で PR）
- `--force` / `--no-verify` / `git add -A` の無断使用
- PR コメント・レビュー依頼の投稿（別途「レビュー依頼して」等の指示が要る）
- 既存 PR の本文の全文差し替え（ユーザーが手で編集している本文を消してしまう。直したい所は提示して反映は任せる）
- push 前に origin を fetch せずに「本番も同じ」等を断定する（古い origin ref で判断を誤る）

## 5. 既に PR がある branch への「push」

- push だけで PR は更新される。PR 本文の更新は、差分の性格が変わった時だけ提案する（勝手に書き換えない）
- レビュー指摘への対応 commit を push した後、返信コメントは書かない（下書きを出し、投稿はユーザー）

## 関係する skill

- `commit` — message 規約・コメントチェック
- `pre-push-quality-checks` — CI 相当のローカルチェック
- `wip` — 手元の差分・stash の棚卸し（この skill の手順 1 と同じ出力）
- `external-review-brief` — Codex の指摘を採否する時の裏取り基準。codex plugin の built-in review にはブリーフ不要
