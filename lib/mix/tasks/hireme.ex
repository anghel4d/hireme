defmodule Mix.Tasks.Hireme.Schema do
  @shortdoc "Check, migrate or freeze the outputs of schema/hireme.schema"
  @moduledoc """
  The cross-language outputs of `schema/hireme.schema` are generated at
  every build by the schema compiler (`schema/build.exs`, run before
  Elixir's), never checked in:

    * `priv/db/baseline.sql`: the whole declaration on an empty database
    * `assets/js/gen/schema.ts`: ids, enums, the catalog and row interfaces
    * `priv/schema.json`: the resolved model `Hireme.Schema` compiles from

  A plain run emits them now and refuses an id move (an id a client
  compiled against is read from the last committed declaration). Options:

    * `--check`: write nothing; fail when the baseline does not apply to an
      empty database, when a frozen baseline is not the one
      `priv/db/baseline.lock` names, or when an existing table, column,
      command or param moved its id since the last commit
    * `--migration NAME`: also write `priv/db/NNNN_NAME.sql`, the
      declaration minus the frozen baseline (emitted from the committed
      declaration the lock names; additive only, a destructive change is
      refused and written by hand as `NNNN_drop_<what>.sql`), and lock the
      new baseline
    * `--renumber`: allow existing ids to move: before the freeze, or with
      `--migration` after it (wire_hash moves, so every client refreshes;
      no stored row holds a column id)
    * `--freeze`: write `priv/db/baseline.lock`, the SHA-256 of the
      baseline. The cutover runs it once: from then on deployed databases
      hold that baseline, so a build whose baseline differs warns and
      `--check` (the tests, the release) fails, until `--migration NAME`
      ships the change.

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

  alias Hireme.Release
  alias Mix.Tasks.Compile.Schema, as: Build

  @schema Build.schema()
  @lock Build.lock()

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

    sql = Build.emit!(["sql"])
    json = Build.emit!(["json"])

    if opts[:check] || opts[:freeze],
      do: check!(sql, json, opts),
      else: write!(sql, json, opts)

    # The cutover's one step: lock the baseline every deployed database starts from.
    if opts[:freeze], do: Build.put!(@lock, Build.lock_text(sql))
  end

  defp write!(sql, json, opts) do
    # Ids are the wire's ABI: once a baseline is deployed they move only with
    # the migration that ships the change.
    if opts[:renumber] && Build.locked() && !opts[:migration],
      do: Mix.raise("ids may move once #{@lock} exists only with --migration NAME")

    case id_problems(json, opts) do
      [] ->
        :ok

      moved ->
        Mix.raise(Enum.join(moved, "\n") <> "\nappend new entries at the end, or pass --renumber")
    end

    locked = Build.locked()

    cond do
      name = opts[:migration] ->
        migration!(name)
        if locked, do: Build.put!(@lock, Build.lock_text(sql))

      problem = Build.lock_problem(sql) ->
        Mix.raise("#{problem}: deployed databases hold it; ship it as --migration NAME")

      true ->
        :ok
    end

    Build.generate!()
  end

  defp check!(sql, json, opts) do
    problems = [Build.apply_problem(sql), Build.lock_problem(sql) | id_problems(json, opts)]

    case Enum.reject(problems, &is_nil/1) do
      [] ->
        Mix.shell().info(
          "schema: the outputs of #{@schema} apply, match #{@lock} and keep every id"
        )

      problems ->
        Mix.raise("schema --check:\n  " <> Enum.join(problems, "\n  "))
    end
  end

  defp migration!(name) do
    unless name =~ ~r/^[a-z0-9_]+$/, do: Mix.raise("--migration takes a snake_case name")

    previous = previous_baseline!()
    written = Path.wildcard(Build.path("priv/db/[0-9][0-9][0-9][0-9]_#{name}.sql"))

    # A step written by hand (a destructive change) is taken once it brings
    # the previous baseline exactly to the declaration.
    steps =
      case written do
        [path] -> [File.read!(path)]
        [] -> []
        _ -> Mix.raise("more than one priv/db/NNNN_#{name}.sql")
      end

    shape =
      Build.with_db(fn db ->
        :ok = Exqlite.Sqlite3.execute(db, previous)

        for step <- steps,
            {:error, e} <- [Exqlite.Sqlite3.execute(db, step)],
            do: Mix.raise("#{hd(written)} does not apply to the previous baseline: #{inspect(e)}")

        shape(db)
      end)

    tmp = "hireme-shape-#{System.unique_integer([:positive])}"
    {out, status} = with_tmp(tmp, shape, &Build.run_emitter(["diff", &1]))

    case {status, written} do
      {0, [path]} when out == "" ->
        Mix.shell().info(
          "#{Path.relative_to(path, Build.path("."))} brings the previous baseline to the declaration"
        )

      {_, [path]} ->
        Mix.raise(
          "#{Path.relative_to(path, Build.path("."))} does not bring the previous baseline to the declaration:\n" <>
            out
        )

      {0, []} when out == "" ->
        Mix.raise(
          "the declaration adds no table, column, index or trigger to the previous baseline, " <>
            "and changes none: a plain mix hireme.schema ships it"
        )

      {0, []} ->
        rel = "priv/db/#{next_number()}_#{name}.sql"

        File.write!(
          Build.path(rel),
          "-- #{name}: generated by `mix hireme.schema --migration`.\n" <> out
        )

        Mix.shell().info("wrote #{rel}")

      {_, []} ->
        Mix.raise(
          "the declaration changes the database in a way no added step can; " <>
            "write priv/db/#{next_number()}_#{name}.sql by hand and run --migration #{name} again " <>
            "(a table rebuild runs between PRAGMA legacy_alter_table = ON and OFF):\n" <> out
        )
    end
  end

  # The baseline deployed databases hold: emitted from the committed
  # declaration the lock names, the newest of the last fifty that touched it.
  defp previous_baseline! do
    case Build.locked() do
      nil ->
        emit_at!("HEAD", "sql")

      hash ->
        git!(["log", "--format=%H", "-n", "50", "--", @schema])
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn rev ->
          sql = emit_at!(rev, "sql")
          if Build.sha(sql) == hash, do: sql
        end)
        |> Kernel.||(
          Mix.raise(
            "no committed #{@schema} in the last 50 revisions emits the baseline #{@lock} names"
          )
        )
    end
  end

  # An output emitted from the declaration as committed at `rev`.
  defp emit_at!(rev, kind) do
    name = "hireme-schema-#{System.unique_integer([:positive])}.schema"
    with_tmp(name, git!(["show", "#{rev}:#{@schema}"]), &Build.emit!([kind], schema: &1))
  end

  # `fun` on a file `name` in the temporary directory holding `content`, removed after.
  defp with_tmp(name, content, fun) do
    tmp = Path.join(System.tmp_dir!(), name)
    File.write!(tmp, content)

    try do
      fun.(tmp)
    after
      File.rm(tmp)
    end
  end

  defp git!(args) do
    case System.cmd("git", args, cd: Build.path("."), stderr_to_stdout: true) do
      {out, 0} -> out
      {out, _} -> Mix.raise("git #{Enum.join(args, " ")}:\n" <> out)
    end
  end

  defp next_number do
    n =
      Build.path("priv/db/[0-9][0-9][0-9][0-9]_*.sql")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.basename() |> binary_part(0, 4) |> String.to_integer()))
      |> Enum.max(fn -> 0 end)

    String.pad_leading(Integer.to_string(n + 1), 4, "0")
  end

  defp shape(db) do
    cols =
      Release.rows(
        db,
        "SELECT m.name, p.name, p.type, p.\"notnull\", coalesce(p.dflt_value, '-') " <>
          "FROM sqlite_master m JOIN pragma_table_info(m.name) p " <>
          "WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.name != 'schema_files' " <>
          "ORDER BY m.name, p.cid"
      )

    indexes =
      Release.rows(
        db,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name"
      )

    triggers =
      Release.rows(db, "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")

    # Definitions too, so a changed index, trigger or ON DELETE is a change.
    sqls =
      Release.rows(
        db,
        "SELECT name, sql FROM sqlite_master WHERE type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY name"
      )

    fks =
      Release.rows(
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

  # ------------------------------------------------------------ id stability

  # An id a client already compiled against must not move: the fresh model
  # against the one the last committed declaration emits. Without a
  # repository to ask (a release build) nothing is compared.
  defp id_problems(fresh, opts) do
    if opts[:renumber] || !git?() do
      []
    else
      new_ids = ids(fresh)

      for {key, id} <- ids(emit_at!("HEAD", "json")), (new = new_ids[key]) != nil, new != id do
        "#{key} moved from id #{id} to #{new}"
      end
    end
  end

  defp git?, do: System.find_executable("git") != nil and File.exists?(Build.path(".git"))

  # Every table, column, command and param by name with its id, and every
  # domain with its bit (stored in every key's masks).
  defp ids(json) do
    m = Jason.decode!(json)
    domains = for d <- m["domains"], do: {"domain #{d["name"]}", d["bit"]}
    tables = for t <- m["tables"], do: {"table #{t["name"]}", t["id"]}
    cols = for t <- m["tables"], c <- t["cols"], do: {"column #{t["name"]}.#{c["name"]}", c["id"]}
    commands = for c <- m["commands"], do: {"command #{c["name"]}", c["id"]}

    params =
      for c <- m["commands"], p <- c["params"], do: {"param #{c["name"]}.#{p["name"]}", p["id"]}

    Map.new(domains ++ tables ++ cols ++ commands ++ params)
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

    # An import is for a node that is stopped (a running one imports over its RPC).
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
  minified) and `auth`, the factor page's passkey script. Arguments go to
  every `bun build`: `--minify` for a release, `--sourcemap=inline --watch`
  for the dev watchers. Bun is MIX_BUN_PATH, else `bun` on PATH.
  """
  use Mix.Task

  @bundles [
    # One file: a chunk per lens was a request per lens on every load.
    ~w(js/app.ts css/app.css --format=esm --external=/wasm/*),
    ~w(js/early.ts --format=iife --minify),
    ~w(js/auth/factor.ts --format=esm)
  ]

  @impl true
  def run(args) do
    bun =
      System.get_env("MIX_BUN_PATH") || System.find_executable("bun") ||
        Mix.raise("bun is not on PATH")

    out = Path.expand("priv/static/assets")
    # A digest's gzipped copies would be served over these builds (Plug.Static prefers a .gz).
    for f <- Path.wildcard("priv/static/{assets,wasm}/*.gz"), do: File.rm!(f)

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
