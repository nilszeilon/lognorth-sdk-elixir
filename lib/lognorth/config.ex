defmodule Lognorth.Config do
  @moduledoc false

  # Read on every event, so it is kept where reads are cheap.
  @key {:lognorth, :config}

  def put(config) when is_map(config), do: :persistent_term.put(@key, config)

  def get, do: :persistent_term.get(@key, %{})

  def configured? do
    case get() do
      %{endpoint: endpoint, api_key: key} when is_binary(endpoint) and is_binary(key) -> true
      _ -> false
    end
  end
end
