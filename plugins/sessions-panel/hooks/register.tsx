import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Saved, Session, SessionStatus } from '../types'

const sessions = atom({ plugin: 'sessions-panel', key: 'sessions' } as const, [] as Session[], {
  shape: 'sessions-1',
})
// The last action's failure, shown under the list until the next action.
const note = atom({ plugin: 'sessions-panel', key: 'note' } as const, '')
// What was open when this session started, before its own polls overwrite the layout.
const restorable = atom({ plugin: 'sessions-panel', key: 'restorable' } as const, [] as Saved[], {
  shape: 'saved-1',
})

const PANE = 'sessions'
// What is open now, rewritten by every running session's poll.
const LAYOUT_KEY = 'layout'
// What was open last time and is not open now; offered until restored or opened by hand.
const RESTORE_KEY = 'restore'
const POLL_MS = 3_000
// Titles come from the transcript, which is large: a missing one is retried
// every 30 seconds, a known one (which rarely changes) every 5 minutes.
const TITLE_MISSING_MS = 30_000
const TITLE_KNOWN_MS = 5 * 60_000
// Tabs opened together start their claudes and MCP servers at once, and an app
// several of them launch (Xcode Service, for xcrun mcpbridge) answers all but
// the first with a "not responding" dialog; restore opens one tab per gap.
const RESTORE_GAP_MS = 5_000
// The id is typed into a shell by restore; only a session id's own shape is let through.
const SESSION_ID =/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

const ICON: Record<SessionStatus, string> = {
  busy: '⏳',
  waiting: '🔔',
  idle: '✅',
  other: '·',
}

// The terminal is an implementation detail behind these two scripts, so another
// terminal can be supported by adding its own pair here.
//
// Selects the tab whose foreground process is the session's claude.
const GHOSTTY_SELECT = `
on run argv
  set target to (item 1 of argv) as integer
  tell application "Ghostty"
    repeat with w in windows
      repeat with t in tabs of w
        if (pid of focused terminal of t) is target then
          select tab t
          activate window w
          activate
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return "notfound"
end run
`
// Types the command line into a new tab's login shell, so PATH and aliases are
// those of a tab opened by hand. Ghostty 1.4 refuses its "new tab" command
// (-1708), so the tab comes from the new_tab action run on this session's own tab.
// "input text" arrives as a paste whose newline the shell ignores; Enter is sent as a key.
const GHOSTTY_OPEN = `
on run argv
  set target to (item 1 of argv) as integer
  tell application "Ghostty"
    repeat with w in windows
      repeat with t in tabs of w
        if (pid of focused terminal of t) is target then
          perform action "new_tab" on focused terminal of t
          delay 0.5
          set term to focused terminal of selected tab of w
          input text (item 2 of argv) to term
          send key "enter" to term
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return "notfound"
end run
`

let home = ''
let ownId = ''
let ownCwd = ''
// A second press while the tabs are still being opened would open them twice.
let isRestoring = false
const titles = new Map<string, { title: string; at: number }>()

// ~/.claude/projects/<slug>/<id>.jsonl, the slug being the cwd with every
// character but letters and digits as - (my_projects → my-projects).
function transcriptOf(cwd: string, sessionId: string) {
  return `${home}/.claude/projects/${cwd.replace(/[^A-Za-z0-9]/g, '-')}/${sessionId}.jsonl`
}

function baseName(path: string) {
  return path.split('/').filter(Boolean).at(-1) ?? path
}

