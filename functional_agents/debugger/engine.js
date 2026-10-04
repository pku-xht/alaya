// A JavaScript rendering of the Lean sketch: programs, replay, the driver and a scripted world.
// A program is a generator; what it yields is what the interpreter handles.

// ---- programs ----
function* perform(op) { return yield { perform: op }; }
function* inbox() { return yield { inbox: true }; }
// A read that waits is for some notices only, which `accepts` says, given the frame the read
// is made in. It is made once one of them has arrived, and takes those and no other.
function* awaitNotice(accepts) { return yield { inbox: true, wait: accepts }; }
// A program fails by throwing a Failure: it gives up what it was doing, up to whoever catches it.
class Failure extends Error {}

// Calls a tool, by its name alone: the interpreter looks the name up among the tools of the
// run and hands back its body, which then runs in a frame of its own. A program holds no body,
// so it cannot run a tool otherwise, and the opening the log holds is the call itself. A call
// ends with a return or with a failure, and the log marks which; its failure is its caller's
// too, unless the caller catches it.
function* call(name, args) {
  const body = yield { enter: { name, arguments: args } };
  let result;
  try {
    if (!body) throw new Failure(`no tool named ${name}`);
    result = yield* body(args);
  } catch (error) {
    if (!(error instanceof Failure)) throw error;
    yield { leave: true, error: error.message };
    throw error;
  }
  yield { leave: true, value: result };
  return result;
}

// Tries a program again while it fails, up to `attempts` times more. Every try is in the log.
function* retry(attempts, make) {
  for (;;) {
    try {
      return yield* make();
    } catch (error) {
      if (!(error instanceof Failure) || attempts-- === 0) throw error;
    }
  }
}

// ---- questions and replies ----
// What a person is asked: `yes_no: …`, `choice: … | first | second`, or the question alone,
// for an answer in their own words.
function parseQuestion(args) {
  if (args.startsWith('yes_no: ')) return { text: args.slice(8), form: 'yes_no' };
  if (args.startsWith('choice: ')) {
    const [text, ...options] = args.slice(8).split(' | ');
    if (options.length < 2) throw new Failure('a choice needs at least two options');
    return { text, form: 'choice', options };
  }
  return { text: args, form: 'open' };
}
// Whether a reply is one the question's form asks for. That a person cannot answer fits any.
const accepts = (question, reply) =>
  reply.kind === 'unavailable' ? true
    : reply.kind === 'yes' || reply.kind === 'no' ? question.form === 'yes_no'
    : reply.kind === 'none' ? question.form === 'choice'
    : reply.kind === 'option' ? question.form === 'choice' && reply.number >= 1 && reply.number <= question.options.length
    : question.form === 'open' && reply.answer !== '';
// A reply as the tool that asked gives it to its model.
const renderReply = (reply) =>
  ({ yes: 'yes', no: 'no', none: 'none_of_above', unavailable: 'unavailable' })[reply.kind] ??
    (reply.kind === 'option' ? String(reply.number) : reply.answer);

// A person's reply to the question a log waits on, as the event to append. It is refused when
// no question waits, or when the reply is not of the form asked: the question is read off the
// opening of the call that asked.
function replyTo(log, answer) {
  const bracket = log.findLast((event) => ['opened', 'returned', 'failed', 'stopped'].includes(event.kind));
  if (bracket?.kind !== 'opened' || bracket.tool.name !== 'ask_user') throw new Error('no question waits for a reply');
  if (!accepts(parseQuestion(bracket.tool.arguments), answer)) throw new Error('the reply is not of the form the question asks for');
  return { kind: 'arrived', notice: { kind: 'replied', to: bracket.frame, reply: answer } };
}

const noticeSays = (notice) =>
  notice.kind === 'said' ? notice.message
    : notice.kind === 'replied' ? renderReply(notice.reply)
    : `The workspace was changed: ${notice.summary}`;
const said = (notices) => notices.map((notice) => ({ role: 'user', text: noticeSays(notice) }));

