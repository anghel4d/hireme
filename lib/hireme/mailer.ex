defmodule Hireme.Mailer do
  @moduledoc """
  The desk's outbound mail: a sign-in link, and the notices an account
  gets through this second channel when something is bound to it or
  removed from it (NIST SP 800-63B-4 Sec. 4.1.2; ASVS 6.3.7). Plain
  text only: nothing to render, nothing to click but the link. The
  adapter is `config :hireme, Hireme.Mailer`; the sender is
  `config :hireme, :mail_from`.
  """

  use Swoosh.Mailer, otp_app: :hireme
  import Swoosh.Email
  require Logger
  alias Hireme.Security

  @spec sign_in_link(String.t(), String.t()) :: :ok | {:error, term()}
  def sign_in_link(to, url) do
    minutes = div(Security.magic_link_ttl(), 60)

    post(to, "Your Hireme sign-in link", """
    Open this link to sign in. It works once, for #{minutes} minutes, and only in the browser that opens it:

    #{url}

    If you did not ask for it, ignore this mail; the link is useless to anyone who did not receive it.
    """)
  end

  @spec notice(String.t(), atom(), map()) :: :ok | {:error, term()}
  def notice(to, kind, meta \\ %{}) do
    post(to, "Hireme: #{line(kind, meta)}", """
    #{line(kind, meta)}

    If this was you, there is nothing to do. If it was not, sign in, end your other sessions, and revoke your keys from the Account page.
    """)
  end

  defp line(:api_key_created, m), do: ~s(an API key named "#{m[:name]}" was created)
  defp line(:api_key_revoked, m), do: ~s(the API key named "#{m[:name]}" was revoked)
  defp line(:authenticator_added, m), do: "a second factor (#{m[:kind]}) was added"
  defp line(:authenticator_removed, m), do: "a second factor (#{m[:kind]}) was removed"
  defp line(:authenticator_disabled, m), do: "a second factor (#{m[:kind]}) was disabled"
  defp line(:recovery_code_used, m), do: "a recovery code was used; #{m[:left]} left"
  defp line(:identity_linked, m), do: "#{m[:provider]} sign-in #{m[:display]} was linked"
  defp line(:identity_unlinked, m), do: "#{m[:provider]} sign-in #{m[:display]} was unlinked"
  defp line(kind, _), do: kind |> Atom.to_string() |> String.replace("_", " ")

  defp post(to, subject, body) do
    {name, address} = Application.get_env(:hireme, :mail_from, {"Hireme", "hireme@localhost"})

    email =
      new()
      |> to(to)
      |> from({name, address})
      |> subject(header_safe(subject))
      |> text_body(body)

    case deliver(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("outbound mail failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # One subject header. Control characters would fold in a second header;
  # anything outside ASCII is an encoded-word so the bytes stay one field.
  defp header_safe(text) do
    text = text |> to_string() |> String.replace(~r/[\r\n\t]/, " ")
    if String.match?(text, ~r/[^\x20-\x7e]/), do: encoded_words(text), else: text
  end

  defp encoded_words(text) do
    text
    |> utf8_chunks(45)
    |> Enum.map_join(" ", &"=?utf-8?B?#{Base.encode64(&1)}?=")
  end

  defp utf8_chunks(text, max) do
    {chunks, last} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], <<>>}, fn grapheme, {chunks, buf} ->
        if buf != "" and byte_size(buf <> grapheme) > max do
          {[buf | chunks], grapheme}
        else
          {chunks, buf <> grapheme}
        end
      end)

    Enum.reverse(if last == "", do: chunks, else: [last | chunks])
  end
end
