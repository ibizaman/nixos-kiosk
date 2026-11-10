{
  pkgs,
  nixos-kiosk,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "app-firstboot";

  nodes = {
    # Node with a pre-populated kiosk.conf containing all supported fields.
    with_config =
      { lib, ... }:
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

        # Populate kiosk.conf before systemd starts so kiosk-firstboot.service finds it.
        boot.postBootCommands = ''
          mkdir -p /boot/firmware
          cat > /boot/firmware/kiosk.conf << 'EOF'
# test config
wifi_ssid=TestNetwork
wifi_password=s3cr3t
hostname=test-kiosk
normal_url=http://test.example.com/display
update_url=http://update.example.com
EOF
        '';
      };

    # Node with no kiosk.conf — init service creates the default; apply runs but is a no-op.
    no_config =
      { lib, ... }:
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
      { lib, ... }:
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

    with subtest("with_config: kiosk.conf consumed and renamed to .applied"):
        with_config.succeed("test ! -f /boot/firmware/kiosk.conf")
        with_config.succeed("test -f /boot/firmware/kiosk.conf.applied")

    with subtest("with_config: NM WiFi profile written"):
        with_config.succeed("test -f /etc/NetworkManager/system-connections/kiosk-firstboot.nmconnection")
        profile = with_config.succeed("cat /etc/NetworkManager/system-connections/kiosk-firstboot.nmconnection")
        assert "ssid=TestNetwork" in profile, f"ssid not found in profile: {profile}"
        assert "psk=s3cr3t" in profile, f"psk not found in profile: {profile}"
        assert "key-mgmt=wpa-psk" in profile, f"key-mgmt not found: {profile}"

    with subtest("with_config: settings.json updated with hostname and URLs"):
        with_config.wait_for_unit("kiosk-firstboot.service")
        s = with_config.succeed("cat /var/lib/nixos-kiosk/settings.json")
        import json
        settings = json.loads(s)
        assert settings.get("mdnsHostname") == "test-kiosk", f"mdnsHostname wrong: {settings}"
        assert settings.get("normalUrl") == "http://test.example.com/display", f"normalUrl wrong: {settings}"
        assert settings.get("updateUrl") == "http://update.example.com", f"updateUrl wrong: {settings}"

    with subtest("with_config: hostname state file written for persistence"):
        with_config.succeed("test -f /var/lib/nixos-kiosk/hostname")
        saved_hostname = with_config.succeed("cat /var/lib/nixos-kiosk/hostname").strip()
        assert saved_hostname == "test-kiosk", f"hostname state file wrong: {saved_hostname!r}"

    with subtest("with_config: kiosk-apply-hostname sets system hostname"):
        with_config.wait_for_unit("kiosk-apply-hostname.service")
        hostname = with_config.succeed("hostname").strip()
        assert hostname == "test-kiosk", f"system hostname wrong: {hostname!r}"

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
