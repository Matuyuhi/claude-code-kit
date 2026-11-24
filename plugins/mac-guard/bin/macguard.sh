#!/bin/bash
# macguard — この Mac で「入口」と「居座り」を止める。AV の代わりではなく、AV が黙っている時に別経路で気づいて
# 止める層。Endpoint Security / Network Extension は使わない（既に入っているセキュリティ製品の拡張と競合させないため）。
#
#   gate <path> [--no-open] [--force] [--json]
#       dmg / pkg / app / zip / 実行ファイル / スクリプトを、開く前に署名・公証・VirusTotal で判定する。
#       OK なら open する。BLOCK / WARN は開かずに理由を出す（--force で開く）。
#       dmg は読み取り専用でマウントして中の .app まで見る（正規のインストーラに混ぜ物をされた形を拾うため）
#   scan-downloads
#       ~/Downloads 直下の新しい（quarantine 付きで未判定の）対象を gate にかける。BLOCK は hold へ退避して通知。
#       LaunchAgent（StartInterval）から呼ばれる
#   watch-persistence
#       security-audit.sh の persistence / browser / agents を専用 baseline で走らせ、新規の ALERT のうち
#       ~/Library/LaunchAgents の plist は bootout して hold へ退避、それ以外は通知する。LaunchAgent（StartInterval）から呼ばれる
#   status [--json]      statusline と人向けの要約。hold / 未確認（pending）の件数 / 監視の鮮度
#   held                 hold にあるものの一覧
#   release <name>       hold から元の場所へ戻す（plist は戻すだけで登録はしない）
#   pending              退避できなかった ALERT / WARN（人が ack するまで残る）
#   ack <id>|all         pending から消す
#   notify <title> <msg> 通知センターに出す（osascript をファイルで呼ぶ。-e は使わない）
#   install | uninstall  LaunchAgents を書いて登録する / 外す。人が自分の端末で実行する
#                        plist にはこのスクリプトの今のパスが入る。plugin として入れた場合は更新でパスが変わるので、更新したら install し直す
#   doctor               前提の確認（VT key・常駐の登録状態・フルディスクアクセス）
#
# VirusTotal の API key はキーチェーン（service: macguard-virustotal）か環境変数 MACGUARD_VT_KEY から読む。
# 送るのは SHA-256 だけで、ファイルは送らない。照会できない時は開かない（--force で開く）。
# 書くのは state ディレクトリ（~/.local/state/macguard/）と、install 時の ~/Library/LaunchAgents/local.macguard.*.plist だけ。
# 退避（hold）は移動であり削除ではない。release で戻せる。
set -uo pipefail
umask 077
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
grep() { LC_ALL=C command grep -a "$@"; }

SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
AUDIT="$(dirname "$SCRIPT")/security-audit.sh"
STATE_DIR="${MACGUARD_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/macguard}"
HOLD_DIR="$STATE_DIR/hold"
EVENTS="$STATE_DIR/events.log"
SEEN="$STATE_DIR/seen.tsv"
PENDING="$STATE_DIR/pending.tsv"
STATUS="$STATE_DIR/status.json"
DOWNLOADS="${MACGUARD_DOWNLOADS:-$HOME/Downloads}"
LABEL_PREFIX="local.macguard"
VT_URL="https://www.virustotal.com/api/v3/files"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

mkdir -p "$STATE_DIR" "$HOLD_DIR" || { echo "state ディレクトリを作れない: $STATE_DIR" >&2; exit 2; }

tmp_or_die() {
    local p
    p=$(mktemp "$@" "${TMPDIR:-/tmp}/macguard.XXXXXX") && { printf '%s' "$p"; return 0; }
    echo "一時ファイルを ${TMPDIR:-/tmp} に作れないため中止" >&2
    return 2
}

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }
epoch() { date '+%s'; }

# 出力に載る文字列は攻撃者が決められる（ファイル名・署名の Subject）。制御文字と不可視 Unicode を落とす
clean() {
    # 末尾の改行（here-string が付ける）は空白に変換せず落とす。それ以外の制御文字は空白にする
    LC_ALL=C perl -pe 'chomp; s/[\x00-\x1f\x7f]/ /g; s/\xE2\x80[\x8B-\x8F\xAA-\xAE]//g; s/\xE2\x81[\xA0-\xA4\xA6-\xA9]//g; s/\xF3\xA0[\x80-\x87][\x80-\xBF]//g; $_ .= "\n"' <<< "$*"
}

log_event() {
    # log_event <level> <kind> <message>
    printf '%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$(clean "$3")" >> "$EVENTS"
}

