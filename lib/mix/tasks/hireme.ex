defmodule Mix.Tasks.Hireme.Schema do
  @shortdoc "Emit the database baseline and the TypeScript types from schema/hireme.schema"
  @moduledoc """
  The cross-language outputs of `schema/hireme.schema`, emitted by
  `native/schema`'s `hireme-schema` binary:

    * `priv/db/baseline.sql`: the whole declaration on an empty database
    * `assets/js/gen/schema.ts`: ids, enums, the catalog and row interfaces
    * `priv/schema.json`: the resolved model `Hireme.Schema` compiles from

  Options:

    * `--check`: write nothing; fail when a checked-in output differs from
      a fresh emit, when the baseline does not apply to an empty database, or when an
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

  A step written by hand that rebuilds a table (the only way SQLite changes
  a column's type, nullability or ON DELETE) runs between
  `PRAGMA legacy_alter_table = ON` and `OFF`: the ref triggers of other
  tables name the table being renamed. It also carries the table's
  `sqlite_sequence` row across the rebuild, or ids are reused:

      CREATE TEMP TABLE keep_seq AS SELECT seq FROM sqlite_sequence WHERE name = '<t>';
      -- ... the rebuild: CREATE the new table, copy, DROP, RENAME ...
      INSERT INTO sqlite_sequence (name, seq)
        SELECT '<t>', seq FROM keep_seq
        WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = '<t>');
      UPDATE sqlite_sequence SET seq = (SELECT seq FROM keep_seq)
        WHERE name = '<t>' AND seq < (SELECT seq FROM keep_seq);
      DROP TABLE keep_seq;

  A database is built from the baseline when empty, and from the `NNNN`
  files it has not applied otherwise (`Hireme.Release`), so the baseline is
  always the whole declaration and each `NNNN` file is one step of it.
  """

  use Mix.Task

  @root Path.expand("../../..", __DIR__)
  @baseline "priv/db/baseline.sql"
  @lock "priv/db/baseline.lock"
  @ts "assets/js/gen/schema.ts"
  @json "priv/schema.json"
  @schema "schema/hireme.schema"

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

    # The emits need no compiled app, and the app compiles from the json.
    sql = emit!(["sql"])
    ts = emit!(["ts"])
    json = emit!(["json"])

    cond do
      opts[:freeze] -> freeze!(sql, ts, json, opts)
      opts[:check] -> check!(sql, ts, json, opts)
      true -> write!(sql, ts, json, opts)
    end
  end

  defp write!(sql, ts, json, opts) do
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
    put!(@json, json)
  end

  # The cutover's one step: lock the baseline every deployed database starts from.
  defp freeze!(sql, ts, json, opts) do
    check!(sql, ts, json, opts)
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

  defp check!(sql, ts, json, opts) do
    problems =
      [
        differs(@baseline, sql),
        differs(@ts, ts),
        differs(@json, json),
        apply_problem(sql),
        lock_problem()
      ] ++
        id_problems(ts, opts)

    case Enum.reject(problems, &is_nil/1) do
      [] ->
        Mix.shell().info("schema: #{@baseline}, #{@ts} and #{@json} match #{@schema}")

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

    written = Path.wildcard(Path.join(@root, "priv/db/[0-9][0-9][0-9][0-9]_#{name}.sql"))

    # A step written by hand (a destructive change) is taken once it brings
    # the previous baseline exactly to the declaration.
    steps =
      case written do
        [path] -> [File.read!(path)]
        [] -> []
        _ -> Mix.raise("more than one priv/db/NNNN_#{name}.sql")
      end

    shape =
      with_db(fn db ->
        :ok = Exqlite.Sqlite3.execute(db, previous)

        for step <- steps do
          case Exqlite.Sqlite3.execute(db, step) do
            :ok ->
              :ok

            {:error, e} ->
              Mix.raise("#{hd(written)} does not apply to the previous baseline: #{inspect(e)}")
          end
        end

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

    case {status, written} do
      {0, [path]} when out == "" ->
        Mix.shell().info(
          "#{Path.relative_to(path, @root)} brings the previous baseline to the declaration"
        )

      {_, [path]} ->
        Mix.raise(
          "#{Path.relative_to(path, @root)} does not bring the previous baseline to the declaration:\n" <>
            out
        )

      {0, []} when out == "" ->
        Mix.raise(
          "the declaration adds no table, column, index or trigger to the previous baseline, " <>
            "and changes none: a plain mix hireme.schema ships it"
        )

      {0, []} ->
        path = Path.join(@root, "priv/db/#{next_number()}_#{name}.sql")
        File.write!(path, "-- #{name}: generated by `mix hireme.schema --migration`.\n" <> out)
        Mix.shell().info("wrote #{Path.relative_to(path, @root)}")

      {_, []} ->
        Mix.raise(
          "the declaration changes the database in a way no added step can; " <>
            "write priv/db/#{next_number()}_#{name}.sql by hand and run --migration #{name} again " <>
            "(a table rebuild runs between PRAGMA legacy_alter_table = ON and OFF):\n" <> out
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

    # Definitions too, so a changed index, trigger or ON DELETE is a change.
    sqls =
      query(
        db,
        "SELECT name, sql FROM sqlite_master WHERE type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY name"
      )

    fks =
      query(
        db,
        "SELECT m.name, f.\"from\", f.on_delete FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) f " <>
          "WHERE m.type = 'table' ORDER BY m.name, f.\"from\""
      )

    tables = cols |> Enum.map(&hd/1) |> Enum.uniq()

    Enum.map_join(tables, "", &"table #{&1}\n") <>
      Enum.map_join(cols, "", fn [t, c, ty, nn, d] -> "col #{t} #{c} #{ty} #{nn} #{d}\n" end) <>
      Enum.map_join(indexes, "", fn [i] -> "index #{i}\n" end) <>
      Enum.map_join(triggers, "", fn [i] -> "trigger #{i}\n" end) <>
      Enum.map_join(sqls, "", fn [n, sql] -> "sql #{n} #{String.replace(sql, ~r/\s+/, " ")}\n" end) <>
      Enum.map_join(fks, "", fn [t, c, action] -> "fk #{t} #{c} #{action}\n" end)
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
      for {block, kind} <- [{"const PACKED:", :table}, {"export const COMMANDS:", :command}],
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
    |> Enum.drop_while(&(not String.starts_with?(&1, name)))
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != "};"))
  end

  defp entry_ids(line, kind) do
    case Regex.run(~r/^\s*"[^"]+":\s*(\{.*\}),$/, line) do
      [_, json] ->
        entry = Jason.decode!(json)

        case kind do
          :table ->
            # A column is packed: [name, id, ...].
            [{"table #{entry["name"]}", entry["id"]}] ++
              Enum.map(entry["cols"], fn [name, id | _] ->
                {"column #{entry["name"]}.#{name}", id}
              end)

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
        ["--schema", Path.join(@root, @schema)] ++ args,
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

