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
# Redis specifically must be given an explicit bind. With no `bind` line and no
# password, redis enables protected-mode and answers loopback only, which looks
# exactly like a firewall problem from the other end.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.mobile.services.data;

  # rndis0 keeps its kernel name in stage-2: the .link-file rename that gives
  # the host side `usbtether0` runs on the host, and this device's udev cannot
  # complete an event for it anyway.
  links = [
    "tailscale0"
    "rndis0"
  ];
in
{
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

      ensureDatabases = [ cfg.database ];
      ensureUsers = [
        {
          name = cfg.database;
          ensureDBOwnership = true;
        }
      ];

      # `ensureUsers` deliberately cannot set a password, and this repo is
      # public so one could not live here anyway. The role exists with no
      # password and therefore cannot authenticate over TCP until someone runs,
      # once, on the device:
      #
      #   doas -u postgres psql -c "\password ${cfg.database}"
      #
      # Peer authentication over the unix socket works without it.
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

      # See the protected-mode note in this module's header: this has to be an
      # address, not null, and the firewall below is what actually restricts it.
      bind = "0.0.0.0";

      # noeviction rather than an LRU policy. This instance is a data store as
      # much as a cache, and an eviction policy turns "out of memory" from an
      # error the client sees into rows that quietly stop existing.
      settings.maxmemory = "256mb";
      settings.maxmemory-policy = "noeviction";
    };

    # Redis forks to write an RDB snapshot and relies on the copy-on-write pages
    # never being charged in full. With the heuristic overcommit the kernel
    # ships by default, that fork is refused on a device this small exactly when
    # it matters most -- under memory pressure -- and the snapshot is lost with
    # only a line in redis's own log to say so.
    boot.kernel.sysctl."vm.overcommit_memory" = 1;

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
