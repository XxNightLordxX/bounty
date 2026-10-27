/* Drives the real ui/app.js against a scripted server, and asserts on what
 * the app actually sends and renders.
 *
 * Everything here exercises the shipped file: app.js is read from disk and
 * executed, not reimplemented. */

'use strict';

const fs = require('fs');
const path = require('path');
const { makeDocument } = require('./dom.js');

const APP = path.join(__dirname, '..', '..', 'crimson-hitman', 'ui', 'app.js');

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
function boot(responses, windowExtras) {
  const document = makeDocument();
  const sent = [];
  const urls = [];
  const timers = [];
  let timerSeq = 0;
  function clearTimer(id) {
    timers.forEach(function (t) { if (t.id === id) { t.cleared = true; } });
  }
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
      // Where FiveM serves a resource's page from, for a server that
      // renamed the folder.
      location: { hostname: 'cfx-nui-renamed-by-the-operator' },
      // Every listener, not the last one registered.
      //
      // This used to keep one function per type, so a second
      // addEventListener('message') silently replaced the first and the
      // suite went on testing the one that no longer ran. A real browser
      // calls both. The shim now fans out, and window._message stays
      // callable as a single function so the existing call sites read the
      // same.
      addEventListener: function (type, fn) {
        var key = '_' + type;
        var existing = sandbox.window[key];
        if (!existing) { sandbox.window[key] = fn; return; }
        var all = existing.__all || [existing];
        all.push(fn);
        var fanout = function (event) {
          for (var i = 0; i < all.length; i++) { all[i](event); }
        };
        fanout.__all = all;
        sandbox.window[key] = fanout;
      }
    },
    fetch: function (url, options) {
      urls.push(url);
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
    /* No GetParentResourceName, as in the real frame.
     *
     * This shim used to provide one, and the page used it, and the suite
     * agreed with itself: FiveM defines it only in frames directly under
     * its NUI root, and lb-phone shows a custom app in an iframe inside its
     * own frame, so the real page never had it and posted to the literal
     * 'crimson-hitman' on every server. What the real frame does have is
     * its own address, https://cfx-nui-<resource>/ (window.location below),
     * named here as something other than the shipped name, so a page that
     * ignores it and uses the literal is a page that fails. */
    // Ids are a counter, not a position: settle() splices fired timeouts out
    // of the list, so a position would name a different timer afterwards.
    setTimeout: function (fn, ms) { timers.push({ fn: fn, ms: ms, id: ++timerSeq }); return timerSeq; },
    setInterval: function (fn, ms) {
      timers.push({ fn: fn, ms: ms, repeating: true, id: ++timerSeq });
      return timerSeq;
    },
    // Recorded, so a test can tell a timer the page stopped from one it
    // forgot. As a no-op, "stopped polling" was not something any test could
    // observe.
    clearInterval: function (id) { clearTimer(id); },
    clearTimeout: function (id) { clearTimer(id); },
    Promise: Promise, JSON: JSON, Math: Math, Number: Number, String: String,
    Array: Array, Object: Object, console: console
  };
  sandbox.window.document = document;
  // What lb-phone itself puts on the page's window before it runs
  // (getSettings, onSettingsChange), for a test that needs it there first.
  Object.assign(sandbox.window, windowExtras || {});

  const source = fs.readFileSync(APP, 'utf8');
  const vm = require('vm');
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, { filename: 'app.js' });

  const booted_app = {
    document, view, sent, urls, timers, sandbox, notices,
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

/** Let every queued headshot batch go, a second at a time.
 *
 * The page asks for faces five at a time, a second apart (FACE_BATCH_MS),
 * and settle() fires only zero-delay timers. A test about what a whole
 * page of faces does lets the batches run here. */
async function drainFaces(app) {
  for (let pass = 0; pass < 50; pass++) {
    const due = app.timers.filter(function (t) {
      return !t.repeating && !t.cleared && t.ms === 1000;
    });
    if (due.length === 0) { return; }
    due.forEach(function (t) { app.timers.splice(app.timers.indexOf(t), 1); });
    due.forEach(function (t) {
      try { t.fn(); } catch (err) { app.thrown.push(err); }
    });
    await settle(); await settle();
  }
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
    settings: { warnCreator: true, warnHitman: true, flagListing: true, minQueryLength: 4 },
    contracts: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'active',
      reward: { baseline: 5000, bonus: 2500 },
      slots: 2, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 1, hitmenMax: 5,
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
      // Less which screen is theirs, which their own game answers
      // (crimson:accessMode) and the server is never asked.
      const names = app.sent.map(function (s) { return s.name; })
        .filter(function (n) { return n !== 'accessMode'; }).sort();
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
      // A server that lets a contract be collected up to three times
      // (Config.Limits.MaxPayoutSlots), so the count is offered.
      rewardOptions: { ok: true, data: { cash: 100000, bank: 50000, dirty: 0, caps: { slots: 3 } } },
      searchTargets: { ok: true, data: [{ handle: 'tg00000001', name: 'Dana Reyes', protected: false }] },
      create: function (body) { submission = body; return { ok: true, data: {} }; }
    });
    await settle(); await settle();

    // Switch to the Place tab, as a player would.
    const tabs = app.document.querySelectorAll('.tab');
    const place = tabs.filter(function (t) { return t.dataset.tab === 'place'; })[0];
    place.onclick();
    await settle(); await settle();

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

  await (async function hitmanCard() {
    const accepted = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    accepted.role = 'hitman';
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

    it('renders a hitman card with a live countdown without throwing', function () {
      truthy(app.view.textContent.indexOf('Dana Reyes') !== -1,
        'the card should render: ' + app.view.textContent);
    });
  })();

  await (async function targetBuyout() {
    const onMe = {
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'exclusive', state: 'active',
      reward: { baseline: 5000, bonus: 0 },
      slots: 1, slotsClaimed: 0, currentSlot: 1, hitmenActive: 1, hitmenMax: 5,
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
    click(app, 'Pay $15,000');
    await settle();
    it('sends the buyout for the right contract', function () {
      truthy(boughtOut, 'nothing was sent');
      eq(boughtOut.id, 'ct00000001');
    });

    it('never shows the target who placed it or who is after them', function () {
      const text = app.view.textContent;
      falsy(text.indexOf('Marlowe') !== -1, 'the creator must not be named');
      falsy(text.indexOf('Operative') !== -1, 'the hitmen must not be listed');
    });
  })();

  /* The board a page at a time: past the first, nothing was reachable. */
  await (async function boardPages() {
    const asked = [];
    const app = boot({
      list: function (body) {
        asked.push(body.page);
        const b = JSON.parse(JSON.stringify(BOARD));
        b.data.page = body.page; b.data.pages = 2;
        return b;
      },
      mine: MINE, ledger: LEDGER
    });
    await settle(); await settle();
    it('offers the next page of the board', function () {
      truthy(app.view.textContent.indexOf('Page 1 of 2') !== -1, app.view.textContent);
    });
    click(app, 'More');
    await settle(); await settle();
    it('asks for it', function () {
      eq(asked[asked.length - 1], 2, 'asked for ' + asked.join(','));
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
          role: 'creator', fulfilment: 'elimination', resolved_at: 1700000000,
          photo: { handle: 'ph00000000aa', state: 'pending' }
        }, {
          // A hitman's own row. The server sends no photo on it; one that
          // somehow arrived must still not be offered.
          contract_id: 'ct00000002', target_name: 'Pia Nolan', reason: 'Owed',
          role: 'hitman', fulfilment: 'elimination', resolved_at: 1700000000,
          photo: { handle: 'ph00000000bb', state: 'pending' }
        }]
      } }
    });
    await settle(); await settle();

    const tabs = app.document.querySelectorAll('.tab');
    tabs.filter(function (t) { return t.dataset.tab === 'ledger'; })[0].onclick();

    it('says when each entry closed', function () {
      truthy(/ago/.test(app.view.textContent),
        'two entries on the same target read exactly alike: ' + app.view.textContent);
    });

    it('shows the standing and the counters', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('Known') !== -1, 'standing: ' + text);
      truthy(text.indexOf('7 completed') !== -1, 'counters: ' + text);
    });

    it('offers the client their photo to open, and draws none in the list', function () {
      const images = app.view.all().filter(function (n) { return n.tagName === 'IMG'; });
      eq(images.length, 0, 'the photo of a body is not on screen until it is asked for');
      const buttons = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'View photo';
      });
      eq(buttons.length, 1, 'one button, on the client row and not on the hitman row');
      truthy(app.view.textContent.indexOf('once') !== -1,
        'and it says it can be seen once: ' + app.view.textContent);
    });

    it('never asks for the photo just because the ledger was read', function () {
      falsy(app.sent.some(function (r) { return r.name === 'openPhoto'; }),
        'the ledger is read on every refresh; a view spent that way was never seen');
    });
  })();

  /* The one look at a kill photo: opened on purpose, saved or deleted, and
     deleted however else it is closed. */

  // A photo the server keeps, as it reaches the page, and the link a
  // server that serves its own photos hands over for one.
  const KEPT = 'data:image/webp;base64,UklGRgAAAABXRUJQ';
  const SERVED = 'https://chatty.server.qbox.re/crimson-hitman/p/Zk3_q-9xWb2LmT0cRf8aNd.webp';

  function photoLedger(state) {
    return { ok: true, data: {
      record: { completed: 0, placed: 1, survived: 0, standing: 'Unproven' },
      entries: [{
        contract_id: 'ct00000001', target_name: 'Dana Reyes', reason: 'Unpaid debt',
        role: 'creator', fulfilment: 'elimination', resolved_at: 1700000000,
        photo: { handle: 'ph00000000aa', state: state || 'pending' }
      }]
    } };
  }

  /* Booted with the photo opened from the Ledger. `phone` is what lb-phone
     gives the page (window.components), in place before the photo opens,
     as it is on a real phone: the dialog offers what the phone can do. */
  async function openedPhoto(extra, phone) {
    // The server's side of it, so a refresh reads back what the page did.
    let photoState = 'pending';
    const answers = Object.assign({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: MINE,
      ledger: function () { return photoLedger(photoState); },
      openPhoto: function () {
        photoState = 'open';
        return { ok: true, data: { handle: 'ph00000000aa',
          url: 'https://cdn.fivemanage.com/proof.png' } };
      },
      photoDecision: function (body) {
        // The link a server that serves its own photos hands over, with
        // the photo still open until the phone has it.
        if (body.choice === 'link') {
          return { ok: true, data: { handle: body.handle, state: 'open', link: SERVED } };
        }
        photoState = body.choice === 'save' ? 'saved'
          : body.choice === 'keep' ? 'kept' : 'deleted';
        return { ok: true, data: { handle: body.handle, state: photoState } };
      }
    }, extra || {});
    const app = boot(answers);
    if (phone) { phone(app.sandbox.window); }
    await settle(); await settle();
    tab(app, 'ledger');
    click(app, 'View photo');
    await settle(); await settle();
    return app;
  }

  function decisions(app) {
    return app.sent.filter(function (r) { return r.name === 'photoDecision'; })
      .map(function (r) { return r.body.choice; });
  }

  await (async function photoOpensOnce() {
    const app = await openedPhoto();

    it('opens the photo by its handle when asked', function () {
      const asked = app.sent.filter(function (r) { return r.name === 'openPhoto'; });
      eq(asked.length, 1);
      eq(asked[0].body.handle, 'ph00000000aa');
    });

    it('shows it whole, with the two choices and what they mean', function () {
      drewCleanly(app, 'the photo');
      const images = app.view.all().filter(function (n) { return n.tagName === 'IMG'; });
      eq(images.length, 1, 'the photo is on screen');
      eq(images[0].src, 'https://cdn.fivemanage.com/proof.png');
      const text = app.view.textContent;
      truthy(text.indexOf('You can see this once') !== -1, text);
      truthy(text.indexOf('Save to Photos') !== -1 && text.indexOf('Delete') !== -1, text);
    });

    // Another tab, the way a player leaves a screen — or a thumb that
    // missed Save to Photos, thirty pixels above the tab bar.
    const boardsAsked = app.sent.filter(function (r) { return r.name === 'list'; }).length;
    tab(app, 'board');
    await settle(); await settle();

    it('keeps the photo up until it is saved or deleted, rather than deleting it on a tab tap', function () {
      drewCleanly(app, 'a tab tapped over the photo');
      eq(decisions(app).length, 0, 'a tab tap is not a Delete: ' + decisions(app).join(','));
      const images = app.view.all().filter(function (n) { return n.tagName === 'IMG'; });
      eq(images.length, 1, 'the photo is still on screen');
      truthy(app.notice().indexOf('Save or delete the photo first') !== -1, app.notice());
      truthy(labels(app).indexOf('Save to Photos') !== -1 && labels(app).indexOf('Delete') !== -1,
        labels(app).join(','));
      eq(app.sent.filter(function (r) { return r.name === 'list'; }).length, boardsAsked,
        'and the board was not opened behind it');
    });

    click(app, 'Delete');
    await settle(); await settle();
    tab(app, 'ledger');
    await settle();
    it('says on the row that it was deleted', function () {
      truthy(app.view.textContent.indexOf('Photo deleted') !== -1, app.view.textContent);
      falsy(app.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'View photo';
      }), 'nothing left to open');
      eq(decisions(app).length, 1, 'told once, not on every redraw');
    });
  })();

  await (async function photoDeleted() {
    const app = await openedPhoto();
    click(app, 'Delete');
    await settle(); await settle();
    it('deletes it when asked to', function () {
      eq(decisions(app).join(','), 'delete');
      truthy(app.view.textContent.indexOf('Photo deleted') !== -1, app.view.textContent);
    });
  })();

  await (async function photoSavedThroughThePhone() {
    const app = await openedPhoto();
    const gallery = [];
    app.sandbox.window.components = {
      saveToGallery: function (url) { gallery.push(url); return Promise.resolve(42); }
    };
    click(app, 'Save to Photos');
    await settle(); await settle(); await settle();

    it('saves it into the phone with lb-phone and then tells the server', function () {
      eq(gallery.join(','), 'https://cdn.fivemanage.com/proof.png');
      eq(decisions(app).join(','), 'save');
      falsy(app.sent.some(function (r) { return r.name === 'saveToPhotos'; }),
        'no fallback needed where the phone gives the app its own save');
    });

    it('says it was saved', function () {
      truthy(app.view.textContent.indexOf('Photo saved to your phone') !== -1,
        app.view.textContent);
    });
  })();

  await (async function photoSavedThroughTheClient() {
    let fallback = null;
    const app = await openedPhoto({
      saveToPhotos: function (body) { fallback = body; return { ok: true }; }
    });
    click(app, 'Save to Photos');
    await settle(); await settle(); await settle();

    it('falls back to the client where the phone gives the app no save', function () {
      truthy(fallback, 'the client was not asked');
      eq(fallback.handle, 'ph00000000aa');
      falsy('url' in fallback, 'the page names the photo; the client knows its link');
      eq(decisions(app).join(','), 'save');
    });
  })();

  await (async function photoSaveFails() {
    const app = await openedPhoto({
      saveToPhotos: { ok: false, err: 'save_unavailable' }
    });
    click(app, 'Save to Photos');
    await settle(); await settle(); await settle();

    it('keeps the photo open when it could not be saved, and tells nobody it was', function () {
      eq(decisions(app).length, 0, 'not saved, so not reported saved, and not deleted either');
      const images = app.view.all().filter(function (n) { return n.tagName === 'IMG'; });
      eq(images.length, 1, 'still there to keep or delete');
      truthy(app.notice().indexOf('could not save') !== -1, app.notice());
    });

    it('offers to keep it in the app instead, rather than losing it', function () {
      const labels = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Keep it in the app instead') !== -1, labels.join(','));
      truthy(labels.indexOf('Delete') !== -1, labels.join(','));
      eq(labels.indexOf('Save to Photos'), -1, 'the phone has already said no');
    });

    click(app, 'Keep it in the app instead');
    await settle(); await settle();
    it('keeps it when asked, and the row offers it again', function () {
      eq(decisions(app).join(','), 'keep');
      truthy(app.view.textContent.indexOf('Kept for you in this app') !== -1, app.view.textContent);
      truthy(app.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'View photo';
      }), 'a kept photo opens again');
    });
  })();

  /* Payments of theirs waiting for room. A receipt missed, or a page
     closed, was the only word of them anywhere (W086). */
  await (async function paymentsWaitingForRoom() {
    const waiting = JSON.parse(JSON.stringify(LEDGER));
    waiting.data.waiting = 2;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: MINE,
      ledger: waiting
    });
    await settle(); await settle();
    tab(app, 'ledger');
    await settle();
    it('lists the payments waiting for the player to make room', function () {
      truthy(app.view.textContent.indexOf('2 payments waiting for room') !== -1,
        app.view.textContent);
    });

    const none = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: MINE,
      ledger: LEDGER
    });
    await settle(); await settle();
    tab(none, 'ledger');
    await settle();
    it('says nothing of waiting payments when none wait', function () {
      falsy(none.view.textContent.indexOf('waiting for room') !== -1, none.view.textContent);
    });
  })();

  await (async function photoAlreadyGone() {
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: MINE,
      ledger: photoLedger(),
      openPhoto: { ok: false, err: 'photo_gone' }
    });
    await settle(); await settle();
    tab(app, 'ledger');
    click(app, 'View photo');
    await settle(); await settle();

    it('says a photo is gone rather than opening an empty dialog', function () {
      drewCleanly(app, 'a refused photo');
      truthy(app.notice().indexOf('That photo is gone') !== -1, app.notice());
      eq(app.view.all().filter(function (n) { return n.tagName === 'IMG'; }).length, 0);
      eq(decisions(app).length, 0);
    });
  })();

  await (async function photoRowsAfterwards() {
    const words = { saved: 'Photo saved to your phone', deleted: 'Photo deleted',
                    open: 'Photo opened and not saved' };
    for (const photoState of Object.keys(words)) {
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
        mine: MINE,
        ledger: photoLedger(photoState)
      });
      await settle(); await settle();
      tab(app, 'ledger');
      it('says what became of a ' + photoState + ' photo, with nothing to open', function () {
        truthy(app.view.textContent.indexOf(words[photoState]) !== -1, app.view.textContent);
        falsy(app.view.all().some(function (n) {
          return n.tagName === 'BUTTON' && n.textContent === 'View photo';
        }));
      });
    }
  })();

  /* A photo kept on the server reaches the page as the photo itself, a
     data URI, which the client held the request for. lb-phone's Photos
     keeps links, so the page gets one of three ways: from the server,
     which serves the photo itself; from lb-phone's own upload; or not at
     all, and the photo is kept in the app instead. */
  function images(app) {
    return app.view.all().filter(function (n) { return n.tagName === 'IMG'; });
  }
  function labels(app) {
    return app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
      .map(function (n) { return n.textContent; });
  }

  /* What the browser loads an image with, in a phone whose network answers
     `outcome` for every link: 'load', 'error', or 'never' (no answer at
     all, so only the page's own timer ends the wait). Records what it was
     asked to load. */
  function phoneImages(app, outcome) {
    const loaded = [];
    app.sandbox.window.Image = function () {
      const image = this;
      Object.defineProperty(image, 'src', {
        set: function (url) {
          loaded.push(url);
          if (outcome === 'never') { return; }
          app.sandbox.setTimeout(function () {
            const handler = outcome === 'error' ? image.onerror : image.onload;
            if (handler) { handler(); }
          }, 0);
        }
      });
    };
    return loaded;
  }

  await (async function photoServedByLink() {
    const gallery = [];
    const app = await openedPhoto({
      openPhoto: { ok: true, data: { handle: 'ph00000000aa', src: KEPT, link: true } }
    });
    app.sandbox.window.components = {
      saveToGallery: function (url) { gallery.push(url); return Promise.resolve(42); }
    };
    const loaded = phoneImages(app, 'load');

    it('shows a photo the server keeps, as it was sent', function () {
      drewCleanly(app, 'a photo kept on the server');
      eq(images(app).length, 1);
      eq(images(app)[0].src, KEPT);
      truthy(app.view.textContent.indexOf('You can see this once') !== -1);
    });

    click(app, 'Save to Photos');
    await settle(); await settle(); await settle(); await settle();

    it('asks the server for its link, saves that, then says it is saved', function () {
      eq(decisions(app).join(','), 'link,save');
      eq(gallery.join(','), SERVED, 'the link the server serves, and never the picture');
      truthy(app.view.textContent.indexOf('Photo saved to your phone') !== -1, app.view.textContent);
    });

    it('loads the link before the phone\'s Photos is given it', function () {
      eq(loaded.join(','), SERVED, 'loaded once, as the Photos app will load it');
    });
  })();

  /* A link that leads nowhere: lb-phone takes any link on an allowed host,
     so a public address that does not reach this server was saved all the
     same — "Saved to your Photos.", a broken picture there, the one look
     spent, and the file kept for good behind the saved link. */
  for (const outcome of ['error', 'never']) {
    await (async function photoLinkDoesNotLoad() {
      const gallery = [];
      const app = await openedPhoto({
        openPhoto: { ok: true, data: { handle: 'ph00000000aa', src: KEPT, link: true } }
      });
      app.sandbox.window.components = {
        saveToGallery: function (url) { gallery.push(url); return Promise.resolve(42); }
      };
      const loaded = phoneImages(app, outcome);
      click(app, 'Save to Photos');
      await settle(); await settle(); await settle();
      if (outcome === 'never') {
        // Nothing answers; the page's own wait runs out.
        const wait = app.timers.filter(function (t) { return t.ms === 8000 && !t.cleared; });
        eq(wait.length, 1, 'one wait for the link to load');
        wait[0].fn();
        await settle(); await settle(); await settle();
      }

      it('does not save a link that ' + (outcome === 'error' ? 'fails to load' : 'never loads')
        + ', and offers to keep the photo instead', function () {
        eq(loaded.join(','), SERVED, 'it was tried');
        eq(gallery.length, 0, 'never handed to the phone\'s Photos: ' + gallery.join(','));
        eq(decisions(app).join(','), 'link', 'not reported saved');
        eq(images(app).length, 1, 'still open, the look not lost');
        truthy(app.notice().indexOf('could not save') !== -1, app.notice());
        truthy(labels(app).indexOf('Keep it in the app instead') !== -1, labels(app).join(','));
      });

      click(app, 'Keep it in the app instead');
      await settle(); await settle();
      it('keeps it in the app when asked, after a link that ' + outcome + 's', function () {
        eq(decisions(app).join(','), 'link,keep');
      });
    })();
  }

  await (async function photoLinkRefused() {
    const app = await openedPhoto({
      openPhoto: { ok: true, data: { handle: 'ph00000000aa', src: KEPT, link: true } },
      photoDecision: function (body) {
        if (body.choice === 'link') { return { ok: false, err: 'photo_no_link' }; }
        return { ok: true, data: { handle: body.handle, state: body.choice === 'keep' ? 'kept' : 'deleted' } };
      }
    });
    app.sandbox.window.components = {
      saveToGallery: function () { throw new Error('nothing should reach the gallery'); }
    };
    click(app, 'Save to Photos');
    await settle(); await settle(); await settle();

    it('says the server had no link, and offers to keep it instead', function () {
      truthy(app.notice().indexOf('could not give your phone a link') !== -1, app.notice());
      truthy(labels(app).indexOf('Keep it in the app instead') !== -1, labels(app).join(','));
      eq(images(app).length, 1, 'still open');
      eq(decisions(app).join(','), 'link', 'asked, and nothing decided');
    });
  })();

  /* No link from the server: lb-phone's own upload, where the phone has
     one. It takes a Blob, made here from the data URI. */
  function blobWindow(window) {
    window.atob = function (text) { return Buffer.from(text, 'base64').toString('binary'); };
    window.Blob = function (parts, options) {
      this.parts = parts;
      this.type = options && options.type;
      this.size = parts.reduce(function (n, p) { return n + p.length; }, 0);
    };
  }

  await (async function photoUploadedByThePhone() {
    const uploads = [], gallery = [];
    const app = await openedPhoto({
      openPhoto: { ok: true, data: { handle: 'ph00000000aa', src: KEPT } }
    }, function (window) {
      blobWindow(window);
      window.components = {
        uploadMedia: function (kind, blob) {
          uploads.push({ kind: kind, blob: blob });
          return Promise.resolve('https://r2.qbox.re/abc123.webp');
        },
        saveToGallery: function (url) { gallery.push(url); return Promise.resolve(7); }
      };
    });
    click(app, 'Save to Photos');
    await settle(); await settle(); await settle(); await settle();

    it('uploads it with lb-phone, saves the upload, then tells the server', function () {
      eq(uploads.length, 1);
      eq(uploads[0].kind, 'Image');
      eq(uploads[0].blob.type, 'image/webp', 'the picture as the server sent it');
      eq(uploads[0].blob.size, Buffer.from(KEPT.split(',')[1], 'base64').length);
      eq(gallery.join(','), 'https://r2.qbox.re/abc123.webp');
      eq(decisions(app).join(','), 'save', 'no link asked of a server that has none');
      truthy(app.view.textContent.indexOf('Photo saved to your phone') !== -1, app.view.textContent);
    });
  })();

  await (async function photoUploadFails() {
    const app = await openedPhoto({
      openPhoto: { ok: true, data: { handle: 'ph00000000aa', src: KEPT } }
    }, function (window) {
      blobWindow(window);
      window.components = {
        uploadMedia: function () { return Promise.reject(new Error('no upload method')); },
        saveToGallery: function () { throw new Error('nothing to save'); }
      };
    });
    click(app, 'Save to Photos');
    await settle(); await settle(); await settle();

    it('keeps the photo open and offers to keep it in the app when the upload fails', function () {
      eq(decisions(app).length, 0);
      eq(images(app).length, 1);
      truthy(labels(app).indexOf('Keep it in the app instead') !== -1, labels(app).join(','));
    });
  })();

  await (async function photoNoRouteAtAll() {
    // A phone that saves links, and has no upload of its own to make one.
    const app = await openedPhoto({
      openPhoto: { ok: true, data: { handle: 'ph00000000aa', src: KEPT } }
    }, function (window) {
      window.components = { saveToGallery: function () { throw new Error('no link to save'); } };
    });

    it('says the phone cannot take it, and offers Save to keep it in the app', function () {
      drewCleanly(app, 'a photo nothing can save');
      eq(labels(app).indexOf('Save to Photos'), -1, 'not offered where it cannot work');
      truthy(labels(app).indexOf('Save') !== -1 && labels(app).indexOf('Delete') !== -1,
        labels(app).join(','));
      truthy(app.view.textContent.indexOf('can’t take it, so it is kept for you in this app') !== -1,
        app.view.textContent);
    });

    click(app, 'Save');
    await settle(); await settle();
    it('keeps it in the app', function () {
      eq(decisions(app).join(','), 'keep');
      truthy(app.notice().indexOf('Kept in this app') !== -1, app.notice());
      truthy(app.view.textContent.indexOf('Kept for you in this app') !== -1, app.view.textContent);
    });
  })();

  /* Kill photos off: a photo kept from before can still be opened, and
     nothing may take it to an image host. With no link from the server the
     page fell back to lb-phone's own upload, which does exactly that. */
  for (const src of [KEPT, 'https://r2.qbox.re/abc123.webp']) {
    await (async function photosOffNoUpload() {
      const uploads = [], gallery = [];
      const app = await openedPhoto({
        openPhoto: { ok: true, data: { handle: 'ph00000000aa', src: src, photosOff: true } }
      }, function (window) {
        blobWindow(window);
        window.components = {
          uploadMedia: function (kind, blob) {
            uploads.push(kind);
            return Promise.resolve('https://r2.qbox.re/def456.webp');
          },
          saveToGallery: function (url) { gallery.push(url); return Promise.resolve(7); }
        };
      });
      const kind = /^data:/.test(src) ? 'kept on the server' : 'on an image host';

      it('offers no way to the phone\'s Photos with kill photos off, for one ' + kind, function () {
        drewCleanly(app, 'a photo with kill photos off');
        eq(labels(app).indexOf('Save to Photos'), -1, labels(app).join(','));
        truthy(labels(app).indexOf('Save') !== -1 && labels(app).indexOf('Delete') !== -1,
          labels(app).join(','));
        truthy(app.view.textContent.indexOf('Kill photos are off on this server') !== -1,
          app.view.textContent);
      });

      click(app, 'Save');
      await settle(); await settle();
      it('keeps it in the app, and hands it to no upload or gallery, for one ' + kind, function () {
        eq(decisions(app).join(','), 'keep');
        eq(uploads.length, 0, 'nothing uploaded');
        eq(gallery.length, 0, 'nothing saved to the phone\'s Photos');
      });
    })();
  }

  await (async function photoNoRouteClosedElsewhere() {
    const app = await openedPhoto({
      openPhoto: { ok: true, data: { handle: 'ph00000000aa', src: KEPT } }
    });
    tab(app, 'board');
    await settle(); await settle();
    it('holds the tab bar here too, until it is kept or deleted', function () {
      eq(decisions(app).length, 0, decisions(app).join(','));
      eq(images(app).length, 1, 'still open');
      truthy(app.notice().indexOf('Save or delete the photo first') !== -1, app.notice());
    });
  })();

  await (async function photoKeptOpensAgain() {
    let opened = 0;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: MINE,
      ledger: photoLedger('kept'),
      openPhoto: function () {
        opened++;
        return { ok: true, data: { handle: 'ph00000000aa', src: KEPT, kept: true } };
      },
      photoDecision: function (body) {
        return { ok: true, data: { handle: body.handle, state: 'deleted' } };
      }
    });
    await settle(); await settle();
    tab(app, 'ledger');

    it('offers a kept photo to open again', function () {
      truthy(app.view.textContent.indexOf('Kept for you in this app') !== -1, app.view.textContent);
    });

    click(app, 'View photo');
    await settle(); await settle();
    it('shows it with Delete and Close, and nothing that spends a look', function () {
      drewCleanly(app, 'a kept photo');
      eq(images(app).length, 1);
      eq(labels(app).join(','), 'Delete,Close');
      truthy(app.view.textContent.indexOf('Kept for you in this app') !== -1, app.view.textContent);
    });

    // Left by the tab bar: a kept photo spends nothing by being left, so
    // the tab bar is not held for it.
    tab(app, 'board');
    await settle(); await settle();
    it('lets the tab bar leave a kept photo, without deleting it', function () {
      eq(images(app).length, 0, 'the board, not the photo');
      eq(decisions(app).length, 0, 'leaving a kept photo is not a Delete');
    });

    tab(app, 'ledger');
    click(app, 'View photo');
    await settle(); await settle();
    click(app, 'Close');
    await settle(); await settle();
    tab(app, 'board');
    await settle();
    it('closes without deleting it', function () {
      eq(decisions(app).length, 0, 'closing a kept photo is not a Delete');
    });

    tab(app, 'ledger');
    click(app, 'View photo');
    await settle(); await settle();
    click(app, 'Delete');
    await settle(); await settle();
    it('opens again as often as asked, and deletes it when told to', function () {
      eq(opened, 3);
      eq(decisions(app).join(','), 'delete');
      truthy(app.view.textContent.indexOf('Photo deleted') !== -1, app.view.textContent);
    });
  })();

  await (async function keptWithoutItsRow() {
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: MINE,
      ledger: { ok: true, data: {
        record: { completed: 0, placed: 1, survived: 0, standing: 'Unproven' },
        entries: [],
        kept: [{ handle: 'ph00000000cc', state: 'kept', taken_at: Math.floor(Date.now() / 1000) - 3 * 86400 }]
      } }
    });
    await settle(); await settle();
    tab(app, 'ledger');
    it('lists a kept photo whose row has gone, so it can still be found', function () {
      drewCleanly(app, 'the kept list');
      truthy(app.view.textContent.indexOf('Photos kept in this app') !== -1, app.view.textContent);
      truthy(app.view.textContent.indexOf('Taken 3 days ago') !== -1, app.view.textContent);
      eq(app.view.textContent.indexOf('No history yet'), -1, 'it is not an empty ledger');
      truthy(labels(app).indexOf('View photo') !== -1, labels(app).join(','));
    });
  })();

  await (async function photoNeverArrived() {
    const app = await openedPhoto({
      openPhoto: { ok: false, err: 'photo_no_answer' }
    });
    it('says a photo that never reached the phone is gone, and tells the server', function () {
      drewCleanly(app, 'a photo that never arrived');
      truthy(app.notice().indexOf('did not reach your phone') !== -1, app.notice());
      eq(decisions(app).join(','), 'delete', 'deleted now, not when the time to decide runs out');
      truthy(app.view.textContent.indexOf('Photo deleted') !== -1, app.view.textContent);
      eq(app.view.all().filter(function (n) { return n.tagName === 'IMG'; }).length, 0);
    });
  })();

  /* A photo kept in the app spends nothing by being opened, so one whose
     delivery ran out is still kept. Reported as deleted, the server deleted
     it, file and all, because one delivery was slow. The client says it was
     kept; the page also knows from the row, or from the kept list. */
  await (async function keptPhotoNeverArrived() {
    for (const variant of [
      { name: 'the client says it is kept', ledger: photoLedger('kept'),
        answer: { ok: false, err: 'photo_no_answer', data: { handle: 'ph00000000aa', kept: true } } },
      { name: 'the row says it is kept', ledger: photoLedger('kept'),
        answer: { ok: false, err: 'photo_no_answer' } },
      { name: 'the kept list says it is kept',
        ledger: { ok: true, data: {
          record: { completed: 0, placed: 1, survived: 0, standing: 'Unproven' },
          entries: [],
          kept: [{ handle: 'ph00000000aa', state: 'kept', taken_at: Math.floor(Date.now() / 1000) - 60 }]
        } },
        answer: { ok: false, err: 'photo_no_answer' } }
    ]) {
      let opened = 0;
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
        mine: MINE,
        ledger: variant.ledger,
        openPhoto: function () {
          opened++;
          return opened === 1 ? variant.answer
            : { ok: true, data: { handle: 'ph00000000aa', src: KEPT, kept: true } };
        },
        photoDecision: function (body) {
          return { ok: true, data: { handle: body.handle, state: 'deleted' } };
        }
      });
      await settle(); await settle();
      tab(app, 'ledger');
      click(app, 'View photo');
      await settle(); await settle();

      it('keeps a kept photo whose delivery ran out (' + variant.name + ')', function () {
        drewCleanly(app, 'a kept photo that never arrived');
        eq(decisions(app).length, 0, 'the server was told to delete a photo its owner kept');
        truthy(app.notice().indexOf('still kept') !== -1, app.notice());
        eq(app.notice().indexOf('deleted'), -1, app.notice());
        eq(app.view.textContent.indexOf('Photo deleted'), -1, app.view.textContent);
        truthy(labels(app).indexOf('View photo') !== -1, labels(app).join(','));
      });

      click(app, 'View photo');
      await settle(); await settle();
      it('and opens it on the next try (' + variant.name + ')', function () {
        eq(opened, 2);
        eq(images(app).length, 1);
        eq(labels(app).join(','), 'Delete,Close');
      });
    }
  })();

  await (async function lawEnforcementWarning() {
    const leo = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    leo.targetProtected = true;

    const board = { ok: true, data: {
      page: 1, pages: 1,
      settings: { warnCreator: true, warnHitman: true, flagListing: true, minQueryLength: 4 },
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
      slots: 1, slotsClaimed: 0, currentSlot: 1, hitmenActive: 1, hitmenMax: 5,
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

    click(app, 'Pay $15,000');
    await settle();
    it('sends the buyout once confirmed', function () {
      truthy(bought, 'the buyout must reach the server');
      eq(bought.id, 'ct00000001');
    });
  })();

  await (async function hitmanCanWalkAway() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hitman';
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

    it('offers the hitman a way off the contract', function () {
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
    held.role = 'hitman';
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
    it('offers a thread from the hitman card', function () { truthy(talk, 'a Message button'); });
    if (talk) { talk.onclick(); await settle(); await settle(); }

    it('renders both sides of the conversation', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('Is it done?') !== -1, 'theirs: ' + text);
      truthy(text.indexOf('Working on it.') !== -1, 'and ours');
      truthy(text.indexOf('Operative #1') !== -1, 'under the alias, never a name');
    });

    it('calls the person who placed it that, a message signed "Client" before included', function () {
      const who = app.view.all().filter(function (n) {
        return n._className === 'who';
      }).map(function (n) { return n.textContent; });
      eq(who.join(' | '), 'The person who placed it | Operative #1');
      truthy(app.view.textContent.indexOf('with the person who placed it') !== -1,
        app.view.textContent);
      falsy(app.view.textContent.indexOf('Client') !== -1, app.view.textContent);
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
      // The live field, not the node captured before the send. Sending
      // re-reads the thread and redraws it, so `field` is a node that is no
      // longer on screen — and the box the player is looking at is the new
      // one. Reading the stale node asserted that the text was cleared
      // before the server had answered, which is the behaviour that lost a
      // refused message.
      const live = app.view.all().filter(function (n) {
        return n.tagName === 'INPUT';
      }).pop();
      truthy(live, 'the compose box should still be there');
      eq(live.value, '', 'the field empties after sending');
    });

    it('does not send on any other key', function () {
      const before = sent;
      const live = app.view.all().filter(function (n) {
        return n.tagName === 'INPUT';
      }).pop();
      live.value = 'half typed';
      live.onkeydown({ key: 'a' });
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
    held.role = 'hitman';
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
    held.role = 'hitman';
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

  /* Answering a proposal the server has closed. The panel kept Agree and
     Decline for good and the words were the shared table's. */
  await (async function answeringAClosedProposal() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hitman';
    held.myAlias = 'Operative #1';
    let open = true;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      amendments: function () {
        return { ok: true, data: open ? [{
          id: 'am00000002', kind: 'shorten_deadline', payload: { seconds: 900 },
          proposer: 'The client', mine: false, answered: false, waiting: 1, expires: 0
        }] : [] };
      },
      respondAmendment: function () { open = false; return { ok: false, err: 'proposal_expired' }; }
    });
    await settle(); await settle(); await settle();
    tab(app, 'mine');
    await settle();
    click(app, 'Agree');
    await settle(); await settle(); await settle();
    it('says the proposal ran out, in words about proposals', function () {
      truthy(app.notice().indexOf('ran out') !== -1, 'the notice: ' + app.notice());
    });
    it('stops offering an answer to it', function () {
      const labels = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      falsy(labels.indexOf('Agree') !== -1, 'Agree is still drawn: ' + labels.join(' | '));
    });
  })();

  await (async function ownProposalIsNotAnswerable() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hitman';
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
    held.role = 'hitman';
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
    held.role = 'hitman';
    held.myAlias = 'Operative #1';

    function open(settings, callReply) {
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: settings } },
        mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
        ledger: LEDGER,
        readThread: { ok: true, data: [] },
        requestCall: callReply,
        endCall: { ok: true, data: { ended: true } }
      });
      return app;
    }

    const app = open({ calls: true }, { ok: true, data: { placed: true } });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();

    // Open the thread the way a hitman does, from their card.
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

    // lb-phone draws no call screen for a call placed this way, so the
    // thread is the only place the caller can hang it up.
    const hangButton = app.document.getElementById('thread-hangup');

    it('offers Hang up while the call is live', function () {
      truthy(hangButton, 'a hang up button');
      falsy(app.document.getElementById('thread-call'), 'in place of Call');
    });

    if (hangButton) {
      hangButton.onclick();
      await settle(); await settle();
    }

    it('hangs up through the server and offers Call again', function () {
      eq(app.sent.filter(function (s) { return s.name === 'endCall'; }).length, 1);
      truthy(app.notice().indexOf('Call ended') !== -1, 'the notice: ' + app.notice());
      truthy(app.document.getElementById('thread-call'), 'Call is back');
      falsy(app.document.getElementById('thread-hangup'));
    });

    // A phone that cannot place calls still gets the other party asked.
    const asked = open({ calls: true },
      { ok: true, data: { placed: false, reason: 'callback' } });
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

  // A thread can be muted from its head, for this player only (spec 11.4).
  // A hitman opens their thread with no entry to carry the mute on, so it
  // comes back with the read.
  await (async function threadMute() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hitman';
    held.myAlias = 'Operative #1';

    let mutedOnServer = true;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: { calls: true } } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      readThread: function () {
        return { ok: true, data: {
          messages: [{ alias: 'Client', body: 'Still there?', at: 1 }],
          muted: mutedOnServer } };
      },
      muteThread: function (body) {
        mutedOnServer = body.muted === true;
        return { ok: true, data: { muted: mutedOnServer } };
      }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Message';
    })[0].onclick();
    await settle(); await settle();

    const first = app.document.getElementById('thread-mute');

    it('opens on the mute the server read back, messages and all', function () {
      truthy(first, 'a mute button in the thread head');
      eq(first && first.textContent, 'Unmute');
      truthy(app.view.textContent.indexOf('Still there?') !== -1,
        'a muted thread still shows its messages');
    });

    if (first) { first.onclick(); await settle(); await settle(); }

    it('unmutes this thread through the server', function () {
      const sent = app.sent.filter(function (s) { return s.name === 'muteThread'; });
      eq(sent.length, 1);
      eq(sent[0].body.id, 'ct00000001', 'the contract, not undefined');
      eq(sent[0].body.muted, false);
      eq(app.document.getElementById('thread-mute').textContent, 'Mute');
      truthy(app.notice().indexOf('ring your phone again') !== -1, 'the notice: ' + app.notice());
    });

    const second = app.document.getElementById('thread-mute');
    if (second) { second.onclick(); await settle(); await settle(); }

    it('mutes it again, and says contract updates still ring', function () {
      const sent = app.sent.filter(function (s) { return s.name === 'muteThread'; });
      eq(sent.length, 2);
      eq(sent[1].body.muted, true);
      eq(app.document.getElementById('thread-mute').textContent, 'Unmute');
      truthy(app.notice().indexOf('Contract updates still will') !== -1,
        'the notice: ' + app.notice());
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

    it('refreshes once for the whole burst, reading what the board draws', function () {
      // The board, and not Mine and the ledger behind it: those are read
      // when their tabs are opened (pushReadsWhatIsShown below).
      const calls = app.sent.slice(opening).map(function (s) { return s.name; }).sort();
      eq(JSON.stringify(calls), JSON.stringify(['list']),
        'exactly one refresh: ' + JSON.stringify(calls));
    });

    it('still ignores a mirrored reply', function () {
      const before = app.sent.length;
      app.sandbox.window._message({ data: { type: 'result', event: 'list' } });
      eq(app.sent.length, before, 'a reply is not a push');
    });
  })();

  /* A push re-read the board, Mine and the ledger whatever tab was open:
     three requests from the bucket all three share where one was drawn,
     and the board, the costliest thing the server builds, for players who
     were not looking at it. Each tab reads what it draws; the rest is read
     when its tab is opened. */
  await (async function pushReadsWhatIsShown() {
    const app = boot({ list: BOARD, mine: MINE, ledger: LEDGER });
    await settle(); await settle();

    async function pushedOn(name) {
      tab(app, name);
      await settle(); await settle();
      const before = app.sent.length;
      app.sandbox.window._message({ data: { type: 'push', reason: 'accepted' } });
      const due = app.timers.filter(function (t) { return t.ms === 250 && !t.cleared; });
      due[due.length - 1].fn();
      await settle(); await settle();
      return app.sent.slice(before).map(function (r) { return r.name; }).sort();
    }

    const read = {};
    for (const name of ['ledger', 'mine', 'onme', 'place', 'board']) {
      read[name] = await pushedOn(name);
    }
    it('reads, on each tab, only what that tab draws', function () {
      drewCleanly(app, 'pushes on every tab');
      eq(JSON.stringify(read.board), JSON.stringify(['list']), 'board');
      eq(JSON.stringify(read.mine), JSON.stringify(['ledger', 'mine']),
        'Mine draws the ledger\'s record too');
      eq(JSON.stringify(read.onme), JSON.stringify(['mine']), 'On me');
      eq(JSON.stringify(read.ledger), JSON.stringify(['ledger']), 'the ledger');
      eq(JSON.stringify(read.place), JSON.stringify([]), 'the Place form draws none of them');
    });

    const before = app.sent.length;
    tab(app, 'ledger');
    await settle(); await settle();
    it('reads the ledger when its tab is opened, now a push may not have', function () {
      eq(JSON.stringify(app.sent.slice(before).map(function (r) { return r.name; })),
        JSON.stringify(['ledger']));
    });
  })();

  /* Every reply redrew the open tab whether it showed the reply or not,
     and NUI replies land in tasks of their own, so the coalescing did not
     merge them: a refresh on the Board was three rebuilds of it. */
  await (async function redrawsOnlyWhatIsShown() {
    const waiting = {};
    function later(name, answer) {
      return function () {
        return new Promise(function (resolve) { waiting[name] = function () { resolve(answer); }; });
      };
    }
    const app = boot({ list: later('list', BOARD), mine: later('mine', MINE),
      ledger: later('ledger', LEDGER) });
    await settle(); await settle();
    // The opening reads, answered.
    ['list', 'mine', 'ledger'].forEach(function (n) { waiting[n](); });
    await settle(); await settle();

    tab(app, 'board');
    await settle();
    const view = app.document.getElementById('view');
    const drawsBefore = view._clears || 0;
    // The three replies, each in a task of its own.
    for (const n of ['ledger', 'mine', 'list']) {
      waiting[n]();
      await settle(); await settle();
    }
    it('redraws the board for the board\'s reply, and not for Mine\'s or the ledger\'s', function () {
      drewCleanly(app, 'replies landing apart');
      eq((view._clears || 0) - drawsBefore, 1, 'full rebuilds of the board');
      truthy(app.view.textContent.indexOf('Dana Reyes') !== -1, 'and it shows the board');
    });
  })();

  /* Refused proposal reads each kept a retry of their own going for as long
     as the contract stayed unread, and every push started another: while
     the bucket was empty the reads multiplied with every refresh, and took
     the tokens the last Mine read needed. */
  await (async function proposalsOneReadAtATime() {
    const placed = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    placed.role = 'creator';
    placed.hitmen = [];
    let asked = 0;
    const app = boot({
      list: BOARD, ledger: LEDGER,
      mine: { ok: true, data: { created: [placed], accepted: [], onMe: [] } },
      amendments: function () {
        asked++;
        return { ok: false, err: 'rate_limited', data: { retryAfter: 2 } };
      }
    });
    await settle(); await settle();
    tab(app, 'mine');
    await settle(); await settle(); await settle();
    const first = asked;

    // Three pushes that name no contract, each refreshed, each refused.
    for (let i = 0; i < 3; i++) {
      app.sandbox.window._message({ data: { type: 'push', reason: 'accepted' } });
      const due = app.timers.filter(function (t) { return t.ms === 250 && !t.cleared; });
      due[due.length - 1].fn();
      await settle(); await settle(); await settle();
    }
    const afterPushes = asked;

    // Every retry that was waiting comes due.
    app.timers.filter(function (t) { return t.ms === 2000 && !t.cleared; })
      .forEach(function (t) { t.fn(); });
    await settle(); await settle(); await settle();

    it('keeps one read of a contract\'s proposals going, however many refreshes ask', function () {
      truthy(first >= 1, 'the opening read was asked: ' + first);
      eq(afterPushes - first, 3, 'one fresh read per push, which forgets the stale one');
      eq(asked - afterPushes, 1, 'and of the retries waiting, only the live one asks again: '
        + (asked - afterPushes));
    });

    // Left Mine while a retry waited: it does not ask from the board, and
    // asks again when Mine is opened.
    tab(app, 'board');
    await settle(); await settle();
    const onBoard = asked;
    app.timers.filter(function (t) { return t.ms === 2000 && !t.cleared; })
      .forEach(function (t) { t.fn(); });
    await settle(); await settle();
    tab(app, 'mine');
    await settle(); await settle(); await settle();
    it('asks again when Mine is opened after a retry it skipped', function () {
      eq(asked, onBoard + 1, 'nothing from the board, then one read on Mine');
    });
  })();

  /* The handover countdown rebuilt the whole Mine tab — every card, face and
     icon — once a second to move one bar. It is painted in place now, as
     the clock chips are. */
  await (async function countdownPaintsInPlace() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hitman';
    held.myAlias = 'Operative #1';
    held.kidnapProgress = { elapsed: 4, required: 30, graceLeft: 3000, graceTotal: 3000 };
    let elapsed = 4;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      kidnapProgress: function () {
        elapsed += 1;
        return { ok: true, data: { elapsed: elapsed, required: 30, graceLeft: 3000, graceTotal: 3000 } };
      }
    });
    await settle(); await settle();
    tab(app, 'mine');
    await settle(); await settle();
    const view = app.document.getElementById('view');
    const poll = app.timers.filter(function (t) { return t.repeating && t.ms === 1000 && !t.cleared; });
    const drawsBefore = view._clears || 0;
    for (let i = 0; i < 3; i++) {
      poll[poll.length - 1].fn();
      await settle(); await settle();
    }
    it('moves the bar without rebuilding the tab', function () {
      drewCleanly(app, 'a countdown painted in place');
      eq(poll.length >= 1, true, 'the countdown is polled');
      eq((view._clears || 0) - drawsBefore, 0, 'full rebuilds of Mine during the countdown');
      truthy(app.view.textContent.indexOf('7s of 30s') !== -1,
        'and the bar says where it is: ' + app.view.textContent);
      eq(app.view.all().filter(function (n) {
        return n._className && n._className.split(' ').indexOf('countdown') !== -1;
      }).length, 1, 'one bar, not one more per poll');
    });
  })();

  /* Every face ever seen was kept: each new render of a target has a new
     reference, so an hour on the board, or a busy board paged through, held
     megabytes more for as long as the app stayed open. */
  await (async function facesAreNotKeptForever() {
    let generation = 1;
    const asked = [];
    function boardOf(gen) {
      const rows = [];
      for (let i = 0; i < 15; i++) {
        const row = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
        row.id = 'ct' + String(1000000 + i);
        row.targetImageId = 'mg' + gen + '_' + String(100000 + i);
        rows.push(row);
      }
      return { ok: true, data: { page: 1, pages: 1, contracts: rows, settings: {} } };
    }
    const app = boot({
      list: function () { return boardOf(generation); },
      mine: MINE, ledger: LEDGER,
      mugshotImage: function (body) {
        asked.push(body.id);
        return { ok: true, data: { id: body.id, image: 'data:image/webp;base64,' + body.id } };
      }
    });
    await settle(); await settle(); await settle();
    async function show(gen) {
      generation = gen;
      tab(app, 'board');
      for (let i = 0; i < 4; i++) { await settle(); }
      await drainFaces(app);
    }
    for (let gen = 2; gen <= 5; gen++) { await show(gen); }
    const afterFive = asked.length;
    await show(5);
    const again = asked.length - afterFive;
    await show(1);
    const oldest = asked.length - afterFive - again;
    it('keeps the faces it draws, and lets the oldest go', function () {
      drewCleanly(app, 'five boards of faces');
      eq(afterFive, 75, 'five boards of fifteen new faces');
      eq(again, 0, 'the faces on screen are kept');
      eq(oldest, 15, 'the first board\'s faces were let go, and are asked for again');
    });
  })();

  /* Opening the app asked for a whole board page of faces in the same
     instant as the board, Mine and the ledger: eighteen events to the server
     at once, against a budget of ten a second per player. */
  await (async function facesArePacedOnOpen() {
    const rows = [];
    for (let i = 0; i < 15; i++) {
      const row = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
      row.id = 'ct' + String(2000000 + i);
      row.targetImageId = 'mg7_' + String(200000 + i);
      rows.push(row);
    }
    const asked = [];
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: rows, settings: {} } },
      mine: MINE, ledger: LEDGER,
      mugshotImage: function (body) {
        asked.push(body.id);
        return { ok: true, data: { id: body.id, image: 'data:image/webp;base64,' + body.id } };
      }
    });
    for (let i = 0; i < 6; i++) { await settle(); }
    const firstSecond = app.sent.length;
    const facesFirst = asked.length;
    const drawnEarly = app.view.all().filter(function (n) {
      return n.tagName === 'IMG' && n._className === 'mugshot';
    }).length;
    await drainFaces(app);

    it('stays within ten requests in the first second', function () {
      truthy(firstSecond <= 10, firstSecond + ' requests: '
        + app.sent.map(function (r) { return r.name; }).join(', '));
      eq(facesFirst, 5, 'the first five faces go at once');
    });

    it('still asks for every face, once, and draws them together', function () {
      eq(asked.length, 15, 'every face on the page');
      eq(new Set(asked).size, 15, 'none twice');
      eq(drawnEarly, 0, 'no half-drawn page while the rest are queued');
      const shots = app.view.all().filter(function (n) {
        return n.tagName === 'IMG' && n._className === 'mugshot';
      });
      eq(shots.length, 15, 'one redraw once the last face is in');
      drewCleanly(app, 'a paced page of faces');
    });

    it('leaves no timer behind once every face is in', function () {
      const left = app.timers.filter(function (t) {
        return !t.repeating && !t.cleared && t.ms === 1000;
      });
      eq(left.length, 0, 'an idle board holds no face timer');
    });
  })();

  // A hitman whose hold is slipping had no way to know: the server has always
  // sent the reason and the grace budget, and the app rendered neither.
  await (async function countdownShowsItsGrace() {
    function withProgress(progress) {
      const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
      held.role = 'hitman';
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
      truthy(text.indexOf('3.0s of leeway left — the handover fails if it runs out') !== -1,
        'the grace budget, and what happens when it is gone: ' + text);
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
      truthy(text.indexOf('The person who placed this contract must be') !== -1,
        'the reason, not the code, and who it is about: ' + text);
      falsy(text.indexOf('creator_too_far') !== -1,
        'a raw reason code must not reach the player: ' + text);
      truthy(text.indexOf('The person who placed this contract must be right there with you and '
        + 'the target — handover fails in 0.9s') !== -1,
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
      falsy(none.view.textContent.indexOf('leeway left') !== -1
        || none.view.textContent.indexOf('handover fails in') !== -1,
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
    // Deliberately not 1: the form's own fallback is 1, so a fixture of 1
    // would pass whether or not the ceiling came from the server at all.
    caps: { maxStacks: 3, maxPerStack: 100, maxWeapons: 2, slots: 3 }
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

  /* What placing takes, said before the button and again after it.
   *
   * The kidnapping bonus opens at 50% and is escrowed with the rest, and the
   * only place the total ever appeared was a refusal for not having it. The
   * confirmation said "Contract placed." about a buyout the server had moved
   * and a deadline nobody was told. Goods marked alive only go into the
   * payout's bonus half, which the form had no way to fill. */
  await (async function placeSaysWhatItTakes() {
    const app = placeForm({
      create: function (body) {
        app.body = body;
        return { ok: true, data: { bailoutAmount: 60000, penaltyAmount: 0, secondsLeft: 10800 } };
      }
    });
    await settle(); await settle();
    tab(app, 'place');
    await settle(); await settle();

    const query = pick(app, 'target-query');
    query.value = 'Dana';
    query.oninput();
    app.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();
    app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent.indexOf('Dana Reyes') === 0;
    })[0].onclick();

    it('offers a way back to the list once somebody is picked', function () {
      truthy(app.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Choose someone else';
      }), 'a wrong tap left one row and nothing to undo it');
    });

    const total = function () { return app.document.getElementById('place-total').textContent; };
    it('says there is nothing in it yet', function () {
      eq(total(), 'Nothing in the reward yet.');
    });

    pick(app, 'slot-cash-1', 40000);
    it('counts the bonus on top in the total', function () {
      eq(total(), 'Taken from you now: $60,000 cash ($40,000 + $20,000 kidnapping bonus). '
        + 'The bonus comes back to you if the target is killed rather than delivered.');
    });

    const alive = pick(app, 'slot-alive-1');
    alive.checked = true;
    alive.onclick();
    pick(app, 'slot-item-1').value = 'lockpick';
    press(app, 'slot-item-add-1');
    it('marks a pick made alive only, and names it in the total', function () {
      truthy(app.view.textContent.indexOf('Lockpick x1 — alive only') !== -1, app.view.textContent);
      truthy(total().indexOf('$60,000 cash ($40,000 + $20,000 kidnapping bonus) and Lockpick (alive only).') !== -1,
        total());
    });

    pick(app, 'bailout', 1000);
    press(app, 'place-submit');
    await settle(); await settle();

    it('sends the alive-only pick as the payout bonus, beside the percentage', function () {
      const slot = app.body.reward.slots[0];
      eq(slot.baseline.cash, 40000);
      falsy(slot.baseline.items, 'kept out of what a kill pays');
      eq(JSON.stringify(slot.bonus), JSON.stringify({ items: [{ name: 'lockpick', count: 1 }] }));
      eq(app.body.bonusPercent, 50);
    });

    it('says what was held, the buyout it settled on and when it runs out', function () {
      const said = app.notice();
      truthy(said.indexOf('Held from you: $60,000 cash') !== -1, said);
      truthy(said.indexOf('Buyout $60,000.') !== -1, said);
      truthy(said.indexOf('moved to the nearest amount') !== -1, said);
      truthy(said.indexOf('runs out in 3h') !== -1, said);
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

    /* W057: with the advisory on, as shipped, the warning stated a fact
       under a "Yes" button and never asked the question. It asks, every
       time, and its button says what it does. */
    it('asks the question under the warning, with a button that says what it does', function () {
      truthy(app.view.textContent.indexOf('Place a contract on them anyway?') !== -1,
        'the question: ' + app.view.textContent);
      truthy(app.view.textContent.indexOf('every officer in the city') !== -1,
        'and what placing it does: ' + app.view.textContent);
      // W112: the bulletin reaches officers off duty too.
      falsy(app.view.textContent.indexOf('on duty') !== -1,
        'not "on duty": off-duty officers are told as well: ' + app.view.textContent);
      falsy(app.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Yes';
      }), 'no bare Yes');
    });

    // Confirm it, the way a player does.
    const yes = app.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Place it';
    })[0];
    truthy(yes, 'a way to confirm');
    if (yes) { yes.onclick(); await settle(); await settle(); }

    it('places the contract the player actually built', function () {
      truthy(submission, 'confirming must submit, not rebuild an empty form');
      eq(submission.reason, 'Unpaid debt', 'with what was typed');
      eq(submission.reward.slots[0].baseline.cash, 5000, 'and what was funded');
    });

    // W058: the agreement goes with it, so a target who took a protected
    // job after being picked is refused until the warning has been seen.
    it('sends the warning\'s acknowledgement with the contract', function () {
      eq(submission && submission.shown && submission.shown.protectedAck, true);
    });
  })();

  await (async function stakesGoods() {
    const app = placeForm();
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('offers as many payouts as the server allows', function () {
      eq(app.document.getElementById('slots-count').max, 3,
        'the ceiling comes from the config, not from the form');
      truthy(GOODS.caps.slots !== 1,
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

  /* Config.Limits.MaxPayoutSlots as it ships, 1: each contract is
     collected once, and the form says nothing about collecting it again. */
  await (async function collectedOnce() {
    const app = placeForm({
      rewardOptions: { ok: true, data: Object.assign({}, GOODS,
        { caps: Object.assign({}, GOODS.caps, { slots: 1, minValue: 1000 }) }) }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('shows no extra-collection controls where a contract is collected once', function () {
      falsy(app.document.getElementById('slots-count'), 'no payout count');
      falsy(app.document.getElementById('slots-ceiling'), 'no note about the most allowed');
      const text = app.view.textContent;
      falsy(text.indexOf('how many times it can be collected') !== -1, text);
      falsy(text.indexOf('More hitmen may accept than there are payouts') !== -1, text);
      falsy(text.indexOf('Payout 1') !== -1, 'the one reward is not numbered: ' + text);
      truthy(app.document.getElementById('slot-cash-1'), 'the reward itself is still set here');
    });

    it('says nothing about payouts in the Payment section, the least reward included', function () {
      const payment = app.view.all().filter(function (n) {
        return n.tagName === 'SECTION' && n.textContent.indexOf('Payment') === 0;
      })[0];
      truthy(payment, 'a Payment section');
      const text = payment.textContent;
      truthy(text.indexOf('cash, bank and dirty money in the reward.') !== -1, text);
      falsy(/payout/i.test(text), 'a payout named where there is one collection: ' + text);
    });

    it('nor anywhere else in the form, the kidnapping bonus\'s hint included', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('Paid on top of the reward when the target is delivered alive') !== -1, text);
      falsy(/payout/i.test(text), 'a payout named where there is one collection: ' + text);
    });

    pick(app, 'slot-cash-1', 6000);
    pick(app, 'target-handle', 'tg00000001');
    pick(app, 'reason', 'Unpaid debt');
    press(app, 'place-submit');
    await settle(); await settle();

    it('places it with one collection', function () {
      const sent = app.submitted();
      truthy(sent, 'the contract went to the server');
      eq(sent.reward.slots.length, 1);
      eq(sent.reward.slots[0].baseline.cash, 6000);
    });
  })();

  /* The same, where the goods the reward can carry run out: each refusal
     names the reward, not a payout there is only one of. */
  await (async function collectedOnceFull() {
    const app = placeForm({
      rewardOptions: { ok: true, data: Object.assign({}, GOODS,
        { caps: { maxStacks: 1, maxPerStack: 10, maxWeapons: 1, slots: 1, minValue: 1000 } }) }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
    await settle(); await settle();

    it('says the reward, not a payout, when it cannot carry more', function () {
      pick(app, 'slot-item-1').value = 'bandage';
      pick(app, 'slot-item-count-1', 20);
      press(app, 'slot-item-add-1');
      eq(app.notice(), 'That is more than the reward can hold of a single item.');
      pick(app, 'slot-item-1').value = 'bandage';
      pick(app, 'slot-item-count-1', 5);
      press(app, 'slot-item-add-1');
      pick(app, 'slot-item-1').value = 'lockpick';
      pick(app, 'slot-item-count-1', 1);
      press(app, 'slot-item-add-1');
      eq(app.notice(), 'The reward is already carrying as many kinds of item as it can.');
      pick(app, 'slot-weapon-1').value = '3';
      press(app, 'slot-weapon-add-1');
      pick(app, 'slot-weapon-1').value = '4';
      press(app, 'slot-weapon-add-1');
      eq(app.notice(), 'The reward is already carrying as many weapons as it can.');
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

    it('falls back to one collection rather than offering what the server may refuse', function () {
      // caps.slots is absent in this fixture, which is what a server too old
      // to send it looks like.
      falsy(app.document.getElementById('slots-count'), 'no count to choose');
      falsy(app.view.textContent.indexOf('Payout 1') !== -1, 'and no numbered payout');
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
        rewardOptions: { ok: true, data: { cash: 100000, bank: 0, dirty: 0, caps: { slots: 3 } } },
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
        hitmenActive: 0, hitmenMax: 5, targetName: 'Dana ' + i,
        targetProtected: false, creatorName: 'Vic', role: 'creator', hitmen: []
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
    //
    // A rebuild, not a return to the tab: a push lands and everything is
    // redrawn. Opening the tab again is the player asking for the form as it
    // is now, and that does read the wallet again (below).
    const afterArrival = inFlightCalls;
    chatty.sandbox.window._message({ data: { type: 'push', reason: 'accepted' } });
    chatty.timers.filter(function (t) { return t.ms === 250 && !t.cleared; })
      .forEach(function (t) { t.cleared = true; t.fn(); });
    await settle(); await settle();

    it('and does not ask again once it has one', function () {
      eq(inFlightCalls, afterArrival,
        're-rendered the form and asked for a wallet it already had');
    });

    /* But opening the form again does read it again.

       It was read on the first open and never after until a contract was
       placed, so every balance on the form was whatever the player carried
       then — a stake paid, a buyout, a purchase anywhere in the city since,
       and the form offered money they no longer had and was then refused
       with "You do not have that" beside a balance saying they did. */
    let walletReads = 0;
    const moving = boot(base({
      browseTargets: { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } },
      rewardOptions: function () {
        walletReads++;
        return { ok: true, data: { cash: walletReads === 1 ? 50000 : 1200, bank: 0,
          dirty: 0, items: [], weapons: [], inventoryRead: true, caps: {} } };
      }
    }));
    await settle(); await settle();
    await toPlace(moving);
    const firstBalance = (moving.view.textContent.match(/Cash \$[\d,]+/) || [])[0];
    moving.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'board'; })[0].onclick();
    await settle();
    await toPlace(moving);
    const secondBalance = (moving.view.textContent.match(/Cash \$[\d,]+/) || [])[0];

    it('reads the wallet again when the form is opened again', function () {
      eq(firstBalance, 'Cash $50,000');
      eq(secondBalance, 'Cash $1,200',
        'the form went on showing a balance read on its first opening');
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
      hitmenActive: 0, hitmenMax: 5,
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

    /* A held contract: lines without ids, not editable. "Take back" was
       drawn anyway and only ever said "Nothing ticked". */
    const heldEditor = await openEditor({ rewardBreakdown: { ok: true, data: {
      editable: false, reason: 'A hitman is working this, so it can only be added to.',
      slots: 1, currentSlot: 1,
      lines: [{ slot: 1, portion: 'baseline', source: 'cash', amount: 5000 }]
    } } });
    it('offers no take-back on a contract somebody holds', function () {
      const labels = heldEditor.view.all().concat(heldEditor.document.body.all())
        .filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      falsy(labels.indexOf('Take back what I ticked') !== -1, labels.join(' | '));
      truthy(labels.indexOf('Add to it') !== -1, 'adding is still offered: ' + labels.join(' | '));
    });

    /* Taken while the editor was open: the server says so, and the page
       says so in words and closes the editor. */
    const raced = await openEditor({ withdrawReward: { ok: false, err: 'contract_taken' } });
    const tick = raced.view.all().concat(raced.document.body.all())
      .filter(function (n) { return n.tagName === 'INPUT' && n.type === 'checkbox'; })[0];
    if (tick) { tick.checked = true; tick.onchange(); }
    const takeBack = raced.view.all().concat(raced.document.body.all())
      .filter(function (n) { return n.tagName === 'BUTTON' && n.textContent === 'Take back what I ticked'; })[0];
    if (takeBack) { takeBack.onclick(); }
    await settle(); await settle();
    it('says a hitman took it, rather than "Not right now."', function () {
      truthy(tick && takeBack, 'the editor drew a line and the button');
      truthy(raced.notice().indexOf('Somebody has taken this contract') !== -1,
        'the notice: ' + raced.notice());
    });
    it('closes the editor, whose take-backs no longer apply', function () {
      const still = raced.view.all().concat(raced.document.body.all())
        .filter(function (n) { return n.tagName === 'BUTTON' && n.textContent === 'Take back what I ticked'; });
      eq(still.length, 0, 'the editor stayed open offering what the server will refuse');
    });

    /* Three collections funded alike drew three identical rows. */
    const threeAlike = await openEditor({ rewardBreakdown: { ok: true, data: {
      editable: true, slots: 3, currentSlot: 1,
      lines: [1, 2, 3].map(function (n) {
        return { id: 'ct00000001:' + n, slot: n, portion: 'baseline', source: 'cash',
                 amount: 5000, withdrawable: true };
      })
    } } });
    it('names the collection each line pays out of', function () {
      const shown = threeAlike.view.textContent;
      truthy(shown.indexOf('Payout 3:') !== -1 && shown.indexOf('Payout 1:') !== -1,
        'three identical rows and no way to tell which is which: ' + shown);
    });

    const oneOnly = await openEditor();
    it('does not number the lines of a contract that pays once', function () {
      falsy(oneOnly.view.textContent.indexOf('Payout 1:') !== -1,
        oneOnly.view.textContent);
    });

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

    /* A contract somebody is working can be added to but not reduced. The
       server decides that; the page has to show the reason rather than an
       empty list with no explanation. */
    const held = await openEditor({
      rewardBreakdown: { ok: true, data: {
        editable: false,
        reason: 'A hitman is working this. You can add to the reward, but not take from it.',
        slots: 1, currentSlot: 1,
        lines: [
          { slot: 1, portion: 'baseline', source: 'cash', amount: 5000,
            withdrawable: false }
        ]
      } }
    });

    it('says why a reward cannot be reduced, rather than showing nothing', function () {
      truthy(held.view.textContent.indexOf('A hitman is working this') !== -1,
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
      truthy(labels.indexOf('Add to it') !== -1,
        'adding is allowed while somebody works it: ' + labels.join(' | '));
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
      hitmenActive: 1, hitmenMax: 5, hitmen: [{ alias: 'Grey' }],
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
    async function onMeWith(settings, card) {
      const app = boot({
        list: board(settings),
        mine: { ok: true, data: { created: [], accepted: [], onMe: [Object.assign({
          id: 'ct00000002', target: 'You', reason: 'Unpaid debt',
          state: 'active', role: 'target', mode: 'exclusive',
          reward: { total: 5000 }, bailoutAmount: 15000, hitmen: [], hitmenActive: 1
        }, card || {})] } },
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
      }), 'the person being targeted got the same dead button: '
        + targetNoInformants.view.textContent);
    });

    const targetWithInformants = await onMeWith({});

    it('offers it on the target card where the server runs them', function () {
      truthy(targetWithInformants.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Buy informant data';
      }), 'a target buying data on who is following them is the feature');
    });

    /* W063: with nobody on the contract the purchase can only answer
       "Unknown operative", and is charged. The card already shows how many
       operatives there are, so hiding it says nothing new. */
    const nobodyOnIt = await onMeWith({}, { hitmenActive: 0 });
    it('does not offer it on a target card nobody has taken', function () {
      falsy(nobodyOnIt.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Buy informant data';
      }), nobodyOnIt.view.textContent);
    });

    /* W066: the viewer's own purchases left. Spent, the button went on
       quoting the full price; one left, nothing said it was the last. */
    const spentOut = await onMeWith({}, { informantLeft: 0 });
    it('drops the button once no purchase is left', function () {
      falsy(spentOut.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Buy informant data';
      }), spentOut.view.textContent);
    });
    const lastOne = await onMeWith({}, { informantLeft: 1 });
    click(lastOne, 'Buy informant data');
    it('says when this is the last one', function () {
      truthy(lastOne.view.textContent.indexOf('This is your last one on this contract.') !== -1,
        lastOne.view.textContent);
    });

    /* W065: a price of 0 from the panel was described as a fee. */
    const free = await onMeWith({ informant: { cost: 0, account: 'bank', maxPerContract: 2 } });
    click(free, 'Buy informant data');
    it('says a free informant is free', function () {
      const text = free.view.textContent;
      truthy(text.indexOf('It is free on this server.') !== -1, text);
      falsy(text.indexOf('It costs') !== -1, 'not a fee: ' + text);
    });

    /* W061/W143: the price quoted goes back with the purchase, and a price
       that moved since is refused, said and read again. */
    const quoted = await onMeWith({ informant: { cost: 25000, account: 'bank', maxPerContract: 2 } });
    click(quoted, 'Buy informant data');
    click(quoted, 'Yes');
    await settle(); await settle();
    const purchase = quoted.sent.filter(function (x) { return x.name === 'informant'; })[0];
    it('sends the price it quoted with the purchase', function () {
      truthy(purchase, 'a purchase was sent');
      eq(JSON.stringify(purchase.body.shown), JSON.stringify({ cost: 25000, account: 'bank' }));
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

    /* Busy with how long: a key held for seconds is the same request still
       being worked on, and "try again" at once meets it again. Under ten
       seconds it is the moment the plain words say. */
    const heldLong = await onMine({
      informant: { ok: false, err: 'busy', data: { heldMs: 12000 } }
    });
    click(heldLong, 'Buy informant data');
    click(heldLong, 'Yes');
    await settle();
    const heldShort = await onMine({
      informant: { ok: false, err: 'busy', data: { heldMs: 2000 } }
    });
    click(heldShort, 'Buy informant data');
    click(heldShort, 'Yes');
    await settle();

    it('says a long hold is still being worked on, and a short one was a moment', function () {
      eq(heldLong.notice(),
        'This is still being worked on. Look again in a minute before you try again.');
      eq(heldShort.notice(), 'That was busy for a moment. Try again.');
    });

    /* The minutes after a restart, which forgot who had been near the
       target: refused uncharged, with how long. */
    const warming = await onMine({
      informant: { ok: false, err: 'informant_warming', data: { minutes: 10 } }
    });
    click(warming, 'Buy informant data');
    click(warming, 'Yes');
    await settle();

    it('says how long until the informant sells again after a restart', function () {
      eq(warming.notice(),
        'The informant is still asking around after a restart. Try again in 10 minutes.');
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

    /* The server refuses a purchase the buyer cannot cover as
       insufficient_funds. The page had words for a code nothing sends, so
       this fell through to the Place form's "You do not have that." */
    const broke = await onMine({
      informant: { ok: false, err: 'insufficient_funds' }
    });
    click(broke, 'Buy informant data');
    click(broke, 'Yes');
    await settle();

    it('says the informant is what they cannot afford', function () {
      truthy(broke.notice().indexOf('afford the informant') !== -1, broke.notice());
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
  await (async function creatorWithNoHitmen() {
    // The server builds this list as a Lua table, and an empty Lua table
    // crosses to JS as {} rather than []. `{}` is truthy, so a guard of
    // `contract.hitmen && ...` passes and .forEach then throws. A freshly
    // placed contract is exactly this state.
    const OWN = { ok: true, data: { created: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'active',
      reward: { baseline: 5000, bonus: 0 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 0, hitmenMax: 5,
      targetName: 'Dana Reyes', role: 'creator',
      hitmen: acrossTheWire([]),
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

    /* A typed count is not bound by the field's max. 9 on a server taking
       3 drew nine payouts and sent a contract the server refuses. */
    const tooMany = await place(wallet());
    (function () {
      const field = tooMany.document.getElementById('slots-count');
      field.value = '9';
      field.onchange();
    })();
    await settle();
    it('builds no more payouts than the server takes', function () {
      const blocks = tooMany.view.all().filter(function (n) {
        return n.id && /^slot-cash-\d+$/.test(n.id);
      });
      eq(blocks.length, 3, 'drew a payout for every number typed');
      eq(tooMany.document.getElementById('slots-count').value, '3',
        'and the box has to show what is being built');
      truthy(tooMany.view.textContent.indexOf('at most 3 payouts') !== -1,
        tooMany.view.textContent.slice(0, 300));
    });

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
      hitmenActive: 0, hitmenMax: 5, targetName: 'Dana Reyes', role: 'creator',
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
    click(own, 'Add to it');
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
    const AS_HITMAN = { ok: true, data: { created: [], accepted: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'accepted',
      reward: { baseline: 5000, bonus: 2500 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 1, hitmenMax: 5,
      targetName: 'Dana Reyes', role: 'hitman',
      /* 2h05m, not exactly 2h.
       *
       * The assertion below looks for "2h" in what the page draws.
       * minutesLeft() floors (deadline - now) / 60, so at exactly 7200 a
       * single second of drift between building this fixture and reading the
       * screen gives 119 minutes, which durationText writes as "1h 59m" —
       * and the test failed, once, in a full run. A suite that fails one run
       * in ten teaches everybody to re-run it, which is how a real failure
       * gets waved through.
       *
       * Five minutes of slack puts the hours component out of reach of any
       * plausible run time. */
      deadline: Math.floor(Date.now() / 1000) + 7500
    }], onMe: [] } };

    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: AS_HITMAN, ledger: LEDGER,
      amendments: { ok: true, data: [] }
    });
    await settle(); await settle();
    app.document.querySelectorAll('.tab')
      .filter(function (t) { return t.dataset.tab === 'mine'; })[0].onclick();
    await settle(); await settle();

    click(app, 'Propose change');

    it('says what each proposal would do before one is chosen', function () {
      const text = app.view.textContent;
      // What a kill pays, with the bonus apart: added together it told a
      // hitman $7,500 for a kill that pays $5,000.
      truthy(text.indexOf('Pays $5,000 (+$2,500 if alive)') !== -1,
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
      truthy(labels.indexOf('Give back the last payout') === -1,
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
      hitmenActive: 1, hitmenMax: 5,
      targetName: 'Dana Reyes', role: 'hitman',
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
    click(multi, 'Give back the last payout');

    /* The last collection is the only one the server will take back: the
       collections are a sequence, and one out of the middle would renumber
       the rest. The page used to offer any later one in a number box, and
       the other party found out by pressing Agree. */
    it('does not ask which collection, because only the last can go', function () {
      falsy(multi.document.getElementById('dialog-value'),
        'a number box offers choices the server refuses');
      truthy(multi.view.textContent.indexOf('payout 3 of 3') !== -1,
        'the one that goes has to be named: ' + multi.view.textContent);
    });

    it('says what giving it back would do', function () {
      truthy(multi.view.textContent.indexOf('2 would remain') !== -1,
        'the consequence has to be on screen: ' + multi.view.textContent);
    });

    click(multi, 'Yes');
    await settle();

    it('sends the last slot, which is what the server reads', function () {
      const sent = multi.sent.filter(function (s) { return s.name === 'propose'; });
      eq(sent.length, 1, 'one proposal');
      eq(sent[0].body.kind, 'reduce_reward');
      eq(sent[0].body.payload.slot, 3,
        'the server takes back the last collection and no other: '
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

    // With something in it: a freetext server refuses an empty reason, and
    // the form says so before sending (W010).
    live(free, 'reason').value = 'Unpaid debt';
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

  /* What the server's settings say the Place form and the accept dialog
     should offer. Each was drawn whatever the server ran, and each was then
     refused, clamped to nothing, or charged without being shown. */
  await (async function formFollowsTheServer() {
    function wallet(caps) {
      return { ok: true, data: {
        cash: 100000, bank: 50000, dirty: 0,
        items: [], weapons: [], inventoryRead: true,
        caps: Object.assign({
          itemsEnabled: false, weaponsEnabled: false, slots: 3,
          cash: 250000, bank: 500000,
          cashEnabled: true, bankEnabled: true, dirtyEnabled: false,
          bonusPercent: 200
        }, caps || {})
      } };
    }
    async function place(settings, caps) {
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: settings || {} } },
        mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
        ledger: LEDGER,
        browseTargets: { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } },
        rewardOptions: wallet(caps)
      });
      await settle(); await settle();
      app.document.querySelectorAll('.tab')
        .filter(function (t) { return t.dataset.tab === 'place'; })[0].onclick();
      await settle(); await settle();
      return app;
    }
    function live(app, id) {
      return app.view.all().filter(function (n) { return n._id === id; })[0] || null;
    }

    const noBuyouts = await place({ buyouts: false });
    it('draws no buyout price on a server without buyouts', function () {
      falsy(live(noBuyouts, 'bailout'),
        'a price the server takes and quietly sets to nothing');
    });
    const buyouts = await place({ buyouts: true });
    it('still draws it where there are buyouts', function () {
      truthy(live(buyouts, 'bailout'));
    });

    const noBonus = await place({}, { bonusPercent: 0 });
    it('draws no bonus on a server whose bonus ceiling is nought', function () {
      falsy(live(noBonus, 'bonus'), 'offered at 50% with no ceiling at all');
    });
    it('still bounds the bonus by a ceiling above nought', function () {
      eq(String(live(buyouts, 'bonus').max), '200');
    });
    const lowCap = await place({}, { bonusPercent: 25 });
    it('opens the bonus at a ceiling under 50, not over it', function () {
      eq(String(live(lowCap, 'bonus').value), '25',
        'opened at 50 beside "(up to 25)", and the totals took 50');
    });

    const feeFree = await place({});
    const feeCharged = await place({ anonymityFees: { creator: 7500, hitman: 0 } });
    it('says what placing anonymously costs, where it costs anything', function () {
      truthy(feeCharged.view.textContent.indexOf('$7,500') !== -1,
        'charged 7,500 no screen had shown: ' + feeCharged.view.textContent);
      falsy(/costs/.test(feeFree.view.textContent.replace(/[^]*Place anonymously/, '').slice(0, 20)),
        'a free server shows no price');
    });

    /* The accept dialog, and what the page says once the server has
       answered. */
    async function accepting(settings, reply) {
      let accepted = null;
      const board = JSON.parse(JSON.stringify(BOARD));
      board.data.settings = Object.assign({}, board.data.settings, settings || {});
      const app = boot({
        list: board, mine: MINE, ledger: LEDGER,
        accept: function (body) { accepted = body; return reply; }
      });
      await settle(); await settle();
      app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Accept contract';
      })[0].onclick();
      return { app: app, sent: function () { return accepted; } };
    }

    const priced = await accepting({ anonymityFees: { creator: 0, hitman: 1000 } },
      { ok: true, data: { myAnonymous: true } });
    it('says what taking one anonymously costs before it is chosen', function () {
      truthy(priced.app.view.textContent.indexOf('$1,000') !== -1,
        'the fee was charged and never shown: ' + priced.app.view.textContent);
    });

    const named = await accepting({}, { ok: true, data: { myAnonymous: false } });
    click(named.app, 'Anonymously');
    await settle(); await settle();
    it('says so when the server took them under their name', function () {
      truthy(named.sent() && named.sent().anonymous === true, 'the choice was sent');
      falsy(named.app.notice().indexOf('anonymously') !== -1,
        'told "accepted, anonymously" while the client sees their name: ' + named.app.notice());
      truthy(named.app.notice().indexOf('under your name') !== -1, named.app.notice());
    });

    /* A contract on an officer, on a server that advises nobody. The page
       said their department had been told. */
    async function onOfficer(settings) {
      const board = JSON.parse(JSON.stringify(BOARD));
      board.data.settings = Object.assign({}, board.data.settings, settings || {});
      board.data.contracts[0].targetProtected = true;
      const app = boot({ list: board, mine: MINE, ledger: LEDGER,
        accept: { ok: true, data: {} } });
      await settle(); await settle();
      return app;
    }
    const unadvised = await onOfficer({ advisory: { posted: false, accepted: false } });
    it('does not say officers were told on a server that tells nobody', function () {
      falsy(/advised/.test(unadvised.view.textContent),
        'told the board a department had been advised: ' + unadvised.view.textContent);
    });
    unadvised.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Accept contract';
    })[0].onclick();
    it('nor warns a hitman that they have been', function () {
      truthy(/sworn officer/.test(unadvised.view.textContent), 'the officer is still flagged');
      falsy(/advised/.test(unadvised.view.textContent), unadvised.view.textContent);
    });
    /* Only the acceptance bulletin runs: nobody has been told yet. */
    const onAccept = await onOfficer({ advisory: { posted: false, accepted: true } });
    onAccept.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Accept contract';
    })[0].onclick();
    it('does not say officers were already told when only accepting tells them', function () {
      falsy(/already been advised/.test(onAccept.view.textContent), onAccept.view.textContent);
      truthy(/Accepting alerts/.test(onAccept.view.textContent),
        'and says that accepting will: ' + onAccept.view.textContent);
    });

    /* W056: only the posting bulletin runs. Whether it went for this
       contract is not something today's switch says (it may have been off
       when this one was placed), so nothing past is claimed: only what
       accepting does, which here is nothing more. */
    const onPost = await onOfficer({ advisory: { posted: true, accepted: false } });
    it('claims no past bulletin on the board', function () {
      falsy(/advised/.test(onPost.view.textContent), onPost.view.textContent);
      truthy(/sworn officer/.test(onPost.view.textContent), 'still flagged');
    });
    onPost.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Accept contract';
    })[0].onclick();
    it('nor in the hitman\'s warning', function () {
      falsy(/advised/.test(onPost.view.textContent), onPost.view.textContent);
      falsy(/Accepting alerts/.test(onPost.view.textContent), onPost.view.textContent);
      truthy(/Accept anyway\?/.test(onPost.view.textContent), onPost.view.textContent);
    });

    const advisedBoard = await onOfficer({ advisory: { posted: true, accepted: true } });
    it('says on the board what accepting it does', function () {
      truthy(/Accepting it alerts every officer in the city/.test(advisedBoard.view.textContent),
        advisedBoard.view.textContent);
      falsy(/has been advised/.test(advisedBoard.view.textContent), advisedBoard.view.textContent);
    });

    const anon = await accepting({}, { ok: true, data: { myAnonymous: true } });
    click(anon.app, 'Anonymously');
    await settle(); await settle();
    it('and that they are anonymous when they are', function () {
      truthy(anon.app.notice().indexOf('anonymously') !== -1, anon.app.notice());
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

    /* The server's boot recovery failed, and it answers nothing until staff
       restart it. That answered busy, "busy for a moment", beside a Try
       again that could never work, on every tab, On me's buyout included. */
    function offersTryAgain(app) {
      return app.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Try again';
      });
    }
    const broken = await refusedWith('recovery_failed');
    it('says the contract system failed to start, with no Try again, on every tab', function () {
      ['board', 'mine', 'onme', 'ledger'].forEach(function (name) {
        tab(broken, name);
        const shown = broken.view.textContent;
        truthy(shown.indexOf('contract system failed to start, and staff have been told') !== -1,
          name + ': ' + JSON.stringify(shown));
        falsy(shown.indexOf('busy for a moment') !== -1, name + ': ' + JSON.stringify(shown));
        falsy(offersTryAgain(broken), name + ' offers a Try again that cannot work');
      });
    });
    it('still offers Try again for a refusal a retry can clear', function () {
      tab(joining, 'board');
      truthy(offersTryAgain(joining));
    });

    const closedForm = boot({
      list: { ok: false, err: 'recovery_failed' }, mine: { ok: false, err: 'recovery_failed' },
      ledger: { ok: false, err: 'recovery_failed' },
      rewardOptions: { ok: false, err: 'recovery_failed' }
    });
    await settle(); await settle();
    tab(closedForm, 'place');
    await settle(); await settle();
    it('the Place form says so too, not that money still works, and offers no Try again', function () {
      const shown = closedForm.view.textContent;
      truthy(shown.indexOf('contract system failed to start, and staff have been told') !== -1,
        JSON.stringify(shown));
      falsy(shown.indexOf('Money still works') !== -1, JSON.stringify(shown));
      falsy(shown.indexOf('Could not read what you are carrying') !== -1, JSON.stringify(shown));
      falsy(offersTryAgain(closedForm), 'a Try again that cannot work');
    });
    drewCleanly(broken); drewCleanly(closedForm);
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

  /* The nearby list as the server answers it now: closed to a player on a
     live contract, so it cannot name the other side of it, and a distance
     given as a band. */
  await (async function nearbyAsAnswered() {
    async function nearbyPicker(answer) {
      const responses = {
        list: { ok: true, data: { page: 1, pages: 1, contracts: [],
          settings: { allowBrowseAll: false, allowNearby: true, nearbyRadius: 30 } } },
        mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
        ledger: LEDGER,
        browseTargets: answer
      };
      const app = boot(responses);
      await settle(); await settle();
      tab(app, 'place');
      await settle(); await settle();
      app.responses = responses;
      return app;
    }

    const closed = await nearbyPicker({ ok: true,
      data: { people: [], total: 0, closed: true } });
    it('says the nearby list is closed while on a contract, not that the street is empty', function () {
      const shown = closed.view.textContent;
      truthy(shown.indexOf('while you are on a contract') !== -1, shown);
      falsy(shown.indexOf('Nobody is standing near you') !== -1, shown);
    });

    // On a server with only the nearby list, closed it left a client with
    // one contract running no way to pick the target of another.
    closed.responses.searchTargets = { ok: true, data: [{ handle: 'tg00000002', name: 'Ann Ryder' }] };
    const filter = closed.document.getElementById('target-query');
    filter.value = 'Ann';
    filter.oninput();
    closed.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    await settle(); await settle();
    it('finds them by name instead', function () {
      truthy(closed.sent.some(function (x) { return x.name === 'searchTargets' && x.body.query === 'Ann'; }),
        'no name search was made');
      truthy(closed.view.textContent.indexOf('Ann Ryder') !== -1, closed.view.textContent);
    });

    const banded = await nearbyPicker({ ok: true, data: { people: [
      { handle: 'tg00000001', name: 'Ann Ryder', metres: 10 }
    ], total: 1, page: 1, pages: 1 } });
    it('gives a distance as the band it is in', function () {
      truthy(banded.view.textContent.indexOf('under 10m') !== -1, banded.view.textContent);
    });
  })();

  /* A refused target list, answering after the form was rebuilt: it was
     written into the picker that asked, no longer on screen. */
  await (async function refusedListReachesTheScreen() {
    let release;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
      ledger: LEDGER,
      browseTargets: function () {
        return new Promise(function (resolve) { release = resolve; });
      },
      rewardOptions: { ok: true, data: { cash: 1000, bank: 0, dirty: 0, items: [], weapons: [],
        inventoryRead: true, caps: { cashEnabled: true, bankEnabled: true, dirtyEnabled: true } } }
    });
    await settle(); await settle();
    tab(app, 'place');
    await settle(); await settle(); await settle();
    truthy(typeof release === 'function', 'the list was asked for');
    release({ ok: false, err: 'rate_limited' });
    await settle(); await settle();
    it('shows why the list is empty, on the picker on screen', function () {
      truthy(app.view.textContent.indexOf('Looking too fast') !== -1,
        'a blank picker with no words: ' + app.view.textContent.slice(0, 200));
    });
    it('offers a way to ask again', function () {
      const again = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Try again';
      });
      eq(again.length, 1);
    });
  })();

  /* What the Place form works out before it sends: the bonus taken on
     top, every payout against one balance, the contract's value ceiling,
     and a buyout with no clean money to price it against. Each was a
     server refusal worded as something else. */
  await (async function placeFormTotals() {
    async function place(opts) {
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
        mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
        ledger: LEDGER,
        searchTargets: { ok: true, data: [{ handle: 'tg00000001', name: 'Ann Ryder' }] },
        rewardOptions: { ok: true, data: {
          cash: opts.cash, bank: opts.bank || 0, dirty: opts.dirty || 0,
          items: [], weapons: [], inventoryRead: true,
          caps: { itemsEnabled: false, weaponsEnabled: false, slots: 5,
                  cash: 500000, bank: 500000, dirty: 500000,
                  cashEnabled: true, bankEnabled: true, dirtyEnabled: true,
                  maxLines: 60, maxValue: opts.maxValue || 1000000,
                  minValue: opts.minValue || 0 }
        } },
        create: opts.create || { ok: true, data: { id: 'ct00000001' } }
      });
      await settle(); await settle();
      tab(app, 'place');
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
      function set(id, value) {
        const field = app.view.all().filter(function (n) { return n._id === id; })[0];
        if (field) { field.value = String(value); if (field.oninput) { field.oninput(); } }
      }
      Object.keys(opts.fields).forEach(function (id) { set(id, opts.fields[id]); });
      app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Place contract';
      })[0].onclick();
      await settle(); await settle();
      return app;
    }
    function created(app) { return app.sent.filter(function (x) { return x.name === 'create'; }).length; }

    const exact = await place({ cash: 10000, fields: { 'slot-cash-1': 10000 } });
    it('counts the bonus taken on top against what the creator holds', function () {
      eq(created(exact), 0, 'sent for a refusal the page could have seen');
      truthy(exact.notice().indexOf('15,000') !== -1 && exact.notice().indexOf('bonus') !== -1,
        exact.notice());
    });

    const noBonus = await place({ cash: 10000, fields: { 'slot-cash-1': 10000, bonus: 0 } });
    it('sends it when there is no bonus on top', function () {
      eq(created(noBonus), 1, noBonus.notice());
    });

    const tooBig = await place({ cash: 2000000, bank: 2000000, maxValue: 1000000,
      fields: { 'slot-cash-1': 200000, 'slot-bank-1': 500000 } });
    it('names the value ceiling rather than calling the reward wrong', function () {
      eq(created(tooBig), 0);
      truthy(tooBig.notice().indexOf('1,050,000') !== -1
        && tooBig.notice().indexOf('1,000,000') !== -1, tooBig.notice());
    });

    const dirtyBuyout = await place({ cash: 0, dirty: 50000,
      fields: { 'slot-dirty-1': 10000, bailout: 20000, bonus: 0 } });
    it('says a buyout needs cash or bank behind it', function () {
      eq(created(dirtyBuyout), 0);
      truthy(dirtyBuyout.notice().indexOf('cash or bank') !== -1, dirtyBuyout.notice());
    });

    /* Config.Limits.MinContractReward. Two one-dollar contracts filled a
       target's slots; the server refuses one worth less, and the form says
       the figure before anything is typed and again before it sends. */
    const tooSmall = await place({ cash: 10000, minValue: 1000,
      fields: { 'slot-cash-1': 500, bonus: 0 } });
    it('names the least a contract may be worth, and does not send under it', function () {
      eq(created(tooSmall), 0, 'sent for a refusal the page could have seen');
      truthy(tooSmall.notice().indexOf('$500') !== -1
        && tooSmall.notice().indexOf('$1,000') !== -1, tooSmall.notice());
    });
    it('says the least on the form itself, where the money is set', function () {
      const hint = tooSmall.view.all().filter(function (n) {
        return n.className === 'hint' && (n.textContent || '').indexOf('at least $1,000') !== -1;
      });
      eq(hint.length, 1, 'one hint naming the minimum');
      truthy(hint[0].textContent.indexOf('Items and weapons do not count') !== -1,
        hint[0].textContent);
    });

    const withBonus = await place({ cash: 10000, minValue: 1000,
      fields: { 'slot-cash-1': 500, bonus: 100 } });
    it('counts the bonus towards it, as the server does', function () {
      eq(created(withBonus), 1, withBonus.notice());
    });

    const noMinimum = await place({ cash: 10000, fields: { 'slot-cash-1': 5, bonus: 0 } });
    it('says nothing about a minimum where there is none', function () {
      eq(created(noMinimum), 1, noMinimum.notice());
      eq(noMinimum.view.all().filter(function (n) {
        return (n.textContent || '').indexOf('at least $') !== -1 && n.className === 'hint';
      }).length, 0);
    });

    const refused = await place({ cash: 10000, fields: { 'slot-cash-1': 5, bonus: 0 },
      create: { ok: false, err: 'reward_too_small', data: { min: 2500 } } });
    it('reads the figure from the refusal when the form had none', function () {
      eq(created(refused), 1);
      truthy(refused.notice().indexOf('$2,500') !== -1, refused.notice());
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
    async function form(maxLines, payouts, fill) {
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
          if (field) { field.value = (fill && fill[source]) || '1000'; }
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

    // Twelve baselines and, at the form's opening 50% bonus, a derived
    // bonus beside each: twenty-four, which is what the server counts.
    it('says how many there are and how many are allowed', function () {
      const shown = over.notice();
      truthy(shown.indexOf('24') !== -1 && shown.indexOf('5') !== -1,
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

    // Over the per-source ceiling (500,000 here), typed rather than stepped.
    const overCap = await form(60, 1, { cash: '600000' });
    it('names the ceiling a payout is over rather than sending it', function () {
      eq(overCap.sent.filter(function (x) { return x.name === 'create'; }).length, 0,
        'sent a payout over the ceiling, for a refusal that says it does not add up');
      truthy(/at most/.test(overCap.notice()), overCap.notice());
    });

    // "1e5" on a number field read as 1, and placed a $1 reward.
    const exponent = await form(60, 1, { bank: '1e5' });
    it('does not read 1e5 as one dollar', function () {
      const sent = exponent.sent.filter(function (x) { return x.name === 'create'; });
      eq(sent.length, 1);
      eq(sent[0].body.reward.slots[0].baseline.bank, 100000,
        'placed with a reward the creator did not type');
    });

    const fraction = await form(60, 1, { bank: '1500.50' });
    it('refuses cents rather than silently dropping them', function () {
      eq(fraction.sent.filter(function (x) { return x.name === 'create'; }).length, 0);
      truthy(/whole dollars/.test(fraction.notice()), fraction.notice());
    });

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
                  reward: { total: 5000 }, hitmen: [] }],
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

    /* mulberry32. The generator this replaced was the textbook LCG taking
       `state % n`: the low bits of that sequence cycle with tiny periods, and
       1103515245 * state overflows the integers a double holds exactly, so a
       walk kept pressing the same few positions in every list. Whether it
       ever reached a given button came down to where the button sat in the
       page — reordering two elements for a redesign "lost" Propose change
       from all twenty-five walks. */
    function rng(seed) {
      let a = seed >>> 0;
      return function (n) {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return Math.floor((((t ^ (t >>> 14)) >>> 0) / 4294967296) * n);
      };
    }

    const CONTRACTS = [
      { id: 'ct00000001', target: 'Dana Reyes', reason: 'Unpaid debt',
        state: 'active', role: 'public', mode: 'competitive',
        reward: { total: 5000 }, hitmen: [], slots: 2, currentSlot: 1 },
      { id: 'ct00000002', target: 'Ann Ryder', reason: 'Snitching',
        state: 'active', role: 'public', mode: 'exclusive',
        reward: { total: 12000 }, hitmen: [], targetProtected: true },
    ];

    function server() {
      return {
        list: { ok: true, data: { page: 1, pages: 2, contracts: CONTRACTS,
          settings: { minQueryLength: 3, allowBrowseAll: true, allowNearby: true,
                      calls: true, reasonMode: 'freetext', reasonMaxLength: 140,
                      informant: { cost: 25000, account: 'bank', maxPerContract: 2 } } } },
        mine: { ok: true, data: {
          created: [Object.assign({}, CONTRACTS[0], { role: 'creator', hitmen: [] })],
          accepted: [Object.assign({}, CONTRACTS[1], { role: 'hitman' })],
          onMe: [Object.assign({}, CONTRACTS[0], { role: 'target', id: 'ct00000003',
            bailoutAmount: 15000, hitmenActive: 1 })] } },
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
   * bytes of it. That is the screen behind a live report: a hitman with a
   * restrained target who cannot work out why the handover will not start.
   *
   * Each refusal the server can give has words written for it here, and
   * until now nobody had checked that any of them appear. */
  await (async function liveDelivery() {
    const HELD = {
      id: 'ct00000001', target: 'Dana Reyes', reason: 'Unpaid debt',
      state: 'accepted', role: 'hitman', mode: 'exclusive',
      reward: { total: 5000 }, canDeliver: true, hitmen: []
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

    it('offers the handover on a contract the hitman holds', function () {
      truthy(offered.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Deliver alive';
      }), 'the button the whole flow hangs off: ' + offered.view.textContent);
    });

    /* Every refusal the server can answer with, in the hitman's words. A
       code with no sentence here reaches them as "Cannot start the
       handover", which tells somebody standing over a cuffed target
       nothing about what to change. */
    const REFUSALS = [
      ['not_coerced', 'restrained'],
      ['target_not_conscious', 'conscious'],
      ['target_too_hurt', 'too badly hurt'],
      ['creator_too_far', 'person who placed this contract must be online'],
      ['target_too_far', 'close'],
      ['target_just_on', 'come into the city'],
      ['target_protected', 'protected'],
      ['party_offline', 'online'],
      ['limit_reached', 'in progress'],
    ];

    for (const [code, words] of REFUSALS) {
      const app = await onMine({ armKidnap: { ok: false, err: code } });
      click(app, 'Deliver alive');
      await settle();
      const shown = app.notice();
      it('explains ' + code + ' in words a hitman can act on', function () {
        truthy(shown.indexOf(words) !== -1,
          'the refusal reached the hitman as ' + JSON.stringify(shown)
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
       is a hitman watching nothing happen for thirty seconds. */
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
        'the countdown drew nothing a hitman can read: ' + shown);
    });

    tick.fn(); await settle();
    tick.fn(); await settle();

    it('stops polling once the delivery is done', function () {
      // elapsed reaches 30 on the third tick, which is >= required.
      falsy(running.view.textContent.indexOf('undefined') !== -1,
        'the finished countdown rendered a hole: ' + running.view.textContent);
    });

    /* A handover already running when the page opened: the bar has to be
       followed, not drawn once from the snapshot and left frozen. */
    const reopened = await (async function () {
      const running2 = JSON.parse(JSON.stringify(HELD));
      running2.kidnapProgress = { elapsed: 5, required: 30 };
      return onMine({ mine: { ok: true, data: { created: [], accepted: [running2], onMe: [] } },
        kidnapProgress: { ok: true, data: { elapsed: 9, required: 30 } } });
    })();

    const twoRunning = await (async function () {
      const a = JSON.parse(JSON.stringify(HELD));
      a.kidnapProgress = { elapsed: 5, required: 30 };
      const b = JSON.parse(JSON.stringify(HELD));
      b.id = 'ct00000077';
      b.kidnapProgress = { elapsed: 5, required: 30 };
      const asked = [];
      const app = await onMine({ mine: { ok: true, data: { created: [], accepted: [a, b], onMe: [] } },
        kidnapProgress: function (body) { asked.push(body.id); return { ok: true, data: { elapsed: 9, required: 30 } }; } });
      const t = app.timers.filter(function (x) { return x.repeating && x.ms === 1000; });
      t.forEach(function (x) { if (!x.cleared) { x.fn(); } });
      await settle(); await settle();
      t.forEach(function (x) { if (!x.cleared) { x.fn(); } });
      await settle();
      return { app: app, asked: asked };
    })();
    it('does not let a second handover take the first one\'s poll', function () {
      const first = twoRunning.asked[0];
      eq(first, HELD.id, 'the second card took the first card\'s poll: ' + twoRunning.asked.join(','));
      truthy(twoRunning.asked.every(function (id) { return id === first; }),
        'the poll was handed from one bar to the other on each redraw: ' + twoRunning.asked.join(','));
    });

    it('follows a handover that was already running when the page opened', function () {
      truthy(reopened.timers.some(function (t) { return t.repeating && t.ms === 1000; }),
        'the bar froze at the snapshot it was drawn from');
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

    /* How it ended. The countdown disappears the moment a handover ends,
       whichever way, and every ending used to reach the poller as the same
       "no_handover" — so a hitman who had just been paid was told the
       handover ended and to try again. */
    async function endedWith(ended) {
      const page = await onMine({
        armKidnap: { ok: true, data: true },
        kidnapProgress: { ok: true, data: Object.assign({ done: true }, ended) }
      });
      click(page, 'Deliver alive');
      await settle();
      page.timers.filter(function (t) { return t.repeating && t.ms === 1000; })[0].fn();
      await settle(); await settle();
      return page;
    }

    const paidPage = await endedWith({ outcome: 'paid' });
    it('tells a hitman who was paid that they were paid', function () {
      const said = paidPage.notice();
      truthy(said.indexOf('Payment released') !== -1, said);
      falsy(/try again/i.test(said), 'told to try again after being paid: ' + said);
    });

    it('stops polling once it knows how the handover ended', function () {
      falsy(paidPage.timers.some(function (t) { return t.repeating && t.ms === 1000 && !t.cleared; }),
        'still polling a handover that is over');
    });

    const owedPage = await endedWith({ outcome: 'paid', pending: true });
    it('says so when part of the payout is being held', function () {
      truthy(owedPage.notice().indexOf('held for you') !== -1, owedPage.notice());
    });

    /* A part whose give raised and whose arrival could not be read is left
       for staff, and no retry gives it: "make room and it will be handed
       over" was untrue of it (W087). */
    const parkedPage = await endedWith({ outcome: 'paid', parked: true });
    it('says staff are checking a part left for them, not to make room', function () {
      const said = parkedPage.notice();
      truthy(said.indexOf('staff have been asked to check it') !== -1, said);
      falsy(said.indexOf('make room') !== -1, said);
    });

    const lostRace = await endedWith({ outcome: 'refused', reason: 'bad_state' });
    it('tells a hitman refused at the end that it was not paid, and why', function () {
      const said = lostRace.notice();
      truthy(said.indexOf('not paid') !== -1, said);
      truthy(said.indexOf('closed') !== -1, said);
      falsy(said.indexOf('Not right now') !== -1, 'the catch-all: ' + said);
    });

    /* A full bar is not the ending. A countdown that has run its course
       waits to be paid while another payout on the contract is settled, and
       stopping the poll there left the hitman with a full bar and no word
       of how it ended. */
    const answers = [
      { ok: true, data: { elapsed: 30, required: 30 } },
      { ok: true, data: { done: true, outcome: 'paid' } }
    ];
    const waitingPage = await onMine({
      armKidnap: { ok: true, data: true },
      kidnapProgress: function () { return answers.length > 1 ? answers.shift() : answers[0]; }
    });
    click(waitingPage, 'Deliver alive');
    await settle();
    const waitTick = waitingPage.timers.filter(function (t) { return t.repeating && t.ms === 1000; })[0];
    waitTick.fn(); await settle(); await settle();
    if (!waitTick.cleared) { waitTick.fn(); await settle(); await settle(); }
    it('reads how it ended after the bar fills', function () {
      truthy(waitingPage.notice().indexOf('Payment released') !== -1,
        'the poll stopped at a full bar: ' + waitingPage.notice());
    });

    /* Walking away mid-handover. The poller outlived the abandon, and the
       server's answer for a delivery on a contract the hitman has left is
       that there is none — which the page reads as a failed one. */
    let left = false;
    const leaving = await onMine({
      armKidnap: { ok: true, data: true },
      kidnapProgress: function () {
        return left ? { ok: false, err: 'no_handover' }
          : { ok: true, data: { elapsed: 5, required: 30 } };
      },
      abandon: function () { left = true; return { ok: true, data: true }; }
    });
    click(leaving, 'Deliver alive');
    await settle();
    const leaveTick = leaving.timers.filter(function (t) { return t.repeating && t.ms === 1000; })[0];
    leaveTick.fn(); await settle(); await settle();
    click(leaving, 'Abandon');
    click(leaving, 'Yes');
    await settle(); await settle();
    if (!leaveTick.cleared) { leaveTick.fn(); await settle(); await settle(); }
    it('stops watching a handover when the hitman walks away from the contract', function () {
      truthy(left, 'the abandon was never sent');
      truthy(leaveTick.cleared, 'still polling a handover on a contract the hitman left');
      falsy(/try again/i.test(leaving.notice()),
        'told a hitman who had walked away to get the target back: ' + leaving.notice());
    });

    /* The same, with a poll already in flight when the abandon is sent:
       its reply lands after "You are off the contract." */
    let heldPoll = null;
    let gone = false;
    const inFlight = await onMine({
      armKidnap: { ok: true, data: true },
      kidnapProgress: function () {
        return gone ? { ok: false, err: 'no_handover' }
          : { ok: true, data: { elapsed: 5, required: 30 } };
      },
      abandon: function () { gone = true; return { ok: true, data: true }; }
    });
    click(inFlight, 'Deliver alive');
    await settle();
    const flightTick = inFlight.timers.filter(function (t) { return t.repeating && t.ms === 1000; })[0];
    flightTick.fn(); await settle(); await settle();
    // The abandon goes out; a tick fires before its reply is back, so its
    // poll reaches the server after the abandon and its answer — no
    // handover — reaches the page after "You are off the contract."
    click(inFlight, 'Abandon');
    click(inFlight, 'Yes');
    flightTick.fn();
    await settle(); await settle(); await settle();
    it('ignores a poll reply that lands after the hitman walked away', function () {
      falsy(/try again/i.test(inFlight.notice()),
        'told a hitman who had just walked away to get the target back: ' + inFlight.notice());
    });
    void heldPoll;

    const tooSoon = await endedWith({ outcome: 'refused', reason: 'slot_cooldown' });
    it('names the wait between payouts when that is why', function () {
      truthy(tooSoon.notice().indexOf('very recently') !== -1, tooSoon.notice());
    });

    const clientGone = await endedWith({ outcome: 'failed', reason: 'party_offline' });
    it('does not say the target got away when somebody went offline', function () {
      const said = clientGone.notice();
      truthy(said.indexOf('offline') !== -1, said);
      falsy(said.indexOf('lost hold') !== -1, said);
    });

    /* Under the health floor and awake: "went down" contradicted what the
       hitman could see. */
    const tooHurt = await endedWith({ outcome: 'failed', reason: 'target_too_hurt' });
    it('says the target got too badly hurt, not that they went down', function () {
      const said = tooHurt.notice();
      truthy(said.indexOf('too badly hurt') !== -1, said);
      falsy(said.indexOf('went down') !== -1, said);
    });

    const closedPage = await endedWith({ outcome: 'closed' });
    it('says the contract closed when it did', function () {
      const said = closedPage.notice();
      truthy(said.indexOf('closed') !== -1, said);
      falsy(/try again/i.test(said), 'nothing to try again on: ' + said);
    });

    const cooling = await onMine({ armKidnap: { ok: false, err: 'handover_cooldown' } });
    click(cooling, 'Deliver alive');
    await settle();
    it('tells a hitman to wait out a failed handover, not "not right now"', function () {
      truthy(cooling.notice().indexOf('minute') !== -1, cooling.notice());
    });
  })();

  /* Every amendment kind, in words.
   *
   * The page turns a wire value like 'reduce_reward' into a sentence. Five
   * of those describers never ran: a player was shown whatever the last one
   * produced, or nothing, and nobody would know. */
  await (async function amendmentWords() {
    const KINDS = [
      ['reduce_reward', { slot: 2 }, 'give back payout'],
      ['shorten_deadline', { seconds: 600 }, 'deadline'],
      ['raise_penalty', { amount: 2500 }, 'raise the stake'],
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
          reward: { total: 5000 }, hitmen: [{ alias: 'Operative #4' }]
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
   * targeted player they were safe, and the suite read both as an empty
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
          'told a player nobody is after them off an unreadable reply: ' + shown);
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
    const DEADLINE = Math.floor(Date.now() / 1000) + 5430;
    STAKED.data.contracts[0].deadline = DEADLINE;

    const app = boot({ list: STAKED, mine: MINE, ledger: LEDGER });
    await settle(); await settle();

    it('says what accepting costs, on the listing', function () {
      const shown = app.view.textContent;
      truthy(shown.indexOf('$4,000') !== -1,
        'a hitman must not learn the stake from their bank balance: ' + shown);
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

    it('and how long there is before it is forfeit', function () {
      // The stake forfeits at the deadline, and nothing on the dialog said
      // when that was.
      const shown = app.view.textContent;
      truthy(shown.indexOf('It runs out in 1h 30m') !== -1,
        'the dialog that takes the stake must say when it runs out: ' + shown);
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
      eq(sent[0].body.deadline, DEADLINE,
        'and the deadline it is forfeit to, so one brought forward is refused: '
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

  /* A staked contract too close to its deadline to stake on. */
  await (async function tooLittleTimeToStake() {
    const STAKED = JSON.parse(JSON.stringify(BOARD));
    STAKED.data.contracts[0].penaltyAmount = 4000;
    STAKED.data.contracts[0].deadline = Math.floor(Date.now() / 1000) + 600;

    const app = boot({
      list: STAKED, mine: MINE, ledger: LEDGER,
      accept: { ok: false, err: 'too_little_time' }
    });
    await settle(); await settle();
    click(app, 'Accept contract');
    await settle();
    click(app, 'Under my name');
    await settle(); await settle();

    it('says the contract runs out too soon, not that something went wrong', function () {
      const said = app.notice();
      truthy(said.indexOf('runs out too soon') !== -1,
        'the refusal has to say why: ' + said);
      falsy(said.indexOf('Something went wrong') !== -1, said);
    });
  })();

  /* A contract with no room left on it. */
  await (async function aFullContract() {
    function board(active, max, mode) {
      const b = JSON.parse(JSON.stringify(BOARD));
      b.data.contracts[0].mode = mode || 'competitive';
      b.data.contracts[0].hitmenActive = active;
      b.data.contracts[0].hitmenMax = max;
      return b;
    }

    const room = boot({ list: board(2, 5), mine: MINE, ledger: LEDGER });
    await settle(); await settle();

    it('says how many operatives are on it and how many it takes', function () {
      const shown = room.view.textContent;
      truthy(shown.indexOf('2 of 5 operatives') !== -1,
        'a count with no cap beside it does not tell a hitman whether they '
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

    it('does not offer Accept on a contract that has no room', function () {
      falsy(full.view.all().some(function (b) {
        return b.tagName === 'BUTTON' && b.textContent === 'Accept contract';
      }), 'a button the server can only refuse reads as broken');
    });

    /* And if it filled between the read and the tap, the refusal is about
       the right thing. */
    const refused = boot({
      list: board(4, 5), mine: MINE, ledger: LEDGER,
      accept: { ok: false, err: 'contract_full' }
    });
    await settle(); await settle();
    click(refused, 'Accept contract');
    await settle();
    click(refused, 'Under my name');
    await settle(); await settle();

    it('does not tell a hitman holding nothing that they hold too much', function () {
      const said = refused.notice();
      falsy(said.indexOf('holding too many') !== -1,
        'that is a rule about the caller, and this one is about the contract: '
        + said);
      truthy(said.toLowerCase().indexOf('operatives') !== -1,
        'the refusal has to name what is actually full: ' + said);
    });

    it('reads the board again, so the stale card goes', function () {
      truthy(refused.sent.filter(function (m) { return m.name === 'list'; }).length >= 2,
        'the card that invited the tap is still up, inviting it again');
    });

    /* A card the viewer cannot take says why, instead of an Accept button
       the server can only refuse. */
    function cardAs(over) {
      const b = JSON.parse(JSON.stringify(BOARD));
      Object.assign(b.data.contracts[0], over);
      return b;
    }
    async function boardWith(over) {
      const app = boot({ list: cardAs(over), mine: MINE, ledger: LEDGER });
      await settle(); await settle();
      return app;
    }
    function offersAccept(app) {
      return app.view.all().some(function (b) {
        return b.tagName === 'BUTTON' && b.textContent === 'Accept contract';
      });
    }

    const ownCard = await boardWith({ role: 'creator' });
    it('does not offer a creator their own contract', function () {
      falsy(offersAccept(ownCard));
      truthy(ownCard.view.textContent.indexOf('Yours') !== -1, ownCard.view.textContent);
    });

    const heldCard = await boardWith({ role: 'hitman' });
    it('does not offer a hitman a contract they already hold', function () {
      falsy(offersAccept(heldCard));
      truthy(heldCard.view.textContent.indexOf('already on this one') !== -1,
        heldCard.view.textContent);
    });

    const takenCard = await boardWith({ mode: 'exclusive', hitmenActive: 1, hitmenMax: 5 });
    it('says an exclusive contract somebody holds is taken', function () {
      falsy(offersAccept(takenCard));
      truthy(takenCard.view.textContent.indexOf('Taken') !== -1, takenCard.view.textContent);
    });

    const openCard = await boardWith({ role: 'public', mode: 'exclusive', hitmenActive: 0 });
    it('still offers Accept on a contract that can be taken', function () {
      truthy(offersAccept(openCard), 'the fix closed the door it was meant to label');
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

  /* A server with buyouts switched off is not the client's doing. */
  await (async function buyoutsSwitchedOff() {
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [],
        settings: { buyouts: false } } },
      mine: { ok: true, data: { created: [], accepted: [], onMe: [{
        id: 'ct00000009', targetName: 'You', reason: 'Unpaid debt',
        mode: 'competitive', state: 'active', reward: { baseline: 9000 },
        slots: 1, slotsClaimed: 0, currentSlot: 1, role: 'target',
        bailoutAmount: 15000, bailoutAvailable: false, penaltyAmount: 0
      }] } }
    });
    await settle(); await settle();
    tab(app, 'onme');
    await settle(); await settle();
    it('says the server offers none, rather than that the client did not', function () {
      const shown = app.view.textContent;
      truthy(shown.indexOf('does not offer buyouts') !== -1, shown);
      falsy(shown.indexOf('No buyout was offered') !== -1, shown);
    });
  })();

  /* Each way a buyout is refused, in words a target can act on. */
  await (async function refusedBuyouts() {
    const ON_ME = { ok: true, data: { created: [], accepted: [], onMe: [{
      id: 'ct00000009', targetName: 'You', reason: 'Unpaid debt',
      mode: 'competitive', state: 'active', reward: { baseline: 9000 },
      slots: 1, slotsClaimed: 0, currentSlot: 1, role: 'target',
      bailoutAmount: 15000, bailoutAvailable: true, penaltyAmount: 0
    }] } };

    const CASES = [
      ['bailout_off',          'does not offer',  'this server never will'],
      ['no_buyout_price',      'nothing to pay',  'the client set no price'],
      ['buyout_pending',       'already paid',    'it is working, not failing'],
      ['incapacitated',        'floor',           'they have to get up'],
      ['handover_in_progress', 'hold of you',     'they are already taken'],
    ];

    for (const [code, words, why] of CASES) {
      const app = boot({
        list: BOARD, ledger: LEDGER, mine: ON_ME,
        bailout: { ok: false, err: code }
      });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();

      click(app, 'Buy out — $15,000');
      await settle();
      click(app, 'Pay $15,000');
      await settle(); await settle();

      const said = app.notice();
      it('says why a buyout was refused: ' + code, function () {
        falsy(said.indexOf('Not right now') !== -1,
          '"Not right now" is the shared answer this replaced — ' + why
          + ': ' + said);
        truthy(said.toLowerCase().indexOf(words) !== -1,
          'the words a target can act on are missing: ' + said);
      });
    }
  })();

  /* Two figures the server has always sent and the page never read. */
  await (async function figuresAlreadySent() {
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {
        minQueryLength: 3, allowBrowseAll: true, allowNearby: true,
        nearbyRadius: 30.0
      } } },
      mine: MINE, ledger: LEDGER
    });
    await settle(); await settle();
    tab(app, 'place');
    await settle(); await settle();

    it('says how near "near me" actually is', function () {
      const shown = app.view.textContent;
      truthy(shown.indexOf('30m') !== -1,
        '"Near me" is not a distance: a player whose target is one metre too '
        + 'far sees an empty list and no reason. ' + shown);
    });

    /* And how many times an informant can be asked about one contract. */
    const OWN = { ok: true, data: { created: [{
      id: 'ct00000001', targetName: 'Dana Reyes', reason: 'Unpaid debt',
      mode: 'competitive', state: 'accepted', role: 'creator',
      reward: { baseline: 5000 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 1, hitmenMax: 5, penaltyAmount: 0,
      // Anonymous: the only operative a client's informant can name.
      hitmen: acrossTheWire([{ alias: 'Operative #1', claims: 0,
        record: { standing: 'Unproven' } }])
    }], accepted: [], onMe: [] } };

    const priced = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {
        minQueryLength: 3,
        informant: { cost: 25000, account: 'bank', maxPerContract: 3 }
      } } },
      mine: OWN, ledger: LEDGER
    });
    await settle(); await settle();
    tab(priced, 'mine');
    await settle(); await settle();
    click(priced, 'Buy informant data');
    await settle();

    /* Every operative on the card already named: the client's purchase
       can only draw an anonymous one, so it bought a certain "nobody". */
    const allNamed = JSON.parse(JSON.stringify(OWN));
    allNamed.data.created[0].hitmen = [{ alias: 'Operative #1', name: 'Rook Ash',
      claims: 0, record: { standing: 'Unproven' } }];
    const namedCard = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {
        minQueryLength: 3,
        informant: { cost: 25000, account: 'bank', maxPerContract: 3 }
      } } },
      mine: allNamed, ledger: LEDGER
    });
    await settle(); await settle();
    tab(namedCard, 'mine');
    await settle(); await settle();
    it('does not sell the client an informant when every operative is named', function () {
      falsy(namedCard.view.all().some(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Buy informant data';
      }), 'a purchase that can only answer "nobody", never refunded');
    });

    it('says how many times one contract can be asked', function () {
      const shown = priced.view.textContent;
      truthy(shown.indexOf('3 times') !== -1,
        'without the cap a player finds out they were on their last one by '
        + 'spending it: ' + shown);
    });
  })();

  /* ---------- the verification photo ----------
   *
   * The one flow that goes out of the app, into lb-phone's camera and back.
   * Every step of it used to be silent. */
  await (async function verificationPhoto() {
    /* A contract this player is working, shaped the way the projection
       sends one: accepted, role hitman, on the Mine tab. */
    function mineWithAJob() {
      return { ok: true, data: { created: [], accepted: [{
        id: 'ct00000001', reason: 'Unpaid debt', mode: 'exclusive',
        state: 'accepted', reward: { baseline: 5000 },
        slots: 1, slotsClaimed: 0, currentSlot: 1,
        hitmenActive: 1, hitmenMax: 1,
        targetName: 'Dana Reyes', role: 'hitman',
        deadline: Math.floor(Date.now() / 1000) + 7200
      }], onMe: [] } };
    }

    await (async function busyWhileTheCameraIsOpen() {
      // A camera the player is still composing a shot in: the reply has not
      // arrived, and will not until they press the shutter.
      let answer;
      const held = new Promise(function (resolve) { answer = resolve; });
      const app = boot({
        mine: mineWithAJob(),
        takeVerificationPhoto: function () { return held; }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();

      click(app, 'Verify kill');
      await settle();

      const labels = app.view.all()
        .filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });

      it('says it is verifying rather than looking untouched', function () {
        truthy(labels.some(function (l) { return l.indexOf('Verifying') !== -1; }),
          'the screen did not change at all for the whole round trip: '
          + labels.join(' | '));
      });

      it('will not mint a second token while the first photo is in flight', function () {
        const before = app.sent.filter(function (x) {
          return x.name === 'takeVerificationPhoto';
        }).length;
        // The button is disabled, so a player tapping it again does nothing.
        const button = app.view.all().filter(function (n) {
          return n.tagName === 'BUTTON' && n.textContent.indexOf('Verifying') !== -1;
        })[0];
        truthy(button.disabled, 'the button stayed live through the upload');
        const after = app.sent.filter(function (x) {
          return x.name === 'takeVerificationPhoto';
        }).length;
        eq(after, before, 'a second token invalidates the photo already sent');
      });

      answer({ ok: true, data: { settled: 2, pending: 0 } });
      await settle(); await settle();

      it('gives the button back once the answer lands', function () {
        const again = app.view.all()
          .filter(function (n) { return n.tagName === 'BUTTON'; })
          .map(function (n) { return n.textContent; });
        falsy(again.some(function (l) { return l.indexOf('Verifying') !== -1; }),
          'a button left disabled is worse than one that could be tapped twice');
      });
    })();

    await (async function tellsTheTruthAboutAQueuedPayout() {
      const app = boot({
        mine: mineWithAJob(),
        // Verified, but the hitman's pockets were full: the server queued
        // part of the reward instead of handing it over.
        takeVerificationPhoto: { ok: true, data: { settled: 1, pending: 2 } }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Verify kill');
      await settle(); await settle();

      it('does not claim a payment that is still being held', function () {
        const said = app.notice();
        falsy(said.indexOf('Payment released') !== -1,
          'the hitman stood there with nothing and no reason to think '
          + 'anything was owed: ' + said);
        truthy(said.indexOf('held for you') !== -1, said);
      });
    })();

    await (async function saysWhatWentWrongWithTheCamera() {
      for (const each of [
        { err: 'camera_unavailable', expect: 'cannot open the camera' },
        // Said a full proof window after the camera opened, by which time
        // the server's claim on the kill has always run out: a "try again"
        // here sends the hitman straight into "No kill ... waiting for proof".
        { err: 'camera_no_answer', expect: 'never came back',
          forbid: ['try again', 'still yours'] }
      ]) {
        const app = boot({
          mine: mineWithAJob(),
          takeVerificationPhoto: { ok: false, err: each.err }
        });
        await settle(); await settle();
        tab(app, 'mine');
        await settle();
        click(app, 'Verify kill');
        await settle(); await settle();

        const said = app.notice();
        it('puts ' + each.err + ' into words a hitman can act on', function () {
          truthy(said.indexOf(each.expect) !== -1,
            'answered "' + said + '" — a hitman with a confirmed kill and a '
            + 'live contract needs to know which of the two happened');
          falsy(said.indexOf('Something went wrong') !== -1, said);
          (each.forbid || []).forEach(function (words) {
            falsy(said.toLowerCase().indexOf(words) !== -1,
              'promised "' + words + '" when there is nothing left to try: ' + said);
          });
        });
      }
    })();

    /* ---------- with kill photos off (Config.Completion.KillPhotos) ----------
       The server checks the scene itself: no camera, no viewfinder, no
       photo step, and nothing the hitman reads says to photograph anything. */
    function boardWithoutPhotos(extra) {
      return { ok: true, data: { page: 1, pages: 1, contracts: [],
        settings: Object.assign({ killPhotos: false, fulfilment: 'either',
          kidnap: { radius: 12, seconds: 30 } }, extra || {}) } };
    }
    const NEW_HITMAN = { ok: true, data: { entries: [], kept: [], record: { completed: 0 } } };
    const CAMERA = ['takeVerificationPhoto', 'sendVerificationPhoto', 'verificationCamera'];

    await (async function verifiedAtTheScene() {
      const app = boot({
        list: boardWithoutPhotos(), mine: mineWithAJob(), ledger: NEW_HITMAN,
        verifyKill: { ok: true, data: { settled: 1, pending: 0 } }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      const howTo = app.view.textContent;
      click(app, 'Verify kill');
      await settle(); await settle();

      it('verifies a kill at the scene with no camera, viewfinder or photo step', function () {
        const asked = app.sent.filter(function (x) { return x.name === 'verifyKill'; });
        eq(asked.length, 1, 'the server is asked to check the scene');
        eq(asked[0].body.id, 'ct00000001');
        CAMERA.forEach(function (name) {
          falsy(app.sent.some(function (x) { return x.name === name; }), name + ' was never asked for');
        });
        falsy(app.view.all().some(function (n) { return n.tagName === 'CANVAS'; }), 'no viewfinder drawn');
        truthy(app.notice().indexOf('Verified. Payment released.') !== -1, app.notice());
      });

      it('tells a new hitman to tap Verify kill at the body, not to photograph it', function () {
        truthy(howTo.indexOf('tap Verify kill before they are revived') !== -1, howTo);
        falsy(howTo.toLowerCase().indexOf('photo') !== -1, howTo);
      });
    })();

    await (async function refusalsSayNothingOfAPhoto() {
      for (const err of ['no_kill_to_verify', 'photo_too_far', 'photo_revived',
                         'photo_still_down', 'rate_limited']) {
        const app = boot({
          list: boardWithoutPhotos(), mine: mineWithAJob(), ledger: NEW_HITMAN,
          verifyKill: { ok: false, err: err }
        });
        await settle(); await settle();
        tab(app, 'mine');
        await settle();
        click(app, 'Verify kill');
        await settle(); await settle();
        const said = app.notice();
        it('words ' + err + ' for a kill checked at the scene', function () {
          truthy(said.length > 0, 'something is said');
          falsy(said.toLowerCase().indexOf('photo') !== -1, 'no photo where none is taken: ' + said);
          falsy(app.view.textContent.toLowerCase().indexOf('photograph') !== -1,
            'nor on the card: ' + app.view.textContent);
        });
      }
    })();

    await (async function followsTheServerWhenItSwitched() {
      // The page read "off", the server has turned photos on since.
      const turnedOn = boot({
        list: boardWithoutPhotos(), mine: mineWithAJob(), ledger: NEW_HITMAN,
        verifyKill: { ok: false, err: 'photo_required' },
        takeVerificationPhoto: { ok: true, data: { settled: 1, pending: 0 } }
      });
      await settle(); await settle();
      tab(turnedOn, 'mine');
      await settle();
      click(turnedOn, 'Verify kill');
      await settle(); await settle(); await settle();

      // The page read "on", the server has turned them off since: the
      // camera is refused unread, and the scene is checked instead.
      const turnedOff = boot({
        list: boardWithoutPhotos({ killPhotos: true }), mine: mineWithAJob(), ledger: NEW_HITMAN,
        takeVerificationPhoto: { ok: false, err: 'photo_gone' },
        verifyKill: { ok: true, data: { settled: 1, pending: 0 } }
      });
      await settle(); await settle();
      tab(turnedOff, 'mine');
      await settle();
      click(turnedOff, 'Verify kill');
      await settle(); await settle(); await settle();

      it('opens the camera after all where the server asks for a photo', function () {
        truthy(turnedOn.sent.some(function (x) { return x.name === 'takeVerificationPhoto'; }));
        truthy(turnedOn.notice().indexOf('Verified') !== -1, turnedOn.notice());
      });
      it('checks the scene where the server has stopped taking photos', function () {
        truthy(turnedOff.sent.some(function (x) { return x.name === 'verifyKill'; }));
        truthy(turnedOff.notice().indexOf('Verified') !== -1, turnedOff.notice());
        falsy(turnedOff.notice().indexOf('That photo is gone') !== -1, turnedOff.notice());
      });
    })();

    /* ---------- the viewfinder, on a server that keeps its photos ----------

       There the client answers Verify kill with the viewfinder to open, and
       the page takes the photo itself, in lb-phone's game render. */

    /* lb-phone's components as the viewfinder uses them, and what a
       browser gives it to shrink the photo with. Records what was asked of
       each, so a test can see the camera let go of. */
    function withGameCamera(app, opts) {
      opts = opts || {};
      const camera = { created: [], resized: [], destroyed: 0, taken: 0, encodes: [] };
      if (opts.noGameRender) {
        app.sandbox.window.components = {};
        return camera;
      }
      app.sandbox.window.components = {
        createGameRender: function (canvas) {
          const render = {
            destroyed: false,
            resizeByAspect: function (ratio) { camera.resized.push(ratio); },
            takePhoto: function () {
              camera.taken++;
              // A phone camera's full-size portrait frame, as a Blob.
              return Promise.resolve({ type: 'image/png', size: 9000000,
                width: 2160, height: 3840 });
            },
            destroy: function () { render.destroyed = true; camera.destroyed++; }
          };
          camera.created.push(canvas);
          camera.render = render;
          return render;
        }
      };
      app.sandbox.window.createImageBitmap = function (blob) {
        return Promise.resolve({ width: blob.width, height: blob.height,
          close: function () { camera.closed = true; } });
      };
      app.sandbox.window.FileReader = function () {
        const reader = this;
        reader.readAsDataURL = function (blob) {
          camera.encoded = blob;
          Promise.resolve().then(function () {
            reader.result = 'data:' + blob.type + ';base64,UklGRgAAAABXRUJQ';
            reader.onload();
          });
        };
      };
      app.document.encode = function (canvas, type, quality) {
        camera.encodes.push({ type: type, quality: quality,
          width: canvas.width, height: canvas.height });
        if (opts.encode) { return opts.encode(type, quality); }
        return { type: type, size: 180000 };
      };
      return camera;
    }

    function finder(app) { return app.document.getElementById('viewfinder'); }

    function pressIn(node, label) {
      const match = node.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === label;
      });
      if (!match.length) { throw new Error('no button labelled "' + label + '" in the viewfinder'); }
      match[0].onclick();
    }

    function camerasAsked(app) {
      return app.sent.filter(function (r) { return r.name === 'verificationCamera'; })
        .map(function (r) { return r.body.on; });
    }

    async function viewfinderOpen(extra, cameraOpts) {
      const app = boot(Object.assign({
        mine: mineWithAJob(),
        takeVerificationPhoto: { ok: true,
          data: { viewfinder: true, maxSide: 1280, maxBytes: 600000 } },
        sendVerificationPhoto: { ok: true, data: { settled: 1, pending: 0 } }
      }, extra || {}));
      const camera = withGameCamera(app, cameraOpts);
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Verify kill');
      await settle(); await settle();
      return { app: app, camera: camera };
    }

    async function shoot(app) {
      pressIn(finder(app), 'Take photo');
      for (let i = 0; i < 8; i++) { await settle(); }
    }

    await (async function viewfinderTakesThePhoto() {
      const { app, camera } = await viewfinderOpen();

      it('opens the app\'s own viewfinder over everything, with the game camera in it', function () {
        const shade = finder(app);
        truthy(shade, 'no viewfinder on screen');
        truthy(shade.parentNode === app.document.body,
          'drawn outside #view, which redraws and would take the camera\'s canvas with it');
        truthy(shade.textContent.indexOf('Point the phone at the body and take the photo.') !== -1,
          shade.textContent);
        eq(camera.created.length, 1, 'one game render');
        eq(camera.created[0].tagName, 'CANVAS');
        truthy(shade.all().indexOf(camera.created[0]) !== -1, 'drawn into the viewfinder\'s canvas');
        eq(camera.resized.length, 1, 'sized to the frame, as lb-phone\'s template does');
        eq(camerasAsked(app).join(','), 'true', 'the camera behind the app is turned on');
        falsy(app.sent.some(function (r) { return r.name === 'sendVerificationPhoto'; }));
        const labels = shade.all().filter(function (n) { return n.tagName === 'BUTTON'; })
          .map(function (n) { return n.textContent; });
        eq(labels.join(','), 'Take photo,Cancel', 'a shutter and a way out; no selfie camera');
      });

      await shoot(app);

      it('sends the picture, shrunk, and nothing else', function () {
        const sends = app.sent.filter(function (r) { return r.name === 'sendVerificationPhoto'; });
        eq(sends.length, 1);
        eq(Object.keys(sends[0].body).sort().join(','), 'id,image',
          'the page has no token to send: the client holds it');
        eq(sends[0].body.id, 'ct00000001');
        eq(sends[0].body.image.indexOf('data:image/webp;base64,'), 0, sends[0].body.image);
        eq(camera.taken, 1);
        const made = camera.encodes[camera.encodes.length - 1];
        eq(made.type, 'image/webp');
        eq(made.quality, 0.8);
        eq(Math.max(made.width, made.height), 1280, 'the longest side brought down to the limit');
        eq(made.width, 720, 'in proportion');
      });

      it('lets go of the camera and the picture once it is taken', function () {
        eq(camera.destroyed, 1, 'the game render destroyed');
        eq(camerasAsked(app).join(','), 'true,false', 'and the camera behind the app turned off');
        eq(camera.created[0].width, 0, 'its canvas emptied');
        truthy(camera.closed, 'the decoded picture closed');
        eq(finder(app), null, 'the viewfinder is gone');
      });

      it('says the kill is verified', function () {
        truthy(app.notice().indexOf('Verified') !== -1, app.notice());
        drewCleanly(app, 'the viewfinder');
      });
    })();

    /* Staff turned kill photos off while the viewfinder was open. The server
       refuses the picture unread, as a photo nobody has (photo_gone), and
       the same tap checks the scene instead, as a page that had read "off"
       would have from the start (server_photos_spec holds the server to the
       token not spent and the kill still the hitman's). */
    await (async function viewfinderAfterPhotosWentOff() {
      const { app } = await viewfinderOpen({
        sendVerificationPhoto: { ok: false, err: 'photo_gone' },
        verifyKill: { ok: true, data: { settled: 1, pending: 0 } }
      });
      await shoot(app);
      for (let i = 0; i < 4; i++) { await settle(); }

      it('checks the scene when the picture is refused because photos went off', function () {
        const WATCHED = ['takeVerificationPhoto', 'verificationCamera', 'sendVerificationPhoto', 'verifyKill'];
        const asked = app.sent.filter(function (r) { return WATCHED.indexOf(r.name) !== -1; })
          .map(function (r) { return r.name === 'verificationCamera' ? r.name + ':' + r.body.on : r.name; });
        eq(asked.join(','), 'takeVerificationPhoto,verificationCamera:true,verificationCamera:false,'
          + 'sendVerificationPhoto,verifyKill');
        truthy(app.notice().indexOf('Verified') !== -1, app.notice());
        falsy(app.notice().indexOf('That photo is gone') !== -1, app.notice());
        eq(finder(app), null, 'the viewfinder is gone');
      });
    })();

    /* The shutter waits for the client to say the rear camera is on. Until
       then the render shows the ordinary game camera, with the hitman in
       it, and a quick tap sent the client that. */
    await (async function viewfinderWaitsForTheCamera() {
      let cameraOn = null;
      const { app, camera } = await viewfinderOpen({
        verificationCamera: function (body) {
          if (body.on) { return new Promise(function (resolve) { cameraOn = resolve; }); }
          return { ok: true };
        }
      });
      function shutterOf() {
        return finder(app).all().filter(function (n) {
          return n.tagName === 'BUTTON' && n.textContent === 'Take photo';
        })[0];
      }
      it('keeps the shutter off until the rear camera is confirmed on', function () {
        truthy(typeof cameraOn === 'function', 'the camera was asked for');
        truthy(shutterOf().disabled, 'a tap now would photograph the game camera, hitman and all');
      });
      pressIn(finder(app), 'Take photo');
      for (let i = 0; i < 4; i++) { await settle(); }
      it('and a press meanwhile takes nothing', function () {
        eq(camera.taken, 0);
        falsy(app.sent.some(function (r) { return r.name === 'sendVerificationPhoto'; }));
      });
      cameraOn({ ok: true });
      await settle(); await settle();
      it('lets it be pressed once the camera is on, and then takes the photo', function () {
        falsy(shutterOf().disabled, 'the camera is on');
      });
      await shoot(app);
      it('sends the photo taken then', function () {
        eq(camera.taken, 1);
        eq(app.sent.filter(function (r) { return r.name === 'sendVerificationPhoto'; }).length, 1);
      });
    })();

    await (async function viewfinderCancelled() {
      const { app, camera } = await viewfinderOpen();
      pressIn(finder(app), 'Cancel');
      await settle(); await settle();

      it('closes on Cancel, turns the camera off and sends nothing', function () {
        eq(finder(app), null);
        eq(camera.destroyed, 1);
        eq(camerasAsked(app).join(','), 'true,false');
        falsy(app.sent.some(function (r) { return r.name === 'sendVerificationPhoto'; }));
        eq(app.notice(), '', 'backing out is the hitman\'s own choice and says nothing');
        truthy(app.view.all().some(function (n) {
          return n.tagName === 'BUTTON' && n.textContent === 'Verify kill';
        }), 'and Verify kill is there to tap again');
      });
    })();

    await (async function viewfinderWithoutWebp() {
      // A browser that cannot make webp hands back a PNG instead.
      const { app, camera } = await viewfinderOpen({}, {
        encode: function (type) { return { type: type === 'image/webp' ? 'image/png' : type, size: 200000 }; }
      });
      await shoot(app);
      it('sends a jpeg where the browser makes no webp', function () {
        eq(camera.encodes.map(function (e) { return e.type; }).join(','), 'image/webp,image/jpeg');
        const sends = app.sent.filter(function (r) { return r.name === 'sendVerificationPhoto'; });
        eq(sends.length, 1);
        eq(sends[0].body.image.indexOf('data:image/jpeg;base64,'), 0);
      });
    })();

    await (async function viewfinderShrinksToFit() {
      // Over the limit at the first two qualities, under it at the third.
      const { app, camera } = await viewfinderOpen({}, {
        encode: function (type, quality) { return { type: type, size: quality > 0.6 ? 700000 : 400000 }; }
      });
      await shoot(app);
      it('lowers the quality until the photo is no bigger than the server keeps', function () {
        eq(camera.encodes.map(function (e) { return e.quality; }).join(','), '0.8,0.65,0.5');
        eq(app.sent.filter(function (r) { return r.name === 'sendVerificationPhoto'; }).length, 1);
      });
    })();

    await (async function viewfinderTooBig() {
      const { app, camera } = await viewfinderOpen({}, {
        encode: function (type) { return { type: type, size: 5000000 }; }
      });
      await shoot(app);
      it('says a photo that will not shrink enough was not sent', function () {
        falsy(app.sent.some(function (r) { return r.name === 'sendVerificationPhoto'; }));
        truthy(app.notice().indexOf('too big') !== -1, app.notice());
        eq(camera.destroyed, 1);
        eq(finder(app), null);
      });
    })();

    await (async function viewfinderRefused() {
      const { app } = await viewfinderOpen({
        sendVerificationPhoto: { ok: false, err: 'photo_too_far' }
      });
      await shoot(app);
      it('says why the server refused the photo, and keeps it on the card', function () {
        truthy(app.notice().indexOf('too far') !== -1, app.notice());
        truthy(app.view.textContent.indexOf('too far') !== -1, 'kept under the buttons: '
          + app.view.textContent);
        eq(finder(app), null);
      });
    })();

    await (async function viewfinderWithoutGameRender() {
      const { app } = await viewfinderOpen({}, { noGameRender: true });
      it('says the phone cannot open the camera where lb-phone has no game render', function () {
        eq(finder(app), null, 'no viewfinder with nothing to show in it');
        truthy(app.notice().indexOf('cannot open the camera') !== -1, app.notice());
        eq(camerasAsked(app).length, 0);
      });
    })();
  })();

  /* ---------- a dialog under a background reply ---------- */
  await (async function dialogsKeepWhatWasTyped() {
    const app = boot({
      mine: { ok: true, data: { created: [{
        id: 'ct00000001', reason: 'Unpaid debt', mode: 'exclusive',
        state: 'active', reward: { baseline: 5000 },
        slots: 1, slotsClaimed: 0, currentSlot: 1,
        hitmenActive: 0, hitmenMax: 1, hitmen: [],
        targetName: 'Dana Reyes', role: 'creator',
        deadline: Math.floor(Date.now() / 1000) + 7200
      }], accepted: [], onMe: [] } },
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {
        minQueryLength: 3, allowBrowseAll: true, reasonMode: 'freetext',
        reasonMaxLength: 140 } } }
    });
    await settle(); await settle();
    tab(app, 'mine');
    await settle();

    click(app, 'Edit');
    await settle();

    const input = app.view.all().filter(function (n) {
      return n.tagName === 'INPUT' && String(n.id).indexOf('dialog-') === 0;
    })[0];

    it('opens a dialog with a field to type into', function () {
      truthy(input, 'nothing to measure otherwise');
    });

    // The player types.
    input.value = 'He took the car as well';
    if (input.oninput) { input.oninput(); }

    // And something lands: a push, a late reply, a headshot. Any of these
    // redraw the page, and the dialog is part of the page.
    app.sandbox.window._message({ data: { type: 'push', reason: 'accepted' } });
    const due = app.timers.filter(function (t) { return t.ms === 250; });
    due.forEach(function (t) { t.fn(); });
    await settle(); await settle();

    it('still holds what the player typed after a reply lands', function () {
      const again = app.view.all().filter(function (n) {
        return n.tagName === 'INPUT' && String(n.id).indexOf('dialog-') === 0;
      })[0];
      truthy(again, 'the dialog closed under them, which is its own fault');
      eq(again.value, 'He took the car as well',
        'their answer was silently replaced with the default and the dialog '
        + 'looked untouched, so the natural thing to do is press Save on a '
        + 'value they did not choose');
    });
  })();

  /* ---------- a handover that ends ---------- */
  await (async function handoverThatEnds() {
    const job = { ok: true, data: { created: [], accepted: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'exclusive',
      state: 'accepted', reward: { baseline: 5000 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 1, hitmenMax: 1,
      targetName: 'Dana Reyes', role: 'hitman',
      deadline: Math.floor(Date.now() / 1000) + 7200
    }], onMe: [] } };

    let progress = { ok: true, data: { elapsed: 4, required: 30 } };
    const app = boot({
      mine: job,
      armKidnap: { ok: true, data: { armed: true } },
      kidnapProgress: function () { return progress; }
    });
    await settle(); await settle();
    tab(app, 'mine');
    await settle();

    click(app, 'Deliver alive');
    await settle(); await settle();

    const ticker = app.timers.filter(function (t) { return t.repeating && t.ms === 1000; })[0];
    it('starts a countdown to watch', function () {
      truthy(ticker, 'nothing is polling, so this measures nothing');
    });

    ticker.fn();
    await settle();
    function bars() {
      return app.view.all().filter(function (n) {
        return n._className && n._className.split(' ').indexOf('countdown') !== -1;
      });
    }

    it('shows the countdown while it is running', function () {
      truthy(bars().length >= 1,
        'nothing is drawing a countdown, so the assertion below that it goes '
        + 'away would pass against a page that never showed one: '
        + app.view.textContent.slice(0, 120));
      truthy(app.view.textContent.indexOf('4s of 30s') !== -1,
        'and it should say where it has got to: '
        + app.view.textContent.slice(0, 120));
    });

    // The target breaks loose. The server stops knowing about the handover,
    // which is an unsuccessful reply — the same shape as a dropped packet.
    progress = { ok: false, err: 'bad_state' };
    ticker.fn();
    await settle(); await settle();

    it('says the handover ended rather than freezing the bar', function () {
      const said = app.notice();
      truthy(said.indexOf('handover ended') !== -1,
        'a delivery that simply stops moving is the one thing a hitman '
        + 'holding a target cannot interpret: "' + said + '"');
    });
    it('takes the dead countdown off the screen', function () {
      eq(bars().length, 0, 'the bar froze at its last value and stayed there');
    });
  })();

  /* ---------- buttons that answer a tap ---------- */
  await (async function everyActionAnswersATap() {
    const own = {
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive',
      state: 'active', reward: { baseline: 5000 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 1, hitmenMax: 5, hitmen: [{ alias: 'Grey' }],
      targetName: 'Dana Reyes', role: 'creator',
      /* 90m30s, not exactly 90m — the same trap as the fixture above.
       *
       * The assertion looks for "1h 30m". minutesLeft() floors the
       * remainder, so at exactly 5400 one second of drift between building
       * this and reading the screen gives 89 minutes and "1h 29m". I wrote
       * this test today and it carried the flake it was written beside. */
      deadline: Math.floor(Date.now() / 1000) + 5430
    };

    await (async function extendSaysWhereTheDeadlineStands() {
      const app = boot({ mine: { ok: true, data: { created: [own], accepted: [], onMe: [] } } });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Extend deadline');
      await settle();

      it('says how long is left before asking how much to add', function () {
        const shown = app.view.textContent;
        truthy(shown.indexOf('1h 30m') !== -1,
          'a creator deciding how much to add has to know what they are '
          + 'adding to, and the app already knew: ' + shown.slice(0, 200));
      });
    })();

    /* The dialog opened on an empty box with no ceiling and no hint, so
       Confirm — the obvious first tap — did nothing and said nothing. */
    await (async function extendOpensAnswerable() {
      const list = JSON.parse(JSON.stringify(BOARD));
      list.data.settings.deadlineMaxMinutes = 120;
      const app = boot({ list: list,
        mine: { ok: true, data: { created: [own], accepted: [], onMe: [] } },
        improve: { ok: true, data: true } });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Extend deadline');
      await settle();
      const box = app.document.getElementById('dialog-value');

      it('opens on a figure Confirm will take', function () {
        truthy(box && Number(box.value) > 0, 'an empty box: "' + (box && box.value) + '"');
      });

      it('holds the figure to what the server takes', function () {
        eq(String(box.max), '120');
      });

      it('says what the deadline would become', function () {
        truthy(app.view.textContent.indexOf('would then run out in') !== -1,
          app.view.textContent);
      });

      box.value = '';
      click(app, 'Extend');
      await settle();
      it('says why when Confirm will not take what is in the box', function () {
        truthy(app.view.textContent.indexOf('between 1 and 120') !== -1,
          'the tap did nothing and said nothing: ' + app.view.textContent);
        eq(app.sent.filter(function (m) { return m.name === 'improve'; }).length, 0);
      });

      box.value = '30';
      click(app, 'Extend');
      await settle(); await settle();
      it('sends the minutes as seconds', function () {
        const sent = app.sent.filter(function (m) { return m.name === 'improve'; });
        eq(sent.length, 1);
        eq(sent[0].body.payload.seconds, 1800);
      });
    })();

    /* A number dialog with no hint had nowhere to say a figure was refused. */
    await (async function anyNumberDialogExplainsARefusal() {
      const app = boot({ mine: { ok: true, data: { created: [own], accepted: [], onMe: [] } } });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Extend deadline');
      await settle();
      const box = app.document.getElementById('dialog-value');
      box.value = '0';
      click(app, 'Extend');
      await settle();
      it('explains a refused figure even on a server that sends no ceiling', function () {
        truthy(app.view.textContent.indexOf('At least 1') !== -1
            || app.view.textContent.indexOf('or more') !== -1,
          'silence: ' + app.view.textContent);
      });
    })();

    /* A second proposal on one contract was refused as "You are holding too
       many contracts", the shared words for a different rule. */
    await (async function proposalLimitInItsOwnWords() {
      const taken = Object.assign({}, own, { role: 'hitman', hitmen: undefined });
      const app = boot({
        mine: { ok: true, data: { created: [], accepted: [taken], onMe: [] } },
        amendments: { ok: true, data: [] },
        propose: { ok: false, err: 'limit_reached' }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      click(app, 'Propose change');
      click(app, 'Call it off');
      click(app, 'Propose it');
      await settle(); await settle();
      it('says a change is already waiting, not that they hold too much', function () {
        const said = app.notice();
        falsy(said.indexOf('holding too many') !== -1, said);
        truthy(said.indexOf('already a change waiting') !== -1, said);
      });
    })();

    /* A creator could only ever reach the first operative's thread: the
       page opened threads[0] and dropped the rest. */
    await (async function everyOperativeIsReachable() {
      const two = Object.assign({}, own, { hitmen: [{ alias: 'Operative #1' }, { alias: 'Operative #2' }],
        hitmenActive: 2 });
      const app = boot({
        mine: { ok: true, data: { created: [two], accepted: [], onMe: [] } },
        threads: { ok: true, data: [
          { handle: 'h-one', alias: 'Operative #1' },
          { handle: 'h-two', alias: 'Operative #2', name: 'Rook Ash' }
        ] },
        readThread: { ok: true, data: [] }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Threads');
      await settle(); await settle();

      it('asks which operative when there is more than one', function () {
        const labels = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
          .map(function (n) { return n.textContent; });
        truthy(labels.indexOf('Operative #1') !== -1 && labels.indexOf('Operative #2') !== -1,
          'only the first operative could ever be reached: ' + labels.join(' | '));
        eq(app.sent.filter(function (m) { return m.name === 'readThread'; }).length, 0,
          'and it opened one without asking');
      });

      click(app, 'Operative #2');
      await settle(); await settle();

      it('opens the thread that was picked', function () {
        const reads = app.sent.filter(function (m) { return m.name === 'readThread'; });
        eq(reads.length, 1);
        eq(reads[0].body.thread, 'h-two');
      });

      it('says who the thread is with', function () {
        truthy(app.view.textContent.indexOf('with Operative #2 (Rook Ash)') !== -1,
          'every message is signed but the thread was never named: '
          + app.view.textContent);
      });
    })();

    await (async function oneOperativeOpensStraightIn() {
      const app = boot({
        mine: { ok: true, data: { created: [own], accepted: [], onMe: [] } },
        threads: { ok: true, data: [{ handle: 'h-one', alias: 'Grey' }] },
        readThread: { ok: true, data: [] }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Threads');
      await settle(); await settle();
      it('does not ask which of one', function () {
        eq(app.sent.filter(function (m) { return m.name === 'readThread'; }).length, 1);
      });
    })();

    /* The half-typed message survives re-reading its thread — and only its
       thread. It was kept per contract, so with a thread per operative a
       message written to one was waiting in the next one opened, a tap away
       from reaching the wrong person. */
    await (async function aDraftStaysWithItsOperative() {
      const two = Object.assign({}, own, { hitmen: [{ alias: 'Operative #1' }, { alias: 'Operative #2' }],
        hitmenActive: 2 });
      const app = boot({
        mine: { ok: true, data: { created: [two], accepted: [], onMe: [] } },
        threads: { ok: true, data: [
          { handle: 'h-one', alias: 'Operative #1' },
          { handle: 'h-two', alias: 'Operative #2' }
        ] },
        readThread: { ok: true, data: [] },
        sendMessage: { ok: true }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Threads');
      await settle(); await settle();
      click(app, 'Operative #1');
      await settle(); await settle();
      const first = app.view.all().filter(function (n) { return n.tagName === 'INPUT'; })[0];
      first.value = 'For you only: the target is at the pier';
      first.oninput();

      click(app, 'Back');
      await settle();
      click(app, 'Threads');
      await settle(); await settle();
      click(app, 'Operative #2');
      await settle(); await settle();
      const second = app.view.all().filter(function (n) { return n.tagName === 'INPUT'; })[0];

      it('does not follow the creator into another operative’s thread', function () {
        eq(second.value, '', 'the message for Operative #1 was one tap from Operative #2');
      });

      // Its own thread re-read under it, as every push does.
      second.value = 'For Operative #2';
      second.oninput();
      app.sandbox.window._message({ data: { type: 'push', reason: 'message' } });
      await settle(); await settle(); await settle();
      const reread = app.view.all().filter(function (n) { return n.tagName === 'INPUT'; })[0];
      it('still survives its own thread being re-read', function () {
        eq(reread.value, 'For Operative #2');
      });
    })();

    /* With the relay switched off, every message would be refused. */
    await (async function noMessagingWhereThereIsNone() {
      const list = JSON.parse(JSON.stringify(BOARD));
      list.data.settings.relay = false;
      const taken = Object.assign({}, own, { role: 'hitman', hitmen: undefined });
      const app = boot({ list: list,
        mine: { ok: true, data: { created: [own], accepted: [taken], onMe: [] } } });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      it('draws neither Message nor Threads', function () {
        const labels = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
          .map(function (n) { return n.textContent; });
        falsy(labels.indexOf('Message') !== -1, labels.join(' | '));
        falsy(labels.indexOf('Threads') !== -1, labels.join(' | '));
        truthy(labels.indexOf('Verify kill') !== -1, 'the rest of the card is still there');
      });
    })();

    /* With no deadline, "runs out in no set deadline" — and an option to
       shorten a deadline that does not exist. */
    await (async function noDeadlineReadsRight() {
      const open = Object.assign({}, own, { role: 'hitman', hitmen: undefined, deadline: undefined });
      const app = boot({
        mine: { ok: true, data: { created: [], accepted: [open], onMe: [] } },
        amendments: { ok: true, data: [] }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      click(app, 'Propose change');
      await settle();
      it('does not say a contract with no deadline runs out in one', function () {
        const shown = app.view.textContent;
        falsy(shown.indexOf('in no set deadline') !== -1, shown);
        truthy(shown.indexOf('has no deadline') !== -1, shown);
      });
      it('does not offer to shorten a deadline that does not exist', function () {
        const labels = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
          .map(function (n) { return n.textContent; });
        falsy(labels.indexOf('Shorten the deadline') !== -1, labels.join(' | '));
      });
    })();

    /* A cut has to leave five minutes on the clock: the server refuses one
       that leaves less, so the box stops short of it rather than offering a
       figure that can only be refused. */
    await (async function shortenStopsShortOfTheFloor() {
      function heldWith(seconds) {
        return Object.assign({}, own, { role: 'hitman', hitmen: undefined,
          deadline: Math.floor(Date.now() / 1000) + seconds });
      }
      const app = boot({
        mine: { ok: true, data: { created: [], accepted: [heldWith(20 * 60 + 30)], onMe: [] } },
        amendments: { ok: true, data: [] }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      click(app, 'Propose change');
      await settle();
      click(app, 'Shorten the deadline');
      await settle();
      it('opens on a cut that leaves five minutes, not one', function () {
        const shown = app.view.textContent;
        truthy(shown.indexOf('It would then run out in 5 minutes') !== -1,
          'twenty minutes left, cut by at most fifteen: ' + shown.slice(-300));
      });

      const tight = boot({
        mine: { ok: true, data: { created: [], accepted: [heldWith(5 * 60 + 30)], onMe: [] } },
        amendments: { ok: true, data: [] }
      });
      await settle(); await settle();
      tab(tight, 'mine');
      await settle(); await settle();
      click(tight, 'Propose change');
      await settle();
      it('does not offer to shorten a deadline with no time to spare', function () {
        const labels = tight.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
          .map(function (n) { return n.textContent; });
        falsy(labels.indexOf('Shorten the deadline') !== -1, labels.join(' | '));
      });
    })();

    /* A row that names no client drew an empty pill. */
    await (async function noEmptyChips() {
      const nameless = Object.assign({}, own, { role: 'target', hitmen: undefined,
        creatorName: undefined, creatorAnonymous: undefined });
      const app = boot({ mine: { ok: true, data: { created: [], accepted: [], onMe: [nameless] } } });
      await settle(); await settle();
      tab(app, 'onme');
      await settle(); await settle();
      it('draws no empty chip', function () {
        const empty = app.view.all().filter(function (n) {
          return /(^| )chip( |$)/.test(n.className || '') && !n.textContent.trim();
        });
        eq(empty.length, 0);
      });
    })();

    await (async function threadsAnswersTheTap() {
      let answer;
      const held = new Promise(function (resolve) { answer = resolve; });
      const app = boot({
        mine: { ok: true, data: { created: [own], accepted: [], onMe: [] } },
        threads: function () { return held; }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Threads');
      await settle();

      it('shows the tap registered instead of looking dead', function () {
        const labels = app.view.all()
          .filter(function (n) { return n.tagName === 'BUTTON'; })
          .map(function (n) { return n.textContent; });
        truthy(labels.some(function (l) { return l.indexOf('Opening') !== -1; }),
          'the screen was identical until the reply landed, so the button '
          + 'read as dead: ' + labels.join(' | '));
      });

      answer({ ok: true, data: [] });
      await settle(); await settle();
    })();
  })();

  /* ---------- refusals that mean something else here ---------- */
  await (async function refusalsWordedForThisPath() {
    const job = { ok: true, data: { created: [], accepted: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'exclusive',
      state: 'accepted', reward: { baseline: 5000 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 1, hitmenMax: 1,
      targetName: 'Dana Reyes', role: 'hitman',
      deadline: Math.floor(Date.now() / 1000) + 7500
    }], onMe: [] } };

    await (async function protectedOnTheKillPath() {
      // The server says how long the protection still runs only when the
      // kill outlasts it (W172).
      const app = boot({
        mine: job,
        takeVerificationPhoto: { ok: false, err: 'target_just_up', data: { secondsLeft: 60 } }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Verify kill');
      await settle(); await settle();

      it('tells a hitman over a body why the kill did not count', function () {
        const said = app.notice();
        // The shared table words this code for the CREATION path, which is a
        // rule about placing contracts on people — not something a hitman
        // standing over a body they just photographed has done.
        falsy(said.indexOf('cannot be listed') !== -1,
          'a hitman was told about a rule for listing contracts: ' + said);
        truthy(said.indexOf('just got back up') !== -1, said);
        truthy(said.indexOf('does not count yet') !== -1,
          'and that the kill may still count: ' + said);
        truthy(said.indexOf('in 1 minute') !== -1, 'and the wait the server measured: ' + said);
      });
    })();

    /* And when the kill lapses before the protection ends, waiting cannot
       make it count: "it counts if they are still lying dead when that
       protection runs out" sent the hitman to stand over a body until the
       kill quietly lapsed. */
    await (async function protectedPastTheKill() {
      const app = boot({
        mine: job,
        takeVerificationPhoto: { ok: false, err: 'kill_too_soon', data: { rule: 'target_just_up' } }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Verify kill');
      await settle(); await settle();

      it('says a kill that lapses before the protection ends does not count', function () {
        const said = app.notice();
        truthy(said.indexOf('just got back up, so this kill does not count') !== -1, said);
        falsy(said.indexOf('yet') !== -1, 'no wait promised: ' + said);
        falsy(said.indexOf('protection runs out') !== -1, said);
      });
    })();

    await (async function everyLineTickedInTheRewardEditor() {
      const own = { ok: true, data: { created: [{
        id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive',
        state: 'active', reward: { baseline: 5000 },
        slots: 1, slotsClaimed: 0, currentSlot: 1,
        hitmenActive: 0, hitmenMax: 5, hitmen: [],
        targetName: 'Dana Reyes', role: 'creator',
        deadline: Math.floor(Date.now() / 1000) + 7500
      }], accepted: [], onMe: [] } };

      const app = boot({
        mine: own,
        rewardBreakdown: { ok: true, data: {
          editable: true, slots: 1, currentSlot: 1,
          lines: [{ id: 'ct00000001:1', slot: 1, portion: 'baseline',
                    source: 'cash', amount: 5000, withdrawable: true }]
        } },
        // What the server answers when a collection would be left empty.
        withdrawReward: { ok: false, err: 'invalid_reward' }
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Change reward');
      await settle(); await settle();

      // Tick the only line and send it.
      const boxes = app.view.all().filter(function (n) {
        return n.tagName === 'INPUT' && n.type === 'checkbox';
      });
      truthy(boxes.length >= 1, 'a line to tick');
      boxes[0].checked = true;
      if (boxes[0].onchange) { boxes[0].onchange(); }

      const send = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent.indexOf('Take back') === 0;
      })[0];
      truthy(send, 'the button that sends it');
      send.onclick();
      await settle(); await settle();

      it('says what the rule actually is, and where the whole-reward button is', function () {
        const said = app.notice();
        // The amounts add up perfectly; the rule is about what has to be LEFT.
        falsy(said.indexOf('does not add up') !== -1,
          'the creator was sent back to re-read figures that were never the '
          + 'problem: ' + said);
        truthy(said.indexOf('keep something in it') !== -1, said);
        truthy(said.indexOf('Withdraw') !== -1,
          'and told about the button two taps away that does what they wanted: '
          + said);
      });
    })();
  })();

  /* ---------- the compose box ---------- */
  await (async function composeBox() {
    function threadFixture(sendAnswer) {
      return {
        mine: { ok: true, data: { created: [], accepted: [{
          id: 'ct00000001', reason: 'Unpaid debt', mode: 'exclusive',
          state: 'accepted', reward: { baseline: 5000 },
          slots: 1, slotsClaimed: 0, currentSlot: 1,
          hitmenActive: 1, hitmenMax: 1,
          targetName: 'Dana Reyes', role: 'hitman',
          deadline: Math.floor(Date.now() / 1000) + 7200
        }], onMe: [] } },
        readThread: { ok: true, data: [] },
        threads: { ok: true, data: [] },
        sendMessage: sendAnswer
      };
    }

    function liveField(app) {
      return app.view.all().filter(function (n) {
        return n.tagName === 'INPUT';
      }).pop();
    }

    await (async function keepsARefusedMessage() {
      const app = boot(threadFixture({ ok: false, err: 'rate_limited' }));
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Message');
      await settle(); await settle();

      const field = liveField(app);
      it('opens a thread with somewhere to type', function () {
        truthy(field, 'no compose box');
      });

      field.value = 'Heading over now';
      if (field.oninput) { field.oninput(); }
      field.onkeydown({ key: 'Enter' });
      await settle(); await settle();

      it('keeps the words the server refused', function () {
        const again = liveField(app);
        eq(again.value, 'Heading over now',
          'the box emptied the instant Enter was pressed, so a message the '
          + 'server refused took the player\'s words with it and left them '
          + 'retyping something they could not see');
      });
    })();

    await (async function hasASendButton() {
      const app = boot(threadFixture({ ok: true, data: {} }));
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Message');
      await settle(); await settle();

      it('offers a Send button, not only the Enter key', function () {
        const labels = app.view.all()
          .filter(function (n) { return n.tagName === 'BUTTON'; })
          .map(function (n) { return n.textContent; });
        truthy(labels.indexOf('Send') !== -1,
          'on a phone, whether the on-screen keyboard produces Enter is up '
          + 'to the keyboard: ' + labels.join(' | '));
      });

      const field = liveField(app);
      field.value = 'On my way';
      if (field.oninput) { field.oninput(); }
      click(app, 'Send');
      await settle(); await settle();

      it('sends what was typed when it is pressed', function () {
        const sent = app.sent.filter(function (x) { return x.name === 'sendMessage'; });
        truthy(sent.length >= 1, 'nothing was sent');
        eq(sent[sent.length - 1].body.body, 'On my way');
      });
    })();

    await (async function reloadsWhenTheOtherPartyWrites() {
      const app = boot(threadFixture({ ok: true, data: {} }));
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Message');
      await settle(); await settle();

      const before = app.sent.filter(function (x) {
        return x.name === 'readThread';
      }).length;

      app.sandbox.window._message({ data: { type: 'push', reason: 'message' } });
      await settle(); await settle();

      it('re-reads an open thread when the server says something changed', function () {
        const after = app.sent.filter(function (x) {
          return x.name === 'readThread';
        }).length;
        truthy(after > before,
          'a thread was read when it was opened and after each send by this '
          + 'player, and never otherwise — so two people could sit in the '
          + 'same conversation, both writing, and neither see the other');
      });
    })();
  })();

  /* ---------- the resource this page belongs to ---------- */
  await (async function addressesItsOwnResource() {
    const seen = [];
    const app = boot({ list: { ok: true, data: { page: 1, pages: 1,
      contracts: [], settings: { minQueryLength: 3 } } } });
    await settle();

    it('posts to the resource it is actually running in', function () {
      // Renaming a resource folder is an ordinary thing for a server owner
      // to do. With the name hardcoded, every request in the app goes to a
      // resource that does not exist, every one answers 'unreachable', and
      // the app is a set of buttons that do nothing with no clue anywhere
      // as to why.
      truthy(app.urls.length > 0, 'nothing was requested, so this measures nothing');
      const wrong = app.urls.filter(function (u) {
        return u.indexOf('https://renamed-by-the-operator/') !== 0;
      });
      truthy(wrong.length === 0,
        'requests went to the wrong resource: ' + wrong.slice(0, 2).join(' | '));
      void seen;
    });
  })();

  /* ---------- diagnostics ----------
   *
   * The one thing this page never had: a way to say it broke. CEF has no
   * console anybody reads, so a thrown error reached nobody — not the
   * client, not the server log, not the operator. The symptom was a blank
   * screen and a working tab bar, and the whole diagnosis available to
   * anyone was a player saying "it broke". All four render crashes this
   * resource has shipped were reported in those words. */
  await (async function diagnostics() {
    function reports(app) {
      return app.sent.filter(function (s) { return s.name === 'pageError'; });
    }

    await (async function thrownRender() {
      const app = boot({ mine: { ok: true, data: { own: [], onMe: [] } } });
      await settle();

      // Planted in appendChild rather than in the data: every view builder
      // puts its nodes on the view with it, so this reaches inside draw()
      // wherever the player is. Planting it in the data would only prove
      // the page is hardened against that data, which already passes.
      //
      // It stays armed. Disarming after one throw let the next coalesced
      // redraw succeed and replace the recovery card with the ordinary
      // view, so the assertions below read a healthy screen and passed
      // while proving nothing. The guard's own card is let through by name.
      const die = app.document.getElementById('view');
      const realAppend = die.appendChild.bind(die);
      const fired = [];
      die.appendChild = function (child) {
        if (child && child._className === 'card') { return realAppend(child); }
        fired.push(1);
        throw new Error('planted render fault');
      };
      tab(app, 'mine');
      await settle();

      const shown = app.view.textContent;

      it('the planted fault actually fired', function () {
        truthy(fired.length >= 1,
          'the injection never ran, so everything below it proves nothing');
      });
      it('draws the failure instead of leaving the screen blank', function () {
        truthy(shown.indexOf('could not be drawn') !== -1,
          'a blank screen with a working tab bar is not a diagnosis: ' + shown);
      });
      it('leaves the player a way out of a screen that will not draw', function () {
        truthy(shown.indexOf('Back to the board') !== -1, shown);
      });
      it('sends the fault somewhere an owner can read it', function () {
        const sent = reports(app);
        truthy(sent.length >= 1,
          'the error has to leave the browser or nobody will ever see it');
        truthy(sent[0].body.what.indexOf('planted render fault') !== -1,
          JSON.stringify(sent[0].body));
      });
      it('names where it happened, not only that it happened', function () {
        truthy(reports(app)[0].body.where.indexOf('render') !== -1,
          reports(app)[0].body.where);
      });
    })();

    await (async function uncaughtError() {
      const app = boot({});
      await settle();
      app.sandbox.window.onerror('x is not a function', 'app.js', 120, 9,
        { stack: 'at card (app.js:120:9)' });
      await settle();

      it('reports an error that escaped everything else', function () {
        const sent = reports(app);
        eq(sent.length, 1, 'got ' + sent.length);
        eq(sent[0].body.what, 'x is not a function');
        truthy(sent[0].body.where.indexOf('app.js:120') !== -1, sent[0].body.where);
      });
    })();

    await (async function cappedReporting() {
      const app = boot({});
      await settle();
      // A render loop throwing every frame. Uncapped that is an audit row
      // per frame: a denial of service on the log this exists to fill.
      for (let i = 0; i < 40; i++) {
        app.sandbox.window.onerror('loop ' + i, 'app.js', i, 0, { stack: '' });
      }
      await settle();

      it('stops reporting a page that is throwing every frame', function () {
        truthy(reports(app).length <= 10,
          'sent ' + reports(app).length + ' reports for 40 errors');
      });
      it('says that it stopped rather than just going quiet', function () {
        const what = reports(app).map(function (r) { return r.body.what; });
        truthy(what.some(function (w) { return w.indexOf('suppressed') !== -1; }),
          'a reader of the log has to tell "eight errors" from "eight and '
          + 'then we stopped counting": ' + what.join(' | '));
      });
    })();

    await (async function theePanel() {
      const app = boot({ ledger: { ok: true, data: { entries: [] } } });
      await settle();
      tab(app, 'ledger');
      await settle();

      const stamp = app.view.all().filter(function (n) {
        return n._className && n._className.indexOf('build-stamp') !== -1;
      })[0];

      it('puts the way in on the build stamp', function () {
        truthy(stamp, 'the build number is the one thing a player is always '
          + 'asked to read out, so it is where the tool belongs');
      });

      for (let i = 0; i < 5; i++) { stamp.onclick(); }
      await settle();

      it('opens the panel on the fifth tap', function () {
        truthy(app.document.getElementById('diag'),
          'five taps, the way a phone exposes a developer menu');
      });
      it('shows the requests the page actually made', function () {
        const text = app.document.getElementById('diag').textContent;
        truthy(text.indexOf('ledger') !== -1,
          'what it has been doing is the point: ' + text);
      });
      it('draws over the page rather than inside the view', function () {
        const inView = app.view.all().filter(function (n) { return n._id === 'diag'; });
        eq(inView.length, 0,
          'a render that throws must not be able to take the tool for '
          + 'diagnosing it with it');
      });

      // And closes again, because a panel that cannot be dismissed is a
      // second broken screen.
      const close = app.document.getElementById('diag').all()
        .filter(function (n) { return n.textContent === 'Close'; })[0];
      close.onclick();
      it('closes again', function () {
        falsy(app.document.getElementById('diag'), 'the panel would not close');
      });
    })();

    /* W101: the panel's own send posted the whole log, oldest first and
       newline-joined; the server keeps the first 900 characters, so the
       events nearest the fault were the ones cut. */
    await (async function thePanelSendsTheNewest() {
      const app = boot({ ledger: { ok: true, data: { entries: [] } } });
      await settle();
      tab(app, 'ledger');
      await settle();
      for (let i = 0; i < 40; i++) {
        app.sandbox.window.onerror('filler event number ' + i, 'app.js', 1, 1, { stack: 'at x' });
      }
      app.sandbox.window.onerror('NEWEST EVENT', 'app.js', 1, 1, { stack: 'at y' });
      await settle();
      const stamp = app.view.all().filter(function (n) {
        return n._className && n._className.indexOf('build-stamp') !== -1;
      })[0];
      for (let i = 0; i < 5; i++) { stamp.onclick(); }
      await settle();
      const send = app.document.getElementById('diag').all()
        .filter(function (n) { return n.textContent === 'Send this to the server log'; })[0];
      send.onclick();
      await settle();
      const sent = app.sent.filter(function (m) {
        return m.name === 'pageError' && m.body.what === 'diagnostics requested by the player';
      });
      it('sends the newest of the log, as the server keeps it', function () {
        eq(sent.length, 1);
        const stack = String(sent[0].body.stack);
        truthy(stack.length <= 900, 'the server keeps 900 characters: ' + stack.length);
        truthy(stack.indexOf(' || ') !== -1, 'in lines the server splits');
        truthy(stack.indexOf('NEWEST EVENT') !== -1, 'with the newest event in it');
      });
    })();

    await (async function recordsWhatTheServerRefused() {
      const app = boot({ list: { ok: false, err: 'rate_limited' },
                         ledger: { ok: true, data: { entries: [] } } });
      await settle();
      tab(app, 'board');
      await settle();
      tab(app, 'ledger');
      await settle();

      const stamp = app.view.all().filter(function (n) {
        return n._className && n._className.indexOf('build-stamp') !== -1;
      })[0];
      for (let i = 0; i < 5; i++) { stamp.onclick(); }
      await settle();

      it('records a refusal with the reason the server gave', function () {
        const text = app.document.getElementById('diag').textContent;
        truthy(text.indexOf('rate_limited') !== -1,
          'the panel has to say WHICH request was refused and why, or it is '
          + 'no better than the player saying it broke: ' + text);
      });
    })();
  })();


  /* ---------- the page walked as each role ----------------------------

     Found by walking every tab as creator, hitman, target and a player with
     nothing, against the shapes the server really sends. Each is something
     the page did that a player would act on, and each fails on the page as
     it was. */
  await (async function walkedAsEachRole() {
    function nowSeconds() { return Math.floor(Date.now() / 1000); }
    function placedCard(extra) {
      return Object.assign({
        id: 'ct00000009', reason: 'Owes money', mode: 'competitive', state: 'accepted',
        reward: { baseline: 5000, bonus: 0 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
        hitmenActive: 1, hitmenMax: 5, targetName: 'Dana Reyes', targetProtected: false,
        creatorName: 'Vic Marlowe', role: 'creator', deadline: nowSeconds() + 3 * 3600,
        penaltyAmount: 0,
        hitmen: [{ alias: 'Operative #1', claims: 0, record: { standing: 'Unproven' } }]
      }, extra || {});
    }
    function boardWith(settings) {
      return { ok: true, data: { page: 1, pages: 1, contracts: [],
        settings: Object.assign({ relay: true, calls: false, deadlineMaxMinutes: 2880,
          buyouts: true, amendments: true }, settings || {}) } };
    }
    function pushNow(app) {
      app.sandbox.window._message({ data: { type: 'push', reason: 'accepted' } });
      app.timers.filter(function (t) { return t.ms === 250 && !t.cleared; })
        .forEach(function (t) { t.cleared = true; t.fn(); });
    }
    function buttonLabels(app) {
      return app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
    }
    function composeBox(app) {
      return app.view.all().filter(function (n) {
        return n.tagName === 'INPUT' && n.placeholder === 'Say something';
      })[0];
    }

    /* A number typed into a dialog, and a push landing before Confirm.

       The box was re-seeded from its opening figure on every render, so
       90 minutes typed became 30 again under the player and Extend sent
       30. The fields dialog was fixed for this long ago; this one was not. */
    await (async function numberDialogKeepsWhatWasTyped() {
      let improved = null;
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [placedCard()], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        improve: function (body) { improved = body; return { ok: true, data: true }; }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Extend deadline');
      const box = app.document.getElementById('dialog-value');
      box.value = '90'; box.oninput();
      pushNow(app);
      await settle(); await settle(); await settle();

      it('keeps a typed figure when the dialog is redrawn under it', function () {
        eq(app.document.getElementById('dialog-value').value, '90',
          'the redraw put the opening figure back in the box');
      });

      click(app, 'Extend');
      await settle();
      it('and sends the figure that was typed', function () {
        truthy(improved, 'nothing was sent');
        eq(improved.payload.seconds, 90 * 60);
      });
      drewCleanly(app, 'the extend dialog');
    })();

    /* A creator with two operatives, writing to the first, then opening the
       second. The draft was kept per contract, so it was waiting pre-filled
       in the second operative's box and went to them on Send. */
    await (async function draftStaysWithItsOperative() {
      const sent = [];
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [placedCard({ hitmenActive: 2, hitmen: [
          { alias: 'Operative #1', claims: 0, record: { standing: 'Unproven' } },
          { alias: 'Operative #2', claims: 0, record: { standing: 'Unproven' } }] })],
          accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        threads: { ok: true, data: [{ handle: 'thA', alias: 'Operative #1' },
                                    { handle: 'thB', alias: 'Operative #2' }] },
        readThread: { ok: true, data: [] },
        sendMessage: function (body) { sent.push(body); return { ok: true, data: true }; }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Threads'); await settle(); await settle();
      click(app, 'Operative #1'); await settle(); await settle();
      const first = composeBox(app);
      first.value = 'Meet me at the pier at ten'; first.oninput();
      click(app, 'Back'); await settle();
      click(app, 'Threads'); await settle(); await settle();
      click(app, 'Operative #2'); await settle(); await settle();

      it('does not carry a draft into another operative’s thread', function () {
        eq(composeBox(app).value, '',
          'words typed to one operative were waiting in the next one’s box');
      });

      click(app, 'Back'); await settle();
      click(app, 'Threads'); await settle(); await settle();
      click(app, 'Operative #1'); await settle(); await settle();
      it('but keeps it for the operative it was written to', function () {
        eq(composeBox(app).value, 'Meet me at the pier at ten');
      });
      it('and sent nothing on the way', function () { eq(sent.length, 0); });
    })();

    /* The server can hand the same conversation a new handle — it did on
       every operative log-off, and does after a restart. A draft filed by
       handle was then never found again. */
    await (async function draftSurvivesANewHandle() {
      let handle = 'thOld';
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [placedCard()], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        threads: function () { return { ok: true, data: [{ handle: handle, alias: 'Operative #1' }] }; },
        readThread: { ok: true, data: [] }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Threads'); await settle(); await settle();
      const box = composeBox(app);
      truthy(box, 'the thread opened');
      box.value = 'Meet me at the pier at nine'; box.oninput();
      click(app, 'Back'); await settle();
      handle = 'thNew';
      click(app, 'Threads'); await settle(); await settle();
      it('keeps a half-typed message when the thread comes back under a new handle', function () {
        eq(composeBox(app) && composeBox(app).value, 'Meet me at the pier at nine');
      });
    })();

    /* The message box's limit is the server's, not a number in the page. */
    await (async function messageBoxFollowsTheServer() {
      const app = boot({
        list: boardWith({ messageMaxLength: 90 }), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [placedCard({ role: 'hitman',
          hitmen: undefined, myAlias: 'Operative #1' })], onMe: [] } },
        amendments: { ok: true, data: [] },
        readThread: { ok: true, data: [] }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Message'); await settle(); await settle();
      it('bounds the message box by the length the server holds messages to', function () {
        truthy(composeBox(app), 'the thread opened');
        eq(String(composeBox(app).maxLength), '90');
      });
    })();

    /* The contract closes while its thread is open. The re-read on the push
       was refused, and the page stayed in front of the conversation saying
       "That is not yours." on every push after. */
    await (async function closedThreadIsLeft() {
      let open = true;
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [placedCard({ role: 'hitman',
          hitmen: undefined, myAlias: 'Operative #1' })], onMe: [] } },
        amendments: { ok: true, data: [] },
        readThread: function () {
          return open ? { ok: true, data: [] } : { ok: false, err: 'already_settled' };
        }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Message'); await settle(); await settle();
      truthy(composeBox(app), 'the thread opened');

      open = false;
      pushNow(app);
      await settle(); await settle(); await settle();

      it('leaves a thread whose contract has closed', function () {
        falsy(!!composeBox(app), 'a compose box every Send of which is refused');
      });
      it('and says the contract closed, not that it is not theirs', function () {
        truthy(app.notice().indexOf('closed') !== -1, app.notice());
        falsy(app.notice().indexOf('not yours') !== -1, app.notice());
      });
    })();

    /* The Edit dialog, opened to fix a word in the reason. It opened on a
       fixed three hours and always sent it, so saving a reason cut a
       contract with most of a day left down to three hours. */
    await (async function editLeavesTheDeadlineAlone() {
      let revised = null;
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [],
        deadline: nowSeconds() + 20 * 3600 });
      const app = boot({
        list: boardWith({ reasonMode: 'freetext' }), ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        revise: function (body) { revised = body; return { ok: true, data: { id: body.id } }; }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Edit');

      it('opens the deadline empty, saying empty keeps what is left', function () {
        const box = app.document.getElementById('dialog-hours');
        eq(box.value, '');
        truthy(/keep 20h/.test(box.placeholder), box.placeholder);
      });

      const reason = app.document.getElementById('dialog-reason');
      reason.value = 'Owes money, and lied about it'; reason.oninput();
      click(app, 'Save'); await settle();

      it('sends the reason and leaves the deadline where it was', function () {
        truthy(revised, 'nothing was sent');
        eq(revised.reason, 'Owes money, and lied about it');
        falsy('deadlineSeconds' in revised && revised.deadlineSeconds !== undefined,
          'a reason edit moved the deadline: ' + JSON.stringify(revised));
      });
    })();

    /* Ten minutes left opened the box on 1 — rounded up — and Save sent it
       only if touched, so a creator who read "1" as an hour from now saved,
       was told "Contract updated." and the deadline stayed at ten minutes.
       The box opens empty now, and whatever is typed in it is sent. */
    await (async function editSetsTheRoundedFigure() {
      let revised = null;
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [],
        deadline: nowSeconds() + 10 * 60 });
      const app = boot({
        list: boardWith({ reasonMode: 'freetext' }), ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        revise: function (body) { revised = body; return { ok: true, data: { id: body.id } }; }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Edit');
      const hours = app.document.getElementById('dialog-hours');
      it('shows no figure Save would ignore, and says exactly how long is left', function () {
        eq(hours.value, '');
        truthy(/10 min/.test(hours.placeholder), hours.placeholder);
      });
      hours.value = '1'; hours.oninput();
      click(app, 'Save'); await settle();
      it('sends the deadline the creator typed, even the figure it opened on', function () {
        truthy(revised, 'nothing was sent');
        eq(revised.deadlineSeconds, 3600, JSON.stringify(revised));
      });
    })();

    // The same dialog on a preset server: moving the deadline replaced the
    // reason with the first preset, because the picker opened on nothing.
    await (async function editKeepsThePresetReason() {
      let revised = null;
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [],
        reason: 'Snitching', deadline: nowSeconds() + 2 * 3600 });
      const app = boot({
        list: boardWith({ reasonMode: 'preset',
          reasonPresets: ['Unpaid debt', 'Snitching', 'Territory dispute'] }),
        ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        revise: function (body) { revised = body; return { ok: true, data: { id: body.id } }; }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Edit');
      const hours = app.document.getElementById('dialog-hours');
      hours.value = '6'; hours.oninput();
      click(app, 'Save'); await settle();

      it('keeps the preset the contract already gives', function () {
        truthy(revised, 'nothing was sent');
        eq(revised.reasonPreset, 2, 'the reason was replaced with the first preset');
        eq(revised.deadlineSeconds, 6 * 3600);
      });
    })();

    /* A proposal on a contract nobody holds. The creator's own answer is
       the one that applies it, and the page drew it as "Waiting to be
       applied." with nothing to press — so it lapsed, held the one open
       slot, and was then put to the next hitman to accept. */
    await (async function untakenProposalApplies() {
      const calls = [];
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [], slots: 2 });
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        propose: function (body) {
          calls.push(['propose', body]);
          return { ok: true, data: { id: 'am00000001', outcome: 'applied' } };
        },
        respondAmendment: function (body) {
          calls.push(['respond', body]); return { ok: false, err: 'rate_limited' };
        }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Propose change');

      it('does not tell a creator of an untaken contract to wait for an operative', function () {
        falsy(app.view.textContent.indexOf('until the operative agrees') !== -1,
          app.view.textContent);
      });

      click(app, 'Give back the last payout');
      click(app, 'Yes');
      await settle(); await settle(); await settle();

      /* The server applies it in the one request. A second request of
         the page's own came out of the same rate-limit bucket, and refused
         it left a proposal the card never drew. */
      it('applies it in the one request', function () {
        eq(calls.map(function (c) { return c[0]; }).join(','), 'propose');
      });
      it('and says it is done', function () {
        truthy(app.notice().indexOf('in effect') !== -1, app.notice());
      });
    })();

    /* "Cancel the contract" on a contract nobody holds closed it on one
       tap: the server applies the creator's own proposal at once, with no
       confirmation and nothing said of the refund or the waits. It hands
       off to Withdraw, which asks first and names the waits. */
    await (async function untakenCancelIsWithdraw() {
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [] });
      const app = boot({
        list: boardWith({ relistWaits: { anyMinutes: 5, sameTargetMinutes: 120 } }),
        ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        propose: { ok: true, data: { outcome: 'applied' } },
        cancel: { ok: true, data: { queued: 0 } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Propose change');
      click(app, 'Cancel the contract');
      await settle();
      it('asks first, as Withdraw does, and sends nothing yet', function () {
        truthy(buttonLabels(app).indexOf('Withdraw it') !== -1, buttonLabels(app).join(' | '));
        eq(app.sent.filter(function (x) { return x.name === 'propose' || x.name === 'cancel'; }).length, 0);
      });
      it('names the waits withdrawing starts', function () {
        const text = app.view.textContent;
        truthy(text.indexOf('any new contract for 5 minutes') !== -1
          && text.indexOf('one on Dana Reyes for 2h') !== -1
          && text.indexOf('nobody else') === -1, text);
      });
      click(app, 'Withdraw it');
      await settle(); await settle();
      it('withdraws through the withdraw request, not a proposal', function () {
        eq(app.sent.filter(function (x) { return x.name === 'cancel'; }).length, 1);
        eq(app.sent.filter(function (x) { return x.name === 'propose'; }).length, 0);
      });
    })();

    /* W071: both cancel options sent on one tap on a held contract, and a
       proposal could not be taken back by whoever made it. */
    await (async function heldCancelAsksFirst() {
      const card = placedCard({});
      const app = boot({
        list: boardWith({ relistWaits: { anyMinutes: 5, sameTargetMinutes: 120 } }),
        ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        propose: { ok: true, data: { outcome: 'open' } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Propose change');
      click(app, 'Cancel the contract');
      await settle();
      it('asks the client first, with the waits an agreed cancel starts', function () {
        truthy(buttonLabels(app).indexOf('Propose it') !== -1, buttonLabels(app).join(' | '));
        eq(app.sent.filter(function (x) { return x.name === 'propose'; }).length, 0);
        truthy(app.view.textContent.indexOf('any new contract for 5 minutes') !== -1,
          app.view.textContent);
      });
      click(app, 'Propose it');
      await settle(); await settle();
      it('and proposes it once agreed to', function () {
        const sent = app.sent.filter(function (x) { return x.name === 'propose'; });
        eq(sent.length, 1);
        eq(sent[0].body.kind, 'cancel');
      });
    })();

    await (async function hitmanCallItOffAsksFirst() {
      const card = placedCard({ role: 'hitman', hitmen: undefined, myAlias: 'Operative #1',
        penaltyAmount: 2000 });
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [card], onMe: [] } },
        amendments: { ok: true, data: [] },
        propose: { ok: true, data: { outcome: 'open' } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Propose change');
      click(app, 'Call it off');
      await settle();
      it('tells a hitman their stake comes back, before anything is sent', function () {
        truthy(app.view.textContent.indexOf('$2,000 stake comes back to you') !== -1,
          app.view.textContent);
        eq(app.sent.filter(function (x) { return x.name === 'propose'; }).length, 0);
      });
    })();

    await (async function ownProposalCanBeTakenBack() {
      const card = placedCard({ role: 'hitman', hitmen: undefined, myAlias: 'Operative #1' });
      let answered = null;
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [card], onMe: [] } },
        amendments: { ok: true, data: [{ id: 'am00000009', kind: 'withdraw', payload: {},
          proposer: 'Operative #1', mine: true, answered: true, waiting: 1, secondsLeft: 240 }] },
        respondAmendment: function (body) {
          answered = body;
          return { ok: true, data: { outcome: 'declined' } };
        }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Take it back');
      await settle(); await settle();
      it('takes back their own proposal with a decline, and says so', function () {
        truthy(answered, 'nothing was sent');
        eq(answered.id, 'am00000009');
        eq(answered.approve, false);
        truthy(app.notice().indexOf('Taken back') !== -1, app.notice());
      });
    })();

    /* W080: Withdraw after an operative took it and walked away said
       "Nobody has taken it", and left out that withdrawing it then starts
       the wait on the target for every client. */
    await (async function withdrawAfterAWalkAway() {
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [], everTaken: true });
      const app = boot({
        list: boardWith({ relistWaits: { anyMinutes: 5, sameTargetMinutes: 120,
          everyoneMinutes: 30 } }),
        ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        cancel: { ok: true, data: { queued: 0 } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Withdraw');
      await settle();
      it('says the operative walked away, and that everybody waits on the target', function () {
        const text = app.view.textContent;
        truthy(text.indexOf('The operative who took it walked away') !== -1, text);
        falsy(text.indexOf('Nobody has taken it') !== -1, text);
        truthy(text.indexOf('Nobody else can place one on Dana Reyes for 30 minutes either.')
          !== -1, text);
      });
    })();

    /* W070: a change everybody agreed to and the server refused as it went
       in reached the last to agree as "ran out". */
    await (async function agreedButNoLongerApplies() {
      const card = placedCard({ role: 'hitman', hitmen: undefined, myAlias: 'Operative #1' });
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [card], onMe: [] } },
        amendments: { ok: true, data: [{ id: 'am00000010', kind: 'change_mode',
          payload: { mode: 'exclusive' }, proposer: 'The client', mine: false,
          answered: false, waiting: 1, secondsLeft: 240 }] },
        respondAmendment: { ok: false, err: 'bad_state', data: { outcome: 'failed' } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Agree');
      await settle(); await settle();
      it('says it was agreed and no longer applies, and why, not that it ran out', function () {
        const said = app.notice();
        truthy(said.indexOf('Agreed, but it no longer applies: who is on the contract changed')
          !== -1, said);
        falsy(said.indexOf('ran out') !== -1, said);
      });
    })();

    /* A staked hitman asked to agree to a shorter clock was told neither
       what missing it costs nor that the proposal lapses. */
    await (async function proposalSaysCostAndLapse() {
      const card = placedCard({ role: 'hitman', hitmen: undefined, myAlias: 'Operative #1',
        mode: 'exclusive', penaltyAmount: 10000, deadline: nowSeconds() + 40 * 60,
        secondsLeft: 40 * 60 });
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [card], onMe: [] } },
        amendments: { ok: true, data: [{ id: 'am00000003', kind: 'shorten_deadline',
          payload: { seconds: 1800 }, proposer: 'The client', mine: false,
          answered: false, waiting: 1, secondsLeft: 240 }] }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      it('says the stake goes if the shorter clock is missed', function () {
        truthy(app.view.textContent.indexOf('Your $10,000 stake goes to the person who placed '
          + 'it if you have not finished by then') !== -1, app.view.textContent);
      });
      it('says when the proposal lapses', function () {
        truthy(app.view.textContent.indexOf('Lapses in 4 minutes if you do not answer') !== -1,
          app.view.textContent);
      });
    })();

    /* Mode, reason and stake: the server has changed them on agreement
       since the first commit and nothing here could ask. Each is offered
       only where the server can take it. */
    await (async function heldContractOffersModeAndReason() {
      let proposed = null;
      const card = placedCard({ mode: 'exclusive', penaltyAmount: 2000, valueHeld: 5000 });
      const app = boot({
        list: boardWith({ reasonMode: 'freetext', stakeCeiling: { amount: 100000, fraction: 2 } }),
        ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        propose: function (body) { proposed = body; return { ok: true, data: { outcome: 'open' } }; }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Propose change');
      it('offers the mode switch and a new reason, but no stake raise under a hitman', function () {
        const labels = buttonLabels(app);
        truthy(labels.indexOf('Open it to other hitmen') !== -1, labels.join(' | '));
        truthy(labels.indexOf('Change the reason') !== -1, labels.join(' | '));
        falsy(labels.indexOf('Raise the stake') !== -1, labels.join(' | '));
      });
      click(app, 'Open it to other hitmen');
      click(app, 'Propose');
      await settle(); await settle();
      it('proposes the mode the server reads', function () {
        truthy(proposed, 'nothing was proposed');
        eq(proposed.kind, 'change_mode');
        eq(proposed.payload.mode, 'competitive');
      });
    })();

    // And the immediate ones, from Change reward: the stake lowered or
    // removed, and the kidnapping bonus raised.
    await (async function rewardScreenImprovesTerms() {
      const improved = [];
      const card = placedCard({ penaltyAmount: 5000, bonusPercent: 10,
        reward: { baseline: 5000, bonus: 500 } });
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        rewardBreakdown: { ok: true, data: { editable: false, slots: 1, currentSlot: 1,
          lines: [{ slot: 1, portion: 'baseline', source: 'cash', amount: 5000 }] } },
        rewardOptions: { ok: true, data: { cash: 0, bank: 0, dirty: 0, items: [], weapons: [],
          caps: { bonusPercent: 50 } } },
        improve: function (body) { improved.push(body); return { ok: true, data: true }; }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Change reward'); await settle(); await settle();
      click(app, 'Lower the stake');
      click(app, 'Remove it');
      await settle(); await settle();
      it('removes the stake through improve, at once', function () {
        eq(improved.length, 1);
        eq(improved[0].kind, 'lower_penalty');
        eq(improved[0].payload.amount, 0);
      });
      click(app, 'Change reward'); await settle(); await settle();
      click(app, 'Add to it'); await settle(); await settle();
      // The bonus is the one thing this wallet can add, so it opens on it.
      click(app, 'Raise'); await settle(); await settle();
      it('raises the kidnapping bonus through improve', function () {
        eq(improved.length, 2);
        eq(improved[1].kind, 'raise_bonus');
        eq(improved[1].payload.percent, 20);
      });
    })();

    /* A buyout paid with a hitman on it waits out the delay, and the
       target was told "closes shortly" and "your money is already gone". */
    await (async function buyoutSaysItWaits() {
      const target = { id: 'ct00000002', reason: 'x', mode: 'exclusive', state: 'accepted',
        reward: { baseline: 5000 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
        hitmenActive: 1, targetName: 'You', role: 'target',
        bailoutAmount: 90000, bailoutAvailable: true };
      const app = boot({
        list: boardWith({ buyoutDelaySeconds: 120 }), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [], onMe: [target] } },
        bailout: { ok: true, data: { queued: true } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'onme'); await settle(); await settle();
      click(app, 'Buy out — $90,000');
      it('says a hitman on it still has time, and the money comes back', function () {
        const text = app.view.textContent;
        truthy(text.indexOf('about 2 minutes more to finish it') !== -1
          && text.indexOf('your $90,000 comes back') !== -1, text);
      });
      click(app, 'Pay $90,000');
      await settle(); await settle();
      it('says they are still a target once paid', function () {
        truthy(app.notice().indexOf('still a target') !== -1, app.notice());
      });
    })();

    // And one left open with nobody else to answer it — the operatives
    // walked away — offers the answer that applies it.
    await (async function strandedProposalCanBeApplied() {
      let answered = null;
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [] });
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [{ id: 'am00000002', kind: 'shorten_deadline',
          payload: { seconds: 1800 }, proposer: 'Vic Marlowe', mine: true,
          answered: true, waiting: 0 }] },
        respondAmendment: function (body) { answered = body; return { ok: true, data: { outcome: 'applied' } }; }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();

      it('does not claim a proposal nobody can answer is waiting to be applied', function () {
        falsy(app.view.textContent.indexOf('Waiting to be applied') !== -1,
          app.view.textContent);
      });
      click(app, 'Apply it');
      await settle(); await settle();
      it('offers the answer that applies it', function () {
        truthy(answered, 'nothing was sent');
        eq(answered.approve, true);
      });
    })();

    // A server with amendments switched off refuses every proposal.
    await (async function noProposalsWhereThereAreNone() {
      const app = boot({
        list: boardWith({ amendments: false }), ledger: LEDGER,
        mine: { ok: true, data: { created: [placedCard()], accepted: [placedCard({
          id: 'ct00000010', role: 'hitman', hitmen: undefined })], onMe: [] } },
        amendments: { ok: true, data: [] }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      it('draws no Propose change where the server takes none', function () {
        eq(buttonLabels(app).filter(function (l) { return l === 'Propose change'; }).length, 0,
          buttonLabels(app).join(' | '));
      });
    })();

    /* An agreed "withdraw" closes the whole contract — the server applies it
       exactly as it applies cancel. The client and every other operative
       were shown "Withdraw from this contract", which reads as one operative
       stepping away. */
    await (async function withdrawSaysWhatItDoes() {
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [placedCard()], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [{ id: 'am00000003', kind: 'withdraw', payload: {},
          proposer: 'Operative #1', mine: false, answered: false, waiting: 2 }] }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      it('tells the client that agreeing ends the whole contract', function () {
        const text = app.view.textContent;
        truthy(text.indexOf('whole contract') !== -1 || text.indexOf('closes for everyone') !== -1,
          text);
      });
    })();

    /* A pick that can no longer be named: its handle lapsed, or the person
       left. It read "Check what you entered.", and picking them again from
       the kept list sent the same dead handle every time. */
    await (async function deadPickIsDropped() {
      const creates = [];
      let reads = 0;
      const app = boot({
        list: boardWith(), ledger: LEDGER, mine: MINE,
        rewardOptions: { ok: true, data: { cash: 100000, bank: 50000, dirty: 0,
          items: [], weapons: [], caps: {} } },
        browseTargets: function () {
          reads++;
          return { ok: true, data: { people: [{ handle: 'tg0000000' + reads,
            name: 'Dana Reyes', protected: false }], total: 1, page: 1, pages: 1 } };
        },
        create: function (body) {
          creates.push(body.target);
          return body.target === 'tg00000001'
            ? { ok: false, err: 'not_found' } : { ok: true, data: {} };
        }
      });
      await settle(); await settle(); await settle();
      tab(app, 'place'); await settle(); await settle(); await settle();
      function person() {
        return app.view.all().filter(function (n) {
          return n.tagName === 'BUTTON' && n._className.indexOf('person') === 0;
        })[0];
      }
      person().onclick();
      const cash = app.document.getElementById('slot-cash-1');
      cash.value = '5000'; cash.oninput();
      click(app, 'Place contract'); await settle(); await settle(); await settle();

      it('says the person cannot be picked any more, not to check the form', function () {
        falsy(app.notice().indexOf('Check what you entered') !== -1, app.notice());
        truthy(app.notice().indexOf('choose') !== -1, app.notice());
      });
      it('reads the list again for fresh picks', function () { eq(reads, 2); });

      person().onclick();
      click(app, 'Place contract'); await settle(); await settle();
      it('and the next pick is a live one', function () {
        eq(JSON.stringify(creates), JSON.stringify(['tg00000001', 'tg00000002']));
      });
    })();

    // Withdrawing a contract whose refund would not all fit.
    await (async function withdrawSaysWhatIsWaiting() {
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [] });
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        cancel: { ok: true, data: { id: 'ct00000009', queued: 2 } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Withdraw'); click(app, 'Withdraw it'); await settle(); await settle();
      it('does not say everything came back when some of it is waiting', function () {
        falsy(app.notice().indexOf('Everything you put up has been returned') !== -1,
          app.notice());
        truthy(app.notice().indexOf('waiting for you') !== -1, app.notice());
      });
    })();

    // And a refund left for staff, which making room does not hand over.
    await (async function withdrawSaysWhatStaffAreChecking() {
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [] });
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        cancel: { ok: true, data: { id: 'ct00000009', queued: 0, parked: 1 } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Withdraw'); click(app, 'Withdraw it'); await settle(); await settle();
      it('says staff are checking a refund left for them, not that it all came back', function () {
        const said = app.notice();
        falsy(said.indexOf('Everything you put up has been returned') !== -1, said);
        truthy(said.indexOf('staff have been asked to check it') !== -1, said);
        falsy(said.indexOf('next have room') !== -1, said);
      });
    })();

    // W074: withdrawing after a payout on it was collected.
    await (async function withdrawSaysWhatWasCollected() {
      const card = placedCard({ state: 'active', hitmenActive: 0, hitmen: [], everTaken: true,
        slots: 2, slotsClaimed: 1, currentSlot: 2 });
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [card], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        cancel: { ok: true, data: { id: 'ct00000009', queued: 0 } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Withdraw');
      const asked = app.view.textContent;
      click(app, 'Withdraw it'); await settle(); await settle();
      it('says before and after that a collected payout does not come back', function () {
        truthy(asked.indexOf('1 of 2 payouts were collected, so the rest of what you put up '
          + 'comes back to you.') !== -1, asked);
        const said = app.notice();
        falsy(said.indexOf('Everything you put up has been returned') !== -1, said);
        truthy(said.indexOf('1 of 2 payouts were collected; the rest of what you put up has been '
          + 'returned.') !== -1, said);
      });
    })();

    // W048: the target's buyout counted down on the hitman's own card.
    await (async function hitmanCardCountsTheBuyoutDown() {
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [], onMe: [], accepted: [{
          id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'accepted',
          reward: { baseline: 5000, bonus: 0 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
          hitmenActive: 1, hitmenMax: 5, targetName: 'Dana Reyes', role: 'hitman',
          deadline: Math.floor(Date.now() / 1000) + 7500, buyoutClosesIn: 90 }] } },
        amendments: { ok: true, data: [] }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      it('says the buyout closes it, and never more time than is left', function () {
        const text = app.view.textContent;
        truthy(text.indexOf('Buyout paid: it closes in under 2 minutes unless you finish it '
          + 'first.') !== -1, text);
      });
    })();

    /* The poll that lands while a finished handover is being paid. It used
       to stop the poller at a full bar — the one place the outcome is read
       — so a hitman who had been paid was never told. */
    await (async function paidHandoverIsReported() {
      const replies = [
        { ok: true, data: { elapsed: 29, required: 30, graceLeft: 3000, graceTotal: 3000 } },
        { ok: true, data: { settling: true, elapsed: 30, required: 30 } },
        { ok: true, data: { done: true, outcome: 'paid' } }
      ];
      const app = boot({
        list: boardWith(), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [placedCard({ role: 'hitman',
          hitmen: undefined })], onMe: [] } },
        amendments: { ok: true, data: [] },
        armKidnap: { ok: true, data: { armed: true } },
        kidnapProgress: function () { return replies.shift() || { ok: false, err: 'no_handover' }; }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine'); await settle(); await settle();
      click(app, 'Deliver alive'); await settle(); await settle();
      const poll = app.timers.filter(function (t) { return t.repeating && t.ms === 1000; })[0];
      truthy(poll, 'the poller started');
      // Only while it is still running, as a browser would: a stopped
      // interval does not fire again.
      for (let i = 0; i < 3; i++) {
        if (!poll.cleared) { poll.fn(); }
        await settle(); await settle();
      }

      it('tells a hitman who was paid that they were paid', function () {
        truthy(app.notice().indexOf('Delivered') !== -1,
          'the poller stopped at a full bar and never heard how it ended: '
          + app.notice());
      });
    })();
  })();
  /* Staff asking for the page's log after it has used up its fault reports:
     it went through the same cap, and the answer never came. */
  await (async function diagnosticsPastTheCap() {
    const app = boot({ list: BOARD, mine: { ok: true, data: { created: [], accepted: [], onMe: [] } },
                       ledger: LEDGER });
    await settle(); await settle();
    for (let i = 0; i < 30; i++) {
      app.sandbox.window._message({ data: { type: 'diagnostics' } });
    }
    const dumps = app.sent.filter(function (m) {
      return m.name === 'pageError' && m.body.what === 'page diagnostics';
    });
    it('answers every request for the log', function () {
      eq(dumps.length, 30, 'capped like a fault report');
    });
    it('sends the newest part of it', function () {
      truthy(dumps.length && String(dumps[0].body.stack).length <= 900);
    });
  })();

  /* A notice's timer clears that notice and nothing newer. */
  await (async function aNoticeOutlivesAnOlderTimer() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hitman';
    let calls = 0;
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
      ledger: LEDGER,
      // A confirmation first: a refusal has no timer at all now, it stays
      // until the next tap, so the older timer has to be a confirmation's.
      takeVerificationPhoto: { ok: true, data: {} },
      readThread: function () {
        calls += 1;
        return { ok: false, err: 'invalid_input' };
      }
    });
    await settle(); await settle();
    tab(app, 'mine');
    await settle();
    click(app, 'Verify kill');
    await settle(); await settle();
    const first = app.timers.filter(function (t) { return t.ms === 4000 && !t.cleared; });
    click(app, 'Message');
    await settle(); await settle();
    const second = app.notice();
    first.forEach(function (t) { t.fn(); });
    it('keeps a notice raised after an older one began to time out', function () {
      truthy(first.length > 0, 'the confirmation set its timer');
      truthy(second.length > 0, 'the second notice was raised');
      eq(app.notice(), second, 'the first notice timer blanked the second');
    });
  })();

  /* Threads and the replies that arrive for them.
     A late reply switched the view wherever the player had gone; a message
     push cost a full refresh; a re-read took the keyboard out of the box. */
  await (async function threadsAndLateReplies() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hitman';
    held.myAlias = 'Operative #1';

    // On screen, not merely registered: the shim keeps a detached node
    // findable by id while its old parent chain still reaches the page.
    function composeOnScreen(app) {
      return app.view.all().filter(function (n) { return n.id === 'compose-input'; })[0] || null;
    }

    function deferred() {
      let release;
      const promise = new Promise(function (resolve) { release = resolve; });
      return { promise: promise, release: release };
    }

    function openApp(readThread) {
      const app = boot({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
        mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
        ledger: LEDGER,
        readThread: readThread,
        rewardOptions: { ok: true, data: { cash: 0, bank: 0, dirty: 0, items: [], weapons: [], caps: {} } }
      });
      return app;
    }

    await (async function aLateOpenDoesNotPullThePlayerBack() {
      let pending = null;
      const app = openApp(function () { pending = deferred(); return pending.promise; });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Message');
      await settle();
      tab(app, 'place');
      await settle();
      pending.release({ ok: true, data: [{ alias: 'The client', body: 'hello' }] });
      await settle(); await settle();
      it('stays where the player went while the thread was opening', function () {
        falsy(app.view.textContent.indexOf('hello') !== -1,
          'the late reply dragged the player into the thread: ' + app.view.textContent.slice(0, 120));
      });
    })();

    await (async function backDuringARereadStaysBack() {
      let pending = null;
      const app = openApp(function () {
        pending = deferred();
        return pending.promise;
      });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Message');
      await settle();
      pending.release({ ok: true, data: [] });
      await settle(); await settle();
      truthy(composeOnScreen(app), 'in the thread');
      // A push re-reads it; the player presses Back before it lands.
      app.sandbox.window._message({ data: { type: 'push', reason: 'message' } });
      await settle();
      click(app, 'Back');
      await settle();
      pending.release({ ok: true, data: [{ alias: 'The client', body: 'late' }] });
      await settle(); await settle();
      it('does not put the player back into a thread they left', function () {
        falsy(!!composeOnScreen(app), 'Back was undone by a re-read landing after it');
      });
    })();

    await (async function aMessagePushOnlyRereadsTheThread() {
      const app = openApp({ ok: true, data: [] });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Message');
      await settle(); await settle();
      const input = composeOnScreen(app);
      truthy(input, 'in the thread');
      input.focus();
      input.value = 'half a sen';
      input.oninput();
      const before = app.sent.length;
      app.sandbox.window._message({ data: { type: 'push', reason: 'message' } });
      await settle(); await settle();
      for (let i = 0; i < 3; i++) { await settle(); }
      const after = app.sent.slice(before).map(function (m) { return m.name; });
      it('re-reads the open thread and nothing else on a message', function () {
        eq(after.join(','), 'readThread',
          'a message cost a whole refresh, and a quick exchange ran into the rate limit');
      });
      it('keeps the half-typed message and the keyboard', function () {
        const box = composeOnScreen(app);
        eq(box && box.value, 'half a sen');
        truthy(app.document.activeElement === box, 'the focus left the box');
      });
    })();

    await (async function aFullRefreshKeepsTheKeyboard() {
      const app = openApp({ ok: true, data: [] });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Message');
      await settle(); await settle();
      const input = composeOnScreen(app);
      truthy(input, 'in the thread');
      input.focus();
      input.value = 'still typing';
      input.oninput();
      // Somebody accepted: the whole page refreshes, not only the thread.
      app.sandbox.window._message({ data: { type: 'push', reason: 'accepted' } });
      const due = app.timers.filter(function (t) { return t.ms === 250; });
      if (due.length) { due[due.length - 1].fn(); }
      for (let i = 0; i < 5; i++) { await settle(); }
      it('keeps the keyboard through a refresh a push caused', function () {
        const box = composeOnScreen(app);
        eq(box && box.value, 'still typing');
        truthy(box && app.document.activeElement === box,
          'a push redrew the thread and the focus left the box mid-sentence');
      });
    })();

    await (async function aRedrawAwayFromTheBoxDoesNotGrabIt() {
      const app = openApp({ ok: true, data: [] });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      click(app, 'Message');
      await settle(); await settle();
      app.document.activeElement = null;
      app.sandbox.window._message({ data: { type: 'push', reason: 'message' } });
      for (let i = 0; i < 4; i++) { await settle(); }
      it('does not raise the keyboard for a player who was not typing', function () {
        const box = composeOnScreen(app);
        truthy(box, 'still in the thread');
        falsy(app.document.activeElement === box, 'the keyboard came up on its own');
      });
    })();

    /* A thread opens on its latest message, and follows the conversation
       down only for a player who is already at the bottom of it. The shim
       has no layout, so the view's measurements are set by hand. */
    await (async function aThreadOpensOnTheLatestMessage() {
      const app = openApp({ ok: true, data: [{ alias: 'The client', body: 'hello' }] });
      await settle(); await settle();
      tab(app, 'mine');
      await settle();
      app.view.scrollTop = 0; app.view.scrollHeight = 2700; app.view.clientHeight = 640;
      click(app, 'Message');
      await settle(); await settle();
      it('scrolls to the newest message and the compose box', function () {
        eq(app.view.scrollTop, 2700, 'the thread opened on its oldest message');
      });
      it('names the contract and who the thread is with', function () {
        const text = app.view.textContent;
        truthy(text.indexOf('Dana Reyes') !== -1 && text.indexOf('with the person who placed it') !== -1,
          'two threads from anonymous clients looked exactly alike: ' + text.slice(0, 120));
      });

      // Scrolled up to read something older: a reply must not yank them down.
      app.view.scrollTop = 300; app.view.scrollHeight = 2800;
      app.sandbox.window._message({ data: { type: 'push', reason: 'message' } });
      for (let i = 0; i < 4; i++) { await settle(); }
      it('leaves a player reading older messages where they are', function () {
        eq(app.view.scrollTop, 300);
      });

      // At the bottom: the reply is followed down.
      app.view.scrollTop = 2200; app.view.scrollHeight = 2900;
      app.sandbox.window._message({ data: { type: 'push', reason: 'message' } });
      for (let i = 0; i < 4; i++) { await settle(); }
      it('follows a reply down for a player at the bottom', function () {
        eq(app.view.scrollTop, 2900);
      });
    })();
  })();

  /* The time left, on the card, from the server's own reading.

     No card showed it: a staked hitman could not see when their stake
     would go. And a countdown to the deadline alone runs through a pause,
     so the reading has to say when the clock is stopped, and a card at zero
     must never say the time has run out on a contract still alive. */
  await (async function cardsShowTheClock() {
    const board = JSON.parse(JSON.stringify(BOARD));
    board.data.contracts[0].secondsLeft = 5400;
    const mine = { ok: true, data: {
      created: [{
        id: 'ct00000002', reason: 'Debt', mode: 'exclusive', state: 'active',
        reward: { baseline: 0, goods: { items: 1, weapons: 0, labels: ['Gold Bar'] } },
        slots: 3, slotsClaimed: 1, currentSlot: 2, hitmenActive: 0,
        targetName: 'Bo Renn', role: 'creator', creatorAnonymous: true,
        secondsLeft: 600, clockStopped: true
      }],
      accepted: [{
        id: 'ct00000003', reason: 'Debt', mode: 'competitive', state: 'accepted',
        reward: { baseline: 10000 }, slots: 1, currentSlot: 1,
        hitmenActive: 3, hitmenMax: 5, targetName: 'Rico Alvarez', role: 'hitman',
        penaltyAmount: 10000, myAlias: 'Operative #1', myAnonymous: true,
        secondsLeft: 1200
      }, {
        id: 'ct00000004', reason: 'Debt', mode: 'exclusive', state: 'accepted',
        reward: { baseline: 2000 }, slots: 1, currentSlot: 1, hitmenActive: 1,
        targetName: 'Sam Hale', role: 'hitman', penaltyAmount: 500,
        myAlias: 'Operative #2', myAnonymous: false, secondsLeft: 0,
        deadline: Math.floor(Date.now() / 1000) - 3600
      }],
      onMe: []
    } };
    const app = boot({ list: board, mine: mine, ledger: LEDGER });
    await settle(); await settle();

    it('shows the time left on a board card', function () {
      truthy(app.view.textContent.indexOf('1h 30m left') !== -1, app.view.textContent);
    });

    tab(app, 'mine');
    await settle(); await settle();
    const shown = app.view.textContent;

    it('says a paused clock is stopped rather than counting it down', function () {
      truthy(shown.indexOf('Clock stopped · 10 minutes left') !== -1, shown);
    });
    it('tells a staked hitman their stake is at risk when time is short', function () {
      truthy(shown.indexOf('20 minutes left · stake at risk') !== -1, shown);
    });
    it('never says a live contract is out of time', function () {
      falsy(/out of time/i.test(shown), shown);
      truthy(shown.indexOf('Due now') !== -1, shown);
    });
    it('says who the hitman is on it, and counts only the others', function () {
      truthy(shown.indexOf('You: Operative #1 · anonymous') !== -1, shown);
      truthy(shown.indexOf('+2 rivals') !== -1, shown);
      truthy(shown.indexOf('You: Operative #2 · under your name') !== -1, shown);
      falsy(shown.indexOf('1 operative') !== -1, 'their own card counted them: ' + shown);
    });
    it('tells a client where their contract stands', function () {
      truthy(shown.indexOf('Open again — no hitman yet') !== -1, shown);
      truthy(shown.indexOf('1 of 3 payouts collected') !== -1, shown);
      truthy(shown.indexOf('Placed anonymously') !== -1, shown);
    });
    it('stamps a goods-only payout with what it pays, not $0', function () {
      falsy(shown.indexOf('$0') !== -1, shown);
      truthy(shown.indexOf('Goods') !== -1, shown);
    });

    const ticker = app.timers.filter(function (t) { return t.repeating && t.ms === 30000; })[0];
    it('keeps the clocks moving while cards are on screen', function () {
      truthy(ticker && !ticker.cleared, 'nothing moves the clocks on');
      ticker.fn();
      truthy(app.view.textContent.indexOf('Clock stopped · 10 minutes left') !== -1,
        app.view.textContent);
    });

    tab(app, 'ledger');
    await settle(); await settle();
    it('stops the clock ticker when no card is showing', function () {
      truthy(ticker.cleared, 'the ticker ran on behind the ledger');
    });
  })();

  /* Black money said portion by portion, not summed under the base. */
  await (async function blackMoneyByPortion() {
    const board = JSON.parse(JSON.stringify(BOARD));
    board.data.contracts[0].reward = { baseline: 150000, bonus: 75000,
      sources: { cash: 100000, dirty: 50000 }, bonusSources: { cash: 50000, dirty: 25000 } };
    const app = boot({ list: board, mine: MINE, ledger: LEDGER });
    await settle(); await settle();
    it('says how much of the base and of the bonus is dirty money', function () {
      truthy(app.view.textContent.indexOf('$50,000 of this is dirty money, and $25,000 of the kidnapping bonus') !== -1,
        app.view.textContent);
      falsy(app.view.textContent.indexOf('$75,000 of it') !== -1, app.view.textContent);
    });
  })();


  /* Notices that last long enough to read, and go when tapped. Every one
     cleared after a flat four seconds, including thirty-word instructions to
     a hitman back from the camera and the answer a $25,000 informant gave. */
  await (async function noticesLongEnoughToRead() {
    const held = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    held.role = 'hitman';
    function onHeld(over) {
      return boot(Object.assign({
        list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
        mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
        ledger: LEDGER
      }, over));
    }
    function noticeNode(app) { return app.document.getElementById('notice').children[0]; }

    const refused = onHeld({ takeVerificationPhoto: { ok: false, err: 'no_kill_to_verify' } });
    await settle(); await settle();
    tab(refused, 'mine');
    await settle();
    click(refused, 'Verify kill');
    await settle(); await settle();
    const shown = refused.notice();
    const timed = refused.timers.filter(function (t) { return t.ms >= 4000 && !t.repeating; });
    const kept = refused.view.all().filter(function (n) {
      return /\bis-refusal\b/.test(n.className || '');
    });

    it('keeps a refusal up until the player taps, rather than timing it out', function () {
      truthy(shown.indexOf('Down is not dead') !== -1, shown);
      eq(timed.length, 0, 'a refusal set a timer: ' + timed.map(function (t) { return t.ms; }));
    });

    it('keeps the photo refusal under the card\'s buttons as well', function () {
      eq(kept.length, 1, refused.view.textContent);
      eq(kept[0].textContent, shown);
    });

    it('clears a refusal on the next tap anywhere', function () {
      const listeners = refused.document._listeners.click || [];
      truthy(listeners.length > 0, 'nothing listens for the next tap');
      listeners.forEach(function (fn) { fn({}); });
      eq(refused.notice(), '', 'the refusal outlived the next tap');
    });

    /* A car bomb, a grenade, a fire: the target's own game named this
       hitman, and the server saw nothing of theirs land. "Down is not dead"
       said nothing to somebody who had just blown them up. */
    const unseen = onHeld({ takeVerificationPhoto: { ok: false, err: 'kill_unobserved' } });
    await settle(); await settle();
    tab(unseen, 'mine');
    await settle();
    click(unseen, 'Verify kill');
    await settle(); await settle();
    const unseenSaid = unseen.notice();
    it('tells a bomber why their kill pays nobody', function () {
      truthy(unseenSaid.indexOf('explosives') !== -1, unseenSaid);
      falsy(unseenSaid.indexOf('Down is not dead') !== -1, unseenSaid);
    });

    const paid = onHeld({ takeVerificationPhoto: { ok: true, data: { pending: true } } });
    await settle(); await settle();
    tab(paid, 'mine');
    await settle();
    click(paid, 'Verify kill');
    await settle(); await settle();
    const message = paid.notice();
    const lifetime = paid.timers.filter(function (t) { return t.ms >= 4000 && !t.repeating; })
      .map(function (t) { return t.ms; });

    it('gives a long confirmation as long as it takes to read', function () {
      eq(lifetime.length, 1, 'timers: ' + lifetime);
      eq(lifetime[0], Math.min(12000, 1200 + 55 * message.length));
      truthy(lifetime[0] > 4000, 'still the flat four seconds');
    });

    it('draws a confirmation as one, not as the sworn-officer caution', function () {
      truthy(/\bok\b/.test(noticeNode(paid).className), noticeNode(paid).className);
      falsy(/\bgold\b/.test(noticeNode(paid).className), noticeNode(paid).className);
    });

    it('dismisses a notice when it is tapped', function () {
      noticeNode(paid).onclick();
      eq(paid.notice(), '', 'the notice swallowed the tap and stayed');
    });

    it('drops the refusal from the card once the hitman tries again', function () {
      falsy(paid.view.all().some(function (n) { return /\bis-refusal\b/.test(n.className || ''); }),
        paid.view.textContent);
    });
  })();

  /* The informant's answer, kept on the card it was paid for, and the
     dialog saying when asking again is free. */
  await (async function informantAnswerKept() {
    const own = { id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'active',
      reward: { baseline: 5000, bonus: 2500 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 1, hitmenMax: 5, hitmen: [{ alias: 'Grey' }],
      targetName: 'Dana Reyes', role: 'creator', informantAnswer: 'Rook Ash' };
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {
        informant: { cost: 25000, account: 'bank', maxPerContract: 2,
          repeatFreeMinutes: 30, askEverySeconds: 300 } } } },
      mine: { ok: true, data: { created: [own], accepted: [], onMe: [] } },
      ledger: LEDGER
    });
    await settle(); await settle();
    tab(app, 'mine');
    await settle(); await settle();

    it('keeps what the informant said on the card', function () {
      truthy(app.view.textContent.indexOf('Informant: Rook Ash') !== -1, app.view.textContent);
    });

    click(app, 'Buy informant data');
    it('says a repeat inside the window is free, from the server\'s figures', function () {
      truthy(app.view.textContent.indexOf('between 5 and 30 minutes after an answer') !== -1,
        app.view.textContent);
    });
  })();

  /* Accept and Buy out: busy while the request runs, and a shortfall that
     says how much and from where. */
  await (async function acceptAndBuyout() {
    let release;
    const board = JSON.parse(JSON.stringify(BOARD));
    board.data.contracts[0].penaltyAmount = 5000;
    board.data.settings.anonymityFees = { creator: 0, hitman: 1000, account: 'bank' };
    const slow = boot({ list: board, mine: MINE, ledger: LEDGER,
      accept: function () { return new Promise(function (r) { release = r; }); } });
    await settle(); await settle();
    click(slow, 'Accept contract');
    click(slow, 'Anonymously');
    await settle(); await settle();
    const busy = slow.view.all().filter(function (n) {
      return n.tagName === 'BUTTON' && n.textContent === 'Accepting…';
    });
    it('disables Accept while the acceptance is in flight', function () {
      eq(busy.length, 1, slow.view.textContent);
      truthy(busy[0].disabled, 'still live mid-request');
    });
    release({ ok: false, err: 'insufficient_funds' });
    await settle(); await settle();
    it('names the stake, the fee and where each comes from', function () {
      const said = slow.notice();
      truthy(said.indexOf('$5,000') !== -1 && said.indexOf('not split') !== -1
        && said.indexOf('$1,000 in your bank') !== -1, said);
    });

    const target = { id: 'ct00000002', reason: 'x', mode: 'exclusive', state: 'active',
      reward: { baseline: 5000 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 0, targetName: 'You', role: 'target',
      bailoutAmount: 90000, bailoutAvailable: true };
    const broke = boot({ list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [], onMe: [target] } },
      ledger: LEDGER, bailout: { ok: false, err: 'insufficient_funds' } });
    await settle(); await settle();
    tab(broke, 'onme');
    await settle(); await settle();
    click(broke, 'Buy out — $90,000');
    it('says before paying that a buyout is never split', function () {
      truthy(broke.view.textContent.indexOf('never split') !== -1, broke.view.textContent);
    });
    click(broke, 'Pay $90,000');
    await settle(); await settle();
    it('says a buyout short of money is taken whole from one account', function () {
      truthy(broke.notice().indexOf('$90,000') !== -1
        && broke.notice().indexOf('never split') !== -1, broke.notice());
    });
  })();

  /* What the server says was missing, worded from its figures; Accept held
     until the refresh after it lands; the exclusive windows on the card;
     a push re-reading only the contracts it names; and Close. */
  await (async function refusalDataAndHolds() {
    const board = JSON.parse(JSON.stringify(BOARD));
    board.data.contracts[0].penaltyAmount = 5000;
    board.data.settings.anonymityFees = { creator: 0, hitman: 1000, account: 'bank' };
    let acceptReply = { ok: false, err: 'insufficient_funds',
      data: { part: 'fee', need: 1500, account: 'cash' } };
    const app = boot({ list: board, mine: MINE, ledger: LEDGER,
      accept: function () { return acceptReply; } });
    await settle(); await settle();
    click(app, 'Accept contract');
    it('dismisses a choice with Close, not a second Cancel', function () {
      const labels = app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      truthy(labels.indexOf('Close') !== -1 && labels.indexOf('Cancel') === -1, labels.join(' | '));
    });
    click(app, 'Anonymously');
    await settle(); await settle();
    it('names only the fee, at the server\'s figure and account, when that is what is short', function () {
      const said = app.notice();
      truthy(said.indexOf('Anonymity costs $1,500 from your cash') !== -1, said);
      eq(said.indexOf('stake'), -1, said);
    });

    // Back on a contract whose anonymity they already paid for: the server
    // charges no fee, and says so, so the setting's $1,000 is not named.
    acceptReply = { ok: false, err: 'insufficient_funds',
      data: { part: 'stake', need: 2000, account: 'bank_or_cash', fee: 0 } };
    click(app, 'Accept contract');
    click(app, 'Anonymously');
    await settle(); await settle();
    it('names no anonymity fee on a stake refusal when the server says none is owed', function () {
      const said = app.notice();
      truthy(said.indexOf('$2,000') !== -1 && said.indexOf('not split') !== -1, said);
      eq(said.indexOf('anonymity'), -1, said);
    });

    acceptReply = { ok: false, err: 'limit_reached', data: { max: 3 } };
    click(app, 'Accept contract');
    click(app, 'Under my name');
    await settle(); await settle();
    it('says how many contracts a hitman may hold', function () {
      truthy(app.notice().indexOf('already working 3 contracts, the most this server allows')
        !== -1, app.notice());
    });

    /* Held through the refresh. The reply landed, the key cleared, and the
       board still had the card as it was: Accept came back live under the
       notice saying it was taken. */
    let lists = 0;
    let releaseList;
    const taken = JSON.parse(JSON.stringify(board));
    taken.data.contracts[0].role = 'hitman';
    const held = boot({ list: function () {
      lists += 1;
      if (lists === 1) { return board; }
      return new Promise(function (r) { releaseList = r; });
    }, mine: MINE, ledger: LEDGER, accept: { ok: true, data: { myAnonymous: false } } });
    await settle(); await settle();
    click(held, 'Accept contract');
    click(held, 'Under my name');
    await settle(); await settle(); await settle();
    it('keeps Accept disabled until the refresh after it lands', function () {
      truthy(held.notice().indexOf('Contract accepted') !== -1, held.notice());
      const busy = held.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Accepting…';
      });
      eq(busy.length, 1, held.view.textContent);
      truthy(busy[0].disabled);
    });
    releaseList(taken);
    await settle(); await settle(); await settle();
    it('lets it go once the board shows the contract taken', function () {
      const labels = held.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
      eq(labels.indexOf('Accepting…'), -1, labels.join(' | '));
      eq(labels.indexOf('Accept contract'), -1, labels.join(' | '));
    });

    const target = { id: 'ct00000002', reason: 'x', mode: 'exclusive', state: 'active',
      reward: { baseline: 5000 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 0, targetName: 'You', role: 'target',
      bailoutAmount: 90000, bailoutAvailable: true };
    const broke = boot({ list: { ok: true, data: { page: 1, pages: 1, contracts: [], settings: {} } },
      mine: { ok: true, data: { created: [], accepted: [], onMe: [target] } },
      ledger: LEDGER, bailout: { ok: false, err: 'insufficient_funds',
        data: { part: 'buyout', need: 95000, account: 'bank_or_cash' } } });
    await settle(); await settle();
    tab(broke, 'onme');
    await settle(); await settle();
    click(broke, 'Buy out — $90,000');
    click(broke, 'Pay $90,000');
    await settle(); await settle();
    it('names the price the server asked, not the one on the card', function () {
      truthy(broke.notice().indexOf('$95,000') !== -1, broke.notice());
    });

    // The windows, on the card the hitman looks at while they work it.
    const mine = { id: 'ct00000003', reason: 'x', mode: 'exclusive', state: 'accepted',
      reward: { baseline: 5000 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 1, targetName: 'Dana Reyes', role: 'hitman', myAlias: 'Operative #1' };
    const working = boot({ list: { ok: true, data: { page: 1, pages: 1, contracts: [],
        settings: { exclusiveIdleMinutes: 30, exclusiveAttemptMinutes: 120 } } },
      mine: { ok: true, data: { created: [], accepted: [mine], onMe: [] } },
      ledger: LEDGER, amendments: { ok: true, data: [] } });
    await settle(); await settle();
    tab(working, 'mine');
    await settle(); await settle();
    it('reminds a hitman on their card what takes an exclusive back', function () {
      truthy(working.view.textContent.indexOf('Exclusive: going 30 minutes without going near '
        + 'them, or 2h without an attempt, while they are in the city puts it back on the '
        + 'board') !== -1, working.view.textContent);
    });

    // W016 and W019: the rule the hitman agrees to is the one applied. Going
    // idle forfeits the stake as walking away does, and a full competitive
    // contract releases the idle too.
    async function acceptDialogFor(mode) {
      const offer = { id: 'ct00000004', reason: 'x', mode: mode, state: 'active',
        reward: { baseline: 5000 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
        hitmenActive: 0, hitmenMax: 5, targetName: 'Dana Reyes', role: 'public',
        penaltyAmount: 2000, deadline: Math.floor(Date.now() / 1000) + 3 * 3600 };
      const app = boot({ list: { ok: true, data: { page: 1, pages: 1, contracts: [offer],
          settings: { exclusiveIdleMinutes: 30, exclusiveAttemptMinutes: 120 } } },
        mine: MINE, ledger: LEDGER });
      await settle(); await settle();
      click(app, 'Accept contract');
      await settle();
      return app.view.textContent;
    }
    const exclusiveTerms = await acceptDialogFor('exclusive');
    it('tells a staked hitman that going idle hands the stake over, as walking away does', function () {
      truthy(exclusiveTerms.indexOf('Walk away, go idle or run out of time and your stake goes '
        + 'to the person who placed it.') !== -1, exclusiveTerms);
      falsy(exclusiveTerms.indexOf('your stake comes back') !== -1, exclusiveTerms);
    });
    const competitiveTerms = await acceptDialogFor('competitive');
    it('tells a competitive hitman what going idle costs while it is full', function () {
      truthy(competitiveTerms.indexOf('While it is full, going 30 minutes without going near '
        + 'them') !== -1 && competitiveTerms.indexOf('gives your place and your stake up.') !== -1,
        competitiveTerms);
    });

    // A push naming one contract re-reads that one's proposals, not every card's.
    const own = [1, 2, 3].map(function (i) {
      return { id: 'ct0000001' + i, reason: 'x', mode: 'competitive', state: 'active',
        reward: { baseline: 5000 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
        hitmenActive: 0, targetName: 'Dana ' + i, role: 'creator', hitmen: [] };
    });
    const asked = [];
    const pushed = boot({ list: BOARD, ledger: LEDGER,
      mine: { ok: true, data: { created: own, accepted: [], onMe: [] } },
      amendments: function (body) { asked.push(body.id); return { ok: true, data: [] }; } });
    await settle(); await settle(); await settle();
    tab(pushed, 'mine');
    await settle(); await settle(); await settle();
    function pushNow(data) {
      asked.length = 0;
      pushed.sandbox.window._message({ data: Object.assign({ type: 'push' }, data) });
      const due = pushed.timers.filter(function (t) { return t.ms === 250 && !t.cleared; });
      due[due.length - 1].fn();
    }
    pushNow({ reason: 'proposal', ids: ['ct00000012'] });
    await settle(); await settle(); await settle();
    it('re-reads only the contract a push names', function () {
      eq(JSON.stringify(asked), JSON.stringify(['ct00000012']));
    });
    pushNow({ reason: 'settled' });
    await settle(); await settle(); await settle();
    it('re-reads every contract when a push names none', function () {
      eq(JSON.stringify(asked.slice().sort()),
        JSON.stringify(['ct00000011', 'ct00000012', 'ct00000013']));
    });
    drewCleanly(app); drewCleanly(held); drewCleanly(broke); drewCleanly(working); drewCleanly(pushed);
  })();

  /* Live transfer only (Config.Completion.Fulfilment, shipped as 'alive').

     Each contract carries the rule it was placed under as `fulfilment`, and
     the board's settings carry the rule a contract placed now gets. The
     card, the accept dialog, Mine and the how-to follow the contract; the
     Place form follows the settings. Under 'alive' a kill completes
     nothing, so nothing offers one and nothing is priced "if alive"; under
     'either' the page is as it was. A card with no `fulfilment` is a
     contract from before the rule and reads as 'either', whatever new ones
     are placed under. */
  await (async function liveTransferOnly() {
    const KIDNAP = { radius: 10, seconds: 30 };
    function contractFor(rule, over) {
      const c = {
        id: 'ct00000001', reason: 'Unpaid debt', mode: 'competitive', state: 'active',
        // As the server places them: no bonus under 'alive'.
        reward: rule === 'alive' ? { baseline: 5000, bonus: 0 } : { baseline: 5000, bonus: 2500 },
        bonusPercent: rule === 'alive' ? 0 : 50,
        slots: 1, slotsClaimed: 0, currentSlot: 1, hitmenActive: 0, hitmenMax: 5,
        targetName: 'Dana Reyes', targetProtected: false,
        creatorName: 'Vic Marlowe', role: 'public',
        deadline: Math.floor(Date.now() / 1000) + 7500
      };
      if (rule !== undefined) { c.fulfilment = rule; }
      return Object.assign(c, over || {});
    }
    function boardFor(rule, contracts) {
      const settings = { kidnap: KIDNAP };
      if (rule !== undefined) { settings.fulfilment = rule; }
      return { ok: true, data: { page: 1, pages: 1, settings: settings, contracts: contracts || [] } };
    }
    function labels(app) {
      return app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
    }
    function button(app, label) {
      return app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === label;
      })[0] || null;
    }
    function chips(app) {
      return app.view.all().filter(function (n) { return n.classList.contains('chip'); })
        .map(function (n) { return n.textContent; });
    }

    // The board, and the dialog that takes a contract from it.
    async function onBoard(rule, cardRule) {
      const app = boot({ list: boardFor(rule, [contractFor(cardRule)]), mine: MINE,
        ledger: LEDGER, accept: { ok: true, data: { myAnonymous: true } } });
      await settle(); await settle();
      return app;
    }
    const aliveBoard = await onBoard('alive', 'alive');
    it('alive: the board card says the contract is alive only', function () {
      truthy(chips(aliveBoard).indexOf('Alive only') !== -1, chips(aliveBoard).join(' | '));
    });
    it('alive: and prices nothing "if alive"', function () {
      falsy(aliveBoard.view.textContent.indexOf('if alive') !== -1, aliveBoard.view.textContent);
    });
    click(aliveBoard, 'Accept contract');
    await settle();
    it('alive: the accept dialog says a kill does not complete it, and to whom they are taken', function () {
      truthy(aliveBoard.view.textContent.indexOf('This contract only pays when you bring the '
        + 'target, alive, to the person who placed it. Killing them does not count.') !== -1,
        aliveBoard.view.textContent);
      falsy(aliveBoard.view.textContent.toLowerCase().indexOf('client') !== -1,
        aliveBoard.view.textContent);
    });

    const eitherBoard = await onBoard('either', 'either');
    it('either: the board card is as it was, bonus "if alive" and no rule chip', function () {
      truthy(eitherBoard.view.textContent.indexOf('+$2,500 if alive') !== -1,
        eitherBoard.view.textContent);
      falsy(chips(eitherBoard).indexOf('Alive only') !== -1, chips(eitherBoard).join(' | '));
    });
    click(eitherBoard, 'Accept contract');
    await settle();
    it('either: and the accept dialog says nothing about it', function () {
      truthy(eitherBoard.view.textContent.indexOf('Take this one anonymously?') !== -1,
        eitherBoard.view.textContent);
      falsy(eitherBoard.view.textContent.indexOf('pays only for delivering') !== -1,
        eitherBoard.view.textContent);
    });

    // A hitman's own card under Mine, by a hitman who has not finished one,
    // so the how-to is drawn.
    async function working(rule, cardRule) {
      const held = contractFor(cardRule, { role: 'hitman', state: 'accepted',
        hitmenActive: 1, myAlias: 'Operative #1', myAnonymous: true });
      const app = boot({ list: boardFor(rule), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [held], onMe: [] } },
        amendments: { ok: true, data: [] }, armKidnap: { ok: true, data: {} } });
      await settle(); await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      return app;
    }
    const aliveWork = await working('alive', 'alive');
    it('alive: Mine offers Deliver alive and no Verify kill', function () {
      const shown = labels(aliveWork);
      falsy(shown.indexOf('Verify kill') !== -1, 'a kill can never pay here: ' + shown.join(' | '));
      truthy(button(aliveWork, 'Deliver alive'), shown.join(' | '));
    });
    it('alive: and Deliver alive is the card\'s primary', function () {
      truthy(button(aliveWork, 'Deliver alive').classList.contains('primary'),
        button(aliveWork, 'Deliver alive').className);
    });
    it('alive: the how-to says only a live delivery pays, with the server\'s handover terms', function () {
      const text = aliveWork.view.textContent;
      truthy(text.indexOf('Bring them in alive: cuff them or get them into your vehicle, take '
        + 'them to the person who placed this contract, get within 10 m of that person, tap '
        + 'Deliver alive and hold for 30 seconds. Killing them does not count \u2014 they '
        + 'respawn and the contract stays open.') !== -1, text);
      falsy(text.toLowerCase().indexOf('client') !== -1, 'nobody is "the client": ' + text);
      falsy(text.indexOf('Verify kill') !== -1, 'nothing tells them to photograph a body: ' + text);
      truthy(chips(aliveWork).indexOf('Alive only') !== -1, chips(aliveWork).join(' | '));
    });
    click(aliveWork, 'Deliver alive');
    await settle(); await settle();
    it('alive: Deliver alive still starts the handover', function () {
      eq(aliveWork.sent.filter(function (s) { return s.name === 'armKidnap'; }).length, 1);
    });
    const aliveTerms = await working('alive', 'alive');
    click(aliveTerms, 'Propose change');
    it('alive: a proposal states what it pays for, not a bonus "if alive"', function () {
      const text = aliveTerms.view.textContent;
      truthy(text.indexOf('Pays $5,000 for a live delivery') !== -1, text);
      falsy(text.indexOf('if alive') !== -1, text);
    });

    const eitherWork = await working('either', 'either');
    it('either: Mine offers both, Verify kill first', function () {
      truthy(button(eitherWork, 'Verify kill').classList.contains('primary'), labels(eitherWork).join(' | '));
      truthy(button(eitherWork, 'Deliver alive'), labels(eitherWork).join(' | '));
      falsy(button(eitherWork, 'Deliver alive').classList.contains('primary'),
        'one crimson button on a card');
    });
    it('either: the how-to explains both ways, as it did', function () {
      truthy(eitherWork.view.textContent.indexOf('Kill: a downed target is not dead. Finish '
        + 'them, then stand over the body and tap Verify kill to photograph it before they '
        + 'are revived. Alive: restrain them or get them into your vehicle, bring them '
        + 'within 10 m of the client, tap Deliver alive and hold for 30s.') !== -1,
        eitherWork.view.textContent);
    });
    const eitherTerms = await working('either', 'either');
    click(eitherTerms, 'Propose change');
    it('either: a proposal states the bonus "if alive", as it did', function () {
      truthy(eitherTerms.view.textContent.indexOf('Pays $5,000 (+$2,500 if alive)') !== -1,
        eitherTerms.view.textContent);
    });

    // The card follows the contract's own rule, not the server's rule for
    // new ones: a server switched to 'alive' still pays a kill on what was
    // taken before, and one switched back still does not on what was not.
    const older = await working('alive', undefined);
    it('a contract stored before the rule still offers Verify kill on an alive server', function () {
      truthy(button(older, 'Verify kill'), labels(older).join(' | '));
      falsy(chips(older).indexOf('Alive only') !== -1, chips(older).join(' | '));
      truthy(older.view.textContent.indexOf('Kill: a downed target is not dead.') !== -1,
        older.view.textContent);
    });
    const kept = await working('either', 'alive');
    it('an alive contract offers no kill on a server since switched to either', function () {
      falsy(button(kept, 'Verify kill'), labels(kept).join(' | '));
      truthy(chips(kept).indexOf('Alive only') !== -1, chips(kept).join(' | '));
    });

    // The client's own card, and adding to it.
    async function placed(rule) {
      const own = contractFor(rule, { role: 'creator', hitmen: [] });
      const app = boot({ list: boardFor(rule), ledger: LEDGER,
        mine: { ok: true, data: { created: [own], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] },
        rewardBreakdown: { ok: true, data: { editable: true, slots: 1, currentSlot: 1,
          lines: [{ id: 'ct00000001:1', slot: 1, portion: 'baseline',
                    source: 'cash', amount: 5000, withdrawable: true }] } },
        rewardOptions: { ok: true, data: { cash: 100000, bank: 50000, dirty: 0,
          items: [], weapons: [], inventoryRead: true,
          caps: { bonusPercent: 100, cash: 250000, bank: 500000, itemsEnabled: false,
                  weaponsEnabled: false, cashEnabled: true, bankEnabled: true,
                  dirtyEnabled: false } } }
      });
      await settle(); await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      return app;
    }
    const aliveOwn = await placed('alive');
    it('alive: the client\'s card under Mine says it is alive only', function () {
      truthy(chips(aliveOwn).indexOf('Alive only') !== -1, chips(aliveOwn).join(' | '));
    });
    click(aliveOwn, 'Change reward'); await settle(); await settle();
    click(aliveOwn, 'Add to it'); await settle(); await settle();
    it('alive: adding to it offers money, and no kidnapping bonus to raise', function () {
      const shown = labels(aliveOwn);
      truthy(shown.indexOf('Cash') !== -1 && shown.indexOf('Bank') !== -1, shown.join(' | '));
      falsy(shown.indexOf('Kidnapping bonus') !== -1, 'the server refuses one: ' + shown.join(' | '));
    });
    const eitherOwn = await placed('either');
    click(eitherOwn, 'Change reward'); await settle(); await settle();
    click(eitherOwn, 'Add to it'); await settle(); await settle();
    it('either: adding to it still offers the kidnapping bonus', function () {
      truthy(labels(eitherOwn).indexOf('Kidnapping bonus') !== -1, labels(eitherOwn).join(' | '));
    });

    // The target is shown the term like the others.
    const hunted = boot({ list: boardFor('alive'), ledger: LEDGER,
      mine: { ok: true, data: { created: [], accepted: [], onMe: [
        contractFor('alive', { role: 'target', hitmenActive: 1, creatorName: undefined,
          creatorAnonymous: true, bailoutAmount: 15000, bailoutAvailable: true })] } } });
    await settle(); await settle(); await settle();
    tab(hunted, 'onme');
    await settle();
    it('alive: the target\'s card says it too', function () {
      truthy(chips(hunted).indexOf('Alive only') !== -1, chips(hunted).join(' | '));
    });

    // The Place form, from the settings.
    function chooseDana(app) {
      const query = pick(app, 'target-query');
      query.value = 'Dana';
      query.oninput();
      app.timers.filter(function (t) { return t.ms === 300; }).forEach(function (t) { t.fn(); });
    }
    async function placing(rule, list, more) {
      const app = placeForm(Object.assign({
        list: list || boardFor(rule),
        create: function (body) {
          app.body = body;
          return { ok: true, data: Object.assign({ penaltyAmount: 0, secondsLeft: 10800 },
            (more && more.created) || {}) };
        }
      }, more && more.rewardOptions ? { rewardOptions: more.rewardOptions } : {}));
      await settle(); await settle();
      tab(app, 'place');
      await settle(); await settle();
      chooseDana(app);
      await settle(); await settle();
      app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent.indexOf('Dana Reyes') === 0;
      })[0].onclick();
      return app;
    }
    const total = function (app) { return app.document.getElementById('place-total').textContent; };

    const alivePlace = await placing('alive');
    it('alive: the Place form draws no bonus and no alive-only marking', function () {
      falsy(alivePlace.document.getElementById('bonus'), 'the bonus field is drawn');
      falsy(alivePlace.document.getElementById('slot-alive-1'), 'the alive-only toggle is drawn');
      falsy(alivePlace.view.textContent.indexOf('Kidnapping bonus') !== -1, alivePlace.view.textContent);
      falsy(alivePlace.view.textContent.indexOf('Only if delivered alive') !== -1,
        alivePlace.view.textContent);
      falsy(alivePlace.view.textContent.indexOf('kidnapping bonus included') !== -1,
        'the buyout hint names a bonus there is none of: ' + alivePlace.view.textContent);
    });
    it('alive: and says contracts pay only when the target is brought to the placer alive', function () {
      truthy(alivePlace.view.textContent.indexOf('Contracts here only pay when the target is '
        + 'brought to you alive. You need to be in the city to meet the hitman for the '
        + 'handover.') !== -1, alivePlace.view.textContent);
    });
    pick(alivePlace, 'slot-cash-1', 40000);
    pick(alivePlace, 'slot-item-1').value = 'lockpick';
    press(alivePlace, 'slot-item-add-1');
    it('alive: the total is the reward alone, with nothing "alive only"', function () {
      eq(total(alivePlace), 'Taken from you now: $40,000 cash and Lockpick.');
      falsy(alivePlace.view.textContent.indexOf('alive only') !== -1, alivePlace.view.textContent);
    });
    press(alivePlace, 'place-submit');
    await settle(); await settle();
    it('alive: it is placed with no bonus, the goods in the payout itself', function () {
      truthy(alivePlace.body, 'nothing was placed');
      eq(alivePlace.body.bonusPercent, 0);
      const slot = alivePlace.body.reward.slots[0];
      eq(slot.baseline.cash, 40000);
      eq(JSON.stringify(slot.baseline.items), JSON.stringify([{ name: 'lockpick', count: 1 }]));
      falsy(slot.bonus, 'nothing set apart for a live delivery: ' + JSON.stringify(slot));
    });

    const eitherPlace = await placing('either');
    it('either: the Place form draws the bonus and the alive-only marking, as it did', function () {
      truthy(eitherPlace.document.getElementById('bonus'), 'no bonus field');
      truthy(eitherPlace.document.getElementById('slot-alive-1'), 'no alive-only toggle');
      truthy(eitherPlace.view.textContent.indexOf('kidnapping bonus included') !== -1,
        eitherPlace.view.textContent);
      falsy(eitherPlace.view.textContent.indexOf('Contracts here only pay') !== -1,
        eitherPlace.view.textContent);
    });
    pick(eitherPlace, 'slot-cash-1', 40000);
    press(eitherPlace, 'place-submit');
    await settle(); await settle();
    it('either: and places the bonus it shows', function () {
      eq(eitherPlace.body.bonusPercent, 50);
    });

    /* The rule arrives with the board. A form opened before it did drew
       the bonus, and a figure typed there is not sent once the board says
       contracts here carry none. */
    let answer = null;
    const early = await placing(undefined, function () {
      return new Promise(function (resolve) { answer = resolve; });
    });
    pick(early, 'bonus', 40);
    answer(boardFor('alive'));
    await settle(); await settle(); await settle();
    it('alive: a bonus typed before the board arrived is taken off the form', function () {
      falsy(early.document.getElementById('bonus'), 'still drawn once the rule is known');
    });
    pick(early, 'slot-cash-1', 40000);
    press(early, 'place-submit');
    await settle(); await settle();
    it('alive: and is not sent', function () {
      truthy(early.body, 'nothing was placed');
      eq(early.body.bonusPercent, 0);
    });

    /* And with the wallet, which the form reads every time it opens. With
       the board's read failed the form knew no rule, drew the bonus at 50%
       on a server that places none, and confirmed a bonus taken that never
       was: the server places the percentage as 0. */
    const BOARD_FAILED = { ok: false, err: 'server_error' };
    const blind = await placing(undefined, BOARD_FAILED, { rewardOptions: { ok: true,
      data: Object.assign({}, GOODS, { caps: Object.assign({}, GOODS.caps, { fulfilment: 'alive' }) }) } });
    it('alive, the board unread: the wallet says so, and no bonus or alive-only marking is drawn', function () {
      falsy(blind.document.getElementById('bonus'), 'the bonus field is drawn');
      falsy(blind.document.getElementById('slot-alive-1'), 'the alive-only toggle is drawn');
      truthy(blind.view.textContent.indexOf('Contracts here only pay when the target is '
        + 'brought to you alive') !== -1, blind.view.textContent);
    });
    pick(blind, 'slot-cash-1', 40000);
    it('alive, the board unread: the total is the reward alone', function () {
      eq(total(blind), 'Taken from you now: $40,000 cash.');
    });
    press(blind, 'place-submit');
    await settle(); await settle();
    it('alive, the board unread: no bonus is sent, and none is said to be held', function () {
      truthy(blind.body, 'nothing was placed');
      eq(blind.body.bonusPercent, 0);
      truthy(blind.notice().indexOf('Held from you: $40,000 cash.') !== -1, blind.notice());
      falsy(blind.notice().indexOf('bonus') !== -1, blind.notice());
    });

    // Neither read saying: the confirmation follows what the server placed.
    const unsaid = await placing(undefined, BOARD_FAILED, { created: { bonusPercent: 0 } });
    pick(unsaid, 'slot-cash-1', 40000);
    press(unsaid, 'place-submit');
    await settle(); await settle();
    it('placed with no bonus whatever was sent: the confirmation says only the reward was held', function () {
      truthy(unsaid.body, 'nothing was placed');
      eq(unsaid.body.bonusPercent, 50, 'the form could not know, and sent its figure');
      truthy(unsaid.notice().indexOf('Held from you: $40,000 cash.') !== -1, unsaid.notice());
      falsy(unsaid.notice().indexOf('kidnapping bonus') !== -1, unsaid.notice());
    });
    // And one the server placed as sent is confirmed as it was.
    const asSent = await placing(undefined, BOARD_FAILED, { created: { bonusPercent: 50 } });
    pick(asSent, 'slot-cash-1', 40000);
    press(asSent, 'place-submit');
    await settle(); await settle();
    it('placed with the bonus sent: the confirmation names it', function () {
      truthy(asSent.notice().indexOf('Held from you: $60,000 cash ($40,000 + $20,000 '
        + 'kidnapping bonus).') !== -1, asSent.notice());
    });

    /* ---------- to whom, said everywhere ----------
       On this server a contract pays only when the target is brought
       alive to the person who placed it, who has to be there. Every line
       says that person, never "the client", with the distance and the hold
       from the server's own Config.Kidnap (here 10 m and 30 s, then 7 m and
       45 s to show nothing is written in). None of it speaks of a photo:
       kill photos ship off. */
    function boardWith(rule, contracts, extra) {
      const b = boardFor(rule, contracts);
      Object.assign(b.data.settings, extra || {});
      return b;
    }
    const NO_PHOTOS = { killPhotos: false };
    function noClientNoPhoto(text, label) {
      falsy(/\bclient\b/i.test(text), label + ' names "the client": ' + text);
      falsy(/photo/i.test(text), label + ' speaks of a photo with kill photos off: ' + text);
    }

    const lineBoard = boot({ list: boardWith('alive', [contractFor('alive')], NO_PHOTOS),
      mine: MINE, ledger: LEDGER });
    await settle(); await settle();
    it('alive: the board card says, under the reward, to whom the target is brought', function () {
      const notes = lineBoard.view.all().filter(function (n) {
        return n.classList.contains('reward-notes');
      })[0];
      truthy(notes, 'no line under the reward');
      truthy(notes.textContent.indexOf('Bring the target alive to the person who placed this '
        + 'contract.') !== -1, notes.textContent);
      noClientNoPhoto(lineBoard.view.textContent, 'the board');
    });
    it('either: the board card has no such line', function () {
      falsy(eitherBoard.view.textContent.indexOf('Bring the target alive') !== -1,
        eitherBoard.view.textContent);
    });

    // The how-to, for a placer who is named and for one who is anonymous.
    async function workingOn(card, extra) {
      const app = boot({ list: boardWith('alive', [], extra), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [card], onMe: [] } },
        amendments: { ok: true, data: [] } });
      await settle(); await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      return app;
    }
    const heldFrom = function (over) {
      return contractFor('alive', Object.assign({ role: 'hitman', state: 'accepted',
        hitmenActive: 1, myAlias: 'Operative #1', myAnonymous: true }, over || {}));
    };
    const namedPlacer = await workingOn(heldFrom(), NO_PHOTOS);
    it('alive, named placer: the how-to names them, with no line about anonymity', function () {
      const text = namedPlacer.view.textContent;
      truthy(text.indexOf('The person who placed it is Vic Marlowe — use Message to agree '
        + 'where to meet.') !== -1, text);
      falsy(text.indexOf('is anonymous') !== -1, text);
      noClientNoPhoto(text, 'the how-to');
    });
    const anonPlacer = await workingOn(heldFrom({ creatorName: undefined, creatorAnonymous: true }),
      NO_PHOTOS);
    it('alive, anonymous placer: the how-to says so, and how to find them', function () {
      const text = anonPlacer.view.textContent;
      truthy(text.indexOf('Bring them in alive: cuff them or get them into your vehicle, take '
        + 'them to the person who placed this contract, get within 10 m of that person, tap '
        + 'Deliver alive and hold for 30 seconds. Killing them does not count — they '
        + 'respawn and the contract stays open. The person who placed it is anonymous — '
        + 'use Message to agree where to meet.') !== -1, text);
      falsy(text.indexOf('Vic') !== -1, 'an anonymous placer is named: ' + text);
      noClientNoPhoto(text, 'the how-to');
    });
    // Not a first-job hint on these: a hitman with jobs behind them (some
    // finished under 'either') was shown only the "Alive only" chip.
    const seasoned = boot({ list: boardWith('alive', [], NO_PHOTOS),
      ledger: { ok: true, data: { entries: [], record: { completed: 4, placed: 0, survived: 0,
        standing: 'Known' } } },
      mine: { ok: true, data: { created: [], accepted: [heldFrom({ creatorName: undefined,
        creatorAnonymous: true })], onMe: [] } },
      amendments: { ok: true, data: [] } });
    await settle(); await settle(); await settle();
    tab(seasoned, 'mine');
    await settle(); await settle();
    it('alive: the how-to is on the card for a hitman who has finished contracts before', function () {
      const text = seasoned.view.textContent;
      truthy(text.indexOf('take them to the person who placed this contract, get within 10 m of '
        + 'that person, tap Deliver alive and hold for 30 seconds.') !== -1, text);
      truthy(text.indexOf('The person who placed it is anonymous — use Message to agree where '
        + 'to meet.') !== -1, text);
      noClientNoPhoto(text, 'the how-to');
    });
    const quietPlacer = await workingOn(heldFrom({ creatorName: undefined, creatorAnonymous: true }),
      { killPhotos: false, relay: false });
    it('alive, anonymous placer, no messages: nothing offers Message', function () {
      falsy(quietPlacer.view.textContent.indexOf('use Message') !== -1, quietPlacer.view.textContent);
    });
    const otherTerms = await workingOn(heldFrom(), { killPhotos: false,
      kidnap: { radius: 7, seconds: 45 } });
    it('alive: the distance and the hold are the server\'s, not written in', function () {
      const text = otherTerms.view.textContent;
      truthy(text.indexOf('get within 7 m of that person, tap Deliver alive and hold for 45 '
        + 'seconds.') !== -1, text);
    });
    // Config.Kidnap.RequireCoercion off, as shipped: nothing tells the hitman
    // to cuff anybody, and it says plainly what the handover needs.
    const unrestrained = await workingOn(heldFrom(), { killPhotos: false,
      kidnap: { radius: 12, seconds: 30, restrain: false } });
    it('alive, no restraint required: the how-to says what is needed, and nothing about cuffs', function () {
      const text = unrestrained.view.textContent;
      truthy(text.indexOf('Bring them in alive: take them to the person who placed this '
        + 'contract, stay within 12 m of that person with them, tap Deliver alive and hold '
        + 'for 30 seconds. They have to stay alive, conscious and on their feet the whole '
        + 'time. Killing them does not count — they respawn and the contract stays '
        + 'open.') !== -1, text);
      falsy(/cuff|restrain|your vehicle/i.test(text), 'restraint is not needed here: ' + text);
      noClientNoPhoto(text, 'the how-to');
    });
    const unrestrainedKill = boot({ list: boardWith('alive', [], { killPhotos: false,
      kidnap: { radius: 12, seconds: 30, restrain: false } }), ledger: LEDGER,
      mine: { ok: true, data: { created: [], accepted: [heldFrom({ fulfilment: undefined })],
        onMe: [] } },
      amendments: { ok: true, data: [] },
      verifyKill: { ok: false, err: 'kill_not_allowed' } });
    await settle(); await settle(); await settle();
    tab(unrestrainedKill, 'mine');
    await settle(); await settle();
    click(unrestrainedKill, 'Verify kill');
    await settle(); await settle();
    it('alive, no restraint required: a refused kill says the same, and nothing about cuffs', function () {
      const said = unrestrainedKill.notice();
      truthy(said.indexOf('This contract only pays when you bring the target, alive, to the '
        + 'person who placed it. Bring them in alive: take them to the person who placed this '
        + 'contract, stay within 12 m of that person with them') !== -1, said);
      falsy(/cuff|restrain/i.test(said), said);
    });

    // The board chip names who placed it, as that.
    it('says who placed a contract, as that, on the hitman\'s card', function () {
      truthy(chips(namedPlacer).indexOf('Placed by Vic Marlowe') !== -1, chips(namedPlacer).join(' | '));
      truthy(chips(anonPlacer).indexOf('Placed anonymously') !== -1, chips(anonPlacer).join(' | '));
    });

    // A kill refused on such a contract, the card having offered one (a
    // contract stored before the rule, read as either by an older page).
    const refusedKill = boot({ list: boardWith('alive', [], NO_PHOTOS), ledger: LEDGER,
      mine: { ok: true, data: { created: [], accepted: [heldFrom({ fulfilment: undefined })],
        onMe: [] } },
      amendments: { ok: true, data: [] },
      verifyKill: { ok: false, err: 'kill_not_allowed' } });
    await settle(); await settle(); await settle();
    tab(refusedKill, 'mine');
    await settle(); await settle();
    click(refusedKill, 'Verify kill');
    await settle(); await settle();
    it('kill_not_allowed says what to do instead, with the server\'s terms', function () {
      const said = refusedKill.notice();
      truthy(said.indexOf('This contract only pays when you bring the target, alive, to the '
        + 'person who placed it. Bring them in alive: cuff them or get them into your '
        + 'vehicle, take them to the person who placed this contract, get within 10 m of '
        + 'that person, tap Deliver alive and hold for 30 seconds.') !== -1, said);
      noClientNoPhoto(said, 'the refusal');
    });

    // Deliver alive refused because the person who placed it is missing.
    async function armRefused(err, card) {
      const app = boot({ list: boardWith('alive', [], NO_PHOTOS), ledger: LEDGER,
        mine: { ok: true, data: { created: [], accepted: [card || heldFrom()], onMe: [] } },
        amendments: { ok: true, data: [] }, armKidnap: { ok: false, err: err } });
      await settle(); await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      click(app, 'Deliver alive');
      await settle(); await settle();
      return app.notice();
    }
    const tooFar = await armRefused('creator_too_far');
    it('creator_too_far says the person who placed it must be online and within the radius', function () {
      truthy(tooFar.indexOf('The person who placed this contract must be online and within '
        + '10 m of you and the target. Take the target to them, then tap Deliver alive '
        + 'again.') !== -1, tooFar);
      noClientNoPhoto(tooFar, 'the refusal');
    });
    const tooFarAnon = await armRefused('creator_too_far',
      heldFrom({ creatorName: undefined, creatorAnonymous: true }));
    it('and, for an anonymous one, how to find them', function () {
      truthy(tooFarAnon.indexOf('They are anonymous — use Message to agree where to '
        + 'meet.') !== -1, tooFarAnon);
    });
    const offline = await armRefused('party_offline');
    it('party_offline says the person who placed it must be in the city and within the radius', function () {
      truthy(offline.indexOf('the person who placed this contract must be in the city and '
        + 'within 10 m of you and the target.') !== -1, offline);
      noClientNoPhoto(offline, 'the refusal');
    });
    const downed = await armRefused('target_not_conscious');
    it('a dead or downed target says killing them does not count, and what does', function () {
      truthy(downed.indexOf('Killing them does not count — once they are back on their '
        + 'feet, bring them in alive.') !== -1, downed);
    });

    // The countdown, slipping because the person who placed it walked off,
    // at the radius this countdown was armed with.
    const slipping = await workingOn(heldFrom({ kidnapProgress: { elapsed: 5, required: 30,
      graceLeft: 1200, graceTotal: 3000, breaking: 'creator_too_far', radius: 8 } }), NO_PHOTOS);
    it('a slipping countdown says how close the person who placed it has to be', function () {
      truthy(slipping.view.textContent.indexOf('The person who placed this contract must be '
        + 'within 8 m of you and the target — handover fails in 1.2s') !== -1,
        slipping.view.textContent);
    });

    // How a failed handover is told, when the placer never came.
    const failedPage = boot({ list: boardWith('alive', [], NO_PHOTOS), ledger: LEDGER,
      mine: { ok: true, data: { created: [], accepted: [heldFrom()], onMe: [] } },
      amendments: { ok: true, data: [] },
      armKidnap: { ok: true, data: true },
      kidnapProgress: { ok: true, data: { done: true, outcome: 'failed', reason: 'creator_too_far' } } });
    await settle(); await settle(); await settle();
    tab(failedPage, 'mine');
    await settle(); await settle();
    click(failedPage, 'Deliver alive');
    await settle();
    failedPage.timers.filter(function (t) { return t.repeating && t.ms === 1000; })[0].fn();
    await settle(); await settle();
    it('a handover that failed for want of the placer says they must be online and within the radius', function () {
      const said = failedPage.notice();
      truthy(said.indexOf('The person who placed this contract did not arrive in time. They '
        + 'must be online and within 10 m of you and the target for the whole handover.') !== -1,
        said);
      noClientNoPhoto(said, 'the ending');
    });

    // The placer's own card under Mine, once a hitman has it.
    async function placedAndTaken(rule, active, extra) {
      const own = contractFor(rule, { role: 'creator', hitmenActive: active,
        hitmen: active ? [{ alias: 'Operative #1' }] : [] });
      const app = boot({ list: boardWith(rule, [], extra), ledger: LEDGER,
        mine: { ok: true, data: { created: [own], accepted: [], onMe: [] } },
        amendments: { ok: true, data: [] } });
      await settle(); await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      return app;
    }
    const TAKEN = 'A hitman took your contract. They’ll bring the target to you alive '
      + '— stay in the city and watch your messages.';
    const takenOwn = await placedAndTaken('alive', 1, NO_PHOTOS);
    it('alive: the placer\'s card says a hitman is bringing the target to them', function () {
      truthy(takenOwn.view.textContent.indexOf(TAKEN) !== -1, takenOwn.view.textContent);
      noClientNoPhoto(takenOwn.view.textContent, 'the placer\'s card');
    });
    const untakenOwn = await placedAndTaken('alive', 0, NO_PHOTOS);
    it('alive: and says nothing of it before anybody has taken it', function () {
      falsy(untakenOwn.view.textContent.indexOf('A hitman took your contract') !== -1,
        untakenOwn.view.textContent);
    });
    const eitherOwnTaken = await placedAndTaken('either', 1);
    it('either: the placer\'s card is as it was', function () {
      falsy(eitherOwnTaken.view.textContent.indexOf('A hitman took your contract') !== -1,
        eitherOwnTaken.view.textContent);
    });
    const quietOwn = await placedAndTaken('alive', 1, { killPhotos: false, relay: false });
    it('alive, no messages: the placer is not sent to their messages', function () {
      truthy(quietOwn.view.textContent.indexOf('They’ll bring the target to you alive '
        + '— stay in the city.') !== -1, quietOwn.view.textContent);
      falsy(quietOwn.view.textContent.indexOf('watch your messages') !== -1, quietOwn.view.textContent);
    });

    drewCleanly(lineBoard); drewCleanly(namedPlacer); drewCleanly(anonPlacer);
    drewCleanly(quietPlacer); drewCleanly(otherTerms); drewCleanly(refusedKill);
    drewCleanly(slipping); drewCleanly(failedPage); drewCleanly(takenOwn);
    drewCleanly(untakenOwn); drewCleanly(eitherOwnTaken); drewCleanly(quietOwn);

    drewCleanly(aliveBoard); drewCleanly(eitherBoard); drewCleanly(aliveWork);
    drewCleanly(eitherWork); drewCleanly(older); drewCleanly(kept); drewCleanly(aliveOwn);
    drewCleanly(eitherOwn); drewCleanly(hunted); drewCleanly(alivePlace);
    drewCleanly(eitherPlace); drewCleanly(early); drewCleanly(blind); drewCleanly(unsaid);
    drewCleanly(asSent);
  })();

  /* The handover's meeting point (server/meeting.lua). The placer's own
     card offers Set meeting point here, asked first, and Clear; a hitman's
     card says one is set and offers Set GPS. Neither sends, nor is sent,
     where it is: the placer's game reads it, and the hitman's game marks it
     (client/main.lua). */
  await (async function () {
    function meetingCard(extra) {
      return Object.assign({
        id: 'ct00000077', reason: 'Owes money', mode: 'competitive', state: 'accepted',
        fulfilment: 'alive', reward: { baseline: 5000, bonus: 0 }, slots: 1, slotsClaimed: 0,
        currentSlot: 1, hitmenActive: 1, hitmenMax: 5, targetName: 'Dana Reyes',
        targetProtected: false, role: 'creator', penaltyAmount: 0,
        deadline: Math.floor(Date.now() / 1000) + 3 * 3600,
        hitmen: [{ alias: 'Operative #1', claims: 0 }]
      }, extra || {});
    }
    function hitmanCard(extra) {
      return meetingCard(Object.assign({ role: 'hitman', hitmen: undefined,
        myAlias: 'Operative #1', creatorAnonymous: true }, extra || {}));
    }
    const board = { ok: true, data: { page: 1, pages: 1, contracts: [],
      settings: { relay: true, calls: false, amendments: true, buyouts: true,
        fulfilment: 'alive', killPhotos: false, kidnap: { radius: 12, seconds: 30 } } } };
    async function mineWith(created, accepted, extra) {
      const app = boot(Object.assign({ list: board, ledger: LEDGER,
        mine: { ok: true, data: { created: created, accepted: accepted, onMe: [] } },
        amendments: { ok: true, data: [] } }, extra || {}));
      await settle(); await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      return app;
    }
    function sentNamed(app, name) {
      return app.sent.filter(function (entry) { return entry.name === name; });
    }
    function labels(app) {
      return app.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
    }

    const unset = await mineWith([meetingCard({ creatorName: 'Vic Marlowe', meetingSet: false })],
      [], { setMeeting: { ok: true, data: { set: true, moved: false } } });
    it('placer: offers to set one where they stand, saying the hitman sees the spot', function () {
      const text = unset.view.textContent;
      truthy(text.indexOf('No meeting point set.') !== -1, text);
      truthy(text.indexOf('Set meeting point here shows the hitman on this contract the spot '
        + 'where you are standing.') !== -1, text);
      truthy(labels(unset).indexOf('Set meeting point here') !== -1, labels(unset).join(' | '));
      eq(labels(unset).indexOf('Clear'), -1, 'nothing to clear');
    });
    click(unset, 'Set meeting point here');
    await settle();
    it('placer: asks first, saying who will see it', function () {
      const text = unset.view.textContent;
      truthy(text.indexOf('Set the meeting point where you are standing?') !== -1, text);
      truthy(text.indexOf('Every hitman on this contract will see this spot on their GPS. Stand '
        + 'where you want to meet them, then tap Set.') !== -1, text);
      eq(sentNamed(unset, 'setMeeting').length, 0, 'nothing sent before Set');
    });
    click(unset, 'Set');
    await settle(); await settle();
    it('placer: sends which contract and nothing of where, which the game reads', function () {
      const posts = sentNamed(unset, 'setMeeting');
      eq(posts.length, 1);
      eq(JSON.stringify(Object.keys(posts[0].body)), JSON.stringify(['id']));
      eq(posts[0].body.id, 'ct00000077');
      truthy(unset.notice().indexOf('Meeting point set where you are standing.') !== -1,
        unset.notice());
    });

    const anon = await mineWith([meetingCard({ creatorAnonymous: true, meetingSet: true })], [],
      { clearMeeting: { ok: true, data: { cleared: true } } });
    it('placer, anonymous: told the hitman sees the spot, not who they are', function () {
      const text = anon.view.textContent;
      truthy(text.indexOf('Meeting point set. The hitman can follow it on their GPS.') !== -1, text);
      truthy(text.indexOf('the spot where you are standing, not who you are.') !== -1, text);
      truthy(labels(anon).indexOf('Clear') !== -1, labels(anon).join(' | '));
    });
    click(anon, 'Clear');
    await settle(); await settle();
    it('placer: Clear clears it, at once', function () {
      eq(sentNamed(anon, 'clearMeeting').length, 1);
      eq(sentNamed(anon, 'clearMeeting')[0].body.id, 'ct00000077');
      truthy(anon.notice().indexOf('Meeting point cleared.') !== -1, anon.notice());
    });

    const soon = await mineWith([meetingCard({ meetingSet: true })], [],
      { setMeeting: { ok: false, err: 'meeting_too_soon', data: { retryAfter: 20 } } });
    click(soon, 'Set meeting point here');
    await settle();
    click(soon, 'Set');
    await settle(); await settle();
    it('placer: a change inside the half minute says how long to wait', function () {
      truthy(soon.notice().indexOf('The meeting point was changed a moment ago. Try again in '
        + '20 seconds.') !== -1, soon.notice());
    });

    const off = await mineWith([meetingCard({})], []);
    it('placer: no controls where the server sends none (off, or nobody on it)', function () {
      eq(off.view.textContent.indexOf('eeting point'), -1, off.view.textContent);
    });

    const hit = await mineWith([], [hitmanCard({ meetingSet: true })], { meetingGps: { ok: true } });
    it('hitman: says a meeting point is set, and offers Set GPS', function () {
      truthy(hit.view.textContent.indexOf('Meeting point set') !== -1, hit.view.textContent);
      truthy(labels(hit).indexOf('Set GPS') !== -1, labels(hit).join(' | '));
      eq(labels(hit).indexOf('Set meeting point here'), -1, 'the placer\'s controls are theirs');
    });
    click(hit, 'Set GPS');
    await settle(); await settle();
    it('hitman: Set GPS has the game mark it, sending which contract alone', function () {
      const posts = sentNamed(hit, 'meetingGps');
      eq(posts.length, 1);
      eq(JSON.stringify(Object.keys(posts[0].body)), JSON.stringify(['id']));
      truthy(hit.notice().indexOf('The meeting point is marked on your GPS.') !== -1, hit.notice());
    });

    const gone = await mineWith([], [hitmanCard({ meetingSet: true })],
      { meetingGps: { ok: false, err: 'no_meeting' } });
    const readsBefore = sentNamed(gone, 'mine').length;
    click(gone, 'Set GPS');
    await settle(); await settle();
    it('hitman: one cleared meanwhile is said, and the card read again', function () {
      truthy(gone.notice().indexOf('No meeting point is set on this contract now.') !== -1,
        gone.notice());
      truthy(sentNamed(gone, 'mine').length > readsBefore, 'read again');
    });

    const none = await mineWith([], [hitmanCard({})]);
    it('hitman: nothing of a meeting point while none is set', function () {
      eq(none.view.textContent.indexOf('eeting point'), -1, none.view.textContent);
      eq(labels(none).indexOf('Set GPS'), -1);
    });

    it('meeting point: every page drew cleanly', function () {
      [unset, anon, soon, off, hit, gone, none].forEach(function (app) { drewCleanly(app); });
    });
  })();

  /* lb-phone's light theme, its default. It draws its status bar and home
     indicator onto the page in black, and the page is dark, so the page
     marks its root with the theme and the stylesheet lays a paper band
     under each (app.css, body::before). */
  await (async function () {
    let listener = null;
    const themed = boot({}, {
      getSettings: function () { return Promise.resolve({ display: { theme: 'light' } }); },
      onSettingsChange: function (fn) { listener = fn; }
    });
    await settle(); await settle();
    it('marks the page with lb-phone\'s light theme', function () {
      eq(themed.document.documentElement.attributes['data-theme'], 'light');
    });
    if (listener) { listener({ display: { theme: 'dark' } }); }
    it('and follows it when the player switches to dark', function () {
      truthy(listener, 'the page did not ask to hear of a change');
      eq(themed.document.documentElement.attributes['data-theme'], 'dark');
    });
    const plain = boot({});
    await settle(); await settle();
    it('leaves a page with no lb-phone around it as it was', function () {
      eq(plain.document.documentElement.attributes['data-theme'], undefined);
    });
    drewCleanly(themed); drewCleanly(plain);
  })();

  /* The whitelisted-job view (Config.WhitelistedView). A player on a job
     the app bars opens it to one read-only screen: the contracts on them
     and on other whitelisted-job members, and the buyout on their own. The
     page learns it from the server, never by deciding for itself: its
     opening reads come back blacklisted_job, and the view's read answers. */
  const BARRED = { ok: false, err: 'blacklisted_job' };
  function jobView(extra) {
    const now = Math.floor(Date.now() / 1000);
    const data = {
      onYou: [{
        id: 'ct00000031', targetName: 'Olive Ward', targetJob: 'Police',
        postedAt: now - 25 * 60, state: 'open', hitmenActive: 0, secondsLeft: 7200,
        bailoutAmount: 15000, bailoutAvailable: true
      }],
      colleagues: [{
        targetName: 'Colin Hart', targetJob: 'SAST', postedAt: now - 3 * 3600,
        state: 'taken', hitmenActive: 2, secondsLeft: 3000
      }, {
        targetName: 'Oona Fell', targetJob: 'EMS', postedAt: now - 120,
        state: 'open', hitmenActive: 0, secondsLeft: 9000
      }],
      settings: { buyouts: true, buyoutDelaySeconds: 120 }
    };
    Object.assign(data, extra || {});
    return { ok: true, data: data };
  }
  const VIEW_INTRO = 'You’re on a whitelisted job, so this app only shows contracts '
    + 'on you and on other whitelisted-job members.';

  await (async function whitelistedView() {
    let bought = null;
    let views = 0;
    const app = boot({
      list: BARRED, mine: BARRED, ledger: BARRED,
      whitelistedView: function () { views += 1; return jobView(); },
      bailout: function (body) { bought = body; return { ok: true, data: { queued: false } }; }
    });
    await settle(); await settle(); await settle();
    const text = app.view.textContent;
    const names = app.sent.map(function (r) { return r.name; });

    it('opens a barred player\'s app on the whitelisted-job view, asked for once', function () {
      eq(names.filter(function (n) { return n === 'whitelistedView'; }).length, 1,
        'one read of the view for three refusals: ' + names.join(', '));
      truthy(text.indexOf(VIEW_INTRO) !== -1, 'the screen says what it is: ' + text);
      falsy(text.indexOf('This app is not for you.') !== -1, 'not a refusal: ' + text);
      truthy(app.document.documentElement.classList.contains('is-whitelisted-view'),
        'the root is marked, which takes the tab bar away');
    });

    it('draws both lists, each entry with no more than the advisory says', function () {
      truthy(text.indexOf('Contracts on you') !== -1, text);
      truthy(text.indexOf('Contracts on whitelisted jobs') !== -1, text);
      ['Olive Ward', 'Police', 'Colin Hart', 'SAST', 'Oona Fell', 'EMS',
       'Taken by 2 hitmen', 'Open — no hitman yet', 'Posted 25 min ago',
       'Posted 3h ago', 'Posted 2 min ago', 'Lapses within 2h',
       'Runs out within '].forEach(function (want) {
        truthy(text.indexOf(want) !== -1, '"' + want + '" is on screen: ' + text);
      });
      eq(app.view.all().filter(function (n) { return n.tagName === 'IMG'; }).length, 0,
        'no photo, ever');
      falsy(text.indexOf('Ref ') !== -1, 'nor a reference to quote: nothing here is theirs to act on but the buyout');
    });

    it('offers the buyout on a contract on them, and only there', function () {
      const buy = app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent.indexOf('Buy out') === 0;
      });
      eq(buy.length, 1, 'one button, on their own entry');
      eq(buy[0].textContent, 'Buy out — $15,000', 'priced as On me prices it');
    });

    click(app, 'Buy out — $15,000');
    it('asks before it pays, as On me does', function () {
      truthy(app.view.textContent.indexOf('Pay $15,000') !== -1, app.view.textContent);
      falsy(bought, 'nothing sent on the first tap');
    });
    const beforePay = app.sent.length;
    click(app, 'Pay $15,000');
    await settle(); await settle(); await settle();
    it('pays through the same request as On me, and reads the view again', function () {
      truthy(bought, 'the buyout reached the server');
      eq(bought.id, 'ct00000031');
      const after = app.sent.slice(beforePay).map(function (r) { return r.name; });
      eq(after.join(','), 'bailout,whitelistedView', 'the view, never the board: ' + after.join(','));
      truthy(app.notice().indexOf('Paid. Contract closed.') !== -1, app.notice());
    });

    const beforeTab = app.sent.length;
    tab(app, 'board');
    tab(app, 'place');
    await settle();
    it('goes nowhere else: the tab bar is gone and its tabs do nothing', function () {
      eq(app.sent.length, beforeTab, 'nothing asked for');
      truthy(app.view.textContent.indexOf(VIEW_INTRO) !== -1, 'still the view');
    });

    const beforePush = app.sent.length;
    app.sandbox.window._message({ data: { type: 'push', reason: 'settings' } });
    app.timers.filter(function (t) { return t.ms === 250 && !t.cleared; })
      .forEach(function (t) { t.cleared = true; t.fn(); });
    await settle(); await settle();
    it('reads the view again on a push, and nothing of the app', function () {
      const after = app.sent.slice(beforePush).map(function (r) { return r.name; });
      eq(after.join(','), 'whitelistedView', after.join(','));
    });
    drewCleanly(app);
  })();

  await (async function whitelistedViewEmpty() {
    const app = boot({
      list: BARRED, mine: BARRED, ledger: BARRED,
      whitelistedView: jobView({ onYou: [], colleagues: [] })
    });
    await settle(); await settle(); await settle();
    it('says when there is nothing on them or on anybody on a whitelisted job', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('No contracts on you or other whitelisted-job members.') !== -1, text);
      truthy(text.indexOf(VIEW_INTRO) !== -1, 'and what the screen is: ' + text);
      falsy(text.indexOf('Contracts on you') !== -1, 'no empty headings: ' + text);
    });
    drewCleanly(app);
  })();

  /* Notify me on the view (Config.WhitelistedView.Alerts): drawn only where
     the server says whether it is on, which it does only while it allows
     it. A tap asks the server, and the screen says what it answered. */
  await (async function whitelistedViewAlerts() {
    const asked = [];
    const app = boot({
      list: BARRED, mine: BARRED, ledger: BARRED,
      whitelistedView: jobView({ alerts: { on: false } }),
      whitelistedViewAlerts: function (body) {
        asked.push(body);
        return { ok: true, data: { on: body.on === true } };
      }
    });
    await settle(); await settle(); await settle();
    function buttons(which) {
      return which.view.all().filter(function (n) { return n.tagName === 'BUTTON'; })
        .map(function (n) { return n.textContent; });
    }
    it('offers Notify me, off until they turn it on, saying what it does', function () {
      truthy(buttons(app).indexOf('Notify me') !== -1, buttons(app).join(' | '));
      truthy(app.view.textContent.indexOf('Notify me is off. Turn it on and your phone tells '
        + 'you when a new contract appears here, while you are in the city.') !== -1,
        app.view.textContent);
    });
    click(app, 'Notify me');
    await settle(); await settle();
    it('turns it on through the server, and says so', function () {
      eq(asked.length, 1);
      eq(JSON.stringify(asked[0].on), 'true', 'asked for on, and nothing else of theirs');
      truthy(app.notice().indexOf('Notify me is on.') !== -1, app.notice());
      truthy(buttons(app).indexOf('Turn off Notify me') !== -1, buttons(app).join(' | '));
      truthy(app.view.textContent.indexOf('Notify me is on: your phone tells you when a new '
        + 'contract appears here, while you are in the city.') !== -1, app.view.textContent);
      truthy(app.view.textContent.indexOf(VIEW_INTRO) !== -1, 'still the view');
    });
    click(app, 'Turn off Notify me');
    await settle(); await settle();
    it('and off again', function () {
      eq(asked.length, 2);
      eq(asked[1].on, false);
      truthy(app.notice().indexOf('Notify me is off.') !== -1, app.notice());
      truthy(buttons(app).indexOf('Notify me') !== -1, buttons(app).join(' | '));
    });
    drewCleanly(app);

    const plain = boot({ list: BARRED, mine: BARRED, ledger: BARRED, whitelistedView: jobView() });
    await settle(); await settle(); await settle();
    it('draws no toggle where the server does not allow it', function () {
      eq(buttons(plain).filter(function (b) { return b.indexOf('Notify me') !== -1; }).length, 0,
        buttons(plain).join(' | '));
      falsy(plain.view.textContent.indexOf('Notify me') !== -1, plain.view.textContent);
    });
    drewCleanly(plain);

    const off = boot({
      list: BARRED, mine: BARRED, ledger: BARRED,
      whitelistedView: jobView({ alerts: { on: false } }),
      whitelistedViewAlerts: { ok: false, err: 'feature_off' }
    });
    await settle(); await settle(); await settle();
    click(off, 'Notify me');
    await settle(); await settle();
    it('takes the toggle away when the server has switched it off since', function () {
      truthy(off.notice().indexOf('That is turned off by the server right now.') !== -1,
        off.notice());
      falsy(off.view.textContent.indexOf('Notify me') !== -1, off.view.textContent);
    });
    drewCleanly(off);

    const fast = boot({
      list: BARRED, mine: BARRED, ledger: BARRED,
      whitelistedView: jobView({ alerts: { on: false } }),
      whitelistedViewAlerts: { ok: false, err: 'rate_limited', data: { retryAfter: 4 } }
    });
    await settle(); await settle(); await settle();
    click(fast, 'Notify me');
    await settle(); await settle();
    it('says how long to wait when tapped too fast, and leaves it as it was', function () {
      truthy(fast.notice().indexOf('Slow down') !== -1, fast.notice());
      truthy(buttons(fast).indexOf('Notify me') !== -1, buttons(fast).join(' | '));
    });
    drewCleanly(fast);
  })();

  /* A viewer the advisory does not reach (EMS, a lawyer), or a server with
     it off: the server sends no colleagues' list at all, and the page draws
     no such section, nor says there is nothing in it. An entry whose
     acceptances no bulletin announces carries no count, and is drawn
     neither open nor taken. */
  await (async function whitelistedViewOwnOnly() {
    const own = jobView();
    delete own.data.colleagues;
    const app = boot({ list: BARRED, mine: BARRED, ledger: BARRED, whitelistedView: own });
    await settle(); await settle(); await settle();
    it('draws only their own contracts where no colleagues\' list is sent', function () {
      const text = app.view.textContent;
      truthy(text.indexOf('this app only shows contracts on you.') !== -1, text);
      falsy(text.indexOf('whitelisted-job members') !== -1, text);
      falsy(text.indexOf('Contracts on whitelisted jobs') !== -1, text);
      truthy(text.indexOf('Olive Ward') !== -1, 'their own entry: ' + text);
    });
    drewCleanly(app);

    const none = jobView({ onYou: [] });
    delete none.data.colleagues;
    const empty = boot({ list: BARRED, mine: BARRED, ledger: BARRED, whitelistedView: none });
    await settle(); await settle(); await settle();
    it('says only that there is nothing on them', function () {
      const text = empty.view.textContent;
      truthy(text.indexOf('No contracts on you.') !== -1, text);
      falsy(text.indexOf('whitelisted-job members') !== -1, text);
    });
    drewCleanly(empty);

    const now = Math.floor(Date.now() / 1000);
    const quiet = boot({ list: BARRED, mine: BARRED, ledger: BARRED, whitelistedView: jobView({
      colleagues: [{ targetName: 'Colin Hart', targetJob: 'SAST' }],
      onYou: [{ id: 'ct00000031', targetName: 'Olive Ward', postedAt: now - 60, state: 'open',
        hitmenActive: 0, secondsLeft: 7200 }]
    }) });
    await settle(); await settle(); await settle();
    it('draws neither open nor taken where the entry carries no count', function () {
      const cards = quiet.view.all().filter(function (n) {
        return n.className === 'card' && n.textContent.indexOf('Colin Hart') !== -1;
      });
      eq(cards.length, 1);
      falsy(/Open|Taken by/.test(cards[0].textContent), cards[0].textContent);
      falsy(cards[0].textContent.indexOf('Posted') !== -1, 'nor when it was posted: ' + cards[0].textContent);
      falsy(/Runs out/.test(cards[0].textContent), 'nor when it runs out: ' + cards[0].textContent);
    });
    drewCleanly(quiet);
  })();

  await (async function whitelistedViewBuyouts() {
    const off = boot({
      list: BARRED, mine: BARRED, ledger: BARRED,
      whitelistedView: (function () {
        const r = jobView({ settings: { buyouts: false, buyoutDelaySeconds: 120 } });
        r.data.onYou[0].bailoutAvailable = false;
        return r;
      })()
    });
    const paid = boot({
      list: BARRED, mine: BARRED, ledger: BARRED,
      whitelistedView: (function () {
        const r = jobView();
        r.data.onYou[0].bailoutPaid = true;
        r.data.onYou[0].bailoutSecondsLeft = 90;
        r.data.onYou[0].hitmenActive = 1;
        r.data.onYou[0].state = 'taken';
        return r;
      })()
    });
    await settle(); await settle(); await settle();
    it('draws no buyout button where buyouts are off, and says why as On me does', function () {
      eq(off.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent.indexOf('Buy out') === 0;
      }).length, 0);
      truthy(off.view.textContent.indexOf('This server does not offer buyouts.') !== -1,
        off.view.textContent);
    });
    it('shows a buyout already paid and how long the hitman still has, as On me does', function () {
      const text = paid.view.textContent;
      truthy(text.indexOf('Paid. A hitman still has about 2 minutes to finish this') !== -1, text);
      truthy(text.indexOf('Taken by 1 hitman') !== -1, text);
    });
    drewCleanly(off); drewCleanly(paid);
  })();

  await (async function whitelistedViewSwitches() {
    // Leaving the job: the view's read sends them back to the whole app.
    let onTheJob = true;
    const leaving = boot({
      list: function () { return onTheJob ? BARRED : BOARD; },
      mine: function () { return onTheJob ? BARRED : MINE; },
      ledger: function () { return onTheJob ? BARRED : LEDGER; },
      whitelistedView: function () {
        return onTheJob ? jobView() : { ok: false, err: 'not_whitelisted' };
      }
    });
    await settle(); await settle(); await settle();
    onTheJob = false;
    leaving.sandbox.window._message({ data: { type: 'push', reason: 'access' } });
    await settle(); await settle(); await settle(); await settle();
    it('gives the whole app back the moment they leave the job', function () {
      const text = leaving.view.textContent;
      truthy(text.indexOf('Dana Reyes') !== -1, 'the board again: ' + text);
      falsy(text.indexOf(VIEW_INTRO) !== -1, 'the view is gone: ' + text);
      falsy(text.indexOf('Olive Ward') !== -1, 'and nothing it held: ' + text);
      falsy(leaving.document.documentElement.classList.contains('is-whitelisted-view'),
        'the tab bar is back');
    });

    // Joining one: the board, Mine and the draft are dropped for the view.
    let hired = false;
    const joining = boot({
      list: function () { return hired ? BARRED : BOARD; },
      mine: function () { return hired ? BARRED : MINE; },
      ledger: function () { return hired ? BARRED : LEDGER; },
      whitelistedView: function () {
        return hired ? jobView() : { ok: false, err: 'not_whitelisted' };
      }
    });
    await settle(); await settle(); await settle();
    const civilianAsked = joining.sent.filter(function (r) {
      return r.name === 'whitelistedView';
    }).length;
    // Hired with the Place form open: it goes, with whatever was typed.
    tab(joining, 'place');
    await settle(); await settle();
    const placeDrawn = joining.view.textContent.indexOf('Subject') !== -1;
    hired = true;
    joining.sandbox.window._message({ data: { type: 'push', reason: 'access' } });
    await settle(); await settle(); await settle(); await settle();
    it('never asks a civilian\'s server for the view', function () {
      eq(civilianAsked, 0);
      truthy(placeDrawn, 'the Place form was open before the job change');
    });
    it('moves a civilian who joins a whitelisted job to the view, dropping the board', function () {
      const text = joining.view.textContent;
      truthy(text.indexOf(VIEW_INTRO) !== -1, text);
      falsy(text.indexOf('Dana Reyes') !== -1, 'nothing of the board survives: ' + text);
      falsy(text.indexOf('Subject') !== -1 || text.indexOf('Payment') !== -1,
        'nor the Place form: ' + text);
      truthy(joining.document.documentElement.classList.contains('is-whitelisted-view'));
    });

    // The view switched off: the app is closed to them, as it always was.
    const closed = boot({
      list: BARRED, mine: BARRED, ledger: BARRED,
      whitelistedView: BARRED
    });
    await settle(); await settle(); await settle();
    it('says the app is not for them where the view is off', function () {
      const text = closed.view.textContent;
      truthy(text.indexOf('This app is not for you.') !== -1, text);
      falsy(text.indexOf(VIEW_INTRO) !== -1, text);
      eq(closed.sent.filter(function (r) { return r.name === 'whitelistedView'; }).length, 1,
        'asked once, not once per refusal');
    });
    drewCleanly(leaving); drewCleanly(joining); drewCleanly(closed);
  })();

  /* ---------- players the app is closed to (group 14) ---------- */

  await (async function barredPlayers() {
    // W167: their game says which screen is theirs before the first read.
    let viewReads = 0;
    const opened = boot({
      accessMode: { ok: true, data: { mode: 'whitelisted' } },
      list: BARRED, mine: BARRED, ledger: BARRED,
      bailout: { ok: true, data: { queued: true } },
      whitelistedView: function () {
        viewReads += 1;
        return viewReads === 3
          ? { ok: false, err: 'rate_limited', data: { retryAfter: 20 } }
          : jobView({ heldJob: 'police' });
      }
    });
    await settle(); await settle(); await settle();
    it('W167: asks a player on the view for its read alone, and none the server refuses them', function () {
      const asked = opened.sent.map(function (r) { return r.name; });
      eq(asked.join(','), 'accessMode,whitelistedView', asked.join(','));
    });
    it('W166: names a job they hold that puts them on the view, and how to get the app back', function () {
      const text = opened.view.textContent;
      truthy(text.indexOf('You hold the police job, a whitelisted one, so this app only shows '
        + 'contracts on you and on other whitelisted-job members. Quit it from your job menu '
        + 'for the whole app.') !== -1, text);
    });

    // W169: nothing pushes a colleague's contract moving here.
    let before = opened.sent.length;
    click(opened, 'Refresh');
    await settle(); await settle(); await settle();
    it('W169: reads the view again from its Refresh', function () {
      eq(opened.sent.slice(before).map(function (r) { return r.name; }).join(','), 'whitelistedView');
    });
    click(opened, 'Refresh');
    await settle(); await settle(); await settle();
    it('W169: says how long to wait when asked too fast, and keeps what it shows', function () {
      truthy(opened.notice().indexOf('Asked too fast. Try again in 20 seconds.') !== -1,
        opened.notice());
      truthy(opened.view.textContent.indexOf('Olive Ward') !== -1, opened.view.textContent);
    });

    // W039: the buyout says another may be out.
    click(opened, 'Buy out — $15,000');
    it('W039: says in the buyout dialog that closing one is not the last', function () {
      truthy(opened.view.textContent.indexOf('Closing this one does not mean nobody else is '
        + 'after you.') !== -1, opened.view.textContent);
    });
    click(opened, 'Pay $15,000');
    await settle(); await settle(); await settle();
    it('W039: and once it is paid', function () {
      truthy(opened.notice().indexOf('You are still a target until then. Closing this one does '
        + 'not mean nobody else is after you.') !== -1, opened.notice());
    });
    drewCleanly(opened);

    // W002: the view off and hiding off: the icon stays and answers nothing.
    const held = { ok: false, err: 'blacklisted_job', data: { job: 'police', held: true } };
    const closed = boot({ list: held, mine: held, ledger: held, whitelistedView: held });
    await settle(); await settle(); await settle();
    it('W002: names the job they hold and how to get the app back, with no Try again', function () {
      const text = closed.view.textContent;
      truthy(text.indexOf('Closed to you while you hold the police job. Quit it from your job '
        + 'menu to use it again.') !== -1, text);
      eq(closed.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Try again';
      }).length, 0, 'asking again changes nothing until they quit it');
    });
    const working = { ok: false, err: 'blacklisted_job', data: { job: 'Police', held: false } };
    const officer = boot({ list: working, mine: working, ledger: working, whitelistedView: working });
    await settle(); await settle(); await settle();
    it('W002: says the app is not for the job they are working, with no Try again either', function () {
      const text = officer.view.textContent;
      truthy(text.indexOf('This app is not for you.') !== -1, text);
      eq(officer.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Try again';
      }).length, 0);
    });
    drewCleanly(closed); drewCleanly(officer);
  })();

  /* ---------- what the page shows is what is charged (group 10) ---------- */

  /* W149, W143: a setting changed from the admin panel pushes reason
     'settings' to every open app. The settings every tab draws by come
     with the board's listing, and that push read the listing on the Board
     tab only: on Place, On me, Mine and the Ledger the page kept the old
     fees while the server charged the new ones. */
  await (async function settingsPushReadsTheListing() {
    let fee = 0;
    function listing() {
      return { ok: true, data: { page: 1, pages: 1, contracts: [],
        settings: { minQueryLength: 3,
                    anonymityFees: { creator: fee, hitman: 0, account: 'bank' } } } };
    }
    const app = boot({
      list: listing, mine: MINE, ledger: LEDGER,
      rewardOptions: { ok: true, data: { cash: 100000, bank: 50000, dirty: 0, caps: { slots: 1 } } },
      browseTargets: { ok: true, data: { people: [], total: 0, page: 1, pages: 1 } }
    });
    await settle(); await settle();

    async function pushedOn(name) {
      tab(app, name);
      await settle(); await settle();
      const before = app.sent.length;
      app.sandbox.window._message({ data: { type: 'push', reason: 'settings' } });
      const due = app.timers.filter(function (t) { return t.ms === 250 && !t.cleared; });
      due[due.length - 1].fn();
      await settle(); await settle(); await settle();
      return app.sent.slice(before).map(function (r) { return r.name; }).sort();
    }

    const read = {};
    for (const name of ['ledger', 'mine', 'onme']) { read[name] = await pushedOn(name); }
    fee = 7500;
    read.place = await pushedOn('place');
    it('reads the listing on a settings push whatever tab is open', function () {
      drewCleanly(app, 'settings pushes on every tab');
      eq(JSON.stringify(read.ledger), JSON.stringify(['ledger', 'list']), 'the ledger');
      eq(JSON.stringify(read.mine), JSON.stringify(['ledger', 'list', 'mine']), 'Mine');
      eq(JSON.stringify(read.onme), JSON.stringify(['list', 'mine']), 'On me');
      truthy(read.place.indexOf('list') !== -1, 'the Place form: ' + read.place);
      truthy(read.place.indexOf('rewardOptions') !== -1,
        'with the wallet, which carries the payouts, sources and caps: ' + read.place);
    });
    it('shows a fee raised mid-form before anything is placed', function () {
      truthy(app.view.textContent.indexOf('(costs $7,500 from your bank)') !== -1,
        app.view.textContent);
    });
  })();

  /* W143, W097, W058, W011, W102: the Place form sends back what it
     showed, and says what the server did with it. */
  await (async function placingIsBinding() {
    function listing(settings) {
      const b = JSON.parse(JSON.stringify(BOARD));
      b.data.settings = Object.assign({}, b.data.settings, settings || {});
      return b;
    }
    async function formWith(over, settings, wallet) {
      const app = placeForm(Object.assign({
        list: listing(Object.assign({ fulfilment: 'alive',
          anonymityFees: { creator: 2500, hitman: 0, account: 'cash' } }, settings || {})),
        rewardOptions: { ok: true, data: Object.assign({}, GOODS, wallet || {}) }
      }, over || {}));
      await settle(); await settle();
      tab(app, 'place');
      await settle(); await settle();
      app.document.getElementById('target-handle').value = 'tg00000001';
      pick(app, 'reason', 'Unpaid debt');
      return app;
    }
    function tickAnonymous(app) {
      const box = app.document.getElementById('anon');
      box.checked = true;
      box.onclick();
    }

    const sent = await formWith();
    pick(sent, 'slot-cash-1', 5000);
    tickAnonymous(sent);
    press(sent, 'place-submit');
    await settle(); await settle();
    it('sends back the fee, its account and the rule it showed', function () {
      const body = sent.submitted();
      truthy(body, 'placed');
      eq(JSON.stringify(body.shown), JSON.stringify({ creatorFee: 2500, feeAccount: 'cash',
        fulfilment: 'alive', protectedAck: false }));
    });

    const moved = await formWith({ create: { ok: false, err: 'terms_changed',
      data: { creatorFee: 9000, feeAccount: 'cash', fulfilment: 'alive' } } });
    pick(moved, 'slot-cash-1', 5000);
    tickAnonymous(moved);
    const listsBefore = moved.sent.filter(function (r) { return r.name === 'list'; }).length;
    press(moved, 'place-submit');
    await settle(); await settle(); await settle();
    it('says the fee now and reads the settings again when it moved', function () {
      truthy(moved.notice().indexOf('$9,000') !== -1, moved.notice());
      truthy(moved.notice().indexOf('Nothing was taken') !== -1, moved.notice());
      truthy(moved.sent.filter(function (r) { return r.name === 'list'; }).length > listsBefore,
        'the listing is read again');
    });

    const ruled = await formWith({ create: { ok: false, err: 'rule_changed',
      data: { creatorFee: 0, feeAccount: 'bank', fulfilment: 'either' } } });
    pick(ruled, 'slot-cash-1', 5000);
    press(ruled, 'place-submit');
    await settle(); await settle(); await settle();
    it('says which way the rule went when it changed under the form', function () {
      truthy(ruled.notice().indexOf('a kill completes one') !== -1, ruled.notice());
    });

    const placed = await formWith({ create: { ok: true, data: { fulfilment: 'either',
      penaltyAmount: 0, charged: { fee: 2500, account: 'cash' } } } });
    pick(placed, 'slot-cash-1', 5000);
    pick(placed, 'penalty', 1000);
    tickAnonymous(placed);
    press(placed, 'place-submit');
    await settle(); await settle();
    it('names the fee charged, the rule where it differs, and a stake that was dropped', function () {
      const said = placed.notice();
      truthy(said.indexOf('Placing it anonymously cost $2,500 from your cash.') !== -1, said);
      truthy(said.indexOf('A kill completes it as well as a live handover.') !== -1, said);
      truthy(said.indexOf('No stake was set') !== -1, said);
    });

    const dirtyOnly = await formWith({}, {}, { dirty: 50000 });
    pick(dirtyOnly, 'slot-dirty-1', 5000);
    pick(dirtyOnly, 'penalty', 2000);
    press(dirtyOnly, 'place-submit');
    await settle();
    it('refuses a stake on a reward with no cash or bank, before sending it', function () {
      falsy(dirtyOnly.submitted(), 'nothing sent');
      truthy(dirtyOnly.notice().indexOf('cannot carry a stake') !== -1, dirtyOnly.notice());
    });

    const NAMING = { items: [
      { name: 'carkey', label: 'Car key', count: 1, namesOwner: true },
      { name: 'lockpick', label: 'Lockpick', count: 5 }
    ] };
    const keyed = await formWith({}, {}, NAMING);
    const optionsNamed = function (app) {
      return app.document.getElementById('slot-item-1').children
        .filter(function (o) { return o.value === 'carkey'; })[0];
    };
    const openKey = optionsNamed(keyed);
    tickAnonymous(keyed);
    await settle();
    const heldBack = optionsNamed(keyed);
    it('holds back an item that names its owner while placing anonymously', function () {
      truthy(openKey && !openKey.disabled, 'offered on a named contract');
      truthy(heldBack && heldBack.disabled, 'held back once anonymous');
      truthy(heldBack.textContent.indexOf('carries your name') !== -1, heldBack.textContent);
    });

    const refusedItem = await formWith({ create: { ok: false, err: 'item_names_owner',
      data: { item: 'carkey' } } }, {}, NAMING);
    pick(refusedItem, 'slot-cash-1', 5000);
    tickAnonymous(refusedItem);
    press(refusedItem, 'place-submit');
    await settle(); await settle();
    it('names the item when the server refuses one for naming its owner', function () {
      truthy(refusedItem.notice().indexOf('Car key carries your name') !== -1,
        refusedItem.notice());
    });

    // W058: picked before they took a protected job.
    const turned = await formWith({ create: { ok: false, err: 'target_now_protected',
      data: { category: 'emergency' } } });
    pick(turned, 'slot-cash-1', 5000);
    press(turned, 'place-submit');
    await settle(); await settle();
    it('shows the warning when the target took a protected job after being picked', function () {
      const text = turned.view.textContent;
      truthy(text.indexOf('That target works in emergency services.') !== -1, text);
      truthy(text.indexOf('Place a contract on them anyway?') !== -1, text);
    });

    drewCleanly(sent); drewCleanly(moved); drewCleanly(placed); drewCleanly(keyed);
    drewCleanly(turned);
  })();

  /* W098, W099: a source switched off on its own said so nowhere. */
  await (async function placeFormSaysWhatIsOff() {
    const app = placeForm({ rewardOptions: { ok: true, data: Object.assign({}, GOODS, {
      items: [], caps: Object.assign({}, GOODS.caps, { dirtyEnabled: false, itemsEnabled: false,
        minValue: 1000 })
    }) } });
    await settle(); await settle();
    tab(app, 'place');
    await settle(); await settle();
    const text = app.view.textContent;
    it('says which money source is off, and leaves it out of the minimum', function () {
      truthy(text.indexOf('This server does not take dirty money as a reward.') !== -1, text);
      falsy(/dirty money (across|in the reward)/.test(text), text);
      truthy(text.indexOf('cash and bank') !== -1, text);
    });
    it('says items are off while a weapon is still offered', function () {
      truthy(app.document.getElementById('slot-weapon-1'), 'the weapon picker');
      truthy(text.indexOf('This server does not take items as a reward.') !== -1, text);
    });
  })();

  /* W018, W022: the hitman's fee is sent back and named. */
  await (async function acceptingIsBinding() {
    let accepted = null;
    let fee = 1000;
    function listing() {
      const b = JSON.parse(JSON.stringify(BOARD));
      b.data.settings = Object.assign({}, b.data.settings,
        { anonymityFees: { creator: 0, hitman: fee, account: 'bank' } });
      return b;
    }
    const app = boot({ list: listing, mine: MINE, ledger: LEDGER,
      accept: function (body) {
        accepted = body;
        return { ok: true, data: { myAnonymous: true, charged: { fee: 2500, account: 'bank' } } };
      } });
    await settle(); await settle();
    click(app, 'Accept contract');
    const shownFirst = app.view.textContent;
    // Raised from the panel while the dialog is open.
    fee = 2500;
    app.sandbox.window._message({ data: { type: 'push', reason: 'settings' } });
    const due = app.timers.filter(function (t) { return t.ms === 250 && !t.cleared; });
    due[due.length - 1].fn();
    await settle(); await settle(); await settle();
    const shownAfter = app.view.textContent;
    click(app, 'Anonymously');
    await settle(); await settle();
    it('draws the open dialog again with a fee raised while it was open', function () {
      truthy(shownFirst.indexOf('$1,000') !== -1, shownFirst);
      truthy(shownAfter.indexOf('$2,500') !== -1, shownAfter);
    });
    it('sends back the fee and the account the dialog showed', function () {
      truthy(accepted, 'accepted');
      eq(JSON.stringify(accepted.shown), JSON.stringify({ hitmanFee: 2500, feeAccount: 'bank' }));
    });
    it('names the fee charged in the notice', function () {
      truthy(app.notice().indexOf('Anonymity cost $2,500 from your bank.') !== -1, app.notice());
    });

    const refused = boot({ list: listing, mine: MINE, ledger: LEDGER,
      accept: { ok: false, err: 'terms_changed', data: { fee: 4000, feeAccount: 'cash' } } });
    await settle(); await settle();
    click(refused, 'Accept contract');
    click(refused, 'Anonymously');
    await settle(); await settle();
    it('says the fee now when it moved before the tap', function () {
      truthy(refused.notice().indexOf('$4,000 from your cash') !== -1, refused.notice());
    });
    drewCleanly(app); drewCleanly(refused);
  })();

  /* A11: the how-to on a hitman's card, while a handover runs on the
     radius it was armed with, says that radius, not the one set since. */
  await (async function howToSaysTheArmedRadius() {
    const mine = { ok: true, data: { created: [], accepted: [{
      id: 'ct00000001', reason: 'Unpaid debt', mode: 'exclusive', fulfilment: 'alive',
      state: 'accepted', reward: { baseline: 5000 },
      slots: 1, slotsClaimed: 0, currentSlot: 1, hitmenActive: 1, hitmenMax: 1,
      targetName: 'Dana Reyes', role: 'hitman', creatorName: 'Vic Marlowe',
      deadline: Math.floor(Date.now() / 1000) + 7200,
      kidnapProgress: { elapsed: 4, required: 30, graceLeft: 3000, graceTotal: 3000, radius: 12 }
    }], onMe: [] } };
    const app = boot({
      list: { ok: true, data: { page: 1, pages: 1, contracts: [],
        settings: { kidnap: { radius: 50, seconds: 30 }, fulfilment: 'alive' } } },
      mine: mine, ledger: LEDGER,
      kidnapProgress: { ok: true, data: { elapsed: 5, required: 30, graceLeft: 3000,
        graceTotal: 3000, radius: 12 } }
    });
    await settle(); await settle();
    tab(app, 'mine');
    await settle(); await settle();
    const text = app.view.textContent;
    it('says the armed radius in the how-to while the countdown runs', function () {
      truthy(text.indexOf('get within 12 m of that person') !== -1, text);
      falsy(text.indexOf('within 50 m') !== -1, 'the radius set since: ' + text);
    });
    drewCleanly(app);
  })();

  /* W100, W054, W055: the Ledger's counters, the switch that flags the
     listing, and the kind of protected job. */
  await (async function countersFlagsAndKinds() {
    const ledger = boot({ list: BOARD, mine: MINE, ledger: { ok: true, data: { entries: [],
      record: { completed: 4, failed: 3, placed: 2, survived: 1, rate: 57, standing: 'Unproven' } } } });
    await settle(); await settle();
    tab(ledger, 'ledger');
    await settle(); await settle();
    it('shows what the success rate is worked out from', function () {
      truthy(ledger.view.textContent.indexOf('3 abandoned or lost') !== -1,
        ledger.view.textContent);
    });

    function officerBoard(settings, kind) {
      const b = JSON.parse(JSON.stringify(BOARD));
      b.data.settings = Object.assign({}, b.data.settings, settings || {});
      b.data.contracts[0].targetProtected = true;
      if (kind) { b.data.contracts[0].targetProtectedAs = kind; }
      return b;
    }
    const unflagged = boot({ list: officerBoard({ flagListing: false }, 'law'), mine: MINE,
      ledger: LEDGER });
    await settle(); await settle();
    it('marks nothing on the card where the listing is not flagged', function () {
      const cards = unflagged.view.all().filter(function (n) {
        return n._className && n._className.split(' ').indexOf('card') !== -1;
      });
      falsy(cards.some(function (n) { return n._className.indexOf('is-protected') !== -1; }),
        'the protected styling');
      falsy(/sworn officer/.test(unflagged.view.textContent), unflagged.view.textContent);
    });

    const medic = boot({ list: officerBoard({}, 'emergency'), mine: MINE, ledger: LEDGER,
      accept: { ok: true, data: {} } });
    await settle(); await settle();
    const card = medic.view.textContent;
    click(medic, 'Accept contract');
    const dialog = medic.view.textContent;
    it('words a medic as emergency services, not a sworn officer', function () {
      truthy(card.indexOf('Emergency services') !== -1, card);
      truthy(card.indexOf('This target works in emergency services.') !== -1, card);
      falsy(/sworn officer|Law enforcement/.test(card), card);
      truthy(dialog.indexOf('This contract is on someone in emergency services.') !== -1, dialog);
    });
    drewCleanly(ledger); drewCleanly(unflagged); drewCleanly(medic);
  })();

  /* ---------- What the page says it knows (G8) ----------
     Timeouts on money, rate limits, refusals on the forms and the board, and
     the relay: each of these said less than the server knew, or the wrong
     thing. */
  await (async function pageSaysWhatItKnows() {
    function boardWith(settings, contracts) {
      return { ok: true, data: { page: 1, pages: 1, contracts: contracts || [],
        settings: Object.assign({ minQueryLength: 4 }, settings || {}) } };
    }
    const WALLET = { ok: true, data: { cash: 100000, bank: 50000, dirty: 20000, caps: { slots: 1 } } };
    async function placeForm(over, settings) {
      const app = boot(Object.assign({
        list: boardWith(settings), mine: MINE, ledger: LEDGER, rewardOptions: WALLET,
        searchTargets: { ok: true, data: [{ handle: 'tg00000001', name: 'Dana Reyes', protected: false }] }
      }, over || {}));
      await settle(); await settle();
      tab(app, 'place');
      await settle(); await settle();
      return app;
    }
    async function placeIt(app, reason) {
      app.document.getElementById('target-handle').value = 'tg00000001';
      const box = app.document.getElementById('reason');
      if (box) { box.value = reason; }
      app.document.getElementById('slot-cash-1').value = '5000';
      click(app, 'Place contract');
      await settle(); await settle(); await settle();
      return app.sent.filter(function (x) { return x.name === 'create'; });
    }
    function asked(app, name) {
      return app.sent.filter(function (x) { return x.name === name; }).length;
    }
    function firePush(app, reason) {
      app.sandbox.window._message({ data: { type: 'push', reason: reason } });
      const due = app.timers.filter(function (t) { return t.ms === 250 && !t.cleared; });
      if (due.length) { due[due.length - 1].fn(); }
    }

    /* S19: a place that ran out of the wait may still have been placed and
       paid for, and "Try again" placed and paid for a second one. */
    const timed = await placeForm({ create: { ok: false, err: 'timeout', event: 'create' } });
    await placeIt(timed, 'Unpaid debt');
    const listTimed = boot({ list: { ok: false, err: 'timeout', event: 'list' }, mine: MINE,
      ledger: LEDGER });
    await settle(); await settle();
    it('says a money request out of time may still go through, and a read to try again', function () {
      eq(timed.notice(), 'No answer yet. It may still go through: look before you try again.');
      truthy(listTimed.view.textContent.indexOf('No answer. Try again.') !== -1,
        'a read moved nothing: ' + listTimed.view.textContent);
    });

    // The answer that lands after it has the page read everything again.
    const late = await placeForm({});
    const lateBefore = { list: asked(late, 'list'), mine: asked(late, 'mine'),
      ledger: asked(late, 'ledger'), wallet: asked(late, 'rewardOptions') };
    firePush(late, 'late');
    await settle(); await settle(); await settle();
    it('reads everything again when a request it gave up on is answered late', function () {
      eq(asked(late, 'list') - lateBefore.list, 1, 'the board');
      eq(asked(late, 'mine') - lateBefore.mine, 1, 'Mine, where a late contract shows');
      eq(asked(late, 'ledger') - lateBefore.ledger, 1, 'the ledger');
      eq(asked(late, 'rewardOptions') - lateBefore.wallet, 1, 'and the wallet it was paid from');
    });

    /* W198: a rate-limited poll is a throttle, not the end of the handover. */
    const holding = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    holding.role = 'hitman';
    holding.myAlias = 'Operative #1';
    holding.kidnapProgress = { elapsed: 4, required: 30, graceLeft: 3000, graceTotal: 3000 };
    const replies = [
      { ok: true, data: { elapsed: 5, required: 30, graceLeft: 3000, graceTotal: 3000 } },
      { ok: false, err: 'rate_limited', data: { retryAfter: 30 } }
    ];
    const polled = boot({
      list: boardWith(), mine: { ok: true, data: { created: [], accepted: [holding], onMe: [] } },
      ledger: LEDGER,
      kidnapProgress: function () { return replies.shift() || { ok: false, err: 'no_handover' }; }
    });
    await settle(); await settle();
    tab(polled, 'mine');
    await settle(); await settle();
    const poll = polled.timers.filter(function (t) { return t.repeating && t.ms === 1000 && !t.cleared; });
    const tick = poll[poll.length - 1];
    tick.fn(); await settle(); await settle();
    const readsBefore = asked(polled, 'list') + asked(polled, 'mine') + asked(polled, 'ledger');
    tick.fn(); await settle(); await settle();
    const pollsAfterLimit = asked(polled, 'kidnapProgress');
    tick.fn(); await settle(); await settle();
    it('keeps the bar through a rate-limited poll, reads nothing and says nothing', function () {
      falsy(tick.cleared, 'the poller is still running');
      truthy(polled.view.textContent.indexOf('5s of 30s') !== -1,
        'the bar stays where it was: ' + polled.view.textContent);
      falsy(polled.notice().indexOf('Slow down') !== -1, polled.notice());
      eq(asked(polled, 'list') + asked(polled, 'mine') + asked(polled, 'ledger'), readsBefore,
        'nothing read again for a throttle');
      eq(asked(polled, 'kidnapProgress'), pollsAfterLimit,
        'and the next poll waits out the wait the server named');
    });

    /* W201: one wording for every wait, in minutes where it is minutes. */
    const HELD = {
      id: 'ct00000001', target: 'Dana Reyes', reason: 'Unpaid debt',
      state: 'accepted', role: 'hitman', mode: 'exclusive',
      reward: { total: 5000 }, canDeliver: true, hitmen: []
    };
    const arming = boot({
      list: boardWith(), mine: { ok: true, data: { created: [], accepted: [HELD], onMe: [] } },
      ledger: LEDGER, armKidnap: { ok: false, err: 'rate_limited', data: { retryAfter: 300 } }
    });
    await settle(); await settle();
    tab(arming, 'mine');
    await settle(); await settle();
    click(arming, 'Deliver alive');
    await settle();
    const slowBoard = boot({ list: { ok: false, err: 'rate_limited', data: { retryAfter: 3600 } },
      mine: MINE, ledger: LEDGER });
    await settle(); await settle();
    const slowWallet = await placeForm({
      rewardOptions: { ok: false, err: 'rate_limited', data: { retryAfter: 120 } } });
    it('says how long a rate limit lasts, in minutes where it is minutes', function () {
      truthy(arming.notice().indexOf('about 5 minutes') !== -1, 'arming: ' + arming.notice());
      truthy(slowBoard.view.textContent.indexOf('Try again in about 60 minutes.') !== -1,
        'the board: ' + slowBoard.view.textContent);
      falsy(slowBoard.view.textContent.indexOf('3600 seconds') !== -1);
      truthy(slowWallet.view.textContent.indexOf('Try again in about 2 minutes.') !== -1,
        'the wallet: ' + slowWallet.view.textContent);
    });

    /* W010: an empty reason caught on the form, and a refused one by its rule. */
    const blank = await placeForm({ create: { ok: true, data: {} } }, { reasonMode: 'freetext' });
    const blankSent = await placeIt(blank, '   ');
    const digits = await placeForm({
      create: { ok: false, err: 'reason_refused', data: { rule: 'digits' } } },
      { reasonMode: 'freetext' });
    await placeIt(digits, 'Owes me 1500000');
    it('says a reason is missing before sending, and which rule a refused one broke', function () {
      eq(blankSent.length, 0, 'nothing sent for an empty reason');
      eq(blank.notice(), 'Give a reason for the contract.');
      truthy(digits.notice().indexOf('digits') !== -1, digits.notice());
      falsy(digits.notice().indexOf('Check what you entered') !== -1);
    });

    /* W021: inside the stake window the card says so, and a refused Accept
       reads the board again. */
    const tight = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    tight.penaltyAmount = 2000;
    tight.secondsLeft = 600;
    const windowed = boot({ list: boardWith({ stakeWindowMinutes: 30 }, [tight]),
      mine: MINE, ledger: LEDGER });
    await settle(); await settle();
    const lockedOut = boot({ list: boardWith({}, [BOARD.data.contracts[0]]), mine: MINE,
      ledger: LEDGER, accept: { ok: false, err: 'locked' } });
    await settle(); await settle();
    const listsBefore = asked(lockedOut, 'list');
    click(lockedOut, 'Accept contract');
    await settle();
    click(lockedOut, 'Under my name');
    await settle(); await settle();
    it('says a staked card is inside the stake window, and re-reads after locked', function () {
      truthy(windowed.view.textContent.indexOf('Too little time left to stake on this one.') !== -1,
        windowed.view.textContent);
      falsy(windowed.view.all().some(function (b) {
        return b.tagName === 'BUTTON' && b.textContent === 'Accept contract';
      }), 'no Accept the server can only refuse');
      eq(asked(lockedOut, 'list') - listsBefore, 1, 'the stale card is read again');
    });

    /* W096: a source switched off mid-form is named, and the wallet read again. */
    const switched = await placeForm({
      create: { ok: false, err: 'source_disabled', data: { source: 'dirty' } } });
    const walletBefore = asked(switched, 'rewardOptions');
    await placeIt(switched, 'Unpaid debt');
    it('names a source switched off and reads the wallet again', function () {
      truthy(switched.notice().indexOf('dirty money') !== -1, switched.notice());
      eq(asked(switched, 'rewardOptions') - walletBefore, 1, 'what can be put up, read again');
    });

    // And the payout ceiling come down to one, with payouts on the form.
    let ceiling = 3;
    const lowered = await placeForm({ rewardOptions: function () {
      return { ok: true, data: { cash: 100000, bank: 50000, dirty: 0, caps: { slots: ceiling } } };
    } });
    const count = lowered.document.getElementById('slots-count');
    count.value = '3';
    count.onchange();
    await settle();
    ceiling = 1;
    firePush(lowered, 'settings');
    await settle(); await settle(); await settle();
    it('says payouts 2 and 3 went when the ceiling came down to one', function () {
      eq(lowered.notice(),
        'This server now takes one payout per contract; payouts 2 and 3 were removed.');
    });

    /* The relay. */
    const caller = JSON.parse(JSON.stringify(BOARD.data.contracts[0]));
    caller.role = 'hitman';
    caller.myAlias = 'Operative #1';
    function relay(over, settings) {
      return boot(Object.assign({
        list: boardWith(Object.assign({ calls: true }, settings || {})),
        mine: { ok: true, data: { created: [], accepted: [caller], onMe: [] } },
        ledger: LEDGER,
        readThread: { ok: true, data: [] },
        requestCall: { ok: true, data: { placed: true } },
        endCall: { ok: true, data: { ended: true } }
      }, over || {}));
    }
    async function inThread(app) {
      await settle(); await settle();
      tab(app, 'mine');
      await settle(); await settle();
      click(app, 'Message');
      await settle(); await settle();
    }

    // W114: the contract closes mid-call and takes the thread with it.
    let closed = false;
    const closing = relay({ readThread: function () {
      return closed ? { ok: false, err: 'already_settled' } : { ok: true, data: [] };
    } });
    await inThread(closing);
    closing.document.getElementById('thread-call').onclick();
    await settle(); await settle();
    closed = true;
    firePush(closing, 'completed');
    await settle(); await settle(); await settle();
    const barHang = closing.view.all().filter(function (n) { return n._id === 'call-hangup'; })[0];
    if (barHang) { barHang.onclick(); await settle(); await settle(); }
    it('keeps Hang up on screen after the contract closes mid-call', function () {
      truthy(asked(closing, 'readThread') >= 2, 'the thread was read again');
      truthy(barHang, 'a Hang up outside the thread: ' + closing.view.textContent);
      eq(asked(closing, 'endCall'), 1, 'and it ends the call');
    });

    // W115: calls switched off mid-call leave Hang up in the thread.
    let callsOn = true;
    const switchedOff = relay({ list: function () {
      return boardWith({ calls: callsOn });
    } });
    await inThread(switchedOff);
    switchedOff.document.getElementById('thread-call').onclick();
    await settle(); await settle();
    callsOn = false;
    firePush(switchedOff, 'settings');
    await settle(); await settle(); await settle();
    it('keeps Hang up in the thread after calls are switched off', function () {
      truthy(switchedOff.view.all().some(function (n) { return n._id === 'thread-hangup'; }),
        switchedOff.view.textContent);
    });

    // W118: a double tap places one call; on a call already, Hang up.
    let answer;
    const tapped = relay({ requestCall: function () {
      return new Promise(function (resolve) { answer = resolve; });
    } });
    await inThread(tapped);
    tapped.document.getElementById('thread-call').onclick();
    await settle();
    const busy = tapped.view.all().filter(function (n) { return n._id === 'thread-call'; })[0];
    if (busy && busy.onclick) { busy.onclick(); }
    await settle();
    if (answer) { answer({ ok: false, err: 'already_in_call' }); }
    await settle(); await settle(); await settle();
    it('sends one call for a double tap, and offers Hang up on a call already', function () {
      eq(asked(tapped, 'requestCall'), 1);
      truthy(busy && busy.textContent === 'Calling…', 'the button says it is asking');
      truthy(tapped.view.all().some(function (n) { return n._id === 'thread-hangup'; }),
        tapped.view.textContent);
    });

    // W117: no Call where a party is anonymous and the phone cannot mask.
    caller.creatorAnonymous = true;
    const unmaskable = relay({}, { canMask: false });
    await inThread(unmaskable);
    const maskable = relay({}, { canMask: true });
    await inThread(maskable);
    delete caller.creatorAnonymous;
    it('draws no Call where the phone cannot hide an anonymous party', function () {
      falsy(unmaskable.view.all().some(function (n) { return n._id === 'thread-call'; }),
        'a Call that can only be refused');
      truthy(maskable.view.all().some(function (n) { return n._id === 'thread-call'; }));
    });

    // W119: a refused message says why, and how long a limit lasts.
    const filtered = relay({ sendMessage: { ok: false, err: 'message_refused' } });
    await inThread(filtered);
    const box = filtered.document.getElementById('compose-input');
    box.value = 'you slur';
    box.oninput();
    box.onkeydown({ key: 'Enter' });
    await settle(); await settle();
    const throttled = relay({ sendMessage: { ok: false, err: 'rate_limited',
      data: { retryAfter: 3600 } } });
    await inThread(throttled);
    const box2 = throttled.document.getElementById('compose-input');
    box2.value = 'Where are you?';
    box2.oninput();
    box2.onkeydown({ key: 'Enter' });
    await settle(); await settle();
    it('says a word was not allowed, and how long a message limit lasts', function () {
      eq(filtered.notice(), 'A word in that message is not allowed here. Your draft is kept.');
      truthy(throttled.notice().indexOf('about 60 minutes') !== -1, throttled.notice());
    });

    // W120: an unread dot, gone once read, kept on the phone.
    const stored = {};
    const storage = {
      getItem: function (k) { return stored[k] === undefined ? null : stored[k]; },
      setItem: function (k, v) { stored[k] = String(v); }
    };
    const unreadCard = JSON.parse(JSON.stringify(caller));
    unreadCard.lastMessageAt = 1000;
    const dotted = boot({
      list: boardWith(), ledger: LEDGER,
      mine: { ok: true, data: { created: [], accepted: [unreadCard], onMe: [] } },
      readThread: { ok: true, data: [{ alias: 'The person who placed it', body: 'Docks.',
        at: 1000, mine: false }] }
    }, { localStorage: storage });
    await settle(); await settle();
    tab(dotted, 'mine');
    await settle(); await settle();
    function messageButton(app) {
      return app.view.all().filter(function (n) {
        return n.tagName === 'BUTTON' && n.textContent === 'Message';
      })[0];
    }
    const before = messageButton(dotted);
    const dottedBefore = !!before && before.classList.contains('has-unread');
    before.onclick();
    await settle(); await settle();
    click(dotted, 'Back');
    await settle(); await settle();
    const after = messageButton(dotted);
    it('marks Message with an unread dot until the thread is read', function () {
      truthy(dottedBefore, 'a message newer than this phone last read');
      falsy(after && after.classList.contains('has-unread'), 'read now');
      truthy(String(stored['crimson-hitman:threads-read'] || '').indexOf('1000') !== -1,
        'kept on this phone: ' + JSON.stringify(stored));
    });

    [timed, listTimed, late, polled, arming, slowBoard, slowWallet, blank, digits, windowed,
     lockedOut, switched, lowered, closing, switchedOff, tapped, unmaskable, maskable, filtered,
     throttled, dotted].forEach(function (app) { drewCleanly(app); });
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