// A conversation offers its model some of the tools of the run, by name, and calls no other.
// A model that fails to answer is asked again, as often as the agent's settings say. A tool
// that fails does not fail the conversation: the model is told of the error. A conversation
// that listens reads the inbox at the end of each round, for the model to hear of it in the
// next.
function* converse(agent, model, dialogue, listen = false) {
  for (;;) {
    const request = { model, messages: dialogue, tools: agent.tools };
    const response = yield* retry(agent.retries, () => perform({ kind: 'sample', request }));
    if (response.toolCalls.length === 0) return response.text;
    const results = [];
    for (const asked of response.toolCalls) {
      let text = `error: ${asked.name} is not a tool of this conversation`;
      try {
        if (agent.tools.includes(asked.name)) text = yield* call(asked.name, asked.arguments);
      } catch (error) {
        if (!(error instanceof Failure)) throw error;
        text = `error: ${error.message}`;
      }
      results.push({ role: 'tool', text });
    }
    const heard = listen ? yield* inbox() : [];
    dialogue = [...dialogue, { role: 'assistant', text: response.text, calls: response.toolCalls }, ...results, ...said(heard)];
  }
}

// The tools of a run, by name, for an agent with a configuration: its system message, its
// settings, and those of its model.
const toolsOf = (config) => ({
  // Runs a command. A command that exits with an error is a failure of the tool.
  *bash(command) {
    const output = yield* perform({ kind: 'exec', command });
    if (output.exit !== 0) throw new Failure(`exit ${output.exit}: ${output.text}`);
    return output.text;
  },
  *time_budget() {
    const { spent, budget } = yield* perform({ kind: 'time' });
    return budget == null ? 'no limit' : `${Math.floor((budget - spent) / 1000)} s left`;
  },
  // Asks a person. The question is the argument, so the opening of the call puts it in the
  // log, with the form its answer is to have. The tool then waits for a reply to this call,
  // of that form; no other notice ends the wait or is taken for the answer.
  *ask_user(args) {
    const question = parseQuestion(args);
    const replies = yield* awaitNotice((frame, notice) =>
      notice.kind === 'replied' && same(notice.to, frame) && accepts(question, notice.reply));
    return replies.map(noticeSays).join('\n');
  },
  // A sub-agent: a conversation of its own, with the model of the agent that started the run.
  delegate: (task) => converse({ tools: ['bash', 'time_budget'], retries: 2 }, config.model,
    [{ role: 'system', text: 'You are a sub-agent.' }, { role: 'user', text: task }]),
  // A tool that calls tools: a sub-agent runs the tests, and then two commands commit the work.
  *commit(message) {
    const report = yield* call('delegate', 'run the tests');
    yield* call('bash', 'git add');
    yield* call('bash', `git commit -m ${message}`);
    return report;
  },
  // The agent is called with its configuration, which the log so holds from the start. It
  // cannot start without a task, so it first waits for one: a notice, like all that a person
  // says.
  *agent(called) {
    const { system, agent, model } = JSON.parse(called);
    const task = yield* awaitNotice((_, notice) => notice.kind === 'said');
    return yield* converse(agent, model, [{ role: 'system', text: system }, ...said(task)], true);
  },
  // A grader, which no conversation offers to a model, and which needs nothing of its own: it
  // is an external program and a reading of what it prints. This one runs tests the agent
  // never sees, in an image of its own, on a checkout of the workspace as the agent left it.
  *hidden_tests() {
    const ran = yield* perform({ kind: 'external', command: 'pytest /grader', image: 'grader@sha256:9f2c', input: 'hidden', timeout: 900 });
    return verdict(ran.stdout);
  },
});

// ---- content addresses ----
// A digest of a text, as sixteen hex digits. It stands in here for a cryptographic hash: it is
// quick and synchronous, and not collision resistant.
function digest(text) {
  let a = 0xdeadbeef, b = 0x41c6ce57;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    a = Math.imul(a ^ code, 2654435761);
    b = Math.imul(b ^ code, 1597334677);
  }
  a = Math.imul(a ^ (a >>> 16), 2246822507) ^ Math.imul(b ^ (b >>> 13), 3266489909);
  b = Math.imul(b ^ (b >>> 16), 2246822507) ^ Math.imul(a ^ (a >>> 13), 3266489909);
  return (b >>> 0).toString(16).padStart(8, '0') + (a >>> 0).toString(16).padStart(8, '0');
}

// An entry of a log is addressed by its content: the event, and the entry before it.
const entryHash = (parent, event) => digest(`${parent}\n${JSON.stringify(event)}`);

// A version of the workspace is addressed by its content too. Here that is what made it: the
// command, and the version it ran on.
const versionHash = (before, command) => digest(`${before}\n${command}`).slice(0, 12);

// ---- replay ----
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const frameKey = (frame) => frame.join('.');

