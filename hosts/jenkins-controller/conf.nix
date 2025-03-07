{
  pkgs,
  self,
  inputs,
  lib,
  ...
}:
let
  jenkins-casc = ./jenkins-casc.yaml;
  run-builder-vm = pkgs.writeShellScript "run-builder-vm" ''
    set -eu
    remote="$1"
    nix_target="$2"
    local_port="$3"
    TMPWORKDIR="$(mktemp --dry-run --directory --suffix .nix-vm-builder)"
    echo "Using TMPWORKDIR '$TMPWORKDIR' on remote '$remote'"
    on_term () {
      set -x
      echo "Removing '$TMPWORKDIR' on '$remote'"
      ${pkgs.openssh}/bin/ssh "$remote" "rm -fr $TMPWORKDIR || echo Failed"
    }
    trap on_term TERM

    # Copy the flake source from /shared/source over to remote at TMPWORKDIR
    # so we can nix run the nix_target on remote
    ${pkgs.openssh}/bin/scp -r /shared/source "$remote":"$TMPWORKDIR"

    # Run the builder vm on the remote over ssh, forwarding the
    # 'localhost:local_port' over to remote port '2322'. After builder vm
    # boots-up, its ssh service is available on remote:2322 so this allows
    # reaching the remote builder over ssh at localhost:local_port.
    # The '-tt' option causes the remote process (nix run ...) to terminate
    # when the below ssh process is terminated.
    echo "Starting builder vm '$nix_target' - ssh at local port '$local_port'"
    ${pkgs.openssh}/bin/ssh -L "$local_port":localhost:2322 "$remote" -tt \
    "\
      export TMPDIR="$TMPWORKDIR"
      cd "$TMPWORKDIR";\
      nix run --refresh .#"$nix_target";\
    ";
  '';
