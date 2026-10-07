defmodule Hireme.ApiKeys do
  @moduledoc """
  Keys an agent presents to the MCP sockets. One key, one account.

  A key reads `hm_<id>_<secret><check>`: a 12-character public id (the
  row's `key_id`, shown as `key_…`), 43 characters of secret from the
  CSPRNG (about 256 bits), and a 6-character CRC32 of everything before
  it. The checksum rejects a malformed or hallucinated key before any
  lookup and lets a secret scanner recognise the shape. The secret is
  returned exactly once, at creation; the row keeps its SHA-256 and the
  first four characters for display. A random secret of this size does
  not need a slow hash.

  `authenticate/2` answers `{:ok, key}` or `:error` and nothing in
  between: a wrong id, a wrong secret, a revoked or expired key, and a
  suspended account all look the same to the caller. Failures from one
  address are throttled.
  """

  import Ecto.Query
  alias Hireme.Accounts
  alias Hireme.ApiKeys.Key
  alias Hireme.Audit
  alias Hireme.Repo
  alias Hireme.Security

  @prefix "hm_"
  @shape ~r/\Ahm_([0-9A-Za-z]{12})_([0-9A-Za-z]{43})([0-9A-Za-z]{6})\z/

  @type created :: %{key: Key.t(), secret: String.t()}

  @doc "Keys for the account on the process, newest first, revoked ones included."
  @spec list() :: [Key.t()]
  def list, do: Repo.all(from k in Key, order_by: [desc: k.id])

  @spec get(pos_integer()) :: Key.t() | nil
  def get(id) when is_integer(id), do: Repo.get(Key, id)

  @doc """
  Mint a key for the account on the process. `expires_in_days` of nil
  means never. The secret in the result is the only copy.
  """
  @spec create(String.t(), pos_integer() | nil, map()) ::
          {:ok, created()} | {:error, :name | :limit | Ecto.Changeset.t()}
  def create(name, expires_in_days \\ nil, meta \\ %{}) do
    name = String.trim(to_string(name))
    account_id = Repo.account_id!()
    live = Repo.aggregate(from(k in Key, where: is_nil(k.revoked_at)), :count)

    cond do
      name == "" ->
        {:error, :name}

      live >= Security.api_keys_per_account() ->
        {:error, :limit}

      true ->
        key_id = Security.base62(12)
        secret = Security.base62(43)
        body = @prefix <> key_id <> "_" <> secret

        attrs = %{
          account_id: account_id,
          key_id: key_id,
          name: name,
          secret_hash: Security.hash(secret),
          prefix: String.slice(secret, 0, 4),
          expires_at: expires_in_days && DateTime.add(now(), expires_in_days * 86_400, :second)
        }

        with {:ok, key} <- %Key{} |> Key.changeset(attrs) |> Repo.insert() do
          Audit.record(:api_key_created, %{key_id: key_id, name: name}, meta)
          Accounts.notify(account_id, :api_key_created, %{name: name, key_id: key_id})
          {:ok, %{key: key, secret: body <> Security.checksum(body)}}
        end
    end
  end

  @spec rename(Key.t(), String.t()) :: {:ok, Key.t()} | {:error, Ecto.Changeset.t()}
  def rename(%Key{} = key, name) do
    key |> Key.changeset(%{name: String.trim(to_string(name))}) |> Repo.update()
  end

  @doc "Revoke now. A revoked key fails `authenticate/2` from this moment and stays listed."
  @spec revoke(Key.t(), map()) :: Key.t()
  def revoke(%Key{revoked_at: nil} = key, meta \\ %{}) do
    revoked = key |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update!()
    Audit.record(:api_key_revoked, %{key_id: key.key_id, name: key.name}, meta)
    Accounts.notify(key.account_id, :api_key_revoked, %{name: key.name, key_id: key.key_id})
    revoked
  end

  @doc """
  The live key a presented secret names, or `:error`. `peer` throttles
  failures per address: twenty in a minute, then nothing for a minute.
  """
  @spec authenticate(term(), String.t()) :: {:ok, Key.t()} | :error
  def authenticate(presented, peer \\ "")

  def authenticate(presented, peer) when is_binary(presented) do
    with :ok <- Security.limit(:api_key_peer, peer),
         {:ok, key_id, secret} <- parse(presented),
         %Key{} = key <- Repo.get_by(Key, [key_id: key_id], skip_account: true),
         true <- Security.equal?(Security.hash(secret), key.secret_hash),
         true <- live?(key),
         true <- Accounts.active?(Accounts.get(key.account_id)) do
      {:ok, used(key)}
    else
      _ -> :error
    end
  end

  def authenticate(_, _), do: :error

  @doc "The shape a key is shown in after creation: `hm_Ed6k…`."
  @spec display(Key.t()) :: String.t()
  def display(%Key{prefix: prefix}), do: @prefix <> prefix <> "…"

  @spec live?(Key.t()) :: boolean()
  def live?(%Key{revoked_at: revoked, expires_at: expires}) do
    is_nil(revoked) and (is_nil(expires) or DateTime.compare(now(), expires) == :lt)
  end

  defp parse(presented) do
    with [_, key_id, secret, check] <- Regex.run(@shape, presented),
         true <- Security.equal?(check, Security.checksum(@prefix <> key_id <> "_" <> secret)) do
      {:ok, key_id, secret}
    else
      _ -> :error
    end
  end

  # Write last_used_at at most once a minute per key.
  defp used(%Key{} = key) do
    if is_nil(key.last_used_at) or DateTime.diff(now(), key.last_used_at) >= 60 do
      key |> Ecto.Changeset.change(last_used_at: now()) |> Repo.update!(skip_account: true)
    else
      key
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