# ---- 通知 ------------------------------------------------------------------
notify() {
    local title="$1" msg="$2" sound="${3:-}" f
    # テストと sandbox（osascript が使えない）では通知を events.log に落とすだけにする
    [ -n "${MACGUARD_NO_NOTIFY:-}" ] && { log_event INFO notify "$title — $msg"; return 0; }
    f=$(tmp_or_die) || return 1
    # 引数で渡す。文言をスクリプト本文に埋め込むと AppleScript の引用符で壊れる
    cat > "$f" <<'AS'
on run argv
    set t to item 1 of argv
    set m to item 2 of argv
    if (count of argv) > 2 then
        display notification m with title t sound name (item 3 of argv)
    else
        display notification m with title t
    end if
end run
AS
    if [ -n "$sound" ]; then
        osascript "$f" "$(clean "$title")" "$(clean "$msg")" "$sound" >/dev/null 2>&1
    else
        osascript "$f" "$(clean "$title")" "$(clean "$msg")" >/dev/null 2>&1
    fi
    local rc=$?
    rm -f "$f"
    return $rc
}

# ---- pending（人が見るまで消えない指摘）----------------------------------------
# 監査の baseline は毎回更新されるので、新規は 1 回しか「新規」にならない。退避できなかった ALERT / WARN は
# ここに積み、ack するまで status と statusline に出し続ける
# add_pending <id> <sev> <kind> <title> <detail>
add_pending() {
    touch "$PENDING"
    grep -q "^$1	" "$PENDING" && return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(clean "$4")" "$(clean "$5")" "$(now)" >> "$PENDING"
}

cmd_pending() {
    [ -s "$PENDING" ] || { echo "pending は空"; return 0; }
    while IFS=$'\t' read -r id sev kind title detail t; do
        printf '  %s %s [%s] %s\n      %s\n      了解したら: macguard.sh ack %s\n' "$sev" "$id" "$kind" "$title" "$detail" "$id"
    done < "$PENDING"
}

cmd_ack() {
    local id="${1:?ack に id（macguard.sh pending で一覧）か all が必要}" tmp
    [ -s "$PENDING" ] || { echo "pending は空"; return 0; }
    if [ "$id" = all ]; then : > "$PENDING"; log_event INFO ack "all"; write_status; echo "すべて ack した"; return 0; fi
    grep -q "^$id	" "$PENDING" || { echo "pending に無い: $id" >&2; return 1; }
    tmp=$(tmp_or_die) || return 2
    grep -v "^$id	" "$PENDING" > "$tmp"; mv "$tmp" "$PENDING"
    log_event INFO ack "$id"
    # statusline は status.json しか見ないので、pending を減らしたらここで書き直す
    write_status
    echo "ack した: $id"
}

