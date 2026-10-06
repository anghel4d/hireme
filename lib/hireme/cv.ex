defmodule Hireme.Cv do
  @moduledoc """
  Folds resolved lines into the document a reader sees.

  Facts sit in the masthead. Experience, projects, education, skills, and
  timeline follow. Hidden lines stay on the document as a masked tray so
  the battleplan can put them back.
  """

  @sections [
    {:experience, "Experience"},
    {:project, "Projects"},
    {:education, "Education"},
    {:skill, "Skills"},
    {:timeline, "Timeline"}
  ]

  def compose(profile, resolved, variant, opts \\ []) do
    theme = theme_of(variant)
    lead = string_key(theme, "lead")
    summary = if lead == "", do: profile.summary, else: lead

    shown = Enum.filter(resolved, & &1.shown)
    hidden = Enum.filter(resolved, &(not &1.shown))

    %{
      label: variant_label(variant),
      person: Keyword.get(opts, :person),
      headline: profile.headline,
      summary: summary,
      summary_canonical: if(summary == profile.summary, do: nil, else: profile.summary),
      summary_reason: blank_nil(string_key(theme, "lead_reason")),
      accent: theme_choice(theme, "accent", "ink"),
      density: theme_choice(theme, "density", "cv"),
      facts: Enum.filter(shown, &(&1.kind == :fact)),
      sections: sections(shown),
      hidden: hidden
    }
  end

  defp sections(shown) do
    Enum.flat_map(@sections, fn {kind, label} ->
      lines = Enum.filter(shown, &(&1.kind == kind))

      if lines == [] do
        []
      else
        [%{kind: kind, label: label, lines: lines}]
      end
    end)
  end

  defp theme_of(%{theme: theme}) when is_map(theme), do: theme
  defp theme_of(_), do: %{}

  defp variant_label(%{label: label}) when is_binary(label) and label != "", do: label
  defp variant_label(_), do: "CV"

  defp theme_choice(theme, key, default) do
    case string_key(theme, key) do
      "" -> default
      value -> value
    end
  end

  defp string_key(theme, key) do
    case Map.get(theme, key) || Map.get(theme, String.to_atom(key)) do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
