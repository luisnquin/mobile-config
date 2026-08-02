# Lights the panel on Xiaomi dandelion (MT6765, NT36525B BOE "dijing").
#
# The display engine on this device is healthy from the moment stage-1 starts:
# LK initialises the panel and passes `atag,videolfb-*` through /chosen, so
# mtkfb sets `is_lcm_inited = 1` and primary_display_init() deliberately skips
# disp_lcm_init(). The link is up, the OVL composites, the framebuffer is
# scanned out. It just is not lit.
#
# The panel's own init table leaves DCS 0x51 ("write display brightness") at
# 0x00 while enabling brightness control through 0x53 = 0x2C:
#
#   nt36525b_vdo_hdp_boe_dijing.c:157   {0x51, 0x01, {0x00}}
#   nt36525b_vdo_hdp_boe_dijing.c:161   {0x53, 1,    {0x2C}}
#
# Raising 0x51 is the job of Android's lights HAL. Stage-1 has no equivalent,
# so an otherwise perfect frame is scanned into liquid crystal with the LED
# driver off -- indistinguishable, from the outside, from a dead panel.
#
# Two further MediaTek behaviours have to be neutralised for the light to stay
# on once raised. Both were observed on this unit as "white flash, then black":
#
#   * primary_display.c:7902 keeps `static unsigned int last_level` and returns
#     early on `last_level == level`. Re-asserting the same brightness is a
#     silent no-op, which makes a failed backlight look like an ignored write.
#     REFRESH_LEVELS therefore alternates between two adjacent values.
#
#   * The idle manager parks the DSI link in ULPS after `idle_check_interval`
#     milliseconds (debug.c:73, default 50) because DISP_OPT_IDLEMGR_ENTER_ULPS
#     is enabled. The link stops carrying video while the backlight stays lit.

