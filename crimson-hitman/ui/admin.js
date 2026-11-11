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

  /* The words this page shows, by key: locales/en.json (README,
     Translations), read once as the page loads from this resource's own
     files. English first, which every key falls back to; then the language
     the client names (Config.Locale: ?lang= on the phone's address, the
     panel's open message), over it. A key that language lacks reads in
     English, and the console says so once; a key English lacks too reads as
     the key itself (tests/locale_spec.lua keeps that from shipping).
     Text.section(name) is one section's table, kept and updated in place, so
     a table read once (ERRORS) follows a language chosen later. */
  var Text = (function () {
    function load(lang) {
      try {
        var xhr = new XMLHttpRequest();
        // Stamped like every other file the page loads (index.html): CEF
        // keeps its own copy by address, and an old en.json after an update
        // shows the new keys in place of their words.
        xhr.open('GET', '../locales/' + lang + '.json?v=' + encodeURIComponent(window.CH_ADMIN_BUILD || 'dev'), false);
        xhr.send(null);
        if (xhr.status && xhr.status !== 200) { return null; }
        var parsed = JSON.parse(xhr.responseText);
        return parsed && typeof parsed === 'object' ? parsed : null;
      } catch (err) { return null; }
    }
    var said = {};
    function warn(message) {
      if (said[message]) { return; }
      said[message] = true;
      try { console.warn('[crimson-hitman] ' + message); } catch (err) { /* no console */ }
    }
    var english = load('en');
    if (!english) {
      english = {};
      warn('locales/en.json could not be read: the page shows keys in place of words.');
    }
    var sections = {};
    function section(name) {
      if (!sections[name]) {
        var out = {}, from = english[name] || {};
        Object.keys(from).forEach(function (key) { out[key] = from[key]; });
        sections[name] = out;
      }
      return sections[name];
    }
    /* What the page builds from its words as it loads (a table of labels),
       run now and again once a language is applied: the panel learns its
       language from its first open message, after it has loaded. */
    var laters = [], applied = 'en';
    function later(fn) { laters.push(fn); fn(); }
    function use(lang) {
      if (typeof lang !== 'string' || !/^[A-Za-z_-]+$/.test(lang) || lang === 'en' || lang === applied) { return; }
      var chosen = load(lang);
      if (!chosen) { warn('there is no locales/' + lang + '.json (Config.Locale); English is used.'); return; }
      var missing = 0;
      Object.keys(english).forEach(function (name) {
        var into = section(name), from = chosen[name] || {};
        Object.keys(english[name] || {}).forEach(function (key) {
          if (Object.prototype.hasOwnProperty.call(from, key)) { into[key] = from[key]; } else { missing++; }
        });
        // And the plural forms English has no use for (key_few, key_many).
        Object.keys(from).forEach(function (key) {
          if (/_(zero|two|few|many)$/.test(key) && typeof from[key] === 'string') { into[key] = from[key]; }
        });
      });
      if (missing > 0) { warn(lang + ' lacks ' + missing + ' text(s); those read in English.'); }
      applied = lang;
      laters.forEach(function (fn) { fn(); });
    }
    /* The values after the key go into the text in order at %s (or %d);
       a language that puts them in another order writes %2$s, %1$s. */
    function fill(text, args) {
      var next = 0;
      return text.replace(/%(?:(\d+)\$)?[sd]/g, function (all, at) {
        var v = at ? args[Number(at) - 1] : args[next++];
        return v === undefined || v === null ? '' : String(v);
      });
    }
    function tv(key) {
      var at = String(key).indexOf('.');
      var value = at > 0 ? section(key.slice(0, at))[key.slice(at + 1)] : undefined;
      if (typeof value !== 'string') {
        warn('no text for ' + key + '; the key is shown.');
        return String(key);
      }
      return arguments.length > 1 ? fill(value, Array.prototype.slice.call(arguments, 1)) : value;
    }
    /* A text that depends on a count: key_one, key_other, or the other
       forms the language has (key_few, key_many: Intl.PluralRules), with
       key_other wherever a form is missing. The values fill it as for t();
       with none, the count itself does. */
    function plural(n) {
      try {
        if (typeof Intl !== 'undefined' && Intl.PluralRules) { return new Intl.PluralRules(applied).select(Number(n) || 0); }
      } catch (err) { /* an unknown language tag reads as English */ }
      return { 1: 'one' }[Number(n)] || 'other';
    }
    function tn(key, n) {
      var args = arguments.length > 2 ? Array.prototype.slice.call(arguments, 2) : [n];
      var form = key + '_' + plural(n);
      var at = form.indexOf('.');
      var found = at > 0 && typeof section(form.slice(0, at))[form.slice(at + 1)] === 'string';
      return tv.apply(null, [found ? form : key + '_other'].concat(args));
    }
    return { t: tv, tn: tn, section: section, use: use, later: later };
  })();
  /* The one way this page reads a word: t('section.key'), with values to
     fill in after the key; tn('section.key', count) when the words depend
     on a count. */
  var t = Text.t;
  var tn = Text.tn;
  /* The words the page's own HTML shows, by key like the rest: data-t (the
     text), data-t-title, data-t-placeholder and data-t-aria-label. */
  Text.later(function () {
    try {
      var root = document.body || document;
      Array.prototype.forEach.call(root.querySelectorAll('[data-t]'), function (node) {
        node.textContent = t(node.getAttribute('data-t'));
      });
      ['title', 'placeholder', 'aria-label'].forEach(function (name) {
        Array.prototype.forEach.call(root.querySelectorAll('[data-t-' + name + ']'), function (node) {
          node.setAttribute(name, t(node.getAttribute('data-t-' + name)));
        });
      });
    } catch (err) { /* a page with no document of its own */ }
  });

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
    if (value < 1024) return t('admin.size_b', value);
    if (value < 1048576) return t('admin.size_kb', (value / 1024).toFixed(1));
    return t('admin.size_mb', (value / 1048576).toFixed(1));
  }

  function pad(n) { return (n < 10 ? '0' : '') + n; }

  /** A server time (os.time seconds) as a local date and time. */
  function when(ts) {
    var tv = Number(ts);
    if (!tv) return '—';
    var d = new Date(tv * 1000);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
      + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  /** A server time as the local time of day, to the second. */
  function clock(ts) {
    var tv = Number(ts);
    if (!tv) return '--:--:--';
    var d = new Date(tv * 1000);
    return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }

  function nowSeconds() { return Math.floor(Date.now() / 1000); }

  /** How long ago, or how long until, a server time. */
  function ago(ts) {
    var tv = Number(ts);
    if (!tv) return '';
    var delta = nowSeconds() - tv;
    var future = delta < 0;
    var s = Math.abs(delta);
    var text;
    if (s < 45) text = future ? t('admin.in_a_moment') : t('admin.just_now');
    else if (s < 3600) text = t('admin.n_min', Math.round(s / 60));
    else if (s < 86400) text = t('admin.n_h', Math.round(s / 3600));
    else text = t('admin.n_d', Math.round(s / 86400));
    if (s < 45) return text;
    return future ? t('admin.in_x', text) : t('admin.x_ago', text);
  }

  function ms(n) {
    var value = Number(n) || 0;
    return t('admin.n_ms', value < 10 ? value.toFixed(2) : value.toFixed(1));
  }

  function wholeNumber(value) {
    var text = trim(value).replace(/,/g, '');
    if (!/^\d+$/.test(text)) return null;
    var n = Number(text);
    return n >= 1 && n <= 1000000000 ? n : null;
  }

  var STATE_LABEL;
  Text.later(function () {
    STATE_LABEL = {
    active: t('admin.active'), accepted: t('admin.accepted'), completing: t('admin.completing'), completed: t('admin.completed'),
    bailed_out: t('admin.bought_out'), expired: t('admin.expired'), cancelled: t('admin.cancelled'), voided: t('admin.voided')
  };
  });
  var STATE_ORDER = ['active', 'accepted', 'completing', 'completed', 'bailed_out', 'expired',
                     'cancelled', 'voided'];
  var LIVE_STATES = { active: true, accepted: true, completing: true };
  var RULE_LABEL;
  Text.later(function () {
    RULE_LABEL = { alive: t('admin.alive_only'), either: t('admin.kill_or_alive') };
  });
  var MODE_LABEL;
  Text.later(function () {
    MODE_LABEL = { exclusive: t('admin.exclusive'), competitive: t('admin.competitive') };
  });
  var SOURCE_LABEL;
  Text.later(function () {
    SOURCE_LABEL = { cash: 'cash', bank: 'bank', dirty: t('admin.dirty_money'), item: 'item', weapon: 'weapon' };
  });
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
    if (line.source === 'weapon') return t('admin.weapon_paren', String(line.item || t('admin.a_weapon')));
    var count = Number(line.quantity) || 0;
    return (count ? num(count) + ' × ' : '') + String(line.item || t('admin.an_item'));
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
  var GROUPS;
  Text.later(function () {
    GROUPS = [
    { id: 'home', head: 'Daily', label: t('admin.home'), icon: 'house', views: ['overview', 'inbox', 'announce'] },
    { id: 'players', head: 'Daily', label: t('admin.players'), icon: 'user',
      views: ['players', 'pmeasures', 'pmoney', 'pplaytime', 'phistory', 'pdiag', 'measures'] },
    { id: 'contracts', head: 'Daily', label: t('admin.contracts'), icon: 'file-contract', views: ['contracts'] },
    // How often one person may be targeted (server/targetlimits.lua).
    { id: 'targets', head: 'Daily', label: t('admin.target_limits'), icon: 'user-clock',
      views: ['tldefaults', 'tljobs', 'tlplayer'], logs: ['logs:targets', t('admin.history')],
      // The live contracts on each target: the one list of contracts, grouped.
      list: ['contracts:bytarget', t('admin.live_contracts_by_target')] },
    { id: 'rules', head: 'Setup', label: t('admin.game_rules'), icon: 'scale-balanced', views: ['rules', 'presets', 'changed'],
      logs: ['logs:settings', t('admin.change_history')] },
    // The hitman organisation (server/org/), off as shipped.
    { id: 'org', head: 'Setup', label: t('admin.hitman_organisation'), icon: 'people-group',
      views: ['orgsetup', 'orgroles', 'orgmembers', 'orgapps', 'orgfunds', 'orgaccess', 'orgnotices', 'orgwork',
        'orgarmory', 'orgrecord', 'orgturf'],
      logs: ['logs:org', t('admin.org_audit')] },
    { id: 'bossperms', head: 'Setup', label: t('admin.boss_permissions'), icon: 'key',
      views: ['bpmatrix', 'bplimits', 'bpoffice'], logs: ['logs:grants', t('admin.grant_history')] },
    { id: 'locations', head: 'Setup', label: t('admin.locations'), icon: 'location-dot', views: ['locations'] },
    { id: 'logs', head: 'Records', label: t('admin.logs'), icon: 'list-ul', views: ['logs', 'alerts'] },
    { id: 'developer', head: 'Developer', label: t('admin.developer'), icon: 'code',
      views: ['health', 'devsettings', 'console', 'tools', 'setup', 'transfer'], developer: true },
    { id: 'help', head: null, label: t('admin.help'), icon: 'circle-question', views: ['help', 'howto', 'permissions'] }
  ];
  });
  /** Each view's name on its sub-tab, its icon, and on the breadcrumb. */
  var VIEW_LABEL;
  Text.later(function () {
    VIEW_LABEL = {
    inbox: [t('admin.inbox'), 'inbox'], overview: [t('admin.dashboard'), 'gauge-high'], announce: [t('admin.announce'), 'bullhorn'],
    players: [t('admin.find_summary'), 'magnifying-glass'],
    pmeasures: [t('admin.measures'), 'snowflake'], pmoney: [t('admin.money'), 'sack-dollar'], pplaytime: [t('admin.playtime'), 'clock'],
    phistory: [t('admin.history'), 'clock-rotate-left'], pdiag: [t('admin.why_can_t_they_see'), 'stethoscope'],
    measures: [t('admin.all_measures'), 'list-check'],
    contracts: [t('admin.contracts'), 'file-contract'],
    tldefaults: [t('admin.defaults'), 'sliders'], tljobs: [t('admin.per_job'), 'briefcase'], tlplayer: [t('admin.per_player'), 'user-clock'],
    rules: [t('admin.areas'), 'layer-group'], presets: [t('admin.presets'), 'box-archive'], changed: [t('admin.changed_from_the_panel'), 'pen'],
    orgsetup: [t('admin.setup'), 'gear'], orgroles: [t('admin.roles_pay'), 'id-badge'], orgmembers: [t('admin.members'), 'users'],
    orgapps: [t('admin.applications'), 'envelope-open-text'], orgfunds: [t('admin.funds_cuts'), 'vault'],
    orgaccess: [t('admin.contract_access'), 'door-open'], orgnotices: [t('admin.notices'), 'thumbtack'],
    orgwork: [t('admin.work_channel'), 'briefcase'], orgarmory: [t('admin.armory'), 'box-open'],
    orgrecord: [t('admin.record_discipline'), 'ranking-star'],
    orgturf: [t('admin.reputation_drops_garage'), 'map'],
    bpmatrix: [t('admin.matrix'), 'table-cells'], bplimits: [t('admin.limits'), 'sliders'], bpoffice: [t('admin.delegation_office'), 'building'],
    locations: [t('admin.map_points'), 'location-dot'],
    logs: [t('admin.logs'), 'list-ul'], alerts: [t('admin.alerts'), 'bell'],
    health: [t('admin.health'), 'heart-pulse'], devsettings: [t('admin.engine_settings'), 'gear'], console: [t('admin.console'), 'terminal'],
    tools: [t('admin.test_tools'), 'screwdriver-wrench'], setup: [t('admin.first_start_setup'), 'wand-magic-sparkles'],
    transfer: [t('admin.export_import'), 'right-left'],
    help: [t('admin.how_it_works'), 'circle-question'], howto: [t('admin.how_do_i'), 'hand'], permissions: [t('admin.who_can_do_what'), 'key']
  };
  });
  /** One line of help under every view's title (drawn with the breadcrumb). */
  var VIEW_HELP;
  Text.later(function () {
    VIEW_HELP = {
    overview: t('admin.everything_at_a_glance_what_waits'),
    inbox: t('admin.what_waits_for_staff_reviews_no'),
    announce: t('admin.send_one_notice_to_every_hitman'),
    players: t('admin.look_a_player_up_by_player'),
    pmeasures: t('admin.freeze_suspend_or_protect_this_player'),
    pmoney: t('admin.what_this_player_is_owed_notices'),
    pplaytime: t('admin.the_hours_counted_for_this_player'),
    phistory: t('admin.this_players_contracts_money_and_measures'),
    pdiag: t('admin.why_a_contract_the_board_or'),
    measures: t('admin.everybody_frozen_suspended_protected_or_with'),
    contracts: t('admin.every_contract_search_filter_by_state'),
    tldefaults: t('admin.how_often_one_person_may_have'),
    tljobs: t('admin.a_jobs_own_target_limits_and'),
    tlplayer: t('admin.one_targets_cooldown_and_counts_exactly'),
    rules: t('admin.every_game_rule_by_the_area'),
    changed: t('admin.the_settings_changed_from_this_panel'),
    presets: t('admin.named_bundles_of_settings_shipped_and'),
    orgsetup: t('admin.the_hitman_organisations_switch_its_job'),
    orgroles: t('admin.the_organisations_roles_their_rank_and'),
    orgmembers: t('admin.who_is_in_the_organisation_their'),
    orgapps: t('admin.applications_to_join_the_organisation_to'),
    orgfunds: t('admin.the_organisations_money_and_the_cut'),
    orgaccess: t('admin.which_contracts_the_organisations_members_may'),
    orgnotices: t('admin.notices_pinned_for_the_organisations_members'),
    orgwork: t('admin.contracts_sent_to_the_organisation_accepts'),
    orgarmory: t('admin.the_organisations_armory_what_it_holds'),
    orgrecord: t('admin.each_members_record_and_the_leaderboard'),
    orgturf: t('admin.reputation_and_tiers_dead_drops_territory'),
    bpmatrix: t('admin.what_each_boss_role_and_each'),
    bplimits: t('admin.the_limits_on_each_boss_power'),
    bpoffice: t('admin.which_powers_bosses_may_hand_down'),
    locations: t('admin.every_place_on_the_map_this'),
    logs: t('admin.every_staff_and_game_action_on'),
    alerts: t('admin.problems_the_server_raised_to_acknowledge'),
    health: t('admin.what_the_server_itself_is_doing'),
    devsettings: t('admin.engine_settings_storage_timings_and_limits'),
    console: t('admin.run_a_staff_console_command_from'),
    tools: t('admin.test_tools_try_a_feature_without'),
    setup: t('admin.the_first_start_setup_storage_your'),
    transfer: t('admin.every_setting_changed_here_and_your'),
    help: t('admin.how_the_contract_app_works_in'),
    howto: t('admin.short_answers_to_how_do_i'),
    permissions: t('admin.who_can_do_what_every_permission')
  };
  });
  Text.later(function () {
    window.CH_ADMIN_VIEW_HELP = VIEW_HELP;
  });

  /** The views only the Developer section's staff see. */
  var DEV_VIEWS = { health: true, devsettings: true, console: true, transfer: true };
  /** A selected player's own tabs, shown once somebody is looked up. */
  var PERSON_VIEWS = { pmeasures: true, pmoney: true, pplaytime: true, phistory: true, pdiag: true };
  var PLAYER_VIEWS = { players: true, pmeasures: true, pmoney: true, pplaytime: true,
                       phistory: true, pdiag: true };
  var ORG_VIEWS = { orgsetup: true, orgroles: true, orgmembers: true, orgapps: true, orgfunds: true,
                    orgaccess: true, orgnotices: true, orgwork: true, orgarmory: true, orgrecord: true,
                    orgturf: true };
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
                   settingsExport: true, settingsImport: true,
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
    // Developer > Export and import (server/settingsio.lua).
    transfer: { exported: null, preview: null, error: null, answer: null, text: null },
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
        return t('admin.moderator_you_may_freeze_suspend_protect')
          + t('admin.ace_itself_config_admin_ace');
      }
      return t('admin.read_only_changing_anything_needs_the')
        + t('admin.the_extra_aces_only_read');
    }
    if (S.recovery === 'recovering') return t('admin.still_recovering_from_the_restart_try');
    if (S.recovery === 'recovery_failed') {
      return t('admin.recovery_failed_at_the_last_start');
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
    node.setAttribute('title', t('admin.click_to_dismiss'));
    setHtml(node, frag(
      icon(kind === 'ok' ? 'circle-check' : kind === 'error' ? 'circle-exclamation' : 'circle-info'),
      h('span.toast-text', String(text))));
    box.appendChild(node);
    while (box.children.length > TOASTS_MAX) box.removeChild(box.children[0]);
    setTimeout(function () { node.remove(); }, kind === 'error' ? TOAST_ERROR_MS : TOAST_MS);
  }

  /* ---------- requests ------------------------------------------------- */

  /** What a refusal says, when the server gave no sentence of its own. */
  var WORDS = Text.section('panel_errors');

  function words(reply) {
    if (!reply) return WORDS.no_answer;
    if (reply.message) return String(reply.message);
    if (reply.ok) return t('panel.done');
    return WORDS[reply.err] || t('panel.refused_without_saying');
  }
  /** For the tests. */
  window.CH_ADMIN_WORDS = words;

  /** Ask the server. Resolves the reply ({ ok, err, message, data }, or one
      saying nothing answered), or null when nobody is waiting for it any more:
      the panel closed or opened again since, or a newer request went out on
      the same channel (a search typed on). */
  /** Several organisations: the ops that work on one, sent with the one
      picked in Hitman organisation > Setup (data.org; none: the first). */
  var ORG_SCOPED = /^(org|bossPerms|bossLimits|bossOfficeRule|place)/;
  var ORG_UNSCOPED = { orgCreate: true, orgRemove: true };
  function scopeOrg(op, data) {
    if (!S.orgScope || ORG_UNSCOPED[op]) return data;
    var scoped = ORG_SCOPED.test(op) || (op === 'logs' && data && (data.area === 'org' || data.area === 'grants'));
    if (!scoped || (data && data.org !== undefined)) return data;
    var out = {};
    Object.keys(data || {}).forEach(function (k) { out[k] = data[k]; });
    out.org = S.orgScope;
    return out;
  }

  function ask(op, data, channel) {
    data = scopeOrg(op, data || {});
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

  function loading(text) { return h('p.loading', icon('spinner'), ' ', text || t('admin.loading')); }

  function answerBox(answer) {
    if (!answer) return null;
    return h('div.notice.answer' + (answer.ok ? '.ok' : ''), { role: 'status' },
      icon(answer.ok ? 'circle-check' : 'circle-exclamation'), h('span.answer-text', answer.text));
  }

  function card(title, body, extraCls, aside) {
    return h('section.card' + (extraCls || ''), h('header.card-head', h('h3', title), aside || null), body);
  }

  /** A date range, as presets and two typed dates. */
  var RANGES;
  Text.later(function () {
    RANGES = [
    { value: '', label: t('admin.any_time') },
    { value: '1d', label: 'Last 24 hours' },
    { value: '7d', label: 'Last 7 days' },
    { value: '30d', label: 'Last 30 days' },
    { value: 'custom', label: t('admin.between_dates') }
  ];
  });

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
      field(prefix + '.from', { id: prefix + '-from', class: 'is-date', placeholder: t('admin.from_yyyy_mm_dd'),
        'data-live': live, 'aria-label': t('admin.from_date') }),
      h('span.range-sep', 'to'),
      field(prefix + '.to', { id: prefix + '-to', class: 'is-date', placeholder: t('admin.to_yyyy_mm_dd'),
        'data-live': live, 'aria-label': t('admin.to_date') }));
  }

  /* ---------- the frame: badges, banner, navigation -------------------- */

  function drawChrome() {
    var version = byId('version');
    if (version) version.textContent = S.access.version ? 'v' + S.access.version : '';
    setHtml(byId('badges'), frag(
      canWrite()
        ? h('span.badge.is-write', { title: t('admin.you_can_change_things_here') }, icon('pen'), t('admin.can_change'))
        : canModerate()
          ? h('span.badge.is-moderator', { title: whyNoWrite() }, icon('gavel'), t('admin.moderator'))
          : h('span.badge.is-read', { title: whyNoWrite() }, icon('eye'), t('admin.read_only')),
      canIdentify()
        ? h('span.badge.is-identity', { title: t('admin.you_see_who_is_behind_anonymous') },
          icon('user-secret'), t('admin.sees_identities'))
        : h('span.badge', { title: t('admin.anonymous_parties_show_as_anonymous_and') },
          icon('mask'), t('admin.identities_hidden'))));
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
      if (lbl) lbl.textContent = current ? current.label : t('admin.sections');
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
      'data-act': 'section', 'data-section': g.logs[0], title: t('admin.records_logs') + g.logs[1] },
      icon('list-ul'), h('span.lbl', g.logs[1] + ' \u25b8')) : null,
      g && g.list ? h('button.sub-btn.is-link', { id: 'nav-' + g.list[0].replace(':', '-'), type: 'button',
        'data-act': 'section', 'data-section': g.list[0], title: t('admin.contracts_list_title', g.list[1]) },
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
        title: t('admin.this_screens_settings_here') }, icon('gear'), ' ', S.gearOpen === S.section
        ? t('admin.hide_its_settings') : t('admin.settings_for_this_screen'))) : null) : null));
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
    return String(p.name || t('admin.no_name_on_record'))
      + (p.online ? t('admin.in_city') + String(p.server) + ')' : ' (offline)');
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
          title: left <= 0 ? t('admin.the_lookup_ran_out_look_them') : t('admin.open_their_card') },
          icon('user'), h('span.lbl', t('admin.player_x', String((S.players.data.player || {}).name || t('admin.no_name_on_record')))),
          h('span.ctx-left', left <= 0 ? t('admin.look_up_again') : t('admin.n_min', left))),
        h('button.ctx-x', { type: 'button', 'data-act': 'ctx-player-clear', 'aria-label': t('admin.clear_the_player'),
          title: t('admin.clear_the_player') }, icon('xmark'), h('span.lbl', t('admin.clear')))));
    }
    if (S.ctx.contract) {
      parts.push(h('span.ctx-chip',
        h('button.ctx-open', { type: 'button', 'data-act': 'ctx-contract', title: t('admin.open_the_contract') },
          icon('file-contract'), h('span.lbl', t('admin.contract_x', S.ctx.contract))),
        h('button.ctx-x', { type: 'button', 'data-act': 'ctx-contract-clear', 'aria-label': t('admin.clear_the_contract'),
          title: t('admin.clear_the_contract') }, icon('xmark'), h('span.lbl', t('admin.clear')))));
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
        t('admin.still_recovering_from_the_restart_everything')
        + t('admin.timer_refresh_wait_until_it_finishes'))));
    } else if (S.recovery === 'recovery_failed') {
      banner.hidden = false;
      banner.className = 'notice banner';
      setHtml(banner, frag(icon('triangle-exclamation'), h('span',
        t('admin.recovery_failed_at_the_last_start_2')
        + t('admin.can_be_voided_settled_resolved_or')
        + t('admin.is_fixed_flushing_the_log_still'))));
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
    setCount('count-home', reviews + stuck + alerts, t('admin.waiting_in_the_inbox_reviews_money'));
    setCount('count-inbox', reviews + stuck + alerts, t('admin.waiting_in_the_inbox'));
    setCount('count-reviews', reviews, t('admin.open_in_the_review_queue'));
    setCount('count-stuck', stuck, t('admin.escrow_line_left_for_you_to'));
    setCount('count-ialerts', alerts, t('admin.open_alerts_not_acknowledged_yet'));
    setCount('count-rules', changed, t('admin.setting_changed_from_the_panel'));
    setCount('count-settings', changed, t('admin.setting_changed_from_the_panel'));
    setCount('count-logs', alerts, t('admin.open_alerts_not_acknowledged_yet'));
    setCount('count-alerts', alerts, t('admin.open_alerts_not_acknowledged_yet'));
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
    return t('admin.updated_refreshes_every', S.overviewAt ? when(S.overviewAt).slice(11) : '\u2014',
      Math.round(refreshMs() / 1000));
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
      h('dt', t('admin.cash')), h('dd.figure', money(b.cash)),
      h('dt', t('admin.bank')), h('dd.figure', money(b.bank)),
      h('dt', t('admin.dirty_money_2')), h('dd.figure', money(b.dirty)),
      h('dt', t('admin.items')), h('dd', num(b.items)),
      h('dt', t('admin.weapons')), h('dd', num(b.weapons)),
      h('dt', t('admin.escrow_lines')), h('dd', num(b.lines)));
  }

  var WHY_SHORT;
  Text.later(function () {
    WHY_SHORT = {
    interrupted: t('admin.stopped_while_being_given'), unknown: t('admin.arrival_unknown'), raised: t('admin.raised_nothing_arrived'),
    stalled: t('admin.stopped_part_way'), unqueued: t('admin.in_no_retry_queue'), stalled_claim: t('admin.stalled_claim'),
    stopped: t('admin.stopped_by_a_raise'), releasing: t('admin.left_mid_release'), ending_unfinished: t('admin.ending_unfinished'),
    orphan: t('admin.contract_never_stored'), never_given_release: t('admin.left_mid_release_never_given'),
    owed_to_nobody: t('admin.owed_to_nobody'), owed_to_unchecked: t('admin.owed_to_an_id_not_checked')
  };
  });

  /** Why Stuck escrow lists nothing, from where recovery stands. After a
      recovery that failed, "while the server is recovering" told staff to
      wait for something that never finishes. */
  function notListed(recovery) {
    if (recovery === 'recovery_failed') {
      return t('admin.not_listed_recovery_failed_at_the')
        + t('admin.the_console_is_fixed');
    }
    return t('admin.not_listed_while_the_server_is');
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
      h('p.sub', t('admin.waiting_for_you')),
      h('div.chips',
        h('button.chip.is-link', { type: 'button', 'data-act': 'ib-go', 'data-value': 'reviews' },
          t('admin.needs_review') + num(reviewsOpen)),
        h('button.chip.is-link', { type: 'button', 'data-act': 'ib-go', 'data-value': 'stuck' },
          t('admin.money_waiting') + num(forYou)),
        h('button.chip.is-link', { type: 'button', 'data-act': 'ib-go', 'data-value': 'alerts' },
          t('admin.alerts_n', num(alertsOpen)))),
      !o.stuck ? h('p.note', notListed(o.recovery))
        : o.stuck.error ? h('p.note.is-error', t('admin.money_waiting_could_not_be_read'))
          : listed > forYou ? h('p.note', tn('admin.more_lines_listed', listed - forYou, num(listed - forYou))) : null);
  }

  function overviewBody() {
    var o = S.overview;
    if (!o) return S.overviewError ? empty(S.overviewError) : loading(t('admin.reading_the_overview'));
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
        tile(t('admin.inbox'), inboxCounts(o)),
        tile(t('admin.quick_actions'), h('div.btn-row.quick',
          btn('.is-small', 'section', { 'data-section': 'players' }, t('admin.find_a_player'), 'magnifying-glass'),
          btn('.is-small', 'section', { 'data-section': 'contracts' }, t('admin.contracts'), 'file-contract'),
          btn('.is-small', 'section', { 'data-section': 'contracts:bytarget' }, t('admin.live_by_target'), 'crosshairs'),
          btn('.is-small', 'section', { 'data-section': 'announce' }, t('admin.announce'), 'bullhorn'),
          btn('.is-small', 'section', { 'data-section': 'rules' }, t('admin.game_rules'), 'scale-balanced'))),
        tile(t('admin.health'), frag(
          h('p.big' + (o.recovery !== 'ready' || problems ? '.is-warn' : '') + '.is-word',
            o.recovery === 'recovering' ? t('admin.recovering') : o.recovery !== 'ready' ? t('admin.recovery_failed')
              : problems ? tn('admin.problems_count', problems, num(problems)) : t('admin.all_well')),
          h('dl.facts',
            h('dt', t('admin.recovery')), h('dd', o.recovery === 'ready' ? 'finished'
              : o.recovery === 'recovering' ? t('admin.still_running') : 'FAILED'),
            h('dt', t('admin.storage')), h('dd', String(o.storage || '—')),
            h('dt', t('admin.setup_problems')), h('dd', canWrite() ? num(warnings.length) : '—'),
            h('dt', t('admin.changed_here')), h('dd', Number(o.overrides) > 0 ? h('button.link', { type: 'button',
              'data-act': 'section', 'data-section': 'changed' }, tn('admin.settings_count', Number(o.overrides),
              num(o.overrides))) : 'none')),
          o.storage === 'memory' ? h('span.chip.is-warn', { title: t('admin.contracts_escrow_review_items_and_settings')
            + t('admin.gone_at_the_next_start') }, t('admin.memory_mode_nothing_is_kept_across')) : null,
          canDevelop() ? h('div.btn-row', btn('.is-small.ghost', 'section', { 'data-section': 'health' },
            t('admin.server_health'), 'heart-pulse')) : null),
          o.recovery !== 'ready' || problems ? '.is-warn' : ''),
        tile(t('admin.contracts'), frag(
          h('p.big', num(contracts.total)),
          h('div.chips', states.filter(function (s) { return byState[s]; }).map(function (s) {
            return h('button.chip.is-link', { type: 'button', 'data-act': 'ov-state', 'data-value': s },
              (STATE_LABEL[s] || s) + ' ' + num(byState[s]));
          })),
          h('p.sub', t('admin.new_ones_placed_under') + (RULE_LABEL[o.fulfilment] || String(o.fulfilment || '—'))))),
        tile(t('admin.operatives'), frag(
          h('p.big', num(hitmen.operatives)),
          h('p.sub', tn('admin.on_contracts_now_holding_n', Number(hitmen.contracts), num(hitmen.contracts))))),
        tile(t('admin.held_in_escrow'), moneyRows(o.held)),
        tile(t('admin.owed_to_players'), frag(moneyRows(owed),
          h('p.sub', tn('admin.players_count', Number(owed.players), num(owed.players)) + ' · '
            + tn('admin.lines_in_a_retry_queue', Number(owed.queued), num(owed.queued))))),
        tile(t('admin.measures_on_players'), frag(
          h('dl.facts',
            h('dt', t('admin.frozen')), h('dd', h('span' + (held ? '.is-warn' : ''), { id: 'ov-frozen' },
              frozenUnknown ? t('admin.unknown') : num(frozenCount))),
            h('dt', t('admin.suspended')), h('dd', measures.suspend == null ? '—' : num(measures.suspend)),
            h('dt', t('admin.protected')), h('dd', measures.protect == null ? '—' : num(measures.protect)),
            h('dt', t('admin.own_target_limits')), h('dd', measures.limit == null ? '—' : num(measures.limit))),
          frozenUnknown ? h('p.sub', t('admin.the_stores_freezes_could_not_be')
            + t('admin.they_can_be')) : null,
          h('div.btn-row',
            btn('.is-small', 'ms-open', { 'data-value': '' }, t('admin.all_measures'), 'arrow-right'),
            btn('.is-small.ghost', 'ms-open', { 'data-value': 'freeze' }, t('admin.frozen'), 'arrow-right'),
            btn('.is-small.ghost', 'ms-open', { 'data-value': 'suspend' }, t('admin.suspended'), 'arrow-right'),
            btn('.is-small.ghost', 'ms-open', { 'data-value': 'protect' }, t('admin.protected'), 'arrow-right'))),
          held ? '.is-warn' : '')),
      warnings.length && canWrite() ? card(t('admin.setup_problems_2') + num(warnings.length) + ')', frag(
        h('ul.warnings', warnings.map(function (line) { return h('li', String(line)); })),
        S.tools.diag && S.section === 'overview' ? linesBox(S.tools.diag.lines, S.tools.diag.later) : null),
        '.is-warn', btn('.is-small', 'ov-diag', {}, t('admin.run_the_diagnosis'), 'stethoscope')) : null,
      h('p.foot', icon('rotate'),
        h('span', { id: 'ov-at' }, overviewStamp()),
        S.overviewError ? h('span.is-error', t('admin.last_refresh') + S.overviewError) : null,
        ' ', btn('.is-small.ghost', 'ov-refresh', {}, t('admin.refresh_now'))));
  }

  SHELL.overview = function () {
    return h('section.view', h('div.stack', { id: 'ov' }, overviewBody()));
  };
  LOAD.overview = function () { loadOverview(false); };

  /* ---- Developer > Health: what the server itself is doing ---- */

  function healthBody() {
    var o = S.overview;
    if (!o) return S.overviewError ? empty(S.overviewError) : loading(t('admin.reading_the_overview'));
    var photos = o.photos;
    var slowest = asList(o.slowest);
    var slowMs = Number(o.slowMs) || 0;
    var tv = S.tools;
    return frag(
      S.access.developerHint ? h('p.hint.is-note', String(S.access.developerHint)) : null,
      h('div.tiles',
        tile(t('admin.server'), h('dl.facts',
          h('dt', t('admin.storage')), h('dd', String(o.storage || '—'), o.storage === 'memory'
            ? h('span.chip.is-warn', { title: t('admin.contracts_escrow_review_items_and_settings_2')
              + t('admin.the_next_start') }, t('admin.nothing_is_kept_across_a_restart')) : null),
          h('dt', t('admin.new_contracts')), h('dd', RULE_LABEL[o.fulfilment] || String(o.fulfilment || '—')),
          h('dt', t('admin.kill_photos')), h('dd', o.killPhotos === false ? t('admin.off')
            : t('admin.on_kept_on') + String(o.photoStorage || '—')),
          h('dt', t('admin.recovery')), h('dd', o.recovery === 'ready' ? t('admin.finished')
            : o.recovery === 'recovering' ? t('admin.still_running_2') : 'FAILED'),
          h('dt', t('admin.settings_changed_here')), h('dd', h('button.link', { type: 'button', 'data-act': 'section',
            'data-section': 'changed' }, (Number(o.overrides) > 0 ? t('admin.n_changed', num(o.overrides))
              : t('admin.none_changed')) + t('admin.open_game_rules')),
            Number(o.notApplied) > 0 ? h('span.chip.is-error', num(o.notApplied) + t('admin.not_applied')) : null),
          h('dt', t('admin.log_rows_queued')), h('dd', num(o.auditQueued)))),
        tile(t('admin.kill_photos'), photos ? h('dl.facts',
          h('dt', t('admin.waiting')), h('dd', num(photos.waiting && photos.waiting.count) + ' · '
            + bytes(photos.waiting && photos.waiting.bytes)),
          h('dt', t('admin.kept_in_the_app')), h('dd', num(photos.kept && photos.kept.count) + ' · '
            + bytes(photos.kept && photos.kept.bytes)),
          h('dt', t('admin.served_to_photos')), h('dd', num(photos.served && photos.served.count) + ' · '
            + bytes(photos.served && photos.served.bytes)))
          : h('p.note', t('admin.the_photo_store_did_not_answer')))),
      card(t('admin.slowest_maintenance_jobs'), slowest.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.job')), h('th.num', t('admin.worst')), h('th.num', t('admin.average')),
          h('th.num', t('admin.last')), h('th.num', t('admin.runs')))),
        h('tbody', slowest.map(function (job) {
          var slow = slowMs > 0 && Number(job.max) > slowMs;
          return h('tr' + (slow ? '.is-warn' : ''), h('td.mono.wrap', String(job.name)),
            h('td.num', ms(job.max)), h('td.num', ms(job.avg)), h('td.num', ms(job.last)),
            h('td.num', num(job.runs)));
        })))) : empty(t('admin.no_job_has_run_yet')),
        '', slowMs > 0 ? h('span.sub', t('admin.over_ms_is_marked', slowMs)) : null),
      card(t('admin.what_the_diagnosis_says'), asList(o.warnings).length
        ? h('ul.warnings', asList(o.warnings).map(function (line) { return h('li', String(line)); }))
        : empty(t('admin.nothing_that_wants_doing'))),
      card(t('admin.diagnosis'), frag(
        h('p.about', t('admin.why_the_app_is_not_showing')
          + t('admin.attention_and_what_the_console_said')
          + t('admin.it_from_a_players_card_in')),
        h('div.btn-row', field('tl.subject', { class: 'is-short', placeholder: t('admin.player_id'), inputmode: 'numeric',
          'data-enter': 'tl-diag', 'aria-label': t('admin.player_id_optional') }),
          btn('.primary', 'tl-diag', {}, t('admin.run_the_diagnosis'), 'stethoscope'),
          btn('', 'tl-config', {}, t('admin.check_the_config'), 'list-check')),
        tv.diag && tv.diag.error ? answerBox({ ok: false, text: tv.diag.error }) : null,
        tv.diag ? linesBox(tv.diag.lines, tv.diag.later) : null)),
      h('p.foot', icon('rotate'), h('span', { id: 'ov-at' }, overviewStamp()),
        ' ', btn('.is-small.ghost', 'ov-refresh', {}, t('admin.refresh_now'))));
  }
  SHELL.health = function () { return h('section.view', h('div.stack', { id: 'dg' }, healthBody())); };
  LOAD.health = function () { loadOverview(false); };

  /* ---- contracts ---- */

  Text.later(function () {
    DD['ct-state'] = {
    prefix: t('admin.state'),
    options: function () {
      return [{ value: 'live', label: t('admin.live_only') }, { value: '', label: t('admin.any') }].concat(STATE_ORDER.map(function (s) {
        return { value: s, label: STATE_LABEL[s] };
      }));
    },
    value: function () { return S.contracts.state; },
    pick: function (v) { S.contracts.state = v; S.contracts.page = 1; loadContracts(); }
  };
  });
  Text.later(function () {
    DD['ct-as'] = {
    prefix: t('admin.their_part'),
    options: function () {
      return [{ value: '', label: t('admin.any') }, { value: 'target', label: PART_LABEL.target },
              { value: 'client', label: PART_LABEL.client }, { value: 'hitman', label: PART_LABEL.hitman }];
    },
    value: function () { return S.contracts.as; },
    pick: function (v) { S.contracts.as = v; S.contracts.page = 1; loadContracts(); }
  };
  });
  Text.later(function () {
    DD['ct-rule'] = {
    prefix: t('admin.rule'),
    options: function () {
      return [{ value: '', label: t('admin.any') }, { value: 'alive', label: RULE_LABEL.alive },
              { value: 'either', label: RULE_LABEL.either }];
    },
    value: function () { return S.contracts.rule; },
    pick: function (v) { S.contracts.rule = v; S.contracts.page = 1; loadContracts(); }
  };
  });
  Text.later(function () {
    DD['ct-range'] = {
    prefix: t('admin.placed'),
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
  });

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

  var PART_LABEL;
  Text.later(function () {
    PART_LABEL = { target: t('admin.target'), client: t('admin.placer'), hitman: t('admin.hitman') };
  });

  function contractRows() {
    var d = S.contracts.data;
    if (!d) return loading(t('admin.reading_contracts'));
    var rows = asList(d.rows);
    if (!rows.length) return empty(S.contracts.byTarget ? t('admin.no_live_contract_matches') : t('admin.no_contract_matches'));
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
          String(row.target || '—'), h('span.sub', ' · ' + num(row.onTarget) + t('admin.live_on_them')))));
      }
      var id = String(row.id);
      // Relative, to scan down a page of them; the date itself on hover.
      var endAt = row.resolved_at || row.deadline_at;
      var ended = row.resolved_at
        ? String(row.resolution || STATE_LABEL[row.state] || 'ended') + ' · ' + ago(row.resolved_at)
        : (row.deadline_at ? t('admin.due_x', ago(row.deadline_at)) : '—');
      out.push(h('tr.row', { 'data-act': 'contract', 'data-id': id, tabindex: '0',
        title: t('admin.open_contract') + row.id },
        h('td.mono.nowrap', id), h('td', stateChip(row.state),
          row.frozen ? h('span.chip.is-warn.is-frozen', c.byTarget ? t('admin.on_hold') : t('admin.frozen')) : null),
        person ? h('td', PART_LABEL[row.role] || String(row.role || '—'),
          row.roleAnonymous ? h('span.chip.is-anon', 'anonymous') : null) : null,
        person ? null : h('td.nowrap', RULE_LABEL[row.rule] || String(row.rule || '—')),
        h('td.name', String(row.target || '—')),
        h('td.name', row.anonymous ? h('span.anon', icon('mask'), ' ', String(row.client || t('admin.anonymous')))
          : String(row.client || '—')),
        person ? null : h('td.num', num(row.claimed) + ' / ' + num(row.slots)),
        h('td.nowrap', when(row.created_at)), h('td', { title: endAt ? when(endAt) : null }, ended),
        whoisCol ? h('td', btn('.is-small.ghost', 'whois', { 'data-id': id, 'data-where': 'contracts' },
          t('admin.whois'), 'user-secret')) : null));
      var who = c.whois[id];
      if (who) out.push(h('tr.more', h('td', { colspan: String(cols) }, whoisBody(who))));
    });
    return h('div.table-wrap', h('table.grid.is-rows',
      h('thead', h('tr', h('th', t('admin.contract')), h('th', t('admin.state')), person ? h('th', t('admin.their_part')) : null,
        person ? null : h('th', t('admin.rule')), h('th', t('admin.target')), h('th', t('admin.client')),
        person ? null : h('th.num', t('admin.payouts')), h('th', t('admin.placed')),
        h('th', t('admin.deadline_or_end')), whoisCol ? h('th', '') : null)),
      h('tbody', out)));
  }

  function contractPager() {
    var d = S.contracts.data;
    if (!d) return frag();
    var page = Number(d.page) || 1, pages = Number(d.pages) || 1;
    return frag(
      btn('.is-small', 'ct-page', { 'data-value': String(page - 1), disabled: page <= 1 }, t('admin.previous'), 'chevron-left'),
      h('span.pager-text', t('admin.page_of', page, pages) + ' · '
        + (S.contracts.byTarget ? tn('admin.live_contracts_count', Number(d.total), num(d.total))
          : tn('admin.contracts_count', Number(d.total), num(d.total)))
        + (S.contracts.byTarget ? tn('admin.on_targets', Number(d.targets), num(d.targets)) : '')),
      btn('.is-small', 'ct-page', { 'data-value': String(page + 1), disabled: page >= pages }, t('admin.next'), 'chevron-right'));
  }

  /** Whose contracts the list shows, and their part on them. */
  function contractPerson() {
    var c = S.contracts;
    return h('div.toolbar.ct-person',
      c.person
        ? frag(h('span.chip.is-link.st-chip', icon('user'), ' ', String(c.person.name || t('admin.one_person')),
            h('button.st-chip-x', { type: 'button', 'data-act': 'ct-person-clear', title: t('admin.show_everybodys'),
              'aria-label': t('admin.show_everybodys_contracts') }, icon('xmark'))),
          dropdown('ct-as'))
        : h('label.search', icon('user'),
          field('ct.who', { id: 'ct-who', placeholder: t('admin.one_person_player_id_citizen_id'),
            'data-enter': 'ct-person-set', 'aria-label': t('admin.show_one_persons_contracts') })),
      segmented('ct-bytarget', [{ value: 'list', label: t('admin.newest_first') },
        { value: 'bytarget', label: t('admin.live_by_target_2') }], c.byTarget ? 'bytarget' : 'list'));
  }

  SHELL.contracts = function () {
    return h('section.view',
      h('div.toolbar',
        h('label.search', icon('magnifying-glass'),
          field('ct.q', { id: 'ct-q', placeholder: S.contracts.byTarget ? t('admin.target_name_or_citizen_id')
            : t('admin.contract_id_citizen_id_or_name'),
            'data-live': 'ct-search', 'data-enter': 'ct-search-now', 'aria-label': t('admin.search_contracts') })),
        dropdown('ct-state'), dropdown('ct-rule'), dropdown('ct-range'),
        rangeInputs('ct', S.contracts.range, 'ct-search'),
        btn('.ghost', 'ct-clear', {}, t('admin.clear'), 'eraser')),
      contractPerson(),
      h('p.hint', canIdentify()
        ? t('admin.you_see_who_is_behind_anonymous_2')
        : t('admin.anonymous_placers_and_operatives_show_as')
          + t('admin.finds_a_contract_through_a_party')),
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
  var WHY_LONG;
  Text.later(function () {
    WHY_LONG = {
    interrupted: t('admin.the_server_stopped_while_it_was'),
    unknown: t('admin.raised_and_what_arrived_could_not'),
    stalled: t('admin.giving_it_stopped_part_way_and'),
    unqueued: t('admin.owed_and_in_no_retry_queue'),
    stalled_claim: t('admin.stalled_claim_the_claim_that_owed'),
    stopped: t('admin.a_raise_stopped_it_while_it'),
    releasing: t('admin.left_mid_release_by_a_call'),
    never_given_release: t('admin.left_mid_release_by_a_call_2'),
    ending_unfinished: t('admin.ending_unfinished_it_settles_itself_within')
  };
  });
  var NEVER_GIVEN = { unqueued: true, stalled_claim: true };

  /** Whether nothing of a line was given, so only Pay settles it: one the
      server says so of, or one left mid-release before it named anyone
      that is owed to somebody. */
  function neverGiven(entry) {
    return !!NEVER_GIVEN[entry.why] || (entry.why === 'never_given_release' && !!entry.owed);
  }
  var SETTLES;
  Text.later(function () {
    SETTLES = {
    queued: t('admin.queued_for_them_since_nothing_to'),
    return_owner: t('admin.does_not_say_whose_it_is'),
    pay_or_return: t('admin.pay_to_them_or_return_to'),
    'return': t('admin.names_nobody_to_pay_only_a')
  };
  });

  function stuckWhy(entry) {
    if (entry.unfinished) return WHY_LONG.ending_unfinished;
    if (entry.orphan) return t('admin.escrow_of_a_contract_never_stored');
    if (entry.why === 'owed_to_nobody') {
      return t('admin.owed_and_queued_to_a_citizen')
        + t('admin.to_the_citizen_id_it_should');
    }
    if (entry.why === 'owed_to_unchecked') {
      return t('admin.owed_and_queued_to_a_citizen_2')
        + t('admin.so_it_stays_queued_for_them');
    }
    if (entry.raised !== undefined && entry.raised !== null) {
      var text = entry.why === 'raised' ? t('admin.raised_times_with_nothing_arriving', num(entry.raised))
        : (WHY_LONG[entry.why] || t('admin.why_is_no_longer_in_the'));
      if (Number(entry.arrived) > 0) text += '; ' + num(entry.arrived) + t('admin.of_it_arrived');
      if (entry.paidAs) text += t('admin.paid_as') + String(entry.paidAs) + t('admin.so_check_that_not_their_account');
      if (entry.why === 'never_given_release' && !entry.owed) {
        text += t('admin.owed_to_nobody_so_return_puts')
          + t('admin.is_live_and_hands_it_back');
      }
      return text;
    }
    return t('admin.was_mid_release_at_a_shutdown') + (SETTLES[entry.settles] || SETTLES['return']);
  }

  var SETTLE_LABEL;
  Text.later(function () {
    SETTLE_LABEL = {
    pay: [t('admin.pay'), t('admin.click_again_to_pay')],
    pay_amount: [t('admin.pay_amount'), t('admin.click_again_to_pay_it')],
    'return': [t('admin.return'), t('admin.click_again_to_return')],
    return_owner: [t('admin.return_to'), t('admin.click_again_to_return')],
    delivered: [t('admin.delivered'), t('admin.click_again_delivered')]
  };
  });

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
        return h('span.inline-form', field('dr.amount.' + line, { class: 'is-short', placeholder: t('admin.amount'),
          inputmode: 'numeric', 'aria-label': t('admin.amount_to_pay_for_line') + line,
          disabled: !writesOpen() }), button);
      }
      if (how === 'return_owner') {
        return h('span.inline-form', field('dr.owner.' + line, { class: 'is-mid', placeholder: t('admin.citizen_id'),
          'aria-label': t('admin.citizen_id_to_return_line_to', line), disabled: !writesOpen() }), button);
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
        entry.intended ? h('span.sub', t('admin.owed_to') + entry.intended) : null,
        entry.at ? h('span.sub', ' · ' + when(entry.at)) : null,
        where === 'stuck' && entry.contract
          ? h('span.sub', t('admin.contract_2'), h('button.link.mono', { type: 'button', 'data-act': 'contract',
            'data-id': String(entry.contract), title: t('admin.open_contract') + entry.contract }, String(entry.contract)))
          : null),
      h('p.stuck-why', stuckWhy(entry)),
      unknownArrival ? h('p.note.is-warn', t('admin.arrival_unknown_check_what_they_received')
        + t('admin.with_pay_amount_or_delivered')) : null,
      neverGiven(entry) ? h('p.note', t('admin.never_given_only_pay_settles_it')) : null,
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
    if (!keys.length) return empty(t('admin.no_escrow_is_recorded_for_this'));
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
      var title = key === 'other' ? t('admin.stakes_and_owed_lines') : t('admin.payout_n', key);
      var status = key === 'other' ? '' : (Number(key) <= claimed ? 'claimed' : t('admin.to_claim'));
      return h('div.slot', h('p.slot-title', title, status ? h('span.chip', status) : null),
        h('p.slot-body', Object.keys(totals).sort().map(function (portion) {
          return h('span.slot-part', portion + ' ' + money(totals[portion]));
        }), goods.length ? h('span.slot-part', goods.join(', ')) : null));
    }));
  }

  /* The drawer's tabs, safest first; only the one open is drawn. */
  var DRAWER_TABS;
  Text.later(function () {
    DRAWER_TABS = [
    { id: 'summary', label: t('admin.summary') }, { id: 'money', label: t('admin.money') }, { id: 'people', label: t('admin.people') },
    { id: 'notes', label: t('admin.notes_text') }, { id: 'record', label: t('admin.record') }
  ];
  });

  function drawerBody() {
    var d = S.drawer.data;
    var id = S.drawer.id;
    var c0 = d && d.contract ? d.contract : null;
    var canVoid = !!(d && d.canVoid && !(c0 && c0.neverStored));
    var head = h('header.drawer-head',
      h('div.drawer-title', h('h2', 'Contract ', h('span.mono', id)),
        c0 ? stateChip(c0.state) : null,
        c0 ? h('span.chip', RULE_LABEL[c0.rule] || String(c0.rule || '')) : null,
        d && d.frozen ? h('span.chip.is-warn.is-frozen', { title: t('admin.on_hold_frozen_by_staff')
          + asList(d.frozen).join(', ') + ')' }, t('admin.frozen')) : null),
      h('div.drawer-tools',
        canVoid ? btn('.ghost.is-small', 'dr-more', { 'aria-expanded': S.drawer.more ? 'true' : 'false',
          title: t('admin.more_void_this_contract') }, S.drawer.more ? t('admin.less') : t('admin.more'), 'ellipsis') : null,
        btn('.ghost', 'drawer-close', { 'aria-label': t('admin.close_the_contract') }, t('admin.close'), 'xmark')));
    if (!d) {
      return frag(head, answerBox(S.drawer.answer), S.drawer.answer ? null : loading(t('admin.reading_the_contract')));
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
    var actions = stub ? h('div.drawer-actions', h('p.note', t('admin.never_stored_escrow_under_this_id')
        + t('admin.contract_record_so_nothing_here_names')
        + t('admin.it_to_the_citizen_id_of'))) : null;

    var stuckPart = null;
    if (stuck === null) {
      stuckPart = card(t('admin.waiting_for_staff'), h('p.note', notListed(S.recovery)));
    } else if (stuck.length) {
      stuckPart = card(t('admin.waiting_for_staff'), h('ul.stuck', stuck.map(function (entry) {
        return stuckItem(entry, 'drawer');
      })), '.is-warn');
    }

    var whois = S.drawer.whois ? card(t('admin.who_is_behind_it'), whoisBody(S.drawer.whois), '.is-identity') : null;
    var deadlinePart = stub ? null : card(t('admin.deadline'), deadlineBody(d.deadline));

    /* Look up / Freeze beside each party it names: the Players view on
       them, where Freeze is. Named by the contract and the role, which the
       server resolves (playerSubject), so no citizen id is needed here. Not
       for a party who is anonymous on it to staff without IdentityAce. */
    function partyButton(role, opId) {
      return btn('.is-small.ghost', 'party-lookup', { 'data-subject': 'contract:' + id + ':' + role
        + (opId ? ':' + opId : '') }, t('admin.look_up_freeze'), 'magnifying-glass');
    }
    var clientHidden = c.anonymous && !canIdentify();
    var terms = h('dl.facts.is-terms',
      h('dt', t('admin.mode')), h('dd', MODE_LABEL[c.mode] || String(c.mode || '—')),
      h('dt', t('admin.completes_by')), h('dd', RULE_LABEL[c.rule] || String(c.rule || '—')),
      h('dt', t('admin.reason')), h('dd.text', String(c.reason || '—')),
      h('dt', t('admin.client')), h('dd', personCell(c.client), c.anonymous ? h('span.chip.is-anon', 'anonymous') : null,
        clientHidden ? null : partyButton('client')),
      h('dt', t('admin.target')), h('dd', personCell(c.target), c.target_protected ? h('span.chip.is-warn', t('admin.law_enforcement')) : null,
        partyButton('target')),
      h('dt', t('admin.placed')), h('dd', when(c.created_at)),
      h('dt', t('admin.deadline')), h('dd', c.deadline_at ? when(c.deadline_at) + ' (' + ago(c.deadline_at) + ')' : '—'),
      h('dt', t('admin.expires')), h('dd', when(c.expires_at)),
      c.paused_since ? h('dt', t('admin.paused_since')) : null, c.paused_since ? h('dd', when(c.paused_since)) : null,
      h('dt', t('admin.ended')), h('dd', c.resolved_at ? String(c.resolution || '') + ' ' + when(c.resolved_at) : t('admin.not_yet')),
      h('dt', t('admin.payouts')), h('dd', t('admin.claimed_of', num(c.claimed), num(c.slots))
        + (c.next_slot ? t('admin.next_2') + c.next_slot : '')),
      h('dt', t('admin.bonus')), h('dd', num(c.bonus_percent) + '%'),
      h('dt', t('admin.stake')), h('dd', money(c.penalty_amount)),
      h('dt', t('admin.buyout_price')), h('dd', money(c.bailout_amount) + (c.buyout_queued ? t('admin.a_buyout_is_queued') : '')),
      // The handover's meeting point: where the client stood, sent to staff
      // with the identity ACE alone, as who they are is.
      c.meeting ? h('dt', t('admin.meeting_point')) : null,
      c.meeting ? h('dd', 'x ' + String(Number(c.meeting.x)) + ', y '
        + String(Number(c.meeting.y))) : null);

    var escrowCard = card(t('admin.escrow_lines'), escrow.length ? h('div.table-wrap', h('table.grid',
      h('thead', h('tr', h('th', t('admin.line')), h('th', t('admin.payout')), h('th', t('admin.holds')),
        h('th', t('admin.state')), h('th', t('admin.owed_to_2')), h('th.num', t('admin.arrived')), h('th.num', t('admin.still_owed')))),
      h('tbody', escrow.map(function (line) {
        return h('tr' + (line.parked ? '.is-warn' : ''),
          h('td.mono.wrap', String(line.id)),
          h('td', (line.slot == null ? '' : line.slot + ' · ') + String(line.portion || '—')),
          h('td', holds(line)),
          h('td', String(line.state || '—'), line.parked ? h('span.chip.is-warn', t('admin.left_for_staff')) : null,
            Number(line.raised) > 0 ? h('span.chip', t('admin.raised_n', num(line.raised))) : null,
            line.settled_by_staff ? h('span.chip', t('admin.staff_x', line.settled_by_staff)) : null),
          h('td.name', String(line.owed_to || line.releasing_to || line.settled_to || '—')),
          h('td.num', line.arrived == null ? '—' : num(line.arrived)),
          h('td.num', MONEY[line.source] ? money(line.owes) : num(line.owes)));
      })))) : empty(t('admin.no_escrow_lines')));

    var operatives = card(t('admin.operatives'), hitmen.length ? h('div.table-wrap', h('table.grid',
      h('thead', h('tr', h('th', t('admin.alias')), h('th', t('admin.name')), canIdentify() ? h('th', t('admin.citizen_id')) : null,
        h('th', t('admin.state')), h('th', t('admin.accepted')), h('th', t('admin.left')), h('th.num', t('admin.claims')), h('th.num', t('admin.stake')))),
      h('tbody', hitmen.map(function (m) {
        // Look up / Freeze under the name, where the name may be shown.
        return h('tr', h('td', String(m.alias || '—')),
          h('td.name', m.anonymous && !m.cid ? h('span.anon', icon('mask'), ' ', String(m.name || t('admin.anonymous')))
            : String(m.name || '—'),
            (m.anonymous && !canIdentify()) || m.id == null ? null
              : h('div.party', partyButton('op', String(m.id)))),
          canIdentify() ? h('td.mono', String(m.cid || '—')) : null,
          h('td', String(m.state || '—')), h('td', when(m.accepted_at)), h('td', when(m.left_at)),
          h('td.num', num(m.claims)), h('td.num', money(m.stake)));
      })))) : empty(t('admin.nobody_has_taken_it')));

    var proposals = amendments.length ? card(t('admin.open_proposals'), h('ul.plain', amendments.map(function (a) {
      return h('li', h('b', String(a.kind || 'proposal')), t('admin.by_x', String(a.proposer || '—')),
        a.expires_at ? t('admin.runs_out') + when(a.expires_at) : '',
        a.payload ? h('span.detail', ' ' + detailText(a.payload)) : null);
    }))) : null;

    var staff = d.staff;
    var tab = S.drawer.tab || 'summary';
    if (stub && tab !== 'money' && tab !== 'record') tab = 'money';
    var waiting = stuck ? stuck.length : 0;
    var tabs = h('div.drawer-tabs', { role: 'tablist' }, DRAWER_TABS.filter(function (tv) {
      return !stub || tv.id === 'money' || tv.id === 'record';
    }).map(function (tv) {
      var on = tv.id === tab;
      return h('button.drawer-tab' + (on ? '.is-on' : ''), { type: 'button', role: 'tab', 'data-act': 'dr-tab',
        'data-value': tv.id, 'aria-selected': on ? 'true' : 'false' }, h('span.lbl', tv.label),
        tv.id === 'money' && waiting > 0 ? h('span.nav-count.is-warn', { title: num(waiting)
          + t('admin.line_waiting_for_staff') }, num(waiting)) : null);
    }));

    var voidForm = canVoid ? h('div.drawer-void', { id: 'dr-void' },
      h('div.inline-form.is-wide',
        field('dr.reason', { class: 'is-grow', placeholder: t('admin.reason_for_the_void_kept_in'),
          maxlength: '120', disabled: !modOpen(), 'aria-label': t('admin.reason_for_the_void') }),
        modBtn('.danger', 'void', {}, t('admin.void_contract'), t('admin.click_again_to_void'), 'ban')),
      h('p.note', t('admin.voiding_closes_it_and_refunds_what'))) : null;

    var body;
    if (tab === 'money') {
      body = frag(actions, stuckPart, stub ? null : card(t('admin.payouts'), slotSummary(escrow, c)),
        staff && !stub ? card(t('admin.change_reward'), rewardBody(d), '.ct-reward') : null, escrowCard);
    } else if (tab === 'people') {
      body = frag(
        canIdentify() ? h('div.drawer-actions', btn('.ghost', 'whois', { 'data-id': id }, t('admin.whois'), 'user-secret'))
          : null,
        whois, operatives,
        staff ? card(t('admin.remove_an_operative'), removeBody(d, staff), '.ct-remove') : null,
        staff ? card(t('admin.reassign_to_another_hitman'), reassignBody(d), '.ct-reassign') : null,
        staff ? card(t('admin.as_a_player_sees_it'), playerViewBody(d), '.ct-view') : null);
    } else if (tab === 'notes') {
      body = staff ? frag(card(t('admin.staff_notes'), notesBody(staff), '.ct-notes'),
        card(t('admin.edit_text'), textBody(d, staff), '.ct-text')) : empty(t('admin.staff_notes_and_text_edits_are'));
    } else if (tab === 'record') {
      body = frag(
        staff && !stub ? card(t('admin.export_the_record'), exportBody(), '.ct-export') : null,
        card(t('admin.timeline'), timeline.length ? h('ol.timeline', timeline.map(function (row) {
          return h('li', h('span.time', when(row.ts)), h('span.chip.kind-' + String(row.kind || 'system'), String(row.kind || '')),
            h('b', String(row.action || '')), row.actor ? h('span.sub', ' ' + row.actor) : null,
            h('span.detail', detailText(row.detail)));
        })) : empty(t('admin.the_log_keeps_nothing_for_it'))));
    } else {
      body = frag(
        d.canVoid ? null : h('p.note', t('admin.closed_a_closed_contract_is_never')),
        card(t('admin.terms'), terms), deadlinePart, proposals,
        canVoid && !S.drawer.more ? h('div.btn-row', btn('.is-small.ghost', 'dr-more', {}, t('admin.void_this_contract'),
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
    var tv = Math.max(0, Math.floor(Number(seconds) || 0));
    var hours = Math.floor(tv / 3600), mins = Math.floor((tv % 3600) / 60), secs = tv % 60;
    var out = [];
    if (hours > 0) out.push(t('admin.n_h', hours));
    if (mins > 0 || (hours > 0 && secs > 0)) out.push(t('admin.n_min', hours > 0 ? pad(mins) : String(mins)));
    if (secs > 0 || !out.length) out.push(t('admin.n_s', secs));
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
    if (!minutes) return h('span', t('admin.pick_a_time_or_type_a'));
    var by = minutes * 60;
    var max = Number(info.maxAdjust) || 0;
    if (max && by > max) return h('span.is-warn', t('admin.at_most') + exactSpan(max) + t('admin.either_way'));
    var most = Math.max(0, left - (Number(info.minLeft) || 0));
    return frag(h('span', 'Extend: ', h('b', exactSpan(left + by)), t('admin.left_after')), ' ',
      by > most
        ? h('span', t('admin.shorten_not_by_this_much_at') + exactSpan(info.minLeft) + t('admin.must_remain_so_the_most_is')
          + exactSpan(most) + '.')
        : h('span', 'Shorten: ', h('b', exactSpan(left - by)), t('admin.left_after')));
  }

  function deadlineBody(info) {
    if (!info) return h('p.note', t('admin.not_sent_by_this_server'));
    var left = deadlineLeft(info);
    var now = h('p', t('admin.time_left_now'), h('b', { id: 'dr-dl-left' }, exactSpan(left)),
      info.stopped ? t('admin.its_clock_is_stopped') : '');
    if (!info.adjustable) {
      return frag(now, h('p.note', t('admin.only_a_live_contract_active_or')));
    }
    var open = modOpen();
    var current = deadlineMinutes();
    return frag(now,
      h('div.inline-form.is-wide.dl-picks',
        segmented('dl-pick', DEADLINE_PICKS.map(function (m) {
          return { value: m, label: m < 60 ? t('admin.n_min', m) : t('admin.n_h', m / 60), disabled: !open,
                   title: open ? null : whyNoMod() };
        }), current == null ? '' : current),
        field('dr.dl.min', { class: 'is-short', placeholder: t('admin.minutes'), inputmode: 'numeric', maxlength: '5',
          'data-live': 'dl-preview', disabled: !open, 'aria-label': t('admin.minutes_to_move_the_deadline_by') })),
      h('p.note', { id: 'dr-dl-preview', 'aria-live': 'polite' }, deadlinePreview()),
      h('div.inline-form.is-wide',
        field('dr.dl.reason', { class: 'is-grow', placeholder: t('admin.reason_required_kept_in_the_log'),
          maxlength: '120', disabled: !open, 'aria-label': t('admin.reason_for_moving_the_deadline') }),
        modBtn('', 'dl-extend', {}, t('admin.extend'), t('admin.click_again_to_extend'), 'plus'),
        modBtn('', 'dl-shorten', {}, t('admin.shorten'), t('admin.click_again_to_shorten'), 'minus')));
  }

  function whoisBody(who) {
    var creator = who.creator || {}, target = who.target || {};
    return frag(h('dl.facts',
      h('dt', t('admin.client')), h('dd', String(creator.name || '—'), creator.cid ? h('span.cid', String(creator.cid)) : null,
        creator.anonymous ? h('span.chip.is-anon', t('admin.paid_to_stay_anonymous')) : null),
      h('dt', t('admin.target')), h('dd', String(target.name || '—'), target.cid ? h('span.cid', String(target.cid)) : null)),
      asList(who.hitmen).length ? h('ul.plain', asList(who.hitmen).map(function (m) {
        return h('li', h('b', String(m.alias || '—')), ' ' + String(m.name || '—') + ' ',
          m.cid ? h('span.cid', String(m.cid)) : null, ' · ' + String(m.state || ''),
          m.anonymous ? h('span.chip.is-anon', 'anonymous') : null);
      })) : h('p.note', t('admin.no_operatives')));
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
    if (!d) return S.stuck.error ? empty(S.stuck.error) : loading(t('admin.reading_what_waits_for_staff'));
    if (d.lines === undefined || d.lines === null) return h('p.note', notListed(d.recovery));
    var lines = asList(d.lines);
    if (!lines.length) return empty(t('admin.no_escrow_line_is_waiting_for'));
    var forYou = lines.filter(function (entry) { return asList(entry.actions).length > 0; }).length;
    return frag(
      h('p.hint', num(forYou) + t('admin.left_for_you_to_settle_of') + num(lines.length) + t('admin.listed_one_queued')
        + t('admin.since_for_whom_it_is_owed')
        + t('admin.check_what_the_player_has_before')),
      card(t('admin.waiting_for_staff'), h('ul.stuck', lines.map(function (entry) {
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

  var INBOX_FILTERS;
  Text.later(function () {
    INBOX_FILTERS = [
    { value: 'all', label: t('admin.everything'), count: 'count-inbox-all' },
    { value: 'reviews', label: t('admin.needs_review_2'), count: 'count-reviews' },
    { value: 'stuck', label: t('admin.money_waiting_2'), count: 'count-stuck' },
    { value: 'alerts', label: t('admin.alerts'), count: 'count-ialerts' }
  ];
  });

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
        btn('.ghost', 'ib-refresh', {}, t('admin.refresh'), 'rotate')),
      h('p.hint', t('admin.everything_waiting_for_staff_review_items')
        + t('admin.settle_and_alerts_not_acknowledged_yet')),
      shows('reviews') ? h('section.ib-part', h('h3.st-group-title', t('admin.needs_review_2')),
        h('div.toolbar', segmented('rv-all', [{ value: 'open', label: t('admin.open') }, { value: 'all', label: t('admin.all_latest_50') }],
          S.reviews.all ? 'all' : 'open')),
        h('p.hint', t('admin.money_no_rule_on_the_server')
          + t('admin.often_it_is_asked_a_role')),
        h('div.stack', { id: 'rv-list' }, reviewList())) : null,
      shows('stuck') ? h('section.ib-part', h('h3.st-group-title', t('admin.money_waiting_for_staff_stuck_escrow')),
        h('div.stack', { id: 'sk-list' }, stuckBody())) : null,
      shows('alerts') ? h('section.ib-part', h('h3.st-group-title', t('admin.open_alerts')),
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

  Text.later(function () {
    DD['rv-who'] = {
    prefix: t('admin.to'),
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
  });
  Text.later(function () {
    DD['rv-account'] = {
    prefix: t('admin.from'),
    options: function () {
      return [{ value: 'cash', label: 'cash' }, { value: 'bank', label: 'bank' }, { value: 'dirty', label: t('admin.dirty_money') }];
    },
    disabled: function (id) { return unwrittenItem(id); },
    value: function (id) {
      return S.forms['rv.' + id + '.account'] || ((reviewItem(id) || {}).account) || 'bank';
    },
    pick: function (v, id) { disarm(); S.forms['rv.' + id + '.account'] = v; }
  };
  });

  function reviewItem(id) {
    return asList(S.reviews.items).filter(function (item) { return String(item.id) === String(id); })[0];
  }

  /** Listed, and not in the store yet: resolving it then answers that the
      store has not taken it, so its form is drawn and cannot be used. */
  var UNWRITTEN_WHY;
  Text.later(function () {
    UNWRITTEN_WHY = t('admin.it_can_be_resolved_once_the');
  });
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
      fields = field('rv.' + id + '.note', { class: 'is-grow', placeholder: t('admin.why_a_note_is_required'),
        maxlength: '200', 'aria-label': t('admin.note'), disabled: off });
    } else if (action === 'pay') {
      fields = parties.length ? dropdown('rv-who:' + id) : h('p.note', t('admin.the_item_names_nobody_to_pay'));
    } else {
      fields = frag(parties.length ? dropdown('rv-who:' + id) : null,
        hasGoods ? segmented('rv-goods', [{ value: 'no', label: t('admin.an_amount'), disabled: off, title: why },
          { value: 'yes', label: t('admin.every_item_and_weapon'), disabled: off, title: why }],
          goods ? 'yes' : 'no', { 'data-id': id }) : null,
        goods ? null : field('rv.' + id + '.amount', { class: 'is-short', placeholder: t('admin.amount'),
          inputmode: 'numeric', 'aria-label': t('admin.amount'), disabled: off }),
        goods ? null : dropdown('rv-account:' + id));
    }
    var verbs = { refund: [t('admin.refund_it'), t('admin.click_again_to_refund')], pay: [t('admin.pay_it'), t('admin.click_again_to_pay')],
                  dismiss: [t('admin.dismiss_it'), t('admin.click_again_to_dismiss')] };
    return h('div.rv-form' + (off ? '.is-off' : ''),
      off ? h('p.note', UNWRITTEN_WHY) : null,
      segmented('rv-action', [{ value: 'refund', label: t('admin.refund'), disabled: off, title: why },
        { value: 'pay', label: t('admin.pay'), disabled: off, title: why },
        { value: 'dismiss', label: t('admin.dismiss'), disabled: off, title: why }], action, { 'data-id': id }),
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
        writeBtn('.primary', 'resolve-finish', { 'data-id': id }, t('admin.finish_as_decided'),
          t('admin.click_again_to_finish'), 'check')));
  }

  /** What a decision on an item says, in a line: what, to whom. */
  function decisionText(resolution) {
    var r = resolution || {};
    return String(r.action || t('admin.a_decision')) + (r.cid ? t('admin.to_x', String(r.cid)) : '');
  }

  function reviewList() {
    var items = S.reviews.items;
    if (!items) return loading(t('admin.reading_the_review_queue'));
    if (!items.length) return empty(S.reviews.all ? t('admin.the_queue_has_never_held_anything') : t('admin.nothing_is_waiting_for_review'));
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
          h('span.sub', t('admin.opened_x', when(item.created_at)))),
        item.about ? h('p.about', String(item.about)) : null,
        item.unwritten ? h('p.note.is-warn', t('admin.not_in_the_store_yet_the')) : null,
        bareGoods(item) ? h('p.note.is-warn', num(bareGoods(item)) + t('admin.of_its_goods_were_kept_without')
          + t('admin.which_was_too_big_to_keep')
          + t('admin.attachments_or_what_was_inside')) : null,
        item.settles && item.state === 'open' && !item.unwritten
          ? h('p.note', t('admin.the_server_settles_this_itself_from')
            + t('admin.refund_or_pay_settles_it_the')) : null,
        resolving ? h('p.note.is-warn', t('admin.being_resolved_by', decisionText(item.resolution),
          String(item.resolved_by || '—')) + t('admin.it_stopped_part_way_and_finish')
          + t('admin.that_decision_and_nothing_else')) : null,
        h('dl.facts',
          h('dt', t('admin.contract')), h('dd', item.contract ? h('button.link.mono', { type: 'button', 'data-act': 'contract',
            'data-id': String(item.contract) }, String(item.contract)) : '—'),
          h('dt', t('admin.amount')), h('dd', item.amount != null ? money(item.amount) + (item.account ? ' ' + item.account : '') : '—'),
          asList(item.items).length ? h('dt', t('admin.goods')) : null,
          asList(item.items).length ? h('dd', asList(item.items).map(function (g) {
            return holds(g) + (g && g.metadata_omitted === true ? t('admin.without_its_metadata') : '');
          }).join(', ')) : null,
          h('dt', t('admin.involved')), h('dd', asList(item.parties).length ? asList(item.parties).map(function (p) {
            return h('span.party', h('b', String(p.role)), ' ' + String(p.who || '—'));
          }) : '—'),
          isReport(item) ? h('dt', t('admin.the_report')) : h('dt', t('admin.what_was_known')),
          h('dd', isReport(item) ? reportPart(item) : (keyValues(item.known) || '—')),
          h('dt', t('admin.the_store_now')), h('dd',
            now.contract ? t('admin.contract_lower_x', now.contract) : t('admin.contract_unknown'),
            now.buyout ? t('admin.buyout') + now.buyout : '',
            lines ? t('admin.lines_held_settled_missing', num(lines.held), num(lines.settled), num(lines.missing)) : ''),
          item.resolution && !resolving ? h('dt', t('admin.resolved')) : null,
          item.resolution && !resolving ? h('dd', detailText(item.resolution) + t('admin.by') + String(item.resolved_by || '—')
            + ' · ' + when(item.resolved_at)) : null),
        open && canWrite() ? (resolving ? finishForm(item) : (dismissOnly(item) ? reportForm(item) : reviewForm(item))) : null,
        answerBox(answer));
    }));
  }

  /* ---- alerts ---- */

  var LEVEL_LABEL;
  Text.later(function () {
    LEVEL_LABEL = { always: t('admin.needs_staff'), problem: t('admin.setting') };
  });

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
    var where = d.webhook === 'alert' ? t('admin.the_alert_webhook_crimson_hitman_alert')
      : d.webhook === 'staff' ? t('admin.the_staff_webhook_crimson_hitman_webhook')
      : null;
    var status;
    if (d.on === false) {
      status = h('p.about', t('admin.off_post_alerts_to_discord_is')
        + t('admin.every_alert_is_still_listed_here'));
    } else if (!where) {
      status = h('p.about', t('admin.no_webhook_is_set_so_nothing')
        + t('admin.server_cfg_set_never_setr_or'));
    } else {
      status = h('p.about', t('admin.posting_to') + where + t('admin.one_post_every_10_seconds_at')
        + t('admin.with_no_identity_in_it'));
    }
    var fail = d.lastFail;
    var failNote = null;
    if (fail) {
      var why = Number(fail.status) > 0 ? t('admin.http_status', fail.status) : t('admin.no_answer');
      var since = d.lastOkAt && Number(d.lastOkAt) > Number(fail.at);
      var lost = [];
      if (Number(fail.alerts) > 0) {
        lost.push(tn('admin.alerts_not_posted', Number(fail.alerts), num(fail.alerts)));
      }
      if (fail.test) lost.push(t('admin.the_test_alert_not_posted'));
      failNote = h('p.note' + (since ? '' : '.is-warn'), (since ? 'Earlier, a' : 'A') + t('admin.post_was_given_up_after')
        + num(fail.tries) + t('admin.tries') + why + ') ' + ago(fail.at) + ': ' + lost.join(', and ') + '.'
        + (since ? t('admin.posts_have_gone_through_since') : ''));
    }
    return frag(status,
      h('dl.facts',
        h('dt', t('admin.last_post')), h('dd', d.lastOkAt ? when(d.lastOkAt) + ' (' + ago(d.lastOkAt) + ')' : t('admin.none_since_the_start')),
        h('dt', t('admin.posted_since_the_start')), h('dd', tn('admin.alerts_count', Number(d.posted), num(d.posted))),
        h('dt', t('admin.waiting')), h('dd', num(d.waiting) + (d.posting ? t('admin.and_a_post_being_tried_again') : ''))),
      failNote,
      h('div.btn-row', writeBtn('', 'al-test', {}, t('admin.send_a_test_alert'), t('admin.click_again_to_send_it'), 'paper-plane', true)),
      answerBox(S.alerts.test));
  }

  function alertCard(a) {
    var id = String(a.id);
    var acked = !!a.acknowledged_at;
    var count = Number(a.count) || 1;
    return h('article.card.al' + (acked ? '' : '.is-open'), { id: 'al-' + id },
      h('header.card-head',
        h('span.chip' + (a.level === 'problem' ? '.is-panel' : '.is-warn'), LEVEL_LABEL[a.level] || String(a.level || '')),
        count > 1 ? h('span.chip', t('admin.said_n_times', num(count))) : null,
        h('span.sub', ago(a.last_at))),
      h('p.al-text', String(a.text || '')),
      h('dl.facts',
        h('dt', count > 1 ? t('admin.first_said') : t('admin.said')), h('dd', when(a.first_at)),
        count > 1 ? h('dt', t('admin.last_said')) : null, count > 1 ? h('dd', when(a.last_at)) : null,
        a.contract ? h('dt', t('admin.contract')) : null,
        a.contract ? h('dd', h('button.link.mono', { type: 'button', 'data-act': 'contract',
          'data-id': String(a.contract) }, String(a.contract))) : null,
        acked ? h('dt', t('admin.acknowledged')) : null,
        acked ? h('dd', String(a.acknowledged_by || '—') + ' · ' + when(a.acknowledged_at)) : null),
      !acked && canWrite() ? h('div.btn-row', writeBtn('', 'al-ack', { 'data-id': id }, t('admin.acknowledge'),
        t('admin.click_again_to_acknowledge'), 'check', true)) : null,
      answerBox(S.alerts.answers[id]));
  }

  function alertsBody() {
    var d = S.alerts.data;
    if (!d) return S.alerts.error ? empty(S.alerts.error) : loading(t('admin.reading_the_alerts'));
    var rows = asList(d.rows);
    var open = S.alerts.state === 'open';
    var total = open ? Number(d.open) || 0 : Number(d.acknowledged) || 0;
    var inInbox = S.section === 'inbox';
    return frag(
      inInbox ? null : card(t('admin.discord'), discordBody(d.discord)),
      h('div.toolbar',
        h('span.sub', t('admin.open_acknowledged', num(d.open), num(d.acknowledged))
          + (rows.length < total ? t('admin.the_newest_shown', num(rows.length)) : '')),
        open && rows.length && canWrite()
          ? writeBtn('', 'al-ack-all', {}, t('admin.acknowledge_all_shown'),
            t('admin.click_again_acknowledge') + num(rows.length), 'check-double', true)
          : null),
      answerBox(S.alerts.all),
      rows.length ? rows.map(alertCard)
        : empty(open ? t('admin.no_open_alerts') : t('admin.nothing_has_been_acknowledged_yet')),
      inInbox ? h('p.note', t('admin.acknowledged_ones_discord_and_the_test')) : null);
  }

  SHELL.alerts = function () {
    return h('section.view',
      h('div.toolbar',
        segmented('al-state', [{ value: 'open', label: t('admin.open') }, { value: 'acknowledged', label: t('admin.acknowledged') }],
          S.alerts.state),
        btn('.ghost', 'al-refresh', {}, t('admin.refresh'), 'rotate')),
      h('p.hint', t('admin.every_line_the_server_console_prints')
        + t('admin.a_write_that_failed_a_job')
        + t('admin.again_is_counted_on_its_alert')),
      h('div.stack', { id: 'al-list' }, alertsBody()));
  };
  LOAD.alerts = function () { loadAlerts(); };

  /* ---- console ---- */

  var KIND_LABEL;
  Text.later(function () {
    KIND_LABEL = { always: t('admin.always'), problem: t('admin.problem'), debug: t('admin.debug') };
  });
  var CONSOLE_KINDS;
  Text.later(function () {
    CONSOLE_KINDS = [
    { value: '', label: t('admin.all') }, { value: 'always', label: t('admin.always') },
    { value: 'problem', label: t('admin.problems') }, { value: 'debug', label: t('admin.debug') }
  ];
  });

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
    return S.console.readAt ? t('admin.read_at') + clock(S.console.readAt) + t('admin.again_every') + Math.round(refreshMs() / 1000)
      + t('admin.while_open') : '';
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
      out.push(t('admin.settings_that_need_attention'));
      shown.problems.forEach(function (text) { out.push(t('admin.problem_line', text)); });
    }
    if (shown.boot.length) {
      out.push(t('admin.what_the_last_start_said'));
      shown.boot.forEach(function (line) { out.push('[' + line.kind + '] ' + line.text); });
    }
    if (shown.recent.length) {
      out.push(t('admin.since_the_start_newest_first'));
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
      times > 1 ? h('span.chip', t('admin.said_n_times', num(times))) : null,
      h('span.cs-text', String(line.text || '')));
  }

  function consoleList(lines, withTime, none) {
    return lines.length ? h('ul.cs-lines', lines.map(function (line) { return consoleLine(line, withTime); }))
      : empty(none);
  }

  function consoleBody() {
    var d = S.console.data;
    if (!d) return S.console.error ? empty(S.console.error) : loading(t('admin.reading_the_console'));
    var shown = consoleShown();
    var kind = S.console.kind;
    var filtered = !!trim(S.forms['cs.q']);
    var parts = [h('p.note', d.debug
      ? t('admin.debug_output_is_on_config_debug')
      : t('admin.debug_output_is_off_config_debug')
        + t('admin.line_for_the_settings_that_need'))];
    if (!kind || kind === 'problem') {
      parts.push(card(t('admin.settings_that_need_attention_2') + num(d.count) + ')',
        consoleList(shown.problems.map(function (text) { return { text: text, kind: 'problem' }; }), false,
          filtered ? t('admin.none_matches') : t('admin.none'))));
    }
    if (kind !== 'problem') {
      var left = Number(d.bootLeft) || 0;
      parts.push(card(t('admin.what_the_last_start_said_2'), frag(
        consoleList(shown.boot, false, filtered || kind ? t('admin.none_matches') : t('admin.nothing_kept')),
        left > 0 ? h('p.note', tn('admin.and_more_lines_the_start_said', left, num(left), num(d.bootKept))) : null)));
      parts.push(card(t('admin.since_the_start_newest_first_2'), frag(
        h('p.note', t('admin.the_newest_2') + num(d.recentKept) + t('admin.debug_lines_and_the_newest') + num(d.alwaysKept)
          + t('admin.lines_marked_always_the_same_line')),
        consoleList(shown.recent, true, filtered || kind ? t('admin.none_matches') : t('admin.nothing_since_the_start')))));
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
          field('cs.q', { id: 'cs-q', placeholder: t('admin.filter_the_lines'), 'data-live': 'cs-filter',
            'aria-label': t('admin.filter_the_lines') })),
        btn('.ghost', 'cs-refresh', {}, t('admin.refresh'), 'rotate'),
        btn('', 'cs-copy', {}, t('admin.copy'), 'copy'),
        h('span.sub', { id: 'cs-at' }, consoleAt())),
      h('p.hint', t('admin.what_this_resource_said_in_the')
        + t('admin.off_always_is_printed_whatever_debug')
        + t('admin.printed_only_with_debug_on_kept')
        + t('admin.are_shown_by_their_place_on')
        + t('admin.database_statement_was_sent')),
      h('div.stack', { id: 'cs-list' }, consoleBody()));
  };
  LOAD.console = function () { loadConsole(); };

  /* ---- logs ---- */

  Text.later(function () {
    DD['lg-kind'] = {
    prefix: t('admin.kind'),
    options: function () {
      return [{ value: '', label: t('admin.any') }, { value: 'financial', label: 'financial' },
        { value: 'conduct', label: 'conduct' }, { value: 'rejected', label: 'rejected' },
        { value: 'system', label: 'system' }];
    },
    value: function () { return S.logs.kind; },
    pick: function (v) { S.logs.kind = v; firstLogPage(); }
  };
  });
  Text.later(function () {
    DD['lg-range'] = {
    prefix: t('admin.when'),
    options: function () { return RANGES; },
    value: function () { return S.logs.range; },
    pick: function (v) {
      S.logs.range = v;
      var range = byId('lg-range');
      if (range) range.hidden = v !== 'custom';
      firstLogPage();
    }
  };
  });

  /* A contract id and a citizen id as the server reads them (Util.toId,
     Util.toCitizenId). Sent half-typed, every pause in typing one answered
     "That is not a contract id." in an error toast, over the rows of the
     search before, which read as its result. A box that does not hold one
     yet is marked and nothing is asked, as with a date that cannot be read,
     and Enter says why. */
  var LOG_IDS;
  Text.later(function () {
    LOG_IDS = {
    contract: { re: /^[A-Za-z0-9_-]{8,64}$/, box: 'lg-contract',
                why: t('admin.a_contract_id_is_8_to') },
    actor: { re: /^[A-Za-z0-9]{3,32}$/, box: 'lg-actor', why: t('admin.a_citizen_id_is_3_to') }
  };
  });

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
    if (!d) return loading(t('admin.reading_the_log'));
    var rows = asList(d.rows);
    if (!rows.length) return empty(t('admin.no_row_matches'));
    return h('div.table-wrap', h('table.grid.is-rows.is-log',
      h('thead', h('tr', h('th', t('admin.when')), h('th', t('admin.kind')), h('th', t('admin.action')), h('th', t('admin.contract')),
        h('th', t('admin.who')), h('th', t('admin.detail')))),
      h('tbody', rows.map(function (row, i) {
        var open = !!S.logs.open[i];
        return frag(
          h('tr.row' + (open ? '.is-open' : ''), { 'data-act': 'lg-expand', 'data-index': String(i), tabindex: '0',
            title: open ? t('admin.hide_the_detail') : t('admin.show_the_whole_detail') },
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
      btn('.is-small', 'lg-newer', { disabled: S.logs.back.length === 0 }, t('admin.newer'), 'chevron-left'),
      h('span.pager-text', t('admin.page_newest_first', page)),
      btn('.is-small', 'lg-older', { disabled: d.next === undefined || d.next === null }, t('admin.older'), 'chevron-right'));
  }

  /* Records \u203a Logs: every log staff read, one view, one op (logs), each
     log a filter chip (its area on the server). Each section links to its
     own with that chip picked (a GROUPS entry's logs: 'logs:<filter>'):
     Game rules to Setting changes, Hitman organisation to Org audit, Boss
     permissions to Grant history, Target limits to the audit log's
     staff_target_ rows. The chip last picked stays picked. */
  var LOG_AREAS;
  Text.later(function () {
    LOG_AREAS = [
    { id: 'audit', label: t('admin.audit_log') },
    { id: 'settings', label: t('admin.setting_changes') },
    { id: 'org', label: t('admin.org_audit') },
    { id: 'grants', label: t('admin.grant_history') }
  ];
  });
  /** What each section link sets: the chip, and for Target limits the
      audit log's action filter. */
  var LOG_FILTERS = {
    audit: { area: 'audit' }, settings: { area: 'settings' }, org: { area: 'org' }, grants: { area: 'grants' },
    targets: { area: 'audit', action: 'staff_target_' }
  };
  function logArea() { return S.section === 'logs' ? S.logs.area : null; }
  function logAreaLabel() {
    var a = LOG_AREAS.filter(function (x) { return x.id === S.logs.area; })[0];
    return a ? a.label : t('admin.audit_log');
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
        field('lg.action', { class: 'is-mid', placeholder: t('admin.action_contains'), 'data-live': 'lg-search',
          'data-enter': 'lg-search-now', 'aria-label': t('admin.action_contains') }),
        field('lg.contract', { id: 'lg-contract', class: 'is-mid', placeholder: t('admin.contract_id'), 'data-live': 'lg-search',
          'data-enter': 'lg-search-now', 'aria-label': t('admin.contract_id') }),
        field('lg.actor', { id: 'lg-actor', class: 'is-mid', placeholder: t('admin.citizen_id'),
          'data-live': 'lg-search', 'data-enter': 'lg-search-now',
          title: canIdentify() ? null : t('admin.without_the_identity_ace_only_the')
            + t('admin.name_as_the_target_or_a'),
          'aria-label': t('admin.citizen_id') }),
        dropdown('lg-range'),
        rangeInputs('lg', S.logs.range, 'lg-search'),
        btn('.ghost', 'lg-clear', {}, t('admin.clear'), 'eraser'),
        h('span.lg-tools', { id: 'lg-tools' }, logToolsBody())),
      h('p.hint', canIdentify()
        ? t('admin.every_row_as_it_was_written')
        : t('admin.citizen_ids_show_as_the_partys')
          + t('admin.anonymous_parties_as_anonymous_a_citizen')
          + t('admin.own_name')),
      h('div.results', { id: 'lg-results' }, logRows()),
      h('div.pager', { id: 'lg-pager' }, logPager()));
  }

  /** The organisation's log and its grant history, as the organisation is. */
  function orgLogBody() {
    var d = S.org.data;
    if (!d) return S.org.error ? empty(S.org.error) : loading(t('admin.reading_the_organisation'));
    if (!d.enabled) {
      return empty(t('admin.the_hitman_organisation_is_off_config')
        + t('admin.hitman_organisation_setup_turns_it_on'));
    }
    if (!d.loaded) return empty(t('admin.the_organisation_has_not_been_read'));
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
    if (!subject && !byRef) { toast(t('admin.give_a_player_id_a_citizen'), 'error'); return Promise.resolve(); }
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
    var from = pt.grandfathered === true ? t('admin.yes') : pt.grandfathered === false ? t('admin.no') : t('admin.not_decided');
    var about;
    /* Grandfathered, and these hours against the floor, decide only where the
       tracker is what the rule reads: an export or QBox metadata answering
       for them decides by its own hours. */
    var elsewhere = pt.from === 'provider' || pt.from === 'metadata';
    if (pt.unread) about = t('admin.their_counted_time_could_not_be');
    else if (elsewhere) about = null;
    else if (pt.grandfathered === true) about = t('admin.they_were_on_the_server_before')
      + t('admin.having_played_enough_whatever_the_hours');
    else if (pt.grandfathered === false) about = hours < floor
      ? t('admin.too_new_to_be_named_as') + num(floor) + ' h.'
      : t('admin.enough_to_be_named_as_a');
    else if (!pt.counted) about = t('admin.nothing_counted_yet_counting_starts_the');
    else about = t('admin.whether_they_were_on_the_server')
      + t('admin.being_in_the_city');
    var rule = pt.from === 'provider' ? t('admin.the_new_player_rule_reads_your')
      : pt.from === 'metadata' ? t('admin.the_new_player_rule_reads_their') : null;
    return card(t('admin.playtime'), frag(
      h('div.tiles.is-compact',
        tile(t('admin.counted_here'), h('p.big', pt.unread ? '—' : t('admin.n_h', num(hours)))),
        tile(t('admin.needed_to_be_a_target'), h('p.big', t('admin.n_h', num(floor)))),
        tile(t('admin.from_before_the_count'), h('p.big.is-word', from))),
      about ? h('p.sub', about) : null,
      rule ? h('p.note', rule) : null,
      h('div.toolbar',
        field('pl.hours', { id: 'pl-hours', type: 'number', min: '0', max: '100000', step: '0.5',
          placeholder: t('admin.hours'), 'aria-label': t('admin.counted_hours') }),
        writeBtn('', 'pl-playtime-set', {}, t('admin.set_hours'), t('admin.click_again_to_set'), 'clock', true),
        writeBtn('.ghost', 'pl-playtime-reset', {}, t('admin.reset_to_0'), t('admin.click_again_to_reset'), 'arrow-rotate-left', true)),
      answerBox(S.players.playtime)), '', h('span.sub', pt.counting ? t('admin.in_the_city_counting') : t('admin.not_counting')));
  }

  /** Freeze or Unfreeze, under the lookup: a reason, and two clicks. While
      frozen, every live contract they are party to is on hold, paused and
      untouched, until they are unfrozen. */
  function freezeCard(frozen) {
    var form = h('div.toolbar',
      field('pl.freezeReason', { id: 'pl-freeze-reason', class: 'is-grow', maxlength: '120',
        placeholder: frozen ? t('admin.reason_for_unfreezing_kept_in_the') : t('admin.reason_for_the_freeze_kept_in'),
        'aria-label': frozen ? t('admin.reason_for_unfreezing') : t('admin.reason_for_the_freeze') }),
      frozen
        ? modBtn('', 'pl-unfreeze', {}, t('admin.unfreeze'), t('admin.click_again_to_unfreeze'), 'play')
        : modBtn('.danger', 'pl-freeze', {}, t('admin.freeze'), t('admin.click_again_to_freeze'), 'snowflake'));
    var about = frozen
      ? frag(h('p.sub', t('admin.frozen_ago', ago(frozen.since)) + (frozen.reason ? ': ' + String(frozen.reason) : '')
          + (frozen.by ? t('admin.by') + String(frozen.by) : '')),
        h('p.note', t('admin.every_live_contract_they_are_party')
          + t('admin.on_it_is_accepted_paid_refunded')))
      : h('p.note', t('admin.freezing_puts_every_live_contract_they')
          + t('admin.placer_or_an_operative_its_clocks')
          + t('admin.players_are_told_only_that_it'));
    return card(t('admin.freeze'), frag(about, form, answerBox(S.players.freeze)), '',
      frozen ? h('span.chip.is-warn.is-frozen', t('admin.frozen')) : null);
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
      h('h2', String(p.name || t('admin.no_name_on_record'))),
      p.cid ? h('span.cid', String(p.cid)) : h('span.chip', t('admin.citizen_id_hidden')),
      p.online ? h('span.chip.is-live', t('admin.in_the_city_player') + String(p.server)) : h('span.chip', 'offline'),
      d.frozen ? h('span.chip.is-warn.is-frozen', t('admin.frozen')) : null,
      d.suspended ? h('span.chip.is-warn.is-suspended', t('admin.suspended')) : null,
      d.protected ? h('span.chip.is-protected', t('admin.protected')) : null);
  }

  /** The person tabs, as buttons under their summary. */
  function personLinks() {
    // Their contracts: the one list of contracts, filtered to them.
    return h('div.btn-row.person-links',
      btn('.is-small.ghost', 'pl-contracts', {}, t('admin.their_contracts'), 'file-contract'),
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
        tile(t('admin.completed'), h('p.big', num(stats.completed))),
        tile(t('admin.failed'), h('p.big', num(stats.failed))),
        tile(t('admin.placed'), h('p.big', num(stats.placed))),
        tile(t('admin.survived'), h('p.big', num(stats.survived))),
        tile(t('admin.success_rate'), h('p.big', stats.rate == null ? '—' : num(stats.rate) + '%')),
        tile(t('admin.standing'), h('p.big.is-word', String(stats.standing || '—'))))
        : h('p.note', t('admin.their_record_is_not_shown_it')
          + t('admin.which_only_the_identity_ace_may')),
      h('div.tiles.is-compact',
        tile(t('admin.contracts'), h('p.big', num(asList(d.contracts).length))),
        tile(t('admin.owed_to_them'), h('p.big', num(asList(d.owed).length))),
        tile(t('admin.playtime'), h('p.big', d.playtime && !d.playtime.unread ? num(d.playtime.hours) + ' h' : '—'))));
  }

  function moneyBody(d) {
    var owed = asList(d.owed);
    var notices = d.notices || {};
    return frag(
      payCard(d),
      h('div.cols',
        card(t('admin.owed_to_them'), owed.length ? h('div.table-wrap', h('table.grid',
          h('thead', h('tr', h('th', t('admin.line')), h('th', t('admin.contract')), h('th', t('admin.holds')), h('th', t('admin.state')),
            h('th.num', t('admin.still_owed')), h('th', t('admin.queued')))),
          h('tbody', owed.map(function (line) {
            return h('tr', h('td.mono', String(line.id)),
              h('td', h('button.link.mono', { type: 'button', 'data-act': 'contract', 'data-id': String(line.contract) },
                String(line.contract))),
              h('td', holds(line)), h('td', String(line.state || '—'),
                line.parked ? h('span.chip.is-warn', t('admin.left_for_staff')) : null),
              h('td.num', MONEY[line.source] ? money(line.owes) : num(line.owes)),
              h('td', line.queued ? 'yes' : 'no'));
          })))) : empty(t('admin.nothing_is_owed_to_them') + (canIdentify() ? '.' : t('admin.that_you_may_see'))),
          '', h('span.sub', tn('admin.deliveries_pending', Number(d.pending), num(d.pending)))),
        card(t('admin.notices_for_their_next_login'), Number(notices.count) > 0
          ? h('ul.plain', asList(notices.titles).map(function (tv) { return h('li', String(tv)); }))
          : empty(t('admin.none_waiting')), '', h('span.sub', num(notices.count)))));
  }

  function measuresBody(d) {
    return frag(
      freezeCard(d.frozen),
      h('div.cols', suspendCard(d), protectCard(d)),
      card(t('admin.target_limits'), frag(
        h('p.about', t('admin.how_often_a_contract_may_be')
          + t('admin.or_an_exemption_exactly_with_reset')),
        d.limit ? h('p.note', (d.limit.exempt ? t('admin.exempt_from_the_target_limits') : t('admin.target_limits_of_their_own'))
          + t('admin.since_x', when(d.limit.since)) + (d.limit['until'] ? t('admin.until_x', when(d.limit['until'])) : t('admin.for_good'))
          + (d.limit.reason ? ': ' + String(d.limit.reason) : '.')) : null,
        h('div.btn-row', btn('.is-small', 'pl-tl', {}, t('admin.open_them_in_target_limits'), 'user-clock')))));
  }

  /** Why can't they see...: the diagnosis, run as the player selected. */
  function playerDiagBody(d) {
    var tv = S.tools;
    var mine = tv.pdiag && tv.pdiag.ref === S.players.ref ? tv.pdiag : null;
    var online = d.player && d.player.online;
    return card(t('admin.why_can_t_they_see'), frag(
      h('p.about', t('admin.runs_the_apps_own_reads_as')
        + t('admin.with_the_server_wide_checks_they')),
      h('div.btn-row', btn('.primary', 'pl-diag', { disabled: !online || null,
        title: online ? null : t('admin.they_are_not_in_the_city') }, t('admin.run_the_diagnosis_as_them'), 'stethoscope')),
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
          field('pl.q', { id: 'pl-q', placeholder: t('admin.player_id_citizen_id_or_name'), 'data-enter': 'pl-lookup',
            'aria-label': t('admin.player_id_citizen_id_or_name') })),
        btn('.primary', 'pl-lookup', {}, t('admin.look_up'), 'arrow-right')),
      recent.length ? h('div.chips.recent', h('span.sub', 'Recent:'), recent.map(function (r) {
        return h('button.chip.is-link', { type: 'button', 'data-act': 'pl-recent', 'data-value': r.subject },
          r.name);
      })) : null,
      h('p.hint', canIdentify()
        ? t('admin.you_see_every_contract_they_were')
        : t('admin.contracts_they_placed_or_took_anonymously')
          + t('admin.and_the_notices_on_them_and')));
  }

  function playerBody() {
    var d = S.players.data;
    if (!d) return empty(t('admin.look_someone_up_by_player_id'));
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
    if (entry.kind === 'switch' || typeof value === 'boolean') return value === true ? t('admin.on') : t('admin.off');
    if (entry.kind === 'list') {
      var list = asList(value);
      return list.length ? list.join(', ') : '(none)';
    }
    if (entry.kind === 'range') {
      return value && typeof value === 'object' ? t('admin.range_to', num(value.min), num(value.max)) : t('admin.not_set');
    }
    if (value === null || value === undefined) return t('admin.not_set');
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
    var inMinutes = !/Seconds$/.test(key);
    var unit = inMinutes ? t('admin.unit_min') : t('admin.unit_s');
    var d = Math.floor(seconds / 86400), hr = Math.floor((seconds % 86400) / 3600);
    var mi = Math.floor((seconds % 3600) / 60), se = seconds % 60;
    var parts = [];
    if (d) parts.push(t('admin.n_d', d));
    if (hr) parts.push(t('admin.n_h', hr));
    if (mi) parts.push(t('admin.n_min', mi));
    if (se) parts.push(t('admin.n_s', se));
    if (parts.length === 1 && inMinutes && mi && !hr && !d) return '';
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
      return h('button.switch' + (on ? '.is-on' : ''), a, h('span.knob'), h('span.lbl', on ? t('admin.on') : t('admin.off')),
        h('span.cfm', t('admin.click_again_turn') + (on ? t('admin.off') : t('admin.on'))));
    }
    if (entry.kind === 'choice') {
      return segmented('st-choice', asList(entry.choices).map(function (c) {
        return { value: c, label: String(c), disabled: !open, title: whyNoWrite(),
                 confirm: t('admin.click_again') + String(c) };
      }), entry.value, { 'data-key': key });
    }
    if (entry.kind === 'list') {
      var names = listDraft(entry);
      var changed = !sameValue(names, asList(entry.value).map(String));
      return h('div.st-list',
        h('ul.st-chips', names.length ? names.map(function (name) {
          return h('li.st-chip', h('span', name),
            h('button.st-chip-x', { type: 'button', 'data-act': 'st-list-del', 'data-key': key, 'data-value': name,
              disabled: !open, title: t('admin.remove_x', name), 'aria-label': t('admin.remove_x', name) }, icon('xmark'),
              h('span.lbl', t('admin.remove'))));
        }) : h('li.st-none', '(none)')),
        h('div.st-edit',
          field('stl.' + key, { class: 'is-grow', placeholder: entry.whole ? t('admin.add_a_line') : t('admin.add_a_name'),
            'data-enter': 'st-list-add',
            'data-key': key, disabled: !open, 'aria-label': t('admin.add_to') + entry.label }),
          btn('.is-small', 'st-list-add', { 'data-key': key, disabled: !open || null }, t('admin.add'), 'plus'),
          writeBtn('.is-small' + (changed ? '.primary' : ''), 'st-list-save',
            { 'data-key': key, id: 'st-save-' + key }, t('admin.save_list'), t('admin.click_again_to_save'), 'check', false, open)));
    }
    if (entry.kind === 'range') {
      var pair = entry.value && typeof entry.value === 'object' ? entry.value : {};
      return h('div.st-edit',
        field('st.' + key + '.min', { value: String(typedOr('st.' + key + '.min', pair.min)), class: 'is-short',
          inputmode: 'decimal', disabled: !open, 'aria-label': t('admin.label_from', entry.label) }),
        h('span.range-sep', 'to'),
        field('st.' + key + '.max', { value: String(typedOr('st.' + key + '.max', pair.max)), class: 'is-short',
          inputmode: 'decimal', disabled: !open, 'aria-label': t('admin.label_to', entry.label) }),
        writeBtn('.is-small', 'st-range-save', { 'data-key': key, id: 'st-save-' + key }, t('admin.save'),
          t('admin.click_again_to_save'), 'check', false, open),
        h('span.st-range', t('admin.range_to', num(entry.min), num(entry.max)) + (entry.integer ? t('admin.whole_suffix') : '')));
    }
    var bind = 'st.' + key;
    var shownValue = String(entry.value == null ? '' : entry.value);
    var range = entry.kind === 'number'
      ? t('admin.range_to', entry.min != null ? entry.min : '…', entry.max != null ? entry.max : '…') + (entry.integer ? t('admin.whole_suffix') : '')
      : 'letters, digits, - and _';
    return h('div.st-edit',
      field(bind, { value: shownValue, class: entry.kind === 'text' ? 'is-grow' : 'is-short',
        inputmode: entry.kind === 'number' ? 'decimal' : null, 'data-enter': 'st-save', 'data-key': key,
        disabled: !open, 'aria-label': entry.label }),
      entry.kind === 'number' && trim(unitOf(entry)) ? h('span.st-unit', trim(unitOf(entry))) : null,
      writeBtn('.is-small', 'st-save', { 'data-key': key, id: 'st-save-' + key }, t('admin.save'),
        t('admin.click_again_to_save'), 'check', false, open),
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
        return String(entry.strict || t('admin.stricter_players_are_refused_sooner')).replace(/%s/g, num(value));
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
  var TYPE_LABEL;
  Text.later(function () {
    TYPE_LABEL = { switch: t('admin.switch'), timer: t('admin.timer'), money: t('admin.money'), limit: t('admin.limit'), list: t('admin.list') };
  });

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
          overridden ? h('span.chip.is-panel', t('admin.changed_from_the_panel_2')) : null,
          entry.live === false ? h('span.chip.is-warn.is-restart', t('admin.applies_after_restart')) : null,
          entry.ignored ? h('span.chip.is-error', t('admin.not_applied_2')) : null,
          entry.inactive ? h('span.chip.is-warn', t('admin.does_not_apply_now')) : null,
          entry.denied ? h('span.chip', t('admin.edit_in_config_lua')) : null),
        // A key whose switch is off (the catalogue's `needs`): said beside
        // it, so a staff member is not left changing something that does
        // nothing.
        entry.inactive ? h('p.st-about.is-warn', String(entry.inactive)) : null,
        entry.readonly ? h('p.st-about.is-warn', String(entry.readonly)) : null,
        entry.destroys && !entry.readonly
          ? h('p.st-about.is-warn', t('admin.lowering_it_deletes_for_good_so')) : null,
        entry.stricter && !entry.readonly
          ? h('p.st-about.is-warn', t('admin.making_it_stricter_refuses_players_at')) : null,
        entry.ignored ? h('p.st-about.is-error', t('admin.the_store_holds_a_value_that')
          + String(entry.ignored) + t('admin.config_luas_is_in_force_reset')) : null,
        entry.unknown ? h('p.st-about.is-error', t('admin.a_change_to_it_raised_in')
          + t('admin.back') + String(entry.unknown) + t('admin.the_store_may_or_may_not')
          + t('admin.force_set_or_reset_it_again')) : null,
        h('button.link.st-more', { type: 'button', 'data-act': 'st-details', 'data-key': key,
          'aria-expanded': open ? 'true' : 'false' }, open ? t('admin.details') : t('admin.details_2')),
        h('div.st-details', { hidden: !open },
          h('code.st-key', entry.secret ? 'server.cfg' : t('admin.config') + key),
          entry.about ? h('p.st-about', String(entry.about)) : null,
          entry.inflight ? h('p.st-inflight', h('b', t('admin.under_way')), String(entry.inflight)) : null,
          entry.readonly ? null : h('p.st-source', t('admin.now_x', describe(entry, entry.value))
            + t('admin.config_lua') + describe(entry, entry.default)
            + (hasShipped ? t('admin.default') + describe(entry, entry.shipped) : '')
            + (overridden ? t('admin.in_force_from_the_panel') + (entry.by ? t('admin.set_by') + entry.by : '')
              + (entry.at ? ' ' + ago(entry.at) : '') : t('admin.in_force_from_config_lua')))),
        answerBox(answer),
        key === 'Completion.KillPhotos' ? keptPhotosPart(entry) : null),
      // A read-only key too, when the store holds a value for it that was
      // not applied (kept from a version where it could be changed): the
      // reset takes that row away, and nothing in force moves.
      h('div.st-control', settingControl(entry),
        entry.ignored || entry.unknown || (overridden && !entry.readonly)
          ? writeBtn('.is-small.ghost', 'st-reset', { 'data-key': key }, t('admin.reset_to_config_lua'),
            t('admin.click_again_to_reset'), 'arrow-rotate-left', false, settingOpen(entry)) : null,
        offDefault ? writeBtn('.is-small.ghost', 'st-default', { 'data-key': key }, t('admin.reset_to_default'),
          t('admin.click_again_back_to') + describe(entry, entry.shipped), 'rotate-left', false,
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
    var photos = n === 1 ? t('admin.kill_photo') : t('admin.kill_photos_2');
    var files = Number(kept.files) || 0, links = Number(kept.links) || 0;
    var open = Math.max(Number(kept.open) || 0, Number(kept.waiting) || 0);
    var facts = [];
    if (files) facts.push(num(files) + t('admin.with_a_file_on_this_server'));
    if (links) {
      facts.push(num(links) + t('admin.on_lb_phones_image_host_removing')
        + t('admin.stays_on_the_host'));
    }
    if (open) {
      facts.push(num(open) + t('admin.open_on_a_phone_right_now')
        + t('admin.is_shown'));
    }
    return h('div.st-kept',
      h('p.st-about', num(n) + ' ' + photos + t('admin.kept_from_before_kill_photos_were')
        + t('admin.became_of_each_photo_removing_deletes')),
      facts.length ? h('ul.st-kept-facts', facts.map(function (text) { return h('li', text); })) : null,
      h('div.btn-row', writeBtn('.danger.is-small', 'st-remove-photos', {},
        t('admin.remove_the') + num(n) + ' ' + photos + t('admin.kept_from_before'),
        t('admin.click_again_remove') + num(n) + ' ' + photos + t('admin.for_good_2'), 'trash-can', true)),
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
  var VIEW_INTRO;
  Text.later(function () {
    VIEW_INTRO = {
    timers: t('admin.how_long_things_last_deadlines_cooldowns')
      + t('admin.while_the_placer_the_target_and'),
    money: t('admin.every_reward_and_money_setting_in')
      + t('admin.informant_prices_the_anonymity_fees_and')
      + t('admin.refuses_new_ones_over_it'),
    limits: t('admin.how_many_contracts_a_player_may')
      + t('admin.limits_each_value_is_checked_the'),
    targeting: t('admin.who_may_open_the_app_who'),
    tldefaults: t('admin.how_often_one_person_may_have_2')
      + t('admin.unless_their_job_per_job_or'),
    features: t('admin.the_on_and_off_switches_every')
      + t('admin.already_under_way_finishes_under_the')
      + t('admin.are_told_the_feature_is_turned'),
    devsettings: t('admin.debug_storage_rate_limits_timings_and')
      + t('admin.not_caps_a_stricter_one_refuses')
  };
  });

  /** Rewards & money, in these groups (the catalogue's `money`). */
  var MONEY_ORDER;
  Text.later(function () {
    MONEY_ORDER = [t('admin.rewards'), t('admin.payouts'), t('admin.buyouts'), t('admin.intel_prices'), t('admin.anonymity_fees'), t('admin.escrow')];
  });
  /** Features, in the README's and config.lua's order: the core switches
      first (in the catalogue's order), then Anonymity, Intel (its other
      groups after these four), the Advisory, Staff tools, Roleplay and
      Improvements. */
  var FEATURE_AREAS;
  Text.later(function () {
    FEATURE_AREAS = [
    [t('admin.anonymity'), t('admin.anonymity_whitelisted_job_targets')],
    ['Intel: Informants', t('admin.intel_informant_tip'), t('admin.intel_every_other_target'), t('admin.intel_whitelisted_job_targets')],
    // A character's record (server/record/), one screen group.
    ['Record: Progression', 'Record: Reputation', t('admin.record_tiered_board'), t('admin.record_hitman_heat'),
      t('admin.record_placer_record')],
    [t('admin.law_enforcement_advisory')],
    [t('admin.staff_tools')]
  ];
  });
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
  var GROUP_INTRO;
  Text.later(function () {
    GROUP_INTRO = {
    'Anonymity': t('admin.whether_a_contract_may_be_placed')
      + t('admin.operatives_name'),
    'Anonymity (whitelisted-job targets)': t('admin.the_same_for_the_other_target'),
    'Intel: Informants': t('admin.the_paid_look_ups_the_targets')
      + t('admin.master_switch'),
    'Intel: Informant tip': t('admin.the_hitmans_paid_tip_on_the'),
    'Intel: Every other target': t('admin.whether_each_informant_feature_is_offered'),
    'Intel: Whitelisted-job targets': t('admin.whether_each_informant_feature_is_offered_2'),
    'Law enforcement advisory': t('admin.what_officers_are_told_when_one')
      + t('admin.targeted_and_when'),
    'Access': t('admin.who_may_open_the_app_barred'),
    'The app': t('admin.where_the_app_appears_on_the'),
    'Rewards': t('admin.what_a_reward_may_be_paid'),
    'Completion': t('admin.how_a_kill_is_checked_and'),
    'Handovers': t('admin.what_a_live_handover_asks_of'),
    'Stakes': t('admin.the_stake_a_hitman_is_shown'),
    'Buyouts': t('admin.whether_a_target_may_buy_a'),
    'Targeting': t('admin.how_a_placer_finds_a_target'),
    'Messages and calls': t('admin.the_anonymous_messages_and_calls_between'),
    'Proposals': t('admin.changes_placer_and_hitman_may_agree'),
    'Notifications': t('admin.phone_notices_players_get'),
    'The clock': t('admin.when_a_contracts_deadline_stops'),
    'Anti-collusion': t('admin.one_account_as_two_parties_to'),
    'Record: Progression': t('admin.criminal_trust_for_completed_contracts'),
    'Audit and debug': t('admin.what_the_log_keeps_and_alerts'),
    'Staff tools': t('admin.pausing_the_whole_app_for_an'),
    'Staff alerts': t('admin.when_one_player_or_one_target'),
    'Contract limits': t('admin.how_long_contracts_run_and_how'),
    'Target limits': t('admin.the_waits_and_caps_on_one'),
    'Server restart': t('admin.how_contracts_pause_before_a_txadmin'),
    'Ledger': t('admin.what_a_players_ledger_keeps_and'),
    'Immunity': t('admin.who_cannot_be_a_target_yet'),
    'Payouts': t('admin.how_many_times_a_contract_pays'),
    'Intel prices': t('admin.what_each_informant_look_up_and'),
    'Anonymity fees': t('admin.what_staying_anonymous_costs_the_placer'),
    'Escrow': t('admin.what_a_reward_may_never_hold'),
    'Buyout pricing': t('admin.what_a_target_pays_to_buy'),
    'Staff': t('admin.limits_on_what_staff_may_do'),
    'Contract reasons': t('admin.what_a_placer_must_give_as'),
    'Advisory job lists': t('admin.which_jobs_raise_a_police_advisory'),
    'Barred jobs': t('admin.jobs_that_may_not_use_the'),
    'Storage': t('admin.where_contracts_and_money_are_kept'),
    'Diagnostics': t('admin.what_the_console_says_about_slow'),
    'Rate limits': t('admin.how_often_each_player_may_send'),
    'Staff commands': t('admin.the_names_of_the_staff_commands'),
    'Other scripts': t('admin.which_of_your_other_scripts_each'),
    'Edit in config.lua': t('admin.settings_this_panel_never_changes_edit'),
    'Kept in the store, not on this list': t('admin.panel_changes_for_keys_this_version'),
    'Other': t('admin.settings_not_in_any_group_above')
  };
  });

  /* ---- Game rules: by feature area, not by type ----

     Every rules and features setting under the area of the game it is
     about (the catalogue's `area`), the area's switches first, then its
     numbers, lists and choices in their groups, each row with its type.
     Filter chips narrow it to Switches, Timers, Money, Limits, Lists or
     what was changed from the panel; across every area when none is
     picked. Target limits, the organisation's and the Developer section's
     own settings are in their sections, and the lists of places in
     Locations. */

  var AREAS;
  Text.later(function () {
    AREAS = [
    { id: 'access', label: t('admin.who_can_use_the_app'), icon: 'door-open' },
    { id: 'placing', label: t('admin.placing_contracts'), icon: 'file-signature' },
    { id: 'anonymity', label: t('admin.anonymity'), icon: 'mask' },
    { id: 'rewards', label: t('admin.rewards_payouts'), icon: 'sack-dollar' },
    { id: 'completing', label: t('admin.completing_a_contract'), icon: 'flag-checkered' },
    { id: 'buyouts', label: t('admin.buyouts'), icon: 'hand-holding-dollar' },
    { id: 'intel', label: 'Intel', icon: 'user-secret' },
    { id: 'record', label: t('admin.record_standing'), icon: 'star' },
    { id: 'police', label: t('admin.police_city_news'), icon: 'shield-halved' },
    { id: 'messages', label: t('admin.phone_messages_notifications'), icon: 'comment' },
    { id: 'extras', label: t('admin.roleplay_extras'), icon: 'masks-theater' },
    { id: 'staff', label: t('admin.staff_tools_alerts'), icon: 'user-shield' },
    { id: 'other', label: t('admin.other'), icon: 'ellipsis' }
  ];
  });
  var AREA_ELSEWHERE;
  Text.later(function () {
    AREA_ELSEWHERE = { targets: t('admin.target_limits'), organisation: t('admin.hitman_organisation'), engine: t('admin.developer') };
  });
  function areaLabel(id) {
    for (var i = 0; i < AREAS.length; i++) if (AREAS[i].id === id) return AREAS[i].label;
    return AREA_ELSEWHERE[id] || String(id || t('admin.other'));
  }
  Text.later(function () {
    window.CH_ADMIN_AREAS = AREAS;
  });
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

  var TYPE_FILTERS;
  Text.later(function () {
    TYPE_FILTERS = [{ value: '', label: t('admin.all') }, { value: 'switch', label: t('admin.switches') },
    { value: 'timer', label: t('admin.timers') }, { value: 'money', label: t('admin.money') }, { value: 'limit', label: t('admin.limits') },
    { value: 'list', label: t('admin.lists') }, { value: 'changed', label: t('admin.changed') }];
  });
  /** Search shows at most this many rows, rather than drawing everything. */
  var SEARCH_ROWS = 50;

  function typeHit(entry, type) {
    if (!type) return true;
    if (type === 'changed') return entry.source === 'panel' || !!entry.ignored || !!entry.unknown;
    return typeOf(entry) === type;
  }
  function textHit(entry, q) {
    if (!q) return true;
    return [entry.key, entry.label, entry.about, entry.group, entry.groupLabel, entry.money, entry.moneyLabel,
      areaLabel(areaOf(entry))]
      .map(function (v) { return v == null ? '' : String(v); }).join(' ').toLowerCase().indexOf(q) !== -1;
  }

  function settingsHead() {
    var d = S.settings.data;
    var overrides = d ? Number(d.overrides) || 0 : 0;
    var view = S.section;
    var undoAll = overrides > 0 || (d && Number(d.stored) > 0) ? writeBtn('.danger.is-small', 'st-reset-all', {},
      t('admin.undo_all_panel_changes'), t('admin.click_again_back_to_config_lua'), 'arrow-rotate-left') : null;
    if (view === 'changed') {
      return frag(h('span.sub', num(overrides) + t('admin.changed_from_the_panel_3')
        + (d && Number(d.notApplied) > 0 ? ', ' + num(d.notApplied) + t('admin.kept_and_not_applied') : '')),
        // Whenever the store holds a row, applied or not: one not applied (a
        // key from another version among them) is cleared by it too.
        undoAll);
    }
    return frag(
      h('label.search', icon('magnifying-glass'),
        field('st.q', { id: 'st-q', placeholder: view === 'rules' ? t('admin.filter_by_name_key_or_description')
          : t('admin.search_by_name_key_description_or'), 'data-live': 'st-filter', 'aria-label': t('admin.filter_the_settings') })),
      view === 'rules' ? h('div.seg.gr-types', { role: 'group' }, TYPE_FILTERS.map(function (o) {
        var on = o.value === S.rules.type;
        return h('button.seg-btn' + (on ? '.is-on' : ''), { type: 'button', 'data-act': 'gr-type',
          'data-value': o.value, 'aria-pressed': on ? 'true' : 'false' }, o.label);
      })) : null,
      h('span.sub', num(overrides) + t('admin.changed_from_the_panel_3')
        + (d && Number(d.notApplied) > 0 ? ', ' + num(d.notApplied) + t('admin.kept_and_not_applied') : '')),
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
          per.source === 'panel' || burst.source === 'panel' ? h('span.chip.is-panel', t('admin.changed_from_the_panel_2')) : null),
        h('code.st-key', 'Config.Cooldowns.' + bucket + ' = { per, burst }'),
        per.about ? h('p.st-about', String(per.about).replace(/ A full allowance refills.*$/, '')) : null,
        h('p.st-about.is-warn', t('admin.making_it_stricter_refuses_players_at_2')),
        h('p.st-source', t('admin.now_refills_over') + num(per.value) + ' s, ' + num(burst.value) + t('admin.held_config_lua')
          + num(per.default) + ' s, ' + num(burst.default)),
        answerBox(answer)),
      h('div.st-control', h('div.st-edit',
        h('label.st-pair', h('span', t('admin.per')),
          field('st.Cooldowns.' + bucket + '.per', { value: String(typedOr('st.Cooldowns.' + bucket + '.per', per.value)),
            class: 'is-short', inputmode: 'decimal', disabled: !open, 'aria-label': bucket + t('admin.refill_window') })),
        h('label.st-pair', h('span', 'burst'),
          field('st.Cooldowns.' + bucket + '.burst', { value: String(typedOr('st.Cooldowns.' + bucket + '.burst', burst.value)),
            class: 'is-short', inputmode: 'numeric', disabled: !open, 'aria-label': bucket + t('admin.requests_held') })),
        writeBtn('.is-small', 'st-map-save', { 'data-bucket': bucket, id: 'st-save-Cooldowns.' + bucket }, t('admin.save'),
          t('admin.click_again_to_save'), 'check', false, open))));
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
      var g = String(entry.group || t('admin.other'));
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
    return h('section.st-group', { 'data-group': g.toLowerCase() }, h('h3.st-group-title', (rows[0] && rows[0].groupLabel) || g),
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
    return h('nav.gr-areas', { 'aria-label': t('admin.areas') },
      h('button.gr-area' + (!S.rules.area ? '.is-on' : ''), { type: 'button', 'data-act': 'gr-area', 'data-value': '' },
        icon('layer-group'), h('span.lbl', t('admin.all_areas')), h('span.gr-n', num(total))),
      AREAS.filter(function (a) { return counts[a.id] || (!S.rules.type && a.id !== 'other'); }).map(function (a) {
        return h('button.gr-area' + (S.rules.area === a.id ? '.is-on' : ''), { type: 'button', 'data-act': 'gr-area',
          'data-value': a.id }, icon(a.icon), h('span.lbl', a.label), h('span.gr-n', num(counts[a.id] || 0)),
          changed[a.id] ? h('span.chip.is-panel', t('admin.n_changed', num(changed[a.id]))) : null);
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
          h('span.sub', num(mine.length) + t('admin.settings') + num(switches) + ' switch' + (switches === 1 ? '' : 'es')));
      }));
    } else if (!rows.length) {
      body = empty(q ? t('admin.no_setting_matches_clear_the_filter') : t('admin.nothing_here_with_this_filter'));
    } else {
      var shown = rows.slice(0, q ? SEARCH_ROWS : rows.length);
      var gr = grouped(shown, 'rules');
      body = frag(
        rows.length > shown.length ? h('p.note', t('admin.the_first_of_matches', num(shown.length), num(rows.length))) : null,
        gr.groups.map(function (g) { return groupSection(g, gr.byGroup[g]); }));
    }
    var memory = S.overview && S.overview.storage === 'memory';
    return h('div.gr',
      areaNav(all),
      h('div.gr-rows',
        h('p.hint', t('admin.every_setting_under_the_area_of')
          + t('admin.effect_at_once_and') + (memory ? t('admin.lasts_until_the_resource_stops_this')
          + t('admin.keeps_nothing_across_a_restart') : t('admin.is_kept_across_restarts')) + t('admin.what_is_already_under_way_finishes')
          + t('admin.under_the_rules_it_started_with')),
        body));
  }

  function settingsList() {
    var d = S.settings.data;
    if (!d) return loading(t('admin.reading_the_settings'));
    var view = S.section;
    if (view === 'rules') return rulesList();
    var q = trim(S.forms['st.q']).toLowerCase();
    var list = settingRowsFor(view).filter(function (e) { return view === 'changed' || textHit(e, q); });
    if (view === 'changed') {
      if (!list.length) return empty(t('admin.nothing_is_changed_from_the_panel'));
      var gc = grouped(list, 'changed');
      return frag(h('p.hint', t('admin.every_setting_changed_from_this_panel')
        + t('admin.puts_every_one_back_to_config')),
        gc.groups.map(function (g) { return groupSection(g, gc.byGroup[g]); }));
    }
    var buckets = view === 'devsettings' ? mapBuckets(list) : [];
    var inMap = {};
    buckets.forEach(function (b) { inMap['Cooldowns.' + b + '.per'] = inMap['Cooldowns.' + b + '.burst'] = true; });
    var gr = grouped(list.filter(function (e) { return !inMap[e.key]; }), view);
    var intro = VIEW_INTRO[view] || '';
    var note = view === 'devsettings' && S.access.developerHint ? h('p.hint.is-note', String(S.access.developerHint)) : null;
    if (!gr.groups.length && !buckets.length) {
      return frag(h('p.hint', intro), note, empty(q ? t('admin.no_setting_matches') : t('admin.nothing_here')));
    }
    return frag(h('p.hint', intro), note, gr.groups.map(function (g) { return groupSection(g, gr.byGroup[g]); }),
      buckets.length ? h('section.st-group', { 'data-group': 'rate limits' }, h('h3.st-group-title', t('admin.rate_limits')),
        h('p.st-group-about', t('admin.per_player_a_full_allowance_of')),
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
      if (raw === '' || !/^-?\d*\.?\d+$/.test(raw)) return { error: t('admin.not_changed') + entry.key + t('admin.has_to_be_a_number') };
      var n = Number(raw);
      if (entry.integer && Math.floor(n) !== n) return { error: t('admin.not_changed') + entry.key + t('admin.has_to_be_a_whole_number') };
      if ((entry.min != null && n < entry.min) || (entry.max != null && n > entry.max)) {
        return { error: t('admin.not_changed_has_to_be_from', entry.key, entry.min, entry.max) };
      }
      return { value: n };
    }
    if (entry.kind === 'text') {
      var word = trim(text);
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(word)) {
        return { error: t('admin.not_changed') + entry.key + t('admin.is_letters_digits_and_only') };
      }
      return { value: word };
    }
    if (entry.kind === 'list') {
      var names = trim(text).split(/[\s,]+/).filter(function (s) { return s.length > 0; });
      for (var i = 0; i < names.length; i++) {
        if (!/^[A-Za-z0-9_-]{1,32}$/.test(names[i])) {
          return { error: t('admin.not_changed_job_names_are_letters') };
        }
      }
      if (names.length > 50) return { error: t('admin.not_changed') + entry.key + t('admin.takes_at_most_50_names') };
      return { value: names };
    }
    return { error: t('admin.not_a_setting_the_panel_may') };
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
    var tv = S.tools;
    return frag(
      h('div.cols',
        card(t('admin.bring_timers_forward'), frag(
          h('p.about', t('admin.test_servers_only_brings_every_wait')
            + t('admin.moved_later_audited')),
          h('div.btn-row', writeBtn('.danger', 'tl-refresh', {}, t('admin.bring_timers_forward'), t('admin.click_again_test_servers_only'), 'forward')),
          tv.refresh ? answerBox(tv.refresh.answer) : null,
          tv.refresh ? linesBox(tv.refresh.lines) : null)),
        card(t('admin.audit_log'), frag(
          h('p.about', t('admin.writes_every_queued_row_of_the')
            + t('admin.works_while_recovery_holds_everything_else')),
          h('div.btn-row', writeBtn('', 'tl-flush', {}, t('admin.flush_the_audit_log'), t('admin.click_again_to_flush'), 'floppy-disk', true)),
          tv.flush ? answerBox(tv.flush) : null))),
      h('p.hint', t('admin.the_diagnosis_is_under_health_and')));
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
    return canWrite() ? frag(writeBtn('.is-small.ghost', 'tl-flush', {}, t('admin.flush_the_audit_log'), t('admin.click_again_to_flush'),
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
  var MEASURE_KINDS;
  Text.later(function () {
    MEASURE_KINDS = [
    { id: '', label: t('admin.all') },
    { id: 'freeze', label: t('admin.frozen'), chip: '.is-warn.is-frozen', none: t('admin.nobody_is_frozen'), lift: 'unfreeze',
      liftLabel: t('admin.unfreeze'), confirm: function () { return t('admin.click_again_to_unfreeze'); }, icon: 'play' },
    { id: 'suspend', label: t('admin.suspended'), chip: '.is-warn.is-suspended', none: t('admin.nobody_is_suspended'),
      lift: 'unsuspend', liftLabel: t('admin.lift'), icon: 'unlock',
      confirm: function (row) { return t('admin.click_again_lift_for') + String(row.name || 'them'); } },
    { id: 'protect', label: t('admin.protected'), chip: '.is-protected', none: t('admin.nobody_is_protected'), lift: 'unprotect',
      liftLabel: t('admin.lift'), icon: 'unlock',
      confirm: function (row) { return t('admin.click_again_lift_for') + String(row.name || 'them'); } },
    { id: 'limit', label: t('admin.own_target_limits'), chip: '', none: t('admin.nobody_has_target_limits_of_their') }
  ];
  });
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
    if (!d) return loading(t('admin.reading_the_measures_in_force'));
    if (d.error) return empty(d.error);
    var kind = measureKind(S.players.measureKind || '');
    var rows = asList(d.rows).filter(function (r) { return !kind.id || r.kind === kind.id; });
    var counts = {};
    asList(d.rows).forEach(function (r) { counts[r.kind] = (counts[r.kind] || 0) + 1; });
    return frag(
      segmented('ms-kind', MEASURE_KINDS.map(function (k) {
        return { value: k.id, label: k.label + (k.id ? ' (' + num(counts[k.id] || 0) + ')' : '') };
      }), kind.id),
      card(kind.id ? t('admin.kind_players', kind.label) : t('admin.every_measure_in_force'), rows.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.player')), h('th', t('admin.since')), h('th', t('admin.until')), h('th', t('admin.reason')), h('th', ''))),
        h('tbody', rows.map(function (row) {
          var k = measureKind(row.kind);
          var ref = String(row.ref || '');
          var answer = S.players.lift[row.kind + ':' + ref];
          return frag(h('tr',
            h('td.name', String(row.name || t('admin.no_name_on_record')), row.cid ? h('span.cid', String(row.cid)) : null,
              h('span.chip' + (k.chip || ''), k.label + (row.kind === 'limit' ? (row.exempt ? ': exempt' : '') : '')),
              row.online ? h('span.chip.is-live', t('admin.in_the_city')) : null,
              row.cid ? h('div.party', btn('.is-small.ghost', 'pl-open-cid', { 'data-value': String(row.cid) },
                t('admin.open'), 'arrow-right')) : null),
            h('td.nowrap', { title: when(row.since) }, ago(row.since)),
            h('td.nowrap', row['until'] ? when(row['until'])
              : row.kind === 'suspend' ? t('admin.until_lifted') : row.kind === 'freeze' ? t('admin.until_unfrozen') : t('admin.for_good_3')),
            h('td', String(row.reason || '—')),
            h('td', k.lift ? modBtn('.is-small', 'pl-lift-row', { 'data-ref': ref, 'data-value': row.kind },
              k.liftLabel, k.confirm(row), k.icon)
              : h('span.sub', { title: t('admin.lift_it_in_target_limits_per') },
                t('admin.in_target_limits')))),
            answer ? h('tr.more', h('td', { colspan: '5' }, answerBox(answer))) : null);
        })))) : empty(kind.id ? kind.none : t('admin.no_measure_is_in_force_on')), '', h('span.sub', num(rows.length))));
  }

  SHELL.measures = function () {
    return h('section.view',
      h('p.hint', t('admin.every_measure_staff_have_put_on')
        + t('admin.suspended_barred_from_placing_and_accepting')
        + t('admin.their_own_target_limits_put_one')
        + t('admin.own_target_limits_in_target_limits')),
      h('div.stack', { id: 'pl-measures' }, measuresListCard()));
  };
  LOAD.measures = function () { loadMeasures(); };

  /* ---- staff actions: every write the panel has, in one place ----

     Each card opens the flow that already does it, in the view it lives
     in; nothing here writes on its own. */

  var STAFF_ACTIONS;
  Text.later(function () {
    STAFF_ACTIONS = [
    { title: t('admin.freeze_or_unfreeze_a_player'), icon: 'snowflake', view: 'players', go: t('admin.players'),
      text: t('admin.look_the_player_up_then_freeze')
        + t('admin.hold_its_clocks_stop_and_nothing')
        + t('admin.listed_under_players_all_measures_each'),
      also: { view: 'measures', go: t('admin.all_measures') } },
    { title: t('admin.suspend_or_protect_a_player'), icon: 'ban', view: 'players', go: t('admin.players'),
      text: t('admin.look_the_player_up_then_measures')
        + t('admin.contracts_naming_them_players_all_measures'),
      also: { view: 'measures', go: t('admin.all_measures') } },
    { title: t('admin.pay_a_player_or_set_their'), icon: 'sack-dollar', view: 'players', go: t('admin.players'),
      text: t('admin.look_the_player_up_then_money')
        + t('admin.playtime_sets_the_hours_counted_for') },
    { title: t('admin.void_a_contract'), icon: 'ban', view: 'contracts', go: t('admin.contracts'),
      text: t('admin.open_the_contract_from_contracts_then')
        + t('admin.reason_kept_in_the_log') },
    { title: t('admin.refund_or_pay'), icon: 'scale-balanced', view: 'inbox:reviews', go: t('admin.inbox_needs_review'),
      text: t('admin.needs_review_holds_the_contracts_a')
        + t('admin.stuck_escrow_holds_the_money_left'),
      also: { view: 'inbox:stuck', go: t('admin.money_waiting_2') } },
    { title: t('admin.deadlines'), icon: 'clock', view: 'contracts', go: t('admin.contracts'),
      text: t('admin.open_the_contract_from_contracts_then_2')
        + t('admin.1_h_2_h_or_a')
        + t('admin.and_after_players_are_told_only')
        + t('admin.voiding_ends_it') },
    { title: t('admin.announce'), icon: 'bullhorn', view: 'announce', go: 'Home, Announce',
      text: t('admin.one_phone_notice_from_staff_to')
        + t('admin.it_never_names_you_takes_two') },
    { title: t('admin.test_tools'), icon: 'screwdriver-wrench', view: 'tools', go: t('admin.test_tools'),
      text: t('admin.bring_timers_forward_test_servers_only')
        + t('admin.health_and_on_a_players_card'), also: { view: 'logs', go: t('admin.logs') } },
    { title: t('admin.settings_2'), icon: 'sliders', view: 'rules', go: t('admin.game_rules'),
      text: t('admin.every_rule_is_in_game_rules')
        + t('admin.by_switches_timers_money_limits_or')
        + t('admin.two_clicks'), also: { view: 'changed', go: t('admin.changed_from_the_panel') } },
    { title: t('admin.undo_a_setting_change'), icon: 'arrow-rotate-left', view: 'logs:settings', go: t('admin.logs_setting_changes'),
      text: t('admin.history_lists_every_setting_changed_from')
        + t('admin.undo_puts_the_value_before_back') },
    { title: t('admin.contract_tools'), icon: 'clipboard-list', view: 'contracts', go: t('admin.contracts'),
      text: t('admin.open_a_contract_staff_notes_remove')
        + t('admin.optionally_barred_edit_text_through_the')
        + t('admin.ticket_and_as_a_player_sees') }
  ];
  });

  /** Help > How do I...: every staff action, each card's Go opening where
      it is done (shown only where this staff member may open it). */
  SHELL.howto = function () {
    return h('section.view',
      h('p.hint', canWrite() ? t('admin.everything_here_changes_something_and_takes')
        + t('admin.it_is_done_the_header_search') : whyNoWrite()),
      h('div.cards-grid', STAFF_ACTIONS.map(function (a) {
        var go = resolveView(a.view);
        return card(frag(icon(a.icon), ' ', a.title), frag(
          h('p.about', a.text),
          h('div.btn-row', viewAllowed(go) ? btn('.is-small', 'section', { 'data-section': a.view }, t('admin.go_x', a.go),
            'arrow-right') : h('p.note', t('admin.needs_ace', DEV_VIEWS[go] ? t('admin.the_developer_ace') : t('admin.the_staff_ace'))),
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
    if (!rows.length) return empty(t('admin.the_server_did_not_say_which'));
    return frag(
      h('p.hint', t('admin.every_ace_this_resource_checks_what')
        + t('admin.an_ace_grant_one_in_the')),
      canDevelop() || !S.access.developerAce ? null : h('p.hint.is-note', t('admin.the_developer_section_needs')
        + String(S.access.developerAce) + t('admin.or_the_staff_ace_itself')),
      h('div.stack', rows.map(function (p) {
        var held = p.held === true;
        return h('section.card.perm-row', { 'data-ace': String(p.ace) },
          h('header.card-head', h('h3', String(p.name || p.ace)),
            h('span.chip' + (held ? '.is-ok' : ''), { class: held ? 'perm-held' : 'perm-missing' },
              held ? t('admin.you_hold_it') : t('admin.you_do_not_hold_it'))),
          h('code.st-key', String(p.ace)),
          h('p.about', String(p.unlocks || '')),
          held ? null : h('p.perm-grant', h('b', t('admin.to_grant_it')), String(p.grant || '')));
      })));
  }
  SHELL.permissions = function () { return h('section.view', h('div.stack', { id: 'pm' }, permissionsBody())); };
  LOAD.permissions = function () {};

  /* ---- how it works ----

     Plain words on what the resource does, written from the code and the
     README; each card links to the settings that control it. Edit the text
     here: it is the one place it is kept. */

  var HELP;
  Text.later(function () {
    HELP = [
    { title: t('admin.a_contract_start_to_finish'), icon: 'file-contract',
      text: t('admin.a_player_places_a_contract_on')
        + t('admin.at_once_and_held_in_escrow')
        + t('admin.board_as_shipped_a_contract_is')
        + t('admin.alive_to_the_person_who_placed')
        + t('admin.either_a_verified_kill_completes_it')
        + t('admin.contract_has_payout_slots'),
      links: [{ key: 'Completion.Fulfilment', label: t('admin.how_contracts_are_completed') },
        { key: 'Kidnap.CountdownSeconds', label: t('admin.handover_countdown') },
        { key: 'Limits.MaxPayoutSlots', label: t('admin.payout_slots') },
        { key: 'Limits.MinContractReward', label: t('admin.least_reward') }] },
    { title: t('admin.the_clock_and_the_time_bands'), icon: 'clock',
      text: t('admin.a_contract_runs_for_its_deadline')
        + t('admin.placer_the_target_and_at_least')
        + t('admin.exact_time_each_card_shows_a')
        + t('admin.15_minutes_left_every_contract_also')
        + t('admin.the_target_is_in_prison_a'),
      links: [{ key: 'Limits.DefaultDeadlineSeconds', label: t('admin.deadline') },
        { key: 'Limits.ContractLifetimeSeconds', label: t('admin.hard_ceiling') },
        { key: 'Holds.RestartPauseBeforeSeconds', label: t('admin.restart_pause') },
        { key: 'Limits.PauseWhileTargetJailed', label: t('admin.pause_while_jailed') }] },
    { title: t('admin.anonymity'), icon: 'mask',
      text: t('admin.a_contract_can_be_placed_or')
        + t('admin.does_not_when_it_is_allowed')
        + t('admin.and_only_staff_with_the_identity')
        + t('admin.whitelisted_job_target_police_ems_and'),
      links: [{ key: 'TargetClasses.default.AllowAnonymousPlacer', label: t('admin.anonymous_placing') },
        { key: 'TargetClasses.default.AllowAnonymousHitman', label: t('admin.anonymous_accepting') },
        { key: 'TargetClasses.whitelisted.AllowAnonymousPlacer',
          label: t('admin.on_whitelisted_job_targets') },
        { key: 'Anonymity.CreatorFee', label: t('admin.anonymity_fees') }] },
    { title: t('admin.the_informants'), icon: 'user-secret',
      text: t('admin.three_paid_look_ups_each_off')
        + t('admin.is_after_them_with_a_chance')
        + t('admin.operative_took_the_contract_the_informant')
        + t('admin.one_master_switch_turns_all_three'),
      links: [{ key: 'Intel.Enabled', label: t('admin.master_switch_2') },
        { key: 'Intel.Informant.Enabled', label: t('admin.targets_informant') },
        { key: 'Intel.PlacerInformant.Enabled', label: t('admin.placers_informant') },
        { key: 'Intel.LocationTip.Enabled', label: t('admin.informant_tip') },
        { key: 'Intel.Informant.Cost', label: t('admin.prices') }] },
    { title: t('admin.buyouts'), icon: 'hand-holding-dollar',
      text: t('admin.a_target_can_pay_to_buy')
        + t('admin.is_the_reward_times_a_multiplier')
        + t('admin.hitman_holds_gives_them_a_head')
        + t('admin.buy_out'),
      links: [{ key: 'Bailout.Enabled', label: t('admin.buyouts_on_or_off') },
        { key: 'Bailout.MinMultiplier', label: t('admin.buyout_price') },
        { key: 'Bailout.ProcessingDelaySeconds', label: t('admin.hitmans_head_start') }] },
    { title: t('admin.the_staff_freeze'), icon: 'snowflake',
      text: t('admin.staff_with_the_staff_or_moderator')
        + t('admin.every_live_contract_they_are_party_2')
        + t('admin.paid_refunded_or_ended_players_are')
        + t('admin.on_hold_back_to_the_second'),
      links: [] },
    { title: t('admin.police_advisories'), icon: 'shield-halved',
      text: t('admin.when_a_contract_is_placed_on')
        + t('admin.advisory_and_an_sc_dispatch_entry')
        + t('admin.accepted_given_an_informant_tip_or')
        + t('admin.card_is_marked_on_the_board'),
      links: [{ key: 'Advisory.Enabled', label: t('admin.advisories_on_or_off') },
        { key: 'Advisory.OnCreate', label: t('admin.when_they_go_out') },
        { key: 'Advisory.RecipientJobNames', label: t('admin.who_is_told') }] },
    { title: t('admin.money_safety'), icon: 'vault',
      text: t('admin.every_reward_is_held_in_escrow')
        + t('admin.be_paid_or_returned_a_contract')
        + t('admin.who_is_offline_or_whose_inventory')
        + t('admin.the_server_could_not_settle_on')
        + t('admin.goes_to_needs_review'),
      links: [{ key: 'PendingEscrow.MaxRetriesPerLogin', label: t('admin.owed_payouts') },
        { key: 'MaxContractValue', label: t('admin.most_a_contract_holds') },
        { key: 'EscrowBlacklist', label: t('admin.items_never_in_a_reward') }] }
  ];
  });
  /** For the tests. */
  Text.later(function () {
    window.CH_ADMIN_HELP = HELP;
  });

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
    return h('section.view', h('p.hint', t('admin.how_the_contract_app_works_in_2')
      + t('admin.the_setting_that_controls_it')),
      h('div.toolbar', btn('.is-small.ghost', 'help-all', {}, t('admin.open_all'), 'angles-down'),
        btn('.is-small.ghost', 'help-none', {}, t('admin.close_all'), 'angles-up')),
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
    if (!S.presets.data) return loading(t('admin.reading_the_presets'));
    var list = asList(S.presets.data.presets);
    return frag(answerBox(S.presets.answer),
      h('div.btn-row', writeBtn('.ghost.is-small', 'ps-save', {}, t('admin.save_the_settings_now_as_current'),
        t('admin.click_again_save_as_current'), 'floppy-disk')),
      h('div.btn-row', field('ps.name', { placeholder: t('admin.name_for_a_preset_of_your'), maxlength: '32',
        'aria-label': t('admin.name_for_a_preset_of_your') }),
        writeBtn('.is-small', 'ps-own', {}, t('admin.save_the_panels_changes_as_a'),
          t('admin.click_again_save_them_under_that'), 'box-archive')),
      h('div.cards-grid', list.map(function (p) {
        var changes = asList(p.changes), refused = asList(p.refused);
        var n = changes.length;
        return card(String(p.name), frag(
          p.about ? h('p.about', String(p.about)) : null,
          n ? h('ul.plain.ps-changes', changes.map(function (c) {
            return h('li', h('span.name', String(c.label)), ': ', h('span.mono', String(c.from)), ' \u2192 ',
              h('span.mono', String(c.to)));
          })) : h('p.note', t('admin.nothing_to_change_the_settings_are')),
          refused.length ? h('ul.warnings', refused.map(function (r) {
            return h('li', String(r.label) + t('admin.left_as_it_is') + String(r.why));
          })) : null,
          Number(p.same) > 0 ? h('p.sub', num(p.same) + t('admin.more_already_as_this_preset_says')) : null,
          h('div.btn-row', writeBtn('.primary.is-small', 'ps-apply', { 'data-value': String(p.name), disabled: !n || null },
            t('admin.apply_x', String(p.name)), tn('admin.click_again_apply_changes', n), 'check'),
            p.own ? writeBtn('.danger.is-small', 'ps-delete', { 'data-value': String(p.name) },
              t('admin.delete'), t('admin.click_again_delete') + String(p.name), 'trash') : null)),
          '.ps-card', h('span.chip' + (p.builtIn ? '' : '.is-panel'), p.builtIn ? 'shipped' : p.own ? 'yours' : 'saved'));
      })));
  }

  SHELL.presets = function () {
    return h('section.view',
      h('p.hint', t('admin.a_preset_changes_nothing_until_you')
        + t('admin.first_so_going_back_is_applying')),
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
    orgwork: { view: 'orgsetup' }, orgarmory: { view: 'orgsetup' }, orgrecord: { view: 'orgsetup' },
    orgturf: { view: 'orgsetup' },
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
    if (!S.settings.data) return loading(t('admin.reading_the_settings'));
    var rows = gearEntries(S.section);
    var gr = grouped(rows, 'rules');
    return card(t('admin.settings_for_this_screen'), frag(
      h('p.hint', t('admin.the_settings_this_screen_works_by')
        + t('admin.undone_from_change_history')),
      rows.length ? gr.groups.map(function (g) { return groupSection(g, gr.byGroup[g]); })
        : empty(t('admin.this_screen_has_no_settings_of')),
      h('div.btn-row', btn('.is-small.ghost', 'section', { 'data-section': 'rules' }, t('admin.all_settings'), 'sliders'))),
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
  /* A preset of the server's own (server/presets.lua, X5): the settings
     changed from the panel now, under the name typed; and deleting one. */
  ACTIONS['ps-own'] = function (node) {
    var name = trim(S.forms['ps.name']);
    if (!name) { S.presets.answer = { ok: false, text: t('admin.name_the_preset_first') }; drawPresets(); return; }
    if (!confirmed(node)) return;
    write('presetSaveOwn', { name: name }, 'preset', node).then(function (reply) {
      if (!reply) return;
      S.presets.answer = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
      if (reply.ok) S.forms['ps.name'] = '';
      loadPresets();
    });
  };
  ACTIONS['ps-delete'] = function (node) {
    if (!confirmed(node)) return;
    write('presetDelete', { name: node.getAttribute('data-value') }, 'preset', node).then(function (reply) {
      if (!reply) return;
      S.presets.answer = { ok: reply.ok === true, text: words(reply) };
      toast(words(reply), reply.ok ? 'ok' : 'error');
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
      if (row.kind === 'switch') return [{ value: 'true', label: t('admin.on') }, { value: 'false', label: t('admin.off') }];
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
    if (!su.data) return loading(t('admin.reading_the_setup'));
    var d = su.data;
    var cmd = d.command || {};
    var cmdBind = 'su.command';
    var preview = su.preview;
    var n = preview ? asList(preview.changes).length : 0;
    return frag(
      answerBox(su.answer),
      d.saved ? h('p.note', t('admin.saved_before') + (d.savedBy ? t('admin.by_x', String(d.savedBy)) : '') + t('admin.change_anything')
        + t('admin.and_apply_again_or_leave_it')) : h('p.hint', t('admin.nothing_is_saved_yet_this_screen')
        + t('admin.every_choice_starts_at_what_is')),
      h('div.cols',
        card(t('admin.storage'), frag(
          h('p.about', t('admin.where_contracts_and_money_are_kept_2')
            + t('admin.set_it_in_config_lua_a')),
          h('p', t('admin.in_force'), h('span.mono', String((d.storage || {}).mode || ''))),
          h('pre.output', String((d.storage || {}).line || '')))),
        card(t('admin.permissions'), frag(
          h('p.about', t('admin.the_lines_that_grant_the_panel')),
          h('ul.plain', asList(d.aces).map(function (a) {
            return h('li', icon(a.held ? 'circle-check' : 'circle'), ' ', String(a.name), h('pre.output', String(a.line)));
          }))))),
      card(t('admin.other_scripts'), frag(
        h('p.about', t('admin.auto_uses_the_first_one_installed')),
        h('ul.plain', asList(d.integrations).map(function (r) {
          var seen = asList(r.detected).map(function (x) { return x.up ? t('admin.name_running', String(x.name)) : String(x.name); });
          return h('li.su-int', setupChoice({ key: r.key, label: r.kind }),
            h('p.sub', t('admin.in_use_found', r.active ? t('admin.in_use') + String(r.active) : t('admin.off_x', String(r.without)),
              seen.length ? seen.join(', ') : t('admin.none_word'))));
        })))),
      card(t('admin.panel_command_and_key_switches'), frag(
        h('div.su-row', h('span.name', String(cmd.label || t('admin.panel_command'))),
          field(cmdBind, { value: String(setupValue(cmd.key, cmd.value) || ''), maxlength: '32' })),
        asList(d.switches).map(function (r) { return setupChoice(r); }))),
      card(t('admin.preview'), frag(
        preview ? frag(
          n ? h('ul.plain.ps-changes', asList(preview.changes).map(function (c) {
            return h('li', h('span.name', String(c.label)), ': ', h('span.mono', String(c.from)), ' → ',
              h('span.mono', String(c.to)));
          })) : h('p.note', t('admin.nothing_to_change_applying_saves_the')),
          asList(preview.refused).length ? h('ul.warnings', asList(preview.refused).map(function (r) {
            return h('li', String(r.label) + t('admin.left_as_it_is') + String(r.why));
          })) : null) : h('p.hint', t('admin.preview_what_applying_would_change_nothing')),
        h('div.btn-row',
          btn('.ghost', 'su-preview', {}, t('admin.preview'), 'eye'),
          writeBtn('.primary', 'su-apply', { disabled: !preview || null }, t('admin.apply'),
            tn('admin.click_again_apply_changes', n) + t('admin.and_save'), 'check')))));
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

  /* ---------- Developer > Export and import (server/settingsio.lua) ----

     Export: every setting changed from the panel and this server's own
     presets as one JSON text, to copy. Not in it: the map places
     (Locations) and the target limits set for a job or a player (Target
     limits). Import: paste a text and Read it: every change it would make
     (from, to), every key it refuses and why, and the presets it would add,
     with nothing changed; Apply then takes two clicks naming how many
     changes, each one a setting change of its own in Change history with
     its Undo. */
  function transferBody() {
    var tv = S.transfer;
    var p = tv.preview;
    var changes = p ? asList(p.changes) : [], refused = p ? asList(p.refused) : [],
      presets = p ? asList(p.presets) : [];
    var adds = presets.filter(function (x) { return !x.why; }).length;
    var n = changes.length;
    return frag(answerBox(tv.answer),
      card(t('admin.export'), frag(
        h('p.about', t('admin.every_setting_changed_from_this_panel_2')
          + t('admin.into_another_server_not_in_it')
          + t('admin.player_target_limits_which_belong_to')),
        h('div.btn-row', btn('.primary', 'io-export', {}, t('admin.export_the_settings'), 'file-export'),
          tv.exported ? btn('', 'io-copy', {}, t('admin.copy'), 'copy') : null),
        tv.exported ? h('p.sub', t('admin.x_and_y', tn('admin.settings_count', Number(tv.exported.settings), num(tv.exported.settings)),
          tn('admin.presets_count', Number(tv.exported.presets), num(tv.exported.presets)))) : null,
        tv.exported ? h('textarea.input.ct-export-text', { readonly: 'readonly', rows: '8',
          'aria-label': t('admin.the_exported_settings_to_copy') }, String(tv.exported.text || '')) : null)),
      card(t('admin.import'), frag(
        h('p.about', t('admin.paste_an_exported_text_and_read')
          + t('admin.never_changes_from_the_panel_one')
          + t('admin.and_left_as_it_is')),
        h('textarea.input.ct-export-text', { 'data-bind': 'io.text', rows: '8',
          'aria-label': t('admin.the_exported_text_to_import') }, String(S.forms['io.text'] || '')),
        h('div.btn-row', btn('', 'io-read', {}, t('admin.read_it'), 'magnifying-glass')),
        tv.error ? answerBox({ ok: false, text: tv.error }) : null,
        p ? frag(
          n ? h('ul.plain.ps-changes', changes.map(function (c) {
            return h('li', h('span.name', String(c.label)), ': ', h('span.mono', String(c.from)), ' → ',
              h('span.mono', String(c.to)));
          })) : h('p.note', t('admin.no_setting_to_change_they_are')),
          refused.length ? h('ul.warnings', refused.map(function (r) {
            return h('li', String(r.label) + ' (' + String(r.key) + t('admin.left_as_it_is_2') + String(r.why));
          })) : null,
          Number(p.same) > 0 ? h('p.sub', num(p.same) + t('admin.more_already_as_that_text_says')) : null,
          presets.length ? h('ul.plain', presets.map(function (x) {
            return h('li', t('admin.preset_x', String(x.name), x.why ? t('admin.not_added') + String(x.why) : t('admin.added_word')));
          })) : null,
          h('div.btn-row', writeBtn('.primary', 'io-apply', { disabled: (!n && !adds) || null },
            t('admin.apply_it'), tn('admin.click_again_apply_changes', n)
              + (adds ? tn('admin.and_add_presets', adds) : ''), 'check'))) : null)));
  }

  function drawTransfer() {
    if (S.section === 'transfer') setHtml(byId('io-body'), transferBody());
  }

  SHELL.transfer = function () {
    return h('section.view', h('div.stack', { id: 'io-body' }, transferBody()));
  };
  LOAD.transfer = function () { drawTransfer(); };

  ACTIONS['io-export'] = function () {
    ask('settingsExport', {}, 'transfer').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) S.transfer.answer = { ok: false, text: words(reply) };
      else { S.transfer.exported = reply.data || {}; S.transfer.answer = null; }
      drawTransfer();
    });
  };
  ACTIONS['io-copy'] = function () {
    var copied = S.transfer.exported && copyText(String(S.transfer.exported.text || ''));
    toast(copied ? t('admin.copied') : t('admin.select_the_text_and_copy_it'), copied ? 'ok' : 'error');
  };
  ACTIONS['io-read'] = function () {
    var text = String(S.forms['io.text'] || '');
    S.transfer.preview = null;
    S.transfer.error = null;
    if (!trim(text)) { S.transfer.error = t('admin.paste_the_exported_text_first'); drawTransfer(); return; }
    ask('settingsImport', { text: text }, 'transfer').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) S.transfer.error = words(reply);
      else { S.transfer.preview = reply.data || {}; S.transfer.text = text; }
      drawTransfer();
    });
  };
  ACTIONS['io-apply'] = function (node) {
    var p = S.transfer.preview;
    if (!p || S.transfer.text == null) return;
    if (!confirmed(node)) return;
    write('settingsImportApply', { text: S.transfer.text, expect: asList(p.changes).length }, 'transfer', node)
      .then(function (reply) {
        if (!reply) return;
        S.transfer.answer = { ok: reply.ok === true, text: words(reply) };
        toast(words(reply), reply.ok ? 'ok' : 'error');
        if (reply.ok) { S.transfer.preview = null; S.transfer.text = null; S.forms['io.text'] = ''; loadSettings(); }
        drawTransfer();
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
    S.contracts.person = { ref: p.ref, name: p.name || p.cid || t('admin.this_player') };
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
    if (!minutes) problem = t('admin.pick_a_time_or_type_a_2');
    else if (Number(info.maxAdjust) && minutes * 60 > Number(info.maxAdjust)) {
      problem = t('admin.at_most') + exactSpan(info.maxAdjust) + t('admin.either_way');
    } else if (!reason) problem = t('admin.give_a_reason_it_goes_on');
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
      if (!data.amount) problem = t('admin.an_amount_is_a_whole_number');
    } else if (how === 'return_owner') {
      data.owner = trim(S.forms['dr.owner.' + line]);
      if (!/^[A-Za-z0-9_-]{3,64}$/.test(data.owner)) problem = t('admin.give_the_citizen_id_of_whoever');
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
    var settleLabel = how === 'pay_amount' ? t('admin.click_again_pay') + money(data.amount) + t('admin.of_this_line')
      : how === 'return_owner' ? t('admin.click_again_return_it_to') + data.owner : null;
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
      if (!data.note) problem = t('admin.say_why_in_a_note_a');
    } else {
      data.who = DD['rv-who'].value(id);
      if (!data.who) problem = t('admin.the_item_names_nobody_to_give');
      if (action === 'refund') {
        if (S.forms['rv.' + id + '.goods'] === 'yes') {
          data.goods = true;
        } else {
          data.amount = wholeNumber(S.forms['rv.' + id + '.amount']);
          data.account = DD['rv-account'].value(id);
          if (!data.amount && !problem) problem = t('admin.an_amount_is_a_whole_number');
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
      : action === 'pay' ? t('admin.click_again_pay_it_to') + whoLabel
        : data.goods ? t('admin.click_again_refund_every_item_and') + whoLabel
          : t('admin.click_again_refund_to_from', money(data.amount), whoLabel, data.account);
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
    if (!n) { toast(t('admin.nothing_is_shown_to_copy'), 'info'); return; }
    if (copyText(consoleText(shown))) toast(tn('admin.copied_lines', n, num(n)), 'ok');
    else toast(t('admin.this_game_would_not_copy_it'), 'error');
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
      S.players.playtime = { ok: false, text: t('admin.hours_are_a_number_from_0') };
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
      S.players.freeze = { ok: false, text: t('admin.give_a_reason_it_goes_on') };
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
    var bad = !isFinite(lo) || !isFinite(hi) ? t('admin.has_to_be_two_numbers')
      : (entry.integer && (Math.floor(lo) !== lo || Math.floor(hi) !== hi)) ? t('admin.has_to_be_whole_numbers')
      : lo > hi ? t('admin.has_its_from_above_its_to')
      : ((entry.min != null && lo < entry.min) || (entry.max != null && hi > entry.max))
        ? t('admin.has_to_be_within_to', entry.min, entry.max) : null;
    if (bad) {
      disarm();
      S.settings.answers[key] = { ok: false, text: t('admin.not_changed') + key + ' ' + bad + '.' };
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
      S.settings.answers['Cooldowns.' + bucket] = { ok: true, text: bucket + t('admin.is_as_typed_already_nothing_changed') };
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
      S.settings.answers[key] = { ok: false, text: said + t('admin.click_save_again_to_do_it') };
      drawSettingRow(key);
    }
    var button = byId('st-save-' + key);
    if (button) {
      var shown = describe(entry, parsed.value);
      if (shown.length > 24) shown = shown.slice(0, 23) + '\u2026';
      confirmed(button, t('admin.click_again_save') + shown);
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
  /* Check the config (server/configcheck.lua, /ch-diag config): every value
     out of range, script missing, ACE not held and risky combination, each
     with its fix, drawn where the diagnosis is. */
  ACTIONS['tl-config'] = function () {
    S.tools.diag = { lines: [t('admin.checking')], later: [] };
    drawTools();
    ask('diag', { config: true }, 'diag').then(function (reply) {
      if (!reply) return;
      if (!reply.ok) S.tools.diag = { error: words(reply) };
      else S.tools.diag = { lines: asList((reply.data || {}).lines), later: [] };
      drawTools();
    });
  };
  ACTIONS['tl-diag'] = function () {
    var subject = trim(S.forms['tl.subject']);
    if (subject && !/^\d{1,5}$/.test(subject)) {
      S.tools.diag = { error: t('admin.give_a_player_id_or_nothing') };
      drawTools();
      return;
    }
    S.tools.diag = { lines: [t('admin.running')], later: [] };
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
    if (n > ANNOUNCE_MAX) return h('span.is-warn', n + ' / ' + ANNOUNCE_MAX + t('admin.characters_too_long_to_send'));
    return h('span', t('admin.n_of_characters', n, ANNOUNCE_MAX));
  }

  function announceBody() {
    var a = ST.announce;
    var open = writesOpen();
    return card(frag(icon('bullhorn'), t('admin.announce_to_every_hitman')), frag(
      h('p.about', t('admin.one_phone_notice_the_same_words')
        + t('admin.at_most') + ANNOUNCE_MAX + t('admin.characters_and_no_links_invites_or')
        + t('admin.who_sent_it_to_whom_how')),
      segmented('an-scope', [
        { value: 'active', label: t('admin.hitmen_on_a_contract'), disabled: !open, title: open ? null : whyNoWrite() },
        { value: 'online', label: t('admin.everyone_online'), disabled: !open, title: open ? null : whyNoWrite() }
      ], a.scope),
      h('div.inline-form.is-wide',
        field('an.text', { id: 'an-text', class: 'is-grow', placeholder: t('admin.the_notice'),
          maxlength: String(ANNOUNCE_MAX * 2), 'data-live': 'an-count', disabled: !open,
          'aria-label': t('admin.the_notice_to_send') }),
        writeBtn('.primary', 'an-send', {}, t('admin.send'), t('admin.click_again_to_send'), 'paper-plane')),
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
    if (!text) problem = t('admin.write_the_notice_first');
    else if (charCount(text) > ANNOUNCE_MAX) problem = t('admin.at_most') + ANNOUNCE_MAX + t('admin.characters');
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
    if (!hs.data) return loading(t('admin.reading_the_settings_history'));
    var rows = asList(hs.data.rows);
    var hidden = Number(hs.data.hidden) || 0;
    return frag(
      answerBox(hs.answer),
      rows.length ? h('div.table-wrap', h('table.grid.is-history',
        h('thead', h('tr', h('th', t('admin.when')), h('th', t('admin.setting')), h('th', t('admin.before')), h('th', t('admin.after')),
          h('th', t('admin.who')), h('th', ''))),
        h('tbody', rows.map(function (r) {
          return h('tr', { 'data-key': String(r.key || '') },
            h('td.nowrap', { title: when(r.ts) }, ago(r.ts)),
            h('td.wrap', h('b', String(r.label || r.key || '—')), h('div.mono.sub', String(r.key || '')),
              r.reset ? h('span.chip', t('admin.back_to_config_lua')) : null),
            h('td.wrap', historyValue(r.old, r.secret)),
            h('td.wrap', historyValue(r['new'], r.secret)),
            h('td.wrap', String(r.by || '—')),
            h('td.nowrap', r.ref ? writeBtn('.is-small', 'hs-undo', { 'data-ref': String(r.ref) }, t('admin.undo'),
              t('admin.click_again_to_undo'), 'arrow-rotate-left') : null));
        })))) : empty(t('admin.no_setting_has_been_changed_from')),
      hidden ? h('p.note', hidden + t('admin.change_to_the_developer_sections_own')
        + t('admin.for_staff_who_may_open_it')) : null,
      h('div.btn-row',
        hs.back.length ? btn('.is-small.ghost', 'hs-newer', {}, t('admin.newer'), 'arrow-left') : null,
        hs.data.next != null ? btn('.is-small.ghost', 'hs-older', {}, t('admin.older'), 'arrow-right') : null));
  }

  /** Records \u203a Logs, Setting changes. */
  function settingsLogBody() {
    return frag(
      h('div.toolbar', btn('.ghost', 'hs-refresh', {}, t('admin.refresh'), 'rotate')),
      h('p.hint', t('admin.every_setting_changed_from_the_panel')
        + t('admin.undo_puts_the_value_before_that')
        + t('admin.the_record_a_secret_is_never')),
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

  var REPORT_ROLE;
  Text.later(function () {
    REPORT_ROLE = { placer: t('admin.the_placer'), target: t('admin.the_target'), hitman: t('admin.a_hitman_on_it'),
                      viewer: t('admin.a_player_who_saw_it_on') };
  });

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
      h('p', t('admin.sent_by'), h('b', REPORT_ROLE[known.role] || String(known.role || t('admin.a_player'))),
        known.note ? frag(': ', h('q', String(known.note))) : t('admin.with_no_note')),
      excerpt.length ? h('ol.excerpt', excerpt.map(function (m) {
        return h('li', h('span.mono.sub', clock(m.at)), ' ', h('b', String(m.alias || '?')), ': ',
          h('span.wrap', String(m.body || '')));
      })) : h('p.note', known.thread ? t('admin.the_thread_was_empty') : t('admin.no_thread_was_sent_with_it')));
  }

  /** A report moves no money: Dismiss, with what was done, is all it takes. */
  function reportForm(item) {
    var id = String(item.id);
    return h('div.rv-form',
      h('div.inline-form.is-wide',
        field('rv.' + id + '.note', { class: 'is-grow', placeholder: t('admin.what_was_done_a_note_is'),
          maxlength: '200', 'aria-label': t('admin.note') }),
        writeBtn('', 'resolve', { 'data-id': id, 'data-report': 'yes' }, t('admin.dismiss_it'), t('admin.click_again_to_dismiss'),
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
      toast(t('admin.the_page_hit_an_error') + (err && err.message ? err.message : String(err)), 'error');
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
      return t('admin.read_only_this_needs_the_staff')
        + t('admin.config_admin_moderatorace_the_extra_aces');
    }
    if (S.recovery === 'recovering') return t('admin.still_recovering_from_the_restart_try');
    if (S.recovery === 'recovery_failed') {
      return t('admin.recovery_failed_at_the_last_start');
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
  var PROTECT_UNITS;
  Text.later(function () {
    PROTECT_UNITS = [{ value: 'h', label: t('admin.hours') }, { value: 'd', label: t('admin.days') },
                       { value: 'forever', label: t('admin.permanent') }];
  });

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
    return row && row['until'] ? t('admin.until_when_ago', when(row['until']), ago(row['until'])) : forever;
  }

  function suspendCard(d) {
    var row = d.suspended;
    var body;
    if (row) {
      body = frag(
        h('p.sub', t('admin.suspended_ago_until', ago(row.since), untilWords(row, t('admin.until_you_lift_it')))
          + (row.reason ? ': ' + String(row.reason) : '') + (row.by ? t('admin.by') + String(row.by) : '')),
        h('p.note', t('admin.they_may_not_place_or_accept')
          + t('admin.their_live_contracts_run_on_freeze')),
        h('div.btn-row', modBtn('', 'ps-lift', { id: 'ps-lift' }, t('admin.lift_suspension'), null, 'unlock')));
    } else {
      var days = trim(S.forms['ps.days']);
      body = frag(
        h('p.note', t('admin.bars_them_from_placing_or_accepting')
          + t('admin.with_a_reason_they_are_shown')),
        h('div.inline-form.is-wide.ps-picks',
          segmented('ps-days', SUSPEND_DAYS.map(function (n) {
            return { value: String(n), label: tn('admin.days_count', n), disabled: !modOpen() };
          }).concat([{ value: '0', label: t('admin.until_lifted_2'), disabled: !modOpen() }]), days),
          field('ps.days', { id: 'ps-days', class: 'is-short', placeholder: t('admin.days'), inputmode: 'numeric',
            maxlength: '3', disabled: !modOpen(), 'aria-label': t('admin.days_suspended_0_until_lifted') })),
        h('div.inline-form.is-wide',
          field('ps.reason', { id: 'ps-reason', class: 'is-grow', maxlength: '120', disabled: !modOpen(),
            placeholder: t('admin.reason_required_they_are_shown_it'),
            'aria-label': t('admin.reason_for_the_suspension') }),
          modBtn('.danger', 'ps-suspend', {}, t('admin.suspend'), t('admin.click_again_to_suspend'), 'ban')));
    }
    return card(t('admin.suspend_from_contracts'), frag(body, answerBox(S.pstaff.suspend)), '',
      row ? h('span.chip.is-warn.is-suspended', t('admin.suspended')) : null);
  }

  function protectCard(d) {
    var row = d.protected;
    var body;
    if (row) {
      body = frag(
        h('p.sub', t('admin.protected_ago_until', ago(row.since), untilWords(row, t('admin.for_good_3')))
          + (row.reason ? ': ' + String(row.reason) : '') + (row.by ? t('admin.by') + String(row.by) : '')),
        h('p.note', t('admin.no_new_contract_may_name_them')
          + t('admin.those_on_hold')),
        h('div.btn-row', modBtn('', 'pp-lift', { id: 'pp-lift' }, t('admin.lift_protection'), null, 'unlock')));
    } else {
      var forever = S.pstaff.unit === 'forever';
      body = frag(
        h('p.note', t('admin.makes_them_untargetable_a_new_player')
          + t('admin.a_new_contract_on_them_is')
          + t('admin.right_now_and_the_target_search')
          + t('admin.contracts_already_on_them_are_not')),
        h('div.inline-form.is-wide.pp-picks',
          segmented('pp-unit', PROTECT_UNITS.map(function (u) {
            return { value: u.value, label: u.label, disabled: !modOpen() };
          }), S.pstaff.unit),
          forever ? null : field('pp.amount', { id: 'pp-amount', class: 'is-short', inputmode: 'numeric',
            maxlength: '4', placeholder: S.pstaff.unit === 'd' ? t('admin.days') : t('admin.hours'), disabled: !modOpen(),
            'aria-label': S.pstaff.unit === 'd' ? t('admin.days_protected') : t('admin.hours_protected') })),
        h('div.inline-form.is-wide',
          field('pp.reason', { id: 'pp-reason', class: 'is-grow', maxlength: '120', disabled: !modOpen(),
            placeholder: t('admin.reason_required_kept_in_the_log'), 'aria-label': t('admin.reason_for_the_protection') }),
          modBtn('', 'pp-protect', {}, t('admin.protect'), t('admin.click_again_to_protect'), 'shield')));
    }
    return card(t('admin.protect_from_contracts'), frag(body, answerBox(S.pstaff.protect)), '',
      row ? h('span.chip.is-protected', t('admin.protected')) : null);
  }

  function payCard(d) {
    var max = Number(d.payMax) || 0;
    var open = writesOpen() && max > 0;
    var why = max > 0 ? whyNoWrite() : t('admin.manual_payments_are_off_config_staff');
    return card(t('admin.pay'), frag(
      h('p.note', max > 0
        ? t('admin.pays_them_cash_or_bank_at') + money(max) + t('admin.at_once_config_staff_manualpaymentmax')
          + t('admin.into_their_hands_now_when_they')
          + t('admin.so_every_payment_is_on_the')
        : why),
      h('div.inline-form.is-wide.pay-form',
        segmented('pay-account', [{ value: 'cash', label: t('admin.cash'), disabled: !open },
          { value: 'bank', label: t('admin.bank'), disabled: !open }], S.pstaff.account),
        field('pay.amount', { id: 'pay-amount', class: 'is-short', inputmode: 'numeric', maxlength: '9',
          placeholder: t('admin.amount_2'), disabled: !open, 'aria-label': t('admin.amount_to_pay') })),
      h('div.inline-form.is-wide',
        field('pay.reason', { id: 'pay-reason', class: 'is-grow', maxlength: '120', disabled: !open,
          placeholder: t('admin.reason_required_kept_in_the_log'), 'aria-label': t('admin.reason_for_the_payment') }),
        writeBtn('.danger', 'pay-send', open ? {} : { title: why }, t('admin.pay'), t('admin.click_again_to_pay'),
          'money-bill', false, open)),
      answerBox(S.pstaff.pay)));
  }

  var MEASURE_LABEL;
  Text.later(function () {
    MEASURE_LABEL = { freeze: t('admin.freeze'), suspend: t('admin.suspension'), protect: t('admin.protection') };
  });
  var ROLE_LABEL;
  Text.later(function () {
    ROLE_LABEL = { client: 'placed', target: t('admin.on_them'), hitman: 'took' };
  });

  function moneyTable(rows, none) {
    rows = asList(rows);
    if (!rows.length) return empty(none);
    return h('div.table-wrap', h('table.grid',
      h('thead', h('tr', h('th', t('admin.kind')), h('th.num', t('admin.amount')))),
      h('tbody', rows.map(function (r) {
        return h('tr', h('td', String(r.kind)), h('td.num', money(r.amount)));
      }))));
  }

  function historyCard() {
    var hd = S.pstaff.history;
    if (S.pstaff.historyError) return card(t('admin.history'), empty(S.pstaff.historyError));
    if (!hd) return card(t('admin.history'), loading(t('admin.reading_their_history')));
    var c = hd.counts || {};
    var measures = asList(hd.measures);
    var recent = asList(hd.recent);
    var ident = hd.identified === true;
    return card(t('admin.history'), frag(
      h('p.hint', ident
        ? t('admin.everything_the_store_keeps_of_them')
          + (Number(hd.anonymous) > 0 ? t('admin.n_anonymous_paren', num(hd.anonymous)) : '') + t('admin.read_only_2')
        : t('admin.what_the_store_keeps_of_them')
          + t('admin.and_any_money_or_purchase_on')),
      h('div.tiles.is-compact',
        tile(t('admin.placed'), h('p.big', num(c.placed))),
        tile(t('admin.taken'), h('p.big', num(c.taken))),
        tile(t('admin.completed'), h('p.big', num(c.completed))),
        tile(t('admin.cancelled'), h('p.big', num(c.cancelled))),
        tile(t('admin.on_them_2'), h('p.big', num(c.onThem))),
        tile(t('admin.bought_out'), h('p.big', num(c.boughtOut)))),
      h('div.tiles.is-compact',
        tile(t('admin.buyouts_paid'), h('p.big', num(hd.buyouts && hd.buyouts.paid))),
        tile(t('admin.paid_for_buyouts'), h('p.big.is-sum', money(hd.buyouts && hd.buyouts.amount))),
        tile(t('admin.informants_bought'), h('p.big', num(hd.informants && hd.informants.count))),
        tile(t('admin.spent_on_informants'), h('p.big.is-sum', money(hd.informants && hd.informants.spent)))),
      h('div.cols',
        card(t('admin.money_in'), moneyTable(hd.money && hd.money['in'], t('admin.nothing_in_that_the_store_keeps'))),
        card(t('admin.money_out'), moneyTable(hd.money && hd.money.out, t('admin.nothing_out_that_the_store_keeps')))),
      card(t('admin.freezes_suspensions_and_protections'), measures.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.what')), h('th', t('admin.from')), h('th', t('admin.until')), h('th', t('admin.state')),
          h('th', t('admin.reason')))),
        h('tbody', measures.map(function (m) {
          return h('tr',
            h('td', MEASURE_LABEL[m.kind] || String(m.kind)),
            h('td.nowrap', when(m.from)),
            h('td.nowrap', m.ended ? when(m.ended) : m['until'] ? when(m['until']) : '—'),
            h('td', String(m.state || '—')),
            h('td', String(m.reason || '—') + (m.by ? t('admin.by') + String(m.by) : '')));
        })))) : empty(t('admin.none_on_record'))),
      card(t('admin.contracts'), recent.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.contract')), h('th', t('admin.their_part')), h('th', t('admin.state')), h('th', t('admin.placed')),
          ident ? h('th', t('admin.client')) : null, ident ? h('th', t('admin.target')) : null)),
        h('tbody', recent.map(function (r) {
          var id = String(r.id);
          return h('tr',
            h('td', h('button.link.mono', { type: 'button', 'data-act': 'contract', 'data-id': id }, id)),
            h('td', asList(r.roles).map(function (x) { return ROLE_LABEL[x] || String(x); }).join(', '),
              r.anonymous ? h('span.chip.is-anon', 'anonymous') : null),
            h('td', stateChip(r.state)), h('td.nowrap', when(r.created_at)),
            ident ? h('td.name', String(r.client || '—')) : null,
            ident ? h('td.name', String(r.target || '—')) : null);
        })))) : empty(t('admin.no_contracts_the_store_keeps')), '', h('span.sub', t('admin.newest_first_3')))));
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
      return refuse('suspend', t('admin.choose_how_many_days_1_to'));
    }
    if (!reason) return refuse('suspend', t('admin.give_a_reason_they_are_shown'));
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
        return refuse('protect', S.pstaff.unit === 'd' ? t('admin.give_a_number_of_days_1')
          : t('admin.give_a_number_of_hours_1'));
      }
    }
    if (!reason) return refuse('protect', t('admin.give_a_reason_it_goes_on'));
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
    if (!amount) return refuse('pay', t('admin.give_the_amount_a_whole_number'));
    if (max > 0 && amount > max) {
      return refuse('pay', t('admin.at_most') + money(max) + t('admin.at_once_config_staff_manualpaymentmax_2'));
    }
    if (!reason) return refuse('pay', t('admin.give_a_reason_it_goes_on'));
    if (!confirmed(node)) return;
    staffWrite(write('manualPay', { ref: S.players.ref, amount: amount, account: S.pstaff.account,
      reason: reason.slice(0, 120) }, 'pstaff:pay', node), 'pay');
  };

  Text.later(function () {
    STAFF_ACTIONS.push(
    { title: t('admin.suspend_or_protect_a_player'), icon: 'ban', view: 'players', go: t('admin.open_players'),
      text: t('admin.look_the_player_up_suspend_bars')
        + t('admin.lifted_with_a_reason_they_are')
        + t('admin.good_neither_touches_live_contracts_the') },
    { title: t('admin.pay_a_player'), icon: 'money-bill', view: 'players', go: t('admin.open_players'),
      text: t('admin.look_the_player_up_then_pay')
        + t('admin.config_staff_manualpaymentmax_paid_at_their') });
  });

  Text.later(function () {
    HELP.push(
    { title: t('admin.suspensions_and_protections'), icon: 'ban',
      text: t('admin.staff_with_the_staff_or_moderator_2')
        + t('admin.accept_one_and_are_told_until')
        + t('admin.refused_as_cannot_be_listed_right')
        + t('admin.own_or_with_lift_neither_touches'),
      links: [] },
    { title: t('admin.moderators'), icon: 'gavel',
      text: t('admin.the_moderator_ace_config_admin_moderatorace')
        + t('admin.identities_they_may_freeze_suspend_protect')
        + t('admin.settling_the_review_queue_and_the'),
      links: [{ key: 'Staff.ManualPaymentMax', label: t('admin.most_one_manual_payment_may_be') }] });
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
        return h('li', h('span.time', when(n.at)), ' ', h('span.sub', String(n.by || t('admin.staff'))),
          h('p.text', String(n.text || '')));
      })) : empty(t('admin.no_notes_yet_only_staff_see')),
      h('div.inline-form.is-wide',
        field('dr.note.' + id, { class: 'is-grow', placeholder: t('admin.a_note_for_staff_e_g'),
          maxlength: String(Number(staff.noteMax) || 300), disabled: !writesOpen(), 'aria-label': t('admin.a_staff_note') }),
        writeBtn('', 'ct-note', {}, t('admin.add_note'), t('admin.click_again_to_add'), 'note-sticky')));
  }

  ACTIONS['ct-note'] = function (node) {
    var id = S.drawer.id;
    if (!id) return;
    var text = trim(S.forms['dr.note.' + id]);
    if (!text) {
      disarm();
      S.drawer.answer = { ok: false, text: t('admin.write_the_note') };
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
      return h('li', h('span.time', when(r.at)), ' ', h('b', String(r.who || t('admin.an_operative'))),
        t('admin.removed_by') + String(r.by || t('admin.staff')),
        r.stakeReturned ? h('span.chip', t('admin.stake_returned')) : null,
        r.blocked ? h('span.chip.is-warn', 'barred') : null,
        h('span.detail', ' ' + String(r.reason || '')));
    })) : null;
    if (!staff.removable) {
      return frag(h('p.note', t('admin.only_a_live_contract_active_or_2')), history);
    }
    if (!active.length) return frag(h('p.note', t('admin.nobody_is_on_it_now')), history);
    if (!active.some(function (m) { return String(m.id) === st.pick; })) st.pick = '';
    var open = writesOpen();
    var off = { disabled: !open, title: open ? null : whyNoWrite() };
    return frag(
      h('p.note', t('admin.takes_them_off_without_ending_it')
        + t('admin.told_an_operative_left_as_a')),
      h('div.ct-row', h('span.ct-label', t('admin.operative')),
        segmented('ct-rm-pick', active.map(function (m) {
          return { value: String(m.id), label: String(m.alias || 'operative') + (m.name ? ' · ' + m.name : ''),
                   disabled: !open, title: off.title };
        }), st.pick)),
      h('div.ct-row', h('span.ct-label', t('admin.their_stake')),
        segmented('ct-rm-stake', [
          { value: 'client', label: t('admin.to_the_placer_as_a_walk'), disabled: !open, title: off.title },
          { value: 'return', label: t('admin.return_the_stake'), disabled: !open, title: off.title }
        ], st.stake)),
      h('div.ct-row', h('span.ct-label', t('admin.afterwards')),
        segmented('ct-rm-block', [
          { value: '', label: t('admin.may_take_it_again'), disabled: !open, title: off.title },
          { value: 'block', label: t('admin.bar_them_from_it'), disabled: !open, title: off.title }
        ], st.block)),
      h('div.inline-form.is-wide',
        field('dr.rm.reason.' + id, { class: 'is-grow', placeholder: t('admin.reason_required_kept_in_the_log'),
          maxlength: '120', disabled: !open, 'aria-label': t('admin.reason_for_removing_the_operative') }),
        writeBtn('.danger', 'ct-remove', {}, t('admin.remove'), t('admin.click_again_to_remove'), 'user-minus')),
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
    var problem = !st.pick ? t('admin.pick_the_operative_to_remove') : (!reason ? t('admin.give_a_reason_it_goes_on') : null);
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
    return st.from === 'placer' ? t('admin.charged_to_the_placers') + st.account : t('admin.added_by_staff') + st.account + ')';
  }

  /** What the change typed would do, in the server's figures. */
  function rewardPreviewText() {
    var st = rwState();
    var by = rewardBy();
    if (by == null) return h('span', t('admin.type_a_whole_number_of_dollars'));
    var v = st.previewBy === by ? st.preview : null;
    if (!v) return h('span', t('admin.reading_what_that_would_do'));
    if (v.refused) return h('span.is-warn', String(v.message || t('admin.not_possible_now')));
    var parts = [h('span', t('admin.collection_n', num(v.slot)), h('b', money(v.reward)), ' → ', h('b', money(v.after)))];
    if (by > 0) parts.push(h('span', ', ' + rewardWho(st) + '.'));
    else {
      parts.push(h('span', '. ' + money(v.toStaff || 0) + t('admin.of_what_staff_added_comes_off')
        + money(v.toPlacer || 0) + t('admin.goes_back_to_the_placer')));
    }
    if (Number(v.max) && Math.abs(by) > Number(v.max)) {
      parts.push(h('span.is-warn', t('admin.at_most_2') + money(v.max) + t('admin.at_once_config_staff_rewardchangemax')));
    }
    return frag(parts);
  }

  function rewardBody(d) {
    var id = S.drawer.id;
    var c = d.contract || {};
    var st = rwState();
    if (c.state !== 'active' && c.state !== 'accepted') {
      return h('p.note', t('admin.only_a_live_contract_active_or_3'));
    }
    var base = st.baseFor === id ? st.base : null;
    var open = writesOpen();
    var off = { disabled: !open, title: open ? null : whyNoWrite() };
    var facts = !base ? loading(t('admin.reading_the_reward'))
      : base.refused ? h('p.note.is-warn', String(base.message || t('admin.its_reward_cannot_be_changed_now')))
        : h('dl.facts',
          h('dt', t('admin.collection')), h('dd', num(base.slot)),
          h('dt', t('admin.its_reward')), h('dd', money(base.reward)),
          h('dt', t('admin.added_by_staff_2')), h('dd', money(base.staffAdded || 0)),
          h('dt', t('admin.lowered_by_at_most')), h('dd', money(base.mostLower || 0)),
          h('dt', t('admin.one_change_at_most')), h('dd', Number(base.max) ? money(base.max) : t('admin.off_config_staff_rewardchangemax_is_0')));
    var dirOpts = [{ value: 'raise', label: t('admin.raise'), disabled: !open, title: off.title },
                   { value: 'lower', label: t('admin.lower'), disabled: !open, title: off.title }];
    return frag(
      h('p.note', t('admin.changes_the_reward_of_the_collection')
        + t('admin.changed_by_staff_nobody_is_named')),
      facts,
      h('div.ct-row', h('span.ct-label', t('admin.change')), segmented('rw-dir', dirOpts, st.dir),
        field('dr.rw.amt.' + id, { class: 'is-short', placeholder: '$ amount', inputmode: 'numeric', maxlength: '9',
          'data-live': 'rw-preview', disabled: !open, 'aria-label': t('admin.dollars_to_change_the_reward_by') })),
      st.dir === 'raise' ? h('div.ct-row', h('span.ct-label', t('admin.paid_by')),
        segmented('rw-from', [
          { value: 'staff', label: t('admin.added_by_staff_2'), disabled: !open, title: off.title },
          { value: 'placer', label: t('admin.charged_to_the_placer'), disabled: !open, title: off.title }
        ], st.from)) : null,
      st.dir === 'raise' ? h('div.ct-row', h('span.ct-label', t('admin.account')),
        segmented('rw-account', [
          { value: 'bank', label: t('admin.bank'), disabled: !open, title: off.title },
          { value: 'cash', label: t('admin.cash'), disabled: !open, title: off.title }
        ], st.account)) : null,
      h('p.note', { id: 'dr-rw-preview', 'aria-live': 'polite' }, rewardPreviewText()),
      h('div.inline-form.is-wide',
        field('dr.rw.reason.' + id, { class: 'is-grow', placeholder: t('admin.reason_required_kept_in_the_log'),
          maxlength: '120', disabled: !open, 'aria-label': t('admin.reason_for_changing_the_reward') }),
        writeBtn('.primary', 'rw-change', {}, t('admin.change_reward'), t('admin.click_again_to_change'), 'sack-dollar')));
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
    var problem = by == null ? t('admin.type_a_whole_number_of_dollars_2')
      : max && Math.abs(by) > max ? t('admin.at_most') + money(max) + t('admin.at_once_config_staff_rewardchangemax')
        : !reason ? t('admin.give_a_reason_it_goes_on') : null;
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
      S.drawer.answer = { ok: false, text: String(v.message || t('admin.not_possible_now')) };
      drawDrawer();
      return;
    }
    var label = by > 0
      ? t('admin.click_again_raise_it_from_to', money(v.reward), money(v.after), rewardWho(st))
      : t('admin.click_again_lower_it_from_to', money(v.reward), money(v.after));
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
      return h('p.note', t('admin.only_a_live_contract_active_or_4'));
    }
    var open = writesOpen();
    var off = { disabled: !open, title: open ? null : whyNoWrite() };
    if (!hasPlayer()) {
      return frag(h('p.note', t('admin.look_the_hitman_up_in_players')
        + t('admin.open_over_it_come_back_to')),
        h('div.btn-row', btn('.is-small', 'section', { 'data-section': 'players' }, t('admin.find_the_hitman_in_players'),
          'magnifying-glass')));
    }
    var who = String((S.players.data.player || {}).name || 'them');
    var v = st.previewRef === S.players.ref ? st.preview : null;
    var ops = v ? asList(v.operatives) : [];
    var said = !v ? loading(t('admin.checking_whether') + who + t('admin.can_take_it'))
      : frag(
        h('p', ops.length ? t('admin.taken_off_it') + ops.join(', ') + t('admin.each_as_remove_operative_does')
          : t('admin.nobody_is_on_it_now')),
        h('p', v.stakeWaived ? t('admin.their_stake_is_waived_config_staff')
          : t('admin.they_put_up_the') + money(v.stake) + t('admin.stake_as_on_accept')),
        v.refused ? h('p.note.is-warn', String(v.message || t('admin.they_cannot_take_it_now'))) : null);
    return frag(
      h('div.ct-row', h('span.ct-label', t('admin.new_hitman')), h('span.chip.is-live', icon('user'), ' ', who)),
      said,
      h('div.ct-row', h('span.ct-label', t('admin.those_taken_off')),
        segmented('ra-block', [
          { value: 'block', label: t('admin.bar_them_from_it'), disabled: !open, title: off.title },
          { value: '', label: t('admin.they_may_take_it_again'), disabled: !open, title: off.title }
        ], st.block)),
      h('div.ct-row', h('span.ct-label', t('admin.their_stakes')),
        segmented('ra-stake', [
          { value: 'client', label: t('admin.to_the_placer_as_a_walk'), disabled: !open, title: off.title },
          { value: 'return', label: t('admin.return_the_stakes'), disabled: !open, title: off.title }
        ], st.stake)),
      h('div.ct-row', h('span.ct-label', t('admin.the_new_hitman')),
        segmented('ra-identity', [
          { value: 'anonymous', label: t('admin.anonymous_no_fee'), disabled: !open, title: off.title },
          { value: 'carry', label: t('admin.as_they_chose_before'), disabled: !open, title: off.title },
          { value: 'named', label: t('admin.named_to_the_placer'), disabled: !open, title: off.title }
        ], st.identity)),
      h('div.inline-form.is-wide',
        field('dr.ra.reason.' + id, { class: 'is-grow', placeholder: t('admin.reason_required_kept_in_the_log'),
          maxlength: '120', disabled: !open, 'aria-label': t('admin.reason_for_reassigning_the_contract') }),
        writeBtn('.danger', 'ra-go', {}, t('admin.reassign'), t('admin.click_again_to_reassign'), 'right-left')));
  }

  ACTIONS['ra-block'] = function (node) { disarm(); raState().block = node.getAttribute('data-value') || ''; drawDrawer(); };
  ACTIONS['ra-stake'] = function (node) { disarm(); raState().stake = node.getAttribute('data-value') || 'client'; drawDrawer(); };
  ACTIONS['ra-identity'] = function (node) { disarm(); raState().identity = node.getAttribute('data-value') || 'anonymous'; drawDrawer(); };

  ACTIONS['ra-go'] = function (node) {
    var id = S.drawer.id;
    if (!id) return;
    var st = raState();
    var reason = trim(S.forms['dr.ra.reason.' + id]).slice(0, 120);
    var problem = !hasPlayer() ? t('admin.look_the_hitman_up_in_players_2')
      : !reason ? t('admin.give_a_reason_it_goes_on') : null;
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
      S.drawer.answer = { ok: false, text: String(v.message || t('admin.they_cannot_take_it_now')) };
      drawDrawer();
      return;
    }
    var who = String((S.players.data.player || {}).name || 'them');
    var n = asList(v.operatives).length;
    var label = t('admin.click_again_give_it_to') + who + (n ? tn('admin.taking_off_operatives', n) : '');
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
    var now = h('p', t('admin.reason_now'), h('span.text', String(c.reason || '—')),
      text.edited ? h('span.chip', t('admin.edited_by_staff')) : null);
    var history = edits.length ? h('ul.plain.ct-history', edits.map(function (e) {
      return h('li', h('span.time', when(e.at)), ' ', String(e.field || 'reason') + t('admin.replaced_by')
        + String(e.by || t('admin.staff')), h('span.detail', ' ' + String(e.reason || '')));
    })) : null;
    if (!text.editable) return frag(now, h('p.note', t('admin.this_server_keeps_no_reason_on')), history);
    var open = writesOpen();
    var input = text.mode === 'preset'
      ? h('div.ct-row', h('span.ct-label', t('admin.new_reason')), segmented('ct-tx-preset', asList(text.presets).map(function (p) {
        return { value: String(p), label: String(p), disabled: !open, title: open ? null : whyNoWrite() };
      }), S.forms['dr.tx.text.' + id] || ''))
      : h('div.inline-form.is-wide', field('dr.tx.text.' + id, { class: 'is-grow', placeholder: t('admin.the_new_text'),
        maxlength: String(Number(text.max) || 120), disabled: !open, 'aria-label': t('admin.the_new_reason') }));
    return frag(now,
      h('p.note', t('admin.goes_through_the_same_checks_a')
        + t('admin.edited_by_staff_the_original_stays')),
      input,
      h('div.inline-form.is-wide',
        field('dr.tx.reason.' + id, { class: 'is-grow', placeholder: t('admin.why_required_kept_in_the_log'),
          maxlength: '120', disabled: !open, 'aria-label': t('admin.reason_for_the_edit') }),
        writeBtn('', 'ct-text', {}, t('admin.replace'), t('admin.click_again_to_replace'), 'pen')),
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
    var problem = !text ? t('admin.type_the_new_text') : (!reason ? t('admin.give_a_reason_it_goes_on') : null);
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
      h('p.note', t('admin.its_whole_timeline_as_plain_text')
        + t('admin.notes_shown_as_this_view_shows')),
      h('div.drawer-actions', btn('', 'ct-export', {}, t('admin.copy_the_record'), 'copy')),
      st.exported && !st.exported.copied
        ? h('textarea.input.ct-export-text', { readonly: 'readonly', rows: '8', 'aria-label': t('admin.the_record_to_copy') },
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
      toast(copied ? t('admin.the_record_is_on_the_clipboard') : t('admin.select_the_text_below_and_copy'), copied ? 'ok' : 'error');
      drawDrawer();
    });
  };

  /* -- as a player sees it -- */

  /** The keys of a card in the order the phone shows them, with words. */
  var VIEW_KEYS;
  Text.later(function () {
    VIEW_KEYS = [
    ['role', t('admin.seen_as')], ['targetName', t('admin.target')], ['reason', t('admin.reason')], ['state', t('admin.state')], ['mode', t('admin.mode')],
    ['fulfilment', t('admin.completes_by')], ['timeLeft', t('admin.time_left')], ['onHold', t('admin.on_hold')], ['reward', t('admin.reward')],
    ['penaltyAmount', t('admin.stake_to_accept')], ['bonusPercent', t('admin.bonus_2')], ['slots', t('admin.payouts')],
    ['slotsClaimed', t('admin.claimed')], ['hitmenActive', t('admin.operatives_on_it')], ['creatorName', t('admin.placed_by')],
    ['creatorAnonymous', t('admin.placed_anonymously')], ['barred', t('admin.barred')]
  ];
  });

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
        ? frag(String(view.reason || '—'), view.staffEdited ? h('span.chip', t('admin.edited_by_staff')) : null)
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
    var options = [{ value: 'target', label: t('admin.target') }, { value: 'placer', label: t('admin.placer') }];
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
        r.whitelisted ? frag(h('p.slot-title', t('admin.whitelisted_job_view')), viewCard(r.whitelisted)) : null);
    } else if (st.viewKey) {
      body = loading(t('admin.reading_their_card'));
    }
    return frag(
      h('p.note', t('admin.read_only_exactly_what_their_phone')
        + t('admin.unless_you_hold_the_identity_ace')),
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

  Text.later(function () {
    HELP.push(
    { title: t('admin.roleplay_proof_of_intent'), icon: 'comments',
      text: t('admin.off_as_shipped_on_a_hitmans')
        + t('admin.the_contract_in_character_enough_messages')
        + t('admin.handover_or_a_meeting_point_set')
        + t('admin.time_it_is_handed_over_anyway')
        + t('admin.and_every_hold_is_audited_intent'),
      links: [{ key: 'Roleplay.ProofOfIntent.Enabled', label: t('admin.proof_of_intent') },
        { key: 'Roleplay.ProofOfIntent.MinMessages', label: t('admin.messages_that_count') },
        { key: 'Roleplay.ProofOfIntent.HoldMaxMinutes', label: t('admin.longest_hold') }] },
    { title: 'Roleplay: Bodyguards', icon: 'shield-halved',
      text: t('admin.off_as_shipped_on_a_target')
        + t('admin.at_once_and_held_and_a')
        + t('admin.protection_tab_by_its_reward_alone')
        + t('admin.never_who_placed_the_hit_or')
        + t('admin.out_the_guard_is_paid_completed')
        + t('admin.nobody_took_it_or_staff_voided'),
      links: [{ key: 'Roleplay.Protection.Enabled', label: t('admin.bodyguard_contracts') },
        { key: 'Roleplay.Protection.MinReward', label: t('admin.reward_bounds_and_account') },
        { key: 'Roleplay.Protection.PayOnCompletionPercent', label: t('admin.share_if_completed') },
        { key: 'Roleplay.Protection.MaxJobsPerGuard', label: t('admin.jobs_per_guard') }] },
    { title: t('admin.roleplay_hit_on_the_hitman'), icon: 'crosshairs',
      text: t('admin.off_as_shipped_on_a_target_2')
        + t('admin.card_to_place_a_contract_on')
        + t('admin.a_contract_applies_nothing_is_offered'),
      links: [{ key: 'Roleplay.HitOnHitman.Enabled', label: t('admin.hit_on_the_hitman') },
        { key: 'Intel.Informant.Enabled', label: t('admin.the_targets_informant') }] });
  });

  window.addEventListener('message', function (event) {
    var message = (event && event.data) || {};
    if (message.type === 'open') {
      // The language the client names (Config.Locale), over English.
      Text.use(message.locale);
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

  Text.later(function () {
    GROUP_INTRO['Roleplay: Witness heat'] = t('admin.a_completion_seen_by_bystanders_alerts');
  });
  Text.later(function () {
    GROUP_INTRO['Roleplay: EMS before re-listing'] = t('admin.a_target_killed_on_a_contract');
  });
  Text.later(function () {
    GROUP_INTRO['Roleplay: City news'] = t('admin.an_anonymous_news_post_after_a');
  });
  Text.later(function () {
    GROUP_INTRO['Roleplay: Dirty money payouts'] = t('admin.a_hitmans_cash_or_bank_payout');
  });
  Text.later(function () {
    GROUP_INTRO['Roleplay: Proof of intent'] = t('admin.a_payout_waits_until_the_hitman');
  });
  Text.later(function () {
    GROUP_INTRO['Roleplay: Bodyguards'] = t('admin.a_target_may_hire_a_bodyguard');
  });
  Text.later(function () {
    GROUP_INTRO['Roleplay: Hit on the hitman'] = t('admin.a_target_may_place_a_contract');
  });
  Text.later(function () {
    GROUP_INTRO['Intel: Rumours and broker'] = t('admin.new_contracts_show_as_rumours_until');
  });
  Text.later(function () {
    GROUP_INTRO['Roleplay: Burner phone'] = t('admin.placing_and_accepting_need_a_burner');
  });
  Text.later(function () {
    GROUP_INTRO['Intel: Informant in person'] = t('admin.informant_purchases_only_beside_the_informant');
  });
  Text.later(function () {
    GROUP_INTRO['Roleplay: Reason quality'] = t('admin.free_text_reasons_held_to_a');
  });
  Text.later(function () {
    GROUP_INTRO['Intel: Tip warning delay'] = t('admin.the_target_hears_of_an_informant');
  });
  Text.later(function () {
    GROUP_INTRO['Intel: Tip limits'] = t('admin.one_tip_per_hitman_per_contract');
  });
  Text.later(function () {
    GROUP_INTRO['Intel: Hold before a tip'] = t('admin.a_tip_only_once_the_hitman');
  });
  Text.later(function () {
    GROUP_INTRO['Intel: Informant second try'] = t('admin.what_the_targets_later_look_ups');
  });
  Text.later(function () {
    GROUP_INTRO['Intel: Tip safe zones'] = t('admin.no_tip_while_the_target_is');
  });
  Text.later(function () {
    GROUP_INTRO['Intel: Go dark'] = t('admin.a_tipped_off_target_may_pay');
  });
  Text.later(function () {
    GROUP_INTRO['Improvements: Proof items'] = t('admin.a_hitman_may_finish_with_an');
  });
  Text.later(function () {
    GROUP_INTRO['Improvements: Serial scrubbing'] = t('admin.an_anonymous_placers_weapon_reaches_the');
  });
  Text.later(function () {
    GROUP_INTRO['Improvements: Weekly stats'] = t('admin.the_weeks_totals_posted_to_discord');
  });
  Text.later(function () {
    GROUP_INTRO['Improvements: Completion cooldown'] = t('admin.a_wait_before_a_completed_contracts');
  });

  Text.later(function () {
    HELP.push(
    { title: t('admin.roleplay_witness_heat'), icon: 'eye',
      text: t('admin.when_it_is_on_every_completion')
        + t('admin.the_hitman_who_are_no_party')
        + t('admin.vague_witness_report_on_their_phones')
        + t('admin.nearest_named_area_a_position_can')
        + t('admin.hitman_or_the_placer'),
      links: [{ key: 'Roleplay.WitnessHeat.Enabled', label: t('admin.witness_heat_on_or_off') },
        { key: 'Roleplay.WitnessHeat.WitnessRadius', label: t('admin.radius_and_witnesses') },
        { key: 'Roleplay.WitnessHeat.Phrases', label: t('admin.what_a_witness_says') },
        { key: 'Roleplay.WitnessHeat.Areas', label: t('admin.named_areas') }] },
    { title: t('admin.roleplay_ems_before_re_listing'), icon: 'kit-medical',
      text: t('admin.when_it_is_on_a_target')
        + t('admin.they_have_to_have_been_up')
        + t('admin.told_they_are_still_recovering_with')
        + t('admin.is_needed_instead_the_rule_always')
        + 'cooldowns.',
      links: [{ key: 'Roleplay.EmsRelisting.Enabled', label: t('admin.on_or_off') },
        { key: 'Roleplay.EmsRelisting.TreatedMinutes', label: t('admin.minutes_up') },
        { key: 'Roleplay.EmsRelisting.RequireEMS', label: t('admin.a_medics_revive') }] },
    { title: t('admin.roleplay_city_news'), icon: 'newspaper',
      text: t('admin.when_it_is_on_a_completed')
        + t('admin.anonymous_news_item_it_goes_out')
        + t('admin.event_another_resource_posts_the_words')
        + t('admin.and_the_time_the_target_is'),
      links: [{ key: 'Roleplay.CityNews.Enabled', label: t('admin.on_or_off') },
        { key: 'Roleplay.CityNews.App', label: t('admin.where_it_is_posted') },
        { key: 'Roleplay.CityNews.Templates', label: t('admin.templates') }] },
    { title: t('admin.roleplay_dirty_money_payouts'), icon: 'sack-dollar',
      text: t('admin.when_it_is_on_a_hitmans')
        + t('admin.count_or_as_one_item_worth')
        + t('admin.converts_it_so_nothing_is_lost')
        + t('admin.does_not_fit_in_their_pockets'),
      links: [{ key: 'Roleplay.DirtyPayouts.Enabled', label: t('admin.on_or_off') },
        { key: 'Roleplay.DirtyPayouts.Item', label: t('admin.the_item') },
        { key: 'Roleplay.DirtyPayouts.Rate', label: t('admin.the_rate') }] });
  });

  /* ---------- the roleplay features (Config.Roleplay) ---------- */

  Text.later(function () {
    HELP.push(
    { title: t('admin.intel_rumours_and_the_broker'), icon: 'user-secret',
      text: t('admin.off_as_shipped_on_a_hitman')
        + t('admin.band_with_no_name_face_or')
        + t('admin.being_briefed_by_a_player_on')
        + t('admin.npc_moves_between_its_places_on'),
      links: [{ key: 'Intel.Rumours.Enabled', label: t('admin.rumours_on_or_off') },
        { key: 'Intel.Rumours.Locations', label: t('admin.broker_places') },
        { key: 'Intel.Rumours.BriefValidMinutes', label: t('admin.how_long_a_briefing_lasts') },
        { key: 'Intel.Rumours.BrokerJobs', label: t('admin.broker_jobs') }] },
    { title: t('admin.roleplay_burner_phone'), icon: 'mobile-screen',
      text: t('admin.off_as_shipped_on_placing_accepting')
        + t('admin.in_the_inventory_counted_on_the')
        + t('admin.phone_and_as_shipped_sees_no')
        + t('admin.up_on_placing_or_accepting_sell'),
      links: [{ key: 'Roleplay.BurnerPhone.Enabled', label: t('admin.burner_phone_on_or_off') },
        { key: 'Roleplay.BurnerPhone.Item', label: t('admin.the_item') }] },
    { title: t('admin.intel_the_informant_in_person'), icon: 'user-secret',
      text: t('admin.off_as_shipped_on_every_informant')
        + t('admin.sold_only_to_a_buyer_standing')
        + t('admin.anywhere_else_it_is_refused_with'),
      links: [{ key: 'Intel.InPerson.Enabled', label: t('admin.informant_in_person') },
        { key: 'Intel.InPerson.Locations', label: t('admin.informant_places') }] },
    { title: t('admin.roleplay_broker_and_informant_placed_from'), icon: 'location-dot',
      text: t('admin.off_as_shipped_on_the_broker')
        + t('admin.broker_and_informant_places_stand_there')
        + t('admin.those_as_their_rotatehours_say_their')
        + t('admin.are_used_while_no_place_is'),
      links: [{ key: 'Roleplay.NpcPlaces.Enabled', label: t('admin.placed_from_the_panel_on_or') },
        { key: 'Intel.Rumours.Locations', label: t('admin.broker_defaults') }] },
    { title: t('admin.roleplay_reason_quality'), icon: 'pen',
      text: t('admin.off_as_shipped_on_a_typed')
        + t('admin.other_reason_rules_a_reason_with')
        + t('admin.and_put_in_needs_review_as'),
      links: [{ key: 'Roleplay.ReasonQuality.Enabled', label: t('admin.reason_quality_on_or_off') },
        { key: 'Roleplay.ReasonQuality.LowEffort', label: t('admin.low_effort_phrases') },
        { key: 'Roleplay.ReasonQuality.LowEffortAction', label: t('admin.refuse_or_review') }] });
  });

  /* ---------- the improvements (Config.Improvements) ---------- */

  Text.later(function () {
    HELP.push(
    { title: t('admin.intel_tip_warning_delay'), icon: 'clock',
      text: t('admin.off_as_shipped_on_the_target')
        + t('admin.a_random_while_after_the_tip')
        + t('admin.a_warning_still_waiting_survives_a')
        + t('admin.the_targets_card_is_rounded_to'),
      links: [{ key: 'Intel.WarningDelay.Enabled', label: t('admin.on_or_off') },
        { key: 'Intel.WarningDelay.MinSeconds', label: t('admin.shortest_delay') },
        { key: 'Intel.WarningDelay.MaxSeconds', label: t('admin.longest_delay') }] },
    { title: t('admin.intel_tip_limits'), icon: 'scale-balanced',
      text: t('admin.off_as_shipped_on_on_top')
        + t('admin.may_buy_one_tip_per_contract')
        + t('admin.before_up_to_the_most_a')
        + t('admin.moved_is_refused_never_charged'),
      links: [{ key: 'Intel.TipLimits.Enabled', label: t('admin.on_or_off') },
        { key: 'Intel.TipLimits.OnePerHitman', label: t('admin.one_per_hitman') },
        { key: 'Intel.TipLimits.PriceDoubling', label: t('admin.price_doubling') },
        { key: 'Intel.TipLimits.MaxCost', label: t('admin.most_a_tip_costs') }] },
    { title: t('admin.intel_hold_before_a_tip'), icon: 'hourglass',
      text: t('admin.off_as_shipped_on_a_hitman_2')
        + t('admin.minutes_set_before_that_the_card'),
      links: [{ key: 'Intel.HoldFirst.Enabled', label: t('admin.on_or_off') },
        { key: 'Intel.HoldFirst.MinHeldMinutes', label: t('admin.minutes_held') }] },
    { title: t('admin.intel_informant_second_try'), icon: 'user-secret',
      text: t('admin.off_as_shipped_on_the_targets')
        + t('admin.the_informants_price_100_is_the'),
      links: [{ key: 'Intel.SecondTry.Enabled', label: t('admin.on_or_off') },
        { key: 'Intel.SecondTry.SecondTryCostPercent', label: t('admin.later_price') },
        { key: 'Intel.Informant.RevealChancePercent', label: t('admin.the_chance') }] },
    { title: t('admin.intel_tip_safe_zones'), icon: 'shield',
      text: t('admin.off_as_shipped_on_no_tip')
        + t('admin.x_y_radius_name_the_hitman')
        + t('admin.never_why_or_where_and_nothing'),
      links: [{ key: 'Intel.SafeZones.Enabled', label: t('admin.on_or_off') },
        { key: 'Intel.SafeZones.Zones', label: t('admin.the_zones') }] },
    { title: t('admin.intel_go_dark'), icon: 'eye-slash',
      text: t('admin.off_as_shipped_on_a_target_3')
        + t('admin.minutes_set_every_tip_bought_on')
        + t('admin.not_find_them_and_gets_the'),
      links: [{ key: 'Intel.GoDark.Enabled', label: t('admin.on_or_off') },
        { key: 'Intel.GoDark.Cost', label: t('admin.the_price') },
        { key: 'Intel.GoDark.Minutes', label: t('admin.how_long') }] });
  });

  /* ---------- a character's record (server/record/) ---------- */

  Text.later(function () {
    GROUP_INTRO['Record: Reputation'] = t('admin.trust_for_a_completion_scaled_by');
  });
  Text.later(function () {
    GROUP_INTRO['Record: Placer record'] = t('admin.a_placers_record_on_the_board');
  });
  Text.later(function () {
    GROUP_INTRO['Record: Hitman heat'] = t('admin.police_attention_a_hitmans_work_builds');
  });
  Text.later(function () {
    GROUP_INTRO['Record: Tiered board'] = t('admin.bigger_rewards_locked_to_higher_progression');
  });

  Text.later(function () {
    HELP.push(
    { title: t('admin.record_reputation_earned_in_character'), icon: 'star',
      text: t('admin.off_as_shipped_on_the_progression')
        + t('admin.plain_completion_plus_a_bonus_each')
        + t('admin.witnesses_near_the_hitman_up_to')
        + t('admin.it_needs_criminal_progression_on_to'),
      links: [{ key: 'Record.Reputation.Enabled', label: t('admin.reputation') },
        { key: 'Record.Reputation.BaseFactor', label: t('admin.factors_and_cap') },
        { key: 'Record.Reputation.WitnessRadius', label: t('admin.witness_radius') }] },
    { title: t('admin.record_placer_record'), icon: 'briefcase',
      text: t('admin.off_as_shipped_on_a_board')
        + t('admin.cancelled_over_the_last_days_set')
        + t('admin.counts_are_exact_an_anonymous_placer')
        + t('admin.only_their_anonymous_contracts_in_bands')
        + t('admin.two_anonymous_contracts_cannot_be_tied'),
      links: [{ key: 'Record.PlacerRecord.Enabled', label: t('admin.placer_record') },
        { key: 'Record.PlacerRecord.ShowForAnonymous', label: t('admin.anonymous_placers') },
        { key: 'Record.PlacerRecord.LookbackDays', label: t('admin.days_counted') }] },
    { title: t('admin.record_hitman_heat'), icon: 'fire',
      text: t('admin.off_as_shipped_on_a_hitman_3')
        + t('admin.report_on_a_completion_and_a')
        + t('admin.target_heat_fades_after_the_hours')
        + t('admin.its_target_the_paranoid_alert_at')
        + t('admin.bulletin_at_most_every_so_many'),
      links: [{ key: 'Record.Heat.Enabled', label: t('admin.hitman_heat') },
        { key: 'Record.Heat.Threshold', label: t('admin.heat_and_threshold') },
        { key: 'Record.Heat.DecayHours', label: t('admin.how_long_heat_stays') },
        { key: 'Record.Heat.BulletinText', label: t('admin.the_bulletin') }] },
    { title: t('admin.record_tiered_board'), icon: 'layer-group',
      text: t('admin.off_as_shipped_and_only_with')
        + t('admin.the_least_level_a_hitmans_level')
        + t('admin.in_a_tier_above_their_level')
        + t('admin.it_before_taking_anything'),
      links: [{ key: 'Record.Tiers.Enabled', label: t('admin.tiered_board') },
        { key: 'Record.Tiers.Tiers', label: t('admin.tiers') },
        { key: 'Record.Tiers.CompletionsPerLevel', label: t('admin.completions_per_level') },
        { key: 'Record.Progression.Enabled', label: t('admin.criminal_progression') }] });
  });

  /* ---------- contract decay (server/imp_board.lua) ---------- */

  Text.later(function () {
    GROUP_INTRO['Improvements: Contract decay'] = t('admin.an_untaken_contracts_reward_rises_or');
  });

  Text.later(function () {
    HELP.push(
    { title: t('admin.improvements_contract_decay'), icon: 'hourglass-half',
      text: t('admin.off_as_shipped_on_a_contract')
        + t('admin.goes_up_by_the_percent_set')
        + t('admin.most_set_in_all_it_waits')
        + t('admin.its_deadline_comes_in_by_the')
        + t('admin.it_off_for_their_contract_from'),
      links: [{ key: 'Improvements.ContractDecay.Enabled', label: t('admin.contract_decay') },
        { key: 'Improvements.ContractDecay.Mode', label: t('admin.rise_or_shorten') },
        { key: 'Improvements.ContractDecay.Percent', label: t('admin.step_cap_and_account') },
        { key: 'Improvements.ContractDecay.Hours', label: t('admin.hours_between_steps') }] });
  });

  /* ---------- the staff and economy improvements (Config.Improvements) ---------- */

  Text.later(function () {
    HELP.push(
    { title: t('admin.improvements_proof_items'), icon: 'id-card',
      text: t('admin.off_as_shipped_on_a_hitman_4')
        + t('admin.standing_beside_the_person_who_placed')
        + t('admin.shipped_an_id_card_whose_citizenid')
        + t('admin.hitmans_inventory_checks_it_names_the')
        + t('admin.pays_as_for_a_verified_kill')
        + t('admin.for_a_live_delivery_only_are'),
      links: [{ key: 'Improvements.ProofItems.Enabled', label: t('admin.proof_items_on_or_off') },
        { key: 'Improvements.ProofItems.Item', label: t('admin.the_item') },
        { key: 'Improvements.ProofItems.MetadataKey', label: t('admin.the_field_naming_the_target') },
        { key: 'Improvements.ProofItems.HandoverRadius', label: t('admin.the_distance') }] },
    { title: t('admin.improvements_completion_cooldown'), icon: 'hourglass',
      text: t('admin.off_as_shipped_0_set_nobody')
        + t('admin.a_contract_on_them_was_completed')
        + t('admin.is_longer_the_placer_is_told'),
      links: [{ key: 'Limits.TargetCooldownAfterCompletionSeconds', label: t('admin.the_wait') }] },
    { title: t('admin.improvements_weapon_serial_scrubbing'), icon: 'gun',
      text: t('admin.off_as_shipped_on_a_weapon')
        + t('admin.random_serial_so_it_cannot_be')
        + t('admin.is_their_own_weapon_unchanged_each')
        + t('admin.only_to_staff_with_the_identity'),
      links: [{ key: 'Improvements.SerialScrub.Enabled', label: t('admin.scrubbing_on_or_off') }] },
    { title: t('admin.improvements_weekly_stats_to_discord'), icon: 'chart-column',
      text: t('admin.off_as_shipped_on_once_a')
        + t('admin.days_contracts_placed_contracts_completed_and')
        + t('admin.never_a_name_a_citizen_id')
        + t('admin.crimson_hitman_stats_webhook_or_else'),
      links: [{ key: 'Improvements.WeeklyStats.Enabled', label: t('admin.weekly_stats_on_or_off') },
        { key: 'Improvements.WeeklyStats.Day', label: t('admin.the_day') },
        { key: 'Improvements.WeeklyStats.Hour', label: t('admin.the_hour') }] });
  });

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
  var TL_SHORT;
  Text.later(function () {
    TL_SHORT = {
    TargetCooldownAfterResolveSeconds: t('admin.after_one_ends'), SameCreatorSameTargetCooldownSeconds: t('admin.same_placer'),
    TargetCooldownAfterCompletionSeconds: t('admin.after_completed'), MaxActiveContractsPerTarget: t('admin.live_at_once'),
    MaxContractsPerTargetPerDay: 'Per 24 h', MaxContractsPerTargetPerWeek: 'Per 7 days'
  };
  });

  function tlKeys() { return asList(S.tl.meta && S.tl.meta.keys); }

  /** A limit's value in words: seconds as a span, 0 as off where 0 is off. */
  function tlValue(entry, value) {
    var n = Number(value) || 0;
    if (entry.unit === 's') {
      if (n === 0) return 'off';
      var d = Math.floor(n / 86400), hr = Math.floor((n % 86400) / 3600), mi = Math.floor((n % 3600) / 60);
      var parts = [];
      if (d) parts.push(t('admin.n_d', d));
      if (hr) parts.push(t('admin.n_h', hr));
      if (mi) parts.push(t('admin.n_min', mi));
      if (!parts.length) parts.push(t('admin.n_s', n));
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
        bad = bad || t('admin.is_a_whole_number_from_to', String(k.label), k.min, k.max);
        return;
      }
      out[k.key] = Number(raw);
      count++;
    });
    return { limits: out, bad: bad, count: count };
  }

  function tlJobTable() {
    var jobs = asList(S.tl.meta && S.tl.meta.jobs);
    if (!jobs.length) return empty(t('admin.no_job_has_limits_of_its'));
    var keys = tlKeys();
    return h('div.table-wrap', h('table.grid',
      h('thead', h('tr', h('th', t('admin.job')), keys.map(function (k) {
        return h('th', { title: String(k.label) }, TL_SHORT[k.key] || String(k.label));
      }), h('th', ''))),
      h('tbody', jobs.map(function (j) {
        var own = j.limits || {}, eff = j.effective || {};
        return h('tr',
          h('td.mono.tl-job', String(j.job)),
          keys.map(function (k) {
            var mine = own[k.key] !== undefined && own[k.key] !== null;
            return h('td' + (mine ? '.is-own' : ''), { title: mine ? t('admin.this_jobs_own') : t('admin.the_default') },
              tlValue(k, eff[k.key]));
          }),
          h('td.nowrap', btn('.is-small.ghost', 'tj-edit', { 'data-value': String(j.job) }, t('admin.edit'), 'pen'),
            ' ', writeBtn('.is-small.danger', 'tj-remove', { 'data-value': String(j.job) }, t('admin.remove'),
              t('admin.click_again_to_remove_2') + String(j.job), 'trash')));
      }))));
  }

  /** Who a job action reaches, in words, once counted. */
  function tlJobWho() {
    var job = trim(S.forms['tja.job']).toLowerCase();
    var count = S.tl.jobCountFor === job ? S.tl.jobCount : null;
    return { count: count, text: count === null ? t('admin.the_players_of') + (job || t('admin.that_job'))
      : tn('admin.players_working', count, num(count), job) };
  }

  /** A job action's buttons, each confirm naming the job and the count:
      drawn again on their own when the count comes, never the box being typed in. */
  function tlManyButtons() {
    var who = tlJobWho().text;
    return frag(
      modBtn('', 'tja-reset', { 'data-value': 'reset' }, t('admin.reset_cooldowns'), t('admin.click_again_reset') + who,
        'arrow-rotate-left'),
      modBtn('', 'tja-reset-all', { 'data-value': 'all' }, t('admin.reset_all'), t('admin.click_again_reset_all_for') + who,
        'arrows-rotate'),
      modBtn('', 'tja-extend', { 'data-value': 'extend' }, t('admin.extend_cooldowns'), t('admin.click_again_extend') + who,
        'hourglass'),
      modBtn('', 'tja-counts', { 'data-value': 'counts' }, t('admin.reset_counts'), t('admin.click_again_reset_counts_for') + who,
        'eraser'));
  }

  function tlJobsBody() {
    if (S.tl.error) return empty(S.tl.error);
    if (!S.tl.meta) return loading(t('admin.reading_the_job_limits'));
    var open = writesOpen();
    var many = modOpen();
    var counted = tlJobWho();
    return frag(
      card(t('admin.a_jobs_own_limits'), frag(
        h('p.note', t('admin.a_target_working_this_job_when')
          + t('admin.you_fill_in_here_instead_of')
          + t('admin.needs_the_staff_ace_config_admin')),
        h('div.inline-form.is-wide',
          field('tj.job', { id: 'tj-job', class: 'is-short', maxlength: String((S.tl.meta.jobMax) || 32),
            placeholder: t('admin.job_name_police'), disabled: !open, 'aria-label': t('admin.job_name') })),
        tlLimitFields('tj', open),
        h('div.btn-row', writeBtn('.primary', 'tj-save', { id: 'tj-save' }, t('admin.save_job_limits'),
          t('admin.click_again_to_save'), 'floppy-disk')),
        answerBox(S.tl.jobAnswer))),
      card(t('admin.jobs_with_their_own_limits'), tlJobTable(), '',
        h('span.sub', t('admin.what_applies_in_bold_the_jobs'))),
      card(t('admin.every_player_of_a_job_at'), frag(
        h('p.note', t('admin.reset_or_extend_the_cooldowns_or')
          + t('admin.working_this_job_now_and_every')
          + t('admin.7_days_recorded_as_working_it')),
        h('div.inline-form.is-wide',
          field('tja.job', { id: 'tja-job', class: 'is-short', maxlength: '32', placeholder: t('admin.job_name'),
            disabled: !many, 'data-live': 'tja-count', 'aria-label': t('admin.job_name_for_a_job_action') }),
          h('span.sub', { id: 'tja-count' }, counted.count === null ? '' : counted.text),
          field('tja.min', { id: 'tja-min', class: 'is-short', inputmode: 'numeric', maxlength: '5',
            placeholder: t('admin.minutes'), disabled: !many, 'aria-label': t('admin.minutes_to_extend_by') })),
        h('div.inline-form.is-wide',
          field('tja.reason', { id: 'tja-reason', class: 'is-grow', maxlength: '120', disabled: !many,
            placeholder: t('admin.reason_required_kept_in_the_log'), 'aria-label': t('admin.reason_for_the_job_action') })),
        h('div.btn-row.tl-many', { id: 'tja-buttons' }, tlManyButtons()),
        answerBox(S.tl.jobAnswerMany))));
  }

  SHELL.tljobs = function () {
    return h('section.view', h('p.hint', t('admin.limits_for_targets_on_one_job')),
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
      return tlJobRefuse('jobAnswer', t('admin.a_job_name_is_its_qbx'));
    }
    var typed = tlLimitsTyped('tj');
    if (typed.bad) return tlJobRefuse('jobAnswer', typed.bad);
    if (!typed.count) return tlJobRefuse('jobAnswer', t('admin.fill_in_at_least_one_limit'));
    if (!confirmed(node, t('admin.click_again_save_limits_for') + job)) return;
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
    if (!/^[a-z0-9_]{1,32}$/.test(job)) return tlJobRefuse('jobAnswerMany', t('admin.give_the_jobs_qbx_name_first'));
    var data = { job: job, action: action, all: all === true, reason: reason.slice(0, 120) };
    if (action === 'extend') {
      var min = wholeNumber(S.forms['tja.min']);
      var most = Number(S.tl.meta && S.tl.meta.extendMax) || 43200;
      if (!min || min > most) return tlJobRefuse('jobAnswerMany', t('admin.give_the_minutes_to_add_1') + most + '.');
      data.minutes = min;
    }
    if (!reason) return tlJobRefuse('jobAnswerMany', t('admin.give_a_reason_it_goes_on'));
    if (S.tl.jobCountFor !== job) {
      // The confirm names how many it reaches: counted first.
      tlJobCount();
      return tlJobRefuse('jobAnswerMany', t('admin.counting_the_players_of') + job + t('admin.click_again_once_the_count_shows'));
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

  var TL_RULE;
  Text.later(function () {
    TL_RULE = {
    TargetCooldownAfterResolveSeconds: t('admin.the_wait_after_a_contract_on'),
    TargetCooldownAfterCompletionSeconds: t('admin.the_wait_after_a_completed_contract'),
    'Immunity.AfterBailoutSeconds': t('admin.the_breather_after_a_buyout'),
    staff: t('admin.a_cooldown_staff_extended')
  };
  });

  function loadTargetStatus(again) {
    var subject = trim(S.forms['tp.q']);
    var byRef = again === true && S.tl.ref ? S.tl.ref : null;
    if (!subject && !byRef) { toast(t('admin.give_a_player_id_a_citizen'), 'error'); return Promise.resolve(); }
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
        h('h2', String(p.name || t('admin.no_name_on_record'))),
        p.cid ? h('span.cid', String(p.cid)) : h('span.chip', t('admin.citizen_id_hidden')),
        p.online ? h('span.chip.is-live', t('admin.in_the_city')) : h('span.chip', 'offline'),
        st.job ? h('span.chip.is-job', t('admin.job_x', String(st.job)) + (st.jobFrom === 'last known' ? t('admin.last_known') : '')) : null,
        st.exempt ? h('span.chip.is-warn', t('admin.exempt_from_limits')) : null),
      h('div.tiles.is-compact',
        tile(t('admin.live_on_them_2'), h('p.big', num(st.live) + ' / ' + (st.exempt ? '—' : num(st.limits && st.limits.MaxActiveContractsPerTarget)))),
        tile('Placed, 24 hours', h('p.big', num(st.day))),
        tile('Placed, 7 days', h('p.big', num(st.week))),
        tile(t('admin.cooldown_left'), h('p.big' + (left > 0 ? '.is-warn' : ''), left > 0 ? exactSpan(left) : 'none'))),
      left > 0 ? h('p.note', t('admin.set_by_from_the_limits', TL_RULE[st.cooldownRule] || String(st.cooldownRule),
        TL_SOURCE[st.cooldownFrom] || 'global')) : null,
      Number(st.dayAll) !== Number(st.day) || Number(st.weekAll) !== Number(st.week)
        ? h('p.note', t('admin.counted_since_staff_reset_the_counts') + num(st.dayAll) + t('admin.in_24_hours_and') + num(st.weekAll)
          + t('admin.in_7_days_in_all')) : null,
      h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.limit')), h('th', t('admin.applies_to_them')), h('th', t('admin.from')))),
        h('tbody', keys.map(function (k) {
          var from = st.source ? st.source[k.key] : 'global';
          return h('tr', h('td', String(k.label)),
            h('td', st.exempt ? 'exempt' : tlValue(k, st.limits ? st.limits[k.key] : 0)),
            h('td', st.exempt ? 'player' : (TL_SOURCE[from] || 'global')));
        })))),
      ov ? h('p.sub', (ov.exempt ? t('admin.exempt_from_limits') : t('admin.their_own_limits')) + ' '
        + (ov.until_at ? t('admin.until_plain', when(ov.until_at)) : t('admin.for_good_3')) + (ov.reason ? ': ' + String(ov.reason) : '')) : null,
      adj.until_at && Number(adj.until_at) > nowSeconds()
        ? h('p.sub', t('admin.cooldown_extended_by_staff_until') + when(adj.until_at)) : null);
  }

  function tlPlayerActions() {
    var open = modOpen();
    var ref = S.tl.ref;
    var a = function (extra) { var o = extra || {}; o['data-ref'] = ref; return o; };
    var keys = tlKeys();
    return frag(
      card(t('admin.staff_actions_on_them'), frag(
        h('p.note', t('admin.every_action_takes_a_reason_goes')
          + t('admin.reset_cooldown_lets_them_be_named')
          + t('admin.and_any_extension_players_are_never')),
        h('div.inline-form.is-wide',
          field('tp.reason', { id: 'tp-reason', class: 'is-grow', maxlength: '120', disabled: !open,
            placeholder: t('admin.reason_required_kept_in_the_log'), 'aria-label': t('admin.reason_for_the_action') })),
        h('div.btn-row.tl-many',
          modBtn('', 'tp-reset', a(), t('admin.reset_cooldown'), t('admin.click_again_to_reset'), 'arrow-rotate-left'),
          modBtn('', 'tp-reset-all', a(), t('admin.reset_all'), t('admin.click_again_to_reset_all'), 'arrows-rotate'),
          modBtn('', 'tp-counts', a(), t('admin.reset_counts'), t('admin.click_again_to_reset_the_counts'), 'eraser')),
        h('div.inline-form.is-wide',
          field('tp.min', { id: 'tp-min', class: 'is-short', inputmode: 'numeric', maxlength: '5', disabled: !open,
            placeholder: t('admin.minutes'), 'aria-label': t('admin.minutes_to_extend_the_cooldown_by') }),
          modBtn('', 'tp-extend', a(), t('admin.extend_by_minutes'), t('admin.click_again_to_extend'), 'hourglass'),
          field('tp.until', { id: 'tp-until', class: 'is-short', maxlength: '16', disabled: !open,
            placeholder: t('admin.yyyy_mm_dd_hh_mm'), 'aria-label': t('admin.hold_the_cooldown_until') }),
          modBtn('', 'tp-until-set', a(), t('admin.hold_until'), t('admin.click_again_to_hold_until_then'), 'calendar'))),
        '', null),
      card(t('admin.their_own_limits'), frag(
        h('p.note', t('admin.over_the_jobs_and_the_defaults')
          + t('admin.what_applies_now_exempt_lifts_every')),
        h('div.inline-form.is-wide',
          segmented('tpo-mode', [{ value: 'custom', label: t('admin.custom_limits'), disabled: !open },
            { value: 'exempt', label: t('admin.exempt_from_limits'), disabled: !open }], S.tl.exempt ? 'exempt' : 'custom'),
          field('tpo.hours', { id: 'tpo-hours', class: 'is-short', inputmode: 'numeric', maxlength: '4',
            disabled: !open, placeholder: t('admin.hours_0_for_good'), 'aria-label': t('admin.hours_the_override_lasts') })),
        S.tl.exempt ? null : tlLimitFields('tpo', open),
        h('div.btn-row',
          modBtn('.primary', 'tpo-set', a(), S.tl.exempt ? t('admin.make_exempt') : t('admin.set_their_limits'),
            t('admin.click_again_to_set'), 'user-shield'),
          keys.length ? modBtn('', 'tpo-clear', a(), t('admin.lift_their_own_limits'), t('admin.click_again_to_lift'), 'unlock') : null))),
      answerBox(S.tl.answer));
  }

  function tlPlayerBody() {
    var d = S.tl.status;
    if (!S.tl.meta && !S.tl.error) return loading(t('admin.reading_the_limits'));
    if (!d) return empty(t('admin.look_somebody_up_by_their_player'));
    if (d.error) return empty(d.error);
    return frag(card(t('admin.as_a_target'), tlStatusCard(d)), tlPlayerActions());
  }

  SHELL.tlplayer = function () {
    return h('section.view',
      h('div.toolbar',
        h('label.search', icon('magnifying-glass'),
          field('tp.q', { id: 'tp-q', placeholder: t('admin.player_id_citizen_id_or_name'), 'data-enter': 'tp-lookup',
            'aria-label': t('admin.player_id_citizen_id_or_name') })),
        btn('.primary', 'tp-lookup', {}, t('admin.look_up'), 'arrow-right')),
      h('p.hint', t('admin.exact_times_which_players_never_see')),
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
    if (!S.tl.ref) return tlRefuse(t('admin.look_them_up_first'));
    var reason = trim(S.forms['tp.reason']);
    if (!reason) return tlRefuse(t('admin.give_a_reason_it_goes_on'));
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
    if (!min || min > most) return tlRefuse(t('admin.give_the_minutes_to_add_1') + most + '.');
    tlWrite(node, TL_SEND.extend, { minutes: min });
  };
  ACTIONS['tp-until-set'] = function (node) {
    var at = parseWhen(S.forms['tp.until'], false);
    if (!at) return tlRefuse(t('admin.give_the_time_as_yyyy_mm'));
    if (at <= nowSeconds()) return tlRefuse(t('admin.that_time_has_passed'));
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
    if (!/^\d{1,4}$/.test(raw) || Number(raw) > max) return tlRefuse(t('admin.give_the_hours_0_for_good') + max + '.');
    if (S.tl.exempt) return tlWrite(node, TL_SEND.override, { exempt: true, hours: Number(raw) });
    var typed = tlLimitsTyped('tpo');
    if (typed.bad) return tlRefuse(typed.bad);
    if (!typed.count) return tlRefuse(t('admin.fill_in_at_least_one_limit_2'));
    tlWrite(node, TL_SEND.override, { exempt: false, limits: typed.limits, hours: Number(raw) });
  };
  ACTIONS['tpo-clear'] = function (node) { tlWrite(node, TL_SEND.clear, {}); };


  Text.later(function () {
    STAFF_ACTIONS.push(
    { title: t('admin.target_limits'), icon: 'user-clock', view: 'tlplayer', go: t('admin.open_per_player'),
      text: t('admin.how_often_one_person_may_have_3')
        + t('admin.players_cooldown_reset_or_extended_counts')
        + t('admin.of_a_job_at_once_live'),
      also: { view: 'tljobs', go: t('admin.per_job') } });
  });

  Text.later(function () {
    HELP.push(
    { title: t('admin.target_limits'), icon: 'user-clock',
      text: t('admin.the_limits_on_how_often_one')
        + t('admin.the_job_they_are_working_when')
        + t('admin.as_shipped_players_are_told_only'),
      links: [{ key: 'Limits.MaxContractsPerTargetPerDay', label: t('admin.day_cap') },
        { key: 'Limits.MaxContractsPerTargetPerWeek', label: t('admin.week_cap') }] });
  });

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
    var run = { ref: ref, lines: [t('admin.running')], later: [] };
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
      return { e: e, text: [e.key, e.label, e.about, e.group, e.groupLabel, areaLabel(areaOf(e))].map(function (v) {
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
    if (contract) hits.push({ kind: t('admin.contract'), label: t('admin.open_contract') + trim(raw), act: 'gs-contract', value: trim(raw) });
    if (digits) hits.push({ kind: t('admin.player'), label: t('admin.look_up_player_id') + trim(raw), act: 'gs-player', value: trim(raw) });
    SECTIONS.forEach(function (view) {
      if (!viewShown(view)) return;
      var g = groupOf(view);
      var label = (VIEW_LABEL[view] || [view])[0];
      if ((label + ' ' + (g ? g.label : '')).toLowerCase().indexOf(q) !== -1) {
        hits.push({ kind: t('admin.section'), label: (g ? g.label + ' › ' : '') + label, act: 'gs-view', value: view });
      }
    });
    STAFF_ACTIONS.forEach(function (a, i) {
      if ((a.title + ' ' + a.text).toLowerCase().indexOf(q) !== -1 && viewAllowed(resolveView(a.view))) {
        hits.push({ kind: t('admin.action'), label: a.title, act: 'gs-action', value: String(i) });
      }
    });
    searchSettings().forEach(function (row) {
      if (row.text.indexOf(q) !== -1) {
        hits.push({ kind: t('admin.setting'), label: String(row.e.label || row.e.key), sub: areaLabel(areaOf(row.e))
          + ' · ' + (row.e.secret ? 'server.cfg' : t('admin.config') + row.e.key), act: 'gs-setting', value: row.e.key });
      }
    });
    if (!contract && !digits) {
      hits.push({ kind: t('admin.player'), label: t('admin.look_up_2') + trim(raw).slice(0, 64) + t('admin.as_a_player'),
        act: 'gs-player', value: trim(raw).slice(0, 64) });
    }
    return hits.slice(0, SEARCH_MAX);
  }

  function searchBody() {
    var q = S.search.q;
    if (!S.search.open || !trim(q)) return frag();
    var hits = searchHits(q);
    if (!S.settings.data) {
      hits.push({ kind: t('admin.note'), label: t('admin.reading_the_settings_their_rows_join'), act: null });
    }
    return frag(hits.length ? hits.map(function (hit, i) {
      return h('button.gs-hit' + (i === 0 ? '.is-first' : ''), { type: 'button', 'data-act': hit.act || 'gs-none',
        'data-value': hit.value == null ? '' : String(hit.value), role: 'option' },
        h('span.gs-kind', hit.kind), h('span.gs-label', hit.label), hit.sub ? h('span.gs-sub', hit.sub) : null);
    }) : h('p.empty', t('admin.no_setting_action_or_section_matches')));
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

  var DISPOSAL_STAGE;
  Text.later(function () {
    DISPOSAL_STAGE = { body: t('admin.body_not_loaded_yet'), loaded: t('admin.loaded_on_the_way_to_the') };
  });
  var DISPOSAL_TIMEOUT;
  Text.later(function () {
    DISPOSAL_TIMEOUT = { pay: t('admin.paid_in_full'), reduced: t('admin.paid_in_part_the_rest_back'),
    refund: t('admin.refunded_to_the_placer') };
  });

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
        ? h('p.note.is-error', t('admin.body_disposal_could_not_be_read') + S.disposal.error) : frag();
    }
    if (!steps.length) {
      return where === 'contracts' && d.enabled
        ? h('p.note', t('admin.body_disposal_is_on_nobody_is')) : frag();
    }
    var timeout = DISPOSAL_TIMEOUT[d.onTimeout] || String(d.onTimeout || t('admin.paid_in_full'));
    return card(t('admin.body_disposal_in_progress') + num(steps.length) + ')', frag(
      h('p.about', t('admin.a_verified_kills_payout_waits_until')
        + exactSpan(d.limitSeconds) + t('admin.in_all_on_running_out_it') + timeout + t('admin.skip_finishes_one_as_if_the')
        + t('admin.body_was_dropped_off_respawn_vehicle')),
      h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.contract')), h('th', t('admin.stage')), h('th', t('admin.time_left')), h('th', ''))),
        h('tbody', steps.map(function (step) {
          var cid = String(step.contract || '');
          return h('tr',
            h('td', h('button.link.mono', { type: 'button', 'data-act': 'contract', 'data-id': cid }, cid),
              h('span.sub', t('admin.payout_lower_n', num(step.slot))),
              canIdentify() && step.hitman ? h('div.sub.mono', String(step.hitman)) : null),
            h('td', DISPOSAL_STAGE[step.stage] || String(step.stage || '—'),
              h('div.sub', t('admin.vehicle_x', step.vehicle ? t('admin.there_word') : t('admin.not_made')), Number(step.respawns) > 0
                ? h('span.chip', tn('admin.respawns_count', Number(step.respawns), num(step.respawns))) : null)),
            h('td.nowrap', exactSpan(step.secondsLeft), step.held ? h('div', h('span.chip.is-warn', t('admin.clock_held'))) : null),
            h('td', h('div.inline-form',
              writeBtn('.is-small', 'dp-skip', { 'data-id': String(step.id), 'data-contract': cid }, t('admin.skip'),
                t('admin.click_again_to_skip'), 'forward'),
              writeBtn('.is-small.ghost', 'dp-respawn', { 'data-id': String(step.id), 'data-contract': cid },
                t('admin.respawn_vehicle'), t('admin.click_again_to_respawn'), 'truck'))));
        })))),
      answerBox(S.disposal.answers.list)), '.dp-steps',
      btn('.is-small.ghost', 'dp-refresh', {}, t('admin.refresh'), 'rotate'));
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
    if (!armed(node, t('admin.click_again_finish_the_disposal_on') + cid + t('admin.and_hand_over_its_payout'))) return;
    disposalWrite('disposalSkip', { id: node.getAttribute('data-id') }, 'list', node);
  };
  ACTIONS['dp-respawn'] = function (node) {
    var cid = node.getAttribute('data-contract');
    if (!armed(node, t('admin.click_again_make_the_vehicle_for') + cid + t('admin.again_at_the_spawn_spot'))) return;
    disposalWrite('disposalRespawn', { id: node.getAttribute('data-id') }, 'list', node);
  };

  Text.later(function () {
    STAFF_ACTIONS.push(
    { title: t('admin.change_a_reward_or_give_a'), icon: 'sack-dollar', view: 'contracts',
      go: t('admin.contracts'),
      text: t('admin.open_the_contract_money_change_reward')
        + t('admin.charged_to_the_placer_with_the')
        + t('admin.looked_up_in_players_taking_off') },
    { title: t('admin.help_with_a_body_disposal'), icon: 'truck', view: 'contracts', go: t('admin.contracts'),
      text: t('admin.every_body_being_disposed_of_is')
        + t('admin.if_dropped_off_respawn_vehicle_makes')
        + t('admin.locations_2'), also: { view: 'locations', go: t('admin.locations') } });
  });

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
    S.org = { work: { member: {}, spot: {}, rules: {} }, x2: { member: '', kind: 'strike' }, data: null, error: null, answers: {}, funds: null, fundsError: null, audit: null, auditError: null,
      auditAction: '', member: null, role: null, nonce: null, dir: 'deposit', bonusTo: '', newGrade: null,
      layout: null, hire: null, history: null, historyError: null,
      bp: { pending: {}, cols: [], area: '', granted: false, col: '', add: '' },
      staged: {} };
  }
  orgReset();

  var ORG_TABS = ['members', 'roles', 'pay', 'funds', 'contracts', 'locations', 'notices', 'settings', 'log'];
  var AREA_NAMES;
  Text.later(function () {
    AREA_NAMES = { members: t('admin.members'), roles: t('admin.roles'), pay: t('admin.pay'), money: t('admin.money_cuts'), contracts: t('admin.contracts'),
    locations: t('admin.locations'), notices: t('admin.notices'), armory: t('admin.armory'), garage: t('admin.garage'), settings: t('admin.settings_2'),
    delegation: t('admin.delegation') };
  });
  var ORG_ACTIONS = ['org_created', 'org_member_hired', 'org_member_fired', 'org_member_role', 'org_member_suspended',
    'org_member_limits', 'org_member_grant', 'org_member_staff', 'org_role_created', 'org_role_edited',
    'org_role_deleted', 'org_role_power', 'org_role_pay', 'org_grant', 'org_limits', 'org_office_rule',
    'org_cut_set', 'org_cut', 'org_split_frozen', 'org_access', 'org_pick', 'org_funds_deposit',
    'org_funds_withdraw', 'org_funds_staff_deposit', 'org_bonus', 'org_location_set', 'org_location_removed',
    'org_notice', 'org_applied', 'org_application', 'org_renamed', 'org_layout', 'org_external_adopted',
    'org_external_reverted', 'org_funds_unrecorded', 'org_setup',
    'org_contract_received', 'org_contract_assigned', 'org_contract_reassigned', 'org_contract_released',
    'org_accept_requested', 'org_accept_approved', 'org_accept_refused', 'org_accept_expired',
    'org_probation', 'org_probation_passed', 'org_duty', 'org_duty_forced', 'org_channel_post',
    'org_channel_removed', 'org_channel_mute', 'org_dossier',
    'org_armory_deposit', 'org_armory_withdraw', 'org_armory_limit', 'org_armory_stocked', 'org_armory_removed',
    'org_armory_refund_failed', 'org_stats_reset', 'org_strike', 'org_warning', 'org_discipline_overturned',
    'org_recruit_form', 'org_interview_note', 'org_added', 'org_removed',
    'org_rep_adjusted', 'org_payout_method', 'org_drop_left', 'org_drop_collected', 'org_drop_expired',
    'org_drop_settled', 'org_territory_hold', 'org_vehicle_out', 'org_vehicle_returned', 'org_vehicle_removed',
    'org_garage_offer', 'org_internal_requested', 'org_internal_decided'];

  function loadOrg() {
    return ask('orgGet', {}, 'orgGet').then(function (reply) {
      if (!reply) return;
      // The one picked was taken off meanwhile: back to the first.
      if (!reply.ok && reply.err === 'org_not_found' && S.orgScope) { S.orgScope = null; loadOrg(); return; }
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
    return card(t('admin.the_hitman_job_is_switched_off'), frag(
      h('p.about', t('admin.the_hitman_job_is_off_turn') + String(d.job || 'hitman')
        + t('admin.with_roles_members_funds_boss_permissions')
        + t('admin.changes_for_anybody') + (what || '')),
      e ? h('div.st-row', { id: 'st-row-' + e.key, 'data-key': e.key }, settingInner(e))
        : loading(t('admin.reading_the_switch'))), '.is-warn.org-off');
  }

  function orgViewBody() {
    var d = S.org.data;
    if (!d) return S.org.error ? empty(S.org.error) : loading(t('admin.reading_the_organisation'));
    if (!d.enabled) return offCard(S.section === 'orgsetup' ? '' : t('admin.setup_has_its_other_settings'));
    if (!d.loaded) {
      return card(t('admin.on_and_not_read_yet'), frag(
        h('p.about', t('admin.the_switch_is_on_but_the')
          + t('admin.registers_the_job_in_qbx_core')),
        h('div.btn-row', writeBtn('.primary', 'org-setup', {}, t('admin.create_sync_job'),
          t('admin.click_again_register') + String(d.job || t('admin.the_job')) + t('admin.in_qbx_core'), 'rotate')),
        orgAnswer('setup')), '.is-warn');
    }
    switch (S.section) {
      case 'orgroles': return orgRolesBody(d);
      case 'orgmembers': return orgMembersBody(d);
      case 'orgapps': return orgAppsBody(d);
      case 'orgfunds': return orgFundsBody(d);
      case 'orgaccess': return orgAccessBody(d);
      case 'orgnotices': return orgNoticesBody(d);
      case 'orgwork': return orgWorkBody(d);
      case 'orgarmory': return orgArmoryBody(d);
      case 'orgrecord': return orgRecordBody(d);
      case 'orgturf': return orgTurfBody(d);
      case 'bpmatrix': return bpMatrixBody(d);
      case 'bplimits': return bpLimitsBody(d);
      case 'bpoffice': return bpOfficeBody(d);
      default: return orgSetupBody(d);
    }
  }

  function roleName(d, grade) {
    var r = asList(d.roles).filter(function (x) { return Number(x.grade) === Number(grade); })[0];
    return r ? String(r.label || r.name || t('admin.grade_n', grade)) : t('admin.grade_n', grade);
  }
  function memberOf(d, ref) {
    return asList(d.members).filter(function (m) { return String(m.ref) === String(ref); })[0];
  }
  function powerOf(d, code) {
    return asList(d.powers).filter(function (p) { return p.code === code; })[0];
  }
  function powerName(d, code) {
    if (code === 'TAKE') return t('admin.take_contracts');
    var p = powerOf(d, code);
    return p ? String(p.label) : String(code);
  }
  function roleOptions(d) {
    return asList(d.roles).map(function (r) { return { value: String(r.grade), label: String(r.grade) + ' · ' + roleName(d, r.grade) }; });
  }

  /* -- Setup -- */

  /** Several organisations (Organisation.SeveralOrganisations): which one
      every Hitman organisation, Boss permissions and Locations view works
      on, and adding or taking one off. Nothing while the switch is off. */
  function orgPickCard(d) {
    if (!d.several) return null;
    var orgs = asList(d.orgs);
    var full = orgs.length >= Number(d.maxOrgs || 1);
    return card(t('admin.organisations'), frag(
      h('p.about', t('admin.each_organisation_is_its_own_qbx')
        + t('admin.permissions_pick_the_one_every_hitman')
        + t('admin.citizen_is_a_member_of_one')),
      h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', 'Organisation'), h('th', t('admin.job')), h('th', t('admin.members')), h('th', ''))),
        h('tbody', orgs.map(function (o) {
          var on = String(o.id) === String(d.id);
          return h('tr' + (on ? '.is-on' : ''),
            h('td', String(o.label || o.id), o.first ? h('span.chip.is-label', 'config.lua') : null),
            h('td.mono', String(o.job || o.id)), h('td', num(o.members || 0)),
            h('td', h('div.btn-row',
              on ? h('span.chip.is-label', t('admin.working_on_this_one'))
                : h('button.btn', { type: 'button', 'data-act': 'org-scope', 'data-id': String(o.id) }, t('admin.work_on_this')),
              (!o.first && !on) ? writeBtn('.danger', 'org-remove', { 'data-id': String(o.id) }, t('admin.take_off'),
                t('admin.click_again_take') + String(o.label || o.id) + t('admin.off_the_list'), 'trash') : null)));
        })))),
      orgAnswer('orgremove'),
      h('h4', t('admin.add_an_organisation')),
      full ? h('p.about', t('admin.at_the_most_organisations_staff_set')
        + num(d.maxOrgs) + ').') : frag(
        h('div.toolbar',
          field('org.new.job', { class: 'is-mid', maxlength: '32', placeholder: t('admin.job_name_e_g_syndicate'),
            'aria-label': t('admin.new_organisation_job_name') }),
          field('org.new.label', { class: 'is-grow', maxlength: '64', placeholder: t('admin.label_players_see'),
            'aria-label': t('admin.new_organisation_label') }),
          writeBtn('.primary', 'org-create', {}, t('admin.add'), t('admin.click_again_add_this_organisation'), 'plus')),
        orgAnswer('orgcreate'))));
  }

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
      orgPickCard(d),
      card(t('admin.the_job_2'), frag(
        h('dl.facts',
          h('dt', t('admin.job_qbx_core')), h('dd.mono', String(d.job || '—')),
          h('dt', t('admin.label')), h('dd', String(d.label || '—')),
          h('dt', t('admin.type')), h('dd', String(d.type || '—')),
          h('dt', t('admin.only_members_may_accept')), h('dd', d.requireJob ? t('admin.yes') : t('admin.no')),
          h('dt', t('admin.members')), h('dd', num(members.length) + ' · ' + num(online) + t('admin.in_the_city_2')),
          h('dt', t('admin.roles')), h('dd', num(asList(d.roles).length)),
          h('dt', t('admin.funds')), h('dd', money(d.balance) + ' · ' + (d.bank ? t('admin.renewed_banking_society_account')
            : t('admin.this_resources_own_ledger')))),
        warnings.length ? h('ul.warnings', warnings.map(function (w) { return h('li', String(w)); })) : null,
        h('div.btn-row', writeBtn('', 'org-setup', {}, t('admin.create_sync_job'),
          t('admin.click_again_register') + String(d.job || t('admin.the_job')) + t('admin.in_qbx_core'), 'rotate')),
        orgAnswer('setup'))),
      card(t('admin.rename'), frag(
        h('p.about', t('admin.the_label_players_see_never_the')),
        h('div.toolbar', field('org.label', { class: 'is-grow', value: String(d.label || ''), maxlength: '64',
          'aria-label': 'Organisation label' }),
          writeBtn('', 'org-rename', {}, t('admin.rename'), t('admin.click_again_to_rename'), 'pen')),
        orgAnswer('rename'))),
      card(t('admin.boss_menu'), frag(
        h('p.about', t('admin.what_each_tab_of_the_phones')),
        h('div.table-wrap', h('table.grid',
          h('thead', h('tr', h('th', t('admin.tab')), h('th', t('admin.label')), h('th', t('admin.hidden_from')))),
          h('tbody', ORG_TABS.map(function (tab) {
            var hidden = (layout.hidden && layout.hidden[tab]) || asList((saved.hidden || {})[tab]).map(String);
            return h('tr', h('td.mono', tab),
              h('td', field('org.tab.' + tab, { class: 'is-mid', maxlength: '24',
                value: String(((saved.labels || {})[tab]) || ''), placeholder: tab, 'aria-label': t('admin.label_of') + tab })),
              h('td', h('div.chips', asList(d.roles).map(function (r) {
                var on = hidden.indexOf(String(r.grade)) !== -1;
                return h('button.chip.is-link' + (on ? '.is-warn' : ''), { type: 'button', 'data-act': 'org-tab-hide',
                  'data-value': tab, 'data-id': String(r.grade), 'aria-pressed': on ? 'true' : 'false' },
                  roleName(d, r.grade));
              }))));
          })))),
        h('div.btn-row', writeBtn('', 'org-layout', {}, t('admin.save_the_boss_menu'), t('admin.click_again_save_the_boss_menu'), 'check')),
        orgAnswer('layout'))),
      card(t('admin.settings_2'), rows.length ? h('div.stack', rows.map(settingRow))
        : (S.settings.data ? empty(t('admin.no_organisation_settings')) : loading(t('admin.reading_the_settings')))));
  }

  /* -- Roles & pay -- */

  function orgRolesBody(d) {
    var roles = asList(d.roles);
    var sel = S.org.role != null ? roles.filter(function (r) { return Number(r.grade) === Number(S.org.role); })[0] : null;
    return frag(
      card(t('admin.roles'), roles.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th.num', t('admin.grade')), h('th', t('admin.name')), h('th', t('admin.label')), h('th.num', t('admin.pay_per_cycle')),
          h('th', t('admin.boss')), h('th.num', t('admin.members')), h('th', ''))),
        h('tbody', roles.map(function (r) {
          return h('tr' + (sel && Number(sel.grade) === Number(r.grade) ? '.is-open' : ''),
            h('td.num', num(r.grade)), h('td.mono', String(r.name || '—')), h('td', String(r.label || '—'),
              r.locked ? h('span.chip.is-warn', 'locked') : null),
            h('td.num', money(r.pay)), h('td', r.boss ? h('span.chip.is-panel', 'boss') : '—'),
            h('td.num', num(r.members)),
            h('td', btn('.is-small.ghost', 'org-role-open', { 'data-id': String(r.grade) }, t('admin.edit_powers'), 'pen')));
        })))) : empty(t('admin.no_roles_yet_add_one_below')), '', h('span.sub', num(roles.length))),
      sel ? orgRoleCard(d, sel) : null,
      card(t('admin.add_a_role'), frag(
        h('div.toolbar',
          field('org.new.grade', { class: 'is-short', inputmode: 'numeric', placeholder: t('admin.grade'), 'aria-label': t('admin.grade') }),
          field('org.new.name', { class: 'is-mid', maxlength: '64', placeholder: t('admin.name_job_grade'), 'aria-label': t('admin.name') }),
          field('org.new.label', { class: 'is-mid', maxlength: '64', placeholder: t('admin.label'), 'aria-label': t('admin.label') }),
          field('org.new.pay', { class: 'is-short', inputmode: 'numeric', placeholder: '$ pay', 'aria-label': t('admin.pay') }),
          segmented('org-new-boss', [{ value: 'no', label: t('admin.not_boss') }, { value: 'yes', label: t('admin.boss') }],
            S.org.newBoss ? 'yes' : 'no'),
          writeBtn('.primary', 'org-role-add', {}, t('admin.add_role'), t('admin.click_again_to_add'), 'plus')),
        orgAnswer('role-add'))));
  }

  function orgRoleCard(d, r) {
    var g = String(r.grade);
    var ceiling = (d.ceiling && d.ceiling.role && d.ceiling.role[g]) || {};
    var powers = r.powers || {};
    var codes = [{ code: 'TAKE', area: 'contracts', label: t('admin.take_contracts'), about: t('admin.may_accept_contracts_when_only')
      + t('admin.roles_given_it_may_config_organisation') }].concat(asList(d.powers));
    return card(t('admin.role_x', roleName(d, r.grade)), frag(
      h('div.toolbar',
        h('label.st-pair', h('span', t('admin.name')), field('org.role.' + g + '.name', { class: 'is-mid', value: String(r.name || ''),
          maxlength: '64', 'aria-label': t('admin.name') })),
        h('label.st-pair', h('span', t('admin.label')), field('org.role.' + g + '.label', { class: 'is-mid',
          value: String(r.label || ''), maxlength: '64', 'aria-label': t('admin.label') })),
        h('label.st-pair', h('span', 'Pay $'), field('org.role.' + g + '.pay', { class: 'is-short', inputmode: 'numeric',
          value: String(r.pay == null ? '' : r.pay), 'aria-label': t('admin.pay') })),
        h('label.st-pair', h('span', t('admin.grade')), field('org.role.' + g + '.grade', { class: 'is-short', inputmode: 'numeric',
          value: g, 'aria-label': t('admin.grade_order') }))),
      h('div.toolbar',
        segmented('org-role-boss', [{ value: 'no', label: t('admin.not_boss') }, { value: 'yes', label: t('admin.boss') }],
          (S.org.staged['boss:' + g] != null ? S.org.staged['boss:' + g] : !!r.boss) ? 'yes' : 'no', { 'data-id': g }),
        segmented('org-role-lock', [{ value: 'no', label: t('admin.bosses_may_edit') }, { value: 'yes', label: t('admin.locked') }],
          (S.org.staged['lock:' + g] != null ? S.org.staged['lock:' + g] : !!r.locked) ? 'yes' : 'no', { 'data-id': g }),
        writeBtn('.primary', 'org-role-save', { 'data-id': g }, t('admin.save_role'), t('admin.click_again_to_save'), 'check'),
        writeBtn('.danger', 'org-role-remove', { 'data-id': g, disabled: Number(r.members) > 0 || null,
          title: Number(r.members) > 0 ? t('admin.a_role_cannot_be_removed_while') : null },
          t('admin.remove_role'), t('admin.click_again_remove') + roleName(d, r.grade), 'trash-can')),
      Number(r.members) > 0 ? h('p.note', t('admin.a_role_cannot_be_removed_while_2')) : null,
      orgAnswer('role:' + g),
      h('h3.st-group-title', t('admin.powers_of_this_role')),
      h('p.hint', t('admin.what_members_holding_this_role_may')
        + t('admin.for_the_role_or_them_greyed')),
      h('div.table-wrap', h('table.grid.org-powers',
        h('tbody', codes.map(function (p) {
          var on = !!powers[p.code];
          var above = p.code !== 'TAKE' && ceiling[p.code] !== 'allow';
          return h('tr' + (above ? '.is-dim' : ''),
            h('td', h('b', String(p.label)), h('span.sub', ' ' + String(AREA_NAMES[p.area] || p.area || ''))),
            h('td.detail', String(p.about || '')),
            h('td', above ? h('span.chip', t('admin.above_the_ceiling')) : h('span.chip.is-panel', t('admin.within_the_ceiling'))),
            h('td', writeBtn('.is-small' + (on ? '.primary' : ''), 'org-role-power', { 'data-id': g,
              'data-power': p.code, 'data-value': on ? 'off' : 'on' }, on ? t('admin.given') : t('admin.not_given'),
              on ? t('admin.click_again_take_from', p.label, roleName(d, r.grade))
                : t('admin.click_again_give_to', p.label, roleName(d, r.grade)), on ? 'check' : 'plus')));
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
      card(t('admin.hire'), frag(
        h('p.about', player ? t('admin.hire_the_player_selected_in_players') + String(player.name || 'them') + t('admin.into_a_role')
          : t('admin.look_a_player_up_in_players')),
        h('div.toolbar',
          player ? h('span.chip.is-live', icon('user'), ' ', String(player.name || t('admin.no_name_on_record')))
            : field('org.hire.cid', { class: 'is-mid', placeholder: t('admin.exact_citizen_id'), maxlength: '64',
              'aria-label': t('admin.citizen_id') }),
          h('span.sub', 'as'),
          h('div.seg', { role: 'group' }, asList(d.roles).map(function (r) {
            var on = String(r.grade) === String(hireGrade);
            return h('button.seg-btn' + (on ? '.is-on' : ''), { type: 'button', 'data-act': 'org-hire-grade',
              'data-value': String(r.grade), 'aria-pressed': on ? 'true' : 'false' }, roleName(d, r.grade));
          })),
          writeBtn('.primary', 'org-hire', {}, t('admin.hire'), t('admin.click_again_to_hire'), 'user-plus')),
        orgAnswer('hire'))),
      card(t('admin.members'), members.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.name')), h('th', t('admin.role')), h('th', t('admin.in_the_city_3')), h('th', t('admin.joined')), h('th', t('admin.last_seen')),
          h('th', t('admin.flags')), h('th', ''))),
        h('tbody', members.map(function (m) {
          var suspended = m.suspendedUntil && Number(m.suspendedUntil) > nowSeconds();
          return h('tr' + (sel && sel.ref === m.ref ? '.is-open' : ''),
            h('td.name', String(m.name || '—')), h('td', String(m.role || roleName(d, m.grade))),
            h('td', m.online ? h('span.chip.is-live', 'yes') : 'no'),
            h('td.nowrap', m.joined ? ago(m.joined) : '—'), h('td.nowrap', m.lastSeen ? ago(m.lastSeen) : '—'),
            h('td', m.boss ? h('span.chip.is-panel', 'boss') : null, m.locked ? h('span.chip.is-warn', 'locked') : null,
              suspended ? h('span.chip.is-warn', 'suspended') : null,
              Object.keys(m.grants || {}).length ? h('span.chip', t('admin.n_granted', num(Object.keys(m.grants).length))) : null,
              Object.keys(m.denies || {}).length ? h('span.chip', t('admin.n_denied', num(Object.keys(m.denies).length))) : null),
            h('td', btn('.is-small.ghost', 'org-member-open', { 'data-id': String(m.ref) }, t('admin.manage'), 'pen')));
        })))) : empty(t('admin.nobody_is_a_member_yet_hire')), '', h('span.sub', num(members.length))),
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
    return card(t('admin.member_x', name), frag(
      h('dl.facts',
        h('dt', t('admin.role')), h('dd', roleName(d, m.grade)),
        h('dt', t('admin.holds_now')), h('dd', held.length ? held.map(function (c) { return powerName(d, c); }).join(', ') : 'nothing'),
        h('dt', t('admin.own_grants')), h('dd', Object.keys(grants).length ? Object.keys(grants).map(function (c) {
          return powerName(d, c) + (grants[c].inactive ? t('admin.inactive_paren', String(grants[c].inactive)) : '')
            + t('admin.by_x', String(grants[c].by));
        }).join(', ') : 'none'),
        h('dt', t('admin.own_denies')), h('dd', Object.keys(denies).length ? Object.keys(denies).map(function (c) {
          return powerName(d, c) + t('admin.by_x', String(denies[c]));
        }).join(', ') : 'none'),
        h('dt', t('admin.limits')), h('dd', (limits.maxAtOnce ? num(limits.maxAtOnce) + t('admin.at_once') : t('admin.servers_at_once')) + ' · '
          + (limits.cooldownMinutes != null ? num(limits.cooldownMinutes) + t('admin.min_between_accepts') : t('admin.servers_cooldown'))),
        m.suspendedUntil ? h('dt', t('admin.suspended_until')) : null, m.suspendedUntil ? h('dd', when(m.suspendedUntil)) : null),
      h('h3.st-group-title', t('admin.role')),
      h('div.toolbar',
        h('div.seg', { role: 'group' }, asList(d.roles).map(function (r) {
          var on = String(r.grade) === String(roleSel);
          return h('button.seg-btn' + (on ? '.is-on' : ''), { type: 'button', 'data-act': 'org-member-grade',
            'data-id': ref, 'data-value': String(r.grade) }, roleName(d, r.grade));
        })),
        writeBtn('', 'org-member-role', { 'data-id': ref }, t('admin.set_role'), t('admin.click_again_to_set'), 'id-badge')),
      orgAnswer('role-of:' + ref),
      h('h3.st-group-title', t('admin.suspend_from_contracts')),
      h('div.toolbar',
        field('org.m.' + ref + '.hours', { class: 'is-short', inputmode: 'numeric', placeholder: t('admin.hours_0_lifts'),
          'aria-label': t('admin.hours') }),
        field('org.m.' + ref + '.sreason', { class: 'is-grow', maxlength: '160', placeholder: t('admin.reason_kept_in_the_log_2'),
          'aria-label': t('admin.reason') }),
        writeBtn('', 'org-member-suspend', { 'data-id': ref }, t('admin.suspend'), t('admin.click_again_to_suspend'), 'ban')),
      orgAnswer('suspend:' + ref),
      h('h3.st-group-title', t('admin.own_limits')),
      h('div.toolbar',
        h('label.st-pair', h('span', t('admin.at_once_2')), field('org.m.' + ref + '.at', { class: 'is-short', inputmode: 'numeric',
          value: limits.maxAtOnce == null ? '' : String(limits.maxAtOnce), placeholder: '1-50', 'aria-label': t('admin.at_once_2') })),
        h('label.st-pair', h('span', t('admin.cooldown_min')), field('org.m.' + ref + '.cd', { class: 'is-short',
          inputmode: 'numeric', value: limits.cooldownMinutes == null ? '' : String(limits.cooldownMinutes),
          placeholder: '0-10080', 'aria-label': t('admin.cooldown_minutes') })),
        writeBtn('', 'org-member-limits', { 'data-id': ref }, t('admin.save_limits'), t('admin.click_again_to_save'), 'check')),
      orgAnswer('limits:' + ref),
      h('h3.st-group-title', t('admin.a_power_of_their_own')),
      h('div.toolbar',
        dropdown('org-mpower:' + ref),
        segmented('org-member-state', [{ value: 'grant', label: t('admin.grant') }, { value: 'deny', label: t('admin.deny') },
          { value: 'clear', label: t('admin.clear') }], state, { 'data-id': ref }),
        writeBtn('', 'org-member-grant', { 'data-id': ref, 'data-power': power }, t('admin.save'), t('admin.click_again_to_save'), 'key')),
      orgAnswer('grant:' + ref),
      h('h3.st-group-title', t('admin.codename_and_lock')),
      h('div.toolbar',
        field('org.m.' + ref + '.codename', { class: 'is-mid', maxlength: '32', placeholder: t('admin.codename_empty_clears'),
          'aria-label': t('admin.codename') }),
        writeBtn('', 'org-member-codename', { 'data-id': ref }, t('admin.save_codename'), t('admin.click_again_to_save'), 'mask'),
        writeBtn('', 'org-member-lock', { 'data-id': ref, 'data-value': m.locked ? 'off' : 'on' },
          m.locked ? t('admin.unlock') : t('admin.lock_against_boss_edits'),
          m.locked ? t('admin.click_again_let_bosses_edit') + name : t('admin.click_again_lock') + name, m.locked ? 'unlock' : 'lock')),
      orgAnswer('staff:' + ref),
      h('h3.st-group-title', t('admin.fire')),
      h('div.toolbar',
        field('org.m.' + ref + '.freason', { class: 'is-grow', maxlength: '200', placeholder: t('admin.reason_kept_in_the_log_2'),
          'aria-label': t('admin.reason_for_firing') }),
        writeBtn('.danger', 'org-member-fire', { 'data-id': ref }, t('admin.fire'), t('admin.click_again_fire') + name, 'user-minus')),
      orgAnswer('fire:' + ref)), '.is-identity');
  }

  Text.later(function () {
    DD['org-mpower'] = {
    prefix: t('admin.power'),
    options: function () {
      var d = S.org.data || {};
      return [{ value: 'TAKE', label: t('admin.take_contracts') }].concat(asList(d.powers).map(function (p) {
        return { value: p.code, label: String(p.label) };
      }));
    },
    value: function (ref) {
      var d = S.org.data || {};
      return S.org.staged['power:' + ref] || (asList(d.powers)[0] || {}).code || 'M1';
    },
    pick: function (v, ref) { disarm(); S.org.staged['power:' + ref] = v; drawOrg(); }
  };
  });

  /* -- Applications -- */

  function orgAppsBody(d) {
    var apps = asList(d.applications);
    var x = d.extras2 || {};
    var form = null;
    if (x.Recruitment) {
      var qs = asList(x.form);
      var most = Number(x.formMax) || 0;
      var rows = [];
      for (var i = 0; i < most; i += 1) {
        rows.push(h('div.toolbar', field('org.form.q' + i, { class: 'is-grow', maxlength: '200',
          value: qs[i] !== undefined ? String(qs[i]) : '', placeholder: t('admin.question_n_empty_none', i + 1),
          'aria-label': t('admin.question_n', i + 1) })));
      }
      form = card(t('admin.application_form'), frag(
        h('p.about', t('admin.the_questions_an_applicant_answers_up') + most + t('admin.bosses_holding_edit_application_form')
          + t('admin.set_them_too')),
        rows.length ? h('div.stack', rows) : empty(t('admin.questions_on_the_form_at_most')),
        h('div.btn-row', writeBtn('.primary', 'org-form-save', { 'data-count': String(most) }, t('admin.save_the_form'),
          t('admin.click_again_save_these_questions'), 'check')),
        orgAnswer('form')));
    }
    return frag(form, card(t('admin.applications'), apps.length ? h('div.stack', apps.map(function (a) {
      var id = String(a.id);
      return h('article.card.org-app',
        h('header.card-head', h('h3', String(a.name || t('admin.applicant'))), h('span.sub', a.at ? ago(a.at) : '')),
        h('p.al-text', String(a.body || '')),
        asList(a.form).length ? h('div.stack', asList(a.form).map(function (f) {
          return h('div.org-answer', h('p.sub', String(f.q || '')), h('blockquote.org-notice', String(f.a || '')));
        })) : null,
        x.Recruitment ? frag(
          a.note ? h('p.sub', t('admin.interview_note') + String(a.note.by || t('admin.staff')) + '): ' + String(a.note.text || '')) : null,
          h('div.toolbar', field('org.note.' + id, { class: 'is-grow', maxlength: '2000',
            placeholder: t('admin.interview_note_2'), 'aria-label': t('admin.interview_note_2') }),
            writeBtn('.ghost', 'org-note-save', { 'data-id': id }, t('admin.save_note'), t('admin.click_again_save_the_note'), 'pen'),
            a.note ? writeBtn('.ghost', 'org-note-clear', { 'data-id': id }, t('admin.clear'), t('admin.click_again_clear_the_note'),
              'eraser') : null)) : null,
        h('div.btn-row',
          writeBtn('.primary', 'org-app', { 'data-id': id, 'data-value': 'yes' }, t('admin.accept'),
            t('admin.click_again_hire') + String(a.name || 'them') + t('admin.into_the_lowest_role'), 'check'),
          writeBtn('.danger', 'org-app', { 'data-id': id, 'data-value': 'no' }, t('admin.reject'),
            t('admin.click_again_reject') + String(a.name || 'them'), 'xmark')),
        orgAnswer('app:' + id));
    })) : empty(t('admin.no_open_applications_players_apply_from')),
    '', h('span.sub', num(apps.length))));
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
          'aria-label': t('admin.label_percent', label) }),
          writeBtn('.is-small', 'org-cut', { 'data-value': kind }, t('admin.save'), t('admin.click_again_to_save'), 'check'))));
    }
    return frag(
      h('div.tiles',
        tile(t('admin.balance'), frag(h('p.big', fundsReady(d, f) ? money(f ? f.balance : d.balance) : t('admin.unknown')),
          h('p.sub', fundsReady(d, f) ? (fundsBackend(d, f) === 'bank' ? t('admin.renewed_banking_society_account')
            : t('admin.this_resources_own_ledger')) : t('admin.the_bank_is_not_answering_the'))),
          fundsReady(d, f) ? '' : '.is-warn')),
      fundsBackendCard(d, f),
      card(t('admin.move_money'), frag(
        h('p.about', t('admin.staff_money_into_the_funds_or')
          + t('admin.sent_once_however_often_it_is')),
        h('div.toolbar',
          segmented('org-dir', [{ value: 'deposit', label: t('admin.deposit') }, { value: 'withdraw', label: t('admin.withdraw') },
            { value: 'bonus', label: t('admin.bonus_to_a_member') }], dir),
          dir === 'bonus' ? dropdown('org-bonus-to') : null),
        h('div.toolbar',
          field('org.funds.amount', { class: 'is-short', inputmode: 'numeric', placeholder: '$ amount', 'aria-label': t('admin.amount') }),
          field('org.funds.reason', { class: 'is-grow', maxlength: '200', placeholder: t('admin.reason_kept_in_the_log_2'),
            'aria-label': t('admin.reason') }),
          writeBtn('.primary', 'org-funds', {}, dir === 'deposit' ? t('admin.deposit') : dir === 'withdraw' ? t('admin.withdraw') : t('admin.pay_bonus'),
            t('admin.click_again_2'), dir === 'withdraw' ? 'arrow-up-from-bracket' : 'arrow-down-to-bracket')),
        orgAnswer('funds'))),
      card(t('admin.cuts'), frag(
        h('p.about', t('admin.the_share_of_what_a_member')
          + t('admin.accepts_it_a_change_never_touches')
          + t('admin.of_one_payout') + num(cap) + t('admin.a_boss_only_within_the_limits')),
        h('div.table-wrap', h('table.grid',
          h('thead', h('tr', h('th', t('admin.cut')), h('th.num', t('admin.now')), h('th.num', t('admin.staff_may_set')), h('th.num', t('admin.a_boss_may_set')),
            h('th', ''))),
          h('tbody',
            cutRow('payout', t('admin.organisation_cut_of_payouts'), cuts.payout, Math.min(cap, Number(lim.CutMaxPercent) || 0)),
            cutRow('stake', t('admin.cut_on_stakes'), cuts.stake, Math.min(cap, Number(lim.StakeCutMaxPercent) || 0)),
            cutRow('buyout', t('admin.cut_on_buyouts'), cuts.buyout, Math.min(cap, Number(lim.BuyoutCutMaxPercent) || 0)),
            asList(d.roles).map(function (r) {
              var v = (cuts.byRole || {})[String(r.grade)];
              return h('tr', h('td', t('admin.role_x', roleName(d, r.grade))), h('td.num', v == null ? t('admin.as_the_organisation') : num(v) + '%'),
                h('td.num', '0–' + num(cap) + '%'), h('td.num', '0–' + num(Math.min(cap, Number(lim.CutMaxPercent) || 0)) + '%'),
                h('td', h('div.inline-form', field('org.cut.role.' + r.grade, { class: 'is-short', inputmode: 'numeric',
                  placeholder: '%', 'aria-label': t('admin.cut_for') + roleName(d, r.grade) }),
                  writeBtn('.is-small', 'org-cut', { 'data-value': 'role', 'data-id': String(r.grade) }, t('admin.save'),
                    t('admin.click_again_to_save'), 'check'),
                  v == null ? null : writeBtn('.is-small.ghost', 'org-cut-clear', { 'data-id': String(r.grade) },
                    t('admin.clear'), t('admin.click_again') + roleName(d, r.grade) + t('admin.as_the_organisation_2'), 'eraser'))));
            })))),
        byMember ? h('p.note', tn('admin.members_with_cuts', byMember, num(byMember))) : null,
        orgAnswer('cut'))),
      card(t('admin.ledger'), f ? (asList(f.rows).length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.when')), h('th', t('admin.kind')), h('th.num', t('admin.amount')), h('th', t('admin.reason')), h('th', t('admin.contract')),
          canIdentify() ? h('th', t('admin.by_2')) : null)),
        h('tbody', asList(f.rows).map(function (r) {
          return h('tr', h('td.nowrap', when(r.at)), h('td', String(r.kind || '—')), h('td.num', money(r.amount)),
            h('td', String(r.reason || '—')),
            h('td', r.contract ? h('button.link.mono', { type: 'button', 'data-act': 'contract', 'data-id': String(r.contract) },
              String(r.contract)) : '—'),
            canIdentify() ? h('td.mono', String(r.actor || '—')) : null);
        })))) : empty(t('admin.nothing_has_moved_yet')))
        : (S.org.fundsError ? empty(S.org.fundsError) : loading(t('admin.reading_the_ledger'))), '',
        btn('.is-small.ghost', 'org-funds-refresh', {}, t('admin.refresh'), 'rotate')));
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
    var otherName = other === 'bank' ? 'Renewed-Banking' : t('admin.this_resources_own_ledger');
    return card(t('admin.where_the_funds_are_kept'), frag(
      h('p.about', t('admin.now_x', now === 'bank' ? t('admin.renewed_bankings_society_account') : t('admin.this_resources_own_ledger'))
        + (ready ? '.' : t('admin.which_is_not_answering')) + t('admin.switching_moves_the_balance_to_the')),
      // A switch carries the balance across, so it needs Renewed-Banking
      // answering on both sides (Funds.switch): while the bank is down the
      // only way off it is Abandon, and the server refuses a plain switch.
      h('div.btn-row', writeBtn('', 'org-backend', { 'data-value': other,
        title: ready ? null : t('admin.the_bank_is_not_answering_a') },
        t('admin.switch_to') + otherName, t('admin.click_again_move_the_funds_to') + otherName, 'right-left', false,
        ready ? undefined : false)),
      !ready && now === 'bank' ? h('div.org-abandon',
        h('p.note.is-error', t('admin.the_bank_is_down_abandon_leaves')
          + otherName + t('admin.and_whatever_the_bank_holds_is')
          + t('admin.come_back')),
        h('div.btn-row', writeBtn('.danger', 'org-backend', { 'data-value': other, 'data-how': 'abandon' },
          t('admin.abandon_the_bank'), t('admin.click_again_abandon_the_bank_start') + otherName, 'triangle-exclamation')))
        : null,
      orgAnswer('backend')), ready ? '' : '.is-warn');
  }

  /* -- Contract access -- */

  function orgAccessBody(d) {
    var access = d.access || {};
    return frag(
      card(t('admin.which_contracts_each_role_may_take'), frag(
        h('p.about', t('admin.only_ever_stricter_than_the_servers')
          + t('admin.organisations_own')),
        h('div.org-access', asList(d.roles).map(function (r) {
          var g = String(r.grade);
          var a = access[g] || {};
          var rule = S.org.staged['rule:' + g] != null ? S.org.staged['rule:' + g] : (a.rule || '');
          var wl = S.org.staged['wl:' + g] != null ? S.org.staged['wl:' + g] : (a.whitelisted === false ? 'no' : 'yes');
          return h('div.org-access-role',
            h('b', roleName(d, g)),
            h('div.toolbar',
              h('label.st-pair', h('span', t('admin.most_reward')), field('org.acc.' + g + '.max', { class: 'is-short',
                inputmode: 'numeric', value: a.maxReward == null ? '' : String(a.maxReward), 'aria-label': t('admin.most_reward_2') })),
              h('label.st-pair', h('span', t('admin.at_once_2')), field('org.acc.' + g + '.at', { class: 'is-short',
                inputmode: 'numeric', value: a.maxAtOnce == null ? '' : String(a.maxAtOnce), 'aria-label': t('admin.at_once_2') })),
              h('label.st-pair', h('span', t('admin.cooldown_min')), field('org.acc.' + g + '.cd', { class: 'is-short',
                inputmode: 'numeric', value: a.cooldownMinutes == null ? '' : String(a.cooldownMinutes),
                'aria-label': t('admin.cooldown') }))),
            h('div.toolbar',
              segmented('org-acc-rule', [{ value: '', label: t('admin.any_rule') }, { value: 'alive', label: t('admin.alive_only') },
                { value: 'either', label: t('admin.kill_or_alive') }], rule, { 'data-id': g }),
              segmented('org-acc-wl', [{ value: 'yes', label: t('admin.whitelisted_job_targets_allowed') },
                { value: 'no', label: t('admin.not_on_whitelisted_jobs') }], wl, { 'data-id': g }),
              writeBtn('.is-small', 'org-access', { 'data-id': g }, t('admin.save'), t('admin.click_again_save_for') + roleName(d, g),
                'check')));
        })),
        orgAnswer('access'))),
      card(t('admin.boss_pick'), frag(
        h('p.about', t('admin.pin_a_contract_to_a_member')),
        h('div.toolbar',
          field('org.pick.id', { class: 'is-mid', maxlength: '64', placeholder: t('admin.contract_id'), 'aria-label': t('admin.contract_id') }),
          dropdown('org-pick-to'),
          writeBtn('', 'org-pick', {}, t('admin.pick'), t('admin.click_again_2'), 'thumbtack')),
        orgAnswer('pick'))));
  }

  /** A member to pick from a list, drawn as a dropdown (a roster can be long). */
  function memberOptions(first) {
    return [{ value: '', label: first }].concat(asList((S.org.data || {}).members).map(function (m) {
      return { value: String(m.ref), label: String(m.name || '—') };
    }));
  }
  Text.later(function () {
    DD['org-pick-to'] = {
    prefix: t('admin.member'),
    options: function () { return memberOptions(t('admin.nobody_clear_the_pick')); },
    value: function () { return S.org.staged.pick || ''; },
    pick: function (v) { disarm(); S.org.staged.pick = v; drawOrg(); }
  };
  });
  Text.later(function () {
    DD['org-bonus-to'] = {
    prefix: t('admin.to'),
    options: function () { return memberOptions(t('admin.pick_a_member')); },
    value: function () { return S.org.bonusTo || ''; },
    pick: function (v) { disarm(); S.org.bonusTo = v; drawOrg(); }
  };
  });

  /* -- Notices -- */

  function orgNoticesBody(d) {
    var n = d.notice;
    var text = n && typeof n === 'object' ? n.text : null;
    return card(t('admin.the_board_notice'), frag(
      text ? h('blockquote.org-notice', String(text)) : empty(t('admin.no_notice_posted')),
      n && n.at ? h('p.sub', t('admin.posted_x', ago(n.at))) : null,
      h('div.toolbar',
        field('org.notice', { class: 'is-grow', maxlength: String((d.limits || {}).NoticeMaxLength || 2000),
          placeholder: t('admin.new_notice'), 'aria-label': t('admin.notice') })),
      h('div.toolbar',
        segmented('org-broadcast', [{ value: 'no', label: t('admin.on_the_board') }, { value: 'yes', label: t('admin.and_message_every_member') }],
          S.org.staged.broadcast ? 'yes' : 'no'),
        writeBtn('.primary', 'org-notice', {}, t('admin.post'), t('admin.click_again_to_post'), 'thumbtack'),
        text ? writeBtn('.ghost', 'org-notice-clear', {}, t('admin.take_it_down'), t('admin.click_again_take_the_notice_down'), 'eraser')
          : null),
      orgAnswer('notice')));
  }

  /* -- Work & channel: the organisation extras (server/org/extras.lua) -- */

  var DOSSIER_RULES;
  Text.later(function () {
    DOSSIER_RULES = [{ value: 'discreet', label: t('admin.discreet') }, { value: 'clean', label: t('admin.clean') },
    { value: 'open', label: t('admin.open') }];
  });

  Text.later(function () {
    DD['org-work-member'] = {
    prefix: t('admin.to'),
    options: function () {
      return [{ value: '', label: t('admin.pick_a_member') }].concat(asList((S.org.data || {}).members).map(function (m) {
        return { value: String(m.ref), label: String(m.name || 'member') + (m.onDuty === false ? t('admin.off_duty') : '') };
      }));
    },
    value: function (id) { return S.org.work.member[id] || ''; },
    pick: function (v, id) { disarm(); S.org.work.member[id] = v; }
  };
  });
  Text.later(function () {
    DD['org-work-spot'] = {
    prefix: t('admin.meet_at'),
    options: function () {
      var w = ((S.org.data || {}).extras || {}).work || {};
      return [{ value: '', label: t('admin.no_spot') }].concat(asList(w.spots).map(function (p) {
        return { value: String(p.id), label: String(p.label || t('admin.meeting_spot')) };
      }));
    },
    value: function (id) { return S.org.work.spot[id] || ''; },
    pick: function (v, id) { disarm(); S.org.work.spot[id] = v; }
  };
  });

  function dossierText(dz) {
    if (!dz) return null;
    return h('div.org-dossier',
      dz.notes ? h('blockquote.org-notice', String(dz.notes)) : null,
      h('p.sub', [dz.spot ? t('admin.meet_at_2') + String(dz.spot.label || t('admin.a_meeting_spot')) : null,
        dz.rulesText ? String(dz.rulesText) : null].filter(Boolean).join(' · ') || t('admin.notes_only')));
  }

  function orgWorkBody(d) {
    var x = d.extras;
    if (!x) {
      return card(t('admin.every_extra_is_switched_off'), h('p.about', t('admin.contracts_to_the_organisation_accept_approval')
        + t('admin.probation_duty_the_private_channel_and')
        + t('admin.each_boss_power_they_add_is')), '.is-warn');
    }
    var w = x.work || {};
    var parts = [];
    if (x.AcceptApproval) {
      var aps = asList(w.approvals);
      parts.push(card(t('admin.accepts_waiting_for_approval'), aps.length ? h('div.stack', aps.map(function (a) {
        var id = String(a.id);
        var who = String((a.member && a.member.name) || t('admin.a_member'));
        return h('article.card',
          h('header.card-head', h('h3', who + ' · ' + String(a.contractId || '')),
            h('span.sub', t('admin.about_min_left', Math.max(1, Math.ceil((Number(a.expiresIn) || 0) / 60))))),
          h('p.sub', t('admin.worth_nothing_taken_until_approved', money(a.worth), a.probation ? t('admin.on_probation') : '')),
          h('div.btn-row',
            writeBtn('.primary', 'org-work-approve', { 'data-id': id, 'data-value': 'yes' }, t('admin.approve'),
              t('admin.click_again_run') + who + t('admin.accept_now'), 'check'),
            writeBtn('.danger', 'org-work-approve', { 'data-id': id, 'data-value': 'no' }, t('admin.refuse'),
              t('admin.click_again_refuse_it_nothing_was'), 'xmark')),
          orgAnswer('ap:' + id));
      })) : empty(t('admin.no_accept_waits_for_approval')), '', h('span.sub', num(aps.length))));
    }
    if (x.OrgContracts) {
      var cs = asList(w.contracts);
      parts.push(card(t('admin.contracts_sent_to_the_organisation'), cs.length ? h('div.stack', cs.map(function (c) {
        var id = String(c.id);
        var who = c.member ? String(c.member.name || t('admin.a_member')) : null;
        return h('article.card',
          h('header.card-head', h('h3', String(c.targetName || t('admin.a_contract')) + ' · ' + id),
            h('span.sub', c.state === 'waiting' ? t('admin.not_assigned') : c.state === 'taken' ? t('admin.taken_by') + who
              : t('admin.assigned_to') + who)),
          h('p.sub', t('admin.worth_x', money(c.worth)) + (c.staked ? t('admin.staked_suffix') : '') + (c.expiresIn
            ? t('admin.on_the_open_board_in_about_min', Math.max(1, Math.ceil(Number(c.expiresIn) / 60))) : '.')),
          c.state !== 'taken' ? h('div.toolbar', dropdown('org-work-member:' + id),
            writeBtn('.primary', 'org-work-assign', { 'data-id': id }, c.state === 'waiting' ? t('admin.assign') : t('admin.reassign'),
              t('admin.click_again_give_it_to_the'), 'user-check'),
            writeBtn('.ghost', 'org-work-release', { 'data-id': id }, t('admin.send_to_the_open_board'),
              t('admin.click_again_put_it_on_the'), 'share')) : null,
          x.Dossiers ? dossierText(c.dossier) : null,
          x.Dossiers && c.state !== 'waiting' ? frag(
            h('div.toolbar', field('org.dossier.' + id, { class: 'is-grow', maxlength: '2000',
              placeholder: t('admin.dossier_notes_no_citizen_ids'), 'aria-label': t('admin.dossier_notes') })),
            h('div.toolbar', dropdown('org-work-spot:' + id),
              segmented('org-work-rules', DOSSIER_RULES, S.org.work.rules[id] || '', { 'data-id': id }),
              writeBtn('.ghost', 'org-work-dossier', { 'data-id': id }, t('admin.save_dossier'), t('admin.click_again_save_it'), 'file-pen'),
              c.dossier ? writeBtn('.ghost', 'org-work-dclear', { 'data-id': id }, t('admin.clear'),
                t('admin.click_again_clear_the_dossier'), 'eraser') : null)) : null,
          orgAnswer('work:' + id));
      })) : empty(t('admin.nothing_sent_to_the_organisation_is')),
      '', h('span.sub', num(cs.length))));
    }
    var members = asList(d.members);
    if (x.Probation) {
      var pro = members.filter(function (m) { return m.probation; });
      parts.push(card(t('admin.on_probation_2'), pro.length ? h('div.stack', pro.map(function (m) {
        var ref = String(m.ref);
        return h('div.toolbar', h('span.is-grow', t('admin.name_completions_of', String(m.name || 'member'),
          Number(m.probation.done) || 0, Number(m.probation.need) || 0)),
          writeBtn('.ghost', 'org-probation', { 'data-ref': ref, 'data-value': 'yes' }, t('admin.end_probation'),
            t('admin.click_again_end_probation', String(m.name || 'their')), 'check'),
          orgAnswer('pro:' + ref));
      })) : empty(t('admin.nobody_is_on_probation'))));
      var back = members.filter(function (m) { return !m.probation; });
      if (back.length) {
        parts.push(card(t('admin.put_on_probation_again'), h('div.stack', back.map(function (m) {
          var ref = String(m.ref);
          return h('div.toolbar', h('span.is-grow', String(m.name || 'member')),
            writeBtn('.ghost', 'org-probation', { 'data-ref': ref, 'data-value': 'no' }, t('admin.probation_again'),
              t('admin.click_again_put_them_on_probation'), 'rotate-left'),
            orgAnswer('pro:' + ref));
        }))));
      }
    }
    if (x.Duty) {
      var on = members.filter(function (m) { return m.onDuty; });
      parts.push(card(t('admin.on_duty'), on.length ? h('div.stack', on.map(function (m) {
        var ref = String(m.ref);
        return h('div.toolbar', h('span.is-grow', String(m.name || 'member')),
          writeBtn('.ghost', 'org-duty-off', { 'data-ref': ref }, t('admin.send_off_duty'),
            t('admin.click_again_send') + String(m.name || 'them') + t('admin.off_duty_2'), 'power-off'),
          orgAnswer('duty:' + ref));
      })) : empty(t('admin.nobody_is_on_duty')), '', h('span.sub', num(on.length))));
    }
    if (x.Channel) {
      var msgs = asList(x.channel);
      parts.push(card(t('admin.the_channel'), frag(
        msgs.length ? h('div.stack', msgs.map(function (r) {
          var id = String(r.id);
          return h('div.org-message',
            h('p.sub', String(r.from || t('admin.a_member_2')) + (r.at ? ' · ' + ago(r.at) : '')),
            h('blockquote.org-notice', String(r.body || '')),
            h('div.btn-row',
              writeBtn('.ghost', 'org-chan-remove', { 'data-id': id }, t('admin.remove'), t('admin.click_again_remove_it'), 'trash'),
              r.member ? writeBtn('.ghost', 'org-chan-mute', { 'data-ref': String(r.member) }, t('admin.mute'),
                t('admin.click_again_mute_the_writer_for'), 'volume-xmark') : null),
            orgAnswer('msg:' + id));
        })) : empty(t('admin.no_messages_yet')),
        h('div.toolbar', field('org.mute.hours', { type: 'number', min: '0', max: '720', value: '24',
          'aria-label': t('admin.mute_for_hours') }), h('span.sub', t('admin.hours_a_mute_lasts_0_lifts'))),
        h('div.toolbar', field('org.channel', { class: 'is-grow', maxlength: '1000', placeholder: t('admin.write_as_staff'),
          'aria-label': t('admin.message') }), writeBtn('.primary', 'org-chan-post', {}, t('admin.post'), t('admin.click_again_post_it'), 'paper-plane')),
        orgAnswer('chan')), '', h('span.sub', num(msgs.length))));
    }
    return h('div.stack', parts.length ? parts : [empty(t('admin.turn_a_switch_on_in_setup'))]);
  }

  /* -- Armory, Record & discipline: the organisation extras 2
     (server/org/extras2.lua) -- */

  Text.later(function () {
    DD['org-x2-member'] = {
    prefix: t('admin.member'),
    options: function () {
      return [{ value: '', label: t('admin.pick_a_member') }].concat(asList((S.org.data || {}).members).map(function (m) {
        return { value: String(m.ref), label: String(m.name || 'member') + ' · ' + String(m.role || '') };
      }));
    },
    value: function () { return S.org.x2.member || ''; },
    pick: function (v) { disarm(); S.org.x2.member = v; }
  };
  });

  function x2Off(name, what) {
    return card(name + t('admin.is_switched_off'), h('p.about', what + t('admin.it_is_a_switch_in_setup')
      + t('admin.power_it_adds_is_its_own')), '.is-warn');
  }

  /** Organisation extras 3 (server/org/extras3.lua): every one off as
      shipped, each a card while its switch is on. */
  function orgTurfBody(d) {
    var x = d.extras3 || {};
    var parts = [];
    if (x.Reputation) {
      var r = x.reputation || {};
      parts.push(card(t('admin.reputation'), frag(
        h('dl.facts',
          h('dt', t('admin.standing')), h('dd', t('admin.n_points', num(r.points)) + (r.tier ? ' · ' + String(r.tier.label) : '')),
          h('dt', t('admin.earned')), h('dd', t('admin.earned_done_failed', num(r.earned), num(r.completed), num(r.failed))),
          h('dt', t('admin.heat_off')), h('dd', num(r.heat)),
          h('dt', t('admin.next_tier')), h('dd', r.next ? t('admin.tier_at', String(r.next.label), num(r.next.points)) : '—')),
        h('div.table-wrap', h('table.grid', h('thead', h('tr', h('th.num', t('admin.points')), h('th', t('admin.tier')),
          h('th', t('admin.most_an_accept_is_worth')))), h('tbody', asList(r.tiers).map(function (tv) {
          return h('tr', h('td.num', num(tv.points)), h('td', String(tv.label)),
            h('td', Number(tv.max) > 0 ? money(tv.max) : t('admin.no_cap')));
        })))),
        h('div.toolbar', field('org.rep.points', { class: 'is-mid', type: 'number', placeholder: '+/- points',
          'aria-label': t('admin.points_to_add_or_take_off') }), field('org.rep.reason', { class: 'is-grow', maxlength: '200',
          placeholder: t('admin.reason'), 'aria-label': t('admin.reason') }),
          writeBtn('.primary', 'org-rep-adjust', {}, t('admin.adjust'), t('admin.click_again_adjust_the_reputation'), 'pen')),
        orgAnswer('rep'))));
    }
    if (x.DeadDrops) {
      var dd = x.deadDrops || {};
      var drops = asList(dd.rows);
      parts.push(card(t('admin.dead_drops'), frag(
        h('p.about', t('admin.payouts_are') + (dd.method === 'deaddrop' ? t('admin.left_at_the_dead_drop') : t('admin.handed_over_the_usual_way'))
          + t('admin.unclaimed_x', dd.unclaimed === 'refund' ? t('admin.back_to_the_placer') : t('admin.handed_over_anyway'))
          + (dd.spot ? '' : t('admin.no_dead_drop_is_set_yet'))),
        h('div.btn-row', writeBtn('', 'org-pay-method', { 'data-value': dd.method === 'deaddrop' ? 'bank' : 'deaddrop' },
          dd.method === 'deaddrop' ? t('admin.pay_the_usual_way') : t('admin.pay_at_the_dead_drop'), t('admin.click_again_change_it'), 'box')),
        orgAnswer('paymethod'),
        drops.length ? h('div.table-wrap', h('table.grid', h('thead', h('tr', h('th', t('admin.member')), h('th', t('admin.left')),
          h('th', t('admin.runs_out_2')), h('th', ''))), h('tbody', drops.map(function (row) {
          var key = String(row.handle);
          return h('tr', h('td', String(row.name)), h('td', row.at ? ago(row.at) : '—'),
            h('td', row.expires ? ago(row.expires) : '—'),
            h('td', h('div.btn-row', writeBtn('.ghost', 'org-drop-settle', { 'data-id': key, 'data-value': 'release' },
              t('admin.hand_over'), t('admin.click_again_hand_it_over_now'), 'check'),
              writeBtn('.danger', 'org-drop-settle', { 'data-id': key, 'data-value': 'refund' }, t('admin.refund'),
                t('admin.click_again_back_to_the_placer'), 'rotate-left')), orgAnswer('drop:' + key)));
        })))) : empty(t('admin.no_payout_waits_at_a_drop')))));
    }
    if (x.Territory) {
      var tv = x.territory || {};
      parts.push(card(t('admin.territory'), frag(
        h('p.about', num(tv.zones) + t('admin.zone_draw_them_in_locations_territory')
          + t('admin.placed_on_somebody_in_one_while')
          + t('admin.nobody_is_told_why_or_where')),
        tv.needsOrgContracts ? h('p.about.is-warn', t('admin.it_needs_contracts_to_the_organisation')) : null)));
    }
    if (x.Garage) {
      var g = x.garage || {};
      parts.push(card(t('admin.garage'), frag(
        h('p.about', (g.ready ? '' : t('admin.no_vehicle_adapter_answers_config_integrations'))
          + (g.hasSpot ? '' : t('admin.no_garage_spot_is_set_yet')) + t('admin.n_of_out', num(asList(g.out).length), num(g.max))),
        h('div.chips', asList(g.all).map(function (a) {
          var on = S.org.garage && S.org.garage[a.model] !== undefined ? S.org.garage[a.model] : a.offered === true;
          return h('button.chip.is-link' + (on ? '' : '.is-warn'), { type: 'button', 'data-act': 'org-garage-toggle',
            'data-value': String(a.model), 'aria-pressed': on ? 'true' : 'false' }, String(a.model));
        })),
        h('div.btn-row', writeBtn('', 'org-garage-offer', {}, t('admin.save_what_is_offered'), t('admin.click_again_save_it'), 'check')),
        orgAnswer('garage'),
        asList(g.out).length ? h('div.table-wrap', h('table.grid', h('thead', h('tr', h('th', t('admin.member')),
          h('th', t('admin.vehicle')), h('th', t('admin.out_since')), h('th', ''))), h('tbody', asList(g.out).map(function (o) {
          var ref = String(o.ref || '');
          return h('tr', h('td', String(o.name)), h('td.mono', String(o.model)), h('td', o.at ? ago(o.at) : '—'),
            h('td', writeBtn('.danger', 'org-garage-remove', { 'data-ref': ref }, t('admin.take_away'),
              t('admin.click_again_take_it_away'), 'trash'), orgAnswer('garage:' + ref)));
        })))) : null)));
    }
    if (x.InternalContracts) {
      var reqs = asList(x.internal);
      parts.push(card(t('admin.internal_contracts'), reqs.length ? h('div.stack', reqs.map(function (q) {
        var id = String(q.id);
        return h('article.card', h('header.card-head', h('h3', String(q.name)),
          h('span.sub', String(q.state) + t('admin.asked_by') + String(q.by) + (q.at ? ' · ' + ago(q.at) : ''))),
          h('blockquote.org-notice', String(q.reason || '')),
          h('p.sub', t('admin.amount_cash', money(q.amount)) + (q.anonymous ? t('admin.anonymous_suffix') : '')),
          q.state === 'pending' ? h('div.btn-row',
            writeBtn('.primary', 'org-internal', { 'data-id': id, 'data-value': 'yes' }, t('admin.approve'),
              t('admin.click_again_place_it_in_the'), 'check'),
            writeBtn('.danger', 'org-internal', { 'data-id': id, 'data-value': 'no' }, t('admin.decline'),
              t('admin.click_again_decline_it'), 'xmark')) : null,
          orgAnswer('ic:' + id));
      })) : empty(t('admin.no_request'))));
    }
    if (x.Handler) {
      parts.push(card(t('admin.handler'), h('p.about', t('admin.the_organisations_npc_spots_locations_npc')
        + t('admin.talks_to_them_and_with_the'))));
    }
    if (x.ActivityLog) {
      var log = asList(x.activity);
      parts.push(card(t('admin.activity_log'), log.length ? h('div.table-wrap', h('table.grid', h('thead', h('tr',
        h('th', t('admin.when')), h('th', t('admin.what')), h('th', t('admin.by_2')), h('th', t('admin.member')), h('th.num', t('admin.amount')))),
        h('tbody', log.map(function (e) {
          return h('tr', h('td', e.at ? ago(e.at) : '—'), h('td', String(e.what || '')), h('td', String(e.by || '')),
            h('td', String(e.member || '')), h('td.num', e.amount != null ? money(e.amount) : ''));
        })))) : empty(t('admin.nothing_logged_yet')), '', h('span.sub', t('admin.what_a_boss_holding_view_org'))));
    }
    if (!parts.length) {
      return x2Off(t('admin.reputation_dead_drops_and_the_garage'), t('admin.reputation_dead_drops_territory_the_garage')
        + t('admin.contracts_the_handler_and_the_activity'));
    }
    return h('div.stack', parts);
  }

  function orgArmoryBody(d) {
    var x = d.extras2 || {};
    if (!x.Armory) {
      return x2Off(t('admin.the_armory'), t('admin.an_ox_inventory_stash_of_the'));
    }
    var a = x.armory || {};
    if (a.error) { return card(t('admin.the_armory_cannot_be_read'), h('p.about', String(a.error)), '.is-warn'); }
    var items = asList(a.items);
    var log = asList(a.log);
    var allowed = asList(a.allowed);
    return frag(
      card(t('admin.in_the_armory'), items.length ? h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.item')), h('th.num', t('admin.count')), h('th', t('admin.take_out_removed_for_good')))),
        h('tbody', items.map(function (it) {
          var slot = String(it.slot);
          return h('tr', h('td', String(it.label || it.name) + ' ', h('span.mono.sub', String(it.name))),
            h('td.num', num(it.count)),
            h('td', h('div.toolbar', field('org.arm.out.' + slot, { type: 'number', min: '1', max: '1000', value: '1',
              class: 'is-short', 'aria-label': t('admin.how_many') }),
              writeBtn('.danger', 'org-arm-remove', { 'data-id': slot }, t('admin.remove'), t('admin.click_again_remove_them_for_good'),
                'trash')), orgAnswer('arm:' + slot)));
        })))) : empty(t('admin.empty_members_put_in_what_the')),
        '', h('span.sub', num(items.length))),
      card(t('admin.stock_it'), frag(
        h('p.about', allowed.length ? t('admin.allowed_x', allowed.join(', ')) + t('admin.change_the_list_in_setup_items')
          + t('admin.in_the_armory_2') : t('admin.nothing_is_allowed_yet_add_item')),
        h('div.toolbar', field('org.arm.item', { class: 'is-mid', maxlength: '64', placeholder: t('admin.item_name'),
          'aria-label': t('admin.item') }), field('org.arm.count', { type: 'number', min: '1', max: '1000', value: '1',
          class: 'is-short', 'aria-label': t('admin.how_many') }),
          writeBtn('.primary', 'org-arm-stock', {}, t('admin.stock'), t('admin.click_again_add_them_to_the'), 'plus')),
        orgAnswer('arm:stock'))),
      card(t('admin.limits_a_day_by_role'), frag(
        h('p.about', t('admin.items_each_member_of_a_role')
          + t('admin.roles_below_them_up_to') + num(a.withdrawMax) + '.'),
        h('div.stack', asList(d.roles).map(function (r) {
          var g = String(r.grade);
          return h('div.toolbar', h('span.is-grow', roleName(d, r.grade) + t('admin.now_2') + num((a.limits || {})[g] || 0)),
            field('org.arm.lim.' + g, { type: 'number', min: '0', max: '1000', class: 'is-short',
              value: String((a.limits || {})[g] || 0), 'aria-label': t('admin.limit_for') + roleName(d, r.grade) }),
            writeBtn('.ghost', 'org-arm-limit', { 'data-id': g }, t('admin.set'), t('admin.click_again_set_the_limit'), 'check'),
            orgAnswer('arm:lim:' + g));
        })))),
      card(t('admin.log'), log.length ? h('div.stack', log.slice(0, 50).map(function (e) {
        return h('p.sub', (e.dir === 'in' ? 'In: ' : 'Out: ') + String(e.item) + ' × ' + num(e.count) + ' · '
          + String(e.who || t('admin.a_member')) + (e.at ? ' · ' + ago(e.at) : ''));
      })) : empty(t('admin.nothing_moved_yet_every_move_is')), '', h('span.sub', num(log.length))));
  }

  function orgRecordBody(d) {
    var x = d.extras2 || {};
    var parts = [];
    if (x.Stats) {
      var rows = asList(x.leaderboard);
      parts.push(card(t('admin.leaderboard'), rows.length ? frag(h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th.num', '#'), h('th', t('admin.member')), h('th.num', t('admin.done')), h('th.num', t('admin.failed')),
          h('th.num', t('admin.earned')), h('th.num', t('admin.reliable')), h('th', t('admin.average')), h('th', ''))),
        h('tbody', rows.map(function (r) {
          var ref = String(r.ref || '');
          return h('tr', h('td.num', num(r.rank)), h('td', String(r.name || 'member')), h('td.num', num(r.completed)),
            h('td.num', num(r.failed)), h('td.num', money(r.earned)),
            h('td.num', r.rate != null ? r.rate + '%' : '—'),
            h('td', r.avgMinutes != null ? num(r.avgMinutes) + t('admin.min_2') + String(r.band || '') + ')' : '—'),
            h('td', ref ? writeBtn('.ghost', 'org-stats-reset', { 'data-ref': ref }, t('admin.reset'),
              t('admin.click_again_reset_their_counts'), 'rotate-left') : null, orgAnswer('stats:' + ref)));
        })))),
        h('div.btn-row', writeBtn('.danger', 'org-stats-reset', { 'data-ref': '' }, t('admin.reset_everybody'),
          t('admin.click_again_reset_every_members_counts'), 'rotate-left')), orgAnswer('stats:'))
        : empty(t('admin.nobody_is_counted_yet_completions_and')),
        '', h('span.sub', t('admin.players_see_bands_never_these_minutes'))));
    }
    if (x.Discipline) {
      var rules = x.disciplineRules || {};
      var recs = asList(x.discipline);
      parts.push(card(t('admin.give_a_strike_or_a_warning'), frag(
        h('p.about', t('admin.a_strike_counts_for_days', num(rules.decayDays)) + (Number(rules.suspendAt) > 0
          ? t('admin.standing_bar_the_member_for_h', num(rules.suspendAt), num(rules.suspendHours))
          : '') + (Number(rules.demoteAt) > 0 ? num(rules.demoteAt) + t('admin.move_them_one_role_down') : '')
          + t('admin.the_member_is_told')),
        h('div.toolbar', dropdown('org-x2-member'),
          segmented('org-x2-kind', [{ value: 'strike', label: t('admin.strike') }, { value: 'warning', label: t('admin.warning') }],
            S.org.x2.kind || 'strike')),
        h('div.toolbar', field('org.disc.reason', { class: 'is-grow', maxlength: '200', placeholder: t('admin.reason'),
          'aria-label': t('admin.reason') }), writeBtn('.primary', 'org-disc-give', {}, t('admin.give'), t('admin.click_again_give_it'), 'gavel')),
        orgAnswer('disc'))));
      parts.push(card(t('admin.records'), recs.length ? h('div.stack', recs.map(function (rec) {
        var ref = String(rec.ref);
        return h('article.card',
          h('header.card-head', h('h3', String(rec.name || 'member')), h('span.sub', t('admin.n_standing', num(rec.strikes)))),
          h('div.stack', asList(rec.rows).map(function (e) {
            var id = String(e.id);
            return h('div.org-discipline',
              h('p.sub', (e.kind === 'strike' ? t('admin.strike') : t('admin.warning')) + ' · ' + (e.at ? ago(e.at) : '') + ' · '
                + String(e.by || '') + (e.overturned ? t('admin.overturned') + String(e.overturnReason || '')
                  : e.kind === 'strike' && !e.active ? t('admin.no_longer_counts') : '')
                + (e.consequence ? t('admin.then') + String(e.consequence) : '')),
              h('blockquote.org-notice', String(e.reason || '')),
              e.overturned ? null : h('div.toolbar', field('org.over.' + id, { class: 'is-grow', maxlength: '200',
                placeholder: t('admin.why_it_is_overturned'), 'aria-label': t('admin.why_it_is_overturned') }),
                writeBtn('.ghost', 'org-disc-over', { 'data-ref': ref, 'data-id': id }, t('admin.overturn'),
                  t('admin.click_again_overturn_it_the_member'), 'rotate-left')),
              orgAnswer('over:' + id));
          })));
      })) : empty(t('admin.no_strikes_or_warnings_on_anybodys')), '', h('span.sub', num(recs.length))));
    }
    if (!parts.length) {
      return x2Off(t('admin.the_record_and_discipline'), t('admin.each_members_record_and_the_leaderboard_2')
        + t('admin.are_two_switches'));
    }
    return h('div.stack', parts);
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

  Text.later(function () {
    DD['org-audit'] = {
    prefix: t('admin.action'),
    options: function () {
      return [{ value: '', label: t('admin.every_action') }].concat(ORG_ACTIONS.map(function (a) {
        return { value: a, label: a.replace(/^org_/, '').replace(/_/g, ' ') };
      }));
    },
    value: function () { return S.org.auditAction; },
    pick: function (v) { S.org.auditAction = v; S.org.audit = null; drawOrg(); loadOrgAudit(v); }
  };
  });

  function auditTable(rows) {
    return h('div.table-wrap', h('table.grid.is-log',
      h('thead', h('tr', h('th', t('admin.when')), h('th', t('admin.action')), h('th', t('admin.by_2')), h('th', t('admin.detail')))),
      h('tbody', rows.map(function (r) {
        return h('tr', h('td.nowrap', when(r.ts)), h('td.mono', String(r.action || '').replace(/^org_/, '')),
          h('td', String(r.by || '—')), h('td.detail', detailText(r.detail)));
      }))));
  }

  function orgAuditBody() {
    var rows = S.org.audit;
    return frag(
      h('div.toolbar', dropdown('org-audit'), btn('.ghost', 'org-audit-refresh', {}, t('admin.refresh'), 'rotate')),
      card(t('admin.every_boss_and_staff_action_on'), rows ? (rows.length ? auditTable(rows)
        : empty(t('admin.nothing_on_the_record_yet'))) : (S.org.auditError ? empty(S.org.auditError) : loading(t('admin.reading_the_log')))));
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
  var BP_WORD;
  Text.later(function () {
    BP_WORD = { allow: t('admin.allow'), off: t('admin.off'), deny: t('admin.deny'), inherit: t('admin.inherit_role') };
  });
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
        text: (state === 'allow' ? '+ ' : state === 'inherit' ? '↺ ' : '− ') + t('admin.power_for', powerName(d, code), col.label)
          + (state === 'deny' ? t('admin.deny_paren') : state === 'inherit' ? t('admin.inherit_role_2') : '') });
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

  Text.later(function () {
    DD['bp-area'] = {
    prefix: t('admin.area'),
    options: function () {
      return [{ value: '', label: t('admin.every_area') }].concat(Object.keys(AREA_NAMES).map(function (a) {
        return { value: a, label: AREA_NAMES[a] };
      }));
    },
    value: function () { return S.org.bp.area; },
    pick: function (v) { S.org.bp.area = v; drawOrg(); }
  };
  });
  Text.later(function () {
    DD['bp-add'] = {
    prefix: t('admin.add_an_individual_boss'),
    options: function () {
      var d = S.org.data || {};
      var shown = {};
      bpColumns(d).forEach(function (c) { shown[c.key] = true; });
      return [{ value: '', label: t('admin.pick_a_member') }].concat(asList(d.members).filter(function (m) {
        return !shown['member:' + m.ref];
      }).map(function (m) { return { value: String(m.ref), label: String(m.name || '—') + ' · ' + String(m.role || '') }; }));
    },
    value: function () { return ''; },
    pick: function (v) { if (v) { S.org.bp.cols.push(v); drawOrg(); } }
  };
  });
  Text.later(function () {
    DD['bp-col'] = {
    prefix: t('admin.show'),
    options: function () {
      return [{ value: '', label: t('admin.every_column') }].concat(bpColumns(S.org.data || {}).map(function (c) {
        return { value: c.key, label: c.label };
      }));
    },
    value: function () { return S.org.bp.col; },
    pick: function (v) { S.org.bp.col = v; drawOrg(); }
  };
  });
  Text.later(function () {
    DD['bp-copy'] = {
    prefix: t('admin.copy_from'),
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
  });

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
      h('p.hint', t('admin.the_ceiling_every_power_is_off')
        + t('admin.boss_a_bosss_own_column_overrides')
        + t('admin.nothing_is_saved_until_save_staff')),
      h('div.toolbar',
        dropdown('bp-area'),
        h('label.search', icon('magnifying-glass'), field('bp.q', { placeholder: t('admin.find_a_power'), 'data-live': 'bp-filter',
          'aria-label': t('admin.find_a_power') })),
        segmented('bp-granted', [{ value: 'all', label: t('admin.every_power') }, { value: 'granted', label: t('admin.only_granted') }],
          S.org.bp.granted ? 'granted' : 'all'),
        dropdown('bp-col'),
        dropdown('bp-add')),
      allCols.length ? null : h('p.note.is-warn', t('admin.no_role_is_marked_boss_and')
        + t('admin.in_roles_pay_or_add_an')),
      h('div.table-wrap.bp-wrap', h('table.grid.bp-grid',
        h('thead',
          h('tr', h('th', t('admin.power')), cols.map(function (c) {
            return h('th.bp-col', h('span.bp-col-name', c.label), h('span.sub', c.subject === 'role' ? 'role' : t('admin.one_boss')));
          })),
          h('tr.bp-tools', h('th', ''), cols.map(function (c) {
            return h('th', h('div.bp-col-tools', dropdown('bp-copy:' + c.key, '.is-small'),
              writeBtn('.is-small.danger', 'bp-revoke', { 'data-id': c.key }, t('admin.revoke_all'),
                t('admin.click_again_revoke_every_power_from') + c.label, 'ban')));
          }))),
        h('tbody', areas.map(function (area) {
          return frag(h('tr.tl-group', h('td', { colspan: String(cols.length + 1) }, AREA_NAMES[area] || area)),
            powers.filter(function (p) { return p.area === area; }).map(function (p) {
              return h('tr',
                h('td.bp-power', h('b', String(p.label)), office[p.code] ? h('span.chip.is-warn', { title: t('admin.needs_the_boss_office') },
                  icon('lock'), ' office') : null,
                  asList(p.limits).length ? h('button.link.bp-limits-link', { type: 'button', 'data-act': 'section',
                    'data-section': 'bplimits' }, t('admin.limits_2')) : null,
                  h('span.detail', ' ' + String(p.about || ''))),
                cols.map(function (c) {
                  var st = bpState(d, c, p.code);
                  var dirty = !!S.org.bp.pending[c.key + '|' + p.code];
                  var warn = st === 'allow' && atDefault(d, p);
                  return h('td.bp-cell',
                    h('button.bp-btn.is-' + st + (dirty ? '.is-pending' : ''), { type: 'button', 'data-act': 'bp-cell',
                      'data-id': c.key, 'data-power': p.code, disabled: !writesOpen() || null,
                      title: (dirty ? t('admin.changed_not_saved') : '') + BP_WORD[st] + (warn ? t('admin.its_limit_is_still_the')
                        + t('admin.default_set_bounds_in_limits') : ''), 'aria-label': t('admin.power_for_state', p.label, c.label, BP_WORD[st]) },
                      h('span.lbl', BP_WORD[st]), warn ? h('span.bp-warn', { 'aria-hidden': 'true' }, '⚠') : null));
                }));
            }));
        })))),
      card(t('admin.changes_to_save') + num(pending.length) + ')', pending.length ? frag(
        h('ul.plain.bp-diff', pending.map(function (x) { return h('li', x.text); })),
        h('div.btn-row',
          writeBtn('.primary', 'bp-save', {}, tn('admin.save_changes', pending.length, num(pending.length)),
            tn('admin.click_again_save_changes', pending.length, num(pending.length)), 'check'),
          btn('.ghost', 'bp-discard', {}, t('admin.discard'), 'xmark'))) : empty(t('admin.nothing_changed_yet_click_a_cell')),
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
      h('p.hint', t('admin.the_bounds_every_boss_power_works')
        + t('admin.config_organisation_limits_reset_puts_one')),
      card(t('admin.limits'), h('div.table-wrap', h('table.grid',
        h('thead', h('tr', h('th', t('admin.limit')), h('th.num', t('admin.now')), h('th.num', 'config.lua'), h('th', t('admin.used_by')), h('th', ''))),
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
              writeBtn('.is-small', 'bp-limit', { 'data-id': k }, t('admin.save'), t('admin.click_again_to_save'), 'check'),
              e && Number(e.value) !== Number(lim[k]) ? writeBtn('.is-small.ghost', 'bp-limit-reset', { 'data-id': k },
                t('admin.reset'), t('admin.click_again_back_to') + show(e.value), 'arrow-rotate-left') : null)));
        })))), '', h('span.sub', num(keys.length))),
      orgAnswer('limits'));
  }

  function bpOfficeBody(d) {
    var office = d.officeStaff || {};
    var bossOwn = d.officeBoss || {};
    return frag(
      card(t('admin.needs_the_boss_office'), frag(
        h('p.about', t('admin.powers_a_boss_may_use_only')
          + t('admin.boss_may_add_more_for_themselves')),
        h('div.table-wrap', h('table.grid',
          h('thead', h('tr', h('th', t('admin.power')), h('th', t('admin.staff_require_it')), h('th', t('admin.a_boss_added_it')), h('th', ''))),
          h('tbody', asList(d.powers).map(function (p) {
            var on = !!office[p.code];
            return h('tr', h('td', h('b', String(p.label)), h('span.sub', ' ' + (AREA_NAMES[p.area] || p.area))),
              h('td', on ? h('span.chip.is-warn', icon('lock'), ' office') : 'no'),
              h('td', bossOwn[p.code] ? 'yes' : '—'),
              h('td', writeBtn('.is-small', 'bp-office', { 'data-power': p.code, 'data-value': on ? 'off' : 'on' },
                on ? t('admin.stop_requiring_it') : t('admin.require_the_office'),
                on ? t('admin.click_again_x_anywhere', p.label) : t('admin.click_again') + p.label + t('admin.only_in_the_office'), 'building')));
          })))),
        orgAnswer('office'))),
      card(t('admin.delegation_rules'), h('ul.plain.bp-rules',
        h('li', t('admin.a_boss_passes_on_only_powers')
          + t('admin.wider_limits_than_their_own')),
        h('li', t('admin.rank_a_boss_never_creates_edits')
          + t('admin.it_unless_given_promote_to_own')),
        h('li', t('admin.no_self_escalation_a_boss_never')
          + t('admin.higher_rank')),
        h('li', t('admin.revoking_a_power_here_makes_every')
          + t('admin.restores_them')),
        h('li', t('admin.staff_may_edit_any_role_member')),
        h('li', t('admin.the_organisation_is_never_left_without')),
        h('li', t('admin.every_rule_is_checked_on_the')))));
  }

  function bpHistoryBody() {
    var rows = S.org.history;
    var d = S.org.data || {};
    return frag(
      h('div.toolbar', btn('.ghost', 'bp-history-refresh', {}, t('admin.refresh'), 'rotate')),
      card(t('admin.grant_history'), rows ? (rows.length ? h('div.table-wrap', h('table.grid.is-log',
        h('thead', h('tr', h('th', t('admin.when')), h('th', t('admin.by_2')), h('th', t('admin.column')), h('th', t('admin.power')), h('th', t('admin.before')),
          h('th', t('admin.after')), h('th', ''))),
        h('tbody', rows.map(function (r, i) {
          var det = r.detail || {};
          var isRole = det.subject === 'role';
          var undoTo = isRole ? (det.before === 'allow' ? 'allow' : 'off') : null;
          return h('tr', h('td.nowrap', when(r.ts)), h('td', String(r.by || '—')),
            h('td', isRole ? t('admin.role_x', roleName(d, det.id)) : t('admin.one_boss_2')),
            h('td', powerName(d, det.power)), h('td', String(det.before || 'off')), h('td', String(det.after || 'off')),
            h('td', isRole && det.before !== det.after ? writeBtn('.is-small.ghost', 'bp-undo', { 'data-index': String(i),
              'data-id': String(det.id), 'data-power': String(det.power), 'data-value': undoTo }, t('admin.undo'),
              t('admin.click_again') + powerName(d, det.power) + t('admin.back_to') + undoTo, 'arrow-rotate-left')
              : (isRole ? null : h('span.sub', t('admin.change_it_in_the_matrix')))));
        })))) : empty(t('admin.nothing_granted_or_revoked_yet')))
        : (S.org.historyError ? empty(S.org.historyError) : loading(t('admin.reading_the_history')))),
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

  var PLACE_GROUPS;
  Text.later(function () {
    PLACE_GROUPS = {
    org: { title: t('admin.organisation_places') },
    npc: { title: t('admin.broker_and_informant_places'),
      hint: t('admin.where_the_broker_rumours_and_the')
        + t('admin.the_settings_below_which_stays_the') },
    disposal: { title: t('admin.body_disposal'),
      hint: t('admin.where_the_disposal_vehicle_is_made')
        + t('admin.vehiclespawn_and_dropoff_apply_while_one') }
  };
  });

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
      h('p.hint', t('admin.every_place_this_resource_uses_by')
        + t('admin.server_reads_where_you_stand_adjust')),
      pos ? h('p.note', t('admin.your_position_xyz', fmt(pos.x), fmt(pos.y), fmt(pos.z), fmt(pos.heading, 0), ago(S.places.posAt))) : null,
      placeAnswer('pos'),
      !d ? (S.places.error ? (S.places.errCode === 'unknown_op' ? empty(t('admin.this_server_has_no_panel_set'))
        : empty(S.places.error)) : loading(t('admin.reading_the_places')))
        : groups.map(placeGroup),
      h('h3.st-group-title', t('admin.places_in_the_settings')),
      S.settings.data ? placeSettings() : loading(t('admin.reading_the_settings')));
  }

  /** One group of kinds; all of it off for one reason: said once, with its switch. */
  function placeGroup(g) {
    var about = PLACE_GROUPS[g.id] || { title: String(g.id || t('admin.places')) };
    var first = g.kinds[0] || {};
    var allOff = g.kinds.every(function (k) { return k.off && k.off === first.off; });
    return frag(h('h3.st-group-title', about.title),
      about.hint ? h('p.hint', about.hint) : null,
      allOff ? placeOff(first, g.kinds) : g.kinds.map(function (k) { return placeCard(k); }));
  }
  function switchRow(key) {
    var sw = key ? settingEntry(key) : null;
    if (!sw) return key ? (S.settings.data ? null : loading(t('admin.reading_the_switch'))) : null;
    return h('div.st-row', { id: 'st-row-' + sw.key, 'data-key': sw.key }, settingInner(sw));
  }
  function placeOff(k, kinds) {
    return card(t('admin.set_here_once_it_is_on'), frag(
      h('p.about', String(k.off)),
      kinds.map(function (x) { return asList(x.rows).length || asList(x.defaults).length ? placeDefaults(x) : null; }),
      switchRow(k.switch)), '.is-warn.place-off');
  }
  function placeDefaults(k) {
    var defaults = asList(k.defaults);
    var rows = asList(k.rows);
    return frag(
      k.using ? h('p.sub', k.label + ': ' + (k.using === 'panel' ? t('admin.standing_at_the_places_set_here')
        : t('admin.using_its_config') + (k.key ? '(' + k.key + ')' : 'default') + '.')) : null,
      k.defaults ? h('p.sub', t('admin.defaults_config') + (defaults.length ? defaults.map(function (p) {
        return fmt(p.x) + ', ' + fmt(p.y) + ', ' + fmt(p.z);
      }).join(' · ') : 'none')) : null,
      k.off && rows.length ? h('p.sub', num(rows.length) + t('admin.set_here_kept_while_it_is')) : null);
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
        h('thead', h('tr', h('th', t('admin.name')), h('th', 'x, y, z, heading'), f.radius ? h('th.num', t('admin.radius')) : null,
          f.blip ? h('th', t('admin.blip')) : null, f.enabled ? h('th', t('admin.on')) : null, h('th', ''))),
        h('tbody', rows.map(function (r) {
          return h('tr' + (r.id === edit && !kind.single ? '.is-open' : ''), h('td.name', String(r.label || '—')),
            h('td.mono', fmt(r.x) + ', ' + fmt(r.y) + ', ' + fmt(r.z) + ', ' + fmt(r.heading, 0)),
            f.radius ? h('td.num', fmt(r.radius) + ' m') : null, f.blip ? h('td', r.blip ? 'yes' : 'no') : null,
            f.enabled ? h('td', r.enabled === false ? 'off' : 'on') : null,
            h('td', h('div.inline-form',
              !kind.single && open ? btn('.is-small.ghost', 'loc-edit', { 'data-id': String(r.id), 'data-value': k },
                t('admin.edit'), 'pen') : null,
              open ? writeBtn('.is-small.danger', 'loc-remove', { 'data-id': String(r.id), 'data-value': k },
                kind.single ? t('admin.clear') : t('admin.remove'), t('admin.click_again_remove') + String(r.label || 'it'), 'trash-can') : null)));
        })))) : empty(kind.single ? t('admin.not_set_2') : t('admin.none_set_here')),
      kind.using || kind.defaults ? placeDefaults(kind) : null,
      open ? h('div.loc-form',
        h('p.sub', editing ? t('admin.editing_x', String(editing.label || kind.one || k)) : t('admin.add_x', String(kind.one || t('admin.a_place')))),
        h('div.toolbar',
          f.label ? input('label', { class: 'is-mid', maxlength: String(kind.labelMax || 64), placeholder: t('admin.name'),
            value: editing ? String(editing.label || '') : '', 'aria-label': t('admin.name') }) : null,
          ['x', 'y', 'z'].map(function (a) {
            return input(a, { class: 'is-short', inputmode: 'decimal', placeholder: a, value: editing ? fmt(editing[a]) : '',
              'aria-label': a });
          }),
          input('h', { class: 'is-short', inputmode: 'decimal', placeholder: 'heading',
            value: editing ? fmt(editing.heading, 0) : '', 'aria-label': t('admin.heading') }),
          f.radius ? input('r', { class: 'is-short', inputmode: 'decimal', placeholder: t('admin.radius_m'),
            value: editing && editing.radius != null ? fmt(editing.radius) : '', 'aria-label': t('admin.radius_m_2') }) : null),
        h('div.toolbar',
          f.blip ? segmented('loc-blip', [{ value: 'no', label: t('admin.no_blip') }, { value: 'yes', label: t('admin.map_blip') }],
            blip ? 'yes' : 'no', { 'data-id': k }) : null,
          f.enabled ? segmented('loc-enabled', [{ value: 'yes', label: t('admin.on') }, { value: 'no', label: t('admin.off') }],
            enabled ? 'yes' : 'no', { 'data-id': k }) : null,
          btn('.is-small', 'loc-mypos', { 'data-value': k }, t('admin.use_my_position'), 'location-crosshairs'),
          writeBtn('.primary.is-small', 'loc-save', { 'data-value': k, 'data-id': edit }, t('admin.save'), t('admin.click_again_to_save'),
            'check'),
          writeBtn('.is-small', 'loc-here', { 'data-value': k, 'data-id': edit }, t('admin.save_where_i_stand'),
            t('admin.click_again_save_where_you_stand'), 'street-view'),
          editing && !kind.single ? btn('.is-small.ghost', 'loc-new', { 'data-value': k }, t('admin.new_instead'), 'plus') : null,
          kind.reset && rows.length ? writeBtn('.is-small.ghost', 'loc-reset', { 'data-value': k }, t('admin.reset_to_config'),
            t('admin.click_again_remove_every_place_set'), 'rotate-left') : null),
        placeAnswer('loc:' + k)) : placeAnswer('loc:' + k)), '.loc-kind');
  }

  /** The settings that are places, with Use my position filling a line. */
  function placeSettings() {
    var entries = allSettings().filter(function (e) { return !!placeOf(e); });
    if (!entries.length) return empty(t('admin.no_place_settings_on_this_server'));
    var jail = entries.filter(function (e) { return placeOf(e) === 'jail'; });
    return frag(entries.filter(function (e) { return placeOf(e) !== 'jail'; }).map(function (e) {
      return h('div.loc-setting',
        settingRow(e),
        placeOf(e) !== 'name' && settingOpen(e) ? h('div.btn-row', btn('.is-small', 'loc-fill', { 'data-key': e.key },
          t('admin.use_my_position_for_a_new'), 'location-crosshairs')) : null);
    }), jail.length ? h('div.loc-setting', h('h3.st-group-title', t('admin.prison_zone')),
      jail.map(function (e) { return settingRow(e); }),
      settingOpen(jail[0]) ? h('div.btn-row', btn('.is-small', 'loc-fill', { 'data-key': jail[0].key },
        t('admin.use_my_position_for_the_centre'), 'location-crosshairs')) : null) : null);
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
        : kind === 'zone' ? fmt(pos.x) + ', ' + fmt(pos.y) + t('admin.50_new_zone')
          : kind === 'district' ? fmt(pos.x) + ', ' + fmt(pos.y) + t('admin.new_district')
            : t('admin.new_area') + fmt(pos.x) + ',' + fmt(pos.y);
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
    function val(name, from) { var tv = S.forms[pre + name]; return trim(tv === undefined ? (from == null ? '' : from) : tv); }
    var spec = { kind: k };
    if (id) spec.id = id;
    if (f.label) {
      var label = val('label', editing && editing.label);
      if (!label && !kind.labelOptional) return { error: t('admin.give_the_place_a_name') };
      if (label) spec.label = label.slice(0, kind.labelMax || 64);
    }
    if (f.radius) {
      var r = val('r', editing && editing.radius != null ? fmt(editing.radius) : '');
      if (r !== '') {
        spec.radius = Number(r);
        var lim = kind.radius || { min: 0.5, max: 50 };
        if (!isFinite(spec.radius) || spec.radius < lim.min || spec.radius > lim.max) {
          return { error: t('admin.the_radius_is_to', lim.min, lim.max) };
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
    if (nums.slice(0, 3).some(function (tv) { return tv === '' || !isFinite(Number(tv)); })) {
      return { error: t('admin.give_x_y_and_z_as') };
    }
    spec.x = Number(nums[0]); spec.y = Number(nums[1]); spec.z = Number(nums[2]);
    spec.heading = nums[3] === '' ? 0 : Number(nums[3]);
    if (!isFinite(spec.heading) || spec.heading < 0 || spec.heading > 360) {
      return { error: t('admin.the_heading_is_a_number_from') };
    }
    return spec;
  }
  function locSave(node, here) {
    var k = node.getAttribute('data-value');
    var kind = placeKind(k) || {};
    var spec = spotSpec(k, here);
    if (spec.error) { placeRefuse('loc:' + k, spec.error); return; }
    var pre = 'loc.' + k + '.';
    var what = spec.label || kind.one || t('admin.the_place');
    var label = here ? t('admin.click_again_save') + what + t('admin.where_you_stand')
      : t('admin.click_again_save_at', what, fmt(spec.x), fmt(spec.y));
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

  ACTIONS['org-scope'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!id) return;
    var d = S.org.data || {};
    var first = asList(d.orgs).filter(function (o) { return o.first; })[0];
    S.orgScope = first && String(first.id) === id ? null : id;
    var keep = S.orgScope;
    orgReset();
    S.orgScope = keep;
    loadOrg();
    if (typeof loadPlaces === 'function' && S.section === 'locations') loadPlaces();
  };
  ACTIONS['org-create'] = function (node) {
    var job = trim(S.forms['org.new.job']).toLowerCase(), label = trim(S.forms['org.new.label']);
    if (!/^[a-z][a-z0-9_]{1,31}$/.test(job)) {
      orgRefuse('orgcreate', t('admin.a_job_name_2_32_lower'));
      return;
    }
    if (!label) { orgRefuse('orgcreate', t('admin.give_the_label_players_see')); return; }
    if (!armed(node, t('admin.click_again_add') + label + ' (' + job + ')', ['org.new.job', 'org.new.label'])) return;
    orgWrite('orgCreate', { job: job, label: label.slice(0, 64) }, 'orgcreate', node, function () {
      delete S.forms['org.new.job'];
      delete S.forms['org.new.label'];
    });
  };
  ACTIONS['org-remove'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!id || !armed(node)) return;
    orgWrite('orgRemove', { id: id }, 'orgremove', node);
  };
  ACTIONS['org-setup'] = function (node) {
    if (!armed(node)) return;
    orgWrite('orgSetup', {}, 'setup', node);
  };
  ACTIONS['org-rename'] = function (node) {
    var label = trim(S.forms['org.label']);
    if (!label) { orgRefuse('rename', t('admin.give_the_label')); return; }
    if (!armed(node, t('admin.click_again_rename_to') + label, ['org.label'])) return;
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
        if (text.length > 24) bad = t('admin.a_tab_label_is_at_most');
        labels[tab] = text;
      }
      var list = (S.org.layout && S.org.layout.hidden[tab]) || asList((saved.hidden || {})[tab]).map(String);
      if (list.length) hidden[tab] = list.map(Number);
    });
    if (bad) { orgRefuse('layout', bad); return; }
    if (!armed(node, t('admin.click_again_save_the_boss_menu'))) return;
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
    var tv = trim(text);
    if (tv === '') return null;
    if (!/^-?\d+$/.test(tv)) return false;
    var n = Number(tv);
    return n >= lo && n <= hi ? n : false;
  }
  ACTIONS['org-role-add'] = function (node) {
    var grade = wholeOrNull(S.forms['org.new.grade'], 0, 100);
    var pay = wholeOrNull(S.forms['org.new.pay'], 0, 100000000);
    var label = trim(S.forms['org.new.label']), name = trim(S.forms['org.new.name']);
    if (grade === null || grade === false) { orgRefuse('role-add', t('admin.give_the_role_a_whole_grade')); return; }
    if (!label || !name) { orgRefuse('role-add', t('admin.give_the_role_a_name_and')); return; }
    if (pay === false) { orgRefuse('role-add', t('admin.pay_is_a_whole_number_of')); return; }
    if (!armed(node, t('admin.click_again_add') + label + t('admin.at_grade') + grade,
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
    if (!name || !label) { orgRefuse('role:' + g, t('admin.a_role_needs_a_name_and')); return; }
    if (pay === false) { orgRefuse('role:' + g, t('admin.pay_is_a_whole_number_of')); return; }
    if (newGrade === false || newGrade === null) { orgRefuse('role:' + g, t('admin.the_grade_is_a_whole_number')); return; }
    if (!armed(node, t('admin.click_again_save') + label, [pre + 'name', pre + 'label', pre + 'pay', pre + 'grade'])) return;
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
    if (grade == null) { orgRefuse('hire', t('admin.add_a_role_first_in_roles')); return; }
    var data = { grade: Number(grade) };
    var who;
    if (hasPlayer()) {
      data.ref = S.players.ref;
      who = String((S.players.data.player || {}).name || 'them');
    } else {
      var cid = trim(S.forms['org.hire.cid']);
      if (!cid) { orgRefuse('hire', t('admin.look_a_player_up_in_players_2')); return; }
      data.subject = cid.slice(0, 64);
      who = cid;
    }
    if (!armed(node, t('admin.click_again_hire_as', who, roleName(d, grade)), ['org.hire.cid'])) return;
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
    if (m && String(m.grade) === String(grade)) { orgRefuse('role-of:' + ref, t('admin.they_hold_that_role_already_pick')); return; }
    if (!armed(node, t('admin.click_again_make') + memberName(ref) + ' ' + roleName(d, grade))) return;
    orgWrite('orgMemberRole', { member: ref, grade: Number(grade) }, 'role-of:' + ref, node, function () {
      delete S.org.staged['role:' + ref];
    });
  };
  ACTIONS['org-member-suspend'] = function (node) {
    var ref = node.getAttribute('data-id');
    var pre = 'org.m.' + ref + '.';
    var hours = wholeOrNull(S.forms[pre + 'hours'], 0, 720);
    if (hours === null || hours === false) { orgRefuse('suspend:' + ref, t('admin.hours_are_a_whole_number_from')); return; }
    if (!armed(node, hours === 0 ? t('admin.click_again_lift') + memberName(ref) + t('admin.suspension_2')
      : t('admin.click_again_suspend_for_h', memberName(ref), hours), [pre + 'hours', pre + 'sreason'])) return;
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
    if (at === false || cd === false) { orgRefuse('limits:' + ref, t('admin.at_once_is_1_to_50')); return; }
    if (!armed(node, t('admin.click_again_at_once_cooldown', at == null ? t('admin.servers_word') : at,
      cd == null ? t('admin.servers_word') : t('admin.n_min', cd)), [pre + 'at', pre + 'cd'])) return;
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
    var said = { clear: 'admin.click_again_clear_for', deny: 'admin.click_again_deny_to' }[state] || 'admin.click_again_grant_to';
    if (!armed(node, t(said, powerName(d, power), memberName(ref)))) return;
    orgWrite('orgMemberOverride', { member: ref, power: power, state: state }, 'grant:' + ref, node);
  };
  ACTIONS['org-member-codename'] = function (node) {
    var ref = node.getAttribute('data-id');
    var bind = 'org.m.' + ref + '.codename';
    var text = trim(S.forms[bind]);
    if (text.length > 32) { orgRefuse('staff:' + ref, t('admin.a_codename_is_at_most_32')); return; }
    if (!armed(node, text ? t('admin.click_again_codename') + text : t('admin.click_again_clear_the_codename'), [bind])) return;
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
    if (!reason) { orgRefuse('fire:' + ref, t('admin.give_a_reason_it_goes_on')); return; }
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

  /* The organisation extras 2's clicks (Armory, Record & discipline, the form). */
  ACTIONS['org-arm-remove'] = function (node) {
    var slot = node.getAttribute('data-id');
    var raw = trim(S.forms['org.arm.out.' + slot] == null ? '1' : S.forms['org.arm.out.' + slot]);
    if (!/^\d+$/.test(raw) || raw === '0') { orgRefuse('arm:' + slot, t('admin.how_many_a_whole_number_from')); return; }
    if (!armed(node, null, ['org.arm.out.' + slot])) return;
    orgWrite('orgArmoryStock', { remove: true, slot: parseInt(slot, 10), count: parseInt(raw, 10) }, 'arm:' + slot,
      node);
  };
  ACTIONS['org-arm-stock'] = function (node) {
    var item = trim(S.forms['org.arm.item']);
    var raw = trim(S.forms['org.arm.count'] == null ? '1' : S.forms['org.arm.count']);
    if (!item) { orgRefuse('arm:stock', t('admin.write_the_item_name')); return; }
    if (!/^\d+$/.test(raw) || raw === '0') { orgRefuse('arm:stock', t('admin.how_many_a_whole_number_from')); return; }
    if (!armed(node, null, ['org.arm.item', 'org.arm.count'])) return;
    orgWrite('orgArmoryStock', { item: item, count: parseInt(raw, 10) }, 'arm:stock', node);
  };
  ACTIONS['org-arm-limit'] = function (node) {
    var g = node.getAttribute('data-id');
    var raw = trim(S.forms['org.arm.lim.' + g] == null ? '' : S.forms['org.arm.lim.' + g]);
    if (!/^\d+$/.test(raw)) { orgRefuse('arm:lim:' + g, t('admin.a_whole_number_0_for_none')); return; }
    if (!armed(node, null, ['org.arm.lim.' + g])) return;
    orgWrite('orgArmoryLimit', { grade: parseInt(g, 10), count: parseInt(raw, 10) }, 'arm:lim:' + g, node);
  };
  ACTIONS['org-rep-adjust'] = function (node) {
    var points = Number(trim(S.forms['org.rep.points']));
    var reason = trim(S.forms['org.rep.reason']);
    if (!points || Math.floor(points) !== points) { orgRefuse('rep', t('admin.a_whole_number_of_points_either')); return; }
    if (!reason) { orgRefuse('rep', t('admin.give_a_reason')); return; }
    if (!armed(node, t(points > 0 ? 'admin.click_again_add_points' : 'admin.click_again_take_off_points', Math.abs(points)),
      ['org.rep.points', 'org.rep.reason'])) return;
    orgWrite('orgRepAdjust', { points: points, reason: reason.slice(0, 200) }, 'rep', node, function () {
      delete S.forms['org.rep.points'];
      delete S.forms['org.rep.reason'];
    });
  };
  ACTIONS['org-pay-method'] = function (node) {
    if (!armed(node)) return;
    orgWrite('orgPayoutMethod', { method: node.getAttribute('data-value') }, 'paymethod', node);
  };
  ACTIONS['org-drop-settle'] = function (node) {
    var key = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgDropSettle', { handle: key, how: node.getAttribute('data-value') }, 'drop:' + key, node);
  };
  ACTIONS['org-garage-toggle'] = function (node) {
    disarm();
    var model = node.getAttribute('data-value');
    var g = ((S.org.data || {}).extras3 || {}).garage || {};
    var now = asList(g.all).filter(function (a) { return a.model === model; })[0];
    if (!S.org.garage) S.org.garage = {};
    var was = S.org.garage[model] !== undefined ? S.org.garage[model] : !!(now && now.offered);
    S.org.garage[model] = !was;
    drawOrg();
  };
  ACTIONS['org-garage-offer'] = function (node) {
    var g = ((S.org.data || {}).extras3 || {}).garage || {};
    var models = asList(g.all).filter(function (a) {
      return S.org.garage && S.org.garage[a.model] !== undefined ? S.org.garage[a.model] : a.offered === true;
    }).map(function (a) { return a.model; });
    if (!armed(node, tn('admin.click_again_offer_vehicles', models.length))) return;
    orgWrite('orgGarageOffer', { models: models }, 'garage', node, function () { S.org.garage = null; });
  };
  ACTIONS['org-garage-remove'] = function (node) {
    var ref = node.getAttribute('data-ref');
    if (!armed(node)) return;
    orgWrite('orgGarageRemove', { member: ref }, 'garage:' + ref, node);
  };
  ACTIONS['org-internal'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgInternalDecide', { id: id, approve: node.getAttribute('data-value') === 'yes' }, 'ic:' + id, node);
  };
  ACTIONS['org-stats-reset'] = function (node) {
    var ref = node.getAttribute('data-ref');
    if (!armed(node)) return;
    orgWrite('orgStatsReset', ref ? { member: ref } : { all: true }, 'stats:' + ref, node);
  };
  ACTIONS['org-x2-kind'] = function (node) {
    disarm();
    S.org.x2.kind = node.getAttribute('data-value');
    drawOrg();
  };
  ACTIONS['org-disc-give'] = function (node) {
    var reason = trim(S.forms['org.disc.reason']);
    if (!S.org.x2.member) { orgRefuse('disc', t('admin.pick_the_member_first')); return; }
    if (!reason) { orgRefuse('disc', t('admin.give_a_reason')); return; }
    if (!armed(node, null, ['org.disc.reason'])) return;
    orgWrite('orgStrike', { member: S.org.x2.member, kind: S.org.x2.kind || 'strike', reason: reason }, 'disc', node,
      function () { delete S.forms['org.disc.reason']; });
  };
  ACTIONS['org-disc-over'] = function (node) {
    var id = node.getAttribute('data-id');
    var reason = trim(S.forms['org.over.' + id]);
    if (!reason) { orgRefuse('over:' + id, t('admin.say_why_it_is_overturned')); return; }
    if (!armed(node, null, ['org.over.' + id])) return;
    orgWrite('orgOverturn', { member: node.getAttribute('data-ref'), id: id, reason: reason }, 'over:' + id, node);
  };
  ACTIONS['org-form-save'] = function (node) {
    var most = parseInt(node.getAttribute('data-count'), 10) || 0;
    var x = (S.org.data || {}).extras2 || {};
    var current = asList(x.form);
    var list = [];
    var binds = [];
    for (var i = 0; i < most; i += 1) {
      var key = 'org.form.q' + i;
      binds.push(key);
      var q = trim(S.forms[key] == null ? (current[i] !== undefined ? String(current[i]) : '') : S.forms[key]);
      if (q) list.push(q);
    }
    if (!armed(node, null, binds)) return;
    orgWrite('orgRecruitForm', { questions: list }, 'form', node);
  };
  ACTIONS['org-note-save'] = function (node) {
    var id = node.getAttribute('data-id');
    var text = trim(S.forms['org.note.' + id]);
    if (!text) { orgRefuse('app:' + id, t('admin.write_the_note')); return; }
    if (!armed(node, null, ['org.note.' + id])) return;
    orgWrite('orgInterviewNote', { id: id, text: text }, 'app:' + id, node, function () {
      delete S.forms['org.note.' + id];
    });
  };
  ACTIONS['org-note-clear'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgInterviewNote', { id: id, clear: true }, 'app:' + id, node);
  };

  /* The organisation extras' clicks (Work & channel). */
  ACTIONS['org-work-assign'] = function (node) {
    var id = node.getAttribute('data-id');
    var member = S.org.work.member[id];
    if (!member) { orgRefuse('work:' + id, t('admin.pick_the_member_first')); return; }
    if (!armed(node)) return;
    orgWrite('orgContractAssign', { id: id, member: member }, 'work:' + id, node);
  };
  ACTIONS['org-work-release'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgContractAssign', { id: id, release: true }, 'work:' + id, node);
  };
  ACTIONS['org-work-approve'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgAcceptDecide', { id: id, approve: node.getAttribute('data-value') === 'yes' }, 'ap:' + id, node);
  };
  ACTIONS['org-work-rules'] = function (node) {
    disarm();
    S.org.work.rules[node.getAttribute('data-id')] = node.getAttribute('data-value');
    drawOrg();
  };
  ACTIONS['org-work-dossier'] = function (node) {
    var id = node.getAttribute('data-id');
    var notes = trim(S.forms['org.dossier.' + id]);
    var data = { id: id };
    if (notes) data.notes = notes;
    if (S.org.work.spot[id]) data.spot = S.org.work.spot[id];
    if (S.org.work.rules[id]) data.rules = S.org.work.rules[id];
    if (!data.notes && !data.spot && !data.rules) { orgRefuse('work:' + id, t('admin.write_notes_or_pick_a_spot')); return; }
    if (!armed(node, null, ['org.dossier.' + id])) return;
    orgWrite('orgDossier', data, 'work:' + id, node, function () { delete S.forms['org.dossier.' + id]; });
  };
  ACTIONS['org-work-dclear'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgDossier', { id: id, clear: true }, 'work:' + id, node);
  };
  ACTIONS['org-probation'] = function (node) {
    var ref = node.getAttribute('data-ref');
    if (!armed(node)) return;
    orgWrite('orgProbation', { member: ref, passed: node.getAttribute('data-value') === 'yes' }, 'pro:' + ref, node);
  };
  ACTIONS['org-duty-off'] = function (node) {
    var ref = node.getAttribute('data-ref');
    if (!armed(node)) return;
    orgWrite('orgDutyOff', { member: ref }, 'duty:' + ref, node);
  };
  ACTIONS['org-chan-remove'] = function (node) {
    var id = node.getAttribute('data-id');
    if (!armed(node)) return;
    orgWrite('orgChannelRemove', { id: id }, 'msg:' + id, node);
  };
  ACTIONS['org-chan-mute'] = function (node) {
    var raw = trim(S.forms['org.mute.hours'] == null ? '24' : S.forms['org.mute.hours']);
    if (!/^\d+$/.test(raw)) { orgRefuse('chan', t('admin.hours_a_whole_number_0_lifts')); return; }
    if (!armed(node, null, ['org.mute.hours'])) return;
    orgWrite('orgChannelMute', { member: node.getAttribute('data-ref'), hours: parseInt(raw, 10) }, 'chan', node);
  };
  ACTIONS['org-chan-post'] = function (node) {
    var text = trim(S.forms['org.channel']);
    if (!text) { orgRefuse('chan', t('admin.write_the_message')); return; }
    if (!armed(node, null, ['org.channel'])) return;
    orgWrite('orgChannelPost', { text: text }, 'chan', node, function () { delete S.forms['org.channel']; });
  };

  ACTIONS['org-dir'] = function (node) { disarm(); S.org.dir = node.getAttribute('data-value'); drawOrg(); };
  ACTIONS['org-funds'] = function (node) {
    var dir = S.org.dir;
    var amount = wholeOrNull(S.forms['org.funds.amount'], 1, 100000000);
    var reason = trim(S.forms['org.funds.reason']);
    if (amount === null || amount === false) { orgRefuse('funds', t('admin.give_a_whole_number_of_dollars')); return; }
    if (!reason) { orgRefuse('funds', t('admin.give_a_reason_it_goes_on')); return; }
    if (dir === 'bonus' && !S.org.bonusTo) { orgRefuse('funds', t('admin.pick_the_member_the_bonus_goes')); return; }
    var label = dir === 'deposit' ? t('admin.click_again_deposit') + money(amount)
      : dir === 'withdraw' ? t('admin.click_again_withdraw') + money(amount)
        : t('admin.click_again_pay') + memberName(S.org.bonusTo) + ' ' + money(amount);
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
    if (pct === null || pct === false) { orgRefuse('cut', t('admin.a_cut_is_a_whole_percent') + cap + '.'); return; }
    if (pct > cap) { orgRefuse('cut', t('admin.at_most') + cap + t('admin.the_cap_on_all_cuts_of')); return; }
    var what = kind === 'role' ? t('admin.the_cut_for') + roleName(d, grade) : kind === 'payout' ? t('admin.the_payout_cut')
      : t('admin.the_cut_on_kind', kind);
    if (!armed(node, t('admin.click_again_set_to_percent', what, pct), [bind])) return;
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
      orgRefuse('access', t('admin.most_reward_is_whole_dollars_at'));
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
    if (!id) { orgRefuse('pick', t('admin.give_the_contract_id')); return; }
    var to = S.org.staged.pick || '';
    if (!armed(node, to ? t('admin.click_again_pin_to', id, memberName(to)) : t('admin.click_again_clear_the_pick_on') + id,
      ['org.pick.id'])) return;
    var data = { id: id.slice(0, 64) };
    if (to) data.member = to;
    orgWrite('orgPick', data, 'pick', node);
  };

  ACTIONS['org-broadcast'] = function (node) { disarm(); S.org.staged.broadcast = node.getAttribute('data-value') === 'yes'; drawOrg(); };
  ACTIONS['org-notice'] = function (node) {
    var text = trim(S.forms['org.notice']);
    if (!text) { orgRefuse('notice', t('admin.write_the_notice_first')); return; }
    if (!armed(node, S.org.staged.broadcast ? t('admin.click_again_post_it_and_message') : t('admin.click_again_post_it'),
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
    if (raw === '' || !isFinite(n) || n < 0) { orgRefuse('limits', t('admin.give_a_number_for') + k + '.'); return; }
    var e = settingEntry('Organisation.Limits.' + k);
    if (e && ((e.min != null && n < e.min) || (e.max != null && n > e.max))) {
      orgRefuse('limits', t('admin.key_is_from_to', k, e.min, e.max));
      return;
    }
    if (e && e.integer && Math.floor(n) !== n) { orgRefuse('limits', k + t('admin.is_a_whole_number')); return; }
    if (!armed(node, t('admin.click_again_key_to_now', k, num(n), num((d.limits || {})[k])), [bind])) return;
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

  Text.later(function () {
    HELP.push(
    { title: t('admin.the_hitman_organisation'), icon: 'people-group',
      text: t('admin.off_as_shipped_on_the_hitmen')
        + t('admin.on_the_phone_and_its_own')
        + t('admin.boss_role_or_one_boss_within')
        + t('admin.frozen_onto_a_contract_when_a'),
      links: [{ key: 'Organisation.Enabled', label: t('admin.the_switch') },
        { key: 'Organisation.RequireJobToAccept', label: t('admin.only_members_may_accept') }] });
  });
  Text.later(function () {
    STAFF_ACTIONS.push(
    { title: t('admin.run_the_hitman_organisation'), icon: 'people-group', view: 'orgsetup', go: t('admin.hitman_organisation'),
      text: t('admin.turn_it_on_sync_the_job')
        + t('admin.with_a_reason_set_cuts_contract'),
      also: { view: 'orgmembers', go: t('admin.members') } },
    { title: t('admin.give_bosses_powers'), icon: 'key', view: 'bpmatrix', go: t('admin.boss_permissions'),
      text: t('admin.the_grid_of_powers_by_boss')
        + t('admin.save_limits_sets_the_bounds_delegation'),
      also: { view: 'bplimits', go: t('admin.limits') } },
    { title: t('admin.set_a_place_on_the_map'), icon: 'location-dot', view: 'locations', go: t('admin.locations'),
      text: t('admin.the_boss_office_sign_up_and')
        + t('admin.districts_and_the_prison_zone_stand') });
  });

  /* Loaded to the end: admin.html's fallback, which gives the focus back
     when this file fails to load or throws while loading, stands down. */
  window.CH_ADMIN_READY = true;
})();
