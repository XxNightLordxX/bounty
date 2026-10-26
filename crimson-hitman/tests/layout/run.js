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
 * headline number on a contract board and the entire reason a hitman reads
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
      hitmenActive: 1, hitmenMax: 5,
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
    hitmenActive: 4, hitmenMax: 5,
    targetName: 'Maximilian Featherstonehaugh-Cholmondeley',
    creatorName: 'Vic Marlowe', role: 'public'
  });

  // A creator's own contract carries the most actions of any card, which
  // is the case that overflowed.
  const own = contracts.slice(0, 3).map(function (c) {
    const copy = JSON.parse(JSON.stringify(c));
    copy.role = 'creator';
    copy.hitmenActive = 0;
    copy.hitmen = [];
    // More than one collection, so "Give back the last payout" is offered
    // and its dialog gets measured too.
    copy.slots = 3;
    copy.currentSlot = 1;
    copy.deadline = Math.floor(Date.now() / 1000) + 7200;
    return copy;
  });
  const taken = contracts.slice(3, 5).map(function (c) {
    const copy = JSON.parse(JSON.stringify(c));
    copy.role = 'hitman';
    return copy;
  });
  // One taken under live transfer only, as the server places them: no
  // bonus, the rule as a chip, and Deliver alive alone on the top line
  // where the other card has Verify kill beside it.
  taken[1].fulfilment = 'alive';
  taken[1].reward = { baseline: taken[1].reward.baseline, bonus: 0 };
  // And on the board, where the line under the reward says to whom the
  // target is brought; and on a placer's own card once a hitman has it,
  // which says a hitman is bringing the target to them. Both measured with
  // every other card, at phone width.
  contracts[1].fulfilment = 'alive';
  contracts[1].reward = { baseline: contracts[1].reward.baseline, bonus: 0 };
  own[2].fulfilment = 'alive';
  own[2].reward = { baseline: own[2].reward.baseline, bonus: 0 };
  own[2].hitmenActive = 1;
  own[2].hitmen = [{ alias: 'Operative #1' }];

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
      hitmenActive: 2, hitmenMax: 5,
      targetName: 'You', role: 'target',
      bailoutAvailable: true, bailoutAmount: 90000,
      deadline: Math.floor(Date.now() / 1000) + 7200
    }] } },
    ledger: { ok: true, data: { entries: [{
      // The client's row, with their kill photo waiting to be opened. Only
      // the client's row ever carries one.
      contract_id: 'ct00000001',
      target_name: 'Dana Reyes', reason: 'Unpaid debt', role: 'creator',
      fulfilment: 'elimination', resolved_at: 1700000000,
      photo: { handle: 'ph00000000aa', state: 'pending' }
    }],
      // A photo kept for the client in the app whose row has gone: listed
      // on its own under the history.
      kept: [{ handle: 'ph00000000bb', state: 'kept',
               taken_at: Math.floor(Date.now() / 1000) - 3 * 86400 }],
      record: { completed: 0, placed: 0, survived: 0, standing: 'Unproven' } } },
    // A full-resolution portrait photograph, which is what a phone camera
    // hands over. Unbounded, one of these once made a history entry taller
    // than the whole viewport. Kept on the server, which can serve it to the
    // phone's Photos (link), so the dialog offers Save to Photos.
    openPhoto: { ok: true, data: { handle: 'ph00000000aa', link: true,
      url: 'data:image/svg+xml;base64,' + btoa(
        '<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1920">'
        + '<rect width="1080" height="1920" fill="#555"/></svg>') } },
    photoDecision: { ok: true, data: { handle: 'ph00000000aa', state: 'deleted' } },
    // A server that keeps its photos itself: Verify kill opens the app's
    // own viewfinder rather than lb-phone's camera.
    takeVerificationPhoto: { ok: true, data: { viewfinder: true, maxSide: 1280, maxBytes: 600000 } },
    rewardOptions: { ok: true, data: { cash: 100000, bank: 50000, dirty: 2000,
      items: [{ name: 'lockpick', label: 'Lockpick', count: 5 }],
      weapons: [{ name: 'WEAPON_PISTOL', label: 'Pistol', slot: 3, serial: 'C123' }],
      inventoryRead: true,
      // minValue as shipped (Config.Limits.MinContractReward), so the Place
      // form is measured with the hint that names it drawn.
      caps: { itemsEnabled: true, weaponsEnabled: true, maxStacks: 3,
              maxPerStack: 100, maxWeapons: 2, slots: 5, bonusPercent: 200,
              minValue: 1000 } } },
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
   * contract carries hitmen = [] from the moment it is placed. So this
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

  /* ---- lb-phone's status bar ----
   *
   * The other edge. lb-phone draws no header over a custom app: its clock,
   * the island and the battery lie straight over the top of the page, the
   * island ending about 3.45rem down. The page took out its own header
   * believing lb-phone drew one, and kept 0.9rem at the top — so the first
   * card's name, Mine's first heading, a thread's Back and Call and the
   * first line of every notice sat under the status bar. Measured against
   * that line, in the page's own rem. */
  const STATUS_BAR_REM = 3.45;
  function clearOfStatusBar(probe, selector) {
    return probe.evaluate(function (which) {
      const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
      const node = document.querySelector(which);
      if (!node) { return null; }
      return node.getBoundingClientRect().top / rem;
    }, selector);
  }
  const firstOnBoard = await clearOfStatusBar(page, '#view > *');

  it('starts the board below lb-phone\'s status bar', function () {
    truthy(firstOnBoard !== null, 'nothing drawn on the board, so this measures nothing');
    atLeast(firstOnBoard, STATUS_BAR_REM, 'the first card starts (rem)');
  });

  /* ---- lb-phone's light theme ----
   *
   * Its default. lb-phone draws the clock, signal, battery and the home
   * indicator onto the page in black in the light theme, and the page is
   * near-black: they vanished, the way out of the app with them. A paper
   * band goes under each, in the light theme only, set on the root (as the
   * page does) or on the body (as lb-phone may). */
  const bands = await page.evaluate(function () {
    function luminance(css) {
      const m = /rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)/.exec(css || '');
      if (!m) { return -1; }
      return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) / 255;
    }
    function read() {
      const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
      const top = getComputedStyle(document.body, '::before');
      const bottom = getComputedStyle(document.body, '::after');
      return {
        topShown: top.content !== 'none' && top.content !== 'normal',
        topAt: top.top, topRem: parseFloat(top.height) / rem,
        topLight: luminance(top.backgroundColor),
        topZ: parseInt(top.zIndex, 10), topTaps: top.pointerEvents,
        bottomShown: bottom.content !== 'none' && bottom.content !== 'normal',
        bottomPx: parseFloat(bottom.height), bottomLight: luminance(bottom.backgroundColor),
        bottomAt: bottom.bottom
      };
    }
    const dark = read();
    document.documentElement.setAttribute('data-theme', 'light');
    const onRoot = read();
    document.documentElement.removeAttribute('data-theme');
    document.body.setAttribute('data-theme', 'light');
    const onBody = read();
    document.body.removeAttribute('data-theme');
    return { dark: dark, onRoot: onRoot, onBody: onBody };
  });

  it('lays a paper band under lb-phone\'s status bar in its light theme', function () {
    [['on the root', bands.onRoot], ['on the body', bands.onBody]].forEach(function (pair) {
      const b = pair[1];
      truthy(b.topShown, 'no band with the theme ' + pair[0]);
      truthy(b.topAt === '0px', 'the band starts at ' + b.topAt + ' ' + pair[0]);
      atLeast(b.topRem, STATUS_BAR_REM, 'the band covers the status bar (rem) ' + pair[0]);
      atLeast(b.topLight, 0.75, 'black glyphs need a light band ' + pair[0]);
      atLeast(b.topZ, 91, 'over the viewfinder (z-index 90) ' + pair[0]);
      truthy(b.topTaps === 'none', 'the band takes taps ' + pair[0]);
    });
  });

  it('and under the home indicator', function () {
    [['on the root', bands.onRoot], ['on the body', bands.onBody]].forEach(function (pair) {
      const b = pair[1];
      truthy(b.bottomShown, 'no band with the theme ' + pair[0]);
      truthy(b.bottomAt === '0px', 'the band ends at ' + b.bottomAt + ' ' + pair[0]);
      atLeast(b.bottomPx, 16, 'the band under the home indicator (px) ' + pair[0]);
      atLeast(b.bottomLight, 0.75, 'a light band ' + pair[0]);
    });
  });

  it('draws no band in the dark theme', function () {
    truthy(!bands.dark.topShown && !bands.dark.bottomShown,
      'a band drawn without the light theme: ' + JSON.stringify(bands.dark));
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
   * suite: measured at 390x720, the money — the headline number on a contract
   * board and the entire reason a hitman reads the card — had its right
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

  /* A contract that pays only for a live delivery has one way to finish,
     where the row was laid out for two side by side. */
  const lone = await page.evaluate(function () {
    const deliver = Array.prototype.slice.call(document.querySelectorAll('.actions.is-working > button'))
      .filter(function (b) {
        return b.textContent === 'Deliver alive' && b.classList.contains('primary');
      })[0];
    if (!deliver) { return null; }
    const row = deliver.parentNode.getBoundingClientRect();
    const r = deliver.getBoundingClientRect();
    const style = getComputedStyle(deliver.parentNode);
    return { width: r.width, height: r.height,
             room: row.width - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
             beside: deliver.parentNode.querySelectorAll(':scope > button').length };
  });

  it('gives Deliver alive the whole line where it is the only way to finish', function () {
    truthy(lone, 'no card taken under live transfer only, so this measures nothing');
    truthy(lone.beside === 1, 'it shares the line with ' + (lone.beside - 1) + ' other button(s)');
    atLeast(lone.width, lone.room - 1, 'Deliver alive across its row (px)');
    atLeast(lone.height, 36, 'Deliver alive height (px)');
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

  /* ---- the head of a thread ----
   *
   * Back, Call and Mute each took their width out of the middle of one
   * line, the who-and-what: at 390px a client's thread read "with Operat…",
   * and one with several operatives could not tell which one it was writing
   * to. Measured with Call and Unmute both drawn, Unmute being the wider. */
  function threadStub() {
    const contract = {
      id: 'ct00000031', reason: 'Unpaid debt', mode: 'competitive', state: 'accepted',
      reward: { baseline: 5000 }, slots: 1, slotsClaimed: 0, currentSlot: 1,
      hitmenActive: 1, hitmenMax: 5, role: 'creator',
      targetName: 'Maximilian Featherstonehaugh-Cholmondeley',
      hitmen: [{ alias: 'Operative #2', name: 'Vic Marlowe' }],
    };
    const answers = {
      list: { ok: true, data: { page: 1, pages: 1, contracts: [],
        settings: { calls: true, reasonMode: 'freetext' } } },
      mine: { ok: true, data: { created: [contract] } },
      threads: { ok: true, data: [{ handle: 'h2', alias: 'Operative #2', name: 'Vic Marlowe' }] },
      readThread: { ok: true, data: { muted: true,
        messages: [{ alias: 'Operative #2', body: 'On it.' }] } },
    };
    window.fetch = function (url) {
      const name = url.split('/crimson:')[1];
      return Promise.resolve({ json: function () {
        return Promise.resolve(answers[name] || { ok: true });
      } });
    };
  }

  const tp = await browser.newPage({ viewport: { width: 390, height: 720 } });
  await tp.addInitScript(threadStub);
  await tp.goto('file://' + UI);
  await tp.waitForTimeout(250);
  await tp.click('[data-tab="mine"]');
  await tp.waitForTimeout(200);
  await tp.evaluate(function () {
    const b = Array.prototype.slice.call(document.querySelectorAll('button'))
      .filter(function (n) { return n.textContent === 'Threads'; })[0];
    if (b) { b.click(); }
  });
  await tp.waitForTimeout(250);
  const threadButtonsTop = await clearOfStatusBar(tp, '.thread-head button');
  const threadHead = await tp.evaluate(function () {
    const withLine = document.querySelector('.thread-head .with');
    const about = document.querySelector('.thread-head .about');
    const call = document.getElementById('thread-call');
    const mute = document.getElementById('thread-mute');
    if (!withLine) { return null; }
    // What "with Operative #2" takes, in the line's own font.
    const probe = document.createElement('span');
    probe.textContent = 'with Operative #2';
    probe.style.whiteSpace = 'nowrap';
    withLine.appendChild(probe);
    const needed = probe.getBoundingClientRect().width;
    withLine.removeChild(probe);
    return {
      text: withLine.textContent, needed: Math.ceil(needed),
      width: Math.floor(withLine.getBoundingClientRect().width),
      about: about ? Math.floor(about.getBoundingClientRect().width) : 0,
      call: !!(call && call.getBoundingClientRect().width > 0),
      mute: mute ? mute.textContent : null,
    };
  });
  await tp.close();

  it('keeps which operative a thread is with readable beside Call and Mute', function () {
    truthy(threadHead, 'the thread did not open, so this measures nothing');
    truthy(threadHead.call && threadHead.mute === 'Unmute',
      'Call and Unmute both have to be drawn: ' + JSON.stringify(threadHead));
    atLeast(threadHead.width, threadHead.needed,
      '"with Operative #2" is cut off (' + JSON.stringify(threadHead) + ')');
    atLeast(threadHead.about, 120, 'the target\'s name');
  });

  it('keeps a thread\'s Back and Call below lb-phone\'s status bar', function () {
    truthy(threadButtonsTop !== null, 'the thread did not open, so this measures nothing');
    atLeast(threadButtonsTop, STATUS_BAR_REM, 'the thread\'s first button starts (rem)');
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
                   ['mine', 'Withdraw'],
                   ['ledger', 'View photo']];

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

  const ledgerCard = await page.evaluate(function () {
    const card = document.querySelector('.proof-line');
    if (!card) { return null; }
    return {
      cardH: Math.round(card.closest('.card').getBoundingClientRect().height),
      viewportH: window.innerHeight,
      images: document.querySelectorAll('#view img').length
    };
  });

  it('keeps the photo out of the history list', function () {
    truthy(ledgerCard, 'no photo line rendered, so this measures nothing');
    truthy(ledgerCard.images === 0, 'a photo was drawn in the list: ' + ledgerCard.images);
    truthy(ledgerCard.cardH < ledgerCard.viewportH * 0.5,
      'one ledger card is ' + ledgerCard.cardH + 'px tall on a '
      + ledgerCard.viewportH + 'px screen');
  });

  await page.evaluate(function () {
    const b = Array.prototype.slice.call(document.querySelectorAll('button'))
      .filter(function (n) { return n.textContent === 'View photo'; })[0];
    if (b) { b.click(); }
  });
  await page.waitForTimeout(300);

  /* The one look at a kill photo, at phone size. It is shown once, so it
     has to be shown properly: the photo as large as the screen allows,
     whole rather than cropped, and both buttons on screen however tall the
     photo is — a Save button under the tab bar is a photo that is lost. */
  const oneView = await page.evaluate(function () {
    const panel = document.querySelector('.dialog.photo-view');
    if (!panel) { return null; }
    const img = panel.querySelector('img');
    const frame = panel.querySelector('.photo-frame');
    const nav = document.querySelector('.tabs').getBoundingClientRect();
    const buttons = Array.prototype.slice.call(panel.querySelectorAll('button'));
    const ir = img.getBoundingClientRect();
    const fr = frame.getBoundingClientRect();
    return {
      buried: buttons.filter(function (b) {
        return b.getBoundingClientRect().bottom > nav.top + 1;
      }).map(function (b) { return b.textContent; }),
      labels: buttons.map(function (b) { return b.textContent; }),
      shortest: Math.min.apply(Math, buttons.map(function (b) {
        return b.getBoundingClientRect().height;
      })),
      imgH: Math.round(ir.height), imgW: Math.round(ir.width),
      inFrame: ir.top >= fr.top - 1 && ir.bottom <= fr.bottom + 1
        && ir.left >= fr.left - 1 && ir.right <= fr.right + 1,
      viewportH: window.innerHeight
    };
  });

  it('opens the photo in a dialog of its own', function () {
    truthy(oneView, 'the View photo button did not open anything, so this measures nothing');
    truthy(oneView.labels.indexOf('Save to Photos') !== -1 && oneView.labels.indexOf('Delete') !== -1,
      'both choices: ' + JSON.stringify(oneView.labels));
  });

  it('keeps Save to Photos and Delete on screen above the tab bar', function () {
    truthy(oneView && oneView.buried.length === 0,
      'behind the tab bar: ' + JSON.stringify(oneView && oneView.buried));
    atLeast(oneView ? oneView.shortest : 0, 36, 'shortest button in the photo dialog');
  });

  it('shows the photo whole and large', function () {
    truthy(oneView && oneView.inFrame, 'the photo spills out of its frame: ' + JSON.stringify(oneView));
    atLeast(oneView ? oneView.imgH : 0, Math.round((oneView ? oneView.viewportH : 0) * 0.4),
      'a photo the client sees once is drawn ' + (oneView && oneView.imgH) + 'px tall');
    // Portrait in, portrait out: contained, not stretched or cropped.
    truthy(oneView && oneView.imgW < oneView.imgH,
      'the 9:16 photo is drawn ' + (oneView && oneView.imgW) + 'x' + (oneView && oneView.imgH));
  });

  /* The same dialog once the phone has refused the photo: the longest
     label it carries, "Keep it in the app instead", beside Delete. Both on
     screen and whole at phone size, the smallest included, or a photo the
     phone could not take is a photo that is lost. The fixture hands back
     no link, so the save fails as a phone refusing it would. */
  const refusedViews = [];
  for (const [w, h] of [[280, 560], [390, 720]]) {
    const rp = await browser.newPage({ viewport: { width: w, height: h } });
    await rp.addInitScript(serverStub);
    await rp.goto('file://' + UI);
    await rp.waitForTimeout(250);
    await rp.click('[data-tab="ledger"]');
    await rp.waitForTimeout(200);
    for (const label of ['View photo', 'Save to Photos']) {
      await rp.evaluate(function (text) {
        const b = Array.prototype.slice.call(document.querySelectorAll('button'))
          .filter(function (n) { return n.textContent === text; })[0];
        if (b) { b.click(); }
      }, label);
      await rp.waitForTimeout(250);
    }
    refusedViews.push(await rp.evaluate(function (size) {
      const panel = document.querySelector('.dialog.photo-view');
      if (!panel) { return { size: size, missing: true }; }
      const nav = document.querySelector('.tabs').getBoundingClientRect();
      const box = panel.getBoundingClientRect();
      const buttons = Array.prototype.slice.call(panel.querySelectorAll('button'));
      return {
        size: size,
        labels: buttons.map(function (b) { return b.textContent; }),
        buried: buttons.filter(function (b) {
          return b.getBoundingClientRect().bottom > nav.top + 1;
        }).map(function (b) { return b.textContent; }),
        clipped: buttons.filter(function (b) {
          const r = b.getBoundingClientRect();
          return b.scrollWidth > b.clientWidth + 1 || r.right > box.right + 1
            || r.left < box.left - 1;
        }).map(function (b) { return b.textContent; }),
        shortest: Math.min.apply(Math, buttons.map(function (b) {
          return b.getBoundingClientRect().height;
        }))
      };
    }, w + 'x' + h));
    await rp.close();
  }

  it('offers to keep a photo the phone refused, on screen and whole', function () {
    refusedViews.forEach(function (v) {
      truthy(!v.missing, v.size + ': the dialog closed when the save failed, so this measures nothing');
      truthy(v.labels.indexOf('Keep it in the app instead') !== -1
        && v.labels.indexOf('Delete') !== -1, v.size + ': ' + JSON.stringify(v.labels));
      truthy(v.buried.length === 0, v.size + ' behind the tab bar: ' + JSON.stringify(v.buried));
      truthy(v.clipped.length === 0, v.size + ' cut off: ' + JSON.stringify(v.clipped));
      atLeast(v.shortest, 36, v.size + ': shortest button in the refused photo dialog');
    });
  });

  /* A tab tapped over the photo's one look is refused, with a notice; the
     notice is measured against the status bar while it is up. Then the
     photo is deleted, as the notice asks, so the rest of this page can
     move on. */
  await page.click('[data-tab="onme"]');
  await page.waitForTimeout(120);
  const heldTab = await page.evaluate(function () {
    return {
      photo: !!document.querySelector('.dialog.photo-view'),
      notice: (document.querySelector('#notice') || {}).textContent || ''
    };
  });
  const noticeTop = await clearOfStatusBar(page, '#notice .notice');

  it('holds the tab bar while the photo\'s one look is unanswered', function () {
    truthy(heldTab.photo, 'a tab tap closed the photo, which deletes it');
    truthy(heldTab.notice.indexOf('Save or delete the photo first') !== -1, heldTab.notice);
  });

  it('puts a notice below lb-phone\'s status bar, first line and all', function () {
    truthy(noticeTop !== null, 'no notice was up, so this measures nothing');
    atLeast(noticeTop, STATUS_BAR_REM, 'the notice starts (rem)');
  });

  await page.evaluate(function () {
    const b = Array.prototype.slice.call(document.querySelectorAll('.dialog.photo-view button'))
      .filter(function (n) { return n.textContent === 'Delete'; })[0];
    if (b) { b.click(); }
  });
  await page.waitForTimeout(300);

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

  /* The kill photo viewfinder, on a server that keeps its photos itself.
     Over the whole app, tab bar included, with the game camera taking most
     of the screen, and the shutter clear of lb-phone's home indicator: a
     shutter under the gesture bar is a photo that is never taken. lb-phone's
     game render is stood in for; it draws into the canvas the page gives it. */
  await page.evaluate(function () {
    window.components = {
      createGameRender: function () {
        return {
          destroyed: false,
          resizeByAspect: function () {},
          destroy: function () { this.destroyed = true; },
          takePhoto: function () { return new Promise(function () {}); }
        };
      }
    };
    const b = Array.prototype.slice.call(document.querySelectorAll('button'))
      .filter(function (n) { return n.textContent === 'Verify kill'; })[0];
    if (b) { b.click(); }
  });
  await page.waitForTimeout(300);

  const finder = await page.evaluate(function () {
    const shade = document.getElementById('viewfinder');
    if (!shade) { return null; }
    const r = shade.getBoundingClientRect();
    const frame = shade.querySelector('.viewfinder-frame').getBoundingClientRect();
    const buttons = Array.prototype.slice.call(shade.querySelectorAll('button'));
    const nav = document.querySelector('.tabs').getBoundingClientRect();
    const overTabs = document.elementFromPoint(nav.left + nav.width / 2, nav.top + nav.height / 2);
    return {
      covers: r.left <= 0.5 && r.top <= 0.5 && r.right >= window.innerWidth - 0.5
        && r.bottom >= window.innerHeight - 0.5,
      overTabs: !!overTabs && shade.contains(overTabs),
      frameH: Math.round(frame.height),
      viewportH: window.innerHeight,
      lowest: Math.max.apply(Math, buttons.map(function (b) { return b.getBoundingClientRect().bottom; })),
      shortest: Math.min.apply(Math, buttons.map(function (b) { return b.getBoundingClientRect().height; })),
      labels: buttons.map(function (b) { return b.textContent; }),
      sideways: shade.scrollWidth > shade.clientWidth + 1
    };
  });
  const finderHintTop = await clearOfStatusBar(page, '#viewfinder .viewfinder-hint');

  it('opens the viewfinder over the whole app, tab bar included', function () {
    truthy(finder, 'Verify kill opened no viewfinder, so this measures nothing');
    truthy(finder.covers, 'the viewfinder leaves part of the app showing');
    truthy(finder.overTabs, 'a tap meant for the shutter could land on a tab');
    truthy(finder.labels.join(',') === 'Take photo,Cancel', JSON.stringify(finder.labels));
    truthy(!finder.sideways, 'the viewfinder is cut off sideways');
  });

  it('gives the camera most of the screen and keeps the shutter clear of the home indicator', function () {
    atLeast(finder ? finder.frameH : 0, Math.round((finder ? finder.viewportH : 0) * 0.5),
      'the picture being lined up is drawn ' + (finder && finder.frameH) + 'px tall');
    truthy(finder && finder.lowest <= finder.viewportH - 16,
      'a button ends at ' + (finder && finder.lowest) + ' of ' + (finder && finder.viewportH));
    atLeast(finder ? finder.shortest : 0, 44, 'shortest viewfinder button');
  });

  it('starts the viewfinder\'s instruction below lb-phone\'s status bar', function () {
    truthy(finderHintTop !== null, 'no viewfinder instruction, so this measures nothing');
    atLeast(finderHintTop, STATUS_BAR_REM, 'the instruction starts (rem)');
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
