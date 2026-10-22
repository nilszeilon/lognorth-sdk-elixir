defmodule Lognorth.Event do
  @moduledoc false

  # The same limits as the Ruby and Go clients.
  @max_message_chars 1_000
  @max_event_bytes 64 * 1024
  @max_stack_trace_bytes 16 * 1024
  @max_string_bytes 8 * 1024

  # The context keys an event keeps when it is still too big after trimming.
  @essential ~w(error error_class error_file error_line method path status environment release user)

  @frame ~r/^\s+\(([\w.\-]+) ([\w.\-+]+)\) (\S+?):(\d+): (.+)$/m
  @exception ~r/^\*\* \(([A-Za-z][\w.]*)\)\s*(.*)$/m

  @doc "Builds an event map ready for JSON."
  def build(message, context, opts \\ []) do
    event = %{
      "message" => to_string(message),
      "timestamp" => timestamp(opts[:timestamp]),
      "context" =>
        context
        |> normalize()
        |> put_if("environment", opts[:environment] || environment())
        |> put_if("user", opts[:user] || Lognorth.user())
    }

    event
    |> put_if("trace_id", opts[:trace_id])
    |> put_if("duration_ms", opts[:duration_ms])
    |> stamp_release(opts[:release])
    |> trim()
  end

  @doc "Builds an error event from an exception or from parsed text."
  def build_error(message, exception, context, opts \\ []) do
    info = exception_info(exception)

    context
    |> Map.merge(info)
    |> then(&build(message, &1, opts))
  end

  @doc "True when the event must be treated as an error: an error, or a 5xx."
  def error?(event) do
    context = event["context"] || %{}
    status = context["status"]

    not is_nil(context["error"]) or not is_nil(context["error_class"]) or
      (is_integer(status) and status >= 500)
  end

  @doc """
  Reads the Elixir exception out of a log line. Phoenix writes
  `** (RuntimeError) boom` and then indented frames
  `(app 1.2.3) lib/app/foo.ex:12: App.Foo.bar/0`.
  """
  def parse_text(text) when is_binary(text) do
    frames = Regex.scan(@frame, text) |> Enum.map(&frame_text/1)
    {class, message} = exception_from_text(text)

    %{}
    |> put_if("error_class", class)
    |> put_if("error", message)
    |> put_if("error_file", first_file(frames))
    |> put_if("error_line", first_frame_line(frames))
    |> put_if("error_caller", first_caller(frames))
    |> put_if("stack_trace", if(frames == [], do: nil, else: Enum.join(frames, "\n")))
  end

  @doc "The first line of a message, cut to the message limit."
  def first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, @max_message_chars)
  end

  # ── trimming ───────────────────────────────────────────────────────

  def trim(event) do
    message = event["message"] || ""
    message = String.slice(message, 0, @max_message_chars)
    trimmed? = message != (event["message"] || "")

    {context, trimmed_context?} =
      case event["context"] do
        context when is_map(context) -> trim_context(context)
        other -> {normalize(other), false}
      end

    event = %{event | "message" => message, "context" => context}
    trimmed? = trimmed? or trimmed_context?

    {event, trimmed?} =
      if byte_size(Jason.encode!(event)) > @max_event_bytes do
        essential = Map.take(context, @essential)
        {%{event | "context" => essential}, true}
      else
        {event, trimmed?}
      end

    if trimmed?, do: Map.update!(event, "context", &Map.put(&1, "truncated", true)), else: event
  end

  defp trim_context(context) do
    Enum.reduce(context, {%{}, false}, fn {key, value}, {acc, trimmed?} ->
      limit =
        if to_string(key) == "stack_trace", do: @max_stack_trace_bytes, else: @max_string_bytes

      if is_binary(value) and byte_size(value) > limit do
        {Map.put(acc, key, value |> safe_slice(limit)), true}
      else
        {Map.put(acc, key, value), trimmed?}
      end
    end)
  end

  defp safe_slice(value, limit) do
    if String.valid?(value) do
      String.slice(value, 0, limit)
    else
      value |> binary_part(0, min(byte_size(value), limit)) |> String.replace_suffix("", "")
    end
  end

  # ── exceptions ─────────────────────────────────────────────────────

  defp exception_info(%{__struct__: module} = exception) do
    message =
      try do
        Exception.message(exception)
      rescue
        _ -> inspect(exception, limit: 10)
      end

    %{
      "error" => message,
      "error_class" => inspect(module),
      "error_file" => "",
      "error_line" => 0,
      "error_caller" => "",
      "stack_trace" => ""
    }
  end

  defp exception_info(%{class: class, message: message} = info) do
    stack = info[:stacktrace] || info[:stack_trace] || []
    {file, line, caller, stack_text} = stack_info(stack)

    %{
      "error" => to_string(message),
      "error_class" => to_string(class),
      "error_file" => file,
      "error_line" => line,
      "error_caller" => caller,
      "stack_trace" => stack_text
    }
  end

  defp exception_info(other) do
    %{
      "error" => inspect(other, limit: 10),
      "error_class" => "",
      "error_file" => "",
      "error_line" => 0,
      "error_caller" => "",
      "stack_trace" => ""
    }
  end

  defp stack_info([]), do: {"", 0, "", ""}

  defp stack_info(stack) when is_list(stack) do
    frames = Enum.map(stack, &stack_frame/1)
    {file, line, caller} = first_location(stack)

    {file, line, caller, frames |> Enum.reject(&is_nil/1) |> Enum.join("\n")}
  end

  defp stack_info(_), do: {"", 0, "", ""}

  defp stack_frame({module, fun, arity, location}) do
    file = location[:file] && to_string(location[:file])
    line = location[:line]

    if file,
      do: "#{inspect(module)}.#{fun}/#{arity} (#{file}:#{line})",
      else: "#{inspect(module)}.#{fun}/#{arity}"
  end

  defp stack_frame(_), do: nil

  defp first_location([{module, fun, arity, location} | _]) do
    file = location[:file] && Path.basename(to_string(location[:file]))
    line = location[:line] || 0
    {file || "", line, "#{inspect(module)}.#{fun}/#{arity}"}
  end

  defp first_location(_), do: {"", 0, ""}

  # ── text parsing ───────────────────────────────────────────────────

  defp exception_from_text(text) do
    case Regex.run(@exception, text) do
      [_, class, message] when class in ["exit", "throw", "error"] -> {nil, String.trim(message)}
      [_, class, message] -> {class, String.trim(message)}
      nil -> {nil, first_line(text)}
    end
  end

  defp frame_text([_, app, version, file, line, caller]) do
    "(#{app} #{version}) #{file}:#{line}: #{caller}"
  end

  defp first_file([frame | _]) do
    case Regex.run(~r/\) (\S+?):(\d+):/, frame) do
      [_, file, _line] -> Path.basename(file)
      _ -> ""
    end
  end

  defp first_file(_), do: ""

  defp first_line_of_frame(nil), do: 0

  defp first_line_of_frame(frame) do
    case Regex.run(~r/:(\d+):/, frame) do
      [_, line] -> String.to_integer(line)
      _ -> 0
    end
  end

  defp first_frame_line(frames), do: first_line_of_frame(List.first(frames))

  defp first_caller([frame | _]) do
    case Regex.run(~r/:\d+: (.+)$/, frame) do
      [_, caller] -> caller
      _ -> ""
    end
  end

  defp first_caller(_), do: ""

  # ── helpers ────────────────────────────────────────────────────────

  defp environment, do: Lognorth.Config.get()[:environment]

  def stamp_release(event, nil), do: event

  def stamp_release(event, release) do
    if error?(event) do
      Map.update!(event, "context", &Map.put(&1, "release", release))
    else
      event
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc false
  def normalize(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {to_string(key), normalize(val)} end)
  end

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value) when is_binary(value), do: value
  def normalize(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  def normalize(value) when is_atom(value), do: Atom.to_string(value)
  def normalize(value), do: inspect(value, limit: 20, printable_limit: 2_000)

  defp timestamp(nil),
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp timestamp(%DateTime{} = at),
    do: at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp timestamp(us) when is_integer(us) do
    us
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end
end
