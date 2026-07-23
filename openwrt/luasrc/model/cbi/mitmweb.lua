-- /usr/lib/lua/luci/model/cbi/mitmweb.lua
--
-- CBI model for mitmweb. Single TypedSection "main" with three tabs.
-- Status tab pulls data via XHR from /admin/services/mitmweb/status_json.
-- Basic tab exposes every UCI option in the config file.
-- Transparent tab is mode-gated (only visible when mode includes "transparent").

local m, s, o

m = Map("mitmweb", translate("MITM Proxy"),
        translate("OpenWrt-side controls for the mitmweb daemon: ports, mode, transparent-proxy iptables, and CA certificate management. For filters, intercept rules, modify_*, map_*, block list, replay, etc. use mitmweb's own web UI at the URL shown on the Status tab."))
m:chain("luci")

-- ===========================================================================
-- Status section: anonymous + custom template. Renders the HTML
-- fragment at view/mitmweb/status.htm which XHR-fetches
-- /admin/services/mitmweb/status_json. With `anonymous = true` LuCI
-- shows only the template (no form fields here — the actual
-- settings live in the Basic Settings section below).
-- ===========================================================================
local s_status = m:section(TypedSection, "main", translate("Status"))
s_status.anonymous = true
s_status.addremove = false

local o = s_status:option(Value, "_status", translate(" "))
o.rmempty = true
o.template = "mitmweb/status"

-- ===========================================================================
-- Basic Settings section: NOT anonymous. All actual UCI options live
-- here. `anonymous` would hide the section header AND every field
-- (it forces "no config" mode for read-only display sections like
-- Status), so we deliberately do NOT set it on this section.
-- ===========================================================================
local s_basic = m:section(TypedSection, "main", translate("Basic Settings"),
    translate("Mode, ports, web UI, TLS, lifecycle, and runtime tuning. Anything you set here becomes a mitmproxy CLI flag at next start."))

--    --mode is MultiValue in UCI; mitmproxy supports multiple --mode flags.
o = s_basic:option(ListValue, "mode", translate("Proxy mode"),
             translate("Choose one or more. mitmweb will start one server per selected mode."))
o:value("regular",    translate("Regular HTTP(S) proxy (port 8080)"))
o:value("socks5",     translate("SOCKS5 proxy (port 1080)"))
o:value("transparent", translate("Transparent (NAT redirect; see Transparent tab)"))
o:value("upstream",   translate("Upstream HTTP(S) parent proxy"))
o:value("reverse",    translate("Reverse proxy"))
o:value("local",      translate("Local loopback capture"))
o:value("wireguard",  translate("WireGuard tunnel"))
o:value("dns",        translate("DNS server (port 53)"))

o = s_basic:option(Value, "regular_listen_port", translate("Regular proxy port"))
o.datatype = "port"
o.default  = 8080
o:depends("mode", "regular")

o = s_basic:option(Value, "socks5_listen_port", translate("SOCKS5 proxy port"))
o.datatype = "port"
o.default  = 1080
o:depends("mode", "socks5")

o = s_basic:option(Value, "upstream_parent_url", translate("Upstream parent URL"),
             translate("Required if mode contains 'upstream'. Only http:// or https:// allowed — SOCKS5 not supported."))
o.default  = ""
o:depends("mode", "upstream")

o = s_basic:option(Value, "reverse_target", translate("Reverse proxy target URL"),
             translate("Required if mode contains 'reverse'. e.g. http://10.0.0.5:80"))
o.default  = ""
o:depends("mode", "reverse")

o = s_basic:option(Value, "wireguard_path", translate("WireGuard key file path"),
             translate("Required if mode contains 'wireguard'."))
o.default  = ""
o:depends("mode", "wireguard")

o = s_basic:option(Value, "dns_listen_port", translate("DNS server port"))
o.datatype = "port"
o.default  = 53
o:depends("mode", "dns")

o = s_basic:option(TextValue, "mode_custom_extra",
             translate("Custom --mode specs (advanced)"),
             translate("Each non-empty, non-comment line becomes an extra --mode flag. For example: tun:utun3, reverse:https://example.com@127.0.0.1:443"))
o.rows = 4
o.default = ""

-- Separator
o = s_basic:option(DummyValue, "_sep_bindings", " ")
o.template = "cbi/simpleform_section"

o = s_basic:option(Value, "listen_host", translate("Global listen address (default for all modes)"),
             translate("Leave empty to bind on all interfaces. Ignored if a per-mode port override is set."))
o.datatype = "ipaddr"
o.default  = ""

o = s_basic:option(Value, "listen_port", translate("Global listen port"))
o.datatype = "port"
o.default  = 8080

-- ---------------------------------------------------------------------------
-- Web UI
-- ---------------------------------------------------------------------------
o = s_basic:option(Value, "web_host", translate("mitmweb Web UI bind address"),
             translate("0.0.0.0 lets the LuCI tab link out to a LAN-reachable URL. 127.0.0.1 (mitmweb default) is unreachable from another device."))
o.datatype = "ipaddr"
o.default  = "0.0.0.0"

o = s_basic:option(Value, "web_port", translate("mitmweb Web UI port"))
o.datatype = "port"
o.default  = 8081

