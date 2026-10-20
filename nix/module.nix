# Everything Hireme needs from a NixOS host: the user and one sandboxed unit,
# and with `public.enable` the reverse proxy, the vault's secrets and the
# profile `nix/deploy.sh` flips; with `gate.address` the gate's forwarding
# and its wildcard certificate. The importing host names its addresses only.
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
  gate = cfg.gate;
  cert = "hireme-gate";
  gatePort = 4433;
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

    gate = {
      enable = lib.mkEnableOption "the WebTransport gate, run by the node as a Port";
      address = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Floating IPv4 only the gate listens on; UDP 443 there is forwarded
          to the gate's high port. The host puts the address on its interface.
        '';
      };
      host = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          DNS-only name (one label under `domain`, so the wildcard certificate
          covers it) whose A record points at `address`.
        '';
      };
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

        (lib.mkIf (gate.enable && gate.address != null) {
          assertions = [
            {
              assertion =
                gate.host != null
                && lib.hasSuffix ".${cfg.domain}" gate.host
                && !(lib.hasInfix "." (lib.removeSuffix ".${cfg.domain}" gate.host));
              message = "services.hireme.gate.host must be one label under ${cfg.domain}, inside the wildcard.";
            }
            {
              assertion = cfg.public.enable;
              message = "services.hireme.gate.address needs services.hireme.public.enable for its certificate.";
            }
          ];

          services.hireme.gate = {
            listen = "${gate.address}:${toString gatePort}";
            url = "https://${gate.host}/wt";
            cert = "/var/lib/acme/${cert}";
          };

          # UDP 443 on the gate's address only, forwarded to its high port;
          # the high port takes nothing that was not forwarded.
          networking.firewall.extraCommands = ''
            iptables -t nat -N hireme-gate 2>/dev/null || iptables -t nat -F hireme-gate
            iptables -t nat -A hireme-gate -d ${gate.address}/32 -p udp --dport 443 -j DNAT --to-destination ${gate.address}:${toString gatePort}
            iptables -t nat -C PREROUTING -j hireme-gate 2>/dev/null || iptables -t nat -A PREROUTING -j hireme-gate
            iptables -A nixos-fw -d ${gate.address}/32 -p udp --dport ${toString gatePort} -m conntrack --ctstate DNAT -j nixos-fw-accept
          '';
          networking.firewall.extraStopCommands = ''
            iptables -t nat -D PREROUTING -j hireme-gate 2>/dev/null || true
            iptables -t nat -F hireme-gate 2>/dev/null || true
            iptables -t nat -X hireme-gate 2>/dev/null || true
          '';

          # quinn's recommended socket buffers for bursts of QUIC datagrams.
          boot.kernel.sysctl = {
            "net.core.rmem_max" = 7500000;
            "net.core.wmem_max" = 7500000;
          };

          # Wildcard by DNS-01, so certificate transparency shows
          # *.${cfg.domain} and not the gate's own name. The gate rereads
          # the pair when a renewal rewrites it.
          security.acme.certs.${cert} = {
            domain = "*.${cfg.domain}";
            dnsProvider = "cloudflare";
            dnsResolver = "1.1.1.1:53";
            # CF_DNS_API_TOKEN: Zone DNS Edit on the domain's zone only.
            environmentFile = config.age.secrets.hireme-acme.path;
            group = "hireme";
          };
          systemd.services.hireme = {
            wants = [ "acme-${cert}.service" ];
            after = [ "acme-${cert}.service" ];
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
            (lib.mkIf (gate.enable && gate.address != null) {
              age.secrets.hireme-acme = {
                rekeyFile = "${self}/secrets/master/hireme-acme.age";
                mode = "0400";
              };
            })
          ]
        )
      )
    )
  );
}
