defmodule Lognorth.PlugTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  setup do
    Process.register(self(), :lognorth_test)
    Application.put_env(:lognorth, :test_response, {:ok, 200, nil})
    Lognorth.Client.reset()

    Lognorth.config("https://logs.example.test", "lgn-test",
      transport: Lognorth.TestTransport,
      environment: "test"
    )

    on_exit(fn ->
      if Process.whereis(:lognorth_test), do: Process.unregister(:lognorth_test)
      Application.delete_env(:lognorth, :test_response)
    end)

    :ok
  end

  test "one event per request, with the status and the duration" do
    conn(:get, "/hello")
    |> Lognorth.Plug.call(%{})
    |> send_resp(200, "ok")

    assert Lognorth.flush() == 0
    assert_receive {:posted, %{body: body}}

    assert [event] = Jason.decode!(body)["events"]
    assert event["message"] == "GET /hello → 200"
    assert event["context"]["method"] == "GET"
    assert event["context"]["path"] == "/hello"
    assert event["context"]["status"] == 200
    assert is_integer(event["duration_ms"])
  end

  test "the trace ID comes from x-request-id, or is made up" do
    conn =
      conn(:get, "/traced")
      |> put_req_header("x-request-id", "req-abc")
      |> Lognorth.Plug.call(%{})

    assert get_resp_header(conn, "x-trace-id") == ["req-abc"]

    conn |> send_resp(200, "")
    assert Lognorth.flush() == 0
    assert_receive {:posted, %{body: body}}
    assert [event] = Jason.decode!(body)["events"]
    assert event["trace_id"] == "req-abc"
  end

  test "ignored paths send nothing" do
    conn(:get, "/up")
    |> Lognorth.Plug.call(%{ignored_paths: ["/up"]})
    |> send_resp(200, "")

    assert Lognorth.flush() == 0
    refute_receive {:posted, _}, 50
  end

  test "the user option stamps the event" do
    conn(:get, "/me")
    |> Lognorth.Plug.call(%{user: fn _conn -> 42 end})
    |> send_resp(200, "")

    assert Lognorth.flush() == 0
    assert_receive {:posted, %{body: body}}
    assert [event] = Jason.decode!(body)["events"]
    assert event["context"]["user"] == "42"
  end
end
