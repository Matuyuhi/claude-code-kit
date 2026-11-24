# Codex 並走の注意点（ステップ 2.2 / 3.5）

SKILL.md のコマンドがそのまま動かなかった時、初めて回す時に読む。

## パスと起動

- パスに `$TMPDIR` を使わない。sandbox 内の Bash では `/tmp/claude-<uid>`、sandbox を外した Bash では `/var/folders/.../T` を指し、worktree を作った側と読む側で別のディレクトリになる（2026-11-09 の試走で実際にすれ違った）。system prompt にある scratchpad の絶対パスを書き込む
- 最後の `node` 行は Bash ツールを `run_in_background: true` で起動する。companion の `review` は `--background` を付けても自分では detach しない（detach するのは `task` だけ）ので、並走させるには Claude Code 側で background にするしかない。終了通知が来たら出力ファイルを読む
- 出力は本文テキスト（要約の後に `- [P1] 見出し — path:line-line` の形で指摘が並ぶ。P0 が最重）。`verdict` / `findings` の構造化 JSON は built-in review には無い。出力言語は英語になることがある

## 動かない時

- worktree を使うのは、ユーザーの working tree を切り替えないため。`git worktree add` も `.git/worktrees/` に書くので、`.git` が書けない環境では checkout と同様に失敗する。その時はこの手順を飛ばす。既に同じ PR の worktree があれば使い回す（`git worktree list`）
- Codex の runtime は `~/.codex` に、companion は `~/.claude/plugins/data/codex-openai-codex/state/` に書くので sandbox 内では動かない（EPERM）。実行を拒否されたら、コマンドをユーザーに渡して結果を貼ってもらうか、この手順を飛ばして「外部レビュー: 未実施」と書く
- subagent の中で review-pr を回すと sandbox で必ず止まる（2026-11-13 のバックテスト 4 件すべてで EPERM）。Codex 込みで回したい時はメインの session で実行する
- Codex が使えない時はレビューを止めない。ステップ 4 の「外部レビュー」欄に未実施と理由を 1 行書く

## 確認済みの挙動

2026-11-09 に Terraform 1 ファイルの PR で通しで確認した。`--base origin/master` のような remote-tracking ref は native review がそのまま受け付け、Codex は persona skill を自分で読み（続けて読んだ skill 名はログが切れていて未確認）、PR 本文に無い関連ファイル（workflow・Makefile・既存 IAM）まで rg で当たってから「指摘なし」を返した（約 4 分）。

## 採否の補足（ステップ 3.5）

見送りの理由は、AI レビューの指摘が退けられる 3 つの型（diff 外の事情を知らない・仕様の勘違い・既存に揃えた意図的な書き方）のどれかで言えることが多い。言えないなら本当に見送ってよいかもう一度見る。
