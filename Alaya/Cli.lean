import Lean.Data.Json
import Alaya.Error

/-!
The `alaya` command line, declared. A command's arguments and flags are a `Spec`: every flag, switch and
positional argument it accepts, and a pure decoder that turns what was given into a typed value.
Declaring a flag and reading it are one act, so the parser knows everything a command accepts:
it refuses what it does not know, never lets a switch take the next token, and writes the help.

Specs compose applicatively. A module that owns some settings owns their flags too
(`Executor.Docker.RunOptions.cli`, `Provider.Choice.cli`), and a command lists the groups it
takes:

```
ContinueArgs.mk <$> dataDir <*> arg "HASH" .string "the state to continue from"
  <*> Provider.Choice.cli <*> Docker.RunOptions.cli <*> flagD "time-budget" .nat 0 "…"
```

A command line is `COMMAND` followed by positionals and flags in any order. A valued flag takes
the next token, or its value after `=`, which is how a value that begins with `--` is written. A
switch takes nothing. `--` ends option parsing. Every problem is collected, so one attempt shows
all of them. `--json` and `--help` are accepted by every command.
-/

namespace Alaya.Cli

/-! ## Values -/

/-- Parses a decimal like `0.2` via the JSON number grammar. -/
def parseFloat? (s : String) : Option Float :=
  match Lean.Json.parse s with
  | .ok json => json.getNum?.toOption.map (·.toFloat)
  | .error _ => none

/-- How the text of a flag or an argument becomes a value. `parse` says what is wrong without
naming the flag; the parser prefixes that. -/
structure Value (α : Type) where
  metavar : String
  parse : String → Except String α

namespace Value

def map (f : α → β) (v : Value α) : Value β := ⟨v.metavar, fun s => f <$> v.parse s⟩

def string (metavar := "TEXT") : Value String := ⟨metavar, .ok⟩

def path (metavar := "PATH") : Value System.FilePath := ⟨metavar, fun s => .ok s⟩

def nat (metavar := "N") : Value Nat := ⟨metavar, fun s =>
  match s.toNat? with
  | some n => .ok n
  | none => .error s!"expects a whole number, got '{s}'"⟩

/-- A finite decimal, in the JSON number grammar. -/
def float (metavar := "X") : Value Float := ⟨metavar, fun s =>
  match parseFloat? s with
  | some x => if x.isFinite then .ok x else .error s!"expects a finite number, got '{s}'"
  | none => .error s!"expects a number, got '{s}'"⟩

/-- One of fixed names. -/
def enum (metavar : String) (cases : List (String × α)) : Value α := ⟨metavar, fun s =>
  match cases.lookup s with
  | some a => .ok a
  | none => .error s!"expects one of {", ".intercalate (cases.map (·.1))}, got '{s}'"⟩

end Value

/-! ## Declarations -/

inductive Shape where
  | switch
  | valued (metavar : String) (repeatable : Bool)
  /-- A positional argument; its `Item.name` is its metavar. -/
  | argument (optional : Bool)
  /-- A flag that no longer exists, refused with `message`. -/
  | removed (message : String)
  deriving Repr, BEq, Inhabited

/-- One declared thing a command line may contain. -/
structure Item where
  name : String
  shape : Shape
  help : String
  required : Bool := false
  /-- The default as help shows it. -/
  default? : Option String := none
  /-- An environment variable read when the flag is absent. -/
  env? : Option String := none
  /-- Items with the same group are alternatives, such as `--task` and `--task-file`. -/
  group? : Option String := none
  deriving Repr, Inhabited

def Item.isFlag (item : Item) : Bool :=
  match item.shape with
  | .argument _ => false
  | _ => true

/-- A command line after tokenizing: what was given, sorted by the items it belongs to. -/
structure Raw where
  /-- Valued flag occurrences, `(name, value)`, in order. -/
  values : Array (String × String) := #[]
  switches : Array String := #[]
  /-- Positional arguments by the metavar they were matched to. -/
  arguments : Array (String × String) := #[]
  env : String → Option String := fun _ => none

private def Raw.valuesOf (raw : Raw) (name : String) : Array String :=
  raw.values.filterMap fun (n, v) => if n == name then some v else none

/-- A declared part of a command line and the value it yields. -/
structure Spec (α : Type) where
  items : Array Item
  decode : Raw → Except (Array String) α

