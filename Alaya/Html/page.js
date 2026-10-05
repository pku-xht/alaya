// The report's page: it reads the forest from the data element and shows it. It only reads:
// nothing on it runs anything or changes the logs.
const data = JSON.parse(document.getElementById('data').textContent);
const entries = data.entries;

/* --- the forest -------------------------------------------------------
   An entry is one event and the entry before it; a log is the path from a root to an entry; a
   branch is a log no entry follows. Every entry is shown at most once per branch. */

const children = entries.map(() => []);
entries.forEach((e, i) => { if (e.p !== null) children[e.p].push(i); });
const roots = entries.map((e, i) => i).filter(i => entries[i].p === null);

/* A comment that nothing follows, beside another continuation of its entry, is no branch: it is
   an annotation on the entry, shown under it in every log through it. */
const isLone = i => entries[i].e.k === 'comment' && children[i].length === 0;
const isNote = i => isLone(i) && entries[i].p !== null && children[entries[i].p].some(c => !isLone(c));
const kids = entries.map((e, i) => children[i].filter(c => !isNote(c)));
const notes = entries.map((e, i) => children[i].filter(isNote));
const isLeaf = i => kids[i].length === 0;

/** The deepest entry under `i`: the end of its longest branch, which is what a switch to `i`
shows. */
const deepest = new Array(entries.length);
for (let i = entries.length - 1; i >= 0; i--) {
  let best = i;
  for (const c of kids[i]) if (entries[deepest[c]].pos > entries[best].pos) best = deepest[c];
  deepest[i] = best;
}

function pathTo(i) {
  const path = [];
  for (let at = i; at !== null; at = entries[at].p) path.push(at);
  return path.reverse();
}

const short = h => h.slice(0, 12);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = text;
  return n;
};
const flat = (s, n = 90) => {
  s = String(s ?? '').replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
};
const given = v => v !== null && v !== undefined;

function duration(ms) {
  const s = ms / 1000;
  if (s < 60) return s.toFixed(1) + ' s';
  const m = Math.floor(s / 60);
  const rest = Math.round(s - 60 * m);
  if (m < 60) return m + ' min' + (rest ? ' ' + rest + ' s' : '');
  return Math.floor(m / 60) + ' h' + (m % 60 ? ' ' + (m % 60) + ' min' : '');
}

/** A count of tokens in a few characters: 980, 20.3k, 1.05M. */
function compact(n) {
  if (n >= 1e6) return +(n / 1e6).toFixed(2) + 'M';
  if (n >= 1e3) return +(n / 1e3).toFixed(1) + 'k';
  return String(n);
}

/* --- what an entry says, in a line ------------------------------------ */

function verdictOf(value) {
  if (Array.isArray(value)) return value.map(verdictOf).filter(Boolean).join(', ');
  if (value && typeof value === 'object' && typeof value.status === 'string' && given(value.total))
    return value.status + ' ' + value.passed + '/' + value.total;
  return null;
}

function summary(i) {
  const e = entries[i].e;
  switch (e.k) {
    case 'said': return 'said “' + flat(e.text, 70) + '”';
    case 'changed': return entries[i].p === null ? 'the workspace the run starts from'
      : 'workspace changed: ' + flat(e.text, 70);
    case 'replied': return 'replied to ' + e.to.join('.') + ': ' + flat(e.text, 60);
    case 'assigned': return 'assigned grader “' + flat(e.summary, 60) + '”';
    case 'heard': return e.notices.length ? 'inbox: takes ' + e.notices.join(', ') : 'inbox: nothing';
    case 'asked': return 'ask “' + flat(e.text, 70) + '”';
    case 'sample':
      if (given(e.error)) return 'sample failed: ' + flat(e.error, 70);
      if (e.calls.length) return 'sample → ' + e.calls.map(c => c.name + ' ' + flat(c.summary, 50)).join('; ');
      return 'sample → says “' + flat(e.content, 60) + '”';
    case 'exec':
      if (given(e.error)) return 'exec failed: ' + flat(e.error, 70);
      return 'exec ' + flat(e.command, 60) + ' → ' + (given(e.exit) ? 'exit ' + e.exit : flat(e.failure, 30));
    case 'time': return given(e.error) ? 'time failed' : 'time ' + duration(e.spent) + (given(e.budget) ? ' of ' + duration(e.budget) : '');
    case 'external':
      if (given(e.error)) return 'external failed: ' + flat(e.error, 70);
      return 'external ' + flat(e.command, 50) + ' → ' + (given(e.exit) ? 'exit ' + e.exit : flat(e.failure, 30));
    case 'open':
      if (e.routine === 'agent') {
        const a = (e.arguments || {}).agent || {}, m = (e.arguments || {}).model || {};
        return 'open agent: ' + (a.name || '?') + ', ' + (m.name || '?');
      }
      return 'open ' + e.routine + ' “' + flat(e.summary, 60) + '”';
    case 'return': return 'return ' + (verdictOf(e.value) || flat(e.summary, 70));
    case 'fail': return 'fail: ' + flat(e.error, 70);
    case 'stop': return 'stopped: ' + flat(e.text, 70);
    case 'comment': return '# ' + flat(e.text, 80);
    default: return e.k;
  }
}

