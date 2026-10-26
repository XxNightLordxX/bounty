/* The admin panel (/hitmanadmin). Vanilla JS, no build step.
 *
 * Every request goes through nui(), which posts to client/admin.lua's
 * adminRequest callback; the server checks the ACE on every one and answers
 * { ok, err, message, data } (README, Integration Guide, has every op). */
(function () {
  'use strict';

  var RESOURCE = typeof GetParentResourceName === 'function'
    ? GetParentResourceName() : 'crimson-hitman';

  /** Every interpolated string goes through this. */
  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /** One fetch helper: the callback's answer, or null on any error. */
  function nui(event, data) {
    return fetch('https://' + RESOURCE + '/' + event, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {})
    }).then(function (r) { return r.json(); }).catch(function () { return null; });
  }

  function request(op, data) { return nui('adminRequest', { op: op, data: data || {} }); }

  var panel = document.getElementById('panel');
  var body = document.getElementById('body');
  var toasts = document.getElementById('toasts');

  function toast(text) {
    var node = document.createElement('div');
    node.className = 'toast';
    node.textContent = String(text);
    toasts.appendChild(node);
    setTimeout(function () { node.remove(); }, 4000);
  }

  function close() {
    panel.hidden = true;
    body.textContent = '';
    nui('adminClose');
  }

  function open() {
    panel.hidden = false;
    body.textContent = '';
    request('overview').then(function (reply) {
      if (!reply || !reply.ok) { toast((reply && reply.message) || 'The server did not answer.'); return; }
      var data = reply.data || {};
      var line = document.createElement('p');
      line.innerHTML = 'Contracts on record: <b>' + esc((data.contracts || {}).total)
        + '</b>. Storage: <b>' + esc(data.storage) + '</b>.';
      body.appendChild(line);
    });
  }

  window.addEventListener('message', function (event) {
    var message = event.data || {};
    if (message.type === 'open') open();
    else if (message.type === 'close') { panel.hidden = true; body.textContent = ''; }
  });

  document.getElementById('close').addEventListener('click', close);
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && !panel.hidden) close();
  });
})();
