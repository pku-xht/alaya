import Lean.Data.Json
import Alaya.Base.Error

/-!
A small test framework for reproducible IO tests.

A suite is a set of cases under a name, `layer/module` (`core/replay`, `runtime/driver`), with
what its cases need from the machine beyond Lean: a docker daemon, restic, node, the built
`alaya`. Each case runs with a fresh scratch directory, recreated before the run, so a failure
leaves its state behind for inspection. Failures are collected rather than aborting the run.

`lake exe tests [FILTER …]` runs the cases whose `suite/case` name contains any of the filters,
all of them without one; `--list` names them instead. A suite whose needs the machine does not
meet is skipped and said to be, and a skipped case counts against the exit status as a failure
does, so a run that checked less than it was asked to does not pass.
-/

namespace Testing

open Alaya.Base (Result Error)

/-- Everything a running test can reach: its full name and its private scratch directory. -/
structure Context where
  name : String
  scratch : System.FilePath

abbrev TestM := ReaderT Context IO

/-- Byte arrays print as byte lists in assertion failures. -/
instance : Repr ByteArray := ⟨fun bytes precedence => reprPrec bytes.toList precedence⟩

/-- Something a suite needs from the machine: its name, and why the machine does not meet it,
or `none` when it does. Each is checked once per run. -/
structure Need where
  name : String
  problem? : IO (Option String)

structure Case where
  name : String
  run : Context → IO Unit

structure Suite where
  name : String
  cases : Array Case
  needs : Array Need := #[]

def test (name : String) (body : TestM Unit) : Case :=
  { name, run := fun context => body.run context }

/-- Wraps a plain `IO Unit` test that does not need a scratch directory. -/
def iotest (name : String) (body : IO Unit) : Case :=
  { name, run := fun _ => body }

