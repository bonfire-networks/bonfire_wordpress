defmodule Bonfire.WordPress.Posts do
  @moduledoc """
  Importing WordPress posts, wherever they come from: an export file (`Bonfire.WordPress.Import.WXR`), and later the site's REST API or a ping from it. Each source turns what it has into a normalised post and calls `import_post/2`, as Ghost's sync, webhooks and embed all go through `Bonfire.Ghost.EmbedHelper.import_article/2`.
  """
  import Untangle

  @typedoc """
  A WordPress post, whatever it came from:
  - `title`: the post's title
  - `link`: where it is on the site, kept as the imported post's canonical URL
  - `published_at`: when it was published there (a `DateTime`), or nil
  - `html`: its body as the site renders it, not yet sanitised
  - `author`: `%{login:, email:, display_name:}` from the site, or nil when it has none (eg. a deleted account)
  - `password_protected?`: true when the site only shows it behind a password (its REST API says so in `content.protected`), so it's refused
  - `media`: its media files on the site, each `%{url:, media_type:, alt:, primary?:}` (`primary?` for its featured image), attached as links to where they are, never downloaded
  """
  @type post :: %{
          required(:title) => String.t() | nil,
          required(:link) => String.t(),
          required(:published_at) => DateTime.t() | nil,
          required(:html) => String.t() | nil,
          required(:author) =>
            %{login: String.t(), email: String.t() | nil, display_name: String.t() | nil} | nil,
          optional(:password_protected?) => boolean(),
          optional(:media) => [
            %{
              url: String.t(),
              media_type: String.t() | nil,
              alt: String.t() | nil,
              primary?: boolean()
            }
          ]
        }

  @doc """
  Imports one WordPress post: as the user here for its author (made by email, see `author/2`), else as `current_user:` (the person importing), with its embedded players kept as links, its body sanitised, backdated to `published_at`, and recorded as coming from `link` (see `Bonfire.Posts.publish_imported/3`). Other `opts` (eg. `boundary:`) go to the publish; posts are public unless they say otherwise.
  """
  @spec import_post(post(), Keyword.t()) :: {:ok, any()} | {:error, any()}
  # a post behind a password is only for those who have it, so it never comes in public
  def import_post(%{password_protected?: true}, _opts), do: {:error, :password_protected}

  def import_post(%{link: link} = post, opts) when is_binary(link) do
    # a post already imported from this link isn't published again (an edit there doesn't update it here yet)
    if MapSet.member?(imported_links([link]), link),
      do: {:ok, :already_imported},
      else: do_import_post(post, opts)
  end

  def import_post(post, _opts), do: error(post, "Not a WordPress post to import")

  @doc "The links among `links` that a post here was already imported from, as a `MapSet`, in one query (see `Bonfire.Posts.publish_imported/3`, which records each post's link)."
  def imported_links(links) when is_list(links) do
    case Bonfire.Common.Utils.maybe_apply(
           Bonfire.Federate.ActivityPub.Peered,
           :list_by_canonical_uris,
           [links],
           fallback_return: []
         ) do
      peereds when is_list(peereds) -> MapSet.new(peereds, & &1.canonical_uri)
      _ -> MapSet.new()
    end
  end

  defp do_import_post(%{link: link} = post, opts) do
    with {:ok, author} <- author(post[:author], opts[:current_user]) do
      {html, embeds} = embeds_as_links(post[:html])

      # TODO: keep images and embedded media inline in the article, where the author put them, rather than only attached to it (needs inline media support in articles)
      Bonfire.Posts.publish_imported(
        author,
        %{
          # an HTML-encoded title (as the site's REST API sends it, eg. `It&#8217;s`) needs no decoding here: publishing reads a title as HTML, as it does a typed one
          name: post[:title],
          html_body: Bonfire.Common.Text.maybe_sane_html(html),
          published_at: post[:published_at],
          canonical_url: link,
          uploaded_media: post_media(author, post[:media]) ++ embed_media(author, embeds)
        },
        opts
        |> Keyword.drop([:current_user])
        |> Keyword.put_new(:boundary, "public")
      )
    end
  end

  @doc """
  The user to import a post as: the user here for its author (by email, see `Bonfire.Me.Users.get_or_create_for_external_author/3`), else the person importing (a post with no author, or one whose author has no email).
  """
  def author(%{email: email} = author, _importer) when is_binary(email) and email != "" do
    login = author[:login]
    name = author[:display_name] || login || email

    Bonfire.Me.Users.get_or_create_for_external_author(
      email,
      name,
      Enum.reject([login, name], &(is_nil(&1) or &1 == ""))
    )
  end

  def author(_author, importer), do: {:ok, importer}

  @doc """
  How many of `authors` (`%{login:, email:, display_name:}`, each with an email) would get a `new:` user here, and how many already have an `existing:` account with their email, without making any: for saying so before importing. One lookup per author.
  """
  def author_counts(authors) when is_list(authors) do
    authors
    |> Enum.filter(&(is_binary(&1[:email]) and &1[:email] != ""))
    |> Enum.uniq_by(& &1.email)
    |> Enum.reduce(%{new: 0, existing: 0}, fn author, acc ->
      if Bonfire.WordPress.repo().exists?(Bonfire.Me.Accounts.Queries.by_email(author.email)),
        do: %{acc | existing: acc.existing + 1},
        else: %{acc | new: acc.new + 1}
    end)
  end

  @doc """
  Makes sure each of `authors` (`%{login:, email:, display_name:}`) has a user here, as `author/2` would when importing their posts, so an import can say up front who it created. Returns the users `created:` and the ones whose email `matched:` an existing account. Authors without an email are left out: their posts are the importer's.
  """
  def ensure_authors(authors) when is_list(authors) do
    authors
    |> Enum.filter(&(is_binary(&1[:email]) and &1[:email] != ""))
    |> Enum.reduce(%{created: [], matched: []}, fn author, acc ->
      existed? =
        Bonfire.WordPress.repo().exists?(Bonfire.Me.Accounts.Queries.by_email(author.email))

      case author(author, nil) do
        {:ok, %{} = user} when existed? ->
          %{acc | matched: [user | acc.matched]}

        {:ok, %{} = user} ->
          %{acc | created: [user | acc.created]}

        other ->
          error(other, "Could not make a user for a WordPress author")
          acc
      end
    end)
    |> Map.new(fn {key, users} -> {key, Enum.reverse(users)} end)
  end

  # An embedded player (an `<iframe>`, as `[embed]` and embed blocks render it) can't come through the sanitiser, so each becomes a link to what it showed, titled by the iframe's title when it has one. Returns the body and the embeds' URLs, in order, to attach to the post.
  defp embeds_as_links(html) when is_binary(html) and html != "" do
    {tree, urls} =
      html
      |> Bonfire.Common.Text.as_html_tree()
      |> LazyHTML.Tree.postwalk([], fn
        {"iframe", attrs, _children} = node, urls ->
          case embed_url(List.keyfind(attrs, "src", 0)) do
            nil ->
              {node, urls}

            url ->
              text =
                case List.keyfind(attrs, "title", 0) do
                  {"title", title} when title != "" -> title
                  _ -> url
                end

              {{"a", [{"href", url}], [text]}, [url | urls]}
          end

        node, urls ->
          {node, urls}
      end)

    if urls == [],
      do: {html, []},
      else: {LazyHTML.Tree.to_html(tree), urls |> Enum.reverse() |> Enum.uniq()}
  end

  defp embeds_as_links(html), do: {html, []}

  # only a web address: a protocol-relative one (`//www.youtube.com/…`) is https
  defp embed_url({"src", "//" <> rest}), do: embed_url({"src", "https://" <> rest})
  defp embed_url({"src", src}), do: web_url(src)
  defp embed_url(_), do: nil

  defp web_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        url

      _ ->
        nil
    end
  end

  defp web_url(_), do: nil

  # the post's media files, each attached as a link to where it is on the site: `Bonfire.Files.ap_receive_attachments/3` saves a remote URL without downloading it (an image, audio or document, never a `Link`, which it would fetch to unfurl), the primary one as the post's image
  defp post_media(author, media) when is_list(media) and media != [] do
    {primary, others} =
      media
      |> Enum.filter(&web_url(&1[:url]))
      |> Enum.split_with(& &1[:primary?])

    {primary, others} =
      case primary do
        [first | more] -> {as_attachment(first), more ++ others}
        [] -> {false, others}
      end

    Bonfire.Files.ap_receive_attachments(author, primary, Enum.map(others, &as_attachment/1))
    |> List.wrap()
  end

  defp post_media(_author, _media), do: []

  defp as_attachment(%{url: url} = media) do
    media_type = media[:media_type] || MIME.from_path(URI.parse(url).path || "")

    %{"type" => as2_type(media_type), "url" => url, "mediaType" => media_type}
    |> Bonfire.Common.Enums.maybe_put("name", media[:alt])
  end

  defp as2_type("image/" <> _), do: "Image"
  defp as2_type("audio/" <> _), do: "Audio"
  defp as2_type("video/" <> _), do: "Video"
  defp as2_type(_), do: "Document"

  # each embed attached as a link, which is unfurled into a preview or player (one request per embed), else kept as the bare link
  defp embed_media(_author, []), do: []

  defp embed_media(author, urls),
    do:
      Bonfire.Files.ap_receive_attachments(
        author,
        false,
        Enum.map(urls, &%{"type" => "Link", "href" => &1})
      )
      |> List.wrap()
end
