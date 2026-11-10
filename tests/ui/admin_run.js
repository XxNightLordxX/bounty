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

const ROOT = path.join(__dirname, '..', '..', 'crimson-hitman', 'ui');
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
const CONFIG_LUA = fs.readFileSync(path.join(__dirname, '..', '..', 'crimson-hitman', 'config', 'config.lua'), 'utf8');
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

const PERMISSIONS = [
  { ace: 'crimson.admin', name: 'Staff ACE (Config.Admin.Ace)', held: true, unlocks: 'Opens this panel.',
    grant: 'Grant it with add_ace group.admin crimson.admin allow, pasted into the server console.' },
  { ace: 'crimson.identity', name: 'Identity ACE (Config.Admin.IdentityAce)', held: false,
    unlocks: 'Shows who is behind an anonymous party.',
    grant: 'Grant it with add_ace identifier.license:<their licence> crimson.identity allow for one person.' },
  { ace: 'crimson.developer', name: 'Developer ACE (Config.Admin.DeveloperAce)', held: false,
    unlocks: 'Opens the Developer section.', grant: 'Grant it with add_ace group.admin crimson.developer allow.' },
  { ace: 'crimson.moderator', name: 'Moderator ACE (Config.Admin.ModeratorAce)', held: false,
    unlocks: 'Opens this panel to read, and to freeze, suspend, protect, void and move a deadline.',
    grant: 'Grant it with add_ace group.moderator crimson.moderator allow.' }
];

function access(extra) {
  return Object.assign({ canWrite: true, canIdentify: true, pageSize: 25, refreshSeconds: 10,
    recovery: 'ready', version: '1.1.0', canDevelop: true, developerAce: 'crimson.developer',
    permissions: PERMISSIONS }, extra || {});
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
      target: identity ? { name: 'Dana Reyes', cid: 'TARGET01' } : { name: 'Dana Reyes' },
      // The handover's meeting point, sent with the identity ACE alone.
      meeting: identity ? { x: 1234, y: -568 } : undefined },
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
    player: { cid: 'TARGET01', name: 'Dana Reyes', online: true, server: 12, ref: 'p7_424242' },
    contracts: [{ id: 'ct00000001', state: 'accepted', role: 'target', anonymous: false, target: 'Dana Reyes',
                  created_at: NOW - 3600, resolution: null }],
    stats: { completed: 4, failed: 1, placed: 2, survived: 3, rate: 80, standing: 'Unproven' },
    owed: [{ id: 'ct00000005:2', contract: 'ct00000005', source: 'cash', amount: 700, state: 'held',
             owes: 700, queued: true, parked: false }],
    pending: 1,
    notices: { count: 2, titles: ['Contract closed', XSS] },
    playtime: { hours: 1.5, grandfathered: false, counted: true, counting: true, floor: 5, from: 'tracker' }
  } };
}

