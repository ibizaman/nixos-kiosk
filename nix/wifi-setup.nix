{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.kiosk;
in
{
  options.kiosk = {
    enable = lib.mkEnableOption "NixOS Kiosk";

    chromiumKioskEnable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set to false to disable kiosk mode for debugging (shows browser chrome).
      '';
    };

    showJournal = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Replace chromium with journalctl output
      '';
    };

    dnsmasqDebug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable debug output in dnsmasq
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
    };

    countryCode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "US";
      description = ''
        ISO 3166-1 alpha-2 country code for the WiFi regulatory domain.
        Required on brcmfmac devices (Raspberry Pi, Orange Pi) to prevent
        the AP from being disabled by a regulatory domain reset to WORLD.
      '';
    };

    kioskIP = lib.mkOption {
      type = lib.types.str;
      default = "192.168.4.1";
    };

    dhcpRange = lib.mkOption {
      type = lib.types.str;
      default = "192.168.4.10,192.168.4.100,12h";
    };

    fixedInsecureKioskPassword = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "12345678";
    };

    normalURL = lib.mkOption {
      type = lib.types.str;
      default = "https://example.com/display/view";
    };

    chromiumPort = lib.mkOption {
      type = lib.types.port;
      default = 9222;
    };

    setupPort = lib.mkOption {
      type = lib.types.port;
      default = 8000;
    };

    setupSSID = lib.mkOption {
      type = lib.types.str;
      default = "Kiosk Setup";
    };

    connectivityCheckHost = lib.mkOption {
      type = lib.types.str;
      default = "www.github.com";
      description = ''
        Host TCP-dialled on port 443 to confirm internet access before
        switching to normal mode.
      '';
    };

    ntpServer = lib.mkOption {
      type = lib.types.str;
      default = "0.nixos.pool.ntp.org";
      description = ''
        NTP server queried over UDP/123 to sync the clock once internet
        is confirmed.
      '';
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "nixos-kiosk";
      description = ''
        mDNS hostname for the kiosk. The device will be reachable at
        <hostname>.local on the network. Also used as the nginx virtual host.
      '';
    };

    urlPrefix = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        If non-empty, the navigator only redirects Chromium when the current
        URL does not start with this prefix. Useful for multi-page sites where
        the user navigates to sub-pages (e.g. set to the site's origin so any
        page under that origin is considered "correct").
      '';
    };

    persistBrowserSession = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Persist the Chromium profile across reboots by storing it under
        /var/lib/nixos-kiosk/chromium. Cookies, localStorage, and cached
        OAuth tokens survive restarts, so a one-time login is sufficient.
      '';
    };

    onScreenKeyboard = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Start wvkbd-mobintl as a background process inside the cage session,
        providing an on-screen keyboard for touchscreen input.
      '';
    };

  };
  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
    environment.systemPackages = [
      pkgs.dig
      cfg.package
    ];

    networking.networkmanager.enable = true;
    services.timesyncd.enable = lib.mkDefault true;
    networking.networkmanager.wifi.powersave = false;
    # Write DNS servers directly from DHCP into /etc/resolv.conf rather than
    # routing everything through the local dnsmasq (which serves captive-portal
    # responses and would resolve all hostnames to the kiosk's own IP).
    networking.networkmanager.dns = "default";

    # Enables touchscreen
    services.libinput.enable = true;

    # Prevent touchscreen and tablet devices from emitting pointer events (which
    # would show a cursor). Touch events via wl_touch are unaffected.
    services.udev.extraRules = ''
      ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{ID_INPUT_MOUSE}="0", ENV{ID_INPUT_POINTER}="0"
      ENV{ID_INPUT_TABLET}=="1", ENV{ID_INPUT_MOUSE}="0", ENV{ID_INPUT_POINTER}="0"
    '';

    systemd.tmpfiles.rules = [
      "d /var/lib/nixos-kiosk 0750 kiosk-controller kiosk-controller -"
      # Hostname state file writable by kiosk-controller so the UI can persist it.
      "f /var/lib/nixos-kiosk/hostname 0640 kiosk-controller kiosk-controller -"
    ] ++ lib.optional cfg.persistBrowserSession
      "d /var/lib/nixos-kiosk/chromium 0750 frame frame -";

    # Apply nixos user password from settings.json on every boot.
    # kiosk-firstboot may write nixosPassword into settings.json; running
    # after it ensures the latest value is picked up on first boot too.
    systemd.services.kiosk-apply-nixos-password = {
      description = "Apply nixos login password from kiosk settings";

      wantedBy = [ "multi-user.target" ];
      after = [
        "nixos-activation.service"
        "kiosk-firstboot.service"
        "systemd-tmpfiles-setup.service"
      ];
      wants = [ "kiosk-firstboot.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail
        SETTINGS=/var/lib/nixos-kiosk/settings.json
        if [ ! -f "$SETTINGS" ]; then exit 0; fi
        PASSWORD=$(${pkgs.jq}/bin/jq -r '.nixosPassword // empty' "$SETTINGS")
        if [ -z "$PASSWORD" ]; then exit 0; fi
        printf 'nixos:%s\n' "$PASSWORD" | ${pkgs.shadow}/bin/chpasswd
        # Clear the password from settings.json now that it has been applied.
        ${pkgs.jq}/bin/jq 'del(.nixosPassword)' "$SETTINGS" > "$SETTINGS.tmp" \
          && mv "$SETTINGS.tmp" "$SETTINGS"
      '';
    };

    # Always active
    systemd.services.nixos-kiosk = {
      description = "NixOS Kiosk";

      wantedBy = [
        "multi-user.target"
      ];

      after = [
        "NetworkManager.service"
      ];

      serviceConfig = {
        Type = "notify";
        ExecStart = "${cfg.package}/bin/nixos-kiosk daemon '${cfg.setupSSID}' ${cfg.normalURL} --port ${toString cfg.setupPort} --chromium-port ${toString cfg.chromiumPort} --ip ${cfg.kioskIP} --hostname ${cfg.hostname} --settings-path /var/lib/nixos-kiosk/settings.json --hostname-state-path /var/lib/nixos-kiosk/hostname --connectivity-check-host ${cfg.connectivityCheckHost} --ntp-server ${cfg.ntpServer}"
            + lib.optionalString (cfg.urlPrefix != "") " --url-prefix '${cfg.urlPrefix}'";
        User = "kiosk-controller";
        Restart = "always";
        AmbientCapabilities = [ "CAP_SYS_TIME" ];
      };
      environment = (
        lib.optionalAttrs (cfg.fixedInsecureKioskPassword != null) {
          NIXOS_KIOSK_PSK = cfg.fixedInsecureKioskPassword;
        }
      );
    };

    users.users.kiosk-controller = {
      isSystemUser = true;
      group = "kiosk-controller";
    };

    users.groups.kiosk-controller = { };
    # nginx reads the captive-portal TLS key from /var/lib/nixos-kiosk/
    users.users.nginx.extraGroups = [ "kiosk-controller" ];
    # Allow kiosk-controller to manage WiFi
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.user == "kiosk-controller") {
          if (action.id == "org.freedesktop.NetworkManager.network-control" ||
              action.id == "org.freedesktop.NetworkManager.settings.modify.system") {
            return polkit.Result.YES;
          }
        }
      });
    '';

    users.users.nixos = {
      isNormalUser = true;
      initialPassword = "nixos";
      group = "nixos";
      extraGroups = [
        "wheel"
      ];
    };
    users.groups.nixos = { };

    users.users.frame = {
      isNormalUser = true;
      initialPassword = "kiosk";
      group = "frame";
      extraGroups = [
        "video"
        "render"
        "input"
        "systemd-journal"
      ];
    };
    users.groups.frame = { };

    services.avahi = {
      enable = true;
      hostName = cfg.hostname;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };

    services.cage = {
      enable = true;

      user = "frame";

      program = lib.getExe (
        pkgs.writeShellApplication {
          name = "kiosk-chromium-setup";
          runtimeInputs =
            if cfg.showJournal then
              [
                pkgs.foot
              ]
            else
              [
                pkgs.chromium
                pkgs.wlr-randr
                pkgs.foot
              ]
              ++ lib.optional cfg.onScreenKeyboard pkgs.wvkbd;
          text =
            if cfg.showJournal then
              ''
                foot -e journalctl -f -n 100000 -o short-monotonic
              ''
            else
              ''
                # Apply rotation first so foot (boot-error display) also uses the correct orientation.
                _ROTATION=$(cat /var/lib/nixos-kiosk/screen-rotation 2>/dev/null || echo "${cfg.screenRotation or "none"}")
                if [ "$_ROTATION" = "CW" ]; then
                  _OUTPUT=$(wlr-randr | awk 'NR==1 {print $1; exit}')
                  wlr-randr --output "$_OUTPUT" --transform 270 || true
                elif [ "$_ROTATION" = "CCW" ]; then
                  _OUTPUT=$(wlr-randr | awk 'NR==1 {print $1; exit}')
                  wlr-randr --output "$_OUTPUT" --transform 90 || true
                fi

                # If a critical boot service failed, show its journal instead of
                # starting the kiosk UI so the user can diagnose the problem.
                for _svc in kiosk-firstboot.service kiosk-firstboot-init.service; do
                  if systemctl is-failed --quiet "$_svc" 2>/dev/null; then
                    exec foot sh -c \
                      'echo "=== Boot error: '"$_svc"' failed ==="; echo; journalctl -b --no-pager; echo; printf "Press Enter to exit.\n"; read -r _'
                  fi
                done
                ${lib.optionalString cfg.onScreenKeyboard "wvkbd-mobintl &"}
                chromium \
                  ${lib.optionalString cfg.chromiumKioskEnable "--kiosk "}\
                  ${lib.optionalString cfg.persistBrowserSession "--user-data-dir=/var/lib/nixos-kiosk/chromium "}\
                  --ozone-platform=wayland \
                  --no-first-run \
                  --disable-infobars \
                  --noerrdialogs \
                  --remote-debugging-address=127.0.0.1 \
                  --remote-debugging-port=${toString cfg.chromiumPort} \
                  http://localhost:${toString cfg.setupPort}/manage
              '';
        }
      );
    };

    # cage-tty1 must start after kiosk-firstboot so the script above can
    # reliably inspect its final state via systemctl is-failed.
    systemd.services."cage-tty1" = {
      after = [ "kiosk-firstboot.service" ];
      wants = [ "kiosk-firstboot.service" ];
    };

    boot.extraModprobeConfig = lib.mkIf (cfg.countryCode != null) ''
      options cfg80211 ieee80211_regdom=${cfg.countryCode}
    '';
    hardware.wirelessRegulatoryDatabase = lib.mkIf (cfg.countryCode != null) true;

    services.resolved.enable = false;
    networking.firewall.allowedUDPPorts = [ 53 67 ];
    networking.firewall.allowedTCPPorts = [ 53 80 443 ];
    services.dnsmasq = {
      enable = true;
      # Don't register 127.0.0.1 as a nameserver for the kiosk itself.
      # dnsmasq serves captive-portal DNS only to clients on the AP interface.
      resolveLocalQueries = false;

      settings = {
        log-dhcp = cfg.dnsmasqDebug;
        log-queries = cfg.dnsmasqDebug;
        # Bind only to the AP IP so the kiosk's own DNS queries (on other
        # interfaces) bypass dnsmasq and use the home network's resolvers.
        # bind-dynamic allows startup before the AP interface is configured.
        listen-address = cfg.kioskIP;
        bind-dynamic = true;
        domain-needed = true;
        no-resolv = true;

        # Answer every DNS query with our AP IP
        address = [
          "/#/${cfg.kioskIP}"
        ];

        dhcp-range = [
          cfg.dhcpRange
        ];
      };
    };

    systemd.services.dnsmasq = {
      after = [
        "network.target"
      ];

      wants = [
        "network.target"
      ];

      wantedBy = [
        "multi-user.target"
      ];
    };

    # Self-signed cert for the HTTPS catch-all: iOS 14+ probes
    # https://captive.apple.com/... to detect captive portals. Without
    # anything on port 443 iOS gets "connection refused" which it treats as
    # "broken network" and disconnects immediately. With a self-signed cert it
    # gets a TLS error, which iOS correctly reads as "intercepting captive
    # portal" and keeps the connection alive.
    systemd.services.kiosk-gen-tls-cert = {
      description = "Generate self-signed TLS cert for kiosk captive portal";
      wantedBy = [ "nginx.service" ];
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "kiosk-controller";
        Group = "kiosk-controller";
      };
      script = ''
        if [ ! -f /var/lib/nixos-kiosk/captive-portal.crt ]; then
          ${pkgs.openssl}/bin/openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout /var/lib/nixos-kiosk/captive-portal.key \
            -out    /var/lib/nixos-kiosk/captive-portal.crt \
            -days 3650 -subj "/CN=kiosk-captive-portal"
          chmod 640 /var/lib/nixos-kiosk/captive-portal.key
        fi
      '';
    };

    services.nginx = {
      enable = true;

      # HTTP catch-all: handles every domain dnsmasq points at the kiosk IP.
      #
      # Captive-portal probe paths (/hotspot-detect.html, /generate_204) return
      # the OS-specific "connected" response so the device stays associated with
      # the AP.  Returning a redirect here instead would cause iOS to disconnect
      # after ~3 s once it decides the portal never completed.
      #
      # All other requests are proxied directly to the kiosk setup backend
      # instead of redirecting to hostname.local — the .local redirect required
      # mDNS resolution which could add up to 20 s on iOS before the page appeared.
      virtualHosts."_" = {
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
            extraParameters = [
              "default_server"
              # Seemingly the default value of net.core.somaxconn
              "backlog=4096"
              "deferred"
            ];
          }
        ];

        # Apple captive-portal probe (iOS / macOS).
        # Returning a redirect (not Success) triggers the CNA popup automatically.
        # We redirect to the IP directly to avoid mDNS (.local) delays on iOS.
        locations."/hotspot-detect.html" = {
          extraConfig = ''
            return 302 http://${cfg.kioskIP}/manage;
          '';
        };

        # Android captive-portal probe.
        locations."/generate_204" = {
          extraConfig = "return 204;";
        };

        # Windows NCSI probes. Without these Windows marks the connection as
        # "No Internet Access" and may disconnect from the AP.
        locations."/ncsi.txt" = {
          extraConfig = ''
            default_type text/plain;
            return 200 "Microsoft NCSI";
          '';
        };
        locations."/connecttest.txt" = {
          extraConfig = ''
            default_type text/plain;
            return 200 "Microsoft Connect Test";
          '';
        };

        # Firefox captive-portal probe.
        locations."/success.txt" = {
          extraConfig = ''
            default_type text/plain;
            return 200 "success";
          '';
        };

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.setupPort}";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
          '';
        };
      };

      # Catch-all HTTPS vhost: iOS 14+ probes https://captive.apple.com/… to
      # detect captive portals.  Without anything on port 443 iOS gets
      # "connection refused" which it treats as "broken network" and disconnects
      # immediately.  With a self-signed cert it gets a TLS error, which iOS
      # correctly reads as "intercepting captive portal" and keeps the AP
      # association alive.
      virtualHosts."_https" = {
        listen = [
          {
            addr = "0.0.0.0";
            port = 443;
            ssl = true;
            extraParameters = [ "default_server" ];
          }
        ];

        onlySSL = true;
        sslCertificate = "/var/lib/nixos-kiosk/captive-portal.crt";
        sslCertificateKey = "/var/lib/nixos-kiosk/captive-portal.key";

        locations."/" = {
          extraConfig = ''
            return 302 http://${cfg.kioskIP}/manage;
          '';
        };
      };

      virtualHosts."${cfg.hostname}.local" = {
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.setupPort}";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
          '';
        };
      };
    };

    systemd.services.nginx = {
      after = [
        "network.target"
      ];

      wants = [
        "network.target"
      ];

      wantedBy = [
        "multi-user.target"
      ];
    };
    }
  ]);
}
