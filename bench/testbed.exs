# Run with `bin/hireme eval 'Code.eval_file("bench/testbed.exs")'`.
# All state and credentials are synthetic and confined to BENCH_DIR.
defmodule HiremeBench.Testbed do
  import Ecto.Query

  def start do
    dir = System.fetch_env!("BENCH_DIR") |> Path.expand()

    database =
      Application.fetch_env!(:hireme, Hireme.Repo) |> Keyword.fetch!(:database) |> Path.expand()

    unless String.starts_with?(database, dir <> "/"),
      do: raise("database must be inside BENCH_DIR")

    File.mkdir_p!(dir)
    Logger.configure(level: :warning)
    Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
    endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)

    Application.put_env(
      :hireme,
      HiremeWeb.Endpoint,
      Keyword.merge(endpoint,
        server: true,
        url: [
          host: "localhost",
          scheme: "http",
          port: String.to_integer(System.fetch_env!("PORT"))
        ],
        check_origin: ["//localhost", "//127.0.0.1"]
      )
    )

    Hireme.Release.migrate()
    {:ok, _} = Application.ensure_all_started(:hireme)
    account = Hireme.Accounts.use_default!()
    profiles = Hireme.Corpus.list_profiles()
    profiles = if profiles == [], do: seed(), else: profiles

    {token, session} =
      Hireme.Accounts.start_session(account, %{user_agent: "isolated-performance-testbed"})

    secret = Application.fetch_env!(:hireme, :secret_key_base)

    session_opts =
      Plug.Session.init(
        store: :cookie,
        key: "__Host-hireme",
        signing_salt: "hireme-session-sign",
        encryption_salt: "hireme-session-seal",
        same_site: "Lax",
        secure: true,
        http_only: true,
        max_age: 86400
      )

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, secret)
      |> Plug.Session.call(session_opts)
      |> Plug.Conn.fetch_session()
      |> HiremeWeb.Auth.sign_in(token)
      |> Plug.Conn.send_resp(200, "")

    cookie = conn.resp_cookies["__Host-hireme"].value
    jobs = Hireme.Repo.all(from j in Hireme.Desk.Job, order_by: j.id, select: j.id)

    metadata = %{
      account_id: account.id,
      profile_ids: Enum.map(profiles, & &1.id),
      job_ids: jobs,
      session_id: session.id,
      session_token: token,
      cookie: cookie,
      port: System.fetch_env!("PORT"),
      job_count: length(jobs)
    }

    File.write!(Path.join(dir, "testbed.json"), Jason.encode!(metadata))
    File.chmod!(Path.join(dir, "testbed.json"), 0o600)
    IO.puts("HIREME_BENCH_READY jobs=#{length(jobs)} port=#{System.fetch_env!("PORT")}")
    Process.sleep(:infinity)
  end

  defp seed do
    profiles =
      for p <- 1..3 do
        profile =
          Hireme.Corpus.create_profile!(%{
            slug: "bench-#{p}",
            name: "Benchmark Candidate #{p}",
            headline: "Systems Engineer",
            summary: "Synthetic performance fixture, no personal data."
          })

        for i <- 1..30 do
          Hireme.Corpus.create_item!(%{
            profile_id: profile.id,
            kind: :experience,
            key: "bench-#{p}-#{i}",
            title: "Project #{i}",
            body:
              "Built distributed systems with Elixir Rust TypeScript PostgreSQL SQLite and WebAssembly. " <>
                String.duplicate(
                  "Measured latency and throughput under production workloads. ",
                  4
                ),
            position: i,
            keywords: ["Elixir", "Rust", "TypeScript"]
          })
        end

        profile
      end

    batches =
      for i <- 1..10 do
        %Hireme.Desk.Batch{}
        |> Hireme.Desk.Batch.changeset(%{code: "BENCH-#{i}", ordinal: i, target_size: 100})
        |> Hireme.Repo.insert!()
      end

    count = System.get_env("BENCH_JOBS", "1000") |> String.to_integer()

    for i <- 1..count do
      profile = Enum.at(profiles, rem(i, 3))

      Hireme.Desk.create_job!(%{
        profile_id: profile.id,
        batch_id: Enum.at(batches, rem(i, 10)).id,
        company: "Company #{rem(i, 100)}",
        role: "Systems Engineer #{i}",
        canonical_url: "https://jobs.example.test/#{i}",
        location: "Remote",
        department: "Engineering #{rem(i, 5)}",
        score_100: rem(i, 101),
        stage: if(i <= 100, do: :submitted, else: :discovered),
        stage_on: Date.add(Date.utc_today(), -rem(i, 70)),
        listing:
          String.duplicate(
            "Elixir Rust TypeScript distributed systems latency SQLite WebAssembly ",
            20
          )
      })
    end

    for i <- 1..2000 do
      {:ok, _} =
        Hireme.Gym.log(%{
          title: "Problem #{rem(i, 100)}",
          slug: "problem-#{rem(i, 100)}",
          topic: :dp,
          difficulty: :medium,
          minutes: 20,
          done_on: Date.add(Date.utc_today(), -rem(i, 365))
        })

      {:ok, _} =
        Hireme.Net.log(%{
          kind: if(rem(i, 5) == 0, do: :draft, else: :artifact),
          title: "Artifact #{i}",
          body: "Synthetic benchmark entry",
          shipped_on: if(rem(i, 5) == 0, do: nil, else: Date.add(Date.utc_today(), -rem(i, 365)))
        })
    end

    profiles
  end
end

HiremeBench.Testbed.start()
