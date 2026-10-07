// The factor page: a pending session presents a passkey. Codes post as
// plain forms; only the passkey needs a script.

import * as webauthn from "./webauthn.ts"

const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
const button = document.getElementById("use-passkey")

async function post(url: string, body: unknown): Promise<Response> {
  return fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json", "x-csrf-token": csrf },
    body: JSON.stringify(body),
  })
}

if (button instanceof HTMLButtonElement) {
  if (!webauthn.supported()) button.hidden = true
  button.addEventListener("click", async () => {
    button.disabled = true
    try {
      const options = await (await post("/sign-in/factor/webauthn", {})).json()
      const assertion = await webauthn.get(options)
      const res = await post("/sign-in/factor/webauthn/confirm", assertion)
      if (res.ok) location.assign("/")
      else {
        const data = (await res.json().catch(() => ({}))) as { error?: string }
        location.assign(`/sign-in/factor?error=${encodeURIComponent(data.error ?? "That passkey was not accepted.")}`)
      }
    } catch (cause) {
      button.disabled = false
      const main = document.getElementById("factor")
      const p = document.createElement("p")
      p.className = "banner hold-error"
      p.textContent = cause instanceof Error ? cause.message : String(cause)
      main?.insertBefore(p, button)
    }
  })
}
