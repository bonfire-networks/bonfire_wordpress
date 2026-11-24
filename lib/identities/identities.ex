defmodule Bonfire.WordPress.Identities do
  @moduledoc """
  Which user here each of a WordPress site's authors is (the `bonfire_wordpress_author` table), so a sync can bring an author's posts in as the user an export import made for them. The site's REST API names a post's author by id only, never by email, which is what the export import finds or makes users by.

  One row per site and author id. A site is keyed as `Bonfire.WordPress.Sync.site_key/1` writes it, so `http://` and `https://`, or a trailing slash, are the same site.
  """

  import Ecto.Query
  import Untangle

  alias Bonfire.Common.Enums
  alias Bonfire.WordPress.Identities.AuthorIdentity

  @doc """
  Records `user` as the author with id `author_id` on `site`, replacing who it was before. Does nothing without a site or an id.
  """
  def link(site, author_id, user) do
    with site when is_binary(site) and site != "" <- Bonfire.WordPress.Sync.site_key(site),
         author_id when is_binary(author_id) and author_id != "" <- to_id(author_id),
         user_id when is_binary(user_id) <- Enums.id(user) do
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      Bonfire.WordPress.repo().insert(
        %AuthorIdentity{
          site: site,
          wp_author_id: author_id,
          user_id: user_id,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: [set: [user_id: user_id, updated_at: now]],
        conflict_target: [:site, :wp_author_id]
      )
    else
      _ -> {:error, :missing}
    end
  end

  @doc "The user here for the author with id `author_id` on `site`, or nil."
  def user_for(site, author_id) do
    with site when is_binary(site) and site != "" <- Bonfire.WordPress.Sync.site_key(site),
         author_id when is_binary(author_id) and author_id != "" <- to_id(author_id),
         user_id when is_binary(user_id) <-
           Bonfire.WordPress.repo().one(
             from(a in AuthorIdentity,
               where: a.site == ^site and a.wp_author_id == ^author_id,
               select: a.user_id
             )
           ),
         {:ok, user} <- Bonfire.Me.Users.by_id(user_id) do
      user
    else
      {:error, e} ->
        warn(e, "The user linked to a WordPress author could not be loaded")
        nil

      _ ->
        nil
    end
  end

  # an export gives ids as text, the REST API as numbers
  defp to_id(id) when is_integer(id), do: Integer.to_string(id)
  defp to_id(id) when is_binary(id), do: String.trim(id)
  defp to_id(_), do: nil
end
