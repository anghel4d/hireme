{
  description = "Hireme: the release (MCP served over HTTP inside it), kernel.wasm, the NixOS module, and the checks that prove them";

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

      # The latest Bun; the pin ships 1.4.2. It bundles, type checks and runs
      # every script the repository has.
      bun = pkgs.bun.overrideAttrs (o: {
        version = "1.4.3";
        src = pkgs.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.3/bun-linux-x64-baseline.zip";
          hash = "sha256-H8LtrIQxApCeOhvh2NmALMYHHPB05n6IIx9P/g+LOXs=";
        };
      });

      # qemu for the dev VM, waiting for each vhost-user socket it is given.
      # The pinned qemu-vm.nix backgrounds its virtiofsd daemons and execs
      # qemu at once, and qemu connects to a chardev socket only once, so
      # it can lose that race and exit ("Connection refused"); the driver
      # then hangs on a pipe the daemons keep open. Up to 10 s per socket.
      qemuWaiting = pkgs.symlinkJoin {
        name = "qemu-waiting-for-virtiofsd";
        paths = [ pkgs.qemu_test ];
        postBuild = ''
          rm $out/bin/qemu-system-x86_64
          cat > $out/bin/qemu-system-x86_64 <<'EOF'
          #!${pkgs.runtimeShell}
          for arg in "$@"; do
            case "$arg" in
              socket,*path=*)
                sock=''${arg##*path=}; sock=''${sock%%,*}
                for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.1; done ;;
            esac
          done
          exec ${pkgs.qemu_test}/bin/qemu-system-x86_64 "$@"
          EOF
          chmod +x $out/bin/qemu-system-x86_64
        '';
      };

      beamPackages = pkgs.beam.packages.erlang_28.overrideScope (_: prev: { elixir = prev.elixir_1_20; });

      # A throwaway CA and one certificate for Gmail's two hosts, made at
      # build time, so the dev check's VM can stand a fake Gmail behind the
      # names the release pins and verify it like the real one.
      mailTestCerts = pkgs.runCommand "hireme-mail-test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
        mkdir -p $out
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
          -subj /CN=hireme-dev-mail-ca -keyout ca.key -out $out/ca.pem
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
          -subj /CN=imap.gmail.com -keyout $out/gmail.key -out gmail.csr
        printf 'subjectAltName=DNS:imap.gmail.com,DNS:smtp.gmail.com\nextendedKeyUsage=serverAuth\n' > ext
        openssl x509 -req -in gmail.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial -days 3650 \
          -extfile ext -out $out/gmail.pem
      '';
      hireme = pkgs.callPackage ./nix/package.nix {
        inherit bun beamPackages;
        source = ./.;
        revision = self.rev or self.dirtyRev or "dirty";
      };
    in
    {
      packages.${system} = {
        inherit hireme;
        default = hireme;
        kernel-wasm = hireme.kernel-wasm;
        hireme-mcp = hireme.mcp-client;
      };

      nixosModules.hireme = import ./nix/module.nix { inherit self; };

      checks.${system} = {
        # Every suite the repository has, offline in the sandbox: mix test
        # (its own database per run), cargo test over the workspace, the
        # kernel's vectors under wasm, bun check, and bun test over assets/test.
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
            hash = "sha256-nsMVzNBRleZONGgv8Z934BvuqICEdEm3gHn6jF66bLU=";
          };
          nativeBuildInputs = [
            beamPackages.elixir
            beamPackages.erlang
            beamPackages.hex
            # idna and telemetry build with rebar3; mix must not fetch one.
            beamPackages.rebar3
            pkgs.rustPlatform.cargoSetupHook
            pkgs.cargo
            pkgs.rustc
            pkgs.lld
            pkgs.sqlite
            bun
          ];
          env = {
            MIX_ENV = "test";
            MIX_REBAR3 = "${beamPackages.rebar3}/bin/rebar3";
            EXQLITE_USE_SYSTEM = "1";
            EXQLITE_SYSTEM_CFLAGS = "-I${pkgs.sqlite.dev}/include";
            EXQLITE_SYSTEM_LDFLAGS = "-L${pkgs.sqlite.out}/lib -lsqlite3";
            LANG = "C.UTF-8";
            # The sandbox has no CA store at the paths OTP's loader walks,
            # and OTP 28's httpc and the connector's :system cacerts read one
            # (pubkey_os_cacerts) even for localhost: twelve tests fail
            # without one. config/test.exs hands this bundle to public_key.
            HIREME_CACERTS = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          };
          buildPhase = ''
            export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex HEX_OFFLINE=1
            cp -r --no-preserve=mode $mixDeps deps
            (cd native && cargo test --offline --workspace --release)
            (cd native && cargo rustc --offline -p kernel --lib --release --target wasm32-unknown-unknown --crate-type cdylib)
            bun native/kernel/vectors.mjs native/target/wasm32-unknown-unknown/release/kernel.wasm
            bun native/kernel/fuzz.mjs native/target/wasm32-unknown-unknown/release/kernel.wasm
            mix test
            bun check -p assets; bun test ./assets/test
          '';
          installPhase = "touch $out";
        };

        # The dev profile: the module on a VM with generated secrets; the node
        # applies its schema at boot, backs up, and keeps its data across a
        # restart. Behind
        # the public host's nginx (plain HTTP here), /mcp outlives the
        # morning that took it down on 2026-10-20 (nix/mcp-replay.py).
        dev = pkgs.testers.runNixOSTest {
          name = "hireme-dev";
          nodes.machine = {
            imports = [ self.nixosModules.hireme ];
            virtualisation.memorySize = 2048;
            # The store as a disk image, not a virtiofs share (see qemuWaiting).
            virtualisation.mountHostNixStore = false;
            virtualisation.useNixStoreImage = true;
            # An overlay over the read-only image, so nix can register the
            # closure and make its .links at boot.
            virtualisation.writableStore = true;
            # The driver's own shares (xchg, shared) are virtiofs still.
            virtualisation.qemu.package = lib.mkForce qemuWaiting;
            environment.systemPackages = [
              pkgs.sqlite
              pkgs.psmisc
              pkgs.python3
            ];
            environment.etc."hireme/mcp-replay.py".source = ./nix/mcp-replay.py;
            environment.etc."hireme/mail-check.py".source = ./nix/mail-check.py;
            environment.etc."hireme/mail-check.exs".source = ./nix/mail-check.exs;
            # A fake Gmail (IMAP 993, SMTP 587 STARTTLS — the port the estate
            # sends on, since fsn1-2 has no route to 465 — Gmail's X-GM
            # extensions) driven through its spool: test/support/fake_gmail.ex,
            # standalone.
            systemd.services.fake-gmail = {
              wantedBy = [ "multi-user.target" ];
              before = [ "hireme.service" ];
              environment.HOME = "/var/lib/fake-gmail";
              serviceConfig.StateDirectory = "fake-gmail";
              script = ''
                exec ${beamPackages.elixir}/bin/elixir -r ${./test/support/fake_gmail.ex} \
                  -e 'Hireme.FakeGmail.main(System.argv())' -- \
                  --imap-port 993 --smtp-port 587 --ip 127.0.0.1 \
                  --cert ${mailTestCerts}/gmail.pem --key ${mailTestCerts}/gmail.key \
                  --user check@gmail.com --password abcdefghijklmnop --spool /var/lib/fake-gmail
              '';
            };
            # Gmail's hosts, as the release pins them, answered by the fake
            # below under a certificate from the check's own CA.
            networking.hosts."127.0.0.1" = [ "imap.gmail.com" "smtp.gmail.com" ];
            security.pki.certificateFiles = [ "${mailTestCerts}/ca.pem" ];
            services.nginx.virtualHosts.localhost = {
              enableACME = lib.mkForce false;
              forceSSL = lib.mkForce false;
            };
            services.hireme = {
              enable = true;
              domain = "localhost";
              release = "${hireme}";
              public = {
                enable = true;
                acmeEmail = "hireme@localhost";
              };
              environmentFile = "/var/lib/hireme-dev/env";
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
                  echo "MAIL_FROM=hireme@localhost"
                } > /var/lib/hireme-dev/env
              '';
            };
          };
          testScript =
            { nodes, ... }:
            ''
              import re

              machine.wait_for_unit("hireme.service")
              machine.wait_for_open_port(4000)
              machine.succeed("curl -sf -o /dev/null http://127.0.0.1:4000/sign-in")

              # The node applied the baseline at boot and took its first backup.
              machine.succeed("sqlite3 /var/lib/hireme/hireme.db \"select name from schema_files\" | grep -qx 0000_baseline")
              machine.succeed("sqlite3 /var/lib/hireme/hireme.db 'select count(*) from accounts'")
              machine.wait_until_succeeds("ls /var/lib/hireme/backups/hireme-v2-*.db")

              # The operator's and the deploy's way in: an rpc over loopback
              # distribution, with the unit's environment.
              def rpc(expr):
                  return machine.succeed(
                      "systemd-run --quiet --wait --pipe --uid=hireme --gid=hireme"
                      " -p EnvironmentFile=/var/lib/hireme-dev/env"
                      " -E HOME=/var/lib/hireme -E RELEASE_TMP=/var/lib/hireme/tmp"
                      " -E ERL_EPMD_ADDRESS=127.0.0.1 -E RELEASE_DISTRIBUTION=name -E RELEASE_NODE=hireme@127.0.0.1"
                      f" $(systemctl show -P ExecStart hireme | grep -o '/nix/store/[^ ]*/bin/hireme' | head -1) rpc '{expr}'"
                  ).strip()

              assert rpc("IO.puts(:ok)") == "ok"
              listening = machine.succeed("ss -Htlpn").splitlines()
              exposed = [l for l in listening if (":4369" in l or "beam" in l) and not ("127.0.0.1:" in l or "[::1]:" in l)]
              assert not exposed, f"epmd or the node listens off loopback: {exposed}"

              # The page ships the kernel the release was built with.
              machine.succeed("curl -sf -o /dev/null http://127.0.0.1:4000/wasm/kernel.wasm")


              # A restart keeps the data and applies nothing twice.
              machine.succeed("systemctl stop hireme")
              machine.succeed("systemctl start hireme")
              machine.wait_for_open_port(4000)
              machine.wait_until_succeeds("sqlite3 /var/lib/hireme/hireme.db \"select count(*) from schema_files where name = '0000_baseline'\" | grep -qx 1")

              # The public host's location, as fsn1-2 runs it: a CV file's body
              # (the node reads 64 MiB), answers under Cloudflare's 100 s (the
              # node's wait is 90 s), event streams unbuffered.
              conf = machine.succeed("cat $(systemctl show -P ExecStart nginx | grep -o \"/nix/store/[^ ']*nginx.conf\" | head -1)")
              [location] = re.findall(r"location / \{(.*?)\n\s*\}", conf, re.S)
              timeouts = [int(t) for t in re.findall(r"proxy_read_timeout (\d+)s;", location)]
              assert "client_max_body_size 64m;" in location and "proxy_buffering off;" in location, location
              assert timeouts and min(timeouts) >= 90, location

              # The /mcp outage of 2026-10-20, through that nginx from the
              # machine's own address: the node sees a visitor, not its proxy.
              key = rpc(
                  '{:ok, _, s} = Hireme.Accounts.sign_in_with(:email, %{subject: "replay@localhost", display: "replay@localhost"}, %{ip: "127.0.0.1"});'
                  " m = Hireme.Grants.all();"
                  ' {:ok, %{secret: k}} = Hireme.Keys.mint(s, "replay", %{read_mask: m, write_mask: m, may_delete: true});'
                  " IO.puts(k)"
              )
              machine.wait_for_open_port(80)
              status, replay = machine.execute(f"python3 /etc/hireme/mcp-replay.py ${nodes.machine.networking.primaryIPAddress} {key}")
              assert status == 0, replay
              print(replay)

              # Mail, missions and fire keys (docs/mail/passthrough.md), end to
              # end against a fake Gmail behind the names the release pins: the
              # operator's half inside the release (nix/mail-check.exs), the
              # agent's over /mcp with a read/write key (nix/mail-check.py).
              import json

              def op(step):
                  return json.loads(rpc(f'Code.require_file("/etc/hireme/mail-check.exs"); MailCheck.{step}').splitlines()[-1])

              def agent(*args):
                  return json.loads(machine.succeed("python3 /etc/hireme/mail-check.py " + " ".join(str(a) for a in args)).splitlines()[-1])

              machine.wait_for_unit("fake-gmail.service")
              machine.wait_for_open_port(993)
              machine.wait_for_open_port(587)

              seed = op("seed()")
              key, reply, changed, unsettled, app, other = seed["agent_key"], seed["reply"], seed["changed"], seed["unsettled"], seed["app"], seed["other"]
              assert seed["first_without_cv"] != "accepted", seed

              linked = op("link()")
              assert linked["linked"], linked

              # Without a key: answered, not an error, and nothing goes out.
              nokey = agent("fire", key, reply, app)
              assert not nokey["is_error"] and nokey["sent"] == 0, nokey
              # An earlier send the operator has not settled cannot fire.
              blocked = agent("fire", key, unsettled, other)
              assert blocked["sent"] == 0 and "unsettled" in blocked["text"].lower(), blocked

              # The request answers the predialed link; opening it creates nothing.
              asked = agent("request", key, f"{reply},{changed}", app)
              assert "/fire/" in asked["link"], asked
              assert op("state()")["keys"] == 0

              # The fresh session creates the key; one past the step-up window cannot.
              made = op(f'create_key("{reply},{changed}")')
              assert made["key"] and made["refused"] == [] and made["stale_session"] == ["step_up"], made

              # One shot: exactly one mail, to the mission's own target; the application submitted.
              shot = agent("fire", key, reply, app, made["key"])
              assert not shot["is_error"] and shot["sent"] == 1, shot
              assert shot["envelopes"][-1]["rcpts"] == ["jobs@acme.example"], shot
              after = op("state()")
              assert after["missions"][str(reply)]["state"] == "fired" and after["app_stage"] == "submitted", after

              # Again: the commander answers, and nothing more goes out.
              again = agent("fire", key, reply, app, made["key"])
              assert not again["is_error"] and again["sent"] == 0, again

              # A mission edited after the key was made fires nothing.
              agent("edit", key, changed, app)
              edited = agent("fire", key, changed, app, made["key"])
              assert edited["sent"] == 0 and "changed" in edited["text"].lower(), edited

              # A recruiter's reply is filed to the application and labelled in Gmail.
              mid = after["missions"][str(reply)]["message_id"].strip("<>")
              agent("reply", key, mid)
              def filed(_):
                  rows = op("state()")["outreach"]
                  return any(r["direction"] == "inbound" and r["filing"] == "filed" and r["application_id"] == seed["app"] for r in rows)
              retry(filed, timeout_seconds=60)
              def labelled(_):
                  return any("hireme" in m["labels"] and "\\Inbox" in m["labels"] for m in agent("labels", key))
              retry(labelled, timeout_seconds=60)

              # The domain pipe: a forged post refused, a signed one taken once.
              pipe = op("pipe()")
              posted = agent("pipe", key, pipe["pipe_id"], pipe["secret"])
              assert posted["forged"] == 401 and posted["signed"] in (200, 202) and posted["replayed"] in (200, 202), posted
              rows = [r for r in op("state()")["outreach"] if r["message_id"] and "pipe-1@acme.example" in r["message_id"]]
              assert len(rows) == 1, rows
              print("mail check passed")
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
          # rustc links the wasm32 kernel with lld; the check and the release do too.
          pkgs.lld
          pkgs.sqlite
          bun
        ];
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
