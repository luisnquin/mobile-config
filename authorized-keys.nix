# Keys allowed to log in as root over the stage-1 USB network.
#
# THIS IS THE ONLY FILE YOU MUST EDIT AFTER FORKING. The keys below belong to
# this repository's author. An image built from an unedited checkout grants them
# root on your phone whenever it is plugged in. Replace the list; do not append
# to it.
#
# Public keys are not secrets, and checking them in on purpose is what makes the
# image reproducible from the repository alone. There is no secret material
# here: the dropbear host key is generated on the device at first boot.
[
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIXW6vsDRgI/AiOdGnQOTyiz1uLFL0o66u0Ahcw9VWyd luis@quinones.pro"
]
