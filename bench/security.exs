# Run through the immutable production release with a copied synthetic BENCH_DIR.
# BENCH_PATCHES compiles only the module(s) under comparison before application startup.
defmodule HiremeBench.Security do
  alias Hireme.{Accounts, ApiKeys, Mfa, Repo, Security}

  def run do
    dir = Path.expand(System.fetch_env!("BENCH_DIR"))
    database = Application.fetch_env!(:hireme, Repo) |> Keyword.fetch!(:database) |> Path.expand()

    unless String.starts_with?(database, dir <> "/"),
      do: raise("database must be inside BENCH_DIR")

    Logger.configure(level: :warning)

    for path <- String.split(System.get_env("BENCH_PATCHES", ""), ":", trim: true) do
      Code.compile_file(path)
    end

    endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)
    Application.put_env(:hireme, HiremeWeb.Endpoint, Keyword.put(endpoint, :server, false))
    Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
    {:ok, _} = Application.ensure_all_started(:hireme)
    metadata = dir |> Path.join("testbed.json") |> File.read!() |> Jason.decode!()
    Repo.put_account(metadata["account_id"])
    account = Accounts.get(metadata["account_id"])
    {token, session} = Accounts.start_session(account)
    {:ok, %{secret: secret}} = ApiKeys.create("isolated security benchmark")
    {:ok, key} = ApiKeys.authenticate(secret, "setup")
    count = System.get_env("BENCH_N", "100000") |> String.to_integer()
    true = count > 0

    # Refresh hot timestamps outside timed intervals, even if a scenario runs over a minute.
    refresh_session = fn i ->
      if rem(i, 2000) == 0, do: refresh(session, :last_seen_at)
      token
    end

    measure(
      "Domain/Accounts",
      "session_authenticate_hot",
      count,
      refresh_session,
      &Accounts.session/1,
      fn result ->
        case result do
          {%{id: id}, %{id: owner}} when id == session.id and owner == account.id -> :ok
          _ -> raise("session authentication failed")
        end
      end
    )

    # Every attempt gets a distinct synthetic peer prepared outside timing. A benchmark
    # must measure successful authentication, never Hammer's twenty-attempt rejection.
    measure(
      "Domain/ApiKeys",
      "authenticate_hot",
      count,
      fn i ->
        if rem(i, 2000) == 0, do: refresh(key, :last_used_at)
        "bench-auth-#{i}"
      end,
      fn peer -> ApiKeys.authenticate(secret, peer) end,
      fn result ->
        case result do
          {:ok, %{id: id, account_id: owner}} when id == key.id and owner == account.id -> :ok
          _ -> raise("API key authentication failed or was throttled")
        end
      end
    )

    measure(
      "Domain/ApiKeys",
      "usable",
      count,
      fn _ -> nil end,
      fn _ -> ApiKeys.usable?(key.key_id, account.id) end,
      &expect_true/1
    )

    # Separate scoped accounts keep each factor cardinality fixed and independent.
    for factor_count <- [0, 1, 10] do
      factor_account = Accounts.create!(%{name: "MFA benchmark #{factor_count}"})
      Repo.put_account(factor_account.id)

      if factor_count > 0 do
        for i <- 1..factor_count do
          %Hireme.Mfa.Method{}
          |> Hireme.Mfa.Method.changeset(%{
            account_id: factor_account.id,
            kind: :totp,
            name: "Synthetic factor #{i}",
            totp_secret: Security.seal(NimbleTOTP.secret(), "hireme mfa totp"),
            verified_at: now()
          })
          |> Repo.insert!()
        end
      end

      expected = factor_count > 0

      measure(
        "Domain/Mfa",
        "enrolled_#{factor_count}_factors",
        count,
        fn _ -> nil end,
        fn _ -> Mfa.enrolled?() end,
        fn result ->
          unless result == expected, do: raise("wrong scoped enrollment result")
        end
      )
    end

    for length <- [12, 43] do
      measure(
        "Domain/Security",
        "base62_#{length}",
        count,
        fn _ -> length end,
        &Security.base62/1,
        fn result ->
          unless byte_size(result) == length and result =~ ~r/\A[0-9A-Za-z]+\z/,
            do: raise("invalid base62 key material")
        end
      )
    end
  end

  defp refresh(row, field) do
    row |> Ecto.Changeset.change([{field, now()}]) |> Repo.update!(skip_account: true)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp expect_true(true), do: :ok
  defp expect_true(_), do: raise("live key unusable")

  defp measure(page, interaction, count, prepare, operation, validate) do
    only = System.get_env("BENCH_ONLY", "")

    if only == "" or String.contains?(page <> "/" <> interaction, only) do
      for i <- -200..-1, do: i |> prepare.() |> operation.() |> validate.()
      :erlang.garbage_collect()

      samples =
        for i <- 0..(count - 1) do
          arg = prepare.(i)
          started = System.monotonic_time()
          result = operation.(arg)
          elapsed = System.monotonic_time() - started
          validate.(result)
          System.convert_time_unit(elapsed, :native, :nanosecond) / 1_000_000
        end

      arg = prepare.(count)
      handler = {__MODULE__, make_ref()}
      Process.put(:security_bench_queries, 0)
      :ok = :telemetry.attach(handler, [:hireme, :repo, :query], &__MODULE__.query/4, self())

      queries =
        try do
          operation.(arg) |> validate.()
          Process.get(:security_bench_queries)
        after
          :telemetry.detach(handler)
          Process.delete(:security_bench_queries)
        end

      sorted = Enum.sort(samples)
      percentile = fn p -> Enum.at(sorted, max(0, ceil(count * p) - 1)) end
      mean = Enum.sum(samples) / count

      row = %{
        page: page,
        interaction: interaction,
        rev: System.fetch_env!("BENCH_REV"),
        n: count,
        mean: mean,
        p0_1: percentile.(0.001),
        p1: percentile.(0.01),
        p50: percentile.(0.5),
        p99: percentile.(0.99),
        p99_9: percentile.(0.999),
        samples: samples,
        queries: queries,
        ops_per_second: 1000 / mean,
        layer: "domain",
        schedulers: :erlang.system_info(:schedulers_online)
      }

      File.write!(System.fetch_env!("BENCH_OUTPUT"), Jason.encode!(row) <> "\n", [:append])
      IO.puts(Jason.encode!(Map.delete(row, :samples)))
    end
  end

  def query(_event, _measurements, _metadata, owner) do
    if self() == owner,
      do: Process.put(:security_bench_queries, Process.get(:security_bench_queries, 0) + 1)
  end
end

HiremeBench.Security.run()
