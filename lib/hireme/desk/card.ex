defmodule Hireme.Desk.Card do
  @moduledoc """
  What the board shows for one application. No listing text, no document.
  The query selects straight into this struct. Company load, cap, and
  heat state are painted after fetch — they are not columns.
  """

  alias Hireme.Pipeline

  @enforce_keys [
    :id,
    :company,
    :role,
    :location,
    :heat,
    :status,
    :stage,
    :pips,
    :cv_label,
    :profile_name,
    :profile_slug,
    :keyword_hits,
    :keyword_total,
    :mask_hidden,
    :mask_altered,
    :mask_emphasized,
    :next_action,
    :next_due,
    :stage_on,
    :batch_code,
    :batch_fire,
    :batch_ordinal,
    :freshness,
    :gate,
    :fit,
    :score_100
  ]
  defstruct @enforce_keys ++
              [
                listing_url: "",
                canonical_url: "",
                department: "",
                squad: "",
                heat_override: false,
                heat_override_reason: "",
                load: 0.0,
                cap: 1.0,
                heat_state: :cool,
                ats_vendor: :unknown,
                cooldown_days: nil
              ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          company: String.t(),
          role: String.t(),
          location: String.t(),
          heat: 1..5,
          status: atom(),
          stage: Pipeline.stage(),
          pips: String.t(),
          cv_label: String.t(),
          profile_name: String.t(),
          profile_slug: String.t(),
          keyword_hits: non_neg_integer(),
          keyword_total: non_neg_integer(),
          mask_hidden: non_neg_integer(),
          mask_altered: non_neg_integer(),
          mask_emphasized: non_neg_integer(),
          next_action: String.t(),
          next_due: Date.t() | nil,
          stage_on: Date.t() | nil,
          batch_code: String.t() | nil,
          batch_fire: :hold | :open_fire | nil,
          batch_ordinal: non_neg_integer() | nil,
          freshness: atom(),
          gate: atom(),
          fit: String.t(),
          score_100: Hireme.LifeEv.score(),
          listing_url: String.t(),
          canonical_url: String.t(),
          department: String.t(),
          squad: String.t(),
          heat_override: boolean(),
          heat_override_reason: String.t(),
          load: float(),
          cap: float(),
          heat_state: :cool | :warm | :hot | :blocked,
          ats_vendor: atom(),
          cooldown_days: non_neg_integer() | nil
        }

  @doc """
  Board order: highest `score_100` first, then cooler company load, then
  batch, then rung, then interest heat, then company.
  """
  @spec order(t()) ::
          {integer(), integer(), non_neg_integer(), non_neg_integer(), integer(), String.t()}
  def order(%__MODULE__{} = card) do
    ratio = if card.cap <= 0, do: 100, else: round(card.load / card.cap * 100)

    {-card.score_100, ratio, card.batch_ordinal || 999, Pipeline.rank(card.stage), -card.heat,
     card.company}
  end
end

defmodule Hireme.Desk.Placed do
  @moduledoc false
  @enforce_keys [:card, :x, :y]
  defstruct [:card, :x, :y]

  @type t :: %__MODULE__{card: Hireme.Desk.Card.t(), x: integer(), y: integer()}
end
