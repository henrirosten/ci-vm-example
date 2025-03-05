{
  inputs,
  self,
  ...
}:
let
  specialArgs = {
    inherit inputs self;
  };
in
{
  flake.nixosModules = {
    hosts-common = import ./hosts-common.nix;
    nixos-builder = ./builder/conf.nix;
    nixos-jenkins-controller = ./jenkins-controller/conf.nix;
  };
  flake.nixosConfigurations = {

    vm-builder = inputs.nixpkgs.lib.nixosSystem {
      inherit specialArgs;
      modules = [
        (import ./vm-nixos-qemu.nix { })
        self.nixosModules.nixos-builder
        {
          nixpkgs.hostPlatform = "x86_64-linux";
          # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/virtualisation/qemu-vm.nix
          virtualisation.vmVariant.virtualisation.forwardPorts = [
            {
              from = "host";
              host.port = 2322;
              guest.port = 22;
            }
          ];
        }
      ];
    };

    vm-jenkins-controller = inputs.nixpkgs.lib.nixosSystem {
      inherit specialArgs;
      modules = [
        (import ./vm-nixos-qemu.nix {
          disk_gb = 150;
        })
        self.nixosModules.nixos-jenkins-controller
        {
          nixpkgs.hostPlatform = "x86_64-linux";
          # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/virtualisation/qemu-vm.nix
          virtualisation.vmVariant.virtualisation.forwardPorts = [
            {
              from = "host";
              host.port = 8081;
              guest.port = 8081;
            }
            {
              from = "host";
              host.port = 2222;
              guest.port = 22;
            }
          ];
        }
      ];
    };
  };
}
