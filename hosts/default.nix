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
    nixos-builder = import ./builder/conf.nix;
    nixos-jenkins-controller = import ./jenkins-controller/conf.nix;
  };

  flake.nixosConfigurations = {
    vm-builder-x86 = inputs.nixpkgs.lib.nixosSystem {
      inherit specialArgs;
      modules = [
        (import ./vm-nixos-qemu.nix {
          disk_gb = 200;
          vcpus = 20;
          ram_gb = 40;
        })
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
    vm-builder-aarch = inputs.nixpkgs.lib.nixosSystem {
      inherit specialArgs;
      modules = [
        (import ./vm-nixos-qemu.nix {
          disk_gb = 200;
          vcpus = 20;
          ram_gb = 40;
        })
        self.nixosModules.nixos-builder
        {
          nixpkgs.hostPlatform = "aarch64-linux";
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
          disk_gb = 200;
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
