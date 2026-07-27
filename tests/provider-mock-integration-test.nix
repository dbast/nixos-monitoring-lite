{
  self,
  nixpkgs,
  system,
}:

(import "${nixpkgs}/nixos/lib/testing-python.nix" { inherit system; }).runTest {
  name = "provider-mock-integration-test";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];

      system.stateVersion = "25.11";
      environment.systemPackages = [ pkgs.shellcheck ];

      environment.etc = {
        "monitoring/canary.url".text = "http://127.0.0.1:8080/canary\n";
        "monitoring/systemd-failure.url".text = "http://127.0.0.1:8080/systemd-failure\n";
        "monitoring/smartd.url".text = "http://127.0.0.1:8080/smartd\n";
        "monitoring-mock.py".source = pkgs.writeText "monitoring-mock.py" ''
          from http.server import BaseHTTPRequestHandler, HTTPServer

          log_path = "/tmp/monitoring-requests.log"

          class Handler(BaseHTTPRequestHandler):
              def _record(self):
                  length = int(self.headers.get("content-length", "0"))
                  body = self.rfile.read(length).decode("utf-8", "replace")
                  with open(log_path, "a", encoding="utf-8") as log:
                      log.write(f"{self.command} {self.path}\n")
                      log.write(body)
                      log.write("\n---\n")
                  self.send_response(200)
                  self.end_headers()
                  self.wfile.write(b"ok\n")

              def do_POST(self):
                  self._record()

              def log_message(self, _format, *args):
                  return

          HTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
        '';
      };

      systemd.services.monitoring-mock = {
        description = "Local mock monitoring provider";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 /etc/monitoring-mock.py";
          Restart = "always";
        };
      };

      services.monitoringLite.canary = {
        enable = true;
        urlFile = "/etc/monitoring/canary.url";
        threshold = 100;
        nixpkgsMaxAgeDays = 0;
        extraContext.mock.script = ''
          printf 'mock=ok\n'
        '';
      };

      services.monitoringLite.systemdFail = {
        enable = true;
        enableDemo = true;
        urlFile = "/etc/monitoring/systemd-failure.url";
      };

      services.monitoringLite.smartd = {
        enable = true;
        testMode = true;
        urlFile = "/etc/monitoring/smartd.url";
        shortSelfTest.enable = true;
      };
    };

  testScript = ''
    def shellcheck_unit(unit):
        exec_start = machine.succeed(f"systemctl show -P ExecStart {unit}").strip()
        if "path=" in exec_start:
            script = exec_start.split("path=", 1)[1].split(" ;", 1)[0]
        else:
            script = exec_start.split()[0]
        machine.succeed(f"test -x {script}")
        machine.succeed(f"shellcheck {script}")

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("monitoring-mock.service")
    machine.wait_for_open_port(8080)

    shellcheck_unit("monitoring-lite-canary.service")
    shellcheck_unit("monitoring-lite-fail@monitoring-lite-fail-demo.service")
    shellcheck_unit("monitoring-lite-systemd-fail-ok.service")
    shellcheck_unit("monitoring-lite-smartd-short-self-test.service")
    shellcheck_unit("monitoring-lite-smartd-test-alert.service")
    shellcheck_unit("monitoring-lite-smartd-ok.service")

    machine.succeed("systemctl start monitoring-lite-canary.service")
    machine.wait_until_succeeds("grep -Fx 'POST /canary' /tmp/monitoring-requests.log")
    machine.fail("grep -F 'POST /canary/fail' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'Nixpkgs: disabled' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'Reboot: no' /tmp/monitoring-requests.log")

    machine.succeed("mkdir /tmp/booted-system")
    machine.succeed("ln -s /different/initrd /different/kernel /different/kernel-modules /tmp/booted-system")
    machine.succeed("ln -sfn /tmp/booted-system /run/booted-system")
    machine.succeed("systemctl start monitoring-lite-canary.service")
    machine.wait_until_succeeds("grep -F 'POST /canary/fail' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'Reboot: required' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'reboot-required' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'Disk:' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'Context: mock:mock=ok' /tmp/monitoring-requests.log")

    machine.fail("systemctl start monitoring-lite-fail-demo.service")
    machine.wait_until_succeeds("grep -F 'POST /systemd-failure/fail' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'Service monitoring-lite-fail-demo.service failed' /tmp/monitoring-requests.log")

    machine.succeed("systemctl start monitoring-lite-systemd-fail-ok.service")
    machine.wait_until_succeeds("grep -F 'POST /systemd-failure' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'systemd failure path recovered' /tmp/monitoring-requests.log")

    machine.succeed("systemctl start monitoring-lite-smartd-test-alert.service")
    machine.wait_until_succeeds("grep -F 'POST /smartd/fail' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'SMARTD_DEVICE=/dev/test' /tmp/monitoring-requests.log")

    machine.succeed("systemctl start monitoring-lite-smartd-ok.service")
    machine.wait_until_succeeds("grep -F 'POST /smartd' /tmp/monitoring-requests.log")
    machine.succeed("grep -F 'SMART monitoring recovered' /tmp/monitoring-requests.log")
  '';
}
