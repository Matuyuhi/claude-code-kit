---
name: learn-from-prs
description: GitHub PRの実装内容・レビューコメント・議論を分析し、プロジェクト固有のコーディングガイド（スキル）を自動生成する。「/learn-from-prs ios 50」のように使用。
---

# PR学習 → スキル自動生成

GitHub PRの差分、レビューコメント、議論から、プラットフォーム固有の実装パターン・注意点・ベストプラクティスを抽出し、再利用可能なスキルとして出力します。

## Usage

```
/learn-from-prs <platform> [pr_count] [--label <label>] [--author <author>] [--repo <owner/repo>]
```

### 引数

| 引数 | 必須 | デフォルト | 説明 |
|------|------|-----------|------|
| platform | Yes | - | `ios` / `android` / `web` / `backend` など。生成するスキルの対象プラットフォーム |
| pr_count | No | 30 | 分析するPR数（最大100） |
| --label | No | - | PRのラベルでフィルタ（例: `--label bug`） |
| --author | No | - | 特定の著者のPRのみ分析 |
| --repo | No | カレントリポジトリ | 対象リポジトリ（例: `--repo owner/repo`） |

### 例

```bash
# 現在のリポジトリのiOS PRを30件分析
/learn-from-prs ios

# Android PRを50件、bugラベル付きのみ分析
/learn-from-prs android 50 --label bug

# 特定リポジトリのPRを分析
/learn-from-prs ios 40 --repo owner/example-app-ios
```

## Instructions

### Phase 1: PR情報の収集

引数をパースし、`gh` コマンドでPR情報を収集する。

#### 1-1. マージ済みPRの一覧取得

```bash
# 基本コマンド（引数に応じてフィルタを追加）
gh pr list --state merged --limit <pr_count> --json number,title,labels,author,mergedAt,additions,deletions,reviewDecision
```

`--label` や `--author` が指定されている場合はフィルタに追加する。
`--repo` が指定されている場合は `--repo <owner/repo>` を追加する。

#### 1-1a. 大量（目安 100 PR 超・全件）の場合は repo 単位で一括取得する

PR を 1 件ずつ叩く 1-2 の手順は数十件向け。数百〜全件では次に切り替える。

- 取得は repo 単位のエンドポイントで行い、生データはファイルに保存して文脈に流さない
  - インライン: `gh api --paginate "repos/<o>/<r>/pulls/comments?per_page=100&sort=created&direction=desc"`（`path`・`in_reply_to_id`・diff hunk 末尾数行を jq で残す）
  - 会話欄: `repos/<o>/<r>/issues/comments`（`html_url` に `/pull/` を含むものだけ）
  - レビュー本文: GraphQL の `pullRequests(first:40)` を `--paginate`。`gh pr list --json reviews` を大きい limit で叩くと 504 になる
- `--paginate` は途中で stream error が出ても exit 0 で終わることがある。取得後に日付の最小値を確かめ、欠けていれば `direction=asc` で取り直して id で重複排除する
- bot 判定で起点コメントを捨てない。bot を除外して取ると、bot 起点スレッドへの人間の返信が親を失い、整形段階で丸ごと落ちる。bot 起点スレッドは「AI レビューの指摘を人間がどう採否したか」として別バッチで抽出する
- bot 判定には名前に bot を含まない `github-actions`・組織の GitHub App 等も入れる。会話欄の「見ます」「review お願いします」等の定型は 30 字未満で落とす
- repo 単位の取得には未マージで閉じた PR も混ざる。`gh pr list --state closed --json number,state,mergedAt,closedAt` で状態と日付を付け直す
- 抽出は PR 群を約 12 万字のバッチに分けて subagent に渡す。共通指示書をファイルに書いて各 agent に Read させ、prompt にはバッチ名だけ書く
  - model は明示して中位 tier にする（1 本あたり約 22 万 token。同時実行は 20 本まで）
  - 出力は「人が読む md」と「1 行 1 知見の jsonl（category は固定語彙、kind / weight / status 付き）」の 2 つ。md を jsonl から機械生成しないことを最初から指示に書く
- 頻度の集計は jq で行い、LLM に数えさせない。集約は platform ごとにカテゴリ群で 2〜3 分割し、evidence を削った jsonl を入力にする
- 各候補の根拠（支持 PR 数・期間・BAD→GOOD・矛盾）は skill の `references/` に置き、SKILL.md からは項目番号で参照する

#### 1-2. 各PRの詳細情報を取得

重要: 各PRを 1件ずつ順番に 処理する。巨大な一括出力はパースに失敗するため避ける。

##### 取得順序（優先度順）

Step 1: レビューコメント（最優先 - 最も知見が豊富）

インラインレビューコメントは「やってはいけないこと」「推奨パターン」の宝庫。`--jq` で必要フィールドだけ抽出する:

