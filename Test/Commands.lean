import Test.Framework
import Test.Container
import Alaya

/-! The commands of `alaya`, run as a person runs them: the built binary, a data directory, a
real repository of snapshots and a container. No model is asked: a run is created, read, added
to by a person, and graded at several points by several graders, each on a fork of its own, and
what a command refuses it refuses with its class's exit status. The suite runs the binary as it is built, and does not build it: `lake build alaya tests`
builds both. -/

namespace CommandsTests

open Testing Alaya
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

/-- A grader that checks `a.txt` was edited: two checks, the second failing where it was not. -/
private def grader : Array String := #["--grader",
  "printf '1..2\\nok 1 - ran\\n'; test \"$(cat a.txt)\" = edited && echo 'ok 2 - edited' || echo 'not ok 2 - edited'"]

/-- A run of MiniSwe over a small project. Gives the data directory, the project, and the entries
`new` made. -/
private def newRun : TestM (System.FilePath × System.FilePath × Array Json) := do
  let data := (← scratch) / "data"
  let project := (← scratch) / "project"
  writeSpec project #[("a.txt", "one\n"), ("src/b.txt", "two\n")]
  let made ← records (← ok data "new" #["--json", "--task", "the task", project.toString,
    "--image", testImageReference, "--agent", "mini-swe", "--model", "gpt-oss-120b",
    "--set", "agent.context_reserve=7"])
  pure (data, project, made)

