#!/usr/bin/env node
// Nib device smoke runner (F090). Plays tools/smoke/*.json scripts (tool calls plus expectations) against a device
// through the in-app MCP/HTTP bridge, so every sideloaded build can be checked from a PC. Node 18+, no dependencies.
// Script format, options and examples: tools/smoke/README.md.
import { readFile, readdir, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline/promises';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROTOCOL_VERSION = '2025-06-18';
// Caller-chosen ids must be [A-Za-z0-9_-]{1,64}: "SMK" + base-36 time is unique per run and valid.
const RUN_ID = 'SMK' + Date.now().toString(36).toUpperCase();

const USAGE = `Usage: node tools/smoke/run.mjs [options] [script ...]

Runs tools/smoke/<script>.json (default: every *.json there) against Nib through the bridge.

Options:
  --url <url>        bridge address (env NIB_BRIDGE_URL; default http://127.0.0.1:7331)
  --token <token>    bearer token nib_... from Settings > Bridge (env NIB_BRIDGE_TOKEN)
  --var name=value   set a script variable (repeatable; JSON values allowed)
  --out <dir>        where renders and report.json go (default: a new folder in the temp directory)
  --timeout <s>      per-request limit in seconds (default 130; the bridge waits up to 120 s for confirmations)
  --no-manual        do not prompt for manual checks even on a terminal (they are listed as "manual")
  --bail             stop after the first script that fails
  --list             print the scripts and their steps without running them
  -v, --verbose      print every result
  -h, --help         this text

Exit codes: 0 all passed (skipped and manual steps allowed), 1 a step failed, 2 usage or connection error.`;

class UsageError extends Error {}
/** The bridge cannot be used at all (unreachable, token refused): the run stops. */
class BridgeError extends Error {}
/** A step cannot run as written (unknown variable, missing action). */
class StepError extends Error {}
class VarError extends StepError {}

// MARK: - Arguments

function parseLoose(text) {
  try { return JSON.parse(text); } catch { return text; }
}

function parseArgs(argv) {
  const o = {
    url: process.env.NIB_BRIDGE_URL || 'http://127.0.0.1:7331', token: process.env.NIB_BRIDGE_TOKEN || '',
    out: '', timeout: 130, manual: true, bail: false, list: false, verbose: false, help: false, vars: {}, scripts: [],
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) throw new UsageError(`${a} needs a value`);
      return argv[++i];
    };
    switch (a) {
      case '--url': o.url = next(); break;
      case '--token': o.token = next(); break;
      case '--out': o.out = next(); break;
      case '--timeout': o.timeout = Number(next()); break;
      case '--var': {
        const kv = next();
        const eq = kv.indexOf('=');
        if (eq < 1) throw new UsageError('--var needs name=value');
        o.vars[kv.slice(0, eq)] = parseLoose(kv.slice(eq + 1));
        break;
      }
      case '--no-manual': o.manual = false; break;
      case '--bail': o.bail = true; break;
      case '--list': o.list = true; break;
      case '-v': case '--verbose': o.verbose = true; break;
      case '-h': case '--help': o.help = true; break;
      default:
        if (a.startsWith('-')) throw new UsageError(`unknown option ${a}`);
        o.scripts.push(a);
    }
  }
  if (!Number.isFinite(o.timeout) || o.timeout <= 0) throw new UsageError('--timeout must be a positive number of seconds');
  return o;
}

async function resolveScripts(names) {
  if (!names.length) {
    return (await readdir(HERE)).filter((f) => f.endsWith('.json')).sort().map((f) => path.join(HERE, f));
  }
  return names.map((n) => {
    const hit = [n, path.join(HERE, n), path.join(HERE, n + '.json')].find((c) => c.endsWith('.json') && existsSync(c));
    if (!hit) throw new UsageError(`no smoke script "${n}" (looked in ${HERE})`);
    return path.resolve(hit);
  });
}

// MARK: - JSON helpers

