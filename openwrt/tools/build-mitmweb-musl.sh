#!/usr/bin/env bash
# build-mitmweb-musl.sh - Build a self-contained mitmweb binary on musl libc.
#
# Why: OpenWrt uses musl libc, so a glibc-built PyInstaller binary would fail to
# load. We build inside an Alpine container (musl-based) and emit a single ELF
# that depends only on libc + libcrypto + libssl, both of which OpenWrt ships.
#
# Usage:
#   ./build-mitmweb-musl.sh [--arch ARCH] [--no-container] [--out DIR] [--tag VER]
#
# Examples:
#   # default: x86_64, Docker required on host
#   ./build-mitmweb-musl.sh
#   # aarch64 (e.g. for raspberry pi 4 / most modern routers)
#   ./build-mitmweb-musl.sh --arch aarch64
#   # both architectures, side-by-side
#   ./build-mitmweb-musl.sh --arch x86_64 --tag v12.0.0
#   ./build-mitmweb-musl.sh --arch aarch64 --tag v12.0.0
#   # already on Alpine? build natively without docker
#   ./build-mitmweb-musl.sh --no-container
#
# Output:
#   $OUT/mitmweb-linux-musl-<arch>-<tag>.bin      # raw ELF
#   $OUT/mitmweb-linux-musl-<arch>-<tag>.tar.xz   # tarball with SHA256SUM

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# repo root = parent of openwrt/tools/
repo_root="$(cd "$here/../.." && pwd)"

OUT="${OUT:-$repo_root/release/dist}"
ARCH="x86_64"
USE_DOCKER=1
TAG=""
PYTHON_VERSION="3.13"
PYINSTALLER_VERSION="6.20.0"

usage() {
    sed -n '2,30p' "$0"
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)           ARCH="$2"; shift 2 ;;
        --no-container)   USE_DOCKER=0; shift ;;
        --container)      USE_DOCKER=1; shift ;;
        --out)            OUT="$2"; shift 2 ;;
        --tag)            TAG="$2"; shift 2 ;;
        --python)         PYTHON_VERSION="$2"; shift 2 ;;
        --pyinstaller)    PYINSTALLER_VERSION="$2"; shift 2 ;;
        -h|--help)        usage 0 ;;
        *)                echo "unknown arg: $1" >&2; usage 1 ;;
    esac
done

# Normalize arch name (e.g. arm64 -> aarch64)
case "$ARCH" in
    x86_64|amd64|AMD64)   ARCH=x86_64 ;;
    aarch64|arm64)        ARCH=aarch64 ;;
    armv7|armhf|arm_cortex-a7_neon-vfpv4) ARCH=armv7 ;;
    mips|mipsel)          ARCH="$ARCH" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$OUT"

# Derive tag from pyproject if not passed
if [[ -z "$TAG" ]]; then
    TAG="$(grep -E '^version[[:space:]]*=' "$repo_root/pyproject.toml" 2>/dev/null \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        || true)"
    TAG="${TAG:-dev}"
fi

binary_basename="mitmweb-linux-musl-${ARCH}-${TAG}"
binary_path="$OUT/${binary_basename}.bin"
tarball_path="$OUT/${binary_basename}.tar.xz"

echo ">>> Building mitmweb for linux-musl / $ARCH (tag $TAG)"
echo "    source:  $repo_root"
echo "    output:  $binary_path"

# ---------------------------------------------------------------------------
# Step 1: Resolve & install local mitmproxy + deps inside the builder.
# ---------------------------------------------------------------------------
# We install the *local* checkout (not PyPI) so the resulting binary matches
# whatever's in this repo at build time. The pyproject.toml pins the version.

