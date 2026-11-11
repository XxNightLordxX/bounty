/* Renders ui/admin.html (the staff panel, /hitmanadmin) in a real browser
 * and measures it, at the desktop window sizes it is opened in: 1280 and
 * 1920 wide, 1024, where it has to stay usable, and a phone's 390, where
 * the sidebar folds into one menu and the drawer takes the whole screen.
 * Every view of every section is measured, the organisation's, Boss
 * permissions' and Locations' included.
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

const PAGE = path.join(__dirname, '..', '..', 'crimson-hitman', 'ui', 'admin.html');

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
  settings.limits.push({ key: 'Ledger.PhotoRetentionDays', category: 'rules-timers', group: 'Ledger',
    label: 'Days an unopened kill photo is kept (0 forever)', kind: 'number', integer: true, min: 0, max: 365,
    live: true, value: 7, default: 7, source: 'config',
    inflight: 'Looked at every ten minutes: photos already past a shorter age go then.',
    destroys: 'Lowered to %s, every unopened kill photo older than %s day(s) is deleted at the next sweep, for good.' });
  settings.limits.push({ key: 'Advisory.RecipientJobNames', category: 'rules-targeting', group: 'Advisory job lists',
    label: 'Job names that receive advisories', kind: 'list', live: true,
    value: ['police', 'sheriff', 'sast', 'fib', 'ranger', 'bcso', 'trooper', 'sasp', 'k9', 'leo_reserve_long_name'],
    default: ['police'], shipped: ['police', 'sheriff'], hasShipped: true, source: 'panel' });
  settings.limits.push({ key: 'Notifications.ParanoidAlertJitter', category: 'rules-timers', group: 'Notifications',
    label: 'Wait before "eyes on you" (s, from-to)', kind: 'range', integer: true, min: 0, max: 86400, live: true,
    value: { min: 60, max: 600 }, default: { min: 60, max: 600 }, shipped: { min: 30, max: 600 }, hasShipped: true,
    source: 'config', inflight: 'Read each time it is used.' });
  settings.limits.push({ key: 'Bailout.Command', category: 'rules-limits', group: 'Buyouts', label: 'Buyout command',
    kind: 'text', live: false, value: 'cleanse', default: 'cleanse', source: 'config',
    inflight: 'Read once at start: kept now, and in force after the next restart.' });
  ['MaxContractValue', 'Sources.cash.max', 'Intel.Informant.Cost', 'Anonymity.CreatorFee', 'Limits.MaxEscrowLines',
    'Bailout.AbsoluteMax'].forEach(function (key, i) {
    settings.limits.push({ key: key, category: 'rules-rewards',
      money: ['Rewards', 'Rewards', 'Intel prices', 'Anonymity fees', 'Escrow', 'Buyouts'][i], group: 'Money',
      label: 'A money setting with a label long enough to wrap ' + i, kind: 'number', integer: true, min: 0,
      max: 100000000, live: true, value: 250000, default: 250000, shipped: 500000, hasShipped: true, source: 'config',
      about: 'What it does, in a sentence long enough to wrap across the row.', inflight: 'Read each time it is used.' });
  });
  ['create', 'accept', 'load'].forEach(function (b) {
    settings.limits.push({ key: 'Cooldowns.' + b + '.per', category: 'developer', group: 'Rate limits',
      label: b + ': refill window (s)', kind: 'number', min: 0.5, max: 3600, live: true, value: 60, default: 60,
      source: 'config', stricter: 'up', about: 'Placing a contract, and a sentence long enough to wrap the row.',
      inflight: 'Read each time it is used.' });
    settings.limits.push({ key: 'Cooldowns.' + b + '.burst', category: 'developer', group: 'Rate limits',
      label: b + ': requests held', kind: 'number', integer: true, min: 1, max: 200, live: true, value: 2,
      default: 2, source: 'config', stricter: 'down', inflight: 'Read each time it is used.' });
  });
  settings.readonly.push({ key: 'convar:crimson_hitman_alert_webhook', category: 'developer',
    group: 'Edit in config.lua', label: 'Secret: crimson_hitman_alert_webhook', kind: 'text', denied: true,
    secret: true, value: 'not set', source: 'config',
    readonly: 'The Discord webhook for alerts: a secret, set in server.cfg with set (never setr).' });
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
      // The Deadline card: the exact time left, quick picks, minutes, a
      // reason, Extend and Shorten.
      deadline: { left: 37230, stopped: true, adjustable: true, maxAdjust: 86400, minLeft: 300 },
      // The staff tools: notes, removals and edits with the longest things
      // they hold, and a reason that may be replaced.
      staff: { noteMax: 300, removable: true,
        notes: [{ id: 'cs1', at: NOW - 900, by: LONG, text: REASON + ' ' + 'x'.repeat(200) },
          { id: 'cs2', at: NOW - 600, by: 'Staff', text: 'a_note_with_no_spaces_to_break_at_' + 'x'.repeat(200) }],
        removals: [{ id: 'cs3', at: NOW - 300, who: 'operative Ghost of the Eastern Docks', by: LONG, reason: REASON,
          stakeReturned: true, blocked: true }],
        edits: [{ id: 'cs4', at: NOW - 200, field: 'reason', by: LONG, reason: REASON }],
        text: { editable: true, mode: 'freetext', max: 120, edited: true } },
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
        now: { contract: 'none', lines: { held: 1, settled: 0, missing: 2 } }, state: 'open', created_at: NOW - 900 },
      // A player's report: the longest note, and a thread of twenty long
      // messages with no spaces in some to break at.
      { id: 'rv00000002', kind: 'player_report', about: 'a player reported this contract, or a message thread on it, '
          + 'from the app: read their note and the messages, deal with it in the city, then dismiss with what was done',
        contract: 'ct10000002', parties: [{ role: 'from', who: 'operative Ghost of the Eastern Docks' },
          { role: 'reported', who: 'the client' }], items: [],
        known: { role: 'hitman', note: REASON + ' ' + REASON, thread: true, excerpt: (function () {
          const out = [];
          for (let i = 0; i < 20; i++) {
            out.push({ alias: i % 2 ? 'Placer' : 'Ghost of the Eastern Docks', at: NOW - (20 - i) * 60,
              body: i % 3 ? REASON : 'https://averyveryverylongaddresswithnospacesinittobreakatanywhere.example/x' });
          }
          return out;
        })() },
        now: { contract: 'accepted' }, state: 'open', created_at: NOW - 300 }
    ] } },
    // The settings history: long labels, long values, a list, a secret.
    'logs.settings': { ok: true, data: { next: 99, rows: (function () {
      const out = [];
      for (let i = 0; i < 25; i++) {
        out.push({ ts: NOW - i * 300, key: i % 5 === 0 ? 'Advisory.RecipientJobNames' : 'Limits.SameCreatorSameTargetCooldownSeconds',
          label: 'What it does, in a sentence long enough to wrap across the row at the narrowest width',
          old: i % 5 === 0 ? ['police', 'sheriff', 'bcso', 'fib', 'trooper', 'sasp', 'ranger', 'sast'] : 1800,
          new: i % 5 === 0 ? ['police'] : 3600, by: i % 2 ? 'a staff member' : 'ADMIN00000001',
          reset: i % 7 === 0 || undefined, ref: 'h' + i });
      }
      out.push({ ts: NOW - 9000, key: 'convar:crimson_hitman_webhook', secret: true, by: 'a staff member' });
      return out;
    })() } },
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
    player: function (data) { return playerView(data.subject === '456'); },
    history: null };
  function playerView(plain) {
    const view = { ok: true, data: { player: { cid: 'TARGET01', name: LONG, online: true, server: 123, ref: 'p1_100001' },
      contracts: rows.slice(0, 10).map(function (r) {
        return { id: r.id, state: r.state, role: 'target', anonymous: false, target: r.target,
          created_at: r.created_at, resolution: r.resolution };
      }),
      stats: { completed: 52, failed: 3, placed: 9, survived: 4, rate: 94, standing: 'Notorious' },
      owed: [{ id: 'ct10000005:2', contract: 'ct10000005', source: 'bank', amount: 1250000, state: 'held', owes: 1250000,
        queued: true }],
      pending: 2, notices: { count: 2, titles: ['Contract closed', REASON] },
      playtime: { hours: 1234.5, grandfathered: false, counted: true, counting: true, floor: 5,
        from: 'provider' },
      // Suspended with the longest reason (its Lift measured), not protected
      // (the Protect form, its unit picks and boxes measured), and Pay's cap.
      suspended: { since: NOW - 600, until: NOW + 30 * 86400, reason: REASON, by: 'ADMIN001' },
      payMax: 100000 } };
    // Neither suspended nor protected: both forms, their picks and boxes.
    if (plain) view.data.suspended = null;
    return view;
  }
  Object.assign(answers, {
    // A player's history card, with the longest things each holds.
    history: { ok: true, data: {
      counts: { placed: 1234, taken: 5678, completed: 4321, cancelled: 99, onThem: 12, boughtOut: 3 },
      recent: rows.slice(0, 10).map(function (r) {
        return { id: r.id, state: r.state, roles: ['client', 'hitman'], anonymous: true, created_at: r.created_at,
          client: LONG, target: LONG };
      }),
      buyouts: { paid: 12, amount: 12500000 },
      informants: { count: 40, spent: 1000000, informant: 20, placerInformant: 10, locationTip: 10 },
      money: { in: [{ kind: 'payouts', amount: 125000000 }, { kind: 'buyout premiums', amount: 3000000 },
                    { kind: 'staff payments', amount: 100000 }],
               out: [{ kind: 'rewards put up', amount: 99000000 }, { kind: 'anonymity fees', amount: 25000 }] },
      measures: [
        { kind: 'suspend', from: NOW - 600, until: NOW + 30 * 86400, state: 'in force', reason: REASON, by: 'ADMIN001' },
        { kind: 'protect', from: NOW - 60, state: 'in force', reason: REASON },
        { kind: 'freeze', from: NOW - 90000, ended: NOW - 80000, state: 'lifted', reason: REASON, by: 'ADMIN001' }],
      anonymous: 4, identified: true, retentionDays: 30 } },
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
      target: { cid: 'TARGET01', name: 'Dana Reyes' }, hitmen: [] } },
    // A party's card, with the longest things it holds.
    playerView: { ok: true, data: { role: 'hitman', shown: true, alias: 'Ghost of the Eastern Docks',
      note: 'No longer on it (abandoned): this is the card the board would show them.',
      viewer: { cid: 'HITMAN01', name: LONG },
      view: { id: 'ct10000001', role: 'hitman', targetName: LONG, reason: REASON, staffEdited: true,
        timeLeft: 'More than 2 hours left', reward: { baseline: 1250000, bonus: 625000,
          sources: { bank: 1250000, cash: 0, dirty: 0 }, goods: { count: 3, labels: ['a_long_item_name_1'] } },
        penaltyAmount: 25000, myAlias: 'Ghost of the Eastern Docks', creatorAnonymous: true,
        locationTip: { left: 2, waitSeconds: 0, note: REASON } } } }
  });
  // Target limits (server/targetlimits.lua), with the longest things each holds.
  const TL_KEYS = [
    ['TargetCooldownAfterResolveSeconds', 'Wait after a contract on them ends', 's', 0, 604800, 1800],
    ['SameCreatorSameTargetCooldownSeconds', 'Wait before the same placer names them again', 's', 0, 604800, 7200],
    ['TargetCooldownAfterCompletionSeconds', 'Wait after a completed contract on them', 's', 0, 2592000, 0],
    ['MaxActiveContractsPerTarget', 'Live contracts on them at once', 'contracts', 1, 50, 2],
    ['MaxContractsPerTargetPerDay', 'Contracts placed on them in 24 hours', 'contracts', 0, 100, 0],
    ['MaxContractsPerTargetPerWeek', 'Contracts placed on them in 7 days', 'contracts', 0, 500, 0]
  ].map(function (k) { return { key: k[0], label: k[1], unit: k[2], min: k[3], max: k[4], value: k[5] }; });
  const tlJobs = [];
  for (let i = 0; i < 6; i++) {
    tlJobs.push({ job: i === 0 ? 'a_long_job_name_of_32_characters' : 'job_' + i, at: NOW,
      limits: { TargetCooldownAfterResolveSeconds: 604800, MaxContractsPerTargetPerWeek: 500 },
      effective: { TargetCooldownAfterResolveSeconds: 604800, SameCreatorSameTargetCooldownSeconds: 7200,
        TargetCooldownAfterCompletionSeconds: 2592000, MaxActiveContractsPerTarget: 50,
        MaxContractsPerTargetPerDay: 100, MaxContractsPerTargetPerWeek: 500 } });
  }
  answers.targetLimits = { ok: true, data: { keys: TL_KEYS, jobs: tlJobs, ignored: 0, jobMax: 32,
    extendMax: 43200, overrideMaxHours: 8760 } };
  answers.targetJobCount = { ok: true, data: { job: 'a_long_job_name_of_32_characters', count: 1234 } };
  answers.targetStatus = { ok: true, data: { player: { name: LONG, cid: 'TARGET01', online: true, ref: 'p1_1' },
    status: { live: 2, day: 12, week: 140, dayAll: 20, weekAll: 300, cooldownLeft: 2591000,
      cooldownRule: 'TargetCooldownAfterCompletionSeconds', cooldownFrom: 'job', exempt: false,
      job: 'a_long_job_name_of_32_characters', jobFrom: 'last known',
      source: { TargetCooldownAfterResolveSeconds: 'job', MaxContractsPerTargetPerDay: 'player' },
      limits: { TargetCooldownAfterResolveSeconds: 604800, SameCreatorSameTargetCooldownSeconds: 7200,
        TargetCooldownAfterCompletionSeconds: 2592000, MaxActiveContractsPerTarget: 50,
        MaxContractsPerTargetPerDay: 100, MaxContractsPerTargetPerWeek: 500 },
      adjustment: { until_at: NOW + 86400, override: { exempt: false, limits: {}, until_at: NOW + 3600,
        reason: REASON } } } } };
  // The one list of contracts: by target (Target limits' link), or one
  // person's with their part on each, or everybody's.
  const everyone = answers.contracts;
  const byTarget = { ok: true, data: { page: 1, pages: 4, total: 100, targets: 40,
    rows: rows.slice(0, 20).map(function (r, i) {
      return Object.assign({}, r, { state: i % 2 ? 'active' : 'accepted', group: 't' + Math.floor(i / 3),
        target: i < 3 ? LONG : r.target, onTarget: 3, frozen: i % 4 === 0 });
    }) } };
  const theirs = { ok: true, data: { page: 1, pages: 2, total: 30,
    rows: rows.slice(0, 20).map(function (r, i) {
      return Object.assign({}, r, { role: ['target', 'client', 'hitman'][i % 3], roleAnonymous: i % 3 === 1 });
    }) } };
  answers.presets = { ok: true, data: { presets: ['Strict', 'Relaxed', 'Roleplay-heavy', 'Current'].map(function (n, i) {
    return { name: n, builtIn: i < 3, about: REASON, same: i, refused: i === 0 ? [{ key: 'K', label: LONG, why: REASON }] : [],
      changes: i === 3 ? [] : [0, 1, 2, 3, 4, 5].map(function (j) {
        return { key: 'Limits.Key' + j, label: 'A setting with a long label number ' + j + ' ' + LONG,
          from: String(1000000 + j), to: String(2000000 + j) }; }) };
  }) } };
  answers.contracts = function (data) {
    if (data.byTarget) return byTarget;
    if (data.ref || data.person) return theirs;
    return everyone;
  };
  // The hitman organisation, with the longest things each part holds.
  const POWERS = [];
  ['members', 'roles', 'pay', 'money', 'contracts', 'locations', 'notices', 'settings', 'delegation'].forEach(function (a, i) {
    for (let j = 0; j < 3; j++) {
      POWERS.push({ code: a.charAt(0).toUpperCase() + i + '' + j, area: a, label: 'A power with a long name ' + i + j,
        about: 'Lets the boss do something that takes a sentence long enough to wrap across the cell.',
        office: j === 0, limits: j === 1 ? ['WithdrawMax', 'MaxMembers'] : undefined });
    }
  });
  const ORG_MEMBERS = [];
  for (let i = 0; i < 12; i++) {
    ORG_MEMBERS.push({ ref: 'm' + i + '_1000', name: i === 0 ? LONG : 'Member ' + i, grade: i < 2 ? 3 : 1,
      role: i < 2 ? 'Boss of the whole outfit' : 'Hitman', online: i % 2 === 0, joined: NOW - 86400 * i,
      lastSeen: NOW - 600 * i, boss: i < 2 || undefined, locked: i === 3 || undefined,
      suspendedUntil: i === 4 ? NOW + 3600 : undefined, grants: i === 5 ? { M00: { by: 'staff' } } : {},
      denies: {}, limits: { maxAtOnce: 2 }, held: { M00: true } });
  }
  answers.orgGet = { ok: true, data: { enabled: true, loaded: true, job: 'hitman', label: 'The ' + LONG,
    type: 'leo', requireJob: true,
    roles: [
      { grade: 3, name: 'boss', label: 'Boss of the whole outfit', pay: 125000, boss: true, members: 2,
        powers: { M00: { by: 'staff' } }, cut: 10, access: {} },
      { grade: 2, name: 'lieutenant_with_a_long_name', label: 'Lieutenant ' + LONG, pay: 5000, boss: true, members: 0,
        powers: {} },
      { grade: 1, name: 'hitman', label: 'Hitman', pay: 100, members: 10, powers: {} }],
    members: ORG_MEMBERS,
    ceiling: { role: { 3: { M00: 'allow', M01: 'allow' } }, member: { m0_1000: { C30: 'deny' }, m5_1000: { M00: 'allow' } } },
    cuts: { payout: 10, stake: 5, buyout: 0, byRole: { 1: 5 }, byMember: { X: 3 } },
    limits: { MaxMembers: 30, WithdrawMax: 5000, TotalCutCapPercent: 40, CutMaxPercent: 25, StakeCutMaxPercent: 20,
      BuyoutCutMaxPercent: 20, NoticeMaxLength: 400, HireRadius: 3.5, PayMax: 100000 },
    officeStaff: { M00: true, C30: true }, officeBoss: { R10: true },
    notice: { text: REASON + ' ' + REASON, at: NOW - 120 },
    access: { 1: { maxReward: 2000000000, rule: 'alive', maxAtOnce: 50, cooldownMinutes: 10080 } },
    balance: 1234567890, bank: true,
    applications: [{ id: 'hitman:app:1', name: LONG, body: REASON + ' ' + REASON, at: NOW - 300,
      form: [{ q: REASON.slice(0, 200), a: REASON + ' ' + REASON }], note: { text: REASON, by: 'Staff' } }],
    powers: POWERS, warnings: ['qbx:max_jobs_per_player is 1: members lose their other job when hired.'],
    layout: { labels: { members: 'Crew' }, hidden: { funds: [1] } },
    // The organisation extras, every one on, at their longest.
    extras: { OrgContracts: true, AcceptApproval: true, Probation: true, Duty: true, Channel: true, Dossiers: true,
      work: {
        contracts: [{ id: 'ct10000001', state: 'waiting', targetName: LONG, worth: 2000000000, expiresIn: 86400, staked: true },
          { id: 'ct10000002', state: 'assigned', targetName: LONG, worth: 5000, expiresIn: 600,
            member: { ref: 'm0_1000', name: LONG }, dossier: { notes: REASON + ' ' + REASON,
              rulesText: 'Discreet: no witnesses, nothing in public', spot: { label: LONG } } }],
        approvals: [{ id: 'ap1_1000', contractId: 'ct10000003', worth: 2000000000, expiresIn: 900, probation: true,
          member: { ref: 'm0_1000', name: LONG } }],
        spots: [{ id: 'hitman:meeting:1', label: LONG }] },
      channel: [{ id: 'msg:1', from: LONG, body: REASON + ' ' + REASON, at: NOW - 60, member: 'm0_1000' }] },
    // And the extras 2, every one on, at their longest.
    extras2: { Armory: true, Stats: true, Discipline: true, Recruitment: true,
      armory: { items: [{ slot: 1, name: 'weapon_carbinerifle_mk2', label: LONG, count: 1000 }],
        allowed: ['weapon_carbinerifle_mk2', 'bandage', 'lockpick', 'armour_heavy_plate_vest'],
        limits: { '1': 1000, '3': 1000 }, withdrawMax: 1000,
        log: [{ at: NOW - 60, dir: 'out', item: 'weapon_carbinerifle_mk2', count: 1000, who: LONG }] },
      leaderboard: [{ rank: 1, name: LONG, ref: 'm0_1000', completed: 123456, failed: 12345, earned: 2000000000,
        rate: 100, avgMinutes: 123456, band: 'over 8 h' }],
      discipline: [{ ref: 'm0_1000', name: LONG, strikes: 99, rows: [{ id: 'dc1_1000', kind: 'strike',
        reason: REASON, at: NOW - 60, active: true, by: 'A boss', consequence: 'suspended 720 h, demoted' },
        { id: 'dc2_1000', kind: 'warning', reason: REASON, at: NOW - 60, by: 'Staff', overturned: NOW - 30,
          overturnReason: REASON }] }],
      disciplineRules: { decayDays: 3650, suspendAt: 100, suspendHours: 720, demoteAt: 100 },
      form: [REASON.slice(0, 200), REASON.slice(0, 200)], formMax: 5 } } };
  answers.orgFunds = { ok: true, data: { balance: 1234567890, bank: true, rows: (function () {
    const out = [];
    for (let i = 0; i < 15; i++) {
      out.push({ kind: ['staff_deposit', 'withdraw', 'cut', 'bonus'][i % 4], amount: 125000 * (i + 1), at: NOW - i * 600,
        reason: REASON, contract: i % 3 ? 'ct' + String(10000000 + i) : null, actor: 'ADMIN001' });
    }
    return out;
  })() } };
  answers['logs.org'] = { ok: true, data: { rows: (function () {
    const out = [];
    for (let i = 0; i < 20; i++) {
      out.push({ ts: NOW - i * 60, action: i % 2 ? 'org_grant' : 'org_member_role_with_a_long_name',
        by: 'a staff member', detail: { subject: 'role', id: '3', power: 'M00', before: 'off', after: 'allow',
          reason: REASON } });
    }
    return out;
  })() } };
  answers.placeMyPosition = { ok: true, data: { x: -1234.567, y: 4567.891, z: 30.12, heading: 359.4 } };
  // Every kind of place (placeList), with the longest labels and both disposal spots' states.
  answers.placeList = { ok: true, data: { readable: true, kinds: (function () {
    const ORG = { label: true, radius: true, blip: true, enabled: true };
    function org(id, label, one, rows, single) {
      return { id: id, group: 'org', label: label, one: one, icon: 'building', fields: ORG, labelMax: 64,
        single: !!single, radius: { min: 0.5, max: 50, default: 2 }, switch: 'Organisation.Enabled', rows: rows };
    }
    function rp(id, label, rows) {
      return { id: id, group: 'npc', label: label, one: id + ' place', icon: 'user-secret',
        fields: { label: true, enabled: true }, labelMax: 40, labelOptional: true, reset: true, max: 20,
        switch: 'Roleplay.NpcPlaces.Enabled', rows: rows, on: true, using: rows.length ? 'panel' : 'config',
        defaults: [{ x: -1171.0, y: -1572.5, z: 4.66, h: 125 }], key: 'Intel.Rumours.Locations' };
    }
    function dp(id, label, one, rows) {
      return { id: id, group: 'disposal', label: label, one: one, icon: 'truck', fields: {}, single: true, max: 1,
        rows: rows, defaults: [], on: true, using: rows.length ? 'panel' : 'config',
        note: 'Body disposal cannot start a step until both are set.' };
    }
    return [
      org('office', 'Boss office', 'boss office', [{ id: 'hitman:office:1', kind: 'office', label: 'Back room of ' + LONG,
        x: -1234.56, y: 4567.89, z: 30.12, heading: 359, radius: 12.5, blip: true, enabled: true }], true),
      org('signup', 'Sign-up spots', 'sign-up spot', []),
      org('meeting', 'Meeting and handover spots', 'meeting spot', [{ id: 'hitman:meeting:1', kind: 'meeting',
        label: 'Docks', x: 1.5, y: -2.5, z: 3, heading: 0, radius: 2, blip: false, enabled: false }]),
      org('npc', 'NPC spots', 'NPC spot', []),
      org('place', 'Other organisation places', 'place', []),
      rp('broker', 'Broker NPC', [{ id: 'map:broker:1', kind: 'broker', label: 'Pier of ' + LONG.slice(0, 30),
        x: -1234.5, y: 4567.8, z: 30.1, heading: 359.4, enabled: true }]),
      rp('informant', 'Informant NPC', []),
      dp('disposal_vehicle', 'Disposal vehicle spawn', 'the vehicle spawn', [{ id: 'place:disposal_vehicle:1',
        kind: 'disposal_vehicle', label: 'Disposal vehicle spawn', x: -1234.5, y: 4567.8, z: 30.1, heading: 359.4,
        enabled: true }]),
      dp('disposal_drop', 'Body drop-off', 'the drop-off', [])
    ];
  })() } };
  // The drawer's Change reward and Reassign, with the largest figures.
  answers.rewardPreview = function (data) {
    const base = { max: 100000000, slot: 3, reward: 1234567890, total: 1234567890, mostLower: 1234567889,
      staffAdded: 987654321 };
    if (data.by === undefined) return { ok: true, data: base };
    return { ok: true, data: Object.assign(base, { after: 1234567890 + data.by,
      toStaff: data.by < 0 ? 987654321 : undefined, toPlacer: data.by < 0 ? 12345678 : undefined }) };
  };
  answers.reassignPreview = { ok: true, data: { stakeWaived: false, stake: 25000,
    operatives: ['Ghost of the Eastern Docks', 'Second of the Western Quays', LONG] } };
  // Body disposal: steps with the longest ids and every chip, and both spots.
  answers.disposalList = { ok: true, data: { enabled: true, limitSeconds: 86400, onTimeout: 'reduced',
    spots: { vehicle: { x: -1234.5, y: 4567.8, z: 30.1, h: 359.4 } },
    steps: rows.slice(0, 6).map(function (r, i) {
      return { id: 'disposal:' + r.id + ':' + (i + 1), contract: r.id, slot: i + 1, hitman: 'HITMAN0' + i,
        stage: i % 2 ? 'loaded' : 'body', secondsLeft: 86399 - i * 3600, held: i % 2 === 0, vehicle: i % 3 !== 0,
        respawns: i };
    }) } };
  // Every measure in force (measures), with the longest names and reasons, each kind.
  answers.measures = { ok: true, data: { rows: rows.slice(0, 6).map(function (r, i) {
    return { kind: 'suspend', ref: 'f' + i, name: i === 0 ? LONG : 'Dana Reyes ' + i, cid: 'CITIZEN' + i,
      online: i % 2 === 0, since: NOW - 600 * i, until: i % 2 ? NOW + 86400 : null, reason: REASON, by: 'ADMIN001' };
  }).concat([{ kind: 'protect', ref: 'f9', name: LONG, since: NOW - 60, reason: REASON },
    { kind: 'freeze', ref: 'f10', name: LONG, since: NOW - 30, reason: REASON },
    { kind: 'limit', ref: 'f11', name: LONG, since: NOW - 20, reason: REASON, exempt: true }]) } };
  // The organisation's settings and the places, with the longest labels.
  settings.features.push({ key: 'Organisation.Enabled', category: 'organisation', group: 'Organisation',
    area: 'organisation', label: 'Hitman organisation', kind: 'switch', live: true, value: true, default: false,
    source: 'panel', about: 'A real qbx_core job with roles, a boss menu and Boss permissions.' });
  settings.limits.push({ key: 'Organisation.Limits.WithdrawMax', category: 'organisation',
    group: 'Organisation: Boss limits', area: 'organisation', label: 'Largest withdrawal ($)', kind: 'number',
    integer: true, min: 0, max: 10000000, live: true, value: 5000, default: 5000, source: 'config' });
  settings.limits.push({ key: 'Intel.Rumours.Locations', place: 'point', category: 'rules-limits', group: 'Intel: Rumours and broker',
    area: 'extras', label: 'Broker NPC places', kind: 'list', whole: true, live: true,
    value: ['-1171.0, -1572.5, 4.66, 125.0', '1240.6, -3179.2, 7.1, 270.0'], default: [], source: 'config' });
  settings.limits.push({ key: 'Intel.SafeZones.Zones', place: 'zone', category: 'rules-targeting',
    group: 'Intel: Tip safe zones', area: 'intel', label: 'Safe zones (x, y, radius, name)', kind: 'list',
    whole: true, live: true, value: ['300, -590, 80, Pillbox Hill Medical Center and the car park'], default: [],
    source: 'config' });
  settings.limits.push({ key: 'Limits.JailZone.x', place: 'jail', category: 'rules-limits', group: 'Contract limits', area: 'placing',
    label: 'Prison grounds centre, x', kind: 'number', min: -10000, max: 10000, live: true, value: 1700, default: 1700,
    source: 'config' });
  window.GetParentResourceName = function () { return 'crimson-hitman'; };
  window.__requests = [];
  window.fetch = function (url, options) {
    const event = url.split('/').pop();
    const body = JSON.parse((options && options.body) || '{}');
    // Records › Logs is one op; each log is its area, answered as logs.<area>.
    const op = body.op === 'logs' && body.data && body.data.area ? 'logs.' + body.data.area : body.op;
    window.__requests.push({ event: event, op: op });
    let answer = event === 'adminRequest' ? (answers[op] || { ok: true }) : { ok: true };
    if (typeof answer === 'function') answer = answer(body.data || {});
    return Promise.resolve({ json: function () { return Promise.resolve(acrossTheWire(answer)); } });
  };
}

const ACCESS = { canWrite: true, canIdentify: true, pageSize: 25, refreshSeconds: 10, recovery: 'ready',
  version: '1.1.0', canDevelop: true, developerAce: 'crimson.developer',
  developerHint: 'To give the Developer section to its own people: grant it with add_ace group.admin '
    + 'crimson.developer allow, pasted into the server console until the next restart.',
  permissions: [
    { ace: 'crimson.admin', name: 'Staff ACE (Config.Admin.Ace)', held: true,
      unlocks: 'Opens this panel and the staff commands, and is the only ACE that changes anything.',
      grant: 'Grant it with add_ace group.admin crimson.admin allow, pasted into the server console.' },
    { ace: 'crimson.identity', name: 'Identity ACE (Config.Admin.IdentityAce)', held: false,
      unlocks: 'Shows who is behind an anonymous party, and citizen ids, everywhere in the panel.',
      grant: 'Grant it with add_ace identifier.license:<their licence> crimson.identity allow for one person, or '
        + 'to a group of its own (add_ace group.<name> crimson.identity allow); not group.admin.' },
    { ace: 'crimson.developer', name: 'Developer ACE (Config.Admin.DeveloperAce)', held: false,
      unlocks: 'Opens the Developer section.', grant: 'Grant it with add_ace group.admin crimson.developer allow.' },
    { ace: 'crimson.moderator', name: 'Moderator ACE (Config.Admin.ModeratorAce)', held: false,
      unlocks: 'Opens this panel to read everything the staff ACE reads, scrubbed as without the identity ACE, and '
        + 'to freeze and unfreeze, suspend, protect, void and move a deadline.',
      grant: 'Grant it with add_ace group.moderator crimson.moderator allow, pasted into the server console.' }
  ] };

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

/* A view, as a link or the sidebar reaches it: through the page's own show
   (a view has one name; 'logs:<area>' and 'inbox:<filter>' choose a filter
   there). The sidebar's own buttons are measured on their own below. */
