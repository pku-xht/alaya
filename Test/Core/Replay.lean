import Alaya.Core.Rebase
import Test.Support.Framework
import Test.Support.Frames

/-! Replay, on its own: a signature of the test's, whose one operation is answered by its name,
and a driver of the test's that answers it and appends the marks, with no store and no world.
What a log is a trace of, how a read takes notices, what a break ends, how a run starts and
ends, and what a rebase keeps, each where it is hardest. -/

namespace ReplayTests

open Testing Alaya Alaya.Base Alaya.Core
open Lean (Json)

/-! ## A signature, and a driver -/

/-- The test's signature: an operation is a name, answered with JSON, and kept by its name. -/
abbrev Toy : Signature :=
  { Op := String, Answer := fun _ => Json, Key := String, key := id, sameKey := (· == ·)
    Stored := Json, store := fun _ answer => answer, read := fun _ stored => some stored }

/-- The operation `name`, which the test's world answers with `"name done"`. -/
def step (name : String) : Computation Toy Json := perform (σ := Toy) name

def world (op : String) : Except String Json := .ok (.str s!"{op} done")

/-- The log with `event` appended as the driver appends one: after the comments the computation
made since its last event. -/
def appended (scope : Scope Toy) (log : Log Toy) (event : Event Toy) : Log Toy :=
  (log ++ (Replayer.ofLog scope log).comments.map Event.commented).push event

/-- The log driven on as the driver drives it, `answer` answering every operation, until the
run waits, ends, or is no trace of its routine. -/
partial def drive (scope : Scope Toy) (log : Log Toy)
    (answer : String → Except String Json := world) (fuel : Nat := 1000) : Log Toy :=
  if fuel == 0 then log else
  match next scope log with
  | .ask request => drive scope (appended scope log (.answered request.frame request.op (answer request.op))) answer (fuel - 1)
  | .mark event => drive scope (appended scope log event) answer (fuel - 1)
  | _ => log

def calledEvent (name : String) (arguments : Json := .null) : Event Toy :=
  .arrived (.called { name, arguments })

def said (message : String) : Event Toy := .arrived (.said message)

/-- A scope of routines that call each other by name, each a computation of its arguments. -/
def scopeOf (routines : Array (String × (Json → Computation Toy Json))) : Scope Toy :=
  Scope.fix fun scope => routines.map fun (name, body) => { name, body, scope }

/-- Waits for a message, and gives it. -/
def awaitMessage : Computation Toy Json := do
  match ← await fun _ notice => notice matches .said _ with
  | .said message :: _ => pure (.str message)
  | _ => throw (.refused "no message")

def describe (next : Next Toy) : String :=
  match next with
  | .ask request => s!"ask {Frame.render request.frame} {request.op}"
  | .mark event => s!"mark in {(event.frame?.map Frame.render).getD "-"}"
  | .waits frame _ => s!"waits in {Frame.render frame}"
  | .ended (.ok value) => s!"ended {value.compress}"
  | .ended (.error error) => s!"failed {error.render}"
  | .mismatch position => s!"mismatch at {position}"
  | .unguarded frame => s!"unguarded in {Frame.render frame}"

def assertNext (label : String) (scope : Scope Toy) (log : Log Toy) (expected : String) : TestM Unit :=
  assertEqual label (describe (next scope log)) expected

/-- Whether the log has a mark, a return or a failure, in `frame`. -/
def endedIn (log : Log Toy) (frame : Frame) : Bool :=
  log.any fun | .returned at' _ | .failed at' _ => at' == frame | _ => false

/-! ## The suites -/

