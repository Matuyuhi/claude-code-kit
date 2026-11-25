#!/usr/bin/env bash
set -euo pipefail

PROGRAM=${0##*/}
DEVICE_SERIAL=""
SERIAL_FROM_OPTION=false
TEMP_PATHS=()
TEMP_FILE=""
SUSPENDED_IME=""

fail() {
  echo "${PROGRAM}: $*" >&2
  exit 1
}

cleanup() {
  local path
  # `[ -e ] && rm` の形だと一時ファイルが無い時に test の失敗が trap の終了コードになり、
  # 正常終了したサブコマンドまで rc=1 になる
  for path in "${TEMP_PATHS[@]:-}"; do
    if [ -n "$path" ] && [ -e "$path" ]; then
      rm -rf "$path"
    fi
  done
  restore_ime || true
}
trap cleanup EXIT

require_commands() {
  command -v adb >/dev/null 2>&1 || fail "adb が見つかりません"
  command -v python3 >/dev/null 2>&1 || fail "python3 が見つかりません"
}

usage() {
  cat <<'EOF'
使い方:
  android-drive.sh [-s SERIAL] <subcommand> [args]

デバイス:
  devices

観察:
  shot [OUT.png]
  ui [--json]
  layout [--diff]      (android CLI 経由。Compose の clickable / selected / testTag が取れる)
  find <substring>
  current
  log [--pkg PKG] [--pattern REGEX] [--crash] [--tail N]

操作:
  tap <x> <y>
  tap-text <substring>
  tap-desc <content-desc>   (完全一致)
  tap-id <resource-id>      (完全一致)
  long <x> <y> [ms]
  swipe <up|down|left|right>
  text <string>
  key <BACK|HOME|ENTER|...>
  start <package>[/<activity>]
  stop <package>
  install-split <pkg> <bundle.apks> <split-name>
  wait <sec>
  log clear
  help

index 再生 (LLM なし。index は ~/.android-drive/<package>/index.json):
  screen                          現在の画面名を index の anchors から同定する
  wait-for <substring> [sec]      text / desc が現れるまで待つ (既定 15 秒)
  wait-for-screen <name> [sec]    画面に到達するまで待つ
  goto <name>... [sec]            index の辺を BFS で辿って画面へ移動する（複数なら順に巡る）。逸れたら停止
  flow <file> [--fail-fast]       1 行 1 サブコマンドを 1 プロセスで実行する。入力はファイル、
  flow - / flow "行" "行"...        `-` で標準入力、または引数 1 つ = 1 行。`case 名前` で項目を
                                  区切り、assert-screen / assert-text / assert-no-text /
                                  assert-alive <pkg> で検証する

index 作成 (~/.android-drive/<package>/index.json と samples/ に書く):
  index candidates                現在の画面で anchors に使える要素を列挙する
  index add-screen <name> --anchor k=v ... [--alias A]... [--update]
  index verify-screen <name> [--sample]
  index add-edge <from> <to> --step "cmd args" ... [--timeout N] [--no-verify]
  index remove-edge <from> <to>
  index add-dismiss <name> --anchor k=v ... --step "cmd args" ... [--no-verify]
  index check                     標本で anchors の一意性と辺の連結を検査する
  index list

デバイスは -s SERIAL または ANDROID_SERIAL で明示できます。未指定時は、
接続中の emulator-* が 1 台だけの場合に限り選びます。

text は ASCII のみ。入力中は IME を一時無効化し、終了時に元へ戻します。

install-split は bundle.apks 内の splits/<split-name>.apk を既存アプリへ追加します。
split-name は "feature_stats-master" のように接尾辞まで指定し、base と同じ variant 番号の
split を選んでください。bundle の versionCode がインストール済みと一致している必要があります。
EOF
}

shell_quote_command() {
  python3 - "$@" <<'PY'
import shlex
import sys

print(" ".join(shlex.quote(argument) for argument in sys.argv[1:]))
PY
}

adb_shell() {
  local command
  command=$(shell_quote_command "$@")
  adb -s "$DEVICE_SERIAL" shell "$command"
}

# `input text` はキーイベントとして届くので、有効な IME がローマ字→かな変換などを挟むと
# 送った文字列がそのまま入らない（Gboard 日本語で "hello" が "へっぉ" になる）。
# サブタイプの settings put は Gboard が即座に元へ戻すため、入力中だけ IME を無効化する。
suspend_ime() {
  local ime
  ime=$(adb_shell settings get secure default_input_method | tr -d '\r')
  if [ -z "$ime" ] || [ "$ime" = null ]; then
    return
  fi
  adb_shell ime disable "$ime" >/dev/null
  SUSPENDED_IME=$ime
}

restore_ime() {
  [ -n "$SUSPENDED_IME" ] || return 0
  adb_shell ime enable "$SUSPENDED_IME" >/dev/null
  adb_shell ime set "$SUSPENDED_IME" >/dev/null
  SUSPENDED_IME=""
}

list_devices() {
  adb devices -l | python3 -c '
import re
import sys

for line in sys.stdin:
    line = line.strip()
    if not line or line.startswith("List of devices attached"):
        continue
    columns = line.split()
    serial = columns[0]
    state = columns[1] if len(columns) > 1 else "unknown"
    model = "unknown"
    for column in columns[2:]:
        match = re.match(r"model:(.*)", column)
        if match:
            model = match.group(1)
            break
    kind = "emulator" if serial.startswith("emulator-") else "physical"
    print("serial={}  model={}  type={}  state={}".format(serial, model, kind, state))
'
}

select_device() {
  local requested="${DEVICE_SERIAL:-${ANDROID_SERIAL:-}}"
  local serial state ignored
  local candidates=()

  if [ -n "$requested" ]; then
    if [ "$SERIAL_FROM_OPTION" = false ] && [[ "$requested" != emulator-* ]]; then
      fail "実機を操作するには -s SERIAL で明示してください"
    fi
    while IFS=$'\t' read -r serial state ignored; do
      if [ "$serial" = "$requested" ] && [ "$state" = "device" ]; then
        DEVICE_SERIAL=$requested
        return
      fi
    done < <(adb devices | python3 -c '
import sys
for line in sys.stdin:
    columns = line.split()
    if len(columns) >= 2 and columns[0] != "List":
        print("{}\t{}".format(columns[0], columns[1]))
')
    fail "指定したデバイスが接続済みではありません: $requested"
  fi

  while IFS=$'\t' read -r serial state ignored; do
    if [ "$state" = "device" ]; then
      candidates+=("$serial")
    fi
  done < <(adb devices | python3 -c '
import sys
for line in sys.stdin:
    columns = line.split()
    if len(columns) >= 2 and columns[0] != "List":
        print("{}\t{}".format(columns[0], columns[1]))
')

  if [ "${#candidates[@]}" -ne 1 ] || [[ "${candidates[0]:-}" != emulator-* ]]; then
    fail "操作対象を自動選択できません。-s SERIAL を指定してください"
  fi
  DEVICE_SERIAL=${candidates[0]}
}

make_temp_file() {
  local suffix=$1
  local directory="${TMPDIR:-/tmp}/android-drive"
  mkdir -p "$directory"
  # macOS の mktemp は末尾以外の XXXXXX を展開しないため、拡張子は X 列の前に置く
  TEMP_FILE=$(mktemp "$directory/android-drive${suffix}.XXXXXX")
  TEMP_PATHS+=("$TEMP_FILE")
}

dump_ui_json() {
  local output=$1
  local xml
  make_temp_file .xml
  xml=$TEMP_FILE
  # android layout（UiAutomation 経由）の直後だとサービス登録が残っていて
  # "UiAutomationService already registered" で dump プロセスが落ちるので、1 回だけ待って再試行する
  if ! adb_shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; then
    sleep 1
    adb_shell uiautomator dump /sdcard/ui.xml >/dev/null
  fi
  adb -s "$DEVICE_SERIAL" exec-out cat /sdcard/ui.xml > "$xml"
  python3 - "$xml" > "$output" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
try:
    root = ET.parse(xml_path).getroot()
except (ET.ParseError, OSError) as error:
    raise SystemExit("ui: XML の読み取りに失敗しました: {}".format(error))

nodes = []
for node in root.iter("node"):
    attributes = node.attrib
    text = attributes.get("text", "")
    description = attributes.get("content-desc", "")
    resource_id = attributes.get("resource-id", "")
    if not text and not description and not resource_id:
        continue
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", attributes.get("bounds", ""))
    if not match:
        continue
    x1, y1, x2, y2 = (int(value) for value in match.groups())
    nodes.append({
        "bounds": [x1, y1, x2, y2],
        "center": [(x1 + x2) // 2, (y1 + y2) // 2],
        "text": text,
        "content_desc": description,
        "resource_id": resource_id,
        "clickable": attributes.get("clickable", "false") == "true",
    })

json.dump(nodes, sys.stdout, ensure_ascii=False)
PY
}

format_nodes() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    nodes = json.load(source)

def quote(value):
    return value.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n").replace("\r", "\\r")

for node in nodes:
    x1, y1, x2, y2 = node["bounds"]
    cx, cy = node["center"]
    line = "[{},{}][{},{}] {},{}  text='{}'  desc='{}'  id={}".format(
        x1, y1, x2, y2, cx, cy, quote(node["text"]), quote(node["content_desc"]), node["resource_id"] or "-"
    )
    if node["clickable"]:
        line += "  [clickable]"
    print(line)
PY
}

# mode: contains(既定。text / desc の部分一致) | text | desc | id(それぞれ完全一致)
find_nodes_json() {
  python3 - "$1" "$2" "${3:-contains}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    nodes = json.load(source)

needle, mode = sys.argv[2], sys.argv[3]
if mode == "contains":
    matches = [node for node in nodes if needle in node["text"] or needle in node["content_desc"]]
else:
    field = {"text": "text", "desc": "content_desc", "id": "resource_id"}[mode]
    matches = [node for node in nodes if node[field] == needle]
json.dump(matches, sys.stdout, ensure_ascii=False)
PY
}

# 一致した先頭ノードの中心をタップする。tap-text / tap-desc / tap-id の共通実装
tap_first_match() {
  local label=$1 needle=$2 mode=$3
  local tap_json matches_json count coordinates tap_x tap_y
  make_temp_file .json
  tap_json=$TEMP_FILE
  make_temp_file .json
  matches_json=$TEMP_FILE
  dump_ui_json "$tap_json"
  find_nodes_json "$tap_json" "$needle" "$mode" > "$matches_json"
  count=$(python3 - "$matches_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    print(len(json.load(source)))
PY
)
  [ "$count" -gt 0 ] || fail "一致するノードがありません: $needle"
  if [ "$count" -gt 1 ]; then
    echo "${label}: ${count} 件一致したため先頭を使います:" >&2
    format_nodes "$matches_json" >&2
  fi
  coordinates=$(python3 - "$matches_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    node = json.load(source)[0]
print("{} {}".format(*node["center"]))
PY
)
  read -r tap_x tap_y <<EOF
$coordinates
EOF
  adb_shell input tap "$tap_x" "$tap_y"
}

# Google 公式 android CLI の layout を ui と同じ行形式に揃える。
# uiautomator と違い Compose の clickable / selected / testTag(resource-id) が取れるので、
# 「選択状態が変わったか」「どの testTag か」の判定にはこちらを使う。
# 操作系コマンドは android CLI に無いので観察専用。sandbox 内では JNI の一時ファイルが
# 作れず落ちるため、失敗時は ui へ誘導する
show_layout() {
  local diff=false
  if [ "${1:-}" = --diff ]; then
    diff=true
    shift
  fi
  [ "$#" -eq 0 ] || fail "layout の引数が不正です: $1"
  command -v android >/dev/null 2>&1 || fail "android CLI が見つかりません。ui を使ってください"

  local json
  make_temp_file .json
  json=$TEMP_FILE
  local -a args=(layout -p "--device=$DEVICE_SERIAL")
  [ "$diff" = false ] || args+=(--diff)
  # JAVA_TOOL_OPTIONS の "Picked up ..." が stderr に混ざるので stderr は捨てる
  if ! android "${args[@]}" > "$json" 2>/dev/null; then
    fail "android layout が失敗しました。sandbox 内では動かないので ui を使うか、sandbox 外で実行してください"
  fi
  python3 - "$json" "$diff" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    raw = source.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError as error:
    raise SystemExit("layout: JSON を読めません: {}".format(error))

def quote(value):
    return value.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n")

def render(node):
    center = re.match(r"\[(\d+),(\d+)\]", node.get("center", "")) or re.match(r"\[(\d+),(\d+)\]", node.get("bounds", ""))
    cx, cy = (center.group(1), center.group(2)) if center else ("-", "-")
    line = "{}  {},{}  text='{}'  desc='{}'  id={}".format(
        node.get("bounds", "-"),
        cx, cy,
        quote(node.get("text", "")),
        quote(node.get("content-desc", "")),
        node.get("resource-id") or "-",
    )
    flags = [i for i in node.get("interactions", []) if i != "focusable"] + node.get("state", [])
    if flags:
        line += "  [" + ",".join(flags) + "]"
    return line

if sys.argv[2] == "true":
    for section in ("added", "modified"):
        items = data.get(section, [])
        print("== {} ({}) ==".format(section, len(items)))
        for node in items:
            print(render(node))
else:
    for node in data:
        # text / desc / id / 操作可能性のどれも無いノードは座標しか無く、操作の手がかりにならない
        if not (node.get("text") or node.get("content-desc") or node.get("resource-id") or node.get("interactions") or node.get("state")):
            continue
        print(render(node))
PY
}

screen_size() {
  local size
  size=$(adb_shell wm size | python3 -c '
import re
import sys

for line in sys.stdin:
    match = re.search(r"(\d+)x(\d+)", line)
    if match:
        print("{} {}".format(match.group(1), match.group(2)))
        break
')
  [ -n "$size" ] || fail "画面サイズを取得できません"
  printf '%s\n' "$size"
}

show_current() {
  adb_shell dumpsys activity activities | python3 -c '
import re
import sys

for line in sys.stdin:
    match = re.search(r"topResumedActivity[=:]\s*ActivityRecord\{[^ ]+\s+(?:u\d+\s+)?([^ }]+)", line)
    if match:
        print(match.group(1))
        break
else:
    raise SystemExit("current: topResumedActivity を取得できません")
'
}

show_log() {
  local package=""
  local pattern=""
  local crash=false
  local tail_count=""
  local pid=""
  local -a logcat_args=(-d -v threadtime)

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pkg)
        [ "$#" -ge 2 ] || fail "log --pkg には package が必要です"
        package=$2
        shift 2
        ;;
      --pattern)
        [ "$#" -ge 2 ] || fail "log --pattern には REGEX が必要です"
        pattern=$2
        shift 2
        ;;
      --crash)
        crash=true
        shift
        ;;
      --tail)
        [ "$#" -ge 2 ] || fail "log --tail には件数が必要です"
        [[ "$2" =~ ^[0-9]+$ ]] || fail "log --tail は 0 以上の整数で指定してください"
        tail_count=$2
        shift 2
        ;;
      *)
        fail "log の引数が不正です: $1"
        ;;
    esac
  done

  if [ -n "$package" ]; then
    pid=$(adb_shell pidof "$package" | tr -d '\r\n')
    [ -n "$pid" ] || fail "対象 package の PID を取得できません: $package"
  fi
  if [ "$crash" = true ]; then
    logcat_args+=(-b crash)
  fi

  local log_file
  make_temp_file .log
  log_file=$TEMP_FILE
  adb -s "$DEVICE_SERIAL" logcat "${logcat_args[@]}" > "$log_file"
  python3 - "$log_file" "$pid" "$pattern" "$tail_count" <<'PY'
