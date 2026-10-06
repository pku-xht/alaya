import Test.Support.Framework
import Alaya.LLM.Cache
import Alaya.LLM.Chat.Schema
import Alaya.LLM.Model

/-! What the LLM tests share: a model that counts its draws, each a response that says its
number, and a request. -/

namespace LLMSupport

open Alaya Alaya.Base Alaya.LLM

def response (value : Nat) : Chat.Response :=
  { content? := some (toString value) }

/-- A model whose draws are `0`, `1`, … in order, across all its streams, and how many it made. -/
def countingModel : IO (Model × IO Nat) := do
  let count ← IO.mkRef 0
  let model : Model := {
    identity := .mkObj [("model", "test"), ("temperature", 1)]
    sample := fun _ => do
      pure { next := do
        let value ← Result.fromIO Error.cache <| count.modifyGet fun value => (value, value + 1)
        pure <| response value } }
  pure (model, count.get)

def request : Chat.Request := { messages := #[.user "prompt"] }

/-- An action that fails with `errors` in turn, then gives `value`; and how many times it ran. -/
def failing (errors : List Error) (value : α) : IO (Result α × IO Nat) := do
  let attempts ← IO.mkRef 0
  let action : Result α := do
    let attempt ← Result.fromIO Error.cache <| attempts.modifyGet fun n => (n, n + 1)
    match errors[attempt]? with
    | some error => throw error
    | none => pure value
  pure (action, attempts.get)

end LLMSupport
