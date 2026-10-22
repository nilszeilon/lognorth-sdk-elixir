defmodule Lognorth.Transport.Httpc do
  @moduledoc false
  # Plain JSON to LogNorth's ingestion API; no protobuf, no OTel.

  @spec post(String.t(), String.t(), iodata(), timeout()) ::
          {:ok, non_neg_integer(), non_neg_integer() | nil} | {:error, term()}
  def post(endpoint, key, body, timeout) do
    url = String.to_charlist(String.trim_trailing(endpoint, "/") <> "/api/v1/events/batch")

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> key)},
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"},
      {~c"user-agent", ~c"lognorth-elixir/0.1.0"}
    ]

    http_opts = [timeout: timeout, connect_timeout: min(timeout, 5_000)] ++ ssl_opts(endpoint)
    request = {url, headers, ~c"application/json", body}

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, _body}} ->
        {:ok, status, retry_after(response_headers)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ssl_opts("https://" <> _ = endpoint) do
    host = endpoint |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist()

    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        server_name_indication: host,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp ssl_opts(_), do: []

  defp retry_after(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "retry-after", do: to_string(value)
    end)
    |> parse_seconds()
  end

  defp parse_seconds(nil), do: nil

  defp parse_seconds(value) do
    case Integer.parse(value) do
      {seconds, _} -> seconds * 1_000
      :error -> nil
    end
  end
end
