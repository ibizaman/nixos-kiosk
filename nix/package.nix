{
  buildGoModule,
}:
buildGoModule {
  pname = "nixos-kiosk";
  version = builtins.readFile ../VERSION;

  src = ../app;

  vendorHash = "sha256-UBESnJa+SbSQ/x7a5VGnIH+jwq0mHI0eusoVf/TviYg=";
}
