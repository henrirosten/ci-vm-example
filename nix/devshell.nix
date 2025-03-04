{ inputs, ... }:
{
  imports = [
    inputs.devshell.flakeModule
  ];
  perSystem =
    { pkgs, ... }:
    {
      devshells = {
        default = {
          devshell = {
            packages = with pkgs; [
              git
              nix
              nixos-rebuild
              reuse
              sops
              ssh-to-age
            ];
          };
          commands = [
            {
              help = "Update all sops yaml and json files according to .sops.yaml rules";
              name = "update-sops-files";
              command = "set -x; find . -type f -iname 'secrets.yaml' -exec sops updatekeys --yes {} ';'";
              category = "sops";
            }
          ];
        };
      };
    };
}
