#!/bin/bash

# Prepare the CS4208 out-of-tree driver sources for a given kernel release.
#
# Fixes over the upstream leifliddy/macbook12-audio-driver version:
#   * accepts Debian kernel releases such as 6.12.115+deb13-amd64
#     (the upstream regex rejected the "+deb13" suffix)
#   * finds the Debian kernel source tarball /usr/src/linux-source-6.12.tar.xz
#     (upstream looked for a nonexistent linux-source-<full version> tarball)
#   * derives the archive top-level directory from the file name instead of
#     assuming "linux-<version>" (Debian uses "linux-source-6.12")
#   * supports MACBOOK12_AUDIO_KERNEL_SRC to point at a kernel tarball manually
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Based on upstream prepare.cirrus.driver.sh (C) leifliddy and contributors,
# with Debian/Ubuntu logic adapted from davidjo/snd_hda_macbookpro.

set -euo pipefail

kernel_release="${1:-$(uname -r)}"

# Normalize: strip flavor ("6.12.115+deb13-amd64" -> "6.12.115+deb13"),
# Ubuntu ABI ("6.8.0-49-generic" -> "6.8.0"), then the Debian "+debXX"
# suffix ("6.12.115+deb13" -> "6.12.115").
kernel_version="${kernel_release%%-*}"
kernel_version="${kernel_version%%_*}"
deb_full_version=""
if [[ $kernel_version == *+* ]]; then
  deb_full_version="$kernel_version"
  kernel_version="${kernel_version%%+*}"
fi

if [[ ! $kernel_version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([.-]rc[0-9]+)?$ ]]; then
  echo "Unsupported kernel release: $kernel_release" >&2
  exit 2
fi

major_version="${kernel_version%%.*}"
version_tail="${kernel_version#*.}"
minor_version="${version_tail%%.*}"
kernel_short_version="$major_version.$minor_version"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

build_dir="$script_dir/build"
patch_dir="$script_dir/patch_cirrus"
hda_dir="$build_dir/hda"
base_url="https://cdn.kernel.org/pub/linux/kernel/v${major_version}.x"

if [[ -n ${MACBOOK12_AUDIO_KERNEL_CACHE:-} ]]; then
  cache_dir="$MACBOOK12_AUDIO_KERNEL_CACHE"
elif (( EUID == 0 )); then
  cache_dir="/var/cache/macbook12-audio-driver"
else
  cache_dir="$build_dir"
fi

download() {
  local url="$1"
  local destination="$2"

  if command -v curl >/dev/null; then
    curl --fail --location --retry 3 --silent --show-error \
      --output "$destination" "$url"
  elif command -v wget >/dev/null; then
    wget --quiet --tries=3 --output-document="$destination" "$url"
  else
    echo "Install curl or wget to download the matching kernel source." >&2
    return 127
  fi
}

refresh_checksums() {
  local partial="$checksums.part"
  rm -f "$partial"
  download "$base_url/sha256sums.asc" "$partial"
  mv "$partial" "$checksums"
}

checksum_for() {
  local archive_name="$1"
  awk -v filename="$archive_name" '$2 == filename { print $1; exit }' "$checksums"
}

# Derive the top-level directory of a kernel source archive from its name:
#   linux-6.12.48.tar.xz          -> linux-6.12.48
#   linux-source-6.12.tar.xz      -> linux-source-6.12
#   linux-source-6.8.0.tar.bz2    -> linux-source-6.8.0
bundled_snapshot_of() {
  # Bundled sound/pci/hda snapshot shipped with the package, for 6.12.x
  # kernels when no matching linux-source package is installed.
  local bundled="$script_dir/bundled/6.12/sound-pci-hda.tar.xz"
  if [[ $kernel_short_version == "6.12" && -f $bundled ]]; then
    printf '%s\n' "$bundled"
  fi
}

archive_top_of() {
  local archive="$1"
  local top
  top="$(basename "$archive" | sed -E 's/\.tar\.(xz|bz2|gz|zst)$//')"
  # sanity check: the entry must exist in the archive (it is the first
  # archive member, so this scan stops immediately)
  if ! tar -tf "$archive" --occurrence=1 "$top" >/dev/null 2>&1; then
    # fall back to reading the first member for nonstandard archives
    top="$(tar -tf "$archive" 2>/dev/null | head -1 | cut -d/ -f1)"
    [[ -n $top ]] || return 1
  fi
  printf '%s\n' "$top"
}

mkdir -p "$build_dir" "$cache_dir"
rm -rf "$hda_dir"