import re
import sys

log_file = sys.argv[1]
pids = set(sys.argv[2].split())
pattern = sys.argv[3]
tail_count = sys.argv[4]
try:
    matcher = re.compile(pattern) if pattern else None
except re.error as error:
    raise SystemExit("log: 正規表現が不正です: {}".format(error))

lines = []
with open(log_file, encoding="utf-8", errors="replace") as source:
    for line in source:
        if pids:
            match = re.match(r"^\d\d-\d\d\s+\d\d:\d\d:\d\d\.\d\d\d\s+(\d+)\s+\d+", line)
            if not match or match.group(1) not in pids:
                continue
        if matcher and not matcher.search(line):
            continue
        lines.append(line)

if tail_count:
    lines = lines[-int(tail_count):]
sys.stdout.writelines(lines)
PY
}

install_split() {
  local package=$1
  local bundle=$2
  local split_name=$3
  local directory apk

  [ -f "$bundle" ] || fail "bundle.apks が見つかりません: $bundle"
  directory=$(mktemp -d "${TMPDIR:-/tmp}/android-drive-install.XXXXXX")
  TEMP_PATHS+=("$directory")
  apk="$directory/split.apk"
  python3 - "$bundle" "$split_name" "$apk" <<'PY'
import shutil
import sys
import zipfile

bundle, split_name, output = sys.argv[1:]
entry = "splits/{}.apk".format(split_name)
try:
    with zipfile.ZipFile(bundle) as archive:
        names = archive.namelist()
        if entry not in names:
            # feature の split は "<module>-master.apk" のように接尾辞付きで、variant 違いの "-master_2" も並ぶ
            available = sorted(
                name[len("splits/"):-len(".apk")]
                for name in names
                if name.startswith("splits/") and not name.startswith("splits/base-")
            )
            raise SystemExit(
                "install-split: {} が bundle にありません。指定できる split: {}".format(
                    entry, ", ".join(available) or "(なし)"
                )
            )
        with archive.open(entry) as source, open(output, "wb") as destination:
            shutil.copyfileobj(source, destination)
except (OSError, zipfile.BadZipFile) as error:
    raise SystemExit("install-split: {} を展開できません: {}".format(entry, error))
PY
  adb -s "$DEVICE_SERIAL" install-multiple -r -p "$package" "$apk"
}

