/* Drives the real ui/admin.js (the staff panel, /hitmanadmin) against a
 * scripted server, through the DOM shim, and asserts on what the page sends
 * and draws.
 *
 * The page is read from disk and run as shipped, inside the real skeleton
 * from ui/admin.html. Its markup is parsed by the shim (markup.js), so an
 * interpolated value that did not go through esc() turns up here as an
 * element, and the escaping tests fail on it.
 *
 * Every reply is put through acrossTheWire first: an empty Lua list
 * crosses as {}, and a page that reads one with .length or .forEach shows
 * nothing or throws on a real server. */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { makeDocument } = require('./dom.js');
const markup = require('./markup.js');

const ROOT = path.join(__dirname, '..', '..', 'ui');
const PAGE_JS = fs.readFileSync(path.join(ROOT, 'admin.js'), 'utf8');
const PAGE_HTML = fs.readFileSync(path.join(ROOT, 'admin.html'), 'utf8');

let passed = 0;
const failures = [];

function it(name, fn) {
  try {
    const returned = fn();
    if (returned && typeof returned.then === 'function') {
      throw new Error('this test body returned a promise; await outside it() and assert synchronously');
    }
    passed++;
  } catch (err) { failures.push(name + '\n    ' + err.message); }
}

function eq(actual, expected, message) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error((message || 'mismatch') + ': expected ' + e + ', got ' + a);
}
function truthy(v, m) { if (!v) throw new Error((m || 'expected truthy') + ', got ' + JSON.stringify(v)); }
function falsy(v, m) { if (v) throw new Error((m || 'expected falsy') + ', got ' + JSON.stringify(v)); }
function has(text, needle, m) {
  if (String(text).indexOf(needle) === -1) {
    throw new Error((m || 'missing text') + ': "' + needle + '" not in "' + String(text).slice(0, 400) + '"');
  }
}
function lacks(text, needle, m) {
  if (String(text).indexOf(needle) !== -1) throw new Error((m || 'unexpected text') + ': "' + needle + '"');
}

function acrossTheWire(value) {
  if (Array.isArray(value)) return value.length === 0 ? {} : value.map(acrossTheWire);
  if (value && typeof value === 'object') {
    const out = {};
    Object.keys(value).forEach(function (k) { out[k] = acrossTheWire(value[k]); });
    return out;
  }
  return value;
}

function settle() { return new Promise(function (resolve) { setImmediate(resolve); }); }
async function settled() { await settle(); await settle(); await settle(); }

/* ---------- fixtures, in the shapes server/panel.lua answers ---------- */

const XSS = '<img src=x onerror=alert(1)>';
const NOW = Math.floor(Date.now() / 1000);

/* The staff commands' names, as config.lua ships them: nothing the panel
   shows may name one (it is buttons only). Read from the file, so a command
   added there is checked here too. */
const CONFIG_LUA = fs.readFileSync(path.join(__dirname, '..', '..', 'config', 'config.lua'), 'utf8');
const COMMAND_NAMES = (function () {
  const block = /Commands\s*=\s*\{([\s\S]*?)\}/.exec(CONFIG_LUA);
  const out = [];
  const re = /=\s*'([^']+)'/g;
  let m;
  while (block && (m = re.exec(block[1])) !== null) out.push(m[1]);
  return out;
})();

/* What in the page names a command: '/ch-', '/hitmanadmin', or '/' and a
   command's name, in any text or attribute. */
function commandMentions(app) {
  const needles = ['/ch-', '/hitmanadmin'].concat(COMMAND_NAMES.map(function (n) { return '/' + n; }));
  const found = [];
  function check(text, where) {
    needles.forEach(function (needle) {
      if (String(text).indexOf(needle) !== -1) found.push(where + ': ' + String(text).slice(0, 160));
    });
  }
  check(app.body.textContent, 'text');
  (function walk(node) {
    Object.keys(node.attributes || {}).forEach(function (k) { check(node.attributes[k], k); });
    if (node.value) check(node.value, 'value');
    (node.children || []).forEach(walk);
  })(app.body);
  return found;
}

function access(extra) {
  return Object.assign({ canWrite: true, canIdentify: true, pageSize: 25, refreshSeconds: 10,
    recovery: 'ready', version: '1.1.0' }, extra || {});
}
const FULL = access();
const ADMIN = access({ canIdentify: false });
const READER = access({ canWrite: false, canIdentify: false });

function overview(extra) {
  return { ok: true, data: Object.assign({
    at: NOW,
    contracts: { total: 12, byState: { active: 3, accepted: 2, completed: 6, voided: 1 } },
    hitmen: { active: 4, operatives: 3, contracts: 2 },
    held: { cash: 15000, bank: 50000, dirty: 2000, items: 4, weapons: 1, lines: 9 },
    owed: { cash: 1200, bank: 0, dirty: 0, items: 0, weapons: 0, lines: 2, players: 1, queued: 1 },
    stuck: { total: 2, leftForStaff: 1, byWhy: { raised: 1, interrupted: 1 } },
    reviews: { open: 3 },
    photos: { waiting: { count: 1, bytes: 204800 }, kept: { count: 0, bytes: 0 },
              served: { count: 2, bytes: 409600 } },
    storage: 'json', fulfilment: 'alive', photoStorage: 'server', recovery: 'ready',
    slowest: [{ name: 'expiry', max: 7.2, avg: 1.1, last: 0.9, runs: 120 },
              { name: 'sampler', max: 0.4, avg: 0.2, last: 0.1, runs: 900 }],
    slowMs: 5,
    warnings: ['photo hosts: 0 -> add your upload host to Config.Completion.ExtraPhotoHosts'],
    overrides: 2, auditQueued: 0, alerts: { open: 4 }
  }, extra || {}) };
}

/* The alerts, as server/panel.lua's alerts op answers: newest first, the
   text already scrubbed for this staff member, and where Discord stands. */
function alertRow(i, extra) {
  return Object.assign({ id: 'al0000000' + i, level: i === 2 ? 'problem' : 'always',
    text: 'escrow line owe0000000' + i + ' was mid-release at shutdown; returned to held',
    contract: i === 1 ? 'ct00000001' : null, count: i === 1 ? 3 : 1,
    first_at: NOW - 3600 - i, last_at: NOW - 60 * i }, extra || {});
}
function alertsView(data) {
  const state = data && data.state === 'acknowledged' ? 'acknowledged' : 'open';
  const rows = state === 'open'
    ? [alertRow(1, { text: 'BOOT RECOVERY FAILED: ' + XSS + '\n  What the last shutdown left part-way' }),
       alertRow(2, { text: 'warning: Kidnap.Radius is 2' }), alertRow(3), alertRow(4)]
    : [alertRow(5, { acknowledged_by: 'ADMIN001', acknowledged_at: NOW - 30 })];
  return { ok: true, data: { state: state, rows: rows, open: 4, acknowledged: 1, limit: 100,
    discord: { on: true, webhook: 'alert', waiting: 0, posting: false, posted: 7, lastOkAt: NOW - 120 } } };
}

/* What the server keeps of its console, as server/panel.lua's console op
   answers: the settings that need attention, the start's lines with their
   kinds, and the newest lines since, oldest first, each with when it was
   last said and how many times. */
function consoleView(extra) {
  return { ok: true, data: Object.assign({
    at: NOW, debug: false, count: 2, bootLeft: 3, bootKept: 120, recentKept: 40, alwaysKept: 40,
    problems: ['warning: Kidnap.Radius is 2', 'warning: Limits.MaxAcceptedPerHitman is 0'],
    boot: [{ text: 'opening the store in json mode', kind: 'debug' },
           { text: 'BOOT RECOVERY FAILED: ' + XSS, kind: 'always' }],
    recent: [{ text: 'escrow line ct00000001:1 left for staff', kind: 'always', at: NOW - 600, times: 1 },
             { text: 'slow job expiry took 12 ms', kind: 'debug', at: NOW - 60, times: 4 }]
  }, extra || {}) };
}

function contractRow(i, extra) {
  return Object.assign({ id: 'ct0000000' + i, state: i === 1 ? 'accepted' : 'active', mode: 'competitive',
    rule: 'alive', created_at: NOW - i * 3600, deadline_at: NOW + 7200, target: 'Dana Reyes ' + i,
    client: 'Vic Marlowe', anonymous: false, slots: 2, claimed: 0 }, extra || {});
}

function contracts(extra) {
  return { ok: true, data: Object.assign({
    rows: [contractRow(1, { target: XSS }), contractRow(2, { client: 'Anonymous', anonymous: true }),
           contractRow(3)],
    page: 1, pages: 3, total: 61 }, extra || {}) };
}

function contractDetail(extra, identity) {
  return { ok: true, data: Object.assign({
    contract: { id: 'ct00000001', state: 'accepted', mode: 'exclusive', rule: 'alive', reason: XSS,
      created_at: NOW - 3600, deadline_at: NOW + 7200, expires_at: NOW + 86400,
      bailout_amount: 90000, penalty_amount: 2500, bonus_percent: 0, slots: 2, claimed: 1, next_slot: 2,
      buyout_queued: false, target_protected: true, anonymous: true,
      client: identity ? { name: 'Vic Marlowe', cid: 'CREATOR1' } : { name: 'Anonymous' },
      target: identity ? { name: 'Dana Reyes', cid: 'TARGET01' } : { name: 'Dana Reyes' } },
    escrow: [
      { id: 'ct00000001:1', contract: 'ct00000001', slot: 1, portion: 'baseline', source: 'cash', amount: 5000,
        quantity: null, state: 'settled', settled_to: 'operative Ghost', raised: 0, parked: false, owes: 0 },
      { id: 'ct00000001:2', contract: 'ct00000001', slot: 2, portion: 'baseline', source: 'bank', amount: 8000,
        state: 'held', raised: 1, arrived: 2000, parked: true, owes: 6000, owed_to: 'operative Ghost' },
      { id: 'ct00000001:3', contract: 'ct00000001', slot: 2, portion: 'bonus', source: 'item', item: 'lockpick',
        quantity: 3, state: 'held', raised: 0, parked: false, owes: 3 }
    ],
    hitmen: [{ id: 'hm1', alias: 'Ghost', anonymous: true, name: identity ? 'Kai Holt' : 'Anonymous',
      cid: identity ? 'HITMAN01' : undefined, state: 'active', accepted_at: NOW - 1800, claims: 1,
      stake: 2500, last_claim_at: NOW - 600 }],
    amendments: [{ id: 'am1', kind: 'extend_deadline', proposer: 'the client', outcome: null,
      expires_at: NOW + 600, payload: { seconds: 3600 } }],
    timeline: [
      { ts: NOW - 3600, kind: 'financial', action: 'escrow_taken', contract: 'ct00000001', actor: 'the client',
        detail: { amount: 13000, note: XSS } },
      { ts: NOW - 600, kind: 'financial', action: 'escrow_deliver_parked', contract: 'ct00000001',
        actor: 'operative Ghost', detail: { line: 'ct00000001:2', unknown: true } }
    ],
    stuck: [
      { line: 'ct00000001:2', contract: 'ct00000001', amount: 8000, source: 'bank', portion: 'baseline',
        intended: 'operative Ghost', why: 'unknown', raised: 1, arrived: 2000, at: NOW - 600,
        actions: ['pay', 'pay_amount', 'return', 'delivered'] },
      { line: 'ct00000001:9', contract: 'ct00000001', amount: 300, source: 'cash', portion: 'owed',
        intended: 'a citizen id no character has', why: 'owed_to_nobody', actions: ['return_owner'] },
      { line: 'ct00000001:8', contract: 'ct00000001', amount: 100, source: 'cash', portion: 'stake',
        why: 'ending_unfinished', unfinished: true, actions: [] }
    ],
    canVoid: true
  }, extra || {}) };
}

/* Every escrow line waiting for staff, as server/panel.lua's stuck op
   answers: the stuck listing's entries, each with what settles it. */
function stuckList(extra) {
  return { ok: true, data: Object.assign({ recovery: 'ready', reviews: 2, lines: [
    { line: 'ct00000001:2', contract: 'ct00000001', amount: 8000, source: 'bank', portion: 'baseline',
      intended: 'operative Ghost', why: 'unknown', raised: 1, arrived: 2000, at: NOW - 600,
      actions: ['pay', 'pay_amount', 'return', 'delivered'] },
    { line: 'owe00000003', contract: 'ct00000004', amount: 900, source: 'cash', portion: 'owed',
      intended: XSS, why: 'unqueued', raised: 0, actions: ['pay'] },
    { line: 'ct00000005:1', contract: 'ct00000005', amount: 900, source: 'cash', portion: 'baseline',
      intended: 'operative Ghost', why: 'interrupted', raised: 3, actions: ['pay', 'pay_amount', 'return', 'delivered'] },
    { line: 'ct00000006:1', contract: 'ct00000006', amount: 500, source: 'cash', portion: 'baseline',
      intended: '(nobody)', why: 'never_given_release', raised: 0, actions: ['return'] },
    { line: 'ct00000009:1', contract: 'ct00000009', amount: 300, source: 'cash', portion: 'baseline',
      orphan: true, actions: ['return_owner'] },
    { line: 'ct00000008:1', contract: 'ct00000008', amount: 100, source: 'cash', portion: 'stake',
      why: 'ending_unfinished', unfinished: true, actions: [] }
  ] }, extra || {}) };
}

function reviews() {
  return { ok: true, data: { items: [
    { id: 'rv00000001', kind: 'bailout_unrecorded', about: 'a buyout was charged, and ' + XSS,
      contract: 'ct00000001', parties: [{ role: 'payer', who: 'the target' }, { role: 'creator', who: 'the client' }],
      amount: 90000, account: 'bank', items: [], known: { error: 'store timeout', at: NOW },
      now: { contract: 'accepted', buyout: 'none' }, state: 'open', created_at: NOW - 900 },
    { id: 'rv00000002', kind: 'escrow_take_raised', about: 'taking a line of escrow raised',
      contract: 'ct00000002', parties: [{ role: 'from', who: 'the client' }],
      items: [{ id: 'ct00000002:4', source: 'item', item: 'lockpick', quantity: 2 }], known: {},
      now: { contract: 'active', lines: { held: 0, settled: 0, missing: 1 } }, state: 'open',
      created_at: NOW - 800 }
  ] } };
}

