import Alaya.Agent
import Alaya.Error

/-! Where runs are kept: a forest of entries. An entry is one event and the entry before it, and
is named by the hash of the two, so a name stands for a whole log, from its root to that entry,
and two logs that share a prefix share its entries: a fork is a second child. Nothing is ever
rewritten, and there are no states: a point of a run is an entry, and its log is the path to
it. See `docs/log-schema.md`.

An entry is a file `<hash>.<parent>.json` in one directory, `root` standing for the parent of a
root, so a single listing gives the shape of the whole forest, and only the entries a command
reads are opened. -/

namespace Alaya

open Lean (Json)

/-- One event of a log, and the entry before it. `elapsedMs` is how long the event took to
happen, as the driver saw it: an operation's time, or a mark's; a run's time is the sum along
its log. It is no part of the entry's name, so the same event after the same entry is one entry,
whenever it happened. -/
structure Entry where
  parent? : Option Hash
  event : Event Agent
  elapsedMs : Nat := 0
  deriving Inhabited

namespace Entry

/-- What names an entry: its parent and its event. -/
def identity (parent? : Option Hash) (event : Event Agent) : Json :=
  .mkObj [("parent", parent?.map (Json.str ·.hex) |>.getD .null), ("event", eventToJson event)]

def hashOf (parent? : Option Hash) (event : Event Agent) : Hash :=
  Hash.ofBytes (identity parent? event).compress.toUTF8

def hash (entry : Entry) : Hash := hashOf entry.parent? entry.event

def toJson (entry : Entry) : Json :=
  .mkObj [("parent", entry.parent?.map (Json.str ·.hex) |>.getD .null),
    ("event", eventToJson entry.event), ("elapsed_ms", entry.elapsedMs)]

def fromJson (json : Json) : Except String Entry := do
  let parent? ← match ← json.getObjVal? "parent" with
    | .null => pure none
    | .str hex => if Hash.valid hex then pure (some ⟨hex⟩) else throw s!"not a digest: {hex}"
    | other => throw s!"a parent is a digest, not {other.compress}"
  pure { parent?, event := ← json.getObjVal? "event" >>= eventFromJson
         elapsedMs := ← json.getObjVal? "elapsed_ms" >>= Json.getNat? }

end Entry

/-- The shape of the forest: every entry, by name, with its parent and its children. -/
structure Forest where
  parents : Std.HashMap Hash (Option Hash) := {}
  children : Std.HashMap Hash (Array Hash) := {}
  /-- Every entry, in name order. -/
  entries : Array Hash := #[]
  deriving Inhabited

namespace Forest

def contains (forest : Forest) (hash : Hash) : Bool := forest.parents.contains hash

def parent? (forest : Forest) (hash : Hash) : Option Hash := (forest.parents.get? hash).join

def childrenOf (forest : Forest) (hash : Hash) : Array Hash := forest.children.getD hash #[]

def roots (forest : Forest) : Array Hash :=
  forest.entries.filter fun hash => forest.parent? hash |>.isNone

/-- The entries no entry follows: the ends of the logs. -/
def leaves (forest : Forest) : Array Hash :=
  forest.entries.filter fun hash => (forest.childrenOf hash).isEmpty

/-- The forest with an entry added. -/
def add (forest : Forest) (hash : Hash) (parent? : Option Hash) : Forest :=
  if forest.contains hash then forest else
  let children := match parent? with
    | some parent => forest.children.insert parent ((forest.childrenOf parent).push hash)
    | none => forest.children
  { parents := forest.parents.insert hash parent?, children
    entries := forest.entries.push hash }

/-- The entries from the root to `hash`, inclusive: the names of its log's events. -/
def path (forest : Forest) (hash : Hash) : Array Hash :=
  let rec climb (hash : Hash) (above : List Hash) (fuel : Nat) : List Hash :=
    match fuel, forest.parent? hash with
    | 0, _ => hash :: above
    | _, none => hash :: above
    | fuel + 1, some parent => climb parent (hash :: above) fuel
  (climb hash [] forest.entries.size).toArray

/-- Every entry that follows `hash`, and itself, each once: the forest is read off file names,
and one made by hand may hold a cycle. -/
def subtree (forest : Forest) (hash : Hash) : Array Hash := Id.run do
  let mut found := #[hash]
  let mut seen : Std.HashSet Hash := {hash}
  let mut next := 0
  while next < found.size do
    for child in forest.childrenOf found[next]! do
      if !seen.contains child then
        seen := seen.insert child
        found := found.push child
    next := next + 1
  return found