current_package() {
  local component
  component=$(show_current)
  printf '%s\n' "${component%%/*}"
}

# index はアプリの repo に置くと毎回差分になるので、package ごとに home 側へ置く。
# 見つからなくても空を返し、index が要るサブコマンド側で失敗させる（wait-for は index 不要）
index_file() {
  printf '%s\n' "$HOME/.android-drive/$1/index.json"
}

locate_index() {
  local candidate
  candidate=$(index_file "$1")
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
  fi
}

# 画面グラフ index を使った LLM なしの再生。画面の同定は uiautomator dump 上の
# text / content-desc / resource-id の組（anchors）だけで行い、アプリ固有のログには依存しない。
# 操作は全てこのスクリプト自身のサブコマンドを子プロセスで呼ぶ
run_navigator() {
  local package index
  package=$(current_package)
  index=$(locate_index "$package")
  python3 - "${BASH_SOURCE[0]}" "$DEVICE_SERIAL" "$package" "$index" "$(index_file "$package")" "$@" <<'PY'
import json
import os
import re
import shlex
import subprocess
import sys
import time
from collections import deque

script, serial, package, index_path, write_path, mode, *args = sys.argv[1:]
DEFAULT_TIMEOUT = 15.0
FIELDS = {"text": "text", "desc": "content_desc", "id": "resource_id"}


def run(*command, capture=False):
    return subprocess.run(["bash", script, "-s", serial, *map(str, command)], text=True, capture_output=capture)


BOUNDS = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


def dump():
    """uiautomator dump を stdout 直出しで 1 回の adb 呼び出しで取る（ui --json を子プロセスで呼ぶより 1 秒強速い）。
    dump_ui_json と同じ形のノードにする"""
    import xml.etree.ElementTree as ET
    command = ["adb", "-s", serial, "exec-out", "uiautomator", "dump", "/dev/tty"]
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0 or b"<hierarchy" not in result.stdout:
        # layout（UiAutomation）直後はサービス登録が残って落ちるので 1 回だけ待って再試行
        time.sleep(1)
        result = subprocess.run(command, capture_output=True)
        if result.returncode != 0 or b"<hierarchy" not in result.stdout:
            raise SystemExit("ui の取得に失敗しました: " + result.stderr.decode("utf-8", "replace").strip())
    # 末尾に "UI hierchary dumped to: /dev/tty" が付くので XML 本体だけ切り出す
    raw = result.stdout
    start = raw.find(b"<?xml")
    end = raw.rfind(b"</hierarchy>")
    if start < 0 or end < 0:
        raise SystemExit("ui: XML を取り出せません")
    try:
        root = ET.fromstring(raw[start:end + len(b"</hierarchy>")])
    except ET.ParseError as error:
        raise SystemExit("ui: XML の読み取りに失敗しました: {}".format(error))
    nodes = []
    for node in root.iter("node"):
        attributes = node.attrib
        text = attributes.get("text", "")
        description = attributes.get("content-desc", "")
        resource_id = attributes.get("resource-id", "")
        match = BOUNDS.fullmatch(attributes.get("bounds", ""))
        if not match or not (text or description or resource_id):
            continue
        x1, y1, x2, y2 = (int(value) for value in match.groups())
        nodes.append({
            "bounds": [x1, y1, x2, y2],
            "center": [(x1 + x2) // 2, (y1 + y2) // 2],
            "text": text,
            "content_desc": description,
            "resource_id": resource_id,
            "clickable": attributes.get("clickable", "false") == "true",
        })
    return nodes


TAP_STEPS = {"tap-text": None, "tap-desc": "content_desc", "tap-id": "resource_id"}


def tap_from_nodes(step, nodes):
    """直前の dump から対象を引いて座標タップする。再 dump（約 3 秒）を省くため"""
    command, needle = step[0], str(step[1])
    field = TAP_STEPS[command]
    if field is None:
        hits = [n for n in nodes if needle in n["text"] or needle in n["content_desc"]]
    else:
        hits = [n for n in nodes if n[field] == needle]
    if not hits:
        return False
    x, y = hits[0]["center"]
    subprocess.run(["adb", "-s", serial, "shell", "input", "tap", str(x), str(y)], check=True)
    return True


def load_index():
    if not index_path:
        raise SystemExit(
            "index が見つかりません: {}".format(write_path)
        )
    with open(index_path, encoding="utf-8") as source:
        index = json.load(source)
    screens = index.get("screens")
    if not isinstance(screens, dict) or not screens:
        raise SystemExit("index: screens がありません: {}".format(index_path))
    for name, screen in screens.items():
        if not screen.get("anchors"):
            raise SystemExit("index: 画面 {} に anchors がありません".format(name))
    for edge in index.get("edges", []):
        for end in ("from", "to"):
            if edge.get(end) not in screens:
                raise SystemExit("index: edge の {} が未登録の画面です: {}".format(end, edge.get(end)))
    return index


def node_matches(anchor, node):
    # 1 つの anchor は 1 ノードが全キーを満たすこと。キー末尾の * は部分一致
    for key, value in anchor.items():
        field = FIELDS.get(key.rstrip("*"))
        if field is None:
            raise SystemExit("index: 不明な anchor キー: {}（text / desc / id とその * 付き）".format(key))
        actual = node[field]
        if key.endswith("*"):
            if value not in actual:
                return False
        elif actual != value:
            return False
    return True


def anchor_present(anchor, nodes):
    return any(node_matches(anchor, node) for node in nodes)


def identify(index, nodes):
    """全 anchors が揃った画面のうち anchors が最も多いものを返す。無ければ (None, 近い候補)"""
    scored = []
    for name, screen in index["screens"].items():
        anchors = screen["anchors"]
        hit = sum(1 for anchor in anchors if anchor_present(anchor, nodes))
        scored.append((name, hit, len(anchors)))
    full = sorted((s for s in scored if s[1] == s[2]), key=lambda s: -s[2])
    if full:
        if len(full) > 1 and full[0][2] == full[1][2]:
            names = [s[0] for s in full if s[2] == full[0][2]]
            raise SystemExit("screen: 複数の画面が同時に一致します: {}（anchors を増やして区別してください）".format(", ".join(names)))
        return full[0][0], []
    scored.sort(key=lambda s: (-(s[1] / s[2]), -s[1]))
    return None, ["{} ({}/{})".format(*s) for s in scored[:3]]


def describe(name, candidates):
    return name or "unknown（近い候補: {}）".format(", ".join(candidates))


def resolve_name(index, name):
    if name in index["screens"]:
        return name
    for key, screen in index["screens"].items():
        if name in screen.get("aliases", []):
            return key
    raise SystemExit("index に画面がありません: {}（登録: {}）".format(name, ", ".join(index["screens"])))


def run_steps(steps, where, nodes=None):
    """nodes は steps 実行前の画面の dump。最初の tap 系 step はそこから座標を引く。
    1 手目以降は画面が変わっているので使わない"""
    for step in steps:
        if not isinstance(step, list) or not step:
            raise SystemExit("index: {} の step が不正です: {!r}".format(where, step))
        print("  > " + " ".join(shlex.quote(str(word)) for word in step), flush=True)
        if step[0] in TAP_STEPS and len(step) == 2:
            if nodes is None:
                nodes = dump()
            if not tap_from_nodes(step, nodes):
                raise SystemExit("{}: 一致するノードがありません: {}".format(where, step[1]))
        elif run(*step).returncode != 0:
            raise SystemExit("{}: step が失敗しました: {}".format(where, " ".join(map(str, step))))
        nodes = None


def apply_dismiss(index, nodes):
    """起動時ポップアップ等の「あれば閉じる」ルールを適用し、閉じた後のノードを返す"""
    for _ in range(3):
        rule = next((r for r in index.get("dismiss", []) if all(anchor_present(a, nodes) for a in r["anchors"])), None)
        if rule is None:
            return nodes
        print("  dismiss: " + rule.get("name", json.dumps(rule["anchors"], ensure_ascii=False)), flush=True)
        run_steps(rule["steps"], "dismiss", nodes)
        time.sleep(1)
        nodes = dump()
    return nodes


def parse_timeout(value):
    try:
        timeout = float(value)
    except ValueError:
        raise SystemExit("タイムアウトは秒数で指定してください: {}".format(value))
    if timeout <= 0:
        raise SystemExit("タイムアウトは正の秒数で指定してください: {}".format(value))
    return timeout


def wait_for_screen(index, target, timeout):
    """到達したら、その時点の dump を返す（次の辺の tap がそれを使う）"""
    deadline = time.monotonic() + timeout
    while True:
        nodes = apply_dismiss(index, dump())
        name, candidates = identify(index, nodes)
        if name == target:
            return nodes
        if time.monotonic() >= deadline:
            raise SystemExit("{:g} 秒以内に {} に到達しませんでした。現在: {}".format(timeout, target, describe(name, candidates)))
        time.sleep(1)


def text_hits(nodes, needle):
    return [n for n in nodes if needle in n["text"] or needle in n["content_desc"]]


def wait_for_text(needle, timeout):
    """現れた時点の dump を返す"""
    deadline = time.monotonic() + timeout
    while True:
        nodes = dump()
        hits = text_hits(nodes, needle)
        if hits:
            print("{} {}".format(*hits[0]["center"]))
            return nodes
        if time.monotonic() >= deadline:
            raise SystemExit("{:g} 秒以内に '{}' が現れませんでした".format(timeout, needle))
        time.sleep(1)


class State:
    """flow / goto が行をまたいで持ち回る「今どの画面で、直前の dump は何か」。
    dump は 1 回 2 秒かかるので、画面を変えない行はこれを使い回す"""

    def __init__(self):
        self.current = None
        self.nodes = None
        self.pids = {}

    def fresh_nodes(self):
        if self.nodes is None:
            self.nodes = dump()
        return self.nodes

    def invalidate(self):
        self.current = None
        self.nodes = None


def find_path(index, start, goal):
    graph = {}
    for edge in index.get("edges", []):
        graph.setdefault(edge["from"], []).append(edge)
    queue = deque([(start, [])])
    seen = {start}
    while queue:
        node, path = queue.popleft()
        if node == goal:
            return path
        for edge in graph.get(node, []):
            if edge["to"] not in seen:
                seen.add(edge["to"])
                queue.append((edge["to"], path + [edge]))
    return None


def goto(index, target_names, timeout, state):
    """複数指定は順に巡る。state に現在地が残っていれば同定の dump を省き、到達時の画面と dump を state に残す"""
    targets = [resolve_name(index, name) for name in target_names]
    if state.current is None:
        state.nodes = apply_dismiss(index, dump())
        current, candidates = identify(index, state.nodes)
        if current is None:
            state.invalidate()
            raise SystemExit(
                "現在の画面を同定できません。近い候補: {}。index に画面を追加するか、既知の画面へ移動してから実行してください".format(", ".join(candidates))
            )
        state.current = current
    print("現在: {}".format(state.current))
    for target in targets:
        if state.current == target:
            print("到達: {}".format(target))
            continue
        path = find_path(index, state.current, target)
        if path is None:
            raise SystemExit("{} から {} への経路が index にありません".format(state.current, target))
        print("経路: " + " → ".join([state.current] + [edge["to"] for edge in path]))
        for edge in path:
            where = "{} → {}".format(edge["from"], edge["to"])
            print(where)
            run_steps(edge["steps"], where, state.nodes)
            state.invalidate()
            try:
                state.nodes = wait_for_screen(index, edge["to"], edge.get("timeout", timeout))
            except SystemExit as error:
                raise SystemExit("{} で逸脱: {}".format(where, error))
            state.current = edge["to"]
        print("到達: {}".format(target))


# UI を変えないサブコマンド。これ以外を実行したら state の画面と dump は捨てる
READ_ONLY_COMMANDS = {"shot", "log", "current", "devices", "find", "ui", "layout"}


def app_pid(package_name):
    result = subprocess.run(["adb", "-s", serial, "shell", "pidof", package_name], capture_output=True, text=True)
    return result.stdout.strip()


def run_flow_line(words, index, state, timeout):
    """flow の 1 行を、state を使い回しながら 1 プロセス内で実行する。失敗は SystemExit"""
    command, rest = words[0], words[1:]
    if command == "goto":
        line_timeout = timeout
        if len(rest) >= 2 and re.fullmatch(r"\d+(\.\d+)?", rest[-1]):
            line_timeout = parse_timeout(rest[-1])
            rest = rest[:-1]
        if not rest:
            raise SystemExit("goto には画面名が必要です")
        goto(index(), rest, line_timeout, state)
    elif command == "wait-for":
        if len(rest) not in (1, 2):
            raise SystemExit("wait-for には substring [秒数] が必要です")
        state.nodes = wait_for_text(rest[0], parse_timeout(rest[1]) if len(rest) == 2 else timeout)
    elif command == "wait-for-screen":
        if len(rest) not in (1, 2):
            raise SystemExit("wait-for-screen には画面名 [秒数] が必要です")
        target = resolve_name(index(), rest[0])
        state.nodes = wait_for_screen(index(), target, parse_timeout(rest[1]) if len(rest) == 2 else timeout)
        state.current = target
    elif command == "screen":
        name, candidates = identify(index(), state.fresh_nodes())
        print(describe(name, candidates))
        state.current = name
    elif command == "assert-screen":
        if len(rest) != 1:
            raise SystemExit("assert-screen には画面名が必要です")
        expected = resolve_name(index(), rest[0])
        name, candidates = identify(index(), state.fresh_nodes())
        if name != expected:
            raise SystemExit("assert-screen: 現在は {}（期待: {}）".format(describe(name, candidates), expected))
        state.current = name
    elif command in ("assert-text", "assert-no-text"):
        if len(rest) != 1:
            raise SystemExit("{} には文言が必要です".format(command))
        found = bool(text_hits(state.fresh_nodes(), rest[0]))
        if command == "assert-text" and not found:
            raise SystemExit("assert-text: '{}' が画面にありません".format(rest[0]))
        if command == "assert-no-text" and found:
            raise SystemExit("assert-no-text: '{}' が画面にあります".format(rest[0]))
    elif command == "assert-alive":
        if len(rest) != 1:
            raise SystemExit("assert-alive には package が必要です")
        pid = app_pid(rest[0])
        if not pid:
            raise SystemExit("assert-alive: {} のプロセスがありません".format(rest[0]))
        first = state.pids.setdefault(rest[0], pid)
        if pid != first:
            raise SystemExit("assert-alive: {} の pid が {} → {} に変わりました（再起動 = クラッシュの疑い）".format(rest[0], first, pid))
    elif command in TAP_STEPS and len(rest) == 1:
        if not tap_from_nodes([command, rest[0]], state.fresh_nodes()):
            raise SystemExit("{}: 一致するノードがありません: {}".format(command, rest[0]))
        state.invalidate()
    else:
        if run(*words).returncode != 0:
            raise SystemExit("{} が失敗しました".format(" ".join(words)))
        if command not in READ_ONLY_COMMANDS:
            state.invalidate()


def read_flow_lines(sources):
    """flow の入力。既存ファイル 1 つ（`-` は bash 側で一時ファイルに落ちて来る）/ それ以外は引数 1 つを 1 行として扱う"""
    if len(sources) == 1 and os.path.isfile(sources[0]):
        try:
            with open(sources[0], encoding="utf-8") as source:
                return sources[0], source.read().splitlines()
        except OSError as error:
            raise SystemExit("flow: ファイルを読めません: {}".format(error))
    return "(args)", list(sources)


def flow(sources, fail_fast, timeout):
    """1 行 1 手のテキストを 1 プロセスで順に実行する。`case 名前` で検証項目を区切り、
    項目内の失敗は記録して次の case へ進む（--fail-fast ならその場で止まる）"""
    path, lines = read_flow_lines(sources)
    cached = {}

    def index():
        if "index" not in cached:
            cached["index"] = load_index()
        return cached["index"]

    state = State()
    results = []  # (case 名, 失敗メッセージ or None, 秒)
    case_name, case_started, case_error = None, time.monotonic(), None

    def close_case():
        if case_name is not None:
            results.append((case_name, case_error, time.monotonic() - case_started))

    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        words = shlex.split(line)
        if words[0] == "case":
            close_case()
            case_name, case_started, case_error = " ".join(words[1:]) or "(無名)", time.monotonic(), None
            print("== case {}".format(case_name), flush=True)
            continue
        if case_error is not None:
            continue  # 失敗した case の残りは飛ばす
        print("[{}] {}".format(number, line), flush=True)
        try:
            run_flow_line(words, index, state, timeout)
        except SystemExit as error:
            message = "{}:{} {}".format(path, number, error)
            if fail_fast or case_name is None:
                close_case()
                raise SystemExit("flow: " + message)
            case_error = message
            state.invalidate()
            print("  FAIL: {}".format(error), flush=True)
    close_case()
    if results:
        failed = [r for r in results if r[1] is not None]
        print("")
        for name, error, seconds in results:
            print("{}  {}  ({:.0f}s){}".format("FAIL" if error else "PASS", name, seconds, "  " + error if error else ""))
        print("{} cases, {} failed".format(len(results), len(failed)))
        if failed:
            sys.exit(1)


# ---- index 作成の補助（LLM は名前付けと anchors の選択だけを担い、検証と書き込みはここで行う）

def load_or_new_index():
    if index_path and os.path.exists(index_path):
        return load_index()
    return {"package": package, "screens": {}, "edges": [], "dismiss": []}


def save_index(index):
    os.makedirs(os.path.dirname(write_path), exist_ok=True)
    temporary = write_path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as target:
        json.dump(index, target, ensure_ascii=False, indent=2)
        target.write("\n")
    os.replace(temporary, write_path)


def sample_path(name):
    # 画面ごとの dump 標本。anchors の一意性チェックと index check の材料
    return os.path.join(os.path.dirname(write_path), "samples", name + ".json")


def load_samples(index):
    samples = {}
    for name in index["screens"]:
        try:
            with open(sample_path(name), encoding="utf-8") as source:
                samples[name] = json.load(source)
        except (OSError, json.JSONDecodeError):
            pass
    return samples


def save_sample(name, nodes):
    os.makedirs(os.path.dirname(sample_path(name)), exist_ok=True)
    with open(sample_path(name), "w", encoding="utf-8") as target:
        json.dump(nodes, target, ensure_ascii=False)


def parse_anchor(value):
    key, separator, needle = value.partition("=")
    if not separator or key.rstrip("*") not in FIELDS or not needle:
        raise SystemExit("--anchor は text=値 / desc=値 / id=値（部分一致は text*=値）の形で指定してください: {}".format(value))
    return {key: needle}


def parse_options(argv, flags_with_value):
    """--key value 形式のオプションを集める。同じ key は繰り返し可。残りは位置引数"""
    options = {key: [] for key in flags_with_value}
    positional = []
    iterator = iter(argv)
    for word in iterator:
        if word in flags_with_value:
            try:
                options[word].append(next(iterator))
            except StopIteration:
                raise SystemExit("{} には値が必要です".format(word))
        elif word.startswith("--") and word not in flags_with_value:
            options.setdefault(word, []).append(True)
        else:
            positional.append(word)
    return options, positional


VOLATILE_TEXT = re.compile(r"\d")


def index_candidates():
    """現在の画面で anchors に使えそうな要素を出す。数字入り text は日付・金額・件数の疑いで除く"""
    index = load_or_new_index()
    samples = load_samples(index)
    nodes = dump()
    seen = set()
    for key, field in (("id", "resource_id"), ("desc", "content_desc"), ("text", "text")):
        for node in nodes:
            value = node[field]
            if not value or (key, value) in seen:
                continue
            if key == "id" and value.startswith("android:"):
                continue
            if key == "text" and (VOLATILE_TEXT.search(value) or len(value) > 20):
                continue
            seen.add((key, value))
            elsewhere = [name for name, sample in samples.items() if anchor_present({key: value}, sample)]
            note = "  (他画面にも: {})".format(", ".join(elsewhere)) if elsewhere else ""
            print("{}={}{}".format(key, value, note))


def index_add_screen(argv):
    options, positional = parse_options(argv, ("--anchor", "--alias"))
    if len(positional) != 1:
        raise SystemExit("index add-screen <name> --anchor k=v [--anchor k=v]... [--alias A]...")
    name = positional[0]
    anchors = [parse_anchor(value) for value in options["--anchor"]]
    if len(anchors) < 2:
        raise SystemExit("anchors は 2 つ以上指定してください（1 つでは他画面と区別しにくい）")
    index = load_or_new_index()
    update = bool(options.get("--update"))
    if name in index["screens"] and not update:
        raise SystemExit("画面 {} は既に登録されています。置き換えるなら --update を付けてください".format(name))
    nodes = dump()
    missing = [anchor for anchor in anchors if not anchor_present(anchor, nodes)]
    if missing:
        raise SystemExit("現在の画面に無い anchor があります: {}".format(json.dumps(missing, ensure_ascii=False)))
    samples = load_samples(index)
    for other, sample in samples.items():
        if other != name and all(anchor_present(anchor, sample) for anchor in anchors):
            raise SystemExit("この anchors は {} の標本にも全部揃っています。区別できる要素を足してください".format(other))
    for other, screen in index["screens"].items():
        if other != name and all(anchor_present(anchor, nodes) for anchor in screen["anchors"]):
            raise SystemExit("{} の anchors がこの画面にも全部揃っています。{} 側の anchors を見直してください".format(other, other))
    index["screens"][name] = {"aliases": options["--alias"], "anchors": anchors}
    save_sample(name, nodes)
    save_index(index)
    print("登録: {} anchors={} aliases={} -> {}".format(name, len(anchors), options["--alias"], write_path))


def index_verify_screen(argv):
    options, positional = parse_options(argv, ())
    if len(positional) != 1:
        raise SystemExit("index verify-screen <name> [--sample]")
    index = load_index()
    name = resolve_name(index, positional[0])
    nodes = dump()
    found, candidates = identify(index, nodes)
    if found != name:
        raise SystemExit("現在の画面は {} と同定されました（期待: {}）".format(describe(found, candidates), name))
    if options.get("--sample"):
        save_sample(name, nodes)
    print("ok: {}".format(name))


def parse_steps(values):
    steps = [shlex.split(value) for value in values]
    if not steps or any(not step for step in steps):
        raise SystemExit("--step \"tap-desc お知らせ\" の形で 1 つ以上指定してください")
    return steps


def index_add_edge(argv):
    options, positional = parse_options(argv, ("--step", "--timeout"))
    if len(positional) != 2:
        raise SystemExit("index add-edge <from> <to> --step \"cmd args\" [--step ...] [--timeout N] [--no-verify]")
    index = load_index()
    source, target = (resolve_name(index, positional[0]), resolve_name(index, positional[1]))
    steps = parse_steps(options["--step"])
    edge = {"from": source, "to": target, "steps": steps}
    if options["--timeout"]:
        edge["timeout"] = parse_timeout(options["--timeout"][-1])
    if any(e["from"] == source and e["to"] == target for e in index["edges"]):
        raise SystemExit("辺 {} → {} は既にあります".format(source, target))
    if not options.get("--no-verify"):
        current, candidates = identify(index, apply_dismiss(index, dump()))
        if current != source:
            raise SystemExit("現在の画面は {} です。{} の画面で実行するか --no-verify を付けてください".format(describe(current, candidates), source))
        run_steps(steps, "{} → {}".format(source, target))
        wait_for_screen(index, target, edge.get("timeout", DEFAULT_TIMEOUT))
        print("到達を確認: {}".format(target))
    index["edges"].append(edge)
    save_index(index)
    print("辺を追加: {} → {} {}".format(source, target, json.dumps(steps, ensure_ascii=False)))


def index_add_dismiss(argv):
    options, positional = parse_options(argv, ("--anchor", "--step"))
    if len(positional) != 1:
        raise SystemExit("index add-dismiss <name> --anchor k=v... --step \"cmd args\"... [--no-verify]")
    index = load_or_new_index()
    anchors = [parse_anchor(value) for value in options["--anchor"]]
    steps = parse_steps(options["--step"])
    if not anchors:
        raise SystemExit("--anchor を 1 つ以上指定してください")
    if not options.get("--no-verify"):
        nodes = dump()
        missing = [anchor for anchor in anchors if not anchor_present(anchor, nodes)]
        if missing:
            raise SystemExit("現在の画面に無い anchor があります: {}".format(json.dumps(missing, ensure_ascii=False)))
        run_steps(steps, "dismiss " + positional[0])
        time.sleep(1)
        if all(anchor_present(anchor, dump()) for anchor in anchors):
            raise SystemExit("steps を実行しても anchors が残っています。閉じる操作を見直してください")
    index.setdefault("dismiss", []).append({"name": positional[0], "anchors": anchors, "steps": steps})
    save_index(index)
    print("dismiss を追加: {}".format(positional[0]))


def index_check():
    index = load_index()
    samples = load_samples(index)
    problems = []
    for name in index["screens"]:
        sample = samples.get(name)
        if sample is None:
            problems.append("{}: 標本がありません（verify-screen --sample で採取）".format(name))
            continue
        try:
            found, candidates = identify(index, sample)
        except SystemExit as error:
            problems.append("{}: {}".format(name, error))
            continue
        if found != name:
            problems.append("{}: 自分の標本が {} と同定されます".format(name, describe(found, candidates)))
    incoming = {name: 0 for name in index["screens"]}
    outgoing = {name: 0 for name in index["screens"]}
    for edge in index.get("edges", []):
        incoming[edge["to"]] += 1
        outgoing[edge["from"]] += 1
    for name in index["screens"]:
        if incoming[name] == 0:
            problems.append("{}: 到達する辺がありません".format(name))
        if outgoing[name] == 0:
            problems.append("{}: 出る辺がありません（戻れない）".format(name))
    print("screens={} edges={} dismiss={} samples={}".format(len(index["screens"]), len(index.get("edges", [])), len(index.get("dismiss", [])), len(samples)))
    if problems:
        raise SystemExit("\n".join(problems))
    print("ok")


def index_list():
    index = load_index()
    incoming = {name: 0 for name in index["screens"]}
    outgoing = {name: 0 for name in index["screens"]}
    for edge in index.get("edges", []):
        incoming[edge["to"]] += 1
        outgoing[edge["from"]] += 1
    for name, screen in index["screens"].items():
        aliases = " ".join(screen.get("aliases", []))
        print("{}  anchors={} in={} out={}{}".format(name, len(screen["anchors"]), incoming[name], outgoing[name], "  [" + aliases + "]" if aliases else ""))
    print("index: {}".format(index_path))


def index_remove_edge(argv):
    if len(argv) != 2:
        raise SystemExit("index remove-edge <from> <to>")
    index = load_index()
    source, target = (resolve_name(index, argv[0]), resolve_name(index, argv[1]))
    remaining = [e for e in index["edges"] if not (e["from"] == source and e["to"] == target)]
    if len(remaining) == len(index["edges"]):
        raise SystemExit("辺 {} → {} はありません".format(source, target))
    index["edges"] = remaining
    save_index(index)
    print("辺を削除: {} → {}".format(source, target))


def index_tool(argv):
    if not argv:
        raise SystemExit("index <candidates|add-screen|verify-screen|add-edge|remove-edge|add-dismiss|check|list> ...")
    command, *rest = argv
    if command == "candidates":
        index_candidates()
    elif command == "add-screen":
        index_add_screen(rest)
    elif command == "verify-screen":
        index_verify_screen(rest)
    elif command == "add-edge":
        index_add_edge(rest)
    elif command == "remove-edge":
        index_remove_edge(rest)
    elif command == "add-dismiss":
        index_add_dismiss(rest)
    elif command == "check":
        index_check()
    elif command == "list":
        index_list()
    else:
        raise SystemExit("不明な index サブコマンドです: {}".format(command))


if mode == "index":
    index_tool(args)
elif mode == "screen":
    if args:
        raise SystemExit("screen は引数を受け取りません")
    name, candidates = identify(load_index(), dump())
    if name is None:
        raise SystemExit(describe(name, candidates))
    print(name)
elif mode == "wait-for":
    if len(args) not in (1, 2):
        raise SystemExit("wait-for には substring [秒数] が必要です")
    wait_for_text(args[0], parse_timeout(args[1]) if len(args) == 2 else DEFAULT_TIMEOUT)
elif mode == "wait-for-screen":
    if len(args) not in (1, 2):
        raise SystemExit("wait-for-screen には画面名 [秒数] が必要です")
    index = load_index()
    wait_for_screen(index, resolve_name(index, args[0]), parse_timeout(args[1]) if len(args) == 2 else DEFAULT_TIMEOUT)
elif mode == "goto":
    # 末尾が数値なら辺ごとのタイムアウト。それ以外は目的地（複数可、順に巡る）
    timeout = DEFAULT_TIMEOUT
    if len(args) >= 2 and re.fullmatch(r"\d+(\.\d+)?", args[-1]):
        timeout = parse_timeout(args[-1])
        args = args[:-1]
    if not args:
        raise SystemExit("goto には画面名（複数可） [辺ごとの秒数] が必要です")
    goto(load_index(), args, timeout, State())
elif mode == "flow":
    fail_fast = "--fail-fast" in args
    sources = [a for a in args if a != "--fail-fast"]
    if not sources:
        raise SystemExit("flow <file> | flow - | flow \"行\" \"行\"... [--fail-fast]")
    flow(sources, fail_fast, DEFAULT_TIMEOUT)
PY
}

main() {
  local option
  require_commands

  while getopts ":s:h" option; do
    case "$option" in
      s)
        DEVICE_SERIAL=$OPTARG
        SERIAL_FROM_OPTION=true
        ;;
      h)
        usage
        return
        ;;
      :)
        fail "-$OPTARG には値が必要です"
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
  shift $((OPTIND - 1))

  local subcommand=${1:-help}
  if [ "$subcommand" = devices ]; then
    [ "$#" -eq 1 ] || fail "devices は引数を受け取りません"
    list_devices
    return
  fi
  if [ "$subcommand" = help ]; then
    usage
    return
  fi
  select_device
  shift

  case "$subcommand" in
    shot)
      [ "$#" -le 1 ] || fail "shot は保存先を 1 つだけ受け取ります"
      local output
      if [ "$#" -eq 1 ]; then
        output=$1
      else
        local directory="${TMPDIR:-/tmp}/android-drive"
        mkdir -p "$directory"
        output="$directory/shot-$(date +%Y%m%d-%H%M%S).png"
      fi
      [ ! -e "$output" ] || fail "保存先が既に存在します: $output"
      adb -s "$DEVICE_SERIAL" exec-out screencap -p > "$output"
      printf '%s\n' "$output"
      ;;
    ui)
      [ "$#" -le 1 ] || fail "ui の引数が不正です"
      local json_output
      make_temp_file .json
      json_output=$TEMP_FILE
      dump_ui_json "$json_output"
      if [ "${1:-}" = --json ]; then
        cat "$json_output"
      elif [ "$#" -eq 0 ]; then
        format_nodes "$json_output"
      else
        fail "ui の引数が不正です: $1"
      fi
      ;;
    find)
      [ "$#" -eq 1 ] || fail "find には substring が必要です"
      local find_json matches_json
      make_temp_file .json
      find_json=$TEMP_FILE
      make_temp_file .json
      matches_json=$TEMP_FILE
      dump_ui_json "$find_json"
      find_nodes_json "$find_json" "$1" > "$matches_json"
      format_nodes "$matches_json"
      ;;
    tap)
      [ "$#" -eq 2 ] || fail "tap には x y が必要です"
      [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || fail "tap の座標は 0 以上の整数で指定してください"
      adb_shell input tap "$1" "$2"
      ;;
    tap-text)
      [ "$#" -eq 1 ] || fail "tap-text には substring が必要です"
      tap_first_match tap-text "$1" contains
      ;;
    tap-desc)
      [ "$#" -eq 1 ] || fail "tap-desc には content-desc が必要です"
      tap_first_match tap-desc "$1" desc
      ;;
    tap-id)
      [ "$#" -eq 1 ] || fail "tap-id には resource-id が必要です"
      tap_first_match tap-id "$1" id
      ;;
    flow)
      # python 本体を heredoc で stdin から渡しているので、`-`（標準入力）は bash 側で一時ファイルに落とす
      local -a flow_args=()
      local flow_arg
      for flow_arg in "$@"; do
        if [ "$flow_arg" = - ]; then
          make_temp_file .flow
          cat > "$TEMP_FILE"
          flow_args+=("$TEMP_FILE")
        else
          flow_args+=("$flow_arg")
        fi
      done
      run_navigator flow "${flow_args[@]}"
      ;;
    screen|wait-for|wait-for-screen|goto|index)
      run_navigator "$subcommand" "$@"
      ;;
    long)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail "long には x y [ms] が必要です"
      local duration=${3:-800}
      [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ && "$duration" =~ ^[0-9]+$ ]] || fail "long の座標と ms は 0 以上の整数で指定してください"
      adb_shell input swipe "$1" "$2" "$1" "$2" "$duration"
      ;;
    swipe)
      [ "$#" -eq 1 ] || fail "swipe には方向が必要です"
      local width height x1 y1 x2 y2
      read -r width height <<EOF
