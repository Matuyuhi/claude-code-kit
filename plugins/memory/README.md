# memory

セッションをまたぐ記憶を `~/.claude/knowledge/` に置き、保存・検索・振り返りを skill で回す plugin。

## データの置き場

データは plugin の外、`~/.claude/knowledge/` に置く（`KNOWLEDGE_DIR` で変更可）。plugin を更新・削除してもデータは残る。

```
~/.claude/knowledge/
├── INDEX.md            # 自動生成の全目次
├── INDEX-short.md      # 自動生成の縮約目次。CLAUDE.md から @ で常時読み込む
├── global/             # 全プロジェクト共通（user 属性・横断 feedback・reference）
├── projects/<repo名>/  # リポジトリ別の事実
├── tech/<domain>/      # android / ios / go 等の技術領域別
└── sessions/           # セッションジャーナル（1 セッション = 1 ファイル + 専用 INDEX.md）
```

初回は `mkdir -p ~/.claude/knowledge/{global,projects,tech,sessions}` で作り、`~/.claude/CLAUDE.md` に次の 1 行を足すと縮約目次が毎セッション読み込まれる。

```
@~/.claude/knowledge/INDEX-short.md
```

## 中身

- skills: `/remember`（事実 1 件）・`/recall`（検索）・`/journal`（作業記録）・`/reflect`（振り返り）・`/sessions`（過去セッション探索）・`/start`（作業の入口）・`/now`（現状まとめ）・`/promote-memory`（auto-memory の昇格）・`/compact-claude-md`（CLAUDE.md を情報を落とさずに縮める）
- agent: `knowledge-searcher`
- bin（plugin を有効にすると PATH に載る）:
  - `rebuild-index.sh` — frontmatter から INDEX.md / INDEX-short.md / sessions/INDEX.md を再生成
  - `list-transcripts.sh` — 過去セッションの「最終活動日時 | プロジェクト | タイトル | transcript パス」一覧（端末から直接実行すると選んで再開できる）
  - `audit-carryover.sh` — ジャーナルに書いたまま skill に入っていない学びを洗う
- hook: `~/.claude/knowledge/` 配下の .md を Write / Edit した後に `rebuild-index.sh` を走らせる（PostToolUse）

ファイル形式は built-in auto-memory と同じ frontmatter（`name` / `description` / `metadata.type`）。詳細は `/remember` の SKILL.md。
