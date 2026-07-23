#!/usr/bin/env bash
# build-mitmweb-ipk.sh - Build OpenWrt .ipk files for mitmweb.
#
# Why this script exists (and why there is no openwrt/Makefile anymore):
# -----------------------------------------------------------------------------
# The original design used OpenWrt's full SDK build system (Makefile +
# package.mk + ipkg-build + rstrip.sh + sstrip). That worked at first, but
# the moment we tried to ship a PyInstaller --onefile ELF through it, the
# chain broke in subtle ways:
#
#   * OpenWrt's rstrip.sh runs `sstrip -z` on every ELF in the ipk.
#     sstrip assumes a clean ELF section layout; PyInstaller's bootloader
#     + appended PYZ archive doesn't match that, so sstrip silently
#     truncated the 29 MB binary down to a ~30 KB ELF skeleton, producing
#     a ~33 KB stub ipk. The fix landed as PKG_NO_STRIP:=1 but it was
#     fighting the toolchain.
#
#   * The SDK's busybox tar dropped the -J flag on the floor (treated the
#     xz stream as plain tar, exited 0 having extracted nothing).
#
#   * Three layers of Makefile quoting (`$(...)` vs `$$(...)` vs `${...}`)
#     made diagnostic dumps unreliable.
#
# PyInstaller's output is *already* a stripped, ready-to-run ELF — there's
# no need for a real OpenWrt build at all. An ipk is just an `ar` archive
# containing control.tar.gz + data.tar.gz + debian-binary. This script
# constructs those directly from the artifact the musl job already
# produces, with standard GNU tools available on any Linux runner.
#
# Result: no SDK Docker image, no `make defconfig`, no feeds, no
# rstrip.sh, no sstrip, no surprises. Reproducible, fast, and the binary
# goes through the wire exactly once.
#
# Usage:
#   ./build-mitmweb-ipk.sh \
#       --tarball path/to/mitmweb-linux-musl-<arch>-<ver>.tar.xz \
#       --arch x86_64 \
#       --version v13.0.0.dev \
#       --out path/to/output-dir
#
# Outputs (in --out):
#   mitmweb_<ver>-r1_<arch>.ipk
#   luci-app-mitmweb_<ver>-r1_all.ipk

set -euo pipefail

TARBALL=""
ARCH="x86_64"
VERSION=""
OUT=""

usage() { sed -n '2,30p' "$0"; exit "${1:-1}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tarball)  TARBALL="$2"; shift 2 ;;
        --arch)     ARCH="$2";    shift 2 ;;
        --version)  VERSION="$2"; shift 2 ;;
        --out)      OUT="$2";     shift 2 ;;
        -h|--help)  usage 0 ;;
        *)          echo "unknown arg: $1" >&2; usage 1 ;;
    esac
done

[[ -n "$TARBALL" ]]  || { echo "ERROR: --tarball required" >&2; usage 1; }
[[ -n "$VERSION"  ]] || { echo "ERROR: --version required" >&2;  usage 1; }
[[ -f "$TARBALL" ]]  || { echo "ERROR: tarball not found: $TARBALL" >&2; exit 1; }
[[ -n "$OUT"      ]] || { echo "ERROR: --out required" >&2;      usage 1; }