$(screen_size)
EOF
      case "$1" in
        up) x1=$((width / 2)); y1=$((height * 3 / 4)); x2=$x1; y2=$((height / 4)) ;;
        down) x1=$((width / 2)); y1=$((height / 4)); x2=$x1; y2=$((height * 3 / 4)) ;;
        left) x1=$((width * 3 / 4)); y1=$((height / 2)); x2=$((width / 4)); y2=$y1 ;;
        right) x1=$((width / 4)); y1=$((height / 2)); x2=$((width * 3 / 4)); y2=$y1 ;;
        *) fail "swipe の方向は up/down/left/right です" ;;
      esac
      adb_shell input swipe "$x1" "$y1" "$x2" "$y2" 300
      ;;
    text)
      [ "$#" -eq 1 ] || fail "text には文字列が必要です"
      # `input text` は KeyCharacterMap で打てる文字しか受け付けず、非 ASCII は system_server 側で NPE になる
      if [ "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\177' | wc -c)" -gt 0 ]; then
        fail "text は ASCII 文字のみ入力できます（input text の制約）: $1"
      fi
      local input_text=${1// /%s}
      suspend_ime
      adb_shell input text "$input_text"
      restore_ime
      ;;
    key)
      [ "$#" -eq 1 ] || fail "key にはキーコードが必要です"
      adb_shell input keyevent "$1"
      ;;
    start)
      [ "$#" -eq 1 ] || fail "start には package[/activity] が必要です"
      local component=$1 package
      if [[ "$component" != */* ]]; then
        package=$component
        # --brief は 1 行目に priority 等のメタ情報、2 行目に component を出すので '/' を含む行だけ拾う
        component=$(adb_shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$package" | tr -d '\r' | python3 -c 'import sys; print(next((line.strip() for line in sys.stdin if "/" in line), ""))')
        [ -n "$component" ] || fail "LAUNCHER activity を解決できません: $package"
      fi
      adb_shell am start -n "$component"
      ;;
    stop)
      [ "$#" -eq 1 ] || fail "stop には package が必要です"
      adb_shell am force-stop "$1"
      ;;
    current)
      [ "$#" -eq 0 ] || fail "current は引数を受け取りません"
      show_current
      ;;
    layout)
      show_layout "$@"
      ;;
    log)
      if [ "${1:-}" = clear ]; then
        [ "$#" -eq 1 ] || fail "log clear は引数を受け取りません"
        adb -s "$DEVICE_SERIAL" logcat -c
      else
        show_log "$@"
      fi
      ;;
    install-split)
      [ "$#" -eq 3 ] || fail "install-split には pkg bundle.apks split-name が必要です"
      install_split "$1" "$2" "$3"
      ;;
    wait)
      [ "$#" -eq 1 ] || fail "wait には秒数が必要です"
      [[ "$1" =~ ^([0-9]+|[0-9]+\.[0-9]+)$ ]] || fail "wait は 0 以上の秒数で指定してください"
      sleep "$1"
      ;;
    *)
      usage >&2
      fail "不明なサブコマンドです: $subcommand"
      ;;
  esac
}

main "$@"
