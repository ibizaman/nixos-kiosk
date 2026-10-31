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
        Disable kiosk for debugging.
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
      default = "https://kiosk.tiserbox.com/view";
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

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "magic-frame";
      description = ''
        mDNS hostname for the kiosk. The device will be reachable at
        <hostname>.local on the network. Also used as the nginx virtual host.
      '';
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.dig
      cfg.package
    ];

    networking.networkmanager.enable = true;

    # Enables touchscreen
    services.libinput.enable = true;

    systemd.tmpfiles.rules = [
      "d /var/lib/nixos-kiosk 0750 kiosk-controller kiosk-controller -"
    ];

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
        ExecStart = "${cfg.package}/bin/nixos-kiosk daemon '${cfg.setupSSID}' ${cfg.normalURL} --port ${toString cfg.setupPort} --chromium-port ${toString cfg.chromiumPort} --ip ${cfg.kioskIP} --hostname ${cfg.hostname} --settings-path /var/lib/nixos-kiosk/settings.json";
        User = "kiosk-controller";
        Restart = "always";
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
      ]
      ++ (lib.optionals cfg.showJournal [
        # To see all systemd logs
        "wheel"
      ]);
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
              ];
          text =
            if cfg.showJournal then
              ''
                foot -e journalctl -f -n 100000 -o short-monotonic
              ''
            else
              ''
                chromium \
                  ${lib.optionalString cfg.chromiumKioskEnable "--kiosk "}\
                  --no-first-run \
                  --hide-cursor \
                  --disable-infobars \
                  --noerrdialogs \
                  --remote-debugging-address=127.0.0.1 \
                  --remote-debugging-port=${toString cfg.chromiumPort} \
                  http://localhost:${toString cfg.setupPort}/manage
              '';
        }
      );
    };

    services.resolved.enable = false;
    networking.firewall.allowedUDPPorts = [ 53 67 ];
    networking.firewall.allowedTCPPorts = [ 53 80 443 ];
    services.dnsmasq = {
      enable = true;

      settings = {
        log-dhcp = cfg.dnsmasqDebug;
        log-queries = cfg.dnsmasqDebug;
        # interface = "wlan0";
        # bind-interfaces = true;
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

    services.nginx = {
      enable = true;

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

        locations."/" = {
          extraConfig = ''
            return 301 http://${cfg.hostname}.local;
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
  };
}