/* A glyph per kind of event, on a 14x14 grid. */
const GLYPHS = {
  root: '<circle cx="7" cy="7" r="2.6"/><circle cx="7" cy="7" r="5.6" fill="none"/>',
  said: '<path d="M2 3h10v6H6l-3 2.5V9H2z" fill="none"/>',
  changed: '<path d="M7 1.6L12.4 7 7 12.4 1.6 7z" fill="none"/>',
  replied: '<path d="M6 3.5L2.5 7 6 10.5" fill="none"/><path d="M2.5 7h5.5a3 3 0 0 1 3 3v1.5" fill="none"/>',
  assigned: '<path d="M3 2.5h8v9H3z" fill="none"/><path d="M5 5.5l1.2 1.2L8.8 4.2M5 9h4" fill="none"/>',
  heard: '<path d="M2 8.5h3l1 1.5h2l1-1.5h3" fill="none"/><path d="M2 8.5L3.5 3h7L12 8.5v3H2z" fill="none"/>',
  sample: '<path d="M2.5 3.5L6 7l-3.5 3.5" fill="none"/><path d="M7.5 10.5h4" fill="none"/>',
  exec: '<path d="M4 2.5l7 4.5-7 4.5z" fill="none"/>',
  time: '<circle cx="7" cy="7" r="5.2" fill="none"/><path d="M7 4v3.2l2.2 1.4" fill="none"/>',
  external: '<rect x="2" y="3.5" width="10" height="8" rx="1" fill="none"/><path d="M4.5 3.5V2h5v1.5" fill="none"/>',
  open: '<path d="M2 7h7" fill="none"/><path d="M6.5 4.5L9 7l-2.5 2.5" fill="none"/><path d="M11.5 2.5v9" fill="none"/>',
  return: '<path d="M11.5 4.5v2.5a2 2 0 0 1-2 2H3" fill="none"/><path d="M5.5 6.5L3 9l2.5 2.5" fill="none"/>',
  fail: '<path d="M3.2 3.2l7.6 7.6M10.8 3.2l-7.6 7.6" fill="none"/>',
  stop: '<rect x="3" y="3" width="8" height="8" rx="1" fill="none"/>',
  comment: '<path d="M5.6 2.5l-1.2 9M9.6 2.5l-1.2 9M3 5.5h8.5M2.5 8.5H11" fill="none"/>',
  question: '<path d="M4.6 5.3a2.4 2.4 0 1 1 3.3 2.2c-.6.3-.9.7-.9 1.4" fill="none"/><circle cx="7" cy="11.2" r=".8" stroke="none"/>'
};

function glyphOf(i) {
  const e = entries[i].e;
  if (entries[i].p === null) return 'root';
  if (e.k === 'asked') return 'question';
  if (['sample', 'exec', 'time', 'external'].includes(e.k) && given(e.error)) return 'fail';
  return GLYPHS[e.k] ? e.k : 'open';
}

function icon(i) {
  const key = glyphOf(i);
  const holder = el('span', 'ic i-' + key);
  holder.innerHTML = '<svg viewBox="0 0 14 14" width="13" height="13" stroke="currentColor" ' +
    'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" fill="currentColor">' +
    GLYPHS[key] + '</svg>';
  return holder;
}

/** How a log ends, on the entry that ends it: its verdict when the run is graded, or how its
agent ended, or what it waits for. */
function stateChip(i) {
  const x = entries[i];
  if (!x.state) return null;
  const label = x.graded || { done: 'done', failed: 'failed', stopped: 'stopped', question: 'waits for a reply',
    waits: 'waits', paused: 'paused', broken: 'broken' }[x.state] || x.state;
  // A graded run is coloured by its verdict: green only for a pass.
  const cls = x.graded ? (/\b(fail|error)\b/.test(x.graded) ? 'bad' : 'ok')
    : { done: 'ok', failed: 'bad', broken: 'bad', question: 'wait', waits: 'wait' }[x.state] || '';
  const chip = el('span', 'chip ' + cls, label);
  chip.title = x.next || '';
  return chip;
}

/* --- the run an entry belongs to --------------------------------------- */

/** The task of a run: the first thing a person said, right after the agent is opened. */
function taskOf(opening) {
  if (opening === null) return null;
  for (const c of children[opening]) if (entries[c].e.k === 'said') return entries[c].e.text;
  return null;
}

function runTitle(root) {
  const opening = children[root].find(c => entries[c].config);
  if (opening === undefined) return { name: 'a run', task: '' };
  const config = entries[opening].config;
  return { name: (config.agent.name || '?') + ', ' + (config.model.name || '?'), task: taskOf(opening) || '' };
}

/* --- state ------------------------------------------------------------- */