// A run, as the driver sees it: the pure function from the log to what to do next. A run is
// the agent, in the frame [0], opened with its call, and then what follows it, in the frame [].
// What follows is given
// what the agent returned, or the error when it failed or was stopped from outside. A stop ends
// every frame of the agent, whatever the nesting, and nothing in the agent can catch it, where
// a failure is caught by the scope it happens in.
const STOPPED = { kind: 'stopped' };

function next(run, log) {
  // A run starts from a root: the first entry of its log is a change from outside, the
  // workspace that someone provides. Without it the run waits. No read of the inbox takes it.
  if (log.length === 0) return { kind: 'waits', frame: [] };
  if (log[0].kind !== 'arrived' || log[0].notice.kind !== 'changed') return { kind: 'mismatch', position: 0 };
  let frame = [];
  let opened = [0];
  let position = 1;
  let unread = [];
  const pass = () => {
    for (; position < log.length && log[position].kind === 'arrived'; position++) unread.push({ at: position, notice: log[position].notice });
  };
  const stopHere = () => log[position]?.kind === 'stopped' && (position += 1, true);
  // A mark says what the program did, with nothing in it for the program to learn: a read of
  // the inbox, a scope opened, a return. Replay knows what it must be and checks the logged one.
  const mark = (expected) => {
    pass();
    if (position >= log.length) return expected;
    if (stopHere()) return STOPPED;
    if (!same(log[position], expected)) return { kind: 'mismatch', position };
    position += 1;
    return null;
  };
  // Runs a program against the log: gives its value or its failure, or what stops replay.
  const play = (program) => {
    let input;
    let failure = null;
    for (;;) {
      let step;
      try {
        // an operation the world could not answer fails where it was performed
        step = failure ? program.throw(failure) : program.next(input);
        failure = null;
      } catch (error) {
        if (!(error instanceof Failure)) throw error;
        return { failure: error.message };
      }
      const { value, done } = step;
      input = undefined;
      if (done) return { value };
      let stop = null;
      if (value.enter) {
        frame.push(opened[opened.length - 1]++);
        opened.push(0);
        stop = mark({ kind: 'opened', frame: [...frame], tool: value.enter });
        input = run.tools[value.enter.name];
      } else if (value.leave) {
        stop = mark(value.error === undefined
          ? { kind: 'returned', frame: [...frame], value: value.value }
          : { kind: 'failed', frame: [...frame], error: value.error });
        frame.pop();
        opened.pop();
      } else if (value.inbox) {
        // What the read takes, and what it leaves unread: a read that waits takes those of the
        // notices just arrived that it is for; any other takes all that is unread, replies
        // apart. The mark holds the positions of what it took.
        const older = unread;
        unread = [];
        pass();
        const mine = (one) => (value.wait ? value.wait(frame, one.notice) : one.notice.kind !== 'replied');
        const candidates = value.wait ? unread : [...older, ...unread];
        const taken = candidates.filter(mine);
        unread = [...(value.wait ? older : []), ...candidates.filter((one) => !mine(one))];
        if (value.wait && taken.length === 0) {
          if (position >= log.length) return { stop: { kind: 'waits', frame: [...frame] } };
          return { stop: stopHere() ? STOPPED : { kind: 'mismatch', position } };
        }
        stop = mark({ kind: 'heard', frame: [...frame], notices: taken.map((one) => one.at) });
        input = taken.map((one) => one.notice);
      } else {
        pass();
        const call = { frame: [...frame], op: value.perform };
        if (position >= log.length) return { stop: { kind: 'ask', call } };
        if (stopHere()) return { stop: STOPPED };
        const event = log[position];
        if (event.kind !== 'answered' || !same(event.frame, call.frame) || !same(event.op, call.op)) return { stop: { kind: 'mismatch', position } };
        if (event.error === undefined) input = event.answer;
        else failure = new Failure(event.error);
        position += 1;
      }
      if (stop) return { stop };
    }
  };

  // How a frame ended: the mark of its return or of its failure.
  const close = (at, body) => body.stop ?? mark(body.failure === undefined
    ? { kind: 'returned', frame: at, value: body.value }
    : { kind: 'failed', frame: at, error: body.failure });
  const outcome = (body) => (body.failure === undefined ? { ok: body.value } : { error: body.failure });

  // the agent, in the frame [0]
  let result = { error: 'stopped' };
  let ended = mark({ kind: 'opened', frame: [0], tool: run.call });
  if (!ended) {
    frame = [0];
    opened = [1, 0];
    const body = run.tools[run.call.name];
    const agent = body ? play(body(run.call.arguments)) : { failure: `no tool named ${run.call.name}` };
    ended = close([0], agent);
    if (!ended) result = outcome(agent);
  }
  if (ended && ended !== STOPPED) return ended;
  // what follows it, in the frame []
  frame = [];
  opened = [1];
  const after = play(run.after(result));
  const closed = close([], after);
  if (closed === STOPPED) return { kind: 'mismatch', position: position - 1 };
  if (closed) return closed;
  pass();
  if (position < log.length) return { kind: 'mismatch', position };
  return after.failure === undefined ? { kind: 'done', value: after.value } : { kind: 'raised', error: after.failure };
}

