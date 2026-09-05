#!/bin/bash
# ==============================================================================
# Script Name   : RareTriccks Multi-Protocol VPN Panel (Direct SSL & Split Menus)
# Ports         : 80 (Plain), 443 (Direct SSL & Nginx SNI Multiplexing), 7300 (BadVPN UDPGW)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PANEL_NAME="RareTriccks VPN Panel (Direct SSL Edition)"
PANEL_VERSION="2026-09-05-direct-ssl"
BANNER_FILE="/etc/issue.net"
DOMAIN_FILE="/etc/raretriccks/domain.conf"
WILDCARD_FILE="/etc/raretriccks/wildcard.conf"
USERS_DIR="/etc/raretriccks/users"
V2USERS_DIR="/etc/raretriccks/v2users"
NGINX_CONF="/etc/nginx/conf.d/raretriccks.conf"
NGINX_STREAM_CONF="/etc/nginx/conf.d/raretriccks_stream.conf"
XRAY_ACCESS_LOG="/var/log/xray/access.log"
XRAY_API_ADDR="127.0.0.1:10085"
SLOWDNS_DIR="/etc/slowdns"
SLOWDNS_PRIVKEY="${SLOWDNS_DIR}/server.key"
SLOWDNS_PUBKEY="${SLOWDNS_DIR}/server.pub"
SLOWDNS_NS_FILE="${SLOWDNS_DIR}/ns_domain.conf"
SLOWDNS_BIN="/usr/local/bin/dns-server"
SLOWDNS_UDP_PORT=53
SLOWDNS_FORWARD_HOST="127.0.0.1"
SLOWDNS_FORWARD_PORT=109

WS_SSH_PORT=2082          
XRAY_WS_TLS_PORT=20001    
XRAY_WS_PLAIN_PORT=20002  
XRAY_GRPC_PORT=20005
XRAY_XHTTP_PORT=8443
XRAY_TCP_PLAIN_PORT=8880
XRAY_TCP_TLS_PORT=8444
BADVPN_PORT=7300

V2RAY_WS_PATH="/v2ray"
V2RAY_XHTTP_PATH="/vless-xhttp"
V2RAY_GRPC_SERVICE="vless-grpc"

XRAY_CERT_DIR="/etc/xray/certs"
XRAY_CERT_FILE="${XRAY_CERT_DIR}/fullchain.pem"
XRAY_KEY_FILE="${XRAY_CERT_DIR}/privkey.pem"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] Yeh script ROOT privilege ke sath chalaen! (sudo -i)${NC}"
   exit 1
fi

mesg n 2>/dev/null
true

get_domain() {
    if [[ -f "$DOMAIN_FILE" ]]; then
        cat "$DOMAIN_FILE" | tr -d '\r\n'
    else
        echo "No Domain Set"
    fi
}

get_cert_domain() {
    if [[ -s "$WILDCARD_FILE" ]]; then
        cat "$WILDCARD_FILE" | tr -d '\r\n'
    else
        get_domain
    fi
}

press_any_key() {
    echo -e "\n${YELLOW}Press [ENTER] key to return...${NC}"
    read -r
}