// Single quotes for the login shell the command is typed into.
function quoted(text: string) {
  return `'${text.replace(/'/g, `'\\''`)}'`
}

// The session list ships in the memory plugin, whose cache path carries its version.
function listTranscripts(home: string) {
  const glob = `${quoted(`${home}/.claude/plugins/cache`)}/*/memory/*/scripts/list-transcripts.py`

  return `python3 "$(ls -d ${glob} 2>/dev/null | tail -1)"`
}

async function titleOf($: EngineInterface, s: { cwd: string; sessionId: string }, now: number) {
  const cached = titles.get(s.sessionId)
  const ttl = cached?.title ? TITLE_KNOWN_MS : TITLE_MISSING_MS
  if (cached !== undefined && now - cached.at < ttl) return cached.title
  let title = cached?.title ?? ''
  try {
    const { stdout } = await $.process.run(
      ['grep', '-F', '"type":"ai-title"', transcriptOf(s.cwd, s.sessionId)],
      { timeoutMs: 5_000 },
    )
    const last = stdout.trim().split('\n').at(-1) ?? ''
    if (last !== '') title = (JSON.parse(last) as { aiTitle?: string }).aiTitle ?? title
  } catch {
    // No transcript yet (a session with no reply) or one line cut mid-write.
  }
  titles.set(s.sessionId, { title, at: now })

  return title
}

async function alivePids($: EngineInterface, pids: number[]) {
  if (pids.length === 0) return new Set<number>()
  const { stdout } = await $.process.run(['ps', '-o', 'pid=', '-p', pids.join(',')])

  return new Set(stdout.split('\n').map(line => Number(line.trim())).filter(n => n > 0))
}

// The running interactive sessions, from the status file Claude Code keeps per process.
async function scan($: EngineInterface): Promise<Session[]> {
  const dir = `${home}/.claude/sessions`
  const now = await $.clock.now()
  const found: (Omit<Session, 'title'> & { renamed?: string })[] = []
  for (const entry of await $.fs.list(dir)) {
    // The same folder holds per-session .key files; only the .json status is read.
    if (entry.kind !== 'file' || !/^\d+\.json$/.test(entry.name)) continue
    try {
      const raw = JSON.parse(await $.fs.read(`${dir}/${entry.name}`)) as {
        pid?: number
        sessionId?: string
        cwd?: string
        status?: string
        kind?: string
        name?: string
        nameSource?: string
      }
      if (raw.kind !== 'interactive' || raw.pid === undefined || raw.sessionId === undefined) continue
      const status: SessionStatus =
        raw.status === 'busy' || raw.status === 'idle' || raw.status === 'waiting' ? raw.status : 'other'
      // A derived name is only the folder plus a suffix; the transcript's title says more.
      const renamed = raw.nameSource === 'user' ? raw.name : undefined
      found.push({ pid: raw.pid, sessionId: raw.sessionId, cwd: raw.cwd ?? '', status, renamed })
    } catch {
      // A file caught mid-write; the next poll reads it whole.
    }
  }
  // A killed claude can leave its file behind.
  const alive = await alivePids($, found.map(s => s.pid))
  const list: Session[] = []
  for (const { renamed, ...s } of found.filter(s => alive.has(s.pid))) {
    list.push({ ...s, title: renamed ?? (await titleOf($, s, now)) })
  }

  return list.sort((a, b) => a.pid - b.pid)
}

function savedList(value: unknown): Saved[] {
  return Array.isArray(value) ? (value as Saved[]).filter(s => SESSION_ID.test(s?.sessionId ?? '')) : []
}

async function poll($: EngineInterface) {
  try {
    const list = await scan($)
    if (JSON.stringify(list) !== JSON.stringify(await read($, sessions))) {
      await update($, sessions, () => list)
    }
    // Every running session writes the same list; quitting the terminal leaves the last one whole.
    // An empty list is never written, so a moment with nothing found cannot erase it.
    const layout: Saved[] = list.map(s => ({ sessionId: s.sessionId, cwd: s.cwd, title: s.title }))
    if (layout.length > 0 && JSON.stringify(layout) !== JSON.stringify(await $.store.get(LAYOUT_KEY))) {
      await $.store.set(LAYOUT_KEY, layout)
    }
    // Opened by hand or by another session's restore: drop those from the offer.
    const open = new Set(list.map(s => s.sessionId))
    const offer = savedList(await $.store.get(RESTORE_KEY))
    const left = offer.filter(s => !open.has(s.sessionId))
    if (left.length !== offer.length) {
      if (left.length === 0) await $.store.delete(RESTORE_KEY)
      else await $.store.set(RESTORE_KEY, left)
    }
    if (JSON.stringify(left) !== JSON.stringify(await read($, restorable))) {
      await update($, restorable, () => left)
    }
  } catch {
    // Retried by the next poll.
  }
}

// On start, before this session's polls rewrite the layout: whatever the last
// layout held that is not running now was closed together (the terminal quit),
// so it becomes the restore offer. Sessions closed one by one already left the
// layout through the others' polls, and are not offered.
async function captureRestore($: EngineInterface) {
  const last = savedList(await $.store.get(LAYOUT_KEY))
  if (last.length === 0) return
  const open = new Set((await scan($)).map(s => s.sessionId))
  const closed = last.filter(s => !open.has(s.sessionId))
  if (closed.length > 0) await $.store.set(RESTORE_KEY, closed)
}

async function say($: EngineInterface, text: string) {
  await update($, note, () => text)
}

async function osascript($: EngineInterface, script: string, args: string[]) {
  const { stdout, stderr, exitCode } = await $.process.run(['osascript', '-', ...args], {
    stdin: script,
    timeoutMs: 10_000,
  })

  return exitCode === 0 ? stdout.trim() : `error: ${stderr.trim().split('\n')[0] ?? ''}`
}

async function jump($: EngineInterface, s: Session) {
  const result = await osascript($, GHOSTTY_SELECT, [String(s.pid)])
  await say(
    $,
    result === 'ok' ? ''
    : result === 'notfound' ? `${s.title || baseName(s.cwd)} のタブが Ghostty に見つかりません`
    : `切り替えられませんでした: ${result}`,
  )
}

async function openTab($: EngineInterface, cwd: string, command: string) {
  const me = (await read($, sessions)).find(s => s.sessionId === ownId)
  if (me === undefined) {
    await say($, 'このセッションの状態ファイルがまだ見つかりません。数秒おいてもう一度試してください')

    return false
  }
  const result = await osascript($, GHOSTTY_OPEN, [String(me.pid), `cd ${quoted(cwd)} && ${command}`])
  await say(
    $,
    result === 'ok' ? ''
    : result === 'notfound' ? 'このセッションのタブが Ghostty に見つかりません（tmux の中などでは開けません）'
    : `タブを開けませんでした: ${result}`,
  )

  return result === 'ok'
}

async function restore($: EngineInterface) {
  if (isRestoring) return
  const open = new Set((await read($, sessions)).map(s => s.sessionId))
  const queue = (await read($, restorable)).filter(s => !open.has(s.sessionId) && SESSION_ID.test(s.sessionId))
  isRestoring = true
  // Each tab is scheduled on the clock rather than awaited in a loop, so the
  // gaps do not run inside one hook's time budget.
  const openNext = async () => {
    try {
      const s = queue.shift()
      if (s !== undefined) {
        // A session with no reply has no transcript to resume; start fresh in its place.
        const hasTranscript = await $.fs.exists(transcriptOf(s.cwd, s.sessionId))
        const dir = (await $.fs.exists(s.cwd)) ? s.cwd : home
        const isOpened = await openTab($, dir, hasTranscript ? `claude --resume ${s.sessionId}` : 'claude')
        if (!isOpened) {
          isRestoring = false
          return
        }
        if (queue.length > 0) {
          await say($, `残り ${queue.length} 件を ${RESTORE_GAP_MS / 1000} 秒おきに開きます`)
          $.clock.after(RESTORE_GAP_MS, () => void openNext())
          return
        }
      }
      isRestoring = false
      await $.store.delete(RESTORE_KEY)
      await update($, restorable, () => [])
    } catch (error) {
      isRestoring = false
      await say($, `タブを開けませんでした: ${String(error)}`)
    }
  }
  await openNext()
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // A -p run or an SDK host has no terminal to switch tabs in, and its
    // polls would only rewrite the layout the terminal sessions keep.
    if ((await $.session.surfaces()).length === 0) return next(e)
    home = (await $.env.get('HOME')) ?? ''
    ownId = await $.session.id()
    ownCwd = await $.session.cwd()
    try {
      await captureRestore($)
    } catch {
      // Nothing to offer this time; the layout itself is untouched.
    }
    await $.command.register({
      name: 'cs',
      description: 'セッション一覧を開く。/cs new [dir] で新しいタブに claude、/cs resume で過去のセッションから再開',
      argumentHint: '[new [dir] | resume]',
    })
    $.clock.every(POLL_MS, () => void poll($))
    await poll($)
    // Unasked, a pane seats only on a wide terminal (144 columns); /cs opens it anywhere.
    void $.ui.open({ id: PANE, title: 'sessions' })

    return next(e)
  })

  on('command.run', { command: 'cs' }, async ($, e) => {
    const [sub = '', ...rest] = e.args.trim().split(/\s+/).filter(Boolean)
    if (sub === 'new') {
      const raw = rest.join(' ')
      const dir = raw === '' ? ownCwd : raw.startsWith('~') ? `${home}${raw.slice(1)}` : raw
      if (!(await $.fs.exists(dir))) return { text: `ディレクトリがありません: ${dir}` }
      const isOpened = await openTab($, dir, 'claude')

      return { text: isOpened ? `${dir} で新しいタブを開きました` : await read($, note) }
    }
    if (sub === 'resume') {
      const isOpened = await openTab($, ownCwd, listTranscripts(home))

      return { text: isOpened ? '新しいタブで過去のセッションの一覧を開きました' : await read($, note) }
    }
    await poll($)
    await $.ui.open({ id: PANE, title: 'sessions', focus: true })

    return { text: '一覧を開きました（数字キーかクリックで移動、n 新規、r 再開、Esc で戻る）' }
  })

  // Below the width a pane needs, the list stays in sight as one line above the
  // prompt. Its buttons take clicks only: a band hotkey would answer a bare digit
  // typed into an empty prompt.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const pane = (await $.ui.panes()).find(p => p.id === PANE)
    if (pane?.isPlaced && pane.isShown) return next(e)
    const others = (await read($, sessions)).filter(s => s.sessionId !== ownId)
    if (others.length === 0) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    const width = Math.max(20, e.props.bodyColumns ?? 80)
    // Share the line between the sessions; a title gets what is left after the icon and gaps.
    const room = Math.max(6, Math.floor((width - 8) / others.length) - 4)
    const short = (text: string) => (text.length > room ? `${text.slice(0, room - 1)}…` : text)

    return (
      <Box flexDirection="row">
        {others.map(s => (
          <Button key={s.sessionId} onPress={() => void jump($, s)}>
            {ICON[s.status]} {short(s.title !== '' ? s.title : baseName(s.cwd))}
          </Button>
        ))}
        <Text dimColor> /cs</Text>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const list = await read($, sessions)
    const message = await read($, note)
    const open = new Set(list.map(s => s.sessionId))
    const missing = (await read($, restorable)).filter(s => !open.has(s.sessionId))
    const width = Math.max(16, e.props.bodyColumns ?? 30)
    const short = (text: string, room: number) => (text.length > room ? `${text.slice(0, room - 1)}…` : text)

    return (
      <Box flexDirection="column">
        {list.map((s, i) => {
          const isMe = s.sessionId === ownId
          const name = s.title !== '' ? s.title : baseName(s.cwd)

          return (
            <Box key={s.sessionId} flexDirection="column">
              <Button
                key={s.sessionId}
                hotkey={i < 9 ? String(i + 1) : undefined}
                onPress={() => (isMe ? undefined : void jump($, s))}
              >
                {ICON[s.status]} {short(name, Math.floor(width / 2) - 4)}
                {isMe ? <Text dimColor> (ここ)</Text> : ''}
              </Button>
              <Text dimColor>{'   '}{short(baseName(s.cwd), width - 4)}</Text>
            </Box>
          )
        })}
        <Text> </Text>
        {missing.length > 0 && (
          <Button key="restore" hotkey="o" onPress={() => void restore($)}>
            前回の {missing.length} セッションを開き直す
          </Button>
        )}
        <Button key="new" hotkey="n" onPress={() => void openTab($, ownCwd, 'claude')}>
          新規（{short(baseName(ownCwd), width - 12)}）
        </Button>
        <Button
          key="resume"
          hotkey="r"
          onPress={() =>
            void openTab($, ownCwd, listTranscripts(home))
          }
        >
          過去のセッションから再開
        </Button>
        {message !== '' && <Text color="warning">{message}</Text>}
      </Box>
    )
  })
}
