/* Crimson Bounty System — app shell.
   The UI holds no authority: it renders what the server sends and asks for
   what the player clicks. Every value shown here arrived in a projection. */

(function () {
  'use strict';

  var RESOURCE = 'crimson-bounty';
  var state = { tab: 'board', board: null, mine: null, ledger: null, busy: false, notice: null };

  /* ---------- transport ---------- */

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
    not_found: 'Gone.'
  };

  function say(message, kind) {
    state.notice = { message: message, kind: kind || 'red' };
    render();
    setTimeout(function () { state.notice = null; render(); }, 4000);
  }

  function fail(result) {
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
    var left = el('div');
    left.appendChild(el('div', 'target', contract.targetName));
    left.appendChild(el('div', 'reason', contract.reason || '—'));
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
    meta.appendChild(chip(contract.creatorAnonymous ? 'Anonymous client' : contract.creatorName));
    if (contract.targetProtected) {
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

      if (contract.kidnapProgress) {
        row.parentNode = null;
        var wrap = el('div');
        wrap.appendChild(row);
        wrap.appendChild(countdown(contract.kidnapProgress));
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
        msg.onclick = function () { openThread(contract, contract.hunters[0]); };
        row.appendChild(msg);
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

  function countdown(progress) {
    var wrap = el('div', 'countdown');
    var bar = el('div', 'bar');
    var fill = el('i');
    fill.style.width = Math.min(100, (progress.elapsed / progress.required) * 100) + '%';
    bar.appendChild(fill);
    wrap.appendChild(bar);
    wrap.appendChild(el('div', 'label',
      progress.breaking
        ? 'Hold position — ' + progress.elapsed + 's of ' + progress.required + 's'
        : progress.elapsed + 's of ' + progress.required + 's'));
    return wrap;
  }

  /* ---------- actions ---------- */

  function acceptContract(contract) {
    if (contract.targetProtected &&
        !window.confirm('This contract is on an active law enforcement officer. ' +
                        'Law enforcement has already been advised. Accept anyway?')) {
      return;
    }
    var anonymous = window.confirm('Accept anonymously?');
    post('accept', { id: contract.id, anonymous: anonymous }).then(function (r) {
      if (!r.ok) return fail(r);
      say('Contract accepted.', 'gold');
      refresh();
    });
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
          target_too_far: 'Keep the target close.'
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
        render();
        if (r.data.elapsed >= r.data.required) { clearInterval(timer); refresh(); }
      });
    }, 1000);
    setTimeout(function () { clearInterval(timer); }, 120000);
  }

  function bailout(contract) {
    if (!window.confirm('Pay ' + money(contract.bailoutAmount) + ' to close this contract?')) return;
    post('bailout', { id: contract.id }).then(function (r) {
      if (!r.ok) return fail(r);
      say('Paid. The contract closes shortly.', 'gold');
      refresh();
    });
  }

  function buyInformant(contract) {
    if (!window.confirm('Informant data is expensive and may turn up nothing. Continue?')) return;
    post('informant', { id: contract.id }).then(function (r) {
      if (!r.ok) return fail(r);
      if (!r.data || !r.data.found) return say('The informant had nothing for you.');
      say('Informant: ' + (r.data.name || r.data.description), 'gold');
    });
  }

  function addEscrow(contract) {
    var amount = window.prompt('Add how much cash to the pot?');
    var value = parseInt(amount, 10);
    if (!value || value <= 0) return;
    post('addEscrow', { id: contract.id, reward: { baseline: { cash: value } } })
      .then(function (r) {
        if (!r.ok) return fail(r);
        say('Added to the pot.', 'gold');
        refresh();
      });
  }

  function openThread(contract, hunter) {
    post('readThread', { id: contract.id, hunter: hunter ? hunter.hunterCid : null })
      .then(function (r) {
        if (!r.ok) return fail(r);
        state.thread = { contract: contract, hunter: hunter, messages: r.data || [] };
        state.tab = 'thread';
        render();
      });
  }

  function sendMessage(body) {
    if (!body) return;
    var t = state.thread;
    post('sendMessage', {
      id: t.contract.id,
      hunter: t.hunter ? t.hunter.hunterCid : null,
      body: body
    }).then(function (r) {
      if (!r.ok) return fail(r);
      openThread(t.contract, t.hunter);
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
    var rows = state.ledger || [];
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

    var back = el('button', 'ghost', 'Back');
    back.onclick = function () { state.tab = 'mine'; render(); };
    view.appendChild(back);

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
    slots.min = 1; slots.max = 5;
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

    var anon = document.createElement('input');
    anon.type = 'checkbox'; anon.id = 'anon';
    var toggle = el('div', 'toggle');
    toggle.appendChild(anon);
    toggle.appendChild(el('span', null, 'Place anonymously'));
    form.appendChild(toggle);

    var submit = el('button', 'primary', 'Place contract');
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
    box.innerHTML = '';
    for (var i = 1; i <= count; i++) {
      var slot = el('div', 'slot');
      slot.appendChild(el('h4', null, 'Payout ' + i));
      var split = el('div', 'split');
      split.appendChild(labelled('Cash', numberInput('slot-cash-' + i, 0)));
      split.appendChild(labelled('Bank', numberInput('slot-bank-' + i, 0)));
      split.appendChild(labelled('Dirty', numberInput('slot-dirty-' + i, 0)));
      slot.appendChild(split);
      box.appendChild(slot);
    }
  }

  function submitContract() {
    var target = document.getElementById('target-handle').value;
    if (!target) return say('Choose a target.');

    var count = parseInt(document.getElementById('slots-count').value, 10) || 1;
    var slots = [];
    for (var i = 1; i <= count; i++) {
      slots.push({
        baseline: {
          cash: num('slot-cash-' + i),
          bank: num('slot-bank-' + i),
          dirty: num('slot-dirty-' + i)
        }
      });
    }

    var protectedTarget = document.getElementById('target-handle').dataset.protected === 'true';
    if (protectedTarget &&
        !window.confirm('This target is a sworn law enforcement officer. Placing this ' +
                        'contract will alert every officer on duty. Continue?')) {
      return;
    }

    post('create', {
      target: target,
      reason: document.getElementById('reason').value,
      mode: document.getElementById('mode').value,
      reward: { slots: slots },
      bonusPercent: num('bonus'),
      bailoutAmount: num('bailout'),
      anonymous: document.getElementById('anon').checked
    }).then(function (r) {
      if (!r.ok) return fail(r);
      say('Contract placed.', 'gold');
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

    input.oninput = function () {
      if (input.value.length < 3) { results.innerHTML = ''; return; }
      post('searchTargets', { query: input.value }).then(function (r) {
        results.innerHTML = '';
        if (!r.ok || !r.data) return;
        r.data.forEach(function (person) {
          var pick = el('button', 'ghost',
            person.name + (person.protected ? '  ·  ' + (person.job || 'LEO') : ''));
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
    };

    wrap.appendChild(input);
    wrap.appendChild(handle);
    wrap.appendChild(results);
    return wrap;
  }

  /* ---------- shell ---------- */

  function render() {
    var view = document.getElementById('view');
    view.innerHTML = '';

    if (state.notice) {
      view.appendChild(el('div', 'notice' + (state.notice.kind === 'gold' ? ' gold' : ''),
        state.notice.message));
    }

    ({
      board: viewBoard, mine: viewMine, place: viewPlace,
      onme: viewOnMe, ledger: viewLedger, thread: viewThread
    })[state.tab](view);

    Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (tab) {
      tab.classList.toggle('is-active', tab.dataset.tab === state.tab);
    });
  }

  function refresh() {
    post('list', { page: 1 }).then(function (r) { if (r.ok) { state.board = r.data; render(); } });
    post('mine', {}).then(function (r) { if (r.ok) { state.mine = r.data; render(); } });
    post('ledger', {}).then(function (r) { if (r.ok) { state.ledger = r.data; render(); } });
  }

  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (tab) {
    tab.onclick = function () { state.tab = tab.dataset.tab; render(); };
  });

  window.addEventListener('message', function (event) {
    var data = event.data || {};
    if (data.type === 'result') refresh();
  });

  render();
  refresh();
})();