build_inside() {
    local py_image="python:${PYTHON_VERSION}-alpine"

    # Native-ext deps from pyproject.toml: aioquic, mitmproxy_rs, cryptography,
    # argon2-cffi, Brotli, bcrypt, ruamel.yaml, zstandard, mitmproxy-linux.
    # They all need a C toolchain + openssl + libffi headers + (optionally)
    # linux-headers for kqueue-style stuff.
    apk add --no-cache \
        binutils \
        git \
        build-base \
        openssl-dev \
        libffi-dev \
        linux-headers \
        cmake \
        pkgconfig \
        bash \
        file \
        cargo \
        rust >/dev/null

    # Install PyInstaller first (small, fast) so we have a known-good pip.
    pip install --no-cache-dir --break-system-packages \
        "pyinstaller==${PYINSTALLER_VERSION}" || {
            echo "ERROR: failed to install pyinstaller $PYINSTALLER_VERSION" >&2
            return 1
        }

    # Install rustup. The Alpine `rust` package gives us system cargo/rustc
    # but mitmproxy-linux's build.rs spawns `rustup run nightly cargo build
    # --target bpfel-unknown-none` to compile an eBPF redirector, and
    # Alpine does not ship a `rustup` binary.
    if ! command -v rustup >/dev/null 2>&1; then
        echo ">>> installing rustup"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --default-toolchain none --profile minimal \
                --no-modify-path
        # rustup installer writes into $CARGO_HOME (default ~/.cargo) and
        # $RUSTUP_HOME (default ~/.rustup). Add to PATH for the rest of
        # the build.
        export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
        export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
        export PATH="$CARGO_HOME/bin:$PATH"
        command -v rustup >/dev/null 2>&1 \
            || { echo "rustup install failed" >&2; return 1; }
    fi

    # Install the nightly toolchain + eBPF target. Without nightly Rust the
    # `bpfel-unknown-none` target is not available, and without the target
    # the eBPF redirector sub-crate cannot compile.
    rustup toolchain install nightly --profile minimal --component rust-src || {
        echo "ERROR: failed to install nightly toolchain" >&2
        return 1
    }
    rustup target add bpfel-unknown-none --toolchain nightly || {
        echo "ERROR: failed to add bpfel-unknown-none target" >&2
        return 1
    }

    # Install bpf-linker, required by mitmproxy-linux-ebpf's build.rs
    # (used by mitmproxy's "local" mode that runs an eBPF redirector).
    cargo install --locked bpf-linker --root /tmp/cargo-tools || {
        echo "ERROR: failed to install bpf-linker (needed by mitmproxy-linux-ebpf)" >&2
        return 1
    }
    export PATH="/tmp/cargo-tools/bin:${PATH}"
    command -v bpf-linker || { echo "bpf-linker still not on PATH" >&2; return 1; }

    # Install the local mitmproxy source tree. This compiles mitmproxy_rs
    # and friends from source via maturin.
    pip install --no-cache-dir --break-system-packages /src || {
            echo "ERROR: failed to install local /src (rust native deps failed?)" >&2
            return 1
        }

    # Build a onefile mitmweb binary, strip debug symbols.
    pyinstaller \
        --onefile \
        --clean \
        --noconfirm \
        --strip \
        --name mitmweb \
        --workpath /tmp/pyinst-work \
        --distpath /tmp/pyinst-out \
        --specpath /tmp/pyinst-spec \
        --paths /src \
        --collect-submodules mitmproxy \
        --collect-data mitmproxy \
        --exclude-module tkinter \
        --exclude-module test \
        /src/release/specs/mitmweb || {
            echo "ERROR: pyinstaller failed" >&2
            return 1
        }

    cp /tmp/pyinst-out/mitmweb /tmp/out/mitmweb.bin
    chmod +x /tmp/out/mitmweb.bin
    ls -la /tmp/out/mitmweb.bin
    file /tmp/out/mitmweb.bin || true
    ldd /tmp/out/mitmweb.bin 2>/dev/null || true
}

if [[ $USE_DOCKER -eq 1 ]]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "docker not found; rerun with --no-container on a musl host" >&2
        exit 1
    fi
    # Map ARCH to a docker platform string. Alpine on armv7 is rare; most users
    # want x86_64/aarch64. For armv7 we fall back to qemu-user emulation.
    case "$ARCH" in
        x86_64)  docker_platform="linux/amd64" ;;
        aarch64) docker_platform="linux/arm64" ;;
        *)       docker_platform="linux/amd64" ;;
    esac

    docker run --rm \
        --platform "$docker_platform" \
        -e PYINSTALLER_VERSION="$PYINSTALLER_VERSION" \
        -e PYTHON_VERSION="$PYTHON_VERSION" \
        -v "$repo_root:/src" \
        -v "$OUT:/tmp/out" \
        -w /tmp \
        "python:${PYTHON_VERSION}-alpine" \
        sh -c "$(declare -f build_inside); build_inside"
else
    # Native build — assumes we're already on a musl host (Alpine / Void / Chimera).
    build_inside
fi

# ---------------------------------------------------------------------------
# Step 2: Smoke-test, hash, and tar.
# ---------------------------------------------------------------------------

if [[ ! -f "$OUT/mitmweb.bin" ]]; then
    echo "ERROR: build did not produce $OUT/mitmweb.bin" >&2
    exit 1
fi

mv "$OUT/mitmweb.bin" "$binary_path"

echo ">>> Quick smoke test"
"$binary_path" --version

echo ">>> Producing tarball"
tmp_tar_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_tar_dir"' EXIT
mkdir -p "$tmp_tar_dir/mitmweb-linux-musl-$ARCH"
cp "$binary_path" "$tmp_tar_dir/mitmweb-linux-musl-$ARCH/mitmweb.bin"
(cd "$tmp_tar_dir" && sha256sum "mitmweb-linux-musl-$ARCH/mitmweb.bin" > SHA256SUMS) || true
(cd "$tmp_tar_dir" && tar -cJf "$tarball_path" "mitmweb-linux-musl-$ARCH" SHA256SUMS) || true

echo ">>> Done."
echo "    binary:   $binary_path"
echo "    tarball:  $tarball_path"
echo "    sha256:   $(sha256sum "$binary_path" | awk '{print $1}')"
echo
echo "To use in the OpenWrt build:"
echo "    cp $tarball_path ~/path/to/openwrt-sdk/dl/mitmweb-linux-musl-${ARCH}-${TAG}.tar.xz"
