{
  inputs,
  self,
  ...
}:
let
  decrypt-sops-key =
    pkgs:
    (pkgs.writeShellScript "decrypt-sops-key" ''
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
      umask 077; mkdir -p "$todir"
      rm -fr "$todir/ssh_host_ed25519_key"
      tofile="$todir/ssh_host_ed25519_key"
      umask 377
      ${pkgs.lib.getExe pkgs.sops} --extract '["ssh_host_ed25519_key"]' --decrypt "$secret" >"$tofile"
      echo "[+] Decrypted sops key '$tofile'"
    '');

  run-vm-with-share =
    pkgs: cfg:
    (pkgs.writeShellScriptBin "run-vm-with-share" ''
      set -eu
      echo "[+] Running '$(realpath "$0")'"
      # Host path of the shr share directory
      sharedir="${cfg.virtualisation.vmVariant.virtualisation.sharedDirectories.shr.source}"
      # See nixpkgs: virtualisation/qemu-vm.nix
      export TMPDIR="$sharedir"
      on_exit () {
        echo "[+] Removing '$sharedir'"
        rm -fr "$sharedir"
      }
      trap on_exit EXIT

      # Decrypt vm secret(s)
      secret="${self.outPath}/hosts/${cfg.system.name}/secrets.yaml"
      todir="$sharedir/secrets"
      ${decrypt-sops-key pkgs} "$secret" "$todir"

      # Copy the flake source tree to the share
      umask 077; cp -a -R --no-preserve=mode,ownership "${self.outPath}" "$sharedir/source"

      # Run vm with the share mounted inside the virtual machine
      ${pkgs.lib.getExe cfg.system.build.vm}
    '');

  run-vm =
    pkgs: cfg:
    (pkgs.writeShellScriptBin "run-vm" ''
      set -eu
      echo "[+] Running '$(realpath "$0")'"
      if [ -z "$TMPDIR" ]; then
        export TMPDIR="$(mktemp --directory --suffix .nix-vm-tmpdir)"
      fi
      on_exit () {
        echo "[+] Removing '$TMPDIR'"
        rm -fr "$TMPDIR"
      }
      trap on_exit EXIT

      ${pkgs.lib.getExe cfg.system.build.vm}
    '');
in
{
  flake.apps."x86_64-linux" =
    let
      pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
    in
    {
      run-vm-builder = {
        type = "app";
        program = run-vm pkgs self.nixosConfigurations.vm-builder-x86.config;
      };
      run-vm-jenkins-controller = {
        type = "app";
        program = run-vm-with-share pkgs self.nixosConfigurations.vm-jenkins-controller.config;
      };
    };
  flake.apps."aarch64-linux" =
    let
      pkgs = import inputs.nixpkgs { system = "aarch64-linux"; };
    in
    {
      run-vm-builder = {
        type = "app";
        program = run-vm pkgs self.nixosConfigurations.vm-builder-aarch.config;
      };
    };
}
