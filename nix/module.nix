# The host-agnostic half of running Hireme on NixOS: its user, its one
# systemd unit and that unit's sandbox, and where its secrets come from.
# Everything about a particular machine (addresses, firewall, certificates,
# the reverse proxy) belongs to the host that imports this.
#
# systemd only starts and sandboxes the node. The node itself migrates the
# database before it serves, takes the daily backup, drains its sessions on
# SIGTERM, and runs the WebTransport gate as its own Port (which exits when
# the node does), so there is no second unit, user or capability.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hireme;
  gate = cfg.gate;
  inherit (lib) mkOption types;
in
{
  options.services.hireme = {
    enable = lib.mkEnableOption "Hireme";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.hireme;
      defaultText = lib.literalExpression "hireme.packages.\${system}.hireme";
      description = "The release, with `bin/hireme` and `bin/hireme-gate`.";
    };

    release = mkOption {
      type = types.str;
      default = "${cfg.package}";
      defaultText = lib.literalExpression "\"\${config.services.hireme.package}\"";
      example = "/nix/var/nix/profiles/hireme";
      description = ''
        Where the unit runs the release from. A profile path here lets a
        deploy flip the application alone, without a system switch.
      '';
    };

    domain = mkOption {
      type = types.str;
      description = "Public DNS name of the desk.";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
      description = "Loopback HTTP port the reverse proxy forwards to.";
    };

    environmentFile = mkOption {
      type = types.str;
      example = "/run/agenix/hireme-env";
      description = ''
        `KEY=value` lines with SECRET_KEY_BASE, RELEASE_COOKIE and the mail
        credentials (CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_EMAIL_TOKEN). On a
        host this is the agenix path; in the dev profile a plaintext file
        generated on the machine. Never a store path: the store is world
        readable.
      '';
    };

    gate = {
      enable = lib.mkEnableOption "the WebTransport gate, run by the node as a Port";
      listen = mkOption {
        type = types.str;
        default = "0.0.0.0:4433";
        description = ''
          UDP `address:port` the gate binds. A high port needs no
          capability; the host forwards UDP 443 to it.
        '';
      };
      url = mkOption {
        type = types.str;
        example = "https://wt.example.org/wt";
        description = "The gate's public URL, as the page dials it.";
      };
      origins = mkOption {
        type = types.listOf types.str;
        default = [ "https://${cfg.domain}" ];
        defaultText = lib.literalExpression "[ \"https://\${config.services.hireme.domain}\" ]";
        description = "Page origins allowed to open a session; agents send none.";
      };
      cert = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Directory holding `fullchain.pem` and `key.pem`, readable by the
          `hireme` group. The gate rereads them when they change. Null
          makes the gate sign its own ECDSA P-256 certificate at each start
          (valid 14 days, pinned by hash): the dev profile only.
        '';
      };
      perIp = mkOption {
        type = types.ints.positive;
        default = 16;
        description = "Live WebTransport sessions allowed per client address.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.hireme = { };
    users.users.hireme = {
      isSystemUser = true;
      group = "hireme";
    };

    systemd.services.hireme = {
      description = "Hireme";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        PHX_SERVER = "true";
        PHX_HOST = cfg.domain;
        PHX_IP = "127.0.0.1";
        PORT = toString cfg.port;
        DATABASE_PATH = "/var/lib/hireme/hireme.db";
        HOME = "/var/lib/hireme";
        RELEASE_TMP = "/var/lib/hireme/tmp";
      }
      // lib.optionalAttrs gate.enable (
        {
          GATE_BIN = "${cfg.release}/bin/hireme-gate";
          GATE_SOCKET = "/run/hireme/gate.sock";
          GATE_URL = gate.url;
          GATE_LISTEN = gate.listen;
          GATE_ORIGINS = lib.concatStringsSep "," gate.origins;
          GATE_PER_IP = toString gate.perIp;
        }
        // (
          if gate.cert == null then
            { GATE_CERT_HASH_FILE = "/run/hireme/gate.hash"; }
          else
            {
              GATE_CERT = "${gate.cert}/fullchain.pem";
              GATE_KEY = "${gate.cert}/key.pem";
            }
        )
      );
      serviceConfig = {
        User = "hireme";
        Group = "hireme";
        WorkingDirectory = "/var/lib/hireme";
        ExecStart = "${cfg.release}/bin/hireme start";
        EnvironmentFile = cfg.environmentFile;
        # SIGTERM reaches the node alone, which drains its sessions through
        # the gate and then closes the gate's stdin; the rest of the cgroup
        # is killed only if that outlasts the stop timeout.
        KillMode = "mixed";
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = [
          "hireme"
          "hireme/tmp"
        ];
        StateDirectoryMode = "0700";
        RuntimeDirectory = "hireme";
        RuntimeDirectoryMode = "0700";
        LimitNOFILE = 65536;
        UMask = "0077";
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
