import Alaya.Model
import Alaya.Chat.Stored
import Std.Sync.Mutex

namespace Alaya.Cache

structure Config where
  directory : System.FilePath
  readOnly : Bool := false

/-- An entry as stored: its key, and its draws in order, each the response and the time the
model took to give it. The time is beside the response and not in it, since a response is stored
here as a log stores it, and a log keeps the time as its entry's. -/
private def responsesToJson (key : String) (responses : Array Chat.Response) : Lean.Json :=
  .mkObj [("key", key), ("draws", .arr <| responses.map fun response =>
    .mkObj [("response", response.toStored), ("elapsed_ms", response.elapsedMs?.getD 0)])]

private def responsesFromJson (key : String) (json : Lean.Json) : Except String (Array Chat.Response) := do
  let storedKey ← json.getObjVal? "key" >>= Lean.Json.getStr?
  if storedKey != key then throw "cached entry key does not match its filename"
  (← json.getObjVal? "draws" >>= Lean.Json.getArr?).mapM fun draw => do
    let response ← Chat.Response.ofStored (← draw.getObjVal? "response")
    pure { response with elapsedMs? := some (← draw.getObjVal? "elapsed_ms" >>= Lean.Json.getNat?) }

/-- An entry's file: the SHA-256 of its key, as everything else in a data directory is named. -/
private def fileName (key : String) : String :=
  s!"{(Hash.ofBytes key.toUTF8).hex}.json"

private def entryPath (config : Config) (key : String) : System.FilePath :=
  config.directory / fileName key

private def load (config : Config) (key : String) : IO (Array Chat.Response) := do
  let path := entryPath config key
  if !(← path.pathExists) then return #[]
  try
    let contents ← IO.FS.readFile path
    let json ← IO.ofExcept <| (Lean.Json.parse contents).mapError fun _ => "cached entry is invalid JSON"
    IO.ofExcept <| responsesFromJson key json
  catch _ =>
    -- A corrupt entry is treated as a miss and replaced on the next successful sample.
    pure #[]

private def save (config : Config) (key : String) (responses : Array Chat.Response) : IO Unit := do
  let path := entryPath config key
  let directory := path.parent.getD config.directory
  IO.FS.createDirAll directory
  -- A name of its own, so two writers never share a half-written file.
  let temporary : System.FilePath :=
    s!"{path}.{← (IO.Process.getPID : BaseIO UInt32)}-{← (IO.monoNanosNow : BaseIO Nat)}.tmp"
  IO.FS.writeFile temporary <| (responsesToJson key responses).pretty
  IO.FS.rename temporary path

/-- Runs a cache-backing IO action, mapping any failure to a typed cache error. -/
private def io (action : IO α) : Result α :=
  Result.fromIO Error.cache action

/-- Replays response sequences from disk and extends them on cache misses. Every response it
gives carries the time its draw took (`elapsedMs?`): measured when the draw is made — the whole
of the call that made it, its retries included — and read back with it after.

Concurrent streams in this process serialize extensions of the same cache entry. Cache directories
must not be written by more than one process at a time. -/
def persistent (inner : Model) (config : Config) : Result Model := do
  let entries ← io <| Std.Mutex.new ({} : Std.HashMap String (Std.Mutex (Array Chat.Response)))
  pure {
    identity := inner.identity
    structuredOutput := inner.structuredOutput
    sample := fun request => do
      let key := inner.cacheKey request
      let loaded ← io <| load config key
      let entry ← entries.atomically fun entries => do
        match (← entries.get).get? key with
        | some entry => pure entry
        | none =>
          let entry ← io <| Std.Mutex.new loaded
          entries.modify fun entries => entries.insert key entry
          pure entry
      let index ← io <| IO.mkRef 0
      let nextN (n : Nat) : Result (Array Chat.Response) := do
        let responses ← entry.atomically fun responses => do
          let current ← io index.get
          let allResponses ← io responses.get
          let cached := (List.range n).foldl (fun cached offset =>
            match allResponses[current + offset]? with
            | some response => cached.push response
            | none => cached) #[]
          let missing := n - cached.size
          if missing == 0 then
            let _ ← io <| index.set (current + n)
            pure cached
          else if config.readOnly then
            throw <| .cache "persistent cache miss in read-only mode"
          else
            let before ← io IO.monoMsNow
            let sampled ← (← inner.sample request).nextN missing
            if sampled.size != missing then
              throw <| .protocol "model returned the wrong number of responses"
            -- Draws made in one call each took that call: what a caller that waited for it saw.
            let took := (← io IO.monoMsNow) - before
            let sampled := sampled.map fun response => { response with elapsedMs? := some took }
            let _ ← io <| responses.modify fun responses => responses ++ sampled
            let saved ← io responses.get
            let _ ← io <| save config key saved
            let _ ← io <| index.set (current + n)
            pure <| cached ++ sampled
        -- Responses loaded from disk carry no mode, so stamp the model's structured-output mode
        -- here, at the single point where responses leave the cache.
        pure <| responses.map fun response => { response with structuredOutput := inner.structuredOutput }
      let next : Result Chat.Response := do
        let responses ← nextN 1
        match responses[0]? with
        | some response => pure response
        | none => throw <| .protocol "model returned no responses"
      pure (Model.Stream.withNative next nextN)
  }

end Alaya.Cache
