defmodule Lognorth.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Lognorth.Client, []}
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Lognorth.Supervisor) do
      maybe_install()
      {:ok, pid}
    end
  end

  # The application is silent until a url and a key are configured.
  defp maybe_install do
    cfg = Application.get_all_env(:lognorth)
    url = cfg[:url]
    key = cfg[:key]

    if is_binary(url) and url != "" and is_binary(key) and key != "" do
      Lognorth.config(url, key,
        environment: cfg[:environment],
        release: cfg[:release],
        transport: cfg[:transport],
        flush_interval: cfg[:flush_interval]
      )

      if Keyword.get(cfg, :attach_logger, true), do: Lognorth.attach(cfg[:level] || :info)
    end

    :ok
  end
end
