---
name: android-drive
description: Android エミュレータを adb で操作・観察する（UI ツリーの精密な読み取りには Google 公式 android CLI の layout も使える）。ユーザーが「エミュレータで操作」「画面を見て」「タップして」「スクショ撮って」「UI ツリー」「実機確認して」などを求めた時に使う。
---

# Android Drive

`android-drive.sh`（android plugin の `scripts/` にある。以下の例は `tool` 変数に入れて呼ぶ）は adb と Python 3 の標準ライブラリだけで、Android の画面を観察・操作する。`layout` サブコマンドだけは Google 公式 `android` CLI があれば使える追加の観察手段で、無くても他は動く。`devices` 以外は、指定がなければ接続中の `emulator-*` が 1 台だけの時だけ実行できる。

```bash
tool="${CLAUDE_PLUGIN_ROOT}/scripts/android-drive.sh"
bash "$tool" devices
bash "$tool" -s emulator-5554 ui
```

実機は `-s SERIAL` を明示した時だけ操作できる。`ANDROID_SERIAL` はエミュレータの明示指定にも使えるが、実機には使わない。デフォルトはエミュレータ限定であり、複数接続時や実機だけの接続時は停止する。

## 操作の流れ

1. `ui` で text / content-desc と中心座標を確認する。必要なら `shot` でスクリーンショットも取得する。
2. `find <文字列>` または `tap-text <文字列>` を使う。Compose 画面は `uiautomator dump` 上で `clickable=false` になるため、clickable の有無で操作対象を絞り込まない。
3. 座標操作が必要な時も、`ui` / `find` で得た中心座標だけを `tap` に渡す。スクリーンショットは Read ツールで画像として読め、座標はスクリーンショット原寸（例: `1280x2856`）で指定する。
4. 操作後は `wait 1`〜`wait 3` を挟んで `ui` を取り直し、結果を確認する。

```bash
tool="${CLAUDE_PLUGIN_ROOT}/scripts/android-drive.sh"
bash "$tool" -s emulator-5554 find お知らせ
bash "$tool" -s emulator-5554 tap-text お知らせ
bash "$tool" -s emulator-5554 wait 2
bash "$tool" -s emulator-5554 ui
```

## サブコマンド

| コマンド | 用途 |
|---|---|
| `devices` | serial、model、emulator / physical を一覧する |
| `shot [OUT.png]` | PNG を保存し、保存パスを返す |
| `ui [--json]` | UI ツリーを座標付きで読む。`--json` は機械可読形式 |
| `layout [--diff]` | Google 公式 `android` CLI 経由の UI ツリー。Compose の `clickable` / `selected` / testTag（`id=`）が取れる。`--diff` は前回 `layout` からの added / modified |
| `find <substring>` | text / content-desc の部分一致を座標付きで探す |
| `tap <x> <y>` / `tap-text <substring>` | 座標、または text / desc 部分一致の最初のノードをタップする |
| `tap-desc <desc>` / `tap-id <resource-id>` | content-desc / resource-id 完全一致の最初のノードをタップする。index の辺ではこちらを優先する |
| `long <x> <y> [ms]` / `swipe <direction>` | 長押し、画面サイズに基づくスワイプ |
| `text <string>` / `key <KEY>` | ASCII 文字入力（入力中だけ IME を無効化する）、キーイベント送信 |
| `start <package>[/<activity>]` / `stop <package>` | 起動、強制停止。activity 省略時は LAUNCHER を解決する |
| `current` | `topResumedActivity` を表示する |
| `log [options]` / `log clear` | ログ確認、クリア。`--pkg`、`--pattern`、`--crash`、`--tail` を使える |
| `install-split <pkg> <bundle.apks> <split-name>` | dynamic feature split を既存アプリへ追加する |
| `wait <sec>` | 連続操作の待機 |
| `wait-for <substring> [sec]` | text / desc が現れるまで待ち、中心座標を返す（既定 15 秒） |
| `screen` / `wait-for-screen <name> [sec]` | index の anchors で現在の画面名を同定する / その画面に到達するまで待つ |
| `goto <name>... [sec]` | index の辺を BFS で辿って画面へ移動する。複数指定は順に巡る（1 プロセスで回るので画面ごとに呼ぶより速い）。LLM 不要 |
| `flow <file>` | 1 行 1 サブコマンドのファイルを順に実行する |
| `index <candidates\|add-screen\|verify-screen\|add-edge\|add-dismiss\|check\|list>` | index を作る・増やす。手順は android-index skill |

