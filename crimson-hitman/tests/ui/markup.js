/* What the staff panel needs of the DOM shim (dom.js) that the phone app
 * never did.
 *
 * The phone app builds every node with createElement and textContent (the
 * static check holds it to that), so the shim never had to read markup and
 * ignores any innerHTML but ''. The staff panel builds its rows as markup,
 * through one function that escapes every value it is given (ui/admin.js,
 * h() and esc()), and hands clicks out from the document by the data-act a
 * node carries. A shim that ignored that markup would test a page with
 * nothing on it.
 *
 * So, installed over dom.js for the staff panel's runner only:
 *   - innerHTML parses what it is given, as a browser does, into real shim
 *     nodes. Text is decoded once, so a value esc() missed shows up here as
 *     an element a test can find, not as text;
 *   - getAttribute / hasAttribute / removeAttribute, and the properties a
 *     browser reflects (id, class, hidden, disabled, value, checked);
 *   - querySelector(All) and closest for simple compound selectors
 *     (tag, #id, .class, [attr], [attr="v"]);
 *   - events that bubble from the target up to the document.
 *
 * Nothing here changes what dom.js does for the phone app's suite, which
 * does not load this file. */

'use strict';

const { Node } = require('./dom.js');

const VOID = { input: true, br: true, hr: true, img: true, meta: true, link: true };

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', middot: '·',
                   hellip: '…', times: '×', mdash: '—', ndash: '–' };

function decode(text) {
  return String(text).replace(/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/g, function (all, name) {
    if (name[0] === '#') {
      const code = name[1] === 'x' ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return isFinite(code) ? String.fromCodePoint(code) : all;
    }
    return Object.prototype.hasOwnProperty.call(ENTITIES, name) ? ENTITIES[name] : all;
  });
}

function camel(name) {
  return name.replace(/-([a-z])/g, function (_, c) { return c.toUpperCase(); });
}

function applyAttribute(node, name, value) {
  name = name.toLowerCase();
  if (name === 'id') { node.id = value; return; }
  if (name === 'class') { node.className = value; return; }
  node.attributes[name] = value;
  if (name.indexOf('data-') === 0) node.dataset[camel(name.slice(5))] = value;
  if (name === 'hidden') node.hidden = true;
  if (name === 'disabled') node.disabled = true;
  if (name === 'checked') node.checked = true;
  if (name === 'value') node.value = value;
}

function textNode(text) {
  const node = new Node('#text');
  node._textContent = text;
  node.nodeType = 3;
  return node;
}

/** Markup into nodes under `parent`, made by `doc` so ids register. */
function parseInto(parent, html, doc) {
  const stack = [parent];
  const re = /<!--[\s\S]*?-->|<(\/?)([a-zA-Z][a-zA-Z0-9-]*)((?:\s+[^\s=>\/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)*)\s*(\/?)>|([^<]+)|(<)/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    const top = stack[stack.length - 1];
    if (m[0].indexOf('<!--') === 0) continue;
    if (m[5] !== undefined || m[6] !== undefined) {
      const text = decode(m[5] !== undefined ? m[5] : m[6]);
      if (/^\s*$/.test(text)) continue;
      top.appendChild(textNode(text));
      continue;
    }
    const closing = m[1] === '/';
    const tag = m[2].toLowerCase();
    if (closing) {
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i].tagName === tag.toUpperCase()) { stack.length = i; break; }
      }
      continue;
    }
    const node = doc.createElement(tag);
    const attrRe = /([^\s=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
    let a;
    while ((a = attrRe.exec(m[3] || '')) !== null) {
      const value = a[2] !== undefined ? a[2] : (a[3] !== undefined ? a[3] : (a[4] !== undefined ? a[4] : ''));
      applyAttribute(node, a[1], decode(value));
    }
    top.appendChild(node);
    if (!VOID[tag] && m[4] !== '/') stack.push(node);
  }
}

/* ---- selectors: compound only, which is all the page and the tests use ---- */