async function go(page, view) {
  await page.evaluate(function (v) { window.CH_ADMIN_SHOW(v); }, view);
  await page.waitForTimeout(40);
}

async function openAt(browser, width, height) {
  const page = await browser.newPage({ viewport: { width: width, height: height } });
  await page.route('https://cdnjs.cloudflare.com/**', function (route) { return route.abort(); });
  await page.addInitScript(serverStub);
  await page.goto('file://' + PAGE);
  await page.waitForFunction(function () { return window.CH_ADMIN_READY === true; });
  await page.waitForTimeout(200);
  return page;
}

const REASON_LONG = 'Event tonight at the pier: no contracts there until midnight, and every hitman '
  + 'stays clear of the square while it runs.';

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
    { w: 1024, h: 768, tablesFit: false },
    // A phone: every section, nothing sideways; tables scroll in their frame.
    { w: 390, h: 844, tablesFit: false, phone: true }
  ];
  // Every view of every section (Game rules once per type of setting), and
  // a selected player's tabs once one is looked up.
  const sections = ['inbox', 'overview', 'announce', 'players', 'pmeasures', 'pmoney', 'pplaytime',
    'phistory', 'pdiag', 'their-contracts', 'measures', 'contracts', 'tldefaults', 'tljobs', 'tlplayer',
    'contracts:bytarget', 'gear:contracts', 'gear:tljobs', 'rules', 'presets', 'changed', 'logs:settings', 'rules:timer', 'rules:money', 'rules:limit', 'rules:list', 'rules:switch',
    'orgsetup', 'orgroles', 'orgmembers', 'orgapps', 'orgfunds', 'orgaccess', 'orgnotices', 'orgwork', 'orgarmory',
    'orgrecord', 'orgturf', 'logs:org',
    'bpmatrix', 'bplimits', 'bpoffice', 'logs:grants', 'locations', 'logs:audit', 'alerts', 'health', 'devsettings',
    'console', 'tools', 'help', 'howto', 'permissions'];

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
               overlap: brand.right > badges.left + 1 && badges.width > 0
                 && brand.bottom > badges.top + 1 && badges.bottom > brand.top + 1, W: window.innerWidth };
    });
    it(at + ': the panel takes most of the window, with its close button in it', function () {
      truthy(frame.width >= frame.W * 0.9 - 1 || frame.width >= 1700, 'the panel is ' + Math.round(frame.width) + 'px wide');
      truthy(frame.closeInside, 'the close button is outside the panel');
      truthy(!frame.overlap, 'the title runs under the badges');
    });

    // The sidebar: its sections, under their group headings, each opening on
    // a click; on a phone, folded into one menu button.
    const sidebar = await page.evaluate(function () {
      const nav = document.getElementById('nav');
      const menu = document.getElementById('nav-menu');
      return { navShown: getComputedStyle(nav).display !== 'none', menuShown: getComputedStyle(menu).display !== 'none',
        heads: Array.prototype.map.call(document.querySelectorAll('.nav-head'), function (n) { return n.textContent; }) };
    });
    if (size.phone) {
      await page.click('#nav-menu');
      await page.waitForTimeout(60);
    }
    await page.click('#grp-rules');
    await page.waitForTimeout(150);
    const afterClick = await page.evaluate(function () {
      const sub = document.getElementById('subnav');
      const tabs = sub.querySelectorAll('.sub-btn');
      const tops = Array.prototype.map.call(tabs, function (t) { return Math.round(t.getBoundingClientRect().top); });
      return { here: (document.querySelector('.crumb.is-here') || {}).textContent,
        oneLine: tops.every(function (t) { return t === tops[0]; }),
        navShown: getComputedStyle(document.getElementById('nav')).display !== 'none' };
    });
    it(at + ': the sidebar holds its sections under Daily, Setup, Records and Developer'
      + (size.phone ? ', folded into one menu' : ''), function () {
      truthy(sidebar.heads.join(',') === 'Daily,Setup,Records,Developer', sidebar.heads.join(','));
      if (size.phone) {
        truthy(!sidebar.navShown && sidebar.menuShown, 'the sidebar is not folded into its menu');
        truthy(!afterClick.navShown, 'the menu stays open after a section is picked');
      } else {
        truthy(sidebar.navShown && !sidebar.menuShown, 'the sidebar is not shown');
      }
      truthy(afterClick.here === 'Areas', 'Game rules did not open: ' + afterClick.here);
      if (size.phone) truthy(afterClick.oneLine, 'the sub-tabs wrap onto more than one line');
    });

    for (const section of sections) {
      if (section === 'their-contracts') {
        // The one list of contracts, filtered to the player looked up.
        await go(page, 'players');
        await page.click('button[data-act="pl-contracts"]');
      } else if (section.indexOf('gear:') === 0) {
        // A screen with its own settings opened in place by its gear.
        await go(page, section.slice(5));
        await page.waitForTimeout(80);
        await page.click('button[data-act="gear"]');
      } else {
        await go(page, section);
      }
      await page.waitForTimeout(120);
      if (section === 'players') {
        await page.fill('#pl-q', '123');
        await page.press('#pl-q', 'Enter');
        await page.waitForTimeout(120);
      }
      if (section === 'tlplayer') {
        // Measured with a player looked up and Reset cooldown armed.
        await page.fill('#tp-q', '123');
        await page.press('#tp-q', 'Enter');
        await page.waitForTimeout(120);
        await page.fill('#tp-reason', REASON_LONG.slice(0, 120));
        await page.click('button[data-act="tp-reset"]');
        await page.waitForTimeout(60);
      }
      if (section === 'tljobs') {
        // Measured with a job typed, counted, and Reset all armed naming it.
        await page.fill('#tja-job', 'a_long_job_name_of_32_characters');
        await page.waitForTimeout(400);
        await page.fill('#tja-reason', REASON_LONG.slice(0, 120));
        await page.click('button[data-act="tja-reset-all"]');
        await page.waitForTimeout(60);
      }
      if (section === 'health') {
        await page.click('button[data-act="tl-diag"]');
        await page.waitForTimeout(120);
      }
      if (section === 'pdiag') {
        await page.click('button[data-act="pl-diag"]');
        await page.waitForTimeout(120);
      }
      if (section === 'rules') {
        // An area open, with a row's Details open.
        await page.click('button[data-act="gr-area"][data-value="other"]');
        await page.waitForTimeout(60);
        await page.click('.st-row button[data-act="st-details"]');
        await page.waitForTimeout(60);
      }
      if (section === 'help') {
        await page.click('button[data-act="help-all"]');
        await page.waitForTimeout(60);
      }
      if (section === 'orgroles') {
        await page.click('button[data-act="org-role-open"][data-id="3"]');
        await page.waitForTimeout(60);
      }
      if (section === 'orgmembers') {
        await page.click('button[data-act="org-member-open"][data-id="m0_1000"]');
        await page.waitForTimeout(60);
      }
      if (section === 'bpmatrix') {
        // Measured with changes waiting, and Save armed naming them.
        await page.click('button[data-act="bp-cell"][data-id="role:3"][data-power="M02"]');
        await page.click('button[data-act="bp-cell"][data-id="member:m0_1000"][data-power="M00"]');
        await page.waitForTimeout(40);
        await page.click('button[data-act="bp-save"]');
        await page.waitForTimeout(60);
      }
      if (section === 'locations') {
        await page.click('button[data-act="loc-mypos"][data-value="signup"]');
        await page.waitForTimeout(120);
        // And the drop-off filled from where staff stand, its Save armed.
        await page.click('button[data-act="loc-mypos"][data-value="disposal_drop"]');
        await page.waitForTimeout(120);
        await page.click('button[data-act="loc-save"][data-value="disposal_drop"]');
        await page.waitForTimeout(60);
      }
      if (section === 'contracts') {
        // Measured with a disposal step's Skip armed.
        await page.click('button[data-act="dp-skip"]');
        await page.waitForTimeout(60);
      }
      if (section === 'alerts') {
        // Measured with Acknowledge all shown armed, its confirm showing.
        await page.click('button[data-act="al-ack-all"]');
        await page.waitForTimeout(60);
      }
      if (section === 'announce') {
        // Measured with a long notice typed and Send armed, its confirm showing.
        await page.fill('#an-text', REASON_LONG);
        await page.click('button[data-act="an-send"]');
        await page.waitForTimeout(60);
      }
      if (section === 'logs:settings') {
        // Measured with an Undo armed.
        await page.click('button[data-act="hs-undo"]');
        await page.waitForTimeout(60);
      }
      if (section === 'features') {
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

    // A player neither suspended nor protected: the Suspend and Protect
    // forms, their picks and boxes, with Pay and the history card, and the
    // Suspend button armed with its confirm showing.
    await go(page, 'players');
    await page.fill('#pl-q', '456');
    await page.press('#pl-q', 'Enter');
    await page.waitForTimeout(150);
    await go(page, 'pmeasures');
    await page.waitForTimeout(100);
    await page.click('button[data-act="ps-days"][data-value="7"]');
    await page.waitForTimeout(60);
    await page.fill('#ps-reason', 'Contract spam');
    await page.click('button[data-act="ps-suspend"]');
    await page.waitForTimeout(60);
    const staffForms = await page.evaluate(measure, { tablesFit: size.tablesFit });
    const staffArmed = await page.evaluate(function () {
      const b = document.querySelector('button[data-act="ps-suspend"]');
      return { armed: b && b.classList.contains('is-armed'), forms: !!document.getElementById('pp-amount')
        && !!document.getElementById('ps-days') };
    });
    await go(page, 'pmoney');
    await page.waitForTimeout(100);
    const payForm = await page.evaluate(measure, { tablesFit: size.tablesFit });
    const payDrawn = await page.evaluate(function () { return !!document.getElementById('pay-amount'); });
    it(at + ': a player\'s Suspend, Protect and Pay forms fit, with Suspend armed', function () {
      truthy(staffArmed.forms && payDrawn, 'the three forms are drawn');
      truthy(staffArmed.armed, 'Suspend was not armed');
      none(staffForms.concat(payForm), 'staff forms');
    });

    // Target limits: the armed write says what it does, and a row of
    // Current contracts opens the contract's own drawer.
    await go(page, 'tlplayer');
    await page.fill('#tp-q', '123');
    await page.press('#tp-q', 'Enter');
    await page.waitForTimeout(120);
    await page.fill('#tp-reason', 'ticket');
    await page.click('button[data-act="tp-counts"]');
    await page.waitForTimeout(60);
    const tlArmed = await page.evaluate(function () {
      const b = document.querySelector('button[data-act="tp-counts"]');
      const cfm = b && b.querySelector('.cfm');
      return { armed: !!b && b.classList.contains('is-armed'),
               label: cfm && getComputedStyle(cfm).visibility === 'visible' ? cfm.textContent : '',
               sent: window.__requests.filter(function (r) { return r.op === 'targetCounts'; }).length };
    });
    it(at + ': Target limits: a write armed says Click again, and sends nothing yet', function () {
      truthy(tlArmed.armed, 'not armed');
      truthy(/Click again/.test(tlArmed.label), tlArmed.label);
      truthy(tlArmed.sent === 0, 'sent on one click');
    });
    await page.click('#nav-contracts-bytarget');
    await page.waitForTimeout(150);
    await page.click('#ct-results tr.row');
    await page.waitForTimeout(200);
    const tlDrawer = await page.evaluate(function () {
      const d = document.getElementById('drawer');
      return { open: !d.hidden, asked: window.__requests.filter(function (r) { return r.op === 'contract'; }).length };
    });
    const tlDrawerFaults = await page.evaluate(measure, { tablesFit: size.tablesFit });
    it(at + ': Target limits: a current contract opens the contract drawer, which fits', function () {
      truthy(tlDrawer.open, 'the drawer did not open');
      truthy(tlDrawer.asked > 0, 'the contract was not asked for');
      none(tlDrawerFaults, 'drawer from Current contracts');
    });
    await page.click('#drawer [data-act="drawer-close"]');
    await page.waitForTimeout(60);

    // The settings, grouped, with each control beside its words (on a
    // phone, below them).
    await go(page, 'rules');
    await page.click('[data-act="gr-type"][data-value="switch"]');
    await page.waitForTimeout(120);
    const sideBySide = function () {
      const out = [];
      document.querySelectorAll('.st-row').forEach(function (row) {
        if (row.hidden) return;
        const main = row.querySelector('.st-main').getBoundingClientRect();
        const control = row.querySelector('.st-control').getBoundingClientRect();
        if (control.width > 0 && main.right > control.left + 1 && main.bottom > control.top + 1
            && main.top < control.bottom - 1 && !(main.bottom <= control.top + 1)) {
          out.push(row.getAttribute('data-key') + ': its words run under its control');
        }
      });
      return out;
    };
    const rowsFit = await page.evaluate(sideBySide);
    it(at + ': every setting\'s words and its control sit side by side', function () { none(rowsFit); });

    // A switch armed for its second click (every write takes two), saying
    // what it sets: still inside the window, beside its words.
    await page.click('.st-row .switch:not([disabled])');
    await page.waitForTimeout(60);
    const switchArmed = await page.evaluate(function () {
      const sw = document.querySelector('.switch.is-armed');
      if (!sw) return null;
      const r = sw.getBoundingClientRect();
      const cfm = sw.querySelector('.cfm');
      return { label: cfm && getComputedStyle(cfm).display !== 'none' ? cfm.textContent : '',
               inside: r.left >= 0 && r.right <= window.innerWidth + 0.5, height: r.height };
    });
    const armedFaults = await page.evaluate(measure, { tablesFit: size.tablesFit });
    const armedRows = await page.evaluate(sideBySide);
    it(at + ': an armed switch says what it sets, and the features still fit', function () {
      truthy(switchArmed, 'the first click did not arm a switch');
      truthy(/^Click again: turn (On|Off)$/.test(switchArmed.label), switchArmed.label);
      truthy(switchArmed.inside, 'the armed switch runs off the window');
      truthy(switchArmed.height >= 28, switchArmed.height + 'px tall');
      none(armedFaults.concat(armedRows), 'features with a switch armed');
    });

    // And the limits, where a Save can carry a confirm label: armed, with
    // the row saying what lowering it deletes.
    await go(page, 'rules');
    await page.click('[data-act="gr-type"][data-value="timer"]');
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
    await go(page, 'contracts');
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
      // Live only, Any and the eight states (Live only is the default: admin review nit).
      truthy(menu.options === 10, menu.options + ' options');
    });
    await page.click('#dd-ct-state .dd-btn');

    // The contract drawer.
    await page.click('#ct-results tr.row');
    await page.waitForTimeout(200);
    await page.click('#drawer [data-act="dr-more"]');
    await page.waitForTimeout(60);
    const drawer = await page.evaluate(function () {
      const d = document.getElementById('drawer');
      const r = d.getBoundingClientRect();
      const main = document.getElementById('main').getBoundingClientRect();
      const head = d.querySelector('.drawer-head').getBoundingClientRect();
      const close = d.querySelector('[data-act="drawer-close"]').getBoundingClientRect();
      const voidBtn = d.querySelector('[data-act="void"]').getBoundingClientRect();
      const nav = document.getElementById('grp-home');
      const navR = nav.getBoundingClientRect();
      const atNav = navR.width > 0 ? document.elementFromPoint(navR.left + navR.width / 2, navR.top + navR.height / 2) : null;
      return { width: r.width, left: r.left, right: r.right, top: r.top, bottom: r.bottom,
               mainLeft: main.left, mainRight: main.right, mainTop: main.top, mainBottom: main.bottom,
               headTop: head.top, closeRight: close.right, voidTop: voidBtn.top, voidBottom: voidBtn.bottom,
               W: window.innerWidth, H: window.innerHeight, navClear: !!atNav && nav.contains(atNav),
               sideways: d.scrollWidth > d.clientWidth + 1 };
    });
    it(at + (size.phone ? ': the drawer takes the whole screen' : ': the drawer lies over the section, leaves the '
      + 'navigation in reach, and is wide enough to read'), function () {
      if (size.phone) {
        truthy(drawer.left <= 0.5 && drawer.right >= drawer.W - 0.5 && drawer.top <= 0.5, 'the drawer is not full-screen');
      } else {
        truthy(drawer.left >= drawer.mainLeft - 0.5 && drawer.right <= drawer.mainRight + 0.5, 'the drawer spills out of the section');
        truthy(drawer.top >= drawer.mainTop - 0.5 && drawer.bottom <= drawer.mainBottom + 0.5, 'the drawer is taller than the section');
        truthy(drawer.width >= 520, 'the drawer is ' + Math.round(drawer.width) + 'px wide');
        truthy(drawer.navClear, 'the drawer or its scrim covers the navigation');
      }
      truthy(!drawer.sideways, 'the drawer scrolls sideways');
    });
    it(at + ': its close, and its void under More, are on screen as it opens', function () {
      truthy(drawer.closeRight <= drawer.right + 0.5, 'close is off the drawer');
      truthy(drawer.voidBottom <= drawer.H && drawer.voidTop >= drawer.headTop, 'void is not on the first screen');
    });
    const inDrawer = await page.evaluate(measure, { tablesFit: size.tablesFit, scope: '#drawer' });
    it(at + ': the drawer fits, with nothing cut off, too small to hit or too small to read', function () {
      none(inDrawer, 'drawer');
    });
    // Look up / Freeze beside each party (S8): every one inside the drawer,
    // tall enough to hit, its label whole, beside the longest names there are.
    const partiesOn = function () {
      const d = document.getElementById('drawer').getBoundingClientRect();
      return Array.prototype.slice.call(document.querySelectorAll('#drawer [data-act="party-lookup"]'))
        .map(function (b) {
          const r = b.getBoundingClientRect();
          return { subject: b.getAttribute('data-subject'), inside: r.left >= d.left - 0.5 && r.right <= d.right + 0.5,
            tall: r.height >= 24, whole: b.scrollWidth <= b.clientWidth + 1 };
        });
    };
    let parties = await page.evaluate(partiesOn);
    await page.click('#drawer [data-act="dr-tab"][data-value="people"]');
    await page.waitForTimeout(60);
    parties = parties.concat(await page.evaluate(partiesOn));
    await page.click('#drawer [data-act="dr-tab"][data-value="summary"]');
    await page.waitForTimeout(60);
    it(at + ': Look up / Freeze sits beside each party, inside the drawer and whole', function () {
      truthy(parties.length >= 3, 'beside the client, the target and the operatives: ' + JSON.stringify(parties));
      none(parties.filter(function (p) { return !p.inside || !p.tall || !p.whole; })
        .map(function (p) { return JSON.stringify(p); }), 'party buttons');
    });

    // The Deadline card: every control inside the drawer, side by side or
    // wrapped, never past its edge; Shorten armed stays where it was.
    await page.fill('#drawer [data-bind="dr.dl.min"]', '90');
    await page.fill('#drawer [data-bind="dr.dl.reason"]', 'A reason long enough to fill the box at a phone\'s width');
    await page.waitForTimeout(50);
    const deadline = await page.evaluate(function () {
      const d = document.getElementById('drawer').getBoundingClientRect();
      const acts = ['dl-pick', 'dl-extend', 'dl-shorten'];
      const out = { outside: [], count: 0 };
      document.querySelectorAll('#drawer button, #drawer [data-bind^="dr.dl"]').forEach(function (b) {
        const act = b.getAttribute('data-act') || '';
        if (acts.indexOf(act) === -1 && !(b.getAttribute('data-bind') || '').startsWith('dr.dl')) return;
        out.count++;
        const r = b.getBoundingClientRect();
        if (r.left < d.left - 0.5 || r.right > d.right + 0.5) out.outside.push(act || b.getAttribute('data-bind'));
        if (r.height < 28) out.outside.push((act || b.getAttribute('data-bind')) + ' is ' + r.height + 'px tall');
      });
      const preview = document.getElementById('dr-dl-preview');
      out.preview = preview ? preview.textContent : '';
      const p = preview.getBoundingClientRect();
      out.previewInside = p.left >= d.left - 0.5 && p.right <= d.right + 0.5;
      const b = document.querySelector('#drawer [data-act="dl-shorten"]');
      const before = b.getBoundingClientRect();
      b.click();
      const after = b.getBoundingClientRect();
      const cfm = b.querySelector('.cfm');
      out.label = cfm && getComputedStyle(cfm).visibility === 'visible' ? cfm.textContent : '';
      out.moved = Math.abs(after.left - before.left) + Math.abs(after.top - before.top);
      return out;
    });
    it(at + ': the deadline card\'s picks, minutes, reason, Extend and Shorten fit inside the drawer', function () {
      truthy(deadline.count === 8, deadline.count + ' controls');
      truthy(deadline.outside.length === 0, deadline.outside.join(', '));
      truthy(deadline.previewInside, 'the time left after spills out of the drawer');
      truthy(/Extend: 11 h 50 min 30 s left after/.test(deadline.preview), deadline.preview);
      truthy(deadline.moved < 1 && /Click again to shorten/.test(deadline.label),
        'armed Shorten moved ' + deadline.moved + 'px, saying ' + deadline.label);
    });

    // The staff tools: every control inside the drawer, and a party's card
    // drawn in it, its longest values wrapped, never past its edge.
    const toolsOn = function () {
      const d = document.getElementById('drawer').getBoundingClientRect();
      const out = { outside: [], count: 0 };
      document.querySelectorAll('#drawer .ct-notes *, #drawer .ct-remove *, #drawer .ct-text *, '
        + '#drawer .ct-export *, #drawer .ct-view *').forEach(function (n) {
        if (!(n.tagName === 'BUTTON' || n.tagName === 'INPUT' || n.tagName === 'DD' || n.tagName === 'PRE'
          || n.tagName === 'LI')) return;
        const r = n.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return;
        out.count++;
        if (r.left < d.left - 0.5 || r.right > d.right + 0.5) {
          out.outside.push((n.getAttribute('data-act') || n.getAttribute('data-bind') || n.tagName) + ' '
            + Math.round(r.left) + '..' + Math.round(r.right));
        }
      });
      const view = document.querySelector('#drawer .ct-view-facts');
      out.view = !!view;
      out.sideways = document.getElementById('drawer').scrollWidth > document.getElementById('drawer').clientWidth + 1;
      return out;
    };
    // The staff tools are on People (remove, the player view), Notes & text
    // and Record (export): each tab measured in turn.
    const tools = { outside: [], count: 0, view: false, sideways: false };
    const inTools = [];
    for (const tab of ['notes', 'record', 'people']) {
      await page.click('#drawer [data-act="dr-tab"][data-value="' + tab + '"]');
      await page.waitForTimeout(80);
      if (tab === 'people') {
        await page.click('#drawer [data-act="ct-view"][data-value="hitman:hm1"]');
        await page.waitForTimeout(150);
      }
      const got = await page.evaluate(toolsOn);
      tools.outside = tools.outside.concat(got.outside);
      tools.count += got.count;
      tools.view = tools.view || got.view;
      tools.sideways = tools.sideways || got.sideways;
      (await page.evaluate(measure, { tablesFit: size.tablesFit, scope: '#drawer' })).forEach(function (f) {
        inTools.push(tab + ': ' + f);
      });
    }
    it(at + ': the staff tools and a party\'s card fit inside the drawer', function () {
      truthy(tools.view, 'the card was not drawn');
      truthy(tools.count > 20, tools.count + ' controls');
      truthy(tools.outside.length === 0, tools.outside.join(', '));
      truthy(!tools.sideways, 'the drawer scrolls sideways');
    });
    it(at + ': the drawer with a party\'s card open fits, nothing cut off or too small', function () {
      none(inTools, 'drawer with the player view');
    });

    // Change reward (Money) and Reassign (People): every control inside the
    // drawer, the figures drawn before the armed button, and each armed
    // naming what it does.
    const staffMoney = function (args) {
      const cls = args.cls, act = args.act;
      const d = document.getElementById('drawer').getBoundingClientRect();
      const out = { outside: [], count: 0, label: '' };
      document.querySelectorAll('#drawer ' + cls + ' button, #drawer ' + cls + ' input, #drawer ' + cls + ' dd, #drawer '
        + cls + ' p').forEach(function (n) {
        const r = n.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return;
        out.count++;
        if (r.left < d.left - 0.5 || r.right > d.right + 0.5) {
          out.outside.push((n.getAttribute('data-act') || n.getAttribute('data-bind') || n.tagName) + ' '
            + Math.round(r.left) + '..' + Math.round(r.right));
        }
        if ((n.tagName === 'BUTTON' || n.tagName === 'INPUT') && r.height < 28) {
          out.outside.push((n.getAttribute('data-act') || n.getAttribute('data-bind')) + ' is ' + r.height + 'px tall');
        }
      });
      const b = document.querySelector('#drawer [data-act="' + act + '"]');
      const cfm = b && b.querySelector('.cfm');
      out.armed = !!b && b.classList.contains('is-armed');
      out.label = cfm && getComputedStyle(cfm).visibility === 'visible' ? cfm.textContent : '';
      out.sideways = document.getElementById('drawer').scrollWidth > document.getElementById('drawer').clientWidth + 1;
      return out;
    };
    await page.click('#drawer [data-act="dr-tab"][data-value="money"]');
    await page.waitForTimeout(150);
    await page.fill('#drawer [data-bind="dr.rw.amt.ct10000001"]', '99999999');
    await page.waitForTimeout(450);
    await page.fill('#drawer [data-bind="dr.rw.reason.ct10000001"]', REASON_LONG.slice(0, 120));
    await page.click('#drawer [data-act="rw-change"]');
    await page.waitForTimeout(60);
    const reward = await page.evaluate(staffMoney, { cls: '.ct-reward', act: 'rw-change' });
    const rewardFaults = await page.evaluate(measure, { tablesFit: size.tablesFit, scope: '#drawer' });
    it(at + ': Change reward fits inside the drawer, its figures drawn and the armed button naming them', function () {
      truthy(reward.count >= 10, reward.count + ' controls');
      none(reward.outside, 'change reward');
      truthy(!reward.sideways, 'the drawer scrolls sideways');
      truthy(reward.armed && /Click again: raise it from \$1,234,567,890 to \$1,334,567,889/.test(reward.label), reward.label);
      none(rewardFaults, 'drawer with Change reward');
    });
    await page.click('#drawer [data-act="dr-tab"][data-value="people"]');
    await page.waitForTimeout(150);
    await page.fill('#drawer [data-bind="dr.ra.reason.ct10000001"]', REASON_LONG.slice(0, 120));
    await page.click('#drawer [data-act="ra-go"]');
    await page.waitForTimeout(60);
    const reassign = await page.evaluate(staffMoney, { cls: '.ct-reassign', act: 'ra-go' });
    const reassignFaults = await page.evaluate(measure, { tablesFit: size.tablesFit, scope: '#drawer' });
    it(at + ': Reassign fits inside the drawer, the hitman looked up and who comes off said, armed naming them', function () {
      truthy(reassign.count >= 6, reassign.count + ' controls');
      none(reassign.outside, 'reassign');
      truthy(!reassign.sideways, 'the drawer scrolls sideways');
      truthy(reassign.armed && /Click again: give it to .+, taking off 3 operatives/.test(reassign.label), reassign.label);
      none(reassignFaults, 'drawer with Reassign');
    });
    await page.click('#drawer [data-act="dr-tab"][data-value="summary"]');
    await page.waitForTimeout(60);

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
    await go(page, 'tools');
    await page.waitForTimeout(100);
    // Two clicks, as every write is.
    await page.click('button[data-act="tl-flush"]');
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

  /* ---- one design system: the phone app and the panel draw the same
     components the same way (ui/kit.css) ---- */
  function probeKit() {
    const sheets = Array.prototype.map.call(document.styleSheets, function (sh) {
      return String(sh.href || '').replace(/^.*\/ui\//, '').replace(/\?.*$/, '');
    });
    const host = document.createElement('div');
    host.innerHTML = '<button class="btn primary">P</button><button class="btn ghost">G</button>'
      + '<button class="btn danger">D</button><button class="btn is-armed">A</button>'
      + '<span class="chip">C</span><span class="chip is-warn">W</span><div class="card">K</div>'
      + '<div class="notice">N</div><div class="notice ok">O</div><div class="notice gold">G</div>'
      + '<p class="hint">H</p><p class="empty">E</p><table class="grid"><tr><th>T</th></tr></table>';
    document.body.appendChild(host);
    const out = {};
    Array.prototype.forEach.call(host.querySelectorAll('*'), function (n, i) {
      if (n.tagName === 'TBODY' || n.tagName === 'TR') return;
      const st = getComputedStyle(n);
      out[i + ':' + n.className] = [st.color, st.backgroundColor, st.backgroundImage, st.borderTopColor,
        st.borderTopLeftRadius, st.fontWeight].join(' | ');
    });
    host.remove();
    return { sheets: sheets, look: out,
             tokens: ['--bg', '--panel', '--ink', '--crimson', '--gold', '--t-sm', '--radius'].map(function (t) {
               return getComputedStyle(document.documentElement).getPropertyValue(t).trim(); }) };
  }
  const kitAdmin = await openAt(browser, 1280, 800);
  const adminKit = await kitAdmin.evaluate(probeKit);
  await kitAdmin.close();
  const kitPhone = await browser.newPage({ viewport: { width: 390, height: 720 } });
  await kitPhone.goto('file://' + path.join(__dirname, '..', '..', 'crimson-hitman', 'ui', 'index.html'));
  await kitPhone.waitForTimeout(300);
  const phoneKit = await kitPhone.evaluate(probeKit);
  await kitPhone.close();
  it('both pages link the one design system (kit.css) before their own sheet', function () {
    truthy(adminKit.sheets.indexOf('kit.css') !== -1 && adminKit.sheets.indexOf('kit.css') < adminKit.sheets.indexOf('admin.css'),
      'admin: ' + adminKit.sheets.join(','));
    truthy(phoneKit.sheets.indexOf('kit.css') !== -1 && phoneKit.sheets.indexOf('kit.css') < phoneKit.sheets.indexOf('app.css'),
      'phone: ' + phoneKit.sheets.join(','));
  });
  it('both pages share every token and draw buttons (armed too), chips, cards, notices, hints and tables alike', function () {
    truthy(JSON.stringify(phoneKit.tokens) === JSON.stringify(adminKit.tokens),
      'tokens: admin ' + adminKit.tokens.join(',') + ' / phone ' + phoneKit.tokens.join(','));
    const differ = Object.keys(adminKit.look).filter(function (k) { return adminKit.look[k] !== phoneKit.look[k]; });
    truthy(differ.length === 0, differ.map(function (k) {
      return k + ': admin ' + adminKit.look[k] + ' / phone ' + phoneKit.look[k]; }).join(' || '));
    truthy(/rgb\(207, 169, 98\)/.test(adminKit.look[Object.keys(adminKit.look)[3]]), 'armed is brass');
    truthy(/gradient/.test(adminKit.look[Object.keys(adminKit.look)[0]]), 'primary is the crimson gradient');
  });

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
