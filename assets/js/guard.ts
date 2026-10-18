// Running a lens's hooks (enter, view, after, refresh) so one that throws
// cannot take the page down with it: the hook's fallback stands in, its first
// failure is logged once with the error and told once in a clipped notice,
// and the failure latches per lens and hook until that hook works again, so a
// hook that keeps throwing (whatever its message) raises one notice, not one
// per repaint. Pure: the shell passes in how to notify, log and defer.

export const VERB = { enter: "load", view: "draw", after: "update", refresh: "refresh" } as const
export type Part = keyof typeof VERB

/** The longest a failure's message runs in its notice. */
export const CLIP = 200

/** An error's message as text, whatever was thrown: an object without a prototype, or one whose
 * toString throws, still reads as something, and describing it never throws. */
export function describe(e: unknown): string {
  try {
    if (e instanceof Error) return String(e.message)
    if (typeof e === "string") return e
    return String(e)
  } catch {
    try {
      return Object.prototype.toString.call(e)
    } catch {
      return "an unprintable error"
    }
  }
}

export interface Guard {
  /** `fn`'s value, or `fallback` when it throws. */
  run<T>(scope: string, part: Part, fn: () => T, fallback: T): T
  /** Whether `scope`'s `part` is failing now. */
  failing(scope: string, part: Part): boolean
}

export function guard(
  notify: (text: string) => void,
  log: (what: string, e: unknown) => void,
  defer: (fn: () => void) => void = queueMicrotask,
): Guard {
  const broken = new Set<string>()
  return {
    run(scope, part, fn, fallback) {
      const key = `${scope}:${part}`
      try {
        const r = fn()
        broken.delete(key)
        return r
      } catch (e) {
        if (!broken.has(key)) {
          broken.add(key)
          const what = `the ${scope} lens failed to ${VERB[part]}`
          try {
            log(what, e)
          } catch {
            // A console that cannot take the error loses the log, not the notice.
          }
          const why = describe(e).replace(/\s+/g, " ").trim().slice(0, CLIP)
          // After this paint: the notice repaints, and the hook would throw again.
          defer(() => notify(`The ${scope} lens failed to ${VERB[part]} (${why}). Reload the page; if it repeats, tell the operator's maintainer.`))
        }
        return fallback
      }
    },
    failing: (scope, part) => broken.has(`${scope}:${part}`),
  }
}
