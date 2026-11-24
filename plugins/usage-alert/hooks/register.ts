import type { EngineInterface, Register, SessionContextUsage, SessionRateLimit } from 'claude-code'

// The highest step reached is the one announced; the last one also goes to the OS.
const RATE_STEPS = [80, 90]
const CONTEXT_STEP = 80

const LABEL: Record<string, string> = { five_hour: '5h', seven_day: '7d' }

// Rate limits are the account's, shared by every running session, so the step
// already announced is kept in the store: one session announces it, not each.
const rateKey = (kind: string) => `rate:${kind}`

// The context window is this session's own.
let contextStep = 0

const stepOf = (percent: number, steps: number[]) =>
  steps.filter(s => percent >= s).at(-1) ?? 0

function remaining(resetsAt: string | undefined, now: number): string {
  const at = resetsAt === undefined ? NaN : Date.parse(resetsAt)
  if (Number.isNaN(at)) return ''
  const mins = Math.max(0, Math.floor((at - now) / 60_000))
  const h = Math.floor(mins / 60)
  return `（リセットまで ${h > 0 ? `${h}h${mins % 60}m` : `${mins}m`}）`
}

async function checkRate($: EngineInterface, limit: SessionRateLimit) {
  const step = stepOf(limit.percentUsed, RATE_STEPS)
  const announced = Number((await $.store.get(rateKey(limit.kind))) ?? 0)
  if (step === announced) return
  // Falling below a step (the window reset) re-arms it without a notice.
  await $.store.set(rateKey(limit.kind), step)
  if (step < announced) return

  const text = `${LABEL[limit.kind] ?? limit.kind} の使用量が ${Math.floor(limit.percentUsed)}% に到達${remaining(limit.resetsAt, await $.clock.now())}`
  $.ui.toast(text)
  if (step === RATE_STEPS.at(-1)) {
    await $.ui.notify(text, { title: 'Claude Code 使用量', key: rateKey(limit.kind) })
  }
}

function checkContext($: EngineInterface, context: SessionContextUsage) {
  // Absent right after a compaction, until the next response reports a fill.
  if (context.percent === undefined) return
  const step = stepOf(context.percent, [CONTEXT_STEP])
  const rose = step > contextStep
  contextStep = step
  if (!rose) return
  const tokens = context.tokens === undefined ? '' : `（${Math.round(context.tokens / 1000)}K/${Math.round(context.window / 1000)}K）`
  $.ui.toast(`コンテキストが ${context.percent}% に到達${tokens}`)
}

export const register: Register = on => {
  on('session.measure', async ($, e, next) => {
    const result = await next(e)
    if (e.changed.includes('rateLimits')) {
      for (const limit of e.rateLimits) await checkRate($, limit)
    }
    if (e.changed.includes('context')) checkContext($, e.context)
    return result
  })
}
