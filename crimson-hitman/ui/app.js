/* Crimson Hitman System — app shell.
   The UI holds no authority: it renders what the server sends and asks for
   what the player clicks. Every value shown here arrived in a projection. */

(function () {
  'use strict';

  /* The resource this page belongs to, read from the page's own address.
  
     This was the literal 'crimson-hitman'. Every NUI call posts to
     https://<resource>/..., and renaming a resource folder is an ordinary
     thing for a server owner to do (a GitHub zip unpacks as
     crimson-hitman-main) — at which point every request in the app goes to
     a resource that does not exist, every one of them answers
     'unreachable', and the app is a set of buttons that do nothing with no
     clue anywhere as to why. The client derives every other URL from
     GetCurrentResourceName(); this is the one place that did not.
  
     It then asked GetParentResourceName, which changed nothing. FiveM
     defines that only in frames directly under its NUI root (the epoxy
     script, NUIApp.cpp), and this page is an iframe inside lb-phone's own
     frame, so it never has it: the literal was used on every server. The
     page's own address is always there. FiveM serves a resource's files
     from https://cfx-nui-<resource>/, which is where the client points
     lb-phone for this page (client/main.lua), and the NUI request handler
     matches a resource name whatever its case, so a host the browser has
     lowercased still reaches it. GetParentResourceName and the literal are
     left for a page opened anywhere else — a browser on the file directly,
     a layout test — because a page that cannot work out its own name
     should still behave as it did before. */
  var RESOURCE = (/^cfx-nui-(.+)$/.exec(String((window.location
      && window.location.hostname) || '')) || [])[1]
    || (typeof GetParentResourceName === 'function' && GetParentResourceName())
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
        xhr.open('GET', '../locales/' + lang + '.json?v=' + encodeURIComponent(window.CH_BUILD || 'dev'), false);
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
  Text.use(((String((window.location && window.location.search) || '')).match(/[?&]lang=([^&]+)/) || [])[1]);
  var state = {
    tab: 'board', board: null, mine: null, ledger: null,
    // Which app this player is shown: 'full', or 'whitelisted' for a player
    // on a job the app bars, who is shown the whitelisted-job view alone
    // (jobView, its one read) while the server keeps it on.
    mode: 'full', jobView: null,
    progress: {}, dialog: null, leoConfirmed: false, wallet: null,
    busy: false, notice: null, walletFailed: null,
    // Why the board, Mine or the ledger has nothing in it, when the reason
    // is that the server refused rather than that there is nothing to show.
    loadFailed: {},
    // Which of those refusals asking again cannot change (finalRefusal), so
    // their card offers no Try again.
    loadFinal: {},
    // Which sections have had an answer at all. Without this the app has no
    // way to tell "asked, and there is nothing" from "have not been told
    // yet", and every view took the second for the first: On me announced
    // "Nobody is looking for you" on every open of the app, for as long as
    // the round trip took — up to the fifteen seconds the client waits
    // before it gives up. Set only on a reply that carried a payload, so
    // Try again returns the section to asking rather than to empty.
    loaded: {},
    // Target headshots, keyed by the reference a projection gave us. The
    // listing carries references, not images, so a board refresh re-sends
    // nothing and a face is fetched once per render. `null` marks a fetch in
    // flight, so fifteen rows of the same target ask once.
    images: {},
    // Items and weapons chosen per payout slot. These live here rather than
    // in the DOM because the picker rebuilds its own markup on every add and
    // remove, and a rebuilt <select> forgets what was put in it.
    picked: {},
    // The page of people the target picker is showing, and what was asked
    // for to get it. The Place form is rebuilt on every keystroke that
    // touches a payout, and refetching the roster each time is a round trip
    // per rebuild against a rate limit — and a list that flickers away
    // under whoever was reading it.
    browse: { scope: 'all', query: '', page: 1, data: null, pending: null, draw: null,
              nearbyClosed: false },
    // The Place form's own values. They used to live only in the DOM, so
    // anything that re-rendered — a tab change, a push, a late reply, the
    // sworn-officer dialog — silently emptied the form the player had built.
    // Keeping them here is what makes the form survive being rebuilt.
    draft: {},
    // Open amendment proposals, keyed by contract. Read on demand rather
    // than carried in every listing row: most contracts have none.
    proposals: {},
    // Half-typed messages, one per conversation — keyed by contract and
    // operative, so a draft never turns up in somebody else's thread.
    drafts: {},
    // What Verify kill last refused on each contract, kept under its
    // buttons until the hitman's next go. The photo refusals are the longest
    // messages in the app and the ones that say what to fix before the kill
    // runs out, and a hitman back from the camera read them in a notice that
    // was gone in four seconds.
    lastRefusal: {},
    // The thread (by threadKey) a call placed from here is live in. The
    // phone draws no call screen for it, so this is what puts Hang up there.
    call: null
  };

  /* ---------- diagnostics ----------------------------------------------

     Until this existed, a JavaScript error in this page went nowhere at
     all. CEF has no console anybody looks at, no error reached the client,
     nothing reached the server log, and render() had already emptied #view
     before it threw — so the symptom was a blank app with a working tab
     bar, and the only person who could see it was the player, who could
     only say "it broke". Four render crashes shipped that way and every one
     of them was reported in those words.

     Three things, then:

       * Nothing thrown in this page is lost. Errors are kept here, sent to
         the client, and written to the server log where an owner can read
         them.
       * A throw inside a render does not blank the app. It draws what went
         wrong and a way out, because a player who can still press Try again
         is not stuck.
       * Everything the page did recently can be read back in game, on the
         phone, without a debugger — which is the only place this runs.

     Reporting is capped per session. A render loop that throws every frame
     would otherwise write the same row to the audit log sixty times a
     second, which is a denial of service on the log this exists to fill. */

  var Diag = (function () {
    var MAX_EVENTS = 80;
    var REPORT_CAP = 8;

    var events = [];
    var reported = 0;
    var suppressed = 0;
    var seq = 0;
    var panelOpen = false;
    var started = now();

    function now() {
      // performance.now over Date.now: monotonic, and the numbers stay
      // small and readable as "ms since the app opened".
      return (window.performance && window.performance.now)
        ? Math.round(window.performance.now()) : 0;
    }

    function note(kind, text, detail) {
      seq += 1;
      events.push({ n: seq, at: now() - started, kind: kind, text: String(text),
                    detail: detail });
      if (events.length > MAX_EVENTS) { events.shift(); }
      if (panelOpen) { drawPanel(); }
      return seq;
    }

    /* Send one fault to the client, which puts it in the server log.

       Capped, and the cap itself is reported once, so a reader of the log
       can tell "eight errors" from "eight errors and then we stopped
       counting". */
    function report(what, where, stack) {
      if (reported >= REPORT_CAP) {
        suppressed += 1;
        if (suppressed === 1) {
          send({ what: 'further page errors suppressed', where: 'diagnostics',
                 stack: '', build: window.CH_BUILD || 'dev' });
        }
        return false;
      }
      reported += 1;
      send({ what: String(what).slice(0, 300),
             where: String(where || '').slice(0, 200),
             stack: String(stack || '').slice(0, 900),
             tab: state && state.tab, build: window.CH_BUILD || 'dev' });
      return true;
    }

    /* The log a staff member asked for. Not a fault, so not under the cap
       that bounds fault reports (a page that had reported its eight was
       refused the one thing staff asked it for), and the newest part of it:
       cut from the front, the events closest to the problem were the ones
       lost. Lines are joined with a marker the server splits on, since it
       strips line breaks from anything a page sends. */
    function dump(text) {
      var flat = String(text || '').split('\n').join(' || ');
      send({ what: 'page diagnostics', where: 'requested',
             stack: flat.slice(-900), tab: state && state.tab,
             build: window.CH_BUILD || 'dev' });
    }

    // Deliberately not post(): post() is instrumented by this module and a
    // failure inside it must not recurse into reporting its own report.
    function send(body) {
      try {
        fetch('https://' + RESOURCE + '/crimson:pageError', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json; charset=UTF-8' },
          body: JSON.stringify(body)
        }).catch(function () {});
      } catch (err) { /* nothing left to try */ }
    }

    /* Run fn, and if it throws, say so everywhere rather than unwinding
       into a browser nobody is watching. Returns the sentinel on failure so
       a caller can tell the two apart. */
    var FAILED = {};
    function guard(label, fn) {
      try {
        return fn();
      } catch (err) {
        var message = (err && err.message) || String(err);
        note('throw', label + ': ' + message, err && err.stack);
        report(message, label, err && err.stack);
        return FAILED;
      }
    }

    function install() {
      window.onerror = function (message, source, line, column, err) {
        note('error', message + ' (' + (source || '?') + ':' + (line || 0) + ')',
             err && err.stack);
        report(message, (source || '?') + ':' + (line || 0) + ':' + (column || 0),
               err && err.stack);
        // False: do not swallow it. Anything else watching still sees it.
        return false;
      };

      window.addEventListener('unhandledrejection', function (event) {
        var reason = event && event.reason;
        var message = (reason && reason.message) || String(reason);
        note('reject', message, reason && reason.stack);
        report(message, t('app.unhandled_rejection'), reason && reason.stack);
      });

      note('boot', 'build ' + (window.CH_BUILD || 'dev'));
    }

    /* ---- the in-game panel ----

       Opened by tapping the build stamp in the ledger five times, the way
       a phone exposes a developer menu, because there is no keyboard here
       and no room for a permanent control. Closed by its own button. */
    var taps = 0, lastTap = 0;

    function tapped() {
      var tv = now();
      taps = (tv - lastTap < 1200) ? taps + 1 : 1;
      lastTap = tv;
      if (taps >= 5) { taps = 0; toggle(); }
    }

    function toggle() {
      panelOpen = !panelOpen;
      if (panelOpen) { drawPanel(); } else { removePanel(); }
    }

    function removePanel() {
      var old = document.getElementById('diag');
      if (old && old.parentNode && old.parentNode.removeChild) {
        old.parentNode.removeChild(old);
      }
    }

    /* Where an overlay goes. document.body in a browser; anything that
       exists otherwise.

       This runs from a click handler, so a throw here does not stay here:
       it unwinds into the browser and leaves the tap looking like it did
       nothing. The one screen whose job is to explain a failure must not be
       able to cause one. */
    function overlayHost() {
      return document.body
          || document.getElementById('app')
          || document.documentElement
          || null;
    }

    function drawPanel() {
      var host = overlayHost();
      if (!host) { return; }
      removePanel();

      var panel = document.createElement('div');
      panel.id = 'diag';

      var head = document.createElement('div');
      head.className = 'diag-head';

      var title = document.createElement('strong');
      title.textContent = t('app.diagnostics') + (window.CH_BUILD || 'dev');
      head.appendChild(title);

      var close = make('button');
      close.className = 'btn ghost';
      close.textContent = t('app.close');
      close.onclick = toggle;
      head.appendChild(close);
      panel.appendChild(head);

      var summary = document.createElement('p');
      summary.className = 'diag-summary';
      summary.textContent = counts();
      panel.appendChild(summary);

      var list = document.createElement('div');
      list.className = 'diag-log';
      // Newest first: the thing that just went wrong is what is being
      // looked for, and a phone shows about eight rows.
      for (var i = events.length - 1; i >= 0; i--) {
        list.appendChild(row(events[i]));
      }
      panel.appendChild(list);

      var copy = make('button');
      copy.className = 'btn ghost diag-copy';
      copy.textContent = t('app.send_this_to_the_server_log');
      // Built as dump() builds the log staff ask for: lines joined with the
      // marker the server splits on, and the newest 900 characters, which
      // is all the server keeps. Sent whole and oldest first, the server
      // kept the start of the session and cut the events nearest the fault.
      copy.onclick = function () {
        var flat = asText().split('\n').join(' || ');
        send({ what: 'diagnostics requested by the player', where: 'panel',
               stack: flat.slice(-900), build: window.CH_BUILD || 'dev' });
        note('sent', t('app.diagnostics_sent_to_the_server_log'));
      };
      panel.appendChild(copy);

      host.appendChild(panel);
    }

    function row(event) {
      var line = document.createElement('div');
      line.className = 'diag-row is-' + event.kind;

      var when = document.createElement('span');
      when.className = 'diag-when';
      when.textContent = (event.at / 1000).toFixed(1) + 's';
      line.appendChild(when);

      var text = document.createElement('span');
      text.className = 'diag-text';
      text.textContent = event.kind + ' · ' + event.text;
      line.appendChild(text);

      return line;
    }

    function counts() {
      var byKind = {};
      for (var i = 0; i < events.length; i++) {
        byKind[events[i].kind] = (byKind[events[i].kind] || 0) + 1;
      }
      var parts = [];
      for (var kind in byKind) {
        if (Object.prototype.hasOwnProperty.call(byKind, kind)) {
          parts.push(byKind[kind] + ' ' + kind);
        }
      }
      parts.push(reported + ' reported');
      if (suppressed) { parts.push(suppressed + ' suppressed'); }
      return parts.join(' · ');
    }

    function asText() {
      var out = [];
      for (var i = 0; i < events.length; i++) {
        var e = events[i];
        out.push((e.at / 1000).toFixed(1) + 's ' + e.kind + ' ' + e.text
                 + (e.detail ? ' | ' + e.detail : ''));
      }
      return out.join('\n');
    }

    return { note: note, report: report, dump: dump, guard: guard, install: install,
             tapped: tapped, toggle: toggle, asText: asText, FAILED: FAILED,
             isOpen: function () { return panelOpen; } };
  })();

  /* ---------- transport ---------- */

  // Each call is answered by its own reply; the client bridge correlates
  // them, so two searches in flight cannot resolve into each other.
  function post(name, data) {
    // Timed and recorded, so the diagnostics panel can answer the question
    // a player's "it's broken" never does: which request, how long it took,
    // and what came back. A round trip here crosses CEF, the client, the
    // server and back — four places a reply can be lost — and none of them
    // used to leave a trace on this side.
    var began = (window.performance && window.performance.now)
      ? window.performance.now() : 0;

    function done(result) {
      var ms = Math.round(((window.performance && window.performance.now)
        ? window.performance.now() : 0) - began);
      Diag.note(result && result.ok ? 'ok' : 'refused',
                name + ' ' + ms + 'ms'
                + (result && result.ok ? '' : ' -> ' + ((result && result.err) || '?')));
      return result;
    }

    return fetch('https://' + RESOURCE + '/crimson:' + name, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {})
    }).then(function (r) { return r.json(); }).then(done).catch(function (err) {
      // A body that is not JSON, or a bridge that answered nothing. Both
      // used to arrive as a bare 'unreachable' with no way to tell them
      // apart from a client that never replied.
      Diag.note('unreachable', name + ' -> ' + ((err && err.message) || t('app.no_reply')));
      return done({ ok: false, err: 'unreachable' });
    });
  }

  /* What each refusal code reads as: locales/en.json, "errors". A code
     whose text is null shows nothing of its own. */
  var ERRORS = Text.section('errors');


  /* The requests that can move money, each a handler in server/app.lua
     (tests/static_check.lua, rule 37). One that runs out of the wait may
     still go through: the server can answer after it, and "Try again" placed
     and paid for a second contract. The answer that lands late has the page
     read everything again (the 'late' push). */
  var MONEY_EVENTS = {
    create: true, accept: true, cancel: true, withdrawReward: true, abandon: true,
    bailout: true, informant: true, placerInformant: true, addEscrow: true, improve: true,
    respondAmendment: true, submitPhoto: true, verifyKill: true, locationTip: true,
    goDark: true, proofItem: true, protectionPost: true
  };

  /* And the organisation's money moves, each a request of
     server/org/boss_ops.lua (rule 37 too): every tap makes a fresh nonce, so
     a "Try again" after a timeout was a real second transfer. */
  var ORG_MONEY_EVENTS = { orgDeposit: true, orgWithdraw: true, orgBonus: true };

  /* What each reward source is called when a refusal names it. */
  var SOURCE_WORDS = { cash: 'cash', bank: t('app.bank_money'), dirty: t('app.dirty_money'),
                       item: 'items', weapon: 'weapons' };

  /* A reason refused for what it says, by the rule it broke (the server's
     reason_refused). The Place form and Edit say the same. */
  function reasonRefusedText(data) {
    var rule = data && data.rule;
    if (rule === 'empty') { return t('app.give_a_reason_for_the_contract'); }
    if (rule === 'length') { return t('app.that_reason_is_too_long_make'); }
    if (rule === 'digits') {
      return t('app.that_reason_has_more_digits_in')
        + t('app.in_words_or_leave_them_out');
    }
    if (rule === 'pattern') {
      return t('app.this_server_will_not_take_a');
    }
    if (rule === 'phone') {
      return t('app.a_word_in_that_reason_is');
    }
    // The roleplay reason rules (Config.Roleplay.ReasonQuality).
    if (rule === 'short') {
      return t('app.give_a_real_reason_at_least') + (Number(data.min) || 0) + t('app.characters');
    }
    if (rule === 'words') {
      return t('app.give_a_real_reason_at_least') + (Number(data.min) || 0) + t('app.words');
    }
    if (rule === 'low_effort') {
      return t('app.that_reads_as_no_reason_at');
    }
    return ERRORS.reason_refused;
  }

  /* How long a wait is, in the words every refusal that carries one uses:
     "in 7 seconds", "in about 2 minutes", or "in a moment" where the server
     sent none. One wording for all of them: the wallet and the target list
     said "in a moment" of an hour, and the board's failure card "3600
     seconds". */
  function retryIn(seconds) {
    var s = Math.ceil(Number(seconds) || 0);
    if (!(s > 0)) { return t('app.in_a_moment'); }
    if (s < 60) { return tn('app.in_seconds', s); }
    var m = Math.ceil(s / 60);
    return tn('app.in_about_minutes', m);
  }

  /* ---------- dialogs ----------
     FiveM's NUI is a CEF browser with no dialog handler: window.confirm and
     window.prompt are never shown, confirm resolves false and prompt null.
     Every action gated behind one would silently do nothing, which is
     indistinguishable from the player declining. These render in-page. */

  /* `labels` may carry { yes, no } to name the two buttons. "Yes" and
     "Cancel" under "Withdraw this contract?" left Cancel reading as the
     button that cancels the contract, and a payment's button is better
     named by what it pays. */
  function ask(question, detail, onYes, labels) {
    state.dialog = { kind: 'confirm', question: question, detail: detail, onYes: onYes,
                     labels: labels || {} };
    render();
  }

  /* Ask for a number, with enough around it to answer.
     
     `opts` may carry { label, value, min, max, unit, hint }. An empty box
     under a bare "By how much?" is not a question anybody can answer: it
     never said what the reward was now, what the floor was, or whether the
     figure meant "by" or "to". The player was left guessing, and a guess
     the server refuses reads as the app being broken.
     
     `hint` is called with the current value on every keystroke and returns
     the line under the field, which is where the consequence goes: what
     the contract will be worth, when it will now run out. */
  function askNumber(question, detail, onValue, opts) {
    state.dialog = {
      kind: 'number', question: question, detail: detail, onValue: onValue,
      opts: opts || {}
    };
    render();
  }

  /* A dialog that asks for more than one thing at once.
     
     `fields` are { id, label, type, value, min, max }. On confirm the
     handler is given a plain object keyed by id. Editing a contract needs
     a reason and a deadline together, and asking for them in two dialogs
     one after another is two chances to abandon halfway. */
  function askFields(question, detail, fields, onValues, confirmLabel) {
    state.dialog = {
      kind: 'fields', question: question, detail: detail,
      fields: fields, onValues: onValues, confirmLabel: confirmLabel
    };
    render();
  }

  function closeDialog() {
    state.dialog = null;
    render();
  }

  /* Pick one, then pay, confirmed twice.

     Who first: each option is a button, and the one picked stays picked.
     Then the price: the pay button arms on the first tap, saying so ("Tap
     again to pay $25,000") for three seconds, and pays on the second, so a
     stray thumb on a gamble paid either way is not a purchase. An option the
     server says is not for sale is drawn, disabled, with why. */
  var PICK_CONFIRM_MS = 3000;
  function askPick(question, detail, options, onPick, payLabel) {
    var open = (options || []).filter(function (o) { return !o.disabled; });
    state.dialog = { kind: 'pick', question: question, detail: detail,
                     options: options || [], onPick: onPick, payLabel: payLabel || t('app.pay'),
                     chosen: open.length === 1 ? open[0].pick : null, armed: false };
    render();
  }

  /* Arm a pick dialog's pay button for PICK_CONFIRM_MS; it disarms itself
     if not tapped again by then. */
  function armPick(d) {
    d.armed = true;
    var armedAt = d.armedAt = Date.now();
    setTimeout(function () {
      if (state.dialog === d && d.armed && d.armedAt === armedAt) {
        d.armed = false;
        render();
      }
    }, PICK_CONFIRM_MS);
  }

  function renderPick(view) {
    var d = state.dialog;
    var panel = el('div', 'card dialog');
    panel.appendChild(el('div', 'target', d.question));
    if (d.detail) panel.appendChild(el('div', 'reason', d.detail));

    var list = el('div', 'choices');
    d.options.forEach(function (option) {
      var block = el('div', 'choice' + (option.note ? ' has-note' : ''));
      var button = el('button', option.pick === d.chosen ? 'primary is-chosen' : 'ghost',
        option.label);
      if (option.disabled) {
        button.disabled = true;
      } else {
        // Picking one is the first of the two taps: the pay button arms
        // with it ("Tap again to pay $25,000"), and the second pays. A pick
        // and then a pay that armed and then a pay again was a third tap
        // for no more safety.
        button.onclick = function () {
          d.chosen = option.pick;
          armPick(d);
          render();
        };
      }
      block.appendChild(button);
      if (option.note) { block.appendChild(el('div', 'hint', option.note)); }
      list.appendChild(block);
    });
    panel.appendChild(list);

    var row = el('div', 'row');
    var armedLabel = t('app.tap_again_to') + d.payLabel.charAt(0).toLowerCase() + d.payLabel.slice(1);
    var pay = el('button', d.armed ? 'danger' : 'primary', d.armed ? armedLabel : d.payLabel);
    if (!d.chosen) { pay.disabled = true; }
    pay.onclick = function () {
      if (!d.chosen) { return; }
      if (!d.armed) {
        armPick(d);
        render();
        return;
      }
      var pick = d.chosen, handler = d.onPick;
      state.dialog = null;
      render();
      if (handler) { handler(pick); }
    };
    var no = el('button', 'ghost', t('app.cancel'));
    no.onclick = closeDialog;
    row.appendChild(pay);
    row.appendChild(no);
    panel.appendChild(row);
    if (!d.chosen) { panel.appendChild(el('div', 'hint', t('app.pick_who_to_ask_about_first'))); }
    view.appendChild(panel);
  }

  function renderFields(view) {
    var d = state.dialog;
    var panel = el('div', 'card dialog');
    panel.appendChild(el('div', 'target', d.question));
    if (d.detail) panel.appendChild(el('div', 'reason', d.detail));

    /* What the player has typed, kept off the DOM.
    
       Every control below was seeded from spec.value — the DEFAULT — on
       every render, and render() runs on any reply that lands: a push from
       the server, a late board load, a headshot arriving. So a player part
       way through a dialog had their answer silently replaced with the
       default under them, and the dialog looked untouched, so the natural
       thing to do is to press Save on a value they did not choose. The Place
       form was fixed this way for the same reason; the dialogs were not. */
    d.values = d.values || {};

    function current(spec) {
      if (d.values[spec.id] !== undefined) { return d.values[spec.id]; }
      return (spec.value !== undefined && spec.value !== null)
        ? String(spec.value) : '';
    }

    var nodes = {};
    d.fields.forEach(function (spec) {
      // A choice, where the server takes one. Without this the only control
      // a dialog could offer was a text box, so the Edit dialog asked for
      // free text on servers that refuse it.
      if (spec.type === 'select') {
        var choose = make('select');
        choose.id = 'dialog-' + spec.id;
        (spec.options || []).forEach(function (option) {
          var node = document.createElement('option');
          node.value = String(option.value);
          node.textContent = option.label;
          choose.appendChild(node);
        });
        choose.value = current(spec);
        choose.onchange = function () { d.values[spec.id] = choose.value; };
        nodes[spec.id] = choose;
        panel.appendChild(labelled(spec.label, choose));
        return;
      }

      var input = make('input');
      input.id = 'dialog-' + spec.id;
      input.type = spec.type || 'text';
      input.value = current(spec);
      input.oninput = function () { d.values[spec.id] = input.value; };
      // A number field on a phone should bring up the number pad.
      if ((spec.type || 'text') === 'number') { input.inputMode = 'numeric'; }
      if (spec.max !== undefined) {
        if (input.type === 'number') { input.max = spec.max; } else { input.maxLength = spec.max; }
      }
      if (spec.min !== undefined) { input.min = spec.min; }
      // What an empty box means, where empty is an answer of its own.
      if (spec.placeholder) { input.placeholder = spec.placeholder; }
      nodes[spec.id] = input;
      panel.appendChild(labelled(spec.label, input));
    });

    var row = el('div', 'row');
    var yes = el('button', 'primary', d.confirmLabel || t('app.save'));
    yes.onclick = function () {
      var values = {};
      d.fields.forEach(function (spec) {
        // The node is the truth at the moment of pressing Save; d.values is
        // what survives a redraw between keystrokes. They agree unless a
        // render landed since the last input event, in which case the node
        // is the one that was just rebuilt from d.values anyway.
        var raw = nodes[spec.id] ? nodes[spec.id].value : current(spec);
        values[spec.id] = (spec.type === 'number') ? (parseInt(raw, 10) || 0) : raw;
      });
      // Which fields the player actually edited, as opposed to left on what
      // they opened with.
      var touched = {};
      Object.keys(d.values || {}).forEach(function (id) { touched[id] = true; });
      var handler = d.onValues;
      state.dialog = null;
      render();
      if (handler) handler(values, touched);
    };
    var no = el('button', 'ghost', t('app.cancel'));
    no.onclick = closeDialog;
    row.appendChild(yes);
    row.appendChild(no);
    panel.appendChild(row);
    view.appendChild(panel);
  }

  function renderDialog(view) {
    var d = state.dialog;
    var panel = el('div', 'card dialog');
    panel.appendChild(el('div', 'target', d.question));
    if (d.detail) panel.appendChild(el('div', 'reason', d.detail));

    var input, consequence;
    if (d.kind === 'number') {
      var opts = d.opts || {};

      input = make('input');
      input.type = 'number';
      input.id = 'dialog-value';
      input.min = opts.min !== undefined ? opts.min : 1;
      if (opts.max !== undefined) { input.max = opts.max; }
      /* What the player typed, kept on the dialog rather than in the node.

         This box was seeded from opts.value on every render, and render()
         runs on any reply that lands — a push, a late board load, a face
         arriving. The fields dialog was fixed for exactly this; this one was
         not, and once it started opening on a figure rather than empty, a
         redraw put that figure back under the player: 90 minutes typed, a
         hitman accepts somewhere, the box reads 30 again and Extend sends
         30. */
      if (d.value !== undefined) {
        input.value = d.value;
      } else if (opts.value !== undefined && opts.value !== null) {
        input.value = String(opts.value);
      }

      // Named, because a bare box in a dialog is the player guessing what
      // the number is measured in.
      panel.appendChild(labelled(opts.label || t('app.amount'), input));

      /* Always there, hint or not. It is also where a figure Confirm will
         not take is explained, and a dialog opened without a hint had
         nowhere to say it: Confirm on a bad value returned and said
         nothing, so the tap read as not having registered at all. */
      consequence = el('div', 'hint');
      var showConsequence = function () {
        if (!opts.hint) { return; }
        var current = parseInt(input.value, 10);
        consequence.textContent = opts.hint(isNaN(current) ? null : current) || '';
      };
      input.oninput = function () {
        d.value = input.value;
        showConsequence();
      };
      showConsequence();
      panel.appendChild(consequence);
    }

    var row = el('div', 'row');
    var named = d.labels || {};
    var yes = el('button', 'primary', d.kind === 'number'
      ? ((d.opts && d.opts.confirm) || t('app.confirm')) : (named.yes || t('app.yes')));
    yes.onclick = function () {
      var handler = d.onYes, valueHandler = d.onValue;
      var value = input ? parseInt(input.value, 10) : null;

      // A figure outside what the server will take is refused here, where
      // the player can still see the box and the numbers around it, rather
      // than as an error a moment later with the form already gone.
      if (input) {
        var bounds = d.opts || {};
        var floor = bounds.min !== undefined ? bounds.min : 1;
        if (!value || value < floor
            || (bounds.max !== undefined && value > bounds.max)) {
          consequence.textContent = bounds.max !== undefined
            ? t('app.enter_between', floor, bounds.max)
            : t('app.enter_or_more', floor);
          return;
        }
      }

      state.dialog = null;
      render();
      if (handler) handler();
      if (valueHandler && value && value > 0) valueHandler(value);
    };
    var no = el('button', 'ghost', named.no || t('app.cancel'));
    no.onclick = closeDialog;
    row.appendChild(yes);
    row.appendChild(no);
    panel.appendChild(row);

    view.appendChild(panel);
  }

  /* ---------- the kill photo, seen once ----------

     The client's photo of the job, opened on purpose from their Ledger row
     and shown once. The server spends the view as it hands the photo over
     (openPhoto), so this dialog is the only time the page holds it: Save to
     Photos puts it in the phone's own gallery, Delete lets it go, and the
     server is told which. The tab bar waits for one of the two (a mis-tap
     there was a Delete); anything else that loses the dialog — a redraw
     that dropped it — is a Delete, and the server is told that too
     (letGoOfProof). A phone closed mid-view tells nobody, and the server
     deletes it once Config.Completion.PhotoOpenSeconds have passed.

     The phone's Photos keeps links, never pictures, so how a photo gets
     there depends on what it is (saveRoute). One the phone cannot take at
     all — or that it refused when asked — is kept for the client in this
     app instead, which opens it again whenever they like until they delete
     it. Nothing is lost because a phone could not save it. */

  /* The photo this page has open and has not yet answered for, by handle.
     Kept off state.dialog so that losing the dialog is something draw() can
     notice: it compares this against what it is about to draw. A photo kept
     in the app is not one of these: closing it only closes it. */
  var proofShown = null;
  /* Draws the Place form's anonymous option again for the target picked
     (viewPlace sets it), where their whitelisted job changes the rule. */
  var placeAnonSync = null;

  // What the client's Ledger row says once the photo is no longer waiting.
  var PROOF_WORDS = {
    saved: t('app.photo_saved_to_your_phone'),
    deleted: t('app.photo_deleted'),
    // Opened and never answered for: this page was closed while it was up.
    // The server deletes it when the time to decide runs out.
    open: t('app.photo_opened_and_not_saved_it')
  };

  /* Set the photo's state here as well as on the server, so the Ledger says
     what happened the moment the dialog closes rather than after the next
     refresh: on its row, or in the list of photos kept in the app. */
  function markProof(handle, photoState) {
    var ledger = state.ledger || {};
    asList(ledger.entries).forEach(function (row) {
      if (row.photo && row.photo.handle === handle) { row.photo.state = photoState; }
    });
    asList(ledger.kept).forEach(function (photo) {
      if (photo && photo.handle === handle) { photo.state = photoState; }
    });
  }

  // What this page last heard of a photo: its Ledger row's state, or its
  // entry in the list of photos kept in the app. Null for one it never saw.
  function proofStateOf(handle) {
    var ledger = state.ledger || {};
    var found = null;
    asList(ledger.entries).forEach(function (row) {
      if (row.photo && row.photo.handle === handle) { found = row.photo.state; }
    });
    asList(ledger.kept).forEach(function (photo) {
      if (photo && photo.handle === handle) { found = photo.state; }
    });
    return found;
  }

  function openProof(handle) {
    // Read before asking: by the time the answer comes, a refresh may have
    // redrawn the row.
    var wasKept = proofStateOf(handle) === 'kept';
    return post('openPhoto', { handle: handle }).then(function (r) {
      // A link to the image host, or, where the server keeps its photos,
      // the photo itself as a data URI.
      var src = r.ok && r.data
        && (typeof r.data.src === 'string' ? r.data.src : r.data.url);
      if (typeof src !== 'string') {
        // Opened on the server and never delivered. A photo kept in the
        // app spent nothing by being opened, so it is still kept and opens
        // again: by what the client said the server answered, or by what
        // this page knew of it, either one. Reported as deleted, the server
        // deleted it, file and all, because one delivery was slow.
        var keptStill = r.err === 'photo_no_answer'
          && (wasKept || (r.data && r.data.kept === true));
        fail(keptStill ? { err: 'photo_kept_no_answer' } : r);
        // Whatever it was, it is not waiting to be opened any more.
        if (r.err === 'photo_gone') { markProof(handle, 'deleted'); redraw(); }
        // A photo that was waiting for its one look spent it all the same.
        // The server is told it is deleted now, rather than being left to
        // delete it when the time to decide runs out.
        if (r.err === 'photo_no_answer' && !keptStill) {
          markProof(handle, 'deleted');
          post('photoDecision', { handle: handle, choice: 'delete' });
          redraw();
        }
        return;
      }
      var kept = r.data.kept === true;
      if (!kept) {
        markProof(handle, 'open');
        proofShown = { handle: handle };
      }
      state.dialog = {
        kind: 'proof', handle: handle, src: src, kept: kept,
        // This server can serve the photo to the phone's Photos itself.
        link: r.data.link === true,
        // Kill photos are off: nothing takes it to the phone's Photos.
        photosOff: r.data.photosOff === true
      };
      render();
    });
  }

  /* How the open photo can go into the phone's Photos, or null where it
     cannot.

       'gallery'  it is on an image host, and its link is handed over;
       'link'     the server keeps it and can serve it: it is asked for the
                  link, which is handed over;
       'upload'   the server keeps it and cannot serve it: lb-phone uploads
                  it wherever the phone uploads its own photos, and that
                  link is handed over.

     None while kill photos are off: the server then serves nothing, and an
     upload or a save would hand the photo to lb-phone and an image host,
     which nothing does for one while they are off. It is kept in the app
     or deleted. */
  function saveRoute(d) {
    if (d.photosOff) { return null; }
    if (!/^data:/.test(d.src)) { return 'gallery'; }
    if (d.link) { return 'link'; }
    var phone = window.components;
    if (phone && typeof phone.uploadMedia === 'function'
        && typeof phone.saveToGallery === 'function') {
      return 'upload';
    }
    return null;
  }

  /* Into the phone's Photos by link: lb-phone's components.saveToGallery
     where the phone gives it to custom apps, otherwise the client's save
     with lb-phone's export, which saves only the link the server handed
     this player for this photo. Settles once the phone has it; an answer
     of false is the phone saying no. */
  function toGallery(handle, url) {
    var phone = window.components;
    if (phone && typeof phone.saveToGallery === 'function') {
      return new Promise(function (resolve) { resolve(phone.saveToGallery(url)); })
        .then(function (id) {
          if (id === false) { throw { err: 'save_unavailable' }; }
          return id;
        });
    }
    // The client's refusal is about this phone, never the photo itself:
    // whatever it says, the photo is still open on the server.
    return post('saveToPhotos', { handle: handle }).then(function (r) {
      if (!r.ok) { throw { err: 'save_unavailable' }; }
      return r;
    });
  }

  /* Whether the link the server serves a photo under actually loads, before
     the phone's Photos is given it.

     lb-phone checks a link's host and nothing else, so a link that leads
     nowhere — a public address without the /<resource> FXServer routes by,
     a proxy that does not pass it on, a certificate the phone refuses — was
     saved all the same: the page said "Saved to your Photos.", the client's
     Photos showed a broken picture, their one chance at the photo was
     spent, and the server kept the file for good behind the saved link.
     Loaded first here, the way the Photos app will load it: a link that
     does not load in time is the phone saying no, and the dialog offers to
     keep the photo in the app instead. The server serves an open photo, so
     this costs one load of a photo the client is looking at anyway.

     Only the host goes in the diagnostics: the name in the link is the
     only thing between the photo and anybody who asks for it. */
  var LINK_CHECK_MS = 8000;

  function linkLoads(url) {
    var Img = window.Image;
    // Nothing to load it with, as in a page opened outside the phone.
    if (typeof Img !== 'function') { return Promise.resolve(); }
    return new Promise(function (resolve, reject) {
      var probe = new Img();
      var over = false;
      function finish(loaded) {
        if (over) { return; }
        over = true;
        clearTimeout(timer);
        probe.onload = probe.onerror = null;
        if (loaded) { return resolve(); }
        Diag.note('refused', t('app.photo_link_did_not_load_from')
          + ((/^https?:\/\/([^\/]+)/.exec(url) || [])[1] || '?'));
        reject({ err: 'save_unavailable' });
      }
      var timer = setTimeout(function () { finish(false); }, LINK_CHECK_MS);
      probe.onload = function () { finish(true); };
      probe.onerror = function () { finish(false); };
      probe.src = url;
    });
  }

  // The data URI the server sent, as the Blob lb-phone's upload takes.
  function blobOf(src) {
    var parts = /^data:([^;,]+);base64,(.*)$/.exec(src);
    if (!parts || typeof window.atob !== 'function' || typeof window.Blob !== 'function') {
      throw { err: 'save_unavailable' };
    }
    var binary = window.atob(parts[2]);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
    return new window.Blob([bytes], { type: parts[1] });
  }

  /* Tell the server what became of the open photo, and close it here.

     Closed whatever the answer: a photo the server has already let go of
     (left open too long) cannot be shown again either way. */
  function decideProof(handle, choice) {
    proofShown = null;
    if (state.dialog && state.dialog.kind === 'proof' && state.dialog.handle === handle) {
      state.dialog = null;
    }
    markProof(handle, choice === 'save' ? 'saved' : choice === 'keep' ? 'kept' : 'deleted');
    render();
    return post('photoDecision', { handle: handle, choice: choice }).then(function (r) {
      if (!r.ok) {
        // Deleting one the server had already let go of is not news.
        if (!(choice === 'delete' && r.err === 'photo_gone')) { fail(r); }
        markProof(handle, 'deleted');
        redraw();
      }
      return r;
    });
  }

  /* Into the phone's own Photos, by whichever route this photo has, then
     tell the server. Only once the phone has it is the server told 'save':
     it lets go of its own copy the moment it hears that, unless the phone
     saved the link the server serves it under.

     Refused anywhere along the way, the photo stays open and nothing is
     reported: the dialog offers to keep it in the app instead. */
  function saveProof(d, route) {
    var saving;
    if (route === 'gallery') {
      saving = toGallery(d.handle, d.src);
    } else if (route === 'link') {
      saving = post('photoDecision', { handle: d.handle, choice: 'link' }).then(function (r) {
        if (!r.ok || !r.data || typeof r.data.link !== 'string') { throw r; }
        var link = r.data.link;
        // Only once it is known to load (linkLoads): a dead link saved is
        // the one look spent on a broken picture.
        return linkLoads(link).then(function () { return toGallery(d.handle, link); });
      });
    } else {
      saving = new Promise(function (resolve) {
        resolve(window.components.uploadMedia(t('app.image'), blobOf(d.src)));
      }).then(function (url) {
        if (typeof url !== 'string' || !url) { throw { err: 'save_unavailable' }; }
        return toGallery(d.handle, url);
      });
    }
    return saving.then(function () {
      return decideProof(d.handle, 'save').then(function (r) {
        if (r.ok) { say(t('app.saved_to_your_photos'), 'ok'); }
      });
    }, function (r) {
      // Left open too long while the phone was busy: it is gone, and
      // there is nothing left to keep.
      if (r && r.err === 'photo_gone') {
        proofShown = null;
        state.dialog = null;
        markProof(d.handle, 'deleted');
        fail(r);
        render();
        return;
      }
      fail({ err: r && r.err === 'photo_no_link' ? 'photo_no_link' : 'save_unavailable' });
      if (state.dialog && state.dialog.kind === 'proof' && state.dialog.handle === d.handle) {
        state.dialog.failed = true;
        render();
      }
    });
  }

  function keepProof(d) {
    return decideProof(d.handle, 'keep').then(function (r) {
      if (r.ok) { say(t('app.kept_in_this_app_open_it'), 'ok'); }
    });
  }

  /* The open photo was closed some way other than its own buttons. That is
     a Delete, and the server is told, rather than the photo being left open
     on the server until it times out. */
  function letGoOfProof() {
    if (!proofShown) { return; }
    var d = state.dialog;
    if (d && d.kind === 'proof' && d.handle === proofShown.handle) { return; }
    var handle = proofShown.handle;
    proofShown = null;
    markProof(handle, 'deleted');
    post('photoDecision', { handle: handle, choice: 'delete' });
  }

  function renderProof(view) {
    var d = state.dialog;
    var route = d.kept || d.failed ? null : saveRoute(d);
    var panel = el('div', 'card dialog photo-view');
    panel.appendChild(el('div', 'target', t('app.proof_of_the_kill')));
    panel.appendChild(el('div', 'reason', d.kept
      ? t('app.kept_for_you_in_this_app')
        + t('app.until_you_delete_it')
      : d.failed
        ? t('app.your_phone_could_not_save_it')
          + t('app.delete_it_it_is_deleted_when')
        : route
          ? t('app.you_can_see_this_once_save')
            + t('app.when_you_close_this')
          : d.photosOff
            ? t('app.you_can_see_this_once_kill')
              + t('app.kept_for_you_in_this_app_2')
              + t('app.close_this')
            : t('app.you_can_see_this_once_your')
              + t('app.in_this_app_tap_save_to')));

    var frame = el('div', 'photo-frame');
    var img = document.createElement('img');
    img.src = d.src;
    img.alt = t('app.verification_photograph');
    frame.appendChild(img);
    panel.appendChild(frame);

    var row = el('div', 'row');
    if (d.kept) {
      row.appendChild(actionButton('ghost is-destructive', t('app.delete'), 'proof-delete:' + d.handle,
        t('app.deleting'), function () { return decideProof(d.handle, 'delete'); }));
      var close = el('button', 'ghost', t('app.close'));
      close.onclick = closeDialog;
      row.appendChild(close);
    } else {
      if (d.failed) {
        row.appendChild(actionButton('primary', t('app.keep_it_in_the_app_instead'),
          'proof-keep:' + d.handle, t('app.keeping'), function () { return keepProof(d); }));
      } else if (route) {
        row.appendChild(actionButton('primary', t('app.save_to_photos'), 'proof-save:' + d.handle,
          t('app.saving'), function () { return saveProof(d, route); }));
      } else {
        row.appendChild(actionButton('primary', t('app.save'), 'proof-keep:' + d.handle,
          t('app.saving'), function () { return keepProof(d); }));
      }
      row.appendChild(actionButton('ghost is-destructive', t('app.delete'), 'proof-delete:' + d.handle,
        t('app.deleting'), function () { return decideProof(d.handle, 'delete'); }));
    }
    panel.appendChild(row);
    view.appendChild(panel);
  }

  function renderChoice(view) {
    var d = state.dialog;
    var panel = el('div', 'card dialog');
    panel.appendChild(el('div', 'target', d.question));
    if (d.detail) panel.appendChild(el('div', 'reason', d.detail));

    // An option that carries a note gets a line of its own, because the note
    // is the part that makes the choice answerable: "Reduce the reward" is
    // not a decision anybody can take without knowing what it pays now.
    var annotated = d.options.some(function (option) { return option.note; });

    var row = el('div', annotated ? 'choices' : 'row');
    d.options.forEach(function (option) {
      var button = el('button', option.primary ? 'primary' : null, option.label);
      button.onclick = function () {
        state.dialog = null;
        render();
        option.run();
      };

      if (option.note) {
        // `has-note` rather than :has(): FiveM's browser may predate it.
        var block = el('div', 'choice has-note');
        block.appendChild(button);
        block.appendChild(el('div', 'hint', option.note));
        row.appendChild(block);
      } else if (annotated) {
        // A row like its neighbours, without the note. Left bare it took the
        // default centred button style, so of two operatives offered side by
        // side, the anonymous one looked like a confirm button and the named
        // one like a different kind of thing altogether.
        var plain = el('div', 'choice');
        plain.appendChild(button);
        row.appendChild(plain);
      } else {
        row.appendChild(button);
      }
    });

    // "Close", not "Cancel": one of the choices this dismisses is "Cancel
    // the contract", and the two sat a thumb apart with the same word.
    var cancel = el('button', 'ghost', t('app.close'));
    cancel.onclick = closeDialog;
    if (annotated) {
      var cancelBlock = el('div', 'choice');
      cancelBlock.appendChild(cancel);
      row.appendChild(cancelBlock);
    } else {
      row.appendChild(cancel);
    }

    panel.appendChild(row);
    view.appendChild(panel);
  }

  /* ---------- target headshots ---------- */

  // Fetches issued by the render now in progress, queued ones included.
  // Every mugshot() call happens inside one synchronous render, so the
  // counter reaches its peak before the first reply arrives and hits zero
  // exactly once — one redraw for a whole page of faces, not one per face.
  var facesInFlight = 0;

  /* Faces are asked for a few at a time. Each one is an event from this
     player to the server, and opening the app asked for a whole board page
     of them in the same instant as the board, Mine and the ledger: eighteen
     at once, against a budget of ten a second per player. Five now, then
     five more each second after, so an open stays at eight. */
  var FACES_PER_BATCH = 5;
  var FACE_BATCH_MS = 1000;
  var faceQueue = [];
  var facesThisBatch = 0;
  var faceBatchTimer = null;

  function fetchFace(id) {
    post('mugshotImage', { id: id }).then(function (r) {
      // A reference that no longer resolves — the target re-rendered, or the
      // entry was dropped. The null stays, so we do not ask again for this
      // reference; the next projection carries a new one.
      if (r.ok && r.data && r.data.image) {
        state.images[r.data.id] = r.data.image;
        keepFewerFaces();
      }
      facesInFlight--;
      // Faces are drawn on the board, Mine and On me, and nowhere else.
      if (facesInFlight === 0) { redrawFor(['board', 'mine', 'onme']); }
    });
  }

  // A batch opens with the first face asked for in it and closes a second
  // later, when whatever queued behind it goes. Nothing queued, no timer.
  function nextFaces() {
    while (faceQueue.length && facesThisBatch < FACES_PER_BATCH) {
      facesThisBatch++;
      fetchFace(faceQueue.shift());
    }
    if (faceBatchTimer === null && facesThisBatch > 0) {
      faceBatchTimer = setTimeout(function () {
        faceBatchTimer = null;
        facesThisBatch = 0;
        nextFaces();
      }, FACE_BATCH_MS);
    }
  }

  /* How many faces are kept. Every new render of a target's face has a new
     reference, and every one ever seen was kept, each up to the server's
     largest headshot: an hour on the board was megabytes more held for as
     long as the app stayed open, and paging a busy board, tens. The least
     recently drawn go first; a face asked for again is fetched again. */
  var FACES_KEPT = 60;

  function keepFewerFaces() {
    var held = Object.keys(state.images);
    var over = held.length - FACES_KEPT;
    for (var i = 0; i < held.length && over > 0; i++) {
      // A null is a fetch in flight, or a reference the server refused,
      // which must not be asked for again.
      if (state.images[held[i]] !== null) {
        delete state.images[held[i]];
        over--;
      }
    }
  }

  // The cached image for a reference, fetching it the first time it is seen.
  // Returns nothing while a fetch is in flight; the card simply renders
  // without a face, which is what it does before the first render anyway.
  function mugshot(id) {
    if (!id) { return null; }
    if (state.images[id] !== undefined) {
      var face = state.images[id];
      // Moved to the newest end, so the faces on screen are the last to go.
      if (face !== null) {
        delete state.images[id];
        state.images[id] = face;
      }
      return face;
    }

    // Marked as in flight before the request goes out, so a page of rows
    // naming the same target asks once rather than once per row.
    state.images[id] = null;
    facesInFlight++;
    faceQueue.push(id);
    nextFaces();
    return null;
  }

  /* Each notice clears itself and nothing newer. The timer used to blank
     whatever was showing when it fired, so a second message raised within
     four seconds of the first vanished half a second after it appeared.

     Up for as long as it takes to read, not a flat four seconds: the
     instructions a hitman gets back from the camera run to thirty-odd words
     and were gone before they were halfway through. A refusal (red) has no
     timer at all — it says what to fix, so it stays until the player's next
     tap — and any notice goes the moment it is tapped.

     `kind` is 'red' for a refusal, 'ok' for a confirmation, and 'caution'
     for the brass shield, which is kept for the warnings the stylesheet
     reserves it for: a sworn officer, a handover under way. Confirmations
     wore it too, so "Contract placed." looked like the law-enforcement
     warning. */
  function say(message, kind) {
    var notice = { message: message, kind: kind || 'red' };
    state.notice = notice;
    renderNotice();
    if (notice.kind === 'red') { return; }
    var length = String(message || '').length;
    setTimeout(function () {
      if (state.notice !== notice) { return; }
      state.notice = null;
      renderNotice();
    }, Math.min(12000, Math.max(4000, 1200 + 55 * length)));
  }

  function dismissNotice() {
    state.notice = null;
    renderNotice();
  }

  // The notice lives outside #view and is mutated in place. Re-rendering the
  // shell to show it would rebuild the Place form from scratch and throw
  // away everything the player had typed — including the target they just
  // picked, since picking one raises a notice.
  function renderNotice() {
    var slot = document.getElementById('notice');
    if (!slot) return;
    slot.innerHTML = '';
    if (!state.notice) { slot.className = ''; return; }
    slot.className = 'notice-slot';
    var kind = state.notice.kind;
    var node = el('div', 'notice' + (kind === 'caution' ? ' gold' : kind === 'ok' ? ' ok' : ''),
      state.notice.message);
    // Dismissed by a tap. It floats over the top of the view and took every
    // tap aimed there — the thread's Back and Call did nothing for as long
    // as it was up. Not pointer-events: none, which would let the tap fall
    // through and press the hidden button the player could not see.
    node.onclick = dismissNotice;
    slot.appendChild(node);
  }

  function fail(result) {
    var text = failText(result);
    if (text) { say(text); }
  }

  // What fail() would say, or null for nothing at all.
  function failText(result) {
    // A null entry means the player did this on purpose; saying anything
    // would read as a failure.
    if (result.err in ERRORS && ERRORS[result.err] === null) return null;

    // A request that can move money, out of time: it may still go through,
    // and "Try again" paid twice. Anything else that timed out moved nothing.
    if (result.err === 'timeout' && MONEY_EVENTS[result.event] === true) {
      return t('app.no_answer_yet_it_may_still');
    }

    // A wait the player can act on. "Slow down" alone reads as a broken
    // button, because tapping again says exactly the same thing.
    if (result.err === 'rate_limited' && result.data && result.data.retryAfter) {
      return t('app.slow_down_try_again') + retryIn(result.data.retryAfter) + '.';
    }

    // A reason refused for what it says, by the rule it broke: a form full
    // of money fields said only "Check what you entered."
    if (result.err === 'reason_refused') { return reasonRefusedText(result.data); }

    // Suspended by staff: until when, and the reason they gave.
    if (result.err === 'suspended') { return suspendedText(result.data); }

    // No burner phone, naming the item this server takes for one.
    if (result.err === 'need_burner') { return burnerText(result.data && result.data.item); }

    // A reward source staff switched off while the form was open, by name.
    if (result.err === 'source_disabled' && result.data && SOURCE_WORDS[result.data.source]) {
      return t('app.this_server_no_longer_takes') + SOURCE_WORDS[result.data.source]
        + t('app.in_a_reward_nothing_was_taken');
    }
    // And the payout ceiling, lowered the same way.
    if (result.err === 'slots_over' && result.data && Number(result.data.max) > 0) {
      var most = Number(result.data.max);
      return most === 1
        ? t('app.this_server_now_takes_one_payout')
        : t('app.this_server_now_takes_at_most') + most + t('app.payouts_per_contract_nothing_was_taken');
    }

    // A message that was not sent for what it says, with the draft kept.
    if (result.err === 'message_refused' && result.data && result.data.empty) {
      return t('app.there_is_nothing_in_that_message');
    }

    // Whose number a call would show, said the right way round: "they are
    // staying anonymous" was said to a named caller whose own number it was.
    if (result.err === 'call_unmasked' && result.data && result.data.anonymous === 'you') {
      return t('app.you_are_staying_anonymous_and_a')
        + t('app.number_send_a_message_instead');
    }

    // Held for seconds: the same request is still being worked on, waiting
    // on the server, and tapping again at once meets it again. Under ten
    // seconds it is the moment the plain words say.
    if (result.err === 'busy' && result.data && Number(result.data.heldMs) >= 10000) {
      return t('app.this_is_still_being_worked_on');
    }

    // How long until a hitman who walked away may take it back.
    if (result.err === 'retake_too_soon' && result.data && Number(result.data.retryAfter) > 0) {
      var back = Math.ceil(Number(result.data.retryAfter) / 60);
      return t('app.you_walked_away_from_this_contract')
        + durationText(back) + t('app.until_then_it_is_open_to');
    }

    // How long until the meeting point may change again: once every half
    // minute, whoever taps.
    if (result.err === 'meeting_too_soon' && result.data && Number(result.data.retryAfter) > 0) {
      return t('app.the_meeting_point_was_changed_a')
        + retryIn(result.data.retryAfter) + '.';
    }

    // How long until a handover may be armed again (Config.Kidnap
    // .RearmCooldownSeconds), and why: one that failed, or a try a moment
    // ago that found the placer too far, when no handover had started.
    if (result.err === 'handover_cooldown' && result.data && Number(result.data.retryAfter) > 0) {
      return (result.data.far ? t('app.handover_far_a_moment_ago') : t('app.handover_failed_a_moment_ago'))
        + retryIn(result.data.retryAfter) + '.';
    }

    // How long until the placer's informant asks again.
    if (result.err === 'informant_cooldown' && result.data && Number(result.data.minutes) > 0) {
      var minutes = Math.ceil(Number(result.data.minutes));
      return tn('app.informant_asks_again_in_minutes', minutes);
    }

    // Worth too little in money: the least is sent with the refusal, and
    // the Place form was opened with it. Said as a figure, because "more
    // than that" leaves the player guessing at a number the server knows.
    if (result.err === 'reward_too_small') {
      var least = Number(result.data && result.data.min)
        || Number(state.wallet && state.wallet.caps && state.wallet.caps.minValue) || 0;
      if (least > 0) { return minRewardText(least); }
      return t('app.a_contract_here_has_to_be') + moneyCounted()
        + t('app.items_and_weapons_do_not_count');
    }

    // The cooling-off after a completed contract
    // (Config.Limits.TargetCooldownAfterCompletionSeconds): how long, in
    // hours, and nothing else.
    if (result.err === 'target_recently_on' && result.data && Number(result.data.hours) > 0) {
      var hours = Math.ceil(Number(result.data.hours));
      return tn('app.cooling_off_hours', hours);
    }
    // Too far from the placer to hand over a proof item, by the server's distance.
    if (result.err === 'proof_too_far' && result.data && Number(result.data.radius) > 0) {
      return t('app.stand_within') + Number(result.data.radius) + t('app.m_of_the_person_who_placed')
        + t('app.contract_to_hand_it_over_nothing');
    }

    // A kill on a contract only a live handover completes: what to do
    // instead, with the server's own distance and hold.
    if (result.err === 'kill_not_allowed') { return aliveOnlyRefusal(); }

    // A buyout charged, then put on hold by staff before it closed the
    // contract: the premium came back, and is said.
    if (result.err === 'contract_frozen' && result.data && result.data.refunded) {
      return t('app.this_contract_is_on_hold_by')
        + t('app.your_payment_was_returned');
    }

    // A fee or a price that moved while it was on screen: the figure now.
    if (result.err === 'terms_changed') {
      var moved = feeMovedText(result.data);
      if (moved) { return moved; }
    }
    // And the rule a contract is placed under, which way it went.
    if (result.err === 'rule_changed' && result.data
        && typeof result.data.fulfilment === 'string') {
      return t('app.this_server_now_places_contracts_differently')
        + (result.data.fulfilment === 'either'
          ? t('app.a_kill_completes_one_as_well')
          : t('app.they_only_pay_when_the_target')
            + t('app.not_complete_one'))
        + t('app.nothing_was_taken_check_the_form');
    }

    return ERRORS[result.err] || t('app.something_went_wrong');
  }

  /* What a charge is now, when a refusal says it moved while it was on
     screen: the anonymity fee on placing or on accepting, or the
     informant's price. Each was charged at whatever the admin panel had
     just set, without ever being shown; now it is refused, and said. */
  function feeMovedText(data) {
    var d = data || {};
    function from(account) { return account === 'cash' ? t('app.your_cash') : t('app.your_bank'); }
    if (typeof d.creatorFee === 'number') {
      return t('app.placing_anonymously_now_costs_from', money(d.creatorFee), from(d.feeAccount));
    }
    if (typeof d.fee === 'number') {
      return t('app.taking_anonymously_now_costs_from', money(d.fee), from(d.feeAccount));
    }
    if (typeof d.cost === 'number') {
      return t('app.informant_now_costs_from', money(d.cost), from(d.account));
    }
    return null;
  }

  /* The least a contract may be worth in money, in the words every place
     that says it uses: the Place form's hint, its own check, and a refusal
     for placing under it or taking a reward back out below it. */
  function minRewardText(least) {
    return t('app.a_contract_here_has_to_be_2') + money(least) + t('app.in_money')
      + moneyCounted() + t('app.items_and_weapons_do_not_count');
  }

  /* What counts as money in a reward. "Across every payout" only where a
     contract can be collected more than once (Config.Limits.MaxPayoutSlots):
     at 1, as shipped, the form says nothing about further collections. */
  function moneyCounted() {
    return moneyTaken() + ' '
      + (slotCeiling() > 1 ? t('app.across_every_payout') : t('app.in_the_reward'));
  }

  /* The money sources this server takes, as words: "cash, bank and dirty
     money", less any switched off (the wallet's caps). The minimum named
     dirty money on a server that had turned it off. All three until the
     wallet has said. */
  function moneyTaken() {
    var caps = (state.wallet && state.wallet.caps) || {};
    var names = [];
    if (caps.cashEnabled !== false) { names.push('cash'); }
    if (caps.bankEnabled !== false) { names.push('bank'); }
    if (caps.dirtyEnabled !== false) { names.push(t('app.dirty_money')); }
    if (!names.length) { return 'money'; }
    return names.length === 1 ? names[0]
      : t('app.list_and', names.slice(0, -1).join(', '), names[names.length - 1]);
  }

  /* ---------- actions already running ----------------------------------

     Not one button in this app had a busy state. Every action was
     post(...).then(...), the screen was identical for the whole round trip,
     and the button stayed live throughout — so the honest reading of a tap
     that appears to do nothing is to tap it again.

     What that cost, by action: a second contract placed and a second escrow
     charged; a second photo token minted, invalidating the one the photo
     already in flight was taken against; two of three photo attempts spent
     before the hitman had seen a single answer; an amendment answered twice,
     the second reply reporting the change that actually applied as "Gone."

     Keyed rather than held on the element, because render() rebuilds the
     DOM: a disabled attribute set here is gone on the next redraw, and a
     redraw is exactly what a reply triggers. The key survives, so a button
     rebuilt mid-flight is rebuilt already disabled. */
  var inFlight = {};

  function isBusy(key) { return inFlight[key] === true; }

  /* Run work once. Returns false if it was already running, so a caller can
     tell "started" from "ignored" — and a tap that is ignored still says
     something, because a button that goes quiet twice is a broken button. */
  function once(key, work) {
    if (inFlight[key]) { return false; }
    inFlight[key] = true;
    redraw();

    function finished(result) {
      delete inFlight[key];
      redraw();
      return result;
    }

    // Both arms: a rejection that left the key set would disable the button
    // for the rest of the session, which is a worse failure than the one
    // this prevents.
    var running = work();
    if (running && typeof running.then === 'function') {
      running.then(finished, function (err) {
        finished();
        Diag.note('throw', 'action ' + key + ': ' + ((err && err.message) || err));
        throw err;
      });
    } else {
      finished();
    }
    return true;
  }

  /* A button wired to `once`. Disabled and relabelled while its work runs,
     so the answer to "did my tap register" is on the button itself.
     `confirm` ({ question, detail, yes, no }) asks first: a write takes two
     taps, the second confirming. */
  function actionButton(className, label, key, busyLabel, work, confirm) {
    var button = el('button', className, isBusy(key) ? (busyLabel || label) : label);
    if (isBusy(key)) {
      button.disabled = true;
      button.classList.toggle('is-busy', true);
      return button;
    }
    button.onclick = confirm
      ? function () {
        ask(confirm.question, confirm.detail, function () { return once(key, work); },
          { yes: confirm.yes, no: confirm.no });
      }
      : function () { once(key, work); };
    return button;
  }

  /* ---------- helpers ---------- */

  function money(n) {
    return '$' + (Number(n) || 0).toLocaleString('en-US');
  }

  /* A list from the server, whatever shape it arrived in.
     
     FiveM msgpack-encodes Lua tables, and an empty Lua table is
     indistinguishable from an empty map — so a server that meant to send an
     empty list sends `{}`, not `[]`. On this side `.length` is then
     undefined, so every "there is nothing here" branch silently fails to
     run, and `.forEach` throws, which takes the whole render with it.
     
     That is an empty target list and an empty item picker with no
     explanation and nothing in any log, which is exactly what it looked
     like. The same conversion recovers a table keyed by something other
     than 1..n — an inventory keyed by slot number, say — which crosses as
     an object for the same reason. */
  function asList(value) {
    if (Array.isArray(value)) { return value; }
    if (value && typeof value === 'object') { return Object.keys(value).map(function (k) { return value[k]; }); }
    return [];
  }

  /* Every control is one of kit.css's components (the design system the
     staff panel shares): a button is a .btn, a field an .input. Made here,
     so no control on the page is drawn without its class. */
  var KIT_CLASS = { button: 'btn', input: 'input', select: 'input', textarea: 'input' };
  function make(tag) {
    var node = document.createElement(tag);
    if (KIT_CLASS[tag]) node.className = KIT_CLASS[tag];
    return node;
  }

  function el(tag, className, text) {
    var node = make(tag);
    if (className) node.className = (KIT_CLASS[tag] ? KIT_CLASS[tag] + ' ' : '') + className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  /* A label on a card. `icon` names one of the line icons app.css draws
     (i-flag, i-users, ...). The stylesheet paints it as a mask before the
     words rather than anything being written into the page, so the chip's
     text — the only thing a screen reader or a test reads — is exactly what
     it was without one. */
  function chip(text, variant, icon) {
    // A caution is a pill (kit.css .chip.is-warn); every other is a label.
    return el('span', 'chip' + (variant === 'is-warn' ? '' : ' is-label') + (variant ? ' ' + variant : '')
      + (icon ? ' ico ' + icon : ''), text);
  }

  /* Up to two initials for a monogram: the first letter of the first and
     the last word that begins with a letter, so "Dana Reyes 2" is DR rather
     than D2. A letter is anything with a case — cheaper than a Unicode
     table and right for every Latin, Greek and Cyrillic name — and a name
     with none at all falls back to its first character, so the seal is
     never empty. */
  function initials(name) {
    var text = String(name || '').trim();
    function lettered(word) {
      var first = word.charAt(0);
      return first.toLowerCase() !== first.toUpperCase();
    }
    var words = text.split(/\s+/).filter(lettered);
    if (!words.length) { return Array.from(text)[0] || '?'; }
    var out = words[0].charAt(0);
    if (words.length > 1) { out += words[words.length - 1].charAt(0); }
    return out.toUpperCase();
  }

  /* The face on a file.

     A card could show a mugshot when the server sent one and otherwise
     showed nothing, so most entries on the board had no face at all and
     the ones that did looked like a different kind of card. Every entry has
     the same slot now: the mugshot when there is one, a monogram struck
     from the name when there is not. The initials live in a data attribute
     and the stylesheet draws them, so they add nothing to the card's text —
     the name is still said once, where it always was. */
  function portrait(name, face) {
    var slot = el('div', 'portrait');
    slot.setAttribute('aria-hidden', 'true');
    if (face) {
      var shot = document.createElement('img');
      shot.className = 'mugshot';
      shot.src = face;
      shot.alt = '';
      slot.appendChild(shot);
    } else {
      slot.className = 'portrait is-monogram';
      slot.dataset.initials = initials(name);
    }
    return slot;
  }

  /* A count over the word it counts: "7 completed", set as a large 7 with
     "completed" beneath it. Two spans, and the second keeps its leading
     space, so read as text it is still exactly "7 completed". */
  function tally(value, label) {
    var cell = el('div', 'stat');
    // Grouped like every money figure: "1234 completed" was the one count
    // on the page set without a separator.
    cell.appendChild(el('span', 'stat-value',
      typeof value === 'number' ? value.toLocaleString('en-US') : value));
    cell.appendChild(el('span', 'stat-label', ' ' + label));
    return cell;
  }

  /* A balance under its caption: "Cash $100,000", the other way up. */
  function balance(label, amount) {
    var cell = el('div', 'stat is-balance');
    cell.appendChild(el('span', 'stat-label', label));
    cell.appendChild(el('span', 'stat-value', ' ' + amount));
    return cell;
  }

  /* One sheet of the Place form, under its heading. The number in front of
     the heading is a CSS counter, not text. */
  function formSection(title) {
    var section = el('section', 'form-section');
    section.appendChild(el('h3', 'form-head', title));
    return section;
  }

  /* ---------- contract card ---------- */

  function card(contract, context) {
    // Marked as a protected target only where the server flags the listing
    // (Advisory.FlagListing): off, the chip went and the gold notice and the
    // styling stayed, so the switch did half of what it says.
    var flagged = contract.targetProtected && settings().flagListing !== false;
    var node = el('div', 'card' + (flagged ? ' is-protected' : ''));

    /* A name with a word too long to share a line with the stamp — a
       double-barrelled surname, a handle with no spaces in it — gets the
       line to itself, and the stamp drops beneath it. Squeezed in beside
       the price it broke every few letters, which reads as a rendering
       fault on the one line of the card that says who this is about. */
    var longestWord = String(contract.targetName || '').split(/\s+/)
      .reduce(function (most, word) { return Math.max(most, word.length); }, 0);
    var head = el('div', 'card-head');
    if (longestWord > 12) { head.className = 'card-head is-stacked'; }
    var left = el('div', 'card-identity');

    left.appendChild(portrait(contract.targetName, mugshot(contract.targetImageId)));

    var who = el('div', 'identity');
    who.appendChild(el('div', 'target', contract.targetName));
    // Staff replaced what a player wrote here (the admin panel's Edit text):
    // the words, then a small mark after them.
    var reasonLine = el('div', 'reason', contract.staffEdited ? null : (contract.reason || '—'));
    if (contract.staffEdited) {
      reasonLine.appendChild(el('span', null, contract.reason || '—'));
      reasonLine.appendChild(el('span', 'edited-mark', t('app.edited_by_staff')));
    }
    who.appendChild(reasonLine);
    left.appendChild(who);
    head.appendChild(left);

    // One row that lost its reward costs that row, not the tab. render()
    // clears the view before it draws, so a throw in here leaves the whole
    // board — or Mine, or On me, card() draws all three — blank, taking
    // every good row after this one with it.
    var paid = contract.reward || {};

    var reward = el('div', 'reward');
    // Goods are not priced — nobody can defend a number for a kitted rifle —
    // so a contract paying them and no money at all was stamped "$0" in the
    // loudest type on the card, with what it actually pays in small print
    // under it, and read as worthless or broken. The stamp says what kind
    // of payout it is instead, and the goods note below still lists it.
    var stamp = money(paid.baseline);
    var g = paid.goods || {};
    if (!(Number(paid.baseline) > 0) && (Number(g.items) || 0) + (Number(g.weapons) || 0) > 0) {
      stamp = Number(g.weapons) > 0 ? t('app.weapons') : t('app.goods');
    }
    reward.appendChild(el('div', 'amount' + (stamp.charAt(0) === '$' ? '' : ' is-goods'), stamp));
    // A contract that pays only for a live delivery pays all of it for one,
    // so nothing on it is "if alive": the server places it with no bonus,
    // and one it somehow held would be paid on the same delivery as the
    // rest. The card says the rule once, as a chip, instead.
    var ifAlive = aliveOnly(contract) ? '' : t('app.if_alive');
    if (paid.bonus > 0) {
      // "If alive", not "alive": "+$75,000 alive" read as a figure with a
      // stray word after it. Not "if delivered alive", which is too long to
      // sit under the stamp at 390px without pushing the target's name down.
      reward.appendChild(el('div', 'bonus', '+' + money(paid.bonus) + ifAlive));
    }

    // What the headline figure does not say goes on a line of its own under
    // the head, not in the stamp's column. In the column, the longest item
    // list set the column's width, and the target's name was squeezed to a
    // few letters a line — on exactly the contracts that pay the most.
    var notes = el('div', 'reward-notes');

    // What the reward is paid for, first under it, on the board where a
    // hitman decides. The chip below says "Alive only"; this says to whom,
    // which the chip cannot, and which is the half nobody guessed.
    if (context === 'board' && aliveOnly(contract)) {
      notes.appendChild(el('div', 'hint ico i-usercheck',
        t('app.bring_the_target_alive_to_the')));
    }

    // How much of that is dirty money, when any of it is. "Dirty money",
    // the Place form's and the wallet's word for it: this note said "black
    // money", so one currency went by two names a screen apart.
    //
    // The headline is one figure covering all three money sources, and they
    // are not worth the same: dirty money sells for a fraction of its face
    // value. A hitman looking at "$250,000" could be looking at a quarter of
    // a million black_money items with no way to tell.
    //
    // Each portion on its own. The base's and the bonus's black money were
    // added together and set under the base figure as "of it", so a
    // $150,000 base with $50,000 of black money, plus a bonus holding
    // $25,000 more, read as half the headline. A kill pays the base alone.
    var dirtyBase = Number(paid.sources && paid.sources.dirty) || 0;
    var dirtyBonus = Number(paid.bonusSources && paid.bonusSources.dirty) || 0;
    var dirtyText = dirtyBase > 0 && dirtyBonus > 0
      ? money(dirtyBase) + t('app.of_this_is_dirty_money_and') + money(dirtyBonus)
        + t('app.of_the_kidnapping_bonus')
      : dirtyBase > 0 ? money(dirtyBase) + t('app.of_this_is_dirty_money')
      : dirtyBonus > 0 ? money(dirtyBonus) + t('app.of_the_kidnapping_bonus_is_dirty')
      : null;
    if (dirtyText) { notes.appendChild(el('div', 'hint ico i-coin', dirtyText)); }

    // The names of the goods, which the stamp above only gives the kind of.
    var goods = goodsLine(paid.goods);
    if (goods) { notes.appendChild(el('div', 'goods ico i-box', goods)); }
    var bonusGoods = goodsLine(paid.bonusGoods);
    if (bonusGoods) { notes.appendChild(el('div', 'goods ico i-box', '+ ' + bonusGoods + ifAlive)); }
    head.appendChild(reward);
    node.appendChild(head);
    if (notes.children.length) { node.appendChild(notes); }

    var meta = el('div', 'meta');
    var mine = contract.role === 'creator';
    var collected = Number(contract.slotsClaimed) || 0;

    // Against the cap on a competitive contract, so a hitman can see
    // whether there is room before they tap Accept and are refused. The
    // server has always sent hitmenMax and the page never read it.
    function crowdChip() {
      var crowd = contract.mode === 'competitive' && contract.hitmenMax
        ? t('app.operatives_of', contract.hitmenActive, contract.hitmenMax)
        : tn('app.operatives', contract.hitmenActive);
      var full = contract.mode === 'competitive'
        && contract.hitmenMax
        && contract.hitmenActive >= contract.hitmenMax;
      return chip(full ? crowd + t('app.full') : crowd, full ? 'is-warn' : 'hot', 'i-users');
    }

    // What a client opens Mine to find out, first: is anyone on it. An
    // untaken contract showed its mode and the client's own name and
    // nothing else, so "nobody has taken it" had to be read from an
    // absence.
    if (mine) {
      meta.appendChild(contract.hitmenActive > 0 ? crowdChip()
        : chip((collected > 0 ? t('app.open_again') : t('app.open')) + t('app.no_hitman_yet'), null, 'i-users'));
    }

    // How long is left, on every card. It was only ever said inside a
    // dialog, so a staked hitman could not see when their stake would go,
    // a client when their contract would lapse, or a target how long they
    // had to stay alive.
    var clock = clockChip(contract);
    if (clock) { meta.appendChild(clock); }

    // Staff have put it on hold. Said once: the clock chip reads "On hold ·
    // <band>", or, on a card with no clock, a chip of its own; the note
    // under the card says what it means for them. The same for every party,
    // never which of them or why. Chip, clock and note said it three times.
    if (contract.onHold && !clock) {
      meta.appendChild(chip(t('app.on_hold'), 'is-warn', 'i-lock'));
    }

    meta.appendChild(chip(contract.mode === 'competitive' ? t('app.competitive') : t('app.exclusive'),
      null, contract.mode === 'competitive' ? 'i-flag' : 'i-lock'));

    // How it can be finished, beside how it is shared: a term of the
    // contract every party is shown, the target too. Only where a kill does
    // not pay. A card without it is finished either way, as every card was.
    if (aliveOnly(contract)) {
      meta.appendChild(chip(t('app.alive_only'), null, 'i-usercheck'));
    }

    // "Payout", the Place form's word for it. "Slot 1 of 3" told the
    // client nothing about how many had been collected.
    if (contract.slots > 1) {
      meta.appendChild(chip(mine
        ? t('app.payouts_collected_of', collected, contract.slots)
        : t('app.payout_of', contract.currentSlot, contract.slots), 'slots', 'i-layers'));
    }

    if (contract.role === 'hitman') {
      // Who they are on it, in place of a count that included them: a red
      // "1 operative" on their own card read as a rival, and nothing said
      // whether they had taken it anonymously or what alias the client sees.
      // The cap is left off — it only matters before accepting.
      // "Under your name", the accept dialog's own words for it: "client
      // sees your name" named a client nobody had been introduced to.
      meta.appendChild(chip(t('app.you') + (contract.myAlias ? ': ' + contract.myAlias : '')
        + (contract.myAnonymous ? t('app.anonymous') : t('app.under_your_name')),
        null, 'i-user'));
      var rivals = (Number(contract.hitmenActive) || 0) - 1;
      if (rivals > 0) {
        meta.appendChild(chip(tn('app.rivals_count', rivals), 'hot', 'i-users'));
      }
    } else if (!mine && contract.hitmenActive > 0) {
      meta.appendChild(crowdChip());
    }
    if (contract.role === 'creator') {
      // Through asList, like every other list from the server. The projection
      // builds this as a Lua table, and an empty Lua table crosses as {} —
      // which is truthy, so a plain `&& contract.hitmen` guard passed and
      // .forEach then threw. That is a contract nobody has taken yet: the
      // state every contract is in the moment it is placed, and it took the
      // whole Mine tab down with it.
      // An operative who took it under their name is named, as the target
      // chip names them: "Operative #1: Rook Ash". The alias alone left the
      // client to guess which of their named operatives was which.
      asList(contract.hitmen).forEach(function (h) {
        if (!h || (!h.record && !h.name)) { return; }
        var label = (h.alias || t('app.an_operative')) + (h.name ? ': ' + h.name : '');
        meta.appendChild(chip(h.record ? label + ' · ' + h.record.standing : label,
          null, 'i-user'));
      });
    } else if (contract.role === 'target') {
      // The operatives on it who took it under their name, where the server
      // shows those to the target (Config.TargetClasses.default.ShowOperativeNames). One
      // who took it anonymously is never listed, and stays an alias.
      asList(contract.operatives).forEach(function (o) {
        if (o && o.name) {
          meta.appendChild(chip((o.alias || t('app.an_operative')) + ': ' + o.name, 'hot', 'i-user'));
        }
      });
    }
    // What accepting costs, on the listing, before the accept button —
    // §14.18. The server used to send this to the creator alone while
    // acceptance debited it anyway, so the first a hitman knew of a stake
    // was the money leaving their bank.
    if (contract.penaltyAmount > 0) {
      meta.appendChild(chip(t('app.amount_stake', money(contract.penaltyAmount)), 'is-warn', 'i-coin'));
    }
    // The buyout as the server set it, on the client's own card. The server
    // moves a price outside what the reward allows to the nearest limit, and
    // the target was the only one shown the result: a client who meant to
    // let them off cheaply had no way to see that they had not.
    if (mine && settings().buyouts !== false) {
      var buyout = Number(contract.bailoutAmount) || 0;
      meta.appendChild(chip(buyout > 0 ? t('app.buyout_amount', money(buyout)) : t('app.no_buyout'), null, 'i-exit'));
    }
    // Only when there is something to say: a row carrying neither drew an
    // empty pill. On the client's own card their own name is noise, but
    // whether they placed it anonymously is the one confirmation they get
    // of that choice.
    if (mine) {
      meta.appendChild(chip(contract.creatorAnonymous ? t('app.placed_anonymously')
        : t('app.placed_under_your_name'), null, 'i-briefcase'));
    } else if (contract.creatorAnonymous || contract.creatorName) {
      // Who placed it, said as that: "Anonymous client", or a bare name
      // beside the target's, left a hitman to guess who either one was.
      meta.appendChild(chip(contract.creatorAnonymous ? t('app.placed_anonymously')
        : t('app.placed_by') + contract.creatorName, null, 'i-briefcase'));
    }
    if (flagged) {
      meta.appendChild(chip(protectedWords(contract.targetProtectedAs).chip, 'is-warn', 'i-shield'));
    }
    // The placer's record (Config.Record.PlacerRecord): counts, never who.
    if (contract.placerRecord) {
      meta.appendChild(chip(placerRecordText(contract.placerRecord), null, 'i-briefcase'));
    }
    node.appendChild(meta);

    // On hold by staff: plain, and nothing about which party or why. What
    // still works is said, and only that is drawn (actionsFor).
    if (contract.onHold) {
      node.appendChild(el('div', 'notice hold', t('app.this_contract_is_on_hold_by_2')
        + (context === 'board' ? '' : t('app.you_can_still_message_and_report'))));
    }

    // A payout of theirs held for proof of intent: what is still missing.
    if (contract.intentHold) {
      node.appendChild(el('div', 'notice gold intent-hold',
        intentHoldText(contract.intentHold, t('app.your_payout_here_is_held'), true)));
    } else if (contract.intentRule && Number(contract.intentRule.messages) > 0) {
      // The rule while it can still be met, before a payout is held by it.
      var times = Number(contract.intentRule.messages);
      node.appendChild(el('div', 'hint intent-rule ico i-message',
        tn('app.payouts_held_unless_messaged', times)));
    }

    // What this player's informant found out, kept by the server with the
    // purchase: the target's on their On me card, the placer's on Mine.
    informantFound(node, contract.informantFound);
    informantFound(node, contract.placerInformantFound);

    // What accepting it does, under the switches now. "Their department has
    // been advised" read today's switch, not whether a bulletin went for
    // this contract, and was said of medics and lawyers, whose departments
    // nobody tells.
    if (flagged && context === 'board') {
      node.appendChild(el('div', 'notice gold', t('app.this_target')
        + protectedWords(contract.targetProtectedAs).is + '.'
        + (advised('accepted') ? t('app.accepting_it_alerts_every_officer_in') : '')));
    }

    // A member of the hitman organisation is told its cut of their payout on
    // every card before they accept (the board's orgTerms, theirs alone),
    // and the acceptance sends the same figure back (acceptContract).
    var orgTerms = context === 'board' ? orgTermsNow() : null;
    if (orgTerms) {
      node.appendChild(el('div', 'hint org-cut ico i-briefcase', orgCutText(orgTerms)));
    }

    // The placer's half of a live handover, on their own card once it is
    // taken: the hitman comes to them, so they have to be in the city to be
    // met. The phone notice that it was taken says the same (Notify
    // .contractAccepted); this is where it stays.
    if (mine && context !== 'board' && aliveOnly(contract)
        && Number(contract.hitmenActive) > 0) {
      node.appendChild(el('div', 'notice ok', placerTakenText()));
    }

    // A handover running on it: the placer has to stand still for it, and
    // the hitman's countdown was the only one drawn (Projection:
    // handoverLeft, roughly how long, never who).
    if (mine && context !== 'board' && Number(contract.handoverLeft) > 0) {
      node.appendChild(placerHandover(contract));
    }

    // Held long enough, and waiting on this placer's word (Config.Kidnap
    // .PlacerConfirms): Confirm handover and Decline, two taps each
    // (Projection: handoverConfirm, roughly how long is left; never who).
    if (mine && context !== 'board' && Number(contract.handoverConfirm) > 0) {
      node.appendChild(placerConfirm(contract));
    }

    // Where to meet for the handover, on the same card. The server sends
    // meetingSet only while one can be set here: an alive-only contract a
    // hitman holds, on a server running the feature (Config.Kidnap
    // .MeetingPoint). Absent, no controls.
    if (mine && context !== 'board' && typeof contract.meetingSet === 'boolean') {
      node.appendChild(placerMeeting(contract));
    }

    node.appendChild(actionsFor(contract, context));
    // Only on the player's own cards: a dispute is about a contract they
    // are in, and the board is a listing, not a case file.
    if (context === 'mine' || context === 'onme') { appendRef(node, contract.id); }
    return node;
  }

  /* ---------- the handover's meeting point ----------
     server/meeting.lua. The point is where the placer stands when they tap,
     read by their own game (client/main.lua) and never by this page; Set
     GPS has the hitman's game mark it, and this page never holds it. */

  /* The placer's half, on their own card. What it shows the hitman is a
     place, so the words say so before they tap: where they are standing,
     and, placed anonymously, not who they are. */
  function placerMeeting(contract) {
    var box = el('div', 'meeting');
    var set = contract.meetingSet === true;
    box.appendChild(el('div', 'meeting-state ico i-pin', set
      ? t('app.meeting_point_set_the_hitman_can')
      : t('app.no_meeting_point_set')));
    box.appendChild(el('div', 'hint', t('app.set_meeting_point_here_shows_the')
      + t('app.contract_the_spot_where_you_are')
      + (contract.creatorAnonymous ? t('app.not_who_you_are') : '.')));
    if (set) { appendMeetingSteps(box, contract); }
    var row = el('div', 'row meeting-actions');
    var key = 'meeting:' + contract.id;
    if (isBusy(key)) {
      row.appendChild(actionButton('ghost ico i-pin', t('app.set_meeting_point_here'), key, t('app.setting')));
    } else {
      var here = el('button', 'ghost ico i-pin', t('app.set_meeting_point_here'));
      here.onclick = function () { setMeetingHere(contract); };
      row.appendChild(here);
    }
    if (set) {
      // Asked first, as Set is: the spot goes from every hitman's GPS.
      row.appendChild(actionButton('ghost ico i-xcircle', t('app.clear'), 'meetingClear:' + contract.id,
        t('app.clearing'), function () { return clearMeeting(contract); },
        { question: t('app.clear_the_meeting_point'),
          detail: t('app.every_hitman_on_this_contract_loses'),
          yes: t('app.clear_it'), no: t('app.keep_it') }));
    }
    box.appendChild(row);
    return box;
  }

  /* Asked first: the spot goes to every hitman on the contract. */
  function setMeetingHere(contract) {
    ask(t('app.set_the_meeting_point_where_you'),
      t('app.every_hitman_on_this_contract_will')
        + (contract.creatorAnonymous ? t('app.but_not_who_you_are') : '')
        + t('app.stand_where_you_want_to_meet'),
      function () {
        once('meeting:' + contract.id, function () {
          return post('setMeeting', { id: contract.id }).then(function (r) {
            if (!r.ok) { return fail(r); }
            say(r.data && r.data.moved ? t('app.meeting_point_moved_to_where_you')
              : t('app.meeting_point_set_where_you_are'), 'ok');
            refresh();
          });
        });
      }, { yes: t('app.set'), no: t('app.not_now') });
  }

  function clearMeeting(contract) {
    return post('clearMeeting', { id: contract.id }).then(function (r) {
      if (!r.ok) {
        fail(r);
        if (r.err === 'no_meeting') { refresh(); }
        return;
      }
      say(t('app.meeting_point_cleared'), 'ok');
      refresh();
    });
  }

  /* What to do at the meeting point, as the server worded it when it was
     set (Meeting.steps): the same words the phone notice carried, for this
     side of the handover. Absent from an older server: nothing drawn. */
  function appendMeetingSteps(box, contract) {
    if (typeof contract.meetingSteps !== 'string' || !contract.meetingSteps) { return; }
    box.appendChild(el('div', 'hint meeting-steps', t('app.what_to_do') + contract.meetingSteps));
  }

  /* The hitman's half: that one is set, what to do, and Set GPS. */
  function hitmanMeeting(contract) {
    var box = el('div', 'meeting');
    box.appendChild(el('div', 'meeting-state ico i-pin', t('app.meeting_point_set')));
    appendMeetingSteps(box, contract);
    var row = el('div', 'row meeting-actions');
    row.appendChild(actionButton('ghost ico i-pin', t('app.set_gps'), 'gps:' + contract.id,
      t('app.setting_gps'), function () {
        return post('gps', { kind: 'meeting', id: contract.id }).then(function (r) {
          if (!r.ok) {
            fail(r);
            // Cleared, or taken off, since the card was drawn.
            if (r.err === 'no_meeting' || r.err === 'not_found') { refresh(); }
            return;
          }
          say(t('app.the_meeting_point_is_marked_on'), 'ok');
        });
      }));
    box.appendChild(row);
    return box;
  }

  /* ---------- the informant tip (server/intel/tip.lua) ----------
     A hitman holding a contract buys the rough area its target was in when
     they bought it: a red circle on their map, never the place itself. The
     button is tapped twice within three seconds, as staff's money buttons
     are, so a stray tap never pays. While a tip is on the map the card says
     until when and offers Set GPS, which their game sets on the middle of
     the area (client/main.lua): the page is never sent where it is. Where
     one cannot be bought the button stays, disabled, with the reason. */
  var TIP_CONFIRM_MS = 3000;
  var tipArmed = null;   // { id, timer }: the tip button waiting for its second tap

  function disarmTip() {
    if (!tipArmed) { return; }
    clearTimeout(tipArmed.timer);
    tipArmed = null;
    redraw();
  }

  function armTip(id) {
    if (tipArmed) { clearTimeout(tipArmed.timer); }
    var armed = { id: id };
    armed.timer = setTimeout(function () {
      if (tipArmed === armed) { tipArmed = null; redraw(); }
    }, TIP_CONFIRM_MS);
    tipArmed = armed;
    redraw();
  }

  /* "21:07", the time of day this many seconds after the reading. */
  function clockAt(seconds, readAt) {
    var at = new Date((readAt || Date.now()) + Math.max(0, Number(seconds) || 0) * 1000);
    function two(n) { return (n < 10 ? '0' : '') + n; }
    return two(at.getHours()) + ':' + two(at.getMinutes());
  }

  /* How far across the area is, in metres: twice the radius. */
  function tipAcross(rules) {
    return Math.round((Number(rules && rules.radius) || 0) * 2);
  }

  /* Why a tip cannot be bought now, in a sentence, or null when it can. */
  function tipBlocked(rules, own, contract) {
    if (rules.enabled !== true) { return t('app.informant_tips_are_turned_off_on'); }
    // Informant fairness (Config.Improvements), off as shipped: held too
    // briefly, or their one tip on it had.
    if (own && Number(own.holdSeconds) > 0) {
      var held = secondsLeftOf({ secondsLeft: own.holdSeconds, clockReadAt: contract.clockReadAt });
      if (held > 0) {
        return t('app.your_informant_will_talk_once_you')
          + clockAt(held) + '.';
      }
    }
    if (own && own.mineUsed === true) { return t('app.you_have_had_your_one_informant'); }
    if (own && Number(own.left) <= 0) {
      return t('app.the_most_informant_tips_allowed_on')
        + (Number(rules.maxPerContract) || 0) + ').';
    }
    if (own && Number(own.cooldownSeconds) > 0) {
      var wait = secondsLeftOf({ secondsLeft: own.cooldownSeconds,
        clockReadAt: contract.clockReadAt });
      if (wait > 0) {
        return t('app.you_can_buy_another_tip_at') + clockAt(wait) + '.';
      }
    }
    if (own && own.targetAway) {
      return t('app.the_target_is_not_in_the');
    }
    return null;
  }

  function tipLabel(rules) {
    return Number(rules.cost) > 0
      ? t('app.buy_informant_tip') + money(rules.cost) : t('app.get_informant_tip_free');
  }

  /* What the tip is, said beside the button before anything is paid. */
  function tipTerms(rules) {
    return t('app.you_get_the_rough_area_the')
      + tipAcross(rules).toLocaleString('en-US') + t('app.m_across_on_your_map_for')
      + durationText(Number(rules.showMinutes) || 0) + t('app.you_still_have_to_search_it')
      + (rules.tellsTarget !== false
        ? t('app.the_target_will_be_told_someone') : '');
  }

  function hitmanTip(contract) {
    var rules = settings().locationTip;
    if (!rules) { return null; }
    var own = contract.locationTip || null;
    // The next tip's own price on this contract, where it differs from the
    // board's (Config.Intel.TipLimits): quoted, and echoed back.
    if (own && typeof own.cost === 'number') {
      rules = Object.assign({}, rules, { cost: own.cost });
    }
    var box = el('div', 'tip');
    box.id = 'tip-' + contract.id;

    var showing = own && Number(own.secondsLeft) > 0
      ? secondsLeftOf({ secondsLeft: own.secondsLeft, clockReadAt: contract.clockReadAt }) : 0;
    if (showing > 0) {
      box.appendChild(el('div', 'tip-state ico i-pin', t('app.informant_tip_on_your_map_until')
        + clockAt(showing) + '.'));
      box.appendChild(el('div', 'hint', t('app.the_target_was_somewhere_in_the')
        + t('app.bought_it_it_does_not_follow')));
      var gps = el('div', 'row tip-actions');
      gps.appendChild(actionButton('ghost ico i-pin', t('app.set_gps'), 'tipgps:' + contract.id,
        t('app.setting_gps'), function () {
          return post('gps', { kind: 'tip', id: contract.id }).then(function (r) {
            if (!r.ok) {
              fail(r);
              if (r.err === 'no_tip') { refresh(); }
              return;
            }
            say(t('app.the_middle_of_the_area_is'), 'ok');
          });
        }));
      box.appendChild(gps);
    }

    // Turned off by the server (Config.Intel.LocationTip.Enabled, or every
    // informant feature with Config.Intel.Enabled): no button at all. A
    // tip already bought stays on the map until it runs out, and says so.
    // Off for this contract alone (a target on a whitelisted job reads its
    // own switch, Config.TargetClasses.whitelisted.LocationTip): the same.
    if (rules.enabled !== true || (own && own.off === true)) { return showing > 0 ? box : null; }

    var blocked = tipBlocked(rules, own, contract);
    var key = 'tip:' + contract.id;
    var buy;
    if (blocked) {
      buy = el('button', 'ghost ico i-search', tipLabel(rules));
      buy.disabled = true;
    } else if (isBusy(key)) {
      buy = actionButton('ghost ico i-search', tipLabel(rules), key, t('app.buying'));
    } else {
      var armed = tipArmed && tipArmed.id === contract.id;
      buy = el('button', 'ghost ico i-search' + (armed ? ' is-armed' : ''),
        armed ? (Number(rules.cost) > 0 ? t('app.tap_again_to_pay') + money(rules.cost)
          : t('app.tap_again_to_get_it')) : tipLabel(rules));
      buy.onclick = function () {
        if (tipArmed && tipArmed.id === contract.id) {
          disarmTip();
          buyTip(contract, rules);
          return;
        }
        armTip(contract.id);
      };
    }
    buy.id = 'tip-buy-' + contract.id;
    var row = el('div', 'row tip-actions');
    row.appendChild(buy);
    box.appendChild(row);
    box.appendChild(el('div', 'hint' + (blocked ? ' is-refusal' : ''), blocked || tipTerms(rules)));
    return box;
  }

  /* A refusal of a tip, in words about the tip: every one charged nothing. */
  function tipRefusal(r) {
    var d = r.data || {};
    function from(account) { return account === 'cash' ? t('app.your_cash') : t('app.your_bank'); }
    if (r.err === 'terms_changed' && typeof d.cost === 'number') {
      return t('app.informant_tip_now_costs_from', money(d.cost), from(d.account));
    }
    if (r.err === 'tip_cooldown' && Number(d.retryAfter) > 0) {
      return t('app.a_tip_on_this_contract_was')
        + clockAt(d.retryAfter) + t('app.nothing_was_taken');
    }
    if (r.err === 'limit_reached' && d.perHitman) {
      return t('app.you_have_had_your_one_informant_2');
    }
    if (r.err === 'limit_reached') {
      return t('app.the_most_informant_tips_allowed_on_2')
        + t('app.bought_nothing_was_taken');
    }
    if (r.err === 'tip_hold' && Number(d.retryAfter) > 0) {
      return t('app.your_informant_will_not_talk_yet')
        + clockAt(d.retryAfter) + t('app.nothing_was_taken');
    }
    if (r.err === 'tip_cant_place') {
      return t('app.your_informant_cant_place_them_right');
    }
    if (r.err === 'tip_not_found') {
      return d.refunded === false
        ? t('app.your_informant_couldnt_find_them_your')
        : t('app.your_informant_couldnt_find_them_your_2');
    }
    if (r.err === 'insufficient_funds' && typeof d.cost === 'number') {
      return t('app.cannot_afford_the_tip_from', money(d.cost), from(d.account));
    }
    if (r.err === 'already_settled') {
      return t('app.this_contract_has_ended_so_there');
    }
    if (r.err === 'not_participant') {
      return t('app.you_are_no_longer_on_this');
    }
    if (r.err === 'feature_off') { return t('app.informant_tips_are_turned_off_on'); }
    return failText(r);
  }

  function buyTip(contract, rules) {
    var shown = { cost: Number(rules.cost) || 0, account: rules.account };
    once('tip:' + contract.id, function () {
      return post('locationTip', { id: contract.id, shown: shown }).then(function (r) {
        if (!r.ok) {
          var text = tipRefusal(r);
          if (text) { say(text); }
          if (r.err !== 'busy' && r.err !== 'rate_limited' && r.err !== 'timeout') { refresh(); }
          return;
        }
        say(t('app.informant_tip_bought_the_rough_area')
          + t('app.in_the_red_circle_set_gps'), 'ok');
        refresh();
      });
    });
  }

  /* The target's side: when somebody was tipped off about their rough area,
     on On me and on the whitelisted-job view alike. Never who, never where. */
  function tipToldNotice(at) {
    var box = el('div', 'tip-told');
    box.appendChild(el('div', 'tip-state ico i-eye', t('app.someone_has_been_tipped_off_about')
      + t('app.rough_location_they_know_the_area')));
    var when = agoText(at);
    if (when) {
      box.appendChild(el('div', 'hint', t('app.tipped_off') + when.charAt(0).toLowerCase()
        + when.slice(1) + '.'));
    }
    return box;
  }

  /* Going dark (Config.Intel.GoDark): a target told of a tip pays so
     that tips on them find nothing for a while. Two taps, the price echoed;
     or until when they are dark. */
  var darkArmed = null;   // the contract id whose Go dark waits for its second tap
  function goDarkBox(contract) {
    var terms = contract.goDark || {};
    var box = el('div', 'tip-told');
    box.id = 'dark-' + contract.id;
    if (Number(terms.untilAt) > 0) {
      var left = Math.max(0, Number(terms.untilAt) - Math.floor(Date.now() / 1000));
      box.appendChild(el('div', 'tip-state ico i-eye', t('app.you_have_gone_dark_until')
        + clockAt(left) + t('app.tips_bought_on_you_meanwhile_find')));
      return box;
    }
    var cost = Number(terms.cost) || 0;
    var account = terms.account === 'cash' ? 'cash' : 'bank';
    var key = 'dark:' + contract.id;
    var armed = darkArmed === contract.id;
    var label = cost > 0 ? t('app.go_dark') + money(cost) : t('app.go_dark_free');
    var buy;
    if (isBusy(key)) {
      buy = actionButton('ghost ico i-eye', label, key, t('app.going_dark'));
    } else {
      buy = el('button', 'ghost ico i-eye' + (armed ? ' is-armed' : ''),
        armed ? (cost > 0 ? t('app.tap_again_to_pay') + money(cost) : t('app.tap_again_to_go_dark')) : label);
      buy.onclick = function () {
        if (darkArmed !== contract.id) {
          darkArmed = contract.id;
          setTimeout(function () {
            if (darkArmed === contract.id) { darkArmed = null; redraw(); }
          }, TIP_CONFIRM_MS);
          return redraw();
        }
        darkArmed = null;
        once(key, function () {
          return post('goDark', { id: contract.id, shown: { cost: cost, account: account } })
            .then(function (r) {
              if (!r.ok) {
                var d = r.data || {};
                if (r.err === 'terms_changed' && typeof d.cost === 'number') {
                  say(t('app.going_dark_now_costs') + money(d.cost) + t('app.nothing_was_taken'));
                } else if (r.err === 'insufficient_funds') {
                  say(t('app.you_cannot_afford_to_go_dark'));
                } else { fail(r); }
                return refresh();
              }
              say(t('app.you_have_gone_dark_tips_bought')
                + (Number(r.data && r.data.minutes) || 0) + t('app.minutes_find_nothing'), 'ok');
              refresh();
            });
        });
      };
    }
    buy.id = 'dark-buy-' + contract.id;
    var actions = el('div', 'row tip-actions');
    actions.appendChild(buy);
    box.appendChild(actions);
    box.appendChild(el('div', 'hint', t('app.lie_low_for') + (Number(terms.minutes) || 0)
      + t('app.minutes_any_informant_asked_about_you') + account + '.'));
    return box;
  }

  /* The contract's reference, small, muted and selectable, for quoting to
     staff. Every staff command — the timeline, a void, who was behind it —
     starts from a contract id, and nothing on screen ever showed one, so
     "my contract on Dana is stuck" could only be answered from the
     database. */
  function appendRef(node, id) {
    if (id) { node.appendChild(el('div', 'ref', t('app.ref_id', id))); }
  }

  // Said once under a list of referenced cards rather than on every card.
  function refHint() {
    return el('div', 'hint ref-hint', t('app.quote_the_ref_to_staff_if'));
  }

  // "2 items and a weapon", or nothing when a payout is money only.
  function goodsLine(goods) {
    if (!goods) { return null; }

    var parts = [];
    if (goods.items > 0) {
      parts.push(tn('app.items_count', goods.items));
    }
    if (goods.weapons > 0) {
      parts.push(tn('app.weapons_count', goods.weapons));
    }
    if (parts.length === 0) { return null; }

    return parts.join(t('app.and_sep'))
      + (goods.labels && goods.labels.length ? ' (' + goods.labels.join(', ') + ')' : '');
  }

  /* Why this card cannot be accepted by this viewer, or nothing if it can. */
  function boardHint(contract) {
    if (contract.role === 'creator') {
      return t('app.yours_manage_it_under_mine');
    }
    if (contract.barred === 'hold_released') {
      return t('app.you_were_taken_off_this_one')
        + t('app.to_take_again');
    }
    if (contract.barred === 'staff_removed') {
      return t('app.staff_removed_you_from_this_one');
    }
    if (contract.barred === 'same_account') {
      return t('app.this_one_involves_another_of_your');
    }
    // Above this player's level (Config.Record.Tiers).
    if (contract.tierLocked) {
      return tierLockedText(contract.tierLocked);
    }
    if (contract.role === 'hitman') {
      return t('app.you_are_already_on_this_one');
    }
    var active = Number(contract.hitmenActive) || 0;
    if (contract.mode === 'exclusive' && active > 0) {
      return t('app.taken_somebody_has_this_one_to')
        + t('app.on_the_board_if_they_walk');
    }
    var cap = Number(contract.hitmenMax) || 0;
    if (contract.mode !== 'exclusive' && cap > 0 && active >= cap) {
      return t('app.full_it_comes_back_open_if');
    }
    /* Staked, with less time left than the server lets a stake be taken
       with (Penalty.MinWindowMinutes): Accept was drawn and refused every
       time as too_little_time, and the card said nothing. The same sum as
       the server's, from the clock it sent. */
    var stakeWindow = Number(settings().stakeWindowMinutes) || 0;
    var band = bandOf(contract);
    // From the band, the only time the page is told: only where every time
    // it can mean is inside the window. Anywhere else the server answers.
    var bandMost = band ? (band === TIME_BANDS[0] ? Infinity
      : TIME_BANDS[TIME_BANDS.indexOf(band) - 1].least - 1) : null;
    if (Number(contract.penaltyAmount) > 0 && stakeWindow > 0 && bandMost !== null
        && bandMost < stakeWindow) {
      return t('app.too_little_time_left_to_stake');
    }
    return null;
  }

  function actionsFor(contract, context) {
    var row = el('div', 'row actions');

    /* Everything but the card's one action.

       A creator's card was a wall of six outlined buttons of identical
       weight, and nothing on it said which one mattered. The primary stays
       in the row at full width; the rest are gathered into this, which the
       stylesheet sets as a grid of quiet tiles under it. Added to the row
       last, and only if anything went into it. */
    var more = el('div', 'more');
    function withMore() {
      if (more.children.length) { row.appendChild(more); }
      return row;
    }

    if (context === 'board') {
      /* An Accept button on a card the server can only refuse is a button
         that reads as broken. The board lists every contract but the
         viewer's own contract, so it includes the ones they placed, the ones
         they already hold, and ones somebody else has filled — and every
         one of them drew Accept. Said instead, with where to look. */
      var why = boardHint(contract);
      if (why) {
        // Theirs, or one they already hold: a tap takes them to it under
        // Mine, open, rather than a line telling them to go and look.
        if (contract.role === 'creator' || contract.role === 'hitman') {
          var go = el('button', 'ghost ico ico-end i-right board-mine', why);
          go.onclick = function () { openUnderMine(contract.id); };
          row.appendChild(go);
        } else {
          row.appendChild(el('div', 'hint', why));
        }
        return row;
      }
      // Staff paused contracts, or this player is suspended from them: the
      // server refuses every acceptance, so Accept is drawn and not live,
      // and the banner at the top says why and until when.
      if (takingPaused()) {
        var paused = el('button', 'primary', t('app.accept_contract'));
        paused.disabled = true;
        row.appendChild(paused);
        more.appendChild(reportButton(contract, null));
        return withMore();
      }
      // Disabled while the acceptance is in flight. The button opens a
      // dialog rather than doing the work, so it is not an actionButton; the
      // request it leads to is keyed the same, and a second tap during the
      // round trip sent a second accept and told the player "Contract
      // accepted" and then "You are already on this contract".
      var acceptKey = 'accept:' + contract.id;
      if (isBusy(acceptKey)) {
        row.appendChild(actionButton('primary', t('app.accept_contract'), acceptKey, t('app.accepting')));
        return row;
      }
      var take = el('button', 'primary', t('app.accept_contract'));
      take.onclick = function () { acceptContract(contract); };
      row.appendChild(take);
      more.appendChild(reportButton(contract, null));
      return withMore();
    }

    if (contract.role === 'hitman') {
      // Two ways to finish, and they share the top line; one, on a contract
      // that pays only for a live delivery, and it has the line to itself.
      row.className = 'row actions is-working';

      // Both through `once`. The camera takes as long as the hitman takes
      // to line up a shot, and until now the button stayed live throughout:
      // a second tap minted a second photo token, which invalidates the one
      // the photo already being uploaded was taken against, and spent a
      // second of the three attempts the rate limit allows — so a hitman
      // could burn their whole allowance before seeing a single answer.
      //
      // "Verifying", not "Camera open": the label lasts the whole request,
      // and the camera is shut while the photo uploads and is checked.
      //
      // Only where a kill can pay. On a contract placed for a live delivery
      // only, the server opens no kill and issues no photo for one, so the
      // button could only ever be refused, and it put a kill on the card as
      // a way to finish. Delivering is the one way, and the card's primary.
      var killPays = !aliveOnly(contract);
      if (killPays) {
        row.appendChild(restartWaits(actionButton('primary', t('app.verify_kill'),
          'photo:' + contract.id, t('app.verifying'),
          function () { return verifyKill(contract); })));
      }

      row.appendChild(restartWaits(actionButton(killPays ? null : 'primary', t('app.deliver_alive'),
        'kidnap:' + contract.id, t('app.starting_handover'),
        function () { return armKidnap(contract); })));

      // Proof items (Config.Improvements.ProofItems, off as shipped): where
      // a kill pays, handing the placer an item taken from the target.
      if (killPays && settings().proofItem) {
        row.appendChild(restartWaits(actionButton(null, t('app.hand_over_proof'),
          'proof:' + contract.id, t('app.handing_over'),
          function () { return handOverProof(contract); })));
      }

      // What the last photo was refused for, under the buttons that retry
      // it, until the next go at either.
      var refused = state.lastRefusal[contract.id];
      if (refused) { row.appendChild(el('div', 'hint is-refusal', refused)); }

      // How it is done: on an alive-only contract always, otherwise for a
      // hitman who has never finished one. Every rule was only learned by
      // tapping and failing, in a notice that is gone in seconds. Worded
      // for this contract's rule.
      var firstJob = howToFinish(contract);
      if (firstJob) { row.appendChild(firstJob); }
      var held = exclusiveReminder(contract);
      if (held) { row.appendChild(held); }

      // Where the person who placed it wants to meet, when they set a
      // point: said, never shown. Set GPS has the game mark it on the map.
      if (contract.meetingSet === true) { row.appendChild(hitmanMeeting(contract)); }

      // The informant tip: buy one, or the one bought on the map with Set GPS.
      var tip = hitmanTip(contract);
      if (tip) { row.appendChild(tip); }

      // The target has paid to close it and the buyout waits out its delay,
      // which is there so the hitman can finish first. The phone said so
      // once, and a full notice budget, a logoff or taking the contract
      // inside the delay missed it; the card said nothing at all.
      // Never more time than they have: "under N minutes".
      if (Number(contract.buyoutClosesIn) > 0) {
        var closesIn = secondsLeftOf({ secondsLeft: contract.buyoutClosesIn,
          clockReadAt: contract.clockReadAt });
        row.appendChild(el('div', 'hint is-warn', t('app.buyout_paid_it_closes_in')
          + (!(closesIn > 0) ? t('app.a_moment')
            : closesIn < 60 ? t('app.under_a_minute')
              : t('app.under_duration', durationText(Math.ceil(closesIn / 60))))
          + t('app.unless_you_finish_it_first')));
      }

      // Opening a thread is a round trip that changes nothing on screen
      // until it lands, so the button read as dead and got tapped again.
      //
      // Not drawn at all on a server with the relay switched off: every
      // message sent from it would be refused.
      if (settings().relay !== false) {
        var message = actionButton('ghost ico i-message', t('app.message'),
          'thread:' + contract.id, t('app.opening'),
          function () { return openThread(contract, null); });
        // A dot for a message newer than this phone last read.
        message.classList.toggle('has-unread',
          unreadIn(threadKey(contract, null), contract.lastMessageAt));
        message.classList.toggle('keeps-on-hold', true);
        more.appendChild(message);
      }

      var quit = el('button', 'ghost ico i-exit is-destructive', t('app.abandon'));
      quit.onclick = function () {
        ask(t('app.walk_away_from_this_contract'),
            contract.penaltyAmount > 0
              ? t('app.the_person_who_placed_it_keeps') + money(contract.penaltyAmount)
                + t('app.you_staked')
              : t('app.you_staked_nothing_on_this_one'),
            function () {
              post('abandon', { id: contract.id }).then(function (r) {
                if (!r.ok) return fail(r);
                // A handover being watched on it ends with it. Left running,
                // the poller read that ending as a failed delivery and told
                // a hitman who had just walked away to get the target back
                // to the client and try again.
                endCountdown(contract.id);
                say(t('app.you_are_off_the_contract'), 'ok');
                refresh();
              });
            });
      };
      more.appendChild(quit);

      // Not on a server with amendments switched off, where every proposal
      // is refused.
      if (settings().amendments !== false) {
        var propose = el('button', 'ghost ico i-swap', t('app.propose_change'));
        propose.onclick = function () { proposeChange(contract); };
        more.appendChild(propose);
      }
      more.appendChild(reportButton(contract, null));

      // Live progress if the countdown is running, otherwise the snapshot
      // that came with the projection.
      //
      // Directly under the two ways to finish, above the other tools. The
      // countdown is the one thing on this card that is urgent — a hitman
      // holding somebody is watching it — and it was drawn last, below
      // Message, Propose change and Abandon, a scroll away from the button
      // that started it. A proposal waiting on an answer goes with it.
      var snapshot = countdownOver[contract.id] === undefined
        ? contract.kidnapProgress : null;
      var progress = state.progress[contract.id] || snapshot;
      var panel = proposalPanel(contract);
      // Kept by contract, so the poll can repaint this bar in place.
      if (progress) { row.appendChild(countdownBars[contract.id] = countdown(progress)); }
      // A handover already running when the page opened (reopened, or
      // reloaded mid-countdown) is followed too: only arming one started the
      // poll, so the bar froze at the snapshot it was drawn from.
      // Never in place of one already followed: a second handover's card
      // took the poll over on every redraw, and the first bar froze.
      if (snapshot && !countdownTimer) {
        pollCountdown(contract.id);
      }
      if (panel) { row.appendChild(panel); }
      return onHoldOnly(contract, withMore());
    }

    if (contract.role === 'creator') {
      // One button for both directions. "Add to pot" could only ever go up,
      // and a creator who had put up too much had exactly one way down:
      // withdraw the whole contract and place it again. The editor behind
      // this offers both, and says which of them this contract allows.
      // Money, and the thing a creator comes back to this card to do, so it
      // is the card's one crimson button.
      // Before anybody takes it, one Edit sheet changes everything at once
      // (editSheet): reason, reward, stake, deadline and mode. Five buttons
      // and five dialogs did it a piece at a time. Once taken, changes are
      // proposed, and the reward can still be raised.
      var untaken = !contract.hitmenActive;
      var top = el('button', 'primary', untaken ? t('app.edit') : t('app.change_reward'));
      top.onclick = function () {
        if (untaken) { editSheet(contract); } else { editReward(contract); }
      };
      row.appendChild(top);

      // The placer's informant (Config.Intel.PlacerInformant): only where the
      // server sells it and somebody is on the contract, and drawn disabled,
      // with why, once it cannot be pressed.
      var lookUp = placerInformantRow(contract);
      if (lookUp) { more.appendChild(lookUp); }

      // Same shape, same reason: {} has no .length, so this read as "no
      // hitmen" whether or not there were any.
      if (asList(contract.hitmen).length && settings().relay !== false) {
        var threadsButton = actionButton('ghost ico i-message', t('app.threads'),
          'threads:' + contract.id, t('app.opening'),
          function () { return openThreads(contract); });
        // A dot when any operative's thread has a message newer than this
        // phone last read of it.
        threadsButton.classList.toggle('has-unread', asList(contract.hitmen).some(function (h) {
          return h && unreadIn(threadKey(contract, { alias: h.alias }), h.lastMessageAt);
        }));
        threadsButton.classList.toggle('keeps-on-hold', true);
        more.appendChild(threadsButton);
      }

      if (!untaken) {
        var extend = el('button', 'ghost ico i-clock', t('app.extend_deadline'));
        extend.onclick = function () { improveContract(contract); };
        more.appendChild(extend);

        // Not on a server with amendments switched off, where every proposal
        // is refused.
        if (settings().amendments !== false) {
          var change = el('button', 'ghost ico i-swap', t('app.propose_change'));
          change.onclick = function () { proposeChange(contract); };
          more.appendChild(change);
        }
      } else {
        // Only while nobody is holding it. Once a hitman has accepted they
        // accepted it as written, and the server refuses it — so offering it
        // would be offering a guaranteed refusal.
        var scrap = el('button', 'danger ico i-xcircle', t('app.withdraw'));
        scrap.onclick = function () { cancelContract(contract); };
        more.appendChild(scrap);
      }
      more.appendChild(reportButton(contract, null));
      // What contract decay does to it, and the way to stop it
      // (Config.Improvements.ContractDecay).
      appendDecay(row, more, contract);
      withMore();
      onHoldOnly(contract, row);

      var creatorPanel = proposalPanel(contract);
      if (creatorPanel) {
        var creatorWrap = el('div');
        creatorWrap.appendChild(row);
        creatorWrap.appendChild(creatorPanel);
        return creatorWrap;
      }
      return row;
    }

    if (contract.role === 'target') {
      // Somebody tipped off about where they were: first, it is about them now.
      if (contract.tippedAt) { row.appendChild(tipToldNotice(contract.tippedAt)); }
      // Going dark, where the server sells it (Config.Intel.GoDark).
      if (contract.goDark) { row.appendChild(goDarkBox(contract)); }
      appendBuyout(row, contract);
      // Their bodyguard job and the hit on a revealed operative, where the
      // server offers them (server/rp_protection.lua).
      appendCounterplay(row, more, contract);
      // Only where the server offers this target something to pick: never to
      // a member of a whitelisted job, who keeps their buyout.
      if (informantOffered(contract)) {
        more.appendChild(informantButton(contract));
      }
      more.appendChild(reportButton(contract, null));
      return onHoldOnly(contract, withMore());
    }

    return row;
  }

  /* A card on hold by staff keeps what still works there — Message,
     Threads and Report — and loses everything the server refuses while it
     is held. Drawn and refused, each read as broken. */
  function onHoldOnly(contract, row) {
    if (!contract.onHold) { return row; }
    function prune(parent) {
      Array.prototype.slice.call(parent.children).forEach(function (child) {
        if (child.classList && child.classList.contains('more')) {
          prune(child);
          if (!child.children.length) { parent.removeChild(child); }
          return;
        }
        var label = child.textContent;
        var keeps = (child.classList && child.classList.contains('keeps-on-hold'))
          || (child.tagName === 'BUTTON' && (label === t('app.report') || label === t('app.sending')));
        if (!keeps) { parent.removeChild(child); }
      });
    }
    prune(row);
    return row;
  }

  /* A way to finish, or a buyout, while the restart hold is on: the server
     refuses it until the restart (or until the hold runs out), so it is
     drawn and not live. The banner says why. */
  function restartWaits(button) {
    if (holdsNow().restartHold) {
      button.disabled = true;
      button.onclick = null;
      button.classList.toggle('is-held', true);
    }
    return button;
  }

  /* What refuses writes right now, from the board's reply (server: the
     'list' handler's `holds`): staff paused the app, the restart hold, or
     this player suspended. */
  function holdsNow() {
    return (state.board && state.board.holds) || {};
  }

  /* The organisation's cut for this player, from the board's reply
     (server: the 'list' handler's orgTerms): a member's only, none while
     the organisation is off. */
  function orgTermsNow() {
    var tv = state.board && state.board.orgTerms;
    return tv && typeof tv.orgPercent === 'number' ? tv : null;
  }

  /* One short line: what of a payout goes to the organisation's funds. */
  function orgCutText(tv) {
    var pct = Number(tv.orgPercent) || 0;
    if (pct <= 0) { return t('app.organisation_cut_none_you_keep_all'); }
    return t('app.organisation_cut') + pct + t('app.of_your_payout_goes_to_its')
      + (100 - pct) + '%.';
  }

  /* A boss's invite to join the organisation, waiting for this player
     (server: the board's orgInvite): the organisation and the role, never
     who asked. Accept and Decline each take a second tap. */
  var inviteArmed = null;   // 'accept' | 'decline' while it waits for its second tap
  function inviteBanner() {
    var inv = state.board && state.board.orgInvite;
    if (!inv || typeof inv.id !== 'string') { return null; }
    var box = el('div', 'notice gold org-invite');
    var minutes = Math.max(1, Math.ceil((Number(inv.expiresIn) || 0) / 60));
    box.appendChild(el('div', null, t('app.invited_to_join', inv.label || t('app.the_organisation'),
      inv.role ? t('app.as_role', inv.role) : '', durationText(minutes))));
    var row = el('div', 'row org-invite-actions');
    var key = 'orgInvite:' + inv.id;
    function answer(accept) {
      var which = accept ? 'accept' : 'decline';
      var label = accept ? t('app.accept') : t('app.decline');
      if (isBusy(key)) {
        return actionButton(accept ? 'primary' : 'ghost', label, key, accept ? t('app.joining') : t('app.declining'));
      }
      var armed = inviteArmed === which;
      var b = el('button', (accept ? 'primary' : 'ghost') + (armed ? ' is-armed' : ''),
        armed ? t('app.tap_again_to') + which : label);
      b.onclick = function () {
        if (inviteArmed !== which) {
          inviteArmed = which;
          setTimeout(function () {
            if (inviteArmed === which) { inviteArmed = null; redraw(); }
          }, TIP_CONFIRM_MS);
          return redraw();
        }
        inviteArmed = null;
        once(key, function () {
          return post('orgInviteAnswer', { id: inv.id, accept: accept }).then(function (r) {
            if (!r.ok) {
              say((r.data && r.data.message) || t('app.that_invite_is_no_longer_open'));
              return refresh();
            }
            say(accept ? t('app.you_have_joined') + (inv.label || t('app.the_organisation')) + '.'
              : t('app.invite_declined'), 'ok');
            return refresh();
          });
        });
      };
      return b;
    }
    row.appendChild(answer(true));
    row.appendChild(answer(false));
    box.appendChild(row);
    return box;
  }

  /* ---------- the Organisation tab ----------

     The hitman organisation (server/org/, Config.Organisation, off as
     shipped). The tab exists only while the board's reply says it is for
     this player (orgTab: a member, an applicant, an invitee, or a player
     standing at a sign-up spot); off, or for anybody else, it is not even
     in the tab bar. What it shows is what orgMine answers: a member's
     place, the notice, their cut and salary, and a boss menu holding only
     the powers the server says they hold after Boss permissions. Every
     write takes two taps; every refusal is the server's own words where it
     sent some, and this page's (ERRORS) otherwise. Positions are never
     sent: Place here is read by the server where it sees the player. */

  state.org = {
    mine: null, failed: null, screen: null, data: {}, dataFailed: {}, form: {},
    armed: null, open: {}, pick: null
  };
  var orgSeq = 0;
  var orgNonceSeq = 0;

  /* The boss menu's screens, the powers each is for, and the layout tab
     (Org.layout, S2) that renames or hides it. */
  var ORG_SCREENS = [
    { id: 'members', label: t('app.members'), layout: 'members',
      powers: ['M1', 'M2', 'M3', 'M4', 'M5', 'M6', 'M7', 'M8', 'M9', 'D2'] },
    { id: 'roles', label: t('app.roles'), layout: 'roles', powers: ['R1', 'R2', 'R3', 'R4', 'P1', 'P3'] },
    { id: 'money', label: t('app.money'), layout: 'funds',
      powers: ['C1', 'C2', 'C3', 'C4', 'C5', 'C6', 'C7', 'C8', 'P2'] },
    { id: 'contracts', label: t('app.contracts'), layout: 'contracts', powers: ['K1', 'K2', 'K3'] },
    { id: 'work', label: t('app.assignments'), layout: 'contracts', powers: ['K4', 'K5', 'K6', 'K7'] },
    { id: 'places', label: t('app.places'), layout: 'locations', powers: ['L1', 'L2', 'L3'] },
    { id: 'notices', label: t('app.notices'), layout: 'notices', powers: ['N1'] },
    { id: 'applications', label: t('app.applications'), layout: 'notices', powers: ['N2'] },
    { id: 'recruiting', label: t('app.application_form'), layout: 'notices', powers: ['N4'] },
    { id: 'settings', label: t('app.settings'), layout: 'settings', powers: ['S1', 'S2', 'S3'] },
    /* Not on the boss menu: every member's, each from its own card (the
       flag on orgMine that says its switch is on). */
    { id: 'channel', label: t('app.channel'), layout: 'notices', powers: [], member: 'channel' },
    { id: 'armory', label: t('app.armory'), layout: 'members', powers: [], member: 'armory' },
    { id: 'stats', label: t('app.leaderboard'), layout: 'members', powers: [], member: 'statsOn' },
    { id: 'garage', label: t('app.garage'), layout: 'members', powers: [], member: 'garage' },
    /* Organisation extras 3: the activity log on the boss menu (M12). */
    { id: 'activity', label: t('app.activity_log'), layout: 'members', powers: ['M12'] }
  ];
  /* The extras' powers, each only while its switch is on (orgMine says). */
  var ORG_POWER_SWITCH = { M7: 'codenames', P3: 'payroll', K4: 'orgContracts', K5: 'orgContracts',
    K6: 'approval', K7: 'dossiers', M8: 'probationOn', M9: 'dutyOn', N3: 'channel',
    A1: 'armory', A2: 'armory', M10: 'statsOn', M11: 'discipline', N4: 'recruitment',
    M12: 'activity', P4: 'deadDrops', K8: 'internal', V1: 'garage' };
  var ORG_SPOT_WORDS = { office: t('app.boss_office'), signup: t('app.sign_up_spot'), meeting: t('app.meeting_spot'),
    npc: t('app.contact'), place: t('app.place') };

  function orgTabWanted() {
    var b = state.board;
    return state.mode !== 'whitelisted' && !!(b && typeof b.orgTab === 'string' && b.orgTab);
  }

  /* The tab itself: made when it is for this player, taken away when it is
     not, so a player outside the organisation has the same five tabs. */
  function syncOrgTab() {
    var tabs = Array.prototype.slice.call(document.querySelectorAll('.tab'));
    var mine = tabs.filter(function (tv) { return tv.dataset.tab === 'org'; })[0];
    var want = orgTabWanted();
    if (want && !mine && tabs.length) {
      var tab = el('button', 'tab', t('app.org'));
      tab.dataset.tab = 'org';
      tab.setAttribute('role', 'tab');
      tabs[0].parentNode.appendChild(tab);
      wireTab(tab);
    } else if (!want && mine) {
      if (mine.parentNode) { mine.parentNode.removeChild(mine); }
      if (state.tab === 'org') { state.tab = 'board'; }
    }
  }

  function orgWords(r) {
    if (r && r.err === 'timeout' && ORG_MONEY_EVENTS[r.event] === true) {
      return t('app.no_answer_yet_it_may_still');
    }
    return (r && r.data && typeof r.data.message === 'string' && r.data.message)
      || (r && ERRORS[r.err]) || t('app.not_done_try_again');
  }

  function orgHolds(code) {
    var m = state.org.mine;
    if (!m || !m.powers || m.powers[code] !== true) { return false; }
    var needs = ORG_POWER_SWITCH[code];
    if (needs && !m[needs]) { return false; }
    return true;
  }

  /* An office-only power, held, with the server not seeing them there. */
  function orgAway(code) {
    var m = state.org.mine;
    return !!(m && m.officeOnly && m.officeOnly[code] && !m.inOffice);
  }

  function orgBound(key) {
    var b = state.org.mine && state.org.mine.bounds;
    return b && typeof b[key] === 'number' ? b[key] : null;
  }

  function orgScreenShown(screen) {
    var m = state.org.mine;
    var hidden = m && m.layout && m.layout.hidden && asList(m.layout.hidden[screen.layout]);
    if (screen.member) { return !!(m && m[screen.member]); }
    if (hidden && hidden.indexOf(m.grade) !== -1) { return false; }
    return screen.powers.some(orgHolds);
  }

  function orgScreenLabel(screen) {
    var labels = state.org.mine && state.org.mine.layout && state.org.mine.layout.labels;
    var own = labels && labels[screen.layout];
    return screen.id !== 'applications' && typeof own === 'string' && own ? own : screen.label;
  }

  function loadOrg() {
    orgSeq += 1;
    var current = orgSeq;
    // Several organisations: the one an outsider picked to look at.
    return post('orgMine', state.org.pick ? { org: state.org.pick } : {}).then(function (r) {
      if (current !== orgSeq) { return; }
      if (r && r.ok && r.data && typeof r.data === 'object') {
        state.org.mine = r.data;
        state.org.failed = null;
      } else {
        state.org.failed = orgWords(r);
      }
      redrawFor(['org']);
      if (state.org.screen && state.org.mine && state.org.mine.member) { loadOrgScreen(state.org.screen); }
    });
  }

  /* One read a screen draws, kept by key, its refusal kept in its place. */
  function orgRead(key, request) {
    return request().then(function (r) {
      if (r && r.ok && r.data && typeof r.data === 'object') {
        state.org.data[key] = r.data;
        delete state.org.dataFailed[key];
      } else {
        state.org.dataFailed[key] = orgWords(r);
      }
      redrawFor(['org']);
    });
  }

  function loadOrgScreen(id) {
    var wantMembers = orgHolds('M1') && (id === 'members' || (id === 'money' && (orgHolds('P2') || orgHolds('C3')))
      || (id === 'contracts' && orgHolds('K2')));
    var wantRoles = id === 'roles' || (id === 'members' && (orgHolds('M2') || orgHolds('M4')))
      || (id === 'money' && orgHolds('C2')) || id === 'contracts';
    if (wantMembers) { orgRead('members', function () { return post('orgMembers', {}); }); }
    if (wantRoles) { orgRead('roles', function () { return post('orgRoles', {}); }); }
    if (id === 'money' && orgHolds('C8')) { orgRead('funds', function () { return post('orgFunds', { limit: 20 }); }); }
    if (id === 'places') { orgRead('spots', function () { return post('orgSpots', {}); }); }
    if (id === 'applications') { orgRead('applications', function () { return post('orgApplications', {}); }); }
    if (id === 'work') { orgRead('work', function () { return post('orgWork', {}); }); }
    if (id === 'channel') { orgRead('channel', function () { return post('orgChannel', { limit: 50 }); }); }
    if (id === 'armory') {
      orgRead('armory', function () { return post('orgArmory', {}); });
      if (orgHolds('A2')) { orgRead('roles', function () { return post('orgRoles', {}); }); }
    }
    if (id === 'stats') { orgRead('stats', function () { return post('orgStats', {}); }); }
    if (id === 'garage') { orgRead('garage', function () { return post('orgGarage', {}); }); }
    if (id === 'activity') { orgRead('activity', function () { return post('orgActivity', { limit: 100 }); }); }
  }

  /* A write: once at a time, its answer said, and what the tab shows read
     again either way (a refusal is often the world having moved on). */
  function orgWrite(key, request, okText) {
    once('org:' + key, function () {
      return request().then(function (r) {
        if (!r || !r.ok) {
          say(orgWords(r));
        } else {
          say(typeof okText === 'function' ? okText(r) : (okText || t('app.done')), 'ok');
        }
        return loadOrg();
      });
    });
  }

  function orgNonce() {
    orgNonceSeq += 1;
    return 'n' + Date.now().toString(36) + '_' + orgNonceSeq;
  }

  /* A write's button: the first tap arms it (and says what the second
     does), the second within three seconds runs it. Drawn disabled, with
     why under it, while an office-only power is away from the office. */
  function orgTwoTap(className, label, key, armedLabel, run, office) {
    if (isBusy('org:' + key)) {
      var busy = el('button', className, t('app.working'));
      busy.disabled = true;
      busy.classList.toggle('is-busy', true);
      return busy;
    }
    var armed = state.org.armed === key;
    var b = el('button', className, armed ? armedLabel : label);
    if (armed) { b.classList.toggle('is-armed', true); }
    var away = office ? orgAway(office) : false;
    if (away) { b.disabled = true; }
    b.onclick = function () {
      if (b.disabled) { return; }
      if (state.org.armed !== key) {
        state.org.armed = key;
        setTimeout(function () {
          if (state.org.armed === key) { state.org.armed = null; redraw(); }
        }, TIP_CONFIRM_MS);
        return redraw();
      }
      state.org.armed = null;
      run();
    };
    return b;
  }

  /* Why an office-only power's buttons are greyed: said once per card. */
  function orgOfficeNote(code) {
    if (!orgAway(code)) { return null; }
    var note = el('div', 'hint org-office ico i-briefcase', state.org.mine.hasOffice
      ? t('app.this_needs_the_boss_office_go')
      : t('app.this_needs_the_boss_office_and'));
    return note;
  }

  function orgField(key, label, kind, placeholder, max) {
    var input = make(kind === 'area' ? 'textarea' : 'input');
    if (kind !== 'area') { input.type = kind === 'number' ? 'number' : 'text'; }
    if (kind === 'number') { input.inputMode = 'numeric'; input.min = 0; }
    input.id = 'org-' + key.replace(/[^A-Za-z0-9]/g, '-');
    input.value = state.org.form[key] !== undefined ? state.org.form[key] : '';
    if (placeholder) { input.placeholder = placeholder; }
    if (max && kind !== 'number') { input.maxLength = max; }
    input.oninput = function () { state.org.form[key] = input.value; };
    return labelled(label, input);
  }

  function orgText(key) { return String(state.org.form[key] === undefined ? '' : state.org.form[key]).trim(); }

  function orgNumber(key) {
    var raw = orgText(key);
    if (raw === '' || !/^\d+$/.test(raw)) { return null; }
    return parseInt(raw, 10);
  }

  /* A choice drawn as buttons (a native select draws wrongly in CEF). */
  function orgChoice(key, options, fallback) {
    var row = el('div', 'row org-choice');
    var current = state.org.form[key] !== undefined ? state.org.form[key] : fallback;
    options.forEach(function (o) {
      var b = el('button', 'ghost', o.label);
      if (current === o.value) { b.classList.toggle('is-on', true); }
      b.onclick = function () { state.org.form[key] = o.value; redraw(); };
      row.appendChild(b);
    });
    return row;
  }

  function orgChosen(key, fallback) {
    return state.org.form[key] !== undefined ? state.org.form[key] : fallback;
  }

  function orgCard(title, icon) {
    var node = el('div', 'card org-card');
    node.appendChild(el('div', 'org-card-title ico ' + (icon || 'i-briefcase'), title));
    return node;
  }

  function orgRow() { return el('div', 'row org-actions'); }

  function orgPending(view, key) {
    if (state.org.dataFailed[key]) {
      view.appendChild(el('div', 'hint', state.org.dataFailed[key]));
      return true;
    }
    if (!state.org.data[key]) {
      view.appendChild(el('div', 'empty is-pending', t('app.asking_the_server')));
      return true;
    }
    return false;
  }

  function orgRoles() { return asList(state.org.data.roles && state.org.data.roles.rows); }
  function orgMembers() { return asList(state.org.data.members && state.org.data.members.rows); }

  function orgRoleOptions(editableOnly, maxGrade) {
    return orgRoles().filter(function (r) {
      return (!editableOnly || r.editable) && (maxGrade === null || maxGrade === undefined || r.grade <= maxGrade);
    }).map(function (r) { return { value: r.grade, label: String(r.label || r.name || r.grade) }; });
  }

  function orgMemberOptions() {
    return orgMembers().map(function (m) { return { value: m.ref, label: String(m.name || t('app.a_member')) }; });
  }

  function viewOrg(view) {
    var o = state.org;
    if (o.failed && !o.mine) {
      var failed = el('div', 'card');
      failed.appendChild(el('div', 'hint', o.failed));
      var again = el('button', 'ghost ico i-refresh', t('app.try_again'));
      again.onclick = function () { o.failed = null; loadOrg(); render(); };
      failed.appendChild(again);
      view.appendChild(failed);
      return;
    }
    if (!o.mine) {
      view.appendChild(el('div', 'empty is-pending', t('app.asking_the_server')));
      return;
    }
    var m = o.mine;
    if (m.enabled === false) {
      view.appendChild(el('div', 'empty', ERRORS.org_off));
      return;
    }
    if (!m.member) { return viewOrgOutside(view, m); }
    if (o.screen) {
      var screen = ORG_SCREENS.filter(function (s) { return s.id === o.screen; })[0];
      if (screen && orgScreenShown(screen)) { return viewOrgScreen(view, screen); }
      o.screen = null;
    }
    viewOrgHome(view, m);
  }

  /* An invitee, an applicant, or a player at a sign-up spot. */
  function viewOrgOutside(view, m) {
    var invite = inviteBanner();
    if (invite) { view.appendChild(invite); return; }
    // Several organisations: which one to look at and apply to.
    if (Array.isArray(m.choices) && m.choices.length > 1) {
      var pick = orgCard(t('app.organisations'), 'i-briefcase');
      var chips = orgRow();
      m.choices.forEach(function (c) {
        var b = el('button', 'btn' + (c.id === m.id ? ' primary' : ''), String(c.label || c.id));
        b.type = 'button';
        b.setAttribute('aria-pressed', c.id === m.id ? 'true' : 'false');
        b.onclick = function () {
          if (c.id === m.id) { return; }
          state.org.pick = String(c.id);
          loadOrg();
        };
        chips.appendChild(b);
      });
      pick.appendChild(chips);
      view.appendChild(pick);
    }
    var box = orgCard(m.label || t('app.the_organisation_2'), 'i-briefcase');
    if (m.applied) {
      box.appendChild(el('div', 'hint', t('app.your_application_is_waiting_for_an')));
      view.appendChild(box);
      return;
    }
    box.appendChild(el('div', 'hint', m.signupOnly && !m.atSignup
      ? t('app.applications_are_taken_only_at_a')
      : t('app.ask_to_join_a_boss_reads')));
    if (m.cooldownUntil) {
      box.appendChild(el('div', 'hint org-warn', t('app.your_last_application_was_declined_you')
        + durationText(Math.max(1, Math.ceil((Number(m.cooldownUntil) - Date.now() / 1000) / 60))) + '.'));
    }
    var questions = asList(m.form);
    questions.forEach(function (q, i) {
      box.appendChild(orgField('apply.a' + i, String(q), 'area', t('app.your_answer'), Number(m.answerMax) || 300));
    });
    box.appendChild(orgField('apply.text', t('app.a_few_words_optional'), 'area', t('app.why_you'), 255));
    var row = orgRow();
    row.appendChild(orgTwoTap('primary', t('app.apply'), 'apply', t('app.tap_again_to_apply'), function () {
      var text = orgText('apply.text');
      var data = text ? { text: text } : {};
      if (m.id) { data.org = m.id; }
      if (questions.length) {
        data.answers = questions.map(function (q, i) { return orgText('apply.a' + i); });
        if (data.answers.some(function (x) { return !x; })) { redraw(); return say(t('app.answer_every_question_first')); }
      }
      orgWrite('apply', function () {
        return post('orgApply', data);
      }, t('app.applied_you_will_be_told_the'));
    }));
    box.appendChild(row);
    view.appendChild(box);
  }

  function viewOrgHome(view, m) {
    var head = orgCard(m.label || t('app.the_organisation_2'), 'i-briefcase');
    head.appendChild(el('div', 'target', m.codename ? t('app.codename_shown', m.codename) : (m.role || t('app.member'))));
    head.appendChild(el('div', 'hint', t('app.your_role') + (m.role || t('app.member'))));
    if (m.suspendedUntil) {
      head.appendChild(el('div', 'hint org-warn', suspendedText({ untilAt: m.suspendedUntil,
        reason: t('app.by_the_organisation') })));
    }
    if (m.terms) {
      head.appendChild(el('div', 'hint', orgCutText(m.terms)));
      if (Number(m.terms.stakePercent) > 0) {
        head.appendChild(el('div', 'hint', t('app.of_a_stake_you_win') + m.terms.stakePercent + t('app.goes_to_the_funds')));
      }
      if (Number(m.terms.buyoutPercent) > 0) {
        head.appendChild(el('div', 'hint', t('app.of_a_buyout_paid_to_you') + m.terms.buyoutPercent
          + t('app.goes_to_the_funds')));
      }
    }
    if (m.payroll) {
      var pay = Number(m.payroll.salary) || 0;
      head.appendChild(el('div', 'hint', pay > 0
        ? t('app.salary_each_pay_day', money(pay), m.payroll.nextIn
          ? t('app.the_next_in_about_x', durationText(Math.max(1, Math.ceil(Number(m.payroll.nextIn) / 60)))) : '')
        : t('app.your_role_has_no_salary')));
    }
    var limits = m.limits || {};
    if (limits.maxAtOnce || limits.cooldownMinutes) {
      head.appendChild(el('div', 'hint', t('app.your_limits') + (limits.maxAtOnce ? limits.maxAtOnce + t('app.at_once') : '')
        + (limits.maxAtOnce && limits.cooldownMinutes ? ', ' : '')
        + (limits.cooldownMinutes ? limits.cooldownMinutes + t('app.min_between_accepts') : '') + '.'));
    }
    view.appendChild(head);

    var notice = orgCard(t('app.notice_board'), 'i-flag');
    notice.appendChild(el('div', m.notice ? 'org-notice' : 'hint', m.notice || t('app.no_notice_posted')));
    view.appendChild(notice);

    if (m.codenames) { view.appendChild(orgCodenameCard(m)); }

    // A member's own record in the organisation (Config.Organisation.Stats):
    // said, rather than left out, while it is off, so the place is known.
    view.appendChild(orgRecordCard(m));
    if (m.discipline) { view.appendChild(orgDisciplineCard(m.discipline)); }
    if (m.armory) { view.appendChild(orgOpenCard(t('app.armory'), 'i-box', m.armoryReady
      ? t('app.the_organisations_stash_put_in_what')
      : t('app.the_armory_needs_an_inventory_script'), t('app.open_armory'), 'armory')); }
    viewOrgExtras3(view, m);

    viewOrgExtras(view, m);

    var screens = ORG_SCREENS.filter(function (s) { return !s.member && orgScreenShown(s); });
    if (screens.length) {
      var menu = orgCard(t('app.boss_menu'), 'i-users');
      var away = Object.keys(m.officeOnly || {}).some(orgAway);
      if (away) {
        menu.appendChild(el('div', 'hint org-office', m.hasOffice
          ? t('app.some_of_your_powers_work_only')
          : t('app.some_of_your_powers_need_the')));
      }
      var row = el('div', 'row org-menu');
      screens.forEach(function (s) {
        var b = el('button', 'ghost', orgScreenLabel(s));
        b.onclick = function () {
          state.org.screen = s.id;
          state.org.armed = null;
          render();
          loadOrgScreen(s.id);
        };
        row.appendChild(b);
      });
      menu.appendChild(row);
      view.appendChild(menu);
    }
    var refresh = el('button', 'ghost ico i-refresh', t('app.refresh'));
    refresh.onclick = function () { loadOrg(); };
    var foot = orgRow();
    foot.appendChild(refresh);
    view.appendChild(foot);
  }

  function orgCodenameCard(m) {
    var box = orgCard(t('app.codename'), 'i-user');
    if (m.codenameGiven) {
      box.appendChild(el('div', 'hint', t('app.given_to_you') + (m.codename || '') + t('app.only_whoever_gave_it_changes_it')));
      return box;
    }
    box.appendChild(el('div', 'hint', m.codename
      ? t('app.shown_in_the_organisation_and_to')
        + m.codename + t('app.codename_a_contract_keeps_the_one')
      : t('app.pick_one_it_is_shown_in')
        + t('app.as_a_codename_it_may_not')));
    box.appendChild(orgField('codename.own', t('app.codename'), 'text', t('app.letters_and_digits'), 32));
    var row = orgRow();
    row.appendChild(orgTwoTap('primary', t('app.set_codename'), 'codename', t('app.tap_again_to_set_it'), function () {
      var name = orgText('codename.own');
      if (!name) { return say(t('app.write_the_codename_first')); }
      orgWrite('codename', function () { return post('orgCodename', { codename: name }); }, t('app.codename_set'));
    }));
    if (m.codename) {
      row.appendChild(orgTwoTap('ghost', t('app.clear'), 'codename:clear', t('app.tap_again_to_clear'), function () {
        orgWrite('codename:clear', function () { return post('orgCodename', { codename: false }); },
          t('app.codename_cleared'));
      }));
    }
    box.appendChild(row);
    return box;
  }

  function viewOrgScreen(view, screen) {
    var bar = el('div', 'row org-back');
    var back = el('button', 'ghost', t('app.back'));
    back.onclick = function () { state.org.screen = null; state.org.armed = null; render(); };
    bar.appendChild(back);
    var refresh = el('button', 'ghost ico i-refresh', t('app.refresh'));
    refresh.onclick = function () { loadOrg(); };
    bar.appendChild(refresh);
    view.appendChild(bar);
    view.appendChild(el('div', 'section', orgScreenLabel(screen)));
    ({
      members: orgMembersScreen, roles: orgRolesScreen, money: orgMoneyScreen,
      contracts: orgContractsScreen, places: orgPlacesScreen, notices: orgNoticesScreen,
      applications: orgApplicationsScreen, settings: orgSettingsScreen,
      work: orgWorkScreen, channel: orgChannelScreen,
      armory: orgArmoryScreen, stats: orgStatsScreen, recruiting: orgRecruitingScreen,
      garage: orgGarageScreen, activity: orgActivityScreen
    })[screen.id](view);
  }

  /* ---- Organisation extras 2: the record and leaderboard, discipline,
     the armory and the application form (each drawn only while orgMine
     says its switch is on) ---- */

  /* A card with one button that opens a member screen. */
  /* ---- Organisation extras 3: reputation, dead drops, the garage and
     internal contracts (each drawn only while orgMine says its switch is
     on). The handler is in the world; territory is never shown. ---- */

  function viewOrgExtras3(view, m) {
    if (m.reputation) {
      var rep = orgCard(t('app.reputation'), 'i-shield');
      var r = m.reputation;
      rep.appendChild(el('div', 'target', t('app.tier_points', r.tier || t('app.no_tier_yet'), Number(r.points) || 0)));
      rep.appendChild(el('div', 'hint', Number(r.max) > 0
        ? t('app.members_may_take_contracts_worth_up') + money(Number(r.max)) + '.'
        : t('app.no_cap_on_what_members_may')));
      if (r.next) {
        rep.appendChild(el('div', 'hint', (Number(r.toNext) || 0) + t('app.more_points_to') + r.next + '.'));
      }
      view.appendChild(rep);
    }
    if (m.deadDrops) {
      var d = m.deadDrops;
      var drop = orgCard(t('app.payouts'), 'i-box');
      drop.appendChild(el('div', 'hint', d.method === 'deaddrop'
        ? t('app.payouts_are_left_at_the_dead') + (d.spot ? ' (' + d.spot + ')' : '') + t('app.collect_them_there')
        : t('app.payouts_are_handed_over_the_usual')));
      if (Number(d.waiting) > 0) {
        drop.appendChild(el('div', 'hint org-warn', Number(d.waiting) + t('app.payout_wait_for_you_at_the')));
      }
      if (d.choose) {
        var other = d.method === 'deaddrop' ? 'bank' : 'deaddrop';
        var row = orgRow();
        row.appendChild(orgTwoTap('ghost', other === 'bank' ? t('app.pay_the_usual_way') : t('app.pay_at_the_dead_drop'),
          'paymethod', t('app.tap_again_to_change_it'), function () {
            orgWrite('paymethod', function () { return post('orgPayoutMethod', { method: other }); },
              t('app.payout_method_changed'));
          }, 'P4'));
        drop.appendChild(row);
      }
      view.appendChild(drop);
    }
    if (m.garage) {
      view.appendChild(orgOpenCard(t('app.garage'), 'i-pin', t('app.vehicles_staff_approved_taken_out_at'),
        t('app.open_garage'), 'garage'));
    }
    if (m.internal) { view.appendChild(orgInternalCard(m.internal)); }
  }

  function orgInternalCard(info) {
    var box = orgCard(t('app.internal_contract'), 'i-flag');
    box.appendChild(el('div', 'hint', t('app.ask_staff_for_a_contract_on')
      + t('app.approve_it_it_is_then_placed')));
    var targets = asList(info.targets);
    if (!targets.length) {
      box.appendChild(el('div', 'hint', t('app.nobody_below_you')));
    } else {
      box.appendChild(orgChoice('ic.member', targets.map(function (tv) {
        return { value: String(tv.ref), label: String(tv.name) };
      }), String(targets[0].ref)));
      box.appendChild(orgField('ic.reason', t('app.why'), 'area', t('app.what_they_did'), 200));
      box.appendChild(orgField('ic.amount', t('app.reward_cash'), 'number', '5000'));
      var row = orgRow();
      row.appendChild(orgTwoTap('primary', t('app.ask_staff'), 'ic:ask', t('app.tap_again_to_ask_staff'), function () {
        var reason = orgText('ic.reason'), amount = orgNumber('ic.amount');
        if (!reason || !amount) { redraw(); return say(t('app.write_why_and_the_reward')); }
        orgWrite('ic:ask', function () {
          return post('orgInternalRequest', { member: orgChosen('ic.member', String(targets[0].ref)),
            reason: reason, amount: amount });
        }, t('app.sent_to_staff_you_are_told'));
      }, 'K8'));
      box.appendChild(row);
    }
    asList(info.rows).forEach(function (q) {
      box.appendChild(el('div', 'hint', String(q.name) + ': ' + ({ pending: t('app.waiting_for_staff'),
        placed: t('app.placed_label'), declined: t('app.declined_label'), expired: t('app.ran_out') }[q.state] || String(q.state))));
    });
    return box;
  }

  function orgGarageScreen(view) {
    if (orgPending(view, 'garage')) { return; }
    var g = state.org.data.garage;
    if (!g.ready) { view.appendChild(el('div', 'hint', t('app.the_garage_needs_a_vehicle_adapter'))); }
    if (!g.hasSpot) { view.appendChild(el('div', 'hint', t('app.staff_have_not_set_a_garage'))); }
    var mine = orgCard(t('app.yours'), 'i-pin');
    if (g.mine) {
      mine.appendChild(el('div', 'target', String(g.mine.model) + ' · ' + String(g.mine.plate || '')));
      var back = orgRow();
      back.appendChild(orgTwoTap('ghost', t('app.return_it'), 'garage:return', t('app.tap_again_to_return_it'), function () {
        orgWrite('garage:return', function () { return post('orgGarageReturn', {}); }, t('app.returned'));
        orgRead('garage', function () { return post('orgGarage', {}); });
      }));
      mine.appendChild(back);
      mine.appendChild(el('div', 'hint', t('app.bring_it_back_to_the_garage')));
    } else {
      mine.appendChild(el('div', 'hint', t('app.none_out_stand_at_the_garage')));
      asList(g.models).forEach(function (model) {
        var row = orgRow();
        row.appendChild(el('span', 'target', String(model)));
        row.appendChild(orgTwoTap('ghost', t('app.take_out'), 'garage:take:' + model, t('app.tap_again_to_take_it'), function () {
          orgWrite('garage:take:' + model, function () { return post('orgGarageTake', { model: model }); },
            t('app.it_is_yours_the_keys_too'));
          orgRead('garage', function () { return post('orgGarage', {}); });
        }));
        mine.appendChild(row);
      });
    }
    view.appendChild(mine);
    var out = orgCard(t('app.out_now'), 'i-layers');
    out.appendChild(el('div', 'hint', t('app.out_of', asList(g.out).length, Number(g.max) || 0)));
    asList(g.out).forEach(function (o) { out.appendChild(el('div', 'hint', String(o.name) + ': ' + String(o.model))); });
    view.appendChild(out);
    if (g.manage) {
      var offer = orgCard(t('app.offered_to_members'), 'i-lock');
      asList(g.all).forEach(function (a) {
        var key = 'garage.offer.' + a.model;
        var on = state.org.form[key] !== undefined ? state.org.form[key] === true : a.offered === true;
        var b = el('button', 'ghost' + (on ? ' is-on' : ''), String(a.model));
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
        b.onclick = function () { state.org.form[key] = !on; redraw(); };
        offer.appendChild(b);
      });
      var save = orgRow();
      save.appendChild(orgTwoTap('primary', t('app.save'), 'garage:offer', t('app.tap_again_to_save_it'), function () {
        var models = asList(g.all).filter(function (a) {
          var key = 'garage.offer.' + a.model;
          return state.org.form[key] !== undefined ? state.org.form[key] === true : a.offered === true;
        }).map(function (a) { return a.model; });
        orgWrite('garage:offer', function () { return post('orgGarageOffer', { models: models }); }, t('app.saved'));
        orgRead('garage', function () { return post('orgGarage', {}); });
      }, 'V1'));
      offer.appendChild(save);
      view.appendChild(offer);
    }
  }

  function orgActivityScreen(view) {
    if (orgPending(view, 'activity')) { return; }
    var rows = asList(state.org.data.activity.rows);
    var box = orgCard(t('app.what_happened'), 'i-layers');
    if (!rows.length) { box.appendChild(el('div', 'hint', t('app.nothing_yet'))); }
    rows.forEach(function (r) {
      var line = String(r.what) + ' · ' + String(r.by || '') + (r.member ? ' → ' + String(r.member) : '')
        + (Number(r.amount) > 0 ? ' · ' + money(Number(r.amount)) : '') + (r.model ? ' · ' + String(r.model) : '');
      box.appendChild(el('div', 'hint', line + (agoText(r.at) ? ' · ' + agoText(r.at) : '')));
    });
    view.appendChild(box);
  }

  function orgOpenCard(title, icon, text, label, screenId) {
    var box = orgCard(title, icon);
    box.appendChild(el('div', 'hint', text));
    var open = el('button', 'ghost', label);
    open.onclick = function () {
      state.org.screen = screenId;
      state.org.armed = null;
      render();
      loadOrgScreen(screenId);
    };
    var row = orgRow();
    row.appendChild(open);
    box.appendChild(row);
    return box;
  }

  function orgRecordCard(m) {
    var s = m.stats;
    if (!s) {
      var none = orgCard(t('app.your_record'), 'i-pencil');
      none.appendChild(el('div', 'hint', t('app.not_kept_yet')));
      return none;
    }
    var box = orgCard(t('app.your_record'), 'i-pencil');
    box.appendChild(el('div', 'target', t('app.completed_failed', Number(s.completed) || 0, Number(s.failed) || 0)));
    box.appendChild(el('div', 'hint', t('app.earned_in_the_organisation') + money(Number(s.earned) || 0) + '.'));
    box.appendChild(el('div', 'hint', s.rate !== undefined && s.rate !== null
      ? t('app.reliability_rate', s.rate) : t('app.reliability_too_early_to_say')));
    if (s.band) { box.appendChild(el('div', 'hint', t('app.you_usually_finish_in') + String(s.band) + '.')); }
    if (s.rank) { box.appendChild(el('div', 'hint', s.of ? t('app.rank_of', s.rank, s.of) : t('app.rank_n', s.rank))); }
    if (s.leaderboard) {
      var open = el('button', 'ghost', t('app.leaderboard'));
      open.onclick = function () {
        state.org.screen = 'stats';
        state.org.armed = null;
        render();
        loadOrgScreen('stats');
      };
      var row = orgRow();
      row.appendChild(open);
      box.appendChild(row);
    }
    return box;
  }

  function orgDisciplineCard(d) {
    var box = orgCard(t('app.discipline'), 'i-shield');
    var strikes = Number(d.strikes) || 0;
    var warnings = Number(d.warnings) || 0;
    box.appendChild(el('div', 'hint', (strikes || warnings)
      ? t('app.discipline_summary', tn('app.strikes_standing', strikes), tn('app.written_warnings', warnings),
        tn('app.days_count', Number(d.decayDays) || 30))
      : t('app.a_clean_record')));
    asList(d.rows).slice(0, 5).forEach(function (r) { box.appendChild(orgDisciplineLine(r)); });
    return box;
  }

  function orgDisciplineLine(r) {
    var line = el('div', 'org-discipline' + (r.overturned ? ' is-overturned' : ''));
    line.appendChild(el('div', 'target', (r.kind === 'strike' ? t('app.strike') : t('app.written_warning_2'))
      + (r.at ? ' · ' + agoText(r.at) : '') + (r.overturned ? t('app.overturned') : r.kind === 'strike' && !r.active
        ? t('app.no_longer_counts') : '')));
    line.appendChild(el('div', 'hint', String(r.reason || '')));
    if (r.consequence) { line.appendChild(el('div', 'hint org-warn', t('app.then_consequence', String(r.consequence)))); }
    return line;
  }

  /* The leaderboard: bands, never exact times; money only for M10. */
  function orgStatsScreen(view) {
    if (orgPending(view, 'stats')) { return; }
    var d = state.org.data.stats;
    var rows = asList(d.rows);
    var box = orgCard(t('app.leaderboard'), 'i-users');
    box.appendChild(el('div', 'hint', t('app.by_completions_then_reliability_times_are')));
    if (!rows.length) { box.appendChild(el('div', 'hint', t('app.nobody_is_counted_yet'))); }
    rows.forEach(function (r) {
      var line = el('div', 'org-rank' + (r.mine ? ' is-mine' : ''));
      line.appendChild(el('div', 'target', '#' + (Number(r.rank) || 0) + ' ' + String(r.name || t('app.a_member'))
        + (r.role ? ' · ' + String(r.role) : '')));
      var bits = [t('app.n_completed', Number(r.completed) || 0)];
      if (d.full) { bits.push(t('app.n_failed', Number(r.failed) || 0), t('app.amount_earned', money(Number(r.earned) || 0))); }
      bits.push(r.rate !== undefined && r.rate !== null ? t('app.rate_reliable', r.rate) : t('app.too_early_to_say'));
      if (r.band) { bits.push(String(r.band)); }
      line.appendChild(el('div', 'hint', bits.join(' · ')));
      box.appendChild(line);
    });
    view.appendChild(box);
  }

  /* The armory: what it holds, what the member may put in and take out. */
  function orgArmoryScreen(view) {
    if (orgPending(view, 'armory')) { return; }
    var a = state.org.data.armory;
    if (a.atOffice && !a.here) {
      view.appendChild(el('div', 'hint org-office ico i-briefcase', t('app.items_go_in_and_out_at')
        + t('app.there_then_tap_refresh')));
    }
    var take = orgCard(t('app.in_the_armory'), 'i-box');
    take.appendChild(el('div', 'hint', t('app.you_may_take_more_today', Number(a.left) || 0,
      Number(a.manageLeft) > 0 ? t('app.and_beyond_that_as_a_boss', a.manageLeft) : '')));
    var items = asList(a.items);
    if (!items.length) { take.appendChild(el('div', 'hint', t('app.empty'))); }
    items.forEach(function (it) {
      var key = 'arm:out:' + it.slot;
      take.appendChild(el('div', 'target', String(it.label || it.name) + ' × ' + (Number(it.count) || 0)));
      take.appendChild(orgField(key, t('app.how_many'), 'number', '1'));
      var r = orgRow();
      r.appendChild(orgTwoTap('ghost', t('app.take'), key + ':go', t('app.tap_again_to_take_it'), function () {
        var n = orgNumber(key) || 1;
        orgWrite(key + ':go', function () { return post('orgArmoryTake', { slot: it.slot, count: n }); },
          t('app.taken'));
        orgRead('armory', function () { return post('orgArmory', {}); });
      }));
      take.appendChild(r);
    });
    view.appendChild(take);
    var put = orgCard(t('app.put_in'), 'i-plus');
    var own = asList(a.own);
    put.appendChild(el('div', 'hint', own.length ? t('app.items_of_yours_staff_allow_in')
      : t('app.you_carry_nothing_staff_allow_in')));
    own.forEach(function (it) {
      var key = 'arm:in:' + it.slot;
      put.appendChild(el('div', 'target', String(it.label || it.name) + ' × ' + (Number(it.count) || 0)));
      put.appendChild(orgField(key, t('app.how_many'), 'number', '1'));
      var r = orgRow();
      r.appendChild(orgTwoTap('ghost', t('app.put_in'), key + ':go', t('app.tap_again_to_put_it_in'), function () {
        var n = orgNumber(key) || 1;
        orgWrite(key + ':go', function () { return post('orgArmoryPut', { slot: it.slot, count: n }); },
          t('app.put_in_the_armory'));
        orgRead('armory', function () { return post('orgArmory', {}); });
      }));
      put.appendChild(r);
    });
    view.appendChild(put);
    if (orgHolds('A2')) {
      var lim = orgCard(t('app.limits_a_day'), 'i-lock');
      var most = Number(a.withdrawMax) || 0;
      lim.appendChild(el('div', 'hint', t('app.items_each_member_of_a_role') + most
        + t('app.0_is_none')));
      orgRoles().filter(function (r) { return r.editable; }).forEach(function (r) {
        var key = 'arm:lim:' + r.grade;
        lim.appendChild(orgField(key, t('app.label_now', String(r.label || r.name),
          Number((a.limits || {})[String(r.grade)]) || 0), 'number', '0'));
        var row = orgRow();
        row.appendChild(orgTwoTap('ghost', t('app.set'), key + ':go', t('app.tap_again_to_set_it'), function () {
          var n = orgNumber(key);
          if (n === null) { redraw(); return say(t('app.write_a_whole_number_0_for')); }
          orgWrite(key + ':go', function () { return post('orgArmoryLimit', { grade: r.grade, count: n }); },
            t('app.limit_set'));
          orgRead('armory', function () { return post('orgArmory', {}); });
        }, 'A2'));
        lim.appendChild(row);
      });
      view.appendChild(lim);
    }
    if (Array.isArray(a.log)) {
      var log = orgCard(t('app.log'), 'i-layers');
      if (!a.log.length) { log.appendChild(el('div', 'hint', t('app.nothing_moved_yet'))); }
      a.log.slice(0, 30).forEach(function (e) {
        log.appendChild(el('div', 'hint', (e.dir === 'in' ? 'In: ' : 'Out: ') + String(e.item) + ' × '
          + (Number(e.count) || 0) + ' · ' + String(e.who || t('app.a_member_2')) + (e.at ? ' · ' + agoText(e.at) : '')));
      });
      view.appendChild(log);
    }
  }

  /* The application form's questions (N4). */
  function orgRecruitingScreen(view) {
    var m = state.org.mine;
    var current = asList(m.recruitForm);
    var most = Number(m.recruitMax) || 0;
    var box = orgCard(t('app.questions'), 'i-pencil');
    box.appendChild(el('div', 'hint', t('app.an_applicant_answers_each_one_up') + most + t('app.leave_one_empty_to_drop_it')));
    for (var i = 0; i < most; i += 1) {
      var key = 'form.q' + i;
      if (state.org.form[key] === undefined && current[i] !== undefined) { state.org.form[key] = String(current[i]); }
      box.appendChild(orgField(key, t('app.question_n', i + 1), 'text', t('app.e_g_who_vouches_for_you'), 200));
    }
    var row = orgRow();
    row.appendChild(orgTwoTap('primary', t('app.save_the_form'), 'form:save', t('app.tap_again_to_save_it'), function () {
      var list = [];
      for (var j = 0; j < most; j += 1) {
        var q = orgText('form.q' + j);
        if (q) { list.push(q); }
      }
      orgWrite('form:save', function () { return post('orgRecruitForm', { questions: list }); },
        list.length ? t('app.form_saved') : t('app.form_cleared'));
    }));
    box.appendChild(row);
    view.appendChild(box);
  }

  /* ---- Organisation extras: duty, probation, assigned contracts, the
     channel (each drawn only while orgMine says its switch is on) ---- */

  function viewOrgExtras(view, m) {
    if (m.duty) {
      var duty = orgCard(t('app.duty'), 'i-clock');
      duty.appendChild(el('div', 'hint', m.duty.on
        ? t('app.you_are_on_duty_the_organisation')
        : t('app.you_are_off_duty_the_organisations')
          + (m.duty.atOffice ? t('app.you_go_on_duty_at_the') : '')));
      var dr = orgRow();
      dr.appendChild(orgTwoTap(m.duty.on ? 'ghost' : 'primary', m.duty.on ? t('app.go_off_duty') : t('app.go_on_duty'), 'duty',
        m.duty.on ? t('app.tap_again_to_go_off_duty') : t('app.tap_again_to_go_on_duty'), function () {
          var want = !m.duty.on;
          orgWrite('duty', function () { return post('orgDuty', { on: want }); },
            want ? t('app.on_duty') : t('app.off_duty'));
        }));
      duty.appendChild(dr);
      view.appendChild(duty);
    }
    if (m.probation) {
      var p = m.probation;
      var pro = orgCard(t('app.probation'), 'i-shield');
      pro.appendChild(el('div', 'hint', t('app.on_probation_worth', money(Number(p.maxReward) || 0),
        p.noStake ? t('app.none_with_a_stake') : '',
        Number(p.need) > 0 ? t('app.completions_of_or_signs_off', Number(p.done) || 0, p.need)
          : t('app.a_boss_signs_you_off'))));
      view.appendChild(pro);
    }
    asList(m.waiting).forEach(function (w) {
      var wait = orgCard(t('app.waiting_for_approval'), 'i-clock');
      wait.appendChild(el('div', 'hint', t('app.your_accept_of') + String(w.contractId || t('app.a_contract'))
        + t('app.waits_for_a_boss_nothing_is')
        + durationText(Math.max(1, Math.ceil((Number(w.expiresIn) || 0) / 60))) + t('app.left')));
      view.appendChild(wait);
    });
    if (m.orgContracts && Array.isArray(m.assigned)) {
      var mine = orgCard(t('app.assigned_to_you'), 'i-crosshair');
      if (!m.assigned.length) {
        mine.appendChild(el('div', 'hint', t('app.nothing_assigned_to_you_right_now')));
      }
      m.assigned.forEach(function (a) {
        var row = el('div', 'org-assigned');
        row.appendChild(el('div', 'target', String(a.targetName || t('app.a_contract_2')) + ' · ' + String(a.id || '')));
        row.appendChild(el('div', 'hint', a.state === 'taken' ? t('app.you_hold_it')
          : t('app.take_it_from_the_board_within') + durationText(Math.max(1, Math.ceil((Number(a.expiresIn) || 0) / 60)))
            + t('app.or_it_goes_on_the_open')));
        if (a.dossier) { row.appendChild(orgDossierView(a.dossier)); }
        mine.appendChild(row);
      });
      view.appendChild(mine);
    } else if (m.orgContracts && m.dutyOn && m.duty && !m.duty.on) {
      var off = orgCard(t('app.assigned_to_you'), 'i-crosshair');
      off.appendChild(el('div', 'hint', t('app.go_on_duty_to_see_what')));
      view.appendChild(off);
    }
    if (m.channel) {
      var ch = orgCard(t('app.channel'), 'i-flag');
      ch.appendChild(el('div', 'hint', m.channelMuted ? t('app.a_boss_muted_you_for_now')
        : t('app.the_organisations_own_messages_plain_text')));
      var open = el('button', 'ghost', t('app.open_channel'));
      open.onclick = function () {
        state.org.screen = 'channel';
        state.org.armed = null;
        render();
        loadOrgScreen('channel');
      };
      var cr = orgRow();
      cr.appendChild(open);
      ch.appendChild(cr);
      view.appendChild(ch);
    }
  }

  function orgDossierView(d) {
    var box = el('div', 'org-dossier');
    box.appendChild(el('div', 'hint', t('app.dossier')));
    if (d.notes) { box.appendChild(el('div', 'org-notice', String(d.notes))); }
    if (d.spot) { box.appendChild(el('div', 'hint', t('app.meet_at') + String(d.spot.label || t('app.a_meeting_spot')))); }
    if (d.rulesText) { box.appendChild(el('div', 'hint', t('app.rules_of_engagement') + String(d.rulesText))); }
    return box;
  }

  /* Contracts sent to the organisation, and accepts waiting for approval. */
  function orgWorkScreen(view) {
    if (orgPending(view, 'work')) { return; }
    var w = state.org.data.work;
    var members = asList(w.members).map(function (x) {
      return { value: x.ref, label: String(x.name || t('app.a_member')) + (x.onDuty === false ? t('app.off_duty_2') : '')
        + (x.probation ? ' (probation)' : '') };
    });
    if (Array.isArray(w.approvals) && orgHolds('K6')) {
      var ap = orgCard(t('app.accepts_waiting'), 'i-usercheck');
      if (!w.approvals.length) { ap.appendChild(el('div', 'hint', t('app.no_accept_waits_for_approval'))); }
      w.approvals.forEach(function (a) {
        var key = 'ap:' + a.id;
        ap.appendChild(el('div', 'target', String(a.member && a.member.name || t('app.a_member')) + ' · '
          + String(a.contractId || '')));
        ap.appendChild(el('div', 'hint', t('app.worth_about_left', money(Number(a.worth) || 0),
          a.probation ? t('app.on_probation') : '', durationText(Math.max(1, Math.ceil((Number(a.expiresIn) || 0) / 60))))));
        if (!a.own) {
          var r = orgRow();
          r.appendChild(orgTwoTap('primary', t('app.approve'), key + ':yes', t('app.tap_again_to_approve'), function () {
            orgWrite(key + ':yes', function () { return post('orgApprove', { id: a.id, approve: true }); },
              t('app.approved_the_accept_ran'));
          }));
          r.appendChild(orgTwoTap('ghost', t('app.refuse'), key + ':no', t('app.tap_again_to_refuse'), function () {
            orgWrite(key + ':no', function () { return post('orgApprove', { id: a.id, approve: false }); },
              t('app.refused_nothing_was_taken'));
          }));
          ap.appendChild(r);
        }
      });
      view.appendChild(ap);
    }
    if (!Array.isArray(w.contracts)) { return; }
    var list = orgCard(t('app.sent_to_the_organisation'), 'i-crosshair');
    list.appendChild(el('div', 'hint', t('app.who_placed_them_is_never_shown')));
    if (!w.contracts.length) { list.appendChild(el('div', 'hint', t('app.none_waiting'))); }
    view.appendChild(list);
    w.contracts.forEach(function (c) {
      var key = 'wc:' + c.id + ':';
      var box = orgCard(String(c.targetName || t('app.a_contract_2')) + ' · ' + String(c.id), 'i-crosshair');
      box.appendChild(el('div', 'hint', t('app.worth_state', money(Number(c.worth) || 0),
        c.staked ? t('app.staked_suffix') : '',
        c.state === 'waiting' ? t('app.not_assigned_yet') : c.state === 'taken'
          ? t('app.taken_by_x', String(c.member && c.member.name || t('app.a_member_2')))
          : t('app.assigned_to_x', String(c.member && c.member.name || t('app.a_member_2'))),
        c.expiresIn ? t('app.about_left', durationText(Math.max(1, Math.ceil(Number(c.expiresIn) / 60)))) : '')));
      var canAssign = c.state === 'waiting' ? orgHolds('K4') : c.state === 'assigned' && orgHolds('K5');
      if (canAssign && members.length) {
        box.appendChild(orgChoice(key + 'member', members, undefined));
        var ra = orgRow();
        ra.appendChild(orgTwoTap('primary', c.state === 'waiting' ? t('app.assign') : t('app.reassign'), key + 'assign',
          t('app.tap_again_to_assign_it'), function () {
            var who = orgChosen(key + 'member', undefined);
            if (who === undefined) { return say(t('app.pick_the_member_first')); }
            orgWrite(key + 'assign', function () { return post('orgAssign', { id: c.id, member: who }); },
              t('app.assigned'));
          }));
        box.appendChild(ra);
      }
      if (c.state !== 'taken' && orgHolds('K5')) {
        var rr = orgRow();
        rr.appendChild(orgTwoTap('ghost', t('app.send_to_the_open_board'), key + 'release', t('app.tap_again_to_send_it'),
          function () {
            orgWrite(key + 'release', function () { return post('orgRelease', { id: c.id }); },
              t('app.on_the_open_board'));
          }));
        box.appendChild(rr);
      }
      if (c.dossier) { box.appendChild(orgDossierView(c.dossier)); }
      if (c.state !== 'waiting' && orgHolds('K7') && Array.isArray(w.rules)) {
        box.appendChild(orgField(key + 'notes', t('app.dossier_notes'), 'area', t('app.plain_text_no_citizen_ids'), 2000));
        var spots = asList(w.spots).map(function (sp) { return { value: sp.id, label: String(sp.label || t('app.spot')) }; });
        if (spots.length) {
          box.appendChild(el('div', 'hint', t('app.meeting_spot')));
          box.appendChild(orgChoice(key + 'spot', spots, undefined));
        }
        box.appendChild(el('div', 'hint', t('app.rules_of_engagement_2')));
        box.appendChild(orgChoice(key + 'rules', w.rules.map(function (r) {
          return { value: r.value, label: String(r.label) };
        }), undefined));
        var rd = orgRow();
        rd.appendChild(orgTwoTap('ghost', t('app.save_dossier'), key + 'dossier', t('app.tap_again_to_save_it'), function () {
          var data = { id: c.id };
          var notes = orgText(key + 'notes');
          var spot = orgChosen(key + 'spot', undefined);
          var rules = orgChosen(key + 'rules', undefined);
          if (notes) { data.notes = notes; }
          if (spot !== undefined) { data.spot = spot; }
          if (rules !== undefined) { data.rules = rules; }
          if (!notes && spot === undefined && rules === undefined) {
            return say(t('app.write_notes_or_pick_a_spot'));
          }
          orgWrite(key + 'dossier', function () { return post('orgDossier', data); }, t('app.dossier_saved'));
        }));
        if (c.dossier) {
          rd.appendChild(orgTwoTap('ghost', t('app.clear_dossier'), key + 'dclear', t('app.tap_again_to_clear_it'), function () {
            orgWrite(key + 'dclear', function () { return post('orgDossier', { id: c.id, clear: true }); },
              t('app.dossier_cleared'));
          }));
        }
        box.appendChild(rd);
      }
      view.appendChild(box);
    });
  }

  /* The organisation's own channel: plain text, two taps to send. */
  function orgChannelScreen(view) {
    if (orgPending(view, 'channel')) { return; }
    var c = state.org.data.channel;
    var box = orgCard(t('app.messages'), 'i-flag');
    var rows = asList(c.rows);
    if (!rows.length) { box.appendChild(el('div', 'hint', t('app.no_messages_yet'))); }
    var moderate = orgHolds('N3');
    rows.forEach(function (r) {
      var line = el('div', 'org-message' + (r.mine ? ' is-mine' : ''));
      line.appendChild(el('div', 'hint', String(r.from || t('app.a_member')) + (r.at ? ' · ' + agoText(r.at) : '')));
      line.appendChild(el('div', 'org-notice', String(r.body || '')));
      if (moderate && !r.mine) {
        var key = 'msg:' + r.id + ':';
        var mr = orgRow();
        mr.appendChild(orgTwoTap('ghost', t('app.remove'), key + 'rm', t('app.tap_again_to_remove_it'), function () {
          orgWrite(key + 'rm', function () { return post('orgChannelRemove', { id: r.id }); }, t('app.removed'));
        }));
        if (r.member) {
          mr.appendChild(orgTwoTap('ghost', t('app.mute_hours', orgBound('ChannelMuteMaxHours') || 1), key + 'mute',
            t('app.tap_again_to_mute_them'), function () {
              orgWrite(key + 'mute', function () {
                return post('orgChannelMute', { member: r.member, hours: orgBound('ChannelMuteMaxHours') || 1 });
              }, t('app.muted'));
            }));
        }
        line.appendChild(mr);
      }
      box.appendChild(line);
    });
    view.appendChild(box);
    if (c.muted) {
      view.appendChild(el('div', 'hint org-warn', t('app.a_boss_muted_you_for_now')));
      return;
    }
    var send = orgCard(t('app.write'), 'i-pencil');
    send.appendChild(orgField('channel.text', t('app.message'), 'area', t('app.plain_text_no_links'), Number(c.maxLength) || 300));
    var sr = orgRow();
    sr.appendChild(orgTwoTap('primary', t('app.send'), 'channel:send', t('app.tap_again_to_send'), function () {
      var text = orgText('channel.text');
      if (!text) { return say(t('app.write_the_message_first')); }
      orgWrite('channel:send', function () {
        return post('orgChannelPost', { text: text }).then(function (r) {
          if (r && r.ok) { state.org.form['channel.text'] = ''; }
          return r;
        });
      }, t('app.sent'));
    }));
    send.appendChild(sr);
    view.appendChild(send);
  }

  /* ---- Members: hire, and each member's actions by the powers held ---- */

  function orgMembersScreen(view) {
    if (orgHolds('M2')) {
      var hire = orgCard(t('app.hire'), 'i-usercheck');
      var radius = orgBound('HireRadius');
      hire.appendChild(el('div', 'hint', t('app.invite_a_player_standing_beside_you')
        + (radius ? t('app.within_metres', radius) : '') + t('app.by_the_id_over_their_head')));
      var office = orgOfficeNote('M2');
      if (office) { hire.appendChild(office); }
      hire.appendChild(orgField('hire.target', t('app.their_id'), 'number', 'e.g. 42'));
      var maxGrade = orgBound('HireMaxGrade');
      var options = orgRoleOptions(true, maxGrade);
      if (options.length) {
        hire.appendChild(el('div', 'hint', t('app.role')));
        hire.appendChild(orgChoice('hire.grade', options, options[options.length - 1].value));
      }
      var row = orgRow();
      row.appendChild(orgTwoTap('primary', t('app.invite'), 'hire', t('app.tap_again_to_invite'), function () {
        var target = orgNumber('hire.target');
        if (!target) { return say(t('app.write_their_id_the_number_over')); }
        var grade = orgChosen('hire.grade', options.length ? options[options.length - 1].value : undefined);
        orgWrite('hire', function () {
          return post('orgHire', grade === undefined ? { target: target } : { target: target, grade: grade });
        }, t('app.invited_they_have_a_while_to'));
      }, 'M2'));
      hire.appendChild(row);
      view.appendChild(hire);
    }
    if (!orgHolds('M1')) {
      view.appendChild(el('div', 'hint', t('app.the_member_list_needs_view_members')));
      return;
    }
    if (orgPending(view, 'members')) { return; }
    var rows = orgMembers();
    if (!rows.length) { view.appendChild(el('div', 'empty', t('app.no_members'))); return; }
    rows.forEach(function (m) { view.appendChild(orgMemberCard(m)); });
  }

  function orgMemberCard(m) {
    var open = state.org.open.member === m.ref;
    var box = el('div', 'card org-card org-member');
    var head = el('button', 'ghost org-row', String(m.name || t('app.a_member')) + ' · ' + String(m.role || ''));
    head.onclick = function () { state.org.open.member = open ? null : m.ref; state.org.armed = null; render(); };
    box.appendChild(head);
    var meta = el('div', 'meta');
    meta.appendChild(chip(m.online ? t('app.in_the_city') : t('app.away'), 'plain', 'i-user'));
    if (m.boss) { meta.appendChild(chip(t('app.boss'), 'role', 'i-shield')); }
    if (m.suspendedUntil) { meta.appendChild(chip(t('app.suspended'), 'hot', 'i-clock')); }
    if (m.locked) { meta.appendChild(chip(t('app.locked_by_staff'), 'plain', 'i-lock')); }
    if (m.onDuty === true) { meta.appendChild(chip(t('app.on_duty_2'), 'role', 'i-clock')); }
    if (m.probation) { meta.appendChild(chip(t('app.probation'), 'plain', 'i-shield')); }
    if (m.channelMuted) { meta.appendChild(chip(t('app.muted_2'), 'plain', 'i-flag')); }
    if (Number(m.strikes) > 0) {
      meta.appendChild(chip(tn('app.strikes', Number(m.strikes)), 'hot', 'i-shield'));
    }
    box.appendChild(meta);
    if (!open) { return box; }
    var key = 'm:' + m.ref + ':';

    /* Their record in full (M11 or M5, as the server checks): the entries,
       reasons and overturns behind the strike chip. A read, so one tap. */
    if (orgHolds('M11') || orgHolds('M5')) {
      var shown = state.org.open.record && state.org.open.record.ref === m.ref ? state.org.open.record.data : null;
      var rr = orgRow();
      rr.appendChild(actionButton('ghost ico i-shield', shown ? t('app.hide_the_record') : t('app.discipline_record'),
        'org:record:' + m.ref, t('app.sending'), function () {
          if (shown) { state.org.open.record = null; render(); return Promise.resolve(); }
          return post('orgDisciplineRecord', { member: m.ref }).then(function (r) {
            if (r && r.ok) { state.org.open.record = { ref: m.ref, data: r.data || {} }; render(); } else { fail(r); }
          });
        }));
      box.appendChild(rr);
      if (shown) {
        var entries = asList(shown.rows);
        if (!entries.length) { box.appendChild(el('div', 'hint', t('app.nothing_on_their_record'))); }
        entries.forEach(function (r) { box.appendChild(orgDisciplineLine(r)); });
      }
    }

    if (orgHolds('M11')) {
      box.appendChild(orgField(key + 'dreason', t('app.reason_for_a_strike_or_warning'), 'text', t('app.what_they_did'), 200));
      var r11 = orgRow();
      [['strike', t('app.strike'), 'danger'], ['warning', t('app.written_warning_2'), 'ghost']].forEach(function (k) {
        r11.appendChild(orgTwoTap(k[2], k[1], key + 'disc:' + k[0], t('app.tap_again') + k[1].toLowerCase(), function () {
          var reason = orgText(key + 'dreason');
          if (!reason) { redraw(); return say(t('app.give_a_reason')); }
          orgWrite(key + 'disc:' + k[0], function () {
            return post('orgStrike', { member: m.ref, kind: k[0], reason: reason }).then(function (r) {
              if (r && r.ok) { state.org.form[key + 'dreason'] = ''; }
              return r;
            });
          }, function (r) {
            var c = r && r.data && r.data.consequence;
            return (k[0] === 'strike' ? t('app.strike_given') : t('app.warning_given')) + (c ? t('app.then_x', c) : '');
          });
        }, 'M11'));
      });
      box.appendChild(r11);
    }

    if (orgHolds('M4')) {
      var roles = orgRoleOptions(true);
      box.appendChild(el('div', 'hint', t('app.role')));
      if (roles.length) { box.appendChild(orgChoice(key + 'grade', roles, m.grade)); }
      var r1 = orgRow();
      r1.appendChild(orgTwoTap('ghost', t('app.set_role'), key + 'role', t('app.tap_again_to_set_the_role'), function () {
        var grade = orgChosen(key + 'grade', m.grade);
        orgWrite(key + 'role', function () { return post('orgSetRole', { member: m.ref, grade: grade }); },
          t('app.role_set'));
      }, 'M4'));
      box.appendChild(r1);
      var note4 = orgOfficeNote('M4');
      if (note4) { box.appendChild(note4); }
    }
    if (orgHolds('M7')) {
      box.appendChild(orgField(key + 'codename', t('app.codename'), 'text', m.codename || t('app.letters_and_digits'), 32));
      var r7 = orgRow();
      r7.appendChild(orgTwoTap('ghost', t('app.give_codename'), key + 'codename', t('app.tap_again_to_give_it'), function () {
        var name = orgText(key + 'codename');
        if (!name) { return say(t('app.write_the_codename_first')); }
        orgWrite(key + 'codename', function () {
          return post('orgCodename', { member: m.ref, codename: name });
        }, t('app.codename_given'));
      }, 'M7'));
      box.appendChild(r7);
    }
    if (orgHolds('M8') && m.probation) {
      box.appendChild(el('div', 'hint', t('app.on_probation_of', Number(m.probation.done) || 0,
        Number(m.probation.need) || 0)));
      var r8 = orgRow();
      r8.appendChild(orgTwoTap('ghost', t('app.end_probation'), key + 'probation', t('app.tap_again_to_end_it'), function () {
        orgWrite(key + 'probation', function () { return post('orgProbationEnd', { member: m.ref }); },
          t('app.probation_ended'));
      }, 'M8'));
      box.appendChild(r8);
    }
    if (orgHolds('M9') && m.onDuty === true) {
      var r9 = orgRow();
      r9.appendChild(orgTwoTap('ghost', t('app.send_off_duty'), key + 'offduty', t('app.tap_again_to_send_them_off'),
        function () {
          orgWrite(key + 'offduty', function () { return post('orgForceOff', { member: m.ref }); }, t('app.off_duty'));
        }, 'M9'));
      box.appendChild(r9);
    }
    if (orgHolds('M5')) {
      var maxH = orgBound('SuspendMaxHours');
      box.appendChild(orgField(key + 'hours', t('app.suspend_for_hours') + (maxH !== null ? t('app.up_to') + maxH : '')
        + t('app.0_lifts_it'), 'number', '0'));
      box.appendChild(orgField(key + 'sreason', t('app.reason'), 'text', t('app.why'), 160));
      var r5 = orgRow();
      r5.appendChild(orgTwoTap('ghost', t('app.suspend'), key + 'suspend', t('app.tap_again_to_suspend'), function () {
        var hours = orgNumber(key + 'hours');
        if (hours === null) { return say(t('app.write_the_hours_a_whole_number')); }
        orgWrite(key + 'suspend', function () {
          return post('orgSuspend', { member: m.ref, hours: hours, reason: orgText(key + 'sreason') });
        }, hours > 0 ? t('app.suspended_from_contracts') : t('app.suspension_lifted'));
      }, 'M5'));
      box.appendChild(r5);
    }
    if (orgHolds('M6')) {
      box.appendChild(orgField(key + 'atonce', t('app.contracts_at_once') + (orgBound('MemberMaxAtOnce') !== null
        ? t('app.up_to_2') + orgBound('MemberMaxAtOnce') + ')' : ''), 'number', t('app.no_limit')));
      box.appendChild(orgField(key + 'cooldown', t('app.minutes_between_accepts') + (orgBound('MemberCooldownMaxMinutes')
        !== null ? t('app.up_to_2') + orgBound('MemberCooldownMaxMinutes') + ')' : ''), 'number', 'none'));
      var r6 = orgRow();
      r6.appendChild(orgTwoTap('ghost', t('app.set_limits'), key + 'limits', t('app.tap_again_to_set_the_limits'), function () {
        var data = { member: m.ref };
        var atOnce = orgNumber(key + 'atonce');
        var cooldown = orgNumber(key + 'cooldown');
        if (atOnce !== null) { data.maxAtOnce = atOnce; }
        if (cooldown !== null) { data.cooldownMinutes = cooldown; }
        orgWrite(key + 'limits', function () { return post('orgMemberLimits', data); }, t('app.limits_set'));
      }, 'M6'));
      box.appendChild(r6);
    }
    if (orgHolds('D2')) { box.appendChild(orgGrantsFor(m, key)); }
    if (orgHolds('M3')) {
      box.appendChild(orgField(key + 'freason', t('app.reason_for_firing'), 'text', t('app.why'), 160));
      var r3 = orgRow();
      r3.appendChild(orgTwoTap('danger', t('app.fire'), key + 'fire', t('app.tap_again_to_fire') + String(m.name || 'them'),
        function () {
          var reason = orgText(key + 'freason');
          if (!reason) { return say(t('app.give_a_reason_for_firing_them')); }
          state.org.open.member = null;
          orgWrite(key + 'fire', function () { return post('orgFire', { member: m.ref, reason: reason }); },
            t('app.fired'));
        }, 'M3'));
      box.appendChild(r3);
      var note3 = orgOfficeNote('M3');
      if (note3) { box.appendChild(note3); }
    }
    return box;
  }

  /* The powers this boss holds, each grantable or deniable to a member
     below them; any other is shown greyed, as staff not having given it. */
  function orgPowerList() {
    var names = state.org.mine && state.org.mine.powerNames;
    var out = [];
    if (!names) { return out; }
    Object.keys(names).sort().forEach(function (code) {
      var p = names[code] || {};
      if (p.feature === 'Codenames' && !state.org.mine.codenames) { return; }
      if (p.feature === 'Payroll' && !state.org.mine.payroll) { return; }
      out.push({ code: code, label: String(p.label || code), held: code === 'TAKE' || orgHolds(code) });
    });
    return out;
  }

  function orgGrantsFor(m, key) {
    var wrap = el('div', 'org-powers');
    wrap.appendChild(el('div', 'hint', t('app.their_own_powers_grant_or_deny')));
    orgPowerList().forEach(function (p) {
      var line = el('div', 'org-power');
      line.appendChild(el('div', p.held ? 'org-power-name' : 'org-power-name org-grey', p.label));
      if (!p.held) {
        line.appendChild(el('div', 'hint', t('app.staff_have_not_given_you_this')));
        wrap.appendChild(line);
        return;
      }
      var row = orgRow();
      [['grant', t('app.grant')], ['deny', t('app.deny')], ['clear', t('app.clear')]].forEach(function (pair) {
        row.appendChild(orgTwoTap('ghost', pair[1], key + 'g:' + p.code + ':' + pair[0], t('app.tap_again') + pair[0],
          function () {
            orgWrite(key + 'g:' + p.code + ':' + pair[0], function () {
              return post('orgMemberGrant', { member: m.ref, power: p.code, state: pair[0] });
            }, t('app.saved'));
          }));
      });
      line.appendChild(row);
      wrap.appendChild(line);
    });
    return wrap;
  }

  /* ---- Roles: create, edit, delete, powers, pay, salary ---- */

  function orgRolesScreen(view) {
    if (orgPending(view, 'roles')) { return; }
    if (orgHolds('R1')) {
      var create = orgCard(t('app.new_role'), 'i-plus');
      var noteR1 = orgOfficeNote('R1');
      if (noteR1) { create.appendChild(noteR1); }
      create.appendChild(orgField('role.grade', t('app.rank_a_number_below_yours'), 'number', '1'));
      create.appendChild(orgField('role.label', t('app.name'), 'text', t('app.runner'), 64));
      create.appendChild(orgField('role.pay', t('app.pay_per_pay_cycle') + (orgBound('PayMax') !== null
        ? t('app.up_to') + money(orgBound('PayMax')) : '') + ')', 'number', '0'));
      var rc = orgRow();
      rc.appendChild(orgTwoTap('primary', t('app.create_role'), 'role:create', t('app.tap_again_to_create_it'), function () {
        var grade = orgNumber('role.grade');
        var label = orgText('role.label');
        if (grade === null || !label) { return say(t('app.give_the_role_a_rank_and')); }
        var name = label.toLowerCase().replace(/[^a-z0-9_]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 32) || 'role';
        orgWrite('role:create', function () {
          return post('orgRoleCreate', { grade: grade, name: name, label: label, pay: orgNumber('role.pay') || 0 });
        }, t('app.role_created'));
      }, 'R1'));
      create.appendChild(rc);
      view.appendChild(create);
    }
    orgRoles().forEach(function (r) { view.appendChild(orgRoleCard(r)); });
  }

  function orgRoleCard(r) {
    var open = state.org.open.role === r.grade;
    var box = el('div', 'card org-card org-role');
    var head = el('button', 'ghost org-row', String(r.label || r.name) + t('app.rank') + r.grade);
    head.onclick = function () { state.org.open.role = open ? null : r.grade; state.org.armed = null; render(); };
    box.appendChild(head);
    var meta = el('div', 'meta');
    meta.appendChild(chip(tn('app.members_count', Number(r.members) || 0), 'plain', 'i-users'));
    meta.appendChild(chip(t('app.pay_amount', money(Number(r.pay) || 0)), 'plain', 'i-coin'));
    if (r.salary !== undefined && r.salary !== null) {
      meta.appendChild(chip(t('app.salary_amount', money(Number(r.salary) || 0)), 'plain', 'i-coin'));
    }
    if (r.boss) { meta.appendChild(chip(t('app.boss_role'), 'role', 'i-shield')); }
    box.appendChild(meta);
    if (!open) { return box; }
    if (!r.editable) {
      box.appendChild(el('div', 'hint', r.locked ? ERRORS.org_locked : t('app.at_or_above_your_rank_only')));
      return box;
    }
    var key = 'r:' + r.grade + ':';
    if (orgHolds('R2')) {
      box.appendChild(orgField(key + 'label', t('app.name'), 'text', String(r.label || ''), 64));
      var r2 = orgRow();
      r2.appendChild(orgTwoTap('ghost', t('app.rename'), key + 'edit', t('app.tap_again_to_rename'), function () {
        var label = orgText(key + 'label');
        if (!label) { return say(t('app.write_the_new_name')); }
        orgWrite(key + 'edit', function () { return post('orgRoleEdit', { grade: r.grade, label: label }); },
          t('app.renamed'));
      }, 'R2'));
      box.appendChild(r2);
    }
    if (orgHolds('P1')) {
      box.appendChild(orgField(key + 'pay', t('app.pay_per_pay_cycle') + (orgBound('PayMax') !== null
        ? t('app.up_to') + money(orgBound('PayMax')) : '') + ')', 'number', String(Number(r.pay) || 0)));
      var rp = orgRow();
      rp.appendChild(orgTwoTap('ghost', t('app.set_pay'), key + 'pay', t('app.tap_again_to_set_the_pay'), function () {
        var pay = orgNumber(key + 'pay');
        if (pay === null) { return say(t('app.write_the_pay_as_a_whole')); }
        orgWrite(key + 'pay', function () { return post('orgRolePay', { grade: r.grade, pay: pay }); }, t('app.pay_set'));
      }, 'P1'));
      box.appendChild(rp);
    }
    if (orgHolds('P3')) {
      box.appendChild(orgField(key + 'salary', t('app.salary_every_pay_day') + (typeof r.salaryMax === 'number'
        ? t('app.up_to') + money(r.salaryMax) : '') + ')', 'number', String(Number(r.salary) || 0)));
      if (typeof r.salaryNext === 'number') {
        box.appendChild(el('div', 'hint', t('app.changing_to') + money(r.salaryNext) + t('app.from_the_pay_day_after_next')));
      }
      var rs = orgRow();
      rs.appendChild(orgTwoTap('ghost', t('app.set_salary'), key + 'salary', t('app.tap_again_to_set_the_salary'), function () {
        var amount = orgNumber(key + 'salary');
        if (amount === null) { return say(t('app.write_the_salary_as_a_whole')); }
        orgWrite(key + 'salary', function () { return post('orgSalary', { grade: r.grade, amount: amount }); },
          t('app.salary_set_a_change_takes_effect'));
      }, 'P3'));
      box.appendChild(rs);
    }
    if (orgHolds('R4')) {
      var powers = el('div', 'org-powers');
      powers.appendChild(el('div', 'hint', t('app.powers_of_this_role_give_or')));
      var noteR4 = orgOfficeNote('R4');
      if (noteR4) { powers.appendChild(noteR4); }
      var has = r.powers || {};
      orgPowerList().forEach(function (p) {
        var line = el('div', 'org-power');
        var on = !!has[p.code];
        line.appendChild(el('div', p.held ? 'org-power-name' : 'org-power-name org-grey',
          p.label + (on ? t('app.given') : '')));
        if (!p.held) {
          line.appendChild(el('div', 'hint', t('app.staff_have_not_given_you_this')));
        } else {
          var row = orgRow();
          row.appendChild(orgTwoTap('ghost', on ? t('app.take') : t('app.give'), key + 'p:' + p.code,
            on ? t('app.tap_again_to_take_it') : t('app.tap_again_to_give_it'), function () {
              orgWrite(key + 'p:' + p.code, function () {
                return post('orgRolePowers', { grade: r.grade, power: p.code, on: !on });
              }, on ? t('app.taken_from_the_role') : t('app.given_to_the_role'));
            }, 'R4'));
          line.appendChild(row);
        }
        powers.appendChild(line);
      });
      box.appendChild(powers);
    }
    if (orgHolds('R3')) {
      var r3 = orgRow();
      r3.appendChild(orgTwoTap('danger', t('app.delete_role'), key + 'delete', t('app.tap_again_to_delete_it'), function () {
        state.org.open.role = null;
        orgWrite(key + 'delete', function () { return post('orgRoleDelete', { grade: r.grade }); }, t('app.role_deleted'));
      }, 'R3'));
      box.appendChild(r3);
      if (Number(r.members) > 0) { box.appendChild(el('div', 'hint', t('app.only_an_empty_role_can_be'))); }
    }
    return box;
  }

  /* ---- Money: the funds, deposits, withdrawals, bonuses and cuts ---- */

  function orgMoneyScreen(view) {
    if (orgHolds('C8')) {
      var funds = orgCard(t('app.funds'), 'i-coin');
      if (!orgPending(funds, 'funds')) {
        var f = state.org.data.funds;
        funds.appendChild(el('div', 'target', f.ready === false ? t('app.not_available_right_now')
          : money(Number(f.balance) || 0)));
        var rows = asList(f.rows);
        if (!rows.length) { funds.appendChild(el('div', 'hint', t('app.nothing_moved_yet'))); }
        rows.slice(0, 20).forEach(function (row) {
          var amount = Number(row.amount) || 0;
          funds.appendChild(el('div', 'hint org-ledger', (amount < 0 ? '−' : '+') + money(Math.abs(amount))
            + ' · ' + String(row.kind || '') + (row.reason ? ' · ' + String(row.reason) : '')
            + (row.created_at ? ' · ' + (agoText(row.created_at) || '') : '')));
        });
      }
      view.appendChild(funds);
    }
    if (orgHolds('C6')) {
      var dep = orgCard(t('app.deposit'), 'i-coin');
      dep.appendChild(orgField('dep.amount', t('app.amount_2'), 'number', '0'));
      dep.appendChild(orgChoice('dep.account', [{ value: 'bank', label: t('app.from_bank') },
        { value: 'cash', label: t('app.from_cash') }], 'bank'));
      var rd = orgRow();
      rd.appendChild(orgTwoTap('primary', t('app.deposit'), 'deposit', t('app.tap_again_to_deposit'), function () {
        var amount = orgNumber('dep.amount');
        if (!amount) { return say(t('app.write_an_amount_above_zero')); }
        var nonce = orgNonce();
        orgWrite('deposit', function () {
          return post('orgDeposit', { amount: amount, account: orgChosen('dep.account', 'bank'), nonce: nonce });
        }, t('app.deposited_into_the_funds'));
      }));
      dep.appendChild(rd);
      view.appendChild(dep);
    }
    if (orgHolds('C7')) {
      var wd = orgCard(t('app.withdraw'), 'i-coin');
      var noteC7 = orgOfficeNote('C7');
      if (noteC7) { wd.appendChild(noteC7); }
      wd.appendChild(orgField('wd.amount', t('app.amount_3') + (orgBound('WithdrawMax') !== null
        ? t('app.up_to') + money(orgBound('WithdrawMax')) : '') + ')', 'number', '0'));
      wd.appendChild(orgField('wd.reason', t('app.reason'), 'text', t('app.what_it_is_for'), 160));
      var rw = orgRow();
      rw.appendChild(orgTwoTap('primary', t('app.withdraw'), 'withdraw', t('app.tap_again_to_withdraw'), function () {
        var amount = orgNumber('wd.amount');
        var reason = orgText('wd.reason');
        if (!amount || !reason) { return say(t('app.write_an_amount_above_zero_and')); }
        var nonce = orgNonce();
        orgWrite('withdraw', function () {
          return post('orgWithdraw', { amount: amount, reason: reason, nonce: nonce });
        }, t('app.withdrawn_to_your_cash'));
      }, 'C7'));
      wd.appendChild(rw);
      view.appendChild(wd);
    }
    if (orgHolds('P2')) {
      var bonus = orgCard(t('app.bonus'), 'i-coin');
      var members = orgMemberOptions();
      if (!orgHolds('M1')) {
        bonus.appendChild(el('div', 'hint', t('app.picking_a_member_needs_view_members')));
      } else if (!members.length) {
        orgPending(bonus, 'members');
      } else {
        bonus.appendChild(orgChoice('bonus.member', members, undefined));
        bonus.appendChild(orgField('bonus.amount', t('app.amount_3') + (orgBound('BonusMax') !== null
          ? t('app.up_to') + money(orgBound('BonusMax')) : '') + ')', 'number', '0'));
        bonus.appendChild(orgField('bonus.reason', t('app.reason'), 'text', t('app.what_it_is_for'), 160));
        var rb = orgRow();
        rb.appendChild(orgTwoTap('primary', t('app.pay_bonus'), 'bonus', t('app.tap_again_to_pay_it'), function () {
          var who = orgChosen('bonus.member', undefined);
          var amount = orgNumber('bonus.amount');
          var reason = orgText('bonus.reason');
          if (!who || !amount || !reason) { return say(t('app.pick_a_member_write_an_amount')); }
          var nonce = orgNonce();
          orgWrite('bonus', function () {
            return post('orgBonus', { member: who, amount: amount, reason: reason, nonce: nonce });
          }, t('app.bonus_paid_to_their_bank'));
        }));
        bonus.appendChild(rb);
      }
      view.appendChild(bonus);
    }
    var cutKinds = [['C1', 'payout', t('app.organisation_cut_of_every_payout'), 'CutMaxPercent'],
      ['C4', 'stake', t('app.cut_of_a_stake_a_member'), 'StakeCutMaxPercent'],
      ['C5', 'buyout', t('app.cut_of_a_buyout_paid_to'), 'BuyoutCutMaxPercent']];
    cutKinds.forEach(function (k) {
      if (!orgHolds(k[0])) { return; }
      var box = orgCard(k[2], 'i-coin');
      var note = orgOfficeNote(k[0]);
      if (note) { box.appendChild(note); }
      var max = orgBound(k[3]);
      var total = orgBound('TotalCutCapPercent');
      var cap = max !== null && total !== null ? Math.min(max, total) : (max !== null ? max : total);
      box.appendChild(orgField('cut.' + k[1], t('app.percent') + (cap !== null ? t('app.zero_to', cap) : ''), 'number', '0'));
      box.appendChild(el('div', 'hint', t('app.contracts_already_accepted_keep_the_cut')));
      var row = orgRow();
      row.appendChild(orgTwoTap('ghost', t('app.set_cut'), 'cut:' + k[1], t('app.tap_again_to_set_the_cut'), function () {
        var pct = orgNumber('cut.' + k[1]);
        if (pct === null) { return say(t('app.write_a_whole_percent')); }
        orgWrite('cut:' + k[1], function () { return post('orgSetCut', { kind: k[1], percent: pct }); }, t('app.cut_set'));
      }, k[0]));
      box.appendChild(row);
      view.appendChild(box);
    });
    if (orgHolds('C2')) { view.appendChild(orgTargetCut('role')); }
    if (orgHolds('C3')) { view.appendChild(orgTargetCut('member')); }
  }

  function orgTargetCut(kind) {
    var code = kind === 'role' ? 'C2' : 'C3';
    var box = orgCard(kind === 'role' ? t('app.cut_by_role') : t('app.cut_for_one_member'), 'i-coin');
    var note = orgOfficeNote(code);
    if (note) { box.appendChild(note); }
    var options = kind === 'role' ? orgRoleOptions(true) : orgMemberOptions();
    if (kind === 'member' && !orgHolds('M1')) {
      box.appendChild(el('div', 'hint', t('app.picking_a_member_needs_view_members')));
      return box;
    }
    if (!options.length) {
      box.appendChild(el('div', 'hint', kind === 'role' ? t('app.no_role_below_yours') : t('app.no_member_to_pick_yet')));
      return box;
    }
    box.appendChild(orgChoice('tcut.' + kind, options, undefined));
    var cap = orgBound('CutMaxPercent');
    box.appendChild(orgField('tcut.' + kind + '.pct', t('app.percent') + (cap !== null ? t('app.zero_to', cap) : ''),
      'number', '0'));
    var row = orgRow();
    function send(percent, label) {
      var target = orgChosen('tcut.' + kind, undefined);
      if (target === undefined) { return say(kind === 'role' ? t('app.pick_a_role_first') : t('app.pick_a_member_first')); }
      var data = kind === 'role' ? { kind: 'role', grade: target, percent: percent }
        : { kind: 'member', member: target, percent: percent };
      orgWrite('tcut:' + kind, function () { return post('orgSetCut', data); }, label);
    }
    row.appendChild(orgTwoTap('ghost', t('app.set_cut'), 'tcut:' + kind + ':set', t('app.tap_again_to_set_the_cut'), function () {
      var pct = orgNumber('tcut.' + kind + '.pct');
      if (pct === null) { return say(t('app.write_a_whole_percent')); }
      send(pct, t('app.cut_set'));
    }, code));
    row.appendChild(orgTwoTap('ghost', t('app.use_the_default'), 'tcut:' + kind + ':clear', t('app.tap_again_to_clear_it'),
      function () { send(false, t('app.their_own_cut_cleared')); }, code));
    box.appendChild(row);
    return box;
  }

  /* ---- Contracts: access rules, boss picks, cooldowns ---- */

  function orgContractsScreen(view) {
    if (orgHolds('K1') || orgHolds('K3')) {
      if (orgPending(view, 'roles')) { return; }
    }
    var roles = orgRoleOptions(true);
    if (orgHolds('K1')) {
      var box = orgCard(t('app.who_may_take_what'), 'i-flag');
      box.appendChild(el('div', 'hint', t('app.only_ever_stricter_than_the_servers')));
      if (!roles.length) {
        box.appendChild(el('div', 'hint', t('app.no_role_below_yours')));
      } else {
        box.appendChild(orgChoice('acc.grade', roles, roles[0].value));
        box.appendChild(orgField('acc.maxReward', t('app.most_a_contract_may_pay_blank'), 'number', ''));
        box.appendChild(orgField('acc.maxAtOnce', t('app.contracts_at_once_blank_for_no'), 'number', ''));
        box.appendChild(el('div', 'hint', t('app.how_they_may_be_finished')));
        box.appendChild(orgChoice('acc.rule', [{ value: '', label: t('app.any') }, { value: 'alive', label: t('app.alive_only') },
          { value: 'either', label: t('app.either') }], ''));
        box.appendChild(el('div', 'hint', t('app.targets_on_whitelisted_jobs')));
        box.appendChild(orgChoice('acc.whitelisted', [{ value: true, label: t('app.allowed') },
          { value: false, label: t('app.not_allowed') }], true));
        var row = orgRow();
        row.appendChild(orgTwoTap('primary', t('app.save_rules'), 'access', t('app.tap_again_to_save_the_rules'), function () {
          var rules = {};
          var maxReward = orgNumber('acc.maxReward');
          var atOnce = orgNumber('acc.maxAtOnce');
          var rule = orgChosen('acc.rule', '');
          rules.maxReward = maxReward === null ? false : maxReward;
          rules.maxAtOnce = atOnce === null ? false : atOnce;
          rules.rule = rule ? rule : false;
          rules.whitelisted = orgChosen('acc.whitelisted', true) === true;
          var grade = orgChosen('acc.grade', roles[0].value);
          orgWrite('access', function () { return post('orgAccess', { grade: grade, rules: rules }); },
            t('app.rules_saved'));
        }));
        box.appendChild(row);
      }
      view.appendChild(box);
    }
    if (orgHolds('K3')) {
      var cd = orgCard(t('app.cooldown_between_accepts'), 'i-clock');
      if (!roles.length) {
        cd.appendChild(el('div', 'hint', t('app.no_role_below_yours')));
      } else {
        cd.appendChild(orgChoice('cd.grade', roles, roles[0].value));
        var cap = orgBound('MemberCooldownMaxMinutes');
        cd.appendChild(orgField('cd.minutes', t('app.minutes') + (cap !== null ? t('app.up_to_2') + cap + ')' : '')
          + t('app.blank_for_none'), 'number', ''));
        var rc = orgRow();
        rc.appendChild(orgTwoTap('ghost', t('app.set_cooldown'), 'cooldown', t('app.tap_again_to_set_it'), function () {
          var minutes = orgNumber('cd.minutes');
          var grade = orgChosen('cd.grade', roles[0].value);
          orgWrite('cooldown', function () {
            return post('orgRoleCooldown', { grade: grade, minutes: minutes === null ? false : minutes });
          }, t('app.cooldown_set'));
        }));
        cd.appendChild(rc);
      }
      view.appendChild(cd);
    }
    if (orgHolds('K2')) {
      var pick = orgCard(t('app.boss_pick'), 'i-crosshair');
      pick.appendChild(el('div', 'hint', t('app.pin_a_contract_on_the_board')
        + t('app.still_take_it_themselves')));
      pick.appendChild(orgField('pick.id', t('app.contract_id'), 'text', 'ct00000001', 64));
      var members = orgMemberOptions();
      if (members.length) { pick.appendChild(orgChoice('pick.member', members, undefined)); }
      var rp = orgRow();
      rp.appendChild(orgTwoTap('ghost', t('app.pin_it'), 'pick', t('app.tap_again_to_pin_it'), function () {
        var id = orgText('pick.id');
        var who = orgChosen('pick.member', undefined);
        if (!id) { return say(t('app.write_the_contracts_id')); }
        orgWrite('pick', function () {
          return post('orgPick', who === undefined ? { id: id } : { id: id, member: who });
        }, who === undefined ? t('app.pick_cleared') : t('app.pinned'));
      }));
      pick.appendChild(rp);
      view.appendChild(pick);
    }
  }

  /* ---- Places: the office, sign-up and meeting spots, set where they stand ---- */

  function orgPlacesScreen(view) {
    view.appendChild(el('div', 'hint', t('app.places_are_set_where_you_stand')
      + t('app.phone_sends_none')));
    [['L1', 'office', t('app.move_the_office_here'), t('app.tap_again_to_move_it_here')],
      ['L2', 'signup', t('app.put_a_sign_up_spot_here'), t('app.tap_again_to_put_it_here')],
      ['L3', 'meeting', t('app.add_a_meeting_spot_here'), t('app.tap_again_to_add_it_here')]].forEach(function (k) {
      if (!orgHolds(k[0])) { return; }
      var box = orgCard(ORG_SPOT_WORDS[k[1]], 'i-pin');
      if (k[1] !== 'office') { box.appendChild(orgField('spot.' + k[1], t('app.name'), 'text', ORG_SPOT_WORDS[k[1]], 64)); }
      if (k[1] === 'office' && orgBound('OfficeMoveMetres') !== null) {
        box.appendChild(el('div', 'hint', t('app.within_m_of_where_staff', orgBound('OfficeMoveMetres'))));
      }
      var note = orgOfficeNote(k[0]);
      if (note) { box.appendChild(note); }
      var row = orgRow();
      row.appendChild(orgTwoTap('primary', k[2], 'spot:' + k[1], k[3], function () {
        var label = orgText('spot.' + k[1]);
        orgWrite('spot:' + k[1], function () {
          return post('orgPlaceHere', label ? { kind: k[1], label: label } : { kind: k[1] });
        }, t('app.placed_where_you_stand'));
        orgRead('spots', function () { return post('orgSpots', {}); });
      }, k[0]));
      box.appendChild(row);
      view.appendChild(box);
    });
    if (orgPending(view, 'spots')) { return; }
    var rows = asList(state.org.data.spots.rows);
    if (!rows.length) { view.appendChild(el('div', 'empty', t('app.no_places_set'))); return; }
    rows.forEach(function (s) {
      var box = el('div', 'card org-card');
      box.appendChild(el('div', 'org-card-title ico i-pin', String(s.label || ORG_SPOT_WORDS[s.kind] || t('app.place'))));
      box.appendChild(el('div', 'hint', ORG_SPOT_WORDS[s.kind] || t('app.place')));
      var power = s.kind === 'signup' ? 'L2' : s.kind === 'meeting' ? 'L3' : null;
      if (power && orgHolds(power)) {
        var row = orgRow();
        row.appendChild(orgTwoTap('danger', t('app.remove'), 'spot:rm:' + s.id, t('app.tap_again_to_remove_it'), function () {
          orgWrite('spot:rm:' + s.id, function () { return post('orgRemoveSpot', { id: s.id }); }, t('app.removed'));
          orgRead('spots', function () { return post('orgSpots', {}); });
        }, power));
        box.appendChild(row);
      }
      view.appendChild(box);
    });
  }

  /* ---- Notices ---- */

  function orgNoticesScreen(view) {
    var box = orgCard(t('app.board_notice'), 'i-flag');
    var cap = orgBound('NoticeMaxLength');
    box.appendChild(orgField('notice.text', t('app.notice') + (cap !== null ? t('app.up_to_characters', cap) : ''),
      'area', state.org.mine.notice || t('app.write_the_notice'), cap || 500));
    box.appendChild(orgChoice('notice.broadcast', [{ value: false, label: t('app.board_only') },
      { value: true, label: t('app.also_message_every_member') }], false));
    var row = orgRow();
    row.appendChild(orgTwoTap('primary', t('app.post'), 'notice', t('app.tap_again_to_post_it'), function () {
      var text = orgText('notice.text');
      if (!text) { return say(t('app.write_the_notice_first')); }
      orgWrite('notice', function () {
        return post('orgNotice', { text: text, broadcast: orgChosen('notice.broadcast', false) === true });
      }, t('app.notice_posted'));
    }));
    if (state.org.mine.notice) {
      row.appendChild(orgTwoTap('ghost', t('app.take_it_down'), 'notice:clear', t('app.tap_again_to_take_it_down'), function () {
        orgWrite('notice:clear', function () { return post('orgNotice', { text: false }); }, t('app.notice_taken_down'));
      }));
    }
    box.appendChild(row);
    view.appendChild(box);
  }

  /* ---- Applications ---- */

  function orgApplicationsScreen(view) {
    if (orgPending(view, 'applications')) { return; }
    var rows = asList(state.org.data.applications.rows);
    if (!rows.length) { view.appendChild(el('div', 'empty', t('app.no_applications_waiting'))); return; }
    rows.forEach(function (a) {
      var box = orgCard(String(a.name || t('app.a_player')), 'i-user');
      box.appendChild(el('div', 'hint', a.body ? String(a.body) : t('app.no_words_given')));
      asList(a.form).forEach(function (f) {
        box.appendChild(el('div', 'target', String(f.q || '')));
        box.appendChild(el('div', 'org-notice', String(f.a || '')));
      });
      if (state.org.mine && state.org.mine.recruitment) {
        if (a.note) { box.appendChild(el('div', 'hint', t('app.interview_note') + String(a.note.text || ''))); }
        var nkey = 'app:' + a.id + ':note';
        box.appendChild(orgField(nkey, t('app.interview_note_2'), 'area', t('app.what_you_made_of_them'), 500));
        var nr = orgRow();
        nr.appendChild(orgTwoTap('ghost', t('app.save_note'), nkey + ':save', t('app.tap_again_to_save_the_note'), function () {
          var text = orgText(nkey);
          if (!text) { return say(t('app.write_the_note_first')); }
          orgWrite(nkey + ':save', function () { return post('orgInterviewNote', { id: a.id, text: text }); },
            t('app.note_saved'));
          orgRead('applications', function () { return post('orgApplications', {}); });
        }));
        box.appendChild(nr);
      }
      var row = orgRow();
      row.appendChild(orgTwoTap('primary', t('app.accept'), 'app:' + a.id + ':yes', t('app.tap_again_to_accept'), function () {
        orgWrite('app:' + a.id + ':yes', function () { return post('orgDecide', { id: a.id, accept: true }); },
          t('app.accepted_they_join_in_the_lowest'));
        orgRead('applications', function () { return post('orgApplications', {}); });
      }));
      row.appendChild(orgTwoTap('ghost', t('app.reject'), 'app:' + a.id + ':no', t('app.tap_again_to_reject'), function () {
        orgWrite('app:' + a.id + ':no', function () { return post('orgDecide', { id: a.id, accept: false }); },
          t('app.rejected'));
        orgRead('applications', function () { return post('orgApplications', {}); });
      }));
      box.appendChild(row);
      view.appendChild(box);
    });
  }

  /* ---- Settings: the label, the menu's layout, the office rule ---- */

  var ORG_LAYOUT_TABS = [['members', t('app.members')], ['roles', t('app.roles')], ['funds', t('app.money')],
    ['contracts', t('app.contracts')], ['locations', t('app.places')], ['notices', t('app.notices')], ['settings', t('app.settings')]];

  function orgSettingsScreen(view) {
    var m = state.org.mine;
    if (orgHolds('S1')) {
      var box = orgCard('Organisation name', 'i-briefcase');
      box.appendChild(orgField('rename', t('app.name'), 'text', m.label || '', 64));
      var row = orgRow();
      row.appendChild(orgTwoTap('primary', t('app.rename'), 'rename', t('app.tap_again_to_rename'), function () {
        var label = orgText('rename');
        if (!label) { return say(t('app.write_the_new_name')); }
        orgWrite('rename', function () { return post('orgRename', { label: label }); }, t('app.renamed'));
      }));
      box.appendChild(row);
      view.appendChild(box);
    }
    if (orgHolds('S2')) {
      var lay = orgCard(t('app.boss_menu_names'), 'i-layers');
      lay.appendChild(el('div', 'hint', t('app.rename_the_menus_screens_for_everybody')
        + t('app.the_name_it_has')));
      var labels = (m.layout && m.layout.labels) || {};
      ORG_LAYOUT_TABS.forEach(function (tv) {
        lay.appendChild(orgField('layout.' + tv[0], tv[1], 'text', String(labels[tv[0]] || tv[1]), 24));
      });
      var rl = orgRow();
      rl.appendChild(orgTwoTap('ghost', t('app.save_names'), 'layout', t('app.tap_again_to_save_the_names'), function () {
        var out = {};
        ORG_LAYOUT_TABS.forEach(function (tv) {
          var v = orgText('layout.' + tv[0]);
          if (v) { out[tv[0]] = v; } else if (labels[tv[0]]) { out[tv[0]] = labels[tv[0]]; }
        });
        var hidden = (m.layout && m.layout.hidden) || {};
        orgWrite('layout', function () {
          return post('orgLayout', { layout: { labels: out, hidden: hidden } });
        }, t('app.names_saved'));
      }));
      lay.appendChild(rl);
      view.appendChild(lay);
    }
    if (orgHolds('S3')) {
      var office = orgCard(t('app.powers_that_need_the_office'), 'i-briefcase');
      office.appendChild(el('div', 'hint', t('app.ask_for_the_office_for_more')
        + t('app.cannot_be_lifted_here')));
      orgPowerList().filter(function (p) { return p.held && p.code !== 'TAKE'; }).forEach(function (p) {
        var needs = !!(m.officeOnly && m.officeOnly[p.code]);
        var line = el('div', 'org-power');
        line.appendChild(el('div', 'org-power-name', p.label + (needs ? t('app.office_only') : t('app.anywhere'))));
        var row = orgRow();
        row.appendChild(orgTwoTap('ghost', needs ? t('app.anywhere_2') : t('app.office_only_2'), 'office:' + p.code,
          t('app.tap_again_to_change_it'), function () {
            orgWrite('office:' + p.code, function () {
              return post('orgOfficeRule', { power: p.code, on: !needs });
            }, t('app.saved'));
          }));
        line.appendChild(row);
        office.appendChild(line);
      });
      view.appendChild(office);
    }
  }

  /* Placing and accepting, which the app pause and a suspension refuse. */
  function takingPaused() {
    var h = holdsNow();
    return !!(h.appPaused || (h.suspendedUntil !== undefined && h.suspendedUntil !== null)
      || (state.board && state.board.suspended));
  }

  /* The banner at the top of Board, Mine, Place and On me while anything
     refuses writes, with until when where that is known. Message and Report
     still work, and it says so. */
  function holdBanner() {
    var h = holdsNow();
    var lines = [];
    if (h.appPaused) {
      lines.push(t('app.contracts_are_paused_by_staff_nothing')
        + t('app.switch_it_back_on'));
    }
    if (h.restartHold) {
      var ends = Number(h.restartHold.endsIn) || 0;
      lines.push(t('app.contracts_are_paused_for_the_server')
        + (ends > 0 ? t('app.for_at_most_more', durationText(Math.max(1, Math.ceil(ends / 60))))
          : '') + t('app.kills_handovers_and_buyouts_wait_and'));
    }
    if (state.board && state.board.suspended) {
      lines.push(suspendedText(state.board.suspended) + '.');
    }
    if (!lines.length) { return null; }
    var box = el('div', 'notice hold hold-banner'
      + (state.board && state.board.suspended ? ' suspended-note' : ''));
    lines.forEach(function (line) { box.appendChild(el('div', null, line)); });
    box.appendChild(el('div', 'hint', t('app.you_can_still_message_and_report_2')));
    return box;
  }

  /* To a contract of theirs under Mine, its card first and marked. From the
     board's "you are already on this one", and after accepting. */
  function openUnderMine(id) {
    navigated();
    state.focus = id;
    state.tab = 'mine';
    render();
  }

  /* The placer's half of a running handover: hold still, and roughly how
     long for, counted down here from the server's reading every few
     seconds while it is on screen. */
  var handoverNodes = {};
  var handoverTimer = null;
  function handoverText(contract) {
    var left = secondsLeftOf({ secondsLeft: contract.handoverLeft,
      clockReadAt: contract.clockReadAt });
    left = left > 0 ? Math.ceil(left / 5) * 5 : 0;
    return left > 0 ? t('app.hold_still_handover_running') + left + 's)'
      : t('app.hold_still_handover_finishing');
  }
  function placerHandover(contract) {
    var node = el('div', 'notice ok handover-live ico i-usercheck', handoverText(contract));
    handoverNodes[contract.id] = { node: node, contract: contract };
    armHandoverTick();
    return node;
  }
  function armHandoverTick() {
    if (handoverTimer) { return; }
    handoverTimer = setTimeout(function () {
      handoverTimer = null;
      var any = false;
      Object.keys(handoverNodes).forEach(function (id) {
        var shown = handoverNodes[id];
        if (shown.node.parentNode) {
          shown.node.textContent = handoverText(shown.contract);
          any = true;
        }
      });
      if (any && pageShown()) { armHandoverTick(); }
    }, 5000);
  }

  /* The placer's Confirm handover: the hold is done, and nothing is paid
     until they say so. Confirm and Decline each take two taps, three
     seconds apart at most, the second naming what it does. Names nobody. */
  var confirmArmed = null;   // 'yes:<id>' | 'no:<id>' waiting on its second tap
  function placerConfirm(contract) {
    var box = el('div', 'notice ok handover-confirm ico i-usercheck');
    box.appendChild(el('div', null, t('app.the_hold_is_done_confirm_handover')
      + Number(contract.handoverConfirm) + t('app.left_nothing_is_paid_until_you')));
    var row = el('div', 'row');
    [['yes', t('app.confirm_handover'), t('app.tap_again_to_confirm_and_pay'), t('app.confirming')],
     ['no', t('app.decline'), t('app.tap_again_to_decline_nothing_is'), t('app.declining')]]
      .forEach(function (b) {
        var key = 'confirm:' + b[0] + ':' + contract.id;
        if (isBusy(key)) {
          row.appendChild(actionButton(b[0] === 'yes' ? 'primary' : 'ghost', b[1], key, b[3]));
          return;
        }
        var armed = confirmArmed === b[0] + ':' + contract.id;
        var button = el('button', (b[0] === 'yes' ? 'primary' : 'ghost') + (armed ? ' is-armed' : ''),
          armed ? b[2] : b[1]);
        button.onclick = function () {
          if (confirmArmed !== b[0] + ':' + contract.id) {
            confirmArmed = b[0] + ':' + contract.id;
            setTimeout(function () {
              if (confirmArmed === b[0] + ':' + contract.id) { confirmArmed = null; render(); }
            }, TIP_CONFIRM_MS);
            return render();
          }
          confirmArmed = null;
          once(key, function () {
            return post('confirmHandover', { id: contract.id,
              decline: b[0] === 'no' ? true : undefined }).then(function (r) {
              if (!r.ok) {
                if (r.err === 'no_handover' || r.err === 'not_found') {
                  say(t('app.that_handover_is_no_longer_waiting'));
                } else { fail(r); }
                return refresh();
              }
              say(b[0] === 'yes' ? t('app.handover_confirmed_the_payment_is_being')
                : t('app.handover_declined_nothing_was_paid_and'),
                b[0] === 'yes' ? 'ok' : null);
              refresh();
            });
          });
        };
        row.appendChild(button);
      });
    box.appendChild(row);
    return box;
  }

  /* The buyout on a contract on this player, into a card's action row: On
     me's, and the same on the whitelisted-job view's "Contracts on you",
     drawn by this one function so the two say and do exactly the same. */
  function appendBuyout(row, contract) {
    // Already paid for, and closing once the delay runs out. Drawn before
    // the buy button so a player who has paid is not offered the same
    // price again on a card identical to the one before their money left.
    // Not "your money is already gone": it comes back if a hitman
    // finishes it first, and until then they still can.
    if (contract.bailoutPaid) {
      var still = buyoutWait(secondsLeftOf({ secondsLeft: contract.bailoutSecondsLeft,
        clockReadAt: contract.clockReadAt }));
      row.appendChild(el('div', 'hint',
        t('app.paid_a_hitman_still_has') + (still || t('app.a_moment')) + t('app.to_finish_this')
        + t('app.stay_out_of_sight_if_they')));
    } else if (contract.bailoutAvailable) {
      var buyoutKey = 'bailout:' + contract.id;
      var buyoutLabel = t('app.buy_out') + money(contract.bailoutAmount);
      if (isBusy(buyoutKey)) {
        row.appendChild(actionButton('primary danger', buyoutLabel, buyoutKey, t('app.paying')));
      } else {
        var out = el('button', 'primary danger', buyoutLabel);
        out.onclick = function () { bailout(contract); };
        row.appendChild(restartWaits(out));
      }
    } else if (settings().buyouts === false) {
      // Not the client's doing. Saying "no buyout was offered" here blamed
      // the one person who had not decided it.
      row.appendChild(el('div', 'hint', t('app.this_server_does_not_offer_buyouts')));
    } else {
      row.appendChild(el('div', 'hint', t('app.no_buyout_was_offered_on_this')));
    }
  }

  // Why a hold is slipping, in words a player can act on. The server sends
  // the reason and always has; the app used to render none of it, so a hitman
  // whose delivery was failing had no idea until it did.
  // Every reason Kidnap.conditionsMet can return, and nothing it cannot.
  // The two that mean the person who placed the contract is missing say who
  // that is and how close they have to be: "The client is too far away" was
  // read as somebody's game client, or as nobody in particular. The radius
  // is the one this countdown was armed with (progress.radius).
  var BREAKING = {
    party_offline: function (radius) {
      return t('app.someone_has_gone_offline_the_person')
        + t('app.online_and') + nearPlacer(radius);
    },
    target_not_conscious: t('app.your_target_must_be_alive_and'),
    target_too_hurt: t('app.your_target_is_too_badly_hurt'),
    not_coerced: t('app.your_target_is_not_restrained'),
    target_too_far: t('app.your_target_is_too_far_from'),
    not_together: t('app.you_and_your_target_are_not'),
    creator_too_far: function (radius) {
      return t('app.the_person_who_placed_this_contract') + nearPlacer(radius);
    }
  };

  // A reason as the countdown says it, or null for one it has no words for.
  function breakingText(progress) {
    var said = BREAKING[progress.breaking];
    return typeof said === 'function' ? said(progress.radius) : (said || null);
  }

  /* The countdown bars on screen, by contract, from the last draw. The
     poll repaints a bar in place, as the clock chips are (paintClock),
     rather than rebuilding every card, face and icon on the tab once a
     second to move one bar. Emptied by draw(), so a bar from an older draw
     is never the one painted. */
  var countdownBars = {};

  function countdown(progress) {
    var wrap = el('div', 'countdown' + (progress.breaking ? ' is-breaking' : ''));

    var bar = el('div', 'bar');
    var fill = el('i');
    fill.style.width = Math.min(100, (progress.elapsed / progress.required) * 100) + '%';
    bar.appendChild(fill);
    wrap.appendChild(bar);

    wrap.appendChild(el('div', 'label', progress.settling
      ? t('app.held_long_enough_settling_the_payout')
      : progress.awaitingConfirm
        ? t('app.held_long_enough_waiting_for_the')
          + (Number(progress.confirmLeft) > 0 ? ' (' + Number(progress.confirmLeft) + 's)' : '')
        : progress.elapsed + t('app.of') + progress.required + 's'));
    // Nothing to hold any more: the leeway is not drawn.
    if (progress.awaitingConfirm) { return wrap; }

    // The grace budget is one allowance for the whole countdown, not one per
    // break, so what is left of it is the number that actually matters.
    // Said as what happens when it is gone: "1.8s of slack left" left a
    // hitman to work out for themselves that zero means the handover fails.
    if (progress.graceTotal > 0) {
      var left = Math.max(0, progress.graceLeft || 0);
      var grace = el('div', 'bar grace');
      var graceFill = el('i');
      graceFill.style.width = Math.min(100, (left / progress.graceTotal) * 100) + '%';
      grace.appendChild(graceFill);
      wrap.appendChild(grace);

      wrap.appendChild(el('div', 'label' + (progress.breaking ? ' warn' : ''),
        progress.breaking
          ? (breakingText(progress) || t('app.hold_position'))
              + t('app.handover_fails_in') + (left / 1000).toFixed(1) + 's'
          : (left / 1000).toFixed(1) + t('app.of_leeway_left_the_handover')
              + t('app.fails_if_it_runs_out')));
    } else if (progress.breaking) {
      wrap.appendChild(el('div', 'label warn',
        breakingText(progress) || t('app.hold_position')));
    }

    return wrap;
  }

  /* ---------- actions ---------- */

  /* The server's settings, from the board; on the whitelisted-job view,
     which is never sent the board, the few its buyout reads come with it. */
  function settings() {
    return (state.board && state.board.settings)
      || (state.jobView && state.jobView.settings) || {};
  }

  /* Take a contract back down. Everything staked comes home, and the
     server refuses it outright the moment somebody is working it. */
  /* A refusal because a hitman took the contract meanwhile: said so, the
     reward editor closed (its take-backs no longer apply), and the cards
     re-read so Withdraw and Edit go away. Anything else is the usual fail. */
  function takenOr(r) {
    if (r.err !== 'contract_taken') { return fail(r); }
    say(ERRORS.contract_taken);
    state.reward = null;
    state.dialog = null;
    refresh();
    redraw();
  }

  /* What withdrawing starts, in a sentence; null when it starts nothing.

     The dialog said only "This cannot be undone.", and a creator who
     withdrew to fix the reward or the deadline — both changeable in place —
     found out about the waits when placing it again was refused. Each wait
     the server has switched off is left out. */
  function relistWaitText(contract) {
    var waits = settings().relistWaits || {};
    var any = Number(waits.anyMinutes) || 0;
    var same = Number(waits.sameTargetMinutes) || 0;
    var everyone = Number(waits.everyoneMinutes) || 0;
    var name = contract.targetName || 'them';
    var mine = [];
    if (any > 0) { mine.push(t('app.any_new_contract_for') + durationText(any)); }
    if (same > 0) { mine.push(t('app.one_on_for', name, durationText(same))); }
    /* The creator's own, and on a contract somebody took up, the wait on the
       target for every client: withdrawing one nobody took up starts none
       for anybody else, and the dialog said "Nobody else waits" after an
       operative had taken it and walked away. */
    var others = contract.everTaken && everyone > 0
      ? t('app.nobody_else_on_for_either', name, durationText(everyone))
      : '';
    if (!mine.length) { return others || null; }
    return t('app.after_this_you_cannot_place') + mine.join(', or ') + '.'
      + (others ? ' ' + others : '');
  }

  /* A payout already collected on a contract is not part of what comes
     back when it closes. "Everything you put up" after one was paid was
     short by that one, which is how a player counts their money, finds it
     short and reports it stolen. null when none was collected. */
  function collectedText(contract) {
    var claimed = Number(contract.slotsClaimed) || 0;
    if (claimed <= 0) { return null; }
    return t('app.payouts_were_collected_of', claimed, Math.max(claimed, Number(contract.slots) || 1));
  }

  function cancelContract(contract) {
    var waits = relistWaitText(contract);
    var collected = collectedText(contract);
    var lead = contract.everTaken ? t('app.the_operative_who_took_it_walked') : t('app.nobody_has_taken_it');
    ask(t('app.withdraw_this_contract'),
      (collected
        ? lead + '. ' + collected + t('app.so_the_rest_of_what_you')
        : lead + t('app.so_everything_you_put_up_comes'))
        + (waits ? ' ' + waits : '')
        + t('app.to_change_what_it_pays_or')
        + t('app.edit_instead'),
      function () {
        post('cancel', { id: contract.id }).then(function (r) {
          if (!r.ok) { return takenOr(r); }
          // Not "everything has been returned" unconditionally. Something
          // that would not fit is owed and handed over later, and the phone
          // notification already says so — this said the opposite at the
          // same moment, which is the case where a player counts their
          // money, finds it short and reports it stolen.
          var queued = (r.data && Number(r.data.queued)) || 0;
          var checking = staffChecking(r.data);
          say(queued > 0
            ? t('app.contract_withdrawn_some_of_what_you')
              + t('app.waiting_for_you_it_arrives_when') + checking
            : checking ? t('app.contract_withdrawn') + checking
              : collected
                ? t('app.contract_withdrawn_2') + collected + t('app.the_rest_of_what_you_put')
                  + 'returned.'
                : t('app.contract_withdrawn_everything_you_put_up'), 'ok');
          refresh();
        });
      }, { yes: t('app.withdraw_it'), no: t('app.keep_it') });
  }

  /* The same reason control the Place form draws, for the same reason.

     The Edit dialog asked for free text whatever the server took, and
     always sent it. On a preset server that was refused as invalid_input;
     on a server storing no reason at all it made the whole edit fail, so
     the deadline it came with could never be changed either. The rules are
     the operator's and apply to every way in: the Edit sheet, and
     proposing a new reason once somebody holds the contract. */
  function reasonFields(contract) {
    var mode = settings().reasonMode || 'freetext';
    var presets = asList(settings().reasonPresets);
    var fields = [];

    if (mode === 'preset' && presets.length) {
      // Opens on the reason the contract already gives. It opened on no
      // choice at all, which Save read as the first preset — so moving the
      // deadline also replaced the reason with whatever was top of the list.
      var currentPreset = presets.indexOf(contract.reason) + 1;
      fields.push({
        id: 'reasonPreset', label: t('app.reason'), type: 'select',
        value: currentPreset > 0 ? currentPreset : undefined,
        // One-based, as the server indexes its own list.
        options: presets.map(function (text, i) {
          return { value: i + 1, label: text };
        })
      });
    } else if (mode !== 'off') {
      fields.push({ id: 'reason', label: t('app.reason'), type: 'text',
                    value: contract.reason || '',
                    max: settings().reasonMaxLength || 140 });
    }
    return fields;
  }

  /* One sheet for everything about a contract nobody has taken: its reason,
     what it pays (more, and what can be taken back), the stake, the
     deadline (more or less, in hours) and the mode. Save shows what will
     change; Confirm makes the changes, through the server's own requests
     for each (revise, addEscrow, improve, propose), one after another, and
     says what was done. It took five buttons and as many dialogs, a change
     at a time. Once somebody holds it, changes are proposed instead. */
  function editSheet(contract) {
    state.dialog = { kind: 'sheet', contract: contract, values: {}, changes: null, error: null };
    render();
  }

  /* The most a stake can be, as Contracts.clampPenalty holds it. */
  function stakeMostOf(contract) {
    var ceiling = settings().stakeCeiling || {};
    var most = Number(ceiling.amount) || 0;
    if (ceiling.fraction) {
      most = Math.min(most, Math.floor((Number(contract.valueHeld) || 0) * Number(ceiling.fraction)));
    }
    return most;
  }

  /* What the sheet would change, from what is in it, or a reason it cannot
     be saved as it stands. */
  function sheetChanges(d) {
    var contract = d.contract;
    var v = d.values;
    var changes = [];
    var whole = function (raw) {
      var text = String(raw === undefined || raw === null ? '' : raw).trim();
      if (text === '') { return 0; }
      return /^[-+]?\d+$/.test(text) ? parseInt(text, 10) : NaN;
    };

    // The reason through revise, as the Edit dialog sent it: text or a
    // preset's index, whichever this server takes. The deadline is moved by
    // hours below (improve, propose), never set here, so revise is sent no
    // deadline: undefined does not survive being encoded.
    var preset = parseInt(v.reasonPreset, 10) || 0;
    var presets = asList(settings().reasonPresets);
    var newText = v.reason !== undefined && v.reason !== (contract.reason || '') ? v.reason : undefined;
    var newPreset = preset > 0 && presets[preset - 1] !== contract.reason ? preset : undefined;
    if (newText !== undefined || newPreset !== undefined) {
      changes.push({ what: 'reason',
        text: t('app.reason_quoted', newText !== undefined ? newText : presets[preset - 1]),
        send: function () {
          return post('revise', { id: contract.id, reason: newText, reasonPreset: newPreset,
                                  deadlineSeconds: undefined });
        } });
    }

    var mode = v.mode || contract.mode;
    if (mode !== contract.mode) {
      changes.push({ what: 'mode', text: mode === 'exclusive' ? t('app.one_hitman_at_a_time')
        : t('app.open_to_several_hitmen_at_once'),
        send: function () {
          return post('propose', { id: contract.id, kind: 'change_mode', payload: { mode: mode } });
        } });
    }

    var stakeNow = Number(contract.penaltyAmount) || 0;
    var stake = v.stake === undefined ? stakeNow : whole(v.stake);
    if (isNaN(stake) || stake < 0) { return { error: t('app.the_stake_is_a_whole_number') }; }
    if (stake > stakeNow) {
      var stakeMost = stakeMostOf(contract);
      if (stake > stakeMost) {
        return { error: t('app.the_stake_can_be_at_most') + money(stakeMost) + t('app.on_this_contract') };
      }
      changes.push({ what: 'stake', text: t('app.stake_is', money(stake)),
        send: function () {
          return post('propose', { id: contract.id, kind: 'raise_penalty', payload: { amount: stake } });
        } });
    } else if (stake < stakeNow) {
      changes.push({ what: 'stake', text: stake > 0 ? t('app.stake_is', money(stake)) : t('app.no_stake'),
        send: function () {
          return post('improve', { id: contract.id, kind: 'lower_penalty', payload: { amount: stake } });
        } });
    }

    var hours = whole(v.hours);
    if (isNaN(hours)) { return { error: t('app.move_the_deadline_by_whole_hours') }; }
    if (hours > 0) {
      var ceiling = Number(settings().deadlineMaxMinutes) || 0;
      if (ceiling > 0 && hours * 60 > ceiling) {
        return { error: t('app.the_deadline_moves_by_at_most') + durationText(ceiling) + t('app.at_a_time') };
      }
      changes.push({ what: 'deadline', text: t('app.deadline_h_more', hours),
        send: function () {
          return post('improve', { id: contract.id, kind: 'extend_deadline',
                                   payload: { seconds: hours * 3600 } });
        } });
    } else if (hours < 0) {
      var keep = Number(settings().deadlineMinLeftMinutes) || 5;
      var left = minutesLeft(contract);
      if (left === null || -hours * 60 > left - keep) {
        return { error: t('app.there_is_not_that_much_deadline')
          + (bandOf(contract) ? bandOf(contract).text.toLowerCase() : t('app.no_deadline')) + '.' };
      }
      changes.push({ what: 'deadline', text: t('app.deadline_h_less', -hours),
        send: function () {
          return post('propose', { id: contract.id, kind: 'shorten_deadline',
                                   payload: { seconds: -hours * 3600 } });
        } });
    }

    // The buyout price, as placing sets it: the server clamps it to what the
    // contract's cash and bank allow, 0 for none.
    if (v.buyout !== undefined) {
      var buyoutNow = Number(contract.bailoutAmount) || 0;
      var buyout = whole(v.buyout);
      if (isNaN(buyout) || buyout < 0) {
        return { error: t('app.the_buyout_price_is_a_whole') };
      }
      if (buyout !== buyoutNow) {
        changes.push({ what: 'buyout', text: buyout > 0 ? t('app.buyout_price') + money(buyout) : t('app.no_buyout'),
          send: function () { return post('revise', { id: contract.id, bailoutAmount: buyout }); } });
      }
    }

    // How it may be completed, only as this server places contracts now.
    var ruleNow = aliveOnly(contract) ? 'alive' : 'either';
    if (v.rule && v.rule !== ruleNow) {
      var rule = v.rule;
      changes.push({ what: 'completion', text: rule === 'alive' ? t('app.completed_alive_only')
        : t('app.completed_alive_or_dead'),
        send: function () { return post('revise', { id: contract.id, fulfilment: rule }); } });
    }

    // Placed under their name or anonymously, where the server allows it,
    // with the fee the page quotes echoed so a changed one is refused.
    var anonNow = contract.creatorAnonymous === true;
    if (v.anon !== undefined && (v.anon === 'anon') !== anonNow) {
      var anon = v.anon === 'anon';
      var fee = anonymityFee('creator');
      changes.push({ what: 'anonymity', text: anon
        ? t('app.placed_anonymously') + (fee > 0 ? ' (' + money(fee) + t('app.from_your') + anonymityAccount() + ')' : '')
        : t('app.under_your_name_2'),
        send: function () {
          return post('revise', { id: contract.id, anonymous: anon,
                                  shown: { creatorFee: fee, feeAccount: anonymityAccount() } });
        },
        // The fee raised under the sheet: the figure now, nothing taken.
        explain: function (r) {
          if (r.err === 'terms_changed' && r.data && typeof r.data.creatorFee === 'number') {
            return t('app.placing_it_anonymously_now_costs') + money(r.data.creatorFee) + t('app.nothing_was_taken');
          }
          return null;
        } });
    }

    var add = whole(v.add);
    if (isNaN(add) || add < 0) { return { error: t('app.add_a_whole_number_of_dollars') }; }
    if (add > 0) {
      var source = v.source === 'bank' ? 'bank' : 'cash';
      changes.push({ what: 'reward', text: t('app.reward_more_from_your', money(add), source),
        send: function () {
          var reward = { baseline: {} };
          reward.baseline[source] = add;
          return post('addEscrow', { id: contract.id, reward: reward });
        } });
    }
    return { changes: changes };
  }

  /* Make the changes one after another, stopping at the first refused, and
     say which went in. */
  function applySheet(contract, changes) {
    var done = [];
    var i = 0;
    function next() {
      if (i >= changes.length) {
        say(t('app.saved_list', done.join(', ')), 'ok');
        return refresh();
      }
      var change = changes[i++];
      return change.send().then(function (r) {
        var failed = !r.ok || (r.data && r.data.outcome === 'failed');
        if (failed) {
          var why = !r.ok ? ((change.explain && change.explain(r)) || failText(r) || t('app.not_right_now'))
            : (ERRORS[r.data.err] || t('app.that_change_no_longer_fits_this'));
          say((done.length ? t('app.saved_list', done.join(', ')) + ' ' : '')
            + t('app.not_saved') + change.what + ': ' + why);
          return refresh();
        }
        done.push(change.what);
        return next();
      });
    }
    return once('sheet:' + contract.id, next);
  }

  /* A different target: the contract is withdrawn (everything put up comes
     back, nobody having taken it, but an anonymity fee) and the Place form
     opened, where the new one goes through every check placing makes. Two
     taps, three seconds apart at most. The usual wait after withdrawing is
     said first, and on the button: as shipped every new placement by this
     placer waits five minutes after a withdrawal, and "Cancel and place
     again" read as if the new one went straight on.

     The anonymity fee is not given back. It bought the listing's
     anonymity for as long as it ran, and handing it back on a withdrawal
     would make anonymity free to anybody who withdraws before a taker:
     list anonymously, watch, withdraw, repeat. It cannot be tied to placing
     again either, since the withdrawal comes first and the new one may
     never be placed. So the words say so instead. */
  var retargetArmed = null;   // the contract id whose Cancel and place again waits for its second tap
  function retargetLabel(contract) {
    var any = Number((settings().relistWaits || {}).anyMinutes) || 0;
    return any > 0 ? t('app.cancel_place_again_in') + durationText(any) : t('app.cancel_and_place_again');
  }
  function feeKeptText(contract) {
    return contract.creatorAnonymous === true
      ? t('app.except_the_anonymity_fee_which_is') : '';
  }
  function retargetBox(contract) {
    var box = el('div', 'sheet-retarget');
    var waits = relistWaitText(contract);
    box.appendChild(el('div', 'hint', t('app.to_put_this_contract_on_someone')
      + t('app.it_again_nobody_has_taken_it')
      + feeKeptText(contract) + '.' + (waits ? ' ' + waits : '')));
    var key = 'retarget:' + contract.id;
    var armed = retargetArmed === contract.id;
    var label = retargetLabel(contract);
    var b;
    if (isBusy(key)) {
      b = actionButton('ghost ico i-swap', label, key, t('app.withdrawing'));
    } else {
      b = el('button', 'ghost ico i-swap' + (armed ? ' is-armed' : ''),
        armed ? t('app.tap_again_to_withdraw_it') : label);
      b.onclick = function () {
        if (retargetArmed !== contract.id) {
          retargetArmed = contract.id;
          setTimeout(function () {
            if (retargetArmed === contract.id) { retargetArmed = null; render(); }
          }, TIP_CONFIRM_MS);
          return render();
        }
        retargetArmed = null;
        once(key, function () {
          return post('cancel', { id: contract.id }).then(function (r) {
            if (!r.ok) { return takenOr(r); }
            var queued = (r.data && Number(r.data.queued)) || 0;
            var any = Number((settings().relistWaits || {}).anyMinutes) || 0;
            say((queued > 0
              ? t('app.contract_withdrawn_some_of_what_you_2')
                + t('app.when_you_next_have_room')
              : t('app.contract_withdrawn_everything_you_put_up_2')
                + feeKeptText(contract) + '.')
              + (any > 0 ? t('app.you_can_place_the_new_one') + durationText(any)
                + t('app.the_place_form_is_open_for') : t('app.place_the_new_one_here'))
              + staffChecking(r.data), 'ok');
            state.dialog = null;
            state.draft = state.draft || {};
            state.tab = 'place';
            refresh();
            render();
          });
        });
      };
    }
    b.id = 'sheet-retarget-' + contract.id;
    box.appendChild(b);
    return box;
  }

  function renderSheet(view) {
    var d = state.dialog;
    var contract = d.contract;
    var sheet = el('div', 'card dialog edit-sheet');
    sheet.appendChild(el('div', 'target', t('app.edit_this_contract')));
    sheet.appendChild(el('div', 'reason', t('app.nobody_has_taken_it_changes_apply') + ' ' + (bandOf(contract) ? t('app.it_has') + bandOf(contract).text.toLowerCase() + '.' : '')));
    // The fields scroll on a short screen; Save and Cancel stay put under
    // them, as the reward editor's lines do.
    var panel = el('div', 'sheet-body');
    sheet.appendChild(panel);

    function remember(id, node) {
      node.oninput = node.onchange = function () {
        d.values[id] = node.value;
        if (d.changes) { d.changes = null; d.error = null; render(); }
      };
    }
    function current(id, fallback) {
      return d.values[id] !== undefined ? String(d.values[id]) : String(fallback);
    }

    // The reason, as the server takes one (reasonFields).
    reasonFields(contract).forEach(function (spec) {
      var node;
      if (spec.type === 'select') {
        node = make('select');
        (spec.options || []).forEach(function (option) {
          var o = document.createElement('option');
          o.value = String(option.value);
          o.textContent = option.label;
          node.appendChild(o);
        });
        node.value = current('reasonPreset', spec.value === undefined ? '' : spec.value);
        remember('reasonPreset', node);
      } else {
        node = make('input');
        node.type = 'text';
        node.maxLength = spec.max;
        node.value = current('reason', spec.value || '');
        remember('reason', node);
      }
      node.id = 'sheet-' + spec.id;
      panel.appendChild(labelled(t('app.reason'), node));
    });

    // The reward: more from cash or bank here; taking back, and goods, the
    // kidnapping bonus and dirty money, in the reward editor.
    var add = make('input');
    add.type = 'number';
    add.inputMode = 'numeric';
    add.min = 0;
    add.id = 'sheet-add';
    add.placeholder = '0';
    add.value = current('add', '');
    remember('add', add);
    panel.appendChild(labelled(t('app.add_to_the_reward_now') + money((contract.reward || {}).baseline),
      add));
    var sources = el('div', 'row target-modes sheet-source');
    [['cash', t('app.from_cash')], ['bank', t('app.from_bank')]].forEach(function (pair) {
      var on = (d.values.source || 'cash') === pair[0];
      var b = el('button', on ? 'primary is-chosen' : 'ghost', pair[1]);
      b.onclick = function () { d.values.source = pair[0]; d.changes = null; render(); };
      sources.appendChild(b);
    });
    panel.appendChild(sources);
    var more = el('button', 'ghost ico i-coin sheet-reward', t('app.change_reward'));
    more.onclick = function () { editReward(contract); };
    panel.appendChild(more);
    // The rest of what can be changed (giving back a later payout among
    // them), each applied at once on a contract nobody holds.
    var rarer = el('button', 'ghost ico i-swap sheet-reward', t('app.more_changes'));
    rarer.onclick = function () { proposeChange(contract); };

    // The stake, as a figure: lower applies at once, higher up to the most
    // this contract can ask.
    var stake = make('input');
    stake.type = 'number';
    stake.inputMode = 'numeric';
    stake.min = 0;
    stake.id = 'sheet-stake';
    stake.value = current('stake', Number(contract.penaltyAmount) || 0);
    remember('stake', stake);
    panel.appendChild(labelled(t('app.hitmans_stake_0_for_none_at')
      + money(Math.max(stakeMostOf(contract), Number(contract.penaltyAmount) || 0)) + ')', stake));

    // The deadline, moved by whole hours either way.
    var hours = make('input');
    hours.type = 'number';
    hours.inputMode = 'numeric';
    hours.id = 'sheet-hours';
    hours.placeholder = '0';
    hours.value = current('hours', '');
    remember('hours', hours);
    panel.appendChild(labelled(t('app.move_the_deadline_by_hours_2'), hours));

    // How many may take it.
    var modes = el('div', 'row target-modes sheet-mode');
    [['exclusive', t('app.one_hitman')], ['competitive', t('app.several_at_once')]].forEach(function (pair) {
      var on = (d.values.mode || contract.mode) === pair[0];
      var b = el('button', on ? 'primary is-chosen' : 'ghost', pair[1]);
      b.onclick = function () { d.values.mode = pair[0]; d.changes = null; render(); };
      modes.appendChild(b);
    });
    panel.appendChild(labelled(t('app.who_can_take_it'), modes));

    // The buyout price, where the server runs buyouts (Contracts.revise
    // clamps it as placing does).
    if (settings().buyouts !== false) {
      var buyoutField = make('input');
      buyoutField.type = 'number';
      buyoutField.inputMode = 'numeric';
      buyoutField.min = 0;
      buyoutField.id = 'sheet-buyout';
      buyoutField.value = current('buyout', Number(contract.bailoutAmount) || 0);
      remember('buyout', buyoutField);
      panel.appendChild(labelled(t('app.buyout_price_0_for_none'), buyoutField));
    }

    // How it may be completed: alive only always; alive or dead only where
    // this server places contracts that allow a kill now.
    var ruleChoices = [['alive', t('app.alive_only')]];
    if (!placingAliveOnly()) { ruleChoices.push(['either', t('app.alive_or_dead')]); }
    var ruleNow = aliveOnly(contract) ? 'alive' : 'either';
    if (ruleChoices.length > 1 || ruleNow !== 'alive') {
      var rules = el('div', 'row target-modes sheet-rule');
      ruleChoices.forEach(function (pair) {
        var on = (d.values.rule || ruleNow) === pair[0];
        var b = el('button', on ? 'primary is-chosen' : 'ghost', pair[1]);
        b.onclick = function () { d.values.rule = pair[0]; d.changes = null; render(); };
        rules.appendChild(b);
      });
      panel.appendChild(labelled(t('app.how_it_is_completed'), rules));
    }

    // Under their name or anonymously: anonymous offered only where the
    // server allows it for this target; back under their name always.
    var anonNow = contract.creatorAnonymous === true;
    if (anonNow || anonymityOffered('creator', contract.targetProtected === true)) {
      var anons = el('div', 'row target-modes sheet-anon');
      var fee = anonymityFee('creator');
      var anonChoices = [['named', t('app.under_my_name')]];
      if (anonNow || anonymityOffered('creator', contract.targetProtected === true)) {
        anonChoices.push(['anon', t('app.anonymously') + (fee > 0 && !anonNow ? ' (' + money(fee) + ')' : '')]);
      }
      anonChoices.forEach(function (pair) {
        var on = (d.values.anon || (anonNow ? 'anon' : 'named')) === pair[0];
        var b = el('button', on ? 'primary is-chosen' : 'ghost', pair[1]);
        b.onclick = function () { d.values.anon = pair[0]; d.changes = null; render(); };
        anons.appendChild(b);
      });
      panel.appendChild(labelled(t('app.who_it_says_placed_it'), anons));
    }

    // The target cannot be changed in place: every placing check runs on
    // a new one. Cancel and place again, two taps, everything handed back.
    panel.appendChild(retargetBox(contract));

    // Save, then Confirm: the first shows what will change, the second
    // makes it so.
    if (settings().amendments !== false) { panel.appendChild(rarer); }
    // What Save found, under the fields and over the buttons, never
    // scrolled out of sight.
    panel = sheet;
    if (d.error) { panel.appendChild(el('div', 'hint is-refusal', d.error)); }
    if (d.changes && d.changes.length) {
      var list = el('div', 'sheet-changes');
      d.changes.forEach(function (c) { list.appendChild(el('div', 'hint ico i-pencil', c.text)); });
      panel.appendChild(list);
    }
    var row = el('div', 'row');
    var confirming = !!(d.changes && d.changes.length);
    var save = el('button', confirming ? 'danger' : 'primary', confirming
      ? tn('app.confirm_changes', d.changes.length)
      : t('app.save'));
    save.onclick = function () {
      if (confirming) {
        var changes = d.changes;
        state.dialog = null;
        render();
        return applySheet(contract, changes);
      }
      var worked = sheetChanges(d);
      if (worked.error) { d.error = worked.error; d.changes = null; return render(); }
      if (!worked.changes.length) { d.error = t('app.nothing_is_changed_yet'); return render(); }
      d.error = null;
      d.changes = worked.changes;
      render();
    };
    var no = el('button', 'ghost', t('app.cancel'));
    no.onclick = closeDialog;
    row.appendChild(save);
    row.appendChild(no);
    panel.appendChild(row);
    view.appendChild(panel);
  }

  /* The rule that takes a hold back, said before it is taken. A hitman
     first learned it from the board once it had barred them from the
     contract for good. What going idle means, in words: "going 30 minutes
     without going near them, or 2h without an attempt, while they are in
     the city". The server's clocks run only while the target (and a named
     client) are in the city, and they apply to an exclusive contract and to
     a competitive one that is full. Each window the server has switched off
     is left out, and with both off there is nothing to say. */
  function idleText(contract) {
    var idle = Number(settings().exclusiveIdleMinutes) || 0;
    var attempt = Number(settings().exclusiveAttemptMinutes) || 0;
    var ways = [];
    if (idle > 0) { ways.push(t('app.going_without_going_near', durationText(idle))); }
    if (attempt > 0) {
      ways.push(ways.length ? t('app.without_an_attempt_x', durationText(attempt))
        : t('app.going_without_an_attempt', durationText(attempt)));
    }
    return ways.length ? ways.join(', or ') + t('app.while_they_are_in_the_city') : '';
  }

  /* Where the stake goes, said where the hitman agrees to it. Going idle
     forfeits it as walking away does (the server's idle release), so the
     dialog no longer says "your stake comes back" about a rule that now
     hands it to the client. */
  function stakeRule(contract) {
    var idleLoses = contract.mode === 'exclusive' && idleText(contract) !== '';
    return (idleLoses ? t('app.walk_away_go_idle_or_run')
      : t('app.walk_away_or_run_out_of')) + t('app.and_your_stake_goes_to_the');
  }

  function exclusiveRule(contract) {
    var idle = idleText(contract);
    if (!idle) { return ''; }
    if (contract.mode === 'exclusive') {
      return t('app.exclusive_idle_cannot_take_again', idle);
    }
    // A competitive contract is released from only while it is full.
    return t('app.while_it_is_full') + idle + t('app.gives_your_place')
      + (Number(contract.penaltyAmount) > 0 ? t('app.and_your_stake') : '') + t('app.up');
  }

  /* The same rule, on the hitman's own card under Mine: where they look
     while they work it, and an hour after the dialog that said it. */
  function exclusiveReminder(contract) {
    var idle = idleText(contract);
    if (!idle) { return null; }
    var staked = Number(contract.penaltyAmount) > 0;
    if (contract.mode === 'exclusive') {
      return el('div', 'hint', t('app.exclusive_idle_not_yours', idle) + (staked ? ' ' + stakeRule(contract) : ''));
    }
    // On a competitive card only while it is full, which is when it applies.
    if ((Number(contract.hitmenActive) || 0) < (Number(contract.hitmenMax) || Infinity)) {
      return null;
    }
    return el('div', 'hint', t('app.while_it_is_full_2') + idle + t('app.gives_your_place')
      + (staked ? t('app.and_your_stake') : '') + t('app.up'));
  }

  /* What accepting echoes of the card: the anonymity fee and its account
     the dialog showed, and the terms a placer may change until somebody
     accepts, as the card had them. A term the card did not carry is not
     sent, and the server holds the tap to nothing about it. */
  function acceptEcho(contract, shownFee, feeAccount) {
    var echo = { hitmanFee: shownFee, feeAccount: feeAccount,
                 creatorAnonymous: contract.creatorAnonymous === true };
    if (typeof contract.fulfilment === 'string') { echo.fulfilment = contract.fulfilment; }
    if (typeof contract.bailoutAmount === 'number') { echo.bailoutAmount = contract.bailoutAmount; }
    return echo;
  }

  /* A term that moved between the card and the tap, said as what it is now:
     the board refreshes under it. null where it is not one of these. */
  function acceptMovedText(r) {
    var d = r.data || {};
    if (r.err === 'rule_changed' && typeof d.fulfilment === 'string') {
      return t('app.the_person_who_placed_it_changed')
        + (d.fulfilment === 'either' ? t('app.a_kill_completes_it_as_well')
          : t('app.it_only_pays_when_the_target'))
        + t('app.nothing_was_taken_check_the_card');
    }
    if (r.err === 'terms_changed' && typeof d.creatorAnonymous === 'boolean') {
      return t('app.the_person_who_placed_it_changed_2')
        + (d.creatorAnonymous ? 'anonymous' : t('app.under_their_name'))
        + t('app.nothing_was_taken_check_the_card_2');
    }
    if (r.err === 'terms_changed' && typeof d.bailoutAmount === 'number') {
      return t('app.the_person_who_placed_it_changed_3')
        + (d.bailoutAmount > 0 ? money(d.bailoutAmount) : 'none')
        + t('app.nothing_was_taken_check_the_card_2');
    }
    return null;
  }

  function acceptContract(contract) {
    var feeAccount = anonymityAccount();
    // The fee the dialog shows, kept with it and sent back with the tap:
    // the server refuses rather than charges a fee that has moved since.
    var shownFee = anonymityFee('hitman');
    // And the organisation's cut the card and the dialog showed: the server
    // refuses an acceptance at a cut that has moved since.
    var shownTerms = orgTermsNow();

    function take(anonymous) {
      // Through `once`, keyed as the board's button is drawn, so the button
      // is disabled from the moment an answer is picked until the reply.
      once('accept:' + contract.id, function () {
      // The stake this player was shown, sent back with the acceptance.
      // The server refuses if it is not the stake on the contract, so the
      // figure on the dialog and the figure debited are the same number by
      // construction rather than by timing.
      return post('accept', {
        id: contract.id, anonymous: anonymous,
        penaltyAmount: contract.penaltyAmount || 0,
        // And the time left as it was shown, the band the stake is forfeit
        // to: shorter now, the server refuses rather than takes the stake.
        timeLeft: contract.timeLeft,
        // And the anonymity fee and its account, as the dialog said them,
        // and the organisation's cut where one was shown, with the terms
        // the placer may change until somebody accepts, as the card showed
        // them: how it is completed, whether it was placed anonymously, and
        // the buyout where the card carries one. The server refuses
        // (rule_changed, terms_changed) rather than takes it on terms that
        // moved under the card.
        shown: (function () {
          var echo = acceptEcho(contract, shownFee, feeAccount);
          if (shownTerms) { echo.orgCut = Number(shownTerms.orgPercent) || 0; }
          return echo;
        })()
      }).then(function (r) {
        if (!r.ok) {
          // Told and shown. A message saying the figure changed, with the
          // old figure still on screen, is half an answer.
          // Likewise a card that is out of date in some other way: closed,
          // taken, or already theirs. The board is only as fresh as its last
          // read, and leaving the stale card up invites the same tap again.
          // And one somebody else took (locked), one that is gone, one this
          // hitman was taken off, and one inside the stake window: each left
          // Accept live on a card the server could only refuse again.
          if (r.err === 'terms_changed' || r.err === 'rule_changed' || r.err === 'already_settled'
              || r.err === 'contract_full' || r.err === 'already_holding'
              || r.err === 'too_little_time' || r.err === 'locked'
              || r.err === 'not_found' || r.err === 'hold_released'
              || r.err === 'staff_barred') {
            refresh();
          }
          // How much, and from where (§14.18: "naming the shortfall").
          // The server says which charge it was short for and the figure it
          // asked; without that (an older server) both are named, since it
          // can be the fee alone, and that the stake is never split between
          // bank and cash.
          var short = r.data || {};
          var stake = contract.penaltyAmount || 0;
          var fee = anonymous ? anonymityFee('hitman') : 0;
          var from = feeAccount;
          if (short.part === 'stake' && Number(short.need) > 0) {
            stake = Number(short.need);
            // With it, the fee the server would have charged, 0 where none
            // is owed: back on a contract whose anonymity was paid for
            // already, or named to its client. The setting alone named a fee
            // to find that would never have been taken.
            if (short.fee !== undefined && short.fee !== null) {
              fee = Number(short.fee) || 0;
              if (short.feeAccount === 'bank' || short.feeAccount === 'cash') {
                from = short.feeAccount;
              }
            }
          }
          if (short.part === 'fee' && Number(short.need) > 0) {
            fee = Number(short.need);
            if (short.account === 'bank' || short.account === 'cash') { from = short.account; }
          }
          var moved = acceptMovedText(r);
          if (moved) { return say(moved); }
          if (r.err === 'insufficient_funds' && (stake > 0 || fee > 0)) {
            return say(stake > 0 && short.part !== 'fee'
              ? t('app.you_need') + money(stake) + t('app.in_your_bank_or_in_your')
                + t('app.stake_it_is_not_split_between')
                + (fee > 0 ? t('app.plus_fee_for_anonymity', money(fee), from) : '') + '.'
              : t('app.anonymity_costs') + money(fee) + t('app.from_your') + from
                + t('app.and_it_does_not_hold_that'));
          }
          // Holding as many as the server allows. The shared wording said
          // "too many", with no number and nothing to do about it.
          if (r.err === 'limit_reached') {
            var most = Number(r.data && r.data.max);
            return say(t('app.you_are_already_working')
              + (most > 0 ? tn('app.contracts_the_most_allowed', most) : t('app.as_many_contracts_as_this_server'))
              + t('app.finish_one_under_mine_before_you'));
          }
          return fail(r);
        }
        // Worded from what the server recorded, not from the button. A
        // hitman the client already knows by name on this contract comes
        // back under it, and was told "accepted, anonymously".
        var recorded = r.data && typeof r.data.myAnonymous === 'boolean'
          ? r.data.myAnonymous : anonymous;
        // And what anonymity cost, as the server took it: nothing on a
        // contract whose anonymity this hitman already paid for.
        var charged = (r.data && r.data.charged) || {};
        var cost = Number(charged.fee) > 0
          ? t('app.anonymity_cost') + money(Number(charged.fee)) + t('app.from_your')
            + (charged.account === 'cash' ? 'cash' : 'bank') + '.' : '';
        say(recorded ? t('app.contract_accepted_anonymously') + cost
          : anonymous ? t('app.contract_accepted_under_your_name_the')
            + t('app.already_knows_you_on_this_one')
          : t('app.contract_accepted'), 'ok');
        // Straight to it under Mine, first and marked: the next thing a
        // hitman does is work it, and the board only said it was taken.
        state.focus = contract.id;
        if (state.tab === 'board') { navigated(); state.tab = 'mine'; }
        // Held until the refresh lands, not just the reply: the board still
        // has the card as it was, and Accept came back live on it for one
        // round trip, under the notice saying it was taken.
        return refresh();
      });
      });
    }

    /* The officer warning, where the server asks for one, is the head of
       the same dialog rather than a dialog of its own before it: one tap
       less, and the warning is on screen as the choice is made. */
    var warned = contract.targetProtected && settings().warnHitman !== false;

    function chooseAnonymity() {
      feeAccount = anonymityAccount();
      // Where the server does not allow accepting anonymously, the dialog
      // offers no such choice and quotes no fee: Accept takes it under the
      // hitman's name.
      var offered = anonymityOffered('hitman', contract.targetProtected === true);
      shownFee = offered ? anonymityFee('hitman') : 0;
      shownTerms = orgTermsNow();
      // Only what accepting does, under the switches now. "Law enforcement
      // has already been advised" read today's switch, not whether a
      // bulletin went for this contract.
      var warning = warned
        ? t('app.this_contract_is_on') + protectedWords(contract.targetProtectedAs).noun + '.'
          + (advised('accepted')
            ? t('app.accepting_alerts_every_officer_in_the') : '') + ' '
        : '';
      state.dialog = {
        kind: 'choice',
        question: warned ? t('app.take_it_anyway') + (offered ? t('app.anonymously_2') : '?')
          : offered ? t('app.take_this_one_anonymously') : t('app.take_this_contract'),
        detail: warning + (offered ? t('app.the_person_who_placed_it_will')
          : t('app.the_person_who_placed_it_will_2'))
          // And the target too, where the server shows named operatives to
          // them (Config.TargetClasses.default.ShowOperativeNames).
          + (namesToTarget(contract.targetProtected === true)
            ? (offered ? t('app.under_your_name_the_target_sees') : t('app.so_will_the_target'))
            : '')
          // What finishes it, before it is taken: the card's chip says it,
          // and this is where a hitman agrees to the terms. One used to
          // being paid for a kill would otherwise find out after making one.
          // To whom, too: "delivering the target alive" left a hitman asking
          // where, and "the client" did not tell them.
          + (aliveOnly(contract)
            ? t('app.this_contract_only_pays_when_you')
              + t('app.person_who_placed_it_killing_them')
            : '')
          + (shownFee > 0
            ? t('app.anonymity_costs_2') + money(shownFee) + t('app.from_your')
              + feeAccount + '.'
            : '')
          // The organisation's cut, as the card said it.
          + (shownTerms ? ' ' + orgCutText(shownTerms) : '')
          // Taken whole from one account, which nothing said until a
          // player with half in each was refused.
          + (contract.penaltyAmount > 0
            ? t('app.accepting_stakes') + money(contract.penaltyAmount)
              + t('app.of_yours_taken_whole_from_your')
              + t('app.returned_when_you_finish') + stakeRule(contract)
            : '')
          // How much time that is. The stake is forfeit to the deadline, and
          // nothing on the dialog said when it was.
          + (bandOf(contract) ? t('app.it_has_2') + bandOf(contract).text.toLowerCase() + '.' : '')
          + exclusiveRule(contract),
        options: offered ? [
          { label: t('app.anonymously'), primary: true, run: function () { take(true); } },
          { label: t('app.under_my_name'), run: function () { take(false); } }
        ] : [
          { label: t('app.accept'), primary: true, run: function () { take(false); } }
        ],
        // Drawn again from the settings when they change while it is open
        // (readBoard), so the fee it shows, and sends back, is the fee now.
        redo: chooseAnonymity
      };
      render();
    }

    chooseAnonymity();
  }

  /* The rules of finishing. On a contract only a live handover completes,
     on every card, whoever is holding it: the distance, the hold, who the
     target is brought to and how to find them are what this contract asks,
     not a lesson a hitman learns once — one who had finished contracts
     under 'either' was shown only the "Alive only" chip. A contract a kill
     can finish too keeps the first-job hint it had, shown until the hitman
     has finished one. Their record comes with the ledger, which loads with
     every refresh; until it has, that one is not drawn rather than a line
     that vanishes a moment later. */
  function howToFinish(contract) {
    // On a contract a kill cannot finish, the kill's half of this told a
    // new hitman the one thing that would never pay. What it does instead
    // is said, since a kill still happens: they come back, and the contract
    // is still open. And to whom: "the client" named nobody a new hitman
    // knew, on the one rule this server is run on.
    // While a handover runs, the distance it was armed with: it keeps that
    // one whatever the server is set to since, and the card told the hitman
    // the new one.
    var armed = runningRadius(contract);
    if (aliveOnly(contract)) {
      return el('div', 'hint', deliverAliveSteps(armed) + placerLine(contract));
    }
    var record = state.ledger && state.ledger.record;
    if (!record || record.completed !== 0) { return null; }
    // A contract a kill can finish too keeps the words it had.
    var kidnap = settings().kidnap || {};
    var within = metres(armed);
    var deliver = (mustRestrain() ? t('app.restrain_them_or_get_them_into')
      : t('app.bring_them_alive_and_conscious'))
      + (within ? t('app.within_m_of', within) : t('app.to_word'))
      + t('app.the_person_who_placed_it_tap')
      + (kidnap.seconds ? t('app.for_seconds_short', kidnap.seconds) : t('app.until_it_finishes'));
    // With kill photos off (settings().killPhotos) nothing is photographed:
    // Verify kill is checked at the scene.
    var text = t('app.kill_a_downed_target_is_not')
        + (settings().killPhotos === false
          ? t('app.the_body_and_tap_verify_kill')
          : t('app.the_body_and_tap_verify_kill_2'))
        + t('app.alive_x', deliver);
    // Nobody can be met who cannot be found.
    if (contract.creatorAnonymous && settings().relay !== false) {
      text += t('app.your_client_is_anonymous_use_message')
        + t('app.before_you_grab_them');
    }
    return el('div', 'hint', text);
  }

  /* ---------- the live handover, in words ----------

     Every line that tells somebody how a live handover works says it the
     same way, from the server's own Config.Kidnap (settings().kidnap): how
     close the person who placed the contract has to be, and how long the
     target is held there. Nothing here hard-codes either figure; a page
     that has not read them says "close" and "until it finishes". */

  // Metres as the server set them, without a trailing ".0".
  function metres(radius) {
    var r = Number(radius);
    if (!(r > 0)) { r = Number((settings().kidnap || {}).radius); }
    if (!(r > 0)) { return null; }
    return String(Math.round(r * 10) / 10);
  }

  // "within 12 m of you and the target", for a missing placer.
  function nearPlacer(radius) {
    var m = metres(radius);
    return m ? t('app.within_m_of_you_and_target', m)
      : t('app.right_there_with_you_and_the');
  }

  /* The radius of a handover running on this contract, as its countdown
     reports it (progress.radius), or null when none is running: the live
     poll's, or the snapshot the card came with, as the countdown bar
     draws. */
  function runningRadius(contract) {
    var running = state.progress[contract.id]
      || (countdownOver[contract.id] === undefined ? contract.kidnapProgress : null);
    var r = running && Number(running.radius);
    return r > 0 ? r : null;
  }

  // Whether the server wants the target restrained for a handover
  // (Config.Kidnap.RequireCoercion, sent as settings().kidnap.restrain).
  // Only false says no: a server from before the flag always wanted it.
  function mustRestrain() {
    return (settings().kidnap || {}).restrain !== false;
  }

  // What a hitman does to finish a contract only a live handover completes:
  // within `radius` (a running countdown's), or the server's where none is.
  // With no restraint required, what the handover does need, in so many
  // words: nothing tells them to cuff anybody.
  function deliverAliveSteps(radius) {
    var m = metres(radius);
    var seconds = Number((settings().kidnap || {}).seconds);
    var hold = (seconds > 0 ? tn('app.for_seconds', seconds) : t('app.until_it_finishes_2'));
    // With the placer's Confirm handover on, the hold is followed by their tap.
    if ((settings().kidnap || {}).confirm === true) {
      hold += t('app.then_the_person_who_placed_it');
    }
    if (!mustRestrain()) {
      return t('app.bring_them_in_alive_take_them')
        + (m ? t('app.stay_within') + m + t('app.m_of_that_person_with_them') : t('app.stay_close_to_that_person_with'))
        + t('app.tap_deliver_alive_and_hold') + hold + t('app.they_have_to_stay_alive_conscious')
        + t('app.on_their_feet_the_whole_time')
        + t('app.the_contract_stays_open');
    }
    return t('app.bring_them_in_alive_cuff_them')
      + t('app.to_the_person_who_placed_this')
      + (m ? t('app.get_within') + m + t('app.m_of_that_person') : t('app.get_close_to_that_person'))
      + t('app.tap_deliver_alive_and_hold') + hold
      + t('app.killing_them_does_not_count_they');
  }

  // Who that person is, as far as this hitman may know: an anonymous one has
  // to be found, a named one is named.
  function placerLine(contract) {
    var relay = settings().relay !== false;
    if (contract.creatorAnonymous) {
      return relay ? t('app.the_person_who_placed_it_is')
        + t('app.agree_where_to_meet') : '';
    }
    if (contract.creatorName) {
      return t('app.the_person_who_placed_it_is_2') + contract.creatorName
        + (relay ? t('app.use_message_to_agree_where_to') : '.');
    }
    return '';
  }

  // The kill refusal on such a contract, with what to do instead.
  function aliveOnlyRefusal() {
    return t('app.this_contract_only_pays_when_you_2')
      + t('app.person_who_placed_it') + deliverAliveSteps();
  }

  // The placer's own card once a hitman has taken it, and the phone notice.
  function placerTakenText() {
    return t('app.a_hitman_took_your_contract_they')
      + t('app.stay_in_the_city') + (settings().relay !== false
        ? t('app.and_watch_your_messages') : '.');
  }

  /* ---------- the kill photo viewfinder ----------

     On a server that keeps kill photos itself (Config.Completion
     .PhotoStorage = 'server') the hitman takes the photo here rather than
     in lb-phone's camera. lb-phone draws its game camera into a canvas of
     this page (components.createGameRender, as lb-phone's own app template
     does), the client turns that camera on behind the app, and the shutter
     takes a picture of it. The picture is shrunk and encoded here and
     handed to the client, which sends it on with the token it holds: this
     page never has the token, and keeps nothing of the picture once it is
     sent. lb-phone's gallery and image host are never involved, so the
     photo does not stay on the hitman's phone.

     Drawn over everything, outside #view: the page redraws #view on every
     change, and the canvas the game camera draws into has to stay the same
     canvas for as long as the viewfinder is up. */

  // The shape asked of the game camera where the frame cannot be measured:
  // a phone held upright.
  var VIEWFINDER_ASPECT = 9 / 16;

  // The qualities a photo is encoded at, best first, until it is no bigger
  // than the server keeps.
  var PHOTO_QUALITIES = [0.8, 0.65, 0.5, 0.35];

  // A picture to draw, from the Blob the camera hands over.
  function pictureOf(blob) {
    if (typeof window.createImageBitmap === 'function') {
      return window.createImageBitmap(blob);
    }
    return new Promise(function (resolve, reject) {
      var url = window.URL.createObjectURL(blob);
      var img = new window.Image();
      img.onload = function () { window.URL.revokeObjectURL(url); resolve(img); };
      img.onerror = function () {
        window.URL.revokeObjectURL(url);
        reject({ err: 'photo_unreadable' });
      };
      img.src = url;
    });
  }

  function canvasBlob(canvas, type, quality) {
    return new Promise(function (resolve) {
      canvas.toBlob(function (blob) { resolve(blob); }, type, quality);
    });
  }

  function dataUrlOf(blob) {
    return new Promise(function (resolve, reject) {
      var reader = new window.FileReader();
      reader.onload = function () { resolve(reader.result); };
      reader.onerror = function () { reject({ err: 'photo_unreadable' }); };
      reader.readAsDataURL(blob);
    });
  }

  /* The photo as the server keeps it, as a data URI: its longest side no
     more than maxSide pixels, webp where this browser makes webp and jpeg
     where it does not (asked for webp, a browser that cannot hands back a
     PNG several times the size), at the best quality that comes in under
     maxBytes. */
  function shrinkPhoto(blob, limits) {
    var maxSide = Number(limits && limits.maxSide) || 1280;
    var maxBytes = Number(limits && limits.maxBytes) || 600000;
    return pictureOf(blob).then(function (picture) {
      var width = picture.width, height = picture.height;
      if (!(width > 0 && height > 0)) { throw { err: 'photo_unreadable' }; }
      var scale = Math.min(1, maxSide / Math.max(width, height));
      var canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(width * scale));
      canvas.height = Math.max(1, Math.round(height * scale));
      canvas.getContext('2d').drawImage(picture, 0, 0, canvas.width, canvas.height);
      if (typeof picture.close === 'function') { picture.close(); }

      var type = 'image/webp';
      function attempt(i) {
        if (i >= PHOTO_QUALITIES.length) {
          canvas.width = 0; canvas.height = 0;
          throw { err: 'photo_too_large' };
        }
        return canvasBlob(canvas, type, PHOTO_QUALITIES[i]).then(function (out) {
          if ((!out || out.type !== type) && type === 'image/webp') {
            type = 'image/jpeg';
            return canvasBlob(canvas, type, PHOTO_QUALITIES[i]);
          }
          return out;
        }).then(function (out) {
          if (!out || out.type !== type) { throw { err: 'photo_unreadable' }; }
          if (out.size > maxBytes) { return attempt(i + 1); }
          canvas.width = 0; canvas.height = 0;
          return dataUrlOf(out);
        });
      }
      return attempt(0);
    });
  }

  /* Open the viewfinder for one contract, and settle with what the claim
     came to once the photo has been sent — or with 'cancelled', which the
     page says nothing about, when the hitman backs out. */
  function viewfinder(contract, limits) {
    return new Promise(function (resolve) {
      var phone = window.components;
      var host = document.body || document.getElementById('app');
      if (!host || !phone || typeof phone.createGameRender !== 'function') {
        resolve({ ok: false, err: 'camera_unavailable' });
        return;
      }

      var shade = el('div', 'viewfinder');
      shade.id = 'viewfinder';
      shade.appendChild(el('div', 'viewfinder-hint',
        t('app.point_the_phone_at_the_body')));
      var frame = el('div', 'viewfinder-frame');
      var canvas = document.createElement('canvas');
      frame.appendChild(canvas);
      shade.appendChild(frame);
      var row = el('div', 'row');
      // Not live until the client says the rear camera is on. Until then the
      // render shows the ordinary game camera, which has the hitman in it,
      // and a quick tap sent the client that.
      var shutter = el('button', 'primary', t('app.take_photo'));
      shutter.disabled = true;
      var cancel = el('button', 'ghost', t('app.cancel'));
      row.appendChild(shutter);
      row.appendChild(cancel);
      shade.appendChild(row);
      host.appendChild(shade);

      var gameRender = null;
      var watch = null;
      var settled = false;

      // The game camera off and its canvas let go of, the moment it has
      // done its part.
      function stopCamera() {
        if (watch !== null) { clearInterval(watch); watch = null; }
        if (gameRender) {
          var done = gameRender;
          gameRender = null;
          try { if (!done.destroyed) { done.destroy(); } } catch (err) { /* already gone */ }
          post('verificationCamera', { on: false });
        }
        canvas.width = 0;
        canvas.height = 0;
      }

      function finish(result) {
        if (settled) { return; }
        settled = true;
        stopCamera();
        if (shade.parentNode) { shade.parentNode.removeChild(shade); }
        resolve(result);
      }

      try {
        gameRender = phone.createGameRender(canvas);
        var w = frame.clientWidth, h = frame.clientHeight;
        gameRender.resizeByAspect(w > 0 && h > 0 ? w / h : VIEWFINDER_ASPECT);
      } catch (err) {
        finish({ ok: false, err: 'camera_unavailable' });
        return;
      }

      post('verificationCamera', { on: true }).then(function (r) {
        if (!r.ok) { finish({ ok: false, err: r.err || 'camera_unavailable' }); return; }
        if (!settled) { shutter.disabled = false; }
      });

      // lb-phone takes the game render down itself when the phone is put
      // away, as its own template watches for.
      watch = setInterval(function () {
        if (gameRender && gameRender.destroyed) { finish({ ok: false, err: 'cancelled' }); }
      }, 1000);

      cancel.onclick = function () { finish({ ok: false, err: 'cancelled' }); };
      shutter.onclick = function () {
        if (!gameRender || shutter.disabled) { return; }
        shutter.disabled = true;
        cancel.disabled = true;
        shutter.textContent = t('app.sending');
        var taking = gameRender;
        Promise.resolve().then(function () {
          return taking.takePhoto();
        }).then(function (blob) {
          stopCamera();
          return shrinkPhoto(blob, limits);
        }).then(function (image) {
          return post('sendVerificationPhoto', { id: contract.id, image: image });
        }).then(finish, function (err) {
          finish({ ok: false, err: (err && err.err) || 'photo_unreadable' });
        });
      };
    });
  }

  /* Which contracts last answered Verify kill with no kill at all. The rate
     limit's reassurance that "the kill is still yours" is untrue for those. */
  var noKillOn = {};

  /* With the camera: a token, then lb-phone's camera or the viewfinder,
     then the claim. */
  function withPhoto(contract) {
    return post('takeVerificationPhoto', { id: contract.id }).then(function (r) {
      // A server that keeps its photos itself answers with the viewfinder
      // to open rather than with the claim. The claim comes back once the
      // photo taken in it has been sent.
      if (r.ok && r.data && r.data.viewfinder) { return viewfinder(contract, r.data); }
      return r;
    });
  }

  /* Without one, where the server takes no kill photos
     (Config.Completion.KillPhotos): it checks the scene and answers with
     the claim. No camera, no viewfinder, nothing photographed. */
  function atTheScene(contract) {
    return post('verifyKill', { id: contract.id });
  }

  function verifyKill(contract) {
    delete state.lastRefusal[contract.id];
    // Which the server does is in its settings. One switched since they
    // were read answers the other way's own refusal, a camera with no
    // token (photo_gone) or a scene that needs a photo (photo_required),
    // and the other way is tried once, so the tap still does what it says.
    // Whatever answered last decides the words: with no photo taken,
    // nothing here says to photograph anything.
    var noPhoto = settings().killPhotos === false;
    // Returned, so `once` knows when the camera and the upload are done.
    var asked = noPhoto
      ? atTheScene(contract).then(function (r) {
        if (r.ok || r.err !== 'photo_required') { return r; }
        noPhoto = false;
        return withPhoto(contract);
      })
      : withPhoto(contract).then(function (r) {
        if (r.ok || r.err !== 'photo_gone') { return r; }
        noPhoto = true;
        return atTheScene(contract);
      });
    return asked.then(function (r) {
      if (!r.ok) {
        /* Two codes mean something different on this path than in the shared
           table, and both reach a hitman standing over a body they have just
           photographed.

           target_protected is worded there for the CREATION path — "That
           target cannot be listed right now" — which is a rule about placing
           contracts on people, not about a kill. armKidnap, the other
           fulfilment route, already words the same code correctly for a
           player in the field. This one did not.

           invalid_reward likewise belongs to the Place form.

           The two protection rules are worded for the kill too. One sentence
           said "they only just got up" to a hitman over a target who had just
           logged in, and promised a retry the hold on the kill can outlast. */
        var noKill = noKillOn[contract.id];
        noKillOn[contract.id] = r.err === 'no_kill_to_verify'
          || r.err === 'kill_unobserved' || r.err === 'kill_lost_restart'
          || r.err === 'kill_too_soon'
          || (noKill && r.err === 'rate_limited');
        /* How long the protection still runs, which the server says only when
           the kill outlasts it; when it does not, the answer is kill_too_soon
           and waiting cannot help. "It counts if they are still lying dead
           when that protection runs out" was said either way, and the kill
           lapsed first in the commonest case. */
        var left = Number(r.data && r.data.secondsLeft);
        var wait = left > 0
          ? t('app.it_counts_if_they_are_still') + waitText(left)
            + t('app.tap_verify_kill_again_then')
          : '';
        var rule = r.data && r.data.rule;
        var here = {
          target_just_up: t('app.they_had_only_just_got_back')
            + t('app.so_the_kill_does_not_count') + wait,
          target_just_on: t('app.they_had_only_just_come_into')
            + t('app.does_not_count_yet') + wait,
          kill_too_soon: rule === 'target_just_on'
            ? t('app.they_had_only_just_come_into_2')
            : t('app.they_had_only_just_got_back_2'),
          target_protected: t('app.they_are_protected_right_now_so')
            + 'count.',
          rate_limited: t('app.too_many_attempts_just_now_wait')
            + (noKill ? t('app.try_again_2')
              : noPhoto ? t('app.tap_verify_kill_again_the_kill')
                : t('app.photograph_them_again_the_kill_is'))
        };
        // The refusals that speak of a photo, said for a kill checked at
        // the scene where no photo is taken.
        if (noPhoto) {
          here.no_kill_to_verify = t('app.no_kill_on_this_contract_is')
            + t('app.down_is_not_dead_if_they')
            + t('app.over_the_body_and_tap_verify')
            + t('app.just_finished_them_give_it_a');
          here.photo_too_far = t('app.you_are_too_far_from_the')
            + t('app.verify_kill_again');
          here.photo_revived = t('app.they_were_brought_back_before_you')
            + t('app.this_is_not_an_elimination_any');
          here.photo_still_down = t('app.they_are_down_not_dead_finish')
            + 'kill.';
          here.token_invalid = t('app.that_kill_is_no_longer_the')
            + t('app.body_and_tap_verify_kill_again');
        }
        // Kept on the card as well as said: the notice is read by someone
        // just back from the camera, and it is the only thing that says
        // what to fix before the kill runs out.
        var why = here[r.err] || failText(r);
        if (why) { state.lastRefusal[contract.id] = why; }
        return here[r.err] ? say(here[r.err]) : fail(r);
      }

      // Not "Payment released" unconditionally. A reward that includes items
      // or a weapon can be verified and then fail to reach a hitman whose
      // pockets are full: the server queues it and hands it over later,
      // which is right — but the app said the money had been released, so
      // the hitman stood there with nothing and no reason to think anything
      // was owed. The server says which happened; this now reads it.
      var owed = r.data && Number(r.data.pending) > 0;
      // Held for proof of intent (Config.Roleplay.ProofOfIntent): not room.
      var held = r.data && r.data.intentHold;
      say((held ? intentHoldText(held, t('app.verified'))
        : owed
        ? t('app.verified_some_of_the_reward_would')
          + t('app.you_make_room_and_it_will') + staffChecking(r.data)
        : t('app.verified_payment_released') + staffChecking(r.data)) + reputationText(r.data), 'ok');
      refresh();
    });
  }

  /* Proof items (Config.Improvements.ProofItems): the server checks the
     item, the target it names and the distance to the placer, and pays as
     for a verified kill. */
  function handOverProof(contract) {
    delete state.lastRefusal[contract.id];
    return post('proofItem', { id: contract.id }).then(function (r) {
      if (!r.ok) { return fail(r); }
      var owed = r.data && Number(r.data.pending) > 0;
      var held = r.data && r.data.intentHold;
      say((held ? intentHoldText(held, t('app.handed_over'))
        : owed
        ? t('app.handed_over_some_of_the_reward')
          + t('app.you_make_room_and_it_will') + staffChecking(r.data)
        : t('app.handed_over_payment_released') + staffChecking(r.data)) + reputationText(r.data), 'ok');
      refresh();
    });
  }

  function armKidnap(contract) {
    // A different go at the same contract: the photo's refusal is stale.
    delete state.lastRefusal[contract.id];
    return post('armKidnap', { id: contract.id }).then(function (r) {
      if (!r.ok) {
        // The person who placed it, by what they are to this hitman. An
        // anonymous one has to be found first, and Message is how.
        var findThem = contract.creatorAnonymous && settings().relay !== false
          ? t('app.they_are_anonymous_use_message_to') : '';
        var reasons = {
          // On a contract only a handover completes, a dead target is the
          // kill that does not count: said, with what still works.
          target_not_conscious: t('app.the_target_must_be_alive_and')
            + (aliveOnly(contract) ? t('app.killing_them_does_not_count_once')
              + t('app.are_back_on_their_feet_bring') : ''),
          target_too_hurt: t('app.the_target_is_too_badly_hurt')
            + t('app.patched_up_first'),
          not_coerced: t('app.the_target_must_be_restrained_or'),
          // Said as the rule, which is the same whether they are offline or
          // only far away: an anonymous one absent is told as this too
          // (Kidnap.conditionsMet), so neither may be guessed from it.
          creator_too_far: t('app.the_person_who_placed_this_contract_2')
            + nearPlacer() + t('app.take_the_target_to_them_then')
            + 'again.' + findThem,
          target_too_far: t('app.keep_the_target_close'),
          // Another instance (an interior, an apartment) is somewhere
          // else, whatever the coordinates say.
          not_together: t('app.you_and_the_target_must_be')
            + t('app.of_you_inside_somewhere_the_other'),
          // A live delivery skips the rule about getting back up, so that is
          // never why; it said so to hitmen holding somebody fresh in town.
          target_just_on: t('app.they_have_only_just_come_into')
            + t('app.will_not_count_until_they_have'),
          target_protected: t('app.they_are_protected_from_contracts_right')
            + t('app.handover_will_not_count'),
          party_offline: t('app.everyone_has_to_be_online_for')
            + t('app.placed_this_contract_must_be_in') + nearPlacer() + '.',
          limit_reached: t('app.too_many_handovers_in_progress_try')
        };
        // With how long, which the reply carries (failText).
        if (r.err === 'rate_limited') { return fail(r); }
        if (r.err === 'handover_cooldown' && r.data && Number(r.data.retryAfter) > 0) { return fail(r); }
        return say(reasons[r.err] || ERRORS[r.err] || t('app.cannot_start_the_handover'));
      }
      say(t('app.hold_position_2'), 'caution');
      pollCountdown(contract.id);
    });
  }

  /* The one timer in this app, and it had three faults.
  
     It called render() directly, once a second, on whatever view happened to
     be open — so a hitman who armed a handover and then went to the Place
     tab had the whole form torn down and rebuilt under them every second for
     two minutes, losing scroll position each time.
  
     It stopped on any unsuccessful reply and left state.progress alone, so
     the bar froze at its last value and stayed there. The handover ENDING —
     the target broke loose, the hitman wandered off, the grace ran out — is
     an unsuccessful reply, so the most important outcome of a delivery was
     indistinguishable from a dropped packet and neither was ever mentioned.
  
     And nothing cancelled it when the player left the screen, so two of them
     could run at once against different contracts. */
  var countdownTimer = null;
  var countdownFor = null;

  /* Handovers this page has seen end, against the Mine load that was
     newest when it did. The card restarts the poll from the projection's
     snapshot, and Mine as last read still carried one: the first redraw
     after an ending — the board's reply, landing before Mine's — drew the
     old bar again and polled a handover that was over, so "You are off the
     contract." became "The handover ended. Get them back to the person who
     placed this contract and try again." The snapshot is trusted again from
     the next Mine read. */
  var countdownOver = {};

  /* The running poll's own tick, so the page being put away or shown again
     can re-arm it at the other pace (armCountdown), and a reply can tell
     whether the poll that asked is still the one running. */
  var countdownTick = null;

  /* Once a second on screen. Put away, once every five: the handover runs
     on the server whatever this page does, the phone tells the hitman how
     it ended, and the server keeps that answer for two minutes, so a page
     shown again still hears how it went and says the same. */
  var COUNTDOWN_MS = 1000;
  var COUNTDOWN_HIDDEN_MS = 5000;

  function stopCountdown() {
    if (countdownTimer) { clearInterval(countdownTimer); countdownTimer = null; }
    countdownTick = null;
    countdownFor = null;
  }

  function armCountdown() {
    if (!countdownTick) { return; }
    if (countdownTimer) { clearInterval(countdownTimer); }
    countdownTimer = setInterval(countdownTick, pageShown() ? COUNTDOWN_MS : COUNTDOWN_HIDDEN_MS);
  }

  function endCountdown(id) {
    if (countdownFor === id) { stopCountdown(); }
    delete state.progress[id];
    countdownOver[id] = loadSeq.mine;
  }

  function pollCountdown(id) {
    stopCountdown();
    countdownFor = id;
    delete countdownOver[id];

    // Long enough for the server's own countdown and its grace, read from
    // the progress it sends; two minutes when there is none yet.
    function allowance() {
      var p = state.progress[id];
      var ms = p && Number(p.required) > 0
        ? Number(p.required) * 1000 + (Number(p.graceTotal) || 0) + 30000 : 120000;
      return Date.now() + ms;
    }
    var deadline = allowance();
    // Until when polls are held back after a rate limit (below).
    var holdUntil = 0;

    var tick = function () {
      if (Date.now() > deadline) {
        endCountdown(id);
        say(t('app.lost_track_of_the_handover_your'));
        refresh();
        return;
      }
      if (Date.now() < holdUntil) { return; }

      post('kidnapProgress', { id: id }).then(function (r) {
        /* A reply to a poll this page has since stopped — the hitman walked
           away while it was in flight, or a newer handover replaced it. It
           answered "no handover" to a hitman who had just left and told
           them to get the target back and try again, and a stale reply
           could stop the poller that replaced it. */
        if (countdownTick !== tick) { return; }
        if (r.ok && r.data && r.data.done) {
          // Over, and the server says how. Every ending used to reach this
          // poller the same way — the countdown gone — so a hitman who had
          // just been PAID for a handover was told it had ended and to try
          // again, and one refused at the end was told to try again on a
          // refusal no retry fixes.
          endCountdown(id);
          handoverEnded(r.data);
          refresh();
          return;
        }
        /* A throttle, not an ending: the handover runs on the server
           whatever this poll heard. It was read as the end, so the bar
           went, "Slow down." was said, everything was read again, and the
           next Mine read started the poll that was refused again. The bar
           stays as it was, nothing is said or read, and polls wait out the
           wait the server named. */
        if (!r.ok && r.err === 'rate_limited') {
          holdUntil = Date.now() + (Number(r.data && r.data.retryAfter) || 1) * 1000;
          deadline = Math.max(deadline, holdUntil + 30000);
          return;
        }
        if (!r.ok || !r.data || r.data.elapsed === undefined) {
          // Over, one way or another. The bar goes rather than freezing,
          // and the player is told — a delivery that simply stops moving is
          // the one thing a hitman holding a target cannot interpret.
          endCountdown(id);
          say(r.err === 'no_handover' || r.err === 'not_found'
                || r.err === 'bad_state'
            ? t('app.the_handover_ended_get_them_back')
              + t('app.contract_and_try_again')
            : (ERRORS[r.err] || t('app.lost_track_of_the_handover')));
          refresh();
          return;
        }

        // Keep the answer. Rendering from the projection's snapshot draws
        // the same frozen bar every second no matter how often we poll.
        state.progress[id] = r.data;
        deadline = allowance();

        // Painted where it is, when the bar is on screen and nothing else
        // is about to redraw it: a whole tab rebuilt every second to move
        // one bar was a frame's worth of the phone's time, every second of
        // a handover. Otherwise coalesced, and only where the bar is drawn
        // — Mine and On me; redrawing the Place form once a second throws
        // away what the player is typing into it.
        var drawn = countdownBars[id];
        if (drawn && drawn.parentNode && !redrawQueued && !state.dialog) {
          var next = countdown(r.data);
          drawn.className = next.className;
          drawn.innerHTML = '';
          Array.prototype.slice.call(next.children).forEach(function (part) {
            drawn.appendChild(part);
          });
        } else if (state.tab === 'mine' || state.tab === 'onme') {
          redraw();
        }

        // A full bar is not the end. A countdown that has run its course is
        // still reported while its payout waits behind another one being
        // settled, and stopping here left the hitman with a full bar and no
        // word of how it ended. The poll that finds it over carries that
        // (`done` above), and the deadline bounds the rest.
      });
    };
    countdownTick = tick;
    armCountdown();
  }

  /* What is said of a payment whose give raised and whose arrival could not
     be read: it was left for staff, and no retry gives it, so "make room and
     it will be handed over" was untrue of it. The server counts it apart
     (`parked`) in a claim's answer, a handover's ending, and a withdrawal's. */
  function staffChecking(data) {
    var parked = data && (data.parked === true || Number(data.parked) > 0);
    return parked
      ? t('app.part_of_it_could_not_be')
      : '';
  }

  /* A wait the server measured, in words: seconds under a minute, else
     minutes, rounded up. */
  function waitText(seconds) {
    var s = Math.max(0, Math.ceil(Number(seconds) || 0));
    if (s < 60) { return tn('app.seconds_count', s); }
    return durationText(Math.ceil(s / 60));
  }

  /* What a finished handover means, in words. The server keeps how each
     one ended for a couple of minutes; the phone notification says the same
     thing to a hitman who has closed the app. */
  function handoverEnded(ended) {
    if (ended.outcome === 'paid') {
      return say(ended.pending
        ? t('app.delivered_some_of_the_reward_would')
          + t('app.you_make_room_and_it_will') + staffChecking(ended)
        : t('app.delivered_payment_released') + staffChecking(ended), 'ok');
    }
    if (ended.outcome === 'closed') {
      return say(t('app.the_contract_closed_before_the_handover'));
    }
    if (ended.outcome === 'refused') {
      // Stopped by a staff freeze, mid-countdown or as it was being paid:
      // "finished" was untrue of the first.
      if (ended.reason === 'contract_frozen') {
        return say(t('app.the_handover_was_not_paid') + ERRORS.contract_frozen);
      }
      var refused = {
        bad_state: t('app.the_contract_closed_before_the_handover'),
        locked: t('app.another_payout_on_this_contract_was')
          + t('app.moment_and_it_got_there_first'),
        target_just_on: t('app.they_had_only_just_come_into_3')
          + t('app.handover_does_not_count'),
        target_protected: t('app.they_were_protected_from_contracts_so')
          + t('app.does_not_count')
      };
      return say(t('app.the_handover_finished_but_was_not')
        + (refused[ended.reason] || ERRORS[ended.reason] || ''));
    }
    // The two that mean the person who placed the contract was missing say
    // so, with how close they have to be. "Your client did not arrive"
    // named somebody a hitman may never have been told about.
    var failed = {
      party_offline: t('app.someone_the_handover_needed_went_offline')
        + t('app.this_contract_must_be_online_and') + nearPlacer() + '.',
      creator_too_far: t('app.the_person_who_placed_this_contract_3')
        + t('app.they_must_be_online_and') + nearPlacer() + t('app.for_the_whole_handover'),
      target_not_conscious: t('app.the_target_went_down_a_handover'),
      target_too_hurt: t('app.the_target_got_too_badly_hurt'),
      not_together: t('app.you_and_the_target_were_not'),
      contract_locked: t('app.the_contract_was_stuck_settling_another')
    };
    // The placer's Confirm handover (Config.Kidnap.PlacerConfirms): a
    // decline and a window that ran out read the same.
    if (ended.reason === 'not_confirmed') {
      return say(t('app.the_person_who_placed_this_contract_4')
        + t('app.was_paid_the_contract_is_still'));
    }
    return say(t('app.the_handover_failed') + (failed[ended.reason]
      || t('app.you_lost_hold_of_the_target')) + t('app.get_them_back_to_the_person')
      + t('app.this_contract_and_try_again_in'));
  }

  /* "about 2 minutes", for the wait a hitman on the contract still has;
     null on a server that does not make them wait. */
  function buyoutWait(seconds) {
    if (!(seconds > 0)) { return null; }
    return seconds < 60 ? t('app.under_a_minute')
      : t('app.about_duration', durationText(Math.ceil(seconds / 60)));
  }

  /* What every buyout says, in its dialog and once paid (spec §14.40):
     closing one contract is not a promise that none other is out. */
  var NOT_THE_LAST = t('app.closing_this_one_does_not_mean');

  function bailout(contract) {
    var amount = money(contract.bailoutAmount);
    /* Which pocket it comes from, said before they agree: the server takes
       the whole of it from the bank, or the whole of it from cash, and never
       splits it — so $50,000 in each fails a $90,000 buyout, and nothing
       said why.

       And when it closes. With a hitman already on it the buyout waits out
       a delay, the contract stays live, and a hitman who finishes it first
       is paid while the target's money comes back. "Close this contract"
       read as safe at once. Not "it closes now" otherwise: a hitman may take
       it between this dialog and the tap, and the reply says which. */
    var wait = buyoutWait(Number(settings().buyoutDelaySeconds) || 0);
    ask(t('app.pay_to_close_this_contract', amount),
        t('app.the_person_who_placed_it_gets')
          + t('app.full_from_your_bank_or_from')
          + t('app.never_split_between_them')
          + (wait && Number(contract.hitmenActive) > 0
            ? t('app.a_hitman_is_already_on_you') + wait + t('app.more_to_finish_it')
              + t('app.if_they_do_your') + amount + t('app.comes_back')
            : t('app.if_nobody_has_taken_it_yet'))
          // §14.40: another may be out, inside its wait and not shown yet.
          + ' ' + NOT_THE_LAST,
        function () {
          // Through `once`, so the button is disabled for the round trip: up
          // to half a million, and a second tap sent a second request.
          once('bailout:' + contract.id, function () {
            return post('bailout', { id: contract.id, shown: Number(contract.bailoutAmount) || 0 })
              .then(function (r) {
              if (!r.ok) {
                // The placer changed the price under the dialog.
                if (r.err === 'terms_changed' && r.data && typeof r.data.amount === 'number') {
                  say(t('app.the_buyout_now_costs') + money(r.data.amount) + t('app.nothing_was_taken'));
                  return refresh();
                }
                // The figure the server asked for, when it says: the price
                // can have been re-set under the dialog.
                if (r.err === 'insufficient_funds') {
                  var need = Number(r.data && r.data.need) > 0 ? money(r.data.need) : amount;
                  // Not there at all, in the two together: said plainly.
                  if (r.data && r.data.short === true) {
                    return say(t('app.you_do_not_have_the_buyout') + need + t('app.nothing_was_taken'));
                  }
                  return say(t('app.your_bank_or_your_cash_has') + need
                    + t('app.on_its_own_it_is_never')
                    + t('app.account_and_try_again'));
                }
                return fail(r);
              }
              // From the reply, not from the card: a hitman may have taken
              // it since the dialog opened.
              var queued = !!(r.data && r.data.queued);
              var waited = buyoutWait(Number(settings().buyoutDelaySeconds) || 0);
              say((queued
                ? t('app.paid_it_closes_in') + (waited || t('app.a_moment'))
                  + t('app.you_are_still_a_target_until')
                : t('app.paid_contract_closed')) + ' ' + NOT_THE_LAST, 'ok');
              // Held until the card is read again, so Buy out does not come
              // back live on a contract that is paid for.
              return refresh();
            });
          });
        }, { yes: t('app.pay_x', amount) });
  }

  /* ---------- informants ----------
     Two look-ups the server sells, each a gamble paid either way: the
     target's (settings().informant), on one operative or the person who
     placed it, and the placer's (settings().placerInformant), on one
     operative who took their contract. Each card carries what its own viewer
     may pick (informantPicks, placerInformantPicks): handles the server
     minted, shown by the alias the roster already uses, which name no row.
     The roll is the server's; the page only says what it came back with. */

  /* What a look-up found, kept on the card it was paid for. It used to be
     said once, in a notice that cleared itself, and a buyer who looked away
     had paid for a name they could no longer read. */
  function informantFound(node, found) {
    asList(found).forEach(function (f) {
      if (!f || !f.text) { return; }
      node.appendChild(el('div', 'informant-answer ico i-search',
        t('app.informant_label_is', f.label || t('app.an_operative'), f.text)));
    });
  }

  /* The price of a look-up, as the button and the dialog say it. */
  function lookUpPrice(rules) {
    return Number(rules.cost) > 0 ? money(rules.cost) : 'free';
  }

  function chanceOf(value) {
    return t('app.percent_chance', Math.max(0, Math.min(100, Math.round(Number(value) || 0))));
  }

  /* Whether the target's card offers it: where the server sells look-ups,
     while they have one left on this contract (their own count), and while
     something on it is still unknown to them. The server sends no picks to
     a target it will not sell to (a member of a whitelisted job), so the
     button is never drawn for them. */
  function informantOffered(contract) {
    if (!settings().informant) { return false; }
    var left = contract.informantLeft;
    if (left !== undefined && left !== null && Number(left) <= 0) { return false; }
    return asList(contract.informantPicks).some(function (p) { return p && !p.known; });
  }

  /* Buy informant data, disabled while a purchase is in flight. */
  function informantButton(contract) {
    var key = 'informant:' + contract.id;
    if (isBusy(key)) {
      return actionButton('ghost ico i-search', t('app.buy_informant_data'), key, t('app.buying'));
    }
    var buy = el('button', 'ghost ico i-search', t('app.buy_informant_data'));
    buy.onclick = function () { buyInformant(contract); };
    return buy;
  }

  /* What the last-one and cap lines say, from the viewer's own count. */
  function lookUpsLeftText(left, most) {
    if (Number(left) === 1) { return t('app.this_is_your_last_one_on'); }
    if (Number(most) > 0) {
      return tn('app.you_can_ask_times', Number(most));
    }
    return '';
  }

  function buyInformant(contract) {
    var rules = settings().informant;
    if (!rules) { return say(t('app.this_server_does_not_run_informants')); }
    // A later look-up's own price (Config.Intel.SecondTry).
    if (typeof contract.informantCost === 'number') {
      rules = Object.assign({}, rules, { cost: contract.informantCost });
    }
    var shown = { cost: Number(rules.cost) || 0,
                  account: rules.account === 'cash' ? 'cash' : 'bank' };
    var detail = t('app.your_informant_asks_around_about_the')
      + chanceOf(rules.chance) + t('app.they_find_out_who_it_is')
      + (shown.cost > 0
        ? t('app.the_cost_from_your_is_paid_either_way', money(shown.cost), shown.account)
        : t('app.it_is_free_on_this_server'))
      + t('app.nobody_is_told_you_asked')
      + lookUpsLeftText(contract.informantLeft, rules.maxPerContract);
    var freeMinutes = Number(rules.repeatFreeMinutes) || 0;
    if (freeMinutes > 0) {
      detail += t('app.asking_about_the_same_one_again') + freeMinutes
        + t('app.minutes_repeats_the_answer_at_no');
    }
    var options = asList(contract.informantPicks).map(function (p) {
      return { pick: p.pick, label: p.label, disabled: !!p.known,
               note: p.known ? (p.named ? (p.pick === 'placer'
                 ? t('app.placed_under_their_name_you_know')
                 : t('app.took_it_under_their_name_you'))
                 : t('app.your_informant_already_found_out')) : null };
    });
    askPick(t('app.buy_informant_data_2'), detail, options, function (pick) {
      doBuyInformant(contract, shown, pick);
    }, shown.cost > 0 ? t('app.pay_x', money(shown.cost)) : t('app.ask'));
    // Drawn again from the settings when they change while it is open
    // (readBoard), so the price it quotes, and sends back, is the price now.
    if (state.dialog) {
      state.dialog.redo = function () { state.dialog = null; buyInformant(contract); };
    }
  }

  /* What a look-up came back with, in plain words. */
  function sayLookUp(data, miss) {
    var d = data || {};
    if (d.found) {
      return say(t('app.your_informant_found_out_is', d.label || t('app.they_word'), d.name || d.description), 'ok');
    }
    say((d.message || miss) + (d.repeated
      ? t('app.that_is_the_answer_you_were') : ''));
  }

  /* The refusals both informants share, in their words. */
  var INFORMANT_REFUSALS = {
    limit_reached: t('app.you_have_used_every_look_up'),
    insufficient_funds: t('app.you_cannot_afford_the_informant'),
    not_participant: t('app.this_is_not_yours_to_ask'),
    bad_state: t('app.this_server_does_not_run_informants'),
    feature_off: t('app.the_informant_is_turned_off_by')
  };

  function doBuyInformant(contract, shown, pick) {
    once('informant:' + contract.id, function () {
    return post('informant', { id: contract.id, shown: shown, pick: pick }).then(function (r) {
      if (!r.ok) {
        // The price moved since it was quoted: said, and the settings read
        // again, so the next quote is the price now. Nothing was taken.
        if (r.err === 'terms_changed') {
          fail(r);
          return refresh({ board: true });
        }
        if (INFORMANT_REFUSALS[r.err]) { say(INFORMANT_REFUSALS[r.err]); return refresh(); }
        fail(r);
        return refresh();
      }
      sayLookUp(r.data, t('app.your_informant_could_not_find_out'));
      // What was found is kept on the card too; the refresh brings it.
      refresh();
    });
    });
  }

  /* The placer's informant on their own card: the button, and under it why
     it cannot be pressed when it cannot. Nothing where the server does not
     sell it or nobody is on the contract. */
  function placerInformantRow(contract) {
    var rules = settings().placerInformant;
    if (!rules || !(Number(contract.hitmenActive) > 0)) { return null; }
    if (contract.placerInformantPicks === undefined || contract.placerInformantPicks === null) {
      return null;
    }
    var key = 'placerInformant:' + contract.id;
    var label = t('app.informant_on_an_operative') + lookUpPrice(rules);
    var wrap = el('div', 'placer-informant');
    var picks = asList(contract.placerInformantPicks);
    var left = contract.placerInformantLeft;
    var wait = Number(contract.placerInformantWait) || 0;
    // Nothing left to sell, nothing drawn: every look-up used, or every
    // operative on it already known. A disabled button there was a dead end.
    if ((left !== undefined && left !== null && Number(left) <= 0) || picks.length === 0) {
      return null;
    }
    var why = null;
    if (wait > 0) {
      why = t('app.your_informant_can_ask_again') + retryIn(wait) + '.';
    }
    var button;
    if (isBusy(key)) {
      button = actionButton('ghost ico i-search', label, key, t('app.asking'));
    } else {
      button = el('button', 'ghost ico i-search', label);
      if (why) {
        button.disabled = true;
      } else {
        button.onclick = function () { buyPlacerInformant(contract); };
      }
    }
    wrap.appendChild(button);
    if (why) { wrap.appendChild(el('div', 'hint', why)); }
    return wrap;
  }

  function buyPlacerInformant(contract) {
    var rules = settings().placerInformant;
    if (!rules) { return say(t('app.this_server_does_not_run_informants')); }
    var shown = { cost: Number(rules.cost) || 0,
                  account: rules.account === 'cash' ? 'cash' : 'bank' };
    var detail = t('app.your_informant_asks_around_about_the_2')
      + chanceOf(rules.chance) + t('app.they_find_out_who_it_is')
      + (shown.cost > 0
        ? t('app.the_cost_from_your_is_paid_either_way', money(shown.cost), shown.account)
        : t('app.it_is_free_on_this_server'))
      + t('app.if_they_do_find_out_there') + chanceOf(rules.alertChance)
      + t('app.that_operative_notices_someone_was_asking')
      + lookUpsLeftText(contract.placerInformantLeft, rules.maxPerContract);
    if (Number(rules.cooldownMinutes) > 0) {
      detail += t('app.look_ups_on_one_contract_are') + Number(rules.cooldownMinutes)
        + t('app.minutes_apart');
    }
    var options = asList(contract.placerInformantPicks).map(function (p) {
      return { pick: p.pick, label: p.label };
    });
    askPick(t('app.informant_on_an_operative_2'), detail, options, function (pick) {
      doBuyPlacerInformant(contract, shown, pick);
    }, shown.cost > 0 ? t('app.pay_x', money(shown.cost)) : t('app.ask'));
    if (state.dialog) {
      state.dialog.redo = function () { state.dialog = null; buyPlacerInformant(contract); };
    }
  }

  function doBuyPlacerInformant(contract, shown, pick) {
    once('placerInformant:' + contract.id, function () {
    return post('placerInformant', { id: contract.id, shown: shown, pick: pick })
      .then(function (r) {
        if (!r.ok) {
          if (r.err === 'terms_changed') {
            fail(r);
            return refresh({ board: true });
          }
          if (INFORMANT_REFUSALS[r.err]) { say(INFORMANT_REFUSALS[r.err]); return refresh(); }
          fail(r);
          return refresh();
        }
        sayLookUp(r.data, t('app.your_informant_could_not_find_out_2'));
        refresh();
      });
    });
  }

  // Improvements apply at once: they can only benefit the hitman.
  /* ---------- contract amendments ----------
     The server has implemented proposals, approvals, declines and expiry
     since the first commit, and nothing rendered any of it: a change could
     be proposed and the other party had no way to see it, let alone answer. */

  // A proposal in words. The kind alone ('shorten_deadline') is a wire
  // value, not something to put in front of a player.
  var AMENDMENT = {
    reduce_reward: function (p) {
      // A slot, never an amount: the server gives back a whole unclaimed
      // collection. Describing it as money was describing a payload the
      // server has never accepted.
      return t('app.give_back_payout') + ((p && p.slot) || '?')
        + t('app.returning_what_funds_it_to_the');
    },
    // With the before and after, which is what the hitman is agreeing to.
    shorten_deadline: function (p, contract) {
      var by = p && p.seconds ? Math.round(p.seconds / 60) : 0;
      var band = contract ? bandOf(contract) : null;
      return t('app.shorten_the_deadline')
        + (by ? t('app.by_duration', durationText(by)) : '')
        + (by && band ? t('app.now_band', band.text.toLowerCase()) : '');
    },
    raise_penalty: function (p) {
      return t('app.raise_the_stake') + (p && p.amount ? t('app.to_amount', money(p.amount)) : '');
    },
    change_mode: function (p) {
      return t('app.change_this_to_a') + ((p && p.mode) === 'exclusive'
        ? t('app.single_hitman_contract') : t('app.competitive_contract'));
    },
    change_reason: function (p) {
      return t('app.change_the_stated_reason') + (p && p.reason ? t('app.to_quoted', p.reason) : '');
    },
    /* Both kinds end the whole contract. The server applies an agreed
       `withdraw` exactly as it applies `cancel` — the contract closes for
       everyone on it and the escrow goes back to the client — and this read
       "Withdraw from this contract", which a client and every other
       operative read as one operative stepping away. Agreeing to that
       closed the contract under all of them, and cost the client a
       two-hour wait before they could list the same person again. */
    /* And to a hitman asked to agree, where their stake goes: back to them. */
    withdraw: function (_p, contract) {
      return t('app.call_the_whole_contract_off_it')
        + t('app.and_what_the_person_who_placed') + stakeBack(contract);
    },
    cancel: function (_p, contract) {
      return t('app.cancel_this_contract_outright_it_closes')
        + t('app.it_and_what_the_person_who') + stakeBack(contract);
    }
  };

  function stakeBack(contract) {
    return contract && contract.role === 'hitman' && Number(contract.penaltyAmount) > 0
      ? t('app.your_stake_comes_back', money(contract.penaltyAmount)) : '';
  }

  function describeAmendment(proposal, contract) {
    var describe = AMENDMENT[proposal.kind];
    // An unknown kind is still shown, because a proposal nobody can read is
    // a proposal nobody can refuse.
    return describe ? describe(proposal.payload, contract) : t('app.a_change_to_this_contract');
  }

  /* The read of each contract's proposals that is the live one: a token
     per contract, from the moment it is asked until it is answered, or
     until its retry asks again.

     Nothing said a read or a retry was already going. Every Mine reply
     asked again for each contract still unread, and every refusal kept its
     own retry going for as long as the contract stayed unread — so while
     the bucket was empty, each push added another chain per contract, the
     extra reads took the tokens the last Mine read needed, and Mine was
     replaced by "Asked too fast" over data it already held. One read at a
     time per contract now; a reply or a retry that is not the live one
     does nothing. */
  var proposalsAsking = {};

  /* Forget what is known of one contract's proposals, or of all of them,
     and any read of them still out: what it brings back is stale too. */
  function forgetProposals(id) {
    if (id === undefined) {
      state.proposals = {};
      proposalsAsking = {};
      return;
    }
    delete state.proposals[id];
    delete proposalsAsking[id];
  }

  /* What each proposal said when it was last taken, by contract, without
     the clock it counts down by: a read that only moved the clock is not
     drawn again. */
  var proposalsSeen = {};

  function proposalsText(list) {
    try {
      return JSON.stringify(list, function (key, value) {
        return (key === 'secondsLeft' || key === 'clockReadAt') ? undefined : value;
      });
    } catch (err) { return null; }
  }

  /* The proposals on every card of Mine, as the Mine reply carries them
     ({ [contractId]: proposals }): the same as one read of each, with none
     asked for. Drawn again only where one changed. */
  function takeProposals(data, proposals) {
    var changed = false;
    asList(data.created).concat(asList(data.accepted)).forEach(function (c) {
      var list = asList(proposals[c.id]);
      var text = proposalsText(list);
      delete proposalsAsking[c.id];
      if (state.proposals[c.id] !== undefined && text !== null && proposalsSeen[c.id] === text) { return; }
      proposalsSeen[c.id] = text;
      state.proposals[c.id] = list;
      stampClocks(list);
      changed = true;
    });
    if (changed) { redrawFor(['mine']); }
  }

  function loadProposals(contract) {
    var asking = proposalsAsking[contract.id] = {};
    post('amendments', { id: contract.id }).then(function (r) {
      if (proposalsAsking[contract.id] !== asking) { return; }
      /* Read in the background, so a refusal is not the player's to read.
         It raised "Slow down" on a player who had pressed nothing, and left
         the proposal undrawn until something else refreshed. Left unasked,
         and asked again once the server allows it. */
      if (!r.ok) {
        if (r.err === 'rate_limited') {
          var wait = (Number(r.data && r.data.retryAfter) || 2) * 1000;
          setTimeout(function () {
            if (proposalsAsking[contract.id] !== asking) { return; }
            // Let go first: a player who left Mine meanwhile has it asked
            // again when they come back, rather than never.
            delete proposalsAsking[contract.id];
            if (state.proposals[contract.id] === undefined
              && (state.tab === 'mine' || state.tab === 'thread')) { loadProposals(contract); }
          }, wait);
          return;
        }
        delete proposalsAsking[contract.id];
        return;
      }
      delete proposalsAsking[contract.id];
      state.proposals[contract.id] = asList(r.data);
      // Counted down from when this landed, as the cards' clocks are.
      stampClocks(state.proposals[contract.id]);
      // One per contract on the page, and only where they are drawn: on
      // Mine's cards. Redrawing for each meant a screen of five contracts
      // redrew five times, on top of the three from the refresh that asked
      // for them, whatever tab was open.
      redrawFor(['mine']);
    });
  }

  /* Refusals that mean the proposal is over, in words that say so. The
     shared table read "Not right now." or "Check what you entered." for
     them, the panel kept Agree and Decline, and every later tap said
     "Gone." */
  var PROPOSAL_OVER = {
    // Its own code since an answer refused as it went in shared bad_state
    // with this, and the last person to agree was told it had run out.
    proposal_expired: t('app.that_proposal_ran_out_before_it'),
    bad_state: t('app.that_proposal_can_no_longer_be'),
    not_found: t('app.that_proposal_has_already_been_settled'),
    already_settled: t('app.that_contract_has_closed_and_the'),
    invalid_input: t('app.agreed_but_the_contract_has_moved')
      + t('app.longer_fits_nothing_was_changed'),
    invalid_reward: t('app.agreed_but_the_contract_has_moved')
      + t('app.longer_fits_nothing_was_changed')
  };

  /* Why a change everybody agreed to did not go in, for "Agreed, but it no
     longer applies: ...". */
  var NO_LONGER_APPLIES = {
    bad_state: t('app.who_is_on_the_contract_changed'),
    invalid_input: t('app.the_contract_has_moved_on_and'),
    reward_too_small: t('app.it_would_leave_the_reward_under'),
    already_settled: t('app.the_contract_has_closed')
  };

  function answerProposal(proposal, approve, takingBack) {
    return post('respondAmendment', { id: proposal.id, approve: approve }).then(function (r) {
      if (!r.ok) {
        // Everybody agreed and the server refused it as it went in: said as
        // that, with why, and not as a proposal that lapsed.
        if (r.data && r.data.outcome === 'failed') {
          say(t('app.agreed_but_it_no_longer_applies') + (NO_LONGER_APPLIES[r.err]
            || t('app.the_contract_changed_before_it_went')) + t('app.nothing_was_changed'));
          forgetProposals();
          refresh();
          return;
        }
        if (PROPOSAL_OVER[r.err]) {
          say(PROPOSAL_OVER[r.err]);
          forgetProposals();
          refresh();
          return;
        }
        return fail(r);
      }
      var outcome = r.data && r.data.outcome;
      say(outcome === 'applied' ? t('app.agreed_the_change_is_in_effect')
        : outcome === 'declined' ? (takingBack ? t('app.taken_back_the_other_side_is') : t('app.declined'))
        : t('app.recorded_waiting_on_the_other_party'), 'ok');
      forgetProposals();
      refresh();
    });
  }

  /* "Lapses in 4 minutes", or null with no reading. A proposal lapses
     unanswered after a few minutes and neither side was told: the
     proposer saw "Waiting on 1 other party." until it silently went. */
  function lapsesIn(proposal) {
    var read = Number(proposal.secondsLeft);
    if (proposal.secondsLeft === undefined || proposal.secondsLeft === null || isNaN(read)) {
      return null;
    }
    var seconds = read - Math.floor((Date.now() - (proposal.clockReadAt || Date.now())) / 1000);
    return t('app.lapses_in') + durationText(Math.max(1, Math.ceil(seconds / 60)));
  }

  /* The second tap of an answer (README: every write takes two): a dialog
     that names the change being answered. Agree can move money at once (a
     raised stake, a lower penalty, a deadline moved). */
  function answerConfirm(proposal, contract, question, yes) {
    return { question: question, detail: describeAmendment(proposal, contract),
             yes: yes, no: t('app.not_now') };
  }

  function takeBack(proposal) {
    return actionButton('', t('app.take_it_back'), 'amend:' + proposal.id, t('app.sending'),
      function () { return answerProposal(proposal, false, true); });
  }

  // The panel under a card: everything currently on the table, and the two
  // buttons that answer it.
  function proposalPanel(contract) {
    var open = state.proposals[contract.id];
    if (!open || open.length === 0) { return null; }

    var box = el('div', 'proposals');
    open.forEach(function (proposal) {
      var item = el('div', 'proposal');
      item.appendChild(el('div', 'what', describeAmendment(proposal, contract)));
      item.appendChild(el('div', 'who',
        proposal.mine ? t('app.your_proposal') : proposal.proposer + t('app.proposed_this')));

      // What a shorter clock costs the hitman being asked, said where they
      // answer it. Agree applies at once, on its second tap (the dialog
      // that names the change).
      if (proposal.kind === 'shorten_deadline' && contract.role === 'hitman'
          && Number(contract.penaltyAmount) > 0) {
        item.appendChild(el('div', 'hint is-warn', t('app.your_stake_goes_to_the_placer', money(contract.penaltyAmount))));
      }
      var lapses = lapsesIn(proposal);

      var waiting = Number(proposal.waiting) || 0;
      if ((proposal.mine || proposal.answered) && waiting === 0) {
        /* Nobody else has to agree, so it is this player's answer that
           applies it — the server applies a proposal on the last answer it
           needs, and with nobody else on the contract that answer is theirs.
           It was drawn as "Waiting to be applied." with nothing to press, so
           it sat until it lapsed, held the contract's one open slot
           meanwhile, and was then put to the next hitman to accept. */
        item.appendChild(el('div', 'hint',
          t('app.nobody_else_is_on_this_contract')
          + (lapses ? ' ' + lapses + t('app.if_you_do_not') : '')));
        var applyRow = el('div', 'row');
        applyRow.appendChild(actionButton('primary', t('app.apply_it'),
          'amend:' + proposal.id, t('app.sending'),
          function () { return answerProposal(proposal, true); },
          answerConfirm(proposal, contract, t('app.apply_this_change_now'), t('app.yes_apply_it'))));
        if (proposal.mine) { applyRow.appendChild(takeBack(proposal)); }
        item.appendChild(applyRow);
      } else if (proposal.mine || proposal.answered) {
        item.appendChild(el('div', 'hint', tn('app.waiting_on_parties', waiting)
              + (lapses ? ' ' + lapses + t('app.if_nobody_answers') : '')));
        /* The proposer's own: taken back rather than left holding the
           contract's one open proposal until it lapses. The server takes
           their own decline as that, and tells the other side. */
        if (proposal.mine) {
          var mineRow = el('div', 'row');
          mineRow.appendChild(takeBack(proposal));
          item.appendChild(mineRow);
        }
      } else {
        if (lapses) { item.appendChild(el('div', 'hint', lapses + t('app.if_you_do_not_answer'))); }
        // Both keyed on the proposal, so answering it disables BOTH — a
        // second tap on either used to send a second answer, and the reply
        // to that one reports the change that actually applied as "Gone."
        var row = el('div', 'row');
        row.appendChild(actionButton('primary', t('app.agree'),
          'amend:' + proposal.id, t('app.sending'),
          function () { return answerProposal(proposal, true); },
          answerConfirm(proposal, contract, t('app.agree_to_this_change'), t('app.yes_agree'))));
        row.appendChild(actionButton('danger', t('app.decline'),
          'amend:' + proposal.id, t('app.sending'),
          function () { return answerProposal(proposal, false); },
          answerConfirm(proposal, contract, t('app.decline_this_change'), t('app.yes_decline'))));
        item.appendChild(row);
      }

      box.appendChild(item);
    });

    return box;
  }

  /* Seconds left on a countdown the server read (a buyout's delay, a
     cooldown), counted down from when the reply arrived; null without one.

     Never a contract's deadline: no page is sent it. The server sends how
     long a contract has left only as a rough band (timeLeft), because a
     countdown players could watch stop, or jump on when it started again,
     told them when an anonymous placer or operative logged off. */
  function secondsLeftOf(reading) {
    var read = reading.secondsLeft;
    if (read === undefined || read === null || isNaN(Number(read))) { return null; }
    if (!reading.clockReadAt) { return Number(read); }
    return Number(read) - Math.floor((Date.now() - reading.clockReadAt) / 1000);
  }

  /* The bands a contract's time left is said in, longest first, with the
     least time each one can mean, in minutes (server: Util.TIME_BANDS). */
  var TIME_BANDS = [
    { text: t('app.more_than_2_hours_left'), least: 121 },
    { text: t('app.1_2_hours_left'), least: 61 },
    { text: t('app.under_1_hour_left'), least: 16 },
    { text: t('app.under_15_minutes_left'), least: 0 }
  ];

  /* The band a contract is in, or null when it has no deadline. */
  function bandOf(contract) {
    var text = contract && contract.timeLeft;
    for (var i = 0; i < TIME_BANDS.length; i++) {
      if (TIME_BANDS[i].text === text) { return TIME_BANDS[i]; }
    }
    return null;
  }

  /* The least whole minutes a contract's band can mean, or null without
     one: what a cut may come out of, said without the exact time. */
  function minutesLeft(contract) {
    var band = bandOf(contract);
    return band ? band.least : null;
  }

  /* When each contract's countdowns were read, so a card can count a
     buyout's delay down from there. Stamped as the reply lands, not as the
     card is drawn: a card is redrawn many times from the same reply. */
  function stampClocks(list) {
    var at = Date.now();
    asList(list).forEach(function (c) { if (c && typeof c === 'object') { c.clockReadAt = at; } });
  }

  /* The time left, as the server's band says it. Never a countdown, a
     "Due now" or a stopped clock: the band moves only while the clock
     really runs, so nothing here changes when somebody logs off. */
  function clockWords(contract) {
    var band = bandOf(contract);
    if (!band) { return null; }
    // On hold by staff: the clock stands still until they release it.
    if (contract.onHold) { return { text: t('app.on_hold_2') + band.text, warn: false }; }
    var close = band.least < (Number(settings().stakeWindowMinutes) || 30);
    if (contract.role === 'hitman' && contract.penaltyAmount > 0 && close) {
      return { text: band.text + t('app.stake_at_risk'), warn: true };
    }
    return { text: band.text, warn: close };
  }

  /* A clock chip, painted once as the card is drawn. What it says is the
     server's band (timeLeft), on hold or not, and the stake window from the
     same reply: nothing in it moves until the next read, which redraws the
     card. It used to be repainted every half minute by a ticker that ran
     while any card was on screen, the phone put away included, and wrote
     the same words each time. */
  function paintClock(node, contract) {
    var words = clockWords(contract);
    if (!words) { return; }
    node.textContent = words.text;
    node.className = 'chip' + (words.warn ? ' is-warn' : ' is-label') + ' ico i-clock';
  }

  function clockChip(contract) {
    if (!clockWords(contract)) { return null; }
    var node = chip('', null, 'i-clock');
    paintClock(node, contract);
    return node;
  }

  /* "runs out in 2h", or what to say instead when there is no clock. The
     no-deadline case used to be spliced into the same sentence and read
     "runs out in no set deadline". */
  function runsOut(contract) {
    var band = bandOf(contract);
    if (!band) { return t('app.has_no_deadline'); }
    return t('app.has_band', band.text.toLowerCase());
  }

  /* "3 days ago", from a server time in seconds; null without one. */
  function agoText(at) {
    var tv = Number(at);
    if (!tv) { return null; }
    var minutes = Math.floor((Date.now() / 1000 - tv) / 60);
    if (minutes < 1) { return t('app.just_now'); }
    if (minutes < 60) { return minutes + t('app.min_ago'); }
    var hours = Math.floor(minutes / 60);
    if (hours < 24) { return hours + t('app.h_ago'); }
    var days = Math.floor(hours / 24);
    return tn('app.days_ago_count', days);
  }

  function durationText(minutes) {
    if (minutes === null || minutes === undefined) { return t('app.no_set_deadline'); }
    if (minutes <= 0) { return t('app.no_time_left'); }
    if (minutes < 60) { return tn('app.minutes_count', minutes); }
    var hours = Math.floor(minutes / 60);
    var rest = minutes % 60;
    return hours + 'h' + (rest ? ' ' + rest + 'm' : '');
  }

  /* Propose a change to a contract already under way.
     
     Both sides have to agree, so both sides need to be able to read what is
     being proposed. This used to be three bare labels and, behind two of
     them, an empty number box asking "By how much?" — with no statement of
     what the reward was, what the deadline was, or whether the figure meant
     "by" or "to". A creator and a hitman were each being asked to commit to
     a change neither could see the shape of. */
  function proposeChange(contract) {
    var hitman = contract.role === 'hitman';
    // Nobody holds it: there is nobody to agree, and the creator's own
    // confirmation applies it (sendProposal). Said so, rather than "if the
    // operative agrees" about an operative who does not exist.
    var active = Number(contract.hitmenActive) || 0;
    var untaken = !hitman && active === 0;
    var left = minutesLeft(contract);

    // What a kill pays, with the bonus apart, as the card shows it. Added
    // together, a hitman was told "Pays $75,000" on a contract whose kill
    // pays $50,000.
    //
    // A contract that pays only for a live delivery pays all of it for
    // that, so nothing is "if alive", and what it pays for is said instead.
    var reward = contract.reward || {};
    var bonusPaid = Number(reward.bonus) || 0;
    var pays = money(Number(reward.baseline) || 0)
      + (bonusPaid > 0 ? ' (+' + money(bonusPaid) + (aliveOnly(contract) ? ')' : t('app.if_alive_2')) : '')
      + (aliveOnly(contract) ? t('app.for_a_live_delivery') : '');

    // The most a stake can be, as Contracts.clampPenalty holds it: offered
    // above that, the server applies the ceiling instead of the figure typed.
    var ceiling = settings().stakeCeiling || {};
    var stakeMost = Number(ceiling.amount) || 0;
    if (ceiling.fraction) {
      stakeMost = Math.min(stakeMost,
        Math.floor((Number(contract.valueHeld) || 0) * Number(ceiling.fraction)));
    }
    var stakeNow = Number(contract.penaltyAmount) || 0;
    var exclusiveNow = contract.mode === 'exclusive';
    var reasonOn = (settings().reasonMode || 'freetext') !== 'off';

    // Payouts still to come after the one being competed for. Only those can
    // be given back, so only those are worth offering.
    var total = Number(contract.slots) || 1;
    var current = Number(contract.currentSlot) || 1;
    var spare = Math.max(0, total - current);

    // A cut has to leave this much on the clock; the server refuses one
    // that does not. Offered only out of the least its band can mean, since
    // the page is never told the exact time.
    var keep = Number(settings().deadlineMinLeftMinutes) || 5;
    var most = left === null ? 0 : left - keep;

    var options = [
      {
        label: t('app.shorten_the_deadline'),
        note: bandOf(contract) ? bandOf(contract).text + '.' : t('app.it_runs_out', runsOut(contract)),
        // Nothing to shorten without a deadline, or without time to spare.
        skip: most < 1,
        run: function () {
          if (most < 1) {
            return say(t('app.there_is_no_deadline_left_to'));
          }
          askNumber(t('app.shorten_the_deadline'),
            hitman
              ? t('app.you_are_asking_the_person_who')
              : (untaken ? t('app.nobody_has_taken_it_so_this')
                         : t('app.you_are_asking_the_operative_to')),
            function (minutes) {
              sendProposal(contract, 'shorten_deadline', { seconds: minutes * 60 });
            },
            {
              label: t('app.cut_it_short_by_minutes'),
              value: Math.min(30, most), min: 1, max: most,
              confirm: untaken ? t('app.shorten') : t('app.propose'),
              hint: function (value) {
                if (!value || value < 1 || value > most) {
                  return t('app.between_1_and_minutes_leaving', most, keep);
                }
                return t('app.it_would_then_have') + durationText(value) + t('app.less');
              }
            });
        }
      },
      {
        /* The server reduces a reward by giving back a whole unclaimed
           payout, not by shaving an amount off the live one — a slot that is
           being competed for cannot be half funded. The app used to send an
           amount, which sanitize refuses outright, so this option could
           never once have worked: every press was an invalid_input.

           It is offered only when there is actually a later payout to give
           back, rather than opening a box that always fails. A creator with
           nobody working has the direct route instead: Change reward. */
        /* The last one only. The collections are a sequence the contract
           walks through, so one out of the middle would renumber everything
           after it — the server refuses that, and this used to offer any
           later collection in a number box and let the other party find
           out by pressing Agree. There is nothing to choose, so nothing is
           asked. */
        label: t('app.give_back_the_last_payout'),
        note: spare > 0
          ? t('app.payout_of_leaving', total, total, total - 1)
          : t('app.nothing_after_the_one_being_competed'),
        skip: spare <= 0,
        run: function () {
          ask(t('app.give_back_payout_of', total, total),
            (hitman
              ? t('app.you_are_offering_to_give_up')
                + t('app.come_what_is_on_the_table')
              : t('app.this_returns_the_last_payout_to')
                + t('app.competed_for_now_is_untouched'))
              + ' ' + (total - 1) + t('app.would_remain'),
            function () {
              sendProposal(contract, 'reduce_reward', { slot: total });
            });
        }
      },
      /* The changes the server has applied on agreement since the first
         commit and nothing here could ask for. Each is offered only where
         the server can take it, and only to the client. */
      {
        // No note: the label says it, and the dialog it opens says the rest.
        // A note here pushed this dialog's own Cancel off a small screen.
        label: exclusiveNow ? t('app.open_it_to_other_hitmen') : t('app.make_it_one_hitman_only'),
        // Exclusive with two on it is a contract its own rules forbid, and
        // the server refuses it after everybody has agreed.
        skip: hitman || (!exclusiveNow && active > 1),
        run: function () {
          var mode = exclusiveNow ? 'competitive' : 'exclusive';
          ask(exclusiveNow ? t('app.open_it_to_other_hitmen_2') : t('app.make_it_one_hitman_only_2'),
            (exclusiveNow
              ? t('app.several_hitmen_can_then_take_it')
              : t('app.only_one_hitman_can_then_be'))
              + (untaken ? t('app.nobody_has_taken_it_so_this')
                : t('app.the_operative_on_it_has_to')),
            function () { sendProposal(contract, 'change_mode', { mode: mode }); },
            { yes: untaken ? t('app.change_it') : t('app.propose') });
        }
      },
      {
        // Unheld, Edit already changes it directly.
        label: t('app.change_the_reason'),
        skip: hitman || untaken || !reasonOn,
        run: function () {
          askFields(t('app.change_the_reason'),
            t('app.the_operative_has_to_agree_first'),
            reasonFields(contract),
            function (values) {
              var preset = parseInt(values.reasonPreset, 10) || 0;
              sendProposal(contract, 'change_reason', {
                reason: values.reason,
                reasonPreset: preset > 0 ? preset : undefined
              });
            }, t('app.propose'));
        }
      },
      {
        // Only while nobody holds it: a hitman staked the figure they took
        // it at, and the server refuses to change it under them. Unheld, it
        // applies on this confirm, and the next hitman stakes the new one.
        label: stakeNow > 0 ? t('app.raise_the_stake') : t('app.ask_for_a_stake'),
        note: stakeNow > 0
          ? t('app.now_to_lower_it_use_change_reward', money(stakeNow))
          : t('app.nobody_has_to_put_anything_up'),
        skip: hitman || !untaken || stakeMost <= stakeNow,
        run: function () {
          askNumber(stakeNow > 0 ? t('app.raise_the_stake') : t('app.ask_for_a_stake'),
            t('app.what_a_hitman_puts_up_when')
              + t('app.and_yours_if_they_walk_away')
              + t('app.taken_it_so_this_applies_at'),
            function (amount) {
              sendProposal(contract, 'raise_penalty', { amount: amount });
            },
            {
              label: t('app.stake'),
              value: Math.min(stakeMost, stakeNow + 1000), min: stakeNow + 1, max: stakeMost,
              confirm: t('app.set_it'),
              hint: function (value) {
                if (!value || value <= stakeNow || value > stakeMost) {
                  return t('app.between_the_most_this_contract_can_ask', money(stakeNow + 1), money(stakeMost));
                }
                return t('app.a_hitman_would_stake') + money(value) + t('app.to_take_it');
              }
            });
        }
      },
      {
        label: hitman ? t('app.call_it_off') : t('app.cancel_the_contract'),
        // Not "hand it back": agreed, this closes the whole contract for
        // everyone on it, the same as the client cancelling it. Walking away
        // alone is Abandon.
        note: hitman
          ? t('app.ask_for_the_whole_contract_to')
            + t('app.closes_for_all_of_you_and')
            + t('app.included_to_leave_on_your_own')
          : (untaken
            ? t('app.nobody_has_taken_it_so_this_2')
            : t('app.close_it_and_take_back_what')),
        run: function () {
          /* Untaken, through Withdraw itself. Sent as a proposal it closed
             the contract on this one tap — the server applies the creator's
             own proposal at once — with no confirmation, a reply that never
             mentioned the refund, and no word of anything that did not fit
             and is owed. Withdraw asks first and says both. */
          if (untaken) { return cancelContract(contract); }
          /* Asked first, as every other option here is: one stray tap put a
             contract-ending proposal in front of the other side. The client
             reads the waits an agreed cancel starts, a hitman where their
             stake goes. */
          var waits = hitman ? null : relistWaitText(contract);
          ask(hitman ? t('app.ask_to_call_it_off') : t('app.ask_to_cancel_the_contract'),
            (hitman
              ? t('app.if_everyone_agrees_it_closes_for')
                + (Number(contract.penaltyAmount) > 0
                  ? t('app.and_your') + money(contract.penaltyAmount) + t('app.stake_comes_back_to_you_2')
                  : '.')
              : t('app.if_everyone_on_it_agrees_it')
                + (waits ? ' ' + waits : ''))
              + t('app.you_can_take_the_proposal_back'),
            function () { sendProposal(contract, hitman ? 'withdraw' : 'cancel', {}); },
            { yes: t('app.propose_it'), no: t('app.keep_it') });
        }
      }
    ];

    state.dialog = {
      kind: 'choice',
      question: t('app.propose_a_change'),
      // The terms, in the header rather than on one option. What the
      // contract pays and how long is left is what every one of these
      // choices is about, and it should not disappear because the option
      // that happened to carry it does not apply here.
      detail: t('app.pays_runs_out', pays, runsOut(contract))
        + (total > 1 ? t('app.comma_payouts', total) : '')
        + (untaken
          // Nobody holds it, so there is nobody to wait for.
          ? t('app.nobody_has_taken_it_so_this_3')
          : t('app.nothing_happens_until')
            + (hitman ? t('app.the_person_who_placed_it') : t('app.the_operative')) + t('app.agrees'))
        // More time and more money are the client's to give, at once, and
        // a hitman looking here for them found only ways to make it worse.
        + (hitman && settings().relay !== false
          ? t('app.for_more_time_or_money_message')
          : ''),
      // An option the server would refuse whatever the player enters is not
      // an option; it is a button that wastes their time and reads as a
      // fault. Dropped rather than drawn.
      options: options.filter(function (option) { return !option.skip; })
    };
    render();
  }

  function sendProposal(contract, kind, payload) {
    post('propose', { id: contract.id, kind: kind, payload: payload }).then(function (r) {
      if (!r.ok) {
        /* limit_reached here is how many changes may wait on THIS contract
           at once, and the shared words for it are about how many contracts
           the player holds — so a creator proposing a second change was
           told they were holding too many contracts. */
        var reasons = {
          limit_reached: t('app.there_is_already_a_change_waiting')
            + t('app.it_has_to_be_answered_or')
            + 'another.',
          invalid_input: t('app.that_change_no_longer_fits_this_2')
            + t('app.has_moved_on_since_you_opened'),
          bad_state: t('app.this_contract_cannot_be_changed_right'),
          feature_off: t('app.proposing_changes_is_turned_off_by')
        };
        // A new reason is refused for its words — too long, too many
        // digits, a banned pattern — not because the contract moved on.
        if (kind === 'change_reason') {
          reasons.invalid_input = t('app.this_server_will_not_take_that')
            + t('app.word_it_differently');
        }
        if (reasons[r.err]) {
          if (r.err === 'invalid_input') { refresh(); }
          return say(reasons[r.err]);
        }
        return fail(r);
      }
      /* Nobody else holds it, so nobody else has to agree: the server
         applies a proposal on the last answer it needs, and on an untaken
         contract that is the creator's own. It used to stop here and say
         "The other party has to agree" about a party that did not exist,
         leaving the proposal to lapse under "Waiting to be applied." — and
         a collection given back this way is the one route the page has for
         it, since the reward editor will not empty a collection. */
      /* The server applies it in the same request when nobody else has to
         agree. The page used to answer its own proposal with a second
         request, from the same rate-limit bucket: refused, it left a
         proposal the card never drew and that blocked the next one. */
      forgetProposals();
      if (r.data && r.data.outcome === 'applied') {
        say(t('app.done_the_change_is_in_effect'), 'ok');
        return refresh();
      }
      if (r.data && r.data.outcome === 'failed') {
        say(ERRORS[r.data.err] || t('app.that_change_no_longer_fits_this'));
        return refresh();
      }
      say(t('app.proposed_the_other_party_has_to'), 'ok');
      refresh();
    });
  }

  function improveContract(contract) {
    /* Says what the deadline currently is.
    
       It asked "by how many minutes?" against a blank box, with no statement
       of where the deadline stands, no ceiling, and no sense of scale. A
       creator deciding how much to add has to know what they are adding to —
       and the one thing the app already knows and was not saying is how long
       is left. */
    var band = bandOf(contract);
    var standing = band === null
      ? t('app.this_contract_has_no_deadline_set')
      : t('app.it_currently_has') + band.text.toLowerCase() + '.';

    /* It opened on an empty box, with no ceiling and no hint — so Confirm,
       the obvious first tap, did nothing and said nothing. It now opens on
       a sensible figure, is held to what the server will take, and says
       what the deadline would become. */
    var ceiling = Number(settings().deadlineMaxMinutes) || 0;
    askNumber(t('app.extend_the_deadline_by_how_many'),
              standing + t('app.this_applies_at_once_it_can')
              + t('app.whoever_is_working_it'),
              function (minutes) {
                post('improve', {
                  id: contract.id,
                  kind: 'extend_deadline',
                  payload: { seconds: minutes * 60 }
                }).then(function (r) {
                  if (!r.ok) return fail(r);
                  say(t('app.deadline_extended'), 'ok');
                  refresh();
                });
              },
              {
                label: t('app.extra_minutes'),
                value: ceiling > 0 ? Math.min(30, ceiling) : 30,
                min: 1,
                max: ceiling > 0 ? ceiling : undefined,
                confirm: t('app.extend'),
                hint: function (value) {
                  if (!value || value < 1 || (ceiling > 0 && value > ceiling)) {
                    return ceiling > 0 ? t('app.between_1_and_minutes', ceiling)
                                       : t('app.at_least_1_minute');
                  }
                  return t('app.it_would_then_have') + durationText(value)
                    + t('app.more_or_run_to_the_contract');
                }
              });
  }

  /* ---------- changing what a contract pays ----------------------------

     Adding to a reward and taking from it are one decision, so they are one
     screen. "Add to pot" on its own could only ever go up, and a creator who
     had put up too much had exactly one way down: withdraw the whole
     contract and place it again, which costs them their place in every
     cooldown that keys on target and creator.

     What can be taken back is decided by the server and re-decided when the
     request arrives. The page draws what it was told and nothing else — an
     id it was not given is an id it cannot name. */

  function editReward(contract) {
    state.reward = { contract: contract, data: null, pending: true,
                     failed: null, chosen: {} };
    state.dialog = { kind: 'reward' };
    render();

    post('rewardBreakdown', { id: contract.id }).then(function (r) {
      // A second dialog may have been opened while this was in flight.
      if (!state.reward || state.reward.contract.id !== contract.id) { return; }
      state.reward.pending = false;
      if (r.ok && r.data) {
        state.reward.data = r.data;
      } else {
        state.reward.failed = (r.err === 'rate_limited')
          ? t('app.asked_too_fast_try_again') + retryIn(r.data && r.data.retryAfter) + '.'
          : t('app.could_not_read_what_this_contract');
      }
      redraw();
    });
  }

  /* One escrow line, as a line of text a player can read. */
  /* On a contract that pays more than once, which collection the line pays
     out of. The breakdown carried the slot and this never read it, so three
     collections each funded with the same cash drew three identical rows and
     a creator wanting the last one's money back could not tell which to
     tick. */
  function rewardLineLabel(line, slots) {
    var what;
    if (line.source === 'cash' || line.source === 'bank' || line.source === 'dirty') {
      what = SOURCE_LABELS[line.source] + ' ' + money(line.amount || 0);
    } else if (line.source === 'weapon') {
      what = itemLabel(line.item);
    } else {
      what = itemLabel(line.item) + ' ×' + (line.quantity || 1);
    }
    // Named the way the Place form names it, so "bonus" is not left to
    // mean whichever bonus the reader guesses.
    var text = what + ' — ' + (line.portion === 'bonus' ? t('app.kidnapping_bonus') : t('app.base_word'));
    if ((Number(slots) || 1) > 1) {
      text = t('app.payout_n_text', Number(line.slot) || 1, text);
    }
    return text;
  }

  function renderRewardEditor(view) {
    var edit = state.reward;
    var panel = el('div', 'card dialog');
    panel.appendChild(el('div', 'target', t('app.change_the_reward')));

    if (!edit) { closeDialog(); return; }

    var total = el('div', 'hint');
    // Drawn further down; showTotal wakes it once something is ticked.
    var take = null;

    /* Rewritten in place rather than by redrawing the dialog: a redraw
       rebuilds every checkbox, and rebuilding a checkbox the player is
       still tapping through is how a tick lands on the wrong row. */
    function showTotal() {
      // Not named `money`: that is the formatter this function calls two
      // lines below, and shadowing it turned the whole dialog into a
      // TypeError the moment anything was ticked.
      // Dirty money counted apart from clean. Adding them into one figure
      // says a creator is getting back "$7,000" when three of it is dirty
      // money, which does not spend the same.
      var amount = 0, dirty = 0, goods = 0;
      asList(edit.data && edit.data.lines).forEach(function (line) {
        if (!line.id || edit.chosen[line.id] !== true) { return; }
        if (line.source === 'cash' || line.source === 'bank') {
          amount += line.amount || 0;
        } else if (line.source === 'dirty') {
          dirty += line.amount || 0;
        } else {
          goods += (line.source === 'weapon') ? 1 : (line.quantity || 1);
        }
      });

      // The crimson button is the one the screen is for, and with nothing
      // ticked that is adding, not taking back: raising the reward on a
      // contract nobody will take is the usual reason to be here, and it
      // sat beside a loud "Take back what I ticked" that did nothing.
      if (edit.armed) { disarmTake(); }
      if (take) {
        var any = !!(amount || dirty || goods);
        take.className = 'btn ' + (any ? 'primary' : 'ghost') + ' take-back';
        take.disabled = !any;
      }

      if (!amount && !dirty && !goods) {
        total.textContent = t('app.nothing_ticked_yet');
        return;
      }

      var parts = [];
      if (amount) { parts.push(money(amount)); }
      if (dirty) { parts.push(money(dirty) + t('app.dirty_money_2')); }
      if (goods) { parts.push(tn('app.items_count', goods)); }
      total.textContent = t('app.coming_back_to_you') + parts.join(t('app.and_sep')) + '.';
      edit.totalText = parts.join(t('app.and_sep'));
    }

    /* Take back is a write: its first tap arms it and names what comes
       back, the second sends it. A change to what is ticked disarms it, and
       so does a wait (TIP_CONFIRM_MS). */
    function disarmTake() {
      edit.armed = false;
      if (take) {
        take.textContent = t('app.take_back_what_i_ticked');
        take.classList.toggle('is-armed', false);
      }
    }

    if (edit.pending) {
      panel.appendChild(el('div', 'reason', t('app.reading_what_this_contract_is_holding')));
    } else if (edit.failed) {
      panel.appendChild(el('div', 'reason', edit.failed));
    } else if (edit.data) {
      var lines = asList(edit.data.lines);

      if (edit.data.reason) {
        panel.appendChild(el('div', 'reason', edit.data.reason));
      } else {
        panel.appendChild(el('div', 'reason',
          t('app.add_more_or_tick_anything_you')));
      }

      if (!lines.length) {
        panel.appendChild(el('div', 'hint', t('app.nothing_here_can_be_taken_back')));
      }

      var list = el('div', 'reward-lines');
      lines.forEach(function (line, index) {
        // `toggle` is the existing styled checkbox row: same tap target,
        // same drawn box. A second look for the same control would be a
        // second thing to keep in step.
        var row = el('label', 'toggle reward-line');

        if (line.id) {
          var box = make('input');
          box.type = 'checkbox';
          box.id = 'reward-line-' + index;
          box.checked = edit.chosen[line.id] === true;
          box.onchange = function () {
            // Read back off the node rather than toggling a remembered
            // value: a redraw between the click and here would otherwise
            // flip the wrong way.
            if (box.checked) { edit.chosen[line.id] = true; }
            else { delete edit.chosen[line.id]; }
            showTotal();
          };
          row.appendChild(box);
        }

        row.appendChild(el('span', line.id ? null : 'hint',
          rewardLineLabel(line, edit.data.slots)));
        list.appendChild(row);
      });
      panel.appendChild(list);

      // What is actually coming back, before they commit to it. Ticking
      // five lines and reading five separate figures off a phone screen is
      // arithmetic nobody should have to do to get their own money back.
      panel.appendChild(total);
      showTotal();
    }

    var row = el('div', 'row editor-actions');

    // Only where there is something it could take back. On a held
    // contract the server sends the lines without ids and marks them not
    // editable; the button was drawn anyway and only ever said "Nothing
    // ticked".
    var takeable = !!(edit.data && edit.data.editable !== false
      && asList(edit.data.lines).some(function (l) { return l && l.id; }));

    // Adding is offered from the same screen whether or not taking back is
    // allowed: a contract somebody is working can still be sweetened, and
    // that is exactly when a creator wants to. First in the row, and "Add
    // to it" rather than "Add money": the next step offers bank and dirty
    // money, goods and the kidnapping bonus too.
    var add = el('button', 'ghost ico i-plus', t('app.add_to_it'));
    add.onclick = function () {
      var contract = edit.contract;
      state.dialog = null; state.reward = null;
      // Closed on screen as well as in state. The wallet is read first, and
      // a refusal, or nothing this server takes, is only said: the editor
      // stayed drawn with no dialog behind it, its buttons still live.
      render();
      addEscrow(contract);
    };
    row.appendChild(add);

    // Lowering the stake applies at once, like adding: it can only help
    // whoever takes it. The server has done it since the first commit and
    // nothing here asked for it.
    if (Number(edit.contract.penaltyAmount) > 0) {
      var lower = el('button', 'ghost', t('app.lower_the_stake'));
      lower.onclick = function () {
        var contract = edit.contract;
        state.dialog = null; state.reward = null;
        lowerStake(contract);
      };
      row.appendChild(lower);
    }

    if (edit.data && !edit.pending && takeable) {
      take = el('button', 'primary take-back', t('app.take_back_what_i_ticked'));
      edit.armed = false;
      take.onclick = function () {
        // Nothing ticked sends nothing: withdrawChosen only says so.
        if (!Object.keys(edit.chosen).length || edit.sending) { return withdrawChosen(edit); }
        if (!edit.armed) {
          edit.armed = true;
          take.textContent = t('app.tap_again_to_take_back', edit.totalText || '');
          take.classList.toggle('is-armed', true);
          var armedButton = take;
          setTimeout(function () { if (edit.armed && take === armedButton) { disarmTake(); } }, TIP_CONFIRM_MS);
          return;
        }
        disarmTake();
        withdrawChosen(edit);
      };
      row.appendChild(take);
      showTotal();
    }

    var close = el('button', 'ghost', t('app.done_2'));
    close.onclick = function () { state.reward = null; closeDialog(); };
    row.appendChild(close);

    panel.appendChild(row);
    view.appendChild(panel);
  }

  function withdrawChosen(edit) {
    var ids = Object.keys(edit.chosen);
    if (!ids.length) {
      say(t('app.nothing_ticked_so_nothing_was_taken'));
      return;
    }

    // Guarded here as well as on the server: a double tap while the first
    // request is in flight would ask for the same lines twice, and the
    // second answer is a refusal the creator has done nothing to deserve.
    if (edit.sending) { return; }
    edit.sending = true;

    post('withdrawReward', { id: edit.contract.id, lines: ids }).then(function (r) {
      edit.sending = false;
      if (!r.ok) {
        /* The amounts add up perfectly; the rule is about what has to be LEFT
           on the contract. Taking all of it back is a real thing to want, and
           it has a button of its own two taps away.

           The shared table words invalid_reward for the Place form — "That
           reward does not add up" — so a creator who ticked every line was
           sent back to re-read figures that were never the problem, about a
           rule nobody had told them, with no hint that Withdraw does what
           they were trying to do. */
        if (r.err === 'invalid_reward') {
          return say(t('app.a_payout_has_to_keep_something')
            + t('app.whole_reward_back_use_withdraw_that')
            + t('app.and_returns_everything'));
        }
        return takenOr(r);
      }

      var queued = (r.data && r.data.queued) || 0;
      var checking = staffChecking(r.data);
      say(queued
        ? t('app.taken_off_the_contract_some_of')
          + t('app.for_you_it_arrives_when_you') + checking
        : checking ? t('app.taken_off_the_contract') + checking
          : t('app.taken_off_the_contract_and_returned'), 'ok');

      state.reward = null;
      state.dialog = null;
      refresh();
    });
  }

  /* Put more up on a contract that is already out there.
     
     This only ever offered cash. A creator whose money is in the bank, or
     who deals in black money, had no way to sweeten a contract at all —
     the server has taken all three since the first commit. */
  function addEscrow(contract, fresh) {
    var wallet = fresh;
    if (!wallet) {
      // Read now, every time. This used whatever wallet the Place form had
      // read, however long ago, and told the creator "You hold $50,000"
      // and offered up to it when they held a fraction of that.
      var navAt = navSeq;
      return post('rewardOptions', {}).then(function (r) {
        // The amount box opens over wherever the player is now.
        if (navSeq !== navAt || state.dialog) { return; }
        if (!r.ok || !r.data) { return fail(r); }
        state.wallet = r.data;
        addEscrow(contract, r.data);
      });
    }

    var caps = wallet.caps || {};
    var usable = ['cash', 'bank', 'dirty'].filter(function (source) {
      return caps[source + t('app.enabled')] !== false && (Number(wallet[source]) || 0) > 0;
    });

    /* Goods, and the kidnapping bonus, beside money. The server has taken
       items and weapons onto a contract already out there, and raised the
       bonus on one, since the first commit; this offered money alone, so
       the only way to put a rifle on a live contract was to withdraw it
       and place it again. */
    var items = (caps.itemsEnabled === false) ? [] : asList(wallet.items);
    var weapons = (caps.weaponsEnabled === false) ? [] : asList(wallet.weapons);
    var bonusNow = Number(contract.bonusPercent) || 0;
    var bonusCap = Number(caps.bonusPercent) || 0;
    var base = Number((contract.reward || {}).baseline) || 0;
    // The bonus is a share of the money base, so with none there is nothing
    // to take a share of, and the server refuses.
    //
    // Nor on a contract that pays only for a live delivery: it pays all of
    // its reward for that, so there is no bonus to raise, and the server
    // refuses one (no_bonus). Adding to the reward is the way to offer more.
    var bonusRoom = bonusCap > bonusNow && base > 0 && !aliveOnly(contract);

    if (!usable.length && !items.length && !weapons.length && !bonusRoom) {
      return say(t('app.you_have_nothing_this_server_takes'));
    }

    // Every top-up lands the same way, whatever it is made of.
    function send(reward, tooMuch) {
      post('addEscrow', { id: contract.id, reward: reward }).then(function (r) {
        if (!r.ok && r.err === 'invalid_reward') { return say(tooMuch); }
        if (!r.ok) return fail(r);
        say(t('app.added_to_the_reward'), 'ok');
        state.wallet = null;
        refresh();
      });
    }

    function addItem() {
      askFields(t('app.add_an_item_to_the_reward'),
        t('app.taken_from_you_now_and_held'),
        [
          { id: 'item', label: t('app.item'), type: 'select', value: items[0].name,
            options: items.map(function (item) {
              return { value: item.name, label: t('app.item_held', item.label, item.count) };
            }) },
          { id: 'count', label: t('app.how_many'), type: 'number', value: 1, min: 1 }
        ],
        function (values) {
          var held = 0;
          items.forEach(function (item) { if (item.name === values.item) { held = item.count; } });
          if (!values.count || values.count < 1 || values.count > held) {
            return say(t('app.you_hold') + held + t('app.of_those'));
          }
          send({ baseline: { items: [{ name: values.item, count: values.count }] } },
            t('app.this_contract_cannot_carry_that_it'));
        }, t('app.add'));
    }

    function addWeapon() {
      askFields(t('app.add_a_weapon_to_the_reward'),
        t('app.taken_from_you_now_and_held_2')
          + t('app.serial_and_all'),
        [{ id: 'weapon', label: t('app.weapon'), type: 'select', value: String(weapons[0].slot),
           options: weapons.map(function (weapon) {
             return { value: String(weapon.slot),
                      label: weapon.label + (weapon.serial ? '  #' + weapon.serial : '') };
           }) }],
        function (values) {
          var found = null;
          weapons.forEach(function (weapon) {
            if (String(weapon.slot) === String(values.weapon)) { found = weapon; }
          });
          if (!found) { return say(t('app.that_weapon_is_no_longer_in')); }
          send({ baseline: { weapons: [{ name: found.name, slot: found.slot }] } },
            t('app.this_contract_cannot_carry_that_it'));
        }, t('app.add'));
    }

    function raiseBonus() {
      var later = Math.max(0, (Number(contract.slots) || 1) - (Number(contract.currentSlot) || 1));
      askNumber(t('app.raise_the_kidnapping_bonus'),
        t('app.paid_on_top_for_delivering_them')
          + t('app.and_applies_at_once'),
        function (percent) {
          post('improve', { id: contract.id, kind: 'raise_bonus',
                            payload: { percent: percent } }).then(function (r) {
            if (!r.ok && r.err === 'invalid_reward') {
              return say(t('app.that_bonus_would_take_this_contract')
                + t('app.allows_or_there_is_no_money'));
            }
            if (!r.ok) return fail(r);
            say(t('app.kidnapping_bonus_raised_to') + percent + '%.', 'ok');
            state.wallet = null;
            refresh();
          });
        },
        {
          label: t('app.bonus_2'),
          value: Math.min(bonusCap, bonusNow + 10), min: bonusNow + 1, max: bonusCap,
          confirm: t('app.raise'),
          hint: function (value) {
            if (!value || value <= bonusNow || value > bonusCap) {
              return t('app.now_percent_between', bonusNow, bonusNow + 1, bonusCap);
            }
            return t('app.now_percent_about_more_from_you', bonusNow, money(Math.floor(base * (value - bonusNow) / 100)))
              + (later > 0 ? t('app.and_the_same_share_of_each') : '.');
          }
        });
    }

    function amountFrom(source) {
      var held = Number(wallet[source]) || 0;
      var ceiling = Math.min(held, Number(caps[source]) || held);
      // And the room left under the most one contract may be worth.
      var maxValue = Number(caps.maxValue) || 0;
      if (maxValue > 0 && contract.valueHeld !== undefined) {
        ceiling = Math.min(ceiling, Math.max(0, maxValue - (Number(contract.valueHeld) || 0)));
      }
      if (ceiling < 1) {
        return say(t('app.this_contract_is_already_worth_as'));
      }
      askNumber(t('app.add_source_to_the_reward', (SOURCE_LABELS[source] || source).toLowerCase()),
        t('app.it_is_taken_from_you_now'),
        function (value) {
          var reward = { baseline: {} };
          reward.baseline[source] = value;
          send(reward, t('app.that_would_take_this_contract_past')
            + t('app.may_be_worth_on_this_server'));
        },
        {
          label: t('app.how_much'),
          value: Math.min(1000, ceiling), min: 1, max: ceiling,
          confirm: t('app.add'),
          hint: function (value) {
            if (!value || value < 1 || value > ceiling) {
              return t('app.between_x_and_y', money(1), money(ceiling));
            }
            return t('app.you_hold') + money(held) + '; '
              + money(held - value) + t('app.would_be_left');
          }
        });
    }

    var options = usable.map(function (source) {
      return {
        label: SOURCE_LABELS[source] || source,
        note: t('app.you_hold') + money(wallet[source]) + '.',
        run: function () { amountFrom(source); }
      };
    });
    if (items.length) {
      options.push({ label: t('app.items'), note: t('app.something_from_your_pockets'), run: addItem });
    }
    if (weapons.length) {
      options.push({ label: t('app.weapons'), note: tn('app.you_carry_weapons', weapons.length),
        run: addWeapon });
    }
    if (bonusRoom) {
      options.push({ label: t('app.kidnapping_bonus_2'), note: t('app.now_percent_paid_on_top', bonusNow), run: raiseBonus });
    }

    // One thing to add, straight to it. More than one, ask which first.
    if (options.length === 1) { return options[0].run(); }

    state.dialog = {
      kind: 'choice',
      question: t('app.add_to_the_reward'),
      detail: t('app.taken_from_you_now_and_held'),
      options: options
    };
    render();
  }

  /* Lower the stake a hitman puts up, or take it off. Applies at once:
     it can only help whoever is on it, and anyone who already staked the
     old figure gets the difference back. */
  function lowerStake(contract) {
    var now = Number(contract.penaltyAmount) || 0;
    var detail = t('app.now_this_applies_at_once', money(now))
      + (Number(contract.hitmenActive) > 0
        ? t('app.and_anyone_already_staked_gets_the') : '.');

    function send(amount) {
      post('improve', { id: contract.id, kind: 'lower_penalty',
                        payload: { amount: amount } }).then(function (r) {
        if (!r.ok) return fail(r);
        say(amount > 0 ? t('app.stake_lowered_to') + money(amount) + '.' : t('app.stake_removed'), 'ok');
        refresh();
      });
    }

    state.dialog = {
      kind: 'choice',
      question: t('app.lower_the_stake'),
      detail: detail,
      options: [
        {
          label: t('app.lower_it'), note: t('app.to_a_smaller_figure'), skip: now <= 1,
          run: function () {
            askNumber(t('app.lower_the_stake'), detail, send, {
              label: t('app.new_stake'), value: Math.max(1, Math.floor(now / 2)),
              min: 1, max: now - 1, confirm: t('app.lower'),
              hint: function (value) {
                if (!value || value < 1 || value >= now) {
                  return t('app.between_x_and_y', money(1), money(now - 1));
                }
                return t('app.a_hitman_would_stake') + money(value) + t('app.to_take_it');
              }
            });
          }
        },
        { label: t('app.remove_it'), note: t('app.nobody_has_to_put_anything_up_2'),
          run: function () { send(0); } }
      ].filter(function (option) { return !option.skip; })
    };
    render();
  }

  /* Whether `open` is the conversation with this operative on this contract.

     A contract is not a conversation: a creator on a competitive contract
     has one thread per operative. Matching on the contract alone is how a
     message half-typed to one operative was waiting, pre-filled, in the
     next operative's box — and went to them on Send. */
  /* Which conversation this is: the contract, and the operative by alias.
     Not by handle, which the server can issue afresh for the same thread —
     a draft filed under the old one could never be found again. An alias
     is unique on its contract and kept by an operative who comes back. */
  function threadKey(contract, thread) {
    return (contract && contract.id) + '|'
      + ((thread && (thread.alias || thread.handle)) || '');
  }

  function sameThread(open, contract, thread) {
    return !!(open && open.contract)
      && threadKey(open.contract, open.thread) === threadKey(contract, thread);
  }

  /* When this phone last read each thread, by threadKey: the server's time
     of the newest message from the other side it showed. The only sign of
     a new message was the phone's notice, which a muted thread, a full
     budget or being away never sent, so a client told "use Message to agree
     where to meet" had nothing to say a message had come. Kept on this
     phone only, a convenience for this viewer: nothing about it goes to the
     server, and every read and write of storage is guarded, since it can
     be missing or refused. Without it, the dots last as long as the page. */
  var READ_KEY = 'crimson-hitman:threads-read';
  var READ_KEPT = 200;
  var readTimes = null;

  function threadsRead() {
    if (readTimes) { return readTimes; }
    readTimes = {};
    try {
      var raw = window.localStorage && window.localStorage.getItem(READ_KEY);
      var parsed = raw ? JSON.parse(raw) : null;
      if (parsed && typeof parsed === 'object') { readTimes = parsed; }
    } catch (err) { /* read nothing: every thread with a message shows a dot */ }
    return readTimes;
  }

  function markRead(key, at) {
    var newest = Number(at) || 0;
    var times = threadsRead();
    if (!(newest > 0) || (Number(times[key]) || 0) >= newest) { return; }
    times[key] = newest;
    // The oldest go first once there are more than are worth keeping.
    var keys = Object.keys(times);
    if (keys.length > READ_KEPT) {
      keys.sort(function (a, b) { return (Number(times[a]) || 0) - (Number(times[b]) || 0); });
      keys.slice(0, keys.length - READ_KEPT).forEach(function (k) { delete times[k]; });
    }
    try {
      if (window.localStorage) { window.localStorage.setItem(READ_KEY, JSON.stringify(times)); }
    } catch (err) { /* kept for this page only */ }
  }

  /* Whether a thread has a message from the other side newer than this
     phone last read of it. */
  function unreadIn(key, lastMessageAt) {
    var at = Number(lastMessageAt) || 0;
    return at > 0 && at > (Number(threadsRead()[key]) || 0);
  }

  /* What a thread that can no longer be read means, in words. The shared
     table says "That is not yours." for not_participant, which is what the
     creator of a contract that has just closed was told on every push,
     sitting in front of a conversation they had been part of a moment ago. */
  var THREAD_GONE = {
    already_settled: t('app.that_contract_has_closed_and_its')
      + t('app.with_it'),
    not_participant: t('app.that_conversation_is_no_longer_open')
      + t('app.has_ended_or_the_operative_is')
      + t('app.still_running_open_it_again_from')
  };

  /* Leave a thread the server will not serve any more, rather than sitting
     in front of it with a compose box every Send of which is refused. */
  function leaveDeadThread(r, contract, thread) {
    if (!THREAD_GONE[r.err]) { return false; }
    if (state.tab === 'thread' && sameThread(state.thread, contract, thread)) {
      state.thread = null;
      state.tab = 'mine';
      render();
      refresh();
    }
    say(THREAD_GONE[r.err]);
    return true;
  }

  // Threads are addressed by an opaque server-issued handle, never by a
  // citizen id — the creator is not told who the operative is.
  /* Counts every move the player makes between screens. A reply that
     arrives after the count has moved was asked for from somewhere the
     player has since left, and does not get to take them back there. */
  var navSeq = 0;
  function navigated() { navSeq += 1; }

  /* opts.reread: a re-read of the thread already open (after a send, on a
     push), applied only while the player is still in it. Otherwise it is
     the player opening it, applied only if they have not gone anywhere
     else meanwhile.

     A late reply used to switch the view whatever the player had done in
     the meantime: they tapped Message, moved to Place while it said
     "Opening…", and were pulled into the thread; they pressed Back while a
     push was re-reading it, and were put straight back in. */
  function openThread(contract, thread, opts) {
    var reread = !!(opts && opts.reread);
    var navAt = navSeq;

    function stale() {
      if (reread) {
        return state.tab !== 'thread' || !sameThread(state.thread, contract, thread);
      }
      return navSeq !== navAt || !!state.dialog;
    }

    return post('readThread', { id: contract.id, thread: thread ? thread.handle : null })
      .then(function (r) {
        if (!r.ok) {
          if (leaveDeadThread(r, contract, thread)) { return; }
          if (stale()) { return; }
          return fail(r);
        }
        if (stale()) { return; }
        // Whatever is half-typed survives re-reading the thread, read now
        // rather than when the request went out: the player can have typed
        // more while it was in flight. The same thread only, so a draft
        // never follows the player into a conversation with somebody else.
        var keep = state.drafts[threadKey(contract, thread)] || '';
        // { messages, muted }: the reader's own mute rides with the read, so
        // the Mute button is right for a hitman too, who opens their thread
        // with no entry to carry it. A bare list is the messages alone.
        var data = r.data || [];
        var list = Array.isArray(data) ? data : asList(data.messages);
        // Read, up to the newest message from the other side shown here.
        var newest = 0;
        list.forEach(function (m) {
          if (m && !m.mine && Number(m.at) > newest) { newest = Number(m.at); }
        });
        markRead(threadKey(contract, thread), newest);
        // The keyboard stays up through the redraw: render() sees to it.
        state.thread = { contract: contract, thread: thread,
                         messages: list, draft: keep,
                         muted: !Array.isArray(data) && data.muted === true };
        state.tab = 'thread';

        /* Opened on the latest message, with the compose box under it. The
           thread is drawn oldest first and nothing ever moved the scroll,
           so thirty messages in, the player landed on the first one with
           the newest and the Send box four screens below. A re-read follows
           the conversation down only if the player was already at the
           bottom of it: one scrolled up to read something older is left
           there. The view is measured before the redraw, which keeps the
           position the player had. */
        var view = document.getElementById('view');
        var atBottom = !view || !reread
          || (view.scrollHeight - view.scrollTop - view.clientHeight < 80);
        render();
        if (view && atBottom && state.tab === 'thread' && !state.dialog) {
          view.scrollTop = view.scrollHeight;
        }
      });
  }

  /* A creator picks which operative to talk to; a hitman has only one
     thread.

     The picking is the part that was missing. A competitive contract has a
     thread per operative and the server hands back a handle for each, and
     this opened the first and dropped the rest — so on a contract with three
     operatives, two of them could write to the client and the client had no
     way into either thread. Nothing said so: the first one opened normally,
     and the other messages simply went unanswered. */
  function openThreads(contract) {
    var navAt = navSeq;
    return post('threads', { id: contract.id }).then(function (r) {
      // The picker opens where the player is now, so only if that is still
      // where they asked from.
      if (navSeq !== navAt || state.dialog) { return; }
      if (!r.ok) return fail(r);
      var threads = asList(r.data);
      if (!threads.length) return say(t('app.no_operative_to_talk_to_yet'));
      if (threads.length === 1) { return openThread(contract, threads[0]); }

      state.dialog = {
        kind: 'choice',
        question: t('app.which_operative'),
        detail: threads.length + t('app.operatives_are_on_this_contract_each')
          + t('app.a_thread_of_their_own_and'),
        options: threads.map(function (thread) {
          var fresh = unreadIn(threadKey(contract, thread), thread.lastMessageAt);
          return {
            label: thread.alias || t('app.operative'),
            note: [thread.name, fresh ? t('app.new_message') : null].filter(Boolean).join(' \u00b7 ')
              || null,
            run: function () { openThread(contract, thread); }
          };
        })
      };
      render();
    });
  }

  /* What the player is told when no call rang, by the server's reason.
     It used to be "they have been asked to call you back" every time, on
     servers where the other side had no way to do that either. */
  var CALL_NOT_PLACED = {
    callback: t('app.they_have_been_asked_to_call'),
    both_anonymous: t('app.both_of_you_are_anonymous_so')
      + t('app.contract_use_messages'),
    no_calls: t('app.they_have_been_told_you_want')
      + t('app.place_calls_so_use_messages'),
    not_placed: t('app.the_call_could_not_be_placed')
      + t('app.want_to_talk_use_messages'),
    unreachable: t('app.they_could_not_be_reached_use')
  };

  function requestCall() {
    var tv = state.thread;
    if (!tv) { return; }

    return post('requestCall', {
      id: tv.contract.id,
      thread: tv.thread ? tv.thread.handle : null
    }).then(function (r) {
      if (!r.ok) {
        // On a call already: Hang up is what this thread offers now.
        if (r.err === 'already_in_call') {
          state.call = threadKey(tv.contract, tv.thread);
          redraw();
        }
        return fail(r);
      }
      // Say which actually happened. Telling the player a call is
      // connecting when none is would be worse than any of the others.
      if (r.data && r.data.placed) {
        state.call = threadKey(tv.contract, tv.thread);
        // Redrawn only where the player still is, so Hang up appears
        // without a late reply rebuilding some other page under them.
        if (state.tab === 'thread' && sameThread(state.thread, tv.contract, tv.thread)) {
          render();
        }
        return say(t('app.calling_hang_up_here_when_you'), 'ok');
      }
      var line = CALL_NOT_PLACED[r.data && r.data.reason];
      say(typeof line === 'string' ? line : CALL_NOT_PLACED.not_placed, 'ok');
    });
  }

  /* Mute or unmute the open thread, for this player only (§11.4): their
     phone stops ringing for its messages, which still arrive and still
     show here. Nothing about it reaches the other side. */
  function toggleMute() {
    var tv = state.thread;
    if (!tv) { return; }

    return post('muteThread', {
      id: tv.contract.id,
      thread: tv.thread ? tv.thread.handle : null,
      muted: !tv.muted
    }).then(function (r) {
      if (!r.ok) {
        if (leaveDeadThread(r, tv.contract, tv.thread)) { return; }
        return fail(r);
      }
      var muted = !!(r.data && r.data.muted === true);
      // Onto the thread as it stands now — a push can have re-read it
      // meanwhile — and redrawn only where the player still is.
      if (sameThread(state.thread, tv.contract, tv.thread)) {
        state.thread.muted = muted;
        if (state.tab === 'thread') { render(); }
      }
      say(muted
        ? t('app.muted_new_messages_will_not_ring')
        : t('app.unmuted_new_messages_will_ring_your'), 'ok');
    });
  }

  /* The Hang up drawn above every screen but the thread while a call placed
     from here is live (draw). */
  function callBar() {
    var bar = el('div', 'row call-bar');
    bar.appendChild(el('div', 'hint', t('app.you_are_on_a_call_placed')));
    var hang = el('button', 'ghost ico i-xcircle', t('app.hang_up'));
    hang.id = 'call-hangup';
    hang.onclick = function () { endCall(); };
    bar.appendChild(hang);
    return bar;
  }

  function endCall() {
    post('endCall', {}).then(function (r) {
      if (!r.ok) { return fail(r); }
      state.call = null;
      // Whatever is open: Hang up is drawn on every screen while a call is.
      redraw();
      // Over already — the other side hung up or never answered — is said
      // as it is, rather than claiming this ended it.
      say(r.data && r.data.ended ? t('app.call_ended') : t('app.the_call_had_already_ended'), 'ok');
    });
  }

  function sendMessage(body) {
    if (!body) { return; }
    var tv = state.thread;
    return post('sendMessage', {
      id: tv.contract.id,
      thread: tv.thread ? tv.thread.handle : null,
      body: body
    }).then(function (r) {
      // Cleared on success and not before. It used to be emptied the
      // instant Enter was pressed, so a message the server refused — too
      // long, too fast, a thread that had closed — took the player's words
      // with it and left them retyping something they could not see.
      if (!r.ok) {
        if (leaveDeadThread(r, tv.contract, tv.thread)) { return; }
        return fail(r);
      }
      tv.draft = '';
      // Only if it is still what was sent: the player may have started the
      // next message while this one was in flight.
      var key = threadKey(tv.contract, tv.thread);
      if (state.drafts[key] === body) { delete state.drafts[key]; }
      // A push can have re-read the thread while this was in flight, which
      // replaces state.thread with a copy still holding what was just sent.
      if (sameThread(state.thread, tv.contract, tv.thread)
          && state.thread.draft === body) {
        state.thread.draft = '';
      }
      // Only if the player is still in this conversation. Reopening it
      // regardless pulled them out of whichever thread they had moved to.
      if (state.tab !== 'thread' || !sameThread(state.thread, tv.contract, tv.thread)) {
        return;
      }
      return openThread(tv.contract, tv.thread, { reread: true });
    });
  }

  /* ---------- views ---------- */

  /* The card that goes where the missing thing should be. Returns true when
     it drew one, so the caller stops rather than also claiming the section
     is empty. */
  function drewFailure(view, section) {
    var why = state.loadFailed[section];
    if (!why) { return false; }
    var failed = el('div', 'card');
    failed.appendChild(el('div', 'hint', why));
    if (!state.loadFinal[section]) {
      var again = el('button', 'ghost ico i-refresh', t('app.try_again'));
      again.onclick = function () { delete state.loadFailed[section]; refresh(); render(); };
      failed.appendChild(again);
    }
    view.appendChild(failed);
    return true;
  }

  /* A refusal no retry from this page can change: the server's boot
     recovery failed, and it answers nothing until staff restart it; or the
     app is closed to a job they have, which only quitting it changes. A Try
     again beside either was a button that could never work. */
  function finalRefusal(code) {
    return code === 'recovery_failed' || code === 'blacklisted_job';
  }

  /* Why the app is closed to them, from the refusal: a job they hold but
     are not working is named, with how to get the app back, as their phone
     was told (the server's explainHeld). */
  function barredText(r) {
    var data = r && r.data;
    if (data && data.held && data.job) {
      return t('app.closed_to_you_while_you_hold') + data.job + t('app.job_quit_it_from_your')
        + t('app.job_menu_to_use_it_again');
    }
    return ERRORS.blacklisted_job;
  }

  /* The card that goes where the missing thing should be while the answer
     is still on its way.
   
     A section that has not been answered yet has exactly as little in it as
     a section the server answered with nothing, and the app used to draw
     them the same. On the board that reads as an empty city; on Mine it was
     a blank screen with nothing on it to press; on On me it is an all-clear
     given to a player with a live contract on them. Drawn after the failure
     card and before the empty one, so a refusal still wins. */
  function drewPending(view, section) {
    if (state.loaded[section]) { return false; }
    view.appendChild(el('div', 'empty is-pending', t('app.asking_the_server')));
    return true;
  }

  /* A suspension from contracts (server/sanctions.lua), in the player's own
     words: until when, in their own time, and the reason staff gave. Never
     who set it: the server sends no name. */
  function suspendedText(data) {
    var at = data && Number(data.untilAt);
    var until = t('app.staff_lift_it');
    if (at > 0) {
      var d = new Date(at * 1000);
      var two = function (n) { return (n < 10 ? '0' : '') + n; };
      until = d.getFullYear() + '-' + two(d.getMonth() + 1) + '-' + two(d.getDate())
        + ' ' + two(d.getHours()) + ':' + two(d.getMinutes());
    }
    var reason = data && typeof data.reason === 'string' && data.reason ? data.reason : t('app.no_reason_given');
    return t('app.you_are_suspended_from_contracts_until') + until + ': ' + reason;
  }

  /* ---------- one line of help, and the Board's top ----------

     Every screen says in one line what it is for, under the status bar.
     The Board, where the app opens, also sums up what this player has
     going (contracts taken, placed, on them: each a tap to where they are)
     and searches the contracts on it and the app's own screens. */
  var SCREEN_HELP = {
    board: t('app.open_contracts_you_can_take_accept'),
    mine: t('app.the_contracts_you_took_and_the'),
    place: t('app.put_a_price_on_someone_pick'),
    onme: t('app.contracts_with_you_as_the_target'),
    ledger: t('app.your_record_the_contracts_you_finished'),
    org: t('app.the_hitman_organisation_your_place_in')
  };
  var SCREENS = [['board', t('app.board'), t('app.open_contracts_to_take')], ['mine', t('app.mine'), t('app.contracts_you_took_or_placed_messages')],
    ['place', t('app.place'), t('app.put_a_contract_on_someone_reward')], ['onme', t('app.on_me'), t('app.contracts_on_you_buy_out')],
    ['ledger', t('app.ledger'), t('app.your_record_finished_contracts')], ['org', t('app.org'), t('app.the_organisation_members_money')]];

  /** Opens a tab as its own button does (wireTab), so it reads afresh. */
  function tabNode(name) {
    return Array.prototype.filter.call(document.querySelectorAll('.tab'), function (tv) {
      return tv.dataset && tv.dataset.tab === name;
    })[0] || null;
  }
  function goTab(name) {
    var tab = tabNode(name);
    if (tab && tab.onclick) { tab.onclick(); }
  }

  function screenHelp() {
    return SCREEN_HELP[state.tab] ? el('p', 'hint screen-help', SCREEN_HELP[state.tab]) : null;
  }

  /** What this player has going, from Mine's answer: one tap to each. */
  function homeSummary() {
    var data = state.mine;
    if (!data || data.burnerMissing) { return null; }
    var parts = [['mine', asList(data.accepted).length, t('app.taken_label')],
      ['mine', asList(data.created).length, t('app.placed_label')],
      ['onme', asList(data.onMe).length, t('app.on_you')]];
    var row = el('div', 'row home-summary');
    parts.forEach(function (p) {
      var b = el('button', 'ghost' + (p[0] === 'onme' && p[1] > 0 ? ' danger' : ''), p[1] + ' ' + p[2]);
      b.onclick = function () { goTab(p[0]); };
      row.appendChild(b);
    });
    return row;
  }

  /** The search: the board's cards that match, hidden in place (no redraw,
      so the field keeps the keyboard), and the screens whose words match. */
  function boardSearch() {
    var box = el('div', 'board-search');
    var input = el('input', 'search-field');
    input.type = 'search';
    input.placeholder = t('app.search_contracts_and_screens');
    input.setAttribute('aria-label', t('app.search_contracts_and_screens'));
    input.value = state.find || '';
    var screens = el('div', 'row search-screens');
    function apply() {
      var q = String(input.value || '').trim().toLowerCase();
      state.find = input.value;
      box.cards.forEach(function (node) {
        node.hidden = !!q && String(node.textContent || '').toLowerCase().indexOf(q) === -1;
      });
      screens.innerHTML = '';
      if (q) {
        SCREENS.forEach(function (sc) {
          if (!tabNode(sc[0])) { return; }
          if ((sc[1] + ' ' + sc[2]).toLowerCase().indexOf(q) === -1) { return; }
          var go = el('button', 'ghost ico ico-end i-right', t('app.open_x', sc[1]));
          go.onclick = function () { goTab(sc[0]); };
          screens.appendChild(go);
        });
      }
      screens.hidden = !screens.children.length;
    }
    input.oninput = apply;
    box.appendChild(input);
    box.appendChild(screens);
    box.cards = [];
    box.apply = apply;
    return box;
  }

  function viewBoard(view) {
    // The board's Protection tab, where the server runs bodyguard jobs; and
    // for a guard on a live job after it was switched off (the server says
    // so in settings, and the jobs read last say it too): their job, its
    // pin and Set GPS are on it.
    var guarding = !!(state.protection && state.protection.data
      && asList(state.protection.data.mine).length);
    if (settings().protection === true || guarding) {
      view.appendChild(boardTabs());
      if (state.boardTab === 'protection') { return viewProtection(view); }
    } else { state.boardTab = 'contracts'; }
    if (drewFailure(view, 'board')) { return; }
    if (drewPending(view, 'board')) { return; }
    var data = state.board;
    // Suspended by staff: said by the banner at the top of every tab
    // (holdBanner), with the app pause and the restart hold.
    // No burner phone on a server that needs one (Config.Roleplay.BurnerPhone):
    // the server sent no contracts, and this says why.
    if (data && data.burnerMissing) {
      view.appendChild(el('div', 'empty is-refusal', burnerText(data.burnerItem)));
      return;
    }
    var summary = homeSummary();
    if (summary) { view.appendChild(summary); }
    var search = boardSearch();
    view.appendChild(search);
    // A broker player's tools (Config.Intel.Rumours), above the board.
    if (data && data.rumours && data.rumours.broker) { view.appendChild(brokerPanel()); }
    var contracts = asList(data && data.contracts);
    if (!data || contracts.length === 0) {
      view.appendChild(el('div', 'empty', t('app.no_contracts_on_the_board')));
      search.apply();
      return;
    }
    contracts.forEach(function (c) {
      var node = c && c.rumour ? rumourCard(c, data.rumours || {}) : card(c, 'board');
      search.cards.push(node);
      view.appendChild(node);
    });
    search.apply();

    // The board is sent a page at a time. With no pager, every contract past
    // the first page could never be seen or taken from the phone.
    var page = Number(data.page) || 1;
    var pages = Number(data.pages) || 1;
    if (pages > 1) {
      var nav = el('div', 'row pager');
      var back = el('button', 'ghost ico i-left', t('app.back'));
      back.disabled = page <= 1;
      back.onclick = function () { state.boardPage = page - 1; refresh(); };
      var forward = el('button', 'ghost ico ico-end i-right', t('app.more'));
      forward.disabled = page >= pages;
      forward.onclick = function () { state.boardPage = page + 1; refresh(); };
      nav.appendChild(back);
      nav.appendChild(el('div', 'page-of', t('app.page_of', page, pages)));
      nav.appendChild(forward);
      view.appendChild(nav);
    }
  }

  /* ---------- rumours and the broker (Config.Intel.Rumours) ----------

     A contract this player is not briefed on comes as a rumour: a rough
     area and a reward band, no name, no face, no Accept. Ask the broker
     sends the question from where the player stands; the server checks they
     are beside the broker NPC. A player on a broker job gets a panel to
     brief somebody standing with them. */
  var broker = { people: null, picked: null, asking: false };

  function rumourBand(r) {
    if (r.goods && !(Number(r.high) > 0)) { return t('app.pays_in_goods'); }
    if (!(Number(r.high) > 0)) { return t('app.pay_unknown'); }
    return money(r.low) + ' \u2013 ' + money(r.high) + (r.goods ? t('app.and_goods') : '');
  }

  function rumourCard(contract, rules) {
    var r = contract.rumour || {};
    var node = el('div', 'card is-rumour');
    var head = el('div', 'card-head');
    var who = el('div', 'identity');
    who.appendChild(el('div', 'target', t('app.a_rumour')));
    who.appendChild(el('div', 'reason', t('app.word_is_somebody_wants_a_job')
      + (r.area || t('app.the_city')) + '.'));
    head.appendChild(who);
    node.appendChild(head);
    // On a line of its own: a band is two figures, too wide for the stamp.
    node.appendChild(el('div', 'rumour-band', t('app.pays_about') + rumourBand(r)));
    // The band already says "left" ("Under 1 hour left").
    if (contract.timeLeft) { node.appendChild(el('div', 'hint', contract.timeLeft)); }
    var row = el('div', 'row');
    // A broker briefs; they do not go looking for one.
    if (rules.npc && !rules.broker) {
      var ask = el('button', 'ghost ico i-eye', t('app.ask_the_broker'));
      ask.onclick = function () {
        once('rumour:' + contract.id, function () {
          return post('rumourBrief', { id: contract.id }).then(function (res) {
            if (!res.ok) { say(failText(res)); return; }
            say(t('app.the_broker_filled_you_in_you') + (Number(res.data && res.data.minutes) || 0)
              + t('app.minutes_to_act_on_it'), 'ok');
            refresh();
          });
        });
      };
      row.appendChild(ask);
    }
    if (rules.broker) {
      var brief = el('button', broker.picked ? 'primary ico i-usercheck' : 'ghost ico i-usercheck',
        t('app.brief_them'));
      brief.onclick = function () {
        if (!broker.picked) {
          return say(t('app.pick_who_is_standing_with_you'));
        }
        once('brief:' + contract.id, function () {
          return post('brokerBrief', { id: contract.id, who: broker.picked }).then(function (res) {
            if (!res.ok) { say(failText(res)); return; }
            say(t('app.briefed_they_can_see_this_one'), 'ok');
          });
        });
      };
      row.appendChild(brief);
    }
    if (row.children.length) { node.appendChild(row); }
    node.appendChild(el('div', 'hint', rumourHint(rules)));
    return node;
  }

  /* What a rumour card tells this player to do. A broker briefs: "Find the
     broker" told the broker to look for themselves. Where the NPC is not
     on the map, the district it stands in (the server's, by name only). */
  function rumourHint(rules) {
    if (rules.broker) {
      return t('app.pick_somebody_standing_with_you_above');
    }
    if (rules.npc) {
      if (rules.brokerArea) {
        return t('app.find_the_broker_ask_around') + rules.brokerArea
          + t('app.ask_them_about_it_to_see');
      }
      return rules.blip
        ? t('app.find_the_broker_marked_on_your')
        : t('app.find_the_broker_and_ask_about');
    }
    return t('app.a_broker_can_tell_you_who');
  }

  /* No burner phone, with the item it takes on this server. */
  function burnerText(item) {
    return t('app.you_need_a_burner_phone') + (item ? t('app.item_paren', item) : '') + '.';
  }

  function brokerPanel() {
    var box = el('div', 'notice broker-panel');
    box.appendChild(el('div', 'tip-state ico i-usercheck', t('app.you_are_a_broker_pick_somebody')
      + t('app.standing_with_you_then_brief_them')));
    var people = asList(broker.people);
    if (broker.people && !people.length) {
      box.appendChild(el('div', 'hint', t('app.nobody_is_standing_close_enough')));
    }
    people.forEach(function (p, i) {
      var pick = el('button', broker.picked === p.handle ? 'primary' : 'ghost',
        t('app.person_m_away', i + 1, Number(p.metres) || 0));
      pick.onclick = function () { broker.picked = p.handle; render(); };
      box.appendChild(pick);
    });
    var look = el('button', 'ghost ico i-eye', t('app.who_is_near_me'));
    look.onclick = function () {
      once('brokerNearby', function () {
        return post('brokerNearby', {}).then(function (res) {
          if (!res.ok) { say(failText(res)); return; }
          broker.people = asList(res.data && res.data.people);
          broker.picked = null;
          render();
        });
      });
    };
    box.appendChild(look);
    return box;
  }

  function viewMine(view) {
    if (drewFailure(view, 'mine')) { return; }
    if (drewPending(view, 'mine')) { return; }
    var data = state.mine || {};
    var any = false;

    var accepted = asList(data.accepted);
    var created = asList(data.created);
    // No burner phone (Config.Roleplay.BurnerPhone): On me is still there.
    if (data.burnerMissing) {
      view.appendChild(el('div', 'empty is-refusal', burnerText(data.burnerItem)));
      return;
    }

    // Payouts held for proof of intent, the contract finished or not.
    asList(data.intentHeld).forEach(function (h) {
      any = true;
      view.appendChild(el('div', 'notice gold intent-hold', (h.ref ? t('app.ref_prefix', h.ref) : '')
        + intentHoldText(h, t('app.a_payout_of_yours_is_held'), true)));
    });

    // The one they came here for (just accepted, or tapped on the board)
    // first in its list, and marked: it was somewhere in a list of cards
    // on a tab they had to find for themselves.
    function focusFirst(list) {
      if (!state.focus) { return list; }
      return list.filter(function (c) { return c && c.id === state.focus; })
        .concat(list.filter(function (c) { return !c || c.id !== state.focus; }));
    }
    function mineCard(c) {
      var node = card(c, 'mine');
      if (c && state.focus && c.id === state.focus) { node.classList.toggle('is-focus', true); }
      view.appendChild(node);
    }

    if (accepted.length) {
      any = true;
      view.appendChild(el('h3', 'section', t('app.contracts_you_took')));
      focusFirst(accepted).forEach(mineCard);
    }
    if (created.length) {
      any = true;
      view.appendChild(el('h3', 'section', t('app.contracts_you_placed')));
      focusFirst(created).forEach(mineCard);
    }
    if (!any) view.appendChild(el('div', 'empty', t('app.nothing_active')));
    else view.appendChild(refHint());
  }

  function viewOnMe(view) {
    // Same reply as Mine — a refused read must not read as "nobody is
    // looking for you", which is the most reassuring thing this app can
    // say and the worst thing to say wrongly.
    if (drewFailure(view, 'mine')) { return; }
    if (drewPending(view, 'mine')) { return; }
    // Through asList like every other list in the app. This was the one site
    // that read the value raw, so a roster that crossed keyed by anything
    // but 1..n had no .length here — the all-clear below — and anything else
    // with a length reached .forEach and took the render down after the
    // page had already said there was a price on this player's head.
    var rows = asList(state.mine && state.mine.onMe);
    if (!rows.length) {
      view.appendChild(el('div', 'empty', t('app.nobody_is_looking_for_you_that')));
      return;
    }
    view.appendChild(el('div', 'notice', t('app.there_is_a_price_on_your')));
    rows.forEach(function (c) { view.appendChild(card(c, 'onme')); });
    view.appendChild(refHint());
  }

  /* ---------- the whitelisted-job view ----------

     A player on a job the app bars (police, EMS, DOJ, lawyers and the rest)
     is shown this one screen and nothing else, while the server keeps
     Config.WhitelistedView on: the contracts on them, and, where the law
     enforcement advisory reaches them, the contracts on other
     whitelisted-job members. Each entry is what the server sent and no
     more, which is what the advisory already said: who it is on and their
     job, when it was posted, open or taken, and when it runs out at the
     latest, any of the last three left out where no bulletin said it (when
     it runs out goes with when it was posted, which it would give back). With
     no colleagues' list sent at all, there is no such section. No photo is
     drawn, ever: the monogram stands where a face would be. On a contract on
     them, and only there, the buyout On me offers a civilian target
     (appendBuyout). */
  function viewJobView(view) {
    if (drewFailure(view, 'jobview')) { return; }
    if (drewPending(view, 'jobview')) { return; }
    var data = state.jobView || {};
    var mine = asList(data.onYou);
    var shared = data.colleagues !== undefined && data.colleagues !== null;
    var others = asList(data.colleagues);

    var shows = shared ? t('app.only_shows_contracts_on_you_and')
      : t('app.only_shows_contracts_on_you');
    // Naming the job that puts them here when they hold it rather than
    // work it (a boss can hire anybody), with how to get the whole app back.
    view.appendChild(el('div', 'notice ok', data.heldJob
      ? t('app.you_hold_the') + data.heldJob + t('app.job_a_whitelisted_one_so_this') + shows
        + t('app.quit_it_from_your_job_menu')
      : t('app.you_re_on_a_whitelisted_job') + shows));
    // Its one way to ask again while open: nothing pushes a colleague's
    // contract moving to this screen, since that would date it for every
    // officer. Through the same allowance as every read.
    var again = el('div', 'row actions');
    again.appendChild(actionButton('ghost ico i-refresh', t('app.refresh'), 'jobview:refresh',
      t('app.refreshing'), function () { return readJobView({ keep: true }); }));
    // Notify me, where the server sends whether it is on: it sends that
    // only while it allows it (Config.WhitelistedView.Alerts).
    var alerts = data.alerts && typeof data.alerts === 'object' ? data.alerts : null;
    if (alerts) { again.appendChild(jobViewAlertsButton(alerts.on === true)); }
    view.appendChild(again);
    if (alerts) {
      view.appendChild(el('div', 'hint', alerts.on === true
        ? t('app.notify_me_is_on_your_phone')
          + t('app.you_are_in_the_city')
        : t('app.notify_me_is_off_turn_it')
          + t('app.here_while_you_are_in_the')));
    }
    if (!mine.length && !others.length) {
      view.appendChild(el('div', 'empty', shared
        ? t('app.no_contracts_on_you_or_other') : t('app.no_contracts_on_you')));
      return;
    }
    if (!shared) {
      mine.forEach(function (entry) { view.appendChild(jobViewCard(entry, true)); });
      return;
    }

    view.appendChild(el('h3', 'section', t('app.contracts_on_you')));
    if (mine.length) {
      mine.forEach(function (entry) { view.appendChild(jobViewCard(entry, true)); });
    } else {
      view.appendChild(el('div', 'hint', t('app.none_on_you')));
    }
    view.appendChild(el('h3', 'section', t('app.contracts_on_whitelisted_jobs')));
    if (others.length) {
      others.forEach(function (entry) { view.appendChild(jobViewCard(entry, false)); });
    } else {
      view.appendChild(el('div', 'hint', t('app.none_on_other_whitelisted_job_members')));
    }
  }

  /* Notify me on the view (Config.WhitelistedView.Alerts): a phone notice
     when a new entry appears here, for this character, off until they turn
     it on. Words on the button rather than a box to tick, as Mute on a
     thread: which way it is set is the whole point of it. */
  function jobViewAlertsButton(on) {
    var button = actionButton('ghost ico i-phone', on ? t('app.turn_off_notify_me') : t('app.notify_me'),
      'jobview:alerts', on ? t('app.turning_off') : t('app.turning_on'),
      function () { return setJobViewAlerts(!on); });
    button.id = 'jobview-alerts';
    return button;
  }

  function setJobViewAlerts(on) {
    return post('whitelistedViewAlerts', { on: on }).then(function (r) {
      if (!r.ok) {
        // They have left the job: the whole app is theirs again.
        if (r.err === 'not_whitelisted') { return leaveJobView(); }
        // Switched off by the server since the screen was drawn: the
        // toggle goes, as a read now would take it away.
        if (r.err === 'feature_off' && state.jobView) {
          delete state.jobView.alerts;
          redrawFor(['jobview']);
        }
        return fail(r);
      }
      var now = !!(r.data && r.data.on === true);
      if (state.jobView) { state.jobView.alerts = { on: now }; }
      redrawFor(['jobview']);
      say(now ? t('app.notify_me_is_on') : t('app.notify_me_is_off'), 'ok');
    });
  }

  /* One entry of the whitelisted-job view. `own` is a contract on this
     player, the one place its buyout is drawn. */
  function jobViewCard(entry, own) {
    var node = el('div', 'card');
    var head = el('div', 'card-head');
    var left = el('div', 'card-identity');
    left.appendChild(portrait(entry.targetName, null));
    var who = el('div', 'identity');
    who.appendChild(el('div', 'target', entry.targetName || t('app.unknown')));
    if (entry.targetJob) { who.appendChild(el('div', 'target-job', entry.targetJob)); }
    left.appendChild(who);
    head.appendChild(left);
    node.appendChild(head);

    var meta = el('div', 'meta');
    // Left out where no acceptance bulletin goes: not "open", which it
    // may not be.
    if (entry.hitmenActive !== undefined && entry.hitmenActive !== null) {
      var taken = Number(entry.hitmenActive) || 0;
      meta.appendChild(taken > 0
        ? chip(tn('app.taken_by_hitmen', taken), 'hot', 'i-users')
        : chip(t('app.open_no_hitman_yet'), null, 'i-users'));
    }
    var posted = agoText(entry.postedAt);
    if (posted) {
      meta.appendChild(chip(t('app.posted_ago', posted.charAt(0).toLowerCase() + posted.slice(1)),
        null, 'i-flag'));
    }
    var clock = clockChip(entry);
    if (clock) { meta.appendChild(clock); }
    // Their own entry only, as On me shows it: a placer who put their name
    // to it, and the operatives who took it under theirs where the server
    // shows those to the target. A colleague's entry never carries either.
    if (own) {
      if (entry.creatorName) {
        meta.appendChild(chip(t('app.placed_by') + entry.creatorName, null, 'i-briefcase'));
      }
      asList(entry.operatives).forEach(function (o) {
        if (o && o.name) {
          meta.appendChild(chip((o.alias || t('app.an_operative')) + ': ' + o.name, 'hot', 'i-user'));
        }
      });
    }
    node.appendChild(meta);

    if (own) {
      // What their informant found, and the look-up itself, where the server
      // sells it to a member of a whitelisted job.
      informantFound(node, entry.informantFound);
      var row = el('div', 'row actions');
      // As On me says it, for a target the app shows only this view.
      if (entry.tippedAt) { row.appendChild(tipToldNotice(entry.tippedAt)); }
      appendBuyout(row, entry);
      if (informantOffered(entry)) { row.appendChild(informantButton(entry)); }
      node.appendChild(row);
    } else if (entry.tipAdvisedAt) {
      // The bulletin said a hitman bought an informant tip on them: when,
      // never who or where.
      var tip = el('div', 'tip-told');
      tip.appendChild(el('div', 'tip-state ico i-eye', t('app.a_hitman_has_a_tip_on')));
      var tipWhen = agoText(entry.tipAdvisedAt);
      if (tipWhen) {
        tip.appendChild(el('div', 'hint', t('app.tipped_off') + tipWhen.charAt(0).toLowerCase()
          + tipWhen.slice(1) + '.'));
      }
      node.appendChild(tip);
    }
    return node;
  }

  function viewLedger(view) {
    if (drewFailure(view, 'ledger')) { return; }
    if (drewPending(view, 'ledger')) { return; }
    var data = state.ledger || {};
    var rows = asList(data.entries);
    var record = data.record;

    if (record) {
      var card = el('div', 'card record');
      card.appendChild(el('div', 'target', record.standing));
      // Figures rather than pills: three grey capsules in a row read as
      // three buttons, and the numbers were the smallest thing in them.
      var stats = el('div', 'stats');
      stats.appendChild(tally(record.completed, t('app.completed_label')));
      // What the success rate is worked out from beside it: the rate was
      // drawn and the contracts that brought it down were not.
      if (typeof record.failed === 'number') {
        stats.appendChild(tally(record.failed, t('app.abandoned_or_lost')));
      }
      stats.appendChild(tally(record.placed, t('app.placed_label')));
      stats.appendChild(tally(record.survived, t('app.survived_label')));
      if (record.rate !== undefined && record.rate !== null) {
        stats.appendChild(tally(record.rate + '%', t('app.success_label')));
      }
      card.appendChild(stats);
      view.appendChild(card);
    }

    /* Payments of theirs that would not fit and wait for room. A receipt
       missed, or a page closed, was the only word of them anywhere. A count
       of their own and nothing else. */
    var waiting = Number(data.waiting) || 0;
    if (waiting > 0) {
      view.appendChild(el('div', 'hint', tn('app.payments_waiting_for_room', waiting)));
    }

    /* Photos kept for this client in the app whose ledger row is gone:
       pushed off by newer rows, or past the days a row keeps its photo. A
       kept photo outlives its row, and this is where its owner finds it. */
    var kept = asList(data.kept).filter(function (photo) {
      return photo && typeof photo === 'object' && photo.state === 'kept';
    });

    if (!rows.length && !kept.length) {
      view.appendChild(el('div', 'empty', t('app.no_history_yet')));
      view.appendChild(buildStamp());
      return;
    }
    rows.forEach(function (row) {
      var node = el('div', 'card');
      // The same face and name as the entry had on the board, so a closed
      // file reads as the one that was open.
      var head = el('div', 'card-identity');
      head.appendChild(portrait(row.target_name || t('app.unknown'), null));
      var who = el('div', 'identity');
      who.appendChild(el('div', 'target', row.target_name || t('app.unknown')));
      who.appendChild(el('div', 'reason', row.reason || ''));
      head.appendChild(who);
      node.appendChild(head);
      var meta = el('div', 'meta');
      // The part they played, in words: "creator" and "hitman" were the
      // server's field values, read off the row as they were stored.
      meta.appendChild(chip(ROLE_WORDS[row.role] || t('app.you_were_on_it'), 'role',
        ROLE_ICONS[row.role] || 'i-user'));
      var outcome = ledgerOutcome(row);
      meta.appendChild(chip(outcome.text, 'hot', outcome.icon));
      // What it moved in money, said from their side of it.
      var moved = ledgerAmount(row);
      if (moved) { meta.appendChild(chip(moved, 'plain', 'i-coin')); }
      // When it closed. Entries on the same target read alike without it.
      var closedAgo = agoText(row.resolved_at);
      if (closedAgo) { meta.appendChild(chip(closedAgo, 'plain', 'i-clock')); }
      node.appendChild(meta);
      /* The kill photo, on the client's own row only, and never drawn in
         the list. This was a thumbnail of the photo's link on any row that
         had one — the hitman's own included — so the photograph of a body
         was on screen whenever the Ledger was, loaded from somebody else's
         host on every refresh. Now there is a button, and the photo is
         opened on purpose, once. */
      if (row.role === 'creator' && row.photo && typeof row.photo === 'object') {
        node.appendChild(proofLine(row.photo));
      }
      appendRef(node, row.contract_id);
      view.appendChild(node);
    });

    if (kept.length) {
      view.appendChild(el('h3', 'section', t('app.photos_kept_in_this_app')));
      kept.forEach(function (photo) {
        var node = el('div', 'card');
        node.appendChild(el('div', 'target', t('app.kill_photo')));
        var taken = agoText(photo.taken_at);
        if (taken) { node.appendChild(el('div', 'reason', t('app.taken_ago', taken.toLowerCase()))); }
        node.appendChild(proofLine(photo));
        view.appendChild(node);
      });
    }

    if (rows.length) { view.appendChild(refHint()); }
    view.appendChild(buildStamp());
  }

  /* What a client's ledger row says about its kill photo: a button while
     it waits to be seen, or while it is kept for them in the app, and
     otherwise what they did with it. Nothing at all once it is gone. */
  function proofLine(photo) {
    var line = el('div', 'proof-line');
    if (photo.state === 'pending' || photo.state === 'kept') {
      line.appendChild(actionButton('ghost ico i-camera', t('app.view_photo'),
        'proof:' + photo.handle, t('app.opening'),
        function () { return openProof(photo.handle); }));
      line.appendChild(el('div', 'hint', photo.state === 'kept'
        ? t('app.kept_for_you_in_this_app_3') : t('app.you_can_see_it_once')));
    } else if (PROOF_WORDS[photo.state]) {
      line.appendChild(el('div', 'hint', PROOF_WORDS[photo.state]));
    }
    return line;
  }

  // The icon beside the part a player played in a closed contract.
  var ROLE_ICONS = { hitman: 'i-user', creator: 'i-briefcase', target: 'i-eye' };
  // And the part itself, as they would say it.
  var ROLE_WORDS = { creator: t('app.you_placed_it'), hitman: t('app.you_took_it'), target: t('app.it_was_on_you') };

  /* How a closed contract ended, from the row's kind (the server's Ledger:
     'paid', 'withdrawn', 'refunded', 'cancelled', 'buyout'; a row from before there were
     kinds is a payout). */
  function ledgerOutcome(row) {
    var kind = row.kind || 'paid';
    if (kind === 'withdrawn') { return { text: t('app.withdrawn'), icon: 'i-xcircle' }; }
    if (kind === 'refunded') { return { text: t('app.ran_out_refunded'), icon: 'i-clock' }; }
    if (kind === 'cancelled') { return { text: t('app.cancelled_refunded'), icon: 'i-xcircle' }; }
    if (kind === 'buyout') { return { text: t('app.bought_out'), icon: 'i-exit' }; }
    // A proof item handed to the placer (Config.Improvements.ProofItems):
    // paid as a kill would be, but nobody saw one.
    if (row.fulfilment === 'proof') { return { text: t('app.proof_handed_over'), icon: 'i-usercheck' }; }
    return row.fulfilment === 'kidnapping'
      ? { text: t('app.delivered_alive'), icon: 'i-usercheck' }
      : { text: t('app.eliminated'), icon: 'i-crosshair' };
  }

  /* The money a row moved, from this player's side: what they were paid,
     what a payout cost them, what came back, what a buyout cost. Null where
     nothing of theirs moved, or the row predates the figure. */
  function ledgerAmount(row) {
    var amount = Number(row.amount) || 0;
    if (!(amount > 0)) { return null; }
    var kind = row.kind || 'paid';
    if (kind === 'withdrawn' || kind === 'refunded' || kind === 'cancelled') {
      // The operatives' stakes it handed over are counted in, and said so
      // (the server's Ledger.ended): never whose.
      var stakes = Number(row.stakes) || 0;
      return money(amount) + t('app.back_to_you')
        + (stakes > 0 ? ' (' + money(stakes) + t('app.of_it_forfeited_stakes') : '');
    }
    if (kind === 'buyout') {
      return row.role === 'target' ? t('app.you_paid') + money(amount) : money(amount) + t('app.to_you');
    }
    if (row.role === 'hitman') { return t('app.paid_you') + money(amount); }
    if (row.role === 'creator') { return t('app.cost_you') + money(amount); }
    return null;
  }

  /* Which copy of this page the player is actually running.

     CEF caches app.js on its own disk, so "have you updated?" and "is the
     update running?" are different questions, and for a long time neither
     end of a support conversation could answer the second one. Now the page
     says so itself. */
  /* The build number, and the way into the diagnostics panel.

     Five taps, the way a phone exposes a developer menu. There is no
     keyboard in here and no room on a phone screen for a permanent control,
     and a player reading out a build number is already the first question
     anyone asks them. */
  function buildStamp() {
    var build = (typeof window !== 'undefined' && window.CH_BUILD) || 'unknown';
    var stamp = el('div', 'hint build-stamp', t('app.crimson_hitman_build') + build);
    stamp.onclick = function () { Diag.tapped(); };
    return stamp;
  }

  function viewThread(view) {
    var tv = state.thread;
    if (!tv) { state.tab = 'mine'; return render(); }

    // The head stays on the top edge (see the stylesheet): Back, who and
    // what the thread is about, and Call on one line, Mute on its own under
    // them.
    var head = el('div', 'thread-head');
    var row = el('div', 'row thread-bar');
    head.appendChild(row);

    var back = el('button', 'ghost ico i-left', t('app.back'));
    back.onclick = function () { navigated(); state.tab = 'mine'; render(); };
    row.appendChild(back);

    /* Who this thread is with, and which contract it is about. Every
       message is signed with an alias, but the thread itself was never
       named — so a creator with several operatives could not tell which of
       them they were writing to. And a hitman holding two contracts from
       anonymous clients got two threads both headed "With The client",
       with nothing to say which job either was, so a message could go to
       the wrong one. The target names the contract; the line under it
       names the other party. Each is one line and cuts off rather than
       wrapping, so a long name cannot push Back and Call apart. */
    // A hitman's thread is with the person who placed the contract, said
    // as that: the server called them "Client", which a player new to the
    // app could not place.
    var placerSide = tv.contract.role === 'hitman';
    var withWhom = placerSide ? t('app.the_person_who_placed_it')
      : tv.thread && tv.thread.alias
        ? tv.thread.alias + (tv.thread.name ? ' (' + tv.thread.name + ')' : '')
        : null;
    var about = el('div', 'hint');
    if (tv.contract.targetName) {
      about.appendChild(el('div', 'about', tv.contract.targetName));
    }
    if (withWhom) {
      about.appendChild(el('div', 'with', t('app.with_whom', withWhom)));
    }
    row.appendChild(about);

    // The server has always had a call path and nothing reached it, so the
    // whole feature was unreachable from the phone.
    //
    // Not when both sides are anonymous: neither can be rung and the server
    // sends nothing, so the button could only say calls were off. A
    // creator's thread names the operative only when they chose to be seen.
    var bothAnonymous = tv.contract.creatorAnonymous === true
      && (tv.contract.role === 'hitman'
        ? tv.contract.myAnonymous === true
        : !!(tv.thread && !tv.thread.name));
    // Nor where either side is anonymous and the phone cannot hide the
    // number as the server requires (settings().canMask): every Call there
    // was refused, and a call asked of the other side sent them to a Call
    // that was refused too.
    var anyAnonymous = tv.contract.creatorAnonymous === true
      || (tv.contract.role === 'hitman' ? tv.contract.myAnonymous === true
        : !(tv.thread && tv.thread.name));
    if (state.call === threadKey(tv.contract, tv.thread)) {
      // lb-phone draws no call screen for a call placed from here — its
      // CreateCall is built for payphones — so this is the only way the
      // caller can put the phone down. Whatever the settings say now: calls
      // switched off mid-call took the button away, and with it the call's
      // only end.
      var hang = el('button', 'ghost ico i-xcircle', t('app.hang_up'));
      hang.id = 'thread-hangup';
      hang.onclick = function () { endCall(); };
      row.appendChild(hang);
    } else if (settings().calls && !bothAnonymous
        && !(anyAnonymous && settings().canMask === false)) {
      // Held while it is asked, so a double tap places one call, not two.
      var call = actionButton('ghost ico i-phone', t('app.call'),
        'call:' + threadKey(tv.contract, tv.thread), t('app.calling'),
        function () { return requestCall(); });
      call.id = 'thread-call';
      row.appendChild(call);
    }

    // Silences this thread's ring on this phone only. Words rather than an
    // icon, because which way it is set is the whole point of the button.
    //
    // On a line of its own. In the one above, its width came out of the
    // who-and-what in the middle, the only thing in the head that cannot
    // be put back with a tap: at 390px "with Operative #2" was cut to
    // "with Operat…", and a client with several operatives could not tell
    // which one they were writing to.
    var mute = actionButton('ghost', tv.muted ? t('app.unmute') : t('app.mute'),
      'mute:' + threadKey(tv.contract, tv.thread),
      tv.muted ? t('app.unmuting') : t('app.muting'),
      function () { return toggleMute(); });
    mute.id = 'thread-mute';
    var tools = el('div', 'row thread-tools');
    tools.appendChild(mute);
    // Reporting this conversation to staff, with its last messages.
    var report = reportButton(tv.contract, tv.thread);
    report.id = 'thread-report';
    tools.appendChild(report);
    head.appendChild(tools);

    view.appendChild(head);

    var thread = el('div', 'thread');
    tv.messages.forEach(function (m) {
      var msg = el('div', 'msg' + (m.mine ? ' mine' : ''));
      // Signed by the placer, to a hitman: a message stored before the
      // server named them so still carries "Client".
      msg.appendChild(el('div', 'who', placerSide && !m.mine && (!m.alias || m.alias === 'Client')
        ? t('app.the_person_who_placed_it_2') : m.alias));
      msg.appendChild(el('div', null, m.body));
      thread.appendChild(msg);
    });
    // A new thread was a header and a text box with nothing between them.
    if (!tv.messages.length) {
      thread.appendChild(el('div', 'hint', t('app.no_messages_yet')));
    }
    view.appendChild(thread);

    /* The compose box.
    
       It was an <input> and nothing else, cleared the instant Enter was
       pressed and rebuilt empty by any render. So: a refused message lost
       the text that was refused, a push landing mid-sentence emptied the
       box under the player, and there was no Send button at all — Enter
       only, on a phone, where whether the on-screen keyboard produces one
       depends on the keyboard. */
    var field = el('div', 'field compose');
    var input = make('input');
    input.id = 'compose-input';
    input.placeholder = t('app.say_something');
    input.maxLength = settings().messageMaxLength || 200;
    input.value = tv.draft || '';
    input.oninput = function () {
      tv.draft = input.value;
      state.drafts[threadKey(tv.contract, tv.thread)] = input.value;
    };

    // Per conversation, not per contract: a send to one operative must not
    // lock the box in another's thread.
    var busyKey = 'message:' + threadKey(tv.contract, tv.thread);

    function send() {
      var body = input.value;
      if (!body) { return; }
      once(busyKey, function () { return sendMessage(body); });
    }

    input.onkeydown = function (e) { if (e.key === 'Enter') { send(); } };
    field.appendChild(input);

    var go = el('button', 'primary',
      isBusy(busyKey) ? t('app.sending') : t('app.send'));
    if (isBusy(busyKey)) { go.disabled = true; }
    else { go.onclick = send; }
    field.appendChild(go);

    view.appendChild(field);
  }

  function viewPlace(view) {
    var form = el('div', 'place-form');
    // A server that does not allow placing anonymously draws no such option,
    // and a draft ticked before it was turned off is placed under the name.
    if (!anonymityOffered('creator')) { state.draft.anon = false; }

    // What the creator actually has, read server-side, so an over-budget
    // contract is obvious before they submit rather than after.
    //
    // Each branch is chosen by exactly the thing it draws. It used to lead
    // with "have I asked yet", which meant a render that happened while the
    // request was in flight matched neither that nor the failure branch and
    // fell through to the one that reads the wallet — throwing on a wallet
    // that had not arrived, and taking the whole form with it. Rebuilds
    // during that window are the normal case, not a rare one: the target
    // list lands in it.
    if (state.walletFailed && state.walletFailed.final) {
      var closed = el('div', 'card');
      closed.appendChild(el('div', 'hint', state.walletFailed.text));
      form.appendChild(closed);
    } else if (state.walletFailed) {
      var failed = el('div', 'card');
      failed.appendChild(el('div', 'hint', state.walletFailed.text
        + t('app.money_still_works_items_and_weapons')
        + (state.walletFailed.code ? t('app.code_paren', state.walletFailed.code) : '')));
      var again = el('button', 'ghost ico i-refresh', t('app.try_again'));
      again.onclick = function () {
        state.walletFailed = null; state.walletPending = false; render();
      };
      failed.appendChild(again);
      form.appendChild(failed);
    } else if (state.wallet) {
      var w = state.wallet;
      var wcaps = w.caps || {};
      var wallet = el('div', 'card funds');
      // A strip of figures, each under its caption, rather than three pills.
      var meta = el('div', 'stats');
      // Only what this server will actually take. A balance shown beside a
      // source that is switched off is an offer the form cannot honour.
      if (wcaps.cashEnabled !== false) { meta.appendChild(balance(t('app.cash'), money(w.cash))); }
      if (wcaps.bankEnabled !== false) { meta.appendChild(balance(t('app.bank'), money(w.bank))); }
      if (wcaps.dirtyEnabled !== false) { meta.appendChild(balance(t('app.dirty'), money(w.dirty))); }
      wallet.appendChild(meta);
      form.appendChild(wallet);
    } else {
      // Nothing yet. Ask, if nobody has — once, not once per render. The
      // form is rebuilt whenever anything on it changes, and each rebuild
      // used to send its own request, spending the same per-player
      // allowance the target list needs, several times over, before the
      // first reply had even landed.
      if (!state.walletPending) {
        state.walletPending = true;
        post('rewardOptions', {}).then(function (r) {
          state.walletPending = false;
          if (r.ok && r.data) {
            state.wallet = r.data;
            state.walletFailed = null;
          } else {
            // Silently dropping the pickers left a form that simply had no
            // item or weapon section, with nothing saying why and no way to
            // ask again.
            // The code is named, not swallowed. "Could not read what you
            // are carrying" is true of a rate limit, a crashed handler and
            // a refused gate alike, and a player reporting it to an admin
            // was passing on a shrug — which cost days of guessing at a
            // fault the server could have named in one word. Labelled and
            // put last, after the sentence, so it reads as something to
            // quote rather than as part of what the player is being told.
            // Not "Money still works" where nothing does: the server's
            // boot recovery failed, and placing is refused too.
            state.walletFailed = (r.err === 'rate_limited')
              ? { text: t('app.reading_your_pockets_too_fast_try')
                  + retryIn(r.data && r.data.retryAfter) + '.' }
              : finalRefusal(r.err)
                ? { text: ERRORS[r.err], final: true }
                : { text: t('app.could_not_read_what_you_are'),
                    code: r.err || 'no reply' };
          }
          redraw();
        });
      }

      // And say so meanwhile. A reply that never comes back — a callback
      // lost on the way to the client — would otherwise leave this branch
      // drawing nothing at all, forever, with no way to ask again.
      var waiting = el('div', 'card');
      waiting.appendChild(el('div', 'hint', t('app.reading_what_you_are_carrying')));
      var retry = el('button', 'ghost ico i-refresh', t('app.try_again'));
      retry.onclick = function () { state.walletPending = false; render(); };
      waiting.appendChild(retry);
      form.appendChild(waiting);
    }

    /* Four sheets, in the order a contract is written: who, the job, what
       it pays, and on what terms. This was one column of fifteen controls
       with nothing to say where one decision ended and the next began.
       Only the paper is new — every field, id and draft key, and the order
       they come in, is as it was. */
    var subject = formSection(t('app.subject'));
    subject.appendChild(labelled(t('app.target'), targetSearch()));
    form.appendChild(subject);

    var job = formSection(t('app.the_job'));

    // The reason control this server will actually accept.
    //
    // Config.Reason.Mode takes 'freetext', 'preset' or 'off', and the form
    // drew a text box for all three. On a server set to 'preset' the server
    // wants an index into a list the page had never been given, so it
    // refused every contract with invalid_input — and the box the player had
    // just filled in was not the field being rejected, so there was nothing
    // to correct and no way to find out. Same shape as the money sources an
    // operator had switched off, which the form went on offering until caps
    // started carrying the flags.
    var reasonMode = settings().reasonMode || 'freetext';
    var presets = asList(settings().reasonPresets);

    if (reasonMode === 'preset' && presets.length) {
      var pick = make('select');
      pick.id = 'reasonPreset';
      presets.forEach(function (text, i) {
        var opt = document.createElement('option');
        // One-based: the server indexes its own list, and a zero is not a
        // choice it accepts.
        opt.value = String(i + 1);
        opt.textContent = text;
        pick.appendChild(opt);
      });
      job.appendChild(labelled(t('app.reason'), drafted(pick, 'reasonPreset', '1')));
    } else if (reasonMode !== 'off') {
      job.appendChild(labelled(t('app.reason'),
        drafted(textInput('reason', t('app.why_2'), settings().reasonMaxLength || 140),
                'reason')));
    }

    var mode = make('select');
    mode.id = 'mode';
    [['exclusive', t('app.exclusive_one_hitman')],
     ['competitive', t('app.competitive_first_to_finish')]].forEach(function (o) {
      var opt = document.createElement('option');
      opt.value = o[0]; opt.textContent = o[1];
      mode.appendChild(opt);
    });
    job.appendChild(labelled(t('app.assignment'), drafted(mode, 'mode', 'exclusive')));
    form.appendChild(job);

    var pay = formSection(t('app.payment'));

    // How many times a contract can be collected, only where the server
    // allows more than once (Config.Limits.MaxPayoutSlots, 1 to 3). At 1,
    // as shipped, there is nothing to choose, and nothing about further
    // collections is drawn at all.
    if (slotCeiling() > 1) {
      var slots = drafted(numberInput('slots', 1), 'slots', '1');
      slots.min = 1;
      // The server's ceiling, not a number typed here: raising
      // MaxPayoutSlots in the config used to leave the form refusing to go
      // past five.
      slots.max = slotCeiling();
      slots.onchange = function () { state.draft.slots = slots.value; renderSlots(); };
      pay.appendChild(labelled(t('app.payouts_how_many_times_it_can'), slots));
      var ceilingNote = el('div', 'hint');
      ceilingNote.id = 'slots-ceiling';
      pay.appendChild(ceilingNote);
      pay.appendChild(el('div', 'hint',
        t('app.every_payout_is_paid_in_and') +
        t('app.payouts_the_first_to_finish_are')));
    }
    // The least a contract may be worth (caps.minValue, 0 for none), said
    // where the money is set rather than in a refusal once it is all filled
    // in. The bonus counts towards it, as it does towards the ceiling.
    var payCaps = (state.wallet && state.wallet.caps) || {};
    var leastValue = Number(payCaps.minValue) || 0;
    if (leastValue > 0) {
      pay.appendChild(el('div', 'hint', minRewardText(leastValue)
        + (placingAliveOnly() || payCaps.bonusPercent === 0 ? '' : t('app.the_kidnapping_bonus_does'))));
    }
    // What a payout is paid for, on a server that places contracts for a
    // live delivery only. Said where the money is set, since it is what the
    // money buys, and in place of the bonus field, whose hint was the only
    // thing that told a creator they have to be at the handover.
    if (placingAliveOnly()) {
      pay.appendChild(el('div', 'hint',
        t('app.contracts_here_only_pay_when_the')
        + t('app.to_be_in_the_city_to')));
    }

    var slotBox = el('div');
    slotBox.id = 'slots';
    pay.appendChild(slotBox);
    form.appendChild(pay);

    var terms = formSection(t('app.terms'));

    // Bounded by the ceiling the server sent, and told to the creator.
    // caps.bonusPercent was computed and shipped and never read, so a figure
    // over the cap reached the server — which clamps it now, and used to
    // drop it to no bonus at all.
    //
    // A cap of 0 is a server with no bonus, not a server with no cap: read
    // with ||, it offered the box at 50 with no ceiling.
    var caps = state.wallet && state.wallet.caps;
    var bonusCap = caps && typeof caps.bonusPercent === 'number' ? caps.bonusPercent : null;
    // And none where contracts are placed for a live delivery only: the
    // whole reward is paid for that, so there is nothing to pay on top, and
    // the server places them with no bonus whatever is typed here.
    var bonusOffered = bonusCap !== 0 && !placingAliveOnly();
    if (!bonusOffered) {
      delete state.draft.bonus;
    } else {
      // Opens at 0: a bonus is money taken now on top of the reward, and
      // one the creator never typed was one they never chose. It opened at
      // 50%, so $40,000 typed into Cash took $60,000.
      var bonusOpen = '0';
      var bonusField = drafted(numberInput('bonus', bonusOpen), 'bonus', bonusOpen);
      if (bonusCap) { bonusField.max = bonusCap; }
      terms.appendChild(labelled(
        t('app.kidnapping_bonus_3') + (bonusCap ? t('app.up_to_2') + bonusCap + ')' : ''),
        bonusField));
      // It opens at 50 and is money taken now, which nothing said: a creator
      // holding exactly what they entered was refused for the half on top.
      // The total it comes to is said above the Place button.
      terms.appendChild(el('div', 'hint',
        t('app.paid_on_top_of') + (slotCeiling() > 1 ? t('app.a_payout') : t('app.the_reward'))
        + t('app.when_the_target_is_delivered_alive')
        + t('app.items_marked_alive_only_it_is')
        + t('app.comes_back_if_nobody_earns_it')
        + t('app.brought_to_you_you_have_to')));
    }
    // Not on a server without buyouts, where the figure was taken and then
    // quietly set to nothing.
    if (settings().buyouts !== false) {
      terms.appendChild(labelled(t('app.buyout_price_0_for_none_2'),
        drafted(numberInput('bailout', 0), 'bailout', '0')));
      // The server holds the price between the clean money in the reward,
      // bonus lines included, and a multiple of it, and moves anything
      // outside to the nearest limit without a word: $1,000 on $10,000 with
      // the 50% bonus became $15,000. Said here, and the price it settled on
      // is said once it is placed and on the client's card.
      terms.appendChild(el('div', 'hint',
        t('app.what_the_target_can_pay_to')
        + t('app.cash_and_bank_you_put_up') + (placingAliveOnly() ? '' : t('app.kidnapping_bonus_included'))
        + t('app.and_a_few_times_that_and')));
    } else {
      delete state.draft.bailout;
    }
    // "Stake", the word every card, dialog and proposal uses for it. Set
    // here as a "failure penalty", it came back on the client's own card as
    // "$5,000 stake", which read as a second figure.
    terms.appendChild(labelled(t('app.hitmans_stake_0_for_none'),
      drafted(numberInput('penalty', 0), 'penalty', '0')));
    terms.appendChild(el('div', 'hint',
      t('app.a_hitman_stakes_this_when_they')));

    // How long it runs. The form has no deadline of its own: every contract
    // gets the server's default, and nothing here said what that was, so a
    // client expecting a day-long contract who never opened Edit had it
    // lapse after three hours.
    //
    // And while whom: a named client's clock also stops while they are
    // away, an anonymous one's follows the target alone (§14.32), so it
    // follows the checkbox. The lifetime runs through every stop, and no
    // extension goes past it.
    // The rule as the server keeps it (clock_rule_spec): the clock runs only
    // while the placer (named or anonymous), the target and an operative
    // holding it are all in the city, and not at all before somebody takes
    // it. It said the target alone, or the two of them, and nothing of the
    // wait for a taker.
    function clockHint() {
      var ceiling = Number(settings().deadlineMaxMinutes) || 0;
      return t('app.it_runs_for') + durationText(Number(settings().defaultDeadlineMinutes) || 180)
        + t('app.counted_only_while_you_the_target')
        + t('app.it_does_not_start_until_someone')
        + t('app.comes_back_extend_it_from_mine')
        + (ceiling > 0 ? t('app.up_to') + durationText(ceiling) + t('app.after_you_place_it') : '.');
    }
    var clock = el('div', 'hint', clockHint());
    terms.appendChild(clock);

    // Not drawn at all where the server does not allow it for the target
    // picked (anonymityOffered): one on a whitelisted job reads its own
    // switch (settings().anonymity.whitelisted), by the mark the pick
    // already carries. Drawn again when the pick changes (placeAnonSync).
    var anonSlot = el('div', null);
    terms.appendChild(anonSlot);
    function drawAnonOption() {
      anonSlot.innerHTML = '';
      // Not offered: placed under the placer's name, and said before they
      // pay. The target's On Me card names who placed it, and a police
      // target's screen shows it at once; nothing on the form said so.
      if (!anonymityOffered('creator', state.draft.targetProtected === true)) {
        anonSlot.appendChild(el('div', 'hint', t('app.placed_under_your_name_notice')));
        return;
      }
      var anon = make('input');
      anon.type = 'checkbox'; anon.id = 'anon';
      anon.checked = state.draft.anon === true;
      anon.onclick = function () {
        state.draft.anon = anon.checked;
        clock.textContent = clockHint();
        // The item pickers hold back what names its owner while it is ticked;
        // renderSlots brings the total up to date too.
        renderSlots();
      };
      // A label, so the words toggle it too. The box on its own is a twenty
      // pixel target on a phone screen, which is a coin toss.
      var toggle = document.createElement('label');
      toggle.className = 'toggle';
      toggle.htmlFor = 'anon';
      toggle.appendChild(anon);
      toggle.appendChild(el('span', null, t('app.place_anonymously')
        + (anonymityFee('creator') > 0 ? t('app.costs_from_your_paren', money(anonymityFee('creator')), anonymityAccount()) : '')));
      anonSlot.appendChild(toggle);
    }
    drawAnonOption();
    // Sent to the hitman organisation instead of the open board, where the
    // server offers it (Config.Organisation.OrgContracts): a boss there
    // assigns it, and it goes on the open board if nobody takes it in time.
    var toOrg = settings().orgContracts;
    if (toOrg && typeof toOrg === 'object') {
      var org = make('input');
      org.type = 'checkbox'; org.id = 'to-org';
      org.checked = state.draft.toOrg === true;
      org.onclick = function () { state.draft.toOrg = org.checked; };
      var orgToggle = document.createElement('label');
      orgToggle.className = 'toggle';
      orgToggle.htmlFor = 'to-org';
      orgToggle.appendChild(org);
      orgToggle.appendChild(el('span', null, t('app.send_to') + String(toOrg.label || t('app.the_organisation'))
        + t('app.a_boss_assigns_it_not_taken') + durationText(Number(toOrg.minutes) || 30)
        + t('app.it_goes_on_the_open_board')));
      terms.appendChild(orgToggle);
      // Several organisations: which one it goes to.
      var orgList = Array.isArray(toOrg.orgs) ? toOrg.orgs : [];
      if (orgList.length > 1) {
        if (!orgList.some(function (o) { return o.id === state.draft.toOrgId; })) {
          state.draft.toOrgId = String(orgList[0].id);
        }
        var orgPick = el('div', 'row org-actions');
        orgList.forEach(function (o) {
          var b = el('button', 'btn' + (o.id === state.draft.toOrgId ? ' primary' : ''), String(o.label || o.id));
          b.type = 'button';
          b.setAttribute('aria-pressed', o.id === state.draft.toOrgId ? 'true' : 'false');
          b.onclick = function () {
            state.draft.toOrgId = String(o.id);
            Array.prototype.forEach.call(orgPick.children, function (other) {
              var on = other === b;
              other.className = 'btn' + (on ? ' primary' : '');
              other.setAttribute('aria-pressed', on ? 'true' : 'false');
            });
          };
          orgPick.appendChild(b);
        });
        terms.appendChild(orgPick);
      } else {
        state.draft.toOrgId = null;
      }
    } else {
      state.draft.toOrg = false;
    }
    // A pick that changes the rule: the option drawn again, and a box
    // ticked under the other rule unticked where this one allows none.
    placeAnonSync = function () {
      if (!anonymityOffered('creator', state.draft.targetProtected === true)
          && state.draft.anon === true) {
        state.draft.anon = false;
        clock.textContent = clockHint();
        renderSlots();
      }
      drawAnonOption();
    };
    form.appendChild(terms);

    // What placing it takes, right above the button that takes it. Filled
    // in by showPlaceTotal, which every field on the form calls.
    var placeTotal = el('div', 'hint place-total');
    placeTotal.id = 'place-total';
    form.appendChild(placeTotal);

    // Through `once`, because this one charges money. Nothing on screen
    // changed for the whole round trip and the button stayed live, so a
    // second tap placed a second contract and took a second escrow — the
    // most expensive tap in the app, and the one most likely to be made.
    // Armed by the first tap (submitContract), naming what it takes; the
    // second places it. Placing was the one charge in the app on one tap.
    var armed = state.placeArmed && !isBusy('create');
    var submit = el('button', armed ? 'danger' : 'primary',
      isBusy('create') ? t('app.placing')
        : armed ? state.placeArmed.label : t('app.place_contract'));
    submit.id = 'place-submit';
    placeSubmit = submit;
    // Paused by staff, or suspended: placing is refused, so not live. The
    // banner at the top says why.
    if (takingPaused() && !isBusy('create')) {
      submit.disabled = true;
      submit.textContent = t('app.place_contract');
    }
    if (isBusy('create')) {
      submit.disabled = true;
      submit.classList.toggle('is-busy', true);
    } else {
      submit.onclick = submitContract;
    }
    form.appendChild(submit);

    view.appendChild(form);
    renderSlots();
  }

  /* How many payouts the form is building, held to the server's ceiling.

     The field's max stops the stepper arrows and nothing else: a phone keypad
     types, and a browser does not bind a typed value to max. So 9 on a
     server taking 3 drew nine payouts, let them all be funded, and was
     refused as "That reward does not add up" when the amounts added up
     perfectly; and 2000 built two thousand payout blocks in one pass. The
     form and the submit each derived the count on their own, so a clamp in
     one would still have sent a contract that differed from the one on
     screen — both read it from here. */
  function payoutCount() {
    var ceiling = slotCeiling();
    var count = parseInt(state.draft.slots, 10);
    if (!count || count < 1) { return 1; }
    return Math.min(count, ceiling);
  }

  /* How many times the server lets one contract be collected
     (caps.slots, Config.Limits.MaxPayoutSlots). While the wallet is being
     read again (every visit to this tab), the last figure the server gave;
     once, where it has never said: a field offering more than the server
     takes builds a contract it refuses. */
  function slotCeiling() {
    var told = parseInt(state.wallet && state.wallet.caps && state.wallet.caps.slots, 10);
    if (told > 0) { state.slotCeiling = told; }
    return state.slotCeiling || 1;
  }

  function renderSlots() {
    var box = document.getElementById('slots');
    if (!box) return;
    var count = payoutCount();

    // Put the clamped figure back in the box, and say why, so what the
    // field shows is what is being built.
    var typed = parseInt(state.draft.slots, 10);
    var note = document.getElementById('slots-ceiling');
    // Only against a figure the server has given: a draft is not cut down
    // to a guess while the wallet is being read again.
    var told = !!(state.wallet && state.wallet.caps && state.wallet.caps.slots);
    if (typed > count && told) {
      state.draft.slots = String(count);
      var field = document.getElementById('slots-count');
      if (field) { field.value = String(count); }
      if (note) { note.textContent = t('app.this_server_allows_at_most') + count + t('app.payouts_2'); }
      /* At one there is no count field to say it beside, and payouts 2 and
         up went with whatever was staged on them and no word. Said as a
         notice instead. */
      if (count === 1) {
        say(t('app.this_server_now_takes_one_payout_2')
          + (typed === 2 ? t('app.payout_2_was') : typed === 3 ? t('app.payouts_2_and_3_were')
            : t('app.payouts_2_to_were', typed)) + t('app.removed_2'), 'caution');
      }
    } else if (note) {
      note.textContent = '';
    }

    // Drop what was staged on payouts the player has taken away. This runs
    // only on a real change to the count, never on a rebuild: it used to run
    // on every render, and since a rebuilt form reported one payout, it
    // deleted everything staged on payouts two and up — destroying exactly
    // the state that was moved out of the DOM to protect it.
    Object.keys(state.picked).forEach(function (index) {
      if (parseInt(index, 10) > count) { delete state.picked[index]; }
    });

    box.innerHTML = '';
    for (var i = 1; i <= count; i++) {
      var slot = el('div', 'slot');
      // Numbered only where there can be more than one.
      slot.appendChild(el('h4', null, slotCeiling() > 1 ? t('app.payout_n', i) : t('app.reward')));

      var caps = (state.wallet && state.wallet.caps) || {};
      var split = el('div', 'split');
      var offered = 0;

      ['cash', 'bank', 'dirty'].forEach(function (source) {
        // A source the server has switched off is not offered. It used to
        // be drawn regardless, with the player's balance printed above it,
        // and the whole contract was then refused with "That reward does not
        // add up" — a message about the numbers, when the numbers were fine
        // and the source was simply not accepted.
        if (caps[source + t('app.enabled')] === false) { return; }
        offered++;

        var id = 'slot-' + source + '-' + i;
        var field = drafted(numberInput(id, 0), id, '0');

        // The ceiling the server will enforce, applied here so it is a
        // bounded field rather than a refusal after the fact. It was
        // computed, sent, and never read.
        var ceiling = caps[source];
        if (ceiling) { field.max = ceiling; }

        // The amount read back with its separators. A number box cannot
        // show them, and a third of a phone's width scrolls the start of a
        // long figure out of view, so $125,000 typed read as "12500".
        // Through addEventListener: drafted() owns oninput.
        var echo = el('div', 'hint money-echo');
        function readBack() {
          echo.textContent = Number(field.value) > 0 ? '= ' + money(Number(field.value)) : '';
        }
        field.addEventListener('input', readBack);
        readBack();

        var labelledField = labelled(SOURCE_LABELS[source] || source, field);
        labelledField.appendChild(echo);
        split.appendChild(labelledField);
      });

      if (offered > 0) {
        slot.appendChild(split);
        // A source switched off on its own said so nowhere: its field and
        // its balance just went. Said once, under the first payout.
        var off = ['cash', 'bank', 'dirty'].filter(function (source) {
          return caps[source + t('app.enabled')] === false;
        }).map(function (source) { return SOURCE_LABELS[source].toLowerCase(); });
        if (off.length && i === 1) {
          slot.appendChild(el('div', 'hint', t('app.this_server_does_not_take')
            + off.join(' or ') + t('app.as_a_reward')));
        }
      } else {
        slot.appendChild(el('div', 'hint',
          t('app.this_server_does_not_take_money')
          + t('app.below_if_it_takes_those')));
      }

      slot.appendChild(goodsBox(i));
      box.appendChild(slot);
    }

    // Goods added or taken away and payouts added or dropped all come
    // through here, so the total above the Place button follows them.
    showPlaceTotal();
  }

  /* ---------- items and weapons ----------
     The server has escrowed items and weapons since the first commit; this
     is what lets a player reach it. Everything shown comes from the
     server-read inventory in rewardOptions, and every amount is checked
     there again on submit — this only keeps the form honest. */

  /* What is staged on one payout. `alive` holds the goods that pay only
     for a live delivery — the server's bonus portion, which it has always
     escrowed and paid and which the form never let anyone fill — and
     `aliveOnly` is whether the next pick goes there. */
  function pickedFor(index) {
    if (!state.picked[index]) {
      state.picked[index] = { items: {}, weapons: {}, alive: { items: {}, weapons: {} },
                              aliveOnly: false };
    }
    return state.picked[index];
  }

  // Both halves of a payout, the kill's and the live delivery's.
  function stagedHalves(picked) {
    return picked.alive ? [picked, picked.alive] : [picked];
  }

  // How much of an item is already promised across every payout, so the
  // same 3 lockpicks cannot be put into three different payouts — or into
  // one payout twice, once for a kill and once more alive only.
  function allocatedItem(name) {
    var total = 0;
    Object.keys(state.picked).forEach(function (index) {
      stagedHalves(state.picked[index]).forEach(function (half) {
        total += half.items[name] || 0;
      });
    });
    return total;
  }

  function weaponTaken(slotNumber) {
    return Object.keys(state.picked).some(function (index) {
      return stagedHalves(state.picked[index]).some(function (half) {
        return half.weapons[slotNumber] !== undefined;
      });
    });
  }

  /* The goods half of a payout.
     
     This used to return an empty node whenever there was nothing to offer,
     which meant the Place form simply had no item or weapon section — no
     heading, no explanation, nothing to say whether the player was carrying
     nothing, the server had goods escrow switched off, or the inventory
     could not be read at all. Three different situations that all looked
     like a missing feature.
     
     The section is always here now, and always says which one it is. */
  function goodsBox(index) {
    var wrap = el('div', 'goods-box');
    var wallet = state.wallet;

    wrap.appendChild(el('h5', 'goods-title', t('app.items_weapons')));

    if (!wallet) {
      wrap.appendChild(el('div', 'hint', t('app.reading_your_pockets')));
      return wrap;
    }

    var caps = wallet.caps || {};
    var items = (caps.itemsEnabled === false) ? [] : asList(wallet.items);
    var weapons = (caps.weaponsEnabled === false) ? [] : asList(wallet.weapons);

    var picked = pickedFor(index);

    // What is already in this payout, each removable, the alive-only ones
    // marked as such.
    var chosen = el('div', 'meta');
    stagedHalves(picked).forEach(function (half) {
      var tail = (half === picked) ? '' : t('app.alive_only_2');
      Object.keys(half.items).forEach(function (name) {
        chosen.appendChild(removable(
          labelOf(items, name) + ' x' + half.items[name] + tail,
          function () { delete half.items[name]; renderSlots(); }));
      });
      Object.keys(half.weapons).forEach(function (slotNumber) {
        var weapon = half.weapons[slotNumber];
        chosen.appendChild(removable(weapon.label + (weapon.serial ? ' #' + weapon.serial : '') + tail,
          function () { delete half.weapons[slotNumber]; renderSlots(); }));
      });
    });
    if (chosen.children.length > 0) { wrap.appendChild(chosen); }

    if (items.length > 0) { wrap.appendChild(itemPicker(index, items)); }
    if (weapons.length > 0) { wrap.appendChild(weaponPicker(index, weapons)); }

    // Goods that pay only for a live delivery, which config and spec have
    // always promised and the server has always escrowed and paid: the form
    // offered one percentage and nothing else, so a rifle for bringing them
    // in breathing could not be put up. Not on a server with no kidnapping
    // bonus, the same rule the percentage field follows — which includes
    // one placing contracts for a live delivery only, where everything in a
    // payout is paid for that and the server refuses goods set apart for it
    // (no_bonus). Picks go into the payout itself there.
    var bonusCap = typeof caps.bonusPercent === 'number' ? caps.bonusPercent : null;
    if (placingAliveOnly()) { picked.aliveOnly = false; }
    if ((items.length > 0 || weapons.length > 0) && bonusCap !== 0 && !placingAliveOnly()) {
      var alive = make('input');
      alive.type = 'checkbox'; alive.id = 'slot-alive-' + index;
      alive.checked = picked.aliveOnly === true;
      alive.onclick = function () { picked.aliveOnly = alive.checked; };
      var aliveToggle = document.createElement('label');
      aliveToggle.className = 'toggle';
      aliveToggle.htmlFor = alive.id;
      aliveToggle.appendChild(alive);
      aliveToggle.appendChild(el('span', null, t('app.only_if_delivered_alive')));
      wrap.appendChild(aliveToggle);
    }

    if (items.length === 0 && weapons.length === 0) {
      wrap.appendChild(el('div', 'hint', goodsAbsenceReason(wallet, caps)));
    } else if (caps.itemsEnabled === false || caps.weaponsEnabled === false) {
      // One of the two switched off while the other is offered: the
      // missing picker read as an app that failed to read the pockets.
      wrap.appendChild(el('div', 'hint', caps.itemsEnabled === false
        ? t('app.this_server_does_not_take_items')
        : t('app.this_server_does_not_take_weapons')));
    }
    return wrap;
  }

  /* Why there is nothing to pick. Never silence: a player who cannot see an
     option assumes it does not exist. */
  function goodsAbsenceReason(wallet, caps) {
    if (wallet.inventoryRead === false) {
      return t('app.your_inventory_could_not_be_read')
        + t('app.offered_right_now_money_still_works');
    }
    if (caps.itemsEnabled === false && caps.weaponsEnabled === false) {
      return t('app.this_server_does_not_take_items_2');
    }
    if (caps.itemsEnabled === false) {
      return t('app.this_server_does_not_take_items_3')
        + t('app.carrying_a_weapon_that_can_be');
    }
    if (caps.weaponsEnabled === false) {
      return t('app.this_server_does_not_take_weapons_2')
        + t('app.carrying_anything_else_that_can_be');
    }
    // Only the money this server takes, and none where it takes none.
    var taken = moneyTaken();
    if (taken === 'money') {
      return t('app.you_are_not_carrying_anything_that');
    }
    return t('app.you_are_not_carrying_anything_that_2')
      + taken.charAt(0).toUpperCase() + taken.slice(1) + t('app.above_still')
      + (taken.indexOf(' and ') === -1 ? 'works.' : 'work.');
  }

  var SOURCE_LABELS = { cash: t('app.cash'), bank: t('app.bank'), dirty: t('app.dirty_money_3') };

  /* A readable name for something that is no longer in the player's pockets.

     The wallet carries proper labels, but only for what they are carrying
     right now — and everything in escrow is, by definition, not. So the
     wallet is asked first and the raw name is tidied when it cannot answer:
     WEAPON_PISTOL reads as "Pistol", black_money as "Black money". */
  function itemLabel(name) {
    if (!name) { return t('app.something'); }

    var wallet = state.wallet;
    if (wallet) {
      var found = labelOf(asList(wallet.items), name);
      if (found !== name) { return found; }
      found = labelOf(asList(wallet.weapons), name);
      if (found !== name) { return found; }
    }

    var text = String(name)
      .replace(/^WEAPON_/i, '')
      .replace(/[_\-]+/g, ' ')
      .toLowerCase().trim();
    if (!text) { return String(name); }
    return text.charAt(0).toUpperCase() + text.slice(1);
  }

  function labelOf(items, name) {
    for (var i = 0; i < items.length; i++) {
      if (items[i].name === name) { return items[i].label; }
    }
    return name;
  }

  function removable(text, onRemove) {
    var button = el('button', 'chip', text + '  \u00d7');
    button.onclick = onRemove;
    return button;
  }

  /* Pick an item, then say how many — and only be asked how many when
     there is a choice to make. Somebody staking their one crowbar should
     not have to confirm that they mean one of it. */
  function itemPicker(index, items) {
    var choose = make('select');
    choose.id = 'slot-item-' + index;

    // How much of each is still unspoken for, so the quantity field can be
    // bounded to it and the row can say so.
    var spare = {};
    // A stack that says whose it is (namesOwner) cannot go on a contract
    // placed anonymously: held back while that is ticked, and said why,
    // rather than the whole contract refused without naming it.
    var naming = {};
    items.forEach(function (item) {
      var free = item.count - allocatedItem(item.name);
      if (free <= 0) { return; }
      spare[item.name] = free;
      var option = document.createElement('option');
      option.value = item.name;
      option.textContent = t('app.item_spare', item.label, free);
      if (item.namesOwner && placingAnonymously()) {
        naming[item.name] = true;
        option.disabled = true;
        option.textContent = item.label + t('app.carries_your_name');
      }
      choose.appendChild(option);
    });
    if (choose.children.length === 0) { return el('div', 'hint', t('app.nothing_spare_left_to_add')); }

    var count = numberInput('slot-item-count-' + index, 1);
    count.min = 1;

    var howMany = labelled(t('app.how_many'), count);
    var field = el('div', 'picker');
    field.appendChild(labelled(t('app.item'), choose));
    field.appendChild(howMany);

    /* Show the quantity field only where the answer could be anything but
       one, and bound it to what is actually spare. */
    function follow() {
      var free = spare[choose.value] || 1;
      count.max = free;
      if (free <= 1) {
        howMany.hidden = true;
        count.value = '1';
      } else {
        howMany.hidden = false;
        if (parseInt(count.value, 10) > free) { count.value = String(free); }
      }
    }
    choose.onchange = follow;
    follow();

    var add = el('button', 'ghost ico i-plus', t('app.add_this_item'));
    add.id = 'slot-item-add-' + index;
    add.onclick = function () {
      var name = choose.value;
      var free = spare[name] || 0;
      // With the field hidden there is only one sensible answer, and
      // reading a control the player never saw is how a hidden default
      // becomes a silent refusal.
      var wanted = (free <= 1) ? 1 : (parseInt(count.value, 10) || 0);
      if (!name || wanted <= 0) { return say(t('app.choose_an_item_and_how_many')); }
      if (naming[name]) {
        return say(labelOf(items, name) + t('app.carries_your_name_or_number_so')
          + t('app.on_a_contract_placed_anonymously'));
      }

      var caps = state.wallet.caps || {};
      // The half the pick goes into. The server bounds each half on its
      // own, so the limits below are counted the same way.
      var picked = pickedFor(index);
      if (picked.aliveOnly) { picked = picked.alive; }
      var held = 0;
      items.forEach(function (item) { if (item.name === name) { held = item.count; } });

      if (allocatedItem(name) + wanted > held) {
        return say(t('app.you_only_have') + (held - allocatedItem(name)) + t('app.of_those_spare'));
      }
      if ((picked.items[name] || 0) + wanted > (caps.maxPerStack || Infinity)) {
        return say(t('app.that_is_more_than') + (slotCeiling() > 1 ? t('app.one_payout') : t('app.the_reward'))
          + t('app.can_hold_of_a_single_item'));
      }
      if (picked.items[name] === undefined
          && Object.keys(picked.items).length >= (caps.maxStacks || Infinity)) {
        return say((slotCeiling() > 1 ? t('app.this_payout') : t('app.the_reward_2'))
          + t('app.is_already_carrying_as_many_kinds'));
      }

      picked.items[name] = (picked.items[name] || 0) + wanted;
      renderSlots();
    };

    field.appendChild(add);
    return field;
  }

  function weaponPicker(index, weapons) {
    var choose = make('select');
    choose.id = 'slot-weapon-' + index;
    weapons.forEach(function (weapon) {
      if (weaponTaken(weapon.slot)) { return; }
      var option = document.createElement('option');
      option.value = String(weapon.slot);
      option.textContent = weapon.label + (weapon.serial ? '  #' + weapon.serial : '');
      choose.appendChild(option);
    });
    if (choose.children.length === 0) { return el('div', 'hint', t('app.no_weapons_left_to_add')); }

    var add = el('button', 'ghost ico i-plus', t('app.add_this_weapon'));
    add.id = 'slot-weapon-add-' + index;
    add.onclick = function () {
      var slotNumber = parseInt(choose.value, 10);
      if (!slotNumber && slotNumber !== 0) { return say(t('app.choose_a_weapon')); }

      var caps = state.wallet.caps || {};
      var picked = pickedFor(index);
      if (picked.aliveOnly) { picked = picked.alive; }
      if (Object.keys(picked.weapons).length >= (caps.maxWeapons || Infinity)) {
        return say((slotCeiling() > 1 ? t('app.this_payout') : t('app.the_reward_2'))
          + t('app.is_already_carrying_as_many_weapons'));
      }

      var found = null;
      weapons.forEach(function (weapon) { if (weapon.slot === slotNumber) { found = weapon; } });
      if (!found) { return say(t('app.that_weapon_is_no_longer_in')); }

      // Keyed by inventory slot, not by name: two of the same weapon are two
      // different objects, and escrowing one twice would take one and then
      // fail looking for its twin.
      picked.weapons[slotNumber] = found;
      renderSlots();
    };

    var field = el('div', 'picker');
    field.appendChild(labelled(t('app.weapon'), choose));
    field.appendChild(add);
    return field;
  }

  // Whether any payout has goods staged on it, as opposed to money only.
  function stagedAnything() {
    return Object.keys(state.picked).some(function (index) {
      return stagedHalves(state.picked[index]).some(function (half) {
        return Object.keys(half.items).length > 0
          || Object.keys(half.weapons).length > 0;
      });
    });
  }

  // The chosen goods for one payout, in the shape the server validates:
  // the kill's half, and under `alive` the half paid only for a delivery.
  function goodsOf(index) {
    var picked = state.picked[index];
    function shaped(half) {
      if (!half) { return { items: [], weapons: [] }; }
      return {
        items: Object.keys(half.items).map(function (name) {
          return { name: name, count: half.items[name] };
        }),
        weapons: Object.keys(half.weapons).map(function (slotNumber) {
          return { name: half.weapons[slotNumber].name, slot: parseInt(slotNumber, 10) };
        })
      };
    }
    var goods = shaped(picked);
    goods.alive = shaped(picked && picked.alive);
    return goods;
  }

  // The preset the picker is showing, as the one-based index the server
  // indexes its own list by. Null off a preset server.
  function reasonPresetIndex() {
    if (settings().reasonMode !== 'preset') { return null; }
    return parseInt(state.draft.reasonPreset, 10) || 1;
  }

  /* The payouts on the form, in the shape the server takes them, read from
     the draft. One reading for the submit and for the total shown above it,
     so the two cannot describe different contracts.

     Only sources the creator actually funded are sent. A zero is not a
     reward, and a contract offering one is rejected server-side — which is
     why sending all three keys unconditionally made every contract creation
     fail. An amount num() cannot read is left out here; the submit refuses
     it by name before it gets this far. */
  function draftSlots() {
    var slots = [];
    for (var i = 1; i <= payoutCount(); i++) {
      var baseline = {};
      ['cash', 'bank', 'dirty'].forEach(function (src) {
        var amount = num('slot-' + src + '-' + i);
        if (amount) { baseline[src] = amount; }
      });

      var goods = goodsOf(i);
      if (goods.items.length) baseline.items = goods.items;
      if (goods.weapons.length) baseline.weapons = goods.weapons;

      var slot = { baseline: baseline };
      if (goods.alive.items.length || goods.alive.weapons.length) {
        slot.bonus = {};
        if (goods.alive.items.length) slot.bonus.items = goods.alive.items;
        if (goods.alive.weapons.length) slot.bonus.weapons = goods.alive.weapons;
      }
      slots.push(slot);
    }
    return slots;
  }

  /* What a set of payouts takes from the creator, and how many separate
     rewards the server will count in it.

     The kidnapping bonus is escrowed now, on top of each payout, as one
     more reward per funded money source. Left out of every sum here, a
     creator holding exactly what they entered was refused for funds they
     had, and a form just under the reward limit was refused over it. The
     server derives it the same way — multiply, then floor — beside goods
     marked alive only, which are a bonus of their own and not a reason to
     drop the percentage. */
  function composeTotals(slots, bonusPct) {
    var out = { lines: 0, totals: { cash: 0, bank: 0, dirty: 0 },
                bonus: { cash: 0, bank: 0, dirty: 0 } };
    slots.forEach(function (slot) {
      var b = slot.baseline;
      ['cash', 'bank', 'dirty'].forEach(function (src) {
        if (!b[src]) { return; }
        out.lines++;
        out.totals[src] += b[src];
        var extra = Math.floor(b[src] * bonusPct / 100);
        if (extra > 0) { out.lines++; out.totals[src] += extra; out.bonus[src] += extra; }
      });
      [b, slot.bonus || {}].forEach(function (half) {
        out.lines += (half.items || []).length;
        out.lines += (half.weapons || []).length;
      });
    });
    return out;
  }

  /* "$75,000 cash ($50,000 + $25,000 kidnapping bonus) and Lockpick x2",
     or null when nothing is in the reward yet. The goods are named from
     what is staged, across every payout. */
  function takenText(composed) {
    var parts = [];
    var words = { cash: 'cash', bank: 'bank', dirty: t('app.dirty_money') };
    ['cash', 'bank', 'dirty'].forEach(function (src) {
      var all = composed.totals[src];
      if (!all) { return; }
      var extra = composed.bonus[src];
      parts.push(money(all) + ' ' + words[src] + (extra
        ? ' (' + money(all - extra) + ' + ' + money(extra) + t('app.kidnapping_bonus_4') : ''));
    });

    // One entry per item and half, summed over the payouts; each weapon on
    // its own, since two of one model are two objects.
    var goods = [], byKey = {};
    for (var i = 1; i <= payoutCount(); i++) {
      var picked = state.picked[i];
      if (!picked) { continue; }
      stagedHalves(picked).forEach(function (half) {
        var tail = (half === picked) ? '' : t('app.alive_only_3');
        Object.keys(half.items).forEach(function (name) {
          var key = name + tail;
          if (!byKey[key]) {
            byKey[key] = { label: itemLabel(name), tail: tail, count: 0 };
            goods.push(byKey[key]);
          }
          byKey[key].count += half.items[name];
        });
        Object.keys(half.weapons).forEach(function (slotNumber) {
          goods.push({ label: half.weapons[slotNumber].label, tail: tail, count: 1 });
        });
      });
    }
    goods.forEach(function (g) {
      parts.push(g.label + (g.count > 1 ? ' x' + g.count : '') + g.tail);
    });

    if (!parts.length) { return null; }
    return parts.length === 1 ? parts[0]
      : t('app.list_and', parts.slice(0, -1).join(', '), parts[parts.length - 1]);
  }

  /* What placing the form would take, rewritten above the Place button on
     every edit. Nothing on the form added it up: the kidnapping bonus opens
     at 50% and is escrowed with the rest, so $40,000 typed into Cash took
     $60,000, and the only place that figure appeared was a refusal for not
     having it. A no-op off the Place form. */
  function showPlaceTotal() {
    var node = document.getElementById('place-total');
    if (!node) { return; }
    var composed = composeTotals(draftSlots(), bonusPercent());
    var taken = takenText(composed);
    if (!taken) { node.textContent = t('app.nothing_in_the_reward_yet'); return; }

    var text = t('app.taken_from_you_now') + taken + '.';
    // The fee is charged, not held, so it is said apart from the escrow.
    var fee = state.draft.anon === true ? anonymityFee('creator') : 0;
    if (fee > 0) {
      text += t('app.plus_from_your_for_anonymity', money(fee),
        (settings().anonymityFees || {}).account === 'cash' ? 'cash' : 'bank');
    }
    var bonus = composed.bonus.cash + composed.bonus.bank + composed.bonus.dirty;
    if (bonus > 0 || taken.indexOf(t('app.alive_only_3')) !== -1) {
      text += t('app.the_bonus_comes_back_to_you');
    }
    node.textContent = text;
  }

  /* The confirmation, saying what was held and the terms the server
     settled on. It said only "Contract placed.": the buyout and the stake
     are moved to the nearest amount the reward allows without a word, and
     the deadline was the server's default, which the form never named. */
  function placedText(held, placed, asked) {
    var text = t('app.contract_placed');
    if (held) { text += t('app.held_from_you') + held + '.'; }

    var terms = [];
    var moved = [];
    if (typeof placed.bailoutAmount === 'number' && placed.bailoutAmount > 0) {
      terms.push(t('app.buyout_amount', money(placed.bailoutAmount)));
      if (asked.bailout > 0 && asked.bailout !== placed.bailoutAmount) { moved.push('buyout'); }
    }
    if (typeof placed.penaltyAmount === 'number' && placed.penaltyAmount > 0) {
      // Whose it is, said: "stake $1,000" beside the buyout read as a
      // second sum taken from the client.
      terms.push(t('app.hitmans_stake') + money(placed.penaltyAmount) + t('app.they_put_it_up_not_you'));
      if (asked.penalty > 0 && asked.penalty !== placed.penaltyAmount) { moved.push('stake'); }
    }
    if (terms.length) { text += ' ' + terms.join('; ') + '.'; }
    if (moved.length) {
      text += tn('app.the_terms_were_moved', moved.length, moved.join(t('app.and_the')));
    }
    // A stake asked for and none placed: the reward cannot carry one.
    if (asked.penalty > 0 && placed.penaltyAmount === 0) {
      text += t('app.no_stake_was_set_this_reward');
    }

    // What anonymity cost, as the server took it (the reply's `charged`).
    var charged = placed.charged || {};
    if (Number(charged.fee) > 0) {
      text += t('app.placing_it_anonymously_cost') + money(Number(charged.fee)) + t('app.from_your')
        + (charged.account === 'cash' ? 'cash' : 'bank') + '.';
    }

    // How it is completed, where that is not what the form said.
    if (typeof placed.fulfilment === 'string'
        && (placed.fulfilment !== 'either') !== (asked.aliveOnly === true)) {
      text += placed.fulfilment === 'either'
        ? t('app.a_kill_completes_it_as_well_2')
        : t('app.it_only_pays_when_the_target_2');
    }

    var band = bandOf(placed);
    var minutes = Number(settings().defaultDeadlineMinutes) || 0;
    if (band || minutes > 0) {
      text += t('app.it_has_2') + (band ? band.text.toLowerCase() : t('app.duration_left', durationText(minutes)))
        + t('app.unless_you_extend_it_its_clock')
        + t('app.operative_on_it_are_all_in');
    }
    // Contract decay (Config.Improvements.ContractDecay): told as it is placed.
    var decay = settings().contractDecay;
    if (decay && typeof decay === 'object') {
      text += decay.mode === 'shorten'
        ? t('app.decay_shorten_h', decay.percent, decay.hours)
        : t('app.decay_rise_h', decay.percent, decay.hours, decay.maxPercent,
          decay.account === 'cash' ? 'cash' : 'bank');
      if (decay.mode !== 'shorten' && asked.anonymous === true) {
        text += t('app.not_this_one_a_contract_placed');
      } else {
        text += t('app.you_can_stop_that_from_its');
      }
    }
    return text;
  }

  /* The Place button, armed or not, repainted where it is: a whole form
     redrawn under a player's thumb to change one label is a form that can
     lose what they were typing. */
  var placeSubmit = null;
  function paintPlaceSubmit() {
    if (!placeSubmit || !placeSubmit.parentNode || isBusy('create')) { return; }
    var armed = state.placeArmed;
    placeSubmit.textContent = armed ? armed.label : t('app.place_contract');
    placeSubmit.className = 'btn ' + (armed ? 'danger' : 'primary');
  }

  function submitContract() {
    // From the draft, not the DOM: the sworn-officer confirmation renders a
    // dialog over the form, which empties #view. Reading the controls here
    // meant the first submit always failed and the second submitted nothing.
    var target = state.draft.target || document.getElementById('target-handle').value;
    if (!target) return say(t('app.choose_a_target'));
    // A server that takes free text refuses an empty reason. Said here, by
    // the field, rather than after a round trip as "Check what you
    // entered." on a form full of money fields. Where the server said so:
    // one that did not is answered by its own refusal.
    var reasonBox = document.getElementById('reason');
    if (settings().reasonMode === 'freetext'
        && !String(state.draft.reason || (reasonBox && reasonBox.value) || '').trim()) {
      return say(reasonRefusedText({ rule: 'empty' }));
    }

    var count = payoutCount();
    var moneyFields = ['bonus', 'bailout', 'penalty'];
    for (var k = 1; k <= count; k++) {
      moneyFields.push('slot-cash-' + k, 'slot-bank-' + k, 'slot-dirty-' + k);
    }
    if (badAmounts(moneyFields)) {
      return say(t('app.amounts_are_whole_dollars_written_out'));
    }
    var caps = (state.wallet && state.wallet.caps) || {};
    var labels = { cash: t('app.cash'), bank: t('app.bank'), dirty: t('app.dirty_money_3') };

    var slots = draftSlots();
    // Named by number only where there can be more than one payout.
    var numbered = slotCeiling() > 1;
    for (var i = 1; i <= slots.length; i++) {
      var baseline = slots[i - 1].baseline;
      // Held to the server's ceiling here, where the field can be named:
      // over it, the server refused the whole contract as not adding up.
      for (var src in labels) {
        var cap = Number(caps[src]);
        if (baseline[src] && cap > 0 && baseline[src] > cap) {
          return say((numbered ? t('app.payout_n_prefix', i) : '') + labels[src] + t('app.is_at_most')
            + money(cap) + t('app.on_this_server'));
        }
      }

      // A payout has to pay something for a kill. Goods marked alive only
      // do not: the server refuses a payout whose kill half is empty.
      if (!baseline.cash && !baseline.bank && !baseline.dirty
          && !baseline.items && !baseline.weapons) {
        var which = numbered ? t('app.payout_n', i) : t('app.the_reward_2');
        return say(slots[i - 1].bonus
          ? which + t('app.pays_nothing_for_a_kill_put')
            + t('app.that_is_not_marked_alive_only')
          : numbered ? which + t('app.has_no_reward_in_it') : t('app.there_is_no_reward_in_it'));
      }
    }

    /* How many separate rewards this contract would carry.
     *
     * One per funded money source per payout, one per item stack, one per
     * weapon. The server bounds the total across the whole contract with
     * Config.Limits.MaxEscrowLines and refuses anything over it as
     * invalid_reward — which this page reads out as "That reward does not
     * add up", blaming amounts that are perfectly fine.
     *
     * The ceiling was computed and sent as caps.maxLines and never read,
     * exactly the way caps.bonusPercent was. And it is reachable without
     * doing anything strange: the shipped caps allow five payouts of three
     * money sources, ten item stacks and three weapons, which is eighty
     * lines against a ceiling of sixty. */
    var bonusPct = bonusPercent();
    var composed = composeTotals(slots, bonusPct);
    var lines = composed.lines;
    var totals = composed.totals;

    // Every payout drawn from one balance, bonus included, against what the
    // player holds: each payout passing on its own is not the contract
    // passing.
    //
    // The anonymity fee too, which the server takes from the same pockets
    // before the escrow. Left out, this check passed a form the server then
    // refused, and the player was told only "You do not have that."
    var need = { cash: totals.cash, bank: totals.bank, dirty: totals.dirty };
    var creatorFee = state.draft.anon === true ? anonymityFee('creator') : 0;
    var creatorFeeAccount = (settings().anonymityFees || {}).account === 'cash' ? 'cash' : 'bank';
    need[creatorFeeAccount] += creatorFee;
    var wallet = state.wallet || {};
    for (var held in labels) {
      var have = Number(wallet[held]);
      if (need[held] > 0 && isFinite(have) && need[held] > have) {
        return say(labels[held] + (numbered ? t('app.across_every_payout_2') : t('app.in_the_reward_2'))
          + (bonusPct > 0 ? t('app.with_the') + bonusPct + t('app.kidnapping_bonus_taken_now_on_top') : '')
          + (creatorFee > 0 && held === creatorFeeAccount
            ? t('app.plus_the') + money(creatorFee) + t('app.anonymity_fee') : '')
          + t('app.comes_to') + money(need[held]) + t('app.you_hold_2') + money(have) + '.');
      }
    }

    var worth = totals.cash + totals.bank + totals.dirty;
    var maxValue = Number(caps.maxValue) || 0;
    if (maxValue > 0 && worth > maxValue) {
      return say(t('app.this_contract_would_be_worth') + money(worth)
        + (bonusPct > 0 ? t('app.with_its_kidnapping_bonus') : '')
        + t('app.this_server_allows_at_most_2') + money(maxValue) + '.');
    }
    // And the least, counted the same way: refused by the server as
    // reward_too_small, it is said here first with both figures.
    var minValue = Number(caps.minValue) || 0;
    if (minValue > 0 && worth < minValue) {
      return say(t('app.this_contract_would_be_worth') + money(worth) + t('app.in_money_2')
        + (bonusPct > 0 ? t('app.with_its_kidnapping_bonus') : '') + '. '
        + minRewardText(minValue));
    }

    // A buyout is priced as a multiple of the clean money in the reward.
    if (num('bailout') > 0 && totals.cash + totals.bank === 0) {
      return say(ERRORS.buyout_needs_clean);
    }
    // And a stake is held to a share of the same clean money, so on a
    // reward with none it can only be nothing: the server placed it with
    // none, and the confirmation did not say so.
    if (num('penalty') > 0 && totals.cash + totals.bank === 0) {
      return say(t('app.a_hitmans_stake_is_held_against')
        + t('app.and_this_one_has_none_so')
        + t('app.the_stake_to_0'));
    }
    // Something staged that says whose it is, on a contract placed
    // anonymously: the server refuses the whole contract for it.
    var named = placingAnonymously() ? stagedNamingOwner() : null;
    if (named) {
      return say(itemLabel(named) + t('app.carries_your_name_or_number_and')
        + t('app.be_handed_it_as_it_is')
        + t('app.contract_under_your_name'));
    }
    var maxLines = (state.wallet && state.wallet.caps && state.wallet.caps.maxLines) || Infinity;
    if (lines > maxLines) {
      return say(t('app.this_contract_holds') + lines + t('app.separate_rewards_and_this')
        + t('app.server_takes_at_most') + maxLines + '. ' + (numbered
          ? t('app.use_fewer_payouts_or_take_some')
          : t('app.take_some_of_the_items_and')));
    }

    // Asked, every time: with a bulletin on it stated a fact under a Yes
    // button and never asked the question. "Every officer in the city", not
    // "on duty": the bulletin goes to every officer whose job receives it,
    // on duty or off, and the narrower words told the creator fewer would
    // hear than do.
    var protectedTarget = state.draft.targetProtected === true;
    if (protectedTarget && settings().warnCreator !== false && !state.leoConfirmed) {
      ask(t('app.that_target') + protectedWords(state.draft.targetProtectedAs).is + '.',
          (advised('posted')
            ? t('app.placing_this_will_alert_every_officer')
            : advised('accepted')
              ? t('app.every_officer_in_the_city_will')
              : '')
            + (placedNamed() ? t('app.placed_under_your_name_notice') + ' ' : '')
            + t('app.place_a_contract_on_them_anyway'),
          function () { state.leoConfirmed = true; submitContract(); },
          { yes: t('app.place_it'), no: t('app.cancel') });
      return;
    }
    // Two taps, the second naming the total it takes, kidnapping bonus and
    // anonymity fee included. Where the officer warning was just agreed to,
    // that dialog's Place it was the second tap.
    var totalTaken = worth + creatorFee;
    var armKey = JSON.stringify([target, slots, bonusPct, creatorFee, num('bailout'),
      num('penalty'), state.draft.mode || 'exclusive', state.draft.anon === true, state.draft.toOrg === true,
      state.draft.toOrgId || null]);
    if (!(protectedTarget && state.leoConfirmed === true)
        && !(state.placeArmed && state.placeArmed.key === armKey)) {
      var armedAt = Date.now();
      state.placeArmed = { key: armKey, at: armedAt,
        label: (placedNamed() ? t('app.tap_again_to_place_under_your_name') : t('app.tap_again_to_place'))
          + (totalTaken > 0 ? ' \u2014 ' + money(totalTaken) : '') };
      setTimeout(function () {
        if (state.placeArmed && state.placeArmed.at === armedAt) {
          state.placeArmed = null;
          paintPlaceSubmit();
        }
      }, PICK_CONFIRM_MS);
      return paintPlaceSubmit();
    }
    state.placeArmed = null;

    // Agreed to (or never asked, where the server warns nobody): sent with
    // the contract, and a target who took a protected job after being
    // picked is refused until the warning has been seen.
    var protectedAck = protectedTarget && state.leoConfirmed === true;
    state.leoConfirmed = false;

    // Kept for the confirmation: the draft is cleared once it is placed.
    var held = takenText(composed);
    var asked = { bailout: num('bailout'), penalty: num('penalty'),
                  aliveOnly: placingAliveOnly(), anonymous: state.draft.anon === true };

    // Guarded here rather than at the top of the function: everything above
    // is client-side validation that answers instantly, and locking the
    // button for those would leave a player unable to fix the thing they
    // were just told to fix.
    once('create', function () {
    return post('create', {
      target: target,
      reason: state.draft.reason || '',
      // Only on a server that runs on presets. Elsewhere it is not a field
      // the server reads, and sending one would be a number nobody chose.
      reasonPreset: reasonPresetIndex(),
      mode: state.draft.mode || 'exclusive',
      reward: { slots: slots },
      bonusPercent: bonusPercent(),
      bailoutAmount: num('bailout'),
      penaltyAmount: num('penalty'),
      anonymous: state.draft.anon === true,
      // What this form showed, sent back so the server charges and places
      // nothing it did not: the anonymity fee and its account, how the
      // contract is completed, and whether the protected-job warning was
      // agreed to. Refused, not charged, where one has moved since.
      shown: {
        creatorFee: anonymityFee('creator'),
        feeAccount: anonymityAccount(),
        fulfilment: placingRule(),
        protectedAck: protectedAck
      },
      // Sent to the hitman organisation, only where it was ticked and the
      // server offers it (left out of the request otherwise).
      toOrg: state.draft.toOrg === true && settings().orgContracts ? (state.draft.toOrgId || true) : undefined
    }).then(function (r) {
      if (!r.ok) {
        /* A fee or the rule changed from the admin panel while the form was
           open. Nothing was taken. Said, and the settings read again, which
           redraws the form with the new figure before it is placed again. */
        if (r.err === 'terms_changed' || r.err === 'rule_changed') {
          fail(r);
          if (r.err === 'rule_changed') { state.wallet = null; state.walletFailed = null; }
          refresh({ board: true });
          return render();
        }
        /* They took a protected job after being picked: the warning the
           form never showed is shown now, and the list is read again so it
           marks them. */
        if (r.err === 'target_now_protected') {
          state.draft.targetProtected = true;
          state.draft.targetProtectedAs = r.data && r.data.category;
          state.browse.data = null;
          state.browse.pending = null;
          state.browse.refusal = null;
          fail(r);
          // Asked at once where this page knows the server warns. Where it
          // read otherwise its settings are stale: read again, and asked on
          // the next tap, rather than sent again unasked.
          if (settings().warnCreator !== false) { return submitContract(); }
          refresh({ board: true });
          return render();
        }
        // The item the server found naming its owner, by name.
        if (r.err === 'item_names_owner' && r.data && r.data.item) {
          return say(itemLabel(r.data.item) + t('app.carries_your_name_or_number_and_2')
            + t('app.would_be_handed_it_as_it')
            + t('app.place_the_contract_under_your_name'));
        }
        // The wallet is read once when the tab opens, so a staged weapon's
        // inventory slot can be stale by the time it is submitted. The
        // server refuses rather than substituting a different one — right,
        // but "you do not have that" is unhelpful while the form still
        // shows the thing. Re-read and drop what is no longer there.
        if (r.err === 'insufficient_funds' && stagedAnything()) {
          state.wallet = null;
          state.walletFailed = null;
          state.picked = {};
          say(t('app.your_pockets_have_changed_since_you')
            + t('app.pick_the_items_and_weapons_again'));
          return render();
        }
        /* The person picked is no longer one the server can name: they left
           the city, or the pick came from a list read long enough ago that
           its handles have lapsed. This read "Check what you entered." on a
           form with nothing wrong in it, and picking them again from the
           same list sent the same dead handle — the list is kept and never
           re-read — so it failed the same way for as long as the player
           kept trying. The pick is dropped and the list asked for again. */
        if (r.err === 'not_found') {
          delete state.draft.target;
          delete state.draft.targetName;
          delete state.draft.targetProtected;
          delete state.draft.targetProtectedAs;
          state.browse.data = null;
          state.browse.pending = null;
          state.browse.refusal = null;
          say(t('app.that_person_cannot_be_picked_any')
            + t('app.the_city_the_list_has_been'));
          return render();
        }
        // Nothing staged, so it is the money: the balances this form checked
        // against were read when it opened. Read again, and said so.
        if (r.err === 'insufficient_funds') {
          state.wallet = null;
          state.walletFailed = null;
          say(t('app.the_server_could_not_take_that')
            + t('app.may_have_changed_since_you_opened')
            + t('app.again_check_the_amounts'));
          return render();
        }
        /* The reward rules moved under the form: a source switched off or
           fewer payouts taken, from the admin panel while it was open. It
           said "That reward does not add up." and kept offering the same
           thing. What can be put up is read again (and anything staged
           dropped, since it was picked under the old rules) before it is
           said; the server names the source or the ceiling where it knows. */
        if (r.err === 'invalid_reward' || r.err === 'source_disabled'
            || r.err === 'slots_over') {
          state.wallet = null;
          state.walletFailed = null;
          if (stagedAnything()) { state.picked = {}; }
          render();
          return say(r.err === 'invalid_reward'
            ? t('app.that_reward_does_not_fit_this')
              + t('app.since_you_opened_this_form_so')
            : failText(r) + t('app.the_form_has_been_read_again'));
        }
        // The limit is on contracts placed, counted across the account's
        // characters. "You are holding too many contracts" was said to a
        // client holding none.
        if (r.err === 'limit_reached') {
          var most = Number(r.data && r.data.max);
          return say(t('app.you_already_have')
            + (most > 0 ? tn('app.contracts_out_the_most_allowed', most) : t('app.as_many_contracts_out_as_this'))
            + t('app.counting_the_ones_placed_from_your')
            + t('app.wait_for_one_to_close_or')
            + t('app.under_mine'));
        }
        return fail(r);
      }
      // What was held, at the percentage the server placed rather than the
      // one sent: it places none where contracts pay only for a live
      // delivery, and the confirmation said a bonus had been taken that
      // never was.
      var placed = r.data || {};
      if (typeof placed.bonusPercent === 'number' && placed.bonusPercent !== bonusPct) {
        held = takenText(composeTotals(slots, placed.bonusPercent));
      }
      say(placedText(held, placed, asked), 'ok');
      // The goods are gone from the player's pockets now; leaving them
      // staged would offer them again on the next contract.
      state.picked = {};
      state.draft = {};
      state.wallet = null;
      state.walletFailed = null;
      state.tab = 'mine';
      refresh();
    });
    });
  }

  /* The kidnapping bonus as the server will take it: never over the
     ceiling it sent, which it clamps to. Totalled and checked at the figure
     typed, a creator who could cover the ceiling was refused for the rest,
     and one who could cover it all was shown more than they got. */
  function bonusPercent() {
    // None where contracts are placed for a live delivery only, as the
    // server places them: the field is not drawn, and a figure left in the
    // draft from before is not one anybody can see.
    if (placingAliveOnly()) { return 0; }
    var typed = num('bonus') || 0;
    var caps = state.wallet && state.wallet.caps;
    var cap = caps && typeof caps.bonusPercent === 'number' ? caps.bonusPercent : null;
    return cap !== null && typed > cap ? cap : typed;
  }

  // From the draft, so a value survives the form being rebuilt under it.
  function num(id) {
    var raw = state.draft[id];
    if (raw === undefined) {
      var node = document.getElementById(id);
      raw = node && node.value;
    }
    // Number, not parseInt: "1e5" read as 1 and a $100,000 reward was
    // placed as $1 with no warning. Anything that is not a whole, finite,
    // non-negative amount is refused by the caller (badAmounts).
    var value = Number(raw);
    if (raw === undefined || raw === null || String(raw).trim() === '') { return 0; }
    if (!isFinite(value) || value < 0 || Math.floor(value) !== value) { return NaN; }
    return value;
  }

  /* The first money field whose entry num() could not read as whole dollars. */
  function badAmounts(ids) {
    for (var i = 0; i < ids.length; i++) {
      if (isNaN(num(ids[i]))) { return ids[i]; }
    }
    return null;
  }

  // An input whose value is the draft's, and whose edits go back into it.
  // Every field built this way is on the Place form, so each edit also
  // brings the total above the Place button up to date.
  function drafted(input, key, fallback) {
    input.value = state.draft[key] !== undefined ? state.draft[key] : (fallback || '');
    input.oninput = function () { state.draft[key] = input.value; showPlaceTotal(); };
    input.onchange = function () { state.draft[key] = input.value; showPlaceTotal(); };
    return input;
  }

  /* A protected target's kind of job, in words: the projection's
     targetProtectedAs and the picker's protectedAs ('law', 'emergency',
     'legal', 'other'). Every protected target was "a sworn officer" of "law
     enforcement", the medic and the lawyer too. A server that sends no kind
     protected law enforcement only. */
  var PROTECTED_WORDS = {
    law: { chip: t('app.law_enforcement'), tag: t('app.law'), is: t('app.is_a_sworn_officer'),
           noun: t('app.a_sworn_officer') },
    emergency: { chip: t('app.emergency_services'), tag: 'EMS', is: t('app.works_in_emergency_services'),
                 noun: t('app.someone_in_emergency_services') },
    legal: { chip: t('app.legal'), tag: t('app.legal'), is: t('app.works_in_the_legal_system'),
             noun: t('app.someone_in_the_legal_system') },
    other: { chip: t('app.protected_job'), tag: t('app.protected'), is: t('app.works_in_a_protected_job'),
             noun: t('app.someone_in_a_protected_job') }
  };

  function protectedWords(kind) {
    if (kind === undefined || kind === null) { return PROTECTED_WORDS.law; }
    return PROTECTED_WORDS[kind] || PROTECTED_WORDS.other;
  }

  /* Whether officers are told at this stage ('posted' or 'accepted'). A
     server that does not say is taken to, which is how it always read. */
  function advised(stage) {
    var a = settings().advisory;
    return !a || a[stage] !== false;
  }

  /* How a contract placed now is completed ('alive' or 'either'), as this
     page has it: the board's settings, or the wallet's caps where the board
     has not said. Undefined where neither has: a server from before the
     rule. Echoed with a placement, so it is placed under the rule shown. */
  function placingRule() {
    var rule = settings().fulfilment;
    if (rule === undefined || rule === null) {
      var caps = state.wallet && state.wallet.caps;
      rule = caps && caps.fulfilment;
    }
    return typeof rule === 'string' ? rule : undefined;
  }

  /* Whether a contract pays only for delivering its target alive: a term
     it was placed under, like its reward, sent on every card as
     `fulfilment` ('alive', or 'either' where a kill completes it too).
     Read the way the server reads it (Util.fulfilmentRule): a card without
     one is a contract from before the rule, accepted on the old terms, so
     only 'either' or nothing means a kill can pay. */
  function aliveOnly(contract) {
    var rule = contract && contract.fulfilment;
    return rule !== undefined && rule !== null && rule !== 'either';
  }

  /* The same for a contract placed now, from the server's rule for new
     ones, which comes with the board's settings. A server that does not
     say is one from before the rule, where every contract was 'either'.

     And with the wallet, which the Place form reads every time it opens:
     with the board's read failed, the form went on offering a kidnapping
     bonus on a server that places none, and said it had taken one. */
  function placingAliveOnly() {
    var rule = placingRule();
    return rule !== undefined && rule !== 'either';
  }

  /* What choosing anonymity costs, from the server's settings; 0 where it
     is free or the server did not say. */
  function anonymityFee(role) {
    var fees = settings().anonymityFees;
    var fee = fees && fees[role];
    return typeof fee === 'number' && fee > 0 ? fee : 0;
  }

  // And the account it comes from: the bank, unless the server says cash.
  function anonymityAccount() {
    return (settings().anonymityFees || {}).account === 'cash' ? 'cash' : 'bank';
  }

  // Whether the Place form is set to place anonymously.
  function placingAnonymously() { return state.draft.anon === true; }

  /* The anonymity switches that apply to a target: on one on a whitelisted
     job (the pick's protected mark, a contract's targetProtected), the
     server's Config.TargetClasses.whitelisted, carried as
     settings().anonymity.whitelisted; on anyone else, the general ones. The
     server decides at the tap either way. */
  function anonymityRules(targetProtected) {
    var allowed = settings().anonymity;
    if (!allowed || typeof allowed !== 'object') { return null; }
    if (targetProtected === true) {
      return allowed.whitelisted && typeof allowed.whitelisted === 'object'
        ? allowed.whitelisted : allowed;
    }
    return allowed;
  }

  /* Whether an operative who accepts under their name is shown by it to the
     target too (Config.TargetClasses.default.ShowOperativeNames). A server that does
     not say does not. */
  function namesToTarget(targetProtected) {
    var rules = anonymityRules(targetProtected);
    return !!(rules && rules.namesToTarget === true);
  }

  /* Whether the server offers anonymity for this role ('creator' on placing,
     'hitman' on accepting): Config.TargetClasses.default.AllowAnonymousPlacer and
     AllowAnonymousHitman, as the listing's settings carry them, or their
     whitelisted-target counterparts for a target on a whitelisted job. Off,
     the option is not drawn at all. A server that does not say offers it. */
  /* Whether the contract on the Place form goes out under the placer's
     name with no choice about it: anonymity is not offered for this target.
     Where it is offered, its box says which it is. */
  function placedNamed() {
    return !anonymityOffered('creator', state.draft.targetProtected === true);
  }

  function anonymityOffered(role, targetProtected) {
    var rules = anonymityRules(targetProtected);
    if (!rules) { return true; }
    return rules[role === 'creator' ? 'placer' : 'hitman'] !== false;
  }

  /* The first item staged on any payout whose stack says whose it is (the
     wallet's namesOwner, Escrow.namesOwner on the server), or null. */
  function stagedNamingOwner() {
    var naming = {};
    asList(state.wallet && state.wallet.items).forEach(function (item) {
      if (item && item.namesOwner) { naming[item.name] = true; }
    });
    var found = null;
    Object.keys(state.picked).forEach(function (index) {
      stagedHalves(state.picked[index]).forEach(function (half) {
        Object.keys(half.items).forEach(function (name) {
          if (!found && naming[name]) { found = name; }
        });
      });
    });
    return found;
  }

  function labelled(text, control) {
    var field = el('div', 'field');
    field.appendChild(el('label', null, text));
    field.appendChild(control);
    return field;
  }

  function textInput(id, placeholder, max) {
    var input = make('input');
    input.id = id; input.placeholder = placeholder || '';
    if (max) input.maxLength = max;
    return input;
  }

  function numberInput(id, value) {
    var input = make('input');
    input.type = 'number';
    input.id = id === 'slots' ? 'slots-count' : id;
    input.value = value;
    input.min = 0;
    return input;
  }

  /* Picking who the contract is for.
     
     This used to be a name box and nothing else: type four characters of a
     name you already know, or get nothing at all. Knowing the name is the
     hard part — you can be looking straight at somebody and have no way to
     say who they are.
     
     So the list is the default now. It opens showing who is in the city,
     paged, and the box filters it rather than gating it. */
  function targetSearch() {
    var wrap = el('div', 'target-picker');
    var browse = state.browse;

    var input = textInput('target-query', t('app.filter_by_name_or_just_browse'), 32);
    // Seeded from the filter, not from whoever is currently chosen. The two
    // used to be the same box: a rebuild put the chosen name in it while the
    // remembered filter still narrowed the list, so the box read one thing
    // and the results were another — and with a filter that matched nobody,
    // "Nobody else is in the city right now" on a city full of people, with
    // no way to ask again. Who is chosen is said below the list instead.
    input.value = browse.query || '';

    var handle = make('input');
    handle.type = 'hidden'; handle.id = 'target-handle';
    handle.value = state.draft.target || '';
    handle.dataset.protected = state.draft.targetProtected ? 'true' : 'false';

    var results = el('div', 'target-results');
    var status = el('div', 'hint');
    // Who is chosen, on a line of its own under the list. It was written
    // into `status`, which the list's own count overwrites on every
    // rebuild, so after the wallet landed or a push nothing on the form
    // named the person it would be placed on.
    var chosen = el('div', 'hint');
    function sayChosen() {
      show(chosen, state.draft.targetName
        ? t('app.contract_will_be_placed_on') + state.draft.targetName + '.' : '');
      chosen.hidden = !state.draft.targetName;
    }

    var timer = null;
    var seq = 0;

    /* Which ways of finding somebody this server offers. A button that
       always comes back empty is worse than no button. */
    var canBrowse = settings().allowBrowseAll !== false;
    var canNearby = settings().allowNearby === true;

    // Start on a scope this server will actually answer.
    //
    // The picker opened on 'all' whatever the server allowed, and the row of
    // scope buttons is hidden when it holds only one — so on a server with
    // AllowBrowseAll off and AllowNearby on, it asked for the one scope the
    // server refuses and drew no button to change it. An empty target list
    // on a city full of people, with nothing on screen to explain it and no
    // way out of it. Both settings are documented and supported; only the
    // default pairing had ever been looked at.
    if (browse.scope === 'all' && !canBrowse && canNearby) { browse.scope = 'nearby'; }
    if (browse.scope === 'nearby' && !canNearby && canBrowse) { browse.scope = 'all'; }

    var modes = el('div', 'row target-modes');
    var allButton, nearButton;

    function setScope(next) {
      browse.scope = next; browse.page = 1; browse.data = null; browse.pending = null;
      markScope();
      load();
    }

    function markScope() {
      if (allButton) { allButton.className = 'btn ' + ((browse.scope === 'all') ? 'primary' : 'ghost'); }
      if (nearButton) { nearButton.className = 'btn ' + ((browse.scope === 'nearby') ? 'primary' : 'ghost'); }
    }

    if (canBrowse) {
      allButton = el('button', 'ghost', t('app.everyone'));
      allButton.id = 'target-scope-all';
      allButton.onclick = function () { setScope('all'); };
      modes.appendChild(allButton);
    }
    if (canNearby) {
      // With the radius, because "near me" is not a distance. The server
      // has always sent it and the page never read it, so a player whose
      // target was thirty-one metres away saw an empty list and no reason.
      var radius = settings().nearbyRadius;
      nearButton = el('button', 'ghost',
        radius ? t('app.within_m_short', Math.round(radius)) : t('app.near_me'));
      nearButton.id = 'target-scope-nearby';
      nearButton.onclick = function () { setScope('nearby'); };
      modes.appendChild(nearButton);
    }
    markScope();
    if (modes.children.length > 1) { wrap.appendChild(modes); }

    input.oninput = function () {
      browse.page = 1;
      browse.query = input.value;
      browse.data = null;
      browse.pending = null;
      // Debounced, so typing a name is one lookup rather than one per
      // keystroke against a bucket that refills twice a second.
      if (timer) clearTimeout(timer);
      timer = setTimeout(load, 300);
    };

    /* Ask for a page of people.
       
       Browsing takes any filter length, including none — the list is
       already bounded server-side, so the box narrows it rather than
       unlocking it. Only the older name-only search has a minimum, and it
       is the fallback for a server with browsing switched off. */
    /* What this load is for, so a second build of the same form can tell
       it is already waiting for the answer rather than asking again. */
    function key() {
      return browse.scope + '|' + browse.query + '|' + browse.page;
    }

    /* Draw into whichever picker is currently on screen.
       
       The form is rebuilt whenever anything on it changes, so the picker
       that asked a question is often not the one that has to show the
       answer — the first one is detached by then, and rendering into it
       puts the list nowhere. */
    browse.draw = function (data) {
      renderPeople(asList(data.people), data.total !== undefined ? data : null);
    };

    /* A refusal, drawn the same way: into whichever picker is on screen.
       It was written into the picker that asked, which by then had been
       replaced, so the player saw an empty picker with no words and
       nothing to press. With a way to ask again, because it is not asked
       again on its own: a refusal is usually the rate limit. */
    browse.showRefusal = function (text) {
      results.innerHTML = '';
      show(status, text);
      var again = el('button', 'ghost', t('app.try_again'));
      again.onclick = function () { browse.refusal = null; browse.pending = null; load(); };
      results.appendChild(again);
    };

    function load() {
      // Each rebuild constructs a fresh picker, and without this every one
      // of them fired its own lookup — the same question several times
      // over, against a rate limit that refills twice a second. The
      // in-flight request answers all of them.
      if (browse.pending === key()) { return; }
      browse.pending = key();
      browse.refusal = null;

      var mine = ++seq;
      var query = browse.query;

      // The name search, where nothing else will find anybody: a server
      // with both lists off, or one with only the nearby list while that is
      // closed to this player (they are on a contract). Without the second,
      // a client with one contract running had no way to pick a target for
      // another.
      if (!canBrowse && (!canNearby || browse.nearbyClosed)) {
        var minimum = settings().minQueryLength || 3;
        if (query.length < minimum) {
          browse.pending = null;
          results.innerHTML = '';
          show(status, t('app.type_at_least') + minimum + t('app.letters_of_their_name'));
          return;
        }
        post('searchTargets', { query: query }).then(function (r) {
          browse.pending = null;
          if (mine !== seq) return;
          if (!r.ok) { return refused(r); }
          browse.data = { people: asList(r.data) };
          if (browse.draw) { browse.draw(browse.data); }
        });
        return;
      }

      post('browseTargets', { scope: browse.scope, query: query, page: browse.page })
        .then(function (r) {
          browse.pending = null;
          // A reply from a query the player has already typed past is stale.
          if (mine !== seq) return;
          if (!r.ok) { return refused(r); }
          browse.data = r.data || { people: [] };
          if (browse.scope === 'nearby') { browse.nearbyClosed = browse.data.closed === true; }
          if (browse.draw) { browse.draw(browse.data); }
        });
    }

    function refused(r) {
      browse.data = null;
      browse.refusal = r.err === 'rate_limited'
        ? t('app.looking_too_fast_try_again') + retryIn(r.data && r.data.retryAfter) + '.'
        // Named for the same reason as the wallet failure above: the code
        // is what an admin needs and the player is the one who can see it.
        : t('app.could_not_read_who_is_online') + (r.err || t('app.no_reply')) + ').';
      if (browse.showRefusal) { browse.showRefusal(browse.refusal); }
    }

    function show(node, text) {
      node.textContent = '';
      if (text) { node.textContent = text; }
    }

    function renderPeople(rows, paging) {
      // Normalised here rather than at each call site: one of them reads a
      // reply straight off the wire, where an empty list is an object.
      var people = asList(rows);
      results.innerHTML = '';

      // The server closes the nearby list to anyone on a live contract, and
      // for a while after one ends (a handover ends with all three standing
      // together), so it cannot name the other side of it. Said, rather than
      // reading as an empty street.
      if (browse.scope === 'nearby' && paging && paging.closed) {
        show(status, t('app.nobody_is_listed_near_you_while')
          + t('app.or_for_a_while_after_one')
          + (canBrowse ? t('app.look_under_everyone')
            : t('app.type_at_least') + (settings().minQueryLength || 3) + t('app.letters_of_their_name')));
        return;
      }

      if (people.length === 0) {
        show(status, input.value
          ? t('app.nobody_online_by_that_name')
          : (browse.scope === 'nearby'
              ? t('app.nobody_is_standing_near_you')
              : t('app.nobody_else_is_in_the_city')));
        return;
      }

      if (paging && paging.total) {
        show(status, (browse.scope === 'nearby')
          ? tn('app.people_near_you_count', paging.total)
          : t('app.showing_of_in_the_city', people.length, paging.total));
      } else {
        show(status, tn('app.matches_count', people.length));
      }

      people.forEach(function (person) { results.appendChild(personRow(person)); });

      // Paging, only where there is more than one page.
      if (paging && paging.pages > 1) {
        var nav = el('div', 'row pager');
        var back = el('button', 'ghost ico i-left', t('app.back'));
        back.disabled = paging.page <= 1;
        back.onclick = function () {
          browse.page = paging.page - 1; browse.data = null; browse.pending = null; load();
        };
        var forward = el('button', 'ghost ico ico-end i-right', t('app.more'));
        forward.disabled = paging.page >= paging.pages;
        forward.onclick = function () {
          browse.page = paging.page + 1; browse.data = null; browse.pending = null; load();
        };
        nav.appendChild(back);
        nav.appendChild(el('div', 'page-of',
          t('app.page_of', paging.page, paging.pages)));
        nav.appendChild(forward);
        results.appendChild(nav);
      }
    }

    function personRow(person) {
      var pick = el('button', 'person');
      if (state.draft.target === person.handle) { pick.className = 'btn person is-chosen'; }

      // The same monogram the contract will carry on the board.
      pick.appendChild(portrait(person.name, null));

      var name = el('span', 'person-name', person.name);
      pick.appendChild(name);

      var tags = el('span', 'person-tags');
      if (person.protected) {
        tags.appendChild(el('span', 'chip is-warn ico i-shield', protectedWords(person.protectedAs).tag));
      }
      // A band, never the figure: "under 20m" (app.lua, NEARBY_BAND).
      if (person.metres !== undefined && person.metres !== null) {
        tags.appendChild(el('span', 'chip ico i-pin', t('app.under_m', person.metres)));
      }
      // Played too little to be a target yet (Config.Immunity
      // .MinTargetPlaytimeHours): said on the row and not pickable, rather
      // than refused once the whole form is filled in.
      if (person.tooNew === true) {
        tags.appendChild(el('span', 'chip', t('app.too_new_to_target')));
        pick.disabled = true;
      }
      if (tags.children.length > 0) { pick.appendChild(tags); }

      pick.onclick = function () {
        handle.value = person.handle;
        handle.dataset.protected = person.protected ? 'true' : 'false';
        state.draft.target = person.handle;
        state.draft.targetProtected = person.protected === true;
        state.draft.targetProtectedAs = person.protectedAs;
        state.draft.targetName = person.name;
        // The anonymity rule for this target (a whitelisted job's own).
        if (placeAnonSync) { placeAnonSync(); }
        // The chosen name stays visible rather than the list vanishing, so
        // the player can see who they picked and change their mind.
        renderPeople([person], null);
        sayChosen();
        // And a way back to everyone else. The list collapsed to the one
        // row with nothing under it, so a player who tapped the wrong name
        // had to guess that the already-lit Everyone button would undo it.
        // The list already read is drawn again with this pick still lit:
        // tapping another row replaces it, and nothing is asked twice.
        var change = el('button', 'ghost ico i-swap', t('app.choose_someone_else'));
        change.onclick = function () {
          if (browse.data) { browse.draw(browse.data); } else { setScope(browse.scope); }
        };
        results.appendChild(change);
        if (person.protected) {
          say(t('app.that_person') + protectedWords(person.protectedAs).is + '.'
            + (advised('posted') ? t('app.placing_this_alerts_every_officer_in')
              : advised('accepted') ? t('app.every_officer_in_the_city_is') : ''),
            'caution');
        }
      };
      return pick;
    }

    wrap.appendChild(input);
    wrap.appendChild(handle);
    wrap.appendChild(status);
    wrap.appendChild(results);
    wrap.appendChild(chosen);
    sayChosen();

    // Open on the list rather than on an empty box: seeing who is out there
    // is the whole point. A rebuild of the form redraws what was already
    // fetched rather than asking again.
    // Always: on a server with browsing switched off this is what states
    // the minimum name length, rather than leaving an empty box that looks
    // broken until the player guesses how much to type.
    if (browse.data) {
      browse.draw(browse.data);
    } else if (browse.refusal) {
      browse.showRefusal(browse.refusal);
    } else if (browse.pending === key()) {
      show(status, t('app.looking'));
    } else {
      load();
    }
    return wrap;
  }

  /* ---------- shell ---------- */

  /* A throw in here used to leave the app blank.

     view.innerHTML is emptied on the first line, so anything that threw
     afterwards left the player looking at nothing, with a tab bar that
     still worked and no error anywhere. That is the shape all four of the
     shipped render crashes took. Now the failure is drawn, reported, and
     leaves a way out. */
  /* ---------- reporting to staff ----------

     Report, on a contract card and in a message thread: a short dialog
     with an optional note, and the server puts the report in the staff
     review queue with the contract, the reporter's place on it and, from a
     thread, its last messages. Nobody on the contract is told anything. It
     has an allowance of its own (Config.Cooldowns.report), so a refusal
     says how long to wait. */
  var REPORT_NOTE_MAX = 200;

  function reportToStaff(contract, thread) {
    var fromThread = !!thread || state.tab === 'thread';
    askFields(fromThread ? t('app.report_this_conversation_to_staff') : t('app.report_this_contract_to_staff'),
      (fromThread ? t('app.staff_read_your_note_and_the')
        : t('app.staff_read_your_note_and_look'))
        + t('app.nobody_on_the_contract_is_told'),
      [{ id: 'note', label: t('app.what_happened_optional'), max: REPORT_NOTE_MAX, placeholder: t('app.optional') }],
      function (values) {
        var payload = { id: contract.id };
        if (thread && thread.handle) { payload.thread = thread.handle; }
        var note = String(values.note || '').replace(/^\s+|\s+$/g, '');
        if (note) { payload.note = Array.from(note).slice(0, REPORT_NOTE_MAX).join(''); }
        once('report:' + contract.id, function () {
          return post('report', payload).then(function (r) {
            if (!r.ok) { return fail(r); }
            say(t('app.sent_to_staff_thank_you'), 'ok');
          });
        });
      }, t('app.send_report'));
  }

  /* The quiet Report button: among a card's other tools, or in a thread's
     head beside Mute. */
  function reportButton(contract, thread) {
    var key = 'report:' + contract.id;
    var button = el('button', 'ghost', isBusy(key) ? t('app.sending') : t('app.report'));
    if (isBusy(key)) {
      button.disabled = true;
      return button;
    }
    button.onclick = function () { reportToStaff(contract, thread); };
    return button;
  }

  function render() {
    /* And the keyboard stays up. The screen is redrawn whole, and anything
       that redrew it while the player was typing - a reply landing, their
       own send going out and coming back, a push refreshing the page -
       took the focus out of the message box mid-sentence. It was put back
       after a thread re-read only.

       And then for the message box only. On the Place form and in every
       dialog, a reply landing mid-word — the wallet the form reads as it
       opens, a push — dropped the rest of what was typed, so 5000 typed
       into Cash could be left at 50. Any field is found again by its id,
       with the caret where it was. */
    var typing = typingIn(document.activeElement);
    // The Organisation tab in the bar or not, as the board last said.
    syncOrgTab();
    var drawn = Diag.guard('render:' + state.tab, draw);
    if (drawn !== Diag.FAILED) {
      if (typing) { refocus(typing); }
      return;
    }

    var view = document.getElementById('view');
    if (!view) { return; }
    view.innerHTML = '';
    view.classList.toggle('has-dialog', false);

    var panel = el('div', 'card');
    panel.appendChild(el('p', 'target', t('app.this_screen_could_not_be_drawn')));
    panel.appendChild(el('p', 'reason',
      t('app.the_fault_has_been_sent_to')
      + t('app.and_nothing_has_been_lost')));

    var row = el('div', 'row');
    // The whitelisted-job view has one screen and no board to go back to.
    var whitelisted = state.mode === 'whitelisted';
    var back = el('button', 'primary', whitelisted ? t('app.try_again') : t('app.back_to_the_board'));
    back.onclick = function () {
      navigated();
      state.dialog = null;
      state.tab = whitelisted ? 'jobview' : 'board';
      render();
    };
    row.appendChild(back);

    var look = el('button', 'ghost', t('app.what_went_wrong'));
    look.onclick = Diag.toggle;
    row.appendChild(look);

    panel.appendChild(row);
    view.appendChild(panel);
  }

  function typingIn(node) {
    if (!node || !node.id || !/^(INPUT|TEXTAREA|SELECT)$/.test(node.tagName || '')) {
      return null;
    }
    var was = { id: node.id, value: node.value, start: null, end: null };
    try { was.start = node.selectionStart; was.end = node.selectionEnd; } catch (e) { /* not every input type has a caret */ }
    return was;
  }

  function refocus(was) {
    var box = document.getElementById(was.id);
    if (!box || !box.focus || box === document.activeElement) { return; }
    box.focus();
    // Where it was; at the end if the box now holds something else, as
    // the message box does once a send has cleared it.
    var same = box.value === was.value && typeof was.start === 'number';
    var at = same ? was.start : String(box.value || '').length;
    try { box.setSelectionRange(at, same ? was.end : at); } catch (e) { /* not every input type */ }
  }

  function draw() {
    // Before anything is drawn: a kill photo whose dialog is no longer the
    // one on screen was closed some other way, and that is a Delete.
    letGoOfProof();

    var view = document.getElementById('view');
    view.innerHTML = '';
    countdownBars = {};
    handoverNodes = {};

    // A dialog is drawn alone, as a sheet at the foot of the view; the view
    // carries the seal behind it while one is open.
    view.classList.toggle('has-dialog', !!state.dialog);

    if (state.dialog) {
      if (state.dialog.kind === 'choice') {
        renderChoice(view);
      } else if (state.dialog.kind === 'fields') {
        renderFields(view);
      } else if (state.dialog.kind === 'reward') {
        renderRewardEditor(view);
      } else if (state.dialog.kind === 'sheet') {
        renderSheet(view);
      } else if (state.dialog.kind === 'proof') {
        renderProof(view);
      } else if (state.dialog.kind === 'pick') {
        renderPick(view);
      } else {
        renderDialog(view);
      }
      return;
    }

    // A call placed from here, on every screen but its thread (which has its
    // own Hang up). lb-phone draws no call screen for it, and a contract
    // that closed mid-call took its thread away, and the only Hang up with
    // it: the caller stayed on the line until the other side hung up.
    if (state.call && state.tab !== 'thread') { view.appendChild(callBar()); }

    // What refuses writes right now, said once at the top of every tab it
    // touches, with until when (holdBanner).
    if (state.tab === 'board' || state.tab === 'mine' || state.tab === 'place'
        || state.tab === 'onme') {
      var banner = holdBanner();
      if (banner) { view.appendChild(banner); }
    }
    if (state.tab === 'board') {
      var invite = inviteBanner();
      if (invite) { view.appendChild(invite); }
    }
    var help = screenHelp();
    if (help) { view.appendChild(help); }

    ({
      board: viewBoard, mine: viewMine, place: viewPlace,
      onme: viewOnMe, ledger: viewLedger, thread: viewThread,
      jobview: viewJobView, org: viewOrg
    })[state.tab](view);

    Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (tab) {
      // A thread is opened from Mine and goes back to it, so Mine stays lit
      // while it is open, rather than no tab at all.
      var shown = state.tab === 'thread' ? 'mine' : state.tab;
      tab.classList.toggle('is-active', tab.dataset.tab === shown);
    });

    renderNotice();
  }

  /* Draw once, however many replies land.
     
     A refresh asks for three things at once and each reply redrew the whole
     page, so one click rebuilt the entire DOM three times over — plus once
     more per contract whose proposals came back. On a phone screen inside a
     game that is the lag: not the request, the redrawing.
     
     Coalesced onto a timeout of zero, which runs after the current burst of
     replies has been handled but before the browser paints, so nothing is
     ever drawn stale. */
  var redrawQueued = false;

  function redraw() {
    if (redrawQueued) { return; }
    redrawQueued = true;
    setTimeout(function () {
      redrawQueued = false;
      render();
    }, 0);
  }

  /* For a reply only some tabs draw: the board, Mine, the ledger, a face.
     Each reply redrew whatever tab was open, whether it showed the reply or
     not — the Place form under a player filling it in, a thread for each of
     six proposal reads, the board for the ledger. NUI replies land in tasks
     of their own, so the coalescing in redraw() did not merge them: a push
     on the Board was two or three full rebuilds of it. A tab draws what it
     holds when it is opened. */
  function redrawFor(tabs) {
    if (tabs.indexOf(state.tab) !== -1) { redraw(); }
  }

  /* Why a section is empty, when the reason is a refusal.
   *
   * These three used to be `if (r.ok)` with no else, so a refused board, a
   * refused Mine and a refused ledger all rendered as "there is nothing
   * here" — which is a different statement from "I could not ask", and the
   * one a player acts on by concluding the app is broken. Rate limited
   * while joining, a character the framework had not loaded yet, a blocked
   * job, a handler that threw: every one of them looked like an empty city.
   *
   * Recorded per section rather than raised as a notice, so it stays on
   * screen where the missing thing should be, next to a way to ask again —
   * the same shape the wallet already used. */
  function loadResult(section, r) {
    // An ok:true is only an answer if it carries one. All three of these
    // loads return a table from the server; a reply that claims success and
    // carries nothing usable — a handler changed under a page that has not
    // reloaded, a payload lost on the way across — used to be stored as
    // state and dereferenced on the next line, which threw inside the
    // promise callback. Nothing caught it: no failure card was drawn, no
    // Try again appeared, and the tab was left blank with the player's only
    // way out being to switch tabs. Refused here instead, so it lands in
    // the failure card that already exists, with the retry already on it.
    if (r.ok && r.data !== null && typeof r.data === 'object') {
      delete state.loadFailed[section];
      delete state.loadFinal[section];
      state.loaded[section] = true;
      return true;
    }
    // Barred from the app by their job: they may be shown the
    // whitelisted-job view instead, which only the server can say. Asked
    // once for the three reads that all come back this way, and the section
    // stays "asking" until it answers (probeJobView).
    if (r.err === 'blacklisted_job' && state.mode !== 'whitelisted') {
      probeJobView();
      return false;
    }
    state.loadFinal[section] = finalRefusal(r.err);
    state.loadFailed[section] = (r.err === 'rate_limited' && r.data && r.data.retryAfter)
      ? t('app.asked_too_fast_try_again') + retryIn(r.data.retryAfter) + '.'
      : r.err === 'blacklisted_job' ? barredText(r)
      : (ERRORS[r.err] || t('app.something_went_wrong'));
    redraw();
    return false;
  }

  /* Which load is the current one, per section.
  
     Two refreshes can be in flight at once — a tab change on top of a push,
     a push on top of the opening load — and nothing said which reply was
     newer. Replies are not ordered: the first request can answer last, and
     when it did it overwrote the newer board with the older one. A contract
     accepted a moment ago reappeared as available, and one that had just
     been placed vanished, until something else happened to trigger another
     refresh. */
  var loadSeq = { board: 0, mine: 0, ledger: 0, jobview: 0 };

  function newestLoad(section) {
    loadSeq[section] += 1;
    var mine = loadSeq[section];
    return function () { return loadSeq[section] === mine; };
  }

  /* Each section's last answer as text, with the object it was kept as, so
     a quiet read can tell an answer it already holds (refresh). Taken as
     the reply lands, before stampClocks marks it. Only while that object is
     still the one held: anything that puts another in its place makes the
     next answer new. */
  var answers = {};

  /* The server's settings as the board last brought them whole, and the hash
     it named them by: { hash, settings }. Sent back with each board read,
     which then leaves them out while they are the same (1.4 KB a read). */
  var boardSettings = null;

  function sameAnswer(section, data, held) {
    var text = null;
    try { text = JSON.stringify(data); } catch (err) { text = null; }
    var last = answers[section];
    return { text: text,
             same: !!(text !== null && held && last && last.held === held && last.text === text) };
  }

  function keepAnswer(section, text, held) {
    answers[section] = text === null ? null : { text: text, held: held };
  }

  /* Returns a promise that settles once all three reads have landed, so an
     action can hold its button until the screen shows what it did.

     `only` names the sections to read ({ board, mine, ledger }); without
     it, all three. A push reads only what the open tab draws (shownNow):
     it read all three whatever the tab, three requests from the bucket the
     board, Mine and the ledger share where one was drawn — and the board
     is the costliest thing the server builds. A section skipped is read
     when its tab is opened.

     `opts.quiet`: a read nobody tapped for (a push, a tab just opened and
     drawn). A section whose answer is the one already held, word for word,
     is then neither taken nor drawn again: a push about something on
     another screen rebuilt this one, the same, every time (sameAnswer). */
  function refresh(only, opts) {
    // The whitelisted-job view reads its one thing, whatever was asked for.
    if (state.mode === 'whitelisted') { return readJobView(opts); }
    var quiet = !!(opts && opts.quiet);

    function asked(section) { return !only || only[section] === true; }

    function readBoard() {
      var boardIsCurrent = newestLoad('board');
      // The server's settings come with the board only when they are not
      // the ones held here (boardSettings), named by their hash.
      return post('list', {
        page: state.boardPage || 1,
        settingsHash: boardSettings ? boardSettings.hash : undefined
      }).then(function (r) {
        if (!boardIsCurrent()) { return; }
        var hadFailed = !!state.loadFailed.board;
        if (r && r.ok && r.data && typeof r.data.settingsHash === 'string') {
          if (r.data.settings === undefined || r.data.settings === null) {
            // Left out as the ones held: the same object, so nothing reads
            // as changed.
            if (boardSettings && boardSettings.hash === r.data.settingsHash) {
              r.data.settings = boardSettings.settings;
            } else {
              // Not the ones held after all: asked for whole.
              boardSettings = null;
              return readBoard();
            }
          } else {
            boardSettings = { hash: r.data.settingsHash, settings: r.data.settings };
          }
        }
        if (!loadResult('board', r)) { return; }
        // The board shrank under the page being looked at: back to its last.
        var pages = Number(r.data && r.data.pages) || 1;
        if ((state.boardPage || 1) > pages) {
          state.boardPage = pages;
          return refresh();
        }
        // The Place form shows the server's settings, which come with the
        // board, and nothing else of it. An open dialog that quotes one (a
        // fee, a price) is drawn again from them, so what it shows is what
        // its tap is charged.
        var seen = sameAnswer('board', r.data, state.board);
        if (quiet && seen.same && !hadFailed) {
          if (state.boardTab === 'protection' && state.tab === 'board') { readProtection(); }
          return;
        }
        var settingsWere = JSON.stringify(settings());
        state.board = r.data;
        // The Organisation tab follows the board's word on it at once.
        syncOrgTab();
        keepAnswer('board', seen.text, r.data);
        stampClocks(r.data.contracts);
        // The Protection tab, when that is the one open, read with it.
        if (state.boardTab === 'protection' && state.tab === 'board') { readProtection(); }
        if (JSON.stringify(settings()) !== settingsWere) {
          if (state.dialog && typeof state.dialog.redo === 'function') { state.dialog.redo(); }
          redraw();
        } else { redrawFor(['board']); }
      });
    }

    function readMine() {
      var mineIsCurrent = newestLoad('mine');
      var mineAsked = loadSeq.mine;
      return post('mine', {}).then(function (r) {
        if (!mineIsCurrent()) { return; }
        // The open proposals on each card, where the server sends them with
        // Mine (one read for all of them, where each card asked on its own):
        // kept apart from the answer, whose sameness they would otherwise
        // break every second they count down.
        var proposals = (r && r.ok && r.data) ? r.data.proposals : undefined;
        if (proposals !== undefined) { delete r.data.proposals; }
        var opening = !state.loaded.mine;
        var hadFailed = !!state.loadFailed.mine;
        if (!loadResult('mine', r)) { return; }
        var seen = sameAnswer('mine', r.data, state.mine);
        var keep = quiet && seen.same && !hadFailed;
        // Read after the handover ended, so its snapshot is current again.
        Object.keys(countdownOver).forEach(function (id) {
          if (countdownOver[id] < mineAsked) { delete countdownOver[id]; }
        });
        if (!keep) {
          state.mine = r.data;
          keepAnswer('mine', seen.text, r.data);
          [r.data.created, r.data.accepted, r.data.onMe].forEach(stampClocks);
          redrawFor(['mine', 'onme', 'board']);
        }
        var data = state.mine;
        if (proposals && typeof proposals === 'object') {
          takeProposals(data, proposals);
          return;
        }
        // Only for contracts this player is actually party to, and only for
        // ones not already loaded: most contracts have no open proposal and
        // asking about every one of them every refresh would be three
        // requests a card.
        //
        // And, once the page is open, only while Mine is, the one tab that
        // draws them. Every push empties them, and each was read again on
        // whatever tab was open: three placed and three taken made a push
        // cost nine reads from the bucket the board, Mine and the ledger
        // share, so a few acceptances in a row ran the page into its own rate
        // limit. Opening Mine refreshes, and reads them then.
        if (!opening && state.tab !== 'mine' && state.tab !== 'thread') { return; }
        asList(data.created).concat(asList(data.accepted)).forEach(function (c) {
          if (state.proposals[c.id] === undefined && !proposalsAsking[c.id]) { loadProposals(c); }
        });
      });
    }

    function readLedger() {
      var ledgerIsCurrent = newestLoad('ledger');
      return post('ledger', {}).then(function (r) {
        if (!ledgerIsCurrent()) { return; }
        var hadFailed = !!state.loadFailed.ledger;
        if (!loadResult('ledger', r)) { return; }
        var seen = sameAnswer('ledger', r.data, state.ledger);
        if (quiet && seen.same && !hadFailed) { return; }
        state.ledger = r.data;
        keepAnswer('ledger', seen.text, r.data);
        // Mine reads it too: how to finish a contract (howToFinish).
        redrawFor(['ledger', 'mine']);
      });
    }

    var board = asked('board') ? readBoard() : Promise.resolve();
    var mine = asked('mine') ? readMine() : Promise.resolve();
    var ledger = asked('ledger') ? readLedger() : Promise.resolve();
    return Promise.all([board, mine, ledger]);
  }

  /* ---------- which app this player is shown ----------

     The whole app, or the whitelisted-job view for a player on a job the
     app bars. The server decides, on every request: the page finds out
     from the answers, never by deciding for itself. Its three opening reads
     come back blacklisted_job for a barred player, and the view's read
     either answers (the view is on) or does not (the app is closed to
     them, as it always was). A job change while the page is open arrives
     as a push ('access'), and the page drops everything it holds from the
     app it was showing before asking again. */

  /* Everything read for the app it was showing, forgotten: no board, Mine,
     ledger, wallet, draft, thread or face survives into the other one, and
     a reply still on its way for it lands nowhere (loadSeq). */
  function forgetMode() {
    navigated();
    stopCountdown();
    Object.keys(loadSeq).forEach(function (section) { loadSeq[section] += 1; });
    state.board = null; state.mine = null; state.ledger = null; state.jobView = null;
    answers = {};
    state.wallet = null; state.walletFailed = null;
    state.dialog = null; state.thread = null; state.call = null; state.reward = null;
    state.draft = {}; state.picked = {}; state.proposals = {}; state.drafts = {};
    state.protection = null; state.boardTab = 'contracts';
    state.lastRefusal = {}; state.progress = {}; state.images = {};
    state.loadFailed = {}; state.loadFinal = {}; state.loaded = {};
    state.boardPage = 1; state.leoConfirmed = false;
    state.browse = { scope: 'all', query: '', page: 1, data: null, pending: null, draw: null,
                     nearbyClosed: false };
  }

  /* The tab bar goes with the whole app: the view is one screen. */
  function markMode() {
    var root = document.documentElement;
    if (root && root.classList) {
      root.classList.toggle('is-whitelisted-view', state.mode === 'whitelisted');
    }
  }

  /* The view's answer, as the page keeps it. A contract on this player is
     read as the target reads it (clockWords, appendBuyout). */
  function takeJobView(data) {
    state.jobView = data;
    asList(data.onYou).forEach(function (entry) {
      if (entry && typeof entry === 'object') { entry.role = 'target'; }
    });
    stampClocks(data.onYou);
    stampClocks(data.colleagues);
  }

  function enterJobView(data) {
    if (state.mode !== 'whitelisted') {
      forgetMode();
      state.mode = 'whitelisted';
      state.tab = 'jobview';
      markMode();
    }
    delete state.loadFailed.jobview;
    delete state.loadFinal.jobview;
    state.loaded.jobview = true;
    takeJobView(data);
    redraw();
  }

  function leaveJobView() {
    forgetMode();
    state.mode = 'full';
    state.tab = 'board';
    markMode();
    render();
    return refresh();
  }

  /* `opts.keep`: asked from the screen's Refresh, so a refusal to ask
     again so soon says how long to wait and leaves what is shown. */
  function readJobView(opts) {
    var isCurrent = newestLoad('jobview');
    return post('whitelistedView', {}).then(function (r) {
      if (!isCurrent()) { return; }
      // They have left the job: the whole app is theirs again.
      if (!r.ok && r.err === 'not_whitelisted') { return leaveJobView(); }
      if (opts && opts.keep && !r.ok && r.err === 'rate_limited' && state.loaded.jobview) {
        return say(t('app.asked_too_fast_try_again') + retryIn(r.data && r.data.retryAfter) + '.',
          'caution');
      }
      var hadFailed = !!state.loadFailed.jobview;
      if (!loadResult('jobview', r)) { return; }
      var seen = sameAnswer('jobview', r.data, state.jobView);
      if (opts && opts.quiet && seen.same && !hadFailed) { return; }
      takeJobView(r.data);
      keepAnswer('jobview', seen.text, r.data);
      redrawFor(['jobview']);
    });
  }

  /* Asked when an opening read comes back blacklisted_job. Once, however
     many of the three do. */
  var probing = null;
  function probeJobView() {
    if (probing) { return probing; }
    probing = post('whitelistedView', {}).then(function (r) {
      probing = null;
      if (state.mode === 'whitelisted') { return; }
      if (r.ok && r.data !== null && typeof r.data === 'object') {
        enterJobView(r.data);
        return;
      }
      // No view for them either: the app is closed to their job, as it
      // always was, and each section says so where its contents would be,
      // naming a job they hold, with no Try again (finalRefusal): only
      // quitting the job changes the answer.
      var why = r.err === 'blacklisted_job' ? barredText(r)
        : (r.err === 'not_whitelisted' || !r.err)
          ? ERRORS.blacklisted_job : (ERRORS[r.err] || ERRORS.blacklisted_job);
      ['board', 'mine', 'ledger'].forEach(function (section) {
        state.loadFinal[section] = finalRefusal(r.err);
        state.loadFailed[section] = why;
      });
      redraw();
    });
    return probing;
  }

  /* What the open tab draws, as refresh() takes it: a push re-reads only
     that. Mine draws the ledger's record too, and a thread the proposals
     Mine's reply asks for; the Place form draws none of them. */
  function shownNow() {
    var tab = state.tab;
    return {
      board: tab === 'board',
      mine: tab === 'mine' || tab === 'onme' || tab === 'thread',
      ledger: tab === 'ledger' || tab === 'mine'
    };
  }

  /* A tab's tap. A function of its own, for the Organisation tab, which is
     made later, when the board says it is for this player (syncOrgTab). */
  function wireTab(tab) {
    tab.onclick = function () {
      // The whitelisted-job view is one screen; its bar is not drawn.
      if (state.mode === 'whitelisted') { return; }
      /* Not while the kill photo's one look is unanswered. Leaving it was a
         Delete (letGoOfProof), so a tap on the tab bar thirty pixels under
         Save to Photos threw away the photo the client had paid for, with
         no undo, on what was a mis-tap or a "back in a moment". The one
         chance stays one chance; it is spent by Save or Delete, said on
         purpose. A photo kept in the app spends nothing by being left. */
      if (state.dialog && state.dialog.kind === 'proof' && !state.dialog.kept) {
        say(t('app.save_or_delete_the_photo_first'), 'caution');
        return;
      }
      navigated();
      state.tab = tab.dataset.tab;
      state.dialog = null;
      state.focus = null;

      // Opening the Place form is a player asking to try again. One refused
      // wallet used to leave an error card where both pickers should be for
      // the rest of the session, since the form only re-asks when it holds
      // neither a wallet nor a failure.
      //
      // And it is read afresh, not kept. The wallet was read on the first
      // open and never again until a contract was placed, so every balance
      // on the form — and every item and weapon offered — was whatever the
      // player had been carrying then: a stake paid, a buyout, a refund or
      // a purchase anywhere in the city since, and the form showed money
      // they no longer had, then refused the contract with "You do not have
      // that" beside a balance saying they did.
      if (state.tab === 'place') {
        state.walletFailed = null;
        state.wallet = null;
        // The list is read afresh too. Its handles lapse after a while, and
        // re-reading it is what renews them.
        state.browse.data = null;
        state.browse.pending = null;
        state.browse.refusal = null;
      }

      render();
      // Opening a tab is when a player expects to see current state. The
      // ledger too: a push no longer reads it unless it is open.
      // Drawn just now from what it holds: an answer the same is not drawn
      // again.
      if (state.tab === 'board' || state.tab === 'mine' || state.tab === 'onme') refresh(null, { quiet: true });
      else if (state.tab === 'ledger') refresh({ ledger: true }, { quiet: true });
      else if (state.tab === 'org') { state.org.armed = null; loadOrg(); }
    };
  }
  Array.prototype.forEach.call(document.querySelectorAll('.tab'), wireTab);

  // The client tells the page each server reply came (its event and
  // outcome, never its data) as well as resolving the fetch that asked for
  // it. Refreshing on those is a loop: one refresh sends three requests,
  // each reply triggers another refresh, and the app buries itself within
  // seconds. Only an unsolicited push is acted on.
  var pushTimer = null;
  // A settings push waiting in that debounce (see the push handler).
  var settingsPushed = false;
  // And a late answer's (the same).
  var latePushed = false;

  /* ---------- whether the player has the app on screen ----------

     lb-phone keeps this frame alive with the phone put away, so whatever
     the page runs, it runs all game for every player who has opened it
     once. While it is put away it reads nothing: a push only notes what it
     asked for (pushOwed), and the page reads it the moment it is shown
     again, once however many came. The handover poll slows to one in five
     seconds (armCountdown). Nothing else here runs on a timer while the
     page is idle.

     Put away and shown are lb-phone's onClose and onOpen, which the client
     passes on ('shown'), and the document's own visibility where the frame
     has one. A tap or a key in the page is the player looking at it,
     whatever was last said, so a lost 'shown' never leaves it asleep. */
  var shownByPhone = true;
  // What a push asked for while the page was put away: null for nothing,
  // else { refresh, all, thread }.
  var pushOwed = null;

  function pageShown() {
    return shownByPhone && !(document && document.hidden === true);
  }

  function owe(what) {
    pushOwed = pushOwed || { refresh: false, all: false, thread: false };
    Object.keys(what).forEach(function (key) { if (what[key]) { pushOwed[key] = true; } });
  }

  /* What the debounced push reads: the open tab's sections (shownNow), the
     board as well after a settings push, everything after a late answer
     or (`all`) a change of app. */
  function readPushed(all) {
    var wanted = all ? { board: true, mine: true, ledger: true } : shownNow();
    if (settingsPushed) {
      settingsPushed = false;
      wanted.board = true;
      if (state.tab === 'place') {
        state.wallet = null;
        state.walletFailed = null;
        redraw();
      }
    }
    if (latePushed) {
      latePushed = false;
      wanted = { board: true, mine: true, ledger: true };
      if (state.tab === 'place') {
        state.wallet = null;
        state.walletFailed = null;
        redraw();
      }
    }
    refresh(wanted, { quiet: true });
  }

  /* Shown again: the poll back to its pace, and what was pushed meanwhile
     read now, once. */
  function shownAgain() {
    if (countdownTick) { armCountdown(); countdownTick(); }
    var owed = pushOwed;
    pushOwed = null;
    if (!owed) { return; }
    if (owed.thread && state.tab === 'thread' && state.thread) {
      openThread(state.thread.contract, state.thread.thread, { reread: true });
    }
    if (owed.refresh || owed.all) { readPushed(owed.all); }
  }

  // What the page last took itself to be: the document's visibility has
  // already changed by the time its event says so.
  var wasShown = true;

  function setShown(byPhone) {
    if (typeof byPhone === 'boolean') { shownByPhone = byPhone; }
    var now = pageShown();
    if (now === wasShown) { return; }
    wasShown = now;
    if (now) { shownAgain(); } else if (countdownTick) { armCountdown(); }
  }

  if (document && typeof document.addEventListener === 'function') {
    document.addEventListener('visibilitychange', function () { setShown(); });
  }

  // A refusal stays up until the player does something else. Captured, so
  // it is cleared before the tap's own handler runs and can raise the next.
  document.addEventListener('click', function () {
    if (!shownByPhone) { setShown(true); }
    if (state.notice && state.notice.kind === 'red') { dismissNotice(); }
  }, true);
  // The pointer over the page, a key or the wheel: the player is looking at
  // it. One comparison each while it is shown.
  ['keydown', 'mousemove', 'wheel'].forEach(function (type) {
    document.addEventListener(type, function () {
      if (!shownByPhone) { setShown(true); }
    }, true);
  });

  window.addEventListener('message', function (event) {
    var data = event.data || {};

    if (data.type === 'push') {
      /* A job change that moved this player between the whole app and the
         whitelisted-job view. Everything held for the one they had is
         dropped, and the page asks again: the view's read in the view
         (which sends them back to the app if they left the job), the
         app's reads otherwise (which find the view if they joined one). */
      if (data.reason === 'access') {
        // A kill photo open for its one look goes with the rest, as a
        // Delete the server is told of (letGoOfProof, in the redraw), and
        // the player is told too, rather than it vanishing unsaid. Kept, it
        // could not be saved: a whitelisted job is refused the app's own
        // requests, deciding on the photo among them.
        var proofLost = !!proofShown && !!state.dialog && state.dialog.kind === 'proof';
        forgetMode();
        // Whatever tab the whole app had open held what was just dropped
        // (a thread, the Place form): it starts again from the board.
        if (state.mode !== 'whitelisted') { state.tab = 'board'; }
        render();
        if (proofLost) {
          say(t('app.your_access_to_the_app_changed'));
        }
        // Put away: read when shown again, everything, as here.
        if (pageShown()) { refresh(); } else { owe({ all: true }); }
        return;
      }

      /* A message changes one thing: the thread it was sent in. A full
         refresh for each one is three requests and more, and a quick
         exchange ran the page into its own rate limit. */
      if (data.reason === 'message') {
        if (!pageShown()) { owe({ thread: true }); return; }
        if (state.tab === 'thread' && state.thread) {
          openThread(state.thread.contract, state.thread.thread, { reread: true });
        }
        return;
      }

      /* A push is the server saying something this player is looking at has
         changed, and an open amendment is the thing most likely to have
         changed that the page cannot work out for itself.
      
         Proposals are read once per contract and then cached, deliberately:
         most contracts have none and asking about every card on every
         refresh is three requests a card. But the cache was keyed on
         "undefined means unasked", and an empty answer is not undefined —
         so once a contract had been asked about and had no proposal, it was
         never asked about again. The other party then proposed a change,
         the server pushed, this page refreshed, and the proposal was never
         fetched, never drawn and never answered. It expired unseen, every
         time, on a feature that needs both parties to see it.
      
         Cleared here and nowhere else: a push is exactly the signal that
         the cache is stale, and it is the only one.

         Only for the contracts the push names, when it names any. Every
         push cleared them all, and with Mine open each one re-read every
         card's proposals: three placed and three taken were nine reads
         from the bucket the board, Mine and the ledger share. A push that
         names none — from an older server, or one standing for a burst
         where something named none — still clears everything. */
      var named = data.ids && typeof data.ids === 'object' ? asList(data.ids) : [];
      if (named.length) {
        named.forEach(function (id) { forgetProposals(id); });
      } else {
        forgetProposals();
      }

      /* And an open thread is re-read.
      
         A thread was fetched when it was opened and after each send by this
         player, and never otherwise. So the other party's replies simply
         did not arrive: two people could sit in the same conversation, both
         writing, and neither would see the other until one of them left the
         screen and came back. A push is the server saying something
         changed, and a message is one of the things it pushes for. */
      if (!pageShown()) {
        owe({ thread: true });
      } else if (state.tab === 'thread' && state.thread) {
        openThread(state.thread.contract, state.thread.thread, { reread: true });
      }

      /* A setting changed from the admin panel. The settings every tab
         draws by — fees, prices, the rule, the switches — come with the
         board's listing, which a push read only on the Board tab: Place, On
         me, Mine and the Ledger kept the old ones, and the server charged
         the new. So the listing is read whatever is open. On the Place form
         the wallet is read again too, which carries the payout count, the
         money sources that are on and the caps; the last payout ceiling is
         kept meanwhile, as opening the tab keeps it. Kept until the
         debounced refresh, so a push landing after it in the same burst does
         not drop it. */
      if (data.reason === 'settings') { settingsPushed = true; }

      /* An answer to a request this page was told had timed out (the client
         remembers those for two minutes). Whatever it did, everything is
         read again, whatever tab is open: a contract placed after "No
         answer yet" shows under Mine, and on the Place form the wallet it
         was paid from is read again. */
      if (data.reason === 'late') { latePushed = true; }

      // Debounced: a contract settling pushes the creator, the target and
      // every hitman, and several of those can land in the same tick. One
      // refresh is three requests, so a push per party would be a burst per
      // event.
      //
      // Put away, nothing is read: what it asked for is read once the
      // page is shown again (shownAgain), however many pushes came.
      if (pushTimer) { clearTimeout(pushTimer); pushTimer = null; }
      if (!pageShown()) { owe({ refresh: true }); return; }
      pushTimer = setTimeout(function () {
        pushTimer = null;
        if (!pageShown()) { owe({ refresh: true }); return; }
        readPushed(false);
      }, 250);
      return;
    }

    // lb-phone's onOpen and onClose, passed on by the client.
    if (data.type === 'shown') {
      setShown(data.shown !== false);
      return;
    }

    // The client asks for this when a staff member runs the diagnosis
    // command, so what the page has seen reaches the same report as what
    // the server has seen. It is the only way to read this side of the
    // bridge from outside the game.
    if (data.type === 'diagnostics') {
      Diag.note('asked', t('app.the_server_asked_what_this_page'));
      Diag.dump(Diag.asText());
      return;
    }
  });

  /* lb-phone's theme, on the root, for the light status band (app.css,
     body::before). lb-phone draws its clock, signal, battery and home
     indicator onto this page in black in its light theme, its default, and
     the page is dark: they vanished. It sets data-theme itself; asked here
     too, as its own app template does, so a build that leaves it to the
     app still gets the band. Optional: a page with neither function (a
     browser, a test) stays as it is. */
  function applyTheme(settings) {
    var theme = settings && settings.display && settings.display.theme;
    if (theme === 'light' || theme === 'dark') {
      document.documentElement.setAttribute('data-theme', theme);
    }
  }
  try {
    if (typeof window.getSettings === 'function') {
      Promise.resolve(window.getSettings()).then(applyTheme, function () {});
    }
    if (typeof window.onSettingsChange === 'function') {
      window.onSettingsChange(applyTheme);
    }
  } catch (err) { /* the dark page as before */ }


  /* ---------- roleplay: proof of intent, reputation, bodyguards ----------

     Proof of intent (Config.Roleplay.ProofOfIntent): a payout held until
     the hitman shows they worked the contract, said on their card, at the
     top of Mine and in the Verify kill answer. Reputation: the trust a
     completion earned and why, in that answer too. Bodyguards
     (Config.Roleplay.Protection): the board's Protection tab, and the
     target's own job on their On me card. The hit on the hitman
     (Config.Roleplay.HitOnHitman): a button by an operative the target's
     informant named, opening Place with them chosen. Everything here is
     drawn from what the server sent; nothing here names a party it did
     not. */

  /* `saysHeld`: the lead already says the payout is held ("Your payout
     here is held."), so the rest does not say it again; it read "… is
     held. Your payout is held until …". */
  function intentHoldText(hold, lead, saysHeld) {
    var minutes = Number(hold.minutesLeft !== undefined ? hold.minutesLeft : hold.minutes) || 0;
    // Nothing left to do on it: the payout closed the contract, and with it
    // its thread and its meeting point. Listing them as ways to release it
    // offered what the server would refuse. Only the wait is said.
    if (hold.closed || !hold.missing) {
      return lead + (saysHeld ? t('app.it_is_released_within') : t('app.payout_held_released_within'))
        + (minutes > 0 ? durationText(minutes) : t('app.a_moment')) + '.';
    }
    return lead + (saysHeld ? t('app.it_is_released_once_you_show_intent') : t('app.your_payout_is_held_until_you'))
      + (hold.missing || t('app.proof_of_intent')) + '.'
      + (minutes > 0 ? t('app.it_is_released_anyway_within') + durationText(minutes) + '.' : '');
  }

  function reputationText(data) {
    var rep = data && data.reputation;
    return rep && rep.text ? ' ' + rep.text : '';
  }

  function boardTabs() {
    var tabs = el('div', 'row target-modes board-tabs');
    [['contracts', t('app.contracts')], ['protection', t('app.protection')]].forEach(function (pair) {
      var on = (state.boardTab || 'contracts') === pair[0];
      var b = el('button', on ? 'primary' : 'ghost', pair[1]);
      b.onclick = function () {
        state.boardTab = pair[0];
        if (pair[0] === 'protection') { readProtection(); }
        render();
      };
      tabs.appendChild(b);
    });
    return tabs;
  }

  function readProtection() {
    state.protection = state.protection || {};
    state.protection.pending = true;
    return post('protectionBoard', {}).then(function (r) {
      state.protection.pending = false;
      if (!r.ok) {
        state.protection.failed = failText(r) || t('app.could_not_read_the_protection_jobs');
      } else {
        state.protection.failed = null;
        state.protection.data = r.data;
      }
      if (state.tab === 'board') { redraw(); }
    });
  }

  function viewProtection(view) {
    var p = state.protection || {};
    if (!p.data && !p.pending && !p.failed) { readProtection(); }
    if (p.failed) {
      var failed = el('div', 'card');
      failed.appendChild(el('div', 'hint', p.failed));
      failed.appendChild(actionButton('ghost ico i-refresh', t('app.try_again'), 'protection:read',
        t('app.reading'), readProtection));
      view.appendChild(failed);
      return;
    }
    if (!p.data) {
      view.appendChild(el('div', 'empty', t('app.reading_the_protection_jobs')));
      return;
    }
    var data = p.data;
    var mine = asList(data.mine);
    if (mine.length) {
      view.appendChild(el('h3', 'section', t('app.people_you_guard')));
      mine.forEach(function (job) {
        var c = el('div', 'card protection-job');
        c.appendChild(el('div', 'target', job.targetName || t('app.your_client')));
        c.appendChild(el('div', 'hint', t('app.paid_if_the_contract_on_them_ends', money(job.reward))));
        if (job.pinSet) {
          var row = el('div', 'row actions');
          row.appendChild(actionButton('ghost ico i-pin', t('app.set_gps_to_the_pin'),
            'protection:gps:' + job.job, t('app.setting'), function () {
              return post('gps', { kind: 'protection', job: job.job }).then(function (r) {
                if (r.ok) { say(t('app.waypoint_set_to_the_meeting_pin'), 'ok'); } else { fail(r); }
              });
            }));
          c.appendChild(row);
        }
        view.appendChild(c);
      });
    }
    view.appendChild(el('h3', 'section', t('app.protection_jobs')));
    if (!data.enabled) {
      view.appendChild(el('div', 'empty', t('app.this_server_is_not_taking_protection')));
      return;
    }
    var open = asList(data.open);
    if (!open.length) {
      view.appendChild(el('div', 'empty', t('app.nobody_is_asking_for_protection_right')));
      return;
    }
    open.forEach(function (job) {
      var c = el('div', 'card protection-job');
      c.appendChild(el('div', 'target', t('app.protection_amount', money(job.reward))));
      c.appendChild(el('div', 'hint', t('app.somebody_with_a_price_on_their')
        + t('app.take_it_and_you_get_their')
        + t('app.on_them_ends_without_being_carried')));
      var take = el('button', 'primary ico i-shield', t('app.take_the_job'));
      function takeJob(anonymous) {
        return once('protection:take:' + job.job, function () {
          return post('protectionAccept', { job: job.job, reward: job.reward,
            anonymous: anonymous === true }).then(function (r) {
            if (!r.ok) { fail(r); return readProtection(); }
            state.protection.data = r.data;
            say(t('app.you_took_the_job_their_name'), 'ok');
            redraw();
          });
        });
      }
      take.onclick = function () {
        var question = t('app.take_this_protection_job_for') + money(job.reward) + '?';
        var detail = t('app.you_get_their_name_and_a');
        /* Taking it anonymously, as an operative takes a contract: offered
           only where the server allows it whatever job the person has (the
           board does not say whether they work a whitelisted one, and a
           choice drawn for one and not the other would say so). */
        if (anonymityOffered('hitman', false) && anonymityOffered('hitman', true)) {
          state.dialog = {
            kind: 'choice', question: question,
            detail: detail + t('app.anonymously_the_person_you_guard_is'),
            options: [
              { label: t('app.anonymously'), primary: true, run: function () { takeJob(true); } },
              { label: t('app.under_my_name'), run: function () { takeJob(false); } }
            ]
          };
          render();
          return;
        }
        ask(question, detail, function () { return takeJob(false); }, { yes: t('app.take_it'), no: t('app.not_now') });
      };
      c.appendChild(take);
      view.appendChild(c);
    });
  }

  /* The target's side, on their On me card. */
  function appendCounterplay(row, more, contract) {
    var job = contract.protection;
    if (job) {
      row.appendChild(el('div', 'notice ok protection-state', job.state === 'taken'
        ? t('app.your_protection_job') + money(job.reward) + t('app.was_taken')
          + (job.guardName ? t('app.by_name', job.guardName) : '') + t('app.they_have_your_name_and_your')
        : t('app.your_protection_job') + money(job.reward) + t('app.is_waiting_for_a_bodyguard')));
      more.appendChild(actionButton('ghost ico i-pin', t('app.move_the_pin_here'),
        'protection:pin:' + job.job, t('app.moving'), function () {
          return post('protectionPin', { job: job.job }).then(function (r) {
            if (r.ok) { say(t('app.the_meeting_pin_is_where_you'), 'ok'); } else { fail(r); }
          });
        }, { question: t('app.move_the_meeting_pin_to_where'),
             detail: job.state === 'taken' ? t('app.your_bodyguard_sees_the_new_spot')
               : t('app.whoever_takes_the_job_meets_you'),
             yes: t('app.move_it'), no: t('app.not_now') }));
      if (job.state !== 'taken') {
        var back = el('button', 'ghost ico i-xcircle', t('app.cancel_protection'));
        back.onclick = function () {
          ask(t('app.cancel_your_protection_job'), t('app.nobody_has_taken_it_so_the') + money(job.reward)
            + t('app.comes_back_to_you'), function () {
            return once('protection:cancel:' + job.job, function () {
              return post('protectionCancel', { job: job.job }).then(function (r) {
                if (r.ok) { say(t('app.cancelled_the_money_is_on_its'), 'ok'); refresh(); }
                else { fail(r); }
              });
            });
          }, { yes: t('app.cancel_it'), no: t('app.keep_it') });
        };
        more.appendChild(back);
      }
    } else if (contract.protectionOffer) {
      var offer = contract.protectionOffer;
      var hire = el('button', 'ghost ico i-shield', t('app.hire_protection'));
      hire.onclick = function () {
        askFields(t('app.hire_a_bodyguard'), t('app.post_an_anonymous_protection_job_the')
          + t('app.your_account_now_and_held', offer.account)
          + t('app.ends_without_being_carried_out_and')
          + t('app.they_get_your_name_and_a'),
          [{ id: 'amount', label: t('app.reward_range', money(offer.min), money(offer.max)),
             type: 'number', value: offer.min, min: offer.min, max: offer.max }],
          function (values) {
            ask(t('app.pay_from_your', money(values.amount), offer.account),
              t('app.held_until_the_contract_on_you'), function () {
                return once('protection:post:' + contract.id, function () {
                  return post('protectionPost', { id: contract.id, amount: values.amount,
                                                  account: offer.account }).then(function (r) {
                    if (r.ok) { say(t('app.your_protection_job_is_posted'), 'ok'); refresh(); }
                    else { fail(r); }
                  });
                });
              }, { yes: t('app.pay_x', money(values.amount)), no: t('app.cancel') });
          }, t('app.next'));
      };
      more.appendChild(hire);
    }
    asList(contract.counterTargets).forEach(function (tv) {
      var hit = el('button', 'ghost ico i-crosshair counter-hit', t('app.place_a_contract_on') + (tv.name || tv.label));
      hit.onclick = function () {
        state.draft = state.draft || {};
        state.draft.target = tv.handle;
        state.draft.targetName = tv.name || tv.label;
        state.draft.targetProtected = false;
        delete state.draft.targetProtectedAs;
        state.tab = 'place';
        render();
      };
      more.appendChild(hit);
    });
  }

  /* ---------- improvements (server/imp_*.lua), each off as shipped ---------- */

  /* The placer's record on a board card: three counts and the days they
     cover, never who. An anonymous placer's come as bands ('1-4'). */
  function placerRecordText(r) {
    return t('app.placer_record', r.placed, r.paidOut, r.cancelled, tn('app.days_count', Number(r.days) || 0));
  }

  /* A card in a tier above this player's level. */
  function tierLockedText(lock) {
    return (lock.tier || t('app.higher')) + t('app.tier_you_need_level') + (Number(lock.level) || 0)
      + (Number(lock.yours) > 0 ? t('app.you_are_level') + Number(lock.yours) + ').' : '.');
  }

  /* What contract decay does to the placer's untaken contract, and a way to
     turn it off for this one (two taps: the button, then the dialog). */
  function appendDecay(row, more, contract) {
    var d = contract.decay;
    if (!d) { return; }
    // Placed anonymously: the reward never rises (server/imp_decay.lua).
    if (d.anonymous) {
      row.appendChild(el('div', 'notice decay-notice',
        t('app.its_reward_does_not_rise_while')));
      return;
    }
    var what;
    if (d.mode === 'shorten') {
      what = tn('app.runs_out_sooner_hours', d.hours, d.percent, d.hours);
    } else {
      what = tn('app.decay_rise_hours', d.hours, d.percent, d.hours, d.maxPercent,
        d.account === 'cash' ? 'cash' : 'bank');
      if (Number(d.added) > 0) { what += t('app.added_so_far') + money(d.added) + '.'; }
    }
    if (d.off) { what = t('app.you_turned_off_the_change_for'); }
    else if (d.stopped) { what += t('app.it_has_stopped_for_this_contract'); }
    else if (d.taken) { what = t('app.somebody_took_it_so_it_no'); }
    row.appendChild(el('div', 'notice decay-notice', what));
    if (d.off || d.stopped || d.taken) { return; }
    var stop = el('button', 'ghost ico i-xcircle decay-off',
      d.mode === 'shorten' ? t('app.stop_the_countdown') : t('app.stop_the_rise'));
    stop.onclick = function () {
      ask(d.mode === 'shorten' ? t('app.stop_bringing_its_deadline_in') : t('app.stop_its_reward_rising'),
        t('app.only_for_this_contract_it_cannot'), function () {
          return once('decayOff:' + contract.id, function () {
            return post('decayOff', { id: contract.id }).then(function (r) {
              if (r.ok) { say(t('app.turned_off_for_this_contract'), 'ok'); refresh(); }
              else { fail(r); }
            });
          });
        }, { yes: t('app.turn_it_off'), no: t('app.keep_it') });
    };
    more.appendChild(stop);
  }

  // Installed before the first render: a throw in that render is exactly
  // the kind this exists to catch, and catching it needs the handler
  // already in place.
  Diag.install();

  render();
  /* Which screen the server said is theirs, from their own game (it keeps
     the last answer: crimson:accessMode), before the first read. A player
     on the whitelisted-job view is asked for its one read, not the app's
     three: each of those is refused them, and the server writes a refusal
     down as somebody probing what is not theirs. Unknown, or anything
     else, is the whole app, whose reads find the view as they always did. */
  post('accessMode', {}).then(function (r) {
    var mode = r && r.ok && r.data && r.data.mode;
    if (mode === 'whitelisted' && state.mode !== 'whitelisted') {
      state.mode = 'whitelisted';
      state.tab = 'jobview';
      markMode();
      render();
    }
    return refresh();
  });

})();
