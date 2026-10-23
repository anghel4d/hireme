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

  What a key may do is two masks over the domains (world 1, desk 2,
  mail 4, corpus 8) and `may_delete`: `read_mask`
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
  alias Hireme.Rows.ApiKey, as: Key
  alias Hireme.Rows.Session
  alias Hireme.Security
  alias Hireme.Store

  @prefix "hm_"
  @presets [:read_only, :write_only, :read_write]
  @shape ~r/\Ahm_([0-9A-Za-z]{12})_([0-9A-Za-z]{43})([0-9A-Za-z]{6})\z/

  @type masks :: %{read_mask: 0..15, write_mask: 0..15, may_delete: boolean()}
  @type authenticated :: %{
          id: pos_integer(),
          key_id: String.t(),
          account_id: pos_integer(),
          name: String.t(),
          read_mask: 0..15,
          write_mask: 0..15,
          may_delete: boolean()
        }

  @doc "A preset's masks (`Hireme.Grants` owns them). `may_delete` is never part of a preset; it is granted on its own."
  @spec preset(:read_only | :write_only | :read_write) :: masks()
  def preset(name) do
    {r, w} = Hireme.Grants.preset(name)
    %{read_mask: r, write_mask: w, may_delete: false}
  end

  @doc "The preset these masks are, or `:custom`."
  @spec preset_of(masks() | Key.t()) :: :read_only | :write_only | :read_write | :custom
  def preset_of(%{read_mask: r, write_mask: w, may_delete: false}),
    do: Enum.find(@presets, :custom, &match?(%{read_mask: ^r, write_mask: ^w}, preset(&1)))

  def preset_of(_), do: :custom

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
         :ok <- if(name?(name), do: :ok, else: {:error, :name}),
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
        trail(:api_key_created, key, %{preset: preset_of(key)}, Audit.ctx(meta, session))
        Accounts.notify(session.account_id, :api_key_created, %{name: name})
        {:ok, %{key: key, secret: body <> Security.checksum(body)}}
      end
    end
  end

  # The count and the insert commit in one BEGIN IMMEDIATE transaction, so
  # a racing mint sees this one; an expired key no longer counts.
  defp insert_under_cap(account_id, row) do
    now = Store.now()
    mine = from(k in Key, where: k.account_id == ^account_id)
    unrevoked = where(mine, [k], is_nil(k.revoked_at))
    live = where(unrevoked, [k], is_nil(k.expires_at) or k.expires_at > ^now)
    count = &Repo.aggregate(&1, :count, skip_account: true)

    Store.transaction(fn ->
      if count.(live) >= Security.api_keys_per_account(), do: Repo.rollback(:limit)

      # Revoked keys count toward the table's cap until the purge removes
      # them, a month after their revoke.
      if count.(mine) >= Hireme.Schema.table(:api_keys).cap, do: Repo.rollback(:limit)
      Repo.insert!(struct(Key, Map.put(row, :rev, 1)), skip_account: true)
    end)
  end

  @doc """
  Change a live key's masks. Widening either mask or granting
  `may_delete` needs a fresh session; narrowing does not. A change that
  moves a mask or `may_delete` ends the key's wire sessions with BYE
  `grants`, so the next HELLO sees the new masks; asking for the masks it
  already has is a no-op.
  """
  @spec change(Session.t(), Key.t(), masks(), map()) ::
          {:ok, Key.t()} | {:error, :step_up | :masks | :revoked}
  def change(%Session{} = session, %Key{} = key, masks, meta \\ %{}) do
    with true <- live?(key) || {:error, :revoked},
         {:ok, masks} <- masks(masks),
         # Asking for the masks the key has changes nothing and ends nothing.
         true <- masks != Map.take(key, [:read_mask, :write_mask, :may_delete]) || {:ok, key},
         widened = widens?(key, masks),
         :ok <- if(widened, do: fresh(session), else: :ok) do
      key = Store.update!(key, Map.to_list(masks))
      about = %{preset: preset_of(key), may_delete: key.may_delete}
      trail(:api_key_changed, key, about, Audit.ctx(meta, session))

      if widened, do: Accounts.notify(key.account_id, :api_key_widened, %{name: key.name})
      Audit.bye(key.account_id, {{:key, key.id}, :grants})
      {:ok, key}
    end
  end

  # A key's name is mailed in notices to the account's addresses: no
  # control or format character (a newline would write the mail's next line).
  defp name?(name), do: Security.name?(name, 100, 200)

  # Whether `new` grants anything `old` did not.
  defp widens?(old, new) do
    # Bits in new and not in old, without bnot: Dialyzer types `x band bnot(y)`
    # as never zero, which made the `or` below unreachable to it.
    Bitwise.band(new.read_mask, old.read_mask) != new.read_mask or
      Bitwise.band(new.write_mask, old.write_mask) != new.write_mask or
      (new.may_delete and not old.may_delete)
  end

  @spec rename(Key.t(), String.t(), map()) :: {:ok, Key.t()} | {:error, :name}
  def rename(%Key{} = key, name, meta \\ %{}) do
    name = name |> to_string() |> String.trim()

    with true <- name?(name) || {:error, :name},
         true <- name != key.name || {:ok, key},
         :ok <- Security.limit(:renames, key.account_id) do
      key = Store.update!(key, name: name)
      trail(:api_key_renamed, key, %{}, Audit.ctx(meta, key.account_id))
      {:ok, key}
    end
  end

  @doc """
  Lift the operator's pause on a live key (set when the operator revoked
  one of its leases): its sessions may open the channel and claim again.
  A key that is not paused is left as it is and nothing is recorded.
  """
  @spec resume(Key.t(), map()) :: {:ok, Key.t()} | {:error, :not_found}
  def resume(%Key{} = key, meta \\ %{}) do
    with true <- live?(key) || {:error, :not_found},
         true <- key.paused_at != nil || {:ok, key} do
      {n, _} =
        Store.bump(
          from(k in Key, where: k.id == ^key.id and not is_nil(k.paused_at)),
          [paused_at: nil, updated_at: Store.now()],
          skip_account: true
        )

      if n == 1 do
        trail(:key_resumed, key, %{}, Audit.ctx(meta, key.account_id))

        # The sequencer holds paused keys in memory; this lifts its hold.
        Hireme.PubSub.broadcast(Audit.topic(key.account_id), {:resume, {:key, key.id}})
      end

      {:ok, Repo.get(Key, key.id, skip_account: true)}
    end
  end

  @doc "Revoke now. A revoked key fails `authenticate/2` from this moment, its sessions end, and it stays listed."
  @spec revoke(Key.t(), map()) :: Key.t()
  def revoke(%Key{} = key, meta \\ %{}) do
    now = Store.now()

    # Revoked only if still live: a second revoke, or one from a stale
    # struct, changes nothing and announces nothing.
    {n, _} =
      Store.bump(
        from(k in Key, where: k.id == ^key.id and is_nil(k.revoked_at)),
        [revoked_at: now, paused_at: nil, updated_at: now],
        skip_account: true
      )

    if n == 1 do
      trail(:api_key_revoked, key, %{}, Audit.ctx(meta, key.account_id))

      Accounts.notify(key.account_id, :api_key_revoked, %{name: key.name})
      Audit.bye(key.account_id, {{:key, key.id}, :revoked})
    end

    Repo.get(Key, key.id, skip_account: true)
  end

  @doc "Whether key `id` is still one `account_id` may use: live, on an active account."
  @spec usable?(pos_integer(), pos_integer()) :: boolean()
  def usable?(id, account_id) when is_integer(id) do
    case Accounts.joined(Key, dynamic([k], k.id == ^id)) do
      {%Key{account_id: ^account_id} = key, account} -> live?(key) and Accounts.active?(account)
      _ -> false
    end
  end

  @doc """
  The live key a presented secret names, or `:error`. A live key is never
  refused, wherever it comes from. Failures are counted per address
  (`api_key_peer`, twenty a minute); one past them is answered
  `{:error, :rate_limited}`, said apart so a client retries later instead
  of giving the key up.
  """
  @spec authenticate(term(), String.t()) ::
          {:ok, authenticated()} | :error | {:error, :rate_limited}
  def authenticate(presented, peer \\ "")

  def authenticate(presented, peer) when is_binary(presented) do
    with :error <- check(presented), :ok <- Security.limit(:api_key_peer, peer), do: :error
  end

  def authenticate(_, _), do: :error

  defp check(presented) do
    with {:ok, key_id, secret} <- parse(presented),
         {%Key{} = key, account} <- Accounts.joined(Key, dynamic([k], k.key_id == ^key_id)),
         true <- Security.equal?(Security.hash(secret), key.secret_hash),
         true <- live?(key) and Accounts.active?(account) do
      used(key)

      {:ok,
       Map.take(key, [:id, :key_id, :account_id, :name, :read_mask, :write_mask, :may_delete])}
    else
      _ -> :error
    end
  end

  @doc "How a key is shown after mint: `hm_Ed6k…`."
  @spec display(Key.t()) :: String.t()
  def display(%Key{prefix: prefix}), do: @prefix <> prefix <> "…"

  @spec live?(Key.t()) :: boolean()
  def live?(%Key{revoked_at: revoked, expires_at: expires}),
    do: is_nil(revoked) and (is_nil(expires) or DateTime.compare(Store.now(), expires) == :lt)

  defp masks(%{read_mask: r, write_mask: w} = m) when is_integer(r) and is_integer(w) do
    all = Hireme.Grants.all()
    d = Map.get(m, :may_delete, false)

    if Bitwise.band(r, all) == r and Bitwise.band(w, all) == w and
         is_boolean(d) and (r != 0 or w != 0),
       do: {:ok, %{read_mask: r, write_mask: w, may_delete: d}},
       else: {:error, :masks}
  end

  defp masks(_), do: {:error, :masks}

  defp fresh(session), do: if(Mfa.fresh?(session), do: :ok, else: {:error, :step_up})

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
      set = [last_used_at: Store.now()]
      query = from(k in Key, where: k.id == ^key.id)
      Store.write(fn -> Repo.update_all(query, [set: set], skip_account: true) end)
    end
  end

  # A key's own lifecycle row names that key (its id and name in the meta,
  # its id as the row's key tag).
  defp trail(kind, key, about, context) do
    about = Map.merge(%{key_id: key.id, name: key.name}, about)
    Audit.record(kind, about, Map.put(context, :key_id, key.id))
  end
end
