# Every row the desk stores, in the order the migration creates them.
# SQLite is the last place a card is a row; everything above reads
# structs, columns, or packets built from these. The account comes
# first; every row the desk owns names it through `tenant/1`.

defmodule Hireme.Accounts.Account do
  @moduledoc "Who signs in. The desk, its keys, its factors, and its sessions hang off this row."
  use Hireme.Schema

  @statuses [:active, :suspended]

  schema "accounts" do
    field :name, :string, default: ""
    field :status, Ecto.Enum, values: @statuses, default: :active
    # Live API keys, moved in the same statement as create and revoke so two
    # mints cannot both pass the cap.
    field :live_key_count, :integer, default: 0
    # Committed desk changes, bumped by `Hireme.Ops` with each one.
    field :desk_rev, :integer, default: 0
    timestamps()
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :status])
    |> validate_length(:name, max: 200)
  end
end

defmodule Hireme.Accounts.Session do
  @moduledoc "One signed-in browser. The cookie carries a token; only its hash is here."
  use Hireme.Schema

  schema "sessions" do
    field :token_hash, :binary, redact: true
    field :authenticated_at, :utc_datetime
    field :mfa_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :ip, :string, default: ""
    field :user_agent, :string, default: ""
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :account_id,
      :token_hash,
      :authenticated_at,
      :mfa_at,
      :last_seen_at,
      :expires_at,
      :revoked_at,
      :ip,
      :user_agent
    ])
    |> validate_required([
      :account_id,
      :token_hash,
      :authenticated_at,
      :last_seen_at,
      :expires_at
    ])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:account_id)
  end
end

defmodule Hireme.Accounts.Identity do
  @moduledoc "One way into an account: a verified address, a GitHub user, or an X user."
  use Hireme.Schema

  @providers [:email, :github, :x]
  @type provider :: :email | :github | :x

  schema "identities" do
    field :provider, Ecto.Enum, values: @providers
    field :subject, :string
    field :display, :string, default: ""
    field :verified_at, :utc_datetime
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def providers, do: @providers

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:account_id, :provider, :subject, :display, :verified_at])
    |> validate_required([:account_id, :provider, :subject, :verified_at])
    |> validate_length(:subject, max: 320)
    |> validate_length(:display, max: 200)
    |> unique_constraint([:provider, :subject])
    |> foreign_key_constraint(:account_id)
  end
end

defmodule Hireme.Accounts.MagicLink do
  @moduledoc """
  A one-time proof of an address, mailed as a link. Only the token's hash
  is here, and no account: the address may not have one yet.
  """
  use Hireme.Schema

  schema "magic_links" do
    field :email, :string
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :ip, :string, default: ""
    field :user_agent, :string, default: ""
    timestamps(updated_at: false)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:email, :token_hash, :expires_at, :used_at, :ip, :user_agent])
    |> validate_required([:email, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
  end
end

defmodule Hireme.ApiKeys.Key do
  @moduledoc "An agent's key: shown once, stored hashed, scoped to one account."
  use Hireme.Schema

  schema "api_keys" do
    field :key_id, :string
    field :name, :string
    field :secret_hash, :binary, redact: true
    field :prefix, :string
    field :scope, :string, default: "mcp"
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:account_id, :key_id, :name, :secret_hash, :prefix, :scope, :expires_at])
    |> validate_required([:account_id, :key_id, :name, :secret_hash, :prefix, :scope])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:key_id)
    |> foreign_key_constraint(:account_id)
  end
end

defmodule Hireme.Mfa.Method do
  @moduledoc "A second factor: an authenticator app or a WebAuthn credential."
  use Hireme.Schema

  schema "mfa_methods" do
    field :kind, Ecto.Enum, values: [:totp, :webauthn]
    field :name, :string, default: ""
    field :totp_secret, :binary, redact: true
    field :totp_last_used, :integer, default: 0
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :aaguid, :binary
    field :transports, :string, default: ""
    field :backup_eligible, :boolean, default: false
    field :backed_up, :boolean, default: false
    field :verified_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :consecutive_failures, :integer, default: 0
    field :disabled_at, :utc_datetime
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(method, attrs) do
    method
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([:account_id, :kind])
    |> validate_length(:name, max: 100)
    |> unique_constraint(:credential_id)
    |> foreign_key_constraint(:account_id)
  end
