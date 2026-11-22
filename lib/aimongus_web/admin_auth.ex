defmodule AimongusWeb.AdminAuth do
  @moduledoc """
  Shared gate for operator controls (`POST /admin/new-match` and the
  spectator page's admin config drawer). Reads `AIMONGUS_ADMIN_TOKEN`;
  when unset or empty every admin action is denied so an unconfigured
  deploy can never expose match control to public visitors.
  """

  @env_var "AIMONGUS_ADMIN_TOKEN"

  @doc "Returns `true` when `AIMONGUS_ADMIN_TOKEN` is configured."
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env(@env_var) do
      token when is_binary(token) and token != "" -> true
      _other -> false
    end
  end

  @doc """
  Checks `given` against `AIMONGUS_ADMIN_TOKEN` in constant time.

  Returns `:ok`, `:disabled` (env var unset/empty), or `:unauthorized`.
  """
  @spec authorize(term()) :: :ok | :disabled | :unauthorized
  def authorize(given) do
    case System.get_env(@env_var) do
      expected when is_binary(expected) and expected != "" ->
        if is_binary(given) and Plug.Crypto.secure_compare(given, expected),
          do: :ok,
          else: :unauthorized

      _other ->
        :disabled
    end
  end
end
