# Console-visible display for dandelion.
#
# This device has no KMS. /sys/class/drm/card0/device/driver is `pvrsrvkm` --
# the PowerVR render node -- and /sys/class/drm/card0-* does not exist, so there
# are zero connectors and nothing can modeset. Output is fbdev-only, through
# mtkfb. That rules out every Wayland compositor; fbcon is the console.
#
# fbcon binds correctly on its own (vtcon1 reports "frame buffer device",
# bound=1), but two vendor behaviours stop its output from ever reaching the
# user's eyes. The panel backlight is handled in ./stage-1/tasks; the pan is
# handled here.
#
# mtkfb only binds the OVL to the framebuffer from mtkfb_pan_display_impl(),
# which runs on FBIOPAN_DISPLAY and nothing else. fbcon draws into framebuffer
# memory but never pans, so on this driver console text is composited exactly
# never. `msm-fb-refresher --loop` issues the missing FBIOPAN_DISPLAY calls.
# Despite the name it is not Qualcomm-specific, and Mobile NixOS documents it as
# applicable to other vendors.
{ ... }:

{
  mobile.quirks.fb-refresher.stage-1.enable = true;
  mobile.quirks.fb-refresher.enable = true;

  mobile.boot.stage-1.tasks = [ ./stage-1/tasks/dandelion-display-task.rb ];
}
