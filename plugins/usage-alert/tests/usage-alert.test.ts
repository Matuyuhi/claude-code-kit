import type { On, SessionRateLimit, UsageUnit } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const NOW = Date.parse('2026-11-15T00:00:00Z')

function world(on: On, store: Record<string, unknown> = {}) {
  mock.store(on, store)
  mock.clock(on, { now: NOW })
  const toasts: string[] = []
  const notices: string[] = []
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.notify', (_$, e) => {
    notices.push(e.text)
    return { value: { isSent: true as const, channel: 'terminal_bell' } }
  })
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  return { toasts, notices }
}

const fiveHour = (percentUsed: number): SessionRateLimit => ({
  kind: 'five_hour',
  percentUsed,
  resetsAt: new Date(NOW + 80 * 60_000).toISOString(),
})

const rate = (limits: SessionRateLimit[]) => ({
  context: { window: 200_000 },
  rateLimits: limits,
  changed: ['rateLimits'] as UsageUnit[],
})

const context = (percent: number) => ({
  context: { window: 200_000, tokens: percent * 2_000, percent },
  rateLimits: [],
  changed: ['context'] as UsageUnit[],
})

test('announces each rate step once, the last one to the OS too', async ($, on) => {
  const { toasts, notices } = world(on)
  await $.session.measure(rate([fiveHour(79)]))
  await $.session.measure(rate([fiveHour(81)]))
  await $.session.measure(rate([fiveHour(85)]))
  await $.session.measure(rate([fiveHour(92.5)]))
  expect(toasts).toEqual([
    '5h の使用量が 81% に到達（リセットまで 1h20m）',
    '5h の使用量が 92% に到達（リセットまで 1h20m）',
  ])
  expect(notices).toEqual(['5h の使用量が 92% に到達（リセットまで 1h20m）'])
})

test('a step another session announced is not announced again', async ($, on) => {
  const { toasts } = world(on, { 'rate:five_hour': 80 })
  await $.session.measure(rate([fiveHour(84)]))
  expect(toasts).toEqual([])
})

test('a reset window re-arms the step', async ($, on) => {
  const { toasts } = world(on, { 'rate:five_hour': 90 })
  await $.session.measure(rate([fiveHour(3)]))
  await $.session.measure(rate([fiveHour(80)]))
  expect(toasts).toEqual(['5h の使用量が 80% に到達（リセットまで 1h20m）'])
})

test('context is announced on crossing and again after dropping below', async ($, on) => {
  const { toasts } = world(on)
  await $.session.measure(context(81))
  await $.session.measure(context(90))
  await $.session.measure(context(30))
  await $.session.measure(context(82))
  expect(toasts).toEqual([
    'コンテキストが 81% に到達（162K/200K）',
    'コンテキストが 82% に到達（164K/200K）',
  ])
})
