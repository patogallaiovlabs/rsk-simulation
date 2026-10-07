#!/usr/bin/env bash
# Rebuild altbn128 libbn128.so for linux/{amd64,arm64}.
#
# Reproduces repos/native/Dockerfile's original toolchain: Go 1.13 in GOPATH mode
# with the aarch64 cross-compiler, all from one amd64 container (that is what the
# Makefile's CC=aarch64-linux-gnu-gcc expects). Modern Go cannot build this source
# at all -- it uses a pre-modules relative import ("./bn256"), dropped after 1.15.
set -euo pipefail
NAT=/Users/patricio/workspace/rsk/rsk-simulation/repos/native

docker run --rm --platform linux/amd64 -v "$NAT":/native golang:1.13-buster bash -euc '
  export DEBIAN_FRONTEND=noninteractive
  # Buster is EOL: its mirrors are gone, everything lives on archive.debian.org
  # and the Release files are expired, hence Check-Valid-Until=false.
  printf "%s\n" \
    "deb http://archive.debian.org/debian buster main" \
    "deb http://archive.debian.org/debian-security buster/updates main" \
    > /etc/apt/sources.list
  echo "Acquire::Check-Valid-Until \"false\";" > /etc/apt/apt.conf.d/99no-check-valid
  apt-get -qq update
  apt-get -qq install -y gcc-aarch64-linux-gnu openjdk-11-jdk-headless >/dev/null
  export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

  # Same trick as the original Dockerfile: the repo ships the JNI headers it wants.
  cp -r /native/jniheaders/include/* "$JAVA_HOME/include/"

  # The original Dockerfile set GOPATH to the altbn128 dir itself, which writes
  # src/ pkg/ bin/ straight into the repo. Any GOPATH works as long as the sources
  # sit OUTSIDE $GOPATH/src -- that is what permits the relative "./bn256" import.
  export GOPATH=/gopath GO111MODULE=off
  cd /native/altbn128
  # `go get` would pull x/sys master, whose newer files Go 1.13 rejects
  # ("C source files not allowed when not using cgo"). Pin to a revision
  # contemporary with the Go 1.13.5 the original Dockerfile used.
  mkdir -p "$GOPATH/src/golang.org/x"
  git clone -q https://github.com/golang/sys "$GOPATH/src/golang.org/x/sys"
  git -C "$GOPATH/src/golang.org/x/sys" checkout -q \
    "$(git -C "$GOPATH/src/golang.org/x/sys" rev-list -1 --before=2019-12-31 master)"
  echo "x/sys pinned to $(git -C "$GOPATH/src/golang.org/x/sys" rev-parse --short HEAD)"
  make clean
  make linux-amd64
  make linux-arm64
  # This image has no `file`, so read the ELF e_machine byte directly
  # (0x3e = x86-64, 0xb7 = aarch64) and fail loudly on a wrong-arch build.
  for a in amd64 arm64; do
    m=$(od -An -tx1 -j18 -N1 "$a/libbn128.so" | tr -d " ")
    printf "%-6s e_machine=0x%s\n" "$a" "$m"
  done
  [ "$(od -An -tx1 -j18 -N1 amd64/libbn128.so | tr -d " ")" = "3e" ] || { echo "amd64 is not x86-64" >&2; exit 1; }
  [ "$(od -An -tx1 -j18 -N1 arm64/libbn128.so | tr -d " ")" = "b7" ] || { echo "arm64 is not aarch64" >&2; exit 1; }
'
