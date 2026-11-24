---
name: judge-pr
description: 現在のリポジトリのGitHub PR を「merge / close / 保留」に振り分けて処理判断する。ユーザーが「このPRどうする？」「PR整理して」「open PR を片付けたい」「PR をマージすべきか・閉じるべきか判断して」「溜まってるPRを掃除」「PR triage」のように、PR の処遇・要否・整理・棚卸し・判定を求めてきた時に必ず使う。引数なしなら open 全件、PR番号を渡せば単一PR。手動では「/judge-pr」「/judge-pr 123」。
---

# Judge PR

現在のディレクトリのリポジトリにある PR について、merge / close / 保留 のいずれが妥当かを判定するスキル。

## Usage

```
/judge-pr            # open している全 PR を対象に判定
/judge-pr <PR番号>   # 指定の単一 PR のみを判定
```

例:
- `/judge-pr` → リポジトリの open PR すべてを順に判定
- `/judge-pr 123` → PR #123 のみを判定

## 前提

- 実行ディレクトリが git リポジトリで、`gh` CLI が GitHub にログイン済みであること
- リモートが GitHub であること

最初に以下で前提を確認する:

```bash
gh auth status
gh repo view --json nameWithOwner -q .nameWithOwner
```

エラーが出る場合は処理を止めてユーザーに報告する。

## Instructions

### ステップ 1: 対象 PR の決定

- 引数なし: `gh pr list --state open --json number,title,author,isDraft,mergeable,mergeStateStatus,updatedAt,additions,deletions,labels,headRefName,baseRefName` で open 全件を取得
- 引数あり: その PR 番号のみを対象にする

### ステップ 2: 各 PR の情報収集

`gh pr list` の `mergeable` / `mergeStateStatus` は GitHub 側が再計算中だと `UNKNOWN` を返す（特に直前に他PRが merge された直後や、新しい PR）。判定材料としては不十分なので 必ず `gh pr view <番号>` で個別取得して `statusCheckRollup` まで見る。

各 PR について以下を取得する:

```bash
gh pr view <番号> --json number,title,body,author,isDraft,state,mergeable,mergeStateStatus,reviewDecision,reviews,statusCheckRollup,commits,labels,updatedAt,createdAt,additions,deletions,changedFiles,headRefName,baseRefName,comments
```

大量PR（10件超）のときは for + jq でコンパクト要約するのが効率的:

```bash
for n in 64 65 66 67 ...; do
  echo "===== PR #$n ====="
  gh pr view $n --json number,title,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,additions,deletions,changedFiles,updatedAt \
    -q '{n:.number,title:.title,draft:.isDraft,mergeable:.mergeable,state:.mergeStateStatus,review:.reviewDecision,addDel:[.additions,.deletions,.changedFiles],updated:.updatedAt,ci:[.statusCheckRollup[]?|{name:(.name//.context),status:(.status//.state),conclusion:.conclusion}]}'
done
```

差分が判断に必要な場合のみ `gh pr diff <番号>` で差分を確認する（大きい差分はファイル一覧と要点だけ確認し、全文読み込みは避ける）。

### ステップ 3: 判定基準

以下の観点で merge / close / 保留 のいずれかを選ぶ。

#### merge を推す条件（複数該当が望ましい）

- `mergeable: MERGEABLE` かつ `mergeStateStatus` が `CLEAN`（hook のある repo では `HAS_HOOKS`）。`UNSTABLE`（必須でない check の失敗）は保留側で扱う
- CI (`statusCheckRollup`) がすべて成功
- `reviewDecision: APPROVED`、あるいはレビュー不要な軽微変更（typo / docs / コメントのみ等）
- Draft でない
- 変更内容が明確で、目的が PR 本文・コミットから読み取れる
- 長期間放置されていない、もしくは内容が今も妥当

#### close を推す条件

- 同等の変更が既に他 PR・main で取り込み済み
- 方針変更により不要になっている（PR 本文・コメント・関連 issue から判断できる場合のみ）
- 著しく古く（例: 半年以上 update なし）、base ブランチから大きく乖離して再生は非現実的
- Draft のまま長期間放置、かつ作者が離脱
- 重複 PR

「使われていないかもしれない」程度の推測で close を勧めない。close の根拠は PR/issue/コードの事実に基づくこと。

#### 保留（hold）を推す条件

- CI が失敗中で、修正が小さく見える
- レビュー待ち
- コンフリクト解消待ち
- 議論が継続中・関連 issue が未決
- 判断材料が足りない

#### 変更カテゴリの粒度分け（merge 候補をさらに区分する）

「merge 候補」と判定されても全部を一括 merge するのは危険。次の粒度に分けて、ユーザーに「どこまで一括で merge するか」を選ばせる:

- A. 確実に安全（即マージ候補）: 未使用コード削除 / typo / コメント / docs / テスト追加のみ / `+N/-0` の追加のみリファクタ
- B. ロジック変更を含む最適化: パフォーマンス系（"Optimize ..."、"Memoize ..."、"bulk query 化" 等）。一見軽微でも挙動の等価性検証が必要 → 個別差分レビュー段階を挟む
- C. 中〜大規模リファクタ: ファイル抽出 / コンポーネント分割。差分行数が大きい場合は差分レビュー用の agent（repo 専用のレビュー agent があればそれ、無ければ general-purpose）に投げる
- D. 新機能 / UX 変更: CLAUDE.md 等で「動作確認していない変更は勝手に merge しない」方針があれば、ユーザーに動作確認済みか確認する

