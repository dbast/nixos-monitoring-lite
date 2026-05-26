{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.monitoringLite.systemdFail;
  sendNotify = import ./send-notify.nix { inherit pkgs; };
  proxyArg = if cfg.proxy != null then "--proxy ${lib.escapeShellArg cfg.proxy}" else "";
in
{
  options.services.monitoringLite.systemdFail = {
    enable = lib.mkEnableOption "systemd failure notifications";

    urlFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/healthchecks/systemd-failure.url";
      description = "Path to a file containing the base Healthchecks.io ping URL for failures (plain file, sops-nix path, or agenix path).";
    };

    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "NixOS systemd service attribute names to attach OnFailure notifications to.";
    };

    enableDemo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable an intentionally failing demo service for testing failure notifications.";
    };

    proxy = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "socks5h://127.0.0.1:9050";
      description = "Optional curl proxy URL. Set this to a local Tor SOCKS proxy if desired.";
    };

    curlTimeout = lib.mkOption {
      type = lib.types.int;
      default = 15;
      description = "Maximum seconds curl may spend on a Healthchecks.io request.";
    };

    retryCount = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "curl retry count for Healthchecks.io requests.";
    };

    journalLines = lib.mkOption {
      type = lib.types.int;
      default = 50;
      description = "Number of failed-invocation journal lines to include in the failure payload.";
    };

    okMessage = lib.mkOption {
      type = lib.types.str;
      default = "systemd failure path recovered";
      description = "Message sent when manually marking the systemd-fail check as recovered.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        systemd.services."monitoring-lite-fail@" = {
          description = "Send monitoring failure notification for %I";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            LoadCredential = "HC_URL:${cfg.urlFile}";
          };
          path = [
            pkgs.coreutils
            pkgs.curl
            pkgs.gnugrep
            pkgs.systemd
          ];
          script = ''
            set -euo pipefail
            loadavg="$(cut -d' ' -f1-3 /proc/loadavg)"
            mem_line="$(grep -i '^MemAvailable:' /proc/meminfo || true)"
            df_root="$(df -h / 2>/dev/null | tail -n +2 || true)"
            log_snip="$(journalctl _SYSTEMD_INVOCATION_ID="$MONITOR_INVOCATION_ID" -n ${toString cfg.journalLines} --no-pager --output=short-unix 2>/dev/null || true)"
            msg="$(cat <<EOF
            Service $MONITOR_UNIT failed on ${config.networking.hostName} (Result=$MONITOR_SERVICE_RESULT ExitCode=$MONITOR_EXIT_CODE ExitStatus=$MONITOR_EXIT_STATUS InvocationID=$MONITOR_INVOCATION_ID)
            LoadAvg=$loadavg  $mem_line
            RootFS: $df_root
            ---- Journal (failed invocation, ${toString cfg.journalLines} lines) ----
            $log_snip
            EOF
            )"

            ${sendNotify} \
              --provider healthchecks \
              --status fail \
              --url-file "$CREDENTIALS_DIRECTORY/HC_URL" \
              --message "$msg" \
              --timeout ${toString cfg.curlTimeout} \
              --retries ${toString cfg.retryCount} \
              ${proxyArg}
          '';
        };

        systemd.services.monitoring-lite-systemd-fail-ok = {
          description = "Mark Healthchecks systemd-fail check as recovered";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            LoadCredential = "HC_URL:${cfg.urlFile}";
          };
          path = [
            pkgs.coreutils
            pkgs.curl
          ];
          script = ''
            set -euo pipefail
            msg="${cfg.okMessage} on ${config.networking.hostName} at $(date --iso-8601=seconds)"
            ${sendNotify} \
              --provider healthchecks \
              --status ok \
              --url-file "$CREDENTIALS_DIRECTORY/HC_URL" \
              --message "$msg" \
              --timeout ${toString cfg.curlTimeout} \
              --retries ${toString cfg.retryCount} \
              ${proxyArg}
          '';
        };
      }
      {
        systemd.services = lib.genAttrs cfg.services (_name: {
          unitConfig.OnFailure = [ "monitoring-lite-fail@%n.service" ];
        });
      }
      (lib.mkIf cfg.enableDemo {
        systemd.services.monitoring-lite-fail-demo = {
          description = "Intentional failing demo service";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/false";
          };
          unitConfig.OnFailure = [ "monitoring-lite-fail@%n.service" ];
        };
      })
    ]
  );
}
