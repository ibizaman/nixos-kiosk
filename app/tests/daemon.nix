{
  pkgs,
  nixos-kiosk,
  ...
}:
let
  modules = import ./common.nix;
in
pkgs.testers.runNixOSTest {
  name = "app-daemon";

  interactive.sshBackdoor.enable = true;

  nodes.airgap =
    { config, ... }:
    {
      imports = with modules; [
        vwifi-server
      ];
    };

  nodes.mobile = {
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
      pkgs.jq
    ];

    imports = with modules; [
      vwifi-client
      ../../nix/wifi-setup.nix
    ];

    test.vwifi-client.mac = "74:F8:F6:00:02";

    kiosk.enable = true;
  };

  testScript =
    { nodes, ... }:
    let
      cfg = nodes.kiosk;
    in
    ''
      import json

      def get_current_url():
          return kiosk.wait_until_succeeds("nixos-kiosk chromium url", timeout=30).strip()

      airgap.start()
      mobile.start()
      kiosk.start()

      airgap.wait_for_unit("multi-user.target")
      mobile.wait_for_unit("multi-user.target")
      mobile.wait_for_unit("NetworkManager.service")
      mobile.wait_for_unit("vwifi-client.service")
      mobile.wait_for_unit("wpa_supplicant.service")

      kiosk.wait_for_unit("NetworkManager.service")
      kiosk.wait_for_unit("vwifi-client.service")
      kiosk.wait_for_unit("multi-user.target")
      kiosk.wait_for_unit("wpa_supplicant.service")
      kiosk.wait_for_unit("nixos-kiosk.service")

      with subtest("initial state: kiosk displays manage page"):
          url = get_current_url()
          expected = "http://localhost:${toString cfg.config.kiosk.setupPort}/manage"
          if url != expected:
              raise Exception(f"Unexpected URL: {url!r}, want {expected!r}")

      with subtest("nm status and profiles return valid JSON"):
          out = kiosk.succeed("nixos-kiosk nm s")
          json.loads(out)
          out = kiosk.succeed("nixos-kiosk nm p")
          json.loads(out)

      home_ssid = "HomeWifi"
      home_psk = "securepassword123"
      home_ip = "10.10.0.1"

      with subtest("mobile creates a WiFi AP"):
          out = mobile.succeed(
              f"NIXOS_KIOSK_PSK={home_psk} nixos-kiosk network-manager addAP"
              f" home-wifi '{home_ssid}' '{home_ip}'"
          )
          path = json.loads(out)
          print(f"AP profile path: {path}")
          out = mobile.succeed(f"nixos-kiosk network-manager connect {path}")
          print(f"Connect result: {out}")

      mobile.sleep(3)

      with subtest("submit WiFi credentials via kiosk web server"):
          out = kiosk.succeed(
              f"curl -s -f -X POST http://localhost:${toString cfg.config.kiosk.setupPort}/manage/wifi"
              f" --data-urlencode 'ssid={home_ssid}'"
              f" --data-urlencode 'password={home_psk}'"
          )
          print(f"Web server response: {out}")
          resp = json.loads(out)
          if resp.get("status") != "ok":
              raise Exception(f"Expected status=ok, got: {resp}")

      with subtest("daemon detects connection and switches to normal mode"):
          kiosk.wait_until_succeeds(
              "nixos-kiosk chromium url | grep -qF '${cfg.config.kiosk.normalURL}'",
              timeout=90
          )

      with subtest("normal URL is shown after switching"):
          url = get_current_url()
          if url != "${cfg.config.kiosk.normalURL}":
              raise Exception(f"Expected normal URL, got: {url!r}")

      with subtest("nm profiles shows kiosk WiFi profile"):
          out = kiosk.succeed("nixos-kiosk nm p")
          profiles = json.loads(out)
          kiosk_profile = next((p for p in profiles if p["id"] == "kiosk"), None)
          if kiosk_profile is None:
              raise Exception(f"kiosk WiFi profile not found in: {profiles}")
          if kiosk_profile.get("ssid") != home_ssid:
              raise Exception(f"kiosk profile SSID={kiosk_profile.get('ssid')!r}, want {home_ssid!r}")
    '';
}
