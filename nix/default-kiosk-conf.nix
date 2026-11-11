{
  pkgs,
  hostname ? "nixos-kiosk",
}:
pkgs.writeText "kiosk.conf" ''
  # Kiosk firstboot configuration
  # Edit this file before the first boot to pre-configure your device.
  # Once the device boots, it applies these settings and renames this file
  # to kiosk.conf.applied. To reconfigure, create a new kiosk.conf and reboot.

  # WiFi network name (leave empty to skip WiFi setup)
  wifi_ssid=

  # WiFi password (leave empty for open networks, minimum 8 characters for WPA2)
  wifi_password=

  # Device hostname (used for mDNS — device will be reachable at hostname.local)
  hostname=${hostname}

  # URL the kiosk navigates to once connected to the internet
  # Leave empty to use the compiled-in default
  normal_url=

  # URL for firmware updates (leave empty to disable)
  update_url=
''
