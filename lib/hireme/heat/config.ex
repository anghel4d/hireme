defmodule Hireme.Heat.Config do
  @moduledoc """
  Caps, half-lives, size tiers, and ATS overrides for the heat governor.

  Defaults are the standing order. Documented in `alchemy/heat.md`.
  A test may pass a struct; the desk uses `Hireme.Heat.Config.defaults/0`.
  """

  @enforce_keys [
    :company_half_life,
    :ats_vendor_half_life,
    :ats_tenant_half_life,
    :application_load,
    :same_department_penalty,
    :clone_penalty,
    :mega_cap,
    :large_cap,
    :mid_cap,
    :small_cap,
    :ats_vendor_cap,
    :ats_tenant_cap,
    :ats_batch_cap,
    :cool_ratio,
    :hot_ratio
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          company_half_life: pos_integer(),
          ats_vendor_half_life: pos_integer(),
          ats_tenant_half_life: pos_integer(),
          application_load: float(),
          same_department_penalty: float(),
          clone_penalty: float(),
          mega_cap: float(),
          large_cap: float(),
          mid_cap: float(),
          small_cap: float(),
          ats_vendor_cap: float(),
          ats_tenant_cap: float(),
          ats_batch_cap: pos_integer(),
          cool_ratio: float(),
          hot_ratio: float()
        }

  @spec defaults() :: t()
  def defaults do
    %__MODULE__{
      # Days to lose half the company load. 30–45 window; 35 is the middle.
      company_half_life: 35,
      # Vendor-level ATS profiling across companies.
      ats_vendor_half_life: 14,
      # One Workday/Greenhouse tenant is usually one employer.
      ats_tenant_half_life: 21,
      # One queued/submitted/rejected application.
      application_load: 1.0,
      # Same department at one company is hotter than spreading orgs.
      same_department_penalty: 0.6,
      # Near-identical titles (same role family) stack worse than distinct tracks.
      clone_penalty: 0.6,
      # Google / Amazon / Meta / NVIDIA / Microsoft: a few roles if different orgs.
      mega_cap: 4.0,
      # Other big tech, labs, frontier.
      large_cap: 2.5,
      mid_cap: 1.5,
      # Default. One seat, maybe two after decay.
      small_cap: 1.0,
      # Decaying vendor cap so one ATS is not the whole campaign.
      ats_vendor_cap: 40.0,
      # Per-tenant cap (often one company).
      ats_tenant_cap: 3.0,
      # Hard mix: one day pack does not slam a single vendor.
      ats_batch_cap: 20,
      cool_ratio: 0.5,
      hot_ratio: 0.8
    }
  end
end
