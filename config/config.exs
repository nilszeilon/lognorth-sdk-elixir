import Config

# The trace ID comes from Logger metadata in a Phoenix request.
if config_env() == :test do
  config :logger, :default_handler, metadata: [:request_id]
  config :logger, :console, metadata: [:request_id]
end
