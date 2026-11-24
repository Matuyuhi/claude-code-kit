---
name: fix-android-studio-jdk-name
description: Android Studio が `.idea/` 配下のファイルに勝手に差分を出す問題を直す。(1) `gradle.xml` / `misc.xml` の JDK 名が `21` → `jbr-21`（`ms-21` 等）に書き換わる、(2) `AndroidProjectSystem.xml` や `runConfigurations.xml` 等の自動生成ファイルが追加される、といった「git diff にノイズが出るが本質ではない」系の対処をまとめる。
---

# Android Studio の JDK 名差分を直す

## 症状

`git status` / `git diff` で `.idea/gradle.xml` と `.idea/misc.xml` に意図しない差分が出る。中身は JDK 名の変化:

```diff
- <option name="gradleJvm" value="21" />
+ <option name="gradleJvm" value="jbr-21" />
```

```diff
- <component name="ProjectRootManager" ... project-jdk-name="21" ...>
+ <component name="ProjectRootManager" ... project-jdk-name="jbr-21" ...>
```

## 原因

Android Studio のグローバル JDK テーブル (`jdk.table.xml`) に登録されている JDK の name が `21` ではなく `jbr-21`（bundled JBR）や `ms-21`（Microsoft 21）になっており、AS がプロジェクトを開くたび `.idea` 側のファイルをその名前に書き換える。

チームの規約は `21` で運用したい（= `.idea/gradle.xml` `.idea/misc.xml` は `21` のまま git に乗っている）ので、ローカルの JDK 名を `21` に揃える必要がある。

## 修正手順

### ステップ1: 現在使用中の Android Studio バージョンを特定

```bash
ls -lat ~/Library/Application\ Support/Google/AndroidStudio*/options/jdk.table.xml | head -3
```

一番新しい mtime のディレクトリが現在使用中。例: `AndroidStudio2025.3.4`。

### ステップ2: jdk.table.xml の現在の JDK 名を確認

```bash
grep -n '<name value=' "$HOME/Library/Application Support/Google/AndroidStudio<VERSION>/options/jdk.table.xml"
```

`jbr-21` や `ms-21` はあるが `21` がない、という状態のはず。

重要: 既に `21` という名前の JDK が登録されている場合、単純リネームは衝突する。その場合は既存の `21` エントリを削除するか、別の対応が必要。

### ステップ3: Android Studio を完全に終了させる

必須。AS が起動中だと、編集が AS の保存処理で上書きされて `jbr-21` に戻る。

```bash
pgrep -lf "Android Studio.app/Contents/MacOS"
```

何も出ないことを確認。出ていたらユーザーに AS を終了してもらう。`osascript -e 'quit app "Android Studio"'` で終了させても良いが、ユーザーに確認してから。

### ステップ4: jdk.table.xml の JDK 名をリネーム

Edit ツールで該当 `<name value="jbr-21" />` を `<name value="21" />` に変更する。

対象ファイル: `~/Library/Application Support/Google/AndroidStudio<VERSION>/options/jdk.table.xml`

```xml
<jdk version="2">
  <name value="jbr-21" />  ← この行
```

### ステップ5: プロジェクトの .idea 差分を戻す

```bash
cd /path/to/project
git checkout -- .idea/gradle.xml .idea/misc.xml
```

`git status` で差分が消えていることを確認。

### ステップ6: Android Studio を再起動

ユーザーに再起動を依頼。再起動後、Project Structure (⌘;) → SDKs で `21` という名前で表示されていれば定着完了。

## 注意点

- AS 起動中の直接編集は無意味。AS が終了時/保存時に `jdk.table.xml` を再書き出しして変更が消える。必ず AS を閉じてから編集する。
- AS バージョンを上げると再発しやすい。新バージョンの jdk.table.xml には bundled JBR が `jbr-21` という名前で再登録されるため。バージョンアップ後にこの skill を再度実行することが多い。
- 代替案: UI で操作。AS の `File > Project Structure > SDKs` で `jbr-21` を選び Name を `21` に変えても同じ結果。ただし複数バージョン間で揃えたい場合や、ターミナルで完結したい場合はファイル編集が早い。
- どうしても直らない時の保険:
  ```bash
  git update-index --skip-worktree .idea/gradle.xml .idea/misc.xml
  ```
  ローカル差分だけ無視できる。ただし他メンバーの変更を pull するときに障害になる可能性があるので最終手段。

## 関連ファイル

- `~/Library/Application Support/Google/AndroidStudio<VERSION>/options/jdk.table.xml` — グローバル JDK 登録
- `<project>/.idea/gradle.xml` — プロジェクトの Gradle JVM 設定
- `<project>/.idea/misc.xml` — プロジェクトの Project JDK 設定

---

# 別ケース: AS が自動生成する .idea/ ファイルを無視したい

## 対象例

git status に以下のような 新規ファイル が勝手に現れるケース:

- `.idea/AndroidProjectSystem.xml` — AS が Gradle プロジェクトと認識した記録
- `.idea/runConfigurations.xml` — JUnit Producer の無効化設定など
- 他にも AS バージョンアップで突然増える `.idea/` 配下のファイル全般

これらは環境依存で、チームの規約として git に乗せたいわけではない場合が多い。

## 判断フロー

1. チーム全員の AS で同じファイルが生成されているか？
   - YES → プロジェクト `.gitignore`（または `.idea/.gitignore`）に追記。PR でチーム全体に効く。
   - NO（自分の AS バージョン固有） → `.git/info/exclude` に追記。ローカルのみで無視。
2. 中身を `git show :path` または `cat` で確認し、機密や共有すべき設定が入っていないか確かめる。

## 修正手順（ローカル無視の場合）

```bash
# 既にステージされていれば外す
git reset HEAD .idea/AndroidProjectSystem.xml .idea/runConfigurations.xml

# .git/info/exclude に追記（リポジトリには乗らない）
```

`.git/info/exclude` への追加例:

```
# Android Studio auto-generated local files
/.idea/AndroidProjectSystem.xml
/.idea/runConfigurations.xml
```

`git status --short` で当該ファイルが消えていることを確認。

## 修正手順（チーム全体で無視する場合）

`.gitignore`（プロジェクト直下）に同じパターンを追記して commit。既存パターンは `/.idea/workspace.xml` のような 先頭スラッシュ + 相対パス 形式になっているので、それに合わせる。
