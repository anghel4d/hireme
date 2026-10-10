defmodule Hireme.Fixtures do
  @moduledoc """
  The rows every test opens with: a profile, a line on it, and an
  application. Defaults are unique wherever the schema demands it;
  pass `attrs` for anything a test asserts on. And the reference reader
  for wire frames: `tables/1`, `named/2` and `plain/1`.
  """

  alias Hireme.Corpus
  alias Hireme.Desk

  def profile(attrs \\ %{}) do
    Corpus.create_profile!(
      Map.merge(
        %{
          slug: "candidate-#{uniq()}",
          name: "Sample Candidate",
          headline: "Engineer",
          summary: "A sample profile."
        },
        attrs
      )
    )
  end

  def item(profile, attrs \\ %{}) do
    Corpus.create_item!(
      Map.merge(
        %{
          profile_id: profile.id,
          kind: :experience,
          key: "exp.#{uniq()}",
          title: "Line",
          body: "Root line",
          position: 1
        },
        attrs
      )
    )
  end

  def job(profile, attrs \\ %{}) do
    Desk.create_job!(
      Map.merge(
        %{
          profile_id: profile.id,
          company: "Sample Co",
          role: "Engineer",
          stage: "discovered",
          canonical_url: "https://jobs.example.test/#{uniq()}"
        },
        attrs
      )
    )
  end

  def uniq, do: System.unique_integer([:positive])

  @doc """
  Hold a lease (a job's block of one, or any `Letterbox.acquire/1` want) in a process of its own, as an
  agent's session would: `{acquire_result, pid}`. `let_go/1` releases it as a closing
  session does.
  """
  def hold_lease(job_id) when is_integer(job_id),
    do: hold_lease({:range, entry(job_id), entry(job_id)})

  def hold_lease(want) do
    account_id = Hireme.Repo.account_id!()
    me = self()

    pid =
      spawn(fn ->
        Hireme.Repo.put_account(account_id)
        claim = Hireme.Letterbox.acquire(want)
        send(me, {:held, self(), claim})

        receive do
          {:let_go, from} ->
            with {:ok, block, _} <- claim, do: Hireme.Letterbox.release(block)
            send(from, {:gone, self()})
        end
      end)

    receive do
      {:held, ^pid, result} -> {result, pid}
    end
  end

  @doc "A job's entry: the account's number for it (`no`)."
  def entry(job_id), do: Hireme.Repo.get!(Hireme.Desk.Job, job_id).no

  @doc "End a lease `hold_lease/1` took."
  def let_go(pid) do
    send(pid, {:let_go, self()})

    receive do
      {:gone, ^pid} -> :ok
    end
  end

  @doc """
  A form drawn from `choices`: each field a random one of its choices, under
  a string or an atom key, and some fields left out. Members of a closed set
  travel as atoms or names.
  """
  def form(choices) do
    for {field, values} <- choices, :rand.uniform(4) > 1, into: %{} do
      value =
        case Enum.random(values) do
          atom when is_atom(atom) and not is_nil(atom) ->
            Enum.random([atom, Atom.to_string(atom)])

          other ->
            other
        end

      {Enum.random([Atom.to_string(field), field]), value}
    end
  end

  # ---- The reference reader for wire frames, as the browser reads them ----

  @doc "A frame body's table blocks as `%{table_id => [rows keyed by column id]}`."
  def tables(body), do: tables(body, %{})
  defp tables(<<>>, acc), do: acc

  defp tables(<<id::little-16, ncols::little-16, n::little-32, rest::binary>>, acc) do
    {cols, rest} =
      Enum.map_reduce(1..ncols//1, rest, fn _,
                                            <<cid::little-16, type::8, 0::8, size::little-32,
                                              rest::binary>> ->
        <<data::binary-size(^size), rest::binary>> = rest
        pad = rem(8 - rem(size, 8), 8)
        <<_::binary-size(^pad), rest::binary>> = rest
        {{cid, values(type, n, data)}, rest}
      end)

    rows = for i <- 0..(n - 1)//1, do: Map.new(cols, fn {cid, vs} -> {cid, Enum.at(vs, i)} end)
    tables(rest, Map.update(acc, id, rows, &(&1 ++ rows)))
  end

  defp values(1, _n, data), do: for(<<v::little-32 <- data>>, do: v)
  defp values(3, _n, data), do: for(<<v::little-64 <- data>>, do: v)
  defp values(4, _n, data), do: for(<<v::binary-8 <- data>>, do: v)

  defp values(5, n, data) do
    <<k::little-32, rest::binary>> = data
    syms = values(2, k, rest)
    size = 4 + 4 * (k + 1) + Enum.sum(Enum.map(syms, &byte_size/1))
    ids_at = size + rem(4 - rem(size, 4), 4)
    <<_::binary-size(^ids_at), ids::binary-size(4 * ^n)>> = data
    for <<i::little-32 <- ids>>, do: Enum.at(syms, i)
  end

  defp values(2, n, data) do
    offs_len = 4 * (n + 1)
    <<offs::binary-size(^offs_len), bytes::binary>> = data
    offs = for <<o::little-32 <- offs>>, do: o

    offs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> binary_part(bytes, a, b - a) end)
  end

  @doc "A table's rows by column name, through the schema's column ids; `[]` when absent."
  def named(t, table) do
    ids = HiremeWeb.Packet.columns(table)

    Enum.map(t[HiremeWeb.Packet.table_id(table)] || [], fn row ->
      Map.new(ids, fn {name, cid} -> {name, row[cid]} end)
    end)
  end

  @doc "A frame with any DEFLATE body inflated, as the browser does before ingest."
  def plain({kind, flags, rev, body}) when Bitwise.band(flags, 1) == 1 do
    <<raw_len::little-32, z_len::little-32, rest::binary>> = body
    <<z::binary-size(^z_len), _pad::binary>> = rest
    raw = :zlib.unzip(z)
    ^raw_len = byte_size(raw)
    {kind, Bitwise.band(flags, 0xFE), rev, raw}
  end

  def plain(frame), do: frame
end
