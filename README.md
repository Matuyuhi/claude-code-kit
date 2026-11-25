# claude-code-kit

Claude Code 用の skills / agents / hooks を、テーマ別の plugin にまとめた marketplace。普段使っている設定から、特定の仕事や個人に結びつく部分を外して公開している。文面は日本語。

## 入れ方

```
/plugin marketplace add matuyuhi/claude-code-kit
/plugin install memory@claude-code-kit
```

必要な plugin だけ入れる。skill 名は `memory:remember` のように plugin 名で名前空間が付く。更新は `/plugin marketplace update claude-code-kit`。Claude Code は plugin の `version` が変わった時だけ更新を取り込むので、中身を変えたら `plugins/<name>/.claude-plugin/plugin.json` の version を上げる。

## plugin 一覧

| plugin | 中身 |
|---|---|
| memory | `~/.claude/knowledge/` に記憶を置き、`/remember` `/recall` `/journal` `/reflect` `/sessions` `/start` `/now` で回す。index 再生成の hook 付き。詳細は [plugins/memory/README.md](plugins/memory/README.md) |
| git-workflow | `/commit` `/publish`（commit → push → PR を一言で）`/wip`（手元の差分の把握）`/pre-push-quality-checks` `/judge-pr`。`gh api` の書き込みを確認に回す hook と、push 前のチェックを促す hook |
| review | `/review-pr`、`/review-watch`（未レビューの PR を巡回してローカルに書き出す）、`/code-comment-cleanup`、`code-quality-principles`、`/learn-from-prs`（自分の repo の PR から `<platform>-guide` skill を作る）、`/learn-from-review`（1 件のレビュー指摘を skill に取り込む）、Codex / Copilot に外部レビューを頼む `external-review-brief` と `copilot-reviewer` agent |
| delegation | `command-runner`（検証コマンドを走らせて結果だけ返す）・`mechanical-worker`・`spec-coder` の 3 agent |
| guides | `design-approach`（着手前の検問と判断実例）・`explain-plainly`・`natural-japanese`・`web-ui-guidelines`・`design-implementation-guide` |
| android | `android-drive`（adb でエミュレータを操作・観察）・`android-index`（画面グラフを作って goto で再生）・`fix-android-studio-jdk-name`（Android Studio が `.idea/` に出す差分を直す）。`android-operator` / `android-indexer` agent |
| mac-guard | macOS の読み取り専用セキュリティ監査と、危険なコマンドを実行前に止める PreToolUse hook。package.json の脆弱性を見る `/scan-vuln` コマンド。下に詳細 |
| usage-alert / sessions-panel / journal-before-compact | Claude Code の mod（`register.ts` で UI やイベントに乗る拡張）。mod の実行環境がある Claude Code でだけ動く。usage-alert は使用量が上限に近づくと通知、sessions-panel は同じ Mac で動いている全セッションを並べてタブに飛ぶ、journal-before-compact は compact の前に `/journal` を走らせる |

plugin をまたいで呼ぶもの（片方だけでも動くが、その手順は飛ばされる）:

- git-workflow の `/commit` → review の `code-comment-cleanup`
- git-workflow の `/publish` → OpenAI の codex plugin（commit 前の Codex レビュー）と review の `external-review-brief`
- memory の `/start` → 作業の種類に応じて git-workflow / review / guides / android の skill
- journal-before-compact → memory の `/journal`
- sessions-panel の「過去セッションの再開」→ memory の `list-transcripts.py`

## 前提

- 共通: `jq`・`python3`・`gh`（hook とスクリプトが使う。無いと hook は確認に倒れるか何もしない）
- mac-guard・sessions-panel: macOS
- sessions-panel: ターミナルは Ghostty（AppleScript でタブを開く・切り替える）
- review の `/review-watch`: Claude Code の `/loop` と PushNotification ツール
- skill から別 plugin の skill を呼ぶ時は名前だけで呼んでいる。両方の plugin を入れておく

## mac-guard

組織管理の Mac でも使える形（Endpoint Security / Network Extension を足さない）で、「気づく」と「止める」を分けて持つ。

| 層 | 何をする | 動く契機 |
|---|---|---|
| `hooks/exec-guard.sh` | Claude Code の Bash / Write / Edit を実行前に見て、取得して実行・隔離属性の除去・常駐の設置・認証情報の持ち出し・痕跡消しを deny、依存追加・設定変更を ask にする。モデルは上書きできない | PreToolUse（plugin を有効にすると登録される） |
| `scripts/security-audit.sh` | 常駐・偽装・窃取・エージェント設定・サプライチェーンを読み取り専用で監査し、`~/.local/state/security-audit/latest.jsonl` に書く。読むのは `security-triage` skill | 手で実行 |
| `scripts/macguard.sh gate <file>` | dmg / pkg / app / 実行ファイルを開く前に署名・公証・VirusTotal（SHA-256 の照会だけ。ファイルは送らない）で判定し、OK なら開く | 手で実行 |
| `scripts/macguard.sh scan-downloads` | `~/Downloads` に落ちた quarantine 付きの対象を gate にかけ、BLOCK は `~/.local/state/macguard/hold/` へ退避して通知する | LaunchAgent（任意） |
| `scripts/macguard.sh watch-persistence` | 新規の常駐を検出し、`~/Library/LaunchAgents` の plist は bootout して退避、それ以外は通知する | LaunchAgent（任意） |

VirusTotal の API key は Keychain の `macguard-virustotal` から読む（無いと照会せず WARN に倒れる）。`scripts/macguard.sh install` は LaunchAgent を書くが、plist に書かれるのは plugin のキャッシュ上のパスなので、plugin を更新したら入れ直す。EDR が入っている端末では `install` を省き、hook と手動の `gate` / `watch-persistence` だけで使う。Downloads のスキャンと常駐の監視は EDR と重なるうえ、自作の LaunchAgent は監視ツールから攻撃者の常駐と区別がつかない（実際にクリーナー系アプリがマルウェアとして検知した）。

届かない所: hook の正規表現は変数で分割した難読化に負ける。ゲートは Downloads 以外に置かれたファイルを見ない。実行中のプロセスは止められない。

テストは `scripts/exec-guard-test.sh` / `scripts/macguard-test.sh` / `scripts/security-audit-test.sh`。

## 自分で用意すると効くもの

review 系の skill（`/review-pr`・`/review-watch`・`external-review-brief` など）は、次の skill が `~/.claude/skills/` にあれば読みに行く。無ければその手順は飛ばして動く。

- `persona` — 自分のコードの判断基準（何を指摘する・しないか）をまとめた skill
- `<platform>-guide`（`android-guide`・`ios-guide` など）— repo のレビュー観点。`/learn-from-prs` で自分の repo の PR から作れる

## ライセンス

未設定。
