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

  The directory socket at `/mcp/websocket` only lists letterboxes.
  A letterbox socket at `/mcp/letterbox/:letterbox_id/websocket` is the
  full-duplex lease. Its handle reads and writes one application. The
  command carried to the consumer has no application id. A job id, a
  variant id, or a letterbox id in the arguments is checked against the
  handle and otherwise ignored.
  """

  alias Hireme.CvPair
  alias Hireme.Desk
  alias Hireme.Desk.Filters
  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle
  alias Hireme.Mcp.Args
  alias Hireme.Pipeline

  @type frame :: map()

  @spec directory(frame()) :: map()
  def directory(%{"id" => id, "method" => "tools/list"}) do
    %{id: id, result: %{tools: directory_tools()}}
  end

  def directory(%{"id" => id, "method" => "tools/call", "params" => %{"name" => name} = params}) do
    case directory_call(name, params["arguments"] || %{}) do
      {:ok, result} -> %{id: id, result: result}
      {:error, reason} -> %{id: id, error: %{code: -32000, message: error_message(reason)}}
    end
  end

  def directory(%{"id" => id}) do
    %{id: id, error: %{code: -32601, message: "unknown method"}}
  end

  def directory(_), do: %{error: %{code: -32600, message: "invalid request"}}

  @spec handle(Handle.t(), frame()) :: map()
  def handle(%Handle{}, %{"id" => id, "method" => "tools/list"}) do
    %{id: id, result: %{tools: leased_tools()}}
  end

  def handle(%Handle{} = handle, %{"id" => id, "method" => "tools/call", "params" => params}) do
    case call(handle, params["name"], params["arguments"] || %{}) do
      {:ok, result} -> %{id: id, result: result}
      {:error, reason} -> %{id: id, error: %{code: -32000, message: error_message(reason)}}
    end
  end

  def handle(%Handle{}, %{"id" => id}) do
    %{id: id, error: %{code: -32601, message: "unknown method"}}
  end

  def handle(%Handle{}, _), do: %{error: %{code: -32600, message: "invalid request"}}

  defp directory_call("list_letterboxes", _args), do: {:ok, %{"letterboxes" => letterbox_rows()}}
  defp directory_call("list_batches", _args), do: {:ok, %{"batches" => batch_rows()}}

  defp directory_call("list_applications", args) do
    filters =
      Filters.from_params(%{
        "q" => Args.optional_string(args, "q"),
        "stage" => Args.optional_string(args, "stage"),
        "status" => Args.optional_string(args, "status") || "all",
        "batch" => Args.optional_string(args, "batch")
      })

    cards =
      Enum.map(Desk.list_cards(filters), fn card ->
        %{
          "job_id" => card.id,
          "company" => card.company,
          "role" => card.role,
          "stage" => Pipeline.name(card.stage),
          "batch" => card.batch_code,
          "cv_label" => card.cv_label
        }
      end)

    {:ok, %{"applications" => cards}}
  end

  defp directory_call(name, _args)
       when name in ~w(get_application set_stage set_next_action tailor_line open_cv_generation) do
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

  def call(%Handle{} = handle, "tailor_line", args) do
    with :ok <- same_target(handle, args),
         {:ok, item_id} <- Args.int(args, "item_id"),
         {:ok, pair} <- Letterbox.command(handle, {:tailor, item_id, tailor_attrs(args)}) do
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
      tool("list_letterboxes", "List letterbox ids. Lease one to open a duplex socket", %{}),
      tool("list_batches", "List batches on the desk", %{}),
      tool("list_applications", "List applications, optionally filtered", %{
        "q" => %{"type" => "string"},
        "stage" => %{"type" => "string", "enum" => Enum.map(Pipeline.keys(), &Pipeline.name/1)},
        "status" => %{"type" => "string"},
        "batch" => %{"type" => "string"}
      })
    ]
  end

  defp leased_tools do
    [
      tool("get_application", "Read the application closed over by this lease", %{}),
      tool("set_stage", "Move this application along the battleplan", %{
        "stage" => %{"type" => "string", "enum" => Enum.map(Pipeline.keys(), &Pipeline.name/1)}
      }),
      tool("set_next_action", "Set the next action on this application", %{
        "next_action" => %{"type" => "string"}
      }),
      tool("tailor_line", "Add or revise a line on the CV closed over by this lease", %{
        "item_id" => %{"type" => "integer"},
        "mode" => %{"type" => "string", "enum" => ~w(hidden altered emphasized)},
        "body" => %{"type" => "string"},
        "reason" => %{"type" => "string"}
      }),
      tool(
        "open_cv_generation",
        "After the cooldown, open an additive generation for this application's employer",
        %{}
      )
    ]
  end

  defp letterbox_rows do
    Enum.map(Letterbox.list(), fn row ->
      %{
        "letterbox_id" => row.id,
        "job_id" => row.job_id,
        "company" => row.company,
        "role" => row.role,
        "stage" => Pipeline.name(row.stage),
        "batch" => row.batch,
        "leased" => row.leased,
        "socket" => "/mcp/letterbox/#{row.id}/websocket"
      }
    end)
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
      "cv_label" => focus.variant.label,
      "lines" =>
        Enum.map(focus.masks, fn line ->
          %{"item_id" => line.id, "mode" => Atom.to_string(line.mode), "title" => line.title}
        end)
    }
  end

  defp tailor_attrs(args) do
    %{
      mode: Args.optional_string(args, "mode"),
      body: Args.optional_string(args, "body"),
      reason: Args.optional_string(args, "reason")
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

  defp tool(name, description, schema) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "properties" => schema}
    }
  end

  defp error_message(%Ecto.Changeset{}), do: "invalid"
  defp error_message({:argument, name}), do: "bad argument #{name}"
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)
end
