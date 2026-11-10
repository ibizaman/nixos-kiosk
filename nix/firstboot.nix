{
  config,
  options,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.kiosk.firstboot;

  defaultConfig = pkgs.writeText "kiosk.conf" ''
    # Kiosk firstboot configuration
    # Edit this file before the first boot to pre-configure your device.
    # Once the device boots, it applies these settings and renames this file
    # to kiosk.conf.applied. To reconfigure, create a new kiosk.conf and reboot.

    # WiFi network name (leave empty to skip WiFi setup)
    wifi_ssid=

    # WiFi password (leave empty for open networks)
    wifi_password=

    # Device hostname (used for mDNS — device will be reachable at hostname.local)
    hostname=nixos-kiosk

    # URL the kiosk navigates to once connected to the internet
    # Leave empty to use the compiled-in default
    normal_url=

    # URL for firmware updates (leave empty to disable)
    update_url=
  '';

  applyScript = pkgs.writeShellScript "kiosk-firstboot" ''
    set -euo pipefail

    CONFIG=/boot/firmware/kiosk.conf
    APPLIED=/boot/firmware/kiosk.conf.applied

    if [ ! -f "$CONFIG" ]; then
      echo "No firstboot config at $CONFIG, skipping."
      exit 0
    fi

    echo "Applying firstboot configuration from $CONFIG"

    parse_value() {
      grep "^$1=" "$CONFIG" 2>/dev/null | head -1 | cut -d= -f2-
    }

    wifi_ssid=$(parse_value wifi_ssid)
    wifi_password=$(parse_value wifi_password)
    hostname=$(parse_value hostname)
    normal_url=$(parse_value normal_url)
    update_url=$(parse_value update_url)

    if [ -n "$wifi_ssid" ]; then
      echo "Writing WiFi profile for: $wifi_ssid"
      mkdir -p /etc/NetworkManager/system-connections
      PROFILE=/etc/NetworkManager/system-connections/kiosk-firstboot.nmconnection
      uuid=$(${pkgs.util-linux}/bin/uuidgen)

      printf '[connection]\nid=kiosk-firstboot\nuuid=%s\ntype=wifi\nautoconnect=true\n\n' "$uuid" > "$PROFILE"
      printf '[wifi]\nmode=infrastructure\nssid=%s\n\n' "$wifi_ssid" >> "$PROFILE"

      if [ -n "$wifi_password" ]; then
        printf '[wifi-security]\nauth-alg=open\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$wifi_password" >> "$PROFILE"
      fi

      printf '[ipv4]\nmethod=auto\n\n[ipv6]\naddr-gen-mode=default\nmethod=auto\n' >> "$PROFILE"
      chmod 600 "$PROFILE"
    fi

    if [ -n "$hostname" ]; then
      echo "Setting hostname: $hostname"
      ${pkgs.systemd}/bin/hostnamectl set-hostname "$hostname"
    fi

    SETTINGS=/var/lib/nixos-kiosk/settings.json
    existing='{}'
    if [ -f "$SETTINGS" ]; then
      existing=$(cat "$SETTINGS")
    fi

    new_settings=$(printf '%s' "$existing" | ${pkgs.jq}/bin/jq \
      --arg hn "$hostname" \
      --arg nu "$normal_url" \
      --arg uu "$update_url" \
      '(if $hn != "" then .mdnsHostname = $hn else . end) |
       (if $nu != "" then .normalUrl = $nu else . end) |
       (if $uu != "" then .updateUrl = $uu else . end)')

    printf '%s\n' "$new_settings" > "$SETTINGS"
    chown kiosk-controller:kiosk-controller "$SETTINGS" 2>/dev/null || true
    chmod 640 "$SETTINGS"

    echo "Done. Renaming $CONFIG to $APPLIED"
    mv "$CONFIG" "$APPLIED"
  '';

  initScript = pkgs.writeShellScript "kiosk-firstboot-init" ''
    set -euo pipefail

    CONFIG=/boot/firmware/kiosk.conf
    APPLIED=/boot/firmware/kiosk.conf.applied

    if [ -f "$CONFIG" ] || [ -f "$APPLIED" ]; then
      exit 0
    fi

    echo "Creating default kiosk.conf on firmware partition"
    mkdir -p /boot/firmware
    cp ${defaultConfig} "$CONFIG"
  '';
in
{
  options.kiosk.firstboot = {
    enable = lib.mkEnableOption "NixOS Kiosk firstboot configuration from /boot/firmware/kiosk.conf";
  };

  config = lib.mkIf cfg.enable (
    {
      # Create the default kiosk.conf if neither .conf nor .applied exists.
      # This runs at every boot but is a no-op once kiosk.conf.applied is present.
      systemd.services.kiosk-firstboot-init = {
        description = "Create default kiosk.conf on firmware partition if absent";

        wantedBy = [ "multi-user.target" ];
        before = [ "kiosk-firstboot.service" ];
        after = [ "local-fs.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = initScript;
        };
  };

    systemd.services.kiosk-firstboot = {
      description = "Apply kiosk firstboot configuration from firmware partition";

      wantedBy = [ "multi-user.target" ];
      before = [
        "NetworkManager.service"
        "nixos-kiosk.service"
      ];
      after = [
        "local-fs.target"
        "systemd-tmpfiles-setup.service"
          "kiosk-firstboot-init.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = applyScript;
      };
    };
    }
    // lib.optionalAttrs (options ? sdImage) {
      # Bake the default kiosk.conf into the firmware partition of the SD image
      # so users can edit it before first boot.
      sdImage.populateFirmwareCommands = lib.mkAfter ''
        cp ${defaultConfig} firmware/kiosk.conf
      '';
    }
  );
}