// ---- the world ----
function workspace(log) {
  let version = '';
  for (const event of log) {
    if (event.kind === 'answered' && event.op.kind === 'exec' && event.answer) version = event.answer.workspace;
    if (event.kind === 'arrived' && event.notice.kind === 'changed') version = event.notice.workspace;
  }
  return version;
}

const calls = (...pairs) => ({ text: '', toolCalls: pairs.map(([name, args]) => ({ name, arguments: args })) });
const says = (text) => ({ text, toolCalls: [] });

// A scripted model: what it answers depends on what it is shown. Asking again takes the next
// of its answers.
function modelAnswers(request) {
  const messages = request.messages;
  const last = messages[messages.length - 1];
  if (messages[0].text.includes('sub-agent')) {
    if (last.role === 'user') return [calls(['time_budget', ''], ['bash', 'pytest']), calls(['bash', 'pytest -x']), says('I could not run the tests')];
    if (last.text.includes('pytest -x')) return [says('2 tests fail'), says('48 tests pass on a second run')];
    return [says('48 tests pass'), says('2 tests fail'), says('47 tests pass, 1 is skipped')];
  }
  // a tool the agent called has just failed: it calls commit again
  const since = messages.slice(messages.findLastIndex((message) => message.role === 'assistant') + 1);
  const failure = since.find((message) => message.role === 'tool' && message.text.startsWith('error:'));
  if (failure) return [calls(['commit', 'fix']), says(`done, though a tool failed with "${failure.text}"`)];
  if (last.role === 'user') {
    if (!messages.some((message) => message.role === 'assistant')) return [calls(['ask_user', 'Which target?']), calls(['bash', 'make']), says('nothing to do')];
    if (last.text.startsWith('The workspace was changed')) return [calls(['bash', 'git diff']), says('done')];
    if (last.text.includes('tag')) return [calls(['bash', 'git tag v1.1']), says(`done, without doing "${last.text}"`)];
    return [says(`done, and noted "${last.text}"`), calls(['bash', 'git status'])];
  }
  // a reply to a question the agent asked
  const asked = messages.findLast((message) => message.role === 'assistant').calls.find((call) => call.name === 'ask_user');
  if (asked && asked.arguments.startsWith('Which target')) {
    return [calls(['bash', last.text.includes('default') ? 'make' : `make ${last.text}`]), says('done, with nothing built')];
  }
  if (asked) return /^y/i.test(last.text) ? [calls(['bash', 'git revert HEAD'])] : [says('done, and the commit stays')];
  if (last.text === 'output of make test') return [calls(['commit', 'fix']), says('done, not committed')];
  if (last.text.startsWith('output of make')) return [calls(['commit', 'fix']), calls(['bash', 'make test']), says('done, not committed')];
  if (last.text.includes('fail')) return [calls(['ask_user', 'yes_no: Tests fail. Revert the commit?']), calls(['bash', 'git revert HEAD']), says('done, though tests fail')];
  if (last.text.includes('tests pass')) return [says('done'), calls(['bash', 'git log'])];
  return [says('done'), says('done, with nothing more to do')];
}

