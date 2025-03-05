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
}
