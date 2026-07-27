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
      ]
      ++ lib.optionals (btrfsMounts != [ ]) [ pkgs.btrfs-progs ];
      script = ''
        set -euo pipefail
        threshold=${toString cfg.threshold}
        nixpkgs_max_age_days=${toString cfg.nixpkgsMaxAgeDays}
        nixos_version=${lib.escapeShellArg config.system.nixos.version}
        notification_status="ok"
        reasons=()
        disk_parts=()
        btrfs_parts=()
        mdraid_parts=()
        context_parts=()
        disks=(${lib.escapeShellArgs cfg.disks})
        btrfs_mounts=(${lib.escapeShellArgs btrfsMounts})
        extra_context_names=(${lib.escapeShellArgs extraContextNames})
        extra_context_scripts=(${lib.escapeShellArgs extraContextScripts})

        mark_failed() {
          notification_status="fail"
          reasons+=("$1")
        }

        nixpkgs_summary="disabled"
        if [ "$nixpkgs_max_age_days" -ne 0 ]; then
          nixpkgs_date="''${nixos_version#*.*.}"
          nixpkgs_date="''${nixpkgs_date%%.*}"
          if nixpkgs_epoch="$(date -u -d "$nixpkgs_date" +%s 2>/dev/null)"; then
            now_epoch="$(date -u +%s)"
            nixpkgs_age_days=$(( (now_epoch - nixpkgs_epoch) / 86400 ))
            nixpkgs_summary="$nixpkgs_date:''${nixpkgs_age_days}d"
            if [ "$nixpkgs_epoch" -gt "$now_epoch" ]; then
              mark_failed "nixpkgs-date-in-future($nixpkgs_date)"
            elif [ "$nixpkgs_age_days" -gt "$nixpkgs_max_age_days" ]; then
              mark_failed "nixpkgs>''${nixpkgs_max_age_days}d(''${nixpkgs_age_days}d)"
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
            mark_failed "reboot-required"
          fi
        fi

        for mp in "''${disks[@]}"; do
          if [ -d "$mp" ]; then
            pct="$(df --output=pcent "$mp" 2>/dev/null | tail -n 1 | tr -d '% ' || echo '?')"
            disk_parts+=("$(basename "$mp"):$pct%")
            if [ "$pct" != "?" ] && [ "$pct" -gt "$threshold" ]; then
              mark_failed "$mp>$threshold%($pct%)"
            fi
          fi
        done

        for mp in "''${btrfs_mounts[@]}"; do
          if [ -d "$mp" ]; then
            status="ok"
            if ! fs_show="$(btrfs filesystem show "$mp" 2>&1)"; then
              status="show-failed"
              mark_failed "$mp:btrfs-show-failed"
            else
              case "$fs_show" in
                *missing*|*MISSING*)
                  status="missing-device"
                  mark_failed "$mp:btrfs-missing-device"
                  ;;
              esac
            fi

            if ! btrfs device stats -c "$mp" >/dev/null 2>&1; then
              if [ "$status" = "ok" ]; then
                status="device-errors"
              else
                status="$status+device-errors"
              fi
              mark_failed "$mp:btrfs-device-errors"
            fi

            btrfs_parts+=("$(basename "$mp"):$status")
          fi
        done

        for degraded_file in /sys/block/md*/md/degraded; do
          [ -e "$degraded_file" ] || continue
          array="''${degraded_file#/sys/block/}"
          array="''${array%%/*}"
          degraded="$(<"$degraded_file")"
          mdraid_parts+=("$array:degraded=$degraded")
          if [ "$degraded" -gt 0 ]; then
            mark_failed "$array:mdraid-degraded($degraded)"
          fi
        done

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
            mark_failed "$context_name:context-failed($context_status)"
            context_output="''${context_output//$'\r'/}"
            context_output="''${context_output//$'\n'/; }"
            if [ -n "$context_output" ]; then
              context_parts+=("$context_name:failed:$context_output")
            else
              context_parts+=("$context_name:failed")
            fi
          fi
        done

        msg="Nixpkgs: $nixpkgs_summary | Reboot: $reboot_summary | Disk: ''${disk_parts[*]}"
        if [ "''${#btrfs_parts[@]}" -gt 0 ]; then
          msg+=" | Btrfs: ''${btrfs_parts[*]}"
        fi
        if [ "''${#mdraid_parts[@]}" -gt 0 ]; then
          msg+=" | Mdraid: ''${mdraid_parts[*]}"
        fi
        if [ "''${#context_parts[@]}" -gt 0 ]; then
          msg+=" | Context: ''${context_parts[*]}"
        fi
        if [ "''${#reasons[@]}" -gt 0 ]; then
          msg+=" | Reasons: ''${reasons[*]}"
        fi

        ${sendNotify} \
          --provider healthchecks \
          --status "$notification_status" \
          --url-file "$CREDENTIALS_DIRECTORY/HC_URL" \
          --message "$msg"
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
