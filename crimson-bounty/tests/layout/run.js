/* Renders ui/index.html in a real browser and measures it.
 *
 * The other two suites cannot see any of this. The server suite has no DOM,
 * and the UI suite has a DOM shim with no layout engine — so a control that
 * is present, correct and three pixels tall passes both of them.
 *
 * Every failure here was reported by somebody using the app rather than
 * found by anything in this repository:
 *   - the tab bar sat on lb-phone's home indicator, so a thumb aiming at
 *     Place took the phone home instead;
 *   - the cards on the board were squeezed below their own content and
 *     clipped, which removed the Accept button from every one of them.
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
    console.log('playwright not installed; skipping the layout suite');
    process.exit(0);
  }
}

const UI = path.join(__dirname, '..', '..', 'ui', 'index.html');

let passed = 0, failed = 0;
const failures = [];

function it(name, fn) {
  try { fn(); passed++; }
  catch (err) { failed++; failures.push(name + '\n    ' + err.message); }
}
function truthy(v, m) { if (!v) throw new Error((m || 'expected truthy') + ', got ' + v); }
function atLeast(actual, floor, m) {
  if (!(actual >= floor)) {
    throw new Error((m || 'too small') + ': expected at least ' + floor + ', got ' + actual);
  }
}

/* Every element inside a card, measured against that card's own edges.
 *
 * The button check measures <button> and nothing else, and the clipping
 * check measures scrollWidth against clientWidth — which a parent with
 * `overflow: hidden` defeats, because the overflowing child is simply not
 * drawn and the parent reports no overflow of its own.
 *
 * Between the two, a reward block 90px wider than its card passed this
 * suite for as long as it existed: measured at 390x720, the money — the
 * headline number on a bounty board and the entire reason a hunter reads
 * the card — had its right edge at 466px on a card ending at 376px. It was
 * not small and it was not badly placed. It was not on the screen. */
function escapedFrom(page) {
  return page.evaluate(function () {
    const out = [];
    document.querySelectorAll('.card').forEach(function (card) {
      const box = card.getBoundingClientRect();
      card.querySelectorAll('*').forEach(function (node) {
        const r = node.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) { return; }
        if (r.right > box.right + 1 || r.left < box.left - 1) {
          out.push((node.className || node.tagName) + ' spans '
            + Math.round(r.left) + '-' + Math.round(r.right)
            + ' on a card spanning ' + Math.round(box.left) + '-' + Math.round(box.right));
        }
      });
    });
    return out;
  });
}