end

defmodule Hireme.Mfa.Challenge do
  @moduledoc "A ceremony in flight: a pending TOTP seed or a WebAuthn challenge, for one session."
  use Hireme.Schema

  schema "mfa_challenges" do
    field :kind, Ecto.Enum, values: [:totp_enroll, :webauthn_register, :webauthn_assert]
    field :payload, :binary, redact: true
    field :expires_at, :utc_datetime
    belongs_to :account, Hireme.Accounts.Account
    belongs_to :session, Hireme.Accounts.Session
    timestamps()
  end

  def changeset(challenge, attrs) do
    challenge
    |> cast(attrs, [:account_id, :session_id, :kind, :payload, :expires_at])
    |> validate_required([:account_id, :session_id, :kind, :payload, :expires_at])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:session_id)
  end
end

defmodule Hireme.Mfa.RecoveryCode do
  @moduledoc "A look-up secret: salted hash, one use."
  use Hireme.Schema

  schema "recovery_codes" do
    field :salt, :binary, redact: true
    field :code_hash, :binary, redact: true
    field :used_at, :utc_datetime
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(code, attrs) do
    code
    |> cast(attrs, [:account_id, :salt, :code_hash, :used_at])
    |> validate_required([:account_id, :salt, :code_hash])
    |> foreign_key_constraint(:account_id)
  end
end

defmodule Hireme.Audit.Event do
  @moduledoc "One security event. `account_id` is nil before anyone has signed in."
  use Hireme.Schema

  schema "audit_events" do
    field :kind, :string
    field :ip, :string, default: ""
    field :user_agent, :string, default: ""
    field :meta, :map, default: %{}
    field :inserted_at, :utc_datetime
    belongs_to :account, Hireme.Accounts.Account
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:account_id, :kind, :ip, :user_agent, :meta, :inserted_at])
    |> validate_required([:kind, :inserted_at])
    |> foreign_key_constraint(:account_id)
  end
end

defmodule Hireme.Corpus.User do
  @moduledoc "The candidate. A profile is a positioning; the narrative hangs off the person."
  use Hireme.Schema

  schema "users" do
    field :name, :string
    field :email, :string, default: ""
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> validate_required([:name])
    |> unique_constraint(:email)
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(narrative, attrs) do
    narrative
    |> cast(attrs, [:user_id, :body, :version, :private])
    |> validate_required([:user_id, :body, :version])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:slug, :name, :headline, :summary, :user_id])
    |> validate_required([:slug, :name, :headline, :summary])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:user_id)
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:profile_id, :kind, :key, :title, :body, :org, :span, :position, :keywords])
    |> validate_required([:kind, :key, :title, :position])
    |> unique_constraint(:key)
    |> tenant()
  end
end

defmodule Hireme.Kv.Pair do
  use Hireme.Schema

  schema "kv_pairs" do
    field :namespace, :string
    field :key, :string
    field :value, :string, default: ""
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(pair, attrs) do
    pair
    |> cast(attrs, [:namespace, :key, :value])
    |> validate_required([:namespace, :key])
    |> unique_constraint([:namespace, :key])
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(employer, attrs) do
    employer
    |> cast(attrs, [:name, :freshness, :note, :score_100])
    |> validate_required([:name])
    |> validate_number(:score_100, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:name)
    |> tenant()
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
    field :note, :string, default: ""
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, __schema__(:fields) -- [:id, :account_id, :inserted_at, :updated_at])
    |> validate_required([:code, :ordinal])
    |> unique_constraint(:code)
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(verdict, attrs) do
    verdict
    |> cast(attrs, [:employer_id, :wave, :verdict, :eng_urls, :noted_on, :source])
    |> validate_required([:wave, :verdict])
    |> unique_constraint([:wave, :verdict])
    |> tenant()
  end
end