def suite (name : String) (cases : Array Case) (needs : Array Need := #[]) : Suite :=
  { name, cases, needs }

/-- The test's private scratch directory, fresh at the start of the run. -/
def scratch : TestM System.FilePath :=
  return (← read).scratch

/-- The image of runs a test makes when nothing of the run's runs in it, so it names no real
image; a test that runs a command uses the pinned test image (`Test/Support/Container.lean`). -/
def recordedImage : String := "alaya.test/image@sha256:0"

/-- The workdir of the runs a test makes. -/
def recordedWorkdir : String := "/workspace"

/-! ## Assertions -/

def fail (message : String) : TestM α := do
  throw <| IO.userError s!"{(← read).name}: {message}"

def check (condition : Bool) (message : String) : TestM Unit := do
  if !condition then fail message

def assertEqual [BEq α] [Repr α] (label : String) (actual expected : α) : TestM Unit := do
  if actual != expected then
    fail s!"{label}: expected {repr expected}, got {repr actual}"

/-- Whether `needle` occurs in `haystack`. -/
def contains (haystack needle : String) : Bool :=
  (haystack.splitOn needle).length >= 2

def assertContains (label haystack needle : String) : TestM Unit :=
  check (contains haystack needle) s!"{label}: {needle.quote} is not in {haystack.quote}"

/-- Two texts equal, or where they first differ, with the text around it. -/
def assertStringEq (label actual expected : String) : TestM Unit := do
  if actual == expected then return ()
  let a := actual.toList
  let e := expected.toList
  let mut i := 0
  while i < a.length && i < e.length && a[i]? == e[i]? do
    i := i + 1
  let around (text : List Char) := repr (text.drop (i - min i 10) |>.take 40 |> String.ofList)
  fail s!"{label}: differ at char {i}\n  actual  ({actual.length}): {around a}\n  expected({expected.length}): {around e}"

/-- Runs a typed action, failing the test on a typed error. -/
def assertOk (result : Result α) : TestM α := do
  match ← result.toBaseIO with
  | .ok value => pure value
  | .error error => fail s!"unexpected typed error: {repr error}"

/-- Asserts that a typed action fails with an error accepted by `accepts`. -/
def assertError (label : String) (result : Result α) (accepts : Error → Bool) : TestM Unit := do
  match ← result.toBaseIO with
  | .ok _ => fail s!"{label}: expected an error, got a value"
  | .error error =>
    if !accepts error then fail s!"{label}: wrong error: {repr error}"

/-- Asserts that a typed action fails with an input error whose message has `needle`. -/
def assertInput (label : String) (result : Result α) (needle : String) : TestM Unit :=
  assertError label result fun
    | .input message => contains message needle
    | _ => false

/-- The text a file of the test tree holds, compared with `actual` line by line. With
`ALAYA_REGENERATE` set, the file is written as `actual` first: after a change of design, a
person reviews the difference, as `git diff` shows it. -/
def golden (path : System.FilePath) (actual : Array String) : TestM Unit := do
  if (← IO.getEnv "ALAYA_REGENERATE").isSome then
    IO.FS.writeFile path ("\n".intercalate actual.toList ++ "\n")
  let expected := (← IO.FS.readFile path).splitOn "\n"
  let expected := if expected.getLast? == some "" then expected.dropLast else expected
  for ((line, wanted), i) in (actual.toList.zip expected).zipIdx do
    if line != wanted then
      fail s!"{path}, line {i + 1}:\n  actual:   {line}\n  expected: {wanted}"
  if actual.size != expected.length then
    fail s!"{path}: {actual.size} lines where {expected.length} are expected"

/-! ## Files -/

/-- Deterministic pseudo-random bytes (a linear congruential generator), so tests that need
"arbitrary" content are reproducible across runs and machines. -/
def deterministicBytes (seed length : Nat) : ByteArray := Id.run do
  let mut state := seed * 2654435761 + 1013904223
  let mut bytes := ByteArray.emptyWithCapacity length
  for _ in [0:length] do
    state := (state * 6364136223846793005 + 1442695040888963407) % (2 ^ 64)
    bytes := bytes.push (UInt8.ofNat ((state >>> 33) % 256))
  return bytes

/-- Creates the given files under `base`, making parent directories as needed. Paths are
`/`-separated and relative; contents are written verbatim. -/
def writeSpec (base : System.FilePath) (files : Array (String × String)) : IO Unit := do
  for (path, content) in files do
    let destination := base / (path : System.FilePath)
    IO.FS.createDirAll (destination.parent.getD base)
    IO.FS.writeFile destination content

private partial def readSpecInto (base : System.FilePath) (relative : String)
    (accumulated : Array (String × String)) : IO (Array (String × String)) := do
  let directory := if relative.isEmpty then base else base / (relative : System.FilePath)
  let children ← directory.readDir
  children.foldlM (init := accumulated) fun accumulated child => do
    let path := if relative.isEmpty then child.fileName else s!"{relative}/{child.fileName}"
    match (← child.path.symlinkMetadata).type with
    | .dir => readSpecInto base path accumulated
    | .symlink =>
      let out ← IO.Process.output { cmd := "readlink", args := #[child.path.toString] }
      pure (accumulated.push (path, s!"-> {out.stdout.trimAscii}"))
    | _ => pure (accumulated.push (path, ← IO.FS.readFile child.path))

/-- Reads every regular file under `base` back into sorted `(path, content)` pairs, for
comparing a directory against a `writeSpec`. Symlinks are listed as `(path, "-> target")`. -/
def readSpec (base : System.FilePath) : IO (Array (String × String)) := do
  let entries ← readSpecInto base "" #[]
  pure (entries.qsort fun a b => compare a.1 b.1 == .lt)

/-- Marks a file executable (user+group+other read, user write/execute). -/
def setExecutable (path : System.FilePath) : IO Unit :=
  IO.setAccessRights path {
    user := { read := true, write := true, execution := true }
    group := { read := true, execution := true }
    other := { read := true, execution := true }
  }

def isExecutable (path : System.FilePath) : IO Bool := do
  let out ← IO.Process.output { cmd := "test", args := #["-x", path.toString] }
  pure (out.exitCode == 0)

def createSymlink (target : String) (path : System.FilePath) : IO Unit := do
  let out ← IO.Process.output { cmd := "ln", args := #["-s", target, path.toString] }
  if out.exitCode != 0 then throw <| IO.userError s!"ln -s failed: {out.stderr}"

def readSymlink (path : System.FilePath) : IO String := do
  let out ← IO.Process.output { cmd := "readlink", args := #[path.toString] }
  if out.exitCode != 0 then throw <| IO.userError s!"readlink failed: {out.stderr}"
  pure out.stdout.trimAscii.toString

/-! ## The runner -/

/-- What the command line asks: the filters, and whether to list rather than run. -/
structure Options where
  filters : Array String := #[]
  list : Bool := false

def Options.parse (args : List String) : Options :=
  args.foldl (init := {}) fun options arg =>
    if arg == "--list" then { options with list := true } else { options with filters := options.filters.push arg }

def Options.keeps (options : Options) (name : String) : Bool :=
  options.filters.isEmpty || options.filters.any (contains name ·)

/-- Runs the suites, printing progress, the slowest cases, and a summary. Gives the number of
cases that failed or were skipped, at most 255. -/
def runSuites (suites : Array Suite) (options : Options) : IO UInt32 := do
  if options.list then
    for suite in suites do
      for case in suite.cases do
        let name := s!"{suite.name}/{case.name}"
        if options.keeps name then IO.println name
    return 0
  let scratchRoot : System.FilePath := ".lake" / "test-scratch"
  let mut passed := 0
  let mut failures : Array (String × String) := #[]
  let mut skipped : Array (String × String) := #[]
  let mut times : Array (String × Nat) := #[]
  let mut problems : Std.HashMap String (Option String) := {}
  for suite in suites do
    let cases := suite.cases.filter fun case => options.keeps s!"{suite.name}/{case.name}"
    if cases.isEmpty then continue
    -- What the suite needs, each checked once.
    let mut unmet : Array String := #[]
    for need in suite.needs do
      let problem? ← match problems.get? need.name with
        | some known => pure known
        | none => do
          let found ← need.problem?
          problems := problems.insert need.name found
          pure found
      if let some problem := problem? then unmet := unmet.push s!"{need.name}: {problem}"
    if !unmet.isEmpty then
      let reason := "; ".intercalate unmet.toList
      IO.eprintln s!"SKIP {suite.name} ({cases.size} cases): {reason}"
      skipped := skipped.push (suite.name, s!"{cases.size} cases, {reason}")
      continue
    for case in cases do
      let name := s!"{suite.name}/{case.name}"
      let slug := name.map fun c => if c.isAlphanum || c == '-' || c == '.' then c else '_'
      let scratch := scratchRoot / slug
      if ← scratch.pathExists then IO.FS.removeDirAll scratch
      IO.FS.createDirAll scratch
      let started ← IO.monoMsNow
      match ← (case.run { name, scratch }).toBaseIO with
      | .ok () => passed := passed + 1
      | .error error =>
        failures := failures.push (name, error.toString)
        IO.eprintln s!"FAIL {name}: {error}"
      times := times.push (name, (← IO.monoMsNow) - started)
  -- The slowest cases, so that a slow test is seen when it comes.
  if !times.isEmpty then
    IO.println s!"Slowest of {times.size}, in ms:"
    for (name, ms) in (times.qsort (·.2 > ·.2)).extract 0 10 do
      IO.println s!"  {ms}  {name}"
  for (name, reason) in skipped do
    IO.eprintln s!"skipped {name}: {reason}"
  let skippedCases := skipped.foldl (fun n (_, _) => n + 1) 0
  if failures.isEmpty && skipped.isEmpty then
    IO.println s!"All {passed} tests passed."
  else if failures.isEmpty then
    IO.eprintln s!"All {passed} tests run passed; {skipped.size} suite(s) skipped."
  else
    IO.eprintln s!"\n{failures.size} of {passed + failures.size} tests failed:"
    for (name, message) in failures do
      IO.eprintln s!"  {name}: {message}"
  pure (UInt32.ofNat (min (failures.size + skippedCases) 255))

end Testing
