{
  pkgs,
  nixos-kiosk,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "app-networkmanager";

  nodes.machine = {
    environment.systemPackages = [
      nixos-kiosk
    ];

    networking.networkmanager = {
      enable = true;

      ensureProfiles.profiles = {
        home-wifi = {
          connection = {
            id = "home-wifi";
            permissions = "";
            type = "wifi";
          };
          ipv4 = {
            dns-search = "";
            method = "auto";
          };
          ipv6 = {
            addr-gen-mode = "stable-privacy";
            dns-search = "";
            method = "auto";
          };
          wifi = {
            mac-address-blacklist = "";
            mode = "infrastructure";
            ssid = "Home Wi-Fi";
          };
          wifi-security = {
            auth-alg = "open";
            key-mgmt = "wpa-psk";
            psk = "a_password";
          };
        };
      };
    };
  };

  testScript = ''
  import json

  machine.start()

  machine.wait_for_unit("NetworkManager.service")
  machine.wait_for_unit("multi-user.target")

  machine.succeed('nixos-kiosk network-manager devices')
  out = machine.succeed('nixos-kiosk network-manager profiles')
  profiles = json.loads(out)

  found = False
  for p in profiles:
      if p["id"] == "home-wifi":
          found = True

  if not found:
      raise Exception("Could not find home-wifi profile")
  '';
}
