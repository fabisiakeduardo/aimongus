defmodule Aimongus.LLM.OpenRouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Aimongus.LLM.OpenRouter

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp content_response(text) do
    %{"choices" => [%{"message" => %{"content" => text}}]}
  end

  test "posts a chat completion and returns the message content" do
    plug = fn conn ->
      assert ["Bearer test-key"] = get_req_header(conn, "authorization")

      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["model"] == "test-model"
      assert [%{"role" => "user", "content" => "the prompt"}] = decoded["messages"]
      refute Map.has_key?(decoded, "response_format")

      json_response(conn, 200, content_response("{\"ok\":true}"))
    end

    assert {:ok, "{\"ok\":true}"} =
             OpenRouter.complete("the prompt",
               model: "test-model",
               api_key: "test-key",
               plug: plug
             )
  end

  test "json_mode: true opts in to response_format json_object" do
    plug = fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert Jason.decode!(body)["response_format"] == %{"type" => "json_object"}

      json_response(conn, 200, content_response("{}"))
    end

    assert {:ok, "{}"} =
             OpenRouter.complete("p",
               model: "m",
               api_key: "k",
               json_mode: true,
               plug: plug
             )
  end

  test "non-2xx status returns {:error, {:http_status, status, body}}" do
    plug = fn conn -> json_response(conn, 429, %{"error" => "rate limited"}) end

    assert {:error, {:http_status, 429, %{"error" => "rate limited"}}} =
             OpenRouter.complete("p", model: "m", api_key: "k", plug: plug)
  end

  test "a 2xx without choices content returns an error" do
    plug = fn conn -> json_response(conn, 200, %{"choices" => []}) end

    assert {:error, {:http_status, 200, %{"choices" => []}}} =
             OpenRouter.complete("p", model: "m", api_key: "k", plug: plug)
  end

  test "missing api key returns an error without a request" do
    previous = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")

    on_exit(fn ->
      if previous, do: System.put_env("OPENROUTER_API_KEY", previous)
    end)

    assert {:error, :missing_api_key} = OpenRouter.complete("p", model: "m")
  end

  test "missing model returns an error without a request" do
    assert {:error, :missing_model} = OpenRouter.complete("p", api_key: "k")
  end
end