instance : Applicative Spec where
  pure a := ⟨#[], fun _ => .ok a⟩
  map f s := ⟨s.items, fun raw => f <$> s.decode raw⟩
  seq f x :=
    let x := x ()
    ⟨f.items ++ x.items, fun raw =>
      -- Both sides decode, so every problem is reported at once.
      match f.decode raw, x.decode raw with
      | .ok g, .ok a => .ok (g a)
      | .error e, .error e' => .error (e ++ e')
      | .error e, .ok _ => .error e
      | .ok _, .error e => .error e⟩

private def parseAs (v : Value α) (label text : String) : Except (Array String) α :=
  match v.parse text with
  | .ok a => .ok a
  | .error e => .error #[s!"{label} {e}"]

/-- An optional valued flag, falling back to `env` when it is absent. -/
def flag? (name : String) (v : Value α) (help : String) (env? : Option String := none) :
    Spec (Option α) :=
  ⟨#[{ name, shape := .valued v.metavar false, help, env? }], fun raw =>
    match (raw.valuesOf name).back? with
    | some text => some <$> parseAs v s!"--{name}" text
    | none =>
      match env? with
      | some var =>
        match raw.env var with
        | some text => if text.isEmpty then .ok none else some <$> parseAs v var text
        | none => .ok none
      | none => .ok none⟩

/-- Marks every item of `s` required and fails with `message` when it yields nothing. -/
def Spec.required (s : Spec (Option α)) (message : String) : Spec α :=
  ⟨s.items.map ({ · with required := true }), fun raw => do
    match ← s.decode raw with
    | some a => pure a
    | none => throw #[message]⟩

/-- A required valued flag. -/
def flag (name : String) (v : Value α) (help : String) : Spec α :=
  (flag? name v help).required s!"--{name} {v.metavar} is required: {help}"

/-- A valued flag with a default; `shown` is how help prints the default. -/
def flagD [ToString α] (name : String) (v : Value α) (default : α) (help : String)
    (env? : Option String := none) (shown : String := toString default) : Spec α :=
  let s := flag? name v help env?
  ⟨s.items.map ({ · with default? := some shown }), fun raw => (·.getD default) <$> s.decode raw⟩

/-- A flag that may be given any number of times; every value, in order. -/
def repeated (name : String) (v : Value α) (help : String) : Spec (Array α) :=
  ⟨#[{ name, shape := .valued v.metavar true, help }], fun raw =>
    (raw.valuesOf name).mapM (parseAs v s!"--{name}")⟩

def switch (name : String) (help : String) : Spec Bool :=
  ⟨#[{ name, shape := .switch, help }], fun raw => .ok (raw.switches.contains name)⟩

/-- An optional positional argument. Positionals are matched in the order they are declared,
and optional ones come after required ones. -/
def arg? (metavar : String) (v : Value α) (help : String) : Spec (Option α) :=
  ⟨#[{ name := metavar, shape := .argument true, help }], fun raw =>
    match raw.arguments.find? (·.1 == metavar) with
    | some (_, text) => some <$> parseAs v metavar text
    | none => .ok none⟩

def arg (metavar : String) (v : Value α) (help : String) : Spec α :=
  let s := arg? metavar v help
  ⟨s.items.map ({ · with shape := .argument false, required := true }), fun raw => do
    match ← s.decode raw with
    | some a => pure a
    | none => throw #[s!"missing {metavar}: {help}"]⟩

/-- A flag that is gone; giving it is an error that says what to do instead. -/
def removed (name message : String) : Spec Unit :=
  ⟨#[{ name, shape := .removed message, help := "" }], fun _ => .ok ()⟩

/-! ## Text -/

/-- Where free text comes from. Parsing stays pure; the command reads it with `read`. -/
inductive TextSource where
  | inline (text : String)
  | file (path : System.FilePath)
  | stdin
  deriving Repr, BEq, Inhabited

