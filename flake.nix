{
  description = "NixOS Kiosk";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  nixConfig = {
    extra-substituters = [
      "https://nixos-kiosk.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-kiosk.cachix.org-1:Ra804yD9XwVuzkKY3SnXbPz36sH5hHr27fz1qSBdmZ0="
    ];
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      ...
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
            system,
            ...
          }:
          let
            pkgs = import nixpkgs {
              inherit system;
            };
            lib = pkgs.lib;
          in
          {
            formatter = pkgs.nixfmt-tree;

            packages = {
              nixos-kiosk = pkgs.callPackage ./nix/package.nix { };
            }
            // lib.optionalAttrs (system == "x86_64-linux") {
              screenshots =
                let
                  test = pkgs.callPackage ./nix/screenshot.nix {
                    inherit (self'.packages) nixos-kiosk;
                  };
                in
                pkgs.runCommand "screenshots" { inherit test; } ''
                  mkdir $out
                  cp $test/setup-form.png $out/
                  cp $test/connected.png $out/
                '';
            };

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
          nixosModules = {
            fake-wifi = ./nix/fake-wifi.nix;
            appliance = ./nix/appliance.nix;
            nixos-kiosk = ./nix/wifi-setup.nix;
          };
        };
      };
}
