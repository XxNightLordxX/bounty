/* Renders ui/admin.html (the staff panel, /hitmanadmin) in a real browser
 * and measures it, at the desktop window sizes it is opened in: 1280 and
 * 1920 wide, and 1024, where it has to stay usable.
 *
 * The UI suite drives the page's behaviour through a DOM shim with no
 * layout engine, so a control that is present and correct and drawn off the
 * edge of the panel passes it. This is the half it cannot see: everything on
 * screen, nothing cut off or sideways-scrolling, controls big enough to hit,
 * text big enough to read at arm's length, the drawer and the dropdowns
 * inside the window, and nothing drawn at all over the game while closed.
 *
 * The page's Font Awesome comes from cdnjs, which is blocked here: the panel
 * has to read without its icons, as it would on a game client that cannot
 * reach the CDN.
 *
 * Skipped where playwright is not installed. */

'use strict';

const path = require('path');

let chromium;
try {
  chromium = require('playwright').chromium;
} catch (err) {
  try {
    chromium = require('/opt/node22/lib/node_modules/playwright').chromium;
  } catch (err2) {
    console.log('playwright not installed; skipping the admin panel layout suite');
    process.exit(0);
  }
}

const PAGE = path.join(__dirname, '..', '..', 'ui', 'admin.html');

let passed = 0, failed = 0;
const failures = [];

function it(name, fn) {
  try { fn(); passed++; }
  catch (err) { failed++; failures.push(name + '\n    ' + err.message); }
}
function truthy(v, m) { if (!v) throw new Error((m || 'expected truthy') + ', got ' + JSON.stringify(v)); }
function none(list, m) {
  if (list && list.length) throw new Error((m || 'faults') + ' (' + list.length + '): ' + list.slice(0, 6).join(' | '));
}

/* A server, installed before the page loads: the panel's shapes, with the
 * longest things each can hold (names, reasons, log details, labels). */
