defmodule Bonfire.WordPress.Import.WXR do
  @moduledoc """
  A WordPress export file (WXR, from Tools → Export) as an import source, and the op that imports one of its posts.

  The file can be large (a site's whole history in one XML document), so it is read as a stream with `Saxy`, one item at a time. Staging writes each post the import will use to its own file in the staged dir (`posts/<id>.json`) with a light index (`posts_index.jsonl`), each attachment to its own file (`attachments/<id>.json`, so a post's featured image is found by id), and the export's authors to `authors.json`, so materializing and each job read only what they need. Media stays on the site: a post's featured image and a podcast episode's audio are attached as links to where they are, never downloaded.

  Saxy skips any DTD and leaves unknown entity references as text, so a crafted file can't expand entities or pull in local files. It also doesn't check namespaces, which matters since real exports use prefixes they never declare (eg. a podcast plugin's `itunes:`).

  A post's body comes from the site's REST API (`content.rendered`, after WordPress has run its shortcodes, blocks and paragraphs), fetched for up to 100 posts at a time: the first job of a chunk fetches it and caches every body in the staged dir, and the rest of the chunk reads the cache. When the API can't give a body (the site is down or its API blocked), the post comes in with the export's own body instead, without the block editor's comments, and a failed chunk isn't requested again by its other posts.
  """
  @behaviour Bonfire.Common.ImportModule

  use Bonfire.Common.Localise
  import Untangle

  alias Bonfire.Common.Import

  # post types that import as posts (a podcast episode is a post with its audio attached), and the REST API's name for each
  @rest_types %{"post" => "posts", "podcast" => "podcast"}
  @post_types Map.keys(@rest_types)

  # how many posts one REST request asks for (WordPress's maximum `per_page`)
  @chunk_size 100

  # the fields of an item that are kept, by element name
  @item_fields ~w(title link dc:creator guid content:encoded excerpt:encoded wp:post_id wp:post_date_gmt wp:status wp:post_type wp:post_parent wp:post_name wp:post_password wp:attachment_url)

  @op "wordpress_import"

  @impl true
  def import_source, do: :wordpress

  @impl true
  def import_source_label, do: l("WordPress export (XML)")

  @impl true
  def import_ops, do: [@op]

  @impl true
  def import_op_label(@op), do: l("WordPress post")
  def import_op_label(_), do: nil

  @impl true
  def import_op_phrase(@op), do: l("Importing WordPress post")
  def import_op_phrase(_), do: nil

  @impl true
  def stage(path) when is_binary(path) do
    with {:ok, dir} <- Import.make_staging_dir(),
         :ok <- File.mkdir_p(Path.join(dir, "posts")),
         :ok <- File.mkdir_p(Path.join(dir, "attachments")),
         {:ok, state} <- parse(path, dir) do
      File.write!(Path.join(dir, "authors.json"), Jason.encode!(state.authors))
      Import.enqueue_archive_cleanup(dir)

      preview = preview(dir, state.authors)

      {:ok,
       %{
         source: __MODULE__,
         dir: dir,
         base_site_url: state.base_site_url,
         items: items(state.counts, preview),
         skipped: state.skipped,
         summary: already_lines(preview.already) ++ not_imported_lines(state.skipped)
       }}
    end
  end

  # what importing the staged posts would do, worked out before the person picks: how many a previous import already brought in (one query), and the authors of the others who have an email, with how many of them already have an account here (one lookup each, nothing made)
  defp preview(dir, export_authors) do
    staged_posts = read_posts_index(dir)
    done = Bonfire.WordPress.Posts.imported_links(Enum.map(staged_posts, & &1["link"]))
    posts = Enum.reject(staged_posts, &MapSet.member?(done, &1["link"]))

    authors =
      posts
      |> Enum.map(&author_from(export_authors, &1["creator"]))
      |> Enum.filter(&(&1 && is_binary(&1.email) && &1.email != ""))
      |> Enum.uniq_by(& &1.email)

    %{
      already: length(staged_posts) - length(posts),
      author_counts: if(authors != [], do: Bonfire.WordPress.Posts.author_counts(authors))
    }
  end

  defp read_posts_index(dir) do
    path = Path.join(dir, "posts_index.jsonl")

    if File.exists?(path),
      do: path |> File.stream!() |> Enum.map(&Jason.decode!/1),
      else: []
  end

  defp parse(path, dir) do
    files = %{
      posts_index: File.open!(Path.join(dir, "posts_index.jsonl"), [:write, :binary])
    }

    state = %{
      dir: dir,
      files: files,
      text: [],
      item: nil,
      meta_key: nil,
      meta_value: nil,
      in_comment?: false,
      category: nil,
      author: nil,
      authors: %{},
      base_site_url: nil,
      counts: %{posts: 0, pages: 0, attachments: 0},
      skipped: %{}
    }

    try do
      path
      |> File.stream!(64_000)
      |> Saxy.parse_stream(__MODULE__.Handler, state)
    after
      Enum.each(files, fn {_, file} -> File.close(file) end)
    end
  end

  # each attachment in its own file, so a job finds a post's featured image by id without reading the others
  @doc false
  def handle_item(%{"wp:post_type" => "attachment"} = item, state) do
    case post_id(item["wp:post_id"]) do
      nil ->
        state

      id ->
        File.write!(attachment_path(state.dir, id), Jason.encode!(item))
        count(state, :attachments)
    end
  end

  # a published post behind a password is only for those who have it, so it never comes in public
  def handle_item(
        %{"wp:post_type" => type, "wp:status" => "publish", "wp:post_password" => password},
        state
      )
      when type in @post_types and is_binary(password) and password != "",
      do: skip(state, "password-protected")

  def handle_item(%{"wp:post_type" => type, "wp:status" => "publish"} = item, state)
      when type in @post_types do
    case post_id(item["wp:post_id"]) do
      nil ->
        skip(state, "no id")

      id ->
        File.write!(post_path(state.dir, id), Jason.encode!(item))

        state
        |> write(:posts_index, %{
          "id" => id,
          "type" => type,
          "link" => item["link"],
          "creator" => item["dc:creator"],
          "categories" => item["categories"] || []
        })
        |> count(:posts)
    end
  end

  def handle_item(%{"wp:post_type" => "page", "wp:status" => "publish"}, state),
    do: count(state, :pages)

  # a post or page that isn't published is counted by its status, anything else by its type
  def handle_item(%{"wp:post_type" => type, "wp:status" => status}, state)
      when type in ["page" | @post_types],
      do: skip(state, status)

  def handle_item(item, state), do: skip(state, item["wp:post_type"] || "unknown")

  @doc false
  def item_field?(name), do: name in @item_fields

  defp write(state, file, item) do
    IO.binwrite(state.files[file], [Jason.encode!(item), ?\n])
    state
  end

  defp count(state, key), do: update_in(state, [:counts, key], &(&1 + 1))

  defp skip(state, reason),
    do: update_in(state, [:skipped], &Map.update(&1, reason, 1, fn n -> n + 1 end))

  defp items(counts, preview) do
    [
      if counts.posts > 0 do
        %{
          key: :posts,
          label: l("Posts"),
          count: counts.posts,
          importable?: true,
          reason: nil,
          options: author_options(preview.author_counts)
        }
      else
        %{
          key: :posts,
          label: l("Posts"),
          count: 0,
          importable?: false,
          reason: l("Nothing to import in it")
        }
      end,
      if counts.pages > 0 do
        %{
          key: :pages,
          label: l("Pages"),
          count: counts.pages,
          importable?: false,
          reason: l("Pages aren't imported yet")
        }
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  # a user here for each of the site's authors, rather than every post being the importer's: making accounts for other people is for an instance admin only, so only they are offered it (and the job preparing the import checks again)
  defp author_options(%{new: new, existing: existing}),
    do: [
      %{
        key: :create_author_users,
        label:
          l("Create a user for each author (%{new} new, %{existing} existing accounts)",
            new: new,
            existing: existing
          ),
        default: true,
        admin_only?: true
      }
    ]

  defp author_options(_), do: []

  defp already_lines(0), do: []

  defp already_lines(already),
    do: [
      %{
        key: l("Posts"),
        reason:
          lp("%{count} already imported", "%{count} already imported", already, count: already)
      }
    ]

  # a report line for each kind of item staging left out, by status for posts and pages that aren't published, else by the item's type as WordPress names it
  defp not_imported_lines(skipped) when is_map(skipped) do
    for {reason, count} <- Enum.sort(skipped) do
      %{
        key: not_imported_label(reason),
        reason: l("skipping %{count}", count: count)
      }
    end
  end

  defp not_imported_lines(_), do: []

  # one report line for the authors' users: how many were made, and how many authors already had an account here
  defp authors_lines(%{created: [], matched: []}), do: []

  defp authors_lines(%{created: created, matched: matched}) do
    text =
      [
        if(created != [],
          do:
            lp("%{count} user created", "%{count} users created", length(created),
              count: length(created)
            )
        ),
        if(matched != [],
          do:
            lp(
              "%{count} already had an account here",
              "%{count} already had an account here",
              length(matched),
              count: length(matched)
            )
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    [%{key: l("Authors"), reason: text}]
  end

  # a report line when a group was asked for (or configured) but the importer can't post in it, so the posts come in outside it
  defp group_lines(asked, nil) when is_binary(asked),
    do: [%{key: l("Group"), reason: l("posts not put in it, no permission to post there")}]

  defp group_lines(_asked, _group_id), do: []

  # one report line for the topics made in the group for the posts' categories, and the ones not made since the importer may not make topics there
  defp topics_lines(%{created: created, not_created: not_created}) do
    text =
      [
        if(created != [],
          do: lp("%{count} created", "%{count} created", length(created), count: length(created))
        ),
        if(not_created > 0,
          do:
            lp(
              "%{count} not created, no permission to make topics in the group",
              "%{count} not created, no permission to make topics in the group",
              not_created,
              count: not_created
            )
        )
      ]
      |> Enum.reject(&is_nil/1)

    if text == [], do: [], else: [%{key: l("Topics"), reason: Enum.join(text, ", ")}]
  end

  defp not_imported_label("draft"), do: l("Drafts")
  defp not_imported_label("pending"), do: l("Pending posts")
  defp not_imported_label("private"), do: l("Private posts")
  defp not_imported_label("future"), do: l("Scheduled posts")
  defp not_imported_label("trash"), do: l("Deleted posts")
  defp not_imported_label("password-protected"), do: l("Password-protected posts")
  defp not_imported_label(type), do: type

  @impl true
  def materialize(%{dir: dir, base_site_url: site} = staged, keys, opts) do
    # what the export holds that isn't imported, as staging counted it
    not_imported = not_imported_lines(staged[:skipped])

    # a user for each author only when asked for, and only by an instance admin (checked here too, since the form's options can't be trusted); otherwise every post is the importer's
    author_users? =
      opts[:create_author_users] == true and Import.instance_admin?(opts[:current_user])

    # the group the posts go into: the one asked for, else the one the instance's WordPress site posts into (as its sync does), for anyone who can post there (see `Bonfire.WordPress.Posts.can_post_in?/2`)
    asked_group_id =
      blank_to_nil(opts[:post_into_group]) || Bonfire.WordPress.Sync.post_into_group()

    group_id =
      if asked_group_id &&
           Bonfire.WordPress.Posts.can_post_in?(opts[:current_user], asked_group_id),
         do: asked_group_id

    # an admin's import makes this the instance's WordPress site to keep in sync (see `Bonfire.WordPress.Sync`), unless another site is configured already; it's instance config, so not anyone's import
    if :posts in keys and Import.instance_admin?(opts[:current_user]) do
      with {:error, :other_site} <-
             Bonfire.WordPress.Sync.remember_site(site, opts[:current_user]) do
        warn(site, "Another WordPress site is configured for syncing, so this one isn't")
      end
    end

    if :posts in keys do
      staged_posts = read_posts_index(dir)

      # the posts a previous import already brought in, found in one query, aren't queued again
      done = Bonfire.WordPress.Posts.imported_links(Enum.map(staged_posts, & &1["link"]))
      posts = Enum.reject(staged_posts, &MapSet.member?(done, &1["link"]))
      already = length(staged_posts) - length(posts)

      # the REST requests to make: each type's post ids, 100 at a time
      chunks =
        posts
        |> Enum.group_by(&@rest_types[&1["type"]], & &1["id"])
        |> Map.new(fn {rest_type, ids} -> {rest_type, Enum.chunk_every(ids, @chunk_size)} end)

      File.write!(Path.join(dir, "chunks.json"), Jason.encode!(chunks))

      jobs =
        for post <- posts do
          rest_type = @rest_types[post["type"]]

          %{
            key: :posts,
            op: @op,
            identifiers: [post["link"]],
            args: %{
              "dir" => dir,
              "site" => site,
              "wp_id" => post["id"],
              "rest_type" => rest_type,
              "chunk" => Enum.find_index(chunks[rest_type], &(post["id"] in &1)),
              "authors" => author_users?,
              "group_id" => group_id
            }
          }
        end

      # the users for the authors of the posts about to be imported, made once here rather than by each post's job (which then finds its author's user)
      authors =
        if author_users? do
          export_authors = export_authors(dir)

          posts
          |> Enum.map(&author_from(export_authors, &1["creator"]))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(& &1.email)
          |> Bonfire.WordPress.Posts.ensure_authors(site)
        else
          %{created: [], matched: []}
        end

      # the group's topics for these posts' categories, made once here rather than by each post's job (which then finds them), so two jobs can't make the same topic
      topics =
        Bonfire.WordPress.Posts.ensure_topics(
          group_id,
          Enum.flat_map(posts, &List.wrap(&1["categories"])),
          opts[:current_user]
        )

      {:ok,
       %{
         jobs: jobs,
         notes:
           authors_lines(authors) ++
             group_lines(asked_group_id, group_id) ++ topics_lines(topics),
         skipped: already_lines(already) ++ not_imported
       }}
    else
      {:ok, %{jobs: [], skipped: not_imported}}
    end
  end

  @doc """
  Imports one staged post, `link` being where it is on the site: reads it and its author from the staged dir, and its body from the site's REST API (cached per chunk), then hands it to `Bonfire.WordPress.Posts.import_post/2` as a normalised post.
  """
  @impl true
  def perform_import(@op, link, opts) do
    args = opts[:args] || %{}
    dir = args["dir"]

    with true <- Import.staged_dir?(dir) || {:error, :not_a_staged_dir},
         id when is_integer(id) <- post_id(args["wp_id"]) || {:error, :no_post_id},
         {:ok, item} <- read_json(post_path(dir, id)),
         {:ok, body} <- body(dir, id, item, args) do
      Bonfire.WordPress.Posts.import_post(
        %{
          title: item["title"],
          link: link,
          published_at: published_at(item["wp:post_date_gmt"]),
          html: body,
          # the post's author only when the import made users for them (see `materialize/3`), else the post is the importer's
          author: if(args["authors"] == true, do: author(dir, item["dc:creator"])),
          media: media(dir, item),
          categories: List.wrap(item["categories"])
        },
        current_user: opts[:current_user],
        post_into_group: args["group_id"],
        site: args["site"]
      )
    else
      {:error, _} = e -> e
      other -> error(other, "Could not import this WordPress post")
    end
  end

  # the post's body: from the cache a job of its chunk filled, else fetched with the rest of its chunk. When the site's API can't give it (the site is down, the API blocked, or the post missing from its answer), the export's own body instead, and a chunk whose request failed isn't requested again by its other posts' jobs
  defp body(dir, id, item, %{"site" => site, "rest_type" => rest_type, "chunk" => chunk})
       when is_integer(chunk) do
    with {:error, _} <- File.read(body_path(dir, id)),
         false <- File.exists?(failed_chunk_path(dir, rest_type, chunk)),
         {:ok, chunks} <- read_json(Path.join(dir, "chunks.json")),
         ids when is_list(ids) <- get_in(chunks, [rest_type, Access.at(chunk)]) do
      case Bonfire.WordPress.API.rendered_bodies(site, rest_type, ids) do
        {:ok, bodies} ->
          File.mkdir_p!(Path.join(dir, "bodies"))
          for {post_id, body} <- bodies, do: File.write!(body_path(dir, post_id), body)

          case bodies[id] do
            nil -> export_body(item, "the site's API didn't return this post")
            body -> {:ok, body}
          end

        other ->
          warn(
            other,
            "The WordPress site's API couldn't give this chunk's bodies, using the export's"
          )

          File.mkdir_p!(Path.join(dir, "failed"))
          File.write!(failed_chunk_path(dir, rest_type, chunk), "")
          export_body(item, "the site's API couldn't be reached")
      end
    else
      {:ok, body} -> {:ok, body}
      true -> export_body(item, "the site's API couldn't be reached")
      other -> error(other, "Could not find this post's chunk")
    end
  end

  # the body as the export stores it: the block editor's comments taken out (shortcodes stay as text, and nothing adds the paragraphs WordPress adds when showing it)
  defp export_body(%{"content:encoded" => html}, why) when is_binary(html) and html != "" do
    debug(why, "Importing a WordPress post with the export's body")
    {:ok, Regex.replace(~r/<!--\s*\/?wp:.*?-->/s, html, "")}
  end

  defp export_body(_item, why), do: error(why, "No body for this WordPress post")

  # a post's author from the export's list of authors, by the login its `dc:creator` names, or nil (a post with no author, eg. one whose author was deleted on the site)
  defp author(dir, login), do: author_from(export_authors(dir), login)

  # the export's authors, by login, as staging saved them
  defp export_authors(dir) do
    case read_json(Path.join(dir, "authors.json")) do
      {:ok, %{} = authors} -> authors
      _ -> %{}
    end
  end

  defp author_from(authors, login) when is_binary(login) and login != "" do
    case authors do
      %{^login => author} ->
        %{
          id: author["wp:author_id"],
          login: login,
          email: author["wp:author_email"],
          display_name: author["wp:author_display_name"]
        }

      _ ->
        nil
    end
  end

  defp author_from(_authors, _login), do: nil

  # the media a post uses, as the site has it: its featured image (`_thumbnail_id`, the attachment's URL and alt text), and a podcast episode's audio (`audio_file` or `enclosure`, a URL). Typed by the file's extension, since an export doesn't say.
  defp media(dir, item) do
    meta = item["meta"] || %{}

    featured =
      with id when is_integer(id) <- post_id(meta["_thumbnail_id"]),
           {:ok, attachment} <- read_json(attachment_path(dir, id)),
           url when is_binary(url) and url != "" <- attachment["wp:attachment_url"] do
        %{
          url: url,
          media_type: media_type(url),
          alt: blank_to_nil(get_in(attachment, ["meta", "_wp_attachment_image_alt"])),
          primary?: true
        }
      else
        _ -> nil
      end

    audio =
      case first_line(meta["audio_file"]) || first_line(meta["enclosure"]) do
        nil -> nil
        url -> %{url: url, media_type: media_type(url), alt: nil, primary?: false}
      end

    Enum.reject([featured, audio], &is_nil/1)
  end

  # WordPress keeps an enclosure as "url\nlength\ntype", and an audio file as the URL alone
  defp first_line(value) when is_binary(value) do
    value |> String.split("\n", parts: 2) |> List.first() |> String.trim() |> blank_to_nil()
  end

  defp first_line(_), do: nil

  defp media_type(url), do: MIME.from_path(URI.parse(url).path || "")

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  # WordPress writes UTC as "YYYY-MM-DD HH:MM:SS", and "0000-00-00 00:00:00" for a post never published
  defp published_at(date) when is_binary(date) do
    case NaiveDateTime.from_iso8601(String.replace(date, " ", "T")) do
      {:ok, %{year: year} = naive} when year > 0 -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end

  defp published_at(_), do: nil

  defp read_json(path) do
    with {:ok, json} <- File.read(path), do: Jason.decode(json)
  end

  # a post id from the export or a job, only ever digits, so it can't make a path go anywhere else
  defp post_id(id) when is_integer(id) and id > 0, do: id

  defp post_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp post_id(_), do: nil

  defp post_path(dir, id), do: Path.join([dir, "posts", "#{id}.json"])
  defp body_path(dir, id), do: Path.join([dir, "bodies", "#{id}.html"])

  # rest_type comes from staging (eg. "posts", "podcast"); anything else can't make a path
  defp failed_chunk_path(dir, rest_type, chunk) when is_integer(chunk) do
    type = if Regex.match?(~r/^[a-z0-9_-]+$/, to_string(rest_type)), do: rest_type, else: "other"
    Path.join([dir, "failed", "#{type}-#{chunk}"])
  end

  defp attachment_path(dir, id), do: Path.join([dir, "attachments", "#{id}.json"])
end
