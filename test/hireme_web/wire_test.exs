defmodule HiremeWeb.WireTest do
  @moduledoc """
  The wire encoder against a reference reader: every frame is whole and
  8-aligned, every table block decodes back to the rows it was given, and
  the frames a session sends (BOOT, PATCH, FOCUS, LINES) hold together.
  The golden frames in test/fixtures/wire/ are built from fixed rows, so
  the same encoder always writes the same bytes; the test fails when the
  committed files and the encoder part, and `WIRE_GOLDEN=1 mix test
  test/hireme_web/wire_test.exs` rewrites them.
  """

  use Hireme.DataCase, async: false

  import Hireme.Fixtures
  alias HiremeWeb.Packet

  @golden Path.expand("../fixtures/wire", __DIR__)

  # The reference reader: a frame's table blocks as %{table_id => [rows]}.
  defp tables(body), do: tables(body, %{})
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

  defp values(2, n, data) do
    offs_len = 4 * (n + 1)
    <<offs::binary-size(^offs_len), bytes::binary>> = data
    offs = for <<o::little-32 <- offs>>, do: o

    offs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> binary_part(bytes, a, b - a) end)
  end

  # Whole frames, with any DEFLATE body inflated the way the browser does
  # before ingest; the binary is re-framed plain, as the kernel sees it.
  defp one!(iodata) do
    bin = IO.iodata_to_binary(iodata)
    assert rem(byte_size(bin), 8) == 0
    assert {:ok, frames, ""} = Packet.split(bin)
    frames = Enum.map(frames, &plain/1)

    plain_bin =
      frames
      |> Enum.map(fn {k, f, r, b} -> Packet.frame(k, r, b, flags: f) end)
      |> IO.iodata_to_binary()

    {plain_bin, frames}
  end

  defp plain({kind, flags, rev, body}) when Bitwise.band(flags, 1) == 1 do
    <<raw_len::little-32, z_len::little-32, rest::binary>> = body
    <<z::binary-size(^z_len), _pad::binary>> = rest
    raw = :zlib.unzip(z)
    assert byte_size(raw) == raw_len
    {kind, Bitwise.band(flags, 0xFE), rev, raw}
  end

  defp plain(frame), do: frame

  defp desk do
    p = profile()
    item(p, %{title: "Shipped", body: "Shipped a thing"})
    item(p, %{title: "Built", body: "Built a thing", key: "exp.b", position: 2})
    jobs = for c <- ~w(Acme Globex Initech), do: job(p, %{company: c})
    {p, jobs}
  end

  # A table's rows by column name, through the schema's column ids.
  defp named(t, table) do
    ids = Packet.columns(table)

    Enum.map(t[Packet.table_id(table)] || [], fn row ->
      Map.new(ids, fn {name, cid} -> {name, row[cid]} end)
    end)
  end

  test "a raw boot decodes back to the account's rows, enums, dates, lists and JSON" do
    {p, [a | _] = jobs} = desk()
    {:ok, rev, {:boot, %{tables: tables}}} = Hireme.Ops.attach(Hireme.Repo.account_id!(), nil)
    body = [Packet.static_lookups(), for({k, rows} <- tables, do: Packet.raw(k, rows))]

    {_bin, [{:boot, 0x02, ^rev, decoded}]} = one!(Packet.frame(:boot, rev, body, flags: 0x02))
    t = tables(decoded)
    rows = named(t, :job_apps)
    assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort(Enum.map(jobs, & &1.id))
    row = Enum.find(rows, &(&1.id == a.id))
    assert row.current_stage == "discovered"
    assert row.profile_id == p.id
    assert row.company == "Acme"

    assert row.stage_on == Date.diff(Date.utc_today(), ~D[1970-01-01]) or
             row.stage_on == 0xFFFFFFFF

    assert [item | _] = named(t, :items)
    assert is_binary(item.keywords)

    assert Enum.map(named(t, :stages), & &1.key) ==
             Enum.map(Hireme.Pipeline.keys(), &Atom.to_string/1)

    zbin = IO.iodata_to_binary(Packet.frame(:boot, rev, body, deflate: true, flags: 0x02))
    assert {:ok, [{:boot, 0x03, ^rev, _} = packed], ""} = Packet.split(zbin)
    assert plain(packed) == {:boot, 0x02, rev, decoded}
  end

  test "a raw patch carries partial rows, U+001F lists and deletions" do
    {_p, [a, b | _]} = desk()

    body = [
      Packet.raw(:job_apps, [%{id: a.id, next_action: "Call back"}]),
      Packet.raw(:cv_variants, [
        %{id: 7, theme: %{"targets" => ["elixir", "rust"], "accent" => "ink"}}
      ]),
      Packet.raw(:batches, [
        %{id: 3, code: "B-1", fire: :open_fire, variety: %{"apps" => 4, "flags" => ["mixed"]}}
      ]),
      Packet.table(:gone, [%{table: Packet.table_id(:job_apps), id: b.id}])
    ]

    {_bin, [{:patch, 0, 8, decoded}]} = one!(Packet.frame(:patch, 8, body))
    t = tables(decoded)
    # A partial row carries only its columns; the rest stay as the reader has them.
    assert [%{id: id, next_action: "Call back", listing: nil, company: nil}] = named(t, :job_apps)
    assert id == a.id

    assert [%{theme_targets: "elixir" <> <<0x1F>> <> "rust", theme: theme}] =
             named(t, :cv_variants)

    assert Jason.decode!(theme)["accent"] == "ink"
    assert [%{fire: 1, variety_apps: 4, variety_flags: "mixed"}] = named(t, :batches)
    assert [%{table: 47, id: gone}] = named(t, :gone)
    assert gone == b.id
  end

  # ---- Golden frames: fixed rows, so the bytes never depend on when, where
  # or in what order they were built. The Rust and TypeScript readers test
  # against these files; this test fails when the encoder's output and the
  # committed bytes part, and WIRE_GOLDEN=1 rewrites them.

  @day ~D[2026-10-09]
  @at ~U[2026-10-09 12:00:00Z]

  defp golden_tables do
    %{
      profiles: [
        %{
          id: 1,
          user_id: 1,
          slug: "systems",
          name: "Systems",
          headline: "Engineer",
          summary: "Builds systems."
        }
      ],
      items: [
        %{
          id: 11,
          profile_id: 1,
          kind: :experience,
          key: "exp.a",
          title: "Shipped",
          body: "Shipped a thing",
          org: "Acme",
          span: "2024",
          position: 1,
          keywords: ["elixir", "rust"]
        },
        %{
          id: 12,
          profile_id: nil,
          kind: :skill,
          key: "skill.b",
          title: "Rust",
          body: "",
          org: "",
          span: "",
          position: 2,
          keywords: []
        }
      ],
      batches: [
        %{
          id: 3,
          code: "B-1",
          ordinal: 1,
          kind: :day_pack,
          status: :draft_prep,
          fire: :hold,
          target_size: 10,
          queued_on: @day,
          squad: "core",
          variety: %{
            "apps" => 2,
            "companies" => 2,
            "roles" => 1,
            "locations" => 1,
            "fits" => 1,
            "flags" => ["mixed"]
          },
          note: ""
        }
      ],
      cv_lineages: [
        %{
          id: 5,
          employer_id: 9,
          generation: 1,
          opened_on: @day,
          rewrites_allowed: true,
          theme: %{"targets" => ["elixir"], "accent" => "ink"}
        }
      ],
      cv_variants: [
        %{
          id: 7,
          job_app_id: 100,
          profile_id: 1,
          lineage_id: 5,
          label: "Acme CV",
          theme: %{"targets" => ["elixir", "rust"], "accent" => "ink", "density" => "cv"},
          note: ""
        }
      ],
      overlays: [
        %{
          id: 21,
          job_app_id: 100,
          item_id: 11,
          lineage_id: 5,
          mode: :altered,
          title: nil,
          body: "Shipped it twice",
          reason: "Sharper",
          generation: 1
        }
      ],
      job_apps: [
        %{
          id: 100,
          profile_id: 1,
          employer_id: 9,
          batch_id: 3,
          company: "Acme",
          role: "Engineer",
          location: "Remote",
          listing_url: "https://jobs.example.test/1",
          canonical_url: "https://jobs.example.test/1",
          listing: "Elixir and Rust.",
          heat: 3,
          status: :open,
          next_action: "Call",
          next_due: @day,
          source: "manual",
          stage_on: @day,
          current_stage: :in_batch,
          pips: "DDDAPPPPPP",
          stage_notes: %{"in_batch" => "named"},
          freshness: :open,
          gate: :pursue,
          fit: "strong",
          squad: "core",
          department: "eng",
          score_100: 80,
          heat_override: false,
          heat_override_reason: nil,
          keyword_hits: 2,
          keyword_total: 3,
          mask_hidden: 0,
          mask_altered: 1,
          mask_emphasized: 0,
          inserted_at: @at,
          updated_at: @at
        },
        %{
          id: 101,
          profile_id: 1,
          employer_id: 9,
          batch_id: nil,
          company: "Globex",
          role: "Engineer",
          location: "Berlin",
          listing_url: "",
          canonical_url: "",
          listing: "",
          heat: 1,
          status: :open,
          next_action: "",
          next_due: nil,
          source: "manual",
          stage_on: nil,
          current_stage: :discovered,
          pips: "APPPPPPPPP",
          stage_notes: %{},
          freshness: :unknown,
          gate: :unset,
          fit: "",
          squad: "",
          department: "",
          score_100: 40,
          heat_override: false,
          heat_override_reason: nil,
          keyword_hits: 0,
          keyword_total: 0,
          mask_hidden: 0,
          mask_altered: 0,
          mask_emphasized: 0,
          inserted_at: @at,
          updated_at: @at
        }
      ],
      events: [
        %{id: 31, job_app_id: 100, kind: "stage", body: "Stage → In batch", inserted_at: @at}
      ],
      kv_pairs: [%{id: 41, namespace: "global", key: "candidate", value: "Sample Candidate"}],
      narratives: [%{id: 51, user_id: 1, body: "A story.", version: 2, private: true}],
      scoreboard_snapshots: [
        %{
          id: 61,
          noted_on: @day,
          leftover_unique: 4,
          target_total: 100,
          target_on: @day,
          daily_batches: 1,
          daily_apps: 10,
          note: ""
        }
      ],
      gym_problems: [
        %{
          id: 71,
          platform: :leetcode,
          slug: "two-sum",
          title: "Two Sum",
          topic: :arrays,
          difficulty: :easy,
          url: "https://example.test/two-sum"
        }
      ],
      gym_reps: [
        %{id: 81, problem_id: 71, done_on: @day, minutes: 20, outcome: :solved, note: ""}
      ],
      net_entries: [
        %{
          id: 91,
          kind: :post,
          channel: :linkedin,
          title: "Shipped",
          url: "",
          body: "",
          shipped_on: @day
        }
      ],
      leases: [%{id: 101}]
    }
  end

  defp golden_boot do
    t = golden_tables()

    [
      Packet.static_lookups(),
      for(k <- Enum.sort(Map.keys(t)), do: Packet.raw(k, t[k])),
      Packet.table(:clock, [%{today: @day, now: @at}])
    ]
  end

  defp golden_patch do
    [
      Packet.raw(:job_apps, [
        %{id: 100, current_stage: :submitted, pips: "DDDDDDDAPP", stage_on: @day}
      ]),
      Packet.raw(:events, [
        %{id: 32, job_app_id: 100, kind: "stage", body: "Stage → Submitted", inserted_at: @at}
      ]),
      Packet.table(:gone, [%{table: Packet.table_id(:leases), id: 101}])
    ]
  end

  test "the golden frames are exactly what the encoder writes for the fixed rows" do
    boot = IO.iodata_to_binary(Packet.frame(:boot, 7, golden_boot(), flags: 0x02))
    patch = IO.iodata_to_binary(Packet.frame(:patch, 8, golden_patch()))

    deflated =
      IO.iodata_to_binary(Packet.frame(:boot, 7, golden_boot(), deflate: true, flags: 0x02))

    # Built twice, the same bytes: nothing here reads a clock, a path or an id sequence.
    assert boot == IO.iodata_to_binary(Packet.frame(:boot, 7, golden_boot(), flags: 0x02))

    if System.get_env("WIRE_GOLDEN") == "1" do
      File.write!(Path.join(@golden, "boot.bin"), boot)
      File.write!(Path.join(@golden, "patch.bin"), patch)
      File.write!(Path.join(@golden, "boot.deflate.bin"), deflated)
    end

    assert File.read!(Path.join(@golden, "boot.bin")) == boot
    assert File.read!(Path.join(@golden, "patch.bin")) == patch

    # zlib's output may differ across zlib releases; what must not differ is what it inflates to.
    {_, [packed], _} =
      Packet.split(File.read!(Path.join(@golden, "boot.deflate.bin")))
      |> then(fn {:ok, f, r} -> {:ok, f, r} end)

    {:ok, [{:boot, 0x02, 7, plain_body}], ""} = Packet.split(boot)
    assert plain(packed) == {:boot, 0x02, 7, plain_body}
  end

  test "split refuses torn lengths and other schemas, and keeps partial frames" do
    bin = IO.iodata_to_binary(Packet.frame(:ping, 0, <<1::little-64>>))
    torn = binary_part(bin, 0, 20)
    assert {:ok, [], ^torn} = Packet.split(torn)
    assert {:ok, [{:ping, 0, 0, <<1::little-64>>}], ""} = Packet.split(bin)
    assert {:error, :frame_length} = Packet.split(<<12::little-32, 0::96>>)
    <<len::binary-4, kind::8, flags::8, _hash::16, rest::binary>> = bin
    assert {:error, :schema} = Packet.split(len <> <<kind, flags>> <> <<0::16>> <> rest)
  end
end