function serverStub() {
  const NOW = Math.floor(Date.now() / 1000);
  const LONG = 'Maximilian Featherstonehaugh-Cholmondeley';
  const REASON = 'Skipped on a debt and took the car with him, which was not his, and then told everyone';
  function acrossTheWire(value) {
    if (Array.isArray(value)) return value.length === 0 ? {} : value.map(acrossTheWire);
    if (value && typeof value === 'object') {
      const out = {};
      Object.keys(value).forEach(function (k) { out[k] = acrossTheWire(value[k]); });
      return out;
    }
    return value;
  }
  const rows = [];
  for (let i = 1; i <= 25; i++) {
    rows.push({ id: 'ct' + String(10000000 + i), state: ['active', 'accepted', 'completed', 'voided', 'bailed_out'][i % 5],
      mode: 'competitive', rule: i % 2 ? 'alive' : 'either', created_at: NOW - i * 3600, deadline_at: NOW + 7200,
      resolved_at: i % 5 === 2 ? NOW - 60 : null, resolution: i % 5 === 2 ? 'completed' : null,
      target: i === 3 ? LONG : 'Dana Reyes ' + i, client: i % 4 === 0 ? 'Anonymous' : 'Vic Marlowe',
      anonymous: i % 4 === 0, slots: 3, claimed: i % 3 });
  }
  const settings = { features: [], limits: [], readonly: [], overrides: 3 };
  const groups = ['Access', 'Rewards', 'Completion', 'Handovers', 'Buyouts', 'Targeting', 'Law enforcement advisory'];
  for (let i = 0; i < 40; i++) {
    settings.features.push({ key: 'Feature' + i + '.Enabled', group: groups[i % groups.length],
      label: i === 4 ? 'The hitman\'s vehicle counts as restraint for the whole of the countdown' : 'Feature number ' + i,
      about: 'What it does, in a sentence long enough to wrap across the row at the narrowest width this is opened at.',
      inflight: 'Things already under way finish under the rules they started with; only new actions are refused while it is off.',
      kind: 'switch', live: i !== 2, value: i % 3 !== 0, default: true, source: i % 7 === 0 ? 'panel' : 'config',
      by: 'ADMIN001', at: NOW - 600, ignored: i === 5 ? 'has to be on or off' : undefined });
  }
  // Kill photos off with some kept from before: the removal under the
  // switch, with every fact it can say.
  settings.features.push({ key: 'Completion.KillPhotos', group: 'Completion', label: 'Kill photos', kind: 'switch',
    live: true, value: false, default: false, source: 'config',
    about: 'Off: no kill photo is ever taken, uploaded, kept or served, and no image host is asked anything.',
    inflight: 'Read at the next Verify kill, with no restart.' });
  settings.keptPhotos = { count: 1234, open: 12, links: 600, files: 634, waiting: 2 };
  settings.features.push({ key: 'Completion.Fulfilment', group: 'Completion', label: 'How contracts are completed',
    kind: 'choice', choices: ['alive', 'either'], live: true, value: 'alive', default: 'alive', source: 'config',
    about: '\'alive\': live handover only. \'either\': a photographed kill or a handover.',
    inflight: 'Each contract keeps the rule it was placed under; this changes new contracts only.' });
  for (let i = 0; i < 30; i++) {
    settings.limits.push({ key: 'Cooldowns.bucket' + i + '.burst', group: i < 10 ? 'Contract limits' : 'Rate limits',
      label: 'bucket' + i + ': requests held', kind: 'number', integer: true, min: 1, max: 200, live: true,
      value: 30, default: 30, source: i === 3 ? 'panel' : 'config',
      inflight: 'Read each time it is used, so it applies to the next check, including on contracts already placed.' });
  }
  // A number whose lowering deletes: its Save carries a confirm label, and
  // its row a warning line.
  settings.limits.push({ key: 'Ledger.PhotoRetentionDays', group: 'Ledger',
    label: 'Days an unopened kill photo is kept (0 forever)', kind: 'number', integer: true, min: 0, max: 365,
    live: true, value: 7, default: 7, source: 'config',
    inflight: 'Looked at every ten minutes: photos already past a shorter age go then.',
    destroys: 'Lowered to %s, every unopened kill photo older than %s day(s) is deleted at the next sweep, for good.' });
  settings.limits.push({ key: 'Advisory.RecipientJobNames', group: 'Advisory job lists',
    label: 'Job names that receive advisories', kind: 'list', live: true,
    value: ['police', 'sheriff', 'sast', 'fib', 'ranger'], default: ['police'], source: 'panel' });
  settings.readonly.push({ key: 'Database.Mode', group: 'Storage', label: 'Storage mode', kind: 'text',
    readonly: 'Changing it needs the money in the old mode settled and a restart (README, Changing storage mode).',
    value: 'json', default: 'json', source: 'config' });

  const answers = {
    overview: { ok: true, data: {
      at: NOW, contracts: { total: 1234, byState: { active: 31, accepted: 22, completing: 1, completed: 900,
        bailed_out: 40, expired: 200, cancelled: 30, voided: 10 } },
      hitmen: { active: 44, operatives: 30 },
      held: { cash: 12345678, bank: 98765432, dirty: 1234567, items: 120, weapons: 14, lines: 300 },
      owed: { cash: 1200, bank: 45000, dirty: 0, items: 3, weapons: 1, lines: 9, players: 4, queued: 6 },
      stuck: { total: 5, leftForStaff: 3, byWhy: { raised: 1, unknown: 1, interrupted: 1, stalled_claim: 1, ending_unfinished: 1 } },
      reviews: { open: 4 },
      photos: { waiting: { count: 3, bytes: 900000 }, kept: { count: 2, bytes: 400000 }, served: { count: 9, bytes: 4000000 } },
      storage: 'mysql', fulfilment: 'either', photoStorage: 'server', recovery: 'ready',
      slowest: [{ name: 'expiry_and_cleanup_of_contracts', max: 12.5, avg: 2.1, last: 1.9, runs: 12000 },
        { name: 'sampler', max: 0.4, avg: 0.2, last: 0.1, runs: 900 }],
      slowMs: 5,
      warnings: ['photo hosts: 0 -> add your phone\'s upload host to Config.Completion.ExtraPhotoHosts (a bare domain)',
        'PHOTO LINKS: the public address does not lead here -> set Config.Completion.PhotoPublicUrl'],
      overrides: 3, auditQueued: 12, alerts: { open: 12 } } },
    // The alerts, with the longest things each holds: a block of lines, a
    // line with no spaces to break at, a contract, a count, and a post given up.
    alerts: { ok: true, data: { state: 'open', open: 12, acknowledged: 3, limit: 100,
      discord: { on: true, webhook: 'staff', waiting: 3, posting: true, posted: 1234, lastOkAt: NOW - 600,
        lastFail: { at: NOW - 60, tries: 3, status: 429, alerts: 14 } },
      rows: (function () {
        const out = [];
        for (let i = 1; i <= 12; i++) {
          out.push({ id: 'al' + String(10000000 + i), level: i % 3 ? 'always' : 'problem',
            text: i === 1 ? 'BOOT RECOVERY FAILED: ' + REASON + '\n  What the last shutdown left part-way is not settled, '
              + 'so the app,\n  the login payouts and the staff commands that settle, void or list escrow stay closed.'
              : i === 2 ? 'a_line_with_no_spaces_to_break_at_' + 'x'.repeat(240)
              : 'escrow line owe' + String(10000000 + i) + ': ' + REASON + ' -> left for staff in Stuck escrow',
            contract: i % 2 ? 'ct' + String(10000000 + i) : null, count: i % 4 ? 1 : 27,
            first_at: NOW - 86400 * i, last_at: NOW - 600 * i });
        }
        return out;
      })() } },
    // The console, with the longest things it keeps: a start of 120 lines
    // and more not kept, a line with no spaces to break at, a database
    // error, a block of lines, and the newest 80 with counts.
    console: { ok: true, data: (function () {
      const boot = [], recent = [];
      for (let i = 0; i < 120; i++) {
        boot.push({ text: i === 3 ? 'a_line_with_no_spaces_to_break_at_' + 'x'.repeat(240)
          : 'start line ' + i + ': ' + REASON, kind: i % 9 ? 'debug' : 'always' });
      }
      for (let i = 0; i < 80; i++) {
        recent.push({ text: i === 1 ? 'BOOT RECOVERY FAILED: ' + REASON + '\n  What the last shutdown left part-way'
          : 'escrow line ct' + String(10000000 + i) + ':2 raised: Deadlock found when trying to get lock (statement: '
            + 'UPDATE crimson_escrow SET state = ? WHERE id = ? AND state = ?)', kind: i % 2 ? 'always' : 'debug',
          at: NOW - 60 * (80 - i), times: i % 5 ? 1 : 1234 });
      }
      return { at: NOW, debug: false, count: 14, bootLeft: 37, bootKept: 120, recentKept: 40, alwaysKept: 40,
        problems: ['warning: Config.Completion.ExtraPhotoHosts names ' + 'host'.repeat(30) + ', which is not a host',
          'warning: ' + REASON], boot: boot, recent: recent };
    })() },
    contracts: { ok: true, data: { rows: rows, page: 1, pages: 50, total: 1234 } },
    contract: { ok: true, data: {
      contract: { id: 'ct10000001', state: 'accepted', mode: 'exclusive', rule: 'either', reason: REASON,
        created_at: NOW - 3600, deadline_at: NOW + 7200, expires_at: NOW + 86400, bailout_amount: 1250000,
        penalty_amount: 25000, bonus_percent: 50, slots: 3, claimed: 1, next_slot: 2, buyout_queued: true,
        target_protected: true, anonymous: true,
        client: { name: LONG, cid: 'CREATOR1' }, target: { name: LONG, cid: 'TARGET01' } },
      escrow: (function () {
        const out = [];
        for (let i = 1; i <= 12; i++) {
          out.push({ id: 'ct10000001:' + i, contract: 'ct10000001', slot: (i % 3) + 1, portion: i % 4 ? 'baseline' : 'bonus',
            source: i % 5 === 0 ? 'item' : 'bank', amount: 125000 * i, item: 'a_long_item_name_' + i, quantity: i,
            state: i % 2 ? 'held' : 'settled', owed_to: i === 2 ? 'operative Ghost of the Eastern Docks' : undefined,
            raised: i === 2 ? 3 : 0, arrived: i === 2 ? 2000 : undefined, parked: i === 2, owes: i % 2 ? 125000 * i : 0,
            settled_by_staff: i === 4 ? 'delivered' : undefined });
        }
        return out;
      })(),
      hitmen: [{ id: 'hm1', alias: 'Ghost of the Eastern Docks', anonymous: true, name: LONG, cid: 'HITMAN01',
        state: 'active', accepted_at: NOW - 1800, claims: 1, stake: 25000 },
        { id: 'hm2', alias: 'Second', anonymous: false, name: 'Bo Renn', cid: 'HITMAN02', state: 'left',
          accepted_at: NOW - 9000, left_at: NOW - 5000, claims: 0, stake: 0 }],
      amendments: [{ id: 'am1', kind: 'extend_deadline', proposer: 'the client', expires_at: NOW + 600,
        payload: { seconds: 3600, note: REASON } }],
      timeline: (function () {
        const out = [];
        for (let i = 0; i < 20; i++) {
          out.push({ ts: NOW - 3600 + i * 60, kind: ['financial', 'conduct', 'rejected', 'system'][i % 4],
            action: 'escrow_deliver_parked_and_a_long_action_name', contract: 'ct10000001', actor: 'operative Ghost',
            detail: { line: 'ct10000001:2', reason: REASON, amounts: [1, 2, 3], nested: { a: 1, b: 'two' } } });
        }
        return out;
      })(),
      stuck: [
        { line: 'ct10000001:2', contract: 'ct10000001', amount: 250000, source: 'bank', portion: 'baseline',
          intended: 'operative Ghost of the Eastern Docks', why: 'unknown', raised: 1, arrived: 2000, at: NOW - 600,
          actions: ['pay', 'pay_amount', 'return', 'delivered'] },
        { line: 'ct10000001:9', contract: 'ct10000001', amount: 300, source: 'cash', portion: 'baseline',
          orphan: true, actions: ['return_owner'] }
      ],
      canVoid: true } },
    reviews: { ok: true, data: { items: [
      { id: 'rv00000001', kind: 'contract_unrecorded', about: 'a contract\'s escrow was taken, and the store would neither '
          + 'write the contract nor say whether it had: its escrow is handed back by the server, so refund only the '
          + 'anonymity fee, if one was taken, where the contract does not exist',
        contract: 'ct10000002', parties: [{ role: 'payer', who: 'the client' }, { role: 'creator', who: 'the client' }],
        amount: 25000, account: 'bank', items: [{ source: 'item', item: 'lockpick', quantity: 5 }],
        known: { error: 'MySQL server has gone away while writing crimson_contracts row', at: NOW },
        now: { contract: 'none', lines: { held: 1, settled: 0, missing: 2 } }, state: 'open', created_at: NOW - 900 }
    ] } },
    logs: { ok: true, data: { rows: (function () {
      const out = [];
      for (let i = 0; i < 25; i++) {
        out.push({ ts: NOW - i * 60, kind: ['financial', 'conduct', 'rejected', 'system'][i % 4],
          action: i === 2 ? 'admin_settle_result_with_an_unusually_long_action' : 'admin_void',
          contract: 'ct' + String(10000000 + i), actor: i % 2 ? '(a player)' : 'the client',
          detail: { reason: REASON, lines: i, nested: { line: 'ct10000001:2', owed_to: 'the client' } } });
      }
      return out;
    })(), next: 99 } },
    player: { ok: true, data: { player: { cid: 'TARGET01', name: LONG, online: true, server: 123 },
      contracts: rows.slice(0, 10).map(function (r) {
        return { id: r.id, state: r.state, role: 'target', anonymous: false, target: r.target,
          created_at: r.created_at, resolution: r.resolution };
      }),
      stats: { completed: 52, failed: 3, placed: 9, survived: 4, rate: 94, standing: 'Notorious' },
      owed: [{ id: 'ct10000005:2', contract: 'ct10000005', source: 'bank', amount: 1250000, state: 'held', owes: 1250000,
        queued: true }],
      pending: 2, notices: { count: 2, titles: ['Contract closed', REASON] },
      playtime: { hours: 1234.5, grandfathered: false, counted: true, counting: true, floor: 5,
        from: 'provider' } } },
    settings: { ok: true, data: settings },
    diag: { ok: true, data: { lines: (function () {
      const out = ['--- crimson-hitman diagnosis'];
      for (let i = 0; i < 30; i++) out.push('check ' + i + ': ' + REASON + ' -> do something about it');
      return out;
    })() } },
    flush: { ok: true, message: 'Audit log flushed: 12 row(s) written.', data: { written: 12 } },
    // Every escrow line waiting for staff, with the longest things each holds.
    stuck: { ok: true, data: { recovery: 'ready', reviews: 4, lines: (function () {
      const out = [];
      const whys = ['unknown', 'raised', 'unqueued', 'stalled_claim', 'releasing'];
      for (let i = 1; i <= 8; i++) {
        out.push({ line: 'ct1000000' + i + ':' + (i + 10), contract: 'ct1000000' + i, amount: 125000 * i,
          source: i % 3 ? 'bank' : 'item', item: 'a_long_item_name_' + i, quantity: i, portion: i % 2 ? 'baseline' : 'owed',
          intended: 'operative Ghost of the Eastern Docks', why: whys[i % whys.length], raised: i % 4, arrived: i * 100,
          at: NOW - i * 600, actions: i === 3 ? ['return_owner'] : ['pay', 'pay_amount', 'return', 'delivered'] });
      }
      out.push({ line: 'ct10000099:1', contract: 'ct10000099', amount: 100, source: 'cash', portion: 'stake',
        why: 'ending_unfinished', unfinished: true, actions: [] });
      return out;
    })() } },
    whois: { ok: true, data: { creator: { cid: 'CREATOR1', name: LONG, anonymous: true },
      target: { cid: 'TARGET01', name: 'Dana Reyes' }, hitmen: [] } }
  };
  window.GetParentResourceName = function () { return 'crimson-hitman'; };
  window.__requests = [];
  window.fetch = function (url, options) {
    const event = url.split('/').pop();
    const body = JSON.parse((options && options.body) || '{}');
    window.__requests.push({ event: event, op: body.op });
    const answer = event === 'adminRequest' ? (answers[body.op] || { ok: true }) : { ok: true };
    return Promise.resolve({ json: function () { return Promise.resolve(acrossTheWire(answer)); } });
  };
}

