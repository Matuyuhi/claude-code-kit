#!/usr/bin/env python3
"""~/.claude/projects/*/<uuid>.jsonl（セッション transcript）を
フォルダ横断で一覧し、選んだセッションを claude --resume で再開する。

  list-transcripts.py [絞り込み] [-n 件数] [-l] [--plain] [--no-color]

TTY なら対話ピッカー、パイプ等なら整形テキストを出力する。
"""
import curses
import datetime
import glob
import json
import locale
import os
import re
import sys
import unicodedata

HOME = os.path.expanduser('~')
PROJECTS_DIR = os.environ.get('PROJECTS_DIR', os.path.join(HOME, '.claude', 'projects'))
HOME_SLUG = HOME.replace('/', '-').replace('.', '-')
UUID_RE = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$')
TAG_RE = re.compile(r'<[^>]*>')
ANSI_RE = re.compile(r'\033\[[0-9;]*m')
# セッションの中身を表さないコマンド。これしか無い時だけ表示する
META_CMDS = {'/clear', '/model', '/context', '/compact', '/config', '/cost',
             '/status', '/resume', '/exit', '/help', '/login', '/logout',
             '/reload-skills', '/doctor', '/theme', '/effort', '/fast', '/vim',
             '/mcp', '/agents', '/permissions', '/hooks', '/export', '/bug',
             '/terminal-setup', '/output-style', '/statusline', '/ide', '/upgrade'}


# ---------------------------------------------------------------- 表示幅ユーティリティ

def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in s)


def clip(s, w):
    """表示幅 w に収まるよう末尾を … で切る（全角を 2 幅として計算）"""
    if w <= 0:
        return ''
    if width(s) <= w:
        return s
    out, acc = '', 0
    for c in s:
        cw = 2 if unicodedata.east_asian_width(c) in 'WF' else 1
        if acc + cw > w - 1:
            break
        out += c
        acc += cw
    return out + '…'


def clip_left(s, w):
    """パス表示用。repo 名を残したいので先頭側を … で切る"""
    if w <= 0:
        return ''
    if width(s) <= w:
        return s
    out, acc = '', 0
    for c in reversed(s):
        cw = 2 if unicodedata.east_asian_width(c) in 'WF' else 1
        if acc + cw > w - 1:
            break
        out = c + out
        acc += cw
    return '…' + out


def pad(s, w):
    return s + ' ' * max(0, w - width(s))


# ---------------------------------------------------------------- transcript の読み取り

def summarize(path, max_lines=400):
    """(title, 冒頭のユーザー依頼, cwd) を返す。
    title は Claude Code が最初の応答後に書く ai-title レコード（無ければ None）。
    /clear 等のメタコマンドや、`!` 実行時に注入される isMeta 行は読み飛ばす"""
    cwd, fallback, title, text = None, None, None, None
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for n, line in enumerate(f):
                if n >= max_lines or (title and text):
                    break
                if '"type":"ai-title"' in line:
                    try:
                        title = json.loads(line).get('aiTitle') or title
                    except ValueError:
                        pass
                    continue
                if text or '"type":"user"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if obj.get('type') != 'user' or obj.get('isSidechain'):
                    continue
                cwd = cwd or obj.get('cwd')
                if obj.get('isMeta'):
                    continue
                content = (obj.get('message') or {}).get('content', '')
                if isinstance(content, list):
                    content = ' '.join(c.get('text', '') for c in content
                                       if isinstance(c, dict) and c.get('type') == 'text')
                content = ANSI_RE.sub('', str(content))
                # /model 等の実行結果。ユーザーの依頼ではないので読み飛ばす
                if '<local-command-stdout>' in content or '<local-command-caveat>' in content:
                    continue
                # スラッシュコマンドは <command-name> + <command-args> に分解されている
                name = re.search(r'<command-name>(.*?)</command-name>', content, re.S)
                if name:
                    cmd = name.group(1).strip()
                    if cmd in META_CMDS:
                        fallback = fallback or f'({cmd})'
                        continue
                    args = re.search(r'<command-args>(.*?)</command-args>', content, re.S)
                    text = ' '.join(f'{cmd} {args.group(1) if args else ""}'.split())
                else:
                    text = ' '.join(TAG_RE.sub(' ', content).split())
                if not text or text.startswith('Caveat:'):
                    text = None
    except OSError:
        pass
    return title, text or fallback or '(冒頭メッセージなし)', cwd


def relpath_of(cwd, slug):
    if cwd:
        rel = os.path.relpath(cwd, HOME) if cwd.startswith(HOME) else cwd
        return '/'.join(p for p in rel.split(os.sep) if p not in ('.', '')) or '~'
    return slug[len(HOME_SLUG):].lstrip('-') if slug.startswith(HOME_SLUG) else slug


def shorten_labels(paths):
    """repo 名だけで表示する。同名 repo の別クローンがある時だけ親を足して区別する"""
    paths = set(paths)
    labels = {}
    for depth in (1, 2, 3, 4):
        labels = {p: '/'.join(p.split('/')[-depth:]) for p in paths}
        counts = {}
        for v in labels.values():
            counts[v] = counts.get(v, 0) + 1
        if all(counts[labels[p]] == 1 or labels[p] == p for p in paths):
            break
    return labels