wait_for_port() {
    local host="$1"
    local port="$2"
    local label="$3"
    local timeout="${4:-15}"
    local waited=0

    while ! (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; do
        sleep 1
        waited=$((waited+1))
        if [[ $waited -ge $timeout ]]; then
            echo -e "${RED}[WARN] ${label} (${host}:${port}) did not come up after ${timeout}s${NC}" >&2
            return 1
        fi
    done
    exec 3>&- 2>/dev/null
    echo -e "${GREEN}[OK] ${label} listening on ${host}:${port}${NC}" >&2
    return 0
}

install_badvpn_udpgw() {
    echo -e "${BLUE}[+] Installing & Auto-Starting BadVPN UDP Gateway for Gaming & Calls...${NC}"
    if [[ ! -f /usr/local/bin/badvpn-udpgw ]]; then
        wget -O /usr/local/bin/badvpn-udpgw https://github.com/ambrop72/badvpn/raw/master/udpgw/badvpn-udpgw 2>/dev/null || true
        if [[ ! -f /usr/local/bin/badvpn-udpgw ]]; then
            apt install -y cmake build-essential libssl-dev git &>/dev/null || true
            if [[ ! -d /tmp/badvpn ]]; then
                git clone https://github.com/ambrop72/badvpn.git /tmp/badvpn &>/dev/null || true
            fi
            if [[ -d /tmp/badvpn ]]; then
                mkdir -p /tmp/badvpn/build
                cd /tmp/badvpn/build
                cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 &>/dev/null
                make install &>/dev/null || true
                cd ~
            fi
        fi
    fi

    if [[ -f /usr/local/bin/badvpn-udpgw ]]; then
        chmod +x /usr/local/bin/badvpn-udpgw
    fi

cat << 'EOF' > /etc/systemd/system/badvpn.service
[Unit]
Description=BadVPN UDP Gateway for Gaming & Voice Calls
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections 2000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable badvpn
    systemctl restart badvpn
    wait_for_port 127.0.0.1 7300 "BadVPN UDPGW (7300)" 5 || true
}

fix_dropbear_core() {
    mkdir -p /etc/dropbear
    chmod 700 /etc/dropbear

    grep -qxF "/bin/bash" /etc/shells || echo "/bin/bash" >> /etc/shells
    grep -qxF "/usr/sbin/nologin" /etc/shells || echo "/usr/sbin/nologin" >> /etc/shells

    if [[ ! -f /etc/dropbear/dropbear_rsa_host_key ]]; then
        dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key &>/dev/null
    fi
    if [[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]]; then
        dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key &>/dev/null
    fi
    if [[ ! -f /etc/dropbear/dropbear_ed25519_host_key ]]; then
        dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key &>/dev/null
    fi

    chmod 600 /etc/dropbear/*_host_key 2>/dev/null
    rm -rf /etc/systemd/system/dropbear.service.d

cat << 'EOF' > /etc/default/dropbear
NO_START=0
DROPBEAR_PORT=22
DROPBEAR_EXTRA_ARGS="-p 109 -p 447 -p 443 -b /etc/issue.net"
DROPBEAR_BANNER="/etc/issue.net"
DROPBEAR_RECEIVE_WINDOW=65536
EOF

    systemctl daemon-reload
    systemctl enable dropbear
    systemctl restart dropbear
    wait_for_port 127.0.0.1 109 "Dropbear (109)" 10
}

get_ns_domain() {
    if [[ -s "$SLOWDNS_NS_FILE" ]]; then
        cat "$SLOWDNS_NS_FILE" | tr -d '\r\n'
    else
        echo ""
    fi
}

free_port_53() {
    if ss -uln 2>/dev/null | grep -q ':53 '; then
        if systemctl is-active systemd-resolved &>/dev/null; then
            mkdir -p /etc/systemd/resolved.conf.d
            if grep -q '^DNSStubListener=' /etc/systemd/resolved.conf 2>/dev/null; then
                sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
            else
                echo 'DNSStubListener=no' >> /etc/systemd/resolved.conf
            fi
            systemctl restart systemd-resolved 2>/dev/null
            sleep 1
            rm -f /etc/resolv.conf
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        fi
    fi

    for svc in named bind9 dnsmasq; do
        systemctl is-active "$svc" &>/dev/null && systemctl stop "$svc" 2>/dev/null && systemctl disable "$svc" 2>/dev/null
    done
}

install_slowdns_binary() {
    [[ -x "$SLOWDNS_BIN" ]] && return 0
    echo -e "${BLUE}[+] Installing SlowDNS (dnstt-server) binary...${NC}"
    apt install -y golang-go git build-essential &>/dev/null
    export GIT_TERMINAL_PROMPT=0
    rm -rf /tmp/dnstt-src

    if ! git clone https://www.bamsoftware.com/git/dnstt.git /tmp/dnstt-src &>/tmp/slowdns_clone.log; then
        echo -e "${RED}[ERROR] dnstt source clone fail ho gaya.${NC}"
        cat /tmp/slowdns_clone.log
        return 1
    fi

    (
        cd /tmp/dnstt-src/dnstt-server || exit 1
        go build -o "$SLOWDNS_BIN" . 2>/tmp/slowdns_build.log
    )

    if [[ ! -x "$SLOWDNS_BIN" ]]; then
        echo -e "${RED}[ERROR] SlowDNS binary build nahi ho saka.${NC}"
        cat /tmp/slowdns_build.log 2>/dev/null
        return 1
    fi
    chmod +x "$SLOWDNS_BIN"
    return 0
}

slowdns_generate_keys() {
    mkdir -p "$SLOWDNS_DIR"
    if [[ ! -f "$SLOWDNS_PRIVKEY" || ! -f "$SLOWDNS_PUBKEY" ]]; then
        "$SLOWDNS_BIN" -gen-key -privkey-file "$SLOWDNS_PRIVKEY" -pubkey-file "$SLOWDNS_PUBKEY" &>/tmp/slowdns_keygen.log
    fi
    if [[ ! -f "$SLOWDNS_PRIVKEY" || ! -f "$SLOWDNS_PUBKEY" ]]; then
        echo -e "${RED}[ERROR] SlowDNS keypair generate nahi ho saka.${NC}"
        cat /tmp/slowdns_keygen.log 2>/dev/null
        return 1
    fi
    chmod 600 "$SLOWDNS_PRIVKEY"
    chmod 644 "$SLOWDNS_PUBKEY"
    return 0
}

configure_slowdns_service() {
    local ns_dom
    ns_dom=$(get_ns_domain)
    if [[ -z "$ns_dom" ]]; then
        echo -e "${RED}[ERROR] NS Domain set nahi hai.${NC}"
        return 1
    fi

    free_port_53

cat << SD_EOF > /etc/systemd/system/slowdns.service
[Unit]
Description=SlowDNS (SSH over DNS) Tunnel Server
After=network.target dropbear.service

[Service]
ExecStart=${SLOWDNS_BIN} -udp :${SLOWDNS_UDP_PORT} -privkey-file ${SLOWDNS_PRIVKEY} ${ns_dom} ${SLOWDNS_FORWARD_HOST}:${SLOWDNS_FORWARD_PORT}
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SD_EOF

    systemctl daemon-reload
    systemctl enable slowdns &>/dev/null
    systemctl restart slowdns

    sleep 2
    if ss -uln 2>/dev/null | grep -q ":${SLOWDNS_UDP_PORT} "; then
        echo -e "${GREEN}[OK] SlowDNS UDP/${SLOWDNS_UDP_PORT} active.${NC}"
    else
        echo -e "${RED}[WARN] SlowDNS port ${SLOWDNS_UDP_PORT} par active nahi hai.${NC}"
    fi
}

install_slowdns() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}          SLOWDNS INSTALL / CONFIGURE              ${NC}"
    echo -e "${CYAN}====================================================${NC}"

    if [[ -z "$(get_ns_domain)" ]]; then
        slowdns_set_ns_domain_flow
    fi

    if ! install_slowdns_binary; then press_any_key; return 1; fi
    if ! slowdns_generate_keys; then press_any_key; return 1; fi

    configure_slowdns_service
    echo -e "${GREEN}[SUCCESS] SlowDNS install complete.${NC}"
    press_any_key
}

slowdns_set_ns_domain_flow() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}          SET / CHANGE NS DOMAIN                   ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    read -rp "NS Subdomain enter karein (e.g. ns.yourdomain.com): " ns_input
    if [[ -z "$ns_input" ]]; then
        echo -e "${RED}[ERROR] NS domain khaali nahi ho sakta.${NC}"
    else
        mkdir -p "$SLOWDNS_DIR"
        echo "$ns_input" > "$SLOWDNS_NS_FILE"
        echo -e "${GREEN}[SUCCESS] NS Domain set: ${CYAN}${ns_input}${NC}"
        if [[ -f "$SLOWDNS_PRIVKEY" ]]; then
            configure_slowdns_service
        fi
    fi
    press_any_key
}

slowdns_show_info() {
    clear
    local ns_dom pubkey pubip
    ns_dom=$(get_ns_domain)
    pubkey=$(cat "$SLOWDNS_PUBKEY" 2>/dev/null)
    pubip=$(curl -s ifconfig.me 2>/dev/null)
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}          SLOWDNS CONNECTION INFO                  ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e " Service Status : $(systemctl is-active slowdns 2>/dev/null)"
    echo -e " NS Domain      : ${ns_dom:-Not Set}"
    echo -e " Server Public IP: ${pubip:-Unknown}"
    echo -e " Public Key     : ${pubkey:-Not Generated}"
    echo -e " UDP Port       : ${SLOWDNS_UDP_PORT}"
    echo -e "${CYAN}====================================================${NC}"
    press_any_key
}

slowdns_menu() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}          SLOWDNS MANAGEMENT                       ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e " 1) Install / Reinstall SlowDNS Server"
    echo -e " 2) Set / Change NS Domain"
    echo -e " 3) Show Public Key & Connection Info"
    echo -e " 4) Restart SlowDNS Service"
    echo -e " 5) Back"
    echo -e "${CYAN}====================================================${NC}"
    read -rp "Option [1-5]: " sd_opt
    case $sd_opt in
        1) install_slowdns ;;
        2) slowdns_set_ns_domain_flow ;;
        3) slowdns_show_info ;;
        4)
            free_port_53
            systemctl restart slowdns 2>/dev/null
            echo -e "${GREEN}[SUCCESS] SlowDNS service restart kar diya gaya.${NC}"
            press_any_key
            ;;
        5) return ;;
    esac
}

install_python_tracker() {
cat << 'EOF' > /usr/local/bin/autokill.py
import os
import sys
import time
import subprocess
import re
import json
import datetime

USER_DIR = "/etc/raretriccks/users"
V2USER_DIR = "/etc/raretriccks/v2users"
XRAY_CONFIG = "/usr/local/etc/xray/config.json"
XRAY_ACCESS_LOG = "/var/log/xray/access.log"
XRAY_API_ADDR = "127.0.0.1:10085"

def get_auth_logs():
    raw = ""
    try:
        raw = subprocess.check_output(["journalctl", "-u", "dropbear", "--no-pager", "-n", "300"], stderr=subprocess.DEVNULL).decode("utf-8", errors="ignore")
    except Exception:
        pass
    if os.path.exists("/var/log/auth.log"):
        try:
            with open("/var/log/auth.log", "r", encoding="utf-8", errors="ignore") as f:
                raw += "\n" + f.read()
        except Exception:
            pass
    return raw

def get_active_users_and_pids(raw_logs):
    user_pids = {}
    try:
        ps_out = subprocess.check_output(["ps", "aux"], stderr=subprocess.DEVNULL).decode("utf-8", errors="ignore")
        for line in ps_out.splitlines():
            if "dropbear" in line and "grep" not in line:
                parts = line.split()
                if len(parts) > 1:
                    pid = parts[1]
                    matches = [l for l in raw_logs.splitlines() if f"dropbear[{pid}]" in l and "Password auth succeeded" in l]
                    if matches:
                        last_line = matches[-1]
                        m = re.search(r"for \x27(\w+)\x27", last_line)
                        if not m:
                            m = re.search(r"for (\w+)", last_line)
                        if m:
                            uname = m.group(1)
                            if uname not in user_pids:
                                user_pids[uname] = []
                            user_pids[uname].append(pid)
    except Exception:
        pass
    return user_pids

def get_pid_io_bytes(pid):
    io_file = f"/proc/{pid}/io"
    total_bytes = 0
    if os.path.exists(io_file):
        try:
            with open(io_file, "r") as f:
                for line in f:
                    if line.startswith("rchar:") or line.startswith("wchar:"):
                        total_bytes += int(line.split(":")[1].strip())
        except Exception:
            pass
    return total_bytes

last_pid_bytes = {}

def xray_strip_client(email):
    try:
        with open(XRAY_CONFIG, "r") as f:
            cfg = json.load(f)
        changed = False
        for ib in cfg.get("inbounds", []):
            clients = ib.get("settings", {}).get("clients")
            if clients:
                new_clients = [c for c in clients if c.get("email") != email]
                if len(new_clients) != len(clients):
                    ib["settings"]["clients"] = new_clients
                    changed = True
        if changed:
            with open(XRAY_CONFIG, "w") as f:
                json.dump(cfg, f, indent=2)
            subprocess.call(["systemctl", "restart", "xray"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

def get_v2ray_delta_mb(email):
    total_bytes = 0
    try:
        out = subprocess.check_output(
            ["xray", "api", "statsquery",
             "--server=" + XRAY_API_ADDR,
             "-pattern", "user>>>{}>>>traffic".format(email),
             "-reset"],
            stderr=subprocess.DEVNULL, timeout=5
        ).decode("utf-8", errors="ignore")
        data = json.loads(out)
        for stat in data.get("stat", []):
            try:
                total_bytes += int(stat.get("value", 0))
            except Exception:
                pass
    except Exception:
        pass
    return total_bytes / (1024.0 * 1024.0)

def get_v2ray_active_ips(email, log_lines):
    ips = set()
    needle = f"email: {email}"
    for line in log_lines:
        if needle in line:
            m = re.search(r"from\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):", line)
            if m:
                ips.add(m.group(1))
    return ips

def process_v2ray_users():
    if not os.path.exists(V2USER_DIR):
        return

    log_lines = []
    try:
        with open(XRAY_ACCESS_LOG, "r", errors="ignore") as f:
            log_lines = f.readlines()[-1500:]
    except Exception:
        pass

    for fname in os.listdir(V2USER_DIR):
        if not fname.endswith(".conf"):
            continue
        uname = fname[:-5]
        conf_path = os.path.join(V2USER_DIR, fname)

        data = {}
        try:
            with open(conf_path, "r") as f:
                lines = f.readlines()
        except Exception:
            continue

        for line in lines:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                data[k] = v

        if data.get("LOCKED", "0") == "1":
            continue

        ip_limit = 0
        try:
            ip_limit = int(data.get("IP_LIMIT", "0") or 0)
        except Exception:
            pass
        gb_limit = data.get("GB_LIMIT", "Unlimited")
        used_mb = 0.0
        try:
            used_mb = float(data.get("USED_MB", "0.0") or 0.0)
        except Exception:
            pass
        expire_date = data.get("EXPIRE_DATE", "Unlimited")

        delta_mb = get_v2ray_delta_mb(uname)
        if delta_mb > 0:
            used_mb += delta_mb

        active_ips = get_v2ray_active_ips(uname, log_lines)

        breach = False
        if gb_limit != "Unlimited":
            try:
                if used_mb >= float(gb_limit) * 1024.0:
                    breach = True
            except Exception:
                pass
        if ip_limit > 0 and len(active_ips) > ip_limit:
            breach = True
        if expire_date != "Unlimited":
            try:
                exp = datetime.datetime.strptime(expire_date, "%Y-%m-%d").date()
                if datetime.date.today() >= exp:
                    breach = True
            except Exception:
                pass

        data["USED_MB"] = "{:.2f}".format(used_mb)
        if breach:
            data["LOCKED"] = "1"
            xray_strip_client(uname)

        try:
            with open(conf_path, "w") as f:
                for k, v in data.items():
                    f.write("{}={}\n".format(k, v))
        except Exception:
            pass

while True:
    try:
        raw_logs = get_auth_logs()
        user_pids_map = get_active_users_and_pids(raw_logs)

        if os.path.exists(USER_DIR):
            for fname in os.listdir(USER_DIR):
                if not fname.endswith(".conf"):
                    continue

                uname = fname[:-5]
                conf_path = os.path.join(USER_DIR, fname)

                ip_limit = 0
                gb_limit = "Unlimited"
                used_mb = 0.0

                with open(conf_path, "r") as f:
                    lines = f.readlines()

                for line in lines:
                    if line.startswith("IP_LIMIT="):
                        try: ip_limit = int(line.strip().split("=")[1])
                        except Exception: pass
                    elif line.startswith("GB_LIMIT="):
                        gb_limit = line.strip().split("=")[1]
                    elif line.startswith("USED_MB="):
                        try: used_mb = float(line.strip().split("=")[1])
                        except Exception: pass

                active_pids = user_pids_map.get(uname, [])

                for pid in active_pids:
                    current_b = get_pid_io_bytes(pid)
                    if pid in last_pid_bytes:
                        diff = current_b - last_pid_bytes[pid]
                        if diff > 0:
                            used_mb += (diff / (1024.0 * 1024.0))
                    last_pid_bytes[pid] = current_b

                new_lines = []
                for line in lines:
                    if line.startswith("USED_MB="):
                        new_lines.append(f"USED_MB={used_mb:.2f}\n")
                    else:
                        new_lines.append(line)
                with open(conf_path, "w") as f:
                    f.writelines(new_lines)

                if gb_limit != "Unlimited":
                    try:
                        max_mb = float(gb_limit) * 1024.0
                        if used_mb >= max_mb:
                            subprocess.call(["passwd", "-l", uname], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                            for pid in active_pids:
                                subprocess.call(["kill", "-9", pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    except Exception:
                        pass

                if ip_limit > 0 and len(active_pids) > ip_limit:
                    subprocess.call(["passwd", "-l", uname], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    for pid in active_pids:
                        subprocess.call(["kill", "-9", pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        process_v2ray_users()

    except Exception:
        pass

    time.sleep(3)
EOF
    chmod +x /usr/local/bin/autokill.py

cat << 'EOF' > /etc/systemd/system/autokill.service
[Unit]
Description=RareTriccks Auto-Kill & Bandwidth Tracking Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/autokill.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable autokill
    systemctl restart autokill
}

copy_xray_certs() {
    local CERT_DOM=$(get_cert_domain)
    mkdir -p "$XRAY_CERT_DIR"
    if [[ -f "/etc/letsencrypt/live/${CERT_DOM}/fullchain.pem" && -f "/etc/letsencrypt/live/${CERT_DOM}/privkey.pem" ]]; then
        cp "/etc/letsencrypt/live/${CERT_DOM}/fullchain.pem" "$XRAY_CERT_FILE"
        cp "/etc/letsencrypt/live/${CERT_DOM}/privkey.pem" "$XRAY_KEY_FILE"
        chown -R "${XRAY_SVC_USER}:${XRAY_SVC_USER}" "$XRAY_CERT_DIR" 2>/dev/null || chown -R nobody:nogroup "$XRAY_CERT_DIR"
        chmod 750 "$XRAY_CERT_DIR"
        chmod 640 "$XRAY_CERT_FILE" "$XRAY_KEY_FILE"
        return 0
    fi
    return 1
}

configure_nginx_proxy() {
    local MY_DOMAIN=$(get_domain)
    local CERT_DOM=$(get_cert_domain)
    local HAVE_SSL=0
    
    if [[ -f "/etc/letsencrypt/live/${CERT_DOM}/fullchain.pem" ]]; then
        HAVE_SSL=1
    fi

    mkdir -p /etc/nginx/conf.d

cat << NGINX_EOF > "$NGINX_CONF"
server {
    listen 80;
    listen [::]:80;
    server_name ${MY_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location ${V2RAY_WS_PATH} {
        proxy_pass http://127.0.0.1:${XRAY_WS_PLAIN_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass http://127.0.0.1:${WS_SSH_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX_EOF

    if [[ "$HAVE_SSL" -eq 1 ]]; then
cat << NGINX_EOF >> "$NGINX_CONF"
server {
    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;
    server_name ${MY_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${CERT_DOM}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CERT_DOM}/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location ${V2RAY_WS_PATH} {
        proxy_pass http://127.0.0.1:${XRAY_WS_TLS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass http://127.0.0.1:${WS_SSH_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX_EOF

cat << STREAM_EOF > "$NGINX_STREAM_CONF"
stream {
    upstream ssh_direct {
        server 127.0.0.1:109;
    }
    upstream web_backend {
        server 127.0.0.1:8443;
    }

    map \$ssl_preread_protocol \$backend {
        "" ssh_direct;
        default web_backend;
    }

    server {
        listen 443;
        listen [::]:443;
        proxy_pass \$backend;
        ssl_preread on;
    }
}
STREAM_EOF
        grep -q "include $NGINX_STREAM_CONF;" /etc/nginx/nginx.conf || sed -i "/http {/i include $NGINX_STREAM_CONF;\n" /etc/nginx/nginx.conf
    fi

    nginx -t &>/tmp/nginx_check.log
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[ERROR] Nginx config invalid!${NC}"
        cat /tmp/nginx_check.log
        return 1
    fi

    systemctl enable nginx &>/dev/null
    systemctl restart nginx
    wait_for_port 127.0.0.1 80 "Nginx (80)" 10
    if [[ "$HAVE_SSL" -eq 1 ]]; then
        wait_for_port 127.0.0.1 443 "Nginx Direct Multiplexer (443)" 10
    fi
}

add_domain_option() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}        ADD / CHANGE DOMAIN NAME                    ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    read -rp " Apna Domain Enter Karein (e.g. vpn.domain.com): " new_dom

    if [[ -z "$new_dom" ]]; then
        echo -e "${RED}[ERROR] Domain khaali nahi chhod sakte!${NC}"
    else
        mkdir -p /etc/raretriccks
        echo "$new_dom" > "$DOMAIN_FILE"
        echo -e "\n${GREEN}[SUCCESS] Domain set to: ${CYAN}${new_dom}${NC}"
        configure_nginx_proxy
    fi
    press_any_key
}

install_all_components() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}   ${PANEL_NAME} - SYSTEM INSTALLATION           ${NC}"
    echo -e "${CYAN}====================================================${NC}"

    echo -e "${BLUE}[1/8] Updating Packages...${NC}"
    apt update -y && apt upgrade -y

    echo -e "${BLUE}[2/8] Installing Required Tools...${NC}"
    apt install -y curl wget unzip tar net-tools socat jq openssl nginx dropbear certbot python3 python3-pip lsof iptables golang-go

    echo -e "${BLUE}[3/8] Configuring Dropbear SSH & Banner...${NC}"
cat << 'EOF' > $BANNER_FILE
<font color="green">==========================================</font><br>
<font color="yellow"><b>WELCOME TO RARETRICCKS VIP VPN</b></font><br>
<font color="red"><b>- NO TORRENT / NO MULTILOGIN</b></font><br>
<font color="green">==========================================</font><br>
EOF

    fix_dropbear_core
    sed -i 's/#Banner none/Banner \/etc\/issue.net/g' /etc/ssh/sshd_config
    systemctl restart ssh

    echo -e "${BLUE}[4/8] Installing BadVPN UDP Gateway...${NC}"
    install_badvpn_udpgw

    echo -e "${BLUE}[5/8] Creating Python WebSocket Service...${NC}"
cat << 'EOF' > /usr/local/bin/ws-proxy.py
import socket, threading, select, time

PORT = 2082
TARGET_HOST = '127.0.0.1'
TARGET_PORT = 109
LOG_FILE = '/var/log/ws-proxy.log'

def log_client_ip(ip):
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - REAL_IP:{ip}\n")
    except Exception:
        pass

def handle_client(client_socket, client_addr):
    real_ip = client_addr[0]
    try:
        client_socket.settimeout(10)
        request_raw = client_socket.recv(4096)
        if not request_raw:
            client_socket.close()
            return

        request = request_raw.decode('utf-8', errors='ignore')

        for line in request.split('\r\n'):
            if line.lower().startswith('x-forwarded-for:') or line.lower().startswith('x-real-ip:'):
                real_ip = line.split(':')[1].strip().split(',')[0].strip()
                break

        log_client_ip(real_ip)

        response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        client_socket.sendall(response.encode('utf-8'))

        target_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target_socket.connect((TARGET_HOST, TARGET_PORT))

        sockets = [client_socket, target_socket]
        client_socket.settimeout(None)

        while True:
            readable, _, _ = select.select(sockets, [], [])
            for s in readable:
                other = target_socket if s is client_socket else client_socket
                data = s.recv(8192)
                if not data:
                    return
                other.sendall(data)
    except Exception:
        pass
    finally:
        client_socket.close()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', PORT))
server.listen(200)

while True:
    client, addr = server.accept()
    threading.Thread(target=handle_client, args=(client, addr), daemon=True).start()
EOF

cat << 'EOF' > /etc/systemd/system/ws-proxy.service
[Unit]
Description=RareTriccks WebSocket Proxy Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ws-proxy
    systemctl restart ws-proxy
    wait_for_port 127.0.0.1 2082 "WS-Proxy (2082)" 10

    echo -e "${BLUE}[6/8] Installing Xray-core & Nginx Reverse Proxy...${NC}"
    install_xray_core
    if command -v xray &>/dev/null; then
        configure_xray
        configure_nginx_proxy
    else
        echo -e "${RED}[ERROR] Xray-core install fail ho gaya.${NC}"
    fi

    echo -e "${BLUE}[7/8] Installing Bandwidth Tracking Engine...${NC}"
    install_python_tracker

    echo -e "${BLUE}[8/8] SlowDNS Setup...${NC}"
    if [[ -n "$(get_ns_domain)" ]]; then
        install_slowdns_binary && slowdns_generate_keys && configure_slowdns_service
    fi

    echo -e "\n${GREEN}[SUCCESS] All Components Installed Successfully!${NC}"
    status_check_inline
    press_any_key
}

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_SVC_USER="xray-svc"

install_xray_core() {
    if ! command -v xray &>/dev/null; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
    mkdir -p /usr/local/etc/xray
    fix_xray_service_user
    systemctl enable xray &>/dev/null
    return 0
}

fix_xray_service_user() {
    if ! id "$XRAY_SVC_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$XRAY_SVC_USER" 2>/dev/null
    fi

    local unit="/etc/systemd/system/xray.service"
    if [[ -f "$unit" ]]; then
        if grep -q '^User=' "$unit"; then
            sed -i "s/^User=.*/User=${XRAY_SVC_USER}/" "$unit"
        else
            sed -i "/\[Service\]/a User=${XRAY_SVC_USER}" "$unit"
        fi
        if grep -q '^Group=' "$unit"; then
            sed -i "s/^Group=.*/Group=${XRAY_SVC_USER}/" "$unit"
        else
            sed -i "/\[Service\]/a Group=${XRAY_SVC_USER}" "$unit"
        fi
        systemctl daemon-reload
    fi
}

configure_xray() {
    mkdir -p /usr/local/etc/xray
    fix_xray_service_user
    local MY_DOMAIN=$(get_domain)
    local HAVE_CERT=0
    if copy_xray_certs; then HAVE_CERT=1; fi
    local CERT_FILE="$XRAY_CERT_FILE"
    local KEY_FILE="$XRAY_KEY_FILE"

    mkdir -p /var/log/xray
    chown -R "${XRAY_SVC_USER}:${XRAY_SVC_USER}" /var/log/xray 2>/dev/null || chown -R nobody:nogroup /var/log/xray

cat << XR_EOF > "$XRAY_CONFIG"
{
  "log": { "loglevel": "warning", "access": "${XRAY_ACCESS_LOG}" },
  "api": { "tag": "api", "services": ["HandlerService", "StatsService", "LoggerService"] },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "ws-tls-in",
      "listen": "127.0.0.1",
      "port": ${XRAY_WS_TLS_PORT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "${V2RAY_WS_PATH}" }, "acceptProxyProtocol": true }
    },
    {
      "tag": "ws-plain-in",
      "listen": "127.0.0.1",
      "port": ${XRAY_WS_PLAIN_PORT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "${V2RAY_WS_PATH}" }, "acceptProxyProtocol": true }
    },
    {
      "tag": "xhttp-in",
      "listen": "0.0.0.0",
      "port": ${XRAY_XHTTP_PORT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "security": "none", "xhttpSettings": { "path": "${V2RAY_XHTTP_PATH}", "mode": "auto" } }
    },
    {
      "tag": "tcp-plain-in",
      "listen": "0.0.0.0",
      "port": ${XRAY_TCP_PLAIN_PORT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "tcp" }
    },
    {
      "tag": "tcp-tls-in",
      "listen": "0.0.0.0",
      "port": ${XRAY_TCP_TLS_PORT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "none" }
    },
    {
      "tag": "grpc-in",
      "listen": "0.0.0.0",
      "port": ${XRAY_GRPC_PORT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "grpc", "grpcSettings": { "serviceName": "${V2RAY_GRPC_SERVICE}" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" }
    ]
  }
}
XR_EOF
    chmod 644 "$XRAY_CONFIG"

    if [[ "$HAVE_CERT" -eq 1 && -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        tmp=$(mktemp)
        jq --arg cert "$CERT_FILE" --arg key "$KEY_FILE" \
           '(.inbounds[] | select(.tag=="xhttp-in" or .tag=="tcp-tls-in") | .streamSettings) += { "security": "tls", "tlsSettings": { "certificates": [ { "certificateFile": $cert, "keyFile": $key } ] } }' \
           "$XRAY_CONFIG" > "$tmp"
        if [[ -s "$tmp" ]] && jq empty "$tmp" &>/dev/null; then
            mv "$tmp" "$XRAY_CONFIG"
        else
            rm -f "$tmp"
        fi
        chmod 644 "$XRAY_CONFIG"
    fi

    systemctl restart xray
    wait_for_port 127.0.0.1 "$XRAY_WS_TLS_PORT" "Xray ws-tls-in" 10
    wait_for_port 127.0.0.1 "$XRAY_WS_PLAIN_PORT" "Xray ws-plain-in" 10
}

v2ray_inject_client() {
    local uname="$1"
    local uuid="$2"
    local backup
    backup=$(mktemp)
    cp "$XRAY_CONFIG" "$backup"

    for tag in ws-tls-in ws-plain-in xhttp-in tcp-plain-in tcp-tls-in grpc-in; do
        tmp=$(mktemp)
        jq --arg tag "$tag" --arg id "$uuid" --arg email "$uname" \
           '(.inbounds[] | select(.tag==$tag) | .settings.clients) += [{"id": $id, "email": $email}]' \
           "$XRAY_CONFIG" > "$tmp"
        if [[ -s "$tmp" ]] && jq empty "$tmp" &>/dev/null; then
            mv "$tmp" "$XRAY_CONFIG"
        else
            rm -f "$tmp"
            cp "$backup" "$XRAY_CONFIG"
            rm -f "$backup"
            return 1
        fi
    done
    chmod 644 "$XRAY_CONFIG"
    rm -f "$backup"
    timeout 15 systemctl restart xray
    return 0
}

v2ray_strip_client() {
    local uname="$1"
    local backup
    backup=$(mktemp)
    cp "$XRAY_CONFIG" "$backup"

    tmp=$(mktemp)
    jq --arg email "$uname" \
       '(.inbounds[].settings.clients) |= map(select(.email != $email))' \
       "$XRAY_CONFIG" > "$tmp"
    if [[ -s "$tmp" ]] && jq empty "$tmp" &>/dev/null; then
        mv "$tmp" "$XRAY_CONFIG"
    else
        rm -f "$tmp" "$backup"
        return 1
    fi
    chmod 644 "$XRAY_CONFIG"
    rm -f "$backup"
    timeout 15 systemctl restart xray
}

v2ray_add_user() {
    local uname="$1"
    local uuid="$2"
    local ip_limit="${3:-0}"
    local gb_limit="${4:-Unlimited}"
    local exp_days="${5:-0}"
    [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)

    if ! v2ray_inject_client "$uname" "$uuid"; then
        return 1
    fi

    mkdir -p "$V2USERS_DIR"
    local expire_date="Unlimited"
    if [[ "$exp_days" =~ ^[0-9]+$ && "$exp_days" -gt 0 ]]; then
        expire_date=$(date -d "+${exp_days} days" +"%Y-%m-%d")
    fi

cat << V2_EOF > "${V2USERS_DIR}/${uname}.conf"
USERNAME=$uname
UUID=$uuid
IP_LIMIT=$ip_limit
GB_LIMIT=$gb_limit
USED_MB=0.0
EXPIRE_DATE=$expire_date
LOCKED=0
V2_EOF

    echo "$uuid"
}

v2ray_delete_user() {
    local uname="$1"
    if v2ray_strip_client "$uname"; then
        rm -f "${V2USERS_DIR}/${uname}.conf"
        return 0
    fi
    return 1
}

v2ray_unlock_user() {
    local uname="$1"
    local conf="${V2USERS_DIR}/${uname}.conf"
    [[ -f "$conf" ]] || return 1
    local uuid
    uuid=$(grep '^UUID=' "$conf" | cut -d= -f2)
    [[ -z "$uuid" ]] && return 1

    v2ray_strip_client "$uname" &>/dev/null
    if v2ray_inject_client "$uname" "$uuid"; then
        sed -i 's/^LOCKED=.*/LOCKED=0/' "$conf"
        return 0
    fi
    return 1
}

v2ray_list_users() {
    jq -r '.inbounds[] | select(.tag=="ws-tls-in") | .settings.clients[]? | "\(.email)  ->  \(.id)"' "$XRAY_CONFIG" 2>/dev/null
    if [[ -d "$V2USERS_DIR" ]]; then
        echo -e "\n${CYAN}--- Limits / Quota (V2Ray Users) ---${NC}"
        for f in "${V2USERS_DIR}"/*.conf; do
            [[ -e "$f" ]] || continue
            local uname ip gb used exp locked
            uname=$(grep '^USERNAME=' "$f" | cut -d= -f2)
            ip=$(grep '^IP_LIMIT=' "$f" | cut -d= -f2)
            gb=$(grep '^GB_LIMIT=' "$f" | cut -d= -f2)
            used=$(grep '^USED_MB=' "$f" | cut -d= -f2)
            exp=$(grep '^EXPIRE_DATE=' "$f" | cut -d= -f2)
            locked=$(grep '^LOCKED=' "$f" | cut -d= -f2)
            echo -e " ${uname}: IP_LIMIT=${ip} GB_LIMIT=${gb} USED_MB=${used} EXPIRE=${exp} LOCKED=${locked}"
        done
    fi
}

v2ray_add_user_flow() {
    local MY_DOMAIN=$(get_domain)
    read -rp "Username/Remarks (e.g. test): " vu
    read -rp "Custom UUID (Leave blank for auto-generate): " custom_uuid
    read -rp "Expired Days (0 for unlimited): " vexp
    read -rp "IP Limit (0 for unlimited): " vip
    read -rp "GB Limit (e.g. 10 or Unlimited): " vgb
    [[ -z "$vu" ]] && { echo -e "${RED}Username khaali nahi ho saka${NC}"; press_any_key; return; }
    local gen_uuid
    gen_uuid=$(v2ray_add_user "$vu" "$custom_uuid" "$vip" "$vgb" "$vexp")
    if [[ -z "$gen_uuid" ]]; then
        echo -e "\n${RED}[FAILED] User add nahi ho saka.${NC}"
        press_any_key
        return
    fi
    echo -e "\n${GREEN}[SUCCESS] V2Ray User '${vu}' added successfully!${NC}"
    echo -e "${CYAN}UUID          : ${gen_uuid}${NC}"
    echo -e "${CYAN}IP Limit      : ${vip:-0}${NC}"
    echo -e "${CYAN}GB Limit      : ${vgb:-Unlimited}${NC}"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e "${GREEN}Link WS TLS       :${NC} vless://${gen_uuid}@${MY_DOMAIN}:443?type=ws&encryption=none&security=tls&host=${MY_DOMAIN}&path=${V2RAY_WS_PATH}#XRAY_VLESS_WS_${vu}"
    echo -e "${GREEN}Link WS NoTLS     :${NC} vless://${gen_uuid}@${MY_DOMAIN}:80?type=ws&encryption=none&security=none&host=${MY_DOMAIN}&path=${V2RAY_WS_PATH}#XRAY_VLESS_WS_${vu}"
    echo -e "${CYAN}====================================================${NC}"
    press_any_key
}

v2ray_delete_user_flow() {
    read -rp "Username to delete: " vu
    if v2ray_delete_user "$vu"; then
        echo -e "${GREEN}[SUCCESS] V2Ray User removed.${NC}"
    else
        echo -e "${RED}[FAILED] User remove nahi ho saka.${NC}"
    fi
    press_any_key
}

v2ray_check_online_ips() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}     V2RAY / XRAY CONNECTED USERS & REAL IPs       ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    if [[ -f "$XRAY_ACCESS_LOG" ]]; then
        echo -e "${BLUE}Real IP Connection Logs (Pakistan/Client Public IP):${NC}"
        grep -oE "from [0-9.]+:[0-9]+ accepted tcp:.* email: [A-Za-z0-9_.-]+" "$XRAY_ACCESS_LOG" | tail -n 30
    else
        echo -e "${YELLOW}Access log unavailable.${NC}"
    fi
    echo -e "${CYAN}====================================================${NC}"
    press_any_key
}

v2ray_modify_limits() {
    clear
    echo -e "${CYAN}--- Modify V2Ray Limits & Quota ---${NC}"
    read -rp "Username: " uname
    local conf="${V2USERS_DIR}/${uname}.conf"
    if [[ ! -f "$conf" ]]; then
        echo -e "${RED}[ERROR] User not found!${NC}"
        press_any_key
        return
    fi
    read -rp "New IP Limit (0 = unlimited): " newip
    read -rp "New GB Limit (e.g. 20 or Unlimited): " newgb
    read -rp "New Expiry Days (0 = unlimited): " newdays

    sed -i "s/^IP_LIMIT=.*/IP_LIMIT=${newip}/" "$conf"
    sed -i "s/^GB_LIMIT=.*/GB_LIMIT=${newgb}/" "$conf"
    if [[ "$newdays" == "0" ]]; then
        sed -i "s/^EXPIRE_DATE=.*/EXPIRE_DATE=Unlimited/" "$conf"
    else
        sed -i "s/^EXPIRE_DATE=.*/EXPIRE_DATE=$(date -d "+$newdays days" +"%Y-%m-%d")/" "$conf"
    fi
    v2ray_unlock_user "$uname"
    echo -e "${GREEN}[SUCCESS] V2Ray account updated & unlocked.${NC}"
    press_any_key
}

v2ray_menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${YELLOW}          V2RAY / XRAY MANAGEMENT                  ${NC}"
        echo -e "${CYAN}====================================================${NC}"
        echo -e " 1) Add V2Ray User"
        echo -e " 2) Delete V2Ray User"
        echo -e " 3) List V2Ray Users & Usage"
        echo -e " 4) Check V2Ray Connected Real IPs"
        echo -e " 5) Extend / Modify Limits (IP / GB / Expiry)"
        echo -e " 6) Back to Main Menu"
        echo -e "${CYAN}====================================================${NC}"
        read -rp "Option [1-6]: " v_opt
        case $v_opt in
            1) v2ray_add_user_flow ;;
            2) v2ray_delete_user_flow ;;
            3) clear; v2ray_list_users; press_any_key ;;
            4) v2ray_check_online_ips ;;
            5) v2ray_modify_limits ;;
            6) return ;;
        esac
    done
}

