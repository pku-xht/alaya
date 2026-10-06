import Test.Framework
import Test.Scripted
import Test.Container
import Alaya

/-! Runs as logs of entries: what `new` writes, what the driver appends, how a run goes on after
a pause or a crash, how a point is run again as a fork with a new draw, what a person appends —
a message, an edit, a stop — and how a reader sees it all, the HTML report's requests included.
The model is scripted, the workspaces are directory copies, and commands that write files run
in the test container. -/

namespace RunsTests

open Testing Alaya Scripted
open Lean (Json)

/-- An executor that answers every command with `output`, and runs nothing. -/
private def echoing (output : String := "ok") : Executor :=
  { exec := fun _ _ _ _ => pure { output, exitCode? := some 0 } }

/-- A model that fails `failures` times, as a provider that cannot be reached does, then answers
`responses` in order. -/
private def unreachable (failures : Nat) (responses : Array Chat.Response) : IO Model := do
  let index ← IO.mkRef 0
  let failed ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "unreachable")]
    sample := fun _ => pure { next := do
      if (← Result.fromIO Error.cache failed.get) < failures then
        Result.fromIO Error.cache (failed.modify (· + 1))
        throw <| .transport "connection refused"
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match responses[i]? with
      | some response => pure response
      | none => throw <| .protocol "scripted model exhausted" } }

/-- A model whose every response fails with `error`. -/
private def failing (error : Error) : Model :=
  { identity := .mkObj [("model", "failing")], sample := fun _ => pure { next := throw error } }

/-- An executor that keeps files and runs nothing: `write PATH TEXT` writes a file of the work
directory, `rm PATH` removes one, `leak` drops a file among the outputs, and anything else lists
the work directory and the outputs. -/
private def filing (outputs : System.FilePath) : Executor :=
  let done : Output := { output := "", exitCode? := some 0 }
  let names (dir : System.FilePath) : IO String := do
    if !(← dir.isDir) then return ""
    pure (" ".intercalate ((← dir.readDir).map (·.fileName) |>.qsort (· < ·)).toList)
  { exec := fun _ workDir argv _ => do
      match (argv[0]?.getD "").splitOn " " with
      | ["write", path, text] =>
        let file := workDir / (path : System.FilePath)
        IO.FS.createDirAll (file.parent.getD workDir)
        IO.FS.writeFile file (text ++ "\n")
        pure done
      | ["rm", path] =>
        IO.FS.removeFile (workDir / (path : System.FilePath))
        pure done
      | ["leak"] =>
        IO.FS.createDirAll outputs
        IO.FS.writeFile (outputs / "leak.txt") "x"
        pure done
      | _ => pure { done with output := s!"work: {← names workDir}; outputs: {← names outputs}" } }

/-- A runtime whose commands are `filing`'s, over a store and workspaces of the test's own. -/
private def filingRuntime (model : Model) : TestM Driver.Runtime := do
  let rt ← runtime (echoing) (some model)
  pure { rt with executor := fun _ => pure (answeringUname (filing rt.outputsDir)) }

/-- What the command `command` printed, in a log. -/
private def printed (log : Log Agent) (command : String) : Option String :=
  log.findSome? fun
    | .answered _ (.exec ran _) (.ok (.execution e)) => if ran == command then some e.output.output else none
    | _ => none

/-- A run whose agent comments on what it does: before a command, and on what it printed. -/
private def commenting : Routine Agent :=
  runOf fun _ => do
    comment "before the command"
    let ran ← exec "echo one"
    comment s!"it printed {ran.output.output}"
    return "done"

/-- The comments of a log, in order. -/
private def comments (log : Log Agent) : Array String :=
  log.filterMap fun | .commented text => some text | _ => none

/-- A log as lines, the names of snapshots left out: two runs take snapshots of their own. -/
private def describe (log : Log Agent) : Array String := log.map fun
  | .answered frame key (.ok (.execution e)) =>
    Render.eventSummary (.answered frame key (.ok (.execution { e with workspace := default })))
  | .arrived (.changed _ summary) => Render.eventSummary (.arrived (.changed default summary))
  | event => Render.eventSummary event

/-- Runs `k` with MiniSwe's run, configured by `config`. -/
private def withMini (config : Agents.MiniSwe.Config := {}) (k : Routine Agent → TestM Unit) : TestM Unit :=
  match miniRun config with
  | .ok run => k run
  | .error problem => fail problem

private def script : Array Chat.Response := #[
  responseWith #[call "c1" "bash" "echo one"],
  responseWith #[call "c2" "bash" "echo two", call "c3" "bash" "echo three"],
  responseWith #[submitCall "s" "done"]]