/-- Free text: `--NAME TEXT`, or `--NAME-file FILE`, where FILE `-` is stdin; one of the two. -/
def text (name help : String) : Spec (Option TextSource) :=
  let fileFlag := s!"{name}-file"
  ⟨#[{ name, shape := .valued "TEXT" false, help, group? := some name },
     { name := fileFlag, shape := .valued "FILE" false, group? := some name,
       help := s!"read the {name} from FILE, as it is; - reads stdin" }], fun raw =>
    match (raw.valuesOf name).back?, (raw.valuesOf fileFlag).back? with
    | some _, some _ => .error #[s!"give either --{name} TEXT or --{fileFlag} FILE, not both"]
    | some t, none => .ok (some (.inline t))
    | none, some "-" => .ok (some .stdin)
    | none, some p => .ok (some (.file p))
    | none, none => .ok none⟩

private partial def readAll (stream : IO.FS.Stream) (acc : ByteArray := .empty) : IO ByteArray := do
  let chunk ← stream.read 65536
  if chunk.isEmpty then pure acc else readAll stream (acc ++ chunk)

/-- The text, exactly: a file is read on the host, not trimmed, and must be UTF-8. `name` is
the flag's, for messages. -/
def TextSource.read (name : String) : TextSource → Result String
  | .inline t => pure t
  | source => do
    let (what, action) := match source with
      | .file path => (s!"the {name} file {path}", IO.FS.readBinFile path)
      | _ => (s!"the {name} from stdin", do readAll (← IO.getStdin))
    let bytes ← match ← (Result.fromIO Error.configuration action).toBaseIO with
      | .ok bytes => pure bytes
      | .error _ => throw <| .configuration s!"cannot read {what}"
    match String.fromUTF8? bytes with
    | some t => pure t
    | none => throw <| .configuration s!"{what} is not valid UTF-8"

/-! ## Parsing -/

private def distance (a b : String) : Nat := Id.run do
  let a := a.toList.toArray
  let b := b.toList.toArray
  let mut previous : Array Nat := Array.range (b.size + 1)
  for i in [0:a.size] do
    let mut current : Array Nat := #[i + 1]
    for j in [0:b.size] do
      let cost := if a[i]! == b[j]! then 0 else 1
      current := current.push (min (min (previous[j + 1]! + 1) (current[j]! + 1)) (previous[j]! + cost))
    previous := current
  previous[b.size]!

/-- The closest of `candidates` to `word`, when it is close enough to be a likely typo. -/
def suggest (candidates : Array String) (word : String) : Option String :=
  let best := candidates.foldl (init := none) fun best? c =>
    let d := distance word c
    match best? with
    | some (_, bd) => if d < bd then some (c, d) else best?
    | none => some (c, d)
  match best with
  | some (c, d) => if d ≤ 2 && d < word.length then some c else none
  | none => none

private def didYouMean (candidates : Array String) (word : String) (prefix_ : String := "") : String :=
  match suggest candidates word with
  | some c => s!" (did you mean {prefix_}{c}?)"
  | none => ""

/-- Sorts `argv` into a `Raw` by the declared items, or says everything that does not fit. -/
def tokenize (items : Array Item) (argv : List String) (env : String → Option String := fun _ => none) :
    Except (Array String) Raw := Id.run do
  let mut problems : Array String := #[]
  let mut values : Array (String × String) := #[]
  let mut switches : Array String := #[]
  let mut positional : Array String := #[]
  let flagNames := (items.filter fun i => i.isFlag && !(i.shape matches .removed _)).map (·.name)
  let mut rest := argv
  while true do
    match rest with
    | [] => break
    | "--" :: more =>
      positional := positional ++ more.toArray
      break
    | token :: more =>
      rest := more
      if token.startsWith "--" then
        let body := (token.drop 2).toString
        let (name, inline?) := match body.splitOn "=" with
          | name :: value :: tail => (name, some ("=".intercalate (value :: tail)))
          | _ => (body, none)
        match items.find? fun i => i.isFlag && i.name == name with
        | some { shape := .switch, .. } =>
          if inline?.isSome then problems := problems.push s!"--{name} is a switch and takes no value"
          else switches := switches.push name
        | some { shape := .valued _ repeatable, .. } =>
          let (value?, consumed) := match inline?, more with
            | some v, _ => (some v, false)
            | none, v :: _ => if v.startsWith "--" then (none, false) else (some v, true)
            | none, [] => (none, false)
          if consumed then rest := more.tail
          match value? with
          | none | some "" =>
            problems := problems.push
              s!"--{name} needs a value (write --{name}=VALUE for a value that begins with --)"
          | some v =>
            if !repeatable && values.any (·.1 == name) then
              problems := problems.push s!"--{name} is given more than once"
            else values := values.push (name, v)
        | some { shape := .removed message, .. } =>
          problems := problems.push s!"--{name} is no longer accepted: {message}"
          -- Its value, if it had one, is not an argument.
          if let v :: tail := more then
            if inline?.isNone && !v.startsWith "-" then rest := tail
        | _ =>
          problems := problems.push s!"unknown option --{name}{didYouMean flagNames name "--"}"
          -- A typo of a valued flag keeps its value from reading as a stray argument.
          let likely := (suggest flagNames name).bind fun c => items.find? (·.name == c)
          if let some { shape := .valued .., .. } := likely then
            if let v :: tail := more then
              if inline?.isNone && !v.startsWith "--" then rest := tail
      else if token.startsWith "-" && token.length > 1 then
        problems := problems.push
          s!"unknown option {token} (an argument that begins with - goes after --)"
      else
        positional := positional.push token
  let declared := items.filter fun i => !i.isFlag
  let mut arguments : Array (String × String) := #[]
  for (text, i) in positional.zipIdx do
    match declared[i]? with
    | some item => arguments := arguments.push (item.name, text)
    | none => problems := problems.push s!"unexpected argument '{text}'"
  if problems.isEmpty then .ok { values, switches, arguments, env }
  else .error problems

