defmodule Hireme.Provenance do
  @moduledoc """
  Where a figure or a text came from: `sources` (one per URL, its host
  derived here and never taken from a writer), `citations` (append-only,
  the only provenance authority: the newest citation of a cell is its
  source, the rest its history) and `trusted_hosts` (the operator's list of
  hosts whose pages may source `culture` and ratings).

  Check 5 of the sequencer, `provenance`, is `check/3`:

  - a metric written without `as_of` is refused `freshness`; one older than
    the cell's stored `<metric>_on` is `stale` (an equal date is a
    restatement and passes); the write moves `<metric>_on` to `as_of`;
  - prose written without `expect_rev` is refused `rev`, as is one whose
    `expect_rev` is not the row's rev (a new row's prose names 0); prose
    without a source is `source_missing`;
  - `culture` and the rating metrics need a source whose host is trusted
    (`source_trust`), and so a source at all (`source_missing`).

  Each metric or prose cell written gets one citation (`cite/4`).
  """

  import Ecto.Query
  alias Hireme.{Audit, Repo, Store}
  alias Hireme.Rows.{Citation, Source, TrustedHost}

  @trusted_only ~w(culture rating rating_count wlb_rating)

  @doc "The host of a URL as sources store it: lowercase, no port, no trailing dot; nil for a non-web URL."
  def host(url) when is_binary(url) do
    # A URL a browser would read another way is refused outright: a browser
    # treats a backslash as a slash, so "https://evil.example\\@levels.fyi/"
    # opens evil.example while URI.parse names levels.fyi; userinfo, spaces
    # and control characters have no place in a source's URL either.
    case !String.match?(url, ~r/[\\\s\p{Cc}]/u) and URI.parse(url) do
      %URI{scheme: s, host: h, userinfo: nil}
      when s in ["http", "https"] and is_binary(h) and h != "" ->
        h |> String.downcase() |> String.trim_trailing(".") |> hostname()

      _ ->
        nil
    end
  end

  def host(_), do: nil

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

  @fixed ~w(url host publisher title kind)a

  @doc """
  A source's identity is fixed once written: its URL (and so its host),
  publisher, title and kind. Every citation of it says what it said when
  cited, so a later writer cannot retarget or relabel it; a new claim is a
  new source. Only its retrieval (`retrieved_at`, `doc`) moves.
  """
  def source_change(nil, %{"url" => url}) do
    if host(url),
      do: :ok,
      else:
        {:refused, :type,
         %{table: "sources", column: "url", reason: "an http(s) URL on a real hostname"}}
  end

  def source_change(nil, _values), do: :ok

  def source_change(row, values) do
    case Enum.find(
           @fixed,
           &(Map.has_key?(values, Atom.to_string(&1)) and
               values[Atom.to_string(&1)] != Map.get(row, &1))
         ) do
      nil ->
        :ok

      col ->
        {:refused, :column,
         %{table: "sources", column: col, reason: "a source's identity is fixed once written"}}
    end
  end

  @doc """
  The source an op names in its `source` cell: an existing source's id, or
  a URL, found by its natural key or created with its host derived.
  `{:ok, source | nil}` or `{:refused, refusal, data}`. Runs inside the
  sequencer's transaction.
  """
  def source(nil, _now), do: {:ok, nil}

  def source(id, _now) when is_integer(id) do
    case Repo.get(Source, id) do
      nil -> {:refused, :source_missing, %{source: id}}
      s -> {:ok, s}
    end
  end

  def source(url, now) when is_binary(url) do
    case host(url) do
      nil ->
        {:refused, :type, %{column: "source", reason: "an http(s) URL or a source id"}}

      host ->
        case Repo.one(from s in Source, where: s.url == ^url) do
          nil ->
            %Source{}
            |> Ecto.Changeset.change(
              url: url,
              host: host,
              rev: 1,
              mutable: true,
              inserted_at: now,
              updated_at: now
            )
            |> Ecto.Changeset.put_change(:account_id, Repo.account_id!())
            |> Repo.insert()
            |> case do
              {:ok, s} -> {:ok, s}
              {:error, cs} -> {:refused, :type, %{column: "source", errors: inspect(cs.errors)}}
            end

          s ->
            {:ok, s}
        end
    end
  end

  @doc """
  Check 5 for the cells one write puts on a row of `table`. `row` is the
  stored row (nil for an insert); `changes` maps column names (strings) to
  values; `ctx` carries `as_of` (Date | nil), `source` (a `Source` | nil),
  `expect_rev` (integer | nil). Returns `{:ok, changes}` with every metric's
  `_on` moved to `as_of`, or `{:refused, refusal, data}`.
  """
  def check(table, row, changes, ctx) do
    cols = Map.new(table.cols, &{&1.name, &1})
    written = for {name, _} <- changes, c = cols[name], c.metric or c.prose, do: c

    Enum.reduce_while(written, {:ok, changes}, fn col, {:ok, acc} ->
      case check_cell(table, col, row, ctx) do
        :ok when col.metric -> {:cont, {:ok, Map.put(acc, col.name <> "_on", ctx.as_of)}}
        :ok -> {:cont, {:ok, acc}}
        refused -> {:halt, refused}
      end
    end)
  end

  defp check_cell(table, %{metric: true, name: name} = col, row, ctx) do
    stored = row && Map.get(row, String.to_atom(name <> "_on"))

    cond do
      ctx.as_of == nil ->
        {:refused, :freshness, %{table: table.name, column: name}}

      stored && Date.compare(ctx.as_of, stored) == :lt ->
        {:refused, :stale, %{table: table.name, column: name, on: Date.to_iso8601(stored)}}

      true ->
        trusted_source(table, col, ctx)
    end
  end

  defp check_cell(table, %{prose: true, name: name} = col, row, ctx) do
    rev = if row, do: row.rev, else: 0

    cond do
      ctx.expect_rev == nil -> {:refused, :rev, %{table: table.name, column: name, rev: rev}}
      ctx.expect_rev != rev -> {:refused, :rev, %{table: table.name, column: name, rev: rev}}
      ctx.source == nil -> {:refused, :source_missing, %{table: table.name, column: name}}
      true -> trusted_source(table, col, ctx)
    end
  end

  defp trusted_source(table, %{name: name}, ctx) when name in @trusted_only do
    cond do
      ctx.source == nil -> {:refused, :source_missing, %{table: table.name, column: name}}
      trusted?(ctx.source.host) -> :ok
      true -> {:refused, :source_trust, %{table: table.name, column: name, host: ctx.source.host}}
    end
  end

  defp trusted_source(_table, _col, _ctx), do: :ok

  # A trusted host covers its subdomains: trusting levels.fyi trusts www.levels.fyi.
  defp trusted?(host) do
    labels = String.split(host, ".")
    hosts = for i <- 0..max(length(labels) - 2, 0), do: labels |> Enum.drop(i) |> Enum.join(".")
    Repo.exists?(from t in TrustedHost, where: t.host in ^hosts)
  end

  @doc """
  One citation per metric or prose cell of a committed write. `cells` are
  `{column_name, value}`; `ctx` carries `source`, `as_of`, `today`, `actor`,
  `key_id`, `op_id`, `now`.
  """
  def cite(table, row_id, cells, ctx) do
    cols = Map.new(table.cols, &{&1.name, &1})

    rows =
      for {name, value} <- cells, c = cols[name], c.metric or c.prose do
        %{
          account_id: Repo.account_id!(),
          table: table.name,
          row_id: row_id,
          column: name,
          source_id: ctx.source && ctx.source.id,
          value: %{"v" => json_value(value)},
          as_of: if(c.metric, do: ctx.as_of, else: ctx.as_of || ctx.today),
          actor: ctx.actor,
          key_id: ctx.key_id,
          op_id: ctx.op_id,
          rev: 1,
          inserted_at: ctx.now,
          updated_at: ctx.now
        }
      end

    if rows != [], do: Repo.insert_all(Citation, rows)
    length(rows)
  end

  defp json_value(%Date{} = d), do: Date.to_iso8601(d)
  defp json_value(v), do: v

  # ------------------------------------------------------ trusted hosts

  @doc "The account's trusted hosts (account on the process)."
  def trusted_hosts do
    Repo.all(
      from t in TrustedHost, order_by: t.host, select: %{id: t.id, host: t.host, note: t.note}
    )
  end

  @doc "Trusts a host (a bare host or a URL). The account lens gates this behind step-up."
  def trust(host_or_url, note, meta) do
    host = host(host_or_url) || normalize(host_or_url)

    if host do
      now = Store.now()

      Store.write(fn ->
        %TrustedHost{}
        |> TrustedHost.changeset(%{host: host, note: note})
        |> Ecto.Changeset.change(rev: 1, inserted_at: now, updated_at: now)
        |> Repo.insert(
          on_conflict: {:replace, [:note, :updated_at]},
          conflict_target: [:account_id, :host]
        )
      end)
      |> tap(fn
        {:ok, _} -> Audit.record(:host_trusted, %{host: host}, audit_ctx(meta))
        _ -> :ok
      end)
    else
      {:error, :host}
    end
  end

  @doc "Stops trusting a host."
  def distrust(id, meta) do
    Store.write(fn -> Repo.delete_all(from t in TrustedHost, where: t.id == ^id) end)
    |> case do
      {1, _} -> Audit.record(:host_distrusted, %{id: id}, audit_ctx(meta))
      _ -> :ok
    end

    :ok
  end

  defp audit_ctx(meta), do: Map.put_new(meta, :account_id, Repo.account_id())

  defp normalize(host) when is_binary(host) do
    h = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")
    if h =~ ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/, do: h
  end

  defp normalize(_), do: nil
end
