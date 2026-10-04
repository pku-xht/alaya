/-- The version of the workspace the log has reached. A command leaves a version, and so does
a change from outside (the time-stamped handles of Thiemann 2002); the first is that of the
root. An external program works on a checkout of its own, which is not the run's workspace. Without the versions a command would depend on something the log does not track (Mokhov,
Mitchell and Peyton Jones 2018). -/
def workspace (log : List (Event Agent)) : Snapshot :=
  log.foldl (init := "") fun version event =>
    match event with
    | .answered ⟨_, .exec _⟩ (.ok output) => output.workspace
    | .arrived (.changed workspace _) => workspace
    | _ => version

/-- A person's reply to the question a log waits on, as the event to append. It is refused when
no question waits, or when the reply is not of the form the question asks for: the question is
read off the opening of the call that asked. -/
def reply (log : List (Event Agent)) (answer : Reply) : Except String (Event Agent) := do
  let bracket := log.reverse.find? fun
    | .opened .. | .returned .. | .failed .. | .stopped _ => true
    | _ => false
  match bracket with
  | some (.opened frame ⟨"ask_user", arguments⟩) =>
    if (← Question.parse arguments).accepts answer then pure (.arrived (.replied frame answer))
    else throw "the reply is not of the form the question asks for"
  | _ => throw "no question waits for a reply"

/-- The world outside the program. A real one is a model, an executor, a clock and people; the
test scripts one. A model may fail to answer, and what it does can change with time, for which
the log stands. -/
structure World where
  model : List (Event Agent) → Request → Except String Response
  execute : Snapshot → String → Output            -- runs a command on a version of the workspace
  /-- Runs an external program, in its image, on a checkout of a version of the workspace. -/
  external : Snapshot → String → String → ExternalOutput
  clock : Nat × Option Nat
  arrivals : List (Event Agent) → List Notice     -- what has happened, unasked, since the log

/-- Carries out an operation: the handler (Plotkin and Pretnar 2009). A command runs on the
version the log has reached, which the executor restores if the workspace is at another; so a
command that is run again after a crash starts from the same workspace. No more than that is
promised: a command happens at least once, and an effect of it beyond the workspace may happen
twice (Zhang et al. 2020; Burckhardt et al. 2021). The answer is an error when the world could
not give one. A driver may well try again by itself first, which leaves nothing in the log; an
error it gives up on is logged as the answer, and it is then for the program to deal with. -/
def World.answer (world : World) (log : List (Event Agent)) :
    (op : Op) → Except String op.Answer
  | .sample request => world.model log request
  | .exec command => .ok (world.execute (workspace log) command)
  | .time => .ok world.clock
  | .external command image _ _ => .ok (world.external (workspace log) image command)

/-- The driver. "Execution is an external operation rather than a constant within type theory"
(Hancock and Setzer 2000), so this is the one definition that need not terminate. Whatever has
happened unasked is logged first, the root before all. Then the call the log has no answer to
is carried out and its answer logged; or a mark is logged, of a read of the inbox or of a call
that opens or ends. When the program waits for a notice and none has arrived, the driver stops:
there is nothing to do, and this same loop resumes the run once the log holds one. Resuming
after a crash is no different: a call that was being carried out is asked for again. -/
partial def drive (world : World) (run : Run Agent) (log : List (Event Agent)) :
    List (Event Agent) × Next Agent Json :=
  let log := log ++ (world.arrivals log).map .arrived
  match next run log with
  | .ask call => drive world run (log ++ [.answered call (world.answer log call.op)])
  | .hears frame notices => drive world run (log ++ [.heard frame notices])
  | .opens frame tool => drive world run (log ++ [.opened frame tool])
  | .returns frame value => drive world run (log ++ [.returned frame value])
  | .fails frame error => drive world run (log ++ [.failed frame error])
  | result => (log, result)