function parseJSON(text) {
  try { return JSON.parse(text); } catch { return undefined; }
}

function typeOf(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  return typeof v;
}

function brief(v, max = 160) {
  if (v === undefined) return 'nothing';
  const s = typeof v === 'string' ? JSON.stringify(v) : JSON.stringify(v) ?? String(v);
  return s.length > max ? s.slice(0, max) + '...' : s;
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (typeOf(a) !== typeOf(b)) return false;
  if (Array.isArray(a)) return a.length === b.length && a.every((x, i) => deepEqual(x, b[i]));
  if (a && typeof a === 'object') {
    const ka = Object.keys(a), kb = Object.keys(b);
    return ka.length === kb.length && ka.every((k) => Object.prototype.hasOwnProperty.call(b, k) && deepEqual(a[k], b[k]));
  }
  return false;
}

/** "$.results[0].value.ref", "document", "$" (the whole value). */
function getPath(obj, p) {
  if (p === '$' || p === '') return obj;
  const s = p.startsWith('$.') ? p.slice(2) : p.startsWith('$') ? p.slice(1) : p;
  let cur = obj;
  for (const m of s.matchAll(/([^.[\]]+)|\[(\d+)\]/g)) {
    if (cur === null || cur === undefined) return undefined;
    cur = m[2] !== undefined ? cur[Number(m[2])] : cur[m[1]];
  }
  return cur;
}

// MARK: - Variables

function lookup(vars, name) {
  const v = getPath(vars, name.trim());
  if (v === undefined) throw new VarError(`unknown variable \${${name}}`);
  return v;
}

/** "${x}" alone keeps x's JSON type; inside a longer string it is spliced in as text. */
function substitute(v, vars) {
  if (typeof v === 'string') {
    const whole = v.match(/^\$\{([^}]+)\}$/);
    if (whole) return lookup(vars, whole[1]);
    return v.replace(/\$\{([^}]+)\}/g, (_, n) => {
      const x = lookup(vars, n);
      return typeof x === 'string' ? x : JSON.stringify(x);
    });
  }
  if (Array.isArray(v)) return v.map((x) => substitute(x, vars));
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, substitute(x, vars)]));
  return v;
}

// MARK: - Expectations

function sizeOf(v) {
  if (typeof v === 'string' || Array.isArray(v)) return v.length;
  if (v && typeof v === 'object') return Object.keys(v).length;
  return NaN;
}

const OPS = {
  $exists: (a, v) => (a !== undefined) === Boolean(v),
  $eq: (a, v) => deepEqual(a, v),
  $ne: (a, v) => !deepEqual(a, v),
  $match: (a, v) => typeof a === 'string' && new RegExp(v).test(a),
  $gt: (a, v) => typeof a === 'number' && a > v,
  $gte: (a, v) => typeof a === 'number' && a >= v,
  $lt: (a, v) => typeof a === 'number' && a < v,
  $lte: (a, v) => typeof a === 'number' && a <= v,
  $len: (a, v) => sizeOf(a) === v,
  $minLen: (a, v) => sizeOf(a) >= v,
  $maxLen: (a, v) => sizeOf(a) <= v,
  $contains: (a, v) => (typeof a === 'string'
    ? typeof v === 'string' && a.includes(v)
    : Array.isArray(a) && a.some((x) => match(x, v, '').length === 0)),
  $type: (a, v) => typeOf(a) === v,
  $oneOf: (a, v) => Array.isArray(v) && v.some((x) => match(a, x, '').length === 0),
  $not: (a, v) => match(a, v, '').length > 0,
};

function isMatcher(e) {
  if (!e || typeof e !== 'object' || Array.isArray(e)) return false;
  const keys = Object.keys(e);
  return keys.length > 0 && keys.every((k) => k.startsWith('$'));
}

/**
 * Subset match: objects need only the listed keys, arrays match element by element (same length), anything else is
 * compared exactly; `{"$op": …}` objects are matchers.
 */
