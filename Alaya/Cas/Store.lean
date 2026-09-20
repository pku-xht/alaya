import Alaya.Cas.Core
import Alaya.Cas.Git

/-! Native Git objects and references. Historical raw stores are handled explicitly by
`Alaya.Cas.Legacy`, never by ordinary snapshot reads or writes. -/

namespace Alaya.Cas

private def io (action : IO α) : Result α := Result.fromIO Error.storage action

structure Store where
  root : System.FilePath
  counter : IO.Ref Nat

def Store.gitDir (store : Store) : System.FilePath := store.root / "git"

namespace Store

private def args (store : Store) (command : Array String) : Array String :=
  #["--git-dir=" ++ store.gitDir.toString,
    "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
    "-c", "core.logAllRefUpdates=false"] ++ command

/-- Execute plumbing in the store repository. -/
def git (store : Store) (command : Array String) (input : ByteArray := .empty) : Result ByteArray :=
  Git.checked (args store command) input

def gitText (store : Store) (command : Array String) (input : ByteArray := .empty) : Result String := do
  Git.text (← store.git command input)

private def checkHash (hash : Hash) : Result Unit :=
  if validHex hash.hex then pure () else throw <| .storage s!"invalid object hash: {hash.hex}"

private def parseHash (bytes : ByteArray) : Result Hash := do
  let hash : Hash := ⟨(← Git.text bytes).trimAscii.toString⟩
  checkHash hash
  pure hash

