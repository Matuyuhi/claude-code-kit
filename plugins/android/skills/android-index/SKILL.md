---
name: android-index
description: Android アプリの画面グラフ index（android-drive の goto / flow が LLM なしで再生するための ~/.android-drive/<package>/index.json）を、エミュレータを踏み歩いて作る・増やす手順。ユーザーが「index 作って」「画面マップ作って」「この画面も goto できるようにして」「index を更新して」と言った時、または android-drive の goto が「index に画面がありません」「経路がありません」で止まった時に使う。作るのは 1 回で、画面が増えた時に差分を足す。
---

# Android Index

`android-drive.sh` の `index` サブコマンドで、アプリの画面グラフを `~/.android-drive/<package>/index.json` に記録する。LLM が担うのは「画面に名前を付ける」「anchors を選ぶ」「どこをタップするか決める」の 3 つだけで、anchors の実在確認・他画面との一意性・辺の実行検証・JSON の書き込みはツールが行う。ツールが拒否したものを `--no-verify` や `--update` で押し通さない。

```bash
tool="${CLAUDE_PLUGIN_ROOT}/scripts/android-drive.sh"
bash "$tool" index candidates
bash "$tool" index add-screen NewsScreen --anchor text=お知らせ --anchor text=ニュース --anchor text=メッセージ --alias SCR-010
bash "$tool" index add-edge HomeScreen NewsScreen --step "tap-desc お知らせ"
bash "$tool" index add-edge NewsScreen HomeScreen --step "key BACK"
bash "$tool" index check
```

## 前提

- index は `~/.android-drive/<package>/index.json` に書かれ、標本（画面ごとの dump）は同じディレクトリの `samples/` に入る。アプリの repo には書かないので、実行場所はどこでもよい
- 対象アプリを前面に出し、index 作成に使うアカウント状態（ログイン済み等）にしておく。package は前面アプリから取る
- 実機は使わない。エミュレータで作った index はロケールと画面密度が同じ端末でそのまま使える

## 名前の付け方

1. ソースが読めるなら、画面の登録簿を探して名前と別名をそこから取る。画面 ID と Composable 名を対で持つ注釈（例: `@ScreenId("SCR-010", "NewsScreen")`）、Navigation の route 定義、`sealed class Screen` などが候補。`grep -rn 'ScreenId\|@Composable fun [A-Z][A-Za-z]*Screen(' --include='*.kt'` の類で当たる
2. 名前は Composable 名または画面クラス名、別名（`--alias`）に仕様書の画面 ID を入れる
3. ソースが無いアプリは、ヘッダ文言を英語化した名前（`SettingsScreen` 等）にし、別名にヘッダ文言そのものを入れる

## anchors の選び方

`index candidates` の出力から 2〜4 個選ぶ。優先順位は id（Compose の testTag は `testTagsAsResourceId` 有効時に resource-id として出る）→ desc → 短い静的 text。

- 「他画面にも:」が付いた要素だけで構成しない。ボトムバーやヘッダのアイコンは全タブに在るので、タブ固有の要素を必ず 1 つ以上混ぜる
- 数字・日付・金額・ユーザー名・一覧の中身は使わない（`candidates` は数字入り text を既に除いているが、一覧の見出し文言などは残る）
- ローディング中だけ出る要素（`LOADING`、スケルトン）は使わない。`wait-for` で本文が出てから `candidates` を見る
- `add-screen` が「他画面の標本にも全部揃っています」で拒否したら、区別できる要素を足す。「他画面の anchors がこの画面にも揃っています」なら、その他画面の anchors が弱いので先にそちらを `--update` で強くする

## 踏み歩きの手順

開始画面（通常はアプリの HOME）から幅優先で、深さの上限（既定 2。呼び出し元の指定があればそれ）まで辿る。

1. 現在の画面を登録する。既に index にあるなら `index verify-screen <name> --sample` で標本を更新するだけ
2. `ui` を見て、この画面から出られる操作を列挙する。対象は desc 付きアイコン、タブ、ボタン文言、ナビゲーション行。一覧の個々の行（記事・ユーザー等）は代表 1 件だけにし、報告に「一覧行は未登録」と書く
3. 操作を 1 つ実行し `wait 2` → `screen` で行き先を見る
   - 未登録の画面に着いた → 手順 1 で登録し、`key BACK` 等で元の画面に戻ってから `index add-edge <from> <to> --step "..."` を実行する（ツールが操作を再実行して到達を検証し、到達した状態で終わる）。続けて戻る辺 `index add-edge <to> <from> --step "key BACK"` も登録する（検証で元の画面に戻る）
   - 登録済みの画面に着いた → 戻ってから同様に `add-edge` を登録する。ボトムバーのタブ同士のように全組み合わせが 1 手で行ける場合は、全ペアの辺を登録する
   - `key BACK` の行き先は入ってきた経路で変わる。同じ画面に入口が複数ある時、戻る辺は正規の入口 1 本だけにする（複数張ると `goto` の BFS が実際の履歴と矛盾する経路を選び、逸脱で止まる）。2 本目の入口は行きの辺だけ登録する。誤って張った辺は `index remove-edge <from> <to>` で消す（JSON を直接編集しない）
   - 一覧の状態に依存する操作（「再開」ボタンは中断中の項目にしか無い等）は辺にせず、常に在る操作（「詳細を見る」等）を使う
   - 同じ画面のまま（タブ内の切替、展開）→ 辺にしない
   - ダイアログ・ボトムシートが出た → それが目的地になり得る（ヘッダがある、操作の受け皿）なら画面として登録し、割り込み（キャンペーン告知、評価依頼）なら閉じる操作を `index add-dismiss` で登録する
   - 別アプリ・ブラウザに遷移した（`current` の package が変わった）→ `key BACK` で戻り、辺にしない。報告に残す
4. その画面の操作を全部試したら次の画面へ。深さ上限に達した画面は登録だけして中には入らない
5. 最後に `index check` を通す。「到達する辺がありません」「出る辺がありません」は辺の登録漏れなので埋める。「自分の標本が X と同定されます」は anchors の弱さなので `add-screen --update` で強くする

## 触ってはいけない操作

index 作成は読み取りが目的なので、状態を変える操作は行わない。該当する文言のボタンは辺の候補から外し、報告に「未探索: <画面> の <文言>」と書く。`android-drive.sh` や SKILL.md 自体も編集しない。ツールの不具合や欲しい機能は報告に書いて呼び出し元に委ねる。

- 購入・送信・決済の確定、金額入力の先へ進む
- ログアウト、退会、アカウント削除、パスワード・メール変更
- 投稿、コメント、送信、フォロー、ブロック、通報
- 設定の切替（通知、表示モード等）
- 端末の設定アプリ、外部ブラウザでの操作

## 停止条件

- 深さ上限まで全画面の操作を試した
- 操作が 60 手を超えた
- 同じ画面で 3 回連続して未登録画面に着けず、辺も増えなかった
- `log --crash` に FATAL が出た

## 報告

- 追加した画面（名前・別名）と辺の数、`index check` の結果
- 未探索の操作（危険操作・別アプリ遷移・一覧行）
- anchors に迷った画面（変動する要素しか無い等）
