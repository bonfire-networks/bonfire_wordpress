defmodule Bonfire.WordPress.Import.WXR.Handler do
  @moduledoc """
  The `Saxy` event handler for `Bonfire.WordPress.Import.WXR`: collects one `<item>` at a time (its fields and `wp:postmeta`), and passes it to `WXR.handle_item/2` when the item ends. Comments inside an item are skipped for now.
  """
  @behaviour Saxy.Handler

  alias Bonfire.WordPress.Import.WXR

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  def handle_event(:end_document, _data, state), do: {:ok, state}

  def handle_event(:start_element, {"item", _attrs}, state),
    do: {:ok, %{state | item: %{"meta" => %{}}, text: []}}

  def handle_event(:start_element, {"wp:comment", _attrs}, state),
    do: {:ok, %{state | in_comment?: true, text: []}}

  def handle_event(:start_element, {"wp:postmeta", _attrs}, state),
    do: {:ok, %{state | meta_key: nil, meta_value: nil, text: []}}

  # the channel's list of authors, which items name by login in `dc:creator`
  def handle_event(:start_element, {"wp:author", _attrs}, %{item: nil} = state),
    do: {:ok, %{state | author: %{}, text: []}}

  def handle_event(:start_element, _element, state), do: {:ok, %{state | text: []}}

  def handle_event(:characters, chars, state), do: {:ok, %{state | text: [state.text | chars]}}

  def handle_event(:end_element, "wp:comment", state), do: {:ok, %{state | in_comment?: false}}

  def handle_event(:end_element, _name, %{in_comment?: true} = state), do: {:ok, state}

  def handle_event(:end_element, "item", %{item: item} = state) when is_map(item),
    do: {:ok, WXR.handle_item(item, %{state | item: nil, text: []})}

  def handle_event(:end_element, "wp:meta_key", %{item: item} = state) when is_map(item),
    do: {:ok, %{state | meta_key: text(state)}}

  def handle_event(:end_element, "wp:meta_value", %{item: item} = state) when is_map(item),
    do: {:ok, %{state | meta_value: text(state)}}

  def handle_event(:end_element, "wp:postmeta", %{item: item, meta_key: key} = state)
      when is_map(item) and is_binary(key),
      do: {:ok, %{state | item: put_in(item, ["meta", key], state.meta_value)}}

  def handle_event(:end_element, name, %{item: item} = state) when is_map(item) do
    if WXR.item_field?(name),
      do: {:ok, %{state | item: Map.put(item, name, text(state))}},
      else: {:ok, state}
  end

  def handle_event(:end_element, "wp:base_site_url", state),
    do: {:ok, %{state | base_site_url: text(state)}}

  def handle_event(
        :end_element,
        "wp:author",
        %{author: %{"wp:author_login" => login} = author} = state
      )
      when is_binary(login) and login != "",
      do: {:ok, %{state | author: nil, authors: Map.put(state.authors, login, author)}}

  def handle_event(:end_element, "wp:author", state), do: {:ok, %{state | author: nil}}

  def handle_event(:end_element, name, %{author: author} = state)
      when is_map(author) and
             name in ["wp:author_login", "wp:author_email", "wp:author_display_name"],
      do: {:ok, %{state | author: Map.put(author, name, text(state))}}

  def handle_event(:end_element, _name, state), do: {:ok, state}

  defp text(state), do: state.text |> IO.iodata_to_binary() |> String.trim()
end