# Debian/Ubuntu Kernel logic adapted from
# https://github.com/davidjo/snd_hda_macbookpro/blob/master/install.cirrus.driver.sh
is_debian_like=0
# Check if we are dealing with Debian
if [[ $(grep '^NAME=' /etc/os-release | grep -c Debian) -eq 1 ]]; then
  is_debian_like=1
# Check if we are dealing with Ubuntu
elif [[ $(grep '^NAME=' /etc/os-release | grep -c Ubuntu) -eq 1 ]]; then
  is_debian_like=1
# For Ubuntu based distributions like Mint, "ubuntu" will be mentioned in ID_LIKE
elif [[ $(grep '^ID_LIKE=' /etc/os-release | grep -c "ubuntu") -eq 1 ]]; then
  is_debian_like=1
# In some other Ubuntu based distributions like Pop OS, we need to check ID
elif [ $(grep '^ID=' /etc/os-release | grep -c "ubuntu") -eq 1 ]; then
  is_debian_like=1
fi

archive=""
if [[ -n ${MACBOOK12_AUDIO_KERNEL_SRC:-} ]]; then
  # Explicitly provided kernel source archive (useful for custom kernels,
  # containers or offline builds).  Must be a .tar.xz/.tar.bz2/.tar.gz.
  archive="${MACBOOK12_AUDIO_KERNEL_SRC}"
  [[ -f $archive ]] || { echo "MACBOOK12_AUDIO_KERNEL_SRC=$archive is not a file" >&2; exit 1; }
  kernel_version="$(basename "$archive" | sed -E 's/\.tar\.(xz|bz2|gz|zst)$//; s/^linux-//')"
  kernel_version="${kernel_version#source-}"
elif [ $is_debian_like -ge 1 ]; then
  # NOTE for Ubuntu we need to use the distribution kernel sources as they seem
  # to be significantly modified from the mainline kernel sources generally with
  # backports from later kernels.
  #
  # Debian names its source package after the stable ABI (linux-source-6.12),
  # Ubuntu after the full upstream version (linux-source-6.8.0).
  source_candidates=(
    "/usr/src/linux-source-${kernel_short_version}.tar.xz"
    "/usr/src/linux-source-${kernel_short_version}.tar.bz2"
  )
  if [[ -n $deb_full_version ]]; then
    source_candidates+=(
      "/usr/src/linux-source-${deb_full_version}.tar.xz"
      "/usr/src/linux-source-${deb_full_version}.tar.bz2"
    )
  fi
  source_candidates+=(
    "/usr/src/linux-source-${kernel_version}.tar.xz"
    "/usr/src/linux-source-${kernel_version}.tar.bz2"
  )

  for candidate in "${source_candidates[@]}"; do
    if [[ -f $candidate ]]; then
      archive="$candidate"
      break
    fi
  done

  if [[ -z $archive ]]; then
    archive="$(bundled_snapshot_of || true)"
    if [[ -n $archive ]]; then
      echo "No linux-source package found; using the bundled sound/pci/hda" >&2
      echo "snapshot (Linux 6.12.115). For an exact source match install:" >&2
      echo "  sudo apt install linux-source-6.12" >&2
    fi
  fi

  if [[ -z $archive ]]; then
    echo "Linux kernel source not found in /usr/src." >&2
    echo "Please install the kernel source package matching your kernel ($kernel_release):" >&2
    if [[ -n $deb_full_version || $(grep '^NAME=' /etc/os-release | grep -c Debian) -eq 1 ]]; then
      echo "  sudo apt install linux-source-${kernel_short_version}" >&2
    else
      echo "  sudo apt install linux-source-${kernel_version}" >&2
    fi
    echo "You also need the matching kernel headers:" >&2
    echo "  sudo apt install linux-headers-\$(uname -r)" >&2
    echo "Alternatively, point MACBOOK12_AUDIO_KERNEL_SRC at a kernel source tarball." >&2
    exit 1
  fi
