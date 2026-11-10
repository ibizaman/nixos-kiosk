{
  description = "NixOS Kiosk for RPI 3";

  inputs = {
    nixos-raspberrypi.url = "github:ibizaman/nixos-raspberrypi/develop";
    nixos-kiosk = {
      # You would use this URL
      # url = "github:ibizaman/nixos-kiosk";
      url = "../..";
      inputs.nixpkgs.follows = "nixos-raspberrypi/nixpkgs";
    };
  };

  nixConfig = {
    extra-substituters = [
      "https://nixos-kiosk.cachix.org"
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-kiosk.cachix.org-1:Ra804yD9XwVuzkKY3SnXbPz36sH5hHr27fz1qSBdmZ0="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs =
    inputs@{
      self,
      nixos-kiosk,
      nixos-raspberrypi,
    }:
    nixos-kiosk.inputs.flake-parts.lib.mkFlake
      {
        inherit inputs;
      }
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ];

        perSystem =
          {
            system,
            ...
          }:
          let
            pkgs = import nixos-raspberrypi.inputs.nixpkgs {
              inherit system;
            };
            lib = pkgs.lib;
          in
          {
            formatter = pkgs.nixfmt-tree;

            checks = lib.optionalAttrs pkgs.stdenv.isLinux {};
          };

        flake = {
          nixosModules = {
            rpi3-hw = {
              imports = with nixos-raspberrypi.nixosModules; [
                raspberry-pi-3.base
              ];
            };

            rpi-sd-filesystems = {
              fileSystems = {
                "/boot/firmware" = {
                  device = "/dev/disk/by-label/FIRMWARE";
                  fsType = "vfat";
                  options = [
                    "noatime"
                    "noauto"
                    "x-systemd.automount"
                    "x-systemd.idle-timeout=1min"
                  ];
                };
                "/" = {
                  device = "/dev/disk/by-label/NIXOS_SD";
                  fsType = "ext4";
                  options = [ "noatime" ];
                };
              };
            };

            rpi-hdmi = {
              hardware.raspberry-pi.config.all.options = {
                hdmi_force_hotplug = {
                  enable = true;
                  value = 1;
                };
                hdmi_drive = {
                  enable = true;
                  value = 2;
                };
              };
            };

            rpi-common =
              {
                config,
                ...
              }:
              {
                kiosk.enable = true;
                networking.hostName = "nixos-kiosk";

                system.nixos.tags =
                  let
                    cfg = config.boot.loader.raspberry-pi;
                  in
                  [
                    "raspberry-pi-${cfg.variant}"
                    cfg.bootloader
                    config.boot.kernelPackages.kernel.version
                  ];
              };
          };

          nixosConfigurations = {
            nixos-kiosk-rpi3 = nixos-raspberrypi.lib.nixosSystem {
              specialArgs = inputs;
              modules = [
                {
                  nixpkgs.hostPlatform = "aarch64-linux";
                }
                self.nixosModules.rpi-sd-filesystems
                self.nixosModules.rpi3-hw
                self.nixosModules.rpi-hdmi
                self.nixosModules.rpi-common
                nixos-kiosk.nixosModules.appliance
                nixos-kiosk.nixosModules.nixos-kiosk
              ];
            };

            nixos-kiosk-rpi3-image = nixos-raspberrypi.lib.nixosSystem {
              specialArgs = inputs;
              modules = [
                {
                  nixpkgs.hostPlatform = "aarch64-linux";
                }
                self.nixosModules.rpi3-hw
                self.nixosModules.rpi-hdmi
                nixos-raspberrypi.nixosModules.sd-image
                self.nixosModules.rpi-common
                nixos-kiosk.nixosModules.appliance
                nixos-kiosk.nixosModules.nixos-kiosk
              ];
            };
          };

          nixosConfigurations.default = self.nixosConfigurations.nixos-kiosk-rpi3-image;
        };
      };
}