class Session:
    def __init__(self, path):
        self.path = path
        self.sid = os.path.basename(path)[:-6]
        self.mtime = os.path.getmtime(path)
        self.title, self.text, self.cwd = summarize(path)
        self.rel = relpath_of(self.cwd, os.path.basename(os.path.dirname(path)))
        self.label = self.rel

    @property
    def when(self):
        return datetime.datetime.fromtimestamp(self.mtime)

    @property
    def headline(self):
        """一覧に出す 1 行。title が無いセッションは冒頭の依頼で代用する"""
        return self.title or self.text

    def matches(self, needle):
        return needle in f'{self.rel} {self.title or ""} {self.text} {self.path}'.lower()


def collect():
    rows = [Session(p) for p in glob.glob(os.path.join(PROJECTS_DIR, '*', '*.jsonl'))
            if UUID_RE.match(os.path.basename(p))]
    rows.sort(key=lambda s: s.mtime, reverse=True)
    return rows


def apply_labels(rows):
    labels = shorten_labels(s.rel for s in rows)
    for s in rows:
        s.label = labels[s.rel]


def daylabel(d, today):
    delta = (today - d).days
    wd = '月火水木金土日'[d.weekday()]
    suffix = {0: '今日', 1: '昨日'}.get(delta, f'{delta}日前')
    return f'{d:%Y-%m-%d} ({wd}) {suffix}'


# ---------------------------------------------------------------- プレーン出力

def render_plain(rows, total, needle, limit, long_mode, color, cols):
    if color:
        DIM, BOLD, CYAN, YEL, OFF = '\033[2m', '\033[1m', '\033[36m', '\033[33m', '\033[0m'
    else:
        DIM = BOLD = CYAN = YEL = OFF = ''

    id_w = 36 if long_mode else 8
    proj_w = max(12, min(34, max((width(s.label) for s in rows), default=12)))

    header = f'{BOLD}Claude Sessions{OFF}  {total} 件'
    if needle:
        header += f' / 絞り込み "{needle}"'
    if limit and total > len(rows):
        header += f'（先頭 {len(rows)} 件）'
    print(header)

    today = datetime.date.today()
    cur = None
    for s in rows:
        ts = s.when
        if ts.date() != cur:
            cur = ts.date()
            label = daylabel(cur, today)
            print(f'\n{BOLD}{label}{OFF} {DIM}' + '─' * max(0, cols - width(label) - 2) + OFF)
        print(f'  {YEL}{ts:%H:%M}{OFF}  {CYAN}{pad(clip_left(s.label, proj_w), proj_w)}{OFF}'
              f'  {DIM}{s.sid[:id_w]}{OFF}')
        print(f'        {clip(s.headline, cols - 9)}')
        if long_mode:
            if s.title and s.text != s.title:
                print(f'        {DIM}{clip(s.text, cols - 9)}{OFF}')
            print(f'        {DIM}{s.path}{OFF}')

    hint = '再開: claude --resume <session id>'
    if not long_mode:
        hint += '（フル id / パスは -l）'
    print(f'\n{DIM}{hint}{OFF}')


# ---------------------------------------------------------------- 対話ピッカー

HELP = '↑↓ 選択  Enter 再開  文字入力 絞り込み  Ctrl-U クリア  Esc/q 終了'


def build_items(rows, needle, today):
    """日付見出し（選択不可）とセッション行を混ぜた表示リストを作る"""
    items, cur = [], None
    for s in rows:
        if needle and not s.matches(needle):
            continue
        d = s.when.date()
        if d != cur:
            cur = d
            items.append(('head', daylabel(d, today)))
        items.append(('row', s))
    return items


def draw(stdscr, items, sel, top, needle, total, shown):
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    detail_h = 3
    list_h = max(1, h - 2 - detail_h)

    title = f' Claude Sessions  {shown}/{total} 件 '
    stdscr.addstr(0, 0, pad(clip(title, w), w)[:w], curses.A_REVERSE | curses.A_BOLD)
    q = f' 絞り込み: {needle}' if needle else f' {HELP}'
    stdscr.addstr(1, 0, clip(q, w - 1), curses.A_BOLD if needle else curses.A_DIM)

    proj_w = max(12, min(30, max((width(s.label) for k, s in items if k == 'row'), default=12)))
    for i in range(list_h):
        idx = top + i
        if idx >= len(items):
            break
        kind, val = items[idx]
        y = i + 2
        if kind == 'head':
            rule = '─' * max(0, w - width(val) - 3)
            stdscr.addstr(y, 1, clip(f'{val} {rule}', w - 2), curses.color_pair(1) | curses.A_BOLD)
            continue
        cur = idx == sel
        mark = '▸ ' if cur else '  '
        left = f'{mark}{val.when:%m/%d %H:%M}  {pad(clip_left(val.label, proj_w), proj_w)}  '
        line = pad(clip(left + val.headline, w - 1), w - 1)
        attr = curses.A_REVERSE if cur else curses.A_NORMAL
        stdscr.addstr(y, 0, line, attr)

    y = h - detail_h
    stdscr.addstr(y, 0, '─' * max(0, w - 1), curses.A_DIM)
    if 0 <= sel < len(items) and items[sel][0] == 'row':
        s = items[sel][1]
        stdscr.addstr(y + 1, 1, clip(s.text, w - 2), curses.A_BOLD)
        stdscr.addstr(y + 2, 1, clip(f'{s.cwd or "?"}  ·  {s.sid}', w - 2), curses.A_DIM)
    stdscr.noutrefresh()
    curses.doupdate()


