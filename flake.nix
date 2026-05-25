{
  description = "Lean Healthchecks.io monitoring modules for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forLinuxSystems = lib.genAttrs linuxSystems;
      pkgsFor = system: import nixpkgs { inherit system; };

      baseModule = {
        boot.loader.grub.enable = false;
        fileSystems."/".device = "none";
        fileSystems."/".fsType = "ext4";
        system.stateVersion = "25.05";
      };

      mkConfig =
        system: modules:
        (lib.nixosSystem {
          inherit system;
          modules = [ baseModule ] ++ modules;
        }).config;

      mkEvalCheck =
        pkgs: name: config:
        pkgs.runCommand name
          {
            evaluatedToplevel = config.system.build.toplevel.name;
          }
          ''
            touch $out
          '';
    in
    {
      nixosModules = rec {
        canary = ./modules/canary.nix;
        systemd-fail = ./modules/systemd-fail.nix;
        smartd = ./modules/smartd.nix;
        default = ./modules/default.nix;
      };

      checks = forLinuxSystems (
        system:
        let
          pkgs = pkgsFor system;
          canaryConfig = mkConfig system [
            self.nixosModules.canary
            {
              services.healthchecksLite.canary.enable = true;
              services.healthchecksLite.canary.urlFile = "/run/secrets/hc-canary.url";
            }
          ];
          btrfsConfig = mkConfig system [
            self.nixosModules.canary
            {
              fileSystems."/data" = {
                device = "none";
                fsType = "btrfs";
              };
              services.healthchecksLite.canary.enable = true;
              services.healthchecksLite.canary.urlFile = "/run/secrets/hc-canary.url";
            }
          ];
          aggregateConfig = mkConfig system [
            self.nixosModules.default
            {
              services.healthchecksLite.canary.enable = true;
              services.healthchecksLite.canary.urlFile = "/run/secrets/hc-canary.url";
              services.healthchecksLite.systemdFail.enable = true;
              services.healthchecksLite.systemdFail.urlFile = "/run/secrets/hc-systemd.url";
              services.healthchecksLite.smartd.enable = true;
              services.healthchecksLite.smartd.urlFile = "/run/secrets/hc-smartd.url";
            }
          ];
          failConfig = mkConfig system [
            self.nixosModules.systemd-fail
            {
              services.healthchecksLite.systemdFail.enable = true;
              services.healthchecksLite.systemdFail.urlFile = "/run/secrets/hc-systemd.url";
              services.healthchecksLite.systemdFail.services = [ "demo" ];
            }
          ];
        in
        {
          canary = mkEvalCheck pkgs "canary-eval" canaryConfig;
          systemd-fail = mkEvalCheck pkgs "systemd-fail-eval" failConfig;
          smartd = mkEvalCheck pkgs "smartd-eval" (
            mkConfig system [
              self.nixosModules.smartd
              {
                services.healthchecksLite.smartd.enable = true;
                services.healthchecksLite.smartd.urlFile = "/run/secrets/hc-smartd.url";
              }
            ]
          );
          aggregate = mkEvalCheck pkgs "aggregate-eval" aggregateConfig;
          canary-no-btrfs-progs =
            pkgs.runCommand "canary-no-btrfs-progs"
              {
                servicePath = lib.concatStringsSep " " (
                  map toString canaryConfig.systemd.services.healthchecks-lite-canary.path
                );
              }
              ''
                case "$servicePath" in
                  *"${pkgs.btrfs-progs}"*)
                    echo "btrfs-progs unexpectedly present for non-Btrfs host" >&2
                    exit 1
                    ;;
                esac
                touch $out
              '';
          canary-btrfs-progs =
            pkgs.runCommand "canary-btrfs-progs"
              {
                servicePath = lib.concatStringsSep " " (
                  map toString btrfsConfig.systemd.services.healthchecks-lite-canary.path
                );
              }
              ''
                case "$servicePath" in
                  *"${pkgs.btrfs-progs}"*) touch $out ;;
                  *)
                    echo "btrfs-progs missing for Btrfs host" >&2
                    exit 1
                    ;;
                esac
              '';
        }
        // {
          provider-mock-integration = import ./tests/provider-mock-integration-test.nix {
            inherit self nixpkgs system;
          };
        }
      );
    };
}