function logs(extra) {
  return { ok: true, data: Object.assign({ rows: [
    { ts: NOW - 60, kind: 'financial', action: 'admin_void', contract: 'ct00000003', actor: '(a player)',
      detail: { reason: XSS, lines: 2 } },
    { ts: NOW - 120, kind: 'rejected', action: 'rate_limited', actor: 'the client', detail: {} }
  ], next: 4242 }, extra || {}) };
}

function player() {
  return { ok: true, data: {
    player: { cid: 'TARGET01', name: 'Dana Reyes', online: true, server: 12 },
    contracts: [{ id: 'ct00000001', state: 'accepted', role: 'target', anonymous: false, target: 'Dana Reyes',
                  created_at: NOW - 3600, resolution: null }],
    stats: { completed: 4, failed: 1, placed: 2, survived: 3, rate: 80, standing: 'Unproven' },
    owed: [{ id: 'ct00000005:2', contract: 'ct00000005', source: 'cash', amount: 700, state: 'held',
             owes: 700, queued: true, parked: false }],
    pending: 1,
    notices: { count: 2, titles: ['Contract closed', XSS] }
  } };
}

function settingsView(extra) {
  return { ok: true, data: Object.assign({
    features: [
      { key: 'Sources.cash.enabled', group: 'Rewards', label: 'Cash rewards', about: 'Cash may be put up.',
        kind: 'switch', live: true, inflight: 'Things already under way finish under the rules they started with.',
        value: true, default: true, source: 'config' },
      { key: 'Bailout.Enabled', group: 'Buyouts', label: 'Buyouts', about: 'A target may pay.', kind: 'switch',
        live: true, inflight: 'A buyout already paid still closes the contract.', value: false, default: true,
        source: 'panel', by: 'ADMIN001', at: NOW - 300 },
      { key: 'App.DefaultInstalled', group: 'The app', label: 'Put the app on every home screen', kind: 'switch',
        live: false, inflight: 'Applies after restart.', value: false, default: false, source: 'config' },
      { key: 'Completion.Fulfilment', group: 'Completion', label: 'How contracts are completed', kind: 'choice',
        choices: ['alive', 'either'], live: true, inflight: 'Each contract keeps its rule.', value: 'alive',
        default: 'alive', source: 'config' },
      { key: 'Relay.Enabled', group: 'Messages and calls', label: 'Messages ' + XSS, kind: 'switch', live: true,
        value: true, default: true, source: 'config', ignored: 'has to be on or off' },
      { key: 'Completion.KillPhotos', group: 'Completion', label: 'Kill photos', kind: 'switch', live: true,
        inflight: 'Read at the next Verify kill, with no restart.', value: false, default: false,
        source: 'config' },
      { key: 'Completion.PhotoStorage', group: 'Completion', label: 'Where kill photos are kept',
        kind: 'choice', choices: ['server', 'host'], live: true, value: 'server', default: 'server',
        source: 'config', inflight: 'Photos already kept stay where they are.',
        inactive: 'Does not apply while kill photos are off (Completion.KillPhotos).' }
    ],
    limits: [
      { key: 'Limits.MaxAcceptedPerHitman', group: 'Contract limits', label: 'Contracts a hitman may hold',
        kind: 'number', integer: true, min: 1, max: 50, live: true, inflight: 'Lowering it never cancels anything.',
        value: 3, default: 3, source: 'config' },
      { key: 'Penalty.MaxFractionOfEscrow', group: 'Stakes', label: 'Largest stake, as a share', kind: 'number',
        min: 0, max: 10, live: true, value: 0.5, default: 0.5, source: 'config' },
      { key: 'Advisory.RecipientJobNames', group: 'Advisory job lists', label: 'Job names that receive advisories',
        kind: 'list', live: true, value: ['police'], default: [], source: 'panel', by: 'ADMIN001', at: NOW - 60 }
    ],
    readonly: [
      { key: 'Admin.Enabled', group: 'Staff', label: 'Staff tools', kind: 'switch', live: true,
        readonly: 'Turning the staff tools off from the staff tools would lock you out.', value: true,
        default: true, source: 'config' },
      { key: 'Cooldowns.admin.burst', group: 'Staff', label: 'admin: requests held', kind: 'number',
        integer: true, min: 1, max: 200, live: true, value: 30, default: 30, source: 'config',
        readonly: 'The staff panel\'s own allowance, which every request it makes spends.',
        ignored: 'The staff panel\'s own allowance, which every request it makes spends.' }
    ],
    overrides: 2
  }, extra || {}) };
}

function standardServer(extra) {
  return Object.assign({
    overview: overview(), contracts: contracts(), contract: contractDetail(null, false), reviews: reviews(),
    stuck: stuckList(), alerts: alertsView, console: consoleView(),
    removePhotos: { ok: true, message: 'Removed 3 kill photo(s). 1 file(s) deleted from this server. 2 were on '
      + 'lb-phone\'s image host: this server has forgotten them, and the pictures stay on the host.',
      data: { removed: 3, files: 1, links: 2, left: 0, waiting: 0 } },
    ackAlerts: function (data) {
      return { ok: true, message: 'Acknowledged ' + (data.ids || []).length + ' alert(s).',
        data: { done: (data.ids || []).length, already: 0, missing: 0 } };
    },
    testAlert: { ok: true, message: 'A test alert goes to Discord in about 0 second(s). This section says whether it went through.',
      data: { seconds: 0 } },
    logs: logs(), player: player(), settings: settingsView(),
    whois: { ok: true, data: { creator: { cid: 'CREATOR1', name: 'Vic Marlowe', anonymous: true },
      target: { cid: 'TARGET01', name: 'Dana Reyes' },
      hitmen: [{ alias: 'Ghost', cid: 'HITMAN01', name: 'Kai Holt', anonymous: true, state: 'active' }] } },
    void: { ok: true, message: 'Contract ct00000001 voided: its escrow is back with the client.' },
    settle: { ok: true, message: 'Settled ct00000001:2: paid 2000 to operative Ghost.', data: { detail: {} } },
    resolve: { ok: true, message: 'Review rv00000001 resolved: refunded $500 to the payer.', data: { detail: {} } },
    setSetting: function (data) {
      return { ok: true, message: data.key + ' is now ' + JSON.stringify(data.value) + '.',
        data: { key: data.key, value: data.value, old: null, source: 'panel' } };
    },
    resetSetting: function (data) {
      return { ok: true, message: data.key + ' is back to what config.lua says.', data: { key: data.key } };
    },
    resetSettings: { ok: true, message: 'Every setting is back to what config.lua says (2 were changed).',
      data: { keys: 2 } },
    refresh: { ok: true, message: 'Timers brought forward.', data: { lines: ['3 contract deadline(s) checked', 'cooldowns cleared'] } },
    diag: { ok: true, data: { lines: ['--- crimson-hitman diagnosis', 'storage: json', 'photo hosts: 0 -> add one'] } },
    flush: { ok: true, message: 'Audit log flushed: 4 row(s) written.', data: { written: 4 } }
  }, extra || {});
}

/* ---------- the page, booted ---------- */

function bodyOf(html) {
  const inner = /<body[^>]*>([\s\S]*)<\/body>/i.exec(html)[1];
  return inner.replace(/<script[\s\S]*?<\/script>/gi, '');
}

function boot(server) {
  const document = markup.install(makeDocument());
  document.body.innerHTML = bodyOf(PAGE_HTML);
  const sent = [];
  const urls = [];
  const timers = [];
  let timerSeq = 0;
  const thrown = [];

  const windowListeners = {};
  const window = {
    location: { hostname: 'cfx-nui-somewhere-else' },
    addEventListener: function (type, fn) { (windowListeners[type] = windowListeners[type] || []).push(fn); }
  };

  const sandbox = {
    document: document,
    window: window,
    // FiveM's NUI page has it, and the page is to post to whatever it says.
    GetParentResourceName: function () { return 'crimson-hitman-renamed'; },
    fetch: function (url, options) {
      urls.push(url);
      const event = url.split('/').pop();
      const body = JSON.parse(options.body);
      if (sent.length > 400) throw new Error('runaway request loop: ' + sent.length + ' requests');
      sent.push({ event: event, op: body.op, data: body.data, body: body });
      if (server.__fetchFails && server.__fetchFails(body)) return Promise.reject(new Error('no route'));
      let answer;
      if (event === 'adminClose') answer = { ok: true };
      else if (event === 'adminRequest') {
        answer = server[body.op];
        if (typeof answer === 'function') answer = answer(body.data || {});
        if (answer === undefined) answer = { ok: false, err: 'unknown_op' };
      }
      const arriving = (answer && typeof answer.then === 'function') ? answer : Promise.resolve(answer);
      return Promise.resolve({
        json: function () {
          return arriving.then(function (r) {
            if (r === '__not_json') throw new SyntaxError('Unexpected token');
            return acrossTheWire(r);
          });
        }
      });
    },
    setTimeout: function (fn, ms) { timers.push({ fn: fn, ms: ms || 0, id: ++timerSeq }); return timerSeq; },
    clearTimeout: function (id) { timers.forEach(function (t) { if (t.id === id) t.cleared = true; }); },
    setInterval: function () { throw new Error('the page polls with one setTimeout chain, never setInterval'); },
    clearInterval: function () {},
    Promise: Promise, console: console
  };
  vm.createContext(sandbox);
  vm.runInContext(PAGE_JS, sandbox, { filename: 'admin.js' });

  const app = {
    document, sent, urls, timers, thrown, server,
    body: document.body,
    $: function (selector) { return document.body.querySelector(selector); },
    $$: function (selector) { return document.body.querySelectorAll(selector); },
    byId: function (id) { return document.getElementById(id); },
    message: function (data) {
      (windowListeners.message || []).forEach(function (fn) {
        try { fn({ data: data }); } catch (err) { thrown.push(err); }
      });
    },
    open: function (a) { app.message({ type: 'open', access: a || FULL }); },
    requests: function (op) { return sent.filter(function (s) { return s.op === op; }); },
    last: function (op) { const list = app.requests(op); return list[list.length - 1]; },
    click: function (node) {
      if (!node) throw new Error('nothing to click');
      try { markup.dispatch(node, 'click'); } catch (err) { thrown.push(err); throw err; }
      return node;
    },
    type: function (node, text) {
      if (!node) throw new Error('nothing to type into');
      node.value = text;
      markup.dispatch(node, 'input');
      return node;
    },
    key: function (node, key) { markup.dispatch(node || document.body, 'keydown', { key: key }); },
    keyUp: function (node, key) { markup.dispatch(node || document.body, 'keyup', { key: key }); },
    /** Fire every live timer of this length, as that much time passing would. */
    fire: function (ms) {
      const due = timers.filter(function (t) { return !t.cleared && !t.fired && t.ms === ms; });
      due.forEach(function (t) {
        t.fired = true;
        try { t.fn(); } catch (err) { thrown.push(err); }
      });
      return due.length;
    },
    live: function (ms) { return timers.filter(function (t) { return !t.cleared && !t.fired && t.ms === ms; }).length; },
    visible: function (node) {
      let n = node;
      while (n) { if (n.hidden === true) return false; n = n.parentNode; }
      return true;
    },
    /** A button (or a drawn control) by what it says, among those on screen. */
    button: function (label, within) {
      const root = within || document.body;
      const all = root.querySelectorAll('button').filter(app.visible);
      const match = all.filter(function (b) {
        const lbl = b.querySelector('.lbl');
        return (lbl ? lbl.textContent : b.textContent).trim() === label;
      });
      if (!match.length) {
        throw new Error('no button "' + label + '" on screen: ' + all.map(function (b) {
          const lbl = b.querySelector('.lbl');
          return (lbl ? lbl.textContent : b.textContent).trim();
        }).filter(Boolean).join(' | '));
      }
      return match[0];
    },
    text: function (node) { return (node || document.body).textContent; },
    main: function () { return document.getElementById('main').textContent; },
    drawer: function () { return document.getElementById('drawer'); },
    toasts: function () { return document.getElementById('toasts').textContent; },
    nav: function (section) { app.click(document.getElementById('nav-' + section)); }
  };
  return app;
}

/** Pick an option in one of the page's own dropdowns. */
function pick(app, name, value) {
  const wrap = app.byId('dd-' + name);
  if (!wrap) throw new Error('no dropdown ' + name);
  app.click(wrap.querySelector('.dd-btn'));
  const menu = app.byId('dd-' + name).querySelector('.dd-menu');
  if (menu.hidden) throw new Error('the dropdown ' + name + ' did not open');
  const option = menu.querySelectorAll('.dd-opt').filter(function (o) { return o.getAttribute('data-value') === value; })[0];
  if (!option) throw new Error('no option ' + value + ' in ' + name);
  app.click(option);
}

/** Where player text became markup: an element the escaped text would
 *  have been, had esc() been skipped. Recorded, not thrown, so each place
 *  is named in the one test that asserts on them. */
function markupFrom(app, where, found) {
  const planted = app.body.querySelectorAll('img').concat(app.body.querySelectorAll('script'));
  if (planted.length) found.push(where + ' (' + planted.length + ' element(s))');
}

function clean(app, where) {
  if (app.thrown.length) {
    throw new Error((where || 'the page') + ' threw: ' + app.thrown.map(function (e) { return e.message; }).join(' | '));
  }
}

/* ---------- the tests ---------- */

