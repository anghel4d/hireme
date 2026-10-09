defmodule HiremeWeb.Mcp.Args do
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

defmodule HiremeWeb.Mcp do
  @moduledoc """
  Tool calls for a connected agent.

  The directory (`directory/1`) lists, ranks, and reports; it cannot
  write an application. A lease (`handle/2`) reads and writes one
  application through its handle. Both carriers reach these the same
  way: a stream of an agent's wire session (`HiremeWeb.LetterboxStream`)
  or the fallback websockets at `/mcp/websocket` and
  `/mcp/letterbox/:letterbox_id/websocket`. The command carried to the
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
  alias Hireme.Net
  alias Hireme.Pipeline
  alias HiremeWeb.JSON
  alias HiremeWeb.Mcp.Args

  @type frame :: map()

  @score %{"type" => "integer", "minimum" => 0, "maximum" => 100}
  @string %{"type" => "string"}
  @integer %{"type" => "integer"}
  @hold "FIRE HOLD — does not submit."
  @gym_note "Gym score is weekly conditioning pace (0–100), not Life-EV score_100. FIRE HOLD — does not submit."
  @net_note "Not CRM. Broadside Observer + shipped work. FIRE HOLD — does not submit."

  @doc """
  One directory frame. Besides `tools/list` and `tools/call`, the
  directory answers `letterbox/tools` with the tools a lease would
  offer, so a client can show them before it holds one.
  """
  @spec directory(frame()) :: map()
  def directory(%{"id" => id, "method" => "letterbox/tools"}),
    do: %{id: id, result: %{tools: leased_tools()}}

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

  defp directory_call("score_distribution", args),
    do: {:ok, JSON.chart(Desk.score_chart(list_filters(args)))}

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
      {:ok, Map.merge(JSON.verdict(Heat.can_apply(job_id)), %{job_id: job_id, fire: "hold"})}
    end
  end

  defp directory_call("gym_status", _args), do: {:ok, gym()}

  defp directory_call("gym_log", args) do
    with {:ok, rep} <- Hireme.Ops.exec({:gym_log, args}),
         do: {:ok, Map.put(JSON.rep(rep), :progress, gym())}
  end

  defp directory_call("gym_set_target", args) do
    with {:ok, n} <- Args.int(args, "target"),
         {:ok, _n} <- Hireme.Ops.exec({:gym_target, n}),
         do: {:ok, gym()}
  end

  defp directory_call("net_status", _args), do: {:ok, net()}

  defp directory_call("net_log", args) do
    with {:ok, entry} <- Hireme.Ops.exec({:net_log, args}),
         do: {:ok, Map.put(JSON.entry(entry), :progress, net())}
  end

  defp directory_call("net_set_lane", args) do
    with {:ok, url} <- Args.string(args, "url"),
         {:ok, _lane} <- Hireme.Ops.exec({:net_lane, url}),
         do: {:ok, net()}
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

  defp heat_rows(rows, needle) when needle in [nil, ""], do: Enum.map(rows, &JSON.heat_row/1)

  defp heat_rows(rows, needle) do
    n = String.downcase(needle)

    rows
    |> Enum.filter(
      &(String.contains?(String.downcase(&1.key), n) or
          String.contains?(String.downcase(&1.label), n))
    )
    |> Enum.map(&JSON.heat_row/1)
  end

  defp gym, do: Map.put(JSON.gym(Gym.progress()), :note, @gym_note)

  defp net, do: Map.put(JSON.net(Net.progress()), :note, @net_note)

  defp error_message(%Ecto.Changeset{}), do: "invalid"
  defp error_message({:argument, name}), do: "bad argument #{name}"
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)
end
