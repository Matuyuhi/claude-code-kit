#!/bin/bash
# セッション一覧・再開ピッカーの入口。実体は list-transcripts.py。
# TTY なら対話ピッカー、パイプ等なら整形テキストを出力する。
exec python3 "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/list-transcripts.py" "$@"
