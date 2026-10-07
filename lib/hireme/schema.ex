# Every row the desk stores, in the order the migration creates them.
# SQLite is the last place a card is a row; everything above reads
# structs, columns, or packets built from these.

defmodule Hireme.Corpus.User do
  @moduledoc "The candidate. A profile is a positioning; the narrative hangs off the person."
  use Hireme.Schema

  schema "users" do
    field :name, :string
    field :email, :string, default: ""
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> validate_required([:name])
    |> unique_constraint(:email)
  end
end

defmodule Hireme.Corpus.Narrative do
  @moduledoc """
  Private memory for one candidate. Not a CV section and not an overlay.
  Application export leaves it out while `private` is true, the default.
  """
  use Hireme.Schema

  schema "narratives" do
    field :body, :string, default: ""
    field :version, :integer, default: 1
    field :private, :boolean, default: true
    belongs_to :user, Hireme.Corpus.User
    timestamps()
  end

  def changeset(narrative, attrs) do
    narrative
    |> cast(attrs, [:user_id, :body, :version, :private])
    |> validate_required([:user_id, :body, :version])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end

defmodule Hireme.Corpus.Profile do
  use Hireme.Schema

  schema "profiles" do
    field :slug, :string
    field :name, :string
    field :headline, :string
    field :summary, :string
    belongs_to :user, Hireme.Corpus.User
    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:slug, :name, :headline, :summary, :user_id])
    |> validate_required([:slug, :name, :headline, :summary])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:user_id)
  end
end

defmodule Hireme.Corpus.Item do
  use Hireme.Schema

  schema "items" do
    field :kind, Ecto.Enum, values: [:experience, :project, :education, :skill, :timeline, :fact]
    field :key, :string
    field :title, :string
    field :body, :string, default: ""
    field :org, :string, default: ""
    field :span, :string, default: ""
    field :position, :integer, default: 0
    field :keywords, {:array, :string}, default: []
    belongs_to :profile, Hireme.Corpus.Profile
    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:profile_id, :kind, :key, :title, :body, :org, :span, :position, :keywords])
    |> validate_required([:kind, :key, :title, :position])
    |> unique_constraint(:key)
  end
end

defmodule Hireme.Kv.Pair do
  use Hireme.Schema

  schema "kv_pairs" do
    field :namespace, :string
    field :key, :string
    field :value, :string, default: ""
    timestamps()
  end

  def changeset(pair, attrs) do
    pair
    |> cast(attrs, [:namespace, :key, :value])
    |> validate_required([:namespace, :key])
    |> unique_constraint([:namespace, :key])
  end
end

defmodule Hireme.Desk.Employer do
  use Hireme.Schema

  schema "employers" do
    field :name, :string

    field :freshness, Ecto.Enum,
      values: [:unknown, :open, :thin, :closed, :blocked],
      default: :unknown

    field :note, :string, default: ""
    field :score_100, :integer, default: 50
    timestamps()
  end

  def changeset(employer, attrs) do
    employer
    |> cast(attrs, [:name, :freshness, :note, :score_100])
    |> validate_required([:name])
    |> validate_number(:score_100, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:name)
  end
end

defmodule Hireme.Desk.Batch do
  use Hireme.Schema

  schema "batches" do
    field :code, :string
    field :ordinal, :integer

    field :kind, Ecto.Enum,
      values: [:day_pack, :leftover, :universe_gaps, :linkedin],
      default: :day_pack

    field :status, Ecto.Enum,
      values: [:draft_prep, :fire_ready, :open_fire, :closed],
      default: :draft_prep

    field :fire, Ecto.Enum, values: [:hold, :open_fire], default: :hold
    field :target_size, :integer, default: 55
    field :queued_on, :date
    field :squad, :string, default: ""
    field :variety, :map, default: %{}
    field :note, :string, default: ""
    timestamps()
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([:code, :ordinal])
    |> unique_constraint(:code)
  end
end

defmodule Hireme.Desk.FreshnessVerdict do
  use Hireme.Schema

  schema "freshness_verdicts" do
    field :wave, :string
    field :verdict, Ecto.Enum, values: [:open, :thin, :closed, :blocked]
    field :eng_urls, :integer, default: 0
    field :noted_on, :date
    field :source, :string, default: ""
    belongs_to :employer, Hireme.Desk.Employer
    timestamps()
  end

  def changeset(verdict, attrs) do
    verdict
    |> cast(attrs, [:employer_id, :wave, :verdict, :eng_urls, :noted_on, :source])
    |> validate_required([:wave, :verdict])
    |> unique_constraint([:wave, :verdict])
  end
