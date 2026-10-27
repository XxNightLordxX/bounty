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
        report(message, 'unhandled rejection', reason && reason.stack);
      });

      note('boot', 'build ' + (window.CH_BUILD || 'dev'));
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
      title.textContent = 'Diagnostics · ' + (window.CH_BUILD || 'dev');
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
      // Built as dump() builds the log staff ask for: lines joined with the
      // marker the server splits on, and the newest 900 characters, which
      // is all the server keeps. Sent whole and oldest first, the server
      // kept the start of the session and cut the events nearest the fault.
      copy.onclick = function () {
        var flat = asText().split('\n').join(' || ');
        send({ what: 'diagnostics requested by the player', where: 'panel',
               stack: flat.slice(-900), build: window.CH_BUILD || 'dev' });
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
    // The whitelisted-job view's read, answered for somebody who left the
    // job: the page goes back to the whole app on it rather than say this.
    not_whitelisted: 'That screen is only for players on a whitelisted job.',
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
    // One live contract per player on one person, on any character.
    same_target_active: 'You already have a contract out on them.',
    // Also policy waits. slot_cooldown shared rate_limited, so a hitman
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
    // Walked away from this exclusive one a moment ago. failText says how
    // long when the server sends it.
    retake_too_soon: 'You walked away from this contract a moment ago. It is open '
      + 'to everybody else for a while before you can take it again.',
    // A proposal answered after it lapsed (answerProposal says it the same way).
    proposal_expired: 'That proposal ran out before it was answered.',
    relay_off: 'This server does not run messages through the app.',
    calls_off: 'This server does not place calls through the app.',
    // A feature staff turned off (proposals, the informant). Only new
    // actions are refused; whatever was under way carries on.
    feature_off: 'That is turned off by the server right now.',
    /* Informant data in the minutes after a restart, which forgot who had
       been near the target. Nothing was charged. failText says how long
       when the server sends it. */
    informant_warming: 'The informant is still asking around after a restart. '
      + 'Try again in a few minutes.',
    call_unmasked: 'They are staying anonymous, and a call from this phone '
      + 'would show their number. Send a message instead.',
    limit_reached: 'You are holding too many contracts.',
    /* A different rule entirely, and it used to share the message above —
       which told a hitman holding nothing that they were holding too much,
       and sent them to cancel their own work over somebody else's contract
       being popular. */
    contract_full: 'This contract already has as many operatives on it as it '
      + 'allows. Try another, or come back if one drops out.',
    /* The stake moved between reading the board and tapping Accept. Refused
       rather than charged, because a stake is taken on the tap and forfeits
       to the client if the hitman later walks away — the one repricing a
       player cannot undo by looking again. */
    terms_changed: 'The stake or the deadline on this contract changed while you '
      + 'were looking at it. Refreshing now — check the new terms before you take it.',
    /* How a contract placed now is completed changed from the admin panel
       while the Place form was open. failText says which way when the
       server sends it. Nothing was taken. */
    rule_changed: 'This server now places contracts differently. Nothing was taken. '
      + 'Check the form and place it again.',
    /* The target took a protected job after being picked, so the warning
       was never shown. Nothing was taken; submitContract shows it now. */
    target_now_protected: 'That target now works in a protected job. Nothing was taken. '
      + 'Read the warning and place it again if you still want to.',
    too_little_time: 'This contract runs out too soon to stake on. Taking it now '
      + 'would hand your stake to the person who placed it before you could work it.',
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
    // The paths a player meets most — accept, buy out, place — word their
    // own; this is what is left, and it at least says it is about money.
    insufficient_funds: 'You do not have enough money for that.',
    invalid_reward: 'That reward does not add up.',
    // Worth too little in money (Config.Limits.MinContractReward). Said with
    // the figure where the reply or the Place form carries it (failText);
    // this is what is left when neither does.
    reward_too_small: 'A contract here has to be worth more in money than that: '
      + 'cash, bank and dirty money in the reward. Items and weapons do not '
      + 'count towards it.',
    // Anonymous only: the item would go to the hitman with its own record
    // of whose it is, so it is the item to take out, not the figures.
    item_names_owner: 'One of those items carries your name or number, and '
      + 'the hitman would be handed it as it is, which would give you away. '
      + 'Leave it out.',
    // mysql mode only: the item's own data is more than the escrow table
    // holds. Refused before anything was taken.
    item_too_large: 'One of those items carries more data than this server can hold '
      + 'in escrow. Leave it out.',
    invalid_input: 'Check what you entered.',
    server_error: 'Something broke on the server, not on your end. '
      + 'An admin can see what in the server console.',
    /* mysql mode only: the database did not answer within the server's
       limit. A read that timed out moved nothing; a payment being recorded
       may still land, or is settled by the server, which says so. */
    db_timeout: 'The server’s records did not answer in time. If you were '
      + 'paying for something, look before you try again: it may still go through.',
    not_participant: 'That is not yours.',
    already_settled: 'That contract is closed.',
    // The rules are on the server and the numbers are configurable, so the
    // words carry what the settings say rather than figures hardcoded here.
    // "Take the target down" was said to a hitman who just had: a downed
    // target is not a kill, and nothing told them to finish the job. The
    // last line covers the second the server waits for the finishing shot.
    // "A few seconds": a kill the target's own phone never reports is
    // opened by the server alone, a few seconds after the death.
    no_kill_to_verify: 'No kill on this contract is waiting for proof. Down is '
      + 'not dead: if they are on the ground, finish them. Then photograph the '
      + 'body from a few metres away, soon after the kill. If you only just '
      + 'finished them, give it a few seconds and try again.',
    // Their death was put down to this hitman, and nothing the server can
    // see landed: Config.Completion.RequireObservedDamage.
    kill_unobserved: 'They died, but no shot or blow of yours was seen landing on '
      + 'them, so the kill pays nobody. Only gunfire and melee count: '
      + 'explosives, fire, run-overs and falls do not.',
    // The server restarted between the kill and Verify kill: what proved it
    // is kept in memory only, and went with the restart.
    kill_lost_restart: 'The server restarted and lost the proof of this kill, so it '
      + 'cannot be verified.',
    // Refused while the target was still protected, and the kill lapses
    // before that protection ends, so waiting cannot make it count. The
    // Verify kill path words which protection it was.
    kill_too_soon: 'They were still protected when you killed them, so this kill does '
      + 'not count.',
    // A contract placed for a live delivery only (its fulfilment is
    // 'alive'): a kill never completes it, so there is never one to verify.
    // What to do instead, with the server's distance and hold, is said by
    // failText (aliveOnlyRefusal); this is what is left when the page has
    // not read them. "The client" is gone from every line about it: a
    // hitman had no way to know it meant the person who placed the contract.
    kill_not_allowed: 'This contract only pays when you bring the target, alive, to '
      + 'the person who placed it. Killing them does not count: cuff them or get '
      + 'them into your vehicle, take them to that person and tap Deliver alive.',
    // The same contracts pay their whole reward for that delivery, so there
    // is no bonus on top to set, raise or add to.
    no_bonus: 'Contracts here only pay when the target is brought alive to the '
      + 'person who placed the contract, and that pays the whole reward, so '
      + 'there is no separate bonus. Add it to the reward instead.',
    // Not a fault. The poller stops on this and says the handover ended.
    no_handover: 'That handover is not running.',
    // A page that thought kill photos were off, on a server that takes
    // them. verifyKill opens the camera on this rather than saying it.
    photo_required: 'This server verifies a kill with a photo. Tap Verify kill again '
      + 'to take it.',
    // A token outlived by a newer kill, replaced by a second tap, or lost to
    // a restart: in every case the body can still be photographed.
    token_invalid: 'That verification is no longer valid. Take a new photo of '
      + 'the body now.',
    // The other side of what "expired" used to cover. A token never outlives
    // its kill, so this one is final, and saying "take it again" was not.
    proof_expired: 'The time to verify this kill ran out before the photo '
      + 'arrived. Nothing was sent for it, and this kill can no longer be claimed.',
    photo_rejected: 'The photo was not accepted.',
    photo_too_far: 'You are too far from the body. Stand over them and take it again.',
    photo_revived: 'They were brought back before you sent the photo, so this is '
      + 'not an elimination any more.',
    photo_still_down: 'They are down, not dead. Finish them, then take the photo.',
    photo_not_dead: 'They are not lying dead right now. If they are still down, '
      + 'try again in a moment; if they were brought back, the kill does not count.',
    photo_bad_host: 'That image host is not on this server\u2019s allow list. '
      + 'An admin sets which hosts the camera may upload to.',
    /* One answer for a photo already seen, one left open too long, and a
       handle that was never this player's: the server will not say which,
       so neither does the page. */
    photo_gone: 'That photo is gone. Each one can be opened once, and it is '
      + 'deleted unless it was saved to your Photos or kept in this app.',
    // The phone did not take it: lb-phone's own save, the client's
    // fallback or lb-phone's upload refused, or none of them was there.
    save_unavailable: 'This phone could not save the photo to Photos. It is still '
      + 'open: keep it in this app instead, or delete it.',
    // The server has no public address to serve the photo from after all.
    photo_no_link: 'This server could not give your phone a link to save the photo '
      + 'with. It is still open: keep it in this app instead, or delete it.',
    // The server opened it and it never reached this phone. The one look
    // was spent all the same, so it is gone.
    photo_no_answer: 'The photo did not reach your phone, and it could be '
      + 'opened only once. It has been deleted.',
    // The same for a photo kept in this app, which spent nothing by being
    // opened: it is still kept, and opens again (openProof).
    photo_kept_no_answer: 'The photo did not reach your phone. It is still kept '
      + 'for you in this app: tap View photo to try again.',
    /* The viewfinder's photo, which the page makes itself: the server could
       not read it, it would not shrink to the size the server keeps, or
       this phone could not make one at all. A new Verify kill is a new
       token, so each says to start there. */
    photo_bad_image: 'The photo could not be read. Tap Verify kill and take it again.',
    photo_too_large: 'The photo was too big to send. Tap Verify kill and take it again.',
    photo_unreadable: 'The photo could not be made. Tap Verify kill and take it again.',
    bad_state: 'Not right now.',

    /* The six ways a buyout is refused. They shared bad_state — "Not right
       now" — which is wrong for four of them: three will never work however
       long you wait, and one of them means it IS working. This is the one
       move a target has. */
    bailout_off: 'This server does not offer buyouts.',
    no_buyout_price: 'The person who placed this contract did not put a price on '
      + 'closing it. There is nothing to pay.',
    buyout_pending: 'You have already paid. It closes shortly — a hitman is '
      + 'engaged, so it is not instant.',
    incapacitated: 'Not from the floor. Get up first.',
    handover_in_progress: 'Somebody has hold of you. You cannot buy your way '
      + 'out of a handover already under way.',
    locked: 'Someone got there first.',
    /* Nothing was changed: the contract was busy with something else in
       that instant, or the server had only just started. Asking again
       works, so it says so rather than calling it a failure. */
    busy: 'That was busy for a moment. Try again.',
    /* Boot recovery failed, so the server answers nothing until staff fix
       it and restart the resource. It was "busy for a moment", beside a Try
       again that could never work; this is what /cleanse says. Final, so
       nothing offers to ask again (finalRefusal). */
    recovery_failed: 'The server\u2019s contract system failed to start, and staff '
      + 'have been told.',
    /* A hitman took the contract while the creator was looking at it. It
       was "Not right now." for Withdraw, Edit and Take back, and the retry
       got the same words, with nothing saying why or what still works. */
    contract_taken: 'Somebody has taken this contract. From now on it can '
      + 'only be improved: add to the reward, or propose a change.',
    deadline_at_limit: 'This contract already runs as long as this server '
      + 'allows. The deadline cannot go any later.',
    buyout_needs_clean: 'A buyout has to be backed by cash or bank in the '
      + 'reward. Add some, or set the buyout to 0.',
    not_found: 'Gone.',
    // The player closed the camera themselves. They know; saying so is
    // telling them what they just did.
    cancelled: null,
    // The phone has no camera this resource can drive. Nothing the hitman
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
       said there is never a kill left to claim. "Try again" sent the hitman
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
      // What an empty box means, where empty is an answer of its own.
      if (spec.placeholder) { input.placeholder = spec.placeholder; }
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
      // Which fields the player actually edited, as opposed to left on what
      // they opened with.
      var touched = {};
      Object.keys(d.values || {}).forEach(function (id) { touched[id] = true; });
      var handler = d.onValues;
      state.dialog = null;
      render();
      if (handler) handler(values, touched);
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
         hitman accepts somewhere, the box reads 30 again and Extend sends
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
    var named = d.labels || {};
    var yes = el('button', 'primary', d.kind === 'number'
      ? ((d.opts && d.opts.confirm) || 'Confirm') : (named.yes || 'Yes'));
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
    var no = el('button', 'ghost', named.no || 'Cancel');
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

  // What the client's Ledger row says once the photo is no longer waiting.
  var PROOF_WORDS = {
    saved: 'Photo saved to your phone',
    deleted: 'Photo deleted',
    // Opened and never answered for: this page was closed while it was up.
    // The server deletes it when the time to decide runs out.
    open: 'Photo opened and not saved. It is being deleted.'
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
        Diag.note('refused', 'photo link did not load from '
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
        resolve(window.components.uploadMedia('Image', blobOf(d.src)));
      }).then(function (url) {
        if (typeof url !== 'string' || !url) { throw { err: 'save_unavailable' }; }
        return toGallery(d.handle, url);
      });
    }
    return saving.then(function () {
      return decideProof(d.handle, 'save').then(function (r) {
        if (r.ok) { say('Saved to your Photos.', 'ok'); }
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
      if (r.ok) { say('Kept in this app. Open it again from your Ledger.', 'ok'); }
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
    panel.appendChild(el('div', 'target', 'Proof of the kill'));
    panel.appendChild(el('div', 'reason', d.kept
      ? 'Kept for you in this app. Open it again from your Ledger whenever you like, '
        + 'until you delete it.'
      : d.failed
        ? 'Your phone could not save it to Photos. Keep it in this app instead, or '
          + 'delete it \u2014 it is deleted when you close this.'
        : route
          ? 'You can see this once. Save it to Photos to keep it \u2014 it is deleted '
            + 'when you close this.'
          : d.photosOff
            ? 'You can see this once. Kill photos are off on this server, so it can only be '
              + 'kept for you in this app. Tap Save to keep it \u2014 it is deleted when you '
              + 'close this.'
            : 'You can see this once. Your phone can\u2019t take it, so it is kept for you '
              + 'in this app. Tap Save to keep it \u2014 it is deleted when you close this.'));

    var frame = el('div', 'photo-frame');
    var img = document.createElement('img');
    img.src = d.src;
    img.alt = 'Verification photograph';
    frame.appendChild(img);
    panel.appendChild(frame);

    var row = el('div', 'row');
    if (d.kept) {
      row.appendChild(actionButton('ghost is-destructive', 'Delete', 'proof-delete:' + d.handle,
        'Deleting\u2026', function () { return decideProof(d.handle, 'delete'); }));
      var close = el('button', 'ghost', 'Close');
      close.onclick = closeDialog;
      row.appendChild(close);
    } else {
      if (d.failed) {
        row.appendChild(actionButton('primary', 'Keep it in the app instead',
          'proof-keep:' + d.handle, 'Keeping\u2026', function () { return keepProof(d); }));
      } else if (route) {
        row.appendChild(actionButton('primary', 'Save to Photos', 'proof-save:' + d.handle,
          'Saving\u2026', function () { return saveProof(d, route); }));
      } else {
        row.appendChild(actionButton('primary', 'Save', 'proof-keep:' + d.handle,
          'Saving\u2026', function () { return keepProof(d); }));
      }
      row.appendChild(actionButton('ghost is-destructive', 'Delete', 'proof-delete:' + d.handle,
        'Deleting\u2026', function () { return decideProof(d.handle, 'delete'); }));
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
    var cancel = el('button', 'ghost', 'Close');
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

    // A wait the player can act on. "Slow down" alone reads as a broken
    // button, because tapping again says exactly the same thing.
    if (result.err === 'rate_limited' && result.data && result.data.retryAfter) {
        var wait = result.data.retryAfter;
        return wait >= 60
          ? 'Slow down — try again in about ' + Math.ceil(wait / 60) + ' minute'
            + (wait >= 120 ? 's' : '') + '.'
          : 'Slow down — try again in ' + wait + ' second' + (wait === 1 ? '' : 's') + '.';
    }

    // Held for seconds: the same request is still being worked on, waiting
    // on the server, and tapping again at once meets it again. Under ten
    // seconds it is the moment the plain words say.
    if (result.err === 'busy' && result.data && Number(result.data.heldMs) >= 10000) {
      return 'This is still being worked on. Look again in a minute before you try again.';
    }

    // How long until a hitman who walked away may take it back.
    if (result.err === 'retake_too_soon' && result.data && Number(result.data.retryAfter) > 0) {
      var back = Math.ceil(Number(result.data.retryAfter) / 60);
      return 'You walked away from this contract a moment ago. You can take it again in '
        + durationText(back) + '; until then it is open to everybody else.';
    }

    // How long until the informant sells again after a restart.
    if (result.err === 'informant_warming' && result.data && Number(result.data.minutes) > 0) {
      var minutes = Math.ceil(Number(result.data.minutes));
      return 'The informant is still asking around after a restart. Try again in '
        + minutes + ' minute' + (minutes === 1 ? '' : 's') + '.';
    }

    // Worth too little in money: the least is sent with the refusal, and
    // the Place form was opened with it. Said as a figure, because "more
    // than that" leaves the player guessing at a number the server knows.
    if (result.err === 'reward_too_small') {
      var least = Number(result.data && result.data.min)
        || Number(state.wallet && state.wallet.caps && state.wallet.caps.minValue) || 0;
      if (least > 0) { return minRewardText(least); }
      return 'A contract here has to be worth more in money than that: ' + moneyCounted()
        + ' Items and weapons do not count towards it.';
    }

    // A kill on a contract only a live handover completes: what to do
    // instead, with the server's own distance and hold.
    if (result.err === 'kill_not_allowed') { return aliveOnlyRefusal(); }

    // A fee or a price that moved while it was on screen: the figure now.
    if (result.err === 'terms_changed') {
      var moved = feeMovedText(result.data);
      if (moved) { return moved; }
    }
    // And the rule a contract is placed under, which way it went.
    if (result.err === 'rule_changed' && result.data
        && typeof result.data.fulfilment === 'string') {
      return 'This server now places contracts differently: '
        + (result.data.fulfilment === 'either'
          ? 'a kill completes one as well as a live handover.'
          : 'they only pay when the target is brought to you alive, and a kill does '
            + 'not complete one.')
        + ' Nothing was taken. Check the form and place it again.';
    }

    return ERRORS[result.err] || 'Something went wrong.';
  }

  /* What a charge is now, when a refusal says it moved while it was on
     screen: the anonymity fee on placing or on accepting, or the
     informant's price. Each was charged at whatever the admin panel had
     just set, without ever being shown; now it is refused, and said. */
  function feeMovedText(data) {
    var d = data || {};
    function from(account) { return account === 'cash' ? 'your cash' : 'your bank'; }
    if (typeof d.creatorFee === 'number') {
      return 'Placing anonymously now costs ' + money(d.creatorFee) + ' from '
        + from(d.feeAccount) + '. Nothing was taken. The form shows the new figure; '
        + 'place it again if that is fine.';
    }
    if (typeof d.fee === 'number') {
      return 'Taking it anonymously now costs ' + money(d.fee) + ' from '
        + from(d.feeAccount) + '. Nothing was taken. Check the new figure before you take it.';
    }
    if (typeof d.cost === 'number') {
      return 'The informant now costs ' + money(d.cost) + ' from ' + from(d.account)
        + '. Nothing was taken. Ask again if that is fine.';
    }
    return null;
  }

  /* The least a contract may be worth in money, in the words every place
     that says it uses: the Place form's hint, its own check, and a refusal
     for placing under it or taking a reward back out below it. */
  function minRewardText(least) {
    return 'A contract here has to be worth at least ' + money(least) + ' in money: '
      + moneyCounted() + ' Items and weapons do not count towards it.';
  }

  /* What counts as money in a reward. "Across every payout" only where a
     contract can be collected more than once (Config.Limits.MaxPayoutSlots):
     at 1, as shipped, the form says nothing about further collections. */
  function moneyCounted() {
    return moneyTaken() + ' '
      + (slotCeiling() > 1 ? 'across every payout.' : 'in the reward.');
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
    if (caps.dirtyEnabled !== false) { names.push('dirty money'); }
    if (!names.length) { return 'money'; }
    return names.length === 1 ? names[0]
      : names.slice(0, -1).join(', ') + ' and ' + names[names.length - 1];
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
    who.appendChild(el('div', 'reason', contract.reason || '—'));
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
      stamp = Number(g.weapons) > 0 ? 'Weapons' : 'Goods';
    }
    reward.appendChild(el('div', 'amount' + (stamp.charAt(0) === '$' ? '' : ' is-goods'), stamp));
    // A contract that pays only for a live delivery pays all of it for one,
    // so nothing on it is "if alive": the server places it with no bonus,
    // and one it somehow held would be paid on the same delivery as the
    // rest. The card says the rule once, as a chip, instead.
    var ifAlive = aliveOnly(contract) ? '' : ' if alive';
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
        'Bring the target alive to the person who placed this contract.'));
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
      ? money(dirtyBase) + ' of this is dirty money, and ' + money(dirtyBonus)
        + ' of the kidnapping bonus'
      : dirtyBase > 0 ? money(dirtyBase) + ' of this is dirty money'
      : dirtyBonus > 0 ? money(dirtyBonus) + ' of the kidnapping bonus is dirty money'
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
        ? contract.hitmenActive + ' of ' + contract.hitmenMax + ' operatives'
        : contract.hitmenActive
          + (contract.hitmenActive === 1 ? ' operative' : ' operatives');
      var full = contract.mode === 'competitive'
        && contract.hitmenMax
        && contract.hitmenActive >= contract.hitmenMax;
      return chip(full ? crowd + ' — full' : crowd, full ? 'warn' : 'hot', 'i-users');
    }

    // What a client opens Mine to find out, first: is anyone on it. An
    // untaken contract showed its mode and the client's own name and
    // nothing else, so "nobody has taken it" had to be read from an
    // absence.
    if (mine) {
      meta.appendChild(contract.hitmenActive > 0 ? crowdChip()
        : chip((collected > 0 ? 'Open again' : 'Open') + ' — no hitman yet', null, 'i-users'));
    }

    // How long is left, on every card. It was only ever said inside a
    // dialog, so a staked hitman could not see when their stake would go,
    // a client when their contract would lapse, or a target how long they
    // had to stay alive.
    var clock = clockChip(contract);
    if (clock) { meta.appendChild(clock); }

    meta.appendChild(chip(contract.mode === 'competitive' ? 'Competitive' : 'Exclusive',
      null, contract.mode === 'competitive' ? 'i-flag' : 'i-lock'));

    // How it can be finished, beside how it is shared: a term of the
    // contract every party is shown, the target too. Only where a kill does
    // not pay. A card without it is finished either way, as every card was.
    if (aliveOnly(contract)) {
      meta.appendChild(chip('Alive only', null, 'i-usercheck'));
    }

    // "Payout", the Place form's word for it. "Slot 1 of 3" told the
    // client nothing about how many had been collected.
    if (contract.slots > 1) {
      meta.appendChild(chip(mine
        ? collected + ' of ' + contract.slots + ' payouts collected'
        : 'Payout ' + contract.currentSlot + ' of ' + contract.slots, 'slots', 'i-layers'));
    }

    if (contract.role === 'hitman') {
      // Who they are on it, in place of a count that included them: a red
      // "1 operative" on their own card read as a rival, and nothing said
      // whether they had taken it anonymously or what alias the client sees.
      // The cap is left off — it only matters before accepting.
      // "Under your name", the accept dialog's own words for it: "client
      // sees your name" named a client nobody had been introduced to.
      meta.appendChild(chip('You' + (contract.myAlias ? ': ' + contract.myAlias : '')
        + (contract.myAnonymous ? ' · anonymous' : ' · under your name'),
        null, 'i-user'));
      var rivals = (Number(contract.hitmenActive) || 0) - 1;
      if (rivals > 0) {
        meta.appendChild(chip('+' + rivals + (rivals === 1 ? ' rival' : ' rivals'), 'hot', 'i-users'));
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
      asList(contract.hitmen).forEach(function (h) {
        if (h.record) {
          meta.appendChild(chip(h.alias + ' · ' + h.record.standing, null, 'i-user'));
        }
      });
    }
    // What accepting costs, on the listing, before the accept button —
    // §14.18. The server used to send this to the creator alone while
    // acceptance debited it anyway, so the first a hitman knew of a stake
    // was the money leaving their bank.
    if (contract.penaltyAmount > 0) {
      meta.appendChild(chip(money(contract.penaltyAmount) + ' stake', 'warn', 'i-coin'));
    }
    // The buyout as the server set it, on the client's own card. The server
    // moves a price outside what the reward allows to the nearest limit, and
    // the target was the only one shown the result: a client who meant to
    // let them off cheaply had no way to see that they had not.
    if (mine && settings().buyouts !== false) {
      var buyout = Number(contract.bailoutAmount) || 0;
      meta.appendChild(chip(buyout > 0 ? 'Buyout ' + money(buyout) : 'No buyout', null, 'i-exit'));
    }
    // Only when there is something to say: a row carrying neither drew an
    // empty pill. On the client's own card their own name is noise, but
    // whether they placed it anonymously is the one confirmation they get
    // of that choice.
    if (mine) {
      meta.appendChild(chip(contract.creatorAnonymous ? 'Placed anonymously'
        : 'Placed under your name', null, 'i-briefcase'));
    } else if (contract.creatorAnonymous || contract.creatorName) {
      // Who placed it, said as that: "Anonymous client", or a bare name
      // beside the target's, left a hitman to guess who either one was.
      meta.appendChild(chip(contract.creatorAnonymous ? 'Placed anonymously'
        : 'Placed by ' + contract.creatorName, null, 'i-briefcase'));
    }
    if (flagged) {
      meta.appendChild(chip(protectedWords(contract.targetProtectedAs).chip, 'warn', 'i-shield'));
    }
    node.appendChild(meta);

    // What this player's informant came back with, kept by the server with
    // the purchase. It used to be said once, in a notice that cleared itself
    // after four seconds, and nothing on the card or anywhere else held the
    // name the premium had paid for.
    if (contract.informantAnswer) {
      node.appendChild(el('div', 'informant-answer ico i-search',
        'Informant: ' + contract.informantAnswer));
    }

    // What accepting it does, under the switches now. "Their department has
    // been advised" read today's switch, not whether a bulletin went for
    // this contract, and was said of medics and lawyers, whose departments
    // nobody tells.
    if (flagged && context === 'board') {
      node.appendChild(el('div', 'notice gold', 'This target '
        + protectedWords(contract.targetProtectedAs).is + '.'
        + (advised('accepted') ? ' Accepting it alerts every officer in the city.' : '')));
    }

    // The placer's half of a live handover, on their own card once it is
    // taken: the hitman comes to them, so they have to be in the city to be
    // met. The phone notice that it was taken says the same (Notify
    // .contractAccepted); this is where it stays.
    if (mine && context !== 'board' && aliveOnly(contract)
        && Number(contract.hitmenActive) > 0) {
      node.appendChild(el('div', 'notice ok', placerTakenText()));
    }

    node.appendChild(actionsFor(contract, context));
    // Only on the player's own cards: a dispute is about a contract they
    // are in, and the board is a listing, not a case file.
    if (context === 'mine' || context === 'onme') { appendRef(node, contract.id); }
    return node;
  }

  /* The contract's reference, small, muted and selectable, for quoting to
     staff. Every staff command — the timeline, a void, who was behind it —
     starts from a contract id, and nothing on screen ever showed one, so
     "my contract on Dana is stuck" could only be answered from the
     database. */
  function appendRef(node, id) {
    if (id) { node.appendChild(el('div', 'ref', 'Ref ' + id)); }
  }

  // Said once under a list of referenced cards rather than on every card.
  function refHint() {
    return el('div', 'hint ref-hint', 'Quote the Ref to staff if something goes wrong.');
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
    if (contract.barred === 'hold_released') {
      return 'You were taken off this one for not working it. It is not yours '
        + 'to take again.';
    }
    if (contract.barred === 'same_account') {
      return 'This one involves another of your own characters.';
    }
    if (contract.role === 'hitman') {
      return 'You are already on this one \u2014 it is under Mine.';
    }
    var active = Number(contract.hitmenActive) || 0;
    if (contract.mode === 'exclusive' && active > 0) {
      return 'Taken. Somebody has this one to themselves \u2014 it comes back '
        + 'on the board if they walk away.';
    }
    var cap = Number(contract.hitmenMax) || 0;
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
         viewer's own contract, so it includes the ones they placed, the ones
         they already hold, and ones somebody else has filled — and every
         one of them drew Accept. Said instead, with where to look. */
      var why = boardHint(contract);
      if (why) {
        row.appendChild(el('div', 'hint', why));
        return row;
      }
      // Disabled while the acceptance is in flight. The button opens a
      // dialog rather than doing the work, so it is not an actionButton; the
      // request it leads to is keyed the same, and a second tap during the
      // round trip sent a second accept and told the player "Contract
      // accepted" and then "You are already on this contract".
      var acceptKey = 'accept:' + contract.id;
      if (isBusy(acceptKey)) {
        row.appendChild(actionButton('primary', 'Accept contract', acceptKey, 'Accepting\u2026'));
        return row;
      }
      var take = el('button', 'primary', 'Accept contract');
      take.onclick = function () { acceptContract(contract); };
      row.appendChild(take);
      return row;
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
        row.appendChild(actionButton('primary', 'Verify kill',
          'photo:' + contract.id, 'Verifying\u2026',
          function () { return verifyKill(contract); }));
      }

      row.appendChild(actionButton(killPays ? null : 'primary', 'Deliver alive',
        'kidnap:' + contract.id, 'Starting handover\u2026',
        function () { return armKidnap(contract); }));

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

      // The target has paid to close it and the buyout waits out its delay,
      // which is there so the hitman can finish first. The phone said so
      // once, and a full notice budget, a logoff or taking the contract
      // inside the delay missed it; the card said nothing at all.
      // Never more time than they have: "under N minutes".
      if (Number(contract.buyoutClosesIn) > 0) {
        var closesIn = secondsLeftOf({ secondsLeft: contract.buyoutClosesIn,
          clockReadAt: contract.clockReadAt });
        row.appendChild(el('div', 'hint is-warn', 'Buyout paid: it closes in '
          + (!(closesIn > 0) ? 'a moment'
            : closesIn < 60 ? 'under a minute'
              : 'under ' + durationText(Math.ceil(closesIn / 60)))
          + ' unless you finish it first.'));
      }

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
              ? 'The person who placed it keeps the ' + money(contract.penaltyAmount)
                + ' you staked.'
              : 'You staked nothing on this one, so it costs you nothing.',
            function () {
              post('abandon', { id: contract.id }).then(function (r) {
                if (!r.ok) return fail(r);
                // A handover being watched on it ends with it. Left running,
                // the poller read that ending as a failed delivery and told
                // a hitman who had just walked away to get the target back
                // to the client and try again.
                endCountdown(contract.id);
                say('You are off the contract.', 'ok');
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
      //
      // Nor where every operative on this card is already named. The
      // client's purchase only ever draws an anonymous one, so with none it
      // bought a certain "nobody" on the one purchase never refunded.
      var anyAnonymous = asList(contract.hitmen).some(function (h) { return !h.name; });
      if (informantOffered(contract) && anyAnonymous) {
        more.appendChild(informantButton(contract));
      }

      // Same shape, same reason: {} has no .length, so this read as "no
      // hitmen" whether or not there were any.
      if (asList(contract.hitmen).length && settings().relay !== false) {
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

      // Only while nobody is holding it. Once a hitman has accepted they
      // accepted it as written, and the server refuses both of these — so
      // offering them would be offering a guaranteed refusal.
      if (!contract.hitmenActive) {
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
      appendBuyout(row, contract);
      // Only with somebody on it. With nobody, the purchase could only
      // answer "Unknown operative", and was charged; the card already says
      // how many operatives there are, so hiding it says nothing new.
      if (informantOffered(contract) && Number(contract.hitmenActive) > 0) {
        more.appendChild(informantButton(contract));
      }
      return withMore();
    }

    return row;
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
        'Paid. A hitman still has ' + (still || 'a moment') + ' to finish this '
        + '\u2014 stay out of sight. If they do, your money comes back.'));
    } else if (contract.bailoutAvailable) {
      var buyoutKey = 'bailout:' + contract.id;
      var buyoutLabel = 'Buy out \u2014 ' + money(contract.bailoutAmount);
      if (isBusy(buyoutKey)) {
        row.appendChild(actionButton('primary danger', buyoutLabel, buyoutKey, 'Paying\u2026'));
      } else {
        var out = el('button', 'primary danger', buyoutLabel);
        out.onclick = function () { bailout(contract); };
        row.appendChild(out);
      }
    } else if (settings().buyouts === false) {
      // Not the client's doing. Saying "no buyout was offered" here blamed
      // the one person who had not decided it.
      row.appendChild(el('div', 'hint', 'This server does not offer buyouts.'));
    } else {
      row.appendChild(el('div', 'hint', 'No buyout was offered on this contract.'));
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
      return 'Someone has gone offline. The person who placed this contract must be '
        + 'online and ' + nearPlacer(radius);
    },
    target_not_conscious: 'Your target must be alive and conscious',
    target_too_hurt: 'Your target is too badly hurt',
    not_coerced: 'Your target is not restrained',
    target_too_far: 'Your target is too far from you',
    creator_too_far: function (radius) {
      return 'The person who placed this contract must be ' + nearPlacer(radius);
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
      ? 'Held long enough — settling the payout…'
      : progress.elapsed + 's of ' + progress.required + 's'));

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
          ? (breakingText(progress) || 'Hold position')
              + ' — handover fails in ' + (left / 1000).toFixed(1) + 's'
          : (left / 1000).toFixed(1) + 's of leeway left — the handover '
              + 'fails if it runs out'));
    } else if (progress.breaking) {
      wrap.appendChild(el('div', 'label warn',
        breakingText(progress) || 'Hold position'));
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
    if (any > 0) { mine.push('any new contract for ' + durationText(any)); }
    if (same > 0) { mine.push('one on ' + name + ' for ' + durationText(same)); }
    /* The creator's own, and on a contract somebody took up, the wait on the
       target for every client: withdrawing one nobody took up starts none
       for anybody else, and the dialog said "Nobody else waits" after an
       operative had taken it and walked away. */
    var others = contract.everTaken && everyone > 0
      ? 'Nobody else can place one on ' + name + ' for ' + durationText(everyone) + ' either.'
      : '';
    if (!mine.length) { return others || null; }
    return 'After this you cannot place ' + mine.join(', or ') + '.'
      + (others ? ' ' + others : '');
  }

  /* A payout already collected on a contract is not part of what comes
     back when it closes. "Everything you put up" after one was paid was
     short by that one, which is how a player counts their money, finds it
     short and reports it stolen. null when none was collected. */
  function collectedText(contract) {
    var claimed = Number(contract.slotsClaimed) || 0;
    if (claimed <= 0) { return null; }
    return claimed + ' of ' + Math.max(claimed, Number(contract.slots) || 1)
      + ' payouts were collected';
  }

  function cancelContract(contract) {
    var waits = relistWaitText(contract);
    var collected = collectedText(contract);
    var lead = contract.everTaken ? 'The operative who took it walked away' : 'Nobody has taken it';
    ask('Withdraw this contract?',
      (collected
        ? lead + '. ' + collected + ', so the rest of what you put up comes back to you.'
        : lead + ', so everything you put up comes back to you.')
        + (waits ? ' ' + waits : '')
        + ' To change what it pays or when it runs out, use Change reward or '
        + 'Edit instead.',
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
            ? 'Contract withdrawn. Some of what you put up would not fit and is '
              + 'waiting for you — it arrives when you next have room.' + checking
            : checking ? 'Contract withdrawn.' + checking
              : collected
                ? 'Contract withdrawn. ' + collected + '; the rest of what you put up has been '
                  + 'returned.'
                : 'Contract withdrawn. Everything you put up has been returned.', 'ok');
          refresh();
        });
      }, { yes: 'Withdraw it', no: 'Keep it' });
  }

  /* Change a contract nobody has taken. What it pays is not edited here —
     moving escrow is money in and out of a pocket, and that has its own
     screen behind "Change reward", which can both add and take back. */
  /* The same reason control the Place form draws, for the same reason.

     The Edit dialog asked for free text whatever the server took, and
     always sent it. On a preset server that was refused as invalid_input;
     on a server storing no reason at all it made the whole edit fail, so
     the deadline it came with could never be changed either. The rules are
     the operator's and apply to every way in: Edit, and proposing a new
     reason once somebody holds the contract. */
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
    return fields;
  }

  function editContract(contract) {
    var fields = reasonFields(contract);

    /* The deadline as it stands, not a fixed three hours.

       The box always opened on 3 and Save always sent it, so a creator who
       opened Edit to fix a word in the reason also moved the deadline to
       three hours from now — cutting a contract with a day left down to
       three hours, with nothing on screen saying the deadline had been
       touched.

       Empty while a deadline is running, saying what empty keeps. It
       opened on the time left rounded up to whole hours and sent it only if
       touched, so nine minutes left read "1", a creator took that for "an
       hour from now", saved, and the contract lapsed nine minutes later
       under "Contract updated.". The box no longer shows a figure Save
       ignores: whatever is in it is sent. */
    var left = minutesLeft(contract);
    // With no deadline running there is nothing to keep: the figure in the
    // box is only a suggestion, and Save means it.
    var suggested = left === null || left <= 0;
    fields.push({
      id: 'hours',
      label: suggested ? 'Hours from now to the deadline'
                       : 'New deadline, in hours from now (optional)',
      type: 'number', value: suggested ? 3 : '', min: 1, max: 48,
      placeholder: suggested ? '' : 'Leave empty to keep ' + durationText(left)
    });

    askFields('Edit this contract',
      // Where everything else about it is changed, since this is where a
      // creator looks first.
      'Only while nobody has taken it. To change what it pays or lower the '
        + 'stake, use Change reward.'
        + (settings().amendments !== false
          ? ' To raise the stake or change how many hitmen can take it, use '
            + 'Propose change.' : ''),
      fields,
      function (values) {
        var seconds = values.hours > 0 ? values.hours * 3600 : 0;
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
          if (!r.ok) { return takenOr(r); }
          say('Contract updated.', 'ok');
          refresh();
        });
      });
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
    if (idle > 0) { ways.push('going ' + durationText(idle) + ' without going near them'); }
    if (attempt > 0) {
      ways.push((ways.length ? '' : 'going ') + durationText(attempt) + ' without an attempt');
    }
    return ways.length ? ways.join(', or ') + ', while they are in the city' : '';
  }

  /* Where the stake goes, said where the hitman agrees to it. Going idle
     forfeits it as walking away does (the server's idle release), so the
     dialog no longer says "your stake comes back" about a rule that now
     hands it to the client. */
  function stakeRule(contract) {
    var idleLoses = contract.mode === 'exclusive' && idleText(contract) !== '';
    return (idleLoses ? 'Walk away, go idle or run out of time'
      : 'Walk away or run out of time') + ' and your stake goes to the person who placed it.';
  }

  function exclusiveRule(contract) {
    var idle = idleText(contract);
    if (!idle) { return ''; }
    if (contract.mode === 'exclusive') {
      return ' Exclusive: ' + idle + ' puts it back on the board, and you cannot take it '
        + 'again.';
    }
    // A competitive contract is released from only while it is full.
    return ' While it is full, ' + idle + ' gives your place'
      + (Number(contract.penaltyAmount) > 0 ? ' and your stake' : '') + ' up.';
  }

  /* The same rule, on the hitman's own card under Mine: where they look
     while they work it, and an hour after the dialog that said it. */
  function exclusiveReminder(contract) {
    var idle = idleText(contract);
    if (!idle) { return null; }
    var staked = Number(contract.penaltyAmount) > 0;
    if (contract.mode === 'exclusive') {
      return el('div', 'hint', 'Exclusive: ' + idle + ' puts it back on the board, and it '
        + 'is not yours to take again.' + (staked ? ' ' + stakeRule(contract) : ''));
    }
    // On a competitive card only while it is full, which is when it applies.
    if ((Number(contract.hitmenActive) || 0) < (Number(contract.hitmenMax) || Infinity)) {
      return null;
    }
    return el('div', 'hint', 'While it is full, ' + idle + ' gives your place'
      + (staked ? ' and your stake' : '') + ' up.');
  }

  function acceptContract(contract) {
    var feeAccount = anonymityAccount();
    // The fee the dialog shows, kept with it and sent back with the tap:
    // the server refuses rather than charges a fee that has moved since.
    var shownFee = anonymityFee('hitman');

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
        // And the deadline, which the stake is forfeit to: brought forward
        // since it was shown, the server refuses rather than takes the stake.
        deadline: contract.deadline,
        // And the anonymity fee and its account, as the dialog said them.
        shown: { hitmanFee: shownFee, feeAccount: feeAccount }
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
          if (r.err === 'insufficient_funds' && (stake > 0 || fee > 0)) {
            return say(stake > 0 && short.part !== 'fee'
              ? 'You need ' + money(stake) + ' in your bank or in your cash for the '
                + 'stake \u2014 it is not split between them'
                + (fee > 0 ? ', plus ' + money(fee) + ' in your ' + from
                  + ' for anonymity' : '') + '.'
              : 'Anonymity costs ' + money(fee) + ' from your ' + from
                + ', and it does not hold that much.');
          }
          // Holding as many as the server allows. The shared wording said
          // "too many", with no number and nothing to do about it.
          if (r.err === 'limit_reached') {
            var most = Number(r.data && r.data.max);
            return say('You are already working '
              + (most > 0 ? most + ' contract' + (most === 1 ? '' : 's')
                + ', the most this server allows' : 'as many contracts as this server allows')
              + '. Finish one under Mine before you take another.');
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
          ? ' Anonymity cost ' + money(Number(charged.fee)) + ' from your '
            + (charged.account === 'cash' ? 'cash' : 'bank') + '.' : '';
        say(recorded ? 'Contract accepted, anonymously.' + cost
          : anonymous ? 'Contract accepted under your name: the person who placed it '
            + 'already knows you on this one.'
          : 'Contract accepted.', 'ok');
        // Held until the refresh lands, not just the reply: the board still
        // has the card as it was, and Accept came back live on it for one
        // round trip, under the notice saying it was taken.
        return refresh();
      });
      });
    }

    function chooseAnonymity() {
      feeAccount = anonymityAccount();
      shownFee = anonymityFee('hitman');
      state.dialog = {
        kind: 'choice',
        question: 'Take this one anonymously?',
        detail: 'The person who placed it will see an operative, not your name.'
          // What finishes it, before it is taken: the card's chip says it,
          // and this is where a hitman agrees to the terms. One used to
          // being paid for a kill would otherwise find out after making one.
          // To whom, too: "delivering the target alive" left a hitman asking
          // where, and "the client" did not tell them.
          + (aliveOnly(contract)
            ? ' This contract only pays when you bring the target, alive, to the '
              + 'person who placed it. Killing them does not count.'
            : '')
          + (shownFee > 0
            ? ' Anonymity costs ' + money(shownFee) + ' from your '
              + feeAccount + '.'
            : '')
          // Taken whole from one account, which nothing said until a
          // player with half in each was refused.
          + (contract.penaltyAmount > 0
            ? ' Accepting stakes ' + money(contract.penaltyAmount)
              + ' of yours, taken whole from your bank or whole from your cash,'
              + ' returned when you finish. ' + stakeRule(contract)
            : '')
          // How much time that is. The stake is forfeit to the deadline, and
          // nothing on the dialog said when it was.
          + (minutesLeft(contract) !== null && minutesLeft(contract) > 0
            ? ' It runs out in ' + durationText(minutesLeft(contract)) + '.'
            : '')
          + exclusiveRule(contract),
        options: [
          { label: 'Anonymously', primary: true, run: function () { take(true); } },
          { label: 'Under my name', run: function () { take(false); } }
        ],
        // Drawn again from the settings when they change while it is open
        // (readBoard), so the fee it shows, and sends back, is the fee now.
        redo: chooseAnonymity
      };
      render();
    }

    if (contract.targetProtected && settings().warnHitman !== false) {
      // Only what accepting does, under the switches now. "Law enforcement
      // has already been advised" read today's switch, not whether a
      // bulletin went for this contract.
      var told = [];
      if (advised('accepted')) { told.push('Accepting alerts every officer in the city that someone is coming.'); }
      told.push('Accept anyway?');
      ask('This contract is on ' + protectedWords(contract.targetProtectedAs).noun + '.',
          told.join(' '), chooseAnonymity);
      return;
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
    var deliver = 'restrain them or get them into your vehicle, bring them '
      + (within ? 'within ' + within + ' m of' : 'to')
      + ' the client, tap Deliver alive and hold '
      + (kidnap.seconds ? 'for ' + kidnap.seconds + 's.' : 'until it finishes.');
    // With kill photos off (settings().killPhotos) nothing is photographed:
    // Verify kill is checked at the scene.
    var text = 'Kill: a downed target is not dead. Finish them, then stand over '
        + (settings().killPhotos === false
          ? 'the body and tap Verify kill before they are revived. '
          : 'the body and tap Verify kill to photograph it before they are revived. ')
        + 'Alive: ' + deliver;
    // Nobody can be met who cannot be found.
    if (contract.creatorAnonymous && settings().relay !== false) {
      text += ' Your client is anonymous. Use Message to agree where to meet '
        + 'before you grab them.';
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
    return m ? 'within ' + m + ' m of you and the target'
      : 'right there with you and the target';
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

  // What a hitman does to finish a contract only a live handover completes:
  // within `radius` (a running countdown's), or the server's where none is.
  function deliverAliveSteps(radius) {
    var m = metres(radius);
    var seconds = Number((settings().kidnap || {}).seconds);
    return 'Bring them in alive: cuff them or get them into your vehicle, take them '
      + 'to the person who placed this contract, '
      + (m ? 'get within ' + m + ' m of that person' : 'get close to that person')
      + ', tap Deliver alive and hold '
      + (seconds > 0 ? 'for ' + seconds + ' seconds' : 'until it finishes')
      + '. Killing them does not count \u2014 they respawn and the contract stays open.';
  }

  // Who that person is, as far as this hitman may know: an anonymous one has
  // to be found, a named one is named.
  function placerLine(contract) {
    var relay = settings().relay !== false;
    if (contract.creatorAnonymous) {
      return relay ? ' The person who placed it is anonymous \u2014 use Message to '
        + 'agree where to meet.' : '';
    }
    if (contract.creatorName) {
      return ' The person who placed it is ' + contract.creatorName
        + (relay ? ' \u2014 use Message to agree where to meet.' : '.');
    }
    return '';
  }

  // The kill refusal on such a contract, with what to do instead.
  function aliveOnlyRefusal() {
    return 'This contract only pays when you bring the target, alive, to the '
      + 'person who placed it. ' + deliverAliveSteps();
  }

  // The placer's own card once a hitman has taken it, and the phone notice.
  function placerTakenText() {
    return 'A hitman took your contract. They\u2019ll bring the target to you alive '
      + '\u2014 stay in the city' + (settings().relay !== false
        ? ' and watch your messages.' : '.');
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
        'Point the phone at the body and take the photo.'));
      var frame = el('div', 'viewfinder-frame');
      var canvas = document.createElement('canvas');
      frame.appendChild(canvas);
      shade.appendChild(frame);
      var row = el('div', 'row');
      // Not live until the client says the rear camera is on. Until then the
      // render shows the ordinary game camera, which has the hitman in it,
      // and a quick tap sent the client that.
      var shutter = el('button', 'primary', 'Take photo');
      shutter.disabled = true;
      var cancel = el('button', 'ghost', 'Cancel');
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
        shutter.textContent = 'Sending\u2026';
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
          ? ' It counts if they are still lying dead in ' + waitText(left)
            + ': tap Verify kill again then.'
          : '';
        var rule = r.data && r.data.rule;
        var here = {
          target_just_up: 'They had only just got back up when you killed them, '
            + 'so the kill does not count yet.' + wait,
          target_just_on: 'They had only just come into the city, so the kill '
            + 'does not count yet.' + wait,
          kill_too_soon: rule === 'target_just_on'
            ? 'They had only just come into the city, so this kill does not count.'
            : 'They had only just got back up, so this kill does not count.',
          target_protected: 'They are protected right now, so the kill does not '
            + 'count.',
          rate_limited: 'Too many attempts just now. Wait a few seconds and '
            + (noKill ? 'try again.'
              : noPhoto ? 'tap Verify kill again; the kill is still yours to claim.'
                : 'photograph them again; the kill is still yours to claim.')
        };
        // The refusals that speak of a photo, said for a kill checked at
        // the scene where no photo is taken.
        if (noPhoto) {
          here.no_kill_to_verify = 'No kill on this contract is waiting to be verified. '
            + 'Down is not dead: if they are on the ground, finish them. Then stand '
            + 'over the body and tap Verify kill, soon after the kill. If you only '
            + 'just finished them, give it a few seconds and try again.';
          here.photo_too_far = 'You are too far from the body. Stand over them and tap '
            + 'Verify kill again.';
          here.photo_revived = 'They were brought back before you verified the kill, so '
            + 'this is not an elimination any more.';
          here.photo_still_down = 'They are down, not dead. Finish them, then tap Verify '
            + 'kill.';
          here.token_invalid = 'That kill is no longer the one to verify. Stand over the '
            + 'body and tap Verify kill again.';
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
      say(owed
        ? 'Verified. Some of the reward would not fit and is being held for '
          + 'you \u2014 make room and it will be handed over.' + staffChecking(r.data)
        : 'Verified. Payment released.' + staffChecking(r.data), 'ok');
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
          ? ' They are anonymous \u2014 use Message to agree where to meet.' : '';
        var reasons = {
          // On a contract only a handover completes, a dead target is the
          // kill that does not count: said, with what still works.
          target_not_conscious: 'The target must be alive and conscious.'
            + (aliveOnly(contract) ? ' Killing them does not count \u2014 once they '
              + 'are back on their feet, bring them in alive.' : ''),
          target_too_hurt: 'The target is too badly hurt to hand over. Get them '
            + 'patched up first.',
          not_coerced: 'The target must be restrained or in your vehicle.',
          // Said as the rule, which is the same whether they are offline or
          // only far away: an anonymous one absent is told as this too
          // (Kidnap.conditionsMet), so neither may be guessed from it.
          creator_too_far: 'The person who placed this contract must be online and '
            + nearPlacer() + '. Take the target to them, then tap Deliver alive '
            + 'again.' + findThem,
          target_too_far: 'Keep the target close.',
          // A live delivery skips the rule about getting back up, so that is
          // never why; it said so to hitmen holding somebody fresh in town.
          target_just_on: 'They have only just come into the city. A handover '
            + 'will not count until they have been here a few minutes.',
          target_protected: 'They are protected from contracts right now, so a '
            + 'handover will not count.',
          party_offline: 'Everyone has to be online for a handover: the person who '
            + 'placed this contract must be in the city and ' + nearPlacer() + '.',
          limit_reached: 'Too many handovers in progress. Try shortly.'
        };
        return say(reasons[r.err] || ERRORS[r.err] || 'Cannot start the handover.');
      }
      say('Hold position.', 'caution');
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

  function stopCountdown() {
    if (countdownTimer) { clearInterval(countdownTimer); countdownTimer = null; }
    countdownFor = null;
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
    var timer;

    timer = countdownTimer = setInterval(function () {
      if (Date.now() > deadline) {
        endCountdown(id);
        say('Lost track of the handover. Your contracts show how it ended.');
        refresh();
        return;
      }

      post('kidnapProgress', { id: id }).then(function (r) {
        /* A reply to a poll this page has since stopped — the hitman walked
           away while it was in flight, or a newer handover replaced it. It
           answered "no handover" to a hitman who had just left and told
           them to get the target back and try again, and a stale reply
           could stop the poller that replaced it. */
        if (countdownTimer !== timer) { return; }
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
        if (!r.ok || !r.data || r.data.elapsed === undefined) {
          // Over, one way or another. The bar goes rather than freezing,
          // and the player is told — a delivery that simply stops moving is
          // the one thing a hitman holding a target cannot interpret.
          endCountdown(id);
          say(r.err === 'no_handover' || r.err === 'not_found'
                || r.err === 'bad_state'
            ? 'The handover ended. Get them back to the person who placed this '
              + 'contract and try again.'
            : (ERRORS[r.err] || 'Lost track of the handover.'));
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
    }, 1000);
  }

  /* What is said of a payment whose give raised and whose arrival could not
     be read: it was left for staff, and no retry gives it, so "make room and
     it will be handed over" was untrue of it. The server counts it apart
     (`parked`) in a claim's answer, a handover's ending, and a withdrawal's. */
  function staffChecking(data) {
    var parked = data && (data.parked === true || Number(data.parked) > 0);
    return parked
      ? ' Part of it could not be confirmed; staff have been asked to check it.'
      : '';
  }

  /* A wait the server measured, in words: seconds under a minute, else
     minutes, rounded up. */
  function waitText(seconds) {
    var s = Math.max(0, Math.ceil(Number(seconds) || 0));
    if (s < 60) { return s + (s === 1 ? ' second' : ' seconds'); }
    return durationText(Math.ceil(s / 60));
  }

  /* What a finished handover means, in words. The server keeps how each
     one ended for a couple of minutes; the phone notification says the same
     thing to a hitman who has closed the app. */
  function handoverEnded(ended) {
    if (ended.outcome === 'paid') {
      return say(ended.pending
        ? 'Delivered. Some of the reward would not fit and is being held for '
          + 'you \u2014 make room and it will be handed over.' + staffChecking(ended)
        : 'Delivered. Payment released.' + staffChecking(ended), 'ok');
    }
    if (ended.outcome === 'closed') {
      return say('The contract closed before the handover finished.');
    }
    if (ended.outcome === 'refused') {
      var refused = {
        bad_state: 'The contract closed before the handover finished.',
        locked: 'Another payout on this contract was being settled at the same '
          + 'moment, and it got there first.',
        target_just_on: 'They had only just come into the city, so the '
          + 'handover does not count.',
        target_protected: 'They were protected from contracts, so the handover '
          + 'does not count.'
      };
      return say('The handover finished but was not paid. '
        + (refused[ended.reason] || ERRORS[ended.reason] || ''));
    }
    // The two that mean the person who placed the contract was missing say
    // so, with how close they have to be. "Your client did not arrive"
    // named somebody a hitman may never have been told about.
    var failed = {
      party_offline: 'Someone the handover needed went offline. The person who placed '
        + 'this contract must be online and ' + nearPlacer() + '.',
      creator_too_far: 'The person who placed this contract did not arrive in time. '
        + 'They must be online and ' + nearPlacer() + ' for the whole handover.',
      target_not_conscious: 'The target went down. A handover has to be alive.',
      target_too_hurt: 'The target got too badly hurt. Get them patched up first.',
      contract_locked: 'The contract was stuck settling another payout.'
    };
    return say('The handover failed. ' + (failed[ended.reason]
      || 'You lost hold of the target.') + ' Get them back to the person who placed '
      + 'this contract and try again in a minute.');
  }

  /* "about 2 minutes", for the wait a hitman on the contract still has;
     null on a server that does not make them wait. */
  function buyoutWait(seconds) {
    if (!(seconds > 0)) { return null; }
    return seconds < 60 ? 'under a minute'
      : 'about ' + durationText(Math.ceil(seconds / 60));
  }

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
    ask('Pay ' + amount + ' to close this contract?',
        'The person who placed it gets their money back, along with your payment. It is paid in '
          + 'full from your bank, or from your cash if the bank cannot cover it '
          + '\u2014 never split between them. '
          + (wait && Number(contract.hitmenActive) > 0
            ? 'A hitman is already on you and gets ' + wait + ' more to finish it. '
              + 'If they do, your ' + amount + ' comes back.'
            : 'If nobody has taken it yet, it closes at once.'),
        function () {
          // Through `once`, so the button is disabled for the round trip: up
          // to half a million, and a second tap sent a second request.
          once('bailout:' + contract.id, function () {
            return post('bailout', { id: contract.id }).then(function (r) {
              if (!r.ok) {
                // The figure the server asked for, when it says: the price
                // can have been re-set under the dialog.
                if (r.err === 'insufficient_funds') {
                  var need = Number(r.data && r.data.need) > 0 ? money(r.data.need) : amount;
                  return say('Your bank or your cash has to cover the full ' + need
                    + ' on its own \u2014 it is never split. Move it into one '
                    + 'account and try again.');
                }
                return fail(r);
              }
              // From the reply, not from the card: a hitman may have taken
              // it since the dialog opened.
              var queued = !!(r.data && r.data.queued);
              var waited = buyoutWait(Number(settings().buyoutDelaySeconds) || 0);
              say(queued
                ? 'Paid. It closes in ' + (waited || 'a moment')
                  + '. You are still a target until then.'
                : 'Paid. Contract closed.', 'ok');
              // Held until the card is read again, so Buy out does not come
              // back live on a contract that is paid for.
              return refresh();
            });
          });
        }, { yes: 'Pay ' + amount });
  }

  /* Whether this card offers informant data: where the server runs
     informants, and while this player has a purchase left on it (their own
     count, the projection's informantLeft). Spent, the button stayed, quoted
     the full price, and said nothing more could be bought only once the
     player had agreed to pay. */
  function informantOffered(contract) {
    if (!settings().informant) { return false; }
    var left = contract.informantLeft;
    return left === undefined || left === null || Number(left) > 0;
  }

  /* Buy informant data, disabled while a purchase is in flight: the one
     purchase that is never refunded, and the button stayed live through
     the round trip. */
  function informantButton(contract) {
    var key = 'informant:' + contract.id;
    if (isBusy(key)) {
      return actionButton('ghost ico i-search', 'Buy informant data', key, 'Buying\u2026');
    }
    var buy = el('button', 'ghost ico i-search', 'Buy informant data');
    buy.onclick = function () { buyInformant(contract); };
    return buy;
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
    // spending it — on a purchase that is deliberately not refunded. Kept,
    // and sent back with the purchase: a price that has moved since is
    // refused rather than charged.
    var shown = { cost: Number(rules.cost) || 0,
                  account: rules.account === 'cash' ? 'cash' : 'bank' };
    // Free is said as free. A cost of 0 fell to the words for a missing
    // figure, and a free purchase was described as a paid one.
    var detail = rules.cost === 0
      ? 'It is free on this server.'
      : 'It costs ' + (Number(rules.cost) > 0
        ? money(rules.cost) + ' from your ' + shown.account : 'a fee')
        + ', taken now, whether or not it turns anything up.';
    // How many times this contract can be asked at all. The cap is already
    // sent; without it a player has no idea they are on their last one, and
    // finds out by spending it. Their own count says which this is.
    if (Number(contract.informantLeft) === 1) {
      detail += ' This is your last one on this contract.';
    } else if (rules && rules.maxPerContract) {
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

    // A repeat inside the reroll lock is free and gives the answer already
    // bought, once the rate limit lets a second request through — and the
    // dialog quoted the full fee for that too.
    var waitMinutes = Math.ceil((Number(rules.askEverySeconds) || 0) / 60);
    var freeMinutes = Number(rules.repeatFreeMinutes) || 0;
    if (freeMinutes > waitMinutes) {
      detail += ' Asked about this contract again ' + (waitMinutes > 0
        ? 'between ' + waitMinutes + ' and ' + freeMinutes + ' minutes after an answer'
        : 'within ' + freeMinutes + ' minutes of an answer')
        + ', the informant repeats that answer at no charge.';
    }

    ask('Buy informant data?', detail, function () { doBuyInformant(contract, shown); });
    // Drawn again from the settings when they change while it is open
    // (readBoard), so the price it quotes, and sends back, is the price now.
    // Closed instead where the informant has been switched off meanwhile.
    if (state.dialog) {
      state.dialog.redo = function () { state.dialog = null; buyInformant(contract); };
    }
  }

  function doBuyInformant(contract, shown) {
    once('informant:' + contract.id, function () {
    return post('informant', { id: contract.id, shown: shown }).then(function (r) {
      if (!r.ok) {
        // The price moved since it was quoted: said, and the settings read
        // again, so the next quote is the price now. Nothing was taken.
        if (r.err === 'terms_changed') {
          fail(r);
          return refresh({ board: true });
        }
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
          bad_state: 'This server does not run informants.',
          feature_off: 'The informant is turned off by the server right now.'
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
        || 'Unknown operative'), 'ok');
      // The answer is kept on the card too; the refresh brings it.
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
      return 'Give back payout ' + ((p && p.slot) || '?')
        + ', returning what funds it to the person who placed the contract';
    },
    // With the before and after, which is what the hitman is agreeing to.
    shorten_deadline: function (p, contract) {
      var by = p && p.seconds ? Math.round(p.seconds / 60) : 0;
      var now = contract ? minutesLeft(contract) : null;
      return 'Shorten the deadline'
        + (by ? ' by ' + durationText(by) : '')
        + (by && now !== null && now > by
          ? ' (from ' + durationText(now) + ' left to ' + durationText(now - by) + ')' : '');
    },
    raise_penalty: function (p) {
      return 'Raise the stake' + (p && p.amount ? ' to ' + money(p.amount) : '');
    },
    change_mode: function (p) {
      return 'Change this to a ' + ((p && p.mode) === 'exclusive'
        ? 'single-hitman contract' : 'competitive contract');
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
    /* And to a hitman asked to agree, where their stake goes: back to them. */
    withdraw: function (_p, contract) {
      return 'Call the whole contract off — it closes for everyone on it, '
        + 'and what the person who placed it put up goes back to them' + stakeBack(contract);
    },
    cancel: function (_p, contract) {
      return 'Cancel this contract outright — it closes for everyone on '
        + 'it, and what the person who placed it put up goes back to them' + stakeBack(contract);
    }
  };

  function stakeBack(contract) {
    return contract && contract.role === 'hitman' && Number(contract.penaltyAmount) > 0
      ? '; your ' + money(contract.penaltyAmount) + ' stake comes back to you' : '';
  }

  function describeAmendment(proposal, contract) {
    var describe = AMENDMENT[proposal.kind];
    // An unknown kind is still shown, because a proposal nobody can read is
    // a proposal nobody can refuse.
    return describe ? describe(proposal.payload, contract) : 'A change to this contract';
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
    proposal_expired: 'That proposal ran out before it was answered.',
    bad_state: 'That proposal can no longer be answered.',
    not_found: 'That proposal has already been settled or has run out.',
    already_settled: 'That contract has closed, and the proposal with it.',
    invalid_input: 'Agreed, but the contract has moved on and the change no '
      + 'longer fits. Nothing was changed.',
    invalid_reward: 'Agreed, but the contract has moved on and the change no '
      + 'longer fits. Nothing was changed.'
  };

  /* Why a change everybody agreed to did not go in, for "Agreed, but it no
     longer applies: ...". */
  var NO_LONGER_APPLIES = {
    bad_state: 'who is on the contract changed before it went in.',
    invalid_input: 'the contract has moved on and the change no longer fits.',
    reward_too_small: 'it would leave the reward under the least a contract may be worth.',
    already_settled: 'the contract has closed.'
  };

  function answerProposal(proposal, approve, takingBack) {
    return post('respondAmendment', { id: proposal.id, approve: approve }).then(function (r) {
      if (!r.ok) {
        // Everybody agreed and the server refused it as it went in: said as
        // that, with why, and not as a proposal that lapsed.
        if (r.data && r.data.outcome === 'failed') {
          say('Agreed, but it no longer applies: ' + (NO_LONGER_APPLIES[r.err]
            || 'the contract changed before it went in.') + ' Nothing was changed.');
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
      say(outcome === 'applied' ? 'Agreed — the change is in effect.'
        : outcome === 'declined' ? (takingBack ? 'Taken back. The other side is told.' : 'Declined.')
        : 'Recorded. Waiting on the other party.', 'ok');
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
    return 'Lapses in ' + durationText(Math.max(1, Math.ceil(seconds / 60)));
  }

  function takeBack(proposal) {
    return actionButton('', 'Take it back', 'amend:' + proposal.id, 'Sending\u2026',
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
        proposal.mine ? 'Your proposal' : proposal.proposer + ' proposed this'));

      // What a shorter clock costs the hitman being asked, said where they
      // answer it. Agree is one tap and applies at once.
      if (proposal.kind === 'shorten_deadline' && contract.role === 'hitman'
          && Number(contract.penaltyAmount) > 0) {
        item.appendChild(el('div', 'hint is-warn', 'Your ' + money(contract.penaltyAmount)
          + ' stake goes to the person who placed it if you have not finished by then.'));
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
          'Nobody else is on this contract to agree, so it is yours to apply.'
          + (lapses ? ' ' + lapses + ' if you do not.' : '')));
        var applyRow = el('div', 'row');
        applyRow.appendChild(actionButton('primary', 'Apply it',
          'amend:' + proposal.id, 'Sending…',
          function () { return answerProposal(proposal, true); }));
        if (proposal.mine) { applyRow.appendChild(takeBack(proposal)); }
        item.appendChild(applyRow);
      } else if (proposal.mine || proposal.answered) {
        item.appendChild(el('div', 'hint', 'Waiting on ' + waiting
              + (waiting === 1 ? ' other party.' : ' other parties.')
              + (lapses ? ' ' + lapses + ' if nobody answers.' : '')));
        /* The proposer's own: taken back rather than left holding the
           contract's one open proposal until it lapses. The server takes
           their own decline as that, and tells the other side. */
        if (proposal.mine) {
          var mineRow = el('div', 'row');
          mineRow.appendChild(takeBack(proposal));
          item.appendChild(mineRow);
        }
      } else {
        if (lapses) { item.appendChild(el('div', 'hint', lapses + ' if you do not answer.')); }
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

  /* Seconds left on the clock, or null when there is no deadline to read.

     From the server's own reading, counted down from when it arrived. The
     deadline alone is wrong twice over: it stands still while the contract
     is paused and jumps on when the pause ends, so a countdown to it ran
     straight through every pause; and it is the server's clock compared
     with this machine's, which need not agree. A stopped clock is not
     counted down at all. The deadline is the fallback for a reply that
     carries no reading. */
  function secondsLeftOf(contract) {
    var read = contract.secondsLeft;
    if (read === undefined || read === null || isNaN(Number(read))) {
      if (!contract.deadline) { return null; }
      return contract.deadline - Math.floor(Date.now() / 1000);
    }
    if (contract.clockStopped || !contract.clockReadAt) { return Number(read); }
    return Number(read) - Math.floor((Date.now() - contract.clockReadAt) / 1000);
  }

  /* Minutes left on the clock, or null when there is no deadline to read. */
  function minutesLeft(contract) {
    var seconds = secondsLeftOf(contract);
    if (seconds === null) { return null; }
    return seconds > 0 ? Math.floor(seconds / 60) : 0;
  }

  /* When each contract's clock was read, so its card can count down from
     there. Stamped as the reply lands, not as the card is drawn: a card is
     redrawn many times from the same reply. */
  function stampClocks(list) {
    var at = Date.now();
    asList(list).forEach(function (c) { if (c && typeof c === 'object') { c.clockReadAt = at; } });
  }

  /* The time left, in the words of whoever is reading it.

     Never "out of time". The server resolves a contract whose clock is
     running within moments of its deadline, so a card still on screen at
     zero is one the server has not got to yet or one whose reading has gone
     stale here — and telling a staked hitman their stake was gone on a
     contract that was still alive is worse than saying nothing. */
  function clockWords(contract) {
    var seconds = secondsLeftOf(contract);
    if (seconds === null) { return null; }
    if (seconds <= 0) { return { text: 'Due now', warn: true }; }
    var left = durationText(Math.ceil(seconds / 60));
    if (contract.clockStopped) {
      return { text: 'Clock stopped · ' + left + ' left', warn: false };
    }
    var close = seconds < (Number(settings().stakeWindowMinutes) || 30) * 60;
    if (contract.atLatest) {
      return { text: (contract.role === 'target' ? 'Lapses within ' : 'Runs out within ') + left,
               warn: false };
    }
    if (contract.role === 'creator') { return { text: 'Runs out in ' + left, warn: close }; }
    if (contract.role === 'target') { return { text: 'Lapses in ' + left, warn: close }; }
    if (contract.role === 'hitman' && contract.penaltyAmount > 0 && close) {
      return { text: left + ' left · stake at risk', warn: true };
    }
    return { text: left + ' left', warn: close };
  }

  /* The clock chips on screen, rewritten in place every half minute while
     there are any. Redrawing the view to move them would reset the scroll
     and rebuild whatever the player had open; draw() empties the list and
     starts or stops the ticker, so it runs only while a card is showing. */
  var clockChips = [];
  var clockTimer = null;

  function paintClock(node, contract) {
    var words = clockWords(contract);
    if (!words) { return; }
    node.textContent = words.text;
    node.className = 'chip' + (words.warn ? ' warn' : '') + ' ico i-clock';
  }

  function clockChip(contract) {
    if (!clockWords(contract)) { return null; }
    var node = chip('', null, 'i-clock');
    paintClock(node, contract);
    clockChips.push({ node: node, contract: contract });
    return node;
  }

  function syncClockTicker() {
    if (clockChips.length && !clockTimer) {
      clockTimer = setInterval(function () {
        clockChips.forEach(function (c) { paintClock(c.node, c.contract); });
      }, 30000);
    } else if (!clockChips.length && clockTimer) {
      clearInterval(clockTimer);
      clockTimer = null;
    }
  }

  /* "runs out in 2h", or what to say instead when there is no clock. The
     no-deadline case used to be spliced into the same sentence and read
     "runs out in no set deadline". */
  function runsOut(minutes) {
    if (minutes === null || minutes === undefined) { return 'has no deadline'; }
    if (minutes <= 0) { return 'has run out'; }
    return 'runs out in ' + durationText(minutes);
  }

  /* "3 days ago", from a server time in seconds; null without one. */
  function agoText(at) {
    var t = Number(at);
    if (!t) { return null; }
    var minutes = Math.floor((Date.now() / 1000 - t) / 60);
    if (minutes < 1) { return 'Just now'; }
    if (minutes < 60) { return minutes + ' min ago'; }
    var hours = Math.floor(minutes / 60);
    if (hours < 24) { return hours + 'h ago'; }
    var days = Math.floor(hours / 24);
    return days + (days === 1 ? ' day ago' : ' days ago');
  }

  function durationText(minutes) {
    if (minutes === null || minutes === undefined) { return 'no set deadline'; }
    if (minutes <= 0) { return 'no time left'; }
    if (minutes < 60) { return minutes + (minutes === 1 ? ' minute' : ' minutes'); }
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
      + (bonusPaid > 0 ? ' (+' + money(bonusPaid) + (aliveOnly(contract) ? ')' : ' if alive)') : '')
      + (aliveOnly(contract) ? ' for a live delivery' : '');

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
    // that does not, so the box never offers it.
    var keep = Number(settings().deadlineMinLeftMinutes) || 5;
    var most = left === null ? 0 : left - keep;

    var options = [
      {
        label: 'Shorten the deadline',
        note: 'It ' + runsOut(left) + ' now.',
        // Nothing to shorten without a deadline, or without time to spare.
        skip: most < 1,
        run: function () {
          if (most < 1) {
            return say('There is no deadline left to shorten.');
          }
          askNumber('Shorten the deadline',
            hitman
              ? 'You are asking the person who placed it for less time than you have.'
              : (untaken ? 'Nobody has taken it, so this applies at once.'
                         : 'You are asking the operative to finish sooner.'),
            function (minutes) {
              sendProposal(contract, 'shorten_deadline', { seconds: minutes * 60 });
            },
            {
              label: 'Cut it short by (minutes)',
              value: Math.min(30, most), min: 1, max: most,
              confirm: untaken ? 'Shorten' : 'Propose',
              hint: function (value) {
                if (!value || value < 1 || value > most) {
                  return 'Between 1 and ' + most + ' minutes, leaving at least '
                    + keep + '.';
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
           nobody working has the direct route instead: Change reward. */
        /* The last one only. The collections are a sequence the contract
           walks through, so one out of the middle would renumber everything
           after it — the server refuses that, and this used to offer any
           later collection in a number box and let the other party find
           out by pressing Agree. There is nothing to choose, so nothing is
           asked. */
        label: 'Give back the last payout',
        note: spare > 0
          ? 'Payout ' + total + ' of ' + total + ', leaving ' + (total - 1) + '.'
          : 'Nothing after the one being competed for.',
        skip: spare <= 0,
        run: function () {
          ask('Give back payout ' + total + ' of ' + total + '?',
            (hitman
              ? 'You are offering to give up the last payout still to '
                + 'come. What is on the table now is untouched.'
              : 'This returns the last payout to you. The one being '
                + 'competed for now is untouched.')
              + ' ' + (total - 1) + ' would remain.',
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
        label: exclusiveNow ? 'Open it to other hitmen' : 'Make it one hitman only',
        // Exclusive with two on it is a contract its own rules forbid, and
        // the server refuses it after everybody has agreed.
        skip: hitman || (!exclusiveNow && active > 1),
        run: function () {
          var mode = exclusiveNow ? 'competitive' : 'exclusive';
          ask(exclusiveNow ? 'Open it to other hitmen?' : 'Make it one hitman only?',
            (exclusiveNow
              ? 'Several hitmen can then take it at once, and the first to finish is paid. '
              : 'Only one hitman can then be on it at a time. ')
              + (untaken ? 'Nobody has taken it, so this applies at once.'
                : 'The operative on it has to agree first.'),
            function () { sendProposal(contract, 'change_mode', { mode: mode }); },
            { yes: untaken ? 'Change it' : 'Propose' });
        }
      },
      {
        // Unheld, Edit already changes it directly.
        label: 'Change the reason',
        skip: hitman || untaken || !reasonOn,
        run: function () {
          askFields('Change the reason',
            'The operative has to agree first.',
            reasonFields(contract),
            function (values) {
              var preset = parseInt(values.reasonPreset, 10) || 0;
              sendProposal(contract, 'change_reason', {
                reason: values.reason,
                reasonPreset: preset > 0 ? preset : undefined
              });
            }, 'Propose');
        }
      },
      {
        // Only while nobody holds it: a hitman staked the figure they took
        // it at, and the server refuses to change it under them. Unheld, it
        // applies on this confirm, and the next hitman stakes the new one.
        label: stakeNow > 0 ? 'Raise the stake' : 'Ask for a stake',
        note: stakeNow > 0
          ? 'Now ' + money(stakeNow) + '. To lower it, use Change reward.'
          : 'Nobody has to put anything up to take it now.',
        skip: hitman || !untaken || stakeMost <= stakeNow,
        run: function () {
          askNumber(stakeNow > 0 ? 'Raise the stake' : 'Ask for a stake',
            'What a hitman puts up when they accept, returned when they finish '
              + 'and yours if they walk away or run out of time. Nobody has '
              + 'taken it, so this applies at once.',
            function (amount) {
              sendProposal(contract, 'raise_penalty', { amount: amount });
            },
            {
              label: 'Stake ($)',
              value: Math.min(stakeMost, stakeNow + 1000), min: stakeNow + 1, max: stakeMost,
              confirm: 'Set it',
              hint: function (value) {
                if (!value || value <= stakeNow || value > stakeMost) {
                  return 'Between ' + money(stakeNow + 1) + ' and ' + money(stakeMost)
                    + ', the most this contract can ask.';
                }
                return 'A hitman would stake ' + money(value) + ' to take it.';
              }
            });
        }
      },
      {
        label: hitman ? 'Call it off' : 'Cancel the contract',
        // Not "hand it back": agreed, this closes the whole contract for
        // everyone on it, the same as the client cancelling it. Walking away
        // alone is Abandon.
        note: hitman
          ? 'Ask for the whole contract to be cancelled. If everyone agrees it '
            + 'closes for all of you, and everything put up goes back, your stake '
            + 'included. To leave on your own, use Abandon.'
          : (untaken
            ? 'Nobody has taken it, so this is Withdraw, which asks first.'
            : 'Close it and take back what you put up, if the operative agrees.'),
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
          ask(hitman ? 'Ask to call it off?' : 'Ask to cancel the contract?',
            (hitman
              ? 'If everyone agrees it closes for all of you'
                + (Number(contract.penaltyAmount) > 0
                  ? ', and your ' + money(contract.penaltyAmount) + ' stake comes back to you.'
                  : '.')
              : 'If everyone on it agrees it closes, and what you put up comes back to you.'
                + (waits ? ' ' + waits : ''))
              + ' You can take the proposal back until it is answered.',
            function () { sendProposal(contract, hitman ? 'withdraw' : 'cancel', {}); },
            { yes: 'Propose it', no: 'Keep it' });
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
      detail: 'Pays ' + pays + ', ' + runsOut(left)
        + (total > 1 ? ', ' + total + ' payouts' : '')
        + (untaken
          // Nobody holds it, so there is nobody to wait for.
          ? '. Nobody has taken it, so this applies as soon as you confirm.'
          : '. Nothing happens until '
            + (hitman ? 'the person who placed it' : 'the operative') + ' agrees.')
        // More time and more money are the client's to give, at once, and
        // a hitman looking here for them found only ways to make it worse.
        + (hitman && settings().relay !== false
          ? ' For more time or money, message them.'
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
          limit_reached: 'There is already a change waiting on this contract. '
            + 'It has to be answered, or run out, before you can propose '
            + 'another.',
          invalid_input: 'That change no longer fits this contract \u2014 it '
            + 'has moved on since you opened it. Look again.',
          bad_state: 'This contract cannot be changed right now.',
          feature_off: 'Proposing changes is turned off by the server right now.'
        };
        // A new reason is refused for its words — too long, too many
        // digits, a banned pattern — not because the contract moved on.
        if (kind === 'change_reason') {
          reasons.invalid_input = 'This server will not take that reason. '
            + 'Word it differently.';
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
        say('Done \u2014 the change is in effect.', 'ok');
        return refresh();
      }
      if (r.data && r.data.outcome === 'failed') {
        say(ERRORS[r.data.err] || 'That change no longer fits this contract.');
        return refresh();
      }
      say('Proposed. The other party has to agree.', 'ok');
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
              + 'whoever is working it.',
              function (minutes) {
                post('improve', {
                  id: contract.id,
                  kind: 'extend_deadline',
                  payload: { seconds: minutes * 60 }
                }).then(function (r) {
                  if (!r.ok) return fail(r);
                  say('Deadline extended.', 'ok');
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
    // Named the way the Place form names it, so "bonus" is not left to
    // mean whichever bonus the reader guesses.
    var text = what + ' — ' + (line.portion === 'bonus' ? 'kidnapping bonus' : 'base');
    if ((Number(slots) || 1) > 1) {
      text = 'Payout ' + (Number(line.slot) || 1) + ': ' + text;
    }
    return text;
  }

  function renderRewardEditor(view) {
    var edit = state.reward;
    var panel = el('div', 'card dialog');
    panel.appendChild(el('div', 'target', 'Change the reward'));

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
      if (take) {
        var any = !!(amount || dirty || goods);
        take.className = (any ? 'primary' : 'ghost') + ' take-back';
        take.disabled = !any;
      }

      if (!amount && !dirty && !goods) {
        total.textContent = 'Nothing ticked yet.';
        return;
      }

      var parts = [];
      if (amount) { parts.push(money(amount)); }
      if (dirty) { parts.push(money(dirty) + ' dirty money'); }
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
          'Add more, or tick anything you want back. The rest stays on the contract.'));
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
    var add = el('button', 'ghost ico i-plus', 'Add to it');
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
      var lower = el('button', 'ghost', 'Lower the stake');
      lower.onclick = function () {
        var contract = edit.contract;
        state.dialog = null; state.reward = null;
        lowerStake(contract);
      };
      row.appendChild(lower);
    }

    if (edit.data && !edit.pending && takeable) {
      take = el('button', 'primary take-back', 'Take back what I ticked');
      take.onclick = function () { withdrawChosen(edit); };
      row.appendChild(take);
      showTotal();
    }

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
          return say('A payout has to keep something in it. To take the '
            + 'whole reward back, use Withdraw \u2014 that closes the contract '
            + 'and returns everything.');
        }
        return takenOr(r);
      }

      var queued = (r.data && r.data.queued) || 0;
      var checking = staffChecking(r.data);
      say(queued
        ? 'Taken off the contract. Some of it could not fit and is waiting '
          + 'for you — it arrives when you next have room.' + checking
        : checking ? 'Taken off the contract.' + checking
          : 'Taken off the contract and returned to you.', 'ok');

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
      return caps[source + 'Enabled'] !== false && (Number(wallet[source]) || 0) > 0;
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
      return say('You have nothing this server takes as a reward.');
    }

    // Every top-up lands the same way, whatever it is made of.
    function send(reward, tooMuch) {
      post('addEscrow', { id: contract.id, reward: reward }).then(function (r) {
        if (!r.ok && r.err === 'invalid_reward') { return say(tooMuch); }
        if (!r.ok) return fail(r);
        say('Added to the reward.', 'ok');
        state.wallet = null;
        refresh();
      });
    }

    function addItem() {
      askFields('Add an item to the reward',
        'Taken from you now and held with the rest.',
        [
          { id: 'item', label: 'Item', type: 'select', value: items[0].name,
            options: items.map(function (item) {
              return { value: item.name, label: item.label + '  \u00b7  ' + item.count + ' held' };
            }) },
          { id: 'count', label: 'How many', type: 'number', value: 1, min: 1 }
        ],
        function (values) {
          var held = 0;
          items.forEach(function (item) { if (item.name === values.item) { held = item.count; } });
          if (!values.count || values.count < 1 || values.count > held) {
            return say('You hold ' + held + ' of those.');
          }
          send({ baseline: { items: [{ name: values.item, count: values.count }] } },
            'This contract cannot carry that: it is already holding as much as it can.');
        }, 'Add');
    }

    function addWeapon() {
      askFields('Add a weapon to the reward',
        'Taken from you now and held with the rest. The hitman gets this one, '
          + 'serial and all.',
        [{ id: 'weapon', label: 'Weapon', type: 'select', value: String(weapons[0].slot),
           options: weapons.map(function (weapon) {
             return { value: String(weapon.slot),
                      label: weapon.label + (weapon.serial ? '  #' + weapon.serial : '') };
           }) }],
        function (values) {
          var found = null;
          weapons.forEach(function (weapon) {
            if (String(weapon.slot) === String(values.weapon)) { found = weapon; }
          });
          if (!found) { return say('That weapon is no longer in your pockets.'); }
          send({ baseline: { weapons: [{ name: found.name, slot: found.slot }] } },
            'This contract cannot carry that: it is already holding as much as it can.');
        }, 'Add');
    }

    function raiseBonus() {
      var later = Math.max(0, (Number(contract.slots) || 1) - (Number(contract.currentSlot) || 1));
      askNumber('Raise the kidnapping bonus',
        'Paid on top for delivering them alive. The extra is taken from you now '
          + 'and applies at once.',
        function (percent) {
          post('improve', { id: contract.id, kind: 'raise_bonus',
                            payload: { percent: percent } }).then(function (r) {
            if (!r.ok && r.err === 'invalid_reward') {
              return say('That bonus would take this contract past what this server '
                + 'allows, or there is no money left in it to work a bonus out from.');
            }
            if (!r.ok) return fail(r);
            say('Kidnapping bonus raised to ' + percent + '%.', 'ok');
            state.wallet = null;
            refresh();
          });
        },
        {
          label: 'Bonus (%)',
          value: Math.min(bonusCap, bonusNow + 10), min: bonusNow + 1, max: bonusCap,
          confirm: 'Raise',
          hint: function (value) {
            if (!value || value <= bonusNow || value > bonusCap) {
              return 'Now ' + bonusNow + '%. Between ' + (bonusNow + 1) + ' and '
                + bonusCap + '.';
            }
            return 'Now ' + bonusNow + '%. About ' + money(Math.floor(base * (value - bonusNow) / 100))
              + ' more from you' + (later > 0 ? ', and the same share of each later payout.' : '.');
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
        return say('This contract is already worth as much as this server allows one to be.');
      }
      askNumber('Add ' + (SOURCE_LABELS[source] || source).toLowerCase()
                  + ' to the reward',
        'It is taken from you now and held with the rest.',
        function (value) {
          var reward = { baseline: {} };
          reward.baseline[source] = value;
          send(reward, 'That would take this contract past the most one contract '
            + 'may be worth on this server.');
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

    var options = usable.map(function (source) {
      return {
        label: SOURCE_LABELS[source] || source,
        note: 'You hold ' + money(wallet[source]) + '.',
        run: function () { amountFrom(source); }
      };
    });
    if (items.length) {
      options.push({ label: 'Items', note: 'Something from your pockets.', run: addItem });
    }
    if (weapons.length) {
      options.push({ label: 'Weapons', note: 'You carry ' + weapons.length
        + (weapons.length === 1 ? ' weapon.' : ' weapons.'), run: addWeapon });
    }
    if (bonusRoom) {
      options.push({ label: 'Kidnapping bonus', note: 'Now ' + bonusNow
        + '%, paid on top for delivering them alive.', run: raiseBonus });
    }

    // One thing to add, straight to it. More than one, ask which first.
    if (options.length === 1) { return options[0].run(); }

    state.dialog = {
      kind: 'choice',
      question: 'Add to the reward',
      detail: 'Taken from you now and held with the rest.',
      options: options
    };
    render();
  }

  /* Lower the stake a hitman puts up, or take it off. Applies at once:
     it can only help whoever is on it, and anyone who already staked the
     old figure gets the difference back. */
  function lowerStake(contract) {
    var now = Number(contract.penaltyAmount) || 0;
    var detail = 'Now ' + money(now) + '. This applies at once'
      + (Number(contract.hitmenActive) > 0
        ? ', and anyone already staked gets the difference back.' : '.');

    function send(amount) {
      post('improve', { id: contract.id, kind: 'lower_penalty',
                        payload: { amount: amount } }).then(function (r) {
        if (!r.ok) return fail(r);
        say(amount > 0 ? 'Stake lowered to ' + money(amount) + '.' : 'Stake removed.', 'ok');
        refresh();
      });
    }

    state.dialog = {
      kind: 'choice',
      question: 'Lower the stake',
      detail: detail,
      options: [
        {
          label: 'Lower it', note: 'To a smaller figure.', skip: now <= 1,
          run: function () {
            askNumber('Lower the stake', detail, send, {
              label: 'New stake ($)', value: Math.max(1, Math.floor(now / 2)),
              min: 1, max: now - 1, confirm: 'Lower',
              hint: function (value) {
                if (!value || value < 1 || value >= now) {
                  return 'Between ' + money(1) + ' and ' + money(now - 1) + '.';
                }
                return 'A hitman would stake ' + money(value) + ' to take it.';
              }
            });
          }
        },
        { label: 'Remove it', note: 'Nobody has to put anything up to take it.',
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

  /* What the player is told when no call rang, by the server's reason.
     It used to be "they have been asked to call you back" every time, on
     servers where the other side had no way to do that either. */
  var CALL_NOT_PLACED = {
    callback: 'They have been asked to call you back.',
    both_anonymous: 'Both of you are anonymous, so calls are off for this '
      + 'contract. Use messages.',
    no_calls: 'They have been told you want to talk. This server cannot '
      + 'place calls, so use messages.',
    not_placed: 'The call could not be placed, so they have been told you '
      + 'want to talk. Use messages.',
    unreachable: 'They could not be reached. Use messages.'
  };

  function requestCall() {
    var t = state.thread;
    if (!t) { return; }

    post('requestCall', {
      id: t.contract.id,
      thread: t.thread ? t.thread.handle : null
    }).then(function (r) {
      if (!r.ok) { return fail(r); }
      // Say which actually happened. Telling the player a call is
      // connecting when none is would be worse than any of the others.
      if (r.data && r.data.placed) {
        state.call = threadKey(t.contract, t.thread);
        // Redrawn only where the player still is, so Hang up appears
        // without a late reply rebuilding some other page under them.
        if (state.tab === 'thread' && sameThread(state.thread, t.contract, t.thread)) {
          render();
        }
        return say('Calling. Hang up here when you are done.', 'ok');
      }
      var line = CALL_NOT_PLACED[r.data && r.data.reason];
      say(typeof line === 'string' ? line : CALL_NOT_PLACED.not_placed, 'ok');
    });
  }

  /* Mute or unmute the open thread, for this player only (§11.4): their
     phone stops ringing for its messages, which still arrive and still
     show here. Nothing about it reaches the other side. */
  function toggleMute() {
    var t = state.thread;
    if (!t) { return; }

    return post('muteThread', {
      id: t.contract.id,
      thread: t.thread ? t.thread.handle : null,
      muted: !t.muted
    }).then(function (r) {
      if (!r.ok) {
        if (leaveDeadThread(r, t.contract, t.thread)) { return; }
        return fail(r);
      }
      var muted = !!(r.data && r.data.muted === true);
      // Onto the thread as it stands now — a push can have re-read it
      // meanwhile — and redrawn only where the player still is.
      if (sameThread(state.thread, t.contract, t.thread)) {
        state.thread.muted = muted;
        if (state.tab === 'thread') { render(); }
      }
      say(muted
        ? 'Muted: new messages will not ring your phone. Contract updates still will.'
        : 'Unmuted: new messages will ring your phone again.', 'ok');
    });
  }

  function endCall() {
    post('endCall', {}).then(function (r) {
      if (!r.ok) { return fail(r); }
      state.call = null;
      if (state.tab === 'thread') { render(); }
      // Over already — the other side hung up or never answered — is said
      // as it is, rather than claiming this ended it.
      say(r.data && r.data.ended ? 'Call ended.' : 'The call had already ended.', 'ok');
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
      return openThread(t.contract, t.thread, { reread: true });
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
      var again = el('button', 'ghost ico i-refresh', 'Try again');
      again.onclick = function () { delete state.loadFailed[section]; refresh(); render(); };
      failed.appendChild(again);
    }
    view.appendChild(failed);
    return true;
  }

  /* A refusal no retry from this page can change: the server's boot
     recovery failed, and it answers nothing until staff restart it. A Try
     again beside it was a button that could never work. */
  function finalRefusal(code) {
    return code === 'recovery_failed';
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

    // The board is sent a page at a time. With no pager, every contract past
    // the first page could never be seen or taken from the phone.
    var page = Number(data.page) || 1;
    var pages = Number(data.pages) || 1;
    if (pages > 1) {
      var nav = el('div', 'row pager');
      var back = el('button', 'ghost ico i-left', 'Back');
      back.disabled = page <= 1;
      back.onclick = function () { state.boardPage = page - 1; refresh(); };
      var forward = el('button', 'ghost ico ico-end i-right', 'More');
      forward.disabled = page >= pages;
      forward.onclick = function () { state.boardPage = page + 1; refresh(); };
      nav.appendChild(back);
      nav.appendChild(el('div', 'page-of', 'Page ' + page + ' of ' + pages));
      nav.appendChild(forward);
      view.appendChild(nav);
    }
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
      view.appendChild(el('div', 'empty', 'Nobody is looking for you. That you know of.'));
      return;
    }
    view.appendChild(el('div', 'notice', 'There is a price on your head.'));
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

    view.appendChild(el('div', 'notice ok', 'You\u2019re on a whitelisted job, so this app '
      + (shared ? 'only shows contracts on you and on other whitelisted-job members.'
        : 'only shows contracts on you.')));
    if (!mine.length && !others.length) {
      view.appendChild(el('div', 'empty', shared
        ? 'No contracts on you or other whitelisted-job members.' : 'No contracts on you.'));
      return;
    }
    if (!shared) {
      mine.forEach(function (entry) { view.appendChild(jobViewCard(entry, true)); });
      return;
    }

    view.appendChild(el('h3', 'section', 'Contracts on you'));
    if (mine.length) {
      mine.forEach(function (entry) { view.appendChild(jobViewCard(entry, true)); });
    } else {
      view.appendChild(el('div', 'hint', 'None on you.'));
    }
    view.appendChild(el('h3', 'section', 'Contracts on whitelisted jobs'));
    if (others.length) {
      others.forEach(function (entry) { view.appendChild(jobViewCard(entry, false)); });
    } else {
      view.appendChild(el('div', 'hint', 'None on other whitelisted-job members.'));
    }
  }

  /* One entry of the whitelisted-job view. `own` is a contract on this
     player, the one place its buyout is drawn. */
  function jobViewCard(entry, own) {
    var node = el('div', 'card');
    var head = el('div', 'card-head');
    var left = el('div', 'card-identity');
    left.appendChild(portrait(entry.targetName, null));
    var who = el('div', 'identity');
    who.appendChild(el('div', 'target', entry.targetName || 'Unknown'));
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
        ? chip('Taken by ' + taken + (taken === 1 ? ' hitman' : ' hitmen'), 'hot', 'i-users')
        : chip('Open \u2014 no hitman yet', null, 'i-users'));
    }
    var posted = agoText(entry.postedAt);
    if (posted) {
      meta.appendChild(chip('Posted ' + posted.charAt(0).toLowerCase() + posted.slice(1),
        null, 'i-flag'));
    }
    var clock = clockChip(entry);
    if (clock) { meta.appendChild(clock); }
    node.appendChild(meta);

    if (own) {
      var row = el('div', 'row actions');
      appendBuyout(row, entry);
      node.appendChild(row);
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
      stats.appendChild(tally(record.completed, 'completed'));
      // What the success rate is worked out from beside it: the rate was
      // drawn and the contracts that brought it down were not.
      if (typeof record.failed === 'number') {
        stats.appendChild(tally(record.failed, 'abandoned or lost'));
      }
      stats.appendChild(tally(record.placed, 'placed'));
      stats.appendChild(tally(record.survived, 'survived'));
      if (record.rate !== undefined && record.rate !== null) {
        stats.appendChild(tally(record.rate + '%', 'success'));
      }
      card.appendChild(stats);
      view.appendChild(card);
    }

    /* Payments of theirs that would not fit and wait for room. A receipt
       missed, or a page closed, was the only word of them anywhere. A count
       of their own and nothing else. */
    var waiting = Number(data.waiting) || 0;
    if (waiting > 0) {
      view.appendChild(el('div', 'hint', waiting + ' payment' + (waiting === 1 ? '' : 's')
        + ' waiting for room. Make room and ' + (waiting === 1 ? 'it is' : 'they are')
        + ' handed over.'));
    }

    /* Photos kept for this client in the app whose ledger row is gone:
       pushed off by newer rows, or past the days a row keeps its photo. A
       kept photo outlives its row, and this is where its owner finds it. */
    var kept = asList(data.kept).filter(function (photo) {
      return photo && typeof photo === 'object' && photo.state === 'kept';
    });

    if (!rows.length && !kept.length) {
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
      view.appendChild(el('h3', 'section', 'Photos kept in this app'));
      kept.forEach(function (photo) {
        var node = el('div', 'card');
        node.appendChild(el('div', 'target', 'Kill photo'));
        var taken = agoText(photo.taken_at);
        if (taken) { node.appendChild(el('div', 'reason', 'Taken ' + taken.toLowerCase())); }
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
      line.appendChild(actionButton('ghost ico i-camera', 'View photo',
        'proof:' + photo.handle, 'Opening\u2026',
        function () { return openProof(photo.handle); }));
      line.appendChild(el('div', 'hint', photo.state === 'kept'
        ? 'Kept for you in this app.' : 'You can see it once.'));
    } else if (PROOF_WORDS[photo.state]) {
      line.appendChild(el('div', 'hint', PROOF_WORDS[photo.state]));
    }
    return line;
  }

  // The icon beside the part a player played in a closed contract.
  var ROLE_ICONS = { hitman: 'i-user', creator: 'i-briefcase', target: 'i-eye' };

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
    var stamp = el('div', 'hint build-stamp', 'Crimson-Hitman build ' + build);
    stamp.onclick = function () { Diag.tapped(); };
    return stamp;
  }

  function viewThread(view) {
    var t = state.thread;
    if (!t) { state.tab = 'mine'; return render(); }

    // The head stays on the top edge (see the stylesheet): Back, who and
    // what the thread is about, and Call on one line, Mute on its own under
    // them.
    var head = el('div', 'thread-head');
    var row = el('div', 'row thread-bar');
    head.appendChild(row);

    var back = el('button', 'ghost ico i-left', 'Back');
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
    var placerSide = t.contract.role === 'hitman';
    var withWhom = placerSide ? 'the person who placed it'
      : t.thread && t.thread.alias
        ? t.thread.alias + (t.thread.name ? ' (' + t.thread.name + ')' : '')
        : null;
    var about = el('div', 'hint');
    if (t.contract.targetName) {
      about.appendChild(el('div', 'about', t.contract.targetName));
    }
    if (withWhom) {
      about.appendChild(el('div', 'with', 'with ' + withWhom));
    }
    row.appendChild(about);

    // The server has always had a call path and nothing reached it, so the
    // whole feature was unreachable from the phone.
    //
    // Not when both sides are anonymous: neither can be rung and the server
    // sends nothing, so the button could only say calls were off. A
    // creator's thread names the operative only when they chose to be seen.
    var bothAnonymous = t.contract.creatorAnonymous === true
      && (t.contract.role === 'hitman'
        ? t.contract.myAnonymous === true
        : !!(t.thread && !t.thread.name));
    if (settings().calls && !bothAnonymous) {
      if (state.call === threadKey(t.contract, t.thread)) {
        // lb-phone draws no call screen for a call placed from here — its
        // CreateCall is built for payphones — so this is the only way the
        // caller can put the phone down.
        var hang = el('button', 'ghost ico i-xcircle', 'Hang up');
        hang.id = 'thread-hangup';
        hang.onclick = function () { endCall(); };
        row.appendChild(hang);
      } else {
        var call = el('button', 'ghost ico i-phone', 'Call');
        call.id = 'thread-call';
        call.onclick = function () { requestCall(); };
        row.appendChild(call);
      }
    }

    // Silences this thread's ring on this phone only. Words rather than an
    // icon, because which way it is set is the whole point of the button.
    //
    // On a line of its own. In the one above, its width came out of the
    // who-and-what in the middle, the only thing in the head that cannot
    // be put back with a tap: at 390px "with Operative #2" was cut to
    // "with Operat…", and a client with several operatives could not tell
    // which one they were writing to.
    var mute = actionButton('ghost', t.muted ? 'Unmute' : 'Mute',
      'mute:' + threadKey(t.contract, t.thread),
      t.muted ? 'Unmuting\u2026' : 'Muting\u2026',
      function () { return toggleMute(); });
    mute.id = 'thread-mute';
    var tools = el('div', 'row thread-tools');
    tools.appendChild(mute);
    head.appendChild(tools);

    view.appendChild(head);

    var thread = el('div', 'thread');
    t.messages.forEach(function (m) {
      var msg = el('div', 'msg' + (m.mine ? ' mine' : ''));
      // Signed by the placer, to a hitman: a message stored before the
      // server named them so still carries "Client".
      msg.appendChild(el('div', 'who', placerSide && !m.mine && (!m.alias || m.alias === 'Client')
        ? 'The person who placed it' : m.alias));
      msg.appendChild(el('div', null, m.body));
      thread.appendChild(msg);
    });
    // A new thread was a header and a text box with nothing between them.
    if (!t.messages.length) {
      thread.appendChild(el('div', 'hint', 'No messages yet.'));
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
    var input = document.createElement('input');
    input.id = 'compose-input';
    input.placeholder = 'Say something';
    input.maxLength = settings().messageMaxLength || 200;
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
    if (state.walletFailed && state.walletFailed.final) {
      var closed = el('div', 'card');
      closed.appendChild(el('div', 'hint', state.walletFailed.text));
      form.appendChild(closed);
    } else if (state.walletFailed) {
      var failed = el('div', 'card');
      failed.appendChild(el('div', 'hint', state.walletFailed.text
        + ' Money still works; items and weapons need another look.'
        + (state.walletFailed.code ? ' (code: ' + state.walletFailed.code + ')' : '')));
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
            // fault the server could have named in one word. Labelled and
            // put last, after the sentence, so it reads as something to
            // quote rather than as part of what the player is being told.
            // Not "Money still works" where nothing does: the server's
            // boot recovery failed, and placing is refused too.
            state.walletFailed = (r.err === 'rate_limited')
              ? { text: 'Reading your pockets too fast. Try again in a moment.' }
              : finalRefusal(r.err)
                ? { text: ERRORS[r.err], final: true }
                : { text: 'Could not read what you are carrying.',
                    code: r.err || 'no reply' };
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
    [['exclusive', 'Exclusive — one hitman'],
     ['competitive', 'Competitive — first to finish']].forEach(function (o) {
      var opt = document.createElement('option');
      opt.value = o[0]; opt.textContent = o[1];
      mode.appendChild(opt);
    });
    job.appendChild(labelled('Assignment', drafted(mode, 'mode', 'exclusive')));
    form.appendChild(job);

    var pay = formSection('Payment');

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
      pay.appendChild(labelled('Payouts (how many times it can be collected)', slots));
      var ceilingNote = el('div', 'hint');
      ceilingNote.id = 'slots-ceiling';
      pay.appendChild(ceilingNote);
      pay.appendChild(el('div', 'hint',
        'Every payout is funded and escrowed up front. More hitmen may accept than there are ' +
        'payouts — the first to finish are paid.'));
    }
    // The least a contract may be worth (caps.minValue, 0 for none), said
    // where the money is set rather than in a refusal once it is all filled
    // in. The bonus counts towards it, as it does towards the ceiling.
    var payCaps = (state.wallet && state.wallet.caps) || {};
    var leastValue = Number(payCaps.minValue) || 0;
    if (leastValue > 0) {
      pay.appendChild(el('div', 'hint', minRewardText(leastValue)
        + (placingAliveOnly() || payCaps.bonusPercent === 0 ? '' : ' The kidnapping bonus does.')));
    }
    // What a payout is paid for, on a server that places contracts for a
    // live delivery only. Said where the money is set, since it is what the
    // money buys, and in place of the bonus field, whose hint was the only
    // thing that told a creator they have to be at the handover.
    if (placingAliveOnly()) {
      pay.appendChild(el('div', 'hint',
        'Contracts here only pay when the target is brought to you alive. You need '
        + 'to be in the city to meet the hitman for the handover.'));
    }

    var slotBox = el('div');
    slotBox.id = 'slots';
    pay.appendChild(slotBox);
    form.appendChild(pay);

    var terms = formSection('Terms');

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
      // Opens at 50 or the ceiling, whichever is lower: a max attribute
      // does not hold a value set from script, so under a lower ceiling it
      // opened at 50 beside "(up to 25)" and was charged at 50.
      var bonusOpen = String(bonusCap ? Math.min(50, bonusCap) : 50);
      var bonusField = drafted(numberInput('bonus', bonusOpen), 'bonus', bonusOpen);
      if (bonusCap) { bonusField.max = bonusCap; }
      terms.appendChild(labelled(
        'Kidnapping bonus %' + (bonusCap ? ' (up to ' + bonusCap + ')' : ''),
        bonusField));
      // It opens at 50 and is money taken now, which nothing said: a creator
      // holding exactly what they entered was refused for the half on top.
      // The total it comes to is said above the Place button.
      terms.appendChild(el('div', 'hint',
        'Paid on top of ' + (slotCeiling() > 1 ? 'a payout' : 'the reward')
        + ' when the target is delivered alive, plus any '
        + 'items marked alive only. It is taken from you now with the rest, and '
        + 'comes back if nobody earns it. Set 0 for none. Delivered alive means '
        + 'brought to you: you have to be there in person for the handover.'));
    }
    // Not on a server without buyouts, where the figure was taken and then
    // quietly set to nothing.
    if (settings().buyouts !== false) {
      terms.appendChild(labelled('Buyout price (0 for none)',
        drafted(numberInput('bailout', 0), 'bailout', '0')));
      // The server holds the price between the clean money in the reward,
      // bonus lines included, and a multiple of it, and moves anything
      // outside to the nearest limit without a word: $1,000 on $10,000 with
      // the 50% bonus became $15,000. Said here, and the price it settled on
      // is said once it is placed and on the client's card.
      terms.appendChild(el('div', 'hint',
        'What the target can pay to close this early. It is kept between the '
        + 'cash and bank you put up' + (placingAliveOnly() ? '' : ' (kidnapping bonus included)')
        + ' and a few times that, and is moved to the nearest limit if outside.'));
    } else {
      delete state.draft.bailout;
    }
    // "Stake", the word every card, dialog and proposal uses for it. Set
    // here as a "failure penalty", it came back on the client's own card as
    // "$5,000 stake", which read as a second figure.
    terms.appendChild(labelled("Hitman's stake (0 for none)",
      drafted(numberInput('penalty', 0), 'penalty', '0')));
    terms.appendChild(el('div', 'hint',
      'A hitman stakes this when they accept, and forfeits it to you if they walk away.'));

    // How long it runs. The form has no deadline of its own: every contract
    // gets the server's default, and nothing here said what that was, so a
    // client expecting a day-long contract who never opened Edit had it
    // lapse after three hours.
    //
    // And while whom: a named client's clock also stops while they are
    // away, an anonymous one's follows the target alone (§14.32), so it
    // follows the checkbox. The lifetime runs through every stop, and no
    // extension goes past it.
    function clockHint() {
      var ceiling = Number(settings().deadlineMaxMinutes) || 0;
      return 'It runs for ' + durationText(Number(settings().defaultDeadlineMinutes) || 180)
        + (state.draft.anon === true
          ? ' while the target is in the city'
          : ' while you and the target are both in the city')
        + ', then lapses and what you put up comes back. Extend it from Mine '
        + '\u2192 Extend deadline'
        + (ceiling > 0 ? ', up to ' + durationText(ceiling) + ' after you place it.' : '.');
    }
    var clock = el('div', 'hint', clockHint());
    terms.appendChild(clock);

    var anon = document.createElement('input');
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
    toggle.appendChild(el('span', null, 'Place anonymously'
      + (anonymityFee('creator') > 0 ? ' (costs ' + money(anonymityFee('creator'))
        + ' from your ' + anonymityAccount() + ')' : '')));
    terms.appendChild(toggle);
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
      // Numbered only where there can be more than one.
      slot.appendChild(el('h4', null, slotCeiling() > 1 ? 'Payout ' + i : 'Reward'));

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
          return caps[source + 'Enabled'] === false;
        }).map(function (source) { return SOURCE_LABELS[source].toLowerCase(); });
        if (off.length && i === 1) {
          slot.appendChild(el('div', 'hint', 'This server does not take '
            + off.join(' or ') + ' as a reward.'));
        }
      } else {
        slot.appendChild(el('div', 'hint',
          'This server does not take money as a reward. Items and weapons '
          + 'below, if it takes those.'));
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

    wrap.appendChild(el('h5', 'goods-title', 'Items & weapons'));

    if (!wallet) {
      wrap.appendChild(el('div', 'hint', 'Reading your pockets\u2026'));
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
      var tail = (half === picked) ? '' : ' \u2014 alive only';
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
      var alive = document.createElement('input');
      alive.type = 'checkbox'; alive.id = 'slot-alive-' + index;
      alive.checked = picked.aliveOnly === true;
      alive.onclick = function () { picked.aliveOnly = alive.checked; };
      var aliveToggle = document.createElement('label');
      aliveToggle.className = 'toggle';
      aliveToggle.htmlFor = alive.id;
      aliveToggle.appendChild(alive);
      aliveToggle.appendChild(el('span', null, 'Only if delivered alive'));
      wrap.appendChild(aliveToggle);
    }

    if (items.length === 0 && weapons.length === 0) {
      wrap.appendChild(el('div', 'hint', goodsAbsenceReason(wallet, caps)));
    } else if (caps.itemsEnabled === false || caps.weaponsEnabled === false) {
      // One of the two switched off while the other is offered: the
      // missing picker read as an app that failed to read the pockets.
      wrap.appendChild(el('div', 'hint', caps.itemsEnabled === false
        ? 'This server does not take items as a reward.'
        : 'This server does not take weapons as a reward.'));
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
    // Only the money this server takes, and none where it takes none.
    var taken = moneyTaken();
    if (taken === 'money') {
      return 'You are not carrying anything that can be put up as a reward.';
    }
    return 'You are not carrying anything that can be put up as a reward. '
      + taken.charAt(0).toUpperCase() + taken.slice(1) + ' above still '
      + (taken.indexOf(' and ') === -1 ? 'works.' : 'work.');
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
      option.textContent = item.label + '  \u00b7  ' + free + ' spare';
      if (item.namesOwner && placingAnonymously()) {
        naming[item.name] = true;
        option.disabled = true;
        option.textContent = item.label + '  \u00b7  carries your name';
      }
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
      if (naming[name]) {
        return say(labelOf(items, name) + ' carries your name or number, so it cannot go '
          + 'on a contract placed anonymously.');
      }

      var caps = state.wallet.caps || {};
      // The half the pick goes into. The server bounds each half on its
      // own, so the limits below are counted the same way.
      var picked = pickedFor(index);
      if (picked.aliveOnly) { picked = picked.alive; }
      var held = 0;
      items.forEach(function (item) { if (item.name === name) { held = item.count; } });

      if (allocatedItem(name) + wanted > held) {
        return say('You only have ' + (held - allocatedItem(name)) + ' of those spare.');
      }
      if ((picked.items[name] || 0) + wanted > (caps.maxPerStack || Infinity)) {
        return say('That is more than ' + (slotCeiling() > 1 ? 'one payout' : 'the reward')
          + ' can hold of a single item.');
      }
      if (picked.items[name] === undefined
          && Object.keys(picked.items).length >= (caps.maxStacks || Infinity)) {
        return say((slotCeiling() > 1 ? 'This payout' : 'The reward')
          + ' is already carrying as many kinds of item as it can.');
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
      if (picked.aliveOnly) { picked = picked.alive; }
      if (Object.keys(picked.weapons).length >= (caps.maxWeapons || Infinity)) {
        return say((slotCeiling() > 1 ? 'This payout' : 'The reward')
          + ' is already carrying as many weapons as it can.');
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
    var words = { cash: 'cash', bank: 'bank', dirty: 'dirty money' };
    ['cash', 'bank', 'dirty'].forEach(function (src) {
      var all = composed.totals[src];
      if (!all) { return; }
      var extra = composed.bonus[src];
      parts.push(money(all) + ' ' + words[src] + (extra
        ? ' (' + money(all - extra) + ' + ' + money(extra) + ' kidnapping bonus)' : ''));
    });

    // One entry per item and half, summed over the payouts; each weapon on
    // its own, since two of one model are two objects.
    var goods = [], byKey = {};
    for (var i = 1; i <= payoutCount(); i++) {
      var picked = state.picked[i];
      if (!picked) { continue; }
      stagedHalves(picked).forEach(function (half) {
        var tail = (half === picked) ? '' : ' (alive only)';
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
      : parts.slice(0, -1).join(', ') + ' and ' + parts[parts.length - 1];
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
    if (!taken) { node.textContent = 'Nothing in the reward yet.'; return; }

    var text = 'Taken from you now: ' + taken + '.';
    // The fee is charged, not held, so it is said apart from the escrow.
    var fee = state.draft.anon === true ? anonymityFee('creator') : 0;
    if (fee > 0) {
      text += ' Plus ' + money(fee) + ' from your '
        + ((settings().anonymityFees || {}).account === 'cash' ? 'cash' : 'bank')
        + ' for anonymity.';
    }
    var bonus = composed.bonus.cash + composed.bonus.bank + composed.bonus.dirty;
    if (bonus > 0 || taken.indexOf('(alive only)') !== -1) {
      text += ' The bonus comes back to you if the target is killed rather than delivered.';
    }
    node.textContent = text;
  }

  /* The confirmation, saying what was held and the terms the server
     settled on. It said only "Contract placed.": the buyout and the stake
     are moved to the nearest amount the reward allows without a word, and
     the deadline was the server's default, which the form never named. */
  function placedText(held, placed, asked) {
    var text = 'Contract placed.';
    if (held) { text += ' Held from you: ' + held + '.'; }

    var terms = [];
    var moved = [];
    if (typeof placed.bailoutAmount === 'number' && placed.bailoutAmount > 0) {
      terms.push('Buyout ' + money(placed.bailoutAmount));
      if (asked.bailout > 0 && asked.bailout !== placed.bailoutAmount) { moved.push('buyout'); }
    }
    if (typeof placed.penaltyAmount === 'number' && placed.penaltyAmount > 0) {
      terms.push('stake ' + money(placed.penaltyAmount));
      if (asked.penalty > 0 && asked.penalty !== placed.penaltyAmount) { moved.push('stake'); }
    }
    if (terms.length) { text += ' ' + terms.join('; ') + '.'; }
    if (moved.length) {
      text += ' The ' + moved.join(' and the ') + (moved.length > 1 ? ' were' : ' was')
        + ' moved to the nearest amount this reward allows.';
    }
    // A stake asked for and none placed: the reward cannot carry one.
    if (asked.penalty > 0 && placed.penaltyAmount === 0) {
      text += ' No stake was set: this reward cannot carry one.';
    }

    // What anonymity cost, as the server took it (the reply's `charged`).
    var charged = placed.charged || {};
    if (Number(charged.fee) > 0) {
      text += ' Placing it anonymously cost ' + money(Number(charged.fee)) + ' from your '
        + (charged.account === 'cash' ? 'cash' : 'bank') + '.';
    }

    // How it is completed, where that is not what the form said.
    if (typeof placed.fulfilment === 'string'
        && (placed.fulfilment !== 'either') !== (asked.aliveOnly === true)) {
      text += placed.fulfilment === 'either'
        ? ' A kill completes it as well as a live handover.'
        : ' It only pays when the target is brought to you alive.';
    }

    var seconds = Number(placed.secondsLeft);
    var minutes = seconds > 0 ? Math.ceil(seconds / 60)
      : Number(settings().defaultDeadlineMinutes) || 0;
    if (minutes > 0) {
      text += ' It runs out in ' + durationText(minutes) + ' unless you extend it.';
    }
    return text;
  }

  function submitContract() {
    // From the draft, not the DOM: the sworn-officer confirmation renders a
    // dialog over the form, which empties #view. Reading the controls here
    // meant the first submit always failed and the second submitted nothing.
    var target = state.draft.target || document.getElementById('target-handle').value;
    if (!target) return say('Choose a target.');

    var count = payoutCount();
    var moneyFields = ['bonus', 'bailout', 'penalty'];
    for (var k = 1; k <= count; k++) {
      moneyFields.push('slot-cash-' + k, 'slot-bank-' + k, 'slot-dirty-' + k);
    }
    if (badAmounts(moneyFields)) {
      return say('Amounts are whole dollars, written out in full (100000, not 1e5).');
    }
    var caps = (state.wallet && state.wallet.caps) || {};
    var labels = { cash: 'Cash', bank: 'Bank', dirty: 'Dirty money' };

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
          return say((numbered ? 'Payout ' + i + ': ' : '') + labels[src] + ' is at most '
            + money(cap) + ' on this server.');
        }
      }

      // A payout has to pay something for a kill. Goods marked alive only
      // do not: the server refuses a payout whose kill half is empty.
      if (!baseline.cash && !baseline.bank && !baseline.dirty
          && !baseline.items && !baseline.weapons) {
        var which = numbered ? 'Payout ' + i : 'The reward';
        return say(slots[i - 1].bonus
          ? which + ' pays nothing for a kill. Put something in it '
            + 'that is not marked alive only.'
          : numbered ? which + ' has no reward in it.' : 'There is no reward in it yet.');
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
        return say(labels[held] + (numbered ? ' across every payout' : ' in the reward')
          + (bonusPct > 0 ? ', with the ' + bonusPct + '% kidnapping bonus taken now on top,' : '')
          + (creatorFee > 0 && held === creatorFeeAccount
            ? ' plus the ' + money(creatorFee) + ' anonymity fee,' : '')
          + ' comes to ' + money(need[held]) + '. You hold ' + money(have) + '.');
      }
    }

    var worth = totals.cash + totals.bank + totals.dirty;
    var maxValue = Number(caps.maxValue) || 0;
    if (maxValue > 0 && worth > maxValue) {
      return say('This contract would be worth ' + money(worth)
        + (bonusPct > 0 ? ' with its kidnapping bonus' : '')
        + '; this server allows at most ' + money(maxValue) + '.');
    }
    // And the least, counted the same way: refused by the server as
    // reward_too_small, it is said here first with both figures.
    var minValue = Number(caps.minValue) || 0;
    if (minValue > 0 && worth < minValue) {
      return say('This contract would be worth ' + money(worth) + ' in money'
        + (bonusPct > 0 ? ' with its kidnapping bonus' : '') + '. '
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
      return say('A hitman\'s stake is held against the cash and bank in the reward, '
        + 'and this one has none, so it cannot carry a stake. Add cash or bank, or set '
        + 'the stake to 0.');
    }
    // Something staged that says whose it is, on a contract placed
    // anonymously: the server refuses the whole contract for it.
    var named = placingAnonymously() ? stagedNamingOwner() : null;
    if (named) {
      return say(itemLabel(named) + ' carries your name or number, and the hitman would '
        + 'be handed it as it is, which would give you away. Take it out, or place the '
        + 'contract under your name.');
    }
    var maxLines = (state.wallet && state.wallet.caps && state.wallet.caps.maxLines) || Infinity;
    if (lines > maxLines) {
      return say('This contract holds ' + lines + ' separate rewards and this '
        + 'server takes at most ' + maxLines + '. ' + (numbered
          ? 'Use fewer payouts, or take some of the items and weapons back out.'
          : 'Take some of the items and weapons back out.'));
    }

    // Asked, every time: with a bulletin on it stated a fact under a Yes
    // button and never asked the question. "Every officer in the city", not
    // "on duty": the bulletin goes to every officer whose job receives it,
    // on duty or off, and the narrower words told the creator fewer would
    // hear than do.
    var protectedTarget = state.draft.targetProtected === true;
    if (protectedTarget && settings().warnCreator !== false && !state.leoConfirmed) {
      ask('That target ' + protectedWords(state.draft.targetProtectedAs).is + '.',
          (advised('posted')
            ? 'Placing this will alert every officer in the city, by phone and over dispatch. '
            : advised('accepted')
              ? 'Every officer in the city will be alerted when someone accepts it. '
              : '')
            + 'Place a contract on them anyway?',
          function () { state.leoConfirmed = true; submitContract(); },
          { yes: 'Place it', no: 'Cancel' });
      return;
    }
    // Agreed to (or never asked, where the server warns nobody): sent with
    // the contract, and a target who took a protected job after being
    // picked is refused until the warning has been seen.
    var protectedAck = protectedTarget && state.leoConfirmed === true;
    state.leoConfirmed = false;

    // Kept for the confirmation: the draft is cleared once it is placed.
    var held = takenText(composed);
    var asked = { bailout: num('bailout'), penalty: num('penalty'),
                  aliveOnly: placingAliveOnly() };

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
      }
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
          return say(itemLabel(r.data.item) + ' carries your name or number, and the hitman '
            + 'would be handed it as it is, which would give you away. Take it out, or '
            + 'place the contract under your name.');
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
          delete state.draft.targetProtectedAs;
          state.browse.data = null;
          state.browse.pending = null;
          state.browse.refusal = null;
          say('That person cannot be picked any more — they may have left '
            + 'the city. The list has been read again; choose who this is for.');
          return render();
        }
        // Nothing staged, so it is the money: the balances this form checked
        // against were read when it opened. Read again, and said so.
        if (r.err === 'insufficient_funds') {
          state.wallet = null;
          state.walletFailed = null;
          say('The server could not take that much from you \u2014 your balances '
            + 'may have changed since you opened this form. They have been read '
            + 'again; check the amounts.');
          return render();
        }
        // The limit is on contracts placed, counted across the account's
        // characters. "You are holding too many contracts" was said to a
        // client holding none.
        if (r.err === 'limit_reached') {
          var most = Number(r.data && r.data.max);
          return say('You already have '
            + (most > 0 ? most + ' contract' + (most === 1 ? '' : 's')
              + ' out, the most this server allows' : 'as many contracts out as this server allows')
            + ', counting the ones placed from your other characters. '
            + 'Wait for one to close, or withdraw one nobody has taken yet '
            + 'under Mine.');
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
    law: { chip: 'Law enforcement', tag: 'Law', is: 'is a sworn officer',
           noun: 'a sworn officer' },
    emergency: { chip: 'Emergency services', tag: 'EMS', is: 'works in emergency services',
                 noun: 'someone in emergency services' },
    legal: { chip: 'Legal', tag: 'Legal', is: 'works in the legal system',
             noun: 'someone in the legal system' },
    other: { chip: 'Protected job', tag: 'Protected', is: 'works in a protected job',
             noun: 'someone in a protected job' }
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
    // Who is chosen, on a line of its own under the list. It was written
    // into `status`, which the list's own count overwrites on every
    // rebuild, so after the wallet landed or a push nothing on the form
    // named the person it would be placed on.
    var chosen = el('div', 'hint');
    function sayChosen() {
      show(chosen, state.draft.targetName
        ? 'Contract will be placed on ' + state.draft.targetName + '.' : '');
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

    /* A refusal, drawn the same way: into whichever picker is on screen.
       It was written into the picker that asked, which by then had been
       replaced, so the player saw an empty picker with no words and
       nothing to press. With a way to ask again, because it is not asked
       again on its own: a refusal is usually the rate limit. */
    browse.showRefusal = function (text) {
      results.innerHTML = '';
      show(status, text);
      var again = el('button', 'ghost', 'Try again');
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
          if (browse.scope === 'nearby') { browse.nearbyClosed = browse.data.closed === true; }
          if (browse.draw) { browse.draw(browse.data); }
        });
    }

    function refused(r) {
      browse.data = null;
      browse.refusal = r.err === 'rate_limited'
        ? 'Looking too fast. Try again in a moment.'
        // Named for the same reason as the wallet failure above: the code
        // is what an admin needs and the player is the one who can see it.
        : 'Could not read who is online (' + (r.err || 'no reply') + ').';
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
        show(status, 'Nobody is listed near you while you are on a contract, '
          + 'or for a while after one ends. '
          + (canBrowse ? 'Look under Everyone.'
            : 'Type at least ' + (settings().minQueryLength || 3) + ' letters of their name.'));
        return;
      }

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
      if (person.protected) {
        tags.appendChild(el('span', 'chip warn ico i-shield', protectedWords(person.protectedAs).tag));
      }
      // A band, never the figure: "under 20m" (app.lua, NEARBY_BAND).
      if (person.metres !== undefined && person.metres !== null) {
        tags.appendChild(el('span', 'chip ico i-pin', 'under ' + person.metres + 'm'));
      }
      if (tags.children.length > 0) { pick.appendChild(tags); }

      pick.onclick = function () {
        handle.value = person.handle;
        handle.dataset.protected = person.protected ? 'true' : 'false';
        state.draft.target = person.handle;
        state.draft.targetProtected = person.protected === true;
        state.draft.targetProtectedAs = person.protectedAs;
        state.draft.targetName = person.name;
        // The chosen name stays visible rather than the list vanishing, so
        // the player can see who they picked and change their mind.
        renderPeople([person], null);
        sayChosen();
        // And a way back to everyone else. The list collapsed to the one
        // row with nothing under it, so a player who tapped the wrong name
        // had to guess that the already-lit Everyone button would undo it.
        // The list already read is drawn again with this pick still lit:
        // tapping another row replaces it, and nothing is asked twice.
        var change = el('button', 'ghost ico i-swap', 'Choose someone else');
        change.onclick = function () {
          if (browse.data) { browse.draw(browse.data); } else { setScope(browse.scope); }
        };
        results.appendChild(change);
        if (person.protected) {
          say('That person ' + protectedWords(person.protectedAs).is + '.'
            + (advised('posted') ? ' Placing this alerts every officer in the city.'
              : advised('accepted') ? ' Every officer in the city is told when someone accepts it.' : ''),
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
      show(status, 'Looking\u2026');
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
    panel.appendChild(el('p', 'target', 'This screen could not be drawn.'));
    panel.appendChild(el('p', 'reason',
      'The fault has been sent to the server log. Nothing you did caused it '
      + 'and nothing has been lost.'));

    var row = el('div', 'row');
    // The whitelisted-job view has one screen and no board to go back to.
    var whitelisted = state.mode === 'whitelisted';
    var back = el('button', 'primary', whitelisted ? 'Try again' : 'Back to the board');
    back.onclick = function () {
      navigated();
      state.dialog = null;
      state.tab = whitelisted ? 'jobview' : 'board';
      render();
    };
    row.appendChild(back);

    var look = el('button', 'ghost', 'What went wrong');
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
    clockChips = [];
    countdownBars = {};

    // A dialog is drawn alone, as a sheet at the foot of the view; the view
    // carries the seal behind it while one is open.
    view.classList.toggle('has-dialog', !!state.dialog);

    if (state.dialog) {
      syncClockTicker();
      if (state.dialog.kind === 'choice') {
        renderChoice(view);
      } else if (state.dialog.kind === 'fields') {
        renderFields(view);
      } else if (state.dialog.kind === 'reward') {
        renderRewardEditor(view);
      } else if (state.dialog.kind === 'proof') {
        renderProof(view);
      } else {
        renderDialog(view);
      }
      return;
    }

    ({
      board: viewBoard, mine: viewMine, place: viewPlace,
      onme: viewOnMe, ledger: viewLedger, thread: viewThread,
      jobview: viewJobView
    })[state.tab](view);
    syncClockTicker();

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
  var loadSeq = { board: 0, mine: 0, ledger: 0, jobview: 0 };

  function newestLoad(section) {
    loadSeq[section] += 1;
    var mine = loadSeq[section];
    return function () { return loadSeq[section] === mine; };
  }

  /* Returns a promise that settles once all three reads have landed, so an
     action can hold its button until the screen shows what it did.

     `only` names the sections to read ({ board, mine, ledger }); without
     it, all three. A push reads only what the open tab draws (shownNow):
     it read all three whatever the tab, three requests from the bucket the
     board, Mine and the ledger share where one was drawn — and the board
     is the costliest thing the server builds. A section skipped is read
     when its tab is opened. */
  function refresh(only) {
    // The whitelisted-job view reads its one thing, whatever was asked for.
    if (state.mode === 'whitelisted') { return readJobView(); }

    function asked(section) { return !only || only[section] === true; }

    function readBoard() {
      var boardIsCurrent = newestLoad('board');
      return post('list', { page: state.boardPage || 1 }).then(function (r) {
        if (!boardIsCurrent()) { return; }
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
        var settingsWere = JSON.stringify(settings());
        state.board = r.data;
        stampClocks(r.data.contracts);
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
        var opening = !state.loaded.mine;
        if (!loadResult('mine', r)) { return; }
        state.mine = r.data;
        // Read after the handover ended, so its snapshot is current again.
        Object.keys(countdownOver).forEach(function (id) {
          if (countdownOver[id] < mineAsked) { delete countdownOver[id]; }
        });
        [r.data.created, r.data.accepted, r.data.onMe].forEach(stampClocks);
        redrawFor(['mine', 'onme']);
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
        asList(r.data.created).concat(asList(r.data.accepted)).forEach(function (c) {
          if (state.proposals[c.id] === undefined && !proposalsAsking[c.id]) { loadProposals(c); }
        });
      });
    }

    function readLedger() {
      var ledgerIsCurrent = newestLoad('ledger');
      return post('ledger', {}).then(function (r) {
        if (!ledgerIsCurrent()) { return; }
        if (!loadResult('ledger', r)) { return; }
        state.ledger = r.data;
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
    state.wallet = null; state.walletFailed = null;
    state.dialog = null; state.thread = null; state.call = null; state.reward = null;
    state.draft = {}; state.picked = {}; state.proposals = {}; state.drafts = {};
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
    // Each clock here is the contract's lifetime, the latest it can run
    // (Projection.whitelistedView): said as "within", since it may end
    // sooner.
    asList(data.onYou).concat(asList(data.colleagues)).forEach(function (entry) {
      if (entry && typeof entry === 'object') { entry.atLatest = true; }
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

  function readJobView() {
    var isCurrent = newestLoad('jobview');
    return post('whitelistedView', {}).then(function (r) {
      if (!isCurrent()) { return; }
      // They have left the job: the whole app is theirs again.
      if (!r.ok && r.err === 'not_whitelisted') { return leaveJobView(); }
      if (!loadResult('jobview', r)) { return; }
      takeJobView(r.data);
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
      // always was, and each section says so where its contents would be.
      var why = (r.err === 'not_whitelisted' || r.err === 'blacklisted_job' || !r.err)
        ? ERRORS.blacklisted_job : (ERRORS[r.err] || ERRORS.blacklisted_job);
      ['board', 'mine', 'ledger'].forEach(function (section) {
        state.loadFinal[section] = false;
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

  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (tab) {
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
        say('Save or delete the photo first. You can only see it once.', 'caution');
        return;
      }
      navigated();
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
        state.browse.refusal = null;
      }

      render();
      // Opening a tab is when a player expects to see current state. The
      // ledger too: a push no longer reads it unless it is open.
      if (state.tab === 'board' || state.tab === 'mine' || state.tab === 'onme') refresh();
      else if (state.tab === 'ledger') refresh({ ledger: true });
    };
  });

  // The client tells the page each server reply came (its event and
  // outcome, never its data) as well as resolving the fetch that asked for
  // it. Refreshing on those is a loop: one refresh sends three requests,
  // each reply triggers another refresh, and the app buries itself within
  // seconds. Only an unsolicited push is acted on.
  var pushTimer = null;
  // A settings push waiting in that debounce (see the push handler).
  var settingsPushed = false;

  // A refusal stays up until the player does something else. Captured, so
  // it is cleared before the tap's own handler runs and can raise the next.
  document.addEventListener('click', function () {
    if (state.notice && state.notice.kind === 'red') { dismissNotice(); }
  }, true);

  window.addEventListener('message', function (event) {
    var data = event.data || {};

    if (data.type === 'push') {
      /* A job change that moved this player between the whole app and the
         whitelisted-job view. Everything held for the one they had is
         dropped, and the page asks again: the view's read in the view
         (which sends them back to the app if they left the job), the
         app's reads otherwise (which find the view if they joined one). */
      if (data.reason === 'access') {
        forgetMode();
        // Whatever tab the whole app had open held what was just dropped
        // (a thread, the Place form): it starts again from the board.
        if (state.mode !== 'whitelisted') { state.tab = 'board'; }
        render();
        refresh();
        return;
      }

      /* A message changes one thing: the thread it was sent in. A full
         refresh for each one is three requests and more, and a quick
         exchange ran the page into its own rate limit. */
      if (data.reason === 'message') {
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
      if (state.tab === 'thread' && state.thread) {
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

      // Debounced: a contract settling pushes the creator, the target and
      // every hitman, and several of those can land in the same tick. One
      // refresh is three requests, so a push per party would be a burst per
      // event.
      if (pushTimer) { clearTimeout(pushTimer); }
      pushTimer = setTimeout(function () {
        pushTimer = null;
        var wanted = shownNow();
        if (settingsPushed) {
          settingsPushed = false;
          wanted.board = true;
          if (state.tab === 'place') {
            state.wallet = null;
            state.walletFailed = null;
            redraw();
          }
        }
        refresh(wanted);
      }, 250);
      return;
    }

    // The client asks for this when a staff member runs the diagnosis
    // command, so what the page has seen reaches the same report as what
    // the server has seen. It is the only way to read this side of the
    // bridge from outside the game.
    if (data.type === 'diagnostics') {
      Diag.note('asked', 'the server asked what this page has seen');
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

  // Installed before the first render: a throw in that render is exactly
  // the kind this exists to catch, and catching it needs the handler
  // already in place.
  Diag.install();

  render();
  refresh();

})();
