// Runs the page's scripts against a stand-in for the DOM, to catch errors without a browser:
// node page-check.js
const fs = require('fs');
const vm = require('vm');

const page = fs.readFileSync(`${__dirname}/debugger.html`, 'utf8');
const ui = [...page.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((match) => match[1]).join('\n');
const engine = fs.readFileSync(`${__dirname}/engine.js`, 'utf8');

const stub = `
function el() {
  const check = (nodes) => { for (const node of nodes) if (Array.isArray(node)) throw new Error('an array was appended'); };
  const e = { children: [], listeners: {}, attributes: {}, className: '', disabled: false, value: '', textContent: '',
    append(...nodes) { check(nodes); e.children.push(...nodes); },
    replaceChildren(...nodes) { check(nodes); e.children = nodes; },
    addEventListener(name, f) { e.listeners[name] = f; }, setAttribute(name, value) { e.attributes[name] = value; },
    scrollIntoView() {}, matches() { return false; } };
  return e;
}
const byId = {};
const document = { createElement: el, createElementNS: el, getElementById: (id) => (byId[id] ??= el()), addEventListener() {} };
const text = (e) => (typeof e !== 'object' ? String(e) : (e.textContent || '') + e.children.map(text).join(' ')).replace(/\\s+/g, ' ').trim();
`;

const exercise = `
const say = (label, value) => console.log(label.padEnd(18), value);
const rowsIn = (e) => (typeof e !== 'object' ? 0 : (String(e.className).split(' ').includes('node') ? 1 : 0) + e.children.reduce((n, c) => n + rowsIn(c), 0));
say('entries, branches', byId.log.children.length + ', ' + branches.map((b) => b.result.kind).join(' '));
say('the tree', rowsIn(byId.tree) + ' rows for ' + (nodes.length - 1) + ' entries; a row reads: ' + JSON.stringify(text(byId.tree.children[0])));
say('the log title', text(byId.logTitle));
say('the root', text(byId.log.children[0]));
say('the agent opens', text(byId.log.children[1]));
say('a read', text(byId.log.children[7]));
say('a command', text(byId.log.children[12]));
stepOver(); say('step over', index); stepOut(); say('step out', index); nextSample(); say('next model call', index);
go(0); say('the root entry', text(byId.eventSection));
go(1); say('the configuration', text(byId.eventSection));
go(6); say('a reply', text(byId.log.children[6]) + ' | ' + text(byId.eventSection));
go(18); say('a stack', text(byId.stackSection));
say('its call', text(byId.frameSection).slice(0, 120));
go(44); say('an external program', text(byId.log.children[44]) + ' | ' + text(byId.eventSection));
say('a grader call', text(byId.stackSection));
go(24); say('the state', text(byId.stateSection));
head = branches[4]; go(25); say('a stop', text(byId.log.children[25]) + ' | ' + text(byId.eventSection));
say('its branch', text(byId.result));
head = branches[1]; go(events().length - 1);
say('a waiting branch', text(byId.result));
reply({ kind: 'text', answer: 'maybe' }); say('a reply refused', text(byId.result));
reply({ kind: 'no' }); say('after a reply', head.result.kind + ': ' + head.result.value);
go(18); askAgain(); say('ask again', head.how + ': ' + head.result.kind);
addNotice('hello'); say('add a notice', head.how + ': ' + head.result.kind + forkError);
go(4); runEditedAnswer('{"text":"all done","toolCalls":[]}'); say('edit an answer', head.how + ': ' + head.result.value + forkError);
runEditedAnswer('{"text":1}'); say('a bad edit', forkError);
head = branches[5]; go(33); say('a failure', text(byId.log.children[33]) + ' | ' + text(byId.log.children[34]));
head = branches[6]; go(18); say('a model failure', text(byId.log.children[18]) + ' | ' + text(byId.log.children[19]));
head = branches[0]; go(12); makeFail(); say('make a call fail', head.how + ': ' + text(byId.log.children[12]) + ' -> ' + head.result.kind + forkError);
head = branches[0]; go(31); stopHere(); say('stop the agent', head.how + ': ' + head.result.value);
collapsed.add(nodes[1].hash); renderTree(); say('collapsed', rowsIn(byId.tree) + ' row: ' + JSON.stringify(text(byId.tree.children[0])));
`;

vm.runInNewContext(stub + engine + ui + exercise, { console });
