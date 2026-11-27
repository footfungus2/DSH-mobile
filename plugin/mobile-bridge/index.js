// Host half of the @local/mobile-bridge plugin.
//
// Opens a LAN HTTP port the moment the harness starts so the DSH Mobile app
// has a fixed bridge to talk to (PLAN.md Option B, first slice). Every inbound
// device is tracked and announced in a log ring buffer that the sidebar panel
// renders as a live console. No conversation data crosses this port yet —
// Phase 1 capture will add the real session endpoints here.

import http from 'node:http';
import os from 'node:os';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const CHANNEL = '/api/mobile-bridge';
const PORT = Number(process.env.DSH_MOBILE_BRIDGE_PORT ?? 8328);
const MAX_LOG_LINES = 200;

export const inject = ['connection', 'sessionController', 'sessionQuery'];

const logLines = [];
const devices = new Map(); // ip -> { firstSeen, lastSeen, requests }
let lastError = null;
let host = null; // session services, installed in apply(ctx)

function log(message) {
  const time = new Date().toLocaleTimeString('en-GB', { hour12: false });
  const line = `${time}  ${message}`;
  logLines.push(line);
  if (logLines.length > MAX_LOG_LINES) logLines.shift();
  console.log(`[mobile-bridge] ${line}`);
}

function lanAddresses() {
  return Object.values(os.networkInterfaces())
    .flat()
    .filter((entry) => entry && entry.family === 'IPv4' && !entry.internal)
    .map((entry) => entry.address);
}

function trackDevice(ip) {
  const now = new Date().toISOString();
  const existing = devices.get(ip);
  if (existing) {
    existing.lastSeen = now;
    existing.requests += 1;
  } else {
    devices.set(ip, { firstSeen: now, lastSeen: now, requests: 1 });
    log(`device connected from ${ip}`);
  }
}

function json(response, status, value) {
  response.writeHead(status, {
    'content-type': 'application/json',
    'access-control-allow-origin': '*',
  });
  response.end(JSON.stringify(value));
}

const signal = () => new AbortController().signal;

// Registered mock conversations (harness-style demo transcripts). They are
// prepended to the real session list so the phone always has something rich
// to render, even on a fresh profile.
const MOCK_SESSIONS = [
  {
    id: 'ses_mock_1',
    title: 'can you show me what a full transcript looks like?',
    model: 'EAC Kimi K3 1 Pro Low',
    updatedAt: Date.now() - 19 * 60_000,
  },
  {
    id: 'ses_mock_2',
    title: 'test',
    model: 'EAC Qwen3.8 Max 1 High',
    updatedAt: Date.now() - 30 * 60_000,
  },
  {
    id: 'ses_mock_3',
    title: 'test',
    model: 'EAC GLM 5.2 1 Max',
    updatedAt: Date.now() - 3 * 3_600_000,
  },
  {
    id: 'ses_mock_4',
    title: 'test',
    model: 'GPT OSS 120B',
    updatedAt: Date.now() - 5 * 3_600_000,
  },
];

let mockMessages = null;
let mockMtime = 0;
const mockFile = join(dirname(fileURLToPath(import.meta.url)), 'mock-messages.json');
function loadMocks(force = false) {
  try {
    const { mtimeMs } = statSync(mockFile);
    if (!force && mtimeMs === mockMtime) return;
    mockMtime = mtimeMs;
    mockMessages = new Map(Object.entries(JSON.parse(readFileSync(mockFile, 'utf8'))));
    log(`mock transcripts registered for ${mockMessages.size} session(s)`);
  } catch (cause) {
    mockMessages = null;
    log(`mock transcripts disabled: ${String(cause?.message ?? cause)}`);
  }
}
loadMocks(true);

function mockSessionMessages(sessionId) {
  loadMocks();
  const stored = mockMessages?.get(sessionId);
  if (!stored) return null;
  const meta = MOCK_SESSIONS.find((session) => session.id === sessionId);
  const messages = stored.map((message) => ({
    role: message.role,
    time: message.time,
    parts: message.parts.map((part) => {
      if (part.t === 'tool') {
        return {
          kind: 'tool',
          name: part.name,
          title: part.detail,
          status: part.status,
          error: part.error,
          sub: (part.children ?? []).map((child) => ({
            name: child.name,
            title: child.detail,
            status: child.status,
            error: child.error,
            exitCode: /exit code (\d+)/.exec(child.result ?? '')?.[1] === undefined ? undefined : Number(/exit code (\d+)/.exec(child.result ?? '')?.[1]),
          })),
        };
      }
      if (part.t === 'inject') return { kind: 'context', label: part.detail };
      if (part.t === 'image') {
        return { kind: 'image', attachmentId: part.sha, name: part.name, mediaType: part.mediaType, data: part.data };
      }
      return { kind: part.t === 'think' ? 'think' : 'text', text: part.text };
    }),
  }));
  return { messages, model: meta?.model ?? null };
}

