import Std.Data.HashMap
import Alaya.Cas.Core
import Alaya.Cas.Sha256
import Alaya.Cas.Git

/-! Git owns new objects, tree encoding, refs and garbage collection. Legacy raw SHA-256
objects are read without rewriting the old store or its trajectory identities. -/

namespace Alaya.Cas

private def io (action : IO α) : Result α := Result.fromIO Error.storage action

structure Store where
  root : System.FilePath
  counter : IO.Ref Nat

def Store.gitDir (store : Store) : System.FilePath := store.root / "git"

namespace Store

private def args (store : Store) (command : Array String) : Array String :=
  #["--git-dir=" ++ store.gitDir.toString,
    "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", "-c", "core.logAllRefUpdates=false"] ++ command

/-- Execute plumbing in the store's repository, isolated from the caller's Git configuration. -/
def git (store : Store) (command : Array String) (input : ByteArray := .empty) : Result ByteArray :=
  Git.checked (args store command) input

private def gitText (store : Store) (command : Array String)
    (input : ByteArray := .empty) : Result String := do
  Git.text (← store.git command input)

private def checkHash (hash : Hash) : Result Unit :=
  if validHex hash.hex then pure () else throw <| .storage s!"invalid object hash: {hash.hex}"

private def parseHash (bytes : ByteArray) : Result Hash := do
  let hash : Hash := ⟨(← Git.text bytes).trimAscii.toString⟩
  checkHash hash
  pure hash