ユーザーから「掃除系と軽微でデグレもしなさそうなものを」のような指示があったときは A のみ。「全部 merge して」と言われても B/C/D を含めるかは一度確認する。

### ステップ 4: 判定結果の出力

複数 PR の場合はサマリを先に出し、その後に各 PR の詳細を続ける。

#### サマリ形式

```markdown
## PR 判定サマリ (<owner/repo>)

| # | Title | 判定 | 理由(要約) |
|---|---|---|---|
| 123 | ... | merge | CI green / approved |
| 124 | ... | close | #130 で取り込み済み |
| 125 | ... | hold | CI 失敗中 |
```

#### 各 PR の詳細形式

```markdown
### PR #<番号> <title>

- 作者: <author>  / branch: <head> → <base>
- 状態: draft=<bool> / mergeable=<...> / mergeState=<...> / reviewDecision=<...>
- CI: <成功/失敗の要約>
- 変更規模: +<add> / -<del> / <changedFiles> files
- 最終更新: <updatedAt>

**判定: merge / close / hold**

**理由**:
- <根拠 1>
- <根拠 2>

**推奨コマンド**:
\`\`\`bash
# merge の場合（squash 例。プロジェクト規約に従い調整）
gh pr merge <番号> --squash --delete-branch

# close の場合
gh pr close <番号> --comment "<close 理由>"
\`\`\`
```

### ステップ 4.5: 個別差分レビュー（カテゴリ B/C/D のみ）

カテゴリ A（確実に安全）以外は、merge 前に差分レビュー段階を挟む:

- 小さい差分（〜100行・1ファイル）: 自分で `gh pr diff <番号>` を読んで等価性 / デグレリスクを判定
- 中〜大規模差分: 差分レビュー用の agent（repo 専用のレビュー agent があればそれ、無ければ general-purpose）に投げる。リポジトリ固有の罠（CLAUDE.md に書かれている要注意事項）を観点として指示すると効果的。read-only で並列実行できるので、複数PRを並列で投げてよい
- 新機能 (D): ユーザーに「動作確認済みですか？」を先に確認

レビュー結果を踏まえて、各PRに「merge OK / 要修正 / hold」を再判定してからユーザーに提示。

### ステップ 5: 実行フロー（重要）

1. 判定結果（サマリ＋詳細）をまず提示する
2. この時点では `gh pr merge` / `gh pr close` を実行しない
3. ユーザーに次の形で確認を取る:
   - 「上記の判定に従って実行してよいか？」
   - 「一部だけ実行する場合は番号で指定してください（例: `123, 124 だけ merge` / `125 を close`）」
4. ユーザーから明示的な承認（「ok」「実行して」「全部やって」「123 だけ merge」等）が来たら、対象だけ実行する
5. 実行は 1 PR ずつ。merge コマンドが失敗（CI 待ち、コンフリクト、保護ブランチ等）したら次に進まず、原因を報告して指示を仰ぐ
6. すべて完了後に最終結果（成功した PR 一覧、失敗した PR と原因）をまとめて報告する

#### 連続 merge 時の挙動

- 1件 merge すると、main を共有する他の open PR の `mergeable` / `mergeStateStatus` が一時的に `UNKNOWN` にリセットされる（GitHub が再計算中）。これは異常ではないので、続けて次の PR を merge してよい。コンフリクトしていれば `gh pr merge` 側がエラーで返す
- 同一ファイルを触る PR が複数あって順番が重要なら、サイズの小さい順 / 影響範囲の小さい順に merge する（後続が rebase 不要になるとは限らないが、コンフリクト解消の手間が最小化される）
- 全件 merge した後に `gh pr list --state open` で 0 件であることを確認して報告

### 実行コマンドのデフォルト

- merge は `gh pr merge <番号> --squash --delete-branch` を デフォルト案 として提示する
  - リポジトリの規約・既存 PR の merge 方式（`git log --merges` で `Merge pull request` パターンが多ければ merge commit、squash commit パターンが多ければ squash）に合わせる
  - ユーザーが指示の中で merge 方式を指定（「merge commit で」「squash で」等）したらそれを最優先
- close は `gh pr close <番号> --comment "<日本語で簡潔な理由>"` を提示する
  - 理由コメントは自動で書かず、ユーザーに最終文言を確認してもらう（特に他者の PR の場合）

### 自分の PR / 他者の PR の扱い

- 他者の PR を close / merge する場合は、より慎重に確認する旨を明示する（特に close は破壊的）
- 自分の PR でも、PR 本文・コメントの議論が未解決の場合は hold を優先

## Notes

- 大量の open PR がある場合（10 件以上等）はサマリのみ詳細にして、各 PR の詳細はトップ数件＋判定理由 1 行に圧縮しても良い
- リポジトリの CLAUDE.md / CONTRIBUTING.md に PR 運用ルールがあれば、その規約を優先する
- 判定はあくまで「材料に基づく推奨」であり、最終判断はユーザー。迷ったら hold を選び、根拠を提示する
- 選択肢を提示する際は番号付きリストで（ユーザーが番号で返答するスタイル）。例: 「1. 全部 merge / 2. A だけ先に merge / 3. 番号指定」
- ユーザーが「動作確認した」等を明示したら、それは新機能 merge の前提条件を満たしたシグナル。同じ確認を再度求めない
