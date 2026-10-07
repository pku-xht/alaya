import Test.Support.Framework
import Alaya.Agents.HelpStudy

namespace HelpStudyTests
open Testing Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.Agents

def suite : Suite := Testing.suite "agents/help-study" #[
  test "solo and help tools differ only in ask_user" do
    let solo : HelpStudy.Config := {}
    let help : HelpStudy.Config := { base := { questionTypes := #[.openEnded] } }
    assertEqual "solo tools" (solo.tools.map (·.name)) #["bash", "submit", "time_budget"]
    assertEqual "help tools" (help.tools.map (·.name)) #["bash", "submit", "ask_user", "time_budget"],
  test "guidance appears in the first system message with a separate task" do
    let config : HelpStudy.Config := { guidance := "STUDY_POLICY", base := { mode := .codeproof } }
    let messages := HelpStudy.openingMessages config "STUDY_TASK" { system := "Linux", machine := "x86_64" }
    assertEqual "two initial messages" messages.size 2
    match messages[0]! with
    | .system text => check (text.endsWith "STUDY_POLICY") "guidance missing from initial system"
    | _ => fail "first message is not system"
    match messages[1]! with
    | .user text =>
      check (contains text "STUDY_TASK") "task missing"
      check (!contains text "subagent") "model subagent unexpectedly offered"
    | _ => fail "second message is not user",
  test "configuration round trip preserves guidance and question types" do
    let config : HelpStudy.Config := { guidance := "POLICY", base := { questionTypes := #[.openEnded] } }
    match HelpStudy.Config.fromJson config.toJson with
    | .error e => fail e
    | .ok actual =>
      assertEqual "guidance" actual.guidance "POLICY"
      assertEqual "question types" actual.base.questionTypes #[.openEnded],
  test "unknown experimental settings are rejected" do
    match HelpStudy.Config.fromJson (.mkObj [("unexpected", true)]) with
    | .error _ => pure ()
    | .ok _ => fail "unknown config accepted"]

end HelpStudyTests
