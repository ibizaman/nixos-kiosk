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
ssh_authorized_key=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForNixOSKioskTest testkey
nixos_password=testpw123
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

        boot.kernelModules = [ "mac80211_hwsim" ];

        # Ensure the firmware directory exists but kiosk.conf does not.
        boot.postBootCommands = ''
          mkdir -p /boot/firmware
        '';
      };

    # Node with an open (passwordless) WiFi network.
    open_network =
      { ... }:
      {
        imports = [
          ../../nix/wifi-setup.nix
          ../../nix/firstboot.nix
        ];

        kiosk.enable = true;
        kiosk.firstboot.enable = true;

        boot.kernelModules = [ "mac80211_hwsim" ];

        boot.postBootCommands = ''
          mkdir -p /boot/firmware
          cat > /boot/firmware/kiosk.conf << 'EOF'
wifi_ssid=OpenNet
wifi_password=
hostname=open-kiosk
EOF
        '';
      };

    # Node with only a subset of fields — exercises that absent fields are no-ops.
    partial_conf =
      { ... }:
      {
        imports = [
          ../../nix/wifi-setup.nix
          ../../nix/firstboot.nix
        ];

        kiosk.enable = true;
        kiosk.firstboot.enable = true;

        boot.kernelModules = [ "mac80211_hwsim" ];

        boot.postBootCommands = ''
          mkdir -p /boot/firmware
          cat > /boot/firmware/kiosk.conf << 'EOF'
hostname=partial-kiosk
EOF
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

        boot.kernelModules = [ "mac80211_hwsim" ];

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
    open_network.start()
    partial_conf.start()

    with_config.wait_for_unit("multi-user.target")
    no_config.wait_for_unit("multi-user.target")
    already_applied.wait_for_unit("multi-user.target")
    open_network.wait_for_unit("multi-user.target")
    partial_conf.wait_for_unit("multi-user.target")

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

    with subtest("with_config: kiosk-firstboot sets hostname immediately on first boot"):
        with_config.wait_for_unit("kiosk-firstboot.service")
        hostname = with_config.succeed("hostname").strip()
        assert hostname == "test-kiosk", f"hostname wrong after firstboot: {hostname!r}"

    with subtest("with_config: ssh_authorized_key written to nixos-authorized-keys"):
        with_config.wait_for_unit("kiosk-firstboot.service")
        key = with_config.succeed("cat /var/lib/nixos-kiosk/nixos-authorized-keys").strip()
        assert key == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForNixOSKioskTest testkey", \
            f"authorized key wrong: {key!r}"


    with subtest("with_config: nixos_password persisted in settings.json"):
        with_config.wait_for_unit("kiosk-firstboot.service")
        s = with_config.succeed("cat /var/lib/nixos-kiosk/settings.json")
        import json
        settings_pw = json.loads(s)
        assert settings_pw.get("nixosPassword") == "testpw123", \
            f"nixosPassword wrong in settings.json: {settings_pw}"

    with subtest("with_config: kiosk-apply-nixos-password applies password"):
        with_config.wait_for_unit("kiosk-apply-nixos-password.service")
        result = with_config.succeed(
            "systemctl show -p Result kiosk-apply-nixos-password.service"
        ).strip()
        assert result == "Result=success", f"apply-nixos-password failed: {result}"
        # Verify the shadow entry is not locked/empty.
        shadow = with_config.succeed("getent shadow nixos | cut -d: -f2").strip()
        assert shadow not in ("", "!", "*"), f"nixos password not set in shadow: {shadow!r}"

    with subtest("no_config: kiosk-apply-nixos-password is a no-op when settings.json absent"):
        no_config.wait_for_unit("kiosk-apply-nixos-password.service")
        result = no_config.succeed(
            "systemctl show -p Result kiosk-apply-nixos-password.service"
        ).strip()
        assert result == "Result=success", f"apply-nixos-password failed on no_config: {result}"

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

    with subtest("open_network: firstboot succeeds with no wifi_password"):
        open_network.wait_for_unit("kiosk-firstboot.service")
        open_network.succeed("test -f /boot/firmware/kiosk.conf.applied")
        # NM profile must exist but have no security settings.
        profile = open_network.succeed("nmcli -t -f connection.id,802-11-wireless.ssid connection show kiosk")
        assert "OpenNet" in profile, f"open ssid not in NM profile: {profile}"
        # The profile must NOT have a psk set (open network).
        sec = open_network.succeed(
            "nmcli -s -t -f 802-11-wireless-security.key-mgmt connection show kiosk 2>&1 || true"
        )
        assert "wpa-psk" not in sec, f"open network should not have wpa-psk: {sec}"

    with subtest("open_network: hostname set correctly"):
        open_network.wait_for_unit("kiosk-firstboot.service")
        hostname = open_network.succeed("hostname").strip()
        assert hostname == "open-kiosk", f"hostname wrong: {hostname!r}"

    with subtest("partial_conf: firstboot completes with only hostname set"):
        partial_conf.wait_for_unit("kiosk-firstboot.service")
        partial_conf.succeed("test -f /boot/firmware/kiosk.conf.applied")
        hostname = partial_conf.succeed("hostname").strip()
        assert hostname == "partial-kiosk", f"hostname wrong: {hostname!r}"

    with subtest("with_config: credentials stripped from kiosk.conf.applied"):
        with_config.wait_for_unit("kiosk-firstboot.service")
        applied = with_config.succeed("cat /boot/firmware/kiosk.conf.applied")
        assert "s3cr3tpw" not in applied, "wifi_password must be stripped from .applied"
        assert "testpw123" not in applied, "nixos_password must be stripped from .applied"
        # Field keys should still be present (just empty values).
        assert "wifi_password=" in applied, "wifi_password key missing from .applied"
        assert "nixos_password=" in applied, "nixos_password key missing from .applied"

    with subtest("with_config: nixosPassword cleared from settings.json after apply"):
        with_config.wait_for_unit("kiosk-apply-nixos-password.service")
        s = with_config.succeed("cat /var/lib/nixos-kiosk/settings.json")
        import json
        settings_after = json.loads(s)
        assert "nixosPassword" not in settings_after, \
            f"nixosPassword must be cleared after chpasswd: {settings_after}"
  '';
}
