# The three things Hireme ships, from one source tree and one Cargo lock:
# the OTP release (with the kernel NIF and the gate inside it), hireme-mcp,
# and kernel.wasm. Nothing they build is committed to the repository.
{
  lib,
  beamPackages,
  rustPlatform,
  esbuild,
  sqlite,
  lld,
  source,
  revision,
  mixDepsHash ? "sha256-wh1q2KvQYDCdk/lsD8d6eV58J/0R8TDgct9dn1eRcdE=",
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

  # The Rust half reads the declaration (native/schema include_str!s it).
  nativeSrc = only "hireme-native" [
    "native"
    "schema/hireme.schema"
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

  # The gate, hireme-mcp and the NIF share one dependency build.
  native = rustPlatform.buildRustPackage (
    cargo
    // {
      pname = "hireme-native";
      inherit version;
      # The gate's fixes to the latest wtransport: 0.5-RTT SETTINGS, and
      # closing handshakes a client abandons.
      postPatch = ''
        patch -d "$cargoDepsCopy"/wtransport-0.7.2 -p1 < native/gate/wtransport.patch
      '';
      cargoBuildFlags = [
        "-p"
        "gate"
        "-p"
        "hireme-mcp"
        "-p"
        "nif"
      ];
      doCheck = false;
      installPhase = ''
        runHook preInstall
        release=$(dirname "$(find native/target -path '*/release/hireme-mcp' -type f | head -1)")
        install -Dm755 "$release/hireme-gate" $out/bin/hireme-gate
        install -Dm755 "$release/hireme-mcp" $out/bin/hireme-mcp
        install -Dm644 "$release/libnif.so" $out/lib/libnif.so
        runHook postInstall
      '';
    }
  );

  kernel-wasm = rustPlatform.buildRustPackage (
    cargo
    // {
      pname = "kernel-wasm";
      inherit version;
      # rustc links wasm32 with lld.
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
      "priv/db"
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
      # One scheduler, so the parallel compiler creates atoms in one order:
      # small maps order atom keys by creation, the type pass iterates them,
      # and two builds once emitted different code for one module.
      ERL_FLAGS = "+S 1:1";
    };

    postPatch = ''
      # The pinned esbuild, without the Mix task's network installer.
      substituteInPlace config/config.exs \
        --replace-fail 'version: "0.28.2",' 'version: "${lib.getVersion esbuild}", path: "${lib.getExe esbuild}",'
      install -Dm644 ${native}/lib/libnif.so priv/native/libnif.so
      install -Dm644 ${kernel-wasm}/kernel.wasm priv/static/wasm/kernel.wasm
    '';

    # The digester stamps the manifest with the build's clock; pin it to
    # SOURCE_DATE_EPOCH so the manifest is a function of the sources.
    postBuild = ''
      mix do deps.loadpaths --no-deps-check, assets.deploy
      sed -i -E "s/\"mtime\":[0-9]+/\"mtime\":$((62167219200 + SOURCE_DATE_EPOCH))/g" priv/static/cache_manifest.json
    '';

    # One profile carries the node and its gate, so a deploy flips both.
    postInstall = ''
      install -Dm755 ${native}/bin/hireme-gate $out/bin/hireme-gate
    '';

    # RELEASE_COOKIE comes at runtime, outside the public store.
    removeCookie = true;

    passthru = { inherit native kernel-wasm; };

    meta = {
      description = "Account-isolated job campaign desk";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
      mainProgram = "hireme";
    };
  };
in
release