class Tasks::DandelionDisplay < SingletonTask
  DEBUGFS_PATH = "/sys/kernel/debug"

  # process_dbg_opt()'s command vocabulary is bound to this file (debug.c:1760).
  # /sys/kernel/debug/dispsys is a *different* and much smaller parser that
  # answers these commands with "parse command error!".
  MTKFB_DEBUG = "#{DEBUGFS_PATH}/mtkfb"

  # idletime_set() clamps to [33, 1000000] ms (debug.c:1718).
  IDLETIME = "#{DEBUGFS_PATH}/displowpower/idletime"
  IDLETIME_MAX = 1000000

  # Adjacent, so alternating between them is not perceptible, but distinct, so
  # neither write is swallowed by the `last_level` check.
  REFRESH_LEVELS = [200, 201]
  REFRESH_INTERVAL = 2

  BACKLIGHT = "/sys/class/leds/lcd-backlight/brightness"

  # Depending on Tasks::Graphics is not enough on this device. That task is
  # `:Any` of FBDev or DRM, and dandelion has a PowerVR render node at
  # /dev/dri/card0, so the DRM branch resolves almost immediately -- even though
  # that node exposes zero connectors and cannot modeset. Graphics then reports
  # done ~4s before Tasks::Graphics::FBDev has run, and this task would fire
  # against a /sys/class/leds that is not populated yet.
  def initialize()
    add_dependency(:Task, Tasks::Graphics::FBDev.instance)
    add_dependency(:Mount, "/sys")
    add_dependency(:Files, BACKLIGHT)
    Targets[:Graphics].add_dependency(:Task, self)
  end

  def run()
    mount_debugfs()
    disable_idle_manager()
    clear_no_update()
    bind_fbcon()
    start_backlight()
  end

  # Runs before the framebuffer is handed to anything that draws, so the first
  # frame a user could see is already lit.
  def ux_priority()
    -50
  end

  private

  # System.mount is deliberately avoided: it consults System.mount_points, which
  # bind-mounts a private procfs at /.proc, and that failed here with exit 127.
  # Nothing below needs the bookkeeping, and mounting debugfs twice is harmless.
  def mount_debugfs()
    return if File.exist?(MTKFB_DEBUG)
    System.run("mount", "-t", "debugfs", "none", DEBUGFS_PATH)
  rescue => e
    log("dandelion-display: could not mount debugfs: #{e.message}")
  end

  # enable_idlemgr(0) clears the idlemgr_task_wakeup atomic and kicks the
  # manager awake (disp_lowpower.c:1322). It does not touch the
  # DISP_OPT_IDLE_MGR helper option, so that option reading back as 1 afterwards
  # is expected and is not evidence that the write failed.
  def disable_idle_manager()
    write_node(MTKFB_DEBUG, "enable_idlemgr:0")
    write_node(IDLETIME, IDLETIME_MAX.to_s)
  end

  # mtkfb latches `no_update` from FB_ACTIVATE_NO_UPDATE (mtkfb.c:826) and then
  # discards every FBIOPAN_DISPLAY while it is set (mtkfb.c:587), which silently
  # disables the only path that binds the OVL to our framebuffer. Writing
  # bits_per_pixel goes through check_var with FB_ACTIVATE_NOW and clears it.
  def clear_no_update()
    path = "/sys/class/graphics/fb0/bits_per_pixel"
    return unless File.exist?(path)
    write_node(path, File.read(path).strip)
  end

  # fbcon does not take the console over by itself on this kernel. The boot log
  # reports `Console: colour dummy device 80x25` and `console [tty0] enabled`,
  # and never the `Console: switching to colour frame buffer device 90x100` that
  # do_bind_con_driver() prints -- so printk keeps going to the dummy console
  # and nothing is ever composited. Forcing an unbind/rebind of the fbcon
  # vtconsole produces that line and makes tty1 real.
  #
  # vtcon0 is the dummy console and vtcon1 is fbcon on this device, but neither
  # index is guaranteed, so the `name` attribute decides rather than the number.
  FBCON_NAME = "frame buffer device"
  VTCONSOLE_CANDIDATES = 4

  def bind_fbcon()
    VTCONSOLE_CANDIDATES.times do |i|
      path = "/sys/class/vtconsole/vtcon#{i}"
      next unless File.exist?("#{path}/name")
      next unless File.read("#{path}/name").include?(FBCON_NAME)

      log("dandelion-display: rebinding fbcon on vtcon#{i}")
      write_node("#{path}/bind", "0")
      write_node("#{path}/bind", "1")
      return
    end
    log("dandelion-display: no fbcon vtconsole found")
  end

  # Spawned as a shell loop rather than a Ruby thread: the stage-1 init is mruby
  # 4.0.0, which has no Thread. This mirrors how the fb-refresher quirk runs its
  # own loop.
  #
  # The loop has to end itself at switch_root, and nothing else will do it. It is
  # spawned detached, so stage-1 does not reap it; its `sh` keeps running from
  # the dismantled initramfs, where PATH no longer resolves and the old /sys is
  # gone. Observed on a real boot: `sleep` stopped resolving, which left `while
  # true` with nothing to throttle it, and the loop spun a core while writing two
  # failures per iteration to /dev/console -- for 428s, until the battery or the
  # user intervened. That starves stage-2 badly enough to look like a hang.
  #
  # So: an absolute path to sleep, because PATH is what disappears first, and a
  # loop condition on the node itself rather than `true`. After switch_root the
  # old root's /sys/class/leds is empty, the condition fails, and the loop exits
  # on its own. Stage-2 owns the backlight from that point.
  def start_backlight()
    unless File.exist?(BACKLIGHT)
      log("dandelion-display: no backlight control node at #{BACKLIGHT}")
      return
    end
    log("dandelion-display: driving backlight via #{BACKLIGHT}")

    sleep_bin = System.which("sleep") || "sleep"
    steps = REFRESH_LEVELS.map do |level|
      "echo #{level} > #{BACKLIGHT} || exit 0; #{sleep_bin} #{REFRESH_INTERVAL} || exit 0"
    end
    System.spawn("sh", "-c", "while [ -w #{BACKLIGHT} ]; do #{steps.join("; ")}; done")
  end

  def write_node(path, value)
    System.write(path, value)
  rescue => e
    log("dandelion-display: write #{value.inspect} > #{path} failed: #{e.message}")
  end
end
