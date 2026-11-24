---
name: external-review-brief
description: Codex の adversarial-review に差分レビューを頼む直前、または Codex / Copilot を直接使っていて「このユーザーのレビュー基準で見て」と言われた時に、persona の判断基準と差分の領域に合う guide（android-guide / ios-guide / go-api-guide / ops-guide）の要点を 1 つの指示文に組み立てる。Codex の built-in review と Copilot CLI は AGENTS.md と persona を自分で読むので、通常の呼び出しにこのブリーフは要らない（bot 却下パターンの抑制だけが残る価値）。基準の本文はここに複製せず、都度 persona と guide から切り出す。
---

# external-review-brief — 外部レビュアーに渡す判断基準の組み立て

Codex の built-in `review` は、cwd の `AGENTS.md` とグローバルの `~/.codex/AGENTS.md`（自分の CLAUDE.md への symlink にしている場合）を読み、CLAUDE.md が `@` で指している persona と、差分の言語に合う guide（Go 差分で `~/.codex/skills/go-api-guide/SKILL.md`）を自分で `cat` して参照した（2026-11-08 の試走。詳細は末尾）。したがって Codex の built-in `review` には persona も guide も既に届いていて、このブリーフは要らない。

ブリーフが要るのは次の 3 つ。

- Codex の `adversarial-review`: 既定の姿勢が「出荷を止める理由を探す」なので、下の「出さない指摘」節で抑制を効かせる
- Copilot CLI を直接使う時: Copilot も `copilot-instructions.md` の `@` 先（persona）と AGENTS.md を読む（2026-11-09 の試走、`agents/copilot-reviewer.md` の記録）ので基準は届いている。ただし diff 外の既存バグも挙げるので、「出さない指摘」節の抑制だけは渡す価値がある。`copilot-reviewer` agent は同じ抑制をプロンプトに埋め込んでいる
- bot 却下パターンの抑制: persona には「一般論の指摘を出さない」はあるが、AI レビュー bot の指摘を人が退けた理由で最多だった「diff 外の事情を知らずに断定する」の抑止は無い。「出さない指摘」節で補う

以下はそのブリーフ（指示文）を呼び出しのたびに組み立てる手順。

## 1. 入力

- diff の対象: 変更ファイルの一覧（`git diff --name-only <base>...HEAD` か `git status --short` の出力）
- 領域の手がかり: repo 名・パス。ファイル一覧から決められない時だけ呼び出し元が明示する
- 追加の焦点（任意）: 呼び出し元が特に見てほしい点。1〜2 行

## 2. 領域の判定

ファイル一覧の拡張子・パスで決める。複数に当たれば複数の guide を使う。

| 手がかり | guide | 切り出す節 |
|---|---|---|
| `.kt` / `.kts` | android-guide | `## DO / DON'T` と `## レビューでよく指摘されるポイント` |
| `.swift` | ios-guide | `## DO / DON'T` と `## レビューでよく指摘されるポイント` |
| `.go` | go-api-guide | `## DO / DON'T` と `## レビューでよく指摘されるポイント` |
| `.tf` / `.yaml` の Helm・ArgoCD / `.circleci` / `.github/workflows` | ops-guide | `## レビューの観点` と `## DO / DON'T（共通）` |
| 上のどれにも当たらない | なし | persona だけ渡す |

`*-guide` は `/learn-from-prs` で自分の repo から作る想定の skill で、この repo には含めていない。無い guide は飛ばす。

guide の節は見出しで切り出す。本文をこの skill に写さない（guide が更新されたら自動で追随させるため）。

## 3. 組み立て

`$TMPDIR/external-review-brief.md` に書き出す。見出し単位の切り出しは次の形で行う。`SKILLS` は persona や guide を置いている自分の skill ディレクトリ（既定 `~/.claude/skills`）。2 で判定した領域は先頭の `set --` に並べる。