end

defmodule Hireme.Desk.Claim do
  use Hireme.Schema

  schema "claims" do
    field :squad, :string
    field :slice, :string
    field :note, :string, default: ""
    timestamps()
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:squad, :slice, :note])
    |> validate_required([:squad, :slice])
    |> unique_constraint([:squad, :slice])
  end
end

defmodule Hireme.Desk.Snapshot do
  use Hireme.Schema

  schema "scoreboard_snapshots" do
    field :noted_on, :date
    field :leftover_unique, :integer, default: 0
    field :target_total, :integer, default: 10_000
    field :target_on, :date
    field :daily_batches, :integer, default: 8
    field :daily_apps, :integer, default: 440
    field :note, :string, default: ""
    timestamps()
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([:noted_on])
    |> unique_constraint(:noted_on)
  end
end

defmodule Hireme.Desk.Job do
  use Hireme.Schema
  alias Hireme.Pipeline

  @statuses [:open, :paused, :hired, :closed]
  @type status :: :open | :paused | :hired | :closed

  schema "job_apps" do
    field :company, :string
    field :role, :string
    field :location, :string, default: ""
    field :listing_url, :string, default: ""
    field :canonical_url, :string, default: ""
    field :listing, :string, default: ""
    field :heat, :integer, default: 3
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :next_action, :string, default: ""
    field :next_due, :date
    field :source, :string, default: ""
    field :stage_on, :date
    field :current_stage, Ecto.Enum, values: Pipeline.keys()
    field :pips, :string, default: Pipeline.encode(Pipeline.initial(:discovered))
    field :stage_notes, :map, default: %{}

    field :freshness, Ecto.Enum,
      values: [:unknown, :open, :thin, :closed, :blocked],
      default: :unknown

    field :gate, Ecto.Enum, values: [:unset, :pursue, :maybe, :skip], default: :unset
    field :fit, :string, default: ""
    field :squad, :string, default: ""
    field :department, :string, default: ""
    field :score_100, :integer, default: 50
    field :heat_override, :boolean, default: false
    field :heat_override_reason, :string, default: ""
    field :keyword_hits, :integer, default: 0
    field :keyword_total, :integer, default: 0
    field :mask_hidden, :integer, default: 0
    field :mask_altered, :integer, default: 0
    field :mask_emphasized, :integer, default: 0
    belongs_to :profile, Hireme.Corpus.Profile
    belongs_to :employer, Hireme.Desk.Employer
    belongs_to :batch, Hireme.Desk.Batch
    timestamps()
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec parse_status(term()) :: {:ok, status()} | :error
  def parse_status(value), do: Hireme.Closed.parse(@statuses, value)

  def changeset(job, attrs) do
    job
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([:profile_id, :company, :role, :heat, :status, :current_stage, :pips])
    |> validate_number(:heat, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_number(:score_100, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_length(:pips, is: length(Pipeline.keys()))
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:batch_id)
    |> foreign_key_constraint(:employer_id)
    |> unique_constraint(:canonical_url)
  end
end

defmodule Hireme.Desk.Event do
  use Hireme.Schema

  schema "events" do
    field :kind, :string
    field :body, :string, default: ""
    belongs_to :job_app, Hireme.Desk.Job
    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:job_app_id, :kind, :body])
    |> validate_required([:job_app_id, :kind, :body])
    |> foreign_key_constraint(:job_app_id)
  end
end

defmodule Hireme.Letterbox.Record do
  @moduledoc false
  use Hireme.Schema

  schema "letterboxes" do
    belongs_to :job_app, Hireme.Desk.Job
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:job_app_id])
    |> validate_required([:job_app_id])
    |> unique_constraint(:job_app_id)
    |> foreign_key_constraint(:job_app_id)
  end
end

defmodule Hireme.Cv.Lineage do
  @moduledoc "The one CV for an employer. Applications do not carry a free-floating variant."
  use Hireme.Schema

  schema "cv_lineages" do
    field :generation, :integer, default: 1
    field :opened_on, :date
    field :rewrites_allowed, :boolean, default: true
    field :theme, :map, default: %{}
    belongs_to :employer, Hireme.Desk.Employer
    timestamps()
  end

  def changeset(lineage, attrs) do
    lineage
    |> cast(attrs, [:employer_id, :generation, :opened_on, :rewrites_allowed, :theme])
    |> validate_required([:employer_id, :generation, :opened_on])
    |> unique_constraint(:employer_id)
    |> foreign_key_constraint(:employer_id)
  end
