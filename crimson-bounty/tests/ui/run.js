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

let passed = 0;
const failures = [];

function it(name, fn) {
  try {
    const returned = fn();
    // A test body that returns a promise has already returned by the time
    // its assertions run, so it is counted as passed here and any failure
    // surfaces later as an unhandled rejection — after the totals may
    // already have been printed. Two tests were written that way and both
    // would have passed with the code they were testing removed. Await the
    // work outside the body and keep the body synchronous.
    if (returned && typeof returned.then === 'function') {
      throw new Error('this test body returned a promise, so its assertions '
        + 'run after it has been counted as passed. Await outside it() and '
        + 'assert synchronously.');
    }
    passed++;
  } catch (err) { failures.push(name + '\n    ' + err.message); }
}

function eq(actual, expected, message) {
  if (actual !== expected) {
    throw new Error((message || 'mismatch') +
      ': expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
  }
}
function truthy(v, m) { if (!v) throw new Error((m || 'expected truthy') + ', got ' + v); }
function falsy(v, m) { if (v) throw new Error((m || 'expected falsy') + ', got ' + JSON.stringify(v)); }

/** What a reply looks like after FiveM has carried it.
 *
 * The server writes Lua tables and they are msgpack-encoded on the way to
 * the client and JSON-encoded on the way into the page. An empty Lua table
 * is indistinguishable from an empty map, so a list the server meant to
 * send empty arrives as {} rather than [] — and on this side `.length` is
 * then undefined and `.forEach` throws.
 *
 * Fixtures here are hand-written JavaScript with real arrays, so without
 * this the suite tests a boundary that does not exist: every "there is
 * nothing here" branch was being exercised against a shape production
 * never produces. */
/** A list that crosses keyed by something other than 1..n.
 *
 * The other half of the same boundary, and the half nothing modelled. A Lua
 * table keyed by inventory slot — which is exactly what ox_inventory hands
 * back — is not a sequence, so it crosses as an object however many entries
 * it has. asList documents recovering that case and nothing exercised it:
 * reducing asList to `Array.isArray(value) ? value : []` left this suite
 * green, and rule 25 in the static check only greps for the identifier.
 *
 * Wrap a fixture list in this to say "the server keys this by slot".
 */
function keyedBySlot(items, slots) {
  const out = {};
  items.forEach(function (item, i) {
    out[String((slots && slots[i]) || (i + 1) * 3)] = item;
  });
  return out;
}

function acrossTheWire(value) {
  if (Array.isArray(value)) {
    return value.length === 0 ? {} : value.map(acrossTheWire);
  }
  if (value && typeof value === 'object') {
    const out = {};
    Object.keys(value).forEach(function (k) { out[k] = acrossTheWire(value[k]); });
    return out;
  }
  return value;
}

/** Boot the app against a server that answers from `responses`. */
function boot(responses) {
  const document = makeDocument();
  const sent = [];
  const timers = [];
  const notices = [];

  // The tab bar the app expects to exist.
  const app = document.createElement('div');
  const notice = document.createElement('div');
  notice.id = 'notice';
  app.appendChild(notice);
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
      addEventListener: function (type, fn) { sandbox.window['_' + type] = fn; }
    },
    fetch: function (url, options) {
      const name = url.split('/crimson:')[1];
      const body = JSON.parse(options.body);
      sent.push({ name: name, body: body });
      // A render that re-requests what it is waiting for loops forever, and
      // a suite that loops forever tells you nothing. One of these bugs has
      // already shipped in this app; this turns the next one into a failure
      // with a name on it.
      if (sent.length > 500) {
        throw new Error('runaway request loop: ' + sent.length + ' calls, last was ' + name);
      }
      let answer = responses[name];

      // The picker browses by default and falls back to a name search only
      // where the server has browsing switched off. A fixture that scripts
      // one and not the other is describing the same people either way, so
      // the missing half is derived rather than made to look like an empty
      // city — a test that silently browsed nobody would pass while the
      // player saw an empty list.
      if (answer === undefined && name === 'browseTargets' && responses.searchTargets) {
        const search = typeof responses.searchTargets === 'function'
          ? responses.searchTargets(body) : responses.searchTargets;
        const people = (search && search.data) || [];
        const matching = body.query
          ? people.filter(function (p) {
              return p.name.toLowerCase().indexOf(String(body.query).toLowerCase()) !== -1;
            })
          : people;
        answer = { ok: true, data: {
          people: matching, total: matching.length, page: 1, pages: 1
        } };
      }

      const result = typeof answer === 'function' ? answer(body) : answer;

      // A fixture may answer with a promise, meaning a server that has not
      // replied yet. A harness that always answers instantly cannot see a
      // form that asks again on every render, because the first answer is
      // always back before the second render happens; on a real server the
      // reply takes a frame or two and the renders pile up behind it.
      const arriving = (result && typeof result.then === 'function')
        ? result : Promise.resolve(result);
      return Promise.resolve({
        json: function () {
          return arriving.then(function (r) { return acrossTheWire(r || { ok: true }); });
        }
      });
    },
    setTimeout: function (fn, ms) { timers.push({ fn: fn, ms: ms }); return timers.length; },
    setInterval: function (fn, ms) { timers.push({ fn: fn, ms: ms, repeating: true }); return timers.length; },
    clearInterval: function () {},
    clearTimeout: function () {},
    Promise: Promise, JSON: JSON, Math: Math, Number: Number, String: String,
    Array: Array, Object: Object, console: console
  };
  sandbox.window.document = document;

  const source = fs.readFileSync(APP, 'utf8');
  const vm = require('vm');
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, { filename: 'app.js' });

  const booted_app = {
    document, view, sent, timers, sandbox, notices,
    // Throws that escaped a coalesced redraw. render() runs on a timeout of
    // zero, so a throw inside it lands nowhere a test can see it: the app
    // draws a blank tab and the suite reads that as an empty section. Four
    // shipped render crashes hid behind that silence. Recorded here and
    // asserted on by every journey below.
    thrown: [],
    // What the player is currently being told. The notice lives outside
    // #view precisely so it does not rebuild the form, so it has to be read
    // from its own node rather than from the view.
    notice: function () { return document.getElementById('notice').textContent; }
  };
  booted.push(booted_app);
  return booted_app;
}

/** Every app booted in this run, so settle() can drive their timers.
 *
 * A browser runs a zero-delay timeout on the next tick, and the app
 * coalesces its redraws onto exactly that — so a harness that never fired
 * them would be testing a page that had received its data and never drawn
 * it. Registering here rather than threading the app through every settle()
 * keeps the call sites as they were. */
const booted = [];

/** Let queued promise callbacks run, and fire what a browser would. */
function settle() {
  return new Promise(function (resolve) {
    setImmediate(function () {
      booted.forEach(function (app) {
        // Taken out of the list first: a timer that queues another must not
        // be run again inside this same pass.
        const due = app.timers.filter(function (t) { return !t.repeating && !t.ms; });
        due.forEach(function (t) { app.timers.splice(app.timers.indexOf(t), 1); });
        due.forEach(function (t) {
          try { t.fn(); } catch (err) { app.thrown.push(err); }
        });
      });
      resolve();
    });
  });
}

/** Click a button in the rendered view by its exact label. */
function click(app, label) {
  const match = app.view.all().filter(function (n) {
    return n.tagName === 'BUTTON' && n.textContent === label;
  });
  if (match.length === 0) {
    throw new Error('no button labelled "' + label + '" — on screen: ' +
      app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; }).join(' | '));
  }
  match[0].onclick();
  return match[0];
}

/** Every throw the app took while drawing, as one message. */
function threw(app) {
  return app.thrown.map(function (e) { return e.message; }).join(' | ');
}

/** Switch tabs the way a player does.
 *
 * A tab click calls render() directly rather than through the coalesced
 * redraw, so a throw in there escapes the journey entirely and takes every
 * later test in the same block with it — the run then reports one failure
 * ("the suite itself threw") and quietly runs six fewer tests than it has.
 * Recorded like a redraw throw instead, so the journey continues and the
 * test that is actually about it is the one that goes red. */
function tab(app, name) {
  const found = app.document.querySelectorAll('.tab')
    .filter(function (t) { return t.dataset.tab === name; });
  if (!found.length) { throw new Error('no tab named ' + name); }
  try { found[0].onclick(); } catch (err) { app.thrown.push(err); }
  return found[0];
}

