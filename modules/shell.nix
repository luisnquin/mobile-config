# black-terminal's components. Its modules come in from flake.nix.
{
  black-terminal,
  config,
  pkgs,
  ...
}: let
  user = config.mobile.session.user;

  # The NixOS half carries no prompt: everything visible is in the home half.
  homeComponents = {
    imports = [black-terminal.homeModules.default];

    home.stateVersion = "26.05";

    shared.starship.enable = true;
    shared.zsh.enable = true;

    shared.bat.enable = true;
    shared.btop.enable = true;
    shared.eza.enable = true;
    shared.fzf.enable = true;
    shared.lazygit.enable = true;
    shared.less.enable = true;
    shared.macchina.enable = true;
    shared.zoxide.enable = true;
  };
in {
  shared.zsh.enable = true;
  shared.eza.enable = true;
  shared.aliases.enable = true;

  shared.git = {
    enable = true;
    user.name = "Luis Quiñones";
    user.email = "lpaandres2020@gmail.com";
  };

  users.defaultUserShell = pkgs.zsh;

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    users.root = homeComponents;

    users.${user} = {
      imports = [homeComponents];

      # Its zsh sets no_global_rcs, which skips /etc/zprofile and with it the
      # dashboard's tty1 autostart.
      programs.zsh.profileExtra = config.environment.loginShellInit;
    };
  };

  # Nothing orders getty after home-manager activation, so the first login of a
  # boot can find an unpopulated ZDOTDIR and zsh-newuser-install would take tty1
  # with a prompt no hardware key can answer.
  systemd.tmpfiles.rules = [
    "f /home/${user}/.zshrc 0644 ${user} users -"
    "f /root/.zshrc 0644 root root -"
  ];
}
