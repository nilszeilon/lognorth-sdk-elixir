defmodule Lognorth.LoggerHandlerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  require Logger

  setup do
    Process.register(self(), :lognorth_test)
    Application.put_env(:lognorth, :test_response, {:ok, 200, nil})
    Lognorth.Client.reset()

    Lognorth.config("https://logs.example.test", "lgn-test",
      transport: Lognorth.TestTransport,
      environment: "test",
      attach_logger: false
    )

    Lognorth.attach(:info)

    on_exit(fn ->
      Lognorth.detach()
      if Process.whereis(:lognorth_test), do: Process.unregister(:lognorth_test)
      Application.delete_env(:lognorth, :test_response)
    end)

    :ok
  end

  test "a Logger.error with an Elixir exception becomes a structured error" do
    capture_log(fn ->
      Logger.error("""
      ** (RuntimeError) boom
          (blog 0.1.0) lib/blog/foo.ex:12: Blog.Foo.bar/0
      """)
    end)

    assert Lognorth.flush() == 0
    assert_receive {:posted, %{body: body}}

    assert [event] = Jason.decode!(body)["events"]
    assert event["message"] == "RuntimeError: boom"
    assert event["context"]["error_class"] == "RuntimeError"
    assert event["context"]["error_file"] == "foo.ex"
    assert event["context"]["error_line"] == 12
    assert event["context"]["level"] == "error"
    assert event["context"]["environment"] == "test"
  end

  test "a Logger.info becomes a plain event with the level" do
    capture_log(fn -> Logger.info("GET / → 200") end)

    assert Lognorth.flush() == 0
    assert_receive {:posted, %{body: body}}

    assert [event] = Jason.decode!(body)["events"]
    assert event["message"] == "GET / → 200"
    assert event["context"]["level"] == "info"
    refute event["context"]["error_class"]
  end

  test "the request id of the metadata becomes the trace id" do
    capture_log(fn ->
      Logger.info("in a request", request_id: "req-123")
    end)

    assert Lognorth.flush() == 0
    assert_receive {:posted, %{body: body}}

    assert [event] = Jason.decode!(body)["events"]
    assert event["trace_id"] == "req-123"
  end
end

defmodule Lognorth.RequestLogTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  require Logger

  setup do
    Process.register(self(), :lognorth_test)
    Application.put_env(:lognorth, :test_response, {:ok, 200, nil})
    Lognorth.Client.reset()

    Lognorth.config("https://logs.example.test", "lgn-test",
      transport: Lognorth.TestTransport,
      environment: "test"
    )

    on_exit(fn ->
      Process.delete(:lognorth_plug)
      if Process.whereis(:lognorth_test), do: Process.unregister(:lognorth_test)
      Application.delete_env(:lognorth, :test_response)
    end)

    :ok
  end

  test "Phoenix's own request log is dropped while a Plug request is in flight" do
    Process.put(:lognorth_plug, true)

    capture_log(fn ->
      Lognorth.Client.logger_event(:info, "GET /",
        mfa: {Phoenix.Logger, :phoenix_endpoint_start, 4}
      )

      Lognorth.Client.logger_event(:info, "Sent 200 in 2ms",
        mfa: {Phoenix.Logger, :phoenix_endpoint_stop, 4}
      )
    end)

    assert Lognorth.flush() == 0
    refute_receive {:posted, _}, 50
  end

  test "the same lines are kept when no Plug handled the request" do
    capture_log(fn ->
      Lognorth.Client.logger_event(:info, "GET /",
        mfa: {Phoenix.Logger, :phoenix_endpoint_start, 4}
      )
    end)

    assert Lognorth.flush() == 0
    assert_receive {:posted, %{body: body}}
    assert [event] = Jason.decode!(body)["events"]
    assert event["message"] == "GET /"
  end
end