let leaf = null;       // the branch shown: the entry that ends it
let selected = null;   // the entry whose page is shown
let rows = new Map();  // entry -> its row in the log
let order = [];        // the branch's entries, in order

/* --- rows ----------------------------------------------------------------
   The branches and the log are lists of the same rows: a position, or a range of them, the
   depth as thin guides, an icon, and what the row says. */

function rowOf(position, depth, i, cls) {
  const row = el('div', 'row' + (cls ? ' ' + cls : ''));
  row.append(el('span', 'pos', position));
  for (let d = 0; d < depth; d++) row.append(el('span', 'guide'));
  row.append(icon(i));
  return row;
}

/* --- the branches ---------------------------------------------------------
   A run, and under it every stretch of entries that starts at a fork, by what starts it: how the
   branch departs. The end of a branch says how its log ends. */

function renderBranches() {
  const box = document.getElementById('branches');
  box.textContent = '';
  const onPath = new Set(pathTo(leaf));
  const stretch = start => {
    let end = start;
    while (kids[end].length === 1) end = kids[end][0];
    return end;
  };
  const place = (start, depth, label) => {
    const end = stretch(start);
    const range = entries[start].pos === entries[end].pos ? String(entries[start].pos)
      : entries[start].pos + '–' + entries[end].pos;
    const row = rowOf(range, depth, start, 'branch' + (onPath.has(end) ? ' on' : ''));
    row.append(label || el('span', 'sum', summary(start)));
    const chip = stateChip(end);
    if (chip) row.append(chip);
    row.onclick = () => switchTo(start);
    box.append(row);
    for (const c of kids[end]) place(c, depth + 1);
  };
  for (const r of roots) {
    const title = runTitle(r);
    const label = el('span', 'sum');
    label.append(el('b', null, title.name), document.createTextNode('  ' + flat(title.task, 90)));
    place(r, 0, label);
  }
}

/* --- the log --------------------------------------------------------------
   A row an entry, indented by its frame: an entry of a call's frame one level under the call's
   opening, so a tool's events nest under it. A notice or a stop, which come from outside, sits at
   the depth of the call that is open. */

function depths(path) {
  const depth = new Map();
  let open = 0;   // calls opened and not yet ended
  for (const i of path) {
    const x = entries[i], f = x.f;
    if (x.p === null) depth.set(i, 0);
    else if (f === null) depth.set(i, open + 1);
    else if (x.e.k === 'open') depth.set(i, f.length);
    else depth.set(i, f.length + 1);
    if (x.e.k === 'open') open++;
    else if ((x.e.k === 'return' || x.e.k === 'fail') && f !== null && f.length) open = Math.max(0, open - 1);
    else if (x.e.k === 'stop') open = 0;
  }
  return depth;
}

function renderLog() {
  const box = document.getElementById('log');
  box.textContent = '';
  rows = new Map();
  order = pathTo(leaf);
  const depth = depths(order);
  const kindOf = x => x.e.k === 'comment' ? 'comment' : x.f === null ? 'notice' : '';
  for (const i of order) {
    const x = entries[i];
    const row = rowOf(String(x.pos), depth.get(i) || 0, i, kindOf(x));
    const text = el('span', 'sum');
    text.append(el('span', 'hash', short(x.h)), document.createTextNode(' ' + summary(i)));
    row.append(text);
    if (x.t >= 1000) row.append(el('span', 'took', duration(x.t)));
    // A switch to the other branches that fork here.
    if (x.p !== null && kids[x.p].length > 1) {
      const siblings = kids[x.p];
      const k = siblings.indexOf(i);
      const fork = el('span', 'fork');
      const back = el('button', null, '‹'), on = el('button', null, '›');
      back.title = 'the branch before'; on.title = 'the branch after';
      back.onclick = event => { event.stopPropagation(); switchTo(siblings[(k + siblings.length - 1) % siblings.length]); };
      on.onclick = event => { event.stopPropagation(); switchTo(siblings[(k + 1) % siblings.length]); };
      fork.append(back, el('span', null, (k + 1) + '/' + siblings.length), on);
      fork.title = siblings.length + ' branches fork here';
      row.append(fork);
    }
    if (i === leaf) { const c = stateChip(i); if (c) row.append(c); }
    row.onclick = () => select(i);
    rows.set(i, row);
    box.append(row);
    // The annotations on the entry: comments beside its continuation.
    for (const n of notes[i]) {
      const note = rowOf(String(entries[n].pos), Math.max(1, depth.get(i) || 0), n, 'comment');
      const said = el('span', 'sum');
      said.append(el('span', 'hash', short(entries[n].h)), document.createTextNode(' ' + summary(n)));
      note.append(said);
      note.onclick = () => select(n);
      rows.set(n, note);
      box.append(note);
    }
  }
}

function switchTo(i) {
  show(deepest[i]);
  select(i);
}

