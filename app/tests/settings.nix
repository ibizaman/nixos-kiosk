{
  pkgs,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "app-settings";

  nodes = {
    # Node with nixos-kiosk daemon running; no kiosk.conf.
    # All five UI-settable settings are posted via curl and their side effects
    # verified: settings.json updated, hostname state file written, shadow entry
    # changed and nixosPassword field cleared by kiosk-apply-nixos-password.
    ui_all =
      { ... }:
      {
        imports = [
          ../../nix/wifi-setup.nix
        ];

        kiosk.enable = true;

        # mac80211_hwsim provides a virtual WiFi device so NetworkManager starts
        # cleanly and the daemon can bind its HTTP server.
        boot.kernelModules = [ "mac80211_hwsim" ];

        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
        ];
      };
  };

  testScript = ''
    import json

    PORT = 8000

    ui_all.start()
    ui_all.wait_for_unit("nixos-kiosk.service")

    with subtest("ui_all: POST all non-password settings updates settings.json"):
        ui_all.succeed(
            f"curl -s -f -X POST http://localhost:{PORT}/manage/settings"
            " -d 'hostname=my-kiosk'"
            " -d 'normalUrl=http://n.example.com/display'"
            " -d 'urlPrefix=http://n.example.com'"
            " -d 'updateUrl=http://u.example.com'"
        )
        s = ui_all.succeed("cat /var/lib/nixos-kiosk/settings.json")
        settings = json.loads(s)
        assert settings.get("mdnsHostname") == "my-kiosk", f"mdnsHostname wrong: {settings}"
        assert settings.get("normalUrl") == "http://n.example.com/display", f"normalUrl wrong: {settings}"
        assert settings.get("urlPrefix") == "http://n.example.com", f"urlPrefix wrong: {settings}"
        assert settings.get("updateUrl") == "http://u.example.com", f"updateUrl wrong: {settings}"

    with subtest("ui_all: hostname state file written on POST"):
        got = ui_all.succeed("cat /var/lib/nixos-kiosk/hostname").strip()
        assert got == "my-kiosk", f"hostname state file wrong: {got!r}"

    with subtest("ui_all: manage page form reflects settings.json values"):
        body = ui_all.succeed(f"curl -s http://localhost:{PORT}/manage")
        assert "http://n.example.com/display" in body, "normalUrl not in manage page"
        assert "http://u.example.com" in body, "updateUrl not in manage page"

    with subtest("ui_all: nixosPassword POST applies via kiosk-apply-nixos-password"):
        initial_shadow = ui_all.succeed("getent shadow nixos | cut -d: -f2").strip()
        ui_all.succeed(
            f"curl -s -f -X POST http://localhost:{PORT}/manage/settings"
            " -d 'nixosPassword=testpw123'"
        )
        # Restart the oneshot so it picks up the newly written password.
        ui_all.succeed("systemctl restart kiosk-apply-nixos-password.service")
        new_shadow = ui_all.succeed("getent shadow nixos | cut -d: -f2").strip()
        assert new_shadow != initial_shadow, \
            "shadow hash did not change after applying new password"
        assert new_shadow not in ("", "!", "*"), \
            f"nixos password locked/cleared after apply: {new_shadow!r}"
        # nixosPassword must be cleared from settings.json.
        s2 = ui_all.succeed("cat /var/lib/nixos-kiosk/settings.json")
        settings2 = json.loads(s2)
        assert "nixosPassword" not in settings2, \
            f"nixosPassword not cleared from settings.json: {settings2}"
  '';
}