defmodule Mix.Tasks.Hireme.Bundle do
  @shortdoc "Bundles the browser's scripts and stylesheet with Bun"
  @moduledoc """
  The browser's bundles, into priv/static/assets: `app` with its stylesheet,
  `early` (inlined in <head> and allowed by its hash in the CSP, so always
  minified), `warm` (the worker it starts) and `auth`, the factor page's passkey script. Arguments go to
  every `bun build`: `--minify` for a release, `--sourcemap=inline --watch`
  for the dev watchers. Bun is MIX_BUN_PATH, else `bun` on PATH.
  """
  use Mix.Task

  @bundles [
    # Each lens but the desk is a chunk app.ts imports on demand, named by its content.
    ~w(js/app.ts css/app.css --format=esm --external=/wasm/* --splitting --chunk-naming=[name]-[hash].[ext]),
    ~w(js/early.ts --format=iife --minify),
    # The worker early.ts warms the kernel in (see warm.ts).
    ~w(js/warm.ts --format=iife --minify),
    ~w(js/auth/factor.ts --format=esm)
  ]

  @impl true
  def run(args) do
    bun =
      System.get_env("MIX_BUN_PATH") || System.find_executable("bun") ||
        Mix.raise("bun is not on PATH")

    out = Path.expand("priv/static/assets")

    @bundles
    |> Enum.map(fn entries ->
      Task.async(fn ->
        System.cmd(
          bun,
          ["build" | entries] ++
            ~w(--target=browser --entry-naming=[name].[ext] --outdir=#{out}) ++ args,
          cd: "assets",
          into: IO.stream(),
          stderr_to_stdout: true
        )
      end)
    end)
    |> Task.await_many(:infinity)
    |> Enum.each(fn {_, status} ->
      status == 0 || Mix.raise("bun build failed (exit #{status})")
    end)
  end
end

defmodule Mix.Tasks.Hireme.Digest do
  @shortdoc "Names each static file by its content and gzips it, for a release"
  @moduledoc """
  Every file under priv/static's `assets` and `wasm` gets a copy named by
  its content (`app-<md5>.js`), and both are gzipped beside it: Plug.Static
  serves the `.gz` to a browser that takes it (kernel.wasm to about a
  third). priv/static/cache_manifest.json maps each name to its digested
  one for `HiremeWeb.Endpoint.static_path/1`. No clock goes in, so the
  output is a function of the files.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    root = "priv/static"

    manifest =
      for dir <- HiremeWeb.static_paths(),
          file <- Path.wildcard(Path.join([root, dir, "**", "*"])),
          File.regular?(file),
          not String.ends_with?(file, ".gz"),
          not Regex.match?(~r/-[0-9a-f]{32}\.[^\/]+$/, file),
          into: %{} do
        bin = File.read!(file)
        hash = Base.encode16(:crypto.hash(:md5, bin), case: :lower)
        digested = Path.rootname(file) <> "-" <> hash <> Path.extname(file)
        File.write!(digested, bin)
        for f <- [file, digested], do: File.write!(f <> ".gz", :zlib.gzip(bin))
        {Path.relative_to(file, root), Path.relative_to(digested, root)}
      end

    File.write!(Path.join(root, "cache_manifest.json"), JSON.encode!(manifest))
  end
end
