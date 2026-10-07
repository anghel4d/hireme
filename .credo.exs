# Credo reads this over its defaults. The desk keeps a decision table as
# one flat function, names JSON-RPC codes as the protocol writes them,
# and documents the row modules once at the head of schema.ex.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{included: ["lib/", "test/", "config/", "priv/repo/"]},
      checks: %{
        extra: [
          {Credo.Check.Readability.ModuleDoc, files: %{excluded: ["lib/hireme/schema.ex"]}},
          {Credo.Check.Readability.LargeNumbers, only_greater_than: 99_999}
        ],
        disabled: [
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []}
        ]
      }
    }
  ]
}