/-- The repository's native object format (`sha1` or `sha256`). -/
def objectFormat (store : Store) : Result String := do
  pure (← store.gitText #["rev-parse", "--show-object-format"]).trimAscii.toString

/-- Create a bare SHA-1 repository, or open an existing bare SHA-1/SHA-256 repository. -/
def create (root : System.FilePath) : Result Store := do
  io <| IO.FS.createDirAll (root / "tmp")
  let root ← io <| IO.FS.realPath root
  let store : Store := { root, counter := ← io (IO.mkRef 0) }
  if !(← io (store.gitDir / "HEAD").pathExists) then
    let _ ← Git.checked #["init", "--bare", "--object-format=sha1", "--template=",
      store.gitDir.toString]
  let format ← store.objectFormat
  if (format != "sha1" && format != "sha256") ||
      (← store.gitText #["rev-parse", "--is-bare-repository"]).trimAscii.toString != "true" then
    throw <| .storage "the snapshot store requires a bare SHA-1 or SHA-256 Git repository"
  pure store

/-- Atomic write for ancillary metadata; Git writes durable snapshot objects. -/
def atomicWrite (store : Store) (destination : System.FilePath) (bytes : ByteArray) : IO Unit := do
  let suffix ← store.counter.modifyGet fun n => (n, n + 1)
  let temporary := store.root / "tmp" / s!"{suffix}-{← IO.monoNanosNow}.tmp"
  IO.FS.writeBinFile temporary bytes
  IO.FS.createDirAll (destination.parent.getD store.root)
  IO.FS.rename temporary destination

/-- Native type lookup. Commits and tags are legitimate Git objects as well as blobs and trees. -/
def objectType? (store : Store) (hash : Hash) : Result (Option String) := do
  checkHash hash
  let output ← store.gitText #["cat-file", "--batch-check=%(objecttype)"] (hash.hex ++ "\n").toUTF8
  let value := output.trimAscii.toString
  if value == s!"{hash.hex} missing" then return none
  if !["blob", "tree", "commit", "tag"].contains value then
    throw <| .storage s!"unexpected Git object type for {hash.hex}: {value}"
  pure (some value)

private def rejectLegacy (store : Store) (hash : Hash) : Result Unit := do
  checkHash hash
  if hash.hex.length == 64 &&
      (← io (store.root / "blobs" / (hash.hex.take 2).toString / hash.hex).pathExists) then
    throw <| .storage s!"{hash.hex} is a legacy raw object; read or import it explicitly with Alaya.Cas.Legacy"

/-- Store the supplied bytes as a native blob, without working-tree attribute conversion. -/
def putBytes (store : Store) (bytes : ByteArray) : Result Hash := do
  parseHash (← store.git #["hash-object", "-w", "--stdin", "--no-filters"] bytes)

/-- Read a native blob in one binary-safe batch request. Legacy stores require explicit import. -/
def getBytes (store : Store) (hash : Hash) : Result (Option ByteArray) := do
  store.rejectLegacy hash
  let output ← store.git #["cat-file", "--batch"] (hash.hex ++ "\n").toUTF8
  let mut headerEnd := 0
  while headerEnd < output.size && output[headerEnd]! != 10 do
    headerEnd := headerEnd + 1
  let header ← Git.text (output.extract 0 headerEnd)
  match header.splitOn " " with
  | [_, "missing"] => pure none
  | [_, "blob", size] =>
    let some size := size.toNat? | throw <| .storage "invalid Git blob size"
    if output.size != headerEnd + size + 2 then
      throw <| .storage "incomplete Git blob response"
    pure (some (output.extract (headerEnd + 1) (headerEnd + 1 + size)))
  | [_, kind, _] => throw <| .storage s!"object {hash.hex} is a {kind}, not a blob"
  | _ => throw <| .storage "invalid Git cat-file response"

def hasBytes (store : Store) (hash : Hash) : Result Bool := do
  store.rejectLegacy hash
  pure (← store.objectType? hash).isSome

/-- Resolve a native commit, tag, or tree to its tree; no historical conversion takes place. -/
def treeHash (store : Store) (hash : Hash) : Result Hash := do
  store.rejectLegacy hash
  parseHash (← store.git #["rev-parse", "--verify", hash.hex ++ "^{tree}"])

/-- Create a snapshot commit. Workspace capture reuses its HEAD when the tree is unchanged. -/
def commitTree (store : Store) (tree : Hash) (parent? : Option Hash := none) : Result Hash := do
  store.rejectLegacy tree
  if let some parent := parent? then store.rejectLegacy parent
  let command := #["-c", "user.name=Alaya", "-c", "user.email=alaya@localhost",
    "commit-tree", tree.hex] ++
    (parent?.map (fun parent => #["-p", parent.hex]) |>.getD #[]) ++
    #["-m", "Alaya snapshot"]
  parseHash (← store.git command)

private def mode : EntryType → String
  | .file => "100644"
  | .executable => "100755"
  | .symlink => "120000"
  | .directory => "040000"
  | .gitlink => "160000"

private def kind : EntryType → String
  | .directory => "tree"
  | .gitlink => "commit"
  | _ => "blob"

private def typeOfMode (value : String) : Result EntryType :=
  match value with
  | "100644" => pure .file
  | "100755" => pure .executable
  | "120000" => pure .symlink
  | "040000" => pure .directory
  | "160000" => pure .gitlink
  | _ => throw <| .storage s!"unsupported Git tree mode: {value}"

/-- Write native entries in one mktree call. Gitlinks may refer to a commit in another repo. -/
def putTree (store : Store) (tree : Tree) : Result Hash := do
  let _ ← Result.fromExcept Error.storage (Tree.fromJson tree.toJson)
  let records := tree.entries.map fun entry =>
    s!"{mode entry.type} {kind entry.type} {entry.hash.hex}\t{entry.name}\x00"
  parseHash (← store.git #["mktree", "-z", "--missing"] (String.join records.toList).toUTF8)

/-- Read the native directory named by a tree or commit. -/
def getTree (store : Store) (hash : Hash) : Result Tree := do
  let tree ← store.treeHash hash
  let text ← store.gitText #["ls-tree", "-z", tree.hex]
  let entries ← (text.splitOn "\x00" |>.filter (!·.isEmpty)).toArray.mapM fun record => do
    let parts := record.splitOn "\t"
    let header := parts.head!
    let name := String.intercalate "\t" parts.tail!
    if parts.length < 2 || !validName name then
      throw <| .storage "invalid name in Git snapshot"
    match header.splitOn " " with
    | [permissions, objectKind, hex] =>
      let type ← typeOfMode permissions
      if objectKind != kind type then
        throw <| .storage "invalid object type in Git snapshot"
      let hash : Hash := ⟨hex⟩
      checkHash hash
      pure ({ name, type, hash } : Entry)
    | _ => throw <| .storage "invalid Git ls-tree response"
  pure (Tree.ofEntries entries)

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

private def gitRefs (store : Store) (refPrefix : String := "refs/alaya/") :
    Result (Array (String × Hash × String)) := do
  let output ← store.gitText #["for-each-ref", "--format=%(refname)", refPrefix]
  (output.splitOn "\n" |>.filter (!·.isEmpty)).toArray.mapM fun ref => do
    match ref.splitOn "/" with
    | ["refs", "alaya", encoded, hex] =>
      let name ← decodeName encoded
      let hash : Hash := ⟨hex⟩
      checkHash hash
      pure (name, hash, ref)
    | _ => throw <| .storage s!"corrupt Alaya Git reference: {ref}"

/-- Enumerate active native Alaya refs. Old raw ref files remain untouched and unenumerated. -/
def listRefs (store : Store) : Result (Array (String × Hash)) := do
  pure <| ((← store.gitRefs).map fun (name, hash, _) => (name, hash)).qsort
    (fun a b => compare a.1 b.1 == .lt)

def getRef? (store : Store) (name : String) : Result (Option Hash) := do
  checkRefName name
  pure ((← store.gitRefs s!"refs/alaya/{encodeName name}/")[0]?.map fun (_, hash, _) => hash)

/-- Atomically replace this named native ref. Updates to one name must be serialized. -/
def setRef (store : Store) (name : String) (hash : Hash) : Result Unit := do
  checkRefName name
  store.rejectLegacy hash
  let target := s!"refs/alaya/{encodeName name}/{hash.hex}"
  let mut commands := "start\n"
  for (_, _, ref) in ← store.gitRefs s!"refs/alaya/{encodeName name}/" do
    if ref != target then commands := commands ++ s!"delete {ref}\n"
  commands := commands ++ s!"update {target} {hash.hex}\nprepare\ncommit\n"
  let _ ← store.git #["update-ref", "--stdin"] commands.toUTF8
  pure ()

def deleteRef (store : Store) (name : String) : Result Unit := do
  checkRefName name
  let mut commands := "start\n"
  for (_, _, ref) in ← store.gitRefs s!"refs/alaya/{encodeName name}/" do
    commands := commands ++ s!"delete {ref}\n"
  let _ ← store.git #["update-ref", "--stdin"] (commands ++ "prepare\ncommit\n").toUTF8
  pure ()

/-- Collect unreachable Git objects during exclusive maintenance. Commit ancestry is retained
through live refs. Explicit legacy import refs pin their converted objects separately. -/
def gc (store : Store) : Result Unit := do
  let _ ← store.git #["reflog", "expire", "--expire=now", "--all"]
  let _ ← store.git #["gc", "--prune=now"]
  pure ()

end Store
end Alaya.Cas
