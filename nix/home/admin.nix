{
  pkgs,
  role,
  ...
}: {
  home = {
    username = "admin";
    homeDirectory = "/var/home/admin";
    stateVersion = "25.11";
    packages = with pkgs; [
      bat
      fd
      fzf
      jq
      ripgrep
      tmux
    ];
    sessionVariables.LUCIDITY_ROLE = role;
  };

  programs = {
    bash = {
      enable = true;
      enableCompletion = true;
      shellAliases = {
        ll = "ls -alF";
        mesh-status = "systemctl status nebula.service";
      };
    };
    git.enable = true;
    home-manager.enable = true;
  };
}