/* A server, installed before the page loads. */
function serverStub() {
  const contracts = [];
  for (let i = 1; i <= 8; i++) {
    contracts.push({
      id: 'ct0000000' + i, reason: 'Unpaid debt, and a reason long enough to wrap ' + i,
      mode: 'competitive', state: 'active',
      reward: { baseline: 5000 * i, bonus: 2500 },
      slots: 2, slotsClaimed: 0, currentSlot: 1,
      huntersActive: 1, huntersMax: 5,
      targetName: 'Dana Reyes ' + i, targetProtected: i === 3,
      creatorName: 'Vic Marlowe', role: 'public'
    });
  }
  /* The widest card this app can draw.
   *
   * Everything above pays a round five-figure sum to a short name, which is
   * the easy case — and it was the only case measured, so a reward block
   * 90px wider than its own card passed this suite for as long as it
   * existed. A reward is money AND a bonus AND black money AND a list of
   * item and weapon labels, any of which can be long, next to a name that
   * can be longer.
   *
   * Added as a real row so every measurement below sees it, rather than as
   * a test of its own that only checks the one thing it was written for. */
  contracts.push({
    id: 'ct00000009',
    reason: 'Skipped on a debt and took the car with him, which was not his',
    mode: 'competitive', state: 'active',
    reward: { baseline: 1250000, bonus: 500000, dirty: 300000,
              goods: { items: 3, weapons: 2,
                       labels: ['Lockpick', 'Pistol', 'Advanced Repair Kit'] } },
    slots: 3, slotsClaimed: 0, currentSlot: 1,
    huntersActive: 4, huntersMax: 5,
    targetName: 'Maximilian Featherstonehaugh-Cholmondeley',
    creatorName: 'Vic Marlowe', role: 'public'
  });

  // A creator's own contract carries the most actions of any card, which
  // is the case that overflowed.
  const own = contracts.slice(0, 3).map(function (c) {
    const copy = JSON.parse(JSON.stringify(c));
    copy.role = 'creator';
    copy.huntersActive = 0;
    copy.hunters = [];
    // More than one collection, so "Give back a later payout" is offered
    // and its dialog gets measured too.
    copy.slots = 3;
    copy.currentSlot = 1;
    copy.deadline = Math.floor(Date.now() / 1000) + 7200;
    return copy;
  });
  const taken = contracts.slice(3, 5).map(function (c) {
    const copy = JSON.parse(JSON.stringify(c));
    copy.role = 'hunter';
    return copy;
  });

  const answers = {
    list: { ok: true, data: { page: 1, pages: 1, contracts: contracts,
      settings: { minQueryLength: 3, allowBrowseAll: true, allowNearby: true,
        // This suite measures the most crowded card there is, so it has to
        // be a server that offers every button that card can carry.
        informant: { cost: 25000, account: 'bank', maxPerContract: 2 },
        reasonMode: 'freetext', reasonMaxLength: 140 } } },
    mine: { ok: true, data: { created: own, accepted: taken, onMe: [{
      // A price on this player's head. The buyout is the only move the
      // target of a contract has, and it was drawn as an outline no louder
      // than the paid extra beside it.
      id: 'ct00000020', reason: 'Unpaid debt', mode: 'competitive',
      state: 'active', reward: { baseline: 90000 },
      slots: 1, slotsClaimed: 0, currentSlot: 1,
      huntersActive: 2, huntersMax: 5,
      targetName: 'You', role: 'target',
      bailoutAvailable: true, bailoutAmount: 90000,
      deadline: Math.floor(Date.now() / 1000) + 7200
    }] } },
    ledger: { ok: true, data: { entries: [{
      // A full-resolution photograph on somebody else's host, which is what
      // a proof reference actually is. Unbounded this made one history
      // entry taller than the whole viewport.
      target_name: 'Dana Reyes', reason: 'Unpaid debt', role: 'hunter',
      fulfilment: 'elimination', resolved_at: 1700000000,
      photo_ref: 'data:image/svg+xml;base64,' + btoa(
        '<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1920"></svg>')
    }],
      record: { completed: 0, placed: 0, survived: 0, standing: 'Unproven' } } },
    rewardOptions: { ok: true, data: { cash: 100000, bank: 50000, dirty: 2000,
      items: [{ name: 'lockpick', label: 'Lockpick', count: 5 }],
      weapons: [{ name: 'WEAPON_PISTOL', label: 'Pistol', slot: 3, serial: 'C123' }],
      inventoryRead: true,
      caps: { itemsEnabled: true, weaponsEnabled: true, maxStacks: 3,
              maxPerStack: 100, maxWeapons: 2, slots: 5, bonusPercent: 200 } } },
    // Deliberately more lines than fit: a reward can be several money
    // lines and a handful of item stacks, and that is the shape that
    // pushes a dialog's own buttons off the bottom of the screen.
    rewardBreakdown: { ok: true, data: {
      editable: true, slots: 1, currentSlot: 1,
      lines: (function () {
        const rows = [
          { id: 'ct00000001:1', slot: 1, portion: 'baseline', source: 'cash',
            amount: 5000, withdrawable: true },
          { id: 'ct00000001:2', slot: 1, portion: 'baseline', source: 'bank',
            amount: 3000, withdrawable: true },
          { id: 'ct00000001:3', slot: 1, portion: 'bonus', source: 'dirty',
            amount: 2500, withdrawable: true }
        ];
        for (let i = 4; i <= 14; i++) {
          rows.push({ id: 'ct00000001:' + i, slot: 1, portion: 'bonus',
            source: 'item', item: 'a_long_item_name_' + i, quantity: i,
            withdrawable: true });
        }
        return rows;
      })()
    } },
    withdrawReward: { ok: true, data: { id: 'ct00000001', returned: 1, queued: 0 } },
    amendments: { ok: true, data: [] },
    informant: { ok: true, data: { found: false } },
    browseTargets: { ok: true, data: { people: [
      { handle: 'tg1', name: 'Ada Quill', protected: false },
      { handle: 'tg2', name: 'Bo Renn', protected: true }
    ], total: 41, page: 1, pages: 5 } }
  };
  /* What FiveM actually delivers.
   *
   * The server writes Lua tables; they are msgpack-encoded on the way to
   * the client and JSON-encoded on the way into the page. An empty Lua
   * table is indistinguishable from an empty map, so a list the server
   * meant to send empty arrives as {} rather than [] — and on this side
   * .length is then undefined and .forEach throws, taking the render with
   * it.
   *
   * The UI suite has converted its fixtures for exactly this reason since
   * it was written. This one did not, and it matters most here: the Mine
   * tab is where this file does most of its work, and a creator's own
   * contract carries hunters = [] from the moment it is placed. So this
   * suite was measuring layout, at every viewport, on a page that on a
   * real server threw before it drew anything — and reported 23/23 on the
   * exact contract shape the Mine tab had to be fixed for. */
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

  window.fetch = function (url) {
    const name = url.split('/crimson:')[1];
    return Promise.resolve({
      json: function () {
        return Promise.resolve(acrossTheWire(answers[name] || { ok: true }));
      }
    });
  };
}

