defmodule Bonfire.WordPress.API do
  @moduledoc """
  A WordPress site's public REST API (`/wp-json/wp/v2/`), which needs no key for published posts. Requests go through `Bonfire.Common.HTTP`, so the SSRF guard applies.
  """
  import Untangle

  # WordPress's maximum page size
  @per_page 100

  @doc """
  The rendered bodies (`content.rendered`, after WordPress has run its shortcodes, blocks and paragraphs) of up to 100 posts of a REST type (eg. `"posts"`, `"podcast"`) on `site`, in one request, as `%{id => html}`.
  """
  def rendered_bodies(site, rest_type, ids)
      when is_binary(site) and is_binary(rest_type) and is_list(ids) and length(ids) <= @per_page do
    url =
      "#{String.trim_trailing(site, "/")}/wp-json/wp/v2/#{URI.encode(rest_type)}?" <>
        URI.encode_query(%{
          "include" => Enum.join(ids, ","),
          "per_page" => @per_page,
          "_fields" => "id,content"
        })

    with {:ok, %{status: 200, body: body}} <- Bonfire.Common.HTTP.get(url),
         {:ok, posts} when is_list(posts) <- decode(body) do
      bodies =
        for %{"id" => id, "content" => %{"rendered" => html}} <- posts,
            is_binary(html),
            into: %{},
            do: {id, html}

      {:ok, bodies}
    else
      {:ok, %{status: status}} -> error(status, "The WordPress site's API answered #{url} with")
      other -> error(other, "Could not get posts from the WordPress site's API at #{url}")
    end
  end

  # the REST types to sync, and whether the site must have them (podcasts come from a plugin many sites don't have)
  @sync_types [{"posts", :required}, {"podcast", :optional}]

  @doc """
  The posts and podcast episodes on `site` changed since `since` (a `DateTime`, or nil for all), as normalised posts for `Bonfire.WordPress.Posts.import_post/2`, paging 100 at a time. Each post's author is only its id on the site, since the API gives no email.
  """
  def changed_posts(site, since) when is_binary(site) do
    query =
      %{
        "orderby" => "modified",
        "order" => "asc",
        # the featured image and the post's terms (categories and tags, with their names) come embedded in the same answer; with `_fields`, an embed needs `_links` and `_embedded` listed too. `meta` holds a podcast's audio file and cover (Seriously Simple Podcasting), public like the rest
        "_embed" => "wp:featuredmedia,wp:term",
        "_fields" =>
          "id,link,date_gmt,modified_gmt,title,content,author,featured_media,categories,meta,_links,_embedded"
      }
      |> then(&if since, do: Map.put(&1, "modified_after", DateTime.to_iso8601(since)), else: &1)

    Enum.reduce_while(@sync_types, {:ok, []}, fn {rest_type, need}, {:ok, acc} ->
      case pages(site, rest_type, query, &normalise(&1, site), 1, []) do
        {:ok, posts} -> {:cont, {:ok, acc ++ posts}}
        _ when need == :optional -> {:cont, {:ok, acc}}
        e -> {:halt, e}
      end
    end)
  end

  @doc """
  The links of every post and podcast episode `site` publishes, paging 100 at a time (ids and links only), for telling which imported posts it no longer has. An error unless the whole list was had: a site without the podcast plugin has no podcast route (a 404), but any other failure leaves the list incomplete.
  """
  def published_links(site) when is_binary(site) do
    query = %{"orderby" => "id", "order" => "asc", "_fields" => "id,link"}

    Enum.reduce_while(@sync_types, {:ok, []}, fn {rest_type, need}, {:ok, acc} ->
      case pages(site, rest_type, query, & &1["link"], 1, []) do
        {:ok, links} -> {:cont, {:ok, acc ++ Enum.filter(links, &is_binary/1)}}
        {:error, {:http_status, 404}} when need == :optional -> {:cont, {:ok, acc}}
        e -> {:halt, e}
      end
    end)
  end

  # every page of a REST type's posts with `query`, each made into what `fun` returns
  defp pages(site, rest_type, query, fun, page, acc) do
    url =
      "#{String.trim_trailing(site, "/")}/wp-json/wp/v2/#{URI.encode(rest_type)}?" <>
        URI.encode_query(Map.merge(query, %{"per_page" => @per_page, "page" => page}))

    with {:ok, %{status: 200, body: body} = env} <- Bonfire.Common.HTTP.get(url),
         {:ok, posts} when is_list(posts) <- decode(body) do
      acc = acc ++ Enum.map(posts, fun)

      if length(posts) < @per_page or page >= total_pages(env),
        do: {:ok, acc},
        else: pages(site, rest_type, query, fun, page + 1, acc)
    else
      {:ok, %{status: status}} ->
        warn(status, "The WordPress site's API answered #{url} with")
        {:error, {:http_status, status}}

      other ->
        error(other, "Could not get posts from the WordPress site's API at #{url}")
    end
  end

  defp total_pages(%{headers: headers}) do
    with {_, value} <-
           Enum.find(headers || [], fn {k, _} -> String.downcase(k) == "x-wp-totalpages" end),
         {n, _} <- Integer.parse(value) do
      n
    else
      _ -> 1
    end
  end

  defp total_pages(_), do: 1

  defp normalise(post, site) do
    html = get_in(post, ["content", "rendered"])

    %{
      title: get_in(post, ["title", "rendered"]),
      link: post["link"],
      published_at: gmt(post["date_gmt"]),
      html: html,
      # by id only: the API never gives an author's email, so the user is the one an import recorded for that id (see `Bonfire.WordPress.Identities`)
      author: if(is_integer(post["author"]) and post["author"] > 0, do: %{id: post["author"]}),
      password_protected?: get_in(post, ["content", "protected"]) == true,
      media: media(post),
      # each `<img>` the body shows, as `{src, upload id}` (see `Bonfire.WordPress.Uploads.img_tags/1`), with its alt text: placed when the post is imported, through the uploads known here or, for a site never imported from an export, the site's media (see `uploads/2`)
      image_tags: Bonfire.WordPress.Uploads.img_tags(html),
      image_alts: Bonfire.WordPress.Uploads.img_alts(html),
      categories: categories(post)
    }
  end

  @doc """
  The uploads `tags` show (`{src, upload id}` from `Bonfire.WordPress.Uploads.img_tags/1`), as `Bonfire.WordPress.Uploads` entries, through one request to `site`'s media for all the ids they name (none when they name none), and the `src` of each other image.
  """
  def uploads(site, tags) when is_list(tags) do
    items = media_items(site, tags |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1))

    shown =
      for {src, id} <- tags,
          %{} = item <- [items[id]],
          url = Bonfire.WordPress.Uploads.absolute_url(src, site) || item["source_url"],
          do: {id, src, url, shown_width(item, url), item}

    named = MapSet.new(shown, &elem(&1, 1))

    {Bonfire.WordPress.Uploads.group(shown, &rest_upload/4),
     for({src, _} <- tags, not MapSet.member?(named, src), do: src)}
  end

  # the site's media items with these ids (at most 100, WordPress's page size), by id; none when the site can't say
  defp media_items(_site, []), do: %{}

  defp media_items(site, ids) do
    url =
      "#{String.trim_trailing(site, "/")}/wp-json/wp/v2/media?" <>
        URI.encode_query(%{
          "include" => ids |> Enum.uniq() |> Enum.take(@per_page) |> Enum.join(","),
          "per_page" => @per_page,
          "_fields" => "id,source_url,mime_type,alt_text,caption,description,title,media_details"
        })

    with {:ok, %{status: 200, body: body}} <- Bonfire.Common.HTTP.get(url),
         {:ok, items} when is_list(items) <- decode(body) do
      for %{"id" => id} = item <- items, into: %{}, do: {id, item}
    else
      other ->
        warn(other, "Could not get media from the WordPress site's API at #{url}")
        %{}
    end
  end

  # every URL a media item has, with its width: the original and each size WordPress made of it
  defp rest_sizes(item) do
    details = if is_map(item["media_details"]), do: item["media_details"], else: %{}
    sizes = if is_map(details["sizes"]), do: Map.values(details["sizes"]), else: []

    [{item["source_url"], details["width"] || 100_000}] ++
      for %{"source_url" => url} = size <- sizes, is_binary(url), do: {url, size["width"] || 0}
  end

  # the width of the size `url` shows, else the original's
  defp shown_width(item, url) do
    key = Bonfire.WordPress.Uploads.url_key(url)
    [{_, original} | _] = sizes = rest_sizes(item)

    Enum.find_value(sizes, original, fn {size_url, width} ->
      if Bonfire.WordPress.Uploads.url_key(size_url) == key, do: width
    end)
  end

  defp rest_upload(item, id, url, width) do
    Bonfire.WordPress.Uploads.entry(%{
      id: id,
      url: url,
      width: width,
      media_type: item["mime_type"],
      sizes: rest_sizes(item),
      alt: item["alt_text"],
      caption: get_in(item, ["caption", "rendered"]),
      description: get_in(item, ["description", "rendered"]),
      title: get_in(item, ["title", "rendered"])
    })
  end

  # the post's categories, by name and slug, from its embedded terms (one list per taxonomy); tags and other taxonomies aren't used
  defp categories(%{"_embedded" => %{"wp:term" => taxonomies}}) when is_list(taxonomies) do
    for terms when is_list(terms) <- taxonomies,
        %{"taxonomy" => "category", "name" => name} = term <- terms,
        is_binary(name) and name != "",
        do: %{name: name, slug: term["slug"]}
  end

  defp categories(_), do: []

  # the post's featured image as its primary image, else a podcast's cover, plus a podcast's audio file. Only addresses: nothing is fetched
  defp media(post) do
    meta = if is_map(post["meta"]), do: post["meta"], else: %{}

    primary = featured_image(post) || url_media(meta["cover_image"], primary?: true)
    audio = url_media(meta["audio_file"], primary?: false)

    Enum.reject([primary, audio], &is_nil/1)
  end

  # the embedded featured image, unless the site sent an error instead (eg. `rest_forbidden` for media that isn't public)
  defp featured_image(%{
         "_embedded" => %{"wp:featuredmedia" => [%{"source_url" => url} = image | _]}
       })
       when is_binary(url) and url != "" do
    %{
      url: url,
      media_type: image["mime_type"],
      alt: if(is_binary(image["alt_text"]) and image["alt_text"] != "", do: image["alt_text"]),
      primary?: true
    }
  end

  defp featured_image(_), do: nil

  defp url_media(url, opts) when is_binary(url) and url != "",
    do: %{url: url, media_type: nil, alt: nil, primary?: opts[:primary?] == true}

  defp url_media(_, _), do: nil

  defp gmt(at) when is_binary(at) do
    case NaiveDateTime.from_iso8601(at) do
      {:ok, at} -> DateTime.from_naive!(at, "Etc/UTC")
      _ -> nil
    end
  end

  defp gmt(_), do: nil

  # a body Tesla already decoded, or a JSON string
  defp decode(body) when is_list(body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_), do: {:error, :not_json}
end
