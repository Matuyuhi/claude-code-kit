---
name: pre-push-quality-checks
description: push・PR 作成の前に、その repo の CI が PR に対して走らせるチェックと同じものをローカルで実行し、エラーを 0 件にする。チェックコマンドは決め打ちせず、CI 設定・package.json scripts・Makefile・CLAUDE.md 等から repo ごとに特定する。ユーザーが「push 前チェック」「PR 出す前に確認して」と言った時、または push / PR 作成を依頼された時に使う。
---

# pre-push-quality-checks

PR で CI が落ちると、レビュー依頼後に修正 commit が積まれる。push 前に CI と同じチェックを手元で通しておくのが目的。何を走らせるかは repo ごとに違うので、毎回 repo から特定する。

## 1. チェック対象を特定する

CI が PR に対して実行する job を基準にする。ローカルの script 名から推測するより、CI 設定のほうが「何が通れば merge できるか」の正確な定義になっている。

探す場所:

- `.github/workflows/*.yml` — `on: pull_request` / `pull_request_target` で起動する job。`paths` / `paths-ignore` フィルタがあれば、今回の変更ファイルが該当するかも見る（該当しない job はこの PR では走らない）
- `.circleci/config.yml`、`bitrise.yml`、`.gitlab-ci.yml`、`Jenkinsfile` など他の CI 設定。workflow のブランチフィルタで PR 時に走るものを選ぶ
- git hook 系: `.husky/`、`lefthook.yml`、`.pre-commit-config.yaml`（push 時に走るものは CI と同じ扱い）
- CI の各 step が呼んでいるコマンドの定義元: `package.json` scripts、`Makefile`、`Taskfile.yml`、gradle タスク、`scripts/` 配下
- repo の `CLAUDE.md` / `CONTRIBUTING.md` / `docs/`、memory plugin を使っていれば `~/.claude/knowledge/projects/<repo>/`。ローカル実行の制約（flavor の指定、CLI からのビルドを避ける等）が書かれていればそれに従う

CI 設定が無い repo では、上記のローカル定義から fix / format / type check / lint / test に当たるものを拾う。

特定した job ごとに、ローカルで再現できるかを分ける。secret や専用 runner が必要なもの、デプロイ、VRT のように CI 上の成果物と比べる前提のものは再現できない側に入れる。実行前に、対応表（CI job → ローカルで打つコマンド / 再現不可の理由）をユーザーに短く示す。

## 2. 実行する

- CI の step と同じコマンド・引数で打つ（flavor・対象モジュール・設定ファイルの指定まで揃える）。近いだけのコマンドで代用すると、手元で通って CI で落ちる
- 依存のインストール（`npm ci`、`bun install`、`bundle install` 等）が要る場合は、依存の追加・更新になるので実行前に確認を取る
- 順序は、自動修正・整形 → 静的チェック（型・lint）→ テスト。自動修正でファイルが変わったら、何が変わったかを示す
- テストが長時間かかる場合は、全部回すか変更箇所に関係する範囲に絞るかをユーザーに聞く

## 3. エラーに対応する

エラーが 0 件になるまで push・PR に進まない。自分の変更で出たエラーかどうかは問わない（CI は区別せずに落ちる）。

ただし既存エラーの修正は依頼範囲外の差分になる。修正は自分の変更分と既存分に分けて報告し、既存分が大きい（件数が多い・別領域に及ぶ）場合は、直す前にユーザーに相談する。

`@ts-ignore` / `any` / `@Suppress` / `//nolint`、lint baseline への追加などでエラーを隠す場合は、先にユーザーの承認を取る。

## 4. 報告して止まる

報告する内容:

- 実行したチェックと CI job の対応、それぞれの結果
- 修正した内容（自分の変更分 / 既存エラー分）
- ローカルで再現できなかった CI job とその理由（PR 上の CI で確認が必要なもの）

commit / push / PR 作成は、ユーザーの明示的な承認があってから行う。
