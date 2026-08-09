# The interactive shell, from the black-terminal flake. Its NixOS module is
# imported for every device in flake.nix; this file is what turns the four
# components on, so a device that wants a stock shell just leaves it out.
{ pkgs, ... }:

{
  shared.zsh.enable = true;
  shared.eza.enable = true;
  shared.aliases.enable = true;

  shared.git = {
    enable = true;
    user.name = "Luis Quiñones";
    user.email = "lpaandres2020@gmail.com";
  };

  users.defaultUserShell = pkgs.zsh;

  # shared.aliases points core commands at replacements -- `cat` at bat, `top`
  # at btop, `man` at tldr -- so without these the aliases turn working
  # commands into command-not-found.
  environment.systemPackages = with pkgs; [
    alejandra
    bat
    btop
    macchina
    net-tools
    nyancat
    python3
    ranger
    rclone
    tldr
    unar
    xdg-utils
  ];
}
