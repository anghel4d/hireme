defmodule Hireme.CloudflareMail do
  @moduledoc "Cloudflare HTTPS delivery for Hireme's plain-text transactional mail."
  use Swoosh.Adapter, required_config: [:account_id, :api_token]

  @impl true
  def deliver(email, config) do
    {name, address} = email.from
    recipients = Enum.map(email.to, fn {_, address} -> address end)

    request =
      Req.new(
        url:
          "https://api.cloudflare.com/client/v4/accounts/#{config[:account_id]}/email/sending/send",
        auth: {:bearer, config[:api_token]},
        retry: false,
        receive_timeout: 15_000
      )
      |> Req.merge(Keyword.get(config, :request_options, []))

    payload = %{
      from: %{name: name, address: address},
      to: recipients,
      subject: email.subject,
      text: email.text_body
    }

    case Req.post(request, json: payload) do
      {:ok,
       %Req.Response{
         status: status,
         body: %{
           "success" => true,
           "result" => %{"delivered" => delivered, "queued" => queued, "permanent_bounces" => []}
         }
       }}
      when status in 200..299 ->
        if Enum.all?(recipients, &(&1 in delivered or &1 in queued)) do
          {:ok, %{delivered: delivered, queued: queued}}
        else
          {:error, :recipients_not_accepted}
        end

      {:ok, %Req.Response{status: status, body: %{"result" => %{"permanent_bounces" => [_ | _]}}}}
      when status in 200..299 ->
        {:error, :permanent_bounce}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:cloudflare_http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
