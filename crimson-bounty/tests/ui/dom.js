/* A minimal DOM, enough to run the app's real code.
 *
 * The UI is the part of this resource a Lua test cannot reach, and it is the
 * part that has broken worst: a form that could never submit, an app that
 * refreshed itself into a storm, a card that threw and blanked the screen.
 * None of those were visible until someone ran the page.
 */

'use strict';

function Node(tag) {
  this.tagName = (tag || '').toUpperCase();
  this.children = [];
  this.parentNode = null;
  this.attributes = {};
  this.style = {};
  this.dataset = {};
  this.classList = new ClassList(this);
  this._className = '';
  this._textContent = '';
  this._listeners = {};
  this.value = '';
  this.checked = false;
}

Object.defineProperty(Node.prototype, 'className', {
  get: function () { return this._className; },
  set: function (v) { this._className = String(v); }
});

Object.defineProperty(Node.prototype, 'textContent', {
  get: function () {
    if (this.children.length === 0) return this._textContent;
    return this.children.map(function (c) { return c.textContent; }).join('');
  },
  set: function (v) { this._textContent = String(v); this.children = []; }
});

Object.defineProperty(Node.prototype, 'innerHTML', {
  get: function () { return this.children.length ? '<...>' : ''; },
  set: function (v) { if (v === '') this.children = []; }
});

function ClassList(node) { this.node = node; }
ClassList.prototype.toggle = function (name, on) {
  var has = this.node._className.split(' ').indexOf(name) !== -1;
  var want = on === undefined ? !has : !!on;
  if (want && !has) this.node._className += ' ' + name;
  if (!want && has) {
    this.node._className = this.node._className.split(' ')
      .filter(function (c) { return c !== name; }).join(' ');
  }
};
ClassList.prototype.contains = function (name) {
  return this.node._className.split(' ').indexOf(name) !== -1;
};

Node.prototype.appendChild = function (child) {
  child.parentNode = this;
  this.children.push(child);
  return child;
};
Node.prototype.addEventListener = function (type, fn) {
  (this._listeners[type] = this._listeners[type] || []).push(fn);
};
Node.prototype.setAttribute = function (k, v) { this.attributes[k] = v; };

/** Every node in the tree, for querying and for driving clicks. */
Node.prototype.all = function (out) {
  out = out || [];
  for (var i = 0; i < this.children.length; i++) {
    out.push(this.children[i]);
    this.children[i].all(out);
  }
  return out;
};

function makeDocument() {
  var doc = new Node('document');
  var byId = {};

  doc.createElement = function (tag) {
    var node = new Node(tag);
    var realId = Object.defineProperty;
    // Registering on id assignment is what getElementById needs, since the
    // app builds nodes and sets ids before attaching them.
    realId(node, 'id', {
      get: function () { return node._id; },
      set: function (v) { node._id = v; byId[v] = node; },
      configurable: true
    });
    return node;
  };

  doc.getElementById = function (id) { return byId[id] || null; };

  doc.querySelectorAll = function (selector) {
    var wanted = selector.replace('.', '');
    return doc.all().filter(function (n) {
      return n._className && n._className.split(' ').indexOf(wanted) !== -1;
    });
  };

  doc._byId = byId;
  return doc;
}

module.exports = { Node: Node, makeDocument: makeDocument };
