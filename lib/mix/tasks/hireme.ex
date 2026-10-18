defmodule Mix.Tasks.Hireme.Schema do
  @shortdoc "Emit the database baseline and the TypeScript types from schema/hireme.schema"
  @moduledoc """
  The cross-language outputs of `schema/hireme.schema`, emitted by
  `native/schema`'s `hireme-schema` binary:

    * `priv/db/baseline.sql`: the whole declaration on an empty database
    * `assets/js/gen/schema.ts`: ids, enums, the catalog and row interfaces

  Options:

    * `--check`: write nothing; fail when a checked-in output differs from
      a fresh emit, when the Rust and Elixir readings of the file differ,
      when the baseline does not apply to an empty database, or when an
      existing table, column or command changed its id
    * `--migration NAME`: also write `priv/db/NNNN_NAME.sql`, the
      declaration minus the previous baseline (additive only; a destructive
      change is refused and written by hand as `NNNN_drop_<what>.sql`)
    * `--renumber`: allow existing ids to move (before the cutover only)
    * `--freeze`: write `priv/db/baseline.lock`, the SHA-256 of the
      checked-in baseline. The cutover runs it once: from then on deployed
      databases hold that baseline, so a plain emit that would change it is
      refused (a change ships as `--migration NAME`, which writes its
      `NNNN` step and locks the new baseline), and `--check` fails on a
      baseline the lock does not name. Before the freeze, an emit rewrites
      the baseline freely.

  A database is built from the baseline when empty, and from the `NNNN`
  files it has not applied otherwise (`Hireme.Release`), so the baseline is
  always the whole declaration and each `NNNN` file is one step of it.
  """

  use Mix.Task

  @root Path.expand("../../..", __DIR__)
  @baseline "priv/db/baseline.sql"
  @lock "priv/db/baseline.lock"
  @ts "assets/js/gen/schema.ts"

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [check: :boolean, migration: :string, renumber: :boolean, freeze: :boolean]
      )

    # A mistyped --check must not turn into a write.
    if invalid != [] or rest != [],
      do:
        Mix.raise(
          "unknown arguments #{inspect(Enum.map(invalid, &elem(&1, 0)) ++ rest)}; see mix help hireme.schema"
        )

    Mix.Task.run("compile")

    sql = emit!(["sql"])
    ts = emit!(["ts"])

    cond do
      opts[:freeze] -> freeze!(sql, ts, opts)
      opts[:check] -> check!(sql, ts, opts)
      true -> write!(sql, ts, opts)
    end
  end

  defp write!(sql, ts, opts) do
    # Ids are the wire's ABI: once a baseline is deployed they never move,
    # so a reorder belongs before --freeze.
    if opts[:renumber] && locked(),
      do: Mix.raise("ids may not move once #{@lock} exists; a reorder belongs before --freeze")

    guard_ids!(ts, opts)

    case {locked(), opts[:migration]} do
      {nil, nil} ->
        :ok

      {nil, name} ->
        migration!(name)

      {hash, nil} ->
        if sha(sql) != hash,
          do:
            Mix.raise(
              "#{@baseline} is frozen: deployed databases hold it. " <>
                "Ship this change as mix hireme.schema --migration NAME"
            )

      {_hash, name} ->
        migration!(name)
        put!(@lock, lock_text(sql))
    end

    put!(@baseline, sql)
    put!(@ts, ts)
  end

  # The cutover's one step: lock the baseline every deployed database starts from.
  defp freeze!(sql, ts, opts) do
    check!(sql, ts, opts)
    put!(@lock, lock_text(sql))
  end

  defp locked do
    case File.read(Path.join(@root, @lock)) do
      {:ok, text} -> text |> String.split("\n") |> Enum.find(&(&1 =~ ~r/^[0-9a-f]{64}$/))
      {:error, _} -> nil
    end
  end

  defp lock_text(sql),
    do: "# The deployed baseline's SHA-256; see mix help hireme.schema (--freeze).\n#{sha(sql)}\n"

  defp sha(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp lock_problem do
    case {locked(), File.read(Path.join(@root, @baseline))} do
      {nil, _} ->
        nil

      {hash, {:ok, sql}} ->
        if sha(sql) != hash, do: "#{@baseline} is not the baseline #{@lock} names"

      {_, {:error, _}} ->
        nil
    end
  end

  defp check!(sql, ts, opts) do
    problems =
      [
        differs(@baseline, sql),
        differs(@ts, ts),
        canonical_problem(),
        apply_problem(sql),
        lock_problem()
      ] ++ id_problems(ts, opts)

    case Enum.reject(problems, &is_nil/1) do
      [] ->
        Mix.shell().info("schema: #{@baseline} and #{@ts} match schema/hireme.schema")

      problems ->
        Mix.raise(
          "schema --check:\n  " <> Enum.join(problems, "\n  ") <> "\nrun `mix hireme.schema`"
        )
    end
  end

  defp differs(path, fresh) do
    case File.read(Path.join(@root, path)) do
      {:ok, ^fresh} -> nil
      {:ok, _} -> "#{path} differs from a fresh emit"
      {:error, _} -> "#{path} is missing"
    end
  end

  # The crate and Hireme.Schema read the file by the same rules; the
  # canonical dumps they hash must be the same bytes.
  defp canonical_problem do
    Enum.find_value([:wire, :full], fn scope ->
      rust = emit!(["canonical", Atom.to_string(scope)])

      if rust != Hireme.Schema.canonical(scope) do
        "the #{scope} canonical dump differs between native/schema and Hireme.Schema"
      end
    end)
  end

  defp apply_problem(sql) do
    with_db(fn db ->
      case Exqlite.Sqlite3.execute(db, sql) do
        :ok -> nil
        {:error, reason} -> "#{@baseline} does not apply to an empty database: #{inspect(reason)}"
      end
    end)
  end

  defp migration!(name) do
    unless name =~ ~r/^[a-z0-9_]+$/, do: Mix.raise("--migration takes a snake_case name")

    previous =
      case File.read(Path.join(@root, @baseline)) do
        {:ok, sql} -> sql
        {:error, _} -> Mix.raise("no #{@baseline} to diff against")
      end

    shape =
      with_db(fn db ->
        :ok = Exqlite.Sqlite3.execute(db, previous)
        shape(db)
      end)

    shape_file =
      Path.join(System.tmp_dir!(), "hireme-shape-#{System.unique_integer([:positive])}")

    File.write!(shape_file, shape)

    {out, status} =
      try do
        cargo(["diff", shape_file])
      after
        File.rm(shape_file)
      end

    case status do
      0 when out == "" ->
        Mix.raise(
          "the declaration adds no table, column, index or trigger to the previous baseline"
        )

      0 ->
        path = Path.join(@root, "priv/db/#{next_number()}_#{name}.sql")
        File.write!(path, "-- #{name}: generated by `mix hireme.schema --migration`.\n" <> out)
        Mix.shell().info("wrote #{Path.relative_to(path, @root)}")

      _ ->
        Mix.raise(
          "the declaration changes the database in a way no added step can; " <>
            "write priv/db/NNNN_<what>.sql by hand:\n" <> out
        )
    end
  end

  defp next_number do
    n =
      Path.join(@root, "priv/db/[0-9][0-9][0-9][0-9]_*.sql")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.basename() |> binary_part(0, 4) |> String.to_integer()))
      |> Enum.max(fn -> 0 end)

    String.pad_leading(Integer.to_string(n + 1), 4, "0")
  end

  defp shape(db) do
    cols =
      query(
        db,
        "SELECT m.name, p.name, p.type, p.\"notnull\", coalesce(p.dflt_value, '-') " <>
          "FROM sqlite_master m JOIN pragma_table_info(m.name) p " <>
          "WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.name != 'schema_files' " <>
          "ORDER BY m.name, p.cid"
      )

    indexes =
      query(
        db,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name"
      )

    triggers = query(db, "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
    tables = cols |> Enum.map(&hd/1) |> Enum.uniq()

    Enum.map_join(tables, "", &"table #{&1}\n") <>
      Enum.map_join(cols, "", fn [t, c, ty, nn, d] -> "col #{t} #{c} #{ty} #{nn} #{d}\n" end) <>
      Enum.map_join(indexes, "", fn [i] -> "index #{i}\n" end) <>
      Enum.map_join(triggers, "", fn [i] -> "trigger #{i}\n" end)
  end

  defp query(db, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)

    try do
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
      rows
    after
      Exqlite.Sqlite3.release(db, stmt)
    end
  end

  defp with_db(fun) do
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")

    try do
      fun.(db)
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  # ------------------------------------------------------------ id stability

  defp guard_ids!(ts, opts) do
    case id_problems(ts, opts) do
      [] ->
        :ok

      moved ->
        Mix.raise(Enum.join(moved, "\n") <> "\nappend new entries at the end, or pass --renumber")
    end
  end

  # An id a client already compiled against must not move: compare the
  # checked-in gen/schema.ts with the fresh one, name by name.
  defp id_problems(fresh, opts) do
    with false <- opts[:renumber] || false,
         {:ok, old} <- File.read(Path.join(@root, @ts)) do
      old_ids = ids(old)
      new_ids = ids(fresh)

      for {key, id} <- old_ids, (new = Map.get(new_ids, key)) != nil, new != id do
        "#{key} moved from id #{id} to #{new}"
      end
    else
      _ -> []
    end
  end

  defp ids(ts) do
    entries =
      for {block, kind} <- [{"TABLES", :table}, {"COMMANDS", :command}],
          line <- block_lines(ts, block),
          entry <- entry_ids(line, kind),
          into: %{},
          do: entry

    # A domain's bit is stored in every key's masks.
    domains =
      case Regex.run(~r/^export const DOMAIN = \{ (.*) \} as const;$/m, ts) do
        [_, body] ->
          for pair <- String.split(body, ", "),
              [name, bit] = String.split(pair, ": "),
              into: %{},
              do: {"domain #{name}", String.to_integer(bit)}

        _ ->
          %{}
      end

    Map.merge(entries, domains)
  end

  defp block_lines(ts, name) do
    ts
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "export const #{name}:")))
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != "};"))
  end

  defp entry_ids(line, kind) do
    case Regex.run(~r/^\s*"[^"]+":\s*(\{.*\}),$/, line) do
      [_, json] ->
        entry = Jason.decode!(json)

        case kind do
          :table ->
            [{"table #{entry["name"]}", entry["id"]}] ++
              Enum.map(entry["cols"], &{"column #{entry["name"]}.#{&1["name"]}", &1["id"]})

          :command ->
            [{"command #{entry["name"]}", entry["id"]}] ++
              Enum.map(entry["params"], &{"param #{entry["name"]}.#{&1["name"]}", &1["id"]})
        end

      _ ->
        []
    end
  end

  # ------------------------------------------------------------ the binary

  defp emit!(args) do
    case cargo(args) do
      {out, 0} -> out
      {out, _} -> Mix.raise("hireme-schema #{Enum.join(args, " ")}:\n" <> out)
    end
  end

  defp cargo(args) do
    System.cmd(
      "cargo",
      ~w(run --quiet --manifest-path native/Cargo.toml -p schema --bin hireme-schema --) ++
        ["--schema", Hireme.Schema.path()] ++ args,
      # Warnings and diagnostics go to the terminal; stdout is the output.
      cd: @root
    )
  end

  defp put!(path, content) do
    full = Path.join(@root, path)
    File.mkdir_p!(Path.dirname(full))

    case File.read(full) do
      {:ok, ^content} ->
        :ok

      _ ->
        File.write!(full, content)
        Mix.shell().info("wrote #{path}")
    end
  end