end

defmodule Hireme.Desk.Variant do
  use Hireme.Schema

  schema "cv_variants" do
    field :label, :string
    field :theme, :map, default: %{}
    field :note, :string, default: ""
    belongs_to :job_app, Hireme.Desk.Job
    belongs_to :profile, Hireme.Corpus.Profile
    belongs_to :lineage, Hireme.Cv.Lineage
    timestamps()
  end

  def changeset(variant, attrs) do
    variant
    |> cast(attrs, [:job_app_id, :profile_id, :label, :theme, :note, :lineage_id])
    |> validate_required([:profile_id, :label])
    |> unique_constraint(:job_app_id)
    |> foreign_key_constraint(:job_app_id)
    |> foreign_key_constraint(:profile_id)
  end
end

defmodule Hireme.Desk.Overlay do
  use Hireme.Schema
  alias Hireme.Mask

  schema "overlays" do
    field :mode, Ecto.Enum, values: Mask.modes()
    field :title, :string
    field :body, :string
    field :reason, :string
    field :generation, :integer, default: 1
    belongs_to :job_app, Hireme.Desk.Job
    belongs_to :item, Hireme.Corpus.Item
    belongs_to :lineage, Hireme.Cv.Lineage
    timestamps()
  end

  @doc "One overlay mode from the wire. `inherit` is the absence of an overlay and is the caller's word."
  @spec parse_mode(term()) :: {:ok, Mask.applied()} | :error
  def parse_mode(value), do: Hireme.Closed.parse(Mask.modes(), value)

  def changeset(overlay, attrs) do
    overlay
    |> cast(attrs, [
      :job_app_id,
      :item_id,
      :lineage_id,
      :mode,
      :title,
      :body,
      :reason,
      :generation
    ])
    |> validate_required([:job_app_id, :item_id, :lineage_id, :mode])
    |> unique_constraint([:job_app_id, :item_id])
    |> unique_constraint([:lineage_id, :item_id])
    |> foreign_key_constraint(:job_app_id)
    |> foreign_key_constraint(:item_id)
  end
end

defmodule Hireme.Gym.Problem do
  use Hireme.Schema

  schema "gym_problems" do
    field :platform, Ecto.Enum, values: [:leetcode, :codeforces, :other]
    field :slug, :string
    field :title, :string, default: ""

    field :topic, Ecto.Enum,
      values: [:arrays, :graphs, :strings, :dp, :trees, :systems, :other],
      default: :other

    field :difficulty, Ecto.Enum, values: [:easy, :medium, :hard, :unknown], default: :unknown
    field :url, :string, default: ""
    has_many :reps, Hireme.Gym.Rep
    timestamps()
  end

  def changeset(problem, attrs) do
    problem
    |> cast(attrs, [:platform, :slug, :title, :topic, :difficulty, :url])
    |> validate_required([:platform, :slug, :title])
    |> unique_constraint([:platform, :slug])
  end
end

defmodule Hireme.Gym.Rep do
  use Hireme.Schema

  schema "gym_reps" do
    field :done_on, :date
    field :minutes, :integer, default: 0
    field :outcome, Ecto.Enum, values: [:solved, :attempt, :skip], default: :solved
    field :note, :string, default: ""
    belongs_to :problem, Hireme.Gym.Problem
    timestamps()
  end

  def changeset(rep, attrs) do
    rep
    |> cast(attrs, [:problem_id, :done_on, :minutes, :outcome, :note])
    |> validate_required([:problem_id, :done_on, :outcome])
    |> validate_number(:minutes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:problem_id)
  end
end

defmodule Hireme.Net.Entry do
  use Hireme.Schema

  schema "net_entries" do
    field :kind, Ecto.Enum, values: [:observer, :artifact, :post, :draft]
    field :channel, Ecto.Enum, values: [:broadside, :x, :other], default: :other
    field :title, :string, default: ""
    field :url, :string, default: ""
    field :body, :string, default: ""
    field :shipped_on, :date
    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :channel, :title, :url, :body, :shipped_on])
    |> validate_required([:kind, :channel, :title])
  end
end