function match(actual, expected, at) {
  if (isMatcher(expected)) {
    const problems = [];
    for (const [op, v] of Object.entries(expected)) {
      const fn = OPS[op];
      if (!fn) problems.push(`${at}: unknown matcher ${op}`);
      else if (!fn(actual, v)) problems.push(`${at}: expected ${op} ${brief(v)}, got ${brief(actual)}`);
    }
    return problems;
  }
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) return [`${at}: expected an array, got ${brief(actual)}`];
    if (actual.length !== expected.length) return [`${at}: expected ${expected.length} element(s), got ${actual.length}`];
    return expected.flatMap((e, i) => match(actual[i], e, `${at}[${i}]`));
  }
  if (expected !== null && typeof expected === 'object') {
    if (!actual || typeof actual !== 'object' || Array.isArray(actual)) return [`${at}: expected an object, got ${brief(actual)}`];
    return Object.entries(expected).flatMap(([k, e]) => match(actual[k], e, `${at}.${k}`));
  }
  return deepEqual(actual, expected) ? [] : [`${at}: expected ${brief(expected)}, got ${brief(actual)}`];
}

function errorText(r) {
  const e = r.json?.error;
  if (e && typeof e === 'object') return `[${e.code}] ${e.message}${e.hint ? ` (hint: ${e.hint})` : ''}`;
  return brief(r.text);
}

function check(expect, r, kind) {
  const p = [];
  if (kind === 'http') {
    p.push(...match(r.status, expect.status ?? { $lt: 400 }, 'status'));
  } else {
    const wantError = expect.isError ?? (expect.ok !== undefined ? !expect.ok : expect.error !== undefined);
    if (r.isError !== wantError) p.push(wantError ? `expected an error, got ${brief(r.json ?? r.text)}` : `failed: ${errorText(r)}`);
    if (expect.error !== undefined) p.push(...match(r.json?.error?.code, expect.error, 'error.code'));
  }
  if (expect.json !== undefined) p.push(...match(r.json, expect.json, '$'));
  if (expect.text !== undefined) {
    if (typeof expect.text === 'string') {
      if (!r.text.includes(expect.text)) p.push(`text does not contain ${brief(expect.text)}`);
    } else {
      p.push(...match(r.text, expect.text, 'text'));
    }
  }
  if (expect.image !== undefined && (r.images.length > 0) !== Boolean(expect.image)) {
    p.push(expect.image ? 'expected an image result' : 'expected no image');
  }
  if (expect.maxMs !== undefined && r.ms > expect.maxMs) p.push(`took ${r.ms} ms (limit ${expect.maxMs} ms)`);
  return p;
}

// MARK: - Bridge client (MCP Streamable HTTP, JSON-response mode)

function describeFetchError(e, base, seconds) {
  if (e?.name === 'TimeoutError' || e?.name === 'AbortError') return `no answer from ${base} within ${seconds} s`;
  const code = e?.cause?.code;
  if (code === 'ECONNREFUSED') {
    return `nothing is listening at ${base}: is Nib open in the foreground with the bridge on (Settings > Bridge)?`;
  }
  if (['EHOSTUNREACH', 'ENETUNREACH', 'ETIMEDOUT', 'UND_ERR_CONNECT_TIMEOUT'].includes(code)) {
    return `cannot reach ${base} (${code}): same Wi-Fi, or Tailscale up on both devices?`;
  }
  if (code === 'ENOTFOUND') return `unknown host in ${base}`;
  if (code === 'ECONNRESET' || code === 'UND_ERR_SOCKET') return `${base} dropped the connection (Nib went to the background?)`;
  return `${base}: ${e?.cause?.message ?? e?.message ?? e}`;
}

class Bridge {
  constructor({ url, token, timeout }) {
    this.base = url.replace(/\/+$/, '').replace(/\/mcp$/, '');
    this.origin = new URL(this.base).origin;
    this.token = token;
    this.timeout = timeout;
    this.session = null;
    this.protocol = PROTOCOL_VERSION;
    this.nextId = 1;
    this.tools = new Set();
    this.server = null;
  }