function settingsView(extra) {
  return { ok: true, data: Object.assign({
    features: [
      { key: 'Sources.cash.enabled', category: 'features', group: 'Rewards', label: 'Cash rewards', about: 'Cash may be put up.',
        kind: 'switch', live: true, inflight: 'Things already under way finish under the rules they started with.',
        value: true, default: true, source: 'config' },
      { key: 'Bailout.Enabled', category: 'features', group: 'Buyouts', label: 'Buyouts', about: 'A target may pay.', kind: 'switch',
        live: true, inflight: 'A buyout already paid still closes the contract.', value: false, default: true,
        shipped: true, hasShipped: true,
        source: 'panel', by: 'ADMIN001', at: NOW - 300 },
      { key: 'App.DefaultInstalled', category: 'features', group: 'The app', label: 'Put the app on every home screen', kind: 'switch',
        live: false, inflight: 'Applies after restart.', value: false, default: false, source: 'config' },
      { key: 'Completion.Fulfilment', category: 'rules-limits', group: 'Completion', label: 'How contracts are completed', kind: 'choice',
        choices: ['alive', 'either'], live: true, inflight: 'Each contract keeps its rule.', value: 'alive',
        default: 'alive', source: 'config' },
      { key: 'Relay.Enabled', category: 'features', group: 'Messages and calls', label: 'Messages ' + XSS, kind: 'switch', live: true,
        value: true, default: true, source: 'config', ignored: 'has to be on or off' },
      { key: 'Completion.KillPhotos', category: 'features', group: 'Completion', label: 'Kill photos', kind: 'switch', live: true,
        inflight: 'Read at the next Verify kill, with no restart.', value: false, default: false,
        source: 'config' },
      { key: 'Completion.PhotoStorage', category: 'developer', group: 'Completion', label: 'Where kill photos are kept',
        kind: 'choice', choices: ['server', 'host'], live: true, value: 'server', default: 'server',
        source: 'config', inflight: 'Photos already kept stay where they are.',
        inactive: 'Does not apply while kill photos are off (Completion.KillPhotos).' }
    ],
    limits: [
      { key: 'Limits.MaxAcceptedPerHitman', category: 'rules-limits', group: 'Contract limits', label: 'Contracts a hitman may hold',
        kind: 'number', integer: true, min: 1, max: 50, live: true, inflight: 'Lowering it never cancels anything.',
        value: 3, default: 3, source: 'config' },
      { key: 'Penalty.MaxFractionOfEscrow', category: 'rules-rewards', money: 'Escrow', group: 'Stakes', label: 'Largest stake, as a share', kind: 'number',
        min: 0, max: 10, live: true, value: 0.5, default: 0.5, source: 'config' },
      { key: 'Advisory.RecipientJobNames', category: 'rules-targeting', group: 'Advisory job lists', label: 'Job names that receive advisories',
        kind: 'list', live: true, value: ['police'], default: [], shipped: ['police', 'sheriff'], hasShipped: true,
        source: 'panel', by: 'ADMIN001', at: NOW - 60 },
      { key: 'Notifications.ParanoidAlertJitter', category: 'rules-timers', group: 'Notifications',
        label: 'Wait before "eyes on you" (s, from-to)', kind: 'range', integer: true, min: 0, max: 86400, live: true,
        inflight: 'Read each time it is used.', value: { min: 60, max: 600 }, default: { min: 60, max: 600 },
        shipped: { min: 60, max: 600 }, hasShipped: true, source: 'config' },
      { key: 'Bailout.Command', category: 'rules-limits', group: 'Buyouts', label: 'Buyout command', kind: 'text',
        live: false, inflight: 'Read once at start: kept now, and in force after the next restart.',
        value: 'cleanse', default: 'cleanse', shipped: 'cleanse', hasShipped: true, source: 'config' },
      { key: 'Cooldowns.create.per', category: 'developer', group: 'Rate limits', label: 'create: refill window (s)',
        about: 'Placing a contract. A full allowance refills over this many seconds: longer is stricter.',
        kind: 'number', min: 0.5, max: 3600, live: true, inflight: 'Read each time it is used.', stricter: 'up',
        value: 60, default: 60, shipped: 60, hasShipped: true, source: 'config' },
      { key: 'Cooldowns.create.burst', category: 'developer', group: 'Rate limits', label: 'create: requests held',
        about: 'Placing a contract. How many it allows at once.', kind: 'number', integer: true, min: 1, max: 200,
        live: true, inflight: 'Read each time it is used.', stricter: 'down', value: 2, default: 2, shipped: 2,
        hasShipped: true, source: 'config' }
    ],
    readonly: [
      { key: 'Admin.Enabled', category: 'developer', group: 'Staff', label: 'Staff tools', kind: 'switch', live: true,
        readonly: 'Turning the staff tools off from the staff tools would lock you out.', value: true,
        default: true, source: 'config' },
      { key: 'Cooldowns.admin.burst', category: 'developer', group: 'Staff', label: 'admin: requests held', kind: 'number',
        integer: true, min: 1, max: 200, live: true, value: 30, default: 30, source: 'config',
        readonly: 'The staff panel\'s own allowance, which every request it makes spends.',
        ignored: 'The staff panel\'s own allowance, which every request it makes spends.' },
      { key: 'convar:crimson_hitman_webhook', category: 'developer', group: 'Edit in config.lua',
        label: 'Secret: crimson_hitman_webhook', kind: 'text', denied: true, secret: true, value: 'set',
        readonly: 'The Discord webhook for the log: a secret, set in server.cfg with set (never setr).',
        source: 'config' }
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
    flush: { ok: true, message: 'Audit log flushed: 4 row(s) written.', data: { written: 4 } },
    setPlaytime: function (data) {
      return { ok: true, message: 'Dana Reyes\'s counted playtime is now ' + data.hours + ' h (it was 1.5 h).',
        data: { playtime: { hours: data.hours, grandfathered: false, counted: true, counting: true, floor: 5,
          from: 'tracker' } } };
    }
  }, extra || {});
}

/* ---------- the page, booted ---------- */

function bodyOf(html) {
  const inner = /<body[^>]*>([\s\S]*)<\/body>/i.exec(html)[1];
  return inner.replace(/<script[\s\S]*?<\/script>/gi, '');
}

function boot(server, opts) {
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
  if (opts && opts.storage) window.localStorage = opts.storage;

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
  /* A test that reads a time the page works out from the clock (the deadline
     preview counts down from when the contract was read) passes
     opts.clock = { ms }: the page's Date then reads that and only that, so a
     second rolling over between the read and the assertion cannot change
     what it draws. The test moves the clock itself when it means to. */
  if (opts && opts.clock) {
    const clock = opts.clock;
    sandbox.Date = class FixedDate extends Date {
      constructor(...args) { if (args.length) super(...args); else super(clock.ms); }
      static now() { return clock.ms; }
    };
  }
  vm.createContext(sandbox);
  vm.runInContext(PAGE_JS, sandbox, { filename: 'admin.js' });

  const app = {
    document, sent, urls, timers, thrown, server, window,
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
    /** A view by its sub-tab: the old Features & limits is Features now,
        its limits under Rules, its read-only values under Developer. */
    nav: function (section) {
      const view = { settings: 'features' }[section] || section;
      app.click(document.getElementById('nav-' + view));
    }
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
    // The same answer again: only its Updated time is written, not the
    // whole overview rebuilt every ten seconds the panel stands open.
    const ovClears = app.byId('ov')._clears || 0;
    app.fire(10000);
    await settled();
    it('draws the overview again only when its answer changed', function () {
      eq((app.byId('ov')._clears || 0) - ovClears, 0, 'rebuilds for the same answer');
      has(app.byId('ov-at').textContent, 'Updated');
      has(app.byId('ov-at').textContent, 'refreshes every 10 s');
    });
    const sameServer = app.server.overview;
    app.server.overview = function (body) {
      const answer = JSON.parse(JSON.stringify(typeof sameServer === 'function' ? sameServer(body) : sameServer));
      if (answer && answer.data) { answer.data.overrides = (Number(answer.data.overrides) || 0) + 7; }
      return answer;
    };
    app.fire(10000);
    await settled();
    it('and does when it changed', function () {
      eq((app.byId('ov')._clears || 0) - ovClears, 1, 'rebuilds for a new answer');
    });
    app.server.overview = sameServer;
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
    it('without identity the log\'s citizen id filter is open, and says it finds only rows under their own name', function () {
      const input = app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'lg.actor'; })[0];
      falsy(input.disabled, 'disabled');
      has(app.main(), 'A citizen id finds only the rows that player acted in under their own name.');
      app.type(input, 'ABC12345');
      app.fire(350);
    });
    await settled();
    it('(and the server is asked, which keeps the rows they acted in anonymously out)', function () {
      eq(app.last('logs').data.actor, 'ABC12345');
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
    it('with identity: and the meeting point the server sent, where the client stood', function () {
      has(app.text(app.drawer()), 'Meeting point');
      has(app.text(app.drawer()), 'x 1234, y -568');
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
    const visits = ['contracts', 'reviews', 'logs', 'features', 'limits', 'devsettings', 'help', 'permissions'];
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
      lacks(text, 'Meeting point', 'no meeting point line where the server sent none');
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
    // Kept without a good's metadata, which was too big for the store.
    const answer = reviews();
    answer.data.items[1].items = [
      { id: 'ct00000002:4', source: 'item', item: 'lockpick', quantity: 2, metadata_omitted: true },
      { id: 'ct00000002:5', source: 'weapon', item: 'WEAPON_PISTOL', quantity: 1 }];
    const app = boot(standardServer({ reviews: answer }));
    app.open(ADMIN);
    await settled();
    app.nav('reviews');
    await settled();
    it('says which goods were kept without their metadata, before anybody gives them', function () {
      const card = app.text(app.byId('rv-rv00000002'));
      has(card, '2 × lockpick (without its metadata)');
      has(card, 'WEAPON_PISTOL (weapon)');
      lacks(card, 'WEAPON_PISTOL (weapon) (without', 'the weapon kept whole says nothing');
      has(card, '1 of its goods were kept without their metadata');
      lacks(app.text(app.byId('rv-rv00000001')), 'without their metadata', 'nor does an item that kept all of it');
    });
    clean(app, 'reviews, metadata left out');
  })();

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

    const testAlert = app.button('Send a test alert');
    app.click(testAlert);
    await settled();
    it('a test alert takes two clicks too: the first arms it and sends nothing (sweep 5 F3)', function () {
      eq(app.requests('testAlert').length, 0);
      truthy(testAlert.classList.contains('is-armed'));
      has(app.text(testAlert), 'Click again to send it');
    });
    app.click(testAlert);
    await settled();
    it('the second sends it, and says what came of it', function () {
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

  /* ---- a player's playtime ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(ADMIN);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('shows the hours counted, what is needed and whether they are from before the count', function () {
      const text = app.main();
      has(text, 'Playtime');
      has(text, '1.5 h');
      has(text, 'Needed to be a target');
      has(text, 'From before the count');
      has(text, 'Too new to be named as a target until the count reaches 5 h.');
      has(text, 'in the city: counting');
    });
    app.type(app.byId('pl-q'), 'SOMEONE2');
    app.type(app.byId('pl-hours'), '6');
    app.click(app.button('Set hours'));
    await settled();
    it('takes two clicks to set, and sends nothing on the first', function () {
      eq(app.requests('setPlaytime').length, 0);
    });
    app.click(app.button('Set hours'));
    await settled();
    it('sends the hours for the player as they were looked up, not what the box says now', function () {
      eq(app.last('setPlaytime').data, { ref: 'p7_424242', hours: 6 });
      has(app.main(), 'Dana Reyes\'s counted playtime is now 6 h (it was 1.5 h).');
      has(app.main(), 'Enough to be named as a target.', 'the card shows what the server answered');
    });
    app.click(app.button('Reset to 0'));
    app.click(app.button('Reset to 0'));
    await settled();
    it('resets to 0 with two clicks', function () {
      eq(app.last('setPlaytime').data, { ref: 'p7_424242', hours: 0 });
    });
    const before = app.requests('setPlaytime').length;
    app.type(app.byId('pl-hours'), '-3');
    app.click(app.button('Set hours'));
    await settled();
    it('refuses hours that are not 0 or more, saying so and sending nothing', function () {
      eq(app.requests('setPlaytime').length, before);
      has(app.main(), 'Hours are a number from 0 to 100000.');
    });
    clean(app, 'playtime');
  })();

  await (async function () {
    const answer = player();
    answer.data.playtime = { hours: 0, grandfathered: true, counted: true, counting: false, floor: 5,
      from: 'tracker' };
    const app = boot(standardServer({ player: answer }));
    app.open(READER);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('says a character from before counts as having played enough where the tracker is what the rule reads', function () {
      has(app.main(), 'they count as having played enough, whatever the hours say');
      lacks(app.main(), 'not these hours');
    });
    clean(app, 'playtime, grandfathered');
  })();

  await (async function () {
    const answer = player();
    answer.data.playtime = { hours: 0, grandfathered: true, counted: true, counting: false, floor: 5,
      from: 'metadata' };
    const app = boot(standardServer({ player: answer }));
    app.open(READER);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('where the rule reads elsewhere, says so and nothing about these hours deciding', function () {
      has(app.main(), 'The new-player rule reads their QBox metadata for them, not these hours.');
      lacks(app.main(), 'played enough');
      lacks(app.main(), 'Too new to be named');
      lacks(app.main(), 'Enough to be named');
    });
    it('read-only staff see Set and Reset disabled', function () {
      eq(app.button('Set hours', app.byId('main')).disabled, true);
      eq(app.button('Reset to 0', app.byId('main')).disabled, true);
    });
    clean(app, 'playtime, read only');
  })();

  /* ---- settings: Rules, Features, Developer ---- */
  await (async function () {
    const server = standardServer();
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('features');
    await settled();
    it('Features lists the switches by group, each with its value, config.lua\'s and where it comes from', function () {
      const text = app.main();
      ['Rewards', 'Buyouts', 'The app', 'Completion'].forEach(function (g) { has(text, g); });
      has(text, 'Config.Bailout.Enabled');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'changed from the panel');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'config.lua: On');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'Now: Off');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'default: On');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'set by ADMIN001');
      has(app.text(app.byId('st-row-App.DefaultInstalled')), 'applies after restart');
      has(app.text(app.byId('st-row-Relay.Enabled')), 'not applied');
      has(app.text(app.byId('st-row-Sources.cash.enabled')), 'Under way:');
      lacks(app.text(app.byId('st-row-Completion.KillPhotos')), 'does not apply now',
        'and the switch itself does not');
      falsy(app.byId('st-row-Completion.Fulfilment'), 'a choice is a rule, not a switch');
      falsy(app.byId('st-row-Limits.MaxAcceptedPerHitman'), 'and a number is not here either');
    });
    it('each feature group says in one line what it controls', function () {
      has(app.text(app.$('.st-group[data-group="buyouts"]')), 'Whether a target may buy a contract out.');
    });
    it('every switch here carries a second-click confirm naming its new value (sweep 5 F3)', function () {
      const switches = app.$$('.switch');
      truthy(switches.length > 3, 'switches drawn');
      switches.forEach(function (sw) {
        eq(sw.getAttribute('data-confirm'), 'yes', sw.getAttribute('data-key'));
        const on = sw.getAttribute('aria-checked') === 'true';
        has(app.text(sw.querySelector('.cfm')), 'Click again: turn ' + (on ? 'Off' : 'On'), sw.getAttribute('data-key'));
      });
    });
    const setsBefore = app.requests('setSetting').length;
    const cashSwitch = app.byId('st-row-Sources.cash.enabled').querySelector('.switch');
    app.click(cashSwitch);
    await settled();
    it('a switch takes two clicks: the first arms it, naming the new value, and sends nothing (sweep 5 F3)',
      function () {
        eq(app.requests('setSetting').length, setsBefore);
        truthy(cashSwitch.classList.contains('is-armed'));
        has(app.text(cashSwitch.querySelector('.cfm')), 'Click again: turn Off');
      });
    app.click(cashSwitch);
    await settled();
    it('the second turns the feature off and shows the answer', function () {
      eq(app.last('setSetting').data, { key: 'Sources.cash.enabled', value: false });
      has(app.toasts(), 'Sources.cash.enabled is now false.');
      has(app.text(app.byId('st-row-Sources.cash.enabled')), 'Sources.cash.enabled is now false.');
      truthy(app.requests('settings').length >= 2, 'the settings are read again');
    });
    app.click(app.byId('st-row-Bailout.Enabled').querySelector('.switch'));
    it('armed to turn it On', function () {
      has(app.text(app.byId('st-row-Bailout.Enabled').querySelector('.switch.is-armed')), 'Click again: turn On');
    });
    app.click(app.byId('st-row-Bailout.Enabled').querySelector('.switch'));
    await settled();
    it('and back on', function () {
      eq(app.last('setSetting').data, { key: 'Bailout.Enabled', value: true });
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
    const sets0 = app.requests('setSetting').length;
    const toDefault = app.button('Reset to default', app.byId('st-row-Bailout.Enabled'));
    app.click(toDefault);
    await settled();
    it('Reset to default shows where the value is not the shipped one, and takes two clicks', function () {
      eq(app.requests('setSetting').length, sets0);
      truthy(toDefault.classList.contains('is-armed'));
      has(app.text(toDefault), 'Click again: back to On');
      lacks(app.text(app.byId('st-row-Sources.cash.enabled')), 'Reset to default', 'not where they are the same');
    });
    app.click(toDefault);
    await settled();
    it('and the second sets the shipped value through the ordinary change', function () {
      eq(app.requests('setSetting').length, sets0 + 1);
      eq(app.last('setSetting').data, { key: 'Bailout.Enabled', value: true });
    });

    app.nav('limits');
    await settled();
    const either = function () {
      return app.byId('st-row-Completion.Fulfilment').querySelectorAll('.seg-btn')
        .filter(function (b) { return b.getAttribute('data-value') === 'either'; })[0];
    };
    it('every choice not chosen and every Save here carries a second-click confirm (sweep 5 F3)', function () {
      const choices = app.$$('.seg-btn').filter(function (b) {
        return b.getAttribute('data-act') === 'st-choice' && b.getAttribute('aria-pressed') !== 'true';
      });
      truthy(choices.length > 0, 'choices drawn');
      choices.forEach(function (b) {
        has(app.text(b.querySelector('.cfm')), 'Click again: ' + b.getAttribute('data-value'));
      });
      const saves = app.$$('button').filter(function (b) { return b.getAttribute('data-act') === 'st-save'; });
      truthy(saves.length > 0, 'Saves drawn');
      saves.forEach(function (b) { eq(b.getAttribute('data-confirm'), 'yes', b.getAttribute('data-key')); });
    });
    const setsChoice = app.requests('setSetting').length;
    app.click(either());
    await settled();
    it('a choice takes two clicks: the first arms it, naming the choice (sweep 5 F3)', function () {
      eq(app.requests('setSetting').length, setsChoice);
      truthy(either().classList.contains('is-armed'));
      has(app.text(either().querySelector('.cfm')), 'Click again: either');
    });
    app.click(either());
    await settled();
    it('Rules: Limits has the choices, and a choice sets one of its choices', function () {
      eq(app.last('setSetting').data, { key: 'Completion.Fulfilment', value: 'either' });
    });
    it('a key read once at start says it applies after a restart', function () {
      has(app.text(app.byId('st-row-Bailout.Command')), 'applies after restart');
      truthy(app.byId('st-row-Bailout.Command').querySelector('.is-restart'), 'as a badge');
    });
    app.type(app.byId('st-row-Bailout.Command').querySelector('input'), 'buyout');
    const setsText = app.requests('setSetting').length;
    app.click(app.button('Save', app.byId('st-row-Bailout.Command')));
    await settled();
    it('a Save takes two clicks: the first arms it, naming the value it saves (sweep 5 F3)', function () {
      eq(app.requests('setSetting').length, setsText);
      const save = app.byId('st-save-Bailout.Command');
      truthy(save.classList.contains('is-armed'));
      has(app.text(save.querySelector('.cfm')), 'Click again: save buyout');
    });
    app.click(app.button('Save', app.byId('st-row-Bailout.Command')));
    await settled();
    it('a text key goes as the word typed', function () {
      eq(app.last('setSetting').data, { key: 'Bailout.Command', value: 'buyout' });
    });
    const limit = app.byId('st-row-Limits.MaxAcceptedPerHitman');
    app.type(limit.querySelector('input'), '0');
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
    app.click(app.button('Save', app.byId('st-row-Limits.MaxAcceptedPerHitman')));
    await settled();
    it('a number goes as a number, and the start-up checks\' refusal is shown on its row', function () {
      eq(app.last('setSetting').data, { key: 'Limits.MaxAcceptedPerHitman', value: 1 });
      has(app.text(app.byId('st-row-Limits.MaxAcceptedPerHitman')), 'above what the start allows');
    });
    server.setSetting = standardServer().setSetting;

    app.nav('money');
    await settled();
    it('Rewards & money groups each money setting under its money group', function () {
      has(app.text(app.$('.st-group[data-group="escrow"]')), 'Largest stake, as a share');
    });
    app.type(app.byId('st-row-Penalty.MaxFractionOfEscrow').querySelector('input'), '0.75');
    app.click(app.button('Save', app.byId('st-row-Penalty.MaxFractionOfEscrow')));
    app.click(app.button('Save', app.byId('st-row-Penalty.MaxFractionOfEscrow')));
    await settled();
    it('a fraction goes where the key takes one', function () {
      eq(app.last('setSetting').data, { key: 'Penalty.MaxFractionOfEscrow', value: 0.75 });
    });

    // A job list: names added and removed, saved on the second click.
    app.nav('targeting');
    await settled();
    const jobs = function () { return app.byId('st-row-Advisory.RecipientJobNames'); };
    app.type(jobs().querySelector('input'), 'sheriff');
    app.click(app.button('Add', jobs()));
    app.type(jobs().querySelector('input'), 'bcso');
    app.key(jobs().querySelector('input'), 'Enter');
    await settled();
    it('a list adds names to what is being edited, and sends nothing yet', function () {
      has(app.text(jobs()), 'sheriff');
      has(app.text(jobs()), 'bcso');
      eq(app.requests('setSetting').filter(function (r) { return r.data.key === 'Advisory.RecipientJobNames'; }).length, 0);
    });
    app.click(jobs().querySelectorAll('button[data-act="st-list-del"]')
      .filter(function (b) { return b.getAttribute('data-value') === 'police'; })[0]);
    await settled();
    it('and removes one', function () {
      eq(jobs().querySelectorAll('button[data-act="st-list-del"]').map(function (b) {
        return b.getAttribute('data-value');
      }), ['sheriff', 'bcso']);
    });
    const listSets = app.requests('setSetting').length;
    app.click(app.byId('st-save-Advisory.RecipientJobNames'));
    await settled();
    it('saving a list takes two clicks', function () {
      eq(app.requests('setSetting').length, listSets);
      truthy(app.byId('st-save-Advisory.RecipientJobNames').classList.contains('is-armed'));
    });
    app.click(app.byId('st-save-Advisory.RecipientJobNames'));
    await settled();
    it('and the second sends the list as names', function () {
      eq(app.last('setSetting').data, { key: 'Advisory.RecipientJobNames', value: ['sheriff', 'bcso'] });
    });
    server.setSetting = { ok: false, err: 'invalid_value',
      message: 'Not changed: Advisory.RecipientJobNames names letters, digits, - and _ only, up to 32 long.' };
    app.type(jobs().querySelector('input'), 'bad name!');
    app.click(app.button('Add', jobs()));
    app.click(app.byId('st-save-Advisory.RecipientJobNames'));
    app.click(app.byId('st-save-Advisory.RecipientJobNames'));
    await settled();
    it('a bad name is the server\'s to refuse, and its refusal shows on the row', function () {
      has(app.text(jobs()), 'names letters, digits, - and _ only');
    });
    server.setSetting = standardServer().setSetting;

    // A from-to pair.
    app.nav('timers');
    await settled();
    const jitter = function () { return app.byId('st-row-Notifications.ParanoidAlertJitter'); };
    const inputs = jitter().querySelectorAll('input');
    app.type(inputs[0], '900');
    app.type(inputs[1], '100');
    const rangeSets = app.requests('setSetting').length;
    app.click(app.byId('st-save-Notifications.ParanoidAlertJitter'));
    await settled();
    it('a pair with its from above its to is refused before it is sent', function () {
      eq(app.requests('setSetting').length, rangeSets);
      has(app.text(jitter()), 'has its from above its to');
    });
    app.type(jitter().querySelectorAll('input')[0], '30');
    app.type(jitter().querySelectorAll('input')[1], '300');
    app.click(app.byId('st-save-Notifications.ParanoidAlertJitter'));
    app.click(app.byId('st-save-Notifications.ParanoidAlertJitter'));
    await settled();
    it('and a good one goes as from and to, on the second click', function () {
      eq(app.last('setSetting').data, { key: 'Notifications.ParanoidAlertJitter', value: { min: 30, max: 300 } });
    });

    // Search: label, key, description and group.
    app.nav('limits');
    await settled();
    app.type(app.byId('st-q'), 'hitman may hold');
    it('the search finds a label', function () {
      eq(app.byId('st-row-Limits.MaxAcceptedPerHitman').hidden, false);
      eq(app.byId('st-row-Completion.Fulfilment').hidden, true);
    });
    app.type(app.byId('st-q'), 'completion.fulf');
    it('a key', function () {
      eq(app.byId('st-row-Completion.Fulfilment').hidden, false);
      eq(app.byId('st-row-Limits.MaxAcceptedPerHitman').hidden, true);
    });
    app.type(app.byId('st-q'), 'contract limits');
    it('a group', function () {
      eq(app.byId('st-row-Limits.MaxAcceptedPerHitman').hidden, false);
      eq(app.byId('st-row-Completion.Fulfilment').hidden, true);
    });
    app.nav('features');
    await settled();
    it('and keeps what was typed from section to section', function () {
      eq(app.byId('st-q').value, 'contract limits');
      eq(app.byId('st-none').hidden, false, 'saying nothing matches');
    });
    app.type(app.byId('st-q'), 'cash may be put');
    it('and a description', function () {
      eq(app.byId('st-row-Sources.cash.enabled').hidden, false);
      eq(app.byId('st-row-Bailout.Enabled').hidden, true);
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

    app.nav('devsettings');
    await settled();
    it('Developer holds the read-only values: one shows why, and no control', function () {
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
    it('a secret shows as set or not, never its value, with edit in config.lua', function () {
      const row = app.byId('st-row-convar:crimson_hitman_webhook');
      has(app.text(row), 'edit in config.lua');
      has(app.text(row), 'set');
      eq(row.querySelectorAll('input').length, 0);
    });
    it('a key whose switch is off says so beside it', function () {
      has(app.text(app.byId('st-row-Completion.PhotoStorage')), 'does not apply now');
      has(app.text(app.byId('st-row-Completion.PhotoStorage')), 'Does not apply while kill photos are off');
    });
    it('a rate limit is one row with its per and burst', function () {
      const row = app.byId('st-map-create');
      truthy(row, 'the map row');
      eq(row.querySelectorAll('input').length, 2);
      falsy(app.byId('st-row-Cooldowns.create.per'), 'not two rows');
    });
    app.type(app.byId('st-map-create').querySelectorAll('input')[1], '1');
    const mapSets = app.requests('setSetting').length;
    app.click(app.byId('st-save-Cooldowns.create'));
    await settled();
    it('saving a rate limit takes two clicks', function () { eq(app.requests('setSetting').length, mapSets); });
    app.click(app.byId('st-save-Cooldowns.create'));
    await settled();
    it('and sends only what changed, as its own setting', function () {
      eq(app.requests('setSetting').length, mapSets + 1);
      eq(app.last('setSetting').data, { key: 'Cooldowns.create.burst', value: 1 });
    });
    clean(app, 'settings');
  })();

  /* ---- the sections ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(ADMIN);
    await settled();
    const views = ['help', 'overview', 'contracts', 'players', 'frozen', 'reviews', 'stuck', 'actions', 'tools',
      'timers', 'money', 'limits', 'targeting', 'features', 'logs', 'alerts', 'devsettings', 'console',
      'diagnostics', 'permissions'];
    it('seven sections, in order, each a button (Target limits after Rules)', function () {
      eq(app.$$('.nav-btn').map(function (b) { return b.getAttribute('data-group'); }),
        ['live', 'actions', 'rules', 'targets', 'features', 'logs', 'developer']);
    });
    app.click(app.byId('grp-rules'));
    await settled();
    it('a section opens on its first sub-tab, showing only its own', function () {
      eq(app.byId('nav-timers').getAttribute('aria-current'), 'page');
      eq(app.byId('nav-money').hidden, false);
      eq(app.byId('nav-overview').hidden, true);
    });
    const reached = [];
    for (const view of views) {
      app.nav(view);
      await settled();
      if (app.byId('nav-' + view).getAttribute('aria-current') === 'page' && app.main().length > 20) reached.push(view);
    }
    it('every view the panel had is still a sub-tab, and the new ones too', function () {
      eq(reached, views);
    });
    app.nav('limits');
    await settled();
    app.click(app.byId('grp-live'));
    await settled();
    app.click(app.byId('grp-rules'));
    await settled();
    it('and on the one last open in it after', function () {
      eq(app.byId('nav-limits').getAttribute('aria-current'), 'page');
    });
    app.click(app.byId('grp-features'));
    await settled();
    it('a section of one view has no strip of sub-tabs', function () { eq(app.byId('subnav').hidden, true); });
    clean(app, 'the sections');
  })();

  await (async function () {
    const kept = {};
    const storage = { getItem: function (k) { return k in kept ? kept[k] : null; },
                      setItem: function (k, v) { kept[k] = String(v); } };
    const first = boot(standardServer(), { storage: storage });
    first.open(ADMIN);
    await settled();
    first.nav('targeting');
    await settled();
    const again = boot(standardServer(), { storage: storage });
    again.open(ADMIN);
    await settled();
    it('the last section and sub-tab are remembered in this browser', function () {
      eq(again.byId('nav-targeting').getAttribute('aria-current'), 'page');
      eq(again.byId('grp-rules').getAttribute('aria-current'), 'page');
    });
    const broken = boot(standardServer(), { storage: { getItem: function () { throw new Error('denied'); },
      setItem: function () { throw new Error('denied'); } } });
    broken.open(ADMIN);
    await settled();
    it('and storage that throws is no storage, never a fault', function () {
      eq(broken.byId('nav-overview').getAttribute('aria-current'), 'page');
      clean(broken, 'storage that throws');
    });
  })();

  /* ---- The developer ACE without the staff ACE: its own section's settings ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(access({ canWrite: false, canIdentify: false, canDevelop: true }));
    await settled();
    app.nav('devsettings');
    await settled();
    it('the developer ACE alone can change a Developer setting', function () {
      app.$$('.seg-btn').filter(function (b) {
        return b.getAttribute('data-act') === 'st-choice' && b.getAttribute('data-key') === 'Completion.PhotoStorage';
      }).forEach(function (b) { eq(!!b.disabled, false, 'choice ' + b.getAttribute('data-value')); });
      eq(!!app.byId('st-save-Cooldowns.create').disabled, false);
      eq(app.byId('st-row-convar:crimson_hitman_webhook').querySelectorAll('input').length, 0,
        'never a denied one');
    });
    app.type(app.byId('st-map-create').querySelectorAll('input')[1], '1');
    const sets = app.requests('setSetting').length;
    app.click(app.byId('st-save-Cooldowns.create'));
    await settled();
    app.click(app.byId('st-save-Cooldowns.create'));
    await settled();
    it('and sends it', function () {
      eq(app.requests('setSetting').length, sets + 1);
      eq(app.last('setSetting').data, { key: 'Cooldowns.create.burst', value: 1 });
    });
    app.nav('features');
    await settled();
    it('but no setting of any other section', function () {
      app.$$('.switch').forEach(function (b) { eq(b.disabled, true, 'switch ' + b.getAttribute('data-key')); });
    });
    clean(app, 'developer ACE alone');
  })();

  /* ---- Developer, and Permissions ---- */
  await (async function () {
    const server = standardServer();
    const app = boot(server);
    app.open(access({ canWrite: false, canIdentify: false, canDevelop: false,
      permissions: PERMISSIONS.map(function (p) { return Object.assign({}, p, { held: p.ace === 'crimson.admin' }); }) }));
    await settled();
    it('without the developer ACE the section is Permissions alone', function () {
      has(app.text(app.byId('grp-developer')), 'Permissions & history');
      lacks(app.text(app.byId('grp-developer')), 'Developer');
    });
    app.click(app.byId('grp-developer'));
    await settled();
    it('with no console, diagnostics or developer settings in it', function () {
      eq(app.byId('nav-console').hidden, true);
      eq(app.byId('nav-devsettings').hidden, true);
      eq(app.byId('nav-diagnostics').hidden, true);
      eq(app.byId('nav-permissions').getAttribute('aria-current'), 'page');
    });
    app.nav('console');
    await settled();
    it('and a developer view asked for anyway is Permissions, with nothing asked of the server', function () {
      eq(app.byId('nav-permissions').getAttribute('aria-current'), 'page');
      eq(app.requests('console').length, 0);
    });
    it('Permissions lists each ACE, whether it is held, and how to grant one that is not', function () {
      const rows = app.$$('.perm-row');
      eq(rows.map(function (r) { return r.getAttribute('data-ace'); }),
        ['crimson.admin', 'crimson.identity', 'crimson.developer', 'crimson.moderator']);
      has(app.text(rows[0]), 'You hold it');
      has(app.text(rows[1]), 'You do not hold it');
      has(app.text(rows[2]), 'add_ace group.admin crimson.developer allow');
      lacks(app.text(rows[0]), 'To grant it');
    });
    it('and has nothing on it that changes anything', function () {
      eq(app.byId('main').querySelectorAll('input').length, 0);
      eq(app.byId('main').querySelectorAll('button').length, 0);
    });
    clean(app, 'permissions');

    const owner = boot(standardServer());
    owner.open(access({ developerByAce: false,
      developerHint: 'To give the Developer section to its own people: grant it with add_ace group.admin crimson.developer allow.' }));
    await settled();
    owner.nav('devsettings');
    await settled();
    it('the staff ACE still sees Developer, with one line on granting its own ACE', function () {
      has(owner.main(), 'add_ace group.admin crimson.developer allow');
    });
    clean(owner, 'developer through the staff ACE');
  })();

  /* ---- How it works ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(ADMIN);
    await settled();
    app.nav('help');
    await settled();
    const help = app.window.CH_ADMIN_HELP;
    it('How it works is a card per subject, each three to six sentences', function () {
      eq(app.$$('.help-card').length, help.length);
      truthy(help.length >= 8, help.length + ' cards');
      ['lifecycle', 'clock', 'anonymity', 'informant', 'buyout', 'freeze', 'advisor', 'escrow'].forEach(function (w) {
        truthy(help.some(function (c) { return (c.title + ' ' + c.text).toLowerCase().indexOf(w) !== -1
          || (w === 'lifecycle' && /start to finish/.test(c.title)); }), 'a card on ' + w);
      });
      help.forEach(function (c) {
        const n = (c.text.match(/[.!?](\s|$)/g) || []).length;
        truthy(n >= 3 && n <= 6, c.title + ' has ' + n + ' sentences');
      });
    });
    // Every link names the view its key is shown in, as server/settings.lua
    // categorises it.
    const settingsLua = fs.readFileSync(path.join(__dirname, '..', '..', 'crimson-hitman', 'server', 'settings.lua'), 'utf8');
    const VIEW = { 'rules-timers': 'timers', 'rules-rewards': 'money', 'rules-limits': 'limits',
      'rules-targeting': 'targeting', features: 'features', developer: 'devsettings',
      'target-limits': 'tldefaults' };
    const wrong = [];
    help.forEach(function (c) {
      c.links.forEach(function (l) {
        const at = settingsLua.indexOf("key = '" + l.key + "'");
        const cat = at === -1 ? null : /category = '([\w-]+)'/.exec(settingsLua.slice(at, at + 400));
        if (!cat || VIEW[cat[1]] !== l.view) wrong.push(l.key + ' -> ' + l.view + ' (' + (cat && cat[1]) + ')');
      });
    });
    it('every link names the section its setting is in', function () { eq(wrong, []); });
    const link = app.$$('button[data-act="help-jump"]').filter(function (b) {
      return b.getAttribute('data-key') === 'Advisory.RecipientJobNames';
    })[0];
    app.click(link);
    await settled();
    it('and lands on that setting, marked', function () {
      eq(app.byId('nav-targeting').getAttribute('aria-current'), 'page');
      truthy(app.byId('st-row-Advisory.RecipientJobNames').classList.contains('is-focus'));
    });
    clean(app, 'how it works');
  })();

  await (async function () {
    const view = settingsView();
    view.data.limits.push({ key: 'Ledger.PhotoRetentionDays', category: 'rules-timers', group: 'Ledger',
      label: 'Days an unopened kill photo is kept (0 forever)', kind: 'number', integer: true, min: 0, max: 365,
      live: true, inflight: 'Looked at every ten minutes.', value: 30, default: 30, source: 'config',
      destroys: 'Lowered to %s, every unopened kill photo older than %s day(s) is deleted at the next sweep, for good.' });
    const server = standardServer({ settings: view });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('timers');
    await settled();
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
      has(app.text(save.querySelector('.cfm')), 'Click again: save 1');
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
    it('raising it deletes nothing: the row warns of nothing, and Save still takes two clicks', function () {
      eq(app.requests('setSetting').length, sets + 1);
      lacks(app.text(row()), 'Click Save again to do it');
      has(app.text(app.byId('st-save-Ledger.PhotoRetentionDays').querySelector('.cfm')), 'Click again: save 60 d');
      truthy(app.byId('st-save-Ledger.PhotoRetentionDays').classList.contains('is-armed'));
    });
    app.click(app.button('Save', row()));
    await settled();
    it('and the second click saves it', function () {
      eq(app.requests('setSetting').length, sets + 2);
      eq(app.last('setSetting').data, { key: 'Ledger.PhotoRetentionDays', value: 60 });
    });
    app.type(row().querySelector('input'), '0');
    app.key(row().querySelector('input'), 'Enter');
    await settled();
    it('Enter arms 0 (which keeps every photo) and sends nothing', function () {
      eq(app.requests('setSetting').length, sets + 2);
      lacks(app.text(row()), 'Click Save again to do it');
    });
    app.click(app.button('Save', row()));
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
    // Sweep 5 F3: the timed refresh redraws Stuck escrow while a button
    // waits for its second click. The button drawn in its place stays
    // armed, so the next click is the second, not a third.
    const pay = app.button('Pay', item('owe00000003'));
    app.click(pay);
    await settled();
    const settlesArmed = app.requests('settle').length;
    const stuckReads = app.requests('stuck').length;
    app.fire(10000);
    await settled();
    it('the timed refresh redraws the list and keeps the armed button armed (sweep 5 F3)', function () {
      truthy(app.requests('stuck').length > stuckReads, 'the refresh read the list again');
      const again = app.button('Pay', item('owe00000003'));
      truthy(again !== pay, 'the button was drawn again');
      truthy(again.classList.contains('is-armed'), 'and is still armed');
      eq(app.requests('settle').length, settlesArmed, 'nothing sent by the refresh');
    });
    app.click(app.button('Pay', item('owe00000003')));
    await settled();
    it('so the next click is the second, and settles', function () {
      eq(app.requests('settle').length, settlesArmed + 1);
      eq(app.last('settle').data, { line: 'owe00000003', disposition: 'pay' });
    });
    app.click(app.button('Pay amount', item('ct00000005:1')));
    await settled();
    it('Pay amount asks for an amount first, beside the line, and sends nothing', function () {
      eq(app.requests('settle').length, settlesArmed + 1);
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
        for (const section of ['contracts', 'stuck', 'reviews', 'alerts', 'console', 'logs', 'players', 'frozen',
          'actions', 'tools', 'help', 'timers', 'money', 'limits', 'targeting', 'features', 'devsettings',
          'diagnostics', 'permissions']) {
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
        for (const tab of ['features', 'timers', 'money', 'limits', 'targeting', 'devsettings']) {
          app.nav(tab);
          await settled();
          sweep(app, 'settings ' + tab);
        }
        app.nav('features');
        await settled();
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
    const flush = app.button('Flush the audit log');
    app.click(flush);
    await settled();
    it('flushing takes two clicks: the first arms it and writes nothing (sweep 5 F3)', function () {
      eq(app.requests('flush').length, 0);
      truthy(flush.classList.contains('is-armed'));
      has(app.text(flush), 'Click again to flush');
    });
    app.click(flush);
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
    it('Run it runs the diagnosis, under Developer for staff who have it', function () {
      eq(app.byId('nav-diagnostics').getAttribute('aria-current'), 'page');
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
    app.nav('limits');
    await settled();
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

  /* ---- a contract's deadline: Extend and Shorten on its view ---- */
  await (async function () {
    const deadline = { left: 5400, stopped: false, adjustable: true, maxAdjust: 86400, minLeft: 300 };
    const server = standardServer({
      contract: contractDetail({ deadline: deadline }),
      adjustDeadline: function (data) {
        return { ok: true, message: 'Extended by 1 h: 1 h 30 min left before, 2 h 30 min left now.',
          data: { seconds: data.seconds, leftBefore: 5400, leftAfter: 5400 + data.seconds } };
      },
    });
    // The clock stands still unless the test moves it: the preview counts
    // down from the read, and a real second rolling over between the read
    // and an assertion once took a minute off what it drew.
    const clock = { ms: NOW * 1000 + 999 };
    const app = boot(server, { clock: clock });
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    const drawer = app.drawer();
    it('the contract view shows the exact time left, with Extend, Shorten and the quick picks', function () {
      has(app.text(drawer), 'Deadline');
      has(app.text(app.byId('dr-dl-left')), '1 h 30 min');
      ['15 min', '30 min', '1 h', '2 h', 'Extend', 'Shorten'].forEach(function (label) {
        truthy(app.button(label, drawer), label);
      });
      truthy(drawer.querySelector('[data-bind="dr.dl.min"]'), 'a box for a number of minutes');
      truthy(drawer.querySelector('[data-bind="dr.dl.reason"]'), 'a reason box');
    });
    app.click(app.button('Extend', app.drawer()));
    await settled();
    it('refuses with no time picked, sending nothing', function () {
      eq(app.requests('adjustDeadline').length, 0);
      has(app.text(app.drawer().querySelector('.answer')), 'Pick a time');
    });
    app.click(app.button('1 h', app.drawer()));
    await settled();
    it('a quick pick fills the minutes and shows the time left after either way', function () {
      eq(app.drawer().querySelector('[data-bind="dr.dl.min"]').value, '60');
      const preview = app.text(app.byId('dr-dl-preview'));
      has(preview, 'Extend: 2 h 30 min left after');
      has(preview, 'Shorten: 30 min left after');
    });
    app.click(app.button('Extend', app.drawer()));
    await settled();
    it('refuses with no reason, sending nothing', function () {
      eq(app.requests('adjustDeadline').length, 0);
      has(app.text(app.drawer().querySelector('.answer')), 'Give a reason');
    });
    app.type(app.drawer().querySelector('[data-bind="dr.dl.min"]'), '100');
    it('a typed number of minutes updates the preview as it is typed', function () {
      has(app.text(app.byId('dr-dl-preview')), 'Shorten: not by this much');
      has(app.text(app.byId('dr-dl-preview')), 'the most is 1 h 25 min');
      has(app.text(app.byId('dr-dl-preview')), 'Extend: 3 h 10 min left after');
    });
    clock.ms += 1;
    app.type(app.drawer().querySelector('[data-bind="dr.dl.min"]'), '60');
    it('the preview counts down from the read: a second later it shows a second less', function () {
      has(app.text(app.byId('dr-dl-preview')), 'Extend: 2 h 29 min 59 s left after');
      has(app.text(app.byId('dr-dl-preview')), 'Shorten: 29 min 59 s left after');
    });
    clock.ms -= 1;
    app.type(app.drawer().querySelector('[data-bind="dr.dl.min"]'), '45');
    app.type(app.drawer().querySelector('[data-bind="dr.dl.reason"]'), 'Server crash cost them time');
    const extend = app.button('Extend', app.drawer());
    app.click(extend);
    await settled();
    it('Extend takes two clicks: the first only arms it', function () {
      eq(app.requests('adjustDeadline').length, 0);
      truthy(extend.classList.contains('is-armed'));
      has(app.text(extend), 'Click again to extend');
    });
    app.fire(3000);
    it('and it disarms itself after three seconds', function () {
      falsy(extend.classList.contains('is-armed'));
    });
    app.click(extend);
    app.click(extend);
    await settled();
    it('the second click extends by the minutes, in seconds, with the reason', function () {
      eq(app.requests('adjustDeadline').length, 1);
      eq(app.last('adjustDeadline').data, { id: 'ct00000001', seconds: 2700, reason: 'Server crash cost them time' });
      has(app.text(app.drawer().querySelector('.answer')), '2 h 30 min left now');
      truthy(app.requests('contract').length >= 2, 'the contract is read again');
    });
    app.click(app.button('30 min', app.drawer()));
    app.type(app.drawer().querySelector('[data-bind="dr.dl.reason"]'), 'Agreed in the ticket');
    const shorten = app.button('Shorten', app.drawer());
    app.click(shorten);
    await settled();
    it('Shorten takes two clicks too', function () {
      eq(app.requests('adjustDeadline').length, 1);
      has(app.text(shorten), 'Click again to shorten');
    });
    app.click(shorten);
    await settled();
    it('and sends a negative number of seconds', function () {
      eq(app.requests('adjustDeadline').length, 2);
      eq(app.last('adjustDeadline').data, { id: 'ct00000001', seconds: -1800, reason: 'Agreed in the ticket' });
    });
    server.adjustDeadline = { ok: false, err: 'min_left', message: 'Not shortened: it has 10 min left, and at least '
      + '5 min must remain (Config.Limits.StaffDeadlineMinLeftSeconds). The most you can shorten it by is 5 min.' };
    app.click(app.button('15 min', app.drawer()));
    app.type(app.drawer().querySelector('[data-bind="dr.dl.reason"]'), 'x');
    const again = app.button('Shorten', app.drawer());
    app.click(again);
    app.click(again);
    await settled();
    it('a refusal shows the server\'s words', function () {
      const answer = app.drawer().querySelector('.answer');
      truthy(answer.classList.contains('is-error'));
      has(app.text(answer), 'The most you can shorten it by is 5 min.');
    });
    clean(app, 'deadline');
  })();

  await (async function () {
    const app = boot(standardServer({ contract: contractDetail({ deadline: { left: 900, stopped: true,
      adjustable: true, maxAdjust: 86400, minLeft: 300 } }) }));
    app.open(READER);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('a reader sees the time left, and Extend and Shorten disabled, sending nothing', function () {
      has(app.text(app.byId('dr-dl-left')), '15 min');
      has(app.text(app.drawer()), 'its clock is stopped');
      ['Extend', 'Shorten', '1 h'].forEach(function (label) {
        truthy(app.button(label, app.drawer()).disabled, label + ' disabled');
      });
      app.click(app.button('Extend', app.drawer()));
      eq(app.requests('adjustDeadline').length, 0);
    });
    clean(app, 'deadline reader');
  })();

  await (async function () {
    const app = boot(standardServer({ contract: contractDetail({ deadline: { left: 0, adjustable: false } }) }));
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('a closed contract offers no Extend or Shorten', function () {
      has(app.text(app.drawer()), 'Only a live contract');
      eq(app.drawer().querySelectorAll('button').filter(function (b) {
        return /^dl-/.test(b.getAttribute('data-act') || '');
      }).length, 0);
    });
    app.nav('actions');
    await settled();
    it('Staff actions > Deadlines points to Extend and Shorten in Contracts', function () {
      has(app.main(), 'Extend or Shorten under Deadline');
      lacks(app.main(), 'the panel has no button that sets one');
    });
    clean(app, 'deadline closed');
  })();

  /* ---- staff freeze: Freeze and Unfreeze under Players ---- */
  await (async function () {
    let frozen = null;
    const server = standardServer({
      player: function () {
        const reply = player();
        reply.data.frozen = frozen;
        if (frozen) reply.data.contracts[0].frozen = true;
        return reply;
      },
      frozen: function () {
        return { ok: true, data: { rows: frozen ? [{ ref: 'f1', name: 'Dana Reyes', online: true,
          since: NOW - 60, reason: 'RP dispute' }] : [] } };
      },
      freeze: function (data) {
        frozen = { since: NOW, reason: data.reason };
        return { ok: true, message: 'Dana Reyes is frozen.', data: { frozen: frozen } };
      },
      unfreeze: function () {
        frozen = null;
        return { ok: true, message: 'Unfrozen. Their contracts run again, with the time on hold given back.' };
      },
      contracts: contracts({ rows: [contractRow(1, { frozen: true }), contractRow(2)] }),
      overview: overview({ frozen: { players: 2 } }),
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    it('counts frozen players on the overview', function () {
      has(app.main(), 'Frozen players');
      has(app.text(app.byId('ov-frozen')), '2');
    });
    app.nav('contracts');
    await settled();
    it('badges a frozen contract in the list, and only that one', function () {
      eq(app.$$('.is-frozen').length, 1);
    });
    app.nav('players');
    await settled();
    it('asks for the frozen list when Players opens', function () {
      truthy(app.requests('frozen').length >= 1, 'asked');
      has(app.main(), 'Nobody is frozen.');
    });
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('offers Freeze, with a reason field, on the player looked up', function () {
      truthy(app.button('Freeze'), 'Freeze');
      truthy(app.byId('pl-freeze-reason'), 'the reason field');
      eq(app.$$('button').filter(function (b) { return b.getAttribute('data-act') === 'pl-unfreeze'; }).length, 0,
        'Unfreeze before they are frozen');
    });
    app.click(app.button('Freeze'));
    await settled();
    it('refuses a freeze with no reason, sending nothing', function () {
      eq(app.requests('freeze').length, 0);
      has(app.main(), 'Give a reason');
    });
    app.type(app.byId('pl-freeze-reason'), 'RP dispute');
    app.click(app.button('Freeze'));
    await settled();
    it('takes two clicks to freeze, and sends nothing on the first', function () {
      eq(app.requests('freeze').length, 0);
    });
    app.click(app.button('Freeze'));
    await settled();
    it('freezes the player as they were looked up, with the reason', function () {
      eq(app.last('freeze').data, { ref: 'p7_424242', reason: 'RP dispute' });
      has(app.main(), 'Dana Reyes is frozen.');
      truthy(app.button('Unfreeze'), 'Unfreeze once frozen');
      truthy(app.$$('.is-frozen').length >= 1, 'the Frozen badge');
      has(app.main(), 'Frozen players');
    });
    app.click(app.button('Unfreeze'));
    await settled();
    it('takes two clicks to unfreeze', function () {
      eq(app.requests('unfreeze').length, 0);
    });
    app.click(app.button('Unfreeze'));
    await settled();
    it('unfreezes, and offers Freeze again', function () {
      eq(app.last('unfreeze').data.ref, 'p7_424242');
      has(app.main(), 'Unfrozen.');
      truthy(app.button('Freeze'), 'Freeze again');
    });
    clean(app, 'freeze');
  })();

  await (async function () {
    const app = boot(standardServer({ frozen: { ok: true, data: { rows: [] } } }));
    app.open(READER);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('a reader is shown Freeze disabled, and it sends nothing', function () {
      const button = app.button('Freeze');
      truthy(button, 'drawn');
      truthy(button.disabled, 'disabled for a reader');
      app.click(button);
      app.click(button);
      eq(app.requests('freeze').length, 0);
    });
    clean(app, 'freeze reader');
  })();

  /* ---- staff tools on a contract: notes, remove an operative, edit text,
     export, the player view ---- */
  function staffPart(extra) {
    return Object.assign({
      notes: [{ id: 'cs1', at: NOW - 900, by: 'Staff', text: XSS }],
      removals: [{ id: 'cs2', at: NOW - 600, who: 'operative Ghost', by: 'Staff', reason: 'rdm',
        stakeReturned: true, blocked: true }],
      edits: [{ id: 'cs3', at: NOW - 300, field: 'reason', by: 'Staff', reason: 'a slur' }],
      noteMax: 300, removable: true,
      text: { editable: true, mode: 'freetext', max: 120, edited: true }
    }, extra || {});
  }

  await (async function () {
    const found = [];
    const server = standardServer({
      contract: contractDetail({ staff: staffPart() }),
      addNote: { ok: true, message: 'Note added.', data: { id: 'cs9' } },
      removeHitman: { ok: true, message: 'Ghost taken off the contract.', data: { stake: 2500 } },
      editText: { ok: true, message: 'Reason replaced.', data: { new: 'Settling a score' } },
      exportContract: { ok: true, data: { text: 'Contract ct00000001\nState: accepted\n' + XSS } },
      playerView: function (data) {
        return { ok: true, data: { role: data.role, shown: true, alias: data.hitman ? 'Ghost' : undefined,
          view: { id: 'ct00000001', role: data.role === 'placer' ? 'creator' : data.role, targetName: 'Dana Reyes',
            reason: XSS, staffEdited: true, timeLeft: '1–2 hours left', penaltyAmount: 2500,
            reward: { baseline: 5000, bonus: 0 }, creatorAnonymous: true, myAlias: data.hitman ? 'Ghost' : undefined } } };
      }
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    markupFrom(app, 'the staff tools', found);
    it('the contract view has the five staff tools, the notes and history escaped', function () {
      const text = app.text(app.drawer());
      ['Staff notes', 'Remove an operative', 'Edit text', 'Export the record', 'As a player sees it'].forEach(function (t) {
        has(text, t);
      });
      eq(found.length, 0, found.join(', '));
      has(text, 'operative Ghost');
      has(text, 'stake returned');
      has(text, 'barred');
      has(text, 'edited by staff');
      has(text, 'reason replaced by Staff');
    });

    // Notes.
    app.click(app.button('Add note', app.drawer()));
    await settled();
    it('Add note with nothing written sends nothing', function () {
      eq(app.requests('addNote').length, 0);
      has(app.text(app.drawer().querySelector('.answer')), 'Write the note.');
    });
    app.type(app.drawer().querySelector('[data-bind="dr.note.ct00000001"]'), 'ticket #42, waiting on clip');
    const add = app.button('Add note', app.drawer());
    app.click(add);
    await settled();
    it('Add note takes two clicks', function () {
      eq(app.requests('addNote').length, 0);
      has(app.text(add), 'Click again to add');
    });
    app.click(add);
    await settled();
    it('and sends the note for this contract', function () {
      eq(app.last('addNote').data, { id: 'ct00000001', text: 'ticket #42, waiting on clip' });
      has(app.text(app.drawer().querySelector('.answer')), 'Note added.');
    });

    // Remove an operative.
    app.type(app.drawer().querySelector('[data-bind="dr.rm.reason.ct00000001"]'), 'combat logging');
    app.click(app.button('Remove', app.drawer()));
    await settled();
    it('Remove with no operative picked sends nothing', function () {
      eq(app.requests('removeHitman').length, 0);
      has(app.text(app.drawer().querySelector('.answer')), 'Pick the operative');
    });
    app.click(app.button('Ghost · Anonymous', app.drawer()));
    app.click(app.button('Return the stake', app.drawer()));
    app.click(app.button('Bar them from it', app.drawer()));
    const remove = app.button('Remove', app.drawer());
    app.click(remove);
    await settled();
    it('Remove takes two clicks', function () {
      eq(app.requests('removeHitman').length, 0);
      has(app.text(remove), 'Click again to remove');
    });
    app.click(remove);
    await settled();
    it('and sends the operative, the reason, the stake choice and the bar', function () {
      eq(app.last('removeHitman').data, { id: 'ct00000001', hitman: 'hm1', reason: 'combat logging',
        returnStake: true, block: true });
      has(app.text(app.drawer().querySelector('.answer')), 'Ghost taken off the contract.');
    });

    // Edit text.
    app.type(app.drawer().querySelector('[data-bind="dr.tx.text.ct00000001"]'), 'Settling a score');
    app.click(app.button('Replace', app.drawer()));
    await settled();
    it('Replace with no reason sends nothing', function () {
      eq(app.requests('editText').length, 0);
      has(app.text(app.drawer().querySelector('.answer')), 'Give a reason');
    });
    app.type(app.drawer().querySelector('[data-bind="dr.tx.reason.ct00000001"]'), 'a slur');
    const replace = app.button('Replace', app.drawer());
    app.click(replace);
    app.click(replace);
    await settled();
    it('Replace, on the second click, sends the new text and the reason', function () {
      eq(app.last('editText').data, { id: 'ct00000001', field: 'reason', text: 'Settling a score', reason: 'a slur' });
    });

    // Export.
    app.click(app.button('Copy the record', app.drawer()));
    await settled();
    it('Copy the record asks for it and puts it on the clipboard, as plain text', function () {
      eq(app.last('exportContract').data, { id: 'ct00000001' });
      eq(app.document.clipboard, 'Contract ct00000001\nState: accepted\n' + XSS);
      has(app.toasts(), 'on the clipboard');
    });
    app.document.copyRefused = true;
    app.click(app.button('Copy the record', app.drawer()));
    await settled();
    it('and shows it to copy by hand when the game will not copy', function () {
      const box = app.drawer().querySelector('textarea');
      truthy(box, 'a box to copy from');
      has(box.textContent || box.value, 'Contract ct00000001');
      markupFrom(app, 'the export box', found);
      eq(found.length, 0, found.join(', '));
    });

    // The player view.
    app.click(app.button('Target', app.drawer()));
    await settled();
    it('the target\'s card is asked for, and drawn, escaped, with its edited mark', function () {
      eq(app.last('playerView').data, { id: 'ct00000001', role: 'target' });
      const text = app.text(app.drawer().querySelector('.ct-view'));
      has(text, 'Dana Reyes');
      has(text, '1–2 hours left');
      has(text, 'edited by staff');
      has(text, '$5,000');
      markupFrom(app, 'the player view', found);
      eq(found.length, 0, found.join(', '));
    });
    app.click(app.button('Ghost', app.drawer()));
    await settled();
    it('an operative\'s card by their row, not by who they are', function () {
      eq(app.last('playerView').data, { id: 'ct00000001', role: 'hitman', hitman: 'hm1' });
      has(app.text(app.drawer().querySelector('.ct-view')), 'myAlias');
    });
    clean(app, 'staff tools');
  })();

  await (async function () {
    const app = boot(standardServer({ contract: contractDetail({ staff: staffPart() }),
      playerView: { ok: true, data: { role: 'placer', shown: false, note: 'Closed: it is off their phone.' } } }));
    app.open(READER);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('a reader sees the notes and the history, and every tool that writes disabled', function () {
      ['Add note', 'Remove', 'Replace'].forEach(function (label) {
        truthy(app.button(label, app.drawer()).disabled, label + ' disabled');
      });
      falsy(app.button('Copy the record', app.drawer()).disabled, 'exporting is not a write');
      falsy(app.button('Placer', app.drawer()).disabled, 'looking is not a write');
      app.click(app.button('Add note', app.drawer()));
      app.click(app.button('Remove', app.drawer()));
      eq(app.requests('addNote').length + app.requests('removeHitman').length, 0);
    });
    app.click(app.button('Placer', app.drawer()));
    await settled();
    it('a card not shown says why', function () {
      has(app.text(app.drawer().querySelector('.ct-view')), 'Closed: it is off their phone.');
    });
    clean(app, 'staff tools reader');
  })();

  await (async function () {
    const app = boot(standardServer({ contract: contractDetail({ staff: staffPart({
      removable: false, text: { editable: false, mode: 'off' } }) }) }));
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('a closed contract offers no Remove, and a server with no reason no Replace', function () {
      has(app.text(app.drawer()), 'Only a live contract (active or accepted) has operatives to remove.');
      has(app.text(app.drawer()), 'This server keeps no reason on a contract.');
      eq(app.drawer().querySelectorAll('button').filter(function (b) {
        const act = b.getAttribute('data-act') || '';
        return act === 'ct-remove' || act === 'ct-text';
      }).length, 0);
    });
    clean(app, 'staff tools closed');
  })();

  /* ---- a player's staff tools: Suspend, Protect, Pay and the history card ---- */
  function staffPlayerServer(extra) {
    const state = { suspended: null, protected: null };
    const history = { ok: true, data: {
      counts: { placed: 2, taken: 1, completed: 1, cancelled: 1, onThem: 3, boughtOut: 1 },
      recent: [{ id: 'ct00000007', state: 'completed', roles: ['hitman'], created_at: NOW - 7200 }],
      buyouts: { paid: 1, amount: 15000 },
      informants: { count: 2, spent: 50000, informant: 1, placerInformant: 0, locationTip: 1 },
      money: { in: [{ kind: 'payouts', amount: 5000 }, { kind: 'staff payments', amount: 250 }],
               out: [{ kind: 'rewards put up', amount: 12000 }] },
      measures: [{ kind: 'suspend', from: NOW - 600, until: NOW + 86400, state: 'in force', reason: XSS },
                 { kind: 'freeze', from: NOW - 9000, ended: NOW - 8000, state: 'lifted', reason: 'dispute' }],
      identified: false, retentionDays: 30 } };
    return Object.assign(standardServer({
      player: function () {
        const reply = player();
        reply.data.suspended = state.suspended;
        reply.data.protected = state.protected;
        reply.data.payMax = 100000;
        return reply;
      },
      history: history,
      frozen: { ok: true, data: { rows: [] } },
      suspend: function (data) {
        state.suspended = { since: NOW, until: data.days > 0 ? NOW + data.days * 86400 : null, reason: data.reason };
        return { ok: true, message: 'Dana Reyes is suspended from placing and accepting contracts for '
          + data.days + ' days. Their live contracts are not touched: freeze them for that.',
          data: { suspended: state.suspended } };
      },
      unsuspend: function () {
        state.suspended = null;
        return { ok: true, message: 'Suspension lifted. They may place and accept contracts again.' };
      },
      protect: function (data) {
        state.protected = { since: NOW, until: data.hours > 0 ? NOW + data.hours * 3600 : null, reason: data.reason };
        return { ok: true, message: 'Dana Reyes is protected from new contracts.' };
      },
      unprotect: function () {
        state.protected = null;
        return { ok: true, message: 'Protection lifted. New contracts may name them again.' };
      },
      manualPay: function (data) {
        return { ok: true, message: 'Paid $' + data.amount + ' in ' + data.account + ' to Dana Reyes.',
          data: { paid: true, owed: false } };
      }
    }), extra || {});
  }

  async function lookUp(app) {
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
  }

  await (async function () {
    const app = boot(staffPlayerServer());
    app.open(ADMIN);
    await settled();
    await lookUp(app);
    it('a lookup draws Suspend, Protect, Pay and the history card, and asks for the history', function () {
      has(app.main(), 'Suspend from contracts');
      has(app.main(), 'Protect from contracts');
      has(app.main(), 'Pay');
      has(app.main(), 'History');
      eq(app.last('history').data, { ref: 'p7_424242' });
      has(app.main(), 'Their live contracts are not touched: freeze them for that.');
      has(app.main(), 'Contracts already on them are not touched: freeze them for that.');
    });
    it('the history card shows the counts, money by kind and each measure with its dates, escaped', function () {
      has(app.main(), 'Bought out');
      has(app.main(), 'rewards put up');
      has(app.main(), 'staff payments');
      has(app.main(), 'Suspension');
      has(app.main(), 'Freeze');
      has(app.main(), XSS, 'the reason as text');
      eq(app.$$('img').length, 0, 'never as markup');
      lacks(app.main(), 'Client', 'no names column without the identity ACE');
    });

    app.click(app.button('Suspend'));
    await settled();
    it('refuses a suspension with no days chosen, sending nothing', function () {
      eq(app.requests('suspend').length, 0);
      has(app.main(), 'Choose how many days');
    });
    app.click(app.button('3 days'));
    await settled();
    app.click(app.button('Suspend'));
    await settled();
    it('and with no reason', function () {
      eq(app.requests('suspend').length, 0);
      has(app.main(), 'Give a reason');
    });
    app.type(app.byId('ps-reason'), 'Contract spam');
    app.click(app.button('Suspend'));
    await settled();
    it('takes two clicks to suspend, and sends nothing on the first', function () {
      eq(app.requests('suspend').length, 0);
    });
    app.click(app.button('Suspend'));
    await settled();
    it('suspends the player looked up, for the days picked, with the reason', function () {
      eq(app.last('suspend').data, { ref: 'p7_424242', days: 3, reason: 'Contract spam' });
      has(app.main(), 'Dana Reyes is suspended');
      truthy(app.button('Lift suspension'), 'Lift once suspended');
      truthy(app.$$('.is-suspended').length >= 1, 'the Suspended badge');
    });
    app.click(app.button('Lift suspension'));
    await settled();
    it('round 3 L7: takes two clicks to lift a suspension, and sends nothing on the first', function () {
      eq(app.requests('unsuspend').length, 0);
    });
    app.click(app.button('Lift suspension'));
    await settled();
    it('lifts it on the second click', function () {
      eq(app.requests('unsuspend').length, 1);
      eq(app.last('unsuspend').data, { ref: 'p7_424242' });
      truthy(app.button('Suspend'), 'Suspend again');
    });

    app.click(app.button('Days'));
    await settled();
    app.type(app.byId('pp-amount'), '2');
    app.type(app.byId('pp-reason'), 'New player');
    app.click(app.button('Protect'));
    await settled();
    app.click(app.button('Protect'));
    await settled();
    it('protects for the days typed, sent as hours, on two clicks', function () {
      eq(app.requests('protect').length, 1);
      eq(app.last('protect').data, { ref: 'p7_424242', hours: 48, reason: 'New player' });
      truthy(app.button('Lift protection'), 'Lift once protected');
    });
    app.click(app.button('Lift protection'));
    await settled();
    it('round 3 L7: takes two clicks to lift a protection too', function () {
      eq(app.requests('unprotect').length, 0);
    });
    app.click(app.button('Lift protection'));
    await settled();
    it('and lifts it on the second', function () {
      eq(app.requests('unprotect').length, 1);
      eq(app.last('unprotect').data, { ref: 'p7_424242' });
    });
    app.click(app.button('Permanent'));
    await settled();
    app.type(app.byId('pp-reason'), 'Off duty staff');
    app.click(app.button('Protect'));
    app.click(app.button('Protect'));
    await settled();
    it('protects for good as hours 0', function () {
      eq(app.last('protect').data, { ref: 'p7_424242', hours: 0, reason: 'Off duty staff' });
    });

    app.type(app.byId('pay-amount'), '250000');
    app.type(app.byId('pay-reason'), 'Lost to a bug');
    app.click(app.button('Pay'));
    await settled();
    it('refuses a payment over the cap, sending nothing', function () {
      eq(app.requests('manualPay').length, 0);
      has(app.main(), 'At most $100,000');
    });
    app.click(app.button('Bank'));
    await settled();
    app.type(app.byId('pay-amount'), '2500');
    app.click(app.button('Pay'));
    await settled();
    it('takes two clicks to pay', function () {
      eq(app.requests('manualPay').length, 0);
    });
    app.click(app.button('Pay'));
    await settled();
    it('pays the amount in the account chosen, with the reason', function () {
      eq(app.last('manualPay').data, { ref: 'p7_424242', amount: 2500, account: 'bank', reason: 'Lost to a bug' });
      has(app.toasts(), 'Paid $2500 in bank');
    });
    clean(app, 'staff player tools');
  })();

  await (async function () {
    const app = boot(staffPlayerServer());
    app.open(access({ canWrite: false, canModerate: true, canIdentify: false }));
    await settled();
    it('a moderator is badged as one', function () {
      has(app.text(app.byId('badges')), 'Moderator');
    });
    await lookUp(app);
    it('a moderator may freeze, suspend and protect, and not pay', function () {
      falsy(app.button('Freeze').disabled, 'Freeze');
      falsy(app.button('Suspend').disabled, 'Suspend');
      falsy(app.button('Protect').disabled, 'Protect');
      truthy(app.button('Pay').disabled, 'Pay is the staff ACE\'s');
      app.click(app.button('Pay'));
      app.click(app.button('Pay'));
      eq(app.requests('manualPay').length, 0);
      truthy(app.byId('pay-amount').disabled, 'nor its amount');
    });
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('a moderator may void and move a deadline from the contract view', function () {
      falsy(app.button('Void contract', app.drawer()).disabled, 'Void');
    });
    clean(app, 'moderator');
  })();

  await (async function () {
    const app = boot(staffPlayerServer());
    app.open(READER);
    await settled();
    await lookUp(app);
    it('a reader sees Suspend, Protect and Pay disabled, and they send nothing', function () {
      ['Suspend', 'Protect', 'Pay'].forEach(function (label) {
        const button = app.button(label);
        truthy(button.disabled, label + ' disabled for a reader');
        app.click(button);
        app.click(button);
      });
      eq(app.requests('suspend').length + app.requests('protect').length + app.requests('manualPay').length, 0);
      has(app.main(), 'History', 'the history card reads for them too');
    });
    clean(app, 'reader staff tools');
  })();

  await (async function () {
    const app = boot(staffPlayerServer({ history: { ok: true, data: {
      counts: { placed: 1 }, recent: [{ id: 'ct00000009', state: 'cancelled', roles: ['client'],
        anonymous: true, created_at: NOW, client: 'Vic Marlowe', target: XSS }],
      money: {}, measures: [], buyouts: {}, informants: {}, identified: true, anonymous: 1 } } }));
    app.open(FULL);
    await settled();
    await lookUp(app);
    it('with the identity ACE the history card names the parties, and how many were anonymous', function () {
      has(app.main(), 'Vic Marlowe');
      has(app.main(), XSS);
      has(app.main(), '1 anonymous');
      eq(app.$$('img').length, 0);
    });
    clean(app, 'identified history');
  })();

  /* ---- staff tools: Announce ---- */
  await (async function () {
    const server = standardServer({
      announce: function (data) {
        return { ok: true, message: 'Sent to 3 hitman/hitmen holding a contract, from Staff.',
          data: { sent: 3, scope: data.scope } };
      }
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.click(app.byId('grp-actions'));
    await settled();
    it('Staff actions has an Announce sub-tab, and a card pointing to it', function () {
      eq(app.byId('nav-announce').hidden, false);
      has(app.main(), 'Announce');
    });
    app.nav('announce');
    await settled();
    it('Announce says it comes from Staff, with both audiences and a count', function () {
      has(app.main(), 'from Staff, never from you');
      truthy(app.button('Hitmen on a contract'));
      truthy(app.button('Everyone online'));
      has(app.text(app.byId('an-count')), '0 / 200 characters');
    });
    app.click(app.button('Send'));
    await settled();
    it('refuses an empty notice, sending nothing', function () {
      eq(app.requests('announce').length, 0);
      has(app.main(), 'Write the notice first.');
    });
    app.type(app.byId('an-text'), 'x'.repeat(201));
    it('counts as it is typed, and says when it is too long', function () {
      has(app.text(app.byId('an-count')), '201 / 200 characters: too long to send.');
    });
    app.click(app.button('Send'));
    await settled();
    it('and refuses one too long, sending nothing', function () {
      eq(app.requests('announce').length, 0);
      has(app.main(), 'At most 200 characters.');
    });
    app.type(app.byId('an-text'), 'Event tonight at the pier.');
    const send = app.button('Send');
    app.click(send);
    await settled();
    it('Send takes two clicks: the first only arms it', function () {
      eq(app.requests('announce').length, 0);
      truthy(send.classList.contains('is-armed'));
      has(app.text(send), 'Click again to send');
    });
    app.click(send);
    await settled();
    it('the second sends the text to every hitman holding a contract', function () {
      eq(app.requests('announce').length, 1);
      eq(app.last('announce').data, { text: 'Event tonight at the pier.', scope: 'active' });
      has(app.main(), 'Sent to 3');
      eq(app.byId('an-text').value, '', 'the box empties once sent');
    });
    app.click(app.button('Everyone online'));
    await settled();
    app.type(app.byId('an-text'), 'Server event at eight.');
    const again = app.button('Send');
    app.click(again);
    app.click(again);
    await settled();
    it('or to everybody online with the app, when chosen', function () {
      eq(app.last('announce').data, { text: 'Server event at eight.', scope: 'online' });
    });
    server.announce = { ok: false, err: 'text_refused', message: 'Not sent: no links, invites or handles in a notice to players.' };
    app.type(app.byId('an-text'), 'discord.gg/abc');
    const third = app.button('Send');
    app.click(third);
    app.click(third);
    await settled();
    it('a refusal shows the server\'s words', function () {
      has(app.main(), 'no links, invites or handles');
    });
    clean(app, 'announce');
  })();

  await (async function () {
    const app = boot(standardServer());
    app.open(READER);
    await settled();
    app.nav('announce');
    await settled();
    it('a reader sees Announce with Send disabled, and it sends nothing', function () {
      const send = app.button('Send');
      truthy(send.disabled, 'disabled for a reader');
      app.click(send);
      app.click(send);
      eq(app.requests('announce').length, 0);
    });
    clean(app, 'announce reader');
  })();

  /* ---- staff tools: Developer > Settings history, with Undo ---- */
  function historyRows(withRefs) {
    return [
      { ts: NOW - 60, key: 'Relay.Enabled', label: 'Anonymous messages', old: true, new: false, by: 'a staff member',
        ref: withRefs ? 'h2' : undefined },
      { ts: NOW - 120, key: 'Limits.MaxActiveContractsPerTarget', label: 'Most contracts on one target', old: 10,
        new: 4, by: 'a staff member', reset: true, ref: withRefs ? 'h1' : undefined },
      { ts: NOW - 180, key: 'convar:crimson_hitman_webhook', secret: true, by: 'a staff member' },
      { ts: NOW - 240, key: 'Notes.Words', label: XSS, old: [XSS], new: [], by: XSS }
    ];
  }
  await (async function () {
    const server = standardServer({
      settingsHistory: { ok: true, data: { rows: historyRows(true), next: 77 } },
      undoSetting: function () {
        return { ok: true, message: 'Undone: Relay.Enabled is on again (it was off).', data: { key: 'Relay.Enabled' } };
      }
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('history');
    await settled();
    it('Developer > Settings history lists each change: when, the setting, before, after and who', function () {
      eq(app.byId('nav-history').getAttribute('aria-current'), 'page');
      eq(app.requests('settingsHistory').length, 1);
      const rows = app.$$('tr[data-key]');
      eq(rows.length, 4);
      has(app.text(rows[0]), 'Relay.Enabled');
      has(app.text(rows[0]), 'on');
      has(app.text(rows[0]), 'off');
      has(app.text(rows[0]), 'a staff member');
      has(app.text(rows[1]), 'back to config.lua');
    });
    it('never a secret\'s value, and nothing a player typed as markup', function () {
      const rows = app.$$('tr[data-key]');
      has(app.text(rows[2]), '(hidden)');
      eq(rows[2].querySelectorAll('button').length, 0, 'an Undo on a secret');
      eq(app.body.querySelectorAll('img').length, 0, 'markup from a row');
    });
    const undo = app.$$('tr[data-key]')[0].querySelector('button');
    app.click(undo);
    await settled();
    it('Undo takes two clicks: the first only arms it', function () {
      eq(app.requests('undoSetting').length, 0);
      has(app.text(undo), 'Click again to undo');
    });
    app.click(undo);
    await settled();
    it('the second asks the server to undo that row, by its handle alone', function () {
      eq(app.requests('undoSetting').length, 1);
      eq(app.last('undoSetting').data, { ref: 'h2' });
      has(app.main(), 'Undone: Relay.Enabled is on again');
      eq(app.requests('settingsHistory').length, 2, 'the history is read again');
    });
    app.click(app.button('Older'));
    await settled();
    it('Older reads the next page from the cursor, and Newer goes back', function () {
      eq(app.last('settingsHistory').data, { cursor: 77 });
      app.click(app.button('Newer'));
    });
    await settled();
    it('back at the first page', function () { eq(app.last('settingsHistory').data, {}); });
    clean(app, 'settings history');
  })();

  await (async function () {
    const server = standardServer({
      settingsHistory: { ok: true, data: { rows: historyRows(false), hidden: 2 } }
    });
    const app = boot(server);
    app.open(access({ canWrite: false, canIdentify: false, canDevelop: false }));
    await settled();
    app.click(app.byId('grp-developer'));
    await settled();
    it('staff without the Developer section still have Settings history beside Permissions', function () {
      eq(app.byId('nav-permissions').getAttribute('aria-current'), 'page');
      eq(app.byId('nav-history').hidden, false);
    });
    app.nav('history');
    await settled();
    it('a reader reads the history, with no Undo, told what is left out', function () {
      eq(app.byId('nav-history').getAttribute('aria-current'), 'page');
      eq(app.$$('tr[data-key]').length, 4);
      eq(app.byId('main').querySelectorAll('button[data-act="hs-undo"]').length, 0);
      has(app.main(), '2 change(s) to the Developer section');
    });
    clean(app, 'settings history reader');
  })();

  /* ---- staff tools: a player's report in Needs review ---- */
  await (async function () {
    const report = { id: 'rv00000009', kind: 'player_report', about: 'a player reported this contract',
      contract: 'ct00000001', parties: [{ role: 'from', who: 'operative Ghost' }, { role: 'reported', who: 'the client' }],
      items: [], known: { role: 'hitman', note: 'Threats ' + XSS, thread: true, excerpt: [
        { alias: 'Ghost', body: 'On my way', at: NOW - 300 },
        { alias: 'Placer', body: 'Do it or else ' + XSS, at: NOW - 200 }] },
      now: { contract: 'accepted' }, state: 'open', created_at: NOW - 100 };
    const server = standardServer({
      reviews: { ok: true, data: { items: [report] } },
      resolve: { ok: true, message: 'Review rv00000009 resolved: dismissed.', data: { detail: {} } }
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('reviews');
    await settled();
    const item = app.byId('rv-rv00000009');
    it('a report shows who sent it by role, the note and the thread\'s messages by alias', function () {
      has(app.text(item), 'player report');
      has(app.text(item), 'a hitman on it');
      has(app.text(item), 'Threats');
      has(app.text(item), 'Ghost');
      has(app.text(item), 'Do it or else');
      eq(item.querySelectorAll('li').length, 2);
      eq(app.body.querySelectorAll('img').length, 0, 'markup from a report');
    });
    it('and offers Dismiss alone: a report holds no money', function () {
      lacks(app.text(item), 'Refund it');
      lacks(app.text(item), 'Pay it');
      truthy(app.button('Dismiss it', item));
    });
    const dismiss = app.button('Dismiss it', item);
    app.click(dismiss);
    await settled();
    it('Dismiss without a note is refused, sending nothing', function () {
      eq(app.requests('resolve').length, 0);
      has(app.text(app.byId('rv-rv00000009')), 'Say why in a note');
    });
    app.type(app.byId('rv-rv00000009').querySelector('[data-bind="rv.rv00000009.note"]'), 'Spoke to both');
    const again = app.button('Dismiss it', app.byId('rv-rv00000009'));
    app.click(again);
    app.click(again);
    await settled();
    it('and with one dismisses it, in two clicks', function () {
      eq(app.requests('resolve').length, 1);
      eq(app.last('resolve').data, { id: 'rv00000009', action: 'dismiss', note: 'Spoke to both' });
    });
    clean(app, 'player report');
  })();

  /* ---- The roleplay consequences (server/rp_consequences.lua) ---- */
  await (async function () {
    const view = settingsView();
    view.data.features.push({ key: 'Roleplay.WitnessHeat.Enabled', category: 'features',
      group: 'Roleplay: Witness heat', label: 'Witness heat', kind: 'switch', live: true,
      inflight: 'At the next completion, with no restart.', value: false, default: false, source: 'config' });
    view.data.limits.push({ key: 'Roleplay.WitnessHeat.Phrases', category: 'rules-limits',
      group: 'Roleplay: Witness heat', label: 'What a witness says', kind: 'list', whole: true, live: true,
      inflight: 'Read each time it is used.', value: ['a person in dark clothing fled {direction}'],
      default: ['a person in dark clothing fled {direction}'], source: 'config' });
    const server = standardServer({ settings: view });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('features');
    await settled();
    it('lists a roleplay switch under Features, in its Roleplay group, with what the group is', function () {
      has(app.text(app.byId('st-row-Roleplay.WitnessHeat.Enabled')), 'Witness heat');
      has(app.text(app.$('#panel')), 'naming nobody');
    });
    app.nav('limits');
    await settled();
    const row = function () { return app.byId('st-row-Roleplay.WitnessHeat.Phrases'); };
    app.type(row().querySelector('input'), 'a tall man, in a cap, ran {direction}');
    app.click(app.button('Add', row()));
    await settled();
    app.click(app.byId('st-save-Roleplay.WitnessHeat.Phrases'));
    app.click(app.byId('st-save-Roleplay.WitnessHeat.Phrases'));
    await settled();
    it('a list of phrases takes the line as typed, spaces and commas kept, on two clicks', function () {
      eq(app.last('setSetting').data, { key: 'Roleplay.WitnessHeat.Phrases',
        value: ['a person in dark clothing fled {direction}', 'a tall man, in a cap, ran {direction}'] });
    });
    app.nav('help');
    await settled();
    it('How it works has a card for each roleplay feature, linking to its settings', function () {
      const text = app.text(app.$('#panel'));
      ['Witness heat', 'EMS before re-listing', 'City news', 'Dirty money payouts'].forEach(function (t) {
        has(text, t);
      });
      truthy(app.$$('button[data-act="help-jump"]').some(function (b) {
        return b.getAttribute('data-key') === 'Roleplay.DirtyPayouts.Item' && b.getAttribute('data-view') === 'money';
      }), 'a link to the item, under Rewards & money');
    });
    clean(app, 'roleplay settings');
  })();

  /* ---- Roleplay (group rpC): help cards and the switches ---- */
  await (async function () {
    const view = settingsView();
    view.data.features.push({ key: 'Roleplay.Protection.Enabled', category: 'features',
      group: 'Roleplay: Bodyguards', label: 'Bodyguard contracts', about: 'A target may hire a bodyguard.',
      kind: 'switch', live: true, inflight: 'Jobs already posted are still paid.', value: false,
      default: false, shipped: false, hasShipped: true, source: 'config' });
    view.data.limits.push({ key: 'Roleplay.ProofOfIntent.HoldMaxMinutes', category: 'rules-timers',
      group: 'Roleplay: Proof of intent', label: 'Longest a payout is held for proof of intent (min)',
      kind: 'number', integer: true, min: 1, max: 10080, live: true, inflight: 'Read at every give.',
      value: 60, default: 60, source: 'config' });
    const app = boot(standardServer({ settings: view }));
    app.open(ADMIN);
    await settled();
    app.nav('help');
    await settled();
    const help = app.window.CH_ADMIN_HELP;
    it('How it works has a card for each rpC roleplay feature, linking to its settings', function () {
      ['proof of intent', 'reputation', 'bodyguards', 'hit on the hitman'].forEach(function (w) {
        const found = help.filter(function (c) { return c.title.toLowerCase().indexOf('roleplay: ' + w) === 0; });
        eq(found.length, 1, 'a card on ' + w);
        truthy(found[0].links.length >= 1, w + ' links to its settings');
        truthy(/off as shipped/i.test(found[0].text), w + ' says it ships off');
      });
    });
    const link = app.$$('button[data-act="help-jump"]').filter(function (b) {
      return b.getAttribute('data-key') === 'Roleplay.ProofOfIntent.HoldMaxMinutes';
    })[0];
    truthy(link, 'the hold time link');
    app.click(link);
    await settled();
    it('a roleplay help link lands on its setting under Rules > Timers', function () {
      eq(app.byId('nav-timers').getAttribute('aria-current'), 'page');
      truthy(app.byId('st-row-Roleplay.ProofOfIntent.HoldMaxMinutes').classList.contains('is-focus'));
    });
    app.nav('features');
    await settled();
    it('the bodyguard switch is under Features, in its Roleplay group', function () {
      has(app.main(), 'Roleplay: Bodyguards');
      truthy(app.byId('st-row-Roleplay.Protection.Enabled'), 'its row');
    });
    clean(app, 'roleplay rpC');
  })();

  /* ---- the roleplay features (Config.Roleplay) ---- */
  await (async function () {
    const places = { key: 'Roleplay.Rumours.Locations', category: 'rules-limits', group: 'Roleplay: Rumours and broker',
      label: 'Broker NPC places', kind: 'list', whole: true, live: true, inflight: 'Every game is told at once.',
      value: ['-1171.0, -1572.5, 4.66, 125.0'], default: [], source: 'config' };
    const lazy = { id: 'rv00000010', kind: 'low_effort_reason', about: 'a contract was placed or edited with a low-effort reason',
      contract: 'ct00000001', parties: [{ role: 'creator', who: 'the client' }], items: [],
      known: { matched: 'rdm', request: 'create' }, state: 'open', created_at: NOW - 100 };
    const server = standardServer({
      settings: settingsView({ limits: [places] }),
      reviews: { ok: true, data: { items: [lazy] } },
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('limits');
    await settled();
    const row = function () { return app.byId('st-row-Roleplay.Rumours.Locations'); };
    app.type(row().querySelector('input'), '1240.6, -3179.2, 7.1, 270.0');
    app.click(app.button('Add', row()));
    await settled();
    app.click(app.byId('st-save-Roleplay.Rumours.Locations'));
    app.click(app.byId('st-save-Roleplay.Rumours.Locations'));
    await settled();
    it('a place is added whole, commas and spaces kept', function () {
      eq(app.last('setSetting').data, { key: 'Roleplay.Rumours.Locations',
        value: ['-1171.0, -1572.5, 4.66, 125.0', '1240.6, -3179.2, 7.1, 270.0'] });
    });
    app.nav('reviews');
    await settled();
    const item = app.byId('rv-rv00000010');
    it('a low-effort reason in Needs review offers Dismiss alone: it holds no money', function () {
      has(app.text(item), 'low-effort reason');
      has(app.text(item), 'rdm');
      lacks(app.text(item), 'Refund it');
      lacks(app.text(item), 'Pay it');
      truthy(app.button('Dismiss it', item));
    });
    app.nav('help');
    await settled();
    it('How it works has a card for each roleplay feature', function () {
      ['Rumours and the broker', 'Burner phone', 'The informant in person', 'Reason quality'].forEach(function (t) {
        has(app.main(), t);
      });
    });
    clean(app, 'roleplay settings and review');
  })();

  /* ---- round 3 P8: the overview chain outlives a refresh that threw ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(FULL);
    await settled();
    const realGet = app.document.getElementById;
    let broken = true;
    app.document.getElementById = function (id) {
      if (broken && String(id).indexOf('count-') === 0) throw new Error('a draw failed');
      return realGet.apply(this, arguments);
    };
    const before = app.requests('overview').length;
    app.fire(10000);
    await settled();
    broken = false;
    it('round 3 P8: a refresh whose draw threw still sets the next one', function () {
      eq(app.requests('overview').length, before + 1, 'the refresh ran');
      eq(app.live(10000), 1, 'and the chain goes on');
    });
    app.fire(10000);
    await settled();
    it('round 3 P8: and the next one runs', function () {
      eq(app.requests('overview').length, before + 2);
      eq(app.live(10000), 1);
    });
  })();

  /* ---- round 3: admin.html gives the focus back when admin.js never came up ---- */
  await (function () {
    const scripts = [];
    PAGE_HTML.replace(/<script>([\s\S]*?)<\/script>/gi, function (_, body) { scripts.push(body); return _; });
    const loader = scripts.filter(function (s) { return s.indexOf('admin.js?v=') !== -1; })[0];
    function run() {
      const listeners = {};
      const posted = [];
      const appended = [];
      const sandbox = {
        window: { addEventListener: function (t, fn) { (listeners[t] = listeners[t] || []).push(fn); } },
        location: { hostname: 'cfx-nui-crimson-hitman' },
        document: {
          createElement: function () { return {}; },
          body: { appendChild: function (n) { appended.push(n); } }
        },
        GetParentResourceName: function () { return 'crimson-hitman-renamed'; },
        fetch: function (url) { posted.push(url); return Promise.resolve({}); },
        encodeURIComponent: encodeURIComponent
      };
      vm.createContext(sandbox);
      vm.runInContext(loader, sandbox, { filename: 'admin.html' });
      return {
        posted, appended, sandbox,
        fire: function (type, ev) { (listeners[type] || []).forEach(function (fn) { fn(ev || {}); }); }
      };
    }
    it('round 3: the loader posts adminClose when admin.js fails to load', function () {
      truthy(loader, 'the loader script is in admin.html');
      const page = run();
      eq(page.appended.length, 1, 'admin.js is loaded');
      page.appended[0].onerror();
      eq(page.posted, ['https://crimson-hitman-renamed/adminClose']);
    });
    it('round 3: and on an open that arrives while the page is not ready, or an error while loading', function () {
      const page = run();
      page.fire('message', { data: { type: 'open' } });
      page.fire('error');
      eq(page.posted.length, 2);
    });
    it('round 3: and never once admin.js has loaded', function () {
      const page = run();
      page.sandbox.window.CH_ADMIN_READY = true;
      page.fire('message', { data: { type: 'open' } });
      page.fire('error');
      eq(page.posted.length, 0);
    });
    it('round 3: admin.js says it loaded, at its end', function () {
      const app = boot(standardServer());
      eq(app.window.CH_ADMIN_READY, true);
    });
  })();

  /* ---- informant fairness (Config.Improvements) ---- */
  await (async function () {
    const zones = { key: 'Improvements.TipSafeZones.Zones', category: 'rules-targeting',
      group: 'Improvements: Tip safe zones', label: 'Safe zones (x, y, radius, name)', kind: 'list',
      whole: true, live: true, inflight: 'Read each time it is used.', value: [], default: [],
      source: 'config' };
    const server = standardServer({ settings: settingsView({ limits: [zones] }) });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('targeting');
    await settled();
    const row = function () { return app.byId('st-row-Improvements.TipSafeZones.Zones'); };
    app.type(row().querySelector('input'), '300, -590, 80, Pillbox Hill');
    app.click(app.button('Add', row()));
    await settled();
    app.click(app.byId('st-save-Improvements.TipSafeZones.Zones'));
    app.click(app.byId('st-save-Improvements.TipSafeZones.Zones'));
    await settled();
    it('a safe zone is added whole, commas and spaces kept', function () {
      eq(app.last('setSetting').data, { key: 'Improvements.TipSafeZones.Zones',
        value: ['300, -590, 80, Pillbox Hill'] });
    });
    app.nav('help');
    await settled();
    it('How it works has a card for each informant fairness option', function () {
      ['Tip warning delay', 'Tip limits', 'Hold before a tip', 'Informant second try', 'Tip safe zones',
        'Go dark'].forEach(function (t) { has(app.main(), t); });
    });
    clean(app, 'informant fairness settings');
  })();

  /* ---- Improvements (group impB): help cards, the switches, the tier list ---- */
  await (async function () {
    const view = settingsView();
    view.data.features.push({ key: 'Improvements.ContractDecay.Enabled', category: 'features',
      group: 'Improvements: Contract decay', label: 'Contract decay',
      about: 'An untaken contract\'s reward rises each step, charged to its placer.',
      kind: 'switch', live: true, inflight: 'At the next tick, with no restart.', value: false,
      default: false, shipped: false, hasShipped: true, source: 'config' });
    const tiers = { key: 'Improvements.Tiers.Tiers', category: 'rules-limits', group: 'Improvements: Tiered board',
      label: 'Tiers, as name, least reward, level', kind: 'list', whole: true, live: true,
      inflight: 'Read each time it is used.', value: ['Professional, 50000, 2'], default: [], source: 'config' };
    view.data.limits.push(tiers);
    const app = boot(standardServer({ settings: view }));
    app.open(ADMIN);
    await settled();
    app.nav('features');
    await settled();
    it('the contract decay switch is under Features, in its Improvements group', function () {
      has(app.main(), 'Improvements: Contract decay');
      truthy(app.byId('st-row-Improvements.ContractDecay.Enabled'), 'its row');
    });
    app.nav('limits');
    await settled();
    const row = function () { return app.byId('st-row-Improvements.Tiers.Tiers'); };
    app.type(row().querySelector('input'), 'Elite, 150000, 4');
    app.click(app.button('Add', row()));
    await settled();
    app.click(app.byId('st-save-Improvements.Tiers.Tiers'));
    app.click(app.byId('st-save-Improvements.Tiers.Tiers'));
    await settled();
    it('a tier is added whole, its commas and spaces kept', function () {
      eq(app.last('setSetting').data, { key: 'Improvements.Tiers.Tiers',
        value: ['Professional, 50000, 2', 'Elite, 150000, 4'] });
    });
    app.nav('help');
    await settled();
    const help = app.window.CH_ADMIN_HELP;
    it('How it works has a card for each board improvement, linking to its settings', function () {
      ['placer record', 'hitman heat', 'tiered board', 'contract decay'].forEach(function (w) {
        const found = help.filter(function (c) { return c.title.toLowerCase() === 'improvements: ' + w; });
        eq(found.length, 1, 'a card on ' + w);
        truthy(found[0].links.length >= 2, w + ' links to its settings');
        truthy(/off as shipped/i.test(found[0].text), w + ' says it ships off');
        found[0].links.forEach(function (l) {
          truthy(['features', 'limits', 'timers', 'money', 'targeting'].indexOf(l.view) !== -1, l.key + ' view');
        });
      });
    });
    const link = app.$$('button[data-act="help-jump"]').filter(function (b) {
      return b.getAttribute('data-key') === 'Improvements.ContractDecay.Enabled';
    })[0];
    truthy(link, 'the decay switch link');
    app.click(link);
    await settled();
    it('an improvement help link lands on its switch under Features', function () {
      eq(app.byId('nav-features').getAttribute('aria-current'), 'page');
      truthy(app.byId('st-row-Improvements.ContractDecay.Enabled').classList.contains('is-focus'));
    });
    clean(app, 'improvements impB');
  })();

  /* ---- the staff and economy improvements (Config.Improvements) ---- */
  await (async function () {
    const view = settingsView();
    view.data.features.push({ key: 'Improvements.ProofItems.Enabled', category: 'features',
      group: 'Improvements: Proof items', label: 'Proof items', about: 'A hitman may hand over an id card.',
      kind: 'switch', live: true, inflight: 'Read at every handover.', value: false,
      default: false, shipped: false, hasShipped: true, source: 'config' });
    view.data.limits.push({ key: 'Limits.TargetCooldownAfterCompletionSeconds', category: 'target-limits',
      group: 'Target limits',
      label: 'Wait after a completed contract before its target is listed again (s, 0 = off)',
      kind: 'number', integer: true, min: 0, max: 2592000, live: true, inflight: 'Read at every placing.',
      value: 0, default: 0, source: 'config' });
    const app = boot(standardServer({ settings: view }));
    app.open(ADMIN);
    await settled();
    app.nav('help');
    await settled();
    const help = app.window.CH_ADMIN_HELP;
    it('How it works has a card for each improvement, linking to its settings', function () {
      ['Proof items', 'Completion cooldown', 'Weapon serial scrubbing', 'Weekly stats to Discord'].forEach(function (t) {
        const found = help.filter(function (c) { return c.title === 'Improvements: ' + t; });
        eq(found.length, 1, 'a card on ' + t);
        truthy(found[0].links.length >= 1, t + ' links to its settings');
        truthy(/off as shipped/i.test(found[0].text), t + ' says it ships off');
      });
    });
    const link = app.$$('button[data-act="help-jump"]').filter(function (b) {
      return b.getAttribute('data-key') === 'Limits.TargetCooldownAfterCompletionSeconds';
    })[0];
    truthy(link, 'the completion cooldown link');
    app.click(link);
    await settled();
    it('the completion cooldown link lands on its setting under Target limits > Defaults', function () {
      eq(app.byId('nav-tldefaults').getAttribute('aria-current'), 'page');
      truthy(app.byId('st-row-Limits.TargetCooldownAfterCompletionSeconds').classList.contains('is-focus'));
    });
    app.nav('features');
    await settled();
    it('the proof items switch is under Features, in its Improvements group', function () {
      has(app.main(), 'Improvements: Proof items');
      truthy(app.byId('st-row-Improvements.ProofItems.Enabled'), 'its row');
    });
    clean(app, 'improvements impC');
  })();

  /* Round 3 performance: the settings rows' fixed parts (label, help,
     limits, defaults) come once, named by a hash; after that the server
     sends each row's key and what changes, and the page puts them back
     together. A hash it does not hold is asked for whole. */
  await (async function settingsSchemaOnce() {
    const FIXED = ['group', 'label', 'about', 'category', 'money', 'shipped', 'hasShipped', 'kind',
      'choices', 'min', 'integer', 'live', 'inflight', 'readonly', 'destroys', 'stricter', 'strict',
      'whole', 'default'];
    let schema = 'S1';
    function lean(full) {
      const data = Object.assign({}, full.data, { schema: schema, lean: true });
      ['features', 'limits'].forEach(function (list) {
        data[list] = full.data[list].map(function (row) {
          const out = {};
          Object.keys(row).forEach(function (k) { if (FIXED.indexOf(k) === -1) out[k] = row[k]; });
          return out;
        });
      });
      return { ok: true, data: data };
    }
    const full = settingsView();
    const server = standardServer({
      settings: function (data) {
        if (data.schema === schema) return lean(full);
        return { ok: true, data: Object.assign({}, full.data, { schema: schema }) };
      }
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('features');
    await settled();
    const whole = app.main();
    it('asks for the rows whole the first time', function () {
      eq(app.requests('settings')[0].data, {});
    });
    app.click(app.byId('st-row-Sources.cash.enabled').querySelector('.switch'));
    app.click(app.byId('st-row-Sources.cash.enabled').querySelector('.switch'));
    await settled();
    it('then names the fixed parts it holds, and draws the lean rows the same', function () {
      eq(app.last('settings').data, { schema: 'S1' });
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'config.lua: On');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'default: On');
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'set by ADMIN001');
      has(app.main(), 'Cash rewards');
      has(whole, 'Cash rewards');
    });
    // The server's fixed parts changed (a restart): a lean reply naming a
    // hash this page does not hold is not drawn; it asks again whole.
    const before = app.requests('settings').length;
    server.settings = function (data) {
      if (data.schema === 'S1') return lean(full); // a server that answers lean all the same
      return { ok: true, data: Object.assign({}, full.data, { schema: 'S2' }) };
    };
    schema = 'S2';
    app.click(app.byId('st-row-Sources.cash.enabled').querySelector('.switch'));
    app.click(app.byId('st-row-Sources.cash.enabled').querySelector('.switch'));
    await settled();
    it('asks again whole when the lean reply names other fixed parts', function () {
      const asked = app.requests('settings').slice(before);
      truthy(asked.length >= 2, JSON.stringify(asked.map(function (r) { return r.data; })));
      eq(asked[asked.length - 1].data, {});
      has(app.text(app.byId('st-row-Bailout.Enabled')), 'config.lua: On');
    });
    clean(app, 'settings schema sent once');
  })();

  /* ---- workflow round 3: S8 and S13 ---- */
  await (async function () {
    const named = contractDetail({
      contract: Object.assign({}, contractDetail(null, false).data.contract, { anonymous: false,
        mode: 'exclusive', client: { name: 'Vic Marlowe' } }),
      hitmen: [{ id: 'hm1', alias: 'Ghost', anonymous: false, name: 'Kai Holt', state: 'active',
        accepted_at: NOW - 1800, claims: 0, stake: 0 },
               { id: 'hm2', alias: 'Shade', anonymous: true, name: 'Anonymous', state: 'active',
        accepted_at: NOW - 1800, claims: 0, stake: 0 }]
    }, false);
    const settings = settingsView();
    settings.data.limits.push({ key: 'Limits.ExclusiveIdleReleaseSeconds', category: 'rules-timers',
      group: 'Contract limits', label: 'Idle release', kind: 'number', integer: true, min: 0, max: 86400,
      live: true, value: 10800, default: 10800, source: 'config' });
    const app = boot(standardServer({ contract: named, settings: settings,
      overview: overview({ overrides: 0 }) }));
    app.open(FULL);
    await settled();
    it('S13: the overview\'s settings link says what it opens, not a bare 0', function () {
      const link = app.$$('button').filter(function (b) {
        return b.getAttribute('data-section') === 'settings' && b.className.indexOf('link') !== -1;
      })[0];
      truthy(link, 'the link');
      eq(link.textContent.trim(), 'None changed — open Settings');
    });
    app.nav('contracts');
    await settled();
    app.click(app.$$('[data-act="contract"]')[0]);
    await settled();
    const drawerText = app.text(app.drawer());
    it('S13: says the mode with a capital, as every other term', function () {
      has(drawerText, 'ModeExclusive');
    });
    const parties = app.drawer().querySelectorAll('button').filter(function (b) {
      return b.getAttribute('data-act') === 'party-lookup';
    });
    it('S8: offers Look up / Freeze beside every party, by role (IdentityAce: anonymous ones too)', function () {
      eq(parties.map(function (b) { return b.getAttribute('data-subject'); }),
        ['contract:ct00000001:client', 'contract:ct00000001:target', 'contract:ct00000001:op:hm1',
         'contract:ct00000001:op:hm2']);
      has(app.text(parties[0]), 'Look up / Freeze');
    });
    app.click(parties[1]);
    await settled();
    it('S8: which opens Players on them, asked by the contract and the role, no citizen id', function () {
      eq(app.last('player').data.subject, 'contract:ct00000001:target');
      has(app.main(), 'Freeze');
    });
    app.type(app.byId('pl-q'), 'Dana Reyes');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('S8: Players takes a name, as Contracts does', function () {
      eq(app.last('player').data.subject, 'Dana Reyes');
      eq(app.byId('pl-q').getAttribute('placeholder'), 'Player id, citizen id or name');
    });
    app.nav('timers');
    await settled();
    it('S13: a duration in seconds says it in hours too', function () {
      has(app.main(), '10,800 s = 3 h');
    });
    clean(app, 'workflow round 3');
  })();

  await (async function () {
    const app = boot(standardServer());
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$$('[data-act="contract"]')[0]);
    await settled();
    it('S8: offers nobody anonymous to staff without IdentityAce: the client and an anonymous operative', function () {
      const subjects = app.drawer().querySelectorAll('button').filter(function (b) {
        return b.getAttribute('data-act') === 'party-lookup';
      }).map(function (b) { return b.getAttribute('data-subject'); });
      eq(subjects, ['contract:ct00000001:target']);
    });
    clean(app, 'anonymous parties');
  })();

  /* ---- final pass: the Features order, units, group headers, How it works ---- */
  await (async function () {
    const view = settingsView();
    function sw(key, group) {
      return { key: key, category: 'features', group: group, label: key.split('.').slice(-2).join(' '),
        kind: 'switch', live: true, value: false, default: false, shipped: false, hasShipped: true, source: 'config' };
    }
    view.data.features.push(sw('Improvements.GoDark.Enabled', 'Improvements: Go dark'));
    view.data.features.push(sw('Roleplay.CityNews.Enabled', 'Roleplay: City news'));
    view.data.features.push(sw('Staff.AppPaused', 'Staff tools'));
    view.data.features.push(sw('Advisory.Enabled', 'Law enforcement advisory'));
    view.data.features.push(sw('InformantsEnabled', 'Informant'));
    view.data.features.push(sw('Anonymity.AllowAnonymousCreate', 'Anonymity'));
    view.data.limits.push({ key: 'Informant.Cost', category: 'rules-rewards', group: 'Informant', money: 'Informant prices',
      label: 'Price of a look-up', kind: 'number', integer: true, min: 0, max: 1000000, live: true,
      value: 25000, default: 25000, source: 'config' });
    view.data.limits.push({ key: 'Roleplay.WitnessHeat.WitnessRadius', category: 'rules-limits',
      group: 'Roleplay: Witness heat', label: 'How far a bystander sees it from', kind: 'number', min: 1, max: 500,
      live: true, value: 60, default: 60, source: 'config' });
    const app = boot(standardServer({ settings: view }));
    app.open(ADMIN);
    await settled();
    app.nav('features');
    await settled();
    const rank = app.window.CH_ADMIN_FEATURE_RANK;
    it('Features lists the core first, then Anonymity, Informants, Advisory, Staff tools, Roleplay, Improvements', function () {
      const groups = app.$$('.st-group').map(function (g) { return g.getAttribute('data-group'); });
      const order = ['anonymity', 'informant', 'law enforcement advisory', 'staff tools', 'roleplay: city news',
        'improvements: go dark'];
      let last = -1;
      order.forEach(function (g) {
        const at = groups.indexOf(g);
        truthy(at > last, g + ' after the group before it: ' + groups.join(' | '));
        last = at;
      });
      truthy(groups.indexOf('buyouts') !== -1 && groups.indexOf('buyouts') < groups.indexOf('anonymity'),
        'a core group (Buyouts) before Anonymity');
      eq(rank('Access'), 0);
      truthy(rank('Anonymity') < rank('Informant tip') && rank('Informant tip') < rank('Law enforcement advisory')
        && rank('Law enforcement advisory') < rank('Staff tools') && rank('Staff tools') < rank('Roleplay: X')
        && rank('Roleplay: X') < rank('Improvements: Y'), 'the areas in order');
    });
    it('every group drawn says in one line what it does', function () {
      app.$$('.st-group').forEach(function (g) {
        truthy(g.querySelector('.st-group-about'), g.getAttribute('data-group') + ' has no line saying what it does');
      });
    });
    app.nav('money');
    await settled();
    it('every group in Rules says what it does too', function () {
      truthy(app.$$('.st-group').length > 0, 'groups');
      app.$$('.st-group').forEach(function (g) {
        truthy(g.querySelector('.st-group-about'), g.getAttribute('data-group') + ' has no line saying what it does');
      });
    });
    it('every number shows its unit: dollars, seconds, metres, percent', function () {
      has(app.text(app.byId('st-row-Informant.Cost')), 'Now: $25,000');
      const unit = app.window.CH_ADMIN_UNIT_OF;
      eq(unit({ key: 'Informant.Cost' }), '$');
      eq(unit({ key: 'Sources.cash.max' }), '$');
      eq(unit({ key: 'Limits.SlotCooldownSeconds' }), ' s');
      eq(unit({ key: 'PendingEscrow.LoginRetryDelayMs' }), ' ms');
      eq(unit({ key: 'Restart.MaxHoldMinutes' }), ' min');
      eq(unit({ key: 'Improvements.HitmanHeat.DecayHours' }), ' h');
      eq(unit({ key: 'Audit.ContractRetentionDays' }), ' d');
      eq(unit({ key: 'Roleplay.WitnessHeat.WitnessRadius' }), ' m');
      eq(unit({ key: 'Improvements.ContractDecay.Percent' }), '%');
      eq(unit({ key: 'Bailout.MaxMultiplier' }), ' \u00d7');
      eq(unit({ key: 'Limits.MaxActiveContractsPerCreator' }), '', 'a count has none');
    });
    app.nav('help');
    await settled();
    it('How it works: every optional feature has a card, titled by its area, in config.lua\'s order', function () {
      const ordered = app.window.CH_ADMIN_HELP_ORDERED();
      eq(app.$$('.help-card').length, ordered.length);
      const titles = ordered.map(function (c) { return c.title; });
      const rp = titles.filter(function (t) { return /^Roleplay: /.test(t); });
      const imp = titles.filter(function (t) { return /^Improvements: /.test(t); });
      eq(rp.length, 12, 'twelve roleplay cards: ' + rp.join(', '));
      eq(imp.length, 14, 'thirteen improvements and the completion cooldown: ' + imp.join(', '));
      truthy(titles.indexOf(rp[0]) > titles.indexOf('Moderators'), 'Roleplay after the staff tools');
      truthy(titles.indexOf(imp[0]) > titles.indexOf(rp[rp.length - 1]), 'Improvements after Roleplay');
      truthy(titles.indexOf('Anonymity') < titles.indexOf('The informants')
        && titles.indexOf('The informants') < titles.indexOf('Police advisories')
        && titles.indexOf('Police advisories') < titles.indexOf('The staff freeze'), 'the core areas in order');
      eq(rp[0], 'Roleplay: Witness heat', 'config.lua\'s first roleplay block first');
      eq(imp[0], 'Improvements: Tip warning delay', 'and its first improvement');
    });
    app.nav('actions');
    await settled();
    it('Actions offers the hardest one to find: undoing a setting change, in History', function () {
      has(app.main(), 'Undo a setting change');
      truthy(app.$$('button[data-act="section"]').some(function (b) {
        return b.getAttribute('data-section') === 'history';
      }), 'a button to History');
    });
    clean(app, 'final pass panel');
  })();

  /* ---- sweep 4 D2: every write names the player by the lookup's handle ---- */
  await (async function () {
    let lookups = 0;
    const server = staffPlayerServer({
      player: function (data) {
        lookups += 1;
        const reply = player();
        reply.data.payMax = 100000;
        // A fresh handle each lookup, as the server gives one.
        reply.data.player.ref = data.ref ? 'p9_' + lookups : 'p8_' + lookups;
        return reply;
      }
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    await lookUp(app);
    const first = app.last('player').data;
    // Somebody else is typed in the box after the lookup.
    app.type(app.byId('pl-q'), 'Someone Else');
    app.type(app.byId('pay-amount'), '100');
    app.type(app.byId('pay-reason'), 'refund');
    app.click(app.button('Pay'));
    await settled();
    app.click(app.button('Pay'));
    await settled();
    const pay = app.last('manualPay').data;
    it('sweep 4 D2: a payment names the player by the lookup\'s handle, never by what was typed', function () {
      eq(first, { subject: '12' }, 'the lookup sends what was typed');
      eq(pay.ref, 'p8_1');
      eq(pay.subject, undefined, 'no name or player id for the server to match again');
    });
    it('sweep 4 D2: and reads the card again by that handle, not by the box', function () {
      eq(app.last('player').data, { ref: 'p8_1' });
      eq(app.last('history').data, { ref: 'p9_2' }, 'the history by the handle the reread gave');
    });
    app.type(app.byId('ps-reason'), 'spam');
    app.click(app.button('3 days'));
    await settled();
    app.click(app.button('Suspend'));
    await settled();
    app.click(app.button('Suspend'));
    await settled();
    it('sweep 4 D2: the next write uses the handle the reread gave', function () {
      eq(app.last('suspend').data, { ref: 'p9_2', days: 3, reason: 'spam' });
    });
    ['freeze', 'unfreeze', 'suspend', 'unsuspend', 'protect', 'unprotect', 'manualPay', 'setPlaytime']
      .forEach(function (op) {
        app.requests(op).forEach(function (r) {
          it('sweep 4 D2: ' + op + ' carries no subject', function () { eq(r.data.subject, undefined); });
        });
      });
    clean(app, 'sweep 4 lookup handle');
  })();

  await (async function () {
    const app = boot(staffPlayerServer({
      manualPay: { ok: false, err: 'stale_lookup',
        message: 'That lookup is out of date, so nothing was changed. Look them up again.' }
    }));
    app.open(ADMIN);
    await settled();
    await lookUp(app);
    app.type(app.byId('pay-amount'), '100');
    app.type(app.byId('pay-reason'), 'refund');
    app.click(app.button('Pay'));
    await settled();
    it('sweep 4 D2: the first click of a payment still sends nothing', function () {
      eq(app.requests('manualPay').length, 0);
    });
    app.click(app.button('Pay'));
    await settled();
    it('sweep 4 D2: a stale handle is refused in words: look them up again', function () {
      eq(app.requests('manualPay').length, 1);
      has(app.toasts(), 'Look them up again.');
    });
    clean(app, 'sweep 4 stale handle');
  })();

  /* ---- sweep 5 review: an armed button never carries over to another subject ---- */
  await (async function () {
    const server = standardServer({
      player: function (data) {
        const reply = player();
        const b = data && (data.subject === '13' || data.ref === 'p7_BBBBBB');
        reply.data.player.ref = b ? 'p7_BBBBBB' : 'p7_AAAAAA';
        reply.data.player.cid = b ? 'TARGET02' : 'TARGET01';
        reply.data.frozen = { since: NOW - 60, reason: 'RP dispute' };
        return reply;
      },
      frozen: { ok: true, data: { rows: [] } },
      unfreeze: { ok: true, message: 'Unfrozen.' },
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    app.click(app.button('Unfreeze'));
    await settled();
    it('sweep 5 review: Unfreeze on the first player is armed', function () {
      eq(app.requests('unfreeze').length, 0);
      truthy(app.button('Unfreeze').classList.contains('is-armed'));
    });
    app.type(app.byId('pl-q'), '13');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('sweep 5 review: looking up another player leaves nothing armed', function () {
      eq(app.last('player').data, { subject: '13' });
      falsy(app.button('Unfreeze').classList.contains('is-armed'), 'still armed on the second player');
    });
    app.click(app.button('Unfreeze'));
    await settled();
    it('sweep 5 review: one click on the second player\'s Unfreeze sends nothing', function () {
      eq(app.requests('unfreeze').length, 0, 'unfroze the second player on one click');
    });
    app.click(app.button('Unfreeze'));
    await settled();
    it('sweep 5 review: the second click unfreezes the player shown', function () {
      eq(app.requests('unfreeze').length, 1);
      eq(app.last('unfreeze').data.ref, 'p7_BBBBBB');
    });
    clean(app, 'sweep 5 review player arm');
  })();

  await (async function () {
    const app = boot(standardServer({
      contracts: contracts({ rows: [contractRow(1), contractRow(2)] }),
    }));
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    app.click(app.$$('tr.row')[0]);
    await settled();
    app.type(app.drawer().querySelector('[data-bind="dr.reason"]'), 'Duplicate');
    app.click(app.button('Void contract', app.drawer()));
    await settled();
    it('sweep 5 review: Void on the first contract is armed', function () {
      eq(app.requests('void').length, 0);
      truthy(app.button('Void contract', app.drawer()).classList.contains('is-armed'));
    });
    app.click(app.$$('tr.row')[1]);
    await settled();
    it('sweep 5 review: opening another contract leaves nothing armed', function () {
      eq(app.last('contract').data, { id: 'ct00000002' });
      falsy(app.button('Void contract', app.drawer()).classList.contains('is-armed'), 'still armed');
    });
    app.type(app.drawer().querySelector('[data-bind="dr.reason"]'), 'Duplicate');
    app.click(app.button('Void contract', app.drawer()));
    await settled();
    it('sweep 5 review: one click on the second contract\'s Void sends nothing', function () {
      eq(app.requests('void').length, 0, 'voided the second contract on one click');
    });
    clean(app, 'sweep 5 review drawer arm');
  })();

  /* ---- Target limits (server/targetlimits.lua): its own section ---- */
  const TL_KEYS = [
    { key: 'TargetCooldownAfterResolveSeconds', label: 'Wait after a contract on them ends', unit: 's', min: 0,
      max: 604800, value: 1800 },
    { key: 'SameCreatorSameTargetCooldownSeconds', label: 'Wait before the same placer names them again', unit: 's',
      min: 0, max: 604800, value: 7200 },
    { key: 'TargetCooldownAfterCompletionSeconds', label: 'Wait after a completed contract on them', unit: 's',
      min: 0, max: 2592000, value: 0 },
    { key: 'MaxActiveContractsPerTarget', label: 'Live contracts on them at once', unit: 'contracts', min: 1,
      max: 50, value: 2 },
    { key: 'MaxContractsPerTargetPerDay', label: 'Contracts placed on them in 24 hours', unit: 'contracts', min: 0,
      max: 100, value: 0 },
    { key: 'MaxContractsPerTargetPerWeek', label: 'Contracts placed on them in 7 days', unit: 'contracts', min: 0,
      max: 500, value: 0 }
  ];
  function tlServer(extra) {
    return standardServer(Object.assign({
      targetLimits: { ok: true, data: { keys: TL_KEYS, jobMax: 32, extendMax: 43200, overrideMaxHours: 8760,
        ignored: 0, jobs: [{ job: 'police', limits: { TargetCooldownAfterResolveSeconds: 7200 }, at: NOW,
          effective: { TargetCooldownAfterResolveSeconds: 7200, SameCreatorSameTargetCooldownSeconds: 7200,
            TargetCooldownAfterCompletionSeconds: 0, MaxActiveContractsPerTarget: 2, MaxContractsPerTargetPerDay: 0,
            MaxContractsPerTargetPerWeek: 0 } }] } },
      targetJobSet: function (d) { return { ok: true, message: 'Targets working as ' + d.job + ' now have these limits.' }; },
      targetJobRemove: { ok: true, message: 'Removed.' },
      targetJobCount: function (d) { return { ok: true, data: { job: d.job, count: 3 } }; },
      targetJobAction: function (d) { return { ok: true, message: d.job + ': 3 player(s) had their cooldowns reset.',
        data: { done: 3, failed: 0 } }; },
      targetStatus: { ok: true, data: { player: { name: XSS, online: true, ref: 'p1_123456' },
        status: { live: 1, day: 2, week: 3, dayAll: 2, weekAll: 3, cooldownLeft: 1500,
          cooldownRule: 'TargetCooldownAfterResolveSeconds', cooldownFrom: 'job', exempt: false, job: 'police',
          jobFrom: 'now', source: { TargetCooldownAfterResolveSeconds: 'job' },
          limits: { TargetCooldownAfterResolveSeconds: 7200, MaxActiveContractsPerTarget: 2 } } } },
      targetReset: { ok: true, message: 'Their cooldown is cleared.' },
      targetExtend: { ok: false, err: 'stale_lookup', message: 'That lookup is out of date, so nothing was changed. Look them up again.' },
      targetCounts: { ok: true, message: 'Their day and week counts start again from now.' },
      targetOverride: { ok: true, message: 'They are exempt from the target limits.' },
      targetOverrideClear: { ok: false, err: 'not_active', message: 'Nothing like that is set, so nothing was changed.' },
      targetContracts: { ok: true, data: { page: 1, pages: 1, total: 3, targets: 2, rows: [
        { id: 'ct00000001', state: 'active', rule: 'alive', target: 'Dana Reyes', group: 't1', onTarget: 2,
          client: 'Anonymous', anonymous: true, slots: 1, claimed: 0, created_at: NOW - 60, deadline_at: NOW + 3600 },
        { id: 'ct00000002', state: 'accepted', rule: 'alive', target: 'Dana Reyes', group: 't1', onTarget: 2,
          client: XSS, slots: 1, claimed: 0, created_at: NOW - 120, deadline_at: NOW + 3600, frozen: true },
        { id: 'ct00000003', state: 'active', rule: 'either', target: XSS, group: 't2', onTarget: 1,
          client: 'Vic Marlowe', slots: 1, claimed: 0, created_at: NOW - 30 }] } }
    }, extra || {}));
  }

  await (async function targetLimitsSection() {
    const app = boot(tlServer());
    app.open(ADMIN);
    await settled();
    app.click(app.byId('grp-targets'));
    await settled();
    it('Target limits: its own section after Rules, opening on Defaults (the settings view)', function () {
      eq(app.byId('nav-tldefaults').getAttribute('aria-current'), 'page');
      eq(app.byId('nav-tljobs').hidden, false);
      eq(app.byId('nav-tlplayer').hidden, false);
      eq(app.byId('nav-tlcontracts').hidden, false);
      eq(app.byId('nav-timers').hidden, true);
      truthy(app.requests('settings').length >= 1, 'reads the settings');
    });

    app.nav('tljobs');
    await settled();
    it('Per job lists each job with its own and its effective values', function () {
      has(app.main(), 'police');
      has(app.main(), '2 h');
      has(app.main(), 'in bold, the job');
    });
    app.type(app.byId('tj-job'), 'Police');
    app.type(app.byId('tj-TargetCooldownAfterResolveSeconds'), '9000');
    app.click(app.byId('tj-save'));
    await settled();
    it('Save job limits takes two clicks, naming the job', function () {
      eq(app.requests('targetJobSet').length, 0, 'sent on one click');
      truthy(app.byId('tj-save').classList.contains('is-armed'));
      has(app.byId('tj-save').textContent, 'police');
    });
    app.click(app.byId('tj-save'));
    await settled();
    it('the second click sends the job and only the limits filled in', function () {
      eq(app.last('targetJobSet').data, { job: 'police', limits: { TargetCooldownAfterResolveSeconds: 9000 } });
    });
    app.type(app.byId('tj-TargetCooldownAfterResolveSeconds'), '99999999');
    app.click(app.byId('tj-save'));
    await settled();
    it('a value out of range is refused on the page, nothing sent', function () {
      eq(app.requests('targetJobSet').length, 1);
      has(app.main(), 'whole number from 0 to 604800');
    });
    const remove = app.button('Remove');
    app.click(remove);
    await settled();
    it('Remove takes two clicks', function () {
      eq(app.requests('targetJobRemove').length, 0);
      app.click(app.button('Remove'));
    });
    await settled();
    it('the second Remove sends the job', function () { eq(app.last('targetJobRemove').data, { job: 'police' }); });

    const typedIn = app.byId('tja-job');
    app.type(typedIn, 'police');
    app.fire(250);
    await settled();
    it('the count arrives without redrawing the box being typed in', function () {
      truthy(app.byId('tja-job') === typedIn, 'the job box was drawn again');
      has(app.byId('tja-count').textContent, '3 players working police');
    });
    app.type(app.byId('tja-reason'), 'event');
    app.click(app.button('Reset cooldowns'));
    await settled();
    it('a job action\'s confirm names the job and how many players it reaches', function () {
      eq(app.last('targetJobCount').data, { job: 'police' });
      eq(app.requests('targetJobAction').length, 0, 'sent on one click');
      has(app.main(), 'Click again: reset 3 players working police');
    });
    app.click(app.button('Reset cooldowns'));
    await settled();
    it('the second click resets the whole job, with the reason', function () {
      eq(app.last('targetJobAction').data, { job: 'police', action: 'reset', all: false, reason: 'event' });
      has(app.main(), '3 player(s)');
    });
    app.click(app.button('Extend cooldowns'));
    await settled();
    it('Extend cooldowns for a job needs the minutes, and sends nothing without', function () {
      eq(app.requests('targetJobAction').length, 1);
      has(app.main(), 'Give the minutes to add');
    });
    clean(app, 'target limits per job');
  })();

  await (async function targetLimitsPlayer() {
    const app = boot(tlServer());
    app.open(access({ canWrite: false, canModerate: true, canIdentify: false }));
    await settled();
    app.nav('tlplayer');
    await settled();
    app.type(app.byId('tp-q'), 'Dana');
    app.click(app.button('Look up'));
    await settled();
    it('Per player looks them up and shows their standing exactly, with the rule that set it', function () {
      eq(app.last('targetStatus').data, { subject: 'Dana' });
      has(app.main(), '25 min');
      has(app.main(), 'job: police');
      has(app.main(), 'from the job limits');
      eq(app.body.querySelectorAll('img').length, 0, 'the name was escaped');
    });
    app.click(app.button('Reset cooldown'));
    await settled();
    it('a write without a reason is refused on the page', function () {
      eq(app.requests('targetReset').length, 0);
      has(app.main(), 'Give a reason');
    });
    app.type(app.byId('tp-reason'), 'ticket 12');
    app.click(app.button('Reset cooldown'));
    await settled();
    it('Reset cooldown takes two clicks, as a moderator', function () {
      eq(app.requests('targetReset').length, 0);
    });
    app.click(app.button('Reset cooldown'));
    await settled();
    it('the second click sends the lookup\'s ref, never the name', function () {
      eq(app.last('targetReset').data, { ref: 'p1_123456', reason: 'ticket 12', all: false });
    });
    for (const [label, op] of [['Reset all', 'targetReset'], ['Reset counts', 'targetCounts']]) {
      const before = app.requests(op).length;
      app.click(app.button(label));
      await settled();
      it(label + ' takes two clicks', function () { eq(app.requests(op).length, before); });
      app.click(app.button(label));
      await settled();
      it(label + ' sends on the second', function () { eq(app.requests(op).length, before + 1); });
    }
    app.type(app.byId('tp-min'), '30');
    app.click(app.button('Extend by minutes'));
    await settled();
    app.click(app.button('Extend by minutes'));
    await settled();
    it('a refusal from the server is shown on the card (a stale lookup)', function () {
      eq(app.last('targetExtend').data, { ref: 'p1_123456', reason: 'ticket 12', minutes: 30 });
      has(app.main(), 'out of date');
    });
    app.click(app.button('Exempt from limits'));
    await settled();
    app.type(app.byId('tpo-hours'), '0');
    app.click(app.button('Make exempt'));
    await settled();
    it('Make exempt takes two clicks', function () { eq(app.requests('targetOverride').length, 0); });
    app.click(app.button('Make exempt'));
    await settled();
    it('then sends exempt for good', function () {
      eq(app.last('targetOverride').data, { ref: 'p1_123456', reason: 'ticket 12', exempt: true, hours: 0 });
    });
    app.click(app.button('Lift their own limits'));
    await settled();
    app.click(app.button('Lift their own limits'));
    await settled();
    it('Lift their own limits: two clicks, and the refusal shown', function () {
      eq(app.requests('targetOverrideClear').length, 1);
      has(app.main(), 'Nothing like that is set');
    });
    clean(app, 'target limits per player');
  })();

  await (async function targetLimitsReadOnly() {
    const app = boot(tlServer());
    app.open(READER);
    await settled();
    app.nav('tlplayer');
    await settled();
    app.type(app.byId('tp-q'), 'Dana');
    app.click(app.button('Look up'));
    await settled();
    it('a reader sees the standing and every write disabled', function () {
      has(app.main(), '25 min');
      truthy(app.button('Reset cooldown').disabled, 'Reset cooldown open to a reader');
      truthy(app.button('Set their limits').disabled, 'override open to a reader');
    });
    app.nav('tljobs');
    await settled();
    it('a reader cannot save a job\'s limits', function () { truthy(app.byId('tj-save').disabled); });
    clean(app, 'target limits read only');
  })();

  await (async function targetLimitsCurrent() {
    const app = boot(tlServer());
    app.open(ADMIN);
    await settled();
    app.nav('tlcontracts');
    await settled();
    it('Current contracts lists every live contract grouped by target, escaped', function () {
      eq(app.last('targetContracts').data, { page: 1 });
      eq(app.$$('tr.tl-group').length, 2);
      eq(app.$$('tr.row').length, 3);
      has(app.main(), 'On hold');
      has(app.main(), '3 live contracts on 2 targets');
      eq(app.body.querySelectorAll('img').length, 0, 'escaped');
    });
    app.type(app.byId('tc-q'), 'Dana');
    app.fire(250);
    await settled();
    it('the search asks by target', function () { eq(app.last('targetContracts').data, { page: 1, query: 'Dana' }); });
    app.click(app.$$('tr.row')[1]);
    await settled();
    it('a row opens the existing contract drawer, with its staff actions', function () {
      eq(app.last('contract').data, { id: 'ct00000002' });
      eq(app.drawer().hidden, false);
      truthy(app.button('Void contract', app.drawer()), 'the drawer\'s own Void');
    });
    clean(app, 'target limits current contracts');
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