o = s_basic:option(Value, "web_password", translate("mitmweb Web UI password (optional)"),
             translate("Plain text or argon2id hash (starting with $argon2...). Empty = mitmweb generates a random token printed to the log on first start."))
o.password = true
o.default  = ""

o = s_basic:option(Flag, "web_debug", translate("Verbose debug logging"))
o.default  = 0

o = s_basic:option(Flag, "web_open_browser", translate("Open browser on start"),
             translate("Leave disabled on a router — there is typically no GUI browser."))
o.default  = 0

-- ---------------------------------------------------------------------------
-- TLS
-- ---------------------------------------------------------------------------
o = s_basic:option(Flag, "ssl_insecure", translate("Skip upstream certificate validation"),
             translate("WARNING: disables TLS validation against the upstream server. Only enable on a private, trusted network."))
o.default  = 0

o = s_basic:option(Flag, "trust_ca_system", translate("Also install CA into /etc/ssl/certs"),
             translate("Installs mitmproxy-ca-cert.pem into the router's system trust store. Required if you want any HTTPS traffic originating from the router itself (opkg, LuCI) to flow through mitmproxy."))
o.default  = 0

-- ---------------------------------------------------------------------------
-- Service / memory protection
-- ---------------------------------------------------------------------------
o = s_basic:option(Flag, "enabled", translate("Start on boot"))
o.default  = 0

o = s_basic:option(Flag, "server", translate("Run as proxy server"))
o.default  = 1

o = s_basic:option(Value, "confdir", translate("Configuration &amp; CA directory"))
o.default  = "/etc/mitmweb"

o = s_basic:option(Value, "view_max_flows", translate("Max flows kept in memory"),
             translate("FIFO cap — oldest flows evict first. Recommended: 64MB RAM → 500, 128MB → 1000, 256MB+ → 5000. 0 or empty = unlimited (will OOM on a small router)."))
o.datatype = "uinteger"
o.default  = 1000

o = s_basic:option(Value, "stream_large_bodies", translate("Stream large bodies to disk"),
             translate("Requests/responses larger than this get streamed instead of buffered. e.g. '1m'. Empty = disabled."))
o.default  = "1m"

o = s_basic:option(Value, "body_size_limit", translate("Body size memory limit"),
             translate("Reject bodies larger than this. e.g. '10m'. Empty = unlimited."))
o.default  = "10m"

o = s_basic:option(Value, "tcp_timeout", translate("Idle TCP timeout (seconds)"),
             translate("Close connections idle longer than this. Default in upstream is 600; OpenWrt devices usually want 60-120 to free socket memory."))
o.datatype = "uinteger"
o.default  = 120

-- ---------------------------------------------------------------------------
-- Pass-through escape hatches
-- ---------------------------------------------------------------------------
o = s_basic:option(TextValue, "extra_set",
             translate("Extra --set options (advanced)"),
             translate("One k=v per line; each becomes --set on the CLI. Useful for setting options this UI does not expose yet."))
o.rows = 5
o.default = ""

o = s_basic:option(Value, "extra_args", translate("Extra CLI args (advanced, verbatim)"))
o.default  = ""

-- ===========================================================================
-- Transparent Proxy section: anonymous + mode-gated. Description-only
-- when mode != "transparent", full form when it is.
-- ===========================================================================
local s2 = m:section(TypedSection, "main", translate("Transparent Proxy"),
               translate("Only effective when 'transparent' is one of the modes in the Basic tab. Sets up iptables nat:MITMWEB chain to REDIRECT TCP:80 and TCP:443."))
s2.anonymous = true
s2.addremove = false

o = s2:option(Value, "transparent_lan_iface", translate("LAN interface"))
o.default = "br-lan"
o:depends("mode", "transparent")

o = s2:option(Flag, "transparent_intercept_http", translate("Intercept HTTP (port 80)"))
o.default = 1
o:depends("mode", "transparent")

o = s2:option(Flag, "transparent_intercept_https", translate("Intercept HTTPS (port 443)"))
o.default = 1
o:depends("mode", "transparent")

o = s2:option(Value, "transparent_http_port", translate("HTTP redirect target port"))
o.datatype = "port"
o.default = 80
o:depends("mode", "transparent")

o = s2:option(Value, "transparent_https_port", translate("HTTPS redirect target port"))
o.datatype = "port"
o.default = 443
o:depends("mode", "transparent")

o = s2:option(TextValue, "transparent_skip_subnets",
              translate("Skip redirection (CIDRs)"),
              translate("One CIDR per line; traffic from these sources is not REDIRECTed. Loopback (127.0.0.0/8) and the router's own LAN IP are always skipped."))
o.rows = 4
o.default = ""
o:depends("mode", "transparent")

o = s2:option(TextValue, "transparent_skip_hosts",
              translate("Hosts to ignore (regex)"),
              translate("One regex per line; mitmproxy itself will not intercept traffic to matching hosts. e.g. apple.com, .*\\.google-analytics\\.com, 10\\.0\\.0\\.0/8"))
o.rows = 5
o.default = ""
o:depends("mode", "transparent")

-- ---------------------------------------------------------------------------
-- Apply button: save UCI + reload init.d (save() handler runs after the
-- CBI form commits).
-- ---------------------------------------------------------------------------
function m.on_after_commit(self)
    require("luci.sys").call("/etc/init.d/mitmweb reload >/dev/null 2>&1")
end

return m
