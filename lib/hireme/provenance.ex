defmodule Hireme.Provenance do
  @moduledoc """
  Where a figure or a text came from, the server's part: a source's host
  is derived here (`host/1`) and never taken from a writer, and
  `trusted_hosts` is the operator's list of hosts whose pages may source
  `culture` and the ratings (`trust/3`, `distrust/2`). The provenance
  checks themselves (freshness, stale, rev, source_missing, source_trust)
  and the citations are the kernel's, as the one judge of every put.
  """

  import Ecto.Query
  alias Hireme.{Audit, Repo, Store}
  alias Hireme.Rows.TrustedHost

  @doc "The host of a URL as sources store it: lowercase, no port, no trailing dot; nil for a non-web URL."
  # A source URL is a link, not a payload: past this it is refused before
  # any parsing (a megabyte of labels or port digits costs the writer lock).
  @url_max 2_048

  def host(url) when is_binary(url) and byte_size(url) > @url_max, do: nil

  def host(url) when is_binary(url) do
    # A URL a browser would read another way is refused outright: a browser
    # treats a backslash as a slash, so "https://evil.example\\@levels.fyi/"
    # opens evil.example while URI.parse names levels.fyi; userinfo, spaces
    # and control characters have no place in a source's URL either.
    case !String.match?(url, ~r/[\\\s\p{Cc}]/u) and port_ok?(url) and URI.parse(url) do
      %URI{scheme: s, host: h, userinfo: nil}
      when s in ["http", "https"] and is_binary(h) and h != "" ->
        h |> String.downcase() |> String.trim_trailing(".") |> hostname()

      _ ->
        nil
    end
  end

  def host(_), do: nil

  # The authority's port as a browser reads it (WHATWG): absent, empty, or
  # ASCII digits up to 65535; ":99999", ":80a" or ":１" open nothing.
  # Leading zeros are allowed (":080"); at most five digits remain to convert.
  defp port_number?(port) do
    digits = String.trim_leading(port, "0")

    port =~ ~r/^[0-9]+$/ and byte_size(digits) <= 5 and
      (digits == "" or String.to_integer(digits) <= 65_535)
  end

  defp port_ok?(url) do
    authority =
      case String.split(url, "://", parts: 2) do
        [_, rest] -> rest |> String.split(["/", "?", "#"], parts: 2) |> hd()
        _ -> ""
      end

    case String.split(authority, ":", parts: 2) do
      [_host] -> true
      [_host, ""] -> true
      [_host, port] -> port_number?(port)
    end
  end

  # Only a real hostname counts: labels of letters, digits and hyphens. A
  # host like "evil%5c.levels.fyi" must not pass as a subdomain of a trusted one.
  # A DNS name, not an address: at most 253 characters, and a last label
  # that is no number (a browser reads "127.1" and "0x7f.1" as 127.0.0.1).
  defp hostname(h) do
    tld = h |> String.split(".") |> List.last()

    if byte_size(h) <= 253 and
         h =~ ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/ and
         tld =~ ~r/[a-z]/ and not String.starts_with?(tld, "0x"),
       do: h
  end

  @doc "The account's trusted hosts (account on the process)."
  def trusted_hosts do
    Repo.all(
      from t in TrustedHost, order_by: t.host, select: %{id: t.id, host: t.host, note: t.note}
    )
  end

  @doc "Trusts a host (a bare host or a URL). The account lens gates this behind step-up."
  def trust(host_or_url, note, meta) do
    host = host(host_or_url) || normalize(host_or_url)

    cond do
      host == nil ->
        {:error, :host}

      Repo.aggregate(TrustedHost, :count) >= Hireme.Schema.table(:trusted_hosts).cap and
          not Repo.exists?(from t in TrustedHost, where: t.host == ^host) ->
        {:error, :cap}

      true ->
        trust_host(host, note, meta)
    end
  end

  defp trust_host(host, note, meta) do
    now = Store.now()

    row = %TrustedHost{
      account_id: Repo.account_id(),
      host: host,
      note: if(note == "", do: nil, else: note),
      rev: 1,
      inserted_at: now,
      updated_at: now
    }

    Store.write(fn ->
      Repo.insert(row,
        on_conflict: {:replace, [:note, :updated_at]},
        conflict_target: [:account_id, :host]
      )
    end)
    |> tap(fn
      {:ok, _} -> Audit.record(:host_trusted, %{host: host}, audit_ctx(meta))
      _ -> :ok
    end)
  end

  @doc "Stops trusting a host."
  def distrust(id, meta) do
    with {1, _} <-
           Store.write(fn -> Repo.delete_all(from t in TrustedHost, where: t.id == ^id) end),
         do: Audit.record(:host_distrusted, %{id: id}, audit_ctx(meta))

    :ok
  end

  defp audit_ctx(meta), do: Map.put_new(meta, :account_id, Repo.account_id())

  # A bare host (no scheme) the operator types: the same DNS-name rule.
  defp normalize(host) when is_binary(host),
    do: host |> String.trim() |> String.downcase() |> String.trim_trailing(".") |> hostname()

  defp normalize(_), do: nil
end
