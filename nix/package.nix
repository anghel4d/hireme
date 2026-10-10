{
  lib,
  beamPackages,
  rustPlatform,
  esbuild,
  sqlite,
  source,
  revision,
  mixDepsHash ? "sha256-RcQOprTOZhep++nm2w6rY7kdkPdSqy3KQrTaTT7N9+M=",
}:
let
  # Only application inputs enter the store: never local databases, seed data,
  # secrets, dependency caches, or previously built assets.
  src = lib.cleanSourceWith {
    src = source;
    name = "hireme-source";
    filter =
      path: type:
      let
        relative = lib.removePrefix "${toString source}/" (toString path);
        within = directory: relative == directory || lib.hasPrefix "${directory}/" relative;
      in
      type != "symlink"
      && (
        builtins.elem relative [
          "mix.exs"
          "mix.lock"
          "priv"
          "priv/repo"
        ]
        || lib.any within [
          "config"
          "lib"
          "assets"
          "priv/repo/migrations"
          "priv/wire"
        ]
        || (
          within "priv/static"
          && !(within "priv/static/assets")
          # Of the wasm directory only the committed kernel.wasm (checked
          # against the wire schema by the tests); digests and desk.wasm are
          # build output.
          && (!(lib.hasPrefix "priv/static/wasm/" relative) || relative == "priv/static/wasm/kernel.wasm")
          && relative != "priv/static/cache_manifest.json"
        )
      );
  };

  # The WebTransport gate: a standalone crate with its own lock. Only its
  # own directory enters the store, so a change elsewhere in the app does
  # not rebuild it.
  gate = rustPlatform.buildRustPackage {
    pname = "hireme-gate";
    version = "0.1.0";
    src = lib.cleanSourceWith {
      src = source;
      name = "hireme-gate-source";
      filter =
        path: type:
        let
          relative = lib.removePrefix "${toString source}/" (toString path);
        in
        type != "symlink"
        && (
          builtins.elem relative [
            "native"
            "native/gate"
          ]
          || lib.any (d: lib.hasPrefix "native/gate/${d}" relative) [
            "Cargo.toml"
            "Cargo.lock"
            "src"
            "wtransport.patch"
          ]
        );
    };
    cargoRoot = "native/gate";
    buildAndTestSubdir = "native/gate";
    cargoLock.lockFile = source + "/native/gate/Cargo.lock";
    # Cargo hashes each crate's absolute location into its symbols, and so
    # into the code layout, and panic messages name source paths: the gate
    # is the same binary only when built at the same path. The sandbox's
    # /build is that path; refuse any other.
    preBuild = ''
      if [ "$NIX_BUILD_TOP" != /build ]; then
        echo "hireme-gate builds reproducibly only in the Nix sandbox (/build, not $NIX_BUILD_TOP)" >&2
        exit 1
      fi
    '';
    postPatch = ''
      patch -d "$cargoDepsCopy/wtransport-0.7.2" -p1 < native/gate/wtransport.patch
    '';
    # The probe example is a workstation tool and is not built here.
    cargoBuildFlags = [
      "--bin"
      "hireme-gate"
    ];
    doCheck = false;
    meta.mainProgram = "hireme-gate";
  };
in
beamPackages.mixRelease {
  pname = "hireme";
  version = "0.1.0-${builtins.substring 0 12 revision}";
  inherit src revision;
  mixEnv = "prod";
  mixReleaseName = "hireme";

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "hireme-mix-deps";
    version = builtins.substring 0 12 (builtins.hashFile "sha256" (source + "/mix.lock"));
    inherit src;
    mixEnv = "prod";
    hash = mixDepsHash;
  };

  buildInputs = [ sqlite ];

  # Build the SQLite NIF against Nix libraries instead of downloading a binary.
  env = {
    EXQLITE_USE_SYSTEM = "1";
    EXQLITE_SYSTEM_CFLAGS = "-I${sqlite.dev}/include";
    EXQLITE_SYSTEM_LDFLAGS = "-L${sqlite.out}/lib -lsqlite3";
    # One scheduler, so Elixir's parallel compiler runs its modules in one
    # order. Small maps order atom keys by atom-table index, which follows
    # the order atoms were first created, and the Erlang compiler's type pass
    # iterates such maps: two parallel builds once inferred different types
    # for Decimal and emitted different code.
    ERL_FLAGS = "+S 1:1";
  };

  postPatch = ''
    # Use the pinned nixpkgs esbuild, without the Mix task's network installer.
    substituteInPlace config/config.exs \
      --replace-fail 'version: "0.25.4",' \
        'version: "${lib.getVersion esbuild}", path: "${lib.getExe esbuild}",'
  '';

  # The digester stamps every cache_manifest.json entry with the build's
  # clock (gregorian seconds; only `phx.digest.clean` reads it). Pin it to
  # SOURCE_DATE_EPOCH so the manifest is a function of the sources.
  postBuild = ''
    mix do deps.loadpaths --no-deps-check, assets.deploy
    sed -i -E "s/\"mtime\":[0-9]+/\"mtime\":$((62167219200 + SOURCE_DATE_EPOCH))/g" priv/static/cache_manifest.json
  '';

  # One profile carries both programs, so a deploy flips them together.
  postInstall = ''
    install -Dm755 ${lib.getExe gate} $out/bin/hireme-gate
  '';

  passthru = { inherit gate; };

  # RELEASE_COOKIE is supplied at runtime, outside the public Nix store.
  removeCookie = true;

  meta = {
    description = "Account-isolated job application desk";
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
    mainProgram = "hireme";
  };
}
