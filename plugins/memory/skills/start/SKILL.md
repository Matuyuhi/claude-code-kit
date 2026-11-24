---
name: start
description: セッション最初の作業指示の入口。「/start <指示・URL>」の形で、実装・修正・調査・レビューなど通常の指示に前置して使う。指示とリンクを解析し、対象領域に応じた skill を確実に読み込み、knowledge を照会してから通常ワークフローで作業に入る。手動では「/start Notion リンク これ実装して」のように使う。
---

# /start — 作業開始の入口

作業の種類に合った skill と knowledge を、「読んだつもり」ではなく確実に読み込んでから着手する。skill が自分から発動するかはモデル任せで安定しないので、その対策として置いている。

セッション冒頭専用ではない。途中で作業の種類や対象が変わった時（実装 → レビュー、Android → Go 等）も、新しい指示に `/start` を前置して呼び直してよい。その時点の指示で 2 の表を当て直し、新しく当たった skill だけを読む。読み込み済みの skill は読み直さない。

CLAUDE.md に書いてあるルール（publish は明示承認後・セキュリティ確認 等）があれば、この skill より常に優先する。

下の表の skill は guides・review・git-workflow の各 plugin にある。入れていない plugin の skill は飛ばす。

## 1. 指示を読み取る

引数から次の 3 つを取り出す。

- やること: 実装 / 修正 / レビュー / 調査 / 設計 / SQL 作成 のいずれか
- 対象: repo・領域（Android / iOS / Go / Web / データ）・ファイル。引数から分からなければ cwd から判断する。それでも曖昧なら、着手前に 1 回だけ確認する
- URL: あれば本文より先に取得して、仕様・文脈を把握する

| URL | 取得手段 |
|---|---|
| Notion | Notion MCP（notion-fetch） |
| GitHub PR / issue | `gh` |
| Slack | `mcp__claude_ai_Slack__slack_read_thread`（スレッド全文） |
| その他 | WebFetch |

## 2. skill を読み込む

下の表で当たった行の skill を、Skill tool でこの場で必ず読み込む。複数当たれば全部読む。どれにも当たらなければ何も読まずに進む（無理に読まない）。

| 対象・作業種別 | 必ず読む skill |
|---|---|
| Web UI コンポーネントの新規作成・編集 | web-ui-guidelines, design-implementation-guide |
| PR レビュー | この skill での前処理は不要。/review-pr の経路に乗せる |
| 設計・実装方針を決める作業（実装・修正の着手前を含む） | design-approach |
| コードを書く・直す作業すべて | code-quality-principles |
| 「commit」「push」「pr」等の publish 指示 | publish |
| 「手元の差分」「stash」「現状」「再開」 | wip |
| 「説明して」「わかりやすく」「〜とは」 | explain-plainly |

自分の判断基準をまとめた `persona` skill を置いている場合は、CLAUDE.md から `@` で import して常に読み込む形にしておくと、ここで読む必要が無い。

## 3. knowledge を照会する

- `~/.claude/knowledge/INDEX.md` の目次と対象領域を突き合わせ、関係しそうな項目があれば該当ファイルを Read する（目次の 1 行だけで判断しない）
- 対象 repo 名・主な技術キーワードで 1 回 grep し、目次に無い関連ファイルも拾う

  ```bash
  grep -ril "<キーワード>" ~/.claude/knowledge --include='*.md' --exclude='INDEX*.md' --exclude='README.md'
  ```

- このステップは knowledge-searcher agent（haiku）に委譲してよい。返るのはパスと原文の抜粋だけなので、関連するか・採るかの判断はメインで行う

## 4. 作業に入る

1. 読み込んだ skill 名を 1 行で報告する（例:「適用: design-approach, code-quality-principles」）。発動したかをユーザーが目で確かめられるようにするため
2. 通常の進め方（方針の提案 → 計画 → 実装 → 報告して止まる。CLAUDE.md に決まりがあればそれに従う）で作業に入る

対象が Android の時は、作業の種類を問わず次を使う。調査だけの作業でも効く。

- Kotlin シンボルの宣言・参照を探す時は、素の grep ではなく `android studio find-declaration <symbol>` / `find-usages <symbol>` を優先する（IDE のインデックスを使うので精度が高い）。使う前に `android studio check`
- 文字列・リソース・正規表現の検索や、複数クローンが開いていて project を解決できない時は Grep に切り替える

## メンテナンス

- 「読んでほしかった skill が読まれなかった」ことがあったら、2 の表に行を足す
- 将来 hook で自動の router を作る時は、この表をそのまま使う
