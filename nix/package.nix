{
  buildGoModule,
}:
buildGoModule {
  pname = "nixos-kiosk";
  version = builtins.readFile ../VERSION;

  src = ../app;

  vendorHash = "sha256-9xQYPIP8a4Ky9mSyvK950cSilRH9JkRV/p6a3nqN53Q=";
}
