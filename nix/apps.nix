{
  inputs,
  self,
  ...
}:
let
  pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
  decrypt-sops-key = pkgs.writeShellScript "decrypt-sops-key" ''
    set -eu
    on_err () {
      echo "[+] Failed decrypting sops key: VM will boot-up without secrets"
      # Wait for user input if stdout is to a terminal (and not to file or pipe)
      if [ -t 1 ]; then
        echo; read -n 1 -srp "Press any key to continue"; echo
      fi
      exit 1
    }
    trap on_err ERR
    if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
      on_err
    fi
    secret="$1"
    todir="$2"
    mkdir -p "$todir"
    rm -fr "$todir/ssh_host_ed25519_key"
    tofile="$todir/ssh_host_ed25519_key"
    umask 377
    ${pkgs.lib.getExe pkgs.sops} --extract '["ssh_host_ed25519_key"]' --decrypt "$secret" >"$tofile"
    echo "[+] Decrypted sops key '$tofile'"
  '';
in
{
  flake.apps."x86_64-linux" = {
    run-vm-builder = {
      type = "app";
      program = self.nixosConfigurations.vm-builder.config.system.build.vm;
    };
    run-vm-jenkins-controller = {
      type = "app";
      program = pkgs.writeShellScriptBin "jenkins-nixosvm-with-secrets" ''
        echo "[+] Running $(realpath "$0")"
        secret="${self.outPath}/hosts/jenkins-controller/secrets.yaml"
        todir="${self.nixosConfigurations.vm-jenkins-controller.config.virtualisation.vmVariant.virtualisation.sharedDirectories.shr.source}"
        ${decrypt-sops-key} "$secret" "$todir"
        ${pkgs.lib.getExe self.nixosConfigurations.vm-jenkins-controller.config.system.build.vm}
        rm -fr "$todir/ssh_host_ed25519_key"
      '';
    };
  };
}
