defmodule Hireme.Heat.Org do
  @moduledoc """
  Company size tier, department, and role-family — closed atoms at the edge.

  Size is org breadth, not Life-EV. Mega employers can take a few roles
  across departments; a small shop gets one, maybe two after decay.
  Department inputs are normalized once before exact lookup or fallback inference.
  """

  import Hireme.Text, only: [normalize: 1]

  @mega ~w(google alphabet amazon aws meta facebook nvidia microsoft)
  @large ~w(
    apple netflix uber stripe databricks snowflake tesla adobe salesforce oracle
    linkedin snap pinterest shopify openai anthropic spacex neuralink xai
    starfish valve gdm deepmind ssi mira
  )
  @mega_names MapSet.new(@mega)
  @large_names MapSet.new(@large)

  @type size :: :mega | :large | :mid | :small

  @type family ::
          :software_engineer
          | :research_engineer
          | :research_scientist
          | :sre
          | :data_engineer
          | :security_engineer
          | :other

  @type department :: :infra | :research | :security | :data | :product | :eng | :other

  @spec size(term()) :: size()
  def size(company) when is_binary(company) do
    name = normalize(company)
    # All size anchors are single words. Check each word and the compact name
    # once, rather than rebuilding a compact/padded anchor for every employer.
    names = [String.replace(name, " ", "") | String.split(name, " ", trim: true)]

    cond do
      Enum.any?(names, &MapSet.member?(@mega_names, &1)) -> :mega
      Enum.any?(names, &MapSet.member?(@large_names, &1)) -> :large
      name =~ re(:mid) -> :mid
      true -> :small
    end
  end

  def size(_), do: :small

  @spec department(map() | struct()) :: department()
  def department(job) when is_map(job) or is_struct(job) do
    explicit = field(job, :department)

    if explicit != "" do
      parse_department(explicit)
    else
      blob = "#{field(job, :role)} #{field(job, :squad)} #{field(job, :fit)}"
      infer_department(normalize(blob))
    end
  end

  @spec family(map() | struct()) :: family()
  def family(job) when is_map(job) or is_struct(job) do
    infer_family(field(job, :role))
  end

  @spec company_key(term()) :: String.t()
  def company_key(name) when is_binary(name), do: normalize(name)
  def company_key(_), do: ""

  defp parse_department(value) do
    n = normalize(value)

    cond do
      n in ~w(infra infrastructure sre platform runtime kernel systems) -> :infra
      n in ~w(research ml science ai) -> :research
      n in ~w(security privacy) -> :security
      n in ~w(data analytics) -> :data
      n in ~w(product frontend mobile web) -> :product
      n in ~w(eng engineering) -> :eng
      true -> infer_department(n)
    end
  end

  defp infer_department(n) do
    cond do
      n =~ re(:research) ->
        :research

      n =~ re(:infra) ->
        :infra

      n =~ re(:security) ->
        :security

      n =~ re(:data) ->
        :data

      n =~ re(:product) ->
        :product

      n =~ re(:eng) ->
        :eng

      true ->
        :other
    end
  end

  defp infer_family(role) do
    n =
      role
      |> normalize()
      |> String.replace(
        re(:seniority),
        " "
      )
      |> String.replace(re(:spaces), " ")
      |> String.trim()

    cond do
      n =~ re(:research_scientist) -> :research_scientist
      n =~ re(:research_engineer) -> :research_engineer
      n =~ re(:sre) -> :sre
      n =~ re(:data_engineer) -> :data_engineer
      n =~ re(:security_engineer) -> :security_engineer
      n =~ re(:software_engineer) -> :software_engineer
      true -> :other
    end
  end

  # OTP 28 cannot keep a compiled regex in a module literal, so a `~r`
  # here is compiled again on every call (about 20 µs each, and a card
  # paints with several). Each pattern is compiled once per VM instead.
  @patterns %{
    mid: ~S"\b(systems|runtime|infra|labs?)\b",
    research: ~S"\b(research|scientist|machine learning|\bml\b|applied sci)",
    infra: ~S"\b(sre|site reliability|infra|infrastructure|platform|runtime|kernel|systems)",
    security: ~S"\b(security|privacy)",
    data: ~S"\b(data engineer|analytics|data platform)",
    product: ~S"\b(frontend|front end|ios|android|mobile|product engineer)",
    eng: ~S"\b(engineer|developer|swe)",
    seniority:
      ~S"\b(staff|senior|sr|principal|distinguished|fellow|junior|jr|intern|iii|ii|\bi\b|l[3-8])\b",
    spaces: ~S"\s+",
    research_scientist: ~S"\bresearch scientist|applied scientist",
    research_engineer: ~S"\bresearch engineer",
    sre: ~S"\b(site reliability|sre)\b",
    data_engineer: ~S"\bdata engineer",
    security_engineer: ~S"\bsecurity engineer",
    software_engineer: ~S"\b(software engineer|swe|engineer|developer)"
  }

  defp re(key) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil ->
        regex = Regex.compile!(Map.fetch!(@patterns, key))
        :persistent_term.put({__MODULE__, key}, regex)
        regex

      regex ->
        regex
    end
  end

  defp field(job, key) do
    case Map.get(job, key) || Map.get(job, Atom.to_string(key)) do
      s when is_binary(s) -> String.trim(s)
      _ -> ""
    end
  end
end