function compile(selector) {
  const parts = [];
  const re = /([a-zA-Z][a-zA-Z0-9-]*)|#([\w.-]+)|\.([\w-]+)|\[([\w-]+)(?:="([^"]*)")?\]/g;
  let m;
  while ((m = re.exec(selector)) !== null) {
    if (m[1]) { const tag = m[1].toUpperCase(); parts.push(function (n) { return n.tagName === tag; }); }
    else if (m[2]) { const id = m[2]; parts.push(function (n) { return n.id === id; }); }
    else if (m[3]) { const c = m[3]; parts.push(function (n) { return n.classList.contains(c); }); }
    else if (m[4]) {
      const name = m[4], value = m[5];
      parts.push(function (n) {
        const v = n.getAttribute(name);
        return v !== null && (value === undefined || v === value);
      });
    }
  }
  return function (node) {
    if (!node || node.nodeType === 3) return false;
    for (let i = 0; i < parts.length; i++) if (!parts[i](node)) return false;
    return true;
  };
}

function matcher(selector) {
  const alternatives = String(selector).split(',').map(function (s) { return compile(s.trim()); });
  return function (node) {
    return alternatives.some(function (fn) { return fn(node); });
  };
}

let installed = false;

/** Teach the shim's nodes markup, attributes and selectors. Once per run:
 *  it changes Node.prototype, which every document shares. */
function patchPrototype() {
  if (installed) return;
  installed = true;
  const proto = Node.prototype;

  proto.getAttribute = function (name) {
    name = String(name).toLowerCase();
    if (name === 'id') return this._id === undefined ? null : this._id;
    if (name === 'class') return this._className || null;
    return Object.prototype.hasOwnProperty.call(this.attributes, name) ? String(this.attributes[name]) : null;
  };
  proto.hasAttribute = function (name) { return this.getAttribute(name) !== null; };
  const plainSet = proto.setAttribute;
  proto.setAttribute = function (name, value) {
    if (String(name).toLowerCase() === 'class') { this.className = value; return; }
    plainSet.call(this, String(name).toLowerCase(), String(value));
  };
  proto.removeAttribute = function (name) { delete this.attributes[String(name).toLowerCase()]; };

  proto.matches = function (selector) { return matcher(selector)(this); };
  proto.querySelectorAll = function (selector) {
    const test = matcher(selector);
    return this.all().filter(test);
  };
  proto.querySelector = function (selector) { return this.querySelectorAll(selector)[0] || null; };
  proto.closest = function (selector) {
    const test = matcher(selector);
    let node = this;
    while (node && node.tagName !== 'DOCUMENT') {
      if (test(node)) return node;
      node = node.parentNode;
    }
    return null;
  };
  proto.contains = function (other) {
    let node = other;
    while (node) { if (node === this) return true; node = node.parentNode; }
    return false;
  };

  // classList.add/remove, which a browser has and dom.js did not need.
  const list = Object.getPrototypeOf(new Node('div').classList);
  list.add = function (name) { this.toggle(name, true); };
  list.remove = function (name) { this.toggle(name, false); };
}

/* Markup, parsed. dom.js defines innerHTML on the prototype, for good, so
   it is defined again on each node this document makes: '' keeps dom.js's
   own meaning (the count of clears), anything else is parsed. */
const plainInner = Object.getOwnPropertyDescriptor(Node.prototype, 'innerHTML');

function teachMarkup(node, doc) {
  node.ownerDocument = doc;
  Object.defineProperty(node, 'innerHTML', {
    get: plainInner.get,
    set: function (v) {
      plainInner.set.call(this, '');
      if (v === '' || v === null || v === undefined) return;
      parseInto(this, String(v), doc);
    },
    configurable: true
  });
  return node;
}

/** Install over one document from dom.js's makeDocument. */
function install(doc) {
  patchPrototype();
  // Every node the page makes knows its document, so markup it is given
  // registers ids with the same register getElementById reads.
  const make = doc.createElement;
  doc.createElement = function (tag) { return teachMarkup(make.call(doc, tag), doc); };
  doc.ownerDocument = doc;
  doc.all().forEach(function (node) { teachMarkup(node, doc); });
  return doc;
}

/** Fire an event at a node and let it bubble to the document, as a browser
 *  does: each listener sees the node it was fired at as event.target. */
function dispatch(node, type, init) {
  let stopped = false;
  const event = Object.assign({
    type: type, target: node, defaultPrevented: false,
    preventDefault: function () { event.defaultPrevented = true; },
    stopPropagation: function () { stopped = true; }
  }, init || {});
  let at = node;
  while (at && !stopped) {
    event.currentTarget = at;
    const listeners = (at._listeners && at._listeners[type]) || [];
    for (let i = 0; i < listeners.length; i++) listeners[i](event);
    at = at.parentNode;
  }
  return event;
}

module.exports = { install: install, dispatch: dispatch, parseInto: parseInto, decode: decode };
