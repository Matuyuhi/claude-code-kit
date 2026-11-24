---
name: learn-from-review
description: セッション中に共有された PR の review コメント・指摘・議論から「将来も使える知見」を抽出し、該当プラットフォームの既存 skill（ios-guide / android-guide / go-api-guide / code-quality-principles 等）に追記する。ユーザーが会話で「こんな review もらった」「PR コメント」「reviewer が指摘した」「○○ と言われた」のように review 内容や PR URL を共有してきた場合、その内容が将来の実装/レビューに役立つ知見なら、Claude は能動的にこの skill の使用を提案すること。手動では「/learn-from-review」で呼ぶ。learn-from-prs（複数PR一括分析）と違い、1件の知見をその場で軽量に取り込む用途。
---

# Review 知見 → 既存 skill へ即時取り込み

セッション中に出てきた 1件の review コメント / 指摘 / 議論 を、対応するプラットフォーム skill に追記して将来の自分が参照できるようにする skill。

## いつ使うか（Claude 側からのサジェスト条件）

ユーザーが会話の中で以下のようなものを共有してきたとき、Claude は 能動的にこの skill の使用を提案すること:

- PR の inline review comment 本文（コード断片 + レビュアーの説明文）
- PR の Issue/Review コメント
- 「○○ さんから指摘された」「reviewer が〜と言っていた」「コードレビューで〜」のような文脈
- Figma/Slack/メール経由のコードレビューの引用
- PR URL（特にコメント箇所への deep link）

ただし、以下は サジェストしない:

- 単発の質問・雑談（review という文脈ではない）
- そのプロジェクト固有すぎる詳細（例: 特定の画面 ID, 特定のテーブル名のみの話）で、汎用化できないもの
- 既に明らかに skill に書かれている内容（重複が予想される場合）

サジェストの仕方:

> この review、`ios-guide` に追記しておくと将来役立ちそうです。`/learn-from-review` で取り込みましょうか？

ユーザーが「お願い」「やって」「うん」等と返したら skill を実行する。

## Usage

```
/learn-from-review [入力]
```

引数なしの場合は、直近の会話に含まれる review 内容 を入力として扱う。引数として PR URL や review コメント本文を直接渡すこともできる。

## Instructions

### Phase 1: 入力の取得・整形

1. 入力ソースの判定:
   - 引数に PR URL（例: `https://github.com/owner/repo/pull/123#discussion_r123456`）が含まれる場合 → `gh api` で該当コメントを取得
   - 引数にコメント本文が直接含まれる場合 → そのまま使用
   - 引数なし → 直近の会話履歴から review 内容（コード断片 + レビュアー説明）を抽出

2. PR URL からのコメント取得例:

   ```bash
   # PR 全体のレビューコメント
   gh api repos/<owner>/<repo>/pulls/<PR番号>/comments \
     --jq '.[] | {user: .user.login, path: .path, body: .body, html_url: .html_url}'

   # 特定の comment_id だけ
   gh api repos/<owner>/<repo>/pulls/comments/<comment_id> \
     --jq '{user: .user.login, path: .path, body: .body, html_url: .html_url}'
   ```

3. 入力データを以下の形に整理する:
   - レビュアー名（任意。skill に書く際は基本含めない）
   - 対象ファイル/言語
   - 指摘の本文
   - 引用コード（あれば）
   - 出典 URL（あれば）

### Phase 2: 知見の抽出

入力から 将来の自分が参照したくなる教訓 を1〜3点で抽出する。粒度の目安:

- ✅ 一般化された「DO / DON'T」または「なぜ」の説明（背景・パフォーマンス影響など）
- ✅ BAD → GOOD のコード例（あれば）
- ❌ プロジェクト固有の変数名・画面名のみの指摘（汎用化できる範囲で書き直す）
- ❌ typo 指摘・lint レベルの瑣末な指摘