function makeWorld() {
  // A version of the workspace is the command that made it, on the version before.
  const made = new Map();
  const fresh = (before, command) => {
    const version = versionHash(before, command);
    made.set(version, { before, command });
    return version;
  };
  // The tests the agent does not see, run on a version: they pass in part once the build is
  // made, and in full once a fix whose tests passed is committed.
  const passing = (version) => {
    const commands = [];
    for (let at = made.get(version); at; at = made.get(at.before)) commands.unshift(at.command);
    let passed = 0;
    for (const command of commands) {
      if (command.startsWith('make')) passed = Math.max(passed, 12);
      if (command.startsWith('git commit')) passed = commands.includes('pytest -x') ? 46 : 48;
      if (command.startsWith('git revert')) passed = 12;
    }
    return passed;
  };
  return {
    fresh,
    passing,
    answer(log, op, variant) {
      if (op.kind === 'sample') {
        const answers = modelAnswers(op.request);
        return answers[variant] ?? says(`another answer (${variant + 1})`);
      }
      if (op.kind === 'exec') {
        const reads = /^git (diff|log|status)/.test(op.command);
        const before = workspace(log);
        return { text: `output of ${op.command}`, workspace: reads ? before : fresh(before, op.command), exit: 0 };
      }
      if (op.kind === 'external') {
        // An external program runs in a fresh container of its image, on a checkout of the
        // workspace: the checkout it leaves is in its answer, and the run's workspace stays.
        const before = workspace(log);
        const ok = { 0: 0, 12: 1, 46: 3, 48: 4 }[passing(before)];
        const checks = ['builds', 'parses', 'evaluates', 'reports errors'];
        return {
          exit: ok === 4 ? 0 : 1,
          stdout: checks.map((name, i) => `${i < ok ? 'ok' : 'not ok'} ${i + 1} - ${name}`).join('\n'),
          checkout: versionHash(before, op.command),
          elapsedMs: 1200,
        };
      }
      return { spent: 412000, budget: 3600000 };
    },
  };
}

// ---- grading ----
// A verdict, read off what a grader prints: how many of its checks passed, of how many, in the
// Test Anything Protocol's lines `ok` and `not ok`.
function verdict(stdout) {
  const lines = stdout.split('\n');
  const passed = lines.filter((line) => line.startsWith('ok ')).length;
  const failed = lines.filter((line) => line.startsWith('not ok ')).length;
  return `${failed === 0 ? 'pass' : 'fail'} ${passed}/${passed + failed}`;
}

// What follows the agent in a run: the graders. What they return is the result of the run. The
// agent is over when they start, so whatever they do, the agent cannot see it. To grade a state
// a run went through is no other thing: the log is forked there and stopped, and the graders
// follow.
const grading = () => call('hidden_tests', '');

// A run: its tools, the call of the agent among them with its configuration, and the graders.
const config = {
  system: 'You are a coding agent.',
  agent: { tools: ['bash', 'time_budget', 'commit', 'ask_user'], retries: 2 },
  model: { name: 'a-model', maxTokens: 4096 },
};
const graded = { tools: toolsOf(config), call: { name: 'agent', arguments: JSON.stringify(config) }, after: grading };

// The driver: log what has arrived, then carry out the call and log its answer, or log a
// mark: a read of the inbox, a scope opened, a return or a failure. When the program waits for a notice and
// none has arrived, the driver stops: the run waits. `variant` picks the answer
// to the first call only, which is how a fork asks the model again.
function drive(program, world, log, arrivals = () => [], variant = 0) {
  log = [...log];
  for (let turn = 0; turn < 80; turn++) {
    for (const notice of arrivals(log)) log.push({ kind: 'arrived', notice });
    const result = next(program, log);
    if (['heard', 'opened', 'returned', 'failed'].includes(result.kind)) { log.push(result); continue; }
    if (result.kind !== 'ask') return { log, result };
    const { frame, op } = result.call;
    log.push({ kind: 'answered', frame, op, answer: world.answer(log, op, variant) });
    variant = 0;
  }
  return { log, result: next(program, log) };
}

// What a person does in the first run: provides the workspace, which is the root of the run,
// gives the task once the agent is there, replies to the first question, and
// later edits a file.
const firstRunArrivals = (world) => (log) => {
  const last = log[log.length - 1];
  if (log.length === 0) return [{ kind: 'changed', workspace: world.fresh('', 'the repository'), summary: 'the repository' }];
  if (log.length === 2) return [{ kind: 'said', message: 'the task' }];
  if (last?.kind === 'opened' && last.tool.arguments === 'Which target?') return [replyTo(log, { kind: 'text', answer: 'the default one' }).notice];
  if (log.length === 22) return [{ kind: 'changed', workspace: world.fresh(workspace(log), 'edit README'), summary: 'a person edited README' }];
  return [];
};

if (typeof module !== 'undefined') {
  module.exports = { graded, next, drive, replyTo, makeWorld, firstRunArrivals, workspace, frameKey, same, digest, entryHash };
}
