{
  description = "Hireme: the release, hireme-mcp, kernel.wasm, the NixOS module, and the checks that prove them";

  # A host imports nixosModules.hireme with `inputs.hireme.inputs.nixpkgs.follows
  # = "nixpkgs"` and names its addresses; everything builds from this lock.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      # The release is not under a free licence, and says so.
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      lib = pkgs.lib;

      # The latest esbuild; the pin ships 0.27.2 and no 0.28 attribute.
      esbuild = pkgs.esbuild.overrideAttrs (o: {
        version = "0.28.2";
        src = pkgs.fetchurl {
          url = "https://github.com/evanw/esbuild/archive/v0.28.2.tar.gz";
          hash = "sha256-MAFi+Jk2HZ8CYwZfhyjvkIbc/Bo9Nry8Tgq+XenFi/g=";
        };
        vendorHash = "sha256-+BfxCyg0KkDQpHt/wycy/8CTG6YBA/VJvJFhhzUnSiQ=";
      });

      beamPackages = pkgs.beam.packages.erlang_28.overrideScope (_: prev: { elixir = prev.elixir_1_20; });

      hireme = pkgs.callPackage ./nix/package.nix {
        inherit esbuild beamPackages;
        source = ./.;
        revision = self.rev or self.dirtyRev or "dirty";
      };
    in
    {
      packages.${system} = {
        inherit hireme;
        default = hireme;
        hireme-mcp = pkgs.runCommand "hireme-mcp-${hireme.version}" { meta.mainProgram = "hireme-mcp"; } ''
          install -Dm755 ${hireme.native}/bin/hireme-mcp $out/bin/hireme-mcp
        '';
        kernel-wasm = hireme.kernel-wasm;
      };

      nixosModules.hireme = import ./nix/module.nix { inherit self; };

      checks.${system} = {
        # Every suite the repository has, offline in the sandbox: mix test
        # (its own database per run), cargo test over the workspace, the
        # kernel's vectors under wasm, and tsc.
        unit = pkgs.stdenv.mkDerivation {
          name = "hireme-unit";
          src = ./.;
          cargoDeps = pkgs.rustPlatform.importCargoLock { lockFile = ./native/Cargo.lock; };
          cargoRoot = "native";
          mixDeps = beamPackages.fetchMixDeps {
            pname = "hireme-test-deps";
            version = builtins.substring 0 12 (builtins.hashFile "sha256" ./mix.lock);
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./mix.exs
                ./mix.lock
              ];
            };
            mixEnv = "test";
            hash = "sha256-h2/YtCpmbUZmxaBnDiG2l1ZSeONx4hXEwtjhV4SWYX4=";
          };
          nativeBuildInputs = [
            beamPackages.elixir
            beamPackages.erlang
            beamPackages.hex
            pkgs.rustPlatform.cargoSetupHook
            pkgs.cargo
            pkgs.rustc
            pkgs.lld
            pkgs.nodejs
            pkgs.sqlite
            pkgs.typescript
            esbuild
          ];
          env = {
            MIX_ENV = "test";
            EXQLITE_USE_SYSTEM = "1";
            EXQLITE_SYSTEM_CFLAGS = "-I${pkgs.sqlite.dev}/include";
            EXQLITE_SYSTEM_LDFLAGS = "-L${pkgs.sqlite.out}/lib -lsqlite3";
            LANG = "C.UTF-8";
          };
          buildPhase = ''
            export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex HEX_OFFLINE=1
            cp -r --no-preserve=mode $mixDeps deps
            (cd native && cargo test --offline --workspace --release)
            (cd native && cargo rustc --offline -p kernel --lib --release --target wasm32-unknown-unknown --crate-type cdylib)
            node native/kernel/vectors.mjs native/target/wasm32-unknown-unknown/release/kernel.wasm
            mix test
            tsc -p assets/tsconfig.json --noEmit
          '';
          installPhase = "touch $out";
        };

        # The dev profile: the module on a VM with generated secrets and a
        # self-signed gate; the node applies its schema at boot, backs up,
        # supervises the gate, and keeps its data across a restart.
        dev = pkgs.testers.runNixOSTest {
          name = "hireme-dev";
          nodes.machine = {
            imports = [ self.nixosModules.hireme ];
            virtualisation.memorySize = 2048;
            environment.systemPackages = [
              pkgs.sqlite
              pkgs.psmisc
            ];
            services.hireme = {
              enable = true;
              domain = "localhost";
              environmentFile = "/var/lib/hireme-dev/env";
              gate = {
                enable = true;
                listen = "127.0.0.1:4433";
                url = "https://127.0.0.1:4433/wt";
                origins = [ "http://localhost:4000" ];
              };
            };
            systemd.services.hireme-dev-secrets = {
              wantedBy = [ "hireme.service" ];
              before = [ "hireme.service" ];
              serviceConfig.Type = "oneshot";
              path = [ pkgs.openssl ];
              script = ''
                install -d -m 0700 /var/lib/hireme-dev
                [ -s /var/lib/hireme-dev/env ] || {
                  umask 077
                  echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')"
                  echo "RELEASE_COOKIE=$(openssl rand -hex 32)"
                  echo "CLOUDFLARE_ACCOUNT_ID=dev"
                  echo "CLOUDFLARE_EMAIL_TOKEN=dev"
                } > /var/lib/hireme-dev/env
              '';
            };
          };
          testScript = ''
            machine.wait_for_unit("hireme.service")
            machine.wait_for_open_port(4000)
            machine.succeed("curl -sf -o /dev/null http://127.0.0.1:4000/sign-in")

            # The node applied the baseline at boot and took its first backup.
            machine.succeed("sqlite3 /var/lib/hireme/hireme.db \"select name from schema_files\" | grep -qx 0000_baseline")
            machine.succeed("sqlite3 /var/lib/hireme/hireme.db 'select count(*) from accounts'")
            machine.wait_until_succeeds("ls /var/lib/hireme/backups/hireme-*.db")

            # The page ships the kernel the release was built with.
            machine.succeed("curl -sf -o /dev/null http://127.0.0.1:4000/wasm/kernel.wasm")

            # The gate is the node's child, on a high port, as the node's user,
            # with no capability, pinned by hash.
            machine.wait_until_succeeds("ss -Hulpn 'sport = :4433' | grep -q hireme-gate")
            gate = machine.succeed("ps -o user= -p $(pgrep hireme-gate)").split()
            node = machine.succeed("systemctl show -P MainPID hireme").strip()
            assert gate[0] == "hireme", f"the gate runs as {gate[0]}"
            caps = machine.succeed("grep CapEff /proc/$(pgrep hireme-gate)/status").split()[1]
            assert int(caps, 16) == 0, f"the gate holds capabilities {caps}"
            machine.succeed(f"pstree -p {node} | grep -q hireme-gate")
            machine.succeed("grep -Eq '^[0-9a-f]{64}$' /run/hireme/gate.hash")

            # A gate that dies is started again by the node.
            old = machine.succeed("pgrep hireme-gate").strip()
            machine.succeed(f"kill -9 {old}")
            machine.wait_until_succeeds(f"pgrep hireme-gate | grep -vx {old}")

            # Stopping the node stops the gate; restarting keeps the data and
            # applies nothing twice.
            machine.succeed("systemctl stop hireme")
            machine.fail("pgrep hireme-gate")
            machine.succeed("systemctl start hireme")
            machine.wait_for_open_port(4000)
            machine.succeed("test $(sqlite3 /var/lib/hireme/hireme.db 'select count(*) from schema_files where name = \"0000_baseline\"') = 1")
            machine.wait_until_succeeds("ss -Hulpn 'sport = :4433' | grep -q hireme-gate")
          '';
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          beamPackages.elixir
          beamPackages.erlang
          pkgs.cargo
          pkgs.rustc
          pkgs.clippy
          pkgs.nodejs
          pkgs.sqlite
          pkgs.typescript
          esbuild
        ];
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
