{
  self,
  ...
}:
{
  imports = with self.nixosModules; [
    hosts-common
    user-hrosten
    user-remote-builder
  ];
  networking = {
    hostName = "builder";
  };
  virtualisation.vmVariant.virtualisation.sharedDirectories.shr = {
    source = "/tmp/shared/builder";
    target = "/shared";
  };
  virtualisation.vmVariant.services.openssh.hostKeys = [
    {
      path = "/shared/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];
}
