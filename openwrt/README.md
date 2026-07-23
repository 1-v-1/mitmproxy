# mitmweb for OpenWrt

This directory contains everything needed to package `mitmweb` (the headless
mitmproxy web UI) as two OpenWrt ipks, plus a thin LuCI companion app for
OpenWrt-side configuration only.

## What's shipped

| Package | Files |
|---|---|
| `mitmweb` | Daemon: PyInstaller-built ELF, procd init script, UCI config, iptables rules, sysctl, logrotate, hotplug, ACL. |
| `luci-app-mitmweb` | Three-tab LuCI UI (Status / Basic / Transparent) with CA download buttons and "Regenerate CA" button. |

The LuCI UI **deliberately does not duplicate** anything that mitmweb's own web
UI handles directly: filter / intercept rules, modify_body, modify_headers,
map_local, map_remote, block_list, stickycookie, stickyauth, save_stream,
replay, scripts — all of those are managed from mitmweb's UI at
`http://<router>:<web_port>`. The LuCI tab links out to that URL on the
Status page.

What LuCI *does* expose that mitmweb's own UI does not:

- The four OpenWrt-side modes that need iptables / network integration
  (`regular`, `socks5`, `transparent`, `upstream`, `reverse`, `local`,
  `wireguard`, `dns`), with mode-specific URL/port/path fields.
- The `upstream` -> SOCKS5 mapping is not allowed by mitmproxy's parser
  (`mitmproxy/proxy/mode_specs.py` rejects `socks5://` for upstream).
- Memory-protection options (`view_max_flows`, `stream_large_bodies`,
  `body_size_limit`, `tcp_timeout`) — none of these are exposed anywhere in
  mitmweb's web UI.
- CA certificate download (PEM/P12/CER/private-key) and "Regenerate CA".
- Transparent-proxy iptables integration (LAN interface, skip CIDRs, etc.).

---

## Building

The release pipeline (`.github/workflows/openwrt.yml`) is two jobs:

1. **`musl-binary`** — runs `openwrt/tools/build-mitmweb-musl.sh` in a
   `python:3.13-alpine` Docker container to produce the stripped musl-linked
   ELF. Output: `release/dist/mitmweb-linux-musl-<arch>-<tag>.tar.xz`,
   uploaded as a GitHub Actions artifact.
2. **`openwrt-package`** — downloads the tarball artifact and runs
   `openwrt/tools/build-mitmweb-ipk.sh` directly on the runner. That script
   lays out the package files, generates the control tarball, and `ar`s
   everything into standard `.ipk` files. **No OpenWrt SDK, no
   `make defconfig`, no feeds, no `rstrip.sh`/`sstrip`** — PyInstaller's
   output is already stripped and ready to ship.

### Building locally

```sh
cd openwrt/tools

# Step 1: produce the musl tarball
./build-mitmweb-musl.sh --arch x86_64 --tag v12.0.0
#  → ../release/dist/mitmweb-linux-musl-x86_64-v12.0.0.tar.xz

# Step 2: package it as ipks
./build-mitmweb-ipk.sh \
    --tarball ../release/dist/mitmweb-linux-musl-x86_64-v12.0.0.tar.xz \
    --arch x86_64 \
    --version v12.0.0 \
    --out /tmp/mitmweb-ipks
#  → /tmp/mitmweb-ipks/mitmweb_v12.0.0-r1_x86_64.ipk
#  → /tmp/mitmweb-ipks/luci-app-mitmweb_v12.0.0-r1_all.ipk
```

The tarball layout (produced by `build-mitmweb-musl.sh`):

```
mitmweb-linux-musl-<arch>-<tag>/
    mitmweb.bin    # stripped, dynamically linked ELF (~30 MB)
    SHA256SUMS
```

---

## Installing (on the device)

```sh
opkg install /tmp/mitmweb_<ver>_<arch>.ipk
opkg install /tmp/luci-app-mitmweb_<ver>_all.ipk
```

After install:

- `mitmweb` user is created (uid 472).
- `/etc/mitmweb/` is owned by that user.
- The LuCI tab "网络 -> MITM 代理" (Network -> MITM Proxy) appears.

The service is **not** auto-started. Enable it from the Status tab or:

```sh
uci set mitmweb.main.enabled='1'
uci commit mitmweb
/etc/init.d/mitmweb enable
/etc/init.d/mitmweb start
```

The first start generates the CA bundle into `/etc/mitmweb/`:

```
mitmproxy-ca-cert.pem      # certificate only — install on clients
mitmproxy-ca.pem           # private key + cert — used by mitmproxy itself
mitmproxy-ca.p12           # PKCS12 key+cert — Windows full import
mitmproxy-ca-cert.p12      # PKCS12 cert only
mitmproxy-ca-cert.cer      # same cert, .cer extension (Android)
mitmproxy-dhparam.pem      # DH params (internal)
```

Validity of those certificates (see `mitmproxy/certs.py:40-44`):

| Cert kind | Validity |
|---|---|
| mitmproxy CA (root) | **10 years + 2 days** |
| Per-domain leaf certs (auto-signed) | 199 days (auto-renewed) |
| CRL | 7 days |

---

## Common workflows

### Transparent HTTPS inspection

1. LuCI -> MITM 代理 -> 基础:mode = `transparent`, Save.
2. 透明代理 tab: leave defaults (LAN interface `br-lan`, intercept HTTP and
   HTTPS).
3. Save & Apply on the 基础 tab -> `/etc/init.d/mitmweb reload`.
4. iptables rule is now: any TCP to/from LAN port 80 or 443 goes to mitmweb's
   port 8080.
5. Status tab -> Download PEM certificate. Install `mitmproxy-ca-cert.pem`
   on every client that should trust mitmproxy:
   - **Linux**: copy to `/usr/local/share/ca-certificates/mitm.crt` and run
     `sudo update-ca-certificates`.
   - **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k
     /Library/Keychains/System.keychain mitmproxy-ca-cert.pem`.
   - **Windows**: download the P12 and double-click.
   - **iOS**: download the PEM and install via Settings -> General ->
     VPN & Device Management.
   - **Android**: download CER and install via Settings -> Security ->
     Encryption & credentials -> Install a certificate.
6. Point the client's gateway / HTTP proxy settings at the router. Traffic is
   now visible in mitmweb's UI at `http://<router>:<web_port>`.

### SOCKS5 server

mode = `socks5` -> mitmweb listens on port 1080 by default. Configure your
client to use `<router>:1080` as a SOCKS5 proxy.

### Chain through an upstream HTTP proxy

mode = `upstream` + `upstream_parent_url = http://corp-proxy:3128`. Clients
point at mitmweb; mitmweb forwards to the corporate proxy. **HTTPS-only**:
mitmproxy's upstream mode rejects SOCKS / non-HTTP schemes (see
`mitmproxy/proxy/mode_specs.py:218`).

### Reverse proxy / dev tunnel

mode = `reverse` + `reverse_target = http://backend.lan:80`. Add an entry on
your DNS server / `/etc/hosts` (on every client) pointing the public hostname
at the router. Every request to that hostname is captured.

---

## File map

```
openwrt/
├── README.md                     # This file
├── LICENSE                       # MIT
├── files/
│   ├── etc/
│   │   ├── config/mitmweb        # UCI defaults (single 'main' section)
│   │   ├── init.d/mitmweb        # procd init script
│   │   ├── hotplug.d/iface/99-mitmweb-restart
│   │   ├── logrotate.d/mitmweb
│   │   ├── rpcd/acl.d/50-mitmweb.json
│   │   ├── sysctl.d/99-mitmweb.conf  # net.ipv4.ip_forward=1
│   │   └── uci-defaults/99-mitmweb-perms
│   └── usr/bin/mitmweb           # HOME wrapper
├── luasrc/
│   ├── controller/mitmweb.lua    # LuCI entry, leaf handlers
│   ├── model/cbi/mitmweb.lua     # CBI map (3 sections)
│   └── view/mitmweb/status.htm   # Status tab server template
├── po/
│   ├── en/mitmweb.po             # English (no-op)
│   └── zh-cn/mitmweb.po          # 简体中文
└── tools/
    ├── build-mitmweb-musl.sh     # PyInstaller-in-Docker build helper
    └── build-mitmweb-ipk.sh      # ipk assembler (runs on the CI runner)
```

