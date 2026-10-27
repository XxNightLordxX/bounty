/* Crimson Hitman System — the staff panel (/hitmanadmin).

   This resource's own NUI page (ui_page ui/admin.html), apart from the phone
   app. It holds no authority. Every request goes through nui() to
   client/admin.lua's adminRequest callback and on to server/panel.lua, which
   checks the ACE again on every one, rate-limits it, and answers
   { ok, err, message, data } (README, Integration Guide, has every op and
   shape). The page draws what it is told and nothing more: who is behind an
   anonymous party arrives only for staff with crimson.identity, already
   redacted for everybody else, and the page never asks for whois without it.

   Markup is built by h(), which passes every string it is given, text and
   attribute alike, through esc(). Player-written text (reasons, names,
   aliases, log details) is in almost every row here, so nothing reaches
   innerHTML any other way: setHtml() is the one assignment, and it takes
   only what h() made.

   Clicks, typing and keys are handled once, on the document, by the data-act
   (and data-bind, data-live, data-enter) the markup carries, so a section
   redrawn from a fresh answer needs nothing wired again. */

(function () {
  'use strict';

  /* ---------- the resource, and the one way to ask ---------------------

     GetParentResourceName first, which FiveM defines on its own NUI pages
     (this is one); the page's address after it (https://cfx-nui-<resource>/),
     and the shipped name for a page opened anywhere else (a layout test). */
  var RESOURCE = (typeof GetParentResourceName === 'function' && GetParentResourceName())
    || (/^cfx-nui-(.+)$/.exec(String((window.location && window.location.hostname) || '')) || [])[1]
    || 'crimson-hitman';

  /** Every interpolated string goes through this. */
  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /** One fetch helper: the callback's answer, or null on any error. */
  function nui(event, data) {
    try {
      return fetch('https://' + RESOURCE + '/' + event, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data || {})
      }).then(function (r) { return r.json(); })
        .then(function (value) { return value && typeof value === 'object' ? value : null; })
        .catch(function () { return null; });
    } catch (err) {
      return Promise.resolve(null);
    }
  }

  /* ---------- markup ----------------------------------------------------

     h('tag.class.other', { attr: value }, child, ...) -> Markup. A child is
     a string or number (escaped), another Markup, a list of either, or
     nothing (null, undefined, false). An attribute that is false or null is
     left out; true is written bare. */

  function Markup(html) { this.html = html; }

  var VOID_TAGS = { input: true, br: true, hr: true, img: true };
  var ATTR_NAME = /^[a-z][a-z0-9-]*$/;

  function childHtml(child) {
    if (child === null || child === undefined || child === false) return '';
    if (child instanceof Markup) return child.html;
    if (Array.isArray(child)) return child.map(childHtml).join('');
    return esc(child);
  }

  function h(spec) {
    var parts = String(spec).split('.');
    var tag = parts[0] || 'div';
    var classes = parts.slice(1);
    var rest = Array.prototype.slice.call(arguments, 1);
    var attrs = null;
    if (rest.length && rest[0] && typeof rest[0] === 'object'
        && !(rest[0] instanceof Markup) && !Array.isArray(rest[0])) {
      attrs = rest.shift();
    }
    var out = '<' + tag;
    if (attrs) {
      Object.keys(attrs).forEach(function (name) {
        var v = attrs[name];
        if (name === 'class') { if (v) classes.push(String(v)); return; }
        if (!ATTR_NAME.test(name) || v === null || v === undefined || v === false) return;
        out += ' ' + name + (v === true ? '' : '="' + esc(v) + '"');
      });
    }
    if (classes.length) out += ' class="' + esc(classes.join(' ')) + '"';
    out += '>';
    if (VOID_TAGS[tag]) return new Markup(out);
    return new Markup(out + rest.map(childHtml).join('') + '</' + tag + '>');
  }

  /** Several pieces of markup as one. */
  function frag() {
    return new Markup(Array.prototype.map.call(arguments, childHtml).join(''));
  }

  /** The one innerHTML assignment, and it takes only what h() made. */
  function setHtml(node, markup) {
    if (!node) return;
    node.innerHTML = markup instanceof Markup ? markup.html : '';
  }

  function icon(name) {
    return h('i', { class: 'fa-solid fa-' + name, 'aria-hidden': 'true' });
  }

  function byId(id) { return document.getElementById(id); }

  /* ---------- reading what the server sends -----------------------------

     A Lua table crosses as JSON, and an empty one is indistinguishable from
     an empty map: a list the server meant to send empty arrives as {}. And a
     list keyed by anything but 1..n crosses as an object. Every list is read
     through this. */
  function asList(value) {
    if (Array.isArray(value)) return value;
    if (value && typeof value === 'object') {
      return Object.keys(value).sort(function (a, b) { return Number(a) - Number(b); })
        .map(function (k) { return value[k]; });
    }
    return [];
  }

  function trim(value) { return String(value == null ? '' : value).replace(/^\s+|\s+$/g, ''); }

  /** A number with thousands separators and at most two decimals. */
  function num(n) {
    var value = Number(n);
    if (!isFinite(value)) return '0';
    var rounded = Math.round(value * 100) / 100;
    var abs = Math.abs(rounded);
    var whole = Math.floor(abs);
    var cents = Math.round((abs - whole) * 100);
    var text = String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    if (cents > 0) text += '.' + (cents < 10 ? '0' + cents : String(cents)).replace(/0$/, '');
    return (rounded < 0 ? '-' : '') + text;
  }

  function money(n) { return '$' + num(Math.round(Number(n) || 0)); }

  function bytes(n) {
    var value = Number(n) || 0;
    if (value < 1024) return value + ' B';
    if (value < 1048576) return (value / 1024).toFixed(1) + ' KB';
    return (value / 1048576).toFixed(1) + ' MB';
  }

  function pad(n) { return (n < 10 ? '0' : '') + n; }

  /** A server time (os.time seconds) as a local date and time. */
  function when(ts) {
    var t = Number(ts);
    if (!t) return '—';
    var d = new Date(t * 1000);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
      + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  function nowSeconds() { return Math.floor(Date.now() / 1000); }

  /** How long ago, or how long until, a server time. */
  function ago(ts) {
    var t = Number(ts);
    if (!t) return '';
    var delta = nowSeconds() - t;
    var future = delta < 0;
    var s = Math.abs(delta);
    var text;
    if (s < 45) text = future ? 'in a moment' : 'just now';
    else if (s < 3600) text = Math.round(s / 60) + ' min';
    else if (s < 86400) text = Math.round(s / 3600) + ' h';
    else text = Math.round(s / 86400) + ' d';
    if (s < 45) return text;
    return future ? 'in ' + text : text + ' ago';
  }

  function ms(n) {
    var value = Number(n) || 0;
    return (value < 10 ? value.toFixed(2) : value.toFixed(1)) + ' ms';
  }

  function wholeNumber(value) {
    var text = trim(value).replace(/,/g, '');
    if (!/^\d+$/.test(text)) return null;
    var n = Number(text);
    return n >= 1 && n <= 1000000000 ? n : null;
  }

  var STATE_LABEL = {
    active: 'Active', accepted: 'Accepted', completing: 'Completing', completed: 'Completed',
    bailed_out: 'Bought out', expired: 'Expired', cancelled: 'Cancelled', voided: 'Voided'
  };
  var STATE_ORDER = ['active', 'accepted', 'completing', 'completed', 'bailed_out', 'expired',
                     'cancelled', 'voided'];
  var LIVE_STATES = { active: true, accepted: true, completing: true };
  var RULE_LABEL = { alive: 'Alive only', either: 'Kill or alive' };
  var SOURCE_LABEL = { cash: 'cash', bank: 'bank', dirty: 'dirty money', item: 'item', weapon: 'weapon' };
  var MONEY = { cash: true, bank: true, dirty: true };

  function stateChip(state) {
    var cls = LIVE_STATES[state] ? 'is-live' : (state === 'voided' ? 'is-void' : 'is-closed');
    return h('span.chip', { class: 'state ' + cls }, STATE_LABEL[state] || state || '—');
  }

  /** What an escrow line or a stuck line holds, in words. */
  function holds(line) {
    if (!line) return '—';
    if (MONEY[line.source]) return money(line.amount) + ' ' + SOURCE_LABEL[line.source];
    if (line.source === 'weapon') return String(line.item || 'a weapon') + ' (weapon)';
    var count = Number(line.quantity) || 0;
    return (count ? num(count) + ' × ' : '') + String(line.item || 'an item');
  }

  /** A log row's or a proposal's detail, short, as one line. */
  function shortValue(value) {
    var text;
    if (value && typeof value === 'object') {
      try { text = JSON.stringify(value); } catch (err) { text = String(value); }
    } else {
      text = String(value);
    }
    return text.length > 140 ? text.slice(0, 139) + '…' : text;
  }

  /** One detail field: a time as a date (the log keeps os.time seconds). */
  function fieldText(key, value) {
    if ((key === 'at' || key === 'ts' || /_at$/.test(key)) && typeof value === 'number' && value > 1e9) {
      return when(value);
    }
    return shortValue(value);
  }

  function detailText(detail) {
    if (detail === null || detail === undefined) return '';
    if (typeof detail !== 'object') return String(detail);
    return Object.keys(detail).sort().map(function (k) {
      return k + ': ' + fieldText(k, detail[k]);
    }).join(' · ');
  }

  function prettyJson(value) {
    try { return JSON.stringify(value, null, 2); } catch (err) { return String(value); }
  }

  /* ---------- state ---------------------------------------------------- */

  var SECTIONS = ['overview', 'contracts', 'stuck', 'reviews', 'logs', 'players', 'settings', 'tools'];

  /** Ops that only read. A refusal of one as not_allowed means the staff
      member may no longer read at all (an ACE taken away while the panel was
      open), and the panel closes on it, as the README says it does. */
  var READ_OPS = { access: true, overview: true, contracts: true, contract: true, reviews: true,
                   logs: true, player: true, settings: true, diag: true, whois: true, stuck: true };

  var DEBOUNCE_MS = 250;
  var CONFIRM_MS = 3000;
  var TOAST_MS = 6000, TOAST_ERROR_MS = 9000, TOASTS_MAX = 4;

  var S = {
    open: false,
    gen: 0,                 // bumped on every open and close: a reply from before is nobody's
    access: {},
    recovery: 'ready',
    section: 'overview',
    seq: {},                // [channel] = the newest request on it
    forms: {},              // what has been typed, by data-bind, so a redraw keeps it
    busy: {},               // writes in flight, by what they act on
    armed: null,            // { node, timer, value, bind }: the destructive button waiting for its second click
    menu: null,             // the dropdown that is open
    overview: null, overviewAt: 0, overviewError: null, overviewTimer: null,
    pollGen: 0,             // the open whose overview refresh is running
    contracts: { page: 1, state: '', rule: '', range: '', data: null, timer: null },
    drawer: { id: null, data: null, answer: null, whois: null },
    stuck: { data: null, error: null, answers: {} },
    reviews: { all: false, items: null, action: {}, answers: {} },
    logs: { kind: '', range: '', cursor: null, back: [], data: null, open: {}, timer: null },
    players: { data: null, whois: {} },
    settings: { data: null, tab: 'features', answers: {} },
    tools: { refresh: null, diag: null, flush: null }
  };

  function canWrite() { return S.access.canWrite === true; }
  function canIdentify() { return S.access.canIdentify === true; }
  /** Writes wait for boot recovery, as the commands do; flushing the log does not. */
  function writesOpen() { return canWrite() && S.recovery === 'ready'; }

  function whyNoWrite() {
    if (!canWrite()) {
      return 'Read only: changing anything needs the staff ACE itself (Config.Admin.Ace); '
        + 'the extra ACEs only read.';
    }
    if (S.recovery === 'recovering') return 'Still recovering from the restart: try again in a moment.';
    if (S.recovery === 'recovery_failed') {
      return 'Recovery failed at the last start: restart the resource once the cause in the console is fixed.';
    }
    return '';
  }

  /* ---------- toasts --------------------------------------------------- */

  function toast(text, kind) {
    var box = byId('toasts');
    if (!box || !text) return;
    kind = kind || 'info';
    var node = document.createElement('div');
    node.className = 'toast is-' + kind;
    node.setAttribute('role', kind === 'error' ? 'alert' : 'status');
    node.setAttribute('data-act', 'toast-close');
    node.setAttribute('title', 'Click to dismiss');
    setHtml(node, frag(
      icon(kind === 'ok' ? 'circle-check' : kind === 'error' ? 'circle-exclamation' : 'circle-info'),
      h('span.toast-text', String(text))));
    box.appendChild(node);
    while (box.children.length > TOASTS_MAX) box.removeChild(box.children[0]);
    setTimeout(function () { node.remove(); }, kind === 'error' ? TOAST_ERROR_MS : TOAST_MS);
  }

  /* ---------- requests ------------------------------------------------- */

  /** What a refusal says, when the server gave no sentence of its own. */
  var WORDS = {
    no_answer: 'The game did not answer that. Try again.',
    not_allowed: 'Not authorised.',
    identity_required: 'That needs the identity ACE (Config.Admin.IdentityAce).',
    rate_limited: 'Slow down: too many requests. Try again in a moment.',
    timeout: 'The server did not answer in time. Try again.',
    closed: 'The panel was closed.',
    invalid_input: 'The server could not read that request.',
    unknown_op: 'The server does not know that request: is the resource up to date?',
    admin_off: 'The staff tools are switched off (Config.Admin.Enabled).',
    server_error: 'That raised an error on the server. Run the diagnosis, under Tools, to read it.',
    recovering: 'Still recovering from the restart: try again in a moment.',
    recovery_failed: 'Recovery failed at the last start: restart the resource once the cause in the console is fixed.',
    not_found: 'Not found.',
    read_only: 'That setting cannot be changed from the panel.',
    invalid_value: 'That value is refused.',
    store_failed: 'The store would not take it. Nothing changed.',
    store_unknown: 'The store may or may not have kept it; the diagnosis lists it.',
    not_overridden: 'That setting is what config.lua says already.',
    busy: 'Another change is being saved right now. Try again in a moment.'
  };

  function words(reply) {
    if (!reply) return WORDS.no_answer;
    if (reply.message) return String(reply.message);
    if (reply.ok) return 'Done.';
    return WORDS[reply.err] || ('Refused (' + (reply.err || 'no reason given') + ').');
  }

  /** Ask the server. Resolves the reply ({ ok, err, message, data }, or one
      saying nothing answered), or null when nobody is waiting for it any more:
      the panel closed or opened again since, or a newer request went out on
      the same channel (a search typed on). */
  function ask(op, data, channel) {
    var gen = S.gen;
    var mine = 0;
    if (channel) { mine = (S.seq[channel] || 0) + 1; S.seq[channel] = mine; }
    return nui('adminRequest', { op: op, data: data || {} }).then(function (reply) {
      if (gen !== S.gen || !S.open) return null;
      if (channel && S.seq[channel] !== mine) return null;
      if (!reply) return { ok: false, err: 'no_answer', message: WORDS.no_answer };
      if (reply.ok !== true && reply.err === 'closed') return null;
      if (reply.ok !== true && (reply.err === 'admin_off' || (reply.err === 'not_allowed' && READ_OPS[op]))) {
        // This staff member may not read at all any more: the ACE went, or
        // the staff tools were switched off. Nothing here is theirs to see.
        close(words(reply));
        return null;
      }
      return reply;
    });
  }

  /** A write, once at a time per thing it acts on. */
  function write(op, data, key, node) {
    if (S.busy[key]) return Promise.resolve(null);
    S.busy[key] = true;
    if (node) { node.disabled = true; node.classList.toggle('is-busy', true); }
    return ask(op, data).then(function (reply) {
      delete S.busy[key];
      if (node) { node.disabled = false; node.classList.toggle('is-busy', false); }
      // What it moved shows in the counts at once, not at the next refresh.
      if (reply && reply.ok) loadOverview(false);
      // Refused as not allowed: the ACE that writes went while the panel was
      // open. The badge and every write button follow, rather than each
      // click being refused the same way.
      if (reply && reply.ok !== true && reply.err === 'not_allowed' && canWrite()) {
        var was = S.access, now = {};
        Object.keys(was).forEach(function (k) { now[k] = was[k]; });
        now.canWrite = false;
        S.access = now;
        drawChrome();
        redraw();
      }
      return reply;
    }, function () {
      delete S.busy[key];
      return null;
    });
  }

  /* ---------- confirming ------------------------------------------------

     A destructive button (void, settle, resolve, reset, the timer refresh)
     takes two clicks: the first arms it and says what the second does, and
     it disarms itself after three seconds. */

  function disarm() {
    if (!S.armed) return;
    clearTimeout(S.armed.timer);
    S.armed.node.classList.toggle('is-armed', false);
    S.armed = null;
  }

  /** True on the second click; on the first, arms the button and says no. */
  function confirmed(node) {
    if (S.armed && S.armed.node === node) { disarm(); return true; }
    disarm();
    node.classList.toggle('is-armed', true);
    S.armed = { node: node, timer: setTimeout(disarm, CONFIRM_MS) };
    return false;
  }

  /* ---------- controls --------------------------------------------------- */

  function btn(cls, act, attrs, label, iconName) {
    var a = attrs || {};
    a.type = 'button';
    a['data-act'] = act;
    return h('button.btn' + (cls || ''), a, iconName ? icon(iconName) : null, h('span.lbl', label));
  }

  /** A button that changes something: disabled, saying why, for staff who
      may only read, and while recovery holds writes back. A second label is
      the confirm it shows when armed. */
  function writeBtn(cls, act, attrs, label, confirmLabel, iconName, always) {
    var a = attrs || {};
    a.type = 'button';
    a['data-act'] = act;
    var allowed = always ? canWrite() : writesOpen();
    if (!allowed) { a.disabled = true; a.title = whyNoWrite(); }
    if (confirmLabel) a['data-confirm'] = 'yes';
    return h('button.btn' + (cls || ''), a, iconName ? icon(iconName) : null, h('span.lbl', label),
      confirmLabel ? h('span.cfm', confirmLabel) : null);
  }

  function field(bind, attrs) {
    var a = attrs || {};
    a['data-bind'] = bind;
    a.value = S.forms[bind] == null ? (a.value == null ? '' : a.value) : S.forms[bind];
    a.autocomplete = 'off';
    a.spellcheck = 'false';
    if (!a.type) a.type = 'text';
    return h('input.input', a);
  }

  /* Dropdowns, drawn rather than native: a <select> opens a popup CEF draws
     wrongly, or not at all. Each one is defined below by name ('ct-state'),
     or by name and the thing it belongs to ('rv-who:rv123'). */
  var DD = {};

  function ddParts(name) {
    var at = name.indexOf(':');
    return at === -1 ? { def: DD[name], arg: null } : { def: DD[name.slice(0, at)], arg: name.slice(at + 1) };
  }

  function ddInner(name) {
    var p = ddParts(name);
    if (!p.def) return frag();
    var options = p.def.options(p.arg);
    var current = String(p.def.value(p.arg) == null ? '' : p.def.value(p.arg));
    var chosen = options.filter(function (o) { return String(o.value) === current; })[0] || options[0]
      || { label: '' };
    var open = S.menu === name;
    return frag(
      h('button.dd-btn', { type: 'button', 'data-act': 'dd-open', 'data-dd': name,
        'aria-haspopup': 'listbox', 'aria-expanded': open ? 'true' : 'false',
        disabled: p.def.disabled ? p.def.disabled(p.arg) : false },
        p.def.prefix ? h('span.dd-prefix', p.def.prefix) : null,
        h('span.dd-label', chosen.label), icon('chevron-down')),
      h('div.dd-menu', { role: 'listbox', hidden: !open },
        options.map(function (o) {
          var on = String(o.value) === current;
          return h('button.dd-opt' + (on ? '.is-on' : ''), { type: 'button', role: 'option',
            'aria-selected': on ? 'true' : 'false', 'data-act': 'dd-pick', 'data-dd': name,
            'data-value': String(o.value) }, o.label);
        })));
  }

  function dropdown(name, cls) {
    return h('div.dd' + (cls || ''), { id: 'dd-' + name }, ddInner(name));
  }

  function redrawDropdown(name) { setHtml(byId('dd-' + name), ddInner(name)); }

  function closeMenu() {
    if (!S.menu) return;
    var name = S.menu;
    S.menu = null;
    redrawDropdown(name);
  }

  /** A row of buttons of which one is chosen (a tab strip, two choices). */
  function segmented(act, options, current, extra) {
    return h('div.seg', { role: 'group' }, options.map(function (o) {
      var on = String(o.value) === String(current);
      var a = { type: 'button', 'data-act': act, 'data-value': String(o.value),
                'aria-pressed': on ? 'true' : 'false' };
      Object.keys(extra || {}).forEach(function (k) { a[k] = extra[k]; });
      if (o.disabled) { a.disabled = true; a.title = o.title || null; }
      return h('button.seg-btn' + (on ? '.is-on' : ''), a, o.label);
    }));
  }

  function empty(text) { return h('p.empty', text); }

  function loading(text) { return h('p.loading', icon('spinner'), ' ', text || 'Loading…'); }

  function answerBox(answer) {
    if (!answer) return null;
    return h('div.answer' + (answer.ok ? '.is-ok' : '.is-error'), { role: 'status' },
      icon(answer.ok ? 'circle-check' : 'circle-exclamation'), h('span.answer-text', answer.text));
  }

  function card(title, body, extraCls, aside) {
    return h('section.card' + (extraCls || ''), h('header.card-head', h('h3', title), aside || null), body);
  }

  /** A date range, as presets and two typed dates. */
  var RANGES = [
    { value: '', label: 'Any time' },
    { value: '1d', label: 'Last 24 hours' },
    { value: '7d', label: 'Last 7 days' },
    { value: '30d', label: 'Last 30 days' },
    { value: 'custom', label: 'Between dates…' }
  ];

  /** A typed date ('2026-10-26', or '2026-10-26 14:30') as a server time;
      null when nothing was typed, false when it cannot be read. */
  function parseWhen(text, endOfDay) {
    text = trim(text);
    if (!text) return null;
    var m = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?$/.exec(text);
    if (!m) return false;
    var y = Number(m[1]), mo = Number(m[2]) - 1, d = Number(m[3]);
    var hh = m[4] ? Number(m[4]) : (endOfDay ? 23 : 0);
    var mm = m[5] ? Number(m[5]) : (endOfDay ? 59 : 0);
    var date = new Date(y, mo, d, hh, mm, (endOfDay && !m[4]) ? 59 : 0);
    if (isNaN(date.getTime()) || date.getMonth() !== mo || date.getDate() !== d || hh > 23 || mm > 59) {
      return false;
    }
    return Math.floor(date.getTime() / 1000);
  }

  /** { from, to } for a range, or false when a typed date is unreadable
      (that box is marked, and nothing is asked). */
  function rangeOf(prefix, range) {
    var now = nowSeconds();
    if (range === '1d') return { from: now - 86400 };
    if (range === '7d') return { from: now - 7 * 86400 };
    if (range === '30d') return { from: now - 30 * 86400 };
    if (range !== 'custom') return {};
    var from = parseWhen(S.forms[prefix + '.from'], false);
    var to = parseWhen(S.forms[prefix + '.to'], true);
    markBad(prefix + '-from', from === false);
    markBad(prefix + '-to', to === false);
    if (from === false || to === false) return false;
    var out = {};
    if (from) out.from = from;
    if (to) out.to = to;
    return out;
  }

  function markBad(id, bad) {
    var node = byId(id);
    if (node) node.classList.toggle('is-bad', !!bad);
  }

  function rangeInputs(prefix, range, live) {
    return h('span.range', { id: prefix + '-range', hidden: range !== 'custom' },
      field(prefix + '.from', { id: prefix + '-from', class: 'is-date', placeholder: 'From YYYY-MM-DD',
        'data-live': live, 'aria-label': 'From date' }),
      h('span.range-sep', 'to'),
      field(prefix + '.to', { id: prefix + '-to', class: 'is-date', placeholder: 'To YYYY-MM-DD',
        'data-live': live, 'aria-label': 'To date' }));
  }

  /* ---------- the frame: badges, banner, navigation -------------------- */

  function drawChrome() {
    var version = byId('version');
    if (version) version.textContent = S.access.version ? 'v' + S.access.version : '';
    setHtml(byId('badges'), frag(
      canWrite()
        ? h('span.badge.is-write', { title: 'You can change things here' }, icon('pen'), 'Can change')
        : h('span.badge.is-read', { title: whyNoWrite() }, icon('eye'), 'Read only'),
      canIdentify()
        ? h('span.badge.is-identity', { title: 'You see who is behind anonymous parties; every lookup is on the record' },
          icon('user-secret'), 'Sees identities')
        : h('span.badge', { title: 'Anonymous parties show as Anonymous, and citizen ids as roles' },
          icon('mask'), 'Identities hidden')));
    drawBanner();
    SECTIONS.forEach(function (name) {
      var node = byId('nav-' + name);
      if (!node) return;
      node.classList.toggle('is-on', name === S.section);
      node.setAttribute('aria-current', name === S.section ? 'page' : 'false');
    });
    drawCounts();
  }

  function drawBanner() {
    var banner = byId('banner');
    if (!banner) return;
    if (S.recovery === 'recovering') {
      banner.hidden = false;
      banner.className = 'banner is-warn';
      setHtml(banner, frag(icon('hourglass-half'), h('span',
        'Still recovering from the restart. Everything reads; void, settle, resolve, settings and the '
        + 'timer refresh wait until it finishes.')));
    } else if (S.recovery === 'recovery_failed') {
      banner.hidden = false;
      banner.className = 'banner is-error';
      setHtml(banner, frag(icon('triangle-exclamation'), h('span',
        'Recovery failed at the last start (the console says why, after BOOT RECOVERY FAILED). Nothing '
        + 'can be voided, settled, resolved or changed until the resource is restarted once the cause '
        + 'is fixed. Flushing the log still works.')));
    } else {
      banner.hidden = true;
      setHtml(banner, frag());
    }
  }

  function setCount(id, n, what) {
    var node = byId(id);
    if (!node) return;
    node.hidden = !(n > 0);
    node.textContent = n > 0 ? String(n) : '';
    node.setAttribute('title', n > 0 ? n + ' ' + what : '');
  }

  function drawCounts() {
    var o = S.overview || {};
    setCount('count-reviews', o.reviews ? Number(o.reviews.open) || 0 : 0, 'open in the review queue');
    // What staff settle, not every line listed: one queued since, or an
    // ending finishing itself, needs nobody. Beside Stuck escrow, where
    // they are settled.
    setCount('count-stuck', o.stuck ? Number(o.stuck.leftForStaff) || 0 : 0, 'escrow line(s) left for you to settle');
    setCount('count-settings', Number(o.overrides) || 0, 'setting(s) changed from the panel');
  }

  function setRecovery(state) {
    if (!state || state === S.recovery) return;
    S.recovery = state;
    drawBanner();
    // Every write button reads it as it is drawn.
    redraw();
  }

  /* ---------- sections ------------------------------------------------- */

  var SHELL = {}, LOAD = {};

  function show(section) {
    if (SECTIONS.indexOf(section) === -1) section = 'overview';
    S.section = section;
    closeDrawer();
    disarm();
    S.menu = null;
    drawChrome();
    var main = byId('main');
    setHtml(main, SHELL[section]());
    if (main) main.scrollTop = 0;
    LOAD[section]();
  }

  /** The current section drawn again from what is already here. */
  function redraw() {
    if (!S.open) return;
    var main = byId('main');
    if (!main) return;
    var top = main.scrollTop;
    setHtml(main, SHELL[S.section]());
    main.scrollTop = top;
    if (S.drawer.id) drawDrawer();
  }

  /* ---- overview ---- */

  function refreshMs() {
    var s = Number(S.access.refreshSeconds) || 10;
    return Math.max(2, s) * 1000;
  }

  function loadOverview(manual) {
    return ask('overview', {}, 'overview').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) {
        S.overviewError = words(reply);
        if (manual || !S.overview) toast(S.overviewError, 'error');
      } else {
        S.overview = reply.data || {};
        S.overviewAt = nowSeconds();
        S.overviewError = null;
        if (S.overview.recovery) setRecovery(S.overview.recovery);
      }
      drawCounts();
      if (S.section === 'overview') setHtml(byId('ov'), overviewBody());
    });
  }

  /** The overview again every Config.Admin.PanelRefreshSeconds while the
      panel is open: one timer, started on open and stopped on close. */
  function schedule(gen) {
    if (gen !== S.gen || !S.open) return;
    clearTimeout(S.overviewTimer);
    S.overviewTimer = setTimeout(function () {
      S.overviewTimer = null;
      if (gen !== S.gen || !S.open) return;
      // Stuck escrow too while it is on screen, so its list and the badge
      // agree after another staff member settles a line.
      if (S.section === 'stuck' && !S.drawer.id) loadStuck(true);
      loadOverview(false).then(function () { schedule(gen); });
    }, refreshMs());
  }

  function moneyRows(bucket) {
    var b = bucket || {};
    return h('dl.facts',
      h('dt', 'Cash'), h('dd.figure', money(b.cash)),
      h('dt', 'Bank'), h('dd.figure', money(b.bank)),
      h('dt', 'Dirty money'), h('dd.figure', money(b.dirty)),
      h('dt', 'Items'), h('dd', num(b.items)),
      h('dt', 'Weapons'), h('dd', num(b.weapons)),
      h('dt', 'Escrow lines'), h('dd', num(b.lines)));
  }

  var WHY_SHORT = {
    interrupted: 'stopped while being given', unknown: 'arrival unknown', raised: 'raised, nothing arrived',
    stalled: 'stopped part-way', unqueued: 'in no retry queue', stalled_claim: 'stalled claim',
    stopped: 'stopped by a raise', releasing: 'left mid-release', ending_unfinished: 'ending unfinished',
    orphan: 'contract never stored', never_given_release: 'left mid-release, never given',
    owed_to_nobody: 'owed to nobody', owed_to_unchecked: 'owed to an id not checked'
  };

  /** Why Stuck escrow lists nothing, from where recovery stands. After a
      recovery that failed, "while the server is recovering" told staff to
      wait for something that never finishes. */
  function notListed(recovery) {
    if (recovery === 'recovery_failed') {
      return 'Not listed: recovery failed at the last start; restart the resource once the cause in '
        + 'the console is fixed.';
    }
    return 'Not listed while the server is recovering from the restart.';
  }

  function tile(title, body, cls) {
    return h('div.tile' + (cls || ''), h('h3.tile-title', title), body);
  }

  function overviewBody() {
    var o = S.overview;
    if (!o) return S.overviewError ? empty(S.overviewError) : loading('Reading the overview…');
    var contracts = o.contracts || {};
    var byState = contracts.byState || {};
    var states = STATE_ORDER.slice();
    Object.keys(byState).forEach(function (s) { if (states.indexOf(s) === -1) states.push(s); });
    var hitmen = o.hitmen || {};
    var owed = o.owed || {};
    var photos = o.photos;
    var slowest = asList(o.slowest);
    var warnings = asList(o.warnings);
    var slowMs = Number(o.slowMs) || 0;

    /* The headline is what staff settle (every line with something to settle
       it by), not every line listed: one queued since for whom it is owed,
       or an ending finishing itself, needs nobody, and is said so apart. */
    var stuckBody;
    var forYou = o.stuck ? Number(o.stuck.leftForStaff) || 0 : 0;
    if (!o.stuck) {
      stuckBody = h('p.note', notListed(o.recovery));
    } else if (o.stuck.error) {
      stuckBody = frag(h('p.note.is-error', 'The list could not be read just now; the diagnosis keeps '
        + 'why. Stuck escrow reads it again.'),
        btn('.is-small', 'section', { 'data-section': 'stuck' }, 'Open Stuck escrow', 'arrow-right'));
    } else {
      var byWhy = o.stuck.byWhy || {};
      var listed = Number(o.stuck.total) || 0;
      var nothingToDo = Math.max(0, listed - forYou);
      stuckBody = frag(
        h('p.big' + (forYou > 0 ? '.is-warn' : ''), num(forYou)),
        h('p.sub', 'left for you to settle, of ' + num(listed) + ' listed'),
        h('div.chips', Object.keys(byWhy).sort().map(function (why) {
          return h('span.chip', (WHY_SHORT[why] || why) + ' ' + num(byWhy[why]));
        })),
        nothingToDo > 0
          ? h('p.note', num(nothingToDo) + ' need nothing from you: queued since for whom '
            + (nothingToDo === 1 ? 'it is' : 'they are') + ' owed, or an ending settling itself within a minute.')
          : null,
        listed > 0
          ? h('p.note', 'Stuck escrow lists every one and settles it; each contract\'s view lists its '
            + 'own, a contract that was never stored included.')
          : null,
        btn('.is-small', 'section', { 'data-section': 'stuck' }, 'Open Stuck escrow', 'arrow-right'));
    }

    var reviewsOpen = o.reviews ? Number(o.reviews.open) || 0 : 0;

    return frag(
      h('div.tiles',
        tile('Contracts', frag(
          h('p.big', num(contracts.total)),
          h('div.chips', states.filter(function (s) { return byState[s]; }).map(function (s) {
            return h('button.chip.is-link', { type: 'button', 'data-act': 'ov-state', 'data-value': s },
              (STATE_LABEL[s] || s) + ' ' + num(byState[s]));
          })))),
        tile('Operatives', frag(
          h('p.big', num(hitmen.operatives)),
          h('p.sub', 'on contracts now, holding ' + num(hitmen.contracts) + ' contract'
            + (Number(hitmen.contracts) === 1 ? '' : 's')))),
        tile('Held in escrow', moneyRows(o.held)),
        tile('Owed to players', frag(moneyRows(owed),
          h('p.sub', num(owed.players) + ' player' + (Number(owed.players) === 1 ? '' : 's') + ' · '
            + num(owed.queued) + ' line' + (Number(owed.queued) === 1 ? '' : 's') + ' in a retry queue'))),
        tile('Waiting for staff', stuckBody, forYou > 0 ? '.is-warn' : ''),
        tile('Needs review', frag(
          h('p.big' + (reviewsOpen > 0 ? '.is-warn' : ''), num(reviewsOpen)),
          h('p.sub', 'open item' + (reviewsOpen === 1 ? '' : 's') + ' in the review queue'),
          btn('.is-small', 'section', { 'data-section': 'reviews' }, 'Open the queue', 'arrow-right')),
          reviewsOpen > 0 ? '.is-warn' : ''),
        tile('Kill photos', photos ? h('dl.facts',
          h('dt', 'Waiting'), h('dd', num(photos.waiting && photos.waiting.count) + ' · '
            + bytes(photos.waiting && photos.waiting.bytes)),
          h('dt', 'Kept in the app'), h('dd', num(photos.kept && photos.kept.count) + ' · '
            + bytes(photos.kept && photos.kept.bytes)),
          h('dt', 'Served to Photos'), h('dd', num(photos.served && photos.served.count) + ' · '
            + bytes(photos.served && photos.served.bytes)))
          : h('p.note', 'The photo store did not answer.')),
        tile('Server', h('dl.facts',
          h('dt', 'Storage'), h('dd', String(o.storage || '—'), o.storage === 'memory'
            ? h('span.chip.is-warn', { title: 'Contracts, escrow, review items and settings are gone at '
              + 'the next start' }, 'nothing is kept across a restart') : null),
          h('dt', 'New contracts'), h('dd', RULE_LABEL[o.fulfilment] || String(o.fulfilment || '—')),
          h('dt', 'Kill photos'), h('dd', o.killPhotos === false ? 'Off'
            : 'On, kept on ' + String(o.photoStorage || '—')),
          h('dt', 'Recovery'), h('dd', o.recovery === 'ready' ? 'Finished'
            : o.recovery === 'recovering' ? 'Still running' : 'FAILED'),
          h('dt', 'Settings changed here'), h('dd', h('button.link', { type: 'button', 'data-act': 'section',
            'data-section': 'settings' }, num(o.overrides)),
            Number(o.notApplied) > 0 ? h('span.chip.is-error', num(o.notApplied) + ' not applied') : null),
          h('dt', 'Log rows queued'), h('dd', num(o.auditQueued))))),
      h('div.cols',
        card('Slowest maintenance jobs', slowest.length ? h('div.table-wrap', h('table.grid',
          h('thead', h('tr', h('th', 'Job'), h('th.num', 'Worst'), h('th.num', 'Average'),
            h('th.num', 'Last'), h('th.num', 'Runs'))),
          h('tbody', slowest.map(function (job) {
            var slow = slowMs > 0 && Number(job.max) > slowMs;
            return h('tr' + (slow ? '.is-warn' : ''), h('td.mono.wrap', String(job.name)),
              h('td.num', ms(job.max)), h('td.num', ms(job.avg)), h('td.num', ms(job.last)),
              h('td.num', num(job.runs)));
          })))) : empty('No job has run yet.'),
          '', slowMs > 0 ? h('span.sub', 'over ' + slowMs + ' ms is marked') : null),
        card('What the diagnosis says', warnings.length
          ? h('ul.warnings', warnings.map(function (line) { return h('li', String(line)); }))
          : empty('Nothing that wants doing.'), '',
          btn('.is-small', 'ov-diag', {}, 'Run it', 'stethoscope'))),
      h('p.foot', icon('rotate'),
        ' Updated ' + (S.overviewAt ? when(S.overviewAt).slice(11) : '—') + ' · refreshes every '
        + Math.round(refreshMs() / 1000) + ' s',
        S.overviewError ? h('span.is-error', ' · last refresh: ' + S.overviewError) : null,
        ' ', btn('.is-small.is-ghost', 'ov-refresh', {}, 'Refresh now')));
  }

  SHELL.overview = function () {
    return h('section.view', h('div.stack', { id: 'ov' }, overviewBody()));
  };
  LOAD.overview = function () { loadOverview(false); };

  /* ---- contracts ---- */

  DD['ct-state'] = {
    prefix: 'State',
    options: function () {
      return [{ value: '', label: 'Any' }].concat(STATE_ORDER.map(function (s) {
        return { value: s, label: STATE_LABEL[s] };
      }));
    },
    value: function () { return S.contracts.state; },
    pick: function (v) { S.contracts.state = v; S.contracts.page = 1; loadContracts(); }
  };
  DD['ct-rule'] = {
    prefix: 'Rule',
    options: function () {
      return [{ value: '', label: 'Any' }, { value: 'alive', label: RULE_LABEL.alive },
              { value: 'either', label: RULE_LABEL.either }];
    },
    value: function () { return S.contracts.rule; },
    pick: function (v) { S.contracts.rule = v; S.contracts.page = 1; loadContracts(); }
  };
  DD['ct-range'] = {
    prefix: 'Placed',
    options: function () { return RANGES; },
    value: function () { return S.contracts.range; },
    pick: function (v) {
      S.contracts.range = v;
      S.contracts.page = 1;
      var range = byId('ct-range');
      if (range) range.hidden = v !== 'custom';
      loadContracts();
    }
  };

  function contractQuery() {
    var c = S.contracts;
    var data = { page: c.page };
    var q = trim(S.forms['ct.q']).slice(0, 64);
    if (q) data.query = q;
    if (c.state) data.state = c.state;
    if (c.rule) data.rule = c.rule;
    var range = rangeOf('ct', c.range);
    if (range === false) return null;
    if (range.from) data.from = range.from;
    if (range.to) data.to = range.to;
    return data;
  }

  function loadContracts() {
    clearTimeout(S.contracts.timer);
    S.contracts.timer = null;
    var data = contractQuery();
    if (!data) return Promise.resolve();
    var results = byId('ct-results');
    if (results) results.classList.toggle('is-loading', true);
    return ask('contracts', data, 'contracts').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) {
        toast(words(reply), 'error');
      } else {
        S.contracts.data = reply.data || {};
        S.contracts.page = Number(S.contracts.data.page) || 1;
      }
      if (S.section === 'contracts') drawContracts();
    });
  }

  function drawContracts() {
    var results = byId('ct-results');
    if (results) {
      results.classList.toggle('is-loading', false);
      setHtml(results, contractRows());
    }
    setHtml(byId('ct-pager'), contractPager());
  }

  function contractRows() {
    var d = S.contracts.data;
    if (!d) return loading('Reading contracts…');
    var rows = asList(d.rows);
    if (!rows.length) return empty('No contract matches.');
    return h('div.table-wrap', h('table.grid.is-rows',
      h('thead', h('tr', h('th', 'Contract'), h('th', 'State'), h('th', 'Rule'), h('th', 'Target'),
        h('th', 'Client'), h('th.num', 'Payouts'), h('th', 'Placed'), h('th', 'Deadline or end'))),
      h('tbody', rows.map(function (row) {
        // Relative, to scan down a page of them; the date itself on hover.
        var endAt = row.resolved_at || row.deadline_at;
        var ended = row.resolved_at
          ? String(row.resolution || STATE_LABEL[row.state] || 'ended') + ' · ' + ago(row.resolved_at)
          : (row.deadline_at ? 'due ' + ago(row.deadline_at) : '—');
        return h('tr.row', { 'data-act': 'contract', 'data-id': String(row.id), tabindex: '0',
          title: 'Open contract ' + row.id },
          h('td.mono.nowrap', String(row.id)), h('td', stateChip(row.state)),
          h('td.nowrap', RULE_LABEL[row.rule] || String(row.rule || '—')),
          h('td.name', String(row.target || '—')),
          h('td.name', row.anonymous ? h('span.anon', icon('mask'), ' ', String(row.client || 'Anonymous'))
            : String(row.client || '—')),
          h('td.num', num(row.claimed) + ' / ' + num(row.slots)),
          h('td.nowrap', when(row.created_at)), h('td', { title: endAt ? when(endAt) : null }, ended));
      }))));
  }

  function contractPager() {
    var d = S.contracts.data;
    if (!d) return frag();
    var page = Number(d.page) || 1, pages = Number(d.pages) || 1;
    return frag(
      btn('.is-small', 'ct-page', { 'data-value': String(page - 1), disabled: page <= 1 }, 'Previous', 'chevron-left'),
      h('span.pager-text', 'Page ' + page + ' of ' + pages + ' · ' + num(d.total) + ' contract'
        + (Number(d.total) === 1 ? '' : 's')),
      btn('.is-small', 'ct-page', { 'data-value': String(page + 1), disabled: page >= pages }, 'Next', 'chevron-right'));
  }

  SHELL.contracts = function () {
    return h('section.view',
      h('div.toolbar',
        h('label.search', icon('magnifying-glass'),
          field('ct.q', { id: 'ct-q', placeholder: 'Contract id, citizen id or name',
            'data-live': 'ct-search', 'data-enter': 'ct-search-now', 'aria-label': 'Search contracts' })),
        dropdown('ct-state'), dropdown('ct-rule'), dropdown('ct-range'),
        rangeInputs('ct', S.contracts.range, 'ct-search'),
        btn('.is-ghost', 'ct-clear', {}, 'Clear', 'eraser')),
      h('p.hint', canIdentify()
        ? 'You see who is behind anonymous parties. Every search and every contract you open is on the record.'
        : 'Anonymous clients and operatives show as Anonymous, and a search by citizen id or name never '
          + 'finds a contract through a party who stayed anonymous.'),
      h('div.results', { id: 'ct-results' }, contractRows()),
      h('div.pager', { id: 'ct-pager' }, contractPager()));
  };
  LOAD.contracts = function () { loadContracts(); };

  /* ---- the contract drawer ---- */

  function openContract(id) {
    if (!id) return;
    S.drawer = { id: String(id), data: null, answer: null, whois: null };
    // A reason typed for another contract is not this one's.
    S.forms['dr.reason'] = '';
    drawDrawer();
    loadContract();
  }

  function loadContract() {
    var id = S.drawer.id;
    if (!id) return Promise.resolve();
    return ask('contract', { id: id }, 'contract').then(function (reply) {
      if (!reply || S.drawer.id !== id) return;
      if (!reply.ok) {
        S.drawer.data = null;
        S.drawer.answer = { ok: false, text: words(reply) };
      } else {
        S.drawer.data = reply.data || {};
      }
      drawDrawer();
    });
  }

  function closeDrawer() {
    disarm();
    var was = S.drawer.id;
    S.drawer = { id: null, data: null, answer: null, whois: null };
    var drawer = byId('drawer'), scrim = byId('scrim');
    if (drawer) { drawer.hidden = true; setHtml(drawer, frag()); }
    if (scrim) scrim.hidden = true;
    // What was settled in it shows in the list behind it.
    if (was && S.open && S.section === 'stuck') loadStuck();
  }

  function drawDrawer() {
    var drawer = byId('drawer'), scrim = byId('scrim');
    if (!drawer) return;
    drawer.hidden = !S.drawer.id;
    if (scrim) scrim.hidden = !S.drawer.id;
    if (!S.drawer.id) return;
    setHtml(drawer, drawerBody());
  }

  function personCell(person) {
    var p = person || {};
    return frag(h('span.name', String(p.name || '—')), p.cid ? h('span.cid', String(p.cid)) : null);
  }

  /** The words the stuck listing uses for why a line waits. */
  var WHY_LONG = {
    interrupted: 'the server stopped while it was being given',
    unknown: 'raised, and what arrived could not be read',
    stalled: 'giving it stopped part-way, and nothing will try it again',
    unqueued: 'owed and in no retry queue, so nothing will give it',
    stalled_claim: 'stalled claim: the claim that owed it raised before paying it, so nothing will give it',
    stopped: 'a raise stopped it while it was being given',
    releasing: 'left mid-release by a call that raised, and nothing is finishing it',
    never_given_release: 'left mid-release by a call that raised before it named anyone, so nothing of it was given',
    ending_unfinished: 'ending unfinished; it settles itself within a minute'
  };
  var NEVER_GIVEN = { unqueued: true, stalled_claim: true };

  /** Whether nothing of a line was given, so only Pay settles it: one the
      server says so of, or one left mid-release before it named anyone
      that is owed to somebody. */
  function neverGiven(entry) {
    return !!NEVER_GIVEN[entry.why] || (entry.why === 'never_given_release' && !!entry.owed);
  }
  var SETTLES = {
    queued: 'queued for them since: nothing to settle',
    return_owner: 'does not say whose it is: return it to a citizen id once you know who put it up',
    pay_or_return: 'pay (to them) or return (to whoever put it up)',
    'return': 'names nobody to pay: only a return settles it, to whoever put it up'
  };

  function stuckWhy(entry) {
    if (entry.unfinished) return WHY_LONG.ending_unfinished;
    if (entry.orphan) return 'escrow of a contract never stored, and it does not say whose it is';
    if (entry.why === 'owed_to_nobody') {
      return 'owed and queued to a citizen id no character has, so nothing will give it: return it '
        + 'to the citizen id it should go to';
    }
    if (entry.why === 'owed_to_unchecked') {
      return 'owed and queued to a citizen id the server could not check (qbx_core did not answer), '
        + 'so it stays queued for them and is not moved';
    }
    if (entry.raised !== undefined && entry.raised !== null) {
      var text = entry.why === 'raised' ? 'raised ' + num(entry.raised) + ' times with nothing arriving'
        : (WHY_LONG[entry.why] || 'why is no longer in the log');
      if (Number(entry.arrived) > 0) text += '; ' + num(entry.arrived) + ' of it arrived';
      if (entry.why === 'never_given_release' && !entry.owed) {
        text += '; owed to nobody, so Return puts it back to its contract, which keeps it while it '
          + 'is live and hands it back once it is closed';
      }
      return text;
    }
    return 'was mid-release at a shutdown: ' + (SETTLES[entry.settles] || SETTLES['return']);
  }

  var SETTLE_LABEL = {
    pay: ['Pay', 'Click again to pay'],
    pay_amount: ['Pay amount', 'Click again to pay it'],
    'return': ['Return', 'Click again to return'],
    return_owner: ['Return to', 'Click again to return'],
    delivered: ['Delivered', 'Click again: delivered']
  };

  /** The settle buttons of one stuck line: in the contract's view
      (`where` 'drawer') or in Stuck escrow ('stuck'), each answering
      where it was pressed. */
  function stuckActions(entry, where) {
    var actions = asList(entry.actions);
    if (!actions.length) return null;
    var line = String(entry.line);
    return h('div.settle', actions.map(function (how) {
      var label = SETTLE_LABEL[how];
      if (!label) return null;
      // All alike: which one is right is what staff check first, and none
      // of them is the one the drawer is for.
      var button = writeBtn('', 'settle', { 'data-line': line, 'data-how': how,
        'data-where': where || 'drawer', 'data-contract': entry.contract ? String(entry.contract) : null },
        label[0], label[1]);
      if (how === 'pay_amount') {
        return h('span.inline-form', field('dr.amount.' + line, { class: 'is-short', placeholder: 'Amount',
          inputmode: 'numeric', 'aria-label': 'Amount to pay for line ' + line,
          disabled: !writesOpen() }), button);
      }
      if (how === 'return_owner') {
        return h('span.inline-form', field('dr.owner.' + line, { class: 'is-mid', placeholder: 'Citizen id',
          'aria-label': 'Citizen id to return line ' + line + ' to', disabled: !writesOpen() }), button);
      }
      return button;
    }));
  }

  /** One stuck line: what it holds, why it waits, what settles it. In
      Stuck escrow it names its contract, which opens its view. */
  function stuckItem(entry, where) {
    var unknownArrival = entry.raised !== undefined && entry.raised !== null && entry.why !== 'raised'
      && entry.why !== 'never_given_release' && !NEVER_GIVEN[entry.why] && !entry.unfinished;
    var answer = where === 'stuck' ? S.stuck.answers[String(entry.line)] : null;
    return h('li.stuck-line',
      h('p.stuck-head', h('span.mono', String(entry.line)), ' ', h('b', holds(entry)),
        entry.portion ? h('span.chip', String(entry.portion)) : null,
        entry.intended ? h('span.sub', ' owed to ' + entry.intended) : null,
        entry.at ? h('span.sub', ' · ' + when(entry.at)) : null,
        where === 'stuck' && entry.contract
          ? h('span.sub', ' · contract ', h('button.link.mono', { type: 'button', 'data-act': 'contract',
            'data-id': String(entry.contract), title: 'Open contract ' + entry.contract }, String(entry.contract)))
          : null),
      h('p.stuck-why', stuckWhy(entry)),
      unknownArrival ? h('p.note.is-warn', 'Arrival unknown: check what they received, then pay the rest '
        + 'with Pay amount, or Delivered.') : null,
      neverGiven(entry) ? h('p.note', 'Never given: only Pay settles it, to them, in full.') : null,
      stuckActions(entry, where),
      answerBox(answer));
  }

  function slotSummary(escrow, contract) {
    var slots = {};
    escrow.forEach(function (line) {
      var key = line.slot === undefined || line.slot === null ? 'other' : String(line.slot);
      (slots[key] = slots[key] || []).push(line);
    });
    var keys = Object.keys(slots).sort(function (a, b) {
      if (a === 'other') return 1;
      if (b === 'other') return -1;
      return Number(a) - Number(b);
    });
    if (!keys.length) return empty('No escrow is recorded for this contract.');
    var claimed = Number(contract.claimed) || 0;
    return h('div.slots', keys.map(function (key) {
      var lines = slots[key];
      var totals = {};
      var goods = [];
      lines.forEach(function (line) {
        var portion = String(line.portion || 'other');
        if (MONEY[line.source]) {
          totals[portion] = (totals[portion] || 0) + (Number(line.amount) || 0);
        } else {
          goods.push(holds(line));
        }
      });
      var title = key === 'other' ? 'Stakes and owed lines' : 'Payout ' + key;
      var status = key === 'other' ? '' : (Number(key) <= claimed ? 'claimed' : 'to claim');
      return h('div.slot', h('p.slot-title', title, status ? h('span.chip', status) : null),
        h('p.slot-body', Object.keys(totals).sort().map(function (portion) {
          return h('span.slot-part', portion + ' ' + money(totals[portion]));
        }), goods.length ? h('span.slot-part', goods.join(', ')) : null));
    }));
  }

  function drawerBody() {
    var d = S.drawer.data;
    var id = S.drawer.id;
    var head = h('header.drawer-head',
      h('div.drawer-title', h('h2', 'Contract ', h('span.mono', id)),
        d && d.contract ? stateChip(d.contract.state) : null,
        d && d.contract ? h('span.chip', RULE_LABEL[d.contract.rule] || String(d.contract.rule || '')) : null),
      btn('.is-ghost', 'drawer-close', { 'aria-label': 'Close the contract' }, 'Close', 'xmark'));
    if (!d) {
      return frag(head, answerBox(S.drawer.answer), S.drawer.answer ? null : loading('Reading the contract…'));
    }
    var c = d.contract || {};
    var escrow = asList(d.escrow);
    var hitmen = asList(d.hitmen);
    var amendments = asList(d.amendments);
    var timeline = asList(d.timeline);
    var stuck = d.stuck === undefined || d.stuck === null ? null : asList(d.stuck);

    // An id with escrow and no contract record: its lines alone, settled
    // here as Stuck escrow settles them.
    var stub = c.neverStored === true;
    var actions = stub ? h('div.drawer-actions', h('p.note', 'Never stored: escrow under this id has no '
        + 'contract record, so nothing here names who put it up. Settle each line below; Return to sends '
        + 'it to the citizen id of whoever did.'))
      : h('div.drawer-actions',
      d.canVoid
        ? h('div.inline-form.is-wide',
          field('dr.reason', { class: 'is-grow', placeholder: 'Reason for the void (kept in the log)',
            maxlength: '120', disabled: !writesOpen(), 'aria-label': 'Reason for the void' }),
          writeBtn('.is-danger', 'void', {}, 'Void contract', 'Click again to void', 'ban'))
        : h('p.note', 'Closed: a closed contract is never voided.'),
      canIdentify() ? btn('.is-ghost', 'whois', { 'data-id': id }, 'Whois', 'user-secret') : null);

    var stuckPart = null;
    if (stuck === null) {
      stuckPart = card('Waiting for staff', h('p.note', notListed(S.recovery)));
    } else if (stuck.length) {
      stuckPart = card('Waiting for staff', h('ul.stuck', stuck.map(function (entry) {
        return stuckItem(entry, 'drawer');
      })), '.is-warn');
    }

    var whois = S.drawer.whois ? card('Who is behind it', whoisBody(S.drawer.whois), '.is-identity') : null;

    var terms = h('dl.facts.is-terms',
      h('dt', 'Mode'), h('dd', String(c.mode || '—')),
      h('dt', 'Completes by'), h('dd', RULE_LABEL[c.rule] || String(c.rule || '—')),
      h('dt', 'Reason'), h('dd.text', String(c.reason || '—')),
      h('dt', 'Client'), h('dd', personCell(c.client), c.anonymous ? h('span.chip.is-anon', 'anonymous') : null),
      h('dt', 'Target'), h('dd', personCell(c.target), c.target_protected ? h('span.chip.is-warn', 'law enforcement') : null),
      h('dt', 'Placed'), h('dd', when(c.created_at)),
      h('dt', 'Deadline'), h('dd', c.deadline_at ? when(c.deadline_at) + ' (' + ago(c.deadline_at) + ')' : '—'),
      h('dt', 'Expires'), h('dd', when(c.expires_at)),
      c.paused_since ? h('dt', 'Paused since') : null, c.paused_since ? h('dd', when(c.paused_since)) : null,
      h('dt', 'Ended'), h('dd', c.resolved_at ? String(c.resolution || '') + ' ' + when(c.resolved_at) : 'not yet'),
      h('dt', 'Payouts'), h('dd', num(c.claimed) + ' of ' + num(c.slots) + ' claimed'
        + (c.next_slot ? ' · next ' + c.next_slot : '')),
      h('dt', 'Bonus'), h('dd', num(c.bonus_percent) + '%'),
      h('dt', 'Stake'), h('dd', money(c.penalty_amount)),
      h('dt', 'Buyout price'), h('dd', money(c.bailout_amount) + (c.buyout_queued ? ' · a buyout is queued' : '')));

    return frag(head, answerBox(S.drawer.answer), h('div.drawer-body',
      actions,
      whois,
      stuckPart,
      stub ? null : card('Terms', terms),
      stub ? null : card('Payouts', slotSummary(escrow, c)),
      card('Escrow lines', escrow.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Line'), h('th', 'Payout'), h('th', 'Holds'),
          h('th', 'State'), h('th', 'Owed to'), h('th.num', 'Arrived'), h('th.num', 'Still owed'))),
        h('tbody', escrow.map(function (line) {
          return h('tr' + (line.parked ? '.is-warn' : ''),
            h('td.mono.wrap', String(line.id)),
            h('td', (line.slot == null ? '' : line.slot + ' · ') + String(line.portion || '—')),
            h('td', holds(line)),
            h('td', String(line.state || '—'), line.parked ? h('span.chip.is-warn', 'left for staff') : null,
              Number(line.raised) > 0 ? h('span.chip', 'raised ' + num(line.raised)) : null,
              line.settled_by_staff ? h('span.chip', 'staff: ' + line.settled_by_staff) : null),
            h('td.name', String(line.owed_to || line.releasing_to || line.settled_to || '—')),
            h('td.num', line.arrived == null ? '—' : num(line.arrived)),
            h('td.num', MONEY[line.source] ? money(line.owes) : num(line.owes)));
        })))) : empty('No escrow lines.')),
      stub ? null : card('Operatives', hitmen.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Alias'), h('th', 'Name'), canIdentify() ? h('th', 'Citizen id') : null,
          h('th', 'State'), h('th', 'Accepted'), h('th', 'Left'), h('th.num', 'Claims'), h('th.num', 'Stake'))),
        h('tbody', hitmen.map(function (m) {
          return h('tr', h('td', String(m.alias || '—')),
            h('td.name', m.anonymous && !m.cid ? h('span.anon', icon('mask'), ' ', String(m.name || 'Anonymous'))
              : String(m.name || '—')),
            canIdentify() ? h('td.mono', String(m.cid || '—')) : null,
            h('td', String(m.state || '—')), h('td', when(m.accepted_at)), h('td', when(m.left_at)),
            h('td.num', num(m.claims)), h('td.num', money(m.stake)));
        })))) : empty('Nobody has taken it.')),
      amendments.length ? card('Open proposals', h('ul.plain', amendments.map(function (a) {
        return h('li', h('b', String(a.kind || 'proposal')), ' by ' + String(a.proposer || '—'),
          a.expires_at ? ' · runs out ' + when(a.expires_at) : '',
          a.payload ? h('span.detail', ' ' + detailText(a.payload)) : null);
      }))) : null,
      card('Timeline', timeline.length ? h('ol.timeline', timeline.map(function (row) {
        return h('li', h('span.time', when(row.ts)), h('span.chip.kind-' + String(row.kind || 'system'), String(row.kind || '')),
          h('b', String(row.action || '')), row.actor ? h('span.sub', ' ' + row.actor) : null,
          h('span.detail', detailText(row.detail)));
      })) : empty('The log keeps nothing for it.'))));
  }

  function whoisBody(who) {
    var creator = who.creator || {}, target = who.target || {};
    return frag(h('dl.facts',
      h('dt', 'Client'), h('dd', String(creator.name || '—'), creator.cid ? h('span.cid', String(creator.cid)) : null,
        creator.anonymous ? h('span.chip.is-anon', 'paid to stay anonymous') : null),
      h('dt', 'Target'), h('dd', String(target.name || '—'), target.cid ? h('span.cid', String(target.cid)) : null)),
      asList(who.hitmen).length ? h('ul.plain', asList(who.hitmen).map(function (m) {
        return h('li', h('b', String(m.alias || '—')), ' ' + String(m.name || '—') + ' ',
          m.cid ? h('span.cid', String(m.cid)) : null, ' · ' + String(m.state || ''),
          m.anonymous ? h('span.chip.is-anon', 'anonymous') : null);
      })) : h('p.note', 'No operatives.'));
  }

  /* ---- stuck escrow ---- */

  /** Every escrow line waiting for staff, from the server (op stuck), as
      the stuck listing has them, each settled here with its buttons. */
  function loadStuck(quiet) {
    return ask('stuck', {}, 'stuck').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) {
        S.stuck.error = words(reply);
        if (!quiet) toast(S.stuck.error, 'error');
      } else {
        S.stuck.data = reply.data || {};
        S.stuck.error = null;
        if (S.stuck.data.recovery) setRecovery(S.stuck.data.recovery);
      }
      drawStuck();
    });
  }

  function drawStuck() {
    if (S.section === 'stuck') setHtml(byId('sk-list'), stuckBody());
  }

  function stuckBody() {
    var d = S.stuck.data;
    if (!d) return S.stuck.error ? empty(S.stuck.error) : loading('Reading what waits for staff…');
    var reviewsOpen = Number(d.reviews) || 0;
    var reviews = reviewsOpen > 0
      ? card('Needs review', frag(
          h('p.about', num(reviewsOpen) + ' money event' + (reviewsOpen === 1 ? '' : 's')
            + ' no rule could settle wait' + (reviewsOpen === 1 ? 's' : '') + ' in the review queue.'),
          btn('.is-small', 'section', { 'data-section': 'reviews' }, 'Open the queue', 'arrow-right')), '.is-warn')
      : null;
    if (d.lines === undefined || d.lines === null) {
      return frag(h('p.note', notListed(d.recovery)), reviews);
    }
    var lines = asList(d.lines);
    if (!lines.length) return frag(empty('No escrow line is waiting for staff.'), reviews);
    var forYou = lines.filter(function (entry) { return asList(entry.actions).length > 0; }).length;
    return frag(
      h('p.hint', num(forYou) + ' left for you to settle, of ' + num(lines.length) + ' listed. One queued '
        + 'since for whom it is owed, or an ending settling itself within a minute, needs nothing from you.'),
      card('Waiting for staff', h('ul.stuck', lines.map(function (entry) {
        return stuckItem(entry, 'stuck');
      })), forYou > 0 ? '.is-warn' : ''),
      reviews);
  }

  SHELL.stuck = function () {
    return h('section.view',
      h('div.toolbar', btn('.is-ghost', 'sk-refresh', {}, 'Refresh', 'rotate')),
      h('p.hint', 'Every escrow line left for staff: a payout whose give raised or stopped part-way, one '
        + 'the server stopped in the middle of, and escrow of a contract never stored. Check what the '
        + 'player has before you settle one: Delivered if it is there, Pay if it is not.'),
      h('div.stack', { id: 'sk-list' }, stuckBody()));
  };
  LOAD.stuck = function () { loadStuck(); };

  /* ---- needs review ---- */

  DD['rv-who'] = {
    prefix: 'To',
    options: function (id) {
      var item = reviewItem(id);
      return asList(item && item.parties).map(function (p) {
        return { value: String(p.role), label: String(p.role) + ' · ' + String(p.who || '—') };
      });
    },
    disabled: function (id) { return unwrittenItem(id); },
    value: function (id) {
      var chosen = S.forms['rv.' + id + '.who'];
      if (chosen) return chosen;
      var first = asList((reviewItem(id) || {}).parties)[0];
      return first ? String(first.role) : '';
    },
    pick: function (v, id) { S.forms['rv.' + id + '.who'] = v; }
  };
  DD['rv-account'] = {
    prefix: 'From',
    options: function () {
      return [{ value: 'cash', label: 'cash' }, { value: 'bank', label: 'bank' }, { value: 'dirty', label: 'dirty money' }];
    },
    disabled: function (id) { return unwrittenItem(id); },
    value: function (id) {
      return S.forms['rv.' + id + '.account'] || ((reviewItem(id) || {}).account) || 'bank';
    },
    pick: function (v, id) { S.forms['rv.' + id + '.account'] = v; }
  };

  function reviewItem(id) {
    return asList(S.reviews.items).filter(function (item) { return String(item.id) === String(id); })[0];
  }

  /** Listed, and not in the store yet: resolving it then answers that the
      store has not taken it, so its form is drawn and cannot be used. */
  var UNWRITTEN_WHY = 'It can be resolved once the store has taken it, within a tick.';
  function unwrittenItem(id) { return !!((reviewItem(id) || {}).unwritten); }

  /** The fresh list, with each item resolved here that it no longer lists
      kept where it was, marked resolved, so its answer stays in its card. */
  function keptResolved(before, fresh) {
    var listed = {}, used = {}, out = [];
    fresh.forEach(function (item) { listed[String(item.id)] = item; });
    before.forEach(function (item) {
      var id = String(item.id);
      var answer = S.reviews.answers[id];
      if (listed[id]) {
        out.push(listed[id]);
        used[id] = true;
      } else if (answer && answer.ok) {
        var copy = {};
        Object.keys(item).forEach(function (k) { copy[k] = item[k]; });
        copy.state = 'resolved';
        out.push(copy);
      }
    });
    fresh.forEach(function (item) { if (!used[String(item.id)]) out.push(item); });
    return out;
  }

  /** The queue, read again. After a resolve (`keep`), the item resolved
      stays until Refresh or another section: the open list no longer has
      it, and read alone it vanished with its answer the moment the resolve
      came back, leaving the exact words only in a toast. */
  function loadReviews(keep) {
    return ask('reviews', S.reviews.all ? { all: true } : {}, 'reviews').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { toast(words(reply), 'error'); return; }
      var fresh = asList((reply.data || {}).items);
      S.reviews.items = keep ? keptResolved(asList(S.reviews.items), fresh) : fresh;
      if (S.section === 'reviews') setHtml(byId('rv-list'), reviewList());
    });
  }

  function keyValues(map) {
    var keys = Object.keys(map || {}).sort();
    if (!keys.length) return null;
    return h('span.detail', keys.map(function (k) { return k + ': ' + fieldText(k, map[k]); }).join(' · '));
  }

  function reviewForm(item) {
    var id = String(item.id);
    var action = S.reviews.action[id] || 'refund';
    var hasGoods = asList(item.items).length > 0;
    var goods = S.forms['rv.' + id + '.goods'] === 'yes';
    var parties = asList(item.parties);
    /* Not in the store yet (W138): drawn so staff see what it will take,
       every part of it off, saying why. */
    var off = item.unwritten === true;
    var why = off ? UNWRITTEN_WHY : null;
    var fields;
    if (action === 'dismiss') {
      fields = field('rv.' + id + '.note', { class: 'is-grow', placeholder: 'Why (a note is required)',
        maxlength: '200', 'aria-label': 'Note', disabled: off });
    } else if (action === 'pay') {
      fields = parties.length ? dropdown('rv-who:' + id) : h('p.note', 'The item names nobody to pay.');
    } else {
      fields = frag(parties.length ? dropdown('rv-who:' + id) : null,
        hasGoods ? segmented('rv-goods', [{ value: 'no', label: 'An amount', disabled: off, title: why },
          { value: 'yes', label: 'Every item and weapon', disabled: off, title: why }],
          goods ? 'yes' : 'no', { 'data-id': id }) : null,
        goods ? null : field('rv.' + id + '.amount', { class: 'is-short', placeholder: 'Amount',
          inputmode: 'numeric', 'aria-label': 'Amount', disabled: off }),
        goods ? null : dropdown('rv-account:' + id));
    }
    var verbs = { refund: ['Refund it', 'Click again to refund'], pay: ['Pay it', 'Click again to pay'],
                  dismiss: ['Dismiss it', 'Click again to dismiss'] };
    return h('div.rv-form' + (off ? '.is-off' : ''),
      off ? h('p.note', UNWRITTEN_WHY) : null,
      segmented('rv-action', [{ value: 'refund', label: 'Refund', disabled: off, title: why },
        { value: 'pay', label: 'Pay', disabled: off, title: why },
        { value: 'dismiss', label: 'Dismiss', disabled: off, title: why }], action, { 'data-id': id }),
      h('div.inline-form.is-wide', fields,
        writeBtn(action === 'dismiss' ? '' : '.is-primary', 'resolve',
          { 'data-id': id, disabled: off, title: why },
          verbs[action][0], verbs[action][1], action === 'dismiss' ? 'xmark' : 'hand-holding-dollar')));
  }

  /** An item a resolution stopped part-way through (W137): its decision is
      on it and is the only thing that can finish it, so there is one button,
      and no action to choose that would be carried out as another. */
  function finishForm(item) {
    var id = String(item.id);
    return h('div.rv-form',
      h('div.inline-form.is-wide',
        writeBtn('.is-primary', 'resolve-finish', { 'data-id': id }, 'Finish as decided',
          'Click again to finish', 'check')));
  }

  /** What a decision on an item says, in a line: what, to whom. */
  function decisionText(resolution) {
    var r = resolution || {};
    return String(r.action || 'a decision') + (r.cid ? ' to ' + String(r.cid) : '');
  }

  function reviewList() {
    var items = S.reviews.items;
    if (!items) return loading('Reading the review queue…');
    if (!items.length) return empty(S.reviews.all ? 'The queue has never held anything.' : 'Nothing is waiting for review.');
    return frag(items.map(function (item) {
      var id = String(item.id);
      var open = item.state === 'open' || item.state === 'resolving';
      var resolving = item.state === 'resolving';
      var now = item.now || {};
      var lines = now.lines;
      var answer = S.reviews.answers[id];
      return h('article.card.rv' + (open ? '.is-open' : ''), { id: 'rv-' + id },
        h('header.card-head', h('h3', String(item.kind || 'item').replace(/_/g, ' ')),
          h('span.mono', id), h('span.chip' + (open ? '.is-warn' : ''), String(item.state || '')),
          h('span.sub', 'opened ' + when(item.created_at))),
        item.about ? h('p.about', String(item.about)) : null,
        item.unwritten ? h('p.note.is-warn', 'Not in the store yet: the server keeps it in memory until the store takes it.') : null,
        item.settles && item.state === 'open' && !item.unwritten
          ? h('p.note', 'The server settles this itself from its own record once the database answers. '
            + 'Refund or Pay settles it the same way now; what is typed is not used.') : null,
        resolving ? h('p.note.is-warn', 'Being resolved: ' + decisionText(item.resolution) + ' by '
          + String(item.resolved_by || '—') + '. It stopped part-way, and Finish as decided carries out '
          + 'that decision and nothing else.') : null,
        h('dl.facts',
          h('dt', 'Contract'), h('dd', item.contract ? h('button.link.mono', { type: 'button', 'data-act': 'contract',
            'data-id': String(item.contract) }, String(item.contract)) : '—'),
          h('dt', 'Amount'), h('dd', item.amount != null ? money(item.amount) + (item.account ? ' ' + item.account : '') : '—'),
          asList(item.items).length ? h('dt', 'Goods') : null,
          asList(item.items).length ? h('dd', asList(item.items).map(function (g) { return holds(g); }).join(', ')) : null,
          h('dt', 'Involved'), h('dd', asList(item.parties).length ? asList(item.parties).map(function (p) {
            return h('span.party', h('b', String(p.role)), ' ' + String(p.who || '—'));
          }) : '—'),
          h('dt', 'What was known'), h('dd', keyValues(item.known) || '—'),
          h('dt', 'The store now'), h('dd',
            now.contract ? 'contract ' + now.contract : 'contract unknown',
            now.buyout ? ' · buyout ' + now.buyout : '',
            lines ? ' · lines held ' + num(lines.held) + ', settled ' + num(lines.settled) + ', missing ' + num(lines.missing) : ''),
          item.resolution && !resolving ? h('dt', 'Resolved') : null,
          item.resolution && !resolving ? h('dd', detailText(item.resolution) + ' · by ' + String(item.resolved_by || '—')
            + ' · ' + when(item.resolved_at)) : null),
        open && canWrite() ? (resolving ? finishForm(item) : reviewForm(item)) : null,
        answerBox(answer));
    }));
  }

  SHELL.reviews = function () {
    return h('section.view',
      h('div.toolbar',
        segmented('rv-all', [{ value: 'open', label: 'Open' }, { value: 'all', label: 'All (latest 50)' }],
          S.reviews.all ? 'all' : 'open'),
        btn('.is-ghost', 'rv-refresh', {}, 'Refresh', 'rotate')),
      h('p.hint', 'Money no rule on the server could settle by itself. Resolving an item gives it once, however '
        + 'often it is asked; a role (payer, creator, ...) names a party without unmasking them.'),
      h('div.stack', { id: 'rv-list' }, reviewList()));
  };
  LOAD.reviews = function () { loadReviews(); };

  /* ---- logs ---- */

  DD['lg-kind'] = {
    prefix: 'Kind',
    options: function () {
      return [{ value: '', label: 'Any' }, { value: 'financial', label: 'financial' },
        { value: 'conduct', label: 'conduct' }, { value: 'rejected', label: 'rejected' },
        { value: 'system', label: 'system' }];
    },
    value: function () { return S.logs.kind; },
    pick: function (v) { S.logs.kind = v; firstLogPage(); }
  };
  DD['lg-range'] = {
    prefix: 'When',
    options: function () { return RANGES; },
    value: function () { return S.logs.range; },
    pick: function (v) {
      S.logs.range = v;
      var range = byId('lg-range');
      if (range) range.hidden = v !== 'custom';
      firstLogPage();
    }
  };

  /* A contract id and a citizen id as the server reads them (Util.toId,
     Util.toCitizenId). Sent half-typed, every pause in typing one answered
     "That is not a contract id." in an error toast, over the rows of the
     search before, which read as its result. A box that does not hold one
     yet is marked and nothing is asked, as with a date that cannot be read,
     and Enter says why. */
  var LOG_IDS = {
    contract: { re: /^[A-Za-z0-9_-]{8,64}$/, box: 'lg-contract',
                why: 'A contract id is 8 to 64 letters, digits, - or _, as ct00000001.' },
    actor: { re: /^[A-Za-z0-9]{3,32}$/, box: 'lg-actor', why: 'A citizen id is 3 to 32 letters and digits.' }
  };

  /** The log's filters as a request, or null when one cannot be sent yet
      (its box is marked). `strict` (Enter) says why. */
  function logQuery(strict) {
    var data = {};
    if (S.logs.kind) data.kind = S.logs.kind;
    var action = trim(S.forms['lg.action']).slice(0, 48);
    if (action) data.action = action;
    var typed = { contract: trim(S.forms['lg.contract']), actor: canIdentify() ? trim(S.forms['lg.actor']) : '' };
    var bad = null;
    Object.keys(LOG_IDS).forEach(function (name) {
      var wrong = typed[name] !== '' && !LOG_IDS[name].re.test(typed[name]);
      markBad(LOG_IDS[name].box, wrong);
      if (wrong && !bad) bad = LOG_IDS[name].why;
      else if (!wrong && typed[name]) data[name] = typed[name];
    });
    if (bad) {
      if (strict) toast(bad, 'error');
      return null;
    }
    var range = rangeOf('lg', S.logs.range);
    if (range === false) return null;
    if (range.from) data.from = range.from;
    if (range.to) data.to = range.to;
    if (S.logs.cursor !== null && S.logs.cursor !== undefined) data.cursor = S.logs.cursor;
    return data;
  }

  function firstLogPage(strict) {
    S.logs.cursor = null;
    S.logs.back = [];
    S.logs.open = {};
    return loadLogs(strict);
  }

  function loadLogs(strict) {
    clearTimeout(S.logs.timer);
    S.logs.timer = null;
    var data = logQuery(strict);
    if (!data) return Promise.resolve();
    var results = byId('lg-results');
    if (results) results.classList.toggle('is-loading', true);
    return ask('logs', data, 'logs').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) toast(words(reply), 'error');
      else S.logs.data = reply.data || {};
      if (S.section === 'logs') drawLogs();
    });
  }

  function drawLogs() {
    var results = byId('lg-results');
    if (results) {
      results.classList.toggle('is-loading', false);
      setHtml(results, logRows());
    }
    setHtml(byId('lg-pager'), logPager());
  }

  function logRows() {
    var d = S.logs.data;
    if (!d) return loading('Reading the log…');
    var rows = asList(d.rows);
    if (!rows.length) return empty('No row matches.');
    return h('div.table-wrap', h('table.grid.is-rows.is-log',
      h('thead', h('tr', h('th', 'When'), h('th', 'Kind'), h('th', 'Action'), h('th', 'Contract'),
        h('th', 'Who'), h('th', 'Detail'))),
      h('tbody', rows.map(function (row, i) {
        var open = !!S.logs.open[i];
        return frag(
          h('tr.row' + (open ? '.is-open' : ''), { 'data-act': 'lg-expand', 'data-index': String(i), tabindex: '0',
            title: open ? 'Hide the detail' : 'Show the whole detail' },
            h('td.nowrap', when(row.ts)), h('td', h('span.chip.kind-' + String(row.kind || 'system'), String(row.kind || ''))),
            h('td.mono.wrap', String(row.action || '')),
            h('td', row.contract ? h('button.link.mono', { type: 'button', 'data-act': 'contract',
              'data-id': String(row.contract) }, String(row.contract)) : '—'),
            h('td.name', String(row.actor || '—')),
            h('td.detail', h('span.clamp', detailText(row.detail)))),
          open ? h('tr.more', h('td', { colspan: '6' }, h('pre.json', prettyJson(row.detail || {})))) : null);
      }))));
  }

  function logPager() {
    var d = S.logs.data;
    if (!d) return frag();
    var page = S.logs.back.length + 1;
    return frag(
      btn('.is-small', 'lg-newer', { disabled: S.logs.back.length === 0 }, 'Newer', 'chevron-left'),
      h('span.pager-text', 'Page ' + page + ' · newest first'),
      btn('.is-small', 'lg-older', { disabled: d.next === undefined || d.next === null }, 'Older', 'chevron-right'));
  }

  SHELL.logs = function () {
    return h('section.view',
      h('div.toolbar',
        dropdown('lg-kind'),
        field('lg.action', { class: 'is-mid', placeholder: 'Action contains', 'data-live': 'lg-search',
          'data-enter': 'lg-search-now', 'aria-label': 'Action contains' }),
        field('lg.contract', { id: 'lg-contract', class: 'is-mid', placeholder: 'Contract id', 'data-live': 'lg-search',
          'data-enter': 'lg-search-now', 'aria-label': 'Contract id' }),
        field('lg.actor', { id: 'lg-actor', class: 'is-mid', placeholder: canIdentify() ? 'Citizen id' : 'Citizen id (needs identity)',
          'data-live': 'lg-search', 'data-enter': 'lg-search-now', disabled: !canIdentify(),
          title: canIdentify() ? null : 'Finding a player\'s rows needs the identity ACE.',
          'aria-label': 'Citizen id' }),
        dropdown('lg-range'),
        rangeInputs('lg', S.logs.range, 'lg-search'),
        btn('.is-ghost', 'lg-clear', {}, 'Clear', 'eraser')),
      h('p.hint', canIdentify()
        ? 'Every row as it was written. Reading the log as you can see it is on the record.'
        : 'Citizen ids show as the party\'s place on the contract (the client, the target, an operative) and '
          + 'anonymous parties as Anonymous.'),
      h('div.results', { id: 'lg-results' }, logRows()),
      h('div.pager', { id: 'lg-pager' }, logPager()));
  };
  LOAD.logs = function () { loadLogs(); };

  /* ---- players ---- */

  function loadPlayer() {
    var subject = trim(S.forms['pl.q']);
    if (!subject) { toast('Give a player id or a citizen id.', 'error'); return Promise.resolve(); }
    S.players.whois = {};
    return ask('player', { subject: subject.slice(0, 64) }, 'player').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { toast(words(reply), 'error'); S.players.data = { error: words(reply) }; }
      else S.players.data = reply.data || {};
      if (S.section === 'players') setHtml(byId('pl-result'), playerBody());
    });
  }

  function playerBody() {
    var d = S.players.data;
    if (!d) return empty('Look somebody up by their player id (in the city) or their citizen id (anybody).');
    if (d.error) return empty(d.error);
    var p = d.player || {};
    var stats = d.stats;
    var owed = asList(d.owed);
    var contracts = asList(d.contracts);
    var notices = d.notices || {};
    return frag(
      h('div.person',
        h('h2', String(p.name || 'No name on record')),
        p.cid ? h('span.cid', String(p.cid)) : h('span.chip', 'citizen id hidden'),
        p.online ? h('span.chip.is-live', 'in the city · player ' + String(p.server)) : h('span.chip', 'offline')),
      // Sent only to staff with the identity ACE: the counters hold what was
      // placed and taken anonymously too, and nothing says which.
      stats ? h('div.tiles.is-compact',
        tile('Completed', h('p.big', num(stats.completed))),
        tile('Failed', h('p.big', num(stats.failed))),
        tile('Placed', h('p.big', num(stats.placed))),
        tile('Survived', h('p.big', num(stats.survived))),
        tile('Success rate', h('p.big', stats.rate == null ? '—' : num(stats.rate) + '%')),
        tile('Standing', h('p.big.is-word', String(stats.standing || '—'))))
        : h('p.note', 'Their record is not shown: it counts contracts placed and taken anonymously too, '
          + 'which only the identity ACE may see.'),
      h('div.cols',
        card('Owed to them', owed.length ? h('div.table-wrap', h('table.grid',
          h('thead', h('tr', h('th', 'Line'), h('th', 'Contract'), h('th', 'Holds'), h('th', 'State'),
            h('th.num', 'Still owed'), h('th', 'Queued'))),
          h('tbody', owed.map(function (line) {
            return h('tr', h('td.mono', String(line.id)),
              h('td', h('button.link.mono', { type: 'button', 'data-act': 'contract', 'data-id': String(line.contract) },
                String(line.contract))),
              h('td', holds(line)), h('td', String(line.state || '—'),
                line.parked ? h('span.chip.is-warn', 'left for staff') : null),
              h('td.num', MONEY[line.source] ? money(line.owes) : num(line.owes)),
              h('td', line.queued ? 'yes' : 'no'));
          })))) : empty('Nothing is owed to them' + (canIdentify() ? '.' : ' that you may see.')),
          '', h('span.sub', num(d.pending) + (Number(d.pending) === 1 ? ' delivery' : ' deliveries') + ' pending')),
        card('Notices for their next login', Number(notices.count) > 0
          ? h('ul.plain', asList(notices.titles).map(function (t) { return h('li', String(t)); }))
          : empty('None waiting.'), '', h('span.sub', num(notices.count)))),
      card('Contracts', contracts.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Contract'), h('th', 'State'), h('th', 'Role'), h('th', 'Target'),
          h('th', 'Placed'), h('th', 'Ended'), canIdentify() ? h('th', '') : null)),
        h('tbody', contracts.map(function (row) {
          var id = String(row.id);
          var who = S.players.whois[id];
          return frag(h('tr',
            h('td', h('button.link.mono', { type: 'button', 'data-act': 'contract', 'data-id': id }, id)),
            h('td', stateChip(row.state)),
            h('td', String(row.role || '—'), row.anonymous ? h('span.chip.is-anon', 'anonymous') : null),
            h('td.name', String(row.target || '—')), h('td', when(row.created_at)),
            h('td', String(row.resolution || '—')),
            canIdentify() ? h('td', btn('.is-small.is-ghost', 'whois', { 'data-id': id, 'data-where': 'player' },
              'Whois', 'user-secret')) : null),
            who ? h('tr.more', h('td', { colspan: canIdentify() ? '7' : '6' }, whoisBody(who))) : null);
        })))) : empty(canIdentify() ? 'No contracts on record.' : 'No contracts you may see.'),
        '', h('span.sub', 'newest first')));
  }

  SHELL.players = function () {
    return h('section.view',
      h('div.toolbar',
        h('label.search', icon('magnifying-glass'),
          field('pl.q', { id: 'pl-q', placeholder: 'Player id or citizen id', 'data-enter': 'pl-lookup',
            'aria-label': 'Player id or citizen id' })),
        btn('.is-primary', 'pl-lookup', {}, 'Look up', 'arrow-right')),
      h('p.hint', canIdentify()
        ? 'You see every contract they were party to, anonymous ones included. Each lookup is on the record.'
        : 'Contracts they placed or took anonymously are left out, with what they are owed, the deliveries '
          + 'and the notices on them, and so is their record, which counts them.'),
      h('div.stack', { id: 'pl-result' }, playerBody()));
  };
  LOAD.players = function () {};

  /* ---- features, limits & settings ---- */

  function settingList(tab) {
    var d = S.settings.data || {};
    return asList(d[tab]);
  }

  function settingEntry(key) {
    var all = settingList('features').concat(settingList('limits'), settingList('readonly'));
    return all.filter(function (e) { return e.key === key; })[0];
  }

  function describe(entry, value) {
    if (entry.kind === 'switch' || typeof value === 'boolean') return value === true ? 'On' : 'Off';
    if (entry.kind === 'list') {
      var list = asList(value);
      return list.length ? list.join(', ') : '(none)';
    }
    if (value === null || value === undefined) return '(not set)';
    if (typeof value === 'number') return num(value);
    return String(value);
  }

  function loadSettings() {
    return ask('settings', {}, 'settings').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { toast(words(reply), 'error'); return; }
      S.settings.data = reply.data || {};
      if (S.section === 'settings') drawSettings();
    });
  }

  function drawSettings() {
    setHtml(byId('st-head'), settingsHead());
    setHtml(byId('st-list'), settingsList());
    filterSettings();
  }

  function settingControl(entry) {
    var key = entry.key;
    if (entry.readonly) return h('span.st-value', describe(entry, entry.value));
    var open = writesOpen();
    var busy = !!S.busy['set:' + key];
    if (entry.kind === 'switch') {
      var on = entry.value === true;
      var a = { type: 'button', 'data-act': 'st-switch', 'data-key': key, role: 'switch',
                'aria-checked': on ? 'true' : 'false', 'aria-label': entry.label };
      if (!open || busy) { a.disabled = true; a.title = whyNoWrite() || null; }
      return h('button.switch' + (on ? '.is-on' : ''), a, h('span.knob'), h('span.lbl', on ? 'On' : 'Off'));
    }
    if (entry.kind === 'choice') {
      return segmented('st-choice', asList(entry.choices).map(function (c) {
        return { value: c, label: String(c), disabled: !open, title: whyNoWrite() };
      }), entry.value, { 'data-key': key });
    }
    var bind = 'st.' + key;
    var shownValue = entry.kind === 'list' ? asList(entry.value).join(', ') : String(entry.value == null ? '' : entry.value);
    var range = entry.kind === 'number'
      ? (entry.min != null ? entry.min : '…') + ' to ' + (entry.max != null ? entry.max : '…') + (entry.integer ? ', whole' : '')
      : 'job names, separated by commas';
    return h('div.st-edit',
      field(bind, { value: shownValue, class: entry.kind === 'list' ? 'is-grow' : 'is-short',
        inputmode: entry.kind === 'number' ? 'decimal' : null, 'data-enter': 'st-save', 'data-key': key,
        disabled: !open, 'aria-label': entry.label }),
      writeBtn('.is-small', 'st-save', { 'data-key': key, id: 'st-save-' + key }, 'Save',
        entry.destroys || entry.stricter ? 'Click again to save' : null, 'check'),
      h('span.st-range', range));
  }

  /** Whether saving this value deletes something for good (the catalogue's
      `destroys`): a lower one, 0 being never and so the highest. */
  function destroysWith(entry, value) {
    if (!entry.destroys || typeof value !== 'number' || value === 0) return false;
    var now = Number(entry.value) || 0;
    return now === 0 || value < now;
  }

  /** What the second click of a value that takes two says it does, or
      null: one that deletes for good, or a rate limit made stricter (the
      catalogue's `stricter`, the way that refuses players sooner). */
  function secondClick(entry, value) {
    if (destroysWith(entry, value)) return String(entry.destroys).replace(/%s/g, num(value));
    if (entry.stricter && typeof value === 'number') {
      var now = Number(entry.value);
      if ((entry.stricter === 'up' && value > now) || (entry.stricter === 'down' && value < now)) {
        return String(entry.strict || 'Stricter: players are refused sooner.').replace(/%s/g, num(value));
      }
    }
    return null;
  }

  function settingInner(entry) {
    var key = entry.key;
    var answer = S.settings.answers[key];
    var overridden = entry.source === 'panel';
    return frag(
      h('div.st-main',
        h('p.st-title', h('b', String(entry.label || key)),
          overridden ? h('span.chip.is-panel', 'changed from the panel') : null,
          entry.live === false ? h('span.chip.is-warn', 'applies after restart') : null,
          entry.ignored ? h('span.chip.is-error', 'not applied') : null,
          entry.inactive ? h('span.chip.is-warn', 'does not apply now') : null),
        h('code.st-key', 'Config.' + key),
        entry.about ? h('p.st-about', String(entry.about)) : null,
        // A key whose switch is off (the catalogue's `needs`): said beside
        // it, so a staff member is not left changing something that does
        // nothing.
        entry.inactive ? h('p.st-about.is-warn', String(entry.inactive)) : null,
        entry.readonly ? h('p.st-about.is-warn', String(entry.readonly)) : null,
        entry.destroys && !entry.readonly
          ? h('p.st-about.is-warn', 'Lowering it deletes for good, so saving a lower value takes two clicks.') : null,
        entry.stricter && !entry.readonly
          ? h('p.st-about.is-warn', 'Making it stricter refuses players at once, so it takes two clicks.') : null,
        entry.inflight ? h('p.st-inflight', h('b', 'Under way: '), String(entry.inflight)) : null,
        entry.readonly ? null : h('p.st-source', 'config.lua: ' + describe(entry, entry.default),
          overridden ? ' · in force from the panel' + (entry.by ? ', set by ' + entry.by : '')
            + (entry.at ? ' ' + ago(entry.at) : '') : ' · in force from config.lua'),
        entry.ignored ? h('p.st-about.is-error', 'The store holds a value that was not applied at start: '
          + String(entry.ignored) + '. config.lua\'s is in force; reset it to clear this.') : null,
        entry.unknown ? h('p.st-about.is-error', 'A change to it raised in the store, and so did reading it '
          + 'back (' + String(entry.unknown) + '): the store may or may not hold it. What is shown is in '
          + 'force; set or reset it again to settle it.') : null,
        answerBox(answer)),
      // A read-only key too, when the store holds a value for it that was
      // not applied (kept from a version where it could be changed): the
      // reset takes that row away, and nothing in force moves.
      h('div.st-control', settingControl(entry),
        entry.ignored || entry.unknown || (overridden && !entry.readonly)
          ? writeBtn('.is-small.is-ghost', 'st-reset', { 'data-key': key }, 'Reset to config.lua',
            'Click again to reset', 'arrow-rotate-left') : null));
  }

  function settingRow(entry) {
    return h('div.st-row' + (entry.source === 'panel' ? '.is-panel' : '') + (entry.ignored ? '.is-ignored' : ''),
      { id: 'st-row-' + entry.key, 'data-key': entry.key,
        'data-find': (String(entry.key) + ' ' + String(entry.label || '') + ' ' + String(entry.group || '')).toLowerCase() },
      settingInner(entry));
  }

  function drawSettingRow(key) {
    var entry = settingEntry(key);
    var row = byId('st-row-' + key);
    if (entry && row) setHtml(row, settingInner(entry));
  }

  var SETTING_TABS = [
    { value: 'features', label: 'Features' },
    { value: 'limits', label: 'Limits & settings' },
    { value: 'readonly', label: 'Read only' }
  ];

  var TAB_INTRO = {
    features: 'Every switch here takes effect at once and is kept across restarts. What is already under way '
      + 'finishes under the rules it started with; only new actions are refused, and players are told the '
      + 'feature is turned off by the server.',
    limits: 'Each value is checked the way the server checks config.lua at start. Lowering a cap below what is '
      + 'in use never cancels anything: it only refuses new ones over it. Rate limits are not caps: a '
      + 'stricter one refuses players at once, so it takes two clicks and says what it refuses, and the '
      + 'ones the app cannot work without have a floor.',
    readonly: 'Shown so you can see them, and changed only in config.lua: from here, a slip could lock staff '
      + 'out, or would need a migration.'
  };

  function settingsHead() {
    var d = S.settings.data;
    var overrides = d ? Number(d.overrides) || 0 : 0;
    return frag(
      segmented('st-tab', SETTING_TABS.map(function (t) {
        return { value: t.value, label: t.label + (d ? ' (' + settingList(t.value).length + ')' : '') };
      }), S.settings.tab),
      h('label.search', icon('magnifying-glass'),
        field('st.q', { id: 'st-q', placeholder: 'Find a setting', 'data-live': 'st-filter',
          'aria-label': 'Find a setting' })),
      h('span.sub', num(overrides) + ' changed from the panel'
        + (d && Number(d.notApplied) > 0 ? ', ' + num(d.notApplied) + ' kept and not applied' : '')),
      // Whenever the store holds a row, applied or not: one not applied (a
      // key from another version among them) is cleared by it too.
      overrides > 0 || (d && Number(d.stored) > 0) ? writeBtn('.is-danger.is-small', 'st-reset-all', {},
        'Reset all to config.lua', 'Click again to reset all', 'arrow-rotate-left') : null);
  }

  function settingsList() {
    var d = S.settings.data;
    if (!d) return loading('Reading the settings…');
    var list = settingList(S.settings.tab);
    if (!list.length) return empty('Nothing here.');
    var groups = [], byGroup = {};
    list.forEach(function (entry) {
      var g = String(entry.group || 'Other');
      if (!byGroup[g]) { byGroup[g] = []; groups.push(g); }
      byGroup[g].push(entry);
    });
    // In memory mode nothing is kept across a restart: the settings no more
    // than the contracts.
    var intro = S.settings.tab === 'features' && S.overview && S.overview.storage === 'memory'
      ? 'Every switch here takes effect at once, and lasts until the resource stops: this server runs in '
        + 'memory mode, which keeps nothing across a restart. What is already under way finishes under the '
        + 'rules it started with; only new actions are refused, and players are told the feature is turned '
        + 'off by the server.'
      : TAB_INTRO[S.settings.tab];
    return frag(h('p.hint', intro), groups.map(function (g) {
      return h('section.st-group', { 'data-group': g.toLowerCase() }, h('h3.st-group-title', g),
        byGroup[g].map(settingRow));
    }), h('p.empty', { id: 'st-none', hidden: true }, 'No setting matches.'));
  }

  /** Hide what the search box does not match: rows, then groups left empty. */
  function filterSettings() {
    var q = trim(S.forms['st.q']).toLowerCase();
    var list = byId('st-list');
    if (!list) return;
    var shown = 0;
    settingList(S.settings.tab).forEach(function (entry) {
      var row = byId('st-row-' + entry.key);
      if (!row) return;
      var hit = !q || row.getAttribute('data-find').indexOf(q) !== -1;
      row.hidden = !hit;
      if (hit) shown++;
      var group = row.parentNode;
      if (group) group.hidden = false;
    });
    // A group with nothing showing goes too.
    settingList(S.settings.tab).forEach(function (entry) {
      var row = byId('st-row-' + entry.key);
      var group = row && row.parentNode;
      if (!group) return;
      var any = false;
      for (var i = 0; i < group.children.length; i++) {
        var child = group.children[i];
        if (child.getAttribute && child.getAttribute('data-key') && !child.hidden) any = true;
      }
      group.hidden = !any;
    });
    var none = byId('st-none');
    if (none) none.hidden = shown > 0;
  }

  /** A typed value, in the type the key takes, or why not. */
  function parseSetting(entry, text) {
    if (entry.kind === 'number') {
      var raw = trim(text).replace(/,/g, '');
      if (raw === '' || !/^-?\d*\.?\d+$/.test(raw)) return { error: 'Not changed: ' + entry.key + ' has to be a number.' };
      var n = Number(raw);
      if (entry.integer && Math.floor(n) !== n) return { error: 'Not changed: ' + entry.key + ' has to be a whole number.' };
      if ((entry.min != null && n < entry.min) || (entry.max != null && n > entry.max)) {
        return { error: 'Not changed: ' + entry.key + ' has to be from ' + entry.min + ' to ' + entry.max + '.' };
      }
      return { value: n };
    }
    if (entry.kind === 'list') {
      var names = trim(text).split(/[\s,]+/).filter(function (s) { return s.length > 0; });
      for (var i = 0; i < names.length; i++) {
        if (!/^[A-Za-z0-9_-]{1,32}$/.test(names[i])) {
          return { error: 'Not changed: job names are letters, digits, - and _ only, up to 32 long.' };
        }
      }
      if (names.length > 50) return { error: 'Not changed: ' + entry.key + ' takes at most 50 names.' };
      return { value: names };
    }
    return { error: 'Not a setting the panel may change.' };
  }

  function setSetting(key, value, node) {
    write('setSetting', { key: key, value: value }, 'set:' + key, node).then(function (reply) {
      if (!reply) return;
      S.settings.answers[key] = { ok: reply.ok, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) {
        delete S.forms['st.' + key];
        // Read again, so who changed it and when are the server's.
        loadSettings();
      } else {
        drawSettingRow(key);
      }
    });
  }

  SHELL.settings = function () {
    return h('section.view',
      h('div.toolbar', { id: 'st-head' }, settingsHead()),
      h('div.stack', { id: 'st-list' }, settingsList()));
  };
  LOAD.settings = function () { loadSettings(); };

  /* ---- tools ---- */

  function linesBox(lines, later) {
    var all = asList(lines);
    var extra = asList(later);
    if (!all.length && !extra.length) return null;
    return h('pre.output', all.map(String).join('\n') + (extra.length ? '\n' + extra.map(String).join('\n') : ''));
  }

  function toolsBody() {
    var t = S.tools;
    return frag(
      h('div.cols',
        card('Bring timers forward', frag(
          h('p.about', 'Test servers only: brings every wait and cooldown forward. Deadlines are only ever '
            + 'moved later. Audited.'),
          h('div.btn-row', writeBtn('.is-danger', 'tl-refresh', {}, 'Bring timers forward', 'Click again: test servers only', 'forward')),
          t.refresh ? answerBox(t.refresh.answer) : null,
          t.refresh ? linesBox(t.refresh.lines) : null)),
        card('Audit log', frag(
          h('p.about', 'Writes every queued row of the audit log to the store now, rather than at the next flush. '
            + 'Works while recovery holds everything else back.'),
          h('div.btn-row', writeBtn('', 'tl-flush', {}, 'Flush the audit log', null, 'floppy-disk', true)),
          t.flush ? answerBox(t.flush) : null))),
      card('Diagnosis', frag(
        h('p.about', 'Why the app is not showing something, the server-wide checks, the settings that need '
          + 'attention, and what the console said. Name a player id to run the app\'s own reads as them.'),
        h('div.btn-row', field('tl.subject', { class: 'is-short', placeholder: 'Player id', inputmode: 'numeric',
          'data-enter': 'tl-diag', 'aria-label': 'Player id (optional)' }),
          btn('.is-primary', 'tl-diag', {}, 'Run the diagnosis', 'stethoscope')),
        t.diag && t.diag.error ? answerBox({ ok: false, text: t.diag.error }) : null,
        t.diag ? linesBox(t.diag.lines, t.diag.later) : null)));
  }

  SHELL.tools = function () { return h('section.view', h('div.stack', { id: 'tl' }, toolsBody())); };
  LOAD.tools = function () {};

  function drawTools() { if (S.section === 'tools') setHtml(byId('tl'), toolsBody()); }

  /* ---------- what a click, a key or typing does ----------------------- */

  var ACTIONS = {};
  var LIVE = {};

  ACTIONS.close = function () { close(); };
  ACTIONS.section = function (node) { show(node.getAttribute('data-section')); };
  ACTIONS['toast-close'] = function (node) { node.remove(); };

  ACTIONS['dd-open'] = function (node) {
    var name = node.getAttribute('data-dd');
    var was = S.menu;
    if (was) closeMenu();
    if (was === name) return;
    S.menu = name;
    redrawDropdown(name);
  };
  ACTIONS['dd-pick'] = function (node) {
    var name = node.getAttribute('data-dd');
    var p = ddParts(name);
    S.menu = null;
    if (p.def) p.def.pick(node.getAttribute('data-value'), p.arg);
    redrawDropdown(name);
  };

  ACTIONS['ov-refresh'] = function () { loadOverview(true); };
  /** A state chip: the contracts in that state, as many as it counted, so
      nothing typed or picked before narrows the list. */
  ACTIONS['ov-state'] = function (node) {
    S.forms['ct.q'] = '';
    S.forms['ct.from'] = '';
    S.forms['ct.to'] = '';
    S.contracts.rule = '';
    S.contracts.range = '';
    S.contracts.state = node.getAttribute('data-value') || '';
    S.contracts.page = 1;
    show('contracts');
  };
  /** Run it: the diagnosis, run, not only the section it is run from. */
  ACTIONS['ov-diag'] = function () {
    show('tools');
    ACTIONS['tl-diag']();
  };

  ACTIONS['ct-search-now'] = function () { S.contracts.page = 1; loadContracts(); };
  LIVE['ct-search'] = function () {
    clearTimeout(S.contracts.timer);
    S.contracts.timer = setTimeout(function () {
      S.contracts.timer = null;
      S.contracts.page = 1;
      loadContracts();
    }, DEBOUNCE_MS);
  };
  ACTIONS['ct-page'] = function (node) {
    S.contracts.page = Math.max(1, Number(node.getAttribute('data-value')) || 1);
    loadContracts();
  };
  ACTIONS['ct-clear'] = function () {
    S.forms['ct.q'] = '';
    S.forms['ct.from'] = '';
    S.forms['ct.to'] = '';
    S.contracts.state = '';
    S.contracts.rule = '';
    S.contracts.range = '';
    S.contracts.page = 1;
    show('contracts');
  };
  ACTIONS.contract = function (node) { openContract(node.getAttribute('data-id')); };
  ACTIONS['drawer-close'] = function () { closeDrawer(); };

  function drawerAnswer(reply) {
    S.drawer.answer = { ok: reply.ok === true, text: words(reply) };
    toast(words(reply), reply.ok ? 'ok' : 'error');
  }

  ACTIONS['void'] = function (node) {
    var id = S.drawer.id;
    if (!id || !confirmed(node)) return;
    var reason = trim(S.forms['dr.reason']).slice(0, 120);
    var data = { id: id };
    if (reason) data.reason = reason;
    write('void', data, 'void:' + id, node).then(function (reply) {
      if (!reply || S.drawer.id !== id) return;
      drawerAnswer(reply);
      if (reply.ok) {
        S.forms['dr.reason'] = '';
        if (S.section === 'contracts') loadContracts();
      }
      drawDrawer();
      loadContract();
    });
  };

  ACTIONS.settle = function (node) {
    var line = node.getAttribute('data-line');
    var how = node.getAttribute('data-how');
    var inStuck = node.getAttribute('data-where') === 'stuck';
    var data = { line: line, disposition: how === 'pay_amount' ? 'pay' : (how === 'return_owner' ? 'return' : how) };
    var problem = null;
    if (how === 'pay_amount') {
      data.amount = wholeNumber(S.forms['dr.amount.' + line]);
      if (!data.amount) problem = 'An amount is a whole number of at least 1.';
    } else if (how === 'return_owner') {
      data.owner = trim(S.forms['dr.owner.' + line]);
      if (!/^[A-Za-z0-9_-]{3,64}$/.test(data.owner)) problem = 'Give the citizen id of whoever put it up.';
    }
    if (problem) {
      disarm();
      if (inStuck) {
        S.stuck.answers[line] = { ok: false, text: problem };
        drawStuck();
      } else {
        S.drawer.answer = { ok: false, text: problem };
        drawDrawer();
      }
      return;
    }
    if (!confirmed(node)) return;
    var id = S.drawer.id;
    write('settle', data, 'settle:' + line, node).then(function (reply) {
      if (!reply) return;
      if (reply.ok) {
        delete S.forms['dr.amount.' + line];
        delete S.forms['dr.owner.' + line];
      }
      if (inStuck) {
        // Its answer stays beside it, and the list is read again: a line
        // settled leaves it, and one re-queued or left again says so.
        S.stuck.answers[line] = { ok: reply.ok === true, text: words(reply) };
        toast(words(reply), reply.ok ? 'ok' : 'error');
        drawStuck();
        loadStuck();
        return;
      }
      // Opened from Stuck escrow, the list behind it is read again too.
      if (S.section === 'stuck') loadStuck();
      if (S.drawer.id !== id) return;
      drawerAnswer(reply);
      drawDrawer();
      loadContract();
    });
  };

  ACTIONS['sk-refresh'] = function () { S.stuck.answers = {}; loadStuck(); };

  ACTIONS.whois = function (node) {
    if (!canIdentify()) return;
    var id = node.getAttribute('data-id');
    var where = node.getAttribute('data-where');
    ask('whois', { id: id }).then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { toast(words(reply), 'error'); return; }
      if (where === 'player') {
        S.players.whois[id] = reply.data || {};
        if (S.section === 'players') setHtml(byId('pl-result'), playerBody());
      } else if (S.drawer.id === id) {
        S.drawer.whois = reply.data || {};
        drawDrawer();
      }
    });
  };

  ACTIONS['rv-all'] = function (node) {
    S.reviews.all = node.getAttribute('data-value') === 'all';
    S.reviews.items = null;
    show('reviews');
  };
  ACTIONS['rv-refresh'] = function () { loadReviews(); };
  ACTIONS['rv-action'] = function (node) {
    var id = node.getAttribute('data-id');
    S.reviews.action[id] = node.getAttribute('data-value');
    disarm();
    setHtml(byId('rv-list'), reviewList());
  };
  ACTIONS['rv-goods'] = function (node) {
    var id = node.getAttribute('data-id');
    S.forms['rv.' + id + '.goods'] = node.getAttribute('data-value');
    setHtml(byId('rv-list'), reviewList());
  };
  ACTIONS.resolve = function (node) {
    var id = node.getAttribute('data-id');
    var item = reviewItem(id);
    if (!item) return;
    var action = S.reviews.action[id] || 'refund';
    var data = { id: id, action: action };
    var problem = null;
    if (action === 'dismiss') {
      data.note = trim(S.forms['rv.' + id + '.note']).slice(0, 200);
      if (!data.note) problem = 'Say why in a note: a dismissal gives nothing, and the note is the record of why.';
    } else {
      data.who = DD['rv-who'].value(id);
      if (!data.who) problem = 'The item names nobody to give it to.';
      if (action === 'refund') {
        if (S.forms['rv.' + id + '.goods'] === 'yes') {
          data.goods = true;
        } else {
          data.amount = wholeNumber(S.forms['rv.' + id + '.amount']);
          data.account = DD['rv-account'].value(id);
          if (!data.amount && !problem) problem = 'An amount is a whole number of at least 1.';
        }
      }
    }
    if (problem) {
      disarm();
      S.reviews.answers[id] = { ok: false, text: problem };
      setHtml(byId('rv-list'), reviewList());
      return;
    }
    if (!confirmed(node)) return;
    write('resolve', data, 'resolve:' + id, node).then(function (reply) {
      if (!reply) return;
      S.reviews.answers[id] = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (S.section === 'reviews') setHtml(byId('rv-list'), reviewList());
      loadReviews(true);
    });
  };

  ACTIONS['resolve-finish'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!reviewItem(id)) return;
    if (!confirmed(node)) return;
    write('resolve', { id: id, action: 'finish' }, 'resolve:' + id, node).then(function (reply) {
      if (!reply) return;
      S.reviews.answers[id] = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (S.section === 'reviews') setHtml(byId('rv-list'), reviewList());
      loadReviews(true);
    });
  };

  ACTIONS['lg-search-now'] = function () { firstLogPage(true); };
  LIVE['lg-search'] = function () {
    clearTimeout(S.logs.timer);
    S.logs.timer = setTimeout(function () { S.logs.timer = null; firstLogPage(); }, DEBOUNCE_MS + 100);
  };
  ACTIONS['lg-older'] = function () {
    var d = S.logs.data;
    if (!d || d.next === undefined || d.next === null) return;
    S.logs.back.push(S.logs.cursor);
    S.logs.cursor = d.next;
    S.logs.open = {};
    loadLogs();
  };
  ACTIONS['lg-newer'] = function () {
    if (!S.logs.back.length) return;
    S.logs.cursor = S.logs.back.pop();
    S.logs.open = {};
    loadLogs();
  };
  ACTIONS['lg-expand'] = function (node) {
    var i = node.getAttribute('data-index');
    S.logs.open[i] = !S.logs.open[i];
    setHtml(byId('lg-results'), logRows());
  };
  ACTIONS['lg-clear'] = function () {
    ['lg.action', 'lg.contract', 'lg.actor', 'lg.from', 'lg.to'].forEach(function (k) { S.forms[k] = ''; });
    S.logs.kind = '';
    S.logs.range = '';
    S.logs.cursor = null;
    S.logs.back = [];
    show('logs');
  };

  ACTIONS['pl-lookup'] = function () { loadPlayer(); };

  ACTIONS['st-tab'] = function (node) {
    S.settings.tab = node.getAttribute('data-value') || 'features';
    disarm();
    drawSettings();
  };
  LIVE['st-filter'] = function () { filterSettings(); };
  ACTIONS['st-switch'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    if (!entry || entry.readonly) return;
    setSetting(key, entry.value !== true, node);
  };
  ACTIONS['st-choice'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    var value = node.getAttribute('data-value');
    if (!entry || entry.readonly || String(entry.value) === value) return;
    setSetting(key, value, node);
  };
  ACTIONS['st-save'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    if (!entry || entry.readonly || !writesOpen()) return;
    var typed = S.forms['st.' + key];
    if (typed === undefined) typed = entry.kind === 'list' ? asList(entry.value).join(', ') : String(entry.value);
    var parsed = parseSetting(entry, typed);
    if (parsed.error) {
      S.settings.answers[key] = { ok: false, text: parsed.error };
      drawSettingRow(key);
      return;
    }
    // A value that deletes something for good, or a rate limit made
    // stricter, takes the two clicks every destructive button does, the row
    // saying what the second one does. Saved on one click or on Enter, a
    // typo of 1 for 10 days lost every unopened kill photo older than a day
    // at the next sweep. Enter only ever arms it, and the second click saves
    // only the value the first one named: anything typed since arms again
    // with its own words.
    var said = secondClick(entry, parsed.value);
    if (said) {
      if (node.tagName === 'BUTTON' && S.armed && S.armed.node === node && S.armed.value === parsed.value) {
        disarm();
        setSetting(key, parsed.value, node);
        return;
      }
      disarm();
      S.settings.answers[key] = { ok: false, text: said + ' Click Save again to do it.' };
      drawSettingRow(key);
      var button = byId('st-save-' + key);
      if (button) {
        confirmed(button);
        if (S.armed) { S.armed.value = parsed.value; S.armed.bind = 'st.' + key; }
      }
      return;
    }
    setSetting(key, parsed.value, node.tagName === 'BUTTON' ? node : null);
  };
  ACTIONS['st-reset'] = function (node) {
    var key = node.getAttribute('data-key');
    if (!confirmed(node)) return;
    write('resetSetting', { key: key }, 'set:' + key, node).then(function (reply) {
      if (!reply) return;
      S.settings.answers[key] = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      delete S.forms['st.' + key];
      if (reply.ok) loadSettings(); else drawSettingRow(key);
    });
  };
  ACTIONS['st-reset-all'] = function (node) {
    if (!confirmed(node)) return;
    write('resetSettings', {}, 'reset-all', node).then(function (reply) {
      if (!reply) return;
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) {
        S.settings.answers = {};
        Object.keys(S.forms).forEach(function (k) { if (k.indexOf('st.') === 0 && k !== 'st.q') delete S.forms[k]; });
        loadSettings();
      }
    });
  };

  ACTIONS['tl-refresh'] = function (node) {
    if (!confirmed(node)) return;
    write('refresh', {}, 'refresh', node).then(function (reply) {
      if (!reply) return;
      toast(words(reply), reply.ok ? 'ok' : 'error');
      S.tools.refresh = { answer: { ok: reply.ok === true, text: words(reply) },
                          lines: reply.ok ? (reply.data || {}).lines : null };
      drawTools();
    });
  };
  ACTIONS['tl-flush'] = function (node) {
    write('flush', {}, 'flush', node).then(function (reply) {
      if (!reply) return;
      toast(words(reply), reply.ok ? 'ok' : 'error');
      S.tools.flush = { ok: reply.ok === true, text: words(reply) };
      drawTools();
    });
  };
  ACTIONS['tl-diag'] = function () {
    var subject = trim(S.forms['tl.subject']);
    if (subject && !/^\d{1,5}$/.test(subject)) {
      S.tools.diag = { error: 'Give a player id, or nothing to run it as yourself.' };
      drawTools();
      return;
    }
    S.tools.diag = { lines: ['Running…'], later: [] };
    drawTools();
    ask('diag', subject ? { subject: Number(subject) } : {}, 'diag').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) S.tools.diag = { error: words(reply) };
      else S.tools.diag = { lines: asList((reply.data || {}).lines), later: [] };
      drawTools();
    });
  };

  function actorOf(node) {
    while (node && node !== document) {
      if (node.getAttribute && node.getAttribute('data-act')) return node;
      node = node.parentNode;
    }
    return null;
  }

  /** A fault in a handler is said, not swallowed: in CEF nobody reads a console. */
  function run(fn, node, event) {
    try { fn(node, event); } catch (err) {
      toast('The page hit an error: ' + (err && err.message ? err.message : String(err)), 'error');
    }
  }

  document.addEventListener('click', function (event) {
    var node = actorOf(event.target);
    var act = node ? node.getAttribute('data-act') : null;
    // A click anywhere but the dropdown closes it.
    if (S.menu && act !== 'dd-open' && act !== 'dd-pick') closeMenu();
    if (!node || node.disabled || !ACTIONS[act]) return;
    if (!S.open && act !== 'toast-close') return;
    run(ACTIONS[act], node, event);
  });

  document.addEventListener('input', function (event) {
    var node = event.target;
    if (!node || !node.getAttribute) return;
    var bind = node.getAttribute('data-bind');
    if (bind) S.forms[bind] = node.value;
    // Typing in a box whose Save is armed disarms it: what the armed click
    // named is no longer what is in the box.
    if (bind && S.armed && S.armed.bind === bind) disarm();
    var live = node.getAttribute('data-live');
    if (live && LIVE[live]) run(LIVE[live], node, event);
  });

  /* Escape closes on its release, not its press. Closed on the press, the
     focus went back to the game with the key still down, and the rest of
     that keystroke reached it: the pause menu opened as the panel closed.
     The client holds the pause keys off for a moment after, too. */
  function isEscape(event) { return event.key === 'Escape' || event.key === 'Esc'; }

  document.addEventListener('keyup', function (event) {
    if (!S.open || !isEscape(event)) return;
    if (event.preventDefault) event.preventDefault();
    close();
  });

  document.addEventListener('keydown', function (event) {
    if (!S.open) return;
    if (isEscape(event)) {
      if (event.preventDefault) event.preventDefault();
      return;
    }
    if (event.key === 'Enter') {
      var node = event.target;
      var enter = node && node.getAttribute && node.getAttribute('data-enter');
      if (enter && ACTIONS[enter]) {
        if (event.preventDefault) event.preventDefault();
        run(ACTIONS[enter], node, event);
        return;
      }
      // A row that opens something opens on Enter, as a button would.
      var actor = actorOf(node);
      if (actor && actor.tagName === 'TR' && ACTIONS[actor.getAttribute('data-act')]) {
        run(ACTIONS[actor.getAttribute('data-act')], actor, event);
      }
    }
  });

  /* ---------- opening and closing -------------------------------------- */

  function clearTimers() {
    clearTimeout(S.overviewTimer);
    clearTimeout(S.contracts.timer);
    clearTimeout(S.logs.timer);
    S.overviewTimer = S.contracts.timer = S.logs.timer = null;
    disarm();
  }

  /** Forget everything read while open: the next open reads it afresh, as
      the staff member's access then is. */
  function forget() {
    S.overview = null;
    S.overviewAt = 0;
    S.overviewError = null;
    S.contracts.data = null;
    S.reviews.items = null;
    S.reviews.answers = {};
    S.logs.data = null;
    S.logs.cursor = null;
    S.logs.back = [];
    S.logs.open = {};
    S.players.data = null;
    S.players.whois = {};
    S.settings.data = null;
    S.settings.answers = {};
    S.tools = { refresh: null, diag: null, flush: null };
    S.busy = {};
    S.seq = {};
    S.menu = null;
    S.drawer = { id: null, data: null, answer: null, whois: null };
    S.stuck = { data: null, error: null, answers: {} };
  }

  /** The page's side of closing, however it closes. */
  function hide() {
    var was = S.open;
    S.open = false;
    S.gen++;
    clearTimers();
    forget();
    var panel = byId('panel');
    if (panel) panel.hidden = true;
    var drawer = byId('drawer'), scrim = byId('scrim');
    if (drawer) { drawer.hidden = true; setHtml(drawer, frag()); }
    if (scrim) scrim.hidden = true;
    setHtml(byId('main'), frag());
    return was;
  }

  /** Close from the page (its button, Escape, or the server no longer
      letting this staff member read): the client releases the focus, in its
      one close function. `why` is said as the panel goes. */
  function close(why) {
    hide();
    var box = byId('toasts');
    if (box && !why) setHtml(box, frag());
    if (why) toast(why, 'error');
    nui('adminClose', {});
  }

  function open(access) {
    var reopened = S.open;
    S.access = access && typeof access === 'object' ? access : {};
    S.recovery = S.access.recovery || 'ready';
    if (!reopened) {
      S.gen++;
      S.open = true;
    }
    var panel = byId('panel');
    if (panel) panel.hidden = false;
    show(S.section);
    startPolling();
  }

  /** The overview's refresh, once per open: an open the server repeats
      (staff typing the command again) keeps the chain it already has, even
      while that chain's request is in flight and no timer is set. */
  function startPolling() {
    if (S.pollGen === S.gen) return;
    S.pollGen = S.gen;
    var gen = S.gen;
    // On the overview, show() has just asked for it.
    if (S.section !== 'overview') loadOverview(false).then(function () { schedule(gen); });
    else schedule(gen);
  }

  window.addEventListener('message', function (event) {
    var message = (event && event.data) || {};
    if (message.type === 'open') {
      open(message.access);
    } else if (message.type === 'close') {
      // Closed from the game (Escape there, the resource stopping). One the
      // page closed itself is already closed, and keeps what it said as it
      // went (an ACE taken away).
      if (!S.open) return;
      hide();
      setHtml(byId('toasts'), frag());
    } else if (message.type === 'push' && message.kind === 'diag' && typeof message.line === 'string') {
      // A diagnosis line that had to wait for an answer (the photo address check).
      if (!S.open) return;
      if (!S.tools.diag || S.tools.diag.error) S.tools.diag = { lines: [], later: [] };
      S.tools.diag.later = asList(S.tools.diag.later).concat([message.line]);
      drawTools();
    }
  });
})();