# Resolve --out to an absolute path. The ar(1) subshell later runs with
# cwd=$WORK (a fresh mktemp dir), so a relative --out would resolve
# against the wrong directory and `ar` would error with "No such file
# or directory". Make --out absolute up-front so the subshell's cwd
# doesn't matter.
case "$OUT" in
    /*) ;;
    *)  OUT="$(cd "$(dirname -- "$OUT")" && pwd)/$(basename -- "$OUT")" ;;
esac

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ">>> Building OpenWrt ipks"
echo "    tarball: $TARBALL"
echo "    arch:    $ARCH"
echo "    version: $VERSION"

# ----------------------------------------------------------------------------
# 1. Extract the musl tarball and validate the ELF.
# ----------------------------------------------------------------------------
# tarball layout (from openwrt/tools/build-mitmweb-musl.sh):
#   mitmweb-linux-musl-<arch>-<ver>/
#       mitmweb.bin
#       SHA256SUMS
tar -xJf "$TARBALL" -C "$WORK"
src_root="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -n1)"
bin="$src_root/mitmweb.bin"
[[ -f "$bin" ]] || { echo "ERROR: $bin not found in tarball" >&2; exit 1; }

bin_sz=$(wc -c < "$bin" | tr -d ' ')
echo "    ELF size: $bin_sz bytes"
if (( bin_sz < 1000000 )); then
    echo "ERROR: mitmweb.bin is only $bin_sz bytes — musl build produced" >&2
    echo "       only the PyInstaller bootloader stub without the PYZ archive." >&2
    echo "       Re-run the 'Build mitmweb ELF (musl, $ARCH)' step." >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# 2. Build helper: lay out a control/ + data/ tree, then ar them into an ipk.
# ----------------------------------------------------------------------------
# $1 = package name (e.g. "mitmweb")
# $2 = pkg arch string for the filename (e.g. "x86_64" or "all")
# Remaining args = "CONTROL_VAR=value ..." pairs plus a final "--" then a
# sequence of "src_path dst_path mode" triples to install into data/.
build_ipk() {
    local pkg="$1" arch="$2"; shift 2
    local control_vars=() triples=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then shift; break; fi
        control_vars+=("$1"); shift
    done
    while [[ $# -gt 0 ]]; do triples+=("$1" "$2" "$3"); shift 3; done

    local root="$WORK/pkg-$pkg"
    rm -rf "$root"
    mkdir -p "$root/control" "$root/data"

    # Generate control file from KEY=VALUE pairs.
    {
        for kv in "${control_vars[@]}"; do
            echo "$kv"
        done
        echo "Architecture: $arch"
        printf "Description: "
        case "$pkg" in
            mitmweb)
                echo "Self-contained mitmweb binary (built with PyInstaller against musl libc)"
                echo " that provides an interactive man-in-the-middle web UI for HTTP/1, HTTP/2,"
                echo " HTTP/3, and WebSocket traffic."
                echo ""
                echo " This package only ships the daemon, init script, and UCI defaults. Install"
                echo " luci-app-mitmweb in addition for a web-based configuration UI."
                ;;
            luci-app-mitmweb)
                echo "LuCI web interface for the OpenWrt-side configuration of mitmweb: service"
                echo " control, ports, transparent-proxy iptables integration, CA certificate"
                echo " download, and a link out to mitmweb's own web UI for full proxy features"
                echo " (filters, intercept rules, modify_*, map_*, block list, replay, etc.)."
                echo ""
                echo " This package deliberately does NOT duplicate anything mitmweb's own web UI"
                echo " already handles; it only covers router-side concerns (procd lifecycle,"
                echo " network integration, CA files, system logging)."
                ;;
        esac
    } > "$root/control/control"

    # Install scripts (postinst, prerm) — generated below for mitmweb only;
    # luci-app-mitmweb has none.
    if [[ "$pkg" == "mitmweb" ]]; then
        # Self-heal for the "old install left 0644 scripts behind"
        # scenario: if opkg (or any earlier install) ever extracted
        # these scripts without +x, we get into a stuck state where
        # `opkg install` sees "up to date" and won't re-extract, but
        # the postinst can't be exec'd. The self-heal at the top of
        # each script chmods $0 and re-execs via `sh` (which doesn't
        # require +x on the script). After the first run, the file is
        # 0755 forever; the check just no-ops on subsequent installs.
        cat > "$root/control/postinst" <<'EOF'
#!/bin/sh
[ -x "$0" ] || chmod 0755 "$0"
[ -x "$0" ] || exec /bin/sh "$0" "$@"
# Create the mitmweb user/group if they don't exist. The init script and
# uci-defaults/99-mitmweb-perms both `chown mitmweb:mitmweb` into the
# confdir; without these accounts the chowns fail silently and the
# CA private key ends up owned by the build-host uid baked into the
# tarball (501 on macOS). `id mitmweb` returns non-zero only when the
# user is missing on busybox; groupid 472 matches the UID reserved in
# the OpenWrt wiki for "network daemons".
grep -q '^mitmweb:' /etc/passwd || echo 'mitmweb:x:472:472:mitmweb:/etc/mitmweb:/sbin/nologin' >> /etc/passwd
grep -q '^mitmweb:' /etc/group || echo 'mitmweb:x:472:' >> /etc/group
chown -R mitmweb:mitmweb /etc/mitmweb 2>/dev/null || true
chmod 0750 /etc/mitmweb
mkdir -p /var/log
touch /var/log/mitmweb.log
chown mitmweb:mitmweb /var/log/mitmweb.log
exit 0
EOF
        cat > "$root/control/prerm" <<'EOF'
#!/bin/sh
[ -x "$0" ] || chmod 0755 "$0"
[ -x "$0" ] || exec /bin/sh "$0" "$@"
/etc/init.d/mitmweb stop >/dev/null 2>&1 || true
/etc/init.d/mitmweb disable >/dev/null 2>&1 || true
exit 0
EOF
        # OpenWrt's ipkg-build also includes these even when empty:
        # conffiles lists user-editable config files (none for mitmweb
        # yet, but the empty file must exist); postinst-pkg / prerm-pkg
        # are "package-level" hooks that run during upgrades too
        # (mitmweb has nothing to do there, but the empty stubs must
        # be present); postrm runs after the package is removed.
        # Some opkg forks choke when these are missing — match
        # ipkg-build's output 1:1.
        : > "$root/control/conffiles"
        cat > "$root/control/postrm" <<'EOF'
#!/bin/sh
exit 0
EOF
        cat > "$root/control/postinst-pkg" <<'EOF'
#!/bin/sh
exit 0
EOF
        cat > "$root/control/prerm-pkg" <<'EOF'
#!/bin/sh
exit 0
EOF
    fi

    # Lay out data tree from (src, dst, mode) triples.
    # Plain `install -m` won't create leading directories; use mkdir -p
    # first so the destination's parent exists. POSIX-portable — works
    # on both GNU coreutils install and BSD install.
    for ((i=0; i<${#triples[@]}; i+=3)); do
        local src="${triples[i]}" dst="${triples[i+1]}" mode="${triples[i+2]}"
        mkdir -p "$(dirname "$root/data$dst")"
        install -m "$mode" "$src" "$root/data$dst"
    done

    # Pack: control.tar.gz + data.tar.gz + debian-binary -> gzip-of-tar.
    # Two compatibility shims here that ipkg-build also relies on:
    #   * `tar --format=ustar --no-xattrs --no-acls` — forces POSIX ustar
    #     tar format with no extended headers, no xattrs, no ACLs. GNU tar
    #     on a modern runner defaults to GNU format with extra pax
    #     headers, which older opkg parsers can't read and silently fail.
    #   * `chmod 755 postinst prerm` BEFORE tar-ing — opkg extracts
    #     scripts with their original mode and refuses to execute
    #     non-0755 files (errs with "Permission denied" / exit 126).
    #     CRITICAL: must happen BEFORE the tar command below, otherwise
    #     the tarball captures 0644 and chmod is a no-op for the
    #     installed package. ipkg-build chmods scripts at this same
    #     stage; the previous version of this script chmod-ed AFTER
    #     tar-ing, which silently did nothing.
    chmod 0755 "$root/control/postinst" "$root/control/prerm" \
              "$root/control/postrm" \
              "$root/control/postinst-pkg" \
              "$root/control/prerm-pkg" 2>/dev/null || true
    (cd "$root/control" && tar --format=ustar --no-xattrs --no-acls --owner=0 --group=0 -czf "$WORK/control.tar.gz" .)
    # --owner=0 --group=0: stamp every entry in data.tar.gz as root:root.
    # Without these, the tar carries the build-host uid (501 on macOS,
    # 1000 on Debian) and opkg on the target device extracts files
    # belonging to that uid, which doesn't exist on OpenWrt. Result:
    # /etc/mitmweb, /usr/lib/mitmweb/mitmweb.bin, etc. all end up owned
    # by 501:20, and `chown mitmweb:mitmweb` in the postinst fails
    # silently (mitmweb user is created by postinst now, but root:root
    # is still the right baseline for everything before the chown).
    (cd "$root/data"    && tar --format=ustar --no-xattrs --no-acls --owner=0 --group=0 -czf "$WORK/data.tar.gz"    .)
    printf '2.0\n' > "$WORK/debian-binary"

    local out_ipk="$OUT/${pkg}_${VERSION}-r1_${arch}.ipk"
    rm -f "$out_ipk"
    # Package: OpenWrt's ipk format is gzip-of-tar-of-tar — a single
    # gzip stream wrapping a tar archive that contains the three
    # package files (which are themselves gzipped tars). The outer
    # gzip is detected by opkg via the `1f 8b` magic bytes; without
    # it opkg sees a plain tarball and rejects it with "Malformed
    # package file". The reference for this format is OpenWrt's
    # ipkg-build script, which uses `tar -czf` (note the lowercase
    # `z` = gzip the outer container).
    #
    # Members:
    #   ./debian-binary    — literal "2.0\n", mode 0644
    #   ./control.tar.gz   — control dir + scripts (control, postinst, prerm)
    #   ./data.tar.gz      — the package's installed files
    #
    # NO standalone `./` directory entry — pass file arguments
    # directly so tar doesn't add a `./` entry as the first member.
    (cd "$WORK" && tar --format=ustar --no-xattrs --no-acls -czf "$out_ipk" \
        ./debian-binary ./control.tar.gz ./data.tar.gz)

    local sz=$(wc -c < "$out_ipk" | tr -d ' ')
    echo "    $out_ipk ($sz bytes)"
}

# ----------------------------------------------------------------------------
# 3. Build mitmweb_<ver>-r1_<arch>.ipk
# ----------------------------------------------------------------------------
# File layout (mirrors the old Package/mitmweb/install recipe 1:1):
#   /usr/lib/mitmweb/mitmweb.bin        — the stripped ELF from the tarball
#   /usr/bin/mitmweb                    — wrapper that sets HOME
#   /etc/config/mitmweb                 — UCI defaults
#   /etc/init.d/mitmweb                 — procd init script
#   /etc/hotplug.d/iface/99-mitmweb-restart
#   /etc/logrotate.d/mitmweb
#   /etc/sysctl.d/99-mitmweb.conf
#   /etc/rpcd/acl.d/50-mitmweb.json
#   /etc/uci-defaults/99-mitmweb-perms
#   /etc/mitmweb/                       — empty confdir (mode 0750)
PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# We bundle the empty confdir as a zero-byte file with mode 0750; the
# postinst script chowns it to mitmweb:mitmweb anyway. ipkg-build's
# behaviour with truly-empty directories is finicky; a sentinel is more
# portable across OpenWrt versions. Create the sentinel file now so the
# triple below has a real source to install.
mkdir -p "$WORK/sentinel-etc-mitmweb"
: > "$WORK/sentinel-etc-mitmweb/.keep"

build_ipk "mitmweb" "$ARCH" \
    "Package: mitmweb" \
    "Version: ${VERSION}-r1" \
    "Depends: iptables-nft, kmod-nf-nat, kmod-ipt-nat, libc, libopenssl, zlib, ca-bundle, libpthread" \
    "Section: net" \
    "Category: Network" \
    "Title: mitmweb (man-in-the-middle proxy web UI)" \
    "URL: https://mitmproxy.org/" \
    "Maintainer: mitmproxy contributors" \
    -- \
    "$bin"                                                         "/usr/lib/mitmweb/mitmweb.bin"               "0755" \
    "$PKG_ROOT/files/usr/bin/mitmweb"                              "/usr/bin/mitmweb"                            "0755" \
    "$PKG_ROOT/files/etc/config/mitmweb"                           "/etc/config/mitmweb"                         "0644" \
    "$PKG_ROOT/files/etc/init.d/mitmweb"                           "/etc/init.d/mitmweb"                         "0755" \
    "$PKG_ROOT/files/etc/hotplug.d/iface/99-mitmweb-restart"       "/etc/hotplug.d/iface/99-mitmweb-restart"     "0644" \
    "$PKG_ROOT/files/etc/logrotate.d/mitmweb"                      "/etc/logrotate.d/mitmweb"                    "0644" \
    "$PKG_ROOT/files/etc/sysctl.d/99-mitmweb.conf"                 "/etc/sysctl.d/99-mitmweb.conf"               "0644" \
    "$PKG_ROOT/files/etc/uci-defaults/99-mitmweb-acl"             "/etc/uci-defaults/99-mitmweb-acl"           "0755" \
    "$PKG_ROOT/files/etc/uci-defaults/99-mitmweb-perms"            "/etc/uci-defaults/99-mitmweb-perms"          "0755" \
    "$WORK/sentinel-etc-mitmweb/.keep"                             "/etc/mitmweb/.keep"                          "0750"

# ----------------------------------------------------------------------------
# 4. Build luci-app-mitmweb_<ver>-r1_all.ipk
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# 4. Build luci-app-mitmweb_<ver>-r1_all.ipk
# ----------------------------------------------------------------------------
# File layout (mirrors the old Package/luci-app-mitmweb/install recipe):
#   /usr/lib/lua/luci/controller/mitmweb.lua  — module entry
#   /usr/lib/lua/luci/model/cbi/mitmweb.lua    — CBI map (Status/Basic/Transparent)
#   /usr/lib/lua/luci/view/mitmweb/status.htm  — Status tab server template
#   /usr/lib/lua/luci/i18n/mitmweb.en.po       — English
#   /usr/lib/lua/luci/i18n/mitmweb.zh-cn.po    — Simplified Chinese
#   /usr/share/luci/menu.d/luci-app-mitmweb.json  — menu entry; LuCI's
#     menu subsystem scans /usr/share/luci/menu.d/*.json at startup
#     and registers each top-level node (here, "admin/services/mitmweb"
#     under Services). Without this file the LuCI left nav has no
#     way to know "MITM Proxy" should appear.
#   /usr/share/rpcd/acl.d/luci-app-mitmweb.json  — ACL group definition
#     for the `luci-app-mitmweb` group. The controller's
#     `acl_depends = { "luci-app-mitmweb" }` and the menu entry's
#     `depends.acl = [ "luci-app-mitmweb" ]` both reference it; rpcd
#     reads every *.json in /usr/share/rpcd/acl.d/ to learn the
#     available groups. The "who has access" mapping comes from
#     /etc/config/rpcd (iStoreOS-style: login section with
#     `list read '*'` grants root access to every group).
build_ipk "luci-app-mitmweb" "all" \
    "Package: luci-app-mitmweb" \
    "Version: ${VERSION}-r1" \
    "Depends: luci-base, mitmweb" \
    "Section: luci" \
    "Category: LuCI" \
    "Title: LuCI support for mitmweb" \
    "URL: https://mitmproxy.org/" \
    "Maintainer: mitmproxy contributors" \
    -- \
    "$PKG_ROOT/luasrc/controller/mitmweb.lua"         "/usr/lib/lua/luci/controller/mitmweb.lua"    "0644" \
    "$PKG_ROOT/luasrc/model/cbi/mitmweb.lua"           "/usr/lib/lua/luci/model/cbi/mitmweb.lua"      "0644" \
    "$PKG_ROOT/luasrc/view/mitmweb/status.htm"         "/usr/lib/lua/luci/view/mitmweb/status.htm"    "0644" \
    "$PKG_ROOT/po/en/mitmweb.po"                      "/usr/lib/lua/luci/i18n/mitmweb.en.po"         "0644" \
    "$PKG_ROOT/po/zh-cn/mitmweb.po"                   "/usr/lib/lua/luci/i18n/mitmweb.zh-cn.po"      "0644" \
    "$PKG_ROOT/files/usr/share/luci/menu.d/luci-app-mitmweb.json"  "/usr/share/luci/menu.d/luci-app-mitmweb.json"  "0644" \
    "$PKG_ROOT/files/usr/share/rpcd/acl.d/luci-app-mitmweb.json"   "/usr/share/rpcd/acl.d/luci-app-mitmweb.json"   "0644"

echo ">>> Done."
ls -la "$OUT"

# ----------------------------------------------------------------------------
# 4. Sanity-check the produced ipks.
# ----------------------------------------------------------------------------
# Print the format (tar magic) + member list so we can verify what
# opkg will see from CI logs without downloading the artifact.
for ipk in "$OUT"/*.ipk; do
    [[ -f "$ipk" ]] || continue
    echo
    echo "=== ipk sanity check: $(basename "$ipk") ==="
    echo "    size:    $(wc -c < "$ipk" | tr -d ' ') bytes"
    echo "    magic:   $(head -c 8 "$ipk" | od -c -An | tr -s ' ')"
    echo "    members:"
    tar tf "$ipk" 2>&1 | sed 's/^/      /'
done