defmodule Lognorth.LoggerHandler do
  @moduledoc false
  # The :logger handler callbacks: log/2, adding_handler/1, removing_handler/1,
  # changing_config/3. OTP documents them but ships no behaviour module for them.
  def adding_handler(config), do: {:ok, config}

  def removing_handler(_config), do: :ok

  def changing_config(_set, _old, new), do: {:ok, new}

  def log(%{level: level, msg: msg, meta: meta}, config) do
    if :logger.compare_levels(level, Map.get(config, :level, :info)) != :lt do
      Lognorth.Client.logger_event(level, format(msg, meta), meta)
    end

    :ok
  end

  defp format({:report, report}, meta), do: format_report(report, meta)
  defp format(msg, _meta), do: format(msg)

  @doc false
  def format({:string, msg}), do: IO.chardata_to_string(msg)

  def format({format, args}) do
    format
    |> :io_lib.format(args)
    |> IO.chardata_to_string()
  rescue
    _ -> inspect({format, args}, limit: 20, printable_limit: 2_000)
  catch
    _, _ -> inspect({format, args}, limit: 20, printable_limit: 2_000)
  end

  def format({:report, report}) do
    format_report(report, %{})
  rescue
    _ -> inspect(report, limit: 20, printable_limit: 4_000)
  catch
    _, _ -> inspect(report, limit: 20, printable_limit: 4_000)
  end

  def format(other), do: inspect(other, limit: 20, printable_limit: 2_000)

  @doc false
  def format_report(report, meta) do
    case meta[:report_cb] do
      callback when is_function(callback, 2) ->
        callback.(report, %{depth: 20, chars_limit: 4_000}) |> IO.chardata_to_string()

      callback when is_function(callback, 1) ->
        case callback.(report) do
          {format, args} -> :io_lib.format(format, args) |> IO.chardata_to_string()
          other -> IO.chardata_to_string(other)
        end

      _ ->
        :io_lib.format(~c"~tp", [report]) |> IO.chardata_to_string()
    end
  rescue
    _ -> inspect(report, limit: 20, printable_limit: 4_000)
  catch
    _, _ -> inspect(report, limit: 20, printable_limit: 4_000)
  end
end