/-- Opens an isolated bare SHA-256 repository. The caller's project and index are untouched. -/
def create (root : System.FilePath) : Result Store := do
  io <| IO.FS.createDirAll (root / "tmp")
  let root ← io <| IO.FS.realPath root
  let store : Store := { root, counter := ← io (IO.mkRef 0) }
  if !(← io (store.gitDir / "HEAD").pathExists) then
    let _ ← Git.checked #["init", "--bare", "--object-format=sha256", "--template=",
      store.gitDir.toString]
  if (← store.gitText #["rev-parse", "--show-object-format"]).trimAscii.toString != "sha256" ||
      (← store.gitText #["rev-parse", "--is-bare-repository"]).trimAscii.toString != "true" then
    throw <| .storage "the snapshot store requires a bare SHA-256 Git repository"
  pure store

/-- Used only for ancillary metadata; durable content is written by Git. -/
def atomicWrite (store : Store) (destination : System.FilePath) (bytes : ByteArray) : IO Unit := do
  let suffix ← store.counter.modifyGet fun n => (n, n + 1)
  let temporary := store.root / "tmp" / s!"{suffix}-{← IO.monoNanosNow}.tmp"
  IO.FS.writeBinFile temporary bytes
  IO.FS.createDirAll (destination.parent.getD store.root)
  IO.FS.rename temporary destination

private def objectType? (store : Store) (hash : Hash) : Result (Option String) := do
  checkHash hash
  let output ← store.gitText #["cat-file", "--batch-check=%(objecttype)"] (hash.hex ++ "\n").toUTF8
  let value := output.trimAscii.toString
  if value == s!"{hash.hex} missing" then return none
  if value != "blob" && value != "tree" then
    throw <| .storage s!"unexpected Git object type for {hash.hex}: {value}"
  pure (some value)

private def legacyBytes? (store : Store) (hash : Hash) : Result (Option ByteArray) := do
  checkHash hash
  let path := store.root / "blobs" / (hash.hex.take 2).toString / hash.hex
  if !(← io path.pathExists) then return none
  let bytes ← io <| IO.FS.readBinFile path
  if Sha256.sumHex bytes != hash.hex then
    throw <| .storage s!"corrupt legacy object: {hash.hex}"
  pure (some bytes)

/-- Store the exact bytes as a native Git blob; no attributes, filters or line conversion. -/
def putBytes (store : Store) (bytes : ByteArray) : Result Hash := do
  parseHash (← store.git #["hash-object", "-w", "--stdin", "--no-filters"] bytes)

def getBytes (store : Store) (hash : Hash) : Result (Option ByteArray) := do
  match ← store.objectType? hash with
  | some "blob" => pure (some (← store.git #["cat-file", "blob", hash.hex]))
  | some _ => throw <| .storage s!"object {hash.hex} is not a blob"
  | none => store.legacyBytes? hash

def hasBytes (store : Store) (hash : Hash) : Result Bool := do
  pure ((← store.objectType? hash).isSome || (← store.legacyBytes? hash).isSome)

private def mode : EntryType → String
  | .file => "100644"
  | .executable => "100755"
  | .symlink => "120000"
  | .directory => "040000"

private def typeOfMode (value : String) : Result EntryType :=
  match value with
  | "100644" => pure .file
  | "100755" => pure .executable
  | "120000" => pure .symlink
  | "040000" => pure .directory
  | _ => throw <| .storage s!"unsupported Git tree mode: {value}"

private def rawTree (store : Store) (hash : Hash) : Result Tree := do
  let text ← store.gitText #["ls-tree", "-z", hash.hex]
  let entries ← (text.splitOn "\x00" |>.filter (!·.isEmpty)).toArray.mapM fun record => do
    let parts := record.splitOn "\t"
    let header := parts.head!
    let name := String.intercalate "\t" parts.tail!
    if parts.length < 2 || !validName name then
      throw <| .storage "invalid name in Git snapshot"
    match header.splitOn " " with
    | [permissions, kind, hex] =>
      let type ← typeOfMode permissions
      if kind != (if type == .directory then "tree" else "blob") then
        throw <| .storage "invalid object type in Git snapshot"
      let hash : Hash := ⟨hex⟩
      checkHash hash
      pure ({ name, type, hash } : Entry)
    | _ => throw <| .storage "invalid Git ls-tree response"
  pure (Tree.ofEntries entries)

private def legacyTree (store : Store) (hash : Hash) : Result Tree := do
  let some bytes ← store.legacyBytes? hash
    | throw <| .storage s!"missing tree {hash.hex}"
  let text ← Git.text bytes
  let json ← Result.fromExcept Error.storage (Lean.Json.parse text)
  Result.fromExcept Error.storage (Tree.fromJson json)

private def importBlob (store : Store) (hash : Hash) : Result Hash := do
  match ← store.objectType? hash with
  | some "blob" => pure hash
  | some _ => throw <| .storage s!"expected blob: {hash.hex}"
  | none =>
    let some bytes ← store.legacyBytes? hash
      | throw <| .storage s!"missing blob {hash.hex}"
    store.putBytes bytes

mutual
  /-- Resolve a legacy JSON tree to its native Git tree without rewriting old objects. -/
  partial def importTree (store : Store) (hash : Hash) : Result Hash := do
    match ← store.objectType? hash with
    | some "tree" => pure hash
    | some _ => throw <| .storage s!"expected tree: {hash.hex}"
    | none => store.putTree (← store.legacyTree hash)

  /-- Write a native tree, importing legacy children according to their declared type. -/
  partial def putTree (store : Store) (tree : Tree) : Result Hash := do
    let _ ← Result.fromExcept Error.storage (Tree.fromJson tree.toJson)
    let records ← tree.entries.mapM fun entry => do
      let oid ← if entry.type == .directory then store.importTree entry.hash
        else store.importBlob entry.hash
      let kind := if entry.type == .directory then "tree" else "blob"
      pure s!"{mode entry.type} {kind} {oid.hex}\t{entry.name}\x00"
    parseHash (← store.git #["mktree", "-z"] (String.join records.toList).toUTF8)
end

/-- Trees read through the legacy adapter expose canonical native child identities, so
unchanged old/new snapshots compare equal without treating every file as modified. -/
def getTree (store : Store) (hash : Hash) : Result Tree := do
  store.rawTree (← store.importTree hash)

/-- Reference names remain the public Alaya names; Git path restrictions stay internal. -/
def validRefName (name : String) : Bool :=
  !name.isEmpty && name != "." && name != ".." &&
    name.all fun c => c.isAlphanum || c == '-' || c == '_' || c == '.'

private def checkRefName (name : String) : Result Unit :=
  if validRefName name then pure () else throw <| .storage s!"invalid ref name: {name}"

private def encodeName (name : String) : String :=
  String.join <| name.toUTF8.data.toList.map fun byte =>
    let digits := "0123456789abcdef".toList.toArray
    String.ofList [digits[byte.toNat / 16]!, digits[byte.toNat % 16]!]

private def decodeName (text : String) : Result String := do
  let chars := text.toList.toArray
  if chars.size % 2 != 0 then throw <| .storage "corrupt Git reference name"
  let mut bytes := ByteArray.empty
  for i in [0:chars.size / 2] do
    let digit (c : Char) : Option Nat :=
      if c >= '0' && c <= '9' then some (c.toNat - '0'.toNat)
      else if c >= 'a' && c <= 'f' then some (c.toNat - 'a'.toNat + 10)
      else none
    let some hi := digit chars[2*i]! | throw <| .storage "corrupt Git reference name"
    let some lo := digit chars[2*i+1]! | throw <| .storage "corrupt Git reference name"
    bytes := bytes.push (UInt8.ofNat (hi*16+lo))
  let name ← Git.text bytes
  checkRefName name
  pure name

private def gitRefs (store : Store) : Result (Array (String × Hash × String)) := do
  let output ← store.gitText #["for-each-ref", "--format=%(refname)", "refs/alaya/"]
  (output.splitOn "\n" |>.filter (!·.isEmpty)).toArray.mapM fun ref => do
    match ref.splitOn "/" with
    | ["refs", "alaya", encoded, hex] =>
      let name ← decodeName encoded
      let hash : Hash := ⟨hex⟩
      checkHash hash
      pure (name, hash, ref)
    | _ => throw <| .storage s!"corrupt Alaya Git reference: {ref}"

/-- Enumerate logical hashes, including unchanged legacy state identities. -/
def listRefs (store : Store) : Result (Array (String × Hash)) := do
  let mut refs : Std.HashMap String Hash := {}
  let legacy := store.root / "refs"
  if ← io legacy.pathExists then
    for entry in ← io legacy.readDir do
      checkRefName entry.fileName
      let hash : Hash := ⟨(← io (IO.FS.readFile entry.path)).trimAscii.toString⟩
      checkHash hash
      refs := refs.insert entry.fileName hash
  for (name, hash, _) in ← store.gitRefs do
    refs := refs.insert name hash
  pure (refs.toArray.qsort fun a b => compare a.1 b.1 == .lt)

def getRef? (store : Store) (name : String) : Result (Option Hash) := do
  checkRefName name
  pure ((← store.listRefs).find? (fun entry => entry.1 == name) |>.map (·.2))

private def legacyRef (store : Store) (name : String) : System.FilePath := store.root / "refs" / name

/-- The ref path carries the public hash, while its target pins the corresponding Git
object. This preserves old state IDs even though Git's object hash includes a type header. -/
def setRef (store : Store) (name : String) (hash : Hash) : Result Unit := do
  checkRefName name
  checkHash hash
  let oid ← match ← store.objectType? hash with
    | some _ => pure hash
    | none =>
      let some bytes ← store.legacyBytes? hash
        | throw <| .storage s!"cannot pin missing object {hash.hex}"
      match String.fromUTF8? bytes >>= (fun text => (Lean.Json.parse text).toOption) >>=
          (fun json => (Tree.fromJson json).toOption) with
      | some tree => store.putTree tree
      | none => store.putBytes bytes
  let target := s!"refs/alaya/{encodeName name}/{hash.hex}"
  let mut commands := "start\n"
  for (existing, _, ref) in ← store.gitRefs do
    if existing == name && ref != target then commands := commands ++ s!"delete {ref}\n"
  commands := commands ++ s!"update {target} {oid.hex}\nprepare\ncommit\n"
  let _ ← store.git #["update-ref", "--stdin"] commands.toUTF8
  if ← io (store.legacyRef name).pathExists then io <| IO.FS.removeFile (store.legacyRef name)

def deleteRef (store : Store) (name : String) : Result Unit := do
  checkRefName name
  let mut commands := "start\n"
  for (existing, _, ref) in ← store.gitRefs do
    if existing == name then commands := commands ++ s!"delete {ref}\n"
  let _ ← store.git #["update-ref", "--stdin"] (commands ++ "prepare\ncommit\n").toUTF8
  if ← io (store.legacyRef name).pathExists then io <| IO.FS.removeFile (store.legacyRef name)

/-- Git traverses native tree references. Legacy blobs remain read-only compatibility data.
Run only when no writer is using this store (the same exclusive maintenance boundary as rm). -/
def gc (store : Store) : Result Unit := do
  -- Legacy refs can point at Git-imported children. Pin all live roots before pruning.
  for (name, hash) in ← store.listRefs do
    store.setRef name hash
  let _ ← store.git #["reflog", "expire", "--expire=now", "--all"]
  let _ ← store.git #["gc", "--prune=now"]
  pure ()

end Store
end Alaya.Cas
