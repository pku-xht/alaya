/-! Stubs standing in for Alaya's types. The files have no imports; check them together:
`cat {Stubs,Core,Programs,Replay,Driver,Grade,Test}.lean | lean --stdin` -/
abbrev Json := String
/-- A version of the workspace: the name of a snapshot of it. -/
abbrev Snapshot := String
structure ToolCall where
  name : String
  arguments : Json
  deriving DecidableEq
inductive Message where
  | system (text : String) | user (text : String)
  | assistant (text : String) (calls : List ToolCall) | tool (result : String)
  deriving DecidableEq
abbrev Dialogue := List Message
/-- The settings of a model: which one, and how much it may answer. -/
structure ModelConfig where
  name : String
  maxTokens : Nat
  deriving DecidableEq
/-- The settings of an agent: the tools it offers its model, and how often it asks a model that
failed to answer again. -/
structure AgentConfig where
  tools : List String
  retries : Nat
/-- What an agent is started with: its system message, its settings, and those of its model. -/
structure Config where
  system : String
  agent : AgentConfig
  model : ModelConfig
/-- A configuration as the log holds it. -/
def Config.json (config : Config) : Json :=
  s!"system: \"{config.system}\", " ++
  s!"agent: tools {config.agent.tools}, retries {config.agent.retries}, " ++
  s!"model: {config.model.name}, max tokens {config.model.maxTokens}"
structure Request where
  model : ModelConfig
  messages : Dialogue
  tools : List String
  deriving DecidableEq
/-- The form in which a question wants its answer. -/
inductive Form where
  | yesNo | choice (options : List String) | openEnded
/-- What a person is asked: `yes_no: …`, `choice: … | first | second`, or the question alone,
for an answer in their own words. -/
structure Question where
  text : String
  form : Form
def Question.parse (arguments : Json) : Except String Question :=
  if arguments.startsWith "yes_no: " then pure ⟨(arguments.drop 8).toString, .yesNo⟩
  else if arguments.startsWith "choice: " then
    match (arguments.drop 8).toString.splitOn " | " with
    | text :: first :: second :: more => pure ⟨text, .choice (first :: second :: more)⟩
    | _ => throw "a choice needs at least two options"
  else pure ⟨arguments, .openEnded⟩
/-- What a person answers: in the form asked, or that they cannot. -/
inductive Reply where
  | yes | no | option (number : Nat) | noneOfThese | text (answer : String) | unavailable
/-- Whether the reply is one the question's form asks for. That a person cannot answer fits any. -/
def Question.accepts (question : Question) : Reply → Bool
  | .unavailable => true
  | .yes | .no => (question.form matches .yesNo)
  | .noneOfThese => (question.form matches .choice _)
  | .option number =>
    match question.form with
    | .choice options => 1 ≤ number && number ≤ options.length
    | _ => false
  | .text answer => (question.form matches .openEnded) && !answer.isEmpty
/-- A reply as the tool that asked gives it to its model. -/
def Reply.render : Reply → String
  | .yes => "yes" | .no => "no" | .option number => toString number
  | .noneOfThese => "none_of_above" | .text answer => answer | .unavailable => "unavailable"
structure Response where
  text : String
  toolCalls : List ToolCall := []
structure Output where
  text : String
  workspace : Snapshot               -- the version of the workspace the command left
  exit : Nat := 0                    -- its exit status
/-- What an external program left: its output, and the checkout it ran on, as it left it. -/
structure ExternalOutput where
  exit : Nat
  stdout : String
  checkout : Snapshot
  elapsedMs : Nat