```sh
# 見出し行を grep -x で特定してから次の ## まで出す。
# macOS の awk は -v で渡した日本語文字列の == 比較を誤る（「## 設計・実装」が「## レビュー」に一致した）ので awk 内で比較しない
section() {
  s=$(grep -nxF -- "$2" "$1" | head -1 | cut -d: -f1)
  [ -n "$s" ] || { echo "見出しが見つからない: $2 ($1)" >&2; return 1; }
  awk -v s="$s" 'NR > s && /^## / { exit } NR >= s { print }' "$1"
}

set -- android            # 2 で判定した領域（android / ios / go / ops）。複数なら空白区切り
SKILLS=~/.claude/skills
OUT="$TMPDIR/external-review-brief.md"
{
  cat <<'EOF'
# レビュー依頼

あなたはこの差分のレビュアーの 1 人です。最終判断は依頼側が行うので、指摘は根拠付きで列挙してください。

## 出力の形
- 各指摘に Must Fix / Should Fix / Nice to Have のいずれかを付け、該当ファイルと行番号、根拠（差分中の箇所、参照した既存コード、仕様）を書く
- 根拠を差分と手元のコードから示せない懸念は、断定せず「要確認: 〜なら問題」の形で分けて書く
- 問題が無ければ「指摘なし」と短く返す。良い点の列挙は不要

## 出さない指摘
- 一般論として正しくても、この repo の既存の書き方に反する提案（既存実装に揃っているものは問題にしない）
- 整形・命名の好み・共通化・定数化の提案。同一処理の重複が実在する場合だけ Nice to Have で出す
- diff の外の事情（先行 PR・既存の設定・CI の結果・別サービスの運用）を確認せずに「不足」「落ちる」と断定する指摘。確認できないなら「要確認」に回す
- スコープ外・TODO・仮実装への指摘。PR 本文や差分にその旨があれば対象外
- 別言語・古い API の規則を当てはめた断定。公式仕様やビルド結果で裏付けられるものだけ出す

EOF
  echo "## 判断基準（このユーザーのレビュー観）"
  section "$SKILLS/persona/SKILL.md" "## レビュー"
  # 領域ごとに追加（判定した guide の分だけ繰り返す）
  for g in "$@"; do
    case "$g" in
      android) f="$SKILLS/android-guide/SKILL.md"; echo "## Android の観点（android-guide）"; section "$f" "## DO / DON'T"; section "$f" "## レビューでよく指摘されるポイント";;
      ios)     f="$SKILLS/ios-guide/SKILL.md";     echo "## iOS の観点（ios-guide）";     section "$f" "## DO / DON'T"; section "$f" "## レビューでよく指摘されるポイント";;
      go)      f="$SKILLS/go-api-guide/SKILL.md";  echo "## Go API の観点（go-api-guide）"; section "$f" "## DO / DON'T"; section "$f" "## レビューでよく指摘されるポイント";;
      ops)     f="$SKILLS/ops-guide/SKILL.md";     echo "## インフラ・運用の観点（ops-guide）"; section "$f" "## レビューの観点"; section "$f" "## DO / DON'T（共通）";;
    esac
  done
} > "$OUT"
wc -c "$OUT"
```

- 見出しの文字列は guide 側の現物に合わせる。切り出しが空（0 行）になったら見出しが変わっているので、`grep -n '^## ' <guide>` で確かめて直す。空のまま渡さない
- 追加の焦点があれば、末尾に `## 今回特に見る点` として付ける
- 大きさの目安は 16 KB 以内（persona + guide 1 領域で約 12 KB、2 領域で約 17 KB）。超えたら guide の「よく指摘されるポイント」を落とし、DO / DON'T 表だけ残す。persona の節は落とさない
- ブリーフ内の `→ references/...md #n` のような参照先は外部レビュアーには読めない。そのまま残して構わないが、指摘の根拠として要求しない

## 4. 渡し方

- Codex（codex plugin）: `PLUGIN=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/* | tail -1)` で plugin の場所を取り、`node "$PLUGIN/scripts/codex-companion.mjs" adversarial-review --wait --scope working-tree "$(cat "$OUT")"`（branch 全体なら `--scope branch --base <ref>`）。built-in の `review` は焦点文を受け取らないが、AGENTS.md と skills を自分で読むのでブリーフ無しで使ってよい。`adversarial-review` の既定の姿勢は「出荷を止める理由を探す」なので、上の「出さない指摘」節がそのまま抑制として働く
- Copilot CLI: `copilot` を直接呼ばず、`copilot-run.sh review-diff --cwd <repo> --diff <patch> --prompt-file <f>` を使う。許可・拒否のフラグはラッパーが固定している。ブリーフを渡す時は、`$OUT` の後ろに差分の場所と指示を足したものを `--prompt-file` に渡す
- Codex / Copilot を直接対話で使っている時: この skill を読んだら上の手順で `$OUT` を作り、自分への指示として読む

## 5. 返ってきた指摘の扱い（呼び出し元の仕事）

ブリーフを渡しても外部レビュアーは diff 外の事情を知らない。返ってきた指摘は、そのまま Must / Should にせず、呼び出し元が次を確かめてから昇格する。

- diff 外の事情で成立しなくなるか: 先行 PR・既存の同種設定・CI の結果（AI レビュー bot の指摘が退けられる理由で最多）
- 仕様の勘違いか: 公式仕様・実データ・ビルド結果で裏を取る
- 既存に揃えた意図的な書き方か: 同じ repo の他の箇所を grep する

確かめられない指摘は「未確認」として残し、採用した扱いにしない。

## 試走の記録（2026-11-08）

scratch の git repo に、`AGENTS.md`（「summary の先頭に `CANARY-7731` を書く」「`fmt.Println` のログはブロッキング」）と Go の小さな差分を置き、`codex-companion.mjs review --wait --scope working-tree` を実行した。

- summary は `CANARY-7731` で始まり日本語だった。cwd の AGENTS.md は読まれている
- Codex が自分で `cat ~/.codex/skills/persona/SKILL.md` と `cat ~/.codex/skills/go-api-guide/SKILL.md` を実行した。persona はグローバルの `~/.codex/AGENTS.md`（CLAUDE.md）からしか辿れないので、グローバル側も読まれていて、`@~/.claude/skills/...` のパスを `~/.codex/skills/...` に読み替えて追っている
- 差分の外にある既存バグ（`i <= len(xs)`）は「今回の変更で導入されたものではない」として指摘から外した。built-in review は diff 内に絞る

## 未確認事項

- なし（Codex は 2026-11-08、Copilot は 2026-11-09 に確認済み）
