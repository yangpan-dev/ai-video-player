export interface PlayerPreferences {
  volume: number
  muted: boolean
  playbackRate: number
  brightness: number
  subtitleMode: 'bilingual' | 'original' | 'translation' | 'off'
  fontSize: number
  bottomMargin: number
  autoNext: boolean
}

export const PREFERENCES_KEY = 'aivideo-player.preferences.v1'

export function normalizePreferences(value: unknown): PlayerPreferences {
  const p = value && typeof value === 'object' ? value as Partial<PlayerPreferences> : {}
  const number = (v: unknown, fallback: number, min: number, max: number): number =>
    typeof v === 'number' && Number.isFinite(v) ? Math.min(max, Math.max(min, v)) : fallback
  return {
    volume: number(p.volume, 1, 0, 1),
    muted: p.muted === true,
    playbackRate: number(p.playbackRate, 1, 0.25, 3),
    brightness: number(p.brightness, 1, 0.4, 1.6),
    subtitleMode: ['bilingual', 'original', 'translation', 'off'].includes(p.subtitleMode ?? '') ? p.subtitleMode! : 'bilingual',
    fontSize: number(p.fontSize, 20, 12, 48),
    bottomMargin: number(p.bottomMargin, 76, 20, 220),
    autoNext: p.autoNext === true
  }
}