ssh_add_user_flow() {
    local MY_DOMAIN=$(get_domain)
    read -rp "Username: " su
    read -rp "Password: " sp
    read -rp "Expired Days: " sd
    read -rp "IP Limit (0 for unlimited): " sil
    read -rp "GB Limit (e.g. 10 or Unlimited): " sgb

    if id "$su" &>/dev/null; then
        echo -e "${RED}User pehle se mojood hai!${NC}"
        press_any_key
        return
    fi

    useradd -e "$(date -d "+$sd days" +"%Y-%m-%d")" -s /bin/bash -m "$su"
    echo -e "$sp\n$sp" | passwd "$su" &>/dev/null

    mkdir -p "$USERS_DIR"
cat << U_EOF > "${USERS_DIR}/${su}.conf"
USERNAME=$su
PASSWORD=$sp
IP_LIMIT=$sil
GB_LIMIT=$sgb
USED_MB=0.0
U_EOF

    echo -e "\n${GREEN}[SUCCESS] SSH Account Created Successfully!${NC}"
    echo -e "${CYAN}Username         : ${su}${NC}"
    echo -e "${CYAN}Password         : ${sp}${NC}"
    echo -e "${CYAN}Host/IP          : ${MY_DOMAIN}${NC}"
    echo -e "${CYAN}Direct SSL Port  : 443 (No Payload Required / Stunnel compatible)${NC}"
    echo -e "${CYAN}Dropbear Port    : 109 / 22 / 447${NC}"
    echo -e "${CYAN}WS Port          : 80 / 8443 (via Nginx -> 2082)${NC}"
    echo -e "${CYAN}BadVPN Port      : 127.0.0.1:${BADVPN_PORT}${NC}"
    echo -e "${CYAN}====================================================${NC}"
    press_any_key
}

