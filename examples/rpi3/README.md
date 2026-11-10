# NixOS Kiosk for Raspberry Pi 3

1. Build image

   ```bash
   nix build .#nixosConfigurations.nixos-kiosk-rpi3-image.config.system.build.sdImage
   ```

2. Burn on sdcard:

   ```bash
   nix run nixpkgs#usbimager
   ```

3. Boot RPI
