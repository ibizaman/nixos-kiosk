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

    chromiumPort = lib.mkOption {
      type = lib.types.port;
      default = 9222;
    };
  };
  config = lib.mkIf cfg.enable {
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
        ExecStart = "${cfg.package}/bin/nixos-kiosk serve";
        DynamicUser = true;
        Restart = "always";
      };
    };

    systemd.targets.kiosk-normal = {
      description = "Normal kiosk mode";

      wantedBy = [
        "multi-user.target"
      ];
    };

    systemd.targets.kiosk-setup = {
      description = "WiFi setup kiosk mode";
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        AllowIsolate = true;
      };

      wants = [
        "dnsmasq.service"
        "nginx.service"
        "kiosk-chromium.service"
      ];

      after = [
        "network.target"
      ];
    };

    users.users.frame = {
      isNormalUser = true;
      group = "frame";
      extraGroups = [
        "video"
        "render"
        "input"
      ];
    };
    users.group.frame = { };

    systemd.services.kiosk-chromium = {
      description = "Chromium WiFi setup kiosk";

      wantedBy = [
        "kiosk-setup.target"
      ];

      partOf = [
        "kiosk-setup.target"
      ];

      after = [
        "systemd-user-sessions.service"
      ];

      serviceConfig = {
        User = "frame";

        Environment = [
          "DISPLAY=:0"
        ];

        ExecStart = ''
          ${pkgs.cage}/bin/cage \
            ${pkgs.chromium}/bin/chromium \
              --kiosk \
              --no-first-run \
              --disable-infobars \
              --noerrdialogs \
              --remote-debugging-address=127.0.0.1 \
              --remote-debugging-port=${toString cfg.chromiumPort} \
              http://setup.local/connect
        '';

        Restart = "always";
      };
    };

    services.dnsmasq = {
      enable = true;

      settings = {
        # interface = "wlan0";
        bind-interfaces = true;

        # Never forward DNS
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
      partOf = [
        "kiosk-setup.target"
      ];

      wantedBy = [
        "kiosk-setup.target"
      ];
    };

    services.nginx = {
      enable = true;

      virtualHosts."setup.local" = {
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];

        locations."/" = {
          proxyPass = "http://127.0.0.1:8000";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
          '';
        };
      };
    };

    systemd.services.nginx = {
      partOf = [
        "kiosk-setup.target"
      ];

      wantedBy = [
        "kiosk-setup.target"
      ];
    };
  };
}
