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
# ~3.0 GiB (784879 blocks), which ends far below slotA.
#
# CONSTRAINT: the filesystem must END before slotA, and "how full it is" is not
# the test. ext4 lays block-group metadata at fixed positions across the whole
# extent it was created with, regardless of fill level, so a 3 GiB-full but
# 24 GiB-wide filesystem still owns block 4194304. That is not hypothetical: a
# 5945595-block ext4 on p41 put group 128's block bitmap at exactly 4194304, its
# inode bitmap at 4194305 and its inode table at 4194306-4194816, and the ring
# wrote log text straight into the inode table -- e2fsck -fn reported illegal
# blocks in inode 1047035 (group 128), the "block numbers" being ASCII read as
# pointers (538976288 = 0x20202020, four spaces). It stayed survivable only
# because group 128 was still INODE_UNINIT/BLOCK_UNINIT and unused.
#
# So never resize the rootfs to fill the partition. Deploying an image whose own
# superblock ends below slotA is necessary but NOT sufficient, and believing it
# was is how the 5945595-block filesystem above came to exist: the image written
# to p41 was 784879 blocks and verified chunk by chunk, and the device still came
# up 24 GiB wide. Mobile NixOS re-grows it from the initrd on every single boot
# -- mobile-nixos/modules/rootfs.nix sets autoResize on "/", and
# boot/init/lib/mounting.rb turns that into a Tasks::AutoResize dependency of the
# root mount -- so the resize happens after the deploy, undoing it silently.
#
# ../../devices/xiaomi-dandelion/default.nix therefore turns autoResize off, and
# that override is what actually holds this constraint. Verify with
# `dumpe2fs -h <img> | grep 'Block count'` before deploying, and again on the
# device after the first boot, because only the second reading can catch a
# resize.
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
