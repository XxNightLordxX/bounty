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
      const answer = responses[name];
      const result = typeof answer === 'function' ? answer(body) : answer;
      return Promise.resolve({ json: function () { return Promise.resolve(result || { ok: true }); } });
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

  return {
    document, view, sent, timers, sandbox, notices,
    // What the player is currently being told. The notice lives outside
    // #view precisely so it does not rebuild the form, so it has to be read
    // from its own node rather than from the view.
    notice: function () { return document.getElementById('notice').textContent; }
  };
}

/** Let queued promise callbacks run. */
function settle() {
  return new Promise(function (resolve) { setImmediate(resolve); });
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

    it('debounces the search instead of firing per keystroke', function () {
      const searches = app.sent.filter(function (s) { return s.name === 'searchTargets'; });
      eq(searches.length, 1, 'one lookup for one debounced query');
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
    caps: { maxStacks: 3, maxPerStack: 100, maxWeapons: 2, slots: 5 }
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

  function pick(app, id, value) {
    const node = app.document.getElementById(id);
    truthy(node, 'missing control: ' + id);
    if (value !== undefined) { node.value = String(value); }
    return node;
  }

  function press(app, id) {
    const node = app.document.getElementById(id);
    truthy(node, 'missing button: ' + id);
    node.onclick();
  }

  await (async function stakesGoods() {
    const app = placeForm();
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('offers as many payouts as the server allows', function () {
      eq(app.document.getElementById('slots-count').max, GOODS.caps.slots,
        'the ceiling comes from the config, not from the form');
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
    pick(app, 'reason').value = 'Unpaid debt';
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
      eq(app.sandbox.window.__state, undefined, 'no state is leaked to the page');
      // Going back to the form must not offer goods the contract took.
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
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
    pick(app, 'reason').value = 'Debt';
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

    it('takes its payout ceiling from the server', function () {
      // caps.slots is absent here, so the form falls back rather than
      // offering an unbounded field.
      eq(app.document.getElementById('slots-count').max, 5);
    });

    it('shows no picker at all when there is nothing to stake', function () {
      falsy(app.document.getElementById('slot-item-add-1'), 'no item picker');
      falsy(app.document.getElementById('slot-weapon-add-1'), 'no weapon picker');
      truthy(app.document.getElementById('slot-cash-1'), 'money is still offerable');
    });
  })();

  console.log('');
  failures.forEach(function (f) { console.log('FAIL  ' + f); });
  console.log('\n' + passed + ' passed, ' + failed + ' failed');
  process.exit(failed === 0 ? 0 : 1);
}

main();
