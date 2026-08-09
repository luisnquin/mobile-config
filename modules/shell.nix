# black-terminal's components. Its module comes in from flake.nix.
{
  config,
  pkgs,
  ...
}: {
  shared.zsh.enable = true;
  shared.eza.enable = true;
  shared.aliases.enable = true;

  shared.git = {
    enable = true;
    user.name = "Luis Quiñones";
    user.email = "lpaandres2020@gmail.com";
  };

  users.defaultUserShell = pkgs.zsh;

  # Without these zsh-newuser-install blocks tty1 before /etc/zprofile.
  systemd.tmpfiles.rules = [
    "f /home/${config.mobile.session.user}/.zshrc 0644 ${config.mobile.session.user} users -"
    "f /root/.zshrc 0644 root root -"
  ];
}
