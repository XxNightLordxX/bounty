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
  // A creator's own contract carries the most actions of any card, which
  // is the case that overflowed.
  const own = contracts.slice(0, 3).map(function (c) {
    const copy = JSON.parse(JSON.stringify(c));
    copy.role = 'creator';
    copy.huntersActive = 0;
    copy.hunters = [];
    return copy;
  });
  const taken = contracts.slice(3, 5).map(function (c) {
    const copy = JSON.parse(JSON.stringify(c));
    copy.role = 'hunter';
    return copy;
  });

  const answers = {
    list: { ok: true, data: { page: 1, pages: 1, contracts: contracts,
      settings: { minQueryLength: 3, allowBrowseAll: true, allowNearby: true } } },
    mine: { ok: true, data: { created: own, accepted: taken, onMe: [] } },
    ledger: { ok: true, data: { entries: [],
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
    browseTargets: { ok: true, data: { people: [
      { handle: 'tg1', name: 'Ada Quill', protected: false },
      { handle: 'tg2', name: 'Bo Renn', protected: true }
    ], total: 41, page: 1, pages: 5 } }
  };
  window.fetch = function (url) {
    const name = url.split('/crimson:')[1];
    return Promise.resolve({
      json: function () { return Promise.resolve(answers[name] || { ok: true }); }
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