/** Shows the branch that ends at `end`. */
function show(end) {
  if (end === leaf) return;
  leaf = end;
  renderBranches();
  renderLog();
}

function markSelected() {
  for (const [i, row] of rows) row.classList.toggle('on', i === selected);
  const row = rows.get(selected);
  if (row) row.scrollIntoView({ block: 'nearest' });
}

/* --- the page of an entry ---------------------------------------------------
   Every entry has the same page: what it is and where it happened; a few facts; what it holds,
   as labelled blocks; and, where it has them, the request it answered and the files it changed.
   One list of facts, one kind of block, one way to write a time, a count and a name. */

/** Wraps a node so anything tall collapses to a clip with a toggle. */
function foldable(node, label) {
  const wrap = el('div', 'fold closed');
  const clip = el('div', 'clip');
  clip.append(node);
  const more = 'Show all' + (label ? ' (' + label + ')' : '');
  const button = el('button', null, more);
  button.onclick = () => {
    const closed = wrap.classList.toggle('closed');
    button.textContent = closed ? more : 'Collapse';
  };
  wrap.append(clip, button);
  requestAnimationFrame(() => {
    if (clip.scrollHeight <= clip.clientHeight + 4) { wrap.classList.remove('closed'); button.remove(); }
  });
  return wrap;
}

/** A labelled block of text, as it is: a command, an output, a message. */
function block(parent, label, content, cls) {
  if (label) parent.append(el('div', 'label', label));
  const lines = String(content).split('\n').length;
  parent.append(foldable(el('pre', 'block' + (cls ? ' ' + cls : ''), content), lines > 1 ? lines + ' lines' : ''));
}

const json = value => JSON.stringify(value, null, 2);

/** A list of facts: a name and a value a row; a fact with no value is left out. */
function facts(parent, pairs, cls) {
  const list = el('dl', 'facts' + (cls ? ' ' + cls : ''));
  for (const [name, value, tone] of pairs) {
    if (value === null || value === undefined || value === '') continue;
    const dd = el('dd', tone || null);
    if (typeof value === 'string') dd.textContent = value; else dd.append(value);
    list.append(el('dt', null, name), dd);
  }
  if (list.children.length) parent.append(list);
  return list;
}

function section(parent, title, note) {
  const head = el('h2', null, title);
  if (note) head.append(el('small', null, note));
  parent.append(head);
}

function link(i, label) {
  const a = el('a', null, label || short(entries[i].h));
  a.onclick = () => select(i);
  return a;
}

/** A snapshot's name, short, with the whole of it on hover. */
function snapshot(hex) {
  const span = el('span', 'mono', short(hex));
  span.title = hex;
  return span;
}

const cached = u => u && u.input && u.cached ? ', ' + Math.round(100 * u.cached / u.input) + '% cached' : '';

/** The calls an entry is inside of, outermost first, as the entries that opened them. A return
or a failure is inside the call it ends; an opening is not inside itself. */
function callsAround(i) {
  const open = [];
  for (const j of pathTo(i)) {
    const x = entries[j];
    if (x.e.k === 'open') { if (j !== i) open.push(j); }
    else if ((x.e.k === 'return' || x.e.k === 'fail') && x.f && x.f.length) { if (j !== i) open.pop(); }
    else if (x.e.k === 'stop') { while (open.length && entries[open[open.length - 1]].f[0] === 0) open.pop(); }
  }
  return open;
}

/** What an entry is, in a word or two: the words of its row in the log. */
function titleOf(i) {
  const x = entries[i], e = x.e;
  if (x.p === null) return 'root';
  if (['sample', 'exec', 'time', 'external'].includes(e.k) && given(e.error)) return e.k + ' failed';
  return { said: 'said', changed: 'changed', replied: 'replied', assigned: 'assigned grader', heard: 'inbox',
    asked: 'ask',
    open: 'open ' + e.routine, return: 'return', fail: 'fail', stop: 'stopped', comment: 'comment' }[e.k] || e.k;
}

/** Where an entry happened: the calls it is inside of, each a link to its opening; a notice and
a stop come from outside. */
function whereOf(i) {
  const x = entries[i];
  const line = el('div', 'where');
  const calls = callsAround(i);
  const inside = () => {
    calls.forEach((j, n) => {
      if (n) line.append(document.createTextNode(' › '));
      line.append(link(j, entries[j].e.routine));
    });
  };
  if (x.p === null) line.append(document.createTextNode('the workspace the run starts from'));
  else if (x.f === null) {
    line.append(document.createTextNode('from outside'));
    if (calls.length) { line.append(document.createTextNode(', while in ')); inside(); }
  } else if (calls.length) { line.append(document.createTextNode('in ')); inside(); }
  else line.append(document.createTextNode('in the run'));
  return line;
}

