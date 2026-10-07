// Row-major card movement. h and l stay on the row, k and j stay on the
// column, the edge clamps. Tile size is the CSS --card-* lengths.

export type Dir = "h" | "j" | "k" | "l"

export interface Metrics { width: number; height: number; gap: number; inset: number }

const WIDTH_REM = 14.5
const HEIGHT_REM = 11.25
const GAP_REM = 0.5
const INSET_REM = 0.5

export function metrics(rem: number): Metrics {
  return { width: WIDTH_REM * rem, height: HEIGHT_REM * rem, gap: GAP_REM * rem, inset: INSET_REM * rem }
}

export function dirFromKey(key: string): Dir | null {
  switch (key) {
    case "h": case "ArrowLeft": return "h"
    case "j": case "ArrowDown": return "j"
    case "k": case "ArrowUp": return "k"
    case "l": case "ArrowRight": return "l"
    default: return null
  }
}

export function move(index: number, cols: number, count: number, dir: Dir): number {
  if (count <= 0) return 0
  const columns = Math.max(Math.trunc(cols), 1)
  const i = Math.min(Math.max(index, 0), count - 1)
  const row = Math.floor(i / columns)
  const col = i % columns
  let nr = row, nc = col
  switch (dir) {
    case "h": nc = col - 1; break
    case "l": nc = col + 1; break
    case "k": nr = row - 1; break
    case "j": nr = row + 1; break
  }
  if (nr < 0 || nc < 0 || nc >= columns) return i
  const next = nr * columns + nc
  return next < 0 || next >= count ? i : next
}

export function columns(containerWidth: number, m: Metrics): number {
  if (containerWidth <= 0) return 1
  const inner = containerWidth - m.inset * 2
  return Math.max(Math.trunc((inner + m.gap) / (m.width + m.gap)), 1)
}

/** Inclusive index range of the painted window, or [-1, -1]. */
export function slice(count: number, cols: number, scrollTop: number, viewport: number, m: Metrics, overscan = 2): [number, number] {
  if (count <= 0) return [-1, -1]
  const c = Math.max(Math.trunc(cols), 1)
  const stride = m.height + m.gap
  const scrolled = Math.max(scrollTop - m.inset, 0)
  const firstRow = Math.max(Math.trunc(scrolled / stride) - overscan, 0)
  const visibleRows = Math.max(Math.ceil(Math.max(viewport, 1) / stride), 1) + overscan * 2
  const start = firstRow * c
  const last = Math.min(count - 1, start + visibleRows * c - 1)
  return start > last ? [-1, -1] : [start, last]
}

export function origin(index: number, cols: number, m: Metrics): [number, number] {
  const c = Math.max(Math.trunc(cols), 1)
  return [m.inset + (index % c) * (m.width + m.gap), m.inset + Math.floor(index / c) * (m.height + m.gap)]
}

export function contentHeight(count: number, cols: number, m: Metrics): number {
  if (count <= 0) return 0
  const c = Math.max(Math.trunc(cols), 1)
  const rows = Math.ceil(count / c)
  return m.inset * 2 + rows * m.height + (rows - 1) * m.gap
}

/** Scroll offset keeping `index` in view; unchanged when already visible. */
export function scrollTo(index: number, cols: number, scrollTop: number, viewport: number, m: Metrics): number {
  const c = Math.max(Math.trunc(cols), 1)
  const y = m.inset + Math.floor(Math.max(index, 0) / c) * (m.height + m.gap)
  const bottom = y + m.height
  if (y < scrollTop) return y
  if (bottom > scrollTop + viewport) return Math.max(bottom - viewport, 0)
  return scrollTop
}
