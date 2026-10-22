defmodule Lognorth.Client do
  @moduledoc false
  use GenServer
  require Logger

  alias Lognorth.{Config, Event}

  # The same limits as the Ruby and Go clients.
  @max_buffer 10_000
  @max_buffer_bytes 10 * 1024 * 1024
  @max_batch 500
  @max_batch_bytes 1024 * 1024

  @flush_interval 5_000
  @first_backoff 1_000
  @max_backoff 60_000
  @first_config_backoff 60_000
  @max_config_backoff 300_000
  @request_timeout 10_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # ── API ────────────────────────────────────────────────────────────

  def configure(url, key, opts \\ []) do
    GenServer.call(__MODULE__, {:configure, url, key, opts})
  end

  def log(message, context \\ %{}), do: event(message, context, [])

  def error(message, exception, context \\ %{}), do: error(message, exception, context, [])

  def error(message, exception, context, opts) when is_list(opts) do
    emit(Event.build_error(message, exception, context, event_opts(opts)), :error)
  end

  def event(message, context, opts) do
    if Config.configured?() do
      emit(Event.build(message, context, event_opts(opts)), :normal)
    else
      :ok
    end
  end

  @doc false
  def emit(event, kind), do: GenServer.cast(__MODULE__, {:enqueue, event, kind})

  @doc false
  def logger_event(level, text, meta) do
    if Config.configured?() do
      trace_id = meta[:request_id] || Lognorth.trace_id()

      context = %{
        "level" => to_string(level),
        "file" => meta[:file] && to_string(meta[:file]),
        "line" => meta[:line],
        "mfa" => mfa(meta[:mfa]),
        "domain" => domain(meta[:domain])
      }

      if error_level?(level) do
        parsed = Event.parse_text(text)
        message = error_message(parsed, text)

        event =
          Event.build(message, Map.merge(context, parsed),
            trace_id: trace_id,
            timestamp: meta[:time]
          )

        emit(event, :error)
      else
        emit(
          Event.build(Event.first_line(text), context, trace_id: trace_id, timestamp: meta[:time]),
          :normal
        )
      end
    end

    :ok
  end

  def flush, do: GenServer.call(__MODULE__, :flush, @request_timeout + 5_000)

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    transport = Application.get_env(:lognorth, :transport, Lognorth.Transport.Httpc)
    interval = Application.get_env(:lognorth, :flush_interval, @flush_interval)

    {:ok,
     %{
       queue: :queue.new(),
       bytes: 0,
       entries: 0,
       dropped: 0,
       dropped_errors: 0,
       retry_at: nil,
       backoff: @first_backoff,
       config_backoff: @first_config_backoff,
       in_flight: false,
       timer: nil,
       batch_sizes: [],
       transport: transport,
       interval: interval
     }}
  end

  @impl true
  def handle_call({:configure, url, key, opts}, _from, state) do
    config = %{
      endpoint: String.trim_trailing(url, "/"),
      api_key: key,
      environment: opts[:environment],
      release: opts[:release]
    }

    Config.put(config)

    state =
      state
      |> Map.put(:transport, opts[:transport] || state.transport)
      |> Map.put(:interval, opts[:flush_interval] || state.interval)

    # LogNorth takes the first start of a release as the deploy time.
    state =
      case {opts[:release], Config.get()[:announced]} do
        {release, announced} when is_binary(release) and release != "" and release != announced ->
          Config.put(Map.put(Config.get(), :announced, release))

          enqueue(
            state,
            Event.build("Release #{release} started", %{"release" => release}),
            :normal
          )

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | queue: :queue.new(), bytes: 0, entries: 0, retry_at: nil}}
  end

  def handle_call(:flush, _from, state) do
    {state, _} = state |> Map.put(:retry_at, nil) |> send_now(@request_timeout)
    {:reply, state.entries, state}
  end

  @impl true
  def handle_cast({:enqueue, event, kind}, state), do: {:noreply, enqueue(state, event, kind)}

  def handle_cast({:sent, entries, result}, state) do
    state = %{state | in_flight: false}
    {:noreply, handle_result(state, entries, result)}
  end

  @impl true
  def handle_info(:flush, state) do
    state = %{state | timer: nil}
    {state, _} = send_now(state, @request_timeout)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # One last attempt, bounded; what is left is lost and said so.
    {state, _} = send_now(state, 5_000)
    left = state.entries

    if left > 0 do
      Logger.warning("[Lognorth] exiting with #{left} unsent event(s); they are lost")
    end

    :ok
  end

  # ── queue ──────────────────────────────────────────────────────────

  defp enqueue(state, event, kind) do
    entry = %{event: event, bytes: byte_size(Jason.encode!(event)), error: kind == :error}
    state = push(state, entry)
    schedule(state, kind == :error)
  end

  defp push(state, entry) do
    state = %{
      state
      | queue: :queue.in(entry, state.queue),
        bytes: state.bytes + entry.bytes,
        entries: state.entries + 1
    }

    drop_oldest(state)
  end

  defp drop_oldest(state) do
    if over_limit?(state) do
      state |> drop_one() |> drop_oldest()
    else
      state
    end
  end

  defp over_limit?(state), do: state.entries > @max_buffer or state.bytes > @max_buffer_bytes

  defp drop_one(state) do
    case pop_oldest(state.queue) do
      {nil, queue} -> %{state | queue: queue}
      {entry, queue} -> apply_drop(state, entry, queue)
    end
  end

  defp apply_drop(state, entry, queue) do
    warn_queue_full(state)

    %{
      state
      | queue: queue,
        bytes: state.bytes - entry.bytes,
        entries: state.entries - 1,
        dropped: state.dropped + 1,
        dropped_errors: state.dropped_errors + if(entry.error, do: 1, else: 0)
    }
  end

  defp warn_queue_full(%{dropped: 0}) do
    Logger.warning("[Lognorth] queue full, dropping the oldest events")
  end

  defp warn_queue_full(_state), do: :ok

  # An error leaves first only when the queue holds nothing else.
  defp pop_oldest(queue) do
    case :queue.to_list(queue) do
      [] ->
        {nil, queue}

      entries ->
        index = Enum.find_index(entries, &(not &1.error)) || 0
        {entry, rest} = List.pop_at(entries, index)
        {entry, :queue.from_list(rest)}
    end
  end

  defp schedule(%{entries: 0} = state, _urgent), do: cancel_timer(state)

  defp schedule(state, urgent) do
    cond do
      urgent or state.entries >= 10 or state.bytes > div(@max_buffer_bytes, 2) ->
        send(self(), :flush)
        cancel_timer(state)

      state.timer == nil ->
        %{state | timer: Process.send_after(self(), :flush, due_in(state))}

      true ->
        state
    end
  end

  defp due_in(%{retry_at: retry_at}) when is_integer(retry_at) do
    max(retry_at - now(), 0)
  end

  defp due_in(%{interval: interval}), do: interval

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  # ── sending ────────────────────────────────────────────────────────

  defp send_now(%{in_flight: true} = state, _timeout), do: {state, :busy}

  defp send_now(state, timeout) do
    cond do
      state.entries == 0 ->
        {cancel_timer(state), :empty}

      is_integer(state.retry_at) and state.retry_at > now() ->
        {reschedule(state), :waiting}

      true ->
        {batch, state} = take_batch(state)
        result = post(state, batch, timeout)
        state = handle_result(%{state | in_flight: false}, batch, result)
        {state, :sent}
    end
  end

  defp post(state, batch, timeout) do
    body = Jason.encode!(%{"events" => Enum.map(batch, & &1.event)})
    config = Config.get()
    state.transport.post(config.endpoint, config.api_key, body, timeout)
  rescue
    error -> {:error, error}
  end

  defp take_batch(state) do
    {batch, bytes} = take(state.queue, [], 12, 0)
    {_entries, queue} = :queue.split(length(batch), state.queue)

    remaining_bytes = state.bytes - bytes
    remaining = state.entries - length(batch)

    state = %{state | queue: queue, bytes: remaining_bytes, entries: remaining}
    state = if remaining == 0, do: %{state | retry_at: nil, batch_sizes: []}, else: state
    {batch, state}
  end

  defp take(queue, acc, bytes, count) do
    case :queue.out(queue) do
      {{:value, entry}, _rest}
      when count < @max_batch and (bytes + entry.bytes <= @max_batch_bytes or count == 0) ->
        take(:queue.drop(queue), [entry | acc], bytes + entry.bytes + 1, count + 1)

      _ ->
        {Enum.reverse(acc), bytes}
    end
  end

  # Puts the batch back at the front, in order.
  defp put_back(state, batch, delay) do
    bytes = Enum.reduce(batch, 0, &(&1.bytes + &2))

    state = %{
      state
      | queue: :queue.join(:queue.from_list(batch), state.queue),
        bytes: state.bytes + bytes,
        entries: state.entries + length(batch),
        batch_sizes: [length(batch) | state.batch_sizes],
        retry_at: now() + delay
    }

    drop_oldest(state)
  end

  defp handle_result(state, _batch, {:ok, status, _retry_after}) when status in 200..299 do
    %{state | backoff: @first_backoff, config_backoff: @first_config_backoff} |> reschedule()
  end

  defp handle_result(state, batch, {:ok, status, retry_after}) when status in [429, 503] do
    delay = retry_after || next_backoff(state)

    state
    |> put_back(batch, delay)
    |> Map.put(:backoff, min(state.backoff * 2, @max_backoff))
    |> reschedule()
  end

  defp handle_result(state, batch, {:ok, status, _}) when status in [408] or status in 500..599 do
    state
    |> put_back(batch, jitter(state.backoff))
    |> Map.put(:backoff, min(state.backoff * 2, @max_backoff))
    |> reschedule()
  end

  defp handle_result(state, batch, {:ok, status, _}) when status in [401, 403, 404] do
    if state.config_backoff == @first_config_backoff do
      Logger.warning("[Lognorth] the server answered #{status}: check the url and the key")
    end

    state
    |> put_back(batch, state.config_backoff)
    |> Map.put(:config_backoff, min(state.config_backoff * 2, @max_config_backoff))
    |> reschedule()
  end

  defp handle_result(state, batch, {:ok, status, _}) when status in 400..499 do
    Logger.warning("[Lognorth] the server refused #{length(batch)} event(s) with #{status}")
    %{state | dropped: state.dropped + length(batch)} |> reschedule()
  end

  defp handle_result(state, batch, {:ok, status, _}) do
    Logger.warning("[Lognorth] unexpected answer #{status}; is the url right?")
    state |> put_back(batch, state.config_backoff) |> reschedule()
  end

  defp handle_result(state, batch, {:error, reason}) do
    if state.backoff == @first_backoff do
      Logger.debug("[Lognorth] send failed: #{inspect(reason)}")
    end

    state
    |> put_back(batch, jitter(state.backoff))
    |> Map.put(:backoff, min(state.backoff * 2, @max_backoff))
    |> reschedule()
  end

  defp reschedule(%{entries: 0} = state), do: cancel_timer(state)

  defp reschedule(state) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :flush, due_in(state))}
  end

  # ── helpers ────────────────────────────────────────────────────────

  defp event_opts(opts) do
    Keyword.put_new_lazy(opts, :release, fn -> Config.get()[:release] end)
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp next_backoff(state), do: state.backoff
  defp jitter(delay), do: delay + :rand.uniform(div(delay, 2) + 1)

  defp error_level?(level), do: level in [:error, :critical, :alert, :emergency]

  defp error_message(parsed, text) do
    case {parsed["error_class"], parsed["error"]} do
      {nil, nil} -> Event.first_line(text)
      {nil, message} -> message
      {class, nil} -> class
      {class, message} -> "#{class}: #{message}"
    end
  end

  defp mfa({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"
  defp mfa(_), do: nil

  defp domain(domain) when is_list(domain), do: Enum.map(domain, &to_string/1)
  defp domain(_), do: nil
end
