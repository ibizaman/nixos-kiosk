{ lib, ... }:
{
  # networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
  #   {
  #     address = "192.168.1.2";
  #     prefixLength = 24;
  #   }
  # ];
  services.vwifi = {
    server = {
      enable = true;
      ports.tcp = 8212;
      # uncomment if you want to enable monitor mode on another node
      # ports.spy = 8213;
      # openFirewall = true;
    };
  };

  networking.wireless.enable = lib.mkOverride 0 true;
  networking.networkmanager.enable = true;
  networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
    {
      address = "192.168.1.3";
      prefixLength = 24;
    }
  ];
  services.vwifi = {
    module = {
      enable = true;
      macPrefix = "74:F8:F6:00:01";
    };
    client = {
      enable = true;
      serverAddress = "192.168.1.2";
    };
  };
}
