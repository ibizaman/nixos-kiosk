{
  description = "NixOS Kiosk";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
  };

  nixConfig = {
    extra-substituters = [
      "https://ibizaman.cachix.org"
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "ibizaman.cachix.org-1:Y8cRpAoeMfeeUp1jRG5KuwoVteZOQLG4HYkYyT4TC8k="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      nixos-raspberrypi,
    }:
    flake-parts.lib.mkFlake
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
            self',
            inputs',
            pkgs,
            system,
            ...
          }:
          {
            formatter = pkgs.nixfmt-tree;

            packages.nixos-kiosk = pkgs.callPackage ./nix/package.nix { };

            checks = {
              app-networkmanager = pkgs.callPackage ./app/tests/networkmanager.nix {
                inherit (self'.packages) nixos-kiosk;
              };
              app-chromium = pkgs.callPackage ./app/tests/chromium.nix {
                inherit (self'.packages) nixos-kiosk;
              };
            };
          };

        flake = {
          # nixos-raspberrypi.inputs.nixos-images.nixosModules.sdimage-installer
          nixosModules = {
            rpi2-hw = {
              imports = with nixos-raspberrypi.nixosModules; [
                raspberry-pi-02.base
                raspberry-pi-02.display-vc4
                raspberry-pi-02.bluetooth
              ];
            };
            rpi3-hw = {
              imports = with nixos-raspberrypi.nixosModules; [
                raspberry-pi-3.base
                # raspberry-pi-3.display-vc4
                # raspberry-pi-3.bluetooth
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

            nixos-kiosk = {
              imports = [
                ./nix/wifi-setup.nix
              ];

              kiosk.enable = true;
            };

            magic-frame = {
              networking.hostName = "magic-frame";
            };
          };

          nixosConfigurations = {
            nixos-kiosk = nixpkgs.lib.nixosSystem {
              modules = [
                {
                  nixpkgs.hostPlatform = "x86_64-linux";
                }
                self.nixosModules.nixos-kiosk
                self.nixosModules.magic-frame
              ];
            };

            nixos-kiosk-rpi2 = nixos-raspberrypi.lib.nixosSystem {
              specialArgs = inputs;
              modules = [
                {
                  nixpkgs.buildPlatform = "x86_64-linux";
                  nixpkgs.hostPlatform = "armv7l-linux";
                }
                self.nixosModules.rpi-sd-filesystems
                self.nixosModules.rpi2-hw
                self.nixosModules.rpi-hdmi
                self.nixosModules.rpi-common
                self.nixosModules.nixos-kiosk
                self.nixosModules.magic-frame
              ];
            };

            nixos-kiosk-rpi2-image = nixos-raspberrypi.lib.nixosSystem {
              specialArgs = inputs;
              modules = [
                {
                  nixpkgs.buildPlatform = "x86_64-linux";
                  nixpkgs.hostPlatform = "armv7l-linux";
                }
                self.nixosModules.rpi2-hw
                self.nixosModules.rpi-hdmi
                nixos-raspberrypi.nixosModules.sd-image
                self.nixosModules.rpi-common
                self.nixosModules.nixos-kiosk
                self.nixosModules.magic-frame
              ];
            };

            nixos-kiosk-rpi3 = nixos-raspberrypi.lib.nixosSystem {
              specialArgs = inputs;
              modules = [
                {
                  nixpkgs.buildPlatform = "x86_64-linux";
                  nixpkgs.hostPlatform = "aarch64-linux";
                }
                self.nixosModules.rpi-sd-filesystems
                self.nixosModules.rpi3-hw
                self.nixosModules.rpi-hdmi
                self.nixosModules.rpi-common
                self.nixosModules.nixos-kiosk
                self.nixosModules.magic-frame
              ];
            };

            nixos-kiosk-rpi3-image = nixos-raspberrypi.lib.nixosSystem {
              specialArgs = inputs;
              modules = [
                {
                  nixpkgs.buildPlatform = "x86_64-linux";
                  nixpkgs.hostPlatform = "aarch64-linux";
                }
                self.nixosModules.rpi3-hw
                self.nixosModules.rpi-hdmi
                nixos-raspberrypi.nixosModules.sd-image
                self.nixosModules.rpi-common
                self.nixosModules.nixos-kiosk
                self.nixosModules.magic-frame
              ];
            };
          };

          vms.nixos-kiosk = self.nixosConfigurations.nixos-kiosk.config.system.build.vm;
          sdImages.nixos-kiosk-rpi2 =
            self.nixosConfigurations.nixos-kiosk-rpi2-image.config.system.build.sdImage;
          sdImages.nixos-kiosk-rpi3 =
            self.nixosConfigurations.nixos-kiosk-rpi3-image.config.system.build.sdImage;
        };
      };
}
