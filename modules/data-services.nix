# PostgreSQL and Redis, sized for the device and reachable only over the two
# links it actually has.
#
# This is what the port is for: a always-on data server for small side projects,
# on hardware that draws about two watts. The constraints are 1875 MB of RAM
# (half of which is now zram swap, see ./zram-linux-4.9.nix), eight A53 cores
# with no meaningful single-thread speed, and eMMC.
#
# TRUST BOUNDARY. The device has no wifi driver and no cellular, so its entire
# network surface is two point-to-point links: rndis0 to the build host over
# USB, and tailscale0. Both are already authenticated -- one physically, one by
# the tailnet -- and nothing else can route to this machine at all. So the
# services listen on every interface and the firewall is what narrows them,
# rather than the other way round: binding to the tailnet address would mean
# ordering both units after an address that appears asynchronously, and units
# that wait on this device tend to wait forever (see
# ../modules/usb-network.nix and the udev note in ./zram-linux-4.9.nix).
#
# Redis needs both halves of this. The NixOS default binds it to 127.0.0.1, and
# since Redis 7 protected-mode triggers on the *default user having no
# password* rather than on the old "no bind and no requirepass" pair -- so
# widening the bind alone still gets every non-loopback client a DENIED reply
# that reads like a firewall problem from the other end. The password is
# therefore mandatory, not hardening, and it is generated below.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mobile.services.data;

  secrets = "/var/lib/secrets";
  redisPasswordFile = "${secrets}/redis-password";
  postgresPasswordFile = "${secrets}/postgres-${cfg.database}-password";

  # 48 characters from an alphabet of 62 is about 285 bits. Alphanumeric only,
  # so it survives being pasted into a connection URI without escaping.
  #
  # The random source is read once into a variable rather than piped through
  # `head -c`, which would close the pipe under /dev/urandom and leave a
  # `tr: write error: Broken pipe` in the journal on every start. 512 bytes
  # yield ~124 usable characters.
  generate = target: mode: owner: ''
    if [ ! -s ${target} ]; then
      chars=$(head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9')
      ( umask 077
        printf '%s' "''${chars:0:48}" > ${target} )
    fi
    chown ${owner} ${target}
    chmod ${mode} ${target}
  '';

  # rndis0 keeps its kernel name in stage-2: the .link-file rename that gives
  # the host side `usbtether0` runs on the host, and this device's udev cannot
  # complete an event for it anyway.
  links = [
    "tailscale0"
    "rndis0"
  ];
in {
  options.mobile.services.data = {
    enable = lib.mkEnableOption "PostgreSQL and Redis for side projects";

    database = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = ''
        Name of the initial database, and of the role that owns it. Its password
        is not set here -- see the note in this module.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      enableTCPIP = true;

      ensureDatabases = [cfg.database];
      ensureUsers = [
        {
          name = cfg.database;
          ensureDBOwnership = true;
        }
      ];

      # The role's password is set from ${postgresPasswordFile} by
      # postgresql-password.service below; `ensureUsers` deliberately cannot.
      authentication = ''
        host all all 100.64.0.0/10 scram-sha-256
        host all all 172.16.42.0/24 scram-sha-256
      '';

      settings = {
        max_connections = 40;

        shared_buffers = "192MB";
        effective_cache_size = "512MB";
        work_mem = "8MB";
        maintenance_work_mem = "96MB";

        # Parallel query costs more than it buys here. Gathering across A53
        # cores adds startup and tuple-transfer overhead to queries that, at
        # side-project data sizes, were already going to finish in one pass.
        max_parallel_workers_per_gather = 0;

        # eMMC. The default of 4.0 is calibrated for a seek on spinning rust and
        # pushes the planner onto sequential scans it does not need here.
        random_page_cost = 1.1;

        # Spread the checkpoint write out. A burst of dirty pages to eMMC stalls
        # every other writer on the device, including the journal.
        checkpoint_completion_target = 0.9;
        max_wal_size = "1GB";
        min_wal_size = "128MB";
      };
    };

    services.redis.servers."" = {
      enable = true;

      # Every interface; see the header. The firewall below is what narrows it.
      bind = "0.0.0.0";

      requirePassFile = redisPasswordFile;

      # noeviction rather than an LRU policy. This instance is a data store as
      # much as a cache, and an eviction policy turns "out of memory" from an
      # error the client sees into rows that quietly stop existing.
      settings.maxmemory = "256mb";
      settings.maxmemory-policy = "noeviction";
    };

    # Neither password can live in this repo, and neither can be a manual step:
    # redis.service reads its file in ExecStartPre and fails outright without
    # one, and a postgres role with no password cannot authenticate over TCP at
    # all. Generating both on first start is what keeps a freshly flashed device
    # usable without putting a credential in git.
    #
    #   ssh dandelion sudo cat ${redisPasswordFile}
    #   ssh dandelion sudo cat ${postgresPasswordFile}
    #
    # Deleting a file rolls that password on the next start of its service.
    systemd.services.data-secrets = {
      description = "Generate the database passwords on first start";
      before = [
        "redis.service"
        "postgresql.service"
      ];
      requiredBy = [
        "redis.service"
        "postgresql.service"
      ];
      path = [pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0751 ${secrets}
        ${generate redisPasswordFile "0400" "root:root"}
        ${generate postgresPasswordFile "0440" "root:postgres"}
      '';
    };

    # Re-applied on every start rather than only at initdb, so the file stays
    # the source of truth: replacing it and restarting is how the password is
    # rotated. `:'pw'` is psql's own quoting, which is what makes a password
    # from outside this module safe to interpolate -- and it has to arrive on
    # stdin, because `-c` is documented to take only what the *server* can parse
    # and passes psql-specific syntax like `:'var'` through untouched.
    systemd.services.postgresql-password = {
      description = "Apply the ${cfg.database} role password from ${postgresPasswordFile}";
      # postgresql-setup, not postgresql: the role this alters is created there,
      # and that unit is also the one that waits for the server to accept
      # connections. data-secrets is listed too because postgresql.service is
      # often already running when this is activated, so nothing else orders the
      # two -- which is how the first deploy of this module raced and applied an
      # empty password.
      after = [
        "postgresql-setup.service"
        "data-secrets.service"
      ];
      requires = [
        "postgresql-setup.service"
        "data-secrets.service"
      ];
      wantedBy = ["multi-user.target"];
      path = [
        config.services.postgresql.package
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
      };
      # Read into a variable first. A command substitution used directly as an
      # argument does not trip `set -e` when it fails, so an unreadable file
      # would otherwise reach psql as an empty password.
      script = ''
        pw=$(cat ${postgresPasswordFile})
        psql -v ON_ERROR_STOP=1 -v pw="$pw" <<'SQL'
        ALTER ROLE "${cfg.database}" PASSWORD :'pw';
        SQL
      '';
    };

    networking.firewall.interfaces = lib.genAttrs links (_: {
      allowedTCPPorts = [
        config.services.postgresql.settings.port
        config.services.redis.servers."".port
      ];
    });

    environment.systemPackages = [
      config.services.postgresql.package
      pkgs.redis
    ];
  };
}
