defmodule BedrockRaft.MixProject do
  use Mix.Project

  def project do
    [
      app: :bedrock_raft,
      version: "0.9.8",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      dialyzer: dialyzer(),
      description:
        "An implementation of the RAFT consensus algorithm in Elixir that doesn't force opinions. Bake the protocol into your own GenServers, send messages and manage logs how you like.",
      source_url: "https://github.com/bedrock-kv/raft",
      homepage_url: "https://github.com/bedrock-kv/raft",
      package: package(),
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.json": :test,
        dialyzer: :dev
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    []
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.3"}
    ]
    |> add_deps_for_dev_and_test()
  end

  def add_deps_for_dev_and_test(deps) do
    deps ++
      [
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
        {:ex_doc, "~> 0.39", only: :dev, runtime: false, warn_if_outdated: true},
        {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
        {:mox, "~> 1.1", only: :test},
        {:excoveralls, "~> 0.18", only: :test}
      ]
  end

  defp dialyzer do
    [
      plt_core_path: "plts",
      plt_file: {:no_warn, "plts/dialyzer.plt"},
      plt_add_apps: [:ex_unit, :mix],
      # Disable opaque type checks due to OTP 28 issues with structs containing
      # MapSet/queue. See: https://github.com/elixir-lang/elixir/issues/14576
      flags: [:no_opaque]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/bedrock-kv/raft",
        "Changelog" => "https://github.com/bedrock-kv/raft/blob/main/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "Bedrock.Raft",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