# ---- status ------------------------------------------------------------------
# status.json は statusline が毎描画で読む。小さく、キーは固定
# agent は LaunchAgent が入っているか。LaunchAgent を入れずに手動で使う場合は 0 で、鮮度の判定をしない
write_status() {
    S_HELD=$(find "$HOLD_DIR" -mindepth 1 -maxdepth 1 ! -name '*.meta' 2>/dev/null | wc -l | tr -d ' ')
    S_ALERT=$(cut -f2 "$PENDING" 2>/dev/null | grep -c '^ALERT$' | tr -d ' ')
    S_WARN=$(cut -f2 "$PENDING" 2>/dev/null | grep -c '^WARN$' | tr -d ' ')
    S_LAST_P=$(cat "$STATE_DIR/last-persistence" 2>/dev/null || echo 0)
    S_LAST_D=$(cat "$STATE_DIR/last-downloads" 2>/dev/null || echo 0)
    S_AGENT=0; [ -f "$LA_DIR/$LABEL_PREFIX.persistence.plist" ] && S_AGENT=1
    S_JSON=$(printf '{"time":%s,"held":%s,"pending_alert":%s,"pending_warn":%s,"last_persistence":%s,"last_downloads":%s,"agent":%s}' \
        "$(epoch)" "$S_HELD" "${S_ALERT:-0}" "${S_WARN:-0}" "$S_LAST_P" "$S_LAST_D" "$S_AGENT")
    # 書けない場所（Claude Code の sandbox）から status を見た時も表示は続ける
    { printf '%s\n' "$S_JSON" > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"; } 2>/dev/null
    return 0
}

cmd_status() {
    local json=0; [ "${1:-}" = --json ] && json=1
    write_status
    if [ "$json" = 1 ]; then printf '%s\n' "$S_JSON"; return 0; fi
    local held="$S_HELD" p_alert="${S_ALERT:-0}" p_warn="${S_WARN:-0}" last_p="$S_LAST_P" age
    age=$(( $(epoch) - last_p ))
    printf 'hold: %s 件  未確認: ALERT %s / WARN %s  常駐監視: ' "$held" "$p_alert" "$p_warn"
    if [ "$last_p" = 0 ]; then echo "未実行（macguard.sh watch-persistence か install）"
    elif [ "$S_AGENT" = 0 ]; then echo "$((age / 60)) 分前（手動。LaunchAgent なし）"
    elif [ "$age" -gt 3600 ]; then echo "$((age / 60)) 分前（止まっている可能性。macguard.sh doctor）"
    else echo "$((age / 60)) 分前"; fi
    [ "$held" -gt 0 ] && cmd_held
    [ -s "$PENDING" ] && cmd_pending
    [ -s "$EVENTS" ] && { echo "直近のイベント:"; tail -5 "$EVENTS" | cut -f1-4 | sed 's/^/  /'; }
    return 0
}

# ---- 署名・公証の判定 ----------------------------------------------------------
# sig_verdict <path> → "<KIND>|<説明>"。KIND: NOTARIZED / DEVID / APPLE / ADHOC / UNSIGNED / SCRIPT / REJECTED
sig_verdict() {
    local p="$1" kind="$2" out auth sp src
    case "$kind" in
        pkg)
            out=$(pkgutil --check-signature "$p" 2>&1)
            if printf '%s' "$out" | grep -q 'Status: signed by a developer certificate issued by Apple'; then
                auth=$(printf '%s\n' "$out" | grep -m1 'Developer ID Installer' | sed 's/^ *[0-9]*\. //')
                sp=$(spctl -a -t install -vv "$p" 2>&1)
                if printf '%s' "$sp" | grep -q 'source=Notarized'; then echo "NOTARIZED|${auth}（公証済み）"; else echo "DEVID|${auth}（公証なし）"; fi
            elif printf '%s' "$out" | grep -q 'Status: signed Apple Software'; then
                echo "APPLE|Apple 署名"
            else
                echo "UNSIGNED|未署名のパッケージ"
            fi ;;
        dmg)
            out=$(codesign -dv --verbose=2 "$p" 2>&1)
            if printf '%s' "$out" | grep -q 'not signed at all'; then echo "UNSIGNED|未署名のディスクイメージ（中身で判定）"; return; fi
            auth=$(printf '%s\n' "$out" | grep -m1 '^Authority=' | sed 's/^Authority=//')
            sp=$(spctl -a -t open --context context:primary-signature -vv "$p" 2>&1)
            if printf '%s' "$sp" | grep -q 'source=Notarized'; then echo "NOTARIZED|${auth}（公証済み）"
            elif [ -n "$auth" ]; then echo "DEVID|${auth}（公証なし）"
            else echo "ADHOC|ad-hoc 署名のディスクイメージ"; fi ;;
        app|exec)
            out=$(codesign --verify --deep --strict "$p" 2>&1)
            if printf '%s' "$out" | grep -q 'not signed at all'; then
                [ "$kind" = app ] && { echo "UNSIGNED|未署名のアプリ"; return; }
                echo "UNSIGNED|未署名の実行ファイル"; return
            fi
            if printf '%s' "$out" | grep -qE 'invalid|modified|does not satisfy'; then echo "REJECTED|署名が壊れている（改変の可能性）: $(printf '%s' "$out" | head -1)"; return; fi
            out=$(codesign -dv --verbose=2 "$p" 2>&1)
            if printf '%s' "$out" | grep -q '^Signature=adhoc'; then echo "ADHOC|ad-hoc 署名（配布元を証明できない）"; return; fi
            auth=$(printf '%s\n' "$out" | grep -m1 '^Authority=' | sed 's/^Authority=//')
            sp=$(spctl -a -t exec -vv "$p" 2>&1)
            src=$(printf '%s\n' "$sp" | grep -m1 -o 'source=.*' | sed 's/source=//')
            case "$auth" in
                "Software Signing"|"Apple "*|"macOS Software Signing") echo "APPLE|$auth" ;;
                "Developer ID Application: "*)
                    case "$src" in
                        Notarized*) echo "NOTARIZED|${auth}（公証済み）" ;;
                        # spctl は sandbox 内や Code Signing subsystem のエラーで source を返さない。「公証なし」と断定しない
                        "")         echo "DEVID|${auth}（公証を確認できない: $(printf '%s' "$sp" | tail -1 | cut -c1-60)）" ;;
                        *)          echo "DEVID|${auth}（公証なし: ${src}）" ;;
                    esac ;;
                "Apple Mac OS Application Signing"|"Apple Worldwide Developer Relations"*) echo "APPLE|App Store: $auth" ;;
                "") echo "UNSIGNED|署名情報を取得できない" ;;
                *)  echo "DEVID|${auth}（Developer ID ではない証明書）" ;;
            esac ;;
        script) echo "SCRIPT|署名不能なスクリプト（中身を目視）" ;;
        archive) echo "SCRIPT|書庫（展開後に gate にかける）" ;;
        *) echo "UNSIGNED|種類を判定できない" ;;
    esac
}

