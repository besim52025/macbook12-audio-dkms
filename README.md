# macbook12-audio-dkms

Out-of-tree HD-audio codec driver for the **Cirrus Logic CS4208** codec of the
12-inch **MacBook 9,1 (Early 2016)** and **MacBook 10,1 (2017)**, packaged as a
DKMS `.deb` for **Debian 13 (trixie)** with the 6.12.x kernel series.

It replaces the in-kernel `snd-hda-codec-cirrus` module with a version that
replays the macOS codec initialization sequence, enabling:

* internal speakers
* headphone jack and automatic jack switching
* internal microphone

The module is built automatically by DKMS for every installed kernel that has
headers (`AUTOINSTALL=yes`), so kernel updates need no manual steps.

## Attribution

**This project is based on
[leifliddy/macbook12-audio-driver](https://github.com/leifliddy/macbook12-audio-driver).**
All credit for the codec work — the macOS initialization sequence that makes
the CS4208 usable — belongs to upstream and to the authors it builds on
(`patch_cirrus.c` is derived from the ALSA/kernel file, Copyright 2009
Takashi Iwai; bundled kernel sources are Copyright the Linux kernel and ALSA
contributors).

This repository exists to package that work for Debian 13 and to fix the
Debian-13-specific failures of the upstream installer:

| Upstream failure on Debian 13 | Fix in this tree |
|---|---|
| prepare step rejects kernel releases like `6.12.116+deb13-amd64` ("Unsupported kernel release") | version normalization strips the `+deb13` suffix |
| looks for a `linux-source-<full-version>` tarball Debian never installs | uses `/usr/src/linux-source-6.12.tar.xz`, or the bundled `sound/pci/hda` snapshot (Linux 6.12.115) |
| DKMS builds against the running kernel instead of the target kernel | `KERNELRELEASE=${kernelver}` in `dkms.conf` |
| module BTF step fails because `pahole` is missing (Debian enables BTF for modules) | Makefile falls back to a no-op `pahole` (module builds without BTF debug data) |
| hard dependency on kernel-header metapackages can poison dpkg state | package only hard-depends on `dkms`; headers/dwarves are Recommends |

The module has been verified to compile, link and produce the correct
vermagic against `linux-headers-6.12.115+deb13-amd64` and
`linux-headers-6.12.116+deb13-amd64` (package 6.12.116-1).

## Install (Debian 13)

Grab `macbook12-audio-dkms_<version>_all.deb` from
[Releases](../../releases) (built automatically by CI), then:

```bash
sudo apt update
sudo apt install linux-headers-amd64 dwarves
sudo apt install ./macbook12-audio-dkms_0.3_all.deb
sudo reboot
```

Or run the bundled recovery installer, which also cleans up stale DKMS state
left by the upstream git installer (that stale state is what breaks kernel
headers installation on Debian 13):

```bash
sudo bash install.sh
```

### Required: speaker software volume (WirePlumber)

The internal speaker has **no usable hardware volume control** (the codec's
only analog amplifier is wired to the headphone path). PipeWire must apply
volume in software, otherwise the volume slider does nothing. The package
installs `/etc/wireplumber/wireplumber.conf.d/51-macbook-cs4208-softvol.conf`
for WirePlumber 0.5+ (what Debian 13 ships); a Lua variant for older
WirePlumber 0.4 is in `contrib/`.

After the first boot, if the speakers are silent:

```bash
amixer -c0 sset Master 100% unmute
sudo alsactl store
systemctl --user restart wireplumber
```

## Verify

```bash
dkms status                     # macbook12-audio-driver/0.3, ...: installed
modinfo -n snd-hda-codec-cirrus # path must contain /updates/
aplay -l                        # analog devices of card 0
cat /proc/asound/card0/codec* | grep -i codec   # "Cirrus Logic CS4208"
```

More (Secure Boot, custom kernels, build failures): see
`debian/README.Debian`, which is also shipped inside the package at
`/usr/share/doc/macbook12-audio-dkms/README.Debian`.

## Building the package

```bash
dpkg-buildpackage -b -us -uc
```

Only `dpkg-dev` is required; the resulting `.deb` appears one directory up.

## License

GPL-2.0 — see [LICENSE](LICENSE) and `debian/copyright` for the precise
per-file breakdown (driver code: GPL-2.0-or-later per its SPDX headers;
bundled `sound/pci/hda` snapshot: GPL-2.0-only).

## Upstream

* Upstream project: https://github.com/leifliddy/macbook12-audio-driver
* If you find the codec work useful, star upstream first — this tree only
  packages and Debian-fits it.
