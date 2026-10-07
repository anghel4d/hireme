defmodule Hireme.Desk.Card do
  @moduledoc """
  What the board shows for one application. No listing text, no document.
  """

  alias Hireme.Pipeline

  @enforce_keys [
    :id,
    :code,
    :company,
    :role,
    :location,
    :heat,
    :status,
    :stage,
    :stage_label,
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
    :age,
    :batch_code,
    :batch_fire,
    :batch_ordinal,
    :freshness,
    :gate,
    :fit,
    :score_100,
    :band
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: pos_integer(),
          code: String.t(),
          company: String.t(),
          role: String.t(),
          location: String.t(),
          heat: 1..5,
          status: atom(),
          stage: Pipeline.stage(),
          stage_label: String.t(),
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
          age: non_neg_integer() | nil,
          batch_code: String.t() | nil,
          batch_fire: :hold | :open_fire | nil,
          batch_ordinal: non_neg_integer() | nil,
          freshness: atom(),
          gate: atom(),
          fit: String.t(),
          score_100: Hireme.LifeEv.score(),
          band: Hireme.LifeEv.band()
        }

  @doc """
  Board order: Life-EV first, then batch, then rung, then heat, then company.
  """
  @spec order(t()) ::
          {integer(), non_neg_integer(), non_neg_integer(), integer(), String.t()}
  def order(%__MODULE__{} = card) do
    {-card.score_100, card.batch_ordinal || 999, Pipeline.rank(card.stage), -card.heat,
     card.company}
  end
end

defmodule Hireme.Desk.Placed do
  @moduledoc """
  A card at a pixel origin inside the painted window.
  """

  @enforce_keys [:card, :x, :y]
  defstruct [:card, :x, :y]

  @type t :: %__MODULE__{card: Hireme.Desk.Card.t(), x: integer(), y: integer()}
end