file_kind() {
    local p="$1" lower
    lower=$(printf '%s' "$p" | tr 'A-Z' 'a-z')
    if [ -d "$p" ]; then
        case "$lower" in *.app) echo app ;; *.pkg|*.mpkg) echo pkg ;; *) echo dir ;; esac; return
    fi
    case "$lower" in
        *.dmg|*.iso|*.sparseimage) echo dmg ;;
        *.pkg|*.mpkg) echo pkg ;;
        *.zip|*.tar|*.tgz|*.tar.gz|*.tar.bz2|*.tar.xz|*.7z|*.rar|*.jar) echo archive ;;
        *.command|*.sh|*.zsh|*.bash|*.py|*.rb|*.pl|*.scpt|*.applescript|*.js|*.tool) echo script ;;
        *)
            case "$(file -b "$p" 2>/dev/null)" in
                *Mach-O*) echo exec ;;
                *"shell script"*|*"script text"*) echo script ;;
                *) echo other ;;
            esac ;;
    esac
}

# ---- VirusTotal ----------------------------------------------------------------
vt_key() {
    [ -n "${MACGUARD_VT_KEY:-}" ] && { printf '%s' "$MACGUARD_VT_KEY"; return 0; }
    security find-generic-password -s macguard-virustotal -w 2>/dev/null
}

# vt_lookup <sha256> → "<KIND>|<説明>"。KIND: MALICIOUS / SUSPICIOUS / CLEAN / UNKNOWN / NOKEY / ERROR
# ファイルは送らない。ハッシュの照会だけ
vt_lookup() {
    local sha="$1" key body code mal sus harm und
    if [ -n "${MACGUARD_VT_STUB:-}" ]; then
        # テスト用: 応答 JSON と HTTP コードを差し替える。ネットワークには出ない
        body="$MACGUARD_VT_STUB"; code="${MACGUARD_VT_STUB_CODE:-200}"
    else
        key=$(vt_key) || { echo "NOKEY|VirusTotal の API key が無い（security add-generic-password -a \"\$USER\" -s macguard-virustotal -w）"; return; }
        body=$(tmp_or_die) || { echo "ERROR|一時ファイルを作れない"; return; }
        code=$(curl -sS -m 25 -H "x-apikey: $key" -o "$body" -w '%{http_code}' "$VT_URL/$sha" 2>/dev/null) || code=000
    fi
    case "$code" in
        200)
            mal=$(jq -r '.data.attributes.last_analysis_stats.malicious // 0' "$body" 2>/dev/null)
            sus=$(jq -r '.data.attributes.last_analysis_stats.suspicious // 0' "$body" 2>/dev/null)
            harm=$(jq -r '.data.attributes.last_analysis_stats.harmless // 0' "$body" 2>/dev/null)
            und=$(jq -r '.data.attributes.last_analysis_stats.undetected // 0' "$body" 2>/dev/null)
            [ -z "${MACGUARD_VT_STUB:-}" ] && rm -f "$body"
            if [ "${mal:-0}" -gt 0 ]; then echo "MALICIOUS|VirusTotal: ${mal} 社が悪性と判定（suspicious ${sus} / undetected ${und}）"
            elif [ "${sus:-0}" -gt 0 ]; then echo "SUSPICIOUS|VirusTotal: ${sus} 社が疑わしいと判定（undetected ${und}）"
            else echo "CLEAN|VirusTotal: 悪性判定なし（undetected ${und} / harmless ${harm}）"; fi ;;
        404) [ -z "${MACGUARD_VT_STUB:-}" ] && rm -f "$body"; echo "UNKNOWN|VirusTotal に未登録のハッシュ（誰も提出していない = 新しいか珍しい）" ;;
        401|403) [ -z "${MACGUARD_VT_STUB:-}" ] && rm -f "$body"; echo "ERROR|VirusTotal の API key が拒否された（HTTP ${code}）" ;;
        429) [ -z "${MACGUARD_VT_STUB:-}" ] && rm -f "$body"; echo "ERROR|VirusTotal のレート制限（HTTP 429）。少し待って再実行" ;;
        *)   [ -z "${MACGUARD_VT_STUB:-}" ] && rm -f "$body"; echo "ERROR|VirusTotal に到達できない（HTTP ${code}）" ;;
    esac
}

