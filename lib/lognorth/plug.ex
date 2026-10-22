if Code.ensure_loaded?(Plug) do
  defmodule Lognorth.Plug do
    @moduledoc """
    One event per request, with the trace ID and the user that the rest of the
    request logs carry.

        # router.ex, before the pipeline
        plug Lognorth.Plug

        # or with options
        plug Lognorth.Plug, ignored_paths: ["/up", "/health"], user: &MyApp.Auth.user_id/1

    Requests that answer 5xx are flushed at once. 404s that match no route are
    skipped, like the Ruby client skips scanner noise.
    """
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: Map.new(opts)

    @impl true
    def call(conn, opts) do
      # Tells the Logger handler that this request is already an event.
      Process.put(:lognorth_plug, true)
      path = conn.request_path

      if ignored?(path, opts) do
        conn
      else
        trace_id = trace_id(conn, opts)
        Lognorth.trace_id(trace_id)
        maybe_user(conn, opts)
        started = System.monotonic_time()

        conn
        |> put_resp_header("x-trace-id", trace_id)
        |> register_before_send(fn conn -> finish(conn, path, trace_id, started) end)
      end
    end

    defp finish(conn, path, trace_id, started) do
      status = conn.status || 0

      duration =
        System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

      context =
        %{"method" => conn.method, "path" => path, "status" => status}
        |> route(conn)
        |> user_agent(conn, status)

      Lognorth.Client.event(
        "#{conn.method} #{path} → #{status}",
        context,
        trace_id: trace_id,
        duration_ms: duration
      )

      if status >= 500, do: Lognorth.flush()
      Lognorth.end_request()
      conn
    end

    defp ignored?(path, opts) do
      opts
      |> Map.get(:ignored_paths, [])
      |> Enum.any?(fn ignored -> path == ignored or String.starts_with?(path, ignored <> "/") end)
    end

    defp trace_id(conn, opts) do
      header = Map.get(opts, :trace_header, "x-request-id")

      request_id = conn |> get_req_header(header) |> List.first()
      response_id = conn |> get_resp_header(header) |> List.first()

      request_id || response_id || random_trace_id()
    end

    defp random_trace_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    defp maybe_user(conn, opts) do
      case Map.get(opts, :user) do
        fun when is_function(fun, 1) ->
          case fun.(conn) do
            nil -> :ok
            id -> Lognorth.user(id)
          end

        nil ->
          :ok

        other ->
          raise ArgumentError,
                "Lognorth.Plug :user must be a function of the conn, got: #{inspect(other)}"
      end
    end

    defp route(context, conn) do
      context
      |> put_if("controller", conn.private[:phoenix_controller])
      |> put_if("action", conn.private[:phoenix_action])
    end

    defp user_agent(context, conn, status) when status >= 500 do
      case get_req_header(conn, "user-agent") do
        [agent | _] -> Map.put(context, "user_agent", agent)
        _ -> context
      end
    end

    defp user_agent(context, _conn, _status), do: context

    defp put_if(map, _key, nil), do: map
    defp put_if(map, key, value), do: Map.put(map, key, inspect(value))
  end
end
