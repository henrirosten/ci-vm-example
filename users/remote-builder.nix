{
  users.users = {
    remote-builder = {
      isNormalUser = true;
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMVsUoqwCioTTeqq7rgKyk6kZ5voqhufyW8ja5nTMa73 remote-builder"
      ];
      extraGroups = [ ];
    };
  };
  nix.settings.trusted-users = [ "remote-builder" ];
}
