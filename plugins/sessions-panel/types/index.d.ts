export type SessionStatus = 'busy' | 'idle' | 'waiting' | 'other'

export type Session = {
  pid: number
  sessionId: string
  cwd: string
  status: SessionStatus
  title: string
}

// One session as the layout keeps it, to open it again after everything was closed.
export type Saved = { sessionId: string; cwd: string; title: string }

declare module 'claude-code' {
  interface PluginState {
    'sessions-panel': { sessions: Shaped<Session[]>; note: string; restorable: Shaped<Saved[]> }
  }
}
