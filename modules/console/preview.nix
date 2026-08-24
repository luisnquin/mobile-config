{pkgs}: let
  fixture = ./tests/fixture;

  binary =
    pkgs.runCommandCC "mobile-panel" {
      buildInputs = [pkgs.systemd];
    } ''
      mkdir -p $out/bin
      $CC -O2 -Wall -Wextra -std=gnu11 -o $out/bin/panel ${./panel.c} -lsystemd
    '';
in {
  console-preview = pkgs.writeShellApplication {
    name = "console-preview";
    text = ''
      exec ${binary}/bin/panel \
        --root ${fixture} \
        --subtitle "xiaomi redmi 9a . mt6765" \
        --load-note "23 mt6765 vendor threads sit in D forever" \
        --service sshd:22 \
        --service tailscaled \
        "$@"
    '';
    meta.description = "Compile the on-panel dashboard and preview it live against the test fixture, no device required";
  };
}
