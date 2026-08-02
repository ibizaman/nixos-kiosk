{
  buildGoModule,
}:
buildGoModule {
  pname = "nixos-kiosk";
  version = builtins.readFile ../VERSION;

  src = ../app;

  vendorHash = "sha256-2B7rPIwHb8/XgmEGXAiFSeqPRE3JY37Wn2WoTAT/I2c=";
}