defmodule Hireme.Desk.Claim do
  use Hireme.Schema

  schema "claims" do
    field :squad, :string
    field :slice, :string
    field :note, :string, default: ""
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:squad, :slice, :note])
    |> validate_required([:squad, :slice])
    |> unique_constraint([:squad, :slice])
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, __schema__(:fields) -- [:id, :account_id, :inserted_at, :updated_at])
    |> validate_required([:noted_on])
    |> unique_constraint(:noted_on)
    |> tenant()
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
    belongs_to :profile, Hireme.Corpus.Profile
    belongs_to :employer, Hireme.Desk.Employer
    belongs_to :batch, Hireme.Desk.Batch
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  def changeset(job, attrs) do
    job
    |> cast(attrs, __schema__(:fields) -- [:id, :account_id, :inserted_at, :updated_at])
    |> validate_required([:profile_id, :company, :role, :heat, :status, :current_stage, :pips])
    |> validate_number(:heat, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_number(:score_100, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_length(:pips, is: length(Pipeline.keys()))
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:batch_id)
    |> foreign_key_constraint(:employer_id)
    |> unique_constraint(:canonical_url)
    |> tenant()
  end
end

defmodule Hireme.Desk.Event do
  use Hireme.Schema

  schema "events" do
    field :kind, :string
    field :body, :string, default: ""
    belongs_to :job_app, Hireme.Desk.Job
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:job_app_id, :kind, :body])
    |> validate_required([:job_app_id, :kind, :body])
    |> foreign_key_constraint(:job_app_id)
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(lineage, attrs) do
    lineage
    |> cast(attrs, [:employer_id, :generation, :opened_on, :rewrites_allowed, :theme])
    |> validate_required([:employer_id, :generation, :opened_on])
    |> unique_constraint(:employer_id)
    |> foreign_key_constraint(:employer_id)
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(variant, attrs) do
    variant
    |> cast(attrs, [:job_app_id, :profile_id, :label, :theme, :note, :lineage_id])
    |> validate_required([:profile_id, :label])
    |> unique_constraint(:job_app_id)
    |> foreign_key_constraint(:job_app_id)
    |> foreign_key_constraint(:profile_id)
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
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
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(problem, attrs) do
    problem
    |> cast(attrs, [:platform, :slug, :title, :topic, :difficulty, :url])
    |> validate_required([:platform, :slug, :title])
    |> unique_constraint([:platform, :slug])
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(rep, attrs) do
    rep
    |> cast(attrs, [:problem_id, :done_on, :minutes, :outcome, :note])
    |> validate_required([:problem_id, :done_on, :outcome])
    |> validate_number(:minutes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:problem_id)
    |> tenant()
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
    belongs_to :account, Hireme.Accounts.Account
    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :channel, :title, :url, :body, :shipped_on])
    |> validate_required([:kind, :channel, :title])
    |> tenant()
  end
end

defmodule Hireme.Mailer.Notice do
  @moduledoc """
  One security notice for one address, queued by the request that caused
  it and sent by `Hireme.Mailer.Outbox`. `meta` holds only the notice's
  display fields (names, kinds, counts), never a secret.
  """
  use Hireme.Schema

  schema "mail_outbox" do
    field :address, :string
    field :kind, :string
    field :meta, :map, default: %{}
    field :attempts, :integer, default: 0
    field :next_at, :utc_datetime
    field :sent_at, :utc_datetime
    field :last_error, :string
    belongs_to :account, Hireme.Accounts.Account
    timestamps(updated_at: false)
  end
end

defmodule Hireme.Ops.Entry do
  @moduledoc """
  One client op's outcome, kept 24 hours under the client's id so a
  resend is answered from here. `op_id` is the client's u64 read as a
  signed 64-bit integer. `refusal` is nil for an op that committed at
  `rev`, and the refusal's name otherwise.
  """
  use Hireme.Schema

  schema "wire_ops" do
    field :op_id, :integer
    field :kind, :string
    field :rev, :integer
    field :refusal, :string
    belongs_to :account, Hireme.Accounts.Account
    timestamps(updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:op_id, :kind, :rev, :refusal])
    |> validate_required([:op_id, :kind, :rev])
    |> unique_constraint([:account_id, :op_id])
    |> tenant()
  end
end
