defmodule Flume.Mixfile do
  use Mix.Project

  def project do
    [
      app: :flume,
      version: "0.2.0",
      elixir: "~> 1.8",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/scripbox/flume",
      homepage_url: "https://github.com/scripbox/flume",
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support", "test/factories"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      applications: [
        :redix,
        :logger_file_backend,
        :gen_stage,
        :jason,
        :poolboy,
        :retry,
        :telemetry
      ],
      extra_applications: [:logger],
      mod: {Flume, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:redix, "~> 1.0"},
      {:gen_stage, "~> 0.14.0"},
      {:jason, "~> 1.1.0"},
      {:poolboy, "~> 1.5.1"},
      {:elixir_uuid, "~> 1.2"},
      {:logger_file_backend, "~> 0.0.10"},
      {:retry, "0.8.2"},
      {:benchee, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:excoveralls, "~> 0.10.6", only: :test}
    ]
  end

  defp description do
    "Flume is a job processing system backed by GenStage & Redis"
  end

  defp package do
    [
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/scripbox/flume"}
    ]
  end
end