  async http(method, target, { body, headers = {}, auth = true } = {}) {
    // Absolute URLs (asset links in results) are fetched from the bridge we were given, never another host.
    const pathname = /^https?:\/\//i.test(target) ? (() => { const u = new URL(target); return u.pathname + u.search; })() : target;
    const h = { ...headers };
    if (auth) h.Authorization = `Bearer ${this.token}`;
    let payload;
    if (body !== undefined) {
      payload = typeof body === 'string' ? body : JSON.stringify(body);
      if (!Object.keys(h).some((k) => k.toLowerCase() === 'content-type')) h['Content-Type'] = 'application/json';
    }
    const started = performance.now();
    let res;
    try {
      res = await fetch(this.origin + pathname, { method, headers: h, body: payload, signal: AbortSignal.timeout(this.timeout * 1000) });
    } catch (e) {
      throw new BridgeError(describeFetchError(e, this.base, this.timeout));
    }
    let buffer;
    try {
      buffer = Buffer.from(await res.arrayBuffer());
    } catch (e) {
      throw new BridgeError(describeFetchError(e, this.base, this.timeout));
    }
    const text = buffer.toString('utf8');
    return { status: res.status, headers: res.headers, buffer, text, json: parseJSON(text), ms: Math.round(performance.now() - started) };
  }

  mcpHeaders() {
    const h = { Accept: 'application/json, text/event-stream' };
    if (this.session) {
      h['Mcp-Session-Id'] = this.session;
      h['MCP-Protocol-Version'] = this.protocol;
    }
    return h;
  }

  async rpc(method, params) {
    const message = { jsonrpc: '2.0', id: this.nextId++, method };
    if (params !== undefined) message.params = params;
    const r = await this.http('POST', '/mcp', { body: message, headers: this.mcpHeaders() });
    if (r.status === 401) throw new BridgeError('the bridge refused the token (401): copy it again from Settings > Bridge');
    if (r.status === 403 && !r.json?.jsonrpc) {
      throw new BridgeError(`the bridge refused this computer (403): ${r.json?.error?.message ?? 'forbidden'}`);
    }
    if (!r.json || typeof r.json !== 'object' || !('result' in r.json || 'error' in r.json)) {
      throw new BridgeError(`POST /mcp ${method}: HTTP ${r.status}, unexpected body ${brief(r.text)}`);
    }
    return { ...r.json, ms: r.ms, headers: r.headers, status: r.status };
  }

  async open() {
    const r = await this.rpc('initialize', {
      protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: 'nib-smoke', version: '1.0' },
    });
    if (r.error) throw new BridgeError(`initialize failed: ${r.error.message}`);
    this.protocol = r.result.protocolVersion ?? PROTOCOL_VERSION;
    this.session = r.headers.get('mcp-session-id');
    this.server = r.result.serverInfo ?? {};
    await this.http('POST', '/mcp', { body: { jsonrpc: '2.0', method: 'notifications/initialized' }, headers: this.mcpHeaders() });
    const list = await this.rpc('tools/list', {});
    if (list.error) throw new BridgeError(`tools/list failed: ${list.error.message}`);
    this.tools = new Set((list.result.tools ?? []).map((t) => t.name));
  }

  async close() {
    if (!this.session) return;
    try {
      await this.http('DELETE', '/mcp', { headers: this.mcpHeaders() });
    } catch {
      // The session expires with the app anyway.
    }
    this.session = null;
  }

  /** tools/call, following result cursors (results over 20 KB come in pages) and decoding image parts. */
  async callTool(name, args = {}) {
    let r = await this.rpc('tools/call', { name, arguments: args });
    if (r.error) {
      return { isError: true, json: { error: r.error }, text: r.error.message ?? '', images: [], ms: r.ms };
    }
    let ms = r.ms;
    const texts = [];
    const images = [];
    const isError = Boolean(r.result.isError);
    for (;;) {
      const pageTexts = [];
      for (const part of r.result.content ?? []) {
        if (part.type === 'image') images.push({ data: Buffer.from(part.data, 'base64'), mimeType: part.mimeType });
        else if (part.type === 'text') pageTexts.push(part.text);
      }
      const more = pageTexts.length > 1 ? parseJSON(pageTexts[pageTexts.length - 1]) : undefined;
      if (more?.truncated === true && typeof more.cursor === 'string') {
        texts.push(...pageTexts.slice(0, -1));
        r = await this.rpc('tools/call', { name, arguments: { cursor: more.cursor } });
        if (r.error) throw new StepError(`reading the next page of ${name}: ${r.error.message}`);
        ms += r.ms;
        continue;
      }
      texts.push(...pageTexts);
      break;
    }
    const text = texts.join('');
    return { isError, text, json: parseJSON(text), images, ms };
  }
}

