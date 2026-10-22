defmodule Lognorth do
  @moduledoc """
  LogNorth for Elixir.

  Two ways in, the same as the Ruby and Go clients:

    * a `:logger` handler, so every `Logger.info/1` and `Logger.error/1` in the
      application becomes an event — `Lognorth.attach/1`;
    * the calls `Lognorth.log/2` and `Lognorth.error/3` for events you want to
      describe yourself.

  Configure it in `config/runtime.exs`:

      config :lognorth,
        url: System.get_env("LOGNORTH_URL"),
        key: System.get_env("LOGNORTH_API_KEY"),
        environment: System.get_env("APP_ENV", "production"),
        release: System.get_env("GIT_SHA")

  The `:lognorth` application starts the sender and attaches the handler when a
  url and a key are set. Without them the library does nothing and costs a
  function call.

  In a request, the trace ID and the user are kept per process, which is the
  Elixir equivalent of the thread-local in the Ruby client:

      Lognorth.user(user.id)
      Lognorth.trace_id(conn.get_resp_header("x-request-id"))
      # ... and Lognorth.end_request/0 when it is done (the Plug does it)

  `Lognorth.Plug` does all of that for a Plug or Phoenix endpoint.
  """

  alias Lognorth.Client

  @doc """
  Configures the client. Options:

    * `:environment` — stamped on every event as `context.environment`
    * `:release` — stamped on errors; announced once as "Release … started"
    * `:transport` — the module that posts a batch (default `Lognorth.Transport.Httpc`)
    * `:flush_interval` — milliseconds an event may wait for a batch (default 5000)
  """
  def config(url, key, opts \\ []) do
    Client.configure(url, key, opts)
  end

  @doc "Adds an event that is not an error."
  def log(message, context \\ %{}) do
    Client.log(message, context)
  end

  @doc """
  Adds an error event. `exception` is anything with a `message` and a
  `__struct__`; an Elixir exception or a map with `:class`, `:message` and
  `:stacktrace` both work.
  """
  def error(message, exception, context \\ %{}) do
    Client.error(message, exception, context)
  end

  @doc "Sends what is queued now. Returns how many events are left."
  def flush, do: Client.flush()

  @doc "Attaches the Logger handler. Called by the application when configured."
  def attach(level \\ :info) do
    config = %{level: level}
    _ = :logger.remove_handler(:lognorth)
    :logger.add_handler(:lognorth, Lognorth.LoggerHandler, config)
  end

  @doc "Removes the Logger handler."
  def detach do
    :logger.remove_handler(:lognorth)
  end

  @doc "Names the user of the current request: an ID, not an email."
  def user(id), do: Process.put(:lognorth_user, to_string(id))
  def user, do: Process.get(:lognorth_user)

  @doc "Sets the trace ID of the current request."
  def trace_id(id), do: Process.put(:lognorth_trace_id, to_string(id))
  def trace_id, do: Process.get(:lognorth_trace_id)

  @doc "Forgets the trace ID and the user of the current process."
  def end_request do
    Process.delete(:lognorth_trace_id)
    Process.delete(:lognorth_user)
    :ok
  end
end
