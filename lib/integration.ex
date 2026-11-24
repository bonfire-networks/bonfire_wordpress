defmodule Bonfire.WordPress do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Bonfire.Common.Modularity.DeclareHelpers

  declare_extension(
    l("WordPress integration"),
    icon: "bi:wordpress",
    description: l("Import content from a WordPress site")
  )

  def repo, do: Config.repo()
end