/-- The entry a reference names: a name, or any prefix of one that no other name has; and,
after it, `:N`, the entry at position N of its log, from 0. -/
def resolve (forest : Forest) (reference : String) : Except String Hash := do
  let (prefix', position?) := match reference.splitOn ":" with
    | [name, position] => (name, some position)
    | _ => (reference, none)
  if prefix'.isEmpty then throw "an entry is named by its hash, or a prefix of it"
  let hits := forest.entries.filter (·.hex.startsWith prefix')
  let hash ← match hits.toList with
    | [hash] => pure hash
    | [] => throw s!"no entry matches {prefix'}"
    | _ => throw s!"ambiguous entry prefix {prefix'} ({hits.size} entries)"
  match position? with
  | none => pure hash
  | some text =>
    let some position := text.toNat? | throw s!"not a position in a log: {text}"
    let path := forest.path hash
    match path[position]? with
    | some hash => pure hash
    | none => throw s!"the log of {hash.hex.take 12} has {path.size} entries; there is no position {position}"

end Forest

/-- A directory of entries. -/
structure Store where
  dir : System.FilePath

namespace Store

private def io (action : IO α) : Result α := Result.fromIO Error.storage action

private def fileName (hash : Hash) (parent? : Option Hash) : String :=
  s!"{hash.hex}.{(parent?.map (·.hex)).getD "root"}.json"

/-- Opens the store at `dir`, creating the directory if needed. -/
def create (dir : System.FilePath) : Result Store := io do
  IO.FS.createDirAll dir
  pure { dir }

/-- The shape of the forest, from one listing of the directory. -/
def forest (store : Store) : Result Forest := io do
  let mut found : Array (Hash × Option Hash) := #[]
  for entry in ← store.dir.readDir do
    match entry.fileName.splitOn "." with
    | [hex, parent, "json"] =>
      if Hash.valid hex && (parent == "root" || Hash.valid parent) then
        found := found.push (⟨hex⟩, if parent == "root" then none else some ⟨parent⟩)
    | _ => pure ()
  let sorted := found.qsort fun a b => a.1.hex < b.1.hex
  pure <| sorted.foldl (init := {}) fun forest (hash, parent?) => forest.add hash parent?

/-- The entry named `hash`. -/
def get (store : Store) (forest : Forest) (hash : Hash) : Result Entry := do
  let some parent? := forest.parents.get? hash | throw <| .storage s!"no entry {hash.hex}"
  let path := store.dir / fileName hash parent?
  let text ← io (IO.FS.readFile path)
  let json ← Result.fromExcept Error.storage (Json.parse text)
  let entry ← Result.fromExcept (fun m => .storage s!"entry {hash.hex}: {m}") (Entry.fromJson json)
  if entry.hash != hash then throw <| .storage s!"the entry {hash.hex} does not hold what names it"
  pure entry

/-- Writes an entry, unless it is there already, and gives its name and the forest with it. The
write is a rename of a finished temporary file, so a crash leaves no partial entry. -/
def put (store : Store) (forest : Forest) (entry : Entry) : Result (Hash × Forest) := do
  let hash := entry.hash
  if forest.contains hash then return (hash, forest)
  if let some parent := entry.parent? then
    if !forest.contains parent then throw <| .storage s!"no entry {parent.hex} to follow"
  io do
    let destination := store.dir / fileName hash entry.parent?
    let temporary := store.dir / s!".{hash.hex}.{← IO.monoNanosNow}.tmp"
    IO.FS.writeFile temporary entry.toJson.compress
    IO.FS.rename temporary destination
  pure (hash, forest.add hash entry.parent?)

/-- The entries of the log that ends at `hash`, from its root. -/
def entries (store : Store) (forest : Forest) (hash : Hash) : Result (Array Entry) :=
  (forest.path hash).mapM (store.get forest)

/-- The log that ends at `hash`. -/
def log (store : Store) (forest : Forest) (hash : Hash) : Result (Log Agent) := do
  pure ((← store.entries forest hash).map (·.event))

/-- Removes the entries named; the forest is to be read again after. -/
def delete (store : Store) (forest : Forest) (hashes : Array Hash) : Result Unit := io do
  for hash in hashes do
    if let some parent? := forest.parents.get? hash then
      let path := store.dir / fileName hash parent?
      if ← path.pathExists then IO.FS.removeFile path

end Store

end Alaya
