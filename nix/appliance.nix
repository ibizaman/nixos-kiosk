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
    screenRotation = lib.mkOption {
      type = lib.types.enum [
        "none"
        "left"
        "right"
      ];
      default = "none";
      description = ''
        Screen rotation for the kiosk display.
        "left" rotates 90° counter-clockwise, "right" rotates 90° clockwise.
        Sets fbcon=rotate:N for the kernel console and rotates the Wayland
        output via wlr-randr.
        Note: GRUB is not rotated; on a kiosk with a short boot timeout this
        is not visible in practice.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf (cfg.screenRotation != "none") {
      boot.kernelParams = [
        "fbcon=rotate:${if cfg.screenRotation == "right" then "3" else "1"}"
      ];
    })
  ]);
}
