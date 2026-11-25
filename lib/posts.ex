defmodule Bonfire.WordPress.Posts do
  @moduledoc """
  Importing WordPress posts, wherever they come from: an export file (`Bonfire.WordPress.Import.WXR`), and later the site's REST API or a ping from it. Each source turns what it has into a normalised post and calls `import_post/2`, as Ghost's sync, webhooks and embed all go through `Bonfire.Ghost.EmbedHelper.import_article/2`.
  """
  import Untangle
  require Bonfire.Common.Config
  alias Bonfire.Classify.Routing

  @typedoc """
  A WordPress post, whatever it came from:
  - `title`: the post's title
  - `link`: where it is on the site, kept as the imported post's canonical URL
  - `published_at`: when it was published there (a `DateTime`), or nil
  - `html`: its body as the site renders it, not yet sanitised
  - `author`: `%{id:, login:, email:, display_name:}` from the site, or nil when it has none (eg. a deleted account). An export gives all four; the site's REST API only `id`, its author id there
  - `password_protected?`: true when the site only shows it behind a password (its REST API says so in `content.protected`), so it's refused
  - `media`: its media files on the site, each `%{url:, media_type:, alt:, primary?:}` (`primary?` for its featured image), attached as links to where they are, never downloaded. One that is an upload on the site (with a `wp_id:`, see `images`) comes in as that upload's `Media`
  - `images`: the uploads its body shows (from an export, which lists them), each `%{wp_id:, url:, width:, urls:, srcs:, media_type:, alt:, caption:, description:}`: shown at `url` (the largest size it shows), `urls` being every size the upload has and `srcs` each `src` that shows it in the body. Each upload is one `Media` whatever posts show it, at the largest size any of them shows, and each `src` is replaced by its `Media`'s URL, so the post shows it once, where it is (see `Bonfire.Files.inline_url/1`)
  - `categories`: its categories on the site, each `%{name:, slug:}`, in the site's order, which place it in topics when it's imported into a group (see `import_post/2`)
  """
  @type post :: %{
          required(:title) => String.t() | nil,
          required(:link) => String.t(),
          required(:published_at) => DateTime.t() | nil,
          required(:html) => String.t() | nil,
          required(:author) =>
            %{
              optional(:id) => String.t() | integer() | nil,
              optional(:login) => String.t() | nil,
              optional(:email) => String.t() | nil,
              optional(:display_name) => String.t() | nil
            }
            | nil,
          optional(:password_protected?) => boolean(),
          optional(:categories) => [%{name: String.t(), slug: String.t() | nil}],
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
  Imports one WordPress post: as the user here for its author (made by email, or found by their author id on `site:`, see `author/3`), else as `current_user:` (the person importing), with its embedded players kept as links, its body sanitised, backdated to `published_at`, and recorded as coming from `link` (see `Bonfire.Posts.publish_imported/3`). Other `opts` (eg. `boundary:`) go to the publish; posts are public unless they say otherwise.

  A post already imported from `link` is left as it is, unless `update: true` (as a sync passes): then its title and body become the site's, overwriting an edit made here, and it's placed where its categories now say.

  With `post_into_group:` (a group's or topic's id), the post goes into that group: into the topic its first category has there, boosted into the topics of its others, else into the group itself, shared as the group shares its posts. Topics are found, never made here (see `ensure_topics/3`). The author is made a member, and allowed to post in each topic (see `Bonfire.Classify.Routing.ensure_author_can_post/3`).
  """
  @spec import_post(post(), Keyword.t()) :: {:ok, any()} | {:error, any()}
  # a post behind a password is only for those who have it, so it never comes in public
  def import_post(%{password_protected?: true}, _opts), do: {:error, :password_protected}

  def import_post(%{link: link} = post, opts) when is_binary(link) do
    cond do
      not MapSet.member?(imported_links([link]), link) -> do_import_post(post, opts)
      # a sync brings in an edit made on the site: the site wins, so an edit made here is overwritten
      opts[:update] -> update_post(post, opts)
      # an export import, or importing the same post again, leaves it as it is
      true -> {:ok, :already_imported}
    end
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

  @doc """
  Hides the posts imported from `site` whose link isn't among `published` (the links of every post the site publishes, see `Bonfire.WordPress.API.published_links/1`), as Ghost does with an article unpublished or deleted: out of the feeds, with its replies and likes kept, by its creator here (see `Bonfire.Posts.retract_imported/2`). A sync shows it again when the site publishes it again. Returns how many were hidden.

  An empty `published` hides nothing, since a site that answers with no posts at all is more likely broken than emptied.
  """
  def hide_gone(_site, []) do
    warn("The WordPress site lists no published posts, so no imported post is hidden")
    {:ok, 0}
  end

  def hide_gone(site, published) when is_binary(site) and is_list(published) do
    published = MapSet.new(published, &link_key/1)

    gone =
      site
      |> imported_from()
      |> Enum.reject(fn {_id, link, _creator_id} -> MapSet.member?(published, link_key(link)) end)

    creators =
      gone
      |> Enum.map(&elem(&1, 2))
      |> Enum.uniq()
      |> Map.new(fn creator_id ->
        {creator_id,
         case Bonfire.Me.Users.by_id(creator_id) do
           {:ok, user} -> user
           _ -> nil
         end}
      end)

    hidden =
      Enum.count(gone, fn {id, _link, creator_id} ->
        match?({:ok, _}, Bonfire.Posts.retract_imported(id, creators[creator_id]))
      end)

    {:ok, hidden}
  end

  # the posts imported from `site`, as `{id, link, creator_id}`: the objects recorded as coming from a link on the site's host and under its path, made here by a local user (as an import makes them), so nothing federated from that host is touched (eg. posts of a site that also federates)
  defp imported_from(site) do
    import Ecto.Query

    with key when is_binary(key) <- Bonfire.WordPress.Sync.site_key(site),
         host = key |> String.split("/", parts: 2) |> hd(),
         {:ok, %{id: peer_id}} <-
           Bonfire.Common.Utils.maybe_apply(
             Bonfire.Federate.ActivityPub.Instances,
             :get_by_domain,
             [host],
             fallback_return: {:error, :not_found}
           ) do
      from(p in Bonfire.Data.ActivityPub.Peered,
        join: c in Bonfire.Data.Social.Created,
        on: c.id == p.id,
        left_join: cp in Bonfire.Data.ActivityPub.Peered,
        on: cp.id == c.creator_id,
        where: p.peer_id == ^peer_id and is_nil(cp.id),
        select: {p.id, p.canonical_uri, c.creator_id}
      )
      |> Bonfire.WordPress.repo().all()
      |> Enum.filter(fn {_id, link, _} -> under_site?(link, key) end)
    else
      _ -> []
    end
  end

  defp under_site?(link, key) do
    case Bonfire.WordPress.Sync.site_key(link) do
      ^key -> true
      link_key when is_binary(link_key) -> String.starts_with?(link_key, key <> "/")
      _ -> false
    end
  end

  # a link as a key that doesn't depend on its scheme or a trailing slash
  defp link_key(link) when is_binary(link) do
    uri = URI.parse(String.trim(link))

    String.downcase(uri.host || "") <>
      String.trim_trailing(uri.path || "", "/") <> if(uri.query, do: "?" <> uri.query, else: "")
  end

  defp link_key(_), do: nil

  defp do_import_post(%{link: link} = post, opts) do
    group_id = opts[:post_into_group]
    importer = opts[:current_user]

    with {:ok, author} <- author(post[:author], importer, opts[:site]) do
      {html, embeds} = body_players(post)

      # the importer's own posts go only where they can post themselves, unless they manage the group or moderate the instance (see `Routing.may_join_to_post?/2`)
      by_importer? = Bonfire.Common.Enums.id(author) == Bonfire.Common.Enums.id(importer)

      {{_, context}, other_topics, join?} =
        placement(group_id, post[:categories], importer, by_importer?)

      # an author the importer made a user for (see `ensure_authors/2`), or an importer who may join to post, is made a member and allowed to post where the post is placed, as Ghost's import author is
      if join?, do: Routing.ensure_author_can_post(author, context, group_id)

      {uploads, other_media} = placed_uploads(author, post, opts[:site])

      with {:ok, published} <-
             Bonfire.Posts.publish_imported(
               author,
               %{
                 # an HTML-encoded title (as the site's REST API sends it, eg. `It&#8217;s`) needs no decoding here: publishing reads a title as HTML, as it does a typed one
                 name: post[:title],
                 # sanitised on publishing, as the admin chose (`Bonfire.WordPress.Sync.sanitise/0`)
                 html_body: place_uploads(html, uploads),
                 published_at: post[:published_at],
                 canonical_url: link,
                 uploaded_media:
                   post_media(author, other_media) ++
                     upload_medias(uploads) ++ embed_media(author, embeds)
               },
               opts
               |> Keyword.drop([:current_user, :post_into_group, :update, :site])
               |> Keyword.put(:sanitise, Bonfire.WordPress.Sync.sanitise())
               # in a group, as the group shares its posts by default (as Ghost's imports do), else public
               |> Keyword.put_new(:boundary, Routing.default_boundary(context))
               |> Kernel.++(Routing.publish_opts(context))
             ) do
        # its other categories' topics get it too, boosted as of when it was published
        for topic <- other_topics,
            do:
              Routing.boost_into_context(author, {:topic, topic}, published, group_id,
                auto_boost_at: post[:published_at],
                join: join?
              )

        {:ok, published}
      end
    end
  end

  # An edit on the site, brought in by a sync: the post's title and body become the site's, prepared as an import prepares them, by the post's creator here (who can edit it, whoever the site now names as its author), and the post is placed where its categories now say, as when it was imported (topics found, never made). A post whose title and body already read as the site's isn't edited, so no Update federates for nothing. Its media become the site's when they changed there (eg. a new featured image).
  defp update_post(%{link: link} = post, opts) do
    with {:ok, %{id: id}} <- Bonfire.Federate.ActivityPub.Peered.get_by_uri(link),
         %Bonfire.Data.Social.PostContent{} = current <-
           Bonfire.WordPress.repo().get(Bonfire.Data.Social.PostContent, id),
         %Bonfire.Data.Social.Created{creator_id: creator_id} <-
           Bonfire.WordPress.repo().get(Bonfire.Data.Social.Created, id),
         {:ok, creator} <- Bonfire.Me.Users.by_id(creator_id) do
      # the site publishes it, so a post hidden when it was gone from there shows again (as Ghost's sync does on every update)
      Bonfire.Posts.restore_imported(id)

      {html, embeds} = body_players(post)
      {uploads, other_media} = placed_uploads(creator, post, opts[:site])

      sanitise = Bonfire.WordPress.Sync.sanitise()

      new =
        %{name: post[:title], html_body: place_uploads(html, uploads)}
        |> Bonfire.Social.PostContents.maybe_prepare_contents(creator, nil, sanitise: sanitise)
        |> Map.take([:name, :html_body])

      media_updated? = update_media(id, creator, other_media, embeds, upload_medias(uploads))

      if new.name == current.name and new.html_body == current.html_body do
        if media_updated?,
          do: Bonfire.Common.Needles.get(id, skip_boundary_check: true),
          else: {:ok, :unchanged}
      else
        with {:ok, updated} <-
               Bonfire.Social.PostContents.edit(creator, current, new, sanitise: sanitise) do
          route_updated(creator, id, post, opts)
          {:ok, updated}
        end
      end
    else
      other -> error(other, "Could not find the imported post to update")
    end
  end

  # The body with each player (an `<iframe>`, `<video>` or `<audio>`, which the sanitiser drops) turned into a link where it was, and the players' URLs to attach. A player of a file the post already attaches (eg. a podcast's own episode) stays a link in the body without being attached twice.
  defp body_players(post) do
    {html, players} = Bonfire.Files.InlineMedia.embeds_as_links(post[:html])
    {html, players -- Enum.map(List.wrap(post[:media]), & &1[:url])}
  end

  # the post's media become the site's, as an import attaches them (see `Bonfire.Files.update_object_media/3`), with the uploads its body shows: whether they changed
  defp update_media(id, creator, media, embeds, uploads) do
    urls = Enum.map(List.wrap(media), & &1[:url]) ++ embeds ++ Enum.map(uploads, & &1.path)

    media_ids = fn post -> post.files |> Enum.map(& &1.media_id) |> MapSet.new() end

    with {:ok, post} <- Bonfire.Common.Needles.get(id, skip_boundary_check: true),
         post = Bonfire.WordPress.repo().preload(post, :files, force: true),
         {:ok, updated} <-
           Bonfire.Files.update_object_media(post, urls, fn ->
             post_media(creator, media) ++ embed_media(creator, embeds) ++ uploads
           end) do
      media_ids.(updated) != media_ids.(post)
    else
      other ->
        error(other, "Could not update the media of an imported post")
        false
    end
  end

  # as Ghost's sync does after an edit: the post is boosted into the topics its categories now have in the group (each boost is idempotent)
  defp route_updated(creator, id, post, opts) do
    group_id = opts[:post_into_group]
    importer = opts[:current_user]
    by_importer? = Bonfire.Common.Enums.id(creator) == Bonfire.Common.Enums.id(importer)

    case placement(group_id, post[:categories], importer, by_importer?) do
      {{type, _} = context, others, join?} when type in [:group, :topic] ->
        with {:ok, updated} <- Bonfire.Common.Needles.get(id, skip_boundary_check: true) do
          for target <- [context | Enum.map(others, &{:topic, &1})],
              do:
                Routing.boost_into_context(creator, target, updated, group_id,
                  auto_boost_at: post[:published_at],
                  join: join?
                )
        end

      _ ->
        :ok
    end
  end

  # Where a post goes in the group `group_id` (a group, or a topic): the topic for its first category that has one, and the topics of its other categories, to boost it into, and whether its author is to be made a member and allowed to post there. Nowhere when the importer can't post in the group (see `can_post_in?/2`). The importer's own posts go only in topics they can post in, unless they may join to post (`Routing.may_join_to_post?/2`). Topics are only found here, never made (an import makes them beforehand, see `ensure_topics/3`). Without a group, nowhere.
  defp placement(group_id, categories, importer, by_importer?) when is_binary(group_id) do
    case Routing.resolve_context(group_id) do
      {type, target} = placed when type in [:group, :topic] ->
        join? = not by_importer? or Routing.may_join_to_post?(importer, target)

        cond do
          not can_post_in?(importer, target) ->
            warn(group_id, "The importer can't post in this group, so the post isn't put in it")
            {{:no_context, nil}, [], false}

          type == :topic ->
            {placed, [], join?}

          true ->
            topics =
              categories
              |> List.wrap()
              |> Enum.map(&Routing.find_topic_for(target, category(&1)))
              |> Enum.flat_map(fn
                {:topic, topic} -> [topic]
                _ -> []
              end)
              |> Enum.uniq_by(& &1.id)
              |> Enum.filter(&(join? or can_post_in?(importer, &1)))

            case topics do
              [first | others] -> {{:topic, first}, others, join?}
              [] -> {placed, [], join?}
            end
        end

      other ->
        {other, [], false}
    end
  end

  defp placement(_group_id, _categories, _importer, _by_importer?),
    do: {{:no_context, nil}, [], false}

  @doc """
  Whether `user` can post in `group_or_id` (a group or topic, or its id), as when they post there themselves: `Bonfire.Boundaries.can?(user, :tag, group)`, the check `Bonfire.Social.Tags` makes before putting a post in a group.
  """
  def can_post_in?(user, group_id) when is_binary(group_id) do
    case Routing.resolve_context(group_id) do
      {type, target} when type in [:group, :topic] -> can_post_in?(user, target)
      _ -> false
    end
  end

  def can_post_in?(nil, _group), do: false
  def can_post_in?(user, %{} = group), do: Bonfire.Boundaries.can?(user, :tag, group) == true
  def can_post_in?(_user, _group), do: false

  @doc """
  Makes sure the group `group_id` has a topic for each of `categories` (`%{name:, slug:}`, as `import_post/2` takes them), made by `creator` when it hasn't, so each post's job only has to find them. Topics are made only if `creator` may make topics in the group (`Bonfire.Classify.can_create_topic?/2`, as when making one by hand); the ones that would have been made are counted as `not_created:`. Returns the topics `created:` and `found:`, and that count. A topic id as `group_id` gets nothing made: posts go into that topic.
  """
  def ensure_topics(group_id, categories, creator) when is_binary(group_id) do
    case Routing.resolve_context(group_id) do
      {:group, group} ->
        may_create? = Bonfire.Classify.can_create_topic?(creator, group) == true

        categories
        |> Enum.map(&category/1)
        |> Enum.uniq_by(&(&1[:slug] || &1[:name]))
        |> Enum.reduce(%{created: [], found: [], not_created: 0}, fn category, acc ->
          case Routing.find_topic_for(group, category) do
            {:topic, topic} ->
              %{acc | found: [topic | acc.found]}

            nil when not may_create? ->
              %{acc | not_created: acc.not_created + 1}

            nil ->
              case Routing.get_or_create_topic_for(group, category, creator) do
                {:ok, topic, :created} ->
                  %{acc | created: [topic | acc.created]}

                {:ok, topic, :found} ->
                  %{acc | found: [topic | acc.found]}

                other ->
                  error(other, "Could not make a topic for a WordPress category")
                  acc
              end
          end
        end)

      _ ->
        %{created: [], found: [], not_created: 0}
    end
  end

  def ensure_topics(_group_id, _categories, _creator),
    do: %{created: [], found: [], not_created: 0}

  # a category as staged (string keys) or normalised (atom keys), named as it reads: WordPress stores a term's name HTML-encoded (`News &amp; Views`), and both its export and its REST API give it as stored, so it's decoded as a post's text is before it's sanitised
  defp category(%{"name" => name} = category),
    do: category(%{name: name, slug: category["slug"]})

  defp category(%{name: name} = category) when is_binary(name),
    do: %{category | name: HtmlEntities.decode(name)}

  defp category(%{} = category), do: category

  @doc """
  The user to import a post as: the user here for its author, else the person importing (a post with no author, or one whose author is neither known nor has an email).

  An author with an email (as an export gives them) is found or made by it (see `Bonfire.Me.Users.get_or_create_for_external_author/3`), and recorded as the author with their id on `site` (see `Bonfire.WordPress.Identities`). An author with only an id (as the site's REST API gives them) is the user recorded for that id on `site`, if any.
  """
  def author(author, importer, site \\ nil)

  def author(%{email: email} = author, _importer, site) when is_binary(email) and email != "" do
    login = author[:login]
    name = author[:display_name] || login || email

    with {:ok, user} <-
           Bonfire.Me.Users.get_or_create_for_external_author(
             email,
             name,
             Enum.reject([login, name], &(is_nil(&1) or &1 == ""))
           ) do
      # a sync finds the author by this record, so it not being saved only means their synced posts come in as the importer's
      if site && author[:id] do
        with {:error, e} <- Bonfire.WordPress.Identities.link(site, author[:id], user),
             do: warn(e, "Could not record which user a WordPress author is")
      end

      {:ok, user}
    end
  end

  def author(%{id: author_id}, importer, site) when not is_nil(author_id) and is_binary(site) do
    {:ok, Bonfire.WordPress.Identities.user_for(site, author_id) || importer}
  end

  def author(_author, importer, _site), do: {:ok, importer}

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
  Makes sure each of `authors` (`%{id:, login:, email:, display_name:}`) has a user here, as `author/3` would when importing their posts, so an import can say up front who it created, and records each as the author with their id on `site`. Returns the users `created:` and the ones whose email `matched:` an existing account. Authors without an email are left out: their posts are the importer's.
  """
  def ensure_authors(authors, site \\ nil) when is_list(authors) do
    authors
    |> Enum.filter(&(is_binary(&1[:email]) and &1[:email] != ""))
    |> Enum.reduce(%{created: [], matched: []}, fn author, acc ->
      existed? =
        Bonfire.WordPress.repo().exists?(Bonfire.Me.Accounts.Queries.by_email(author.email))

      case author(author, nil, site) do
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

  @doc """
  The name `/files/redir/<name>/…` uses for `site`'s files (see `Bonfire.Files.redir_url/2`), eg. `blog-example-com`, or nil.
  """
  def redir_storage(site) do
    case Bonfire.WordPress.Sync.site_key(site) do
      key when is_binary(key) ->
        key |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

      _ ->
        nil
    end
  end

  @doc """
  Makes `site`'s files reachable through `/files/redir/<redir_storage(site)>/…`, as a lookup of each `Media` (instance config, see `Bonfire.Files.redir_url/2`). Left as it is when the name is already configured, eg. once the files are stored here and it stands for this instance's storage.
  """
  def register_redir_storage(site) do
    with name when is_binary(name) <- redir_storage(site),
         storages = Bonfire.Files.redir_storages(),
         false <- Map.has_key?(storages, name) do
      Bonfire.Common.Settings.put(
        [:bonfire_files, :redir_storages],
        Map.put(storages, name, :lookup),
        scope: :instance,
        skip_boundary_check: true
      )
    end

    :ok
  end

  # the post's uploads on the site (its featured image, and the images its body shows), one per upload, apart from its other media (eg. a podcast's audio)
  defp uploads(post) do
    {uploads, other_media} = Enum.split_with(List.wrap(post[:media]), & &1[:wp_id])

    uploads =
      (uploads ++ List.wrap(post[:images]))
      |> Enum.group_by(& &1.wp_id)
      |> Enum.map(fn {_id, [first | _] = entries} ->
        largest = Enum.max_by(entries, & &1.width)

        Map.merge(first, %{
          url: largest.url,
          width: largest.width,
          srcs: Enum.flat_map(entries, &List.wrap(&1[:srcs])),
          primary?: Enum.any?(entries, & &1[:primary?])
        })
      end)

    {uploads, other_media}
  end

  # the uploads the post shows, as `{upload, media}` (see `upload_media/3`), and the post's other media (eg. a podcast's audio)
  defp placed_uploads(author, post, site) do
    {uploads, other_media} = uploads(post)

    {upload_media(author, uploads, site) ++ synced_uploads(author, post, site), other_media}
  end

  # A synced post's images (its `image_tags`, see `Bonfire.WordPress.API`): each one showing an upload known here (by any of its URLs, see `known_uploads/2`) is placed through its `Media`, with no request. The others: on a site imported from an export (whose uploads all came in then), each gets a `Media` from its own URL and alt text; on a site only ever synced, the site's media are asked for them, once per post (see `Bonfire.WordPress.API.uploads/2`)
  defp synced_uploads(author, %{image_tags: [_ | _] = tags} = post, site) do
    known = known_uploads(Enum.map(tags, &elem(&1, 0)), site)
    known_srcs = known |> Enum.flat_map(fn {upload, _} -> upload.srcs end) |> MapSet.new()
    unknown = Enum.reject(tags, fn {src, _} -> MapSet.member?(known_srcs, src) end)

    known ++ upload_media(author, unknown_uploads(unknown, post[:image_alts] || %{}, site), site)
  end

  defp synced_uploads(_author, _post, _site), do: []

  defp unknown_uploads([], _alts, _site), do: []

  defp unknown_uploads(tags, alts, site) do
    if Bonfire.WordPress.Sync.imported?(site) do
      shown =
        for {src, id} <- tags,
            url = Bonfire.WordPress.Uploads.absolute_url(src, site),
            do: {id || url, src, url, 0, %{alt: alts[src]}}

      Bonfire.WordPress.Uploads.group(shown, fn %{alt: alt}, id, url, width ->
        Bonfire.WordPress.Uploads.entry(%{
          id: if(is_integer(id), do: id),
          url: url,
          width: width,
          media_type: MIME.from_path(URI.parse(url).path || ""),
          sizes: [{url, width}],
          alt: alt
        })
      end)
    else
      {uploads, _other_srcs} = Bonfire.WordPress.API.uploads(site, tags)
      uploads
    end
  end

  # the `Media` already here that these `<img src>` show, each with the srcs that show it: one indexed query over their URLs (as a `Media`'s path, or among the URLs of its sizes it keeps, see `find_or_save_upload/3`), whatever the scheme; only an imported upload's (one placed through `/files/redir`)
  defp known_uploads(srcs, site) when is_list(srcs) and srcs != [] do
    by_url =
      for src <- srcs,
          url = Bonfire.WordPress.Uploads.absolute_url(src, site),
          form <- Bonfire.WordPress.Uploads.scheme_forms(url),
          do: {form, src}

    storage = redir_storage(site)

    for %{file: %Entrepot.Locator{storage: ^storage}} = media <-
          Bonfire.Files.Media.many_by_urls(Enum.map(by_url, &elem(&1, 0))),
        urls = MapSet.new([media.path | List.wrap(media.metadata["urls"])]),
        srcs = for({url, src} <- by_url, MapSet.member?(urls, url), do: src),
        srcs != [],
        do: {%{srcs: Enum.uniq(srcs)}, media}
  end

  defp known_uploads(_srcs, _site), do: []

  defp upload_medias(uploads), do: uploads |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id)

  # each upload's `Media`, as `{upload, media}`: the one already made for it, whichever size it was saved at (an indexed query over the paths of its sizes), moved to this size when it's larger, else a new one at this size (never downloaded)
  defp upload_media(author, uploads, site) do
    storage = redir_storage(site)

    # each `Media` gets a locator in the site's storage, whose URL can only be built once that storage is configured: done here so any caller of `import_post/2` works, not only the sync and the export import (a config read, written only the first time)
    if uploads != [], do: register_redir_storage(site)

    for upload <- uploads,
        {:ok, media} <- [media_for_upload(author, upload, storage)],
        do: {upload, media}
  end

  # one upload at a time: two jobs importing or syncing posts that show the same upload would otherwise both find none and each make one
  defp media_for_upload(author, upload, storage) do
    Bonfire.Common.Repo.transact_with_lock(
      {:wordpress_upload, storage, upload[:wp_id] || upload.url},
      fn -> find_or_save_upload(author, upload, storage) end
    )
  end

  defp find_or_save_upload(author, upload, storage) do
    urls = Enum.uniq([upload.url | List.wrap(upload[:urls])])

    metadata =
      %{
        "alt" => upload[:alt],
        "label" => upload[:caption],
        "description" => upload[:description],
        "width" => upload.width,
        "primary_image" => if(upload[:primary?], do: true),
        # every URL of the upload's sizes, so a sync finds it from whichever size a post shows (see `known_uploads/2`)
        "urls" => urls
      }
      |> Bonfire.Common.Enums.filter_empty(%{})

    case Bonfire.Files.Media.many_by_urls(urls) do
      [%{} = media | _] ->
        stored = media.metadata || %{}
        larger? = upload.width > (stored["width"] || 0)

        changes =
          %{
            metadata:
              stored
              # the site wins: its alt text, caption and description replace the ones here
              |> Map.merge(metadata, fn
                "width", old, new -> max(old, new)
                "primary_image", old, new -> old || new
                "urls", old, new -> Enum.uniq(List.wrap(old) ++ new)
                _key, _old, new -> new
              end)
          }
          |> then(&if(larger?, do: Map.put(&1, :path, upload.url), else: &1))

        with {:ok, media} <-
               if(changes.metadata == stored and not larger?,
                 do: {:ok, media},
                 else: Bonfire.Files.Media.update(nil, media, changes, skip_boundary_check: true)
               ) do
          Bonfire.Files.put_storage_locator(media, storage)
        end

      _ ->
        # its file stays on the site; its URL is the one it will have once stored here (see `Bonfire.Files.put_storage_locator/2`)
        with {:ok, media} <-
               Bonfire.Files.save_url_as_media(author, upload.url, %{
                 media_type: upload.media_type,
                 metadata: metadata
               }) do
          Bonfire.Files.put_storage_locator(media, storage)
        end
    end
  end

  # each `src` of an upload in the body replaced by its `Media`'s URL (see `Bonfire.Files.inline_url/1`), so the body places it
  defp place_uploads(html, uploads) when is_binary(html) do
    Enum.reduce(uploads, html, fn {upload, media}, html ->
      case media do
        %{file: %Entrepot.Locator{}} ->
          url = URI.parse(Bonfire.Files.inline_url(media)).path

          Enum.reduce(List.wrap(upload[:srcs]), html, fn src, html ->
            html
            |> String.replace(~s(src="#{src}"), ~s(src="#{url}"))
            |> String.replace(~s(src='#{src}'), ~s(src="#{url}"))
          end)

        _ ->
          html
      end
    end)
  end

  defp place_uploads(html, _uploads), do: html

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
