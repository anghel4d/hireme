defmodule Hireme.Heat.Ats do
  @moduledoc """
  Infer ATS vendor and tenant from an apply URL host and path.

  Closed vendor set. Unknown hosts are `:unknown` with no tenant, so they
  do not trip the vendor governor.
  """

  @vendors [
    :greenhouse,
    :lever,
    :ashby,
    :workday,
    :icims,
    :smartrecruiters,
    :workable,
    :jobvite,
    :taleo,
    :successfactors,
    :bamboohr,
    :rippling,
    :eightfold,
    :gem,
    :unknown
  ]

  @by_name Map.new(@vendors, &{Atom.to_string(&1), &1})

  @type vendor ::
          :greenhouse
          | :lever
          | :ashby
          | :workday
          | :icims
          | :smartrecruiters
          | :workable
          | :jobvite
          | :taleo
          | :successfactors
          | :bamboohr
          | :rippling
          | :eightfold
          | :gem
          | :unknown

  @type t :: %{vendor: vendor(), tenant: String.t() | nil}

  @spec vendors() :: [vendor()]
  def vendors, do: @vendors

  @spec name(vendor()) :: String.t()
  def name(vendor) when vendor in @vendors, do: Atom.to_string(vendor)

  @spec parse_vendor(term()) :: {:ok, vendor()} | :error
  def parse_vendor(vendor) when vendor in @vendors, do: {:ok, vendor}

  def parse_vendor(name) when is_binary(name) do
    case Map.fetch(@by_name, name) do
      {:ok, vendor} -> {:ok, vendor}
      :error -> :error
    end
  end

  def parse_vendor(_), do: :error

  @spec parse(term()) :: t()
  def parse(url) when is_binary(url) and url != "" do
    case URI.parse(String.trim(url)) do
      %URI{host: host} = uri when is_binary(host) ->
        host = String.downcase(host)
        path = uri.path || ""
        from_host_path(host, path)

      _ ->
        unknown()
    end
  end

  def parse(_), do: unknown()

  defp from_host_path(host, path) do
    cond do
      greenhouse?(host) ->
        %{vendor: :greenhouse, tenant: greenhouse_tenant(host, path)}

      lever?(host) ->
        %{vendor: :lever, tenant: first_segment(path) || subdomain(host, "lever.co")}

      ashby?(host) ->
        %{vendor: :ashby, tenant: first_segment(path) || subdomain(host, "ashbyhq.com")}

      workday?(host) ->
        %{vendor: :workday, tenant: workday_tenant(host, path)}

      icims?(host) ->
        %{vendor: :icims, tenant: icims_tenant(host)}

      smartrecruiters?(host) ->
        %{vendor: :smartrecruiters, tenant: first_segment(path)}

      workable?(host) ->
        %{vendor: :workable, tenant: first_segment(path) || subdomain(host, "workable.com")}

      jobvite?(host) ->
        %{vendor: :jobvite, tenant: first_segment(path)}

      taleo?(host) ->
        %{vendor: :taleo, tenant: subdomain(host, "taleo.net")}

      successfactors?(host) ->
        %{vendor: :successfactors, tenant: sf_tenant(host)}

      bamboohr?(host) ->
        %{vendor: :bamboohr, tenant: subdomain(host, "bamboohr.com")}

      String.ends_with?(host, ".rippling.com") or host == "ats.rippling.com" ->
        %{vendor: :rippling, tenant: first_segment(path)}

      String.ends_with?(host, ".eightfold.ai") ->
        %{vendor: :eightfold, tenant: subdomain(host, "eightfold.ai")}

      host in ["jobs.gem.com", "gem.com"] or String.ends_with?(host, ".gem.com") ->
        %{vendor: :gem, tenant: first_segment(path)}

      true ->
        unknown()
    end
  end

  defp greenhouse?(host) do
    host in ["boards.greenhouse.io", "job-boards.greenhouse.io", "greenhouse.io"] or
      String.ends_with?(host, ".greenhouse.io") or String.ends_with?(host, ".greenhouse.net")
  end

  defp greenhouse_tenant(host, path) do
    first_segment(path) || subdomain(host, "greenhouse.io") ||
      subdomain(host, "greenhouse.net")
  end

  defp lever?(host) do
    host in ["jobs.lever.co", "lever.co"] or String.ends_with?(host, ".lever.co")
  end

  defp ashby?(host) do
    host in ["jobs.ashbyhq.com", "ashbyhq.com"] or String.ends_with?(host, ".ashbyhq.com")
  end

  defp workday?(host) do
    String.contains?(host, "myworkdayjobs.com") or String.contains?(host, "myworkday.com") or
      String.ends_with?(host, ".wd1.myworkdaysite.com")
  end

  defp workday_tenant(host, path) do
    cond do
      match = Regex.run(~r/\A([a-z0-9-]+)\.wd\d+\./, host) ->
        Enum.at(match, 1)

      match = Regex.run(~r/\A([a-z0-9-]+)\.(?:myworkdayjobs|myworkday)\.com\z/, host) ->
        Enum.at(match, 1)

      true ->
        first_segment(path)
    end
  end

  defp icims?(host), do: String.ends_with?(host, ".icims.com") or host == "icims.com"

  defp icims_tenant(host) do
    host
    |> String.replace_suffix(".icims.com", "")
    |> String.replace_prefix("careers-", "")
    |> case do
      "" -> nil
      "www" -> nil
      tenant -> tenant
    end
  end

  defp smartrecruiters?(host) do
    host in ["jobs.smartrecruiters.com", "smartrecruiters.com"] or
      String.ends_with?(host, ".smartrecruiters.com")
  end

  defp workable?(host) do
    host in ["apply.workable.com", "workable.com"] or String.ends_with?(host, ".workable.com")
  end

  defp jobvite?(host) do
    host in ["jobs.jobvite.com", "jobvite.com"] or String.ends_with?(host, ".jobvite.com")
  end

  defp taleo?(host), do: String.ends_with?(host, ".taleo.net") or host == "taleo.net"

  defp bamboohr?(host), do: String.ends_with?(host, ".bamboohr.com") or host == "bamboohr.com"

  defp successfactors?(host) do
    String.ends_with?(host, ".successfactors.com") or
      String.ends_with?(host, ".successfactors.eu") or
      String.ends_with?(host, ".sapsf.com") or String.ends_with?(host, ".sapsf.eu")
  end

  defp sf_tenant(host) do
    host
    |> String.replace(~r/\.(successfactors|sapsf)\.(com|eu)\z/, "")
    |> case do
      ^host -> nil
      tenant -> tenant
    end
  end

  defp first_segment(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.find(fn seg -> seg != "" and not job_segment?(seg) end)
    |> case do
      nil -> nil
      seg -> String.downcase(seg)
    end
  end

  defp job_segment?(seg), do: String.downcase(seg) in ~w(job jobs career careers apply embed)

  defp subdomain(host, root) do
    suffix = "." <> root

    if String.ends_with?(host, suffix) do
      left = String.replace_suffix(host, suffix, "")

      left
      |> String.split(".")
      |> List.last()
      |> case do
        name when name in [nil, "", "www", "jobs", "boards", "job-boards", "apply", "ats"] -> nil
        name -> name
      end
    else
      nil
    end
  end

  defp unknown, do: %{vendor: :unknown, tenant: nil}
end
