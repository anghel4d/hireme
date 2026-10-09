defmodule Hireme.CloudflareMailTest do
  use ExUnit.Case, async: true

  alias Hireme.CloudflareMail

  setup do
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from({"Hireme", "signin@example.com"})
      |> Swoosh.Email.to("owner@example.net")
      |> Swoosh.Email.subject("Sign in")
      |> Swoosh.Email.text_body("Your sign-in link")

    config = [
      account_id: "account",
      api_token: "test",
      request_options: [plug: {Req.Test, __MODULE__}]
    ]

    %{email: email, config: config}
  end

  test "queued mail is accepted without requiring immediate delivery", %{
    email: email,
    config: config
  } do
    respond(%{"delivered" => [], "queued" => ["owner@example.net"], "permanent_bounces" => []})
    assert {:ok, %{queued: ["owner@example.net"]}} = CloudflareMail.deliver(email, config)
  end

  test "a successful envelope cannot hide a permanent bounce", %{email: email, config: config} do
    respond(%{"delivered" => [], "queued" => [], "permanent_bounces" => ["owner@example.net"]})
    assert {:error, :permanent_bounce} = CloudflareMail.deliver(email, config)
  end

  test "acceptance of another address does not count as delivery", %{email: email, config: config} do
    respond(%{"delivered" => ["someone@example.net"], "queued" => [], "permanent_bounces" => []})
    assert {:error, :recipients_not_accepted} = CloudflareMail.deliver(email, config)
  end

  test "API rejection does not expose response content to mailer logs", %{
    email: email,
    config: config
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{"success" => false, "errors" => ["private detail"]})
    end)

    assert {:error, {:cloudflare_http, 403}} = CloudflareMail.deliver(email, config)
  end

  defp respond(result) do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"success" => true, "result" => result}))
  end
end
