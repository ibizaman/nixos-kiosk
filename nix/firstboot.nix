{
  config,
  options,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.kiosk.firstboot;
  # config.kiosk.hostname is defined by wifi-setup.nix; fall back gracefully
  # if this module is used without it.
  compiledHostname = config.kiosk.hostname or "nixos-kiosk";

  hostnameStateFile = "/var/lib/nixos-kiosk/hostname";

  defaultConfig = import ./default-kiosk-conf.nix { inherit pkgs; hostname = compiledHostname; };

  applyScript = pkgs.writeShellScript "kiosk-firstboot" ''
    set -euo pipefail

    CONFIG=/boot/firmware/kiosk.conf

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
      echo "Configuring WiFi: $wifi_ssid"

      if [ -n "$wifi_password" ] && [ "''${#wifi_password}" -lt 8 ]; then
        echo "Error: wifi_password must be at least 8 characters (WPA2 requirement)" >&2
        exit 1
      fi

      # Remove any existing kiosk profile so we can replace it cleanly.
      ${pkgs.networkmanager}/bin/nmcli connection delete kiosk 2>/dev/null || true

      nmcli_args=(connection add type wifi con-name kiosk ssid "$wifi_ssid" connection.autoconnect yes)
      if [ -n "$wifi_password" ]; then
        nmcli_args+=(wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$wifi_password")
      fi
      ${pkgs.networkmanager}/bin/nmcli "''${nmcli_args[@]}"

      # Start connecting asynchronously so the daemon, which is already running
      # in setup mode at this point, detects the "activating" connection and
      # transitions from setup to normal mode.
      ${pkgs.networkmanager}/bin/nmcli connection up kiosk --wait 0 || true
    fi

    if [ -n "$hostname" ]; then
      echo "Persisting hostname: $hostname"
      # Write to state file so kiosk-apply-hostname.service re-applies on every boot,
      # even after nixos-activation rewrites /etc/hostname to the compiled-in value.
      printf '%s' "$hostname" > ${hostnameStateFile}
      chown kiosk-controller:kiosk-controller ${hostnameStateFile} 2>/dev/null || true
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

    echo "Done. Renaming $CONFIG to $CONFIG.applied"
    mv "$CONFIG" "$CONFIG.applied"
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

  applyHostnameScript = pkgs.writeShellScript "kiosk-apply-hostname" ''
    set -euo pipefail

    STATE=${hostnameStateFile}

    if [ ! -f "$STATE" ]; then
      exit 0
    fi

    hostname=$(cat "$STATE")
    if [ -z "$hostname" ]; then
      exit 0
    fi

    echo "Restoring hostname: $hostname"
    ${pkgs.systemd}/bin/hostnamectl set-hostname "$hostname"
  '';
in
{
  options.kiosk.firstboot = {
    enable = lib.mkEnableOption "NixOS Kiosk firstboot configuration from /boot/firmware/kiosk.conf";
  };

  config = lib.mkIf cfg.enable (
    {
      # When firstboot is enabled, let avahi follow the runtime system hostname
      # (set by kiosk-apply-hostname.service) rather than the compile-time NixOS value.
      # An empty string makes the avahi module omit host-name= from its config.
      services.avahi.hostName = lib.mkForce "";

      # Create the default kiosk.conf if neither .conf nor .applied exists.
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

      # Apply settings from kiosk.conf on first boot.
      systemd.services.kiosk-firstboot = {
        description = "Apply kiosk firstboot configuration from firmware partition";

        wantedBy = [ "multi-user.target" ];
        # Run after nixos-kiosk so the daemon is already in setup mode when
        # firstboot adds and activates the WiFi connection.  The daemon then
        # detects the "activating" connection and transitions to normal mode on
        # its own, giving the user a brief view of the setup UI before the
        # kiosk switches to the normal URL.
        after = [
          "NetworkManager.service"
          "nixos-kiosk.service"
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

      # Re-apply the persisted hostname on every boot, after nixos-activation
      # has written the compile-time /etc/hostname.
      systemd.services.kiosk-apply-hostname = {
        description = "Restore kiosk firstboot hostname after NixOS activation";

        wantedBy = [ "multi-user.target" ];
        # nixos-activation overwrites /etc/hostname; run after it.
        after = [
          "nixos-activation.service"
          "systemd-tmpfiles-setup.service"
        ];
        # avahi and NetworkManager should see the correct hostname from the start.
        before = [
          "avahi-daemon.service"
          "NetworkManager.service"
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = applyHostnameScript;
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