def suite : Suite := Testing.suite "runs" #[
  test "new writes the root, and a call of the agent is a notice with its configuration and its task" do
    withMini {} fun run => do
      let rt ← runtime (echoing) none
      let tip ← start rt run "the task"
      let log ← logAt rt tip
      assertEqual "the root and the call" log.size 2
      check (log[0]! matches .arrived (.changed ..)) "the root is the workspace"
      check (log[1]! matches .arrived (.called _)) "the call is a notice"
      match next run log with
      | .hears #[] notices => assertEqual "the run's read takes the call" notices #[1]
      | _ => fail "the run reads its call next"
      let settled := settle run log
      assertEqual "the call opens with its configuration" ((callAt? settled { name := "agent" }).map (·.toJson.compress))
        (some (testArguments "the task").toJson.compress)
      check (settled[3]? matches some (Event.opened ⟪"agent"⟫ _)) "in a frame of its own",

  test "the driver appends an entry an event, and replay agrees with the log at every prefix" do
    withMini {} fun run => do
      let (rt, last, stop) ← drive run (echoing) (← scriptedModel script)
      check (stop matches .idle) "the agent is over"
      let log ← logAt rt last
      assertEqual "the agent's outcome" (agentStatus log) "Submitted"
      -- Wherever the driver went on, replay of the log before says what it then logged.
      for i in [2:log.size] do
        let agrees := match log[i]!, next run (log.extract 0 i) with
          | .answered frame key _, .ask asked => frame == asked.frame && key == asked.op.key
          | .heard frame notices, .hears reader taken => frame == reader && notices == taken
          | .opened frame tool, .opens entered called => frame == entered && tool == called
          | .returned frame value, .returns ended given => frame == ended && value == given
          | .failed frame error, .fails ended given => frame == ended && error == given
          | _, _ => false
        check agrees s!"replay disagrees at {i}: {Render.eventSummary log[i]!}"
      -- Once the agent is over, the run waits for the next call.
      match next run log with
      | .waits #[] none => pure ()
      | _ => fail "the agent is over, and the run waits for a call"
      -- Driven again from its end, a run whose agent is over stays as it is: nothing is appended.
      let count := (← assertOk rt.store.forest).entries.size
      let (again, stop) ← assertOk <| Driver.drive rt run last
      check ((stop matches .idle) && again == last) "the run is still over"
      assertEqual "no entry written" (← assertOk rt.store.forest).entries.size count
      -- Three commands, each in a frame of its own under the agent's, named by its routine and how
      -- many calls of it came before: the agent's uname, a call of another routine, moves none.
      let frames := log.filterMap fun | .opened frame ⟨"bash", _⟩ => some frame | _ => none
      assertEqual "frames" frames #[⟪"agent", "bash"⟫, ⟪"agent", "bash#1"⟫, ⟪"agent", "bash#2"⟫],

  test "the driver reports each entry as it appends it, in order, with its time" do
    withMini {} fun run => do
      let rt ← runtime (echoing) (some (← scriptedModel script))
      let tip ← start rt run
      let seen ← IO.mkRef (#[] : Array (Hash × Nat))
      let (last, _) ← assertOk <| Driver.drive rt run tip {} fun hash entry =>
        Result.fromIO Error.storage (seen.modify (·.push (hash, entry.elapsedMs)))
      let forest ← assertOk rt.store.forest
      let path := forest.path last
      assertEqual "every entry after the start" ((← seen.get).map (·.1)) (path.extract 2 path.size)
      let entries ← assertOk <| rt.store.entries forest last
      assertEqual "each with the time the store keeps" ((← seen.get).map (·.2))
        ((entries.extract 2 entries.size).map (·.elapsedMs)),

  test "a run paused at a limit goes on where it stopped, to the log an uninterrupted run makes" do
    withMini {} fun run => do
      let (whole, wholeEnd, _) ← drive run (echoing) (← scriptedModel script)
      let rt ← runtime (echoing) (some (← scriptedModel script))
      let tip ← start rt run
      let (paused, stop) ← assertOk <| Driver.drive rt run tip { samples? := some 1 }
      match stop with
      | .paused reason => check (contains reason "1 response") reason
      | _ => fail "the run pauses after one sample"
      -- It pauses before the next round's read of the inbox, so a message added there is heard.
      check ((← logAt rt paused).back? matches some (.returned ⟪"agent", "bash"⟫ _)) "paused after the first call ended"
      let (finished, _) ← assertOk <| Driver.drive rt run paused
      assertEqual "the same events" (describe (← logAt rt finished)) (describe (← logAt whole wholeEnd)),

  test "a crash is resumed: the operation is asked for again, and nothing was logged for it" do
    withMini {} fun run => do
      let rt ← runtime (echoing) (some (← unreachable 1 script))
      let tip ← start rt run
      assertError "the provider cannot be reached" (Driver.drive rt run tip) fun
        | .transport _ => true
        | _ => false
      let forest ← assertOk rt.store.forest
      let after := forest.leaves
      assertEqual "one log" after.size 1
      let log ← logAt rt after[0]!
      check (!(log.any fun | .answered _ (.sample ..) _ => true | _ => false)) "no response was logged"
      let (finished, stop) ← assertOk <| Driver.drive rt run after[0]!
      check (stop matches .idle) "the run finishes"
      assertEqual "the run is whole" (agentStatus (← logAt rt finished)) "Submitted",

  test "a failure of the provider that is no refusal for length stops the driver, with nothing logged" do
    withMini {} fun run => do
      for (label, error) in #[("a key it rejects", Error.http 401 "invalid api key"),
          ("a request it rejects", Error.http 400 "temperature must be finite"),
          ("a response it garbles", Error.protocol "no choices"),
          ("a failure of its own", Error.provider "overloaded")] do
        let rt ← runtime (echoing) (some (failing error))
        let tip ← start rt run
        assertError label (Driver.drive rt run tip) fun thrown => thrown.describe == error.describe
        let forest ← assertOk rt.store.forest
        assertEqual s!"{label}: one log" forest.leaves.size 1
        check (!(← logAt rt forest.leaves[0]!).any fun | .answered _ (.sample ..) _ => true | _ => false)
          s!"{label}: a response was logged"
      -- With no provider named, a run that needs a sample says so.
      let rt ← runtime (echoing) none
      assertError "no provider" (Driver.drive rt run (← start rt run)) fun
        | .input message => contains message "--provider"
        | _ => false,

  test "a command that could not be run stops the driver, and the next run asks for it again" do
    withMini {} fun run => do
      let attempts ← IO.mkRef 0
      let flaky : Executor := { exec := fun _ _ _ _ => do
        if (← attempts.modifyGet fun n => (n, n + 1)) == 0 then throw <| IO.userError "the daemon is gone"
        pure { output := "ok", exitCode? := some 0 } }
      let rt ← runtime flaky (some (← scriptedModel script))
      assertError "the command could not be run" (Driver.drive rt run (← start rt run)) fun
        | .environment message => contains message "the daemon is gone"
        | _ => false
      let forest ← assertOk rt.store.forest
      assertEqual "one log" forest.leaves.size 1
      let log ← logAt rt forest.leaves[0]!
      check (log.back? matches some (.opened ⟪"agent", "bash"⟫ _)) "the log ends with the call that asked for the command"
      let (finished, stop) ← assertOk <| Driver.drive rt run forest.leaves[0]!
      check (stop matches .idle) "the run finishes"
      assertEqual "the command ran once in the log" ((← logAt rt finished).filter fun
        | .answered _ (.exec "echo one" _) _ => true
        | _ => false).size 1,

  test "a log lost after its responses were sampled is made again from the cache, the model not asked" do
    withMini {} fun run => do
      -- The scripted model has one response for each request: a second ask would exhaust it.
      let model ← cached (← scriptedModel script)
      let (first, firstEnd, _) ← drive run (echoing) model
      let (second, secondEnd, stop) ← drive run (echoing) model
      check (stop matches .idle) "the run finishes on what the cache kept"
      assertEqual "the same events" (describe (← logAt second secondEnd)) (describe (← logAt first firstEnd)),

  test "a response costs the time its draw took, in every log that holds it" do
    withMini {} fun run => do
      -- A model that takes a while over each response, behind a cache on disk.
      let inner ← scriptedModel script
      let slow : Model := { inner with sample := fun request => do
        let stream ← inner.sample request
        pure (Model.Stream.ofNext do
          Result.fromIO Error.cache (IO.sleep 120)
          stream.next) }
      let directory := (← scratch) / s!"cache-{← IO.monoNanosNow}"
      let sampleTimes (rt : Driver.Runtime) (tip : Hash) : TestM (Array Nat) := do
        let entries ← assertOk <| rt.store.entries (← assertOk rt.store.forest) tip
        pure <| entries.filterMap fun entry => match entry.event with
          | .answered _ (.sample ..) (.ok _) => some entry.elapsedMs
          | _ => none
      let (first, firstEnd, _) ← drive run (echoing) (← assertOk <| Cache.persistent slow { directory })
      let times ← sampleTimes first firstEnd
      check (!times.isEmpty && times.all (· ≥ 120)) s!"each sample took the model's time: {times}"
      -- The log made again from the cache, by a model that has no response to give: no time
      -- passes, and every sample costs what its draw took.
      let (second, secondEnd, stop) ← drive run (echoing)
        (← assertOk <| Cache.persistent (← scriptedModel #[]) { directory })
      check (stop matches .idle) "the run finishes on what the cache kept"
      assertEqual "the times of the draws, not of the reads" (← sampleTimes second secondEnd) times
      -- The cache keeps a draw's time beside its response; a response as stored holds none.
      let mut kept := #[]
      for file in ← directory.readDir do
        let json ← match Json.parse (← IO.FS.readFile file.path) with
          | .ok json => pure json
          | .error problem => fail problem
        for draw in (json.getObjVal? "draws" >>= Json.getArr?).toOption.getD #[] do
          kept := kept.push ((draw.getObjVal? "elapsed_ms" >>= Json.getNat?).toOption.getD 0)
          check ((draw.getObjVal? "response" >>= (·.getObjVal? "elapsed_ms")).toOption.isNone)
            "the response holds no time"
      assertEqual "a time a draw" (kept.qsort (· < ·)) (times.qsort (· < ·)),

  test "running a point again is a fork: a new draw, the first one kept" do
    withMini {} fun run => do
      let responses := script ++ #[responseWith #[submitCall "s2" "the other"]]
      let rt ← runtime (echoing) (some (← cached (← scriptedModel responses)))
      let tip ← start rt run
      let (first, _) ← assertOk <| Driver.drive rt run tip
      -- The point before the first sample: the agent has read its task and the inbox.
      let log ← logAt rt first
      let found := log.findIdx? (fun | .answered _ (.sample ..) _ => true | _ => false)
      let some sampleAt := found | fail "no sample"
      let forest ← assertOk rt.store.forest
      let point := (forest.path first)[sampleAt - 1]!
      -- The scripted model's next response is the fork's: draw 1 of the same request.
      let (second, _) ← assertOk <| Driver.drive rt run point
      let forest ← assertOk rt.store.forest
      assertEqual "two continuations" (forest.childrenOf point).size 2
      assertEqual "the first kept" (agentStatus (← logAt rt first)) "Submitted"
      let forked ← logAt rt second
      check (forked.any fun | .returned ⟪"agent"⟫ value => contains value.compress "the other" | _ => false)
        "the fork ended its own way",

  test "a message appended where a run paused reaches the model in its next request" do
    withMini {} fun run => do
      let (model, requests) ← do
        let requests ← IO.mkRef (#[] : Array Chat.Request)
        let index ← IO.mkRef 0
        pure (({ identity := .mkObj [("model", "recording")]
                 sample := fun request => do
                   Result.fromIO Error.cache (requests.modify (·.push request))
                   pure { next := do
                     let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
                     pure (script[i]?.getD (responseWith #[submitCall "s"])) } } : Model), requests)
      let rt ← runtime (echoing) (some model)
      let (paused, _) ← assertOk <| Driver.drive rt run (← start rt run) { samples? := some 1 }
      let (told, _) ← assertOk <| Driver.append rt.store run paused (.arrived (.said "keep the old API"))
      let (_, _) ← assertOk <| Driver.drive rt run told { samples? := some 1 }
      let some request := (← requests.get)[1]? | fail "no second request"
      let some (Chat.Message.user text) := request.messages.back? | fail "the message is last"
      check (contains text "keep the old API" && contains text "<intervention>") text,

  test "a stop ends the agent, and one is refused once the agent is over" do
    withMini {} fun run => do
      let rt ← runtime (echoing) (some (← scriptedModel script))
      let tip ← start rt run
      let (paused, _) ← assertOk <| Driver.drive rt run tip { samples? := some 2 }
      let (stopped, _) ← assertOk <| Driver.append rt.store run paused (.stopped "enough")
      let (ended, stop) ← assertOk <| Driver.drive rt run stopped
      check (stop matches .idle) "the agent is over"
      assertEqual "stopped, with the reason the stop gave"
        ((lastCall? (← logAt rt ended)).bind (·.2) |>.map Render.endingSummary) (some "stopped: enough")
      check (!(← logAt rt ended).any fun | .returned ⟪"agent"⟫ _ | .failed ⟪"agent"⟫ _ => true | _ => false)
        "a stop marks no end of the agent's frames"
      assertError "a stop after the end" (Driver.append rt.store run ended (.stopped "again")) fun
        | .input _ => true
        | _ => false
      assertError "a message after the end" (Driver.append rt.store run ended (.arrived (.said "late"))) fun
        | .input _ => true
        | _ => false
      -- A program is called once no call runs, and only one the run can build.
      let grader := (graderCall "true").event
      assertError "a call while the agent runs" (Driver.append rt.store run paused grader) fun
        | .input message => contains message "a call is running"
        | _ => false
      assertError "a call of no program" (Driver.append rt.store run ended ({ testCall with name := "nothing" }).event) fun
        | .input message => contains message "no program named nothing"
        | _ => false
      -- Whether a call's arguments fit its program is the CLI's to check before it appends it.
      check (match Agents.Catalog.check (graderCall "") with
        | .error message => contains message "needs its command"
        | .ok () => false) "a grader with no command"
      -- Every program is called the same way: a task is a field of an agent's configuration.
      let agentWith (fields : List (String × Json)) : RoutineCall :=
        programCall "mini-swe" (.mkObj ((("model", "gpt-oss-120b") : String × Json) :: fields)) testEnvironment
      check (match Agents.Catalog.check (agentWith []) with
        | .error message => contains message "works on a task"
        | .ok () => false) "an agent with no task"
      check (Agents.Catalog.check (agentWith [("task", "fix it")]) matches .ok ()) "an agent with its task"
      let tasked := programCall "grader" (.mkObj [("command", "true"), ("task", "t")]) testEnvironment
      check (match Agents.Catalog.check tasked with
        | .error message => contains message "task"
        | .ok () => false) "a grader takes no task: it has no such field"
      let (asked, _) ← assertOk <| Driver.append rt.store run ended grader
      let log ← logAt rt asked
      check ((next run log) matches .hears #[] _) "the run takes the call"
      assertError "a second call, before the first is made" (Driver.append rt.store run asked grader) fun
        | .input message => contains message "a call to make here already"
        | _ => false
      -- The grader is a call of its own: its command is asked for in its frame, and a stop ends it.
      let grading := settle run log
      check ((next run grading) matches .ask { frame := ⟪"grader"⟫, op := .exec .., .. }) "the grader's command, in its own frame"
      let mut during := asked
      let mut forest ← assertOk rt.store.forest
      for event in grading.extract log.size grading.size do
        let (hash, grown) ← assertOk <| rt.store.put forest { parent? := some during, event }
        during := hash
        forest := grown
      assertError "a call while the grader runs" (Driver.append rt.store run during grader) fun
        | .input message => contains message "a call is running"
        | _ => false
      let (halted, _) ← assertOk <| Driver.append rt.store run during (.stopped "no need")
      check ((next run (← logAt rt halted)) matches .waits #[] none) "a stop ends the grader, and the run waits for a call",

  test "a log that is no trace of the run is refused, not driven" do
    withMini {} fun run => do
      let rt ← runtime (echoing) (some (← scriptedModel script))
      let tip ← start rt run
      let forest ← assertOk rt.store.forest
      let (bad, _) ← assertOk <| rt.store.put forest { parent? := some tip, event := .returned ⟪"agent", "bash#5"⟫ "x" }
      assertError "a mark the program does not make" (Driver.drive rt run bad) fun
        | .input message => contains message "no trace"
        | _ => false
      assertError "nor is anything appended to it" (Driver.append rt.store run bad (.arrived (.said "go on"))) fun
        | .input message => contains message "no trace"
        | _ => false,

  test "a program's comments are written once, before the event that follows them, and every comment of a log is passed over" do
    let run := commenting
    let rt ← runtime (echoing) none
    let tip ← start rt run
    -- Paused before the command: the comment before it waits for it, and is not written yet.
    let (paused, stop) ← assertOk <| Driver.drive rt run tip { budgetMs? := some 0 }
    check (stop matches .paused _) "paused at the budget"
    assertEqual "nothing written while paused" (comments (← logAt rt paused)) #[]
    let (first, stop) ← assertOk <| Driver.drive rt run paused
    check (stop matches .idle) "the agent is over"
    let log ← logAt rt first
    assertEqual "the program's comments, once each" (comments log) #["before the command", "it printed ok"]
    let at' := log.findIdx? fun | .commented "before the command" => true | _ => false
    check (at'.any fun i => log[i + 1]! matches .answered _ (.exec "echo one" _) _) "the first, just before its command"
    -- Driven again from its end, nothing is written.
    let count := (← assertOk rt.store.forest).entries.size
    let _ ← assertOk <| Driver.drive rt run first
    assertEqual "no entry written" (← assertOk rt.store.forest).entries.size count
    -- A comment in the log is passed over, even in the program's own words: the program's are
    -- written after it all the same.
    for text in #["watch the command", "before the command"] do
      let (noted, entry) ← assertOk <| Notices.comment rt.store tip text
      check (entry.event matches .commented _) "a comment"
      let (second, stop) ← assertOk <| Driver.drive rt run noted
      check (stop matches .idle) "the agent is over, from the comment too"
      assertEqual "that comment, then the program's" (comments (← logAt rt second))
        #[text, "before the command", "it printed ok"]
    -- A comment is taken at any entry, with nothing to check: where the agent is over, where a
    -- stop or a message is refused, and on a log that is no trace of its run.
    let (after, _) ← assertOk <| Notices.comment rt.store first "after the end"
    check ((next run (← logAt rt after)) matches .waits #[] _) "the run stands as it stood"
    assertError "a message there" (Driver.append rt.store run after (.arrived (.said "late"))) fun
      | .input _ => true
      | _ => false
    let forest ← assertOk rt.store.forest
    let (bad, _) ← assertOk <| rt.store.put forest { parent? := some tip, event := .returned ⟪"agent", "bash#5"⟫ "x" }
    let _ ← assertOk <| Notices.comment rt.store bad "this log is broken"
    pure (),

  test "a person's message and a person's change are told to the model as interventions" do
    let told (notice : Notice) : String :=
      ((Agents.MiniSwe.noticeMessage notice).map (·.toStored.compress)).getD "nothing"
    assertStringEq "a message" (told (.said "keep the old API"))
      (Chat.Message.user "<intervention>\nA person sent you a message while you were paused.\nkeep the old API\n</intervention>").toStored.compress
    assertStringEq "a change" (told (.changed default "  M a.txt\nI fixed it"))
      (Chat.Message.user "<intervention>\nA person changed the workspace while you were paused:\n  M a.txt\nI fixed it\n</intervention>").toStored.compress
    assertStringEq "a reply is the asking call's, not the model's to be told" (told (.replied ⟪"agent", "ask_user"⟫ .yes)) "nothing"
    assertStringEq "nor a call" (told (.called ⟨"grader", .null⟩)) "nothing",

  test "a commit appends the files and what changed, and the next command runs on them" do
    withMini {} fun run => do
      let executor ← containerExecutor
      try
        let rt ← runtime executor (some (← scriptedModel #[
          responseWith #[call "c1" "bash" "echo one > a.txt"],
          responseWith #[call "c2" "bash" "cat b.txt"], responseWith #[submitCall "s"]]))
        let (paused, _) ← assertOk <| Driver.drive rt run (← start rt run) { samples? := some 1 }
        let edited := (← scratch) / "edited"
        assertOk <| rt.workspaces.materialize ((workspace? (← logAt rt paused)).getD default) edited
        IO.FS.writeFile (edited / "b.txt") "from a person\n"
        let event ← assertOk <| Notices.changed rt.store rt.workspaces paused edited "I added b.txt"
        match event with
        | .arrived (.changed _ summary) => check (contains summary "+ b.txt" && contains summary "I added b.txt") summary
        | _ => fail "a change is a notice"
        let (changed, _) ← assertOk <| Driver.append rt.store run paused event
        assertError "no change is refused" (Notices.changed rt.store rt.workspaces changed edited "") fun
          | .input _ => true
          | _ => false
        let (final, _) ← assertOk <| Driver.drive rt run changed
        let log ← logAt rt final
        check (log.any fun
          | .answered _ (.exec "cat b.txt" _) (.ok (.execution e)) => e.output.output == "from a person\n"
          | _ => false) "the command read the person's file"
        let found := log.findIdx? (fun | .arrived (.changed _ summary) => contains summary "b.txt" | _ => false)
        let some changedAt := found | fail "the change is in the log"
        check (log.any fun | .heard ⟪"agent"⟫ notices => notices == #[changedAt] | _ => false)
          "the agent heard the change"
      finally executor.close,

  test "a command run with its outputs kept finds the whole of earlier ones; a fork, only its own" do
    withMini { recoverOutput := true } fun run => do
      let long := String.ofList (List.replicate 12000 'z')
      let rt ← containerRuntime (some (← cached (← scriptedModel #[
          responseWith #[call "c1" "bash" s!"printf '%s' {long}"],
          responseWith #[call "c2" "bash" "ls /alaya/outputs"],
          responseWith #[submitCall "s"],
          responseWith #[call "c3" "bash" "ls /alaya/outputs"], responseWith #[submitCall "s"]])))
      try
        let tip ← start rt run
        let (first, _) ← assertOk <| Driver.drive rt run tip
        let log ← logAt rt first
        let some listed := log.findSome? fun
            | .answered _ (.exec "ls /alaya/outputs" _) (.ok (.execution e)) => some e.output.output
            | _ => none
          | fail "the listing ran"
        let some firstFile := log.findSome? fun
            | .answered _ (.exec _ _) (.ok (.execution e)) => e.file?
            | _ => none
          | fail "a file is named"
        check (contains listed (firstFile.drop "/alaya/outputs/".length).toString) s!"{listed} lacks {firstFile}"
        assertEqual "the file is named by its content" firstFile s!"/alaya/outputs/{Driver.outputFile long}"
        -- From the point after the first command: the second listing is the fork's own.
        let forest ← assertOk rt.store.forest
        let returnedAt := log.findIdx? (fun | .returned ⟪"agent", "bash"⟫ _ => true | _ => false)
        let some at' := returnedAt | fail "no return"
        let (forked, _) ← assertOk <| Driver.drive rt run (forest.path first)[at']!
        let some again := (← logAt rt forked).findSome? fun
            | .answered _ (.exec "ls /alaya/outputs" _) (.ok (.execution e)) => some e.output.output
            | _ => none
          | fail "the fork listed"
        assertEqual "one file, the first command's" ((again.splitOn "\n").filter (!·.isEmpty)).length 1
        let reached := (workspace? log).getD default
        assertEqual "no output reaches the workspace"
          ((← assertOk <| rt.workspaces.listEntries reached "").map (·.name)) #[]
      finally pure (),

  test "an output's file is named by its content, so a comment before the command changes no request" do
    withMini { recoverOutput := true } fun run => do
      let long := String.ofList (List.replicate 12000 'z')
      let script := #[responseWith #[call "c1" "bash" "print"], responseWith #[submitCall "s"]]
      let named (log : Log Agent) : Option String := log.findSome? fun
        | .answered _ (.exec _ _) (.ok (.execution e)) => e.file?
        | _ => none
      let requests (log : Log Agent) : Array String :=
        (samplesOf run log).map fun (request, _) => (Model.requestDigest request).hex
      -- One run as it is, and one with a person's comment before everything the agent does.
      let plain ← runtime (echoing long) (some (← scriptedModel script))
      let (first, _) ← assertOk <| Driver.drive plain run (← start plain run)
      let noted ← runtime (echoing long) (some (← scriptedModel script))
      let (comment, _) ← assertOk <| Notices.comment noted.store (← start noted run) "a note"
      let (second, _) ← assertOk <| Driver.drive noted run comment
      let name := s!"/alaya/outputs/{Driver.outputFile long}"
      assertEqual "the name is the content's" (named (← logAt plain first)) (some name)
      assertEqual "and the same after a comment" (named (← logAt noted second)) (some name)
      assertEqual "two samples each" (requests (← logAt plain first)).size 2
      assertEqual "the model is sent the same requests" (requests (← logAt noted second))
        (requests (← logAt plain first)),

  test "a command run without its outputs kept finds none, whatever was left there" do
    withMini {} fun run => do
      let rt ← filingRuntime (← scriptedModel #[responseWith #[call "c1" "bash" "leak"],
        responseWith #[call "c2" "bash" "ls"], responseWith #[submitCall "s"]])
      let (final, _) ← assertOk <| Driver.drive rt run (← start rt run)
      assertEqual "the listing" (printed (← logAt rt final) "ls") (some "work: ; outputs: "),

  test "a fork has the files of its own log, and none of the branch it left" do
    withMini {} fun run => do
      let rt ← filingRuntime (← cached (← scriptedModel #[
        responseWith #[call "c1" "bash" "write a.txt one"], responseWith #[call "c2" "bash" "write b.txt two"],
        responseWith #[call "c3" "bash" "ls"], responseWith #[submitCall "s"],
        -- The fork's draws: the second response again, and what follows it there.
        responseWith #[call "c4" "bash" "ls"], responseWith #[submitCall "t"]]))
      let (first, _) ← assertOk <| Driver.drive rt run (← start rt run)
      let log ← logAt rt first
      assertEqual "the first log's files" (printed log "ls") (some "work: a.txt b.txt; outputs: ")
      -- From the point after the first command, before the second sample.
      let samples := log.zipIdx.filterMap fun (event, i) =>
        if event matches .answered _ (.sample ..) _ then some i else none
      let forest ← assertOk rt.store.forest
      let (forked, _) ← assertOk <| Driver.drive rt run (forest.path first)[samples[1]! - 1]!
      assertEqual "the fork's files" (printed (← logAt rt forked) "ls") (some "work: a.txt; outputs: ")
      -- And the first log's workspace is as it was.
      let reached := (workspace? log).getD default
      assertEqual "the first log's workspace"
        ((← assertOk <| rt.workspaces.listEntries reached "").map (·.name) |>.qsort (· < ·)) #["a.txt", "b.txt"],

  test "the report shows how each command changed the workspace, with the text when it is cheap" do
    withMini {} fun run => do
      let commands := #["write a.txt one", "write .venv/x 1", "write a.txt two", "rm a.txt", "write .venv/x 2"]
      let rt ← filingRuntime (← scriptedModel (commands.mapIdx (fun i command =>
        responseWith #[call s!"c{i}" "bash" command]) ++ #[responseWith #[submitCall "s"]]))
      let _ ← assertOk <| Driver.drive rt run (← start rt run)
      let forest ← assertOk rt.store.forest
      -- The directory to fold is given as a person types it, with its slash.
      let page ← assertOk <| Html.dataJson rt.store rt.workspaces forest "t" #[".venv/"] run
      let entries ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "entries" >>= Json.getArr?)
      let changesOf (command : String) : TestM Json := do
        let some row := entries.find? fun row =>
            (row.getObjVal? "e" >>= (·.getObjVal? "command") >>= Json.getStr?).toOption == some command
          | fail s!"no entry for {command}"
        pure ((row.getObjVal? "changes").toOption.getD .null)
      let listed (changes : Json) : String := ((changes.getObjVal? "changes").toOption.getD .null).compress
      let folded (changes : Json) : String := ((changes.getObjVal? "folded").toOption.getD .null).compress
      assertStringEq "a file added" (listed (← changesOf commands[0]!))
        "[{\"kind\":\"added\",\"new\":\"one\\n\",\"old\":null,\"path\":\"a.txt\"}]"
      assertStringEq "a file modified" (listed (← changesOf commands[2]!))
        "[{\"kind\":\"modified\",\"new\":\"two\\n\",\"old\":\"one\\n\",\"path\":\"a.txt\"}]"
      assertStringEq "a file removed" (listed (← changesOf commands[3]!))
        "[{\"kind\":\"removed\",\"new\":null,\"old\":\"two\\n\",\"path\":\"a.txt\"}]"
      -- What changes under a folded directory is counted, not listed.
      let made ← changesOf commands[1]!
      assertStringEq "nothing listed" (listed made) "[]"
      assertStringEq "a folded directory made" (folded made)
        "[{\"added\":1,\"modified\":0,\"prefix\":\".venv\",\"removed\":0}]"
      assertEqual "but counted" ((made.getObjVal? "count" >>= Json.getNat?).toOption) (some 1)
      assertStringEq "a file modified under it" (folded (← changesOf commands[4]!))
        "[{\"added\":0,\"modified\":1,\"prefix\":\".venv\",\"removed\":0}]"
      -- An entry that leaves the workspace as it was carries no change.
      check (entries.all fun row => (row.getObjVal? "e" >>= (·.getObjVal? "k") >>= Json.getStr?).toOption == some "exec"
          || (row.getObjVal? "changes").toOption == some Json.null) "a change on an entry that is no command",

  test "the report carries every sample's request, exactly, and every entry once" do
    withMini {} fun run => do
      let responses := #[responseWith #[call "a" "bash" "echo one", call "b" "bash" "echo two"],
        responseWith #[],   -- a format error: the view substitutes a user turn
        responseWith #[submitCall "s"], responseWith #[submitCall "t"]]
      -- Behind the cache, as a run's model is: the fork's draw asks for one response more.
      let rt ← runtime (echoing) (some (← cached (← scriptedModel responses)))
      let tip ← start rt run
      let (first, _) ← assertOk <| Driver.drive rt run tip
      -- A fork from just before the last sample, so the forest has two branches.
      let log ← logAt rt first
      let forest ← assertOk rt.store.forest
      let some lastSample := (log.zipIdx.filter fun (e, _) => e matches .answered _ (.sample ..) _).back?
        | fail "no sample"
      let _ ← assertOk <| Driver.drive rt run (forest.path first)[lastSample.2 - 1]!
      let forest ← assertOk rt.store.forest
      let page ← assertOk <| Html.dataJson rt.store rt.workspaces forest "t" (root := run)
      let entries ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "entries" >>= Json.getArr?)
      assertEqual "every entry once" entries.size forest.entries.size
      let envelopes ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "envelopes" >>= Json.getArr?)
      -- Assemble each request as the page does, from what each adds to the one before it.
      let rec messages (fuel i : Nat) : Array Json :=
        match fuel with
        | 0 => #[]
        | fuel + 1 =>
          let request := (entries[i]!.getObjVal? "request").toOption.getD .null
          let added := ((request.getObjVal? "added" >>= Json.getArr?).toOption).getD #[]
          match (request.getObjVal? "base" >>= Json.getNat?).toOption with
          | some base => messages fuel base ++ added
          | none => added
      let byHash := entries.zipIdx.map fun (e, i) => ((e.getObjVal? "h" >>= Json.getStr?).toOption.getD "", i)
      for (request, _) in samplesOf run log do
        let digest := Model.requestDigest request
        -- The entry that answered this request, in the first branch.
        let found := log.findIdx? (fun | .answered _ (.sample _ d) _ => d == digest | _ => false)
        let some position := found | fail "no answer for a request"
        let some (_, i) := byHash.find? (·.1 == ((forest.path first)[position]!).hex) | fail "entry missing"
        let row := entries[i]!.getObjVal? "request" |>.toOption.getD .null
        let envelope := envelopes[(row.getObjVal? "envelope" >>= Json.getNat?).toOption.getD 0]!
        let assembled := envelope.setObjVal! "messages" (.arr (messages entries.size i))
        assertStringEq "request" assembled.compress request.toJson.compress
]

end RunsTests
