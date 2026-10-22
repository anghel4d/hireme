defmodule Hireme.RateLimit do
  @moduledoc false
  # Fixed-window counters in ETS, one table per node. `Hireme.Security`
  # is the only caller.
  use Hammer, backend: :ets
end

defmodule Hireme.Security do
  @moduledoc """
  The security policy in one place, and the primitives it is built on.

  Numbers answer the standards current on 2026-10-18: NIST SP 800-63B-4
  (July 2025) at assurance level 2, OWASP ASVS 5.0 for sessions and
  factors, CIS Controls v8.1 for MFA and logging, WebAuthn Level 3. Each
  constant names the clause it answers. Every throttle is named here and
  counted through `limit/2` or `hit/3`; no other module holds a number
  that bounds an attacker.

  Primitives: CSPRNG tokens, SHA-256, constant-time comparison, base62
  text for keys, a CRC shape check, and authenticated encryption for
  secrets that must be read back (a TOTP seed, a ceremony in flight).
  """

  @base62 "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  ## Sessions and ceremonies

  # NIST SP 800-63B-4 Sec. 2.2.3 (AAL2): reauthenticate at least every 24 h
  # and after at most 1 h of inactivity. ASVS 7.3.1, 7.3.2. A session signed
  # in with "Remember this device" is the operator's documented exception
  # (ASVS 7.3 lets the risk analysis set them): 30 days from its last use,
  # never past 90 days from sign-in; sensitive changes still step up.
  @spec session_lifetime(boolean()) :: pos_integer()
  def session_lifetime(remember \\ false), do: if(remember, do: 90, else: 1) * 24 * 60 * 60

  @spec session_idle(boolean()) :: pos_integer()
  def session_idle(remember \\ false), do: if(remember, do: 30 * 24 * 60 * 60, else: 60 * 60)

  # ASVS 7.5.1, 7.5.3: re-authenticate before a sensitive change; a second
  # factor presented within this window counts.
  @spec step_up_window() :: pos_integer()
  def step_up_window, do: 5 * 60

  # A ceremony in flight (WebAuthn challenge, pending TOTP seed).
  @spec challenge_ttl() :: pos_integer()
  def challenge_ttl, do: 5 * 60

  # A mailed sign-in link: one use, short-lived.
  @spec magic_link_ttl() :: pos_integer()
  def magic_link_ttl, do: 10 * 60

  # A wire ticket: minted by the signed-in page, spent by one HELLO.
  @spec ticket_ttl() :: pos_integer()
  def ticket_ttl, do: 60

  # NIST SP 800-63B-4 Sec. 3.2.2: at most 100 consecutive failures on one
  # authenticator before it is disabled.
  @spec lockout_failures() :: pos_integer()
  def lockout_failures, do: 100

  @spec api_keys_per_account() :: pos_integer()
  def api_keys_per_account, do: 100

  # Wire sessions one peer holds open at once, authenticated or not, as the
  # gate's GATE_PER_IP bounds its carrier.
  @spec wire_sessions_per_peer() :: pos_integer()
  def wire_sessions_per_peer, do: 16

  # The bytes an account's text may hold (every str, text and json cell,
  # as the sequencer counts them in accounts.text_bytes):
  # one SQLite file serves every account.
  @spec account_text_bytes() :: pos_integer()
  def account_text_bytes, do: 1024 * 1024 * 1024

  # Days the trail keeps activity rows (an agent's op batches, its HELLOs,
  # its leases opening and closing); security events are kept forever.
  @spec activity_retention_days() :: pos_integer()
  def activity_retention_days, do: 90

  # Refused key HELLOs are anonymous and come at the global budget's rate;
  # they are kept a week.
  @spec refusal_retention_days() :: pos_integer()
  def refusal_retention_days, do: 7

  # One key's wire sessions open at once; a connect loop or a leaked key
  # cannot hold the node's sessions. An MCP session over it makes room by
  # closing the key's longest-idle one (`HiremeWeb.Mcp.Session`).
  @spec key_sessions() :: pos_integer()
  def key_sessions, do: 64

  ## The wire carrier

  # Liveness is the carrier: a PING every 15 s, and 45 s without any frame
  # ends the session and with it the lease (SECURITY.md, "Carrier").
  @spec ping_interval() :: pos_integer()
  def ping_interval, do: 15_000

  @spec carrier_timeout() :: pos_integer()
  def carrier_timeout, do: 45_000

  ## Named limits

  # The window in ms and how many fit in it. ASVS 6.3.1, 6.6.3: brute force
  # on any factor or credential stops here. `agent_write` is a circuit
  # breaker on a key's writes for clear abuse, not a pace: work goes as fast
  # as the node does, and a bulk contract (`agent_bulk`) is outside it.
  @limits %{
    link_address: {:timer.minutes(10), 5},
    link_peer: {:timer.minutes(10), 20},
    # Every sign-in link the node sends, whoever asks: the mail provider's
    # reputation is the node's, and peers are cheap.
    link_global: {:timer.minutes(10), 300},
    redeem_peer: {:timer.minutes(10), 20},
    # Step-up codes mailed per account (`Hireme.Mfa.mail_code/2`), like a link.
    step_up_mail: {:timer.minutes(10), 5},
    mfa_account: {:timer.minutes(15), 10},
    api_key_peer: {:timer.minutes(1), 20},
    ticket_peer: {:timer.minutes(1), 60},
    # /wire upgrades; each connection may buffer a frame before its HELLO,
    # and agents behind one NAT share a peer, so this bounds the rate and
    # `wire_sessions_per_peer/0` the memory held at once.
    wire_peer: {:timer.minutes(1), 300},
    # Refused key HELLOs the trail records, from everyone together; past it
    # they are still refused, just not recorded.
    refusal_global: {:timer.minutes(1), 600},
    refusal_peer: {:timer.minutes(10), 20},
    # OAuth callbacks that reach the provider and may sign someone in.
    oauth_peer: {:timer.minutes(10), 20},
    oauth_global: {:timer.minutes(10), 300},
    # Renames of an account or its keys, each a trail row.
    renames: {:timer.minutes(10), 30},
    # Every other account.* call that writes the trail or mails a notice.
    account_writes: {:timer.minutes(10), 60},
    # Trail rows for an account's activity (agent op batches, key HELLOs,
    # leases opening and closing), and for lease revokes; past either the
    # rows coalesce into one per window (`Hireme.Audit.Coalescer`).
    activity: {:timer.minutes(10), 1000},
    revokes: {:timer.minutes(10), 120},
    # A key's HELLOs on the trail; past it the first per (key, address) in a
    # window is still written.
    hellos: {:timer.minutes(10), 600},
    # Every account's activity rows together: the node's ceiling. Past it an
    # account still writes its floor.
    activity_node: {:timer.minutes(10), 20_000},
    activity_floor: {:timer.minutes(10), 100},
    # Notice rows queued per account (an event to many addresses is many).
    notice_rows: {:timer.minutes(10), 300},
    # Notices of a change that must reach the owner as itself, in two
    # classes so one cannot spend the other's: a factor or a way in (added,
    # removed, disabled, linked, unlinked, recovery codes), and a key
    # (created, widened).
    factor_notices: {:timer.minutes(10), 10},
    key_notices: {:timer.minutes(10), 10},
    # Ceremonies begun (a TOTP QR, passkey options), per browser session.
    ceremony_session: {:timer.minutes(10), 30},
    # Security notices queued per account, every address together; past
    # it they coalesce into one digest per address.
    notices: {:timer.minutes(10), 30},
    agent_write: {:timer.minutes(1), 100_000},
    # The writes a key's bulk contracts (lease `bulk`) may reserve in an hour.
    agent_bulk: {:timer.hours(1), 5_000_000},
    # A key's lease requests (lease.*).
    agent_read: {:timer.minutes(1), 3000},
    # Signed messages one domain pipe posts (`HiremeWeb.MailInbound`), per pipe.
    mail_inbound: {:timer.minutes(10), 600}
  }

  @doc "The named limits, for SECURITY.md and the account lens."
  @spec limits() :: %{atom() => {pos_integer(), pos_integer()}}
  def limits, do: @limits

  @doc "Count one attempt under the named limit for `key`; refuse past its cap."
  @spec limit(atom(), term()) :: :ok | {:error, :rate_limited}
  def limit(name, key), do: with({:error, _} <- hit(name, key, 1), do: {:error, :rate_limited})

  @doc """
  Count `n` under the named limit for `key`. A refusal says how many ms
  remain in the window; the refused count is not taken back, so a caller
  that keeps hammering stays refused.
  """
  @spec hit(atom(), term(), pos_integer()) :: :ok | {:error, non_neg_integer()}
  def hit(name, key, n) when is_map_key(@limits, name) and is_integer(n) and n > 0 do
    {scale_ms, max} = Map.fetch!(@limits, name)

    case Hireme.RateLimit.hit(bucket(name, key), scale_ms, max, n) do
      {:allow, _} -> :ok
      {:deny, retry_ms} -> {:error, retry_ms}
    end
  end

  @doc """
  Whether `key` is already over the named limit, without counting. With
  `failed/2` this throttles failures only, so callers that succeed behind
  one address (agents behind a NAT) never spend the budget.
  """
  @spec blocked?(atom(), term()) :: boolean()
  def blocked?(name, key) when is_map_key(@limits, name) do
    {scale_ms, max} = Map.fetch!(@limits, name)
    Hireme.RateLimit.get(bucket(name, key), scale_ms) >= max
  end

  @doc "Give back one count taken under the named limit for `key` (a call that wrote nothing)."
  @spec refund(atom(), term()) :: :ok
  def refund(name, key) when is_map_key(@limits, name) do
    {scale_ms, _} = Map.fetch!(@limits, name)
    # Hammer's API only adds (its increment is a pos_integer), so the take-back
    # is on its fixed window's ETS row, {{key, window}, count, expires_at}:
    # a decrement floored at zero, and nothing once that window has rolled.
    window = div(System.system_time(:millisecond), scale_ms)
    :ets.update_counter(Hireme.RateLimit, {bucket(name, key), window}, {2, -1, 0, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Count one failure under the named limit for `key`."
  @spec failed(atom(), term()) :: :ok
  def failed(name, key) when is_map_key(@limits, name) do
    {scale_ms, _} = Map.fetch!(@limits, name)
    Hireme.RateLimit.inc(bucket(name, key), scale_ms)
    :ok
  end

  # A `*_peer` limit counts an IPv6 peer by its /64: one host holds a whole
  # /64 and could otherwise rotate through 2^64 peers.
  defp bucket(name, key) do
    if String.ends_with?(Atom.to_string(name), "_peer"),
      do: "#{name}:#{peer(key)}",
      else: "#{name}:#{key}"
  end

  @doc """
  `bin` inflated (zlib; gzip with `window` 31), or nil when it is no such
  stream or would pass `max` bytes: nothing a peer sends inflates unbounded.
  """
  @spec inflate(binary(), pos_integer(), pos_integer()) :: binary() | nil
  def inflate(bin, max, window \\ 15) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, window)
      inflating(z, :zlib.safeInflate(z, bin), max, [], 0)
    rescue
      _ -> nil
    after
      :zlib.close(z)
    end
  end

  defp inflating(z, {status, out}, max, acc, n) do
    n = n + IO.iodata_length(out)

    cond do
      n > max -> nil
      status == :finished -> IO.iodata_to_binary([acc | out])
      true -> inflating(z, :zlib.safeInflate(z, []), max, [acc | out], n)
    end
  end

  @doc "The peer a limit counts: an IPv4 address as is, an IPv6 one by its /64."
  @spec peer(term()) :: String.t()
  def peer(ip) do
    case is_binary(ip) && :inet.parse_ipv6strict_address(String.to_charlist(ip)) do
      # ::ffff:a.b.c.d is the v4 peer a.b.c.d.
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, hi, lo}} ->
        :inet.ntoa({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}) |> to_string()

      {:ok, {a, b, c, d, _, _, _, _}} ->
        :inet.ntoa({a, b, c, d, 0, 0, 0, 0}) |> to_string() |> Kernel.<>("/64")

      _ ->
        to_string(ip)
    end
  end

  ## Primitives

  @doc "`bytes` of CSPRNG output; 32 is 256 bits (ASVS 7.2.3 asks for 128)."
  @spec token(pos_integer()) :: binary()
  def token(bytes \\ 32), do: :crypto.strong_rand_bytes(bytes)

  @spec hash(binary()) :: binary()
  def hash(binary) when is_binary(binary), do: :crypto.hash(:sha256, binary)

  @doc "Constant-time equality; different lengths are unequal without comparing."
  @spec equal?(binary(), binary()) :: boolean()
  def equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  def equal?(_, _), do: false

  @doc "A token as URL text, and back."
  @spec encode(binary()) :: String.t()
  def encode(raw), do: Base.url_encode64(raw, padding: false)

  @spec decode(term()) :: {:ok, binary()} | :error
  def decode(text) when is_binary(text), do: Base.url_decode64(text, padding: false)
  def decode(_), do: :error

  @doc """
  `n` base62 characters from batched CSPRNG bytes. Rejecting bytes 248-255
  leaves exactly four equally likely bytes per character.
  """
  @spec base62(pos_integer()) :: String.t()
  def base62(n) when is_integer(n) and n > 0, do: base62(<<>>, n, <<>>)

  defp base62(_, 0, acc), do: acc

  defp base62(<<>>, left, acc),
    do: base62(:crypto.strong_rand_bytes(left + div(left, 31) + 1), left, acc)

  defp base62(<<byte, rest::binary>>, left, acc) when byte < 248,
    do: base62(rest, left - 1, <<acc::binary, :binary.at(@base62, rem(byte, 62))>>)

  defp base62(<<_, rest::binary>>, left, acc), do: base62(rest, left, acc)

  @doc "CRC32 of `text` as six base62 characters: a shape check before any lookup."
  @spec checksum(String.t()) :: String.t()
  def checksum(text) do
    text |> :erlang.crc32() |> digits([]) |> List.to_string() |> String.pad_leading(6, "0")
  end

  defp digits(0, acc), do: acc
  defp digits(n, acc), do: digits(div(n, 62), [:binary.at(@base62, rem(n, 62)) | acc])

  @doc "Encrypt a term for storage under `purpose`; the key derives from the application secret."
  @spec seal(term(), String.t()) :: binary()
  def seal(term, purpose) when is_binary(purpose),
    do: Plug.Crypto.encrypt(key_base(), purpose, term, max_age: :infinity)

  @spec unseal(binary(), String.t()) :: {:ok, term()} | :error
  def unseal(sealed, purpose) when is_binary(sealed) and is_binary(purpose) do
    with {:error, _} <- Plug.Crypto.decrypt(key_base(), purpose, sealed, max_age: :infinity),
         do: :error
  end

  @doc """
  Whether `name` may name something the account sees and mail repeats:
  non-empty, at most `chars` characters and `bytes` bytes (a letter with
  a million combining marks is one character), no control or format
  character, and no run of more than four combining marks.
  """
  @spec name?(term(), pos_integer(), pos_integer()) :: boolean()
  def name?(name, chars, bytes) do
    is_binary(name) and name != "" and byte_size(name) <= bytes and String.valid?(name) and
      String.length(name) <= chars and
      not String.match?(name, ~r/[\p{Cc}\p{Cf}\x{2028}\x{2029}]|\p{M}{5,}/u)
  end

  @doc """
  A clipped, printable copy of request metadata for the trail: byte-wise,
  every byte outside printable ASCII becomes `?`, so any input (a header of
  invalid UTF-8 included) gives a valid string and never raises.
  """
  @spec clip(term(), pos_integer()) :: String.t()
  def clip(text, max \\ 200) do
    bin = to_string(text)
    bin = binary_part(bin, 0, min(byte_size(bin), max))
    for <<b <- bin>>, into: "", do: if(b in 0x20..0x7E, do: <<b>>, else: "?")
  end

  @doc "`clip/2` with nothing, nil or blank, as nil: no column holds an empty string."
  @spec text(term(), pos_integer()) :: String.t() | nil
  def text(value, max) do
    case clip(value, max) do
      "" -> nil
      text -> text
    end
  end

  defp key_base, do: Application.fetch_env!(:hireme, :secret_key_base)
end
