defmodule Hireme do
  @moduledoc """
  A desk for a hiring campaign.

  The root record (experience, timeline, education, facts, CV) lives in
  SQLite. Each application stores a sparse mask over that record, so
  JobApp14413 can read CV14413 without rewriting the root.
  """
end
