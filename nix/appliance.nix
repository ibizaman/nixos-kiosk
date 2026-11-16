{
  config,
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
      ];

      users.users.nixos.openssh.authorizedKeys.keys = cfg.sshAuthorizedKeys;
    }
    (lib.mkIf (cfg.screenRotation != "none") {
      boot.kernelParams = [
        "fbcon=rotate:${if cfg.screenRotation == "CW" then "3" else "1"}"
      ];
    })
  ]);
}
