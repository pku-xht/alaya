/-- What an agent may ask for. -/
inductive Op where
  | sample (request : Request)       -- answered by the model, which may fail to
  | exec (command : String)          -- answered by the executor; changes the workspace
  | time                             -- answered by the clock
  /-- An external program, opaque to the run: `command` in a fresh container of `image`, with
  no network, on a checkout of the workspace, and with `input`, files that are not in the
  workspace, mounted to read. The checkout it leaves is in its answer; the workspace of the
  run stays where it is. -/
  | external (command image : String) (input : Option Snapshot) (timeout : Nat)
  deriving DecidableEq

def Op.Answer : Op → Type
  | .sample _ => Response
  | .exec _ => Output
  | .time => Nat × Option Nat
  | .external .. => ExternalOutput

abbrev Agent : Signature := ⟨Op, Op.Answer⟩

/-- The generic effect of an operation (Plotkin and Power 2003): perform it and return. An
operation the world could not answer fails, where it was performed. -/
def perform (op : Op) : Program Agent op.Answer :=
  .perform op fun | .ok answer => .pure answer | .error error => .fail error

/-- A tool is a program from a call's arguments to its result, under a name. Programs call a
tool by its name alone, so it always runs in a frame of its own. -/
structure Tool where
  name : String
  run : Json → Program Agent Json

/-- Runs a command. A command that exits with an error is a failure of the tool. -/
def bash : Tool where
  name := "bash"
  run command := do
    let output ← perform (.exec command)
    if output.exit != 0 then throw s!"exit {output.exit}: {output.text}"
    return output.text

def timeBudget : Tool where
  name := "time_budget"
  run _ := do
    let (spent, budget?) ← perform .time
    return match budget? with
      | some budget => s!"{(budget - spent) / 1000} s left"
      | none => "no limit"

/-- What a notice says. -/
def Notice.text : Notice → String
  | .said message => message
  | .changed _ summary => s!"The workspace was changed: {summary}"
  | .replied _ reply => reply.render

/-- Asks a person. The question is the argument, so the opening of the call puts it in the
log, with the form its answer is to have. The tool then waits for a reply to this call, of
that form: it is logged when the person gives it, and no other notice ends the wait or is
taken for the answer. So the run stops at a question as a script of Thiemann (2002) stops at a
form until the user responds. -/
def askUser : Tool where
  name := "ask_user"
  run arguments := do
    let question ← match Question.parse arguments with
      | .ok question => pure question
      | .error problem => throw problem
    let replies ← await fun frame notice =>
      match notice with
      | .replied to reply => to == frame && question.accepts reply
      | _ => false
    return "\n".intercalate (replies.map (·.text))

/-- One round of a conversation with the model: sample, and call each tool the response asks
for, by its name. The conversation offers its model some of the tools of the run, and calls no
other. A model that fails to answer is asked again, as often as the agent's settings say. A
tool that fails does not fail the conversation: the model is told of the error, as the result
of its call. The round gives the longer dialogue, or the answer when a response makes no
calls. A conversation that listens reads the inbox at the end of each round, for the model to
hear of it in the next. -/
def round (agent : AgentConfig) (model : ModelConfig) (listen : Bool) (dialogue : Dialogue) :
    Program Agent (Dialogue ⊕ String) := do
  let request := { model, messages := dialogue, tools := agent.tools }
  let response ← retry agent.retries (perform (.sample request))
  if response.toolCalls.isEmpty then return .inr response.text
  let mut results := []
  for asked in response.toolCalls do
    let result ←
      if agent.tools.contains asked.name then
        try call asked.name asked.arguments catch error => pure s!"error: {error}"
      else pure s!"error: {asked.name} is not a tool of this conversation"
    results := results ++ [.tool result]
  let heard ← if listen then inbox else pure []
  return .inl (dialogue ++ [.assistant response.text response.toolCalls] ++ results
    ++ heard.map (.user ·.text))

/-- A conversation is a loop of rounds whose state is the dialogue. Every round samples, so
the loop is guarded. A model's answers are the random choices of this program, and a log is
one trace of it (Dohan et al. 2022). -/
def converse (agent : AgentConfig) (model : ModelConfig) (dialogue : Dialogue)
    (listen := false) : Program Agent String :=
  iter (round agent model listen) dialogue

/-- A sub-agent is a tool whose program is a conversation of its own, with the model of the
agent that started the run. Its samples and its tools' frames nest inside the call's frame;
the outer model sees only what it returns. -/
def delegate (model : ModelConfig) : Tool where
  name := "delegate"
  run task := converse { tools := ["bash", "time_budget"], retries := 2 } model
    [.system "You are a sub-agent.", .user task]

/-- A tool that calls tools: a sub-agent runs the tests, and then two commands commit the work.
Each of the three calls opens a frame in this tool's frame, so frames nest as the calls do. -/
def commit : Tool where
  name := "commit"
  run message := do
    let report ← call "delegate" "run the tests"
    let _ ← call "bash" "git add"
    let _ ← call "bash" s!"git commit -m {message}"
    return report

/-- The agent is the outermost tool. It is called with its configuration: its system message,
its settings, and those of its model. It cannot start without a task, so it first waits for
one: a notice, like all that a person says. It is the only conversation that listens. What it
returns is its submission. The stub keeps the configuration it is built from, where a real
agent would read it from its call. -/
def agent (config : Config) : Tool where
  name := "agent"
  run _ := do
    let task ← await fun _ notice => notice matches .said _
    converse config.agent config.model ([.system config.system] ++ task.map (.user ·.text))
      (listen := true)

/-- The tools of a run, by name, from a list of them. -/
def table (tools : List Tool) : Tools Agent :=
  fun name => (tools.find? (·.name == name)).map (·.run)
