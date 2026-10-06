import Alaya.Cli
import Alaya.Executor.Docker
import Alaya.Provider

/-! The command line's options for what the runtime takes: how a call's containers run, and where
a provider's server listens. The runtime takes plain values; the command line reads them here. -/

namespace Alaya

/-- `--container-user` and `--network`: how a call's containers run. -/
def Executor.Docker.RunOptions.cli : Cli.Spec Executor.Docker.RunOptions :=
  (fun user? network => ({ user?, network } : Executor.Docker.RunOptions))
    <$> Cli.flag? "container-user" (.string "UID:GID")
      "the user commands run as; by default the host user on Linux, the image's own on macOS"
    <*> Cli.flagD "network" (.string "NAME") "none" "the docker network, e.g. bridge; none is no network"


/-- `--url` and `--port`: where this invocation's `dgx` server listens. -/
def Provider.endpointCli : Cli.Spec (Option Provider.Dgx.Endpoint) :=
  let endpoint : Cli.Value Provider.Dgx.Endpoint := ⟨"URL", fun url =>
    (Provider.Dgx.Endpoint.ofUrl url).mapError (s!"is not an endpoint: {·}")⟩
  (fun url? port? => match port? with
      | none => url?
      | some port => some { url?.getD {} with port })
    <$> Cli.flag? "url" endpoint "with --provider dgx: the server, e.g. spark.local:9000"
    <*> Cli.flag? "port" .nat "with --provider dgx: its port, overriding the one in --url"

end Alaya
