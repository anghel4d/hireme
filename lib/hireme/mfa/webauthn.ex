defmodule Hireme.Mfa.WebAuthn do
  @moduledoc false
  # The two WebAuthn ceremonies as the browser speaks them, over Wax.
  # Options go out in the PublicKeyCredentialCreationOptions and
  # PublicKeyCredentialRequestOptions shapes with binary fields as
  # base64url; responses come back the same way and are verified here.

  alias Hireme.Security

  @rp_name "Hireme"
  # EdDSA, ES256, RS256: what passkeys, security keys, and platform keychains sign with.
  @algorithms [-8, -7, -257]

  def registration_challenge do
    Wax.new_registration_challenge(
      attestation: "none",
      user_verification: "required",
      timeout: Security.challenge_ttl()
    )
  end

  def registration_options(%Wax.Challenge{} = challenge, account_id, label, exclude) do
    %{
      publicKey: %{
        challenge: b64(challenge.bytes),
        rp: %{id: challenge.rp_id, name: @rp_name},
        user: %{id: b64("hireme-account-#{account_id}"), name: label, displayName: label},
        pubKeyCredParams: Enum.map(@algorithms, &%{type: "public-key", alg: &1}),
        timeout: Security.challenge_ttl() * 1000,
        attestation: "none",
        authenticatorSelection: %{residentKey: "preferred", userVerification: "required"},
        excludeCredentials: Enum.map(exclude, &%{type: "public-key", id: b64(&1)})
      }
    }
  end

  @doc "Verify a registration response; the map is what the method row stores."
  def register(%Wax.Challenge{} = challenge, params) when is_map(params) do
    with {:ok, attestation} <- decode(params["attestationObject"]),
         {:ok, client_data} <- decode(params["clientDataJSON"]),
         {:ok, {auth_data, _attestation}} <-
           quietly(fn -> Wax.register(attestation, client_data, challenge) end),
         %Wax.AttestedCredentialData{} = credential <- auth_data.attested_credential_data do
      {:ok,
       %{
         credential_id: credential.credential_id,
         public_key: :erlang.term_to_binary(credential.credential_public_key),
         sign_count: auth_data.sign_count,
         aaguid: credential.aaguid,
         transports:
           params["transports"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join(","),
         backup_eligible: auth_data.flag_backup_eligible == true,
         backed_up: auth_data.flag_credential_backed_up == true
       }}
    else
      _ -> {:error, :attestation}
    end
  end

  def authentication_challenge(credentials) when is_list(credentials) do
    Wax.new_authentication_challenge(
      allow_credentials: credentials,
      user_verification: "required",
      timeout: Security.challenge_ttl()
    )
  end

  def assertion_options(%Wax.Challenge{} = challenge, methods) do
    %{
      publicKey: %{
        challenge: b64(challenge.bytes),
        rpId: challenge.rp_id,
        timeout: Security.challenge_ttl() * 1000,
        userVerification: "required",
        allowCredentials:
          Enum.map(methods, fn method ->
            %{
              type: "public-key",
              id: b64(method.credential_id),
              transports: String.split(method.transports, ",", trim: true)
            }
          end)
      }
    }
  end

  @doc "Verify an assertion; answers the credential id it was made with and the authenticator data."
  def authenticate(%Wax.Challenge{} = challenge, params) when is_map(params) do
    with {:ok, raw_id} <- decode(params["rawId"]),
         {:ok, auth_data} <- decode(params["authenticatorData"]),
         {:ok, signature} <- decode(params["signature"]),
         {:ok, client_data} <- decode(params["clientDataJSON"]),
         {:ok, data} <-
           quietly(fn ->
             Wax.authenticate(raw_id, auth_data, signature, client_data, challenge)
           end) do
      {:ok, raw_id, data}
    else
      _ -> {:error, :assertion}
    end
  end

  @doc "The stored COSE key of a method, for the allow list."
  def credential({credential_id, public_key}) when is_binary(public_key) do
    {credential_id, :erlang.binary_to_term(public_key, [:safe])}
  end

  defp decode(value) when is_binary(value), do: Base.url_decode64(value, padding: false)
  defp decode(_), do: :error

  defp b64(binary), do: Base.url_encode64(binary, padding: false)

  # Wax parses the browser's bytes with bang functions; a forged response raises in there.
  defp quietly(verify) do
    verify.()
  rescue
    _ -> {:error, :malformed}
  end
end