end

defmodule Mix.Tasks.Hireme.Import do
  @shortdoc "Import a pack (JSON or markdown) into an account through its sequencer"
  @moduledoc """
      mix hireme.import --account ID PATH...

  Each pack is lowered to puts and run as the operator (`Hireme.Import`,
  whose moduledoc is the pack format). Prints what each group wrote and
  every refusal; exits non-zero when any row was refused.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, paths, invalid} = OptionParser.parse(argv, strict: [account: :integer])

    if invalid != [],
      do: Mix.raise("unknown arguments #{inspect(Enum.map(invalid, &elem(&1, 0)))}")

    account = opts[:account] || Mix.raise("--account ID is required")
    if paths == [], do: Mix.raise("name at least one pack")

    # An import needs the database and the sequencer, not the gate; and it
    # is for a node that is stopped (a running one imports over its RPC).
    Application.put_env(:hireme, :gate, false)
    Mix.Task.run("app.start")

    refused =
      Enum.reduce(paths, 0, fn path, refused ->
        case Hireme.Import.file(account, path) do
          {:ok, report} ->
            Mix.shell().info("#{path}: rev #{report.rev}")

            for g <- report.groups,
                do: Mix.shell().info("  #{g.table}: #{g.written} written, #{g.refused} refused")

            for r <- report.refusals,
                do:
                  Mix.shell().error(
                    "  #{r.table} row #{inspect(r.row)}: #{r.code} #{inspect(r.data)}"
                  )

            refused + length(report.refusals)

          {:error, reason} ->
            Mix.shell().error("#{path}: #{inspect(reason)}")
            refused + 1
        end
      end)

    if refused > 0, do: exit({:shutdown, 1})
  end
end
