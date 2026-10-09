defmodule Hireme.RateLimit do
  @moduledoc false
  # Fixed-window counters in ETS, one per node. `Hireme.Security.limit/3`
  # is the only caller.
  use Hammer, backend: :ets
end

defmodule Hireme.Security do
  @moduledoc """
  The security policy, in one place, and the primitives it is built on.

  Numbers follow the standards current on 2026-10-07: NIST SP 800-63B-4
  (July 2025) for assurance level 2, OWASP ASVS 5.0 (2025) for sessions
  and factors, CIS Controls v8.1 for MFA and logging. Each constant
  says which clause it answers.

  Primitives: a random token, its hash, a constant-time comparison,
  base62 text for keys, and authenticated encryption for secrets that
  must be read back (a TOTP seed).
  """

  @base62 "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  # NIST SP 800-63B-4 Sec. 3.1.2 (AAL2): the overall reauthentication timeout
  # SHOULD be no more than 24 hours; the inactivity timeout SHOULD be no more
  # than 1 hour. ASVS 7.3.1 / 7.3.2.
  @spec session_lifetime() :: pos_integer()
  def session_lifetime, do: 24 * 60 * 60

  @spec session_idle() :: pos_integer()
  def session_idle, do: 60 * 60

  # ASVS 7.5.1 / 7.5.3: full re-authentication before a sensitive change.
  # A second factor presented within this window counts as that.
  @spec step_up_window() :: pos_integer()
  def step_up_window, do: 5 * 60

  # A ceremony in flight (WebAuthn challenge, pending TOTP seed) lives this long.
  @spec challenge_ttl() :: pos_integer()
  def challenge_ttl, do: 5 * 60

  # A sign-in link: one use, bound to the browser that asked, short-lived.
  @spec magic_link_ttl() :: pos_integer()
  def magic_link_ttl, do: 10 * 60

  # NIST SP 800-63B-4 Sec. 3.2.2: no more than 100 consecutive failed
  # attempts on one authenticator before it is disabled.
  @spec lockout_failures() :: pos_integer()
  def lockout_failures, do: 100

  @spec api_keys_per_account() :: pos_integer()
  def api_keys_per_account, do: 100

  # Every throttle in the desk, by name: the window and how many fit in it.
  # ASVS 6.3.1 / 6.6.3: brute force on any factor is refused here.
  @limits %{
    link_address: {:timer.minutes(10), 5},
    link_peer: {:timer.minutes(10), 20},
    redeem_peer: {:timer.minutes(10), 20},
    mfa_account: {:timer.minutes(15), 10},
    api_key_peer: {:timer.minutes(1), 20}
  }

  @doc "Count one attempt under the named policy for `key`; refuse past its cap."
  @spec limit(atom(), String.t() | pos_integer()) :: :ok | {:error, :rate_limited}
  def limit(name, key) when is_map_key(@limits, name) do
    {scale_ms, max} = Map.fetch!(@limits, name)

    case Hireme.RateLimit.hit("#{name}:#{key}", scale_ms, max) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  @doc "`bytes` of CSPRNG output. 32 bytes is 256 bits; ASVS 7.2.3 asks for 128."
  @spec token(pos_integer()) :: binary()
  def token(bytes \\ 32), do: :crypto.strong_rand_bytes(bytes)

  @spec hash(binary()) :: binary()
  def hash(binary) when is_binary(binary), do: :crypto.hash(:sha256, binary)

  @doc "Constant-time equality. Different lengths are unequal without comparing."
  @spec equal?(binary(), binary()) :: boolean()
  def equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  def equal?(_, _), do: false

  @doc """
  `n` base62 characters from batched CSPRNG bytes. Rejecting bytes 248–255
  leaves exactly four equally likely byte values for every character.
  """
  @spec base62(pos_integer()) :: String.t()
  def base62(n) when is_integer(n) and n > 0 do
    base62(<<>>, n, <<>>)
  end

  defp base62(_, 0, acc), do: acc

  defp base62(<<>>, remaining, acc) do
    base62(:crypto.strong_rand_bytes(remaining + div(remaining, 31) + 1), remaining, acc)
  end

  defp base62(<<byte, rest::binary>>, remaining, acc) when byte < 248 do
    base62(rest, remaining - 1, <<acc::binary, :binary.at(@base62, rem(byte, 62))>>)
  end

  defp base62(<<_, rest::binary>>, remaining, acc), do: base62(rest, remaining, acc)

  @doc "A CRC32 of `text` as six base62 characters: a shape check before any lookup."
  @spec checksum(String.t()) :: String.t()
  def checksum(text) do
    text |> :erlang.crc32() |> digits([]) |> List.to_string() |> String.pad_leading(6, "0")
  end

  defp digits(0, acc), do: acc
  defp digits(n, acc), do: digits(div(n, 62), [:binary.at(@base62, rem(n, 62)) | acc])

  @doc "Encrypt a term for storage; the key derives from the application secret."
  @spec seal(term(), String.t()) :: binary()
  def seal(term, purpose) when is_binary(purpose) do
    Plug.Crypto.encrypt(key_base(), purpose, term, max_age: :infinity)
  end

  @spec unseal(binary(), String.t()) :: {:ok, term()} | :error
  def unseal(sealed, purpose) when is_binary(sealed) and is_binary(purpose) do
    case Plug.Crypto.decrypt(key_base(), purpose, sealed, max_age: :infinity) do
      {:ok, term} -> {:ok, term}
      _ -> :error
    end
  end

  defp key_base do
    Application.fetch_env!(:hireme, :secret_key_base)
  end
end
