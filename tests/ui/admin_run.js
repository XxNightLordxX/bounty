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
const { makeDocument, localeXhr } = require('./dom.js');
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

/* Each row's feature area, as server/settings.lua sends it (Settings.areaOf). */
const AREA_OF_GROUP = { 'Rewards': 'rewards', 'Buyouts': 'buyouts', 'The app': 'access', 'Completion': 'completing',
  'Messages and calls': 'messages', 'Contract limits': 'placing', 'Stakes': 'placing', 'Advisory job lists': 'police',
  'Notifications': 'messages', 'Rate limits': 'engine', 'Staff': 'staff', 'Edit in config.lua': 'engine',
  'Target limits': 'targets', 'Organisation': 'organisation', 'Organisation: Boss limits': 'organisation' };
function withAreas(data) {
  ['features', 'limits', 'readonly'].forEach(function (list) {
    (data[list] || []).forEach(function (row) {
      if (row.area === undefined) row.area = AREA_OF_GROUP[row.group] || 'other';
    });
  });
  return data;
}

function settingsView(extra) {
  return { ok: true, data: withAreas(Object.assign({
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
  }, extra || {})) };
}

/* The organisation, as server/org/staff_ops.lua's orgGet answers
   (Org.staffView): switched off, or on with two roles, two members, a
   ceiling, spots, cuts and limits. */
const POWERS = [
  { code: 'M1', area: 'members', label: 'View members', about: 'See the member list.' },
  { code: 'M2', area: 'members', label: 'Hire', office: true, limits: ['MaxMembers', 'HireRadius'], about: 'Add a player.' },
  { code: 'C7', area: 'money', label: 'Withdraw funds', office: true, limits: ['WithdrawMax'], about: 'Take money out.' },
  { code: 'N1', area: 'notices', label: 'Post notice ' + XSS, limits: ['NoticeMaxLength'], about: 'Edit the notice.' }
];
function orgOff() { return { ok: true, data: { enabled: false, job: 'hitman' } }; }
function orgOn(extra) {
  return { ok: true, data: Object.assign({
    enabled: true, loaded: true, job: 'hitman', label: 'The Crimson ' + XSS, type: 'leo', requireJob: true,
    roles: [
      { grade: 3, name: 'boss', label: 'Boss', pay: 500, boss: true, members: 1, powers: { M1: { by: 'staff' } },
        editable: true },
      { grade: 1, name: 'hitman', label: 'Hitman ' + XSS, pay: 100, members: 1, powers: {}, editable: true }
    ],
    members: [
      { ref: 'm1_1111', name: 'Kai Holt', grade: 3, role: 'Boss', online: true, joined: NOW - 86400, lastSeen: NOW - 60,
        boss: true, grants: {}, denies: {}, limits: {}, held: { M1: true } },
      { ref: 'm2_2222', name: XSS, grade: 1, role: 'Hitman', online: false, joined: NOW - 3600, lastSeen: NOW - 600,
        grants: { M1: { by: 'staff' } }, denies: {}, limits: { maxAtOnce: 2 }, held: {} }
    ],
    ceiling: { role: { 3: { M1: 'allow' } }, member: { m1_1111: { C7: 'deny' } } },
    cuts: { payout: 10, stake: 0, buyout: 0, byRole: { 1: 5 }, byMember: {} },
    limits: { MaxMembers: 30, HireRadius: 3, WithdrawMax: 5000, NoticeMaxLength: 400, TotalCutCapPercent: 40,
      CutMaxPercent: 25, StakeCutMaxPercent: 20, BuyoutCutMaxPercent: 20 },
    officeStaff: { M2: true, C7: true }, officeBoss: {}, notice: { text: 'Meet at ' + XSS, at: NOW - 120 },
    access: { 1: { maxReward: 50000, rule: 'alive' } }, balance: 12500, bank: false,
    applications: [{ id: 'hitman:app:1', name: 'Rook ' + XSS, body: 'I am quiet ' + XSS, at: NOW - 300 }],
    powers: POWERS, warnings: [], layout: { labels: { members: 'Crew' }, hidden: { funds: [1] } }
  }, extra || {}) };
}

