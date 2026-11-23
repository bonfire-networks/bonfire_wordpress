defmodule Bonfire.WordPress.XMLRPC do
  @moduledoc """
  The XML-RPC that WordPress's "update services" send (Settings > Writing on the site): `weblogUpdates.ping(site name, home URL)` and `weblogUpdates.extendedPing(site name, home URL, changed URL, feed URL)`, and the answers they expect.

  The body comes from anyone, so a document with a DTD is refused before parsing, and the parser (`Saxy`) never expands entities.
  """
  @behaviour Saxy.Handler

  @methods ["weblogUpdates.ping", "weblogUpdates.extendedPing"]

  @doc "The method and the pinging site's home URL, or `{:error, :dtd}` for a body with a DTD, or `{:error, :not_a_ping}`."
  def parse_ping(body) when is_binary(body) do
    if String.contains?(String.downcase(body), "<!doctype") do
      {:error, :dtd}
    else
      # Saxy's default (`expand_entity: :keep`) decodes `&amp;` and the like, and leaves any other entity as text
      case Saxy.parse_string(body, __MODULE__, %{in_value?: false, text: [], method: nil, params: []}) do
        {:ok, %{method: method, params: params}} when method in @methods ->
          case Enum.reverse(params) do
            [_name, home_url | _] -> {:ok, %{method: method, home_url: home_url}}
            _ -> {:error, :not_a_ping}
          end

        _ ->
          {:error, :not_a_ping}
      end
    end
  end

  def parse_ping(_), do: {:error, :not_a_ping}

  @doc "The answer to a ping it took, in the `weblogUpdates` convention."
  def thanks,
    do:
      ~s(<?xml version="1.0"?><methodResponse><params><param><value><struct>) <>
        ~s(<member><name>flerror</name><value><boolean>0</boolean></value></member>) <>
        ~s(<member><name>message</name><value><string>Thanks for the ping.</string></value></member>) <>
        ~s(</struct></value></param></params></methodResponse>)

  @doc "The answer to a body that isn't a ping it can read."
  def fault,
    do:
      ~s(<?xml version="1.0"?><methodResponse><fault><value><struct>) <>
        ~s(<member><name>faultCode</name><value><int>400</int></value></member>) <>
        ~s(<member><name>faultString</name><value><string>Not a weblogUpdates ping</string></value></member>) <>
        ~s(</struct></value></fault></methodResponse>)

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}
  def handle_event(:end_document, _data, state), do: {:ok, state}

  def handle_event(:start_element, {"value", _}, state),
    do: {:ok, %{state | in_value?: true, text: []}}

  def handle_event(:start_element, {"methodName", _}, state), do: {:ok, %{state | text: []}}
  def handle_event(:start_element, _element, state), do: {:ok, state}

  def handle_event(:characters, chars, state), do: {:ok, %{state | text: [state.text | chars]}}

  def handle_event(:end_element, "methodName", state),
    do: {:ok, %{state | method: text(state)}}

  def handle_event(:end_element, "value", %{in_value?: true} = state),
    do: {:ok, %{state | in_value?: false, params: [text(state) | state.params]}}

  def handle_event(:end_element, _name, state), do: {:ok, state}

  defp text(state), do: state.text |> IO.iodata_to_binary() |> String.trim()
end
