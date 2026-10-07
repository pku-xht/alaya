import Test.Framework
import Test.Container
import Alaya

/-! The commands of `alaya`, run as a person runs them: the built binary, a data directory, a
real repository of snapshots and a container. No model is asked: a run is created, read, added
to by a person, and graded at several points by several graders, each on a fork of its own, and
what a command refuses it refuses with its class's exit status. The suite runs the binary as it is built, and does not build it: `lake build alaya tests`
builds both. -/

namespace CommandsTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Lean (Json)

private def binary : System.FilePath := ".lake" / "build" / "bin" / "alaya"

/-- What a command printed, and how it ended. -/
private structure Ran where
  exit : UInt32
  stdout : String
  stderr : String

/-- Runs `alaya` with `arguments`. -/
private def bare (arguments : Array String) : TestM Ran := do
  if !(← binary.pathExists) then fail s!"{binary} is not built: run `lake build alaya`"
  let out ← IO.Process.output { cmd := binary.toString, args := arguments }
  pure { exit := out.exitCode, stdout := out.stdout, stderr := out.stderr }

/-- Runs `alaya COMMAND` on the data directory `data`, with `arguments`. -/
private def alaya (data : System.FilePath) (command : String) (arguments : Array String := #[]) : TestM Ran :=
  bare (#[command, "--data", data.toString] ++ arguments)

/-- Runs a command that must succeed, and gives what it printed. -/
private def ok (data : System.FilePath) (command : String) (arguments : Array String := #[]) : TestM String := do
  let ran ← alaya data command arguments
  if ran.exit != 0 then fail s!"alaya {command} exited {ran.exit}: {ran.stderr}"
  pure ran.stdout

/-- Runs a command that must be refused with `exit`, and gives what it said. -/
private def refused (exit : UInt32) (data : System.FilePath) (command : String)
    (arguments : Array String := #[]) : TestM String := do
  let ran ← alaya data command arguments
  if ran.exit != exit then fail s!"alaya {command} exited {ran.exit}, not {exit}: {ran.stdout}{ran.stderr}"
  pure ran.stderr

private def lines (text : String) : Array String :=
  ((text.splitOn "\n").filter (!·.isEmpty)).toArray

private def records (text : String) : TestM (Array Json) :=
  (lines text).mapM fun line => match Json.parse line with
    | .ok json => pure json
    | .error problem => fail s!"not a line of JSON ({problem}): {line}"

private def field (json : Json) (path : List String) : Json :=
  path.foldl (fun json name => (json.getObjVal? name).toOption.getD .null) json

private def text (json : Json) (path : List String) : String :=
  (field json path).getStr?.toOption.getD (field json path).compress

private def has (haystack needle : String) : Bool := (haystack.splitOn needle).length > 1

/-- The one entry a command that appends prints, with `--json`. -/
private def appended (data : System.FilePath) (command : String) (arguments : Array String) : TestM Json := do
  let made ← records (← ok data command (arguments.push "--json"))
  let some entry := made[0]? | fail s!"alaya {command} printed no entry"
  pure entry

/-- The grader's command: it checks `a.txt` was edited, two checks, the second failing where it
was not. -/
private def check2 : String :=
  "printf '1..2\\nok 1 - ran\\n'; test \"$(cat a.txt)\" = edited && echo 'ok 2 - edited' || echo 'not ok 2 - edited'"

/-- Grades the point `entry` as a person does: stops the call running there, if one is, calls the
grader with `command`, and resumes. Gives the stop, if there was one, the call, and what resume
printed and how it exited. -/
private def gradeAt (data : System.FilePath) (entry command : String) :
    TestM (Option Json × Json × Ran) := do
  let stop ← alaya data "stop" #[entry, "--json"]
  let stopped? ← if stop.exit == 0 then pure (← records stop.stdout)[0]? else pure none
  let at' := (stopped?.map (text · ["entry"])).getD entry
  let called ← appended data "call" #[at', "grader", "--image", testImageReference, "--set", s!"command={command}"]
  pure (stopped?, called, ← alaya data "resume" #[text called ["entry"], "--json"])

/-- A run of MiniSwe over a small project, driven as far as it goes without a model: up to the
agent's first sample. Gives the data directory, the project, the entries `new` and `call` made,
and the entries `resume` appended. -/
private def newRun : TestM (System.FilePath × System.FilePath × Array Json × Array Json) := do
  let data := (← scratch) / "data"
  let project := (← scratch) / "project"
  writeSpec project #[("a.txt", "one\n"), ("src/b.txt", "two\n")]
  let root ← records (← ok data "new" #["--json", project.toString])
  let called ← records (← ok data "call" #["--json", text root.back! ["entry"], "mini-swe", "--set", "task=the task",
    "--image", testImageReference, "--set", "model=gpt-oss-120b", "--set", "context_reserve=7"])
  let resumed ← alaya data "resume" #[text called[0]! ["entry"], "--json"]
  if resumed.exit != 65 || !has resumed.stderr "--provider" then
    fail s!"resume without a provider: {resumed.exit} {resumed.stderr}"
  pure (data, project, root ++ called, ← records resumed.stdout)

def suite : Suite := Testing.suite "commands" #[
  test "new makes a root and the session that waits, call asks for an agent with its configuration, resume opens it, and the readers read it" do
    let (data, _, made, resumed) ← newRun
    assertEqual "the root, the session's call, read and opened, and the agent's call"
      (made.map (text · ["event", "type"])) #["arrived", "arrived", "heard", "opened", "arrived"]
    assertEqual "each after the one before" (made.map (text · ["parent"]))
      (#["null"] ++ (made.pop.map (text · ["entry"])))
    assertEqual "the session, in its frame" (text made[3]! ["frame"]) "[\"session\"]"
    let call := field made[4]! ["event", "notice", "call"]
    let config := field call ["arguments"]
    assertEqual "the call names its program, and its arguments are its configuration, model and task"
      (text call ["name"], text config ["model", "name"], (field config ["context_reserve"]).compress,
        text config ["task"])
      ("mini-swe", "gpt-oss-120b", "7", "the task")
    check ((field config ["name"]) == Json.null) "the name is the call's alone"
    check (has (text call ["environment", "image"]) "@sha256:")
      "the person's call pins its image by its digest"
    check (has (← refused 64 data "new" #["--task", "t", ((← scratch) / "project").toString]) "unknown option --task")
      "new takes no task"
    assertEqual "resume reads the call, opens the agent, which runs uname and reads its inbox"
      (resumed.map (text · ["event", "type"])) #["heard", "opened", "answered", "heard"]
    let tip := text resumed.back! ["entry"]
    -- A prefix names an entry, and `:N` a position of its log.
    let log ← records (← ok data "log" #[(tip.take 10).toString, "--json"])
    assertEqual "the log, and what comes next" (log.map fun record =>
        if (field record ["next"]) != Json.null then text record ["next"] else text record ["event", "type"])
      #["arrived", "arrived", "heard", "opened", "arrived", "heard", "opened", "answered", "heard",
        "next: sample gpt-oss-120b on a request of 2 messages"]
    let plain := lines (← ok data "log" #[tip])
    check (plain[6]?.any (has · "session/mini-swe  open mini-swe, gpt-oss-120b")) s!"the log in lines: {plain}"
    let shown ← records (← ok data "show" #[s!"{tip}:6", "--json"])
    assertEqual "an entry by its position" (text shown[0]! ["entry"]) (text resumed[1]! ["entry"])
    assertEqual "the calls open at it" ((field shown[0]! ["calls"]).getArr?.toOption.map (·.map (text · ["routine", "name"])))
      (some #["session", "mini-swe"])
    assertEqual "the workspace it stands on" (text shown[0]! ["workspace"]) (text made[0]! ["event", "notice", "workspace"])
    check (has (← ok data "show" #[tip, "--request"]) "request: none") "an entry that answers no sample has no request"
    let tree := lines (← ok data "tree")
    assertEqual "the tree" tree.size 2
    check (has tree[0]! "root  mini-swe, gpt-oss-120b" && has tree[1]! "[next: sample gpt-oss-120b on a request of 2 messages]") s!"{tree}"
    assertEqual "the tree as records" (← records (← ok data "tree" #["--json"])).size 9
    assertEqual "no question waits" (← ok data "waiting") ""
    -- The workspace at an entry: listed, read, written out.
    let listed := lines (← ok data "ls" #[tip])
    check (listed.any (·.endsWith "a.txt") && listed.any (·.endsWith "src/")) s!"the root: {listed}"
    check ((lines (← ok data "ls" #[tip, "src"])).any (·.endsWith "src/b.txt")) "a directory"
    assertEqual "a file, byte for byte" (← ok data "cat" #[tip, "src/b.txt"]) "two\n"
    let preview ← records (← ok data "cat" #[tip, "a.txt", "--json"])
    assertEqual "a preview" (text preview[0]! ["kind"], text preview[0]! ["content"]) ("text", "one\n")
    let out := (← scratch) / "out"
    let _ ← ok data "checkout" #[tip, out.toString]
    assertEqual "checked out" (← readSpec out) #[("a.txt", "one\n"), ("src/b.txt", "two\n")]
    let page := (← scratch) / "report.html"
    let _ ← ok data "html" #[page.toString]
    check ((← IO.FS.readFile page).startsWith "<!doctype html>") "the report is a page",

  test "a person's message and change are appended, any point is graded by any grader, and rm removes" do
    let (data, _, _, resumed) ← newRun
    let tip := text resumed.back! ["entry"]
    let told ← appended data "tell" #[tip, "keep the old API"]
    assertEqual "a message" (text told ["event", "notice", "message"], (field told ["position"]).compress)
      ("keep the old API", "9")
    -- A change: the files of a directory, and what changed.
    let edited := (← scratch) / "edited"
    let _ ← ok data "checkout" #[tip, edited.toString]
    IO.FS.writeFile (edited / "a.txt") "edited\n"
    let made ← records (← ok data "commit" #[text told ["entry"], edited.toString, "--message", "by hand", "--json"])
    let some changed := made[0]? | fail "commit printed no change"
    assertEqual "what changed" (text changed ["event", "notice", "summary"]) "M a.txt"
    -- The change reaches no read: a message after it says what changed, and what the person adds.
    assertEqual "and a message after it" (made.map (text · ["event", "notice", "type"])) #["changed", "said"]
    assertEqual "that says so" (text made[1]! ["event", "notice", "message"]) "I changed the workspace:\n  M a.txt\nby hand"
    check (has (← refused 65 data "commit" #[text changed ["entry"], edited.toString]) "no change")
      "a directory with no change is refused"
    assertEqual "the change, between two entries" (lines (← ok data "diff" #[tip, text changed ["entry"]])) #["M a.txt"]
    assertEqual "the file at the change" (← ok data "cat" #[text changed ["entry"], "a.txt"]) "edited\n"
    assertEqual "and before it" (← ok data "cat" #[tip, "a.txt"]) "one\n"
    -- No program is called while the agent runs.
    check (has (← refused 65 data "call" #[text changed ["entry"], "grader", "--image", testImageReference,
      "--set", "command=exit 0"]) "a call is running") "a call while the agent runs"
    -- Graded there: the agent is stopped, the grader called, and resume runs it, with no model.
    let (stopped, called, ran) ← gradeAt data (text changed ["entry"]) check2
    check (stopped.any (text · ["event", "type"] == "broke")) "the agent is stopped first"
    assertEqual "the grader is a call" (text called ["event", "notice", "call", "name"]) "grader"
    assertEqual "a pass exits 0" ran.exit 0
    let ran ← records ran.stdout
    assertEqual "the run reads the call, opens it, runs its command, and it returns its verdict"
      ((ran.extract 0 4).map fun record => text record ["event", "type"]) #["heard", "opened", "answered", "returned"]
    assertEqual "the grader runs in a frame of its own" ((ran.extract 1 4).map fun record =>
      (field record ["event", "frame"]).compress) #["[\"session\",\"grader\"]", "[\"session\",\"grader\"]", "[\"session\",\"grader\"]"]
    let some status := ran.back? | fail "resume printed nothing"
    let verdictOf (status : Json) := (text status ["call"], text status ["value", "status"],
      (field status ["value", "passed"]).compress, (field status ["value", "total"]).compress)
    assertEqual "with the grader's verdict" (verdictOf status) ("grader", "pass", "2", "2")
    let graded := text status ["entry"]
    -- The same grader at the first version, where the file is as it was: a fail, and resume exits 1.
    let (_, _, early) ← gradeAt data tip check2
    assertEqual "a fail exits 1" early.exit 1
    assertEqual "its verdict" ((← records early.stdout).back?.map verdictOf) (some ("grader", "fail", "1", "2"))
    -- Another grader, at the point already graded: called after the first's end, it is a second call.
    let (none, _, again) ← gradeAt data graded "printf '1..1\\nok 1 - other\\n'" | fail "no call runs there"
    assertEqual "a pass exits 0" again.exit 0
    let again ← records again.stdout
    assertEqual "its own verdict" (again.back?.map verdictOf) (some ("grader", "pass", "1", "1"))
    let twice := text again.back! ["entry"]
    -- The second grader follows the first in the same log: the tree shows how the log ends.
    let tree := lines (← ok data "tree")
    check (tree.any (has · "[done: pass 1/1]") && !tree.any (has · "[done: pass 2/2]")) s!"the last verdict: {tree}"
    check ((lines (← ok data "log" #[twice])).any (has · "return pass 2/2")) "the first is in the log, before it"
    -- A grader that prints no TAP is an error, and resume exits 2.
    let (_, _, broken) ← gradeAt data graded "exit 3"
    check (broken.exit == 2 && has broken.stdout "\"status\":\"error\"") s!"an error exits 2: {broken.exit} {broken.stdout}"
    -- Where no call runs, there is nothing to stop and no one to read a message.
    check (has (← refused 65 data "stop" #[twice]) "no call is running") "a stop where no call runs is refused"
    check (has (← refused 65 data "tell" #[twice, "late"]) "no call is running") "and so is a message"
    let over ← alaya data "resume" #[twice]
    check (over.exit == 0 && has over.stderr "grader: done: pass 1/1") s!"resume finds nothing to do: {over.stderr}"
    -- Removing the message removes all that followed it.
    let removed ← records (← ok data "rm" #[text told ["entry"], "--json"])
    check ((field removed[0]! ["removed"]).getNat?.toOption.any (· >= 13)) s!"removed: {removed[0]!.compress}"
    check (has (← refused 65 data "log" #[text changed ["entry"]]) "no entry") "what was removed is gone"
    let tree := lines (← ok data "tree")
    check (tree.any (has · "[done: fail 1/2]") && !tree.any (has · "pass 2/2")) s!"the tree after: {tree}",

  test "rebase copies a graded run into a new data directory, which reads and runs as the old one did" do
    let (data, _, made, resumed) ← newRun
    let told ← appended data "tell" #[text resumed.back! ["entry"], "keep the old API"]
    let edited := (← scratch) / "edited"
    let _ ← ok data "checkout" #[text told ["entry"], edited.toString]
    IO.FS.writeFile (edited / "a.txt") "edited\n"
    let changed ← appended data "commit" #[text told ["entry"], edited.toString]
    let (_, _, ran) ← gradeAt data (text changed ["entry"]) check2
    let graded := text (← records ran.stdout).back! ["entry"]
    IO.FS.createDirAll (data / "cache")
    IO.FS.writeFile (data / "cache" / "0123.json") "a draw"
    let tree := lines (← ok data "tree")
    let target := (← scratch) / "rebased"
    -- A setting no call takes: refused, and nothing is made.
    check (has (← refused 65 data "rebase" #[graded, target.toString, "--set", "no_such_field=1"])
      "fits no call") "an unknown field"
    check (!(← target.pathExists)) "no directory is left"
    let written ← records (← ok data "rebase" #[graded, target.toString, "--json"])
    let some summary := written.back? | fail "rebase printed nothing"
    assertEqual "the whole log holds" (text summary ["held"], text summary ["total"], text summary ["divergence"])
      ("17", "17", "null")
    let tip := text summary ["entry"]
    let note := written[written.size - 2]!
    check (text note ["entry"] == tip && has (text note ["event", "text"]) s!"rebased from {graded}")
      s!"the last entry says where it came from: {note.compress}"
    assertEqual "the old directory as it was" (lines (← ok data "tree")) tree
    -- The new directory reads as the old one: its tree, the file a person changed, the workspace
    -- the grader left, each by the new names of its snapshots.
    check ((lines (← ok target "tree")).any (has · "[done: pass 2/2]")) "the verdict"
    assertEqual "the change" (← ok target "cat" #[s!"{tip}:10", "a.txt"]) "edited\n"
    assertEqual "after the grader's command" (← ok target "cat" #[s!"{tip}:14", "a.txt"]) "edited\n"
    check ((text written[0]! ["event", "notice", "workspace"]) != (text made[0]! ["event", "notice", "workspace"]))
      "a snapshot under a name of the new repository"
    assertEqual "the model cache" (← IO.FS.readFile (target / "cache" / "0123.json")) "a draw"
    let over ← alaya target "resume" #[tip]
    check (over.exit == 0 && has over.stderr "grader: done: pass 2/2") s!"and resumes: {over.stderr}"
    check (has (← refused 65 data "rebase" #[graded, target.toString]) "exists") "a directory that exists is refused"
    -- Without --json: the entries, then what held on stderr.
    let plain ← alaya data "rebase" #[graded, ((← scratch) / "again").toString]
    check (plain.exit == 0 && has plain.stderr "all 17 events hold") s!"what held: {plain.stderr}"
    check ((lines plain.stdout).back?.any (has · "# rebased from")) "the last line is the entry to go on from",

  test "a command says what it refuses, with its class's exit status" do
    let (data, _, made, resumed) ← newRun
    let tip := text resumed.back! ["entry"]
    check (has (← refused 65 data "reply" #[tip, "yes"]) "no question waits") "a reply where no question waits"
    check (has (← refused 65 data "log" #["ffff"]) "no entry matches ffff") "an entry that is not there"
    check (has (← refused 65 data "show" #[s!"{tip}:9"]) "no position 9") "a position past the end of a log"
    check (has (← refused 65 data "resume" #[tip]) "--provider") "a run that samples, with no provider named"
    check (has (← refused 64 data "call" #[tip, "nothing", "--image", testImageReference]) "expects one of")
      "a call of no program"
    check (has (← refused 65 data "call" #[text made[0]! ["entry"], "mini-swe", "--image", testImageReference,
      "--set", "model=gpt-oss-120b"]) "works on a task") "an agent without its task"
    -- What the driver logged before it needed the model is kept: the next `resume` goes on from there.
    let tree := lines (← ok data "tree")
    check (tree.any (has · "[next: sample gpt-oss-120b on a request of 2 messages]")) s!"the tree: {tree}"
    -- A comment: on an entry that goes on, an annotation and no branch; at the end of a log, its
    -- last entry. Either way the run stands as it stood.
    let noted ← appended data "comment" #[text made[1]! ["entry"], "the task could say more"]
    assertEqual "a comment" (text noted ["event", "type"], text noted ["event", "text"])
      ("commented", "the task could say more")
    let tree := lines (← ok data "tree")
    assertEqual "no branch for it" tree.size 3
    check (tree.any (has · "# the task could say more")) s!"the annotation: {tree}"
    let leaf := text ((← records (← ok data "tree" #["--json"])).filter fun row =>
      text row ["status"] != "null" && text row ["entry"] != text noted ["entry"])[0]! ["entry"]
    let last ← appended data "comment" #[leaf, "stopped for want of a provider"]
    let log := lines (← ok data "log" #[text last ["entry"]])
    check (log.any (has · "# stopped for want of a provider") &&
      (log.back?.any (has · "next: sample gpt-oss-120b on a request of 2 messages"))) s!"the log, with its comment: {log}"
    let errors ← records (← refused 65 data "reply" #[tip, "yes", "--json"])
    assertEqual "a failure as JSON, on stderr" (text errors[0]! ["error"]) "input"
    -- A directory that holds no entries is no data directory, whatever else it holds.
    let legacy := (← scratch) / "legacy"
    IO.FS.createDirAll (legacy / "states")
    check (has (← refused 65 legacy "tree") "no data directory") "a directory of another layout"
    check (has (← refused 65 ((← scratch) / "nowhere") "tree") "no data directory") "a path that holds nothing"
    let unknown ← alaya data "frobnicate"
    assertEqual "an unknown command" unknown.exit 64
    let usage ← alaya data "tell" #[tip]
    check (usage.exit == 64 && has usage.stderr "missing TEXT") s!"a missing argument: {usage.stderr}"
    -- The configuration a run would record, without creating one: `config` takes no data directory.
    let shown ← bare #["config", "--program", "mini-vero", "--set", "model=gpt-oss-120b", "--set", "mode=codeproof", "--json"]
    assertEqual "config" shown.exit 0
    let config ← records shown.stdout
    assertEqual "a configuration" (text config[0]! ["program"], text config[0]! ["config", "mode"],
        text config[0]! ["config", "model", "name"])
      ("mini-vero", "codeproof", "gpt-oss-120b")
    let wrong ← bare #["config", "--program", "mini-swe", "--set", "no_such_field=1"]
    check (wrong.exit == 65 && has wrong.stderr "no_such_field") s!"a setting that names no field: {wrong.stderr}"
    let every ← bare #["config", "--json"]
    check (every.exit == 0 && (← records every.stdout).any fun record => text record ["provider", "name"] != "null")
      "with no flags, the programs, models and providers"
]

end CommandsTests