# ---- gate --------------------------------------------------------------------
# dmg は読み取り専用・非表示・自動オープンなしでマウントし、中の .app / .pkg を判定する
dmg_contents_verdict() {
    local dmg="$1" mnt out dev worst="OK" reasons="" item v kind
    mnt=$(tmp_or_die -d) || return 1
    # stdin を閉じる。ライセンス同意付きの dmg は同意の入力を待って止まる（launchd 配下では永久に）
    out=$(hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" 2>&1 </dev/null) || {
        rmdir "$mnt" 2>/dev/null
        printf 'WARN|マウントできない（暗号化・破損・ライセンス同意が要る形）: %s' "$(printf '%s' "$out" | tail -1)"
        return 0
    }
    # 直下と 1 階層下の .app / .pkg を見る。dmg には /Applications への symlink が置かれるのが普通で、
    # それを辿るとインストール済みアプリを全部判定してしまうので symlink は見ない
    for item in "$mnt"/* "$mnt"/*/*; do
        [ -e "$item" ] || continue
        [ -L "$item" ] && continue
        [ -L "$(dirname "$item")" ] && continue
        case "$item" in *.app|*.pkg|*.mpkg) ;; *) continue ;; esac
        kind=$(file_kind "$item")
        v=$(sig_verdict "$item" "$kind")
        case "${v%%|*}" in
            NOTARIZED|APPLE) reasons="$reasons; $(basename "$item"): ${v#*|}" ;;
            DEVID)           [ "$worst" = OK ] && worst=WARN; reasons="$reasons; $(basename "$item"): ${v#*|}" ;;
            *)               worst=BLOCK; reasons="$reasons; $(basename "$item"): ${v#*|}" ;;
        esac
    done
    hdiutil detach "$mnt" -quiet 2>/dev/null || hdiutil detach "$mnt" -force -quiet 2>/dev/null
    rmdir "$mnt" 2>/dev/null
    [ -n "$reasons" ] || { printf 'WARN|中に .app / .pkg が見当たらない'; return 0; }
    printf '%s|%s' "$worst" "${reasons#; }"
}

# gate_verdict <path> → 標準出力に "VERDICT\tsha256\t理由1\t理由2..."。VERDICT: OK / WARN / BLOCK
gate_verdict() {
    local p="$1" kind sha sig vt worst=OK reasons=() v
    kind=$(file_kind "$p")
    [ "$kind" = dir ] || [ "$kind" = other ] && { printf 'SKIP\t\t対象外（%s）\n' "$kind"; return 0; }
    if [ -d "$p" ]; then
        # bundle は中身全体の hash ではなく主実行ファイルで照会する
        local main; main=$(plutil -extract CFBundleExecutable raw -o - "$p/Contents/Info.plist" 2>/dev/null)
        sha=$(shasum -a 256 "$p/Contents/MacOS/${main:-}" 2>/dev/null | cut -d' ' -f1)
    else
        sha=$(shasum -a 256 "$p" | cut -d' ' -f1)
    fi
    sig=$(sig_verdict "$p" "$kind")
    reasons+=("署名: ${sig#*|}")
    case "${sig%%|*}" in
        NOTARIZED|APPLE) ;;
        DEVID)  worst=WARN ;;
        SCRIPT) worst=WARN ;;
        UNSIGNED|ADHOC)
            # dmg の容器が未署名なのは普通（brew の cask 等）。中身で決める
            if [ "$kind" = dmg ]; then worst=WARN; else worst=BLOCK; fi ;;
        REJECTED) worst=BLOCK ;;
    esac
    if [ "$kind" = dmg ]; then
        v=$(dmg_contents_verdict "$p")
        reasons+=("中身: ${v#*|}")
        case "${v%%|*}" in
            BLOCK) worst=BLOCK ;;
            WARN)  [ "$worst" = OK ] && worst=WARN ;;
            OK)    # 中身が公証済みなら容器の未署名は問題にしない
                   case "${sig%%|*}" in UNSIGNED|ADHOC) worst=OK ;; esac ;;
        esac
    fi
    if [ -n "$sha" ]; then
        vt=$(vt_lookup "$sha")
        reasons+=("${vt#*|}")
        case "${vt%%|*}" in
            MALICIOUS)  worst=BLOCK ;;
            SUSPICIOUS) [ "$worst" = OK ] && worst=WARN ;;
            CLEAN) ;;
            UNKNOWN)    [ "$worst" = OK ] && worst=WARN ;;
            NOKEY|ERROR) [ "$worst" = OK ] && worst=WARN ;;
        esac
    fi
    printf '%s\t%s' "$worst" "$sha"
    printf '\t%s' "${reasons[@]}"
    printf '\n'
}

