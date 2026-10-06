// Runs the report's script against a stand-in for the DOM, selecting every entry of the page
// and switching to every branch, to catch errors without a browser: node page-check.js PAGE
const fs = require('fs');
const vm = require('vm');

const page = fs.readFileSync(process.argv[2], 'utf8');
const data = page.match(/<script id="data" type="application\/json">([\s\S]*?)<\/script>/)[1];
const script = [...page.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join('\n');

function element() {
  const e = {
    children: [], listeners: {}, attributes: {}, dataset: {}, style: {}, className: '', textContent: '',
    innerHTML: '', value: '', open: false, scrollHeight: 0, clientHeight: 0,
    classList: {
      set: new Set(),
      add(c) { this.set.add(c); }, remove(c) { this.set.delete(c); },
      contains(c) { return this.set.has(c); },
      toggle(c, on) { const want = on === undefined ? !this.set.has(c) : on; if (want) this.set.add(c); else this.set.delete(c); return want; },
    },
    append(...nodes) { for (const n of nodes) if (Array.isArray(n)) throw new Error('an array was appended'); e.children.push(...nodes); },
    insertBefore(n) { e.children.push(n); },
    addEventListener(name, f) { e.listeners[name] = f; },
    setAttribute(name, v) { e.attributes[name] = v; },
    scrollIntoView() {},
    remove() {},
    get lastChild() { return e.children[e.children.length - 1]; },
  };
  return e;
}
const byId = {};
const document = {
  getElementById(id) {
    if (id === 'data') return { textContent: data };
    return byId[id] || (byId[id] = element());
  },
  createElement: () => element(),
  createTextNode: (text) => ({ text }),
};
const sandbox = { document, location: { hash: '' }, requestAnimationFrame: (f) => f(), JSON, Math, Object,
  Array, Set, Map, String, Number, Uint32Array, console, Node: function Node() {} };
vm.createContext(sandbox);
vm.runInContext(script + `
;for (let i = 0; i < entries.length; i++) select(i);
for (const i of entries.map((e, i) => i).filter(isLeaf)) switchTo(i);
find('sample', 1); find('sample', 1); find('', 0);
`, sandbox);
console.log('ok ' + JSON.parse(data).entries.length);
