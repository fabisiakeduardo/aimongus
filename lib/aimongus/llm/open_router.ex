defmodule Aimongus.LLM.OpenRouter do
  @moduledoc """
  Production adapter for `Aimongus.LLM.Client`: OpenRouter's
  chat-completions endpoint — one API key, access to every hosted
  model, and per-agent model mixing (personality diversity for free).

  Returns `{:ok, text}` — the raw `choices[0].message.content`, which
  `Aimongus.LLM.Intent.parse/1` decodes downstream.

  ## Options

    * `:model` — OpenRouter model id (`"google/gemini-2.0-flash-001"`,
      ...). Falls back to `config :aimongus, Aimongus.LLM.OpenRouter`
      `:model`. Required.
    * `:api_key` — defaults to `OPENROUTER_API_KEY` env var.
    * `:json_mode` — opt-in: adds
      `response_format: %{type: "json_object"}` to the request. Only
      enable for models that support it.
    * `:timeout` — Req `receive_timeout` in ms; default 60s, or the
      module config's `:timeout`.
    * `:url` — endpoint override, default the OpenRouter
      chat-completions URL (or the module config's `:url`). Useful for
      OpenRouter-compatible proxies.
    * `:plug`, `:retry` — passed through to Req. `:plug` is the test
      seam (a `conn -> conn` function); no real HTTP in tests.
  """

  @behaviour Aimongus.LLM.Client

  @url "https://openrouter.ai/api/v1/chat/completions"
  @default_timeout :timer.seconds(60)

  @impl true
  def complete(prompt, opts) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("OPENROUTER_API_KEY")
    model = Keyword.get(opts, :model) || configured(:model)

    cond do
      is_nil(api_key) -> {:error, :missing_api_key}
      is_nil(model) -> {:error, :missing_model}
      true -> request(prompt, model, api_key, opts)
    end
  end

  defp request(prompt, model, api_key, opts) do
    body =
      %{model: model, messages: [%{role: "user", content: prompt}]}
      |> maybe_json_mode(opts)

    req_opts =
      [
        url: url(opts),
        json: body,
        auth: {:bearer, api_key},
        receive_timeout: timeout(opts)
      ]
      |> Keyword.merge(Keyword.take(opts, [:plug, :retry]))

    case Req.post(req_opts) do
      {:ok, %{status: status, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}}
      when status in 200..299 ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_json_mode(body, opts) do
    if Keyword.get(opts, :json_mode, configured(:json_mode)) do
      Map.put(body, :response_format, %{type: "json_object"})
    else
      body
    end
  end

  defp timeout(opts) do
    Keyword.get(opts, :timeout) || configured(:timeout) || @default_timeout
  end

  defp url(opts) do
    Keyword.get(opts, :url) || configured(:url) || @url
  end

  defp configured(key) do
    Application.get_env(:aimongus, __MODULE__, [])[key]
  end
end