else
  checksums="$cache_dir/sha256sums-v${major_version}.asc"
  [[ -f $checksums ]] || refresh_checksums
  for candidate_version in "$kernel_version" "$kernel_short_version"; do
    archive_name="linux-${candidate_version}.tar.xz"
    expected_sha256="$(checksum_for "$archive_name")"

    if [[ -z $expected_sha256 ]]; then
      refresh_checksums
      expected_sha256="$(checksum_for "$archive_name")"
    fi
    [[ -n $expected_sha256 ]] || continue

    candidate_archive="$cache_dir/$archive_name"
    if [[ -f $candidate_archive ]]; then
      actual_sha256="$(sha256sum "$candidate_archive" | awk '{ print $1 }')"
    else
      actual_sha256=""
    fi

    if [[ $actual_sha256 != "$expected_sha256" ]]; then
      partial_archive="$candidate_archive.part"
      rm -f "$partial_archive"
      echo "Downloading $archive_name"
      if ! download "$base_url/$archive_name" "$partial_archive"; then
        rm -f "$partial_archive"
        continue
      fi

      actual_sha256="$(sha256sum "$partial_archive" | awk '{ print $1 }')"
      if [[ $actual_sha256 != "$expected_sha256" ]]; then
        rm -f "$partial_archive"
        echo "SHA-256 verification failed for $archive_name" >&2
        exit 3
      fi
      mv "$partial_archive" "$candidate_archive"
    fi

    archive="$candidate_archive"
    kernel_version="$candidate_version"
    break
  done

  if [[ -z $archive ]]; then
    archive="$(bundled_snapshot_of || true)"
    if [[ -n $archive ]]; then
      echo "No kernel.org source archive found; using the bundled sound/pci/hda" >&2
      echo "snapshot (Linux 6.12.115)." >&2
    fi
  fi

  if [[ -z $archive ]]; then
    echo "No verified kernel.org source archive found for $kernel_release" >&2
    exit 4
  fi
fi

if [[ $archive == "$script_dir/bundled/"* ]]; then
  # entries are stored without a top-level directory: sound/pci/hda/...
  archive_top=""
  strip_hda=1
  strip_pci=2
else
  archive_top="$(archive_top_of "$archive")"
  strip_hda=2
  strip_pci=3
fi
member="${archive_top:+$archive_top/}"

if (( major_version > 6 || (major_version == 6 && minor_version >= 17) )); then
  makefile_name="Makefile_cs420x"
  tar --strip-components=$strip_hda -xf "$archive" --directory="$build_dir" \
    "${member}sound/hda"
  mv "$hda_dir/codecs/cirrus/Makefile" "$hda_dir/codecs/cirrus/Makefile.orig"
  mv "$hda_dir/codecs/cirrus/cs420x.c" "$hda_dir/codecs/cirrus/cs420x.c.orig"
  cp "$patch_dir/cs420x.c" \
    "$patch_dir/patch_cirrus_a1534_setup.h" \
    "$patch_dir/patch_cirrus_a1534_pcm.h" \
    "$hda_dir/codecs/cirrus"
  cp "$patch_dir/$makefile_name" "$hda_dir/codecs/cirrus/Makefile"
else
  makefile_name="Makefile_cirrus"
  tar --strip-components=$strip_pci -xf "$archive" --directory="$build_dir" \
    "${member}sound/pci/hda"
  mv "$hda_dir/Makefile" "$hda_dir/Makefile.orig"
  mv "$hda_dir/patch_cirrus.c" "$hda_dir/patch_cirrus.c.orig"
  cp "$patch_dir/patch_cirrus.c" \
    "$patch_dir/patch_cirrus_a1534_setup.h" \
    "$patch_dir/patch_cirrus_a1534_pcm.h" \
    "$hda_dir"
  cp "$patch_dir/$makefile_name" "$hda_dir/Makefile"
fi

if (( major_version > 6 || (major_version == 6 && minor_version >= 17) )); then
  sed -i 's/\.free/.remove/' "$hda_dir/codecs/cirrus/patch_cirrus_a1534_pcm.h"
fi

if (( major_version == 6 && minor_version >= 12 && minor_version < 17 )); then
  sed -i 's/snd_pci_quirk/hda_quirk/' "$hda_dir/patch_cirrus.c"
  sed -i 's/SND_PCI_QUIRK\b/HDA_CODEC_QUIRK/' "$hda_dir/patch_cirrus.c"
fi

if (( major_version == 6 && minor_version <= 11 )); then
  sed -i 's/hda_quirk/snd_pci_quirk/' "$hda_dir/patch_cirrus.c"
fi

if (( major_version < 5 || (major_version == 5 && minor_version < 6) )); then
  sed -i 's/timespec64/timespec/' "$hda_dir/patch_cirrus.c"
  sed -i 's/timespec64/timespec/' "$hda_dir/patch_cirrus_a1534_pcm.h"
  sed -i 's/ktime_get_real_ts64/getnstimeofday/' "$hda_dir/patch_cirrus_a1534_pcm.h"
fi

cp "$script_dir/$makefile_name" "$script_dir/Makefile"
