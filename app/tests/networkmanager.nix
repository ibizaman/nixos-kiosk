{
  pkgs,
  lib,
  nixos-kiosk,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "app-networkmanager";

  interactive.sshBackdoor.enable = true;

  nodes.airgap =
    { config, ... }:
    {
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.168.1.2";
          prefixLength = 24;
        }
      ];
      services.vwifi = {
        server = {
          enable = true;
          ports.tcp = 8212;
          # uncomment if you want to enable monitor mode on another node
          # ports.spy = 8213;
          openFirewall = true;
        };
      };
    };

  nodes.ap =
    { config, ... }:
    {
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.168.1.3";
          prefixLength = 24;
        }
      ];
      services.hostapd = {
        enable = true;
        radios.wlan0 = {
          channel = 1;
          networks.wlan0 = {
            ssid = "NixOS Test Wi-Fi Network";
            authentication = {
              mode = "wpa3-sae";
              saePasswords = [ { password = "supersecret"; } ];
              enableRecommendedPairwiseCiphers = true;
            };
          };
        };
      };
      services.vwifi = {
        module = {
          enable = true;
          macPrefix = "74:F8:F6:00:01";
        };
        client = {
          enable = true;
          serverAddress = "192.168.1.2";
        };
      };
    };

  nodes.kiosk = {
    environment.systemPackages = [
      pkgs.networkmanager
      pkgs.iw
      nixos-kiosk
    ];

    networking.wireless = {
      enable = lib.mkOverride 0 true;
      autoDetectInterfaces = false;
      dbusControlled = true;
    };
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

    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = "192.168.1.3";
        prefixLength = 24;
      }
    ];
    services.vwifi = {
      module = {
        enable = true;
        macPrefix = "74:F8:F6:00:02";
      };
      client = {
        enable = true;
        serverAddress = "192.168.1.2";
      };
    };
  };

  testScript = ''
    import json

    def find_home_wifi():
        out = kiosk.succeed("nixos-kiosk network-manager profiles")
        profiles = json.loads(out)
        print(json.dumps(profiles, indent=2))

        home_wifi = None
        for p in profiles:
            if p["id"] == "home-wifi":
                home_wifi = p

        return home_wifi

    def is_home_wifi_active():
        out = kiosk.succeed("nixos-kiosk network-manager status")
        status = json.loads(out)
        print(json.dumps(status, indent=2))

        active = False
        for p in status["activeConnections"]:
            if p["id"] == "home-wifi":
                active = True

        return active

    airgap.start()
    ap.start()
    kiosk.start()

    airgap.wait_for_unit("multi-user.target")
    ap.wait_for_unit("multi-user.target")
    kiosk.wait_for_unit("NetworkManager.service")
    kiosk.wait_for_unit("vwifi-client.service")
    kiosk.wait_for_unit("multi-user.target")
    kiosk.wait_for_unit("wpa_supplicant.service")

    home_wifi = find_home_wifi()
    if not home_wifi:
        raise Exception("Could not find home-wifi profile")

    if is_home_wifi_active():
        raise Exception("home-wifi should not be activated yet")

    print(kiosk.succeed("busctl --list"))
    print(kiosk.succeed("ip link show wlan0"))
    print(kiosk.succeed("nmcli device"))
    print(kiosk.succeed("journalctl -u wpa_supplicant -b"))
    print(kiosk.succeed("journalctl -u NetworkManager -b"))
    print(kiosk.succeed("iw dev"))

    out = kiosk.succeed(f"nixos-kiosk network-manager connect {home_wifi["path"]}")
    result = json.loads(out)
    print(result)

    if not is_home_wifi_active():
        raise Exception("home-wifi should be activated")
  '';
}
