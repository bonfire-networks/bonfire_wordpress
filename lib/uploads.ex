defmodule Bonfire.WordPress.Uploads do
  @moduledoc """
  The uploads a WordPress post shows in its body, as entries for `Bonfire.WordPress.Posts.import_post/2` (its `images`), whether they come from an export's attachments (`Bonfire.WordPress.Import.WXR`) or the site's media API (`Bonfire.WordPress.API`): one entry per upload, at the largest size the post shows it, with each `src` that shows it, every URL of its sizes, and its alt text, caption and description.
  """

  @doc """
  Each `<img>` in `html` once, in order, as `{src, upload id}`, the id from the `wp-image-<id>` class WordPress gives an image it inserts (nil without one).
  """
  def img_tags(html) when is_binary(html) do
    ~r/<img\b[^>]*>/i
    |> Regex.scan(html)
    |> Enum.flat_map(fn [tag] ->
      case Regex.run(~r/\bsrc\s*=\s*["']([^"']+)["']/i, tag, capture: :all_but_first) do
        [src] -> [{src, wp_image_id(tag)}]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  def img_tags(_), do: []

  @doc "The alt text of each `<img>` in `html` that has one, by its `src`."
  def img_alts(html) when is_binary(html) do
    for [tag] <- Regex.scan(~r/<img\b[^>]*>/i, html),
        [src] <- [Regex.run(~r/\bsrc\s*=\s*["']([^"']+)["']/i, tag, capture: :all_but_first)],
        [alt] <- [Regex.run(~r/\balt\s*=\s*["']([^"']*)["']/i, tag, capture: :all_but_first)],
        String.trim(alt) != "",
        into: %{},
        do: {src, alt}
  end

  def img_alts(_), do: %{}

  defp wp_image_id(tag) do
    case Regex.run(~r/\bclass\s*=\s*["'][^"']*\bwp-image-(\d+)\b/i, tag, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      _ -> nil
    end
  end

  @doc """
  The entries for what a post shows, from `shown`, a list of `{upload id, src, url, width, source}` (one per `<img>` found to show that upload, `url` the absolute URL of the size it shows, `width` that size's): one per upload, at the largest size shown, with each `src` that shows it. `to_entry` makes an upload's entry from its `source`, id, URL and width (see `entry/1`).
  """
  def group(shown, to_entry) when is_function(to_entry, 4) do
    shown
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {id, shown} ->
      {_, _, url, width, source} = Enum.max_by(shown, &elem(&1, 3))

      source
      |> to_entry.(id, url, width)
      |> Map.put(:srcs, Enum.map(shown, &elem(&1, 1)))
    end)
  end

  @doc """
  An upload's entry from what the site has for it: `id`, the `url` and `width` it's shown at, its `media_type`, its `sizes` (`{url, width}` of the original and each size WordPress made), and its `alt`, `caption`, `description` and `title`, as text or HTML. Each of the alt text, caption and description is kept only when it adds something to the ones before it (WordPress often repeats the alt text as the caption, and the caption or the title as the description). The title is left out: it's the file's name more often than not.
  """
  def entry(%{id: id, url: url, width: width} = upload) do
    alt = text(upload[:alt])
    caption = text(upload[:caption])
    description = text(upload[:description])
    title = text(upload[:title])

    %{
      url: url,
      media_type: upload[:media_type],
      alt: alt,
      caption: if(not same_text?(caption, [alt]), do: caption),
      description: if(not same_text?(description, [alt, caption, title]), do: description),
      primary?: false,
      wp_id: id,
      width: width,
      urls: for({size_url, _} <- upload[:sizes] || [], form <- scheme_forms(size_url), do: form)
    }
  end

  defp text(value) when is_binary(value) do
    case value |> Bonfire.Common.Text.text_only() |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp text(_), do: nil

  # whether `text` says nothing more than one of `others`, ignoring case, spaces and punctuation
  defp same_text?(nil, _others), do: true

  defp same_text?(text, others),
    do: Enum.any?(others, &(is_binary(&1) and comparable(&1) == comparable(text)))

  defp comparable(text), do: text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "")

  @doc "A URL with each scheme (`https` and `http`), since a site's posts often link its own files with either."
  def scheme_forms("https://" <> rest), do: ["https://" <> rest, "http://" <> rest]
  def scheme_forms("http://" <> rest), do: ["https://" <> rest, "http://" <> rest]
  def scheme_forms(url), do: [url]

  @doc "A URL as a key whatever its scheme (its host and path), or nil."
  def url_key(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) and host != "" ->
        String.downcase(host) <> (path || "")

      _ ->
        nil
    end
  end

  def url_key(_), do: nil

  @doc "An `<img src>` as an absolute URL on `site` (a protocol-relative one as `https`), or nil for one relative to its page."
  def absolute_url("//" <> rest, _site), do: "https://" <> rest
  def absolute_url("http" <> _ = url, _site), do: url

  def absolute_url("/" <> _ = path, site) when is_binary(site),
    do: URI.merge(site, path) |> to_string()

  def absolute_url(_, _), do: nil
end