/** The fields of what a call is given, or of a value it gave: a long text, such as a command or
a question, as a block under its name, and the rest as facts. `title` goes before the first
block's label. */
function renderArguments(parent, title, args) {
  if (typeof args === 'string') { block(parent, title || 'arguments', args); return; }
  const entriesOf = args && typeof args === 'object' && !Array.isArray(args) ? Object.entries(args) : null;
  if (!entriesOf) { block(parent, title || 'arguments', json(args)); return; }
  const long = v => typeof v === 'string' && (v.includes('\n') || v.length > 60);
  // The first text is what the call is about, however short: a command, a question, a message.
  const first = entriesOf.find(([k, v]) => typeof v === 'string');
  const texts = entriesOf.filter(pair => pair === first || long(pair[1]));
  const rest = entriesOf.filter(pair => !texts.includes(pair));
  const name = key => key.replace(/_/g, ' ');
  texts.forEach(([key, value], n) => block(parent, n === 0 && title ? title + ' · ' + name(key) : name(key), value));
  if (!texts.length && title) parent.append(el('div', 'label', title));
  facts(parent, rest.map(([key, value]) => [name(key), typeof value === 'string' ? value
    : Array.isArray(value) && value.every(v => typeof v === 'string') ? (value.length ? value.join('\n') : 'none')
    : JSON.stringify(value)]));
}

/** A grader's verdict: its score, the checks that failed, and the rest folded. */
function renderVerdict(parent, verdict) {
  const line = el('div', 'verdict');
  line.append(el('b', verdict.status === 'pass' ? 'ok' : 'bad', verdict.status),
    document.createTextNode('  ' + verdict.passed + ' of ' + verdict.total + ' checks pass' +
      (verdict.total ? ' (' + Math.round(100 * verdict.passed / verdict.total) + '%)' : '')));
  parent.append(line);
  const failed = verdict.checks.filter(c => !c.ok), passed = verdict.checks.filter(c => c.ok);
  // The reason repeats the failed checks; alone, it says why there is no verdict on them.
  if (verdict.reason && !failed.length) block(parent, 'reason', verdict.reason, 'bad');
  const list = checks => {
    const grid = el('div', 'checks');
    for (const c of checks)
      grid.append(el('span', c.ok ? 'ok' : 'bad', c.ok ? 'ok' : 'not ok'),
        el('span', null, c.name + (c.directive ? '  # ' + c.directive : '')));
    return grid;
  };
  if (failed.length) {
    parent.append(el('div', 'label', failed.length + ' failed'));
    parent.append(foldable(list(failed), failed.length + ' checks'));
  }
  if (passed.length) {
    const rest = el('details', 'more');
    rest.append(el('summary', null, passed.length + ' passed'));
    rest.addEventListener('toggle', () => { if (rest.open && rest.children.length === 1) rest.append(list(passed)); });
    parent.append(rest);
  }
}

/** A value a call gave. Its `kind` is what the report says it is — a verdict, a command's
result, an agent's outcome — and the page does not guess: a value of no kind is shown as what
it holds, a text, the fields of an object, or JSON. */
function renderValue(parent, value, kind) {
  switch (kind) {
    case 'verdict': renderVerdict(parent, value); return;
    case 'command':
      facts(parent, [['exit status', given(value.exit_code) ? String(value.exit_code) : 'none', value.exit_code === 0 ? 'ok' : 'bad'],
        ['failure', value.error, 'bad'], ['whole output', value.file]]);
      block(parent, 'output', value.output || '(no output)');
      return;
    case 'outcome':
      facts(parent, [['status', value.status], ['reason', value.reason]]);
      if (value.submission) block(parent, 'submission', value.submission, 'prose');
      return;
  }
  if (typeof value === 'string') block(parent, 'value', value);
  else if (value && typeof value === 'object' && !Array.isArray(value)) renderArguments(parent, '', value);
  else block(parent, 'value', json(value));
}

/** A run's configuration: the agent's, the model's, and where its commands run. */
function settingRows(value, prefix = '') {
  const out = [];
  for (const [key, v] of Object.entries(value || {})) {
    const path = prefix + key;
    if (v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length) out.push(...settingRows(v, path + '.'));
    else if (Array.isArray(v) && v.length && v.every(p => Array.isArray(p) && p.length === 2))
      out.push([path, v.map(([k, w]) => k + '=' + w).join('  ')]);
    else if (Array.isArray(v) && v.every(s => typeof s === 'string')) out.push([path, v.length ? v.join(', ') : 'none']);
    else out.push([path, v === null ? 'none' : typeof v === 'string' ? v : JSON.stringify(v)]);
  }
  return out;
}

function renderConfig(parent, config) {
  for (const [title, value] of [['Agent', config.agent], ['Model', config.model], ['Environment', config.environment]]) {
    section(parent, title);
    facts(parent, settingRows(value), 'mono');
  }
}

