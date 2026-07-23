-- /usr/lib/lua/luci/controller/mitmweb.lua
--
-- Entry-point for the LuCI "MITM Proxy" page. Each leaf is an
-- `entry(...).leaf = true` action routed through ubus. Uses `entry()`
-- (not `page()`) because the latter is a Lua-dispatcher convenience
-- that iStoreOS / OpenWrt 24+ ucode runtime doesn't expose — calling
-- `page()` from a controller invoked through ucodebridge.lua fails
-- with "attempt to call global 'page' (a nil value)" and the whole
-- web UI 500s. `entry()` has identical semantics for our purpose
-- (path + target + title + order) and works on both Lua and ucode
-- runtimes.

module("luci.controller.mitmweb", package.seeall)

local function has_uci()
    return require("nixio.fs").access("/etc/config/mitmweb")
end

function index()
    if not has_uci() then
        return
    end

    local root = entry({"admin", "services", "mitmweb"}, firstchild(), _("MITM Proxy"), 60)
    root.acl_depends = { "luci-app-mitmweb" }

    -- The first three entries are the actual menu sub-tabs (cbi model);
    -- the remaining five are leaf actions hit by the Status tab's XHR
    -- and the cert / start-stop / regen-CA buttons. With firstchild()
    -- the parent path /admin/services/mitmweb renders the first cbi
    -- sub-entry (status) so the menu JSON's `view` action still
    -- works, while the full paths below keep routing to their own
    -- targets instead of being shadowed by the parent.
    entry({"admin", "services", "mitmweb", "status"},      cbi("mitmweb"), _("Status"),              1).acl_depends = { "luci-app-mitmweb" }
    entry({"admin", "services", "mitmweb", "basic"},       cbi("mitmweb"), _("Basic Settings"),      2).acl_depends = { "luci-app-mitmweb" }
    entry({"admin", "services", "mitmweb", "transparent"}, cbi("mitmweb"), _("Transparent Proxy"),   3).acl_depends = { "luci-app-mitmweb" }
    entry({"admin", "services", "mitmweb", "yaml"},        cbi("mitmweb"), _("YAML Config"),        4).acl_depends = { "luci-app-mitmweb" }

    entry({"admin", "services", "mitmweb", "status_json"}, call("action_status")).leaf   = true
    entry({"admin", "services", "mitmweb", "cert"},        call("action_cert")).leaf     = true
    entry({"admin", "services", "mitmweb", "logtail"},     call("action_logtail")).leaf  = true
    entry({"admin", "services", "mitmweb", "control"},     call("action_control")).leaf  = true
    entry({"admin", "services", "mitmweb", "regen_ca"},    call("action_regen_ca")).leaf = true
end

-- ---------------------------------------------------------------------------
-- Leaf handlers: all return JSON via luci.http.write_json() or stream files.
-- ---------------------------------------------------------------------------

local function uci_cursor()
    return require("luci.model.uci").cursor()
end

local function syscall(cmd)
    return require("luci.sys").exec(cmd) or ""
end

local function uci_or_default(cur, opt, default)
    local v = cur:get("mitmweb", "main", opt)
    if v == nil or v == "" or v == "nil" then return default end
    return v
end

local function running_pids()
    local out = syscall("pgrep -f 'mitmweb.bin' 2>/dev/null")
    local pids = {}
    for pid in (out or ""):gmatch("%S+") do pids[#pids + 1] = pid end
    return pids
end

local function web_url(cur)
    local host = uci_or_default(cur, "web_host", "0.0.0.0")
    if host == "" or host == "0.0.0.0" then
        host = require("luci.util").trim(syscall("uci -q get network.lan.ipaddr | head -n1"))
        if host == "" or host == nil then host = "192.168.1.1" end
    end
    local port = uci_or_default(cur, "web_port", "8081")
    return string.format("http://%s:%s", host, port)
end

function action_status()
    local cur = uci_cursor()
    -- `mode` is a list-type option (one entry per --mode flag), so
    -- `cur:get(...)` returns nil — use get_list() and join with spaces
    -- (mitmweb's behaviour for MultiValue: --mode can repeat).
    local mode_list = cur:get_list("mitmweb", "main", "mode") or {}
    local mode_str = table.concat(mode_list, " ")

    local pids = running_pids()

    local confdir = uci_or_default(cur, "confdir", "/etc/mitmweb")
    local log_tail = syscall("tail -n 30 /var/log/mitmweb.log 2>/dev/null")

    -- CA info: read the first cert and extract subject/dates via openssl.
    local cert = confdir .. "/mitmproxy-ca-cert.pem"
    local ca_info = nil
    local nixio = require("nixio.fs")
    if nixio.access(cert) then
        local openssl = syscall(
            "openssl x509 -in " .. cert ..
            " -noout -subject -issuer -dates -serial -fingerprint -sha256 2>/dev/null"
        )
        ca_info = { exists = true, raw = openssl }
    else
        ca_info = { exists = false }
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        running   = #pids > 0,
        pids      = pids,
        mode      = mode_str,
        web_url   = web_url(cur),
        confdir   = confdir,
        ca_info   = ca_info,
        log_tail  = log_tail,
        version   = require("luci.version").lucirpc or nil,
    })
