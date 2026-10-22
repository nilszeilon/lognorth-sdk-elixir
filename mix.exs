defmodule Lognorth.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/nilszeilon/lognorth-sdk-elixir"

  def project do
    [
      app: :lognorth,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "LogNorth for Elixir: a Logger handler and Plug middleware.",
      package: package(),
      source_url: @source_url,
      docs: [main: "Lognorth", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl], mod: {Lognorth.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:plug, "~> 1.14", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [licenses: ["MIT"], links: %{"GitHub" => @source_url}]
  end
end
