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

  /** A server time as the local time of day, to the second. */
  function clock(ts) {
    var t = Number(ts);
    if (!t) return '--:--:--';
    var d = new Date(t * 1000);
    return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
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
  var MODE_LABEL = { exclusive: 'Exclusive', competitive: 'Competitive' };
  var SOURCE_LABEL = { cash: 'cash', bank: 'bank', dirty: 'dirty money', item: 'item', weapon: 'weapon' };
  var MONEY = { cash: true, bank: true, dirty: true };

  function stateChip(state) {
    var cls = LIVE_STATES[state] ? 'is-live' : (state === 'voided' ? 'is-void' : 'is-closed');
    return h('span.chip', { class: 'state ' + cls }, STATE_LABEL[state] || state || '—');
  }

  /** How many of a review item's goods were kept without their metadata. */
  function bareGoods(item) {
    return asList(item && item.items).filter(function (g) { return g && g.metadata_omitted === true; }).length;
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

  /* Six sections by who uses them, each holding views as sub-tabs. Every
     view the panel had is still one; the settings are split by category
     (the catalogue's `category`, server/settings.lua). Developer is only for
     staff the server says may open it (access.canDevelop); everybody else
     has its Permissions page alone, under that name. */
  var GROUPS = [
    { id: 'live', views: ['help', 'overview', 'contracts', 'players', 'frozen', 'reviews', 'stuck'],
      first: 'overview' },
    { id: 'actions', views: ['actions', 'tools', 'announce'] },
    { id: 'rules', views: ['timers', 'money', 'limits', 'targeting'] },
    { id: 'features', views: ['features'] },
    { id: 'logs', views: ['logs', 'alerts'] },
    { id: 'developer', views: ['devsettings', 'console', 'diagnostics', 'permissions', 'history'], developer: true }
  ];
  /** The views only the Developer section's staff see. */
  var DEV_VIEWS = { devsettings: true, console: true, diagnostics: true };
  var SECTIONS = [];
  GROUPS.forEach(function (g) { SECTIONS = SECTIONS.concat(g.views); });
  /** Old names, so a link or a remembered view from before lands somewhere. */
  var ALIASES = { settings: 'features' };

  /** The settings view each category is shown in. */
  var CATEGORY_VIEW = {
    'rules-timers': 'timers', 'rules-rewards': 'money', 'rules-limits': 'limits',
    'rules-targeting': 'targeting', features: 'features', developer: 'devsettings'
  };
  var SETTING_VIEWS = { timers: true, money: true, limits: true, targeting: true, features: true,
                        devsettings: true };

  /** Ops that only read. A refusal of one as not_allowed means the staff
      member may no longer read at all (an ACE taken away while the panel was
      open), and the panel closes on it, as the README says it does. */
  var READ_OPS = { access: true, overview: true, contracts: true, contract: true, reviews: true,
                   logs: true, player: true, settings: true, diag: true, whois: true, stuck: true,
                   alerts: true, console: true, frozen: true, exportContract: true, playerView: true,
                   history: true, settingsHistory: true };

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
    alerts: { state: 'open', data: null, error: null, answers: {}, all: null, test: null },
    console: { kind: '', data: null, error: null, sig: null, loading: false, readAt: null },
    logs: { kind: '', range: '', cursor: null, back: [], data: null, open: {}, timer: null },
    players: { data: null, whois: {}, subject: null, playtime: null, freeze: null, frozen: null },
    settings: { data: null, answers: {}, photos: null, drafts: {} },
    remembered: {},         // [group] = the sub-tab last open in it
    tools: { refresh: null, diag: null, flush: null }
  };

  function canWrite() { return S.access.canWrite === true; }
  function canIdentify() { return S.access.canIdentify === true; }
  /** Writes wait for boot recovery, as the commands do; flushing the log does not. */
  function writesOpen() { return canWrite() && S.recovery === 'ready'; }
  /** Whether a setting's controls are open: to the staff ACE, and a setting
      of the Developer section to the developer ACE too (never a denied one),
      as the server allows its setSetting and resetSetting. */
  function settingOpen(entry) {
    if (writesOpen()) return true;
    return !!entry && entry.category === 'developer' && !entry.denied && canDevelop()
      && S.recovery === 'ready';
  }

  function whyNoWrite() {
    if (!canWrite()) {
      if (canModerate()) {
        return 'Moderator: you may freeze, suspend, protect, void and move deadlines; this needs the staff '
          + 'ACE itself (Config.Admin.Ace).';
      }
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
    busy: 'Another change is being saved right now. Try again in a moment.',
    no_webhook: 'No Discord webhook is set in server.cfg.',
    discord_off: 'Posting alerts to Discord is switched off (Alerts.ToDiscord).',
    unavailable: 'Alerts are not running on this server yet.',
    photos_on: 'Kill photos are on: turn them off first.'
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
  function writeBtn(cls, act, attrs, label, confirmLabel, iconName, always, open) {
    var a = attrs || {};
    a.type = 'button';
    a['data-act'] = act;
    var allowed = open !== undefined ? open : (always ? canWrite() : writesOpen());
    if (!allowed) { a.disabled = true; a.title = a.title || whyNoWrite(); }
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
        : canModerate()
          ? h('span.badge.is-moderator', { title: whyNoWrite() }, icon('gavel'), 'Moderator')
          : h('span.badge.is-read', { title: whyNoWrite() }, icon('eye'), 'Read only'),
      canIdentify()
        ? h('span.badge.is-identity', { title: 'You see who is behind anonymous parties; every lookup is on the record' },
          icon('user-secret'), 'Sees identities')
        : h('span.badge', { title: 'Anonymous parties show as Anonymous, and citizen ids as roles' },
          icon('mask'), 'Identities hidden')));
    drawBanner();
    var current = groupOf(S.section);
    GROUPS.forEach(function (g) {
      var top = byId('grp-' + g.id);
      if (top) {
        top.classList.toggle('is-on', g === current);
        top.setAttribute('aria-current', g === current ? 'page' : 'false');
        if (g.developer) {
          var lbl = top.querySelector('.lbl');
          if (lbl) lbl.textContent = canDevelop() ? 'Developer' : 'Permissions';
        }
      }
    });
    SECTIONS.forEach(function (name) {
      var node = byId('nav-' + name);
      if (!node) return;
      node.hidden = !(current && current.views.indexOf(name) !== -1 && viewAllowed(name));
      node.classList.toggle('is-on', name === S.section);
      node.setAttribute('aria-current', name === S.section ? 'page' : 'false');
    });
    // One sub-tab is no strip at all.
    var subnav = byId('subnav');
    if (subnav) subnav.hidden = !current || current.views.filter(viewAllowed).length < 2;
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
    setCount('count-alerts', o.alerts ? Number(o.alerts.open) || 0 : 0, 'open alerts, not acknowledged yet');
    // On the sections, what waits in their sub-tabs.
    setCount('count-live', (o.reviews ? Number(o.reviews.open) || 0 : 0)
      + (o.stuck ? Number(o.stuck.leftForStaff) || 0 : 0), 'waiting for staff in the review queue and stuck escrow');
    setCount('count-logs', o.alerts ? Number(o.alerts.open) || 0 : 0, 'open alerts, not acknowledged yet');
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

  function canDevelop() { return S.access.canDevelop === true; }

  /** The section a view is a sub-tab of. */
  function groupOf(view) {
    for (var i = 0; i < GROUPS.length; i++) if (GROUPS[i].views.indexOf(view) !== -1) return GROUPS[i];
    return null;
  }

  /** Whether this staff member is shown a view at all. */
  function viewAllowed(view) { return !DEV_VIEWS[view] || canDevelop(); }

  /* Where the staff member was, kept in this browser only: the last view,
     and the sub-tab last open in each section. Storage that throws (private
     mode, a CEF profile without it) is no storage, never a fault. */
  var STORE_KEY = 'crimson-hitman.admin.nav';

  function remember() {
    try {
      window.localStorage.setItem(STORE_KEY, JSON.stringify({ view: S.section, sub: S.remembered }));
    } catch (err) { /* not kept */ }
  }

  function recall() {
    try {
      var kept = JSON.parse(window.localStorage.getItem(STORE_KEY) || 'null');
      if (!kept || typeof kept !== 'object') return;
      if (kept.sub && typeof kept.sub === 'object') {
        Object.keys(kept.sub).forEach(function (g) {
          if (typeof kept.sub[g] === 'string' && SECTIONS.indexOf(kept.sub[g]) !== -1) S.remembered[g] = kept.sub[g];
        });
      }
      if (typeof kept.view === 'string' && SECTIONS.indexOf(kept.view) !== -1) S.section = kept.view;
    } catch (err) { /* nothing kept */ }
  }

  /** A section's own sub-tab: the one last open in it, else its first. */
  function openGroup(id) {
    var g = GROUPS.filter(function (x) { return x.id === id; })[0];
    if (!g) return;
    var views = g.views.filter(viewAllowed);
    var want = S.remembered[g.id];
    show(views.indexOf(want) !== -1 ? want : (views.indexOf(g.first) !== -1 ? g.first : views[0]));
  }

  function show(section) {
    if (ALIASES[section]) section = ALIASES[section];
    if (SECTIONS.indexOf(section) === -1) section = 'overview';
    // Developer views for staff the server says may not open them: the
    // Permissions page, which everybody may read.
    if (!viewAllowed(section)) section = 'permissions';
    S.section = section;
    var g = groupOf(section);
    if (g) S.remembered[g.id] = section;
    remember();
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
      // The timed refresh (and opening the section, drawn just before from
      // what is held) with the answer it already shows, word for word: only
      // its Updated time moves. The whole overview was rebuilt every ten
      // seconds the panel stood open, the same each time.
      var text = null;
      if (reply.ok) {
        try { text = JSON.stringify(reply.data || {}); } catch (err) { text = null; }
      }
      var same = !manual && reply.ok && text !== null && S.overview && text === S.overviewText
        && !S.overviewError;
      if (!reply.ok) {
        S.overviewError = words(reply);
        if (manual || !S.overview) toast(S.overviewError, 'error');
      } else {
        S.overview = reply.data || {};
        S.overviewText = text;
        S.overviewAt = nowSeconds();
        S.overviewError = null;
        if (S.overview.recovery) setRecovery(S.overview.recovery);
      }
      drawCounts();
      if (S.section !== 'overview') return;
      var at = same && byId('ov-at');
      if (at) { at.textContent = overviewStamp(); return; }
      setHtml(byId('ov'), overviewBody());
    });
  }

  /** The overview's foot: when it was read and how often it is. */
  function overviewStamp() {
    return ' Updated ' + (S.overviewAt ? when(S.overviewAt).slice(11) : '\u2014') + ' \u00b7 refreshes every '
      + Math.round(refreshMs() / 1000) + ' s';
  }

  /** The overview again every Config.Admin.PanelRefreshSeconds while the
      panel is open: one timer, started on open and stopped on close. */
  function schedule(gen) {
    if (gen !== S.gen || !S.open) return;
    clearTimeout(S.overviewTimer);
    S.overviewTimer = setTimeout(function () {
      S.overviewTimer = null;
      if (gen !== S.gen || !S.open) return;
      // The next one is set however this one ends: a draw that threw (a
      // rejected promise, or a raise before it) used to end the chain, and
      // the panel stopped refreshing until it was closed and opened again.
      var next = function () { schedule(gen); };
      try {
        // Stuck escrow too while it is on screen, so its list and the badge
        // agree after another staff member settles a line.
        if (S.section === 'stuck' && !S.drawer.id) loadStuck(true);
        // And the alerts, unless a button there waits for its second click.
        if (S.section === 'alerts' && !S.drawer.id && !S.armed) loadAlerts();
        // And the console: its live updates, at this pace and no faster.
        if (S.section === 'console' && !S.drawer.id) loadConsole();
        loadOverview(false).then(next, next);
      } catch (err) {
        next();
      }
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
    var alertsOpen = o.alerts ? Number(o.alerts.open) || 0 : 0;
    var frozenCount = o.frozen ? Number(o.frozen.players) || 0 : 0;

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
        tile('Frozen players', frag(
          h('p.big' + (frozenCount > 0 ? '.is-warn' : ''), { id: 'ov-frozen' }, num(frozenCount)),
          h('p.sub', 'player' + (frozenCount === 1 ? '' : 's') + ' whose contracts are on hold'),
          btn('.is-small', 'section', { 'data-section': 'players' }, 'Open Players', 'arrow-right')),
          frozenCount > 0 ? '.is-warn' : ''),
        tile('Needs review', frag(
          h('p.big' + (reviewsOpen > 0 ? '.is-warn' : ''), num(reviewsOpen)),
          h('p.sub', 'open item' + (reviewsOpen === 1 ? '' : 's') + ' in the review queue'),
          btn('.is-small', 'section', { 'data-section': 'reviews' }, 'Open the queue', 'arrow-right')),
          reviewsOpen > 0 ? '.is-warn' : ''),
        tile('Alerts', frag(
          h('p.big' + (alertsOpen > 0 ? '.is-warn' : ''), { id: 'ov-alerts' }, num(alertsOpen)),
          h('p.sub', 'open alert' + (alertsOpen === 1 ? '' : 's') + ', not acknowledged yet'),
          btn('.is-small', 'section', { 'data-section': 'alerts' }, 'Open Alerts', 'arrow-right')),
          alertsOpen > 0 ? '.is-warn' : ''),
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
            'data-section': 'settings' }, (Number(o.overrides) > 0 ? num(o.overrides) + ' changed'
              : 'None changed') + ' \u2014 open Settings'),
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
        h('span', { id: 'ov-at' }, overviewStamp()),
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
          h('td.mono.nowrap', String(row.id)), h('td', stateChip(row.state),
            row.frozen ? h('span.chip.is-warn.is-frozen', 'Frozen') : null),
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
    S.forms['dr.dl.min'] = '';
    S.forms['dr.dl.reason'] = '';
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
        S.drawer.readAt = nowSeconds();
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
        d && d.contract ? h('span.chip', RULE_LABEL[d.contract.rule] || String(d.contract.rule || '')) : null,
        d && d.frozen ? h('span.chip.is-warn.is-frozen', { title: 'On hold: frozen by staff ('
          + asList(d.frozen).join(', ') + ')' }, 'Frozen') : null),
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
            maxlength: '120', disabled: !modOpen(), 'aria-label': 'Reason for the void' }),
          modBtn('.is-danger', 'void', {}, 'Void contract', 'Click again to void', 'ban'))
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
    var deadlinePart = stub ? null : card('Deadline', deadlineBody(d.deadline));

    /* Look up / Freeze beside each party it names: the Players view on
       them, where Freeze is. Named by the contract and the role, which the
       server resolves (playerSubject), so no citizen id is needed here. Not
       for a party who is anonymous on it to staff without IdentityAce. */
    function partyButton(role, opId) {
      return btn('.is-small.is-ghost', 'party-lookup', { 'data-subject': 'contract:' + id + ':' + role
        + (opId ? ':' + opId : '') }, 'Look up / Freeze', 'magnifying-glass');
    }
    var clientHidden = c.anonymous && !canIdentify();
    var terms = h('dl.facts.is-terms',
      h('dt', 'Mode'), h('dd', MODE_LABEL[c.mode] || String(c.mode || '—')),
      h('dt', 'Completes by'), h('dd', RULE_LABEL[c.rule] || String(c.rule || '—')),
      h('dt', 'Reason'), h('dd.text', String(c.reason || '—')),
      h('dt', 'Client'), h('dd', personCell(c.client), c.anonymous ? h('span.chip.is-anon', 'anonymous') : null,
        clientHidden ? null : partyButton('client')),
      h('dt', 'Target'), h('dd', personCell(c.target), c.target_protected ? h('span.chip.is-warn', 'law enforcement') : null,
        partyButton('target')),
      h('dt', 'Placed'), h('dd', when(c.created_at)),
      h('dt', 'Deadline'), h('dd', c.deadline_at ? when(c.deadline_at) + ' (' + ago(c.deadline_at) + ')' : '—'),
      h('dt', 'Expires'), h('dd', when(c.expires_at)),
      c.paused_since ? h('dt', 'Paused since') : null, c.paused_since ? h('dd', when(c.paused_since)) : null,
      h('dt', 'Ended'), h('dd', c.resolved_at ? String(c.resolution || '') + ' ' + when(c.resolved_at) : 'not yet'),
      h('dt', 'Payouts'), h('dd', num(c.claimed) + ' of ' + num(c.slots) + ' claimed'
        + (c.next_slot ? ' · next ' + c.next_slot : '')),
      h('dt', 'Bonus'), h('dd', num(c.bonus_percent) + '%'),
      h('dt', 'Stake'), h('dd', money(c.penalty_amount)),
      h('dt', 'Buyout price'), h('dd', money(c.bailout_amount) + (c.buyout_queued ? ' · a buyout is queued' : '')),
      // The handover's meeting point: where the client stood, sent to staff
      // with the identity ACE alone, as who they are is.
      c.meeting ? h('dt', 'Meeting point') : null,
      c.meeting ? h('dd', 'x ' + String(Number(c.meeting.x)) + ', y '
        + String(Number(c.meeting.y))) : null);

    return frag(head, answerBox(S.drawer.answer), h('div.drawer-body',
      actions,
      whois,
      stuckPart,
      deadlinePart,
      stub ? null : card('Terms', terms),
      stub ? null : contractTools(d),
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
          // Look up / Freeze under the name, where the name may be shown.
          return h('tr', h('td', String(m.alias || '—')),
            h('td.name', m.anonymous && !m.cid ? h('span.anon', icon('mask'), ' ', String(m.name || 'Anonymous'))
              : String(m.name || '—'),
              (m.anonymous && !canIdentify()) || m.id == null ? null
                : h('div.party', partyButton('op', String(m.id)))),
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

  /* ---- a contract's deadline, moved by staff ----

     The exact run time left (players see only its band), and Extend and
     Shorten by a quick pick or a number of minutes, with a reason, each on
     a two-click confirm. The server holds both to its limits and answers
     with the time left before and after. */

  var DEADLINE_PICKS = [15, 30, 60, 120];

  /** Run time as staff read it, to the second: '1 h 05 min', '25 min 10 s'. */
  function exactSpan(seconds) {
    var t = Math.max(0, Math.floor(Number(seconds) || 0));
    var hours = Math.floor(t / 3600), mins = Math.floor((t % 3600) / 60), secs = t % 60;
    var out = [];
    if (hours > 0) out.push(hours + ' h');
    if (mins > 0 || (hours > 0 && secs > 0)) out.push((hours > 0 ? pad(mins) : String(mins)) + ' min');
    if (secs > 0 || !out.length) out.push(secs + ' s');
    return out.join(' ');
  }

  /** The run time left now: as read, less what has passed since while the
      clock runs. */
  function deadlineLeft(info) {
    var left = Number(info.left) || 0;
    if (!info.stopped && S.drawer.readAt) left -= Math.max(0, nowSeconds() - S.drawer.readAt);
    return Math.max(0, left);
  }

  function deadlineMinutes() {
    return wholeNumber(S.forms['dr.dl.min']);
  }

  /** What Extend and Shorten would leave, for the minutes chosen. */
  function deadlinePreview() {
    var info = (S.drawer.data || {}).deadline || {};
    var left = deadlineLeft(info);
    var minutes = deadlineMinutes();
    if (!minutes) return h('span', 'Pick a time or type a number of minutes to see the time left after.');
    var by = minutes * 60;
    var max = Number(info.maxAdjust) || 0;
    if (max && by > max) return h('span.is-warn', 'At most ' + exactSpan(max) + ' either way.');
    var most = Math.max(0, left - (Number(info.minLeft) || 0));
    return frag(h('span', 'Extend: ', h('b', exactSpan(left + by)), ' left after.'), ' ',
      by > most
        ? h('span', 'Shorten: not by this much; at least ' + exactSpan(info.minLeft) + ' must remain, so the most is '
          + exactSpan(most) + '.')
        : h('span', 'Shorten: ', h('b', exactSpan(left - by)), ' left after.'));
  }

  function deadlineBody(info) {
    if (!info) return h('p.note', 'Not sent by this server.');
    var left = deadlineLeft(info);
    var now = h('p', 'Time left now: ', h('b', { id: 'dr-dl-left' }, exactSpan(left)),
      info.stopped ? ' (its clock is stopped)' : '');
    if (!info.adjustable) {
      return frag(now, h('p.note', 'Only a live contract (active or accepted) has a deadline to move.'));
    }
    var open = modOpen();
    var current = deadlineMinutes();
    return frag(now,
      h('div.inline-form.is-wide.dl-picks',
        segmented('dl-pick', DEADLINE_PICKS.map(function (m) {
          return { value: m, label: m < 60 ? m + ' min' : (m / 60) + ' h', disabled: !open,
                   title: open ? null : whyNoMod() };
        }), current == null ? '' : current),
        field('dr.dl.min', { class: 'is-short', placeholder: 'Minutes', inputmode: 'numeric', maxlength: '5',
          'data-live': 'dl-preview', disabled: !open, 'aria-label': 'Minutes to move the deadline by' })),
      h('p.note', { id: 'dr-dl-preview', 'aria-live': 'polite' }, deadlinePreview()),
      h('div.inline-form.is-wide',
        field('dr.dl.reason', { class: 'is-grow', placeholder: 'Reason (required, kept in the log)',
          maxlength: '120', disabled: !open, 'aria-label': 'Reason for moving the deadline' }),
        modBtn('', 'dl-extend', {}, 'Extend', 'Click again to extend', 'plus'),
        modBtn('', 'dl-shorten', {}, 'Shorten', 'Click again to shorten', 'minus')));
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
        bareGoods(item) ? h('p.note.is-warn', num(bareGoods(item)) + ' of its goods were kept without their metadata, '
          + 'which was too big to keep. Refund or Pay gives them back without it: no serial, registration, '
          + 'attachments or what was inside.') : null,
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
          asList(item.items).length ? h('dd', asList(item.items).map(function (g) {
            return holds(g) + (g && g.metadata_omitted === true ? ' (without its metadata)' : '');
          }).join(', ')) : null,
          h('dt', 'Involved'), h('dd', asList(item.parties).length ? asList(item.parties).map(function (p) {
            return h('span.party', h('b', String(p.role)), ' ' + String(p.who || '—'));
          }) : '—'),
          isReport(item) ? h('dt', 'The report') : h('dt', 'What was known'),
          h('dd', isReport(item) ? reportPart(item) : (keyValues(item.known) || '—')),
          h('dt', 'The store now'), h('dd',
            now.contract ? 'contract ' + now.contract : 'contract unknown',
            now.buyout ? ' · buyout ' + now.buyout : '',
            lines ? ' · lines held ' + num(lines.held) + ', settled ' + num(lines.settled) + ', missing ' + num(lines.missing) : ''),
          item.resolution && !resolving ? h('dt', 'Resolved') : null,
          item.resolution && !resolving ? h('dd', detailText(item.resolution) + ' · by ' + String(item.resolved_by || '—')
            + ' · ' + when(item.resolved_at)) : null),
        open && canWrite() ? (resolving ? finishForm(item) : (dismissOnly(item) ? reportForm(item) : reviewForm(item))) : null,
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

  /* ---- alerts ---- */

  var LEVEL_LABEL = { always: 'Needs staff', problem: 'Setting' };

  function loadAlerts() {
    return ask('alerts', { state: S.alerts.state }, 'alerts').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) {
        S.alerts.error = words(reply);
        if (!S.alerts.data) drawAlerts(); else toast(S.alerts.error, 'error');
        return;
      }
      S.alerts.data = reply.data || {};
      S.alerts.error = null;
      drawAlerts();
    });
  }

  function drawAlerts() { if (S.section === 'alerts') setHtml(byId('al-list'), alertsBody()); }

  /** Where posting to Discord stands: whether a webhook is set (never what
      it is), the last post, and the last one given up. */
  function discordBody(d) {
    d = d || {};
    var where = d.webhook === 'alert' ? 'the alert webhook (crimson_hitman_alert_webhook)'
      : d.webhook === 'staff' ? 'the staff webhook (crimson_hitman_webhook), as no alert webhook is set'
      : null;
    var status;
    if (d.on === false) {
      status = h('p.about', 'Off: Post alerts to Discord is switched off under Features. Nothing is posted; '
        + 'every alert is still listed here.');
    } else if (!where) {
      status = h('p.about', 'No webhook is set, so nothing is posted. Set crimson_hitman_alert_webhook in '
        + 'server.cfg (set, never setr), or crimson_hitman_webhook for the staff channel.');
    } else {
      status = h('p.about', 'Posting to ' + where + ': one post every 10 seconds at most, ten alerts a post, '
        + 'with no identity in it.');
    }
    var fail = d.lastFail;
    var failNote = null;
    if (fail) {
      var why = Number(fail.status) > 0 ? 'HTTP ' + fail.status : 'no answer';
      var since = d.lastOkAt && Number(d.lastOkAt) > Number(fail.at);
      var lost = [];
      if (Number(fail.alerts) > 0) {
        lost.push(num(fail.alerts) + ' alert' + (Number(fail.alerts) === 1 ? '' : 's')
          + ' not posted, still listed here');
      }
      if (fail.test) lost.push('the test alert not posted');
      failNote = h('p.note' + (since ? '' : '.is-warn'), (since ? 'Earlier, a' : 'A') + ' post was given up after '
        + num(fail.tries) + ' tries (' + why + ') ' + ago(fail.at) + ': ' + lost.join(', and ') + '.'
        + (since ? ' Posts have gone through since.' : ''));
    }
    return frag(status,
      h('dl.facts',
        h('dt', 'Last post'), h('dd', d.lastOkAt ? when(d.lastOkAt) + ' (' + ago(d.lastOkAt) + ')' : 'none since the start'),
        h('dt', 'Posted since the start'), h('dd', num(d.posted) + ' alert' + (Number(d.posted) === 1 ? '' : 's')),
        h('dt', 'Waiting'), h('dd', num(d.waiting) + (d.posting ? ', and a post being tried again' : ''))),
      failNote,
      h('div.btn-row', writeBtn('', 'al-test', {}, 'Send a test alert', null, 'paper-plane', true)),
      answerBox(S.alerts.test));
  }

  function alertCard(a) {
    var id = String(a.id);
    var acked = !!a.acknowledged_at;
    var count = Number(a.count) || 1;
    return h('article.card.al' + (acked ? '' : '.is-open'), { id: 'al-' + id },
      h('header.card-head',
        h('span.chip' + (a.level === 'problem' ? '.is-panel' : '.is-warn'), LEVEL_LABEL[a.level] || String(a.level || '')),
        count > 1 ? h('span.chip', 'said ' + num(count) + ' times') : null,
        h('span.sub', ago(a.last_at))),
      h('p.al-text', String(a.text || '')),
      h('dl.facts',
        h('dt', count > 1 ? 'First said' : 'Said'), h('dd', when(a.first_at)),
        count > 1 ? h('dt', 'Last said') : null, count > 1 ? h('dd', when(a.last_at)) : null,
        a.contract ? h('dt', 'Contract') : null,
        a.contract ? h('dd', h('button.link.mono', { type: 'button', 'data-act': 'contract',
          'data-id': String(a.contract) }, String(a.contract))) : null,
        acked ? h('dt', 'Acknowledged') : null,
        acked ? h('dd', String(a.acknowledged_by || '—') + ' · ' + when(a.acknowledged_at)) : null),
      !acked && canWrite() ? h('div.btn-row', writeBtn('', 'al-ack', { 'data-id': id }, 'Acknowledge',
        'Click again to acknowledge', 'check', true)) : null,
      answerBox(S.alerts.answers[id]));
  }

  function alertsBody() {
    var d = S.alerts.data;
    if (!d) return S.alerts.error ? empty(S.alerts.error) : loading('Reading the alerts…');
    var rows = asList(d.rows);
    var open = S.alerts.state === 'open';
    var total = open ? Number(d.open) || 0 : Number(d.acknowledged) || 0;
    return frag(
      card('Discord', discordBody(d.discord)),
      h('div.toolbar',
        h('span.sub', num(d.open) + ' open · ' + num(d.acknowledged) + ' acknowledged'
          + (rows.length < total ? ' · the newest ' + num(rows.length) + ' shown' : '')),
        open && rows.length && canWrite()
          ? writeBtn('', 'al-ack-all', {}, 'Acknowledge all shown',
            'Click again: acknowledge ' + num(rows.length), 'check-double', true)
          : null),
      answerBox(S.alerts.all),
      rows.length ? rows.map(alertCard)
        : empty(open ? 'No open alerts.' : 'Nothing has been acknowledged yet.'));
  }

  SHELL.alerts = function () {
    return h('section.view',
      h('div.toolbar',
        segmented('al-state', [{ value: 'open', label: 'Open' }, { value: 'acknowledged', label: 'Acknowledged' }],
          S.alerts.state),
        btn('.is-ghost', 'al-refresh', {}, 'Refresh', 'rotate')),
      h('p.hint', 'Every line the server console prints whatever Debug says: money at risk or left for staff, '
        + 'a write that failed, a job that keeps failing, and each setting that needs attention. The same line '
        + 'again is counted on its alert. Kept across restarts until acknowledged; acknowledging is on the record.'),
      h('div.stack', { id: 'al-list' }, alertsBody()));
  };
  LOAD.alerts = function () { loadAlerts(); };

  /* ---- console ---- */

  var KIND_LABEL = { always: 'Always', problem: 'Problem', debug: 'Debug' };
  var CONSOLE_KINDS = [
    { value: '', label: 'All' }, { value: 'always', label: 'Always' },
    { value: 'problem', label: 'Problems' }, { value: 'debug', label: 'Debug' }
  ];

  /** What the server keeps of its console. One read at a time: a refresh
      asked for while one is out waits for that one's answer. */
  function loadConsole() {
    if (S.console.loading) return Promise.resolve();
    S.console.loading = true;
    return ask('console', {}, 'console').then(function (reply) {
      S.console.loading = false;
      if (!reply) return;
      if (!reply.ok) {
        S.console.error = words(reply);
        if (!S.console.data) drawConsole(); else toast(S.console.error, 'error');
        return;
      }
      var data = reply.data || {};
      S.console.error = null;
      S.console.readAt = nowSeconds();
      var at = byId('cs-at');
      if (at) at.textContent = consoleAt();
      // Drawn again only when a line changed: a redraw of the same lines
      // would undo a selection being made by hand.
      var sig = JSON.stringify([data.debug, data.count, data.problems, data.boot, data.bootLeft, data.recent]);
      if (sig === S.console.sig && S.console.data) return;
      S.console.sig = sig;
      S.console.data = data;
      drawConsole();
    });
  }

  function drawConsole() { if (S.section === 'console') setHtml(byId('cs-list'), consoleBody()); }

  function consoleAt() {
    return S.console.readAt ? 'Read at ' + clock(S.console.readAt) + ', again every ' + Math.round(refreshMs() / 1000)
      + ' s while open' : '';
  }

  /** Whether a line passes the kind and text filters. */
  function consoleWanted(kind, text) {
    if (S.console.kind && kind !== S.console.kind) return false;
    var q = trim(S.forms['cs.q']).toLowerCase();
    return !q || String(text).toLowerCase().indexOf(q) !== -1;
  }

  /** The lines the filters leave: the settings that need attention, what
      the start said in order, and what came after, newest first. */
  function consoleShown() {
    var d = S.console.data || {};
    return {
      problems: asList(d.problems).filter(function (text) { return consoleWanted('problem', text); }),
      boot: asList(d.boot).filter(function (line) { return consoleWanted(line.kind, line.text); }),
      recent: asList(d.recent).slice().reverse().filter(function (line) { return consoleWanted(line.kind, line.text); })
    };
  }

  /** The shown lines as plain text, in the order shown, for Copy. */
  function consoleText(shown) {
    var out = [];
    if (shown.problems.length) {
      out.push('Settings that need attention:');
      shown.problems.forEach(function (text) { out.push('[problem] ' + text); });
    }
    if (shown.boot.length) {
      out.push('What the last start said:');
      shown.boot.forEach(function (line) { out.push('[' + line.kind + '] ' + line.text); });
    }
    if (shown.recent.length) {
      out.push('Since the start, newest first:');
      shown.recent.forEach(function (line) {
        var times = Number(line.times) || 1;
        out.push(clock(line.at) + ' [' + line.kind + '] ' + line.text + (times > 1 ? ' (x' + times + ')' : ''));
      });
    }
    return out.join('\n');
  }

  function consoleLine(line, withTime) {
    var times = Number(line.times) || 1;
    return h('li.cs-line',
      withTime ? h('span.time', clock(line.at)) : null,
      h('span.chip' + (line.kind === 'always' ? '.is-warn' : line.kind === 'problem' ? '.is-panel' : ''),
        KIND_LABEL[line.kind] || String(line.kind || '')),
      times > 1 ? h('span.chip', 'said ' + num(times) + ' times') : null,
      h('span.cs-text', String(line.text || '')));
  }

  function consoleList(lines, withTime, none) {
    return lines.length ? h('ul.cs-lines', lines.map(function (line) { return consoleLine(line, withTime); }))
      : empty(none);
  }

  function consoleBody() {
    var d = S.console.data;
    if (!d) return S.console.error ? empty(S.console.error) : loading('Reading the console…');
    var shown = consoleShown();
    var kind = S.console.kind;
    var filtered = !!trim(S.forms['cs.q']);
    var parts = [h('p.note', d.debug
      ? 'Debug output is on (Config.Debug): the server console printed every line here as well.'
      : 'Debug output is off (Config.Debug): the server console printed only the lines marked Always, and one '
        + 'line for the settings that need attention. Every other line is kept here.')];
    if (!kind || kind === 'problem') {
      parts.push(card('Settings that need attention (' + num(d.count) + ')',
        consoleList(shown.problems.map(function (text) { return { text: text, kind: 'problem' }; }), false,
          filtered ? 'None matches.' : 'None.')));
    }
    if (kind !== 'problem') {
      var left = Number(d.bootLeft) || 0;
      parts.push(card('What the last start said', frag(
        consoleList(shown.boot, false, filtered || kind ? 'None matches.' : 'Nothing kept.'),
        left > 0 ? h('p.note', 'And ' + num(left) + ' more line' + (left === 1 ? '' : 's') + ' the start said, past the '
          + num(d.bootKept) + ' kept.') : null)));
      parts.push(card('Since the start, newest first', frag(
        h('p.note', 'The newest ' + num(d.recentKept) + ' debug lines and the newest ' + num(d.alwaysKept)
          + ' lines marked Always; the same line again is counted on it.'),
        consoleList(shown.recent, true, filtered || kind ? 'None matches.' : 'Nothing since the start.'))));
    }
    return frag(parts);
  }

  /** Put text on the clipboard, from a box made for it and selected, with
      execCommand: it needs no clipboard permission. */
  function copyText(text) {
    var box = document.createElement('textarea');
    box.className = 'copy-buffer';
    box.value = text;
    box.setAttribute('readonly', 'readonly');
    box.setAttribute('aria-hidden', 'true');
    document.body.appendChild(box);
    var copied = false;
    try {
      box.select();
      copied = document.execCommand('copy') === true;
    } catch (err) {
      copied = false;
    }
    box.remove();
    return copied;
  }

  SHELL.console = function () {
    return h('section.view',
      h('div.toolbar',
        segmented('cs-kind', CONSOLE_KINDS, S.console.kind),
        h('label.search', icon('magnifying-glass'),
          field('cs.q', { id: 'cs-q', placeholder: 'Filter the lines', 'data-live': 'cs-filter',
            'aria-label': 'Filter the lines' })),
        btn('.is-ghost', 'cs-refresh', {}, 'Refresh', 'rotate'),
        btn('', 'cs-copy', {}, 'Copy', 'copy'),
        h('span.sub', { id: 'cs-at' }, consoleAt())),
      h('p.hint', 'What this resource said in the server console since its last start, and what it kept with Debug '
        + 'off: Always is printed whatever Debug says, Problems are the settings the start found wrong, and Debug is '
        + 'printed only with Debug on. Kept in memory, so a restart begins it again. Without the identity ACE, people '
        + 'are shown by their place on a contract; nobody here sees a webhook address, a secret, or the values a '
        + 'database statement was sent.'),
      h('div.stack', { id: 'cs-list' }, consoleBody()));
  };
  LOAD.console = function () { loadConsole(); };

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
    var typed = { contract: trim(S.forms['lg.contract']), actor: trim(S.forms['lg.actor']) };
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
        field('lg.actor', { id: 'lg-actor', class: 'is-mid', placeholder: 'Citizen id',
          'data-live': 'lg-search', 'data-enter': 'lg-search-now',
          title: canIdentify() ? null : 'Without the identity ACE, only the rows they acted in under their own '
            + 'name: as the target, or a client or operative who did not stay anonymous.',
          'aria-label': 'Citizen id' }),
        dropdown('lg-range'),
        rangeInputs('lg', S.logs.range, 'lg-search'),
        btn('.is-ghost', 'lg-clear', {}, 'Clear', 'eraser')),
      h('p.hint', canIdentify()
        ? 'Every row as it was written. Reading the log as you can see it is on the record.'
        : 'Citizen ids show as the party\'s place on the contract (the client, the target, an operative) and '
          + 'anonymous parties as Anonymous. A citizen id finds only the rows that player acted in under their '
          + 'own name.'),
      h('div.results', { id: 'lg-results' }, logRows()),
      h('div.pager', { id: 'lg-pager' }, logPager()));
  };
  LOAD.logs = function () { loadLogs(); };

  /* ---- players ---- */

  function loadPlayer() {
    var subject = trim(S.forms['pl.q']);
    if (!subject) { toast('Give a player id, a citizen id or a name.', 'error'); return Promise.resolve(); }
    S.players.whois = {};
    S.players.playtime = null;
    S.players.freeze = null;
    resetPlayerStaff();
    return ask('player', { subject: subject.slice(0, 64) }, 'player').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { toast(words(reply), 'error'); S.players.data = { error: words(reply) }; }
      else S.players.data = reply.data || {};
      // Set and Reset name the player as this lookup did, whatever is typed
      // in the box afterwards.
      S.players.subject = reply.ok ? subject.slice(0, 64) : null;
      if (S.section === 'players') setHtml(byId('pl-result'), playerBody());
      if (reply.ok) loadPlayerHistory();
    });
  }

  /** The hours the server counted for them, whether they were on the server
      before the count started, and Set or Reset. What the new-player rule
      reads for them is said where it is not these hours. */
  function playtimeCard(pt) {
    if (!pt) return null;
    var floor = Number(pt.floor) || 0;
    var hours = Number(pt.hours) || 0;
    var from = pt.grandfathered === true ? 'Yes' : pt.grandfathered === false ? 'No' : 'Not decided';
    var about;
    /* Grandfathered, and these hours against the floor, decide only where the
       tracker is what the rule reads: an export or QBox metadata answering
       for them decides by its own hours. */
    var elsewhere = pt.from === 'provider' || pt.from === 'metadata';
    if (pt.unread) about = 'Their counted time could not be read from the store just now.';
    else if (elsewhere) about = null;
    else if (pt.grandfathered === true) about = 'They were on the server before the count started, so they count as '
      + 'having played enough, whatever the hours say.';
    else if (pt.grandfathered === false) about = hours < floor
      ? 'Too new to be named as a target until the count reaches ' + num(floor) + ' h.'
      : 'Enough to be named as a target.';
    else if (!pt.counted) about = 'Nothing counted yet. Counting starts the next time they are in the city.';
    else about = 'Whether they were on the server before the count started is decided within a minute of them '
      + 'being in the city.';
    var rule = pt.from === 'provider' ? 'The new-player rule reads your playtime export for them, not these hours.'
      : pt.from === 'metadata' ? 'The new-player rule reads their QBox metadata for them, not these hours.' : null;
    return card('Playtime', frag(
      h('div.tiles.is-compact',
        tile('Counted here', h('p.big', pt.unread ? '—' : num(hours) + ' h')),
        tile('Needed to be a target', h('p.big', num(floor) + ' h')),
        tile('From before the count', h('p.big.is-word', from))),
      about ? h('p.sub', about) : null,
      rule ? h('p.note', rule) : null,
      h('div.toolbar',
        field('pl.hours', { id: 'pl-hours', type: 'number', min: '0', max: '100000', step: '0.5',
          placeholder: 'Hours', 'aria-label': 'Counted hours' }),
        writeBtn('', 'pl-playtime-set', {}, 'Set hours', 'Click again to set', 'clock', true),
        writeBtn('.is-ghost', 'pl-playtime-reset', {}, 'Reset to 0', 'Click again to reset', 'arrow-rotate-left', true)),
      answerBox(S.players.playtime)), '', h('span.sub', pt.counting ? 'in the city: counting' : 'not counting'));
  }

  /** Freeze or Unfreeze, under the lookup: a reason, and two clicks. While
      frozen, every live contract they are party to is on hold, paused and
      untouched, until they are unfrozen. */
  function freezeCard(frozen) {
    var form = h('div.toolbar',
      field('pl.freezeReason', { id: 'pl-freeze-reason', class: 'is-grow', maxlength: '120',
        placeholder: frozen ? 'Reason for unfreezing (kept in the log)' : 'Reason for the freeze (kept in the log)',
        'aria-label': frozen ? 'Reason for unfreezing' : 'Reason for the freeze' }),
      frozen
        ? modBtn('', 'pl-unfreeze', {}, 'Unfreeze', 'Click again to unfreeze', 'play')
        : modBtn('.is-danger', 'pl-freeze', {}, 'Freeze', 'Click again to freeze', 'snowflake'));
    var about = frozen
      ? frag(h('p.sub', 'Frozen ' + ago(frozen.since) + (frozen.reason ? ': ' + String(frozen.reason) : '')
          + (frozen.by ? ' · by ' + String(frozen.by) : '')),
        h('p.note', 'Every live contract they are party to is on hold: its clocks stopped, and nothing '
          + 'on it is accepted, paid, refunded or ended. Unfreeze gives the time on hold back.'))
      : h('p.note', 'Freezing puts every live contract they are party to on hold, as the target, the '
          + 'client or an operative: its clocks stop and nothing on it moves until you unfreeze them. '
          + 'Players are told only that it is on hold by staff.');
    return card('Freeze', frag(about, form, answerBox(S.players.freeze)), '',
      frozen ? h('span.chip.is-warn.is-frozen', 'Frozen') : null);
  }

  /** Every player staff have frozen, with Unfreeze on each row. */
  function frozenListCard() {
    var list = S.players.frozen;
    if (!list) return null;
    var rows = asList(list.rows);
    return card('Frozen players', rows.length ? h('div.table-wrap', h('table.grid',
      h('thead', h('tr', h('th', 'Player'), h('th', 'Since'), h('th', 'Reason'), h('th', ''))),
      h('tbody', rows.map(function (row) {
        return h('tr',
          h('td.name', String(row.name || 'No name on record'), row.cid ? h('span.cid', String(row.cid)) : null,
            h('span.chip.is-warn.is-frozen', 'Frozen')),
          h('td.nowrap', { title: when(row.since) }, ago(row.since)),
          h('td', String(row.reason || '—')),
          h('td', modBtn('.is-small', 'pl-unfreeze-row', { 'data-ref': String(row.ref) }, 'Unfreeze',
            'Click again to unfreeze', 'play')));
      })))) : empty('Nobody is frozen.'), '', h('span.sub', num(rows.length)));
  }

  function playerBody() {
    var d = S.players.data;
    if (!d) return empty('Look somebody up by their player id (in the city), their citizen id (anybody) '
      + 'or their name, as Contracts searches.');
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
        p.online ? h('span.chip.is-live', 'in the city · player ' + String(p.server)) : h('span.chip', 'offline'),
        d.frozen ? h('span.chip.is-warn.is-frozen', 'Frozen') : null),
      freezeCard(d.frozen),
      // Suspend, Protect, Pay and the history card (the block near the end).
      playerStaffCards(d),
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
      playtimeCard(d.playtime),
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
            h('td', stateChip(row.state), row.frozen ? h('span.chip.is-warn.is-frozen', 'Frozen') : null),
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
          field('pl.q', { id: 'pl-q', placeholder: 'Player id, citizen id or name', 'data-enter': 'pl-lookup',
            'aria-label': 'Player id, citizen id or name' })),
        btn('.is-primary', 'pl-lookup', {}, 'Look up', 'arrow-right')),
      h('p.hint', canIdentify()
        ? 'You see every contract they were party to, anonymous ones included. Each lookup is on the record.'
        : 'Contracts they placed or took anonymously are left out, with what they are owed, the deliveries '
          + 'and the notices on them, and so is their record, which counts them.'),
      h('div.stack', { id: 'pl-result' }, playerBody()),
      h('div.stack', { id: 'pl-frozen' }, frozenListCard()));
  };
  function loadFrozen() {
    return ask('frozen', {}, 'frozen').then(function (reply) {
      if (!reply || !reply.ok) return;
      S.players.frozen = reply.data || {};
      if (S.section === 'players' || S.section === 'frozen') setHtml(byId('pl-frozen'), frozenListCard());
    });
  }
  LOAD.players = function () { loadFrozen(); };

  /* ---- settings: Rules, Features and Developer ----

     One list from the server (Settings.view), every row with its category.
     Each settings view shows one category, in groups, with a search box;
     each row shows its value now, what config.lua says, and what
     defaults.lua ships, with Reset to default where that differs. One row
     renderer per kind: switch, choice, number, text, list, range, and the
     rate limits' per and burst as one map row. */

  /** Every row the server sent, whichever list it came in. */
  function allSettings() {
    var d = S.settings.data || {};
    return asList(d.features).concat(asList(d.limits), asList(d.readonly));
  }

  /** A row's category: as the server says, or, from a server before
      categories, from the list it came in. */
  function categoryOf(entry, list) {
    if (entry.category) return String(entry.category);
    if (list === 'readonly' || entry.readonly) return 'developer';
    if (list === 'features' && entry.kind === 'switch') return 'features';
    return 'rules-limits';
  }

  function settingList(view) {
    var d = S.settings.data || {};
    var out = [];
    ['features', 'limits', 'readonly'].forEach(function (list) {
      asList(d[list]).forEach(function (entry) {
        if (CATEGORY_VIEW[categoryOf(entry, list)] === view) out.push(entry);
      });
    });
    return out;
  }

  function settingEntry(key) {
    return allSettings().filter(function (e) { return e.key === key; })[0];
  }

  function describe(entry, value) {
    if (entry.kind === 'switch' || typeof value === 'boolean') return value === true ? 'On' : 'Off';
    if (entry.kind === 'list') {
      var list = asList(value);
      return list.length ? list.join(', ') : '(none)';
    }
    if (entry.kind === 'range') {
      return value && typeof value === 'object' ? num(value.min) + ' to ' + num(value.max) : '(not set)';
    }
    if (value === null || value === undefined) return '(not set)';
    if (typeof value === 'number') return num(value) + spanOf(entry, value);
    return String(value);
  }

  /** A duration setting's figure in hours and minutes too: '10800 s = 3 h',
      '90 min = 1 h 30 min'. Nothing for anything else, or under a minute. */
  function spanOf(entry, value) {
    var key = String((entry && entry.key) || '');
    var seconds = /Seconds$/.test(key) ? value : /Minutes$/.test(key) ? value * 60 : null;
    if (seconds === null || !(seconds >= 60) || seconds !== Math.floor(seconds)) return '';
    var unit = /Seconds$/.test(key) ? ' s' : ' min';
    var d = Math.floor(seconds / 86400), hr = Math.floor((seconds % 86400) / 3600);
    var mi = Math.floor((seconds % 3600) / 60), se = seconds % 60;
    var parts = [];
    if (d) parts.push(d + ' d');
    if (hr) parts.push(hr + ' h');
    if (mi) parts.push(mi + ' min');
    if (se) parts.push(se + ' s');
    if (parts.length === 1 && unit === ' min' && mi && !hr && !d) return '';
    return unit + ' = ' + parts.join(' ');
  }

  /** Two values the same, as the panel shows them (lists, pairs). */
  function sameValue(a, b) {
    return JSON.stringify(normalised(a)) === JSON.stringify(normalised(b));
  }
  function normalised(v) {
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      var keys = Object.keys(v);
      // A list arrives as an object keyed 1..n across the wire.
      if (keys.length && keys.every(function (k) { return /^\d+$/.test(k); })) return asList(v);
      var out = {};
      keys.sort().forEach(function (k) { out[k] = normalised(v[k]); });
      return out;
    }
    return v;
  }

  /* The fixed parts of every Features and Limits row (label, help, limits,
     defaults), as the server last sent them whole, and the hash it named
     them by: sent once, and after that only each row's key and what
     changes, which are put back together here. The reply was 172 KB at
     every open of the section and after every change. */
  var SCHEMA_FIELDS = ['group', 'label', 'about', 'category', 'money', 'shipped', 'hasShipped',
    'kind', 'choices', 'min', 'integer', 'live', 'inflight', 'readonly', 'destroys', 'stricter',
    'strict', 'whole', 'default'];
  var settingsSchema = null; // { hash, rows: { [key]: fixed parts } }

  function keepSchema(data) {
    if (!data || typeof data.schema !== 'string') { settingsSchema = null; return; }
    var rows = {};
    ['features', 'limits'].forEach(function (list) {
      asList(data[list]).forEach(function (row) {
        var fixed = {};
        SCHEMA_FIELDS.forEach(function (f) { if (row[f] !== undefined) fixed[f] = row[f]; });
        rows[row.key] = fixed;
      });
    });
    settingsSchema = { hash: data.schema, rows: rows };
  }

  /* A lean reply with its fixed parts put back, or null when this page does
     not hold the ones it names (then it is asked for whole). */
  function withSchema(data) {
    if (!settingsSchema || settingsSchema.hash !== data.schema) return null;
    var out = {};
    Object.keys(data).forEach(function (k) { out[k] = data[k]; });
    delete out.lean;
    var whole = true;
    ['features', 'limits'].forEach(function (list) {
      out[list] = asList(data[list]).map(function (row) {
        var fixed = settingsSchema.rows[row.key];
        if (!fixed) { whole = false; return row; }
        var merged = {};
        Object.keys(fixed).forEach(function (f) { merged[f] = fixed[f]; });
        Object.keys(row).forEach(function (f) { merged[f] = row[f]; });
        return merged;
      });
    });
    return whole ? out : null;
  }

  function loadSettings(whole) {
    var asked = (!whole && settingsSchema) ? { schema: settingsSchema.hash } : {};
    return ask('settings', asked, 'settings').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { toast(words(reply), 'error'); return; }
      var data = reply.data || {};
      if (data.lean) {
        data = withSchema(data);
        if (!data) { settingsSchema = null; return loadSettings(true); }
      } else {
        keepSchema(data);
      }
      S.settings.data = data;
      if (SETTING_VIEWS[S.section]) drawSettings();
    });
  }

  function drawSettings() {
    setHtml(byId('st-head'), settingsHead());
    setHtml(byId('st-list'), settingsList());
    filterSettings();
    // Where a help link pointed: that row, marked and brought into view.
    var focus = S.settings.focus && byId('st-row-' + S.settings.focus);
    if (focus) {
      focus.classList.toggle('is-focus', true);
      if (typeof focus.scrollIntoView === 'function') focus.scrollIntoView({ block: 'center' });
      S.settings.focus = null;
    }
  }

  /** What a row's box holds now: what was typed, else the value. */
  function typedOr(bind, value) {
    var typed = S.forms[bind];
    return typed === undefined ? value : typed;
  }

  /** A list being edited: the names added and removed since it was read. */
  function listDraft(entry) {
    var draft = S.settings.drafts[entry.key];
    return draft ? draft.slice() : asList(entry.value).map(String);
  }

  function settingControl(entry) {
    var key = entry.key;
    if (entry.readonly) return h('span.st-value', entry.secret ? String(entry.value) : describe(entry, entry.value));
    var open = settingOpen(entry);
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
    if (entry.kind === 'list') {
      var names = listDraft(entry);
      var changed = !sameValue(names, asList(entry.value).map(String));
      return h('div.st-list',
        h('ul.st-chips', names.length ? names.map(function (name) {
          return h('li.st-chip', h('span', name),
            h('button.st-chip-x', { type: 'button', 'data-act': 'st-list-del', 'data-key': key, 'data-value': name,
              disabled: !open, title: 'Remove ' + name, 'aria-label': 'Remove ' + name }, icon('xmark'),
              h('span.lbl', 'Remove')));
        }) : h('li.st-none', '(none)')),
        h('div.st-edit',
          field('stl.' + key, { class: 'is-grow', placeholder: entry.whole ? 'Add a line' : 'Add a name',
            'data-enter': 'st-list-add',
            'data-key': key, disabled: !open, 'aria-label': 'Add to ' + entry.label }),
          btn('.is-small', 'st-list-add', { 'data-key': key, disabled: !open || null }, 'Add', 'plus'),
          writeBtn('.is-small' + (changed ? '.is-primary' : ''), 'st-list-save',
            { 'data-key': key, id: 'st-save-' + key }, 'Save list', 'Click again to save', 'check', false, open)));
    }
    if (entry.kind === 'range') {
      var pair = entry.value && typeof entry.value === 'object' ? entry.value : {};
      return h('div.st-edit',
        field('st.' + key + '.min', { value: String(typedOr('st.' + key + '.min', pair.min)), class: 'is-short',
          inputmode: 'decimal', disabled: !open, 'aria-label': entry.label + ': from' }),
        h('span.range-sep', 'to'),
        field('st.' + key + '.max', { value: String(typedOr('st.' + key + '.max', pair.max)), class: 'is-short',
          inputmode: 'decimal', disabled: !open, 'aria-label': entry.label + ': to' }),
        writeBtn('.is-small', 'st-range-save', { 'data-key': key, id: 'st-save-' + key }, 'Save',
          'Click again to save', 'check', false, open),
        h('span.st-range', num(entry.min) + ' to ' + num(entry.max) + (entry.integer ? ', whole' : '')));
    }
    var bind = 'st.' + key;
    var shownValue = String(entry.value == null ? '' : entry.value);
    var range = entry.kind === 'number'
      ? (entry.min != null ? entry.min : '…') + ' to ' + (entry.max != null ? entry.max : '…') + (entry.integer ? ', whole' : '')
      : 'letters, digits, - and _';
    return h('div.st-edit',
      field(bind, { value: shownValue, class: entry.kind === 'text' ? 'is-grow' : 'is-short',
        inputmode: entry.kind === 'number' ? 'decimal' : null, 'data-enter': 'st-save', 'data-key': key,
        disabled: !open, 'aria-label': entry.label }),
      writeBtn('.is-small', 'st-save', { 'data-key': key, id: 'st-save-' + key }, 'Save',
        entry.destroys || entry.stricter ? 'Click again to save' : null, 'check', false, open),
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
    var hasShipped = entry.hasShipped === true || (entry.hasShipped === undefined && entry.shipped !== undefined);
    var offDefault = !entry.readonly && hasShipped && !sameValue(entry.value, entry.shipped);
    return frag(
      h('div.st-main',
        h('p.st-title', h('b', String(entry.label || key)),
          overridden ? h('span.chip.is-panel', 'changed from the panel') : null,
          entry.live === false ? h('span.chip.is-warn.is-restart', 'applies after restart') : null,
          entry.ignored ? h('span.chip.is-error', 'not applied') : null,
          entry.inactive ? h('span.chip.is-warn', 'does not apply now') : null,
          entry.denied ? h('span.chip', 'edit in config.lua') : null),
        h('code.st-key', entry.secret ? 'server.cfg' : 'Config.' + key),
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
        entry.readonly ? null : h('p.st-source', 'Now: ' + describe(entry, entry.value)
          + ' · config.lua: ' + describe(entry, entry.default)
          + (hasShipped ? ' · default: ' + describe(entry, entry.shipped) : '')
          + (overridden ? ' · in force from the panel' + (entry.by ? ', set by ' + entry.by : '')
            + (entry.at ? ' ' + ago(entry.at) : '') : ' · in force from config.lua')),
        entry.ignored ? h('p.st-about.is-error', 'The store holds a value that was not applied at start: '
          + String(entry.ignored) + '. config.lua\'s is in force; reset it to clear this.') : null,
        entry.unknown ? h('p.st-about.is-error', 'A change to it raised in the store, and so did reading it '
          + 'back (' + String(entry.unknown) + '): the store may or may not hold it. What is shown is in '
          + 'force; set or reset it again to settle it.') : null,
        answerBox(answer),
        key === 'Completion.KillPhotos' ? keptPhotosPart(entry) : null),
      // A read-only key too, when the store holds a value for it that was
      // not applied (kept from a version where it could be changed): the
      // reset takes that row away, and nothing in force moves.
      h('div.st-control', settingControl(entry),
        entry.ignored || entry.unknown || (overridden && !entry.readonly)
          ? writeBtn('.is-small.is-ghost', 'st-reset', { 'data-key': key }, 'Reset to config.lua',
            'Click again to reset', 'arrow-rotate-left', false, settingOpen(entry)) : null,
        offDefault ? writeBtn('.is-small.is-ghost', 'st-default', { 'data-key': key }, 'Reset to default',
          'Click again: back to ' + describe(entry, entry.shipped), 'rotate-left', false,
          settingOpen(entry)) : null));
  }

  /** Under Kill photos, while they are off and some are kept from before
      they were: the button that removes them all, and what removing does to
      each kind. Its answer stays once the button has gone. */
  function keptPhotosPart(entry) {
    var kept = (S.settings.data || {}).keptPhotos;
    var answer = S.settings.photos;
    var n = kept ? Number(kept.count) || 0 : 0;
    if (entry.value === true || n < 1) return answer ? answerBox(answer) : null;
    var photos = n === 1 ? 'kill photo' : 'kill photos';
    var files = Number(kept.files) || 0, links = Number(kept.links) || 0;
    var open = Math.max(Number(kept.open) || 0, Number(kept.waiting) || 0);
    var facts = [];
    if (files) facts.push(num(files) + ' with a file on this server: the file is deleted.');
    if (links) {
      facts.push(num(links) + ' on lb-phone\'s image host: removing only forgets the link here, and the picture '
        + 'stays on the host.');
    }
    if (open) {
      facts.push(num(open) + ' open on a phone right now: each is removed when that view closes, never while it '
        + 'is shown.');
    }
    return h('div.st-kept',
      h('p.st-about', num(n) + ' ' + photos + ' kept from before kill photos were turned off (records, whatever '
        + 'became of each photo). Removing deletes every one, and is on the record.'),
      facts.length ? h('ul.st-kept-facts', facts.map(function (text) { return h('li', text); })) : null,
      h('div.btn-row', writeBtn('.is-danger.is-small', 'st-remove-photos', {},
        'Remove the ' + num(n) + ' ' + photos + ' kept from before',
        'Click again: remove ' + num(n) + ' ' + photos + ' for good', 'trash-can', true)),
      answerBox(answer));
  }

  function settingRow(entry) {
    return h('div.st-row' + (entry.source === 'panel' ? '.is-panel' : '') + (entry.ignored ? '.is-ignored' : ''),
      { id: 'st-row-' + entry.key, 'data-key': entry.key,
        'data-find': [entry.key, entry.label, entry.about, entry.group, entry.money].map(function (v) {
          return v == null ? '' : String(v);
        }).join(' ').toLowerCase() },
      settingInner(entry));
  }

  function drawSettingRow(key) {
    var entry = settingEntry(key);
    var row = byId('st-row-' + key);
    if (entry && row) setHtml(row, settingInner(entry));
    var pair = /^Cooldowns\.([\w]+)\.(per|burst)$/.exec(key);
    if (pair) {
      var map = byId('st-map-' + pair[1]);
      if (map) setHtml(map, mapInner(pair[1]));
    }
  }

  /** What each settings view says at its head. */
  var VIEW_INTRO = {
    timers: 'How long things last: deadlines, cooldowns, waits and the restart pause. The deadline runs only '
      + 'while the placer, the target and one operative are all in the city.',
    money: 'Every reward and money setting in one place: what a reward may hold, payouts, buyouts, the '
      + 'informant prices, the anonymity fees and escrow. Lowering a cap never cancels anything: it only '
      + 'refuses new ones over it.',
    limits: 'How many contracts a player may place, take or carry, how one is completed and the other '
      + 'limits. Each value is checked the way the server checks config.lua at start.',
    targeting: 'Who may open the app, who can be targeted, and the whitelisted-job rules.',
    features: 'The on and off switches. Every switch takes effect at once and is kept across restarts. What is '
      + 'already under way finishes under the rules it started with; only new actions are refused, and players '
      + 'are told the feature is turned off by the server.',
    devsettings: 'Debug, storage, rate limits, timings and the values only config.lua changes. Rate limits are '
      + 'not caps: a stricter one refuses players at once, so it takes two clicks and says what it refuses.'
  };

  /** Rewards & money, in these groups (the catalogue's `money`). */
  var MONEY_ORDER = ['Rewards', 'Payouts', 'Buyouts', 'Informant prices', 'Anonymity fees', 'Escrow'];
  /** Features, these groups first, each with what it controls. */
  var FEATURE_ORDER = ['Anonymity', 'Anonymity (whitelisted-job targets)', 'Informant', 'Informant tip',
    'Informants (whitelisted-job targets)', 'Law enforcement advisory'];
  var GROUP_INTRO = {
    'Anonymity': 'Whether a contract may be placed or accepted anonymously, and whether a target sees an '
      + 'operative\'s name.',
    'Anonymity (whitelisted-job targets)': 'The same, in place of the above, where the target is on a whitelisted job.',
    'Informant': 'The paid look-ups: the target\'s (who is after me) and the placer\'s (who took it), and their '
      + 'master switch.',
    'Informant tip': 'The hitman\'s paid tip on the target\'s rough area, and whether the target is told.',
    'Informants (whitelisted-job targets)': 'Whether each informant feature is offered on a whitelisted-job target.',
    'Law enforcement advisory': 'What officers are told when one of them, or another whitelisted-job member, is '
      + 'targeted, and when.',
    'Access': 'Who may open the app: barred jobs off duty, and the whitelisted-job view.',
    'The app': 'Where the app appears on the phone.',
    'Rewards': 'What a reward may be paid in.',
    'Completion': 'How a kill is checked and kept.',
    'Handovers': 'What a live handover asks of the target.',
    'Stakes': 'The stake a hitman is shown before accepting.',
    'Buyouts': 'Whether a target may buy a contract out.',
    'Targeting': 'How a placer finds a target, and headshots on the board.',
    'Messages and calls': 'The anonymous messages and calls between the parties.',
    'Proposals': 'Changes placer and hitman may agree to a contract.',
    'Notifications': 'Phone notices players get.',
    'The clock': 'When a contract\'s deadline stops.',
    'Anti-collusion': 'One account as two parties to a contract.',
    'Progression': 'Criminal trust for completed contracts.',
    'Audit and debug': 'What the log keeps, and alerts to Discord.',
    'Staff tools': 'Pausing the whole app for an event, and the daily summary to the staff Discord.',
    'Staff alerts': 'When one player or one target goes past a threshold, one staff alert, and on Discord too.'
  };

  function settingsHead() {
    var d = S.settings.data;
    var overrides = d ? Number(d.overrides) || 0 : 0;
    return frag(
      h('label.search', icon('magnifying-glass'),
        field('st.q', { id: 'st-q', placeholder: 'Search by name, key, description or group', 'data-live': 'st-filter',
          'aria-label': 'Search the settings' })),
      h('span.sub', num(overrides) + ' changed from the panel'
        + (d && Number(d.notApplied) > 0 ? ', ' + num(d.notApplied) + ' kept and not applied' : '')),
      // Whenever the store holds a row, applied or not: one not applied (a
      // key from another version among them) is cleared by it too.
      overrides > 0 || (d && Number(d.stored) > 0) ? writeBtn('.is-danger.is-small', 'st-reset-all', {},
        'Reset all to config.lua', 'Click again to reset all', 'arrow-rotate-left') : null);
  }

  /** The rate limits' two rows per bucket, as one row with both. */
  function mapInner(bucket) {
    var per = settingEntry('Cooldowns.' + bucket + '.per');
    var burst = settingEntry('Cooldowns.' + bucket + '.burst');
    if (!per || !burst) return frag();
    var open = settingOpen(per) && settingOpen(burst);
    var answer = S.settings.answers['Cooldowns.' + bucket];
    return frag(
      h('div.st-main',
        h('p.st-title', h('b', bucket),
          per.source === 'panel' || burst.source === 'panel' ? h('span.chip.is-panel', 'changed from the panel') : null),
        h('code.st-key', 'Config.Cooldowns.' + bucket + ' = { per, burst }'),
        per.about ? h('p.st-about', String(per.about).replace(/ A full allowance refills.*$/, '')) : null,
        h('p.st-about.is-warn', 'Making it stricter refuses players at once, so saving takes two clicks.'),
        h('p.st-source', 'Now: refills over ' + num(per.value) + ' s, ' + num(burst.value) + ' held · config.lua: '
          + num(per.default) + ' s, ' + num(burst.default)),
        answerBox(answer)),
      h('div.st-control', h('div.st-edit',
        h('label.st-pair', h('span', 'per (s)'),
          field('st.Cooldowns.' + bucket + '.per', { value: String(typedOr('st.Cooldowns.' + bucket + '.per', per.value)),
            class: 'is-short', inputmode: 'decimal', disabled: !open, 'aria-label': bucket + ': refill window' })),
        h('label.st-pair', h('span', 'burst'),
          field('st.Cooldowns.' + bucket + '.burst', { value: String(typedOr('st.Cooldowns.' + bucket + '.burst', burst.value)),
            class: 'is-short', inputmode: 'numeric', disabled: !open, 'aria-label': bucket + ': requests held' })),
        writeBtn('.is-small', 'st-map-save', { 'data-bucket': bucket, id: 'st-save-Cooldowns.' + bucket }, 'Save',
          'Click again to save', 'check', false, open))));
  }

  /** The buckets whose two rows are both editable here. */
  function mapBuckets(list) {
    var seen = {}, out = [];
    list.forEach(function (e) {
      var m = /^Cooldowns\.([\w]+)\.(per|burst)$/.exec(e.key);
      if (m && !e.readonly && !seen[m[1]]) { seen[m[1]] = true; out.push(m[1]); }
    });
    return out.filter(function (b) {
      var per = settingEntry('Cooldowns.' + b + '.per'), burst = settingEntry('Cooldowns.' + b + '.burst');
      return per && burst && !per.readonly && !burst.readonly;
    });
  }

  function settingsList() {
    var d = S.settings.data;
    if (!d) return loading('Reading the settings…');
    var view = S.section;
    var list = settingList(view);
    var buckets = view === 'devsettings' ? mapBuckets(list) : [];
    var inMap = {};
    buckets.forEach(function (b) { inMap['Cooldowns.' + b + '.per'] = inMap['Cooldowns.' + b + '.burst'] = true; });
    var groups = [], byGroup = {};
    list.forEach(function (entry) {
      if (inMap[entry.key]) return;
      var g = String((view === 'money' && entry.money) || entry.group || 'Other');
      if (!byGroup[g]) { byGroup[g] = []; groups.push(g); }
      byGroup[g].push(entry);
    });
    var order = view === 'money' ? MONEY_ORDER : view === 'features' ? FEATURE_ORDER : [];
    groups.sort(function (a, b) {
      var x = order.indexOf(a), y = order.indexOf(b);
      if (x === -1 && y === -1) return 0;
      if (x === -1) return 1;
      if (y === -1) return -1;
      return x - y;
    });
    // In memory mode nothing is kept across a restart: the settings no more
    // than the contracts.
    var memory = S.overview && S.overview.storage === 'memory';
    var intro = memory && view === 'features'
      ? 'Every switch here takes effect at once, and lasts until the resource stops: this server runs in '
        + 'memory mode, which keeps nothing across a restart. What is already under way finishes under the '
        + 'rules it started with; only new actions are refused, and players are told the feature is turned '
        + 'off by the server.'
      : VIEW_INTRO[view] + (memory ? ' This server runs in memory mode, which keeps nothing across a restart: '
        + 'a change lasts until the resource stops.' : '');
    var note = view === 'devsettings' && S.access.developerHint ? h('p.hint.is-note', String(S.access.developerHint)) : null;
    if (!groups.length && !buckets.length) return frag(h('p.hint', intro), note, empty('Nothing here.'));
    return frag(h('p.hint', intro), note, groups.map(function (g) {
      return h('section.st-group', { 'data-group': g.toLowerCase() }, h('h3.st-group-title', g),
        view === 'features' && GROUP_INTRO[g] ? h('p.st-group-about', GROUP_INTRO[g]) : null,
        byGroup[g].map(settingRow));
    }), buckets.length ? h('section.st-group', { 'data-group': 'rate limits' }, h('h3.st-group-title', 'Rate limits'),
      h('p.st-group-about', 'Per player: a full allowance of burst requests refills over per seconds.'),
      buckets.map(function (b) {
        var per = settingEntry('Cooldowns.' + b + '.per');
        return h('div.st-row.st-map', { id: 'st-map-' + b, 'data-key': 'Cooldowns.' + b,
          'data-find': ('cooldowns.' + b + ' ' + b + ' rate limits ' + String(per.about || '')).toLowerCase() },
          mapInner(b));
      })) : null, h('p.empty', { id: 'st-none', hidden: true }, 'No setting matches.'));
  }

  /** Hide what the search box does not match: rows, then groups left empty. */
  function filterSettings() {
    var q = trim(S.forms['st.q']).toLowerCase();
    var list = byId('st-list');
    if (!list) return;
    var shown = 0;
    var rows = list.querySelectorAll('.st-row');
    rows.forEach(function (row) {
      var hit = !q || String(row.getAttribute('data-find') || '').indexOf(q) !== -1;
      row.hidden = !hit;
      if (hit) shown++;
    });
    list.querySelectorAll('.st-group').forEach(function (group) {
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
    if (entry.kind === 'text') {
      var word = trim(text);
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(word)) {
        return { error: 'Not changed: ' + entry.key + ' is letters, digits, - and _ only.' };
      }
      return { value: word };
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
        delete S.forms['st.' + key + '.min'];
        delete S.forms['st.' + key + '.max'];
        delete S.settings.drafts[key];
        // Read again, so who changed it and when are the server's.
        loadSettings();
      } else {
        drawSettingRow(key);
      }
    });
  }

  function settingsShell() {
    return h('section.view',
      h('div.toolbar', { id: 'st-head' }, settingsHead()),
      h('div.stack', { id: 'st-list' }, settingsList()));
  }
  Object.keys(SETTING_VIEWS).forEach(function (view) {
    SHELL[view] = settingsShell;
    LOAD[view] = function () { loadSettings(); };
  });

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

  function drawTools() {
    if (S.section === 'tools') setHtml(byId('tl'), toolsBody());
    if (S.section === 'diagnostics') setHtml(byId('dg'), diagnosticsBody());
  }

  /* ---- frozen players: the list from Players, as its own sub-tab ---- */

  SHELL.frozen = function () {
    return h('section.view',
      h('p.hint', 'Every player staff have frozen. Freeze somebody from Players, after looking them up.'),
      h('div.stack', { id: 'pl-frozen' }, frozenListCard() || loading('Reading who is frozen…')));
  };
  LOAD.frozen = function () { loadFrozen(); };

  /* ---- staff actions: every write the panel has, in one place ----

     Each card opens the flow that already does it, in the view it lives
     in; nothing here writes on its own. */

  var STAFF_ACTIONS = [
    { title: 'Freeze or unfreeze a player', icon: 'snowflake', view: 'players', go: 'Open Players',
      text: 'Look the player up, then Freeze puts every live contract they are party to on hold: its clocks stop '
        + 'and nothing on it moves. Unfreeze gives the time back. Every frozen player is listed under Frozen '
        + 'players, each with its own Unfreeze.', also: { view: 'frozen', go: 'Frozen players' } },
    { title: 'Void a contract', icon: 'ban', view: 'contracts', go: 'Open Contracts',
      text: 'Open the contract from Contracts, then Void contract closes it and refunds what it holds, with a '
        + 'reason kept in the log.' },
    { title: 'Refund or pay', icon: 'scale-balanced', view: 'reviews', go: 'Open Needs review',
      text: 'Needs review holds the contracts a player asked staff to look at: Refund, Pay or Dismiss each. '
        + 'Stuck escrow holds the money left for staff: Pay, Pay amount, Return or Delivered.',
      also: { view: 'stuck', go: 'Stuck escrow' } },
    { title: 'Deadlines', icon: 'clock', view: 'contracts', go: 'Open Contracts',
      text: 'Open the contract from Contracts, then Extend or Shorten under Deadline moves it: 15 min, 30 min, '
        + '1 h, 2 h or a number of minutes, with a reason kept in the log. It shows the exact time left before '
        + 'and after; players are told only that staff changed its time. Freezing a player stops its clock, and '
        + 'voiding ends it.' },
    { title: 'Announce', icon: 'bullhorn', view: 'announce', go: 'Open Announce',
      text: 'One phone notice from Staff to every hitman holding a contract, or to everybody online with the app. '
        + 'It never names you, takes two clicks and is on the record.' },
    { title: 'Tools', icon: 'screwdriver-wrench', view: 'tools', go: 'Open Tools',
      text: 'Bring timers forward (test servers only), Flush the audit log, and Run the diagnosis for why the app '
        + 'is not showing something.' },
    { title: 'Settings', icon: 'sliders', view: 'timers', go: 'Open Rules',
      text: 'Every setting is changed in Rules or Features, each Save, reset or list edit taking the same '
        + 'confirms as before.', also: { view: 'features', go: 'Features' } },
    { title: 'Contract tools', icon: 'clipboard-list', view: 'contracts', go: 'Open Contracts',
      text: 'Open a contract: Staff notes, Remove an operative (stake to the client as a walk-away, or returned; '
        + 'optionally barred), Edit text through the checks a player\'s text gets, Export the record for a '
        + 'ticket, and As a player sees it.' }
  ];

  SHELL.actions = function () {
    return h('section.view',
      h('p.hint', canWrite() ? 'Everything here changes something, and takes two clicks where it moves money or '
        + 'cannot be undone. Each opens the place it is done.' : whyNoWrite()),
      h('div.cards-grid', STAFF_ACTIONS.map(function (a) {
        return card(frag(icon(a.icon), ' ', a.title), frag(
          h('p.about', a.text),
          h('div.btn-row', btn('.is-small', 'section', { 'data-section': a.view }, a.go, 'arrow-right'),
            a.also ? btn('.is-small.is-ghost', 'section', { 'data-section': a.also.view }, a.also.go, 'arrow-right')
              : null)));
      })));
  };
  LOAD.actions = function () {};

  /* ---- diagnostics: the slow jobs, and the diagnosis ---- */

  function diagnosticsBody() {
    var o = S.overview || {};
    var slowest = asList(o.slowest);
    var t = S.tools;
    return frag(
      S.access.developerHint ? h('p.hint.is-note', String(S.access.developerHint)) : null,
      card('Slow-job timings', slowest.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Job'), h('th.num', 'Slowest'), h('th.num', 'Average'), h('th.num', 'Last'),
          h('th.num', 'Runs'))),
        h('tbody', slowest.map(function (job) {
          return h('tr', h('td', String(job.name)), h('td.num', ms(job.max)), h('td.num', ms(job.avg)),
            h('td.num', ms(job.last)), h('td.num', num(job.runs)));
        })))) : empty('No timings yet: the overview reads them.'), '',
        o.slowMs != null ? h('span.sub', 'warns above ' + num(o.slowMs) + ' ms') : null),
      card('Diagnosis', frag(
        h('p.about', 'Why the app is not showing something, the server-wide checks, the settings that need '
          + 'attention, and what the console said. Name a player id to run the app\'s own reads as them.'),
        h('div.btn-row', field('tl.subject', { class: 'is-short', placeholder: 'Player id', inputmode: 'numeric',
          'data-enter': 'tl-diag', 'aria-label': 'Player id (optional)' }),
          btn('.is-primary', 'tl-diag', {}, 'Run the diagnosis', 'stethoscope')),
        t.diag && t.diag.error ? answerBox({ ok: false, text: t.diag.error }) : null,
        t.diag ? linesBox(t.diag.lines, t.diag.later) : null)));
  }
  SHELL.diagnostics = function () { return h('section.view', h('div.stack', { id: 'dg' }, diagnosticsBody())); };
  LOAD.diagnostics = function () { loadOverview(false).then(drawTools); };

  /* ---- permissions: every ACE this resource checks, read-only ---- */

  function permissionsBody() {
    var rows = asList(S.access.permissions);
    if (!rows.length) return empty('The server did not say which ACEs it checks.');
    return frag(
      h('p.hint', 'Every ACE this resource checks, what it opens, and whether you hold it. Nothing here changes '
        + 'an ACE: grant one in the server console or server.cfg.'),
      canDevelop() || !S.access.developerAce ? null : h('p.hint.is-note', 'The Developer section needs '
        + String(S.access.developerAce) + ', or the staff ACE itself.'),
      h('div.stack', rows.map(function (p) {
        var held = p.held === true;
        return h('section.card.perm-row', { 'data-ace': String(p.ace) },
          h('header.card-head', h('h3', String(p.name || p.ace)),
            h('span.chip' + (held ? '.is-ok' : ''), { class: held ? 'perm-held' : 'perm-missing' },
              held ? 'You hold it' : 'You do not hold it')),
          h('code.st-key', String(p.ace)),
          h('p.about', String(p.unlocks || '')),
          held ? null : h('p.perm-grant', h('b', 'To grant it: '), String(p.grant || '')));
      })));
  }
  SHELL.permissions = function () { return h('section.view', h('div.stack', { id: 'pm' }, permissionsBody())); };
  LOAD.permissions = function () {};

  /* ---- how it works ----

     Plain words on what the resource does, written from the code and the
     README; each card links to the settings that control it. Edit the text
     here: it is the one place it is kept. */

  var HELP = [
    { title: 'A contract, start to finish', icon: 'file-contract',
      text: 'A player places a contract on a target from the app, naming a reward; the reward is taken from them '
        + 'at once and held in escrow, so nothing is promised that is not there. A hitman accepts it from the '
        + 'board. As shipped a contract is completed only by a live handover: the hitman brings the target, '
        + 'alive, to the person who placed it, and the three stay close together for the countdown. Under '
        + '\'either\' a verified kill completes it too. The escrow then pays the hitman, as many times as the '
        + 'contract has payout slots.',
      links: [{ key: 'Completion.Fulfilment', view: 'limits', label: 'How contracts are completed' },
        { key: 'Kidnap.CountdownSeconds', view: 'timers', label: 'Handover countdown' },
        { key: 'Limits.MaxPayoutSlots', view: 'money', label: 'Payout slots' },
        { key: 'Limits.MinContractReward', view: 'money', label: 'Least reward' }] },
    { title: 'The clock and the time bands', icon: 'clock',
      text: 'A contract runs for its deadline, three hours as shipped, but the clock counts down only while the '
        + 'placer, the target and at least one operative holding it are all in the city. Players never see the '
        + 'exact time: each card shows a rough band, More than 2 hours, 1 to 2 hours, Under 1 hour or Under '
        + '15 minutes left. Every contract also pauses for the half hour before a txAdmin restart, and while '
        + 'the target is in prison. A hard ceiling ends any contract after two days, pauses included.',
      links: [{ key: 'Limits.DefaultDeadlineSeconds', view: 'timers', label: 'Deadline' },
        { key: 'Limits.ContractLifetimeSeconds', view: 'timers', label: 'Hard ceiling' },
        { key: 'Restart.PauseBeforeSeconds', view: 'timers', label: 'Restart pause' },
        { key: 'Limits.PauseWhileTargetJailed', view: 'features', label: 'Pause while jailed' }] },
    { title: 'Anonymity', icon: 'mask',
      text: 'A contract can be placed or accepted anonymously only if the server allows it, and as shipped it '
        + 'does not. When it is allowed, the placer or operative shows as Anonymous everywhere a player looks, '
        + 'and only staff with the identity ACE see who it is. A fee can be charged for it. Contracts on a '
        + 'whitelisted-job target (police, EMS and the like) follow their own three switches instead.',
      links: [{ key: 'Anonymity.AllowAnonymousPlacer', view: 'features', label: 'Anonymous placing' },
        { key: 'Anonymity.AllowAnonymousHitman', view: 'features', label: 'Anonymous accepting' },
        { key: 'Anonymity.WhitelistedTargets.AllowAnonymousPlacer', view: 'features',
          label: 'On whitelisted-job targets' },
        { key: 'Anonymity.CreatorFee', view: 'money', label: 'Anonymity fees' }] },
    { title: 'The informants', icon: 'user-secret',
      text: 'Three paid look-ups, each off as shipped. The target\'s informant lets a target pay to find out who '
        + 'is after them, with a chance of an answer. The placer\'s informant lets the placer find out which '
        + 'operative took the contract. The informant tip lets a hitman buy the target\'s rough area on the map. '
        + 'One master switch turns all three off at once, and each has its own switch for whitelisted-job targets.',
      links: [{ key: 'InformantsEnabled', view: 'features', label: 'Master switch' },
        { key: 'Informant.Enabled', view: 'features', label: 'Target\'s informant' },
        { key: 'PlacerInformant.Enabled', view: 'features', label: 'Placer\'s informant' },
        { key: 'LocationTip.Enabled', view: 'features', label: 'Informant tip' },
        { key: 'Informant.Cost', view: 'money', label: 'Prices' }] },
    { title: 'Buyouts', icon: 'hand-holding-dollar',
      text: 'A target can pay to buy out a contract on them, from the app or with the buyout command. The price '
        + 'is the reward times a multiplier, between a least and a most, and never above a cap. A contract a '
        + 'hitman holds gives them a head start before the buyout closes it. A dead or downed target cannot '
        + 'buy out.',
      links: [{ key: 'Bailout.Enabled', view: 'features', label: 'Buyouts on or off' },
        { key: 'Bailout.MinMultiplier', view: 'money', label: 'Buyout price' },
        { key: 'Bailout.ProcessingDelaySeconds', view: 'money', label: 'Hitman\'s head start' }] },
    { title: 'The staff freeze', icon: 'snowflake',
      text: 'Staff with the staff or moderator ACE can freeze a player for a staff situation or a dispute, from Players. '
        + 'Every live contract they are party to goes on hold: its clocks stop, and nothing on it is accepted, '
        + 'paid, refunded or ended. Players are told only that it is on hold by staff. Unfreeze gives the time '
        + 'on hold back, to the second.',
      links: [] },
    { title: 'Police advisories', icon: 'shield-halved',
      text: 'When a contract is placed on an officer or another whitelisted-job member, officers are told by an '
        + 'advisory, and an sc-dispatch entry if that is on. Bulletins can go out when a contract is placed, '
        + 'accepted, given an informant tip or called off. The placer and the hitman are warned first, and the '
        + 'card is marked on the board. Which jobs raise one, and which are told, are lists under Targeting.',
      links: [{ key: 'Advisory.Enabled', view: 'features', label: 'Advisories on or off' },
        { key: 'Advisory.OnCreate', view: 'features', label: 'When they go out' },
        { key: 'Advisory.RecipientJobNames', view: 'targeting', label: 'Who is told' }] },
    { title: 'Money safety', icon: 'vault',
      text: 'Every reward is held in escrow from the moment a contract is placed until it ends, so it can always '
        + 'be paid or returned. A contract that ends without a payout refunds its placer. A payout to a player '
        + 'who is offline, or whose inventory is full, is owed to them and paid when they next log in. Anything '
        + 'the server could not settle on its own is left for staff under Stuck escrow, and a disputed contract '
        + 'goes to Needs review.',
      links: [{ key: 'PendingEscrow.MaxRetriesPerLogin', view: 'money', label: 'Owed payouts' },
        { key: 'MaxContractValue', view: 'money', label: 'Most a contract holds' },
        { key: 'EscrowBlacklist', view: 'money', label: 'Items never in a reward' }] }
  ];
  /** For the tests. */
  window.CH_ADMIN_HELP = HELP;

  SHELL.help = function () {
    return h('section.view', h('p.hint', 'How the contract app works, in plain words. Each link opens the setting '
      + 'that controls it.'),
      h('div.cards-grid', HELP.map(function (c, i) {
        return card(frag(icon(c.icon), ' ', c.title), frag(
          h('p.about', c.text),
          c.links.length ? h('div.help-links', c.links.map(function (l) {
            return h('button.link', { type: 'button', 'data-act': 'help-jump', 'data-key': l.key,
              'data-view': l.view }, l.label);
          })) : null), '.help-card', null);
      })));
  };
  LOAD.help = function () {};


  /* ---------- what a click, a key or typing does ----------------------- */

  var ACTIONS = {};
  var LIVE = {};

  ACTIONS.close = function () { close(); };
  ACTIONS.section = function (node) { show(node.getAttribute('data-section')); };
  /** Look up / Freeze in the contract view: Players, on that party. */
  ACTIONS['party-lookup'] = function (node) {
    var subject = node.getAttribute('data-subject');
    if (!subject) return;
    S.forms['pl.q'] = subject;
    show('players');
    loadPlayer();
  };
  ACTIONS.group = function (node) { openGroup(node.getAttribute('data-group')); };
  /** A help link: the setting's view, the search cleared, and its row marked. */
  ACTIONS['help-jump'] = function (node) {
    var key = node.getAttribute('data-key');
    S.forms['st.q'] = '';
    S.settings.focus = key;
    show(node.getAttribute('data-view'));
  };
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
    show(canDevelop() ? 'diagnostics' : 'tools');
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

  ACTIONS['dl-pick'] = function (node) {
    disarm();
    S.forms['dr.dl.min'] = node.getAttribute('data-value') || '';
    drawDrawer();
  };

  LIVE['dl-preview'] = function () {
    setHtml(byId('dr-dl-preview'), deadlinePreview());
  };

  /** Extend (+1) or Shorten (-1) by the minutes chosen, with the reason. */
  function adjustDeadline(sign, node) {
    var id = S.drawer.id;
    var info = (S.drawer.data || {}).deadline || {};
    if (!id) return;
    var minutes = deadlineMinutes();
    var reason = trim(S.forms['dr.dl.reason']).slice(0, 120);
    var problem = null;
    if (!minutes) problem = 'Pick a time or type a whole number of minutes.';
    else if (Number(info.maxAdjust) && minutes * 60 > Number(info.maxAdjust)) {
      problem = 'At most ' + exactSpan(info.maxAdjust) + ' either way.';
    } else if (!reason) problem = 'Give a reason: it goes on the record.';
    if (problem) {
      disarm();
      S.drawer.answer = { ok: false, text: problem };
      drawDrawer();
      return;
    }
    if (!confirmed(node)) {
      // Another number typed is not what the armed click named.
      if (S.armed) S.armed.bind = 'dr.dl.min';
      return;
    }
    write('adjustDeadline', { id: id, seconds: sign * minutes * 60, reason: reason }, 'deadline:' + id, node)
      .then(function (reply) {
        if (!reply || S.drawer.id !== id) return;
        drawerAnswer(reply);
        if (reply.ok) {
          S.forms['dr.dl.min'] = '';
          S.forms['dr.dl.reason'] = '';
          if (S.section === 'contracts') loadContracts();
        }
        drawDrawer();
        loadContract();
      });
  }

  ACTIONS['dl-extend'] = function (node) { adjustDeadline(1, node); };
  ACTIONS['dl-shorten'] = function (node) { adjustDeadline(-1, node); };

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
    var action = dismissOnly(item) ? 'dismiss' : (S.reviews.action[id] || 'refund');
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

  ACTIONS['al-state'] = function (node) {
    S.alerts.state = node.getAttribute('data-value') === 'acknowledged' ? 'acknowledged' : 'open';
    S.alerts.data = null;
    S.alerts.answers = {};
    S.alerts.all = null;
    show('alerts');
  };
  ACTIONS['al-refresh'] = function () { loadAlerts(); };
  ACTIONS['al-ack'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!confirmed(node)) return;
    write('ackAlerts', { ids: [id] }, 'ack:' + id, node).then(function (reply) {
      if (!reply) return;
      toast(words(reply), reply.ok ? 'ok' : 'error');
      // A refusal stays beside the alert; one acknowledged leaves the list.
      if (reply.ok) delete S.alerts.answers[id];
      else S.alerts.answers[id] = { ok: false, text: words(reply) };
      drawAlerts();
      loadAlerts();
    });
  };
  ACTIONS['al-ack-all'] = function (node) {
    var ids = asList((S.alerts.data || {}).rows).filter(function (a) { return !a.acknowledged_at; })
      .map(function (a) { return String(a.id); });
    if (!ids.length || !confirmed(node)) return;
    write('ackAlerts', { ids: ids }, 'ack-all', node).then(function (reply) {
      if (!reply) return;
      toast(words(reply), reply.ok ? 'ok' : 'error');
      S.alerts.all = reply.ok ? null : { ok: false, text: words(reply) };
      drawAlerts();
      loadAlerts();
    });
  };
  ACTIONS['al-test'] = function (node) {
    write('testAlert', {}, 'alert-test', node).then(function (reply) {
      if (!reply) return;
      toast(words(reply), reply.ok ? 'ok' : 'error');
      S.alerts.test = { ok: reply.ok === true, text: words(reply) };
      drawAlerts();
    });
  };

  ACTIONS['cs-kind'] = function (node) {
    S.console.kind = node.getAttribute('data-value') || '';
    if (!KIND_LABEL[S.console.kind]) S.console.kind = '';
    redraw();
  };
  ACTIONS['cs-refresh'] = function () { loadConsole(); };
  LIVE['cs-filter'] = function () { drawConsole(); };
  ACTIONS['cs-copy'] = function () {
    if (!S.console.data) return;
    var shown = consoleShown();
    var n = shown.problems.length + shown.boot.length + shown.recent.length;
    if (!n) { toast('Nothing is shown to copy.', 'info'); return; }
    if (copyText(consoleText(shown))) toast('Copied ' + num(n) + ' line' + (n === 1 ? '' : 's') + '.', 'ok');
    else toast('This game would not copy it: select the lines and press Ctrl+C instead.', 'error');
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

  /** Set one character's counted hours, two clicks, naming them as the
      lookup did. The card shows what the server answered. */
  function setPlaytime(node, hours) {
    if (!S.players.subject || !confirmed(node)) return;
    write('setPlaytime', { subject: S.players.subject, hours: hours }, 'playtime', node).then(function (reply) {
      if (!reply) return;
      S.players.playtime = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok && reply.data && reply.data.playtime && S.players.data) {
        S.players.data.playtime = reply.data.playtime;
        delete S.forms['pl.hours'];
      }
      if (S.section === 'players') setHtml(byId('pl-result'), playerBody());
    });
  }
  ACTIONS['pl-playtime-set'] = function (node) {
    var raw = trim(S.forms['pl.hours']);
    var hours = Number(raw);
    if (raw === '' || !isFinite(hours) || hours < 0 || hours > 100000) {
      disarm();
      S.players.playtime = { ok: false, text: 'Hours are a number from 0 to 100000.' };
      if (S.section === 'players') setHtml(byId('pl-result'), playerBody());
      return;
    }
    setPlaytime(node, hours);
  };
  ACTIONS['pl-playtime-reset'] = function (node) { setPlaytime(node, 0); };

  /** Freeze or unfreeze the player looked up, two clicks, with the reason. */
  function freezeWrite(op, data, node) {
    var sent = op === 'freeze' ? write('freeze', data, 'freeze', node) : write('unfreeze', data, 'freeze', node);
    sent.then(function (reply) {
      if (!reply) return;
      S.players.freeze = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) {
        delete S.forms['pl.freezeReason'];
        if (S.players.data && !S.players.data.error && data.subject === S.players.subject) {
          S.players.data.frozen = op === 'freeze' ? (reply.data && reply.data.frozen) || { since: nowSeconds() } : null;
        }
        loadFrozen();
      }
      if (S.section === 'players') setHtml(byId('pl-result'), playerBody());
    });
  }
  ACTIONS['pl-freeze'] = function (node) {
    if (!S.players.subject) return;
    var reason = trim(S.forms['pl.freezeReason']);
    if (!reason) {
      disarm();
      S.players.freeze = { ok: false, text: 'Give a reason: it goes on the record.' };
      if (S.section === 'players') setHtml(byId('pl-result'), playerBody());
      return;
    }
    if (!confirmed(node)) return;
    freezeWrite('freeze', { subject: S.players.subject, reason: reason.slice(0, 120) }, node);
  };
  ACTIONS['pl-unfreeze'] = function (node) {
    if (!S.players.subject || !confirmed(node)) return;
    freezeWrite('unfreeze', { subject: S.players.subject,
      reason: trim(S.forms['pl.freezeReason']).slice(0, 120) }, node);
  };
  ACTIONS['pl-unfreeze-row'] = function (node) {
    var ref = node.getAttribute('data-ref');
    if (!ref || !confirmed(node)) return;
    write('unfreeze', { ref: ref }, 'freeze', node).then(function (reply) {
      if (!reply) return;
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok && S.players.data && S.players.data.frozen) loadPlayer();
      loadFrozen();
    });
  };

  /** A list's name typed into its box, added to what is being edited. */
  ACTIONS['st-list-add'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    if (!entry || entry.readonly) return;
    var typed = trim(S.forms['stl.' + key]);
    if (!typed) return;
    var names = listDraft(entry);
    // A list of phrases, templates, areas or places (`whole`) takes the line
    // as typed: one entry, spaces and commas kept.
    (entry.whole ? [typed] : typed.split(/[\s,]+/)).forEach(function (name) {
      if (name && names.indexOf(name) === -1) names.push(name);
    });
    S.settings.drafts[key] = names;
    S.forms['stl.' + key] = '';
    disarm();
    drawSettingRow(key);
  };
  ACTIONS['st-list-del'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    if (!entry || entry.readonly) return;
    var gone = node.getAttribute('data-value');
    S.settings.drafts[key] = listDraft(entry).filter(function (name) { return name !== gone; });
    disarm();
    drawSettingRow(key);
  };
  /** The list as edited, saved on the second click; the server checks every name. */
  ACTIONS['st-list-save'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    if (!entry || entry.readonly || !confirmed(node)) return;
    setSetting(key, listDraft(entry), node);
  };
  ACTIONS['st-range-save'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    if (!entry || entry.readonly) return;
    var pair = entry.value && typeof entry.value === 'object' ? entry.value : {};
    var lo = Number(trim(typedOr('st.' + key + '.min', pair.min)));
    var hi = Number(trim(typedOr('st.' + key + '.max', pair.max)));
    var bad = !isFinite(lo) || !isFinite(hi) ? 'has to be two numbers'
      : (entry.integer && (Math.floor(lo) !== lo || Math.floor(hi) !== hi)) ? 'has to be whole numbers'
      : lo > hi ? 'has its from above its to'
      : ((entry.min != null && lo < entry.min) || (entry.max != null && hi > entry.max))
        ? 'has to be within ' + entry.min + ' to ' + entry.max : null;
    if (bad) {
      disarm();
      S.settings.answers[key] = { ok: false, text: 'Not changed: ' + key + ' ' + bad + '.' };
      drawSettingRow(key);
      return;
    }
    if (!confirmed(node)) return;
    setSetting(key, { min: lo, max: hi }, node);
  };
  /** A bucket's per and burst, each sent as the setting it is, one after the
      other: the second only once the first is in force. */
  ACTIONS['st-map-save'] = function (node) {
    var bucket = node.getAttribute('data-bucket');
    var keys = ['Cooldowns.' + bucket + '.per', 'Cooldowns.' + bucket + '.burst'];
    var changes = [];
    for (var i = 0; i < keys.length; i++) {
      var entry = settingEntry(keys[i]);
      if (!entry || entry.readonly) return;
      var parsed = parseSetting(entry, String(typedOr('st.' + keys[i], entry.value)));
      if (parsed.error) {
        disarm();
        S.settings.answers['Cooldowns.' + bucket] = { ok: false, text: parsed.error };
        drawSettingRow(keys[i]);
        return;
      }
      if (parsed.value !== entry.value) changes.push({ key: keys[i], value: parsed.value });
    }
    if (!changes.length) {
      S.settings.answers['Cooldowns.' + bucket] = { ok: true, text: bucket + ' is as typed already; nothing changed.' };
      drawSettingRow(keys[0]);
      return;
    }
    if (!confirmed(node)) return;
    var said = [];
    (function next(i) {
      if (i >= changes.length) {
        S.settings.answers['Cooldowns.' + bucket] = { ok: true, text: said.join(' ') };
        loadSettings();
        return;
      }
      write('setSetting', { key: changes[i].key, value: changes[i].value }, 'set:' + changes[i].key, node)
        .then(function (reply) {
          if (!reply) return;
          said.push(words(reply));
          toast(words(reply), reply.ok ? 'ok' : 'error');
          if (!reply.ok) {
            S.settings.answers['Cooldowns.' + bucket] = { ok: false, text: said.join(' ') };
            loadSettings();
            return;
          }
          delete S.forms['st.' + changes[i].key];
          next(i + 1);
        });
    })(0);
  };
  /** Back to what defaults.lua ships, through the same change as any other. */
  ACTIONS['st-default'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    if (!entry || entry.readonly || !confirmed(node)) return;
    var value = entry.kind === 'list' ? asList(entry.shipped) : entry.shipped;
    setSetting(key, value, node);
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
    if (!entry || entry.readonly || !settingOpen(entry)) return;
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
  ACTIONS['st-remove-photos'] = function (node) {
    if (!confirmed(node)) return;
    write('removePhotos', {}, 'remove-photos', node).then(function (reply) {
      if (!reply) return;
      S.settings.photos = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      loadSettings();
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

  /* ---------- staff tools ----------------------------------------------

     Staff actions > Announce: one phone notice, from 'Staff', to every
     hitman holding a contract or to everybody online with the app.
     Developer > Settings history: every setting change with who, when and
     both values, each with Undo (the server keeps the value it puts back).
     And the players' reports in Needs review: the role, the note and the
     thread's last messages, dismissed like any item. */

  var ANNOUNCE_MAX = 200;
  var ST = {
    announce: { scope: 'active', answer: null },
    history: { data: null, error: null, answer: null, cursor: null, back: [] }
  };

  /** Characters, as the server counts them (code points, not UTF-16 units). */
  function charCount(text) { return Array.from(String(text || '')).length; }

  function announceCount() {
    var n = charCount(S.forms['an.text']);
    if (n > ANNOUNCE_MAX) return h('span.is-warn', n + ' / ' + ANNOUNCE_MAX + ' characters: too long to send.');
    return h('span', n + ' / ' + ANNOUNCE_MAX + ' characters');
  }

  function announceBody() {
    var a = ST.announce;
    var open = writesOpen();
    return card(frag(icon('bullhorn'), ' Announce to every hitman'), frag(
      h('p.about', 'One phone notice, the same words to everybody. Players see it from Staff, never from you. '
        + 'At most ' + ANNOUNCE_MAX + ' characters, and no links, invites or handles. It is on the record with '
        + 'who sent it, to whom, how many it reached and what it said.'),
      segmented('an-scope', [
        { value: 'active', label: 'Hitmen on a contract', disabled: !open, title: open ? null : whyNoWrite() },
        { value: 'online', label: 'Everyone online', disabled: !open, title: open ? null : whyNoWrite() }
      ], a.scope),
      h('div.inline-form.is-wide',
        field('an.text', { id: 'an-text', class: 'is-grow', placeholder: 'The notice',
          maxlength: String(ANNOUNCE_MAX * 2), 'data-live': 'an-count', disabled: !open,
          'aria-label': 'The notice to send' }),
        writeBtn('.is-primary', 'an-send', {}, 'Send', 'Click again to send', 'paper-plane')),
      h('p.note', { id: 'an-count', 'aria-live': 'polite' }, announceCount()),
      answerBox(a.answer)));
  }

  function drawAnnounce() { if (S.section === 'announce') setHtml(byId('an'), announceBody()); }

  SHELL.announce = function () {
    return h('section.view', h('div.stack', { id: 'an' }, announceBody()));
  };
  LOAD.announce = function () {};

  LIVE['an-count'] = function () { setHtml(byId('an-count'), announceCount()); };

  ACTIONS['an-scope'] = function (node) {
    disarm();
    ST.announce.scope = node.getAttribute('data-value') === 'online' ? 'online' : 'active';
    drawAnnounce();
  };

  ACTIONS['an-send'] = function (node) {
    var text = trim(S.forms['an.text']);
    var problem = null;
    if (!text) problem = 'Write the notice first.';
    else if (charCount(text) > ANNOUNCE_MAX) problem = 'At most ' + ANNOUNCE_MAX + ' characters.';
    if (problem) {
      disarm();
      ST.announce.answer = { ok: false, text: problem };
      drawAnnounce();
      return;
    }
    if (!confirmed(node)) {
      // Another word typed is not what the armed click named.
      if (S.armed) S.armed.bind = 'an.text';
      return;
    }
    write('announce', { text: text, scope: ST.announce.scope }, 'announce', node).then(function (reply) {
      if (!reply) return;
      ST.announce.answer = { ok: reply.ok === true, text: words(reply) };
      if (reply.ok) S.forms['an.text'] = '';
      toast(words(reply), reply.ok ? 'ok' : 'error');
      drawAnnounce();
    });
  };

  /* ---- Developer > Settings history ---- */

  /** A value as the history shows it; a secret never. */
  function historyValue(value, secret) {
    if (secret) return h('span.sub', '(hidden)');
    if (value === null || value === undefined) return h('span.sub', '—');
    if (typeof value === 'boolean') return value ? 'on' : 'off';
    if (Array.isArray(value)) return value.map(String).join(', ') || '(none)';
    if (typeof value === 'object') return JSON.stringify(value);
    return String(value);
  }

  function loadHistory() {
    var hs = ST.history;
    return ask('settingsHistory', hs.cursor != null ? { cursor: hs.cursor } : {}, 'history').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) hs.error = words(reply);
      else { hs.error = null; hs.data = reply.data || {}; }
      drawHistory();
    });
  }

  function drawHistory() { if (S.section === 'history') setHtml(byId('hs'), historyBody()); }

  function historyBody() {
    var hs = ST.history;
    if (hs.error && !hs.data) return answerBox({ ok: false, text: hs.error });
    if (!hs.data) return loading('Reading the settings history…');
    var rows = asList(hs.data.rows);
    var hidden = Number(hs.data.hidden) || 0;
    return frag(
      answerBox(hs.answer),
      rows.length ? h('div.table-wrap', h('table.grid.is-history',
        h('thead', h('tr', h('th', 'When'), h('th', 'Setting'), h('th', 'Before'), h('th', 'After'),
          h('th', 'Who'), h('th', ''))),
        h('tbody', rows.map(function (r) {
          return h('tr', { 'data-key': String(r.key || '') },
            h('td.nowrap', { title: when(r.ts) }, ago(r.ts)),
            h('td.wrap', h('b', String(r.label || r.key || '—')), h('div.mono.sub', String(r.key || '')),
              r.reset ? h('span.chip', 'back to config.lua') : null),
            h('td.wrap', historyValue(r.old, r.secret)),
            h('td.wrap', historyValue(r['new'], r.secret)),
            h('td.wrap', String(r.by || '—')),
            h('td.nowrap', r.ref ? writeBtn('.is-small', 'hs-undo', { 'data-ref': String(r.ref) }, 'Undo',
              'Click again to undo', 'arrow-rotate-left') : null));
        })))) : empty('No setting has been changed from the panel within the log\'s retention.'),
      hidden ? h('p.note', hidden + ' change(s) to the Developer section\'s own settings are left out: they are '
        + 'for staff who may open it.') : null,
      h('div.btn-row',
        hs.back.length ? btn('.is-small.is-ghost', 'hs-newer', {}, 'Newer', 'arrow-left') : null,
        hs.data.next != null ? btn('.is-small.is-ghost', 'hs-older', {}, 'Older', 'arrow-right') : null));
  }

  SHELL.history = function () {
    return h('section.view',
      h('div.toolbar', btn('.is-ghost', 'hs-refresh', {}, 'Refresh', 'rotate')),
      h('p.hint', 'Every setting changed from the panel, newest first: when, the value before and after, and who. '
        + 'Undo puts the value before that change back, checked as any change is; it takes two clicks and is on '
        + 'the record. A secret is never shown.'),
      h('div.stack', { id: 'hs' }, historyBody()));
  };
  LOAD.history = function () {
    ST.history = { data: null, error: null, answer: null, cursor: null, back: [] };
    loadHistory();
  };

  ACTIONS['hs-refresh'] = function () { ST.history.answer = null; loadHistory(); };
  ACTIONS['hs-older'] = function () {
    var hs = ST.history;
    if (!hs.data || hs.data.next == null) return;
    hs.back.push(hs.cursor);
    hs.cursor = hs.data.next;
    loadHistory();
  };
  ACTIONS['hs-newer'] = function () {
    var hs = ST.history;
    if (!hs.back.length) return;
    hs.cursor = hs.back.pop();
    loadHistory();
  };
  ACTIONS['hs-undo'] = function (node) {
    var ref = node.getAttribute('data-ref');
    if (!ref || !confirmed(node)) return;
    write('undoSetting', { ref: ref }, 'undo:' + ref, node).then(function (reply) {
      if (!reply) return;
      ST.history.answer = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      // The settings pages read afresh when next opened.
      if (reply.ok) S.settings.data = null;
      loadHistory();
    });
  };

  /* ---- a player's report, in Needs review ---- */

  var REPORT_ROLE = { placer: 'the placer', target: 'the target', hitman: 'a hitman on it',
                      viewer: 'a player who saw it on the board' };

  function isReport(item) { return !!item && item.kind === 'player_report'; }
  /** An item with no money in it, only ever dismissed with a note: a report,
      or a low-effort reason (Config.Roleplay.ReasonQuality). */
  function dismissOnly(item) { return isReport(item) || (!!item && item.kind === 'low_effort_reason'); }

  /** What a report says: who sent it (as their role), their note, and the
      thread's last messages, by alias. */
  function reportPart(item) {
    var known = item.known || {};
    var excerpt = asList(known.excerpt);
    return h('div.report',
      h('p', 'Sent by ', h('b', REPORT_ROLE[known.role] || String(known.role || 'a player')),
        known.note ? frag(': ', h('q', String(known.note))) : ', with no note.'),
      excerpt.length ? h('ol.excerpt', excerpt.map(function (m) {
        return h('li', h('span.mono.sub', clock(m.at)), ' ', h('b', String(m.alias || '?')), ': ',
          h('span.wrap', String(m.body || '')));
      })) : h('p.note', known.thread ? 'The thread was empty.' : 'No thread was sent with it.'));
  }

  /** A report moves no money: Dismiss, with what was done, is all it takes. */
  function reportForm(item) {
    var id = String(item.id);
    return h('div.rv-form',
      h('div.inline-form.is-wide',
        field('rv.' + id + '.note', { class: 'is-grow', placeholder: 'What was done (a note is required)',
          maxlength: '200', 'aria-label': 'Note' }),
        writeBtn('', 'resolve', { 'data-id': id, 'data-report': 'yes' }, 'Dismiss it', 'Click again to dismiss',
          'xmark')));
  }

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

  /* ---------- a player's staff tools: suspend, protect, pay, history -------

     Under a player's lookup in Players. Suspend and Protect are the
     moderator's (the staff ACE, or Config.Admin.ModeratorAce), as Freeze and
     Void are; Pay is the staff ACE's alone. Each takes a reason and the
     two-click confirm. Lift, which only gives back what a suspension or a
     protection took, is one click. The history card only reads. */

  /** The moderator's ops: the staff ACE, or the moderator ACE. */
  function canModerate() { return S.access.canModerate === true || canWrite(); }
  function modOpen() { return canModerate() && S.recovery === 'ready'; }
  function whyNoMod() {
    if (!canModerate()) {
      return 'Read only: this needs the staff ACE (Config.Admin.Ace) or the moderator ACE '
        + '(Config.Admin.ModeratorAce); the extra ACEs only read.';
    }
    if (S.recovery === 'recovering') return 'Still recovering from the restart: try again in a moment.';
    if (S.recovery === 'recovery_failed') {
      return 'Recovery failed at the last start: restart the resource once the cause in the console is fixed.';
    }
    return '';
  }
  /** A button for one of the moderator's ops: open to them as to the staff ACE. */
  function modBtn(cls, act, attrs, label, confirmLabel, iconName) {
    var open = modOpen();
    var a = attrs || {};
    if (!open) a.title = whyNoMod();
    return writeBtn(cls, act, a, label, confirmLabel, iconName, false, open);
  }

  var SUSPEND_DAYS = [1, 3, 7, 30];
  var PROTECT_UNITS = [{ value: 'h', label: 'Hours' }, { value: 'd', label: 'Days' },
                       { value: 'forever', label: 'Permanent' }];

  function resetPlayerStaff() {
    S.pstaff = { suspend: null, protect: null, pay: null, history: null, historyError: null,
                 unit: 'h', account: 'cash' };
    ['ps.days', 'ps.reason', 'pp.amount', 'pp.reason', 'pay.amount', 'pay.reason'].forEach(function (k) {
      delete S.forms[k];
    });
  }
  resetPlayerStaff();

  function drawPlayer() {
    if (S.section === 'players') setHtml(byId('pl-result'), playerBody());
  }

  /** Until when, in words: a date, or until lifted. */
  function untilWords(row, forever) {
    return row && row['until'] ? 'until ' + when(row['until']) + ' (' + ago(row['until']) + ')' : forever;
  }

  function suspendCard(d) {
    var row = d.suspended;
    var body;
    if (row) {
      body = frag(
        h('p.sub', 'Suspended ' + ago(row.since) + ', ' + untilWords(row, 'until you lift it')
          + (row.reason ? ': ' + String(row.reason) : '') + (row.by ? ' · by ' + String(row.by) : '')),
        h('p.note', 'They may not place or accept a contract; they are told until when and why. '
          + 'Their live contracts run on: freeze them for that.'),
        h('div.btn-row', modBtn('', 'ps-lift', { id: 'ps-lift' }, 'Lift suspension', null, 'unlock')));
    } else {
      var days = trim(S.forms['ps.days']);
      body = frag(
        h('p.note', 'Bars them from placing or accepting contracts, for some days or until you lift it, '
          + 'with a reason they are shown. Their live contracts are not touched: freeze them for that.'),
        h('div.inline-form.is-wide.ps-picks',
          segmented('ps-days', SUSPEND_DAYS.map(function (n) {
            return { value: String(n), label: n === 1 ? '1 day' : n + ' days', disabled: !modOpen() };
          }).concat([{ value: '0', label: 'Until lifted', disabled: !modOpen() }]), days),
          field('ps.days', { id: 'ps-days', class: 'is-short', placeholder: 'Days', inputmode: 'numeric',
            maxlength: '3', disabled: !modOpen(), 'aria-label': 'Days suspended (0 until lifted)' })),
        h('div.inline-form.is-wide',
          field('ps.reason', { id: 'ps-reason', class: 'is-grow', maxlength: '120', disabled: !modOpen(),
            placeholder: 'Reason (required: they are shown it, and it goes in the log)',
            'aria-label': 'Reason for the suspension' }),
          modBtn('.is-danger', 'ps-suspend', {}, 'Suspend', 'Click again to suspend', 'ban')));
    }
    return card('Suspend from contracts', frag(body, answerBox(S.pstaff.suspend)), '',
      row ? h('span.chip.is-warn.is-suspended', 'Suspended') : null);
  }

  function protectCard(d) {
    var row = d.protected;
    var body;
    if (row) {
      body = frag(
        h('p.sub', 'Protected ' + ago(row.since) + ', ' + untilWords(row, 'for good')
          + (row.reason ? ': ' + String(row.reason) : '') + (row.by ? ' · by ' + String(row.by) : '')),
        h('p.note', 'No new contract may name them. Contracts already on them run on: freeze them to put '
          + 'those on hold.'),
        h('div.btn-row', modBtn('', 'pp-lift', { id: 'pp-lift' }, 'Lift protection', null, 'unlock')));
    } else {
      var forever = S.pstaff.unit === 'forever';
      body = frag(
        h('p.note', 'Makes them untargetable: a new player, a break from roleplay, a staff member off duty. '
          + 'A new contract on them is refused with the answer the target rules give ("cannot be listed '
          + 'right now"), and the target search lists them like anybody, so nothing says staff protect them. '
          + 'Contracts already on them are not touched: freeze them for that.'),
        h('div.inline-form.is-wide.pp-picks',
          segmented('pp-unit', PROTECT_UNITS.map(function (u) {
            return { value: u.value, label: u.label, disabled: !modOpen() };
          }), S.pstaff.unit),
          forever ? null : field('pp.amount', { id: 'pp-amount', class: 'is-short', inputmode: 'numeric',
            maxlength: '4', placeholder: S.pstaff.unit === 'd' ? 'Days' : 'Hours', disabled: !modOpen(),
            'aria-label': S.pstaff.unit === 'd' ? 'Days protected' : 'Hours protected' })),
        h('div.inline-form.is-wide',
          field('pp.reason', { id: 'pp-reason', class: 'is-grow', maxlength: '120', disabled: !modOpen(),
            placeholder: 'Reason (required, kept in the log)', 'aria-label': 'Reason for the protection' }),
          modBtn('', 'pp-protect', {}, 'Protect', 'Click again to protect', 'shield')));
    }
    return card('Protect from contracts', frag(body, answerBox(S.pstaff.protect)), '',
      row ? h('span.chip.is-protected', 'Protected') : null);
  }

  function payCard(d) {
    var max = Number(d.payMax) || 0;
    var open = writesOpen() && max > 0;
    var why = max > 0 ? whyNoWrite() : 'Manual payments are off (Config.Staff.ManualPaymentMax is 0).';
    return card('Pay', frag(
      h('p.note', max > 0
        ? 'Pays them cash or bank, at most ' + money(max) + ' at once (Config.Staff.ManualPaymentMax): '
          + 'into their hands now when they are in the city, otherwise at their next login. It creates money, '
          + 'so every payment is on the record with your reason.'
        : why),
      h('div.inline-form.is-wide.pay-form',
        segmented('pay-account', [{ value: 'cash', label: 'Cash', disabled: !open },
          { value: 'bank', label: 'Bank', disabled: !open }], S.pstaff.account),
        field('pay.amount', { id: 'pay-amount', class: 'is-short', inputmode: 'numeric', maxlength: '9',
          placeholder: 'Amount ($)', disabled: !open, 'aria-label': 'Amount to pay' })),
      h('div.inline-form.is-wide',
        field('pay.reason', { id: 'pay-reason', class: 'is-grow', maxlength: '120', disabled: !open,
          placeholder: 'Reason (required, kept in the log)', 'aria-label': 'Reason for the payment' }),
        writeBtn('.is-danger', 'pay-send', open ? {} : { title: why }, 'Pay', 'Click again to pay',
          'money-bill', false, open)),
      answerBox(S.pstaff.pay)));
  }

  var MEASURE_LABEL = { freeze: 'Freeze', suspend: 'Suspension', protect: 'Protection' };
  var ROLE_LABEL = { client: 'placed', target: 'on them', hitman: 'took' };

  function moneyTable(rows, none) {
    rows = asList(rows);
    if (!rows.length) return empty(none);
    return h('div.table-wrap', h('table.grid',
      h('thead', h('tr', h('th', 'Kind'), h('th.num', 'Amount'))),
      h('tbody', rows.map(function (r) {
        return h('tr', h('td', String(r.kind)), h('td.num', money(r.amount)));
      }))));
  }

  function historyCard() {
    var hd = S.pstaff.history;
    if (S.pstaff.historyError) return card('History', empty(S.pstaff.historyError));
    if (!hd) return card('History', loading('Reading their history…'));
    var c = hd.counts || {};
    var measures = asList(hd.measures);
    var recent = asList(hd.recent);
    var ident = hd.identified === true;
    return card('History', frag(
      h('p.hint', ident
        ? 'Everything the store keeps of them, anonymous contracts included'
          + (Number(hd.anonymous) > 0 ? ' (' + num(hd.anonymous) + ' anonymous)' : '') + '. Read-only.'
        : 'What the store keeps of them, leaving out every contract they placed or took anonymously, '
          + 'and any money or purchase on one, which only the identity ACE may see. No names. Read-only.'),
      h('div.tiles.is-compact',
        tile('Placed', h('p.big', num(c.placed))),
        tile('Taken', h('p.big', num(c.taken))),
        tile('Completed', h('p.big', num(c.completed))),
        tile('Cancelled', h('p.big', num(c.cancelled))),
        tile('On them', h('p.big', num(c.onThem))),
        tile('Bought out', h('p.big', num(c.boughtOut)))),
      h('div.tiles.is-compact',
        tile('Buyouts paid', h('p.big', num(hd.buyouts && hd.buyouts.paid))),
        tile('Paid for buyouts', h('p.big.is-sum', money(hd.buyouts && hd.buyouts.amount))),
        tile('Informants bought', h('p.big', num(hd.informants && hd.informants.count))),
        tile('Spent on informants', h('p.big.is-sum', money(hd.informants && hd.informants.spent)))),
      h('div.cols',
        card('Money in', moneyTable(hd.money && hd.money['in'], 'Nothing in that the store keeps.')),
        card('Money out', moneyTable(hd.money && hd.money.out, 'Nothing out that the store keeps.'))),
      card('Freezes, suspensions and protections', measures.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'What'), h('th', 'From'), h('th', 'Until'), h('th', 'State'),
          h('th', 'Reason'))),
        h('tbody', measures.map(function (m) {
          return h('tr',
            h('td', MEASURE_LABEL[m.kind] || String(m.kind)),
            h('td.nowrap', when(m.from)),
            h('td.nowrap', m.ended ? when(m.ended) : m['until'] ? when(m['until']) : '—'),
            h('td', String(m.state || '—')),
            h('td', String(m.reason || '—') + (m.by ? ' · by ' + String(m.by) : '')));
        })))) : empty('None on record.')),
      card('Contracts', recent.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Contract'), h('th', 'Their part'), h('th', 'State'), h('th', 'Placed'),
          ident ? h('th', 'Client') : null, ident ? h('th', 'Target') : null)),
        h('tbody', recent.map(function (r) {
          var id = String(r.id);
          return h('tr',
            h('td', h('button.link.mono', { type: 'button', 'data-act': 'contract', 'data-id': id }, id)),
            h('td', asList(r.roles).map(function (x) { return ROLE_LABEL[x] || String(x); }).join(', '),
              r.anonymous ? h('span.chip.is-anon', 'anonymous') : null),
            h('td', stateChip(r.state)), h('td.nowrap', when(r.created_at)),
            ident ? h('td.name', String(r.client || '—')) : null,
            ident ? h('td.name', String(r.target || '—')) : null);
        })))) : empty('No contracts the store keeps.'), '', h('span.sub', 'newest first'))));
  }

  /** The cards under Freeze on a player's lookup. */
  function playerStaffCards(d) {
    return frag(h('div.cols', suspendCard(d), protectCard(d)), payCard(d), historyCard());
  }

  function loadPlayerHistory() {
    var subject = S.players.subject;
    if (!subject) return Promise.resolve();
    S.pstaff.history = null;
    S.pstaff.historyError = null;
    return ask('history', { subject: subject }, 'playerHistory').then(function (reply) {
      if (!reply || subject !== S.players.subject) return;
      if (reply.ok) S.pstaff.history = reply.data || {};
      else S.pstaff.historyError = words(reply);
      drawPlayer();
    });
  }

  /** A write from one of the cards: its answer kept on the card, a toast,
      and the lookup and its history read again once it went through. */
  function staffWrite(sent, slot) {
    return sent.then(function (reply) {
      if (!reply) return null;
      S.pstaff[slot] = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) {
        var keep = S.pstaff[slot];
        loadPlayer().then(function () { S.pstaff[slot] = keep; drawPlayer(); });
      } else {
        drawPlayer();
      }
      return reply;
    });
  }

  function refuse(slot, text) {
    disarm();
    S.pstaff[slot] = { ok: false, text: text };
    drawPlayer();
  }

  ACTIONS['ps-days'] = function (node) {
    S.forms['ps.days'] = node.getAttribute('data-value') || '';
    disarm();
    drawPlayer();
  };
  ACTIONS['ps-suspend'] = function (node) {
    if (!S.players.subject) return;
    var reason = trim(S.forms['ps.reason']);
    var raw = trim(S.forms['ps.days']);
    if (!/^\d{1,3}$/.test(raw) || Number(raw) > 365) {
      return refuse('suspend', 'Choose how many days (1 to 365), or Until lifted.');
    }
    if (!reason) return refuse('suspend', 'Give a reason: they are shown it, and it goes on the record.');
    if (!confirmed(node)) return;
    staffWrite(write('suspend', { subject: S.players.subject, days: Number(raw),
      reason: reason.slice(0, 120) }, 'pstaff:suspend', node), 'suspend');
  };
  ACTIONS['ps-lift'] = function (node) {
    if (!S.players.subject) return;
    // Two clicks, as every other write here is (3 s to confirm).
    if (!confirmed(node)) return;
    staffWrite(write('unsuspend', { subject: S.players.subject }, 'pstaff:suspend', node), 'suspend');
  };

  ACTIONS['pp-unit'] = function (node) {
    S.pstaff.unit = node.getAttribute('data-value') || 'h';
    disarm();
    drawPlayer();
  };
  ACTIONS['pp-protect'] = function (node) {
    if (!S.players.subject) return;
    var reason = trim(S.forms['pp.reason']);
    var hours = 0;
    if (S.pstaff.unit !== 'forever') {
      var raw = trim(S.forms['pp.amount']);
      var n = /^\d{1,4}$/.test(raw) ? Number(raw) : 0;
      hours = S.pstaff.unit === 'd' ? n * 24 : n;
      if (n < 1 || hours > 8760) {
        return refuse('protect', S.pstaff.unit === 'd' ? 'Give a number of days, 1 to 365, or choose Permanent.'
          : 'Give a number of hours, 1 to 8760, or choose Permanent.');
      }
    }
    if (!reason) return refuse('protect', 'Give a reason: it goes on the record.');
    if (!confirmed(node)) return;
    staffWrite(write('protect', { subject: S.players.subject, hours: hours,
      reason: reason.slice(0, 120) }, 'pstaff:protect', node), 'protect');
  };
  ACTIONS['pp-lift'] = function (node) {
    if (!S.players.subject) return;
    // Two clicks, as every other write here is (3 s to confirm).
    if (!confirmed(node)) return;
    staffWrite(write('unprotect', { subject: S.players.subject }, 'pstaff:protect', node), 'protect');
  };

  ACTIONS['pay-account'] = function (node) {
    S.pstaff.account = node.getAttribute('data-value') === 'bank' ? 'bank' : 'cash';
    disarm();
    drawPlayer();
  };
  ACTIONS['pay-send'] = function (node) {
    if (!S.players.subject) return;
    var max = Number(S.players.data && S.players.data.payMax) || 0;
    var amount = wholeNumber(S.forms['pay.amount']);
    var reason = trim(S.forms['pay.reason']);
    if (!amount) return refuse('pay', 'Give the amount, a whole number of dollars.');
    if (max > 0 && amount > max) {
      return refuse('pay', 'At most ' + money(max) + ' at once (Config.Staff.ManualPaymentMax).');
    }
    if (!reason) return refuse('pay', 'Give a reason: it goes on the record.');
    if (!confirmed(node)) return;
    staffWrite(write('manualPay', { subject: S.players.subject, amount: amount, account: S.pstaff.account,
      reason: reason.slice(0, 120) }, 'pstaff:pay', node), 'pay');
  };

  STAFF_ACTIONS.push(
    { title: 'Suspend or protect a player', icon: 'ban', view: 'players', go: 'Open Players',
      text: 'Look the player up. Suspend bars them from placing or accepting contracts for some days or until '
        + 'lifted, with a reason they are shown; Protect makes them untargetable for some hours, days or for '
        + 'good. Neither touches live contracts: the freeze is the tool for those. Lift ends either at once.' },
    { title: 'Pay a player', icon: 'money-bill', view: 'players', go: 'Open Players',
      text: 'Look the player up, then Pay: cash or bank, with a reason, on two clicks, at most '
        + 'Config.Staff.ManualPaymentMax. Paid at their next login when they are away. The staff ACE only.' });

  HELP.push(
    { title: 'Suspensions and protections', icon: 'ban',
      text: 'Staff with the staff or moderator ACE can suspend a player from contracts (they cannot place or '
        + 'accept one, and are told until when and why) or protect one from them (a new contract on them is '
        + 'refused as "cannot be listed right now", and nothing says staff protect them). Both end on their '
        + 'own, or with Lift. Neither touches a contract already running: the freeze is the tool for that.',
      links: [] },
    { title: 'Moderators', icon: 'gavel',
      text: 'The moderator ACE (Config.Admin.ModeratorAce) reads everything the staff ACE reads, without '
        + 'identities. They may freeze, suspend, protect, void and move a deadline. Settings, payments, '
        + 'settling, the review queue and the Developer section stay with the staff ACE.',
      links: [{ key: 'Staff.ManualPaymentMax', view: 'limits', label: 'Most one manual payment may be' }] });

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
    S.alerts = { state: S.alerts.state, data: null, error: null, answers: {}, all: null, test: null };
    S.console = { kind: S.console.kind, data: null, error: null, sig: null, loading: false, readAt: null };
    S.logs.data = null;
    S.logs.cursor = null;
    S.logs.back = [];
    S.logs.open = {};
    S.players.data = null;
    S.players.whois = {};
    S.players.subject = null;
    S.players.playtime = null;
    S.players.freeze = null;
    S.players.frozen = null;
    resetPlayerStaff();
    S.settings.data = null;
    S.settings.answers = {};
    S.settings.photos = null;
    S.settings.drafts = {};
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

  /* ---- staff tools on one contract ----

     Five cards on a contract's view (server/staffcontract.lua and the
     panel's addNote, removeHitman, editText, exportContract and playerView):
     private notes; taking one operative off it; replacing a player's text
     through the checks a player's text gets; its whole record as plain text
     on the clipboard; and the card one of its parties sees on their phone.
     Every write is on the two-click confirm. What each card has picked lives
     on S.drawer, so another contract starts from nothing; what is typed is
     kept per contract id. */

  function ctState() {
    if (!S.drawer.ct) S.drawer.ct = { pick: '', stake: 'client', block: '', view: null, viewKey: '', exported: null };
    return S.drawer.ct;
  }

  function activeOperatives(d) {
    return asList(d.hitmen).filter(function (m) { return m.state === 'active'; });
  }

  function contractTools(d) {
    var staff = d.staff;
    if (!staff) return null;
    return frag(
      card('Staff notes', notesBody(staff), '.ct-notes'),
      card('Remove an operative', removeBody(d, staff), '.ct-remove'),
      card('Edit text', textBody(d, staff), '.ct-text'),
      card('Export the record', exportBody(), '.ct-export'),
      card('As a player sees it', playerViewBody(d), '.ct-view'));
  }

  /* -- notes -- */

  function notesBody(staff) {
    var id = S.drawer.id;
    var notes = asList(staff.notes);
    return frag(
      notes.length ? h('ol.ct-note-list', notes.map(function (n) {
        return h('li', h('span.time', when(n.at)), ' ', h('span.sub', String(n.by || 'Staff')),
          h('p.text', String(n.text || '')));
      })) : empty('No notes yet. Only staff see them.'),
      h('div.inline-form.is-wide',
        field('dr.note.' + id, { class: 'is-grow', placeholder: 'A note for staff, e.g. ticket #42, waiting on clip',
          maxlength: String(Number(staff.noteMax) || 300), disabled: !writesOpen(), 'aria-label': 'A staff note' }),
        writeBtn('', 'ct-note', {}, 'Add note', 'Click again to add', 'note-sticky')));
  }

  ACTIONS['ct-note'] = function (node) {
    var id = S.drawer.id;
    if (!id) return;
    var text = trim(S.forms['dr.note.' + id]);
    if (!text) {
      disarm();
      S.drawer.answer = { ok: false, text: 'Write the note.' };
      drawDrawer();
      return;
    }
    if (!confirmed(node)) {
      if (S.armed) S.armed.bind = 'dr.note.' + id;
      return;
    }
    write('addNote', { id: id, text: text }, 'note:' + id, node).then(function (reply) {
      if (!reply || S.drawer.id !== id) return;
      drawerAnswer(reply);
      if (reply.ok) S.forms['dr.note.' + id] = '';
      drawDrawer();
      loadContract();
    });
  };

  /* -- remove an operative -- */

  function removeBody(d, staff) {
    var id = S.drawer.id;
    var st = ctState();
    var active = activeOperatives(d);
    var past = asList(staff.removals);
    var history = past.length ? h('ul.plain.ct-history', past.map(function (r) {
      return h('li', h('span.time', when(r.at)), ' ', h('b', String(r.who || 'an operative')),
        ' removed by ' + String(r.by || 'Staff'),
        r.stakeReturned ? h('span.chip', 'stake returned') : null,
        r.blocked ? h('span.chip.is-warn', 'barred') : null,
        h('span.detail', ' ' + String(r.reason || '')));
    })) : null;
    if (!staff.removable) {
      return frag(h('p.note', 'Only a live contract (active or accepted) has operatives to remove.'), history);
    }
    if (!active.length) return frag(h('p.note', 'Nobody is on it now.'), history);
    if (!active.some(function (m) { return String(m.id) === st.pick; })) st.pick = '';
    var open = writesOpen();
    var off = { disabled: !open, title: open ? null : whyNoWrite() };
    return frag(
      h('p.note', 'Takes them off without ending it for anybody else. The client and the other operatives are '
        + 'told an operative left, as a walk-away says it; they are told "Staff removed you from a contract."'),
      h('div.ct-row', h('span.ct-label', 'Operative'),
        segmented('ct-rm-pick', active.map(function (m) {
          return { value: String(m.id), label: String(m.alias || 'operative') + (m.name ? ' · ' + m.name : ''),
                   disabled: !open, title: off.title };
        }), st.pick)),
      h('div.ct-row', h('span.ct-label', 'Their stake'),
        segmented('ct-rm-stake', [
          { value: 'client', label: 'To the client (as a walk-away)', disabled: !open, title: off.title },
          { value: 'return', label: 'Return the stake', disabled: !open, title: off.title }
        ], st.stake)),
      h('div.ct-row', h('span.ct-label', 'Afterwards'),
        segmented('ct-rm-block', [
          { value: '', label: 'May take it again', disabled: !open, title: off.title },
          { value: 'block', label: 'Bar them from it', disabled: !open, title: off.title }
        ], st.block)),
      h('div.inline-form.is-wide',
        field('dr.rm.reason.' + id, { class: 'is-grow', placeholder: 'Reason (required, kept in the log)',
          maxlength: '120', disabled: !open, 'aria-label': 'Reason for removing the operative' }),
        writeBtn('.is-danger', 'ct-remove', {}, 'Remove', 'Click again to remove', 'user-minus')),
      history);
  }

  ACTIONS['ct-rm-pick'] = function (node) { disarm(); ctState().pick = node.getAttribute('data-value') || ''; drawDrawer(); };
  ACTIONS['ct-rm-stake'] = function (node) { disarm(); ctState().stake = node.getAttribute('data-value') || 'client'; drawDrawer(); };
  ACTIONS['ct-rm-block'] = function (node) { disarm(); ctState().block = node.getAttribute('data-value') || ''; drawDrawer(); };

  ACTIONS['ct-remove'] = function (node) {
    var id = S.drawer.id;
    if (!id) return;
    var st = ctState();
    var reason = trim(S.forms['dr.rm.reason.' + id]).slice(0, 120);
    var problem = !st.pick ? 'Pick the operative to remove.' : (!reason ? 'Give a reason: it goes on the record.' : null);
    if (problem) {
      disarm();
      S.drawer.answer = { ok: false, text: problem };
      drawDrawer();
      return;
    }
    if (!confirmed(node)) {
      if (S.armed) S.armed.bind = 'dr.rm.reason.' + id;
      return;
    }
    write('removeHitman', { id: id, hitman: st.pick, reason: reason, returnStake: st.stake === 'return',
      block: st.block === 'block' }, 'remove:' + id, node).then(function (reply) {
      if (!reply || S.drawer.id !== id) return;
      drawerAnswer(reply);
      if (reply.ok) {
        S.forms['dr.rm.reason.' + id] = '';
        st.pick = '';
        if (S.section === 'contracts') loadContracts();
      }
      drawDrawer();
      loadContract();
    });
  };

  /* -- edit a player's text -- */

  function textBody(d, staff) {
    var id = S.drawer.id;
    var c = d.contract || {};
    var text = staff.text || {};
    var edits = asList(staff.edits);
    var now = h('p', 'Reason now: ', h('span.text', String(c.reason || '—')),
      text.edited ? h('span.chip', 'edited by staff') : null);
    var history = edits.length ? h('ul.plain.ct-history', edits.map(function (e) {
      return h('li', h('span.time', when(e.at)), ' ', String(e.field || 'reason') + ' replaced by '
        + String(e.by || 'Staff'), h('span.detail', ' ' + String(e.reason || '')));
    })) : null;
    if (!text.editable) return frag(now, h('p.note', 'This server keeps no reason on a contract.'), history);
    var open = writesOpen();
    var input = text.mode === 'preset'
      ? h('div.ct-row', h('span.ct-label', 'New reason'), segmented('ct-tx-preset', asList(text.presets).map(function (p) {
        return { value: String(p), label: String(p), disabled: !open, title: open ? null : whyNoWrite() };
      }), S.forms['dr.tx.text.' + id] || ''))
      : h('div.inline-form.is-wide', field('dr.tx.text.' + id, { class: 'is-grow', placeholder: 'The new text',
        maxlength: String(Number(text.max) || 120), disabled: !open, 'aria-label': 'The new reason' }));
    return frag(now,
      h('p.note', 'Goes through the same checks a player\'s text gets. Players see the new text marked '
        + '"edited by staff"; the original stays in the log.'),
      input,
      h('div.inline-form.is-wide',
        field('dr.tx.reason.' + id, { class: 'is-grow', placeholder: 'Why (required, kept in the log)',
          maxlength: '120', disabled: !open, 'aria-label': 'Reason for the edit' }),
        writeBtn('', 'ct-text', {}, 'Replace', 'Click again to replace', 'pen')),
      history);
  }

  ACTIONS['ct-tx-preset'] = function (node) {
    disarm();
    S.forms['dr.tx.text.' + S.drawer.id] = node.getAttribute('data-value') || '';
    drawDrawer();
  };

  ACTIONS['ct-text'] = function (node) {
    var id = S.drawer.id;
    if (!id) return;
    var text = trim(S.forms['dr.tx.text.' + id]);
    var reason = trim(S.forms['dr.tx.reason.' + id]).slice(0, 120);
    var problem = !text ? 'Type the new text.' : (!reason ? 'Give a reason: it goes on the record.' : null);
    if (problem) {
      disarm();
      S.drawer.answer = { ok: false, text: problem };
      drawDrawer();
      return;
    }
    if (!confirmed(node)) {
      if (S.armed) S.armed.bind = 'dr.tx.text.' + id;
      return;
    }
    write('editText', { id: id, field: 'reason', text: text, reason: reason }, 'text:' + id, node)
      .then(function (reply) {
        if (!reply || S.drawer.id !== id) return;
        drawerAnswer(reply);
        if (reply.ok) {
          S.forms['dr.tx.text.' + id] = '';
          S.forms['dr.tx.reason.' + id] = '';
        }
        drawDrawer();
        loadContract();
      });
  };

  /* -- export -- */

  function exportBody() {
    var st = ctState();
    return frag(
      h('p.note', 'Its whole timeline as plain text for a ticket: states, proposals, payments, staff actions and '
        + 'notes, shown as this view shows them to you.'),
      h('div.drawer-actions', btn('', 'ct-export', {}, 'Copy the record', 'copy')),
      st.exported && !st.exported.copied
        ? h('textarea.input.ct-export-text', { readonly: 'readonly', rows: '8', 'aria-label': 'The record, to copy' },
          st.exported.text)
        : null);
  }

  ACTIONS['ct-export'] = function () {
    var id = S.drawer.id;
    if (!id) return;
    ask('exportContract', { id: id }, 'export').then(function (reply) {
      if (!reply || S.drawer.id !== id) return;
      if (!reply.ok) { drawerAnswer(reply); drawDrawer(); return; }
      var text = String((reply.data || {}).text || '');
      var copied = copyText(text);
      ctState().exported = { text: text, copied: copied };
      toast(copied ? 'The record is on the clipboard.' : 'Select the text below and copy it.', copied ? 'ok' : 'error');
      drawDrawer();
    });
  };

  /* -- as a player sees it -- */

  /** The keys of a card in the order the phone shows them, with words. */
  var VIEW_KEYS = [
    ['role', 'Seen as'], ['targetName', 'Target'], ['reason', 'Reason'], ['state', 'State'], ['mode', 'Mode'],
    ['fulfilment', 'Completes by'], ['timeLeft', 'Time left'], ['onHold', 'On hold'], ['reward', 'Reward'],
    ['penaltyAmount', 'Stake to accept'], ['bonusPercent', 'Bonus %'], ['slots', 'Payouts'],
    ['slotsClaimed', 'Claimed'], ['hitmenActive', 'Operatives on it'], ['creatorName', 'Placed by'],
    ['creatorAnonymous', 'Placed anonymously'], ['barred', 'Barred']
  ];

  function viewValue(value) {
    if (value === true) return 'yes';
    if (value === false) return 'no';
    if (value && typeof value === 'object') return h('pre.json', prettyJson(value));
    return String(value);
  }

  function viewCard(view) {
    var seen = {};
    var rows = [];
    VIEW_KEYS.forEach(function (pair) {
      seen[pair[0]] = true;
      if (view[pair[0]] === undefined || view[pair[0]] === null) return;
      var value = pair[0] === 'reason'
        ? frag(String(view.reason || '—'), view.staffEdited ? h('span.chip', 'edited by staff') : null)
        : (pair[0] === 'reward' && view.reward && typeof view.reward === 'object'
          ? money(Number(view.reward.baseline) || 0) + (Number(view.reward.bonus) ? ' + ' + money(view.reward.bonus) + ' bonus' : '')
          : viewValue(view[pair[0]]));
      rows.push(h('dt', pair[1]), h('dd', value));
    });
    seen.staffEdited = true;
    Object.keys(view).sort().forEach(function (key) {
      if (seen[key] || view[key] === undefined || view[key] === null) return;
      rows.push(h('dt.mono', key), h('dd', viewValue(view[key])));
    });
    return h('dl.facts.ct-view-facts', rows);
  }

  function playerViewBody(d) {
    var st = ctState();
    var options = [{ value: 'target', label: 'Target' }, { value: 'placer', label: 'Placer' }];
    asList(d.hitmen).forEach(function (m) {
      options.push({ value: 'hitman:' + m.id, label: String(m.alias || 'operative') + (m.state === 'active' ? '' : ' (left)') });
    });
    var v = st.view;
    var body = null;
    if (v && v.key === st.viewKey) {
      var r = v.data || {};
      body = frag(
        r.viewer ? h('p.sub', 'As ', h('b', String(r.viewer.name || '—')), ' ', h('span.cid', String(r.viewer.cid || ''))) : null,
        r.note ? h('p.note', String(r.note)) : null,
        r.shown === false || !r.view ? null : viewCard(r.view),
        r.whitelisted ? frag(h('p.slot-title', 'Whitelisted-job view'), viewCard(r.whitelisted)) : null);
    } else if (st.viewKey) {
      body = loading('Reading their card…');
    }
    return frag(
      h('p.note', 'Read-only: exactly what their phone is sent for this contract. Anonymous parties stay hidden '
        + 'unless you hold the identity ACE.'),
      segmented('ct-view', options, st.viewKey),
      body);
  }

  ACTIONS['ct-view'] = function (node) {
    var id = S.drawer.id;
    if (!id) return;
    var key = node.getAttribute('data-value') || '';
    var st = ctState();
    st.viewKey = key;
    st.view = null;
    drawDrawer();
    var data = { id: id, role: key.indexOf('hitman:') === 0 ? 'hitman' : key };
    if (data.role === 'hitman') data.hitman = key.slice(7);
    ask('playerView', data, 'playerView').then(function (reply) {
      if (!reply || S.drawer.id !== id || ctState().viewKey !== key) return;
      if (!reply.ok) {
        ctState().viewKey = '';
        drawerAnswer(reply);
      } else {
        ctState().view = { key: key, data: reply.data || {} };
      }
      drawDrawer();
    });
  };

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

  var recalled = false;

  function open(access) {
    if (!recalled) { recalled = true; recall(); }
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

  /* ---------- roleplay (group rpC): help cards ------------------------- */

  HELP.push(
    { title: 'Roleplay: proof of intent', icon: 'comments',
      text: 'Off as shipped. On, a hitman\'s payout is held, never refused, until they have shown they worked '
        + 'the contract in character: enough messages to the client in the contract thread, or a live '
        + 'handover, or a meeting point set. Their receipt and their card say what is missing. After the hold '
        + 'time it is handed over anyway, so money is never stuck. The money stays in escrow, owed to them, '
        + 'and every hold is audited (intent_hold_started, intent_hold_released).',
      links: [{ key: 'Roleplay.ProofOfIntent.Enabled', view: 'features', label: 'Proof of intent' },
        { key: 'Roleplay.ProofOfIntent.MinMessages', view: 'limits', label: 'Messages that count' },
        { key: 'Roleplay.ProofOfIntent.HoldMaxMinutes', view: 'timers', label: 'Longest hold' }] },
    { title: 'Roleplay: reputation earned in character', icon: 'star',
      text: 'Off as shipped. On, the progression trust a completion earns is multiplied: a base factor for a '
        + 'plain completion, plus a bonus each for the thread used, a meeting point, a live handover and no '
        + 'witnesses near the hitman, up to a cap. The hitman sees the breakdown on their completion notice. '
        + 'It needs Criminal progression on to give any trust.',
      links: [{ key: 'Roleplay.Reputation.Enabled', view: 'features', label: 'Reputation' },
        { key: 'Roleplay.Reputation.BaseFactor', view: 'limits', label: 'Factors and cap' },
        { key: 'Roleplay.Reputation.WitnessRadius', view: 'limits', label: 'Witness radius' }] },
    { title: 'Roleplay: bodyguards', icon: 'shield-halved',
      text: 'Off as shipped. On, a target can hire protection from their On me card: a reward taken from them '
        + 'at once and held, and a meeting pin where they stand. Other players see the job on the board\'s '
        + 'Protection tab by its reward alone; the one who takes it gets the target\'s name and the pin, and '
        + 'never who placed the hit or who is on it. Ended without a completion (expired, cancelled, bought '
        + 'out): the guard is paid. Completed anyway: the guard gets their share and the rest goes back. '
        + 'Nobody took it, or staff voided the contract: all of it goes back to the target.',
      links: [{ key: 'Roleplay.Protection.Enabled', view: 'features', label: 'Bodyguard contracts' },
        { key: 'Roleplay.Protection.MinReward', view: 'money', label: 'Reward bounds and account' },
        { key: 'Roleplay.Protection.PayOnCompletionPercent', view: 'money', label: 'Share if completed' },
        { key: 'Roleplay.Protection.MaxJobsPerGuard', view: 'limits', label: 'Jobs per guard' }] },
    { title: 'Roleplay: hit on the hitman', icon: 'crosshairs',
      text: 'Off as shipped. On, a target whose informant found out an operative\'s name gets a button on that '
        + 'card to place a contract on them: the Place form opens with them chosen, and every rule of placing '
        + 'a contract applies. Nothing is offered for an operative found only by description.',
      links: [{ key: 'Roleplay.HitOnHitman.Enabled', view: 'features', label: 'Hit on the hitman' },
        { key: 'Informant.Enabled', view: 'features', label: 'The target\'s informant' }] });

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

  /* ---------- roleplay consequences (server/rp_consequences.lua) ------- */

  GROUP_INTRO['Roleplay: Witness heat'] = 'A completion seen by bystanders alerts the police, naming nobody.';
  GROUP_INTRO['Roleplay: EMS before re-listing'] = 'A target killed on a contract is treated before a new one.';
  GROUP_INTRO['Roleplay: City news'] = 'An anonymous news post after a completed contract.';
  GROUP_INTRO['Roleplay: Dirty money payouts'] = 'A hitman\'s cash or bank payout handed over as a dirty money item.';

  HELP.push(
    { title: 'Witness heat', icon: 'eye',
      text: 'When it is on, every completion, a kill or a handover, is checked on the server for players near '
        + 'the hitman who are no party to the contract. With enough of them, or always if set, officers get a '
        + 'vague witness report on their phones and in sc-dispatch: a phrase, the way the hitman went, and the '
        + 'nearest named area. A position can be sent too, moved by up to the fuzz distance. It never names the '
        + 'hitman or the placer.',
      links: [{ key: 'Roleplay.WitnessHeat.Enabled', view: 'features', label: 'Witness heat on or off' },
        { key: 'Roleplay.WitnessHeat.WitnessRadius', view: 'limits', label: 'Radius and witnesses' },
        { key: 'Roleplay.WitnessHeat.Phrases', view: 'limits', label: 'What a witness says' },
        { key: 'Roleplay.WitnessHeat.Areas', view: 'limits', label: 'Named areas' }] },
    { title: 'EMS before re-listing', icon: 'kit-medical',
      text: 'When it is on, a target killed on a contract cannot have a new one placed on them straight away. '
        + 'They have to have been up, neither dead nor downed, for the treated minutes first; the placer is '
        + 'told they are still recovering. With the medic switch on, an on-duty medic\'s defibrillator revive '
        + 'is needed instead. The rule always lets go after the longest hold, and it adds to the usual '
        + 'cooldowns.',
      links: [{ key: 'Roleplay.EmsRelisting.Enabled', view: 'features', label: 'On or off' },
        { key: 'Roleplay.EmsRelisting.TreatedMinutes', view: 'timers', label: 'Minutes up' },
        { key: 'Roleplay.EmsRelisting.RequireEMS', view: 'features', label: 'A medic\'s revive' }] },
    { title: 'City news', icon: 'newspaper',
      text: 'When it is on, a completed contract on a whitelisted-job target, or on any target if set, posts an '
        + 'anonymous news item. It goes out on lb-phone\'s Birdy from the configured account, or as a server '
        + 'event another resource posts. The words come from the templates, with the target\'s job, the area '
        + 'and the time. The target is named only if staff turn that on, and the hitman and the placer never.',
      links: [{ key: 'Roleplay.CityNews.Enabled', view: 'features', label: 'On or off' },
        { key: 'Roleplay.CityNews.App', view: 'limits', label: 'Where it is posted' },
        { key: 'Roleplay.CityNews.Templates', view: 'limits', label: 'Templates' }] },
    { title: 'Dirty money payouts', icon: 'sack-dollar',
      text: 'When it is on, a hitman\'s cash or bank payout is handed over as a dirty money item instead, by '
        + 'count or as one item worth the figure. Escrow keeps the money it took, and only the payout '
        + 'converts it, so nothing is lost. A refund to the placer goes back as it was taken. A payout that '
        + 'does not fit in their pockets is owed, and paid when they make room or next log in.',
      links: [{ key: 'Roleplay.DirtyPayouts.Enabled', view: 'features', label: 'On or off' },
        { key: 'Roleplay.DirtyPayouts.Item', view: 'money', label: 'The item' },
        { key: 'Roleplay.DirtyPayouts.Rate', view: 'money', label: 'The rate' }] });

  /* ---------- the roleplay features (Config.Roleplay) ---------- */

  HELP.push(
    { title: 'Rumours and the broker', icon: 'user-secret',
      text: 'Off as shipped. On, a hitman sees a new contract only as a rumour: a rough area and a reward '
        + 'band, with no name, face or Accept. Asking the broker NPC about it, standing beside it, or '
        + 'being briefed by a player on a broker job, shows the whole card and Accept for a while. The '
        + 'NPC moves between its places on a timer. Distances are checked on the server.',
      links: [{ key: 'Roleplay.Rumours.Enabled', view: 'features', label: 'Rumours on or off' },
        { key: 'Roleplay.Rumours.Locations', view: 'limits', label: 'Broker places' },
        { key: 'Roleplay.Rumours.BriefValidMinutes', view: 'timers', label: 'How long a briefing lasts' },
        { key: 'Roleplay.Rumours.BrokerJobs', view: 'targeting', label: 'Broker jobs' }] },
    { title: 'Burner phone', icon: 'mobile-screen',
      text: 'Off as shipped. On, placing, accepting and every contract action need the burner phone item '
        + 'in the inventory, counted on the server. Without one a player is told "You need a burner '
        + 'phone." and, as shipped, sees no contracts at all. Live contracts stay; a burner can be used '
        + 'up on placing or accepting. Sell it through sc-blackmarket (README).',
      links: [{ key: 'Roleplay.BurnerPhone.Enabled', view: 'features', label: 'Burner phone on or off' },
        { key: 'Roleplay.BurnerPhone.Item', view: 'limits', label: 'The item' }] },
    { title: 'The informant in person', icon: 'user-secret',
      text: 'Off as shipped. On, every informant purchase (the target\'s, the placer\'s and the tip) is '
        + 'sold only to a buyer standing beside the informant NPC, which moves between its own places. '
        + 'Anywhere else it is refused with "Find the informant first." and nothing is charged.',
      links: [{ key: 'Roleplay.InformantNpc.Enabled', view: 'features', label: 'Informant in person' },
        { key: 'Roleplay.InformantNpc.Locations', view: 'limits', label: 'Informant places' }] },
    { title: 'Reason quality', icon: 'pen',
      text: 'Off as shipped. On, a typed reason needs a least length and number of words, on top of the '
        + 'other reason rules. A reason with a low-effort phrase (rdm, idk, test) is refused, or placed '
        + 'and put in Needs review as a low-effort reason, as set.',
      links: [{ key: 'Roleplay.ReasonQuality.Enabled', view: 'features', label: 'Reason quality on or off' },
        { key: 'Roleplay.ReasonQuality.LowEffort', view: 'limits', label: 'Low-effort phrases' },
        { key: 'Roleplay.ReasonQuality.LowEffortAction', view: 'limits', label: 'Refuse or review' }] });

  /* ---------- the improvements (Config.Improvements) ---------- */

  HELP.push(
    { title: 'Tip warning delay', icon: 'clock',
      text: 'Off as shipped. On, the target of an informant tip is told someone knows their rough area '
        + 'a random while after the tip, between the shortest and longest delay, instead of at once. '
        + 'A warning still waiting survives a restart and is sent late rather than lost. The time on '
        + 'the target\'s card is rounded to 5 minutes, so it does not give the delay away.',
      links: [{ key: 'Improvements.TipWarningDelay.Enabled', view: 'features', label: 'On or off' },
        { key: 'Improvements.TipWarningDelay.MinSeconds', view: 'timers', label: 'Shortest delay' },
        { key: 'Improvements.TipWarningDelay.MaxSeconds', view: 'timers', label: 'Longest delay' }] },
    { title: 'Tip limits', icon: 'scale-balanced',
      text: 'Off as shipped. On, on top of the tips per contract and the wait between them: each hitman '
        + 'may buy one tip per contract, and/or each further tip on a contract costs twice the one '
        + 'before, up to the most a tip costs. The card quotes the real next price, and a price that '
        + 'moved is refused, never charged.',
      links: [{ key: 'Improvements.TipLimits.Enabled', view: 'features', label: 'On or off' },
        { key: 'Improvements.TipLimits.OnePerHitman', view: 'features', label: 'One per hitman' },
        { key: 'Improvements.TipLimits.PriceDoubling', view: 'features', label: 'Price doubling' },
        { key: 'Improvements.TipLimits.MaxCost', view: 'money', label: 'Most a tip costs' }] },
    { title: 'Hold before a tip', icon: 'hourglass',
      text: 'Off as shipped. On, a hitman can buy a tip only once they have held the contract for the '
        + 'minutes set. Before that the card and the refusal say how long is left; nothing is charged.',
      links: [{ key: 'Improvements.TipHoldFirst.Enabled', view: 'features', label: 'On or off' },
        { key: 'Improvements.TipHoldFirst.MinHeldMinutes', view: 'timers', label: 'Minutes held' }] },
    { title: 'Informant second try', icon: 'user-secret',
      text: 'Off as shipped. On, the target\'s look-ups after the first on a contract cost this share of '
        + 'the informant\'s price (100 is the same price). The chance stays the informant\'s own.',
      links: [{ key: 'Improvements.InformantSecondTry.Enabled', view: 'features', label: 'On or off' },
        { key: 'Improvements.InformantSecondTry.SecondTryCostPercent', view: 'money', label: 'Later price' },
        { key: 'Informant.RevealChancePercent', view: 'limits', label: 'The chance' }] },
    { title: 'Tip safe zones', icon: 'shield',
      text: 'Off as shipped. On, no tip is sold while the target stands inside one of the zones '
        + '(x, y, radius, name). The hitman is told only "Your informant can\'t place them right now.", '
        + 'never why or where, and nothing is charged.',
      links: [{ key: 'Improvements.TipSafeZones.Enabled', view: 'features', label: 'On or off' },
        { key: 'Improvements.TipSafeZones.Zones', view: 'targeting', label: 'The zones' }] },
    { title: 'Go dark', icon: 'eye-slash',
      text: 'Off as shipped. On, a target who was told of a tip can pay from On me to go dark. For the '
        + 'minutes set, every tip bought on them finds nothing: the hitman is told the informant could '
        + 'not find them and gets the price back in full. Nothing names anybody.',
      links: [{ key: 'Improvements.GoDark.Enabled', view: 'features', label: 'On or off' },
        { key: 'Improvements.GoDark.Cost', view: 'money', label: 'The price' },
        { key: 'Improvements.GoDark.Minutes', view: 'timers', label: 'How long' }] });

  /* ---------- board and progression improvements (server/imp_*.lua) ---------- */

  GROUP_INTRO['Improvements: Placer record'] = 'A placer\'s record on the board, never who they are.';
  GROUP_INTRO['Improvements: Hitman heat'] = 'Police attention a hitman\'s work builds up, naming nobody.';
  GROUP_INTRO['Improvements: Tiered board'] = 'Bigger rewards locked to higher progression levels.';
  GROUP_INTRO['Improvements: Contract decay'] = 'An untaken contract\'s reward rises, or it ends sooner.';

  HELP.push(
    { title: 'Improvements: placer record', icon: 'briefcase',
      text: 'Off as shipped. On, a board card shows how many contracts its placer placed, had paid out and '
        + 'cancelled over the last days set, not counting this one, and never who they are. A named placer\'s '
        + 'counts are exact. An anonymous placer shows nothing unless "anonymous placers too" is on, and then '
        + 'only their anonymous contracts, in bands (0, 1-4, 5-9, 10+), fixed when the card is first drawn, so '
        + 'two anonymous contracts cannot be tied to one person by their numbers.',
      links: [{ key: 'Improvements.PlacerRecord.Enabled', view: 'features', label: 'Placer record' },
        { key: 'Improvements.PlacerRecord.ShowForAnonymous', view: 'features', label: 'Anonymous placers' },
        { key: 'Improvements.PlacerRecord.LookbackDays', view: 'limits', label: 'Days counted' }] },
    { title: 'Improvements: hitman heat', icon: 'fire',
      text: 'Off as shipped. On, a hitman gets heat for a completion on a whitelisted-job target, a witness '
        + 'report on a completion, and a police bulletin about their acceptance or tip on a whitelisted-job '
        + 'target. Heat fades after the hours set. At the threshold they are known: a contract they take warns '
        + 'its target (the paranoid alert) at the chance set, and while they hold one, officers get a vague '
        + 'bulletin at most every so many minutes. Nothing names the hitman, and players never see heat.',
      links: [{ key: 'Improvements.HitmanHeat.Enabled', view: 'features', label: 'Hitman heat' },
        { key: 'Improvements.HitmanHeat.Threshold', view: 'limits', label: 'Heat and threshold' },
        { key: 'Improvements.HitmanHeat.DecayHours', view: 'timers', label: 'How long heat stays' },
        { key: 'Improvements.HitmanHeat.BulletinText', view: 'limits', label: 'The bulletin' }] },
    { title: 'Improvements: tiered board', icon: 'layer-group',
      text: 'Off as shipped, and only with Criminal progression on. Each tier is a name, the least reward and '
        + 'the least level. A hitman\'s level is 1, plus one for each so many contracts they completed. A card '
        + 'in a tier above their level shows locked, with the level needed, and the server refuses Accept on '
        + 'it before taking anything.',
      links: [{ key: 'Improvements.Tiers.Enabled', view: 'features', label: 'Tiered board' },
        { key: 'Improvements.Tiers.Tiers', view: 'limits', label: 'Tiers' },
        { key: 'Improvements.Tiers.CompletionsPerLevel', view: 'limits', label: 'Completions per level' },
        { key: 'Progression.Enabled', view: 'features', label: 'Criminal progression' }] },
    { title: 'Improvements: contract decay', icon: 'hourglass-half',
      text: 'Off as shipped. On, a contract nobody has taken changes every so many hours. "rise": its reward '
        + 'goes up by the percent set, charged to its placer through their own add-to-reward path, up to the '
        + 'most set in all; it waits while they are away, and stops for good if they cannot pay. "shorten": '
        + 'its deadline comes in by the percent of the time left. The placer is told each time, and can turn '
        + 'it off for their contract from its card.',
      links: [{ key: 'Improvements.ContractDecay.Enabled', view: 'features', label: 'Contract decay' },
        { key: 'Improvements.ContractDecay.Mode', view: 'limits', label: 'Rise or shorten' },
        { key: 'Improvements.ContractDecay.Percent', view: 'money', label: 'Step, cap and account' },
        { key: 'Improvements.ContractDecay.Hours', view: 'timers', label: 'Hours between steps' }] });

  /* ---------- the staff and economy improvements (Config.Improvements) ---------- */

  HELP.push(
    { title: 'Proof items', icon: 'id-card',
      text: 'Off as shipped. On, a hitman on a contract a kill completes can tap Hand over proof '
        + 'standing beside the person who placed it, carrying an item taken from the target (as '
        + 'shipped an id card whose citizenid names them). The server finds the item in the '
        + 'hitman\'s inventory, checks it names the target and the distance, takes the item and '
        + 'pays as for a verified kill. A payout refused gives the item back. Contracts placed '
        + 'for a live delivery only are never paid this way.',
      links: [{ key: 'Improvements.ProofItems.Enabled', view: 'features', label: 'Proof items on or off' },
        { key: 'Improvements.ProofItems.Item', view: 'limits', label: 'The item' },
        { key: 'Improvements.ProofItems.MetadataKey', view: 'limits', label: 'The field naming the target' },
        { key: 'Improvements.ProofItems.HandoverRadius', view: 'limits', label: 'The distance' }] },
    { title: 'Completion cooldown', icon: 'hourglass',
      text: 'Off as shipped (0). Set, nobody may place a contract on somebody for this long after '
        + 'a contract on them was completed, or for the ordinary wait after any contract if that '
        + 'is longer. The placer is told how many hours are left, and nothing else.',
      links: [{ key: 'Limits.TargetCooldownAfterCompletionSeconds', view: 'timers', label: 'The wait' }] },
    { title: 'Weapon serial scrubbing', icon: 'gun',
      text: 'Off as shipped. On, a weapon an anonymous placer put up reaches the hitman with a new '
        + 'random serial, so it cannot be traced back to them by its number. A refund to the placer '
        + 'is their own weapon unchanged. Each scrub is in the log; the original serial is shown '
        + 'only to staff with the identity ACE.',
      links: [{ key: 'Improvements.SerialScrub.Enabled', view: 'features', label: 'Scrubbing on or off' }] },
    { title: 'Weekly stats to Discord', icon: 'chart-column',
      text: 'Off as shipped. On, once a week on the day and hour set, one post of the last seven '
        + 'days: contracts placed, contracts completed and money paid out to hitmen. Totals only, '
        + 'never a name, a citizen id or a handle for any hitman. To the webhook in '
        + 'crimson_hitman_stats_webhook, or else the alert webhook. At most once a week.',
      links: [{ key: 'Improvements.WeeklyStats.Enabled', view: 'features', label: 'Weekly stats on or off' },
        { key: 'Improvements.WeeklyStats.Day', view: 'timers', label: 'The day' },
        { key: 'Improvements.WeeklyStats.Hour', view: 'timers', label: 'The hour' }] });

  /* Loaded to the end: admin.html's fallback, which gives the focus back
     when this file fails to load or throws while loading, stands down. */
  window.CH_ADMIN_READY = true;
})();