## index 再生（LLM なし）

`screen` / `wait-for-screen` / `goto` / `flow` は、アプリごとの画面グラフ index を読んで LLM を介さずに画面遷移を再生する。index は対象アプリの package 名で `~/.android-drive/<package>/index.json` を読む（アプリの repo には置かないので、実行場所はどこでもよい）。package は `current` の topResumedActivity から取るので、対象アプリを前面に出してから実行する。

画面の同定は uiautomator dump 上の text / content-desc / resource-id の組（anchors）だけで行い、アプリ固有のログやソースには依存しないので、Compose でも View でも同じ index 形式で動く。Compose の testTag は `testTagsAsResourceId` が有効なら resource-id として dump に出る。

```json
{
  "package": "com.example.app",
  "screens": {
    "NewsScreen": {
      "aliases": ["SCR-010"],
      "anchors": [{"text": "お知らせ"}, {"text": "ニュース"}, {"text": "メッセージ"}]
    }
  },
  "edges": [
    {"from": "HomeScreen", "to": "NewsScreen", "steps": [["tap-desc", "お知らせ"]]},
    {"from": "NewsScreen", "to": "HomeScreen", "steps": [["key", "BACK"]], "timeout": 10}
  ],
  "dismiss": [
    {"name": "キャンペーンを閉じる", "anchors": [{"text": "閉じる"}, {"text*": "キャンペーン"}], "steps": [["tap-text", "閉じる"]]}
  ]
}
```

- `anchors` は「その画面なら常に在る要素」の組。1 つの anchor は 1 ノードが全キーを満たすこと。キーは `text` / `desc` / `id` の完全一致と、`*` 付き（`text*` 等）の部分一致。日付・金額・件数など変動する text は入れない。全 anchors が揃った画面のうち anchors 数が最大のものを現在画面とし、同数で複数一致したら index の不備として止まる
- `edges` の `steps` はこのスクリプトのサブコマンドをそのまま配列で書く。辺を実行した後は `to` の画面に到達するまで待ち（既定 15 秒、辺ごとに `timeout` で上書き）、到達しなければ「どの辺で逸れ、実際はどの画面（または近い候補）だったか」を出して rc=1 で止まる
- `dismiss` は起動時ポップアップ等の「あれば閉じる」。`goto` と `wait-for-screen` は画面を見るたびに先に適用する（最大 3 回）
- `aliases` は仕様書の画面 ID など別名。`goto` / `wait-for-screen` の引数に使える
- 所要時間の下限は端末側の `uiautomator dump`（約 2 秒）で決まり、1 辺につき到達確認の dump が 1 回走る。tap 系の step は直前の dump から座標を引くので再 dump しない。全画面を巡る検証は `goto A B C ...` の 1 コマンドにまとめる（画面ごとに `goto` + `screen` を呼ぶと同定の dump が毎回 2 回余分に走る）

`flow` のファイルは 1 行 1 サブコマンドで、`#` 始まりと空行は無視する。1 プロセスで実行し、現在地と直前の dump を行をまたいで使い回すので、`goto` の到達直後の `assert-*` は dump を増やさない。検証項目が多い時はこれに並べるのが最速で、所要は概ね「辿る辺の数 × 2 秒」になる。

- `case <名前>` で検証項目を区切る。項目内で失敗したら残りの行を飛ばして次の case へ進み、最後に PASS / FAIL と所要秒の一覧を出す。1 つでも FAIL なら rc=1。`--fail-fast` で従来どおり最初の失敗で止まる
- 検証の語彙: `assert-screen <name>`（index の画面名・別名）、`assert-text <文言>` / `assert-no-text <文言>`（text / desc の部分一致）、`assert-alive <package>`（最初に見た pid から変わっていない = 再起動していない）
- 各 case は `goto` で始める。前の case が途中で失敗していても、`goto` が現在地を同定し直すので独立に動く

