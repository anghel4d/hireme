# What Hireme ships, from one source tree and one Cargo lock: the OTP
# release (with the kernel NIF inside it; MCP is served by the
# node), kernel.wasm, and hireme-mcp, the local daemon an operator's agents
# reach the node through. Nothing they build is committed to the repository,
# nor are the declaration's outputs (schema/build.exs emits them in the
# release build from the hireme-schema binary built here).
{
  lib,
  beamPackages,
  rustPlatform,
  bun,
  sqlite,
  lld,
  source,
  revision,
  mixDepsHash ? "sha256-aorRNC9G0Qr4LN+c5vNXyG/i69gqTJVOgdTEh9RIKuw=",
}:
let
  version = "0.2.0-${builtins.substring 0 12 revision}";

  # Only what a path list names enters the store: never local databases,
  # seed data, secrets, dependency caches or earlier build output.
  only =
    name: paths:
    lib.cleanSourceWith {
      src = source;
      inherit name;
      filter =
        path: type:
        let
          relative = lib.removePrefix "${toString source}/" (toString path);
          within = d: relative == d || lib.hasPrefix "${d}/" relative;
          above = d: lib.hasPrefix "${relative}/" d;
        in
        type != "symlink" && lib.any (d: within d || above d) paths && !(within "native/target");
    };

  # The Rust half reads the declaration (native/schema include_str!s it)
  # and embeds the zstd dictionaries (native/wire include_bytes!s them).
  nativeSrc = only "hireme-native" [
    "native"
    "schema/hireme.schema"
    "priv/wire"
  ];

  cargo = {
    src = nativeSrc;
    cargoRoot = "native";
    buildAndTestSubdir = "native";
    cargoLock.lockFile = source + "/native/Cargo.lock";
    # Cargo hashes each crate's absolute path into symbols and panic
    # messages, so a binary is the same only when built at the same path;
    # the sandbox's /build is that path.
    preBuild = ''
      if [ "$NIX_BUILD_TOP" != /build ]; then
        echo "hireme builds reproducibly only in the Nix sandbox (/build, not $NIX_BUILD_TOP)" >&2
        exit 1
      fi
    '';
  };

  # The NIF (with the MCP surface inside it) and the schema emitter share
  # one dependency build.
  native = rustPlatform.buildRustPackage (
    cargo
    // {
      pname = "hireme-native";
      inherit version;
      cargoBuildFlags = [
        "-p"
        "nif"
        "-p"
        "schema"
      ];
      doCheck = false;
      installPhase = ''
        runHook preInstall
        # buildRustPackage builds into target/<triple>/release under its own
        # target dir, wherever that is; find the binaries rather than guess.
        release=$(dirname "$(find . -path '*/release/hireme-schema' -type f -not -path '*/deps/*' | head -1)")
        install -Dm755 "$release/hireme-schema" $out/bin/hireme-schema
        install -Dm644 "$release/libnif.so" $out/lib/libnif.so
        runHook postInstall
      '';
    }
  );

  # The daemon builds on its own: in the release's cargo run its `client` feature would unify into
  # the NIF's mcp crate and compile an async runtime into the node for nothing.
  mcp-client = rustPlatform.buildRustPackage (
    cargo
    // {
      pname = "hireme-mcp";
      inherit version;
      cargoBuildFlags = [
        "-p"
        "mcp"
        "--features"
        "client"
        "--bin"
        "hireme-mcp"
      ];
      doCheck = false;
      installPhase = ''
        runHook preInstall
        install -Dm755 "$(find . -path '*/release/hireme-mcp' -type f -not -path '*/deps/*' | head -1)" $out/bin/hireme-mcp
        runHook postInstall
      '';
      meta.mainProgram = "hireme-mcp";
    }
  );

  kernel-wasm = rustPlatform.buildRustPackage (
    cargo
    // {
      pname = "kernel-wasm";
      inherit version;
      # rustc links wasm32 with lld. No wasm-opt pass: -O3's inlining made the
      # first call of a write's judge ~3 ms slower in Chromium (a fresh page's
      # heat override 7.1 -> 10.3 ms, A/B x2) for a fifth fewer bytes.
      nativeBuildInputs = [ lld ];
      buildPhase = ''
        runHook preBuild
        cd native
        cargo rustc --offline --frozen -p kernel --lib --release \
          --target wasm32-unknown-unknown --crate-type cdylib
        runHook postBuild
      '';
      doCheck = false;
      installPhase = ''
        install -Dm644 target/wasm32-unknown-unknown/release/kernel.wasm $out/kernel.wasm
      '';
    }
  );

  release = beamPackages.mixRelease {
    pname = "hireme";
    inherit version revision;
    src = only "hireme-source" [
      "mix.exs"
      "mix.lock"
      "config"
      "lib"
      "schema/hireme.schema"
      "schema/build.exs"
      "priv/db"
      "priv/wire"
      "assets"
    ];
    mixEnv = "prod";
    mixReleaseName = "hireme";

    mixFodDeps = beamPackages.fetchMixDeps {
      pname = "hireme-mix-deps";
      version = builtins.substring 0 12 (builtins.hashFile "sha256" (source + "/mix.lock"));
      src = only "hireme-mix-lock" [
        "mix.exs"
        "mix.lock"
      ];
      mixEnv = "prod";
      hash = mixDepsHash;
    };

    buildInputs = [ sqlite ];

    env = {
      # The SQLite NIF against Nix's library instead of a downloaded binary.
      EXQLITE_USE_SYSTEM = "1";
      EXQLITE_SYSTEM_CFLAGS = "-I${sqlite.dev}/include";
      EXQLITE_SYSTEM_LDFLAGS = "-L${sqlite.out}/lib -lsqlite3";
      # The kernel NIF is built above; Rustler loads it and compiles nothing.
      HIREME_NIF_PREBUILT = "1";
      # The declaration's outputs are emitted by the binary built above, not cargo.
      HIREME_SCHEMA_BIN = "${native}/bin/hireme-schema";
      # The pinned Bun bundles the browser's scripts; read at build time
      # only, so the release does not keep it in its closure.
      MIX_BUN_PATH = lib.getExe bun;
      # One scheduler, so the parallel compiler creates atoms in one order:
      # small maps order atom keys by creation, the type pass iterates them,
      # and two builds once emitted different code for one module.
      ERL_FLAGS = "+S 1:1";
    };

    postPatch = ''
      install -Dm644 ${native}/lib/libnif.so priv/native/nif.so
      install -Dm644 ${kernel-wasm}/kernel.wasm priv/static/wasm/kernel.wasm
    '';

    # The check refuses a declaration whose baseline left the frozen one
    # without a migration; then the bundle, from the generated schema.ts.
    postBuild = ''
      mix do deps.loadpaths --no-deps-check + hireme.schema --check + assets.deploy
    '';

    # RELEASE_COOKIE comes at runtime, outside the public store.
    removeCookie = true;

    passthru = { inherit native kernel-wasm mcp-client; };

    meta = {
      description = "Account-isolated job campaign desk";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
      mainProgram = "hireme";
    };
  };
in
release
