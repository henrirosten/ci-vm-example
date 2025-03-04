{
  flake.nixosModules = {
    user-hrosten = import ./hrosten.nix;
    user-remote-builder = import ./remote-builder.nix;
  };
}