in
{
  sops.defaultSopsFile = ./secrets.yaml;
  sops.secrets.id_builder.owner = "root";
  sops.secrets.remote_build_ssh_key.owner = "root";
  imports =
    [
      inputs.sops-nix.nixosModules.sops
    ]
    ++ (with self.nixosModules; [
      hosts-common
      user-hrosten
    ]);

  virtualisation.vmVariant.virtualisation.sharedDirectories.shr = {
    source = "$HOME/.config/vmshared/jenkins-controller";
    target = "/shared";
  };
  virtualisation.vmVariant.services.openssh.hostKeys = [
    {
      path = "/shared/secrets/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];

  networking = {
    hostName = "jenkins-controller";
    firewall.allowedTCPPorts = [
      8081
    ];
  };
  services.jenkins = {
    enable = true;
    listenAddress = "0.0.0.0";
    port = 8081;
    withCLI = true;
    packages = with pkgs; [
      bashInteractive # 'sh' step in jenkins pipeline requires this
      coreutils
      nix
      git
      zstd
      jq
      csvkit
      curl
      nix-eval-jobs
    ];
    extraJavaOptions = [
      # Useful when the 'sh' step fails:
      "-Dorg.jenkinsci.plugins.durabletask.BourneShellScript.LAUNCH_DIAGNOSTICS=true"
      # Point to configuration-as-code config
      "-Dcasc.jenkins.config=${jenkins-casc}"
    ];

    plugins = import ./plugins.nix { inherit (pkgs) stdenv fetchurl; };

    # Configure jenkins job(s):
    # https://jenkins-job-builder.readthedocs.io/en/latest/project_pipeline.html
    # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/continuous-integration/jenkins/job-builder.nix
    jobBuilder = {
      enable = true;
      nixJobs =
        lib.mapAttrsToList
          (display-name: script: {
            job = {
              inherit display-name;
              name = script;
              project-type = "pipeline";
              concurrent = true;
              pipeline-scm = {
                script-path = "${script}.groovy";
                lightweight-checkout = true;
                scm = [
                  {
                    git = {
                      url = "https://github.com/tiiuae/ghaf-jenkins-pipeline.git";
                      clean = true;
                      branches = [ "*/main" ];
                    };
                  }
                ];
              };
            };
          })
          {
            "Ghaf main pipeline" = "ghaf-main-pipeline";
            "Ghaf nightly pipeline" = "ghaf-nightly-pipeline";
            "Ghaf release pipeline" = "ghaf-release-pipeline";
          };
    };
  };
  systemd.services.jenkins.serviceConfig = {
    Restart = "on-failure";
  };

  systemd.services.jenkins-job-builder.serviceConfig = {
    Restart = "on-failure";
    RestartSec = 5;
  };

  # set StateDirectory=jenkins, so state volume has the right permissions
  # and we wait on the mountpoint to appear.
  # https://github.com/NixOS/nixpkgs/pull/272679
  systemd.services.jenkins.serviceConfig.StateDirectory = "jenkins";

  # Install jenkins plugins, apply initial jenkins config
  systemd.services.jenkins-config = {
    after = [ "jenkins-job-builder.service" ];
    wantedBy = [ "multi-user.target" ];
    # Make `jenkins-cli` available
    path = with pkgs; [ jenkins ];
    # Implicit URL parameter for `jenkins-cli`
    environment = {
      JENKINS_URL = "http://localhost:8081";
    };
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = 5;
      RequiresMountsFor = "/var/lib/jenkins";
    };
    script =
      let
        jenkins-auth = "-auth admin:\"$(cat /var/lib/jenkins/secrets/initialAdminPassword)\"";

        # disable initial setup, which needs to happen *after* all jenkins-cli setup.
        # otherwise we won't have initialAdminPassword.
        # Disabling the setup wizard cannot happen from configuration-as-code either.
        jenkins-groovy = pkgs.writeText "groovy" ''
          #!groovy

          import jenkins.model.*
          import hudson.util.*;
          import jenkins.install.*;

          def instance = Jenkins.getInstance()

          instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
          instance.save()
        '';
      in
      ''
        # Disable initial install
        jenkins-cli ${jenkins-auth} groovy = < ${jenkins-groovy}

        # Restart jenkins
        jenkins-cli ${jenkins-auth} safe-restart
      '';
  };

  systemd.services.populate-builder-machines = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
    };
    script = ''
      # If this is not the first time this instance of jenkins-controller
      # boots-up, the ephemeral builders' public keys from the pervious power
      # cycle might still be around in /root/.ssh/known_hosts. Since we
      # spin-up new ephemeral builders every time jenkins-controller
      # boots-up, we also need to clean the /root/.ssh/known_hosts
      rm -fr /root/.ssh/known_hosts

      mkdir -p /etc/nix
      echo "ssh://ephemeral-build4 x86_64-linux - 20 10 kvm,nixos-test,benchmark,big-parallel" >/etc/nix/machines
      echo "ssh://ephemeral-hetzarm aarch64-linux - 20 10 kvm,nixos-test,benchmark,big-parallel" >>/etc/nix/machines
    '';
  };

  systemd.services.builder-vm-x86-start = {
    after = [ "network-online.target" ];
    before = [ "nix-daemon.service" ];
    requires = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      RemainAfterExit = true;
      Restart = "no";
    };
    script = ''
      remote="build4.vedenemo.dev"
      nix_target="apps.x86_64-linux.run-vm-builder"
      local_port="3022"
      ${run-builder-vm} "$remote" "$nix_target" "$local_port"
    '';
  };

  systemd.services.builder-vm-aarch-start = {
    after = [ "network-online.target" ];
    before = [ "nix-daemon.service" ];
    requires = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      RemainAfterExit = true;
      Restart = "no";
    };
    script = ''
      remote="hetzarm.vedenemo.dev"
      nix_target="apps.aarch64-linux.run-vm-builder"
      local_port="4022"
      ${run-builder-vm} "$remote" "$nix_target" "$local_port"
    '';
  };

  # Enable early out-of-memory killing.
  # Make nix builds more likely to be killed over more important services.
  services.earlyoom = {
    enable = true;
    # earlyoom sends SIGTERM once below 5% and SIGKILL when below half
    # of freeMemThreshold
    freeMemThreshold = 5;
    extraArgs = [
      "--prefer"
      "^(nix-daemon)$"
      "--avoid"
      "^(java|jenkins-.*|sshd|systemd|systemd-.*)$"
    ];
  };
  # Tell the Nix evaluator to garbage collect more aggressively
  environment.variables.GC_INITIAL_HEAP_SIZE = "1M";
  # Always overcommit: pretend there is always enough memory
  # until it actually runs out
  boot.kernel.sysctl."vm.overcommit_memory" = "1";

  nix.extraOptions = ''
    trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
    substituters = https://cache.nixos.org
    connect-timeout = 5
    system-features = nixos-test benchmark big-parallel kvm
    builders-use-substitutes = false
    builders = @/etc/nix/machines
    max-jobs = 0
  '';
  programs.ssh = {

    # Known builder host public keys, these go to /root/.ssh/known_hosts
    knownHosts."build4.vedenemo.dev".publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMrLRVAi7dDXUF1EFTd7oHLyolxFSkE6MROXvIM+UqDo";
    knownHosts."builder.vedenemo.dev".publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHSI8s/wefXiD2h3I3mIRdK+d9yDGMn0qS5fpKDnSGqj";
    knownHosts."hetzarm.vedenemo.dev".publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILx4zU4gIkTY/1oKEOkf9gTJChdx/jR3lDgZ7p/c7LEK";

    # Custom options to /etc/ssh/ssh_config
    extraConfig = lib.mkAfter ''
      # VM we spin-up on build4.vedenemo.dev with builder-vm-x86-start service
      Host ephemeral-build4
      Hostname localhost
      Port 3022
      User remote-builder
      IdentityFile /run/secrets/id_builder
      # We check the build4.vedenemo.dev key already
      StrictHostKeyChecking no

      # VM we spin-up on hetzarm.vedenemo.dev with builder-vm-aarch-start service
      Host ephemeral-hetzarm
      Hostname localhost
      Port 4022
      User remote-builder
      IdentityFile /run/secrets/id_builder
      # We check the hetzarm.vedenemo.dev key already
      StrictHostKeyChecking no

      Host builder.vedenemo.dev
      Hostname builder.vedenemo.dev
      User remote-build
      IdentityFile /run/secrets/remote_build_ssh_key

      Host build4.vedenemo.dev
      Hostname build4.vedenemo.dev
      User remote-build
      IdentityFile /run/secrets/remote_build_ssh_key

      Host hetzarm.vedenemo.dev
      Hostname hetzarm.vedenemo.dev
      User remote-build
      IdentityFile /run/secrets/remote_build_ssh_key
    '';
  };
}