```
case お知らせにタブが 2 つある
goto NewsScreen
assert-text ニュース
assert-text メッセージ
assert-alive com.example.app

case 設定に主要項目が並ぶ
goto SettingsScreen
assert-text 通知
assert-text アカウント
```

操作を混ぜる時は tap 系 / `key` / `swipe` / `text` などもそのまま書ける。UI を変える行の後は dump が捨てられ、次の `assert-*` や `screen` が取り直す。

入力はファイルのほか、引数 1 つを 1 行として直接渡す形と、`-` で標準入力（heredoc）から読む形がある。数行の確認ならファイルを作らずに済む。

```bash
bash "$tool" flow "goto NewsScreen" "assert-text ニュース" "assert-alive com.example.app"
bash "$tool" flow - <<'EOF'
case 設定
goto SettingsScreen
assert-text 通知
EOF
```

index は android-index skill の手順で（`android-indexer` agent か自分で）一度だけ画面を踏み歩いて作り、画面が増えた時に差分を足す。`index add-screen` は anchors の実在と他画面との一意性を、`index add-edge` は操作の実行と到達を検証してから書き込む。標本は `~/.android-drive/<package>/samples/` に置かれ、`index check` が使う。`goto` の逸脱メッセージが「どこから再 index するか」の入力になる。

## ui と layout の使い分け

観察は `ui` が既定。`layout` は「タブの選択状態が変わったか」「どの testTag の要素か」「操作前後で何が変わったか（`--diff`）」のように、uiautomator では取れない情報が判定に要る時だけ使う。理由は 2 つ: `layout` は 1 回 3 秒程度かかる（JVM 起動込み）こと、`android` CLI は Claude Code の sandbox 内では JNI の一時ファイルを作れず失敗すること。sandbox 内で `layout` が落ちた時は `ui` に切り替えるか、その 1 回だけ sandbox 外で実行する。`layout` と `ui` はどちらも端末側の UiAutomation を占有するため、続けて叩くと後の方が `UiAutomationService already registered` で失敗する（`log --crash` に uiautomator プロセスの FATAL が出るが、アプリのクラッシュではない。PID で見分ける）。スクリプトは 1 秒待って 1 回再試行するが、連続で使うなら間に `wait 1` を挟む。操作系コマンドは `android` CLI に存在しないので、tap / text / key は常に adb 経由（このスクリプトの他のサブコマンド）で行う。

変更を再インストールした後は、`stop <pkg>`（`am force-stop`）→ `start <pkg>` でプロセスを新しくしてからログを見る。古い PID のログが混ざるためである。`log --pkg <pkg>` は対象アプリの PID に絞るので、指定しないと gms など他プロセスの行が混ざる。

`text` は `input text` を使うため ASCII しか入らず（非 ASCII は system_server 側で NPE になるので事前に拒否する）、キーイベントとして届くので有効な IME が変換を挟む。Gboard 日本語では `hello` が `へっぉ` になるため、入力中だけ `default_input_method` の IME を `ime disable` し、終了時（失敗時も EXIT trap で）`ime enable` + `ime set` で戻す。空白は `%s` に置き換えて送るので、文字列中の `%s` も空白になる。

ローカルの `installXxxRelease` は base split のみ入る。dynamic feature は `install-split` で追加する。Play 非経由のローカル install では `SplitInstallManager` が `APP_NOT_OWNED` で失敗するため、dynamic feature 側の検証には同じ variant 番号の split を指定する。split 名は bundle 内の実名（`feature_stats-master` のように `-master` 接尾辞付き。variant 違いの `-master_2` も並ぶ）で指定し、無い名前を渡すと候補一覧を表示して止まる。bundle の versionCode がインストール済みと違うと `INSTALL_FAILED_INVALID_APK: Existing version code N inconsistent with M` で失敗し、アプリは変更されない。

adb は Claude Code の sandbox 内で動く。一方、`./gradlew` は sandbox 内で実行すると Android Studio のデーモンを壊すため、sandbox 内では実行しない。
