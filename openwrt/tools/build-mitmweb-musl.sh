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
# Step 0: Cache directories on the runner, bind-mounted into the Alpine
# container so cargo / pip / PyInstaller state survives across CI runs.
# ---------------------------------------------------------------------------
# The runner-side paths come from the workflow (which sets them to
# ${HOME}/.cargo etc.). Inside the Alpine container the default user is
# root with $HOME=/root, so cargo/pip/PyInstaller all look at /root/...
# by default — see the docker run block below, which maps the runner
# paths onto /root/... so the tools find them without env-var wiring.
#
# actions/cache restores these on the runner before the container
# starts; the bind-mount then makes the same files visible inside the
# container. On a cache hit, cargo reuses its registry, pip reuses its
# downloaded wheels, PyInstaller reuses its pre-stripped binary cache,
# and rustup skips re-downloading the toolchain — saving ~5 min of the
# overall ~12 min build.
: "${CARGO_HOME:=$HOME/.cargo}"
: "${RUSTUP_HOME:=$HOME/.rustup}"
: "${PIP_CACHE_DIR:=$HOME/.cache/pip}"
: "${PYI_CACHE_DIR:=$HOME/.cache/pyinstaller}"
# Pre-create on the host so the bind-mount has a directory to mount on
# the very first (cold-cache) run.
mkdir -p "$CARGO_HOME" "$RUSTUP_HOME" "$PIP_CACHE_DIR" "$PYI_CACHE_DIR"

# ---------------------------------------------------------------------------
# Step 1: Resolve & install local mitmproxy + deps inside the builder.
# ---------------------------------------------------------------------------
# We install the *local* checkout (not PyPI) so the resulting binary matches
# whatever's in this repo at build time. The pyproject.toml pins the version.

