---
name: recall
description: 横断メモリ ~/.claude/knowledge/ から過去の知見・事実・慣習を検索して思い出す。ユーザーが「〜について覚えてる？」「前に何か決めてなかったっけ」「knowledge 確認して」と聞いた時、または実装・レビュー着手前に対象 repo / 技術領域の過去フィードバックを確認したい時に使う。手動では「/recall <キーワード>」。過去セッションの作業内容の探索は /sessions。
---

# /recall — 横断メモリの検索

`~/.claude/knowledge/` に保存した事実・慣習を探して答える。過去の作業の経緯や手順を探す時は /sessions を使う。

## 1. 目次から探す

`~/.claude/knowledge/INDEX.md` を Read し、description が話題に合う行を探す。常時 import されている `INDEX-short.md` は global 以外が名前だけなので、説明付きの `INDEX.md` を改めて読む。

## 2. 目次で見つからなければ本文を grep する

```bash
grep -ril "<キーワード>" ~/.claude/knowledge --include='*.md' --exclude='INDEX*.md' --exclude='README.md' --exclude-dir=sessions
```

- キーワードは表記ゆれ（日本語 / 英語・類義語）を 2〜3 通り試す
- 目次・README・ジャーナル（`sessions/`）は除いている。ジャーナルは /sessions の担当

## 3. 本文を Read してから答える

- 目次の 1 行だけで答えない。Why / How to apply に要点が書かれていることが多い
- `type: project` のものは書かれた日付・時点を確認し、古い可能性があればその旨を添える

## 4. 見つからない時

1. built-in auto-memory も探す

   ```bash
   grep -ril "<キーワード>" ~/.claude/projects --include='*.md'
   ```

   見つかったら、その内容で答えたうえで knowledge への取り込み（/remember）を提案する
2. セッション単位の記録が要りそうなら /sessions を案内する
3. それでも無ければ「記録なし」と答える。無理に捻り出さない
