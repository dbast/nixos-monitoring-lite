{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.monitoringLite.smartd;
  sendNotify = import ./send-notify.nix { inherit pkgs; };
  proxyArg = if cfg.proxy != null then "--proxy ${lib.escapeShellArg cfg.proxy}" else "";
  smartdHook = pkgs.writeShellScript "smartd-monitoring-lite.sh" ''
    set -euo pipefail
    msg="SMARTD_DEVICE=$SMARTD_DEVICE
    SMARTD_FAILTYPE=$SMARTD_FAILTYPE
    SMARTD_MESSAGE=$SMARTD_MESSAGE
    SMARTD_FULLMESSAGE=$SMARTD_FULLMESSAGE"
    ${sendNotify} \
      --provider healthchecks \
      --status fail \
      --url-file ${lib.escapeShellArg cfg.urlFile} \
      --message "$msg" \
      ${proxyArg}
  '';
  shortSelfTestServices = lib.optionalAttrs cfg.shortSelfTest.enable {
    monitoring-lite-smartd-short-self-test = {
      description = "Run SMART short self-tests without waking standby disks";
      path = [ pkgs.smartmontools ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        devices=(${lib.escapeShellArgs cfg.shortSelfTest.devices})

        if [ "''${#devices[@]}" -eq 0 ]; then
          while read -r device _; do
            devices+=("$device")
          done < <(smartctl --scan-open)
        fi

        if [ "''${#devices[@]}" -eq 0 ]; then
          echo "No SMART devices found"
          exit 0
        fi

        fail=0
        for device in "''${devices[@]}"; do
          if smartctl -n standby -t short "$device"; then
            echo "Started SMART short self-test on $device"
          else
            rc=$?
            if [ "$rc" -eq 2 ]; then
              echo "Skipped SMART short self-test on standby device $device"
            else
              echo "Failed to start SMART short self-test on $device (exit $rc)"
              fail=1
            fi
          fi
        done

        exit "$fail"
      '';
    };
  };
  shortSelfTestTriggers = lib.optionalAttrs cfg.shortSelfTest.enable (
    lib.genAttrs cfg.shortSelfTest.triggerAfterUnits (_name: {
      unitConfig.OnSuccess = [ "monitoring-lite-smartd-short-self-test.service" ];
    })
  );
  shortSelfTestTimers =
    lib.optionalAttrs (cfg.shortSelfTest.enable && cfg.shortSelfTest.onCalendar != null)
      {
        monitoring-lite-smartd-short-self-test = {
          description = "Run SMART short self-tests";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.shortSelfTest.onCalendar;
            Persistent = true;
          };
        };
      };
in
{
  options.services.monitoringLite.smartd = {
    enable = lib.mkEnableOption "SMART disk monitor";

    urlFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/healthchecks/smartd.url";
      description = "Path to a file containing the base Healthchecks.io ping URL for SMART alerts (plain file, sops-nix path, or agenix path).";
    };

    testMode = lib.mkEnableOption "sending a test SMART alert on smartd startup";

    proxy = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "socks5h://127.0.0.1:9050";
      description = "Optional curl proxy URL. Set this to a local Tor SOCKS proxy if desired.";
    };

    okMessage = lib.mkOption {
      type = lib.types.str;
      default = "SMART monitoring recovered";
      description = "Message sent when manually marking the SMART check as recovered.";
    };

    shortSelfTest = {
      enable = lib.mkEnableOption "periodic SMART short self-tests";

      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SMART device paths to test. Empty means devices are discovered with smartctl --scan-open.";
      };

      onCalendar = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "weekly";
        description = "Optional systemd calendar expression for SMART short self-tests.";
      };

      triggerAfterUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Systemd service names whose successful completion should trigger SMART short self-tests.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.smartd = {
      enable = true;
      autodetect = true;
      defaults.autodetected = "-a -n standby,q -m <nomailer> -M exec ${smartdHook} ${lib.optionalString cfg.testMode "-M test"}";
      notifications = {
        mail.enable = false;
        wall.enable = false;
        x11.enable = false;
        systembus-notify.enable = false;
      };
    };

    systemd.services =
      shortSelfTestServices
      // shortSelfTestTriggers
      // {
        monitoring-lite-smartd-ok = {
          description = "Mark Healthchecks SMART check as recovered";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig.Type = "oneshot";
          path = [
            pkgs.coreutils
          ];
          script = ''
            set -euo pipefail
            msg="${cfg.okMessage} on ${config.networking.hostName} at $(date --iso-8601=seconds)"
            ${sendNotify} \
              --provider healthchecks \
              --status ok \
              --url-file ${lib.escapeShellArg cfg.urlFile} \
              --message "$msg" \
            ${proxyArg}
          '';
        };
        monitoring-lite-smartd-test-alert = lib.mkIf cfg.testMode {
          description = "Send a synthetic Healthchecks SMART failure test alert";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            Environment = [
              "SMARTD_DEVICE=/dev/test"
              "SMARTD_FAILTYPE=EmailTest"
              "SMARTD_MESSAGE=synthetic smartd test alert"
              "SMARTD_FULLMESSAGE=synthetic smartd test alert from monitoring-lite-smartd-test-alert"
            ];
            ExecStart = smartdHook;
          };
        };
      };
    systemd.timers = shortSelfTestTimers;
  };
}
