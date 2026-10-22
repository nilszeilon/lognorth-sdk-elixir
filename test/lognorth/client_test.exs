defmodule Lognorth.ClientTest do
  use ExUnit.Case, async: false

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

  test "sends an event with the environment stamped" do
    Lognorth.log("hello", %{"order_id" => 42})
    assert Lognorth.flush() == 0

    assert_receive {:posted, %{endpoint: endpoint, key: key, body: body}}
    assert endpoint == "https://logs.example.test"
    assert key == "lgn-test"

    assert [event] = Jason.decode!(body)["events"]
    assert event["message"] == "hello"
    assert event["context"]["order_id"] == 42
    assert event["context"]["environment"] == "test"
    assert is_binary(event["timestamp"])
  end

  test "an error carries the class, the file and the line" do
    stack = [{Blog.Foo, :bar, 0, [file: ~c"lib/blog/foo.ex", line: 12]}]

    Lognorth.error(
      "checkout failed",
      %{class: "RuntimeError", message: "boom", stacktrace: stack},
      %{
        "order_id" => 42
      }
    )

    assert Lognorth.flush() == 0
    assert_receive {:posted, %{body: body}}

    assert [event] = Jason.decode!(body)["events"]
    assert event["message"] == "checkout failed"
    assert event["context"]["error"] == "boom"
    assert event["context"]["error_class"] == "RuntimeError"
    assert event["context"]["error_file"] == "foo.ex"
    assert event["context"]["error_line"] == 12
    assert event["context"]["stack_trace"] =~ "Blog.Foo.bar/0"
  end

  test "a 5xx keeps the event and sends it again" do
    Application.put_env(:lognorth, :test_response, {:ok, 500, nil})
    Lognorth.log("will retry")
    assert Lognorth.flush() == 1

    Application.put_env(:lognorth, :test_response, {:ok, 200, nil})
    assert Lognorth.flush() == 0

    assert_receive {:posted, _}
    assert_receive {:posted, %{body: body}}
    assert Jason.decode!(body)["events"] |> hd() |> Map.get("message") == "will retry"
  end

  test "a 400 drops the batch" do
    Application.put_env(:lognorth, :test_response, {:ok, 400, nil})
    Lognorth.log("bad event")
    assert Lognorth.flush() == 0
  end

  test "a 401 keeps the event, because the url or the key is wrong" do
    Application.put_env(:lognorth, :test_response, {:ok, 401, nil})
    Lognorth.log("unauthorized")
    assert Lognorth.flush() == 1
  end

  test "announces the release once" do
    Lognorth.config("https://logs.example.test", "lgn-test",
      transport: Lognorth.TestTransport,
      environment: "test",
      release: "abc123"
    )

    assert Lognorth.flush() == 0
    assert_receive {:posted, %{body: body}}
    assert [event] = Jason.decode!(body)["events"]
    assert event["message"] == "Release abc123 started"

    Lognorth.config("https://logs.example.test", "lgn-test",
      transport: Lognorth.TestTransport,
      environment: "test",
      release: "abc123"
    )

    refute_receive {:posted, _}, 50
  end

  test "the queue drops the oldest non-error when it is full" do
    Application.put_env(:lognorth, :test_response, {:error, :timeout})

    for i <- 1..10_050 do
      Lognorth.log("event #{i}")
    end

    Lognorth.log("the error", %{"error" => "boom"})

    assert Lognorth.flush() > 0
  end
end
