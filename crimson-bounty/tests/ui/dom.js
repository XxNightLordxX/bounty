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

// The real thing has both: childNodes is every node, children is the element
// ones. Nothing here creates text nodes, so they are the same list — but code
// written against either must work, or the harness starts diverging from the
// browser the app actually runs in.
Object.defineProperty(Node.prototype, 'childNodes', {
  get: function () { return this.children; }
});

Object.defineProperty(Node.prototype, 'innerHTML', {
  get: function () { return this.children.length ? '<...>' : ''; },
  // Counted, because rebuilding the view is what the app's own redraw
  // costs and there is no other way to see how often it happens. One click
  // used to redraw the whole page three times over.
  set: function (v) { if (v === '') { this._clears = (this._clears || 0) + 1; this.children = []; } }
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
  // A real <select> reports its first option as its value until something
  // changes it. The pickers rely on that, so the harness has to do it too —
  // otherwise a test would pass on a select the browser reads differently.
  if (this.tagName === 'SELECT' && child.tagName === 'OPTION'
      && this.children.length === 1) {
    this.value = child.value;
  }
  return child;
};
/* The other half of appendChild.
 *
 * Absent until now, so anything the app removes rather than rebuilds — an
 * overlay closing, a row deleted in place — threw here while working
 * perfectly in a browser. A shim that is missing a method does not report a
 * gap in itself; it reports a bug in the code under test. */
Node.prototype.removeChild = function (child) {
  var at = this.children.indexOf(child);
  if (at === -1) { return child; }
  this.children.splice(at, 1);
  child.parentNode = null;
  return child;
};

Node.prototype.remove = function () {
  if (this.parentNode) { this.parentNode.removeChild(this); }
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

  /* Only nodes that are still in the document.
   *
   * The register is written on id assignment and was never cleaned, so a
   * node the app had removed stayed findable by id forever. A test asserting
   * that something had CLOSED read the detached node and saw it open — and
   * the assertion helper then tried to print it, so the failure that
   * surfaced was a circular-structure error rather than the thing that was
   * actually wrong. */
  function attached(node) {
    while (node) {
      if (node === doc) { return true; }
      node = node.parentNode;
    }
    return false;
  }

  doc.getElementById = function (id) {
    var node = byId[id];
    if (!node) { return null; }
    if (!attached(node)) { delete byId[id]; return null; }
    return node;
  };

  doc.querySelectorAll = function (selector) {
    var wanted = selector.replace('.', '');
    return doc.all().filter(function (n) {
      return n._className && n._className.split(' ').indexOf(wanted) !== -1;
    });
  };

  // A real document has one, and anything that draws over the page rather
  // than inside #view appends to it — an overlay, a dialog, the
  // diagnostics panel. Without it the shim answered undefined and every
  // such thing threw on appendChild, which the suite could only read as
  // "a click threw" with no idea why.
  doc.body = doc.createElement('body');
  doc.appendChild(doc.body);

  doc._byId = byId;
  return doc;
}

module.exports = { Node: Node, makeDocument: makeDocument };
