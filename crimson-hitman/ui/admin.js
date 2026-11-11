/* Crimson Hitman System — the staff panel (/hitmanadmin).

   This resource's own NUI page (ui_page ui/admin.html), apart from the phone
   app. It holds no authority. Every request goes through nui() to
   client/admin.lua's adminRequest callback and on to server/panel.lua, which
   checks the ACE again on every one, rate-limits it, and answers
   { ok, err, message, data } (docs/developer.md, Integration, has every op and
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
    rearm(node);
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

  /* The sections, in sidebar groups ordered by how often each is used
     (Daily, Setup, Records, Developer), each holding its views as sub-tabs;
     Help is the header's (?) button. A view has one name: there are no old
     names kept for it. Developer is only for staff the server says may open
     it (access.canDevelop). */
  var GROUPS = [
    { id: 'home', head: 'Daily', label: 'Home', icon: 'house', views: ['overview', 'inbox', 'announce'] },
    { id: 'players', head: 'Daily', label: 'Players', icon: 'user',
      views: ['players', 'pmeasures', 'pmoney', 'pplaytime', 'phistory', 'pdiag', 'measures'] },
    { id: 'contracts', head: 'Daily', label: 'Contracts', icon: 'file-contract', views: ['contracts'] },
    // How often one person may be targeted (server/targetlimits.lua).
    { id: 'targets', head: 'Daily', label: 'Target limits', icon: 'user-clock',
      views: ['tldefaults', 'tljobs', 'tlplayer'], logs: ['logs:targets', 'History'],
      // The live contracts on each target: the one list of contracts, grouped.
      list: ['contracts:bytarget', 'Live contracts by target'] },
    { id: 'rules', head: 'Setup', label: 'Game rules', icon: 'scale-balanced', views: ['rules', 'presets', 'changed'],
      logs: ['logs:settings', 'Change history'] },
    // The hitman organisation (server/org/), off as shipped.
    { id: 'org', head: 'Setup', label: 'Hitman organisation', icon: 'people-group',
      views: ['orgsetup', 'orgroles', 'orgmembers', 'orgapps', 'orgfunds', 'orgaccess', 'orgnotices'],
      logs: ['logs:org', 'Org audit'] },
    { id: 'bossperms', head: 'Setup', label: 'Boss permissions', icon: 'key',
      views: ['bpmatrix', 'bplimits', 'bpoffice'], logs: ['logs:grants', 'Grant history'] },
    { id: 'locations', head: 'Setup', label: 'Locations', icon: 'location-dot', views: ['locations'] },
    { id: 'logs', head: 'Records', label: 'Logs', icon: 'list-ul', views: ['logs', 'alerts'] },
    { id: 'developer', head: 'Developer', label: 'Developer', icon: 'code',
      views: ['health', 'devsettings', 'console', 'tools', 'setup'], developer: true },
    { id: 'help', head: null, label: 'Help', icon: 'circle-question', views: ['help', 'howto', 'permissions'] }
  ];
  /** Each view's name on its sub-tab, its icon, and on the breadcrumb. */
  var VIEW_LABEL = {
    inbox: ['Inbox', 'inbox'], overview: ['Dashboard', 'gauge-high'], announce: ['Announce', 'bullhorn'],
    players: ['Find & summary', 'magnifying-glass'],
    pmeasures: ['Measures', 'snowflake'], pmoney: ['Money', 'sack-dollar'], pplaytime: ['Playtime', 'clock'],
    phistory: ['History', 'clock-rotate-left'], pdiag: ['Why can’t they see…', 'stethoscope'],
    measures: ['All measures', 'list-check'],
    contracts: ['Contracts', 'file-contract'],
    tldefaults: ['Defaults', 'sliders'], tljobs: ['Per job', 'briefcase'], tlplayer: ['Per player', 'user-clock'],
    rules: ['Areas', 'layer-group'], presets: ['Presets', 'box-archive'], changed: ['Changed from the panel', 'pen'],
    orgsetup: ['Setup', 'gear'], orgroles: ['Roles & pay', 'id-badge'], orgmembers: ['Members', 'users'],
    orgapps: ['Applications', 'envelope-open-text'], orgfunds: ['Funds & cuts', 'vault'],
    orgaccess: ['Contract access', 'door-open'], orgnotices: ['Notices', 'thumbtack'],
    bpmatrix: ['Matrix', 'table-cells'], bplimits: ['Limits', 'sliders'], bpoffice: ['Delegation & office', 'building'],
    locations: ['Map points', 'location-dot'],
    logs: ['Logs', 'list-ul'], alerts: ['Alerts', 'bell'],
    health: ['Health', 'heart-pulse'], devsettings: ['Engine settings', 'gear'], console: ['Console', 'terminal'],
    tools: ['Test tools', 'screwdriver-wrench'], setup: ['First-start setup', 'wand-magic-sparkles'],
    help: ['How it works', 'circle-question'], howto: ['How do I…', 'hand'], permissions: ['Who can do what', 'key']
  };
  /** One line of help under every view's title (drawn with the breadcrumb). */
  var VIEW_HELP = {
    overview: 'Everything at a glance: what waits for you, live counts, quick actions and the server\'s health.',
    inbox: 'What waits for staff: reviews no rule could settle, money left for you, alerts not seen yet.',
    announce: 'Send one notice to every hitman holding a contract, or to everybody with the app.',
    players: 'Look a player up by player id, citizen id or name, then act from their card.',
    pmeasures: 'Freeze, suspend or protect this player, and their standing in Target limits.',
    pmoney: 'What this player is owed, notices waiting for their next login, and Pay.',
    pplaytime: 'The hours counted for this player, for the new-player rule.',
    phistory: 'This player\'s contracts, money and measures over time.',
    pdiag: 'Why a contract, the board or a feature is not showing for this player.',
    measures: 'Everybody frozen, suspended, protected or with target limits of their own.',
    contracts: 'Every contract: search, filter by state or by one person, then open one to act on it.',
    tldefaults: 'How often one person may have a contract placed on them, for everybody.',
    tljobs: 'A job\'s own target limits, and one action for every player of a job.',
    tlplayer: 'One target\'s cooldown and counts, exactly, with Reset, Extend and Exempt.',
    rules: 'Every game rule by the area it is about; pick an area or a type of setting.',
    changed: 'The settings changed from this panel, each with Reset to config.lua.',
    presets: 'Named bundles of settings: see every change one makes, then apply it with two clicks.',
    orgsetup: 'The hitman organisation\'s switch, its job and how it runs.',
    orgroles: 'The organisation\'s roles, their rank and their pay.',
    orgmembers: 'Who is in the organisation, their role and duty.',
    orgapps: 'Applications to join the organisation, to accept or turn down.',
    orgfunds: 'The organisation\'s money and the cut it takes of contracts.',
    orgaccess: 'Which contracts the organisation\'s members may take.',
    orgnotices: 'Notices pinned for the organisation\'s members.',
    bpmatrix: 'What each boss role, and each boss, may do in the organisation.',
    bplimits: 'The limits on each boss power.',
    bpoffice: 'Which powers bosses may hand down, and which need the boss office.',
    locations: 'Every place on the map this resource uses, set where you stand or by hand.',
    logs: 'Every staff and game action on the record, filtered by area, player or time.',
    alerts: 'Problems the server raised, to acknowledge once handled.',
    health: 'What the server itself is doing: jobs, stores, other resources.',
    devsettings: 'Engine settings: storage, timings and limits only developers change.',
    console: 'Run a staff console command from the panel.',
    tools: 'Test tools: try a feature without a real player.',
    setup: 'The first-start setup: storage, your other scripts, permissions, the panel command and the key switches.',
    help: 'How the contract app works, in plain words, each card linked to its settings.',
    howto: 'Short answers to how do I…, each with a button to where it is done.',
    permissions: 'Who can do what: every permission this resource checks.'
  };
  window.CH_ADMIN_VIEW_HELP = VIEW_HELP;

  /** The views only the Developer section's staff see. */
  var DEV_VIEWS = { health: true, devsettings: true, console: true };
  /** A selected player's own tabs, shown once somebody is looked up. */
  var PERSON_VIEWS = { pmeasures: true, pmoney: true, pplaytime: true, phistory: true, pdiag: true };
  var PLAYER_VIEWS = { players: true, pmeasures: true, pmoney: true, pplaytime: true,
                       phistory: true, pdiag: true };
  var ORG_VIEWS = { orgsetup: true, orgroles: true, orgmembers: true, orgapps: true, orgfunds: true,
                    orgaccess: true, orgnotices: true };
  var BP_VIEWS = { bpmatrix: true, bplimits: true, bpoffice: true };
  var SECTIONS = [];
  GROUPS.forEach(function (g) { SECTIONS = SECTIONS.concat(g.views); });

  /** The settings view each category is shown in; Game rules' areas hold
      the rules and features categories. */
  var CATEGORY_VIEW = {
    'rules-timers': 'rules', 'rules-rewards': 'rules', 'rules-limits': 'rules',
    'rules-targeting': 'rules', features: 'rules', developer: 'devsettings',
    'target-limits': 'tldefaults', organisation: 'orgsetup'
  };
  var SETTING_VIEWS = { rules: true, changed: true, devsettings: true, tldefaults: true };

  /** Ops that only read. A refusal of one as not_allowed means the staff
      member may no longer read at all (an ACE taken away while the panel was
      open), and the panel closes on it, as the README says it does. */
  var READ_OPS = { access: true, overview: true, contracts: true, contract: true, reviews: true,
                   logs: true, player: true, settings: true, diag: true, whois: true, stuck: true,
                   alerts: true, console: true, measures: true, exportContract: true, playerView: true,
                   history: true,
                   targetLimits: true, targetStatus: true, targetJobCount: true, presets: true,
                   orgGet: true, bossPermsGet: true, orgFunds: true, placeMyPosition: true,
                   rewardPreview: true, reassignPreview: true, disposalList: true, placeList: true };

  var DEBOUNCE_MS = 250;
  var CONFIRM_MS = 3000;
  var TOAST_MS = 6000, TOAST_ERROR_MS = 9000, TOASTS_MAX = 4;

  var S = {
    open: false,
    gen: 0,                 // bumped on every open and close: a reply from before is nobody's
    access: {},
    recovery: 'ready',
    section: 'inbox',
    seq: {},                // [channel] = the newest request on it
    forms: {},              // what has been typed, by data-bind, so a redraw keeps it
    busy: {},               // writes in flight, by what they act on
    armed: null,            // { node, timer, value, bind }: the destructive button waiting for its second click
    menu: null,             // the dropdown that is open
    overview: null, overviewAt: 0, overviewError: null, overviewTimer: null,
    pollGen: 0,             // the open whose overview refresh is running
    // The one list of contracts. `person`: whose contracts it shows ({ ref or
    // person, name }, from a player's card or typed here), `as` their part on
    // them; `byTarget` the live ones grouped by target (Target limits').
    contracts: { page: 1, state: 'live', rule: '', range: '', data: null, timer: null,
                 person: null, as: '', byTarget: false, whois: {} },
    drawer: { id: null, data: null, answer: null, whois: null },
    stuck: { data: null, error: null, answers: {} },
    reviews: { all: false, items: null, action: {}, answers: {} },
    presets: { data: null, error: null, answer: null },
    setup: { data: null, error: null, answer: null, values: {}, preview: null, shown: false },
    alerts: { state: 'open', data: null, error: null, answers: {}, all: null, test: null },
    console: { kind: '', data: null, error: null, sig: null, loading: false, readAt: null },
    logs: { area: 'audit', kind: '', range: '', cursor: null, back: [], data: null, open: {}, timer: null },
    players: { data: null, subject: null, ref: null, playtime: null, freeze: null, measures: null,
               measureKind: '', at: 0, recent: [], lift: {} },
    inbox: 'all',           // which of the inbox's lists show: all, reviews, stuck, alerts
    rules: { area: '', type: '' },
    ctx: { contract: null },  // the contract last opened, for its header chip
    search: { q: '', open: false, at: 0 },
    help: { open: {} },
    settings: { data: null, answers: {}, photos: null, drafts: {}, open: {} },
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
    server_error: 'That raised an error on the server. Run the diagnosis, under Developer, Health, to read it.',
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
    return WORDS[reply.err] || 'Not done: the server refused it without saying why. The audit log has the details.';
  }
  /** For the tests. */
  window.CH_ADMIN_WORDS = words;

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

     Every write takes two clicks (a switch, a choice and a Save too): the
     first arms the button and says what the second does, naming the new
     value where there is one, and it disarms itself after three seconds.
     A redraw while it is armed (the timed overview refresh, a list read
     again) arms the button drawn in its place, when it is the same button
     saying the same thing, so the second click is not a third. */

  function disarm() {
    if (!S.armed) return;
    clearTimeout(S.armed.timer);
    S.armed.node.classList.toggle('is-armed', false);
    S.armed = null;
  }

  /* What tells a button apart from every other: its act, id and data, and
     the words it shows. A redrawn one that says something else (a count
     that moved, a switch the other way) is a different button. */
  var ARM_ATTRS = ['id', 'data-act', 'data-key', 'data-value', 'data-id', 'data-ref', 'data-index',
    'data-line', 'data-bucket', 'data-where', 'data-how', 'data-subject', 'data-contract', 'data-report',
    'data-ace', 'data-view', 'data-group', 'data-section', 'data-power'];
  /* And whom it acts on: the player card's buttons and the drawer's carry
     no id of their own, so the player looked up (by the handle the lookup
     gave) and the contract open are part of what tells one apart. A button
     armed on one player or contract is never armed again on the next. */
  function armSig(node) {
    return ARM_ATTRS.map(function (k) { return node.getAttribute(k) || ''; }).join('\u0001')
      + '\u0001' + node.textContent
      + '\u0001' + ((S.players && S.players.ref) || '') + '\u0001' + ((S.drawer && S.drawer.id) || '');
  }

  function attached(node) {
    while (node) {
      if (node === document) return true;
      node = node.parentNode;
    }
    return false;
  }

  /** The armed label, naming the value the second click sets. */
  function showArmed(node, label) {
    var cfm = label && node.querySelector('.cfm');
    if (cfm) cfm.textContent = label;
  }

  /** After a redraw inside root: the armed button, drawn again, armed again. */
  function rearm(root) {
    var armed = S.armed;
    if (!armed || attached(armed.node) || !root.querySelectorAll) return;
    var same = Array.prototype.filter.call(root.querySelectorAll('[data-act]'), function (n) {
      return !n.disabled && armSig(n) === armed.sig;
    });
    if (same.length !== 1) return;
    armed.node = same[0];
    same[0].classList.toggle('is-armed', true);
    showArmed(same[0], armed.label);
  }

  /** True on the second click; on the first, arms the button and says no.
      `label`, when given, is what the armed button says in place of the
      confirm it was drawn with. */
  function confirmed(node, label) {
    if (S.armed && S.armed.node === node) { disarm(); return true; }
    disarm();
    var sig = armSig(node);
    node.classList.toggle('is-armed', true);
    S.armed = { node: node, sig: sig, label: label || null, timer: setTimeout(disarm, CONFIRM_MS) };
    showArmed(node, label);
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
    // What decides it, so a change of recovery or of the ACE toggles the
    // button where it is (refreshGates) rather than redrawing the section.
    a['data-gate'] = a['data-gate'] || (open !== undefined ? 'custom' : always ? 'always' : 'write');
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
      if (o.confirm && !on) {
        a['data-confirm'] = 'yes';
        return h('button.seg-btn', a, h('span.lbl', o.label), h('span.cfm', o.confirm));
      }
      return h('button.seg-btn' + (on ? '.is-on' : ''), a, o.label);
    }));
  }

  function empty(text) { return h('p.empty', text); }

  function loading(text) { return h('p.loading', icon('spinner'), ' ', text || 'Loading…'); }

  function answerBox(answer) {
    if (!answer) return null;
    return h('div.notice.answer' + (answer.ok ? '.ok' : ''), { role: 'status' },
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
    var heads = {};
    GROUPS.forEach(function (g) {
      var top = byId('grp-' + g.id);
      var shown = groupShown(g);
      if (shown && g.head) heads[g.head] = true;
      if (top) {
        top.hidden = !shown;
        top.classList.toggle('is-on', g === current);
        top.setAttribute('aria-current', g === current ? 'page' : 'false');
      }
    });
    ['Daily', 'Setup', 'Records', 'Developer'].forEach(function (head) {
      var node = byId('nh-' + head.toLowerCase());
      if (node) node.hidden = !heads[head];
    });
    var help = byId('help-btn');
    if (help) help.classList.toggle('is-on', !!current && current.id === 'help');
    var menu = byId('nav-menu');
    if (menu) {
      var lbl = menu.querySelector('.lbl');
      if (lbl) lbl.textContent = current ? current.label : 'Sections';
      menu.setAttribute('aria-expanded', S.navOpen ? 'true' : 'false');
    }
    var nav = byId('nav');
    if (nav) nav.classList.toggle('is-open', !!S.navOpen);
    drawSubnav();
    drawCrumbs();
    drawContext();
    drawCounts();
  }

  /** The section's sub-tabs, drawn for the section open: a selected
      player's own tabs only once somebody is looked up. */
  function drawSubnav() {
    var subnav = byId('subnav');
    if (!subnav) return;
    var g = groupOf(S.section);
    var views = g ? g.views.filter(viewShown) : [];
    subnav.hidden = views.length + (g && g.logs ? 1 : 0) + (g && g.list ? 1 : 0) < 2;
    var counts = { inbox: 'count-inbox', changed: 'count-settings', alerts: 'count-alerts' };
    setHtml(subnav, frag(views.map(function (view) {
      var on = view === S.section;
      var label = VIEW_LABEL[view] || [view, 'circle'];
      return h('button.sub-btn' + (on ? '.is-on' : '') + (PERSON_VIEWS[view] ? '.is-person' : ''),
        { id: 'nav-' + view, type: 'button', 'data-act': 'section', 'data-section': view,
          'aria-current': on ? 'page' : 'false' },
        icon(label[1]), h('span.lbl', label[0]),
        counts[view] ? h('span.nav-count.is-warn', { id: counts[view], hidden: true }) : null);
    }), g && g.logs ? h('button.sub-btn.is-link', { id: 'nav-' + g.logs[0].replace(':', '-'), type: 'button',
      'data-act': 'section', 'data-section': g.logs[0], title: 'Records \u203a Logs, ' + g.logs[1] },
      icon('list-ul'), h('span.lbl', g.logs[1] + ' \u25b8')) : null,
      g && g.list ? h('button.sub-btn.is-link', { id: 'nav-' + g.list[0].replace(':', '-'), type: 'button',
        'data-act': 'section', 'data-section': g.list[0], title: 'Contracts, ' + g.list[1] },
        icon('file-contract'), h('span.lbl', g.list[1] + ' \u25b8')) : null));
  }

  /** Where the staff member is: the section, the player or area chosen, the view. */
  function drawCrumbs() {
    var node = byId('crumbs');
    if (!node) return;
    var g = groupOf(S.section);
    var parts = [];
    if (g) parts.push(g.label);
    if (PERSON_VIEWS[S.section] || (S.section === 'players' && hasPlayer())) parts.push(playerChipText());
    parts.push((VIEW_LABEL[S.section] || [S.section])[0]);
    if (S.section === 'logs') parts.push(logAreaLabel());
    if (S.section === 'rules' && S.rules.area) parts.push(areaLabel(S.rules.area));
    setHtml(node, frag(parts.map(function (part, i) {
      return frag(i ? h('span.crumb-sep', { 'aria-hidden': 'true' }, '›') : null,
        h('span.crumb' + (i === parts.length - 1 ? '.is-here' : ''), part));
    }), VIEW_HELP[S.section] ? h('div.view-help-row', h('p.view-help', VIEW_HELP[S.section]),
      VIEW_SETTINGS[S.section] ? frag(h('button.link.gear-btn', { type: 'button', 'data-act': 'gear',
        'aria-expanded': S.gearOpen === S.section ? 'true' : 'false', 'aria-controls': 'gear',
        title: 'This screen\'s settings, here' }, icon('gear'), ' ', S.gearOpen === S.section
        ? 'Hide its settings' : 'Settings for this screen')) : null) : null));
  }

  /** Whether a player is selected: looked up, with a handle to act on. */
  function hasPlayer() {
    var d = S.players.data;
    return !!(S.players.ref && d && !d.error && d.player);
  }

  /** Minutes left of the lookup's handle (the server's ten). */
  var PLAYER_REF_MIN = 10;
  function refMinutesLeft() {
    if (!S.players.at) return 0;
    return Math.max(0, PLAYER_REF_MIN - Math.floor((Date.now() - S.players.at) / 60000));
  }

  function playerChipText() {
    var p = (S.players.data && S.players.data.player) || {};
    return String(p.name || 'No name on record')
      + (p.online ? ' (in city · ' + String(p.server) + ')' : ' (offline)');
  }

  /** The header's chips: the selected player (with the minutes left of the
      lookup) and the contract last opened, each with its own clear. */
  function drawContext() {
    var node = byId('ctx');
    if (!node) return;
    var parts = [];
    if (hasPlayer()) {
      var left = refMinutesLeft();
      parts.push(h('span.ctx-chip' + (left <= 0 ? '.is-stale' : ''),
        h('button.ctx-open', { type: 'button', 'data-act': left <= 0 ? 'ctx-relookup' : 'ctx-player',
          title: left <= 0 ? 'The lookup ran out: look them up again' : 'Open their card' },
          icon('user'), h('span.lbl', 'Player: ' + String((S.players.data.player || {}).name || 'No name on record')),
          h('span.ctx-left', left <= 0 ? 'look up again' : left + ' min')),
        h('button.ctx-x', { type: 'button', 'data-act': 'ctx-player-clear', 'aria-label': 'Clear the player',
          title: 'Clear the player' }, icon('xmark'), h('span.lbl', 'Clear'))));
    }
    if (S.ctx.contract) {
      parts.push(h('span.ctx-chip',
        h('button.ctx-open', { type: 'button', 'data-act': 'ctx-contract', title: 'Open the contract' },
          icon('file-contract'), h('span.lbl', 'Contract: ' + S.ctx.contract)),
        h('button.ctx-x', { type: 'button', 'data-act': 'ctx-contract-clear', 'aria-label': 'Clear the contract',
          title: 'Clear the contract' }, icon('xmark'), h('span.lbl', 'Clear'))));
    }
    node.hidden = !parts.length;
    setHtml(node, frag(parts));
  }

  function drawBanner() {
    var banner = byId('banner');
    if (!banner) return;
    if (S.recovery === 'recovering') {
      banner.hidden = false;
      banner.className = 'notice gold banner';
      setHtml(banner, frag(icon('hourglass-half'), h('span',
        'Still recovering from the restart. Everything reads; void, settle, resolve, settings and the '
        + 'timer refresh wait until it finishes.')));
    } else if (S.recovery === 'recovery_failed') {
      banner.hidden = false;
      banner.className = 'notice banner';
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
    var reviews = o.reviews ? Number(o.reviews.open) || 0 : 0;
    // What staff settle, not every line listed: one queued since, or an
    // ending finishing itself, needs nobody.
    var stuck = o.stuck ? Number(o.stuck.leftForStaff) || 0 : 0;
    var alerts = o.alerts ? Number(o.alerts.open) || 0 : 0;
    var changed = Number(o.overrides) || 0;
    setCount('count-home', reviews + stuck + alerts, 'waiting in the inbox: reviews, money left for staff and alerts');
    setCount('count-inbox', reviews + stuck + alerts, 'waiting in the inbox');
    setCount('count-reviews', reviews, 'open in the review queue');
    setCount('count-stuck', stuck, 'escrow line(s) left for you to settle');
    setCount('count-ialerts', alerts, 'open alerts, not acknowledged yet');
    setCount('count-rules', changed, 'setting(s) changed from the panel');
    setCount('count-settings', changed, 'setting(s) changed from the panel');
    setCount('count-logs', alerts, 'open alerts, not acknowledged yet');
    setCount('count-alerts', alerts, 'open alerts, not acknowledged yet');
  }

  /** Every write button drawn, enabled or not as recovery and the ACEs now
      say, where it stands: no section is drawn again for it. A button whose
      gate only its section knows (a setting's) has its section redrawn. */
  function refreshGates() {
    var panel = byId('panel');
    if (!panel || !panel.querySelectorAll) return;
    var custom = false;
    panel.querySelectorAll('[data-gate]').forEach(function (node) {
      var gate = node.getAttribute('data-gate');
      if (gate === 'custom') { custom = true; return; }
      var open = gate === 'mod' ? modOpen() : gate === 'always' ? canWrite() : writesOpen();
      node.disabled = !open;
      if (open) node.removeAttribute('title');
      else node.setAttribute('title', gate === 'mod' ? whyNoMod() : whyNoWrite());
    });
    if (custom) redraw();
  }

  function setRecovery(state) {
    if (!state || state === S.recovery) return;
    S.recovery = state;
    drawBanner();
    // Every write button follows, where it is.
    refreshGates();
  }

  /* ---------- sections ------------------------------------------------- */

  var SHELL = {}, LOAD = {};

  function canDevelop() { return S.access.canDevelop === true; }

  /** The section a view is a sub-tab of. */
  function groupOf(view) {
    for (var i = 0; i < GROUPS.length; i++) if (GROUPS[i].views.indexOf(view) !== -1) return GROUPS[i];
    return null;
  }

  /** Whether this staff member is shown a view at all. Bring timers forward
      and the log flush are the staff ACE's too, under Developer's Test tools
      (Help, How do I... links them for staff without the Developer ACE). */
  function viewAllowed(view) {
    if (DEV_VIEWS[view]) return canDevelop();
    if (view === 'tools') return canDevelop() || canWrite();
    return true;
  }
  /** And on its section's strip: a selected player's tabs once there is one. */
  function viewShown(view) { return viewAllowed(view) && (!PERSON_VIEWS[view] || hasPlayer()); }
  /** A section is in the sidebar when it has a view to show; Developer only
      for the Developer ACE. */
  function groupShown(g) {
    if (g.developer && !canDevelop()) return false;
    if (g.id === 'help') return false;
    return g.views.some(viewAllowed);
  }

  /* Where the staff member was, kept in this browser only: the last view,
     and the sub-tab last open in each section. Storage that throws (private
     mode, a CEF profile without it) is no storage, never a fault. A view
     kept under an old name lands where it is now. */
  var STORE_KEY = 'crimson-hitman.admin.nav';

  function remember() {
    try {
      window.localStorage.setItem(STORE_KEY, JSON.stringify({ view: S.section, sub: S.remembered }));
    } catch (err) { /* not kept */ }
  }

  function known(view) {
    if (typeof view !== 'string') return null;
    return SECTIONS.indexOf(view) !== -1 ? view : null;
  }

  function recall() {
    try {
      var kept = JSON.parse(window.localStorage.getItem(STORE_KEY) || 'null');
      if (!kept || typeof kept !== 'object') return;
      if (kept.sub && typeof kept.sub === 'object') {
        Object.keys(kept.sub).forEach(function (g) {
          var view = known(kept.sub[g]);
          var group = view && groupOf(view);
          if (group) S.remembered[group.id] = view;
        });
      }
      var view = known(kept.view);
      // A selected player's tab is nobody's after a reopen: their Find.
      if (view) S.section = PERSON_VIEWS[view] ? 'players' : view;
    } catch (err) { /* nothing kept */ }
  }

  /** A section's own sub-tab: the one last open in it, else its first. */
  function openGroup(id) {
    var g = GROUPS.filter(function (x) { return x.id === id; })[0];
    if (!g) return;
    var views = g.views.filter(viewShown);
    var want = S.remembered[g.id];
    S.navOpen = false;
    show(views.indexOf(want) !== -1 ? want : views[0]);
  }

  function show(section) {
    // A section's link to its own log: Records \u203a Logs with that log's
    // filter (LOG_AREAS), as 'logs:<filter>'.
    var at = typeof section === 'string' ? section.indexOf(':') : -1;
    if (at > 0 && section.slice(0, at) === 'logs') {
      pickLogArea(section.slice(at + 1));
      section = 'logs';
    }
    // Home's inbox with one filter chosen, as 'inbox:<filter>'.
    if (at > 0 && section.slice(0, at) === 'inbox') {
      S.inbox = section.slice(at + 1);
      section = 'inbox';
    }
    // The one list of contracts, as Target limits shows it: the live ones
    // grouped by target ('contracts:bytarget').
    if (at > 0 && section.slice(0, at) === 'contracts') {
      if (section.slice(at + 1) === 'bytarget') {
        S.contracts.byTarget = true;
        S.contracts.person = null;
        S.contracts.state = 'live';
        S.contracts.page = 1;
      }
      section = 'contracts';
    }
    // Game rules with one type of setting shown, every area, as
    // 'rules:<type>' (switch, timer, money, limit, list, changed).
    if (at > 0 && section.slice(0, at) === 'rules') {
      S.rules.type = section.slice(at + 1);
      S.rules.area = '';
      section = 'rules';
    }
    if (SECTIONS.indexOf(section) === -1) section = 'inbox';
    // A selected player's tab with nobody selected: Find.
    if (PERSON_VIEWS[section] && !hasPlayer()) section = 'players';
    // Developer views for staff the server says may not open them: who can
    // do what, which everybody may read.
    if (!viewAllowed(section)) section = 'permissions';
    var before = S.section;
    S.section = section;
    var g = groupOf(section);
    if (g) S.remembered[g.id] = section;
    remember();
    // The contract drawer stays open over any section until it is closed.
    disarm();
    S.menu = null;
    S.search.open = false;
    drawSearch();
    drawChrome();
    var main = byId('main');
    if (S.gearOpen !== section) S.gearOpen = null;
    setHtml(main, frag(h('div.gear', { id: 'gear', hidden: S.gearOpen !== section }, gearBody()), SHELL[section]()));
    if (main) main.scrollTop = 0;
    LOAD[section](before);
    // The overview's pace follows the section: quicker on Home and the live views.
    if (S.pollGen === S.gen && fastPace(before) !== fastPace(section)) schedule(S.gen);
  }
  window.CH_ADMIN_SHOW = function (view) { if (S.open) show(view); };

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
  /** Away from Home, the counts on the sidebar only need reading this often. */
  var AWAY_MS = 30000;
  /** The views that read again at the panel's own pace while they show. */
  var LIVE_VIEWS = { console: true, alerts: true, health: true };
  function fastPace(view) { var g = groupOf(view); return (g && g.id === 'home') || !!LIVE_VIEWS[view]; }
  function pollMs() { return fastPace(S.section) ? refreshMs() : Math.max(refreshMs(), AWAY_MS); }

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
      if (S.section !== 'overview' && S.section !== 'health') return;
      var at = same && byId('ov-at');
      if (at) { at.textContent = overviewStamp(); return; }
      setHtml(byId(S.section === 'health' ? 'dg' : 'ov'), S.section === 'health' ? healthBody() : overviewBody());
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
        if (shows('stuck') && !S.drawer.id) loadStuck(true);
        // And the alerts, unless a button there waits for its second click.
        if (shows('alerts') && !S.drawer.id && !S.armed) loadAlerts();
        // The header's lookup chip counts its minutes down.
        drawContext();
        // And the console: its live updates, at this pace and no faster.
        if (S.section === 'console' && !S.drawer.id) loadConsole();
        loadOverview(false).then(next, next);
      } catch (err) {
        next();
      }
    }, pollMs());
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

  /** The inbox's three counts on Home, each opening its list. */
  function inboxCounts(o) {
    var forYou = o.stuck ? Number(o.stuck.leftForStaff) || 0 : 0;
    var reviewsOpen = o.reviews ? Number(o.reviews.open) || 0 : 0;
    var alertsOpen = o.alerts ? Number(o.alerts.open) || 0 : 0;
    var listed = o.stuck ? Number(o.stuck.total) || 0 : 0;
    return frag(
      h('p.big' + (forYou + reviewsOpen + alertsOpen > 0 ? '.is-warn' : ''), num(forYou + reviewsOpen + alertsOpen)),
      h('p.sub', 'waiting for you'),
      h('div.chips',
        h('button.chip.is-link', { type: 'button', 'data-act': 'ib-go', 'data-value': 'reviews' },
          'Needs review ' + num(reviewsOpen)),
        h('button.chip.is-link', { type: 'button', 'data-act': 'ib-go', 'data-value': 'stuck' },
          'Money waiting ' + num(forYou)),
        h('button.chip.is-link', { type: 'button', 'data-act': 'ib-go', 'data-value': 'alerts' },
          'Alerts ' + num(alertsOpen))),
      !o.stuck ? h('p.note', notListed(o.recovery))
        : o.stuck.error ? h('p.note.is-error', 'Money waiting could not be read just now; the inbox reads it again.')
          : listed > forYou ? h('p.note', num(listed - forYou) + ' more line' + (listed - forYou === 1 ? '' : 's')
            + ' listed need nothing from you.') : null);
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
    var warnings = asList(o.warnings);
    var measures = o.measures || {};
    var frozenCount = Number(measures.freeze) || 0;
    // The store's freezes could not be read: unknown, never 0.
    var frozenUnknown = !!measures.unknown;
    var held = frozenCount > 0 || frozenUnknown;

    var problems = canWrite() ? warnings.length : 0;
    return frag(
      h('div.tiles',
        tile('Inbox', inboxCounts(o)),
        tile('Quick actions', h('div.btn-row.quick',
          btn('.is-small', 'section', { 'data-section': 'players' }, 'Find a player', 'magnifying-glass'),
          btn('.is-small', 'section', { 'data-section': 'contracts' }, 'Contracts', 'file-contract'),
          btn('.is-small', 'section', { 'data-section': 'contracts:bytarget' }, 'Live by target', 'crosshairs'),
          btn('.is-small', 'section', { 'data-section': 'announce' }, 'Announce', 'bullhorn'),
          btn('.is-small', 'section', { 'data-section': 'rules' }, 'Game rules', 'scale-balanced'))),
        tile('Health', frag(
          h('p.big' + (o.recovery !== 'ready' || problems ? '.is-warn' : '') + '.is-word',
            o.recovery === 'recovering' ? 'Recovering' : o.recovery !== 'ready' ? 'Recovery failed'
              : problems ? num(problems) + ' problem' + (problems === 1 ? '' : 's') : 'All well'),
          h('dl.facts',
            h('dt', 'Recovery'), h('dd', o.recovery === 'ready' ? 'finished'
              : o.recovery === 'recovering' ? 'still running' : 'FAILED'),
            h('dt', 'Storage'), h('dd', String(o.storage || '—')),
            h('dt', 'Setup problems'), h('dd', canWrite() ? num(warnings.length) : '—'),
            h('dt', 'Changed here'), h('dd', Number(o.overrides) > 0 ? h('button.link', { type: 'button',
              'data-act': 'section', 'data-section': 'changed' }, num(o.overrides) + ' setting'
              + (Number(o.overrides) === 1 ? '' : 's')) : 'none')),
          o.storage === 'memory' ? h('span.chip.is-warn', { title: 'Contracts, escrow, review items and settings are '
            + 'gone at the next start' }, 'memory mode: nothing is kept across a restart') : null,
          canDevelop() ? h('div.btn-row', btn('.is-small.ghost', 'section', { 'data-section': 'health' },
            'Server health', 'heart-pulse')) : null),
          o.recovery !== 'ready' || problems ? '.is-warn' : ''),
        tile('Contracts', frag(
          h('p.big', num(contracts.total)),
          h('div.chips', states.filter(function (s) { return byState[s]; }).map(function (s) {
            return h('button.chip.is-link', { type: 'button', 'data-act': 'ov-state', 'data-value': s },
              (STATE_LABEL[s] || s) + ' ' + num(byState[s]));
          })),
          h('p.sub', 'new ones placed under ' + (RULE_LABEL[o.fulfilment] || String(o.fulfilment || '—'))))),
        tile('Operatives', frag(
          h('p.big', num(hitmen.operatives)),
          h('p.sub', 'on contracts now, holding ' + num(hitmen.contracts) + ' contract'
            + (Number(hitmen.contracts) === 1 ? '' : 's')))),
        tile('Held in escrow', moneyRows(o.held)),
        tile('Owed to players', frag(moneyRows(owed),
          h('p.sub', num(owed.players) + ' player' + (Number(owed.players) === 1 ? '' : 's') + ' · '
            + num(owed.queued) + ' line' + (Number(owed.queued) === 1 ? '' : 's') + ' in a retry queue'))),
        tile('Measures on players', frag(
          h('dl.facts',
            h('dt', 'Frozen'), h('dd', h('span' + (held ? '.is-warn' : ''), { id: 'ov-frozen' },
              frozenUnknown ? 'Unknown' : num(frozenCount))),
            h('dt', 'Suspended'), h('dd', measures.suspend == null ? '—' : num(measures.suspend)),
            h('dt', 'Protected'), h('dd', measures.protect == null ? '—' : num(measures.protect)),
            h('dt', 'Own target limits'), h('dd', measures.limit == null ? '—' : num(measures.limit))),
          frozenUnknown ? h('p.sub', 'the store\'s freezes could not be read: every live contract is held until '
            + 'they can be') : null,
          h('div.btn-row',
            btn('.is-small', 'ms-open', { 'data-value': '' }, 'All measures', 'arrow-right'),
            btn('.is-small.ghost', 'ms-open', { 'data-value': 'freeze' }, 'Frozen', 'arrow-right'),
            btn('.is-small.ghost', 'ms-open', { 'data-value': 'suspend' }, 'Suspended', 'arrow-right'),
            btn('.is-small.ghost', 'ms-open', { 'data-value': 'protect' }, 'Protected', 'arrow-right'))),
          held ? '.is-warn' : '')),
      warnings.length && canWrite() ? card('Setup problems (' + num(warnings.length) + ')', frag(
        h('ul.warnings', warnings.map(function (line) { return h('li', String(line)); })),
        S.tools.diag && S.section === 'overview' ? linesBox(S.tools.diag.lines, S.tools.diag.later) : null),
        '.is-warn', btn('.is-small', 'ov-diag', {}, 'Run the diagnosis', 'stethoscope')) : null,
      h('p.foot', icon('rotate'),
        h('span', { id: 'ov-at' }, overviewStamp()),
        S.overviewError ? h('span.is-error', ' · last refresh: ' + S.overviewError) : null,
        ' ', btn('.is-small.ghost', 'ov-refresh', {}, 'Refresh now')));
  }

  SHELL.overview = function () {
    return h('section.view', h('div.stack', { id: 'ov' }, overviewBody()));
  };
  LOAD.overview = function () { loadOverview(false); };

  /* ---- Developer > Health: what the server itself is doing ---- */

  function healthBody() {
    var o = S.overview;
    if (!o) return S.overviewError ? empty(S.overviewError) : loading('Reading the overview…');
    var photos = o.photos;
    var slowest = asList(o.slowest);
    var slowMs = Number(o.slowMs) || 0;
    var t = S.tools;
    return frag(
      S.access.developerHint ? h('p.hint.is-note', String(S.access.developerHint)) : null,
      h('div.tiles',
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
            'data-section': 'changed' }, (Number(o.overrides) > 0 ? num(o.overrides) + ' changed'
              : 'None changed') + ' — open Game rules'),
            Number(o.notApplied) > 0 ? h('span.chip.is-error', num(o.notApplied) + ' not applied') : null),
          h('dt', 'Log rows queued'), h('dd', num(o.auditQueued)))),
        tile('Kill photos', photos ? h('dl.facts',
          h('dt', 'Waiting'), h('dd', num(photos.waiting && photos.waiting.count) + ' · '
            + bytes(photos.waiting && photos.waiting.bytes)),
          h('dt', 'Kept in the app'), h('dd', num(photos.kept && photos.kept.count) + ' · '
            + bytes(photos.kept && photos.kept.bytes)),
          h('dt', 'Served to Photos'), h('dd', num(photos.served && photos.served.count) + ' · '
            + bytes(photos.served && photos.served.bytes)))
          : h('p.note', 'The photo store did not answer.'))),
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
      card('What the diagnosis says', asList(o.warnings).length
        ? h('ul.warnings', asList(o.warnings).map(function (line) { return h('li', String(line)); }))
        : empty('Nothing that wants doing.')),
      card('Diagnosis', frag(
        h('p.about', 'Why the app is not showing something, the server-wide checks, the settings that need '
          + 'attention, and what the console said. Name a player id to run the app\'s own reads as them, or run '
          + 'it from a player\'s card in Players.'),
        h('div.btn-row', field('tl.subject', { class: 'is-short', placeholder: 'Player id', inputmode: 'numeric',
          'data-enter': 'tl-diag', 'aria-label': 'Player id (optional)' }),
          btn('.primary', 'tl-diag', {}, 'Run the diagnosis', 'stethoscope')),
        t.diag && t.diag.error ? answerBox({ ok: false, text: t.diag.error }) : null,
        t.diag ? linesBox(t.diag.lines, t.diag.later) : null)),
      h('p.foot', icon('rotate'), h('span', { id: 'ov-at' }, overviewStamp()),
        ' ', btn('.is-small.ghost', 'ov-refresh', {}, 'Refresh now')));
  }
  SHELL.health = function () { return h('section.view', h('div.stack', { id: 'dg' }, healthBody())); };
  LOAD.health = function () { loadOverview(false); };

  /* ---- contracts ---- */

  DD['ct-state'] = {
    prefix: 'State',
    options: function () {
      return [{ value: 'live', label: 'Live only' }, { value: '', label: 'Any' }].concat(STATE_ORDER.map(function (s) {
        return { value: s, label: STATE_LABEL[s] };
      }));
    },
    value: function () { return S.contracts.state; },
    pick: function (v) { S.contracts.state = v; S.contracts.page = 1; loadContracts(); }
  };
  DD['ct-as'] = {
    prefix: 'Their part',
    options: function () {
      return [{ value: '', label: 'Any' }, { value: 'target', label: PART_LABEL.target },
              { value: 'client', label: PART_LABEL.client }, { value: 'hitman', label: PART_LABEL.hitman }];
    },
    value: function () { return S.contracts.as; },
    pick: function (v) { S.contracts.as = v; S.contracts.page = 1; loadContracts(); }
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
    if (c.person && c.person.ref) data.ref = c.person.ref;
    else if (c.person) data.person = c.person.person;
    if (c.person && c.as) data.as = c.as;
    if (c.byTarget) data.byTarget = true;
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
        // A person no longer found (a lookup gone stale): the list unfiltered.
        if (S.contracts.person && (reply.err === 'stale_lookup' || reply.err === 'not_found')) {
          S.contracts.person = null;
          S.contracts.as = '';
          if (S.section === 'contracts') show('contracts');
        }
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

  var PART_LABEL = { target: 'Target', client: 'Placer', hitman: 'Hitman' };

  function contractRows() {
    var d = S.contracts.data;
    if (!d) return loading('Reading contracts…');
    var rows = asList(d.rows);
    if (!rows.length) return empty(S.contracts.byTarget ? 'No live contract matches.' : 'No contract matches.');
    var c = S.contracts;
    var person = !!c.person;
    var whoisCol = person && canIdentify();
    // One person's: their part in place of the rule and the payouts, as
    // their own list had, so the table still fits a 1280 window.
    var cols = person ? 7 + (whoisCol ? 1 : 0) : 8;
    var out = [], last = null;
    rows.forEach(function (row) {
      if (c.byTarget && row.group !== last) {
        last = row.group;
        out.push(h('tr.tl-group', h('td', { colspan: String(cols) }, icon('crosshairs'), ' ',
          String(row.target || '—'), h('span.sub', ' · ' + num(row.onTarget) + ' live on them'))));
      }
      var id = String(row.id);
      // Relative, to scan down a page of them; the date itself on hover.
      var endAt = row.resolved_at || row.deadline_at;
      var ended = row.resolved_at
        ? String(row.resolution || STATE_LABEL[row.state] || 'ended') + ' · ' + ago(row.resolved_at)
        : (row.deadline_at ? 'due ' + ago(row.deadline_at) : '—');
      out.push(h('tr.row', { 'data-act': 'contract', 'data-id': id, tabindex: '0',
        title: 'Open contract ' + row.id },
        h('td.mono.nowrap', id), h('td', stateChip(row.state),
          row.frozen ? h('span.chip.is-warn.is-frozen', c.byTarget ? 'On hold' : 'Frozen') : null),
        person ? h('td', PART_LABEL[row.role] || String(row.role || '—'),
          row.roleAnonymous ? h('span.chip.is-anon', 'anonymous') : null) : null,
        person ? null : h('td.nowrap', RULE_LABEL[row.rule] || String(row.rule || '—')),
        h('td.name', String(row.target || '—')),
        h('td.name', row.anonymous ? h('span.anon', icon('mask'), ' ', String(row.client || 'Anonymous'))
          : String(row.client || '—')),
        person ? null : h('td.num', num(row.claimed) + ' / ' + num(row.slots)),
        h('td.nowrap', when(row.created_at)), h('td', { title: endAt ? when(endAt) : null }, ended),
        whoisCol ? h('td', btn('.is-small.ghost', 'whois', { 'data-id': id, 'data-where': 'contracts' },
          'Whois', 'user-secret')) : null));
      var who = c.whois[id];
      if (who) out.push(h('tr.more', h('td', { colspan: String(cols) }, whoisBody(who))));
    });
    return h('div.table-wrap', h('table.grid.is-rows',
      h('thead', h('tr', h('th', 'Contract'), h('th', 'State'), person ? h('th', 'Their part') : null,
        person ? null : h('th', 'Rule'), h('th', 'Target'), h('th', 'Client'),
        person ? null : h('th.num', 'Payouts'), h('th', 'Placed'),
        h('th', 'Deadline or end'), whoisCol ? h('th', '') : null)),
      h('tbody', out)));
  }

  function contractPager() {
    var d = S.contracts.data;
    if (!d) return frag();
    var page = Number(d.page) || 1, pages = Number(d.pages) || 1;
    return frag(
      btn('.is-small', 'ct-page', { 'data-value': String(page - 1), disabled: page <= 1 }, 'Previous', 'chevron-left'),
      h('span.pager-text', 'Page ' + page + ' of ' + pages + ' · ' + num(d.total)
        + (S.contracts.byTarget ? ' live contract' : ' contract') + (Number(d.total) === 1 ? '' : 's')
        + (S.contracts.byTarget ? ' on ' + num(d.targets) + ' target' + (Number(d.targets) === 1 ? '' : 's') : '')),
      btn('.is-small', 'ct-page', { 'data-value': String(page + 1), disabled: page >= pages }, 'Next', 'chevron-right'));
  }

  /** Whose contracts the list shows, and their part on them. */
  function contractPerson() {
    var c = S.contracts;
    return h('div.toolbar.ct-person',
      c.person
        ? frag(h('span.chip.is-link.st-chip', icon('user'), ' ', String(c.person.name || 'One person'),
            h('button.st-chip-x', { type: 'button', 'data-act': 'ct-person-clear', title: 'Show everybody\'s',
              'aria-label': 'Show everybody\'s contracts' }, icon('xmark'))),
          dropdown('ct-as'))
        : h('label.search', icon('user'),
          field('ct.who', { id: 'ct-who', placeholder: 'One person: player id, citizen id or name',
            'data-enter': 'ct-person-set', 'aria-label': 'Show one person\'s contracts' })),
      segmented('ct-bytarget', [{ value: 'list', label: 'Newest first' },
        { value: 'bytarget', label: 'Live, by target' }], c.byTarget ? 'bytarget' : 'list'));
  }

  SHELL.contracts = function () {
    return h('section.view',
      h('div.toolbar',
        h('label.search', icon('magnifying-glass'),
          field('ct.q', { id: 'ct-q', placeholder: S.contracts.byTarget ? 'Target name or citizen id'
            : 'Contract id, citizen id or name',
            'data-live': 'ct-search', 'data-enter': 'ct-search-now', 'aria-label': 'Search contracts' })),
        dropdown('ct-state'), dropdown('ct-rule'), dropdown('ct-range'),
        rangeInputs('ct', S.contracts.range, 'ct-search'),
        btn('.ghost', 'ct-clear', {}, 'Clear', 'eraser')),
      contractPerson(),
      h('p.hint', canIdentify()
        ? 'You see who is behind anonymous parties. Every search and every contract you open is on the record.'
        : 'Anonymous placers and operatives show as Anonymous, and a search by citizen id or name never '
          + 'finds a contract through a party who stayed anonymous.'),
      h('div.stack', { id: 'dp-list' }, disposalBody('contracts')),
      h('div.results', { id: 'ct-results' }, contractRows()),
      h('div.pager', { id: 'ct-pager' }, contractPager()));
  };
  LOAD.contracts = function () { loadContracts(); loadDisposal(); };

  /* ---- the contract drawer ---- */

  function openContract(id) {
    if (!id) return;
    // Nothing armed on the contract open before carries over to this one.
    disarm();
    S.drawer = { id: String(id), data: null, answer: null, whois: null, tab: 'summary' };
    // The header's chip reopens it after it is closed, over any section.
    S.ctx.contract = String(id);
    drawContext();
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
    if (was && S.open && shows('stuck')) loadStuck();
  }

  function drawDrawer() {
    var drawer = byId('drawer'), scrim = byId('scrim');
    if (!drawer) return;
    drawer.hidden = !S.drawer.id;
    if (scrim) scrim.hidden = !S.drawer.id;
    if (!S.drawer.id) return;
    setHtml(drawer, drawerBody());
    drawerNeeds();
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

  /* The drawer's tabs, safest first; only the one open is drawn. */
  var DRAWER_TABS = [
    { id: 'summary', label: 'Summary' }, { id: 'money', label: 'Money' }, { id: 'people', label: 'People' },
    { id: 'notes', label: 'Notes & text' }, { id: 'record', label: 'Record' }
  ];

  function drawerBody() {
    var d = S.drawer.data;
    var id = S.drawer.id;
    var c0 = d && d.contract ? d.contract : null;
    var canVoid = !!(d && d.canVoid && !(c0 && c0.neverStored));
    var head = h('header.drawer-head',
      h('div.drawer-title', h('h2', 'Contract ', h('span.mono', id)),
        c0 ? stateChip(c0.state) : null,
        c0 ? h('span.chip', RULE_LABEL[c0.rule] || String(c0.rule || '')) : null,
        d && d.frozen ? h('span.chip.is-warn.is-frozen', { title: 'On hold: frozen by staff ('
          + asList(d.frozen).join(', ') + ')' }, 'Frozen') : null),
      h('div.drawer-tools',
        canVoid ? btn('.ghost.is-small', 'dr-more', { 'aria-expanded': S.drawer.more ? 'true' : 'false',
          title: 'More: void this contract' }, S.drawer.more ? 'Less' : 'More', 'ellipsis') : null,
        btn('.ghost', 'drawer-close', { 'aria-label': 'Close the contract' }, 'Close', 'xmark')));
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
        + 'it to the citizen id of whoever did.')) : null;

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
      return btn('.is-small.ghost', 'party-lookup', { 'data-subject': 'contract:' + id + ':' + role
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

    var escrowCard = card('Escrow lines', escrow.length ? h('div.table-wrap', h('table.grid',
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
      })))) : empty('No escrow lines.'));

    var operatives = card('Operatives', hitmen.length ? h('div.table-wrap', h('table.grid',
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
      })))) : empty('Nobody has taken it.'));

    var proposals = amendments.length ? card('Open proposals', h('ul.plain', amendments.map(function (a) {
      return h('li', h('b', String(a.kind || 'proposal')), ' by ' + String(a.proposer || '—'),
        a.expires_at ? ' · runs out ' + when(a.expires_at) : '',
        a.payload ? h('span.detail', ' ' + detailText(a.payload)) : null);
    }))) : null;

    var staff = d.staff;
    var tab = S.drawer.tab || 'summary';
    if (stub && tab !== 'money' && tab !== 'record') tab = 'money';
    var waiting = stuck ? stuck.length : 0;
    var tabs = h('div.drawer-tabs', { role: 'tablist' }, DRAWER_TABS.filter(function (t) {
      return !stub || t.id === 'money' || t.id === 'record';
    }).map(function (t) {
      var on = t.id === tab;
      return h('button.drawer-tab' + (on ? '.is-on' : ''), { type: 'button', role: 'tab', 'data-act': 'dr-tab',
        'data-value': t.id, 'aria-selected': on ? 'true' : 'false' }, h('span.lbl', t.label),
        t.id === 'money' && waiting > 0 ? h('span.nav-count.is-warn', { title: num(waiting)
          + ' line(s) waiting for staff' }, num(waiting)) : null);
    }));

    var voidForm = canVoid ? h('div.drawer-void', { id: 'dr-void' },
      h('div.inline-form.is-wide',
        field('dr.reason', { class: 'is-grow', placeholder: 'Reason for the void (kept in the log)',
          maxlength: '120', disabled: !modOpen(), 'aria-label': 'Reason for the void' }),
        modBtn('.danger', 'void', {}, 'Void contract', 'Click again to void', 'ban')),
      h('p.note', 'Voiding closes it and refunds what it holds, by the rules every ending follows.')) : null;

    var body;
    if (tab === 'money') {
      body = frag(actions, stuckPart, stub ? null : card('Payouts', slotSummary(escrow, c)),
        staff && !stub ? card('Change reward', rewardBody(d), '.ct-reward') : null, escrowCard);
    } else if (tab === 'people') {
      body = frag(
        canIdentify() ? h('div.drawer-actions', btn('.ghost', 'whois', { 'data-id': id }, 'Whois', 'user-secret'))
          : null,
        whois, operatives,
        staff ? card('Remove an operative', removeBody(d, staff), '.ct-remove') : null,
        staff ? card('Reassign to another hitman', reassignBody(d), '.ct-reassign') : null,
        staff ? card('As a player sees it', playerViewBody(d), '.ct-view') : null);
    } else if (tab === 'notes') {
      body = staff ? frag(card('Staff notes', notesBody(staff), '.ct-notes'),
        card('Edit text', textBody(d, staff), '.ct-text')) : empty('Staff notes and text edits are not available here.');
    } else if (tab === 'record') {
      body = frag(
        staff && !stub ? card('Export the record', exportBody(), '.ct-export') : null,
        card('Timeline', timeline.length ? h('ol.timeline', timeline.map(function (row) {
          return h('li', h('span.time', when(row.ts)), h('span.chip.kind-' + String(row.kind || 'system'), String(row.kind || '')),
            h('b', String(row.action || '')), row.actor ? h('span.sub', ' ' + row.actor) : null,
            h('span.detail', detailText(row.detail)));
        })) : empty('The log keeps nothing for it.')));
    } else {
      body = frag(
        d.canVoid ? null : h('p.note', 'Closed: a closed contract is never voided.'),
        card('Terms', terms), deadlinePart, proposals,
        canVoid && !S.drawer.more ? h('div.btn-row', btn('.is-small.ghost', 'dr-more', {}, 'Void this contract…',
          'ban')) : null);
    }

    return frag(head, S.drawer.more ? voidForm : null, answerBox(S.drawer.answer), tabs,
      h('div.drawer-body', body));
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
    if (shows('stuck')) setHtml(byId('sk-list'), stuckBody());
  }

  function stuckBody() {
    var d = S.stuck.data;
    if (!d) return S.stuck.error ? empty(S.stuck.error) : loading('Reading what waits for staff…');
    if (d.lines === undefined || d.lines === null) return h('p.note', notListed(d.recovery));
    var lines = asList(d.lines);
    if (!lines.length) return empty('No escrow line is waiting for staff.');
    var forYou = lines.filter(function (entry) { return asList(entry.actions).length > 0; }).length;
    return frag(
      h('p.hint', num(forYou) + ' left for you to settle, of ' + num(lines.length) + ' listed. One queued '
        + 'since for whom it is owed, or an ending settling itself within a minute, needs nothing from you. '
        + 'Check what the player has before you settle one: Delivered if it is there, Pay if it is not.'),
      card('Waiting for staff', h('ul.stuck', lines.map(function (entry) {
        return stuckItem(entry, 'stuck');
      })), forYou > 0 ? '.is-warn' : ''));
  }

  /* ---- Home > Inbox: reviews, money waiting and open alerts, one list ----

     What used to be three sub-tabs (Needs review, Stuck escrow and the open
     alerts), with filter chips and a count each. Each part is drawn into
     its own box, and read again only while it shows. */

  /** Whether one of the inbox's parts (or the Alerts view) is on screen. */
  function shows(part) {
    var all = S.section === 'inbox' && S.inbox === 'all';
    if (part === 'reviews') return all || (S.section === 'inbox' && S.inbox === 'reviews');
    if (part === 'stuck') return all || (S.section === 'inbox' && S.inbox === 'stuck');
    if (part === 'alerts') return S.section === 'alerts' || all || (S.section === 'inbox' && S.inbox === 'alerts');
    return false;
  }

  var INBOX_FILTERS = [
    { value: 'all', label: 'Everything', count: 'count-inbox-all' },
    { value: 'reviews', label: 'Needs review', count: 'count-reviews' },
    { value: 'stuck', label: 'Money waiting', count: 'count-stuck' },
    { value: 'alerts', label: 'Alerts', count: 'count-ialerts' }
  ];

  SHELL.inbox = function () {
    var f = S.inbox;
    return h('section.view',
      h('div.toolbar',
        h('div.seg.ib-filters', { role: 'group' }, INBOX_FILTERS.map(function (o) {
          var on = o.value === f;
          return h('button.seg-btn' + (on ? '.is-on' : ''), { type: 'button', 'data-act': 'ib-filter',
            'data-value': o.value, 'aria-pressed': on ? 'true' : 'false' }, o.label,
            o.value === 'all' ? null : h('span.nav-count.is-warn', { id: o.count, hidden: true }));
        })),
        btn('.ghost', 'ib-refresh', {}, 'Refresh', 'rotate')),
      h('p.hint', 'Everything waiting for staff: review items no rule could settle, money left for you to '
        + 'settle, and alerts not acknowledged yet. Nothing waiting? Reviews, stuck money and alerts land here.'),
      shows('reviews') ? h('section.ib-part', h('h3.st-group-title', 'Needs review'),
        h('div.toolbar', segmented('rv-all', [{ value: 'open', label: 'Open' }, { value: 'all', label: 'All (latest 50)' }],
          S.reviews.all ? 'all' : 'open')),
        h('p.hint', 'Money no rule on the server could settle by itself. Resolving an item gives it once, however '
          + 'often it is asked; a role (payer, creator, ...) names a party without unmasking them.'),
        h('div.stack', { id: 'rv-list' }, reviewList())) : null,
      shows('stuck') ? h('section.ib-part', h('h3.st-group-title', 'Money waiting for staff (stuck escrow)'),
        h('div.stack', { id: 'sk-list' }, stuckBody())) : null,
      shows('alerts') ? h('section.ib-part', h('h3.st-group-title', 'Open alerts'),
        h('div.stack', { id: 'al-list' }, alertsBody())) : null,
      S.inbox === 'all' ? h('section.ib-part', h('div.stack', { id: 'dp-list' }, disposalBody('home'))) : null);
  };
  LOAD.inbox = function () {
    loadOverview(false);
    if (shows('reviews')) loadReviews();
    if (shows('stuck')) loadStuck();
    if (shows('alerts')) { S.alerts.state = 'open'; loadAlerts(); }
    if (S.inbox === 'all') loadDisposal();
    drawCounts();
  };

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
    // A Refund or Pay armed for somebody else is no longer what was armed.
    pick: function (v, id) { disarm(); S.forms['rv.' + id + '.who'] = v; }
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
    pick: function (v, id) { disarm(); S.forms['rv.' + id + '.account'] = v; }
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
      if (shows('reviews')) setHtml(byId('rv-list'), reviewList());
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
        writeBtn(action === 'dismiss' ? '' : '.primary', 'resolve',
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
        writeBtn('.primary', 'resolve-finish', { 'data-id': id }, 'Finish as decided',
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

  function drawAlerts() { if (shows('alerts')) setHtml(byId('al-list'), alertsBody()); }

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
      h('div.btn-row', writeBtn('', 'al-test', {}, 'Send a test alert', 'Click again to send it', 'paper-plane', true)),
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
    var inInbox = S.section === 'inbox';
    return frag(
      inInbox ? null : card('Discord', discordBody(d.discord)),
      h('div.toolbar',
        h('span.sub', num(d.open) + ' open · ' + num(d.acknowledged) + ' acknowledged'
          + (rows.length < total ? ' · the newest ' + num(rows.length) + ' shown' : '')),
        open && rows.length && canWrite()
          ? writeBtn('', 'al-ack-all', {}, 'Acknowledge all shown',
            'Click again: acknowledge ' + num(rows.length), 'check-double', true)
          : null),
      answerBox(S.alerts.all),
      rows.length ? rows.map(alertCard)
        : empty(open ? 'No open alerts.' : 'Nothing has been acknowledged yet.'),
      inInbox ? h('p.note', 'Acknowledged ones, Discord and the test alert are in Logs, Alerts.') : null);
  }

  SHELL.alerts = function () {
    return h('section.view',
      h('div.toolbar',
        segmented('al-state', [{ value: 'open', label: 'Open' }, { value: 'acknowledged', label: 'Acknowledged' }],
          S.alerts.state),
        btn('.ghost', 'al-refresh', {}, 'Refresh', 'rotate')),
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
        btn('.ghost', 'cs-refresh', {}, 'Refresh', 'rotate'),
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

  /* Records \u203a Logs: every log staff read, one view, one op (logs), each
     log a filter chip (its area on the server). Each section links to its
     own with that chip picked (a GROUPS entry's logs: 'logs:<filter>'):
     Game rules to Setting changes, Hitman organisation to Org audit, Boss
     permissions to Grant history, Target limits to the audit log's
     staff_target_ rows. The chip last picked stays picked. */
  var LOG_AREAS = [
    { id: 'audit', label: 'Audit log' },
    { id: 'settings', label: 'Setting changes' },
    { id: 'org', label: 'Org audit' },
    { id: 'grants', label: 'Grant history' }
  ];
  /** What each section link sets: the chip, and for Target limits the
      audit log's action filter. */
  var LOG_FILTERS = {
    audit: { area: 'audit' }, settings: { area: 'settings' }, org: { area: 'org' }, grants: { area: 'grants' },
    targets: { area: 'audit', action: 'staff_target_' }
  };
  function logArea() { return S.section === 'logs' ? S.logs.area : null; }
  function logAreaLabel() {
    var a = LOG_AREAS.filter(function (x) { return x.id === S.logs.area; })[0];
    return a ? a.label : 'Audit log';
  }
  function pickLogArea(name) {
    var f = LOG_FILTERS[name];
    if (!f) return;
    S.logs.area = f.area;
    if (f.action !== undefined) {
      ['lg.action', 'lg.contract', 'lg.actor', 'lg.from', 'lg.to'].forEach(function (k) { S.forms[k] = ''; });
      S.forms['lg.action'] = f.action;
      S.logs.kind = '';
      S.logs.range = '';
      S.logs.cursor = null;
      S.logs.back = [];
    }
  }

  /** The audit log: its search, its rows, its pages. */
  function auditLogBody() {
    return frag(
      h('div.toolbar',
        dropdown('lg-kind'),
        field('lg.action', { class: 'is-mid', placeholder: 'Action contains', 'data-live': 'lg-search',
          'data-enter': 'lg-search-now', 'aria-label': 'Action contains' }),
        field('lg.contract', { id: 'lg-contract', class: 'is-mid', placeholder: 'Contract id', 'data-live': 'lg-search',
          'data-enter': 'lg-search-now', 'aria-label': 'Contract id' }),
        field('lg.actor', { id: 'lg-actor', class: 'is-mid', placeholder: 'Citizen id',
          'data-live': 'lg-search', 'data-enter': 'lg-search-now',
          title: canIdentify() ? null : 'Without the identity ACE, only the rows they acted in under their own '
            + 'name: as the target, or a placer or operative who did not stay anonymous.',
          'aria-label': 'Citizen id' }),
        dropdown('lg-range'),
        rangeInputs('lg', S.logs.range, 'lg-search'),
        btn('.ghost', 'lg-clear', {}, 'Clear', 'eraser'),
        h('span.lg-tools', { id: 'lg-tools' }, logToolsBody())),
      h('p.hint', canIdentify()
        ? 'Every row as it was written. Reading the log as you can see it is on the record.'
        : 'Citizen ids show as the party\'s place on the contract (the placer, the target, an operative) and '
          + 'anonymous parties as Anonymous. A citizen id finds only the rows that player acted in under their '
          + 'own name.'),
      h('div.results', { id: 'lg-results' }, logRows()),
      h('div.pager', { id: 'lg-pager' }, logPager()));
  }

  /** The organisation's log and its grant history, as the organisation is. */
  function orgLogBody() {
    var d = S.org.data;
    if (!d) return S.org.error ? empty(S.org.error) : loading('Reading the organisation…');
    if (!d.enabled) {
      return empty('The hitman organisation is off (Config.Organisation.Enabled): it has nothing on the record. '
        + 'Hitman organisation, Setup turns it on.');
    }
    if (!d.loaded) return empty('The organisation has not been read from the store yet: Hitman organisation, Setup.');
    return S.logs.area === 'grants' ? bpHistoryBody() : orgAuditBody();
  }

  SHELL.logs = function () {
    var area = S.logs.area;
    return h('section.view',
      h('div.toolbar', segmented('lg-area', LOG_AREAS.map(function (a) {
        return { value: a.id, label: a.label };
      }), area)),
      area === 'settings' ? settingsLogBody()
        : (area === 'org' || area === 'grants') ? h('div.stack', { id: 'lg-org' }, orgLogBody())
          : auditLogBody());
  };
  LOAD.logs = function () {
    var area = S.logs.area;
    if (area === 'settings') { loadSettingsLog(); return; }
    if (area === 'org' || area === 'grants') {
      var ready = S.org.data ? Promise.resolve() : loadOrg();
      ready.then(function () {
        if (logArea() !== area || !orgOn()) return;
        loadOrgAudit(area === 'grants' ? 'org_grant' : S.org.auditAction);
      });
      return;
    }
    loadLogs();
  };

  /* ---- players ---- */

  /** Look up who the box names; or, `again` after a write, read the same
      player's card again by the handle the lookup gave, whatever the box
      says now. */
  function loadPlayer(again) {
    var subject = trim(S.forms['pl.q']);
    var byRef = again === true && S.players.ref ? S.players.ref : null;
    if (!subject && !byRef) { toast('Give a player id, a citizen id or a name.', 'error'); return Promise.resolve(); }
    // Nothing armed on the card before carries over to who is read now.
    disarm();
    S.players.playtime = null;
    S.players.freeze = null;
    resetPlayerStaff();
    var sent = byRef ? { ref: byRef } : { subject: subject.slice(0, 64) };
    return ask('player', sent, 'player').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { toast(words(reply), 'error'); S.players.data = { error: words(reply) }; }
      else S.players.data = reply.data || {};
      // Every write from the card names the player by the handle this
      // lookup gave (bound on the server to the character it found), never
      // by what was typed: a name or a player id can name somebody else by
      // the time of the click.
      var found = reply.ok && reply.data && reply.data.player;
      S.players.ref = found && typeof found.ref === 'string' ? found.ref : null;
      S.players.subject = reply.ok ? (byRef ? S.players.subject : subject.slice(0, 64)) : null;
      // The handle runs out ten minutes after this lookup; the header's chip
      // counts it down. A lookup again by the handle is a new ten minutes.
      S.players.at = reply.ok ? Date.now() : 0;
      if (found && !byRef) rememberLookup(subject.slice(0, 64), found);
      // A selected player's tab with nobody selected any more: Find.
      if (PERSON_VIEWS[S.section] && !hasPlayer()) { show('players'); return; }
      drawChrome();
      if (PLAYER_VIEWS[S.section]) setHtml(byId('pl-result'), playerBody());
      // Their history only on its own tab, as it opens.
      if (reply.ok && S.section === 'phistory') loadPlayerHistory();
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
        writeBtn('.ghost', 'pl-playtime-reset', {}, 'Reset to 0', 'Click again to reset', 'arrow-rotate-left', true)),
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
        : modBtn('.danger', 'pl-freeze', {}, 'Freeze', 'Click again to freeze', 'snowflake'));
    var about = frozen
      ? frag(h('p.sub', 'Frozen ' + ago(frozen.since) + (frozen.reason ? ': ' + String(frozen.reason) : '')
          + (frozen.by ? ' · by ' + String(frozen.by) : '')),
        h('p.note', 'Every live contract they are party to is on hold: its clocks stopped, and nothing '
          + 'on it is accepted, paid, refunded or ended. Unfreeze gives the time on hold back.'))
      : h('p.note', 'Freezing puts every live contract they are party to on hold, as the target, the '
          + 'placer or an operative: its clocks stop and nothing on it moves until you unfreeze them. '
          + 'Players are told only that it is on hold by staff.');
    return card('Freeze', frag(about, form, answerBox(S.players.freeze)), '',
      frozen ? h('span.chip.is-warn.is-frozen', 'Frozen') : null);
  }

  /** Every player staff have frozen, with Unfreeze on each row. */
  /** The last few lookups, to go back to one with a click. */
  var RECENT_MAX = 6;
  function rememberLookup(subject, found) {
    var list = S.players.recent.filter(function (r) { return r.subject !== subject; });
    list.unshift({ subject: subject, name: String(found.name || subject) });
    S.players.recent = list.slice(0, RECENT_MAX);
  }

  /** Who is selected, above every one of their tabs. */
  function personHead(d) {
    var p = d.player || {};
    return h('div.person',
      h('h2', String(p.name || 'No name on record')),
      p.cid ? h('span.cid', String(p.cid)) : h('span.chip', 'citizen id hidden'),
      p.online ? h('span.chip.is-live', 'in the city · player ' + String(p.server)) : h('span.chip', 'offline'),
      d.frozen ? h('span.chip.is-warn.is-frozen', 'Frozen') : null,
      d.suspended ? h('span.chip.is-warn.is-suspended', 'Suspended') : null,
      d.protected ? h('span.chip.is-protected', 'Protected') : null);
  }

  /** The person tabs, as buttons under their summary. */
  function personLinks() {
    // Their contracts: the one list of contracts, filtered to them.
    return h('div.btn-row.person-links',
      btn('.is-small.ghost', 'pl-contracts', {}, 'Their contracts', 'file-contract'),
      Object.keys(PERSON_VIEWS).map(function (view) {
        return btn('.is-small.ghost', 'section', { 'data-section': view }, VIEW_LABEL[view][0], VIEW_LABEL[view][1]);
      }));
  }

  function summaryBody(d) {
    var stats = d.stats;
    return frag(
      personHead(d),
      personLinks(),
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
      h('div.tiles.is-compact',
        tile('Contracts', h('p.big', num(asList(d.contracts).length))),
        tile('Owed to them', h('p.big', num(asList(d.owed).length))),
        tile('Playtime', h('p.big', d.playtime && !d.playtime.unread ? num(d.playtime.hours) + ' h' : '—'))));
  }

  function moneyBody(d) {
    var owed = asList(d.owed);
    var notices = d.notices || {};
    return frag(
      payCard(d),
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
          : empty('None waiting.'), '', h('span.sub', num(notices.count)))));
  }

  function measuresBody(d) {
    return frag(
      freezeCard(d.frozen),
      h('div.cols', suspendCard(d), protectCard(d)),
      card('Target limits', frag(
        h('p.about', 'How often a contract may be placed on them: their cooldown, their counts, their own limits '
          + 'or an exemption, exactly, with Reset, Extend and Exempt.'),
        d.limit ? h('p.note', (d.limit.exempt ? 'Exempt from the target limits' : 'Target limits of their own')
          + ' since ' + when(d.limit.since) + (d.limit['until'] ? ', until ' + when(d.limit['until']) : ', for good')
          + (d.limit.reason ? ': ' + String(d.limit.reason) : '.')) : null,
        h('div.btn-row', btn('.is-small', 'pl-tl', {}, 'Open them in Target limits', 'user-clock')))));
  }

  /** Why can't they see...: the diagnosis, run as the player selected. */
  function playerDiagBody(d) {
    var t = S.tools;
    var mine = t.pdiag && t.pdiag.ref === S.players.ref ? t.pdiag : null;
    var online = d.player && d.player.online;
    return card('Why can’t they see…', frag(
      h('p.about', 'Runs the app\'s own reads as them: why a contract, the board or a feature is not showing, '
        + 'with the server-wide checks. They have to be in the city.'),
      h('div.btn-row', btn('.primary', 'pl-diag', { disabled: !online || null,
        title: online ? null : 'They are not in the city now' }, 'Run the diagnosis as them', 'stethoscope')),
      // Only the diagnosis run for the player shown (by the lookup's handle),
      // never one run for somebody looked up before.
      mine && mine.error ? answerBox({ ok: false, text: mine.error }) : null,
      mine && !mine.error ? linesBox(mine.lines, mine.later) : null));
  }

  function findBody() {
    var recent = S.players.recent;
    return frag(
      h('div.toolbar',
        h('label.search', icon('magnifying-glass'),
          field('pl.q', { id: 'pl-q', placeholder: 'Player id, citizen id or name', 'data-enter': 'pl-lookup',
            'aria-label': 'Player id, citizen id or name' })),
        btn('.primary', 'pl-lookup', {}, 'Look up', 'arrow-right')),
      recent.length ? h('div.chips.recent', h('span.sub', 'Recent:'), recent.map(function (r) {
        return h('button.chip.is-link', { type: 'button', 'data-act': 'pl-recent', 'data-value': r.subject },
          r.name);
      })) : null,
      h('p.hint', canIdentify()
        ? 'You see every contract they were party to, anonymous ones included. Each lookup is on the record.'
        : 'Contracts they placed or took anonymously are left out, with what they are owed, the deliveries '
          + 'and the notices on them, and so is their record, which counts them.'));
  }

  function playerBody() {
    var d = S.players.data;
    if (!d) return empty('Look someone up by player id, citizen id or name.');
    if (d.error) return empty(d.error);
    switch (S.section) {
      case 'pmeasures': return frag(personHead(d), measuresBody(d));
      case 'pmoney': return frag(personHead(d), moneyBody(d));
      case 'pplaytime': return frag(personHead(d), playtimeCard(d.playtime));
      case 'phistory': return frag(personHead(d), historyCard());
      case 'pdiag': return frag(personHead(d), playerDiagBody(d));
      default: return summaryBody(d);
    }
  }

  SHELL.players = function () {
    return h('section.view', findBody(), h('div.stack', { id: 'pl-result' }, playerBody()));
  };
  LOAD.players = function () {};
  Object.keys(PERSON_VIEWS).forEach(function (view) {
    SHELL[view] = function () { return h('section.view', h('div.stack', { id: 'pl-result' }, playerBody())); };
    LOAD[view] = function () {
      if (view === 'phistory') loadPlayerHistory();
      if (view === 'pdiag') S.tools.pdiag = null;
    };
  });

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
    if ((list === 'features' || list === undefined) && entry.kind === 'switch') return 'features';
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
    if (typeof value === 'number') {
      var span = spanOf(entry, value);
      if (span) return num(value) + span;
      var unit = unitOf(entry);
      return unit === '$' ? '$' + num(value) : num(value) + unit;
    }
    return String(value);
  }

  /** The unit a number setting is counted in, from its key: ' s', ' ms',
      ' min', ' h', ' d', ' m' (metres), '%', ' ×' or '$'; '' for a plain
      count. Every number the panel shows carries it. */
  var MONEY_KEY = /(Cost|Fee|MinReward|MaxReward|MaxAmount|AbsoluteMax|MaxContractValue|MinContractReward|PaymentMax|MaxCost)$|^Sources\.(cash|bank|dirty)\.max$/;
  function unitOf(entry) {
    var key = String((entry && entry.key) || '');
    if (MONEY_KEY.test(key)) return '$';
    if (/Ms$/.test(key)) return ' ms';
    if (/Seconds$/.test(key)) return ' s';
    if (/Minutes$/.test(key)) return ' min';
    if (/Hours$/.test(key)) return ' h';
    if (/Days$/.test(key)) return ' d';
    if (/(Radius|Meters|Metres|Distance)$/.test(key)) return ' m';
    if (/(Percent|percent)$/.test(key)) return '%';
    if (/Multiplier$/.test(key)) return ' \u00d7';
    return '';
  }
  /** For the tests. */
  window.CH_ADMIN_UNIT_OF = unitOf;

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
  var SCHEMA_FIELDS = ['group', 'label', 'about', 'category', 'money', 'area', 'shipped', 'hasShipped',
    'kind', 'choices', 'min', 'integer', 'live', 'inflight', 'readonly', 'destroys', 'stricter',
    'strict', 'whole', 'default'];
  var settingsSchema = null; // { hash, rows: { [key]: fixed parts } }
  /** What else redraws when the settings arrive (Organisation, Locations,
      Boss permissions' limits, the header search). */
  var AFTER_SETTINGS = [];
  /** The header search's index of the settings, built once per reply. */
  var settingsIndex = null;

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
      settingsIndex = null;
      if (SETTING_VIEWS[S.section]) drawSettings();
      // The other views that show settings rows, and the header search.
      AFTER_SETTINGS.forEach(function (fn) { fn(); });
    });
  }

  function drawSettings() {
    // A row asked for (a help link, the header search): its area, its
    // details open.
    var want = S.settings.focus && settingEntry(S.settings.focus);
    if (want && S.section === 'rules') {
      S.rules.area = areaOf(want);
      S.rules.type = '';
      S.forms['st.q'] = '';
      S.settings.open[want.key] = true;
    }
    setHtml(byId('st-head'), settingsHead());
    setHtml(byId('st-list'), settingsList());
    drawCrumbs();
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
                'aria-checked': on ? 'true' : 'false', 'aria-label': entry.label, 'data-confirm': 'yes' };
      if (!open || busy) { a.disabled = true; a.title = whyNoWrite() || null; }
      return h('button.switch' + (on ? '.is-on' : ''), a, h('span.knob'), h('span.lbl', on ? 'On' : 'Off'),
        h('span.cfm', 'Click again: turn ' + (on ? 'Off' : 'On')));
    }
    if (entry.kind === 'choice') {
      return segmented('st-choice', asList(entry.choices).map(function (c) {
        return { value: c, label: String(c), disabled: !open, title: whyNoWrite(),
                 confirm: 'Click again: ' + String(c) };
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
          writeBtn('.is-small' + (changed ? '.primary' : ''), 'st-list-save',
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
      entry.kind === 'number' && trim(unitOf(entry)) ? h('span.st-unit', trim(unitOf(entry))) : null,
      writeBtn('.is-small', 'st-save', { 'data-key': key, id: 'st-save-' + key }, 'Save',
        'Click again to save', 'check', false, open),
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

  /** A row's type, for its chip and Game rules' filter: Switch, Timer,
      Money, Limit or List. */
  function typeOf(entry) {
    if (entry.kind === 'switch') return 'switch';
    if (entry.kind === 'list') return 'list';
    if (entry.money || entry.category === 'rules-rewards' || unitOf(entry) === '$') return 'money';
    if (entry.category === 'rules-timers' || /(Seconds|Minutes|Hours|Days|Ms)$/.test(String(entry.key))) return 'timer';
    return 'limit';
  }
  var TYPE_LABEL = { switch: 'Switch', timer: 'Timer', money: 'Money', limit: 'Limit', list: 'List' };

  /* A setting's row, compact: its label (with its unit), its control and
     Save or Reset, and the chips that matter. Details shows the key, what
     it does, what happens to things under way, and where its value comes
     from; anything that warns (it deletes, it is stricter, it is not
     applied) stays outside Details. */
  function settingInner(entry) {
    var key = entry.key;
    var answer = S.settings.answers[key];
    var overridden = entry.source === 'panel';
    var hasShipped = entry.hasShipped === true || (entry.hasShipped === undefined && entry.shipped !== undefined);
    var offDefault = !entry.readonly && hasShipped && !sameValue(entry.value, entry.shipped);
    var open = !!S.settings.open[key];
    var unit = trim(unitOf(entry));
    return frag(
      h('div.st-main',
        h('p.st-title', h('b', String(entry.label || key)),
          unit && entry.kind === 'number' && String(entry.label || '').indexOf('(') === -1
            ? h('span.st-unit-label', ' (' + unit + ')') : null,
          h('span.chip.st-type.is-' + typeOf(entry), TYPE_LABEL[typeOf(entry)]),
          overridden ? h('span.chip.is-panel', 'changed from the panel') : null,
          entry.live === false ? h('span.chip.is-warn.is-restart', 'applies after restart') : null,
          entry.ignored ? h('span.chip.is-error', 'not applied') : null,
          entry.inactive ? h('span.chip.is-warn', 'does not apply now') : null,
          entry.denied ? h('span.chip', 'edit in config.lua') : null),
        // A key whose switch is off (the catalogue's `needs`): said beside
        // it, so a staff member is not left changing something that does
        // nothing.
        entry.inactive ? h('p.st-about.is-warn', String(entry.inactive)) : null,
        entry.readonly ? h('p.st-about.is-warn', String(entry.readonly)) : null,
        entry.destroys && !entry.readonly
          ? h('p.st-about.is-warn', 'Lowering it deletes for good, so saving a lower value takes two clicks.') : null,
        entry.stricter && !entry.readonly
          ? h('p.st-about.is-warn', 'Making it stricter refuses players at once, so it takes two clicks.') : null,
        entry.ignored ? h('p.st-about.is-error', 'The store holds a value that was not applied at start: '
          + String(entry.ignored) + '. config.lua\'s is in force; reset it to clear this.') : null,
        entry.unknown ? h('p.st-about.is-error', 'A change to it raised in the store, and so did reading it '
          + 'back (' + String(entry.unknown) + '): the store may or may not hold it. What is shown is in '
          + 'force; set or reset it again to settle it.') : null,
        h('button.link.st-more', { type: 'button', 'data-act': 'st-details', 'data-key': key,
          'aria-expanded': open ? 'true' : 'false' }, open ? 'Details ▾' : 'Details ▸'),
        h('div.st-details', { hidden: !open },
          h('code.st-key', entry.secret ? 'server.cfg' : 'Config.' + key),
          entry.about ? h('p.st-about', String(entry.about)) : null,
          entry.inflight ? h('p.st-inflight', h('b', 'Under way: '), String(entry.inflight)) : null,
          entry.readonly ? null : h('p.st-source', 'Now: ' + describe(entry, entry.value)
            + ' · config.lua: ' + describe(entry, entry.default)
            + (hasShipped ? ' · default: ' + describe(entry, entry.shipped) : '')
            + (overridden ? ' · in force from the panel' + (entry.by ? ', set by ' + entry.by : '')
              + (entry.at ? ' ' + ago(entry.at) : '') : ' · in force from config.lua'))),
        answerBox(answer),
        key === 'Completion.KillPhotos' ? keptPhotosPart(entry) : null),
      // A read-only key too, when the store holds a value for it that was
      // not applied (kept from a version where it could be changed): the
      // reset takes that row away, and nothing in force moves.
      h('div.st-control', settingControl(entry),
        entry.ignored || entry.unknown || (overridden && !entry.readonly)
          ? writeBtn('.is-small.ghost', 'st-reset', { 'data-key': key }, 'Reset to config.lua',
            'Click again to reset', 'arrow-rotate-left', false, settingOpen(entry)) : null,
        offDefault ? writeBtn('.is-small.ghost', 'st-default', { 'data-key': key }, 'Reset to default',
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
      h('div.btn-row', writeBtn('.danger.is-small', 'st-remove-photos', {},
        'Remove the ' + num(n) + ' ' + photos + ' kept from before',
        'Click again: remove ' + num(n) + ' ' + photos + ' for good', 'trash-can', true)),
      answerBox(answer));
  }

  function settingRow(entry) {
    return h('div.st-row' + (entry.source === 'panel' ? '.is-panel' : '') + (entry.ignored ? '.is-ignored' : ''),
      { id: 'st-row-' + entry.key, 'data-key': entry.key, 'data-area': areaOf(entry) },
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
    tldefaults: 'How often one person may have a contract placed on them: the waits and caps every target has, '
      + 'unless their job (Per job) or staff (Per player) give them their own. 0 is off where it says so.',
    features: 'The on and off switches. Every switch takes effect at once and is kept across restarts. What is '
      + 'already under way finishes under the rules it started with; only new actions are refused, and players '
      + 'are told the feature is turned off by the server.',
    devsettings: 'Debug, storage, rate limits, timings and the values only config.lua changes. Rate limits are '
      + 'not caps: a stricter one refuses players at once, so it takes two clicks and says what it refuses.'
  };

  /** Rewards & money, in these groups (the catalogue's `money`). */
  var MONEY_ORDER = ['Rewards', 'Payouts', 'Buyouts', 'Intel prices', 'Anonymity fees', 'Escrow'];
  /** Features, in the README's and config.lua's order: the core switches
      first (in the catalogue's order), then Anonymity, Intel (its other
      groups after these four), the Advisory, Staff tools, Roleplay and
      Improvements. */
  var FEATURE_AREAS = [
    ['Anonymity', 'Anonymity (whitelisted-job targets)'],
    ['Intel: Informants', 'Intel: Informant tip', 'Intel: Every other target', 'Intel: Whitelisted-job targets'],
    // A character's record (server/record/), one screen group.
    ['Record: Progression', 'Record: Reputation', 'Record: Tiered board', 'Record: Hitman heat',
      'Record: Placer record'],
    ['Law enforcement advisory'],
    ['Staff tools']
  ];
  /** Where a Features group sorts: 0 for the core, then by area; a group's
      place inside its area as a fraction. */
  function featureRank(group) {
    var g = String(group);
    for (var i = 0; i < FEATURE_AREAS.length; i++) {
      var at = FEATURE_AREAS[i].indexOf(g);
      if (at !== -1) return i + 1 + at / 10;
    }
    // Every other Intel group (server/intel/): after the area's four.
    if (g.indexOf('Intel: ') === 0) return 2.5;
    if (g.indexOf('Roleplay: ') === 0) return FEATURE_AREAS.length + 1;
    if (g.indexOf('Improvements: ') === 0) return FEATURE_AREAS.length + 2;
    return 0;
  }
  /** For the tests. */
  window.CH_ADMIN_FEATURE_RANK = featureRank;
  var GROUP_INTRO = {
    'Anonymity': 'Whether a contract may be placed or accepted anonymously, and whether a target sees an '
      + 'operative\'s name.',
    'Anonymity (whitelisted-job targets)': 'The same, for the other target class: where the target is on a whitelisted job.',
    'Intel: Informants': 'The paid look-ups: the target\'s (who is after me) and the placer\'s (who took it), and their '
      + 'master switch.',
    'Intel: Informant tip': 'The hitman\'s paid tip on the target\'s rough area, and whether the target is told.',
    'Intel: Every other target': 'Whether each informant feature is offered on a target not on a whitelisted job.',
    'Intel: Whitelisted-job targets': 'Whether each informant feature is offered on a whitelisted-job target.',
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
    'Record: Progression': 'Criminal trust for completed contracts.',
    'Audit and debug': 'What the log keeps, and alerts to Discord.',
    'Staff tools': 'Pausing the whole app for an event, and the daily summary to the staff Discord.',
    'Staff alerts': 'When one player or one target goes past a threshold, one staff alert, and on Discord too.',
    'Contract limits': 'How long contracts run and how many a player may place, take or carry.',
    'Target limits': 'The waits and caps on one person being targeted, by default. A job or a player may have their own.',
    'Server restart': 'How contracts pause before a txAdmin restart, and how long that pause may last.',
    'Ledger': 'What a player\'s Ledger keeps, and for how long.',
    'Immunity': 'Who cannot be a target yet: new characters and players just online.',
    'Payouts': 'How many times a contract pays, and how owed payouts are retried.',
    'Intel prices': 'What each informant look-up and tip costs, and which account pays.',
    'Anonymity fees': 'What staying anonymous costs the placer and the hitman.',
    'Escrow': 'What a reward may never hold, and the stake a hitman may be asked for.',
    'Buyout pricing': 'What a target pays to buy a contract out.',
    'Staff': 'Limits on what staff may do from this panel.',
    'Contract reasons': 'What a placer must give as a reason, and what is refused.',
    'Advisory job lists': 'Which jobs raise a police advisory, and which jobs are told.',
    'Barred jobs': 'Jobs that may not use the app.',
    'Storage': 'Where contracts and money are kept. Read only: changed in config.lua.',
    'Diagnostics': 'What the console says about slow jobs.',
    'Rate limits': 'How often each player may send each request.',
    'Staff commands': 'The names of the staff commands.',
    'Other scripts': 'Which of your other scripts each kind of feature uses (inventory, dispatch, phone and the rest), or none.',
    'Edit in config.lua': 'Settings this panel never changes: edit config.lua and restart.',
    'Kept in the store, not on this list': 'Panel changes for keys this version does not have; Reset all clears them.',
    'Other': 'Settings not in any group above.'
  };

  /* ---- Game rules: by feature area, not by type ----

     Every rules and features setting under the area of the game it is
     about (the catalogue's `area`), the area's switches first, then its
     numbers, lists and choices in their groups, each row with its type.
     Filter chips narrow it to Switches, Timers, Money, Limits, Lists or
     what was changed from the panel; across every area when none is
     picked. Target limits, the organisation's and the Developer section's
     own settings are in their sections, and the lists of places in
     Locations. */

  var AREAS = [
    { id: 'access', label: 'Who can use the app', icon: 'door-open' },
    { id: 'placing', label: 'Placing contracts', icon: 'file-signature' },
    { id: 'anonymity', label: 'Anonymity', icon: 'mask' },
    { id: 'rewards', label: 'Rewards & payouts', icon: 'sack-dollar' },
    { id: 'completing', label: 'Completing a contract', icon: 'flag-checkered' },
    { id: 'buyouts', label: 'Buyouts', icon: 'hand-holding-dollar' },
    { id: 'intel', label: 'Intel', icon: 'user-secret' },
    { id: 'record', label: 'Record & standing', icon: 'star' },
    { id: 'police', label: 'Police & city news', icon: 'shield-halved' },
    { id: 'messages', label: 'Phone messages & notifications', icon: 'comment' },
    { id: 'extras', label: 'Roleplay extras', icon: 'masks-theater' },
    { id: 'staff', label: 'Staff tools & alerts', icon: 'user-shield' },
    { id: 'other', label: 'Other', icon: 'ellipsis' }
  ];
  var AREA_ELSEWHERE = { targets: 'Target limits', organisation: 'Hitman organisation', engine: 'Developer' };
  function areaLabel(id) {
    for (var i = 0; i < AREAS.length; i++) if (AREAS[i].id === id) return AREAS[i].label;
    return AREA_ELSEWHERE[id] || String(id || 'Other');
  }
  window.CH_ADMIN_AREAS = AREAS;
  /** An entry's area: the server's, else Other. */
  function areaOf(entry) {
    var a = entry && entry.area ? String(entry.area) : 'other';
    return a;
  }
  /** The settings that are places (the server marks each with its kind of
      place: point, zone, district, area, name, jail), edited in Locations. */
  function placeOf(entry) { return entry && entry.place ? String(entry.place) : ''; }
  /** The section a setting is edited in. */
  function viewOfSetting(entry) {
    if (placeOf(entry)) return 'locations';
    var cat = categoryOf(entry);
    if (cat === 'organisation') {
      return String(entry.group || '').indexOf('Boss limits') !== -1 ? 'bplimits' : 'orgsetup';
    }
    return CATEGORY_VIEW[cat] || 'rules';
  }
  function inRules(entry) { return viewOfSetting(entry) === 'rules'; }

  var TYPE_FILTERS = [{ value: '', label: 'All' }, { value: 'switch', label: 'Switches' },
    { value: 'timer', label: 'Timers' }, { value: 'money', label: 'Money' }, { value: 'limit', label: 'Limits' },
    { value: 'list', label: 'Lists' }, { value: 'changed', label: 'Changed' }];
  /** Search shows at most this many rows, rather than drawing everything. */
  var SEARCH_ROWS = 50;

  function typeHit(entry, type) {
    if (!type) return true;
    if (type === 'changed') return entry.source === 'panel' || !!entry.ignored || !!entry.unknown;
    return typeOf(entry) === type;
  }
  function textHit(entry, q) {
    if (!q) return true;
    return [entry.key, entry.label, entry.about, entry.group, entry.money, areaLabel(areaOf(entry))]
      .map(function (v) { return v == null ? '' : String(v); }).join(' ').toLowerCase().indexOf(q) !== -1;
  }

  function settingsHead() {
    var d = S.settings.data;
    var overrides = d ? Number(d.overrides) || 0 : 0;
    var view = S.section;
    var undoAll = overrides > 0 || (d && Number(d.stored) > 0) ? writeBtn('.danger.is-small', 'st-reset-all', {},
      'Undo all panel changes', 'Click again: back to config.lua', 'arrow-rotate-left') : null;
    if (view === 'changed') {
      return frag(h('span.sub', num(overrides) + ' changed from the panel'
        + (d && Number(d.notApplied) > 0 ? ', ' + num(d.notApplied) + ' kept and not applied' : '')),
        // Whenever the store holds a row, applied or not: one not applied (a
        // key from another version among them) is cleared by it too.
        undoAll);
    }
    return frag(
      h('label.search', icon('magnifying-glass'),
        field('st.q', { id: 'st-q', placeholder: view === 'rules' ? 'Filter by name, key or description'
          : 'Search by name, key, description or group', 'data-live': 'st-filter', 'aria-label': 'Filter the settings' })),
      view === 'rules' ? h('div.seg.gr-types', { role: 'group' }, TYPE_FILTERS.map(function (o) {
        var on = o.value === S.rules.type;
        return h('button.seg-btn' + (on ? '.is-on' : ''), { type: 'button', 'data-act': 'gr-type',
          'data-value': o.value, 'aria-pressed': on ? 'true' : 'false' }, o.label);
      })) : null,
      h('span.sub', num(overrides) + ' changed from the panel'
        + (d && Number(d.notApplied) > 0 ? ', ' + num(d.notApplied) + ' kept and not applied' : '')),
      view === 'rules' ? null : undoAll);
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

  /** The rows of one settings view: its category's, and for Game rules
      the area chosen (or every area, with a type filter or a search). */
  function settingRowsFor(view) {
    var d = S.settings.data || {};
    var out = [];
    ['features', 'limits', 'readonly'].forEach(function (list) {
      asList(d[list]).forEach(function (entry) {
        if (view === 'changed') {
          if (typeHit(entry, 'changed')) out.push(entry);
        } else if (view === 'rules') {
          if (inRules(entry)) out.push(entry);
        } else if (CATEGORY_VIEW[categoryOf(entry, list)] === view) {
          out.push(entry);
        }
      });
    });
    return out;
  }

  /** Groups in their order, each with its rows. In Game rules, a group
      with a switch comes first (in the README's order of features), and in
      each group its switches lead. */
  function grouped(list, view) {
    var groups = [], byGroup = {};
    list.forEach(function (entry) {
      var g = String(entry.group || 'Other');
      if (!byGroup[g]) { byGroup[g] = []; groups.push(g); }
      byGroup[g].push(entry);
    });
    var seq = {};
    groups.forEach(function (g, i) { seq[g] = i; });
    if (view === 'rules') {
      var hasSwitch = {};
      groups.forEach(function (g) {
        hasSwitch[g] = byGroup[g].some(function (e) { return e.kind === 'switch'; });
        byGroup[g] = byGroup[g].map(function (e, i) { return { e: e, i: i }; }).sort(function (a, b) {
          return ((a.e.kind === 'switch' ? 0 : 1) - (b.e.kind === 'switch' ? 0 : 1)) || (a.i - b.i);
        }).map(function (x) { return x.e; });
      });
      groups.sort(function (a, b) {
        return ((hasSwitch[a] ? 0 : 1) - (hasSwitch[b] ? 0 : 1)) || (featureRank(a) - featureRank(b)) || (seq[a] - seq[b]);
      });
    } else {
      groups.sort(function (a, b) { return seq[a] - seq[b]; });
    }
    return { groups: groups, byGroup: byGroup };
  }

  function groupSection(g, rows) {
    return h('section.st-group', { 'data-group': g.toLowerCase() }, h('h3.st-group-title', g),
      GROUP_INTRO[g] ? h('p.st-group-about', GROUP_INTRO[g]) : null,
      rows.map(settingRow));
  }

  /** Game rules' list of areas, each with how many rows it holds now. */
  function areaNav(all) {
    var counts = {}, changed = {};
    all.forEach(function (e) {
      var a = areaOf(e);
      if (typeHit(e, S.rules.type)) counts[a] = (counts[a] || 0) + 1;
      if (typeHit(e, 'changed')) changed[a] = (changed[a] || 0) + 1;
    });
    var total = 0;
    Object.keys(counts).forEach(function (a) { total += counts[a]; });
    return h('nav.gr-areas', { 'aria-label': 'Areas' },
      h('button.gr-area' + (!S.rules.area ? '.is-on' : ''), { type: 'button', 'data-act': 'gr-area', 'data-value': '' },
        icon('layer-group'), h('span.lbl', 'All areas'), h('span.gr-n', num(total))),
      AREAS.filter(function (a) { return counts[a.id] || (!S.rules.type && a.id !== 'other'); }).map(function (a) {
        return h('button.gr-area' + (S.rules.area === a.id ? '.is-on' : ''), { type: 'button', 'data-act': 'gr-area',
          'data-value': a.id }, icon(a.icon), h('span.lbl', a.label), h('span.gr-n', num(counts[a.id] || 0)),
          changed[a.id] ? h('span.chip.is-panel', num(changed[a.id]) + ' changed') : null);
      }));
  }

  function rulesList() {
    var all = settingRowsFor('rules');
    var q = trim(S.forms['st.q']).toLowerCase();
    var type = S.rules.type;
    var area = S.rules.area;
    var rows = all.filter(function (e) {
      return (!area || areaOf(e) === area) && typeHit(e, type) && textHit(e, q);
    });
    var body;
    if (!area && !type && !q) {
      // Every area at once would be hundreds of rows: pick one.
      body = h('div.cards-grid.gr-pick', AREAS.filter(function (a) {
        return all.some(function (e) { return areaOf(e) === a.id; });
      }).map(function (a) {
        var mine = all.filter(function (e) { return areaOf(e) === a.id; });
        var switches = mine.filter(function (e) { return e.kind === 'switch'; }).length;
        return h('button.card.gr-card', { type: 'button', 'data-act': 'gr-area', 'data-value': a.id },
          h('span.gr-card-title', icon(a.icon), ' ', a.label),
          h('span.sub', num(mine.length) + ' settings · ' + num(switches) + ' switch' + (switches === 1 ? '' : 'es')));
      }));
    } else if (!rows.length) {
      body = empty(q ? 'No setting matches; clear the filter.' : 'Nothing here with this filter.');
    } else {
      var shown = rows.slice(0, q ? SEARCH_ROWS : rows.length);
      var gr = grouped(shown, 'rules');
      body = frag(
        rows.length > shown.length ? h('p.note', 'The first ' + num(shown.length) + ' of ' + num(rows.length)
          + ' matches; type more to narrow it.') : null,
        gr.groups.map(function (g) { return groupSection(g, gr.byGroup[g]); }));
    }
    var memory = S.overview && S.overview.storage === 'memory';
    return h('div.gr',
      areaNav(all),
      h('div.gr-rows',
        h('p.hint', 'Every setting under the area of the game it is about, its switches first. Every change takes '
          + 'effect at once and ' + (memory ? 'lasts until the resource stops: this server runs in memory mode, which '
          + 'keeps nothing across a restart' : 'is kept across restarts') + '; what is already under way finishes '
          + 'under the rules it started with.'),
        body));
  }

  function settingsList() {
    var d = S.settings.data;
    if (!d) return loading('Reading the settings…');
    var view = S.section;
    if (view === 'rules') return rulesList();
    var q = trim(S.forms['st.q']).toLowerCase();
    var list = settingRowsFor(view).filter(function (e) { return view === 'changed' || textHit(e, q); });
    if (view === 'changed') {
      if (!list.length) return empty('Nothing is changed from the panel: every setting is what config.lua says.');
      var gc = grouped(list, 'changed');
      return frag(h('p.hint', 'Every setting changed from this panel, wherever it lives. Undo all panel changes '
        + 'puts every one back to config.lua; each row\'s Reset puts back one.'),
        gc.groups.map(function (g) { return groupSection(g, gc.byGroup[g]); }));
    }
    var buckets = view === 'devsettings' ? mapBuckets(list) : [];
    var inMap = {};
    buckets.forEach(function (b) { inMap['Cooldowns.' + b + '.per'] = inMap['Cooldowns.' + b + '.burst'] = true; });
    var gr = grouped(list.filter(function (e) { return !inMap[e.key]; }), view);
    var intro = VIEW_INTRO[view] || '';
    var note = view === 'devsettings' && S.access.developerHint ? h('p.hint.is-note', String(S.access.developerHint)) : null;
    if (!gr.groups.length && !buckets.length) {
      return frag(h('p.hint', intro), note, empty(q ? 'No setting matches.' : 'Nothing here.'));
    }
    return frag(h('p.hint', intro), note, gr.groups.map(function (g) { return groupSection(g, gr.byGroup[g]); }),
      buckets.length ? h('section.st-group', { 'data-group': 'rate limits' }, h('h3.st-group-title', 'Rate limits'),
        h('p.st-group-about', 'Per player: a full allowance of burst requests refills over per seconds.'),
        buckets.map(function (b) {
          return h('div.st-row.st-map', { id: 'st-map-' + b, 'data-key': 'Cooldowns.' + b }, mapInner(b));
        })) : null);
  }

  /** The search box: the list drawn again for what it matches, at most
      SEARCH_ROWS rows. */
  function filterSettings() {
    var list = byId('st-list');
    if (list) setHtml(list, settingsList());
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
  /* One read of the settings serves every view that shows them (Game
     rules, Target limits' Defaults, Developer, Organisation, Locations and
     the header search) while the panel stays open; a Save reads them again,
     and so does the header's Refresh. */
  Object.keys(SETTING_VIEWS).forEach(function (view) {
    SHELL[view] = settingsShell;
    LOAD[view] = function () { if (!S.settings.data) loadSettings(); else drawSettings(); };
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
          h('div.btn-row', writeBtn('.danger', 'tl-refresh', {}, 'Bring timers forward', 'Click again: test servers only', 'forward')),
          t.refresh ? answerBox(t.refresh.answer) : null,
          t.refresh ? linesBox(t.refresh.lines) : null)),
        card('Audit log', frag(
          h('p.about', 'Writes every queued row of the audit log to the store now, rather than at the next flush. '
            + 'Works while recovery holds everything else back.'),
          h('div.btn-row', writeBtn('', 'tl-flush', {}, 'Flush the audit log', 'Click again to flush', 'floppy-disk', true)),
          t.flush ? answerBox(t.flush) : null))),
      h('p.hint', 'The diagnosis is under Health, and on a player\'s card in Players (Why can’t they see…).'));
  }

  SHELL.tools = function () { return h('section.view', h('div.stack', { id: 'tl' }, toolsBody())); };
  LOAD.tools = function () {};

  function drawTools() {
    if (S.section === 'tools') setHtml(byId('tl'), toolsBody());
    if (S.section === 'health') setHtml(byId('dg'), healthBody());
    if (S.section === 'overview') setHtml(byId('ov'), overviewBody());
    if (S.section === 'pdiag') setHtml(byId('pl-result'), playerBody());
    if (S.section === 'logs') { var lt = byId('lg-tools'); if (lt) setHtml(lt, logToolsBody()); }
  }

  /** Logs' own Flush, beside the log it writes. */
  function logToolsBody() {
    return canWrite() ? frag(writeBtn('.is-small.ghost', 'tl-flush', {}, 'Flush the audit log', 'Click again to flush',
      'floppy-disk', true), S.tools.flush ? answerBox(S.tools.flush) : null) : frag();
  }

  /* ---- Players > Frozen, Suspended and Protected: the lists ---- */

  /* ---- Players, Measures: every measure in force, one list ----

     One read (measures, server/measures.lua) of every freeze, suspension,
     protection and player target-limit override in force, newest first,
     filtered by kind here. Each freeze, suspension and protection has its
     own Lift (two clicks, by the list's handle: unfreeze, unsuspend,
     unprotect); an override is lifted in Target limits, Per player, with a
     reason for the record. The citizen id only with the identity ACE. */
  var MEASURE_KINDS = [
    { id: '', label: 'All' },
    { id: 'freeze', label: 'Frozen', chip: '.is-warn.is-frozen', none: 'Nobody is frozen.', lift: 'unfreeze',
      liftLabel: 'Unfreeze', confirm: function () { return 'Click again to unfreeze'; }, icon: 'play' },
    { id: 'suspend', label: 'Suspended', chip: '.is-warn.is-suspended', none: 'Nobody is suspended.',
      lift: 'unsuspend', liftLabel: 'Lift', icon: 'unlock',
      confirm: function (row) { return 'Click again: lift for ' + String(row.name || 'them'); } },
    { id: 'protect', label: 'Protected', chip: '.is-protected', none: 'Nobody is protected.', lift: 'unprotect',
      liftLabel: 'Lift', icon: 'unlock',
      confirm: function (row) { return 'Click again: lift for ' + String(row.name || 'them'); } },
    { id: 'limit', label: 'Own target limits', chip: '', none: 'Nobody has target limits of their own.' }
  ];
  function measureKind(id) { return MEASURE_KINDS.filter(function (k) { return k.id === id; })[0] || MEASURE_KINDS[0]; }

  function loadMeasures() {
    return ask('measures', {}, 'measures').then(function (reply) {
      if (!reply) return;
      S.players.measures = reply.ok ? (reply.data || {}) : { error: words(reply) };
      drawMeasures();
    });
  }
  function drawMeasures() {
    if (S.section === 'measures') setHtml(byId('pl-measures'), measuresListCard());
  }

  /** Every measure in force, filtered by kind, each freeze, suspension and protection with its Lift. */
  function measuresListCard() {
    var d = S.players.measures;
    if (!d) return loading('Reading the measures in force…');
    if (d.error) return empty(d.error);
    var kind = measureKind(S.players.measureKind || '');
    var rows = asList(d.rows).filter(function (r) { return !kind.id || r.kind === kind.id; });
    var counts = {};
    asList(d.rows).forEach(function (r) { counts[r.kind] = (counts[r.kind] || 0) + 1; });
    return frag(
      segmented('ms-kind', MEASURE_KINDS.map(function (k) {
        return { value: k.id, label: k.label + (k.id ? ' (' + num(counts[k.id] || 0) + ')' : '') };
      }), kind.id),
      card(kind.id ? kind.label + ' players' : 'Every measure in force', rows.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Player'), h('th', 'Since'), h('th', 'Until'), h('th', 'Reason'), h('th', ''))),
        h('tbody', rows.map(function (row) {
          var k = measureKind(row.kind);
          var ref = String(row.ref || '');
          var answer = S.players.lift[row.kind + ':' + ref];
          return frag(h('tr',
            h('td.name', String(row.name || 'No name on record'), row.cid ? h('span.cid', String(row.cid)) : null,
              h('span.chip' + (k.chip || ''), k.label + (row.kind === 'limit' ? (row.exempt ? ': exempt' : '') : '')),
              row.online ? h('span.chip.is-live', 'in the city') : null,
              row.cid ? h('div.party', btn('.is-small.ghost', 'pl-open-cid', { 'data-value': String(row.cid) },
                'Open', 'arrow-right')) : null),
            h('td.nowrap', { title: when(row.since) }, ago(row.since)),
            h('td.nowrap', row['until'] ? when(row['until'])
              : row.kind === 'suspend' ? 'until lifted' : row.kind === 'freeze' ? 'until unfrozen' : 'for good'),
            h('td', String(row.reason || '—')),
            h('td', k.lift ? modBtn('.is-small', 'pl-lift-row', { 'data-ref': ref, 'data-value': row.kind },
              k.liftLabel, k.confirm(row), k.icon)
              : h('span.sub', { title: 'Lift it in Target limits, Per player: a reason goes on the record.' },
                'In Target limits'))),
            answer ? h('tr.more', h('td', { colspan: '5' }, answerBox(answer))) : null);
        })))) : empty(kind.id ? kind.none : 'No measure is in force on anybody.'), '', h('span.sub', num(rows.length))));
  }

  SHELL.measures = function () {
    return h('section.view',
      h('p.hint', 'Every measure staff have put on a player, newest first: frozen (their live contracts on hold), '
        + 'suspended (barred from placing and accepting contracts), protected (no new contract may name them) and '
        + 'their own target limits. Put one on somebody from their Measures tab, after looking them up; lift their '
        + 'own target limits in Target limits, Per player, where a reason goes on the record.'),
      h('div.stack', { id: 'pl-measures' }, measuresListCard()));
  };
  LOAD.measures = function () { loadMeasures(); };

  /* ---- staff actions: every write the panel has, in one place ----

     Each card opens the flow that already does it, in the view it lives
     in; nothing here writes on its own. */

  var STAFF_ACTIONS = [
    { title: 'Freeze or unfreeze a player', icon: 'snowflake', view: 'players', go: 'Players',
      text: 'Look the player up, then Freeze on their Measures tab puts every live contract they are party to on '
        + 'hold: its clocks stop and nothing on it moves. Unfreeze gives the time back. Every frozen player is '
        + 'listed under Players, All measures, each with its own Unfreeze.',
      also: { view: 'measures', go: 'All measures' } },
    { title: 'Suspend or protect a player', icon: 'ban', view: 'players', go: 'Players',
      text: 'Look the player up, then Measures: Suspend bars them from placing and accepting; Protect stops new '
        + 'contracts naming them. Players, All measures lists everybody, each with Lift.',
      also: { view: 'measures', go: 'All measures' } },
    { title: 'Pay a player or set their playtime', icon: 'sack-dollar', view: 'players', go: 'Players',
      text: 'Look the player up, then Money: Pay sends money you choose, up to the most the server allows. '
        + 'Playtime sets the hours counted for the new-player rule.' },
    { title: 'Void a contract', icon: 'ban', view: 'contracts', go: 'Contracts',
      text: 'Open the contract from Contracts, then More, Void contract closes it and refunds what it holds, with a '
        + 'reason kept in the log.' },
    { title: 'Refund or pay', icon: 'scale-balanced', view: 'inbox:reviews', go: 'Inbox, Needs review',
      text: 'Needs review holds the contracts a player asked staff to look at: Refund, Pay or Dismiss each. '
        + 'Stuck escrow holds the money left for staff: Pay, Pay amount, Return or Delivered.',
      also: { view: 'inbox:stuck', go: 'Money waiting' } },
    { title: 'Deadlines', icon: 'clock', view: 'contracts', go: 'Contracts',
      text: 'Open the contract from Contracts, then Extend or Shorten under Deadline moves it: 15 min, 30 min, '
        + '1 h, 2 h or a number of minutes, with a reason kept in the log. It shows the exact time left before '
        + 'and after; players are told only that staff changed its time. Freezing a player stops its clock, and '
        + 'voiding ends it.' },
    { title: 'Announce', icon: 'bullhorn', view: 'announce', go: 'Home, Announce',
      text: 'One phone notice from Staff to every hitman holding a contract, or to everybody online with the app. '
        + 'It never names you, takes two clicks and is on the record.' },
    { title: 'Test tools', icon: 'screwdriver-wrench', view: 'tools', go: 'Test tools',
      text: 'Bring timers forward (test servers only) and Flush the audit log. The diagnosis is under Developer, '
        + 'Health, and on a player\'s card (Why can\u2019t they see\u2026).', also: { view: 'logs', go: 'Logs' } },
    { title: 'Settings', icon: 'sliders', view: 'rules', go: 'Game rules',
      text: 'Every rule is in Game rules, by the area of the game it is about, each area\'s switches first. Filter '
        + 'by Switches, Timers, Money, Limits or Lists, or search from the header. Each Save, reset or list edit takes '
        + 'two clicks.', also: { view: 'changed', go: 'Changed from the panel' } },
    { title: 'Undo a setting change', icon: 'arrow-rotate-left', view: 'logs:settings', go: 'Logs, Setting changes',
      text: 'History lists every setting changed from this panel, who changed it and when, with both values. '
        + 'Undo puts the value before back, on two clicks, checked as any change is.' },
    { title: 'Contract tools', icon: 'clipboard-list', view: 'contracts', go: 'Contracts',
      text: 'Open a contract: Staff notes, Remove an operative (stake to the placer as a walk-away, or returned; '
        + 'optionally barred), Edit text through the checks a player\'s text gets, Export the record for a '
        + 'ticket, and As a player sees it.' }
  ];

  /** Help > How do I...: every staff action, each card's Go opening where
      it is done (shown only where this staff member may open it). */
  SHELL.howto = function () {
    return h('section.view',
      h('p.hint', canWrite() ? 'Everything here changes something, and takes two clicks. Each Go opens the place '
        + 'it is done. The header search (/ or Ctrl+K) finds these too.' : whyNoWrite()),
      h('div.cards-grid', STAFF_ACTIONS.map(function (a) {
        var go = resolveView(a.view);
        return card(frag(icon(a.icon), ' ', a.title), frag(
          h('p.about', a.text),
          h('div.btn-row', viewAllowed(go) ? btn('.is-small', 'section', { 'data-section': a.view }, 'Go: ' + a.go,
            'arrow-right') : h('p.note', 'Needs ' + (DEV_VIEWS[go] ? 'the Developer ACE' : 'the staff ACE')
              + ': see Who can do what.'),
            a.also && viewAllowed(resolveView(a.also.view)) ? btn('.is-small.ghost', 'section',
              { 'data-section': a.also.view }, a.also.go, 'arrow-right') : null)), '.howto-card');
      })));
  };
  LOAD.howto = function () {};

  /** The view a link names: 'logs:<area>' and 'inbox:<filter>' are views
      with a filter chosen. */
  function resolveView(view) {
    var at = typeof view === 'string' ? view.indexOf(':') : -1;
    return at > 0 ? view.slice(0, at) : view;
  }

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
      links: [{ key: 'Completion.Fulfilment', label: 'How contracts are completed' },
        { key: 'Kidnap.CountdownSeconds', label: 'Handover countdown' },
        { key: 'Limits.MaxPayoutSlots', label: 'Payout slots' },
        { key: 'Limits.MinContractReward', label: 'Least reward' }] },
    { title: 'The clock and the time bands', icon: 'clock',
      text: 'A contract runs for its deadline, three hours as shipped, but the clock counts down only while the '
        + 'placer, the target and at least one operative holding it are all in the city. Players never see the '
        + 'exact time: each card shows a rough band, More than 2 hours, 1 to 2 hours, Under 1 hour or Under '
        + '15 minutes left. Every contract also pauses for the half hour before a txAdmin restart, and while '
        + 'the target is in prison. A hard ceiling ends any contract after two days, pauses included.',
      links: [{ key: 'Limits.DefaultDeadlineSeconds', label: 'Deadline' },
        { key: 'Limits.ContractLifetimeSeconds', label: 'Hard ceiling' },
        { key: 'Holds.RestartPauseBeforeSeconds', label: 'Restart pause' },
        { key: 'Limits.PauseWhileTargetJailed', label: 'Pause while jailed' }] },
    { title: 'Anonymity', icon: 'mask',
      text: 'A contract can be placed or accepted anonymously only if the server allows it, and as shipped it '
        + 'does not. When it is allowed, the placer or operative shows as Anonymous everywhere a player looks, '
        + 'and only staff with the identity ACE see who it is. A fee can be charged for it. Contracts on a '
        + 'whitelisted-job target (police, EMS and the like) follow their own three switches instead.',
      links: [{ key: 'TargetClasses.default.AllowAnonymousPlacer', label: 'Anonymous placing' },
        { key: 'TargetClasses.default.AllowAnonymousHitman', label: 'Anonymous accepting' },
        { key: 'TargetClasses.whitelisted.AllowAnonymousPlacer',
          label: 'On whitelisted-job targets' },
        { key: 'Anonymity.CreatorFee', label: 'Anonymity fees' }] },
    { title: 'The informants', icon: 'user-secret',
      text: 'Three paid look-ups, each off as shipped. The target\'s informant lets a target pay to find out who '
        + 'is after them, with a chance of an answer. The placer\'s informant lets the placer find out which '
        + 'operative took the contract. The informant tip lets a hitman buy the target\'s rough area on the map. '
        + 'One master switch turns all three off at once, and each has its own switch for whitelisted-job targets.',
      links: [{ key: 'Intel.Enabled', label: 'Master switch' },
        { key: 'Intel.Informant.Enabled', label: 'Target\'s informant' },
        { key: 'Intel.PlacerInformant.Enabled', label: 'Placer\'s informant' },
        { key: 'Intel.LocationTip.Enabled', label: 'Informant tip' },
        { key: 'Intel.Informant.Cost', label: 'Prices' }] },
    { title: 'Buyouts', icon: 'hand-holding-dollar',
      text: 'A target can pay to buy out a contract on them, from the app or with the buyout command. The price '
        + 'is the reward times a multiplier, between a least and a most, and never above a cap. A contract a '
        + 'hitman holds gives them a head start before the buyout closes it. A dead or downed target cannot '
        + 'buy out.',
      links: [{ key: 'Bailout.Enabled', label: 'Buyouts on or off' },
        { key: 'Bailout.MinMultiplier', label: 'Buyout price' },
        { key: 'Bailout.ProcessingDelaySeconds', label: 'Hitman\'s head start' }] },
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
      links: [{ key: 'Advisory.Enabled', label: 'Advisories on or off' },
        { key: 'Advisory.OnCreate', label: 'When they go out' },
        { key: 'Advisory.RecipientJobNames', label: 'Who is told' }] },
    { title: 'Money safety', icon: 'vault',
      text: 'Every reward is held in escrow from the moment a contract is placed until it ends, so it can always '
        + 'be paid or returned. A contract that ends without a payout refunds its placer. A payout to a player '
        + 'who is offline, or whose inventory is full, is owed to them and paid when they next log in. Anything '
        + 'the server could not settle on its own is left for staff under Stuck escrow, and a disputed contract '
        + 'goes to Needs review.',
      links: [{ key: 'PendingEscrow.MaxRetriesPerLogin', label: 'Owed payouts' },
        { key: 'MaxContractValue', label: 'Most a contract holds' },
        { key: 'EscrowBlacklist', label: 'Items never in a reward' }] }
  ];
  /** For the tests. */
  window.CH_ADMIN_HELP = HELP;

  /** The help cards in the order the README, config.lua and Features use:
      the core, Anonymity, the informants and the rest of Intel, the
      advisory, the staff tools,
      Roleplay and Improvements, each feature in config.lua's order. */
  var HELP_AREA = { 'Anonymity': 1, 'The informants': 2, 'Police advisories': 3, 'The staff freeze': 4,
    'Suspensions and protections': 4, 'Moderators': 4 };
  var HELP_BLOCKS = ['Roleplay.WitnessHeat', 'Roleplay.EmsRelisting', 'Roleplay.CityNews', 'Roleplay.DirtyPayouts',
    'Roleplay.ProofOfIntent', 'Roleplay.Protection', 'Roleplay.HitOnHitman',
    'Roleplay.BurnerPhone', 'Roleplay.NpcPlaces', 'Roleplay.ReasonQuality',
    // Intel (server/intel/), right after The informants.
    'Intel.InPerson', 'Intel.Rumours', 'Intel.WarningDelay', 'Intel.TipLimits', 'Intel.HoldFirst',
    'Intel.SecondTry', 'Intel.SafeZones', 'Intel.GoDark',
    // A character's record (server/record/), after Intel.
    'Record.Reputation', 'Record.Tiers', 'Record.Heat', 'Record.PlacerRecord',
    'Improvements.ContractDecay',
    'Improvements.ProofItems', 'Improvements.SerialScrub', 'Improvements.WeeklyStats',
    'Limits.TargetCooldownAfterCompletionSeconds'];
  function helpRank(c) {
    var key = String((c.links[0] && c.links[0].key) || '');
    for (var i = 0; i < HELP_BLOCKS.length; i++) {
      if (key === HELP_BLOCKS[i] || key.indexOf(HELP_BLOCKS[i] + '.') === 0) {
        if (HELP_BLOCKS[i].indexOf('Intel.') === 0) return 2 + (i + 1) / 100;
        if (HELP_BLOCKS[i].indexOf('Record.') === 0) return 2.5 + (i + 1) / 100;
        return (HELP_BLOCKS[i].indexOf('Roleplay.') === 0 ? 5 : 6) + i / 100;
      }
    }
    return HELP_AREA[c.title] || 0;
  }
  function helpOrdered() {
    return HELP.map(function (c, i) { return { c: c, i: i }; }).sort(function (a, b) {
      return (helpRank(a.c) - helpRank(b.c)) || (a.i - b.i);
    }).map(function (x) { return x.c; });
  }
  /** For the tests. */
  window.CH_ADMIN_HELP_ORDERED = helpOrdered;

  /* Help > How it works: an accordion, each card's words drawn only when
     it is opened. */
  SHELL.help = function () {
    return h('section.view', h('p.hint', 'How the contract app works, in plain words. Open a card; each link opens '
      + 'the setting that controls it.'),
      h('div.toolbar', btn('.is-small.ghost', 'help-all', {}, 'Open all', 'angles-down'),
        btn('.is-small.ghost', 'help-none', {}, 'Close all', 'angles-up')),
      h('div.stack.help-list', helpOrdered().map(function (c) {
        var open = !!S.help.open[c.title];
        return h('section.card.help-card' + (open ? '.is-open' : ''),
          h('button.help-head', { type: 'button', 'data-act': 'help-toggle', 'data-value': c.title,
            'aria-expanded': open ? 'true' : 'false' }, icon(c.icon), h('span.lbl', c.title),
            icon(open ? 'chevron-up' : 'chevron-down')),
          open ? frag(h('p.about', c.text),
            c.links.length ? h('div.help-links', c.links.map(function (l) {
              return h('button.link', { type: 'button', 'data-act': 'help-jump', 'data-key': l.key }, l.label);
            })) : null) : null);
      })));
  };
  LOAD.help = function () {};


  /* ---------- Game rules > Presets (server/presets.lua) -----------------

     Named bundles of settings: Strict, Relaxed, Roleplay-heavy, and
     Current (the server's own values, saved by hand or before any other
     preset is applied). Each card lists every change it would make, from
     what to what, and what the server would refuse, read now: nothing
     changes until Apply, which takes two clicks naming how many changes.
     Each change is then a setting change of its own, in Change history
     with its Undo. */
  function loadPresets() {
    return ask('presets', {}, 'presets').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { S.presets.error = words(reply); S.presets.data = null; }
      else { S.presets.error = null; S.presets.data = reply.data || {}; }
      drawPresets();
    });
  }

  function drawPresets() {
    if (S.section === 'presets') setHtml(byId('ps-list'), presetsBody());
  }

  function presetsBody() {
    if (S.presets.error) return empty(S.presets.error);
    if (!S.presets.data) return loading('Reading the presets…');
    var list = asList(S.presets.data.presets);
    return frag(answerBox(S.presets.answer),
      h('div.btn-row', writeBtn('.ghost.is-small', 'ps-save', {}, 'Save the settings now as Current',
        'Click again: save as Current', 'floppy-disk')),
      h('div.cards-grid', list.map(function (p) {
        var changes = asList(p.changes), refused = asList(p.refused);
        var n = changes.length;
        return card(String(p.name), frag(
          p.about ? h('p.about', String(p.about)) : null,
          n ? h('ul.plain.ps-changes', changes.map(function (c) {
            return h('li', h('span.name', String(c.label)), ': ', h('span.mono', String(c.from)), ' \u2192 ',
              h('span.mono', String(c.to)));
          })) : h('p.note', 'Nothing to change: the settings are this already.'),
          refused.length ? h('ul.warnings', refused.map(function (r) {
            return h('li', String(r.label) + ': left as it is. ' + String(r.why));
          })) : null,
          Number(p.same) > 0 ? h('p.sub', num(p.same) + ' more already as this preset says.') : null,
          h('div.btn-row', writeBtn('.primary.is-small', 'ps-apply', { 'data-value': String(p.name), disabled: !n || null },
            'Apply ' + String(p.name), 'Click again: apply ' + n + ' change' + (n === 1 ? '' : 's'), 'check'))),
          '.ps-card', h('span.chip' + (p.builtIn ? '' : '.is-panel'), p.builtIn ? 'shipped' : 'saved'));
      })));
  }

  SHELL.presets = function () {
    return h('section.view',
      h('p.hint', 'A preset changes nothing until you apply it. Applying one saves the settings it names as Current '
        + 'first, so going back is applying Current; every change is also in Change history with its own Undo.'),
      h('div.stack', { id: 'ps-list' }, presetsBody()));
  };
  LOAD.presets = function () { loadPresets(); };

  /* ---------- a screen's own settings, in place (the gear) -------------

     Every screen that has settings of its own carries a gear beside its
     line of help: it opens that screen's settings above it, as rows of the
     settings list (the same Save, two clicks, Reset and Details), without
     leaving the screen. Game rules (every setting, by area) stays the view
     of all of them, one click from the panel. The screens that are settings
     already (Game rules, Changed, Defaults, Engine settings, the
     organisation's Setup, Boss limits, Locations) have no gear. */
  var VIEW_SETTINGS = {
    overview: { areas: ['staff'] }, inbox: { areas: ['staff'] }, announce: { areas: ['messages', 'staff'] },
    players: { areas: ['staff'] }, pmeasures: { areas: ['staff'] }, measures: { areas: ['staff'] },
    pmoney: { areas: ['rewards'] }, pplaytime: { areas: ['access'] }, pdiag: { areas: ['access'] },
    phistory: { areas: ['record'] },
    contracts: { areas: ['placing', 'completing', 'buyouts', 'anonymity'] },
    tljobs: { view: 'tldefaults' }, tlplayer: { view: 'tldefaults' },
    orgroles: { view: 'orgsetup' }, orgmembers: { view: 'orgsetup' }, orgapps: { view: 'orgsetup' },
    orgfunds: { view: 'orgsetup' }, orgaccess: { view: 'orgsetup' }, orgnotices: { view: 'orgsetup' },
    bpmatrix: { view: 'bplimits' }, bpoffice: { view: 'bplimits' },
    logs: { areas: ['staff'] }, alerts: { areas: ['staff'] },
    health: { view: 'devsettings' }, console: { view: 'devsettings' }, tools: { view: 'devsettings' }
  };
  window.CH_ADMIN_VIEW_SETTINGS = VIEW_SETTINGS;

  /** The settings a screen's gear shows. */
  function gearEntries(view) {
    var spec = VIEW_SETTINGS[view];
    if (!spec) return [];
    var d = S.settings.data || {};
    var out = [];
    ['features', 'limits', 'readonly'].forEach(function (list) {
      asList(d[list]).forEach(function (entry) {
        if (spec.view ? viewOfSetting(entry) === spec.view
          : inRules(entry) && spec.areas.indexOf(areaOf(entry)) !== -1) out.push(entry);
      });
    });
    return out;
  }

  function gearBody() {
    if (S.gearOpen !== S.section) return frag();
    if (!S.settings.data) return loading('Reading the settings…');
    var rows = gearEntries(S.section);
    var gr = grouped(rows, 'rules');
    return card('Settings for this screen', frag(
      h('p.hint', 'The settings this screen works by. Every change takes two clicks, is on the record and can be '
        + 'undone from Change history.'),
      rows.length ? gr.groups.map(function (g) { return groupSection(g, gr.byGroup[g]); })
        : empty('This screen has no settings of its own.'),
      h('div.btn-row', btn('.is-small.ghost', 'section', { 'data-section': 'rules' }, 'All settings', 'sliders'))),
      '.gear-card');
  }

  function drawGear() {
    var node = byId('gear');
    if (!node) return;
    node.hidden = S.gearOpen !== S.section;
    setHtml(node, gearBody());
  }
  AFTER_SETTINGS.push(function () { if (S.gearOpen === S.section) drawGear(); });

  /* ---------- what a click, a key or typing does ----------------------- */

  var ACTIONS = {};
  var LIVE = {};

  ACTIONS.close = function () { close(); };
  ACTIONS.gear = function () {
    S.gearOpen = S.gearOpen === S.section ? null : S.section;
    drawCrumbs();
    drawGear();
    if (S.gearOpen && !S.settings.data) loadSettings();
  };
  ACTIONS['ps-apply'] = function (node) {
    if (!confirmed(node)) return;
    var name = node.getAttribute('data-value');
    write('presetApply', { name: name }, 'preset', node).then(function (reply) {
      if (!reply) return;
      S.presets.answer = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) loadSettings();
      loadPresets();
    });
  };
  ACTIONS['ps-save'] = function (node) {
    if (!confirmed(node)) return;
    write('presetSave', {}, 'preset', node).then(function (reply) {
      if (!reply) return;
      S.presets.answer = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      loadPresets();
    });
  };

  /* ---------- Developer > First-start setup (server/setup.lua) ---------

     Shown by itself to the first staff member who may change settings,
     while no setup has been saved, and opened again from here. Every
     choice starts at the value in force: the other scripts (the adapter
     each kind uses), the panel's command name and the key switches. The
     storage mode and the ACE lines are shown with the exact line to write,
     as both are server.cfg or config.lua's. Preview lists every change;
     Apply takes two clicks and saves the setup as done, even with nothing
     changed. */
  function loadSetup() {
    return ask('setup', {}, 'setup').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { S.setup.error = words(reply); S.setup.data = null; }
      else {
        S.setup.error = null;
        S.setup.data = reply.data || {};
        // Every choice starts where it is now; a preview from before is gone.
        S.setup.values = {};
        S.setup.preview = null;
      }
      drawSetup();
    });
  }

  function drawSetup() {
    if (S.section === 'setup') setHtml(byId('su-body'), setupBody());
  }

  /** The value chosen for a key: the staff member's pick, or the one in force. */
  function setupValue(key, current) {
    var v = S.setup.values[key];
    return v === undefined ? current : v;
  }

  function setupChoice(row) {
    return h('div.su-row', h('span.name', String(row.label || row.key)), dropdown('su-pick:' + row.key));
  }

  DD['su-pick'] = {
    options: function (key) {
      var row = setupRows()[key];
      if (!row) return [];
      if (row.kind === 'switch') return [{ value: 'true', label: 'On' }, { value: 'false', label: 'Off' }];
      return asList(row.choices).map(function (c) { return { value: String(c), label: String(c) }; });
    },
    value: function (key) {
      var row = setupRows()[key];
      return row ? String(setupValue(key, row.value)) : '';
    },
    pick: function (v, key) {
      var row = setupRows()[key];
      if (!row) return;
      S.setup.values[key] = row.kind === 'switch' ? v === 'true' : v;
      S.setup.preview = null;
      drawSetup();
    }
  };

  /** Every row the screen can change, by key. */
  function setupRows() {
    var d = S.setup.data || {};
    var out = {};
    asList(d.switches).forEach(function (r) { out[r.key] = r; });
    asList(d.integrations).forEach(function (r) {
      out[r.key] = { key: r.key, label: r.kind, kind: 'choice', choices: r.choices, value: r.choice };
    });
    return out;
  }

  function setupBody() {
    var su = S.setup;
    if (su.error) return empty(su.error);
    if (!su.data) return loading('Reading the setup…');
    var d = su.data;
    var cmd = d.command || {};
    var cmdBind = 'su.command';
    var preview = su.preview;
    var n = preview ? asList(preview.changes).length : 0;
    return frag(
      answerBox(su.answer),
      d.saved ? h('p.note', 'Saved before' + (d.savedBy ? ' by ' + String(d.savedBy) : '') + '. Change anything '
        + 'and apply again, or leave it as it is.') : h('p.hint', 'Nothing is saved yet: this screen shows until it is. '
        + 'Every choice starts at what is in force now, so applying with nothing changed keeps the server as it is.'),
      h('div.cols',
        card('Storage', frag(
          h('p.about', 'Where contracts and money are kept: mysql (the database) or json (files in data/). '
            + 'Set it in config.lua; a change needs the old mode\'s money settled and a restart (README, Changing storage mode).'),
          h('p', 'In force: ', h('span.mono', String((d.storage || {}).mode || ''))),
          h('pre.output', String((d.storage || {}).line || '')))),
        card('Permissions', frag(
          h('p.about', 'The lines that grant the panel to a group, for server.cfg. A tick means you hold it.'),
          h('ul.plain', asList(d.aces).map(function (a) {
            return h('li', icon(a.held ? 'circle-check' : 'circle'), ' ', String(a.name), h('pre.output', String(a.line)));
          }))))),
      card('Other scripts', frag(
        h('p.about', '‘auto’ uses the first one installed and started. ‘none’ turns off what needs it.'),
        h('ul.plain', asList(d.integrations).map(function (r) {
          var seen = asList(r.detected).map(function (x) { return String(x.name) + (x.up ? ' (running)' : ''); });
          return h('li.su-int', setupChoice({ key: r.key, label: r.kind }),
            h('p.sub', (r.active ? 'In use: ' + String(r.active) : 'Off: ' + String(r.without)) + '. Found: '
              + (seen.length ? seen.join(', ') : 'none') + '.'));
        })))),
      card('Panel command and key switches', frag(
        h('div.su-row', h('span.name', String(cmd.label || 'Panel command')),
          field(cmdBind, { value: String(setupValue(cmd.key, cmd.value) || ''), maxlength: '32' })),
        asList(d.switches).map(function (r) { return setupChoice(r); }))),
      card('Preview', frag(
        preview ? frag(
          n ? h('ul.plain.ps-changes', asList(preview.changes).map(function (c) {
            return h('li', h('span.name', String(c.label)), ': ', h('span.mono', String(c.from)), ' → ',
              h('span.mono', String(c.to)));
          })) : h('p.note', 'Nothing to change: applying saves the setup as it is.'),
          asList(preview.refused).length ? h('ul.warnings', asList(preview.refused).map(function (r) {
            return h('li', String(r.label) + ': left as it is. ' + String(r.why));
          })) : null) : h('p.hint', 'Preview what applying would change; nothing changes until Apply.'),
        h('div.btn-row',
          btn('.ghost', 'su-preview', {}, 'Preview', 'eye'),
          writeBtn('.primary', 'su-apply', { disabled: !preview || null }, 'Apply',
            'Click again: apply ' + n + ' change' + (n === 1 ? '' : 's') + ' and save', 'check')))));
  }

  /** What the staff member chose, with the command name typed. */
  function setupValues() {
    var out = {};
    Object.keys(S.setup.values).forEach(function (k) { out[k] = S.setup.values[k]; });
    var cmd = (S.setup.data || {}).command;
    var typed = S.forms['su.command'];
    if (cmd && typed != null && String(typed) !== String(cmd.value)) out[cmd.key] = String(typed);
    return out;
  }

  ACTIONS['su-preview'] = function () {
    ask('setupPreview', { values: setupValues() }, 'setup').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) { toast(words(reply), 'error'); return; }
      S.setup.preview = reply.data || {};
      drawSetup();
    });
  };
  ACTIONS['su-apply'] = function (node) {
    if (!confirmed(node)) return;
    write('setupApply', { values: setupValues() }, 'setup', node).then(function (reply) {
      if (!reply) return;
      S.setup.answer = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) {
        var now = {};
        Object.keys(S.access).forEach(function (k) { now[k] = S.access[k]; });
        now.setupDue = false;
        S.access = now;
        loadSettings();
      }
      loadSetup();
    });
  };

  SHELL.setup = function () {
    return h('section.view', h('div.stack', { id: 'su-body' }, setupBody()));
  };
  LOAD.setup = function () { loadSetup(); };

  ACTIONS.section = function (node) { show(node.getAttribute('data-section')); };
  /** Look up / Freeze in the contract view: Players, on that party. */
  ACTIONS['party-lookup'] = function (node) {
    var subject = node.getAttribute('data-subject');
    if (!subject) return;
    S.forms['pl.q'] = subject;
    // Their Measures, where Freeze is; the contract stays open over it.
    show('players');
    loadPlayer().then(function () { if (hasPlayer()) show('pmeasures'); });
  };
  ACTIONS.group = function (node) { openGroup(node.getAttribute('data-group')); };
  /** A help link: the setting's view, the search cleared, and its row marked. */
  ACTIONS['help-jump'] = function (node) { goSetting(node.getAttribute('data-key')); };
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
    if (canDevelop()) show('health');
    S.forms['tl.subject'] = '';
    ACTIONS['tl-diag']();
  };

  ACTIONS['ct-search-now'] = function () { S.contracts.page = 1; loadContracts(); };
  /** One person's contracts, as typed here (a player id, citizen id or name). */
  ACTIONS['ct-person-set'] = function () {
    var who = trim(S.forms['ct.who']).slice(0, 64);
    if (!who) return;
    S.contracts.person = { person: who, name: who };
    S.contracts.as = '';
    S.contracts.page = 1;
    S.contracts.whois = {};
    show('contracts');
  };
  ACTIONS['ct-person-clear'] = function () {
    S.contracts.person = null;
    S.contracts.as = '';
    S.contracts.page = 1;
    S.forms['ct.who'] = '';
    show('contracts');
  };
  ACTIONS['ct-bytarget'] = function (node) {
    S.contracts.byTarget = node.getAttribute('data-value') === 'bytarget';
    if (S.contracts.byTarget) S.contracts.state = 'live';
    S.contracts.page = 1;
    show('contracts');
  };
  /** From a player's card: the one list of contracts, filtered to them. */
  ACTIONS['pl-contracts'] = function () {
    var p = (S.players.data && S.players.data.player) || {};
    if (!p.ref) return;
    S.contracts.person = { ref: p.ref, name: p.name || p.cid || 'This player' };
    S.contracts.as = '';
    S.contracts.byTarget = false;
    S.contracts.state = '';
    S.contracts.page = 1;
    S.contracts.whois = {};
    show('contracts');
  };
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
    S.forms['ct.who'] = '';
    S.contracts.state = 'live';
    S.contracts.rule = '';
    S.contracts.range = '';
    S.contracts.page = 1;
    S.contracts.person = null;
    S.contracts.as = '';
    S.contracts.byTarget = false;
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
    // Named, and bound to the box it read: typing a new amount (or owner)
    // after arming disarms it rather than sending what was typed.
    var settleLabel = how === 'pay_amount' ? 'Click again: pay ' + money(data.amount) + ' of this line'
      : how === 'return_owner' ? 'Click again: return it to ' + data.owner : null;
    if (!armed(node, settleLabel, ['dr.amount.' + line, 'dr.owner.' + line])) return;
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
      if (shows('stuck')) loadStuck();
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
      if (where === 'contracts') {
        S.contracts.whois[id] = reply.data || {};
        if (S.section === 'contracts') drawContracts();
      } else if (S.drawer.id === id) {
        S.drawer.whois = reply.data || {};
        drawDrawer();
      }
    });
  };

  ACTIONS['rv-all'] = function (node) {
    S.reviews.all = node.getAttribute('data-value') === 'all';
    S.reviews.items = null;
    show('inbox:reviews');
  };
  ACTIONS['rv-refresh'] = function () { loadReviews(); };
  ACTIONS['rv-action'] = function (node) {
    var id = node.getAttribute('data-id');
    S.reviews.action[id] = node.getAttribute('data-value');
    disarm();
    setHtml(byId('rv-list'), reviewList());
  };
  ACTIONS['rv-goods'] = function (node) {
    disarm();
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
    // The armed label names what the second click sends: the amount, to
    // whom and from which account. Typing in the amount, or picking another
    // recipient or account, disarms it (the picks call disarm()).
    var whoLabel = data.who;
    asList((item && item.parties)).forEach(function (p) {
      if (String(p.role) === String(data.who)) whoLabel = String(p.role) + ' · ' + String(p.who || '—');
    });
    var label = action === 'dismiss' ? null
      : action === 'pay' ? 'Click again: pay it to ' + whoLabel
        : data.goods ? 'Click again: refund every item and weapon to ' + whoLabel
          : 'Click again: refund ' + money(data.amount) + ' to ' + whoLabel + ' from ' + data.account;
    if (!armed(node, label, ['rv.' + id + '.amount', 'rv.' + id + '.note'])) return;
    write('resolve', data, 'resolve:' + id, node).then(function (reply) {
      if (!reply) return;
      S.reviews.answers[id] = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (shows('reviews')) setHtml(byId('rv-list'), reviewList());
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
      if (shows('reviews')) setHtml(byId('rv-list'), reviewList());
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
    if (!confirmed(node)) return;
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

  ACTIONS['lg-area'] = function (node) {
    var v = node.getAttribute('data-value');
    if (!LOG_FILTERS[v] || v === S.logs.area) return;
    S.logs.area = v;
    show('logs');
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
    if (!S.players.ref || !confirmed(node)) return;
    write('setPlaytime', { ref: S.players.ref, hours: hours }, 'playtime', node).then(function (reply) {
      if (!reply) return;
      S.players.playtime = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok && reply.data && reply.data.playtime && S.players.data) {
        S.players.data.playtime = reply.data.playtime;
        delete S.forms['pl.hours'];
      }
      if (PLAYER_VIEWS[S.section]) setHtml(byId('pl-result'), playerBody());
    });
  }
  ACTIONS['pl-playtime-set'] = function (node) {
    var raw = trim(S.forms['pl.hours']);
    var hours = Number(raw);
    if (raw === '' || !isFinite(hours) || hours < 0 || hours > 100000) {
      disarm();
      S.players.playtime = { ok: false, text: 'Hours are a number from 0 to 100000.' };
      if (PLAYER_VIEWS[S.section]) setHtml(byId('pl-result'), playerBody());
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
        if (S.players.data && !S.players.data.error && data.ref === S.players.ref) {
          S.players.data.frozen = op === 'freeze' ? (reply.data && reply.data.frozen) || { since: nowSeconds() } : null;
        }
        if (S.players.measures) loadMeasures();
      }
      if (PLAYER_VIEWS[S.section]) setHtml(byId('pl-result'), playerBody());
    });
  }
  ACTIONS['pl-freeze'] = function (node) {
    if (!S.players.ref) return;
    var reason = trim(S.forms['pl.freezeReason']);
    if (!reason) {
      disarm();
      S.players.freeze = { ok: false, text: 'Give a reason: it goes on the record.' };
      if (PLAYER_VIEWS[S.section]) setHtml(byId('pl-result'), playerBody());
      return;
    }
    if (!confirmed(node)) return;
    freezeWrite('freeze', { ref: S.players.ref, reason: reason.slice(0, 120) }, node);
  };
  ACTIONS['pl-unfreeze'] = function (node) {
    if (!S.players.ref || !confirmed(node)) return;
    freezeWrite('unfreeze', { ref: S.players.ref,
      reason: trim(S.forms['pl.freezeReason']).slice(0, 120) }, node);
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
  /* A switch, a choice and a Save each take two clicks too: a switch live
     for the whole server (Holds.AppPaused pauses every contract) went on a
     single misclick. The armed one names the value the second click sets. */
  ACTIONS['st-switch'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    if (!entry || entry.readonly || !confirmed(node)) return;
    setSetting(key, entry.value !== true, node);
  };
  ACTIONS['st-choice'] = function (node) {
    var key = node.getAttribute('data-key');
    var entry = settingEntry(key);
    var value = node.getAttribute('data-value');
    if (!entry || entry.readonly || String(entry.value) === value || !confirmed(node)) return;
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
    // Every Save takes two clicks, the armed one naming the value it saves;
    // one that deletes something for good, or a rate limit made stricter,
    // has the row say what the second click does too. Saved on one click or
    // on Enter, a typo of 1 for 10 days lost every unopened kill photo older
    // than a day at the next sweep. Enter only ever arms it, and the second
    // click saves only the value the first one named: anything typed since
    // arms again with its own words.
    if (node.tagName === 'BUTTON' && S.armed && S.armed.node === node && S.armed.value === parsed.value) {
      disarm();
      setSetting(key, parsed.value, node);
      return;
    }
    disarm();
    var said = secondClick(entry, parsed.value);
    if (said) {
      S.settings.answers[key] = { ok: false, text: said + ' Click Save again to do it.' };
      drawSettingRow(key);
    }
    var button = byId('st-save-' + key);
    if (button) {
      var shown = describe(entry, parsed.value);
      if (shown.length > 24) shown = shown.slice(0, 23) + '\u2026';
      confirmed(button, 'Click again: save ' + shown);
      if (S.armed) { S.armed.value = parsed.value; S.armed.bind = 'st.' + key; }
    }
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
    if (!confirmed(node)) return;
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
     Records › Logs, Setting changes: every setting change with who, when and
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
        writeBtn('.primary', 'an-send', {}, 'Send', 'Click again to send', 'paper-plane')),
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

  /* ---- Records › Logs, Setting changes (the logs op's settings area) ---- */

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
    var data = { area: 'settings' };
    if (hs.cursor != null) data.cursor = hs.cursor;
    return ask('logs', data, 'history').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) hs.error = words(reply);
      else { hs.error = null; hs.data = reply.data || {}; }
      drawHistory();
    });
  }

  function drawHistory() { if (logArea() === 'settings') setHtml(byId('hs'), historyBody()); }

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
        hs.back.length ? btn('.is-small.ghost', 'hs-newer', {}, 'Newer', 'arrow-left') : null,
        hs.data.next != null ? btn('.is-small.ghost', 'hs-older', {}, 'Older', 'arrow-right') : null));
  }

  /** Records \u203a Logs, Setting changes. */
  function settingsLogBody() {
    return frag(
      h('div.toolbar', btn('.ghost', 'hs-refresh', {}, 'Refresh', 'rotate')),
      h('p.hint', 'Every setting changed from the panel, newest first: when, the value before and after, and who. '
        + 'Undo puts the value before that change back, checked as any change is; it takes two clicks and is on '
        + 'the record. A secret is never shown.'),
      h('div.stack', { id: 'hs' }, historyBody()));
  }
  function loadSettingsLog() {
    ST.history = { data: null, error: null, answer: null, cursor: null, back: [] };
    loadHistory();
  }

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
    // And anywhere but the header search, its list.
    if (S.search.open && !(act && act.indexOf('gs-') === 0)
      && !(event.target && event.target.getAttribute && event.target.getAttribute('data-bind') === 'gs.q')) {
      S.search.open = false;
      drawSearch();
    }
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
    if (bind && S.armed && (S.armed.bind === bind || (S.armed.binds && S.armed.binds.indexOf(bind) !== -1))) disarm();
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
    // Escape in the header search clears it; the panel stays.
    if (S.search.open || (event.target && event.target.getAttribute && event.target.getAttribute('data-bind') === 'gs.q')) {
      closeSearch();
      return;
    }
    close();
  });

  /** Whether a key was typed into a box (where / is a slash). */
  function typing(node) {
    var tag = node && node.tagName ? String(node.tagName).toUpperCase() : '';
    return tag === 'INPUT' || tag === 'TEXTAREA';
  }

  document.addEventListener('keydown', function (event) {
    if (!S.open) return;
    if (isEscape(event)) {
      if (event.preventDefault) event.preventDefault();
      return;
    }
    // / or Ctrl+K: the header search.
    if ((event.key === '/' && !typing(event.target)) || ((event.key === 'k' || event.key === 'K') && event.ctrlKey)) {
      var box = byId('gs-q');
      if (box) {
        if (event.preventDefault) event.preventDefault();
        if (box.focus) box.focus();
        S.search.open = true;
        drawSearch();
      }
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
     protection took, takes the two clicks as well. The history card only
     reads. */

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
    a['data-gate'] = 'mod';
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
    if (PLAYER_VIEWS[S.section]) setHtml(byId('pl-result'), playerBody());
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
          modBtn('.danger', 'ps-suspend', {}, 'Suspend', 'Click again to suspend', 'ban')));
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
        writeBtn('.danger', 'pay-send', open ? {} : { title: why }, 'Pay', 'Click again to pay',
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
    // The same player the card shows: by the lookup's handle.
    var ref = S.players.ref;
    if (!ref) return Promise.resolve();
    S.pstaff.history = null;
    S.pstaff.historyError = null;
    return ask('history', { ref: ref }, 'playerHistory').then(function (reply) {
      if (!reply || ref !== S.players.ref) return;
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
        loadPlayer(true).then(function () { S.pstaff[slot] = keep; drawPlayer(); });
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
    if (!S.players.ref) return;
    var reason = trim(S.forms['ps.reason']);
    var raw = trim(S.forms['ps.days']);
    if (!/^\d{1,3}$/.test(raw) || Number(raw) > 365) {
      return refuse('suspend', 'Choose how many days (1 to 365), or Until lifted.');
    }
    if (!reason) return refuse('suspend', 'Give a reason: they are shown it, and it goes on the record.');
    if (!confirmed(node)) return;
    staffWrite(write('suspend', { ref: S.players.ref, days: Number(raw),
      reason: reason.slice(0, 120) }, 'pstaff:suspend', node), 'suspend');
  };
  ACTIONS['ps-lift'] = function (node) {
    if (!S.players.ref) return;
    // Two clicks, as every other write here is (3 s to confirm).
    if (!confirmed(node)) return;
    staffWrite(write('unsuspend', { ref: S.players.ref }, 'pstaff:suspend', node), 'suspend');
  };

  ACTIONS['pp-unit'] = function (node) {
    S.pstaff.unit = node.getAttribute('data-value') || 'h';
    disarm();
    drawPlayer();
  };
  ACTIONS['pp-protect'] = function (node) {
    if (!S.players.ref) return;
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
    staffWrite(write('protect', { ref: S.players.ref, hours: hours,
      reason: reason.slice(0, 120) }, 'pstaff:protect', node), 'protect');
  };
  ACTIONS['pp-lift'] = function (node) {
    if (!S.players.ref) return;
    // Two clicks, as every other write here is (3 s to confirm).
    if (!confirmed(node)) return;
    staffWrite(write('unprotect', { ref: S.players.ref }, 'pstaff:protect', node), 'protect');
  };

  ACTIONS['pay-account'] = function (node) {
    S.pstaff.account = node.getAttribute('data-value') === 'bank' ? 'bank' : 'cash';
    disarm();
    drawPlayer();
  };
  ACTIONS['pay-send'] = function (node) {
    if (!S.players.ref) return;
    var max = Number(S.players.data && S.players.data.payMax) || 0;
    var amount = wholeNumber(S.forms['pay.amount']);
    var reason = trim(S.forms['pay.reason']);
    if (!amount) return refuse('pay', 'Give the amount, a whole number of dollars.');
    if (max > 0 && amount > max) {
      return refuse('pay', 'At most ' + money(max) + ' at once (Config.Staff.ManualPaymentMax).');
    }
    if (!reason) return refuse('pay', 'Give a reason: it goes on the record.');
    if (!confirmed(node)) return;
    staffWrite(write('manualPay', { ref: S.players.ref, amount: amount, account: S.pstaff.account,
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
      links: [{ key: 'Staff.ManualPaymentMax', label: 'Most one manual payment may be' }] });

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
    S.players.subject = null;
    S.players.ref = null;
    S.players.playtime = null;
    S.players.freeze = null;
    S.players.measures = null;
    S.players.measureKind = '';
    S.players.at = 0;
    S.players.lift = {};
    S.ctx.contract = null;
    S.search = { q: '', open: false, at: 0 };
    S.navOpen = false;
    resetPlayerStaff();
    orgReset();
    S.settings.data = null;
    S.settings.answers = {};
    S.settings.photos = null;
    S.settings.drafts = {};
    S.settings.open = {};
    S.tools = { refresh: null, diag: null, flush: null };
    S.busy = {};
    S.seq = {};
    S.menu = null;
    S.drawer = { id: null, data: null, answer: null, whois: null };
    S.stuck = { data: null, error: null, answers: {} };
    if (S.tl) clearTimeout(S.tl.countTimer);
    tlReset();
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
      h('p.note', 'Takes them off without ending it for anybody else. The placer and the other operatives are '
        + 'told an operative left, as a walk-away says it; they are told "Staff removed you from a contract."'),
      h('div.ct-row', h('span.ct-label', 'Operative'),
        segmented('ct-rm-pick', active.map(function (m) {
          return { value: String(m.id), label: String(m.alias || 'operative') + (m.name ? ' · ' + m.name : ''),
                   disabled: !open, title: off.title };
        }), st.pick)),
      h('div.ct-row', h('span.ct-label', 'Their stake'),
        segmented('ct-rm-stake', [
          { value: 'client', label: 'To the placer (as a walk-away)', disabled: !open, title: off.title },
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
        writeBtn('.danger', 'ct-remove', {}, 'Remove', 'Click again to remove', 'user-minus')),
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

  /* -- change the reward (server/staff_reward.lua) --

     Raise or lower the collection being paid next by a whole number of
     dollars: a raise added by staff or charged to the placer, from cash or
     bank; a lowering off what staff added first, then back to the placer.
     The server's figures (rewardPreview, a read) are drawn before the
     button arms, and the armed label names them; rewardChange, the staff
     ACE's, is what decides. */

  function rwState() {
    if (!S.drawer.rw) {
      S.drawer.rw = { dir: 'raise', from: 'staff', account: 'bank', base: null, baseFor: null, baseAsked: false,
        preview: null, previewBy: null, timer: null };
    }
    return S.drawer.rw;
  }

  /** The signed dollars typed, or null: whole and above 0, the direction its sign. */
  function rewardBy() {
    var st = rwState();
    var n = wholeNumber(S.forms['dr.rw.amt.' + S.drawer.id]);
    if (!n || n <= 0) return null;
    return st.dir === 'lower' ? -n : n;
  }

  /** rewardPreview for `by` (null: the collection as it is). */
  function loadRewardPreview(by) {
    var id = S.drawer.id;
    var st = rwState();
    if (!id) return Promise.resolve(null);
    var data = { id: id };
    if (by != null) data.by = by;
    else st.baseAsked = true;
    // The base read and the per-amount preview on channels of their own: on
    // one, a preview sent while the base was in flight dropped the base's
    // reply, and baseAsked kept it from being asked again (the facts read
    // "Reading the reward…" for good, and the cap check below had no max).
    return ask('rewardPreview', data, by == null ? 'rewardBase' : 'rewardPreview').then(function (reply) {
      if (!reply) {
        if (by == null && S.drawer.rw === st) st.baseAsked = false;
        return null;
      }
      if (S.drawer.id !== id || S.drawer.rw !== st) return null;
      var view = reply.ok ? (reply.data || {}) : { refused: reply.err || 'no_answer', message: words(reply) };
      if (by == null) { st.base = view; st.baseFor = id; }
      else { st.preview = view; st.previewBy = by; }
      var box = byId('dr-rw-preview');
      if (by == null || !box) drawDrawer();
      else setHtml(box, rewardPreviewText());
      return view;
    });
  }

  function rewardWho(st) {
    return st.from === 'placer' ? 'charged to the placer\'s ' + st.account : 'added by staff (' + st.account + ')';
  }

  /** What the change typed would do, in the server's figures. */
  function rewardPreviewText() {
    var st = rwState();
    var by = rewardBy();
    if (by == null) return h('span', 'Type a whole number of dollars to see the reward after.');
    var v = st.previewBy === by ? st.preview : null;
    if (!v) return h('span', 'Reading what that would do…');
    if (v.refused) return h('span.is-warn', String(v.message || 'Not possible now.'));
    var parts = [h('span', 'Collection ' + num(v.slot) + ': ', h('b', money(v.reward)), ' → ', h('b', money(v.after)))];
    if (by > 0) parts.push(h('span', ', ' + rewardWho(st) + '.'));
    else {
      parts.push(h('span', '. ' + money(v.toStaff || 0) + ' of what staff added comes off; '
        + money(v.toPlacer || 0) + ' goes back to the placer.'));
    }
    if (Number(v.max) && Math.abs(by) > Number(v.max)) {
      parts.push(h('span.is-warn', ' At most ' + money(v.max) + ' at once (Config.Staff.RewardChangeMax).'));
    }
    return frag(parts);
  }

  function rewardBody(d) {
    var id = S.drawer.id;
    var c = d.contract || {};
    var st = rwState();
    if (c.state !== 'active' && c.state !== 'accepted') {
      return h('p.note', 'Only a live contract (active or accepted) has a reward to change.');
    }
    var base = st.baseFor === id ? st.base : null;
    var open = writesOpen();
    var off = { disabled: !open, title: open ? null : whyNoWrite() };
    var facts = !base ? loading('Reading the reward…')
      : base.refused ? h('p.note.is-warn', String(base.message || 'Its reward cannot be changed now.'))
        : h('dl.facts',
          h('dt', 'Collection'), h('dd', num(base.slot)),
          h('dt', 'Its reward'), h('dd', money(base.reward)),
          h('dt', 'Added by staff'), h('dd', money(base.staffAdded || 0)),
          h('dt', 'Lowered by at most'), h('dd', money(base.mostLower || 0)),
          h('dt', 'One change at most'), h('dd', Number(base.max) ? money(base.max) : 'off (Config.Staff.RewardChangeMax is 0)'));
    var dirOpts = [{ value: 'raise', label: 'Raise', disabled: !open, title: off.title },
                   { value: 'lower', label: 'Lower', disabled: !open, title: off.title }];
    return frag(
      h('p.note', 'Changes the reward of the collection paid next. The placer and the operatives are told it '
        + 'changed, by staff; nobody is named.'),
      facts,
      h('div.ct-row', h('span.ct-label', 'Change'), segmented('rw-dir', dirOpts, st.dir),
        field('dr.rw.amt.' + id, { class: 'is-short', placeholder: '$ amount', inputmode: 'numeric', maxlength: '9',
          'data-live': 'rw-preview', disabled: !open, 'aria-label': 'Dollars to change the reward by' })),
      st.dir === 'raise' ? h('div.ct-row', h('span.ct-label', 'Paid by'),
        segmented('rw-from', [
          { value: 'staff', label: 'Added by staff', disabled: !open, title: off.title },
          { value: 'placer', label: 'Charged to the placer', disabled: !open, title: off.title }
        ], st.from)) : null,
      st.dir === 'raise' ? h('div.ct-row', h('span.ct-label', 'Account'),
        segmented('rw-account', [
          { value: 'bank', label: 'Bank', disabled: !open, title: off.title },
          { value: 'cash', label: 'Cash', disabled: !open, title: off.title }
        ], st.account)) : null,
      h('p.note', { id: 'dr-rw-preview', 'aria-live': 'polite' }, rewardPreviewText()),
      h('div.inline-form.is-wide',
        field('dr.rw.reason.' + id, { class: 'is-grow', placeholder: 'Reason (required, kept in the log)',
          maxlength: '120', disabled: !open, 'aria-label': 'Reason for changing the reward' }),
        writeBtn('.primary', 'rw-change', {}, 'Change reward', 'Click again to change', 'sack-dollar')));
  }

  function rewardPicked() {
    var st = rwState();
    disarm();
    st.preview = null;
    st.previewBy = null;
    drawDrawer();
    var by = rewardBy();
    if (by != null) loadRewardPreview(by);
  }
  ACTIONS['rw-dir'] = function (node) { rwState().dir = node.getAttribute('data-value') === 'lower' ? 'lower' : 'raise'; rewardPicked(); };
  ACTIONS['rw-from'] = function (node) { disarm(); rwState().from = node.getAttribute('data-value') === 'placer' ? 'placer' : 'staff'; drawDrawer(); };
  ACTIONS['rw-account'] = function (node) { disarm(); rwState().account = node.getAttribute('data-value') === 'cash' ? 'cash' : 'bank'; drawDrawer(); };
  LIVE['rw-preview'] = function () {
    var st = rwState();
    clearTimeout(st.timer);
    setHtml(byId('dr-rw-preview'), rewardPreviewText());
    st.timer = setTimeout(function () {
      st.timer = null;
      var by = rewardBy();
      if (by != null && st.previewBy !== by) loadRewardPreview(by);
    }, DEBOUNCE_MS);
  };

  ACTIONS['rw-change'] = function (node) {
    var id = S.drawer.id;
    if (!id) return;
    var st = rwState();
    var by = rewardBy();
    var reason = trim(S.forms['dr.rw.reason.' + id]).slice(0, 120);
    var max = Number((st.base || {}).max) || 0;
    var problem = by == null ? 'Type a whole number of dollars above 0.'
      : max && Math.abs(by) > max ? 'At most ' + money(max) + ' at once (Config.Staff.RewardChangeMax).'
        : !reason ? 'Give a reason: it goes on the record.' : null;
    if (problem) {
      disarm();
      S.drawer.answer = { ok: false, text: problem };
      drawDrawer();
      return;
    }
    var v = st.previewBy === by ? st.preview : null;
    if (!v) {
      // The figures first: the button arms once they are drawn.
      disarm();
      loadRewardPreview(by);
      return;
    }
    if (v.refused) {
      disarm();
      S.drawer.answer = { ok: false, text: String(v.message || 'Not possible now.') };
      drawDrawer();
      return;
    }
    var label = by > 0
      ? 'Click again: raise it from ' + money(v.reward) + ' to ' + money(v.after) + ', ' + rewardWho(st)
      : 'Click again: lower it from ' + money(v.reward) + ' to ' + money(v.after);
    if (!armed(node, label, ['dr.rw.amt.' + id, 'dr.rw.reason.' + id])) return;
    var data = { id: id, by: by, reason: reason };
    if (by > 0) { data.from = st.from; data.account = st.account; }
    write('rewardChange', data, 'reward:' + id, node).then(function (reply) {
      if (!reply || S.drawer.id !== id) return;
      drawerAnswer(reply);
      if (reply.ok) {
        S.forms['dr.rw.amt.' + id] = '';
        S.forms['dr.rw.reason.' + id] = '';
        st.preview = null;
        st.previewBy = null;
        st.base = null;
        st.baseFor = null;
        st.baseAsked = false;
      }
      drawDrawer();
      loadContract();
    });
  };

  /* -- reassign to another hitman (server/staff_reassign.lua) --

     The hitman is the player looked up in Players (by the handle that
     lookup gave, never a typed id): every operative on it is taken off as
     Remove does, and the new one put through every Accept check. The
     preview (reassignPreview, a read) says who comes off and what would
     refuse them before the button arms; reassignHitman is the staff ACE's. */

  function raState() {
    if (!S.drawer.ra) S.drawer.ra = { block: 'block', stake: 'client', identity: 'anonymous', preview: null, previewRef: null, asking: null };
    return S.drawer.ra;
  }

  function loadReassignPreview() {
    var id = S.drawer.id;
    var st = raState();
    var ref = S.players.ref;
    if (!id || !ref) return Promise.resolve(null);
    st.asking = ref;
    return ask('reassignPreview', { id: id, ref: ref }, 'reassignPreview').then(function (reply) {
      if (!reply || S.drawer.id !== id || S.drawer.ra !== st) return null;
      st.asking = null;
      st.preview = reply.ok ? (reply.data || {}) : { refused: reply.err || 'no_answer', message: words(reply) };
      st.previewRef = ref;
      drawDrawer();
      return st.preview;
    });
  }

  function reassignBody(d) {
    var id = S.drawer.id;
    var c = d.contract || {};
    var st = raState();
    if (c.state !== 'active' && c.state !== 'accepted') {
      return h('p.note', 'Only a live contract (active or accepted) can be given to another hitman.');
    }
    var open = writesOpen();
    var off = { disabled: !open, title: open ? null : whyNoWrite() };
    if (!hasPlayer()) {
      return frag(h('p.note', 'Look the hitman up in Players first (the header\'s Player chip). The contract stays '
        + 'open over it; come back to this tab and reassign to them.'),
        h('div.btn-row', btn('.is-small', 'section', { 'data-section': 'players' }, 'Find the hitman in Players',
          'magnifying-glass')));
    }
    var who = String((S.players.data.player || {}).name || 'them');
    var v = st.previewRef === S.players.ref ? st.preview : null;
    var ops = v ? asList(v.operatives) : [];
    var said = !v ? loading('Checking whether ' + who + ' can take it…')
      : frag(
        h('p', ops.length ? 'Taken off it: ' + ops.join(', ') + ', each as Remove operative does.'
          : 'Nobody is on it now.'),
        h('p', v.stakeWaived ? 'Their stake is waived (Config.Staff.ReassignStake).'
          : 'They put up the ' + money(v.stake) + ' stake, as on Accept.'),
        v.refused ? h('p.note.is-warn', String(v.message || 'They cannot take it now.')) : null);
    return frag(
      h('div.ct-row', h('span.ct-label', 'New hitman'), h('span.chip.is-live', icon('user'), ' ', who)),
      said,
      h('div.ct-row', h('span.ct-label', 'Those taken off'),
        segmented('ra-block', [
          { value: 'block', label: 'Bar them from it', disabled: !open, title: off.title },
          { value: '', label: 'They may take it again', disabled: !open, title: off.title }
        ], st.block)),
      h('div.ct-row', h('span.ct-label', 'Their stakes'),
        segmented('ra-stake', [
          { value: 'client', label: 'To the placer (as a walk-away)', disabled: !open, title: off.title },
          { value: 'return', label: 'Return the stakes', disabled: !open, title: off.title }
        ], st.stake)),
      h('div.ct-row', h('span.ct-label', 'The new hitman'),
        segmented('ra-identity', [
          { value: 'anonymous', label: 'Anonymous (no fee)', disabled: !open, title: off.title },
          { value: 'carry', label: 'As they chose before', disabled: !open, title: off.title },
          { value: 'named', label: 'Named to the placer', disabled: !open, title: off.title }
        ], st.identity)),
      h('div.inline-form.is-wide',
        field('dr.ra.reason.' + id, { class: 'is-grow', placeholder: 'Reason (required, kept in the log)',
          maxlength: '120', disabled: !open, 'aria-label': 'Reason for reassigning the contract' }),
        writeBtn('.danger', 'ra-go', {}, 'Reassign', 'Click again to reassign', 'right-left')));
  }

  ACTIONS['ra-block'] = function (node) { disarm(); raState().block = node.getAttribute('data-value') || ''; drawDrawer(); };
  ACTIONS['ra-stake'] = function (node) { disarm(); raState().stake = node.getAttribute('data-value') || 'client'; drawDrawer(); };
  ACTIONS['ra-identity'] = function (node) { disarm(); raState().identity = node.getAttribute('data-value') || 'anonymous'; drawDrawer(); };

  ACTIONS['ra-go'] = function (node) {
    var id = S.drawer.id;
    if (!id) return;
    var st = raState();
    var reason = trim(S.forms['dr.ra.reason.' + id]).slice(0, 120);
    var problem = !hasPlayer() ? 'Look the hitman up in Players first.'
      : !reason ? 'Give a reason: it goes on the record.' : null;
    if (problem) {
      disarm();
      S.drawer.answer = { ok: false, text: problem };
      drawDrawer();
      return;
    }
    var ref = S.players.ref;
    var v = st.previewRef === ref ? st.preview : null;
    if (!v) { disarm(); loadReassignPreview(); return; }
    if (v.refused) {
      disarm();
      S.drawer.answer = { ok: false, text: String(v.message || 'They cannot take it now.') };
      drawDrawer();
      return;
    }
    var who = String((S.players.data.player || {}).name || 'them');
    var n = asList(v.operatives).length;
    var label = 'Click again: give it to ' + who + (n ? ', taking off ' + n + ' operative' + (n === 1 ? '' : 's') : '');
    if (!armed(node, label, ['dr.ra.reason.' + id])) return;
    write('reassignHitman', { id: id, ref: ref, reason: reason, block: st.block === 'block',
      returnStake: st.stake === 'return', identity: st.identity || 'anonymous' }, 'reassign:' + id, node).then(function (reply) {
      if (!reply || S.drawer.id !== id) return;
      drawerAnswer(reply);
      if (reply.ok) {
        S.forms['dr.ra.reason.' + id] = '';
        st.preview = null;
        st.previewRef = null;
        if (S.section === 'contracts') loadContracts();
      }
      drawDrawer();
      loadContract();
    });
  };

  /** What a tab needs read before it can say anything: the reward as it is
      (Money), whether the looked-up hitman can take it (People). Each asked
      once per contract, per player looked up. */
  function drawerNeeds() {
    var d = S.drawer.data;
    if (!S.drawer.id || !d || !d.staff || !d.contract || d.contract.neverStored) return;
    var live = d.contract.state === 'active' || d.contract.state === 'accepted';
    if (!live) return;
    var tab = S.drawer.tab || 'summary';
    if (tab === 'money') {
      var rw = rwState();
      if (rw.baseFor !== S.drawer.id && !rw.baseAsked) loadRewardPreview(null);
    } else if (tab === 'people' && hasPlayer()) {
      var ra = raState();
      if (ra.previewRef !== S.players.ref && ra.asking !== S.players.ref) loadReassignPreview();
    }
  }

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
    // No setup saved yet (server/setup.lua): the first staff member who may
    // change settings is shown it, once a page load; Developer has it after.
    if (S.access.setupDue === true && !S.setup.shown) {
      S.setup.shown = true;
      S.section = 'setup';
    }
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
    { title: 'Roleplay: Proof of intent', icon: 'comments',
      text: 'Off as shipped. On, a hitman\'s payout is held, never refused, until they have shown they worked '
        + 'the contract in character: enough messages to the placer in the contract thread, or a live '
        + 'handover, or a meeting point set. Their receipt and their card say what is missing. After the hold '
        + 'time it is handed over anyway, so money is never stuck. The money stays in escrow, owed to them, '
        + 'and every hold is audited (intent_hold_started, intent_hold_released).',
      links: [{ key: 'Roleplay.ProofOfIntent.Enabled', label: 'Proof of intent' },
        { key: 'Roleplay.ProofOfIntent.MinMessages', label: 'Messages that count' },
        { key: 'Roleplay.ProofOfIntent.HoldMaxMinutes', label: 'Longest hold' }] },
    { title: 'Roleplay: Bodyguards', icon: 'shield-halved',
      text: 'Off as shipped. On, a target can hire protection from their On me card: a reward taken from them '
        + 'at once and held, and a meeting pin where they stand. Other players see the job on the board\'s '
        + 'Protection tab by its reward alone; the one who takes it gets the target\'s name and the pin, and '
        + 'never who placed the hit or who is on it. Ended without a completion (expired, cancelled, bought '
        + 'out): the guard is paid. Completed anyway: the guard gets their share and the rest goes back. '
        + 'Nobody took it, or staff voided the contract: all of it goes back to the target.',
      links: [{ key: 'Roleplay.Protection.Enabled', label: 'Bodyguard contracts' },
        { key: 'Roleplay.Protection.MinReward', label: 'Reward bounds and account' },
        { key: 'Roleplay.Protection.PayOnCompletionPercent', label: 'Share if completed' },
        { key: 'Roleplay.Protection.MaxJobsPerGuard', label: 'Jobs per guard' }] },
    { title: 'Roleplay: Hit on the hitman', icon: 'crosshairs',
      text: 'Off as shipped. On, a target whose informant found out an operative\'s name gets a button on that '
        + 'card to place a contract on them: the Place form opens with them chosen, and every rule of placing '
        + 'a contract applies. Nothing is offered for an operative found only by description.',
      links: [{ key: 'Roleplay.HitOnHitman.Enabled', label: 'Hit on the hitman' },
        { key: 'Intel.Informant.Enabled', label: 'The target\'s informant' }] });

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
      // One run for a player (by their lookup handle) goes to that player's
      // diagnosis and only while it is theirs; one without, to Health's.
      if (typeof message.ref === 'string') {
        var pd = S.tools.pdiag;
        if (!pd || pd.error || pd.ref !== message.ref) return;
        pd.later = asList(pd.later).concat([message.line]);
      } else {
        if (!S.tools.diag || S.tools.diag.error) S.tools.diag = { lines: [], later: [] };
        // Drawn wherever the server diagnosis shows: Health, Home.
        S.tools.diag.later = asList(S.tools.diag.later).concat([message.line]);
      }
      drawTools();
    }
  });

  /* ---------- roleplay consequences (server/rp_consequences.lua) ------- */

  GROUP_INTRO['Roleplay: Witness heat'] = 'A completion seen by bystanders alerts the police, naming nobody.';
  GROUP_INTRO['Roleplay: EMS before re-listing'] = 'A target killed on a contract is treated before a new one.';
  GROUP_INTRO['Roleplay: City news'] = 'An anonymous news post after a completed contract.';
  GROUP_INTRO['Roleplay: Dirty money payouts'] = 'A hitman\'s cash or bank payout handed over as a dirty money item.';
  GROUP_INTRO['Roleplay: Proof of intent'] = 'A payout waits until the hitman has worked the contract in character.';
  GROUP_INTRO['Roleplay: Bodyguards'] = 'A target may hire a bodyguard from On me.';
  GROUP_INTRO['Roleplay: Hit on the hitman'] = 'A target may place a contract on an operative revealed to them.';
  GROUP_INTRO['Intel: Rumours and broker'] = 'New contracts show as rumours until a broker briefs the hitman.';
  GROUP_INTRO['Roleplay: Burner phone'] = 'Placing and accepting need a burner phone item.';
  GROUP_INTRO['Intel: Informant in person'] = 'Informant purchases only beside the informant NPC.';
  GROUP_INTRO['Roleplay: Reason quality'] = 'Free-text reasons held to a length and a low-effort word list.';
  GROUP_INTRO['Intel: Tip warning delay'] = 'The target hears of an informant tip a random while later.';
  GROUP_INTRO['Intel: Tip limits'] = 'One tip per hitman per contract, and doubling prices.';
  GROUP_INTRO['Intel: Hold before a tip'] = 'A tip only once the hitman has held the contract a while.';
  GROUP_INTRO['Intel: Informant second try'] = 'What the target\'s later look-ups cost.';
  GROUP_INTRO['Intel: Tip safe zones'] = 'No tip while the target is inside a safe zone.';
  GROUP_INTRO['Intel: Go dark'] = 'A tipped-off target may pay so tips on them find nothing for a while.';
  GROUP_INTRO['Improvements: Proof items'] = 'A hitman may finish with an item taken from the target.';
  GROUP_INTRO['Improvements: Serial scrubbing'] = 'An anonymous placer\'s weapon reaches the hitman with a new serial.';
  GROUP_INTRO['Improvements: Weekly stats'] = 'The week\'s totals posted to Discord, counts only.';
  GROUP_INTRO['Improvements: Completion cooldown'] = 'A wait before a completed contract\'s target can be listed again.';

  HELP.push(
    { title: 'Roleplay: Witness heat', icon: 'eye',
      text: 'When it is on, every completion, a kill or a handover, is checked on the server for players near '
        + 'the hitman who are no party to the contract. With enough of them, or always if set, officers get a '
        + 'vague witness report on their phones and in sc-dispatch: a phrase, the way the hitman went, and the '
        + 'nearest named area. A position can be sent too, moved by up to the fuzz distance. It never names the '
        + 'hitman or the placer.',
      links: [{ key: 'Roleplay.WitnessHeat.Enabled', label: 'Witness heat on or off' },
        { key: 'Roleplay.WitnessHeat.WitnessRadius', label: 'Radius and witnesses' },
        { key: 'Roleplay.WitnessHeat.Phrases', label: 'What a witness says' },
        { key: 'Roleplay.WitnessHeat.Areas', label: 'Named areas' }] },
    { title: 'Roleplay: EMS before re-listing', icon: 'kit-medical',
      text: 'When it is on, a target killed on a contract cannot have a new one placed on them straight away. '
        + 'They have to have been up, neither dead nor downed, for the treated minutes first; the placer is '
        + 'told they are still recovering. With the medic switch on, an on-duty medic\'s defibrillator revive '
        + 'is needed instead. The rule always lets go after the longest hold, and it adds to the usual '
        + 'cooldowns.',
      links: [{ key: 'Roleplay.EmsRelisting.Enabled', label: 'On or off' },
        { key: 'Roleplay.EmsRelisting.TreatedMinutes', label: 'Minutes up' },
        { key: 'Roleplay.EmsRelisting.RequireEMS', label: 'A medic\'s revive' }] },
    { title: 'Roleplay: City news', icon: 'newspaper',
      text: 'When it is on, a completed contract on a whitelisted-job target, or on any target if set, posts an '
        + 'anonymous news item. It goes out on lb-phone\'s Birdy from the configured account, or as a server '
        + 'event another resource posts. The words come from the templates, with the target\'s job, the area '
        + 'and the time. The target is named only if staff turn that on, and the hitman and the placer never.',
      links: [{ key: 'Roleplay.CityNews.Enabled', label: 'On or off' },
        { key: 'Roleplay.CityNews.App', label: 'Where it is posted' },
        { key: 'Roleplay.CityNews.Templates', label: 'Templates' }] },
    { title: 'Roleplay: Dirty money payouts', icon: 'sack-dollar',
      text: 'When it is on, a hitman\'s cash or bank payout is handed over as a dirty money item instead, by '
        + 'count or as one item worth the figure. Escrow keeps the money it took, and only the payout '
        + 'converts it, so nothing is lost. A refund to the placer goes back as it was taken. A payout that '
        + 'does not fit in their pockets is owed, and paid when they make room or next log in.',
      links: [{ key: 'Roleplay.DirtyPayouts.Enabled', label: 'On or off' },
        { key: 'Roleplay.DirtyPayouts.Item', label: 'The item' },
        { key: 'Roleplay.DirtyPayouts.Rate', label: 'The rate' }] });

  /* ---------- the roleplay features (Config.Roleplay) ---------- */

  HELP.push(
    { title: 'Intel: Rumours and the broker', icon: 'user-secret',
      text: 'Off as shipped. On, a hitman sees a new contract only as a rumour: a rough area and a reward '
        + 'band, with no name, face or Accept. Asking the broker NPC about it, standing beside it, or '
        + 'being briefed by a player on a broker job, shows the whole card and Accept for a while. The '
        + 'NPC moves between its places on a timer. Distances are checked on the server.',
      links: [{ key: 'Intel.Rumours.Enabled', label: 'Rumours on or off' },
        { key: 'Intel.Rumours.Locations', label: 'Broker places' },
        { key: 'Intel.Rumours.BriefValidMinutes', label: 'How long a briefing lasts' },
        { key: 'Intel.Rumours.BrokerJobs', label: 'Broker jobs' }] },
    { title: 'Roleplay: Burner phone', icon: 'mobile-screen',
      text: 'Off as shipped. On, placing, accepting and every contract action need the burner phone item '
        + 'in the inventory, counted on the server. Without one a player is told "You need a burner '
        + 'phone." and, as shipped, sees no contracts at all. Live contracts stay; a burner can be used '
        + 'up on placing or accepting. Sell it through sc-blackmarket (README).',
      links: [{ key: 'Roleplay.BurnerPhone.Enabled', label: 'Burner phone on or off' },
        { key: 'Roleplay.BurnerPhone.Item', label: 'The item' }] },
    { title: 'Intel: The informant in person', icon: 'user-secret',
      text: 'Off as shipped. On, every informant purchase (the target\'s, the placer\'s and the tip) is '
        + 'sold only to a buyer standing beside the informant NPC, which moves between its own places. '
        + 'Anywhere else it is refused with "Find the informant first." and nothing is charged.',
      links: [{ key: 'Intel.InPerson.Enabled', label: 'Informant in person' },
        { key: 'Intel.InPerson.Locations', label: 'Informant places' }] },
    { title: 'Roleplay: Broker and informant placed from the panel', icon: 'location-dot',
      text: 'Off as shipped. On, the broker and the informant NPC stand where staff placed them in Locations, '
        + 'Broker and informant places (stand there in game and press Use my position), rotating among '
        + 'those as their RotateHours say. Their Locations lists in the settings stay the defaults: they '
        + 'are used while no place is set, and again after Reset to config or with this off.',
      links: [{ key: 'Roleplay.NpcPlaces.Enabled', label: 'Placed from the panel on or off' },
        { key: 'Intel.Rumours.Locations', label: 'Broker defaults' }] },
    { title: 'Roleplay: Reason quality', icon: 'pen',
      text: 'Off as shipped. On, a typed reason needs a least length and number of words, on top of the '
        + 'other reason rules. A reason with a low-effort phrase (rdm, idk, test) is refused, or placed '
        + 'and put in Needs review as a low-effort reason, as set.',
      links: [{ key: 'Roleplay.ReasonQuality.Enabled', label: 'Reason quality on or off' },
        { key: 'Roleplay.ReasonQuality.LowEffort', label: 'Low-effort phrases' },
        { key: 'Roleplay.ReasonQuality.LowEffortAction', label: 'Refuse or review' }] });

  /* ---------- the improvements (Config.Improvements) ---------- */

  HELP.push(
    { title: 'Intel: Tip warning delay', icon: 'clock',
      text: 'Off as shipped. On, the target of an informant tip is told someone knows their rough area '
        + 'a random while after the tip, between the shortest and longest delay, instead of at once. '
        + 'A warning still waiting survives a restart and is sent late rather than lost. The time on '
        + 'the target\'s card is rounded to 5 minutes, so it does not give the delay away.',
      links: [{ key: 'Intel.WarningDelay.Enabled', label: 'On or off' },
        { key: 'Intel.WarningDelay.MinSeconds', label: 'Shortest delay' },
        { key: 'Intel.WarningDelay.MaxSeconds', label: 'Longest delay' }] },
    { title: 'Intel: Tip limits', icon: 'scale-balanced',
      text: 'Off as shipped. On, on top of the tips per contract and the wait between them: each hitman '
        + 'may buy one tip per contract, and/or each further tip on a contract costs twice the one '
        + 'before, up to the most a tip costs. The card quotes the real next price, and a price that '
        + 'moved is refused, never charged.',
      links: [{ key: 'Intel.TipLimits.Enabled', label: 'On or off' },
        { key: 'Intel.TipLimits.OnePerHitman', label: 'One per hitman' },
        { key: 'Intel.TipLimits.PriceDoubling', label: 'Price doubling' },
        { key: 'Intel.TipLimits.MaxCost', label: 'Most a tip costs' }] },
    { title: 'Intel: Hold before a tip', icon: 'hourglass',
      text: 'Off as shipped. On, a hitman can buy a tip only once they have held the contract for the '
        + 'minutes set. Before that the card and the refusal say how long is left; nothing is charged.',
      links: [{ key: 'Intel.HoldFirst.Enabled', label: 'On or off' },
        { key: 'Intel.HoldFirst.MinHeldMinutes', label: 'Minutes held' }] },
    { title: 'Intel: Informant second try', icon: 'user-secret',
      text: 'Off as shipped. On, the target\'s look-ups after the first on a contract cost this share of '
        + 'the informant\'s price (100 is the same price). The chance stays the informant\'s own.',
      links: [{ key: 'Intel.SecondTry.Enabled', label: 'On or off' },
        { key: 'Intel.SecondTry.SecondTryCostPercent', label: 'Later price' },
        { key: 'Intel.Informant.RevealChancePercent', label: 'The chance' }] },
    { title: 'Intel: Tip safe zones', icon: 'shield',
      text: 'Off as shipped. On, no tip is sold while the target stands inside one of the zones '
        + '(x, y, radius, name). The hitman is told only "Your informant can\'t place them right now.", '
        + 'never why or where, and nothing is charged.',
      links: [{ key: 'Intel.SafeZones.Enabled', label: 'On or off' },
        { key: 'Intel.SafeZones.Zones', label: 'The zones' }] },
    { title: 'Intel: Go dark', icon: 'eye-slash',
      text: 'Off as shipped. On, a target who was told of a tip can pay from On me to go dark. For the '
        + 'minutes set, every tip bought on them finds nothing: the hitman is told the informant could '
        + 'not find them and gets the price back in full. Nothing names anybody.',
      links: [{ key: 'Intel.GoDark.Enabled', label: 'On or off' },
        { key: 'Intel.GoDark.Cost', label: 'The price' },
        { key: 'Intel.GoDark.Minutes', label: 'How long' }] });

  /* ---------- a character's record (server/record/) ---------- */

  GROUP_INTRO['Record: Reputation'] = 'Trust for a completion scaled by how it was done.';
  GROUP_INTRO['Record: Placer record'] = 'A placer\'s record on the board, never who they are.';
  GROUP_INTRO['Record: Hitman heat'] = 'Police attention a hitman\'s work builds up, naming nobody.';
  GROUP_INTRO['Record: Tiered board'] = 'Bigger rewards locked to higher progression levels.';

  HELP.push(
    { title: 'Record: Reputation earned in character', icon: 'star',
      text: 'Off as shipped. On, the progression trust a completion earns is multiplied: a base factor for a '
        + 'plain completion, plus a bonus each for the thread used, a meeting point, a live handover and no '
        + 'witnesses near the hitman, up to a cap. The hitman sees the breakdown on their completion notice. '
        + 'It needs Criminal progression on to give any trust.',
      links: [{ key: 'Record.Reputation.Enabled', label: 'Reputation' },
        { key: 'Record.Reputation.BaseFactor', label: 'Factors and cap' },
        { key: 'Record.Reputation.WitnessRadius', label: 'Witness radius' }] },
    { title: 'Record: Placer record', icon: 'briefcase',
      text: 'Off as shipped. On, a board card shows how many contracts its placer placed, had paid out and '
        + 'cancelled over the last days set, not counting this one, and never who they are. A named placer\'s '
        + 'counts are exact. An anonymous placer shows nothing unless "anonymous placers too" is on, and then '
        + 'only their anonymous contracts, in bands (0, 1-4, 5-9, 10+), fixed when the card is first drawn, so '
        + 'two anonymous contracts cannot be tied to one person by their numbers.',
      links: [{ key: 'Record.PlacerRecord.Enabled', label: 'Placer record' },
        { key: 'Record.PlacerRecord.ShowForAnonymous', label: 'Anonymous placers' },
        { key: 'Record.PlacerRecord.LookbackDays', label: 'Days counted' }] },
    { title: 'Record: Hitman heat', icon: 'fire',
      text: 'Off as shipped. On, a hitman gets heat for a completion on a whitelisted-job target, a witness '
        + 'report on a completion, and a police bulletin about their acceptance or tip on a whitelisted-job '
        + 'target. Heat fades after the hours set. At the threshold they are known: a contract they take warns '
        + 'its target (the paranoid alert) at the chance set, and while they hold one, officers get a vague '
        + 'bulletin at most every so many minutes. Nothing names the hitman, and players never see heat.',
      links: [{ key: 'Record.Heat.Enabled', label: 'Hitman heat' },
        { key: 'Record.Heat.Threshold', label: 'Heat and threshold' },
        { key: 'Record.Heat.DecayHours', label: 'How long heat stays' },
        { key: 'Record.Heat.BulletinText', label: 'The bulletin' }] },
    { title: 'Record: Tiered board', icon: 'layer-group',
      text: 'Off as shipped, and only with Criminal progression on. Each tier is a name, the least reward and '
        + 'the least level. A hitman\'s level is 1, plus one for each so many contracts they completed. A card '
        + 'in a tier above their level shows locked, with the level needed, and the server refuses Accept on '
        + 'it before taking anything.',
      links: [{ key: 'Record.Tiers.Enabled', label: 'Tiered board' },
        { key: 'Record.Tiers.Tiers', label: 'Tiers' },
        { key: 'Record.Tiers.CompletionsPerLevel', label: 'Completions per level' },
        { key: 'Record.Progression.Enabled', label: 'Criminal progression' }] });

  /* ---------- contract decay (server/imp_board.lua) ---------- */

  GROUP_INTRO['Improvements: Contract decay'] = 'An untaken contract\'s reward rises, or it ends sooner.';

  HELP.push(
    { title: 'Improvements: Contract decay', icon: 'hourglass-half',
      text: 'Off as shipped. On, a contract nobody has taken changes every so many hours. "rise": its reward '
        + 'goes up by the percent set, charged to its placer through their own add-to-reward path, up to the '
        + 'most set in all; it waits while they are away, and stops for good if they cannot pay. "shorten": '
        + 'its deadline comes in by the percent of the time left. The placer is told each time, and can turn '
        + 'it off for their contract from its card.',
      links: [{ key: 'Improvements.ContractDecay.Enabled', label: 'Contract decay' },
        { key: 'Improvements.ContractDecay.Mode', label: 'Rise or shorten' },
        { key: 'Improvements.ContractDecay.Percent', label: 'Step, cap and account' },
        { key: 'Improvements.ContractDecay.Hours', label: 'Hours between steps' }] });

  /* ---------- the staff and economy improvements (Config.Improvements) ---------- */

  HELP.push(
    { title: 'Improvements: Proof items', icon: 'id-card',
      text: 'Off as shipped. On, a hitman on a contract a kill completes can tap Hand over proof '
        + 'standing beside the person who placed it, carrying an item taken from the target (as '
        + 'shipped an id card whose citizenid names them). The server finds the item in the '
        + 'hitman\'s inventory, checks it names the target and the distance, takes the item and '
        + 'pays as for a verified kill. A payout refused gives the item back. Contracts placed '
        + 'for a live delivery only are never paid this way.',
      links: [{ key: 'Improvements.ProofItems.Enabled', label: 'Proof items on or off' },
        { key: 'Improvements.ProofItems.Item', label: 'The item' },
        { key: 'Improvements.ProofItems.MetadataKey', label: 'The field naming the target' },
        { key: 'Improvements.ProofItems.HandoverRadius', label: 'The distance' }] },
    { title: 'Improvements: Completion cooldown', icon: 'hourglass',
      text: 'Off as shipped (0). Set, nobody may place a contract on somebody for this long after '
        + 'a contract on them was completed, or for the ordinary wait after any contract if that '
        + 'is longer. The placer is told how many hours are left, and nothing else.',
      links: [{ key: 'Limits.TargetCooldownAfterCompletionSeconds', label: 'The wait' }] },
    { title: 'Improvements: Weapon serial scrubbing', icon: 'gun',
      text: 'Off as shipped. On, a weapon an anonymous placer put up reaches the hitman with a new '
        + 'random serial, so it cannot be traced back to them by its number. A refund to the placer '
        + 'is their own weapon unchanged. Each scrub is in the log; the original serial is shown '
        + 'only to staff with the identity ACE.',
      links: [{ key: 'Improvements.SerialScrub.Enabled', label: 'Scrubbing on or off' }] },
    { title: 'Improvements: Weekly stats to Discord', icon: 'chart-column',
      text: 'Off as shipped. On, once a week on the day and hour set, one post of the last seven '
        + 'days: contracts placed, contracts completed and money paid out to hitmen. Totals only, '
        + 'never a name, a citizen id or a handle for any hitman. To the webhook in '
        + 'crimson_hitman_stats_webhook, or else the alert webhook. At most once a week.',
      links: [{ key: 'Improvements.WeeklyStats.Enabled', label: 'Weekly stats on or off' },
        { key: 'Improvements.WeeklyStats.Day', label: 'The day' },
        { key: 'Improvements.WeeklyStats.Hour', label: 'The hour' }] });

  /* ---------- Target limits ----------------------------------------------

     Its own section (server/targetlimits.lua): Defaults (the six limits as
     settings), Per job (a job's own limits, and one action for every player
     of a job), Per player (one target's standing, exactly, and the staff
     actions on it), and a link to the one list of contracts listing the
     live ones by target (Contracts, 'contracts:bytarget'). Every write takes the
     two-click confirm; a player's are named by the lookup made here. */

  function tlReset() {
    S.tl = { meta: null, error: null, jobAnswer: null, jobCount: null, jobCountFor: '', jobAnswerMany: null,
             status: null, ref: null, answer: null, exempt: false,
             countTimer: null };
  }
  tlReset();

  var TL_SOURCE = { global: 'global', job: 'job', player: 'player' };
  /** The limits' short names, for the job table's columns. */
  var TL_SHORT = {
    TargetCooldownAfterResolveSeconds: 'After one ends', SameCreatorSameTargetCooldownSeconds: 'Same placer',
    TargetCooldownAfterCompletionSeconds: 'After completed', MaxActiveContractsPerTarget: 'Live at once',
    MaxContractsPerTargetPerDay: 'Per 24 h', MaxContractsPerTargetPerWeek: 'Per 7 days'
  };

  function tlKeys() { return asList(S.tl.meta && S.tl.meta.keys); }

  /** A limit's value in words: seconds as a span, 0 as off where 0 is off. */
  function tlValue(entry, value) {
    var n = Number(value) || 0;
    if (entry.unit === 's') {
      if (n === 0) return 'off';
      var d = Math.floor(n / 86400), hr = Math.floor((n % 86400) / 3600), mi = Math.floor((n % 3600) / 60);
      var parts = [];
      if (d) parts.push(d + ' d');
      if (hr) parts.push(hr + ' h');
      if (mi) parts.push(mi + ' min');
      if (!parts.length) parts.push(n + ' s');
      return parts.join(' ');
    }
    if (n === 0 && entry.min === 0) return 'off';
    return num(n);
  }

  function loadTargetLimits() {
    return ask('targetLimits', {}, 'targetLimits').then(function (reply) {
      if (!reply) return;
      if (reply.ok) { S.tl.meta = reply.data || {}; S.tl.error = null; }
      else S.tl.error = words(reply);
      drawTl();
    });
  }

  function drawTl() {
    if (S.section === 'tljobs') setHtml(byId('tl-jobs'), tlJobsBody());
    if (S.section === 'tlplayer') setHtml(byId('tl-player'), tlPlayerBody());
  }

  /* ---- per job ---- */

  function tlLimitFields(prefix, open) {
    return h('div.tl-fields', tlKeys().map(function (k) {
      return h('label.tl-field', h('span.tl-label', String(k.label) + (k.unit === 's' ? ' (seconds)' : '')),
        field(prefix + '.' + k.key, { id: (prefix + '-' + k.key).replace(/\./g, '-'), class: 'is-short',
          inputmode: 'numeric', maxlength: '7', disabled: !open, placeholder: 'default',
          'aria-label': String(k.label) }));
    }));
  }

  /** What the form asks for: { [key] = n } for every box filled, or a refusal. */
  function tlLimitsTyped(prefix) {
    var out = {}, bad = null, count = 0;
    tlKeys().forEach(function (k) {
      var raw = trim(S.forms[prefix + '.' + k.key]);
      if (!raw) return;
      if (!/^\d{1,7}$/.test(raw) || Number(raw) < k.min || Number(raw) > k.max) {
        bad = bad || (String(k.label) + ' is a whole number from ' + k.min + ' to ' + k.max + '.');
        return;
      }
      out[k.key] = Number(raw);
      count++;
    });
    return { limits: out, bad: bad, count: count };
  }

  function tlJobTable() {
    var jobs = asList(S.tl.meta && S.tl.meta.jobs);
    if (!jobs.length) return empty('No job has limits of its own: every target has the defaults.');
    var keys = tlKeys();
    return h('div.table-wrap', h('table.grid',
      h('thead', h('tr', h('th', 'Job'), keys.map(function (k) {
        return h('th', { title: String(k.label) }, TL_SHORT[k.key] || String(k.label));
      }), h('th', ''))),
      h('tbody', jobs.map(function (j) {
        var own = j.limits || {}, eff = j.effective || {};
        return h('tr',
          h('td.mono.tl-job', String(j.job)),
          keys.map(function (k) {
            var mine = own[k.key] !== undefined && own[k.key] !== null;
            return h('td' + (mine ? '.is-own' : ''), { title: mine ? 'This job\'s own' : 'The default' },
              tlValue(k, eff[k.key]));
          }),
          h('td.nowrap', btn('.is-small.ghost', 'tj-edit', { 'data-value': String(j.job) }, 'Edit', 'pen'),
            ' ', writeBtn('.is-small.danger', 'tj-remove', { 'data-value': String(j.job) }, 'Remove',
              'Click again to remove ' + String(j.job), 'trash')));
      }))));
  }

  /** Who a job action reaches, in words, once counted. */
  function tlJobWho() {
    var job = trim(S.forms['tja.job']).toLowerCase();
    var count = S.tl.jobCountFor === job ? S.tl.jobCount : null;
    return { count: count, text: count === null ? 'the players of ' + (job || 'that job')
      : num(count) + ' player' + (count === 1 ? '' : 's') + ' working ' + job };
  }

  /** A job action's buttons, each confirm naming the job and the count:
      drawn again on their own when the count comes, never the box being typed in. */
  function tlManyButtons() {
    var who = tlJobWho().text;
    return frag(
      modBtn('', 'tja-reset', { 'data-value': 'reset' }, 'Reset cooldowns', 'Click again: reset ' + who,
        'arrow-rotate-left'),
      modBtn('', 'tja-reset-all', { 'data-value': 'all' }, 'Reset all', 'Click again: reset all for ' + who,
        'arrows-rotate'),
      modBtn('', 'tja-extend', { 'data-value': 'extend' }, 'Extend cooldowns', 'Click again: extend ' + who,
        'hourglass'),
      modBtn('', 'tja-counts', { 'data-value': 'counts' }, 'Reset counts', 'Click again: reset counts for ' + who,
        'eraser'));
  }

  function tlJobsBody() {
    if (S.tl.error) return empty(S.tl.error);
    if (!S.tl.meta) return loading('Reading the job limits…');
    var open = writesOpen();
    var many = modOpen();
    var counted = tlJobWho();
    return frag(
      card('A job\'s own limits', frag(
        h('p.note', 'A target working this job when the contract is placed (their qbx job name) has the limits '
          + 'you fill in here instead of the defaults; leave a box empty to keep the default. Changing these '
          + 'needs the staff ACE (Config.Admin.Ace).'),
        h('div.inline-form.is-wide',
          field('tj.job', { id: 'tj-job', class: 'is-short', maxlength: String((S.tl.meta.jobMax) || 32),
            placeholder: 'Job name (police)', disabled: !open, 'aria-label': 'Job name' })),
        tlLimitFields('tj', open),
        h('div.btn-row', writeBtn('.primary', 'tj-save', { id: 'tj-save' }, 'Save job limits',
          'Click again to save', 'floppy-disk')),
        answerBox(S.tl.jobAnswer))),
      card('Jobs with their own limits', tlJobTable(), '',
        h('span.sub', 'what applies; in bold, the job\'s own (the rest are the defaults)')),
      card('Every player of a job, at once', frag(
        h('p.note', 'Reset or extend the cooldowns, or reset the day and week counts, of every player in the city '
          + 'working this job now and every player not in the city whom the latest contract on them in the last '
          + '7 days recorded as working it. One row goes in the log, with the count.'),
        h('div.inline-form.is-wide',
          field('tja.job', { id: 'tja-job', class: 'is-short', maxlength: '32', placeholder: 'Job name',
            disabled: !many, 'data-live': 'tja-count', 'aria-label': 'Job name for a job action' }),
          h('span.sub', { id: 'tja-count' }, counted.count === null ? '' : counted.text),
          field('tja.min', { id: 'tja-min', class: 'is-short', inputmode: 'numeric', maxlength: '5',
            placeholder: 'Minutes', disabled: !many, 'aria-label': 'Minutes to extend by' })),
        h('div.inline-form.is-wide',
          field('tja.reason', { id: 'tja-reason', class: 'is-grow', maxlength: '120', disabled: !many,
            placeholder: 'Reason (required, kept in the log)', 'aria-label': 'Reason for the job action' })),
        h('div.btn-row.tl-many', { id: 'tja-buttons' }, tlManyButtons()),
        answerBox(S.tl.jobAnswerMany))));
  }

  SHELL.tljobs = function () {
    return h('section.view', h('p.hint', 'Limits for targets on one job, and one action for every player of a job.'),
      h('div.stack', { id: 'tl-jobs' }, tlJobsBody()));
  };
  LOAD.tljobs = function () { loadTargetLimits(); };

  function tlJobRefuse(slot, text) {
    disarm();
    S.tl[slot] = { ok: false, text: text };
    drawTl();
  }

  ACTIONS['tj-edit'] = function (node) {
    var job = node.getAttribute('data-value') || '';
    var row = asList(S.tl.meta && S.tl.meta.jobs).filter(function (j) { return j.job === job; })[0];
    S.forms['tj.job'] = job;
    tlKeys().forEach(function (k) {
      var v = row && row.limits ? row.limits[k.key] : undefined;
      S.forms['tj.' + k.key] = v === undefined || v === null ? '' : String(v);
    });
    disarm();
    drawTl();
  };
  ACTIONS['tj-save'] = function (node) {
    var job = trim(S.forms['tj.job']).toLowerCase();
    if (!/^[a-z0-9_]{1,32}$/.test(job)) {
      return tlJobRefuse('jobAnswer', 'A job name is its qbx name: lower-case letters, digits and _.');
    }
    var typed = tlLimitsTyped('tj');
    if (typed.bad) return tlJobRefuse('jobAnswer', typed.bad);
    if (!typed.count) return tlJobRefuse('jobAnswer', 'Fill in at least one limit for the job.');
    if (!confirmed(node, 'Click again: save limits for ' + job)) return;
    write('targetJobSet', { job: job, limits: typed.limits }, 'tl:job:' + job, node).then(function (reply) {
      if (!reply) return;
      S.tl.jobAnswer = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) loadTargetLimits(); else drawTl();
    });
  };
  ACTIONS['tj-remove'] = function (node) {
    var job = node.getAttribute('data-value') || '';
    if (!confirmed(node)) return;
    write('targetJobRemove', { job: job }, 'tl:job:' + job, node).then(function (reply) {
      if (!reply) return;
      S.tl.jobAnswer = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) loadTargetLimits(); else drawTl();
    });
  };

  /** How many players a job action reaches, asked as the job is typed. */
  function tlJobCount() {
    var job = trim(S.forms['tja.job']).toLowerCase();
    if (!/^[a-z0-9_]{1,32}$/.test(job)) { S.tl.jobCount = null; S.tl.jobCountFor = ''; return Promise.resolve(); }
    return ask('targetJobCount', { job: job }, 'targetJobCount').then(function (reply) {
      if (!reply || !reply.ok || !reply.data) return;
      S.tl.jobCount = Number(reply.data.count) || 0;
      S.tl.jobCountFor = String(reply.data.job || job);
      if (S.section !== 'tljobs') return;
      var counted = tlJobWho();
      var span = byId('tja-count');
      if (span) span.textContent = counted.count === null ? '' : counted.text;
      var buttons = byId('tja-buttons');
      if (buttons) { setHtml(buttons, tlManyButtons()); rearm(buttons); }
    });
  }
  LIVE['tja-count'] = function () {
    clearTimeout(S.tl.countTimer);
    S.tl.countTimer = setTimeout(function () { S.tl.countTimer = null; tlJobCount(); }, DEBOUNCE_MS);
  };

  function tlJobAction(node, action, all) {
    var job = trim(S.forms['tja.job']).toLowerCase();
    var reason = trim(S.forms['tja.reason']);
    if (!/^[a-z0-9_]{1,32}$/.test(job)) return tlJobRefuse('jobAnswerMany', 'Give the job\'s qbx name first.');
    var data = { job: job, action: action, all: all === true, reason: reason.slice(0, 120) };
    if (action === 'extend') {
      var min = wholeNumber(S.forms['tja.min']);
      var most = Number(S.tl.meta && S.tl.meta.extendMax) || 43200;
      if (!min || min > most) return tlJobRefuse('jobAnswerMany', 'Give the minutes to add, 1 to ' + most + '.');
      data.minutes = min;
    }
    if (!reason) return tlJobRefuse('jobAnswerMany', 'Give a reason: it goes on the record.');
    if (S.tl.jobCountFor !== job) {
      // The confirm names how many it reaches: counted first.
      tlJobCount();
      return tlJobRefuse('jobAnswerMany', 'Counting the players of ' + job + ': click again once the count shows.');
    }
    if (!confirmed(node)) return;
    write('targetJobAction', data, 'tl:jobaction:' + job, node).then(function (reply) {
      if (!reply) return;
      S.tl.jobAnswerMany = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      drawTl();
    });
  }
  ACTIONS['tja-reset'] = function (node) { tlJobAction(node, 'reset', false); };
  ACTIONS['tja-reset-all'] = function (node) { tlJobAction(node, 'reset', true); };
  ACTIONS['tja-extend'] = function (node) { tlJobAction(node, 'extend', false); };
  ACTIONS['tja-counts'] = function (node) { tlJobAction(node, 'counts', false); };

  /* ---- per player ---- */

  var TL_RULE = {
    TargetCooldownAfterResolveSeconds: 'the wait after a contract on them ended',
    TargetCooldownAfterCompletionSeconds: 'the wait after a completed contract',
    'Immunity.AfterBailoutSeconds': 'the breather after a buyout',
    staff: 'a cooldown staff extended'
  };

  function loadTargetStatus(again) {
    var subject = trim(S.forms['tp.q']);
    var byRef = again === true && S.tl.ref ? S.tl.ref : null;
    if (!subject && !byRef) { toast('Give a player id, a citizen id or a name.', 'error'); return Promise.resolve(); }
    disarm();
    var sent = byRef ? { ref: byRef } : { subject: subject.slice(0, 64) };
    var keep = again === true ? S.tl.answer : null;
    return ask('targetStatus', sent, 'targetStatus').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) {
        S.tl.status = { error: words(reply) };
        if (!byRef) S.tl.ref = null;
        toast(words(reply), 'error');
      } else {
        S.tl.status = reply.data || {};
        var p = S.tl.status.player || {};
        S.tl.ref = typeof p.ref === 'string' ? p.ref : null;
      }
      S.tl.answer = keep;
      drawTl();
    });
  }

  function tlStatusCard(d) {
    var st = d.status || {};
    var p = d.player || {};
    var keys = tlKeys();
    var left = Number(st.cooldownLeft) || 0;
    var adj = st.adjustment || {};
    var ov = adj.override;
    return frag(
      h('div.person',
        h('h2', String(p.name || 'No name on record')),
        p.cid ? h('span.cid', String(p.cid)) : h('span.chip', 'citizen id hidden'),
        p.online ? h('span.chip.is-live', 'in the city') : h('span.chip', 'offline'),
        st.job ? h('span.chip.is-job', 'job: ' + String(st.job) + (st.jobFrom === 'last known' ? ' (last known)' : '')) : null,
        st.exempt ? h('span.chip.is-warn', 'Exempt from limits') : null),
      h('div.tiles.is-compact',
        tile('Live on them', h('p.big', num(st.live) + ' / ' + (st.exempt ? '—' : num(st.limits && st.limits.MaxActiveContractsPerTarget)))),
        tile('Placed, 24 hours', h('p.big', num(st.day))),
        tile('Placed, 7 days', h('p.big', num(st.week))),
        tile('Cooldown left', h('p.big' + (left > 0 ? '.is-warn' : ''), left > 0 ? exactSpan(left) : 'none'))),
      left > 0 ? h('p.note', 'Set by ' + (TL_RULE[st.cooldownRule] || String(st.cooldownRule)) + ' (from the '
        + (TL_SOURCE[st.cooldownFrom] || 'global') + ' limits).') : null,
      Number(st.dayAll) !== Number(st.day) || Number(st.weekAll) !== Number(st.week)
        ? h('p.note', 'Counted since staff reset the counts: ' + num(st.dayAll) + ' in 24 hours and ' + num(st.weekAll)
          + ' in 7 days in all.') : null,
      h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Limit'), h('th', 'Applies to them'), h('th', 'From'))),
        h('tbody', keys.map(function (k) {
          var from = st.source ? st.source[k.key] : 'global';
          return h('tr', h('td', String(k.label)),
            h('td', st.exempt ? 'exempt' : tlValue(k, st.limits ? st.limits[k.key] : 0)),
            h('td', st.exempt ? 'player' : (TL_SOURCE[from] || 'global')));
        })))),
      ov ? h('p.sub', (ov.exempt ? 'Exempt from limits' : 'Their own limits') + ' '
        + (ov.until_at ? 'until ' + when(ov.until_at) : 'for good') + (ov.reason ? ': ' + String(ov.reason) : '')) : null,
      adj.until_at && Number(adj.until_at) > nowSeconds()
        ? h('p.sub', 'Cooldown extended by staff until ' + when(adj.until_at)) : null);
  }

  function tlPlayerActions() {
    var open = modOpen();
    var ref = S.tl.ref;
    var a = function (extra) { var o = extra || {}; o['data-ref'] = ref; return o; };
    var keys = tlKeys();
    return frag(
      card('Staff actions on them', frag(
        h('p.note', 'Every action takes a reason, goes on the record and needs the moderator ACE or the staff ACE. '
          + 'Reset cooldown lets them be named now and keeps the same placer\'s wait; Reset all clears that too, '
          + 'and any extension. Players are never told.'),
        h('div.inline-form.is-wide',
          field('tp.reason', { id: 'tp-reason', class: 'is-grow', maxlength: '120', disabled: !open,
            placeholder: 'Reason (required, kept in the log)', 'aria-label': 'Reason for the action' })),
        h('div.btn-row.tl-many',
          modBtn('', 'tp-reset', a(), 'Reset cooldown', 'Click again to reset', 'arrow-rotate-left'),
          modBtn('', 'tp-reset-all', a(), 'Reset all', 'Click again to reset all', 'arrows-rotate'),
          modBtn('', 'tp-counts', a(), 'Reset counts', 'Click again to reset the counts', 'eraser')),
        h('div.inline-form.is-wide',
          field('tp.min', { id: 'tp-min', class: 'is-short', inputmode: 'numeric', maxlength: '5', disabled: !open,
            placeholder: 'Minutes', 'aria-label': 'Minutes to extend the cooldown by' }),
          modBtn('', 'tp-extend', a(), 'Extend by minutes', 'Click again to extend', 'hourglass'),
          field('tp.until', { id: 'tp-until', class: 'is-short', maxlength: '16', disabled: !open,
            placeholder: 'YYYY-MM-DD HH:MM', 'aria-label': 'Hold the cooldown until' }),
          modBtn('', 'tp-until-set', a(), 'Hold until', 'Click again to hold until then', 'calendar'))),
        '', null),
      card('Their own limits', frag(
        h('p.note', 'Over the job\'s and the defaults, for some hours or for good (0). Leave a box empty to keep '
          + 'what applies now. Exempt lifts every limit; a cooldown staff extended still holds.'),
        h('div.inline-form.is-wide',
          segmented('tpo-mode', [{ value: 'custom', label: 'Custom limits', disabled: !open },
            { value: 'exempt', label: 'Exempt from limits', disabled: !open }], S.tl.exempt ? 'exempt' : 'custom'),
          field('tpo.hours', { id: 'tpo-hours', class: 'is-short', inputmode: 'numeric', maxlength: '4',
            disabled: !open, placeholder: 'Hours (0 = for good)', 'aria-label': 'Hours the override lasts' })),
        S.tl.exempt ? null : tlLimitFields('tpo', open),
        h('div.btn-row',
          modBtn('.primary', 'tpo-set', a(), S.tl.exempt ? 'Make exempt' : 'Set their limits',
            'Click again to set', 'user-shield'),
          keys.length ? modBtn('', 'tpo-clear', a(), 'Lift their own limits', 'Click again to lift', 'unlock') : null))),
      answerBox(S.tl.answer));
  }

  function tlPlayerBody() {
    var d = S.tl.status;
    if (!S.tl.meta && !S.tl.error) return loading('Reading the limits…');
    if (!d) return empty('Look somebody up by their player id, citizen id or name, as Players does.');
    if (d.error) return empty(d.error);
    return frag(card('As a target', tlStatusCard(d)), tlPlayerActions());
  }

  SHELL.tlplayer = function () {
    return h('section.view',
      h('div.toolbar',
        h('label.search', icon('magnifying-glass'),
          field('tp.q', { id: 'tp-q', placeholder: 'Player id, citizen id or name', 'data-enter': 'tp-lookup',
            'aria-label': 'Player id, citizen id or name' })),
        btn('.primary', 'tp-lookup', {}, 'Look up', 'arrow-right')),
      h('p.hint', 'Exact times, which players never see. Each lookup is on the record.'),
      h('div.stack', { id: 'tl-player' }, tlPlayerBody()));
  };
  LOAD.tlplayer = function () { if (!S.tl.meta) loadTargetLimits(); };

  ACTIONS['tp-lookup'] = function () {
    S.tl.answer = null;
    loadTargetStatus(false);
  };

  function tlRefuse(text) {
    disarm();
    S.tl.answer = { ok: false, text: text };
    drawTl();
  }

  /** A write from the card: named by the lookup's handle, the answer kept,
      and the card read again by the same handle once it went through. */
  /** Each write from the card, by name, so every op the page asks for reads plainly. */
  var TL_SEND = {
    reset: function (d, node) { return write('targetReset', d, 'tl:player', node); },
    counts: function (d, node) { return write('targetCounts', d, 'tl:player', node); },
    extend: function (d, node) { return write('targetExtend', d, 'tl:player', node); },
    override: function (d, node) { return write('targetOverride', d, 'tl:player', node); },
    clear: function (d, node) { return write('targetOverrideClear', d, 'tl:player', node); }
  };

  function tlWrite(node, send, extra) {
    if (!S.tl.ref) return tlRefuse('Look them up first.');
    var reason = trim(S.forms['tp.reason']);
    if (!reason) return tlRefuse('Give a reason: it goes on the record.');
    if (!confirmed(node)) return;
    var data = { ref: S.tl.ref, reason: reason.slice(0, 120) };
    Object.keys(extra || {}).forEach(function (k) { data[k] = extra[k]; });
    send(data, node).then(function (reply) {
      if (!reply) return;
      S.tl.answer = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) loadTargetStatus(true); else drawTl();
    });
  }

  ACTIONS['tp-reset'] = function (node) { tlWrite(node, TL_SEND.reset, { all: false }); };
  ACTIONS['tp-reset-all'] = function (node) { tlWrite(node, TL_SEND.reset, { all: true }); };
  ACTIONS['tp-counts'] = function (node) { tlWrite(node, TL_SEND.counts, {}); };
  ACTIONS['tp-extend'] = function (node) {
    var min = wholeNumber(S.forms['tp.min']);
    var most = Number(S.tl.meta && S.tl.meta.extendMax) || 43200;
    if (!min || min > most) return tlRefuse('Give the minutes to add, 1 to ' + most + '.');
    tlWrite(node, TL_SEND.extend, { minutes: min });
  };
  ACTIONS['tp-until-set'] = function (node) {
    var at = parseWhen(S.forms['tp.until'], false);
    if (!at) return tlRefuse('Give the time as YYYY-MM-DD HH:MM.');
    if (at <= nowSeconds()) return tlRefuse('That time has passed.');
    tlWrite(node, TL_SEND.extend, { untilAt: at });
  };
  ACTIONS['tpo-mode'] = function (node) {
    S.tl.exempt = node.getAttribute('data-value') === 'exempt';
    disarm();
    drawTl();
  };
  ACTIONS['tpo-set'] = function (node) {
    var raw = trim(S.forms['tpo.hours']);
    var max = Number(S.tl.meta && S.tl.meta.overrideMaxHours) || 8760;
    if (!/^\d{1,4}$/.test(raw) || Number(raw) > max) return tlRefuse('Give the hours, 0 for good, up to ' + max + '.');
    if (S.tl.exempt) return tlWrite(node, TL_SEND.override, { exempt: true, hours: Number(raw) });
    var typed = tlLimitsTyped('tpo');
    if (typed.bad) return tlRefuse(typed.bad);
    if (!typed.count) return tlRefuse('Fill in at least one limit, or choose Exempt.');
    tlWrite(node, TL_SEND.override, { exempt: false, limits: typed.limits, hours: Number(raw) });
  };
  ACTIONS['tpo-clear'] = function (node) { tlWrite(node, TL_SEND.clear, {}); };


  STAFF_ACTIONS.push(
    { title: 'Target limits', icon: 'user-clock', view: 'tlplayer', go: 'Open Per player',
      text: 'How often one person may have a contract placed on them: the defaults, a job\'s own, and one '
        + 'player\'s cooldown reset or extended, counts reset, own limits or exempt; the same for every player '
        + 'of a job at once. Live contracts by target opens Contracts with the live ones grouped by target.',
      also: { view: 'tljobs', go: 'Per job' } });

  HELP.push(
    { title: 'Target limits', icon: 'user-clock',
      text: 'The limits on how often one person may be targeted. A player\'s own override wins, then their job\'s '
        + '(the job they are working when the contract is placed), then the defaults. Day and week caps are off '
        + 'as shipped. Players are told only what the target rules always said, never a time, a job or staff.',
      links: [{ key: 'Limits.MaxContractsPerTargetPerDay', label: 'Day cap' },
        { key: 'Limits.MaxContractsPerTargetPerWeek', label: 'Week cap' }] });

  /* ---------- the new layout's own clicks: chips, search, areas -------- */

  ACTIONS['nav-menu'] = function () { S.navOpen = !S.navOpen; drawChrome(); };
  ACTIONS['ctx-player'] = function () { show(PLAYER_VIEWS[S.section] ? S.section : 'players'); };
  ACTIONS['ctx-relookup'] = function () {
    if (!S.players.subject) { show('players'); return; }
    S.forms['pl.q'] = S.players.subject;
    loadPlayer();
  };
  ACTIONS['ctx-player-clear'] = function () {
    disarm();
    S.players.data = null;
    S.players.ref = null;
    S.players.subject = null;
    S.players.at = 0;
    resetPlayerStaff();
    if (PLAYER_VIEWS[S.section]) show('players'); else drawChrome();
  };
  ACTIONS['ctx-contract'] = function () { if (S.ctx.contract) openContract(S.ctx.contract); };
  ACTIONS['ctx-contract-clear'] = function () {
    S.ctx.contract = null;
    if (S.drawer.id) closeDrawer();
    drawContext();
  };
  /** The header's Refresh: the section open read again. */
  ACTIONS['refresh-view'] = function () {
    loadOverview(true);
    if (SETTING_VIEWS[S.section]) { loadSettings(); return; }
    if (ORG_VIEWS[S.section] || BP_VIEWS[S.section]) { loadOrg(); }
    LOAD[S.section]();
  };
  ACTIONS['help-btn'] = function () { openGroup('help'); };

  ACTIONS['ib-filter'] = function (node) {
    var v = node.getAttribute('data-value');
    S.inbox = ['reviews', 'stuck', 'alerts'].indexOf(v) !== -1 ? v : 'all';
    show('inbox');
  };
  ACTIONS['ib-go'] = function (node) { ACTIONS['ib-filter'](node); };
  ACTIONS['ib-refresh'] = function () {
    S.stuck.answers = {};
    LOAD.inbox();
  };

  ACTIONS['gr-area'] = function (node) {
    S.rules.area = node.getAttribute('data-value') || '';
    S.forms['st.q'] = '';
    drawSettings();
    var main = byId('main');
    if (main) main.scrollTop = 0;
  };
  ACTIONS['gr-type'] = function (node) {
    S.rules.type = node.getAttribute('data-value') || '';
    drawSettings();
  };
  ACTIONS['st-details'] = function (node) {
    var key = node.getAttribute('data-key');
    S.settings.open[key] = !S.settings.open[key];
    drawSettingRow(key);
  };

  ACTIONS['help-toggle'] = function (node) {
    var title = node.getAttribute('data-value');
    S.help.open[title] = !S.help.open[title];
    redraw();
  };
  ACTIONS['help-all'] = function () { HELP.forEach(function (c) { S.help.open[c.title] = true; }); redraw(); };
  ACTIONS['help-none'] = function () { S.help.open = {}; redraw(); };

  ACTIONS['pl-recent'] = function (node) {
    S.forms['pl.q'] = node.getAttribute('data-value') || '';
    loadPlayer();
  };
  ACTIONS['pl-open-cid'] = function (node) {
    S.forms['pl.q'] = node.getAttribute('data-value') || '';
    show('players');
    loadPlayer();
  };
  /** Their standing as a target, in Target limits, by the same lookup. */
  ACTIONS['pl-tl'] = function () {
    if (!S.players.ref) return;
    S.tl.ref = S.players.ref;
    S.tl.answer = null;
    show('tlplayer');
    loadTargetStatus(true);
  };
  /** Why can't they see...: the diagnosis as the player selected, by the
      lookup's handle (they have to be in the city). */
  ACTIONS['pl-diag'] = function () {
    var ref = S.players.ref;
    if (!ref) return;
    var run = { ref: ref, lines: ['Running…'], later: [] };
    S.tools.pdiag = run;
    drawTools();
    // Its own channel, apart from Health's server diagnosis.
    ask('diag', { ref: ref }, 'pdiag').then(function (reply) {
      // Dropped when another run, or another player, took its place.
      if (!reply || S.tools.pdiag !== run) return;
      if (!reply.ok) S.tools.pdiag = { ref: ref, error: words(reply) };
      else S.tools.pdiag = { ref: ref, lines: asList((reply.data || {}).lines), later: run.later };
      drawTools();
    });
  };
  ACTIONS['ms-kind'] = function (node) {
    S.players.measureKind = node.getAttribute('data-value') || '';
    drawMeasures();
  };
  /** The overview's counts open the list on one kind. */
  ACTIONS['ms-open'] = function (node) {
    S.players.measureKind = node.getAttribute('data-value') || '';
    show('measures');
  };
  /** Lift on a row, by the list's handle: unfreeze, unsuspend or unprotect. */
  ACTIONS['pl-lift-row'] = function (node) {
    var ref = node.getAttribute('data-ref');
    var k = measureKind(node.getAttribute('data-value'));
    if (!ref || !k.lift || !confirmed(node)) return;
    var slot = k.id + ':' + ref;
    write(k.lift, { ref: ref }, 'lift:' + slot, node).then(function (reply) {
      if (!reply) return;
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) delete S.players.lift[slot];
      else S.players.lift[slot] = { ok: false, text: words(reply) };
      if (reply.ok && S.players.data && S.players.data.frozen && k.id === 'freeze') loadPlayer(true);
      if (reply.ok) loadMeasures(); else drawMeasures();
    });
  };

  ACTIONS['dr-tab'] = function (node) {
    disarm();
    S.drawer.tab = node.getAttribute('data-value') || 'summary';
    drawDrawer();
  };
  ACTIONS['dr-more'] = function () {
    disarm();
    S.drawer.more = !S.drawer.more;
    drawDrawer();
  };

  /* ---------- the header search: settings, actions, sections, players ----

     Typed into the header's box (/ or Ctrl+K go there): matches as you
     type, from what the page already holds, at most SEARCH_MAX rows. Enter
     takes the first: a contract id opens it, a player id runs a lookup, and
     any other text with nothing better matching looks it up as a player. */

  var SEARCH_MAX = 20;

  function searchSettings() {
    if (settingsIndex) return settingsIndex;
    settingsIndex = allSettings().map(function (e) {
      return { e: e, text: [e.key, e.label, e.about, e.group, areaLabel(areaOf(e))].map(function (v) {
        return v == null ? '' : String(v);
      }).join(' ').toLowerCase() };
    });
    return settingsIndex;
  }

  function searchHits(raw) {
    var q = trim(raw).toLowerCase();
    if (!q) return [];
    var hits = [];
    var contract = /^ct[a-z0-9]{3,}$/i.test(trim(raw));
    var digits = /^\d{1,6}$/.test(trim(raw));
    if (contract) hits.push({ kind: 'Contract', label: 'Open contract ' + trim(raw), act: 'gs-contract', value: trim(raw) });
    if (digits) hits.push({ kind: 'Player', label: 'Look up player id ' + trim(raw), act: 'gs-player', value: trim(raw) });
    SECTIONS.forEach(function (view) {
      if (!viewShown(view)) return;
      var g = groupOf(view);
      var label = (VIEW_LABEL[view] || [view])[0];
      if ((label + ' ' + (g ? g.label : '')).toLowerCase().indexOf(q) !== -1) {
        hits.push({ kind: 'Section', label: (g ? g.label + ' › ' : '') + label, act: 'gs-view', value: view });
      }
    });
    STAFF_ACTIONS.forEach(function (a, i) {
      if ((a.title + ' ' + a.text).toLowerCase().indexOf(q) !== -1 && viewAllowed(resolveView(a.view))) {
        hits.push({ kind: 'Action', label: a.title, act: 'gs-action', value: String(i) });
      }
    });
    searchSettings().forEach(function (row) {
      if (row.text.indexOf(q) !== -1) {
        hits.push({ kind: 'Setting', label: String(row.e.label || row.e.key), sub: areaLabel(areaOf(row.e))
          + ' · ' + (row.e.secret ? 'server.cfg' : 'Config.' + row.e.key), act: 'gs-setting', value: row.e.key });
      }
    });
    if (!contract && !digits) {
      hits.push({ kind: 'Player', label: 'Look up “' + trim(raw).slice(0, 64) + '” as a player',
        act: 'gs-player', value: trim(raw).slice(0, 64) });
    }
    return hits.slice(0, SEARCH_MAX);
  }

  function searchBody() {
    var q = S.search.q;
    if (!S.search.open || !trim(q)) return frag();
    var hits = searchHits(q);
    if (!S.settings.data) {
      hits.push({ kind: 'Note', label: 'Reading the settings: their rows join the list in a moment.', act: null });
    }
    return frag(hits.length ? hits.map(function (hit, i) {
      return h('button.gs-hit' + (i === 0 ? '.is-first' : ''), { type: 'button', 'data-act': hit.act || 'gs-none',
        'data-value': hit.value == null ? '' : String(hit.value), role: 'option' },
        h('span.gs-kind', hit.kind), h('span.gs-label', hit.label), hit.sub ? h('span.gs-sub', hit.sub) : null);
    }) : h('p.empty', 'No setting, action or section matches. Press Enter to look it up as a player.'));
  }

  function drawSearch() {
    var box = byId('gs-results');
    if (!box) return;
    box.hidden = !(S.search.open && trim(S.search.q));
    setHtml(box, searchBody());
  }

  function closeSearch() {
    S.search.open = false;
    S.search.q = '';
    S.forms['gs.q'] = '';
    var input = byId('gs-q');
    if (input) { input.value = ''; if (input.blur) input.blur(); }
    drawSearch();
  }

  LIVE['gs-input'] = function (node) {
    S.search.q = node.value;
    S.search.open = true;
    // The settings index needs the settings: read once, then kept.
    if (!S.settings.data && !S.search.asked) { S.search.asked = true; loadSettings(); }
    drawSearch();
  };
  AFTER_SETTINGS.push(function () { if (S.search.open) drawSearch(); });

  ACTIONS['gs-go'] = function () {
    var hits = searchHits(S.search.q);
    if (!hits.length) return;
    var first = hits[0];
    var fake = { getAttribute: function (k) { return k === 'data-value' ? first.value : null; } };
    if (ACTIONS[first.act]) ACTIONS[first.act](fake);
  };
  ACTIONS['gs-none'] = function () {};
  ACTIONS['gs-contract'] = function (node) {
    var id = node.getAttribute('data-value');
    closeSearch();
    openContract(id);
  };
  ACTIONS['gs-player'] = function (node) {
    var who = node.getAttribute('data-value');
    closeSearch();
    S.forms['pl.q'] = who;
    show('players');
    loadPlayer();
  };
  ACTIONS['gs-view'] = function (node) {
    var view = node.getAttribute('data-value');
    closeSearch();
    show(view);
  };
  ACTIONS['gs-action'] = function (node) {
    var a = STAFF_ACTIONS[Number(node.getAttribute('data-value'))];
    closeSearch();
    if (a) show(a.view);
  };
  ACTIONS['gs-setting'] = function (node) {
    var key = node.getAttribute('data-value');
    closeSearch();
    goSetting(key);
  };

  /** A setting's row, in the section it is edited in, marked and opened. */
  function goSetting(key) {
    var entry = settingEntry(key);
    S.forms['st.q'] = '';
    S.settings.focus = key;
    S.settings.open[key] = true;
    if (!entry && !S.settings.data) {
      // The settings are not read yet (a help link before any settings
      // view): read them, then land where the setting is.
      loadSettings().then(function () {
        if (settingEntry(key)) goSetting(key); else show('rules');
      });
      return;
    }
    if (!entry) { show('rules'); return; }
    var view = viewOfSetting(entry);
    if (view === 'rules') { S.rules.area = areaOf(entry); S.rules.type = ''; }
    show(view);
    if (!SETTING_VIEWS[view]) focusRow();
  }

  /** The row asked for, marked and brought into view, once it is drawn. */
  function focusRow() {
    var focus = S.settings.focus && byId('st-row-' + S.settings.focus);
    if (!focus) return;
    focus.classList.toggle('is-focus', true);
    if (typeof focus.scrollIntoView === 'function') focus.scrollIntoView({ block: 'center' });
    S.settings.focus = null;
  }
  AFTER_SETTINGS.push(function () { if (!SETTING_VIEWS[S.section]) focusRow(); });

  /* ---------- body disposal (server/disposal.lua) ------------------------

     Config.Disposal, off as shipped: a verified kill's payout waits until
     the body is loaded and dropped off. Contracts and Home list every step
     in force (disposalList, a read: the exact time left, whether its clock
     is held, the vehicle), each with Skip (finish it as if dropped off: the
     payout is handed over) and Respawn vehicle (made again at the spawn
     spot), both the staff ACE's, two clicks naming the contract. Locations
     sets the two spots (placeSet, kinds disposal_vehicle and disposal_drop,
     typed or where the staff member stands; placeRemove). Who the hitman is comes only with the
     identity ACE. */

  S.disposal = { data: null, error: null, errCode: null, answers: {} };

  var DISPOSAL_STAGE = { body: 'Body not loaded yet', loaded: 'Loaded, on the way to the drop-off' };
  var DISPOSAL_TIMEOUT = { pay: 'paid in full', reduced: 'paid in part, the rest back to the placer',
    refund: 'refunded to the placer' };

  function loadDisposal() {
    return ask('disposalList', {}, 'disposal').then(function (reply) {
      if (!reply) return;
      if (reply.ok) { S.disposal.data = reply.data || {}; S.disposal.error = null; S.disposal.errCode = null; }
      else { S.disposal.error = words(reply); S.disposal.errCode = reply.err || null; }
      drawDisposal();
    });
  }

  function drawDisposal() {
    var list = byId('dp-list');
    if (list) setHtml(list, disposalBody(S.section === 'contracts' ? 'contracts' : 'home'));
  }

  function disposalSteps() { return asList((S.disposal.data || {}).steps); }

  /** The steps in force; on Home only while there is one. */
  function disposalBody(where) {
    var d = S.disposal.data;
    var steps = disposalSteps();
    if (where === 'home' && !steps.length) return frag();
    if (!d) {
      // A server without disposal answers unknown_op: nothing to say here.
      return where === 'contracts' && S.disposal.error && S.disposal.errCode !== 'unknown_op'
        ? h('p.note.is-error', 'Body disposal could not be read: ' + S.disposal.error) : frag();
    }
    if (!steps.length) {
      return where === 'contracts' && d.enabled
        ? h('p.note', 'Body disposal is on: nobody is disposing of a body right now.') : frag();
    }
    var timeout = DISPOSAL_TIMEOUT[d.onTimeout] || String(d.onTimeout || 'paid in full');
    return card('Body disposal in progress (' + num(steps.length) + ')', frag(
      h('p.about', 'A verified kill\'s payout waits until the body is dropped off. Each has '
        + exactSpan(d.limitSeconds) + ' in all; on running out it is ' + timeout + '. Skip finishes one as if the '
        + 'body was dropped off; Respawn vehicle makes the vehicle again at the spawn spot.'),
      h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Contract'), h('th', 'Stage'), h('th', 'Time left'), h('th', ''))),
        h('tbody', steps.map(function (step) {
          var cid = String(step.contract || '');
          return h('tr',
            h('td', h('button.link.mono', { type: 'button', 'data-act': 'contract', 'data-id': cid }, cid),
              h('span.sub', ' payout ' + num(step.slot)),
              canIdentify() && step.hitman ? h('div.sub.mono', String(step.hitman)) : null),
            h('td', DISPOSAL_STAGE[step.stage] || String(step.stage || '—'),
              h('div.sub', 'vehicle ' + (step.vehicle ? 'there' : 'not made'), Number(step.respawns) > 0
                ? h('span.chip', num(step.respawns) + ' respawn' + (Number(step.respawns) === 1 ? '' : 's')) : null)),
            h('td.nowrap', exactSpan(step.secondsLeft), step.held ? h('div', h('span.chip.is-warn', 'clock held')) : null),
            h('td', h('div.inline-form',
              writeBtn('.is-small', 'dp-skip', { 'data-id': String(step.id), 'data-contract': cid }, 'Skip',
                'Click again to skip', 'forward'),
              writeBtn('.is-small.ghost', 'dp-respawn', { 'data-id': String(step.id), 'data-contract': cid },
                'Respawn vehicle', 'Click again to respawn', 'truck'))));
        })))),
      answerBox(S.disposal.answers.list)), '.dp-steps',
      btn('.is-small.ghost', 'dp-refresh', {}, 'Refresh', 'rotate'));
  }

  function disposalWrite(op, data, slot, node) {
    return write(op, data, 'disposal:' + slot, node).then(function (reply) {
      if (!reply) return null;
      S.disposal.answers[slot] = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      loadDisposal();
      return reply;
    });
  }

  ACTIONS['dp-refresh'] = function () { loadDisposal(); };
  ACTIONS['dp-skip'] = function (node) {
    var cid = node.getAttribute('data-contract');
    if (!armed(node, 'Click again: finish the disposal on ' + cid + ' and hand over its payout')) return;
    disposalWrite('disposalSkip', { id: node.getAttribute('data-id') }, 'list', node);
  };
  ACTIONS['dp-respawn'] = function (node) {
    var cid = node.getAttribute('data-contract');
    if (!armed(node, 'Click again: make the vehicle for ' + cid + ' again at the spawn spot')) return;
    disposalWrite('disposalRespawn', { id: node.getAttribute('data-id') }, 'list', node);
  };

  STAFF_ACTIONS.push(
    { title: 'Change a reward or give a contract to another hitman', icon: 'sack-dollar', view: 'contracts',
      go: 'Contracts',
      text: 'Open the contract: Money, Change reward raises or lowers the collection paid next (added by staff or '
        + 'charged to the placer), with the figures before it arms. People, Reassign gives it to the hitman you '
        + 'looked up in Players, taking off whoever is on it.' },
    { title: 'Help with a body disposal', icon: 'truck', view: 'contracts', go: 'Contracts',
      text: 'Every body being disposed of is listed on Contracts (and on Home while there is one): Skip pays it as '
        + 'if dropped off, Respawn vehicle makes the vehicle again. The vehicle spawn and the drop-off are set in '
        + 'Locations.', also: { view: 'locations', go: 'Locations' } });

  /* ---------- Hitman organisation, Boss permissions, Locations ----------

     The organisation's staff ops (server/org/staff_ops.lua), each through
     the panel's one gate: reads for every reader of the panel, every change
     the staff ACE's, two clicks, audited (org_*). Staff may do everything
     here whatever Boss permissions say. One read (orgGet) serves the three
     sections; a write reads it again. A member is named by the handle
     orgGet gave (member), a player to hire by the lookup Players made
     (ref) or an exact citizen id. While the organisation is off, each
     section is one card saying so, with its switch. */

  function orgReset() {
    S.org = { data: null, error: null, answers: {}, funds: null, fundsError: null, audit: null, auditError: null,
      auditAction: '', member: null, role: null, nonce: null, dir: 'deposit', bonusTo: '', newGrade: null,
      layout: null, hire: null, history: null, historyError: null,
      bp: { pending: {}, cols: [], area: '', granted: false, col: '', add: '' },
      staged: {} };
  }
  orgReset();

  var ORG_TABS = ['members', 'roles', 'pay', 'funds', 'contracts', 'locations', 'notices', 'settings', 'log'];
  var AREA_NAMES = { members: 'Members', roles: 'Roles', pay: 'Pay', money: 'Money & cuts', contracts: 'Contracts',
    locations: 'Locations', notices: 'Notices', settings: 'Settings', delegation: 'Delegation' };
  var ORG_ACTIONS = ['org_created', 'org_member_hired', 'org_member_fired', 'org_member_role', 'org_member_suspended',
    'org_member_limits', 'org_member_grant', 'org_member_staff', 'org_role_created', 'org_role_edited',
    'org_role_deleted', 'org_role_power', 'org_role_pay', 'org_grant', 'org_limits', 'org_office_rule',
    'org_cut_set', 'org_cut', 'org_split_frozen', 'org_access', 'org_pick', 'org_funds_deposit',
    'org_funds_withdraw', 'org_funds_staff_deposit', 'org_bonus', 'org_location_set', 'org_location_removed',
    'org_notice', 'org_applied', 'org_application', 'org_renamed', 'org_layout', 'org_external_adopted',
    'org_external_reverted', 'org_funds_unrecorded', 'org_setup'];

  function loadOrg() {
    return ask('orgGet', {}, 'orgGet').then(function (reply) {
      if (!reply) return;
      if (reply.ok) { S.org.data = reply.data || {}; S.org.error = null; }
      else S.org.error = words(reply);
      drawOrg();
    });
  }

  function orgOn() { var d = S.org.data; return !!(d && d.enabled && d.loaded); }

  function drawOrg() {
    if (ORG_VIEWS[S.section] || BP_VIEWS[S.section]) {
      setHtml(byId('org-body'), orgViewBody());
    }
    if (logArea() === 'org' || logArea() === 'grants') setHtml(byId('lg-org'), orgLogBody());
  }
  AFTER_SETTINGS.push(function () {
    // The switch turned on or off from the card: what the server holds now.
    var e = settingEntry('Organisation.Enabled');
    if (e && S.org.data && (e.value === true) !== (S.org.data.enabled === true)) { loadOrg(); return; }
    drawOrg();
  });

  /** A write of the organisation's: its answer under the card it came from
      (by `slot`), a toast, and the organisation read again once it went. */
  function orgWrite(op, data, slot, node, after) {
    return write(op, data, 'org:' + slot, node).then(function (reply) {
      if (!reply) return null;
      S.org.answers[slot] = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) {
        if (after) after(reply);
        loadOrg();
      } else {
        drawOrg();
      }
      return reply;
    });
  }
  function orgRefuse(slot, text) {
    disarm();
    S.org.answers[slot] = { ok: false, text: text };
    drawOrg();
  }
  function orgAnswer(slot) { return answerBox(S.org.answers[slot]); }

  /** Arm a write, naming what it sets; typing in any of `binds` disarms it. */
  function armed(node, label, binds) {
    if (confirmed(node, label)) return true;
    if (S.armed && binds) S.armed.binds = binds;
    return false;
  }

  /** The organisation is off: said once, with its switch. */
  function offCard(what) {
    var d = S.org.data || {};
    var e = settingEntry('Organisation.Enabled');
    if (!e && !S.settings.data) loadSettings();
    return card('The hitman job is switched off', frag(
      h('p.about', 'The hitman job is off. Turn it on here: a real qbx_core job (' + String(d.job || 'hitman')
        + ') with roles, members, funds, Boss permissions and its own places. Off, no job is registered and nothing '
        + 'changes for anybody. ' + (what || '')),
      e ? h('div.st-row', { id: 'st-row-' + e.key, 'data-key': e.key }, settingInner(e))
        : loading('Reading the switch…')), '.is-warn.org-off');
  }

  function orgViewBody() {
    var d = S.org.data;
    if (!d) return S.org.error ? empty(S.org.error) : loading('Reading the organisation…');
    if (!d.enabled) return offCard(S.section === 'orgsetup' ? '' : 'Setup has its other settings.');
    if (!d.loaded) {
      return card('On, and not read yet', frag(
        h('p.about', 'The switch is on, but the organisation has not been read from the store yet. Create / sync '
          + 'registers the job in qbx_core and brings every online member in step.'),
        h('div.btn-row', writeBtn('.primary', 'org-setup', {}, 'Create / sync job',
          'Click again: register ' + String(d.job || 'the job') + ' in qbx_core', 'rotate')),
        orgAnswer('setup')), '.is-warn');
    }
    switch (S.section) {
      case 'orgroles': return orgRolesBody(d);
      case 'orgmembers': return orgMembersBody(d);
      case 'orgapps': return orgAppsBody(d);
      case 'orgfunds': return orgFundsBody(d);
      case 'orgaccess': return orgAccessBody(d);
      case 'orgnotices': return orgNoticesBody(d);
      case 'bpmatrix': return bpMatrixBody(d);
      case 'bplimits': return bpLimitsBody(d);
      case 'bpoffice': return bpOfficeBody(d);
      default: return orgSetupBody(d);
    }
  }

  function roleName(d, grade) {
    var r = asList(d.roles).filter(function (x) { return Number(x.grade) === Number(grade); })[0];
    return r ? String(r.label || r.name || ('grade ' + grade)) : 'grade ' + grade;
  }
  function memberOf(d, ref) {
    return asList(d.members).filter(function (m) { return String(m.ref) === String(ref); })[0];
  }
  function powerOf(d, code) {
    return asList(d.powers).filter(function (p) { return p.code === code; })[0];
  }
  function powerName(d, code) {
    if (code === 'TAKE') return 'Take contracts';
    var p = powerOf(d, code);
    return p ? String(p.label) : String(code);
  }
  function roleOptions(d) {
    return asList(d.roles).map(function (r) { return { value: String(r.grade), label: String(r.grade) + ' · ' + roleName(d, r.grade) }; });
  }

  /* -- Setup -- */

  function orgSetupBody(d) {
    var members = asList(d.members);
    var online = members.filter(function (m) { return m.online; }).length;
    var warnings = asList(d.warnings);
    var layout = S.org.layout || { labels: {}, hidden: {} };
    var saved = d.layout || {};
    var rows = allSettings().filter(function (e) {
      return categoryOf(e) === 'organisation' && String(e.group || '').indexOf('Boss limits') === -1;
    });
    rows.sort(function (a, b) { return (a.kind === 'switch' ? 0 : 1) - (b.kind === 'switch' ? 0 : 1); });
    return frag(
      card('The job', frag(
        h('dl.facts',
          h('dt', 'Job (qbx_core)'), h('dd.mono', String(d.job || '—')),
          h('dt', 'Label'), h('dd', String(d.label || '—')),
          h('dt', 'Type'), h('dd', String(d.type || '—')),
          h('dt', 'Only members may accept'), h('dd', d.requireJob ? 'Yes' : 'No'),
          h('dt', 'Members'), h('dd', num(members.length) + ' · ' + num(online) + ' in the city'),
          h('dt', 'Roles'), h('dd', num(asList(d.roles).length)),
          h('dt', 'Funds'), h('dd', money(d.balance) + ' · ' + (d.bank ? 'Renewed-Banking society account'
            : 'this resource\'s own ledger'))),
        warnings.length ? h('ul.warnings', warnings.map(function (w) { return h('li', String(w)); })) : null,
        h('div.btn-row', writeBtn('', 'org-setup', {}, 'Create / sync job',
          'Click again: register ' + String(d.job || 'the job') + ' in qbx_core', 'rotate')),
        orgAnswer('setup'))),
      card('Rename', frag(
        h('p.about', 'The label players see; never the job name members hold in qbx_core.'),
        h('div.toolbar', field('org.label', { class: 'is-grow', value: String(d.label || ''), maxlength: '64',
          'aria-label': 'Organisation label' }),
          writeBtn('', 'org-rename', {}, 'Rename', 'Click again to rename', 'pen')),
        orgAnswer('rename'))),
      card('Boss menu', frag(
        h('p.about', 'What each tab of the phone\'s Organisation tab is called, and the roles a tab is hidden from.'),
        h('div.table-wrap', h('table.grid',
          h('thead', h('tr', h('th', 'Tab'), h('th', 'Label'), h('th', 'Hidden from'))),
          h('tbody', ORG_TABS.map(function (tab) {
            var hidden = (layout.hidden && layout.hidden[tab]) || asList((saved.hidden || {})[tab]).map(String);
            return h('tr', h('td.mono', tab),
              h('td', field('org.tab.' + tab, { class: 'is-mid', maxlength: '24',
                value: String(((saved.labels || {})[tab]) || ''), placeholder: tab, 'aria-label': 'Label of ' + tab })),
              h('td', h('div.chips', asList(d.roles).map(function (r) {
                var on = hidden.indexOf(String(r.grade)) !== -1;
                return h('button.chip.is-link' + (on ? '.is-warn' : ''), { type: 'button', 'data-act': 'org-tab-hide',
                  'data-value': tab, 'data-id': String(r.grade), 'aria-pressed': on ? 'true' : 'false' },
                  roleName(d, r.grade));
              }))));
          })))),
        h('div.btn-row', writeBtn('', 'org-layout', {}, 'Save the boss menu', 'Click again: save the boss menu', 'check')),
        orgAnswer('layout'))),
      card('Settings', rows.length ? h('div.stack', rows.map(settingRow))
        : (S.settings.data ? empty('No organisation settings.') : loading('Reading the settings…'))));
  }

  /* -- Roles & pay -- */

  function orgRolesBody(d) {
    var roles = asList(d.roles);
    var sel = S.org.role != null ? roles.filter(function (r) { return Number(r.grade) === Number(S.org.role); })[0] : null;
    return frag(
      card('Roles', roles.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th.num', 'Grade'), h('th', 'Name'), h('th', 'Label'), h('th.num', 'Pay ($ per cycle)'),
          h('th', 'Boss'), h('th.num', 'Members'), h('th', ''))),
        h('tbody', roles.map(function (r) {
          return h('tr' + (sel && Number(sel.grade) === Number(r.grade) ? '.is-open' : ''),
            h('td.num', num(r.grade)), h('td.mono', String(r.name || '—')), h('td', String(r.label || '—'),
              r.locked ? h('span.chip.is-warn', 'locked') : null),
            h('td.num', money(r.pay)), h('td', r.boss ? h('span.chip.is-panel', 'boss') : '—'),
            h('td.num', num(r.members)),
            h('td', btn('.is-small.ghost', 'org-role-open', { 'data-id': String(r.grade) }, 'Edit & powers', 'pen')));
        })))) : empty('No roles yet. Add one below.'), '', h('span.sub', num(roles.length))),
      sel ? orgRoleCard(d, sel) : null,
      card('Add a role', frag(
        h('div.toolbar',
          field('org.new.grade', { class: 'is-short', inputmode: 'numeric', placeholder: 'Grade', 'aria-label': 'Grade' }),
          field('org.new.name', { class: 'is-mid', maxlength: '64', placeholder: 'name (job grade)', 'aria-label': 'Name' }),
          field('org.new.label', { class: 'is-mid', maxlength: '64', placeholder: 'Label', 'aria-label': 'Label' }),
          field('org.new.pay', { class: 'is-short', inputmode: 'numeric', placeholder: '$ pay', 'aria-label': 'Pay' }),
          segmented('org-new-boss', [{ value: 'no', label: 'Not boss' }, { value: 'yes', label: 'Boss' }],
            S.org.newBoss ? 'yes' : 'no'),
          writeBtn('.primary', 'org-role-add', {}, 'Add role', 'Click again to add', 'plus')),
        orgAnswer('role-add'))));
  }

  function orgRoleCard(d, r) {
    var g = String(r.grade);
    var ceiling = (d.ceiling && d.ceiling.role && d.ceiling.role[g]) || {};
    var powers = r.powers || {};
    var codes = [{ code: 'TAKE', area: 'contracts', label: 'Take contracts', about: 'May accept contracts, when only '
      + 'roles given it may (Config.Organisation.AcceptNeedsPower).' }].concat(asList(d.powers));
    return card('Role: ' + roleName(d, r.grade), frag(
      h('div.toolbar',
        h('label.st-pair', h('span', 'Name'), field('org.role.' + g + '.name', { class: 'is-mid', value: String(r.name || ''),
          maxlength: '64', 'aria-label': 'Name' })),
        h('label.st-pair', h('span', 'Label'), field('org.role.' + g + '.label', { class: 'is-mid',
          value: String(r.label || ''), maxlength: '64', 'aria-label': 'Label' })),
        h('label.st-pair', h('span', 'Pay $'), field('org.role.' + g + '.pay', { class: 'is-short', inputmode: 'numeric',
          value: String(r.pay == null ? '' : r.pay), 'aria-label': 'Pay' })),
        h('label.st-pair', h('span', 'Grade'), field('org.role.' + g + '.grade', { class: 'is-short', inputmode: 'numeric',
          value: g, 'aria-label': 'Grade (order)' }))),
      h('div.toolbar',
        segmented('org-role-boss', [{ value: 'no', label: 'Not boss' }, { value: 'yes', label: 'Boss' }],
          (S.org.staged['boss:' + g] != null ? S.org.staged['boss:' + g] : !!r.boss) ? 'yes' : 'no', { 'data-id': g }),
        segmented('org-role-lock', [{ value: 'no', label: 'Bosses may edit' }, { value: 'yes', label: 'Locked' }],
          (S.org.staged['lock:' + g] != null ? S.org.staged['lock:' + g] : !!r.locked) ? 'yes' : 'no', { 'data-id': g }),
        writeBtn('.primary', 'org-role-save', { 'data-id': g }, 'Save role', 'Click again to save', 'check'),
        writeBtn('.danger', 'org-role-remove', { 'data-id': g, disabled: Number(r.members) > 0 || null,
          title: Number(r.members) > 0 ? 'A role cannot be removed while it holds members' : null },
          'Remove role', 'Click again: remove ' + roleName(d, r.grade), 'trash-can')),
      Number(r.members) > 0 ? h('p.note', 'A role cannot be removed while it holds members.') : null,
      orgAnswer('role:' + g),
      h('h3.st-group-title', 'Powers of this role'),
      h('p.hint', 'What members holding this role may use. A boss reaches a power only once Boss permissions allows it '
        + 'for the role (or them); greyed rows are above that ceiling. Staff may set any.'),
      h('div.table-wrap', h('table.grid.org-powers',
        h('tbody', codes.map(function (p) {
          var on = !!powers[p.code];
          var above = p.code !== 'TAKE' && ceiling[p.code] !== 'allow';
          return h('tr' + (above ? '.is-dim' : ''),
            h('td', h('b', String(p.label)), h('span.sub', ' ' + String(AREA_NAMES[p.area] || p.area || ''))),
            h('td.detail', String(p.about || '')),
            h('td', above ? h('span.chip', 'above the ceiling') : h('span.chip.is-panel', 'within the ceiling')),
            h('td', writeBtn('.is-small' + (on ? '.primary' : ''), 'org-role-power', { 'data-id': g,
              'data-power': p.code, 'data-value': on ? 'off' : 'on' }, on ? 'Given' : 'Not given',
              on ? 'Click again: take ' + p.label + ' from ' + roleName(d, r.grade)
                : 'Click again: give ' + p.label + ' to ' + roleName(d, r.grade), on ? 'check' : 'plus')));
        })))),
      orgAnswer('power:' + g)), '.is-identity');
  }

  /* -- Members -- */

  function orgMembersBody(d) {
    var members = asList(d.members);
    var sel = S.org.member ? memberOf(d, S.org.member) : null;
    var player = hasPlayer() ? (S.players.data.player || {}) : null;
    var hireGrade = S.org.hire != null ? S.org.hire : (asList(d.roles).length ? String(asList(d.roles)[asList(d.roles).length - 1].grade) : '');
    return frag(
      card('Hire', frag(
        h('p.about', player ? 'Hire the player selected in Players, ' + String(player.name || 'them') + ', into a role.'
          : 'Look a player up in Players first (the header\'s Player chip), or give their exact citizen id.'),
        h('div.toolbar',
          player ? h('span.chip.is-live', icon('user'), ' ', String(player.name || 'No name on record'))
            : field('org.hire.cid', { class: 'is-mid', placeholder: 'Exact citizen id', maxlength: '64',
              'aria-label': 'Citizen id' }),
          h('span.sub', 'as'),
          h('div.seg', { role: 'group' }, asList(d.roles).map(function (r) {
            var on = String(r.grade) === String(hireGrade);
            return h('button.seg-btn' + (on ? '.is-on' : ''), { type: 'button', 'data-act': 'org-hire-grade',
              'data-value': String(r.grade), 'aria-pressed': on ? 'true' : 'false' }, roleName(d, r.grade));
          })),
          writeBtn('.primary', 'org-hire', {}, 'Hire', 'Click again to hire', 'user-plus')),
        orgAnswer('hire'))),
      card('Members', members.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Name'), h('th', 'Role'), h('th', 'In the city'), h('th', 'Joined'), h('th', 'Last seen'),
          h('th', 'Flags'), h('th', ''))),
        h('tbody', members.map(function (m) {
          var suspended = m.suspendedUntil && Number(m.suspendedUntil) > nowSeconds();
          return h('tr' + (sel && sel.ref === m.ref ? '.is-open' : ''),
            h('td.name', String(m.name || '—')), h('td', String(m.role || roleName(d, m.grade))),
            h('td', m.online ? h('span.chip.is-live', 'yes') : 'no'),
            h('td.nowrap', m.joined ? ago(m.joined) : '—'), h('td.nowrap', m.lastSeen ? ago(m.lastSeen) : '—'),
            h('td', m.boss ? h('span.chip.is-panel', 'boss') : null, m.locked ? h('span.chip.is-warn', 'locked') : null,
              suspended ? h('span.chip.is-warn', 'suspended') : null,
              Object.keys(m.grants || {}).length ? h('span.chip', num(Object.keys(m.grants).length) + ' granted') : null,
              Object.keys(m.denies || {}).length ? h('span.chip', num(Object.keys(m.denies).length) + ' denied') : null),
            h('td', btn('.is-small.ghost', 'org-member-open', { 'data-id': String(m.ref) }, 'Manage', 'pen')));
        })))) : empty('Nobody is a member yet. Hire somebody above.'), '', h('span.sub', num(members.length))),
      sel ? orgMemberCard(d, sel) : null);
  }

  function orgMemberCard(d, m) {
    var ref = String(m.ref);
    var name = String(m.name || 'them');
    var grants = m.grants || {}, denies = m.denies || {};
    var held = Object.keys(m.held || {});
    var roleSel = S.org.staged['role:' + ref] != null ? S.org.staged['role:' + ref] : String(m.grade);
    var power = S.org.staged['power:' + ref] || (asList(d.powers)[0] || {}).code || 'M1';
    var state = S.org.staged['state:' + ref] || 'grant';
    var limits = m.limits || {};
    return card('Member: ' + name, frag(
      h('dl.facts',
        h('dt', 'Role'), h('dd', roleName(d, m.grade)),
        h('dt', 'Holds now'), h('dd', held.length ? held.map(function (c) { return powerName(d, c); }).join(', ') : 'nothing'),
        h('dt', 'Own grants'), h('dd', Object.keys(grants).length ? Object.keys(grants).map(function (c) {
          return powerName(d, c) + (grants[c].inactive ? ' (inactive: ' + String(grants[c].inactive) + ')' : '')
            + ' by ' + String(grants[c].by);
        }).join(', ') : 'none'),
        h('dt', 'Own denies'), h('dd', Object.keys(denies).length ? Object.keys(denies).map(function (c) {
          return powerName(d, c) + ' by ' + String(denies[c]);
        }).join(', ') : 'none'),
        h('dt', 'Limits'), h('dd', (limits.maxAtOnce ? num(limits.maxAtOnce) + ' at once' : 'server\'s at once') + ' · '
          + (limits.cooldownMinutes != null ? num(limits.cooldownMinutes) + ' min between accepts' : 'server\'s cooldown')),
        m.suspendedUntil ? h('dt', 'Suspended until') : null, m.suspendedUntil ? h('dd', when(m.suspendedUntil)) : null),
      h('h3.st-group-title', 'Role'),
      h('div.toolbar',
        h('div.seg', { role: 'group' }, asList(d.roles).map(function (r) {
          var on = String(r.grade) === String(roleSel);
          return h('button.seg-btn' + (on ? '.is-on' : ''), { type: 'button', 'data-act': 'org-member-grade',
            'data-id': ref, 'data-value': String(r.grade) }, roleName(d, r.grade));
        })),
        writeBtn('', 'org-member-role', { 'data-id': ref }, 'Set role', 'Click again to set', 'id-badge')),
      orgAnswer('role-of:' + ref),
      h('h3.st-group-title', 'Suspend from contracts'),
      h('div.toolbar',
        field('org.m.' + ref + '.hours', { class: 'is-short', inputmode: 'numeric', placeholder: 'Hours (0 lifts)',
          'aria-label': 'Hours' }),
        field('org.m.' + ref + '.sreason', { class: 'is-grow', maxlength: '160', placeholder: 'Reason (kept in the log)',
          'aria-label': 'Reason' }),
        writeBtn('', 'org-member-suspend', { 'data-id': ref }, 'Suspend', 'Click again to suspend', 'ban')),
      orgAnswer('suspend:' + ref),
      h('h3.st-group-title', 'Own limits'),
      h('div.toolbar',
        h('label.st-pair', h('span', 'At once'), field('org.m.' + ref + '.at', { class: 'is-short', inputmode: 'numeric',
          value: limits.maxAtOnce == null ? '' : String(limits.maxAtOnce), placeholder: '1-50', 'aria-label': 'At once' })),
        h('label.st-pair', h('span', 'Cooldown (min)'), field('org.m.' + ref + '.cd', { class: 'is-short',
          inputmode: 'numeric', value: limits.cooldownMinutes == null ? '' : String(limits.cooldownMinutes),
          placeholder: '0-10080', 'aria-label': 'Cooldown minutes' })),
        writeBtn('', 'org-member-limits', { 'data-id': ref }, 'Save limits', 'Click again to save', 'check')),
      orgAnswer('limits:' + ref),
      h('h3.st-group-title', 'A power of their own'),
      h('div.toolbar',
        dropdown('org-mpower:' + ref),
        segmented('org-member-state', [{ value: 'grant', label: 'Grant' }, { value: 'deny', label: 'Deny' },
          { value: 'clear', label: 'Clear' }], state, { 'data-id': ref }),
        writeBtn('', 'org-member-grant', { 'data-id': ref, 'data-power': power }, 'Save', 'Click again to save', 'key')),
      orgAnswer('grant:' + ref),
      h('h3.st-group-title', 'Codename and lock'),
      h('div.toolbar',
        field('org.m.' + ref + '.codename', { class: 'is-mid', maxlength: '32', placeholder: 'Codename (empty clears)',
          'aria-label': 'Codename' }),
        writeBtn('', 'org-member-codename', { 'data-id': ref }, 'Save codename', 'Click again to save', 'mask'),
        writeBtn('', 'org-member-lock', { 'data-id': ref, 'data-value': m.locked ? 'off' : 'on' },
          m.locked ? 'Unlock' : 'Lock against boss edits',
          m.locked ? 'Click again: let bosses edit ' + name : 'Click again: lock ' + name, m.locked ? 'unlock' : 'lock')),
      orgAnswer('staff:' + ref),
      h('h3.st-group-title', 'Fire'),
      h('div.toolbar',
        field('org.m.' + ref + '.freason', { class: 'is-grow', maxlength: '200', placeholder: 'Reason (kept in the log)',
          'aria-label': 'Reason for firing' }),
        writeBtn('.danger', 'org-member-fire', { 'data-id': ref }, 'Fire', 'Click again: fire ' + name, 'user-minus')),
      orgAnswer('fire:' + ref)), '.is-identity');
  }

  DD['org-mpower'] = {
    prefix: 'Power',
    options: function () {
      var d = S.org.data || {};
      return [{ value: 'TAKE', label: 'Take contracts' }].concat(asList(d.powers).map(function (p) {
        return { value: p.code, label: String(p.label) };
      }));
    },
    value: function (ref) {
      var d = S.org.data || {};
      return S.org.staged['power:' + ref] || (asList(d.powers)[0] || {}).code || 'M1';
    },
    pick: function (v, ref) { disarm(); S.org.staged['power:' + ref] = v; drawOrg(); }
  };

  /* -- Applications -- */

  function orgAppsBody(d) {
    var apps = asList(d.applications);
    return card('Applications', apps.length ? h('div.stack', apps.map(function (a) {
      var id = String(a.id);
      return h('article.card.org-app',
        h('header.card-head', h('h3', String(a.name || 'Applicant')), h('span.sub', a.at ? ago(a.at) : '')),
        h('p.al-text', String(a.body || '')),
        h('div.btn-row',
          writeBtn('.primary', 'org-app', { 'data-id': id, 'data-value': 'yes' }, 'Accept',
            'Click again: hire ' + String(a.name || 'them') + ' into the lowest role', 'check'),
          writeBtn('.danger', 'org-app', { 'data-id': id, 'data-value': 'no' }, 'Reject',
            'Click again: reject ' + String(a.name || 'them'), 'xmark')),
        orgAnswer('app:' + id));
    })) : empty('No open applications. Players apply from the app (at a sign-up spot, when that is the rule).'),
    '', h('span.sub', num(apps.length)));
  }

  /* -- Funds & cuts -- */

  function loadOrgFunds() {
    return ask('orgFunds', { limit: 50 }, 'orgFunds').then(function (reply) {
      if (!reply) return;
      if (reply.ok) { S.org.funds = reply.data || {}; S.org.fundsError = null; }
      else S.org.fundsError = words(reply);
      drawOrg();
    });
  }

  function orgNonce() {
    if (!S.org.nonce) S.org.nonce = 'n' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
    return S.org.nonce;
  }

  function orgFundsBody(d) {
    var f = S.org.funds;
    var cuts = d.cuts || {};
    var lim = d.limits || {};
    var cap = Number(lim.TotalCutCapPercent) || 0;
    var dir = S.org.dir;
    var byMember = Object.keys(cuts.byMember || {}).length;
    function cutRow(kind, label, value, bossMax) {
      return h('tr', h('td', label), h('td.num', value == null || value === false ? '—' : num(value) + '%'),
        h('td.num', '0–' + num(cap) + '%'), h('td.num', bossMax == null ? '—' : '0–' + num(bossMax) + '%'),
        h('td', h('div.inline-form', field('org.cut.' + kind, { class: 'is-short', inputmode: 'numeric', placeholder: '%',
          'aria-label': label + ' (percent)' }),
          writeBtn('.is-small', 'org-cut', { 'data-value': kind }, 'Save', 'Click again to save', 'check'))));
    }
    return frag(
      h('div.tiles',
        tile('Balance', frag(h('p.big', fundsReady(d, f) ? money(f ? f.balance : d.balance) : 'Unknown'),
          h('p.sub', fundsReady(d, f) ? (fundsBackend(d, f) === 'bank' ? 'Renewed-Banking society account'
            : 'this resource\'s own ledger') : 'the bank is not answering: the balance cannot be read')),
          fundsReady(d, f) ? '' : '.is-warn')),
      fundsBackendCard(d, f),
      card('Move money', frag(
        h('p.about', 'Staff money into the funds or out of them, or a bonus from the funds to a member, with a reason. '
          + 'Sent once however often it is clicked: a retry after no answer is the same movement.'),
        h('div.toolbar',
          segmented('org-dir', [{ value: 'deposit', label: 'Deposit' }, { value: 'withdraw', label: 'Withdraw' },
            { value: 'bonus', label: 'Bonus to a member' }], dir),
          dir === 'bonus' ? dropdown('org-bonus-to') : null),
        h('div.toolbar',
          field('org.funds.amount', { class: 'is-short', inputmode: 'numeric', placeholder: '$ amount', 'aria-label': 'Amount' }),
          field('org.funds.reason', { class: 'is-grow', maxlength: '200', placeholder: 'Reason (kept in the log)',
            'aria-label': 'Reason' }),
          writeBtn('.primary', 'org-funds', {}, dir === 'deposit' ? 'Deposit' : dir === 'withdraw' ? 'Withdraw' : 'Pay bonus',
            'Click again', dir === 'withdraw' ? 'arrow-up-from-bracket' : 'arrow-down-to-bracket')),
        orgAnswer('funds'))),
      card('Cuts', frag(
        h('p.about', 'The share of what a member is paid that goes to the funds, frozen onto a contract when the member '
          + 'accepts it: a change never touches money already promised. Staff may set any cut up to the cap on all cuts '
          + 'of one payout (' + num(cap) + '%); a boss only within the limits in Boss permissions. 0 is always allowed.'),
        h('div.table-wrap', h('table.grid',
          h('thead', h('tr', h('th', 'Cut'), h('th.num', 'Now'), h('th.num', 'Staff may set'), h('th.num', 'A boss may set'),
            h('th', ''))),
          h('tbody',
            cutRow('payout', 'Organisation cut of payouts', cuts.payout, Math.min(cap, Number(lim.CutMaxPercent) || 0)),
            cutRow('stake', 'Cut on stakes', cuts.stake, Math.min(cap, Number(lim.StakeCutMaxPercent) || 0)),
            cutRow('buyout', 'Cut on buyouts', cuts.buyout, Math.min(cap, Number(lim.BuyoutCutMaxPercent) || 0)),
            asList(d.roles).map(function (r) {
              var v = (cuts.byRole || {})[String(r.grade)];
              return h('tr', h('td', 'Role: ' + roleName(d, r.grade)), h('td.num', v == null ? 'as the organisation' : num(v) + '%'),
                h('td.num', '0–' + num(cap) + '%'), h('td.num', '0–' + num(Math.min(cap, Number(lim.CutMaxPercent) || 0)) + '%'),
                h('td', h('div.inline-form', field('org.cut.role.' + r.grade, { class: 'is-short', inputmode: 'numeric',
                  placeholder: '%', 'aria-label': 'Cut for ' + roleName(d, r.grade) }),
                  writeBtn('.is-small', 'org-cut', { 'data-value': 'role', 'data-id': String(r.grade) }, 'Save',
                    'Click again to save', 'check'),
                  v == null ? null : writeBtn('.is-small.ghost', 'org-cut-clear', { 'data-id': String(r.grade) },
                    'Clear', 'Click again: ' + roleName(d, r.grade) + ' as the organisation', 'eraser'))));
            })))),
        byMember ? h('p.note', num(byMember) + ' member' + (byMember === 1 ? ' has a cut' : 's have cuts')
          + ' of their own.') : null,
        orgAnswer('cut'))),
      card('Ledger', f ? (asList(f.rows).length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'When'), h('th', 'Kind'), h('th.num', 'Amount'), h('th', 'Reason'), h('th', 'Contract'),
          canIdentify() ? h('th', 'By') : null)),
        h('tbody', asList(f.rows).map(function (r) {
          return h('tr', h('td.nowrap', when(r.at)), h('td', String(r.kind || '—')), h('td.num', money(r.amount)),
            h('td', String(r.reason || '—')),
            h('td', r.contract ? h('button.link.mono', { type: 'button', 'data-act': 'contract', 'data-id': String(r.contract) },
              String(r.contract)) : '—'),
            canIdentify() ? h('td.mono', String(r.actor || '—')) : null);
        })))) : empty('Nothing has moved yet.'))
        : (S.org.fundsError ? empty(S.org.fundsError) : loading('Reading the ledger…')), '',
        btn('.is-small.ghost', 'org-funds-refresh', {}, 'Refresh', 'rotate')));
  }

  /** Where the funds are kept, as orgFunds (or orgGet) says: 'internal' or 'bank'. */
  function fundsBackend(d, f) {
    var b = (f && f.backend) || d.fundsBackend;
    if (b) return String(b);
    return (f ? f.bank : d.bank) ? 'bank' : 'internal';
  }
  /** Whether the funds can be read now (false while the bank is down). */
  function fundsReady(d, f) {
    var r = f && f.ready !== undefined ? f.ready : d.fundsReady;
    return r !== false;
  }

  /** Switch the funds between this resource's ledger and Renewed-Banking. */
  function fundsBackendCard(d, f) {
    var now = fundsBackend(d, f);
    var ready = fundsReady(d, f);
    var other = now === 'bank' ? 'internal' : 'bank';
    var otherName = other === 'bank' ? 'Renewed-Banking' : 'this resource\'s own ledger';
    return card('Where the funds are kept', frag(
      h('p.about', 'Now: ' + (now === 'bank' ? 'Renewed-Banking\'s society account' : 'this resource\'s own ledger')
        + (ready ? '.' : ', which is not answering.') + ' Switching moves the balance to the other, on the record.'),
      // A switch carries the balance across, so it needs Renewed-Banking
      // answering on both sides (Funds.switch): while the bank is down the
      // only way off it is Abandon, and the server refuses a plain switch.
      h('div.btn-row', writeBtn('', 'org-backend', { 'data-value': other,
        title: ready ? null : 'The bank is not answering: a switch would carry nothing across. Abandon it below.' },
        'Switch to ' + otherName, 'Click again: move the funds to ' + otherName, 'right-left', false,
        ready ? undefined : false)),
      !ready && now === 'bank' ? h('div.org-abandon',
        h('p.note.is-error', 'The bank is down. Abandon leaves it carrying nothing: the funds start again from $0 in '
          + otherName + ', and whatever the bank holds is not moved or counted. Only do this if the bank will not '
          + 'come back.'),
        h('div.btn-row', writeBtn('.danger', 'org-backend', { 'data-value': other, 'data-how': 'abandon' },
          'Abandon the bank', 'Click again: abandon the bank, start from $0 in ' + otherName, 'triangle-exclamation')))
        : null,
      orgAnswer('backend')), ready ? '' : '.is-warn');
  }

  /* -- Contract access -- */

  function orgAccessBody(d) {
    var access = d.access || {};
    return frag(
      card('Which contracts each role may take', frag(
        h('p.about', 'Only ever stricter than the server\'s own rules, which still apply first. Empty is no rule of the '
          + 'organisation\'s own.'),
        h('div.org-access', asList(d.roles).map(function (r) {
          var g = String(r.grade);
          var a = access[g] || {};
          var rule = S.org.staged['rule:' + g] != null ? S.org.staged['rule:' + g] : (a.rule || '');
          var wl = S.org.staged['wl:' + g] != null ? S.org.staged['wl:' + g] : (a.whitelisted === false ? 'no' : 'yes');
          return h('div.org-access-role',
            h('b', roleName(d, g)),
            h('div.toolbar',
              h('label.st-pair', h('span', 'Most reward ($)'), field('org.acc.' + g + '.max', { class: 'is-short',
                inputmode: 'numeric', value: a.maxReward == null ? '' : String(a.maxReward), 'aria-label': 'Most reward' })),
              h('label.st-pair', h('span', 'At once'), field('org.acc.' + g + '.at', { class: 'is-short',
                inputmode: 'numeric', value: a.maxAtOnce == null ? '' : String(a.maxAtOnce), 'aria-label': 'At once' })),
              h('label.st-pair', h('span', 'Cooldown (min)'), field('org.acc.' + g + '.cd', { class: 'is-short',
                inputmode: 'numeric', value: a.cooldownMinutes == null ? '' : String(a.cooldownMinutes),
                'aria-label': 'Cooldown' }))),
            h('div.toolbar',
              segmented('org-acc-rule', [{ value: '', label: 'Any rule' }, { value: 'alive', label: 'Alive only' },
                { value: 'either', label: 'Kill or alive' }], rule, { 'data-id': g }),
              segmented('org-acc-wl', [{ value: 'yes', label: 'Whitelisted-job targets allowed' },
                { value: 'no', label: 'Not on whitelisted jobs' }], wl, { 'data-id': g }),
              writeBtn('.is-small', 'org-access', { 'data-id': g }, 'Save', 'Click again: save for ' + roleName(d, g),
                'check')));
        })),
        orgAnswer('access'))),
      card('Boss pick', frag(
        h('p.about', 'Pin a contract to a member on their board, as a boss would; Nobody clears the pick.'),
        h('div.toolbar',
          field('org.pick.id', { class: 'is-mid', maxlength: '64', placeholder: 'Contract id', 'aria-label': 'Contract id' }),
          dropdown('org-pick-to'),
          writeBtn('', 'org-pick', {}, 'Pick', 'Click again', 'thumbtack')),
        orgAnswer('pick'))));
  }

  /** A member to pick from a list, drawn as a dropdown (a roster can be long). */
  function memberOptions(first) {
    return [{ value: '', label: first }].concat(asList((S.org.data || {}).members).map(function (m) {
      return { value: String(m.ref), label: String(m.name || '—') };
    }));
  }
  DD['org-pick-to'] = {
    prefix: 'Member',
    options: function () { return memberOptions('Nobody (clear the pick)'); },
    value: function () { return S.org.staged.pick || ''; },
    pick: function (v) { disarm(); S.org.staged.pick = v; drawOrg(); }
  };
  DD['org-bonus-to'] = {
    prefix: 'To',
    options: function () { return memberOptions('Pick a member'); },
    value: function () { return S.org.bonusTo || ''; },
    pick: function (v) { disarm(); S.org.bonusTo = v; drawOrg(); }
  };

  /* -- Notices -- */

  function orgNoticesBody(d) {
    var n = d.notice;
    var text = n && typeof n === 'object' ? n.text : null;
    return card('The board notice', frag(
      text ? h('blockquote.org-notice', String(text)) : empty('No notice posted.'),
      n && n.at ? h('p.sub', 'Posted ' + ago(n.at)) : null,
      h('div.toolbar',
        field('org.notice', { class: 'is-grow', maxlength: String((d.limits || {}).NoticeMaxLength || 2000),
          placeholder: 'New notice', 'aria-label': 'Notice' })),
      h('div.toolbar',
        segmented('org-broadcast', [{ value: 'no', label: 'On the board' }, { value: 'yes', label: 'And message every member' }],
          S.org.staged.broadcast ? 'yes' : 'no'),
        writeBtn('.primary', 'org-notice', {}, 'Post', 'Click again to post', 'thumbtack'),
        text ? writeBtn('.ghost', 'org-notice-clear', {}, 'Take it down', 'Click again: take the notice down', 'eraser')
          : null),
      orgAnswer('notice')));
  }

  /* -- Org audit -- */

  function loadOrgAudit(action) {
    var data = { area: 'org', limit: 100 };
    if (action) data.action = action;
    return ask('logs', data, 'orgAudit').then(function (reply) {
      if (!reply) return;
      var rows = reply.ok ? asList((reply.data || {}).rows) : null;
      if (action === 'org_grant') {
        S.org.history = rows;
        S.org.historyError = reply.ok ? null : words(reply);
      } else {
        S.org.audit = rows;
        S.org.auditError = reply.ok ? null : words(reply);
      }
      drawOrg();
    });
  }

  DD['org-audit'] = {
    prefix: 'Action',
    options: function () {
      return [{ value: '', label: 'Every action' }].concat(ORG_ACTIONS.map(function (a) {
        return { value: a, label: a.replace(/^org_/, '').replace(/_/g, ' ') };
      }));
    },
    value: function () { return S.org.auditAction; },
    pick: function (v) { S.org.auditAction = v; S.org.audit = null; drawOrg(); loadOrgAudit(v); }
  };

  function auditTable(rows) {
    return h('div.table-wrap', h('table.grid.is-log',
      h('thead', h('tr', h('th', 'When'), h('th', 'Action'), h('th', 'By'), h('th', 'Detail'))),
      h('tbody', rows.map(function (r) {
        return h('tr', h('td.nowrap', when(r.ts)), h('td.mono', String(r.action || '').replace(/^org_/, '')),
          h('td', String(r.by || '—')), h('td.detail', detailText(r.detail)));
      }))));
  }

  function orgAuditBody() {
    var rows = S.org.audit;
    return frag(
      h('div.toolbar', dropdown('org-audit'), btn('.ghost', 'org-audit-refresh', {}, 'Refresh', 'rotate')),
      card('Every boss and staff action on the organisation', rows ? (rows.length ? auditTable(rows)
        : empty('Nothing on the record yet.')) : (S.org.auditError ? empty(S.org.auditError) : loading('Reading the log…'))));
  }

  /* -- Boss permissions: the matrix -- */

  function bpColumns(d) {
    var cols = [];
    asList(d.roles).forEach(function (r) {
      if (r.boss) cols.push({ key: 'role:' + r.grade, subject: 'role', id: Number(r.grade), label: roleName(d, r.grade) });
    });
    var cm = (d.ceiling && d.ceiling.member) || {};
    var seen = {};
    Object.keys(cm).concat(S.org.bp.cols).forEach(function (ref) {
      if (seen[ref]) return;
      seen[ref] = true;
      var m = memberOf(d, ref);
      if (m) cols.push({ key: 'member:' + ref, subject: 'member', id: ref, label: String(m.name || 'member') });
    });
    return cols;
  }
  function bpSaved(d, col, code) {
    if (col.subject === 'role') return ((d.ceiling.role || {})[String(col.id)] || {})[code] === 'allow' ? 'allow' : 'off';
    return ((d.ceiling.member || {})[col.id] || {})[code] || 'inherit';
  }
  function bpState(d, col, code) {
    var p = S.org.bp.pending[col.key + '|' + code];
    return p || bpSaved(d, col, code);
  }
  var BP_WORD = { allow: 'Allow', off: 'Off', deny: 'Deny', inherit: 'Inherit role' };
  function bpPendingList(d) {
    var cols = bpColumns(d);
    var out = [];
    Object.keys(S.org.bp.pending).forEach(function (k) {
      var at = k.lastIndexOf('|');
      var colKey = k.slice(0, at), code = k.slice(at + 1);
      var col = cols.filter(function (c) { return c.key === colKey; })[0];
      if (!col) return;
      var state = S.org.bp.pending[k];
      out.push({ col: col, code: code, state: state,
        text: (state === 'allow' ? '+ ' : state === 'inherit' ? '↺ ' : '− ') + powerName(d, code) + ' for '
          + col.label + (state === 'deny' ? ' (deny)' : state === 'inherit' ? ' (inherit role)' : '') });
    });
    return out;
  }
  /** A power allowed whose staff bounds are all still config.lua's. */
  function atDefault(d, p) {
    var keys = asList(p.limits);
    if (!keys.length || !S.settings.data) return false;
    return keys.every(function (k) {
      var e = settingEntry('Organisation.Limits.' + k);
      return e && Number(e.value) === Number((d.limits || {})[k]);
    });
  }

  DD['bp-area'] = {
    prefix: 'Area',
    options: function () {
      return [{ value: '', label: 'Every area' }].concat(Object.keys(AREA_NAMES).map(function (a) {
        return { value: a, label: AREA_NAMES[a] };
      }));
    },
    value: function () { return S.org.bp.area; },
    pick: function (v) { S.org.bp.area = v; drawOrg(); }
  };
  DD['bp-add'] = {
    prefix: 'Add an individual boss',
    options: function () {
      var d = S.org.data || {};
      var shown = {};
      bpColumns(d).forEach(function (c) { shown[c.key] = true; });
      return [{ value: '', label: 'Pick a member' }].concat(asList(d.members).filter(function (m) {
        return !shown['member:' + m.ref];
      }).map(function (m) { return { value: String(m.ref), label: String(m.name || '—') + ' · ' + String(m.role || '') }; }));
    },
    value: function () { return ''; },
    pick: function (v) { if (v) { S.org.bp.cols.push(v); drawOrg(); } }
  };
  DD['bp-col'] = {
    prefix: 'Show',
    options: function () {
      return [{ value: '', label: 'Every column' }].concat(bpColumns(S.org.data || {}).map(function (c) {
        return { value: c.key, label: c.label };
      }));
    },
    value: function () { return S.org.bp.col; },
    pick: function (v) { S.org.bp.col = v; drawOrg(); }
  };
  DD['bp-copy'] = {
    prefix: 'Copy from',
    options: function (colKey) {
      return [{ value: '', label: '…' }].concat(bpColumns(S.org.data || {}).filter(function (c) {
        return c.key !== colKey;
      }).map(function (c) { return { value: c.key, label: c.label }; }));
    },
    value: function () { return ''; },
    pick: function (v, colKey) {
      var d = S.org.data || {};
      var cols = bpColumns(d);
      var from = cols.filter(function (c) { return c.key === v; })[0];
      var to = cols.filter(function (c) { return c.key === colKey; })[0];
      if (!from || !to) return;
      asList(d.powers).forEach(function (p) {
        var src = bpState(d, from, p.code);
        var want = to.subject === 'role' ? (src === 'allow' ? 'allow' : 'off')
          : (from.subject === 'role' ? (src === 'allow' ? 'allow' : 'inherit') : src);
        bpStage(d, to, p.code, want);
      });
      disarm();
      drawOrg();
    }
  };

  function bpStage(d, col, code, state) {
    var k = col.key + '|' + code;
    if (state === bpSaved(d, col, code)) delete S.org.bp.pending[k];
    else S.org.bp.pending[k] = state;
  }

  function bpMatrixBody(d) {
    var allCols = bpColumns(d);
    var cols = S.org.bp.col ? allCols.filter(function (c) { return c.key === S.org.bp.col; }) : allCols;
    var q = trim(S.forms['bp.q']).toLowerCase();
    var office = d.officeStaff || {};
    var powers = asList(d.powers).filter(function (p) {
      if (S.org.bp.area && p.area !== S.org.bp.area) return false;
      if (q && (String(p.label) + ' ' + String(p.about) + ' ' + p.code).toLowerCase().indexOf(q) === -1) return false;
      if (S.org.bp.granted) {
        return cols.some(function (c) { var st = bpState(d, c, p.code); return st === 'allow' || st === 'deny'; });
      }
      return true;
    });
    var pending = bpPendingList(d);
    var areas = [];
    powers.forEach(function (p) { if (areas.indexOf(p.area) === -1) areas.push(p.area); });
    return frag(
      h('p.hint', 'The ceiling: every power is off for every boss until it is allowed here, for a boss role or for one '
        + 'boss. A boss\'s own column overrides their role: Allow, Deny, or Inherit role. Click cells to change them; '
        + 'nothing is saved until Save. Staff may always do everything themselves.'),
      h('div.toolbar',
        dropdown('bp-area'),
        h('label.search', icon('magnifying-glass'), field('bp.q', { placeholder: 'Find a power', 'data-live': 'bp-filter',
          'aria-label': 'Find a power' })),
        segmented('bp-granted', [{ value: 'all', label: 'Every power' }, { value: 'granted', label: 'Only granted' }],
          S.org.bp.granted ? 'granted' : 'all'),
        dropdown('bp-col'),
        dropdown('bp-add')),
      allCols.length ? null : h('p.note.is-warn', 'No role is marked boss, and no boss column is added: mark a role boss '
        + 'in Roles & pay, or add an individual boss.'),
      h('div.table-wrap.bp-wrap', h('table.grid.bp-grid',
        h('thead',
          h('tr', h('th', 'Power'), cols.map(function (c) {
            return h('th.bp-col', h('span.bp-col-name', c.label), h('span.sub', c.subject === 'role' ? 'role' : 'one boss'));
          })),
          h('tr.bp-tools', h('th', ''), cols.map(function (c) {
            return h('th', h('div.bp-col-tools', dropdown('bp-copy:' + c.key, '.is-small'),
              writeBtn('.is-small.danger', 'bp-revoke', { 'data-id': c.key }, 'Revoke all',
                'Click again: revoke every power from ' + c.label, 'ban')));
          }))),
        h('tbody', areas.map(function (area) {
          return frag(h('tr.tl-group', h('td', { colspan: String(cols.length + 1) }, AREA_NAMES[area] || area)),
            powers.filter(function (p) { return p.area === area; }).map(function (p) {
              return h('tr',
                h('td.bp-power', h('b', String(p.label)), office[p.code] ? h('span.chip.is-warn', { title: 'Needs the boss office' },
                  icon('lock'), ' office') : null,
                  asList(p.limits).length ? h('button.link.bp-limits-link', { type: 'button', 'data-act': 'section',
                    'data-section': 'bplimits' }, 'Limits ▸') : null,
                  h('span.detail', ' ' + String(p.about || ''))),
                cols.map(function (c) {
                  var st = bpState(d, c, p.code);
                  var dirty = !!S.org.bp.pending[c.key + '|' + p.code];
                  var warn = st === 'allow' && atDefault(d, p);
                  return h('td.bp-cell',
                    h('button.bp-btn.is-' + st + (dirty ? '.is-pending' : ''), { type: 'button', 'data-act': 'bp-cell',
                      'data-id': c.key, 'data-power': p.code, disabled: !writesOpen() || null,
                      title: (dirty ? 'Changed, not saved: ' : '') + BP_WORD[st] + (warn ? ' · its limit is still the '
                        + 'default: set bounds in Limits' : ''), 'aria-label': p.label + ' for ' + c.label + ': ' + BP_WORD[st] },
                      h('span.lbl', BP_WORD[st]), warn ? h('span.bp-warn', { 'aria-hidden': 'true' }, '⚠') : null));
                }));
            }));
        })))),
      card('Changes to save (' + num(pending.length) + ')', pending.length ? frag(
        h('ul.plain.bp-diff', pending.map(function (x) { return h('li', x.text); })),
        h('div.btn-row',
          writeBtn('.primary', 'bp-save', {}, 'Save ' + num(pending.length) + ' change' + (pending.length === 1 ? '' : 's'),
            'Click again: save ' + num(pending.length) + ' change' + (pending.length === 1 ? '' : 's'), 'check'),
          btn('.ghost', 'bp-discard', {}, 'Discard', 'xmark'))) : empty('Nothing changed yet: click a cell.'),
        pending.length ? '.is-warn' : ''),
      orgAnswer('bp'));
  }

  /* -- Boss permissions: limits, office and delegation, history -- */

  function bpLimitsBody(d) {
    var lim = d.limits || {};
    var keys = Object.keys(lim).sort();
    var usedBy = {};
    asList(d.powers).forEach(function (p) {
      asList(p.limits).forEach(function (k) { (usedBy[k] = usedBy[k] || []).push(String(p.label)); });
    });
    return frag(
      h('p.hint', 'The bounds every boss power works within, for this organisation. config.lua\'s are the defaults '
        + '(Config.Organisation.Limits); Reset puts one back to it.'),
      card('Limits', h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Limit'), h('th.num', 'Now'), h('th.num', 'config.lua'), h('th', 'Used by'), h('th', ''))),
        h('tbody', keys.map(function (k) {
          var e = settingEntry('Organisation.Limits.' + k);
          var label = e ? String(e.label) : k;
          var unit = /Percent$/.test(k) ? '%' : /Minutes$/.test(k) ? ' min' : /Hours$/.test(k) ? ' h'
            : /(Radius|Metres)$/.test(k) ? ' m' : /(Max|PerDay)$/.test(k) && /(Pay|Bonus|Withdraw)/.test(k) ? '$' : '';
          function show(v) { return v == null ? '—' : unit === '$' ? money(v) : num(v) + unit; }
          return h('tr', h('td', h('b', label), h('code.st-key', ' ' + k)), h('td.num', show(lim[k])),
            h('td.num', e ? show(e.value) : '—'), h('td.detail', asList(usedBy[k]).join(', ') || '—'),
            h('td', h('div.inline-form', field('bp.lim.' + k, { class: 'is-short', inputmode: 'decimal',
              placeholder: String(lim[k]), 'aria-label': label }),
              writeBtn('.is-small', 'bp-limit', { 'data-id': k }, 'Save', 'Click again to save', 'check'),
              e && Number(e.value) !== Number(lim[k]) ? writeBtn('.is-small.ghost', 'bp-limit-reset', { 'data-id': k },
                'Reset', 'Click again: back to ' + show(e.value), 'arrow-rotate-left') : null)));
        })))), '', h('span.sub', num(keys.length))),
      orgAnswer('limits'));
  }

  function bpOfficeBody(d) {
    var office = d.officeStaff || {};
    var bossOwn = d.officeBoss || {};
    return frag(
      card('Needs the boss office', frag(
        h('p.about', 'Powers a boss may use only while standing in the boss office (Locations). Staff\'s list is forced: a '
          + 'boss may add more for themselves (Office requirement), never lift one of these.'),
        h('div.table-wrap', h('table.grid',
          h('thead', h('tr', h('th', 'Power'), h('th', 'Staff require it'), h('th', 'A boss added it'), h('th', ''))),
          h('tbody', asList(d.powers).map(function (p) {
            var on = !!office[p.code];
            return h('tr', h('td', h('b', String(p.label)), h('span.sub', ' ' + (AREA_NAMES[p.area] || p.area))),
              h('td', on ? h('span.chip.is-warn', icon('lock'), ' office') : 'no'),
              h('td', bossOwn[p.code] ? 'yes' : '—'),
              h('td', writeBtn('.is-small', 'bp-office', { 'data-power': p.code, 'data-value': on ? 'off' : 'on' },
                on ? 'Stop requiring it' : 'Require the office',
                on ? 'Click again: ' + p.label + ' anywhere' : 'Click again: ' + p.label + ' only in the office', 'building')));
          })))),
        orgAnswer('office'))),
      card('Delegation rules', h('ul.plain.bp-rules',
        h('li', 'A boss passes on only powers they hold themselves, after this ceiling and their denies, and never with '
          + 'wider limits than their own.'),
        h('li', 'Rank: a boss never creates, edits or assigns a role at or above their own, or acts on a member at or above '
          + 'it, unless given Promote to own rank, which allows equal and never above.'),
        h('li', 'No self-escalation: a boss never changes their own role, powers or limits, or another boss of equal or '
          + 'higher rank.'),
        h('li', 'Revoking a power here makes every grant that boss made of it inactive, not deleted: allowing it again '
          + 'restores them.'),
        h('li', 'Staff may edit any role, member or grant, and lock a role or member against boss edits.'),
        h('li', 'The organisation is never left without a member in its top boss role, except by staff.'),
        h('li', 'Every rule is checked on the server for every request; the phone only greys out what it may not do.'))));
  }

  function bpHistoryBody() {
    var rows = S.org.history;
    var d = S.org.data || {};
    return frag(
      h('div.toolbar', btn('.ghost', 'bp-history-refresh', {}, 'Refresh', 'rotate')),
      card('Grant history', rows ? (rows.length ? h('div.table-wrap', h('table.grid.is-log',
        h('thead', h('tr', h('th', 'When'), h('th', 'By'), h('th', 'Column'), h('th', 'Power'), h('th', 'Before'),
          h('th', 'After'), h('th', ''))),
        h('tbody', rows.map(function (r, i) {
          var det = r.detail || {};
          var isRole = det.subject === 'role';
          var undoTo = isRole ? (det.before === 'allow' ? 'allow' : 'off') : null;
          return h('tr', h('td.nowrap', when(r.ts)), h('td', String(r.by || '—')),
            h('td', isRole ? 'Role: ' + roleName(d, det.id) : 'One boss'),
            h('td', powerName(d, det.power)), h('td', String(det.before || 'off')), h('td', String(det.after || 'off')),
            h('td', isRole && det.before !== det.after ? writeBtn('.is-small.ghost', 'bp-undo', { 'data-index': String(i),
              'data-id': String(det.id), 'data-power': String(det.power), 'data-value': undoTo }, 'Undo',
              'Click again: ' + powerName(d, det.power) + ' back to ' + undoTo, 'arrow-rotate-left')
              : (isRole ? null : h('span.sub', 'change it in the Matrix'))));
        })))) : empty('Nothing granted or revoked yet.'))
        : (S.org.historyError ? empty(S.org.historyError) : loading('Reading the history…'))),
      orgAnswer('bp'));
  }

  /* -- Locations -- */

  /** A spot's or a list's coordinates, as each list writes them. */
  function fmt(n, places) { var p = Math.pow(10, places == null ? 1 : places); return String(Math.round(Number(n) * p) / p); }

  /* Every place this resource uses, from the one registry of map spots
     (server/places.lua): placeList gives every kind (the organisation's,
     the broker's and informant's, body disposal's) with its rows, what may
     be set beside the point, its defaults and whether it can be set now;
     placeMyPosition reads where the staff member stands; placeSet,
     placeRemove and placeReset write, each two clicks. The places that are
     settings (marked `place` by the server) follow, with Use my position
     filling a line. */
  S.places = { data: null, error: null, errCode: null, answers: {}, edit: {}, staged: {}, pos: null, posAt: 0 };

  var PLACE_GROUPS = {
    org: { title: 'Organisation places' },
    npc: { title: 'Broker and informant places',
      hint: 'Where the broker (Rumours) and the informant NPC stand. With none set, each uses its Locations list in '
        + 'the settings below, which stays the default.' },
    disposal: { title: 'Body disposal',
      hint: 'Where the disposal vehicle is made, and where the body is dropped off (Config.Disposal). Config.lua\'s '
        + 'VehicleSpawn and DropOff apply while one is not set.' }
  };

  function loadPlaces() {
    return ask('placeList', {}, 'places').then(function (reply) {
      if (!reply) return;
      if (reply.ok) { S.places.data = reply.data || {}; S.places.error = null; S.places.errCode = null; }
      else { S.places.error = words(reply); S.places.errCode = reply.err || null; }
      S.places.switches = S.settings.data ? placeSwitches() : null;
      drawPlaces();
    });
  }
  function drawPlaces() {
    if (S.section === 'locations') setHtml(byId('places-body'), locationsBody());
  }
  function placeKinds() { return asList((S.places.data || {}).kinds); }
  function placeKind(id) { return placeKinds().filter(function (k) { return k.id === id; })[0] || null; }
  function placeAnswer(slot) { return answerBox(S.places.answers[slot]); }
  function placeRefuse(slot, text) {
    disarm();
    S.places.answers[slot] = { ok: false, text: text };
    drawPlaces();
  }
  function placeWrite(op, data, slot, node, after) {
    return write(op, data, 'places:' + slot, node).then(function (reply) {
      if (!reply) return null;
      S.places.answers[slot] = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok && after) after(reply);
      loadPlaces();
      // The organisation's own views read its spots from where they draw.
      if (reply.ok && S.org.data) loadOrg();
      if (reply.ok && S.disposal.data) loadDisposal();
      return reply;
    });
  }

  function locationsBody() {
    var d = S.places.data;
    var pos = S.places.pos;
    var groups = [];
    placeKinds().forEach(function (k) {
      var g = groups.filter(function (x) { return x.id === k.group; })[0];
      if (!g) { g = { id: k.group, kinds: [] }; groups.push(g); }
      g.kinds.push(k);
    });
    return frag(
      h('p.hint', 'Every place this resource uses, by kind. Stand on the spot in game and press Use my position: the '
        + 'server reads where you stand. Adjust, then save; every save takes two clicks.'),
      pos ? h('p.note', 'Your position: x ' + fmt(pos.x) + ', y ' + fmt(pos.y) + ', z ' + fmt(pos.z) + ', heading '
        + fmt(pos.heading, 0) + ' (read ' + ago(S.places.posAt) + ')') : null,
      placeAnswer('pos'),
      !d ? (S.places.error ? (S.places.errCode === 'unknown_op' ? empty('This server has no panel-set places.')
        : empty(S.places.error)) : loading('Reading the places…'))
        : groups.map(placeGroup),
      h('h3.st-group-title', 'Places in the settings'),
      S.settings.data ? placeSettings() : loading('Reading the settings…'));
  }

  /** One group of kinds; all of it off for one reason: said once, with its switch. */
  function placeGroup(g) {
    var about = PLACE_GROUPS[g.id] || { title: String(g.id || 'Places') };
    var first = g.kinds[0] || {};
    var allOff = g.kinds.every(function (k) { return k.off && k.off === first.off; });
    return frag(h('h3.st-group-title', about.title),
      about.hint ? h('p.hint', about.hint) : null,
      allOff ? placeOff(first, g.kinds) : g.kinds.map(function (k) { return placeCard(k); }));
  }
  function switchRow(key) {
    var sw = key ? settingEntry(key) : null;
    if (!sw) return key ? (S.settings.data ? null : loading('Reading the switch…')) : null;
    return h('div.st-row', { id: 'st-row-' + sw.key, 'data-key': sw.key }, settingInner(sw));
  }
  function placeOff(k, kinds) {
    return card('Set here once it is on', frag(
      h('p.about', String(k.off)),
      kinds.map(function (x) { return asList(x.rows).length || asList(x.defaults).length ? placeDefaults(x) : null; }),
      switchRow(k.switch)), '.is-warn.place-off');
  }
  function placeDefaults(k) {
    var defaults = asList(k.defaults);
    var rows = asList(k.rows);
    return frag(
      k.using ? h('p.sub', k.label + ': ' + (k.using === 'panel' ? 'standing at the places set here.'
        : 'using its config ' + (k.key ? '(' + k.key + ')' : 'default') + '.')) : null,
      k.defaults ? h('p.sub', 'Defaults (config): ' + (defaults.length ? defaults.map(function (p) {
        return fmt(p.x) + ', ' + fmt(p.y) + ', ' + fmt(p.z);
      }).join(' · ') : 'none')) : null,
      k.off && rows.length ? h('p.sub', num(rows.length) + ' set here, kept while it is off.') : null);
  }

  /** One kind: its rows, and the form that adds one or edits the one picked. */
  function placeCard(kind) {
    var k = kind.id;
    var f = kind.fields || {};
    var rows = asList(kind.rows);
    var edit = kind.single ? (rows[0] ? rows[0].id : '') : (S.places.edit[k] || '');
    var editing = edit ? rows.filter(function (r) { return r.id === edit; })[0] : null;
    var st = S.places.staged;
    var blip = st['blip:' + k] != null ? st['blip:' + k] : (editing ? !!editing.blip : false);
    var enabled = st['en:' + k] != null ? st['en:' + k] : (editing ? editing.enabled !== false : true);
    var pre = 'loc.' + k + '.';
    var open = !kind.off;
    function input(name, attrs) { return field(pre + name, attrs); }
    return card(frag(icon(kind.icon || 'location-dot'), ' ', String(kind.label || k)), frag(
      kind.off ? h('p.note.is-warn', String(kind.off)) : null,
      kind.off ? switchRow(kind.switch) : null,
      kind.note ? h('p.sub', String(kind.note)) : null,
      rows.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Name'), h('th', 'x, y, z, heading'), f.radius ? h('th.num', 'Radius') : null,
          f.blip ? h('th', 'Blip') : null, f.enabled ? h('th', 'On') : null, h('th', ''))),
        h('tbody', rows.map(function (r) {
          return h('tr' + (r.id === edit && !kind.single ? '.is-open' : ''), h('td.name', String(r.label || '—')),
            h('td.mono', fmt(r.x) + ', ' + fmt(r.y) + ', ' + fmt(r.z) + ', ' + fmt(r.heading, 0)),
            f.radius ? h('td.num', fmt(r.radius) + ' m') : null, f.blip ? h('td', r.blip ? 'yes' : 'no') : null,
            f.enabled ? h('td', r.enabled === false ? 'off' : 'on') : null,
            h('td', h('div.inline-form',
              !kind.single && open ? btn('.is-small.ghost', 'loc-edit', { 'data-id': String(r.id), 'data-value': k },
                'Edit', 'pen') : null,
              open ? writeBtn('.is-small.danger', 'loc-remove', { 'data-id': String(r.id), 'data-value': k },
                kind.single ? 'Clear' : 'Remove', 'Click again: remove ' + String(r.label || 'it'), 'trash-can') : null)));
        })))) : empty(kind.single ? 'Not set.' : 'None set here.'),
      kind.using || kind.defaults ? placeDefaults(kind) : null,
      open ? h('div.loc-form',
        h('p.sub', editing ? 'Editing ' + String(editing.label || kind.one || k) : 'Add ' + String(kind.one || 'a place')),
        h('div.toolbar',
          f.label ? input('label', { class: 'is-mid', maxlength: String(kind.labelMax || 64), placeholder: 'Name',
            value: editing ? String(editing.label || '') : '', 'aria-label': 'Name' }) : null,
          ['x', 'y', 'z'].map(function (a) {
            return input(a, { class: 'is-short', inputmode: 'decimal', placeholder: a, value: editing ? fmt(editing[a]) : '',
              'aria-label': a });
          }),
          input('h', { class: 'is-short', inputmode: 'decimal', placeholder: 'heading',
            value: editing ? fmt(editing.heading, 0) : '', 'aria-label': 'Heading' }),
          f.radius ? input('r', { class: 'is-short', inputmode: 'decimal', placeholder: 'radius m',
            value: editing && editing.radius != null ? fmt(editing.radius) : '', 'aria-label': 'Radius (m)' }) : null),
        h('div.toolbar',
          f.blip ? segmented('loc-blip', [{ value: 'no', label: 'No blip' }, { value: 'yes', label: 'Map blip' }],
            blip ? 'yes' : 'no', { 'data-id': k }) : null,
          f.enabled ? segmented('loc-enabled', [{ value: 'yes', label: 'On' }, { value: 'no', label: 'Off' }],
            enabled ? 'yes' : 'no', { 'data-id': k }) : null,
          btn('.is-small', 'loc-mypos', { 'data-value': k }, 'Use my position', 'location-crosshairs'),
          writeBtn('.primary.is-small', 'loc-save', { 'data-value': k, 'data-id': edit }, 'Save', 'Click again to save',
            'check'),
          writeBtn('.is-small', 'loc-here', { 'data-value': k, 'data-id': edit }, 'Save where I stand',
            'Click again: save where you stand', 'street-view'),
          editing && !kind.single ? btn('.is-small.ghost', 'loc-new', { 'data-value': k }, 'New instead', 'plus') : null,
          kind.reset && rows.length ? writeBtn('.is-small.ghost', 'loc-reset', { 'data-value': k }, 'Reset to config',
            'Click again: remove every place set here', 'rotate-left') : null),
        placeAnswer('loc:' + k)) : placeAnswer('loc:' + k)), '.loc-kind');
  }

  /** The settings that are places, with Use my position filling a line. */
  function placeSettings() {
    var entries = allSettings().filter(function (e) { return !!placeOf(e); });
    if (!entries.length) return empty('No place settings on this server.');
    var jail = entries.filter(function (e) { return placeOf(e) === 'jail'; });
    return frag(entries.filter(function (e) { return placeOf(e) !== 'jail'; }).map(function (e) {
      return h('div.loc-setting',
        settingRow(e),
        placeOf(e) !== 'name' && settingOpen(e) ? h('div.btn-row', btn('.is-small', 'loc-fill', { 'data-key': e.key },
          'Use my position for a new line', 'location-crosshairs')) : null);
    }), jail.length ? h('div.loc-setting', h('h3.st-group-title', 'Prison zone'),
      jail.map(function (e) { return settingRow(e); }),
      settingOpen(jail[0]) ? h('div.btn-row', btn('.is-small', 'loc-fill', { 'data-key': jail[0].key },
        'Use my position for the centre', 'location-crosshairs')) : null) : null);
  }

  /** Use my position: read by the server, from where the character stands. */
  function myPosition() {
    return ask('placeMyPosition', {}, 'placePos').then(function (reply) {
      if (!reply) return null;
      if (!reply.ok) { S.places.answers.pos = { ok: false, text: words(reply) }; drawPlaces(); return null; }
      S.places.answers.pos = null;
      S.places.pos = reply.data || {};
      S.places.posAt = nowSeconds();
      return S.places.pos;
    });
  }
  ACTIONS['loc-mypos'] = function (node) {
    var k = node.getAttribute('data-value');
    myPosition().then(function (pos) {
      if (!pos) return;
      var pre = 'loc.' + k + '.';
      S.forms[pre + 'x'] = fmt(pos.x);
      S.forms[pre + 'y'] = fmt(pos.y);
      S.forms[pre + 'z'] = fmt(pos.z);
      S.forms[pre + 'h'] = fmt(pos.heading, 0);
      disarm();
      drawPlaces();
    });
  };
  ACTIONS['loc-fill'] = function (node) {
    var key = node.getAttribute('data-key');
    myPosition().then(function (pos) {
      if (!pos) return;
      var kind = placeOf(settingEntry(key));
      if (kind === 'jail') {
        S.forms['st.Limits.JailZone.x'] = fmt(pos.x);
        S.forms['st.Limits.JailZone.y'] = fmt(pos.y);
        drawPlaces();
        return;
      }
      var line = kind === 'point' ? fmt(pos.x) + ', ' + fmt(pos.y) + ', ' + fmt(pos.z) + ', ' + fmt(pos.heading, 0)
        : kind === 'zone' ? fmt(pos.x) + ', ' + fmt(pos.y) + ', 50, New zone'
          : kind === 'district' ? fmt(pos.x) + ', ' + fmt(pos.y) + ', New district'
            : 'New area@' + fmt(pos.x) + ',' + fmt(pos.y);
      S.forms['stl.' + key] = line;
      drawPlaces();
    });
  };
  function clearForm(k) {
    ['label', 'x', 'y', 'z', 'h', 'r'].forEach(function (f) { delete S.forms['loc.' + k + '.' + f]; });
    delete S.places.staged['blip:' + k];
    delete S.places.staged['en:' + k];
  }
  ACTIONS['loc-edit'] = function (node) {
    var k = node.getAttribute('data-value');
    S.places.edit[k] = node.getAttribute('data-id');
    clearForm(k);
    disarm();
    drawPlaces();
  };
  ACTIONS['loc-new'] = function (node) {
    var k = node.getAttribute('data-value');
    S.places.edit[k] = '';
    clearForm(k);
    disarm();
    drawPlaces();
  };
  ACTIONS['loc-blip'] = function (node) {
    disarm(); S.places.staged['blip:' + node.getAttribute('data-id')] = node.getAttribute('data-value') === 'yes'; drawPlaces();
  };
  ACTIONS['loc-enabled'] = function (node) {
    disarm(); S.places.staged['en:' + node.getAttribute('data-id')] = node.getAttribute('data-value') === 'yes'; drawPlaces();
  };
  function spotSpec(k, here) {
    var kind = placeKind(k) || { fields: {} };
    var f = kind.fields || {};
    var id = kind.single ? '' : (S.places.edit[k] || '');
    var editing = kind.single ? asList(kind.rows)[0] || null
      : id ? asList(kind.rows).filter(function (s) { return s.id === id; })[0] : null;
    var pre = 'loc.' + k + '.';
    function val(name, from) { var t = S.forms[pre + name]; return trim(t === undefined ? (from == null ? '' : from) : t); }
    var spec = { kind: k };
    if (id) spec.id = id;
    if (f.label) {
      var label = val('label', editing && editing.label);
      if (!label && !kind.labelOptional) return { error: 'Give the place a name.' };
      if (label) spec.label = label.slice(0, kind.labelMax || 64);
    }
    if (f.radius) {
      var r = val('r', editing && editing.radius != null ? fmt(editing.radius) : '');
      if (r !== '') {
        spec.radius = Number(r);
        var lim = kind.radius || { min: 0.5, max: 50 };
        if (!isFinite(spec.radius) || spec.radius < lim.min || spec.radius > lim.max) {
          return { error: 'The radius is ' + lim.min + ' to ' + lim.max + ' m.' };
        }
      }
    }
    var st = S.places.staged;
    if (f.blip) spec.blip = st['blip:' + k] != null ? st['blip:' + k] : !!(editing && editing.blip);
    if (f.enabled) spec.enabled = st['en:' + k] != null ? st['en:' + k] : !(editing && editing.enabled === false);
    if (here) { spec.here = true; return spec; }
    var nums = ['x', 'y', 'z', 'h'].map(function (a) {
      return val(a, editing && (a === 'h' ? fmt(editing.heading, 0) : fmt(editing[a])));
    });
    if (nums.slice(0, 3).some(function (t) { return t === '' || !isFinite(Number(t)); })) {
      return { error: 'Give x, y and z as numbers, or press Use my position.' };
    }
    spec.x = Number(nums[0]); spec.y = Number(nums[1]); spec.z = Number(nums[2]);
    spec.heading = nums[3] === '' ? 0 : Number(nums[3]);
    if (!isFinite(spec.heading) || spec.heading < 0 || spec.heading > 360) {
      return { error: 'The heading is a number from 0 to 360.' };
    }
    return spec;
  }
  function locSave(node, here) {
    var k = node.getAttribute('data-value');
    var kind = placeKind(k) || {};
    var spec = spotSpec(k, here);
    if (spec.error) { placeRefuse('loc:' + k, spec.error); return; }
    var pre = 'loc.' + k + '.';
    var what = spec.label || kind.one || 'the place';
    var label = here ? 'Click again: save ' + what + ' where you stand'
      : 'Click again: save ' + what + ' at ' + fmt(spec.x) + ', ' + fmt(spec.y);
    if (!armed(node, label, ['label', 'x', 'y', 'z', 'h', 'r'].map(function (f) { return pre + f; }))) return;
    placeWrite('placeSet', spec, 'loc:' + k, node, function () {
      clearForm(k);
      S.places.edit[k] = '';
    });
  }
  ACTIONS['loc-save'] = function (node) { locSave(node, false); };
  ACTIONS['loc-here'] = function (node) { locSave(node, true); };
  ACTIONS['loc-remove'] = function (node) {
    if (!armed(node)) return;
    placeWrite('placeRemove', { id: node.getAttribute('data-id') }, 'loc:' + (node.getAttribute('data-value') || 'place'),
      node);
  };
  ACTIONS['loc-reset'] = function (node) {
    var k = node.getAttribute('data-value');
    if (!armed(node)) return;
    placeWrite('placeReset', { kind: k }, 'loc:' + k, node);
  };

  SHELL.locations = function () { return h('section.view', h('div.stack', { id: 'places-body' }, locationsBody())); };
  LOAD.locations = function () {
    if (!S.settings.data) loadSettings();
    return loadPlaces();
  };
  /** The switches the kinds name, as last read, to tell when one moved. */
  function placeSwitches() {
    return placeKinds().map(function (k) {
      var e = k.switch ? settingEntry(k.switch) : null;
      return e ? k.switch + '=' + (e.value === true) : '';
    }).join('|');
  }
  AFTER_SETTINGS.push(function () {
    if (S.section !== 'locations') return;
    // A switch turned on or off from a card here: what can be set now.
    var now = placeSwitches();
    if (S.places.data && S.places.switches != null && now !== S.places.switches) { loadPlaces(); return; }
    S.places.switches = now;
    drawPlaces();
  });

  /* -- the shells -- */

  Object.keys(ORG_VIEWS).concat(Object.keys(BP_VIEWS)).forEach(function (view) {
    SHELL[view] = function () { return h('section.view', h('div.stack', { id: 'org-body' }, orgViewBody())); };
    LOAD[view] = function () {
      var ready = S.org.data ? Promise.resolve() : loadOrg();
      if (!S.settings.data && (view === 'orgsetup' || view === 'bplimits' || view === 'bpmatrix')) {
        loadSettings();
      }
      // The ledger and the log only of an organisation that is on.
      ready.then(function () {
        if (S.section !== view || !orgOn()) return;
        if (view === 'orgfunds') loadOrgFunds();
      });
    };
  });

  /* -- the clicks -- */

  ACTIONS['org-setup'] = function (node) {
    if (!armed(node)) return;
    orgWrite('orgSetup', {}, 'setup', node);
  };
  ACTIONS['org-rename'] = function (node) {
    var label = trim(S.forms['org.label']);
    if (!label) { orgRefuse('rename', 'Give the label.'); return; }
    if (!armed(node, 'Click again: rename to ' + label, ['org.label'])) return;
    orgWrite('orgRename', { label: label.slice(0, 64) }, 'rename', node, function () { delete S.forms['org.label']; });
  };
  ACTIONS['org-tab-hide'] = function (node) {
    var d = S.org.data || {};
    var tab = node.getAttribute('data-value'), grade = node.getAttribute('data-id');
    var saved = (d.layout && d.layout.hidden) || {};
    if (!S.org.layout) S.org.layout = { hidden: {} };
    var list = S.org.layout.hidden[tab] || asList(saved[tab]).map(String);
    var at = list.indexOf(grade);
    if (at === -1) list = list.concat([grade]); else list = list.filter(function (g) { return g !== grade; });
    S.org.layout.hidden[tab] = list;
    disarm();
    drawOrg();
  };
  ACTIONS['org-layout'] = function (node) {
    var d = S.org.data || {};
    var saved = d.layout || {};
    var labels = {}, hidden = {};
    var bad = null;
    ORG_TABS.forEach(function (tab) {
      var typed = S.forms['org.tab.' + tab];
      var text = trim(typed === undefined ? ((saved.labels || {})[tab] || '') : typed);
      if (text) {
        if (text.length > 24) bad = 'A tab label is at most 24 characters.';
        labels[tab] = text;
      }
      var list = (S.org.layout && S.org.layout.hidden[tab]) || asList((saved.hidden || {})[tab]).map(String);
      if (list.length) hidden[tab] = list.map(Number);
    });
    if (bad) { orgRefuse('layout', bad); return; }
    if (!armed(node, 'Click again: save the boss menu')) return;
    orgWrite('orgLayout', { layout: { labels: labels, hidden: hidden } }, 'layout', node, function () { S.org.layout = null; });
  };

  ACTIONS['org-role-open'] = function (node) {
    disarm();
    var g = node.getAttribute('data-id');
    S.org.role = String(S.org.role) === g ? null : Number(g);
    drawOrg();
  };
  ACTIONS['org-new-boss'] = function (node) { disarm(); S.org.newBoss = node.getAttribute('data-value') === 'yes'; drawOrg(); };
  ACTIONS['org-role-boss'] = function (node) {
    disarm();
    S.org.staged['boss:' + node.getAttribute('data-id')] = node.getAttribute('data-value') === 'yes';
    drawOrg();
  };
  ACTIONS['org-role-lock'] = function (node) {
    disarm();
    S.org.staged['lock:' + node.getAttribute('data-id')] = node.getAttribute('data-value') === 'yes';
    drawOrg();
  };
  function wholeOrNull(text, lo, hi) {
    var t = trim(text);
    if (t === '') return null;
    if (!/^-?\d+$/.test(t)) return false;
    var n = Number(t);
    return n >= lo && n <= hi ? n : false;
  }
  ACTIONS['org-role-add'] = function (node) {
    var grade = wholeOrNull(S.forms['org.new.grade'], 0, 100);
    var pay = wholeOrNull(S.forms['org.new.pay'], 0, 100000000);
    var label = trim(S.forms['org.new.label']), name = trim(S.forms['org.new.name']);
    if (grade === null || grade === false) { orgRefuse('role-add', 'Give the role a whole grade from 0 to 100.'); return; }
    if (!label || !name) { orgRefuse('role-add', 'Give the role a name and a label.'); return; }
    if (pay === false) { orgRefuse('role-add', 'Pay is a whole number of dollars.'); return; }
    if (!armed(node, 'Click again: add ' + label + ' at grade ' + grade,
      ['org.new.grade', 'org.new.pay', 'org.new.label', 'org.new.name'])) return;
    var data = { grade: grade, name: name.slice(0, 64), label: label.slice(0, 64), isBoss: !!S.org.newBoss };
    if (pay !== null) data.pay = pay;
    orgWrite('orgRoleSet', data, 'role-add', node, function () {
      ['org.new.grade', 'org.new.pay', 'org.new.label', 'org.new.name'].forEach(function (k) { delete S.forms[k]; });
      S.org.newBoss = false;
    });
  };
  ACTIONS['org-role-save'] = function (node) {
    var d = S.org.data || {};
    var g = node.getAttribute('data-id');
    var role = asList(d.roles).filter(function (r) { return String(r.grade) === g; })[0];
    if (!role) return;
    var pre = 'org.role.' + g + '.';
    var name = trim(typedOr(pre + 'name', role.name)), label = trim(typedOr(pre + 'label', role.label));
    var pay = wholeOrNull(typedOr(pre + 'pay', role.pay == null ? '' : role.pay), 0, 100000000);
    var newGrade = wholeOrNull(typedOr(pre + 'grade', g), 0, 100);
    if (!name || !label) { orgRefuse('role:' + g, 'A role needs a name and a label.'); return; }
    if (pay === false) { orgRefuse('role:' + g, 'Pay is a whole number of dollars.'); return; }
    if (newGrade === false || newGrade === null) { orgRefuse('role:' + g, 'The grade is a whole number from 0 to 100.'); return; }
    if (!armed(node, 'Click again: save ' + label, [pre + 'name', pre + 'label', pre + 'pay', pre + 'grade'])) return;
    var data = { grade: Number(g), name: name.slice(0, 64), label: label.slice(0, 64) };
    if (pay !== null) data.pay = pay;
    if (newGrade !== Number(g)) data.newGrade = newGrade;
    if (S.org.staged['boss:' + g] != null) data.isBoss = S.org.staged['boss:' + g];
    if (S.org.staged['lock:' + g] != null) data.locked = S.org.staged['lock:' + g];
    orgWrite('orgRoleSet', data, 'role:' + g, node, function () {
      [pre + 'name', pre + 'label', pre + 'pay', pre + 'grade'].forEach(function (k) { delete S.forms[k]; });
      delete S.org.staged['boss:' + g];
      delete S.org.staged['lock:' + g];
      if (data.newGrade != null) S.org.role = data.newGrade;
    });
  };
  ACTIONS['org-role-remove'] = function (node) {
    var g = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgRoleRemove', { grade: Number(g) }, 'role:' + g, node, function () { S.org.role = null; });
  };
  ACTIONS['org-role-power'] = function (node) {
    var g = node.getAttribute('data-id'), code = node.getAttribute('data-power');
    var on = node.getAttribute('data-value') === 'on';
    if (!armed(node)) return;
    orgWrite('orgRolePowers', { grade: Number(g), power: code, on: on }, 'power:' + g, node);
  };

  ACTIONS['org-hire-grade'] = function (node) { disarm(); S.org.hire = node.getAttribute('data-value'); drawOrg(); };
  ACTIONS['org-hire'] = function (node) {
    var d = S.org.data || {};
    var roles = asList(d.roles);
    var grade = S.org.hire != null ? S.org.hire : (roles.length ? String(roles[roles.length - 1].grade) : null);
    if (grade == null) { orgRefuse('hire', 'Add a role first, in Roles & pay.'); return; }
    var data = { grade: Number(grade) };
    var who;
    if (hasPlayer()) {
      data.ref = S.players.ref;
      who = String((S.players.data.player || {}).name || 'them');
    } else {
      var cid = trim(S.forms['org.hire.cid']);
      if (!cid) { orgRefuse('hire', 'Look a player up in Players first, or give their exact citizen id.'); return; }
      data.subject = cid.slice(0, 64);
      who = cid;
    }
    if (!armed(node, 'Click again: hire ' + who + ' as ' + roleName(d, grade), ['org.hire.cid'])) return;
    orgWrite('orgMemberHire', data, 'hire', node, function () { delete S.forms['org.hire.cid']; });
  };
  ACTIONS['org-member-open'] = function (node) {
    disarm();
    var ref = node.getAttribute('data-id');
    S.org.member = S.org.member === ref ? null : ref;
    drawOrg();
  };
  ACTIONS['org-member-grade'] = function (node) {
    disarm();
    S.org.staged['role:' + node.getAttribute('data-id')] = node.getAttribute('data-value');
    drawOrg();
  };
  ACTIONS['org-member-state'] = function (node) {
    disarm();
    S.org.staged['state:' + node.getAttribute('data-id')] = node.getAttribute('data-value');
    drawOrg();
  };
  function memberName(ref) { var m = memberOf(S.org.data || {}, ref); return m ? String(m.name || 'them') : 'them'; }
  ACTIONS['org-member-role'] = function (node) {
    var d = S.org.data || {};
    var ref = node.getAttribute('data-id');
    var m = memberOf(d, ref);
    var grade = S.org.staged['role:' + ref] != null ? S.org.staged['role:' + ref] : (m && String(m.grade));
    if (grade == null) return;
    if (m && String(m.grade) === String(grade)) { orgRefuse('role-of:' + ref, 'They hold that role already: pick another.'); return; }
    if (!armed(node, 'Click again: make ' + memberName(ref) + ' ' + roleName(d, grade))) return;
    orgWrite('orgMemberRole', { member: ref, grade: Number(grade) }, 'role-of:' + ref, node, function () {
      delete S.org.staged['role:' + ref];
    });
  };
  ACTIONS['org-member-suspend'] = function (node) {
    var ref = node.getAttribute('data-id');
    var pre = 'org.m.' + ref + '.';
    var hours = wholeOrNull(S.forms[pre + 'hours'], 0, 720);
    if (hours === null || hours === false) { orgRefuse('suspend:' + ref, 'Hours are a whole number from 0 (lifts it) to 720.'); return; }
    if (!armed(node, hours === 0 ? 'Click again: lift ' + memberName(ref) + '\'s suspension'
      : 'Click again: suspend ' + memberName(ref) + ' for ' + hours + ' h', [pre + 'hours', pre + 'sreason'])) return;
    orgWrite('orgMemberSuspend', { member: ref, hours: hours, reason: trim(S.forms[pre + 'sreason']).slice(0, 200) },
      'suspend:' + ref, node, function () { delete S.forms[pre + 'hours']; delete S.forms[pre + 'sreason']; });
  };
  ACTIONS['org-member-limits'] = function (node) {
    var ref = node.getAttribute('data-id');
    var pre = 'org.m.' + ref + '.';
    var m = memberOf(S.org.data || {}, ref) || {};
    var lim = m.limits || {};
    var at = wholeOrNull(typedOr(pre + 'at', lim.maxAtOnce == null ? '' : lim.maxAtOnce), 1, 50);
    var cd = wholeOrNull(typedOr(pre + 'cd', lim.cooldownMinutes == null ? '' : lim.cooldownMinutes), 0, 10080);
    if (at === false || cd === false) { orgRefuse('limits:' + ref, 'At once is 1 to 50, the cooldown 0 to 10080 minutes; empty is the server\'s.'); return; }
    if (!armed(node, 'Click again: ' + (at == null ? 'server\'s' : at) + ' at once, '
      + (cd == null ? 'server\'s' : cd + ' min') + ' cooldown', [pre + 'at', pre + 'cd'])) return;
    var data = { member: ref };
    if (at != null) data.maxAtOnce = at;
    if (cd != null) data.cooldownMinutes = cd;
    orgWrite('orgMemberLimits', data, 'limits:' + ref, node, function () { delete S.forms[pre + 'at']; delete S.forms[pre + 'cd']; });
  };
  ACTIONS['org-member-grant'] = function (node) {
    var d = S.org.data || {};
    var ref = node.getAttribute('data-id');
    var power = S.org.staged['power:' + ref] || (asList(d.powers)[0] || {}).code;
    var state = S.org.staged['state:' + ref] || 'grant';
    if (!power) return;
    if (!armed(node, 'Click again: ' + (state === 'clear' ? 'clear ' + powerName(d, power) + ' for '
      : state + ' ' + powerName(d, power) + ' to ') + memberName(ref))) return;
    orgWrite('orgMemberOverride', { member: ref, power: power, state: state }, 'grant:' + ref, node);
  };
  ACTIONS['org-member-codename'] = function (node) {
    var ref = node.getAttribute('data-id');
    var bind = 'org.m.' + ref + '.codename';
    var text = trim(S.forms[bind]);
    if (text.length > 32) { orgRefuse('staff:' + ref, 'A codename is at most 32 characters.'); return; }
    if (!armed(node, text ? 'Click again: codename ' + text : 'Click again: clear the codename', [bind])) return;
    orgWrite('orgMemberOverride', { member: ref, codename: text ? text : false }, 'staff:' + ref, node, function () {
      delete S.forms[bind];
    });
  };
  ACTIONS['org-member-lock'] = function (node) {
    var ref = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgMemberOverride', { member: ref, locked: node.getAttribute('data-value') === 'on' }, 'staff:' + ref, node);
  };
  ACTIONS['org-member-fire'] = function (node) {
    var ref = node.getAttribute('data-id');
    var bind = 'org.m.' + ref + '.freason';
    var reason = trim(S.forms[bind]);
    if (!reason) { orgRefuse('fire:' + ref, 'Give a reason: it goes on the record.'); return; }
    if (!armed(node, null, [bind])) return;
    orgWrite('orgMemberFire', { member: ref, reason: reason.slice(0, 200) }, 'fire:' + ref, node, function () {
      delete S.forms[bind];
      S.org.member = null;
    });
  };

  ACTIONS['org-app'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgApplication', { id: id, accept: node.getAttribute('data-value') === 'yes' }, 'app:' + id, node);
  };

  ACTIONS['org-dir'] = function (node) { disarm(); S.org.dir = node.getAttribute('data-value'); drawOrg(); };
  ACTIONS['org-funds'] = function (node) {
    var dir = S.org.dir;
    var amount = wholeOrNull(S.forms['org.funds.amount'], 1, 100000000);
    var reason = trim(S.forms['org.funds.reason']);
    if (amount === null || amount === false) { orgRefuse('funds', 'Give a whole number of dollars, 1 or more.'); return; }
    if (!reason) { orgRefuse('funds', 'Give a reason: it goes on the record.'); return; }
    if (dir === 'bonus' && !S.org.bonusTo) { orgRefuse('funds', 'Pick the member the bonus goes to.'); return; }
    var label = dir === 'deposit' ? 'Click again: deposit ' + money(amount)
      : dir === 'withdraw' ? 'Click again: withdraw ' + money(amount)
        : 'Click again: pay ' + memberName(S.org.bonusTo) + ' ' + money(amount);
    if (!armed(node, label, ['org.funds.amount', 'org.funds.reason'])) return;
    var data = { direction: dir, amount: amount, reason: reason.slice(0, 200), nonce: orgNonce() };
    if (dir === 'bonus') data.member = S.org.bonusTo;
    orgWrite('orgFundsMove', data, 'funds', node, function () {
      S.org.nonce = null;
      delete S.forms['org.funds.amount'];
      delete S.forms['org.funds.reason'];
      loadOrgFunds();
    }).then(function (reply) {
      // A refusal (not a lost answer) is a new movement next time.
      if (reply && !reply.ok) S.org.nonce = null;
    });
  };
  ACTIONS['org-funds-refresh'] = function () { loadOrgFunds(); };
  /** Where the funds are kept: the ledger or the bank, or (abandon) leave a
      bank that is down carrying nothing. Two clicks, naming what it does. */
  ACTIONS['org-backend'] = function (node) {
    var backend = node.getAttribute('data-value');
    var abandon = node.getAttribute('data-how') === 'abandon';
    if (!armed(node)) return;
    var data = { backend: backend };
    if (abandon) data.abandon = true;
    orgWrite('orgFundsBackend', data, 'backend', node, function () { loadOrgFunds(); });
  };
  ACTIONS['org-cut'] = function (node) {
    var d = S.org.data || {};
    var kind = node.getAttribute('data-value');
    var grade = node.getAttribute('data-id');
    var bind = kind === 'role' ? 'org.cut.role.' + grade : 'org.cut.' + kind;
    var cap = Number((d.limits || {}).TotalCutCapPercent) || 0;
    var pct = wholeOrNull(S.forms[bind], 0, 100);
    if (pct === null || pct === false) { orgRefuse('cut', 'A cut is a whole percent from 0 to ' + cap + '.'); return; }
    if (pct > cap) { orgRefuse('cut', 'At most ' + cap + '%: the cap on all cuts of one payout (Boss permissions, Limits).'); return; }
    var what = kind === 'role' ? 'the cut for ' + roleName(d, grade) : kind === 'payout' ? 'the payout cut'
      : 'the cut on ' + kind + 's';
    if (!armed(node, 'Click again: set ' + what + ' to ' + pct + '%', [bind])) return;
    var data = { kind: kind, percent: pct };
    if (kind === 'role') data.grade = Number(grade);
    orgWrite('orgCuts', data, 'cut', node, function () { delete S.forms[bind]; });
  };
  ACTIONS['org-cut-clear'] = function (node) {
    var g = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgCuts', { kind: 'role', grade: Number(g), percent: false }, 'cut', node);
  };

  ACTIONS['org-acc-rule'] = function (node) { disarm(); S.org.staged['rule:' + node.getAttribute('data-id')] = node.getAttribute('data-value'); drawOrg(); };
  ACTIONS['org-acc-wl'] = function (node) { disarm(); S.org.staged['wl:' + node.getAttribute('data-id')] = node.getAttribute('data-value'); drawOrg(); };
  ACTIONS['org-access'] = function (node) {
    var d = S.org.data || {};
    var g = node.getAttribute('data-id');
    var a = (d.access || {})[g] || {};
    var pre = 'org.acc.' + g + '.';
    var max = wholeOrNull(typedOr(pre + 'max', a.maxReward == null ? '' : a.maxReward), 0, 2000000000);
    var at = wholeOrNull(typedOr(pre + 'at', a.maxAtOnce == null ? '' : a.maxAtOnce), 1, 50);
    var cd = wholeOrNull(typedOr(pre + 'cd', a.cooldownMinutes == null ? '' : a.cooldownMinutes), 0, 10080);
    if (max === false || at === false || cd === false) {
      orgRefuse('access', 'Most reward is whole dollars, at once 1 to 50, the cooldown 0 to 10080 minutes; empty is no rule.');
      return;
    }
    var rule = S.org.staged['rule:' + g] != null ? S.org.staged['rule:' + g] : (a.rule || '');
    var wl = S.org.staged['wl:' + g] != null ? S.org.staged['wl:' + g] : (a.whitelisted === false ? 'no' : 'yes');
    if (!armed(node, null, [pre + 'max', pre + 'at', pre + 'cd'])) return;
    var rules = { maxReward: max == null ? false : max, maxAtOnce: at == null ? false : at,
      cooldownMinutes: cd == null ? false : cd, rule: rule || false, whitelisted: wl !== 'no' };
    orgWrite('orgAccess', { grade: Number(g), rules: rules }, 'access', node, function () {
      [pre + 'max', pre + 'at', pre + 'cd'].forEach(function (k) { delete S.forms[k]; });
      delete S.org.staged['rule:' + g];
      delete S.org.staged['wl:' + g];
    });
  };
  ACTIONS['org-pick'] = function (node) {
    var id = trim(S.forms['org.pick.id']);
    if (!id) { orgRefuse('pick', 'Give the contract id.'); return; }
    var to = S.org.staged.pick || '';
    if (!armed(node, to ? 'Click again: pin ' + id + ' to ' + memberName(to) : 'Click again: clear the pick on ' + id,
      ['org.pick.id'])) return;
    var data = { id: id.slice(0, 64) };
    if (to) data.member = to;
    orgWrite('orgPick', data, 'pick', node);
  };

  ACTIONS['org-broadcast'] = function (node) { disarm(); S.org.staged.broadcast = node.getAttribute('data-value') === 'yes'; drawOrg(); };
  ACTIONS['org-notice'] = function (node) {
    var text = trim(S.forms['org.notice']);
    if (!text) { orgRefuse('notice', 'Write the notice first.'); return; }
    if (!armed(node, S.org.staged.broadcast ? 'Click again: post it and message every member' : 'Click again: post it',
      ['org.notice'])) return;
    orgWrite('orgNotice', { text: text, broadcast: !!S.org.staged.broadcast }, 'notice', node, function () {
      delete S.forms['org.notice'];
    });
  };
  ACTIONS['org-notice-clear'] = function (node) {
    if (!armed(node)) return;
    orgWrite('orgNotice', { text: false }, 'notice', node);
  };
  ACTIONS['org-audit-refresh'] = function () { loadOrgAudit(S.org.auditAction); };

  ACTIONS['bp-cell'] = function (node) {
    var d = S.org.data || {};
    var colKey = node.getAttribute('data-id'), code = node.getAttribute('data-power');
    var col = bpColumns(d).filter(function (c) { return c.key === colKey; })[0];
    if (!col) return;
    var st = bpState(d, col, code);
    var next = col.subject === 'role' ? (st === 'allow' ? 'off' : 'allow')
      : (st === 'inherit' ? 'allow' : st === 'allow' ? 'deny' : 'inherit');
    bpStage(d, col, code, next);
    disarm();
    drawOrg();
  };
  ACTIONS['bp-discard'] = function () { disarm(); S.org.bp.pending = {}; drawOrg(); };
  ACTIONS['bp-granted'] = function (node) { S.org.bp.granted = node.getAttribute('data-value') === 'granted'; drawOrg(); };
  LIVE['bp-filter'] = function () {
    var box = byId('org-body');
    if (!box) return;
    // Only the grid moves; the box keeps what is typed and its focus.
    setHtml(box, orgViewBody());
    var input = box.querySelector && box.querySelector('[data-bind="bp.q"]');
    if (input && input.focus) input.focus();
  };
  /** The pending cells, as one batch: every one checked before any is written. */
  ACTIONS['bp-save'] = function (node) {
    var d = S.org.data || {};
    var list = bpPendingList(d);
    if (!list.length) return;
    if (!armed(node)) return;
    var cells = list.map(function (x) {
      return { subject: x.col.subject, id: x.col.id, power: x.code, state: x.state };
    });
    orgWrite('bossPermsSet', { cells: cells }, 'bp', node, function () { S.org.bp.pending = {}; });
  };
  ACTIONS['bp-revoke'] = function (node) {
    var d = S.org.data || {};
    var colKey = node.getAttribute('data-id');
    var col = bpColumns(d).filter(function (c) { return c.key === colKey; })[0];
    if (!col || !armed(node)) return;
    orgWrite('bossPermsRevokeAll', { subject: col.subject, id: col.id }, 'bp', node, function () {
      Object.keys(S.org.bp.pending).forEach(function (k) { if (k.indexOf(colKey + '|') === 0) delete S.org.bp.pending[k]; });
    });
  };
  ACTIONS['bp-limit'] = function (node) {
    var d = S.org.data || {};
    var k = node.getAttribute('data-id');
    var bind = 'bp.lim.' + k;
    var raw = trim(S.forms[bind]);
    var n = Number(raw);
    if (raw === '' || !isFinite(n) || n < 0) { orgRefuse('limits', 'Give a number for ' + k + '.'); return; }
    var e = settingEntry('Organisation.Limits.' + k);
    if (e && ((e.min != null && n < e.min) || (e.max != null && n > e.max))) {
      orgRefuse('limits', k + ' is from ' + e.min + ' to ' + e.max + '.');
      return;
    }
    if (e && e.integer && Math.floor(n) !== n) { orgRefuse('limits', k + ' is a whole number.'); return; }
    if (!armed(node, 'Click again: ' + k + ' to ' + num(n) + ' (now ' + num((d.limits || {})[k]) + ')', [bind])) return;
    var limits = {};
    limits[k] = n;
    orgWrite('bossLimits', { limits: limits }, 'limits', node, function () { delete S.forms[bind]; });
  };
  ACTIONS['bp-limit-reset'] = function (node) {
    var k = node.getAttribute('data-id');
    if (!armed(node)) return;
    var limits = {};
    limits[k] = false;
    orgWrite('bossLimits', { limits: limits }, 'limits', node);
  };
  ACTIONS['bp-office'] = function (node) {
    if (!armed(node)) return;
    orgWrite('bossOfficeRule', { power: node.getAttribute('data-power'), on: node.getAttribute('data-value') === 'on' },
      'office', node);
  };
  ACTIONS['bp-history-refresh'] = function () { loadOrgAudit('org_grant'); };
  ACTIONS['bp-undo'] = function (node) {
    var g = Number(node.getAttribute('data-id'));
    var code = node.getAttribute('data-power'), state = node.getAttribute('data-value');
    if (!armed(node)) return;
    orgWrite('bossPermsSet', { cells: [{ subject: 'role', id: g, power: code, state: state }] }, 'bp', node, function () {
      loadOrgAudit('org_grant');
    });
  };

  HELP.push(
    { title: 'The hitman organisation', icon: 'people-group',
      text: 'Off as shipped. On, the hitmen are one qbx_core job with roles (its grades), members, funds, a boss menu '
        + 'on the phone and its own places. Every boss power is off until staff allow it in Boss permissions, for a '
        + 'boss role or one boss, within the limits staff set; staff may do everything from the panel. Cuts are '
        + 'frozen onto a contract when a member accepts it.',
      links: [{ key: 'Organisation.Enabled', label: 'The switch' },
        { key: 'Organisation.RequireJobToAccept', label: 'Only members may accept' }] });
  STAFF_ACTIONS.push(
    { title: 'Run the hitman organisation', icon: 'people-group', view: 'orgsetup', go: 'Hitman organisation',
      text: 'Turn it on, sync the job, edit roles and pay, hire, fire, suspend and set members\' limits, move money '
        + 'with a reason, set cuts, contract access, the board notice and applications.',
      also: { view: 'orgmembers', go: 'Members' } },
    { title: 'Give bosses powers', icon: 'key', view: 'bpmatrix', go: 'Boss permissions',
      text: 'The grid of powers by boss role and by one boss: Allow, Deny or Inherit, every change listed before one '
        + 'Save. Limits sets the bounds; Delegation & office which powers need the boss office.',
      also: { view: 'bplimits', go: 'Limits' } },
    { title: 'Set a place on the map', icon: 'location-dot', view: 'locations', go: 'Locations',
      text: 'The boss office, sign-up and meeting spots, the broker and informant NPC places, tip safe zones, rumour '
        + 'districts and the prison zone: stand there in game and press Use my position.' });

  /* Loaded to the end: admin.html's fallback, which gives the focus back
     when this file fails to load or throws while loading, stands down. */
  window.CH_ADMIN_READY = true;
})();