ssh_delete_user_flow() {
    read -rp "Username to delete: " su
    userdel -f "$su" &>/dev/null
    rm -f "${USERS_DIR}/${su}.conf"
    echo -e "${GREEN}[SUCCESS] SSH User removed.${NC}"
    press_any_key
}

ssh_list_users() {
    clear
    echo -e "${CYAN}--- Active SSH Users & Limits ---${NC}"
    if [[ -d "$USERS_DIR" ]]; then
        for f in "${USERS_DIR}"/*.conf; do
            [[ -e "$f" ]] || continue
            local uname ip gb used exp lockstat
            uname=$(grep '^USERNAME=' "$f" | cut -d= -f2)
            ip=$(grep '^IP_LIMIT=' "$f" | cut -d= -f2)
            gb=$(grep '^GB_LIMIT=' "$f" | cut -d= -f2)
            used=$(grep '^USED_MB=' "$f" | cut -d= -f2)
            exp=$(chage -l "$uname" 2>/dev/null | grep "Account expires" | awk -F': ' '{print $2}')
            lockstat=$(passwd -S "$uname" 2>/dev/null | awk '{print $2}')
            echo -e " ${uname}: IP_LIMIT=${ip} GB_LIMIT=${gb} USED_MB=${used} EXPIRES=${exp:-N/A} STATUS=${lockstat:-N/A}"
        done
    else
        echo "No SSH users found."
    fi
    press_any_key
}

ssh_check_online_ips() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}     SSH CONNECTED SESSIONS & REAL CLIENT IPs      ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${BLUE}Active Connected Dropbear Sessions:${NC}"
    ps aux | grep '[d]ropbear'
    echo ""
    echo -e "${BLUE}Recent SSH Auth Logins (Real IP from Pakistan / Client):${NC}"
    journalctl -u dropbear --no-pager -n 40 | grep "Password auth succeeded"
    echo -e "${CYAN}====================================================${NC}"
    press_any_key
}

ssh_modify_limits() {
    clear
    echo -e "${CYAN}--- Extend / Modify SSH Limits & Limits ---${NC}"
    read -rp "Username: " uname
    if ! id "$uname" &>/dev/null; then
        echo -e "${RED}[ERROR] User not found!${NC}"
        press_any_key
        return
    fi
    local conf="${USERS_DIR}/${uname}.conf"
    read -rp "New IP Limit (0 = unlimited): " newip
    read -rp "New GB Limit (e.g. 20 or Unlimited): " newgb
    read -rp "New Expiry Days (0 = unlimited): " newdays

    if [[ -f "$conf" ]]; then
        sed -i "s/^IP_LIMIT=.*/IP_LIMIT=${newip}/" "$conf"
        sed -i "s/^GB_LIMIT=.*/GB_LIMIT=${newgb}/" "$conf"
    fi

    if [[ "$newdays" == "0" ]]; then
        usermod -e "" "$uname"
    else
        usermod -e "$(date -d "+$newdays days" +"%Y-%m-%d")" "$uname"
    fi
    passwd -u "$uname" &>/dev/null
    echo -e "${GREEN}[SUCCESS] SSH user limits updated & account unlocked.${NC}"
    press_any_key
}

