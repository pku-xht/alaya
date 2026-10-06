namespace Alaya.Base

inductive Error where
  /-- The request names something that is not there, is not in the condition the operation
  needs, or is malformed: an unknown entry, a reply where no question waits, a setting that names
  no field, a temperature that is not finite. The caller fixes the request. -/
  | input (message : String)
  /-- The machine lacks something the operation needs: docker or its daemon, an image, restic, an
  API key. The caller fixes the machine. -/
  | environment (message : String)
  /-- Another process is writing the data directory (`Alaya.Base.Lock`); this one may try again when
  it ends. -/
  | busy (message : String)
  /-- The request could not be delivered or its result is unknown; retrying may duplicate work. -/
  | transport (message : String)
  /-- A provider returned an HTTP response; the status and body support retry and diagnostics. -/
  | http (status : Nat) (body : String) (retryAfterMs? : Option Nat := none)
  /-- The provider refused the request because it does not fit in the model's context: what a
run's agent is answered with, not one that stops the driver (`Driver.drive`). The provider's own
words. -/
  | contextExceeded (message : String)
  /-- A provider-specific failure not represented by transport, HTTP, or protocol failures. -/
  | provider (message : String)
  /-- A response or local wire representation did not satisfy the expected chat protocol. -/
  | protocol (message : String)
  /-- The response did not satisfy the requested structured-output contract. -/
  | structuredOutput (message : String)
  /-- Reading, extending, or atomically persisting a cache entry failed. -/
  | cache (message : String)
  /-- Reading or writing the entries, or a workspace snapshot, failed. -/
  | storage (message : String)
  deriving Repr, Inhabited

/-- One line naming the failure, for a command-line front end. -/
def Error.describe : Error -> String
  | .input m => m
  | .environment m => m
  | .busy m => m
  | .transport m => s!"transport: {m}"
  | .http status body _ => s!"http {status}: {body}"
  | .contextExceeded m => s!"context exceeded: {m}"
  | .provider m => s!"provider: {m}"
  | .protocol m => s!"protocol: {m}"
  | .structuredOutput m => s!"structured output: {m}"
  | .cache m => s!"cache: {m}"
  | .storage m => s!"storage: {m}"

/-- What a caller does about a failure; each class has one exit status (`Alaya.App.Cli`). -/
inductive Error.Class where
  /-- Fix the request. -/
  | input
  /-- Fix the machine. -/
  | environment
  /-- Try again later: another command is writing the data directory, or the provider was
  unreachable, throttled, or failing and the retries `Alaya.Base.Retry` makes have run out. -/
  | transient
  /-- The provider refused the request or answered it wrongly; trying again will not help. -/
  | model
  /-- The data directory could not be read or written. -/
  | storage
  deriving Repr, BEq, Inhabited

def Error.Class.toString : Error.Class -> String
  | .input => "input"
  | .environment => "environment"
  | .transient => "transient"
  | .model => "model"
  | .storage => "storage"

/-- An HTTP status worth retrying: a timeout, a conflict, too early, a rate limit, or the
server's own failure. `Alaya.Base.Retry` retries these, and what is still failing after it is
transient. -/
def Error.retryableStatus (status : Nat) : Bool :=
  status == 408 || status == 409 || status == 425 || status == 429 || (500 <= status && status < 600)

def Error.class : Error -> Error.Class
  | .input _ => .input
  | .environment _ => .environment
  | .busy _ | .transport _ => .transient
  | .http status _ _ => if Error.retryableStatus status then .transient else .model
  | .contextExceeded _ | .provider _ | .protocol _ | .structuredOutput _ => .model
  | .cache _ | .storage _ => .storage

abbrev Result (α : Type) := EIO Error α

namespace Result

def fromIO (kind : String -> Error) (action : IO α) : Result α := do
  match ← action.toBaseIO with
  | .ok value => pure value
  | .error error => throw <| kind error.toString

def fromExcept (kind : String -> Error) (result : Except String α) : Result α :=
  match result with
  | .ok value => pure value
  | .error error => throw <| kind error

/-- Runs a typed action in plain `IO`, rendering any typed failure as a user error. -/
def toUserIO (result : Result α) : IO α :=
  result.toIO fun error => IO.userError s!"{repr error}"

end Result
end Alaya.Base
