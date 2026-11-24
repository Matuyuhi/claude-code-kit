---
name: commit
description: 現在の変更を、repo の既存スタイルに合わせた短い commit message で commit する。ユーザーが「commit して」「/commit」「コミットして」と言った時に必ず使う。message の生成ルール（過程を書かない・短く・repo の log に合わせる）と trailer 規約を含む。
---

# /commit — personalize された commit

このユーザーの commit message 観に合わせて commit する。message は「diff の最終状態」だけを書く。作業の過程は書かない。

## 手順

### 1. 変更内容の確認

```
git status
git diff HEAD --stat
```

- 今回のタスクに関係するファイルだけを stage する。無関係な変更・untracked ファイルが混ざっていたら、勝手に含めず「これも含めますか？」と確認する
- 機密ファイル（`.env`, credentials, 秘密鍵等）が含まれていないか一瞥する

### 1.5. コメント品質チェック（MUST — コード変更を含む場合）

コード変更（ドキュメント・設定ファイルのみの commit は除く）を stage する前に `code-comment-cleanup` skill を Skill ツールで呼び出す。`mode=apply min_confidence=high` を明示する（高確信度のみを対象にし、`/commit` の毎回の摩擦を抑える。中確信度以下の監査は `review-pr` に任せる）:

```
Skill({skill: "code-comment-cleanup", args: "mode=apply min_confidence=high"})
```

高確信度の該当が無ければこのskillは何も聞かずに一言で終了する（`/commit` の「呼び出し自体が承認」という前提を壊さない）。該当があった場合のみ、提示された項目をユーザーに確認の上で適用してから次のステップに進む。

### 2. repo のスタイルを採取

```
git log --format='%s' -15
```

直近の subject から以下を模倣する:

- 言語: 英語 / 日本語 / 混在 — repo の多数派に合わせる
- トーン・長さ: 個人 repo なら「add readme」「update config」級の超簡潔も可。仕事 repo なら「Add batch lookup for user orders」のような imperative 一文
- prefix 慣習: `feat:` / `fix:` 等の conventional commits を repo が使っていればそれに従う。使っていなければ付けない

### 3. message を書く

Subject（1 行目）:

- diff が「何になったか」を imperative で 1 行。50 文字目安、長くても 72 文字以内
- 変更が複数あっても列挙しない。最も意味のある一言に丸める

Body:

- 原則書かない。Why が subject に収まらない時だけ 1〜3 行
- ファイル一覧・変更点の箇条書きの body は書かない（diff を見れば分かる）

Trailer:

```
Co-Authored-By: Claude <モデル名> <noreply@anthropic.com>
```

のみ。`<モデル名>` は今回の commit を書いている実行中モデルの表示名（例: `Fable 5.2`, `Opus 5.5`, `Sonnet 5.5`, `Haiku 5.5`）に置き換える。固定文字列 "Claude" 単体では書かない。Claude-Session の URL は付けない。

### 4. commit と報告

```
git add <対象ファイル> && git commit -m "..."
```

commit 後は `git log -1 --oneline` 相当の 1 行で報告する。push はしない（別途明示指示があった時のみ）。

## 禁止事項 — message に書かないもの

commit message は「コードがどうなったか」の記録であり、「Claude がどう作業したか」の日誌ではない。以下は subject にも body にも一切書かない:

- 試行錯誤・失敗の経緯: 「〜が失敗したので」「当初〜を試したが」「〜では動かなかったため」
- 会話・指示への言及: 「レビュー指摘に対応」「ユーザーの要望により」「as requested」
- 自己弁護・正当化: 「これが正しいアプローチである」「安全のため」（Why として本質的な制約なら可。感想は不可）
- ツール・環境の話: 「Edit ツールで修正」「Claude Code で生成」
- 網羅的な変更列挙: 「また、〜も修正。さらに〜も更新」— 意味の単位が違うなら commit を分けることを提案する

### 例

| ❌ Bad | ✅ Good |
|--------|---------|
| `Fix build error by adding missing import after typealias approach failed due to KT-79781` | `Add missing import in ItemListViewModel` |
| `Update SKILL.md to address user feedback about verbose commit messages and also fix typo` | `Tighten commit message rules` |
| `レビュー指摘を受けて余白の補正を修正、あわせてテストも更新` | `余白の補正を送信ボタンにも適用` |

## 前提

- `/commit` の呼び出し自体が commit の明示承認。改めて「commit して良いですか？」とは聞かない（stage 対象が曖昧な時の確認は除く）
- commit 粒度は「レビューに値するまとまり」。直前の作業が複数の独立した変更を含むなら、1 commit に押し込まず分割を提案する
- 「commit push」「commit draft pr」「pushまで」のように push 以降を含む指示は `publish` skill の担当。この skill は commit で止まる
