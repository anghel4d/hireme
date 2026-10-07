defmodule Hireme.Heat.Org do
  @moduledoc """
  Company size tier, department, and role-family — closed atoms at the edge.

  Size is org breadth, not Life-EV. Mega employers can take a few roles
  across departments; a small shop gets one, maybe two after decay.
  """

  @sizes [:mega, :large, :mid, :small]
  @size_names Map.new(@sizes, &{Atom.to_string(&1), &1})

  @mega ~w(google alphabet amazon aws meta facebook nvidia microsoft)
  @large ~w(
    apple netflix uber stripe databricks snowflake tesla adobe salesforce oracle
    linkedin snap pinterest shopify openai anthropic spacex neuralink xai
    starfish valve gdm deepmind ssi mira
  )

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

  @spec sizes() :: [size()]
  def sizes, do: @sizes

  @spec name(atom()) :: String.t()
  def name(key) when is_atom(key), do: Atom.to_string(key)

  @spec parse_size(term()) :: {:ok, size()} | :error
  def parse_size(size) when size in @sizes, do: {:ok, size}

  def parse_size(name) when is_binary(name) do
    case Map.fetch(@size_names, name) do
      {:ok, size} -> {:ok, size}
      :error -> :error
    end
  end

  def parse_size(_), do: :error

  @spec size(term()) :: size()
  def size(company) when is_binary(company) do
    n = normalize(company)

    cond do
      named?(n, @mega) -> :mega
      named?(n, @large) -> :large
      n =~ ~r/\b(systems|runtime|infra|labs?)\b/ -> :mid
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
      infer_department(blob)
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

  defp infer_department(blob) do
    n = normalize(blob)

    cond do
      n =~ ~r/\b(research|scientist|machine learning|\bml\b|applied sci)/ ->
        :research

      n =~ ~r/\b(sre|site reliability|infra|infrastructure|platform|runtime|kernel|systems)/ ->
        :infra

      n =~ ~r/\b(security|privacy)/ ->
        :security

      n =~ ~r/\b(data engineer|analytics|data platform)/ ->
        :data

      n =~ ~r/\b(frontend|front end|ios|android|mobile|product engineer)/ ->
        :product

      n =~ ~r/\b(engineer|developer|swe)/ ->
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
        ~r/\b(staff|senior|sr|principal|distinguished|fellow|junior|jr|intern|iii|ii|\bi\b|l[3-8])\b/,
        " "
      )
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      n =~ ~r/\bresearch scientist|applied scientist/ -> :research_scientist
      n =~ ~r/\bresearch engineer/ -> :research_engineer
      n =~ ~r/\b(site reliability|sre)\b/ -> :sre
      n =~ ~r/\bdata engineer/ -> :data_engineer
      n =~ ~r/\bsecurity engineer/ -> :security_engineer
      n =~ ~r/\b(software engineer|swe|engineer|developer)/ -> :software_engineer
      true -> :other
    end
  end

  defp named?(n, anchors) do
    compact = String.replace(n, " ", "")

    Enum.any?(anchors, fn anchor ->
      n == anchor or compact == String.replace(anchor, " ", "") or
        String.contains?(" #{n} ", " #{anchor} ")
    end)
  end

  defp normalize(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  defp field(job, key) do
    case Map.get(job, key) || Map.get(job, Atom.to_string(key)) do
      s when is_binary(s) -> String.trim(s)
      _ -> ""
    end
  end
end
