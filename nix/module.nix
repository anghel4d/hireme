# The host-agnostic half of running Hireme on NixOS: the user, one unit that
# starts and sandboxes the node, and where its secrets come from. Addresses,
# firewall, certificates and the reverse proxy belong to the importing host.
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

    release = mkOption {
      type = types.str;
      default = "${self.packages.${pkgs.stdenv.hostPlatform.system}.hireme}";
      description = "The release the unit runs; a profile path lets a deploy flip it without a system switch.";
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
      description = "`KEY=value` lines (SECRET_KEY_BASE, RELEASE_COOKIE, the mail credentials); an agenix path on a host, never a store path.";
    };

    gate = {
      enable = lib.mkEnableOption "the WebTransport gate, run by the node as a Port";
      listen = mkOption {
        type = types.str;
        default = "0.0.0.0:4433";
        description = "UDP `address:port` the gate binds; the host forwards 443 to it.";
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
        description = "Directory with `fullchain.pem` and `key.pem`, readable by the `hireme` group and reread on change; null (the dev profile) self-signs a 14-day ECDSA certificate pinned by hash.";
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