教訓は 1段落 + 短いコード例 に収まる粒度にする。ダラダラ書かない。

### Phase 3: 取り込み先 skill の判定

入力に含まれるキーワード・言語・ファイルパスから自動判定する。判定例:

| キーワード / 言語 | 取り込み先 skill | 推奨ファイル |
|---|---|---|
| TCA, Reducer, Effect, SwiftUI, UIKit, Swift, .swift | `ios-guide` | `review-insights.md` |
| Jetpack Compose, Flow, ViewModel, Hilt, Kotlin, .kt | `android-guide` | `review-insights.md` |
| Go, goroutine, context, .go, gRPC, gin | `go-api-guide` | （該当ファイル、なければ追加箇所を相談） |
| 命名・コメント・エラーハンドリングなど言語非依存の品質指摘 | `code-quality-principles` | `SKILL.md` |
| 上記いずれにも該当しない | ユーザーに確認 | — |

判定に迷う場合は ユーザーに候補を番号付きで提示して確認する。

### Phase 4: 追記内容のプレビュー

実際に書き込む前に、以下を ユーザーに提示して承認を得る:

1. 取り込み先ファイル（絶対パス）
2. どのセクションに追記するか（既存セクションに append / 新規セクション作成）
3. 追記する本文（マークダウン）
4. 出典コメント（追記の末尾に書く。例: `<!-- source: https://github.com/.../pull/123#discussion_rXXXX -->`）

承認なしに書き込まない（skill への追記は commit と同じく後に残る変更なので、確認を挟む）。

### Phase 5: 追記の実行

承認が得られたら:

1. 対象ファイルを `Read` で全文取得
2. 必ず `Edit` ツールを使う（python/sed/awk での一括置換は意図しない箇所まで書き換えるので使わない）
3. 既存セクション内に追記する場合は、関連する箇所の末尾に挿入
4. 新規セクションを作る場合は、関連する見出しの近くに `### <topic>` で追加
5. 出典 URL を HTML コメントで埋め込む（再追記時の重複検出に使える）

### Phase 6: 完了報告

- 何をどのファイルに追記したかを1〜2行で報告
- 追記先は自分で置いた skill（`~/.claude/skills/` 配下）に限る。plugin で入れた skill はキャッシュにあり、plugin の更新で上書きされる。`~/.claude/skills/` を git 管理の repo への symlink にしている場合は、`readlink -f` で解決した実体を編集し、commit はユーザーが確認してから

## 既に書かれている内容との重複チェック

追記前に該当 skill ファイルを Read し、似たような内容が既に書かれていないかチェックする:

- 完全に同じ趣旨なら 追記しない（ユーザーに「既に書かれているのでスキップします」と報告）
- 部分的に重複するなら、既存の内容を補強する形で `Edit` する（新規追加ではなく強化）
- 出典 URL のコメントが同じものが既にあれば、同じ review からの再取り込みなのでスキップ

## サジェストの自然な言い方（例）

会話で review が共有されたとき、Claude は以下のように自然に提案する:

> このレビュー、TCA における Action の使い分けに関する一般化できる教訓ですね。`ios-guide` の `review-insights.md` に追記しておくと、次回 Reducer を書くときに参照できます。`/learn-from-review` で取り込みましょうか？

ユーザーが既に skill の存在を知っている前提で、簡潔に提案する。長々と説明しない。

## 注意事項

- 既存 skill ファイルへの追記は 必ず Edit ツール
- レビュアー名・PR作者名は 含めない（個人名は skill に残さない）
- 出典 URL は HTML コメント `<!-- source: ... -->` で末尾に埋め込む
- 1回の実行で追記する教訓は最大3件まで。それ以上ある場合は分割して再実行を提案
- `learn-from-prs` の重い分析と混同しない: こちらは「1件をその場で軽く」専用
- 取り込み先 skill が存在しない場合は、`learn-from-prs` で初回生成することを案内する