/-- Parses `argv` (without the command name) against `s`. Pure: the environment is passed in. -/
def Spec.parse (s : Spec α) (argv : List String) (env : String → Option String := fun _ => none) :
    Except (Array String) α := do
  s.decode (← tokenize s.items argv env)

/-- Declaration mistakes: a name declared twice, or a required positional after an optional one. -/
def Spec.check (s : Spec α) : Array String := Id.run do
  let mut problems := #[]
  let mut seen : Array String := #[]
  for item in s.items do
    let key := if item.isFlag then s!"--{item.name}" else item.name
    if seen.contains key then problems := problems.push s!"{key} is declared twice"
    seen := seen.push key
  let positionals := s.items.filter (!·.isFlag)
  let mut optionalSeen := false
  for item in positionals do
    match item.shape with
    | .argument true => optionalSeen := true
    | _ => if optionalSeen then problems := problems.push s!"{item.name} is required but follows an optional argument"
  problems

/-! ## Commands -/

private def errorKind : Error → String
  | .configuration _ => "configuration"
  | .transport _ => "transport"
  | .http .. => "http"
  | .provider _ => "provider"
  | .protocol _ => "protocol"
  | .structuredOutput _ => "structured_output"
  | .cache _ => "cache"
  | .storage _ => "storage"
  | .cancelled => "cancelled"

private def errorJson (error : Error) : Lean.Json :=
  let extra : List (String × Lean.Json) := match error with
    | .http status _ retry? => [("status", status),
        ("retry_after_ms", retry?.map (fun n => (n : Lean.Json)) |>.getD .null)]
    | _ => []
  .mkObj ([("error", .str (errorKind error)), ("message", .str error.describe)] ++ extra)

/-- Where a command writes: each record has a JSON form, for `--json`, and a readable one. -/
structure Out where
  json : Bool

private def emit (line : String) : Result Unit := Result.fromIO Error.storage (IO.println line)

/-- One record: its JSON with `--json`, else `pretty`. -/
def Out.record (out : Out) (json : Lean.Json) (pretty : String) : Result Unit :=
  emit (if out.json then json.compress else pretty)

/-- A line for a person only; nothing is printed with `--json`. -/
def Out.note (out : Out) (pretty : String) : Result Unit :=
  if out.json then pure () else emit pretty

/-- A failure on stderr: `error: …`, or one JSON object with `--json`. For a command that
reports its own failure, as one whose exit status means something else does. -/
def Out.fail (out : Out) (error : Error) : Result Unit :=
  Result.fromIO Error.storage <| do
    (← IO.getStderr).putStrLn (if out.json then (errorJson error).compress else s!"error: {error.describe}")

/-- A command is a spec whose value is its action; the action returns the exit status. -/
structure Command where
  name : String
  summary : String
  examples : Array String := #[]
  spec : Spec (Out → Result UInt32)
  /-- The exit status of a command line that does not parse, when the app's would mean
  something else for this command. -/
  usageExit? : Option UInt32 := none

