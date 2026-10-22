defmodule Lognorth.EventTest do
  use ExUnit.Case, async: true

  alias Lognorth.Event

  @phoenix_error """
  ** (RuntimeError) boom
      (blog 0.1.0) lib/blog/foo.ex:12: Blog.Foo.bar/0
      (elixir 1.18.4) lib/enum.ex:1234: Enum.map/2
  """

  test "reads the exception class, message, file and line out of a log line" do
    parsed = Event.parse_text(@phoenix_error)

    assert parsed["error_class"] == "RuntimeError"
    assert parsed["error"] == "boom"
    assert parsed["error_file"] == "foo.ex"
    assert parsed["error_line"] == 12
    assert parsed["error_caller"] == "Blog.Foo.bar/0"
    assert parsed["stack_trace"] =~ "lib/enum.ex:1234"
  end

  test "keeps the message when there is no exception" do
    parsed = Event.parse_text("GET / → 200")

    assert parsed["error_class"] == nil
    assert parsed["error"] == "GET / → 200"
    assert parsed["stack_trace"] == nil
  end

  test "first_line keeps one line" do
    assert Event.first_line("a\nb\nc") == "a"
  end

  test "an error event is one with an error, or a 5xx" do
    assert Event.error?(Event.build("x", %{"error" => "boom"}))
    assert Event.error?(Event.build("x", %{"status" => 500}))
    refute Event.error?(Event.build("x", %{"status" => 404}))
    refute Event.error?(Event.build("x", %{}))
  end

  test "trims the message and marks the event" do
    event = Event.build(String.duplicate("x", 2_000), %{})
    assert String.length(event["message"]) == 1_000
    assert event["context"]["truncated"] == true
  end

  test "trims a long stack trace to 16 KB" do
    event = Event.build("boom", %{"stack_trace" => String.duplicate("f", 20_000)})
    assert byte_size(event["context"]["stack_trace"]) == 16 * 1024
    assert event["context"]["truncated"] == true
  end

  test "keeps the essential keys when the event is still too big" do
    context = Map.new(1..200, fn i -> {"key_#{i}", String.duplicate("v", 1_000)} end)
    event = Event.build("boom", Map.put(context, "error", "boom"))

    assert event["context"]["error"] == "boom"
    assert map_size(event["context"]) < 200
    assert event["context"]["truncated"] == true
  end

  test "stamps the environment and the release on errors only" do
    event = Event.build("hello", %{}, environment: "production", release: "abc")
    assert event["context"]["environment"] == "production"
    refute event["context"]["release"]

    error =
      Event.build_error("boom", %RuntimeError{message: "boom"}, %{},
        environment: "production",
        release: "abc"
      )

    assert error["context"]["release"] == "abc"
    assert error["context"]["error_class"] == "RuntimeError"
  end

  test "normalizes values that JSON cannot carry" do
    event = Event.build("x", %{pid: self(), nested: %{atom: :ok}})

    assert is_binary(event["context"]["pid"])
    assert event["context"]["nested"]["atom"] == "ok"
  end
end