async function main() {
  const browser = await chromium.launch();

  // Roughly what lb-phone gives a page. The exact numbers matter less than
  // that it is small: a phone screen inside a game window.
  const page = await browser.newPage({ viewport: { width: 390, height: 720 } });
  await page.addInitScript(serverStub);
  await page.goto('file://' + UI);
  await page.waitForTimeout(300);

  /* ---- the tab bar ---- */

  const bar = await page.evaluate(function () {
    const nav = document.querySelector('.tabs');
    const rect = nav.getBoundingClientRect();
    const tabs = Array.prototype.slice.call(document.querySelectorAll('.tab'));
    const style = getComputedStyle(nav);
    return {
      bottom: rect.bottom,
      viewport: window.innerHeight,
      clearance: parseFloat(style.paddingBottom),
      smallest: Math.min.apply(Math, tabs.map(function (t) {
        return t.getBoundingClientRect().height;
      })),
      narrowest: Math.min.apply(Math, tabs.map(function (t) {
        return t.getBoundingClientRect().width;
      })),
      count: tabs.length
    };
  });

  it('keeps the whole tab bar on screen', function () {
    truthy(bar.bottom <= bar.viewport + 0.5,
      'the bar ends at ' + bar.bottom + ' in a ' + bar.viewport + ' viewport');
  });

  it('gives every tab a thumb-sized target', function () {
    // Below about 44px a tab is a coin toss on a phone.
    atLeast(bar.smallest, 44, 'shortest tab');
    atLeast(bar.narrowest, 44, 'narrowest tab');
  });

  it('leaves room under the bar for the phone home indicator', function () {
    // lb-phone draws its home gesture area across the bottom of the frame
    // and reports no inset inside the page. Without clearance of its own,
    // a tap meant for a tab takes the phone home.
    atLeast(bar.clearance, 16, 'clearance below the last tab row');
  });

  it('has every tab it is supposed to', function () {
    atLeast(bar.count, 5, 'tab count');
  });

  /* ---- the board ---- */

  const cards = await page.evaluate(function () {
    return Array.prototype.slice.call(document.querySelectorAll('.card')).map(function (card) {
      return {
        height: Math.round(card.getBoundingClientRect().height),
        content: card.scrollHeight,
        buttons: card.querySelectorAll('button').length,
        shortestButton: Math.min.apply(Math, [Infinity].concat(
          Array.prototype.slice.call(card.querySelectorAll('button')).map(function (b) {
            return b.getBoundingClientRect().height;
          })))
      };
    });
  });

  it('renders a board to measure', function () {
    atLeast(cards.length, 8, 'cards on screen');
  });

  it('never clips a card to less than what is inside it', function () {
    // A flex child shrinks by default. Squeezed below its content and with
    // overflow hidden, a card cuts its own bottom off — which took the
    // Accept button off every contract on the board and left no sign of it.
    const clipped = cards.filter(function (c) { return c.content > c.height + 1; });
    truthy(clipped.length === 0,
      clipped.length + ' of ' + cards.length + ' cards are shorter than their '
      + 'contents: ' + JSON.stringify(clipped.slice(0, 3)));
  });

  it('leaves every card its action button, at a usable size', function () {
    const withoutButtons = cards.filter(function (c) { return c.buttons === 0; });
    truthy(withoutButtons.length === 0,
      withoutButtons.length + ' cards have no button at all');
    const tiny = cards.filter(function (c) { return c.shortestButton < 36; });
    truthy(tiny.length === 0,
      tiny.length + ' cards carry a button under 36px: ' + JSON.stringify(tiny.slice(0, 3)));
  });

  const scrolls = await page.evaluate(function () {
    const main = document.querySelector('main');
    return { scrollHeight: main.scrollHeight, clientHeight: main.clientHeight };
  });
  const boardEscapees = await escapedFrom(page);
  it('keeps every part of a board card inside the card', function () {
    truthy(boardEscapees.length === 0,
      boardEscapees.length + ' element(s) outside their card: '
      + boardEscapees.slice(0, 4).join(' | '));
  });

  it('gives the board a scroll rather than clipping it', function () {
    truthy(scrolls.scrollHeight > scrolls.clientHeight,
      'eight contracts should overflow a phone screen, so this measures '
      + 'nothing: ' + JSON.stringify(scrolls));
  });

  /* ---- the place form ---- */

  await page.click('[data-tab="place"]');
  await page.waitForTimeout(300);

  const form = await page.evaluate(function () {
    function box(selector) {
      const node = document.querySelector(selector);
      if (!node) return null;
      const rect = node.getBoundingClientRect();
      return { width: Math.round(rect.width), height: Math.round(rect.height) };
    }
    const inputs = Array.prototype.slice.call(
      document.querySelectorAll('main input, main select'));
    return {
      submit: box('#place-submit'),
      target: box('#target-query'),
      shortestInput: Math.min.apply(Math, [Infinity].concat(inputs.map(function (i) {
        // A hidden field has no box and is not something anyone touches. A
        // checkbox is deliberately small and gets its target from the label
        // around it, which is measured separately below.
        if (i.type === 'hidden' || i.type === 'checkbox') return Infinity;
        return i.getBoundingClientRect().height;
      }))),
      // The row a checkbox lives in is what a thumb actually aims at.
      toggleRow: box('.toggle'),
      // The content width the form has to fill, padding excluded — the
      // element's own clientWidth includes it and nothing can reach that.
      formWidth: (function () {
        const main = document.querySelector('main');
        const style = getComputedStyle(main);
        return Math.round(main.clientWidth
          - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight));
      })(),
      overflowsSideways: document.querySelector('main').scrollWidth
        > document.querySelector('main').clientWidth + 1
    };
  });

  it('gives the form its target box and its submit', function () {
    truthy(form.target, 'no target field on the place form');
    truthy(form.submit, 'no submit button on the place form');
  });

  it('makes the one action the form is for full width', function () {
    atLeast(form.submit.width, form.formWidth - 4, 'submit width');
    atLeast(form.submit.height, 44, 'submit height');
  });

  it('gives every field on the form a thumb-sized target', function () {
    atLeast(form.shortestInput, 40, 'shortest field on the place form');
  });

  it('makes the whole row of a checkbox its target, not the box', function () {
    truthy(form.toggleRow, 'no toggle row on the place form');
    atLeast(form.toggleRow.height, 40, 'the anonymity toggle row');
  });

  it('never makes the page scroll sideways', function () {
    truthy(!form.overflowsSideways,
      'a phone screen has no horizontal room to spare');
  });

  /* ---- nothing is cut off by its own container ----
   *
   * A creator's own contract carries up to seven actions, and they sat in
   * one non-wrapping row: five hundred pixels of buttons inside a three
   * hundred pixel card, with `overflow: hidden` on the card cutting the
   * rest off. The buttons were not missing, they were off the edge — and
   * neither the server suite nor the DOM shim can see an edge. */

  async function clippedNodes() {
    return page.evaluate(function () {
      const out = [];
      document.querySelectorAll('main *').forEach(function (n) {
        const s = getComputedStyle(n);
        const hidesY = s.overflow === 'hidden' || s.overflowY === 'hidden';
        if (hidesY && n.scrollHeight > n.clientHeight + 1) {
          out.push((n.className || n.tagName) + ' cut vertically: '
            + n.clientHeight + 'px tall, ' + n.scrollHeight + 'px of content');
        }
        // Sideways is the one that bit: a row of buttons wider than the
        // card holding it, on a screen with no horizontal room to give.
        if (s.overflowX !== 'auto' && s.overflowX !== 'scroll'
            && n.scrollWidth > n.clientWidth + 1) {
          out.push((n.className || n.tagName) + ' cut sideways: '
            + n.clientWidth + 'px wide, ' + n.scrollWidth + 'px of content');
        }
      });
      return out;
    });
  }

  await page.click('[data-tab="mine"]');
  await page.waitForTimeout(300);
  const mineClipped = await clippedNodes();

  it('cuts nothing off on the contracts you placed and took', function () {
    truthy(mineClipped.length === 0,
      mineClipped.length + ' element(s) clipped: ' + mineClipped.slice(0, 4).join(' | '));
  });

  const mineButtons = await page.evaluate(function () {
    const cards = Array.prototype.slice.call(document.querySelectorAll('.card'));
    return cards.map(function (card) {
      const buttons = Array.prototype.slice.call(card.querySelectorAll('button'));
      const box = card.getBoundingClientRect();
      return {
        count: buttons.length,
        outside: buttons.filter(function (b) {
          const r = b.getBoundingClientRect();
          return r.right > box.right + 1 || r.left < box.left - 1;
        }).length
      };
    });
  });

  it('keeps every action inside the card it belongs to', function () {
    const escaped = mineButtons.filter(function (c) { return c.outside > 0; });
    truthy(escaped.length === 0,
      escaped.length + ' card(s) have buttons outside their own edges: '
      + JSON.stringify(escaped.slice(0, 3)));
    truthy(mineButtons.some(function (c) { return c.count >= 4; }),
      'this measures nothing unless a card carries several actions');
  });

  /* Nothing at all outside the card, not only buttons.
   *
   * The check above measures <button> and nothing else, and the clipping
   * check measures scrollWidth against clientWidth — which a parent with
   * `overflow: hidden` defeats, because the overflowing child is simply not
   * drawn and the parent reports no overflow of its own.
   *
   * Between the two, a reward block 90px wider than its card passed this
   * suite: measured at 390x720, the money — the headline number on a bounty
   * board and the entire reason a hunter reads the card — had its right
   * edge at 466px on a card ending at 376px. It was not small, and it was
   * not badly placed. It was not on the screen.
   *
   * So: every element inside a card, against the card's own edges. */
  const escapees = await escapedFrom(page);

  it('keeps every part of a card inside the card', function () {
    truthy(escapees.length === 0,
      escapees.length + ' element(s) outside their card: '
      + escapees.slice(0, 4).join(' | '));
  });

  await page.click('[data-tab="place"]');
  await page.waitForTimeout(300);
  const placeClipped = await clippedNodes();

  it('cuts nothing off on the place form either', function () {
    truthy(placeClipped.length === 0,
      placeClipped.length + ' element(s) clipped: ' + placeClipped.slice(0, 4).join(' | '));
  });

  /* ---- changing what a contract pays ----
   *
   * The dialog with the most content in the app: a reward can be a dozen
   * lines, each a tickable row. A dialog whose own buttons are pushed off
   * the bottom is a dialog a player cannot leave, and neither the server
   * suite nor the DOM shim can see a bottom. */

  await page.click('[data-tab="mine"]');
  await page.waitForTimeout(300);
  await page.evaluate(function () {
    const buttons = Array.prototype.slice.call(document.querySelectorAll('button'));
    const change = buttons.filter(function (b) { return b.textContent === 'Change reward'; })[0];
    if (change) change.click();
  });
  await page.waitForTimeout(300);

  const editor = await page.evaluate(function () {
    const nav = document.querySelector('.tabs');
    const navTop = nav.getBoundingClientRect().top;
    const panel = document.querySelector('.dialog');
    if (!panel) return null;

    const buttons = Array.prototype.slice.call(panel.querySelectorAll('button'));
    const boxes = Array.prototype.slice.call(
      panel.querySelectorAll('input[type="checkbox"]'));
    const rows = Array.prototype.slice.call(panel.querySelectorAll('.reward-line'));
    const list = panel.querySelector('.reward-lines');

    return {
      boxes: boxes.length,
      labels: buttons.map(function (b) { return b.textContent; }),
      // Every button has to be reachable: on screen, and above the tab bar
      // rather than behind it.
      buried: buttons.filter(function (b) {
        const r = b.getBoundingClientRect();
        return r.bottom > navTop + 1 || r.top < 0;
      }).map(function (b) { return b.textContent; }),
      shortestButton: Math.min.apply(Math, [Infinity].concat(
        buttons.map(function (b) { return b.getBoundingClientRect().height; }))),
      // A tickable row is a tap target like any other.
      shortestRow: Math.min.apply(Math, [Infinity].concat(
        rows.map(function (r) { return r.getBoundingClientRect().height; }))),
      // The list scrolls; the dialog does not grow past the screen.
      listScrolls: list ? list.scrollHeight > list.clientHeight : false,
      listOverflow: list ? getComputedStyle(list).overflowY : null,
      panelClipped: panel.scrollHeight > panel.clientHeight + 1
        && getComputedStyle(panel).overflowY === 'hidden'
    };
  });

  it('opens a reward editor to measure', function () {
    truthy(editor, 'the Change reward button did not open a dialog');
    atLeast(editor.boxes, 14, 'tickable lines');
  });

  it('keeps every button in the editor reachable', function () {
    truthy(editor.buried.length === 0,
      'behind the tab bar or off screen: ' + editor.buried.join(' | '));
    atLeast(editor.shortestButton, 36, 'shortest button in the editor');
  });

  it('gives every tickable line a thumb-sized row', function () {
    atLeast(editor.shortestRow, 40, 'shortest reward line');
  });

  it('scrolls the lines rather than growing the dialog past the screen', function () {
    truthy(editor.listScrolls,
      'fourteen lines should overflow the list, so this measures nothing');
    truthy(editor.listOverflow === 'auto' || editor.listOverflow === 'scroll',
      'the list has to scroll, not clip: overflow-y is ' + editor.listOverflow);
    truthy(!editor.panelClipped, 'the dialog is cutting off its own contents');
  });

  const editorClipped = await clippedNodes();
  it('cuts nothing off in the reward editor', function () {
    truthy(editorClipped.length === 0,
      editorClipped.length + ' element(s) clipped: ' + editorClipped.slice(0, 4).join(' | '));
  });

  /* ---- every screen this might be on ----
   *
   * Everything above measures one 390x720 viewport, which is how a dialog
   * whose buttons sat under the tab bar on a shorter phone passed a suite
   * whose whole purpose is catching that. A player reported it. The sizes
   * below are swept for the two faults that actually strand somebody: a
   * control that cannot be reached without scrolling a panel that reads as
   * a modal, and anything cut off sideways on a screen with no horizontal
   * room to give. */

  const SIZES = [
    [280, 560, 'very small'], [320, 568, 'small'], [360, 640, 'common'],
    [390, 720, 'default'], [414, 896, 'large'], [390, 560, 'short'],
  ];

  const sizeFaults = [];
  // A step whose button is not on screen is skipped, and a sweep that
  // silently skipped everything would pass while measuring nothing.
  const missedSteps = [];
  let measuredDialogs = 0;
  for (const [w, h, label] of SIZES) {
    const p2 = await browser.newPage({ viewport: { width: w, height: h } });
    await p2.addInitScript(serverStub);
    await p2.goto('file://' + UI);
    await p2.waitForTimeout(250);

    // Every screen a player can reach, including the dialogs added since
    // this suite was written. A dialog is where things run off the bottom:
    // it reads as a modal, so a button of its own below the fold reads as
    // missing rather than as needing a scroll.
    const steps = [['board', null], ['mine', null], ['place', null],
                   ['onme', null], ['ledger', null],
                   ['mine', 'Change reward'],
                   ['mine', 'Propose change'],
                   ['mine', 'Buy informant data'],
                   ['mine', 'Extend deadline'],
                   ['mine', 'Edit'],
                   ['mine', 'Withdraw']];

    for (const [tab, press] of steps) {
      await p2.click(`[data-tab="${tab}"]`);
      await p2.waitForTimeout(180);
      if (press) {
        const opened = await p2.evaluate(function (labelText) {
          const b = Array.prototype.slice.call(document.querySelectorAll('button'))
            .filter(function (n) { return n.textContent === labelText; })[0];
          if (!b) return false;
          b.click();
          return true;
        }, press);
        if (!opened) { missedSteps.push(label + ' ' + tab + ' > ' + press); continue; }
        await p2.waitForTimeout(220);
        measuredDialogs++;
      }

      const faults = await p2.evaluate(function () {
        const out = [];
        const navRect = document.querySelector('.tabs').getBoundingClientRect();

        if (navRect.bottom > window.innerHeight + 0.5) {
          out.push('the tab bar runs off the bottom');
        }

        // A dialog reads as a modal, so a button of its own below the fold
        // reads as missing rather than as needing a scroll.
        const panel = document.querySelector('.dialog');
        if (panel) {
          Array.prototype.slice.call(panel.querySelectorAll('button')).forEach(function (b) {
            const r = b.getBoundingClientRect();
            if (r.bottom > navRect.top + 1) {
              out.push('dialog button "' + b.textContent + '" is behind the tab bar');
            }
          });
        }

        // Sideways, on a screen with no room to give. Text inputs scroll
        // their own value by design and are not clipping.
        Array.prototype.slice.call(document.querySelectorAll('main *')).forEach(function (n) {
          if (n.tagName === 'INPUT' || n.tagName === 'TEXTAREA' || n.tagName === 'SELECT') return;
          const st = getComputedStyle(n);
          if (st.overflowX !== 'auto' && st.overflowX !== 'scroll'
              && n.scrollWidth > n.clientWidth + 1) {
            out.push((n.className || n.tagName) + ' is cut off sideways');
          }
        });

        return out;
      });

      faults.forEach(function (f) {
        sizeFaults.push(label + ' ' + tab + (press ? ' > ' + press : '') + ': ' + f);
      });
    }
    await p2.close();
  }

  it('actually opened the dialogs it claims to have measured', function () {
    truthy(measuredDialogs >= 20,
      'only ' + measuredDialogs + ' dialog screens were measured across '
      + SIZES.length + ' sizes; the rest were skipped because their button '
      + 'was not found: ' + Array.from(new Set(missedSteps)).join(' | '));
  });

  /* ---- what reads as important ---- */

  await page.click('[data-tab="ledger"]');
  await page.waitForTimeout(300);

  const proof = await page.evaluate(function () {
    const frame = document.querySelector('.proof');
    if (!frame) { return null; }
    const card = frame.closest('.card');
    return {
      frameH: Math.round(frame.getBoundingClientRect().height),
      cardH: Math.round(card.getBoundingClientRect().height),
      viewportH: window.innerHeight
    };
  });

  it('never lets one history entry fill the screen', function () {
    truthy(proof, 'no proof photograph rendered, so this measures nothing');
    truthy(proof.cardH < proof.viewportH * 0.7,
      'a 1080x1920 photograph made one ledger card ' + proof.cardH + 'px tall '
      + 'on a ' + proof.viewportH + 'px screen, so the entry above it and the '
      + 'entry below it are both off screen');
  });

  await page.click('[data-tab="onme"]');
  await page.waitForTimeout(300);

  const hierarchy = await page.evaluate(function () {
    const label = document.querySelector('.section');
    const target = document.querySelector('.card .target');
    const buttons = Array.prototype.slice.call(
      document.querySelectorAll('.card button'));
    function size(n) { return n ? parseFloat(getComputedStyle(n).fontSize) : null; }
    /* Carries the primary treatment — the crimson gradient.
    
       An earlier version of this asked merely whether the button had a
       background, and every button in the sheet has one: the base rule sets
       --panel-2, so only .ghost answered no. It reported the buyout as
       prominent whether or not it was primary, and passed against the very
       CSS it was written to catch. The gradient is what "this is the main
       action" is actually made of, so that is what it looks for. */
    function primary(n) {
      return getComputedStyle(n).backgroundImage.indexOf('gradient') !== -1;
    }

    const buyout = buttons.filter(function (b) {
      return b.textContent.indexOf('Buy out') === 0;
    })[0];
    const extra = buttons.filter(function (b) {
      return b.textContent.indexOf('Buy informant') === 0;
    })[0];
    return {
      labelSize: size(label), targetSize: size(target),
      buyoutPrimary: buyout ? primary(buyout) : null,
      extraPrimary: extra ? primary(extra) : null,
      othersPrimary: buttons.filter(function (b) {
        return b !== buyout && primary(b);
      }).map(function (b) { return b.textContent.slice(0, 20); }),
      haveBoth: !!(buyout && extra)
    };
  });

  it('draws the target\'s one move louder than the paid extra beside it', function () {
    truthy(hierarchy.haveBoth,
      'both buttons have to be on screen or this measures nothing: '
      + JSON.stringify(hierarchy));
    truthy(hierarchy.buyoutPrimary,
      'the only move the target of a contract has was drawn as an outline, '
      + 'no louder than the paid extra beside it');
    truthy(hierarchy.extraPrimary === false,
      'and the paid extra beside it must not be drawn the same way');
    truthy(hierarchy.othersPrimary.length === 0,
      'nothing else on the card should compete with it: '
      + hierarchy.othersPrimary.join(', '));
  });

  await page.click('[data-tab="mine"]');
  await page.waitForTimeout(300);
  const grouping = await page.evaluate(function () {
    function size(n) { return n ? parseFloat(getComputedStyle(n).fontSize) : null; }
    const target = size(document.querySelector('.card .target'));
    /* Every grouping heading in the content area, not the first one styled.
    
       Asking for `.section` found whichever heading still had the class, so
       leaving one of the two unstyled passed: the query simply matched the
       other. The headings are found by tag instead, which is what they
       actually are, so one left behind is one that fails. */
    const labels = Array.prototype.slice.call(
      document.querySelectorAll('#view h3')).map(function (n) {
        return { text: n.textContent.slice(0, 24), size: size(n) };
      });
    return { labels: labels, targetSize: target };
  });

  it('does not let a grouping label outrank the contracts it groups', function () {
    truthy(grouping.labels.length >= 2 && grouping.targetSize,
      'both groups have to be on screen or this measures one of them: '
      + JSON.stringify(grouping));
    const loud = grouping.labels.filter(function (l) {
      return l.size >= grouping.targetSize;
    });
    truthy(loud.length === 0,
      'a grouping label was drawn at least as large as the name of the person '
      + 'there is a price on (' + grouping.targetSize + 'px): '
      + JSON.stringify(loud));
  });

  it('fits every screen size it might be opened on', function () {
    const unique = Array.from(new Set(sizeFaults));
    truthy(unique.length === 0,
      unique.length + ' fault(s): ' + unique.slice(0, 6).join(' | '));
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