structure App where
  name : String
  summary : String
  commands : Array Command
  /-- Printed at the end of the overview. -/
  epilog : String := ""
  /-- The exit status of a command line that does not parse. -/
  usageExit : UInt32 := 1
  /-- The exit status of a command that failed. -/
  errorExit : Error → UInt32 := fun _ => 1

/-- Every command takes these. -/
private def builtins : Spec (Bool × Bool) :=
  Prod.mk <$> switch "json" "print JSON: one object per line on stdout, errors as JSON on stderr"
    <*> switch "help" "print this help"

private def Command.full (c : Command) : Spec ((Out → Result UInt32) × Bool × Bool) :=
  Prod.mk <$> c.spec <*> builtins

/-! ## Help -/

private def Item.token (item : Item) : String :=
  match item.shape with
  | .switch => s!"--{item.name}"
  | .valued metavar repeatable => s!"--{item.name} {metavar}" ++ (if repeatable then " …" else "")
  | .argument _ => item.name
  | .removed _ => ""

private def visible (items : Array Item) : Array Item :=
  items.filter fun i => !(i.shape matches .removed _)

/-- `alaya resume HASH --model P:M [OPTIONS]`: the arguments and what is required, with
alternatives grouped; help lists the options. -/
def Command.usage (app : App) (c : Command) : String := Id.run do
  let items := visible c.full.items
  let mut parts : Array String := #[]
  let mut groupsDone : Array String := #[]
  let ordered := items.filter (!·.isFlag) ++ items.filter (fun i => i.isFlag && i.required)
  for item in ordered do
    match item.group? with
    | some g =>
      if !groupsDone.contains g then
        groupsDone := groupsDone.push g
        let members := " | ".intercalate ((items.filter (·.group? == some g)).map (·.token)).toList
        parts := parts.push (if item.required then s!"({members})" else s!"[{members}]")
    | none =>
      let optional := match item.shape with
        | .argument optional => optional
        | _ => !item.required
      parts := parts.push (if optional then s!"[{item.token}]" else item.token)
  " ".intercalate ([app.name, c.name] ++ parts.toList ++ ["[OPTIONS]"])

private def table (rows : Array (String × String)) : Array String :=
  let width := min 30 (rows.foldl (fun w (l, _) => max w l.length) 0)
  rows.map fun (left, right) =>
    if left.length > width then s!"  {left}\n  {"".pushn ' ' width}  {right}"
    else s!"  {left}{"".pushn ' ' (width - left.length)}  {right}"

private def Item.describe (item : Item) : String :=
  let notes := (if item.required && item.isFlag && item.group?.isNone then ["required"] else [])
    ++ (item.default?.map (s!"default {·}")).toList ++ (item.env?.map (s!"env {·}")).toList
  if notes.isEmpty then item.help else s!"{item.help} ({"; ".intercalate notes})"

def Command.help (app : App) (c : Command) : String := Id.run do
  let items := visible c.full.items
  let mut lines := #[s!"usage: {c.usage app}", "", c.summary]
  let arguments := items.filter (!·.isFlag)
  if !arguments.isEmpty then
    lines := lines ++ #["", "arguments:"] ++ table (arguments.map fun i => (i.token, i.describe))
  let flags := items.filter (·.isFlag)
  let flags := flags.filter (·.required) ++ flags.filter (!·.required)
  lines := lines ++ #["", "options:"] ++ table (flags.map fun i => (i.token, i.describe))
  if !c.examples.isEmpty then
    lines := lines ++ #["", "examples:"] ++ c.examples.map (s!"  {·}")
  "\n".intercalate lines.toList

