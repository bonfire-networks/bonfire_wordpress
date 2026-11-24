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
      case pages(site, rest_type, query, &normalise/1, 1, []) do
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

  defp normalise(post) do
    %{
      title: get_in(post, ["title", "rendered"]),
      link: post["link"],
      published_at: gmt(post["date_gmt"]),
      html: get_in(post, ["content", "rendered"]),
      # by id only: the API never gives an author's email, so the user is the one an import recorded for that id (see `Bonfire.WordPress.Identities`)
      author: if(is_integer(post["author"]) and post["author"] > 0, do: %{id: post["author"]}),
      password_protected?: get_in(post, ["content", "protected"]) == true,
      media: media(post),
      categories: categories(post)
    }
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
