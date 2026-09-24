#
# Rolling CachyOS bootc image for generic x86-64.
#
# Build context:
#
#   cachyos-bootc/
#   ├── Containerfile
#   └── etc/
#
# Build:
#
#   podman build -t localhost/cachyos-bootc:latest .
#
# The image deliberately follows the current Bootcrew Arch bootc
# implementation for the bootc-specific filesystem and initramfs setup.
#

FROM docker.io/cachyos/cachyos:latest AS base
# brings along:
# git, openssh, curl, pacman-contrib, sudo, cachyos-hooks and others.

#
# --------------------------------------------------------------------------
# Build bootc from current upstream source.
# --------------------------------------------------------------------------
#

FROM base AS bootc-builder

RUN pacman -Syu --noconfirm \
        make \
        git \
        rust \
        go-md2man \
        ostree \
        glibc \
        pkgconf \
        clang \
        base-devel \
        libselinux

WORKDIR /home/build

RUN git clone https://github.com/bootc-dev/bootc.git .

RUN make bin install-all DESTDIR=/output

#
# --------------------------------------------------------------------------
# CachyOS system
# --------------------------------------------------------------------------
#

FROM base AS system

# bootc images keep pacman state in /usr/lib/sysimage rather than /var.
# Move the existing Arch pacman state there and rewrite pacman.conf.
RUN grep "= */var" /etc/pacman.conf | \
    sed "/= *\/var/s/.*=// ; s/ //" | \
    xargs -n1 sh -c \
    'mkdir -p "/usr/lib/sysimage/$(dirname "$(echo "$1" | sed "s@/var/@@")")" && \
     mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i \
        -e "/= *\/var/ s/^#//" \
        -e "s@= */var@= /usr/lib/sysimage@g" \
        -e "/DownloadUser/d" \
        /etc/pacman.conf
RUN pacman -Syu --noconfirm


#
# --------------------------------------------------------------------------
# Host OS packages
# --------------------------------------------------------------------------
#

RUN pacman -S --noconfirm \
        bubblewrap \
        dracut \
        linux-cachyos \
        linux-firmware \
        ostree \
        btrfs-progs \
        e2fsprogs \
        xfsprogs \
        dosfstools \
        skopeo \
        dbus \
        dbus-glib \
        libselinux

#
# Remove cached package archives.
#

RUN pacman -S --clean --noconfirm

#
# --------------------------------------------------------------------------
# Install bootc
# --------------------------------------------------------------------------
#

COPY --from=bootc-builder /output /

#
# --------------------------------------------------------------------------
# Basic boot configuration
# --------------------------------------------------------------------------
#

RUN systemctl enable \
        systemd-networkd \
        systemd-resolved \
        systemd-timesyncd \
        sshd && \
    systemctl mask systemd-firstboot.service

#
# A machine-specific machine-id must not be baked into the image.
# systemd will generate one on first boot.
#
# UTC is deliberately the image default. Set the machine's actual timezone
# through persistent /etc configuration on the deployed system.
#

RUN echo "uninitialized" > /etc/machine-id && \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime

#
# --------------------------------------------------------------------------
# Default wired networking
# --------------------------------------------------------------------------
#
# This is an OS-level default, so it lives under /usr/lib rather than the
# persistent /etc tree. It matches any Ethernet interface and obtains its
# address through DHCP.
#
# Machine-specific networking can instead be placed in /etc/systemd/network
# in the configuration repository.
#

RUN mkdir -p /usr/lib/systemd/network && \
    printf '[Match]\nType=ether\n\n[Network]\nDHCP=yes\n' \
        > /usr/lib/systemd/network/20-wired.network

#
# systemd-resolved creates its runtime stub at boot. tmpfiles creates the
# /etc/resolv.conf symlink because container builds cannot safely replace
# the container runtime's resolv.conf mount.
#

RUN printf \
        'L! /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf\n' \
        > /usr/lib/tmpfiles.d/resolv-conf.conf

#
# --------------------------------------------------------------------------
# bootc initramfs
# --------------------------------------------------------------------------
#
# This follows Bootcrew's current initramfs configuration:
#
#   - reproducible
#   - non-hostonly
#   - zstd compression
#   - bootc dracut module
#

RUN mkdir -p /usr/lib/dracut/dracut.conf.d && \
    printf \
        'systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n' \
        > /usr/lib/dracut/dracut.conf.d/30-bootc-system.conf && \
    printf \
        'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" bootc "\n' \
        > /usr/lib/dracut/dracut.conf.d/30-bootc-container.conf

RUN kernel="$(ls -1 /usr/lib/modules | head -n1)" && \
    dracut --force "/usr/lib/modules/${kernel}/initramfs.img"

#
# --------------------------------------------------------------------------
# bootc filesystem layout
# --------------------------------------------------------------------------
#
# Keep this aligned with the current Bootcrew Arch image.
#

RUN sed -i 's|^HOME=.*|HOME=/var/home|' /etc/default/useradd

RUN rm -rf \
        /boot \
        /home \
        /root \
        /usr/local \
        /srv \
        /opt \
        /mnt \
        /var \
        /usr/lib/sysimage/log \
        /usr/lib/sysimage/cache/pacman/pkg

RUN mkdir -p \
        /sysroot \
        /boot \
        /usr/lib/ostree \
        /var

#
# These are the persistent-state paths used by bootc.
#
# /ostree is retained here because this is how the current Bootcrew Arch
# image is constructed, even though current bootc no longer requires the
# old /ostree directory requirement.
#

RUN ln -sT sysroot/ostree /ostree && \
    ln -sT var/roothome /root && \
    ln -sT var/srv /srv && \
    ln -sT var/opt /opt && \
    ln -sT var/mnt /mnt && \
    ln -sT var/home /home
#    ln -sT ../var/usrlocal /usr/local
# above commented out because you're not supposed to do it if the image
# will be derived from or something

RUN printf \
        'd /var/opt 0755 root root -\n' \
        'd /var/home 0755 root root -\n' \
        'd /var/srv 0755 root root -\n' \
        'd /var/mnt 0755 root root -\n' \
        'd /var/usrlocal 0755 root root -\n' \
        'd /var/roothome 0700 root root -\n' \
        'd /run/media 0755 root root -\n' \
        >> /usr/lib/tmpfiles.d/bootc-base-dirs.conf

#
# Enable the composefs backend and make the physical sysroot read-only.
#

RUN printf \
        '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' \
        > /usr/lib/ostree/prepare-root.conf


#
# --------------------------------------------------------------------------
# Persistent /etc defaults from this repository
# --------------------------------------------------------------------------
#
# IMPORTANT:
#
#   COPY etc/ /etc/
#
# is intentional.
#
# Do NOT copy anything to /usr/etc. bootc/OSTree generates and manages its
# internal /usr/etc representation itself.
#

COPY etc/ /etc/

RUN rm -f /etc/.gitkeep

#
# --------------------------------------------------------------------------
# bootc image identification and validation
# --------------------------------------------------------------------------
#

LABEL containers.bootc="1"
RUN bootc container lint

FROM quay.io/coreos/chunkah:latest AS chunker

RUN --mount=type=bind,target=/run/src,rw \
    --mount=from=system,target=/chunkah,ro \
    chunkah build \
    --prune /sysroot/ \
    --max-layers 128 \
    --skip-special-files \
    --label "containers.bootc=1" \
    --label "ostree.commit-" \
    --label "ostree.final-diffid-" \
    --output oci:/run/src/out 

# no bootc lint after chunkah because that will fuck up the layers or something
FROM oci:out
