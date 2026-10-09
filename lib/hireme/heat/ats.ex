defmodule Hireme.Heat.Ats do
  @moduledoc """
  Infer ATS vendor and tenant from an apply URL host and path.

  Closed vendor set. Unknown hosts are `:unknown` with no tenant, so they
  do not trip the vendor governor.
  """

  # Ordered like the original recognizers. A leading dot means subdomains only.
  @hosts [
    greenhouse: ["greenhouse.io", ".greenhouse.net"],
    lever: ["lever.co"],
    ashby: ["ashbyhq.com"],
    workday: [:workday],
    icims: ["icims.com"],
    smartrecruiters: ["smartrecruiters.com"],
    workable: ["workable.com"],
    jobvite: ["jobvite.com"],
    taleo: ["taleo.net"],
    successfactors: [".successfactors.com", ".successfactors.eu", ".sapsf.com", ".sapsf.eu"],
    bamboohr: ["bamboohr.com"],
    rippling: [".rippling.com"],
    eightfold: [".eightfold.ai"],
    gem: ["gem.com"]
  ]
  @vendors Keyword.keys(@hosts) ++ [:unknown]
  @roots Map.new(@hosts, fn {vendor, [root | _]} -> {vendor, root} end)

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

  @spec name(vendor()) :: String.t()
  def name(vendor) when vendor in @vendors, do: Atom.to_string(vendor)

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
    vendor =
      Enum.find_value(@hosts, :unknown, fn {vendor, roots} ->
        if Enum.any?(roots, &host?(host, &1)), do: vendor
      end)

    %{vendor: vendor, tenant: tenant(vendor, host, path)}
  end

  defp host?(host, :workday) do
    String.contains?(host, "myworkdayjobs.com") or String.contains?(host, "myworkday.com") or
      String.ends_with?(host, ".wd1.myworkdaysite.com")
  end

  defp host?(host, "." <> _ = suffix), do: String.ends_with?(host, suffix)
  defp host?(host, root), do: host == root or String.ends_with?(host, "." <> root)

  defp tenant(:greenhouse, host, path) do
    first_segment(path) || subdomain(host, "greenhouse.io") || subdomain(host, "greenhouse.net")
  end

  defp tenant(vendor, host, path) when vendor in [:lever, :ashby, :workable],
    do: first_segment(path) || subdomain(host, @roots[vendor])

  defp tenant(vendor, _host, path) when vendor in [:smartrecruiters, :jobvite, :rippling, :gem],
    do: first_segment(path)

  defp tenant(vendor, host, _path) when vendor in [:taleo, :bamboohr, :eightfold],
    do: subdomain(host, String.trim_leading(@roots[vendor], "."))

  defp tenant(:workday, host, path), do: workday_tenant(host, path)
  defp tenant(:icims, host, _path), do: icims_tenant(host)
  defp tenant(:successfactors, host, _path), do: sf_tenant(host)
  defp tenant(:unknown, _host, _path), do: nil

  defp workday_tenant(host, path) do
    cond do
      match = Regex.run(re(:workday_wd), host) ->
        Enum.at(match, 1)

      match = Regex.run(re(:workday_host), host) ->
        Enum.at(match, 1)

      true ->
        first_segment(path)
    end
  end

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

  defp sf_tenant(host) do
    host
    |> String.replace(re(:successfactors), "")
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

  # OTP 28 cannot keep a compiled regex in a module literal, so a `~r`
  # here compiles again on every parse, and a heat snapshot parses every
  # hot job's URL. Each pattern is compiled once per VM instead.
  @patterns %{
    workday_wd: ~S"\A([a-z0-9-]+)\.wd\d+\.",
    workday_host: ~S"\A([a-z0-9-]+)\.(?:myworkdayjobs|myworkday)\.com\z",
    successfactors: ~S"\.(successfactors|sapsf)\.(com|eu)\z"
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
end
