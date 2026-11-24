---
name: remember
description: 会話中の事実・知見・好みを横断メモリ ~/.claude/knowledge/ に保存する。ユーザーが「これ覚えて」「remember して」「メモして」「知識に追加して」と言った時、または将来のセッションでも使う事実（プロジェクトの慣習・状況・ユーザー設定・外部リソース等）を保存すべき場面で使う。手動では「/remember <内容>」。セッション全体の振り返りは /reflect、セッションの作業記録は /journal。
---

# /remember — 横断メモリへの保存

`~/.claude/knowledge/` に 1 事実 = 1 ファイルで保存する。ここは全セッションから読まれる中央の置き場で、目次（`INDEX-short.md`）が CLAUDE.md に import されており、本文は /recall が引く。

built-in auto-memory（`~/.claude/projects/*/memory/`）には書かない。あちらはプロジェクト（クローンパス）ごとにしか読まれないので、置き場は knowledge に一本化する。

## 1. 保存する内容を 1 つに絞る

引数があればそれ。無ければ直近の会話から「将来のセッションでも使う事実」を 1 つ選ぶ。

- コード・git log から読み取れる情報は保存しない
- この会話限りの情報は保存しない
- 解釈に自信が無い内容は、保存前にユーザーへ確認する

## 2. 置き場所を決める

| 内容 | 保存先 |
|---|---|
| ユーザー属性・全プロジェクト共通の好み・横断で使う reference | `global/` |
| 特定リポジトリの慣習・状況・reference | `projects/<repo名>/`。クローンパスや slug ではなく repo 名（例: example-app-android） |
| 特定 repo に閉じない技術領域の知見 | `tech/<domain>/`（android / ios / go / web 等） |

## 3. 同じ話題のファイルが無いか探す

`~/.claude/knowledge/INDEX.md` を読み、本文も grep する。目次とジャーナルは事実のファイルではないので除く。

```bash
grep -ril "<キーワード>" ~/.claude/knowledge --include='*.md' --exclude='INDEX*.md' --exclude='README.md' --exclude-dir=sessions
```

- 同じ話題のファイルがあれば、新しく作らずそのファイルを Edit で更新する
- 既存の内容と矛盾する時は、新しい内容を正として書き換える

## 4. 書く

書き込み先は実体のパスにする。`~/.claude/knowledge` を別の場所への symlink にしている場合に備えて、先に解決する。

```bash
readlink -f ~/.claude/knowledge
```

ファイル名は kebab-case で、frontmatter の `name` と揃える。

```markdown
---
name: <kebab-case-slug>
description: <一行要約。INDEX と /recall の検索対象になるので具体的に書く>
metadata:
  type: user | feedback | project | reference | tech
  repo: <repo名>          # projects/ 配下のみ
---

<本文。feedback は **Why:** と **How to apply:** を付ける>
```

`tech` は、特定の repo や指摘に紐づかない技術的な事実（ツール・ライブラリ・クラウドの挙動）に付ける。

## 5. 目次を作り直して報告する

```bash
rebuild-index.sh
```

保存先のパスと要約を 1 行で報告する。
