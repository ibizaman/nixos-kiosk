{
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/image-based-appliance.nix")
  ];
  config = {
  };
}
