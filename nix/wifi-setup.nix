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

    setupURL = lib.mkOption {
      type = lib.types.str;
      description = ''
        It's best to avoid .local domain as this is used by mDNS.
      '';
      default = "setup.kiosk";
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
        ExecStart = "${cfg.package}/bin/nixos-kiosk daemon '${cfg.setupSSID}' ${cfg.normalURL} --port ${toString cfg.setupPort} --chromium-port ${toString cfg.chromiumPort} --ip ${cfg.kioskIP}";
        User = "kiosk-controller";
        Restart = "always";
      };
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
              http://${cfg.setupURL}/connect
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
            return 301 http://${cfg.setupURL};
          '';
        };
      };
      virtualHosts."${cfg.setupURL}" = {
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
