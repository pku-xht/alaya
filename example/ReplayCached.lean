import Alaya

/-! Replay this repository's recorded Bija example. The model has no provider transport:
    all responses come from the read-only cache; tools execute in the recorded container.
    Usage: lake env lean --run example/ReplayCached.lean DATA STATE_PREFIX
    Prepare DATA with prepare_replay.py first, so the desired draw is not already present. -/

open Alaya Alaya.Trajectory

/-- The archived Bija request format is a fixed historical fixture. Updating the production
tool schema or view must not pretend its cache entries came from the new policy. -/
private def archivedObservation (o : Output) : Lean.Json :=
  let length := o.output.length
  let fields : List (String × Lean.Json) :=
    if length < 10000 then [("output", o.output)]
    else
      [("output_head", String.ofList (o.output.toList.take 5000)),
       ("output_tail", String.ofList (o.output.toList.drop (length - 5000))),
       ("elided_chars", (length - 10000 : Nat)), ("warning", "Output too long.")]
  let fields := fields ++ [("exit_code", o.exitCode?.map (fun c => Lean.Json.num c.toNat) |>.getD .null)]
  let fields := match o.error? with
    | some error => fields ++ [("error", Lean.Json.str error)]
    | none => fields
  .mkObj fields

private def archivedView (log : Agent.Log) : Agent.Dialogue :=
  log.flatMap fun event =>
    match event with
    | .observation id content =>
      let json := (Output.fromJson? content).map archivedObservation |>.getD content
      #[.tool id (.str json.pretty)]
    | _ => Agent.MiniSwe.view #[event]

def replay (directory statePrefix : String) : Result Unit := do
  let path ← Result.fromIO Error.storage <| IO.FS.realPath directory
  let store ← Cas.Store.create (path / "store")
  let start ← resolve store statePrefix
  let state ← getState store start
  let image ← match state.image? with
    | some image => pure image
    | none => throw <| .configuration "this example requires its recorded container image"
  let transport : Model := {
    identity := .mkObj [("model", .str "closeai/gpt-5.4-mini"), ("temperature", .num 0)]
    sample := fun _ => throw <| .cache "offline replay has no model transport"
  }
  let model ← Cache.persistent transport { directory := path / "cache", readOnly := true }
  -- The recorded Docker Desktop run used the image's default user (root).
  let settings : Executor.Docker.Settings := { image }
  settings.verifyPresent
  let config : Agent.MiniSwe.Config := { task := "" }
  let executor ← Executor.Docker.executor settings config.executor
  try
    let runtime : Runtime := {
      store, workDir := path / "work", executor, model
      agent := { (Agent.MiniSwe.agent executor config) with
        tools := #[Agent.MiniSwe.bashTool, Agent.MiniSwe.submitTool]
        view := archivedView }
    }
    let result ← resume runtime "xmcp:closeai/gpt-5.4-mini" start fun hash => do
      let step ← getState store hash
      Result.fromIO Error.storage <| IO.println s!"STEP {hash.hex} workspace={step.workspace.hex}"
    Result.fromIO Error.storage <| IO.println s!"FINAL {result.hex}"
  finally
    Result.fromIO Error.storage executor.close

def main (args : List String) : IO Unit := do
  match args with
  | [directory, statePrefix] => (replay directory statePrefix).toUserIO
  | _ => throw <| IO.userError "usage: ReplayCached.lean DATA STATE_PREFIX"