ssh_menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${YELLOW}      SSH / DROPBEAR / DIRECT SSL MANAGEMENT       ${NC}"
        echo -e "${CYAN}====================================================${NC}"
        echo -e " 1) Add SSH Account (Direct SSL 443 + WS)"
        echo -e " 2) Delete SSH Account"
        echo -e " 3) List SSH Accounts & Limits"
        echo -e " 4) Check Connected Real IPs (Pakistan/Client)"
        echo -e " 5) Extend / Modify Limits (IP / GB / Expiry)"
        echo -e " 6) Back to Main Menu"
        echo -e "${CYAN}====================================================${NC}"
        read -rp "Option [1-6]: " s_opt
        case $s_opt in
            1) ssh_add_user_flow ;;
            2) ssh_delete_user_flow ;;
            3) ssh_list_users ;;
            4) ssh_check_online_ips ;;
            5) ssh_modify_limits ;;
            6) return ;;
        esac
    done
}

setup_ssl() {
    clear
    local current_dom=$(get_domain)

    if [[ "$current_dom" == "No Domain Set" || -z "$current_dom" ]]; then
        echo -e "${RED}[ERROR] Pehle Domain Add karein!${NC}"
        press_any_key
        return
    fi

    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}  ${PANEL_NAME} - ISSUING SSL (${current_dom}) ${NC}"
    echo -e "${CYAN}====================================================${NC}"

    systemctl stop nginx 2>/dev/null
    certbot certonly --standalone --preferred-challenges http --agree-tos --register-unsafely-without-email -d "$current_dom"

    if [[ -f "/etc/letsencrypt/live/$current_dom/fullchain.pem" ]]; then
        echo -e "\n${GREEN}[SUCCESS] SSL Active for ${current_dom}!${NC}"
        configure_xray
        configure_nginx_proxy
    else
        echo -e "${RED}[ERROR] SSL Fail ho gaya!${NC}"
    fi
    press_any_key
}

