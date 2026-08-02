{
  pkgs,
  lib,
  nixos-kiosk,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "app-chromium";

  interactive.sshBackdoor.enable = true;

  nodes.machine = {
    environment.systemPackages = [
      pkgs.jq
      nixos-kiosk
    ];

    users.users.frame = {
      isNormalUser = true;
      group = "frame";
      extraGroups = [
        "video"
        "render"
        "input"
      ];
    };
    users.groups.frame = { };

    services.cage = {
      enable = true;

      user = "frame";

      program = lib.getExe (
        pkgs.writeShellApplication {
          name = "kiosk-chromium-setup";
          runtimeInputs = [
            pkgs.chromium
          ];
          text = ''
            chromium \
              --kiosk \
              --no-first-run \
              --disable-infobars \
              --noerrdialogs \
              --remote-debugging-address=127.0.0.1 \
              --remote-debugging-port=9222 \
              http://default
          '';
        }
      );
    };
  };

  testScript = ''
  def get_current_url():
      return machine.wait_until_succeeds("nixos-kiosk chromium url", timeout=10).strip()

  def navigate(url):
      print(machine.succeed(f"nixos-kiosk chromium navigate {url}"))

  machine.start() 
  machine.wait_for_unit("multi-user.target")
  machine.wait_for_unit("cage-tty1.service")
  machine.wait_for_open_port(9222)

  url = get_current_url()
  if url != "http://default/":
      raise Exception(f"Start URL is not as expected, got: {url}")

  navigate("http://newurl")

  url = get_current_url()
  if url != "http://newurl/":
      raise Exception(f"New URL is not as expected, got: {url}")
  '';
  }