cmd_gate() {
    local p="" no_open=0 force=0 json=0 line verdict sha reasons
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-open) no_open=1 ;;
            --force)   force=1 ;;
            --json)    json=1 ;;
            -*) echo "不明な引数: $1" >&2; return 2 ;;
            *) p="$1" ;;
        esac
        shift
    done
    [ -n "$p" ] && [ -e "$p" ] || { echo "gate: 対象のパスが必要" >&2; return 2; }
    p=$(cd "$(dirname "$p")" && pwd)/$(basename "$p")
    line=$(gate_verdict "$p")
    verdict="${line%%$'\t'*}"; line="${line#*$'\t'}"
    sha="${line%%$'\t'*}"; reasons="${line#*$'\t'}"
    if [ "$json" = 1 ]; then
        jq -nc --arg v "$verdict" --arg p "$p" --arg s "$sha" --arg r "$reasons" \
            '{verdict:$v, path:$p, sha256:$s, reasons:($r|split("\t"))}'
    else
        printf '%s  %s\n' "$verdict" "$(clean "$p")"
        printf '%s\n' "$reasons" | tr '\t' '\n' | sed 's/^/  - /'
    fi
    case "$verdict" in
        OK)
            log_event INFO gate "OK $p"
            [ "$no_open" = 1 ] || open "$p" ;;
        SKIP) ;;
        *)
            log_event "$([ "$verdict" = BLOCK ] && echo ALERT || echo WARN)" gate "$verdict $p — $(printf '%s' "$reasons" | tr '\t' ';')"
            if [ "$force" = 1 ] && [ "$no_open" = 0 ]; then
                echo "  --force 指定のため開く"
                open "$p"
                return 0
            fi
            [ "$no_open" = 0 ] && echo "  開かない。それでも開くなら: macguard.sh gate --force \"$(clean "$p")\""
            return 1 ;;
    esac
}

# ---- hold（退避）--------------------------------------------------------------
# hold_item <path> <理由>: 同じボリューム内の移動なので quarantine 属性も保つ。.meta に元の場所を残す
hold_item() {
    local p="$1" why="$2" name dest
    name="$(date '+%Y%m%d-%H%M%S')-$(basename "$p")"
    dest="$HOLD_DIR/$name"
    mv "$p" "$dest" || { log_event ALERT hold "退避に失敗: $p"; return 1; }
    printf '%s\t%s\t%s\n' "$(now)" "$(clean "$p")" "$(clean "$why")" > "$dest.meta"
    log_event ALERT hold "$p → $dest — $why"
    return 0
}

