/* Crimson Bounty System — app shell.
   The UI holds no authority: it renders what the server sends and asks for
   what the player clicks. Every value shown here arrived in a projection. */

(function () {
  'use strict';

  /* The resource this page belongs to, asked for rather than assumed.
  
     This was the literal 'crimson-bounty'. Every NUI call posts to
     https://<resource>/..., and renaming a resource folder is an ordinary
     thing for a server owner to do — at which point every request in the
     app goes to a resource that does not exist, every one of them answers
     'unreachable', and the app is a set of buttons that do nothing with no
     clue anywhere as to why. The client derives every other URL from
     GetCurrentResourceName(); this is the one place that did not.
  
     GetParentResourceName is what CEF provides for exactly this. The
     literal stays as the fallback for anywhere it is absent — the test
     harness, a browser opened on the file directly — because a page that
     cannot work out its own name should still behave as it did before. */
  var RESOURCE = (typeof GetParentResourceName === 'function'
    && GetParentResourceName()) || 'crimson-bounty';
  var state = {
    tab: 'board', board: null, mine: null, ledger: null,
    progress: {}, dialog: null, leoConfirmed: false, wallet: null,
    busy: false, notice: null, walletFailed: null,
    // Why the board, Mine or the ledger has nothing in it, when the reason
    // is that the server refused rather than that there is nothing to show.
    loadFailed: {},
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
    browse: { scope: 'all', query: '', page: 1, data: null, pending: null, draw: null },
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
    drafts: {}
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
                 stack: '', build: window.CB_BUILD || 'dev' });
        }
        return false;
      }
      reported += 1;
      send({ what: String(what).slice(0, 300),
             where: String(where || '').slice(0, 200),
             stack: String(stack || '').slice(0, 900),
             tab: state && state.tab, build: window.CB_BUILD || 'dev' });
      return true;
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
        report(message, 'unhandled rejection', reason && reason.stack);
      });

      note('boot', 'build ' + (window.CB_BUILD || 'dev'));
    }

    /* ---- the in-game panel ----

       Opened by tapping the build stamp in the ledger five times, the way
       a phone exposes a developer menu, because there is no keyboard here
       and no room for a permanent control. Closed by its own button. */
    var taps = 0, lastTap = 0;

    function tapped() {
      var t = now();
      taps = (t - lastTap < 1200) ? taps + 1 : 1;
      lastTap = t;
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
      title.textContent = 'Diagnostics · ' + (window.CB_BUILD || 'dev');
      head.appendChild(title);

      var close = document.createElement('button');
      close.className = 'ghost';
      close.textContent = 'Close';
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

      var copy = document.createElement('button');
      copy.className = 'ghost diag-copy';
      copy.textContent = 'Send this to the server log';
      copy.onclick = function () {
        send({ what: 'diagnostics requested by the player', where: 'panel',
               stack: asText(), build: window.CB_BUILD || 'dev' });
        note('sent', 'diagnostics sent to the server log');
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

    return { note: note, report: report, guard: guard, install: install,
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
      Diag.note('unreachable', name + ' -> ' + ((err && err.message) || 'no reply'));
      return done({ ok: false, err: 'unreachable' });
    });
  }

  var ERRORS = {
    /* The framework has not finished loading this character. Ordinary
       rather than exceptional: the app fires three requests the moment it
       opens, and somebody who opens it while still joining gets this on all
       three. It had no message here, so it fell through to "Something went
       wrong" — which reads as a broken app rather than as "not yet", and
       sends the player looking for a fault that will clear on its own. */
    no_player: 'The server is still loading your character. Give it a few '
      + 'seconds and open this again.',
    blacklisted_job: 'This app is not for you.',
    rate_limited: 'Slow down.',
    // Policy waits, not throttling. Both shared rate_limited, so a creator
    // with two hours to wait read "Slow down." — and three of this page's
    // recovery paths treat rate_limited as a transient condition worth
    // retrying, which these are not.
    same_target_too_soon: 'You placed a contract on this person recently. '
      + 'Somebody else could list them now \u2014 you have to leave it longer.',
    cancelled_too_soon: 'You cancelled a contract recently. Placing another '
      + 'has to wait a few minutes: cancelling and re-listing would otherwise '
      + 'be free.',
    // Also policy waits. slot_cooldown shared rate_limited, so a hunter
    // photographing a body was told to wait a few seconds and try again on
    // a wait of ten minutes; handover_cooldown shared bad_state.
    slot_cooldown: 'You collected on this contract very recently. The next '
      + 'payout on it has to wait \u2014 a kill or a handover now will not '
      + 'count, so work another contract in the meantime.',
    handover_cooldown: 'Your last handover on this contract failed a moment '
      + 'ago. Give it a minute before you start another.',
    self_target: 'You cannot put a price on yourself.',
    self_accept: 'You cannot take your own contract.',
    same_account: 'Not on your own people.',
    already_holding: 'You are already on this contract. It is under Mine.',
    hold_released: 'You held this one without working it and were taken off '
      + 'it. It is not yours to take again.',
    relay_off: 'This server does not run messages through the app.',
    calls_off: 'This server does not place calls through the app.',
    call_unmasked: 'They are staying anonymous, and a call from this phone '
      + 'would show their number. Send a message instead.',
    limit_reached: 'You are holding too many contracts.',
    /* A different rule entirely, and it used to share the message above —
       which told a hunter holding nothing that they were holding too much,
       and sent them to cancel their own work over somebody else's contract
       being popular. */
    contract_full: 'This contract already has as many operatives on it as it '
      + 'allows. Try another, or come back if one drops out.',
    /* The stake moved between reading the board and tapping Accept. Refused
       rather than charged, because a stake is taken on the tap and forfeits
       to the client if the hunter later walks away — the one repricing a
       player cannot undo by looking again. */
    terms_changed: 'The stake on this contract changed while you were looking '
      + 'at it. Refreshing now — check the new figure before you take it.',
    target_protected: 'That target cannot be listed right now.',

    /* One message covered six different rules, and a player reading it had
       no way to tell which — or whether waiting would help. */
    target_is_leo: 'This server does not allow contracts on law enforcement.',
    target_has_enough: 'That target already has as many contracts on them as '
      + 'this server allows. Wait for one of them to close.',
    target_just_on: 'They have only just come online. Give them a few minutes.',
    target_too_new: 'They are too new to the city to be a target yet.',
    target_just_up: 'They have only just got back on their feet. Give it a moment.',
    target_recently_on: 'There was a contract on them very recently. There is a '
      + 'cooling-off period before another one.',
    insufficient_funds: 'You do not have that.',
    invalid_reward: 'That reward does not add up.',
    invalid_input: 'Check what you entered.',
    server_error: 'Something broke on the server, not on your end. '
      + 'An admin can see what in the server console.',
    not_participant: 'That is not yours.',
    already_settled: 'That contract is closed.',
    // The rules are on the server and the numbers are configurable, so the
    // words carry what the settings say rather than figures hardcoded here.
    no_kill_to_verify: 'No kill on this contract is waiting for proof. Take '
      + 'the target down, then photograph them where they fell \u2014 within '
      + 'a few metres, and before they are back on their feet for long.',
    // Not a fault. The poller stops on this and says the handover ended.
    no_handover: 'That handover is not running.',
    token_invalid: 'Verification expired. Take the photo again.',
    photo_rejected: 'The photo was not accepted.',
    photo_too_far: 'You are too far from the body. Stand over them and take it again.',
    photo_revived: 'They were brought back before you sent the photo, so this is '
      + 'not an elimination any more.',
    photo_bad_host: 'That image host is not on this server\u2019s allow list. '
      + 'An admin sets which hosts the camera may upload to.',
    bad_state: 'Not right now.',

    /* The six ways a buyout is refused. They shared bad_state — "Not right
       now" — which is wrong for four of them: three will never work however
       long you wait, and one of them means it IS working. This is the one
       move a target has. */
    bailout_off: 'This server does not offer buyouts.',
    no_buyout_price: 'The client did not put a price on closing this one. '
      + 'There is nothing to pay.',
    buyout_pending: 'You have already paid. It closes shortly — a hunter is '
      + 'engaged, so it is not instant.',
    incapacitated: 'Not from the floor. Get up first.',
    handover_in_progress: 'Somebody has hold of you. You cannot buy your way '
      + 'out of a handover already under way.',
    locked: 'Someone got there first.',
    not_found: 'Gone.',
    // The player closed the camera themselves. They know; saying so is
    // telling them what they just did.
    cancelled: null,
    // The phone has no camera this resource can drive. Nothing the hunter
    // can do about it, so it says who can.
    camera_unavailable: 'This phone cannot open the camera for the app. Tell '
      + 'an admin — the server\u2019s phone resource is missing the camera '
      + 'component this needs.',
    // Distinct from cancelling: the camera was asked for and never came
    // back. Before this had its own code it answered as a cancel, which the
    // page is deliberately silent about — so two minutes after a tap that
    // said nothing, nothing else was said either.
    /* Not "try again". The client gives up on the camera a full proof
       window after it opened, and the server's claim on the kill runs out
       that long after the death, which was earlier — so by the time this is
       said there is never a kill left to claim. "Try again" sent the hunter
       straight into "No kill on this contract is waiting for proof". */
    camera_no_answer: 'The camera never came back, and the time to verify '
      + 'this kill has run out. Nothing was sent.',
    no_token: 'Nothing to verify yet.',
    timeout: 'No answer. Try again.',
    unreachable: 'No answer. Try again.'
  };

  /* ---------- dialogs ----------
     FiveM's NUI is a CEF browser with no dialog handler: window.confirm and
     window.prompt are never shown, confirm resolves false and prompt null.
     Every action gated behind one would silently do nothing, which is
     indistinguishable from the player declining. These render in-page. */

  function ask(question, detail, onYes) {
    state.dialog = { kind: 'confirm', question: question, detail: detail, onYes: onYes };
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
  function askFields(question, detail, fields, onValues) {
    state.dialog = {
      kind: 'fields', question: question, detail: detail,
      fields: fields, onValues: onValues
    };
    render();
  }

  function closeDialog() {
    state.dialog = null;
    render();
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
        var choose = document.createElement('select');
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

      var input = document.createElement('input');
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
      nodes[spec.id] = input;
      panel.appendChild(labelled(spec.label, input));
    });

    var row = el('div', 'row');
    var yes = el('button', 'primary', d.confirmLabel || 'Save');
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
      var handler = d.onValues;
      state.dialog = null;
      render();
      if (handler) handler(values);
    };
    var no = el('button', 'ghost', 'Cancel');
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

      input = document.createElement('input');
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
         hunter accepts somewhere, the box reads 30 again and Extend sends
         30. */
      if (d.value !== undefined) {
        input.value = d.value;
      } else if (opts.value !== undefined && opts.value !== null) {
        input.value = String(opts.value);
      }

      // Named, because a bare box in a dialog is the player guessing what
      // the number is measured in.
      panel.appendChild(labelled(opts.label || 'Amount', input));

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
    var yes = el('button', 'primary', d.kind === 'number'
      ? ((d.opts && d.opts.confirm) || 'Confirm') : 'Yes');
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
            ? ('Enter something between ' + floor + ' and ' + bounds.max + '.')
            : ('Enter ' + floor + ' or more.');
          return;
        }
      }

      state.dialog = null;
      render();
      if (handler) handler();
      if (valueHandler && value && value > 0) valueHandler(value);
    };
    var no = el('button', 'ghost', 'Cancel');
    no.onclick = closeDialog;
    row.appendChild(yes);
    row.appendChild(no);
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
      } else {
        row.appendChild(button);
      }
    });

    var cancel = el('button', 'ghost', 'Cancel');
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

  // Fetches issued by the render now in progress. Every mugshot() call
  // happens inside one synchronous render, so the counter reaches its peak
  // before the first reply arrives and hits zero exactly once — one redraw
  // for a whole page of faces, not one per face.
  var facesInFlight = 0;

  // The cached image for a reference, fetching it the first time it is seen.
  // Returns nothing while a fetch is in flight; the card simply renders
  // without a face, which is what it does before the first render anyway.
  function mugshot(id) {
    if (!id) { return null; }
    if (state.images[id] !== undefined) { return state.images[id]; }

    // Marked as in flight before the request goes out, so a page of rows
    // naming the same target asks once rather than once per row.
    state.images[id] = null;
    facesInFlight++;
    post('mugshotImage', { id: id }).then(function (r) {
      // A reference that no longer resolves — the target re-rendered, or the
      // entry was dropped. The null stays, so we do not ask again for this
      // reference; the next projection carries a new one.
      if (r.ok && r.data && r.data.image) {
        state.images[r.data.id] = r.data.image;
      }
      facesInFlight--;
      if (facesInFlight === 0) { render(); }
    });
    return null;
  }

  function say(message, kind) {
    state.notice = { message: message, kind: kind || 'red' };
    renderNotice();
    setTimeout(function () { state.notice = null; renderNotice(); }, 4000);
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
    slot.appendChild(el('div', 'notice' + (state.notice.kind === 'gold' ? ' gold' : ''),
      state.notice.message));
  }

  function fail(result) {
    // A null entry means the player did this on purpose; saying anything
    // would read as a failure.
    if (result.err in ERRORS && ERRORS[result.err] === null) return;

    // A wait the player can act on. "Slow down" alone reads as a broken
    // button, because tapping again says exactly the same thing.
    if (result.err === 'rate_limited' && result.data && result.data.retryAfter) {
        var wait = result.data.retryAfter;
        return say(wait >= 60
          ? 'Slow down — try again in about ' + Math.ceil(wait / 60) + ' minute'
            + (wait >= 120 ? 's' : '') + '.'
          : 'Slow down — try again in ' + wait + ' second' + (wait === 1 ? '' : 's') + '.');
    }

    say(ERRORS[result.err] || 'Something went wrong.');
  }

  /* ---------- actions already running ----------------------------------

     Not one button in this app had a busy state. Every action was
     post(...).then(...), the screen was identical for the whole round trip,
     and the button stayed live throughout — so the honest reading of a tap
     that appears to do nothing is to tap it again.

     What that cost, by action: a second contract placed and a second escrow
     charged; a second photo token minted, invalidating the one the photo
     already in flight was taken against; two of three photo attempts spent
     before the hunter had seen a single answer; an amendment answered twice,
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
     so the answer to "did my tap register" is on the button itself. */
  function actionButton(className, label, key, busyLabel, work) {
    var button = el('button', className, isBusy(key) ? (busyLabel || label) : label);
    if (isBusy(key)) {
      button.disabled = true;
      button.classList.toggle('is-busy', true);
      return button;
    }
    button.onclick = function () { once(key, work); };
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

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  /* A label on a card. `icon` names one of the line icons app.css draws
     (i-flag, i-users, ...). The stylesheet paints it as a mask before the
     words rather than anything being written into the page, so the chip's
     text — the only thing a screen reader or a test reads — is exactly what
     it was without one. */
  function chip(text, variant, icon) {
    return el('span', 'chip' + (variant ? ' ' + variant : '')
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
    cell.appendChild(el('span', 'stat-value', value));
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
    var node = el('div', 'card' + (contract.targetProtected ? ' is-protected' : ''));

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
    who.appendChild(el('div', 'reason', contract.reason || '—'));
    left.appendChild(who);
    head.appendChild(left);

    // One row that lost its reward costs that row, not the tab. render()
    // clears the view before it draws, so a throw in here leaves the whole
    // board — or Mine, or On me, card() draws all three — blank, taking
    // every good row after this one with it.
    var paid = contract.reward || {};

    var reward = el('div', 'reward');
    reward.appendChild(el('div', 'amount', money(paid.baseline)));
    if (paid.bonus > 0) {
      reward.appendChild(el('div', 'bonus', '+' + money(paid.bonus) + ' alive'));
    }

    // What the headline figure does not say goes on a line of its own under
    // the head, not in the stamp's column. In the column, the longest item
    // list set the column's width, and the target's name was squeezed to a
    // few letters a line — on exactly the contracts that pay the most.
    var notes = el('div', 'reward-notes');

    // How much of that is black money, when any of it is.
    //
    // The headline is one figure covering all three money sources, and they
    // are not worth the same: black money sells for a fraction of its face
    // value. A hunter looking at "$250,000" could be looking at a quarter of
    // a million black_money items with no way to tell.
    var dirtyPart = (paid.sources && paid.sources.dirty || 0)
      + (paid.bonusSources && paid.bonusSources.dirty || 0);
    if (dirtyPart > 0) {
      notes.appendChild(el('div', 'hint ico i-coin',
        money(dirtyPart) + ' of it is black money'));
    }

    // Goods are not priced — nobody can defend a number for a kitted rifle —
    // but a contract paying one and nothing else read as $0.
    var goods = goodsLine(paid.goods);
    if (goods) { notes.appendChild(el('div', 'goods ico i-box', goods)); }
    var bonusGoods = goodsLine(paid.bonusGoods);
    if (bonusGoods) { notes.appendChild(el('div', 'goods ico i-box', '+ ' + bonusGoods + ' alive')); }
    head.appendChild(reward);
    node.appendChild(head);
    if (notes.children.length) { node.appendChild(notes); }

    var meta = el('div', 'meta');
    meta.appendChild(chip(contract.mode === 'competitive' ? 'Competitive' : 'Exclusive',
      null, contract.mode === 'competitive' ? 'i-flag' : 'i-lock'));

    if (contract.slots > 1) {
      meta.appendChild(chip(
        'Slot ' + contract.currentSlot + ' of ' + contract.slots, 'slots', 'i-layers'));
    }
    if (contract.huntersActive > 0) {
      // Against the cap on a competitive contract, so a hunter can see
      // whether there is room before they tap Accept and are refused. The
      // server has always sent huntersMax and the page never read it.
      var crowd = contract.mode === 'competitive' && contract.huntersMax
        ? contract.huntersActive + ' of ' + contract.huntersMax + ' operatives'
        : contract.huntersActive
          + (contract.huntersActive === 1 ? ' operative' : ' operatives');
      var full = contract.mode === 'competitive'
        && contract.huntersMax
        && contract.huntersActive >= contract.huntersMax;
      meta.appendChild(chip(full ? crowd + ' — full' : crowd, full ? 'warn' : 'hot', 'i-users'));
    }
    if (contract.role === 'creator') {
      // Through asList, like every other list from the server. The projection
      // builds this as a Lua table, and an empty Lua table crosses as {} —
      // which is truthy, so a plain `&& contract.hunters` guard passed and
      // .forEach then threw. That is a contract nobody has taken yet: the
      // state every contract is in the moment it is placed, and it took the
      // whole Mine tab down with it.
      asList(contract.hunters).forEach(function (h) {
        if (h.record) {
          meta.appendChild(chip(h.alias + ' · ' + h.record.standing, null, 'i-user'));
        }
      });
    }
    // What accepting costs, on the listing, before the accept button —
    // §14.18. The server used to send this to the creator alone while
    // acceptance debited it anyway, so the first a hunter knew of a stake
    // was the money leaving their bank.
    if (contract.penaltyAmount > 0) {
      meta.appendChild(chip(money(contract.penaltyAmount) + ' stake', 'warn', 'i-coin'));
    }
    // Only when there is something to say: a row carrying neither drew an
    // empty pill.
    if (contract.creatorAnonymous || contract.creatorName) {
      meta.appendChild(chip(contract.creatorAnonymous ? 'Anonymous client' : contract.creatorName,
        null, 'i-briefcase'));
    }
    if (contract.targetProtected && settings().flagListing !== false) {
      meta.appendChild(chip('Law enforcement', 'warn', 'i-shield'));
    }
    node.appendChild(meta);

    if (contract.targetProtected && context === 'board') {
      node.appendChild(el('div', 'notice gold',
        'This target is a sworn officer. Their department has been advised.'));
    }

    node.appendChild(actionsFor(contract, context));
    return node;
  }

  // "2 items and a weapon", or nothing when a payout is money only.
  function goodsLine(goods) {
    if (!goods) { return null; }

    var parts = [];
    if (goods.items > 0) {
      parts.push(goods.items + (goods.items === 1 ? ' item' : ' items'));
    }
    if (goods.weapons > 0) {
      parts.push(goods.weapons + (goods.weapons === 1 ? ' weapon' : ' weapons'));
    }
    if (parts.length === 0) { return null; }

    return parts.join(' and ')
      + (goods.labels && goods.labels.length ? ' (' + goods.labels.join(', ') + ')' : '');
  }

  /* Why this card cannot be accepted by this viewer, or nothing if it can. */
  function boardHint(contract) {
    if (contract.role === 'creator') {
      return 'Yours \u2014 manage it under Mine.';
    }
    if (contract.role === 'hunter') {
      return 'You are already on this one \u2014 it is under Mine.';
    }
    var active = Number(contract.huntersActive) || 0;
    if (contract.mode === 'exclusive' && active > 0) {
      return 'Taken. Somebody has this one to themselves \u2014 it comes back '
        + 'on the board if they walk away.';
    }
    var cap = Number(contract.huntersMax) || 0;
    if (contract.mode !== 'exclusive' && cap > 0 && active >= cap) {
      return 'Full. It comes back open if an operative drops out.';
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
         viewer's own bounty, so it includes the ones they placed, the ones
         they already hold, and ones somebody else has filled — and every
         one of them drew Accept. Said instead, with where to look. */
      var why = boardHint(contract);
      if (why) {
        row.appendChild(el('div', 'hint', why));
        return row;
      }
      var take = el('button', 'primary', 'Accept contract');
      take.onclick = function () { acceptContract(contract); };
      row.appendChild(take);
      return row;
    }

    if (contract.role === 'hunter') {
      // Two ways to finish, and they share the top line.
      row.className = 'row actions is-hunting';

      // Both through `once`. The camera takes as long as the hunter takes
      // to line up a shot, and until now the button stayed live throughout:
      // a second tap minted a second photo token, which invalidates the one
      // the photo already being uploaded was taken against, and spent a
      // second of the three attempts the rate limit allows — so a hunter
      // could burn their whole allowance before seeing a single answer.
      row.appendChild(actionButton('primary', 'Verify kill',
        'photo:' + contract.id, 'Camera open\u2026',
        function () { return verifyKill(contract); }));

      row.appendChild(actionButton(null, 'Deliver alive',
        'kidnap:' + contract.id, 'Arming\u2026',
        function () { return armKidnap(contract); }));

      // Opening a thread is a round trip that changes nothing on screen
      // until it lands, so the button read as dead and got tapped again.
      //
      // Not drawn at all on a server with the relay switched off: every
      // message sent from it would be refused.
      if (settings().relay !== false) {
        more.appendChild(actionButton('ghost ico i-message', 'Message',
          'thread:' + contract.id, 'Opening\u2026',
          function () { return openThread(contract, null); }));
      }

      var quit = el('button', 'ghost ico i-exit is-destructive', 'Abandon');
      quit.onclick = function () {
        ask('Walk away from this contract?',
            contract.penaltyAmount > 0
              ? 'The client keeps the ' + money(contract.penaltyAmount) + ' you staked.'
              : 'You staked nothing on this one, so it costs you nothing.',
            function () {
              post('abandon', { id: contract.id }).then(function (r) {
                if (!r.ok) return fail(r);
                // A handover being watched on it ends with it. Left running,
                // the poller read that ending as a failed delivery and told
                // a hunter who had just walked away to get the target back
                // to the client and try again.
                if (countdownFor === contract.id) { stopCountdown(); }
                delete state.progress[contract.id];
                say('You are off the contract.');
                refresh();
              });
            });
      };
      more.appendChild(quit);

      // Not on a server with amendments switched off, where every proposal
      // is refused.
      if (settings().amendments !== false) {
        var propose = el('button', 'ghost ico i-swap', 'Propose change');
        propose.onclick = function () { proposeChange(contract); };
        more.appendChild(propose);
      }

      // Live progress if the countdown is running, otherwise the snapshot
      // that came with the projection.
      //
      // Directly under the two ways to finish, above the other tools. The
      // countdown is the one thing on this card that is urgent — a hunter
      // holding somebody is watching it — and it was drawn last, below
      // Message, Propose change and Abandon, a scroll away from the button
      // that started it. A proposal waiting on an answer goes with it.
      var progress = state.progress[contract.id] || contract.kidnapProgress;
      var panel = proposalPanel(contract);
      if (progress) { row.appendChild(countdown(progress)); }
      if (panel) { row.appendChild(panel); }
      return withMore();
    }

    if (contract.role === 'creator') {
      // One button for both directions. "Add to pot" could only ever go up,
      // and a creator who had put up too much had exactly one way down:
      // withdraw the whole contract and place it again. The editor behind
      // this offers both, and says which of them this contract allows.
      // Money, and the thing a creator comes back to this card to do, so it
      // is the card's one crimson button.
      var top = el('button', 'primary', 'Change reward');
      top.onclick = function () { editReward(contract); };
      row.appendChild(top);

      // Only where the server runs them. The block is omitted from the
      // settings entirely when informants are off, so it arrives undefined
      // and never as false — and the guard inside buyInformant tested for
      // false, which nothing could satisfy. The button was drawn, quoted
      // "a fee" because there was no figure to quote, and spent a request
      // to be told the server does not run them.
      if (settings().informant) {
        var buy = el('button', 'ghost ico i-search', 'Buy informant data');
        buy.onclick = function () { buyInformant(contract); };
        more.appendChild(buy);
      }

      // Same shape, same reason: {} has no .length, so this read as "no
      // hunters" whether or not there were any.
      if (asList(contract.hunters).length && settings().relay !== false) {
        more.appendChild(actionButton('ghost ico i-message', 'Threads',
          'threads:' + contract.id, 'Opening\u2026',
          function () { return openThreads(contract); }));
      }

      var extend = el('button', 'ghost ico i-clock', 'Extend deadline');
      extend.onclick = function () { improveContract(contract); };
      more.appendChild(extend);

      // Not on a server with amendments switched off, where every proposal
      // is refused.
      if (settings().amendments !== false) {
        var change = el('button', 'ghost ico i-swap', 'Propose change');
        change.onclick = function () { proposeChange(contract); };
        more.appendChild(change);
      }

      // Only while nobody is holding it. Once a hunter has accepted they
      // accepted it as written, and the server refuses both of these — so
      // offering them would be offering a guaranteed refusal.
      if (!contract.huntersActive) {
        var edit = el('button', 'ghost ico i-pencil', 'Edit');
        edit.onclick = function () { editContract(contract); };
        more.appendChild(edit);

        var scrap = el('button', 'danger ico i-xcircle', 'Withdraw');
        scrap.onclick = function () { cancelContract(contract); };
        more.appendChild(scrap);
      }
      withMore();

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
      // Already paid for, and closing once the delay runs out. Drawn before
      // the buy button so a player who has paid is not offered the same
      // price again on a card identical to the one before their money left.
      if (contract.bailoutPaid) {
        row.appendChild(el('div', 'hint',
          'You have paid to close this. A hunter is engaged, so it is not '
          + 'instant \u2014 it closes shortly and your money is already gone.'));
      } else if (contract.bailoutAvailable) {
        var out = el('button', 'primary danger', 'Buy out \u2014 ' + money(contract.bailoutAmount));
        out.onclick = function () { bailout(contract); };
        row.appendChild(out);
      } else if (settings().buyouts === false) {
        // Not the client's doing. Saying "no buyout was offered" here blamed
        // the one person who had not decided it.
        row.appendChild(el('div', 'hint', 'This server does not offer buyouts.'));
      } else {
        row.appendChild(el('div', 'hint', 'No buyout was offered on this contract.'));
      }
      if (settings().informant) {
        var informant = el('button', 'ghost ico i-search', 'Buy informant data');
        informant.onclick = function () { buyInformant(contract); };
        more.appendChild(informant);
      }
      return withMore();
    }

    return row;
  }

  // Why a hold is slipping, in words a player can act on. The server sends
  // the reason and always has; the app used to render none of it, so a hunter
  // whose delivery was failing had no idea until it did.
  // Every reason Kidnap.conditionsMet can return, and nothing it cannot.
  var BREAKING = {
    party_offline: 'Someone this handover needs has gone offline',
    target_not_conscious: 'Your target must be alive and conscious',
    not_coerced: 'Your target is not restrained',
    target_too_far: 'Your target is too far from you',
    creator_too_far: 'The client is too far away'
  };

  function countdown(progress) {
    var wrap = el('div', 'countdown' + (progress.breaking ? ' is-breaking' : ''));

    var bar = el('div', 'bar');
    var fill = el('i');
    fill.style.width = Math.min(100, (progress.elapsed / progress.required) * 100) + '%';
    bar.appendChild(fill);
    wrap.appendChild(bar);

    wrap.appendChild(el('div', 'label', progress.settling
      ? 'Held long enough — settling the payout…'
      : progress.elapsed + 's of ' + progress.required + 's'));

    // The grace budget is one allowance for the whole countdown, not one per
    // break, so what is left of it is the number that actually matters.
    if (progress.graceTotal > 0) {
      var left = Math.max(0, progress.graceLeft || 0);
      var grace = el('div', 'bar grace');
      var graceFill = el('i');
      graceFill.style.width = Math.min(100, (left / progress.graceTotal) * 100) + '%';
      grace.appendChild(graceFill);
      wrap.appendChild(grace);

      wrap.appendChild(el('div', 'label' + (progress.breaking ? ' warn' : ''),
        progress.breaking
          ? (BREAKING[progress.breaking] || 'Hold position')
              + ' — ' + (left / 1000).toFixed(1) + 's of slack left'
          : (left / 1000).toFixed(1) + 's of slack left'));
    } else if (progress.breaking) {
      wrap.appendChild(el('div', 'label warn',
        BREAKING[progress.breaking] || 'Hold position'));
    }

    return wrap;
  }

  /* ---------- actions ---------- */

  function settings() {
    return (state.board && state.board.settings) || {};
  }

  /* Take a contract back down. Everything staked comes home, and the
     server refuses it outright the moment somebody is hunting it. */
  function cancelContract(contract) {
    ask('Withdraw this contract?',
      'Nobody has taken it, so everything you put up comes back to you. '
        + 'This cannot be undone.',
      function () {
        post('cancel', { id: contract.id }).then(function (r) {
          if (!r.ok) { return fail(r); }
          // Not "everything has been returned" unconditionally. Something
          // that would not fit is owed and handed over later, and the phone
          // notification already says so — this said the opposite at the
          // same moment, which is the case where a player counts their
          // money, finds it short and reports it stolen.
          var queued = (r.data && Number(r.data.queued)) || 0;
          say(queued > 0
            ? 'Contract withdrawn. Some of what you put up would not fit and is '
              + 'waiting for you — it arrives when you next have room.'
            : 'Contract withdrawn. Everything you put up has been returned.', 'gold');
          refresh();
        });
      });
  }

  /* Change a contract nobody has taken. What it pays is not edited here —
     moving escrow is money in and out of a pocket, and that has its own
     screen behind "Change reward", which can both add and take back. */
  function editContract(contract) {
    /* The same reason control the Place form draws, for the same reason.
     *
     * This dialog asked for free text whatever the server took, and always
     * sent it. On a preset server that was refused as invalid_input; on a
     * server storing no reason at all it made the whole edit fail, so the
     * deadline it came with could never be changed either. The rules are
     * the operator's and apply to both ways in. */
    var mode = settings().reasonMode || 'freetext';
    var presets = asList(settings().reasonPresets);
    var fields = [];

    if (mode === 'preset' && presets.length) {
      // Opens on the reason the contract already gives. It opened on no
      // choice at all, which Save read as the first preset — so moving the
      // deadline also replaced the reason with whatever was top of the list.
      var currentPreset = presets.indexOf(contract.reason) + 1;
      fields.push({
        id: 'reasonPreset', label: 'Reason', type: 'select',
        value: currentPreset > 0 ? currentPreset : undefined,
        // One-based, as the server indexes its own list.
        options: presets.map(function (text, i) {
          return { value: i + 1, label: text };
        })
      });
    } else if (mode !== 'off') {
      fields.push({ id: 'reason', label: 'Reason', type: 'text',
                    value: contract.reason || '',
                    max: settings().reasonMaxLength || 140 });
    }

    /* The deadline as it stands, not a fixed three hours.

       The box always opened on 3 and Save always sent it, so a creator who
       opened Edit to fix a word in the reason also moved the deadline to
       three hours from now — cutting a contract with a day left down to
       three hours, with nothing on screen saying the deadline had been
       touched. It opens on what is left, and is sent only if changed. */
    var left = minutesLeft(contract);
    // With no deadline running there is nothing to preserve: the figure in
    // the box is only a suggestion, and Save means it.
    var suggested = left === null || left <= 0;
    var hoursNow = suggested ? 3 : Math.min(48, Math.max(1, Math.ceil(left / 60)));
    fields.push({ id: 'hours', label: 'Hours from now to the deadline',
                  type: 'number', value: hoursNow, min: 1, max: 48 });

    askFields('Edit this contract',
      'Only while nobody has taken it. To change what it pays, use Change '
        + 'reward.',
      fields,
      function (values) {
        var seconds = (values.hours && (suggested || values.hours !== hoursNow))
          ? values.hours * 3600 : 0;
        // A picker left on no choice is no change, not the first preset.
        var preset = parseInt(values.reasonPreset, 10) || 0;
        if (!seconds && values.reason === undefined && !preset) {
          return say('Nothing was changed.');
        }
        // Only whichever field this server actually reads. The dialog draws
        // one or the other or neither, so the rest are undefined and do not
        // survive being encoded — sending the wrong one is how the deadline
        // became unchangeable. Written inline so the payload-shape check can
        // read what this site sends.
        post('revise', {
          id: contract.id,
          deadlineSeconds: seconds > 0 ? seconds : undefined,
          reason: values.reason,
          reasonPreset: preset > 0 ? preset : undefined
        }).then(function (r) {
          if (!r.ok) { return fail(r); }
          say('Contract updated.', 'gold');
          refresh();
        });
      });
  }

  function acceptContract(contract) {
    function take(anonymous) {
      // The stake this player was shown, sent back with the acceptance.
      // The server refuses if it is not the stake on the contract, so the
      // figure on the dialog and the figure debited are the same number by
      // construction rather than by timing.
      post('accept', {
        id: contract.id, anonymous: anonymous,
        penaltyAmount: contract.penaltyAmount || 0
      }).then(function (r) {
        if (!r.ok) {
          // Told and shown. A message saying the figure changed, with the
          // old figure still on screen, is half an answer.
          // Likewise a card that is out of date in some other way: closed,
          // taken, or already theirs. The board is only as fresh as its last
          // read, and leaving the stale card up invites the same tap again.
          if (r.err === 'terms_changed' || r.err === 'already_settled'
              || r.err === 'contract_full' || r.err === 'already_holding') {
            refresh();
          }
          return fail(r);
        }
        say(anonymous ? 'Contract accepted, anonymously.' : 'Contract accepted.', 'gold');
        refresh();
      });
    }

    function chooseAnonymity() {
      state.dialog = {
        kind: 'choice',
        question: 'Take this one anonymously?',
        detail: 'The client will see an operative, not a name.'
          + (contract.penaltyAmount > 0
            ? ' Accepting stakes ' + money(contract.penaltyAmount)
              + ' of yours, returned when you finish and forfeit to the client'
              + ' if you walk away or run out of time.'
            : ''),
        options: [
          { label: 'Anonymously', primary: true, run: function () { take(true); } },
          { label: 'Under my name', run: function () { take(false); } }
        ]
      };
      render();
    }

    if (contract.targetProtected && settings().warnHunter !== false) {
      ask('This contract is on a sworn officer.',
          'Law enforcement has already been advised that someone is coming. Accept anyway?',
          chooseAnonymity);
      return;
    }
    chooseAnonymity();
  }

  function verifyKill(contract) {
    // Returned, so `once` knows when the camera and the upload are done.
    return post('takeVerificationPhoto', { id: contract.id }).then(function (r) {
      if (!r.ok) {
        /* Two codes mean something different on this path than in the shared
           table, and both reach a hunter standing over a body they have just
           photographed.

           target_protected is worded there for the CREATION path — "That
           target cannot be listed right now" — which is a rule about placing
           contracts on people, not about a kill. armKidnap, the other
           fulfilment route, already words the same code correctly for a
           player in the field. This one did not.

           invalid_reward likewise belongs to the Place form. */
        var here = {
          target_protected: 'They only just got up. The kill does not count '
            + 'while they are protected \u2014 wait a moment and try again.',
          rate_limited: 'Too many attempts just now. Wait a few seconds and '
            + 'photograph them again; the kill is still yours to claim.'
        };
        if (here[r.err]) { return say(here[r.err]); }
        return fail(r);
      }

      // Not "Payment released" unconditionally. A reward that includes items
      // or a weapon can be verified and then fail to reach a hunter whose
      // pockets are full: the server queues it and hands it over later,
      // which is right — but the app said the money had been released, so
      // the hunter stood there with nothing and no reason to think anything
      // was owed. The server says which happened; this now reads it.
      var owed = r.data && r.data.pending;
      say(owed
        ? 'Verified. Some of the reward would not fit and is being held for '
          + 'you \u2014 make room and it will be handed over.'
        : 'Verified. Payment released.', 'gold');
      refresh();
    });
  }

  function armKidnap(contract) {
    return post('armKidnap', { id: contract.id }).then(function (r) {
      if (!r.ok) {
        var reasons = {
          target_not_conscious: 'The target must be alive and conscious.',
          not_coerced: 'The target must be restrained or in your vehicle.',
          creator_too_far: 'Get the target to the client.',
          target_too_far: 'Keep the target close.',
          target_protected: 'Leave them a moment — they only just got up.',
          party_offline: 'Everyone has to be online for a handover.',
          limit_reached: 'Too many handovers in progress. Try shortly.'
        };
        return say(reasons[r.err] || ERRORS[r.err] || 'Cannot start the handover.');
      }
      say('Hold position.', 'gold');
      pollCountdown(contract.id);
    });
  }

  /* The one timer in this app, and it had three faults.
  
     It called render() directly, once a second, on whatever view happened to
     be open — so a hunter who armed a handover and then went to the Place
     tab had the whole form torn down and rebuilt under them every second for
     two minutes, losing scroll position each time.
  
     It stopped on any unsuccessful reply and left state.progress alone, so
     the bar froze at its last value and stayed there. The handover ENDING —
     the target broke loose, the hunter wandered off, the grace ran out — is
     an unsuccessful reply, so the most important outcome of a delivery was
     indistinguishable from a dropped packet and neither was ever mentioned.
  
     And nothing cancelled it when the player left the screen, so two of them
     could run at once against different contracts. */
  var countdownTimer = null;
  var countdownFor = null;

  function stopCountdown() {
    if (countdownTimer) { clearInterval(countdownTimer); countdownTimer = null; }
    countdownFor = null;
  }

  function pollCountdown(id) {
    stopCountdown();
    countdownFor = id;

    var deadline = Date.now() + 120000;

    countdownTimer = setInterval(function () {
      if (Date.now() > deadline) {
        stopCountdown();
        delete state.progress[id];
        redraw();
        return;
      }

      post('kidnapProgress', { id: id }).then(function (r) {
        if (r.ok && r.data && r.data.done) {
          // Over, and the server says how. Every ending used to reach this
          // poller the same way — the countdown gone — so a hunter who had
          // just been PAID for a handover was told it had ended and to try
          // again, and one refused at the end was told to try again on a
          // refusal no retry fixes.
          stopCountdown();
          delete state.progress[id];
          handoverEnded(r.data);
          refresh();
          return;
        }
        if (!r.ok || !r.data || r.data.elapsed === undefined) {
          // Over, one way or another. The bar goes rather than freezing,
          // and the player is told — a delivery that simply stops moving is
          // the one thing a hunter holding a target cannot interpret.
          stopCountdown();
          delete state.progress[id];
          say(r.err === 'no_handover' || r.err === 'not_found'
                || r.err === 'bad_state'
            ? 'The handover ended. Get them back to the client and try again.'
            : (ERRORS[r.err] || 'Lost track of the handover.'));
          refresh();
          return;
        }

        // Keep the answer. Rendering from the projection's snapshot draws
        // the same frozen bar every second no matter how often we poll.
        state.progress[id] = r.data;

        // Coalesced, and only where the bar is actually on screen. The
        // countdown is drawn on Mine and On me; redrawing the Place form
        // once a second throws away what the player is typing into it.
        if (state.tab === 'mine' || state.tab === 'onme') { redraw(); }

        // A full bar is not the end. A countdown that has run its course is
        // still reported while its payout waits behind another one being
        // settled, and stopping here left the hunter with a full bar and no
        // word of how it ended. The poll that finds it over carries that
        // (`done` above), and the deadline bounds the rest.
      });
    }, 1000);
  }

  /* What a finished handover means, in words. The server keeps how each
     one ended for a couple of minutes; the phone notification says the same
     thing to a hunter who has closed the app. */
  function handoverEnded(ended) {
    if (ended.outcome === 'paid') {
      return say(ended.pending
        ? 'Delivered. Some of the reward would not fit and is being held for '
          + 'you \u2014 make room and it will be handed over.'
        : 'Delivered. Payment released.', 'gold');
    }
    if (ended.outcome === 'closed') {
      return say('The contract closed before the handover finished.');
    }
    if (ended.outcome === 'refused') {
      var refused = {
        bad_state: 'The contract closed before the handover finished.',
        locked: 'Another payout on this contract was being settled at the same '
          + 'moment, and it got there first.',
        target_protected: 'They had only just got back up, so the handover '
          + 'does not count.'
      };
      return say('The handover finished but was not paid. '
        + (refused[ended.reason] || ERRORS[ended.reason] || ''));
    }
    var failed = {
      party_offline: 'Someone the handover needed went offline.',
      creator_too_far: 'Your client did not arrive in time.',
      target_not_conscious: 'The target went down. A handover has to be alive.',
      contract_locked: 'The contract was stuck settling another payout.'
    };
    return say('The handover failed. ' + (failed[ended.reason]
      || 'You lost hold of the target.') + ' Get them back to the client and '
      + 'try again in a minute.');
  }

  function bailout(contract) {
    ask('Pay ' + money(contract.bailoutAmount) + ' to close this contract?',
        'The client gets their money back along with your payment.',
        function () {
          post('bailout', { id: contract.id }).then(function (r) {
            if (!r.ok) return fail(r);
            say('Paid. The contract closes shortly.', 'gold');
            refresh();
          });
        });
  }

  function buyInformant(contract) {
    var rules = settings().informant;
    // Absent, not false: the projection omits the block rather than sending
    // a flag, so anything comparing against false here was dead code.
    if (!rules) {
      return say('This server does not run informants.');
    }

    // What it costs, said before they agree to pay it. The dialog used to
    // call it "expensive" and leave the player to find the figure out by
    // spending it — on a purchase that is deliberately not refunded.
    var price = rules && rules.cost
      ? money(rules.cost) + ' from your ' + (rules.account === 'cash' ? 'cash' : 'bank')
      : 'a fee';

    var detail = 'It costs ' + price + ', taken now, whether or not it turns '
      + 'anything up.';
    // How many times this contract can be asked at all. The cap is already
    // sent; without it a player has no idea they are on their last one, and
    // finds out by spending it.
    if (rules && rules.maxPerContract) {
      detail += ' An informant will answer about one contract '
        + rules.maxPerContract
        + (rules.maxPerContract === 1 ? ' time in total.' : ' times in total.');
    }
    if (rules && rules.needsProximity) {
      // The single most common reason this "does not work": an operative who
      // accepted and has not gone near the target cannot be named, by
      // design, so the money buys a blank.
      detail += ' An informant can only name an operative who has actually '
        + 'been seen near the target — one who took the contract and has not '
        + 'moved on it yet cannot be found.';
    }

    ask('Buy informant data?', detail, function () { doBuyInformant(contract); });
  }

  function doBuyInformant(contract) {
    post('informant', { id: contract.id }).then(function (r) {
      if (!r.ok) {
        // limit_reached means something else entirely here, and the shared
        // message for it — "You are holding too many contracts" — described
        // a rule that has nothing to do with this purchase.
        var reasons = {
          limit_reached: 'You have already bought everything this informant '
            + 'will tell you about this contract.',
          // The code the server sends. This was keyed `insufficient`, which
          // nothing sends, so the purchase fell through to the Place form's
          // "You do not have that."
          insufficient_funds: 'You cannot afford the informant.',
          not_participant: 'This is not yours to ask about.',
          bad_state: 'This server does not run informants.'
        };
        if (reasons[r.err]) { return say(reasons[r.err]); }
        return fail(r);
      }

      // One branch, because the server sends one shape. The page used to
      // read a `found` flag and print "Nobody has been seen near the
      // target", which handed a target a reliable answer to "is anyone on
      // me?" for the price of the premium — the paid oracle §14.29 exists
      // to close. An informant who could not put a name to anyone reads
      // the same whether that is because there was nobody or because the
      // operative is not somewhere they could be described.
      say('Informant: ' + ((r.data && (r.data.name || r.data.description))
        || 'Unknown operative'), 'gold');
    });
  }

  // Improvements apply at once: they can only benefit the hunter.
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
      return 'Give back collection ' + ((p && p.slot) || '?')
        + ', returning what funds it to the client';
    },
    shorten_deadline: function (p) {
      return 'Shorten the deadline'
        + (p && p.seconds ? ' by ' + Math.round(p.seconds / 60) + ' minutes' : '');
    },
    raise_penalty: function (p) {
      return 'Raise the failure stake' + (p && p.amount ? ' to ' + money(p.amount) : '');
    },
    change_mode: function (p) {
      return 'Change this to a ' + ((p && p.mode) === 'exclusive'
        ? 'single-hunter contract' : 'competitive contract');
    },
    change_reason: function (p) {
      return 'Change the stated reason' + (p && p.reason ? ' to "' + p.reason + '"' : '');
    },
    /* Both kinds end the whole contract. The server applies an agreed
       `withdraw` exactly as it applies `cancel` — the contract closes for
       everyone on it and the escrow goes back to the client — and this read
       "Withdraw from this contract", which a client and every other
       operative read as one operative stepping away. Agreeing to that
       closed the contract under all of them, and cost the client a
       two-hour wait before they could list the same person again. */
    withdraw: function () {
      return 'Call the whole contract off — it closes for everyone on it, '
        + 'and what the client put up goes back to them';
    },
    cancel: function () {
      return 'Cancel this contract outright — it closes for everyone on '
        + 'it, and what the client put up goes back to them';
    }
  };

  function describeAmendment(proposal) {
    var describe = AMENDMENT[proposal.kind];
    // An unknown kind is still shown, because a proposal nobody can read is
    // a proposal nobody can refuse.
    return describe ? describe(proposal.payload) : 'A change to this contract';
  }

  function loadProposals(contract) {
    post('amendments', { id: contract.id }).then(function (r) {
      if (!r.ok) { return fail(r); }
      state.proposals[contract.id] = asList(r.data);
      // One per contract on the page. Redrawing for each meant a screen of
      // five contracts redrew five times, on top of the three from the
      // refresh that asked for them.
      redraw();
    });
  }

  function answerProposal(proposal, approve) {
    return post('respondAmendment', { id: proposal.id, approve: approve }).then(function (r) {
      if (!r.ok) { return fail(r); }
      var outcome = r.data && r.data.outcome;
      say(outcome === 'applied' ? 'Agreed — the change is in effect.'
        : outcome === 'declined' ? 'Declined.'
        : 'Recorded. Waiting on the other party.', 'gold');
      state.proposals = {};
      refresh();
    });
  }

  // The panel under a card: everything currently on the table, and the two
  // buttons that answer it.
  function proposalPanel(contract) {
    var open = state.proposals[contract.id];
    if (!open || open.length === 0) { return null; }

    var box = el('div', 'proposals');
    open.forEach(function (proposal) {
      var item = el('div', 'proposal');
      item.appendChild(el('div', 'what', describeAmendment(proposal)));
      item.appendChild(el('div', 'who',
        proposal.mine ? 'Your proposal' : proposal.proposer + ' proposed this'));

      var waiting = Number(proposal.waiting) || 0;
      if ((proposal.mine || proposal.answered) && waiting === 0) {
        /* Nobody else has to agree, so it is this player's answer that
           applies it — the server applies a proposal on the last answer it
           needs, and with nobody else on the contract that answer is theirs.
           It was drawn as "Waiting to be applied." with nothing to press, so
           it sat until it lapsed, held the contract's one open slot
           meanwhile, and was then put to the next hunter to accept. */
        item.appendChild(el('div', 'hint',
          'Nobody else is on this contract to agree, so it is yours to apply.'));
        var applyRow = el('div', 'row');
        applyRow.appendChild(actionButton('primary', 'Apply it',
          'amend:' + proposal.id, 'Sending…',
          function () { return answerProposal(proposal, true); }));
        item.appendChild(applyRow);
      } else if (proposal.mine || proposal.answered) {
        item.appendChild(el('div', 'hint', 'Waiting on ' + waiting
              + (waiting === 1 ? ' other party.' : ' other parties.')));
      } else {
        // Both keyed on the proposal, so answering it disables BOTH — a
        // second tap on either used to send a second answer, and the reply
        // to that one reports the change that actually applied as "Gone."
        var row = el('div', 'row');
        row.appendChild(actionButton('primary', 'Agree',
          'amend:' + proposal.id, 'Sending\u2026',
          function () { return answerProposal(proposal, true); }));
        row.appendChild(actionButton('danger', 'Decline',
          'amend:' + proposal.id, 'Sending\u2026',
          function () { return answerProposal(proposal, false); }));
        item.appendChild(row);
      }

      box.appendChild(item);
    });

    return box;
  }

  // Propose a change that needs the other party's agreement, as opposed to
  // `improve`, which applies at once because it can only help them.
  /* What a contract pays right now, as a number. */
  function rewardTotal(contract) {
    var reward = contract.reward || {};
    return (Number(reward.baseline) || 0) + (Number(reward.bonus) || 0);
  }

  /* Minutes left on the clock, or null when there is no deadline to read. */
  function minutesLeft(contract) {
    if (!contract.deadline) { return null; }
    var seconds = contract.deadline - Math.floor(Date.now() / 1000);
    return seconds > 0 ? Math.floor(seconds / 60) : 0;
  }

  /* "runs out in 2h", or what to say instead when there is no clock. The
     no-deadline case used to be spliced into the same sentence and read
     "runs out in no set deadline". */
  function runsOut(minutes) {
    if (minutes === null || minutes === undefined) { return 'has no deadline'; }
    if (minutes <= 0) { return 'has run out'; }
    return 'runs out in ' + durationText(minutes);
  }

  function durationText(minutes) {
    if (minutes === null || minutes === undefined) { return 'no set deadline'; }
    if (minutes <= 0) { return 'no time left'; }
    if (minutes < 60) { return minutes + ' minutes'; }
    var hours = Math.floor(minutes / 60);
    var rest = minutes % 60;
    return hours + 'h' + (rest ? ' ' + rest + 'm' : '');
  }

  /* Propose a change to a contract already under way.
     
     Both sides have to agree, so both sides need to be able to read what is
     being proposed. This used to be three bare labels and, behind two of
     them, an empty number box asking "By how much?" — with no statement of
     what the reward was, what the deadline was, or whether the figure meant
     "by" or "to". A creator and a hunter were each being asked to commit to
     a change neither could see the shape of. */
  function proposeChange(contract) {
    var hunter = contract.role === 'hunter';
    // Nobody holds it: there is nobody to agree, and the creator's own
    // confirmation applies it (sendProposal). Said so, rather than "if the
    // operative agrees" about an operative who does not exist.
    var untaken = !hunter && !(Number(contract.huntersActive) > 0);
    var pot = rewardTotal(contract);
    var left = minutesLeft(contract);

    // Payouts still to come after the one being competed for. Only those can
    // be given back, so only those are worth offering.
    var total = Number(contract.slots) || 1;
    var current = Number(contract.currentSlot) || 1;
    var spare = Math.max(0, total - current);

    var options = [
      {
        label: 'Shorten the deadline',
        note: 'It ' + runsOut(left) + ' now.',
        // Nothing to shorten without a deadline, or with a minute left.
        skip: left === null || left <= 1,
        run: function () {
          if (left === null || left <= 1) {
            return say('There is no deadline left to shorten.');
          }
          askNumber('Shorten the deadline',
            hunter
              ? 'You are asking the client for less time than you have.'
              : (untaken ? 'Nobody has taken it, so this applies at once.'
                         : 'You are asking the operative to finish sooner.'),
            function (minutes) {
              sendProposal(contract, 'shorten_deadline', { seconds: minutes * 60 });
            },
            {
              label: 'Cut it short by (minutes)',
              value: Math.min(30, left - 1), min: 1, max: left - 1,
              confirm: untaken ? 'Shorten' : 'Propose',
              hint: function (value) {
                if (!value || value < 1 || value > left - 1) {
                  return 'Between 1 and ' + (left - 1) + ' minutes.';
                }
                return 'It would then run out in ' + durationText(left - value) + '.';
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
           nobody hunting has the direct route instead: Change reward. */
        /* The last one only. The collections are a sequence the contract
           walks through, so one out of the middle would renumber everything
           after it — the server refuses that, and this used to offer any
           later collection in a number box and let the other party find
           out by pressing Agree. There is nothing to choose, so nothing is
           asked. */
        label: 'Give back the last payout',
        note: spare > 0
          ? 'Collection ' + total + ' of ' + total + ', leaving ' + (total - 1) + '.'
          : 'Nothing after the one being competed for.',
        skip: spare <= 0,
        run: function () {
          ask('Give back collection ' + total + ' of ' + total + '?',
            (hunter
              ? 'You are offering to give up the last collection still to '
                + 'come. What is on the table now is untouched.'
              : 'This returns the last collection to you. The one being '
                + 'competed for now is untouched.')
              + ' ' + (total - 1) + ' would remain.',
            function () {
              sendProposal(contract, 'reduce_reward', { slot: total });
            });
        }
      },
      {
        label: hunter ? 'Call it off' : 'Cancel the contract',
        // Not "hand it back": agreed, this closes the whole contract for
        // everyone on it, the same as the client cancelling it. Walking away
        // alone is Abandon.
        note: hunter
          ? 'Ask for the whole contract to be cancelled. If everyone agrees it '
            + 'closes for all of you, the client gets back what they put up, '
            + 'and your stake comes back to you. To leave on your own, use '
            + 'Abandon.'
          : (untaken
            ? 'Nobody has taken it, so it closes now and what you put up comes back.'
            : 'Close it and take back what you put up, if the operative agrees.'),
        run: function () {
          sendProposal(contract, hunter ? 'withdraw' : 'cancel', {});
        }
      }
    ];

    state.dialog = {
      kind: 'choice',
      question: 'Propose a change',
      // The terms, in the header rather than on one option. What the
      // contract pays and how long is left is what every one of these
      // choices is about, and it should not disappear because the option
      // that happened to carry it does not apply here.
      detail: 'Pays ' + money(pot) + ', ' + runsOut(left)
        + (total > 1 ? ', ' + total + ' collections' : '')
        + (!hunter && !(Number(contract.huntersActive) > 0)
          // Nobody holds it, so there is nobody to wait for.
          ? '. Nobody has taken it, so this applies as soon as you confirm.'
          : '. Nothing happens until '
            + (hunter ? 'the client' : 'the operative') + ' agrees.'),
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
          limit_reached: 'There is already a change waiting on this contract. '
            + 'It has to be answered, or run out, before you can propose '
            + 'another.',
          invalid_input: 'That change no longer fits this contract \u2014 it '
            + 'has moved on since you opened it. Look again.',
          bad_state: 'This contract cannot be changed right now.'
        };
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
      if (contract.role === 'creator' && !(Number(contract.huntersActive) > 0)
          && r.data && r.data.id) {
        return answerProposal({ id: r.data.id }, true);
      }
      say('Proposed. The other party has to agree.', 'gold');
      state.proposals = {};
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
    var left = minutesLeft(contract);
    var standing = (left === null)
      ? 'This contract has no deadline set.'
      : (left > 0
          ? 'It currently has ' + durationText(left) + ' left.'
          : 'Its deadline has already passed.');

    /* It opened on an empty box, with no ceiling and no hint — so Confirm,
       the obvious first tap, did nothing and said nothing. It now opens on
       a sensible figure, is held to what the server will take, and says
       what the deadline would become. */
    var ceiling = Number(settings().deadlineMaxMinutes) || 0;
    askNumber('Extend the deadline by how many minutes?',
              standing + ' This applies at once \u2014 it can only help '
              + 'whoever is hunting.',
              function (minutes) {
                post('improve', {
                  id: contract.id,
                  kind: 'extend_deadline',
                  payload: { seconds: minutes * 60 }
                }).then(function (r) {
                  if (!r.ok) return fail(r);
                  say('Deadline extended.', 'gold');
                  refresh();
                });
              },
              {
                label: 'Extra minutes',
                value: ceiling > 0 ? Math.min(30, ceiling) : 30,
                min: 1,
                max: ceiling > 0 ? ceiling : undefined,
                confirm: 'Extend',
                hint: function (value) {
                  if (!value || value < 1 || (ceiling > 0 && value > ceiling)) {
                    return ceiling > 0 ? 'Between 1 and ' + ceiling + ' minutes.'
                                       : 'At least 1 minute.';
                  }
                  return 'It would then run out in '
                    + durationText(Math.max(left || 0, 0) + value)
                    + ', or at the contract\u2019s own time limit if that is sooner.';
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
          ? 'Asked too fast. Try again in a moment.'
          : 'Could not read what this contract is holding.';
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
    var text = what + ' — ' + (line.portion === 'bonus' ? 'bonus' : 'base');
    if ((Number(slots) || 1) > 1) {
      text = 'Collection ' + (Number(line.slot) || 1) + ': ' + text;
    }
    return text;
  }

  function renderRewardEditor(view) {
    var edit = state.reward;
    var panel = el('div', 'card dialog');
    panel.appendChild(el('div', 'target', 'Change the reward'));

    if (!edit) { closeDialog(); return; }

    var total = el('div', 'hint');

    /* Rewritten in place rather than by redrawing the dialog: a redraw
       rebuilds every checkbox, and rebuilding a checkbox the player is
       still tapping through is how a tick lands on the wrong row. */
    function showTotal() {
      // Not named `money`: that is the formatter this function calls two
      // lines below, and shadowing it turned the whole dialog into a
      // TypeError the moment anything was ticked.
      // Dirty money counted apart from clean. Adding them into one figure
      // says a creator is getting back "$7,000" when three of it is black
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

      if (!amount && !dirty && !goods) {
        total.textContent = 'Nothing ticked yet.';
        return;
      }

      var parts = [];
      if (amount) { parts.push(money(amount)); }
      if (dirty) { parts.push(money(dirty) + ' black money'); }
      if (goods) { parts.push(goods + (goods === 1 ? ' item' : ' items')); }
      total.textContent = 'Coming back to you: ' + parts.join(' and ') + '.';
    }

    if (edit.pending) {
      panel.appendChild(el('div', 'reason', 'Reading what this contract is holding…'));
    } else if (edit.failed) {
      panel.appendChild(el('div', 'reason', edit.failed));
    } else if (edit.data) {
      var lines = asList(edit.data.lines);

      if (edit.data.reason) {
        panel.appendChild(el('div', 'reason', edit.data.reason));
      } else {
        panel.appendChild(el('div', 'reason',
          'Tick anything you want back. The rest stays on the contract.'));
      }

      if (!lines.length) {
        panel.appendChild(el('div', 'hint', 'Nothing here can be taken back.'));
      }

      var list = el('div', 'reward-lines');
      lines.forEach(function (line, index) {
        // `toggle` is the existing styled checkbox row: same tap target,
        // same drawn box. A second look for the same control would be a
        // second thing to keep in step.
        var row = el('label', 'toggle reward-line');

        if (line.id) {
          var box = document.createElement('input');
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

    if (edit.data && !edit.pending) {
      var take = el('button', 'primary', 'Take back what I ticked');
      take.onclick = function () { withdrawChosen(edit); };
      row.appendChild(take);
    }

    // Adding is offered from the same screen whether or not taking back is
    // allowed: a contract somebody is hunting can still be sweetened, and
    // that is exactly when a creator wants to.
    var add = el('button', 'ghost ico i-plus', 'Add cash');
    add.onclick = function () {
      var contract = edit.contract;
      state.dialog = null; state.reward = null;
      addEscrow(contract);
    };
    row.appendChild(add);

    var close = el('button', 'ghost', 'Done');
    close.onclick = function () { state.reward = null; closeDialog(); };
    row.appendChild(close);

    panel.appendChild(row);
    view.appendChild(panel);
  }

  function withdrawChosen(edit) {
    var ids = Object.keys(edit.chosen);
    if (!ids.length) {
      say('Nothing ticked, so nothing was taken back.');
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
          return say('A collection has to keep something in it. To take the '
            + 'whole reward back, use Withdraw \u2014 that closes the contract '
            + 'and returns everything.');
        }
        return fail(r);
      }

      var queued = (r.data && r.data.queued) || 0;
      say(queued
        ? 'Taken off the contract. Some of it could not fit and is waiting '
          + 'for you — it arrives when you next have room.'
        : 'Taken off the contract and returned to you.', 'gold');

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
      return post('rewardOptions', {}).then(function (r) {
        if (!r.ok || !r.data) { return fail(r); }
        state.wallet = r.data;
        addEscrow(contract, r.data);
      });
    }

    var caps = wallet.caps || {};
    var usable = ['cash', 'bank', 'dirty'].filter(function (source) {
      return caps[source + 'Enabled'] !== false && (Number(wallet[source]) || 0) > 0;
    });

    if (!usable.length) {
      return say('You have nothing this server takes as a reward.');
    }

    function amountFrom(source) {
      var held = Number(wallet[source]) || 0;
      var ceiling = Math.min(held, Number(caps[source]) || held);
      askNumber('Add ' + (SOURCE_LABELS[source] || source).toLowerCase()
                  + ' to the reward',
        'It is taken from you now and held with the rest.',
        function (value) {
          var reward = { baseline: {} };
          reward.baseline[source] = value;
          post('addEscrow', { id: contract.id, reward: reward }).then(function (r) {
            if (!r.ok) return fail(r);
            say('Added to the reward.', 'gold');
            state.wallet = null;
            refresh();
          });
        },
        {
          label: 'How much',
          value: Math.min(1000, ceiling), min: 1, max: ceiling,
          confirm: 'Add',
          hint: function (value) {
            if (!value || value < 1 || value > ceiling) {
              return 'Between ' + money(1) + ' and ' + money(ceiling) + '.';
            }
            return 'You hold ' + money(held) + '; '
              + money(held - value) + ' would be left.';
          }
        });
    }

    // One source, straight to the amount. More than one, ask which first.
    if (usable.length === 1) { return amountFrom(usable[0]); }

    state.dialog = {
      kind: 'choice',
      question: 'Add to the reward',
      detail: 'Taken from you now and held with the rest.',
      options: usable.map(function (source) {
        return {
          label: SOURCE_LABELS[source] || source,
          note: 'You hold ' + money(wallet[source]) + '.',
          run: function () { amountFrom(source); }
        };
      })
    };
    render();
  }

  /* Whether `open` is the conversation with this operative on this contract.

     A contract is not a conversation: a creator on a competitive contract
     has one thread per operative. Matching on the contract alone is how a
     message half-typed to one operative was waiting, pre-filled, in the
     next operative's box — and went to them on Send. */
  function threadKey(contract, thread) {
    return (contract && contract.id) + '|' + ((thread && thread.handle) || '');
  }

  function sameThread(open, contract, thread) {
    return !!(open && open.contract)
      && threadKey(open.contract, open.thread) === threadKey(contract, thread);
  }

  /* What a thread that can no longer be read means, in words. The shared
     table says "That is not yours." for not_participant, which is what the
     creator of a contract that has just closed was told on every push,
     sitting in front of a conversation they had been part of a moment ago. */
  var THREAD_GONE = {
    already_settled: 'That contract has closed, and its conversation closed '
      + 'with it.',
    not_participant: 'That conversation is no longer open — the contract '
      + 'has ended or the operative is no longer on it. If the contract is '
      + 'still running, open it again from Mine.'
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
  function openThread(contract, thread) {
    // Whatever is half-typed survives re-reading the thread. Re-reading is
    // what happens after every send and on every push, so without this the
    // box emptied itself under anyone composing a second message.
    //
    // The same thread only — the same operative on the same contract — so a
    // draft never follows the player into a conversation with somebody else.
    var keep = state.drafts[threadKey(contract, thread)] || '';

    return post('readThread', { id: contract.id, thread: thread ? thread.handle : null })
      .then(function (r) {
        if (!r.ok) {
          if (leaveDeadThread(r, contract, thread)) { return; }
          return fail(r);
        }
        state.thread = { contract: contract, thread: thread,
                         messages: asList(r.data), draft: keep };
        state.tab = 'thread';
        render();
      });
  }

  /* A creator picks which operative to talk to; a hunter has only one
     thread.

     The picking is the part that was missing. A competitive contract has a
     thread per operative and the server hands back a handle for each, and
     this opened the first and dropped the rest — so on a contract with three
     operatives, two of them could write to the client and the client had no
     way into either thread. Nothing said so: the first one opened normally,
     and the other messages simply went unanswered. */
  function openThreads(contract) {
    return post('threads', { id: contract.id }).then(function (r) {
      if (!r.ok) return fail(r);
      var threads = asList(r.data);
      if (!threads.length) return say('No operative to talk to yet.');
      if (threads.length === 1) { return openThread(contract, threads[0]); }

      state.dialog = {
        kind: 'choice',
        question: 'Which operative?',
        detail: threads.length + ' operatives are on this contract. Each has '
          + 'a thread of their own, and none of them can see the others.',
        options: threads.map(function (thread) {
          return {
            label: thread.alias || 'Operative',
            note: thread.name || null,
            run: function () { openThread(contract, thread); }
          };
        })
      };
      render();
    });
  }

  function requestCall() {
    var t = state.thread;
    if (!t) { return; }

    post('requestCall', {
      id: t.contract.id,
      thread: t.thread ? t.thread.handle : null
    }).then(function (r) {
      if (!r.ok) { return fail(r); }
      // Say which of the two actually happened. A phone that cannot place
      // the call still gets the other party asked to ring back, and telling
      // the player a call is connecting when none is would be worse than
      // either.
      say(r.data && r.data.placed
        ? 'Calling.'
        : 'They have been asked to call you back.', 'gold');
    });
  }

  function sendMessage(body) {
    if (!body) { return; }
    var t = state.thread;
    return post('sendMessage', {
      id: t.contract.id,
      thread: t.thread ? t.thread.handle : null,
      body: body
    }).then(function (r) {
      // Cleared on success and not before. It used to be emptied the
      // instant Enter was pressed, so a message the server refused — too
      // long, too fast, a thread that had closed — took the player's words
      // with it and left them retyping something they could not see.
      if (!r.ok) {
        if (leaveDeadThread(r, t.contract, t.thread)) { return; }
        return fail(r);
      }
      t.draft = '';
      // Only if it is still what was sent: the player may have started the
      // next message while this one was in flight.
      var key = threadKey(t.contract, t.thread);
      if (state.drafts[key] === body) { delete state.drafts[key]; }
      // A push can have re-read the thread while this was in flight, which
      // replaces state.thread with a copy still holding what was just sent.
      if (sameThread(state.thread, t.contract, t.thread)
          && state.thread.draft === body) {
        state.thread.draft = '';
      }
      // Only if the player is still in this conversation. Reopening it
      // regardless pulled them out of whichever thread they had moved to.
      if (state.tab !== 'thread' || !sameThread(state.thread, t.contract, t.thread)) {
        return;
      }
      return openThread(t.contract, t.thread);
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
    var again = el('button', 'ghost ico i-refresh', 'Try again');
    again.onclick = function () { delete state.loadFailed[section]; refresh(); render(); };
    failed.appendChild(again);
    view.appendChild(failed);
    return true;
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
    view.appendChild(el('div', 'empty is-pending', 'Asking the server…'));
    return true;
  }

  function viewBoard(view) {
    if (drewFailure(view, 'board')) { return; }
    if (drewPending(view, 'board')) { return; }
    var data = state.board;
    var contracts = asList(data && data.contracts);
    if (!data || contracts.length === 0) {
      view.appendChild(el('div', 'empty', 'No contracts on the board.'));
      return;
    }
    contracts.forEach(function (c) { view.appendChild(card(c, 'board')); });
  }

  function viewMine(view) {
    if (drewFailure(view, 'mine')) { return; }
    if (drewPending(view, 'mine')) { return; }
    var data = state.mine || {};
    var any = false;

    var accepted = asList(data.accepted);
    var created = asList(data.created);

    if (accepted.length) {
      any = true;
      view.appendChild(el('h3', 'section', 'Contracts you took'));
      accepted.forEach(function (c) { view.appendChild(card(c, 'mine')); });
    }
    if (created.length) {
      any = true;
      view.appendChild(el('h3', 'section', 'Contracts you placed'));
      created.forEach(function (c) { view.appendChild(card(c, 'mine')); });
    }
    if (!any) view.appendChild(el('div', 'empty', 'Nothing active.'));
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
      view.appendChild(el('div', 'empty', 'Nobody is looking for you. That you know of.'));
      return;
    }
    view.appendChild(el('div', 'notice', 'There is a price on your head.'));
    rows.forEach(function (c) { view.appendChild(card(c, 'onme')); });
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
      stats.appendChild(tally(record.completed, 'completed'));
      stats.appendChild(tally(record.placed, 'placed'));
      stats.appendChild(tally(record.survived, 'survived'));
      if (record.rate !== undefined && record.rate !== null) {
        stats.appendChild(tally(record.rate + '%', 'success'));
      }
      card.appendChild(stats);
      view.appendChild(card);
    }

    if (!rows.length) {
      view.appendChild(el('div', 'empty', 'No history yet.'));
      view.appendChild(buildStamp());
      return;
    }
    rows.forEach(function (row) {
      var node = el('div', 'card');
      // The same face and name as the entry had on the board, so a closed
      // file reads as the one that was open.
      var head = el('div', 'card-identity');
      head.appendChild(portrait(row.target_name || 'Unknown', null));
      var who = el('div', 'identity');
      who.appendChild(el('div', 'target', row.target_name || 'Unknown'));
      who.appendChild(el('div', 'reason', row.reason || ''));
      head.appendChild(who);
      node.appendChild(head);
      var meta = el('div', 'meta');
      meta.appendChild(chip(row.role, 'role', ROLE_ICONS[row.role] || 'i-user'));
      meta.appendChild(chip(row.fulfilment === 'kidnapping' ? 'Delivered alive' : 'Eliminated',
        'hot', row.fulfilment === 'kidnapping' ? 'i-usercheck' : 'i-crosshair'));
      node.appendChild(meta);
      if (row.photo_ref) {
        /* Bounded, and it says what it is while it loads.
        
           This was `width: 100%` and nothing else, pointed at a
           full-resolution photograph on somebody else's CDN. A 1080x1920
           shot rendered 590px tall inside a card 721px tall, on a viewport
           of 720 — one history entry taller than the whole screen. Ten
           entries meant ten simultaneous requests to a remote host and a
           list that reflowed under the player's thumb as each one landed,
           because nothing reserved the space.
        
           A fixed box, the image fitted inside it, the space held from the
           first paint, and a host that does not answer leaves a caption
           rather than a broken-image glyph and a card that shrinks. */
        var frame = el('div', 'proof');
        var img = document.createElement('img');
        img.src = row.photo_ref;
        img.alt = 'Verification photograph';
        img.loading = 'lazy';
        img.onerror = function () {
          frame.classList.toggle('is-missing', true);
          if (img.parentNode) { frame.removeChild(img); }
          frame.appendChild(el('span', 'hint',
            'The proof photograph is no longer on its host.'));
        };
        frame.appendChild(img);
        node.appendChild(frame);
      }
      view.appendChild(node);
    });

    view.appendChild(buildStamp());
  }

  // The icon beside the part a player played in a closed contract.
  var ROLE_ICONS = { hunter: 'i-user', creator: 'i-briefcase', target: 'i-eye' };

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
    var build = (typeof window !== 'undefined' && window.CB_BUILD) || 'unknown';
    var stamp = el('div', 'hint build-stamp', 'Crimson-Bounty build ' + build);
    stamp.onclick = function () { Diag.tapped(); };
    return stamp;
  }

  function viewThread(view) {
    var t = state.thread;
    if (!t) { state.tab = 'mine'; return render(); }

    var row = el('div', 'row thread-head');

    var back = el('button', 'ghost ico i-left', 'Back');
    back.onclick = function () { state.tab = 'mine'; render(); };
    row.appendChild(back);

    /* Who this thread is with. Every message is signed with an alias, but
       the thread itself was never named — so a creator with several
       operatives could not tell which of them they were writing to. */
    var withWhom = t.thread && t.thread.alias
      ? t.thread.alias + (t.thread.name ? ' (' + t.thread.name + ')' : '')
      : (t.contract.role === 'hunter' ? 'The client' : null);
    if (withWhom) {
      row.appendChild(el('div', 'hint', 'With ' + withWhom));
    }

    // The server has always had a call path and nothing reached it, so the
    // whole feature was unreachable from the phone.
    if (settings().calls) {
      var call = el('button', 'ghost ico i-phone', 'Call');
      call.id = 'thread-call';
      call.onclick = function () { requestCall(); };
      row.appendChild(call);
    }

    view.appendChild(row);

    var thread = el('div', 'thread');
    t.messages.forEach(function (m) {
      var msg = el('div', 'msg' + (m.mine ? ' mine' : ''));
      msg.appendChild(el('div', 'who', m.alias));
      msg.appendChild(el('div', null, m.body));
      thread.appendChild(msg);
    });
    view.appendChild(thread);

    /* The compose box.
    
       It was an <input> and nothing else, cleared the instant Enter was
       pressed and rebuilt empty by any render. So: a refused message lost
       the text that was refused, a push landing mid-sentence emptied the
       box under the player, and there was no Send button at all — Enter
       only, on a phone, where whether the on-screen keyboard produces one
       depends on the keyboard. */
    var field = el('div', 'field compose');
    var input = document.createElement('input');
    input.placeholder = 'Say something';
    input.maxLength = 200;
    input.value = t.draft || '';
    input.oninput = function () {
      t.draft = input.value;
      state.drafts[threadKey(t.contract, t.thread)] = input.value;
    };

    // Per conversation, not per contract: a send to one operative must not
    // lock the box in another's thread.
    var busyKey = 'message:' + threadKey(t.contract, t.thread);

    function send() {
      var body = input.value;
      if (!body) { return; }
      once(busyKey, function () { return sendMessage(body); });
    }

    input.onkeydown = function (e) { if (e.key === 'Enter') { send(); } };
    field.appendChild(input);

    var go = el('button', 'primary',
      isBusy(busyKey) ? 'Sending\u2026' : 'Send');
    if (isBusy(busyKey)) { go.disabled = true; }
    else { go.onclick = send; }
    field.appendChild(go);

    view.appendChild(field);
  }

  function viewPlace(view) {
    var form = el('div', 'place-form');

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
    if (state.walletFailed) {
      var failed = el('div', 'card');
      failed.appendChild(el('div', 'hint', state.walletFailed
        + ' Money still works; items and weapons need another look.'));
      var again = el('button', 'ghost ico i-refresh', 'Try again');
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
      if (wcaps.cashEnabled !== false) { meta.appendChild(balance('Cash', money(w.cash))); }
      if (wcaps.bankEnabled !== false) { meta.appendChild(balance('Bank', money(w.bank))); }
      if (wcaps.dirtyEnabled !== false) { meta.appendChild(balance('Dirty', money(w.dirty))); }
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
            // fault the server could have named in one word.
            state.walletFailed = (r.err === 'rate_limited')
              ? 'Reading your pockets too fast. Try again in a moment.'
              : 'Could not read what you are carrying (' + (r.err || 'no reply') + ').';
          }
          redraw();
        });
      }

      // And say so meanwhile. A reply that never comes back — a callback
      // lost on the way to the client — would otherwise leave this branch
      // drawing nothing at all, forever, with no way to ask again.
      var waiting = el('div', 'card');
      waiting.appendChild(el('div', 'hint', 'Reading what you are carrying…'));
      var retry = el('button', 'ghost ico i-refresh', 'Try again');
      retry.onclick = function () { state.walletPending = false; render(); };
      waiting.appendChild(retry);
      form.appendChild(waiting);
    }

    /* Four sheets, in the order a contract is written: who, the job, what
       it pays, and on what terms. This was one column of fifteen controls
       with nothing to say where one decision ended and the next began.
       Only the paper is new — every field, id and draft key, and the order
       they come in, is as it was. */
    var subject = formSection('Subject');
    subject.appendChild(labelled('Target', targetSearch()));
    form.appendChild(subject);

    var job = formSection('The job');

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
      var pick = document.createElement('select');
      pick.id = 'reasonPreset';
      presets.forEach(function (text, i) {
        var opt = document.createElement('option');
        // One-based: the server indexes its own list, and a zero is not a
        // choice it accepts.
        opt.value = String(i + 1);
        opt.textContent = text;
        pick.appendChild(opt);
      });
      job.appendChild(labelled('Reason', drafted(pick, 'reasonPreset', '1')));
    } else if (reasonMode !== 'off') {
      job.appendChild(labelled('Reason',
        drafted(textInput('reason', 'Why?', settings().reasonMaxLength || 140),
                'reason')));
    }

    var mode = document.createElement('select');
    mode.id = 'mode';
    [['exclusive', 'Exclusive — one hunter'],
     ['competitive', 'Competitive — first to finish']].forEach(function (o) {
      var opt = document.createElement('option');
      opt.value = o[0]; opt.textContent = o[1];
      mode.appendChild(opt);
    });
    job.appendChild(labelled('Assignment', drafted(mode, 'mode', 'exclusive')));
    form.appendChild(job);

    var pay = formSection('Payment');

    var slots = drafted(numberInput('slots', 1), 'slots', '1');
    slots.min = 1;
    // The server's ceiling, not a number typed here: raising MaxPayoutSlots
    // in the config used to leave the form refusing to go past five.
    slots.max = (state.wallet && state.wallet.caps && state.wallet.caps.slots) || 5;
    slots.onchange = function () { state.draft.slots = slots.value; renderSlots(); };
    pay.appendChild(labelled('Payouts (how many times it can be collected)', slots));
    var ceilingNote = el('div', 'hint');
    ceilingNote.id = 'slots-ceiling';
    pay.appendChild(ceilingNote);
    pay.appendChild(el('div', 'hint',
      'Every payout is funded and escrowed up front. More hunters may accept than there are ' +
      'payouts — the first to finish are paid.'));

    var slotBox = el('div');
    slotBox.id = 'slots';
    pay.appendChild(slotBox);
    form.appendChild(pay);

    var terms = formSection('Terms');

    // Bounded by the ceiling the server sent, and told to the creator.
    // caps.bonusPercent was computed and shipped and never read, so a figure
    // over the cap reached the server — which clamps it now, and used to
    // drop it to no bonus at all.
    var bonusCap = (state.wallet && state.wallet.caps && state.wallet.caps.bonusPercent) || null;
    var bonusField = drafted(numberInput('bonus', 50), 'bonus', '50');
    if (bonusCap) { bonusField.max = bonusCap; }
    terms.appendChild(labelled(
      'Kidnapping bonus %' + (bonusCap ? ' (up to ' + bonusCap + ')' : ''),
      bonusField));
    terms.appendChild(labelled('Buyout price (0 for none)',
      drafted(numberInput('bailout', 0), 'bailout', '0')));
    terms.appendChild(labelled('Failure penalty (0 for none)',
      drafted(numberInput('penalty', 0), 'penalty', '0')));
    terms.appendChild(el('div', 'hint',
      'A hunter stakes this when they accept, and forfeits it to you if they walk away.'));

    var anon = document.createElement('input');
    anon.type = 'checkbox'; anon.id = 'anon';
    anon.checked = state.draft.anon === true;
    anon.onclick = function () { state.draft.anon = anon.checked; };
    // A label, so the words toggle it too. The box on its own is a twenty
    // pixel target on a phone screen, which is a coin toss.
    var toggle = document.createElement('label');
    toggle.className = 'toggle';
    toggle.htmlFor = 'anon';
    toggle.appendChild(anon);
    toggle.appendChild(el('span', null, 'Place anonymously'));
    terms.appendChild(toggle);
    form.appendChild(terms);

    // Through `once`, because this one charges money. Nothing on screen
    // changed for the whole round trip and the button stayed live, so a
    // second tap placed a second contract and took a second escrow — the
    // most expensive tap in the app, and the one most likely to be made.
    var submit = el('button', 'primary',
      isBusy('create') ? 'Placing\u2026' : 'Place contract');
    submit.id = 'place-submit';
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
    var ceiling = parseInt(state.wallet && state.wallet.caps
      && state.wallet.caps.slots, 10) || 5;
    var count = parseInt(state.draft.slots, 10);
    if (!count || count < 1) { return 1; }
    return Math.min(count, ceiling);
  }

  function renderSlots() {
    var box = document.getElementById('slots');
    if (!box) return;
    var count = payoutCount();

    // Put the clamped figure back in the box, and say why, so what the
    // field shows is what is being built.
    var typed = parseInt(state.draft.slots, 10);
    var note = document.getElementById('slots-ceiling');
    if (typed > count) {
      state.draft.slots = String(count);
      var field = document.getElementById('slots-count');
      if (field) { field.value = String(count); }
      if (note) { note.textContent = 'This server allows at most ' + count + ' payouts.'; }
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
      slot.appendChild(el('h4', null, 'Payout ' + i));

      var caps = (state.wallet && state.wallet.caps) || {};
      var split = el('div', 'split');
      var offered = 0;

      ['cash', 'bank', 'dirty'].forEach(function (source) {
        // A source the server has switched off is not offered. It used to
        // be drawn regardless, with the player's balance printed above it,
        // and the whole contract was then refused with "That reward does not
        // add up" — a message about the numbers, when the numbers were fine
        // and the source was simply not accepted.
        if (caps[source + 'Enabled'] === false) { return; }
        offered++;

        var id = 'slot-' + source + '-' + i;
        var field = drafted(numberInput(id, 0), id, '0');

        // The ceiling the server will enforce, applied here so it is a
        // bounded field rather than a refusal after the fact. It was
        // computed, sent, and never read.
        var ceiling = caps[source];
        if (ceiling) { field.max = ceiling; }

        split.appendChild(labelled(SOURCE_LABELS[source] || source, field));
      });

      if (offered > 0) {
        slot.appendChild(split);
      } else {
        slot.appendChild(el('div', 'hint',
          'This server does not take money as a reward. Items and weapons '
          + 'below, if it takes those.'));
      }

      slot.appendChild(goodsBox(i));
      box.appendChild(slot);
    }
  }

  /* ---------- items and weapons ----------
     The server has escrowed items and weapons since the first commit; this
     is what lets a player reach it. Everything shown comes from the
     server-read inventory in rewardOptions, and every amount is checked
     there again on submit — this only keeps the form honest. */

  function pickedFor(index) {
    if (!state.picked[index]) { state.picked[index] = { items: {}, weapons: {} }; }
    return state.picked[index];
  }

  // How much of an item is already promised across every payout, so the
  // same 3 lockpicks cannot be put into three different payouts.
  function allocatedItem(name) {
    var total = 0;
    Object.keys(state.picked).forEach(function (index) {
      total += state.picked[index].items[name] || 0;
    });
    return total;
  }

  function weaponTaken(slotNumber) {
    return Object.keys(state.picked).some(function (index) {
      return state.picked[index].weapons[slotNumber] !== undefined;
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

    wrap.appendChild(el('h5', 'goods-title', 'Items & weapons'));

    if (!wallet) {
      wrap.appendChild(el('div', 'hint', 'Reading your pockets\u2026'));
      return wrap;
    }

    var caps = wallet.caps || {};
    var items = (caps.itemsEnabled === false) ? [] : asList(wallet.items);
    var weapons = (caps.weaponsEnabled === false) ? [] : asList(wallet.weapons);

    var picked = pickedFor(index);

    // What is already in this payout, each removable.
    var chosen = el('div', 'meta');
    Object.keys(picked.items).forEach(function (name) {
      chosen.appendChild(removable(
        labelOf(items, name) + ' x' + picked.items[name],
        function () { delete picked.items[name]; renderSlots(); }));
    });
    Object.keys(picked.weapons).forEach(function (slotNumber) {
      var weapon = picked.weapons[slotNumber];
      chosen.appendChild(removable(weapon.label + (weapon.serial ? ' #' + weapon.serial : ''),
        function () { delete picked.weapons[slotNumber]; renderSlots(); }));
    });
    if (chosen.children.length > 0) { wrap.appendChild(chosen); }

    if (items.length > 0) { wrap.appendChild(itemPicker(index, items)); }
    if (weapons.length > 0) { wrap.appendChild(weaponPicker(index, weapons)); }

    if (items.length === 0 && weapons.length === 0) {
      wrap.appendChild(el('div', 'hint', goodsAbsenceReason(wallet, caps)));
    }
    return wrap;
  }

  /* Why there is nothing to pick. Never silence: a player who cannot see an
     option assumes it does not exist. */
  function goodsAbsenceReason(wallet, caps) {
    if (wallet.inventoryRead === false) {
      return 'Your inventory could not be read, so items and weapons cannot be '
        + 'offered right now. Money still works. Tell an admin if this keeps happening.';
    }
    if (caps.itemsEnabled === false && caps.weaponsEnabled === false) {
      return 'This server does not take items or weapons as a reward. Money only.';
    }
    if (caps.itemsEnabled === false) {
      return 'This server does not take items as a reward, and you are not '
        + 'carrying a weapon that can be put up.';
    }
    if (caps.weaponsEnabled === false) {
      return 'This server does not take weapons as a reward, and you are not '
        + 'carrying anything else that can be put up.';
    }
    return 'You are not carrying anything that can be put up as a reward. '
      + 'Cash, bank and dirty money above still work.';
  }

  var SOURCE_LABELS = { cash: 'Cash', bank: 'Bank', dirty: 'Dirty money' };

  /* A readable name for something that is no longer in the player's pockets.

     The wallet carries proper labels, but only for what they are carrying
     right now — and everything in escrow is, by definition, not. So the
     wallet is asked first and the raw name is tidied when it cannot answer:
     WEAPON_PISTOL reads as "Pistol", black_money as "Black money". */
  function itemLabel(name) {
    if (!name) { return 'Something'; }

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
    var choose = document.createElement('select');
    choose.id = 'slot-item-' + index;

    // How much of each is still unspoken for, so the quantity field can be
    // bounded to it and the row can say so.
    var spare = {};
    items.forEach(function (item) {
      var free = item.count - allocatedItem(item.name);
      if (free <= 0) { return; }
      spare[item.name] = free;
      var option = document.createElement('option');
      option.value = item.name;
      option.textContent = item.label + '  \u00b7  ' + free + ' spare';
      choose.appendChild(option);
    });
    if (choose.children.length === 0) { return el('div', 'hint', 'Nothing spare left to add.'); }

    var count = numberInput('slot-item-count-' + index, 1);
    count.min = 1;

    var howMany = labelled('How many', count);
    var field = el('div', 'picker');
    field.appendChild(labelled('Item', choose));
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

    var add = el('button', 'ghost ico i-plus', 'Add this item');
    add.id = 'slot-item-add-' + index;
    add.onclick = function () {
      var name = choose.value;
      var free = spare[name] || 0;
      // With the field hidden there is only one sensible answer, and
      // reading a control the player never saw is how a hidden default
      // becomes a silent refusal.
      var wanted = (free <= 1) ? 1 : (parseInt(count.value, 10) || 0);
      if (!name || wanted <= 0) { return say('Choose an item and how many.'); }

      var caps = state.wallet.caps || {};
      var picked = pickedFor(index);
      var held = 0;
      items.forEach(function (item) { if (item.name === name) { held = item.count; } });

      if (allocatedItem(name) + wanted > held) {
        return say('You only have ' + (held - allocatedItem(name)) + ' of those spare.');
      }
      if ((picked.items[name] || 0) + wanted > (caps.maxPerStack || Infinity)) {
        return say('That is more than one payout can hold of a single item.');
      }
      if (picked.items[name] === undefined
          && Object.keys(picked.items).length >= (caps.maxStacks || Infinity)) {
        return say('This payout is already carrying as many kinds of item as it can.');
      }

      picked.items[name] = (picked.items[name] || 0) + wanted;
      renderSlots();
    };

    field.appendChild(add);
    return field;
  }

  function weaponPicker(index, weapons) {
    var choose = document.createElement('select');
    choose.id = 'slot-weapon-' + index;
    weapons.forEach(function (weapon) {
      if (weaponTaken(weapon.slot)) { return; }
      var option = document.createElement('option');
      option.value = String(weapon.slot);
      option.textContent = weapon.label + (weapon.serial ? '  #' + weapon.serial : '');
      choose.appendChild(option);
    });
    if (choose.children.length === 0) { return el('div', 'hint', 'No weapons left to add.'); }

    var add = el('button', 'ghost ico i-plus', 'Add this weapon');
    add.id = 'slot-weapon-add-' + index;
    add.onclick = function () {
      var slotNumber = parseInt(choose.value, 10);
      if (!slotNumber && slotNumber !== 0) { return say('Choose a weapon.'); }

      var caps = state.wallet.caps || {};
      var picked = pickedFor(index);
      if (Object.keys(picked.weapons).length >= (caps.maxWeapons || Infinity)) {
        return say('This payout is already carrying as many weapons as it can.');
      }

      var found = null;
      weapons.forEach(function (weapon) { if (weapon.slot === slotNumber) { found = weapon; } });
      if (!found) { return say('That weapon is no longer in your pockets.'); }

      // Keyed by inventory slot, not by name: two of the same weapon are two
      // different objects, and escrowing one twice would take one and then
      // fail looking for its twin.
      picked.weapons[slotNumber] = found;
      renderSlots();
    };

    var field = el('div', 'picker');
    field.appendChild(labelled('Weapon', choose));
    field.appendChild(add);
    return field;
  }

  // Whether any payout has goods staged on it, as opposed to money only.
  function stagedAnything() {
    return Object.keys(state.picked).some(function (index) {
      var picked = state.picked[index];
      return Object.keys(picked.items).length > 0
        || Object.keys(picked.weapons).length > 0;
    });
  }

  // The chosen goods for one payout, in the shape the server validates.
  function goodsOf(index) {
    var picked = state.picked[index];
    if (!picked) { return { items: [], weapons: [] }; }

    var items = Object.keys(picked.items).map(function (name) {
      return { name: name, count: picked.items[name] };
    });
    var weapons = Object.keys(picked.weapons).map(function (slotNumber) {
      return { name: picked.weapons[slotNumber].name, slot: parseInt(slotNumber, 10) };
    });
    return { items: items, weapons: weapons };
  }

  // The preset the picker is showing, as the one-based index the server
  // indexes its own list by. Null off a preset server.
  function reasonPresetIndex() {
    if (settings().reasonMode !== 'preset') { return null; }
    return parseInt(state.draft.reasonPreset, 10) || 1;
  }

  function submitContract() {
    // From the draft, not the DOM: the sworn-officer confirmation renders a
    // dialog over the form, which empties #view. Reading the controls here
    // meant the first submit always failed and the second submitted nothing.
    var target = state.draft.target || document.getElementById('target-handle').value;
    if (!target) return say('Choose a target.');

    var count = payoutCount();
    var slots = [];
    for (var i = 1; i <= count; i++) {
      // Only sources the creator actually funded are sent. A zero is not a
      // reward, and a contract offering one is rejected server-side — which
      // is why sending all three keys unconditionally made every contract
      // creation fail.
      var baseline = {};
      var cash = num('slot-cash-' + i);
      var bank = num('slot-bank-' + i);
      var dirty = num('slot-dirty-' + i);
      if (cash) baseline.cash = cash;
      if (bank) baseline.bank = bank;
      if (dirty) baseline.dirty = dirty;

      var goods = goodsOf(i);
      if (goods.items.length) baseline.items = goods.items;
      if (goods.weapons.length) baseline.weapons = goods.weapons;

      if (!cash && !bank && !dirty && !goods.items.length && !goods.weapons.length) {
        return say('Payout ' + i + ' has no reward in it.');
      }
      slots.push({ baseline: baseline });
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
    var lines = 0;
    slots.forEach(function (slot) {
      var b = slot.baseline;
      if (b.cash) { lines++; }
      if (b.bank) { lines++; }
      if (b.dirty) { lines++; }
      lines += (b.items || []).length;
      lines += (b.weapons || []).length;
    });
    var maxLines = (state.wallet && state.wallet.caps && state.wallet.caps.maxLines) || Infinity;
    if (lines > maxLines) {
      return say('This contract holds ' + lines + ' separate rewards and this '
        + 'server takes at most ' + maxLines + '. Use fewer payouts, or take '
        + 'some of the items and weapons back out.');
    }

    var protectedTarget = state.draft.targetProtected === true;
    if (protectedTarget && settings().warnCreator !== false && !state.leoConfirmed) {
      ask('That target is a sworn officer.',
          'Placing this will alert every officer on duty, by phone and over dispatch.',
          function () { state.leoConfirmed = true; submitContract(); });
      return;
    }
    state.leoConfirmed = false;

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
      bonusPercent: num('bonus'),
      bailoutAmount: num('bailout'),
      penaltyAmount: num('penalty'),
      anonymous: state.draft.anon === true
    }).then(function (r) {
      if (!r.ok) {
        // The wallet is read once when the tab opens, so a staged weapon's
        // inventory slot can be stale by the time it is submitted. The
        // server refuses rather than substituting a different one — right,
        // but "you do not have that" is unhelpful while the form still
        // shows the thing. Re-read and drop what is no longer there.
        if (r.err === 'insufficient_funds' && stagedAnything()) {
          state.wallet = null;
          state.walletFailed = null;
          state.picked = {};
          say('Your pockets have changed since you opened this. '
            + 'Pick the items and weapons again.');
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
          state.browse.data = null;
          state.browse.pending = null;
          say('That person cannot be picked any more — they may have left '
            + 'the city. The list has been read again; choose who this is for.');
          return render();
        }
        return fail(r);
      }
      say('Contract placed.', 'gold');
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

  // From the draft, so a value survives the form being rebuilt under it.
  function num(id) {
    var raw = state.draft[id];
    if (raw === undefined) {
      var node = document.getElementById(id);
      raw = node && node.value;
    }
    var value = parseInt(raw, 10);
    return (!value || value < 0) ? 0 : value;
  }

  // An input whose value is the draft's, and whose edits go back into it.
  function drafted(input, key, fallback) {
    input.value = state.draft[key] !== undefined ? state.draft[key] : (fallback || '');
    input.oninput = function () { state.draft[key] = input.value; };
    input.onchange = function () { state.draft[key] = input.value; };
    return input;
  }

  function labelled(text, control) {
    var field = el('div', 'field');
    field.appendChild(el('label', null, text));
    field.appendChild(control);
    return field;
  }

  function textInput(id, placeholder, max) {
    var input = document.createElement('input');
    input.id = id; input.placeholder = placeholder || '';
    if (max) input.maxLength = max;
    return input;
  }

  function numberInput(id, value) {
    var input = document.createElement('input');
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

    var input = textInput('target-query', 'Filter by name, or just browse', 32);
    // Seeded from the filter, not from whoever is currently chosen. The two
    // used to be the same box: a rebuild put the chosen name in it while the
    // remembered filter still narrowed the list, so the box read one thing
    // and the results were another — and with a filter that matched nobody,
    // "Nobody else is in the city right now" on a city full of people, with
    // no way to ask again. Who is chosen is said below the list instead.
    input.value = browse.query || '';

    var handle = document.createElement('input');
    handle.type = 'hidden'; handle.id = 'target-handle';
    handle.value = state.draft.target || '';
    handle.dataset.protected = state.draft.targetProtected ? 'true' : 'false';

    var results = el('div', 'target-results');
    var status = el('div', 'hint');

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
      if (allButton) { allButton.className = (browse.scope === 'all') ? 'primary' : 'ghost'; }
      if (nearButton) { nearButton.className = (browse.scope === 'nearby') ? 'primary' : 'ghost'; }
    }

    if (canBrowse) {
      allButton = el('button', 'ghost', 'Everyone');
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
        radius ? 'Within ' + Math.round(radius) + 'm' : 'Near me');
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

    function load() {
      // Each rebuild constructs a fresh picker, and without this every one
      // of them fired its own lookup — the same question several times
      // over, against a rate limit that refills twice a second. The
      // in-flight request answers all of them.
      if (browse.pending === key()) { return; }
      browse.pending = key();

      var mine = ++seq;
      var query = browse.query;

      if (!canBrowse && !canNearby) {
        var minimum = settings().minQueryLength || 3;
        if (query.length < minimum) {
          browse.pending = null;
          results.innerHTML = '';
          show(status, 'Type at least ' + minimum + ' letters of their name.');
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
          if (browse.draw) { browse.draw(browse.data); }
        });
    }

    function refused(r) {
      browse.data = null;
      results.innerHTML = '';
      show(status, r.err === 'rate_limited'
        ? 'Looking too fast. Try again in a moment.'
        // Named for the same reason as the wallet failure above: the code
        // is what an admin needs and the player is the one who can see it.
        : 'Could not read who is online (' + (r.err || 'no reply') + ').');
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

      if (people.length === 0) {
        show(status, input.value
          ? 'Nobody online by that name.'
          : (browse.scope === 'nearby'
              ? 'Nobody is standing near you.'
              : 'Nobody else is in the city right now.'));
        return;
      }

      if (paging && paging.total) {
        show(status, (browse.scope === 'nearby')
          ? (paging.total + (paging.total === 1 ? ' person near you' : ' people near you'))
          : ('Showing ' + people.length + ' of ' + paging.total + ' in the city'));
      } else {
        show(status, people.length + (people.length === 1 ? ' match' : ' matches'));
      }

      people.forEach(function (person) { results.appendChild(personRow(person)); });

      // Paging, only where there is more than one page.
      if (paging && paging.pages > 1) {
        var nav = el('div', 'row pager');
        var back = el('button', 'ghost ico i-left', 'Back');
        back.disabled = paging.page <= 1;
        back.onclick = function () {
          browse.page = paging.page - 1; browse.data = null; browse.pending = null; load();
        };
        var forward = el('button', 'ghost ico ico-end i-right', 'More');
        forward.disabled = paging.page >= paging.pages;
        forward.onclick = function () {
          browse.page = paging.page + 1; browse.data = null; browse.pending = null; load();
        };
        nav.appendChild(back);
        nav.appendChild(el('div', 'page-of',
          'Page ' + paging.page + ' of ' + paging.pages));
        nav.appendChild(forward);
        results.appendChild(nav);
      }
    }

    function personRow(person) {
      var pick = el('button', 'person');
      if (state.draft.target === person.handle) { pick.className = 'person is-chosen'; }

      // The same monogram the contract will carry on the board.
      pick.appendChild(portrait(person.name, null));

      var name = el('span', 'person-name', person.name);
      pick.appendChild(name);

      var tags = el('span', 'person-tags');
      if (person.protected) { tags.appendChild(el('span', 'chip warn ico i-shield', 'Law')); }
      if (person.metres !== undefined && person.metres !== null) {
        tags.appendChild(el('span', 'chip ico i-pin', person.metres + 'm'));
      }
      if (tags.children.length > 0) { pick.appendChild(tags); }

      pick.onclick = function () {
        handle.value = person.handle;
        handle.dataset.protected = person.protected ? 'true' : 'false';
        state.draft.target = person.handle;
        state.draft.targetProtected = person.protected === true;
        state.draft.targetName = person.name;
        // The chosen name stays visible rather than the list vanishing, so
        // the player can see who they picked and change their mind.
        renderPeople([person], null);
        show(status, 'Contract will be placed on ' + person.name + '.');
        if (person.protected) {
          say('That is a sworn officer. Placing this will alert their department.', 'gold');
        }
      };
      return pick;
    }

    wrap.appendChild(input);
    wrap.appendChild(handle);
    wrap.appendChild(status);
    wrap.appendChild(results);

    if (state.draft.targetName) {
      show(status, 'Contract will be placed on ' + state.draft.targetName + '.');
    }

    // Open on the list rather than on an empty box: seeing who is out there
    // is the whole point. A rebuild of the form redraws what was already
    // fetched rather than asking again.
    // Always: on a server with browsing switched off this is what states
    // the minimum name length, rather than leaving an empty box that looks
    // broken until the player guesses how much to type.
    if (browse.data) {
      browse.draw(browse.data);
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
  function render() {
    var drawn = Diag.guard('render:' + state.tab, draw);
    if (drawn !== Diag.FAILED) { return; }

    var view = document.getElementById('view');
    if (!view) { return; }
    view.innerHTML = '';
    view.classList.toggle('has-dialog', false);

    var panel = el('div', 'card');
    panel.appendChild(el('p', 'target', 'This screen could not be drawn.'));
    panel.appendChild(el('p', 'reason',
      'The fault has been sent to the server log. Nothing you did caused it '
      + 'and nothing has been lost.'));

    var row = el('div', 'row');
    var back = el('button', 'primary', 'Back to the board');
    back.onclick = function () {
      state.dialog = null;
      state.tab = 'board';
      render();
    };
    row.appendChild(back);

    var look = el('button', 'ghost', 'What went wrong');
    look.onclick = Diag.toggle;
    row.appendChild(look);

    panel.appendChild(row);
    view.appendChild(panel);
  }

  function draw() {
    var view = document.getElementById('view');
    view.innerHTML = '';

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
      } else {
        renderDialog(view);
      }
      return;
    }

    ({
      board: viewBoard, mine: viewMine, place: viewPlace,
      onme: viewOnMe, ledger: viewLedger, thread: viewThread
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
      state.loaded[section] = true;
      return true;
    }
    state.loadFailed[section] = (r.err === 'rate_limited' && r.data && r.data.retryAfter)
      ? 'Asked too fast. Try again in ' + r.data.retryAfter + ' second'
        + (r.data.retryAfter === 1 ? '' : 's') + '.'
      : (ERRORS[r.err] || 'Something went wrong.');
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
  var loadSeq = { board: 0, mine: 0, ledger: 0 };

  function newestLoad(section) {
    loadSeq[section] += 1;
    var mine = loadSeq[section];
    return function () { return loadSeq[section] === mine; };
  }

  function refresh() {
    var boardIsCurrent = newestLoad('board');
    post('list', { page: 1 }).then(function (r) {
      if (!boardIsCurrent()) { return; }
      if (!loadResult('board', r)) { return; }
      state.board = r.data;
      redraw();
    });

    var mineIsCurrent = newestLoad('mine');
    post('mine', {}).then(function (r) {
      if (!mineIsCurrent()) { return; }
      if (!loadResult('mine', r)) { return; }
      state.mine = r.data;
      redraw();
      // Only for contracts this player is actually party to, and only for
      // ones not already loaded: most contracts have no open proposal and
      // asking about every one of them every refresh would be three
      // requests a card.
      asList(r.data.created).concat(asList(r.data.accepted)).forEach(function (c) {
        if (state.proposals[c.id] === undefined) { loadProposals(c); }
      });
    });
    var ledgerIsCurrent = newestLoad('ledger');
    post('ledger', {}).then(function (r) {
      if (!ledgerIsCurrent()) { return; }
      if (!loadResult('ledger', r)) { return; }
      state.ledger = r.data;
      redraw();
    });
  }

  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (tab) {
    tab.onclick = function () {
      state.tab = tab.dataset.tab;
      state.dialog = null;

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
      }

      render();
      // Opening a tab is when a player expects to see current state.
      if (state.tab === 'board' || state.tab === 'mine' || state.tab === 'onme') refresh();
    };
  });

  // The client mirrors every server reply here as well as resolving the
  // fetch that asked for it. Refreshing on those is a loop: one refresh
  // sends three requests, each reply triggers another refresh, and the app
  // buries itself within seconds. Only an unsolicited push is acted on.
  var pushTimer = null;

  window.addEventListener('message', function (event) {
    var data = event.data || {};

    if (data.type === 'push') {
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
         the cache is stale, and it is the only one. */
      state.proposals = {};

      /* And an open thread is re-read.
      
         A thread was fetched when it was opened and after each send by this
         player, and never otherwise. So the other party's replies simply
         did not arrive: two people could sit in the same conversation, both
         writing, and neither would see the other until one of them left the
         screen and came back. A push is the server saying something
         changed, and a message is one of the things it pushes for. */
      if (state.tab === 'thread' && state.thread) {
        openThread(state.thread.contract, state.thread.thread);
      }

      // Debounced: a contract settling pushes the creator, the target and
      // every hunter, and several of those can land in the same tick. One
      // refresh is three requests, so a push per party would be a burst per
      // event.
      if (pushTimer) { clearTimeout(pushTimer); }
      pushTimer = setTimeout(function () { pushTimer = null; refresh(); }, 250);
      return;
    }

    // The client asks for this when a staff member runs the diagnosis
    // command, so what the page has seen reaches the same report as what
    // the server has seen. It is the only way to read this side of the
    // bridge from outside the game.
    if (data.type === 'diagnostics') {
      Diag.note('asked', 'the server asked what this page has seen');
      Diag.report('page diagnostics', 'requested', Diag.asText());
      return;
    }
  });

  // Installed before the first render: a throw in that render is exactly
  // the kind this exists to catch, and catching it needs the handler
  // already in place.
  Diag.install();

  render();
  refresh();

})();
