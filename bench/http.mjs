// Closed-loop, authenticated HTTP latency + achieved throughput on a local testbed.
// node bench/http.mjs; BENCH_DIR, BENCH_REV, BENCH_OUTPUT required.
// No production URLs, writes, real credentials, or external mail.
import { readFile, appendFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';

const dir = process.env.BENCH_DIR;
assert(dir?.startsWith('/tmp/hireme-perf-'));
const metadata = JSON.parse(await readFile(`${dir}/testbed.json`, 'utf8'));
const base = new URL(`http://127.0.0.1:${Number(metadata.port)}`);
const revision = process.env.BENCH_REV;
const output = process.env.BENCH_OUTPUT;
assert(revision && output);
const count = Number(process.env.BENCH_N || 1000);
const packetCount = Number(process.env.BENCH_PACKET_N || 200);
assert(Number.isInteger(count) && count > 0 && Number.isInteger(packetCount) && packetCount > 0);
const levels = (process.env.BENCH_CONCURRENCY || '1,4,16').split(',').map(Number);
assert(levels.every(n => Number.isInteger(n) && n > 0 && n <= 64));

const operations = [
  ['Desk', 'shell', '/', bytes => assert.match(bytes.toString(), /id="desk"/)],
  ['Packet', 'pack', '/api/pack', bytes => {
    assert.equal(bytes.toString('ascii', 0, 4), 'HDP1');
    const header = JSON.parse(bytes.toString('utf8', 8, 8 + bytes.readUInt32LE(4)));
    assert.equal(header.n, metadata.job_count);
    assert.equal(header.v, 1);
  }],
  ['Desk', 'focus', `/api/focus/${metadata.job_ids[0]}`, bytes => {
    assert.equal(JSON.parse(bytes).job.id, metadata.job_ids[0]);
  }],
  ['Desk', 'root', `/api/root/${metadata.profile_ids[0]}`],
  ['Campaign', 'scoreboard', '/api/scoreboard'],
  ['Lanes', 'lanes', '/api/lanes'],
  ['Account', 'overview', '/api/account'],
  ['MFA', 'summary', '/api/account/security'],
];

for (const [page, interaction, path, validate] of operations) {
  if (process.env.BENCH_ONLY && !`${page}/${interaction}`.includes(process.env.BENCH_ONLY)) continue;
  const request = async () => {
    const start = performance.now();
    const response = await fetch(new URL(path, base), {
      headers: { cookie: `__Host-hireme=${metadata.cookie}`, accept: '*/*' },
      redirect: 'error', signal: AbortSignal.timeout(30000),
    });
    const bytes = Buffer.from(await response.arrayBuffer());
    const elapsed = performance.now() - start;
    assert.equal(response.status, 200, `${path} status ${response.status}`);
    if (validate) validate(bytes);
    else {
      const json = JSON.parse(bytes);
      assert(json && typeof json === 'object' && !json.error, `${path} must return successful JSON`);
    }
    return elapsed;
  };
  for (let i = 0; i < 20; i++) await request();
  for (const concurrency of levels) {
    const n = interaction === 'pack' ? packetCount : count;
    const samples = new Array(n);
    let next = 0;
    const start = performance.now();
    await Promise.all(Array.from({ length: concurrency }, async () => {
      for (;;) {
        const i = next++;
        if (i >= n) return;
        samples[i] = await request();
      }
    }));
    const wall_ms = performance.now() - start;
    const sorted = samples.toSorted((a, b) => a - b);
    const percentile = p => sorted[Math.max(0, Math.ceil(n * p) - 1)];
    const row = {
      page: `HTTP/${page}`, interaction: `${interaction} (concurrency ${concurrency})`,
      rev: revision, n, concurrency, job_count: metadata.job_count,
      scenario: metadata.scenario || 'canonical_unknown_ats', layer: 'http',
      mean: samples.reduce((a, b) => a + b, 0) / n,
      p0_1: percentile(.001), p1: percentile(.01), p50: percentile(.5),
      p99: percentile(.99), p99_9: percentile(.999),
      wall_ms, requests_per_second: n * 1000 / wall_ms,
      runtime: process.version, samples,
    };
    await appendFile(output, `${JSON.stringify(row)}\n`);
    const { samples: _, ...summary } = row;
    console.log(JSON.stringify(summary));
  }
}
