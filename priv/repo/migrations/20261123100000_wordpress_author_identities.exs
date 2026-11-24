defmodule Bonfire.WordPress.Repo.Migrations.WordPressAuthorIdentities do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration

  @table "bonfire_wordpress_author"

  def up do
    create_if_not_exists table(@table, primary_key: false) do
      # the site, as `Bonfire.WordPress.Sync.site_key/1` writes it
      add(:site, :text, null: false)
      # the author's id on the site (`wp:author_id` in an export, `author` in its REST API)
      add(:wp_author_id, :text, null: false)
      # the user here who the author's posts come in as; the link goes when the user does
      add_pointer(:user_id, :strong, Needle.Pointer, null: false)
      timestamps()
    end

    create_if_not_exists(unique_index(@table, [:site, :wp_author_id]))
    create_if_not_exists(index(@table, [:user_id]))
  end

  def down do
    drop_if_exists(table(@table))
  end
end
