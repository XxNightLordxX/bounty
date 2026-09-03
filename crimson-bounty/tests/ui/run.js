/* Drives the real ui/app.js against a scripted server, and asserts on what
 * the app actually sends and renders.
 *
 * Everything here exercises the shipped file: app.js is read from disk and
 * executed, not reimplemented. */

'use strict';

const fs = require('fs');
const path = require('path');
const { makeDocument } = require('./dom.js');

const APP = path.join(__dirname, '..', '..', 'ui', 'app.js');

let passed = 0, failed = 0;
const failures = [];

function it(name, fn) {
  try { fn(); passed++; }
  catch (err) { failed++; failures.push(name + '\n    ' + err.message); }
}

function eq(actual, expected, message) {
  if (actual !== expected) {
    throw new Error((message || 'mismatch') +
      ': expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
  }
}
function truthy(v, m) { if (!v) throw new Error((m || 'expected truthy') + ', got ' + v); }
function falsy(v, m) { if (v) throw new Error((m || 'expected falsy') + ', got ' + JSON.stringify(v)); }

/** Boot the app against a server that answers from `responses`. */
function boot(responses) {
  const document = makeDocument();
  const sent = [];
  const timers = [];
  const notices = [];

  // The tab bar the app expects to exist.
  const app = document.createElement('div');
  const view = document.createElement('div');
  view.id = 'view';
  app.appendChild(view);
  ['board', 'mine', 'place', 'onme', 'ledger'].forEach(function (name) {
    const tab = document.createElement('button');
    tab.className = 'tab';
    tab.dataset.tab = name;
    app.appendChild(tab);
  });
  document.appendChild(app);

  const sandbox = {
    document: document,
    window: {
      addEventListener: function (type, fn) { sandbox.window['_' + type] = fn; },
      confirm: function () { return sandbox.confirmAnswer !== false; },
      prompt: function () { return sandbox.promptAnswer; }
    },
    fetch: function (url, options) {
      const name = url.split('/crimson:')[1];
      const body = JSON.parse(options.body);
      sent.push({ name: name, body: body });
      const answer = responses[name];
      const result = typeof answer === 'function' ? answer(body) : answer;
      return Promise.resolve({ json: function () { return Promise.resolve(result || { ok: true }); } });
    },
    setTimeout: function (fn, ms) { timers.push({ fn: fn, ms: ms }); return timers.length; },
    setInterval: function (fn, ms) { timers.push({ fn: fn, ms: ms, repeating: true }); return timers.length; },
    clearInterval: function () {},
    Promise: Promise, JSON: JSON, Math: Math, Number: Number, String: String,
    Array: Array, Object: Object, console: console
  };
  sandbox.window.document = document;

  const source = fs.readFileSync(APP, 'utf8');
  const vm = require('vm');
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, { filename: 'app.js' });

  return { document, view, sent, timers, sandbox, notices };
}

/** Let queued promise callbacks run. */
function settle() {
  return new Promise(function (resolve) { setImmediate(resolve); });
}

/* ---------------------------------------------------------------- */

const BOARD = {
  ok: true,
  data: {
    page: 1, pages: 1,
    settings: { warnCreator: true, warnHunter: true, flagListing: true, minQueryLength: 4 },
    contracts: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'active',
      reward: { baseline: 5000, bonus: 2500 },
      slots: 2, slotsClaimed: 0, currentSlot: 1,
      huntersActive: 1, huntersMax: 5,
      targetName: 'Dana Reyes', targetProtected: false,
      creatorName: 'Vic Marlowe', role: 'public'
    }]
  }
};

const MINE = { ok: true, data: { created: [], accepted: [], onMe: [] } };
const LEDGER = { ok: true, data: { entries: [], record: { completed: 0, placed: 0, survived: 0, standing: 'Unproven' } } };

async function main() {
  await (async function rendersTheBoard() {
    const app = boot({ list: BOARD, mine: MINE, ledger: LEDGER });
    await settle(); await settle(); await settle();

    it('renders a contract from the board payload', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('Dana Reyes') !== -1, 'target name should be on screen: ' + text);
      truthy(text.indexOf('$5,000') !== -1, 'reward should be on screen: ' + text);
    });

    it('asks the server for exactly the three things it needs on open', function () {
      const names = app.sent.map(function (s) { return s.name; }).sort();
      eq(names.join(','), 'ledger,list,mine');
    });

    it('does not refresh in a loop when the client mirrors a reply', function () {
      const before = app.sent.length;
      app.sandbox.window._message({ data: { type: 'result', event: 'list' } });
      eq(app.sent.length, before, 'a mirrored reply must not trigger another refresh');
    });
  })();

  await (async function submitsAContract() {
    let submission = null;
    const app = boot({
      list: BOARD, mine: MINE, ledger: LEDGER,
      searchTargets: { ok: true, data: [{ handle: 'tg00000001', name: 'Dana Reyes', protected: false }] },
      create: function (body) { submission = body; return { ok: true, data: {} }; }
    });
    await settle(); await settle();

    // Switch to the Place tab, as a player would.
    const tabs = app.document.querySelectorAll('.tab');
    const place = tabs.filter(function (t) { return t.dataset.tab === 'place'; })[0];
    place.onclick();

    it('renders the create form', function () {
      truthy(app.document.getElementById('slots-count'), 'payout count field');
      truthy(app.document.getElementById('slot-cash-1'), 'first payout cash field');
      truthy(app.document.getElementById('penalty'), 'failure penalty field');
    });

    // Fill it in the way a player would: one source, everything else blank.
    app.document.getElementById('target-handle').value = 'tg00000001';
    app.document.getElementById('reason').value = 'Unpaid debt';
    app.document.getElementById('slot-cash-1').value = '5000';
    app.document.getElementById('bonus').value = '50';

    const buttons = app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Place contract';
    });
    it('has a submit button', function () { eq(buttons.length, 1); });
    buttons[0].onclick();
    await settle(); await settle();

    it('submits a contract the server would accept', function () {
      truthy(submission, 'nothing was submitted');
      const slot = submission.reward.slots[0].baseline;
      eq(slot.cash, 5000, 'the funded source is sent');
      falsy('bank' in slot, 'a blank field must not be sent as a zero');
      falsy('dirty' in slot, 'a blank field must not be sent as a zero');
    });

    it('sends the failure penalty the form collects', function () {
      eq(submission.penaltyAmount, 0);
      truthy('penaltyAmount' in submission, 'the penalty must reach the server');
    });
  })();

  await (async function hunterCard() {
    const accepted = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    accepted.role = 'hunter';
    accepted.myAlias = 'Operative #1';
    accepted.kidnapProgress = { elapsed: 5, required: 30, graceLeft: 3000 };

    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [accepted], onMe: [] } },
      ledger: LEDGER
    });
    await settle(); await settle();

    const tabs = app.document.querySelectorAll('.tab');
    tabs.filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    it('renders a hunter card with a live countdown without throwing', function () {
      truthy(app.view.textContent.indexOf('Dana Reyes') !== -1,
        'the card should render: ' + app.view.textContent);
    });
  })();

  console.log('');
  failures.forEach(function (f) { console.log('FAIL  ' + f); });
  console.log('\n' + passed + ' passed, ' + failed + ' failed');
  process.exit(failed === 0 ? 0 : 1);
}

main();