/** What an entry holds. */
function renderEvent(parent, i) {
  const x = entries[i], e = x.e;
  // An operation always says how long it took; a mark only when that is worth saying.
  const took = ['sample', 'exec', 'time', 'external'].includes(e.k) || x.t >= 50 ? duration(x.t) : null;
  if (given(e.error)) {
    facts(parent, [['time', took]]);
    if (e.k === 'exec' || e.k === 'external') block(parent, 'command', e.command);
    block(parent, 'the world could not answer', e.error, 'bad');
    return;
  }
  switch (e.k) {
    case 'said': block(parent, null, e.text, 'prose'); break;
    case 'changed':
      facts(parent, [['workspace', snapshot(e.workspace)]]);
      if (x.p !== null) block(parent, 'what changed', e.text);
      break;
    case 'replied': block(parent, 'reply', e.text); break;
    case 'asked':
      block(parent, 'question', e.text, 'prose');
      facts(parent, [['kind', e.form]].concat(e.options.map((o, k) => [String(k + 1), o])));
      break;
    case 'assigned': {
      const g = e.grader || {};
      block(parent, 'command', g.command || '');
      facts(parent, [['image', g.image], ['input', g.input ? snapshot(g.input) : 'none'],
        ['time limit', g.timeout_seconds ? duration(1000 * g.timeout_seconds) : 'none']]);
      break;
    }
    case 'heard': {
      if (!e.notices.length) { parent.append(el('div', 'quiet', 'Nothing had arrived.')); break; }
      const list = el('div', 'taken');
      for (const position of e.notices) {
        const j = order[position];
        const item = el('div');
        item.append(el('span', 'pos', String(position)));
        if (j !== undefined) item.append(link(j), document.createTextNode(' ' + summary(j)));
        list.append(item);
      }
      parent.append(el('div', 'label', 'takes'), list);
      break;
    }
    case 'sample': {
      const u = e.usage || {}, request = x.request;
      const share = request && request.window ? Math.min(100, Math.round(100 * request.tokens / request.window)) : null;
      facts(parent, [['time', took],
        ['input', given(u.input) ? compact(u.input) + ' tokens' + cached(u) : null],
        ['output', given(u.output) ? compact(u.output) + ' tokens' + (u.reasoning ? ', ' + compact(u.reasoning) + ' reasoning' : '') : null],
        ['context', share !== null ? share + '% of ' + compact(request.window) + ' tokens' : null,
          share >= 95 ? 'bad' : share >= 80 ? 'warn' : null],
        ['cut short', e.finish && e.finish !== 'tool_calls' && e.finish !== 'stop' ? e.finish : null, 'warn']]);
      if (e.reasoning) block(parent, e.encrypted ? 'reasoning, as the provider summarises it' : 'reasoning', e.reasoning, 'prose quiet');
      else if (e.encrypted) parent.append(el('div', 'quiet', 'Its reasoning is kept encrypted, with no summary.'));
      if (e.content) block(parent, 'says', e.content, 'prose');
      for (const call of e.calls) renderArguments(parent, 'calls ' + call.name, call.arguments);
      if (!e.content && !e.calls.length) parent.append(el('div', 'quiet', 'An empty response.'));
      break;
    }
    case 'exec':
      facts(parent, [['time', took],
        ['exit status', given(e.exit) ? String(e.exit) : 'none', e.exit === 0 ? 'ok' : 'bad'],
        ['failure', e.failure, 'bad'], ['time limit', e.timeout ? duration(1000 * e.timeout) : 'none'],
        ['workspace', snapshot(e.workspace)], ['whole output', e.file]]);
      block(parent, 'command', e.command);
      block(parent, 'output', e.output || '(no output)');
      break;
    case 'time':
      facts(parent, [['time', took], ['run time', duration(e.spent)], ['budget', given(e.budget) ? duration(e.budget) : 'none']]);
      break;
    case 'external':
      facts(parent, [['time', took ? took + ', the program ' + duration(e.elapsed) : null],
        ['exit status', given(e.exit) ? String(e.exit) : 'none', e.exit === 0 ? 'ok' : 'bad'],
        ['failure', e.failure, 'bad'], ['image', e.image],
        ['input', e.input ? snapshot(e.input) : 'none'], ['checkout', snapshot(e.checkout)]]);
      block(parent, 'command', e.command);
      block(parent, 'stdout', e.stdout || '(empty)');
      if (e.stderr) block(parent, 'stderr', e.stderr);
      break;
    case 'open':
      // The agent's arguments are the run's configuration, shown below.
      if (e.routine !== 'agent') renderArguments(parent, '', e.arguments);
      break;
    case 'return': renderValue(parent, e.value, e.kind); break;
    case 'fail': block(parent, 'error', e.error, 'bad'); break;
    case 'stop': block(parent, 'reason', e.text, 'prose'); break;
    case 'comment': block(parent, null, e.text, 'prose'); break;
  }
}

/** The request a sample answered: what it adds to the one before it in the same conversation,
after the messages it shares with it, folded. */
function messagesOf(i) {
  const request = entries[i].request;
  if (!request) return [];
  const before = request.base === null ? [] : messagesOf(request.base);
  return before.concat(request.added);
}