def startSuite : Suite := suite "core/replay.start" #[
  test "a run waits outside until its call arrives, and passes over the notices before it" do
    let scope := scopeOf #[("run", fun _ => step "a")]
    assertNext "an empty log" scope #[] "waits in -"
    assertNext "notices that are no call" scope #[said "hi", .arrived (.changed default "w")] "waits in -"
    let log := drive scope #[said "hi", calledEvent "run"]
    check (log[2]? matches some (Event.heard #[] #[1])) "the outside takes the call where it is"
    check (log[3]? matches some (Event.opened ⟪"run"⟫ _)) "and opens it in a frame of its own"
    assertNext "the run is over when its call is" scope log "ended \"a done\"",

  test "a run whose call names no routine of the scope fails in the call's frame" do
    let log := drive (scopeOf #[("run", fun _ => pure .null)]) #[calledEvent "nowhere"]
    check (log.any fun | .failed ⟪"nowhere"⟫ (.defect message) => contains message "no routine named nowhere" | _ => false)
      "the call fails in its frame"
    assertNext "and the run with it" (scopeOf #[]) log "failed defect: no routine named nowhere",

  test "a call after the run is over is read by no one, and the run stays over" do
    let scope := scopeOf #[("run", fun _ => pure "done")]
    let log := drive scope #[calledEvent "run"]
    assertNext "over" scope log "ended \"done\""
    assertNext "still over" scope (log.push (calledEvent "run")) "ended \"done\"",

  test "a wait for one call takes the earliest, and leaves the others where they arrived" do
    -- A session: it takes a call, makes it, and waits for the next.
    let session : Json → Computation Toy Json := fun _ => iter (fun (_ : Unit) => do
      match ← await (one := true) fun _ notice => notice matches .called _ with
      | .called call :: _ => Computation.call call fun _ => pure (.inl ())
      | _ => throw (.refused "no call")) ()
    let scope := scopeOf #[("session", session), ("a", fun _ => step "a"), ("b", fun _ => step "b")]
    let log := drive scope #[calledEvent "session", calledEvent "a", calledEvent "b"]
    let reads := log.filterMap fun | .heard ⟪"session"⟫ taken => some taken | _ => none
    assertEqual "one call each, in order" reads #[#[1], #[2]]
    check (log.any (· matches .opened ⟪"session", "a"⟫ _) && log.any (· matches .opened ⟪"session", "b"⟫ _))
      "both are made"
    -- A wait for every call takes both at once.
    let greedy : Json → Computation Toy Json := fun _ => do
      let calls ← await fun _ notice => notice matches .called _
      pure (Json.num calls.length)
    let scope := scopeOf #[("session", greedy)]
    let log := drive scope #[calledEvent "session", calledEvent "a", calledEvent "b"]
    check (log.any (· matches .heard ⟪"session"⟫ #[1, 2])) "a plain wait takes all it is for"
    assertNext "and gives them" scope log "ended 2"
]

def readSuite : Suite := suite "core/replay.reads" #[
  test "a read takes the messages that arrived, before or after it was made, and leaves the rest" do
    let reads : Json → Computation Toy Json := fun _ => do
      let first ← inbox
      let _ ← step "work"
      let second ← inbox
      pure (.arr #[(first.length : Json), (second.length : Json)])
    let scope := scopeOf #[("run", reads)]
    -- Before the run: a message, a change, and a reply to another frame.
    let log := drive scope #[said "early", .arrived (.changed default "w"),
      .arrived (.replied ⟪"other"⟫ .yes), calledEvent "run"] (fun op => if op == "work" then world op else .error "no")
    check (log.any (· matches .heard ⟪"run"⟫ #[0])) "the first read takes the message alone"
    -- A message that arrives while the run works is the next read's.
    let paused := (log.filter fun | .heard ⟪"run"⟫ #[] => false | _ => true)
    let at' := paused.findIdx? (· matches .answered ..) |>.getD 0
    let withLate := (paused.extract 0 (at' + 1)).push (said "late")
    let finished := drive scope withLate
    check (finished.any fun | .heard ⟪"run"⟫ taken => taken == #[withLate.size - 1] | _ => false) "the second read takes the late message"
    assertNext "each read gave its own" scope finished "ended [1,1]",

  test "a read is marked with exactly what it takes: other positions, an order, a subset or a frame are no trace" do
    let scope := scopeOf #[("run", fun _ => do let taken ← inbox; pure (Json.num taken.length))]
    let start : Log Toy := #[said "a", said "b", calledEvent "run", .heard #[] #[2], .opened ⟪"run"⟫ { name := "run", arguments := .null }]
    assertNext "the read due" scope start "mark in run"
    for (label, heard) in [("other positions", Event.heard ⟪"run"⟫ #[0, 2]), ("another order", .heard ⟪"run"⟫ #[1, 0]),
        ("a subset", .heard ⟪"run"⟫ #[0]), ("another frame", .heard ⟪"other"⟫ #[0, 1])] do
      assertNext label scope (start.push heard) "mismatch at 5"
    assertNext "the read itself" scope (start.push (.heard ⟪"run"⟫ #[0, 1])) "mark in run",

  test "an answer is matched by its frame and its key, and a failed one goes on as a failure" do
    let scope := scopeOf #[("run", fun _ => do
      let a ← try step "a" catch error => pure (.str s!"caught {error.reason}")
      pure a)]
    let start := drive scope #[calledEvent "run"] (fun _ => .error "not now")
    assertNext "a failed answer is caught where it was asked" scope start "ended \"caught not now\""
    let asked := (start.extract 0 3)
    assertNext "the operation due" scope asked "ask run a"
    assertNext "another operation" scope (asked.push (.answered ⟪"run"⟫ "b" (.ok .null))) "mismatch at 3"
    assertNext "another frame" scope (asked.push (.answered ⟪"other"⟫ "a" (.ok .null))) "mismatch at 3"
    assertNext "a mark where an answer is due" scope (asked.push (.returned ⟪"run"⟫ .null)) "mismatch at 3",

  test "a question waits for a reply to its own frame, of its form, and nothing else ends the wait" do
    let scope := scopeOf #[("run", fun _ => do
      let reply ← ask { text := "Go on?", form := .yesNo }
      pure (.str reply.line))]
    let asked := drive scope #[calledEvent "run"]
    assertNext "the question waits" scope asked "waits in run"
    for (label, notice) in [("a message", Notice.said "yes"), ("a reply to another frame", .replied ⟪"other"⟫ .yes),
        ("a reply of another form", .replied ⟪"run"⟫ (.choice 1))] do
      assertNext label scope (drive scope (asked.push (.arrived notice))) "waits in run"
    assertNext "its reply" scope (drive scope (asked.push (.arrived (.replied ⟪"run"⟫ .yes)))) "ended \"yes\""
]

def breakSuite : Suite := suite "core/replay.breaks" #[
  test "a break ends the call open in its frame and every call inside it, with no marks, and its caller is told why" do
    let scope := scopeOf #[
      ("run", fun _ => try call "child" .null catch error => pure (.str s!"caught {error.reason}")),
      ("child", fun _ => call "grandchild" .null),
      ("grandchild", fun _ => awaitMessage)]
    let waiting := drive scope #[calledEvent "run"]
    assertNext "the grandchild waits" scope waiting "waits in run/child/grandchild"
    let broken := drive scope (waiting.push (.broke ⟪"run", "child"⟫ "enough"))
    check (!endedIn broken ⟪"run", "child"⟫ && !endedIn broken ⟪"run", "child", "grandchild"⟫)
      "neither the child nor the grandchild is marked as ended"
    assertNext "the caller caught the reason" scope broken "ended \"caught enough\""
    -- The same break of the innermost call: its caller, the child, does not catch it, so it fails.
    let inner := drive scope (waiting.push (.broke ⟪"run", "child", "grandchild"⟫ "no"))
    check (inner.any (· matches .failed ⟪"run", "child"⟫ (.broken "no"))) "the child fails with the reason, as broken"
    assertNext "and the run catches that" scope inner "ended \"caught no\"",

  test "nothing inside a broken call catches the break, a loop included" do
    let scope := scopeOf #[
      ("run", fun _ => try call "child" .null catch error => pure (.str s!"run caught {error.reason}")),
      ("child", fun _ => try (iter (fun (_ : Unit) => do let _ ← awaitMessage; pure (.inl ())) ())
        catch _ => pure "child caught")]
    let waiting := drive scope #[calledEvent "run"]
    let broken := drive scope (waiting.push (.broke ⟪"run", "child"⟫ "stop"))
    check (!broken.any (· matches .returned ⟪"run", "child"⟫ _)) "the child's handler never ran"
    assertNext "its caller's did" scope broken "ended \"run caught stop\"",

  test "a break right after an opening ends the call before it asks for anything" do
    let scope := scopeOf #[("run", fun _ => try call "child" .null catch error => pure (.str error.reason)),
      ("child", fun _ => step "never")]
    let opened := (drive scope #[calledEvent "run"]).filter fun | .answered .. => false | _ => true
    let opened := opened.extract 0 (opened.findIdx? (· matches .opened ⟪"run", "child"⟫ _) |>.map (· + 1) |>.getD 0)
    assertNext "the child's operation is due" scope opened "ask run/child never"
    let broken := drive scope (opened.push (.broke ⟪"run", "child"⟫ "early"))
    check (!broken.any (· matches .answered ..)) "nothing was asked"
    assertNext "the caller goes on" scope broken "ended \"early\"",

  test "a break of the run's own call ends the run with its reason" do
    let scope := scopeOf #[("run", fun _ => try awaitMessage catch _ => pure "caught")]
    let waiting := drive scope #[calledEvent "run"]
    assertNext "the run is over" scope (waiting.push (.broke ⟪"run"⟫ "enough")) "failed broken: enough",

  test "a break has no place where no call is open in its frame" do
    let scope := scopeOf #[("run", fun _ => do let _ ← step "a"; awaitMessage)]
    let waiting := drive scope #[calledEvent "run"]
    let position := waiting.size
    for (label, frame) in [("the outside", ⟪⟫), ("a frame never opened", ⟪"run", "child"⟫),
        ("a frame inside the run's that is no call's", ⟪"run", "a"⟫)] do
      assertNext label scope (waiting.push (.broke frame "x")) s!"mismatch at {position}"
    -- Before the call is opened, its frame is not open yet.
    let unopened : Log Toy := #[calledEvent "run", .heard #[] #[0]]
    assertNext "a call not yet opened" scope (unopened.push (.broke ⟪"run"⟫ "x")) "mismatch at 2"
    -- Once the run is over, nothing is open.
    let over := drive scope (waiting.push (said "hi"))
    assertNext "the run is over" scope over "ended \"hi\""
    assertNext "a break after the end" scope (over.push (.broke ⟪"run"⟫ "x")) s!"mismatch at {over.size}"
]

def computationSuite : Suite := suite "core/replay.computations" #[
  test "a failure is caught around a loop, around a call, or by no one" do
    let rounds : Computation Toy Json := iter (fun (n : Nat) => do
      let _ ← step s!"round {n}"
      if n == 2 then throw (.refused s!"gave up at {n}") else pure (Sum.inl (n + 1))) 0
    let caught := scopeOf #[("run", fun _ => try rounds catch error => pure (.str s!"caught: {error.reason}"))]
    let log := drive caught #[calledEvent "run"]
    assertEqual "three rounds, each in the log" (log.filter (· matches .answered ..)).size 3
    assertNext "the handler's value" caught log "ended \"caught: gave up at 2\""
    let uncaught := scopeOf #[("run", fun _ => rounds)]
    let failing := drive uncaught #[calledEvent "run"]
    check (failing.any (· matches .failed ⟪"run"⟫ (.refused "gave up at 2"))) "the call fails"
    assertNext "and the run" uncaught failing "failed refused: gave up at 2"
    -- Inside a round, a try catches each round's failure and the loop goes on.
    let perRound := scopeOf #[("run", fun _ => iter (fun (n : Nat) => do
      let _ ← try step s!"r{n}" catch _ => pure .null
      pure (if n == 2 then Sum.inr (Json.num n) else Sum.inl (n + 1))) 0)]
    assertNext "every round ran" perRound (drive perRound #[calledEvent "run"] (fun _ => .error "x")) "ended 2"
    -- A handler that throws is a failure of its own.
    let rethrows := scopeOf #[("run", fun _ => try step "a" catch error => throw (.refused s!"again: {error.reason}"))]
    assertNext "a handler's failure" rethrows (drive rethrows #[calledEvent "run"] (fun _ => .error "x"))
      "failed refused: again: x",

  test "a retry tries again while it fails, every try in the log, each call in a frame of its own" do
    let scope := scopeOf #[("run", fun _ => retry 2 (call "flaky" .null)), ("flaky", fun _ => step "try")]
    let log := drive scope #[calledEvent "run"] (fun _ => .error "busy")
    let frames := log.filterMap fun | .opened frame { name := "flaky", .. } => some frame | _ => none
    assertEqual "three calls" frames #[⟪"run", "flaky"⟫, ⟪"run", "flaky#1"⟫, ⟪"run", "flaky#2"⟫]
    assertNext "then it fails" scope log "failed refused: busy"
    let once := scopeOf #[("run", fun _ => retry 0 (step "a"))]
    assertEqual "retry 0 tries once" ((drive once #[calledEvent "run"] (fun _ => .error "x")).filter (· matches .answered ..)).size 1,

  test "a loop that reads nothing in a round is found out, in its own frame, and stays so" do
    let spins : Computation Toy Json := iter (fun (n : Nat) => do
      comment s!"round {n}"
      pure (Sum.inl (n + 1) : Nat ⊕ Json)) 0
    let scope := scopeOf #[("run", fun _ => call "tool" .null), ("tool", fun _ => spins)]
    let log := drive scope #[calledEvent "run"]
    assertNext "a loop that only comments" scope log "unguarded in run/tool"
    assertNext "and after more arrives" scope (log.push (said "x")) "unguarded in run/tool",

  test "a comment is kept until the next event, and replay passes over every comment in the log" do
    let scope := scopeOf #[("run", fun _ => do
      comment "before"
      let _ ← step "a"
      comment "after"
      pure "done")]
    let log := drive scope #[calledEvent "run"]
    let comments := log.filterMap fun | .commented text => some text | _ => none
    assertEqual "each once" comments #["before", "after"]
    check (log.findIdx? (· matches .commented "before") |>.any fun i => log[i + 1]? matches some (Event.answered ..))
      "the first just before the operation"
    let bare := log.filter fun | .commented _ => false | _ => true
    assertNext "without them" scope bare "ended \"done\""
    assertNext "with others among them" scope (bare.insertIdx! 3 (.commented "by hand")) "ended \"done\""
    assertEqual "the computation's own are still to write" (Replayer.ofLog scope (bare.extract 0 3)).comments #["before"],

  test "a typed routine reads its arguments and its result, and says which side could not" do
    let typed : Routine.Typed Toy Nat Nat := routine "double" fun (n : Nat) => pure (2 * n)
    let scope := scopeOf #[("run", fun arguments => do
        let n ← typed.call (arguments.getNat?.toOption.getD 0)
        pure (Json.num n)),
      ("double", typed.body), ("wrong", fun _ => typed.call 1),
      ("bad-arguments", fun _ => call "double" "not a number")]
    assertNext "a round trip" scope (drive scope #[calledEvent "run" (Json.num 21)]) "ended 42"
    let log := drive scope #[calledEvent "bad-arguments"]
    check (log.any fun | .failed ⟪"bad-arguments", "double"⟫ (.refused message) => contains message "double: its arguments cannot be read" | _ => false)
      "unreadable arguments fail in the callee's frame",

  test "a scope keeps the first routine of a name, lets routines defined together call each other, and can lose one" do
    let first := Scope.of (σ := Toy) #[{ name := "a", body := fun _ => pure "first", scope := .empty },
      { name := "a", body := fun _ => pure "second", scope := .empty }]
    assertNext "the first of a name" first (drive first #[calledEvent "a"]) "ended \"first\""
    let pair := scopeOf #[("even", fun n => match n.getNat?.toOption.getD 0 with
        | 0 => pure true | n + 1 => call "odd" (Json.num n)),
      ("odd", fun n => match n.getNat?.toOption.getD 0 with
        | 0 => pure false | n + 1 => call "even" (Json.num n))]
    assertNext "mutual recursion" pair (drive pair #[calledEvent "even" (Json.num 4)]) "ended true"
    -- Without `step`, wherever it is reached from: two calls down.
    let deep := scopeOf #[("run", fun _ => call "mid" .null), ("mid", fun _ => call "leaf" .null),
      ("leaf", fun _ => pure "leaf")]
    let log := drive (deep.without "leaf") #[calledEvent "run"]
    check (log.any fun | .failed ⟪"run", "mid", "leaf"⟫ (.defect message) => contains message "no routine named leaf" | _ => false)
      "the routine is gone two calls down",

  test "a refusal and a break are caught; a defect is not, and fails every call up to the run" do
    let scope := scopeOf #[
      ("refuses", fun _ => try call "no" .null catch error => pure (.str s!"caught {error.kind}")),
      ("no", fun _ => throw (.refused "wrong data")),
      ("buggy", fun _ => try call "mid" .null catch _ => pure "caught"),
      ("mid", fun _ => try call "nowhere" .null catch _ => pure "caught too")]
    assertNext "a refusal is caught" scope (drive scope #[calledEvent "refuses"]) "ended \"caught refused\""
    let log := drive scope #[calledEvent "buggy"]
    check (log.any (· matches .failed ⟪"buggy", "mid"⟫ (.defect "no routine named nowhere")))
      "the caller of the missing routine fails with the defect, its handler passed over"
    check (!log.any (· matches .returned ..)) "no handler ran"
    assertNext "and the run ends with it" scope log "failed defect: no routine named nowhere"
]

def rebaseSuite : Suite := suite "core/rebase" #[
  test "a log rebased onto the routine that made it is that log, and an empty log is empty" do
    let scope := scopeOf #[("run", fun _ => do let _ ← step "a"; let _ ← step "b"; pure "done")]
    let log := drive scope #[calledEvent "run"]
    let rebased := rebase scope log
    check rebased.divergence?.isNone "the whole log holds"
    assertEqual "event for event" (rebased.log.map (·.2)) ((Array.range log.size).map some)
    check ((rebase scope #[]).log.isEmpty && (rebase scope #[]).divergence?.isNone) "nothing to keep",

  test "a log that stops being a trace diverges there, and what came from outside after it is left out" do
    let old := scopeOf #[("run", fun _ => do let _ ← step "a"; let _ ← awaitMessage; let _ ← step "b"; pure "done")]
    let waiting := drive old #[calledEvent "run"]
    let log := drive old (waiting.push (said "go"))
    let revised := scopeOf #[("run", fun _ => do let _ ← step "A"; pure "done")]
    let rebased := rebase revised log
    let some divergence := rebased.divergence? | fail "the log diverges"
    check (divergence.found matches .answered _ "a" _) "at the first answer"
    check (divergence.expected matches .ask { op := "A", .. }) "where the revised routine asks another"
    assertEqual "the message is left out, with its position" (rebased.dropped.map (·.1)) #[waiting.size],

  test "a routine that ends earlier diverges where the old log goes on" do
    let old := scopeOf #[("run", fun _ => do let _ ← step "a"; let _ ← step "b"; pure "done")]
    let log := drive old #[calledEvent "run"]
    let shorter := scopeOf #[("run", fun _ => do let _ ← step "a"; pure "done")]
    let some divergence := (rebase shorter log).divergence? | fail "the log diverges"
    check (divergence.expected matches .mark (.returned ..)) "the revised routine returns there",

  test "a rebase writes the revised routine's comments, drops the log's, and moves the reads with them" do
    let quiet := scopeOf #[("run", fun _ => do let _ ← step "a"; let taken ← inbox; pure (Json.num taken.length))]
    let waiting := (drive quiet #[calledEvent "run"]).pop.pop
    let log := drive quiet (waiting.push (said "hint") |>.push (.commented "a person's note"))
    let chatty := scopeOf #[("run", fun _ => do comment "starting"; let _ ← step "a"; let taken ← inbox; pure (Json.num taken.length))]
    let rebased := rebase chatty log
    check rebased.divergence?.isNone "a change of comments only: the whole log holds"
    let new := rebased.log.map (·.1)
    assertEqual "the revised routine's comments alone" (new.filterMap fun | .commented text => some text | _ => none) #["starting"]
    let some hint := new.findIdx? (· matches .arrived (.said _)) | fail "the message"
    check (new.any fun | .heard ⟪"run"⟫ taken => taken == #[hint] | _ => false) "the read takes it at its new position",

  test "a break before the divergence is kept, and one after it is left out" do
    let scope := scopeOf #[("run", fun _ => try call "child" .null catch _ => step "after"),
      ("child", fun _ => awaitMessage)]
    let waiting := drive scope #[calledEvent "run"]
    let log := drive scope (waiting.push (.broke ⟪"run", "child"⟫ "stop"))
    check (rebase scope log).divergence?.isNone "the break holds"
    let revised := scopeOf #[("run", fun _ => try call "child" .null catch _ => step "AFTER"),
      ("child", fun _ => awaitMessage)]
    let rebased := rebase revised log
    check (rebased.log.any (·.1 matches .broke ..)) "the break is kept before the divergence"
    check (rebased.divergence?.any (·.found matches .answered _ "after" _)) "which is at the answer after it"
]

def frameSuite : Suite := suite "core/frames" #[
  test "a frame renders as a path of routines, each after its first with how many came before, and reads back" do
    for (frame, text) in [(⟪"session", "agent", "bash#2", "x"⟫, "session/agent/bash#2/x"), (⟪⟫, "-"), (⟪"a#10"⟫, "a#10")] do
      assertEqual s!"render {text}" (Frame.render frame) text
      assertEqual s!"parse {text}" (Frame.parse text).toOption (some frame)
    for bad in ["agent/bash#x", "agent//x", "#2", "a#1#2", "/a", ""] do
      check ((Frame.parse bad).toOption.isNone) s!"{bad.quote} is no frame"
    check (Frame.within ⟪"a", "b"⟫ ⟪"a"⟫) "a frame is within its caller's"
    check (Frame.within ⟪"a"⟫ ⟪"a"⟫) "and its own"
    check (!Frame.within ⟪"a"⟫ ⟪"a", "b"⟫) "not within a callee's"
    check (!Frame.within ⟪"ab"⟫ ⟪"a"⟫) "a step is a whole name"
]

def suites : Array Suite := #[startSuite, readSuite, breakSuite, computationSuite, rebaseSuite, frameSuite]

end ReplayTests
