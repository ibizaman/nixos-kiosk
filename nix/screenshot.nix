{
  pkgs,
  nixos-kiosk,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "screenshot-setup-form";

  nodes.kiosk = {
    imports = [ ./wifi-setup.nix ];

    kiosk.enable = true;
    kiosk.chromiumKioskEnable = false;
    kiosk.fixedInsecureKioskPassword = "12345678";
  };

  testScript = ''
    kiosk.wait_for_unit("multi-user.target")
    kiosk.wait_for_unit("nixos-kiosk.service")
    kiosk.wait_for_unit("cage-tty1.service")
    kiosk.wait_until_succeeds("nixos-kiosk chromium url", timeout=60)
    kiosk.wait_until_succeeds(
        "nixos-kiosk chromium navigate http://localhost:8000/",
        timeout=30
    )
    kiosk.sleep(3)
    kiosk.screenshot("setup-form")
  '';
}
