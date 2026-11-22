defmodule Aimongus.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AimongusWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:aimongus, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Aimongus.PubSub},
      # One GameServer per running match, looked up by match id.
      {Registry, keys: :unique, name: Aimongus.MatchRegistry},
      # AgentServer LLM calls run here unlinked — a crashed or hung
      # adapter can never take an agent process down with it.
      {Task.Supervisor, name: Aimongus.AgentTaskSupervisor}
    ]

    children =
      children ++
        match_manager_child() ++
        [
          # Start to serve requests, typically the last entry
          AimongusWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Aimongus.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The single-match lifecycle owner (auto-loop, budget guard, replay
  # fallback). Disabled in test so the suite doesn't boot a real match;
  # any env can also tune it via `config :aimongus, Aimongus.Match.Manager`.
  defp match_manager_child do
    config = Application.get_env(:aimongus, Aimongus.Match.Manager, [])

    if Keyword.get(config, :enabled, true) do
      [Aimongus.Match.Manager]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AimongusWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
