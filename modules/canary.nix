{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.monitoringLite.canary;
  sendNotify = import ./send-notify.nix { inherit pkgs; };
  extraContext = lib.mapAttrsToList (
    name: context:
    let
      program = "monitoring-lite-canary-context-${lib.strings.sanitizeDerivationName name}";
    in
    {
      inherit name program;
      package = pkgs.writeShellApplication {
        name = program;
        runtimeInputs = context.runtimeInputs;
        text = context.script;
      };
    }
  ) cfg.extraContext;
  extraContextNames = map (context: context.name) extraContext;
  extraContextScripts = map (context: "${context.package}/bin/${context.program}") extraContext;
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

    nixpkgsMaxAgeDays = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = "Maximum age in days of the running generation's nixpkgs snapshot. Set to 0 to disable this check.";
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

    extraContext = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            script = lib.mkOption {
              type = lib.types.lines;
              description = ''
                Shell script that prints short additional canary payload context to stdout.
                A non-zero exit status marks the canary as failed and adds a reason.
              '';
            };

            runtimeInputs = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
              description = "Packages added to PATH while running this context script.";
            };
          };
        }
      );
      default = { };
      description = "Additional named scripts that emit short host-specific canary context.";
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
        nixpkgs_max_age_days=${toString cfg.nixpkgsMaxAgeDays}
        nixos_version=${lib.escapeShellArg config.system.nixos.version}
        fail=0
        reasons=()
        disk_parts=()
        btrfs_parts=()
        mdraid_parts=()
        context_parts=()
        disks=(${lib.escapeShellArgs cfg.disks})
        btrfs_mounts=(${lib.escapeShellArgs btrfsMounts})
        extra_context_names=(${lib.escapeShellArgs extraContextNames})
        extra_context_scripts=(${lib.escapeShellArgs extraContextScripts})

        nixpkgs_summary="disabled"
        if [ "$nixpkgs_max_age_days" -ne 0 ]; then
          nixpkgs_date="''${nixos_version#*.*.}"
          nixpkgs_date="''${nixpkgs_date%%.*}"
          if nixpkgs_epoch="$(date -u -d "$nixpkgs_date" +%s 2>/dev/null)"; then
            now_epoch="$(date -u +%s)"
            nixpkgs_age_days=$(( (now_epoch - nixpkgs_epoch) / 86400 ))
            nixpkgs_summary="$nixpkgs_date:''${nixpkgs_age_days}d"
            if [ "$nixpkgs_epoch" -gt "$now_epoch" ]; then
              fail=1
              reasons+=("nixpkgs-date-in-future($nixpkgs_date)")
            elif [ "$nixpkgs_age_days" -gt "$nixpkgs_max_age_days" ]; then
              fail=1
              reasons+=("nixpkgs>''${nixpkgs_max_age_days}d(''${nixpkgs_age_days}d)")
            fi
          else
            nixpkgs_summary="unknown:$nixos_version"
          fi
        fi

        target_system=/nix/var/nix/profiles/system
        if [ ! -e "$target_system" ]; then
          target_system=/run/current-system
        fi
        reboot_summary="unknown"
        if booted="$(readlink /run/booted-system/{initrd,kernel,kernel-modules} 2>/dev/null)" \
          && target="$(readlink "$target_system"/{initrd,kernel,kernel-modules} 2>/dev/null)"; then
          reboot_summary="no"
          if [ "$booted" != "$target" ]; then
            reboot_summary="required"
            fail=1
            reasons+=("reboot-required")
          fi
        fi

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

        for idx in "''${!extra_context_names[@]}"; do
          context_name="''${extra_context_names[$idx]}"
          context_script="''${extra_context_scripts[$idx]}"

          if context_output="$("$context_script" 2>&1)"; then
            context_output="''${context_output//$'\r'/}"
            context_output="''${context_output//$'\n'/; }"
            if [ -z "$context_output" ]; then
              context_output="<empty>"
            fi
            context_parts+=("$context_name:$context_output")
          else
            context_status=$?
            fail=1
            reasons+=("$context_name:context-failed($context_status)")
            context_output="''${context_output//$'\r'/}"
            context_output="''${context_output//$'\n'/; }"
            if [ -n "$context_output" ]; then
              context_parts+=("$context_name:failed:$context_output")
            else
              context_parts+=("$context_name:failed")
            fi
          fi
        done

        disk_summary="''${disk_parts[*]}"
        btrfs_summary="''${btrfs_parts[*]}"
        mdraid_summary="''${mdraid_parts[*]}"
        context_summary="''${context_parts[*]}"
        reason_summary="''${reasons[*]}"

        msg="Nixpkgs: $nixpkgs_summary | Reboot: $reboot_summary | Disk: $disk_summary"
        if [ -n "$btrfs_summary" ]; then
          msg="$msg | Btrfs: $btrfs_summary"
        fi
        if [ -n "$mdraid_summary" ]; then
          msg="$msg | Mdraid: $mdraid_summary"
        fi
        if [ -n "$context_summary" ]; then
          msg="$msg | Context: $context_summary"
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
