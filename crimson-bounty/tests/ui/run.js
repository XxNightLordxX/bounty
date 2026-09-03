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
      // A render that re-requests what it is waiting for loops forever, and
      // a suite that loops forever tells you nothing. One of these bugs has
      // already shipped in this app; this turns the next one into a failure
      // with a name on it.
      if (sent.length > 500) {
        throw new Error('runaway request loop: ' + sent.length + ' calls, last was ' + name);
      }
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

    it('asks once and does not retry a reference that failed', async function () {
      const before = asked;
      app.sandbox.window._message({ data: { type: 'result', event: 'list' } });
      await settle(); await settle();
      eq(asked, before, 'a dead reference must not be re-requested every render');
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
  })();

  console.log('');
  failures.forEach(function (f) { console.log('FAIL  ' + f); });
  console.log('\n' + passed + ' passed, ' + failed + ' failed');
  process.exit(failed === 0 ? 0 : 1);
}

main();