function clip(value, max) {
  const text = String(value ?? '').replace(/\r/g, '').trim();
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

function parseArgs(raw) {
  if (raw && typeof raw === 'object') return raw;
  try { return JSON.parse(String(raw ?? '{}')); } catch { return {}; }
}

function extractExit(text) {
  const m = /exitCode: (\d+)/.exec(text) || /\[exit code: (\d+)\]/.exec(text);
  return m ? Number(m[1]) : undefined;
}

function extractError(text) {
  const err = /stderr:\s*\{[\s\S]*?text: '([\s\S]*?)'/.exec(text);
  const source = err ? err[1] : text;
  const line = source.split('\n').map((l) => l.trim()).filter(Boolean)
    .find((l) => /error|Error|failed|not found|No module/.test(l)) ?? source.split('\n')[0];
  return clip((line ?? '').replace(/^' | '$/g, ''), 220);
}

function toolTitle(name, args) {
  if (name === 'run_code') return clip(args.description ?? 'Run code', 120);
  if (name === 'bash') return clip(args.description ?? args.command ?? 'Shell command', 120);
  if (name === 'read') return clip(args.file_path ?? args.path ?? 'Read file', 120);
  if (name === 'write' || name === 'edit') return clip(args.file_path ?? 'Write file', 120);
  if (name === 'web_search' || name === 'webfetch') return clip(args.query ?? args.url ?? name, 120);
  return clip(args.description ?? name, 120);
}

// Rebuilds the harness transcript: prose, reasoning, tool steps (with nested
// PTC sub-calls), context injections and the session's live model selection.
async function readTimeline(sessionId, maxMessages) {
  const page = await host.sessionController.events(
    { address: { kind: 'session', sessionId }, maxMessages },
    signal(),
  );
  const records = page.records.map((record) => record?.event ?? record).filter(Boolean);

  const messages = [];
  const tools = new Map(); // callId -> tool part
  let model = null;

  const push = (role, time, part) => {
    const last = messages.at(-1);
    if (last && last.role === role && last.time === time) last.parts.push(part);
    else messages.push({ role, time, parts: [part] });
  };

  for (const event of records) {
    const data = event.data ?? {};
    switch (event.type) {
      case 'user/message': {
        const message = data.message ?? data;
        if (message?.source && message.source.kind !== 'user') break;
        for (const block of message?.content ?? []) {
          if (block.type === 'text' && block.text?.trim()) {
            push('user', event.time, { kind: 'text', text: clip(block.text, 4000) });
          } else if (block.type === 'image') {
            const a = block.attachment ?? {};
            push('user', event.time, {
              kind: 'image',
              attachmentId: String(a.attachmentId ?? '').replace('sha256:', ''),
              name: a.name ?? 'image',
              mediaType: a.mediaType ?? 'image/png',
            });
          }
        }
        break;
      }
      case 'assistant/message': {
        for (const block of data.message?.content ?? []) {
          if (block.type === 'reasoning' && block.text?.trim()) {
            push('assistant', event.time, { kind: 'think', text: clip(block.text, 400) });
          } else if (block.type === 'text' && block.text?.trim()) {
            push('assistant', event.time, { kind: 'text', text: clip(block.text, 6000) });
          } else if (block.type === 'tool-call') {
            const args = parseArgs(block.arguments);
            const part = {
              kind: 'tool',
              callId: block.id,
              name: block.name,
              title: toolTitle(block.name, args),
              status: 'running',
              sub: [],
            };
            tools.set(block.id, part);
            push('assistant', event.time, part);
          }
        }
        break;
      }
      case 'tool/result': {
        const part = tools.get(data.message?.toolCallId);
        if (!part) break;
        const output = (data.message?.content ?? []).filter((b) => b.type === 'text').map((b) => b.text).join('\n');
        const exit = extractExit(output);
        part.status = data.isError ? 'error' : exit && exit !== 0 ? 'fail' : 'ok';
        if (exit !== undefined) part.exitCode = exit;
        if (part.status !== 'ok') part.error = clip(extractError(output) || output, 220);
        break;
      }
      case 'tool/ptc-dispatch': {
        const parent = tools.get(data.rootCallId);
        if (!parent) break;
        const output = (data.content ?? []).filter((b) => b.type === 'text').map((b) => b.text).join('\n');
        const exit = extractExit(output);
        const status = data.isError ? 'error' : exit && exit !== 0 ? 'fail' : 'ok';
        parent.sub.push({
          name: data.name,
          title: toolTitle(data.name, data.arguments ?? {}),
          status,
          exitCode: exit,
          error: status === 'ok' ? undefined : clip(extractError(output) || output, 220),
        });
        break;
      }
      case 'agent/inbox/spliced': {
        for (const inserted of data.inserted ?? []) {
          const kind = inserted?.source?.kind;
          if (!kind || kind === 'user') continue;
          push('assistant', event.time, { kind: 'context', label: kind });
        }
        break;
      }
      case 'model/selection':
        model = { provider: data.provider, model: data.model, reasoningEffort: data.reasoningEffort };
        break;
      default:
        break;
    }
  }

  const visible = messages.filter((m) => m.parts.length > 0);
  return { messages: visible, model };
}

function timelineText(messages) {
  const out = [];
  for (const message of messages) {
    for (const part of message.parts) if (part.kind === 'text') out.push(part.text);
  }
  return out;
}

let catalogLabels = null; // `${provider}/${model}` → display label
async function modelLabel(selection) {
  if (!selection) return null;
  const name = `${selection.provider}/${selection.model}`;
  if (catalogLabels === null) {
    try {
      const catalog = await host.sessionController.modelCatalog();
      catalogLabels = new Map();
      for (const group of catalog.groups) {
        for (const model of group.models) catalogLabels.set(`${group.id}/${model.id}`, model.name);
      }
    } catch { catalogLabels = new Map(); }
  }
  const label = catalogLabels.get(name) ?? name;
  const effort = selection.reasoningEffort ? ` ${selection.reasoningEffort.replace(/^\w/, (c) => c.toUpperCase())}` : '';
  return `${label}${effort}`;
}

async function listSessions() {
  const { items } = await host.sessionController.list({}, signal());
  const archived = new Set(host.workspaceRegistry?.archivedSessionIds ?? []);
  const pinned = new Set(host.workspaceRegistry?.pinnedSessionIds ?? []);
  const visible = items.filter((item) => !item.blank && item.origin !== 'subagent');
  const real = await Promise.all(visible.map(async (item) => {
    let title;
    try {
      title = (await host.sessionQuery.readTitle(item.sessionId, signal()))?.title;
    } catch { /* cold or unreadable title */ }
    let snippet = '';
    let model = null;
    try {
      const { messages, model: selection } = await readTimeline(item.sessionId, 12);
      const texts = timelineText(messages);
      snippet = (texts.at(-1) ?? '').replace(/\s+/g, ' ').slice(0, 90);
      model = await modelLabel(selection);
    } catch { /* snippet is best effort */ }
    return {
      id: item.sessionId,
      title: title ?? 'Untitled',
      snippet,
      updatedAt: item.updatedAt,
      running: item.running,
      model,
      archived: archived.has(item.sessionId),
      pinned: pinned.has(item.sessionId),
    };
  }));
  const listed = new Set(real.map((row) => row.id));
  const archivedExtras = [];
  for (const id of archived) {
    if (listed.has(id) || MOCK_SESSIONS.some((session) => session.id === id)) continue;
    let title = 'Untitled';
    let snippet = '';
    let model = null;
    let updatedAt = Date.now();
    try {
      title = (await host.sessionQuery.readTitle(id, signal()))?.title ?? title;
    } catch { /* cold or unreadable title */ }
    try {
      const { messages, model: selection } = await readTimeline(id, 12);
      const texts = timelineText(messages);
      snippet = (texts.at(-1) ?? '').replace(/\s+/g, ' ').slice(0, 90);
      if (messages.length) updatedAt = messages[messages.length - 1].time;
      model = await modelLabel(selection);
    } catch { /* snippet is best effort */ }
    archivedExtras.push({ id, title, snippet, updatedAt, running: false, model, archived: true, pinned: pinned.has(id) });
  }
  if (archivedExtras.length) real.push(...archivedExtras);
  const mocks = [];
  for (const meta of MOCK_SESSIONS) {
    const stored = mockSessionMessages(meta.id);
    if (!stored) continue;
    const texts = timelineText(stored.messages);
    mocks.push({
      id: meta.id,
      title: meta.title,
      snippet: (texts.at(-1) ?? '').replace(/\s+/g, ' ').slice(0, 90),
      updatedAt: meta.updatedAt,
      running: false,
      model: meta.model,
      archived: false,
      pinned: false,
    });
  }
  return { real, mocks };
}

async function promptSession(sessionId, text, ip, model) {
  if (!text?.trim()) throw new Error('empty prompt');
  let id = sessionId;
  if (!id || id === 'new' || id.startsWith('local-')) {
    const list = typeof host.workspaceRegistry?.list === 'function' ? host.workspaceRegistry.list() : [];
    const ws = list.length > 0
      ? list.reduce((a, b) => ((b.sessionIds?.length ?? 0) > (a.sessionIds?.length ?? 0) ? b : a), list[0])
      : undefined;
    const created = await host.sessionController.create(ws ? { workspaceId: ws.id } : {}, signal());
    id = created.sessionId;
    log(`new session ${id} created for prompt from ${ip}${ws ? ` in workspace ${ws.title ?? ws.id}` : ''}`);
  }
  if (model?.includes('/')) {
    const [provider, ...rest] = model.split('/');
    await host.sessionController.selectModel({ sessionId: id, provider, model: rest.join('/') }, signal());
    log(`session ${id.slice(0, 8)}… model → ${model}`);
  }
  const promptTime = Date.now();
  await host.sessionController.prompt({
    requestId: `mobile-${promptTime}`,
    sessionId: id,
    mode: 'queue',
    content: [{ type: 'text', text: text.trim() }],
  }, signal());
  log(`prompt from ${ip} → session ${id.slice(0, 8)}…`);

  const deadline = promptTime + 180_000;
  await new Promise((done) => setTimeout(done, 900));
  for (;;) {
    const { items } = await host.sessionController.list({}, signal());
    const item = items.find((entry) => entry.sessionId === id);
    const { messages, model } = await readTimeline(id, 6);
    const recent = messages.filter((m) => m.role === 'assistant' && m.time >= promptTime - 1000);
    const replyTexts = timelineText(recent.filter((m) => m.parts.some((p) => p.kind === 'text')));
    const reply = replyTexts.at(-1);
    if (item?.running === false && reply) return { sessionId: id, reply, model };
    if (Date.now() > deadline) {
      return { sessionId: id, reply: reply ?? '⚠︎ the model is still thinking — check this session in the desktop app.', model };
    }
    await new Promise((done) => setTimeout(done, 700));
  }
}

async function routeSessions(request, response, path, ip) {
  if (!host) return json(response, 503, { ok: false, error: 'session services not ready' });

  if (path === '/sessions') {
    trackDevice(ip);
    const { real, mocks } = await listSessions();
    real.sort((a, b) => b.updatedAt - a.updatedAt);
    return json(response, 200, { ok: true, sessions: [...mocks, ...real] });
  }

  const rawMatch = path.match(/^\/sessions\/([^/]+)\/raw$/);
  if (rawMatch) {
    const page = await host.sessionController.events(
      { address: { kind: 'session', sessionId: decodeURIComponent(rawMatch[1]) }, maxMessages: Number(new URL(request.url, 'http://b').searchParams.get('n') || 6) },
      signal(),
    );
    return json(response, 200, { ok: true, records: page.records });
  }

  const messagesMatch = path.match(/^\/sessions\/([^/]+)\/messages$/);
  if (messagesMatch) {
    trackDevice(ip);
    const id = decodeURIComponent(messagesMatch[1]);
    const mock = mockSessionMessages(id);
    if (mock) return json(response, 200, { ok: true, messages: mock.messages, model: mock.model });
    const { messages, model } = await readTimeline(id, 60);
    return json(response, 200, { ok: true, messages, model: await modelLabel(model) });
  }

  const promptMatch = path.match(/^\/sessions\/([^/]+)\/prompt$/);
  if (promptMatch && request.method === 'POST') {
    trackDevice(ip);
    const id = decodeURIComponent(promptMatch[1]);
    if (MOCK_SESSIONS.some((session) => session.id === id)) {
      return json(response, 200, {
        ok: true,
        sessionId: id,
        reply: 'This is a recorded demo transcript from the desktop harness — start a new chat to talk to a live model.',
      });
    }
    const body = await readBody(request);
    const result = await promptSession(id, body.text ?? '', ip, body.model);
    const label = (await modelLabel(result.model))
      ?? (result.model ? `${result.model.provider}/${result.model.model}` : null);
    return json(response, 200, { ok: true, ...result, model: label });
  }

  const modelMatch = path.match(/^\/sessions\/([^/]+)\/model$/);
  if (modelMatch && request.method === 'POST') {
    trackDevice(ip);
    const body = await readBody(request);
    if (MOCK_SESSIONS.some((session) => session.id === decodeURIComponent(modelMatch[1]))) {
      return json(response, 200, { ok: true, selected: String(body.name ?? '') });
    }
    const [provider, ...rest] = String(body.name ?? '').split('/');
    if (!provider || rest.length === 0) throw new Error(`bad model name: ${body.name}`);
    const value = await host.sessionController.selectModel(
      { sessionId: decodeURIComponent(modelMatch[1]), provider, model: rest.join('/') },
      signal(),
    );
    log(`session ${modelMatch[1].slice(0, 8)}… model → ${body.name}`);
    return json(response, 200, { ok: true, selected: `${value.selected.provider}/${value.selected.model}` });
  }
  const stateMatch = path.match(/^\/sessions\/([^/]+)\/(archive|unarchive|pin|unpin)$/);
  if (stateMatch && request.method === 'POST') {
    trackDevice(ip);
    const id = decodeURIComponent(stateMatch[1]);
    const action = stateMatch[2];
    if (MOCK_SESSIONS.some((session) => session.id === id)) {
      return json(response, 200, { ok: true, selected: action });
    }
    const registry = host.workspaceRegistry;
    if (!registry) return json(response, 503, { ok: false, error: 'workspace registry not ready' });
    try {
      if (action === 'archive') await registry.archiveSession(id, {});
      else if (action === 'unarchive') await registry.unarchiveSession(id);
      else if (action === 'pin') await registry.pinSession(id);
      else await registry.unpinSession(id);
    } catch (cause) {
      return json(response, 400, { ok: false, error: String(cause?.message ?? cause) });
    }
    log(`session ${id.slice(0, 8)}… ${action}`);
    return json(response, 200, { ok: true });
  }
  return null;
}

function readBody(request) {
  return new Promise((resolveBody, rejectBody) => {
    let raw = '';
    request.on('data', (chunk) => { raw += chunk; if (raw.length > 1_000_000) request.destroy(); });
    request.on('end', () => { try { resolveBody(JSON.parse(raw || '{}')); } catch (cause) { rejectBody(cause); } });
    request.on('error', rejectBody);
  });
}

async function routeCatalog(response, ip) {
  trackDevice(ip);
  if (!host) return json(response, 503, { ok: false, error: 'session services not ready' });
  const catalog = await host.sessionController.modelCatalog();
  const models = catalog.groups.flatMap((group) => group.models.map((model) => ({
    name: `${group.id}/${model.id}`,
    label: model.name,
    provider: group.id,
    providerLabel: group.name,
  })));
  const defaultName = `${catalog.default.provider}/${catalog.default.model}`;
  const ordered = [defaultName];
  for (const model of models) if (model.name !== defaultName) ordered.push(model.name);
  const seen = new Set();
  const byName = ordered.map((name) => models.find((model) => model.name === name)).filter((m) => m && !seen.has(m.name) && seen.add(m.name));
  return json(response, 200, { ok: true, default: defaultName, models: byName });
}

async function routeAttachment(response, request, ip) {
  trackDevice(ip);
  const sha = new URL(request.url, 'http://b').pathname.match(/^\/attachments\/([0-9a-f]{64})$/)?.[1];
  if (!sha) return json(response, 400, { ok: false, error: 'bad attachment id' });
  const file = join(os.homedir(), '.dsh/attachments/v1/objects', sha.slice(0, 2), sha);
  if (!existsSync(file)) return json(response, 404, { ok: false, error: 'attachment not found' });
  const buf = await readFile(file);
  const type = new URL(request.url, 'http://b').searchParams.get('type') || 'application/octet-stream';
  response.writeHead(200, { 'content-type': type, 'access-control-allow-origin': '*' });
  response.end(buf);
}

const server = http.createServer((request, response) => {
  if (request.method === 'OPTIONS') {
    response.writeHead(204, {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'content-type',
      'access-control-allow-methods': 'GET, POST, OPTIONS',
    });
    return response.end();
  }

  const ip = (request.socket.remoteAddress ?? 'unknown').replace('::ffff:', '');
  const path = new URL(request.url ?? '/', 'http://bridge').pathname;

  if (path === '/' || path === '/health') {
    trackDevice(ip);
    return json(response, 200, {
      ok: true,
      name: 'DSH Mobile Bridge',
      version: '0.1.0',
      endpoints: ['/health', '/devices', '/logs', '/models', '/sessions', '/sessions/:id/messages', '/sessions/:id/prompt', '/sessions/:id/model', '/sessions/:id/archive', '/sessions/:id/pin', '/attachments/:sha'],
    });
  }
  if (path === '/devices') {
    trackDevice(ip);
    return json(response, 200, { ok: true, devices: [...devices.entries()].map(([address, d]) => ({ address, ...d })) });
  }
  if (path === '/models') {
    routeCatalog(response, ip).catch((cause) => {
      log(`model catalog failed from ${ip}: ${String(cause?.message ?? cause)}`);
      json(response, 500, { ok: false, error: String(cause?.message ?? cause) });
    });
    return;
  }
  if (path === '/logs') {
    trackDevice(ip);
    return json(response, 200, { ok: true, logs: logLines.slice(-80) });
  }

  if (path.startsWith('/attachments/')) {
    routeAttachment(response, request, ip).catch((cause) => {
      log(`attachment failed from ${ip}: ${String(cause?.message ?? cause)}`);
      json(response, 500, { ok: false, error: String(cause?.message ?? cause) });
    });
    return;
  }

  if (path.startsWith('/sessions')) {
    routeSessions(request, response, path, ip).then((handled) => {
      if (handled === null) {
        log(`404 from ${ip} — GET ${path}`);
        json(response, 404, { ok: false, error: `unknown bridge path: ${path}` });
      }
    }).catch((cause) => {
      log(`request failed from ${ip}: ${String(cause?.message ?? cause)}`);
      json(response, 500, { ok: false, error: String(cause?.message ?? cause) });
    });
    return;
  }

  log(`404 from ${ip} — GET ${path}`);
  json(response, 404, { ok: false, error: `unknown bridge path: ${path}` });
});

server.on('error', (error) => {
  lastError = error.code === 'EADDRINUSE'
    ? `port ${PORT} is already in use (a dsh web serve or another bridge holds it)`
    : String(error.message ?? error);
  log(`server error: ${lastError}`);
});

server.on('close', () => log('bridge server closed'));

server.listen(PORT, '0.0.0.0', () => {
  lastError = null;
  log(`port ${PORT} open on all interfaces`);
  for (const address of lanAddresses()) log(`  reachable at http://${address}:${PORT}/health`);
  if (lanAddresses().length === 0) log('  no LAN address found — device connections will fail');
});

function status() {
  return {
    listening: server.listening,
    port: PORT,
    urls: lanAddresses().map((address) => `http://${address}:${PORT}`),
    lastError,
    devices: [...devices.entries()]
      .map(([address, info]) => ({ address, ...info }))
      .sort((a, b) => b.lastSeen.localeCompare(a.lastSeen)),
    logCount: logLines.length,
  };
}

export function apply(ctx) {
  host = {
    sessionController: ctx.get('sessionController'),
    sessionQuery: ctx.get('sessionQuery'),
    workspaceRegistry: ctx.get('workspaceRegistry'),
  };
  if (host.sessionController === undefined || host.sessionQuery === undefined) {
    log('session services missing — /sessions endpoints stay disabled');
    host = null;
  } else {
    log('session services attached — real conversations exposed over the bridge');
  }

  const handlers = {
    status: async () => status(),
    logs: async () => ({ lines: logLines.slice(-120) }),
  };

  const connection = ctx.get('connection');
  if (connection !== undefined) {
    for (const [name, handler] of Object.entries(handlers)) {
      ctx.effect(() => connection.fetch.register({
        path: `${CHANNEL}/${name}`,
        methods: ['POST', 'GET'],
        requestBody: 'buffered',
        fetch: async (request) => {
          let payload = {};
          try {
            payload = (await request.json()).args ?? {};
          } catch {
            payload = {};
          }
          try {
            const value = await handler(payload);
            return Response.json({ ok: true, value });
          } catch (cause) {
            return Response.json({ ok: false, error: String(cause?.message ?? cause) });
          }
        },
      }), `mobile-bridge: ${CHANNEL}/${name}`);
    }
  }

  return () => {
    server.close();
  };
}
