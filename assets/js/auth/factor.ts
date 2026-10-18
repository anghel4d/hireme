// The factor page's passkey assertion: the only script an HTTP auth page
// ships. The page works without it (TOTP and recovery codes are forms).

import { get, supported, why } from "./webauthn.ts"

const button = document.getElementById("use-passkey")
const error = document.getElementById("factor-error")
const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""

const say = (text: string) => {
  if (error) error.textContent = text
}

const post = (path: string, body?: unknown) =>
  fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers: { "x-csrf-token": csrf, ...(body === undefined ? {} : { "content-type": "application/json" }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })

async function assert(): Promise<void> {
  say("")
  button?.setAttribute("aria-busy", "true")
  try {
    const begin = await post("/sign-in/factor/webauthn")
    if (!begin.ok) throw new Error(((await begin.json().catch(() => ({}))) as { error?: string }).error ?? "The passkey could not start.")
    const { publicKey } = (await begin.json()) as { publicKey: Record<string, unknown> }
    const verify = await post("/sign-in/factor/webauthn/verify", await get(publicKey))
    if (verify.ok) return location.assign("/")
    throw new Error(((await verify.json().catch(() => ({}))) as { error?: string }).error ?? "The passkey was not accepted.")
  } catch (e) {
    say(why(e))
  } finally {
    button?.removeAttribute("aria-busy")
  }
}

if (button instanceof HTMLButtonElement) {
  if (supported()) button.addEventListener("click", () => void assert())
  else button.hidden = true
}
