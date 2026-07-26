{
  buildGoModule,
}:
buildGoModule {
  pname = "nixos-kiosk";
  version = builtins.readFile ../VERSION;

  src = ../app;

  vendorHash = "sha256-0r5SUiToz09etDJg/qzoRxIoT1FTHeNlZrSoPVNXy0M=";
}
