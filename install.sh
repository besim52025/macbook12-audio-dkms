#!/bin/bash
# Recovery + install script for macbook12-audio-dkms 0.3 (Debian 13 / trixie)
#
# Usage:  sudo bash install.sh      (run in the folder containing the .deb)
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# The upstream installer (github.com/leifliddy/macbook12-audio-driver)
# registers a DKMS module (macbook12-audio-driver/0.1) whose build fails
# on Debian 13 (it does not understand the "+deb13" kernel release naming).
# DKMS installs a hook in /etc/kernel/header_postinst.d/, so EVERY attempt
# to configure a kernel-headers package re-runs that broken build and
# fails, which dpkg reports as:
#
#   "linux-headers-amd64, linux-headers-cloud-amd64 and
#    linux-headers-rt-amd64 not configured yet"
#
# That is why installing/downgrading headers (6.12.115, 6.12.116, ...)
# never helped: the failure is not a dependency problem, it is the stale
# DKMS registration.  Step 1 below removes it; after that the headers
# packages configure normally again.

set -u

[ "$(id -u)" = 0 ] || { echo "Run with sudo:  sudo bash install.sh" >&2; exit 1; }

DEB="macbook12-audio-dkms_0.3_all.deb"
[ -f "$DEB" ] || { echo "ERROR: $DEB not found in $(pwd)" >&2; exit 1; }

echo "== 1/6  Removing stale DKMS registrations (macbook12-audio-driver) =="
if command -v dkms >/dev/null 2>&1; then
  dkms status 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *macbook12-audio-driver*)
        ver="$(printf '%s\n' "$line" | sed -E 's#.*macbook12-audio-driver/([^,/-]+).*#\1#')"
        [ -n "$ver" ] || continue
        echo "  removing DKMS module macbook12-audio-driver/$ver ..."
        dkms remove -m macbook12-audio-driver -v "$ver" --all || true
        ;;
    esac
  done
  # Leftover source trees of versions other than the one we ship:
  for d in /usr/src/macbook12-audio-driver-*; do
    [ -d "$d" ] || continue
    case "$d" in
      /usr/src/macbook12-audio-driver-0.3) continue ;;
    esac
    echo "  deleting stale source tree $d ..."
    rm -rf -- "$d"
  done
else
  echo "  dkms not installed yet - will be installed below"
fi

echo "== 2/6  Removing half-configured macbook12-audio-dkms (if any) =="
dpkg -r --force-depends macbook12-audio-dkms 2>/dev/null || true

echo "== 3/6  Configuring pending packages (this unblocks the headers) =="
dpkg --configure -a

echo "== 4/6  Updating package lists =="
apt-get update || echo "WARNING: apt update failed - continuing with cached lists"

echo "== 5/6  Installing kernel headers and build tools =="
apt-get install -y linux-headers-amd64 dkms dwarves || \
  echo "WARNING: some packages could not be installed.  The driver package
WARNING: still installs; fix with 'sudo dpkg --configure -a' and retry."

echo "== 6/6  Installing $DEB =="
apt-get install -y "./$DEB"

echo
echo "== Verification =="
dkms status | grep macbook12-audio-driver || echo "DKMS: module not registered?!"
if [ -e "/lib/modules/$(uname -r)/updates/snd-hda-codec-cirrus.ko" ]; then
  echo "OK: driver present for the running kernel ($(uname -r))."
else
  echo "NOTE: driver not yet present for the running kernel ($(uname -r))."
fi
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  echo "NOTE: Secure Boot is ENABLED.  The unsigned module will NOT load;"
  echo "      either disable Secure Boot or enroll a MOK (see README.md)."
fi
echo
echo "If 'dkms status' shows 'installed' for your kernel: reboot now (sudo reboot)."
echo "Afterwards, if sound is silent, set the software volume (see README.md):"
echo "  wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0"
