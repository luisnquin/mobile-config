# On-disk layout of the raw bring-up log. Imported by both the stage-2 writer
# (./default.nix) and the host-side reader (../../tools), so the two can never
# disagree about where the log lives.
#
# The log deliberately does not live on a filesystem. Every previous attempt at
# stage-2 diagnostics put a file on the rootfs, which made reading it depend on
# the rootfs mounting -- and an unmountable rootfs is one of the states being
# diagnosed. Worse, the debug window on this device is created by *zeroing* the
# ext4 magic (see AGENTS.md / the latch), so the only moment there is time to
# read a log is the exact moment the filesystem cannot be mounted.
#
# So: a fixed offset inside the partition, past the end of any filesystem this
# port puts there. p41 is 23782383 KiB (22.68 GiB) and the rootfs image is
# ~3.0 GiB, so everything from 16 GiB on is space no filesystem will touch.
#
# CONSTRAINT: growing the rootfs past 16 GiB would overwrite this. The deferred
# "resize p41 to fill the partition" task must resize to 16 GiB, not to the
# whole partition. That is the price of not depending on a filesystem.
rec {
  # 16 GiB, in 4096-byte blocks.
  slotA = 4194304;

  # 64 MiB per slot, in blocks.
  slotBlocks = 16384;

  # Two slots, written alternately. A power cut during a write can only damage
  # the slot being written; the other still holds the previous snapshot. Without
  # this a hard power-cycle -- the normal way this device is recovered -- would
  # be able to destroy the only copy of the log describing why it needed one.
  slotB = slotA + slotBlocks;

  # Block 0 of a slot is the header; the rest is payload.
  payloadBlocks = slotBlocks - 1;

  magic = "DANDELION-LOG1";
}
