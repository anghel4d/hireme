defmodule Hireme.CvPair.JobId do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: pos_integer()}

  @spec new(pos_integer()) :: t()
  def new(value) when is_integer(value) and value > 0, do: %__MODULE__{value: value}
end

defmodule Hireme.CvPair.VariantId do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: pos_integer()}

  @spec new(pos_integer()) :: t()
  def new(value) when is_integer(value) and value > 0, do: %__MODULE__{value: value}
end

defmodule Hireme.CvPair.EmployerId do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: pos_integer()}

  @spec new(pos_integer()) :: t()
  def new(value) when is_integer(value) and value > 0, do: %__MODULE__{value: value}
end

defmodule Hireme.CvPair.LineageId do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: pos_integer()}

  @spec new(pos_integer()) :: t()
  def new(value) when is_integer(value) and value > 0, do: %__MODULE__{value: value}
end

defmodule Hireme.CvPair do
  @moduledoc """
  The CV for one application.

  `t()` is that application and its variant, loaded together. `bind/1`
  is the constructor. The query joins the variant to the application's
  employer lineage, so a variant from another employer does not produce
  a pair. `tailor/3` and `drop_line/2` accept only `t()`. They load the
  pair again and require the two structs to be equal. A struct built for
  a different application does not match, and the write does not run.

  `JobId`, `VariantId`, `EmployerId`, and `LineageId` are different
  structs. A job id does not have the variant id's type, so the pair
  cannot be assembled by swapping those fields and still type-check.

  One employer has one lineage (`cv_lineages.employer_id` is unique).
  One application has one variant (`cv_variants.job_app_id` is unique).
  The trigger `cv_variants_employer_match` aborts a row that points an
  application at another employer's lineage. The overlay trigger does
  the same for a line.

  For 90 days after a generation opens, the lineage can be rewritten.
  That is one quarter. After that, edits wait. `open_generation/1`
  starts the next quarter and accepts new lines only. An existing line
  stays, so a later attempt cannot replace it with another CV's wording.
  """

  import Ecto.Query
  alias Hireme.Cv.Lineage
  alias Hireme.CvPair.EmployerId
  alias Hireme.CvPair.JobId
  alias Hireme.CvPair.LineageId
  alias Hireme.CvPair.VariantId
  alias Hireme.Desk.Employer
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Variant
  alias Hireme.Repo

  @enforce_keys [:job_id, :variant_id, :employer_id, :lineage_id]
  defstruct [:job_id, :variant_id, :employer_id, :lineage_id]

  @typedoc """
  One application paired with the only variant that belongs to it.
  """
  @type t :: %__MODULE__{
          job_id: JobId.t(),
          variant_id: VariantId.t(),
          employer_id: EmployerId.t(),
          lineage_id: LineageId.t()
        }

  @cooldown_days 90

  @spec cooldown_days() :: 90
  def cooldown_days, do: @cooldown_days

  @spec job_id(t()) :: pos_integer()
  def job_id(%__MODULE__{job_id: %JobId{value: value}}), do: value

  @spec variant_id(t()) :: pos_integer()
  def variant_id(%__MODULE__{variant_id: %VariantId{value: value}}), do: value

  @spec employer_id(t()) :: pos_integer()
  def employer_id(%__MODULE__{employer_id: %EmployerId{value: value}}), do: value

  @spec lineage_id(t()) :: pos_integer()
  def lineage_id(%__MODULE__{lineage_id: %LineageId{value: value}}), do: value

  def ensure_employer(nil, company) when is_binary(company) and company != "" do
    case Repo.get_by(Employer, name: company) do
      nil ->
        %Employer{}
        |> Employer.changeset(%{name: company})
        |> Repo.insert!()

      employer ->
        employer
    end
  end

  def ensure_employer(id, _company) when is_integer(id), do: Repo.get!(Employer, id)

  def ensure_lineage(employer_id, today \\ Date.utc_today()) do
    case Repo.get_by(Lineage, employer_id: employer_id) do
      nil ->
        lineage =
          %Lineage{}
          |> Lineage.changeset(%{
            employer_id: employer_id,
            generation: 1,
            opened_on: today,
            rewrites_allowed: true,
            theme: %{}
          })
          |> Repo.insert!()

        {:new, lineage}

      lineage ->
        {:existing, lineage}
    end
  end

  @doc """
  Load the only CV pair for this application.
  """
  @spec bind(JobId.t() | pos_integer()) :: {:ok, t()} | {:error, :unbound | :job_id}
  def bind(%JobId{value: job_id}), do: load(job_id)
  def bind(job_id) when is_integer(job_id) and job_id > 0, do: bind(JobId.new(job_id))
  def bind(_), do: {:error, :job_id}

  @spec bind!(JobId.t() | pos_integer()) :: t()
  def bind!(job) do
    {:ok, pair} = bind(job)
    pair
  end

  @spec tailor(t(), pos_integer(), map(), Date.t()) ::
          {:ok, t()} | {:error, atom() | Ecto.Changeset.t()}
  def tailor(pair, item_id, attrs, today \\ Date.utc_today())

  def tailor(%__MODULE__{} = claimed, item_id, attrs, today) when is_integer(item_id) do
    with {:ok, pair} <- verified(claimed),
         {:ok, lineage} <- editable(pair, today) do
      write_line(pair, lineage, item_id, attrs, today)
    end
  end

  def tailor(_, _, _, _), do: {:error, :cv_mismatch}

  @spec drop_line(t(), pos_integer(), Date.t()) :: {:ok, t()} | {:error, atom()}
  def drop_line(pair, item_id, today \\ Date.utc_today())

  def drop_line(%__MODULE__{} = claimed, item_id, today) when is_integer(item_id) do
    with {:ok, pair} <- verified(claimed),
         {:ok, lineage} <- editable(pair, today) do
      if lineage.rewrites_allowed do
        Repo.delete_all(
          from o in Overlay,
            where: o.lineage_id == ^lineage_id(pair) and o.item_id == ^item_id
        )

        {:ok, pair}
      else
        {:error, :not_additive}
      end
    end
  end

  def drop_line(_, _, _), do: {:error, :cv_mismatch}

  @spec open_generation(EmployerId.t() | pos_integer(), Date.t()) ::
          {:ok, Lineage.t()} | {:error, atom() | Ecto.Changeset.t()}
  def open_generation(employer, today \\ Date.utc_today())

  def open_generation(%EmployerId{value: employer_id}, today) do
    lineage = Repo.get_by(Lineage, employer_id: employer_id)

    cond do
      is_nil(lineage) ->
        {:error, :lineage}

      Date.diff(today, lineage.opened_on) < @cooldown_days ->
        {:error, :cooldown}

      true ->
        lineage
        |> Lineage.changeset(%{
          generation: lineage.generation + 1,
          opened_on: today,
          rewrites_allowed: false
        })
        |> Repo.update()
    end
  end

  def open_generation(employer_id, today) when is_integer(employer_id) and employer_id > 0 do
    open_generation(EmployerId.new(employer_id), today)
  end

  def open_generation(_, _), do: {:error, :lineage}

  @spec phase(Lineage.t(), Date.t()) :: :ready | :tailor | :additive
  def phase(%Lineage{} = lineage, today \\ Date.utc_today()) do
    cond do
      Date.diff(today, lineage.opened_on) >= @cooldown_days -> :ready
      lineage.rewrites_allowed -> :tailor
      true -> :additive
    end
  end

  defp load(job_id) do
    query =
      from v in Variant,
        join: j in Hireme.Desk.Job,
        on: j.id == v.job_app_id,
        join: l in Lineage,
        on: l.id == v.lineage_id and l.employer_id == j.employer_id,
        where: v.job_app_id == ^job_id,
        select: %{
          job_id: j.id,
          variant_id: v.id,
          employer_id: j.employer_id,
          lineage_id: l.id
        }

    case Repo.one(query) do
      nil ->
        {:error, :unbound}

      row ->
        {:ok,
         %__MODULE__{
           job_id: JobId.new(row.job_id),
           variant_id: VariantId.new(row.variant_id),
           employer_id: EmployerId.new(row.employer_id),
           lineage_id: LineageId.new(row.lineage_id)
         }}
    end
  end

  defp verified(
         %__MODULE__{
           job_id: %JobId{value: job_id},
           variant_id: %VariantId{},
           employer_id: %EmployerId{},
           lineage_id: %LineageId{}
         } = claimed
       ) do
    case load(job_id) do
      {:ok, ^claimed} -> {:ok, claimed}
      {:ok, _other} -> {:error, :cv_mismatch}
      error -> error
    end
  end

  defp verified(_), do: {:error, :cv_mismatch}

  defp editable(pair, today) do
    lineage = Repo.get!(Lineage, lineage_id(pair))

    case phase(lineage, today) do
      :ready -> {:error, :cooldown}
      _ -> {:ok, lineage}
    end
  end

  defp write_line(pair, lineage, item_id, attrs, today) do
    existing = Repo.get_by(Overlay, lineage_id: lineage_id(pair), item_id: item_id)

    cond do
      existing && not lineage.rewrites_allowed ->
        {:error, :not_additive}

      existing ->
        case existing |> Overlay.changeset(attrs) |> Repo.update() do
          {:ok, _} -> {:ok, pair}
          other -> other
        end

      phase(lineage, today) == :ready ->
        {:error, :cooldown}

      true ->
        %Overlay{job_app_id: job_id(pair), lineage_id: lineage_id(pair), item_id: item_id}
        |> Overlay.changeset(
          Map.merge(attrs, %{
            job_app_id: job_id(pair),
            lineage_id: lineage_id(pair),
            item_id: item_id,
            generation: lineage.generation
          })
        )
        |> Repo.insert()
        |> case do
          {:ok, _} -> {:ok, pair}
          other -> other
        end
    end
  end
end