---

## Known limits

- **Only `mitmweb`** is shipped. The console `mitmproxy` and `mitmdump` are
  not in the ipk. Run the upstream Docker image if you need them.
- **Requires OpenWrt ≥ 24.10** (the bundled CPython 3.13 binary uses
  `pwritev2`, which OpenWrt 23.05's musl 1.2.4 doesn't export; on boot
  the binary aborts with `Error relocating ... pwritev2: symbol not
  found`). OpenWrt 24.10 ships musl 1.2.5; 23.05 will not work even
  with all dependencies satisfied.
- **Transparent HTTPS interception needs every LAN client to trust the
  mitmproxy CA.** Until they do, clients see `ERR_CERT_AUTHORITY_INVALID`.
- **procd only** — no systemd / SysV init compatibility.
- **PyInstaller binary is ~30-50 MB**, installed at `/usr/lib/mitmweb/`.
- **Rust extension `mitmproxy_rs` is bundled** inside the PyInstaller ELF,
  so the OpenWrt device needs no Rust toolchain.
- **`upstream` mode is HTTP(S) only.** SOCKS5-as-upstream is rejected by
  mitmproxy itself (`mitmproxy/proxy/mode_specs.py:218`).
- **Per-domain leaf certificates auto-renew every 199 days** — users don't
  have to do anything, but if you've keyed mtls for a specific leaf cert
  externally, you may want to extend that timer.

---

## Verifying

### Binary

```sh
ldd mitmweb-linux-musl-x86_64-*.bin
#  Expected: libc.musl-x86_64.so.1, libcrypto.so.3, libssl.so.3

./mitmweb-linux-musl-x86_64-*.bin --version
#  Expected: mitmproxy X.Y.Z

./mitmweb-linux-musl-x86_64-*.bin --help 2>&1 | head -5
#  Expected: usage line, lists --set, --mode, etc.
```

### Package

```sh
ls /tmp/mitmweb-ipks/
#  mitmweb_v12.0.0-r1_x86_64.ipk
#  luci-app-mitmweb_v12.0.0-r1_all.ipk
```

### On a device / VM

```sh
opkg install /tmp/mitmweb_*.ipk /tmp/luci-app-mitmweb_*.ipk

uci set mitmweb.main.enabled='1'
uci commit mitmweb
/etc/init.d/mitmweb enable
/etc/init.d/mitmweb start

pgrep -f mitmweb.bin
#  Expected: a PID

tail /var/log/mitmweb.log
#  Expected: "Web server listening at http://0.0.0.0:8081/" within ~5s

ls /etc/mitmweb/
#  Expected: mitmproxy-ca.pem + 5 other files
```

Transparent:

```sh
uci set mitmweb.main.mode='transparent'
/etc/init.d/mitmweb restart
iptables -t nat -L PREROUTING -n --line-numbers
#  First line: "-i br-lan -p tcp -j MITMWEB"
iptables -t nat -L MITMWEB -n
#  HTTP and HTTPS REDIRECT entries present
```

From a LAN client (with the router as gateway), `curl https://example.com`
should now succeed *after* the client trusts `/etc/mitmweb/mitmproxy-ca-cert.pem`.

### LuCI

Open `http://<router>/cgi-bin/luci/admin/services/mitmweb/status` in a
browser. Expect:

- Running/Stopped pill reflecting `pgrep -f mitmweb.bin`.
- Start/Stop/Restart/Enable/Disable buttons under "Control".
- CA fingerprint / Subject / dates.
- Four download links for PEM/P12/CER/private-key.
- A red "Regenerate CA" button (with a confirm dialog).
- 30-line tail of `/var/log/mitmweb.log`, refreshed every 5 s.
