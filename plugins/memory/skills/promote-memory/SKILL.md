---
name: promote-memory
description: ~/.claude/projects/*/memory/ 配下に蓄積された auto-memory ファイルを横断スキャンし、将来も使える学び（フィードバック・好み・全プロジェクト共通ルール・技術領域別の知見）を抽出して ~/.claude/knowledge/、~/.claude/CLAUDE.md、または ~/.claude/skills/ 配下の該当 skill SKILL.md に昇格させる。memory ファイル自体は削除せず残す。ユーザーが「memory を整理して」「memory から学びを CLAUDE.md に上げて」「promote memory」と求めた時、または定期的な棚卸し時に使う。手動では「/promote-memory」で呼ぶ。reflect（現在の会話を振り返る）と違い、過去セッションで auto-memory が蓄積した内容の棚卸し用。
---

# /promote-memory — auto-memory に溜まった学びを全セッションで効く場所へ上げる

built-in auto-memory（`~/.claude/projects/*/memory/`）はプロジェクト（クローンパス）ごとにしか読まれない。そこに溜まった memory ファイルを横断して読み、今後も使う学びを knowledge / CLAUDE.md / skill に上げる。reflect が「いまの会話」を対象にするのに対し、こちらは過去のセッションが残した分の棚卸し。

## 守ること

- memory ファイルは読むだけ。削除も書き換えもしない。上げた後も残す。MEMORY.md も触らない
- 書き込み先は `~/.claude/knowledge/`、`~/.claude/CLAUDE.md`、`~/.claude/skills/` 配下の SKILL.md だけ。plugin で入れた skill（`~/.claude/plugins/cache/` 配下）は更新で上書きされるので書かない
- プロジェクト配下の `.claude/CLAUDE.md` や `CLAUDE.md` を新しく作らない・編集しない（既にあっても触らない）。候補としても出さない。プロジェクト固有の学びは `~/.claude/knowledge/projects/<repo名>/` に上げる
- ユーザーの承認なしに書かない。必ず候補を見せて確認を取る

## 1. memory を全部集める

```bash
find ~/.claude/projects -path '*/memory/*.md' ! -name MEMORY.md
```

見つかったファイルをすべて Read する。MEMORY.md は目次なので対象にしない。

## 2. 上げる先の現状を読む

重複と矛盾を判定するために読む。

- `~/.claude/CLAUDE.md`。symlink にしている場合に備えて `readlink -f ~/.claude/CLAUDE.md` で実体を解決してから Read する
- `ls ~/.claude/skills/` で skill の一覧を見て、合いそうな skill の SKILL.md を Read する
- `~/.claude/knowledge/INDEX.md`

## 3. memory を 1 件ずつ分類する

frontmatter の `metadata.type` だけで決めず、必ず本文を読んで判断する。

| 分類 | 当てはまるもの | 行き先 |
|---|---|---|
| (a) skill に上げる | 特定の技術領域に閉じた学びで、既存の skill に合う | その skill の SKILL.md |
| (b) global に上げる | 毎セッション必要な行動ルール・スタイル・好み | `~/.claude/CLAUDE.md` |
| (c) knowledge に上げる | プロジェクト固有の慣習・状況・reference、skill の無い技術知見 | `~/.claude/knowledge/` の該当 scope |
| (d) 既に上がっている | knowledge / CLAUDE.md / SKILL.md に同じ内容がある | スキップ、または既存を更新 |
| (e) 上げない | 一時的・既に古い | memory に残すだけ |

判断の問いは 3 つ。「複数プロジェクトで同じ判断をするか」「既存の skill の話題に当たるか」「将来の参照価値があるか」。前の 2 つが No でも参照価値があれば knowledge に上げる。上げないのは一時的なものと古くなったものだけ。

### (a) skill の当て方

先に skill に合うかを見る。`ls ~/.claude/skills/` の一覧と各 skill の description・内容に照らして決める。

| 内容 | 上げる先の skill |
|---|---|
| 技術領域ごとの知見（iOS / Android / Go 等） | 自分で持っている `<platform>-guide` skill（`/learn-from-prs` で作れる） |
| コメント・命名・エラーハンドリング等のコード品質一般原則 | 自分で置いたコード品質の skill。無ければ `~/.claude/knowledge/tech/` |
| その他、description に明確に当たる自分の skill がある | その skill |

### skill に合わない時の当て方

| memory type | 内容 | 上げる先 |
|---|---|---|
| `feedback` | 全プロジェクト共通の作業スタイル・好み | `~/.claude/CLAUDE.md` |
| `user` | ユーザーの属性・スキル・役割 | `~/.claude/CLAUDE.md` |
| `reference` | 全プロジェクト横断で参照する外部リソース | `~/.claude/CLAUDE.md` |
| `feedback` / `project` / `reference` | 特定プロジェクトに閉じる | `~/.claude/knowledge/projects/<repo名>/`（形式は /remember に従う） |
| 問わない | skill も repo も無い技術領域の知見 | `~/.claude/knowledge/tech/<domain>/` |

### 上げる内容の基準

- 具体的で、そのまま行動に移せる書き方にする（「コードをきれいに書く」ではなく「関数は20行以内に収める」）
- コードや git log から読み取れる情報は上げない
- 一時的・特定タスク限定の情報は上げない
- Why が memory に書かれていれば、上げた先にも残す
- 既存と重複する内容は足さない

## 4. 候補を見せて承認を取る

次の形で番号付きで出す。

```
昇格候補（skill → ~/.claude/skills/<name>/SKILL.md）:
1. [project-slug / memory-name] 要約一行
   → 追加先: ~/.claude/skills/<name>/SKILL.md, セクション: ## XXX
...

昇格候補（global → ~/.claude/CLAUDE.md）:
N. [project-slug / memory-name] 要約一行
   → 追加先セクション: ## XXX
...

昇格候補（knowledge → ~/.claude/knowledge/<scope>/）:
M. [project-slug / memory-name] 要約一行
   → 保存先: ~/.claude/knowledge/projects/<repo名>/<slug>.md
...

スキップ（既存と重複 / 陳腐化）:
- [project-slug / memory-name] 理由
...

どれを昇格しますか？（番号指定 / all / none）
```

- 上げる価値のある memory が 1 つも無いことは普通にある。無理に捻り出さない
- 候補が多い時は「特に重要なもの 5〜10 件」に絞って見せる。一度に足しすぎると CLAUDE.md / SKILL.md が膨らむ
- 既存のルールと矛盾する候補は、新しい方を正として既存を更新する案にし、その旨を候補に書いて確認を取る

## 5. 承認された候補だけ書く

- `Edit` で既存のセクションに追記する。合うセクションが無ければ新しく作る。書き方は既存に合わせ、skill なら章立てに沿った位置に入れる
- `~/.claude/` 配下を別の場所への symlink にしている場合は、symlink 経由だと Edit が拒否されることがあるので、`readlink -f` で解決した実体パスに対して編集する
- knowledge に保存した時は目次を作り直す

  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/rebuild-index.sh"
  ```

- 何をどこに足したかを 1 行ずつ報告する
- `~/.claude/CLAUDE.md` が膨らんできたら `/compact-claude-md` を案内する
