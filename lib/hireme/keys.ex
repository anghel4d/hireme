defmodule Hireme.Keys do
  @moduledoc """
  API keys: how an agent reaches an account. One key, one account.

  A key reads `hm_<id>_<secret><check>`: a 12-character public id (the
  row's `key_id`), 43 characters of CSPRNG secret (about 256 bits), and a
  6-character CRC32 of everything before it. The checksum turns away a
  malformed or hallucinated key before any lookup and lets a secret
  scanner recognise the shape. The secret is returned once, at mint; the
  row keeps its SHA-256 and four characters for display. A random secret
  this long needs no slow hash.

  What a key may do is two masks over the domains (`domains/0`: world 1,
  desk 2, mail 4, lanes 8, corpus 16) and `may_delete`: `read_mask`
  bounds BOOT, PATCH and every read RPC; `write_mask` bounds every op;
  `drop` also needs `may_delete`. `system` tables, `citations` and
  `trusted_hosts` are in no mask. The presets are read only, write only
  and read/write; anything else is custom.

  Minting, widening a mask and granting `may_delete` need a session that
  stepped up within the window (`Hireme.Mfa.fresh?/1`), so every change
  here takes the browser session that asks: a key never mints or changes
  keys, because only a browser session holds one. Any change to a live
  key's masks ends its wire sessions with BYE `grants`; a revoke ends
  them with BYE `revoked`.

  `authenticate/2` answers the key or `:error` and nothing between: a
  wrong id, a wrong secret, a revoked or expired key, a suspended account
  and a throttled peer all look the same. Key and account are read
  together on every check, so revocation and suspension are never cached.
  """

  import Ecto.Query
  alias Hireme.Accounts
  alias Hireme.Audit
  alias Hireme.Mfa
  alias Hireme.Repo
  alias Hireme.Rows.Account
  alias Hireme.Rows.ApiKey, as: Key
  alias Hireme.Rows.Session
  alias Hireme.Security
  alias Hireme.Store

  @prefix "hm_"
  @shape ~r/\Ahm_([0-9A-Za-z]{12})_([0-9A-Za-z]{43})([0-9A-Za-z]{6})\z/
  @domains [:world, :desk, :mail, :lanes, :corpus]

  @type masks :: %{read_mask: 0..31, write_mask: 0..31, may_delete: boolean()}
  @type authenticated :: %{
          id: pos_integer(),
          key_id: String.t(),
          account_id: pos_integer(),
          name: String.t(),
          read_mask: 0..31,
          write_mask: 0..31,
          may_delete: boolean()
        }

  @doc "The masked domains and their bits, in bit order."
  @spec domains() :: [{atom(), pos_integer()}]
  def domains, do: for(d <- @domains, do: {d, Hireme.Schema.domain_bit(d)})

  @doc "Every domain's bit."
  @spec all() :: 0..31
  def all, do: domains() |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  @doc "A preset's masks. `may_delete` is never part of a preset; it is granted on its own."
  @spec preset(:read_only | :write_only | :read_write) :: masks()
  def preset(:read_only), do: %{read_mask: all(), write_mask: 0, may_delete: false}
  def preset(:write_only), do: %{read_mask: 0, write_mask: all(), may_delete: false}
  def preset(:read_write), do: %{read_mask: all(), write_mask: all(), may_delete: false}

  @doc "The preset these masks are, or `:custom`."
  @spec preset_of(masks() | Key.t()) :: :read_only | :write_only | :read_write | :custom
  def preset_of(%{read_mask: r, write_mask: w, may_delete: false}) do
    Enum.find(
      [:read_only, :write_only, :read_write],
      :custom,
      &match?(%{read_mask: ^r, write_mask: ^w}, preset(&1))
    )
  end

  def preset_of(_), do: :custom

  @doc "Keys for the account on the process, newest first, revoked ones included."
  @spec list() :: [Key.t()]
  def list, do: Repo.all(from(k in Key, order_by: [desc: k.id]))

  @spec get(pos_integer()) :: Key.t() | nil
  def get(id) when is_integer(id), do: Repo.get(Key, id)

  @doc """
  Mint a key for `session`'s account. `expires_in_days` nil means never.
  The secret in the answer is the only copy there will ever be.
  """
  @spec mint(Session.t(), String.t(), masks(), pos_integer() | nil, map()) ::
          {:ok, %{key: Key.t(), secret: String.t()}}
          | {:error, :step_up | :name | :masks | :limit}
  def mint(%Session{} = session, name, masks, expires_in_days \\ nil, meta \\ %{}) do
    name = name |> to_string() |> String.trim()

    with :ok <- fresh(session),
         :ok <- if(name != "" and String.length(name) <= 100, do: :ok, else: {:error, :name}),
         {:ok, masks} <- masks(masks) do
      key_id = Security.base62(12)
      secret = Security.base62(43)
      body = @prefix <> key_id <> "_" <> secret

      row =
        Map.merge(masks, %{
          account_id: session.account_id,
          key_id: key_id,
          name: name,
          secret_hash: Security.hash(secret),
          prefix: String.slice(secret, 0, 4),
          expires_at: expires_in_days && DateTime.add(Store.now(), expires_in_days * 86_400)
        })

      with {:ok, key} <- insert_under_cap(session.account_id, row) do
        about = %{key_id: key.id, name: name, preset: preset_of(key)}
        Audit.record(:api_key_created, about, ctx(meta, session))
        Accounts.notify(session.account_id, :api_key_created, %{name: name})
        {:ok, %{key: key, secret: body <> Security.checksum(body)}}
      end
    end
  end

  # The cap and the insert commit together. The account row is the lock:
  # the update matches only while under the cap, so a racing mint sees the
  # incremented count.
  defp insert_under_cap(account_id, row) do
    Store.transaction(fn ->
      {claimed, _} =
        Repo.update_all(
          from(a in Account,
            where: a.id == ^account_id and a.live_key_count < ^Security.api_keys_per_account()
          ),
          [inc: [live_key_count: 1]],
          skip_account: true
        )

      if claimed == 0, do: Repo.rollback(:limit)
      Repo.insert!(struct(Key, row), skip_account: true)
    end)
  end

  @doc """
  Change a live key's masks. Widening either mask or granting
  `may_delete` needs a fresh session; narrowing does not. Any change ends
  the key's wire sessions with BYE `grants`, so the next HELLO sees the
  new masks.
  """
  @spec change(Session.t(), Key.t(), masks(), map()) ::
          {:ok, Key.t()} | {:error, :step_up | :masks | :revoked}
  def change(%Session{} = session, %Key{} = key, masks, meta \\ %{}) do
    with true <- live?(key) || {:error, :revoked},
         {:ok, masks} <- masks(masks),
         widened = widens?(key, masks),
         :ok <- if(widened, do: fresh(session), else: :ok) do
      key =
        key
        |> Ecto.Changeset.change(Map.put(masks, :rev, key.rev + 1))
        |> then(&Store.write(fn -> Repo.update!(&1) end))

      about = %{
        key_id: key.id,
        name: key.name,
        preset: preset_of(key),
        may_delete: key.may_delete
      }

      Audit.record(:api_key_changed, about, ctx(meta, session))
      if widened, do: Accounts.notify(key.account_id, :api_key_widened, %{name: key.name})
      Audit.bye(key.account_id, {{:key, key.id}, :grants})
      {:ok, key}
    end
  end

  @doc "Whether `new` grants anything `old` did not."
  @spec widens?(masks() | Key.t(), masks()) :: boolean()
  def widens?(old, new) do
    Bitwise.band(new.read_mask, Bitwise.bnot(old.read_mask)) != 0 or
      Bitwise.band(new.write_mask, Bitwise.bnot(old.write_mask)) != 0 or
      (new.may_delete and not old.may_delete)
  end

  @spec rename(Key.t(), String.t()) :: {:ok, Key.t()} | {:error, :name}
  def rename(%Key{} = key, name) do
    name = name |> to_string() |> String.trim()

    if name != "" and String.length(name) <= 100 do
      key =
        key
        |> Ecto.Changeset.change(name: name, rev: key.rev + 1)
        |> then(&Store.write(fn -> Repo.update!(&1) end))

      Audit.changed(key.account_id)
      {:ok, key}
    else
      {:error, :name}
    end
  end

  @doc "Revoke now. A revoked key fails `authenticate/2` from this moment, its sessions end, and it stays listed."
  @spec revoke(Key.t(), map()) :: Key.t()
  def revoke(key, meta \\ %{})

  def revoke(%Key{revoked_at: nil} = key, meta) do
    {:ok, revoked} =
      Store.transaction(fn ->
        updated =
          key
          |> Ecto.Changeset.change(revoked_at: Store.now(), rev: key.rev + 1)
          |> Repo.update!(skip_account: true)

        Repo.update_all(
          from(a in Account, where: a.id == ^key.account_id and a.live_key_count > 0),
          [inc: [live_key_count: -1]],
          skip_account: true
        )

        updated
      end)

    Audit.record(
      :api_key_revoked,
      %{key_id: key.id, name: key.name},
      Map.put(meta, :account_id, key.account_id)
    )

    Accounts.notify(key.account_id, :api_key_revoked, %{name: key.name})
    Audit.bye(key.account_id, {{:key, key.id}, :revoked})
    revoked
  end

  def revoke(%Key{} = key, _meta), do: key

  @doc "Whether key `id` is still one `account_id` may use: live, on an active account."
  @spec usable?(pos_integer(), pos_integer()) :: boolean()
  def usable?(id, account_id) when is_integer(id) do
    case with_account(dynamic([k], k.id == ^id)) do
      {%Key{account_id: ^account_id} = key, account} -> live?(key) and Accounts.active?(account)
      _ -> false
    end
  end

  @doc """
  The live key a presented secret names, or `:error`. `peer` throttles
  attempts per address: twenty a minute.
  """
  @spec authenticate(term(), String.t()) :: {:ok, authenticated()} | :error
  def authenticate(presented, peer \\ "")

  def authenticate(presented, peer) when is_binary(presented) do
    with :ok <- Security.limit(:api_key_peer, peer),
         {:ok, key_id, secret} <- parse(presented),
         {%Key{} = key, account} <- with_account(dynamic([k], k.key_id == ^key_id)),
         true <- Security.equal?(Security.hash(secret), key.secret_hash),
         true <- live?(key) and Accounts.active?(account) do
      used(key)

      {:ok,
       Map.take(key, [:id, :key_id, :account_id, :name, :read_mask, :write_mask, :may_delete])}
    else
      _ -> :error
    end
  end

  def authenticate(_, _), do: :error

  @doc "How a key is shown after mint: `hm_Ed6k…`."
  @spec display(Key.t()) :: String.t()
  def display(%Key{prefix: prefix}), do: @prefix <> prefix <> "…"

  @spec live?(Key.t()) :: boolean()
  def live?(%Key{revoked_at: revoked, expires_at: expires}),
    do: is_nil(revoked) and (is_nil(expires) or DateTime.compare(Store.now(), expires) == :lt)

  defp masks(%{read_mask: r, write_mask: w} = m) when r in 0..31 and w in 0..31 do
    all = all()
    d = Map.get(m, :may_delete, false)

    if Bitwise.band(r, Bitwise.bnot(all)) == 0 and Bitwise.band(w, Bitwise.bnot(all)) == 0 and
         is_boolean(d) and (r != 0 or w != 0),
       do: {:ok, %{read_mask: r, write_mask: w, may_delete: d}},
       else: {:error, :masks}
  end

  defp masks(_), do: {:error, :masks}

  defp fresh(session), do: if(Mfa.fresh?(session), do: :ok, else: {:error, :step_up})

  defp with_account(where) do
    Repo.one(
      from(k in Key, join: a in Account, on: a.id == k.account_id, where: ^where, select: {k, a}),
      skip_account: true
    )
  end

  defp parse(presented) do
    with [_, key_id, secret, check] <- Regex.run(@shape, presented),
         true <- Security.equal?(check, Security.checksum(@prefix <> key_id <> "_" <> secret)) do
      {:ok, key_id, secret}
    else
      _ -> :error
    end
  end

  # last_used_at at most once a minute per key.
  defp used(%Key{} = key) do
    if is_nil(key.last_used_at) or DateTime.diff(Store.now(), key.last_used_at) >= 60 do
      Store.write(fn ->
        Repo.update_all(
          from(k in Key, where: k.id == ^key.id),
          [set: [last_used_at: Store.now()]], skip_account: true)
      end)
    end
  end

  defp ctx(meta, %Session{} = s),
    do: meta |> Map.put(:account_id, s.account_id) |> Map.put(:session_id, s.id)
end
