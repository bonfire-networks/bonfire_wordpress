defmodule Bonfire.WordPress do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Bonfire.Common.Modularity.DeclareHelpers

  declare_extension(
    l("WordPress"),
    icon: "bi:wordpress",
    description: l("Import a WordPress site from its export file")
  )

  def repo, do: Config.repo()
end
