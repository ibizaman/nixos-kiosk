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
    environment.systemPackages = [
      pkgs.dig
      cfg.package
    ];

    networking.wireless.enable = lib.mkOverride 0 true;
    networking.networkmanager.enable = true;

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
      ];
    };
    users.groups.frame = { };

    services.cage = {
      enable = true;

      user = "frame";

      program = lib.getExe (
        pkgs.writeShellApplication {
          name = "kiosk-chromium-setup";
          runtimeInputs = [
            pkgs.chromium
          ];
          text = ''
            chromium \
              --kiosk \
              --no-first-run \
              --disable-infobars \
              --noerrdialogs \
              --remote-debugging-address=127.0.0.1 \
              --remote-debugging-port=${toString cfg.chromiumPort} \
              http://setup.local/connect
          '';
        }
      );
    };

    services.dnsmasq = {
      enable = true;

      settings = {
        # interface = "wlan0";
        bind-interfaces = true;
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