// MARK: - Steps

function kindOf(step) {
  if (step.manual !== undefined || step.ask !== undefined || step.prompt !== undefined) return 'manual';
  if (step.waitEvent !== undefined || step.event !== undefined) return 'event';
  if (step.wait !== undefined) return 'wait';
  if (step.http !== undefined) return 'http';
  if (step.tool !== undefined || step.call !== undefined) return 'tool';
  if (step.command !== undefined) return 'command';
  if (step.method !== undefined) return 'rpc';
  return 'none';
}

function stepLabel(step, index) {
  if (step.name) return String(step.name);
  switch (kindOf(step)) {
    case 'manual': return String(step.manual ?? step.ask ?? step.prompt).slice(0, 60);
    case 'event': return `wait for ${brief(step.waitEvent ?? step.event, 60)}`;
    case 'wait': return `wait ${step.wait} s`;
    case 'http': return `${step.http.method ?? 'GET'} ${step.http.path}`;
    case 'tool': return String(step.tool ?? step.call);
    case 'command': return String(step.command);
    case 'rpc': return String(step.method);
    default: return `step ${index + 1}`;
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitEvent(ctx, spec) {
  if (!ctx.bridge.tools.has('nib_events')) throw new StepError('this build has no nib_events tool');
  const want = typeof spec === 'string' ? { type: spec } : spec;
  const seconds = want.timeout ?? 30;
  const deadline = Date.now() + seconds * 1000;
  const started = performance.now();
  const seen = new Set();
  for (;;) {
    const wait = Math.max(0, Math.min(25, (deadline - Date.now()) / 1000));
    const r = await ctx.bridge.callTool('nib_events', { since: ctx.eventCursor ?? undefined, wait });
    if (r.isError) return r;
    for (const e of r.json?.events ?? []) {
      ctx.eventCursor = e.seq;
      const problems = [
        ...(want.type !== undefined ? match(e.type, want.type, 'type') : []),
        ...(want.doc !== undefined ? match(e.doc, want.doc, 'doc') : []),
        ...(want.match !== undefined ? match(e, want.match, 'event') : []),
      ];
      if (!problems.length) {
        return { isError: false, json: e, text: JSON.stringify(e), images: [], ms: Math.round(performance.now() - started) };
      }
      seen.add(e.type);
    }
    if (typeof r.json?.last === 'number') ctx.eventCursor = r.json.last;
    if (Date.now() >= deadline) {
      const message = `no matching event within ${seconds} s (saw: ${[...seen].join(', ') || 'nothing'})`;
      return { isError: true, json: { error: { code: 'timeout', message } }, text: message, images: [], ms: Math.round(performance.now() - started) };
    }
  }
}

async function manualStep(ctx, step, label) {
  const prompt = String(step.manual ?? step.ask ?? step.prompt);
  if (!ctx.rl) return { name: label, status: 'manual', prompt };
  console.log(`\n  ? ${prompt}`);
  for (;;) {
    const answer = (await ctx.rl.question('    [y]es / [n]o / [s]kip > ')).trim().toLowerCase();
    if (answer.startsWith('y')) return { name: label, status: 'passed', prompt };
    if (answer.startsWith('s')) return { name: label, status: 'skipped', prompt };
    if (answer.startsWith('n')) {
      const note = (await ctx.rl.question('    what went wrong? > ')).trim();
      return { name: label, status: step.optional ? 'warned' : 'failed', prompt, problems: [note || 'the person said no'] };
    }
  }
}

function slug(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'script';
}

async function saveImages(ctx, r, step, index, phase) {
  const saved = [];
  for (const [i, image] of r.images.entries()) {
    const ext = image.mimeType === 'image/jpeg' ? 'jpg' : 'png';
    const name = i === 0 && step.saveImage
      ? String(step.saveImage)
      : `${slug(ctx.script)}-${phase === 'cleanup' ? 'cleanup-' : ''}${String(index + 1).padStart(2, '0')}${r.images.length > 1 ? `-${i + 1}` : ''}.${ext}`;
    await mkdir(ctx.out, { recursive: true });
    const file = path.join(ctx.out, path.basename(name));
    await writeFile(file, image.data);
    saved.push(file);
  }
  return saved;
}

async function runStep(ctx, raw, index, phase) {
  let step;
  try {
    step = substitute(raw, ctx.vars);
  } catch (e) {
    const name = stepLabel(raw, index);
    if (e instanceof VarError && phase === 'cleanup') return { name, status: 'skipped', problems: [e.message] };
    return { name, status: raw.optional ? 'warned' : 'failed', problems: [e.message] };
  }
  const label = stepLabel(step, index);
  const fail = (problems, extra = {}) => ({ name: label, status: step.optional ? 'warned' : 'failed', problems, ...extra });
  try {
    const kind = kindOf(step);
    let r;
    switch (kind) {
      case 'manual':
        return await manualStep(ctx, step, label);
      case 'wait':
        await sleep(Number(step.wait) * 1000);
        return { name: label, status: 'passed', ms: Math.round(Number(step.wait) * 1000) };
      case 'event':
        r = await waitEvent(ctx, step.waitEvent ?? step.event);
        break;
      case 'http': {
        const { method = 'GET', path: target, body, headers, auth = true } = step.http;
        if (!target) throw new StepError('http steps need a path');
        const h = await ctx.bridge.http(method, target, { body, headers, auth });
        const type = h.headers.get('content-type') ?? '';
        const images = type.startsWith('image/') ? [{ data: h.buffer, mimeType: type }] : [];
        r = { status: h.status, isError: h.status >= 400, json: h.json, text: images.length ? '' : h.text, images, ms: h.ms };
        break;
      }
      case 'tool': {
        const name = step.tool ?? step.call;
        if (ctx.bridge.tools.size && !ctx.bridge.tools.has(name)) {
          return fail([`the bridge does not offer the tool ${name} (see tools/list)`]);
        }
        r = await ctx.bridge.callTool(name, step.args ?? step.arguments ?? step.params ?? {});
        break;
      }
      case 'command': {
        const args = { command: step.command, params: step.params ?? {} };
        if (step.dryRun || step.dry_run) args.dry_run = true;
        r = await ctx.bridge.callTool('nib_run', args);
        break;
      }
      case 'rpc': {
        const x = await ctx.bridge.rpc(step.method, step.params);
        r = x.error
          ? { isError: true, json: { error: x.error }, text: x.error.message ?? '', images: [], ms: x.ms }
          : { isError: false, json: x.result, text: JSON.stringify(x.result), images: [], ms: x.ms };
        break;
      }
      default:
        throw new StepError('the step has no action: use tool, command, method, http, waitEvent, wait or manual');
    }
    const images = await saveImages(ctx, r, step, index, phase);
    const problems = check(step.expect ?? {}, r, kind);
    if (!problems.length) {
      for (const [name, p] of Object.entries(step.save ?? {})) {
        const v = p === '$text' ? r.text : getPath(r.json, String(p));
        if (v === undefined) problems.push(`save ${name}: ${p} is not in the result`);
        else ctx.vars[name] = v;
      }
    }
    const result = { name: label, status: problems.length ? (step.optional ? 'warned' : 'failed') : 'passed', ms: r.ms, images };
    if (problems.length) result.problems = problems;
    result.output = r.text.length > 4000 ? r.text.slice(0, 4000) + '...' : r.text;
    return result;
  } catch (e) {
    if (e instanceof BridgeError) throw e;
    return fail([e instanceof StepError ? e.message : String(e?.stack ?? e)]);
  }
}

// MARK: - Scripts

const MARK = { passed: 'ok     ', failed: 'FAIL   ', warned: 'warn   ', skipped: 'skip   ', manual: 'manual ', 'not run': '-      ' };

function printStep(res, n, opts, prefix = '') {
  const ms = res.ms !== undefined ? ` (${res.ms} ms)` : '';
  console.log(`  ${prefix}${MARK[res.status] ?? res.status} ${String(n).padStart(2)} ${res.name}${ms}`);
  for (const p of res.problems ?? []) console.log(`            ${p}`);
  if (res.status === 'manual') console.log(`            needs a person: ${res.prompt}`);
  for (const f of res.images ?? []) console.log(`            image: ${f}`);
  if (opts.verbose && res.output) console.log(res.output.split('\n').map((l) => `            | ${l}`).join('\n'));
}

async function loadScript(file) {
  const raw = JSON.parse(await readFile(file, 'utf8'));
  const script = Array.isArray(raw) ? { steps: raw } : raw ?? {};
  return {
    name: String(script.name ?? path.basename(file, '.json')),
    description: script.description,
    requires: Array.isArray(script.requires) ? script.requires : [],
    vars: script.vars ?? {},
    steps: Array.isArray(script.steps) ? script.steps : [],
    cleanup: Array.isArray(script.cleanup) ? script.cleanup : [],
  };
}

async function runScript(bridge, file, opts, shared) {
  const report = { script: path.basename(file, '.json'), file, status: 'passed', steps: [], cleanup: [] };
  let script;
  try {
    script = await loadScript(file);
  } catch (e) {
    report.status = 'failed';
    report.reason = `cannot read ${file}: ${e.message}`;
    console.log(`\n== ${report.script}: FAIL ${report.reason}`);
    return report;
  }
  report.script = script.name;
  console.log(`\n== ${script.name} (${path.relative(process.cwd(), file) || file})${script.description ? `: ${script.description}` : ''}`);
  if (!script.steps.length) {
    report.status = 'skipped';
    report.reason = 'no steps';
    console.log('  skip    (no steps yet)');
    return report;
  }
  for (const id of script.requires) {
    const r = await bridge.callTool('nib_command_schema', { id });
    if (r.isError) {
      report.status = 'skipped';
      report.reason = `needs ${id}, which this build does not have`;
      console.log(`  skip    ${report.reason}`);
      return report;
    }
  }
  const ctx = { bridge, out: shared.out, rl: shared.rl, script: script.name, eventCursor: undefined,
                vars: { run: RUN_ID, script: script.name, ...script.vars, ...opts.vars } };
  if (bridge.tools.has('nib_events')) {
    const start = await bridge.callTool('nib_events', { wait: 0 });
    if (typeof start.json?.last === 'number') ctx.eventCursor = start.json.last;
  }
  let stopped = false;
  for (const [i, step] of script.steps.entries()) {
    const res = stopped ? { name: stepLabel(step, i), status: 'not run' } : await runStep(ctx, step, i, 'steps');
    report.steps.push(res);
    printStep(res, i + 1, opts);
    if (res.status === 'failed') stopped = true;
  }
  for (const [i, step] of script.cleanup.entries()) {
    const res = await runStep(ctx, step, i, 'cleanup');
    report.cleanup.push(res);
    printStep(res, i + 1, opts, 'cleanup ');
  }
  const all = [...report.steps, ...report.cleanup];
  if (all.some((s) => s.status === 'failed')) report.status = 'failed';
  else if (all.some((s) => s.status === 'manual')) report.status = 'manual';
  return report;
}

// MARK: - Main

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(USAGE);
    return 0;
  }
  const files = await resolveScripts(opts.scripts);
  if (!files.length) {
    console.error(`no smoke scripts in ${HERE}`);
    return 2;
  }
  if (opts.list) {
    for (const f of files) {
      try {
        const s = await loadScript(f);
        console.log(`${path.basename(f)}: ${s.name}${s.description ? ` - ${s.description}` : ''}`);
        s.steps.forEach((st, i) => console.log(`  ${String(i + 1).padStart(2)} [${kindOf(st)}] ${stepLabel(st, i)}`));
        s.cleanup.forEach((st, i) => console.log(`  cleanup ${i + 1} [${kindOf(st)}] ${stepLabel(st, i)}`));
        if (!s.steps.length) console.log('  (no steps)');
      } catch (e) {
        console.log(`${path.basename(f)}: cannot read (${e.message})`);
      }
    }
    return 0;
  }
  if (!opts.token) throw new BridgeError('no token: pass --token nib_... or set NIB_BRIDGE_TOKEN (Settings > Bridge shows it)');

  const bridge = new Bridge(opts);
  const health = await bridge.http('GET', '/health', { auth: false });
  if (health.status !== 200 || health.json?.app !== 'nib') {
    throw new BridgeError(`${bridge.base}/health answered ${health.status} ${brief(health.text)}: is this the Nib bridge?`);
  }
  await bridge.open();
  console.log(`nib smoke | ${bridge.base} | ${bridge.server?.name ?? 'nib'} ${bridge.server?.version ?? ''} | MCP ${bridge.protocol} | ${bridge.tools.size} tools | run ${RUN_ID}`);

  const shared = {
    out: path.resolve(opts.out || path.join(os.tmpdir(), `nib-smoke-${RUN_ID}`)),
    rl: opts.manual && process.stdin.isTTY ? readline.createInterface({ input: process.stdin, output: process.stdout }) : null,
  };
  const reports = [];
  const startedAt = new Date().toISOString();
  try {
    for (const f of files) {
      const r = await runScript(bridge, f, opts, shared);
      reports.push(r);
      if (opts.bail && r.status === 'failed') break;
    }
  } finally {
    shared.rl?.close();
    await bridge.close();
  }

  const steps = reports.flatMap((r) => [...r.steps, ...r.cleanup]);
  const count = (s) => steps.filter((x) => x.status === s).length;
  const failed = reports.filter((r) => r.status === 'failed').length;
  console.log(`\n${reports.length} script(s): ${count('passed')} passed, ${count('failed')} failed, ${count('warned')} warned, ` +
    `${count('manual')} manual, ${count('skipped') + reports.filter((r) => r.status === 'skipped').length} skipped, ${count('not run')} not run`);
  const manual = steps.filter((x) => x.status === 'manual');
  if (manual.length) {
    console.log('Manual checks for a person at the device (run on a terminal to answer them):');
    for (const m of manual) console.log(`  - ${m.prompt}`);
  }
  await mkdir(shared.out, { recursive: true });
  const reportFile = path.join(shared.out, 'report.json');
  await writeFile(reportFile, JSON.stringify({ run: RUN_ID, url: bridge.base, server: bridge.server, startedAt,
                                               finishedAt: new Date().toISOString(), scripts: reports }, null, 2));
  console.log(`Report and images: ${shared.out}`);
  return failed ? 1 : 0;
}

main().then(
  (code) => { process.exitCode = code; },
  (e) => {
    if (e instanceof UsageError) console.error(`${e.message}\n\n${USAGE}`);
    else if (e instanceof BridgeError) console.error(`bridge: ${e.message}`);
    else console.error(e?.stack ?? e);
    process.exitCode = 2;
  },
);
