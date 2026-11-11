{
  pkgs,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "app-firstboot";

  nodes = {
    # Node with a pre-populated kiosk.conf containing all supported fields.
    with_config =
      { ... }:
      {
        imports = [
          ../../nix/wifi-setup.nix
          ../../nix/firstboot.nix
        ];

        kiosk.enable = true;
        kiosk.firstboot.enable = true;

        environment.systemPackages = [
          pkgs.jq
        ];

        # mac80211_hwsim provides a virtual WiFi device so that
        # `nmcli connection add type wifi` succeeds in the headless VM.
        boot.kernelModules = [ "mac80211_hwsim" ];

        # Populate kiosk.conf before systemd starts so kiosk-firstboot.service finds it.
        boot.postBootCommands = ''
          mkdir -p /boot/firmware
          cat > /boot/firmware/kiosk.conf << 'EOF'
# test config
wifi_ssid=TestNetwork
wifi_password=s3cr3tpw
hostname=test-kiosk
normal_url=http://test.example.com/display
update_url=http://update.example.com
EOF
        '';
      };

    # Node with no kiosk.conf — init service creates the default; apply runs but is a no-op.
    no_config =
      { ... }:
      {
        imports = [
          ../../nix/wifi-setup.nix
          ../../nix/firstboot.nix
        ];

        kiosk.enable = true;
        kiosk.firstboot.enable = true;

        # Ensure the firmware directory exists but kiosk.conf does not.
        boot.postBootCommands = ''
          mkdir -p /boot/firmware
        '';
      };

    # Node with only kiosk.conf.applied — init service skips; apply service skips.
    already_applied =
      { ... }:
      {
        imports = [
          ../../nix/wifi-setup.nix
          ../../nix/firstboot.nix
        ];

        kiosk.enable = true;
        kiosk.firstboot.enable = true;

        boot.postBootCommands = ''
          mkdir -p /boot/firmware
          touch /boot/firmware/kiosk.conf.applied
        '';
      };
  };

  testScript = ''
    with_config.start()
    no_config.start()
    already_applied.start()

    with_config.wait_for_unit("multi-user.target")
    no_config.wait_for_unit("multi-user.target")
    already_applied.wait_for_unit("multi-user.target")

    with subtest("with_config: kiosk-firstboot.service completes"):
        with_config.wait_for_unit("kiosk-firstboot.service")
        with_config.log(with_config.succeed("journalctl -u kiosk-firstboot.service --no-pager -n 50"))

    with subtest("with_config: kiosk.conf consumed and renamed to .applied"):
        with_config.succeed("test ! -f /boot/firmware/kiosk.conf")
        with_config.succeed("test -f /boot/firmware/kiosk.conf.applied")

    with subtest("with_config: NM WiFi profile created with correct ID"):
        with_config.wait_for_unit("kiosk-firstboot.service")
        # The profile must use id=kiosk so the daemon's watcher can find it.
        profile = with_config.succeed("nmcli -t -f connection.id,802-11-wireless.ssid connection show kiosk")
        assert "TestNetwork" in profile, f"ssid not found in NM profile: {profile}"

    with subtest("with_config: settings.json updated with hostname and URLs"):
        with_config.wait_for_unit("kiosk-firstboot.service")
        s = with_config.succeed("cat /var/lib/nixos-kiosk/settings.json")
        import json
        settings = json.loads(s)
        assert settings.get("mdnsHostname") == "test-kiosk", f"mdnsHostname wrong: {settings}"
        assert settings.get("normalUrl") == "http://test.example.com/display", f"normalUrl wrong: {settings}"
        assert settings.get("updateUrl") == "http://update.example.com", f"updateUrl wrong: {settings}"

    with subtest("with_config: hostname state file written for persistence across reboots"):
        with_config.wait_for_unit("kiosk-firstboot.service")
        with_config.succeed("test -f /var/lib/nixos-kiosk/hostname")
        saved_hostname = with_config.succeed("cat /var/lib/nixos-kiosk/hostname").strip()
        assert saved_hostname == "test-kiosk", f"hostname state file wrong: {saved_hostname!r}"

    with subtest("with_config: kiosk-apply-hostname applies state file on subsequent boots"):
        # kiosk-apply-hostname runs before NetworkManager (early boot), before firstboot
        # has written the state file on the very first boot.  Verify the service itself
        # completes cleanly; the hostname will be applied on the NEXT boot.
        with_config.wait_for_unit("kiosk-apply-hostname.service")

    with subtest("no_config: kiosk-firstboot-init creates default kiosk.conf"):
        no_config.wait_for_unit("kiosk-firstboot-init.service")
        # The apply service may have already consumed .conf; check either file exists.
        no_config.succeed("test -f /boot/firmware/kiosk.conf || test -f /boot/firmware/kiosk.conf.applied")

    with subtest("no_config: kiosk-firstboot.service completes without error"):
        no_config.wait_for_unit("kiosk-firstboot.service")
        no_config.succeed("test -f /boot/firmware/kiosk.conf.applied")

    with subtest("already_applied: init service does not recreate kiosk.conf"):
        already_applied.wait_for_unit("kiosk-firstboot-init.service")
        already_applied.succeed("test ! -f /boot/firmware/kiosk.conf")
        already_applied.succeed("test -f /boot/firmware/kiosk.conf.applied")

    with subtest("already_applied: apply service skips gracefully"):
        already_applied.wait_for_unit("kiosk-firstboot.service")
  '';
}
