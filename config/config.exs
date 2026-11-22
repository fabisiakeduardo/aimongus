# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :aimongus,
  generators: [timestamp_type: :utc_datetime]

# Per-agent LLM adapter selection: agent id => module, :default as
# fallback. DevinCLI shells out to `devin -p` (Devin quota, not API
# keys); test env overrides with the scripted Stub and prod should
# point at OpenRouter.
config :aimongus, :llm_adapters, %{default: Aimongus.LLM.DevinCLI}

# Per-call USD cost estimates the MatchManager charges against
# DAILY_LLM_BUDGET_USD. DevinCLI is $0 — it burns Devin quota, not a
# billed API — and the Stub never leaves the test env. OpenRouter takes
# a per-model map (`:default` covers unlisted models); update with real
# pricing before pointing prod at a model.
config :aimongus, :llm_call_costs, %{
  Aimongus.LLM.DevinCLI => 0.0,
  Aimongus.LLM.Stub => 0.0,
  Aimongus.LLM.OpenRouter => %{default: 0.002}
}

# Configure the endpoint
config :aimongus, AimongusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AimongusWeb.ErrorHTML, json: AimongusWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Aimongus.PubSub,
  live_view: [signing_salt: "X9AaBiJH"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  aimongus: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  aimongus: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