end

function action_cert(fmt)
    local cur = uci_cursor()
    local confdir = uci_or_default(cur, "confdir", "/etc/mitmweb")

    local files = {
        pem = "mitmproxy-ca-cert.pem",
        p12 = "mitmproxy-ca-cert.p12",
        cer = "mitmproxy-ca-cert.cer",
        key = "mitmproxy-ca.pem",
    }

    local mime = {
        pem = "application/x-pem-file",
        p12 = "application/x-pkcs12",
        cer = "application/x-x509-ca-cert",
        key = "application/x-pem-file",
    }

    local download_name = {
        pem = "mitmproxy-ca-cert.pem",
        p12 = "mitmproxy-ca-cert.p12",
        cer = "mitmproxy-ca-cert.cer",
        key = "mitmproxy-ca-private-key.pem",
    }

    -- The Status tab's download buttons link to
    -- `/admin/services/mitmweb/cert?fmt=pem|p12|cer|key` — that's a
    -- QUERY-string `fmt`, not a path segment. `action_cert(fmt)` makes
    -- `fmt` a *path* parameter, which is nil here, so every download
    -- silently fell back to PEM. Read it from formvalue() (which
    -- covers both POST body and GET query string) instead. The path
    -- argument is left as a fallback so `/cert/p12` still works if
    -- anyone hand-types it.
    fmt = fmt or luci.http.formvalue("fmt") or "pem"
    local fname = files[fmt]
    if not fname then
        luci.http.status(400, "unknown fmt")
        return
    end

    local path = confdir .. "/" .. fname
    local nixio = require("nixio.fs")
    if not nixio.access(path) then
        luci.http.status(404, "CA not generated yet")
        luci.http.write("CA not generated yet — start the service first, then refresh this page.\n")
        return
    end

    luci.http.header("Content-Type", mime[fmt] or "application/octet-stream")
    luci.http.header("Content-Disposition",
        'attachment; filename="' .. download_name[fmt] .. '"')
    luci.http.write(nixio.readfile(path) or "")
end

function action_logtail()
    luci.http.prepare_content("text/plain")
    luci.http.write(syscall("tail -n 200 /var/log/mitmweb.log 2>/dev/null"))
end

function action_control(cmd)
    local sys = require("luci.sys")
    -- The Status tab's Start/Stop/Restart/Enable/Disable buttons POST to
    -- `/admin/services/mitmweb/control?cmd=start` — that's a
    -- QUERY-string `cmd`, not a path segment. `action_control(cmd)` makes
    -- `cmd` a *path* parameter, which is nil here, so every button
    -- silently fell through the if-elseif chain (cmd defaulted to
    -- "status", which matches none of the cases) and did literally
    -- nothing. Read it from formvalue() (which covers both POST body
    -- and GET query string) instead. The path argument is left as a
    -- fallback so `/control/start` still works if anyone hand-types it.
    cmd = cmd or luci.http.formvalue("cmd") or "status"
    local ok = false
    if     cmd == "start"   then ok = sys.call("/etc/init.d/mitmweb start")   == 0
    elseif cmd == "stop"    then ok = sys.call("/etc/init.d/mitmweb stop")    == 0
    elseif cmd == "restart" then ok = sys.call("/etc/init.d/mitmweb restart") == 0
    elseif cmd == "enable"  then ok = sys.call("/etc/init.d/mitmweb enable")  == 0
    elseif cmd == "disable" then ok = sys.call("/etc/init.d/mitmweb disable") == 0
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = ok, cmd = cmd })
end

function action_regen_ca()
    local nixio = require("nixio.fs")
    local sys   = require("luci.sys")
    local cur   = uci_cursor()
    local confdir = uci_or_default(cur, "confdir", "/etc/mitmweb")

    -- Capture old SHA-256 if present.
    local old_cert = confdir .. "/mitmproxy-ca-cert.pem"
    local old_sha = nil
    if nixio.access(old_cert) then
        old_sha = (syscall(
            "openssl x509 -in " .. old_cert .. " -noout -fingerprint -sha256 2>/dev/null"
        ):match("fingerprint=(.+)") or ""):gsub("%s+", ""):lower()
    end

    sys.call("/etc/init.d/mitmweb stop >/dev/null 2>&1")
    sys.call("rm -f /etc/mitmweb/mitmproxy-ca* /etc/ssl/certs/mitmproxy-ca-cert.pem 2>/dev/null")
    sys.call("/etc/init.d/mitmweb start >/dev/null 2>&1")

    -- Wait briefly for the new CA to be generated.
    for _ = 1, 20 do
        if nixio.access(old_cert) then break end
        require("luci.sys").call("sleep 0.2")
    end

    local new_sha = nil
    if nixio.access(old_cert) then
        new_sha = (syscall(
            "openssl x509 -in " .. old_cert .. " -noout -fingerprint -sha256 2>/dev/null"
        ):match("fingerprint=(.+)") or ""):gsub("%s+", ""):lower()
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({ old_sha = old_sha, new_sha = new_sha })
end
