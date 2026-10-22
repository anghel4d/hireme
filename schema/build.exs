# The declaration's cross-language outputs, generated at every build and
# never checked in: `mix compile` runs this compiler before Elixir's
# (mix.exs: `compilers: [:schema | Mix.compilers()]`), so `Hireme.Schema`
# compiles from a fresh priv/schema.json, the release ships a fresh
# priv/db/baseline.sql and the bundle reads a fresh assets/js/gen/schema.ts,
# all three from schema/hireme.schema alone. mix.exs loads this file before
# the project compiles, so it uses nothing of lib/; `mix hireme.schema`
# (the migration, freeze and check workflows) builds on it.
defmodule Mix.Tasks.Compile.Schema do
  @moduledoc false
  use Mix.Task.Compiler

  @root Path.expand("..", __DIR__)
  @schema "schema/hireme.schema"
  @lock "priv/db/baseline.lock"
  @outputs [sql: "priv/db/baseline.sql", ts: "assets/js/gen/schema.ts", json: "priv/schema.json"]

  def schema, do: @schema
  def lock, do: @lock
  def outputs, do: @outputs
  def path(rel), do: Path.join(@root, rel)

  @impl Mix.Task.Compiler
  def run(_args) do
    stamp = hd(manifests())
    now = fingerprint()

    if File.read(stamp) == {:ok, now} and Enum.all?(@outputs, &File.exists?(path(elem(&1, 1)))) do
      {:noop, []}
    else
      written = generate!()
      File.mkdir_p!(Path.dirname(stamp))
      File.write!(stamp, now)
      {if(written == [], do: :noop, else: :ok), []}
    end
  end

  @impl Mix.Task.Compiler
  def manifests, do: [Path.join(Mix.Project.manifest_path(), "compile.schema")]

  @impl Mix.Task.Compiler
  def clean, do: Enum.each(@outputs, &File.rm(path(elem(&1, 1))))

  # The declaration and the emitters: when neither moved, the outputs stand.
  defp fingerprint do
    emitters = ~w(native/schema/src/**/*.rs native/schema/build.rs native/schema/Cargo.toml)
    sources = [path(@schema) | Enum.flat_map(emitters, &Path.wildcard(path(&1)))]
    :crypto.hash(:sha256, Enum.map(sources, &File.read!/1)) |> Base.encode16(case: :lower)
  end

  @doc "Emits the outputs, checks the baseline applies, and writes what changed: the paths written."
  def generate! do
    emitted = emit_all!()

    if problem = apply_problem(emitted[:sql]), do: Mix.raise(problem)

    # A frozen baseline that moved is shipped by `--migration`; until then
    # the build goes on, and `mix hireme.schema --check` (the tests, the
    # release) refuses it.
    if problem = lock_problem(emitted[:sql]),
      do:
        Mix.shell().error("#{problem}: run `mix hireme.schema --migration NAME` before shipping")

    for {kind, rel} <- @outputs, put!(rel, emitted[kind]), do: rel
  end

  def emit_all!, do: Map.new(@outputs, fn {kind, _} -> {kind, emit!([Atom.to_string(kind)])} end)

  @doc """
  `hireme-schema` on the declaration (`schema:` another path): the prebuilt
  binary `HIREME_SCHEMA_BIN` names (a release build), else cargo's.
  """
  def emit!(args, opts \\ []) do
    case run_emitter(args, opts) do
      {out, 0} -> out
      {out, _} -> Mix.raise("hireme-schema #{Enum.join(args, " ")}:\n" <> out)
    end
  end

  @doc "`hireme-schema` with `args`: its output and exit status."
  def run_emitter(args, opts \\ []) do
    args = ["--schema", Keyword.get(opts, :schema, path(@schema)) | args]

    case System.get_env("HIREME_SCHEMA_BIN") do
      nil ->
        System.cmd(
          "cargo",
          ~w(run --quiet --manifest-path native/Cargo.toml -p schema --bin hireme-schema --) ++
            args,
          cd: @root
        )

      bin ->
        System.cmd(bin, args, cd: @root)
    end
  end

  def apply_problem(sql) do
    with_db(fn db ->
      case Exqlite.Sqlite3.execute(db, sql) do
        :ok -> nil
        {:error, reason} -> "the baseline does not apply to an empty database: #{inspect(reason)}"
      end
    end)
  end

  @doc "Nil, or why `sql` is not the frozen baseline `priv/db/baseline.lock` names."
  def lock_problem(sql) do
    case locked() do
      nil -> nil
      hash -> if sha(sql) == hash, do: nil, else: "the baseline is not the one #{@lock} names"
    end
  end

  @doc "The frozen baseline's SHA-256, or nil before the freeze. A lock naming no digest fails closed."
  def locked do
    case File.read(path(@lock)) do
      {:ok, text} ->
        case Regex.run(~r/^([0-9a-f]{64})\r?$/m, text) do
          [_, hash] -> hash
          nil -> Mix.raise("#{@lock} names no SHA-256 (a line of 64 lowercase hex digits)")
        end

      {:error, _} ->
        nil
    end
  end

  def lock_text(sql),
    do: "# The deployed baseline's SHA-256; see mix help hireme.schema (--freeze).\n#{sha(sql)}\n"

  def sha(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  def with_db(fun) do
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")

    try do
      fun.(db)
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  @doc "Writes `content` at `rel` unless it is there already; whether it wrote."
  def put!(rel, content) do
    full = path(rel)
    File.mkdir_p!(Path.dirname(full))

    case File.read(full) do
      {:ok, ^content} ->
        false

      _ ->
        File.write!(full, content)
        Mix.shell().info("wrote #{rel}")
        true
    end
  end
end
