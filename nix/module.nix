# Everything Hireme needs from a NixOS host: the user and one sandboxed unit,
# and with `public.enable` the reverse proxy, the vault's secrets and the
# profile `nix/deploy.sh` flips. The importing host names its addresses only.
{ self }:
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hireme;
  inherit (lib) mkOption types;
  # Cloudflare's proxy networks (https://www.cloudflare.com/ips-v4/ and /ips-v6/,
  # checked 2026-10-12): only a request from one of them may name the client.
  cloudflareNetworks = [
    "173.245.48.0/20"
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "141.101.64.0/18"
    "108.162.192.0/18"
    "190.93.240.0/20"
    "188.114.96.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
    "162.158.0.0/15"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "172.64.0.0/13"
    "131.0.72.0/22"
    "2400:cb00::/32"
    "2606:4700::/32"
    "2803:f800::/32"
    "2405:b500::/32"
    "2405:8100::/32"
    "2a06:98c0::/29"
    "2c0f:f248::/32"
  ];
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

    signups = mkOption {
      type = types.bool;
      default = true;
      description = "Whether a new person may make an account (HIREME_SIGNUPS). Off, every existing account still signs in; nothing names an address.";
    };

    public = {
      enable = lib.mkEnableOption "the public host: nginx with ACME on `domain`, the vault's secrets, and the release profile the deploy flips";
      acmeEmail = mkOption {
        type = types.str;
        description = "Contact address for ACME registration.";
      };
    };

  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge (
      [
        {
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
              HIREME_SERVER = "true";
              HIREME_HOST = cfg.domain;
              HIREME_SIGNUPS = if cfg.signups then "on" else "off";
              PORT = toString cfg.port;
              DATABASE_PATH = "/var/lib/hireme/hireme.db";
              HOME = "/var/lib/hireme";
              RELEASE_TMP = "/var/lib/hireme/tmp";
              # Distribution (for `bin/hireme rpc`) stays on loopback: epmd
              # and the node's port bind 127.0.0.1, and the node is named by
              # that address, since a host name may resolve to 127.0.1.1 or
              # 127.0.0.2. A client (deploy.sh, an operator) sets the same.
              ERL_EPMD_ADDRESS = "127.0.0.1";
              ELIXIR_ERL_OPTIONS = "-kernel inet_dist_use_interface {127,0,0,1}";
              RELEASE_DISTRIBUTION = "name";
              RELEASE_NODE = "hireme@127.0.0.1";
            };
            serviceConfig = {
              User = "hireme";
              Group = "hireme";
              WorkingDirectory = "/var/lib/hireme";
              ExecStart = "${cfg.release}/bin/hireme start";
              EnvironmentFile = cfg.environmentFile;
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
        }

        (lib.mkIf cfg.public.enable {
          services.hireme.release = lib.mkDefault "/nix/var/nix/profiles/hireme";

          networking.firewall.allowedTCPPorts = [
            80
            443
          ];
          security.acme = {
            acceptTerms = true;
            defaults.email = lib.mkDefault cfg.public.acmeEmail;
          };
          services.nginx = {
            enable = true;
            recommendedTlsSettings = true;
            recommendedOptimisation = true;
            recommendedProxySettings = true;
            # A request's path without its query, in every server block (the
            # port-80 redirect included): a mailed sign-in link carries its
            # live token in the query, and the access log must not.
            commonHttpConfig = ''
              log_format hireme '$remote_addr - [$time_local] "$request_method $uri $server_protocol" '
                                '$status $body_bytes_sent $request_time "$http_user_agent"';
            '';
            virtualHosts.${cfg.domain} = {
              enableACME = true;
              forceSSL = true;
              # The node's per-peer limits and bans count the visitor, never Cloudflare's edge:
              # CF-Connecting-IP is believed only from Cloudflare's own networks.
              # The log is this host's own line, not the http block's: an `access_log off`
              # that ends the http block (another site's) outranked the format there, and
              # the file stayed empty from 2026-10-09 to the /mcp outage of 2026-10-20.
              extraConfig = ''
                ${lib.concatMapStringsSep "\n" (n: "set_real_ip_from ${n};") cloudflareNetworks}
                real_ip_header CF-Connecting-IP;
                real_ip_recursive off;
                access_log /var/log/nginx/access.log hireme;
              '';
              locations."/" = {
                proxyPass = "http://127.0.0.1:${toString cfg.port}";
                proxyWebsockets = true;
                # Recommended proxy headers include Host and X-Forwarded-Proto $scheme.
                # A body may be a CV file for /blobs (10 MiB, base64 on the MCP) or a
                # bulk put (the node reads 64 MiB): nginx's 1 MiB default answered 413.
                extraConfig = ''
                  proxy_buffering off;
                  proxy_read_timeout 300s;
                  client_max_body_size 64m;
                '';
              };
            };
          };
        })

      ]
      # The vault (secrets/master), rekeyed to the host by agenix-rekey; only
      # where the host imports it, so the dev profile needs none.
      ++ lib.optional (options ? age) (
        lib.mkIf cfg.public.enable (
          lib.mkMerge [
            {
              services.hireme.environmentFile = lib.mkDefault config.age.secrets.hireme-env.path;
              age.secrets.hireme-env = {
                rekeyFile = "${self}/secrets/master/hireme-env.age";
                mode = "0400";
              };
            }
          ]
        )
      )
    )
  );
}
