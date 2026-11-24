#!/bin/bash
# ~/.claude/knowledge/ の INDEX.md・INDEX-short.md・sessions/INDEX.md を各メモリの frontmatter から再生成する。
# 使い方: rebuild-index.sh （引数なし。KNOWLEDGE_DIR 環境変数で対象を上書き可）
set -euo pipefail

KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-$HOME/.claude/knowledge}"

python3 - "$KNOWLEDGE_DIR" <<'PY'
import os
import re
import sys

root = os.path.abspath(sys.argv[1])

FRONTMATTER_RE = re.compile(r'^---\s*\n(.*?)\n---\s*(?:\n|$)', re.S)
KV_RE = re.compile(r'^\s*([A-Za-z_][\w-]*):\s*(.*)$')


def parse_frontmatter(path):
    """frontmatter を素朴に key: value 抽出する（ネストは平坦化、同名キーは最初の値優先）"""
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            text = f.read()
    except OSError:
        return {}
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}
    meta = {}
    for line in m.group(1).splitlines():
        kv = KV_RE.match(line)
        if not kv:
            continue
        key, val = kv.group(1), kv.group(2).strip().strip('"\'')
        if val and key not in meta:
            meta[key] = val
    return meta


entries = {}   # scope（root からの相対ディレクトリ） -> [(name, relpath, desc)]
sessions = []  # (date, repo, kind, name, sessions/ からの相対パス, desc)

for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = sorted(d for d in dirnames if d not in ('bin', '.git'))
    for fn in sorted(filenames):
        if not fn.endswith('.md') or fn in ('INDEX.md', 'INDEX-short.md', 'README.md'):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, root)
        meta = parse_frontmatter(path)
        name = meta.get('name', os.path.splitext(fn)[0])
        desc = meta.get('description', '')
        if rel.split(os.sep)[0] == 'sessions':
            sessions.append((meta.get('date', fn[:10]), meta.get('repo', ''),
                             meta.get('kind', ''), name,
                             os.path.relpath(path, os.path.join(root, 'sessions')), desc))
        else:
            scope = os.path.dirname(rel) or '(root)'
            entries.setdefault(scope, []).append((name, rel, desc))

lines = [
    '# Knowledge Index',
    '<!-- bin/rebuild-index.sh により自動生成。手で編集しない -->',
    '',
    'ここは目次。内容を使う前に、必ず該当ファイル（~/.claude/knowledge/ 配下）を Read すること。',
    '保存: /remember（事実）・/journal（セッション記録） / 検索: /recall（事実）・/sessions（過去セッション）',
    '',
]
for scope in sorted(entries):
    lines.append(f'## {scope}')
    for name, rel, desc in entries[scope]:
        lines.append(f'- [{name}]({rel})' + (f' — {desc}' if desc else ''))
    lines.append('')
lines += [
    '## sessions',
    f'- セッションジャーナル {len(sessions)} 件 → [sessions/INDEX.md](sessions/INDEX.md) を Read（探索は /sessions）',
    '',
]
with open(os.path.join(root, 'INDEX.md'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))

# CLAUDE.md が常時 import する縮約版。global は全セッションで効く規則なので説明付き、他は名前だけ
short = [
    '# Knowledge Index（縮約）',
    '<!-- bin/rebuild-index.sh により自動生成。手で編集しない -->',
    '',
    'global 以外は名前だけ。説明付きの全目次は ~/.claude/knowledge/INDEX.md（/recall・/start が読む）。作業対象の repo・技術に該当しそうな名前があれば INDEX.md か本文を Read する。',
    '',
]
for scope in sorted(entries):
    if scope == 'global':
        short.append('## global')
        short += [f'- [{name}]({rel})' + (f' — {desc}' if desc else '') for name, rel, desc in entries[scope]]
        short.append('')
for scope in sorted(entries):
    if scope != 'global':
        short.append(f'- {scope}/: ' + ' / '.join(name for name, _, _ in entries[scope]))
short.append('')
with open(os.path.join(root, 'INDEX-short.md'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(short))

slines = [
    '# Sessions Index',
    '<!-- bin/rebuild-index.sh により自動生成。手で編集しない -->',
    '',
    '新しい順。各ファイルは ~/.claude/knowledge/sessions/ 配下。',
    '',
]
for date, repo, kind, name, rel, desc in sorted(sessions, reverse=True):
    tags = ''.join(f'[{t}] ' for t in (repo, kind) if t)
    slines.append(f'- {date} {tags}[{name}]({rel})' + (f' — {desc}' if desc else ''))
slines.append('')
os.makedirs(os.path.join(root, 'sessions'), exist_ok=True)
with open(os.path.join(root, 'sessions', 'INDEX.md'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(slines))

total = sum(len(v) for v in entries.values())
print(f'INDEX.md: {total} 件 / sessions/INDEX.md: {len(sessions)} 件 を再生成しました')
PY
