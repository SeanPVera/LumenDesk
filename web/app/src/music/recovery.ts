import type { MusicFrameCommand } from './session'

const RECOVERY_KEY = 'lumendesk.music-recovery.v1'

export interface MusicRecovery {
  port: number
  states: MusicFrameCommand[]
}

/** Only explicit pending Stop/release work belongs here. Active sessions are
 * recovered by the bridge lease, because duplicated tabs inherit a copy of
 * session storage and must not stop a show that is still running. */
export function readMusicRecovery(storage: Pick<Storage, 'getItem'>): Map<string, MusicRecovery> {
  try {
    const saved: unknown = JSON.parse(storage.getItem(RECOVERY_KEY) ?? '[]')
    if (!Array.isArray(saved)) return new Map()
    return new Map(saved.filter((entry): entry is [string, MusicRecovery] => {
      if (!Array.isArray(entry) || entry.length !== 2 || typeof entry[0] !== 'string') return false
      const recovery = entry[1]
      return recovery && Number.isInteger(recovery.port) && recovery.port > 0 && recovery.port <= 65535
        && Array.isArray(recovery.states) && recovery.states.every((state: MusicFrameCommand) =>
          state && typeof state.fixtureID === 'string' && state.owner === entry[0]
          && Number.isFinite(state.controlRevision) && state.rgb
          && [state.rgb.r, state.rgb.g, state.rgb.b].every(channel => Number.isFinite(channel) && channel >= 0 && channel <= 255)
          && (state.restoring === true || state.release === true))
    }))
  } catch { return new Map() }
}

export function writeMusicRecovery(storage: Pick<Storage, 'setItem' | 'removeItem'>, entries: Map<string, MusicRecovery>): void {
  try {
    if (entries.size) storage.setItem(RECOVERY_KEY, JSON.stringify([...entries]))
    else storage.removeItem(RECOVERY_KEY)
  } catch { /* The bridge still owns crash recovery when storage is disabled. */ }
}
