import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.Apiyi

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) (echoReasoning := false) : Result Model :=
  ChatCompletions.modelFromEnv "Apiyi" "APIYI_API_KEY" "https://api.apiyi.com/v1" name temperature
    (baseUrlVar? := some "APIYI_BASE_URL")
    (canonicalModelName? := canonicalModelName?) (structuredOutput := structuredOutput)
    (echoReasoning := echoReasoning)

end Alaya.Provider.Apiyi
