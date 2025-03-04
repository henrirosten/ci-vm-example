{
  pkgs,
  self,
  inputs,
  lib,
  ...
}:
let
  jenkins-casc = ./jenkins-casc.yaml;
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
    source = "/tmp/shared/jenkins-controller";
    target = "/shared";
  };
  virtualisation.vmVariant.sops.age.sshKeyPaths = [ "/shared/ssh_host_ed25519_key" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
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
      mkdir -p /etc/nix
      # Retrieved with 'base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub'
      build4_pubkey='c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSU1yTFJWQWk3ZERYVUYxRUZUZDdvSEx5b2x4RlNrRTZNUk9YdklNK1VxRG8gcm9vdEBidWlsZDQK'
      hetzarm_pubkey='c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUx4NHpVNGdJa1RZLzFvS0VPa2Y5Z1RKQ2hkeC9qUjNsRGdaN3AvYzdMRUsgcm9vdEBVYnVudHUtMjIwNC1qYW1teS1hcm02NC1iYXNlCg=='
      common_elems='/run/secrets/remote_build_ssh_key 8 10 kvm,nixos-test,benchmark,big-parallel -'
      echo "ssh://remote-build@build4.vedenemo.dev x86_64-linux $common_elems $build4_pubkey" >/etc/nix/machines
      echo "ssh://remote-build@hetzarm.vedenemo.dev aarch64-linux $common_elems $hetzarm_pubkey" >>/etc/nix/machines
    '';
  };

  # fail2ban on the builder(s) dislike ssh-keyscan if repeated too quickly
  # which is why we manually hardcode the base64 encoded public key in the
  # 'populate-builder-machines' service, instead of using the below service:
  #systemd.services.populate-known-hosts = {
  #  after = [
  #    "network-online.target"
  #    "populate-builder-machines.service"
  #  ];
  #  before = [ "nix-daemon.service" ];
  #  requires = [
  #    "network-online.target"
  #    "populate-builder-machines.service"
  #  ];
  #  wantedBy = [ "multi-user.target" ];
  #  serviceConfig = {
  #    Type = "oneshot";
  #    RemainAfterExit = true;
  #    Restart = "on-failure";
  #  };
  #  script = ''
  #    umask 077
  #    mkdir -p /root/.ssh
  #    cat /etc/nix/machines | cut -d" " -f1 | cut -d" " -f1 | cut -d "@" -f2 | xargs ${pkgs.openssh}/bin/ssh-keyscan -v -t ed25519 > /root/.ssh/known_hosts
  #  '';
  #};

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
    trusted-public-keys = prod-cache.vedenemo.dev~1:JcytRNMJJdYJVQCYwLNsrfVhct5dhCK2D3fa6O1WHOI= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
    substituters = https://prod-cache.vedenemo.dev https://cache.nixos.org
    connect-timeout = 5
    system-features = nixos-test benchmark big-parallel kvm
    builders-use-substitutes = true
    builders = @/etc/nix/machines
    max-jobs = 1
  '';
}
