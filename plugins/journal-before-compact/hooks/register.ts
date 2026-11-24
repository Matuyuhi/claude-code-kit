import type { EngineInterface, Register } from 'claude-code'

const COMMAND = 'jcompact'

// Auto-compaction can't wait for a journal turn, so the journal is asked for
// while there is still room for it; re-armed once a compaction empties the window.
const AHEAD_PERCENT = 70
const REARM_PERCENT = 40

// A journal written this many turns ago or fewer still covers the session.
const FRESH_TURNS = 2

const JOURNAL_PROMPT =
  'context の compact の前に、journal skill を実行してこのセッションの作業記録を保存・更新してください。報告は保存先のパスだけの 1 行で。'

// The /jcompact the journal turn stands in front of, run when that turn ends.
let pending: { instructions?: string } | undefined
let isJournalTurn = false
let journaledAtTurn: number | undefined
let isAheadArmed = true

async function isFresh($: EngineInterface) {
  return journaledAtTurn !== undefined && (await $.session.turns()) - journaledAtTurn <= FRESH_TURNS
}

function askJournal($: EngineInterface) {
  // A hook can't submit a prompt itself (the turn would wait on that hook), so
  // the submit runs once the dispatch has ended.
  $.clock.after(0, () => {
    // Resolves as the journal turn starts. The submitting plugin's own
    // prompt.submit hook doesn't see the prompt, so the turn is marked here.
    void $.prompt.submit({ text: JOURNAL_PROMPT }).then(
      () => {
        isJournalTurn = true
      },
      err => {
        pending = undefined
        return $.ui.toast(`journal の依頼を送れませんでした: ${String(err)}`)
      },
    )
  })
}

function compact($: EngineInterface, request: { instructions?: string }) {
  // Outside the current dispatch, so the compaction doesn't wait on its hooks.
  $.clock.after(0, () => {
    void $.session.compact(request).then(
      async r => {
        if ('skip' in r) await $.ui.toast(`compact がスキップされました: ${String(r.skip)}`)
      },
      err => $.ui.toast(`compact に失敗しました: ${String(err)}`),
    )
  })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: COMMAND,
      description: 'journal skill で作業記録を保存してから compact する',
      argumentHint: '[compact の指示]',
    })
    return next(e)
  })

  // Another plugin can pass session.compact on before this mod sees it, so a
  // plain /compact can't be held back; /jcompact asks for the journal first.
  on('command.run', { command: COMMAND }, async ($, e) => {
    const request = { instructions: e.args.trim() || undefined }
    if (await isFresh($)) {
      compact($, request)
      return { text: '直近の journal があるので、そのまま compact します' }
    }
    pending = request
    askJournal($)
    return { text: 'journal を保存してから compact します' }
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId !== undefined || !isJournalTurn) return result

    isJournalTurn = false
    journaledAtTurn = await $.session.turns()

    const request = pending
    pending = undefined
    if (request === undefined) return result
    if (e.reason === 'answer') {
      compact($, request)
    } else {
      await $.ui.toast(`journal のターンが ${e.reason} で終わったので compact していません`)
    }
    return result
  })

  on('session.measure', async ($, e, next) => {
    const result = await next(e)
    const percent = e.context.percent
    if (percent === undefined || !e.changed.includes('context')) return result

    if (percent < REARM_PERCENT) {
      isAheadArmed = true
    } else if (percent >= AHEAD_PERCENT && isAheadArmed) {
      isAheadArmed = false
      if (!(await isFresh($))) askJournal($)
    }
    return result
  })
}
