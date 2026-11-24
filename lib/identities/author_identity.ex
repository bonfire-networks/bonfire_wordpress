defmodule Bonfire.WordPress.Identities.AuthorIdentity do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "bonfire_wordpress_author" do
    field(:site, :string, primary_key: true)
    field(:wp_author_id, :string, primary_key: true)
    belongs_to(:user, Bonfire.Data.Identity.User, type: Needle.ULID)
    timestamps()
  end
end