/** placeList as server/places.lua answers it: every kind, with its rows. */
function placesView(opts) {
  opts = opts || {};
  const ORG = { label: true, radius: true, blip: true, enabled: true };
  const orgOff = opts.org === false ? 'Its places (boss office, sign-up and meeting spots) are set here once the '
    + 'organisation is on.' : null;
  function org(id, label, one, icon, rows, single) {
    return { id: id, group: 'org', label: label, one: one, icon: icon, fields: ORG, labelMax: 64, single: !!single,
      radius: { min: 0.5, max: 50, default: 2 }, off: orgOff, switch: 'Organisation.Enabled', rows: orgOff ? [] : rows };
  }
  const npc = opts.npc || { enabled: false, rows: [] };
  const npcOff = npc.enabled ? null : 'Turn on Roleplay.NpcPlaces (Switches) to place the broker and informant from here.';
  function rp(id, label, rows, defaults, key) {
    return { id: id, group: 'npc', label: label, one: id + ' place', icon: 'user-secret',
      fields: { label: true, enabled: true }, labelMax: 40, labelOptional: true, reset: true, max: 20, off: npcOff,
      switch: 'Roleplay.NpcPlaces.Enabled', rows: rows, defaults: defaults, on: true,
      using: rows.length && npc.enabled ? 'panel' : 'config', key: key };
  }
  const dp = opts.disposal || {};
  function disposal(id, label, one, icon, rows) {
    return { id: id, group: 'disposal', label: label, one: one, icon: icon, fields: {}, single: true, max: 1,
      rows: rows, defaults: [], on: true, switch: 'Disposal.Enabled', using: rows.length ? 'panel' : 'config',
      note: 'Body disposal cannot start a step until both are set.' };
  }
  return { ok: true, data: { readable: true, kinds: [
    org('office', 'Boss office', 'boss office', 'building', [{ id: 'hitman:office:1', kind: 'office',
      label: 'Back room ' + XSS, x: 10.5, y: -20.25, z: 30, heading: 90, radius: 2, blip: true, enabled: true }], true),
    org('signup', 'Sign-up spots', 'sign-up spot', 'clipboard', []),
    org('meeting', 'Meeting and handover spots', 'meeting spot', 'handshake', []),
    org('npc', 'NPC spots', 'NPC spot', 'user-tie', []),
    org('place', 'Other organisation places', 'place', 'location-dot', []),
    rp('broker', 'Broker NPC', npc.rows || [], [{ x: -1212.4, y: -1500.2, z: 4.4, h: 90 }], 'Intel.Rumours.Locations'),
    rp('informant', 'Informant NPC', [], [], 'Intel.InPerson.Locations'),
    disposal('disposal_vehicle', 'Disposal vehicle spawn', 'the vehicle spawn', 'truck', dp.vehicle || []),
    disposal('disposal_drop', 'Body drop-off', 'the drop-off', 'flag-checkered', dp.drop || [])
  ] } };
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
  // Most of these tests start on Home's Overview, as the panel once
  // opened: a remembered view says so. opts.fresh opens it as a first open
  // does, with nothing remembered (on Home's Inbox).
  else if (!(opts && opts.fresh)) {
    const kept = { 'crimson-hitman.admin.nav': JSON.stringify({ view: (opts && opts.start) || 'overview', sub: {} }) };
    window.localStorage = { getItem: function (k) { return kept[k] || null; }, setItem: function (k, v) { kept[k] = v; } };
  }

  const sandbox = {
    document: document,
    window: window,
    // The page reads its words (locales/en.json) as it loads.
    XMLHttpRequest: localeXhr(),
    // FiveM's NUI page has it, and the page is to post to whatever it says.
    GetParentResourceName: function () { return 'crimson-hitman-renamed'; },
    fetch: function (url, options) {
      urls.push(url);
      const event = url.split('/').pop();
      const body = JSON.parse(options.body);
      if (sent.length > 400) throw new Error('runaway request loop: ' + sent.length + ' requests');
      // Records › Logs is one op; each log is its area, answered and
      // counted here as logs.<area> (logs alone: the audit log).
      const op = body.op === 'logs' && body.data && body.data.area ? 'logs.' + body.data.area : body.op;
      sent.push({ event: event, op: op, data: body.data, body: body });
      if (server.__fetchFails && server.__fetchFails(body)) return Promise.reject(new Error('no route'));
      let answer;
      if (event === 'adminClose') answer = { ok: true };
      else if (event === 'adminRequest') {
        answer = server[op];
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
    /** A view by its sub-tab when it is on the strip; any other (another
        section's, or an old name that redirects) the way a link reaches
        it, through the page's own show. */
    nav: function (section) {
      const node = document.getElementById('nav-' + section);
      if (node && app.visible(node)) { app.click(node); return; }
      try { window.CH_ADMIN_SHOW(section); } catch (err) { thrown.push(err); throw err; }
    },
    /** A section by its sidebar button. */
    group: function (id) { app.click(document.getElementById('grp-' + id)); },
    /** One of the contract drawer's tabs: summary, money, people, notes, record. */
    tab: function (id) {
      const node = document.getElementById('drawer').querySelectorAll('[data-act="dr-tab"]')
        .filter(function (b) { return b.getAttribute('data-value') === id; })[0];
      if (!node) throw new Error('no drawer tab ' + id);
      app.click(node);
    },
    /** One of Game rules' areas ('' for every area). */
    area: function (id) {
      const node = document.body.querySelectorAll('[data-act="gr-area"]')
        .filter(function (b) { return b.getAttribute('data-value') === id; })[0];
      if (!node) throw new Error('no area ' + id);
      app.click(node);
    },
    /** One of Game rules' type chips ('' for all). */
    type_: function (value) {
      const node = document.body.querySelectorAll('[data-act="gr-type"]')
        .filter(function (b) { return b.getAttribute('data-value') === value; })[0];
      if (!node) throw new Error('no type chip ' + value);
      app.click(node);
    },
    /** The drawer's More: where Void is. */
    more: function () {
      const node = document.getElementById('drawer').querySelectorAll('[data-act="dr-more"]')[0];
      if (!node) throw new Error('no More in the drawer');
      app.click(node);
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
      has(app.main(), 'Inbox8waiting for you', 'the inbox: reviews, money left for staff and alerts');
      has(app.main(), 'Needs review 3');
      has(app.main(), 'Money waiting 1', 'what staff settle, not every line listed');
      has(app.main(), '1 more line listed need nothing from you', 'and the rest said apart');
      has(app.main(), 'Operatives3on contracts now, holding 2 contracts', 'operatives, and the contracts they hold');
      has(app.main(), 'Alive only', 'the rule new contracts are placed under');
      has(app.main(), 'photo hosts: 0', 'the setup problems, for staff who can change things');
      lacks(app.main(), '7.20 ms', 'the slow jobs are Developer, Health\'s');
      lacks(app.main(), '400.0 KB', 'and the kill photos\' bytes');
    });
    it('posts to its own resource, as GetParentResourceName names it', function () {
      truthy(app.urls[0].indexOf('https://crimson-hitman-renamed/adminRequest') === 0, app.urls[0]);
    });
    it('counts what waits on the sidebar: the inbox on Home, changed settings, open alerts', function () {
      eq(app.byId('count-home').textContent, '8', 'reviews 3, money left for staff 1, alerts 4');
      eq(app.byId('count-home').hidden, false);
      eq(app.byId('count-inbox').textContent, '8', 'and on the Inbox sub-tab');
      eq(app.byId('count-overview'), null, 'and not beside the overview');
      eq(app.byId('count-rules').textContent, '2', 'Game rules: changed from the panel');
      eq(app.byId('count-logs').textContent, '4', 'Logs: open alerts');
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
      has(app.main(), 'Not listed while the server is recovering');
    });
    app.nav('health');
    await settled();
    it('and Developer, Health reads them the same way', function () {
      clean(app, 'empty health');
      has(app.main(), 'Kill photosOff', 'kill photos switched off, said as that');
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
    app.more();
    app.tab('money');
    it('read-only staff: void and every settle are disabled, saying why', function () {
      const drawer = app.drawer();
      eq(app.button('Void contract', drawer).disabled, true);
      has(app.button('Void contract', drawer).getAttribute('title'), 'Read only');
      ['Pay', 'Pay amount', 'Return', 'Delivered', 'Return to'].forEach(function (label) {
        eq(app.button(label, drawer).disabled, true, label);
      });
    });
    app.nav('rules:switch');
    await settled();
    it('and every setting', function () {
      app.$$('.switch').forEach(function (s) { eq(s.disabled, true, 'switch ' + s.getAttribute('data-key')); });
      app.$$('.seg-btn').filter(function (b) { return b.getAttribute('data-act') === 'st-choice'; })
        .forEach(function (b) { eq(b.disabled, true); });
    });
    app.nav('inbox:reviews');
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
    });
    app.tab('people');
    it('with identity: and the operatives\' on People', function () {
      has(app.text(app.drawer()), 'HITMAN01');
    });
    app.tab('summary');
    it('with identity: and the meeting point the server sent, where the client stood', function () {
      has(app.text(app.drawer()), 'Meeting point');
      has(app.text(app.drawer()), 'x 1234, y -568');
    });
    app.tab('people');
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
    it('lists contracts newest first, with a page count, live only by default (admin review nit)', function () {
      eq(app.last('contracts').data, { page: 1, state: 'live' });
      has(app.text(app.byId('dd-ct-state')), 'Live only');
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
      eq(app.last('contracts').data, { page: 1, query: 'Dan', state: 'live' });
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
    it('Clear asks for every live contract again, the default', function () {
      eq(app.last('contracts').data, { page: 1, state: 'live' });
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
    // One tab drawn at a time: each read in turn.
    const tabText = {};
    ['summary', 'money', 'people', 'notes', 'record'].forEach(function (t) { app.tab(t); tabText[t] = app.text(drawer); });
    it('the drawer opens on Summary and draws only the tab open', function () {
      has(tabText.summary, 'Terms');
      lacks(tabText.summary, 'Escrow lines', 'Money\'s, not drawn on Summary');
      lacks(tabText.summary, 'escrow_deliver_parked', 'nor the timeline');
      has(tabText.money, 'Escrow lines');
      has(tabText.people, 'Operatives');
      has(tabText.record, 'Timeline');
    });
    it('Money shows how many lines wait for staff on its tab', function () {
      const money = drawer.querySelectorAll('[data-act="dr-tab"]').filter(function (b) {
        return b.getAttribute('data-value') === 'money'; })[0];
      has(app.text(money), '3');
    });
    app.tab('money');
    it('the drawer has the terms, payouts, escrow lines, operatives, proposals and the timeline', function () {
      const text = tabText.summary + tabText.money + tabText.people + tabText.record;
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

    it('Void is not on the drawer until More is opened', function () {
      eq(drawer.querySelectorAll('[data-act="void"]').length, 0);
    });
    app.more();
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
    it('admin review F5: an armed Pay amount names the amount', function () {
      has(app.text(payAgain), 'Click again: pay $2,000');
    });
    app.type(app.drawer().querySelector('[data-bind="dr.amount.ct00000001:2"]'), '9000');
    it('admin review F5: and retyping it disarms, sending nothing', function () {
      falsy(app.drawer().querySelector('.is-armed'));
      eq(app.requests('settle').length, 0);
    });
    app.type(app.drawer().querySelector('[data-bind="dr.amount.ct00000001:2"]'), '2,000');
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
      // A refusal is kit.css's default notice: crimson, not .ok.
      truthy(answer.classList.contains('notice') && !answer.classList.contains('ok'));
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
    app.tab('money');
    it('a contract read while recovering says its stuck lines are not listed', function () {
      has(app.text(app.drawer()), 'Not listed while the server is recovering');
    });
    app.tab('summary');
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
    app.nav('inbox:reviews');
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
    app.nav('inbox:reviews');
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
    app.type(first.querySelector('[data-bind="rv.rv00000001.amount"]'), '100');
    const early = app.button('Refund it', app.byId('rv-rv00000001'));
    app.click(early);
    await settled();
    it('admin review F5: the armed Refund names the amount, the recipient and the account', function () {
      has(app.text(early), 'Click again: refund $100 to payer');
      has(app.text(early), 'from bank');
    });
    app.type(app.byId('rv-rv00000001').querySelector('[data-bind="rv.rv00000001.amount"]'), '99999');
    it('admin review F5: retyping the amount after arming disarms it', function () {
      falsy(app.byId('rv-rv00000001').querySelector('.is-armed'));
    });
    app.click(app.button('Refund it', app.byId('rv-rv00000001')));
    await settled();
    pick(app, 'rv-account:rv00000001', 'cash');
    await settled();
    it('admin review F5: and so does picking another account; nothing was sent', function () {
      falsy(app.byId('rv-rv00000001').querySelector('.is-armed'));
      eq(app.requests('resolve').length, 0);
    });
    app.type(app.byId('rv-rv00000001').querySelector('[data-bind="rv.rv00000001.amount"]'), '500');
    const refund = app.button('Refund it', app.byId('rv-rv00000001'));
    app.click(refund);
    await settled();
    it('a refund takes two clicks', function () {
      eq(app.requests('resolve').length, 0);
      has(app.text(refund), 'Click again: refund $500 to payer');
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
    app.click(app.$$('.seg-btn').filter(function (b) {
      return b.getAttribute('data-act') === 'rv-all' && b.getAttribute('data-value') === 'all'; })[0]);
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
    app.nav('inbox:reviews');
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
    app.nav('inbox:reviews');
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
      eq(app.byId('count-logs').textContent, '4');
      eq(app.byId('count-logs').hidden, false);
      has(app.main(), 'Alerts 4');
    });
    app.click(app.button('Alerts 4'));
    await settled();
    it('the overview\'s count opens the inbox on its open alerts, with Logs keeping the rest', function () {
      eq(app.last('alerts').data, { state: 'open' });
      eq(app.$$('article.al').length, 4);
      has(app.main(), 'Acknowledged ones, Discord and the test alert are in Logs, Alerts.');
      lacks(app.main(), 'Send a test alert');
    });
    app.group('logs');
    app.nav('alerts');
    await settled();
    it('Logs, Alerts counts them on its sub-tab', function () {
      eq(app.byId('count-alerts').textContent, '4');
      eq(app.byId('count-alerts').hidden, false);
    });
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
    it('and shows their summary, with a tab for each part of their card', function () {
      const text = app.main();
      has(text, 'Dana Reyes');
      has(text, 'TARGET01');
      has(text, 'in the city · player 12');
      has(text, '80%');
      ['pmeasures', 'pmoney', 'pplaytime', 'phistory', 'pdiag'].forEach(function (view) {
        truthy(app.byId('nav-' + view), 'the ' + view + ' tab');
      });
    });
    app.nav('pmoney');
    await settled();
    it('Money: what they are owed and their notices', function () {
      const text = app.main();
      has(text, 'Dana Reyes', 'who it is, above every tab');
      has(text, 'ct00000005:2');
      has(text, '1 delivery pending');
      has(text, 'Contract closed');
    });
    app.nav('players');
    await settled();
    it('a player has no Contracts tab of their own: the one list is filtered to them', function () {
      eq(app.byId('nav-pcontracts'), null);
    });
    app.click(app.button('Their contracts'));
    await settled();
    it('Their contracts opens Contracts with the person filter set, by the lookup\'s handle', function () {
      eq(app.byId('nav-contracts').getAttribute('aria-current'), 'page');
      eq(app.last('contracts').data, { page: 1, ref: 'p7_424242' });
      has(app.main(), 'Dana Reyes');
      has(app.main(), 'Their part');
      has(app.main(), 'ct00000001');
    });
    app.click(app.button('Whois'));
    await settled();
    it('with identity, whois answers under the contract', function () {
      eq(app.last('whois').data, { id: 'ct00000001' });
      has(app.main(), 'Kai Holt');
    });
    app.click(app.$$('[data-act="dd-open"]').filter(function (b) { return b.getAttribute('data-dd') === 'ct-as'; })[0]);
    app.click(app.$$('[data-act="dd-pick"]').filter(function (b) {
      return b.getAttribute('data-dd') === 'ct-as' && b.getAttribute('data-value') === 'hitman'; })[0]);
    await settled();
    it('and narrowed to one part they played', function () {
      eq(app.last('contracts').data, { page: 1, ref: 'p7_424242', as: 'hitman' });
    });
    app.click(app.$('[data-act="ct-person-clear"]'));
    await settled();
    it('clearing the person shows everybody\'s again', function () {
      eq(app.last('contracts').data, { page: 1 }, 'every state, as their list was');
      lacks(app.main(), 'Their part');
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
    });
    app.nav('pmoney');
    await settled();
    it('and what may be shown still is', function () {
      has(app.main(), '1 delivery pending');
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
    app.nav('pplaytime');
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
    // What is typed in the header search now names nobody: the card's
    // writes go by the lookup's handle.
    app.type(app.byId('gs-q'), 'SOMEONE2');
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
    app.nav('pplaytime');
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
    app.nav('pplaytime');
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
    app.nav('rules:switch');
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

    app.nav('rules:limit');
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

    app.nav('rules:money');
    await settled();
    it('Game rules\' money settings, every area, each setting under its group', function () {
      has(app.text(app.$('.st-group[data-group="stakes"]')), 'Largest stake, as a share');
      eq(app.$('.gr-old'), null);
    });
    app.type(app.byId('st-row-Penalty.MaxFractionOfEscrow').querySelector('input'), '0.75');
    app.click(app.button('Save', app.byId('st-row-Penalty.MaxFractionOfEscrow')));
    app.click(app.button('Save', app.byId('st-row-Penalty.MaxFractionOfEscrow')));
    await settled();
    it('a fraction goes where the key takes one', function () {
      eq(app.last('setSetting').data, { key: 'Penalty.MaxFractionOfEscrow', value: 0.75 });
    });

    // A job list: names added and removed, saved on the second click.
    app.nav('rules');
    await settled();
    app.type_('');
    app.area('police');
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
    app.nav('rules:timer');
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
    app.nav('rules:limit');
    await settled();
    app.type(app.byId('st-q'), 'hitman may hold');
    it('the search finds a label, and draws only what matches', function () {
      truthy(app.byId('st-row-Limits.MaxAcceptedPerHitman'));
      falsy(app.byId('st-row-Completion.Fulfilment'));
    });
    app.type_('');
    app.type(app.byId('st-q'), 'completion.fulf');
    it('a key', function () {
      truthy(app.byId('st-row-Completion.Fulfilment'));
      falsy(app.byId('st-row-Limits.MaxAcceptedPerHitman'));
    });
    app.type(app.byId('st-q'), 'contract limits');
    it('a group', function () {
      truthy(app.byId('st-row-Limits.MaxAcceptedPerHitman'));
      falsy(app.byId('st-row-Completion.Fulfilment'));
    });
    app.nav('rules:switch');
    await settled();
    it('and keeps what was typed from view to view', function () {
      eq(app.byId('st-q').value, 'contract limits');
      has(app.main(), 'No setting matches; clear the filter.', 'saying nothing matches');
    });
    app.type(app.byId('st-q'), 'cash may be put');
    it('and a description', function () {
      truthy(app.byId('st-row-Sources.cash.enabled'));
      falsy(app.byId('st-row-Bailout.Enabled'));
    });
    app.nav('changed');
    await settled();
    it('Changed from the panel lists every setting changed, wherever it lives', function () {
      truthy(app.byId('st-row-Bailout.Enabled') || app.byId('st-row-Advisory.RecipientJobNames'), 'a changed row');
      falsy(app.byId('st-row-Sources.cash.enabled'), 'and none that is not');
    });
    const all = app.button('Undo all panel changes');
    app.click(all);
    await settled();
    it('reset all takes two clicks', function () { eq(app.requests('resetSettings').length, 0); });
    app.click(all);
    await settled();
    it('and says how many were put back', function () {
      eq(app.requests('resetSettings').length, 1);
      has(app.toasts(), 'Every setting is back to what config.lua says (2 were changed).');
    });
    app.nav('devsettings');
    await settled();
    app.type(app.byId('st-q'), '');
    await settled();
    it('Developer holds the read-only values: one shows why, and no control', function () {
      const row = app.byId('st-row-Admin.Enabled');
      has(app.text(row), 'would lock you out');
      eq(row.querySelectorAll('button').filter(function (b) {
        return b.getAttribute('data-act') !== 'st-details'; }).length, 0, 'no control but its Details');
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

  /* ---- the sections: sidebar groups, sub-tabs, breadcrumbs, old names ---- */
  await (async function () {
    const app = boot(standardServer({ orgGet: orgOff() }));
    app.open(ADMIN);
    await settled();
    const crumb = function () { const here = app.$('.crumb.is-here'); return here ? here.textContent : ''; };
    it('the sidebar holds the sections in their groups: Daily, Setup, Records, Developer', function () {
      eq(app.$$('.nav-btn').map(function (b) { return b.getAttribute('data-group'); }),
        ['home', 'players', 'contracts', 'targets', 'rules', 'org', 'bossperms', 'locations', 'logs', 'developer']);
      eq(app.$$('.nav-head').map(function (n) { return n.textContent; }), ['Daily', 'Setup', 'Records', 'Developer']);
      truthy(app.byId('help-btn'), 'Help is the header\'s');
      eq(app.byId('help-btn').getAttribute('data-act'), 'help-btn');
    });
    app.group('rules');
    await settled();
    it('a section opens on its first sub-tab, showing only its own', function () {
      eq(app.byId('nav-rules').getAttribute('aria-current'), 'page');
      truthy(app.byId('nav-changed'), 'its other sub-tabs');
      eq(app.byId('nav-overview'), null, 'and none of another section');
    });
    it('the breadcrumb says where you are', function () {
      has(app.text(app.byId('crumbs')), 'Game rules');
      eq(crumb(), 'Areas');
    });
    const views = { inbox: 'Inbox', overview: 'Dashboard', announce: 'Announce', players: 'Find & summary',
      measures: 'All measures', contracts: 'Contracts',
      tldefaults: 'Defaults', tljobs: 'Per job', tlplayer: 'Per player',
      rules: 'Areas', presets: 'Presets', changed: 'Changed from the panel', 'logs:settings': 'Setting changes', orgsetup: 'Setup',
      orgroles: 'Roles & pay', orgmembers: 'Members', orgapps: 'Applications', orgfunds: 'Funds & cuts',
      orgaccess: 'Contract access', orgnotices: 'Notices', orgwork: 'Work & channel', orgarmory: 'Armory',
      orgrecord: 'Record & discipline', orgturf: 'Reputation, drops & garage', 'logs:org': 'Org audit', bpmatrix: 'Matrix',
      bplimits: 'Limits', bpoffice: 'Delegation & office', 'logs:grants': 'Grant history', locations: 'Map points',
      'logs:targets': 'Audit log', logs: 'Audit log', alerts: 'Alerts', health: 'Health', devsettings: 'Engine settings', console: 'Console',
      tools: 'Test tools', help: 'How it works', howto: 'How do I…', permissions: 'Who can do what' };
    const reached = [], drew = [], helped = [];
    for (const view of Object.keys(views)) {
      app.nav(view);
      await settled();
      if (crumb() === views[view]) reached.push(view);
      if (app.main().length > 20) drew.push(view);
      // One line of help under its title: one sentence, short enough for one line.
      const help = app.$$('.view-help');
      if (help.length === 1 && help[0].textContent.length >= 20 && help[0].textContent.length <= 110
          && (help[0].textContent.match(/[.!?](\s|$)/g) || []).length === 1) helped.push(view);
    }
    it('every view is reachable, says so on its breadcrumb, and draws something', function () {
      eq(reached, Object.keys(views));
      eq(drew, Object.keys(views));
      clean(app, 'every view');
    });
    it('every view has one line of help under its title (step 4b)', function () {
      eq(helped, Object.keys(views));
      const help = app.window.CH_ADMIN_VIEW_HELP;
      ['pmeasures', 'pmoney', 'pplaytime', 'phistory', 'pdiag'].forEach(function (v) {
        truthy(help[v] && help[v].length <= 110, 'a player\'s ' + v + ' tab');
      });
    });
    // A view has one name: an old one (rule 4: no old-name mappings) is
    // not a view, and lands on Home's inbox like any other unknown name.
    const OLD = ['settings', 'features', 'timers', 'money', 'limits', 'targeting', 'reviews', 'stuck',
      'actions', 'diagnostics', 'live', 'frozenlist'];
    const landed = {};
    for (const old of OLD) {
      app.window.CH_ADMIN_SHOW(old);
      await settled();
      landed[old] = crumb();
    }
    it('no old view name is kept: each is unknown and lands on the inbox', function () {
      const want = {};
      OLD.forEach(function (o) { want[o] = 'Inbox'; });
      eq(landed, want);
      eq(app.window.CH_ADMIN_ALIASES, undefined);
    });
    app.window.CH_ADMIN_SHOW('inbox:stuck');
    await settled();
    it('a link to the inbox with a filter chooses that filter there', function () {
      eq(app.$$('[data-act="ib-filter"]').filter(function (b) { return b.getAttribute('aria-pressed') === 'true'; })[0]
        .getAttribute('data-value'), 'stuck');
      truthy(app.byId('sk-list'), 'Money waiting drawn');
      falsy(app.byId('rv-list'), 'and Needs review not');
    });
    app.nav('changed');
    await settled();
    app.group('home');
    await settled();
    app.group('rules');
    await settled();
    it('a section opens on the sub-tab last open in it', function () {
      eq(app.byId('nav-changed').getAttribute('aria-current'), 'page');
    });
    app.group('contracts');
    await settled();
    it('a section of one view has no strip of sub-tabs', function () { eq(app.byId('subnav').hidden, true); });
    app.group('players');
    await settled();
    it('Players shows a selected player\'s tabs only once somebody is looked up', function () {
      eq(app.byId('nav-pmeasures'), null);
      truthy(app.byId('nav-measures'));
    });
    app.window.CH_ADMIN_SHOW('pmeasures');
    await settled();
    it('and a player\'s tab asked for with nobody selected is Find', function () {
      eq(crumb(), 'Find & summary');
    });
    clean(app, 'the sections');
  })();

  await (async function () {
    const app = boot(standardServer(), { fresh: true });
    app.open(ADMIN);
    await settled();
    it('a first open, with nothing remembered, is Home\'s Inbox, which reads the overview first', function () {
      eq(app.byId('nav-inbox').getAttribute('aria-current'), 'page');
      eq(app.sent[0].op, 'overview');
      truthy(app.requests('reviews').length && app.requests('stuck').length && app.requests('alerts').length,
        'and the three lists it shows');
      has(app.main(), 'Needs review');
      has(app.main(), 'Money waiting for staff');
      has(app.main(), 'Open alerts');
    });
    it('the inbox counts each list on its filter chip', function () {
      eq(app.byId('count-reviews').textContent, '3');
      eq(app.byId('count-stuck').textContent, '1', 'left for staff, not every line listed');
      eq(app.byId('count-ialerts').textContent, '4');
    });
    app.click(app.$$('[data-act="ib-filter"]').filter(function (b) { return b.getAttribute('data-value') === 'reviews'; })[0]);
    await settled();
    it('a filter chip shows its list alone', function () {
      truthy(app.byId('rv-list'));
      falsy(app.byId('sk-list'));
      falsy(app.byId('al-list'));
    });
    clean(app, 'inbox');
  })();

  await (async function () {
    const kept = {};
    const storage = { getItem: function (k) { return k in kept ? kept[k] : null; },
                      setItem: function (k, v) { kept[k] = String(v); } };
    const first = boot(standardServer(), { storage: storage });
    first.open(ADMIN);
    await settled();
    first.nav('changed');
    await settled();
    const again = boot(standardServer(), { storage: storage });
    again.open(ADMIN);
    await settled();
    it('the last section and sub-tab are remembered in this browser', function () {
      eq(again.byId('nav-changed').getAttribute('aria-current'), 'page');
      eq(again.byId('grp-rules').getAttribute('aria-current'), 'page');
    });
    kept['crimson-hitman.admin.nav'] = JSON.stringify({ view: 'targeting', sub: { rules: 'limits', live: 'stuck' } });
    const old = boot(standardServer(), { storage: storage });
    old.open(ADMIN);
    await settled();
    it('a view remembered under an old name is not kept: the panel opens on Home', function () {
      eq(old.byId('nav-inbox').getAttribute('aria-current'), 'page');
      clean(old, 'an old remembered view');
    });
    const broken = boot(standardServer(), { storage: { getItem: function () { throw new Error('denied'); },
      setItem: function () { throw new Error('denied'); } } });
    broken.open(ADMIN);
    await settled();
    it('and storage that throws is no storage, never a fault', function () {
      eq(broken.byId('nav-inbox').getAttribute('aria-current'), 'page');
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
    app.nav('rules:switch');
    await settled();
    it('but no setting of any other section', function () {
      app.$$('.switch').forEach(function (b) { eq(b.disabled, true, 'switch ' + b.getAttribute('data-key')); });
    });
    clean(app, 'developer ACE alone');
  })();

  /* ---- Developer, and Help > Who can do what ---- */
  await (async function () {
    const server = standardServer();
    const app = boot(server);
    app.open(access({ canWrite: false, canIdentify: false, canDevelop: false,
      permissions: PERMISSIONS.map(function (p) { return Object.assign({}, p, { held: p.ace === 'crimson.admin' }); }) }));
    await settled();
    it('without the developer ACE there is no Developer section', function () {
      eq(app.byId('grp-developer').hidden, true);
      eq(app.byId('nh-developer').hidden, true, 'nor its heading');
    });
    app.click(app.byId('help-btn'));
    await settled();
    it('Help opens How it works, How do I and Who can do what', function () {
      eq(app.byId('nav-help').getAttribute('aria-current'), 'page');
      truthy(app.byId('nav-howto'));
      truthy(app.byId('nav-permissions'));
    });
    app.nav('console');
    await settled();
    it('and a developer view asked for anyway is Who can do what, with nothing asked of the server', function () {
      eq(app.byId('nav-permissions').getAttribute('aria-current'), 'page');
      eq(app.requests('console').length, 0);
    });
    it('Who can do what lists each ACE, whether it is held, and how to grant one that is not', function () {
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
    const settingsLua = fs.readFileSync(path.join(__dirname, '..', '..', 'crimson-hitman', 'server', 'settings.lua'), 'utf8')
      + fs.readFileSync(path.join(__dirname, '..', '..', 'crimson-hitman', 'server', 'org', 'settings_catalogue.lua'), 'utf8');
    // A link names a setting, never a view: the panel finds the section
    // its setting is in (server/settings.lua's category).
    const VIEW = { 'rules-timers': 1, 'rules-rewards': 1, 'rules-limits': 1, 'rules-targeting': 1, features: 1,
      developer: 1, 'target-limits': 1, organisation: 1 };
    const wrong = [];
    help.forEach(function (c) {
      c.links.forEach(function (l) {
        const at = settingsLua.indexOf("key = '" + l.key + "'");
        const cat = at === -1 ? null : /category = '([\w-]+)'/.exec(settingsLua.slice(at, at + 400));
        if (!cat || !VIEW[cat[1]] || l.view !== undefined) wrong.push(l.key + ' -> ' + l.view + ' (' + (cat && cat[1]) + ')');
      });
    });
    it('every link names the section its setting is in', function () { eq(wrong, []); });
    it('How it works is an accordion: a card\'s words are drawn only once it is opened', function () {
      eq(app.$$('button[data-act="help-jump"]').length, 0);
      eq(app.$$('.help-card.is-open').length, 0);
    });
    app.click(app.$$('[data-act="help-toggle"]').filter(function (b) {
      return b.getAttribute('data-value') === 'Police advisories'; })[0]);
    it('and opening one draws it', function () {
      eq(app.$$('.help-card.is-open').length, 1);
      has(app.main(), 'officers are told by an advisory');
    });
    const link = app.$$('button[data-act="help-jump"]').filter(function (b) {
      return b.getAttribute('data-key') === 'Advisory.RecipientJobNames';
    })[0];
    app.click(link);
    await settled();
    it('and a link lands on that setting in Game rules, in its area, marked and opened', function () {
      eq(app.byId('nav-rules').getAttribute('aria-current'), 'page');
      truthy(app.byId('st-row-Advisory.RecipientJobNames').classList.contains('is-focus'));
      falsy(app.byId('st-row-Advisory.RecipientJobNames').querySelector('.st-details').hidden, 'its Details open');
      has(app.text(app.byId('crumbs')), 'Police & city news');
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
    app.nav('rules:timer');
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
    app.click(app.button('Money waiting 1'));
    await settled();
    it('the overview opens the inbox on Money waiting, where every waiting line is listed', function () {
      eq(app.last('stuck').op, 'stuck');
      eq(app.byId('nav-inbox').getAttribute('aria-current'), 'page');
      eq(app.$$('[data-act="ib-filter"]').filter(function (b) { return b.getAttribute('aria-pressed') === 'true'; })[0]
        .getAttribute('data-value'), 'stuck');
      has(app.main(), 'ct00000001:2');
      has(app.main(), 'owe00000003');
      has(app.main(), 'ct00000009:1');
      has(app.main(), 'ending unfinished; it settles itself within a minute');
      has(app.main(), '5 left for you to settle, of 6 listed');
      has(app.main(), 'Arrival unknown');
      has(app.main(), 'Never given: only Pay settles it');
      lacks(app.main(), 'money events no rule could settle wait in the review queue',
        'the queue is the inbox\'s own filter now, not a second card here');
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
    app.nav('inbox:stuck');
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
    app.nav('inbox:stuck');
    await settled();
    it('lists nothing while the server recovers, and says so', function () {
      has(app.main(), 'Not listed while the server is recovering from the restart.');
      eq(app.byId('banner').hidden, false);
    });
    clean(app, 'stuck, recovering');
  })();

  await (async function () {
    const app = boot(standardServer());
    app.open(READER);
    await settled();
    app.nav('inbox:stuck');
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
        for (const section of ['contracts', 'stuck', 'reviews', 'alerts', 'console', 'logs', 'players', 'measures',
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
        app.nav('inbox:reviews');
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
        app.nav('rules:switch');
        await settled();
        const sw = app.$$('.switch').filter(function (b) { return !b.disabled; })[0];
        if (sw) { app.click(sw); await settled(); sweep(app, 'a setting changed'); }
        // The tools, each run.
        app.nav('tools');
        await settled();
        const refresh = app.button('Bring timers forward');
        if (!refresh.disabled) { app.click(refresh); sweep(app, 'refresh armed'); app.click(refresh); await settled(); }
        if (!app.button('Flush the audit log').disabled) { app.click(app.button('Flush the audit log')); await settled(); }
        app.nav('health');
        await settled();
        app.click(app.button('Run the diagnosis'));
        await settled();
        sweep(app, 'the tools, run');
        // The new sections too: the organisation, Boss permissions and Locations.
        for (const view of ['orgsetup', 'orgroles', 'orgmembers', 'orgfunds', 'orgaccess', 'orgnotices', 'orgwork',
          'orgarmory', 'orgrecord', 'orgturf', 'logs:org',
          'bpmatrix', 'bplimits', 'bpoffice', 'logs:grants', 'locations', 'measures', 'howto']) {
          app.nav(view);
          await settled();
          sweep(app, view);
        }
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
    planted.nav('health');
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
    app.nav('rules:switch');
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
    none.nav('rules:switch');
    await settled();
    const photosOn = boot(standardServer({ settings: on }));
    photosOn.open(ADMIN);
    await settled();
    photosOn.nav('rules:switch');
    await settled();
    const reader = boot(standardServer({ settings: settingsView({ keptPhotos: kept }) }));
    reader.open(READER);
    await settled();
    reader.nav('rules:switch');
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
    it('Test tools holds the timer refresh and the flush, and points to the diagnosis', function () {
      has(app.main(), 'The diagnosis is under Health');
    });
    app.nav('health');
    await settled();
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
    app.click(app.button('Check the config'));
    await settled();
    it('Health: Check the config asks for the config check and draws it where the diagnosis is', function () {
      eq(app.last('diag').data, { config: true });
    });
    app.nav('tools');
    await settled();
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
    app.nav('inbox:stuck');
    await settled();
    it('and so does Stuck escrow', function () {
      has(app.main(), 'Not listed: recovery failed at the last start; restart the resource');
    });
    app.nav('contracts');
    await settled();
    app.click(app.$$('[data-act="contract"]')[0]);
    await settled();
    app.tab('money');
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
      has(app.main(), 'Money waiting could not be read just now');
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
    app.nav('inbox:stuck');
    await settled();
    app.click(app.$$('button.link').filter(function (b) {
      return b.getAttribute('data-act') === 'contract' && b.getAttribute('data-id') === 'ct00000001';
    })[0]);
    await settled();
    app.tab('money');
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
    app.click(app.button('Run the diagnosis'));
    await settled();
    it('Run the diagnosis runs it, under Developer, Health for staff who have it', function () {
      eq(app.byId('nav-health').getAttribute('aria-current'), 'page');
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
    app.nav('rules:switch');
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
    app.more();
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
    app.nav('rules');
    await settled();
    app.type_('');
    app.area('other');
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
    app.nav('inbox:stuck');
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
      // A refusal is kit.css's default notice: crimson, not .ok.
      truthy(answer.classList.contains('notice') && !answer.classList.contains('ok'));
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
    app.nav('howto');
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
      measures: function () {
        return { ok: true, data: { rows: frozen ? [{ kind: 'freeze', ref: 'f1', name: 'Dana Reyes', online: true,
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
      overview: overview({ measures: { freeze: 2, suspend: 0, protect: 0, limit: 0 } }),
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    it('counts frozen players on the overview', function () {
      has(app.main(), 'Measures on players');
      has(app.text(app.byId('ov-frozen')), '2');
    });
    app.nav('contracts');
    await settled();
    it('badges a frozen contract in the list, and only that one', function () {
      eq(app.$$('.is-frozen').length, 1);
    });
    app.nav('measures');
    await settled();
    it('asks for the one measures list when Players, All measures opens', function () {
      truthy(app.requests('measures').length >= 1, 'asked');
      has(app.main(), 'No measure is in force on anybody.');
    });
    app.click(app.$$('[data-act="ms-kind"]').filter(function (b) { return b.getAttribute('data-value') === 'freeze'; })[0]);
    await settled();
    it('and filters it by kind, saying so for each', function () {
      has(app.main(), 'Nobody is frozen.');
      eq(app.requests('measures').length, 1, 'filtered here, not asked again');
    });
    app.nav('players');
    await settled();
    it('and not on Find, which has no list under it any more', function () {
      eq(app.requests('measures').length, 1);
    });
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    app.nav('pmeasures');
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
      truthy(app.requests('measures').length >= 2, 'the measures list read again');
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
    const app = boot(standardServer({ measures: { ok: true, data: { rows: [] } } }));
    app.open(READER);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    app.nav('pmeasures');
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
    const toolText = [];
    ['people', 'notes', 'record'].forEach(function (t) {
      app.tab(t);
      markupFrom(app, 'the staff tools (' + t + ')', found);
      toolText.push(app.text(app.drawer()));
    });
    app.tab('notes');
    it('the contract view has the five staff tools, the notes and history escaped', function () {
      const text = toolText.join(' ');
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
    app.tab('people');
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
    app.tab('notes');
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
    app.tab('record');
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
    app.tab('people');
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
      app.tab('notes');
      ['Add note', 'Replace'].forEach(function (label) {
        truthy(app.button(label, app.drawer()).disabled, label + ' disabled');
      });
      app.click(app.button('Add note', app.drawer()));
      app.tab('people');
      truthy(app.button('Remove', app.drawer()).disabled, 'Remove disabled');
      falsy(app.button('Placer', app.drawer()).disabled, 'looking is not a write');
      app.click(app.button('Remove', app.drawer()));
      app.tab('record');
      falsy(app.button('Copy the record', app.drawer()).disabled, 'exporting is not a write');
      eq(app.requests('addNote').length + app.requests('removeHitman').length, 0);
    });
    app.tab('people');
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
      const none = function () {
        return app.drawer().querySelectorAll('button').filter(function (b) {
          const act = b.getAttribute('data-act') || '';
          return act === 'ct-remove' || act === 'ct-text';
        }).length;
      };
      app.tab('people');
      has(app.text(app.drawer()), 'Only a live contract (active or accepted) has operatives to remove.');
      eq(none(), 0);
      app.tab('notes');
      has(app.text(app.drawer()), 'This server keeps no reason on a contract.');
      eq(none(), 0);
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
      measures: { ok: true, data: { rows: [] } },
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
    it('a lookup asks for no history until its tab opens', function () {
      eq(app.requests('history').length, 0);
    });
    app.nav('pmeasures');
    await settled();
    it('Measures draws Freeze, Suspend and Protect, and a way to their target limits', function () {
      has(app.main(), 'Suspend from contracts');
      has(app.main(), 'Protect from contracts');
      has(app.main(), 'Their live contracts are not touched: freeze them for that.');
      has(app.main(), 'Contracts already on them are not touched: freeze them for that.');
      truthy(app.button('Open them in Target limits'));
    });
    app.nav('pmoney');
    await settled();
    it('Money draws Pay', function () { has(app.main(), 'Pay'); });
    app.nav('phistory');
    await settled();
    it('History asks for it as its tab opens, by the lookup\'s handle', function () {
      eq(app.last('history').data, { ref: 'p7_424242' });
      has(app.main(), 'History');
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

    app.nav('pmeasures');
    await settled();
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

    app.nav('pmoney');
    await settled();
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
    app.nav('pmeasures');
    await settled();
    it('a moderator may freeze, suspend and protect', function () {
      falsy(app.button('Freeze').disabled, 'Freeze');
      falsy(app.button('Suspend').disabled, 'Suspend');
      falsy(app.button('Protect').disabled, 'Protect');
    });
    app.nav('pmoney');
    await settled();
    it('and not pay', function () {
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
    app.more();
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
    const disabledFor = {};
    for (const [view, labels] of [['pmeasures', ['Suspend', 'Protect']], ['pmoney', ['Pay']]]) {
      app.nav(view);
      await settled();
      labels.forEach(function (label) {
        const button = app.button(label);
        disabledFor[label] = button.disabled;
        app.click(button);
        app.click(button);
      });
    }
    app.nav('phistory');
    await settled();
    it('a reader sees Suspend, Protect and Pay disabled, and they send nothing', function () {
      eq(disabledFor, { Suspend: true, Protect: true, Pay: true });
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
    app.nav('phistory');
    await settled();
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
    app.nav('howto');
    await settled();
    it('How do I has a card pointing to Announce', function () {
      has(app.main(), 'Announce');
      truthy(app.button('Go: Home, Announce'));
    });
    app.group('home');
    await settled();
    it('and Home has its sub-tab', function () {
      truthy(app.byId('nav-announce'));
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
      'logs.settings': { ok: true, data: { rows: historyRows(true), next: 77 } },
      undoSetting: function () {
        return { ok: true, message: 'Undone: Relay.Enabled is on again (it was off).', data: { key: 'Relay.Enabled' } };
      }
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.group('rules');
    await settled();
    app.click(app.byId('nav-logs-settings'));
    await settled();
    it('Records › Logs, Setting changes lists each change: when, the setting, before, after and who', function () {
      eq(app.byId('nav-logs').getAttribute('aria-current'), 'page');
      eq(app.$$('[data-act="lg-area"]').filter(function (b) { return b.getAttribute('aria-pressed') === 'true'; })[0]
        .getAttribute('data-value'), 'settings', 'Game rules\' link opens Logs with its chip picked');
      eq(app.requests('logs.settings').length, 1);
      eq(app.requests('logs').length, 0, 'and not the audit log');
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
      eq(app.requests('logs.settings').length, 2, 'the history is read again');
    });
    app.click(app.button('Older'));
    await settled();
    it('Older reads the next page from the cursor, and Newer goes back', function () {
      eq(app.last('logs.settings').data, { area: 'settings', cursor: 77 });
      app.click(app.button('Newer'));
    });
    await settled();
    it('back at the first page', function () { eq(app.last('logs.settings').data, { area: 'settings' }); });
    clean(app, 'settings history');
  })();

  await (async function () {
    const server = standardServer({
      'logs.settings': { ok: true, data: { rows: historyRows(false), hidden: 2 } }
    });
    const app = boot(server);
    app.open(access({ canWrite: false, canIdentify: false, canDevelop: false }));
    await settled();
    app.group('rules');
    await settled();
    it('staff without the Developer section have the settings history under Game rules', function () {
      eq(app.byId('grp-developer').hidden, true);
      truthy(app.byId('nav-logs-settings'), 'Change history');
    });
    app.nav('logs:settings');
    await settled();
    it('a reader reads the history, with no Undo, told what is left out', function () {
      eq(app.byId('nav-logs').getAttribute('aria-current'), 'page');
      eq(app.$$('tr[data-key]').length, 4);
      eq(app.byId('main').querySelectorAll('button[data-act="hs-undo"]').length, 0);
      has(app.main(), '2 change(s) to the Developer section');
    });
    clean(app, 'settings history reader');
  })();

  /* ---- step 3i: Records › Logs, one view for every log ---- */
  await (async function () {
    const server = standardServer({
      'logs.settings': { ok: true, data: { rows: historyRows(true) } }
    });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('logs');
    await settled();
    const chips = function () {
      return app.$$('[data-act="lg-area"]').map(function (b) { return b.getAttribute('data-value'); });
    };
    const picked = function () {
      return app.$$('[data-act="lg-area"]').filter(function (b) { return b.getAttribute('aria-pressed') === 'true'; })[0]
        .getAttribute('data-value');
    };
    it('Logs has one chip per log, the audit log first and picked', function () {
      eq(chips(), ['audit', 'settings', 'org', 'grants']);
      eq(picked(), 'audit');
      eq(app.requests('logs').length, 1, 'the audit log read');
      truthy(app.byId('lg-results'), 'its search and rows');
    });
    app.click(app.$$('[data-act="lg-area"]').filter(function (b) { return b.getAttribute('data-value') === 'settings'; })[0]);
    await settled();
    it('a chip reads that log, through the same op, and says so on the breadcrumb', function () {
      eq(picked(), 'settings');
      eq(app.requests('logs.settings').length, 1);
      eq(app.$$('tr[data-key]').length, 4);
      eq(app.byId('lg-results'), null, 'and not the audit log\'s rows');
      has(app.text(app.byId('crumbs')), 'Setting changes');
    });
    app.group('targets');
    await settled();
    it('Target limits links to its history', function () { truthy(app.byId('nav-logs-targets')); });
    app.click(app.byId('nav-logs-targets'));
    await settled();
    it('which is the audit log filtered to the target-limit rows', function () {
      eq(picked(), 'audit');
      eq(app.last('logs').data.action, 'staff_target_');
    });
    app.group('home');
    await settled();
    app.nav('logs');
    await settled();
    it('the chip last picked stays picked', function () { eq(picked(), 'audit'); });
    clean(app, 'one log view');
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
    app.nav('inbox:reviews');
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
    app.nav('rules:switch');
    await settled();
    it('lists a roleplay switch under Features, in its Roleplay group, with what the group is', function () {
      has(app.text(app.byId('st-row-Roleplay.WitnessHeat.Enabled')), 'Witness heat');
      has(app.text(app.$('#panel')), 'naming nobody');
    });
    app.nav('rules:list');
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
    app.click(app.button('Open all'));
    it('How it works has a card for each roleplay feature, linking to its settings', function () {
      const text = app.text(app.$('#panel'));
      ['Witness heat', 'EMS before re-listing', 'City news', 'Dirty money payouts'].forEach(function (t) {
        has(text, t);
      });
      truthy(app.$$('button[data-act="help-jump"]').some(function (b) {
        return b.getAttribute('data-key') === 'Roleplay.DirtyPayouts.Item';
      }), 'a link to the item');
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
    app.click(app.button('Open all'));
    const help = app.window.CH_ADMIN_HELP;
    it('How it works has a card for each rpC roleplay feature, linking to its settings', function () {
      // Reputation is part of a character's record (server/record/): its
      // card is titled Record.
      ['proof of intent', 'record: reputation', 'bodyguards', 'hit on the hitman'].forEach(function (w) {
        const found = help.filter(function (c) {
          return c.title.toLowerCase().indexOf(w.indexOf('record: ') === 0 ? w : 'roleplay: ' + w) === 0;
        });
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
    it('a roleplay help link lands on its setting in Game rules', function () {
      eq(app.byId('nav-rules').getAttribute('aria-current'), 'page');
      truthy(app.byId('st-row-Roleplay.ProofOfIntent.HoldMaxMinutes').classList.contains('is-focus'));
    });
    app.nav('rules:switch');
    await settled();
    it('the bodyguard switch is under Features, in its Roleplay group', function () {
      has(app.main(), 'Roleplay: Bodyguards');
      truthy(app.byId('st-row-Roleplay.Protection.Enabled'), 'its row');
    });
    clean(app, 'roleplay rpC');
  })();

  /* ---- the roleplay features (Config.Roleplay) ---- */
  await (async function () {
    const places = { key: 'Intel.Rumours.Locations', place: 'point', category: 'rules-limits',
      group: 'Intel: Rumours and broker',
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
    app.nav('locations');
    await settled();
    it('a place list is edited in Locations, not Game rules', function () {
      truthy(app.byId('st-row-Intel.Rumours.Locations'));
      truthy(app.button('Use my position for a new line'), 'with Use my position');
    });
    const row = function () { return app.byId('st-row-Intel.Rumours.Locations'); };
    app.type(row().querySelector('input'), '1240.6, -3179.2, 7.1, 270.0');
    app.click(app.button('Add', row()));
    await settled();
    app.click(app.byId('st-save-Intel.Rumours.Locations'));
    app.click(app.byId('st-save-Intel.Rumours.Locations'));
    await settled();
    it('a place is added whole, commas and spaces kept', function () {
      eq(app.last('setSetting').data, { key: 'Intel.Rumours.Locations',
        value: ['-1171.0, -1572.5, 4.66, 125.0', '1240.6, -3179.2, 7.1, 270.0'] });
    });
    app.nav('inbox:reviews');
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
    app.click(app.button('Open all'));
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
    const zones = { key: 'Intel.SafeZones.Zones', place: 'zone', category: 'rules-targeting',
      group: 'Intel: Tip safe zones', label: 'Safe zones (x, y, radius, name)', kind: 'list',
      whole: true, live: true, inflight: 'Read each time it is used.', value: [], default: [],
      source: 'config' };
    const server = standardServer({ settings: settingsView({ limits: [zones] }) });
    const app = boot(server);
    app.open(ADMIN);
    await settled();
    app.nav('locations');
    await settled();
    const row = function () { return app.byId('st-row-Intel.SafeZones.Zones'); };
    app.type(row().querySelector('input'), '300, -590, 80, Pillbox Hill');
    app.click(app.button('Add', row()));
    await settled();
    app.click(app.byId('st-save-Intel.SafeZones.Zones'));
    app.click(app.byId('st-save-Intel.SafeZones.Zones'));
    await settled();
    it('a safe zone is added whole, commas and spaces kept', function () {
      eq(app.last('setSetting').data, { key: 'Intel.SafeZones.Zones',
        value: ['300, -590, 80, Pillbox Hill'] });
    });
    app.nav('help');
    await settled();
    app.click(app.button('Open all'));
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
    const tiers = { key: 'Record.Tiers.Tiers', category: 'rules-limits', group: 'Record: Tiered board',
      label: 'Tiers, as name, least reward, level', kind: 'list', whole: true, live: true,
      inflight: 'Read each time it is used.', value: ['Professional, 50000, 2'], default: [], source: 'config' };
    view.data.limits.push(tiers);
    const app = boot(standardServer({ settings: view }));
    app.open(ADMIN);
    await settled();
    app.nav('rules:switch');
    await settled();
    it('the contract decay switch is under Features, in its Improvements group', function () {
      has(app.main(), 'Improvements: Contract decay');
      truthy(app.byId('st-row-Improvements.ContractDecay.Enabled'), 'its row');
    });
    app.nav('rules:list');
    await settled();
    const row = function () { return app.byId('st-row-Record.Tiers.Tiers'); };
    app.type(row().querySelector('input'), 'Elite, 150000, 4');
    app.click(app.button('Add', row()));
    await settled();
    app.click(app.byId('st-save-Record.Tiers.Tiers'));
    app.click(app.byId('st-save-Record.Tiers.Tiers'));
    await settled();
    it('a tier is added whole, its commas and spaces kept', function () {
      eq(app.last('setSetting').data, { key: 'Record.Tiers.Tiers',
        value: ['Professional, 50000, 2', 'Elite, 150000, 4'] });
    });
    app.nav('help');
    await settled();
    app.click(app.button('Open all'));
    const help = app.window.CH_ADMIN_HELP;
    it('How it works has a card for each board improvement, linking to its settings', function () {
      // The first three are part of a character's record (server/record/).
      ['record: placer record', 'record: hitman heat', 'record: tiered board', 'improvements: contract decay'].forEach(function (w) {
        const found = help.filter(function (c) { return c.title.toLowerCase() === w; });
        eq(found.length, 1, 'a card on ' + w);
        truthy(found[0].links.length >= 2, w + ' links to its settings');
        truthy(/off as shipped/i.test(found[0].text), w + ' says it ships off');
        found[0].links.forEach(function (l) {
          // A link names its setting only: no view, old or new.
          eq(l.view, undefined, l.key + ' view');
        });
      });
    });
    const link = app.$$('button[data-act="help-jump"]').filter(function (b) {
      return b.getAttribute('data-key') === 'Improvements.ContractDecay.Enabled';
    })[0];
    truthy(link, 'the decay switch link');
    app.click(link);
    await settled();
    it('an improvement help link lands on its switch in Game rules', function () {
      eq(app.byId('nav-rules').getAttribute('aria-current'), 'page');
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
    app.click(app.button('Open all'));
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
    app.nav('rules:switch');
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
    app.nav('rules:switch');
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
    app.nav('health');
    await settled();
    it('S13: Health\'s settings link says what it opens, not a bare 0', function () {
      const link = app.$$('button').filter(function (b) {
        return b.getAttribute('data-section') === 'changed' && b.className.indexOf('link') !== -1;
      })[0];
      truthy(link, 'the link');
      eq(link.textContent.trim(), 'None changed — open Game rules');
    });
    app.nav('contracts');
    await settled();
    app.click(app.$$('[data-act="contract"]')[0]);
    await settled();
    const drawerText = app.text(app.drawer());
    it('S13: says the mode with a capital, as every other term', function () {
      has(drawerText, 'ModeExclusive');
    });
    const partyButtons = function () {
      return app.drawer().querySelectorAll('button').filter(function (b) {
        return b.getAttribute('data-act') === 'party-lookup';
      });
    };
    // The client and the target on Summary, the operatives on People.
    const onSummary = partyButtons();
    app.tab('people');
    const parties = onSummary.concat(partyButtons());
    app.tab('summary');
    it('S8: offers Look up / Freeze beside every party, by role (IdentityAce: anonymous ones too)', function () {
      eq(parties.map(function (b) { return b.getAttribute('data-subject'); }),
        ['contract:ct00000001:client', 'contract:ct00000001:target', 'contract:ct00000001:op:hm1',
         'contract:ct00000001:op:hm2']);
      has(app.text(parties[0]), 'Look up / Freeze');
    });
    app.click(partyButtons()[1]);
    await settled();
    it('S8: which opens Players on them, on Measures, asked by the contract and the role, no citizen id', function () {
      eq(app.last('player').data.subject, 'contract:ct00000001:target');
      has(app.main(), 'Freeze');
      eq(app.byId('nav-pmeasures').getAttribute('aria-current'), 'page');
      eq(app.drawer().hidden, false, 'and the contract stays open over it');
    });
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), 'Dana Reyes');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('S8: Players takes a name, as Contracts does', function () {
      eq(app.last('player').data.subject, 'Dana Reyes');
      eq(app.byId('pl-q').getAttribute('placeholder'), 'Player id, citizen id or name');
    });
    app.nav('rules:timer');
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
      const subjects = function () {
        return app.drawer().querySelectorAll('button').filter(function (b) {
          return b.getAttribute('data-act') === 'party-lookup';
        }).map(function (b) { return b.getAttribute('data-subject'); });
      };
      const first = subjects();
      app.tab('people');
      eq(first.concat(subjects()), ['contract:ct00000001:target']);
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
    view.data.features.push(sw('Intel.GoDark.Enabled', 'Intel: Go dark'));
    view.data.features.push(sw('Roleplay.CityNews.Enabled', 'Roleplay: City news'));
    view.data.features.push(sw('Holds.AppPaused', 'Staff tools'));
    view.data.features.push(sw('Advisory.Enabled', 'Law enforcement advisory'));
    view.data.features.push(sw('Intel.Enabled', 'Intel: Informants'));
    view.data.features.push(sw('Anonymity.AllowAnonymousCreate', 'Anonymity'));
    view.data.limits.push({ key: 'Intel.Informant.Cost', category: 'rules-rewards', group: 'Intel: Informants', money: 'Intel prices',
      label: 'Price of a look-up', kind: 'number', integer: true, min: 0, max: 1000000, live: true,
      value: 25000, default: 25000, source: 'config' });
    view.data.limits.push({ key: 'Roleplay.WitnessHeat.WitnessRadius', category: 'rules-limits',
      group: 'Roleplay: Witness heat', label: 'How far a bystander sees it from', kind: 'number', min: 1, max: 500,
      live: true, value: 60, default: 60, source: 'config' });
    const app = boot(standardServer({ settings: view }));
    app.open(ADMIN);
    await settled();
    app.nav('rules:switch');
    await settled();
    const rank = app.window.CH_ADMIN_FEATURE_RANK;
    it('Features lists the core first, then Anonymity, Intel, Advisory, Staff tools, Roleplay, Improvements', function () {
      const groups = app.$$('.st-group').map(function (g) { return g.getAttribute('data-group'); });
      // Every Intel group together, its other groups after the area's four.
      const order = ['anonymity', 'intel: informants', 'intel: go dark', 'law enforcement advisory', 'staff tools',
        'roleplay: city news'];
      let last = -1;
      order.forEach(function (g) {
        const at = groups.indexOf(g);
        truthy(at > last, g + ' after the group before it: ' + groups.join(' | '));
        last = at;
      });
      truthy(groups.indexOf('buyouts') !== -1 && groups.indexOf('buyouts') < groups.indexOf('anonymity'),
        'a core group (Buyouts) before Anonymity');
      eq(rank('Access'), 0);
      truthy(rank('Anonymity') < rank('Intel: Informant tip') && rank('Intel: Informant tip') < rank('Law enforcement advisory')
        && rank('Law enforcement advisory') < rank('Staff tools') && rank('Staff tools') < rank('Roleplay: X')
        && rank('Roleplay: X') < rank('Improvements: Y'), 'the areas in order');
      truthy(rank('Intel: Whitelisted-job targets') < rank('Intel: Go dark')
        && rank('Intel: Go dark') < rank('Law enforcement advisory'), 'every Intel group inside its area');
    });
    it('every group drawn says in one line what it does', function () {
      app.$$('.st-group').forEach(function (g) {
        truthy(g.querySelector('.st-group-about'), g.getAttribute('data-group') + ' has no line saying what it does');
      });
    });
    app.nav('rules:money');
    await settled();
    it('every group in Rules says what it does too', function () {
      truthy(app.$$('.st-group').length > 0, 'groups');
      app.$$('.st-group').forEach(function (g) {
        truthy(g.querySelector('.st-group-about'), g.getAttribute('data-group') + ' has no line saying what it does');
      });
    });
    it('every number shows its unit: dollars, seconds, metres, percent', function () {
      has(app.text(app.byId('st-row-Intel.Informant.Cost')), 'Now: $25,000');
      const unit = app.window.CH_ADMIN_UNIT_OF;
      eq(unit({ key: 'Intel.Informant.Cost' }), '$');
      eq(unit({ key: 'Sources.cash.max' }), '$');
      eq(unit({ key: 'Limits.SlotCooldownSeconds' }), ' s');
      eq(unit({ key: 'PendingEscrow.LoginRetryDelayMs' }), ' ms');
      eq(unit({ key: 'Holds.RestartMaxHoldMinutes' }), ' min');
      eq(unit({ key: 'Record.Heat.DecayHours' }), ' h');
      eq(unit({ key: 'Audit.ContractRetentionDays' }), ' d');
      eq(unit({ key: 'Roleplay.WitnessHeat.WitnessRadius' }), ' m');
      eq(unit({ key: 'Improvements.ContractDecay.Percent' }), '%');
      eq(unit({ key: 'Bailout.MaxMultiplier' }), ' \u00d7');
      eq(unit({ key: 'Limits.MaxActiveContractsPerCreator' }), '', 'a count has none');
    });
    app.nav('help');
    await settled();
    app.click(app.button('Open all'));
    it('How it works: every optional feature has a card, titled by its area, in config.lua\'s order', function () {
      const ordered = app.window.CH_ADMIN_HELP_ORDERED();
      eq(app.$$('.help-card').length, ordered.length);
      const titles = ordered.map(function (c) { return c.title; });
      const rp = titles.filter(function (t) { return /^Roleplay: /.test(t); });
      const imp = titles.filter(function (t) { return /^Improvements: /.test(t); });
      const intel = titles.filter(function (t) { return /^Intel: /.test(t); });
      const rec = titles.filter(function (t) { return /^Record: /.test(t); });
      eq(rp.length, 10, 'ten roleplay cards (with the NPC places set from the panel): ' + rp.join(', '));
      eq(imp.length, 5, 'four improvements and the completion cooldown: ' + imp.join(', '));
      eq(rec.length, 4, 'four Record cards (reputation, tiers, heat, placer record): ' + rec.join(', '));
      truthy(titles.indexOf(rec[0]) > titles.indexOf(intel[intel.length - 1])
        && titles.indexOf(rec[rec.length - 1]) < titles.indexOf('Police advisories'),
        'every Record card right after Intel');
      eq(intel.length, 8, 'eight Intel cards (in person, rumours, the five rules, going dark): ' + intel.join(', '));
      truthy(titles.indexOf(intel[0]) > titles.indexOf('The informants')
        && titles.indexOf(intel[intel.length - 1]) < titles.indexOf('Police advisories'),
        'every Intel card right after The informants');
      truthy(titles.indexOf(rp[0]) > titles.indexOf('Moderators'), 'Roleplay after the staff tools');
      truthy(titles.indexOf(imp[0]) > titles.indexOf(rp[rp.length - 1]), 'Improvements after Roleplay');
      truthy(titles.indexOf('Anonymity') < titles.indexOf('The informants')
        && titles.indexOf('The informants') < titles.indexOf('Police advisories')
        && titles.indexOf('Police advisories') < titles.indexOf('The staff freeze'), 'the core areas in order');
      eq(rp[0], 'Roleplay: Witness heat', 'config.lua\'s first roleplay block first');
      eq(imp[0], 'Improvements: Contract decay', 'and its first improvement');
      eq(rec[0], 'Record: Reputation earned in character', 'Record in the order of config.lua');
      eq(intel[0], 'Intel: The informant in person', 'Intel in the order of config.lua');
    });
    app.nav('howto');
    await settled();
    it('Actions offers the hardest one to find: undoing a setting change, in History', function () {
      has(app.main(), 'Undo a setting change');
      truthy(app.$$('button[data-act="section"]').some(function (b) {
        return b.getAttribute('data-section') === 'logs:settings';
      }), 'a button to Logs, Setting changes');
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
    app.nav('pmoney');
    await settled();
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
    });
    app.nav('phistory');
    await settled();
    it('sweep 4 D2: the history by the handle the reread gave', function () {
      eq(app.last('history').data, { ref: 'p9_2' });
    });
    app.nav('pmeasures');
    await settled();
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
    app.nav('pmoney');
    await settled();
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
      measures: { ok: true, data: { rows: [] } },
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
    app.nav('pmeasures');
    await settled();
    app.click(app.button('Unfreeze'));
    await settled();
    it('sweep 5 review: Unfreeze on the first player is armed', function () {
      eq(app.requests('unfreeze').length, 0);
      truthy(app.button('Unfreeze').classList.contains('is-armed'));
    });
    // Another player, from the header search, while Measures is open.
    app.type(app.byId('gs-q'), '13');
    app.key(app.byId('gs-q'), 'Enter');
    await settled();
    app.nav('pmeasures');
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
    app.more();
    app.type(app.drawer().querySelector('[data-bind="dr.reason"]'), 'Duplicate');
    app.click(app.button('Void contract', app.drawer()));
    await settled();
    it('sweep 5 review: Void on the first contract is armed', function () {
      eq(app.requests('void').length, 0);
      truthy(app.button('Void contract', app.drawer()).classList.contains('is-armed'));
    });
    app.click(app.$$('tr.row')[1]);
    await settled();
    it('sweep 5 review: opening another contract closes its More, and leaves nothing armed', function () {
      eq(app.last('contract').data, { id: 'ct00000002' });
      eq(app.drawer().querySelectorAll('[data-act="void"]').length, 0, 'the void form is not carried over');
    });
    app.more();
    it('sweep 5 review: its own Void is not armed', function () {
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
      contracts: { ok: true, data: { page: 1, pages: 1, total: 3, targets: 2, rows: [
        { id: 'ct00000001', state: 'active', rule: 'alive', target: 'Dana Reyes', group: 't1', onTarget: 2,
          client: 'Anonymous', anonymous: true, slots: 1, claimed: 0, created_at: NOW - 60, deadline_at: NOW + 3600 },
        { id: 'ct00000002', state: 'accepted', rule: 'alive', target: 'Dana Reyes', group: 't1', onTarget: 2,
          client: XSS, slots: 1, claimed: 0, created_at: NOW - 120, deadline_at: NOW + 3600, frozen: true },
        { id: 'ct00000003', state: 'active', rule: 'either', target: XSS, group: 't2', onTarget: 1,
          client: 'Vic Marlowe', slots: 1, claimed: 0, created_at: NOW - 30 }] } }
    }, extra || {}));
  }

  /* Step 4b: Home is a dashboard (live counts, the inbox, quick actions and
     health at a glance), and nothing the server refuses shows a code. */
  await (async function homeDashboard() {
    const app = boot(standardServer({ overview: overview({ warnings: ['A problem with the setup'], overrides: 2 }),
      announce: { ok: false, err: 'some_internal_code' } }));
    app.open(ADMIN);
    await settled();
    app.group('home');
    await settled();
    it('Home opens on its dashboard', function () {
      eq(app.byId('nav-overview').getAttribute('aria-current'), 'page');
      has(app.text(app.byId('crumbs')), 'Dashboard');
    });
    it('with what waits, live counts, quick actions and the server\'s health at a glance', function () {
      const text = app.main();
      has(text, 'waiting for you');
      has(text, 'Operatives');
      has(text, 'Quick actions');
      has(text, 'Health');
      has(text, '1 problem');
      has(text, '2 settings');
    });
    app.click(app.button('Live by target'));
    await settled();
    it('a quick action is one click to where it is done', function () {
      eq(app.byId('nav-contracts').getAttribute('aria-current'), 'page');
      eq(app.last('contracts').data, { page: 1, state: 'live', byTarget: true });
    });
    app.nav('announce');
    await settled();
    it('Translations: the refusals read from locales/en.json, and a language with no file reads English', function () {
      eq(app.window.CH_ADMIN_WORDS({ ok: false, err: 'not_allowed' }), 'Not authorised.');
      eq(app.window.CH_ADMIN_WORDS({ ok: true }), 'Done.');
      const warned = [];
      const realWarn = console.warn;
      console.warn = function (m) { warned.push(m); };
      app.message({ type: 'open', access: FULL, locale: 'zz' });
      console.warn = realWarn;
      eq(app.window.CH_ADMIN_WORDS({ ok: false, err: 'not_allowed' }), 'Not authorised.');
      eq(warned.length, 1, 'said once: ' + warned.join(' | '));
      has(warned[0], 'no locales/zz.json');
    });
    it('a refusal with no words of its own shows no internal code', function () {
      const words = app.window.CH_ADMIN_WORDS({ ok: false, err: 'some_internal_code' });
      lacks(words, 'some_internal_code');
      lacks(words, 'Refused (');
      has(words, 'The audit log has the details');
    });
    clean(app, 'the dashboard');
  })();

  /* Translations 5: every word the panel shows is read by key from
     locales/<lang>.json, in the language its open message names. The panel
     loads before that message, so what it built from its words as it
     loaded (the sections, the screens' names and help, its own HTML) is
     built again in that language (Text.later). */
  await (async function panelInAnotherLanguage() {
    const fsx = require('fs');
    const en = JSON.parse(fsx.readFileSync(path.join(__dirname, '..', '..', 'crimson-hitman', 'locales', 'en.json'), 'utf8'));
    const qq = JSON.parse(JSON.stringify(en));
    Object.keys(qq.admin).forEach(function (k) { qq.admin[k] = '\u00ab' + qq.admin[k]; });
    localeXhr.extra['qq.json'] = qq;
    const app = boot(standardServer());
    app.message({ type: 'open', access: FULL, locale: 'qq' });
    await settled();
    delete localeXhr.extra['qq.json'];
    it('Translations: the panel reads its words in the language its open message names', function () {
      const nav = app.byId('nav').textContent;
      has(nav, '\u00abHome', 'its own HTML');
      has(app.byId('panel').textContent, '\u00ab', 'what it draws');
      const missing = [];
      (PAGE_JS.match(/\bt\('[\w]+\.[\w]+'\)/g) || []).forEach(function (call) {
        const key = call.slice(3, -2), at = key.indexOf('.');
        if (key === 'section.key') return;  // the comment that says how
        const sec = en[key.slice(0, at)];
        if (!sec || typeof sec[key.slice(at + 1)] !== 'string') missing.push(key);
      });
      eq(missing.join(', '), '', 'every key the panel asks for is in en.json');
    });
    clean(app, 'the panel in another language');
  })();

  /* Step 4b: a gear on each screen opens that screen's settings in place;
     Game rules stays the view of all of them. */
  await (async function settingsGear() {
    const app = boot(standardServer());
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    const gear = app.$('[data-act="gear"]');
    it('Contracts carries a gear beside its line of help', function () {
      truthy(gear, 'the gear');
      eq(app.byId('gear').hidden, true, 'closed until asked');
    });
    app.click(gear);
    await settled();
    it('the gear opens the screen\'s own settings above it, without leaving it', function () {
      eq(app.byId('nav-contracts').getAttribute('aria-current'), 'page');
      eq(app.byId('gear').hidden, false);
      has(app.text(app.byId('gear')), 'Settings for this screen');
      truthy(app.byId('gear').querySelector('#st-row-Bailout\\.Enabled') || app.byId('st-row-Bailout.Enabled'),
        'the buyout switch, a setting of contracts');
      falsy(app.text(app.byId('gear')).indexOf('Put the app on every home screen') !== -1, 'and not another screen\'s');
      truthy(app.button('All settings', app.byId('gear')), 'one click to every setting');
    });
    const sw = app.byId('st-row-Bailout.Enabled').querySelector('.switch');
    app.click(sw);
    await settled();
    it('a change there takes two clicks, as everywhere', function () {
      eq(app.requests('setSetting').length, 0, 'sent on one click');
    });
    app.click(app.byId('st-row-Bailout.Enabled').querySelector('.switch'));
    await settled();
    it('and the second click saves it', function () {
      eq(app.last('setSetting').data.key, 'Bailout.Enabled');
    });
    app.click(app.$('[data-act="gear"]'));
    await settled();
    it('the gear closes it again', function () { eq(app.byId('gear').hidden, true); });
    app.nav('rules');
    await settled();
    it('a screen that is settings already has no gear', function () { eq(app.$('[data-act="gear"]'), null); });
    clean(app, 'the settings gear');
  })();

  /* Step 4c: presets, each change previewed before a two-click apply. */
  await (async function presetsView() {
    const PRESETS = { ok: true, data: { presets: [
      { name: 'Strict', builtIn: true, about: 'Fewer contracts at once.', same: 1,
        changes: [{ key: 'Limits.MaxAcceptedPerHitman', label: 'Contracts a hitman may hold', from: '3', to: '2' },
          { key: 'Limits.MinContractReward', label: 'Least reward ' + XSS, from: '1000', to: '5000' }],
        refused: [{ key: 'Roleplay.ReasonQuality.Enabled', label: 'Reason quality', why: 'Needs its word list first.' }] },
      { name: 'Relaxed', builtIn: true, about: 'A busy board.', changes: [], refused: [], same: 6 },
      { name: 'Current', builtIn: false, about: 'As they were.', changes: [], refused: [], same: 7 },
      { name: 'Event ' + XSS, builtIn: false, own: true, about: 'Saved by Staff.', same: 0,
        changes: [{ key: 'Limits.MaxAcceptedPerHitman', label: 'Contracts a hitman may hold', from: '3', to: '4' }],
        refused: [] }] } };
    const app = boot(standardServer({ presets: PRESETS,
      presetApply: { ok: true, message: 'Strict applied: 2 settings changed.', data: { applied: ['a', 'b'], refused: [] } },
      presetSave: { ok: true, message: 'Saved: Current holds the settings the presets name, as they are now.' },
      presetSaveOwn: { ok: true, message: 'Saved: Night holds the 1 setting changed from the panel now.' },
      presetDelete: { ok: true, message: 'Deleted. Nothing else changed.' } }));
    app.open(ADMIN);
    await settled();
    app.nav('presets');
    await settled();
    it('Game rules > Presets lists each preset with every change it would make, escaped', function () {
      eq(app.byId('nav-presets').getAttribute('aria-current'), 'page');
      const text = app.main();
      has(text, 'Strict');
      has(text, 'Contracts a hitman may hold: 3 \u2192 2');
      has(text, 'Reason quality: left as it is. Needs its word list first.');
      has(text, 'Nothing to change: the settings are this already.');
      eq(app.body.querySelectorAll('img').length, 0, 'escaped');
      eq(app.requests('presetApply').length, 0, 'nothing applied by reading');
    });
    it('a preset with nothing to change cannot be applied', function () {
      truthy(app.button('Apply Relaxed').disabled);
    });
    const apply = app.button('Apply Strict');
    app.click(apply);
    await settled();
    it('Apply takes two clicks, the first naming how many changes', function () {
      eq(app.requests('presetApply').length, 0, 'sent on one click');
      has(app.text(apply), 'Click again: apply 2 changes');
    });
    app.click(apply);
    await settled();
    it('the second applies it by name and reads the settings again', function () {
      eq(app.last('presetApply').data, { name: 'Strict' });
      has(app.main(), 'Strict applied: 2 settings changed.');
      truthy(app.requests('settings').length >= 1, 'the settings read again');
    });
    const save = app.button('Save the settings now as Current');
    app.click(save);
    app.click(save);
    await settled();
    it('Save as Current takes two clicks too', function () { eq(app.requests('presetSave').length, 1); });
    app.click(app.button('Save the panel\'s changes as a preset'));
    await settled();
    it('your own preset needs a name first, and asks nothing without one', function () {
      eq(app.requests('presetSaveOwn').length, 0);
      has(app.main(), 'Name the preset first.');
    });
    app.type(app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'ps.name'; })[0], 'Night');
    app.click(app.button('Save the panel\'s changes as a preset'));
    await settled();
    it('saving your own preset takes two clicks', function () {
      eq(app.requests('presetSaveOwn').length, 0, 'armed by the first');
    });
    app.click(app.button('Save the panel\'s changes as a preset'));
    await settled();
    it('the second saves it under that name', function () {
      eq(app.last('presetSaveOwn').data, { name: 'Night' });
      has(app.main(), 'Saved: Night holds the 1 setting');
    });
    it('your own preset is marked yours, previewed like the shipped ones, escaped, with Delete', function () {
      has(app.main(), 'yours');
      has(app.main(), 'Contracts a hitman may hold: 3 → 4');
      eq(app.body.querySelectorAll('img').length, 0, 'escaped');
      eq(app.$$('[data-act="ps-delete"]').length, 1, 'Delete on your own preset only');
    });
    const del = app.$$('[data-act="ps-delete"]')[0];
    app.click(del);
    await settled();
    it('Delete takes two clicks', function () { eq(app.requests('presetDelete').length, 0); });
    app.click(del);
    await settled();
    it('and the second deletes it by name', function () {
      eq(app.last('presetDelete').data, { name: 'Event ' + XSS });
    });
    clean(app, 'presets');
  })();

  /* X2: Developer > Export and import (server/settingsio.lua). */
  await (async function exportImport() {
    const TEXT = '{"format":"crimson-hitman-settings","version":1,"settings":{"Limits.MaxAcceptedPerHitman":4}}';
    const app = boot(standardServer({
      settingsExport: { ok: true, data: { text: TEXT, settings: 1, presets: 0 } },
      settingsImport: { ok: true, data: { same: 2,
        changes: [{ key: 'Limits.MaxAcceptedPerHitman', label: 'Contracts a hitman may hold ' + XSS, from: '3', to: '4' }],
        refused: [{ key: 'Database.Mode', label: 'Storage mode', why: 'Never changed from the panel.' }],
        presets: [{ name: 'Night', keys: 1 }, { name: 'Strict', keys: 1, why: 'A shipped name.' }] } },
      settingsImportApply: { ok: true, message: 'Imported: 1 setting changed; 1 preset added.' } }));
    app.open(ADMIN);
    await settled();
    app.nav('transfer');
    await settled();
    it('workflow screen:admin.view:transfer — Developer has Export & import, saying what is not in it', function () {
      eq(app.byId('nav-transfer').getAttribute('aria-current'), 'page');
      has(app.main(), 'Not in it: the map places (Locations) and the target limits');
      eq(app.requests('settingsExport').length, 0, 'nothing asked by opening it');
    });
    app.click(app.button('Export the settings'));
    await settled();
    it('Export shows the text to copy and how much it holds', function () {
      eq(app.requests('settingsExport').length, 1);
      has(app.main(), '1 setting and 0 presets.');
      has(app.main(), 'Limits.MaxAcceptedPerHitman');
    });
    app.click(app.button('Read it'));
    await settled();
    it('Read it with nothing pasted asks nothing and says so', function () {
      eq(app.requests('settingsImport').length, 0);
      has(app.main(), 'Paste the exported text first.');
    });
    app.type(app.$$('textarea').filter(function (t) { return t.getAttribute('data-bind') === 'io.text'; })[0], TEXT);
    app.click(app.button('Read it'));
    await settled();
    it('the preview lists every change, every refused key with why, and the presets, escaped', function () {
      eq(app.last('settingsImport').data, { text: TEXT });
      has(app.main(), ': 3 → 4');
      has(app.main(), 'Storage mode (Database.Mode): left as it is. Never changed from the panel.');
      has(app.main(), 'Preset Night: added.');
      has(app.main(), 'Preset Strict: not added. A shipped name.');
      eq(app.body.querySelectorAll('img').length, 0, 'escaped');
      eq(app.requests('settingsImportApply').length, 0, 'nothing applied by reading');
    });
    const apply = app.button('Apply it');
    app.click(apply);
    await settled();
    it('Apply takes two clicks, the first naming the changes and the presets', function () {
      eq(app.requests('settingsImportApply').length, 0);
      has(app.text(apply), 'Click again: apply 1 change and add 1 preset');
    });
    app.click(apply);
    await settled();
    it('the second sends the text read and the count previewed', function () {
      eq(app.last('settingsImportApply').data, { text: TEXT, expect: 1 });
      has(app.main(), 'Imported: 1 setting changed; 1 preset added.');
    });
    clean(app, 'export and import');
  })();

  /* Step 5b: the first-start setup, shown by itself until it is saved. */
  await (async function firstStartSetup() {
    const SETUP = { ok: true, data: {
      saved: false,
      storage: { mode: 'mysql', choices: ['mysql', 'json'], line: "Config.Database.Mode = 'mysql'" },
      integrations: [
        { kind: 'dispatch', key: 'Integrations.Dispatch', choice: 'auto', active: 'sc-dispatch',
          choices: ['auto', 'sc-dispatch', 'none'], detected: [{ name: 'sc-dispatch', up: true }],
          without: 'nothing is filed in the police MDT' },
        { kind: 'keys', key: 'Integrations.Keys', choice: 'auto', active: null,
          choices: ['auto', 'qbx_vehiclekeys', 'none'], detected: [{ name: 'qbx_vehiclekeys', up: false }],
          without: 'the disposal vehicle is left unlocked ' + XSS }],
      aces: [{ name: 'Staff ACE (Config.Admin.Ace)', ace: 'crimson.admin', held: true,
        line: 'add_ace group.admin crimson.admin allow' }],
      command: { key: 'Admin.Commands.panel', label: 'Command name: panel', kind: 'text', value: 'hitmanadmin' },
      switches: [{ key: 'Intel.Enabled', label: 'Informant features', kind: 'switch', value: true }] } };
    const app = boot(standardServer({ setup: SETUP,
      setupPreview: { ok: true, data: { changes: [{ key: 'Integrations.Dispatch', label: 'Other scripts: dispatch',
        from: "'auto'", to: "'none'" }], refused: [], same: 0 } },
      setupApply: { ok: true, message: 'Setup saved: 1 setting changed.', data: { applied: ['Integrations.Dispatch'], refused: [] } } }));
    app.open(access({ canIdentify: false, setupDue: true }));
    await settled();
    it('opens on the setup by itself while none is saved, every choice at the value in force', function () {
      eq(app.byId('nav-setup').getAttribute('aria-current'), 'page');
      const text = app.main();
      has(text, "Config.Database.Mode = 'mysql'");
      has(text, 'add_ace group.admin crimson.admin allow');
      has(text, 'In use: sc-dispatch');
      has(text, 'Found: qbx_vehiclekeys');
      eq(app.body.querySelectorAll('img').length, 0, 'escaped');
      eq(app.requests('setupApply').length, 0, 'nothing applied by reading');
      truthy(app.button('Apply').disabled, 'no Apply before a preview');
    });
    pick(app, 'su-pick:Integrations.Dispatch', 'none');
    app.click(app.button('Preview'));
    await settled();
    it('Preview sends the choices and lists every change', function () {
      eq(app.last('setupPreview').data, { values: { 'Integrations.Dispatch': 'none' } });
      has(app.main(), "Other scripts: dispatch: 'auto' → 'none'");
    });
    const apply = app.button('Apply');
    app.click(apply);
    await settled();
    it('Apply takes two clicks, the first naming how many changes', function () {
      eq(app.requests('setupApply').length, 0, 'sent on one click');
      has(app.text(apply), 'Click again: apply 1 change and save');
    });
    app.click(apply);
    await settled();
    it('the second applies and saves it, and reads the settings again', function () {
      eq(app.last('setupApply').data, { values: { 'Integrations.Dispatch': 'none' } });
      has(app.main(), 'Setup saved: 1 setting changed.');
      truthy(app.requests('settings').length >= 1);
    });
    clean(app, 'the first-start setup');
  })();

  await (async function targetLimitsSection() {
    const app = boot(tlServer());
    app.open(ADMIN);
    await settled();
    app.click(app.byId('grp-targets'));
    await settled();
    it('Target limits: its own section under Daily, opening on Defaults (the settings view)', function () {
      eq(app.byId('nav-tldefaults').getAttribute('aria-current'), 'page');
      truthy(app.byId('nav-tljobs'));
      truthy(app.byId('nav-tlplayer'));
      truthy(app.byId('nav-contracts-bytarget'), 'and a link to the live contracts by target');
      eq(app.byId('nav-rules'), null, 'and nothing of Game rules');
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
    app.click(app.byId('grp-targets'));
    await settled();
    app.click(app.byId('nav-contracts-bytarget'));
    await settled();
    it('Live contracts by target: the one list of contracts, grouped by target, escaped', function () {
      eq(app.byId('nav-contracts').getAttribute('aria-current'), 'page');
      eq(app.last('contracts').data, { page: 1, state: 'live', byTarget: true });
      eq(app.$$('tr.tl-group').length, 2);
      eq(app.$$('tr.row').length, 3);
      has(app.main(), 'On hold');
      has(app.main(), '3 live contracts on 2 targets');
      eq(app.body.querySelectorAll('img').length, 0, 'escaped');
    });
    app.type(app.byId('ct-q'), 'Dana');
    app.fire(250);
    await settled();
    it('the search asks by target', function () {
      eq(app.last('contracts').data, { page: 1, query: 'Dana', state: 'live', byTarget: true });
    });
    app.click(app.$$('tr.row')[1]);
    await settled();
    app.more();
    it('a row opens the existing contract drawer, with its staff actions', function () {
      eq(app.last('contract').data, { id: 'ct00000002' });
      eq(app.drawer().hidden, false);
      truthy(app.button('Void contract', app.drawer()), 'the drawer\'s own Void');
    });
    clean(app, 'contracts by target');
  })();

  /* ======================================================================
     The new layout: header search, the context chips, the lists of
     Players, the organisation, Boss permissions and Locations.
     ====================================================================== */

  /** The organisation's catalogue rows, as server/org/settings_catalogue.lua adds them. */
  function orgSettings(on) {
    const view = settingsView();
    view.data.features.push({ key: 'Organisation.Enabled', category: 'organisation', group: 'Organisation',
      area: 'organisation', label: 'Hitman organisation', kind: 'switch', live: true, value: !!on, default: false,
      shipped: false, hasShipped: true, source: 'config', about: 'A real qbx_core job.' });
    view.data.limits.push({ key: 'Organisation.OfficeRadius', category: 'organisation', group: 'Organisation',
      area: 'organisation', label: 'Boss office radius (m)', kind: 'number', min: 1, max: 50, live: true, value: 5,
      default: 5, source: 'config' });
    view.data.limits.push({ key: 'Organisation.Limits.WithdrawMax', category: 'organisation',
      group: 'Organisation: Boss limits', area: 'organisation', label: 'Largest withdrawal ($)', kind: 'number',
      integer: true, min: 0, max: 10000000, live: true, value: 5000, default: 5000, source: 'config' });
    view.data.limits.push({ key: 'Organisation.Limits.MaxMembers', category: 'organisation',
      group: 'Organisation: Boss limits', area: 'organisation', label: 'Members at most', kind: 'number',
      integer: true, min: 1, max: 500, live: true, value: 30, default: 30, source: 'config' });
    view.data.limits.push({ key: 'Intel.Rumours.Locations', place: 'point', category: 'rules-limits',
      group: 'Intel: Rumours and broker', area: 'intel', label: 'Broker NPC places', kind: 'list', whole: true,
      live: true, value: [], default: [], source: 'config' });
    view.data.limits.push({ key: 'Limits.JailZone.x', place: 'jail', category: 'rules-limits', group: 'Contract limits',
      area: 'placing', label: 'Prison grounds centre, x', kind: 'number', min: -10000, max: 10000, live: true,
      value: 1700, default: 1700, source: 'config' });
    view.data.limits.push({ key: 'Limits.JailZone.y', place: 'jail', category: 'rules-limits', group: 'Contract limits',
      area: 'placing', label: 'Prison grounds centre, y', kind: 'number', min: -10000, max: 10000, live: true,
      value: 2600, default: 2600, source: 'config' });
    return view;
  }

  function orgServer(extra) {
    const server = standardServer(Object.assign({
      settings: orgSettings(true), orgGet: orgOn(),
      orgFunds: { ok: true, data: { balance: 12500, bank: false, rows: [
        { kind: 'staff_deposit', amount: 5000, at: NOW - 60, reason: 'Seed ' + XSS, actor: 'ADMIN001' }] } },
      'logs.org': function (data) {
        return { ok: true, data: { rows: [{ ts: NOW - 30, action: data.action || 'org_grant', by: 'a staff member',
          detail: { subject: 'role', id: '3', power: 'M2', before: 'off', after: 'allow', note: XSS } }] } };
      },
      placeList: placesView(),
      placeMyPosition: { ok: true, data: { x: 123.456, y: -654.321, z: 30.04, heading: 182.6 } }
    }, extra || {}));
    ['orgSetup', 'orgRename', 'orgLayout', 'orgNotice', 'orgRoleSet', 'orgRoleRemove', 'orgRolePowers',
      'orgMemberHire', 'orgMemberRole', 'orgMemberFire', 'orgMemberSuspend', 'orgMemberLimits', 'orgMemberOverride',
      'bossPermsSet', 'bossPermsRevokeAll', 'bossLimits', 'bossOfficeRule', 'orgCuts', 'orgFundsMove', 'orgAccess',
      'orgPick', 'placeSet', 'placeRemove', 'orgApplication', 'orgFundsBackend', 'orgContractAssign',
      'orgAcceptDecide', 'orgProbation', 'orgDutyOff', 'orgChannelPost', 'orgChannelRemove', 'orgChannelMute',
      'orgDossier'].forEach(function (op) {
      if (server[op] === undefined) server[op] = { ok: true, message: op + ' done.' };
    });
    return server;
  }

  /* ---- several organisations (Organisation.SeveralOrganisations) ---- */
  await (async function () {
    const several = { several: true, id: 'hitman', maxOrgs: 3, orgs: [
      { id: 'hitman', label: 'Crimson Contractors', job: 'hitman', members: 2, first: true },
      { id: 'syndicate', label: 'The Syndicate ' + XSS, job: 'syndicate', members: 0 }] };
    const server = orgServer({ orgGet: function (data) {
      const view = orgOn(several);
      if (data && data.org === 'syndicate') { view.data.id = 'syndicate'; view.data.label = 'The Syndicate'; }
      return view;
    }, orgCreate: { ok: true, message: 'orgCreate done.' }, orgRemove: { ok: true, message: 'orgRemove done.' } });
    const app = boot(server);
    app.open(FULL);
    await settled();
    app.nav('orgsetup');
    await settled();
    const found = [];
    markupFrom(app, 'org several', found);
    it('ORG EXTRAS 3: Setup lists the organisations, escaped, and which one is worked on', function () {
      eq(found, []);
      has(app.main(), 'Organisations');
      has(app.main(), 'The Syndicate ' + XSS);
      has(app.main(), 'Working on this one');
    });
    app.click(app.button('Work on this'));
    await settled();
    it('ORG EXTRAS 3: picking one sends its id with every organisation op after', function () {
      eq(app.last('orgGet').data.org, 'syndicate');
    });
    app.click(app.button('Create / sync job'));
    app.click(app.button('Create / sync job'));
    await settled();
    it('ORG EXTRAS 3: a write goes to the one picked', function () {
      eq(app.last('orgSetup').data.org, 'syndicate');
    });
    app.click(app.button('Work on this'));
    await settled();
    it('ORG EXTRAS 3: picking the first again sends no id', function () {
      eq(app.last('orgGet').data.org, undefined);
    });
    app.type(app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'org.new.job'; })[0], 'cartel');
    app.type(app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'org.new.label'; })[0], 'Cartel');
    const add = app.button('Add');
    app.click(add);
    it('ORG EXTRAS 3: Add takes two clicks, naming what it adds', function () {
      eq(app.requests('orgCreate').length, 0);
      has(app.text(add), 'Click again: add Cartel (cartel)');
    });
    app.click(app.button('Add'));
    await settled();
    it('workflow screen:admin.org.several \u2014 adds one with its job and label, unscoped', function () {
      eq(app.last('orgCreate').data, { job: 'cartel', label: 'Cartel' });
    });
    app.click(app.button('Take off'));
    app.click(app.button('Take off'));
    await settled();
    it('ORG EXTRAS 3: Take off takes two clicks and names the one', function () {
      eq(app.last('orgRemove').data, { id: 'syndicate' });
    });
  })();

  /* ---- the header search ---- */
  await (async function () {
    const app = boot(standardServer());
    app.open(ADMIN);
    await settled();
    app.key(app.body, '/');
    it('/ goes to the header search', function () {
      truthy(app.document.activeElement === app.byId('gs-q'), 'the search box has the focus');
    });
    app.type(app.byId('gs-q'), 'buyout');
    await settled();
    const hits = function () { return app.byId('gs-results').querySelectorAll('.gs-hit'); };
    it('typing lists settings, actions and sections that match, from the settings read once', function () {
      truthy(app.requests('settings').length >= 1, 'the settings read for the index');
      const text = app.text(app.byId('gs-results'));
      has(text, 'Buyouts', 'a setting');
      has(text, 'Look up “buyout” as a player', 'and a player lookup last');
      falsy(app.byId('gs-results').hidden);
      truthy(hits().length <= 20, 'at most twenty');
    });
    app.type(app.byId('gs-q'), 'messages');
    await settled();
    it('a setting\'s label in the list is text, never markup', function () {
      has(app.text(app.byId('gs-results')), XSS);
      eq(app.byId('gs-results').querySelectorAll('img').length, 0);
    });
    app.click(hits().filter(function (b) { return b.getAttribute('data-value') === 'Relay.Enabled'; })[0]);
    await settled();
    it('a setting hit opens its row in its area, marked, the search closed', function () {
      eq(app.byId('nav-rules').getAttribute('aria-current'), 'page');
      truthy(app.byId('st-row-Relay.Enabled').classList.contains('is-focus'));
      eq(app.byId('gs-results').hidden, true);
      has(app.text(app.byId('crumbs')), 'Phone messages & notifications');
    });
    app.type(app.byId('gs-q'), 'ct00000001');
    app.key(app.byId('gs-q'), 'Enter');
    await settled();
    it('Enter on a contract id opens the contract', function () {
      eq(app.last('contract').data, { id: 'ct00000001' });
      eq(app.drawer().hidden, false);
    });
    app.click(app.button('Close', app.drawer()));
    await settled();
    app.type(app.byId('gs-q'), '12');
    app.key(app.byId('gs-q'), 'Enter');
    await settled();
    it('Enter on a player id looks them up, on Players', function () {
      eq(app.last('player').data, { subject: '12' });
      eq(app.byId('nav-players').getAttribute('aria-current'), 'page');
    });
    app.type(app.byId('gs-q'), 'zzqqxx');
    await settled();
    it('with nothing matching, Enter would look it up as a player', function () {
      has(app.text(app.byId('gs-results')), 'Look up “zzqqxx” as a player');
    });
    app.keyUp(app.byId('gs-q'), 'Escape');
    await settled();
    it('Escape in the search clears it, and the panel stays open', function () {
      eq(app.byId('panel').hidden, false);
      eq(app.byId('gs-results').hidden, true);
      eq(app.byId('gs-q').value, '');
    });
    app.key(app.body, 'k');
    it('k alone types nothing anywhere; Ctrl+K goes to the search', function () {
      app.document.activeElement = null;
      markup.dispatch(app.body, 'keydown', { key: 'k', ctrlKey: true });
      truthy(app.document.activeElement === app.byId('gs-q'), 'the search box has the focus');
    });
    app.type(app.byId('gs-q'), 'freeze');
    await settled();
    it('an action hit opens where it is done', function () {
      const action = hits().filter(function (b) { return b.getAttribute('data-act') === 'gs-action'; })[0];
      truthy(action, 'an action');
      app.click(action);
    });
    await settled();
    it('(Players, for a freeze)', function () { eq(app.byId('grp-players').getAttribute('aria-current'), 'page'); });
    clean(app, 'header search');
  })();

  /* ---- the context: the selected player and the contract stay put ---- */
  await (async function () {
    const clock = { ms: Date.now() };
    const app = boot(standardServer(), { clock: clock });
    app.open(ADMIN);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    it('a lookup puts the player in a header chip, with the minutes left of its handle', function () {
      eq(app.byId('ctx').hidden, false);
      has(app.text(app.byId('ctx')), 'Player: Dana Reyes');
      has(app.text(app.byId('ctx')), '10 min');
      has(app.text(app.byId('crumbs')), 'Dana Reyes (in city · 12)');
    });
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    it('and stays there in another section, beside the contract opened', function () {
      has(app.text(app.byId('ctx')), 'Player: Dana Reyes');
      has(app.text(app.byId('ctx')), 'Contract: ct00000001');
    });
    app.nav('logs');
    await settled();
    it('the drawer stays open over any section until it is closed', function () {
      eq(app.drawer().hidden, false);
      eq(app.byId('nav-logs').getAttribute('aria-current'), 'page');
    });
    app.click(app.button('Close', app.drawer()));
    await settled();
    const reads = app.requests('contract').length;
    app.click(app.$$('[data-act="ctx-contract"]')[0]);
    await settled();
    it('the contract chip opens it again after it is closed', function () {
      eq(app.drawer().hidden, false);
      eq(app.requests('contract').length, reads + 1);
    });
    app.click(app.$$('[data-act="ctx-player"]')[0]);
    await settled();
    it('the player chip opens their card', function () {
      eq(app.byId('grp-players').getAttribute('aria-current'), 'page');
      has(app.main(), 'Dana Reyes');
    });
    clock.ms += 11 * 60 * 1000;
    app.fire(30000);
    await settled();
    it('once the handle has run out, the chip asks for a lookup again', function () {
      has(app.text(app.byId('ctx')), 'look up again');
      truthy(app.$$('[data-act="ctx-relookup"]').length, 'a re-lookup');
    });
    app.click(app.$$('[data-act="ctx-relookup"]')[0]);
    await settled();
    it('which looks them up again as typed', function () {
      eq(app.last('player').data, { subject: '12' });
      has(app.text(app.byId('ctx')), '10 min');
    });
    app.click(app.$$('[data-act="ctx-player-clear"]')[0]);
    await settled();
    app.click(app.$$('[data-act="ctx-contract-clear"]')[0]);
    await settled();
    it('each chip clears itself; the contract\'s closes the drawer too', function () {
      eq(app.byId('ctx').hidden, true);
      eq(app.drawer().hidden, true);
      eq(app.byId('nav-pmeasures'), null, 'no player tabs without a player');
    });
    clean(app, 'context chips');
  })();

  /* ---- Players: All measures (suspended, protected), and why can't they see ---- */
  await (async function () {
    const server = standardServer({
      measures: { ok: true, data: { rows: [
        { kind: 'suspend', ref: 'f1', name: 'Dana ' + XSS, since: NOW - 600, until: NOW + 86400, reason: 'Spam ' + XSS,
          online: true },
        { kind: 'protect', ref: 'f2', name: 'Vic Marlowe', cid: 'CREATOR1', since: NOW - 60, reason: 'Event guest' },
        { kind: 'limit', ref: 'f3', name: 'Kai Holt', since: NOW - 30, reason: 'Event', exempt: true }] } },
      unsuspend: { ok: true, message: 'Suspension lifted.' },
      unprotect: { ok: false, err: 'not_active', message: 'They are not protected.' }
    });
    const app = boot(server);
    app.open(FULL);
    await settled();
    const filter = function (k) {
      app.click(app.$$('[data-act="ms-kind"]').filter(function (b) { return b.getAttribute('data-value') === k; })[0]);
    };
    app.nav('measures');
    await settled();
    it('All measures lists every kind, the override sent to Target limits to lift with a reason', function () {
      has(app.main(), 'Kai Holt');
      has(app.main(), 'exempt');
      has(app.main(), 'In Target limits');
    });
    filter('suspend');
    await settled();
    it('Suspended lists everybody suspended now, escaped, each with Lift', function () {
      eq(app.last('measures').op, 'measures');
      has(app.main(), 'Spam ' + XSS);
      eq(app.$$('img').length, 0);
      truthy(app.button('Lift'));
    });
    const lift = app.button('Lift');
    app.click(lift);
    await settled();
    it('Lift takes two clicks, naming who', function () {
      eq(app.requests('unsuspend').length, 0);
      has(app.text(lift), 'Click again: lift for Dana ' + XSS);
    });
    app.click(lift);
    await settled();
    it('and lifts by the list\'s handle, then reads the list again', function () {
      eq(app.last('unsuspend').data, { ref: 'f1' });
      truthy(app.requests('measures').length >= 2);
    });
    filter('protect');
    await settled();
    it('Protected lists the protected, with an Open for a citizen id staff may see', function () {
      has(app.main(), 'Vic Marlowe');
      has(app.main(), 'for good');
      truthy(app.button('Open'));
    });
    app.click(app.button('Lift'));
    app.click(app.button('Lift'));
    await settled();
    it('a refused lift says so on its row', function () {
      has(app.main(), 'They are not protected.');
    });
    app.click(app.button('Open'));
    await settled();
    it('Open looks them up by their citizen id', function () {
      eq(app.last('player').data, { subject: 'CREATOR1' });
    });
    app.nav('pdiag');
    await settled();
    app.click(app.button('Run the diagnosis as them'));
    await settled();
    it('Why can\'t they see runs the diagnosis by the lookup\'s handle', function () {
      eq(app.last('diag').data, { ref: 'p7_424242' });
      has(app.main(), 'photo hosts: 0 -> add one');
    });
    app.nav('pmeasures');
    await settled();
    app.click(app.button('Open them in Target limits'));
    await settled();
    it('Measures opens their standing in Target limits by the same lookup', function () {
      eq(app.byId('nav-tlplayer').getAttribute('aria-current'), 'page');
      eq(app.last('targetStatus').data, { ref: 'p7_424242' });
    });
    clean(app, 'players lists');
  })();

  /* ---- the organisation, switched off ---- */
  await (async function () {
    const server = standardServer({ orgGet: orgOff(), settings: orgSettings(false) });
    const app = boot(server);
    app.open(FULL);
    await settled();
    const views = ['orgsetup', 'orgroles', 'orgmembers', 'orgfunds', 'bpmatrix', 'bplimits'];
    const off = {};
    for (const view of views) {
      app.nav(view);
      await settled();
      off[view] = app.main().indexOf('The hitman job is switched off') !== -1 && !!app.byId('st-row-Organisation.Enabled');
    }
    it('every organisation and Boss permissions view is one card saying it is off, with its switch', function () {
      views.forEach(function (v) { truthy(off[v], v); });
      eq(app.requests('orgFunds').length, 0, 'nothing more asked of an organisation that is off');
    });
    app.nav('orgsetup');
    await settled();
    const sw = app.byId('st-row-Organisation.Enabled').querySelector('.switch');
    app.click(sw);
    await settled();
    it('the switch takes two clicks, naming the value', function () {
      eq(app.requests('setSetting').length, 0);
      has(app.text(sw.querySelector('.cfm')), 'Click again: turn On');
    });
    server.settings = orgSettings(true);
    server.orgGet = orgOn();
    const asked = app.requests('orgGet').length;
    app.click(sw);
    await settled();
    it('and once it is on, the organisation is read again and drawn', function () {
      eq(app.last('setSetting').data, { key: 'Organisation.Enabled', value: true });
      truthy(app.requests('orgGet').length > asked, 'read again');
      has(app.main(), 'The job');
      has(app.main(), 'Create / sync job');
    });
    app.nav('locations');
    await settled();
    clean(app, 'organisation off');
  })();

  /* ---- the organisation, on ---- */
  await (async function () {
    const server = orgServer();
    const app = boot(server);
    app.open(FULL);
    await settled();
    app.nav('orgsetup');
    await settled();
    const found = [];
    markupFrom(app, 'org setup', found);
    it('Setup says what the job is, escaped, with Create / sync, Rename and the boss menu', function () {
      eq(found, []);
      has(app.main(), 'The Crimson ' + XSS);
      has(app.main(), '2 · 1 in the city');
      has(app.main(), "this resource's own ledger");
      truthy(app.byId('st-row-Organisation.OfficeRadius'), 'its own settings');
      falsy(app.byId('st-row-Organisation.Limits.WithdrawMax'), 'but not the boss limits, which are Boss permissions\'');
    });
    const sync = app.button('Create / sync job');
    app.click(sync);
    it('Create / sync takes two clicks, naming the job', function () {
      eq(app.requests('orgSetup').length, 0);
      has(app.text(sync), 'Click again: register hitman in qbx_core');
    });
    app.click(sync);
    await settled();
    it('and asks once on the second', function () { eq(app.requests('orgSetup').length, 1); });
    app.type(app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'org.label'; })[0], 'Night Shift');
    const rename = app.button('Rename');
    app.click(rename);
    it('Rename arms with the label it sets', function () {
      eq(app.requests('orgRename').length, 0);
      has(app.text(rename), 'Click again: rename to Night Shift');
    });
    app.type(app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'org.label'; })[0], 'Night Shift 2');
    it('typing again disarms it', function () { falsy(rename.classList.contains('is-armed')); });
    app.click(app.button('Rename'));
    app.click(app.button('Rename'));
    await settled();
    it('and renames to what was typed last', function () {
      eq(app.last('orgRename').data, { label: 'Night Shift 2' });
      has(app.toasts(), 'orgRename done.');
    });
    app.click(app.$$('[data-act="org-tab-hide"]').filter(function (b) {
      return b.getAttribute('data-value') === 'notices' && b.getAttribute('data-id') === '1'; })[0]);
    app.click(app.button('Save the boss menu'));
    app.click(app.button('Save the boss menu'));
    await settled();
    it('the boss menu saves its labels and hidden tabs, keeping what was set before', function () {
      eq(app.last('orgLayout').data, { layout: { labels: { members: 'Crew' }, hidden: { funds: [1], notices: [1] } } });
    });

    // Roles & pay.
    app.nav('orgroles');
    await settled();
    it('Roles lists each role with its pay and members', function () {
      has(app.main(), 'Hitman ' + XSS);
      has(app.main(), '$500');
      eq(app.$$('img').length, 0);
    });
    app.click(app.$$('[data-act="org-role-open"]').filter(function (b) { return b.getAttribute('data-id') === '3'; })[0]);
    await settled();
    it('a role opens its editor and its power checklist, marking powers above the ceiling', function () {
      has(app.main(), 'Role: Boss');
      has(app.main(), 'within the ceiling', 'M1 is allowed for this role');
      has(app.main(), 'above the ceiling');
      truthy(app.button('Remove role').disabled, 'not while it holds members');
    });
    const give = app.$$('[data-act="org-role-power"]').filter(function (b) { return b.getAttribute('data-power') === 'M2'; })[0];
    app.click(give);
    it('giving a power arms, naming it and the role', function () {
      eq(app.requests('orgRolePowers').length, 0);
      has(app.text(give), 'Click again: give Hire to Boss');
    });
    app.click(give);
    await settled();
    it('and sends the grade, the power and on', function () {
      eq(app.last('orgRolePowers').data, { grade: 3, power: 'M2', on: true });
      truthy(app.requests('orgGet').length >= 2, 'the organisation read again');
    });
    server.orgRoleSet = { ok: false, err: 'org_bounds', message: 'Outside the bounds staff set.' };
    app.type(app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'org.role.3.pay'; })[0], '9000');
    app.click(app.button('Save role'));
    app.click(app.button('Save role'));
    await settled();
    it('a role saved sends what was typed, and a refusal shows the server\'s words on the card', function () {
      eq(app.last('orgRoleSet').data, { grade: 3, name: 'boss', label: 'Boss', pay: 9000 });
      has(app.main(), 'Outside the bounds staff set.');
    });
    server.orgRoleSet = { ok: true, message: 'Role added.' };
    app.click(app.button('Add role'));
    it('adding a role with no grade is refused before it is sent', function () {
      has(app.main(), 'Give the role a whole grade from 0 to 100.');
    });
    const bind = function (b) { return app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === b; })[0]; };
    app.type(bind('org.new.grade'), '2');
    app.type(bind('org.new.name'), 'lieutenant');
    app.type(bind('org.new.label'), 'Lieutenant');
    app.type(bind('org.new.pay'), '250');
    const add = app.button('Add role');
    app.click(add);
    it('adding one arms, naming the label and grade', function () { has(app.text(add), 'Click again: add Lieutenant at grade 2'); });
    app.click(add);
    await settled();
    it('and sends it', function () {
      eq(app.last('orgRoleSet').data, { grade: 2, name: 'lieutenant', label: 'Lieutenant', isBoss: false, pay: 250 });
    });

    // Members.
    app.nav('orgmembers');
    await settled();
    app.click(app.button('Hire'));
    it('Hire without a player selected or a citizen id says how, and sends nothing', function () {
      has(app.main(), 'Look a player up in Players first');
      eq(app.requests('orgMemberHire').length, 0);
    });
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    app.nav('orgmembers');
    await settled();
    const hire = app.button('Hire');
    app.click(hire);
    it('with a player selected, Hire names them and the role', function () {
      has(app.text(hire), 'Click again: hire Dana Reyes as Hitman ' + XSS);
    });
    app.click(hire);
    await settled();
    it('and hires them by the lookup\'s handle', function () {
      eq(app.last('orgMemberHire').data, { grade: 1, ref: 'p7_424242' });
    });
    app.click(app.$$('[data-act="org-member-open"]').filter(function (b) { return b.getAttribute('data-id') === 'm2_2222'; })[0]);
    await settled();
    it('Manage opens one member, their name escaped', function () {
      has(app.main(), 'Member: ' + XSS);
      eq(app.$$('img').length, 0);
    });
    app.click(app.$$('[data-act="org-member-grade"]').filter(function (b) {
      return b.getAttribute('data-id') === 'm2_2222' && b.getAttribute('data-value') === '3'; })[0]);
    const setRole = app.button('Set role');
    app.click(setRole);
    app.click(setRole);
    await settled();
    it('Set role sends the member\'s handle and the grade', function () {
      eq(app.last('orgMemberRole').data, { member: 'm2_2222', grade: 3 });
    });
    app.click(app.$$('[data-act="org-member-open"]').filter(function (b) { return b.getAttribute('data-id') === 'm2_2222'; })[0]);
    app.click(app.$$('[data-act="org-member-open"]').filter(function (b) { return b.getAttribute('data-id') === 'm2_2222'; })[0]);
    await settled();
    app.click(app.button('Fire'));
    it('Fire needs a reason', function () {
      eq(app.requests('orgMemberFire').length, 0);
      has(app.main(), 'Give a reason: it goes on the record.');
    });
    app.type(bind('org.m.m2_2222.freason'), 'Talked');
    app.click(app.button('Fire'));
    app.click(app.button('Fire'));
    await settled();
    it('and fires with it on two clicks', function () {
      eq(app.last('orgMemberFire').data, { member: 'm2_2222', reason: 'Talked' });
    });

    // Applications.
    app.nav('orgapps');
    await settled();
    it('Applications shows each, escaped', function () {
      has(app.main(), 'I am quiet ' + XSS);
      eq(app.$$('img').length, 0);
    });
    app.click(app.button('Accept'));
    app.click(app.button('Accept'));
    await settled();
    it('Accept, on two clicks, sends the application and true', function () {
      eq(app.last('orgApplication').data, { id: 'hitman:app:1', accept: true });
    });

    // Funds & cuts.
    app.nav('orgfunds');
    await settled();
    it('Funds shows the balance and the ledger, escaped, no actor without the identity ACE', function () {
      eq(app.last('orgFunds').data, { limit: 50 });
      has(app.main(), '$12,500');
      has(app.main(), 'Seed ' + XSS);
      eq(app.$$('img').length, 0);
    });
    app.type(bind('org.funds.amount'), '2500');
    app.type(bind('org.funds.reason'), 'Float');
    const move = app.$$('[data-act="org-funds"]')[0];
    app.click(move);
    it('a deposit arms with the amount', function () { has(app.text(move), 'Click again: deposit $2,500'); });
    server.orgFundsMove = function () { return new Promise(function () {}); };
    app.click(move);
    await settled();
    const firstNonce = app.last('orgFundsMove').data.nonce;
    server.orgFundsMove = { ok: true, message: 'Deposited.' };
    it('and sends direction, amount, reason and a nonce', function () {
      const sent = app.last('orgFundsMove').data;
      eq([sent.direction, sent.amount, sent.reason], ['deposit', 2500, 'Float']);
      truthy(typeof firstNonce === 'string' && firstNonce.length > 4, 'a nonce');
    });
    app.type(bind('org.cut.payout'), '60');
    app.click(app.$$('[data-act="org-cut"]').filter(function (b) { return b.getAttribute('data-value') === 'payout'; })[0]);
    it('a cut over the staff cap is refused before it is sent', function () {
      eq(app.requests('orgCuts').length, 0);
      has(app.main(), 'At most 40%');
    });
    app.type(bind('org.cut.payout'), '15');
    const cut = app.$$('[data-act="org-cut"]').filter(function (b) { return b.getAttribute('data-value') === 'payout'; })[0];
    app.click(cut);
    it('a cut arms naming its percent', function () { has(app.text(cut), 'Click again: set the payout cut to 15%'); });
    app.click(cut);
    await settled();
    it('and sends it', function () { eq(app.last('orgCuts').data, { kind: 'payout', percent: 15 }); });

    // Where the funds are kept.
    const switchTo = app.$$('[data-act="org-backend"]')[0];
    app.click(switchTo);
    it('switching where the funds are kept arms, naming where they go', function () {
      eq(app.requests('orgFundsBackend').length, 0);
      has(app.text(switchTo), 'Click again: move the funds to Renewed-Banking');
    });
    app.click(switchTo);
    await settled();
    it('and sends the backend', function () { eq(app.last('orgFundsBackend').data, { backend: 'bank' }); });
    server.orgFunds = { ok: true, data: { backend: 'bank', ready: false, rows: [] } };
    app.click(app.button('Refresh'));
    await settled();
    it('a bank that is down: the balance is unknown, and Abandon is offered with its warning', function () {
      has(app.main(), 'Unknown');
      has(app.main(), 'Abandon leaves it carrying nothing');
    });
    const abandon = app.button('Abandon the bank');
    app.click(abandon);
    it('Abandon arms, saying it starts from $0', function () {
      has(app.text(abandon), 'Click again: abandon the bank, start from $0 in this resource\'s own ledger');
    });
    app.click(abandon);
    await settled();
    it('and sends the backend with abandon', function () {
      eq(app.last('orgFundsBackend').data, { backend: 'internal', abandon: true });
    });

    // Contract access and the notice.
    app.nav('orgaccess');
    await settled();
    app.click(app.$$('[data-act="org-access"]').filter(function (b) { return b.getAttribute('data-id') === '1'; })[0]);
    app.click(app.$$('[data-act="org-access"]').filter(function (b) { return b.getAttribute('data-id') === '1'; })[0]);
    await settled();
    it('Contract access saves a role\'s rules, clearing what is empty', function () {
      eq(app.last('orgAccess').data, { grade: 1, rules: { maxReward: 50000, maxAtOnce: false, cooldownMinutes: false,
        rule: 'alive', whitelisted: true } });
    });
    app.nav('orgnotices');
    await settled();
    it('Notices shows the notice, escaped', function () {
      has(app.main(), 'Meet at ' + XSS);
      eq(app.$$('img').length, 0);
    });
    app.type(bind('org.notice'), 'Quiet week');
    app.click(app.button('And message every member'));
    app.click(app.button('Post'));
    app.click(app.button('Post'));
    await settled();
    it('Post sends the text and whether every member is messaged', function () {
      eq(app.last('orgNotice').data, { text: 'Quiet week', broadcast: true });
    });
    app.group('org');
    await settled();
    app.click(app.byId('nav-logs-org'));
    await settled();
    it('Org audit is Logs\' Org audit chip, reached from the section, and reads the log, escaped', function () {
      eq(app.byId('nav-logs').getAttribute('aria-current'), 'page');
      eq(app.last('logs.org').data, { area: 'org', limit: 100 });
      has(app.main(), XSS);
      eq(app.$$('img').length, 0);
    });
    clean(app, 'organisation on');
  })();

  /* ---- Boss permissions ---- */
  await (async function () {
    const server = orgServer();
    const app = boot(server);
    app.open(FULL);
    await settled();
    app.nav('bpmatrix');
    await settled();
    const cell = function (col, power) {
      return app.$$('[data-act="bp-cell"]').filter(function (b) {
        return b.getAttribute('data-id') === col && b.getAttribute('data-power') === power; })[0];
    };
    it('the matrix has a column per boss role and per boss with a ceiling of their own', function () {
      truthy(cell('role:3', 'M1'), 'the Boss role');
      truthy(cell('member:m1_1111', 'C7'), 'Kai Holt, who has a cell of their own');
      falsy(cell('role:1', 'M1'), 'not a role that is not boss');
      has(app.text(cell('role:3', 'M1')), 'Allow');
      has(app.text(cell('member:m1_1111', 'C7')), 'Deny');
      has(app.text(cell('member:m1_1111', 'M1')), 'Inherit role');
      has(app.main(), 'Post notice ' + XSS);
      eq(app.$$('img').length, 0);
    });
    app.click(cell('role:3', 'M2'));
    app.click(cell('member:m1_1111', 'M1'));
    app.click(cell('member:m1_1111', 'C7'));
    await settled();
    it('cells change locally and are listed before anything is saved', function () {
      eq(app.requests('bossPermsSet').length, 0);
      truthy(cell('role:3', 'M2').classList.contains('is-pending'));
      has(app.main(), 'Changes to save (3)');
      has(app.main(), '+ Hire for Boss');
      has(app.main(), '+ View members for Kai Holt');
      has(app.main(), '↺ Withdraw funds for Kai Holt (inherit role)');
    });
    app.click(cell('role:3', 'M2'));
    it('a cell clicked back to what is saved leaves the list', function () {
      has(app.main(), 'Changes to save (2)');
    });
    app.click(cell('role:3', 'M2'));
    const save = app.button('Save 3 changes');
    app.click(save);
    it('Save takes two clicks, naming how many', function () {
      eq(app.requests('bossPermsSet').length, 0);
      has(app.text(save), 'Click again: save 3 changes');
    });
    server.bossPermsSet = { ok: false, err: 'org_not_found', message: 'Cell 2: that member handle is out of date.' };
    app.click(save);
    await settled();
    it('the second sends every change as one batch', function () {
      eq(app.requests('bossPermsSet').length, 1);
      eq(app.last('bossPermsSet').data, { cells: [
        { subject: 'member', id: 'm1_1111', power: 'M1', state: 'allow' },
        { subject: 'member', id: 'm1_1111', power: 'C7', state: 'inherit' },
        { subject: 'role', id: 3, power: 'M2', state: 'allow' }] });
    });
    it('and a refusal keeps the changes, saying why', function () {
      has(app.main(), 'Cell 2: that member handle is out of date.');
      has(app.main(), 'Changes to save (3)');
    });
    server.bossPermsSet = { ok: true, message: '3 cell(s) saved.' };
    app.click(app.button('Save 3 changes'));
    app.click(app.button('Save 3 changes'));
    await settled();
    it('saved, the list empties and the matrix is read again', function () {
      has(app.main(), 'Nothing changed yet');
      has(app.toasts(), '3 cell(s) saved.');
    });
    const revoke = app.$$('[data-act="bp-revoke"]').filter(function (b) { return b.getAttribute('data-id') === 'role:3'; })[0];
    app.click(revoke);
    it('Revoke all arms, naming the column', function () {
      eq(app.requests('bossPermsRevokeAll').length, 0);
      has(app.text(revoke), 'Click again: revoke every power from Boss');
    });
    app.click(revoke);
    await settled();
    it('and revokes that column', function () { eq(app.last('bossPermsRevokeAll').data, { subject: 'role', id: 3 }); });
    pick(app, 'bp-add', 'm2_2222');
    await settled();
    it('an individual boss can be added as a column', function () {
      truthy(cell('member:m2_2222', 'M1'), 'their column');
    });
    pick(app, 'bp-copy:member:m2_2222', 'role:3');
    await settled();
    it('and filled by copying another column', function () {
      has(app.text(cell('member:m2_2222', 'M1')), 'Allow');
      truthy(cell('member:m2_2222', 'M1').classList.contains('is-pending'));
    });
    app.click(app.button('Discard'));

    app.nav('bplimits');
    await settled();
    const limitInput = function (k) { return app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === 'bp.lim.' + k; })[0]; };
    app.type(limitInput('WithdrawMax'), '20000000');
    app.click(app.$$('[data-act="bp-limit"]').filter(function (b) { return b.getAttribute('data-id') === 'WithdrawMax'; })[0]);
    it('a limit outside its range is refused before it is sent', function () {
      eq(app.requests('bossLimits').length, 0);
      has(app.main(), 'WithdrawMax is from 0 to 10000000.');
    });
    app.type(limitInput('WithdrawMax'), '2500');
    const lim = app.$$('[data-act="bp-limit"]').filter(function (b) { return b.getAttribute('data-id') === 'WithdrawMax'; })[0];
    app.click(lim);
    it('a limit arms with the value and the one now', function () { has(app.text(lim), 'Click again: WithdrawMax to 2,500 (now 5,000)'); });
    app.click(lim);
    await settled();
    it('and sends that one limit', function () { eq(app.last('bossLimits').data, { limits: { WithdrawMax: 2500 } }); });

    app.nav('bpoffice');
    await settled();
    const office = app.$$('[data-act="bp-office"]').filter(function (b) { return b.getAttribute('data-power') === 'C7'; })[0];
    app.click(office);
    app.click(office);
    await settled();
    it('the office requirement toggles a power, on two clicks', function () {
      eq(app.last('bossOfficeRule').data, { power: 'C7', on: false });
    });
    app.nav('logs:grants');
    await settled();
    it('Grant history reads the grants, escaped', function () {
      eq(app.last('logs.org').data, { area: 'org', limit: 100, action: 'org_grant' });
      eq(app.$$('img').length, 0);
    });
    const undo = app.button('Undo');
    app.click(undo);
    it('Undo arms, naming the power and the value it puts back', function () { has(app.text(undo), 'Click again: Hire back to off'); });
    app.click(undo);
    await settled();
    it('and sets that one role cell back', function () {
      eq(app.last('bossPermsSet').data, { cells: [{ subject: 'role', id: 3, power: 'M2', state: 'off' }] });
    });
    clean(app, 'boss permissions');
  })();

  /* ---- Locations ---- */
  await (async function () {
    const server = orgServer();
    const app = boot(server);
    app.open(FULL);
    await settled();
    app.nav('locations');
    await settled();
    const found = [];
    markupFrom(app, 'locations', found);
    it('Locations lists every kind of place, the organisation\'s and the settings\', escaped', function () {
      eq(found, []);
      has(app.main(), 'Boss office');
      has(app.main(), 'Back room ' + XSS);
      has(app.main(), '10.5, -20.2, 30, 90');
      has(app.main(), 'Sign-up spots');
      has(app.main(), 'None set here.');
      truthy(app.byId('st-row-Intel.Rumours.Locations'), 'the broker\\\'s places');
      truthy(app.byId('st-row-Limits.JailZone.x'), 'and the prison zone');
    });
    const kind = function (act, k) {
      return app.$$('[data-act="' + act + '"]').filter(function (b) { return b.getAttribute('data-value') === k; })[0];
    };
    app.click(kind('loc-mypos', 'signup'));
    await settled();
    const bind = function (b) { return app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === b; })[0]; };
    it('Use my position asks the server where you stand, and fills the row', function () {
      eq(app.last('placeMyPosition').op, 'placeMyPosition');
      eq(bind('loc.signup.x').value, '123.5');
      eq(bind('loc.signup.y').value, '-654.3');
      eq(bind('loc.signup.h').value, '183');
      has(app.main(), 'Your position: x 123.5');
    });
    app.click(kind('loc-save', 'signup'));
    it('a spot with no name is refused before it is sent', function () {
      has(app.main(), 'Give the place a name.');
      eq(app.requests('placeSet').length, 0);
    });
    app.type(bind('loc.signup.label'), 'Pier board');
    const save = kind('loc-save', 'signup');
    app.click(save);
    it('Save arms, naming the place and where', function () { has(app.text(save), 'Click again: save Pier board at 123.5, -654.3'); });
    app.click(save);
    await settled();
    it('and sends the typed figures', function () {
      eq(app.last('placeSet').data, { kind: 'signup', label: 'Pier board', blip: false, enabled: true,
        x: 123.5, y: -654.3, z: 30, heading: 183 });
    });
    app.type(bind('loc.meeting.label'), 'Docks');
    const here = kind('loc-here', 'meeting');
    app.click(here);
    app.click(here);
    await settled();
    it('Save where I stand lets the server read the position itself', function () {
      eq(app.last('placeSet').data, { kind: 'meeting', label: 'Docks', blip: false, enabled: true, here: true });
    });
    const remove = app.$$('[data-act="loc-remove"]')[0];
    app.click(remove);
    it('Remove arms, naming the place', function () { has(app.text(remove), 'Click again: remove Back room ' + XSS); });
    app.click(remove);
    await settled();
    it('and removes it by its id', function () { eq(app.last('placeRemove').data, { id: 'hitman:office:1' }); });
    app.click(app.button('Use my position for a new line'));
    await settled();
    it('a list of places gets a line from where you stand, to add and save as any line', function () {
      eq(bind('stl.Intel.Rumours.Locations').value, '123.5, -654.3, 30, 183');
    });
    app.click(app.button('Use my position for the centre'));
    await settled();
    it('and the prison zone its centre', function () {
      eq(bind('st.Limits.JailZone.x').value, '123.5');
      eq(bind('st.Limits.JailZone.y').value, '-654.3');
    });
    clean(app, 'locations');
  })();

  /* ---- Locations is drawn from the kinds the server sends (placeList), and the settings it marks ---- */
  await (async function () {
    const view = placesView();
    view.data.kinds.push({ id: 'stash', group: 'org', label: 'Stash ' + XSS, one: 'stash', icon: 'box',
      fields: { label: true }, labelMax: 20, rows: [] });
    const settings = orgSettings(true);
    settings.data.limits.push({ key: 'Roleplay.WitnessHeat.Areas', place: 'area', category: 'rules-limits',
      group: 'Roleplay: Witness heat', area: 'extras', label: 'Areas, as Name@x,y', kind: 'list', whole: true,
      live: true, value: [], default: [], source: 'config' });
    const app = boot(orgServer({ placeList: view, settings: settings }));
    app.open(FULL);
    await settled();
    app.nav('locations');
    await settled();
    const found = [];
    markupFrom(app, 'locations', found);
    it('KINDS: a kind the server adds is drawn with its own fields, escaped', function () {
      eq(found, []);
      has(app.main(), 'Stash ' + XSS);
      truthy(app.$('[data-bind="loc.stash.label"]'), 'its name field');
      falsy(app.$('[data-bind="loc.stash.r"]'), 'no radius it does not take');
      eq(app.requests('placeList').length, 1, 'one read for every kind');
      eq(app.requests('orgGet').length, 0, 'not the organisation\'s');
    });
    it('KINDS: a setting the server marks as a place is edited here, with Use my position', function () {
      truthy(app.byId('st-row-Roleplay.WitnessHeat.Areas'));
    });
    const bind = function (b) { return app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === b; })[0]; };
    app.click(app.$$('[data-act="loc-fill"]').filter(function (b) {
      return b.getAttribute('data-key') === 'Roleplay.WitnessHeat.Areas';
    })[0]);
    await settled();
    it('KINDS: and its line is filled in the form its kind takes', function () {
      eq(bind('stl.Roleplay.WitnessHeat.Areas').value, 'New area@123.5,-654.3');
    });
    clean(app, 'locations kinds');
  })();

  /* ---- Work & channel: the organisation extras ---- */
  await (async function () {
    const extras = { OrgContracts: true, AcceptApproval: true, Probation: true, Duty: true, Channel: true,
      Dossiers: true,
      work: {
        contracts: [{ id: 'ct00000031', state: 'waiting', targetName: 'Dana ' + XSS, worth: 5000, expiresIn: 600 },
          { id: 'ct00000032', state: 'assigned', targetName: 'Sam Hale', worth: 7000, expiresIn: 300,
            member: { ref: 'm2_2222', name: XSS } }],
        approvals: [{ id: 'ap1_1111', contractId: 'ct00000033', worth: 40000, expiresIn: 300,
          member: { ref: 'm2_2222', name: XSS } }],
        spots: [{ id: 'hitman:meeting:1', label: 'Pier' }] },
      channel: [{ id: 'msg:1', from: XSS, body: 'Hello ' + XSS, at: NOW - 60, member: 'm2_2222' }] };
    const off = boot(orgServer());
    off.open(FULL);
    await settled();
    off.nav('orgwork');
    await settled();
    it('WORK: says every extra is off while orgGet carries none', function () {
      has(off.main(), 'Every extra is switched off');
    });
    const members = orgOn().data.members.map(function (m) { return Object.assign({}, m); });
    members[1].probation = { done: 1, need: 3 };
    members[0].onDuty = true;
    const app = boot(orgServer({ orgGet: orgOn({ extras: extras, members: members }) }));
    app.open(FULL);
    await settled();
    app.nav('orgwork');
    await settled();
    it('WORK: draws each extra, every name and word escaped', function () {
      has(app.main(), 'Accepts waiting for approval');
      has(app.main(), 'Contracts sent to the organisation');
      has(app.main(), 'On probation');
      has(app.main(), 'On duty');
      has(app.main(), 'The channel');
      has(app.main(), 'Hello ' + XSS);
      eq(app.$$('img').length, 0);
    });
    const byAct = function (act, attr, value) {
      return app.$$('[data-act="' + act + '"]').filter(function (b) {
        return !attr || b.getAttribute(attr) === value;
      })[0];
    };
    app.click(byAct('org-work-approve', 'data-value', 'yes'));
    const afterOne = app.requests('orgAcceptDecide').length;
    app.click(byAct('org-work-approve', 'data-value', 'yes'));
    await settled();
    it('WORK: Approve takes two clicks and sends the id', function () {
      eq(afterOne, 0);
      eq(app.last('orgAcceptDecide').data, { id: 'ap1_1111', approve: true });
    });
    app.click(byAct('org-work-assign', 'data-id', 'ct00000031'));
    it('WORK: Assign with no member picked says so and sends nothing', function () {
      eq(app.requests('orgContractAssign').length, 0);
      has(app.main(), 'Pick the member first.');
    });
    app.click(byAct('dd-open', 'data-dd', 'org-work-member:ct00000031'));
    app.click(app.$$('[data-act="dd-pick"]').filter(function (b) {
      return b.getAttribute('data-dd') === 'org-work-member:ct00000031' && b.getAttribute('data-value') === 'm1_1111';
    })[0]);
    app.click(byAct('org-work-assign', 'data-id', 'ct00000031'));
    app.click(byAct('org-work-assign', 'data-id', 'ct00000031'));
    await settled();
    it('WORK: and assigns by the member\'s handle on two clicks', function () {
      eq(app.last('orgContractAssign').data, { id: 'ct00000031', member: 'm1_1111' });
    });
    app.click(byAct('org-work-release', 'data-id', 'ct00000032'));
    app.click(byAct('org-work-release', 'data-id', 'ct00000032'));
    await settled();
    it('WORK: Send to the open board on two clicks', function () {
      eq(app.last('orgContractAssign').data, { id: 'ct00000032', release: true });
    });
    const bind = function (b) {
      return app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === b; })[0];
    };
    app.type(bind('org.dossier.ct00000032'), 'Quietly');
    app.click(app.$$('[data-act="org-work-rules"]').filter(function (b) {
      return b.getAttribute('data-id') === 'ct00000032' && b.getAttribute('data-value') === 'clean';
    })[0]);
    app.click(byAct('org-work-dossier'));
    app.click(byAct('org-work-dossier'));
    await settled();
    it('WORK: a dossier sends its notes and rules on two clicks', function () {
      eq(app.last('orgDossier').data, { id: 'ct00000032', notes: 'Quietly', rules: 'clean' });
    });
    app.click(byAct('org-probation', 'data-value', 'yes'));
    app.click(byAct('org-probation', 'data-value', 'yes'));
    await settled();
    app.click(byAct('org-duty-off'));
    app.click(byAct('org-duty-off'));
    await settled();
    it('WORK: End probation and Send off duty name the member\'s handle', function () {
      eq(app.last('orgProbation').data, { member: 'm2_2222', passed: true });
      eq(app.last('orgDutyOff').data, { member: 'm1_1111' });
    });
    app.type(bind('org.channel'), 'Staff here');
    app.click(byAct('org-chan-post'));
    app.click(byAct('org-chan-post'));
    await settled();
    app.click(byAct('org-chan-mute'));
    app.click(byAct('org-chan-mute'));
    await settled();
    app.click(byAct('org-chan-remove'));
    app.click(byAct('org-chan-remove'));
    await settled();
    it('WORK: the channel posts, mutes and takes a message down, each on two clicks', function () {
      eq(app.last('orgChannelPost').data, { text: 'Staff here' });
      eq(app.last('orgChannelMute').data, { member: 'm2_2222', hours: 24 });
      eq(app.last('orgChannelRemove').data, { id: 'msg:1' });
    });
  })();

  /* ---- Reputation, drops & garage: the organisation extras 3 ---- */
  await (async function () {
    const off = boot(orgServer());
    off.open(FULL);
    await settled();
    off.nav('orgturf');
    await settled();
    it('EXTRAS 3: the view says it is off while orgGet carries none', function () {
      has(off.main(), 'Reputation, dead drops and the garage is switched off');
    });
    const extras3 = { Reputation: true, DeadDrops: true, Territory: true, Garage: true, InternalContracts: true,
      Handler: true, ActivityLog: true,
      reputation: { points: 120, earned: 130, heat: 10, completed: 13, failed: 0, tier: { label: 'Known ' + XSS,
        points: 100, max: 75000 }, next: { label: 'Trusted', points: 300 }, tiers: [{ points: 0, label: 'Unknown',
        max: 25000 }, { points: 100, label: 'Known ' + XSS, max: 75000 }] },
      deadDrops: { method: 'bank', spot: true, unclaimed: 'pay', rows: [{ key: 'ct1:HIT', name: XSS, at: NOW - 60,
        expires: NOW + 600 }] },
      territory: { zones: 2 },
      garage: { ready: true, hasSpot: true, max: 3, all: [{ model: 'sultan', offered: true }, { model: 'baller' }],
        out: [{ name: XSS, model: 'sultan', at: NOW - 120, ref: 'm1_1111' }] },
      internal: [{ id: 'ic1_1', name: XSS, by: 'Kai', reason: 'Sold us out ' + XSS, amount: 2000, state: 'pending',
        at: NOW - 30 }],
      activity: [{ at: NOW - 10, what: 'Contract accepted', by: XSS, action: 'accepted' }] };
    const app = boot(orgServer({ orgGet: orgOn({ extras3: extras3 }), orgRepAdjust: { ok: true, message: 'Adjusted.' },
      orgPayoutMethod: { ok: true, message: 'Set.' }, orgDropSettle: { ok: true, message: 'Settled.' },
      orgGarageOffer: { ok: true, message: 'Saved.' }, orgGarageRemove: { ok: true, message: 'Taken away.' },
      orgInternalDecide: { ok: true, message: 'Placed.' } }));
    app.open(FULL);
    await settled();
    app.nav('orgturf');
    await settled();
    const text = app.main();
    const found = [];
    markupFrom(app, 'org turf', found);
    const byAct = function (act, attr, value) {
      return app.$$('[data-act="' + act + '"]').filter(function (b) {
        return !attr || b.getAttribute(attr) === value;
      })[0];
    };
    const bind = function (b) {
      return app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === b; })[0];
    };
    app.type(bind('org.rep.points'), '-15');
    app.type(bind('org.rep.reason'), 'Sloppy work');
    app.click(byAct('org-rep-adjust'));
    const repAfterOne = app.requests('orgRepAdjust').length;
    app.click(byAct('org-rep-adjust'));
    await settled();
    const rep = app.last('orgRepAdjust');
    app.click(byAct('org-pay-method'));
    app.click(byAct('org-pay-method'));
    await settled();
    const method = app.last('orgPayoutMethod');
    app.click(byAct('org-drop-settle', 'data-value', 'refund'));
    app.click(byAct('org-drop-settle', 'data-value', 'refund'));
    await settled();
    const settled1 = app.last('orgDropSettle');
    app.click(byAct('org-garage-toggle', 'data-value', 'baller'));
    app.click(byAct('org-garage-offer'));
    app.click(byAct('org-garage-offer'));
    await settled();
    const offer = app.last('orgGarageOffer');
    app.click(byAct('org-garage-remove', 'data-ref', 'm1_1111'));
    app.click(byAct('org-garage-remove', 'data-ref', 'm1_1111'));
    await settled();
    const removed = app.last('orgGarageRemove');
    app.click(byAct('org-internal', 'data-value', 'yes'));
    const icAfterOne = app.requests('orgInternalDecide').length;
    app.click(byAct('org-internal', 'data-value', 'yes'));
    await settled();
    it('workflow screen:admin.view:orgturf — reputation, a drop, the garage and an internal contract, two clicks each', function () {
      eq(found, []);
      has(text, 'Known ' + XSS);
      has(text, 'Sold us out ' + XSS);
      has(text, '2 zone(s)');
      eq(app.$$('img').length, 0);
      eq(repAfterOne, 0);
      eq(rep.data, { points: -15, reason: 'Sloppy work' });
      eq(method.data, { method: 'deaddrop' });
      eq(settled1.data, { key: 'ct1:HIT', how: 'refund' });
      eq(offer.data, { models: ['sultan', 'baller'] });
      eq(removed.data, { member: 'm1_1111' });
      eq(icAfterOne, 0);
      eq(app.last('orgInternalDecide').data, { id: 'ic1_1', approve: true });
    });
  })();

  /* ---- Armory, Record & discipline, the form: the organisation extras 2 ---- */
  await (async function () {
    const off = boot(orgServer());
    off.open(FULL);
    await settled();
    off.nav('orgarmory');
    await settled();
    const armOff = off.main();
    off.nav('orgrecord');
    await settled();
    it('EXTRAS 2: the armory and the record say they are off while orgGet carries none', function () {
      has(armOff, 'The armory is switched off');
      has(off.main(), 'The record and discipline is switched off');
    });
    const extras2 = { Armory: true, Stats: true, Discipline: true, Recruitment: true,
      armory: { items: [{ slot: 2, name: 'lockpick', label: 'Lock ' + XSS, count: 4 }], allowed: ['lockpick'],
        limits: { '0': 1 }, withdrawMax: 10, log: [{ at: NOW - 60, dir: 'out', item: 'lockpick', count: 1, who: XSS }] },
      leaderboard: [{ rank: 1, name: XSS, ref: 'm1_1111', completed: 3, failed: 1, earned: 9000, rate: 75,
        avgMinutes: 42, band: '30 min to 2 h' }],
      discipline: [{ ref: 'm2_2222', name: XSS, strikes: 1, rows: [{ id: 'dc1_1', kind: 'strike', reason: 'Late ' + XSS,
        at: NOW - 60, active: true, by: 'A boss' }] }],
      disciplineRules: { decayDays: 30, suspendAt: 3, suspendHours: 48, demoteAt: 0 },
      form: ['Why us?'], formMax: 2 };
    const apps = [{ id: 'app:1', name: 'Ada', body: 'Hi', at: NOW - 60,
      form: [{ q: 'Why us?', a: 'Pay ' + XSS }], note: { text: 'Calm', by: 'Staff' } }];
    const app = boot(orgServer({ orgGet: orgOn({ extras2: extras2, applications: apps }) }));
    app.open(FULL);
    await settled();
    app.nav('orgarmory');
    await settled();
    const armText = app.main();
    const byAct = function (act, attr, value) {
      return app.$$('[data-act="' + act + '"]').filter(function (b) {
        return !attr || b.getAttribute(attr) === value;
      })[0];
    };
    const bind = function (b) {
      return app.$$('input').filter(function (i) { return i.getAttribute('data-bind') === b; })[0];
    };
    app.type(bind('org.arm.out.2'), '3');
    app.click(byAct('org-arm-remove', 'data-id', '2'));
    const removeAfterOne = app.requests('orgArmoryStock').length;
    app.click(byAct('org-arm-remove', 'data-id', '2'));
    await settled();
    const removed = app.last('orgArmoryStock');
    app.type(bind('org.arm.item'), 'lockpick');
    app.type(bind('org.arm.count'), '5');
    app.click(byAct('org-arm-stock'));
    app.click(byAct('org-arm-stock'));
    await settled();
    const stocked = app.last('orgArmoryStock');
    app.type(bind('org.arm.lim.1'), '2');
    app.click(byAct('org-arm-limit', 'data-id', '1'));
    app.click(byAct('org-arm-limit', 'data-id', '1'));
    await settled();
    it('workflow screen:admin.view:orgarmory — the armory removes, stocks and sets a limit on two clicks', function () {
      has(armText, 'Lock ' + XSS);
      has(armText, 'Allowed: lockpick');
      eq(app.$$('img').length, 0);
      eq(removeAfterOne, 0);
      eq(removed.data, { remove: true, slot: 2, count: 3 });
      eq(stocked.data, { item: 'lockpick', count: 5 });
      eq(app.last('orgArmoryLimit').data, { grade: 1, count: 2 });
    });
    app.nav('orgrecord');
    await settled();
    const recText = app.main();
    app.click(byAct('org-stats-reset', 'data-ref', 'm1_1111'));
    app.click(byAct('org-stats-reset', 'data-ref', 'm1_1111'));
    await settled();
    const reset = app.last('orgStatsReset');
    app.click(byAct('org-disc-give'));
    const giveRefused = app.requests('orgStrike').length;
    app.click(byAct('dd-open', 'data-dd', 'org-x2-member'));
    app.click(app.$$('[data-act="dd-pick"]').filter(function (b) {
      return b.getAttribute('data-dd') === 'org-x2-member' && b.getAttribute('data-value') === 'm1_1111';
    })[0]);
    app.click(byAct('org-x2-kind', 'data-value', 'warning'));
    app.type(bind('org.disc.reason'), 'Loud');
    app.click(byAct('org-disc-give'));
    app.click(byAct('org-disc-give'));
    await settled();
    const gave = app.last('orgStrike');
    app.type(bind('org.over.dc1_1'), 'Wrong member');
    app.click(byAct('org-disc-over', 'data-id', 'dc1_1'));
    app.click(byAct('org-disc-over', 'data-id', 'dc1_1'));
    await settled();
    it('workflow screen:admin.view:orgrecord — the record resets, a warning is given and a strike overturned', function () {
      has(recText, '42 min (30 min to 2 h)');
      has(recText, 'Late ' + XSS);
      eq(app.$$('img').length, 0);
      eq(reset.data, { member: 'm1_1111' });
      eq(giveRefused, 0, 'nothing without a member and a reason');
      eq(gave.data, { member: 'm1_1111', kind: 'warning', reason: 'Loud' });
      eq(app.last('orgOverturn').data, { member: 'm2_2222', id: 'dc1_1', reason: 'Wrong member' });
    });
    app.nav('orgapps');
    await settled();
    const appText = app.main();
    app.type(bind('org.form.q1'), 'Who vouches?');
    app.click(byAct('org-form-save'));
    app.click(byAct('org-form-save'));
    await settled();
    const saved = app.last('orgRecruitForm');
    app.type(bind('org.note.app:1'), 'Knows the docks');
    app.click(byAct('org-note-save', 'data-id', 'app:1'));
    app.click(byAct('org-note-save', 'data-id', 'app:1'));
    await settled();
    it('EXTRAS 2: Applications shows the answers and the note, and saves the form and a note on two clicks', function () {
      has(appText, 'Pay ' + XSS);
      has(appText, 'Interview note (Staff): Calm');
      eq(saved.data, { questions: ['Why us?', 'Who vouches?'] });
      eq(app.last('orgInterviewNote').data, { id: 'app:1', text: 'Knows the docks' });
    });
  })();

  /* ---- read-only staff: every new write is disabled, and sends nothing ---- */
  await (async function () {
    const server = orgServer();
    const app = boot(server);
    app.open(READER);
    await settled();
    const writes = [];
    for (const view of ['orgsetup', 'orgroles', 'orgmembers', 'orgfunds', 'orgaccess', 'orgnotices', 'orgwork',
      'orgarmory', 'orgrecord', 'orgturf', 'bpmatrix', 'bplimits', 'bpoffice', 'locations']) {
      app.nav(view);
      await settled();
      app.$$('[data-gate]').forEach(function (b) {
        writes.push(view + ':' + b.getAttribute('data-act') + ':' + (b.disabled ? 'off' : 'ON'));
      });
    }
    it('a reader sees every organisation, Boss permissions and Locations write disabled', function () {
      truthy(writes.length > 20, writes.length + ' writes drawn');
      eq(writes.filter(function (w) { return /:ON$/.test(w); }), []);
      eq(app.$$('[data-act="bp-cell"]').filter(function (b) { return !b.disabled; }).length, 0);
    });
    clean(app, 'org read only');
  })();

  /* ---- the contract drawer: Change reward (rewardPreview, rewardChange) ---- */

  function staffTools() {
    return { notes: [], removals: [], edits: [], noteMax: 300, removable: true,
      text: { editable: false, mode: 'freetext', max: 120, edited: false } };
  }
  function rewardServer(extra) {
    return standardServer(Object.assign({
      contract: contractDetail({ staff: staffTools() }),
      rewardPreview: function (data) {
        const base = { max: 100000, slot: 2, reward: 8000, total: 8000, mostLower: 7999, staffAdded: 1000 };
        if (data.by === undefined) return { ok: true, data: base };
        const out = Object.assign({}, base, { after: 8000 + data.by });
        if (data.by < 0) { out.toStaff = Math.min(1000, -data.by); out.toPlacer = -data.by - out.toStaff; }
        return { ok: true, data: out };
      },
      rewardChange: { ok: true, message: 'Reward raised from $8000 to $9500, added by staff.' },
      reassignPreview: { ok: true, data: { stakeWaived: true, stake: 2500, operatives: ['Ghost'] } },
      reassignHitman: { ok: true, message: 'Reassigned to Operative #2; 1 operative(s) taken off it.' }
    }, extra || {}));
  }
  async function openDrawer(app) {
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
  }
  function inDrawer(app, bindName) { return app.drawer().querySelector('[data-bind="' + bindName + '"]'); }

  await (async function () {
    const app = boot(rewardServer());
    app.open(ADMIN);
    await settled();
    await openDrawer(app);
    it('RW: no reward figures are asked before the Money tab opens', function () {
      eq(app.requests('rewardPreview').length, 0);
    });
    app.tab('money');
    await settled();
    it('RW: the Money tab reads the reward as it is, and shows its figures', function () {
      eq(app.requests('rewardPreview').length, 1);
      eq(app.last('rewardPreview').data, { id: 'ct00000001' });
      const text = app.text(app.drawer());
      has(text, 'Change reward');
      has(text, 'Its reward');
      has(text, '$8,000');
      has(text, 'Added by staff');
      has(text, '$1,000');
      has(text, '$100,000');
    });
    app.type(inDrawer(app, 'dr.rw.amt.ct00000001'), '1500');
    app.fire(250);
    await settled();
    it('RW: typing an amount asks what it would do, and draws the server\'s figures', function () {
      eq(app.last('rewardPreview').data, { id: 'ct00000001', by: 1500 });
      const box = app.byId('dr-rw-preview');
      has(app.text(box), '$8,000');
      has(app.text(box), '$9,500');
      has(app.text(box), 'added by staff (bank)');
    });
    const change = app.button('Change reward', app.drawer());
    app.click(change);
    await settled();
    it('RW: no reason, nothing sent and nothing armed', function () {
      eq(app.requests('rewardChange').length, 0);
      has(app.text(app.drawer().querySelector('.answer')), 'Give a reason');
    });
    app.type(inDrawer(app, 'dr.rw.reason.ct00000001'), 'ticket 7');
    const armedChange = app.button('Change reward', app.drawer());
    app.click(armedChange);
    await settled();
    it('RW: the first click arms, naming the figures before and after and who pays', function () {
      eq(app.requests('rewardChange').length, 0);
      has(app.text(armedChange), 'Click again: raise it from $8,000 to $9,500, added by staff (bank)');
    });
    app.click(armedChange);
    await settled();
    it('RW: the second sends the signed amount, who pays, the account and the reason', function () {
      eq(app.last('rewardChange').data, { id: 'ct00000001', by: 1500, reason: 'ticket 7', from: 'staff', account: 'bank' });
      has(app.text(app.drawer().querySelector('.answer')), 'Reward raised from $8000 to $9500');
    });

    // Charged to the placer, from cash.
    app.click(app.button('Charged to the placer', app.drawer()));
    app.click(app.button('Cash', app.drawer()));
    app.type(inDrawer(app, 'dr.rw.amt.ct00000001'), '2000');
    app.type(inDrawer(app, 'dr.rw.reason.ct00000001'), 'their idea');
    app.fire(250);
    await settled();
    const placer = app.button('Change reward', app.drawer());
    app.click(placer);
    it('RW: a raise charged to the placer says so on the armed button', function () {
      has(app.text(placer), 'Click again: raise it from $8,000 to $10,000, charged to the placer\'s cash');
    });
    app.click(placer);
    await settled();
    it('RW: and sends from placer and cash', function () {
      eq(app.last('rewardChange').data, { id: 'ct00000001', by: 2000, reason: 'their idea', from: 'placer', account: 'cash' });
    });

    // Lowering.
    app.click(app.button('Lower', app.drawer()));
    await settled();
    app.type(inDrawer(app, 'dr.rw.amt.ct00000001'), '1500');
    app.type(inDrawer(app, 'dr.rw.reason.ct00000001'), 'too high');
    app.fire(250);
    await settled();
    it('RW: a lowering previews what comes off staff\'s lines and what goes back to the placer', function () {
      eq(app.last('rewardPreview').data, { id: 'ct00000001', by: -1500 });
      const box = app.text(app.byId('dr-rw-preview'));
      has(box, '$6,500');
      has(box, '$1,000 of what staff added comes off');
      has(box, '$500 goes back to the placer');
      lacks(app.text(app.drawer()), 'Charged to the placer', 'no payer for a lowering');
    });
    const lower = app.button('Change reward', app.drawer());
    app.click(lower);
    app.click(lower);
    await settled();
    it('RW: and sends a negative amount with no payer or account', function () {
      has(app.text(lower), 'Change reward');
      eq(app.last('rewardChange').data, { id: 'ct00000001', by: -1500, reason: 'too high' });
    });

    // Clicked before the figures arrived: they are read first, nothing armed.
    const asked = app.requests('rewardPreview').length;
    app.type(inDrawer(app, 'dr.rw.amt.ct00000001'), '700');
    app.type(inDrawer(app, 'dr.rw.reason.ct00000001'), 'r');
    const early = app.button('Change reward', app.drawer());
    const sentBefore = app.requests('rewardChange').length;
    app.click(early);
    await settled();
    it('RW: a click before the figures for that amount reads them first, arming nothing', function () {
      eq(app.requests('rewardPreview').length, asked + 1);
      eq(app.last('rewardPreview').data, { id: 'ct00000001', by: -700 });
      eq(app.requests('rewardChange').length, sentBefore);
      falsy(app.drawer().querySelector('.is-armed'), 'nothing armed');
    });
    clean(app, 'change reward');
  })();

  await (async function () {
    const app = boot(rewardServer({
      rewardPreview: function (data) {
        if (data.by === undefined) return { ok: true, data: { max: 1000, slot: 1, reward: 5000, mostLower: 4999, staffAdded: 0 } };
        return { ok: true, data: { max: 1000, slot: 1, reward: 5000, after: 5000 + data.by,
          refused: 'claim_running', message: 'A payout on it is being settled right now. Try again in a moment.' } };
      }
    }));
    app.open(ADMIN);
    await settled();
    await openDrawer(app);
    app.tab('money');
    await settled();
    app.type(inDrawer(app, 'dr.rw.amt.ct00000001'), '5000');
    app.type(inDrawer(app, 'dr.rw.reason.ct00000001'), 'x');
    app.click(app.button('Change reward', app.drawer()));
    await settled();
    it('RW: over the most one change moves is refused before anything is asked', function () {
      eq(app.requests('rewardChange').length, 0);
      has(app.text(app.drawer().querySelector('.answer')), 'At most $1,000 at once');
    });
    app.type(inDrawer(app, 'dr.rw.amt.ct00000001'), '500');
    app.fire(250);
    await settled();
    app.click(app.button('Change reward', app.drawer()));
    await settled();
    it('RW: a refusal in the figures is said, and the button never arms', function () {
      has(app.text(app.byId('dr-rw-preview')), 'being settled right now');
      has(app.text(app.drawer().querySelector('.answer')), 'being settled right now');
      eq(app.requests('rewardChange').length, 0);
      falsy(app.drawer().querySelector('.is-armed'));
    });
    clean(app, 'change reward refused');
  })();

  await (async function () {
    const app = boot(rewardServer());
    app.open(READER);
    await settled();
    await openDrawer(app);
    app.tab('money');
    await settled();
    it('RW: a reader sees the figures and a disabled Change reward', function () {
      has(app.text(app.drawer()), '$8,000');
      truthy(app.button('Change reward', app.drawer()).disabled, 'disabled without the staff ACE');
    });
    app.tab('people');
    await settled();
    it('RA: and a disabled Reassign once a hitman is looked up (or the way to look one up)', function () {
      has(app.text(app.drawer()), 'Reassign to another hitman');
    });
    clean(app, 'reader drawer');
  })();

  /* ---- the contract drawer: Reassign (reassignPreview, reassignHitman) ---- */
  await (async function () {
    const app = boot(rewardServer());
    app.open(ADMIN);
    await settled();
    await openDrawer(app);
    app.tab('people');
    await settled();
    it('RA: with nobody looked up, the card says to look the hitman up first, and asks nothing', function () {
      has(app.text(app.drawer()), 'Look the hitman up in Players first');
      truthy(app.button('Find the hitman in Players', app.drawer()));
      eq(app.requests('reassignPreview').length, 0);
    });
    app.click(app.button('Find the hitman in Players', app.drawer()));
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    app.tab('people');
    await settled();
    it('RA: with a player looked up, it checks them by the lookup\'s handle and says who comes off', function () {
      eq(app.last('reassignPreview').data, { id: 'ct00000001', ref: 'p7_424242' });
      const text = app.text(app.drawer());
      has(text, 'Dana Reyes');
      has(text, 'Taken off it: Ghost');
      has(text, 'Their stake is waived');
    });
    app.click(app.button('Reassign', app.drawer()));
    await settled();
    it('RA: no reason, nothing sent', function () {
      eq(app.requests('reassignHitman').length, 0);
      has(app.text(app.drawer().querySelector('.answer')), 'Give a reason');
    });
    app.type(inDrawer(app, 'dr.ra.reason.ct00000001'), 'ticket 12');
    app.click(app.button('Return the stakes', app.drawer()));
    app.click(app.button('They may take it again', app.drawer()));
    const go = app.button('Reassign', app.drawer());
    app.click(go);
    await settled();
    it('RA: the first click arms, naming the hitman and how many come off', function () {
      eq(app.requests('reassignHitman').length, 0);
      has(app.text(go), 'Click again: give it to Dana Reyes, taking off 1 operative');
    });
    app.click(go);
    await settled();
    it('RA: the second sends the lookup handle, the reason, the bar and the stakes', function () {
      eq(app.last('reassignHitman').data, { id: 'ct00000001', ref: 'p7_424242', reason: 'ticket 12', block: false,
        returnStake: true, identity: 'anonymous' });
      has(app.text(app.drawer().querySelector('.answer')), 'Reassigned to Operative #2');
    });
    clean(app, 'reassign');
  })();

  await (async function () {
    const app = boot(rewardServer());
    app.open(ADMIN);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    await openDrawer(app);
    app.tab('people');
    await settled();
    it('RA (review-x F4): the new hitman goes on anonymously unless staff choose otherwise', function () {
      truthy(app.button('Anonymous (no fee)', app.drawer()));
      truthy(app.button('Named to the placer', app.drawer()));
      truthy(app.button('As they chose before', app.drawer()));
    });
    app.type(inDrawer(app, 'dr.ra.reason.ct00000001'), 'ticket 13');
    const go = app.button('Reassign', app.drawer());
    app.click(go);
    await settled();
    app.click(app.button('Named to the placer', app.drawer()));
    await settled();
    it('RA (review-x F4): choosing how they go on disarms the armed button', function () {
      eq(app.requests('reassignHitman').length, 0);
      falsy(app.drawer().querySelector('.is-armed'));
    });
    const again = app.button('Reassign', app.drawer());
    app.click(again);
    await settled();
    app.click(again);
    await settled();
    it('RA (review-x F4): and the choice is sent', function () {
      eq(app.last('reassignHitman').data.identity, 'named');
    });
    clean(app, 'reassign identity');
  })();

  /* ---- admin review F4: the reward's base read on a channel of its own ---- */
  await (async function () {
    let releaseBase = null;
    const app = boot(rewardServer({
      rewardPreview: function (data) {
        const base = { max: 100000, slot: 2, reward: 8000, total: 8000, mostLower: 7999, staffAdded: 1000 };
        if (data.by === undefined) {
          return new Promise(function (resolve) { releaseBase = function () { resolve({ ok: true, data: base }); }; });
        }
        return { ok: true, data: Object.assign({}, base, { after: 8000 + data.by }) };
      }
    }));
    app.open(ADMIN);
    await settled();
    await openDrawer(app);
    app.tab('money');
    await settled();
    app.type(inDrawer(app, 'dr.rw.amt.ct00000001'), '500');
    app.fire(250);
    await settled();
    truthy(releaseBase, 'the base was asked');
    releaseBase();
    await settled();
    it('admin review F4: an amount typed while the base read is in flight does not lose the base', function () {
      lacks(app.text(app.drawer()), 'Reading the reward');
      has(app.text(app.drawer()), '$100,000');
    });
    app.type(inDrawer(app, 'dr.rw.amt.ct00000001'), '200000');
    app.type(inDrawer(app, 'dr.rw.reason.ct00000001'), 'x');
    app.click(app.button('Change reward', app.drawer()));
    await settled();
    it('admin review F4: and the cap is checked on the page from it', function () {
      has(app.text(app.drawer().querySelector('.answer')), 'At most $100,000');
      eq(app.requests('rewardChange').length, 0);
    });
    clean(app, 'reward base channel');
  })();

  /* ---- admin review F2: a player's diagnosis is theirs, Health's its own ---- */
  await (async function () {
    const pending = [];
    const app = boot(standardServer({
      player: function (data) {
        const p = player();
        p.data.player = Object.assign({}, p.data.player, { ref: 'p' + data.subject, name: 'Player ' + data.subject,
          server: Number(data.subject) });
        return p;
      },
      diag: function (data) {
        if (data.ref === 'p11') {
          return new Promise(function (resolve) {
            pending.push(function () { resolve({ ok: true, data: { lines: ['identity: AS p11'] } }); });
          });
        }
        return { ok: true, data: { lines: ['identity: AS ' + String(data.ref || 'yourself')] } };
      }
    }));
    app.open(FULL);
    await settled();
    async function lookUp(id) {
      app.nav('players');
      await settled();
      app.type(app.byId('pl-q'), id);
      app.key(app.byId('pl-q'), 'Enter');
      await settled();
      app.nav('pdiag');
      await settled();
    }
    await lookUp('11');
    app.click(app.button('Run the diagnosis as them'));
    await settled();
    await lookUp('22');
    pending.forEach(function (fn) { fn(); });
    await settled();
    it('admin review F2: a late answer for an earlier player is not drawn under the one looked up now', function () {
      lacks(app.main(), 'AS p11');
    });
    app.click(app.button('Run the diagnosis as them'));
    await settled();
    app.message({ type: 'push', kind: 'diag', line: 'LATE line for p11', ref: 'p11' });
    app.message({ type: 'push', kind: 'diag', line: 'from Health', });
    app.message({ type: 'push', kind: 'diag', line: 'LATE line for p22', ref: 'p22' });
    await settled();
    it('admin review F2: pushes are drawn only under the player they were run for, Health\'s apart', function () {
      has(app.main(), 'AS p22');
      has(app.main(), 'LATE line for p22');
      lacks(app.main(), 'LATE line for p11');
      lacks(app.main(), 'from Health');
    });
    clean(app, 'player diagnosis');
  })();

  await (async function () {
    const app = boot(rewardServer({
      reassignPreview: { ok: true, data: { stakeWaived: false, stake: 2500, operatives: {},
        refused: 'self_target', message: 'That player is its target.' } }
    }));
    app.open(ADMIN);
    await settled();
    app.nav('players');
    await settled();
    app.type(app.byId('pl-q'), '12');
    app.key(app.byId('pl-q'), 'Enter');
    await settled();
    await openDrawer(app);
    app.tab('people');
    await settled();
    app.type(inDrawer(app, 'dr.ra.reason.ct00000001'), 'x');
    app.click(app.button('Reassign', app.drawer()));
    await settled();
    it('RA: a hitman the server would refuse is said so, the stake as charged, and nothing arms or is sent', function () {
      has(app.text(app.drawer()), 'That player is its target.');
      has(app.text(app.drawer()), 'They put up the $2,500 stake');
      has(app.text(app.drawer()), 'Nobody is on it now.');
      eq(app.requests('reassignHitman').length, 0);
      falsy(app.drawer().querySelector('.is-armed'));
    });
    clean(app, 'reassign refused');
  })();

  /* ---- Locations: the broker and informant placed from the panel (Config.Roleplay.NpcPlaces) ---- */
  await (async function () {
    const off = boot(standardServer({ orgGet: orgOff(), placeList: placesView({ org: false }) }));
    off.open(ADMIN);
    await settled();
    off.nav('locations');
    await settled();
    it('RPP: Locations lists the broker and informant, off as shipped, with the config defaults', function () {
      eq(off.requests('placeList').length, 1);
      const text = off.main();
      has(text, 'Broker and informant places');
      has(text, 'Turn on Roleplay.NpcPlaces (Switches)');
      has(text, 'Defaults (config): -1212.4, -1500.2, 4.4');
      eq(off.$$('[data-act="loc-here"]').filter(function (b) {
        return b.getAttribute('data-value') === 'broker';
      }).length, 0, 'nothing to place while off');
    });
    clean(off, 'npc places off');

    const placed = [{ id: 'rpplace-broker-1', label: 'Pier', x: 1.5, y: 2, z: 3, heading: 90, enabled: true }];
    const app = boot(standardServer({ orgGet: orgOff(),
      placeList: placesView({ org: false, npc: { enabled: true, rows: placed } }),
      placeSet: { ok: true, message: 'Place saved.' }, placeRemove: { ok: true, message: 'Place removed.' },
      placeReset: { ok: true, message: 'The config list applies again.' } }));
    app.open(ADMIN);
    await settled();
    app.nav('locations');
    await settled();
    it('RPP: on, each NPC shows the places set here and which list it stands at', function () {
      const text = app.main();
      has(text, 'standing at the places set here.');
      has(text, 'Pier');
      has(text, '1.5, 2, 3, 90');
    });
    const by = function (act, k) {
      return app.$$('[data-act="' + act + '"]').filter(function (b) { return b.getAttribute('data-value') === k; })[0];
    };
    const here = by('loc-here', 'informant');
    app.click(here);
    it('RPP: Save where I stand arms first, sending nothing', function () {
      eq(app.requests('placeSet').length, 0);
      has(app.text(here), 'Click again: save informant place where you stand');
    });
    app.click(here);
    await settled();
    it('RPP: and then sends only the kind and here: the server reads the position, a name may be left out', function () {
      eq(app.last('placeSet').data, { kind: 'informant', enabled: true, here: true });
    });
    const rm = by('loc-remove', 'broker');
    app.click(rm);
    app.click(rm);
    await settled();
    it('RPP: Remove takes two clicks and names the place', function () {
      eq(app.last('placeRemove').data, { id: 'rpplace-broker-1' });
    });
    const reset = by('loc-reset', 'broker');
    app.click(reset);
    app.click(reset);
    await settled();
    it('RPP: Reset to config takes two clicks', function () {
      eq(app.last('placeReset').data, { kind: 'broker' });
    });
    clean(app, 'npc places on');
  })();

  /* ---- body disposal: the steps on Contracts and Home, the spots in Locations ---- */
  function disposalServer(extra) {
    const server = standardServer(Object.assign({
      orgGet: orgOff(),
      disposalList: { ok: true, data: { enabled: true, limitSeconds: 1800, onTimeout: 'reduced',
        spots: { vehicle: { x: 1.5, y: 2, z: 3, h: 90 } },
        steps: [{ id: 'disposal:ct00000001:1', contract: 'ct00000001', slot: 1, hitman: 'HITMAN01', stage: 'body',
          secondsLeft: 1510, held: true, vehicle: true, respawns: 1, spent: 290 }] } },
      disposalSkip: { ok: true, message: 'Finished: the payout is being handed over.' },
      disposalRespawn: { ok: true, message: 'The vehicle is back at the spawn spot.' },
      placeList: placesView({ org: false, disposal: { vehicle: [{ id: 'place:disposal_vehicle:1', kind: 'disposal_vehicle',
        label: 'Disposal vehicle spawn', x: 1.5, y: 2, z: 3, heading: 90, enabled: true }] } }),
      placeMyPosition: { ok: true, data: { x: 321.04, y: 654, z: 31, heading: 182 } },
      placeSet: { ok: true, message: 'Place saved.' },
      placeRemove: { ok: true, message: 'Place removed.' }
    }, extra || {}));
    return server;
  }

  await (async function () {
    const app = boot(disposalServer());
    app.open(ADMIN);
    await settled();
    app.nav('contracts');
    await settled();
    it('DP: Contracts lists every body being disposed of, with the exact time left and its clock', function () {
      eq(app.requests('disposalList').length, 1);
      const text = app.main();
      has(text, 'Body disposal in progress (1)');
      has(text, 'Body not loaded yet');
      has(text, '25 min 10 s');
      has(text, 'clock held');
      has(text, '1 respawn');
      has(text, 'paid in part, the rest back to the placer');
      lacks(text, 'HITMAN01', 'no hitman without the identity ACE');
    });
    const skip = app.button('Skip');
    app.click(skip);
    await settled();
    it('DP: Skip arms, naming the contract and what it does', function () {
      eq(app.requests('disposalSkip').length, 0);
      has(app.text(skip), 'Click again: finish the disposal on ct00000001 and hand over its payout');
    });
    app.click(skip);
    await settled();
    it('DP: and sends the step, then reads the list again', function () {
      eq(app.last('disposalSkip').data, { id: 'disposal:ct00000001:1' });
      eq(app.requests('disposalList').length, 2);
      has(app.main(), 'Finished: the payout is being handed over.');
    });
    const respawn = app.button('Respawn vehicle');
    app.click(respawn);
    it('DP: Respawn vehicle arms naming the contract', function () {
      has(app.text(respawn), 'Click again: make the vehicle for ct00000001 again at the spawn spot');
    });
    app.click(respawn);
    await settled();
    it('DP: and sends the step', function () { eq(app.last('disposalRespawn').data, { id: 'disposal:ct00000001:1' }); });
    app.click(app.$$('[data-act="contract"]').filter(function (n) { return n.tagName === 'BUTTON'; })[0]);
    await settled();
    it('DP: its contract id opens the contract', function () { eq(app.last('contract').data, { id: 'ct00000001' }); });
    clean(app, 'disposal on contracts');
  })();

  await (async function () {
    const app = boot(disposalServer(), { fresh: true });
    app.open(FULL);
    await settled();
    it('DP: Home lists the steps too while there is one, the hitman with the identity ACE', function () {
      truthy(app.requests('disposalList').length >= 1, 'read on Home');
      has(app.main(), 'Body disposal in progress (1)');
      has(app.main(), 'HITMAN01');
    });
    clean(app, 'disposal on home');

    const quiet = boot(disposalServer({ disposalList: { ok: true, data: { enabled: true, steps: {}, spots: {},
      limitSeconds: 1800, onTimeout: 'pay' } } }), { fresh: true });
    quiet.open(ADMIN);
    await settled();
    it('DP: and nothing on Home while nobody is disposing of a body', function () {
      lacks(quiet.main(), 'Body disposal');
    });
    quiet.nav('contracts');
    await settled();
    it('DP: Contracts says it is on with nobody at it', function () {
      has(quiet.main(), 'Body disposal is on: nobody is disposing of a body right now.');
    });
    clean(quiet, 'disposal quiet');

    const old = boot(standardServer({ orgGet: orgOff() }));
    old.open(ADMIN);
    await settled();
    old.nav('contracts');
    await settled();
    old.nav('locations');
    await settled();
    it('DP: a server without disposal: nothing on Contracts, and Locations says it has no places', function () {
      has(old.main(), 'This server has no panel-set places.');
      eq(old.$$('[data-act="dp-skip"]').length, 0);
    });
    clean(old, 'no disposal');
  })();

  await (async function () {
    const app = boot(disposalServer());
    app.open(ADMIN);
    await settled();
    app.nav('locations');
    await settled();
    it('DP: Locations has the disposal vehicle spawn and the drop-off, each as it is now', function () {
      const text = app.main();
      has(text, 'Disposal vehicle spawn');
      has(text, 'Body drop-off');
      has(text, '1.5, 2, 3, 90');
      has(text, 'Not set.');
      has(text, 'Body disposal cannot start a step until both are set.');
    });
    const spotButtons = function (act, k) {
      return app.$$('[data-act="' + act + '"]').filter(function (b) { return b.getAttribute('data-value') === k; })[0];
    };
    app.click(spotButtons('loc-save', 'disposal_drop'));
    await settled();
    it('DP: Save with no figures sends nothing', function () {
      eq(app.requests('placeSet').length, 0);
      has(app.main(), 'Give x, y and z as numbers');
    });
    app.click(spotButtons('loc-mypos', 'disposal_drop'));
    await settled();
    it('DP: Use my position asks the server where staff stand and fills the drop-off', function () {
      eq(app.requests('placeMyPosition').length, 1, 'the one read for every kind');
      eq(app.$('[data-bind="loc.disposal_drop.x"]').value, '321');
      eq(app.$('[data-bind="loc.disposal_drop.h"]').value, '182');
    });
    const save = spotButtons('loc-save', 'disposal_drop');
    app.click(save);
    it('DP: Save arms naming the spot and the point', function () {
      eq(app.requests('placeSet').length, 0);
      has(app.text(save), 'Click again: save the drop-off at 321, 654');
    });
    app.click(save);
    await settled();
    it('DP: and sends the spot with its figures', function () {
      eq(app.last('placeSet').data, { kind: 'disposal_drop', x: 321, y: 654, z: 31, heading: 182 });
    });
    const here = spotButtons('loc-here', 'disposal_vehicle');
    app.click(here);
    it('DP: Save where I stand arms naming the spot', function () {
      has(app.text(here), 'Click again: save the vehicle spawn where you stand');
    });
    app.click(here);
    await settled();
    it('DP: and sends here', function () { eq(app.last('placeSet').data, { kind: 'disposal_vehicle', here: true }); });
    const clear = spotButtons('loc-remove', 'disposal_vehicle');
    app.click(clear);
    app.click(clear);
    await settled();
    it('DP: Clear takes two clicks and sends the spot', function () {
      eq(app.last('placeRemove').data, { id: 'place:disposal_vehicle:1' });
    });
    clean(app, 'disposal spots');

    const reader = boot(disposalServer());
    reader.open(READER);
    await settled();
    reader.nav('locations');
    await settled();
    it('DP: a reader sees the spots and every disposal write disabled', function () {
      has(reader.main(), 'Disposal vehicle spawn');
      ['loc-save', 'loc-here', 'loc-remove'].forEach(function (act) {
        reader.$$('[data-act="' + act + '"]').forEach(function (b) { truthy(b.disabled, act + ' disabled'); });
      });
      truthy(!reader.$$('[data-act="loc-mypos"]')[0].disabled, 'Use my position is a read');
    });
    reader.nav('contracts');
    await settled();
    it('DP: and Skip and Respawn disabled', function () {
      truthy(reader.button('Skip').disabled);
      truthy(reader.button('Respawn vehicle').disabled);
    });
    clean(reader, 'disposal reader');
  })();

  /* ---- where the funds are kept, as the server switches them ---- */
  await (async function () {
    const app = boot(orgServer({ orgFunds: { ok: true, data: { balance: 900, backend: 'internal', ready: true, rows: [] } } }));
    app.open(FULL);
    await settled();
    app.nav('orgfunds');
    await settled();
    it('FB: on the ledger: Switch to Renewed-Banking, enabled, and no Abandon', function () {
      const sw = app.$$('[data-act="org-backend"]');
      eq(sw.length, 1);
      eq(sw[0].getAttribute('data-value'), 'bank');
      falsy(sw[0].disabled);
      lacks(app.main(), 'Abandon the bank');
    });
    app.server.orgFunds = { ok: true, data: { backend: 'bank', ready: false, rows: [] } };
    app.click(app.button('Refresh'));
    await settled();
    it('FB: on a bank that is down: the plain switch is disabled, saying why, and Abandon is the way off', function () {
      const sw = app.$$('[data-act="org-backend"]');
      const plain = sw.filter(function (b) { return b.getAttribute('data-how') !== 'abandon'; })[0];
      const abandon = sw.filter(function (b) { return b.getAttribute('data-how') === 'abandon'; })[0];
      truthy(plain.disabled, 'a switch would be refused bank_down');
      has(plain.getAttribute('title'), 'Abandon it below');
      eq(abandon.getAttribute('data-value'), 'internal');
      falsy(abandon.disabled);
    });
    app.server.orgFunds = { ok: true, data: { backend: 'bank', ready: true, rows: [] } };
    app.click(app.button('Refresh'));
    await settled();
    const back = app.$$('[data-act="org-backend"]')[0];
    app.click(back);
    app.click(back);
    await settled();
    it('FB: on a bank that answers: Switch to the ledger sends internal, no abandon', function () {
      eq(app.last('orgFundsBackend').data, { backend: 'internal' });
      lacks(app.main(), 'Abandon the bank');
    });
    clean(app, 'funds backend');
  })();

  /* ---- a recovery finishing enables the write buttons where they are ---- */
  await (async function () {
    const server = standardServer({ overview: overview({ recovery: 'recovering' }) });
    const app = boot(server);
    app.open(access({ recovery: 'recovering' }));
    await settled();
    app.nav('tools');
    await settled();
    const refresh = app.button('Bring timers forward');
    it('while recovering, a write is disabled', function () { truthy(refresh.disabled); });
    server.overview = overview({ recovery: 'ready' });
    const clears = app.byId('main')._clears || 0;
    app.fire(30000);
    await settled();
    it('and once it finishes, the same button is enabled, with no redraw of the section', function () {
      falsy(app.button('Bring timers forward').disabled);
      truthy(app.button('Bring timers forward') === refresh, 'the same node');
      eq((app.byId('main')._clears || 0) - clears, 0, 'the section was not drawn again');
    });
    clean(app, 'recovery gates');
  })();

  /* ---- every write button the new views draw takes two clicks ---- */
  await (async function () {
    const app = boot(orgServer());
    app.open(FULL);
    await settled();
    const single = [];
    for (const view of ['orgsetup', 'orgroles', 'orgmembers', 'orgapps', 'orgfunds', 'orgaccess', 'orgnotices',
      'orgwork', 'orgarmory', 'orgrecord', 'orgturf', 'bpmatrix', 'bplimits', 'bpoffice', 'logs:grants', 'locations', 'measures',
      'inbox', 'changed']) {
      app.nav(view);
      await settled();
      app.$$('[data-gate]').forEach(function (b) {
        if (b.getAttribute('data-confirm') !== 'yes') single.push(view + ':' + b.getAttribute('data-act'));
      });
    }
    it('every write the new views draw carries the two-click confirm', function () { eq(single, []); });
    clean(app, 'two clicks everywhere');
  })();

  /* ================================================================
     Step 7 workflows: every staff panel screen's main path. Each test's
     name carries the screens it drives ("workflow screen:<id>", the ids of
     the capability inventory); tests/workflows/coverage_spec.lua reads them
     for the coverage report (docs/dev/workflows.md).
     ================================================================ */
  await (async function workflowScreens() {
    const server = orgServer(Object.assign({}, tlServer(), disposalServer(), staffPlayerServer(), {
      settings: orgSettings(true), orgGet: orgOn()
    }));
    const app = boot(server);
    app.open(FULL);
    await settled();
    const GROUP_VIEWS = {
      home: ['overview', 'inbox', 'announce'],
      players: ['players', 'pmeasures', 'pmoney', 'pplaytime', 'phistory', 'pdiag', 'measures'],
      contracts: ['contracts'],
      targets: ['tldefaults', 'tljobs', 'tlplayer'],
      rules: ['rules', 'presets', 'changed'],
      org: ['orgsetup', 'orgroles', 'orgmembers', 'orgapps', 'orgfunds', 'orgaccess', 'orgnotices'],
      bossperms: ['bpmatrix', 'bplimits', 'bpoffice'],
      locations: ['locations'],
      logs: ['logs', 'alerts'],
      developer: ['health', 'devsettings', 'console', 'tools', 'setup'],
      help: ['help', 'howto', 'permissions']
    };
    for (const group of Object.keys(GROUP_VIEWS)) {
      // Help is the header's (?) button, not a sidebar section.
      let groupOk = true;
      if (group !== 'help') {
        try { app.group(group); } catch (err) { groupOk = err.message; }
      }
      await settled();
      const drawn = [];
      for (const view of GROUP_VIEWS[group]) {
        let err = null;
        const before = app.sent ? app.sent.length : 0;
        try { app.nav(view); } catch (e) { err = e.message; }
        await settled();
        drawn.push({ view: view, err: err, text: app.main(), asked: (app.sent ? app.sent.length : 0) - before });
      }
      it('workflow screen:admin.group:' + group + ' ' + GROUP_VIEWS[group].map(function (v) {
        return 'screen:admin.view:' + v;
      }).join(' ') + ' — the section opens and every view in it draws', function () {
        eq(groupOk, true, 'the sidebar opens ' + group);
        drawn.forEach(function (d) {
          eq(d.err, null, d.view + ' opened');
          truthy(d.text && d.text.length > 0, d.view + ' drew something');
        });
      });
    }
    clean(app, 'every section');

    // The inbox's filters.
    for (const filter of ['all', 'reviews', 'stuck', 'alerts']) {
      let err = null;
      try { app.nav('inbox:' + filter); } catch (e) { err = e.message; }
      await settled();
      it('workflow screen:admin.inbox:' + filter + ' — the inbox shows ' + filter, function () {
        eq(err, null, 'opened');
        truthy(app.main().length > 0, 'drew');
      });
    }

    // The contract drawer: every tab, and Void from More.
    app.nav('contracts');
    await settled();
    app.click(app.$('tr.row'));
    await settled();
    for (const id of ['summary', 'money', 'people', 'notes', 'record']) {
      let err = null;
      try { app.tab(id); } catch (e) { err = e.message; }
      await settled();
      it('workflow screen:admin.drawer:' + id + ' — the contract drawer\'s ' + id + ' tab', function () {
        eq(err, null, 'opened');
        truthy(app.drawer().textContent.length > 0, 'drew');
      });
    }
    clean(app, 'the drawer');

    // Announce: the main path sends one notice.
    app.nav('announce');
    await settled();
    let sentAnnounce = false;
    try {
      app.type(app.byId('an-text'), 'The docks are hot tonight.');
      const send = app.button('Send');
      app.click(send);
      await settled();
      app.click(send);
      await settled();
      sentAnnounce = app.requests('announce').length > 0;
    } catch (e) { sentAnnounce = e.message; }
    it('workflow screen:admin.view:announce — staff send an announcement', function () {
      eq(sentAnnounce, true, 'announce was sent');
    });
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
