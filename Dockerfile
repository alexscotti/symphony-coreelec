# Thin layer over the fork's own build container (tools/docker/noble, tagged
# coreelec-noble by cebuild). Adds only what the Mac host forces on us: the
# build tree lives in an ext4 image that the entrypoint loop-mounts, because
# macOS file systems are usually case-insensitive (the kernel source has
# case-colliding names) and Docker's own disk image is often on a small
# internal disk.
FROM coreelec-noble

USER root

# parted/fdisk/mtools/pigz are for am9usb (repartitioning the built image)
RUN apt-get update \
 && apt-get install -y e2fsprogs util-linux mount less vim-tiny \
      parted fdisk mtools dosfstools pigz --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*

# Several toolchains are prebuilt linux-x86 binaries (Android clang for the
# kernel, Linaro gcc 7.5 for u-boot). On an arm64 host they run through Docker
# Desktop's x86_64 binfmt emulation, which needs a real amd64 loader, libc and
# the few shared libraries those binaries link (cc1 wants libz.so.1).
# ports.ubuntu.com carries no amd64, so amd64 gets its own apt source.
RUN if [ "$(uname -m)" = "aarch64" ]; then \
      sed -i '/^Types:/a Architectures: arm64' /etc/apt/sources.list.d/ubuntu.sources \
      && printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: noble noble-updates noble-security\nComponents: main universe\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
           > /etc/apt/sources.list.d/amd64.sources \
      && dpkg --add-architecture amd64 \
      && apt-get update \
      && apt-get install -y --no-install-recommends \
           libc6:amd64 zlib1g:amd64 libstdc++6:amd64 libgcc-s1:amd64 libtinfo6:amd64 libncurses6:amd64 \
      && rm -rf /var/lib/apt/lists/*; \
    fi

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