function renderMessage(message, fresh, toolNames) {
  const box = el('div', 'msg' + (fresh ? ' new' : ''));
  const tool = message.routine_call_id ? toolNames.get(message.routine_call_id) : null;
  box.append(el('div', 'role', message.role + (tool ? ' · ' + tool : '')));
  if (message.reasoning_content) block(box, 'reasoning', message.reasoning_content, 'prose quiet');
  if (given(message.content) && message.content !== '') {
    // What a tool gave is sent as JSON, a text inside a text: shown as its fields, it can be read.
    let fields = null;
    if (message.role === 'tool' && typeof message.content === 'string') {
      try { fields = JSON.parse(message.content); } catch (error) { /* not JSON: as sent */ }
    }
    if (fields && typeof fields === 'object' && !Array.isArray(fields)) renderArguments(box, '', fields);
    else block(box, null, typeof message.content === 'string' ? message.content : json(message.content),
      message.role === 'tool' ? '' : 'prose');
  }
  for (const call of message.routine_calls || []) {
    const fn = call.function || {};
    let args = fn.arguments;
    try { args = JSON.parse(args); } catch (error) { /* as sent */ }
    renderArguments(box, 'calls ' + fn.name, args);
  }
  return box;
}

function renderRequest(parent, i) {
  const request = entries[i].request;
  if (!request) return;
  const messages = messagesOf(i);
  const fresh = request.added.length;
  section(parent, 'Request', messages.length + ' messages, ' + compact(request.tokens) + ' tokens' +
    (request.estimated ? ' (estimated)' : ''));
  // A tool's message names the call it answers by an id: the name of the tool says more.
  const toolNames = new Map();
  for (const m of messages) for (const call of m.tool_calls || []) toolNames.set(call.id, (call.function || {}).name);
  const asJson = el('button', 'plain', 'show as JSON');
  const holder = el('div');
  let whole = false;
  const draw = () => {
    holder.textContent = '';
    if (whole) {
      holder.append(el('pre', 'block', json(Object.assign({}, data.envelopes[request.envelope], { messages }))));
      return;
    }
    const earlier = messages.slice(0, messages.length - fresh);
    if (earlier.length) {
      const fold = el('details', 'more');
      fold.append(el('summary', null, earlier.length + ' earlier message' + (earlier.length > 1 ? 's' : '') +
        ', as in the request before'));
      fold.addEventListener('toggle', () => {
        if (fold.open && fold.children.length === 1) for (const m of earlier) fold.append(renderMessage(m, false, toolNames));
      });
      holder.append(fold);
    }
    for (const m of messages.slice(messages.length - fresh)) holder.append(renderMessage(m, earlier.length > 0, toolNames));
  };
  asJson.onclick = () => { whole = !whole; asJson.textContent = whole ? 'show as messages' : 'show as JSON'; draw(); };
  parent.append(asJson, holder);
  draw();
}

function lineDiff(oldText, newText) {
  const a = oldText.split('\n'), b = newText.split('\n');
  const n = a.length, m = b.length;
  if (n * m > 4e6) return [['-', '(too long to compare line by line)']];
  const lcs = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  const out = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { out.push([' ', a[i]]); i++; j++; }
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) out.push(['-', a[i++]]);
    else out.push(['+', b[j++]]);
  }
  while (i < n) out.push(['-', a[i++]]);
  while (j < m) out.push(['+', b[j++]]);
  return out;
}

function renderDiff(lines) {
  const box = el('div', 'diff');
  const keep = new Set();
  lines.forEach((line, k) => { if (line[0] !== ' ') for (let d = k - 3; d <= k + 3; d++) keep.add(d); });
  let elided = 0;
  lines.forEach((line, k) => {
    if (!keep.has(k)) { elided++; return; }
    if (elided) { box.append(el('div', 'gap', elided + ' unchanged lines')); elided = 0; }
    box.append(el('div', line[0] === '+' ? 'plus' : line[0] === '-' ? 'minus' : '', line[0] + ' ' + line[1]));
  });
  if (elided) box.append(el('div', 'gap', elided + ' unchanged lines'));
  return box;
}