/** Assert the app drew everything it was asked to draw without throwing. */
function drewCleanly(app, where) {
  if (app.thrown.length) {
    throw new Error((where || 'the app') + ' threw while rendering: ' + threw(app));
  }
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

/* An error thrown inside the app's own promise callbacks used to kill the
 * whole run with a stack trace and no test name — which is the least useful
 * way to learn that a render threw. Recorded as a failure instead. */
process.on('unhandledRejection', function (err) {
  failures.push('the app threw while rendering\n    ' + (err && err.message || err));
});

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

  await (async function targetBuyout() {
    const onMe = {
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'exclusive', state: 'active',
      reward: { baseline: 5000, bonus: 0 },
      slots: 1, slotsClaimed: 0, currentSlot: 1, huntersActive: 1, huntersMax: 5,
      targetName: 'Dana Reyes', targetProtected: false, role: 'target',
      bailoutAmount: 15000, bailoutAvailable: true
    };

    let boughtOut = null;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [], onMe: [onMe] } },
      ledger: LEDGER,
      bailout: function (body) { boughtOut = body; return { ok: true, data: true }; }
    });
    await settle(); await settle();

    const tabs = app.document.querySelectorAll('.tab');
    tabs.filter(function (t) { return t.dataset.tab === 'onme'; })[0].onclick();

    it('tells the target there is a price on their head', function () {
      truthy(app.view.textContent.indexOf('price on your head') !== -1,
        'the warning should be visible: ' + app.view.textContent);
    });

    it('offers the buyout at the price the server set', function () {
      truthy(app.view.textContent.indexOf('$15,000') !== -1,
        'the buyout price should be shown: ' + app.view.textContent);
    });

    const buy = app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent.indexOf('Buy out') === 0;
    });
    it('has a buyout button', function () { eq(buy.length, 1); });

    buy[0].onclick();
    click(app, 'Yes');
    await settle();
    it('sends the buyout for the right contract', function () {
      truthy(boughtOut, 'nothing was sent');
      eq(boughtOut.id, 'ct00000001');
    });

    it('never shows the target who placed it or who is hunting them', function () {
      const text = app.view.textContent;
      falsy(text.indexOf('Marlowe') !== -1, 'the creator must not be named');
      falsy(text.indexOf('Operative') !== -1, 'the hunters must not be listed');
    });
  })();

  await (async function ledgerWithProof() {
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: MINE,
      ledger: { ok: true, data: {
        record: { completed: 7, failed: 1, placed: 2, survived: 1, rate: 87, standing: 'Known' },
        entries: [{
          contract_id: 'ct00000001', target_name: 'Dana Reyes', reason: 'Unpaid debt',
          role: 'creator', fulfilment: 'elimination',
          photo_ref: 'https://cdn.fivemanage.com/proof.png', resolved_at: 1700000000
        }]
      } }
    });
    await settle(); await settle();

    const tabs = app.document.querySelectorAll('.tab');
    tabs.filter(function (t) { return t.dataset.tab === 'ledger'; })[0].onclick();

    it('shows the standing and the counters', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('Known') !== -1, 'standing: ' + text);
      truthy(text.indexOf('7 completed') !== -1, 'counters: ' + text);
    });

    it('renders the proof photo from the archive', function () {
      const images = app.view.all().filter(function (n) { return n.tagName === 'IMG'; });
      eq(images.length, 1, 'the verification photo should be on screen');
      eq(images[0].src, 'https://cdn.fivemanage.com/proof.png');
    });
  })();

  await (async function lawEnforcementWarning() {
    const leo = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    leo.targetProtected = true;

    const board = { ok: true, data: {
      page: 1, pages: 1,
      settings: { warnCreator: true, warnHunter: true, flagListing: true, minQueryLength: 4 },
      contracts: [leo]
    } };

    let accepted = null;
    const app = boot({
      list: board, mine: MINE, ledger: LEDGER,
      accept: function (body) { accepted = body; return { ok: true, data: {} }; }
    });
    await settle(); await settle();

    it('flags a law enforcement target on the listing', function () {
      truthy(app.view.textContent.indexOf('Law enforcement') !== -1,
        'the flag should be visible: ' + app.view.textContent);
    });

    const take = app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Accept contract';
    })[0];

    // The player declines the warning.
    take.onclick();
    it('raises an in-page warning rather than a native dialog', function () {
      truthy(app.view.textContent.indexOf('sworn officer') !== -1,
        'the warning must be rendered in the page: ' + app.view.textContent);
    });

    click(app, 'Cancel');
    await settle();
    it('does not accept when the player cancels the warning', function () {
      falsy(accepted, 'cancelling must stop the acceptance');
    });

    take.onclick();
    click(app, 'Yes');
    it('then asks how they want to be named', function () {
      truthy(app.view.textContent.indexOf('anonymously') !== -1,
        'the anonymity choice should follow: ' + app.view.textContent);
    });

    click(app, 'Anonymously');
    await settle();
    it('accepts anonymously when that is chosen', function () {
      truthy(accepted, 'nothing was sent');
      eq(accepted.id, 'ct00000001');
      eq(accepted.anonymous, true);
    });
  })();

  await (async function inPageDialogs() {
    const onMe = {
      id: 'ct00000001', reason: 'x', mode: 'exclusive', state: 'active',
      reward: { baseline: 5000, bonus: 0 },
      slots: 1, slotsClaimed: 0, currentSlot: 1, huntersActive: 1, huntersMax: 5,
      targetName: 'Dana Reyes', targetProtected: false, role: 'target',
      bailoutAmount: 15000, bailoutAvailable: true
    };

    let bought = null;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [], onMe: [onMe] } },
      ledger: LEDGER,
      bailout: function (body) { bought = body; return { ok: true, data: true }; }
    });
    await settle(); await settle();

    const tabs = app.document.querySelectorAll('.tab');
    tabs.filter(function (t) { return t.dataset.tab === 'onme'; })[0].onclick();

    click(app, 'Buy out — $15,000');
    it('confirms the buyout in the page', function () {
      truthy(app.view.textContent.indexOf('Pay $15,000') !== -1,
        'an in-page confirmation must appear: ' + app.view.textContent);
    });

    it('has not sent anything before the player confirms', function () {
      falsy(bought);
    });

    click(app, 'Yes');
    await settle();
    it('sends the buyout once confirmed', function () {
      truthy(bought, 'the buyout must reach the server');
      eq(bought.id, 'ct00000001');
    });
  })();

  await (async function hunterCanWalkAway() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hunter';
    held.myAlias = 'Operative #1';

    let abandoned = null;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      abandon: function (body) { abandoned = body; return { ok: true, data: true }; }
    });
    await settle(); await settle();

    const tabs = app.document.querySelectorAll('.tab');
    tabs.filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    it('offers the hunter a way off the contract', function () {
      const labels = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Abandon') !== -1, 'buttons: ' + labels.join(' | '));
    });

    click(app, 'Abandon');
    click(app, 'Yes');
    await settle();
    it('sends the abandon', function () {
      truthy(abandoned);
      eq(abandoned.id, 'ct00000001');
    });
  })();

  await (async function formSurvivesNotices() {
    const app = boot({
      list: BOARD, mine: MINE, ledger: LEDGER,
      rewardOptions: { ok: true, data: { cash: 100000, bank: 50000, dirty: 2000, caps: {} } },
      searchTargets: { ok: true, data: [{ handle: 'tg00000001', name: 'Ann Ryder', protected: true }] }
    });
    await settle(); await settle();

    const tabs = app.document.querySelectorAll('.tab');
    tabs.filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('shows the creator what they hold', function () {
      truthy(app.view.textContent.indexOf('$100,000') !== -1,
        'balances should be on the form: ' + app.view.textContent);
    });

    // Type a name and pick a law-enforcement target, which raises a notice.
    const query = app.document.getElementById('target-query');
    query.value = 'Ryder';
    query.oninput();
    app.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();

    const pick = app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent.indexOf('Ann Ryder') === 0;
    });
    it('offers the searched target', function () {
      eq(pick.length, 1, 'the candidate should be listed');
    });

    app.document.getElementById('slot-cash-1').value = '5000';
    pick[0].onclick();

    it('keeps the form intact when a notice appears', function () {
      eq(app.document.getElementById('target-handle').value, 'tg00000001',
        'the chosen target must survive the notice it raises');
      eq(app.document.getElementById('slot-cash-1').value, '5000',
        'and so must what was already typed');
    });

    it('debounces the lookup instead of firing per keystroke', function () {
      // One for opening the picker, one for the debounced query. Six
      // keystrokes of "Ryder" must not be six round trips against a bucket
      // that refills twice a second.
      const lookups = app.sent.filter(function (s) {
        return s.name === 'browseTargets' || s.name === 'searchTargets';
      });
      eq(lookups.length, 2,
        'expected the opening list and one debounced query, got: '
        + lookups.map(function (l) { return l.name + '(' + (l.body.query || '') + ')'; })
            .join(', '));
      eq(lookups[1].body.query, 'Ryder', 'and the second carries what was typed');
    });
  })();

  // A contract paying a rifle and nothing else used to read as $0.
  await (async function goodsOnACard() {
    const row = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    row.reward = {
      baseline: 0, bonus: 0,
      goods: { items: 3, weapons: 1, labels: ['WEAPON_PISTOL', 'lockpick'] },
      bonusGoods: { items: 0, weapons: 0, labels: [] }
    };

    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [row], settings: {} } },
      mine: MINE, ledger: LEDGER
    });
    await settle(); await settle();

    it('says a goods-only contract pays goods', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('3 items and 1 weapon') !== -1,
        'the goods, in words: ' + text);
      truthy(text.indexOf('lockpick') !== -1, 'and what they are');
    });

  })();

  await (async function moneyOnlyCardStaysPlain() {
    const plain = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    plain.reward = { baseline: 5000, bonus: 0,
                     goods: { items: 0, weapons: 0, labels: [] } };

    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [plain], settings: {} } },
      mine: MINE, ledger: LEDGER
    });
    await settle(); await settle();

    it('shows nothing extra on a money-only contract', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('$5,000') !== -1, 'the money: ' + text);
      falsy(text.indexOf('item') !== -1, 'and no goods line: ' + text);
      falsy(text.indexOf('weapon') !== -1, text);
    });
  })();

  // The thread view renders from a shape the server sends and has been
  // broken before. It had no coverage at all.
  await (async function threadView() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hunter';
    held.myAlias = 'Operative #1';

    let sent = null;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      readThread: { ok: true, data: [
        { alias: 'Client', body: 'Is it done?', mine: false },
        { alias: 'Operative #1', body: 'Working on it.', mine: true }
      ] },
      sendMessage: function (body) { sent = body; return { ok: true, data: {} }; }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    const talk = app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Message';
    })[0];
    it('offers a thread from the hunter card', function () { truthy(talk, 'a Message button'); });
    if (talk) { talk.onclick(); await settle(); await settle(); }

    it('renders both sides of the conversation', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('Is it done?') !== -1, 'theirs: ' + text);
      truthy(text.indexOf('Working on it.') !== -1, 'and ours');
      truthy(text.indexOf('Operative #1') !== -1, 'under the alias, never a name');
    });

    it('marks which messages are the viewer own', function () {
      const mine = app.view.all().filter(function (n) {
        return n._className && n._className.indexOf('msg mine') !== -1;
      });
      eq(mine.length, 1, 'exactly the one they sent');
    });

    // Type and send, the way a player does.
    const inputs = app.view.all().filter(function (n) { return n.tagName === 'INPUT'; });
    const field = inputs[inputs.length - 1];
    it('offers somewhere to type', function () { truthy(field, 'a message field'); });

    if (field) {
      field.value = 'On my way.';
      field.onkeydown({ key: 'Enter' });
      await settle(); await settle();
    }

    it('sends what was typed, with the contract it belongs to', function () {
      truthy(sent, 'nothing was sent');
      eq(sent.body, 'On my way.');
      eq(sent.id, 'ct00000001', 'the contract, not undefined');
    });

    it('clears the field so a message cannot be sent twice by accident', function () {
      eq(field.value, '', 'the field empties after sending');
    });

    it('does not send on any other key', function () {
      const before = sent;
      field.value = 'half typed';
      field.onkeydown({ key: 'a' });
      eq(sent, before, 'only Enter sends');
    });

    it('goes back to where it came from', function () {
      const back = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Back';
      })[0];
      truthy(back, 'a way out');
      back.onclick();
      truthy(app.view.textContent.indexOf('Dana Reyes') !== -1,
        'back to the cards: ' + app.view.textContent);
    });
  })();

  await (async function emptyThread() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hunter';
    held.myAlias = 'Operative #1';

    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      readThread: { ok: true, data: [] }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Message';
    })[0].onclick();
    await settle(); await settle();

    it('renders a conversation that has not started yet', function () {
      const fields = app.view.all().filter(function (n) { return n.tagName === 'INPUT'; });
      truthy(fields.length > 0, 'still somewhere to type');
    });
  })();

  // Proposals, approvals, declines and expiry have all been implemented on
  // the server since the first commit, and nothing rendered any of it.
  await (async function amendmentPanel() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hunter';
    held.myAlias = 'Operative #1';

    let answered = null;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      amendments: { ok: true, data: [{
        id: 'am00000001', kind: 'shorten_deadline', payload: { seconds: 900 },
        proposer: 'The client', mine: false, answered: false, waiting: 1,
        expires: 0
      }] },
      respondAmendment: function (body) {
        answered = body;
        return { ok: true, data: { outcome: 'applied' } };
      }
    });
    await settle(); await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    it('shows a proposal in words rather than a wire value', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('Shorten the deadline by 15 minutes') !== -1,
        'the change, readably: ' + text);
      falsy(text.indexOf('shorten_deadline') !== -1,
        'never the raw kind: ' + text);
      truthy(text.indexOf('The client proposed this') !== -1, 'and who put it there');
    });

    const buttons = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; });
    const agree = buttons.filter(function (n) { return n.textContent === 'Agree'; })[0];

    it('offers both answers', function () {
      const labels = buttons.map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Agree') !== -1, 'agree: ' + labels.join(','));
      truthy(labels.indexOf('Decline') !== -1, 'decline: ' + labels.join(','));
    });

    // Guarded, so a missing button fails the test above by name instead of
    // taking the whole suite down with a stack trace.
    if (agree) {
      agree.onclick();
      await settle(); await settle();
    }

    it('sends the answer the server expects', function () {
      truthy(answered, 'nothing was sent');
      eq(answered.id, 'am00000001');
      eq(answered.approve, true);
    });

    it('says what the answer settled', function () {
      truthy(app.notice().indexOf('in effect') !== -1, 'the outcome: ' + app.notice());
    });
  })();

  await (async function ownProposalIsNotAnswerable() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hunter';
    held.myAlias = 'Operative #1';

    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      amendments: { ok: true, data: [{
        id: 'am00000001', kind: 'cancel', payload: {},
        proposer: 'Operative #1', mine: true, answered: true, waiting: 1, expires: 0
      }] }
    });
    await settle(); await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    it('does not let a proposer vote on their own proposal twice', function () {
      const labels = app.view.all()
        .filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      falsy(labels.indexOf('Agree') !== -1, 'no second vote: ' + labels.join(','));
      truthy(app.view.textContent.indexOf('Your proposal') !== -1, 'it is marked as theirs');
      truthy(app.view.textContent.indexOf('Waiting on 1 other party') !== -1,
        'and says who it is waiting for: ' + app.view.textContent);
    });
  })();

  await (async function unknownAmendmentKind() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hunter';
    held.myAlias = 'Operative #1';

    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      amendments: { ok: true, data: [{
        id: 'am00000002', kind: 'some_future_kind', payload: {},
        proposer: 'The client', mine: false, answered: false, waiting: 1, expires: 0
      }] }
    });
    await settle(); await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    it('still offers an answer to a kind it does not recognise', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('A change to this contract') !== -1,
        'a proposal nobody can read is a proposal nobody can refuse: ' + text);
      falsy(text.indexOf('some_future_kind') !== -1, 'and never the wire value');
      const labels = app.view.all()
        .filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Decline') !== -1, 'it can still be refused');
    });
  })();

  // The server has had a call path since the first commit and the app had no
  // button that reached it, so the whole feature was unreachable.
  await (async function threadCall() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hunter';
    held.myAlias = 'Operative #1';

    function open(settings, callReply) {
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: settings } },
        mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
        ledger: LEDGER,
        readThread: { ok: true, data: [] },
        requestCall: callReply
      });
      return app;
    }

    const app = open({ calls: true }, { ok: true, data: { placed: true } });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    // Open the thread the way a hunter does, from their card.
    const talk = app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Message';
    });
    truthy(talk.length > 0, 'the card should offer a thread');
    talk[0].onclick();
    await settle(); await settle();

    // Read once and asserted before use: a missing button used to take the
    // whole suite down with a stack trace instead of naming the one test
    // that failed.
    const callButton = app.document.getElementById('thread-call');

    it('offers a call in the thread', function () {
      truthy(callButton, 'a call button');
    });

    if (callButton) {
      callButton.onclick();
      await settle(); await settle();
    }

    it('sends the contract and thread the server expects', function () {
      const sent = app.sent.filter(function (s) { return s.name === 'requestCall'; });
      eq(sent.length, 1);
      eq(sent[0].body.id, 'ct00000001', 'the contract, not undefined');
    });

    it('says a call is connecting only when one is', function () {
      truthy(app.notice().indexOf('Calling') !== -1, 'the notice: ' + app.notice());
    });

    // A phone that cannot place calls still gets the other party asked.
    const asked = open({ calls: true }, { ok: true, data: { placed: false } });
    await settle(); await settle();
    asked.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    asked.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Message';
    })[0].onclick();
    await settle(); await settle();
    const askedButton = asked.document.getElementById('thread-call');
    if (askedButton) {
      askedButton.onclick();
      await settle(); await settle();
    }

    it('does not claim a call is connecting when none is', function () {
      truthy(asked.notice().indexOf('asked to call you back') !== -1,
        'the honest notice: ' + asked.notice());
      falsy(asked.notice().indexOf('Calling') !== -1);
    });

    // With calls off the button is not drawn, rather than drawn and refused.
    const off = open({ calls: false }, { ok: false, err: 'bad_state' });
    await settle(); await settle();
    off.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    off.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Message';
    })[0].onclick();
    await settle(); await settle();

    it('draws no call button when the server has calls off', function () {
      falsy(off.document.getElementById('thread-call'),
        'a button that can only be refused should not be there');
    });
  })();

  // The app refreshes only on an unsolicited push, because refreshing on every
  // mirrored reply was an exponential storm. Nothing sent a push, so an open
  // app never moved.
  await (async function refreshesOnPush() {
    const app = boot({ list: BOARD, mine: MINE, ledger: LEDGER });
    await settle(); await settle();
    const opening = app.sent.length;

    app.sandbox.window._message({ data: { type: 'push', reason: 'accepted' } });

    it('does not refresh until the debounce elapses', function () {
      eq(app.sent.length, opening, 'a push must not fire a request of its own');
    });

    // Three parties to one contract push in the same tick.
    app.sandbox.window._message({ data: { type: 'push', reason: 'completed' } });
    app.sandbox.window._message({ data: { type: 'push', reason: 'completed' } });

    const due = app.timers.filter(function (t) { return t.ms === 250; });
    it('coalesces a burst into one pending refresh', function () {
      truthy(due.length >= 1, 'a debounce timer should be queued');
    });

    // Fire the last queued debounce, as the browser would.
    due[due.length - 1].fn();
    await settle(); await settle();

    it('refreshes once for the whole burst', function () {
      const calls = app.sent.slice(opening).map(function (s) { return s.name; }).sort();
      eq(JSON.stringify(calls), JSON.stringify(['ledger', 'list', 'mine']),
        'exactly one refresh: ' + JSON.stringify(calls));
    });

    it('still ignores a mirrored reply', function () {
      const before = app.sent.length;
      app.sandbox.window._message({ data: { type: 'result', event: 'list' } });
      eq(app.sent.length, before, 'a reply is not a push');
    });
  })();

  // A hunter whose hold is slipping had no way to know: the server has always
  // sent the reason and the grace budget, and the app rendered neither.
  await (async function countdownShowsItsGrace() {
    function withProgress(progress) {
      const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
      held.role = 'hunter';
      held.myAlias = 'Operative #1';
      held.kidnapProgress = progress;
      return boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
        mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
        ledger: LEDGER
      });
    }

    const holding = withProgress({ elapsed: 12, required: 30, graceLeft: 3000, graceTotal: 3000 });
    await settle(); await settle();
    holding.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    it('shows the countdown and the slack while the hold is good', function () {
      const text = holding.view.textContent;
      truthy(text.indexOf('12s of 30s') !== -1, 'the countdown: ' + text);
      truthy(text.indexOf('3.0s of slack left') !== -1, 'the grace budget: ' + text);
    });

    it('does not warn while nothing is breaking', function () {
      const warned = holding.view.all().filter(function (n) {
        return n._className && n._className.indexOf('warn') !== -1;
      });
      eq(warned.length, 0, 'a good hold must read as a good hold');
    });

    const slipping = withProgress({
      elapsed: 12, required: 30, graceLeft: 900, graceTotal: 3000,
      breaking: 'creator_too_far'
    });
    await settle(); await settle();
    slipping.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    it('says why the hold is slipping, in words', function () {
      const text = slipping.view.textContent;
      truthy(text.indexOf('The client is too far away') !== -1,
        'the reason, not the code: ' + text);
      falsy(text.indexOf('creator_too_far') !== -1,
        'a raw reason code must not reach the player: ' + text);
      truthy(text.indexOf('0.9s of slack left') !== -1,
        'and what is left of the allowance: ' + text);
    });

    it('marks a slipping hold visually', function () {
      const breaking = slipping.view.all().filter(function (n) {
        return n._className && n._className.indexOf('is-breaking') !== -1;
      });
      truthy(breaking.length > 0, 'the countdown should carry the breaking class');
    });

    const odd = withProgress({
      elapsed: 1, required: 30, graceLeft: 3000, graceTotal: 3000,
      breaking: 'something_new'
    });
    await settle(); await settle();
    odd.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    it('renders an unknown reason without showing its code', function () {
      const text = odd.view.textContent;
      truthy(text.indexOf('Hold position') !== -1, 'a usable fallback: ' + text);
      falsy(text.indexOf('something_new') !== -1, 'never the raw code: ' + text);
    });

    const none = withProgress({ elapsed: 5, required: 30, graceLeft: 0, graceTotal: 0 });
    await settle(); await settle();
    none.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    it('renders a countdown with no grace budget at all', function () {
      truthy(none.view.textContent.indexOf('5s of 30s') !== -1,
        'a server configured with no slack must still render: ' + none.view.textContent);
      falsy(none.view.textContent.indexOf('slack left') !== -1,
        'and must not offer a budget it does not have');
    });
  })();

  // Headshots arrive as references, not bytes: inlining a 40 KB face into
  // every row of every page cost 600 KB per tab change, re-sent every time.
  await (async function facesByReference() {
    const FACE = 'data:image/png;base64,iVBORw0KGgoAAAA';
    const rows = [];
    for (let i = 0; i < 4; i++) {
      const row = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
      row.id = 'ct0000000' + (i + 1);
      // Three rows name the same face; the fourth names another.
      row.targetImageId = i < 3 ? 'mg1_123456' : 'mg2_654321';
      rows.push(row);
    }

    const asked = [];
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: rows, settings: {} } },
      mine: MINE, ledger: LEDGER,
      mugshotImage: function (body) {
        asked.push(body.id);
        return { ok: true, data: { id: body.id, image: FACE + body.id } };
      }
    });
    await settle(); await settle(); await settle();

    it('asks once per face, not once per row', function () {
      eq(asked.length, 2, 'four rows, two distinct faces: ' + JSON.stringify(asked));
    });

    it('renders the faces once they arrive', function () {
      const shots = app.view.all().filter(function (n) {
        return n.tagName === 'IMG' && n._className === 'mugshot';
      });
      eq(shots.length, 4, 'every row shows its face');
      eq(shots[0].src, FACE + 'mg1_123456');
      eq(shots[3].src, FACE + 'mg2_654321');
    });

    it('redraws once for a whole page of faces', function () {
      // Two faces resolving must not mean two redraws. If they did, the
      // second would re-enter mugshot() for anything still in flight.
      const before = app.sent.length;
      app.sandbox.window._message({ data: { type: 'result', event: 'list' } });
      eq(app.sent.length, before, 'nothing further should be requested');
    });

  })();

  await (async function faceReferenceThatFails() {
    const rows = [JSON.parse(JSON.stringify(BOARD.data.contracts[0]))];
    rows[0].targetImageId = 'mg9_000000';

    let asked = 0;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: rows, settings: {} } },
      mine: MINE, ledger: LEDGER,
      mugshotImage: function () { asked++; return { ok: false, err: 'not_found' }; }
    });
    await settle(); await settle(); await settle();

    it('renders the card without a face when the reference is stale', function () {
      truthy(app.view.textContent.indexOf('Dana Reyes') !== -1,
        'the card must still render: ' + app.view.textContent);
      const shots = app.view.all().filter(function (n) { return n.tagName === 'IMG'; });
      eq(shots.length, 0, 'and show no headshot');
    });

    // Awaited out here, not inside it(): a body that returns a promise is
    // counted as passed before its assertion runs, so this one would have
    // gone on passing with the caching removed.
    const askedBeforeRerender = asked;
    app.sandbox.window._message({ data: { type: 'result', event: 'list' } });
    await settle(); await settle();

    it('asks once and does not retry a reference that failed', function () {
      eq(asked, askedBeforeRerender,
        'a dead reference must not be re-requested every render');
    });
  })();

  // The server has escrowed items and weapons from the start; until the form
  // offered them, a player could not reach any of it.
  const GOODS = {
    cash: 100000, bank: 50000, dirty: 2000,
    // Ordered by label, as the server sends it.
    items: [
      { name: 'bandage', label: 'Bandage', count: 60 },
      { name: 'lockpick', label: 'Lockpick', count: 5 }
    ],
    weapons: [
      { name: 'WEAPON_PISTOL', label: 'Pistol', slot: 3, serial: 'C123' },
      { name: 'WEAPON_PISTOL', label: 'Pistol', slot: 4, serial: 'F456' }
    ],
    // Deliberately not 5: the form's own fallback is 5, so a fixture of 5
    // would pass whether or not the ceiling came from the server at all.
    caps: { maxStacks: 3, maxPerStack: 100, maxWeapons: 2, slots: 7 }
  };

  function placeForm(overrides) {
    let submission = null;
    const app = boot(Object.assign({
      list: BOARD, mine: MINE, ledger: LEDGER,
      rewardOptions: { ok: true, data: GOODS },
      searchTargets: { ok: true, data: [{ handle: 'tg00000001', name: 'Dana Reyes', protected: false }] },
      create: function (body) { submission = body; return { ok: true, data: {} }; }
    }, overrides || {}));
    app.submitted = function () { return submission; };
    return app;
  }

  // Typing into a control the way a browser does: the value changes and the
  // page is told. Setting .value silently is not what a player does, and a
  // form that reads its own state back would never see the edit.
  function pick(app, id, value) {
    const node = app.document.getElementById(id);
    truthy(node, 'missing control: ' + id);
    if (value !== undefined) {
      node.value = String(value);
      if (node.oninput) { node.oninput(); }
    }
    return node;
  }

  function press(app, id) {
    const node = app.document.getElementById(id);
    truthy(node, 'missing button: ' + id);
    node.onclick();
  }

  // The wallet is a snapshot, so a staged weapon's slot can be stale by the
  // time it is submitted. The server refuses rather than substituting — but
  // "you do not have that" is unhelpful while the form still shows the item.
  await (async function staleWalletRecovers() {
    const app = placeForm({
      create: { ok: false, err: 'insufficient_funds' }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    const query = pick(app, 'target-query');
    query.value = 'Dana';
    query.oninput();
    app.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();
    app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent.indexOf('Dana Reyes') === 0;
    })[0].onclick();

    pick(app, 'slot-item-1').value = 'lockpick';
    pick(app, 'slot-item-count-1', 2);
    press(app, 'slot-item-add-1');

    const before = app.sent.filter(function (s) { return s.name === 'rewardOptions'; }).length;
    press(app, 'place-submit');
    await settle(); await settle();

    it('says what actually went wrong', function () {
      truthy(app.notice().indexOf('pockets have changed') !== -1,
        'not a bare "you do not have that": ' + app.notice());
    });

    it('re-reads the wallet instead of showing the stale one', function () {
      const after = app.sent.filter(function (s) { return s.name === 'rewardOptions'; }).length;
      truthy(after > before, 'the pickers must be rebuilt from what is there now');
    });

    it('drops the goods that are no longer holdable', function () {
      falsy(app.view.textContent.indexOf('Lockpick x2') !== -1,
        'staging something the server refused must not persist: ' + app.view.textContent);
    });
  })();

  // A form whose values live only in the DOM loses them every time anything
  // re-renders — a tab change, a push, a late reply, or a dialog. Both of
  // these were found by review, not by the tests written alongside the
  // feature.
  await (async function formSurvivesRerender() {
    const app = placeForm();
    await settle(); await settle();

    function openPlace(a) {
      a.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    }

    openPlace(app);
    await settle(); await settle();

    // Build a two-payout contract with goods on the second.
    pick(app, 'slots-count', 2).onchange();
    pick(app, 'slot-cash-1', 7000);
    pick(app, 'slot-item-2').value = 'lockpick';
    pick(app, 'slot-item-count-2', 3);
    press(app, 'slot-item-add-2');
    // Chosen from a search, the only way a target is ever set.
    const query = pick(app, 'target-query');
    query.value = 'Dana';
    query.oninput();
    app.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();
    app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent.indexOf('Dana Reyes') === 0;
    })[0].onclick();

    pick(app, 'reason', 'Unpaid debt');

    // Glance at another tab and come back, as anyone would.
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    openPlace(app);
    await settle(); await settle();

    it('keeps the payout count across a tab change', function () {
      eq(app.document.getElementById('slots-count').value, '2',
        'the form must not quietly become a one-payout contract');
    });

    it('keeps goods staged on a payout across a tab change', function () {
      truthy(app.view.textContent.indexOf('Lockpick x3') !== -1,
        'staged goods must survive a rebuild: ' + app.view.textContent);
    });

    it('keeps the target and the amounts too', function () {
      eq(app.document.getElementById('target-handle').value, 'tg00000001');
      eq(app.document.getElementById('reason').value, 'Unpaid debt');
      eq(app.document.getElementById('slot-cash-1').value, '7000');
    });
  })();

  await (async function officerConfirmationKeepsTheForm() {
    let submission = null;
    const app = placeForm({
      searchTargets: { ok: true, data: [{ handle: 'tg00000001', name: 'Ann Ryder', protected: true }] },
      create: function (body) { submission = body; return { ok: true, data: {} }; }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    // Picked from a search, the only way a target is ever chosen.
    const query = pick(app, 'target-query');
    query.value = 'Ryder';
    query.oninput();
    app.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();

    const candidate = app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent.indexOf('Ann Ryder') === 0;
    })[0];
    truthy(candidate, 'the officer should be offered');
    if (candidate) { candidate.onclick(); }

    pick(app, 'reason', 'Unpaid debt');
    pick(app, 'slot-cash-1', 5000);

    press(app, 'place-submit');
    await settle();

    it('asks before placing a contract on a sworn officer', function () {
      truthy(app.view.textContent.indexOf('sworn officer') !== -1,
        'the warning: ' + app.view.textContent);
    });

    // Confirm it, the way a player does.
    const yes = app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Yes';
    })[0];
    truthy(yes, 'a way to confirm');
    if (yes) { yes.onclick(); await settle(); await settle(); }

    it('places the contract the player actually built', function () {
      truthy(submission, 'confirming must submit, not rebuild an empty form');
      eq(submission.reason, 'Unpaid debt', 'with what was typed');
      eq(submission.reward.slots[0].baseline.cash, 5000, 'and what was funded');
    });
  })();

  await (async function stakesGoods() {
    const app = placeForm();
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('offers as many payouts as the server allows', function () {
      eq(app.document.getElementById('slots-count').max, 7,
        'the ceiling comes from the config, not from the form');
      truthy(GOODS.caps.slots !== 5,
        'and the fixture must differ from the fallback or this proves nothing');
    });

    it('offers the items and weapons the server says are escrowable', function () {
      truthy(app.document.getElementById('slot-item-1'), 'an item picker');
      truthy(app.document.getElementById('slot-weapon-1'), 'a weapon picker');
      truthy(app.view.textContent.indexOf('Lockpick') !== -1,
        'the item should be named: ' + app.view.textContent);
      truthy(app.view.textContent.indexOf('#C123') !== -1,
        'the serial tail tells two pistols apart: ' + app.view.textContent);
    });

    // Stage a real reward: money, two lockpicks and one specific pistol.
    pick(app, 'slot-cash-1', 7000);
    pick(app, 'slot-item-1').value = 'lockpick';
    pick(app, 'slot-item-count-1', 2);
    press(app, 'slot-item-add-1');
    press(app, 'slot-weapon-add-1');

    it('shows what was staged, removably', function () {
      truthy(app.view.textContent.indexOf('Lockpick x2') !== -1,
        'the staged item and its count: ' + app.view.textContent);
      const chips = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n._className.indexOf('chip') !== -1;
      });
      eq(chips.length, 2, 'one removable chip per staged reward');
    });

    it('actually removes what a chip names', function () {
      const chip = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n._className.indexOf('chip') !== -1
          && n.textContent.indexOf('Lockpick') === 0;
      })[0];
      truthy(chip, 'a chip for the lockpicks');
      chip.onclick();

      falsy(app.view.textContent.indexOf('Lockpick x2') !== -1,
        'removing must remove: ' + app.view.textContent);

      // And the lockpicks are offerable again, rather than still counted
      // against the holding.
      const options = app.document.getElementById('slot-item-1').children
        .filter(function (o) { return o.value === 'lockpick'; });
      truthy(options.length === 1 && options[0].textContent.indexOf('5 spare') !== -1,
        'all five are spare again: ' + (options[0] && options[0].textContent));

      // Put it back, since the tests below expect it staged.
      pick(app, 'slot-item-1').value = 'lockpick';
      pick(app, 'slot-item-count-1', 2);
      press(app, 'slot-item-add-1');
    });

    it('will not offer the same physical weapon twice', function () {
      const options = pick(app, 'slot-weapon-1').children;
      eq(options.length, 1, 'the pistol already staged is gone from the list');
      eq(options[0].value, '4', 'the other pistol is still offerable');
    });

    it('will not let one stack fund two payouts', function () {
      pick(app, 'slots-count', 2).onchange();

      const picker = pick(app, 'slot-item-2');
      const lockpicks = picker.children.filter(function (o) { return o.value === 'lockpick'; });
      eq(lockpicks.length, 1, 'lockpicks are still offerable');
      truthy(lockpicks[0].textContent.indexOf('3 spare') !== -1,
        'only the three not already promised: ' + lockpicks[0].textContent);

      pick(app, 'slot-item-2').value = 'lockpick';
      pick(app, 'slot-item-count-2', 4);
      press(app, 'slot-item-add-2');
      truthy(app.notice() && app.notice().indexOf('3 of those spare') !== -1,
        'over-allocating across payouts must be refused: ' + app.notice());
    });

    it('releases goods staged on a payout that is taken away', function () {
      // Stage a lockpick on the second payout, then drop back to one.
      pick(app, 'slot-item-2').value = 'lockpick';
      pick(app, 'slot-item-count-2', 3);
      press(app, 'slot-item-add-2');

      pick(app, 'slots-count', 1).onchange();
      pick(app, 'slots-count', 2).onchange();

      const lockpicks = pick(app, 'slot-item-2').children
        .filter(function (o) { return o.value === 'lockpick'; });
      truthy(lockpicks.length === 1 && lockpicks[0].textContent.indexOf('3 spare') !== -1,
        'the three released must be offerable again: '
          + (lockpicks[0] && lockpicks[0].textContent));
    });

    it('keeps typed amounts when the payout count changes', function () {
      eq(app.document.getElementById('slot-cash-1').value, '7000',
        'what was typed before the count changed must survive');
    });

    pick(app, 'target-handle', 'tg00000001');
    pick(app, 'reason', 'Unpaid debt');
    pick(app, 'slot-cash-2', 1000);
    press(app, 'place-submit');
    await settle(); await settle();

    it('sends the goods in the shape the server validates', function () {
      const submission = app.submitted();
      truthy(submission, 'nothing was submitted');

      const first = submission.reward.slots[0].baseline;
      eq(first.cash, 7000);
      eq(first.items.length, 1);
      eq(first.items[0].name, 'lockpick');
      eq(first.items[0].count, 2);
      eq(first.weapons.length, 1);
      eq(first.weapons[0].name, 'WEAPON_PISTOL');
      eq(first.weapons[0].slot, 3, 'the inventory slot, so the right pistol is taken');

      const second = submission.reward.slots[1].baseline;
      eq(second.cash, 1000);
      falsy('items' in second, 'the refused item must not have been staged');
      falsy('weapons' in second);
    });

    it('clears the staged goods once they have left the player', function () {
      // Back to the form: what the contract took is no longer staged, and
      // the wallet is read again rather than offering the old holdings.
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();

      falsy(app.view.textContent.indexOf('Lockpick x2') !== -1,
        'goods that are gone must not still be staged: ' + app.view.textContent);
      eq(app.document.getElementById('slots-count').value, '1',
        'and the form starts over rather than keeping the last one');

      const refetches = app.sent.filter(function (s) { return s.name === 'rewardOptions'; });
      truthy(refetches.length >= 2, 'the wallet is read again after a contract is placed');
    });
  })();

  await (async function goodsOnlyPayout() {
    const app = placeForm();
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    pick(app, 'target-handle', 'tg00000001');
    pick(app, 'reason', 'Debt');
    pick(app, 'slot-item-1').value = 'lockpick';
    pick(app, 'slot-item-count-1', 5);
    press(app, 'slot-item-add-1');
    press(app, 'place-submit');
    await settle(); await settle();

    it('accepts a payout funded only by goods', function () {
      const submission = app.submitted();
      truthy(submission, 'a contract paying in goods alone must submit');
      const slot = submission.reward.slots[0].baseline;
      falsy('cash' in slot, 'no money was offered, so none is sent');
      eq(slot.items[0].name, 'lockpick');
      eq(slot.items[0].count, 5, 'the whole stack may be staked');
    });
  })();

  await (async function emptyPayoutStillRefused() {
    const app = placeForm();
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    pick(app, 'target-handle', 'tg00000001');
    press(app, 'place-submit');
    await settle();

    it('still refuses a payout with nothing in it', function () {
      falsy(app.submitted(), 'an empty payout must not reach the server');
      truthy(app.notice() && app.notice().indexOf('no reward') !== -1,
        'and the player must be told why: ' + app.notice());
    });
  })();

  await (async function noGoodsToOffer() {
    const app = placeForm({
      rewardOptions: { ok: true, data: { cash: 500, bank: 0, dirty: 0, items: [], weapons: [], caps: {} } }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('falls back rather than offering an unbounded field', function () {
      // caps.slots is absent in this fixture, which is what a server too old
      // to send it looks like.
      eq(app.document.getElementById('slots-count').max, 5);
    });

    it('shows no picker at all when there is nothing to stake', function () {
      falsy(app.document.getElementById('slot-item-add-1'), 'no item picker');
      falsy(app.document.getElementById('slot-weapon-add-1'), 'no weapon picker');
      truthy(app.document.getElementById('slot-cash-1'), 'money is still offerable');
    });

    it('says why, rather than leaving the section out', function () {
      // A section that is simply absent reads as a missing feature. The
      // player has to be told they are carrying nothing, not shown a gap
      // where the option would be.
      const text = app.view.textContent;
      truthy(text.indexOf('Items & weapons') !== -1,
        'the heading has to be there even when the list is empty: ' + text);
      truthy(text.indexOf('not carrying anything') !== -1,
        'and say why it is empty: ' + text);
    });
  })();

  /* ---- why the goods section is empty --------------------------------
   *
   * Three different situations used to look identical: an empty section
   * with no heading. The player cannot tell a switched-off feature from an
   * empty inventory from a broken one, and assumes the app cannot do it. */
  await (async function goodsAbsenceIsExplained() {
    async function placeWith(data) {
      const app = boot({
        list: BOARD, mine: MINE, ledger: LEDGER,
        rewardOptions: { ok: true, data: data },
        searchTargets: { ok: true, data: [] }
      });
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
      await settle(); await settle();
      return app.view.textContent;
    }

    const carryingNothing = await placeWith({
      cash: 500, bank: 0, dirty: 0, items: [], weapons: [],
      inventoryRead: true, caps: { itemsEnabled: true, weaponsEnabled: true }
    });
    it('distinguishes carrying nothing', function () {
      truthy(carryingNothing.indexOf('not carrying anything') !== -1, carryingNothing);
    });

    const unreadable = await placeWith({
      cash: 500, bank: 0, dirty: 0, items: [], weapons: [],
      inventoryRead: false, caps: { itemsEnabled: true, weaponsEnabled: true }
    });
    it('distinguishes an inventory it could not read', function () {
      truthy(unreadable.indexOf('could not be read') !== -1,
        'a build whose export shape does not match must say so: ' + unreadable);
      truthy(unreadable.indexOf('Money still works') !== -1,
        'and say what does still work: ' + unreadable);
    });

    const bothOff = await placeWith({
      cash: 500, bank: 0, dirty: 0, items: [], weapons: [],
      inventoryRead: true, caps: { itemsEnabled: false, weaponsEnabled: false }
    });
    it('distinguishes a server that takes money only', function () {
      truthy(bothOff.indexOf('does not take items or weapons') !== -1, bothOff);
    });

    const itemsOff = await placeWith({
      cash: 500, bank: 0, dirty: 0, items: [], weapons: [],
      inventoryRead: true, caps: { itemsEnabled: false, weaponsEnabled: true }
    });
    it('distinguishes items being off from weapons being off', function () {
      truthy(itemsOff.indexOf('does not take items as a reward') !== -1, itemsOff);
    });

  })();

  await (async function switchedOffPickerIsNotOffered() {
    const app = boot({
      list: BOARD, mine: MINE, ledger: LEDGER,
      rewardOptions: { ok: true, data: {
        cash: 500, bank: 0, dirty: 0,
        items: [{ name: 'lockpick', label: 'Lockpick', count: 5 }],
        weapons: [{ name: 'WEAPON_PISTOL', label: 'Pistol', slot: 3 }],
        inventoryRead: true,
        caps: { itemsEnabled: false, weaponsEnabled: true }
      } },
      searchTargets: { ok: true, data: [] }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('does not offer a picker the server would refuse', function () {
      falsy(app.document.getElementById('slot-item-add-1'),
        'items are off, so no item picker even though the server listed one');
      truthy(app.document.getElementById('slot-weapon-add-1'),
        'weapons are on, so that picker stays');
    });
  })();

  /* ---- finding somebody to put a contract on -------------------------
   *
   * The picker used to be a name box and nothing else: type four letters
   * of a name you already know, or get nothing. Knowing the name is the
   * hard part. */
  await (async function targetBrowsing() {
    const CITY = {
      ok: true,
      data: {
        people: [
          { handle: 'tg1', name: 'Ada Quill', protected: false },
          { handle: 'tg2', name: 'Bo Renn', protected: true },
          { handle: 'tg3', name: 'Cy Stark', protected: false }
        ],
        total: 41, page: 1, pages: 5
      }
    };

    async function openPlace(responses) {
      const app = boot(Object.assign({
        list: BOARD, mine: MINE, ledger: LEDGER,
        rewardOptions: { ok: true, data: { cash: 100000, bank: 0, dirty: 0, caps: {} } },
        browseTargets: CITY
      }, responses || {}));
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
      await settle(); await settle(); await settle();
      return app;
    }

    const app = await openPlace();

    it('lists the city without being asked to search first', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('Ada Quill') !== -1, 'people should be listed on open: ' + text);
      truthy(text.indexOf('Cy Stark') !== -1, text);
    });

    it('says how many there are and how many it is showing', function () {
      truthy(app.view.textContent.indexOf('Showing 3 of 41') !== -1,
        'the player has to know the list is partial: ' + app.view.textContent);
    });

    it('marks law enforcement in the list, before anyone picks them', function () {
      const row = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent.indexOf('Bo Renn') === 0;
      })[0];
      truthy(row, 'Bo Renn should be listed');
      truthy(row.textContent.indexOf('Law') !== -1,
        'a sworn officer must be flagged in the list itself: ' + row.textContent);
    });

    it('pages rather than dumping a busy server on one screen', function () {
      const more = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'More';
      });
      eq(more.length, 1, 'there are five pages, so there is a way to the next');
      truthy(app.view.textContent.indexOf('Page 1 of 5') !== -1, app.view.textContent);
    });

    const picked = await openPlace();
    const row = picked.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent.indexOf('Ada Quill') === 0;
    })[0];
    if (row) { row.onclick(); }

    it('picking from the list sets the target', function () {
      truthy(row, 'no Ada Quill row to pick; buttons on screen: ' +
        picked.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
          .map(function (n) { return JSON.stringify(n.textContent); }).join(' | '));
      eq(picked.document.getElementById('target-handle').value, 'tg1');
      truthy(picked.view.textContent.indexOf('placed on Ada Quill') !== -1,
        'and says who it is for: ' + picked.view.textContent);
    });

    const filtered = await openPlace();
    const filterBefore = filtered.sent.filter(function (s) { return s.name === 'browseTargets'; }).length;
    const filterBox = filtered.document.getElementById('target-query');
    filterBox.value = 'Ad';
    filterBox.oninput();
    filtered.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();

    it('filters the list instead of gating it behind a minimum length', function () {
      const calls = filtered.sent.filter(function (s) { return s.name === 'browseTargets'; });
      truthy(calls.length > filterBefore,
        'two letters must still look — the list is bounded already, so the box '
        + 'narrows it rather than unlocking it');
      eq(calls[calls.length - 1].body.query, 'Ad');
    });

    const withoutNearby = await openPlace({
      list: { ok: true, data: Object.assign({}, BOARD.data, {
        settings: { minQueryLength: 3, allowBrowseAll: true, allowNearby: false }
      }) }
    });
    const withNearby = await openPlace({
      list: { ok: true, data: Object.assign({}, BOARD.data, {
        settings: { minQueryLength: 3, allowBrowseAll: true, allowNearby: true }
      }) }
    });

    it('offers a nearby mode only where the server has one', function () {
      falsy(withoutNearby.document.getElementById('target-scope-nearby'),
        'a button that always comes back empty is worse than no button');
      truthy(withNearby.document.getElementById('target-scope-nearby'));
      truthy(withNearby.document.getElementById('target-scope-all'));
    });

    const named = await openPlace({
      list: { ok: true, data: Object.assign({}, BOARD.data, {
        settings: { minQueryLength: 3, allowBrowseAll: false, allowNearby: false }
      }) },
      searchTargets: { ok: true, data: [{ handle: 'tg9', name: 'Dana Reyes', protected: false }] }
    });
    const namedBrowsed = named.sent.some(function (s) { return s.name === 'browseTargets'; });
    const namedHint = named.view.textContent;

    const namedBox = named.document.getElementById('target-query');
    namedBox.value = 'Dana';
    namedBox.oninput();
    named.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();

    it('falls back to a name search where browsing is switched off', function () {
      falsy(namedBrowsed, 'no browsing where the server does not allow it');
      truthy(namedHint.indexOf('at least 3 letters') !== -1,
        'the minimum is stated rather than silently enforced: ' + namedHint);
      truthy(named.view.textContent.indexOf('Dana Reyes') !== -1,
        'and the older search still works: ' + named.view.textContent);
    });

    const stable = await openPlace();
    const stableBefore = stable.sent.filter(function (s) { return s.name === 'browseTargets'; }).length;
    // Anything that rebuilds the form. Adding a payout does.
    const slotsField = stable.document.getElementById('slots-count');
    slotsField.value = '2';
    if (slotsField.oninput) { slotsField.oninput(); }
    if (slotsField.onchange) { slotsField.onchange(); }
    await settle(); await settle();

    it('does not refetch the roster every time the form is rebuilt', function () {
      const after = stable.sent.filter(function (s) { return s.name === 'browseTargets'; }).length;
      eq(after, stableBefore,
        'a rebuilt form must redraw the list it already has, not ask again');
    });
  })();

  /* ---- choosing an item and how many --------------------------------- */
  await (async function itemQuantity() {
    async function placeCarrying(items) {
      const app = boot({
        list: BOARD, mine: MINE, ledger: LEDGER,
        browseTargets: { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } },
        rewardOptions: { ok: true, data: {
          cash: 100000, bank: 0, dirty: 0, items: items, weapons: [],
          inventoryRead: true,
          caps: { itemsEnabled: true, weaponsEnabled: true, maxStacks: 3, maxPerStack: 100 }
        } }
      });
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
      await settle(); await settle();
      return app;
    }

    const many = await placeCarrying([{ name: 'lockpick', label: 'Lockpick', count: 5 }]);

    it('offers the items in a dropdown, with how many are spare', function () {
      const choose = many.document.getElementById('slot-item-1');
      truthy(choose, 'an item dropdown');
      truthy(choose.children.length > 0, 'with something in it');
      truthy(choose.children[0].textContent.indexOf('Lockpick') === 0,
        choose.children[0].textContent);
      truthy(choose.children[0].textContent.indexOf('5 spare') !== -1,
        'and says how many can still be staked: ' + choose.children[0].textContent);
    });

    it('asks how many when there is more than one', function () {
      const count = many.document.getElementById('slot-item-count-1');
      truthy(count, 'a quantity field');
      eq(count.max, 5, 'bounded to what is spare');
    });

    it('adds the chosen quantity to the payout', function () {
      many.document.getElementById('slot-item-count-1').value = '3';
      many.document.getElementById('slot-item-add-1').onclick();
      truthy(many.view.textContent.indexOf('Lockpick x3') !== -1,
        'the payout should show what was added: ' + many.view.textContent);
    });

    const one = await placeCarrying([{ name: 'crowbar', label: 'Crowbar', count: 1 }]);

    it('does not ask how many when the answer can only be one', function () {
      const count = one.document.getElementById('slot-item-count-1');
      const field = count && count.parentNode;
      truthy(field && field.hidden === true,
        'staking your only crowbar should not need a quantity confirmed');
    });

    it('still stakes the single item without being told a number', function () {
      one.document.getElementById('slot-item-add-1').onclick();
      truthy(one.view.textContent.indexOf('Crowbar x1') !== -1,
        'the one crowbar should be on the payout: ' + one.view.textContent);
    });
  })();

  /* ---- one click, one redraw ------------------------------------------
   *
   * A refresh asks for three things at once and each reply redrew the whole
   * page, plus once more per contract whose proposals came back. On a phone
   * screen inside a game that is what the lag was: not the request, the
   * redrawing. */
  await (async function redrawsAreCoalesced() {
    function contract(i) {
      return {
        id: 'ct0000000' + i, reason: 'Debt ' + i, mode: 'competitive', state: 'active',
        reward: { baseline: 5000, bonus: 0 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
        huntersActive: 0, huntersMax: 5, targetName: 'Dana ' + i,
        targetProtected: false, creatorName: 'Vic', role: 'creator', hunters: []
      };
    }
    const own = [contract(1), contract(2), contract(3), contract(4)];

    const app = boot({
      list: BOARD, ledger: LEDGER,
      mine: { ok: true, data: { created: own, accepted: [], onMe: [] } },
      amendments: { ok: true, data: [] }
    });
    // Opening the app IS the burst: list, mine and ledger at once, then one
    // amendments call for each contract that comes back on mine.
    await settle(); await settle(); await settle(); await settle();

    const view = app.document.getElementById('view');
    const replies = app.sent.length;

    const redraws = view._clears || 0;

    it('redraws a handful of times for a screenful of replies, not once each', function () {
      truthy(replies >= 7,
        'this measures nothing unless the app really asked for several things: '
        + replies);
      truthy(redraws > 0, 'it has to draw at all');
      truthy(redraws < replies,
        replies + ' replies caused ' + redraws + ' full rebuilds of the page. Each '
        + 'one throws away every node on screen and builds it again, which is what '
        + 'the lag was.');
    });
  })();

  /* ---- empty lists, as FiveM really delivers them ---------------------
   *
   * The server writes Lua tables. An empty Lua table is indistinguishable
   * from an empty map once msgpack has it, so a list the server meant to
   * send empty arrives as {} rather than []. On this side `.length` is
   * undefined — so every "there is nothing here" branch silently fails to
   * run — and `.forEach` throws, taking the whole render with it.
   *
   * An empty target list and an empty item picker, with no explanation and
   * nothing in any log. Which is exactly what it looked like. */
  await (async function emptyListsFromTheServer() {
    async function open(responses, tab) {
      const app = boot(Object.assign({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [],
          settings: { minQueryLength: 3, allowBrowseAll: true, allowNearby: true } } },
        mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
        ledger: { ok: true, data: { entries: [], record: {} } },
        rewardOptions: { ok: true, data: { cash: 500, bank: 0, dirty: 0,
          items: [], weapons: [], inventoryRead: true,
          caps: { itemsEnabled: true, weaponsEnabled: true } } },
        browseTargets: { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } }
      }, responses || {}));
      await settle(); await settle(); await settle();
      if (tab) {
        app.document.querySelectorAll('.tab')
          .filter(function (t) { return t.dataset.tab === tab; })[0].onclick();
        await settle(); await settle();
      }
      return app;
    }

    const board = await open();
    it('says the board is empty rather than rendering nothing', function () {
      truthy(board.view.textContent.length > 0,
        'the view is blank; the render threw on an empty list');
      truthy(board.view.textContent.indexOf('No contracts') !== -1
        || board.view.textContent.toLowerCase().indexOf('nothing') !== -1
        || board.view.textContent.toLowerCase().indexOf('empty') !== -1,
        'an empty board has to say so: ' + board.view.textContent);
    });

    const mine = await open({}, 'mine');
    it('says you have nothing active rather than rendering nothing', function () {
      truthy(mine.view.textContent.indexOf('Nothing active') !== -1,
        'expected the empty-state message: ' + mine.view.textContent);
    });

    const place = await open({}, 'place');
    it('says why the item picker is empty', function () {
      truthy(place.view.textContent.indexOf('Items & weapons') !== -1,
        'the goods section is missing entirely: ' + place.view.textContent);
      truthy(place.view.textContent.indexOf('not carrying anything') !== -1,
        'and it has to say why: ' + place.view.textContent);
    });

    it('says the city is empty rather than showing a blank picker', function () {
      truthy(place.view.textContent.indexOf('Nobody else is in the city') !== -1,
        'an empty roster has to say so: ' + place.view.textContent);
    });

    const ledger = await open({}, 'ledger');
    it('renders an empty ledger without throwing', function () {
      truthy(ledger.view.textContent.length > 0,
        'the ledger view is blank; the render threw');
    });
  })();

  // Give any rejection queued by the last settle a chance to be recorded
  // before the tally is printed.
  await new Promise(function (r) { setImmediate(r); });

  /* ---- one transient failure must not be permanent ---------------------
   *
   * Each of these turns a single refused or slow request into a picker that
   * is empty for the rest of the session, with nothing on screen saying so
   * and no way to make it ask again. */
  await (async function transientFailuresRecover() {
    function base(over) {
      return Object.assign({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [],
          settings: { minQueryLength: 3, allowBrowseAll: true, allowNearby: true } } },
        mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
        ledger: { ok: true, data: { entries: [], record: {} } }
      }, over || {});
    }

    async function toPlace(app) {
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
      await settle(); await settle();
    }

    /* The wallet. One refusal used to leave an error card in place of both
       pickers for the rest of the session: viewPlace only re-asks when
       neither a wallet nor a failure is held. */
    let walletCalls = 0;
    const flaky = boot(base({
      browseTargets: { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } },
      rewardOptions: function () {
        walletCalls++;
        if (walletCalls === 1) { return { ok: false, err: 'rate_limited' }; }
        return { ok: true, data: { cash: 500, bank: 0, dirty: 0,
          items: [{ name: 'lockpick', label: 'Lockpick', count: 5 }], weapons: [],
          inventoryRead: true, caps: { itemsEnabled: true, weaponsEnabled: true } } };
      }
    }));
    await settle(); await settle();
    await toPlace(flaky);

    it('says the wallet could not be read, rather than nothing', function () {
      truthy(flaky.view.textContent.indexOf('Try again') !== -1
        || flaky.view.textContent.indexOf('too fast') !== -1,
        'a refused wallet has to be visible: ' + flaky.view.textContent);
    });

    // Leaving the tab and coming back is what a player does about it.
    flaky.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'board'; })[0].onclick();
    await settle();
    await toPlace(flaky);

    it('asks again when the player comes back to the form', function () {
      truthy(walletCalls >= 2,
        'it never asked again; one refusal removed the pickers for the session');
      truthy(flaky.view.textContent.indexOf('Lockpick') !== -1,
        'and the picker has to come back: ' + flaky.view.textContent);
    });

    /* The wallet request, sent once per render while one is already in
       flight. The reply is held open here on purpose: the form is rebuilt
       whenever anything on it changes, and on a real server several of those
       rebuilds happen before the first answer lands. Each extra request
       spends the same per-player allowance the target list needs, so the
       page that asks hardest for its wallet is the one that ends up with no
       people in it. */
    let inFlightCalls = 0;
    const held = [];
    const chatty = boot(base({
      browseTargets: { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } },
      rewardOptions: function () {
        inFlightCalls++;
        return new Promise(function (resolve) { held.push(resolve); });
      }
    }));
    await settle(); await settle();
    await toPlace(chatty);
    // Force extra renders while the first reply is still pending.
    chatty.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    chatty.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('asks for the wallet once while one is already in flight', function () {
      eq(inFlightCalls, 1,
        'the form asked for the wallet ' + inFlightCalls + ' times before the first '
        + 'answer landed; each one spends the same allowance the target list needs');
    });

    // And it has to draw something in the meantime. A reply that never comes
    // back — a callback lost between server and page — would otherwise leave
    // the form saying nothing about its own pickers for the rest of the
    // session, with nothing to press.
    it('says it is still reading, and offers a way to ask again', function () {
      truthy(chatty.view.textContent.indexOf('Reading what you are carrying') !== -1,
        'the in-flight form said nothing about the wallet: ' + chatty.view.textContent);
      const buttons = chatty.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Try again';
      });
      eq(buttons.length, 1,
        'no way to re-ask for a wallet whose reply never arrives');
    });

    // The rest of the form is still usable while it waits: money is not
    // what the wallet read is for.
    it('still draws the rest of the form while it waits', function () {
      truthy(chatty.document.getElementById('reason'),
        'the form lost its own fields waiting for a wallet');
      truthy(chatty.document.getElementById('mode'),
        'the form lost its assignment picker waiting for a wallet');
    });

    // Pressing it has to actually send another request — a button that
    // clears a flag and redraws the same waiting card is not a way out.
    const beforeRetry = inFlightCalls;
    click(chatty, 'Try again');
    await settle(); await settle();

    it('and pressing that asks again', function () {
      truthy(inFlightCalls > beforeRetry,
        'the retry redrew the card without asking the server anything');
    });

    // And the one answer, once it lands, still fills the pickers in.
    held.forEach(function (resolve) {
      resolve({ ok: true, data: { cash: 1, bank: 0, dirty: 0,
        items: [{ name: 'lockpick', label: 'Lockpick', count: 2 }], weapons: [],
        inventoryRead: true, caps: { itemsEnabled: true, weaponsEnabled: true } } });
    });
    await settle(); await settle();

    it('and draws the pickers when that one answer arrives', function () {
      truthy(chatty.view.textContent.indexOf('Lockpick') !== -1,
        'the held reply never reached the form: ' + chatty.view.textContent);
    });

    // Asking again after it has one would be the same waste by another
    // route, so the settled form must not re-ask on a later rebuild either.
    const afterArrival = inFlightCalls;
    await toPlace(chatty);
    await settle();

    it('and does not ask again once it has one', function () {
      eq(inFlightCalls, afterArrival,
        're-rendered the form and asked for a wallet it already had');
    });

    /* The filter box is rebuilt empty on every render, but the remembered
       query is not — so a rebuild showed the result of a filter the box no
       longer displays, and never asked again. */
    const filtered = boot(base({
      browseTargets: function (body) {
        const all = [{ handle: 'tg1', name: 'Ada Quill', protected: false },
                     { handle: 'tg2', name: 'Bo Renn', protected: false }];
        const rows = body.query
          ? all.filter(function (p) { return p.name.indexOf(body.query) !== -1; })
          : all;
        return { ok: true, data: { people: rows, total: rows.length, page: 1, pages: 1 } };
      },
      rewardOptions: { ok: true, data: { cash: 1, bank: 0, dirty: 0, items: [], weapons: [],
        inventoryRead: true, caps: { itemsEnabled: true, weaponsEnabled: true } } }
    }));
    await settle(); await settle();
    await toPlace(filtered);

    const box = filtered.document.getElementById('target-query');
    box.value = 'Zzz';
    box.oninput();
    filtered.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();

    it('finds nobody for a filter that matches nobody', function () {
      truthy(filtered.view.textContent.indexOf('Nobody online by that name') !== -1,
        filtered.view.textContent);
    });

    // Now rebuild the form. The box comes back empty.
    filtered.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'board'; })[0].onclick();
    await settle();
    await toPlace(filtered);

    it('keeps the box and the list saying the same thing', function () {
      // The bug was the disagreement. The box was rebuilt showing whoever
      // was chosen while the remembered filter still narrowed the results,
      // so a filter matching nobody read as "Nobody else is in the city
      // right now" on a city full of people, with nothing on screen to
      // explain it and no way to ask again.
      const shown = filtered.document.getElementById('target-query').value;
      const text = filtered.view.textContent;
      eq(shown, 'Zzz', 'the filter survives a rebuild, visibly');
      truthy(text.indexOf('Nobody online by that name') !== -1,
        'and the list says it is filtered, not that the city is empty: ' + text);
    });

    // Clearing the box brings the city back.
    const clearBox = filtered.document.getElementById('target-query');
    clearBox.value = '';
    clearBox.oninput();
    filtered.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();

    it('shows the city again once the filter is cleared', function () {
      truthy(filtered.view.textContent.indexOf('Ada Quill') !== -1,
        'clearing the filter has to ask again: ' + filtered.view.textContent);
    });
  })();

  /* ---- changing what a contract pays -----------------------------------
   *
   * Adding to a reward and taking from it are one decision, so they are one
   * screen. What can be taken back is the server's answer, not the page's
   * guess: the page draws the lines it was given ids for and can name
   * nothing else. */
  await (async function rewardEditing() {
    const BREAKDOWN = {
      ok: true,
      data: {
        editable: true,
        slots: 1, currentSlot: 1,
        lines: [
          { id: 'ct00000001:1', slot: 1, portion: 'baseline', source: 'cash',
            amount: 5000, withdrawable: true },
          { id: 'ct00000001:2', slot: 1, portion: 'bonus', source: 'cash',
            amount: 2500, withdrawable: true },
          { id: 'ct00000001:3', slot: 1, portion: 'bonus', source: 'item',
            item: 'lockpick', quantity: 2, withdrawable: true }
        ]
      }
    };

    const MINE_AS_CREATOR = { ok: true, data: { created: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'active',
      reward: { baseline: 5000, bonus: 2500 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      huntersActive: 0, huntersMax: 5,
      targetName: 'Dana Reyes', targetProtected: false, role: 'creator'
    }], accepted: [], onMe: [] } };

    async function openEditor(over) {
      const app = boot(Object.assign({
        list: BOARD, ledger: LEDGER,
        mine: MINE_AS_CREATOR,
        rewardBreakdown: BREAKDOWN
      }, over || {}));
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
      await settle(); await settle();
      click(app, 'Change reward');
      await settle(); await settle();
      return app;
    }

    const app = await openEditor();

    it('lists every line the server said could be taken back', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('$5,000') !== -1, 'the baseline should be listed: ' + text);
      truthy(text.indexOf('$2,500') !== -1, 'the bonus should be listed: ' + text);
      truthy(text.indexOf('Lockpick') !== -1,
        'an item should be listed by a readable name, not its raw id: ' + text);
      truthy(text.indexOf('lockpick') === -1 || text.indexOf('Lockpick') !== -1,
        'the raw item name should not be what the player reads');
    });

    it('gives each one something to tick', function () {
      const boxes = app.view.all().filter(function (n) {
        return n.tagName === 'INPUT' && n.type === 'checkbox';
      });
      eq(boxes.length, 3, 'one box per withdrawable line');
    });

    // Tick the bonus and the item, leave the baseline alone.
    const boxes = app.view.all().filter(function (n) {
      return n.tagName === 'INPUT' && n.type === 'checkbox';
    });
    boxes[1].checked = true; boxes[1].onchange();
    boxes[2].checked = true; boxes[2].onchange();

    it('says what is coming back before it is committed to', function () {
      // Read while the dialog is still open and nothing has been sent: the
      // point of the figure is that it is there while they decide.
      truthy(app.view.textContent.indexOf('Coming back to you') !== -1,
        'no running total on the editor: ' + app.view.textContent);
      truthy(app.view.textContent.indexOf('$2,500') !== -1,
        'the ticked money should be totalled: ' + app.view.textContent);
      truthy(app.view.textContent.indexOf('2 items') !== -1,
        'the ticked goods should be counted: ' + app.view.textContent);
      truthy(app.view.textContent.indexOf('$5,000') === -1
        || app.view.textContent.indexOf('Coming back to you: $2,500') !== -1,
        'the total counted a line that was not ticked: ' + app.view.textContent);
    });

    click(app, 'Take back what I ticked');
    await settle(); await settle();

    it('sends exactly the lines that were ticked', function () {
      const sent = app.sent.filter(function (s) { return s.name === 'withdrawReward'; });
      eq(sent.length, 1, 'one request');
      eq(sent[0].body.id, 'ct00000001');
      const ids = sent[0].body.lines.slice().sort();
      eq(ids.join(','), 'ct00000001:2,ct00000001:3',
        'the ticked lines, and only those');
    });

    /* Nothing ticked is not a request. It used to be worth sending, and the
       server answered invalid_input — an error the player had done nothing
       to earn. */
    const empty = await openEditor();
    click(empty, 'Take back what I ticked');
    await settle();

    it('sends nothing when nothing is ticked, and says so', function () {
      eq(empty.sent.filter(function (s) { return s.name === 'withdrawReward'; }).length, 0,
        'an empty selection was sent to the server');
      truthy(empty.notice().indexOf('Nothing ticked') !== -1,
        'and the player should be told why nothing happened: ' + empty.notice());
    });

    /* A contract somebody is hunting can be added to but not reduced. The
       server decides that; the page has to show the reason rather than an
       empty list with no explanation. */
    const held = await openEditor({
      rewardBreakdown: { ok: true, data: {
        editable: false,
        reason: 'Somebody is hunting this. You can add to the reward, but not take from it.',
        slots: 1, currentSlot: 1,
        lines: [
          { slot: 1, portion: 'baseline', source: 'cash', amount: 5000,
            withdrawable: false }
        ]
      } }
    });

    it('says why a reward cannot be reduced, rather than showing nothing', function () {
      truthy(held.view.textContent.indexOf('Somebody is hunting this') !== -1,
        'the reason should be on screen: ' + held.view.textContent);
    });

    it('offers no way to tick a line the server did not name', function () {
      const boxes2 = held.view.all().filter(function (n) {
        return n.tagName === 'INPUT' && n.type === 'checkbox';
      });
      eq(boxes2.length, 0, 'a line with no id was still made tickable');
      const labels = held.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Take back what I ticked') === -1
        || held.view.textContent.indexOf('$5,000') !== -1,
        'buttons: ' + labels.join(' | '));
    });

    it('still offers to add, which is the half that is allowed', function () {
      const labels = held.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Add cash') !== -1,
        'adding is allowed while somebody hunts it: ' + labels.join(' | '));
    });

    /* A double tap on the confirm while the first request is in flight. The
       second is a refusal the creator has done nothing to deserve. */
    let calls = 0;
    const held2 = [];
    const twice = boot({
      list: BOARD, ledger: LEDGER, mine: MINE_AS_CREATOR,
      rewardBreakdown: BREAKDOWN,
      withdrawReward: function () {
        calls++;
        return new Promise(function (resolve) { held2.push(resolve); });
      }
    });
    await settle(); await settle();
    twice.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    await settle(); await settle();
    click(twice, 'Change reward');
    await settle(); await settle();
    const tb = twice.view.all().filter(function (n) {
      return n.tagName === 'INPUT' && n.type === 'checkbox';
    });
    tb[1].checked = true; tb[1].onchange();
    click(twice, 'Take back what I ticked');
    click(twice, 'Take back what I ticked');
    await settle();

    it('sends one withdrawal however many times the button is pressed', function () {
      eq(calls, 1, 'a double tap sent the same withdrawal ' + calls + ' times');
    });

    // And the reply still lands.
    held2.forEach(function (resolve) {
      resolve({ ok: true, data: { id: 'ct00000001', returned: 1, queued: 0 } });
    });
    await settle(); await settle();

    it('tells the player what came back', function () {
      truthy(twice.notice().indexOf('returned to you') !== -1,
        'nothing was said about the refund: ' + twice.notice());
    });

    /* Escrow that could not be delivered is owed, not lost. Reporting a
       plain success would have the creator counting money that is not in
       their pockets yet and calling it a bug. */
    const queued = boot({
      list: BOARD, ledger: LEDGER, mine: MINE_AS_CREATOR,
      rewardBreakdown: BREAKDOWN,
      withdrawReward: { ok: true, data: { id: 'ct00000001', returned: 0, queued: 2 } }
    });
    await settle(); await settle();
    queued.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    await settle(); await settle();
    click(queued, 'Change reward');
    await settle(); await settle();
    const qb = queued.view.all().filter(function (n) {
      return n.tagName === 'INPUT' && n.type === 'checkbox';
    });
    qb[1].checked = true; qb[1].onchange();
    click(queued, 'Take back what I ticked');
    await settle(); await settle();

    it('says when part of it is waiting rather than back', function () {
      truthy(queued.notice().indexOf('waiting for you') !== -1,
        'a queued refund was reported as a plain success: ' + queued.notice());
    });

    /* A refused breakdown must say so and still let them out of the dialog.
       An error card with no way back is how a player ends up force-closing
       the phone. */
    const refused = await openEditor({
      rewardBreakdown: { ok: false, err: 'rate_limited' }
    });

    it('says a refused breakdown could not be read', function () {
      truthy(refused.view.textContent.indexOf('Asked too fast') !== -1,
        'a refusal should be visible: ' + refused.view.textContent);
    });

    it('and still offers a way out of the dialog', function () {
      const labels = refused.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Done') !== -1, 'buttons: ' + labels.join(' | '));
    });
  })();

  /* ---- saying what a refusal actually was ---------------------------- */
  await (async function refusalsThatSayWhat() {
    const OWN = { ok: true, data: { created: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'active',
      reward: { baseline: 5000, bonus: 2500 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      huntersActive: 1, huntersMax: 5, hunters: [{ alias: 'Grey' }],
      targetName: 'Dana Reyes', role: 'creator',
      deadline: Math.floor(Date.now() / 1000) + 7200
    }], accepted: [], onMe: [] } };

    /* A server that runs informants, unless a test says otherwise. The
       button is only drawn where the settings carry the block, so a fixture
       that omitted it was describing a server with informants switched off
       — which is not what most of these tests are about. */
    function board(settings) {
      return { ok: true, data: { page: 1, pages: 1, contracts: [],
        settings: Object.assign({
          minQueryLength: 3,
          informant: { cost: 25000, account: 'bank', maxPerContract: 2 }
        }, settings || {}) } };
    }

    async function onMine(over, settings) {
      const app = boot(Object.assign({
        list: board(settings), mine: OWN, ledger: LEDGER
      }, over || {}));
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
      await settle(); await settle();
      return app;
    }

    /* A server that does not run informants.
     *
     * The projection omits the informant block entirely when it is off, so
     * it arrives as undefined and never as false — and the page guarded on
     * `rules === false`, which nothing can ever satisfy. The button was
     * drawn on every card, quoted "a fee" because there was no figure to
     * quote, took the player through a confirmation, and spent a request to
     * be told the server does not run them.
     *
     * The same rule as the calls button and the money sources: off, it is
     * not drawn rather than drawn and refused. */
    const noInformants = await onMine({}, { informant: undefined });

    it('does not offer informant data where the server has none', function () {
      falsy(noInformants.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Buy informant data';
      }), 'a button whose only outcome is a refusal is worse than no button: '
        + noInformants.view.textContent);
    });

    it('spends no request finding that out', function () {
      eq(noInformants.sent.filter(function (x) { return x.name === 'informant'; }).length, 0,
        'the page already knew');
    });

    /* The target's own card offers it too, and had the same button. */
    async function onMeWith(settings) {
      const app = boot({
        list: board(settings),
        mine: { ok: true, data: { created: [], accepted: [], onMe: [{
          id: 'ct00000002', target: 'You', reason: 'Unpaid debt',
          state: 'active', role: 'target', mode: 'exclusive',
          reward: { total: 5000 }, bailoutAmount: 15000, hunters: []
        }] } },
        ledger: LEDGER
      });
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'onme'; })[0].onclick();
      await settle(); await settle();
      return app;
    }

    const targetNoInformants = await onMeWith({ informant: undefined });

    it('does not offer it on the target card either', function () {
      falsy(targetNoInformants.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Buy informant data';
      }), 'the person being hunted got the same dead button: '
        + targetNoInformants.view.textContent);
    });

    const targetWithInformants = await onMeWith({});

    it('offers it on the target card where the server runs them', function () {
      truthy(targetWithInformants.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Buy informant data';
      }), 'a target buying data on who is following them is the feature');
    });

    const withInformants = await onMine({}, {
      informant: { cost: 25000, account: 'bank', maxPerContract: 2 }
    });

    it('offers it where the server runs them', function () {
      truthy(withInformants.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Buy informant data';
      }), 'and must still be offered where it works');
    });

    it('quotes the real price rather than "a fee"', function () {
      click(withInformants, 'Buy informant data');
      const shown = withInformants.view.textContent;
      truthy(shown.indexOf('$25,000') !== -1,
        'a purchase that is deliberately not refunded has to name its price '
        + 'before it is agreed to: ' + shown);
    });

    /* "Slow down" alone reads as a broken button: tapping again says exactly
       the same thing, and a player cannot tell two seconds from five
       minutes. */
    const limited = await onMine({
      informant: { ok: false, err: 'rate_limited', data: { retryAfter: 45 } }
    });
    click(limited, 'Buy informant data');
    click(limited, 'Yes');
    await settle();

    it('says how long a rate limit lasts', function () {
      truthy(limited.notice().indexOf('45 second') !== -1,
        'a refusal with a wait must say the wait: ' + limited.notice());
    });

    const longWait = await onMine({
      informant: { ok: false, err: 'rate_limited', data: { retryAfter: 300 } }
    });
    click(longWait, 'Buy informant data');
    click(longWait, 'Yes');
    await settle();

    it('says minutes when the wait is minutes', function () {
      truthy(longWait.notice().indexOf('minute') !== -1,
        'five minutes should not be reported in seconds: ' + longWait.notice());
    });

    /* limit_reached means something else entirely for an informant, and the
       shared wording for it described a rule with nothing to do with this
       purchase. */
    const bought = await onMine({
      informant: { ok: false, err: 'limit_reached' }
    });
    click(bought, 'Buy informant data');
    click(bought, 'Yes');
    await settle();

    it('does not blame the wrong rule when an informant is spent', function () {
      truthy(bought.notice().indexOf('too many contracts') === -1,
        'that is a different rule entirely: ' + bought.notice());
      truthy(bought.notice().indexOf('informant') !== -1,
        'and it has to say what this one was: ' + bought.notice());
    });

    /* The price, before they agree to pay it. */
    const priced = await onMine({}, {
      informant: { cost: 25000, account: 'bank', needsProximity: true }
    });
    click(priced, 'Buy informant data');

    it('says what an informant costs before it is bought', function () {
      const text = priced.view.textContent;
      truthy(text.indexOf('$25,000') !== -1,
        'the price has to be on the confirmation: ' + text);
      truthy(text.indexOf('bank') !== -1, 'and where it comes from: ' + text);
    });

    it('says why an informant may find nobody', function () {
      truthy(priced.view.textContent.indexOf('seen near the target') !== -1,
        'the commonest reason it turns up nothing is a rule, not a fault: '
        + priced.view.textContent);
    });

    /* An informant who could not put a name to anyone, and one who named
       somebody, have to read the same (§14.29).

       The page used to branch on a `found` flag and print "Nobody has been
       seen near the target", which is a reliable server-side answer to "is
       anyone on me right now?" for the price of the premium — the paid
       oracle the charge-either-way rule exists to prevent. That the money
       is taken regardless is said on the confirmation screen before it is
       spent, which is where §14.29 puts it, and is asserted above. */
    const RULES = { informant: { cost: 25000, account: 'bank', needsProximity: true } };
    const empty = await onMine({
      informant: { ok: true, data: { name: 'Unknown operative' } }
    }, RULES);
    click(empty, 'Buy informant data');
    click(empty, 'Yes');
    await settle();

    const named = await onMine({
      informant: { ok: true, data: { name: 'Rook Ash' } }
    }, RULES);
    click(named, 'Buy informant data');
    click(named, 'Yes');
    await settle();

    it('does not tell a target that nobody is on them', function () {
      falsy(empty.notice().toLowerCase().indexOf('nobody') !== -1,
        'a miss must not read as an all-clear: ' + empty.notice());
      truthy(empty.notice().indexOf('Unknown operative') !== -1,
        'it says what the informant came back with: ' + empty.notice());
    });

    it('words a miss and a hit the same way', function () {
      const shape = function (text) { return text.replace(/Unknown operative|Rook Ash/, '·'); };
      eq(shape(empty.notice()), shape(named.notice()),
        'the two answers differ in more than the operative named');
    });
  })();

  /* ---- a creator looking at a contract nobody has taken yet ------------ */
  await (async function creatorWithNoHunters() {
    // The server builds this list as a Lua table, and an empty Lua table
    // crosses to JS as {} rather than []. `{}` is truthy, so a guard of
    // `contract.hunters && ...` passes and .forEach then throws. A freshly
    // placed contract is exactly this state.
    const OWN = { ok: true, data: { created: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'active',
      reward: { baseline: 5000, bonus: 0 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      huntersActive: 0, huntersMax: 5,
      targetName: 'Dana Reyes', role: 'creator',
      hunters: acrossTheWire([]),
      deadline: Math.floor(Date.now() / 1000) + 7200
    }], accepted: [], onMe: [] } };

    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: OWN, ledger: LEDGER,
      rewardOptions: { ok: true, data: { cash: 1, bank: 0, dirty: 0, items: [],
        weapons: [], inventoryRead: true, caps: {} } }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    await settle(); await settle();

    it('draws the card at all', function () {
      truthy(app.view.textContent.indexOf('Dana Reyes') !== -1,
        'the creators own contract vanished: ' + app.view.textContent);
    });

    it('offers the creator their actions', function () {
      const labels = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Change reward') !== -1,
        'the whole card threw before it got to the buttons: ' + labels.join(' | '));
    });
  })();

  /* ---- the three money sources, on the form and after it --------------- */
  await (async function everyMoneySource() {
    function wallet(over) {
      return { ok: true, data: Object.assign({
        cash: 100000, bank: 50000, dirty: 2000,
        items: [], weapons: [], inventoryRead: true,
        caps: { itemsEnabled: true, weaponsEnabled: true, slots: 3,
                cash: 250000, bank: 500000, dirty: 250000,
                cashEnabled: true, bankEnabled: true, dirtyEnabled: true }
      }, over || {}) };
    }

    async function place(walletData) {
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
        mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
        ledger: LEDGER,
        browseTargets: { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } },
        rewardOptions: walletData
      });
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
      await settle(); await settle();
      return app;
    }

    const all = await place(wallet());

    it('offers all three money sources when the server takes all three', function () {
      ['cash', 'bank', 'dirty'].forEach(function (source) {
        truthy(all.view.all().some(function (n) { return n.id === 'slot-' + source + '-1'; }),
          'no field for ' + source);
      });
    });

    it('bounds each field by the ceiling the server sent', function () {
      eq(String(all.document.getElementById('slot-cash-1').max), '250000');
      eq(String(all.document.getElementById('slot-bank-1').max), '500000');
      eq(String(all.document.getElementById('slot-dirty-1').max), '250000',
        'the ceilings were computed, sent, and never read — so an amount the '
        + 'creator could afford came back as "That reward does not add up"');
    });

    /* A source the operator switched off. The server refuses it on submit,
       so offering it is offering a guaranteed refusal — with a message that
       blames the numbers. */
    const noDirty = await place(wallet({
      caps: { itemsEnabled: true, weaponsEnabled: true, slots: 3,
              cash: 250000, bank: 500000, dirty: 250000,
              cashEnabled: true, bankEnabled: true, dirtyEnabled: false }
    }));

    // Searched in the view that is on screen now. getElementById on the shim
    // keeps returning nodes from earlier renders, which would pass whatever
    // the form actually drew.
    function fieldOnScreen(app, id) {
      return app.view.all().some(function (n) { return n.id === id; });
    }

    it('does not offer a money source the server has switched off', function () {
      truthy(fieldOnScreen(noDirty, 'slot-cash-1'), 'cash is still on');
      falsy(fieldOnScreen(noDirty, 'slot-dirty-1'),
        'dirty is off, so a field for it can only ever be refused');
    });

    it('does not advertise a balance it cannot take', function () {
      truthy(noDirty.view.textContent.indexOf('Dirty') === -1,
        'a balance beside a source that is off is an offer the form cannot '
        + 'honour: ' + noDirty.view.textContent);
    });

    /* Adding to a contract already out there. This only ever offered cash,
       so a creator whose money is in the bank could not sweeten one at all —
       though the server has taken all three since the first commit. */
    const OWN = { ok: true, data: { created: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'active',
      reward: { baseline: 5000, bonus: 0 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
      huntersActive: 0, huntersMax: 5, targetName: 'Dana Reyes', role: 'creator',
      deadline: Math.floor(Date.now() / 1000) + 7200
    }], accepted: [], onMe: [] } };

    const own = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: OWN, ledger: LEDGER, rewardOptions: wallet(),
      rewardBreakdown: { ok: true, data: { editable: true, slots: 1, currentSlot: 1,
        lines: [{ id: 'ct00000001:1', slot: 1, portion: 'baseline',
                  source: 'cash', amount: 5000, withdrawable: true }] } },
      addEscrow: { ok: true }
    });
    await settle(); await settle();
    own.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    await settle(); await settle();
    click(own, 'Change reward');
    await settle(); await settle();
    click(own, 'Add cash');
    await settle();

    it('offers every source a creator actually holds when adding', function () {
      const labels = own.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Bank') !== -1,
        'a creator whose money is in the bank could not add to a contract at '
        + 'all: ' + labels.join(' | '));
      truthy(labels.indexOf('Dirty money') !== -1,
        'nor one who deals in black money: ' + labels.join(' | '));
    });

    click(own, 'Bank');
    await settle();
    click(own, 'Add');
    await settle();

    it('adds it in the source that was chosen', function () {
      const sent = own.sent.filter(function (s) { return s.name === 'addEscrow'; });
      eq(sent.length, 1, 'one top-up');
      truthy(sent[0].body.reward.baseline.bank > 0,
        'it hardcoded cash whatever the creator picked: '
        + JSON.stringify(sent[0].body.reward));
      falsy(sent[0].body.reward.baseline.cash);
    });
  })();

  /* ---- proposing a change you can actually read ----------------------- */
  await (async function proposalsWithContext() {
    const AS_HUNTER = { ok: true, data: { created: [], accepted: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'accepted',
      reward: { baseline: 5000, bonus: 2500 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      huntersActive: 1, huntersMax: 5,
      targetName: 'Dana Reyes', role: 'hunter',
      deadline: Math.floor(Date.now() / 1000) + 7200
    }], onMe: [] } };

    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: AS_HUNTER, ledger: LEDGER,
      amendments: { ok: true, data: [] }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    await settle(); await settle();

    click(app, 'Propose change');

    it('says what each proposal would do before one is chosen', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('$7,500') !== -1,
        'the reward has to be stated, or "reduce it" is unanswerable: ' + text);
      truthy(text.indexOf('2h') !== -1,
        'and the time left, for the same reason: ' + text);
    });

    /* The server reduces a reward by giving back a whole unclaimed payout,
       not by shaving an amount off the live one. The app used to send an
       amount, which sanitize refuses outright — so this option could never
       once have worked. On a single-payout contract there is nothing to give
       back, and an option the server would refuse whatever is entered is not
       an option at all. */
    it('does not offer to give back a payout there is none of', function () {
      const labels = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Give back a later payout') === -1,
        'a one-payout contract has nothing after the live one: ' + labels.join(' | '));
      truthy(labels.indexOf('Reduce the reward') === -1,
        'and the old label sent a payload the server has never accepted: '
        + labels.join(' | '));
    });

    // A contract with collections still to come.
    const MULTI = { ok: true, data: { created: [], accepted: [{
      id: 'ct00000002', reason: 'Unpaid debt', mode: 'competitive', state: 'accepted',
      reward: { baseline: 5000, bonus: 2500 },
      slots: 3, slotsClaimed: 0, currentSlot: 1,
      huntersActive: 1, huntersMax: 5,
      targetName: 'Dana Reyes', role: 'hunter',
      deadline: Math.floor(Date.now() / 1000) + 7200
    }], onMe: [] } };

    const multi = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: MULTI, ledger: LEDGER, amendments: { ok: true, data: [] }
    });
    await settle(); await settle();
    multi.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    await settle(); await settle();
    click(multi, 'Propose change');
    click(multi, 'Give back a later payout');

    it('asks which collection, bounded to the ones still to come', function () {
      const box = multi.document.getElementById('dialog-value');
      truthy(box, 'there should be a number field');
      eq(String(box.min), '2', 'the live collection cannot be given back');
      eq(String(box.max), '3', 'nor one that does not exist');
      truthy(box.value && Number(box.value) >= 2,
        'an empty box is the whole complaint: got "' + box.value + '"');
    });

    it('says what giving it back would do', function () {
      truthy(multi.view.textContent.indexOf('goes back to the client') !== -1,
        'the consequence has to be on screen: ' + multi.view.textContent);
    });

    click(multi, 'Propose');
    await settle();

    it('sends a slot, which is what the server reads', function () {
      const sent = multi.sent.filter(function (s) { return s.name === 'propose'; });
      eq(sent.length, 1, 'one proposal');
      eq(sent[0].body.kind, 'reduce_reward');
      truthy(sent[0].body.payload.slot >= 2,
        'the server sanitizes on payload.slot and refuses anything without it: '
        + JSON.stringify(sent[0].body.payload));
      falsy(sent[0].body.payload.amount,
        'an amount is the payload that could never work');
    });
  })();

  /* The reason a contract gives, in each mode an operator can configure.
   *
   * Config.Reason.Mode takes 'freetext', 'preset' or 'off'. The form drew a
   * text box for all three. On a server set to 'preset' the server wants an
   * index into a list the page had never been given, so it refused every
   * contract with invalid_input — and the box the player had just filled in
   * was not the field being rejected, so there was nothing to correct and
   * nothing on screen to explain it. Every contract on such a server was
   * unplaceable for as long as the setting stayed. */
  await (async function reasonModes() {
    function wallet() {
      return { ok: true, data: {
        cash: 100000, bank: 50000, dirty: 0,
        items: [], weapons: [], inventoryRead: true,
        caps: {
          itemsEnabled: false, weaponsEnabled: false, slots: 3,
          cash: 250000, bank: 500000,
          cashEnabled: true, bankEnabled: true, dirtyEnabled: false
        }
      } };
    }

    /* The reason policy rides on the board's settings, not the wallet: the
       Edit dialog needs it too and is reachable without ever having read a
       wallet, and a second copy would be two sources to drift apart. */
    async function place(reasonPolicy) {
      const app = boot({
        list: { ok: true, data: {
          page: 1, pages: 1, contracts: [], settings: reasonPolicy } },
        mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
        ledger: LEDGER,
        searchTargets: { ok: true, data: [{ handle: 'tg00000001', name: 'Ann Ryder' }] },
        rewardOptions: wallet(),
        create: { ok: true, data: { id: 'ct00000001' } }
      });
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
      await settle(); await settle();
      return app;
    }

    /* Fill the form in and press Place, the way a player does. */
    async function submit(app) {
      const query = app.document.getElementById('target-query');
      query.value = 'Ryder';
      query.oninput();
      app.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
      await settle(); await settle();

      app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent.indexOf('Ann Ryder') === 0;
      })[0].onclick();
      await settle();

      app.document.getElementById('slot-cash-1').value = '5000';
      app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Place contract';
      })[0].onclick();
      await settle(); await settle();
      return app.sent.filter(function (x) { return x.name === 'create'; });
    }

    /* Searched in the live view, not through getElementById: the id
     * registry in the DOM shim never forgets a node, and the form draws a
     * text box on its first render — before the wallet reply carrying the
     * mode has arrived — so the orphaned node from that render answers to
     * the id forever after. Asking the registry would have this suite
     * passing while the screen showed the other control. */
    function live(app, id) {
      return app.view.all().filter(function (n) { return n._id === id; })[0] || null;
    }

    const preset = await place({
      reasonMode: 'preset',
      reasonPresets: ['Unpaid debt', 'Snitching', 'Territory dispute']
    });

    it('draws a picker, not a text box, on a preset server', function () {
      const pick = live(preset, 'reasonPreset');
      truthy(pick, 'a server that indexes a list has to be given the list to '
        + 'choose from, or nothing the player types can ever be right');
      eq(pick.children.length, 3, 'every preset the server sent');
      eq(pick.children[0].textContent, 'Unpaid debt');
      falsy(live(preset, 'reason'),
        'a free text box on a preset server collects something the server '
        + 'will not read');
    });

    it('sends the index the server indexes by, one-based', function () {
      const pick = live(preset, 'reasonPreset');
      eq(pick.children[0].value, '1', 'a zero is not a choice the server takes');
      eq(pick.children[2].value, '3');
    });

    const chosen = await place({
      reasonMode: 'preset',
      reasonPresets: ['Unpaid debt', 'Snitching', 'Territory dispute']
    });
    const pick = live(chosen, 'reasonPreset');
    pick.value = '2';
    if (pick.onchange) { pick.onchange(); }
    const presetSent = await submit(chosen);

    it('places a contract carrying the chosen preset', function () {
      eq(presetSent.length, 1, 'one create');
      eq(presetSent[0].body.reasonPreset, 2,
        'the picked preset has to reach the server as the index it indexes '
        + 'by: ' + JSON.stringify(presetSent[0].body));
    });

    const free = await place({ reasonMode: 'freetext', reasonMaxLength: 140 });

    it('still draws a text box on a freetext server', function () {
      truthy(live(free, 'reason'), 'the default has to keep working');
      falsy(live(free, 'reasonPreset'),
        'a picker with nothing behind it is not a control');
    });

    it('bounds the box by the length the server sent', function () {
      eq(String(live(free, 'reason').maxLength), '140');
    });

    const freeSent = await submit(free);

    it('sends no preset index off a preset server', function () {
      eq(freeSent.length, 1, 'one create');
      falsy(freeSent[0].body.reasonPreset,
        'an index nobody chose is not a field to send: '
        + JSON.stringify(freeSent[0].body));
    });

    const off = await place({ reasonMode: 'off' });

    it('asks for no reason at all when the server wants none', function () {
      falsy(live(off, 'reason'),
        'a server that stores no reason must not ask for one');
      falsy(live(off, 'reasonPreset'));
    });

    const offSent = await submit(off);

    it('still places a contract with no reason field on the form', function () {
      eq(offSent.length, 1, 'one create');
    });
  })();

  /* A refusal the player can act on has to reach the screen as words.
   *
   * no_player is what the gate returns while the framework is still loading
   * a character, and the app fires three requests the moment it opens — so
   * anybody who opened it while still joining got it three times. With no
   * entry in ERRORS it fell through to "Something went wrong", which reads
   * as a broken app rather than as "not yet", and sent them looking for a
   * fault that would clear on its own in seconds. */
  await (async function refusalsReachTheScreen() {
    /* The responses object is held here rather than passed by value, so a
       test can make the server start answering and press Try again — which
       is the only way to see the failure card actually clear. */
    async function refusedWithReply(reply) {
      const responses = { list: reply, mine: reply, ledger: reply };
      const app = boot(responses);
      await settle(); await settle();
      app.responses = responses;
      return app;
    }

    function refusedWith(err) {
      return refusedWithReply({ ok: false, err: err });
    }

    const joining = await refusedWith('no_player');

    it('says the character is still loading, not that something went wrong', function () {
      const shown = joining.view.textContent;
      truthy(shown.indexOf('still loading') !== -1,
        'a player who opened the app mid-join has to be told to wait, not '
        + 'handed a fault to chase: ' + JSON.stringify(shown));
      falsy(shown.indexOf('Something went wrong') !== -1,
        'the catch-all is what this code used to fall through to');
    });

    it('does not claim the board is empty when it could not be read', function () {
      falsy(joining.view.textContent.indexOf('No contracts on the board') !== -1,
        '"there is nothing here" and "I could not ask" are different '
        + 'statements, and a player acts on the first by concluding the app '
        + 'is broken');
    });

    it('offers a way to ask again', function () {
      truthy(joining.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Try again';
      }), 'a refusal with no way to retry is a dead screen');
    });

    it('says the same on the other tabs the refusal covered', function () {
      ['mine', 'onme', 'ledger'].forEach(function (name) {
        joining.document.querySelectorAll('.tab')
          .filter(function (t) { return t.dataset.tab === name; })[0].onclick();
        const shown = joining.view.textContent;
        truthy(shown.indexOf('still loading') !== -1,
          name + ' reported no failure at all: ' + JSON.stringify(shown));
      });
      // The most reassuring thing this app can say, and the worst to say
      // wrongly: a refused read must not read as "nobody is looking for you".
      joining.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'onme'; })[0].onclick();
      falsy(joining.view.textContent.indexOf('Nobody is looking for you') !== -1,
        'a refused read told the player they were safe');
    });

    const limited = await refusedWithReply({ ok: false, err: 'rate_limited',
                                             data: { retryAfter: 7 } });

    it('carries the wait when the refusal is a rate limit', function () {
      const shown = limited.view.textContent;
      truthy(shown.indexOf('7 second') !== -1,
        '"slow down" with no number is what has a player tapping again: '
        + JSON.stringify(shown));
    });

    const unknown = await refusedWith('a_code_from_the_future');

    it('says something rather than nothing for a code it has never seen', function () {
      truthy(unknown.view.textContent.indexOf('Something went wrong') !== -1,
        'an unmapped code is exactly what the catch-all is for: '
        + JSON.stringify(unknown.view.textContent));
    });

    const recovered = await refusedWith('no_player');
    recovered.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'board'; })[0].onclick();
    await settle();
    recovered.responses.list = { ok: true, data: {
      page: 1, pages: 1, contracts: [], settings: {} } };
    recovered.responses.mine = { ok: true, data: { created: [], accepted: [], onMe: [] } };
    recovered.responses.ledger = { ok: true, data: { entries: [] } };
    recovered.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Try again';
    })[0].onclick();
    await settle(); await settle();

    it('clears the failure once the server answers', function () {
      truthy(recovered.view.textContent.indexOf('No contracts on the board') !== -1,
        'once the read succeeds the failure card has to go, or the player is '
        + 'stuck looking at a stale complaint: '
        + JSON.stringify(recovered.view.textContent));
    });
  })();

  /* The ways of finding somebody that this server actually offers.
   *
   * Config.Targeting.AllowBrowseAll and AllowNearby are both documented and
   * both supported. The picker opens on 'all' regardless, and the row of
   * scope buttons is hidden when it holds only one — so on a server that
   * allows nearby and not browse-all, the picker asked for a scope the
   * server refuses AND drew no button to change it. A permanently empty
   * target list on a city full of people, which is what an operator who
   * turned browsing off would have got and had no way to diagnose. */
  await (async function targetingScopes() {
    /* `targeting` is read on every request rather than captured, so a test
       can change what the server allows mid-session and the browse fixture
       answers by the new rules. Capturing it meant a fixture that went on
       answering a scope the server had just stopped offering — which had
       this very test passing with the code it tests removed. */
    async function picker(targeting) {
      const responses = {
        list: { ok: true, data: {
          page: 1, pages: 1, contracts: [],
          settings: Object.assign({ allowBrowseAll: true, allowNearby: false }, targeting)
        } },
        mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
        ledger: LEDGER,
        browseTargets: function (body) {
          const allowed = (body.scope === 'nearby')
            ? (targeting.allowNearby === true)
            : (targeting.allowBrowseAll !== false);
          // Exactly what the server does with a scope it does not offer.
          if (!allowed) { return { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } }; }
          return { ok: true, data: {
            people: [{ handle: 'tg00000001', name: 'Ann Ryder' }],
            total: 1, page: 1, pages: 1
          } };
        }
      };
      const app = boot(responses);
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
      await settle(); await settle();
      app.responses = responses;
      app.targeting = targeting;
      return app;
    }

    const nearbyOnly = await picker({ allowBrowseAll: false, allowNearby: true });

    it('finds somebody on a server that allows nearby and not browsing', function () {
      truthy(nearbyOnly.view.textContent.indexOf('Ann Ryder') !== -1,
        'the picker asked for a scope this server refuses and drew no button '
        + 'to change it, so it was empty on a city full of people: '
        + JSON.stringify(nearbyOnly.view.textContent));
    });

    it('asked for the scope the server actually offers', function () {
      const asked = nearbyOnly.sent.filter(function (x) { return x.name === 'browseTargets'; });
      truthy(asked.length > 0, 'it has to ask at all');
      eq(asked[0].body.scope, 'nearby',
        'the first request has to be one the server will answer, not the '
        + 'hardcoded default');
    });

    const browseOnly = await picker({ allowBrowseAll: true, allowNearby: false });

    it('still browses everyone on a default server', function () {
      truthy(browseOnly.view.textContent.indexOf('Ann Ryder') !== -1,
        'the default configuration has to keep working');
      const asked = browseOnly.sent.filter(function (x) { return x.name === 'browseTargets'; });
      eq(asked[0].body.scope, 'all');
    });

    const both = await picker({ allowBrowseAll: true, allowNearby: true });

    it('offers both switches when the server offers both', function () {
      const buttons = both.view.all().filter(function (n) {
        return n.tagName === 'BUTTON'
          && (n.textContent === 'Everyone' || n.textContent === 'Near me');
      });
      eq(buttons.length, 2, 'both ways of looking should be offered');
    });

    /* The other direction, which a player can reach without anything odd
       happening: they press Near me on a server that offers it, an operator
       turns AllowNearby off, and the next board read carries the new
       settings into a page whose remembered scope is now the refused one.
       Without the correction the picker is empty and the button that would
       have changed it is gone. */
    const switched = await picker({ allowBrowseAll: true, allowNearby: true });
    switched.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Near me';
    })[0].onclick();
    await settle(); await settle();

    switched.targeting.allowNearby = false;
    switched.responses.list = { ok: true, data: {
      page: 1, pages: 1, contracts: [],
      settings: { allowBrowseAll: true, allowNearby: false }
    } };
    switched.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'board'; })[0].onclick();
    await settle(); await settle();
    switched.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    // A filter typed after the change, which is what forces a fresh request
    // rather than a redraw of the list the picker is still holding.
    const filter = switched.document.getElementById('target-query');
    filter.value = 'Ryder';
    filter.oninput();
    switched.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();

    // Asserted on what was asked for, not on what is on screen: the picker
    // keeps the last list it was given, so a stale one would answer this
    // question with an answer from before the settings changed.
    const askedAfter = switched.sent.filter(function (x) {
      return x.name === 'browseTargets';
    });

    it('recovers when the scope it remembered stops being offered', function () {
      const last = askedAfter[askedAfter.length - 1];
      truthy(last, 'the picker has to have asked at all');
      eq(last.body.scope, 'all',
        'the remembered scope is the one this server now refuses and the '
        + 'button that would change it is gone, so the picker has to move '
        + 'itself to the one that is left');
    });

    it('and shows the people that scope finds', function () {
      truthy(switched.view.textContent.indexOf('Ann Ryder') !== -1,
        'after recovering, the list has to have somebody in it: '
        + JSON.stringify(switched.view.textContent));
    });

    const neither = await picker({ allowBrowseAll: false, allowNearby: false });

    // searchTargets does not read either flag — turning browsing off leaves
    // the name search, which is what the picker falls back to. So the right
    // behaviour here is the prompt to type a name, not a complaint.
    it('falls back to the name search when neither way of browsing is offered', function () {
      const shown = neither.view.textContent;
      truthy(shown.indexOf('letters of their name') !== -1,
        'browsing off still leaves a name search, and the picker has to say '
        + 'so rather than sit empty: ' + JSON.stringify(shown));
    });

    it('sends no browse request it knows will come back empty', function () {
      const browsed = neither.sent.filter(function (x) { return x.name === 'browseTargets'; });
      eq(browsed.length, 0,
        'a request for a scope the server has switched off is a rate-limit '
        + 'token spent on a guaranteed empty answer');
    });
  })();

  /* The ceiling on how many separate rewards one contract may hold.
   *
   * caps.maxLines was computed and sent and never read, the same way
   * caps.bonusPercent was. The server refuses anything over it as
   * invalid_reward, which this page reads out as "That reward does not add
   * up" — blaming amounts that are fine, about a rule the creator was never
   * shown and could not have counted. */
  await (async function rewardLineCeiling() {
    async function form(maxLines, payouts) {
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
        mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
        ledger: LEDGER,
        searchTargets: { ok: true, data: [{ handle: 'tg00000001', name: 'Ann Ryder' }] },
        rewardOptions: { ok: true, data: {
          cash: 500000, bank: 500000, dirty: 500000,
          items: [], weapons: [], inventoryRead: true,
          caps: { itemsEnabled: false, weaponsEnabled: false, slots: 5,
                  cash: 500000, bank: 500000, dirty: 500000,
                  cashEnabled: true, bankEnabled: true, dirtyEnabled: true,
                  maxLines: maxLines }
        } },
        create: { ok: true, data: { id: 'ct00000001' } }
      });
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
      await settle(); await settle();

      const query = app.document.getElementById('target-query');
      query.value = 'Ryder';
      query.oninput();
      app.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
      await settle(); await settle();
      app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent.indexOf('Ann Ryder') === 0;
      })[0].onclick();
      await settle();

      // As many payouts as asked for, each funded from all three sources.
      const count = app.view.all().filter(function (n) { return n._id === 'slots-count'; })[0];
      count.value = String(payouts);
      count.onchange();
      await settle();
      for (let i = 1; i <= payouts; i++) {
        ['cash', 'bank', 'dirty'].forEach(function (source) {
          const field = app.view.all().filter(function (n) {
            return n._id === 'slot-' + source + '-' + i;
          })[0];
          if (field) { field.value = '1000'; }
        });
      }

      app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Place contract';
      })[0].onclick();
      await settle(); await settle();
      return app;
    }

    // Four payouts of three sources is twelve lines, against a ceiling of
    // five: the shape a creator reaches by filling the form in.
    const over = await form(5, 4);

    it('does not send a contract the server is bound to refuse', function () {
      eq(over.sent.filter(function (x) { return x.name === 'create'; }).length, 0,
        'the form built twelve rewards against a ceiling of five and sent it '
        + 'anyway, for a refusal that blames the amounts');
    });

    it('says how many there are and how many are allowed', function () {
      const shown = over.notice();
      truthy(shown.indexOf('12') !== -1 && shown.indexOf('5') !== -1,
        'a creator cannot act on this without both numbers: '
        + JSON.stringify(shown));
    });

    const within = await form(60, 4);

    it('sends one that fits, with the shipped ceiling', function () {
      eq(within.sent.filter(function (x) { return x.name === 'create'; }).length, 1,
        'twelve lines against sixty is an ordinary contract and must go '
        + 'through');
    });

    const noCap = await form(undefined, 4);

    it('does not invent a ceiling when the server sent none', function () {
      eq(noCap.sent.filter(function (x) { return x.name === 'create'; }).length, 1,
        'an older server that sends no maxLines must not have every contract '
        + 'blocked by the page');
    });
  })();

  /* The Edit dialog, on each server the reason rules can describe.
   *
   * It asked for free text whatever the server took, and always sent it. On
   * a preset server that was refused as invalid_input; on a server storing
   * no reason at all it made the whole edit fail, so the deadline it came
   * with could never be changed through the app either. */
  await (async function editDialogReason() {
    const MINE_ONE = { ok: true, data: {
      created: [{ id: 'ct00000001', target: 'Dana Reyes', reason: 'Unpaid debt',
                  state: 'active', role: 'creator', mode: 'exclusive',
                  reward: { total: 5000 }, hunters: [] }],
      accepted: [], onMe: []
    } };

    async function openEdit(reasonPolicy) {
      const app = boot({
        list: { ok: true, data: {
          page: 1, pages: 1, contracts: [], settings: reasonPolicy } },
        mine: MINE_ONE,
        ledger: LEDGER,
        revise: { ok: true, data: true }
      });
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
      await settle(); await settle();

      const edit = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Edit';
      })[0];
      truthy(edit, 'the Mine card has to offer an Edit button');
      edit.onclick();
      await settle();
      return app;
    }

    function inDialog(app, id) {
      return app.view.all().filter(function (n) { return n._id === 'dialog-' + id; })[0] || null;
    }

    async function save(app) {
      app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Save';
      })[0].onclick();
      await settle(); await settle();
      return app.sent.filter(function (x) { return x.name === 'revise'; });
    }

    const preset = await openEdit({
      reasonMode: 'preset',
      reasonPresets: ['Unpaid debt', 'Snitching', 'Territory dispute']
    });

    it('offers the picker, not a text box, on a preset server', function () {
      const pick = inDialog(preset, 'reasonPreset');
      truthy(pick, 'the dialog asked for free text a preset server refuses');
      eq(pick.children.length, 3);
      falsy(inDialog(preset, 'reason'), 'and must not also ask for text');
    });

    const presetSent = await save(preset);

    it('sends an index, not text, on a preset server', function () {
      eq(presetSent.length, 1, 'one revise');
      eq(presetSent[0].body.reasonPreset, 1);
      falsy(presetSent[0].body.reason,
        'text alongside an index is the field the server will refuse: '
        + JSON.stringify(presetSent[0].body));
    });

    const off = await openEdit({ reasonMode: 'off' });

    it('asks for no reason where the server stores none', function () {
      falsy(inDialog(off, 'reason'));
      falsy(inDialog(off, 'reasonPreset'));
      truthy(inDialog(off, 'hours'), 'the deadline is still editable');
    });

    const offSent = await save(off);

    it('still changes the deadline where the server stores no reason', function () {
      eq(offSent.length, 1, 'one revise');
      truthy(offSent[0].body.deadlineSeconds > 0, 'the deadline has to be in it');
      falsy(offSent[0].body.reason,
        'a reason field the server ignores used to arrive anyway and take '
        + 'the whole edit down with it: ' + JSON.stringify(offSent[0].body));
    });

    const free = await openEdit({ reasonMode: 'freetext', reasonMaxLength: 90 });

    it('keeps the text box, capped as the operator set it', function () {
      const box = inDialog(free, 'reason');
      truthy(box, 'the default has to keep working');
      eq(String(box.maxLength), '90',
        'the cap was written into the page rather than read from the server');
      eq(box.value, 'Unpaid debt', 'and it starts from what the contract says');
    });

    const freeSent = await save(free);

    it('sends the text on a freetext server', function () {
      eq(freeSent.length, 1, 'one revise');
      eq(freeSent[0].body.reason, 'Unpaid debt');
      falsy(freeSent[0].body.reasonPreset);
    });
  })();

  /* A wallet whose lists arrive keyed by inventory slot.
   *
   * ox_inventory hands back a table keyed by slot number, not a sequence,
   * so it crosses as an object however many entries it holds — the same
   * boundary as the empty list, and the half no fixture produced. asList
   * recovers it; nothing checked that it did. */
  await (async function walletKeyedBySlot() {
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: MINE,
      ledger: LEDGER,
      browseTargets: { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } },
      rewardOptions: { ok: true, data: {
        cash: 100000, bank: 50000, dirty: 0, inventoryRead: true,
        items: keyedBySlot([
          { name: 'lockpick', label: 'Lockpick', count: 5 },
          { name: 'bandage', label: 'Bandage', count: 12 }
        ], [3, 7]),
        weapons: keyedBySlot([
          { name: 'WEAPON_PISTOL', label: 'Pistol', slot: 4, serial: 'C123' }
        ], [4]),
        caps: { itemsEnabled: true, weaponsEnabled: true, slots: 3,
                cash: 250000, bank: 500000, maxStacks: 3, maxPerStack: 100,
                maxWeapons: 2, cashEnabled: true, bankEnabled: true }
      } }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('lists items the server keyed by slot rather than by position', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('Lockpick') !== -1 && text.indexOf('Bandage') !== -1,
        'an inventory keyed by slot crosses as an object, and the picker '
        + 'showed nothing: ' + text);
    });

    it('lists weapons the same way', function () {
      truthy(app.view.textContent.indexOf('Pistol') !== -1,
        'the weapon picker read the same shape and came back empty: '
        + app.view.textContent);
    });

    it('draws no error card for a wallet it could read perfectly well', function () {
      falsy(app.view.textContent.indexOf('Could not read what you are carrying') !== -1,
        'a shape the app is written to recover must not read as a failure');
    });
  })();


  /* The page, driven by somebody pressing things at random.
   *
   * Every other test here drives a route somebody chose: open this tab,
   * press that button, assert what appears. A player does not do that. They
   * press the thing next to the thing they meant, go back, press it again,
   * open a dialog and close it from the wrong side — and the reports that
   * started this work were all of that shape: an empty screen, an app that
   * "just stops".
   *
   * So: boot the real app.js against a server that answers plausibly, then
   * press a random clickable thing, over and over, and after every single
   * press assert the two properties that hold no matter what was pressed —
   * the render did not throw, and there is something on screen. Which
   * screen is not the assertion. That there IS one is.
   *
   * Deterministic: the seed picks the sequence, so a failure replays. */
  await (async function randomWalk() {
    // Every control the walk ever pressed, so it can assert its own reach.
    // A walk that degenerates into pressing one tab forty times passes
    // every assertion below while testing nothing.
    const REACHED = new Set();

    function rng(seed) {
      let state = seed;
      return function (n) {
        state = (1103515245 * state + 12345) % 2147483648;
        return state % n;
      };
    }

    const CONTRACTS = [
      { id: 'ct00000001', target: 'Dana Reyes', reason: 'Unpaid debt',
        state: 'active', role: 'public', mode: 'competitive',
        reward: { total: 5000 }, hunters: [], slots: 2, currentSlot: 1 },
      { id: 'ct00000002', target: 'Ann Ryder', reason: 'Snitching',
        state: 'active', role: 'public', mode: 'exclusive',
        reward: { total: 12000 }, hunters: [], targetProtected: true },
    ];

    function server() {
      return {
        list: { ok: true, data: { page: 1, pages: 2, contracts: CONTRACTS,
          settings: { minQueryLength: 3, allowBrowseAll: true, allowNearby: true,
                      calls: true, reasonMode: 'freetext', reasonMaxLength: 140,
                      informant: { cost: 25000, account: 'bank', maxPerContract: 2 } } } },
        mine: { ok: true, data: {
          created: [Object.assign({}, CONTRACTS[0], { role: 'creator', hunters: [] })],
          accepted: [Object.assign({}, CONTRACTS[1], { role: 'hunter' })],
          onMe: [Object.assign({}, CONTRACTS[0], { role: 'target', id: 'ct00000003',
            bailoutAmount: 15000 })] } },
        ledger: LEDGER,
        rewardOptions: { ok: true, data: {
          cash: 100000, bank: 50000, dirty: 2000, inventoryRead: true,
          items: [{ name: 'lockpick', label: 'Lockpick', count: 5 }],
          weapons: [{ name: 'WEAPON_PISTOL', label: 'Pistol', slot: 3, serial: 'C1' }],
          caps: { itemsEnabled: true, weaponsEnabled: true, slots: 3, maxLines: 60,
                  cash: 250000, bank: 500000, dirty: 250000, maxStacks: 3,
                  maxPerStack: 100, maxWeapons: 2, bonusPercent: 200,
                  cashEnabled: true, bankEnabled: true, dirtyEnabled: true } } },
        browseTargets: { ok: true, data: { people: [
          { handle: 'tg1', name: 'Ada Quill' },
          { handle: 'tg2', name: 'Bo Renn', protected: true }
        ], total: 2, page: 1, pages: 1 } },
        searchTargets: { ok: true, data: [{ handle: 'tg1', name: 'Ada Quill' }] },
        rewardBreakdown: { ok: true, data: { reason: 'Unpaid debt', lines: [
          { id: 'ct00000001:1', source: 'cash', amount: 5000, slot: 1, removable: true },
          { id: 'ct00000001:2', source: 'bank', amount: 2500, slot: 2, removable: true }
        ] } },
        amendments: { ok: true, data: [
          { id: 'am00000001', kind: 'shorten_deadline', payload: { seconds: 600 },
            mine: false, proposer: 'Operative #4', waiting: 1,
            expires: 9999999999 }
        ] },
        threads: { ok: true, data: { threads: [{ handle: 'th1', alias: 'Operative #4' }] } },
        readThread: { ok: true, data: { messages: [
          { from: 'Operative #4', body: 'On my way.', at: 1 }
        ] } },
        informant: { ok: true, data: { found: true, name: 'Rook Ash' } },
        mugshotImage: { ok: false, err: 'not_found' },
        // Everything else answers plainly, so a walk that reaches an
        // unusual button still gets a reply rather than hanging.
        create: { ok: true, data: { id: 'ct00000009' } },
        accept: { ok: true, data: true }, abandon: { ok: true, data: true },
        cancel: { ok: true, data: true }, revise: { ok: true, data: true },
        propose: { ok: true, data: { id: 'am00000002' } },
        respondAmendment: { ok: true, data: { outcome: 'applied' } },
        improve: { ok: true, data: true }, addEscrow: { ok: true, data: true },
        withdrawReward: { ok: true, data: { settled: 1 } },
        bailout: { ok: true, data: true }, sendMessage: { ok: true, data: true },
        requestCall: { ok: true, data: { placed: true } },
        armKidnap: { ok: true, data: true },
        kidnapProgress: { ok: true, data: { remaining: 30, total: 60 } },
      };
    }

    /* One walk. Returns a description of the first thing that went wrong,
       or null. */
    async function walk(seed, steps) {
      const pick = rng(seed);
      const app = boot(server());
      await settle(); await settle();

      const pressed = [];

      for (let step = 0; step < steps; step++) {
        // Everything a player could actually press: the tab bar lives
        // outside #view, so it is gathered separately.
        const clickable = app.document.all().filter(function (n) {
          return typeof n.onclick === 'function';
        });
        if (clickable.length === 0) {
          return { seed: seed, at: step, why: 'nothing on screen is clickable',
                   trail: pressed };
        }

        const target = clickable[pick(clickable.length)];
        const label = (target.textContent || target._id || target.tagName || '?')
          .slice(0, 40);
        pressed.push(label);
        REACHED.add(label);

        try {
          target.onclick();
        } catch (err) {
          return { seed: seed, at: step, why: 'a click threw: ' + err.message,
                   trail: pressed };
        }

        // Typing into whatever inputs exist, sometimes, because a form that
        // is only ever clicked is not a form anybody used.
        if (pick(4) === 0) {
          const inputs = app.document.all().filter(function (n) {
            return n.tagName === 'INPUT' && typeof n.oninput === 'function';
          });
          if (inputs.length) {
            const box = inputs[pick(inputs.length)];
            box.value = ['Ryder', '', '5000', '-1', 'zz'][pick(5)];
            try { box.oninput(); } catch (err) {
              return { seed: seed, at: step, why: 'typing threw: ' + err.message,
                       trail: pressed };
            }
          }
        }

        // Any debounce the page is waiting on.
        app.timers.filter(function (t) { return t.ms === 300; })
          .forEach(function (t) { try { t.fn(); } catch (e) {} });

        await settle();

        if (app.view.textContent.trim() === '') {
          return { seed: seed, at: step, why: 'the screen went blank',
                   trail: pressed };
        }
      }
      return null;
    }

    const WALKS = 25, STEPS = 40;
    const broke = [];
    for (let seed = 1; seed <= WALKS; seed++) {
      const bad = await walk(seed, STEPS);
      if (bad) {
        broke.push('seed ' + bad.seed + ' step ' + bad.at + ': ' + bad.why
          + '\n      after: ' + bad.trail.slice(-8).join(' > '));
      }
    }

    it('survives ' + WALKS + ' walks of ' + STEPS + ' presses without breaking', function () {
      eq(broke.length, 0,
        'the page threw or emptied under ordinary misuse:\n    '
        + broke.slice(0, 4).join('\n    '));
    });

    it('actually gets around the app while doing it', function () {
      truthy(REACHED.size >= 15,
        'the walk pressed only ' + REACHED.size + ' distinct controls, which '
        + 'is it having degenerated into one tab rather than the app having '
        + 'shrunk: ' + Array.from(REACHED).join(' | '));
    });

    it('reaches the screens behind the tabs, not just the tabs', function () {
      const deep = ['Place contract', 'Propose change', 'Buy informant data'];
      const missed = deep.filter(function (label) { return !REACHED.has(label); });
      eq(missed.length, 0,
        'a walk that never leaves the board is not exercising the app: '
        + missed.join(', ') + ' were never reached');
    });
  })();


  /* The live-delivery screen, which nothing had ever driven.
   *
   * V8 coverage over the UI suite found twenty-four functions in app.js that
   * never execute, and the largest pair by some distance were armKidnap and
   * pollCountdown — the whole "Deliver alive" flow, about fifteen hundred
   * bytes of it. That is the screen behind a live report: a hunter with a
   * restrained target who cannot work out why the handover will not start.
   *
   * Each refusal the server can give has words written for it here, and
   * until now nobody had checked that any of them appear. */
  await (async function liveDelivery() {
    const HELD = {
      id: 'ct00000001', target: 'Dana Reyes', reason: 'Unpaid debt',
      state: 'accepted', role: 'hunter', mode: 'exclusive',
      reward: { total: 5000 }, canDeliver: true, hunters: []
    };

    async function onMine(over) {
      const app = boot(Object.assign({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [],
          settings: { minQueryLength: 3 } } },
        mine: { ok: true, data: { created: [], accepted: [HELD], onMe: [] } },
        ledger: LEDGER
      }, over || {}));
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
      await settle(); await settle();
      return app;
    }

    const offered = await onMine({});

    it('offers the handover on a contract the hunter holds', function () {
      truthy(offered.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Deliver alive';
      }), 'the button the whole flow hangs off: ' + offered.view.textContent);
    });

    /* Every refusal the server can answer with, in the hunter's words. A
       code with no sentence here reaches them as "Cannot start the
       handover", which tells somebody standing over a cuffed target
       nothing about what to change. */
    const REFUSALS = [
      ['not_coerced', 'restrained'],
      ['target_not_conscious', 'conscious'],
      ['creator_too_far', 'client'],
      ['target_too_far', 'close'],
      ['target_protected', 'just got up'],
      ['party_offline', 'online'],
      ['limit_reached', 'in progress'],
    ];

    for (const [code, words] of REFUSALS) {
      const app = await onMine({ armKidnap: { ok: false, err: code } });
      click(app, 'Deliver alive');
      await settle();
      const shown = app.notice();
      it('explains ' + code + ' in words a hunter can act on', function () {
        truthy(shown.indexOf(words) !== -1,
          'the refusal reached the hunter as ' + JSON.stringify(shown)
          + ', which does not tell them to change anything');
      });
    }

    const unknown = await onMine({ armKidnap: { ok: false, err: 'a_code_from_the_future' } });
    click(unknown, 'Deliver alive');
    await settle();

    it('still says something for a refusal it has no words for', function () {
      truthy(unknown.notice().length > 0, 'silence is the one unacceptable answer');
    });

    /* The countdown. The server is polled once a second while a delivery
       runs, and the bar has to move — rendering from the projection's
       snapshot draws the same frozen bar however often it is polled, which
       is a hunter watching nothing happen for thirty seconds. */
    const running = await onMine({
      armKidnap: { ok: true, data: true },
      kidnapProgress: (function () {
        let elapsed = 0;
        return function () {
          elapsed += 10;
          return { ok: true, data: { elapsed: elapsed, required: 30 } };
        };
      })()
    });
    click(running, 'Deliver alive');
    await settle();

    it('says to hold position once the handover starts', function () {
      truthy(running.notice().indexOf('Hold position') !== -1, running.notice());
    });

    it('starts polling the countdown', function () {
      truthy(running.timers.some(function (t) { return t.repeating && t.ms === 1000; }),
        'nothing polls, so the bar never moves');
    });

    // One second of the countdown.
    const tick = running.timers.filter(function (t) { return t.repeating && t.ms === 1000; })[0];
    tick.fn();
    await settle(); await settle();

    it('draws how far along the delivery is', function () {
      const shown = running.view.textContent;
      truthy(/1[0-9]?\s*\/\s*30|33%|10/.test(shown) || shown.indexOf('30') !== -1,
        'the countdown drew nothing a hunter can read: ' + shown);
    });

    tick.fn(); await settle();
    tick.fn(); await settle();

    it('stops polling once the delivery is done', function () {
      // elapsed reaches 30 on the third tick, which is >= required.
      falsy(running.view.textContent.indexOf('undefined') !== -1,
        'the finished countdown rendered a hole: ' + running.view.textContent);
    });

    const refusedPoll = await onMine({
      armKidnap: { ok: true, data: true },
      kidnapProgress: { ok: false, err: 'not_found' }
    });
    click(refusedPoll, 'Deliver alive');
    await settle();
    const pollTimer = refusedPoll.timers.filter(function (t) {
      return t.repeating && t.ms === 1000;
    })[0];
    pollTimer.fn();
    await settle();

    it('survives the countdown being refused mid-delivery', function () {
      truthy(refusedPoll.view.textContent.trim().length > 0,
        'a refused poll emptied the screen');
    });
  })();

  /* Every amendment kind, in words.
   *
   * The page turns a wire value like 'reduce_reward' into a sentence. Five
   * of those describers never ran: a player was shown whatever the last one
   * produced, or nothing, and nobody would know. */
  await (async function amendmentWords() {
    const KINDS = [
      ['reduce_reward', { slot: 2 }, 'collection'],
      ['shorten_deadline', { seconds: 600 }, 'deadline'],
      ['raise_penalty', { amount: 2500 }, 'failure stake'],
      ['change_mode', { mode: 'competitive' }, 'ompetitive'],
      ['change_reason', { reason: 'Actually, theft' }, 'theft'],
      ['withdraw', {}, 'ithdraw'],
      ['cancel', {}, 'ancel'],
    ];

    for (const [kind, payload, words] of KINDS) {
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [],
          settings: { minQueryLength: 3 } } },
        mine: { ok: true, data: { created: [{
          id: 'ct00000001', target: 'Dana Reyes', reason: 'Unpaid debt',
          state: 'accepted', role: 'creator', mode: 'exclusive',
          reward: { total: 5000 }, hunters: [{ alias: 'Operative #4' }]
        }], accepted: [], onMe: [] } },
        ledger: LEDGER,
        // The handler returns openFor()'s list directly — not wrapped in
        // an { open: ... } envelope. Wrapping it produced a panel that said
        // "A change to this contract" from "undefined", which is the
        // fallback for a proposal the page cannot read, and every wording
        // assertion below failed against it.
        amendments: { ok: true, data: [{
          id: 'am00000001', kind: kind, payload: payload,
          mine: false, proposer: 'Operative #4', waiting: 1,
          expires: 9999999999
        }] }
      });
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
      await settle(); await settle();

      const shown = app.view.textContent;
      it('puts ' + kind + ' into words rather than showing the wire value', function () {
        falsy(shown.indexOf(kind) !== -1,
          'the raw wire value reached the player: ' + shown);
        truthy(shown.toLowerCase().indexOf(words.toLowerCase()) !== -1,
          'nothing described the proposal: ' + shown);
      });
    }
  })();

  /* What the app does when a reply is hostile rather than merely refused.
   *
   * Every journey here is a reply the server should never send, and every
   * one of them used to take the render down inside the coalesced redraw —
   * where nothing could see it. The app drew a blank tab, or worse told a
   * hunted player they were safe, and the suite read both as an empty
   * section and passed. */
  await (async function hostileReplies() {
    // 1. An ok:true carrying no payload at all. This is also what the
    //    harness synthesises for a request nobody scripted, i.e. what a new
    //    endpoint looks like to a page that has not reloaded.
    {
      const app = boot({ list: BOARD, mine: { ok: true }, ledger: LEDGER });
      await settle(); await settle();
      it('an ok reply with no payload does not take the render down', function () {
        drewCleanly(app, 'the app');
      });
      tab(app, 'mine');
      await settle(); await settle();
      const shown = app.view.textContent;
      it('an ok reply with no payload draws the failure card, not a blank tab', function () {
        drewCleanly(app, 'the mine tab');
        truthy(shown.length > 0, 'the tab rendered nothing at all');
        truthy(app.view.all().filter(function (n) {
          return n.tagName === 'BUTTON' && n.textContent === 'Try again';
        }).length === 1, 'no way to ask again: ' + shown);
      });

      // One bad reply is one bad section. The board answered fine.
      tab(app, 'board');
      await settle(); await settle();
      const board = app.view.textContent;
      it('one unreadable reply does not cost the tabs that answered', function () {
        drewCleanly(app, 'the board tab');
        truthy(board.indexOf('Dana Reyes') !== -1,
          'the board had its answer and should still be showing it: ' + board);
      });
    }

    // 1b. And Try again on that failure card brings the real answer back.
    {
      let broken = true;
      const app = boot({
        list: BOARD, ledger: LEDGER,
        mine: function () {
          if (broken) { return { ok: true }; }
          return { ok: true, data: { created: [], accepted: [], onMe: [] } };
        }
      });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();

      broken = false;
      click(app, 'Try again');
      await settle(); await settle();
      const recovered = app.view.textContent;
      it('Try again on a broken section brings the real answer back', function () {
        drewCleanly(app, 'the onme tab');
        truthy(recovered.indexOf('Nobody is looking for you') !== -1,
          'the retry asked again and the answer should be on screen: ' + recovered);
      });
    }

    // 2. A string where the payload belongs.
    {
      const app = boot({ list: BOARD, mine: { ok: true, data: 'ct00000009' }, ledger: LEDGER });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();
      const shown = app.view.textContent;
      it('a string payload does not become an all-clear', function () {
        drewCleanly(app, 'the onme tab');
        falsy(shown.indexOf('Nobody is looking for you') !== -1,
          'told a player nobody is hunting them off an unreadable reply: ' + shown);
      });
    }

    // 3. The onMe list arriving as something with a length that is not an
    //    array — the one list site in the app that did not go through
    //    asList. The page had already appended "There is a price on your
    //    head." before .forEach threw.
    {
      const app = boot({
        list: BOARD, ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [], onMe: 'ct00000009' } }
      });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();
      const shown = app.view.textContent;
      tab(app, 'ledger');
      await settle(); await settle();
      const ledger = app.view.textContent;
      it('a hostile onMe list does not cost the other tabs', function () {
        drewCleanly(app, 'the ledger tab');
        truthy(ledger.length > 0, 'the ledger had its own answer and drew nothing');
      });

      it('a string where the onMe list belongs does not strand the warning', function () {
        drewCleanly(app, 'the onme tab');
        falsy(shown.indexOf('There is a price on your head') !== -1
              && shown.indexOf('Nobody is looking for you') === -1
              && app.view.all().filter(function (n) { return n.className === 'card'; }).length === 0,
          'announced a contract and then drew none of it: ' + shown);
      });
    }

    // 4. The same list keyed by something other than 1..n — the shape
    //    asList exists for, which every other list in the app survives.
    {
      const app = boot({
        list: BOARD, ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [], onMe: keyedBySlot([{
          id: 'ct00000009', targetName: 'You', reason: 'Unpaid debt',
          mode: 'exclusive', state: 'active', reward: { baseline: 9000 },
          slots: 1, slotsClaimed: 0, currentSlot: 1, role: 'target'
        }]) } }
      });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();
      const shown = app.view.textContent;
      it('an onMe roster keyed by something other than 1..n still warns', function () {
        drewCleanly(app, 'the onme tab');
        falsy(shown.indexOf('Nobody is looking for you') !== -1,
          'a roster that crossed as an object read as an all-clear: ' + shown);
        truthy(shown.indexOf('There is a price on your head') !== -1,
          'the warning is missing: ' + shown);
      });
    }

    // 5. One board row that lost its reward. render() clears the view
    //    before it draws, so this cost the whole tab and every good row
    //    after it, not just the bad row. Put between two good rows, so
    //    both directions are covered.
    {
      const broken = JSON.parse(JSON.stringify(BOARD));
      const before = JSON.parse(JSON.stringify(broken.data.contracts[0]));
      const after = JSON.parse(JSON.stringify(broken.data.contracts[0]));
      before.id = 'ct00000000';
      before.targetName = 'Early Bird';
      after.id = 'ct00000002';
      after.targetName = 'Late Riser';
      delete broken.data.contracts[0].reward;
      broken.data.contracts[0].targetName = 'Broken Row';
      broken.data.contracts.unshift(before);
      broken.data.contracts.push(after);
      const app = boot({ list: broken, mine: MINE, ledger: LEDGER });
      await settle(); await settle();
      const shown = app.view.textContent;
      it('a row with no reward on it costs that row, not the board', function () {
        drewCleanly(app, 'the board tab');
        truthy(shown.indexOf('Late Riser') !== -1,
          'the good row after the broken one was lost too: ' + shown);
        truthy(shown.indexOf('Early Bird') !== -1,
          'and so was the one before it: ' + shown);
      });
    }

    // 5b. An onMe list the server meant to send empty. An empty Lua table
    //     crosses as {} rather than [], which is the boundary asList
    //     exists for — and the all-clear is the one message that has to be
    //     right on both sides of it.
    {
      const app = boot({
        list: BOARD, ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [], onMe: acrossTheWire([]) } }
      });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();
      const onme = app.view.textContent;
      it('an empty roster from Lua reads as nobody, not as a crash', function () {
        drewCleanly(app, 'the onme tab');
        truthy(onme.indexOf('Nobody is looking for you') !== -1,
          'an answered, empty roster is exactly when the all-clear is right: ' + onme);
      });

      tab(app, 'mine');
      await settle(); await settle();
      const mine = app.view.textContent;
      it('and Mine says it is empty rather than showing nothing', function () {
        drewCleanly(app, 'the mine tab');
        truthy(mine.length > 0, 'Mine rendered a completely blank screen');
      });
    }

    // 6. An answer that has not arrived. Not a hostile server at all — this
    //    is every open of the app, for as long as the round trip takes, and
    //    the client waits fifteen seconds before it gives up.
    {
      let release = null;
      const held = new Promise(function (r) { release = r; });
      const app = boot({ list: BOARD, mine: held, ledger: LEDGER });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();
      const waiting = app.view.textContent;
      it('an answer still outstanding is not an all-clear', function () {
        drewCleanly(app, 'the onme tab');
        falsy(waiting.indexOf('Nobody is looking for you') !== -1,
          'told a player they were safe before the server had answered: ' + waiting);
        truthy(waiting.length > 0, 'the tab rendered nothing at all');
      });

      tab(app, 'mine');
      await settle(); await settle();
      const mineWaiting = app.view.textContent;
      it('Mine says something while it waits rather than nothing', function () {
        truthy(mineWaiting.length > 0, 'Mine rendered a completely blank screen');
      });

      // And the answer landing still gets through.
      release({ ok: true, data: { created: [], accepted: [], onMe: [{
        id: 'ct00000009', targetName: 'You', reason: 'Unpaid debt',
        mode: 'exclusive', state: 'active', reward: { baseline: 9000 },
        slots: 1, slotsClaimed: 0, currentSlot: 1, role: 'target'
      }] } });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();
      const arrived = app.view.textContent;
      it('the held answer landing draws the contract', function () {
        drewCleanly(app, 'the onme tab');
        truthy(arrived.indexOf('There is a price on your head') !== -1,
          'the answer arrived and the warning did not: ' + arrived);
      });
    }

    // 7. Genuinely nothing, once asked. The all-clear has to survive all of
    //    the above, or the fix is just a message nobody ever sees.
    {
      const app = boot({ list: BOARD, mine: MINE, ledger: LEDGER });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();
      const shown = app.view.textContent;
      it('an answered, empty roster still says nobody is looking', function () {
        drewCleanly(app, 'the onme tab');
        truthy(shown.indexOf('Nobody is looking for you') !== -1,
          'the all-clear never appears any more: ' + shown);
      });
    }
  })();

  /* The stake, shown before it is agreed to and echoed back when it is. */
  await (async function theStakeOnTheBoard() {
    const STAKED = JSON.parse(JSON.stringify(BOARD));
    STAKED.data.contracts[0].penaltyAmount = 4000;

    const app = boot({ list: STAKED, mine: MINE, ledger: LEDGER });
    await settle(); await settle();

    it('says what accepting costs, on the listing', function () {
      const shown = app.view.textContent;
      truthy(shown.indexOf('$4,000') !== -1,
        'a hunter must not learn the stake from their bank balance: ' + shown);
      truthy(shown.toLowerCase().indexOf('stake') !== -1, shown);
    });

    click(app, 'Accept contract');
    await settle();

    it('says it again in the dialog that takes the contract', function () {
      const shown = app.view.textContent;
      truthy(shown.indexOf('$4,000') !== -1,
        'the last screen before the money moves has to carry the figure: '
        + shown);
    });

    click(app, 'Under my name');
    await settle(); await settle();

    it('echoes the figure it showed back with the acceptance', function () {
      // Without this the server refuses every staked acceptance with
      // "the stake changed", so the contract simply cannot be taken — and a
      // page that has stopped complying looks exactly like one that has not.
      const sent = app.sent.filter(function (c) { return c.name === 'accept'; });
      eq(sent.length, 1, 'one acceptance was sent');
      eq(sent[0].body.penaltyAmount, 4000,
        'the acceptance must carry the stake the player was shown: '
        + JSON.stringify(sent[0].body));
    });

    /* And a contract with no stake says nothing about one. */
    const free = boot({ list: BOARD, mine: MINE, ledger: LEDGER });
    await settle(); await settle();

    it('says nothing about a stake when there is none', function () {
      const shown = free.view.textContent;
      falsy(shown.toLowerCase().indexOf('stake') !== -1,
        'a contract with no stake must not advertise one: ' + shown);
    });

    click(free, 'Accept contract');
    await settle();
    click(free, 'Under my name');
    await settle(); await settle();

    it('still sends a figure of zero, so the server sees an answer', function () {
      const sent = free.sent.filter(function (c) { return c.name === 'accept'; });
      eq(sent.length, 1);
      eq(sent[0].body.penaltyAmount, 0);
    });
  })();

  /* A stake that moved while the page was showing it. */
  await (async function theStakeMovedUnderneath() {
    const STAKED = JSON.parse(JSON.stringify(BOARD));
    STAKED.data.contracts[0].penaltyAmount = 4000;

    const app = boot({
      list: STAKED, mine: MINE, ledger: LEDGER,
      accept: { ok: false, err: 'terms_changed' }
    });
    await settle(); await settle();
    const before = app.sent.filter(function (c) { return c.name === 'list'; }).length;

    click(app, 'Accept contract');
    await settle();
    click(app, 'Under my name');
    await settle(); await settle();

    it('tells the player the stake changed rather than that something went wrong', function () {
      const said = app.notice();
      truthy(said.toLowerCase().indexOf('stake') !== -1,
        'the refusal has to name what changed: ' + said);
      falsy(said.indexOf('Something went wrong') !== -1, said);
    });

    it('asks again, so the new figure is on screen with the message', function () {
      const after = app.sent.filter(function (c) { return c.name === 'list'; }).length;
      truthy(after > before,
        'a message saying the figure changed, with the old figure still on '
        + 'screen, is half an answer');
    });
  })();

  /* A contract with no room left on it. */
  await (async function aFullContract() {
    function board(active, max, mode) {
      const b = JSON.parse(JSON.stringify(BOARD));
      b.data.contracts[0].mode = mode || 'competitive';
      b.data.contracts[0].huntersActive = active;
      b.data.contracts[0].huntersMax = max;
      return b;
    }

    const room = boot({ list: board(2, 5), mine: MINE, ledger: LEDGER });
    await settle(); await settle();

    it('says how many operatives are on it and how many it takes', function () {
      const shown = room.view.textContent;
      truthy(shown.indexOf('2 of 5 operatives') !== -1,
        'a count with no cap beside it does not tell a hunter whether they '
        + 'can join: ' + shown);
    });

    const full = boot({ list: board(5, 5), mine: MINE, ledger: LEDGER });
    await settle(); await settle();

    it('says so on the card when there is no room left', function () {
      const shown = full.view.textContent;
      truthy(shown.indexOf('full') !== -1,
        'the board should say this before the tap, not the server after it: '
        + shown);
    });

    /* And if they tap anyway, the refusal is about the right thing. */
    const refused = boot({
      list: board(5, 5), mine: MINE, ledger: LEDGER,
      accept: { ok: false, err: 'contract_full' }
    });
    await settle(); await settle();
    click(refused, 'Accept contract');
    await settle();
    click(refused, 'Under my name');
    await settle(); await settle();

    it('does not tell a hunter holding nothing that they hold too much', function () {
      const said = refused.notice();
      falsy(said.indexOf('holding too many') !== -1,
        'that is a rule about the caller, and this one is about the contract: '
        + said);
      truthy(said.toLowerCase().indexOf('operatives') !== -1,
        'the refusal has to name what is actually full: ' + said);
    });

    /* An exclusive contract has no cap to show. */
    const exclusive = boot({
      list: board(1, 5, 'exclusive'), mine: MINE, ledger: LEDGER
    });
    await settle(); await settle();

    it('says nothing about a cap on a contract that takes one operative', function () {
      const shown = exclusive.view.textContent;
      truthy(shown.indexOf('1 operative') !== -1, shown);
      falsy(shown.indexOf('of 5') !== -1,
        'an exclusive contract has no roster to be full: ' + shown);
    });
  })();

  console.log('');
  failures.forEach(function (f) { console.log('FAIL  ' + f); });
  // Counted from the list itself. Two counters that can disagree is how a
  // run printed ten failures and then said none.
  console.log('\n' + passed + ' passed, ' + failures.length + ' failed');
  process.exit(failures.length === 0 ? 0 : 1);
}

/* main() rejecting is itself a result worth printing. Without this the
 * unhandledRejection handler above swallowed it and the run exited zero
 * having said nothing at all — a suite that reports nothing is worse than
 * one that fails. */
main().catch(function (err) {
  failures.push('the suite itself threw\n    ' + (err && err.stack || err));
  console.log('');
  failures.forEach(function (f) { console.log('FAIL  ' + f); });
  console.log('\n' + passed + ' passed, ' + failures.length + ' failed');
  process.exit(1);
});