cmd_held() {
    local m
    for m in "$HOLD_DIR"/*.meta; do
        [ -e "$m" ] || { echo "hold は空"; return 0; }
        break
    done
    for m in "$HOLD_DIR"/*.meta; do
        [ -e "$m" ] || continue
        IFS=$'\t' read -r t orig why < "$m"
        printf '  %s\n    元: %s\n    理由: %s\n    戻す: macguard.sh release %s\n' "$(basename "${m%.meta}")" "$(clean "$orig")" "$(clean "$why")" "$(basename "${m%.meta}")"
    done
}

cmd_release() {
    local name="${1:?release に hold 内の名前が必要（macguard.sh held で一覧）}" src orig
    src="$HOLD_DIR/$name"
    [ -e "$src" ] && [ -f "$src.meta" ] || { echo "hold に無い: $name" >&2; return 1; }
    orig=$(cut -f2 "$src.meta")
    [ -e "$orig" ] && { echo "元の場所に既に別のものがある: $orig" >&2; return 1; }
    mkdir -p "$(dirname "$orig")" && mv "$src" "$orig" && rm -f "$src.meta" || return 1
    log_event INFO release "$orig ← $name"
    echo "戻した: ${orig}（plist の場合、launchd への再登録はしていない）"
}

# ---- scan-downloads ------------------------------------------------------------
seen_key() { printf '%s|%s|%s' "$1" "$(stat -f '%z' "$1" 2>/dev/null)" "$(stat -f '%m' "$1" 2>/dev/null)"; }

cmd_scan_downloads() {
    local lock="$STATE_DIR/scan.lock" p kind key line verdict sha reasons n=0 base
    # trap は EXIT 時に評価されるので、関数ローカルでなく大域の LOCK に置く
    mkdir "$lock" 2>/dev/null || { echo "別の scan が実行中"; return 0; }
    LOCK="$lock"; trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    [ -d "$DOWNLOADS" ] || { echo "Downloads が無い: $DOWNLOADS"; return 0; }
    touch "$SEEN"
    for p in "$DOWNLOADS"/* "$DOWNLOADS"/.[!.]*; do
        [ -e "$p" ] || continue
        base=$(basename "$p")
        # ダウンロード途中（Chrome / Safari / Firefox の一時名）は触らない。完了時に改名されて再び発火する
        case "$base" in *.crdownload|*.download|*.part|*.partial|.DS_Store|.localized) continue ;; esac
        kind=$(file_kind "$p")
        case "$kind" in dir|other) continue ;; esac
        # quarantine 属性が無い = ブラウザ経由でない（自分で置いた・展開した）。対象外
        xattr -p com.apple.quarantine "$p" >/dev/null 2>&1 || continue
        key=$(seen_key "$p")
        grep -qF "$key" "$SEEN" && continue
        n=$((n + 1))
        line=$(gate_verdict "$p")
        verdict="${line%%$'\t'*}"; line="${line#*$'\t'}"
        sha="${line%%$'\t'*}"; reasons="${line#*$'\t'}"
        printf '%s\t%s\t%s\t%s\n' "$key" "$sha" "$verdict" "$(now)" >> "$SEEN"
        case "$verdict" in
            BLOCK)
                if hold_item "$p" "$(printf '%s' "$reasons" | tr '\t' ';')"; then
                    notify "macguard: 退避した" "$base — $(printf '%s' "$reasons" | tr '\t' ' / ' | cut -c1-120)" Basso
                else
                    notify "macguard: 退避に失敗" "$base を手で確認する" Basso
                fi ;;
            WARN)
                log_event WARN downloads "WARN $p — $(printf '%s' "$reasons" | tr '\t' ';')"
                add_pending "${sha:0:12}" WARN downloads "$base" "$(printf '%s' "$reasons" | tr '\t' ';')"
                notify "macguard: 開く前に確認" "$base — $(printf '%s' "$reasons" | tr '\t' ' / ' | cut -c1-120)" ;;
            OK)
                log_event INFO downloads "OK $p" ;;
        esac
    done
    epoch > "$STATE_DIR/last-downloads"
    write_status
    echo "判定した: $n 件"
}

# ---- watch-persistence -----------------------------------------------------------
# security-audit.sh を専用 baseline で走らせ、新規の ALERT / WARN に対して動く。
# accounts セクションは含めない（sudo -k を毎回実行してしまう）
WATCH_SECTIONS="persistence,browser,agents"

cmd_watch_persistence() {
    local lock="$STATE_DIR/watch.lock" base="$STATE_DIR/persist-baseline.tsv" out="$STATE_DIR/persist.jsonl" first=0
    local n_alert=0 n_warn=0 n_evict=0 summary="" line id sev sec title detail plist label evicted
    [ -x "$AUDIT" ] || { echo "security-audit.sh が見つからない: $AUDIT" >&2; return 2; }
    mkdir "$lock" 2>/dev/null || { echo "別の watch が実行中"; return 0; }
    LOCK="$lock"; trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    [ -f "$base" ] || first=1
    "$AUDIT" --section "$WATCH_SECTIONS" --baseline "$base" --json "$out" --no-state --no-color >/dev/null 2>&1
    epoch > "$STATE_DIR/last-persistence"
    if [ "$first" = 1 ]; then
        log_event INFO watch "baseline を作成（$(grep -c '"type":"finding"' "$out") 件）"
        write_status
        echo "baseline を作成した。次回から新規を検出する"
        return 0
    fi
    while IFS=$'\t' read -r id sev sec title detail; do
        [ -n "$sev" ] || continue
        case "$sev" in ALERT) n_alert=$((n_alert + 1)) ;; WARN) n_warn=$((n_warn + 1)) ;; esac
        summary="$summary; $sev $title"
        log_event "$sev" "watch/$sec" "$title — $detail"
        evicted=0
        # ユーザー領域の LaunchAgent の ALERT だけ退避する。/Library は MDM の領域なので触らない。
        # 監査は plist の basename を title にする（detail は起動対象のパスのことがあるので使わない）
        if [ "$sev" = ALERT ] && [ "$sec" = persistence ]; then
            plist="$HOME/Library/LaunchAgents/${title% \[Disabled\]}.plist"
            if [ -f "$plist" ]; then
                label=$(plutil -extract Label raw -o - "$plist" 2>/dev/null || basename "$plist" .plist)
                launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
                if hold_item "$plist" "$title — $detail"; then n_evict=$((n_evict + 1)); evicted=1; fi
            fi
        fi
        # 退避できなかったものは ack されるまで残す（baseline は次回更新されて「新規」でなくなるため）
        [ "$evicted" = 1 ] || add_pending "$id" "$sev" "watch/$sec" "$title" "$detail"
    done < <(jq -r 'select(.type=="finding" and .new==true and (.severity=="ALERT" or .severity=="WARN")) | [.id,.severity,.section,.title,.detail] | @tsv' "$out")
    write_status
    if [ "$n_alert" -gt 0 ]; then
        notify "macguard: ALERT ${n_alert} 件（退避 ${n_evict}）" "$(printf '%s' "${summary#; }" | cut -c1-120)" Basso
    elif [ "$n_warn" -gt 0 ]; then
        notify "macguard: 新しい常駐・設定 $n_warn 件" "$(printf '%s' "${summary#; }" | cut -c1-120)"
    fi
    echo "ALERT $n_alert / WARN $n_warn / 退避 $n_evict"
}

# ---- install / uninstall / doctor -----------------------------------------------
LA_DIR="$HOME/Library/LaunchAgents"

write_plist() {
    # write_plist <label> <subcommand> <plist 本文の追加キー（XML）>
    local label="$1" sub="$2" extra="$3" f
    f="$LA_DIR/$label.plist"
    cat > "$f" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>$SCRIPT</string><string>$sub</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string></dict>
    <key>StandardOutPath</key><string>$STATE_DIR/$sub.log</string>
    <key>StandardErrorPath</key><string>$STATE_DIR/$sub.log</string>
$extra
</dict>
</plist>
EOF
    plutil -lint "$f" >/dev/null || { echo "plist が不正: $f" >&2; return 1; }
    chmod 644 "$f"
}

cmd_install() {
    local uid
    uid=$(id -u)
    mkdir -p "$LA_DIR"
    # WatchPaths で ~/Downloads を見張ると、CleanMyMac がこの plist と起動対象をアドウェアと判定する
    write_plist "$LABEL_PREFIX.downloads" scan-downloads \
        "    <key>StartInterval</key><integer>${MACGUARD_DOWNLOADS_INTERVAL:-60}</integer>
    <key>RunAtLoad</key><true/>" || return 1
    write_plist "$LABEL_PREFIX.persistence" watch-persistence \
        "    <key>StartInterval</key><integer>${MACGUARD_INTERVAL:-900}</integer>
    <key>RunAtLoad</key><true/>" || return 1
    for l in downloads persistence; do
        launchctl bootout "gui/$uid/$LABEL_PREFIX.$l" >/dev/null 2>&1
        launchctl bootstrap "gui/$uid" "$LA_DIR/$LABEL_PREFIX.$l.plist" || { echo "登録に失敗: $LABEL_PREFIX.$l" >&2; return 1; }
        echo "登録した: $LABEL_PREFIX.$l"
    done
    log_event INFO install "LaunchAgents を登録"
    echo "ログ: $STATE_DIR/*.log  状態: macguard.sh status"
    echo "plist は $SCRIPT を指している。plugin を更新してこのパスが変わったら install し直す"
}

cmd_uninstall() {
    local uid l
    uid=$(id -u)
    for l in downloads persistence; do
        launchctl bootout "gui/$uid/$LABEL_PREFIX.$l" >/dev/null 2>&1
        rm -f "$LA_DIR/$LABEL_PREFIX.$l.plist" && echo "外した: $LABEL_PREFIX.$l"
    done
    log_event INFO uninstall "LaunchAgents を解除"
}

cmd_doctor() {
    local uid ok=1
    uid=$(id -u)
    if vt_key >/dev/null 2>&1; then echo "ok    VirusTotal API key（キーチェーン or MACGUARD_VT_KEY）"
    else echo "NG    VirusTotal API key が無い。ゲートは照会不可で WARN に倒れる"; echo "      登録: security add-generic-password -a \"\$USER\" -s macguard-virustotal -w"; ok=0; fi
    for l in downloads persistence; do
        if launchctl print "gui/$uid/$LABEL_PREFIX.$l" >/dev/null 2>&1; then echo "ok    常駐 $LABEL_PREFIX.$l"
        else echo "NG    常駐 $LABEL_PREFIX.$l が未登録（macguard.sh install）"; ok=0; fi
    done
    [ -x "$AUDIT" ] && echo "ok    security-audit.sh: $AUDIT" || { echo "NG    security-audit.sh が無い: $AUDIT"; ok=0; }
    command -v jq >/dev/null && echo "ok    jq" || { echo "NG    jq が無い"; ok=0; }
    if ls "$HOME/Library/Application Support/com.apple.TCC" >/dev/null 2>&1; then echo "ok    フルディスクアクセス（ブラウザ拡張まで見える）"
    else echo "info  フルディスクアクセスなし（watch の browser セクションは一部読めない。システム設定 > プライバシー > フルディスクアクセスに Terminal を追加）"; fi
    [ "$ok" = 1 ]
}

# ---- 入口 --------------------------------------------------------------------
case "${1:-}" in
    gate)              shift; cmd_gate "$@" ;;
    scan-downloads)    cmd_scan_downloads ;;
    watch-persistence) cmd_watch_persistence ;;
    status)            shift; cmd_status "$@" ;;
    held)              cmd_held ;;
    release)           shift; cmd_release "$@" ;;
    pending)           cmd_pending ;;
    ack)               shift; cmd_ack "$@" ;;
    notify)            shift; notify "${1:?title}" "${2:?message}" "${3:-}" ;;
    install)           cmd_install ;;
    uninstall)         cmd_uninstall ;;
    doctor)            cmd_doctor ;;
    -h|--help|help|"") usage ;;
    *) echo "不明なサブコマンド: $1" >&2; usage >&2; exit 2 ;;
esac
