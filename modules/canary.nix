{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.monitoringLite.canary;
  sendNotify = import ./send-notify.nix { inherit pkgs; };
  btrfsMounts = lib.attrNames (
    lib.filterAttrs (_: fs: fs.fsType or null == "btrfs") config.fileSystems
  );
  proxyArg = if cfg.proxy != null then "--proxy ${lib.escapeShellArg cfg.proxy}" else "";
in
{
  options.services.monitoringLite.canary = {
    enable = lib.mkEnableOption "monitoring canary heartbeat";

    disks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/" ];
      description = "Mount points to include in disk-usage monitoring.";
    };

    threshold = lib.mkOption {
      type = lib.types.int;
      default = 75;
      description = "Disk usage percentage threshold that turns the heartbeat into a failure ping.";
    };

    urlFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/healthchecks/canary.url";
      description = "Path to a file containing the base Healthchecks.io ping URL (plain file, sops-nix path, or agenix path).";
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
  };

  config = lib.mkIf cfg.enable {
    systemd.services.monitoring-lite-canary = {
      description = "Monitoring canary heartbeat";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = "HC_URL:${cfg.urlFile}";
      };
      path = [
        pkgs.coreutils
        pkgs.curl
      ]
      ++ lib.optionals (btrfsMounts != [ ]) [ pkgs.btrfs-progs ];
      script = ''
        set -euo pipefail
        threshold=${toString cfg.threshold}
        fail=0
        reasons=()
        disk_parts=()
        btrfs_parts=()
        mdraid_parts=()
        disks=(${lib.escapeShellArgs cfg.disks})
        btrfs_mounts=(${lib.escapeShellArgs btrfsMounts})

        for mp in "''${disks[@]}"; do
          if [ -d "$mp" ]; then
            pct="$(df --output=pcent "$mp" 2>/dev/null | tail -n 1 | tr -d '% ' || echo '?')"
            disk_parts+=("$(basename "$mp"):$pct%")
            if [ "$pct" != "?" ] && [ "$pct" -gt "$threshold" ]; then
              fail=1
              reasons+=("$mp>$threshold%($pct%)")
            fi
          fi
        done

        for mp in "''${btrfs_mounts[@]}"; do
          if [ -d "$mp" ]; then
            status="ok"
            if ! fs_show="$(btrfs filesystem show "$mp" 2>&1)"; then
              fail=1
              status="show-failed"
              reasons+=("$mp:btrfs-show-failed")
            else
              case "$fs_show" in
                *missing*|*MISSING*)
                  fail=1
                  status="missing-device"
                  reasons+=("$mp:btrfs-missing-device")
                  ;;
              esac
            fi

            if ! btrfs device stats -c "$mp" >/dev/null 2>&1; then
              fail=1
              if [ "$status" = "ok" ]; then
                status="device-errors"
              else
                status="$status+device-errors"
              fi
              reasons+=("$mp:btrfs-device-errors")
            fi

            btrfs_parts+=("$(basename "$mp"):$status")
          fi
        done

        if [ -r /proc/mdstat ]; then
          current_array=""
          while IFS= read -r line; do
            case "$line" in
              md*" :"*)
                current_array="''${line%% *}"
                mdraid_parts+=("$current_array:present")
                ;;
              *"["*"]"*)
                if [ -n "$current_array" ]; then
                  raid_state="''${line##*[}"
                  raid_state="[''${raid_state%%]*}]"
                  last_idx=$(( ''${#mdraid_parts[@]} - 1 ))
                  mdraid_parts[last_idx]="$current_array:$raid_state"
                  case "$raid_state" in
                    *_*)
                      fail=1
                      reasons+=("$current_array:mdraid-degraded")
                      ;;
                  esac
                fi
                ;;
            esac
          done < /proc/mdstat
        fi

        disk_summary="''${disk_parts[*]}"
        btrfs_summary="''${btrfs_parts[*]}"
        mdraid_summary="''${mdraid_parts[*]}"
        reason_summary="''${reasons[*]}"

        msg="Disk: $disk_summary"
        if [ -n "$btrfs_summary" ]; then
          msg="$msg | Btrfs: $btrfs_summary"
        fi
        if [ -n "$mdraid_summary" ]; then
          msg="$msg | Mdraid: $mdraid_summary"
        fi
        if [ -n "$reason_summary" ]; then
          msg="$msg | Reasons: $reason_summary"
        fi

        status="ok"
        if [ "$fail" -eq 1 ]; then
          status="fail"
        fi

        ${sendNotify} \
          --provider healthchecks \
          --status "$status" \
          --url-file "$CREDENTIALS_DIRECTORY/HC_URL" \
          --message "$msg" \
          --timeout ${toString cfg.curlTimeout} \
          --retries ${toString cfg.retryCount} \
          ${proxyArg}
      '';
    };

    systemd.timers.monitoring-lite-canary = {
      description = "Run monitoring canary heartbeat daily";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
