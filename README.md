# LogNorth Elixir SDK

Send errors and logs from Elixir to [LogNorth](https://lognorth.com) for monitoring and alerting.

Two ways in, the same as the Ruby and Go clients:

- a `:logger` handler, so every `Logger.info/1` and `Logger.error/1` becomes an event;
- `Lognorth.log/2` and `Lognorth.error/3` for events you describe yourself;
- `Lognorth.Plug` for one event per request, with the trace ID and the user.

Elixir's OpenTelemetry packages export traces, not logs, and the log path is
`opentelemetry_experimental` plus `grpcbox`. This client talks to LogNorth's
ingestion API over plain JSON instead: two dependencies (`jason`, and `plug` if
you use the Plug), no gRPC, no protobuf.

## Installation

```elixir
# mix.exs
def deps do
  [
    {:lognorth, git: "https://github.com/nilszeilon/lognorth-sdk-elixir"}
  ]
end
```

## Configuration

```elixir
# config/runtime.exs
config :lognorth,
  url: System.get_env("LOGNORTH_URL"),
  key: System.get_env("LOGNORTH_API_KEY"),
  environment: System.get_env("APP_ENV", "production"),
  release: System.get_env("GIT_SHA")
```

The `:lognorth` application starts the sender and attaches the Logger handler
when a url and a key are set. Without them the library does nothing.

`release` is stamped on errors and announced once as `Release <version> started`,
which LogNorth takes as the deploy time. `environment` is stamped on every event.
When `release` is not set, the usual variables are read (`GIT_SHA`, `GIT_COMMIT`,
`SOURCE_COMMIT`, `KAMAL_VERSION`, …) — the same list as the Ruby client.

## Logging

With the handler attached, nothing else is needed:

```elixir
Logger.info("Order shipped", order_id: 42)
Logger.error("Checkout failed")
```

Events you describe yourself:

```elixir
Lognorth.log("Order shipped", %{order_id: 42})

try do
  checkout()
rescue
  exception ->
    Lognorth.error("Checkout failed", exception, %{order_id: 42})
    reraise exception, __STACKTRACE__
end
```

`Lognorth.error/3` takes an Elixir exception, or a map with `:class`, `:message`
and `:stacktrace`. It fills `error`, `error_class`, `error_file`, `error_line`,
`error_caller` and `stack_trace` — the fields LogNorth groups issues by.

## A request

```elixir
# router.ex
plug Lognorth.Plug

# or:
plug Lognorth.Plug, ignored_paths: ["/up", "/health"], user: &MyApp.Auth.user_id/1
```

One event per request: `GET /orders → 200`, with `method`, `path`, `status`,
`duration_ms`, `trace_id` (from `x-request-id`, or a random one, also returned as
`x-trace-id`) and the user. A 5xx is flushed at once; an unmatched 404 is skipped.

In a job or a channel, set the per-process values yourself:

```elixir
Lognorth.user(user.id)
Lognorth.trace_id(job_id)
Lognorth.log("nightly job started")
Lognorth.end_request()
```

## What is sent, and the limits

The same limits as the Ruby and Go clients:

| | |
|---|---|
| queue | 10,000 events or 10 MB; the oldest non-error is dropped first |
| one request | 500 events or 1 MB |
| message | 1,000 characters |
| `context.stack_trace` | 16 KB, keeping the top |
| other context values | 8 KB |
| one event | 64 KB; if still bigger, only the essential keys stay, with `truncated: true` |

Sending happens in a separate process, so a slow or down LogNorth never blocks
the caller. Batches flush every 5 seconds, at 10 events, or at once for an error
and for a 5xx request. Failures are retried with backoff (1 s doubling to 60 s);
`429`/`503` honour `Retry-After`. `401`/`403`/`404` are treated as a
misconfiguration: the events stay queued, the backoff grows to 5 minutes, and one
warning says to check the url and the key. Other 4xx are dropped and counted.

`Lognorth.flush/0` sends what is queued now, ignoring the backoff, and returns
how many events are left. The client flushes once on shutdown; what is left is
logged as lost.

## Development

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
```