def suite : Suite := Testing.suite "commands" #[
  test "new makes a run of three entries, its root, its agent's call and its task, and the readers read it" do
    let (data, _, made) ← newRun
    assertEqual "three entries" (made.map (text · ["event", "type"])) #["arrived", "opened", "arrived"]
    assertEqual "at their positions" (made.map (field · ["position"] |>.compress)) #["0", "1", "2"]
    assertEqual "each after the one before" (made.map (text · ["parent"]))
      #["null", text made[0]! ["entry"], text made[1]! ["entry"]]
    assertEqual "the task" (text made[2]! ["event", "notice", "message"]) "the task"
    let config := field made[1]! ["event", "routine", "arguments"]
    assertEqual "the configuration is the agent's call" (text config ["agent", "name"], text config ["model", "name"],
      (field config ["agent", "context_reserve"]).compress) ("mini-swe", "gpt-oss-120b", "7")
    check (has (text config ["environment", "image"]) "@sha256:") "the image is pinned by its digest"
    assertEqual "and names no grader" (field config ["graders"]).compress "null"
    check (has (← refused 64 data "new" #["--task", "t", "--image", testImageReference, "--agent", "mini-swe",
      "--model", "gpt-oss-120b", "--grader", "true"]) "unknown option --grader") "new takes no grader"
    let tip := text made[2]! ["entry"]
    -- A prefix names an entry, and `:N` a position of its log.
    let log ← records (← ok data "log" #[(tip.take 10).toString, "--json"])
    assertEqual "the log, and what comes next" (log.map fun record =>
        if (field record ["next"]) != Json.null then text record ["next"] else text record ["event", "type"])
      #["arrived", "opened", "arrived", "next: a read of the inbox in 0"]
    let plain := lines (← ok data "log" #[tip])
    check (plain[1]?.any (has · "0  open agent: mini-swe, gpt-oss-120b")) s!"the log in lines: {plain}"
    let shown ← records (← ok data "show" #[s!"{tip}:1", "--json"])
    assertEqual "an entry by its position" (text shown[0]! ["entry"]) (text made[1]! ["entry"])
    assertEqual "the calls open at it" ((field shown[0]! ["calls"]).getArr?.toOption.map (·.map (text · ["routine", "name"])))
      (some #["agent"])
    assertEqual "the workspace it stands on" (text shown[0]! ["workspace"]) (text made[0]! ["event", "notice", "workspace"])
    check (has (← ok data "show" #[tip, "--request"]) "request: none") "an entry that answers no sample has no request"
    let tree := lines (← ok data "tree")
    assertEqual "the tree" tree.size 2
    check (has tree[0]! "root  mini-swe, gpt-oss-120b" && has tree[1]! "[next: a read of the inbox in 0]") s!"{tree}"
    assertEqual "the tree as records" (← records (← ok data "tree" #["--json"])).size 3
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
    let (data, _, made) ← newRun
    let tip := text made[2]! ["entry"]
    let told ← appended data "tell" #[tip, "keep the old API"]
    assertEqual "a message" (text told ["event", "notice", "message"], (field told ["position"]).compress)
      ("keep the old API", "3")
    -- A change: the files of a directory, and what changed.
    let edited := (← scratch) / "edited"
    let _ ← ok data "checkout" #[tip, edited.toString]
    IO.FS.writeFile (edited / "a.txt") "edited\n"
    let changed ← appended data "commit" #[text told ["entry"], edited.toString, "--message", "by hand"]
    assertEqual "what changed, and what the person says" (text changed ["event", "notice", "summary"]) "  M a.txt\nby hand"
    check (has (← refused 65 data "commit" #[text changed ["entry"], edited.toString]) "no change")
      "a directory with no change is refused"
    assertEqual "the change, between two entries" (lines (← ok data "diff" #[tip, text changed ["entry"]])) #["M a.txt"]
    assertEqual "the file at the change" (← ok data "cat" #[text changed ["entry"], "a.txt"]) "edited\n"
    assertEqual "and before it" (← ok data "cat" #[tip, "a.txt"]) "one\n"
    -- Graded there: the agent is stopped, the grader assigned, and it runs, with no model.
    let ran ← records (← ok data "grade" (#[text changed ["entry"], "--json"] ++ grader))
    assertEqual "a stop, the grader, its read, its program, and the run's end with its verdict"
      ((ran.extract 0 5).map fun record => text record ["event", "type"])
      #["stopped", "arrived", "heard", "answered", "returned"]
    assertEqual "the notice assigns the grader" (text ran[1]! ["event", "notice", "type"],
      has (text ran[1]! ["event", "notice", "grader", "image"]) "@sha256:") ("assigned", true)
    assertEqual "the grader runs in the run's own frame, where the run ends" ((ran.extract 3 5).map fun record =>
      (field record ["event", "frame"]).compress) #["[]", "[]"]
    let some status := ran.back? | fail "grade printed nothing"
    assertEqual "the agent was stopped" (text status ["status"], text status ["reason"]) ("stopped", "to grade this point")
    let verdictOf (status : Json) := (text status ["verdict", "status"],
      (field status ["verdict", "passed"]).compress, (field status ["verdict", "total"]).compress)
    assertEqual "with the grader's verdict" (verdictOf status) ("pass", "2", "2")
    let graded := text status ["entry"]
    -- The same grader at the first version, where the file is as it was: a fail, and `grade` exits 1.
    let early ← alaya data "grade" (#[tip, "--json"] ++ grader)
    assertEqual "a fail exits 1" early.exit 1
    assertEqual "its verdict" ((← records early.stdout).back?.map verdictOf) (some ("fail", "1", "2"))
    -- Another grader, at the point already graded: a log has one grader, so this one is assigned
    -- on a fork, from the stop, and the first verdict stays where it is.
    let again ← alaya data "grade" #[graded, "--grader", "printf '1..1\\nok 1 - other\\n'", "--json"]
    assertEqual "a pass exits 0" again.exit 0
    let again ← records again.stdout
    assertEqual "the grader is assigned after the stop, beside the first" (text again[0]! ["event", "notice", "type"],
      text again[0]! ["parent"]) ("assigned", text ran[0]! ["entry"])
    assertEqual "its own verdict" (again.back?.map verdictOf) (some ("pass", "1", "1"))
    let twice := text again.back! ["entry"]
    let tree := lines (← ok data "tree")
    check (tree.any (has · "[stopped: pass 2/2]") && tree.any (has · "[stopped: pass 1/1]")) s!"both verdicts: {tree}"
    -- A grader that prints no TAP is an error, and `grade` exits 2.
    let broken ← alaya data "grade" #[graded, "--grader", "exit 3"]
    check (broken.exit == 2 && has broken.stderr "error 0/0") s!"an error exits 2: {broken.exit} {broken.stderr}"
    check (has (← refused 64 data "grade" #[twice]) "--grader CMD is required") "grade needs its grader"
    -- Once the agent is over, there is nothing to stop and no one to read a message.
    check (has (← refused 65 data "stop" #[twice]) "the agent is over") "a stop after the end is refused"
    check (has (← refused 65 data "tell" #[twice, "late"]) "the agent is over") "and so is a message"
    let over ← alaya data "run" #[twice]
    check (over.exit == 0 && has over.stderr "stopped: pass 1/1") s!"run finds nothing to do: {over.stderr}"
    -- Removing the message removes all that followed it, and leaves the other branch.
    let removed ← records (← ok data "rm" #[text told ["entry"], "--json"])
    check ((field removed[0]! ["removed"]).getNat?.toOption.any (· >= 13)) s!"removed: {removed[0]!.compress}"
    check (has (← refused 65 data "log" #[text changed ["entry"]]) "no entry") "what was removed is gone"
    let tree := lines (← ok data "tree")
    check (tree.any (has · "[stopped: fail 1/2]") && !tree.any (has · "pass 2/2")) s!"the tree after: {tree}",

  test "rebase copies a graded run into a new data directory, which reads and runs as the old one did" do
    let (data, _, made) ← newRun
    let told ← appended data "tell" #[text made[2]! ["entry"], "keep the old API"]
    let edited := (← scratch) / "edited"
    let _ ← ok data "checkout" #[text told ["entry"], edited.toString]
    IO.FS.writeFile (edited / "a.txt") "edited\n"
    let changed ← appended data "commit" #[text told ["entry"], edited.toString]
    let graded := text (← records (← ok data "grade" (#[text changed ["entry"], "--json"] ++ grader))).back! ["entry"]
    IO.FS.createDirAll (data / "cache")
    IO.FS.writeFile (data / "cache" / "0123.json") "a draw"
    let tree := lines (← ok data "tree")
    let target := (← scratch) / "rebased"
    -- A setting this build does not know: refused, and nothing is made.
    check (has (← refused 65 data "rebase" #[graded, target.toString, "--set", "agent.no_such_field=1"])
      "no_such_field") "an unknown field"
    check (!(← target.pathExists)) "no directory is left"
    let written ← records (← ok data "rebase" #[graded, target.toString, "--json"])
    let some summary := written.back? | fail "rebase printed nothing"
    assertEqual "the whole log holds" (text summary ["held"], text summary ["total"], text summary ["divergence"])
      ("10", "10", "null")
    let tip := text summary ["entry"]
    let note := written[written.size - 2]!
    check (text note ["entry"] == tip && has (text note ["event", "text"]) s!"rebased from {graded}")
      s!"the last entry says where it came from: {note.compress}"
    assertEqual "the old directory as it was" (lines (← ok data "tree")) tree
    -- The new directory reads as the old one: its tree, the file a person changed, the checkout a
    -- grader left, each by the new names of its snapshots.
    check ((lines (← ok target "tree")).any (has · "[stopped: pass 2/2]")) "the verdict"
    assertEqual "the change" (← ok target "cat" #[s!"{tip}:4", "a.txt"]) "edited\n"
    assertEqual "the grader's checkout" (← ok target "cat" #[s!"{tip}:8", "a.txt"]) "edited\n"
    check ((text written[0]! ["event", "notice", "workspace"]) != (text made[0]! ["event", "notice", "workspace"]))
      "a snapshot under a name of the new repository"
    assertEqual "the model cache" (← IO.FS.readFile (target / "cache" / "0123.json")) "a draw"
    let over ← alaya target "run" #[tip]
    check (over.exit == 0 && has over.stderr "stopped: pass 2/2") s!"and runs: {over.stderr}"
    check (has (← refused 65 data "rebase" #[graded, target.toString]) "exists") "a directory that exists is refused"
    -- Without --json: the entries, then what held on stderr.
    let plain ← alaya data "rebase" #[graded, ((← scratch) / "again").toString]
    check (plain.exit == 0 && has plain.stderr "all 10 events hold") s!"what held: {plain.stderr}"
    check ((lines plain.stdout).back?.any (has · "# rebased from")) "the last line is the entry to go on from",

  test "a command says what it refuses, with its class's exit status" do
    let (data, _, made) ← newRun
    let tip := text made[2]! ["entry"]
    check (has (← refused 65 data "reply" #[tip, "yes"]) "no question waits") "a reply where no question waits"
    check (has (← refused 65 data "log" #["ffff"]) "no entry matches ffff") "an entry that is not there"
    check (has (← refused 65 data "show" #[s!"{tip}:9"]) "no position 9") "a position past the end of a log"
    check (has (← refused 65 data "run" #[tip]) "--provider") "a run that samples, with no provider named"
    -- What the driver logged before it needed the model is kept: the next `run` goes on from there.
    let tree := lines (← ok data "tree")
    check (tree.any (has · "[next: sample a request of 2 messages]")) s!"the tree: {tree}"
    -- A comment: on an entry that goes on, an annotation and no branch; at the end of a log, its
    -- last entry. Either way the run stands as it stood.
    let noted ← appended data "comment" #[tip, "the task could say more"]
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
      (log.back?.any (has · "next: sample a request of 2 messages"))) s!"the log, with its comment: {log}"
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
    let shown ← bare #["config", "--agent", "mini-vero", "--model", "gpt-oss-120b", "--set", "agent.mode=codeproof", "--json"]
    assertEqual "config" shown.exit 0
    let config ← records shown.stdout
    assertEqual "a configuration" (text config[0]! ["agent", "mode"], text config[0]! ["model", "name"])
      ("codeproof", "gpt-oss-120b")
    let wrong ← bare #["config", "--agent", "mini-swe", "--set", "agent.no_such_field=1"]
    check (wrong.exit == 65 && has wrong.stderr "no_such_field") s!"a setting that names no field: {wrong.stderr}"
    let every ← bare #["config", "--json"]
    check (every.exit == 0 && (← records every.stdout).any fun record => text record ["provider", "name"] != "null")
      "with no flags, the agents, models and providers"
]

end CommandsTests
