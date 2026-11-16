{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:

let
  cfg = config.kiosk;
in
{
  imports = [
    (modulesPath + "/profiles/image-based-appliance.nix")
  ];

  options.kiosk = {
    sshAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys authorised for the nixos user.
        An additional key can be supplied at first-boot via ssh_authorized_key
        in kiosk.conf without rebuilding the image.
      '';
    };

    screenRotation = lib.mkOption {
      type = lib.types.enum [
        "none"
        "CW"
        "CCW"
      ];
      default = "none";
      description = ''
        Screen rotation for the kiosk display.
        "CW" rotates 90° clockwise, "CCW" rotates 90° counter-clockwise.
        Sets fbcon=rotate:N for the kernel console and rotates the Wayland
        output via wlr-randr.
        Note: GRUB is not rotated; on a kiosk with a short boot timeout this
        is not visible in practice.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.openssh = {
        enable = true;
        settings.PasswordAuthentication = lib.mkDefault false;
        # Keep the NixOS default path so openssh.authorizedKeys.keys still works,
        # and add the runtime file written by firstboot.
        authorizedKeysFiles = [
          "%h/.ssh/authorized_keys"
          "/etc/ssh/authorized_keys.d/%u"
          "/var/lib/nixos-kiosk/nixos-authorized-keys"
        ];
      };

      systemd.tmpfiles.rules = [
        # Empty authorized_keys file for the nixos user; firstboot may append a key.
        "f /var/lib/nixos-kiosk/nixos-authorized-keys 0644 root root -"
        # Hostname state file writable by kiosk-controller so the UI can persist it.
        "f /var/lib/nixos-kiosk/hostname 0640 kiosk-controller kiosk-controller -"
      ];

      users.users.nixos.openssh.authorizedKeys.keys = cfg.sshAuthorizedKeys;

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
        '';
      };
    }
    (lib.mkIf (cfg.screenRotation != "none") {
      boot.kernelParams = [
        "fbcon=rotate:${if cfg.screenRotation == "CW" then "1" else "3"}"
      ];
      # Remap touch coordinates to match the rotated display.
      # CW  (90° clockwise):         (x,y) → (y, 1-x) → matrix "0 1 0 -1 0 1"
      # CCW (90° counter-clockwise): (x,y) → (1-y, x) → matrix "0 -1 1 1 0 0"
      services.udev.extraRules = ''
        ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="${
          if cfg.screenRotation == "CW" then "0 1 0 -1 0 1" else "0 -1 1 1 0 0"
        }"
      '';
    })
  ]);
}
