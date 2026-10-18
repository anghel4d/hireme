// Hosts as people read them (assets/js/morph.ts): punycode decoded per RFC 3492, kept as xn-- in doubt.
// bun test assets/test/morph.test.mjs
import { expect, test } from "bun:test"
import { punyDecode, unicodeHost } from "../js/morph.ts"

test("RFC 3492's sample strings decode (section 7.1)", () => {
  const samples = {
    egbpdaj6bu4bxfgehfvwxn: "ليهمابتكلموشعربي؟",
    ihqwcrb4cv8a8dqg056pqjye: "他们为什么不说中文",
    ihqwctvzc91f659drss3x8bo0yb: "他們爲什麽不說中文",
    "Proprostnemluvesky-uyb24dma41a": "Pročprostěnemluvíčesky",
    "4dbcagdahymbxekheh6e0a7fei0b": "למההםפשוטלאמדבריםעברית",
    "3B-ww4c5e180e575a65lsy2b": "3年B組金八先生",
    "-with-SUPER-MONKEYS-pc58ag80a8qai00g7n9n": "安室奈美恵-with-SUPER-MONKEYS",
    d9juau41awczczp: "そのスピードで",
  }
  for (const [code, text] of Object.entries(samples)) expect(punyDecode(code)).toBe(text)
})

test("a host reads in Unicode, label by label", () => {
  expect(unicodeHost("xn--mller-kva.example")).toBe("müller.example")
  expect(unicodeHost("jobs.xn--eckwd4c7c.example")).toBe("jobs.ドメイン.example")
  expect(unicodeHost("plain.example")).toBe("plain.example")
  // The seed's Vietnamese host is v-i-t + a combining n (U+1DE1): what its punycode says, valid to the URL parser.
  expect(unicodeHost("xn--vit-nam-ge3c.example")).toBe("vitᷡ-nam.example")
})

test("in doubt the xn-- form stands", () => {
  expect(unicodeHost("xn--zz.example")).toBe("xn--zz.example")
  // A label that would begin with a combining mark is not a host the URL parser accepts.
  expect(unicodeHost("xn--ab-7tb.example")).toBe("xn--ab-7tb.example")
})
