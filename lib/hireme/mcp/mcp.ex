defmodule Hireme.Letterbox.Handle do
  @moduledoc """
  The agent's lease on one letterbox.

  `Hireme.Letterbox.lease/2` is the constructor. The process that
  receives the handle is the only producer. The letterbox process is the
  only consumer. `pair` is the CV for the one application this letterbox
  owns. A command has no application id, so the handle cannot be aimed
  at a different one. `token` is a reference made inside the consumer;
  the consumer accepts a command only from the producer pid with that
  token.
  """

  @enforce_keys [:id, :token, :pid, :pair]
  defstruct [:id, :token, :pid, :pair]

  @type t :: %__MODULE__{
          id: pos_integer(),
          token: reference(),
          pid: pid(),
          pair: Hireme.CvPair.t()
        }
end

defmodule Hireme.Letterbox do
  @moduledoc """
  One letterbox, one application, one producer, one consumer.

  An MCP connection leases a letterbox id. That lease is a `Handle.t()`
  and it is what opens the full-duplex socket. The handle closes over
  the CV pair for that application. Commands are literals (`:get`,
  `{:set_stage, stage}`, `{:tailor, item_id, attrs}`) with no target id.
  The consumer applies them to the pair in its state.

  A second connection cannot lease that letterbox. A second connection
  cannot lease another application that shares the employer's CV
  lineage. One producer process cannot hold two leases.
  """

  import Ecto.Query
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Job
  alias Hireme.Letterbox.Box
  alias Hireme.Letterbox.Handle
  alias Hireme.Letterbox.Record
  alias Hireme.Repo

  @registry __MODULE__.Registry

  @type command :: Hireme.Desk.command()
  @type reply :: Hireme.Desk.reply()

  @type entry :: %{
          id: pos_integer(),
          job_id: pos_integer(),
          company: String.t(),
          role: String.t(),
          stage: Hireme.Pipeline.stage(),
          batch: String.t() | nil,
          score_100: Hireme.LifeEv.score(),
          leased: boolean()
        }

  @spec open!(pos_integer()) :: Record.t()
  def open!(job_id) when is_integer(job_id) do
    %Record{} |> Record.changeset(%{job_app_id: job_id}) |> Repo.insert!()
  end

  @spec exists?(pos_integer()) :: boolean()
  def exists?(id) when is_integer(id), do: Repo.exists?(from r in Record, where: r.id == ^id)

  @spec for_job(pos_integer()) :: Record.t() | nil
  def for_job(job_id) when is_integer(job_id), do: Repo.get_by(Record, job_app_id: job_id)

  @spec lease(pos_integer(), pid()) :: {:ok, Handle.t()} | {:error, atom()}
  def lease(id, producer) when is_integer(id) and id > 0 and is_pid(producer) do
    with {:ok, pid} <- start_box(id) do
      allow_sandbox(producer, pid)
      GenServer.call(pid, {:lease, producer})
    end
  end

  @spec release(Handle.t()) :: :ok | {:error, :lease}
  def release(%Handle{pid: pid, token: token}) do
    GenServer.call(pid, {:release, token})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Run one command on the application this handle closes over. The
  reply is `Hireme.Desk.perform/2`'s, or `{:error, :lease}` when the
  caller is not the producer or the token is not this lease's.
  """
  @spec command(Handle.t(), command()) :: reply() | {:error, :lease}
  def command(%Handle{pid: pid, token: token}, command)
      when command in [:get, :open_generation] or
             (is_tuple(command) and
                elem(command, 0) in [:set_stage, :set_next, :set_score, :tailor]) do
    GenServer.call(pid, {:cmd, token, command})
  end

  @doc "A box exists only while a lease is held or being taken."
  @spec leased?(pos_integer()) :: boolean()
  def leased?(id) when is_integer(id), do: Registry.lookup(@registry, {:box, id}) != []

  @spec permit_job(pos_integer()) :: :ok | {:error, :leased}
  def permit_job(job_id) when is_integer(job_id) do
    case Registry.lookup(@registry, {:job, job_id}) do
      [{pid, _}] when pid != self() -> {:error, :leased}
      _ -> :ok
    end
  end

  @spec list() :: [entry()]
  def list do
    Record
    |> join(:inner, [r], j in Job, on: j.id == r.job_app_id)
    |> join(:left, [r, j], b in Batch, on: b.id == j.batch_id)
    |> order_by([r], r.id)
    |> select([r, j, b], %{
      id: r.id,
      job_id: j.id,
      company: j.company,
      role: j.role,
      stage: j.current_stage,
      batch: b.code,
      score_100: j.score_100
    })
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :leased, leased?(&1.id)))
  end

  defp start_box(id) do
    if exists?(id) do
      case DynamicSupervisor.start_child(__MODULE__.Supervisor, {Box, id}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, _pid}} -> {:error, :busy}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :letterbox}
    end
  end

  defp allow_sandbox(parent, child) do
    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, child)
    end
  end
end

defmodule Hireme.Mcp.Args do
  @moduledoc """
  Tool arguments off the wire, read once.

  Every reader returns `{:ok, value}` or `{:error, {:argument, name}}`.
  Nothing here raises on a bad frame.
  """

  alias Hireme.Pipeline

  @type problem :: {:argument, String.t()}

  @spec int(map(), String.t()) :: {:ok, integer()} | {:error, problem()}
  def int(args, name) do
    case Map.get(args, name) do
      n when is_integer(n) -> {:ok, n}
      s when is_binary(s) -> parse_int(s, name)
      _ -> {:error, {:argument, name}}
    end
  end

  @spec optional_int(map(), String.t()) :: {:ok, integer() | nil} | {:error, problem()}
  def optional_int(args, name) do
    case Map.get(args, name) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      _ -> int(args, name)
    end
  end

  @spec string(map(), String.t()) :: {:ok, String.t()}
  def string(args, name) do
    case Map.get(args, name) do
      s when is_binary(s) -> {:ok, s}
      _ -> {:ok, ""}
    end
  end

  @spec optional_string(map(), String.t()) :: String.t() | nil
  def optional_string(args, name) do
    case Map.get(args, name) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  @spec score(map(), String.t()) :: {:ok, Hireme.LifeEv.score()} | {:error, problem()}
  def score(args, name) do
    case int(args, name) do
      {:ok, n} when n in 0..100 -> {:ok, n}
      _ -> {:error, {:argument, name}}
    end
  end

  @spec optional_score(map(), String.t(), Hireme.LifeEv.score()) ::
          {:ok, Hireme.LifeEv.score()} | {:error, problem()}
  def optional_score(args, name, default) do
    case optional_int(args, name) do
      {:ok, nil} -> {:ok, default}
      {:ok, n} when n in 0..100 -> {:ok, n}
      _ -> {:error, {:argument, name}}
    end
  end

  @spec stage(map(), String.t()) :: {:ok, Pipeline.stage()} | {:error, problem()}
  def stage(args, name) do
    case Pipeline.parse(Map.get(args, name)) do
      {:ok, stage} -> {:ok, stage}
      :error -> {:error, {:argument, name}}
    end
  end

  defp parse_int(s, name) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:argument, name}}
    end
  end
end

defmodule Hireme.Mcp do
  @moduledoc """
  Tool calls for a connected agent.

  The directory socket at `/mcp/websocket` lists, ranks, and reports;
  it cannot write an application. A letterbox socket at
  `/mcp/letterbox/:letterbox_id/websocket` is the full-duplex lease. Its
  handle reads and writes one application. The command carried to the
  consumer has no application id. A job id, a variant id, or a
  letterbox id in the arguments is checked against the handle and
  otherwise ignored.
  """

  alias Hireme.CvPair
  alias Hireme.Desk
  alias Hireme.Desk.Filters
  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle
  alias Hireme.LifeEv
  alias Hireme.Mcp.Args
  alias Hireme.Net
  alias Hireme.Pipeline

  @type frame :: map()

  @score %{"type" => "integer", "minimum" => 0, "maximum" => 100}
  @string %{"type" => "string"}
  @integer %{"type" => "integer"}
  @hold "FIRE HOLD — does not submit."

  @spec directory(frame()) :: map()
  def directory(frame), do: dispatch(frame, directory_tools(), &directory_call/2)

  @spec handle(Handle.t(), frame()) :: map()
  def handle(%Handle{} = handle, frame),
    do: dispatch(frame, leased_tools(), &call(handle, &1, &2))

  # One JSON-RPC frame in, one object out, for either socket.
  defp dispatch(%{"id" => id, "method" => "tools/list"}, tools, _call),
    do: %{id: id, result: %{tools: tools}}

  defp dispatch(%{"id" => id, "method" => "tools/call", "params" => params}, _tools, call) do
    case call.(params["name"], params["arguments"] || %{}) do
      {:ok, result} -> %{id: id, result: result}
      {:error, reason} -> %{id: id, error: %{code: -32000, message: error_message(reason)}}
    end
  end

  defp dispatch(%{"id" => id}, _tools, _call),
    do: %{id: id, error: %{code: -32601, message: "unknown method"}}

  defp dispatch(_frame, _tools, _call), do: %{error: %{code: -32600, message: "invalid request"}}

  defp directory_call("list_letterboxes", args) do
    with {:ok, min} <- Args.optional_score(args, "min_score", 0) do
      rows =
        Letterbox.list()
        |> Enum.filter(&(&1.score_100 >= min))
        |> Enum.sort_by(&(-&1.score_100))
        |> Enum.map(&letterbox_row/1)

      {:ok, %{"letterboxes" => rows}}
    end
  end

  defp directory_call("list_batches", _args), do: {:ok, %{"batches" => batch_rows()}}

  # Cards come back in board order: score_100 high to low, then batch.
  defp directory_call("list_applications", args) do
    {:ok, %{"applications" => application_rows(list_filters(args))}}
  end

  # The keepers an agent would draft first. This ranks; it does not submit.
  defp directory_call("recommend_applications", args) do
    with {:ok, min} <- Args.optional_score(args, "min_score", 90),
         {:ok, limit} <- Args.optional_int(args, "limit") do
      limit = if is_integer(limit) and limit > 0, do: min(limit, 100), else: 25
      filters = Filters.merge(list_filters(args), %{min_score: min, status: :open})

      apps =
        filters
        |> application_rows()
        |> Enum.reject(&(&1["heat_state"] == "blocked"))
        |> Enum.take(limit)

      {:ok,
       %{
         "applications" => apps,
         "min_score" => min,
         "fire" => fire(),
         "note" =>
           "FIRE HOLD. Ranked by score_100 then cooler heat. Blocked (over cap) omitted. Does not submit."
       }}
    end
  end

  defp directory_call("score_distribution", args) do
    chart = LifeEv.chart(Desk.list_cards(list_filters(args)))

    {:ok,
     %{
       "n" => chart.n,
       "mean" => chart.mean,
       "max" => chart.max,
       "min" => chart.min,
       "bands" =>
         Enum.map(chart.bands, fn row ->
           %{
             "band" => LifeEv.name(row.key),
             "label" => row.label,
             "min" => row.min,
             "max" => row.max,
             "count" => row.count,
             "share" => row.share
           }
         end),
       "bins" => Enum.map(chart.bins, &%{"lo" => &1.lo, "hi" => &1.hi, "count" => &1.count})
     }}
  end

  defp directory_call("heat_status", args) do
    chart = Heat.chart()

    {:ok,
     %{
       "companies" => heat_rows(chart.companies, Args.optional_string(args, "company")),
       "vendors" => heat_rows(chart.vendors, Args.optional_string(args, "ats")),
       "note" => "FIRE HOLD. Heat gates the queue. It does not submit."
     }}
  end

  defp directory_call("can_apply", args) do
    with {:ok, job_id} <- apply_id(args) do
      verdict = Heat.can_apply(job_id)

      {:ok,
       %{
         "job_id" => job_id,
         "decision" => Atom.to_string(verdict.decision),
         "reason" => Atom.to_string(verdict.reason),
         "company" => verdict.company,
         "company_load" => verdict.company_load,
         "company_cap" => verdict.company_cap,
         "company_increment" => verdict.company_increment,
         "size" => Atom.to_string(verdict.size),
         "ats_vendor" => Atom.to_string(verdict.ats_vendor),
         "ats_tenant" => verdict.ats_tenant,
         "vendor_load" => verdict.vendor_load,
         "vendor_cap" => verdict.vendor_cap,
         "tenant_load" => verdict.tenant_load,
         "tenant_cap" => verdict.tenant_cap,
         "cooldown_days" => verdict.cooldown_days,
         "note" => verdict.note,
         "fire" => "hold"
       }}
    end
  end

  defp directory_call("gym_status", _args), do: {:ok, gym_progress_view(Gym.progress())}

  defp directory_call("gym_log", args) do
    with {:ok, rep} <- Gym.log(args) do
      {:ok, Map.put(gym_rep_view(rep), "progress", gym_progress_view(Gym.progress()))}
    end
  end

  defp directory_call("gym_set_target", args) do
    with {:ok, n} <- Args.int(args, "target"),
         {:ok, n} <- Gym.set_target(n) do
      {:ok, Map.put(gym_progress_view(Gym.progress()), "target", n)}
    end
  end

  defp directory_call("net_status", _args), do: {:ok, net_progress_view(Net.progress())}

  defp directory_call("net_log", args) do
    with {:ok, entry} <- Net.log(args) do
      {:ok, Map.put(net_entry_view(entry), "progress", net_progress_view(Net.progress()))}
    end
  end

  defp directory_call("net_set_lane", args) do
    with {:ok, url} <- Args.string(args, "url"),
         {:ok, _lane} <- Net.set_lane(url) do
      {:ok, net_progress_view(Net.progress())}
    end
  end

  defp directory_call(name, _args)
       when name in ~w(get_application set_stage set_next_action set_score tailor_line open_cv_generation) do
    {:error, :unleased}
  end

  defp directory_call(_name, _args), do: {:error, :unknown_tool}

  @spec call(Handle.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(%Handle{} = handle, "get_application", args) do
    with :ok <- same_target(handle, args),
         {:ok, focus} <- Letterbox.command(handle, :get) do
      {:ok, application_view(handle, focus)}
    end
  end

  def call(%Handle{} = handle, "set_stage", args) do
    with :ok <- same_target(handle, args),
         {:ok, stage} <- Args.stage(args, "stage"),
         {:ok, job} <- Letterbox.command(handle, {:set_stage, stage}) do
      {:ok, %{"job_id" => job.id, "stage" => Pipeline.name(job.current_stage)}}
    end
  end

  def call(%Handle{} = handle, "set_next_action", args) do
    with :ok <- same_target(handle, args),
         {:ok, action} <- Args.string(args, "next_action"),
         {:ok, job} <- Letterbox.command(handle, {:set_next, action}) do
      {:ok, %{"job_id" => job.id, "next_action" => job.next_action}}
    end
  end

  def call(%Handle{} = handle, "set_score", args) do
    with :ok <- same_target(handle, args),
         {:ok, score} <- Args.score(args, "score"),
         {:ok, job} <- Letterbox.command(handle, {:set_score, score}) do
      {:ok,
       %{"job_id" => job.id, "score_100" => job.score_100, "band" => band_name(job.score_100)}}
    end
  end

  def call(%Handle{} = handle, "tailor_line", args) do
    attrs = %{
      mode: Args.optional_string(args, "mode"),
      body: Args.optional_string(args, "body"),
      reason: Args.optional_string(args, "reason")
    }

    with :ok <- same_target(handle, args),
         {:ok, item_id} <- Args.int(args, "item_id"),
         {:ok, pair} <- Letterbox.command(handle, {:tailor, item_id, attrs}) do
      {:ok, %{"job_id" => CvPair.job_id(pair), "variant_id" => CvPair.variant_id(pair)}}
    end
  end

  def call(%Handle{} = handle, "open_cv_generation", args) do
    with :ok <- same_target(handle, args),
         {:ok, lineage} <- Letterbox.command(handle, :open_generation) do
      {:ok, %{"employer_id" => lineage.employer_id, "generation" => lineage.generation}}
    end
  end

  def call(%Handle{}, _name, _args), do: {:error, :unknown_tool}

  defp directory_tools do
    [
      tool(
        "list_letterboxes",
        "List letterbox ids, highest score_100 first. Lease one to open a duplex socket",
        %{"min_score" => @score}
      ),
      tool("list_batches", "List batches on the desk", %{}),
      tool(
        "list_applications",
        "List applications ranked by score_100, then cooler company heat. Filters include heat (cool|warm|hot|blocked). FIRE HOLD — does not submit",
        filter_schema()
      ),
      tool(
        "recommend_applications",
        "The top applications by score_100 (default floor 90) to draft first. Omits heat-blocked roles. Ranks only; does not submit",
        Map.put(filter_schema(), "limit", %{"type" => "integer", "minimum" => 1, "maximum" => 100})
      ),
      tool(
        "score_distribution",
        "score_100 band counts and ten-point bins for the filtered desk",
        filter_schema()
      ),
      tool(
        "heat_status",
        "Company and ATS heat vs cap, with cooldown ETA. Optional company or ats filter. Structural governor — does not submit. FIRE HOLD.",
        %{
          "company" => @string,
          "ats" => Map.put(@string, "description", "ATS vendor name (greenhouse, workday, …)")
        }
      ),
      tool(
        "can_apply",
        "Would queueing this application (job_id / role_id) exceed company or ATS heat? Returns allow or defer with reason and cooldown. #{@hold}",
        %{"job_id" => @integer, "role_id" => @integer}
      ),
      tool(
        "gym_status",
        "Gym conditioning progress: daily target, streak, weekly pace score (not Life-EV score_100), topic counts. Jumping jacks for the fight. FIRE HOLD — does not submit jobs.",
        %{}
      ),
      tool(
        "gym_log",
        "Log a LeetCode / Codeforces / systems rep. Upserts the problem by platform+slug. Conditioning, not the job. FIRE HOLD — does not submit jobs.",
        %{
          "platform" => enum(Gym.platforms()),
          "title" => @string,
          "slug" => @string,
          "topic" => enum(Gym.topics()),
          "difficulty" => enum(Gym.difficulties()),
          "url" => @string,
          "outcome" => enum(Gym.outcomes()),
          "minutes" => %{"type" => "integer", "minimum" => 0},
          "note" => @string,
          "done_on" => Map.put(@string, "description", "ISO date. Defaults to today.")
        }
      ),
      tool(
        "gym_set_target",
        "Set the gym daily solved-rep target (1–30). Conditioning pace, not Life-EV. FIRE HOLD.",
        %{"target" => %{"type" => "integer", "minimum" => 1, "maximum" => 30}}
      ),
      tool(
        "net_status",
        "Networking lane: Broadside Observer URL, shipped posts/artifacts this week, open drafts, observer runs. Not CRM. FIRE HOLD — does not submit jobs.",
        %{}
      ),
      tool(
        "net_log",
        "Log a Broadside Observer run, shipped artifact, X/social post, or outreach draft. Not a CRM. No contacts, no sequences. FIRE HOLD — does not submit jobs.",
        %{
          "kind" => enum(Net.kinds()),
          "channel" => enum(Net.channels()),
          "title" => @string,
          "url" => @string,
          "body" => @string,
          "shipped_on" =>
            Map.put(@string, "description", "ISO date. Defaults to today except drafts.")
        }
      ),
      tool(
        "net_set_lane",
        "Set the Broadside Observer research lane URL. Not CRM. FIRE HOLD.",
        %{"url" => @string}
      )
    ]
  end

  defp filter_schema do
    %{
      "q" => @string,
      "stage" => enum(Pipeline.keys()),
      "status" => @string,
      "batch" => @string,
      "min_score" => @score,
      "band" => enum(LifeEv.keys()),
      "heat" => enum(~w(all cool warm hot blocked)a)
    }
  end

  defp leased_tools do
    [
      tool("get_application", "Read the application closed over by this lease", %{}),
      tool("set_stage", "Move this application along the battleplan", %{
        "stage" => enum(Pipeline.keys())
      }),
      tool("set_next_action", "Set the next action on this application", %{
        "next_action" => @string
      }),
      tool("set_score", "Set this application's score_100", %{"score" => @score}),
      tool("tailor_line", "Add or revise a line on the CV closed over by this lease", %{
        "item_id" => @integer,
        "mode" => enum(Hireme.Mask.modes()),
        "body" => @string,
        "reason" => @string
      }),
      tool(
        "open_cv_generation",
        "After the cooldown, open an additive generation for this application's employer",
        %{}
      )
    ]
  end

  defp tool(name, description, schema) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "properties" => schema}
    }
  end

  defp enum(values), do: %{"type" => "string", "enum" => Enum.map(values, &Atom.to_string/1)}

  defp list_filters(args) do
    Filters.from_params(%{
      "q" => Args.optional_string(args, "q"),
      "stage" => Args.optional_string(args, "stage"),
      "status" => Args.optional_string(args, "status") || "all",
      "batch" => Args.optional_string(args, "batch"),
      "min_score" => Args.optional_string(args, "min_score") || Map.get(args, "min_score"),
      "band" => Args.optional_string(args, "band"),
      "heat" => Args.optional_string(args, "heat")
    })
  end

  defp fire do
    if Enum.any?(Desk.list_batches(), &(&1.fire == :open_fire)), do: "open_fire", else: "hold"
  end

  defp band_name(score), do: LifeEv.name(LifeEv.band(score))

  defp application_rows(filters) do
    Enum.map(Desk.list_cards(filters), fn card ->
      %{
        "job_id" => card.id,
        "company" => card.company,
        "role" => card.role,
        "stage" => Pipeline.name(card.stage),
        "batch" => card.batch_code,
        "cv_label" => card.cv_label,
        "score_100" => card.score_100,
        "band" => band_name(card.score_100),
        "load" => card.load,
        "cap" => card.cap,
        "heat_state" => Atom.to_string(card.heat_state),
        "ats" => Atom.to_string(card.ats_vendor),
        "cooldown_days" => card.cooldown_days
      }
    end)
  end

  defp letterbox_row(row) do
    %{
      "letterbox_id" => row.id,
      "job_id" => row.job_id,
      "company" => row.company,
      "role" => row.role,
      "stage" => Pipeline.name(row.stage),
      "batch" => row.batch,
      "score_100" => row.score_100,
      "band" => band_name(row.score_100),
      "leased" => row.leased,
      "socket" => "/mcp/letterbox/#{row.id}/websocket"
    }
  end

  defp batch_rows do
    Enum.map(Desk.list_batches(), fn batch ->
      %{
        "code" => batch.code,
        "fire" => Atom.to_string(batch.fire),
        "status" => Atom.to_string(batch.status),
        "ordinal" => batch.ordinal
      }
    end)
  end

  defp application_view(handle, focus) do
    pair = handle.pair

    %{
      "letterbox_id" => handle.id,
      "job_id" => CvPair.job_id(pair),
      "variant_id" => CvPair.variant_id(pair),
      "employer_id" => CvPair.employer_id(pair),
      "lineage_id" => CvPair.lineage_id(pair),
      "company" => focus.job.company,
      "role" => focus.job.role,
      "stage" => Pipeline.name(focus.job.current_stage),
      "score_100" => focus.job.score_100,
      "band" => band_name(focus.job.score_100),
      "cv_label" => focus.variant.label,
      "lines" =>
        Enum.map(focus.masks, fn line ->
          %{"item_id" => line.id, "mode" => Atom.to_string(line.mode), "title" => line.title}
        end)
    }
  end

  defp same_target(handle, args) do
    pair = handle.pair

    with {:ok, job_id} <- Args.optional_int(args, "job_id"),
         {:ok, letterbox_id} <- Args.optional_int(args, "letterbox_id"),
         {:ok, variant_id} <- Args.optional_int(args, "variant_id"),
         {:ok, lineage_id} <- Args.optional_int(args, "lineage_id") do
      cond do
        mismatch?(job_id, CvPair.job_id(pair)) -> {:error, :letterbox_mismatch}
        mismatch?(letterbox_id, handle.id) -> {:error, :letterbox_mismatch}
        mismatch?(variant_id, CvPair.variant_id(pair)) -> {:error, :cv_mismatch}
        mismatch?(lineage_id, CvPair.lineage_id(pair)) -> {:error, :cv_mismatch}
        true -> :ok
      end
    end
  end

  defp mismatch?(nil, _expected), do: false
  defp mismatch?(value, expected), do: value != expected

  # `job_id` or, as the distillation packs call it, `role_id`.
  defp apply_id(args) do
    case {Args.optional_int(args, "job_id"), Args.optional_int(args, "role_id")} do
      {{:ok, n}, _} when is_integer(n) -> {:ok, n}
      {_, {:ok, n}} when is_integer(n) -> {:ok, n}
      _ -> {:error, {:argument, "job_id"}}
    end
  end

  defp heat_rows(rows, needle) when needle in [nil, ""], do: Enum.map(rows, &heat_row_view/1)

  defp heat_rows(rows, needle) do
    n = String.downcase(needle)

    rows
    |> Enum.filter(
      &(String.contains?(String.downcase(&1.key), n) or
          String.contains?(String.downcase(&1.label), n))
    )
    |> Enum.map(&heat_row_view/1)
  end

  defp heat_row_view(row) do
    %{
      "key" => row.key,
      "label" => row.label,
      "load" => row.load,
      "cap" => row.cap,
      "ratio" => row.ratio,
      "n" => row.n,
      "cooldown_days" => row.cooldown_days,
      "size" => row.size && Atom.to_string(row.size)
    }
  end

  defp gym_progress_view(%Gym.Progress{} = progress) do
    %{
      "today" => Date.to_iso8601(progress.today),
      "target" => progress.target,
      "streak" => progress.streak,
      "solved_today" => progress.solved_today,
      "solved_week" => progress.solved_week,
      "score" => progress.score,
      "note" =>
        "Gym score is weekly conditioning pace (0–100), not Life-EV score_100. FIRE HOLD — does not submit.",
      "topics" =>
        Enum.map(progress.topics, fn row ->
          %{"topic" => Atom.to_string(row.key), "label" => row.label, "count" => row.count}
        end),
      "recent" => Enum.map(progress.recent, &gym_rep_view/1)
    }
  end

  defp gym_rep_view(%Gym.Rep{problem: problem} = rep) do
    %{
      "id" => rep.id,
      "done_on" => Date.to_iso8601(rep.done_on),
      "outcome" => Atom.to_string(rep.outcome),
      "minutes" => rep.minutes,
      "note" => rep.note,
      "platform" => Atom.to_string(problem.platform),
      "slug" => problem.slug,
      "title" => problem.title,
      "topic" => Atom.to_string(problem.topic),
      "difficulty" => Atom.to_string(problem.difficulty),
      "url" => problem.url
    }
  end

  defp net_progress_view(%Net.Progress{} = progress) do
    %{
      "lane" => progress.lane,
      "shipped_week" => progress.shipped_week,
      "drafts" => progress.drafts,
      "observer_runs" => progress.observer_runs,
      "note" => "Not CRM. Broadside Observer + shipped work. FIRE HOLD — does not submit.",
      "recent" => Enum.map(progress.recent, &net_entry_view/1)
    }
  end

  defp net_entry_view(%Net.Entry{} = entry) do
    %{
      "id" => entry.id,
      "kind" => Atom.to_string(entry.kind),
      "channel" => Atom.to_string(entry.channel),
      "title" => entry.title,
      "url" => entry.url,
      "body" => entry.body,
      "shipped_on" => entry.shipped_on && Date.to_iso8601(entry.shipped_on)
    }
  end

  defp error_message(%Ecto.Changeset{}), do: "invalid"
  defp error_message({:argument, name}), do: "bad argument #{name}"
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)
end
