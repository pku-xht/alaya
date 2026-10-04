// Runs the engine and prints what the Lean test prints, to compare the two: node check.js
const { graded, next, drive, replyTo, makeWorld, firstRunArrivals, workspace } = require('./engine.js');
// a state is graded by forking: the log up to there, stopped, and the graders follow
const stopped = (log, position) => [...log.slice(0, position), { kind: 'stopped', reason: 'to grade this state' }];

const describe = (e) => {
  const frame = e.frame ? `[${e.frame.join(', ')}]` : '-';
  if (e.kind === 'arrived') return `${frame}  arrived: ${e.notice.kind === 'said' ? 'said ' + e.notice.message : e.notice.kind === 'replied' ? `replied to [${e.notice.to.join(', ')}]: ${JSON.stringify(e.notice.reply)}` : 'changed → ' + e.notice.workspace}`;
  if (e.kind === 'stopped') return `${frame}  stopped: ${e.reason}`;
  if (e.kind === 'heard') return `${frame}  heard [${e.notices.join(', ')}]`;
  if (e.kind === 'opened') return `${frame}  opened: ${e.tool.name} "${e.tool.arguments}"`;
  if (e.kind === 'returned') return `${frame}  returned: ${e.value}`;
  if (e.kind === 'failed') return `${frame}  failed: ${e.error}`;
  if (e.error !== undefined) return `${frame}  ${e.op.kind}: failed: ${e.error}`;
  if (e.op.kind === 'exec') return `${frame}  exec ${e.op.command} → ${e.answer.workspace}`;
  if (e.op.kind === 'external') return `${frame}  external ${e.op.command}, in ${e.op.image} → exit ${e.answer.exit}`;
  if (e.op.kind === 'sample') return `${frame}  sample after "${e.op.request.messages.at(-1).text}"`;
  return `${frame}  ${e.op.kind}`;
};
const outcome = (r) => r.kind === 'done' ? `done: ${r.value}` : r.kind === 'raised' ? `failed: ${r.error}` : r.kind === 'mismatch' ? `mismatch at ${r.position}`
  : r.kind === 'ask' ? `ask [${r.call.frame.join(', ')}] ${r.call.op.kind} ${r.call.op.command ?? ''}` : `${r.kind} [${(r.frame ?? []).join(', ')}]`;
const show = (title, log, result, from = 0) => {
  console.log(title);
  log.forEach((e, i) => { if (i >= from) console.log(`  ${i}  ${describe(e)}`); });
  console.log(`  → ${outcome(result)}, workspace ${workspace(log)}`);
};
const said = (message) => ({ kind: 'arrived', notice: { kind: 'said', message } });
const replay = (log) => outcome(next(graded, log));

const world = makeWorld();
const main = drive(graded, world, [], firstRunArrivals(world));
show('A: the first run', main.log, main.result);

console.log('the states of the run, graded where the workspace is at a new version:');
for (let i = 1; i < 42; i++) {
  if (workspace(main.log.slice(0, i)) !== workspace(main.log.slice(0, i - 1))) {
    console.log(`  at ${i}, workspace ${workspace(main.log.slice(0, i))}: ${outcome(drive(graded, world, stopped(main.log, i)).result)}`);
  }
}
const branch = drive(graded, world, stopped(main.log, 24));
show('the fork stopped at 24:', branch.log, branch.result, 23);
console.log('the agent cannot go on after a stop:', replay([...main.log.slice(0, 24), { kind: 'stopped', reason: 'x' }, ...main.log.slice(24)]));
console.log('a stop once the agent is over:', replay([...main.log.slice(0, 44), { kind: 'stopped', reason: 'x' }]));

const b = drive(graded, world, main.log.slice(0, 18), undefined, 1);
show('B: the model asked again at 18', b.log, b.result, 18);
let refused = '';
try { replyTo(b.log, { kind: 'text', answer: 'maybe' }); } catch (error) { refused = error.message; }
console.log('a reply of another form than asked:', refused);
const unrelated = drive(graded, world, [...b.log, said('hello')]);
console.log('another notice while the question waits:', outcome(unrelated.result));
const replied = drive(graded, world, [...b.log, replyTo(b.log, { kind: 'yes' })]);
show('B, after the reply yes', replied.log, replied.result, b.log.length);
const c = drive(graded, world, [...main.log.slice(0, 35), said('also tag the release')]);
show('C: a notice after 34', c.log, c.result, 35);
const d = drive(graded, world, b.log.slice(0, 22), undefined, 1);
show('D: from B, the model asked again at 22', d.log, d.result, 22);

// a command that fails: the commit of the first run, made to exit with an error
const flaky = drive(graded, world, [...main.log.slice(0, 32), { ...main.log[32], answer: { text: 'nothing to commit', workspace: workspace(main.log.slice(0, 32)), exit: 1 } }]);
show('with a commit that fails the first time:', flaky.log.slice(0, 39), flaky.result, 31);
console.log(`  and the run ends, after ${flaky.log.length} events`);
// a model that fails to answer: the conversation asks again
const overloaded = { kind: 'answered', frame: main.log[18].frame, op: main.log[18].op, error: 'overloaded' };
const once = drive(graded, world, [...main.log.slice(0, 18), overloaded]);
show('with a model that fails to answer once:', once.log.slice(0, 21), once.result, 17);
console.log(`  and the run ends, after ${once.log.length} events`);
const thrice = next(graded, [...main.log.slice(0, 18), overloaded, overloaded, overloaded]);
console.log('after three failures:', outcome(thrice), thrice.kind === 'failed' ? thrice.error : '');
console.log('after a crash at 24:', replay(main.log.slice(0, 24)));
console.log('with no workspace yet:', replay([]));
console.log('a log with no root:', replay(main.log.slice(1)));
const without = (i) => [...main.log.slice(0, i), ...main.log.slice(i + 1)];
console.log('an answer removed:', replay(without(18)));
console.log('an answer left over:', replay([...main.log, ...main.log.slice(45)]));
console.log('an opening removed:', replay(without(5)));
console.log('a reply removed:', replay(without(6)));
console.log('a return removed:', replay(without(8)));
console.log('a read not marked:', replay(without(35)));
console.log('a notice put in before a read:', replay([...main.log.slice(0, 35), said('stop'), ...main.log.slice(35)]));
