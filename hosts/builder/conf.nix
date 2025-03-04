{
  self,
  lib,
  ...
}:
{
  imports = with self.nixosModules; [
    hosts-common
    user-hrosten
    user-remote-builder
  ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  networking = {
    hostName = "builder";
  };
}
