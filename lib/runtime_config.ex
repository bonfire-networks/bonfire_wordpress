defmodule Bonfire.WordPress.RuntimeConfig do
  use Bonfire.Common.Localise

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  @doc """
  Sets runtime configuration for the extension (typically by reading ENV variables).
  """
  def config do
    import Config

    # offers a WordPress export in the import form's type dropdown, staged by the WXR source
    config :bonfire_social, Bonfire.Social.Import,
      archive_sources: [wordpress: Bonfire.WordPress.Import.WXR]
  end
end