def picker(stdscr, rows, needle):
    curses.curs_set(0)
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    today = datetime.date.today()
    total = len(rows)
    chosen = None

    items = build_items(rows, needle, today)
    sel = next((i for i, it in enumerate(items) if it[0] == 'row'), 0)
    top = 0

    while True:
        h, _ = stdscr.getmaxyx()
        list_h = max(1, h - 5)
        top = min(top, max(0, len(items) - list_h))
        if sel < top + 1:
            top = max(0, sel - 1)
        if sel >= top + list_h:
            top = sel - list_h + 1
        shown = sum(1 for k, _ in items if k == 'row')
        draw(stdscr, items, sel, top, needle, total, shown)

        try:
            ch = stdscr.get_wch()
        except curses.error:
            continue
        except KeyboardInterrupt:
            break

        def move(step):
            nonlocal sel
            i = sel + step
            while 0 <= i < len(items):
                if items[i][0] == 'row':
                    sel = i
                    return
                i += step

        before = needle
        if ch in (curses.KEY_DOWN, '\x0e'):        # ↓ / Ctrl-N
            move(1)
        elif ch in (curses.KEY_UP, '\x10'):        # ↑ / Ctrl-P
            move(-1)
        elif ch == curses.KEY_NPAGE:
            for _ in range(10):
                move(1)
        elif ch == curses.KEY_PPAGE:
            for _ in range(10):
                move(-1)
        elif ch in ('\n', '\r', curses.KEY_ENTER):
            if 0 <= sel < len(items) and items[sel][0] == 'row':
                chosen = items[sel][1]
            break
        elif ch == '\x15':                          # Ctrl-U
            needle = ''
        elif ch in ('\x1b',) or (ch == 'q' and not needle):
            break
        elif ch in (curses.KEY_BACKSPACE, '\x7f', '\b'):
            needle = needle[:-1]
        elif isinstance(ch, str) and ch.isprintable():
            needle += ch.lower()
        else:
            continue

        if needle != before:
            items = build_items(rows, needle, today)
            sel = next((i for i, it in enumerate(items) if it[0] == 'row'), 0)
            top = 0

    return chosen


def resume(s):
    """セッションが動いていた作業ディレクトリで claude --resume する"""
    cwd = s.cwd if s.cwd and os.path.isdir(s.cwd) else HOME
    print(f'\033[2m{cwd} で再開: claude --resume {s.sid}\033[0m')
    os.chdir(cwd)
    os.execvp('claude', ['claude', '--resume', s.sid])


# ---------------------------------------------------------------- entry point

def main():
    locale.setlocale(locale.LC_ALL, '')
    argv, needle, limit = sys.argv[1:], '', None
    long_mode = plain = no_color = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ('-n', '--limit') and i + 1 < len(argv):
            i += 1
            try:
                limit = int(argv[i])
            except ValueError:
                sys.exit(f'-n には数値を指定してください: {argv[i]}')
        elif a in ('-l', '--long'):
            long_mode = True
        elif a in ('-p', '--plain'):
            plain = True
        elif a == '--no-color':
            no_color = True
        elif a in ('-h', '--help'):
            print(__doc__)
            return
        elif not a.startswith('-'):
            needle = a.lower()
        else:
            sys.exit(f'未知のオプション: {a}')
        i += 1

    rows = collect()
    total = len(rows)
    if not rows:
        print('セッションが見つかりません', file=sys.stderr)
        return

    interactive = sys.stdout.isatty() and sys.stdin.isatty() and not plain and not long_mode
    if interactive:
        apply_labels(rows)
        chosen = curses.wrapper(picker, rows, needle)
        if chosen:
            resume(chosen)
        return

    if needle:
        rows = [s for s in rows if s.matches(needle)]
        total = len(rows)
    if limit:
        rows = rows[:limit]
    if not rows:
        print(f'絞り込み "{needle}" に一致するセッションはありません')
        return
    apply_labels(rows)
    cols = int(os.environ.get('COLUMNS') or 0) or (os.get_terminal_size().columns
                                                   if sys.stdout.isatty() else 100)
    render_plain(rows, total, needle, limit, long_mode,
                 sys.stdout.isatty() and not no_color, cols)


if __name__ == '__main__':
    main()
