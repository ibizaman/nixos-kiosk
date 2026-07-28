{
  pkgs,
  nixos-kiosk,
  ...
}:
let
  modules = import ./common.nix;
in
pkgs.testers.runNixOSTest {
  name = "app-networkmanager";

  interactive.sshBackdoor.enable = true;

  nodes.airgap =
    { config, ... }:
    {
      imports = with modules; [
        vwifi-server
      ];
    };

  nodes.ap = {
    environment.systemPackages = [
      nixos-kiosk
    ];

    imports = with modules; [
      vwifi-client
    ];

    test.vwifi-client.mac = "74:F8:F6:00:01";
  };

  nodes.kiosk = {
    environment.systemPackages = [
      pkgs.networkmanager
      pkgs.iw
      nixos-kiosk
    ];

    imports = with modules; [
      vwifi-client
    ];

    test.vwifi-client.mac = "74:F8:F6:00:02";
  };

  testScript = ''
    import json

    def find_home_wifi(ssid):
        out = kiosk.succeed("nixos-kiosk network-manager profiles")
        profiles = json.loads(out)
        print(json.dumps(profiles, indent=2))

        home_wifi = None
        for p in profiles:
            if p["id"] == ssid:
                home_wifi = p

        return home_wifi

    def is_home_wifi_active(ssid):
        out = kiosk.succeed("nixos-kiosk network-manager status")
        status = json.loads(out)
        print(json.dumps(status, indent=2))

        active = False
        for p in status["activeConnections"]:
            if p["id"] == ssid:
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

    ssid = "Kiosk Setup"

    home_wifi = find_home_wifi(ssid)
    if home_wifi:
        raise Exception("Should not already find home-wifi profile")

    if is_home_wifi_active(ssid):
        raise Exception("home-wifi should not be activated yet")

    print(kiosk.succeed("busctl --list"))
    print(kiosk.succeed("ip link show wlan0"))
    print(kiosk.succeed("nmcli device"))
    print(kiosk.succeed("journalctl -u wpa_supplicant -b"))
    print(kiosk.succeed("journalctl -u NetworkManager -b"))
    print(kiosk.succeed("iw dev"))

    out = ap.succeed(f"NIXOS_KIOSK_PSK=asecurepassword nixos-kiosk network-manager addAP kiosk-setup-ap '{ssid}'")
    result = json.loads(out)
    print(result)

    out = kiosk.succeed(f"NIXOS_KIOSK_PSK=asecurepassword nixos-kiosk network-manager add '{ssid}'")
    result = json.loads(out)
    print(result)

    home_wifi = find_home_wifi(ssid)
    if not home_wifi:
        raise Exception("Could not find home-wifi profile")

    if not is_home_wifi_active(ssid):
        raise Exception("home-wifi should be activated")
  '';
}
