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

    # Node where kiosk.normalURL and kiosk.urlPrefix NixOS options are set at
    # build time.  A UI POST must override both in settings.json, and the manage
    # page must render the settings.json values (not the NixOS defaults).
    nixos_option_vs_settings =
      { ... }:
      {
        imports = [
          ../../nix/wifi-setup.nix
        ];

        kiosk.enable = true;
        kiosk.normalURL = "http://nixos.example.com/display";
        kiosk.urlPrefix = "http://nixos.example.com";

        boot.kernelModules = [ "mac80211_hwsim" ];

        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
        ];
      };

    # Node where kiosk.conf sets values A on first boot; a UI POST then
    # overrides them to values B.  settings.json must end up with values B.
    conf_then_ui =
      { ... }:
      {
        imports = [
          ../../nix/wifi-setup.nix
          ../../nix/firstboot.nix
        ];

        kiosk.enable = true;
        kiosk.firstboot.enable = true;

        boot.kernelModules = [ "mac80211_hwsim" ];

        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
        ];

        boot.postBootCommands = ''
          mkdir -p /boot/firmware
          cat > /boot/firmware/kiosk.conf << 'EOF'
hostname=conf-kiosk
normal_url=http://conf.example.com/display
url_prefix=http://conf.example.com
update_url=http://cu.example.com
EOF
        '';
      };
  };

  testScript = ''
    import json

    PORT = 8000

    ui_all.start()
    conf_then_ui.start()
    nixos_option_vs_settings.start()

    ui_all.wait_for_unit("nixos-kiosk.service")
    conf_then_ui.wait_for_unit("multi-user.target")
    nixos_option_vs_settings.wait_for_unit("nixos-kiosk.service")

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

    with subtest("conf_then_ui: firstboot writes conf values A to settings.json"):
        conf_then_ui.wait_for_unit("kiosk-firstboot.service")
        s = conf_then_ui.succeed("cat /var/lib/nixos-kiosk/settings.json")
        settings_a = json.loads(s)
        assert settings_a.get("mdnsHostname") == "conf-kiosk", f"conf mdnsHostname wrong: {settings_a}"
        assert settings_a.get("normalUrl") == "http://conf.example.com/display", f"conf normalUrl wrong: {settings_a}"
        assert settings_a.get("urlPrefix") == "http://conf.example.com", f"conf urlPrefix wrong: {settings_a}"
        assert settings_a.get("updateUrl") == "http://cu.example.com", f"conf updateUrl wrong: {settings_a}"

    with subtest("conf_then_ui: UI POST overrides conf values with values B"):
        conf_then_ui.wait_for_unit("nixos-kiosk.service")
        conf_then_ui.succeed(
            f"curl -s -f -X POST http://localhost:{PORT}/manage/settings"
            " -d 'hostname=ui-kiosk'"
            " -d 'normalUrl=http://ui.example.com/display'"
            " -d 'urlPrefix=http://ui.example.com'"
            " -d 'updateUrl=http://uu.example.com'"
        )
        s = conf_then_ui.succeed("cat /var/lib/nixos-kiosk/settings.json")
        settings_b = json.loads(s)
        assert settings_b.get("mdnsHostname") == "ui-kiosk", f"ui mdnsHostname wrong: {settings_b}"
        assert settings_b.get("normalUrl") == "http://ui.example.com/display", f"ui normalUrl wrong: {settings_b}"
        assert settings_b.get("urlPrefix") == "http://ui.example.com", f"ui urlPrefix wrong: {settings_b}"
        assert settings_b.get("updateUrl") == "http://uu.example.com", f"ui updateUrl wrong: {settings_b}"

    with subtest("nixos_option_vs_settings: manage page shows NixOS option values before any POST"):
        body = nixos_option_vs_settings.succeed(f"curl -s http://localhost:{PORT}/manage")
        assert "http://nixos.example.com/display" in body, \
            "NixOS normalURL not shown on manage page before override"

    with subtest("nixos_option_vs_settings: UI POST overrides NixOS option values in settings.json"):
        nixos_option_vs_settings.succeed(
            f"curl -s -f -X POST http://localhost:{PORT}/manage/settings"
            " -d 'normalUrl=http://ui2.example.com/display'"
            " -d 'urlPrefix=http://ui2.example.com'"
        )
        s = nixos_option_vs_settings.succeed("cat /var/lib/nixos-kiosk/settings.json")
        settings = json.loads(s)
        assert settings.get("normalUrl") == "http://ui2.example.com/display", \
            f"normalUrl not overridden by UI: {settings}"
        assert settings.get("urlPrefix") == "http://ui2.example.com", \
            f"urlPrefix not overridden by UI: {settings}"

    with subtest("nixos_option_vs_settings: manage page renders settings.json values after POST"):
        body = nixos_option_vs_settings.succeed(f"curl -s http://localhost:{PORT}/manage")
        assert "http://ui2.example.com/display" in body, \
            "settings.json normalUrl not shown on manage page after override"
        assert "http://nixos.example.com/display" not in body, \
            "NixOS normalURL still shown on manage page after settings.json override"
  '';
}
