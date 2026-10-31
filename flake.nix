{
  description = "NixOS Kiosk";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixos-raspberrypi.url = "github:ibizaman/nixos-raspberrypi/develop";
  };

  nixConfig = {
    extra-substituters = [
      "https://nixos-kiosk.cachix.org"
      "https://ibizaman.cachix.org"
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "ibizaman.cachix.org-1:Y8cRpAoeMfeeUp1jRG5KuwoVteZOQLG4HYkYyT4TC8k="
      "nixos-kiosk.cachix.org-1:Ra804yD9XwVuzkKY3SnXbPz36sH5hHr27fz1qSBdmZ0="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs =
    inputs@{
      self,
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
          "armv7l-linux"
          "aarch64-darwin"
        ];

        perSystem =
          {
            self',
            inputs',
            system,
            ...
          }:
          let
            pkgs = import nixos-raspberrypi.inputs.nixpkgs {
              inherit system;
            };
            lib = pkgs.lib;

            # For each sdImage whose nixosConfiguration targets this system,
            # expose it as packages.<system>.sdimage-<suffix>.
            # Convention: sdImages.<name> <-> nixosConfigurations.<name>-image.
            sdImagePackages = lib.mapAttrs' (
              name: image:
              lib.nameValuePair
                ("sdimage-" + lib.removePrefix "nixos-kiosk-" name)
                image
            ) (lib.filterAttrs (name: _:
              self.nixosConfigurations."${name}-image".config.nixpkgs.hostPlatform == system
            ) self.sdImages);
          in
          {
            formatter = pkgs.nixfmt-tree;

            packages =
              {
                nixos-kiosk = pkgs.callPackage ./nix/package.nix { };
              }
              // lib.optionalAttrs (system == "x86_64-linux") {
                screenshot-setup-form =
                  let
                    test = pkgs.callPackage ./nix/screenshot.nix {
                      inherit (self'.packages) nixos-kiosk;
                    };
                  in
                  pkgs.runCommand "screenshot-setup-form" { inherit test; } ''
                    mkdir $out
                    cp $test/setup-form.png $out/setup-form.png
                  '';
              }
              // sdImagePackages;

            checks = lib.optionalAttrs pkgs.stdenv.isLinux (
              let
                mkCheck =
                  module:
                  pkgs.callPackage module {
                    inherit (self'.packages) nixos-kiosk;
                  };
              in
              {
                app-networkmanager = mkCheck ./app/tests/networkmanager.nix;
                app-chromium = mkCheck ./app/tests/chromium.nix;
                app-daemon = mkCheck ./app/tests/daemon.nix;
              }
            );
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

            fake-wifi = ./nix/fake-wifi.nix;
            appliance = ./nix/appliance.nix;

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
            nixos-kiosk = nixos-raspberrypi.inputs.nixpkgs.lib.nixosSystem {
              modules = [
                {
                  nixpkgs.hostPlatform = "x86_64-linux";
                }
                self.nixosModules.nixos-kiosk
                self.nixosModules.magic-frame
                self.nixosModules.appliance
                self.nixosModules.fake-wifi
                {
                  kiosk.chromiumKioskEnable = false;
                }
              ];
            };

            nixos-kiosk-rpi2 = nixos-raspberrypi.lib.nixosSystem {
              specialArgs = inputs;
              modules = [
                {
                  nixpkgs.hostPlatform = "armv7l-linux";
                }
                self.nixosModules.rpi-sd-filesystems
                self.nixosModules.rpi2-hw
                self.nixosModules.rpi-hdmi
                self.nixosModules.rpi-common
                self.nixosModules.appliance
                self.nixosModules.nixos-kiosk
                self.nixosModules.magic-frame
              ];
            };

            nixos-kiosk-rpi2-image = nixos-raspberrypi.lib.nixosSystem {
              specialArgs = inputs;
              modules = [
                {
                  nixpkgs.hostPlatform = "armv7l-linux";
                }
                self.nixosModules.rpi2-hw
                self.nixosModules.rpi-hdmi
                nixos-raspberrypi.nixosModules.sd-image
                self.nixosModules.rpi-common
                self.nixosModules.appliance
                self.nixosModules.nixos-kiosk
                self.nixosModules.magic-frame
              ];
            };

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
                self.nixosModules.appliance
                self.nixosModules.nixos-kiosk
                self.nixosModules.magic-frame
              ];
            };

            nixos-kiosk-rpi3-image = nixos-raspberrypi.lib.nixosSystem {
              specialArgs = inputs;
              modules = [
                {
                  nixpkgs.hostPlatform = "aarch64-linux";
                  kiosk.showJournal = true;
                  kiosk.fixedInsecureKioskPassword = "12345678";
                }
                self.nixosModules.rpi3-hw
                self.nixosModules.rpi-hdmi
                nixos-raspberrypi.nixosModules.sd-image
                self.nixosModules.rpi-common
                self.nixosModules.appliance
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