/** The files an entry changed: a line a file, its lines changed, and the diff folded under it. */
function renderChanges(parent, i) {
  const changes = entries[i].changes;
  if (!changes || !changes.count) return;
  section(parent, entries[i].e.k === 'external' ? 'Left in the grader’s checkout' : 'Files changed',
    changes.count + (changes.count === 1 ? ' path' : ' paths'));
  for (const change of changes.changes) {
    const sign = el('span', 'sign ' + change.kind, change.kind === 'added' ? '+' : change.kind === 'removed' ? '−' : '~');
    if (change.old === null && change.new === null) {
      const row = el('div', 'file');
      row.append(sign, el('span', 'path', change.path), el('span', 'stat', 'not shown'));
      row.title = 'too large, binary, a directory, or generated';
      parent.append(row);
      continue;
    }
    const lines = lineDiff(change.old || '', change.new || '');
    const plus = lines.filter(l => l[0] === '+').length, minus = lines.filter(l => l[0] === '-').length;
    const file = el('details', 'file');
    const head = el('summary');
    head.append(sign, el('span', 'path', change.path), el('span', 'stat', '+' + plus + ' −' + minus));
    file.append(head);
    file.addEventListener('toggle', () => {
      if (file.open && file.children.length === 1) file.append(foldable(renderDiff(lines), plus + minus + ' changed lines'));
    });
    parent.append(file);
  }
  for (const fold of changes.folded) {
    const row = el('div', 'file');
    row.append(el('span', 'sign', '…'), el('span', 'path', fold.prefix + '/'),
      el('span', 'stat', (fold.added + fold.removed + fold.modified) + ' paths, not listed'));
    parent.append(row);
  }
  if (changes.listed > changes.changes.length)
    parent.append(el('div', 'quiet', (changes.listed - changes.changes.length) + ' more paths, not listed'));
}

/** How the run stands at an entry: its time and its tokens up to there, and its workspace. */
function renderStanding(parent, i) {
  const x = entries[i], u = x.usage || {};
  const parts = ['run time ' + duration(x.run)];
  if (given(u.input)) parts.push(compact(u.input) + ' tokens in' + cached(u));
  if (given(u.output)) parts.push(compact(u.output) + ' tokens out');
  const foot = el('div', 'standing', 'Up to here: ' + parts.join(' · '));
  // The workspace, unless the entry itself is what left it, and says so above.
  const leaves = x.e.k === 'changed' || (x.e.k === 'exec' && !given(x.e.error));
  if (x.ws && !leaves) foot.append(document.createTextNode(' · workspace '), snapshot(x.ws));
  parent.append(foot);
}

function select(i) {
  // An annotation is shown in the logs through its entry, and has no log of its own.
  const anchor = isNote(i) ? entries[i].p : i;
  if (!pathTo(leaf).includes(anchor)) show(deepest[anchor]);
  selected = i;
  location.hash = short(entries[i].h);
  markSelected();
  const x = entries[i];
  const detail = document.getElementById('detail');
  detail.textContent = '';
  const page = el('div', 'page');
  detail.append(page);
  const head = el('div', 'head');
  const name = el('span', 'mono', short(x.h));
  name.title = x.h;
  head.append(icon(i), el('h1', null, titleOf(i)), el('span', 'at', 'position ' + x.pos), name);
  page.append(head, whereOf(i));
  // Where a log ends: how it ends, and the question it waits on. An annotation ends no log.
  if (x.state && !isNote(i)) {
    const note = el('div', 'ends ' + x.state);
    note.append(el('b', null, 'The log ends here'), document.createTextNode(' — ' + (x.next || x.state)));
    if (x.question && x.question.options.length)
      note.append(el('div', 'quiet', x.question.options.map((o, k) => (k + 1) + '. ' + o).join('   ')));
    page.append(note);
  }
  renderEvent(page, i);
  if (x.config) renderConfig(page, x.config);
  renderRequest(page, i);
  renderChanges(page, i);
  renderStanding(page, i);
  detail.scrollTop = 0;
}

/* --- finding ------------------------------------------------------------ */

let hits = [], hitAt = -1, lastQuery = '';

function find(query, step) {
  const found = document.getElementById('found');
  for (const row of rows.values()) row.classList.remove('hit');
  if (!query) { hits = []; hitAt = -1; found.textContent = ''; return; }
  if (query !== lastQuery) {
    const needle = query.toLowerCase();
    hits = [...rows.keys()].filter(i => (short(entries[i].h) + ' ' + summary(i) + ' ' + JSON.stringify(entries[i].e))
      .toLowerCase().includes(needle));
    hitAt = -1;
    lastQuery = query;
  }
  if (!hits.length) { found.textContent = 'none'; return; }
  hitAt = (hitAt + (step || 1) + hits.length) % hits.length;
  const i = hits[hitAt];
  found.textContent = (hitAt + 1) + ' of ' + hits.length;
  select(i);
  rows.get(i).classList.add('hit');
}

const input = document.getElementById('find');
input.oninput = () => find(input.value, 0);
input.onkeydown = event => {
  if (event.key === 'Enter') { event.preventDefault(); find(input.value, event.shiftKey ? -1 : 1); }
};

document.onkeydown = event => {
  if (event.target.tagName === 'INPUT' || selected === null) return;
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  event.preventDefault();
  const shown = [...rows.keys()];
  const next = shown[shown.indexOf(selected) + (event.key === 'ArrowDown' ? 1 : -1)];
  if (next !== undefined) select(next);
};

/* --- start -------------------------------------------------------------- */

if (entries.length) {
  const wanted = entries.findIndex(x => short(x.h) === location.hash.slice(1));
  const start = wanted >= 0 ? wanted : deepest[roots[0]];
  leaf = deepest[isNote(start) ? entries[start].p : start];
  renderBranches();
  renderLog();
  select(start);
}