async function main() {

  /* ---- page and lifecycle ---- */
  await (async function () {
    const app = boot(standardServer());
    await settled();
    it('stays hidden, and asks nothing, until the client opens it', function () {
      eq(app.byId('panel').hidden, true);
      eq(app.sent.length, 0);
    });

    app.open(FULL);
    await settled();
    it('opens on the client\'s word and reads the overview first', function () {
      eq(app.byId('panel').hidden, false);
      eq(app.sent[0].op, 'overview');
      has(app.main(), 'Contracts');
      has(app.main(), '12');
      has(app.main(), 'Active 3');
      has(app.main(), '$15,000');
      has(app.main(), '$50,000');
      has(app.main(), 'Waiting for staff');
      has(app.main(), 'left for you to settle, of 2 listed', 'what staff settle, not every line listed');
      has(app.main(), '1 need nothing from you', 'and the rest said apart');
      has(app.main(), 'Operatives3on contracts now, holding 2 contracts', 'operatives, and the contracts they hold');
      has(app.main(), 'Alive only', 'the rule new contracts are placed under');
      has(app.main(), 'expiry', 'the slowest job');
      has(app.main(), '7.20 ms');
      has(app.main(), 'photo hosts: 0', 'the diagnosis warnings');
      has(app.main(), '400.0 KB', 'served photos, with their size');
      has(app.main(), 'On, kept on server', 'where kill photos are kept, while they are on');
    });
    it('posts to its own resource, as GetParentResourceName names it', function () {
      truthy(app.urls[0].indexOf('https://crimson-hitman-renamed/adminRequest') === 0, app.urls[0]);
    });
    it('counts open review items and the lines left for staff on the navigation', function () {
      eq(app.byId('count-reviews').textContent, '3');
      eq(app.byId('count-reviews').hidden, false);
      eq(app.byId('count-stuck').textContent, '1', 'beside Stuck escrow: left for staff, not every line listed');
      eq(app.byId('count-overview'), null, 'and not beside the overview');
      eq(app.byId('count-settings').textContent, '2');
    });
    it('marks what this staff member may do', function () {
      has(app.text(app.byId('badges')), 'Can change');
      has(app.text(app.byId('badges')), 'Sees identities');
      has(app.byId('version').textContent, 'v1.1.0');
    });

    it('refreshes the overview every refreshSeconds while open, on one timer', function () {
      eq(app.live(10000), 1, 'one refresh timer');
    });
    const before = app.requests('overview').length;
    app.fire(10000);
    await settled();
    it('and asks for it again when that timer fires, then sets the next', function () {
      eq(app.requests('overview').length, before + 1);
      eq(app.live(10000), 1, 'still one timer');
    });
    app.open(FULL);
    await settled();
    it('a second open (the server said open again) starts no second timer', function () {
      eq(app.live(10000), 1);
    });
    // And not while the refresh is in flight, when no timer is set at all.
    // (The client answers every request, with `timeout` at the latest, so
    // each one held here is answered in the end.)
    const held = [];
    app.server.overview = function () { return new Promise(function (resolve) { held.push(resolve); }); };
    app.fire(10000);
    await settled();
    app.open(FULL);
    await settled();
    held.forEach(function (resolve) { resolve(overview()); });
    await settled();
    app.server.overview = overview();
    it('nor one opened while the refresh was waiting on the server', function () {
      eq(app.live(10000), 1);
    });

    app.key(app.body, 'Escape');
    await settled();
    it('Escape pressed does not close it yet: the game would get the rest of the keystroke', function () {
      eq(app.byId('panel').hidden, false);
      falsy(app.sent.some(function (s) { return s.event === 'adminClose'; }), 'nothing posted');
    });
    app.keyUp(app.body, 'Escape');
    await settled();
    it('Escape closes it on release: tells the client, stops the refresh, draws nothing', function () {
      eq(app.byId('panel').hidden, true);
      truthy(app.sent.some(function (s) { return s.event === 'adminClose'; }), 'adminClose posted');
      eq(app.live(10000), 0, 'no refresh after close');
      eq(app.main(), '');
    });
    const afterClose = app.sent.length;
    app.fire(10000);
    await settled();
    it('and nothing it scheduled asks anything once closed', function () {
      eq(app.sent.length, afterClose);
    });
    clean(app, 'lifecycle');
  })();

  await (async function () {
    const app = boot(standardServer());
    app.open(FULL);
    await settled();
    app.click(app.byId('close'));
    await settled();
    it('the close button closes it the same way', function () {
      eq(app.byId('panel').hidden, true);
      eq(app.sent[app.sent.length - 1].event, 'adminClose');
    });
  })();

  await (async function () {
    let release;
    const server = standardServer({
      contracts: function () { return new Promise(function (resolve) { release = resolve; }); }
    });
    const app = boot(server);
    app.open(FULL);
    await settled();
    app.nav('contracts');
    await settled();
    app.message({ type: 'close' });
    release(contracts());
    await settled();
    it('closed from the game, it hides, and an answer arriving after is dropped', function () {
      eq(app.byId('panel').hidden, true);
      eq(app.main(), '');
      clean(app, 'a late answer');
    });
    it('and does not post adminClose back for a close the client sent', function () {
      falsy(app.sent.some(function (s) { return s.event === 'adminClose'; }));
    });
  })();

  await (async function () {
    const app = boot(standardServer({
      overview: { ok: false, err: 'not_allowed', message: 'Not authorised: add_ace group.admin crimson.admin allow' }
    }));
    app.open(FULL);
    await settled();
    it('a read refused as not_allowed (the ACE taken away) closes the panel and says why', function () {
      eq(app.byId('panel').hidden, true);
      truthy(app.sent.some(function (s) { return s.event === 'adminClose'; }), 'the client is told, to release the focus');
      has(app.toasts(), 'Not authorised: add_ace');
    });
    app.message({ type: 'close' });
    it('and keeps saying it when the client\'s own close comes back', function () {
      has(app.toasts(), 'Not authorised: add_ace');
    });
  })();

  await (async function () {
    const app = boot(standardServer({ __fetchFails: function (body) { return body.op === 'overview'; } }));
    app.open(FULL);
    await settled();
    it('nui() answers null on a failed fetch, and the page says so rather than throwing', function () {
      has(app.toasts(), 'did not answer');
      clean(app, 'a failed fetch');
      eq(app.byId('panel').hidden, false);
    });
  })();

  await (async function () {
    const app = boot(standardServer({ overview: '__not_json' }));
    app.open(FULL);
    await settled();
    it('and on an answer that is not JSON', function () {
      has(app.toasts(), 'did not answer');
      clean(app, 'a broken answer');
    });
  })();

  await (async function () {
    const app = boot(standardServer({ overview: overview({ slowest: [], warnings: [], stuck: undefined,
      photos: undefined, recovery: 'recovering', contracts: { total: 0, byState: {} },
      killPhotos: false }) }));
    app.open(access({ recovery: 'recovering' }));
    await settled();
    it('reads empty lists sent as {} and a recovering server without throwing', function () {
      clean(app, 'empty overview');
      has(app.main(), 'Kill photosOff', 'kill photos switched off, said as that');
      has(app.main(), 'Not listed while the server is recovering');
      has(app.main(), 'No job has run yet');
      has(app.main(), 'Nothing that wants doing');
    });
    it('says recovery holds writes back, in a banner', function () {
      eq(app.byId('banner').hidden, false);
      has(app.text(app.byId('banner')), 'Still recovering from the restart');
    });
    app.nav('tools');
    await settled();
    it('while recovering, writes are disabled with why, and flushing the log is not', function () {
      eq(app.button('Bring timers forward').disabled, true);
      has(app.button('Bring timers forward').getAttribute('title'), 'Still recovering');
      falsy(app.button('Flush the audit log').disabled);
    });
  })();

  /* ---- access and identity ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(READER);
    await settled();
    it('read-only staff are told so', function () {
      has(app.text(app.byId('badges')), 'Read only');
      has(app.text(app.byId('badges')), 'Identities hidden');
    });
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('read-only staff: void and every settle are disabled, saying why', function () {
      const drawer = app.drawer();
      eq(app.button('Void contract', drawer).disabled, true);
      has(app.button('Void contract', drawer).getAttribute('title'), 'Read only');
      ['Pay', 'Pay amount', 'Return', 'Delivered', 'Return to'].forEach(function (label) {
        eq(app.button(label, drawer).disabled, true, label);
      });
    });
    app.nav('settings');
    await settled();
    it('and every setting', function () {
      app.$$('.switch').forEach(function (s) { eq(s.disabled, true, 'switch ' + s.getAttribute('data-key')); });
      app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-act') === 'st-choice'; })
        .forEach(function (b) { eq(b.disabled, true); });
    });
    app.nav('reviews');
    await settled();
    it('and the review queue offers no resolution', function () {
      eq(app.$$('.rv-form').length, 0);
    });
    app.nav('tools');
    await settled();
    it('and the tools that write', function () {
      eq(app.button('Bring timers forward').disabled, true);
      eq(app.button('Flush the audit log').disabled, true);
    });
    clean(app, 'read only');
  })();

  await (async function () {
    // As the server answers staff without crimson.identity who looked a
    // player up by their server id: no cid.
    const unnamed = player();
    delete unnamed.data.player.cid;
    const app = boot(standardServer({ player: unnamed }));
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('without identity: Anonymous, no citizen id, and no whois', function () {
      const drawer = app.drawer();
      has(app.text(drawer), 'Anonymous');
      eq(drawer.querySelectorAll('.cid').length, 0);
      falsy(app.text(drawer).indexOf('Citizen id') !== -1, 'no citizen id column');
      eq(drawer.querySelectorAll('button').filter(function (b) { return b.getAttribute('data-act') === 'whois'; }).length, 0);
      eq(app.requests('whois').length, 0);
    });
    app.nav('logs');
    await settled();
    it('without identity the log\'s citizen id filter is disabled and never sent', function () {
      const input = app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'lg.actor'; })[0];
      eq(input.disabled, true);
      app.type(input, 'ABC12345');
      app.fire(350);
    });
    await settled();
    it('(and typing into it anyway sends nothing that names a player)', function () {
      app.requests('logs').forEach(function (r) { eq(r.data.actor, undefined); });
    });
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('without identity the player view offers no whois', function () {
      eq(app.$$('button').filter(function (b) { return b.getAttribute('data-act') === 'whois'; }).length, 0);
      has(app.main(), 'citizen id hidden', 'a player whose cid did not come is said so');
    });
    clean(app, 'no identity');
  })();

  await (async function () {
    const app = boot(standardServer({ contract: contractDetail(null, true) }));
    app.open(FULL);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('with identity: the citizen ids the server sent are shown', function () {
      has(app.text(app.drawer()), 'CREATOR1');
      has(app.text(app.drawer()), 'HITMAN01');
    });
    app.click(app.button('Whois', app.drawer()));
    await settled();
    it('and whois answers in the drawer', function () {
      eq(app.last('whois').data, { id: 'ct00000001' });
      has(app.text(app.drawer()), 'Who is behind it');
      has(app.text(app.drawer()), 'Kai Holt');
    });
    clean(app, 'identity');
  })();

  /* ---- escaping ---- */
  await (async function () {
    const app = boot(standardServer({
      contract: contractDetail(null, true),
      contracts: contracts(),
      flush: { ok: true, message: 'Flushed ' + XSS }
    }));
    const found = [];
    app.open(FULL);
    await settled();
    const visits = ['contracts', 'reviews', 'logs', 'settings'];
    for (const section of visits) {
      app.nav(section);
      await settled();
      markupFrom(app, section, found);
    }
    app.nav('logs');
    await settled();
    app.click(app.$('tr.row'));
    markupFrom(app, 'a log row\'s whole detail', found);
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    markupFrom(app, 'the contract drawer', found);
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), 'TARGET01');
    app.click(app.button('Look up'));
    await settled();
    markupFrom(app, 'players', found);
    app.nav('tools');
    await settled();
    app.click(app.button('Flush the audit log'));
    await settled();
    markupFrom(app, 'the toasts', found);
    it('player-written text is shown as text everywhere, never as markup', function () {
      eq(found, [], 'player text became markup in');
      has(app.toasts(), 'Flushed ' + XSS, 'a toast shows the words as they are');
    });
    app.nav('contracts');
    await settled();
    it('a name that looks like markup reads as itself', function () {
      has(app.main(), XSS);
    });
    clean(app, 'escaping');
  })();

  /* ---- contracts ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(FULL);
    await settled();
    app.nav('contracts');
    await settled();
    it('lists contracts newest first, with a page count', function () {
      eq(app.last('contracts').data, { page: 1 });
      has(app.main(), 'ct00000001');
      has(app.main(), 'Page 1 of 3 · 61 contracts');
      has(app.main(), 'Anonymous');
    });
    it('never draws a native select', function () {
      eq(app.$$('select').length, 0);
    });
    const asked = app.requests('contracts').length;
    const search = app.byId('ct-q');
    app.type(search, 'D');
    app.type(search, 'Da');
    app.type(search, 'Dan');
    await settled();
    it('search waits for typing to stop', function () {
      eq(app.requests('contracts').length, asked, 'nothing asked mid-word');
    });
    app.fire(250);
    await settled();
    it('then asks once, for what was typed, from the first page', function () {
      eq(app.requests('contracts').length, asked + 1);
      eq(app.last('contracts').data, { page: 1, query: 'Dan' });
    });
    app.key(search, 'Enter');
    await settled();
    it('and Enter asks at once', function () {
      eq(app.requests('contracts').length, asked + 2);
    });

    pick(app, 'ct-state', 'accepted');
    await settled();
    it('filters by state through the page\'s own dropdown', function () {
      eq(app.last('contracts').data.state, 'accepted');
      eq(app.byId('dd-ct-state').querySelector('.dd-menu').hidden, true, 'and the menu closes');
      has(app.text(app.byId('dd-ct-state')), 'Accepted');
    });
    pick(app, 'ct-rule', 'either');
    await settled();
    it('and by rule', function () {
      eq(app.last('contracts').data.rule, 'either');
      eq(app.last('contracts').data.state, 'accepted');
    });
    pick(app, 'ct-range', '7d');
    await settled();
    it('and by a date range', function () {
      const from = app.last('contracts').data.from;
      truthy(Math.abs(from - (Math.floor(Date.now() / 1000) - 7 * 86400)) < 5, 'from ' + from);
    });
    pick(app, 'ct-range', 'custom');
    await settled();
    it('between dates shows two date boxes', function () {
      eq(app.byId('ct-range').hidden, false);
    });
    const beforeBad = app.requests('contracts').length;
    app.type(app.byId('ct-from'), '2026-13-01');
    app.fire(250);
    await settled();
    it('a date it cannot read is marked, and nothing is asked', function () {
      eq(app.requests('contracts').length, beforeBad);
      truthy(app.byId('ct-from').classList.contains('is-bad'));
    });
    app.type(app.byId('ct-from'), '2026-10-01');
    app.type(app.byId('ct-to'), '2026-10-02');
    app.fire(250);
    await settled();
    it('two dates go as server times, the second to the end of its day', function () {
      const data = app.last('contracts').data;
      eq(data.from, Math.floor(new Date(2026, 9, 1, 0, 0, 0).getTime() / 1000));
      eq(data.to, Math.floor(new Date(2026, 9, 2, 23, 59, 59).getTime() / 1000));
      falsy(app.byId('ct-from').classList.contains('is-bad'));
    });
    app.click(app.button('Next'));
    await settled();
    it('pages with Next', function () {
      eq(app.last('contracts').data.page, 2);
    });
    app.click(app.button('Clear'));
    await settled();
    it('Clear asks for everything again', function () {
      eq(app.last('contracts').data, { page: 1 });
    });
    clean(app, 'contracts');
  })();

  await (async function () {
    const pending = [];
    const server = standardServer({
      contracts: function (data) {
        return new Promise(function (resolve) { pending.push({ data: data, resolve: resolve }); });
      }
    });
    const app = boot(server);
    app.open(FULL);
    await settled();
    app.nav('contracts');
    await settled();
    pending.shift().resolve(contracts());
    await settled();
    app.type(app.byId('ct-q'), 'old');
    app.fire(250);
    app.type(app.byId('ct-q'), 'new');
    app.fire(250);
    await settled();
    const older = pending.shift(), newer = pending.shift();
    newer.resolve(contracts({ rows: [contractRow(7, { target: 'Newest Answer' })], pages: 1, total: 1 }));
    await settled();
    older.resolve(contracts({ rows: [contractRow(8, { target: 'Stale Answer' })], pages: 1, total: 1 }));
    await settled();
    it('a slow older answer never overwrites a newer one', function () {
      has(app.main(), 'Newest Answer');
      lacks(app.main(), 'Stale Answer');
    });
    clean(app, 'stale answers');
  })();

  /* ---- the contract drawer: void and settle ---- */
  await (async function () {
    const server = standardServer();
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    const drawer = app.drawer();
    it('a row opens the drawer and reads that contract', function () {
      eq(app.last('contract').data, { id: 'ct00000001' });
      eq(drawer.hidden, false);
      eq(app.byId('scrim').hidden, false);
    });
    it('the drawer has the terms, payouts, escrow lines, operatives, proposals and the timeline', function () {
      const text = app.text(drawer);
      ['Terms', 'Payouts', 'Escrow lines', 'Operatives', 'Open proposals', 'Timeline', 'Waiting for staff']
        .forEach(function (part) { has(text, part); });
      has(text, '$8,000 bank', 'what a line holds');
      has(text, '$6,000', 'what it still owes');
      has(text, 'left for staff');
      has(text, '3 × lockpick');
      has(text, 'Payout 2');
      has(text, 'escrow_deliver_parked', 'the timeline');
      has(text, 'extend_deadline', 'the open proposal');
      has(text, 'law enforcement');
      has(text, 'Ghost');
    });
    it('each stuck line offers exactly what the server says settles it', function () {
      const lines = drawer.querySelectorAll('.stuck-line');
      eq(lines.length, 3);
      const labels = function (li) {
        return li.querySelectorAll('button').map(function (b) { return b.querySelector('.lbl').textContent; });
      };
      eq(labels(lines[0]), ['Pay', 'Pay amount', 'Return', 'Delivered']);
      eq(labels(lines[1]), ['Return to']);
      eq(labels(lines[2]), []);
      has(app.text(lines[0]), 'Arrival unknown');
      has(app.text(lines[2]), 'ending unfinished; it settles itself within a minute');
    });

    const voidBtn = app.button('Void contract', drawer);
    app.type(drawer.querySelector('[data-bind="dr.reason"]'), 'Duplicate of ct00000002');
    app.click(voidBtn);
    await settled();
    it('void takes two clicks: the first only arms it', function () {
      eq(app.requests('void').length, 0);
      truthy(voidBtn.classList.contains('is-armed'));
      has(app.text(voidBtn), 'Click again to void');
    });
    app.fire(3000);
    it('and it disarms itself after three seconds', function () {
      falsy(voidBtn.classList.contains('is-armed'));
    });
    app.click(voidBtn);
    app.click(voidBtn);
    await settled();
    it('the second click voids, with the reason typed', function () {
      eq(app.requests('void').length, 1);
      eq(app.last('void').data, { id: 'ct00000001', reason: 'Duplicate of ct00000002' });
    });
    it('and shows exactly what the server answered, where it was asked and as a toast', function () {
      has(app.text(app.drawer().querySelector('.answer')), 'Contract ct00000001 voided: its escrow is back with the client.');
      has(app.toasts(), 'Contract ct00000001 voided');
    });
    it('then reads the contract again', function () {
      truthy(app.requests('contract').length >= 2);
    });

    const payAmount = app.button('Pay amount', app.drawer());
    app.type(app.drawer().querySelector('[data-bind="dr.amount.ct00000001:2"]'), '12.5');
    app.click(payAmount);
    await settled();
    it('pay <amount> refuses anything but a whole number before asking', function () {
      eq(app.requests('settle').length, 0);
      has(app.text(app.drawer().querySelector('.answer')), 'whole number of at least 1');
    });
    app.type(app.drawer().querySelector('[data-bind="dr.amount.ct00000001:2"]'), '2,000');
    const payAgain = app.button('Pay amount', app.drawer());
    app.click(payAgain);
    app.click(payAgain);
    await settled();
    it('and pays exactly that amount on the second click, answered in the server\'s words', function () {
      eq(app.last('settle').data, { line: 'ct00000001:2', disposition: 'pay', amount: 2000 });
      has(app.text(app.drawer().querySelector('.answer')), 'Settled ct00000001:2: paid 2000 to operative Ghost.');
    });

    app.type(app.drawer().querySelector('[data-bind="dr.owner.ct00000001:9"]'), 'CREATOR1');
    const returnTo = app.button('Return to', app.drawer());
    app.click(returnTo);
    app.click(returnTo);
    await settled();
    it('return to a citizen id names the owner', function () {
      eq(app.last('settle').data, { line: 'ct00000001:9', disposition: 'return', owner: 'CREATOR1' });
    });

    server.settle = { ok: false, err: 'invalid_input', message: 'Not settled: nothing of it was given (owed to operative Ghost and in no retry queue), so only pay settles it.' };
    const delivered = app.button('Delivered', app.drawer());
    app.click(delivered);
    app.click(delivered);
    await settled();
    it('delivered is sent as delivered, and a refusal shows its own words', function () {
      eq(app.last('settle').data, { line: 'ct00000001:2', disposition: 'delivered' });
      const answer = app.drawer().querySelector('.answer');
      truthy(answer.classList.contains('is-error'));
      has(app.text(answer), 'Not settled: nothing of it was given');
    });

    app.click(app.byId('scrim'));
    it('the scrim closes the drawer', function () {
      eq(app.drawer().hidden, true);
      eq(app.byId('scrim').hidden, true);
    });
    clean(app, 'the drawer');
  })();

  await (async function () {
    const app = boot(standardServer({ contract: contractDetail({ stuck: undefined, canVoid: false }) }));
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('a contract read while recovering says its stuck lines are not listed', function () {
      has(app.text(app.drawer()), 'Not listed while the server is recovering');
    });
    it('and a closed contract offers no void', function () {
      has(app.text(app.drawer()), 'a closed contract is never voided');
      eq(app.drawer().querySelectorAll('button').filter(function (b) { return b.getAttribute('data-act') === 'void'; }).length, 0);
    });
  })();

  /* ---- needs review ---- */
  await (async function () {
    const server = standardServer();
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('reviews');
    await settled();
    it('lists the open items with what is known and what the store says now', function () {
      eq(app.last('reviews').data, {});
      has(app.main(), 'bailout unrecorded');
      has(app.main(), 'store timeout');
      has(app.main(), 'contract accepted');
      has(app.main(), 'buyout none');
      has(app.main(), 'missing 1');
      has(app.main(), 'payer the target');
    });
    const first = app.byId('rv-rv00000001');
    app.type(first.querySelector('[data-bind="rv.rv00000001.amount"]'), '500');
    pick(app, 'rv-account:rv00000001', 'cash');
    const refund = app.button('Refund it', app.byId('rv-rv00000001'));
    app.click(refund);
    await settled();
    it('a refund takes two clicks', function () {
      eq(app.requests('resolve').length, 0);
    });
    app.click(refund);
    await settled();
    it('and names a party by role, an amount and an account', function () {
      eq(app.last('resolve').data, { id: 'rv00000001', action: 'refund', who: 'payer', amount: 500, account: 'cash' });
      has(app.main(), 'Review rv00000001 resolved: refunded $500 to the payer.');
    });

    const second = app.byId('rv-rv00000002');
    app.click(second.querySelectorAll('.seg-btn').filter(function (b) { return b.getAttribute('data-value') === 'yes'; })[0]);
    const refundGoods = app.button('Refund it', app.byId('rv-rv00000002'));
    app.click(refundGoods);
    app.click(refundGoods);
    await settled();
    it('or every item and weapon it records', function () {
      eq(app.last('resolve').data, { id: 'rv00000002', action: 'refund', who: 'from', goods: true });
    });

    app.click(app.byId('rv-rv00000001').querySelectorAll('.seg-btn').filter(function (b) {
      return b.getAttribute('data-value') === 'dismiss';
    })[0]);
    const before = app.requests('resolve').length;
    const dismiss = app.button('Dismiss it', app.byId('rv-rv00000001'));
    app.click(dismiss);
    await settled();
    it('a dismissal needs a note, and says so without asking', function () {
      eq(app.requests('resolve').length, before);
      has(app.text(app.byId('rv-rv00000001')), 'Say why in a note');
    });
    app.type(app.byId('rv-rv00000001').querySelector('[data-bind="rv.rv00000001.note"]'), 'Contract shows the buyout');
    const dismissAgain = app.button('Dismiss it', app.byId('rv-rv00000001'));
    app.click(dismissAgain);
    app.click(dismissAgain);
    await settled();
    it('and goes with the note', function () {
      eq(app.last('resolve').data, { id: 'rv00000001', action: 'dismiss', note: 'Contract shows the buyout' });
    });
    app.click(app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-value') === 'all'; })[0]);
    await settled();
    it('All asks for the resolved ones too', function () {
      eq(app.last('reviews').data, { all: true });
    });
    clean(app, 'reviews');
  })();

  await (async function () {
    const server = standardServer();
    let resolved = false;
    // The server lists open items only: once resolved, it is not in the list.
    server.reviews = function () {
      const list = reviews();
      if (resolved) list.data.items = list.data.items.filter(function (i) { return i.id !== 'rv00000001'; });
      return list;
    };
    server.resolve = function () {
      resolved = true;
      return { ok: true, message: 'Resolved: 1 line(s) given, 0 owed and given while they are in the city or at '
        + 'their next login, 0 left for Stuck escrow (giving raised). ', data: { detail: {} } };
    };
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('reviews');
    await settled();
    app.type(app.byId('rv-rv00000001').querySelector('[data-bind="rv.rv00000001.amount"]'), '500');
    const refund = app.button('Refund it', app.byId('rv-rv00000001'));
    app.click(refund);
    app.click(refund);
    await settled();
    it('an item just resolved stays, with the server\'s exact answer in it, once the queue is read again', function () {
      truthy(app.requests('reviews').length >= 2, 'the queue was read again');
      const card = app.byId('rv-rv00000001');
      truthy(card, 'still drawn, though the open list no longer has it');
      has(app.text(card), 'Resolved: 1 line(s) given');
      has(app.text(card), 'resolved', 'marked resolved');
      eq(card.querySelectorAll('.rv-form').length, 0, 'and offers nothing more to do');
      truthy(app.byId('rv-rv00000002'), 'the rest as listed');
    });
    app.click(app.button('Refresh'));
    await settled();
    it('until Refresh', function () {
      falsy(app.byId('rv-rv00000001'), 'gone once the queue is read afresh');
      truthy(app.byId('rv-rv00000002'));
    });
    clean(app, 'a review resolved');
  })();

  /* W137, W138: one left part-way and one not in the store yet. */
  await (async function () {
    const server = standardServer({
      reviews: { ok: true, data: { items: [
        { id: 'rv00000003', kind: 'bailout_refund_stranded', about: 'a buyout premium handed back reached nobody',
          contract: 'ct00000003', parties: [{ role: 'payer', who: 'the target' }], amount: 5000, account: 'bank',
          items: [], known: {}, now: { contract: 'cancelled' }, state: 'resolving',
          resolution: { action: 'refund', cid: 'the target' }, resolved_by: 'console', created_at: NOW - 700 },
        { id: 'rv00000004', kind: 'bailout_refund_stranded', about: 'a buyout premium handed back reached nobody',
          contract: 'ct00000004', parties: [{ role: 'payer', who: 'the target' }], amount: 900, account: 'bank',
          items: [], known: {}, now: {}, state: 'open', unwritten: true, created_at: NOW - 600 }
      ] } },
      resolve: { ok: true, message: 'Resolved: 1 line(s) given. It had been decided before a stop and was '
        + 'finished as decided, not as asked now.', data: { detail: {} } }
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('reviews');
    await settled();
    const resolving = app.byId('rv-rv00000003');
    it('one left part-way says what was decided, with one button and no actions to choose', function () {
      has(app.text(resolving), 'Being resolved: refund to the target by console');
      eq(resolving.querySelectorAll('.seg-btn').length, 0, 'no Refund, Pay or Dismiss to pick');
      falsy(app.text(resolving).indexOf('Resolved') !== -1 && app.text(resolving).indexOf('Being resolved') === -1,
        'not labelled resolved');
      eq(resolving.querySelectorAll('dt').filter(function (d) { return d.textContent === 'Resolved'; }).length, 0,
        'no Resolved row');
      truthy(app.button('Finish as decided', resolving));
    });
    const finish = app.button('Finish as decided', resolving);
    app.click(finish);
    await settled();
    it('Finish as decided takes two clicks', function () {
      eq(app.requests('resolve').length, 0);
    });
    app.click(finish);
    await settled();
    it('and sends the finish, with no other fields', function () {
      eq(app.last('resolve').data, { id: 'rv00000003', action: 'finish' });
    });

    const unwritten = app.byId('rv-rv00000004');
    it('one not in the store yet is drawn, every part of it off, saying why', function () {
      has(app.text(unwritten), 'It can be resolved once the store has taken it, within a tick.');
      eq(app.button('Refund it', unwritten).disabled, true);
      unwritten.querySelectorAll('.seg-btn').forEach(function (b) { eq(b.disabled, true, b.textContent); });
      eq(unwritten.querySelector('[data-bind="rv.rv00000004.amount"]').disabled, true);
    });
    const before = app.requests('resolve').length;
    app.click(app.button('Refund it', unwritten));
    app.click(app.button('Refund it', app.byId('rv-rv00000004')));
    await settled();
    it('and clicking it asks nothing', function () {
      eq(app.requests('resolve').length, before);
    });
    clean(app, 'a review left part-way, and one not in the store');
  })();

  /* ---- alerts ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(ADMIN);
    await settled();
    it('counts the open alerts on the navigation and on the overview', function () {
      eq(app.byId('count-alerts').textContent, '4');
      eq(app.byId('count-alerts').hidden, false);
      eq(app.byId('ov-alerts').textContent, '4');
      has(app.main(), 'open alerts, not acknowledged yet');
    });
    app.click(app.button('Open Alerts'));
    await settled();
    it('opens on the open alerts, newest first, each with its level, count and contract', function () {
      eq(app.last('alerts').data, { state: 'open' });
      const cards = app.$$('article.al');
      eq(cards.length, 4);
      eq(cards[0].getAttribute('id'), 'al-al00000001');
      has(app.text(cards[0]), 'Needs staff');
      has(app.text(cards[0]), 'said 3 times');
      has(app.text(cards[1]), 'Setting');
      truthy(cards[0].querySelector('button.link').getAttribute('data-id') === 'ct00000001', 'the contract, as a link');
      has(app.text(cards[0]), 'What the last shutdown left part-way', 'the block under its first line');
      eq(app.$$('img').length, 0, 'the text is escaped');
    });
    it('says where Discord stands, and never shows a webhook', function () {
      has(app.main(), 'Posting to the alert webhook (crimson_hitman_alert_webhook)');
      has(app.main(), 'Posted since the start7 alerts');
      lacks(app.main(), 'https://');
      truthy(app.button('Send a test alert'), 'and a test button');
    });

    const ack = app.button('Acknowledge', app.byId('al-al00000003'));
    app.click(ack);
    await settled();
    it('acknowledging one takes two clicks', function () {
      eq(app.requests('ackAlerts').length, 0);
      truthy(ack.classList.contains('is-armed'), 'armed');
    });
    const reads = app.requests('alerts').length;
    app.click(ack);
    await settled();
    it('and sends that alert, then reads the list again', function () {
      eq(app.last('ackAlerts').data, { ids: ['al00000003'] });
      has(app.toasts(), 'Acknowledged 1 alert(s).');
      truthy(app.requests('alerts').length > reads, 'read again');
    });

    const all = app.button('Acknowledge all shown');
    app.click(all);
    await settled();
    it('acknowledging all shown takes two clicks too', function () {
      eq(app.requests('ackAlerts').length, 1);
    });
    app.click(all);
    await settled();
    it('and sends every alert shown', function () {
      eq(app.last('ackAlerts').data, { ids: ['al00000001', 'al00000002', 'al00000003', 'al00000004'] });
    });

    app.click(app.button('Send a test alert'));
    await settled();
    it('sends a test alert on one click, and says what came of it', function () {
      eq(app.requests('testAlert').length, 1);
      has(app.main(), 'A test alert goes to Discord');
    });

    app.click(app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-value') === 'acknowledged'; })[0]);
    await settled();
    it('lists the acknowledged ones apart, with who acknowledged each and when', function () {
      eq(app.last('alerts').data, { state: 'acknowledged' });
      const cards = app.$$('article.al');
      eq(cards.length, 1);
      has(app.text(cards[0]), 'ADMIN001');
      eq(app.$$('article.al button').filter(function (b) { return b.getAttribute('data-act') === 'al-ack'; }).length, 0,
        'nothing to acknowledge there');
      lacks(app.main(), 'Acknowledge all shown');
    });
    clean(app, 'alerts');
  })();

  await (async function () {
    const app = boot(standardServer());
    app.open(READER);
    await settled();
    app.nav('alerts');
    await settled();
    it('staff who may only read see the alerts, with nothing to acknowledge or send', function () {
      eq(app.$$('article.al').length, 4);
      eq(app.$$('button').filter(function (b) { return b.getAttribute('data-act') === 'al-ack'; }).length, 0);
      lacks(app.main(), 'Acknowledge all shown');
      truthy(app.button('Send a test alert').disabled, 'the test is a write');
    });
    clean(app, 'alerts read only');
  })();

  await (async function () {
    function withDiscord(discord) {
      return function (data) {
        const view = alertsView(data);
        view.data.discord = discord;
        return view;
      };
    }
    const off = boot(standardServer({ alerts: withDiscord({ on: false, webhook: 'alert', posted: 0, waiting: 0 }) }));
    off.open(ADMIN);
    await settled();
    off.nav('alerts');
    await settled();
    const none = boot(standardServer({ alerts: withDiscord({ on: true, posted: 0, waiting: 0 }) }));
    none.open(ADMIN);
    await settled();
    none.nav('alerts');
    await settled();
    const failed = boot(standardServer({ alerts: withDiscord({ on: true, webhook: 'staff', posted: 2, waiting: 1,
      lastOkAt: NOW - 600, lastFail: { at: NOW - 60, tries: 3, status: 500, alerts: 4 } }) }));
    failed.open(ADMIN);
    await settled();
    failed.nav('alerts');
    await settled();
    it('says when posting is switched off, and when no webhook is set', function () {
      has(off.main(), 'Off: Post alerts to Discord is switched off under Features.');
      has(none.main(), 'No webhook is set, so nothing is posted. Set crimson_hitman_alert_webhook');
    });
    it('says a post was given up after three tries, and that the alerts are still listed', function () {
      has(failed.main(), 'the staff webhook (crimson_hitman_webhook)');
      has(failed.main(), 'A post was given up after 3 tries (HTTP 500)');
      has(failed.main(), '4 alerts not posted, still listed here.');
    });
    const test = boot(standardServer({ alerts: withDiscord({ on: true, webhook: 'alert', posted: 0, waiting: 0,
      lastFail: { at: NOW - 60, tries: 3, status: 0, alerts: 0, test: true } }) }));
    test.open(ADMIN);
    await settled();
    test.nav('alerts');
    await settled();
    it('and when it carried only the test, that the test was not posted', function () {
      has(test.main(), 'A post was given up after 3 tries (no answer)');
      has(test.main(), 'the test alert not posted.');
      lacks(test.main(), 'still listed here');
    });
    clean(test, 'a test given up');
    clean(off, 'discord off');
    clean(none, 'no webhook');
    clean(failed, 'a post given up');
  })();

  /* ---- console ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(ADMIN);
    await settled();
    app.nav('console');
    await settled();
    it('reads what the server keeps of its console when it opens', function () {
      eq(app.last('console').data, {});
      has(app.main(), 'Settings that need attention (2)');
      has(app.main(), 'warning: Kidnap.Radius is 2');
      has(app.main(), 'What the last start said');
      has(app.main(), 'opening the store in json mode');
      has(app.main(), 'And 3 more lines the start said, past the 120 kept.');
      has(app.main(), 'Since the start, newest first');
      has(app.main(), 'Debug output is off (Config.Debug)');
      eq(app.$$('img').length, 0, 'every line is escaped');
    });
    it('shows the newest line first, each with its kind, when it was said and how many times', function () {
      const lines = app.byId('cs-list').querySelectorAll('li').filter(function (li) {
        return li.querySelectorAll('span').filter(function (sp) { return sp.classList.contains('time'); }).length;
      });
      eq(lines.length, 2);
      has(app.text(lines[0]), 'slow job expiry');
      has(app.text(lines[0]), 'Debug');
      has(app.text(lines[0]), 'said 4 times');
      has(app.text(lines[1]), 'Always');
      lacks(app.text(lines[1]), 'said 1 times');
    });

    app.click(app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-act') === 'cs-kind'
      && b.getAttribute('data-value') === 'always'; })[0]);
    it('filters by kind', function () {
      const text = app.text(app.byId('cs-list'));
      has(text, 'BOOT RECOVERY FAILED');
      has(text, 'left for staff');
      lacks(text, 'opening the store');
      lacks(text, 'slow job expiry');
      lacks(text, 'Settings that need attention');
    });
    app.click(app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-act') === 'cs-kind'
      && b.getAttribute('data-value') === 'problem'; })[0]);
    it('the problems alone', function () {
      const text = app.text(app.byId('cs-list'));
      has(text, 'warning: Limits.MaxAcceptedPerHitman is 0');
      lacks(text, 'left for staff');
      lacks(text, 'What the last start said');
    });
    app.click(app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-act') === 'cs-kind'
      && b.getAttribute('data-value') === ''; })[0]);
    const reads = app.requests('console').length;
    app.type(app.byId('cs-q'), 'KIDNAP');
    it('and by text, as it is typed, asking the server nothing', function () {
      const text = app.text(app.byId('cs-list'));
      has(text, 'Kidnap.Radius');
      lacks(text, 'MaxAcceptedPerHitman');
      lacks(text, 'slow job');
      eq(app.requests('console').length, reads);
      eq(app.byId('cs-q').value, 'KIDNAP', 'the box is not drawn again under the typing');
    });

    app.click(app.button('Copy'));
    it('copies the lines shown, as plain text', function () {
      eq(app.document.clipboard, 'Settings that need attention:\n[problem] warning: Kidnap.Radius is 2');
      has(app.toasts(), 'Copied 1 line.');
    });
    app.type(app.byId('cs-q'), '');
    app.click(app.button('Copy'));
    it('every line shown, in the order shown, with times and counts', function () {
      const copied = String(app.document.clipboard).split('\n');
      eq(copied.length, 9);
      eq(copied[3], 'What the last start said:');
      eq(copied[4], '[debug] opening the store in json mode');
      eq(copied[5], '[always] BOOT RECOVERY FAILED: ' + XSS, 'plain text, as the server sent it');
      truthy(/^\d\d:\d\d:\d\d \[debug\] slow job expiry took 12 ms \(x4\)$/.test(copied[7]), copied[7]);
      has(app.toasts(), 'Copied 6 lines.');
      eq(app.$$('textarea').length, 0, 'the box it copied from is gone');
    });
    app.document.copyRefused = true;
    app.click(app.button('Copy'));
    it('says so when the game will not copy', function () {
      has(app.toasts(), 'select the lines and press Ctrl+C instead');
    });

    app.click(app.button('Refresh'));
    await settled();
    it('Refresh reads it again', function () { eq(app.requests('console').length, reads + 1); });
    const clears = app.byId('cs-list')._clears || 0;
    app.fire(10000);
    await settled();
    it('and so does the panel\'s refresh while it is open, drawing nothing when nothing changed', function () {
      eq(app.requests('console').length, reads + 2);
      eq(app.byId('cs-list')._clears || 0, clears, 'the same lines are not drawn again');
    });
    app.server.console = consoleView({ recent: [{ text: 'a new line', kind: 'always', at: NOW, times: 1 }] });
    app.fire(10000);
    await settled();
    it('a new line is drawn at the next refresh', function () {
      has(app.text(app.byId('cs-list')), 'a new line');
    });
    let held = null;
    app.server.console = function () { return new Promise(function (resolve) { held = resolve; }); };
    app.click(app.button('Refresh'));
    app.click(app.button('Refresh'));
    app.fire(10000);
    await settled();
    it('one read at a time: a refresh asked for while one is out waits for its answer', function () {
      eq(app.requests('console').length, reads + 4);
    });
    held(consoleView());
    await settled();
    app.nav('overview');
    await settled();
    const after = app.requests('console').length;
    app.fire(10000);
    await settled();
    it('and nothing once another section is open', function () {
      eq(app.requests('console').length, after);
    });
    clean(app, 'console');
  })();

  await (async function () {
    const app = boot(standardServer({ console: consoleView({ debug: true, problems: [], count: 0, bootLeft: 0,
      boot: [], recent: [] }) }));
    app.open(READER);
    await settled();
    app.nav('console');
    await settled();
    it('staff who may only read see it too, and an empty console says so', function () {
      has(app.main(), 'Debug output is on (Config.Debug)');
      has(app.main(), 'Settings that need attention (0)');
      has(app.main(), 'None.');
      has(app.main(), 'Nothing kept.');
      has(app.main(), 'Nothing since the start.');
      truthy(!app.button('Copy').disabled, 'copying is not a write');
    });
    const refused = boot(standardServer({ console: { ok: false, err: 'rate_limited', message: 'Slow down. Try again in 3 second(s).' } }));
    refused.open(ADMIN);
    await settled();
    refused.nav('console');
    await settled();
    it('a refused read says why', function () { has(refused.main(), 'Slow down. Try again in 3 second(s).'); });
    clean(app, 'console read only');
    clean(refused, 'console refused');
  })();

  /* ---- logs ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(FULL);
    await settled();
    app.nav('logs');
    await settled();
    it('reads the log newest first, as the server pages it', function () {
      eq(app.last('logs').data, {});
      has(app.main(), 'admin_void');
      has(app.main(), 'Page 1 · newest first');
      eq(app.button('Newer').disabled, true, 'nothing newer than the first page');
    });
    pick(app, 'lg-kind', 'financial');
    await settled();
    it('filters by kind', function () { eq(app.last('logs').data, { kind: 'financial' }); });
    const input = function (bind) {
      return app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === bind; })[0];
    };
    app.type(input('lg.action'), 'settle');
    app.type(input('lg.contract'), 'ct00000003');
    app.type(input('lg.actor'), 'TARGET01');
    app.fire(350);
    await settled();
    it('by part of the action, a contract and (with identity) a citizen id', function () {
      eq(app.last('logs').data, { kind: 'financial', action: 'settle', contract: 'ct00000003', actor: 'TARGET01' });
    });
    app.click(app.button('Older'));
    await settled();
    it('Older follows the server\'s cursor', function () {
      eq(app.last('logs').data.cursor, 4242);
      has(app.main(), 'Page 2');
    });
    app.click(app.button('Newer'));
    await settled();
    it('and Newer goes back to where it was', function () {
      eq(app.last('logs').data.cursor, undefined);
    });
    app.click(app.$('tr.row'));
    it('a row opens its whole detail', function () {
      truthy(app.$('pre.json'), 'the detail, whole');
      has(app.text(app.$('pre.json')), '"lines": 2');
    });
    app.click(app.$$('button.link').filter(function (b) { return b.getAttribute('data-act') === 'contract'; })[0]);
    await settled();
    it('and its contract opens the drawer', function () {
      eq(app.last('contract').data, { id: 'ct00000003' });
      eq(app.drawer().hidden, false);
    });
    clean(app, 'logs');
  })();

  await (async function () {
    const app = boot(standardServer());
    app.open(FULL);
    await settled();
    app.nav('logs');
    await settled();
    const input = function (bind) {
      return app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === bind; })[0];
    };
    const asked = app.requests('logs').length;
    app.type(input('lg.contract'), 'ct00');
    app.fire(350);
    await settled();
    it('a contract id half typed is marked, and asks nothing while typing goes on', function () {
      eq(app.requests('logs').length, asked, 'no request for a partial id');
      truthy(input('lg.contract').classList.contains('is-bad'), 'the box says it is not one yet');
      lacks(app.toasts(), 'not a contract id', 'and no error toast at every pause');
    });
    app.key(input('lg.contract'), 'Enter');
    await settled();
    it('Enter on it says what a contract id is, and still asks nothing', function () {
      eq(app.requests('logs').length, asked);
      has(app.toasts(), 'A contract id is 8 to 64 letters');
    });
    app.type(input('lg.actor'), 'ab');
    app.type(input('lg.contract'), 'ct00000003');
    app.fire(350);
    await settled();
    it('nor while the citizen id box holds no citizen id', function () {
      eq(app.requests('logs').length, asked);
      falsy(input('lg.contract').classList.contains('is-bad'), 'the contract id is one now');
      truthy(input('lg.actor').classList.contains('is-bad'));
    });
    app.type(input('lg.actor'), 'TARGET01');
    app.fire(350);
    await settled();
    it('and asks once both are whole', function () {
      eq(app.requests('logs').length, asked + 1);
      eq(app.last('logs').data, { contract: 'ct00000003', actor: 'TARGET01' });
      falsy(input('lg.actor').classList.contains('is-bad'));
    });
    clean(app, 'half-typed ids');
  })();

  /* ---- players ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(FULL);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('looks somebody up by player id', function () {
      eq(app.last('player').data, { subject: '12' });
    });
    it('and shows their record, contracts, what they are owed and their notices', function () {
      const text = app.main();
      has(text, 'Dana Reyes');
      has(text, 'TARGET01');
      has(text, 'in the city · player 12');
      has(text, '80%');
      has(text, 'ct00000005:2');
      has(text, '1 delivery pending');
      has(text, 'Contract closed');
      has(text, 'ct00000001');
    });
    app.click(app.button('Whois'));
    await settled();
    it('with identity, whois answers under the contract', function () {
      eq(app.last('whois').data, { id: 'ct00000001' });
      has(app.main(), 'Kai Holt');
    });
    clean(app, 'players');
  })();

  await (async function () {
    // As the server answers staff without crimson.identity: no record.
    const answer = player();
    delete answer.data.stats;
    const app = boot(standardServer({ player: answer }));
    app.open(ADMIN);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), 'TARGET01');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('without identity the record is said to be held back, not drawn as zeros', function () {
      has(app.main(), 'Their record is not shown');
      lacks(app.main(), 'Success rate');
      has(app.main(), '1 delivery pending', 'what may be shown still is');
    });
    clean(app, 'no record');
  })();

  /* ---- features, limits & settings ---- */
  await (async function () {
    const server = standardServer();
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('settings');
    await settled();
    it('lists every feature switch by group, with its default and where it comes from', function () {
      const text = app.main();
      ['Rewards', 'Buyouts', 'The app', 'Completion'].forEach(function (g) { has(text, g); });
      has(text, 'Config.Bailout.Enabled');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'changed from the panel');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'config.lua: On');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'set by ADMIN001');
      has(app.text(app.byId('st-row-App.DefaultInstalled')), 'applies after restart');
      has(app.text(app.byId('st-row-Relay.Enabled')), 'not applied');
      has(app.text(app.byId('st-row-Sources.cash.enabled')), 'Under way:');
      has(app.text(app.byId('st-row-Completion.PhotoStorage')), 'does not apply now',
        'a key whose switch is off says so beside it');
      has(app.text(app.byId('st-row-Completion.PhotoStorage')),
        'Does not apply while kill photos are off');
      lacks(app.text(app.byId('st-row-Completion.KillPhotos')), 'does not apply now',
        'and the switch itself does not');
    });
    app.click(app.byId('st-row-Sources.cash.enabled').querySelector('.switch'));
    await settled();
    it('a switch turns the feature off at one click and shows the answer', function () {
      eq(app.last('setSetting').data, { key: 'Sources.cash.enabled', value: false });
      has(app.toasts(), 'Sources.cash.enabled is now false.');
      has(app.text(app.byId('st-row-Sources.cash.enabled')), 'Sources.cash.enabled is now false.');
      truthy(app.requests('settings').length >= 2, 'the settings are read again');
    });
    app.click(app.byId('st-row-Bailout.Enabled').querySelector('.switch'));
    await settled();
    it('and back on', function () {
      eq(app.last('setSetting').data, { key: 'Bailout.Enabled', value: true });
    });
    app.click(app.byId('st-row-Completion.Fulfilment').querySelectorAll('.seg-btn')
      .filter(function (b) { return b.getAttribute('data-value') === 'either'; })[0]);
    await settled();
    it('a choice sets one of its choices', function () {
      eq(app.last('setSetting').data, { key: 'Completion.Fulfilment', value: 'either' });
    });
    const reset = app.button('Reset to config.lua', app.byId('st-row-Bailout.Enabled'));
    app.click(reset);
    await settled();
    it('reset takes two clicks', function () { eq(app.requests('resetSetting').length, 0); });
    app.click(reset);
    await settled();
    it('and puts the key back to config.lua', function () {
      eq(app.last('resetSetting').data, { key: 'Bailout.Enabled' });
    });

    app.click(app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-value') === 'limits'; })[0]);
    const limit = app.byId('st-row-Limits.MaxAcceptedPerHitman');
    const box = limit.querySelector('input');
    app.type(box, '0');
    app.click(app.button('Save', limit));
    await settled();
    const sets = app.requests('setSetting').length;
    it('a number outside its range is refused before it is sent', function () {
      has(app.text(app.byId('st-row-Limits.MaxAcceptedPerHitman')), 'has to be from 1 to 50');
    });
    app.type(app.byId('st-row-Limits.MaxAcceptedPerHitman').querySelector('input'), '2.5');
    app.key(app.byId('st-row-Limits.MaxAcceptedPerHitman').querySelector('input'), 'Enter');
    await settled();
    it('and so is a fraction where it takes a whole number', function () {
      eq(app.requests('setSetting').length, sets);
      has(app.text(app.byId('st-row-Limits.MaxAcceptedPerHitman')), 'has to be a whole number');
    });
    server.setSetting = { ok: false, err: 'invalid_value',
      message: 'Not changed: Limits.MaxAcceptedPerHitman Config.Limits.MaxAcceptedPerHitman is above what the start allows.' };
    app.type(app.byId('st-row-Limits.MaxAcceptedPerHitman').querySelector('input'), '1');
    app.click(app.button('Save', app.byId('st-row-Limits.MaxAcceptedPerHitman')));
    await settled();
    it('a number goes as a number, and the start-up checks\' refusal is shown on its row', function () {
      eq(app.last('setSetting').data, { key: 'Limits.MaxAcceptedPerHitman', value: 1 });
      has(app.text(app.byId('st-row-Limits.MaxAcceptedPerHitman')), 'above what the start allows');
    });
    server.setSetting = standardServer().setSetting;
    app.type(app.byId('st-row-Penalty.MaxFractionOfEscrow').querySelector('input'), '0.75');
    app.click(app.button('Save', app.byId('st-row-Penalty.MaxFractionOfEscrow')));
    await settled();
    it('a fraction goes where the key takes one', function () {
      eq(app.last('setSetting').data, { key: 'Penalty.MaxFractionOfEscrow', value: 0.75 });
    });
    app.type(app.byId('st-row-Advisory.RecipientJobNames').querySelector('input'), 'police, sheriff');
    app.click(app.button('Save', app.byId('st-row-Advisory.RecipientJobNames')));
    await settled();
    it('a job list goes as names', function () {
      eq(app.last('setSetting').data, { key: 'Advisory.RecipientJobNames', value: ['police', 'sheriff'] });
    });
    app.type(app.byId('st-q'), 'stake');
    it('Find a setting hides what does not match', function () {
      eq(app.byId('st-row-Limits.MaxAcceptedPerHitman').hidden, true);
      eq(app.byId('st-row-Penalty.MaxFractionOfEscrow').hidden, false);
    });
    const all = app.button('Reset all to config.lua');
    app.click(all);
    await settled();
    it('reset all takes two clicks', function () { eq(app.requests('resetSettings').length, 0); });
    app.click(all);
    await settled();
    it('and says how many were put back', function () {
      eq(app.requests('resetSettings').length, 1);
      has(app.toasts(), 'Every setting is back to what config.lua says (2 were changed).');
    });
    app.type(app.byId('st-q'), '');
    app.click(app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-value') === 'readonly'; })[0]);
    it('a read-only key shows why, and no control', function () {
      const row = app.byId('st-row-Admin.Enabled');
      has(app.text(row), 'would lock you out');
      eq(row.querySelectorAll('button').length, 0);
      eq(row.querySelectorAll('input').length, 0);
    });
    it('but one whose stored value was not applied can have that value reset away', function () {
      const row = app.byId('st-row-Cooldowns.admin.burst');
      has(app.text(row), 'not applied');
      eq(row.querySelectorAll('input').length, 0, 'still nothing to change it with');
      truthy(app.button('Reset to config.lua', row), 'only the reset');
    });
    clean(app, 'settings');
  })();

  await (async function () {
    const view = settingsView();
    view.data.limits.push({ key: 'Ledger.PhotoRetentionDays', group: 'Ledger',
      label: 'Days an unopened kill photo is kept (0 forever)', kind: 'number', integer: true, min: 0, max: 365,
      live: true, inflight: 'Looked at every ten minutes.', value: 30, default: 30, source: 'config',
      destroys: 'Lowered to %s, every unopened kill photo older than %s day(s) is deleted at the next sweep, for good.' });
    const server = standardServer({ settings: view });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('settings');
    await settled();
    app.click(app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-value') === 'limits'; })[0]);
    const row = function () { return app.byId('st-row-Ledger.PhotoRetentionDays'); };
    it('a setting whose lowering deletes says so on its row', function () {
      has(app.text(row()), 'Lowering it deletes for good');
    });
    const sets = app.requests('setSetting').length;
    app.type(row().querySelector('input'), '1');
    app.key(row().querySelector('input'), 'Enter');
    await settled();
    app.key(row().querySelector('input'), 'Enter');
    await settled();
    it('Enter never lowers it: it says what the save would delete and arms Save', function () {
      eq(app.requests('setSetting').length, sets, 'nothing sent, even on a second Enter');
      has(app.text(row()), 'Lowered to 1, every unopened kill photo older than 1 day(s) is deleted');
      truthy(app.byId('st-save-Ledger.PhotoRetentionDays').classList.contains('is-armed'));
    });
    app.fire(3000);
    app.click(app.button('Save', row()));
    await settled();
    it('the first click on Save arms it, and sends nothing', function () {
      eq(app.requests('setSetting').length, sets);
      const save = app.byId('st-save-Ledger.PhotoRetentionDays');
      truthy(save.classList.contains('is-armed'));
      has(app.text(save), 'Click again to save');
    });
    app.click(app.byId('st-save-Ledger.PhotoRetentionDays'));
    await settled();
    it('the second lowers it', function () {
      eq(app.requests('setSetting').length, sets + 1);
      eq(app.last('setSetting').data, { key: 'Ledger.PhotoRetentionDays', value: 1 });
    });
    app.type(row().querySelector('input'), '60');
    app.click(app.button('Save', row()));
    await settled();
    it('raising it deletes nothing, and saves at one click', function () {
      eq(app.requests('setSetting').length, sets + 2);
      eq(app.last('setSetting').data, { key: 'Ledger.PhotoRetentionDays', value: 60 });
    });
    app.type(row().querySelector('input'), '0');
    app.key(row().querySelector('input'), 'Enter');
    await settled();
    it('and so does 0, which keeps every photo', function () {
      eq(app.requests('setSetting').length, sets + 3);
      eq(app.last('setSetting').data, { key: 'Ledger.PhotoRetentionDays', value: 0 });
    });
    clean(app, 'a setting that deletes');
  })();

  /* ---- stuck escrow ---- */
  await (async function () {
    const server = standardServer();
    let settledLine = false;
    server.stuck = function () {
      const list = stuckList();
      if (settledLine) list.data.lines = list.data.lines.filter(function (l) { return l.line !== 'ct00000001:2'; });
      return list;
    };
    server.settle = function () {
      settledLine = true;
      return { ok: true, message: 'Line settled.', data: { detail: {} } };
    };
    const app = boot(server);
    app.open(FULL);
    await settled();
    app.click(app.button('Open Stuck escrow'));
    await settled();
    it('the overview opens Stuck escrow, where every waiting line is listed', function () {
      eq(app.last('stuck').op, 'stuck');
      eq(app.byId('nav-stuck').getAttribute('aria-current'), 'page');
      has(app.main(), 'ct00000001:2');
      has(app.main(), 'owe00000003');
      has(app.main(), 'ct00000009:1');
      has(app.main(), 'ending unfinished; it settles itself within a minute');
      has(app.main(), '5 left for you to settle, of 6 listed');
      has(app.main(), 'Arrival unknown');
      has(app.main(), 'Never given: only Pay settles it');
      has(app.main(), '2 money events no rule could settle wait in the review queue');
    });
    const item = function (id) {
      return app.$$('li').filter(function (li) {
        return li.classList.contains('stuck-line') && app.text(li).indexOf(id) !== -1;
      })[0];
    };
    it('a line nothing of which was given offers only Pay, with no amount to write the rest off', function () {
      eq(item('owe00000003').querySelectorAll('button').filter(function (b) {
        return b.getAttribute('data-act') === 'settle';
      }).map(function (b) { return b.getAttribute('data-how'); }), ['pay']);
      has(app.text(item('owe00000003')), 'Never given: only Pay settles it, to them, in full.');
      lacks(app.text(item('owe00000003')), 'Arrival unknown');
    });
    it('one left mid-release before it named anyone says nothing arrived and that Return puts it back', function () {
      const li = item('ct00000006:1');
      has(app.text(li), 'nothing of it was given');
      has(app.text(li), 'Return puts it back to its contract');
      lacks(app.text(li), 'Arrival unknown');
      lacks(app.text(li), 'Never given');
    });
    const delivered = app.button('Delivered', item('ct00000001:2'));
    app.click(delivered);
    await settled();
    it('a settle from here takes two clicks, as in the contract\'s view', function () {
      eq(app.requests('settle').length, 0);
      truthy(delivered.classList.contains('is-armed'));
    });
    app.click(delivered);
    await settled();
    it('and reads the list again, with the server\'s answer said', function () {
      eq(app.requests('settle').length, 1);
      eq(app.last('settle').data, { line: 'ct00000001:2', disposition: 'delivered' });
      has(app.toasts(), 'Line settled.');
      truthy(app.requests('stuck').length >= 2, 'read again');
      lacks(app.main(), 'ct00000001:2', 'a settled line leaves the list');
    });
    app.click(app.button('Pay amount', item('ct00000005:1')));
    await settled();
    it('Pay amount asks for an amount first, beside the line, and sends nothing', function () {
      eq(app.requests('settle').length, 1);
      has(app.text(item('ct00000005:1')), 'An amount is a whole number of at least 1.');
    });
    app.type(item('ct00000005:1').querySelector('[data-bind="dr.amount.ct00000005:1"]'), '400');
    const payAmount = app.button('Pay amount', item('ct00000005:1'));
    app.click(payAmount);
    app.click(payAmount);
    await settled();
    it('and pays that amount once it has one', function () {
      eq(app.last('settle').data, { line: 'ct00000005:1', disposition: 'pay', amount: 400 });
    });
    app.click(app.$$('button').filter(function (b) {
      return b.getAttribute('data-act') === 'contract' && b.getAttribute('data-id') === 'ct00000004';
    })[0]);
    await settled();
    it('a line\'s contract opens its view over the list', function () {
      eq(app.last('contract').data, { id: 'ct00000004' });
      eq(app.drawer().hidden, false);
    });
    const found = [];
    markupFrom(app, 'stuck escrow', found);
    it('player text in a stuck line is text, not markup', function () { eq(found, []); });
    clean(app, 'stuck escrow');
  })();

  await (async function () {
    const app = boot(standardServer({ stuck: { ok: true, data: { recovery: 'ready', lines: [], reviews: 0 } } }));
    app.open(READER);
    await settled();
    app.nav('stuck');
    await settled();
    it('says when nothing waits for staff', function () {
      has(app.main(), 'No escrow line is waiting for staff.');
    });
    clean(app, 'stuck, empty');
  })();

  await (async function () {
    const app = boot(standardServer({ stuck: { ok: true, data: { recovery: 'recovering', reviews: 1 } } }));
    app.open(FULL);
    await settled();
    app.nav('stuck');
    await settled();
    it('lists nothing while the server recovers, and says so', function () {
      has(app.main(), 'Not listed while the server is recovering from the restart.');
      has(app.main(), 'Open the queue');
      eq(app.byId('banner').hidden, false);
    });
    clean(app, 'stuck, recovering');
  })();

  await (async function () {
    const app = boot(standardServer());
    app.open(READER);
    await settled();
    app.nav('stuck');
    await settled();
    it('read-only staff see every settle in Stuck escrow disabled, saying why', function () {
      ['Pay', 'Pay amount', 'Return', 'Delivered', 'Return to'].forEach(function (label) {
        eq(app.button(label, app.byId('main')).disabled, true, label);
      });
    });
    clean(app, 'stuck, read only');
  })();

  /* ---- no commands anywhere in the panel ---- */
  await (async function () {
    it('knows the commands config.lua ships, to look for them', function () {
      truthy(COMMAND_NAMES.indexOf('ch-stuck') !== -1 && COMMAND_NAMES.indexOf('hitmanadmin') !== -1,
        COMMAND_NAMES.join(','));
    });
    const mentions = [];
    function sweep(app, where) {
      if (app.byId('panel').hidden) throw new Error('the panel closed by ' + where + ': ' + app.toasts());
      commandMentions(app).forEach(function (m) { mentions.push(where + ' ' + m); });
    }
    function flow(server, who) {
      return (async function () {
        const app = boot(server);
        app.open(who);
        await settled();
        sweep(app, 'overview');
        for (const section of ['contracts', 'stuck', 'reviews', 'alerts', 'console', 'logs', 'players', 'settings', 'tools']) {
          app.nav(section);
          await settled();
          sweep(app, section);
        }
        // The contract's view, with whois, and its destructive buttons armed.
        app.nav('contracts');
        await settled();
        const row = app.$('tr.row');
        if (row) {
          app.click(row);
          await settled();
          sweep(app, 'the contract view');
          const drawer = app.drawer();
          const whois = drawer.querySelectorAll('button').filter(function (b) { return b.getAttribute('data-act') === 'whois'; })[0];
          if (whois) { app.click(whois); await settled(); sweep(app, 'whois'); }
          const voidButton = drawer.querySelectorAll('button').filter(function (b) { return b.getAttribute('data-act') === 'void'; })[0];
          if (voidButton && !voidButton.disabled) {
            app.click(voidButton);
            sweep(app, 'void armed');
            app.click(voidButton);
            await settled();
            sweep(app, 'void answered');
          }
          const settle = app.drawer().querySelectorAll('button').filter(function (b) { return b.getAttribute('data-act') === 'settle'; })[0];
          if (settle && !settle.disabled) {
            app.click(settle);
            app.click(settle);
            await settled();
            sweep(app, 'settle answered');
          }
          app.click(app.button('Close', app.drawer()));
          await settled();
        }
        // A review resolved, and one refused.
        app.nav('reviews');
        await settled();
        const resolve = app.$$('button').filter(function (b) { return b.getAttribute('data-act') === 'resolve'; })[0];
        if (resolve && !resolve.disabled) {
          app.click(resolve);
          sweep(app, 'resolve armed');
          app.click(resolve);
          await settled();
          sweep(app, 'resolve answered');
        }
        // A log row's whole detail, a player and their whois.
        app.nav('logs');
        await settled();
        if (app.$('tr.row')) { app.click(app.$('tr.row')); sweep(app, 'a log row'); }
        app.nav('players');
        await settled();
        app.type(app.byId('pl-q'), 'TARGET01');
        app.key(app.byId('pl-q'), 'Enter');
        await settled();
        sweep(app, 'a player');
        // Every settings tab, and a change answered.
        app.nav('settings');
        await settled();
        for (const tab of ['features', 'limits', 'readonly']) {
          const seg = app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-value') === tab; })[0];
          if (seg) { app.click(seg); await settled(); sweep(app, 'settings ' + tab); }
        }
        const sw = app.$$('.switch').filter(function (b) { return !b.disabled; })[0];
        if (sw) { app.click(sw); await settled(); sweep(app, 'a setting changed'); }
        // The tools, each run.
        app.nav('tools');
        await settled();
        const refresh = app.button('Bring timers forward');
        if (!refresh.disabled) { app.click(refresh); sweep(app, 'refresh armed'); app.click(refresh); await settled(); }
        app.click(app.button('Run the diagnosis'));
        await settled();
        if (!app.button('Flush the audit log').disabled) { app.click(app.button('Flush the audit log')); await settled(); }
        sweep(app, 'the tools, run');
        clean(app, 'the sweep');
      })();
    }

    // The server's answers as it gives them, and as it refuses them.
    await flow(standardServer(), FULL);
    await flow(standardServer(), READER);
    await flow(standardServer({ overview: overview({ recovery: 'recovering', stuck: undefined }) }), FULL);
    const NOT_ALLOWED = 'Not authorised: this needs the crimson.admin ACE. Grant it with add_ace group.admin '
      + 'crimson.admin allow, pasted into the server console until the next restart, or put in server.cfg to '
      + 'keep it. Changing anything needs that ACE itself; the extra ACEs only read.';
    const RAISED = 'That raised an error on the server. Run the diagnosis, under Tools, to read it.';
    const refusing = standardServer({
      void: { ok: false, err: 'stalled_claim', message: 'Could not void it: contract ct00000001 is mid-claim with '
        + 'no claim running (a stalled claim: the claim paying a collection raised part-way), and only the next '
        + 'start puts it back. Pay each line Stuck escrow lists for it as a stalled claim with its Pay button, '
        + 'then restart the resource: recovery puts the contract back to accepted (or completes it, if that was '
        + 'its last collection), and Void contract closes it then.' },
      settle: { ok: false, err: 'parked', message: 'Not settled: giving it raised again, so it is left for staff '
        + 'again; see Stuck escrow.' },
      resolve: { ok: false, err: 'note_required', message: 'Say why in the note: a dismissal gives nothing, and '
        + 'the note is the record of why.' },
      setSetting: { ok: false, err: 'not_allowed', message: NOT_ALLOWED },
      refresh: { ok: false, err: 'server_error', message: RAISED },
      flush: { ok: false, err: 'server_error' },
      diag: { ok: false, err: 'rate_limited', message: 'Slow down. Try again in 3 second(s).' },
      player: { ok: false, err: 'not_found', message: 'Nobody in the city has that citizen id, and nothing you '
        + 'may see here names it. Check how it is spelt.' },
      whois: { ok: false, err: 'identity_required', message: 'Unmasking needs crimson.identity, a separate ACE.' },
      stuck: { ok: false, err: 'server_error', message: RAISED },
      logs: { ok: false, err: 'invalid_input', message: 'That is not a contract id.' }
    });
    await flow(refusing, FULL);
    // And every answer the page words itself, for a refusal with no sentence.
    await flow(standardServer({
      void: { ok: false, err: 'recovering' }, settle: { ok: false, err: 'busy' },
      resolve: { ok: false, err: 'unknown_op' }, refresh: { ok: false, err: 'timeout' },
      setSetting: { ok: false, err: 'store_failed' }
    }), FULL);
    // A read refused outright closes the panel, saying why in a toast.
    for (const refusal of [{ ok: false, err: 'not_allowed', message: NOT_ALLOWED }, { ok: false, err: 'admin_off' }]) {
      const app = boot(standardServer({ overview: refusal }));
      app.open(FULL);
      await settled();
      it('a refusal that closes the panel says so (' + refusal.err + ')', function () {
        eq(app.byId('panel').hidden, true);
        truthy(app.toasts().length > 0, 'and says why');
      });
      commandMentions(app).forEach(function (m) { mentions.push('closed: ' + m); });
    }
    it('no section, view, armed button, answer or refusal names a command', function () {
      eq(mentions, [], 'a command named in the panel');
    });
    // Not vacuous: the same sweep finds one in an answer, and in a title.
    const planted = boot(standardServer({ diag: { ok: true, data: { lines: ['-> see /ch-stuck'] } } }));
    planted.open(FULL);
    await settled();
    planted.nav('tools');
    await settled();
    planted.click(planted.button('Run the diagnosis'));
    await settled();
    planted.byId('main').setAttribute('title', 'as /' + COMMAND_NAMES[0] + ' does');
    it('(and the sweep would see one, in text or an attribute)', function () {
      const found = commandMentions(planted);
      truthy(found.some(function (f) { return f.indexOf('text:') === 0; }), 'in text: ' + found.join(' | '));
      truthy(found.some(function (f) { return f.indexOf('title:') === 0; }), 'in a title: ' + found.join(' | '));
    });
    it('and the panel has no Commands card', function () {
      const app = boot(standardServer());
      app.open(FULL);
      app.nav('tools');
      lacks(app.main(), 'Commands');
      lacks(app.main(), 'Runs ');
    });
  })();

  /* ---- the kill photos kept from before ---- */
  await (async function () {
    const kept = { count: 3, open: 1, links: 2, files: 1, waiting: 0 };
    const server = standardServer({ settings: settingsView({ keptPhotos: kept }) });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('settings');
    await settled();
    const row = app.byId('st-row-Completion.KillPhotos');
    it('offers the removal under Kill photos while they are off and some are kept', function () {
      const button = app.button('Remove the 3 kill photos kept from before', row);
      truthy(button && !button.disabled, 'the button');
      has(app.text(row), '1 with a file on this server: the file is deleted.');
      has(app.text(row), '2 on lb-phone\'s image host: removing only forgets the link here, and the picture stays on the host.');
      has(app.text(row), '1 open on a phone right now: each is removed when that view closes, never while it is shown.');
    });
    const remove = app.button('Remove the 3 kill photos kept from before', row);
    app.click(remove);
    await settled();
    it('takes two clicks, the second naming the count', function () {
      eq(app.requests('removePhotos').length, 0);
      truthy(remove.classList.contains('is-armed'), 'armed');
      has(app.text(remove), 'Click again: remove 3 kill photos for good');
    });
    server.settings = settingsView();
    app.click(remove);
    await settled();
    it('then removes them, says what it did, and the button goes', function () {
      eq(app.requests('removePhotos').length, 1);
      eq(app.last('removePhotos').data, {});
      has(app.toasts(), 'the pictures stay on the host');
      const after = app.byId('st-row-Completion.KillPhotos');
      has(app.text(after), 'Removed 3 kill photo(s).', 'its answer stays');
      eq(after.querySelectorAll('button').filter(function (b) {
        return b.getAttribute('data-act') === 'st-remove-photos'; }).length, 0);
    });
    clean(app, 'remove kept photos');
  })();

  await (async function () {
    const kept = { count: 1, open: 0, links: 0, files: 1, waiting: 0 };
    const on = settingsView({ keptPhotos: kept });
    on.data.features.forEach(function (e) { if (e.key === 'Completion.KillPhotos') e.value = true; });
    function removeButtons(app) {
      return app.$$('button').filter(function (b) { return b.getAttribute('data-act') === 'st-remove-photos'; });
    }
    const none = boot(standardServer());
    none.open(ADMIN);
    await settled();
    none.nav('settings');
    await settled();
    const photosOn = boot(standardServer({ settings: on }));
    photosOn.open(ADMIN);
    await settled();
    photosOn.nav('settings');
    await settled();
    const reader = boot(standardServer({ settings: settingsView({ keptPhotos: kept }) }));
    reader.open(READER);
    await settled();
    reader.nav('settings');
    await settled();
    it('offers nothing when none is kept, or while kill photos are on', function () {
      eq(removeButtons(none).length, 0);
      eq(removeButtons(photosOn).length, 0);
    });
    it('names one photo as one, and is greyed out for staff who may only read', function () {
      const button = reader.button('Remove the 1 kill photo kept from before');
      truthy(button.disabled, 'a write');
      lacks(reader.text(reader.byId('st-row-Completion.KillPhotos')), 'image host');
    });
    clean(none, 'no kept photos');
    clean(photosOn, 'kill photos on');
    clean(reader, 'kept photos read only');
  })();

  /* ---- tools ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(ADMIN);
    await settled();
    app.nav('tools');
    await settled();
    const refresh = app.button('Bring timers forward');
    app.click(refresh);
    await settled();
    it('the timer refresh takes two clicks', function () { eq(app.requests('refresh').length, 0); });
    app.click(refresh);
    await settled();
    it('and shows what it did', function () {
      eq(app.requests('refresh').length, 1);
      has(app.main(), 'cooldowns cleared');
    });
    app.type(app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'tl.subject'; })[0], '12');
    app.click(app.button('Run the diagnosis'));
    await settled();
    it('the diagnosis runs as a player and shows its text', function () {
      eq(app.last('diag').data, { subject: 12 });
      has(app.main(), 'photo hosts: 0 -> add one');
    });
    app.message({ type: 'push', kind: 'diag', line: 'photo links: yes (the address leads here)' });
    it('and a line that had to wait is added when it comes', function () {
      has(app.main(), 'photo links: yes');
    });
    app.click(app.button('Flush the audit log'));
    await settled();
    it('flushing says how many rows were written', function () {
      has(app.main(), 'Audit log flushed: 4 row(s) written.');
    });
    clean(app, 'tools');
  })();

  await (async function () {
    const app = boot(standardServer({
      contracts: { ok: false, err: 'rate_limited', message: 'Slow down. Try again in 3 second(s).', data: { retryAfter: 3 } }
    }));
    app.open(FULL);
    await settled();
    app.nav('contracts');
    await settled();
    it('a rate-limited request says the server\'s words, with the wait', function () {
      has(app.toasts(), 'Slow down. Try again in 3 second(s).');
      eq(app.byId('panel').hidden, false, 'and the panel stays open');
    });
    clean(app, 'rate limited');
  })();

  await (async function () {
    const app = boot(standardServer());
    app.open(FULL);
    await settled();
    it('the overview\'s state chips open the contracts with that filter', function () {
      app.click(app.$$('button').filter(function (b) {
        return b.getAttribute('data-act') === 'ov-state' && b.getAttribute('data-value') === 'active';
      })[0]);
    });
    await settled();
    it('(as a request for that state)', function () {
      eq(app.last('contracts').data, { page: 1, state: 'active' });
    });
    clean(app, 'overview links');
  })();

  /* ---- G3: what the panel says it read ---- */

  /* W190: after a recovery that failed, every Stuck escrow surface said the
     server was still recovering. */
  await (async function () {
    const server = standardServer({
      overview: overview({ recovery: 'recovery_failed', stuck: null }),
      stuck: stuckList({ recovery: 'recovery_failed', lines: null }),
      contract: contractDetail({ stuck: null }, false)
    });
    const app = boot(server);
    app.open(access({ recovery: 'recovery_failed', canIdentify: false }));
    await settled();
    it('the overview says recovery failed, not that it is running', function () {
      has(app.main(), 'Not listed: recovery failed at the last start; restart the resource');
      lacks(app.main(), 'while the server is recovering');
    });
    app.nav('stuck');
    await settled();
    it('and so does Stuck escrow', function () {
      has(app.main(), 'Not listed: recovery failed at the last start; restart the resource');
    });
    app.nav('contracts');
    await settled();
    app.click(app.$$('[data-act="contract"]')[0]);
    await settled();
    it('and so does the contract\'s view', function () {
      has(app.text(app.drawer()), 'Not listed: recovery failed at the last start');
      lacks(app.text(app.drawer()), 'while the server is recovering');
    });
    clean(app, 'recovery failed');
  })();

  /* W190: a listing that raised read as recovery still running. */
  await (async function () {
    const app = boot(standardServer({ overview: overview({ stuck: { error: true } }) }));
    app.open(FULL);
    await settled();
    it('says the stuck listing could not be read when it raised', function () {
      has(app.main(), 'The list could not be read just now');
      lacks(app.main(), 'while the server is recovering');
    });
    clean(app, 'listing raised');
  })();

  /* W189: a settle in the contract view opened from Stuck escrow left the
     list behind it stale. */
  await (async function () {
    const server = standardServer();
    let settledLine = false;
    server.stuck = function () {
      const list = stuckList();
      if (settledLine) list.data.lines = list.data.lines.filter(function (l) { return l.line !== 'ct00000001:2'; });
      return list;
    };
    server.settle = function () {
      settledLine = true;
      return { ok: true, message: 'Line settled.', data: { detail: {} } };
    };
    const app = boot(server);
    app.open(FULL);
    await settled();
    app.nav('stuck');
    await settled();
    app.click(app.$$('button.link').filter(function (b) {
      return b.getAttribute('data-act') === 'contract' && b.getAttribute('data-id') === 'ct00000001';
    })[0]);
    await settled();
    const pay = app.$$('button').filter(function (b) {
      return b.getAttribute('data-act') === 'settle' && b.getAttribute('data-line') === 'ct00000001:2'
        && b.getAttribute('data-how') === 'pay' && b.getAttribute('data-where') === 'drawer';
    })[0];
    app.click(pay);
    app.click(pay);
    await settled();
    app.click(app.button('Close', app.drawer()));
    await settled();
    it('reads Stuck escrow again after a settle in the contract view over it', function () {
      eq(app.requests('settle').length, 1);
      lacks(app.main(), 'ct00000001:2', 'the settled line has left the list');
    });
    clean(app, 'stuck after a drawer settle');
  })();

  /* W141: Run it opened Tools, and a state chip kept the filters typed before. */
  await (async function () {
    const app = boot(standardServer());
    app.open(FULL);
    await settled();
    app.click(app.button('Run it'));
    await settled();
    it('Run it runs the diagnosis', function () {
      eq(app.byId('nav-tools').getAttribute('aria-current'), 'page');
      eq(app.requests('diag').length, 1);
      has(app.main(), 'photo hosts: 0');
    });
    app.nav('contracts');
    await settled();
    app.type(app.byId('ct-q'), 'Dana');
    pick(app, 'ct-rule', 'either');
    await settled();
    app.nav('overview');
    await settled();
    app.click(app.$$('button').filter(function (b) {
      return b.getAttribute('data-act') === 'ov-state' && b.getAttribute('data-value') === 'active';
    })[0]);
    await settled();
    it('a state chip lists that state alone, whatever was typed before', function () {
      eq(app.last('contracts').data, { page: 1, state: 'active' });
    });
    clean(app, 'run it and chips');
  })();

  /* W165: memory mode keeps nothing, and the panel said every switch was kept. */
  await (async function () {
    const app = boot(standardServer({ overview: overview({ storage: 'memory' }) }));
    app.open(FULL);
    await settled();
    it('says on the overview that memory mode keeps nothing', function () {
      has(app.main(), 'nothing is kept across a restart');
    });
    app.nav('settings');
    await settled();
    it('and in the Features intro that a change lasts until the resource stops', function () {
      has(app.main(), 'lasts until the resource stops');
      lacks(app.main(), 'is kept across restarts');
    });
    clean(app, 'memory mode');
  })();

  /* W140: a write refused as not allowed left Can change and every button on. */
  await (async function () {
    const server = standardServer({ void: { ok: false, err: 'not_allowed', message: 'Not authorised.' } });
    const app = boot(server);
    app.open(FULL);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$$('[data-act="contract"]')[0]);
    await settled();
    const voidBtn = app.button('Void contract', app.drawer());
    app.click(voidBtn);
    app.click(voidBtn);
    await settled();
    it('reads the refusal as the write ACE gone: read only, buttons off', function () {
      has(app.text(app.byId('badges')), 'Read only');
      truthy(app.button('Void contract', app.drawer()).disabled, 'the void is off');
    });
    clean(app, 'not allowed');
  })();

  /* A05, W199: the second click saves only what the first one named. */
  await (async function () {
    const view = settingsView();
    view.data.limits.push({ key: 'Ledger.PhotoRetentionDays', group: 'Ledger',
      label: 'Days an unopened kill photo is kept (0 forever)', kind: 'number', integer: true, min: 0, max: 365,
      live: true, value: 30, default: 30, source: 'config',
      destroys: 'Lowered to %s, every unopened kill photo older than %s day(s) is deleted at the next sweep, for good.' });
    view.data.limits.push({ key: 'Cooldowns.load.burst', group: 'Rate limits', label: 'load: requests held',
      kind: 'number', integer: true, min: 1, max: 200, live: true, value: 20, default: 20, source: 'config',
      about: 'Every read the app makes of its own state.', stricter: 'down',
      strict: 'Holding %s: players are refused sooner.' });
    const app = boot(standardServer({ settings: view }));
    app.open(FULL);
    await settled();
    app.nav('settings');
    await settled();
    app.click(app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-value') === 'limits'; })[0]);
    const row = function (key) { return app.byId('st-row-' + key); };
    const sets = app.requests('setSetting').length;
    app.type(row('Ledger.PhotoRetentionDays').querySelector('input'), '9');
    app.click(app.button('Save', row('Ledger.PhotoRetentionDays')));
    await settled();
    app.type(row('Ledger.PhotoRetentionDays').querySelector('input'), '1');
    app.click(app.byId('st-save-Ledger.PhotoRetentionDays'));
    await settled();
    it('a value typed after arming arms again, with its own words', function () {
      eq(app.requests('setSetting').length, sets, 'nothing saved');
      has(app.text(row('Ledger.PhotoRetentionDays')), 'Lowered to 1, every unopened kill photo');
      truthy(app.byId('st-save-Ledger.PhotoRetentionDays').classList.contains('is-armed'));
    });
    app.click(app.byId('st-save-Ledger.PhotoRetentionDays'));
    await settled();
    it('and the next click saves that value', function () {
      eq(app.last('setSetting').data, { key: 'Ledger.PhotoRetentionDays', value: 1 });
    });
    const before = app.requests('setSetting').length;
    app.type(row('Cooldowns.load.burst').querySelector('input'), '6');
    app.click(app.button('Save', row('Cooldowns.load.burst')));
    await settled();
    it('a stricter rate limit takes two clicks, saying what it refuses', function () {
      eq(app.requests('setSetting').length, before);
      has(app.text(row('Cooldowns.load.burst')), 'Holding 6: players are refused sooner.');
    });
    app.click(app.byId('st-save-Cooldowns.load.burst'));
    await settled();
    it('(the second saves it)', function () {
      eq(app.last('setSetting').data, { key: 'Cooldowns.load.burst', value: 6 });
    });
    clean(app, 'two clicks');
  })();

  /* A02: a contract never stored opens as its lines alone. */
  await (async function () {
    const stub = { ok: true, data: { contract: { id: 'ct00000009', neverStored: true },
      escrow: [{ id: 'ct00000009:1', contract: 'ct00000009', slot: 1, portion: 'baseline', source: 'cash',
        amount: 300, state: 'held', raised: 0, parked: false, owes: 300 }],
      hitmen: [], amendments: [], timeline: [], canVoid: false,
      stuck: [{ line: 'ct00000009:1', contract: 'ct00000009', amount: 300, source: 'cash', portion: 'baseline',
        orphan: true, actions: ['return_owner'] }] } };
    const app = boot(standardServer({ contract: stub }));
    app.open(FULL);
    await settled();
    app.nav('stuck');
    await settled();
    app.click(app.$$('button.link').filter(function (b) {
      return b.getAttribute('data-act') === 'contract' && b.getAttribute('data-id') === 'ct00000009';
    })[0]);
    await settled();
    it('a contract never stored opens with its lines and Return to', function () {
      has(app.text(app.drawer()), 'Never stored');
      truthy(app.button('Return to', app.drawer()), 'Return to');
      lacks(app.text(app.drawer()), 'Void contract');
    });
    clean(app, 'never stored');
  })();

  console.log('');
  failures.forEach(function (f) { console.log('FAIL  ' + f); });
  console.log('\n' + passed + ' passed, ' + failures.length + ' failed');
  process.exit(failures.length === 0 ? 0 : 1);
}

main().catch(function (err) {
  failures.push('the suite itself threw\n    ' + (err && err.stack || err));
  console.log('');
  failures.forEach(function (f) { console.log('FAIL  ' + f); });
  console.log('\n' + passed + ' passed, ' + failures.length + ' failed');
  process.exit(1);
});
