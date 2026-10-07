export function assertNever(x: never): never {
  throw new Error(`unreachable: ${JSON.stringify(x)}`)
}
