defmodule Hireme.Cv.Section do
  @moduledoc false
  @enforce_keys [:kind, :label, :lines]
  defstruct [:kind, :label, :lines]

  @type t :: %__MODULE__{kind: atom(), label: String.t(), lines: [Hireme.Mask.Line.t()]}
end

defmodule Hireme.Cv.Document do
  @moduledoc """
  The CV a reader sees: masthead, sections, and the masked tray.
  """

  alias Hireme.Theme

  @enforce_keys [:label, :headline, :summary, :accent, :density, :facts, :sections, :hidden]
  defstruct [
    :label,
    :person,
    :headline,
    :summary,
    :summary_canonical,
    :summary_reason,
    :accent,
    :density,
    :facts,
    :sections,
    :hidden
  ]

  @type t :: %__MODULE__{
          label: String.t(),
          person: String.t() | nil,
          headline: String.t() | nil,
          summary: String.t() | nil,
          summary_canonical: String.t() | nil,
          summary_reason: String.t() | nil,
          accent: Theme.accent(),
          density: Theme.density(),
          facts: [Hireme.Mask.Line.t()],
          sections: [Hireme.Cv.Section.t()],
          hidden: [Hireme.Mask.Line.t()]
        }
end

defmodule Hireme.Cv do
  @moduledoc """
  Folds resolved lines into the document a reader sees.

  Facts sit in the masthead. Experience, projects, education, skills, and
  timeline follow. Hidden lines stay on the document as a masked tray so
  the battleplan can put them back.
  """

  alias Hireme.Cv.Document
  alias Hireme.Cv.Section
  alias Hireme.Mask.Line
  alias Hireme.Theme

  @sections [
    {:experience, "Experience"},
    {:project, "Projects"},
    {:education, "Education"},
    {:skill, "Skills"},
    {:timeline, "Timeline"}
  ]

  @type opts :: [label: String.t(), person: String.t() | nil]

  @spec compose(%{headline: term(), summary: term()}, [Line.t()], Theme.t(), opts()) ::
          Document.t()
  def compose(profile, resolved, %Theme{} = theme, opts \\ []) do
    summary = theme.lead || profile.summary
    {shown, hidden} = Enum.split_with(resolved, & &1.shown)

    %Document{
      label: Keyword.get(opts, :label, "CV"),
      person: Keyword.get(opts, :person),
      headline: profile.headline,
      summary: summary,
      summary_canonical: if(summary == profile.summary, do: nil, else: profile.summary),
      summary_reason: theme.lead_reason,
      accent: theme.accent,
      density: theme.density,
      facts: Enum.filter(shown, &(&1.kind == :fact)),
      sections: sections(shown),
      hidden: hidden
    }
  end

  defp sections(shown) do
    Enum.flat_map(@sections, fn {kind, label} ->
      case Enum.filter(shown, &(&1.kind == kind)) do
        [] -> []
        lines -> [%Section{kind: kind, label: label, lines: lines}]
      end
    end)
  end
end