```bash
# インラインレビューコメント（コード行への指摘）
gh api repos/{owner}/{repo}/pulls/<PR番号>/comments \
  --jq '.[] | select(.body != "") | {user: .user.login, path: .path, body: .body}'

# レビュー本文（APPROVED/CHANGES_REQUESTED 時のコメント）
gh api repos/{owner}/{repo}/pulls/<PR番号>/reviews \
  --jq '.[] | select(.body != "" and (.user.login | test("bot|copilot") | not)) | {user: .user.login, state: .state, body: .body}'
```

Step 2: PR本文とIssueコメント

```bash
gh pr view <PR番号> --json body,comments [--repo <owner/repo>] \
  --jq '{body: .body[0:500], comments: [.comments[] | select(.author.login | test("bot|codex|copilot") | not) | {author: .author.login, body: .body[0:500]}]}'
```

Step 3: 差分（実装パターンの把握）

まず `--stat` で変更概要を確認し、必要に応じて本文を取得:

```bash
# 変更ファイル一覧と変更量（軽量）
gh pr diff <PR番号> [--repo <owner/repo>] --stat 2>/dev/null || echo "(stat not available)"

# 差分本文（大きいPRは head で制限）
gh pr diff <PR番号> [--repo <owner/repo>] | head -300
```

- 差分が+1000行を超えるPRは `--stat` のみで概要把握し、主要ファイルだけ差分を確認する
- レビューコメントが豊富なPRは差分よりコメントの分析を優先する

##### 処理の進め方

1. PRリスト全件をループし、各PRごとに Step 1 → Step 2 → Step 3 の順で取得する
2. 1件取得ごとに知見を抽出・メモする（全件取得後にまとめて分析しない）
3. bot（copilot-pull-request-reviewer, chatgpt-codex-connector 等）のコメントは参考程度に留め、人間のレビュアーのコメントを最重視する
4. レビュアーとPR作者の間のやり取り（指摘 → 修正 → 合意）は特に価値が高い

#### 1-3. 収集データの構造化

各PRから以下の情報を抽出・構造化する:

```
PR #xxx: <タイトル>
├── 変更ファイル一覧と変更量（--stat）
├── 実装パターン（新規コード・リファクタリング）
├── 【最重要】レビュー指摘事項（人間のレビュアーのみ）
│   ├── Must Fix（必須修正）
│   ├── Should Fix（推奨修正）
│   └── Nice to Have（改善提案）
├── レビューでの議論・合意事項（指摘→修正→合意の流れ）
└── 修正前 → 修正後の変更パターン
```

特に注目すべきレビューコメントのパターン:
- 「〜は使わない」「〜の代わりに〜を使う」→ DO/DON'T ルールの候補
- 「AIが〜しがち」「生成AIは〜」→ AI利用時の注意点として最優先で記録
- 具体的なコード提案（suggestion）→ BAD/GOOD パターンの候補
- パフォーマンスや設計に関する議論 → アーキテクチャルールの候補

### Phase 2: パターン分析

収集した情報を以下の観点で分析する。

#### 2-1. 実装パターンの抽出

- 頻出する実装パターン: 複数のPRで繰り返し現れるコード構造
- アーキテクチャパターン: レイヤー構成、依存関係、ファイル構成
- 状態管理パターン: データフロー、キャッシュ戦略、エラーハンドリング
- UI実装パターン: コンポーネント設計、画面遷移、レイアウト

#### 2-2. レビュー指摘の集約

- 繰り返し指摘されるポイント: 複数PRで同じ種類の指摘があるもの
- 修正前→修正後のパターン: BAD → GOOD の具体的なコード例
- 命名規則・コーディング規約: レビューで言及されたルール
- パフォーマンス注意点: レビューで指摘された性能問題

#### 2-3. プラットフォーム固有の知見

platformに応じて重点的に分析する:

iOS の場合:
- Swift/SwiftUI/UIKit のパターン
- Combine/async-await の使い方
- MVVM/TCA等のアーキテクチャ
- メモリ管理、ライフサイクル

Android の場合:
- Kotlin/Jetpack Compose のパターン
- Flow/Coroutines の使い方
- ViewModel/Repository のパターン
- Hilt/Koin の DI パターン

Web の場合:
- React/Vue/Angular 等のフレームワークパターン
- 状態管理ライブラリの使い方
- API通信パターン
- コンポーネント設計

Backend の場合:
- API設計パターン
- DB操作、ORM の使い方
- 認証・認可パターン
- エラーハンドリング

### Phase 3: スキル生成

分析結果をスキルとして出力する。

#### 3-1. 出力先ディレクトリの決定

スキルは プラットフォーム単位 で管理する（リポジトリ単位ではない）。
複数リポジトリの知見を同じスキルに蓄積していく。

```
~/.claude/skills/<platform>-guide/
├── SKILL.md          # メインのスキルファイル（簡潔にまとめる）
├── architecture.md   # アーキテクチャの詳細
├── patterns.md       # 実装パターン集（BAD/GOOD例付き）
└── review-insights.md # レビューから得た知見・注意点
```

スキル名は `<platform>-guide` とする（例: `ios-guide`, `android-guide`, `web-guide`, `server-guide`）。

#### 3-1a. 既存スキルへのマージ

同名のスキルが既に存在する場合:

1. 既存の各ファイル（SKILL.md, architecture.md, patterns.md, review-insights.md）を読み込む
2. 今回の分析結果を 既存の内容に追記・統合 する:
   - patterns.md: 新パターンを末尾に追加。既存パターンと重複する場合はより具体的な方を残す
   - review-insights.md: 新しい知見を追加。頻出指摘ランキングは全リポジトリ横断で再集計
   - architecture.md: リポジトリ固有のアーキテクチャはセクション分けして追記
   - SKILL.md: 基本原則・DO/DON'T を統合。分析元の情報（リポジトリ名、PR件数）を更新
3. 各パターンやルールには 出典リポジトリ名を注記 する（例: `<!-- source: example-app-ios -->`）
4. 統合後、SKILL.md が200行を超える場合は詳細をサブファイルに移動して簡潔さを維持する

#### 3-2. SKILL.md の構成（テンプレート）

SKILL.mdは簡潔にまとめ、詳細は別ファイルに委譲する:

```markdown
---
name: <platform>-guide
description: <platform>開発ガイド。複数リポジトリのPR分析から自動生成。実装パターン・レビュー知見・注意点をまとめたもの。
---

# <Platform> 開発ガイド

> PR分析から自動生成（最終更新: <生成日>）
> 分析元: <リポジトリ1>（<件数>件）, <リポジトリ2>（<件数>件）, ...

## 基本原則

- **原則1**: [最も重要なアーキテクチャルール]
- **原則2**: [2番目に重要なルール]
- **原則3**: [3番目に重要なルール]

## 主要パターン

### パターン1: [名前]
[コード例を含む簡潔な説明]

### パターン2: [名前]
[コード例を含む簡潔な説明]

## DO / DON'T

| DO | DON'T |
|----|-------|
| [推奨パターン] | [アンチパターン] |

## レビューでよく指摘されるポイント

1. [最頻出の指摘]
2. [2番目に多い指摘]
3. [3番目に多い指摘]

## 参照

- 実装パターン集: `patterns.md`
- レビュー知見: `review-insights.md`
- アーキテクチャ詳細: `architecture.md`
```

#### 3-3. architecture.md の構成

```markdown
# アーキテクチャ詳細

## レイヤー構成図
[ASCIIアートで層構造を図示]

## 各レイヤーの責務
[レイヤーごとの役割・制約・ファイル配置]

## データフロー
[データの流れを図示]

## 依存関係のルール
[モジュール間の依存ルール]
```

#### 3-4. patterns.md の構成

```markdown
# 実装パターン集

## パターン1: [名前]

### 概要
[どんな場面で使うか]

### BAD（アンチパターン）
```<lang>
// ❌ なぜダメか
[コード例]
```

### GOOD（推奨パターン）
```<lang>
// ✅ なぜ良いか
[コード例]
```

[パターンを繰り返す]
```

#### 3-5. review-insights.md の構成

```markdown
# レビューから得た知見

## 頻出指摘ランキング

| 順位 | カテゴリ | 指摘内容 | 出現回数 |
|------|---------|---------|---------|
| 1 | [カテゴリ] | [内容] | [回数] |

## カテゴリ別の詳細

### 1. [カテゴリ名]

#### 指摘内容
[具体的な指摘の説明]

#### BAD → GOOD 例
[修正前→修正後のコード例]

[カテゴリを繰り返す]
```

### Phase 4: スキルの登録

生成完了後、ユーザーに以下を案内する:

1. 生成・更新されたファイルの場所とその内容の概要
2. 新規作成の場合のみ、登録方法を案内: `~/.claude/skills/<platform>-guide/` に置けば次のセッションから読み込まれる（`~/.claude` への書き込みは sandbox 解除が必要）。業務 repo 由来の知見を含むので、公開する repo には入れない
3. 既存スキルへの追記の場合は、追加された項目の一覧を表示する
4. スキルが正しく登録されたか確認する方法

## 注意事項

- PRの差分が非常に大きい場合（+1000行以上）は、主要ファイルのみ分析する
- プライベートリポジトリの場合、`gh auth status` で認証状態を確認する
- 生成されるスキルのSKILL.mdは200行以内を目標とする（簡潔さ重視）
- コード例は実際のPRから抽出し、必要に応じて匿名化・簡略化する
- レビューコメントの個人名は含めない
- 既に同名のプラットフォームスキルが存在する場合、上書きではなくマージ（追記・統合） する。ユーザーに既存スキルへの追記であることを確認してから実行する
- `gh api` の出力は必ず `--jq` でフィルタする。生のJSON出力は巨大になりパースに失敗する原因となる
- レビューコメントの取得失敗は致命的。取得に失敗した場合はリトライするか、個別に `gh api` で再取得する。レビューコメントなしでスキルを生成すると、最も価値の高い知見（DO/DON'T、AI利用時の注意点等）が欠落する
- 人間のレビュアーのコメントを最重視する。bot（Copilot, ChatGPT Codex等）のコメントは参考程度。特にレビュアーとPR作者の間の議論（指摘→応答→合意）は設計判断の背景が含まれており最も価値が高い
