defmodule Hireme.Desk.Focus do
  @moduledoc """
  One application opened: its row, its rail, its document, and the
  coverage of the listing's words against that document and the root.
  """

  @enforce_keys [
    :job,
    :profile,
    :variant,
    :theme,
    :rail,
    :events,
    :cv,
    :narrative,
    :coverage,
    :root_coverage,
    :kv,
    :masks
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          job: Hireme.Desk.Job.t(),
          profile: Hireme.Corpus.Profile.t(),
          variant: Hireme.Desk.Variant.t(),
          theme: Hireme.Theme.t(),
          rail: Hireme.Pipeline.rail(),
          events: [Hireme.Desk.Event.t()],
          cv: Hireme.Cv.Document.t(),
          narrative: Hireme.Corpus.Narrative.t() | nil,
          coverage: Hireme.Keywords.Coverage.t(),
          root_coverage: Hireme.Keywords.Coverage.t(),
          kv: [Hireme.Kv.Pair.t()],
          masks: [Hireme.Mask.Line.t()]
        }
end

defmodule Hireme.Desk.Root do
  @moduledoc """
  A profile's root CV: every line as written, no mask.
  """

  @enforce_keys [:profile, :cv, :kv, :narrative]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          profile: Hireme.Corpus.Profile.t(),
          cv: Hireme.Cv.Document.t(),
          kv: [Hireme.Kv.Pair.t()],
          narrative: Hireme.Corpus.Narrative.t() | nil
        }
end