def App.overview (app : App) : String :=
  let lines := #[s!"usage: {app.name} COMMAND [ARGUMENTS] [OPTIONS]", "", app.summary, "", "commands:"]
    ++ table (app.commands.map fun c => (c.name, c.summary))
    ++ #["", s!"`{app.name} help COMMAND` or `{app.name} COMMAND --help` shows a command's arguments and options;",
      s!"`{app.name} help --json` describes every command as JSON."]
    ++ (if app.epilog.isEmpty then #[] else #["", app.epilog])
  "\n".intercalate lines.toList

private def Item.toJson (item : Item) : Lean.Json :=
  let kind := match item.shape with
    | .switch => "switch"
    | .valued .. => "option"
    | .argument _ => "argument"
    | .removed _ => "removed"
  let metavar : Lean.Json := match item.shape with
    | .valued metavar _ => metavar
    | _ => .null
  let optional (value : Option String) : Lean.Json := value.map Lean.Json.str |>.getD .null
  .mkObj [("name", item.name), ("kind", kind), ("metavar", metavar), ("help", item.help),
    ("required", match item.shape with | .argument optional => !optional | _ => item.required),
    ("repeatable", item.shape matches .valued _ true),
    ("default", optional item.default?), ("env", optional item.env?), ("group", optional item.group?)]

/-- Every command, its usage, and its items, for programs that drive the CLI. -/
def App.describe (app : App) : Lean.Json :=
  .mkObj [("name", app.name), ("summary", app.summary), ("commands", .arr <| app.commands.map fun c =>
    .mkObj [("name", c.name), ("summary", c.summary), ("usage", c.usage app),
      ("examples", .arr (c.examples.map Lean.Json.str)),
      ("items", .arr ((visible c.full.items).map (·.toJson)))])]

/-! ## Running -/

/-- Whether `--flag` appears before any `--`, so it counts even on a line that does not parse. -/
private def mentions (argv : List String) (flag : String) : Bool :=
  (argv.takeWhile (· != "--")).contains flag

/-- Parses `argv` for `c` and returns its action and whether `--json` was given. -/
def Command.parse (c : Command) (argv : List String) (env : String → Option String := fun _ => none) :
    Except (Array String) ((Out → Result UInt32) × Bool) := do
  let (action, json, _) ← c.full.parse argv env
  pure (action, json)

/-- Runs a whole command line: help, the command, and its failure, with the exit status. -/
def App.run (app : App) (argv : List String) : IO UInt32 := do
  let json := mentions argv "--json"
  let stderr ← IO.getStderr
  let usageError (problems : Array String) (usage : String) (hint : String) : IO UInt32 := do
    if json then
      stderr.putStrLn (Lean.Json.mkObj [("error", "usage"), ("usage", usage),
        ("problems", .arr (problems.map Lean.Json.str))]).compress
    else
      for p in problems do stderr.putStrLn s!"error: {p}"
      stderr.putStrLn s!"usage: {usage}"
      stderr.putStrLn hint
    pure app.usageExit
  -- A declaration mistake is the program's, and says so before anything runs.
  for c in app.commands do
    let problems := c.full.check
    if !problems.isEmpty then
      stderr.putStrLn s!"internal error: `{c.name}` is declared wrongly: {"; ".intercalate problems.toList}"
      return 70
  let names := app.commands.map (·.name)
  let find (name : String) := app.commands.find? (·.name == name)
  match argv with
  | [] | ["help"] | ["--help"] => IO.println app.overview; pure 0
  | ["help", "--json"] => IO.println app.describe.compress; pure 0
  | ["help", name] =>
    match find name with
    | some c => IO.println (c.help app); pure 0
    | none =>
      usageError #[s!"unknown command {name}{didYouMean names name}"] s!"{app.name} help COMMAND"
        s!"commands: {", ".intercalate names.toList}"
  | name :: rest =>
    let some c := find name
      | usageError #[s!"unknown command {name}{didYouMean names name}"]
          s!"{app.name} COMMAND [ARGUMENTS] [OPTIONS]"
          s!"commands: {", ".intercalate names.toList}"
    if mentions rest "--help" then
      IO.println (c.help app)
      return 0
    let vars := (c.full.items.filterMap (·.env?)).toList
    let mut values : List (String × String) := []
    for var in vars do
      if let some value ← IO.getEnv var then values := (var, value) :: values
    let env := fun var => values.lookup var
    match c.parse rest env with
    | .error problems =>
      let code ← usageError problems (c.usage app) s!"run `{app.name} help {c.name}` for every option"
      pure (c.usageExit?.getD code)
    | .ok (action, json) =>
      match ← (action { json }).toBaseIO with
      | .ok code => pure code
      | .error error =>
        let _ ← ((Out.mk json).fail error).toBaseIO
        pure (app.errorExit error)

end Alaya.Cli