const ACCESS = { canWrite: true, canIdentify: true, pageSize: 25, refreshSeconds: 10, recovery: 'ready',
  version: '1.1.0' };

/* Everything that can go wrong on one screen of the panel, measured. */
function measure(opts) {
  const out = [];
  const W = window.innerWidth, H = window.innerHeight;
  const panel = document.getElementById('panel');
  const p = panel.getBoundingClientRect();
  function name(node) {
    const cls = typeof node.className === 'string' && node.className ? '.' + node.className.split(' ').join('.') : '';
    const text = (node.textContent || '').trim().slice(0, 30);
    return node.tagName.toLowerCase() + cls + (text ? ' "' + text + '"' : '');
  }
  function shown(node) {
    const r = node.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return false;
    const style = getComputedStyle(node);
    return style.visibility !== 'hidden' && style.display !== 'none';
  }
  if (p.left < -0.5 || p.top < -0.5 || p.right > W + 0.5 || p.bottom > H + 0.5) {
    out.push('the panel spans ' + [p.left, p.top, p.right, p.bottom].map(Math.round).join(',') + ' in ' + W + 'x' + H);
  }
  if (document.documentElement.scrollWidth > W + 1) out.push('the page scrolls sideways');

  const main = document.getElementById('main');
  if (main.scrollWidth > main.clientWidth + 1) {
    out.push('the section scrolls sideways (' + main.scrollWidth + ' in ' + main.clientWidth + ')');
  }
  if (opts.tablesFit) {
    document.querySelectorAll('#main .table-wrap, #drawer .table-wrap').forEach(function (wrap) {
      if (shown(wrap) && wrap.scrollWidth > wrap.clientWidth + 1) {
        out.push('a table scrolls sideways (' + wrap.scrollWidth + ' in ' + wrap.clientWidth + '): '
          + name(wrap.querySelector('thead') || wrap));
      }
    });
  }

  // Every control on screen big enough to hit with a mouse in a game window.
  const scope = opts.scope ? document.querySelector(opts.scope) : panel;
  scope.querySelectorAll('button, input').forEach(function (node) {
    if (!shown(node)) return;
    const r = node.getBoundingClientRect();
    if (r.height < 28 - 0.5) out.push(name(node) + ' is ' + r.height.toFixed(1) + 'px tall');
    if (r.width < 28 - 0.5) out.push(name(node) + ' is ' + r.width.toFixed(1) + 'px wide');
  });

  // Text big enough to read at arm's length.
  scope.querySelectorAll('*').forEach(function (node) {
    if (!shown(node)) return;
    const own = Array.prototype.some.call(node.childNodes, function (c) {
      return c.nodeType === 3 && c.textContent.trim().length > 0;
    });
    if (!own) return;
    const size = parseFloat(getComputedStyle(node).fontSize);
    if (size < 12 - 0.01) out.push(name(node) + ' is set in ' + size.toFixed(1) + 'px');
  });

  // Nothing cut off by the box it is in: cards, tiles, rows of settings,
  // stuck lines, the drawer's head.
  scope.querySelectorAll('.card, .tile, .st-row, .stuck-line, .drawer-head, .bar, .toolbar, .slot').forEach(function (box) {
    if (!shown(box)) return;
    const b = box.getBoundingClientRect();
    box.querySelectorAll('*').forEach(function (node) {
      if (!shown(node) || node.closest('.table-wrap') || node.closest('.dd-menu')) return;
      const r = node.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return;
      if (r.right > b.right + 1 || r.left < b.left - 1) {
        out.push(name(node) + ' spans ' + Math.round(r.left) + '-' + Math.round(r.right) + ' in '
          + name(box).slice(0, 40) + ' ' + Math.round(b.left) + '-' + Math.round(b.right));
      }
    });
  });

  // The nav: every section reachable, every label whole.
  document.querySelectorAll('.nav-btn').forEach(function (b) {
    const r = b.getBoundingClientRect();
    if (r.bottom > p.bottom + 0.5) out.push(name(b) + ' is below the panel');
    const lbl = b.querySelector('.lbl');
    if (lbl && lbl.scrollWidth > lbl.clientWidth + 1) out.push(name(b) + ' has its label cut off');
  });
  return out;
}

