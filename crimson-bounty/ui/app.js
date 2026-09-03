/* Crimson Bounty System — app shell.
   The UI holds no authority: it renders what the server sends and asks for
   what the player clicks. Every value shown here arrived in a projection. */

(function () {
  'use strict';

  var RESOURCE = 'crimson-bounty';
  var state = {
    tab: 'board', board: null, mine: null, ledger: null,
    progress: {}, dialog: null, leoConfirmed: false, wallet: null,
    busy: false, notice: null,
    // Target headshots, keyed by the reference a projection gave us. The
    // listing carries references, not images, so a board refresh re-sends
    // nothing and a face is fetched once per render. `null` marks a fetch in
    // flight, so fifteen rows of the same target ask once.
    images: {},
    // Items and weapons chosen per payout slot. These live here rather than
    // in the DOM because the picker rebuilds its own markup on every add and
    // remove, and a rebuilt <select> forgets what was put in it.
    picked: {},
    // Open amendment proposals, keyed by contract. Read on demand rather
    // than carried in every listing row: most contracts have none.
    proposals: {}
  };

  /* ---------- transport ---------- */

  // Each call is answered by its own reply; the client bridge correlates
  // them, so two searches in flight cannot resolve into each other.
  function post(name, data) {
    return fetch('https://' + RESOURCE + '/crimson:' + name, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {})
    }).then(function (r) { return r.json(); }).catch(function () {
      return { ok: false, err: 'unreachable' };
    });
  }

  var ERRORS = {
    blacklisted_job: 'This app is not for you.',
    rate_limited: 'Slow down.',
    self_target: 'You cannot put a price on yourself.',
    self_accept: 'You cannot take your own contract.',
    same_account: 'Not on your own people.',
    limit_reached: 'You are holding too many contracts.',
    target_protected: 'That target cannot be listed right now.',
    insufficient_funds: 'You do not have that.',
    invalid_reward: 'That reward does not add up.',
    invalid_input: 'Check what you entered.',
    not_participant: 'That is not yours.',
    already_settled: 'That contract is closed.',
    token_invalid: 'Verification expired. Take the photo again.',
    photo_rejected: 'The photo was not accepted.',
    bad_state: 'Not right now.',
    locked: 'Someone got there first.',
    not_found: 'Gone.',
    cancelled: null,
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

  function askNumber(question, detail, onValue) {
    state.dialog = { kind: 'number', question: question, detail: detail, onValue: onValue };
    render();
  }

  function closeDialog() {
    state.dialog = null;
    render();
  }

  function renderDialog(view) {
    var d = state.dialog;
    var panel = el('div', 'card dialog');
    panel.appendChild(el('div', 'target', d.question));
    if (d.detail) panel.appendChild(el('div', 'reason', d.detail));

    var input;
    if (d.kind === 'number') {
      input = document.createElement('input');
      input.type = 'number';
      input.id = 'dialog-value';
      input.min = 0;
      var field = el('div', 'field');
      field.appendChild(input);
      panel.appendChild(field);
    }

    var row = el('div', 'row');
    var yes = el('button', 'primary', d.kind === 'number' ? 'Confirm' : 'Yes');
    yes.onclick = function () {
      var handler = d.onYes, valueHandler = d.onValue;
      var value = input ? parseInt(input.value, 10) : null;
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

    var row = el('div', 'row');
    d.options.forEach(function (option) {
      var button = el('button', option.primary ? 'primary' : null, option.label);
      button.onclick = function () {
        state.dialog = null;
        render();
        option.run();
      };
      row.appendChild(button);
    });
    var cancel = el('button', 'ghost', 'Cancel');
    cancel.onclick = closeDialog;
    row.appendChild(cancel);
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
    say(ERRORS[result.err] || 'Something went wrong.');
  }

  /* ---------- helpers ---------- */

  function money(n) {
    return '$' + (Number(n) || 0).toLocaleString('en-US');
  }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function chip(text, variant) {
    return el('span', 'chip' + (variant ? ' ' + variant : ''), text);
  }

  /* ---------- contract card ---------- */

  function card(contract, context) {
    var node = el('div', 'card' + (contract.targetProtected ? ' is-protected' : ''));

    var head = el('div', 'card-head');
    var left = el('div', 'card-identity');

    var face = mugshot(contract.targetImageId);
    if (face) {
      var shot = document.createElement('img');
      shot.className = 'mugshot';
      shot.src = face;
      shot.alt = '';
      left.appendChild(shot);
    }

    var who = el('div');
    who.appendChild(el('div', 'target', contract.targetName));
    who.appendChild(el('div', 'reason', contract.reason || '—'));
    left.appendChild(who);
    head.appendChild(left);

    var reward = el('div', 'reward');
    reward.appendChild(el('div', 'amount', money(contract.reward.baseline)));
    if (contract.reward.bonus > 0) {
      reward.appendChild(el('div', 'bonus', '+' + money(contract.reward.bonus) + ' alive'));
    }
    head.appendChild(reward);
    node.appendChild(head);

    var meta = el('div', 'meta');
    meta.appendChild(chip(contract.mode === 'competitive' ? 'Competitive' : 'Exclusive'));

    if (contract.slots > 1) {
      meta.appendChild(chip(
        'Slot ' + contract.currentSlot + ' of ' + contract.slots, 'slots'));
    }
    if (contract.huntersActive > 0) {
      meta.appendChild(chip(
        contract.huntersActive + (contract.huntersActive === 1 ? ' operative' : ' operatives'), 'hot'));
    }
    if (contract.role === 'creator' && contract.hunters) {
      contract.hunters.forEach(function (h) {
        if (h.record) {
          meta.appendChild(chip(h.alias + ' · ' + h.record.standing));
        }
      });
    }
    meta.appendChild(chip(contract.creatorAnonymous ? 'Anonymous client' : contract.creatorName));
    if (contract.targetProtected && settings().flagListing !== false) {
      meta.appendChild(chip('Law enforcement', 'warn'));
    }
    node.appendChild(meta);

    if (contract.targetProtected && context === 'board') {
      node.appendChild(el('div', 'notice gold',
        'This target is a sworn officer. Their department has been advised.'));
    }

    node.appendChild(actionsFor(contract, context));
    return node;
  }

  function actionsFor(contract, context) {
    var row = el('div', 'row');

    if (context === 'board') {
      var take = el('button', 'primary', 'Accept contract');
      take.onclick = function () { acceptContract(contract); };
      row.appendChild(take);
      return row;
    }

    if (contract.role === 'hunter') {
      var photo = el('button', 'primary', 'Verify kill');
      photo.onclick = function () { verifyKill(contract); };
      row.appendChild(photo);

      var deliver = el('button', null, 'Deliver alive');
      deliver.onclick = function () { armKidnap(contract); };
      row.appendChild(deliver);

      var talk = el('button', 'ghost', 'Message');
      talk.onclick = function () { openThread(contract, null); };
      row.appendChild(talk);

      var quit = el('button', 'ghost', 'Abandon');
      quit.onclick = function () {
        ask('Walk away from this contract?',
            'If you staked a penalty, the client keeps it.',
            function () {
              post('abandon', { id: contract.id }).then(function (r) {
                if (!r.ok) return fail(r);
                say('You are off the contract.');
                refresh();
              });
            });
      };
      row.appendChild(quit);

      var propose = el('button', 'ghost', 'Propose change');
      propose.onclick = function () { proposeChange(contract); };
      row.appendChild(propose);

      // Live progress if the countdown is running, otherwise the snapshot
      // that came with the projection.
      var progress = state.progress[contract.id] || contract.kidnapProgress;
      var panel = proposalPanel(contract);
      if (progress || panel) {
        var wrap = el('div');
        wrap.appendChild(row);
        if (progress) { wrap.appendChild(countdown(progress)); }
        if (panel) { wrap.appendChild(panel); }
        return wrap;
      }
      return row;
    }

    if (contract.role === 'creator') {
      var top = el('button', null, 'Add to pot');
      top.onclick = function () { addEscrow(contract); };
      row.appendChild(top);

      var buy = el('button', 'ghost', 'Buy informant data');
      buy.onclick = function () { buyInformant(contract); };
      row.appendChild(buy);

      if (contract.hunters && contract.hunters.length) {
        var msg = el('button', 'ghost', 'Threads');
        msg.onclick = function () { openThreads(contract); };
        row.appendChild(msg);
      }

      var extend = el('button', 'ghost', 'Extend deadline');
      extend.onclick = function () { improveContract(contract); };
      row.appendChild(extend);

      var change = el('button', 'ghost', 'Propose change');
      change.onclick = function () { proposeChange(contract); };
      row.appendChild(change);

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
      if (contract.bailoutAvailable) {
        var out = el('button', 'danger', 'Buy out — ' + money(contract.bailoutAmount));
        out.onclick = function () { bailout(contract); };
        row.appendChild(out);
      } else {
        row.appendChild(el('div', 'hint', 'No buyout was offered on this contract.'));
      }
      var informant = el('button', 'ghost', 'Buy informant data');
      informant.onclick = function () { buyInformant(contract); };
      row.appendChild(informant);
      return row;
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

    wrap.appendChild(el('div', 'label',
      progress.elapsed + 's of ' + progress.required + 's'));

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

  function acceptContract(contract) {
    function take(anonymous) {
      post('accept', { id: contract.id, anonymous: anonymous }).then(function (r) {
        if (!r.ok) return fail(r);
        say(anonymous ? 'Contract accepted, anonymously.' : 'Contract accepted.', 'gold');
        refresh();
      });
    }

    function chooseAnonymity() {
      state.dialog = {
        kind: 'choice',
        question: 'Take this one anonymously?',
        detail: 'The client will see an operative, not a name.',
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
    post('takeVerificationPhoto', { id: contract.id }).then(function (r) {
      if (!r.ok) return fail(r);
      say('Verified. Payment released.', 'gold');
      refresh();
    });
  }

  function armKidnap(contract) {
    post('armKidnap', { id: contract.id }).then(function (r) {
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

  function pollCountdown(id) {
    var timer = setInterval(function () {
      post('kidnapProgress', { id: id }).then(function (r) {
        if (!r.ok || !r.data || r.data.elapsed === undefined) { clearInterval(timer); return; }
        // Keep the answer. Rendering from the projection's snapshot draws
        // the same frozen bar every second no matter how often we poll.
        state.progress[id] = r.data;
        render();
        if (r.data.elapsed >= r.data.required) {
          clearInterval(timer);
          delete state.progress[id];
          refresh();
        }
      });
    }, 1000);
    setTimeout(function () { clearInterval(timer); delete state.progress[id]; }, 120000);
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
    ask('Buy informant data?',
        'It is expensive, and it may turn up nothing. You pay either way.',
        function () { doBuyInformant(contract); });
  }

  function doBuyInformant(contract) {
    post('informant', { id: contract.id }).then(function (r) {
      if (!r.ok) return fail(r);
      if (!r.data || !r.data.found) return say('The informant had nothing for you.');
      say('Informant: ' + (r.data.name || r.data.description), 'gold');
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
      return 'Reduce the reward' + (p && p.amount ? ' by ' + money(p.amount) : '');
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
    withdraw: function () { return 'Withdraw from this contract'; },
    cancel: function () { return 'Cancel this contract outright'; }
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
      state.proposals[contract.id] = r.data || [];
      render();
    });
  }

  function answerProposal(proposal, approve) {
    post('respondAmendment', { id: proposal.id, approve: approve }).then(function (r) {
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

      if (proposal.mine || proposal.answered) {
        item.appendChild(el('div', 'hint', proposal.waiting === 0
          ? 'Waiting to be applied.'
          : 'Waiting on ' + proposal.waiting
              + (proposal.waiting === 1 ? ' other party.' : ' other parties.')));
      } else {
        var row = el('div', 'row');
        var yes = el('button', 'primary', 'Agree');
        yes.onclick = function () { answerProposal(proposal, true); };
        var no = el('button', 'danger', 'Decline');
        no.onclick = function () { answerProposal(proposal, false); };
        row.appendChild(yes);
        row.appendChild(no);
        item.appendChild(row);
      }

      box.appendChild(item);
    });

    return box;
  }

  // Propose a change that needs the other party's agreement, as opposed to
  // `improve`, which applies at once because it can only help them.
  function proposeChange(contract) {
    var options = [
      { label: 'Shorten the deadline', kind: 'shorten_deadline', minutes: true },
      { label: 'Reduce the reward', kind: 'reduce_reward', amount: true },
      { label: contract.role === 'hunter' ? 'Withdraw' : 'Cancel the contract',
        kind: contract.role === 'hunter' ? 'withdraw' : 'cancel' }
    ];

    state.dialog = {
      kind: 'choice',
      question: 'Propose a change',
      detail: 'Both sides have to agree before it takes effect.',
      options: options.map(function (option) {
        return {
          label: option.label,
          run: function () {
            if (option.minutes) {
              return askNumber(option.label, 'By how many minutes?', function (minutes) {
                sendProposal(contract, option.kind, { seconds: minutes * 60 });
              });
            }
            if (option.amount) {
              return askNumber(option.label, 'By how much?', function (amount) {
                sendProposal(contract, option.kind, { amount: amount });
              });
            }
            sendProposal(contract, option.kind, {});
          }
        };
      })
    };
    render();
  }

  function sendProposal(contract, kind, payload) {
    post('propose', { id: contract.id, kind: kind, payload: payload }).then(function (r) {
      if (!r.ok) { return fail(r); }
      say('Proposed. The other party has to agree.', 'gold');
      state.proposals = {};
      refresh();
    });
  }

  function improveContract(contract) {
    askNumber('Extend the deadline by how many minutes?',
              'This applies at once — it can only help whoever is hunting.',
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
              });
  }

  function addEscrow(contract) {
    askNumber('Add how much cash to the pot?',
              'It is taken from you now and held with the rest.',
              function (value) {
                post('addEscrow', { id: contract.id, reward: { baseline: { cash: value } } })
                  .then(function (r) {
                    if (!r.ok) return fail(r);
                    say('Added to the pot.', 'gold');
                    refresh();
                  });
              });
  }

  // Threads are addressed by an opaque server-issued handle, never by a
  // citizen id — the creator is not told who the operative is.
  function openThread(contract, thread) {
    post('readThread', { id: contract.id, thread: thread ? thread.handle : null })
      .then(function (r) {
        if (!r.ok) return fail(r);
        state.thread = { contract: contract, thread: thread, messages: r.data || [] };
        state.tab = 'thread';
        render();
      });
  }

  // A creator picks which operative to talk to; a hunter has only one thread.
  function openThreads(contract) {
    post('threads', { id: contract.id }).then(function (r) {
      if (!r.ok) return fail(r);
      var threads = r.data || [];
      if (!threads.length) return say('No operative to talk to yet.');
      openThread(contract, threads[0]);
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
    if (!body) return;
    var t = state.thread;
    post('sendMessage', {
      id: t.contract.id,
      thread: t.thread ? t.thread.handle : null,
      body: body
    }).then(function (r) {
      if (!r.ok) return fail(r);
      openThread(t.contract, t.thread);
    });
  }

  /* ---------- views ---------- */

  function viewBoard(view) {
    var data = state.board;
    if (!data || !data.contracts || !data.contracts.length) {
      view.appendChild(el('div', 'empty', 'No contracts on the board.'));
      return;
    }
    data.contracts.forEach(function (c) { view.appendChild(card(c, 'board')); });
  }

  function viewMine(view) {
    var data = state.mine;
    if (!data) return;
    var any = false;

    if (data.accepted && data.accepted.length) {
      any = true;
      view.appendChild(el('h3', null, 'Contracts you took'));
      data.accepted.forEach(function (c) { view.appendChild(card(c, 'mine')); });
    }
    if (data.created && data.created.length) {
      any = true;
      view.appendChild(el('h3', null, 'Contracts you placed'));
      data.created.forEach(function (c) { view.appendChild(card(c, 'mine')); });
    }
    if (!any) view.appendChild(el('div', 'empty', 'Nothing active.'));
  }

  function viewOnMe(view) {
    var rows = (state.mine && state.mine.onMe) || [];
    if (!rows.length) {
      view.appendChild(el('div', 'empty', 'Nobody is looking for you. That you know of.'));
      return;
    }
    view.appendChild(el('div', 'notice', 'There is a price on your head.'));
    rows.forEach(function (c) { view.appendChild(card(c, 'onme')); });
  }

  function viewLedger(view) {
    var data = state.ledger || {};
    var rows = data.entries || [];
    var record = data.record;

    if (record) {
      var card = el('div', 'card');
      card.appendChild(el('div', 'target', record.standing));
      var meta = el('div', 'meta');
      meta.appendChild(chip(record.completed + ' completed', 'hot'));
      meta.appendChild(chip(record.placed + ' placed'));
      meta.appendChild(chip(record.survived + ' survived'));
      if (record.rate !== undefined && record.rate !== null) {
        meta.appendChild(chip(record.rate + '% success'));
      }
      card.appendChild(meta);
      view.appendChild(card);
    }

    if (!rows.length) {
      view.appendChild(el('div', 'empty', 'No history yet.'));
      return;
    }
    rows.forEach(function (row) {
      var node = el('div', 'card');
      node.appendChild(el('div', 'target', row.target_name || 'Unknown'));
      node.appendChild(el('div', 'reason', row.reason || ''));
      var meta = el('div', 'meta');
      meta.appendChild(chip(row.role));
      meta.appendChild(chip(row.fulfilment === 'kidnapping' ? 'Delivered alive' : 'Eliminated', 'hot'));
      node.appendChild(meta);
      if (row.photo_ref) {
        var img = document.createElement('img');
        img.src = row.photo_ref;
        img.style.cssText = 'width:100%;border-radius:0.5rem;margin-top:0.6rem';
        node.appendChild(img);
      }
      view.appendChild(node);
    });
  }

  function viewThread(view) {
    var t = state.thread;
    if (!t) { state.tab = 'mine'; return render(); }

    var row = el('div', 'row');

    var back = el('button', 'ghost', 'Back');
    back.onclick = function () { state.tab = 'mine'; render(); };
    row.appendChild(back);

    // The server has always had a call path and nothing reached it, so the
    // whole feature was unreachable from the phone.
    if (settings().calls) {
      var call = el('button', 'ghost', 'Call');
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

    var field = el('div', 'field');
    var input = document.createElement('input');
    input.placeholder = 'Say something';
    input.maxLength = 200;
    input.onkeydown = function (e) {
      if (e.key === 'Enter') { sendMessage(input.value); input.value = ''; }
    };
    field.appendChild(input);
    view.appendChild(field);
  }

  function viewPlace(view) {
    var form = el('div');

    // What the creator actually has, read server-side, so an over-budget
    // contract is obvious before they submit rather than after.
    if (!state.wallet) {
      post('rewardOptions', {}).then(function (r) {
        if (r.ok && r.data) { state.wallet = r.data; render(); }
      });
    } else {
      var w = state.wallet;
      var wallet = el('div', 'card');
      var meta = el('div', 'meta');
      meta.appendChild(chip('Cash ' + money(w.cash)));
      meta.appendChild(chip('Bank ' + money(w.bank)));
      meta.appendChild(chip('Dirty ' + money(w.dirty)));
      wallet.appendChild(meta);
      form.appendChild(wallet);
    }

    form.appendChild(labelled('Target', targetSearch()));
    form.appendChild(labelled('Reason', textInput('reason', 'Why?', 140)));

    var mode = document.createElement('select');
    mode.id = 'mode';
    [['exclusive', 'Exclusive — one hunter'],
     ['competitive', 'Competitive — first to finish']].forEach(function (o) {
      var opt = document.createElement('option');
      opt.value = o[0]; opt.textContent = o[1];
      mode.appendChild(opt);
    });
    form.appendChild(labelled('Assignment', mode));

    var slots = numberInput('slots', 1);
    slots.min = 1;
    // The server's ceiling, not a number typed here: raising MaxPayoutSlots
    // in the config used to leave the form refusing to go past five.
    slots.max = (state.wallet && state.wallet.caps && state.wallet.caps.slots) || 5;
    slots.onchange = function () { renderSlots(); };
    form.appendChild(labelled('Payouts (how many times it can be collected)', slots));
    form.appendChild(el('div', 'hint',
      'Every payout is funded and escrowed up front. More hunters may accept than there are ' +
      'payouts — the first to finish are paid.'));

    var slotBox = el('div');
    slotBox.id = 'slots';
    form.appendChild(slotBox);

    form.appendChild(labelled('Kidnapping bonus %', numberInput('bonus', 50)));
    form.appendChild(labelled('Buyout price (0 for none)', numberInput('bailout', 0)));
    form.appendChild(labelled('Failure penalty (0 for none)', numberInput('penalty', 0)));
    form.appendChild(el('div', 'hint',
      'A hunter stakes this when they accept, and forfeits it to you if they walk away.'));

    var anon = document.createElement('input');
    anon.type = 'checkbox'; anon.id = 'anon';
    var toggle = el('div', 'toggle');
    toggle.appendChild(anon);
    toggle.appendChild(el('span', null, 'Place anonymously'));
    form.appendChild(toggle);

    var submit = el('button', 'primary', 'Place contract');
    submit.id = 'place-submit';
    submit.style.marginTop = '0.8rem';
    submit.onclick = submitContract;
    form.appendChild(submit);

    view.appendChild(form);
    renderSlots();
  }

  function renderSlots() {
    var box = document.getElementById('slots');
    if (!box) return;
    var count = parseInt(document.getElementById('slots-count').value, 10) || 1;

    // Read back whatever is already typed before the box is torn down.
    // Changing the payout count used to reset every amount above it.
    var typed = {};
    ['cash', 'bank', 'dirty'].forEach(function (source) {
      for (var i = 1; i <= 10; i++) {
        var node = document.getElementById('slot-' + source + '-' + i);
        if (node) { typed['slot-' + source + '-' + i] = node.value; }
      }
    });

    // Drop what was staged on payouts that no longer exist. Leaving it in
    // place kept those items counted as promised — so lowering the payout
    // count made them unaddable anywhere, while nothing would ever submit
    // them.
    Object.keys(state.picked).forEach(function (index) {
      if (parseInt(index, 10) > count) { delete state.picked[index]; }
    });

    box.innerHTML = '';
    for (var i = 1; i <= count; i++) {
      var slot = el('div', 'slot');
      slot.appendChild(el('h4', null, 'Payout ' + i));

      var split = el('div', 'split');
      ['cash', 'bank', 'dirty'].forEach(function (source) {
        var id = 'slot-' + source + '-' + i;
        var input = numberInput(id, 0);
        if (typed[id] !== undefined) { input.value = typed[id]; }
        split.appendChild(labelled(
          source.charAt(0).toUpperCase() + source.slice(1), input));
      });
      slot.appendChild(split);

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

  function goodsBox(index) {
    var wrap = el('div');
    var wallet = state.wallet;
    if (!wallet) { return wrap; }

    var items = wallet.items || [];
    var weapons = wallet.weapons || [];
    if (items.length === 0 && weapons.length === 0) { return wrap; }

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
    return wrap;
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

  function itemPicker(index, items) {
    var choose = document.createElement('select');
    choose.id = 'slot-item-' + index;
    items.forEach(function (item) {
      var free = item.count - allocatedItem(item.name);
      if (free <= 0) { return; }
      var option = document.createElement('option');
      option.value = item.name;
      option.textContent = item.label + '  (' + free + ' spare)';
      choose.appendChild(option);
    });
    if (choose.children.length === 0) { return el('div', 'hint', 'Nothing spare left to add.'); }

    var count = numberInput('slot-item-count-' + index, 1);
    count.min = 1;

    var add = el('button', 'ghost', 'Add item');
    add.id = 'slot-item-add-' + index;
    add.onclick = function () {
      var name = choose.value;
      var wanted = parseInt(count.value, 10) || 0;
      if (!name || wanted <= 0) { return say('Choose an item and a count.'); }

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

    var row = el('div', 'split');
    row.appendChild(labelled('Item', choose));
    row.appendChild(labelled('How many', count));
    var field = el('div');
    field.appendChild(row);
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

    var add = el('button', 'ghost', 'Add weapon');
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

    var field = el('div');
    field.appendChild(labelled('Weapon', choose));
    field.appendChild(add);
    return field;
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

  function submitContract() {
    var target = document.getElementById('target-handle').value;
    if (!target) return say('Choose a target.');

    var count = parseInt(document.getElementById('slots-count').value, 10) || 1;
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

    var protectedTarget = document.getElementById('target-handle').dataset.protected === 'true';
    if (protectedTarget && settings().warnCreator !== false && !state.leoConfirmed) {
      ask('That target is a sworn officer.',
          'Placing this will alert every officer on duty, by phone and over dispatch.',
          function () { state.leoConfirmed = true; submitContract(); });
      return;
    }
    state.leoConfirmed = false;

    post('create', {
      target: target,
      reason: document.getElementById('reason').value,
      mode: document.getElementById('mode').value,
      reward: { slots: slots },
      bonusPercent: num('bonus'),
      bailoutAmount: num('bailout'),
      penaltyAmount: num('penalty'),
      anonymous: document.getElementById('anon').checked
    }).then(function (r) {
      if (!r.ok) return fail(r);
      say('Contract placed.', 'gold');
      // The goods are gone from the player's pockets now; leaving them
      // staged would offer them again on the next contract.
      state.picked = {};
      state.wallet = null;
      state.tab = 'mine';
      refresh();
    });
  }

  function num(id) {
    var node = document.getElementById(id);
    var value = node ? parseInt(node.value, 10) : 0;
    return (!value || value < 0) ? 0 : value;
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

  function targetSearch() {
    var wrap = el('div');
    var input = textInput('target-query', 'Search by name', 32);
    var handle = document.createElement('input');
    handle.type = 'hidden'; handle.id = 'target-handle';
    var results = el('div');

    var searchTimer = null;
    var searchSeq = 0;

    input.oninput = function () {
      // The server tells us its minimum; a shorter query is rejected there
      // and burns a rate-limit token for nothing.
      var minimum = settings().minQueryLength || 4;
      if (input.value.length < minimum) { results.innerHTML = ''; return; }

      // Debounced, so typing a name is one lookup rather than one per
      // keystroke against a bucket that refills twice a second.
      if (searchTimer) clearTimeout(searchTimer);
      var mine = ++searchSeq;
      searchTimer = setTimeout(function () { runSearch(mine); }, 300);
    };

    function runSearch(sequence) {
      post('searchTargets', { query: input.value }).then(function (r) {
        // A reply from a query the player has already typed past is stale.
        if (sequence !== searchSeq) return;
        results.innerHTML = '';
        if (!r.ok) {
          if (r.err === 'rate_limited') say('Searching too fast. Try again in a moment.');
          return;
        }
        if (!r.data || r.data.length === 0) {
          results.appendChild(el('div', 'hint', 'Nobody by that name is online.'));
          return;
        }
        r.data.forEach(function (person) {
          var pick = el('button', 'ghost',
            person.name + (person.protected ? '  ·  LAW ENFORCEMENT' : ''));
          pick.style.marginTop = '0.3rem';
          pick.onclick = function () {
            handle.value = person.handle;
            handle.dataset.protected = person.protected ? 'true' : 'false';
            input.value = person.name;
            results.innerHTML = '';
            if (person.protected) {
              say('That is a sworn officer. Placing this will alert their department.', 'gold');
            }
          };
          results.appendChild(pick);
        });
      });
    }

    wrap.appendChild(input);
    wrap.appendChild(handle);
    wrap.appendChild(results);
    return wrap;
  }

  /* ---------- shell ---------- */

  function render() {
    var view = document.getElementById('view');
    view.innerHTML = '';

    if (state.dialog) {
      if (state.dialog.kind === 'choice') {
        renderChoice(view);
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
      tab.classList.toggle('is-active', tab.dataset.tab === state.tab);
    });

    renderNotice();
  }

  function refresh() {
    post('list', { page: 1 }).then(function (r) { if (r.ok) { state.board = r.data; render(); } });
    post('mine', {}).then(function (r) {
      if (!r.ok) { return; }
      state.mine = r.data;
      render();
      // Only for contracts this player is actually party to, and only for
      // ones not already loaded: most contracts have no open proposal and
      // asking about every one of them every refresh would be three
      // requests a card.
      (r.data.created || []).concat(r.data.accepted || []).forEach(function (c) {
        if (state.proposals[c.id] === undefined) { loadProposals(c); }
      });
    });
    post('ledger', {}).then(function (r) { if (r.ok) { state.ledger = r.data; render(); } });
  }

  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (tab) {
    tab.onclick = function () {
      state.tab = tab.dataset.tab;
      state.dialog = null;
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
    if (data.type !== 'push') { return; }

    // Debounced: a contract settling pushes the creator, the target and every
    // hunter, and several of those can land in the same tick. One refresh is
    // three requests, so a push per party would be a burst per event.
    if (pushTimer) { clearTimeout(pushTimer); }
    pushTimer = setTimeout(function () { pushTimer = null; refresh(); }, 250);
  });

  render();
  refresh();
})();
