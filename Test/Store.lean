import Test.Framework
import Alaya

/-! The store of entries on disk: an entry is a file named by its hash and its parent, written
once; the shape of the forest is one listing of the directory; and a file that is no entry, or
that does not hold what names it, is never taken for one. -/

namespace StoreTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Lean (Json)

private def root : Event Agent := .arrived (.changed (Hash.ofBytes "project".toUTF8) "the project")

private def said (text : String) : Event Agent := .arrived (.said text)

private def fresh : TestM Store := do
  assertOk <| Store.create ((← scratch) / "entries")

/-- Writes `events` as one log, and gives the names of its entries. -/
private def chain (store : Store) (events : Array (Event Agent)) (parent? : Option Hash := none) :
    TestM (Array Hash) := do
  let mut forest ← assertOk store.forest
  let mut parent? := parent?
  let mut made := #[]
  for event in events do
    let (hash, grown) ← assertOk <| store.put forest { parent?, event }
    forest := grown
    parent? := some hash
    made := made.push hash
  pure made

private def storage : Error → Bool
  | .storage _ => true
  | _ => false

private def files (store : Store) : IO (Array String) := do
  pure ((← store.dir.readDir).map (·.fileName) |>.qsort (· < ·))

def suite : Suite := Testing.suite "store" #[
  test "an entry is a file named by its hash and its parent, and a log is the path to it" do
    let store ← fresh
    let made ← chain store #[root, said "a", said "b"]
    let fork ← chain store #[said "c"] (some made[0]!)
    let expected := #[s!"{made[0]!.hex}.root.json", s!"{made[1]!.hex}.{made[0]!.hex}.json",
      s!"{made[2]!.hex}.{made[1]!.hex}.json", s!"{fork[0]!.hex}.{made[0]!.hex}.json"].qsort (· < ·)
    assertEqual "the files" (← files store) expected
    -- The forest, read again from the listing alone.
    let forest ← assertOk store.forest
    assertEqual "every entry, in name order" forest.entries ((made ++ fork).qsort (·.hex < ·.hex))
    assertEqual "the root" forest.roots #[made[0]!]
    assertEqual "a fork is a second child" ((forest.childrenOf made[0]!).qsort (·.hex < ·.hex))
      (#[made[1]!, fork[0]!].qsort (·.hex < ·.hex))
    assertEqual "the ends" (forest.leaves.qsort (·.hex < ·.hex)) (#[made[2]!, fork[0]!].qsort (·.hex < ·.hex))
    assertEqual "the path" (forest.path made[2]!) made
    let log ← assertOk <| store.log forest fork[0]!
    assertEqual "the log of the fork" (log.map fun e => (eventToJson e).compress)
      (#[root, said "c"].map fun e => (eventToJson e).compress),

  test "an entry is written once: the same event after the same entry is the entry there is" do
    let store ← fresh
    let made ← chain store #[root]
    let forest ← assertOk store.forest
    let (first, forest) ← assertOk <| store.put forest { parent? := some made[0]!, event := said "a", elapsedMs := 5 }
    let (again, grown) ← assertOk <| store.put forest { parent? := some made[0]!, event := said "a", elapsedMs := 900 }
    assertEqual "one name" again first
    assertEqual "nothing added" grown.entries.size forest.entries.size
    assertEqual "two files" (← files store).size 2
    assertEqual "the first is kept" (← assertOk <| store.get forest first).elapsedMs 5
    -- A writer whose view of the forest is stale writes the same file again, and harms nothing.
    let stale : Forest := ({} : Forest).add made[0]! none
    let (third, _) ← assertOk <| store.put stale { parent? := some made[0]!, event := said "a", elapsedMs := 7 }
    assertEqual "the same name" third first
    assertEqual "still two files, and no temporary one" (← files store).size 2,

  test "an entry that follows nothing in the store is refused" do
    let store ← fresh
    let forest ← assertOk store.forest
    assertError "no parent" (store.put forest { parent? := some (Hash.ofBytes "nowhere".toUTF8), event := said "a" }) storage
    assertEqual "nothing written" (← files store) #[],

  test "a file that does not hold what names it is refused, and so is an entry that is not there" do
    let store ← fresh
    let made ← chain store #[root, said "a"]
    let forest ← assertOk store.forest
    assertError "absent" (store.get forest (Hash.ofBytes "absent".toUTF8)) storage
    let file := store.dir / s!"{made[1]!.hex}.{made[0]!.hex}.json"
    let other : Entry := { parent? := some made[0]!, event := said "another" }
    IO.FS.writeFile file other.toJson.compress
    assertError "another entry under this name" (store.get forest made[1]!) fun
      | .storage message => (message.splitOn "does not hold what names it").length > 1
      | _ => false
    assertError "and its log" (store.log forest made[1]!) storage
    IO.FS.writeFile file "{\"v\":3,"
    assertError "not JSON" (store.get forest made[1]!) storage
    let entry : Entry := { parent? := some made[0]!, event := said "a" }
    for (field, value) in [("parent", Json.str "../../etc"), ("parent", (7 : Json)),
        ("event", .mkObj [("type", "arrived"), ("notice", .mkObj [("type", "shouted")])]),
        ("event", .mkObj [("type", "vanished")]),
        ("event", .mkObj [("type", "arrived"), ("notice", .mkObj [("type", "replied"), ("to", .arr #[]),
          ("reply", .mkObj [("type", "maybe")])])])] do
      IO.FS.writeFile file (entry.toJson.setObjVal! field value).compress
      assertError s!"a bad {field}: {value.compress}" (store.get forest made[1]!) storage
    -- The root is untouched by all of it.
    assertEqual "the root reads" (eventToJson (← assertOk <| store.get forest made[0]!).event).compress
      (eventToJson root).compress,

  test "a file that is no entry is not in the forest, whatever its name" do
    let store ← fresh
    let made ← chain store #[root]
    let hex := made[0]!.hex
    let other := (Hash.ofBytes "other".toUTF8).hex
    for name in #["notes.txt", s!".{other}.123.tmp", "abc.root.json", s!"{other.toUpper}.root.json",
        s!"{other}.json", s!"{other}.root.json.bak", s!"{other}.rooot.json", s!"{other}.{hex.take 10}.json",
        s!"{other}.root.txt"] do
      IO.FS.writeFile (store.dir / name) "{}"
    let forest ← assertOk store.forest
    assertEqual "only the entry" forest.entries made
    for hostile in #["", "abc", "../../x", other.toUpper, other ++ "0", (other.take 63).toString ++ "g",
        (other.take 63).toString ++ "/"] do
      check (!Hash.valid hostile) s!"{repr hostile} is taken for a digest"
    check (Hash.valid other) "a digest is one",

  test "removing entries takes those named, and is safe to repeat" do
    let store ← fresh
    let made ← chain store #[root, said "a", said "b"]
    let forest ← assertOk store.forest
    assertEqual "what follows an entry, and itself" (forest.subtree made[1]!) #[made[1]!, made[2]!]
    assertOk <| store.delete forest (forest.subtree made[1]!)
    -- Again, with the forest as it was: the files are gone already.
    assertOk <| store.delete forest (forest.subtree made[1]!)
    let forest ← assertOk store.forest
    assertEqual "the root stays" forest.entries #[made[0]!]
    assertEqual "and is the end of its log" forest.leaves #[made[0]!],

  test "file names made by hand that follow each other in a circle are walked once" do
    let store ← fresh
    let a := Hash.ofBytes "a".toUTF8
    let b := Hash.ofBytes "b".toUTF8
    IO.FS.writeFile (store.dir / s!"{a.hex}.{b.hex}.json") "{}"
    IO.FS.writeFile (store.dir / s!"{b.hex}.{a.hex}.json") "{}"
    let forest ← assertOk store.forest
    assertEqual "no root" forest.roots #[]
    assertEqual "what follows an entry ends" (forest.subtree a) #[a, b]
    check ((forest.path a).size <= 3) "and so does the path to it"
    assertError "and neither is an entry" (store.get forest a) storage
]

end StoreTests