async function openAt(browser, width, height) {
  const page = await browser.newPage({ viewport: { width: width, height: height } });
  await page.route('https://cdnjs.cloudflare.com/**', function (route) { return route.abort(); });
  await page.addInitScript(serverStub);
  await page.goto('file://' + PAGE);
  await page.waitForFunction(function () { return !!document.querySelector('#nav-overview'); });
  await page.waitForTimeout(200);
  return page;
}

async function main() {
  const browser = await chromium.launch();

  /* ---- closed: nothing over the game ---- */
  const closed = await openAt(browser, 1920, 1080);
  const quiet = await closed.evaluate(function () {
    return {
      hidden: getComputedStyle(document.getElementById('panel')).display === 'none',
      body: getComputedStyle(document.body).backgroundColor,
      html: getComputedStyle(document.documentElement).backgroundColor,
      asked: window.__requests.length,
      script: typeof window.CH_ADMIN_BUILD === 'string'
    };
  });
  it('draws nothing over the game while closed, and asks nothing', function () {
    truthy(quiet.hidden, 'the panel is drawn while closed');
    truthy(quiet.body === 'rgba(0, 0, 0, 0)' && quiet.html === 'rgba(0, 0, 0, 0)',
      'the page is not transparent: ' + quiet.body + ' / ' + quiet.html);
    truthy(quiet.asked === 0, quiet.asked + ' request(s) before it was opened');
    truthy(quiet.script, 'admin.js is loaded with a build query');
  });
  await closed.close();

  const sizes = [
    { w: 1280, h: 720, tablesFit: true },
    { w: 1920, h: 1080, tablesFit: true },
    // Still usable: tables may scroll inside their own frame, never the page.
    { w: 1024, h: 768, tablesFit: false }
  ];
  const sections = ['overview', 'contracts', 'stuck', 'reviews', 'alerts', 'console', 'logs', 'players', 'settings',
    'tools'];

  for (const size of sizes) {
    const page = await openAt(browser, size.w, size.h);
    await page.evaluate(function (access) { window.postMessage({ type: 'open', access: access }, '*'); }, ACCESS);
    await page.waitForTimeout(250);
    const at = size.w + 'x' + size.h;

    const frame = await page.evaluate(function () {
      const p = document.getElementById('panel').getBoundingClientRect();
      const close = document.getElementById('close').getBoundingClientRect();
      const brand = document.querySelector('.brand').getBoundingClientRect();
      const badges = document.getElementById('badges').getBoundingClientRect();
      return { width: p.width, height: p.height, closeInside: close.right <= p.right && close.top >= p.top,
               overlap: brand.right > badges.left + 1 && badges.width > 0, W: window.innerWidth };
    });
    it(at + ': the panel takes most of the window, with its close button in it', function () {
      truthy(frame.width >= frame.W * 0.9 || frame.width >= 1700, 'the panel is ' + Math.round(frame.width) + 'px wide');
      truthy(frame.closeInside, 'the close button is outside the panel');
      truthy(!frame.overlap, 'the title runs under the badges');
    });

    for (const section of sections) {
      await page.click('#nav-' + section);
      await page.waitForTimeout(120);
      if (section === 'players') {
        await page.fill('#pl-q', '123');
        await page.press('#pl-q', 'Enter');
        await page.waitForTimeout(120);
      }
      if (section === 'tools') {
        await page.click('button[data-act="tl-diag"]');
        await page.waitForTimeout(120);
      }
      if (section === 'alerts') {
        // Measured with Acknowledge all shown armed, its confirm showing.
        await page.click('button[data-act="al-ack-all"]');
        await page.waitForTimeout(60);
      }
      if (section === 'settings') {
        // Measured with the removal of the kill photos kept from before
        // armed, its confirm naming the count.
        await page.click('button[data-act="st-remove-photos"]');
        await page.waitForTimeout(60);
      }
      const faults = await page.evaluate(measure, { tablesFit: size.tablesFit });
      it(at + ': ' + section + ' fits, with nothing cut off, too small to hit or too small to read', function () {
        none(faults, section);
      });
      const drawn = await page.evaluate(function () { return document.getElementById('main').textContent.length; });
      it(at + ': ' + section + ' drew something', function () { truthy(drawn > 40, 'only ' + drawn + ' characters'); });
    }

    // The settings, grouped, with each control beside its words.
    await page.click('#nav-settings');
    await page.waitForTimeout(120);
    const sideBySide = function () {
      const out = [];
      document.querySelectorAll('.st-row').forEach(function (row) {
        if (row.hidden) return;
        const main = row.querySelector('.st-main').getBoundingClientRect();
        const control = row.querySelector('.st-control').getBoundingClientRect();
        if (control.width > 0 && main.right > control.left + 1 && main.bottom > control.top + 1
            && main.top < control.bottom - 1) {
          out.push(row.getAttribute('data-key') + ': its words run under its control');
        }
      });
      return out;
    };
    const rowsFit = await page.evaluate(sideBySide);
    it(at + ': every setting\'s words and its control sit side by side', function () { none(rowsFit); });

    // And the limits, where a Save can carry a confirm label: armed, with
    // the row saying what lowering it deletes.
    await page.click('button.seg-btn[data-act="st-tab"][data-value="limits"]');
    await page.waitForTimeout(120);
    await page.fill('[data-bind="st.Ledger.PhotoRetentionDays"]', '1');
    await page.press('[data-bind="st.Ledger.PhotoRetentionDays"]', 'Enter');
    await page.waitForTimeout(120);
    const limitFaults = await page.evaluate(measure, { tablesFit: size.tablesFit });
    const limitRows = await page.evaluate(sideBySide);
    const saveArmed = await page.evaluate(function () {
      const save = document.getElementById('st-save-Ledger.PhotoRetentionDays');
      return save ? save.classList.contains('is-armed') : null;
    });
    it(at + ': the limits fit too, with a destructive Save armed and its warning shown', function () {
      truthy(saveArmed === true, 'the Save was not armed: ' + saveArmed);
      none(limitFaults.concat(limitRows), 'limits');
    });

    // A dropdown opened stays in the window.
    await page.click('#nav-contracts');
    await page.waitForTimeout(120);
    await page.click('#dd-ct-state .dd-btn');
    const menu = await page.evaluate(function () {
      const m = document.querySelector('#dd-ct-state .dd-menu');
      const r = m.getBoundingClientRect();
      return { shown: getComputedStyle(m).display !== 'none', right: r.right, bottom: r.bottom,
               W: window.innerWidth, H: window.innerHeight, options: m.querySelectorAll('.dd-opt').length };
    });
    it(at + ': a dropdown opens inside the window, every option in reach', function () {
      truthy(menu.shown, 'the menu did not open');
      truthy(menu.right <= menu.W && menu.bottom <= menu.H, 'the menu ends at ' + Math.round(menu.right) + ','
        + Math.round(menu.bottom));
      truthy(menu.options === 9, menu.options + ' options');
    });
    await page.click('#dd-ct-state .dd-btn');

    // The contract drawer.
    await page.click('#ct-results tr.row');
    await page.waitForTimeout(200);
    const drawer = await page.evaluate(function () {
      const d = document.getElementById('drawer');
      const r = d.getBoundingClientRect();
      const main = document.getElementById('main').getBoundingClientRect();
      const head = d.querySelector('.drawer-head').getBoundingClientRect();
      const close = d.querySelector('[data-act="drawer-close"]').getBoundingClientRect();
      const voidBtn = d.querySelector('[data-act="void"]').getBoundingClientRect();
      const nav = document.getElementById('nav-overview');
      const navR = nav.getBoundingClientRect();
      const atNav = document.elementFromPoint(navR.left + navR.width / 2, navR.top + navR.height / 2);
      return { width: r.width, left: r.left, right: r.right, top: r.top, bottom: r.bottom,
               mainLeft: main.left, mainRight: main.right, mainTop: main.top, mainBottom: main.bottom,
               headTop: head.top, closeRight: close.right, voidTop: voidBtn.top, voidBottom: voidBtn.bottom,
               H: window.innerHeight, navClear: !!atNav && nav.contains(atNav),
               sideways: d.scrollWidth > d.clientWidth + 1 };
    });
    it(at + ': the drawer lies over the section, leaves the navigation in reach, and is wide enough to read', function () {
      truthy(drawer.left >= drawer.mainLeft - 0.5 && drawer.right <= drawer.mainRight + 0.5, 'the drawer spills out of the section');
      truthy(drawer.top >= drawer.mainTop - 0.5 && drawer.bottom <= drawer.mainBottom + 0.5, 'the drawer is taller than the section');
      truthy(drawer.width >= 520, 'the drawer is ' + Math.round(drawer.width) + 'px wide');
      truthy(drawer.navClear, 'the drawer or its scrim covers the navigation');
      truthy(!drawer.sideways, 'the drawer scrolls sideways');
    });
    it(at + ': its close and its void are on screen as it opens', function () {
      truthy(drawer.closeRight <= drawer.right + 0.5, 'close is off the drawer');
      truthy(drawer.voidBottom <= drawer.H && drawer.voidTop >= drawer.headTop, 'void is not on the first screen');
    });
    const inDrawer = await page.evaluate(measure, { tablesFit: size.tablesFit, scope: '#drawer' });
    it(at + ': the drawer fits, with nothing cut off, too small to hit or too small to read', function () {
      none(inDrawer, 'drawer');
    });

    // An armed button keeps its size, so a second click lands on it.
    const armed = await page.evaluate(function () {
      const b = document.querySelector('#drawer [data-act="void"]');
      const before = b.getBoundingClientRect();
      b.click();
      const after = b.getBoundingClientRect();
      const cfm = b.querySelector('.cfm');
      const label = cfm && getComputedStyle(cfm).visibility === 'visible' ? cfm.textContent : '';
      return { moved: Math.abs(after.left - before.left) + Math.abs(after.top - before.top), label: label,
               armed: b.classList.contains('is-armed'), height: after.height };
    });
    it(at + ': a destructive button armed for its second click stays where it was, saying so', function () {
      truthy(armed.armed, 'the first click did not arm it');
      truthy(armed.moved < 1, 'it moved ' + armed.moved + 'px');
      truthy(/Click again/.test(armed.label), armed.label);
      truthy(armed.height >= 28, armed.height + 'px tall');
    });

    // A toast: inside the window, clear of the close button.
    await page.click('#drawer [data-act="drawer-close"]');
    await page.click('#nav-tools');
    await page.waitForTimeout(100);
    await page.click('button[data-act="tl-flush"]');
    await page.waitForTimeout(150);
    const toast = await page.evaluate(function () {
      const t = document.querySelector('.toast');
      if (!t) return null;
      const r = t.getBoundingClientRect();
      const c = document.getElementById('close').getBoundingClientRect();
      return { right: r.right, bottom: r.bottom, top: r.top, left: r.left, W: window.innerWidth, H: window.innerHeight,
               overClose: !(r.right < c.left || r.left > c.right || r.bottom < c.top || r.top > c.bottom) };
    });
    it(at + ': a toast shows inside the window, clear of the close button', function () {
      truthy(toast, 'no toast');
      truthy(toast.right <= toast.W && toast.bottom <= toast.H && toast.left >= 0, 'the toast is off screen');
      truthy(!toast.overClose, 'the toast covers the close button');
    });

    // The quietest text on the page still reads on what it is set on.
    const contrast = await page.evaluate(function () {
      function lum(css) {
        const m = /rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)/.exec(css);
        const ch = [m[1], m[2], m[3]].map(function (v) {
          v = Number(v) / 255;
          return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        });
        return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
      }
      function ratio(a, b) { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }
      const hint = document.querySelector('.about') || document.querySelector('.hint');
      const card = document.querySelector('.card');
      const main = document.getElementById('main');
      const faint = getComputedStyle(document.querySelector('.card-head h3')).color;
      return {
        faintOnCard: ratio(faint, getComputedStyle(card).backgroundColor),
        faintOnPanel: ratio(faint, getComputedStyle(document.getElementById('panel')).backgroundColor),
        dimOnCard: ratio(getComputedStyle(hint).color, getComputedStyle(card).backgroundColor),
        main: getComputedStyle(main).backgroundColor
      };
    });
    it(at + ': the faintest text clears 4.5:1 on what it is set on', function () {
      truthy(contrast.faintOnCard >= 4.5, 'on a card ' + contrast.faintOnCard.toFixed(2));
      truthy(contrast.faintOnPanel >= 4.5, 'on the panel ' + contrast.faintOnPanel.toFixed(2));
      truthy(contrast.dimOnCard >= 4.5, 'secondary text on a card ' + contrast.dimOnCard.toFixed(2));
    });
    await page.close();
  }

  await browser.close();
  console.log('');
  failures.forEach(function (f) { console.log('FAIL  ' + f); });
  console.log('\n' + passed + ' passed, ' + failed + ' failed');
  process.exit(failed === 0 ? 0 : 1);
}

main().catch(function (err) {
  console.error(err);
  process.exit(1);
});