status_check_inline() {
    local current_dom=$(get_domain)
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e " Domain        : ${current_dom}"
    echo -e " Nginx         : $(systemctl is-active nginx)"
    echo -e " Dropbear SSH  : $(systemctl is-active dropbear)"
    echo -e " WS Proxy      : $(systemctl is-active ws-proxy)"
    echo -e " BadVPN UDPGW  : $(systemctl is-active badvpn)"
    echo -e " Xray-core     : $(systemctl is-active xray)"
    echo -e " SlowDNS       : $(systemctl is-active slowdns)"
    echo -e " Port 80       : $(ss -tln 2>/dev/null | grep -q ':80 ' && echo LISTENING || echo DOWN)"
    echo -e " Port 443      : $(ss -tln 2>/dev/null | grep -q ':443 ' && echo LISTENING (Direct SSL + SNI) || echo DOWN)"
    echo -e "${CYAN}----------------------------------------------------${NC}"
}

status_check() {
    clear
    echo -e "${CYAN}====================================================================${NC}"
    echo -e "${YELLOW}${BOLD}                     SYSTEM & PROTOCOL STATUS                       ${NC}"
    echo -e "${CYAN}====================================================================${NC}"
    status_check_inline
    press_any_key
}

uninstall_panel() {
    clear
    read -rp "Confirm karne ke liye 'YES' likhein: " confirm
    [[ "$confirm" != "YES" ]] && return

    systemctl stop ws-proxy autokill dropbear nginx xray badvpn slowdns 2>/dev/null
    systemctl disable ws-proxy autokill dropbear nginx xray badvpn slowdns 2>/dev/null
    rm -f /etc/systemd/system/ws-proxy.service /etc/systemd/system/autokill.service /etc/systemd/system/badvpn.service /etc/systemd/system/slowdns.service
    rm -f /usr/local/bin/ws-proxy.py /usr/local/bin/autokill.py /usr/local/bin/badvpn-udpgw /usr/local/bin/dns-server
    rm -f "$NGINX_CONF" "$NGINX_STREAM_CONF" "$XRAY_CONFIG"
    rm -rf /etc/raretriccks /etc/slowdns
    echo -e "${GREEN}[SUCCESS] Uninstall complete.${NC}"
    exit 0
}

while true; do
    clear
    CURRENT_DOM=$(get_domain)
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${GREEN}              ${PANEL_NAME}                       ${NC}"
    echo -e "${CYAN}              Build: ${PANEL_VERSION}${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e " Domain Target: ${YELLOW}${CURRENT_DOM}${NC}"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e " 1) Auto Install System Components (BadVPN Built-in)"
    echo -e " 2) Add / Change Domain Name"
    echo -e " 3) Issue SSL Certificate (Let's Encrypt)"
    echo -e " 4) SSH / Direct SSL (Port 443) / WS Management"
    echo -e " 5) V2Ray / Xray Management"
    echo -e " 6) SlowDNS Management (SSH over DNS)"
    echo -e " 7) Check Status & Service Ports"
    echo -e " 8) Uninstall Panel"
    echo -e " 9) Exit Panel"
    echo -e "${CYAN}====================================================${NC}"
    read -rp "Select Option [1-9]: " opt

    case $opt in
        1) install_all_components ;;
        2) add_domain_option ;;
        3) setup_ssl ;;
        4) ssh_menu ;;
        5) v2ray_menu ;;
        6) slowdns_menu ;;
        7) status_check ;;
        8) uninstall_panel ;;
        9) exit 0 ;;
    esac
done
