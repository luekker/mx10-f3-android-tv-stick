# Build env for the vendor sun50iw9 U-Boot 2018.05 (32-bit ARM) and later mainline bits.
FROM debian:bookworm
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
      gcc-aarch64-linux-gnu bc bison flex device-tree-compiler libssl-dev \
      python3 python-is-python3 swig u-boot-tools git ca-certificates file xxd \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