build_inside() {
    # The parent script has `set -euo pipefail`, but it does NOT
    # propagate across `sh -c "$(declare -f ...); build_inside"` — the
    # inner `sh` runs without strict mode, so a failed PyInstaller run
    # would be silently swallowed (the next `cp` against a missing
    # source also "fails" without aborting, leaving an empty/stub
    # /tmp/out/mitmweb.bin and a green CI step). Re-assert it here so
    # any failure aborts and surfaces in the CI log.
    set -euo pipefail

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
        rust \
        curl \
        ca-certificates \
        xz >/dev/null

    # Install PyInstaller first (small, fast) so we have a known-good pip.
    # --no-cache-dir is intentional: pip's cache lives at $PIP_CACHE_DIR
    # (bind-mounted from the runner, where actions/cache persists it),
    # not in pip's per-user default. Pip picks it up via $PIP_CACHE_DIR.
    pip install --break-system-packages \
        "pyinstaller==${PYINSTALLER_VERSION}" || {
            echo "ERROR: failed to install pyinstaller $PYINSTALLER_VERSION" >&2
            return 1
        }

    # Install rustup. We need a Rust toolchain so we can build mitmproxy_rs
    # from source on musl (PyPI ships glibc wheels only).
    if ! command -v rustup >/dev/null 2>&1; then
        echo ">>> installing rustup"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --default-toolchain stable --profile minimal \
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

    # Install mitmproxy from the local source tree WITHOUT pulling in its
    # transitive deps. We install those explicitly below so we can omit
    # `mitmproxy-linux`, which on musl cannot be built (it requires the
    # `bpfel-unknown-none` nightly target that has no prebuilt musl
    # artifacts, and which we don't need on a router anyway since the
    # "local" mode it backs is for desktop capture, not gateway use).
    pip install --break-system-packages --no-deps /src || {
        echo "ERROR: failed to install local /src" >&2
        return 1
    }

    # Install mitmproxy_rs separately, also --no-deps, so its Linux
    # conditional `Requires-Dist: mitmproxy-linux` is NOT honoured. The
    # Rust extension itself builds fine on musl; only the redirector
    # binary that comes from mitmproxy-linux doesn't.
    pip install --break-system-packages --no-deps mitmproxy_rs || {
        echo "ERROR: failed to install mitmproxy_rs" >&2
        return 1
    }

    # Install every other runtime dep with normal resolution. None of them
    # transitively depend on mitmproxy-linux, so they all install cleanly.
    pip install --break-system-packages \
        aioquic argon2-cffi asgiref bcrypt brotli certifi \
        cryptography flask h11 h2 hyperframe kaitaistruct ldap3 pyopenssl \
        pyparsing pyperclip publicsuffix2 "ruamel.yaml" sortedcontainers \
        tornado typing-extensions urwid wsproto zstandard || {
        echo "ERROR: failed to install runtime deps" >&2
        return 1
    }

    # Patch the upstream PyInstaller hook that bundles mitmproxy-linux's
    # redirector binary. We don't ship that binary, so the hook must
    # declare no extra files — otherwise PyInstaller errors out trying
    # to include a path that doesn't exist.
    #
    # Note: `mitmproxy_linux.executable_path()` still works (it returns
    # a missing path), and mitmproxy_rs.local.LocalRedirector's
    # unavailable_reason() will return a string explaining the redirector
    # is missing — which the mitmweb UI surfaces in its mode selector.
    site_packages="$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
    cat > "${site_packages}/mitmproxy_rs/_pyinstaller/hook-mitmproxy_linux.py" <<'EOF'
# Overridden by openwrt/tools/build-mitmweb-musl.sh: skip the eBPF
# redirector binary that the upstream hook tries to bundle, because
# the musl build cannot produce it (no prebuilt bpfel-unknown-none
# target for nightly on musl).
binaries = []
EOF

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

    # Sanity: PyInstaller --onefile appends a PYZ archive to the
    # bootloader ELF (the TOC at the end of the file references it).
    # If the ELF is only the bootloader (~65KB) the archive is missing
    # and the resulting ipk would be a stub. Guard against that
    # silently shipping — historically, with `set -euo pipefail` not
    # propagating into the docker sub-shell, a failed PyInstaller run
    # would leave a stub behind without failing CI.
    sz=$(stat -c %s /tmp/out/mitmweb.bin)
    if [ "$sz" -lt 1000000 ]; then
        echo "ERROR: mitmweb.bin is only $sz bytes — PyInstaller likely" >&2
        echo "       produced only the bootloader stub without the" >&2
        echo "       appended PYZ archive. Check the PyInstaller log" >&2
        echo "       above for the real failure (missing module," >&2
        echo "       import error, Analysis exception, etc.)." >&2
        return 1
    fi
    # NOTE: an earlier version of this script also checked for a
    # 'MEI\014\013\012\013\016' cookie at the very end of the ELF.
    # PyInstaller does write a magic cookie there, but it's obfuscated
    # (`MAGIC_BASE` with byte[3] += 0x0C — see pyi_archive.c), not the
    # literal ASCII sequence. Doing a naive grep on the raw bytes gave
    # false negatives on otherwise-good 29MB ELFs. Skip the marker
    # check; the size check above is the actual signal we care about.
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
        # Inside the Alpine container the default user is root with
        # $HOME=/root, so cargo/pip/PyInstaller all look at /root/...
        # by default. Map the runner's cache dirs onto those exact paths
        # so the tools find them without any extra env-var wiring.
        -v "$CARGO_HOME:/root/.cargo" \
        -v "$RUSTUP_HOME:/root/.rustup" \
        -v "$PIP_CACHE_DIR:/root/.cache/pip" \
        -v "$PYI_CACHE_DIR:/root/.cache/pyinstaller" \
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

# Note: do NOT execute the binary here. It is dynamically linked against
# musl libc, which only exists on Alpine / OpenWrt — on a glibc runner
# (the typical CI image) execution fails with
# "ld.so: bad ELF interpreter" and exits 77. PyInstaller having exited 0
# above is sufficient evidence the ELF was produced successfully.

echo ">>> Producing tarball"
tmp_tar_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_tar_dir"' EXIT
mkdir -p "$tmp_tar_dir/mitmweb-linux-musl-$ARCH"
cp "$binary_path" "$tmp_tar_dir/mitmweb-linux-musl-$ARCH/mitmweb.bin"
(cd "$tmp_tar_dir" && sha256sum "mitmweb-linux-musl-$ARCH/mitmweb.bin" > SHA256SUMS)
# Note: don't use `tar -cJf`. busybox tar shells out to `xz` and we've seen
# it fail with "can't execute 'xz'" even when `xz` is on PATH (likely a
# quoting/environment issue when invoked via `sh -c "$(declare -f ...)"`).
# Pipe through xz explicitly instead.
(cd "$tmp_tar_dir" && tar -cf - "mitmweb-linux-musl-$ARCH" SHA256SUMS | xz -T0 > "$tarball_path")

echo ">>> Done."
echo "    binary:   $binary_path"
echo "    tarball:  $tarball_path"
echo "    sha256:   $(sha256sum "$binary_path" | awk '{print $1}')"
echo
echo "To use in the OpenWrt build:"
echo "    cp $tarball_path ~/path/to/openwrt-sdk/dl/mitmweb-linux-musl-${ARCH}-${TAG}.tar.xz"
