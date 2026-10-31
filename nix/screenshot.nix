{
  pkgs,
  nixos-kiosk,
  ...
}:
let
  modules = import ../app/tests/common.nix;
in
pkgs.testers.runNixOSTest {
  name = "screenshot";

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
      pkgs.curl
    ];

    imports = with modules; [
      vwifi-client
      ../nix/wifi-setup.nix
    ];

    test.vwifi-client.mac = "74:F8:F6:00:02";
    test.vwifi-client.ip = "192.168.1.4";

    kiosk.enable = true;
    kiosk.package = nixos-kiosk;
    kiosk.chromiumKioskEnable = true;
    kiosk.fixedInsecureKioskPassword = "12345678";

    boot.kernelParams = [ "video=1280x1024" ];
  };

  testScript = ''
    import json

    airgap.start()
    ap.start()
    kiosk.start()

    airgap.wait_for_unit("multi-user.target")
    ap.wait_for_unit("multi-user.target")
    ap.wait_for_unit("NetworkManager.service")
    ap.wait_for_unit("vwifi-client.service")
    ap.wait_for_unit("wpa_supplicant.service")

    kiosk.wait_for_unit("NetworkManager.service")
    kiosk.wait_for_unit("vwifi-client.service")
    kiosk.wait_for_unit("multi-user.target")
    kiosk.wait_for_unit("wpa_supplicant.service")
    kiosk.wait_for_unit("nixos-kiosk.service")
    kiosk.wait_for_open_port(8000)
    kiosk.wait_for_unit("cage-tty1.service")
    kiosk.wait_until_succeeds("nixos-kiosk chromium url", timeout=60)

    kiosk.wait_until_succeeds(
        "nixos-kiosk chromium navigate http://localhost:8000/manage",
        timeout=30
    )
    kiosk.sleep(3)
    kiosk.succeed("nixos-kiosk chromium screenshot /tmp/setup-form.png")
    kiosk.copy_from_vm("/tmp/setup-form.png", "")

    home_ssid = "HomeWifi"
    home_psk = "securepassword123"
    home_ip = "10.10.0.1"

    out = ap.succeed(
        f"NIXOS_KIOSK_PSK={home_psk} nixos-kiosk network-manager addAP"
        f" home-wifi '{home_ssid}' '{home_ip}'"
    )
    path = json.loads(out)
    ap.wait_until_succeeds(f"nixos-kiosk network-manager connect {path}", timeout=60)

    out = kiosk.succeed(
        f"curl -s -f -X POST http://localhost:8000/manage/wifi"
        f" --data-urlencode 'ssid={home_ssid}'"
        f" --data-urlencode 'password={home_psk}'"
    )
    resp = json.loads(out)
    if resp.get("status") != "ok":
        raise Exception(f"Expected status=ok, got: {resp}")

    kiosk.wait_until_succeeds(
        "nixos-kiosk nm s | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if any(c[\"id\"]==\"kiosk\" and c[\"stateName\"]==\"activated\" for c in d[\"activeConnections\"]) else 1)'",
        timeout=60
    )

    kiosk.wait_until_succeeds(
        "nixos-kiosk chromium navigate http://localhost:8000/manage",
        timeout=30
    )
    kiosk.sleep(3)
    kiosk.succeed("nixos-kiosk chromium screenshot /tmp/connected.png")
    kiosk.copy_from_vm("/tmp/connected.png", "")
  '';
}
