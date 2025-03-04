{
  lib,
  config,
  pkgs,
  ...
}:
{
  nixpkgs.config.allowUnfree = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  time.timeZone = "Europe/Helsinki";
  environment.systemPackages = with pkgs; [
    curl
    dig.dnsutils
    git
    hdparm
    htop
    nixVersions.latest # use the latest version of 'nix'
    speedtest-cli
    tcpdump
    vim
    wget
  ];
  users.mutableUsers = false;
  users.users.root = {
    password = "toor";
    shell = pkgs.bash;
  };
  services.getty.autologinUser = "root";
  security.pam.loginLimits = [
    {
      domain = "*";
      item = "nofile";
      type = "-";
      value = "32768";
    }
    {
      domain = "*";
      item = "memlock";
      type = "-";
      value = "32768";
    }
  ];
  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = false;
  nix = {
    channel.enable = false;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      connect-timeout = 5;
      log-lines = lib.mkDefault 25;
      trusted-users = [ "@wheel" ];
    };
  };
  networking = {
    enableIPv6 = false;
    firewall.enable = true;
    firewall.allowedTCPPorts = [ 22 ];
  };
  services.openssh = {
    enable = true;
    settings.MaxStartups = 100;
  };
}
