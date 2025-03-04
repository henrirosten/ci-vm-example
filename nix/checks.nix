{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        reuse = pkgs.runCommandLocal "reuse-lint" { buildInputs = [ pkgs.reuse ]; } ''
          cd ${self.outPath}
          reuse lint
          touch $out
        '';
      };
    };
}
