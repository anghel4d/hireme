{
  description = "Hireme: the release, its NixOS module, and the dev profile that tests them";

  # Pure on purpose: nothing about any host. A host flake imports
  # nixosModules.hireme with `inputs.hireme.inputs.nixpkgs.follows =
  # "nixpkgs"`, so the release builds against the host's nixpkgs and the
  # mix dependency hash stays valid; the deploy lives with the host.
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
      hireme = pkgs.callPackage ./nix/package.nix {
        source = ./.;
        revision = self.rev or self.dirtyRev or "dirty";
      };
    in
    {
      packages.${system} = {
        inherit hireme;
        hireme-gate = hireme.gate;
      };

      nixosModules.hireme = import ./nix/module.nix { inherit self; };

      # The dev profile (see README, Production deployment).
      checks.${system}.dev = pkgs.testers.runNixOSTest {
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

          # The node migrated at boot and took its first backup.
          machine.succeed("sqlite3 /var/lib/hireme/hireme.db 'select count(*) from schema_migrations' | grep -qv '^0$'")
          machine.wait_until_succeeds("ls /var/lib/hireme/backups/hireme-*.db")

          # The gate is the node's child, on a high port, as the node's user,
          # with no capability, and it pins its certificate by hash.
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

          # Stopping the node stops the gate; restarting keeps the data.
          machine.succeed("systemctl stop hireme")
          machine.fail("pgrep hireme-gate")
          machine.succeed("systemctl start hireme")
          machine.wait_for_open_port(4000)
          machine.wait_until_succeeds("ss -Hulpn 'sport = :4433' | grep -q hireme-gate")
        '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          elixir
          erlang
          cargo
          rustc
          clippy
          nodejs
          sqlite
        ];
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
