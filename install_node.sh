#!/bin/bash
# Standalone Remnawave Node Installer (Nginx variant)
# Extracted from remnawave-reverse-proxy (install_remnawave.sh + src/nginx/install_node.sh)
#
# Menu:
#   1)  Full node installation (runs all steps below in order)
#   2)  Step: System update & upgrade (apt update && upgrade)
#   3)  Step: Install prerequisites (Docker, certbot, UFW, ufw-docker, packages)
#   4)  Step: Manage IPv6 (enable/disable)
#   5)  Step: Issue / attach TLS certificate
#   6)  Step: Configure node & generate config files (panel IP, secret key,
#             docker-compose.yml, nginx.conf) — needs step 5 done first
#   7)  Step: Deploy camouflage website template
#   8)  Step: Configure firewall & start node
#   9)  Step: Health check
#   10) Uninstall / reinstall node (destructive)

set -uo pipefail

NODE_DIR="/opt/remnanode"
STATE_FILE="$NODE_DIR/.node_installer_state"
SYSCTL_TUNING_FILE="/etc/sysctl.d/99-remnanode-tuning.conf"

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_WHITE="\033[1;37m"
COLOR_RED="\033[1;31m"
COLOR_GRAY='\033[0;90m'

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

question() {
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}$*${COLOR_RESET}"
}

reading() {
    read -rp " $(question "$1")" "$2"
}

error() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}"
}

fatal() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "This script must be run as root."
    fi
}

check_os() {
    if ! grep -q "bullseye" /etc/os-release 2>/dev/null && \
       ! grep -q "bookworm" /etc/os-release 2>/dev/null && \
       ! grep -q "jammy" /etc/os-release 2>/dev/null && \
       ! grep -q "noble" /etc/os-release 2>/dev/null && \
       ! grep -q "trixie" /etc/os-release 2>/dev/null; then
        fatal "Unsupported OS. This script supports Debian 11/12/13 and Ubuntu 22.04/24.04."
    fi
}

spinner() {
    local pid=$1
    local text=$2

    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8

    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local delay=0.1

    printf "\033[1m${COLOR_GREEN}%s${COLOR_RESET}" "$text" > /dev/tty
    while kill -0 "$pid" 2>/dev/null; do
        for (( i=0; i<${#spinstr}; i++ )); do
            printf "\r\033[1m${COLOR_GREEN}[%s] %s${COLOR_RESET}" "${spinstr:$i:1}" "$text" > /dev/tty
            sleep $delay
        done
    done
    printf "\r\033[K" > /dev/tty
}

add_cron_rule() {
    local rule="$1"
    local logged_rule="${rule} >> ${NODE_DIR}/cron_jobs.log 2>&1"

    if ! crontab -u root -l > /dev/null 2>&1; then
        crontab -u root -l 2>/dev/null | crontab -u root -
    fi
    if ! crontab -u root -l | grep -Fxq "$logged_rule"; then
        (crontab -u root -l 2>/dev/null; echo "$logged_rule") | crontab -u root -
    fi
}

# ---------------------------------------------------------------------------
# State persistence (lets each menu step be run independently, in any order,
# across separate script invocations)
# ---------------------------------------------------------------------------

save_state() {
    mkdir -p "$NODE_DIR"
    {
        echo "SELFSTEAL_DOMAIN=\"${SELFSTEAL_DOMAIN:-}\""
        echo "PANEL_IP=\"${PANEL_IP:-}\""
        echo "CERTIFICATE=\"${CERTIFICATE:-}\""
        echo "CERT_METHOD=\"${CERT_METHOD:-}\""
        echo "LETSENCRYPT_EMAIL=\"${LETSENCRYPT_EMAIL:-}\""
        echo "NODE_CERT_DOMAIN=\"${NODE_CERT_DOMAIN:-}\""
        echo "WS_COUNT=\"${WS_COUNT:-}\""
    } > "$STATE_FILE"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    fi
}

require_var() {
    local var_name="$1"
    local prompt_text="$2"
    if [ -z "${!var_name:-}" ]; then
        error "Required value '$var_name' is not set yet (expected from an earlier step)."
        reading "$prompt_text" "$var_name"
    fi
}

# ---------------------------------------------------------------------------
# Domain / certificate helpers
# ---------------------------------------------------------------------------

extract_domain() {
    local SUBDOMAIN=$1
    echo "$SUBDOMAIN" | awk -F'.' '{if (NF > 2) {print $(NF-1)"."$NF} else {print $0}}'
}

check_domain() {
    local domain="$1"

    local domain_ip
    domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    local server_ip
    server_ip=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org || curl -s -4 ipinfo.io/ip)

    if [ -z "$domain_ip" ] || [ -z "$server_ip" ]; then
        error "Warning: could not resolve domain IP or server IP."
        printf "Make sure '%s' has an A record pointing to this server (%s).\n" "$domain" "$server_ip"
        reading "Continue anyway? (y/N):" confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] && return 1 || return 2
    fi

    local cf_ranges
    cf_ranges=$(curl -s https://www.cloudflare.com/ips-v4)
    local cf_array=()
    if [ -n "$cf_ranges" ]; then
        IFS=$'\n' read -r -d '' -a cf_array <<<"$cf_ranges"
    fi

    local ip_in_cloudflare=false
    local IFS='.'
    read -r a b c d <<<"$domain_ip"
    local domain_ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))

    if [ ${#cf_array[@]} -gt 0 ]; then
        for cidr in "${cf_array[@]}"; do
            [[ -z "$cidr" ]] && continue
            local network mask
            network=$(echo "$cidr" | cut -d'/' -f1)
            mask=$(echo "$cidr" | cut -d'/' -f2)
            read -r a b c d <<<"$network"
            local network_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
            local mask_bits=$(( 32 - mask ))
            local range_size=$(( 1 << mask_bits ))
            local min_ip_int=$network_int
            local max_ip_int=$(( network_int + range_size - 1 ))
            if [ "$domain_ip_int" -ge "$min_ip_int" ] && [ "$domain_ip_int" -le "$max_ip_int" ]; then
                ip_in_cloudflare=true
                break
            fi
        done
    fi

    # Restore default IFS before any further `reading` prompts below — while
    # IFS='.' is in effect, `read` stops trimming leading/trailing whitespace
    # from typed input, so a stray space on "y" would silently fail the check.
    unset IFS

    if [ "$domain_ip" = "$server_ip" ]; then
        return 0
    elif [ "$ip_in_cloudflare" = true ]; then
        error "Warning: '$domain' resolves to a Cloudflare IP ($domain_ip). A self-steal domain must NOT be proxied through Cloudflare (grey-cloud it)."
        reading "Continue anyway? (y/N):" confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] && return 1 || return 2
    else
        error "Warning: '$domain' resolves to $domain_ip, but this server's IP is $server_ip."
        reading "Continue anyway? (y/N):" confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] && return 1 || return 2
    fi
}

is_wildcard_cert() {
    local domain=$1
    local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
    [ -f "$cert_path" ] || return 1
    openssl x509 -noout -text -in "$cert_path" | grep -q "\*\.$domain"
}

configure_certbot_renewal_hooks() {
    local renewal_conf="$1"
    [ -f "$renewal_conf" ] || return 1
    sed -i -E '/^(pre_hook|post_hook|renew_hook|deploy_hook) = /d' "$renewal_conf"
    if grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*standalone[[:space:]]*$' "$renewal_conf"; then
        echo "pre_hook = /usr/bin/docker stop nginx" >> "$renewal_conf"
        echo "post_hook = /usr/bin/docker start nginx" >> "$renewal_conf"
    else
        echo "deploy_hook = /usr/bin/docker restart nginx" >> "$renewal_conf"
    fi
}

fix_letsencrypt_structure() {
    local domain=$1
    local live_dir="/etc/letsencrypt/live/$domain"
    local archive_dir="/etc/letsencrypt/archive/$domain"
    local renewal_conf="/etc/letsencrypt/renewal/$domain.conf"

    [ -d "$live_dir" ] || { error "Live directory not found for $domain."; return 1; }
    [ -d "$archive_dir" ] || { error "Archive directory not found for $domain."; return 1; }
    [ -f "$renewal_conf" ] || { error "Renewal config not found for $domain."; return 1; }

    local conf_archive_dir
    conf_archive_dir=$(grep "^archive_dir" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
    [ "$conf_archive_dir" = "$archive_dir" ] || { error "Archive dir mismatch for $domain."; return 1; }

    local latest_version
    latest_version=$(ls -1 "$archive_dir" | grep -E 'cert[0-9]+.pem' | sort -V | tail -n 1 | sed -E 's/.*cert([0-9]+)\.pem/\1/')
    [ -n "$latest_version" ] || { error "Could not determine latest cert version for $domain."; return 1; }

    local files=("cert" "chain" "fullchain" "privkey")
    for file in "${files[@]}"; do
        local archive_file="$archive_dir/$file$latest_version.pem"
        local live_file="$live_dir/$file.pem"
        [ -f "$archive_file" ] || { error "Missing $archive_file"; return 1; }
        [ -f "$live_file" ] && [ ! -L "$live_file" ] && rm "$live_file"
        ln -sf "$archive_file" "$live_file"
    done

    sed -i "s|^cert =.*|cert = $live_dir/cert.pem|" "$renewal_conf"
    sed -i "s|^chain =.*|chain = $live_dir/chain.pem|" "$renewal_conf"
    sed -i "s|^fullchain =.*|fullchain = $live_dir/fullchain.pem|" "$renewal_conf"
    sed -i "s|^privkey =.*|privkey = $live_dir/privkey.pem|" "$renewal_conf"

    configure_certbot_renewal_hooks "$renewal_conf"

    chmod 644 "$live_dir/cert.pem" "$live_dir/chain.pem" "$live_dir/fullchain.pem"
    chmod 600 "$live_dir/privkey.pem"
    return 0
}

check_certificates() {
    local DOMAIN=$1
    local cert_dir="/etc/letsencrypt/live"
    [ -d "$cert_dir" ] || { error "No certificates found for $DOMAIN."; return 1; }

    local live_dir
    live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${DOMAIN}*" 2>/dev/null | sort -V | tail -n 1)
    if [ -n "$live_dir" ] && [ -d "$live_dir" ]; then
        local files=("cert.pem" "chain.pem" "fullchain.pem" "privkey.pem")
        for file in "${files[@]}"; do
            local file_path="$live_dir/$file"
            [ -f "$file_path" ] || { error "Certificate for $DOMAIN is missing $file."; return 1; }
            if [ ! -L "$file_path" ]; then
                fix_letsencrypt_structure "$(basename "$live_dir")" || { error "Failed to fix cert structure for $DOMAIN."; return 1; }
            fi
        done
        echo -e "${COLOR_GREEN}Certificate found: $(basename "$live_dir")${COLOR_RESET}"
        return 0
    fi

    local base_domain
    base_domain=$(extract_domain "$DOMAIN")
    if [ "$base_domain" != "$DOMAIN" ]; then
        live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${base_domain}*" 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$live_dir" ] && [ -d "$live_dir" ] && is_wildcard_cert "$base_domain"; then
            echo -e "${COLOR_GREEN}Wildcard certificate found for $base_domain, covers $DOMAIN${COLOR_RESET}"
            return 0
        fi
    fi

    error "No certificate found for $DOMAIN."
    return 1
}

check_cert_expiry() {
    local domain="$1"
    local cert_dir="/etc/letsencrypt/live"
    local live_dir
    live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${domain}*" | sort -V | tail -n 1)
    [ -n "$live_dir" ] && [ -d "$live_dir" ] || return 1
    local cert_file="$live_dir/fullchain.pem"
    [ -f "$cert_file" ] || return 1
    local expiry_date
    expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | sed 's/notAfter=//')
    [ -n "$expiry_date" ] || return 1
    local expiry_epoch
    expiry_epoch=$(TZ=UTC date -d "$expiry_date" +%s 2>/dev/null) || return 1
    local current_epoch
    current_epoch=$(date +%s)
    echo $(( (expiry_epoch - current_epoch) / 86400 ))
    return 0
}

check_api() {
    local attempts=3
    local attempt=1
    while [ $attempt -le $attempts ]; do
        local api_response
        if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
            api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones \
                --header "Authorization: Bearer ${CLOUDFLARE_API_KEY}" --header "Content-Type: application/json")
        else
            api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones \
                --header "X-Auth-Key: ${CLOUDFLARE_API_KEY}" --header "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                --header "Content-Type: application/json")
        fi
        if echo "$api_response" | grep -q '"success":true'; then
            echo -e "${COLOR_GREEN}Cloudflare token validated.${COLOR_RESET}"
            return 0
        else
            error "Invalid Cloudflare credentials (attempt $attempt/$attempts)."
            if [ $attempt -lt $attempts ]; then
                reading "Cloudflare API token/key:" CLOUDFLARE_API_KEY
                reading "Cloudflare account email:" CLOUDFLARE_EMAIL
            fi
            attempt=$((attempt + 1))
        fi
    done
    fatal "Cloudflare credentials rejected after $attempts attempts."
}

get_certificates() {
    local DOMAIN=$1
    local METHOD=$2
    local EMAIL=$3
    local BASE_DOMAIN
    BASE_DOMAIN=$(extract_domain "$DOMAIN")
    local WILDCARD_DOMAIN="*.$BASE_DOMAIN"

    echo -e "${COLOR_YELLOW}Generating certificate for $DOMAIN...${COLOR_RESET}"

    case $METHOD in
        1)
            # Cloudflare DNS-01 (wildcard)
            reading "Cloudflare API token/key:" CLOUDFLARE_API_KEY
            reading "Cloudflare account email:" CLOUDFLARE_EMAIL
            check_api

            mkdir -p ~/.secrets/certbot
            if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $CLOUDFLARE_API_KEY
EOL
            else
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
            fi
            chmod 600 ~/.secrets/certbot/cloudflare.ini

            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$BASE_DOMAIN" -d "$WILDCARD_DOMAIN" \
                --email "$CLOUDFLARE_EMAIL" --agree-tos --non-interactive \
                --key-type ecdsa --elliptic-curve secp384r1
            ;;
        2)
            # ACME HTTP-01 (single domain, no wildcard). Port 80 is left as-is
            # here — it's permanently open in the firewall baseline for
            # nginx's own HTTP->HTTPS redirect, so it doesn't need toggling.
            # nginx itself must be stopped though, since it already holds 80.
            local nginx_was_running=false
            if docker ps --filter "name=^/nginx$" --format '{{.Names}}' 2>/dev/null | grep -qx "nginx"; then
                nginx_was_running=true
                docker stop nginx > /dev/null
            fi

            certbot certonly --standalone -d "$DOMAIN" \
                --email "$EMAIL" --agree-tos --non-interactive \
                --http-01-port 80 --key-type ecdsa --elliptic-curve secp384r1
            local certbot_status=$?

            [ "$nginx_was_running" = true ] && docker start nginx > /dev/null

            [ "$certbot_status" -ne 0 ] && return "$certbot_status"
            ;;
        3)
            # Gcore DNS-01 (wildcard)
            if ! certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                echo -e "${COLOR_YELLOW}Installing certbot-dns-gcore plugin...${COLOR_RESET}"
                if python3 -m pip install --help 2>&1 | grep -q "break-system-packages"; then
                    python3 -m pip install --break-system-packages certbot-dns-gcore >/dev/null 2>&1
                else
                    python3 -m pip install certbot-dns-gcore >/dev/null 2>&1
                fi
                certbot plugins 2>/dev/null | grep -q "dns-gcore" || fatal "Failed to install certbot-dns-gcore plugin."
            fi

            reading "Gcore API token:" GCORE_API_KEY
            mkdir -p ~/.secrets/certbot
            cat > ~/.secrets/certbot/gcore.ini <<EOL
dns_gcore_apitoken = $GCORE_API_KEY
EOL
            chmod 600 ~/.secrets/certbot/gcore.ini

            certbot certonly \
                --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                -d "$BASE_DOMAIN" -d "$WILDCARD_DOMAIN" \
                --email "$EMAIL" --agree-tos --non-interactive \
                --key-type ecdsa --elliptic-curve secp384r1
            ;;
        *)
            fatal "Invalid certificate method: $METHOD"
            ;;
    esac

    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        error "Certificate generation failed for $DOMAIN."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Step 0: System update & upgrade
# ---------------------------------------------------------------------------

step_system_upgrade() {
    echo -e "${COLOR_GREEN}== Step: System update & upgrade ==${COLOR_RESET}"
    check_root

    echo -e "${COLOR_YELLOW}This runs 'apt-get update -y && apt-get upgrade -y'.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}It may update the kernel or core system packages and could require a reboot afterwards.${COLOR_RESET}"
    reading "Proceed? (y/N):" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${COLOR_YELLOW}Skipped.${COLOR_RESET}"
        return 0
    fi

    apt-get update -y || fatal "apt-get update failed."
    apt-get upgrade -y || fatal "apt-get upgrade failed."

    if [ -f /var/run/reboot-required ]; then
        echo -e "${COLOR_RED}A reboot is required to finish applying updates (kernel or core library was upgraded).${COLOR_RESET}"
        echo -e "${COLOR_RED}Reboot manually when convenient, e.g.: reboot${COLOR_RESET}"
    else
        echo -e "${COLOR_GREEN}System updated, no reboot required.${COLOR_RESET}"
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Install prerequisites
# ---------------------------------------------------------------------------

step_install_prerequisites() {
    echo -e "${COLOR_GREEN}== Step: Install prerequisites ==${COLOR_RESET}"
    check_root
    check_os

    echo -e "${COLOR_YELLOW}Installing base packages...${COLOR_RESET}"
    apt-get update -y || fatal "apt-get update failed."
    apt-get install -y ca-certificates curl jq ufw wget gnupg unzip nano dialog git \
        certbot python3-certbot-dns-cloudflare unattended-upgrades locales dnsutils \
        coreutils grep gawk python3-pip || fatal "Failed to install required packages."

    if ! dpkg -l | grep -q '^ii.*cron '; then
        apt-get install -y cron || fatal "Failed to install cron."
    fi
    systemctl is-active --quiet cron || systemctl start cron || fatal "Failed to start cron."
    systemctl is-enabled --quiet cron || systemctl enable cron || fatal "Failed to enable cron."

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}Installing Docker via get.docker.com...${COLOR_RESET}"
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || fatal "Failed to download Docker installer."
        sh /tmp/get-docker.sh || fatal "Docker installation failed."
    fi
    command -v docker >/dev/null 2>&1 || fatal "Docker is not installed."
    systemctl is-active --quiet docker || systemctl start docker || fatal "Failed to start Docker."
    systemctl is-enabled --quiet docker || systemctl enable docker || fatal "Failed to enable Docker."
    docker info >/dev/null 2>&1 || fatal "Docker is not working correctly."

    # Firewall baseline
    # Port 80 stays open permanently: nginx's default.conf serves a plain
    # HTTP -> HTTPS redirect on it for real visitors, not just ACME challenges.
    # 443/udp: QUIC/HTTP3 and UDP-based inbounds (Hysteria2/TUIC) sharing the
    # same port number as the TCP TLS listener above.
    ufw allow 22/tcp comment 'SSH' && ufw allow 80/tcp comment 'HTTP (redirect to HTTPS)' && ufw allow 443/tcp comment 'HTTPS' && ufw allow 443/udp comment 'QUIC/UDP' && ufw --force enable || fatal "Failed to configure UFW."

    # ufw-docker: makes UFW actually filter Docker's published ports (Docker
    # otherwise inserts its own iptables rules that bypass UFW). Needs both
    # ufw and docker already present, hence installed here, after both.
    echo -e "${COLOR_YELLOW}Installing ufw-docker...${COLOR_RESET}"
    wget -O /usr/local/bin/ufw-docker https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker || fatal "Failed to download ufw-docker."
    chmod +x /usr/local/bin/ufw-docker
    ufw-docker install || fatal "ufw-docker install failed."
    systemctl restart ufw || fatal "Failed to restart ufw after ufw-docker install."

    # Network/connection-tracking tuning for a high-throughput proxy node.
    # Load nf_conntrack explicitly rather than relying on ufw-docker having
    # pulled it in as a side effect — makes net.netfilter.nf_conntrack_max
    # below deterministic instead of depending on UFW's internal behavior.
    modprobe nf_conntrack > /dev/null 2>&1 || true
    # BBR: module load is redundant on kernels where tcp_bbr is built-in, but
    # explicit modprobe + modules-load.d makes it deterministic on kernels
    # where it's a loadable module instead of assuming it's already present.
    modprobe tcp_bbr > /dev/null 2>&1 || true
    echo "tcp_bbr" > /etc/modules-load.d/remnanode-bbr.conf

    # Conntrack table capacity sized from RAM (~320 bytes per tracked
    # connection): a flat ceiling regardless of RAM meant a flood on a small
    # VPS could fill the table and push it toward OOM. This costs nothing at
    # idle — entries are allocated lazily per real connection, not
    # preallocated up to the ceiling; the ceiling only matters under load.
    MEM_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 1048576)"
    CT_MAX=$(( MEM_KB * 1024 / 8 / 320 ))
    [[ "$CT_MAX" -gt 4000000 ]] && CT_MAX=4000000
    [[ "$CT_MAX" -lt 262144  ]] && CT_MAX=262144
    CT_BUCKETS=$(( CT_MAX / 4 ))

    # tcp_mem/udp_mem — global page-count ceiling shared by ALL TCP (or ALL
    # UDP) sockets combined, separate from the per-socket rmem/wmem limits
    # below. Left at the kernel's own boot-time default this is still a real,
    # RAM-derived ceiling (not "unlimited") — and with rmem_max/wmem_max
    # raised to 128MB per socket above, a modest number of concurrent
    # connections could hit that global default long before any single
    # socket's own limit. Budgeted the same way as conntrack (1/8 of RAM,
    # in 4KB pages) rather than set sky-high: UDP has no handshake, so a
    # flood of packets at an open socket (e.g. a future Hysteria2 listener)
    # can pile up receive-buffer memory without ever completing a real
    # connection — an uncapped ceiling turns that into an OOM vector.
    MEM_PAGES_BUDGET=$(( MEM_KB / 32 ))
    [[ "$MEM_PAGES_BUDGET" -lt 16384 ]] && MEM_PAGES_BUDGET=16384
    TCP_MEM_HIGH=$MEM_PAGES_BUDGET
    TCP_MEM_PRESSURE=$(( TCP_MEM_HIGH * 3 / 4 ))
    TCP_MEM_LOW=$(( TCP_MEM_HIGH / 2 ))
    UDP_MEM_HIGH=$MEM_PAGES_BUDGET
    UDP_MEM_PRESSURE=$(( UDP_MEM_HIGH * 3 / 4 ))
    UDP_MEM_LOW=$(( UDP_MEM_HIGH / 2 ))

    cat > "$SYSCTL_TUNING_FILE" <<EOL
# System-wide ceiling on open file descriptors. Per-service limits (ulimits
# in docker-compose, limits.d, systemd DefaultLimitNOFILE) are capped by this
# kernel-wide max regardless of what those individually request.
fs.file-max = 2097152
fs.nr_open = 1048576

# BBR congestion control. Written here (sysctl.d) instead of the legacy
# /etc/sysctl.conf: systemd-sysctl.service reads /etc/sysctl.d/*.conf before
# /etc/sysctl.conf at boot, so a value set only in the legacy file can lose
# to a competing VPS-provider default on reboot (same reasoning as the IPv6
# switch below — see apply_ipv6_sysctl).
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.netfilter.nf_conntrack_max = $CT_MAX
net.netfilter.nf_conntrack_buckets = $CT_BUCKETS
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15

net.core.rmem_max = 134217728
net.core.rmem_default = 26214400
net.core.wmem_max = 134217728
net.core.wmem_default = 26214400
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_mem = $TCP_MEM_LOW $TCP_MEM_PRESSURE $TCP_MEM_HIGH
net.ipv4.udp_mem = $UDP_MEM_LOW $UDP_MEM_PRESSURE $UDP_MEM_HIGH

# TCP auto-tuning ceilings/behavior for many long-lived, bursty connections.
net.ipv4.tcp_rmem = 4096 1048576 134217728
net.ipv4.tcp_wmem = 4096 1048576 134217728
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_min_snd_mss = 512

# tw_reuse only recycles TIME_WAIT sockets for NEW OUTGOING connections
# (client role) using timestamps — unlike the removed tcp_tw_recycle, it
# never touches inbound accept() and is safe behind NAT.
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 2000000
# keepalive: idle time before the first probe, not a connection timeout —
# live connections are unaffected either way, this only reclaims dead ones sooner.
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Anti-spoof / ICMP hardening. rp_filter=2 (loose, not strict=1): host-network
# mode can see asymmetric routing, strict mode would drop legitimate return
# traffic. None of this affects normal ping/traceroute — it only rejects
# spoofed source addresses and disables legacy/unused ICMP redirect and
# source-route handling.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
EOL
    sysctl --system > /dev/null 2>&1 || error "Some sysctl settings could not be applied (e.g. nf_conntrack_max needs the nf_conntrack kernel module) — check 'sysctl --system' output manually if needed."
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        echo -e "${COLOR_GREEN}BBR congestion control active.${COLOR_RESET}"
    else
        error "BBR did not activate (tcp_congestion_control != bbr) — check 'sysctl -n net.ipv4.tcp_congestion_control' and that the tcp_bbr module is available on this kernel."
    fi
    echo -e "${COLOR_GREEN}conntrack sized for ~$(( MEM_KB / 1024 ))MB RAM: max=$CT_MAX buckets=$CT_BUCKETS.${COLOR_RESET}"

    # irqbalance distributes NIC hardware interrupts across CPUs. RPS/RFS
    # below distributes softirq *packet processing* across CPUs — a
    # different layer: without irqbalance the hardware IRQ itself can still
    # pin to one CPU even with RPS configured, so both are needed together.
    if ! dpkg -l | grep -q '^ii.*irqbalance '; then
        apt-get install -y irqbalance ethtool || fatal "Failed to install irqbalance/ethtool."
    fi
    systemctl enable --now irqbalance >/dev/null 2>&1 || true

    # RPS/RFS/XPS: most VPS NICs (virtio) expose a single RX queue, so
    # without this all inbound packet processing (softirq) pins to CPU0 — a
    # PPS ceiling that exists before any sysctl tuning above even matters.
    NODE_NIC="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    if [[ -n "$NODE_NIC" ]]; then
        if [[ ! -f /usr/local/sbin/remnanode-rps-setup ]]; then
            cat > /usr/local/sbin/remnanode-rps-setup <<'RPSEOF'
#!/bin/bash
set -e
NIC="${1:-$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')}"
[ -z "$NIC" ] && exit 0
ncpu="$(nproc)"
mask="$(awk -v n="$ncpu" 'BEGIN{
    s=""; while(n>0){ b=(n>=32?32:n); n-=32;
        v=(b>=32?4294967295:(2^b)-1);
        s=(s==""?sprintf("%x",v):sprintf("%x,%s",v,s)); } print (s==""?"0":s) }')"
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
for q in /sys/class/net/"$NIC"/queues/rx-*; do
    [ -e "$q/rps_cpus" ] && echo "$mask" > "$q/rps_cpus" 2>/dev/null || true
    [ -e "$q/rps_flow_cnt" ] && echo 4096 > "$q/rps_flow_cnt" 2>/dev/null || true
done
for q in /sys/class/net/"$NIC"/queues/tx-*; do
    [ -e "$q/xps_cpus" ] && echo "$mask" > "$q/xps_cpus" 2>/dev/null || true
done
RPSEOF
            chmod +x /usr/local/sbin/remnanode-rps-setup
        fi
        if [[ ! -f /etc/systemd/system/remnanode-rps.service ]]; then
            cat > /etc/systemd/system/remnanode-rps.service <<'EOF'
[Unit]
Description=Remnanode RPS/RFS/XPS tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/remnanode-rps-setup

[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload
        systemctl enable --now remnanode-rps.service >/dev/null 2>&1 || true
        echo -e "${COLOR_GREEN}RPS/RFS/XPS enabled on $NODE_NIC ($(nproc) CPUs).${COLOR_RESET}"
    else
        error "Could not detect the default network interface — RPS/RFS/XPS and NIC tuning skipped."
    fi

    # NIC tuning: bigger ring buffers + offloads. ethtool clamps requests
    # above the driver's real max (typical for virtio-net), so asking for
    # 4096 is safe on smaller hardware too — it just won't be the ceiling on
    # NICs that support more.
    # Re-detects the interface on every boot (same as remnanode-rps-setup)
    # instead of baking $NODE_NIC into the unit at install time — otherwise
    # a later interface-name change (host migration, driver swap) would be
    # silently ignored, since an already-existing unit file is never
    # rewritten on a re-run.
    if [[ -n "$NODE_NIC" ]]; then
        if [[ ! -f /usr/local/sbin/remnanode-nic-tune-setup ]]; then
            cat > /usr/local/sbin/remnanode-nic-tune-setup <<'NICEOF'
#!/bin/bash
set -e
NIC="${1:-$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')}"
[ -z "$NIC" ] && exit 0
ethtool -G "$NIC" rx 4096 tx 4096 2>/dev/null || true
ethtool -K "$NIC" gro on gso on tso on 2>/dev/null || true
ethtool -K "$NIC" lro off 2>/dev/null || true
NICEOF
            chmod +x /usr/local/sbin/remnanode-nic-tune-setup
        fi
        if [[ ! -f /etc/systemd/system/remnanode-nic-tune.service ]]; then
            cat > /etc/systemd/system/remnanode-nic-tune.service <<'EOF'
[Unit]
Description=Remnanode NIC tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/remnanode-nic-tune-setup

[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload
        systemctl enable --now remnanode-nic-tune.service >/dev/null 2>&1 || true
        echo -e "${COLOR_GREEN}NIC tuning applied on $NODE_NIC (ring 4096, GRO/GSO/TSO on, LRO off).${COLOR_RESET}"
    fi

    # THP off. /sys/kernel/mm/transparent_hugepage/enabled is sysfs, not a
    # sysctl — sysctl.d only covers /proc/sys, so it resets to the kernel
    # default on every boot unless something re-applies it. A systemd oneshot
    # unit is the standard way to persist a sysfs value across reboots.
    if [[ ! -f /etc/systemd/system/remnanode-thp-off.service ]]; then
        cat > /etc/systemd/system/remnanode-thp-off.service <<'EOF'
[Unit]
Description=Remnanode disable Transparent Huge Pages
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    fi
    systemctl daemon-reload
    systemctl enable --now remnanode-thp-off.service >/dev/null 2>&1 || true
    echo -e "${COLOR_GREEN}Transparent Huge Pages disabled.${COLOR_RESET}"

    # CPU governor -> performance. Not all VPS expose cpufreq (many don't) —
    # skip cleanly when it's not there instead of failing.
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        if [[ ! -f /etc/systemd/system/remnanode-cpu-perf.service ]]; then
            cat > /etc/systemd/system/remnanode-cpu-perf.service <<'EOF'
[Unit]
Description=Remnanode CPU governor performance
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$c" 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload
        systemctl enable --now remnanode-cpu-perf.service >/dev/null 2>&1 || true
        echo -e "${COLOR_GREEN}CPU governor set to performance.${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}cpufreq not available (typical for VPS) — governor tuning skipped.${COLOR_RESET}"
    fi

    # journald cap. Unrelated to the docker-compose json-file logging above
    # (that only covers container stdout/stderr) — this caps the systemd
    # journal itself (docker.service, ufw, sshd, cron, kernel), which has no
    # size limit on this distro's defaults otherwise.
    mkdir -p /etc/systemd/journald.conf.d
    if [[ ! -f /etc/systemd/journald.conf.d/99-remnanode-size.conf ]]; then
        cat > /etc/systemd/journald.conf.d/99-remnanode-size.conf <<'EOL'
[Journal]
SystemMaxUse=300M
SystemKeepFree=500M
SystemMaxFileSize=50M
Compress=yes
EOL
    fi
    systemctl restart systemd-journald
    echo -e "${COLOR_GREEN}journald capped at 300M.${COLOR_RESET}"

    # Raise the open-file/process limits for all users at the PAM/login level.
    cat > /etc/security/limits.d/99-remnanode-nofile.conf <<'EOL'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOL

    # Raise the default fd/proc limits systemd hands to services it starts,
    # and apply it without a reboot. Low-impact if this fails or does
    # nothing — docker.service gets its own explicit override below regardless.
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-remnanode-nofile.conf <<'EOL'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOL
    systemctl daemon-reexec || true
    systemctl restart "user@$(id -u).service" 2>/dev/null || true

    # Docker's own fd/proc limit override (this is the one that actually
    # matters for the node/nginx containers) — written directly instead of
    # via the interactive 'systemctl edit docker.service'.
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/override.conf <<'EOL'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
EOL
    systemctl daemon-reload || fatal "systemctl daemon-reload failed."
    systemctl restart docker || fatal "Failed to restart docker after applying the nofile override."

    # Unattended upgrades
    echo 'Unattended-Upgrade::Mail "root";' >> /etc/apt/apt.conf.d/50unattended-upgrades
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades && systemctl restart unattended-upgrades || fatal "Failed to configure unattended-upgrades."

    mkdir -p "$NODE_DIR"
    echo -e "${COLOR_GREEN}Prerequisites installed successfully.${COLOR_RESET}"
}

# ---------------------------------------------------------------------------
# Step 2: Manage IPv6 (enable/disable on this node's host)
# OS-level network setting, unrelated to the node's domain/cert/containers —
# runs right after prerequisites, before anything is deployed on top of it.
# ---------------------------------------------------------------------------

# Writes into the same sysctl.d file step_install_prerequisites creates,
# rather than the legacy /etc/sysctl.conf — /etc/sysctl.d/*.conf is read
# before /etc/sysctl.conf by `sysctl --system` (what runs at boot), so this
# actually wins on reboot even if a provider image ships its own IPv6
# defaults elsewhere in /etc/sysctl.d/.
# `all` is documented as the authoritative master switch for every interface
# (current and future), so only all/default/lo need setting — no per-NIC
# line, and no need to detect which interface is the "real" one.
apply_ipv6_sysctl() {
    local value="$1"
    mkdir -p /etc/sysctl.d
    touch "$SYSCTL_TUNING_FILE"
    sed -i -E '/^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6/d' "$SYSCTL_TUNING_FILE"
    {
        echo "net.ipv6.conf.all.disable_ipv6 = $value"
        echo "net.ipv6.conf.default.disable_ipv6 = $value"
        echo "net.ipv6.conf.lo.disable_ipv6 = $value"
    } >> "$SYSCTL_TUNING_FILE"
    sysctl --system > /dev/null 2>&1
}

enable_ipv6() {
    if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}IPv6 is already enabled.${COLOR_RESET}"
        return 0
    fi

    echo -e "${COLOR_YELLOW}Enabling IPv6...${COLOR_RESET}"
    apply_ipv6_sysctl 0

    local current
    current=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [ "$current" = "0" ]; then
        echo -e "${COLOR_GREEN}IPv6 enabled (confirmed: net.ipv6.conf.all.disable_ipv6 = 0).${COLOR_RESET}"
    else
        error "IPv6 enable did not take effect (net.ipv6.conf.all.disable_ipv6 = ${current:-unknown}). Check $SYSCTL_TUNING_FILE manually."
    fi
}

disable_ipv6() {
    if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" -eq 1 ]; then
        echo -e "${COLOR_YELLOW}IPv6 is already disabled.${COLOR_RESET}"
        return 0
    fi

    echo -e "${COLOR_YELLOW}Disabling IPv6...${COLOR_RESET}"
    apply_ipv6_sysctl 1

    local current
    current=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [ "$current" = "1" ]; then
        echo -e "${COLOR_GREEN}IPv6 disabled (confirmed: net.ipv6.conf.all.disable_ipv6 = 1).${COLOR_RESET}"
    else
        error "IPv6 disable did not take effect (net.ipv6.conf.all.disable_ipv6 = ${current:-unknown}). Check $SYSCTL_TUNING_FILE manually."
    fi
}

step_manage_ipv6() {
    echo -e "${COLOR_GREEN}== Step: Manage IPv6 ==${COLOR_RESET}"
    check_root

    echo -e "${COLOR_YELLOW}1. Enable IPv6${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. Disable IPv6${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}0. Skip${COLOR_RESET}"
    reading "Choice:" IPV6_OPTION

    case "$IPV6_OPTION" in
        1) enable_ipv6 ;;
        2) disable_ipv6 ;;
        0) echo -e "${COLOR_YELLOW}Skipped.${COLOR_RESET}" ;;
        *) error "Invalid choice, skipping." ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 3: Issue / attach TLS certificate
# (Runs first — it owns the self-steal domain prompt; the config step below
#  reuses SELFSTEAL_DOMAIN/NODE_CERT_DOMAIN from state instead of asking again.)
# ---------------------------------------------------------------------------

step_setup_certificate() {
    echo -e "${COLOR_GREEN}== Step: TLS certificate ==${COLOR_RESET}"
    check_root
    load_state

    if [ -z "${SELFSTEAL_DOMAIN:-}" ]; then
        reading "Self-steal domain for this node (e.g. node1.example.com):" SELFSTEAL_DOMAIN
        check_domain "$SELFSTEAL_DOMAIN"
        [ $? -eq 2 ] && fatal "Aborted."
        save_state
    fi

    local base_domain
    base_domain=$(extract_domain "$SELFSTEAL_DOMAIN")
    local need_certificate=false

    if ! check_certificates "$SELFSTEAL_DOMAIN"; then
        need_certificate=true
    fi

    if [ "$need_certificate" = true ]; then
        echo -e ""
        echo -e "${COLOR_YELLOW}Choose certificate issuance method:${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}1. Cloudflare DNS-01 (wildcard, needs CF API token)${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ACME HTTP-01 (single domain, needs port 80 open)${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. Gcore DNS-01 (wildcard, needs Gcore API token)${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}0. Cancel${COLOR_RESET}"
        reading "Choice:" CERT_METHOD

        case "$CERT_METHOD" in
            0) fatal "Cancelled." ;;
            2|3) reading "Email for Let's Encrypt notifications:" LETSENCRYPT_EMAIL ;;
            1) : ;;
            *) fatal "Invalid choice." ;;
        esac

        local target_domain="$SELFSTEAL_DOMAIN"
        [[ "$CERT_METHOD" == "1" || "$CERT_METHOD" == "3" ]] && target_domain="$base_domain"

        get_certificates "$target_domain" "$CERT_METHOD" "${LETSENCRYPT_EMAIL:-}" || fatal "Certificate generation failed."
    else
        echo -e "${COLOR_GREEN}Valid certificate already present, skipping issuance.${COLOR_RESET}"
        CERT_METHOD="${CERT_METHOD:-1}"
    fi

    if [[ "$CERT_METHOD" == "1" || "$CERT_METHOD" == "3" ]] && [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
        NODE_CERT_DOMAIN="$base_domain"
    else
        NODE_CERT_DOMAIN="$SELFSTEAL_DOMAIN"
    fi

    # Weekly renewal cron. Method 2 (ACME standalone) needs nginx stopped
    # while certbot briefly binds port 80 itself — port 80 stays open in the
    # firewall permanently now (nginx's own HTTP redirect), so only the
    # container needs to step aside, not the UFW rule.
    local cron_command="/usr/bin/certbot renew --quiet"
    if [ "$CERT_METHOD" == "2" ]; then
        cron_command="docker stop nginx >/dev/null 2>&1; /usr/bin/certbot renew --quiet; certbot_status=\$?; docker start nginx >/dev/null 2>&1; exit \$certbot_status"
    fi
    if ! crontab -u root -l 2>/dev/null | grep -q "/usr/bin/certbot renew"; then
        add_cron_rule "0 5 * * 0 $cron_command"
    fi

    save_state
    echo -e "${COLOR_GREEN}Certificate ready (cert domain: $NODE_CERT_DOMAIN).${COLOR_RESET}"
}

# ---------------------------------------------------------------------------
# Step 4: Configure node & generate config files
# (panel IP, secret key, docker-compose.yml, nginx.conf — requires the TLS
#  certificate step to have run first, since it needs NODE_CERT_DOMAIN)
# ---------------------------------------------------------------------------

step_configure_node() {
    echo -e "${COLOR_GREEN}== Step: Configure node & generate config files ==${COLOR_RESET}"
    check_root
    load_state

    if [ -z "${SELFSTEAL_DOMAIN:-}" ] || [ -z "${NODE_CERT_DOMAIN:-}" ]; then
        fatal "Domain / certificate not set up yet. Run the 'Issue / attach TLS certificate' step first."
    fi

    mkdir -p "$NODE_DIR"
    cd "$NODE_DIR" || fatal "Cannot access $NODE_DIR"

    while true; do
        reading "Panel server IP (the IP the control panel connects from):" PANEL_IP
        if echo "$PANEL_IP" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null && \
           [[ $(echo "$PANEL_IP" | tr '.' '\n' | wc -l) -eq 4 ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -vE '^[0-9]{1,3}$') ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -E '^(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})$') ]]; then
            break
        else
            error "Invalid IPv4 address, try again."
        fi
    done

    echo -n "$(question "Paste the node secret key (SSL_CERT) from the panel, then press Enter twice:")"
    CERTIFICATE=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            [ -n "$CERTIFICATE" ] && break
        else
            CERTIFICATE="$CERTIFICATE$line\n"
        fi
    done

    reading "How many inbounds / WebSocket locations do you want on this node? [Enter = 1]:" WS_COUNT
    if [ -z "$WS_COUNT" ]; then
        WS_COUNT=1
    fi
    if ! [[ "$WS_COUNT" =~ ^[0-9]+$ ]] || [ "$WS_COUNT" -lt 1 ]; then
        error "Invalid number, defaulting to 1."
        WS_COUNT=1
    fi

    echo -e "${COLOR_YELLOW}Domain: $SELFSTEAL_DOMAIN | Cert domain: $NODE_CERT_DOMAIN | Panel IP: $PANEL_IP | Inbounds: $WS_COUNT${COLOR_RESET}"
    reading "Confirm and continue? (y/N):" confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || fatal "Aborted."

    # Written in one pass so reruns always produce a consistent file — no
    # append/duplicate-guard logic needed.
    cat > docker-compose.yml <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

services:
  nginx:
    image: nginx:latest
    container_name: nginx
    hostname: nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt/live/$NODE_CERT_DOMAIN/fullchain.pem:/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem:ro
      - /etc/letsencrypt/live/$NODE_CERT_DOMAIN/privkey.pem:/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=21
      - SECRET_KEY=$(echo -e "$CERTIFICATE")
    volumes:
      - /dev/shm:/dev/shm:rw
      - /etc/letsencrypt/live/$NODE_CERT_DOMAIN/fullchain.pem:/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem:ro
      - /etc/letsencrypt/live/$NODE_CERT_DOMAIN/privkey.pem:/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem:ro
      - /var/www/html:/var/www/html:ro
EOL

    # Main nginx config (replaces the image's built-in /etc/nginx/nginx.conf).
    # Generic, identical on every node — no per-node or SSL directives here.
    cat > nginx.conf <<EOL
user  nginx;
worker_processes  auto;
worker_rlimit_nofile 1048576;

error_log  /var/log/nginx/error.log notice;
pid        /run/nginx.pid;

events {
    worker_connections  65535;
    multi_accept on;
    use epoll;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;
    keepalive_timeout  65;
    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
}
EOL

    # One location block per requested inbound, each proxying to its own
    # xray unix socket (created by xray itself inside the remnanode
    # container, shared via the /dev/shm bind mount both containers use).
    # Inbound 1 uses the bare /ws path; extras are /ws2, /ws3, ...
    local ws_locations=""
    local i location_path
    for (( i=1; i<=WS_COUNT; i++ )); do
        location_path="/ws"
        [ "$i" -gt 1 ] && location_path="/ws$i"
        ws_locations+="    location $location_path {
        proxy_pass http://unix:/dev/shm/xray-ws$i.sock;
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

"
    done

    # Per-node server config: nginx terminates TLS directly on 443 (no more
    # unix-socket/proxy_protocol handoff), serves the camouflage site by
    # default, reverse-proxies the WS location(s) to xray, redirects plain
    # HTTP to HTTPS, and rejects the TLS handshake for any other SNI.
    cat > default.conf <<EOL
server_names_hash_bucket_size 64;
server_tokens off;
large_client_header_buffers 4 24k;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:50m;
ssl_session_tickets off;

server {
    listen 443 ssl backlog=65535;
    server_name $SELFSTEAL_DOMAIN;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";

    root /var/www/html;
    index index.html;

    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;

$ws_locations}

server {
    listen 80 default_server backlog=65535;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOL

    # Validate the generated config with a throwaway container before we
    # trust it — catches template bugs / bad cert paths right here instead
    # of finding out only when the real node fails to start later.
    if command -v docker >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}Validating nginx config...${COLOR_RESET}"
        local nginx_test_output
        if nginx_test_output=$(docker run --rm \
            -v "$NODE_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
            -v "$NODE_DIR/default.conf:/etc/nginx/conf.d/default.conf:ro" \
            -v "/etc/letsencrypt/live/$NODE_CERT_DOMAIN/fullchain.pem:/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem:ro" \
            -v "/etc/letsencrypt/live/$NODE_CERT_DOMAIN/privkey.pem:/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem:ro" \
            nginx:latest nginx -t 2>&1); then
            echo -e "${COLOR_GREEN}nginx config test passed.${COLOR_RESET}"
        else
            error "nginx config test FAILED — the node will not start correctly as-is:"
            echo "$nginx_test_output" >&2
        fi
    else
        error "Docker not found, skipping nginx config validation. Run the 'Install prerequisites' step first."
    fi

    save_state
    printf "${COLOR_GREEN}docker-compose.yml, nginx.conf and default.conf generated in %s (%s inbound(s)).${COLOR_RESET}\n" "$NODE_DIR" "$WS_COUNT"
}

# ---------------------------------------------------------------------------
# Step 5: Deploy camouflage website template
# ---------------------------------------------------------------------------

step_deploy_template() {
    echo -e "${COLOR_GREEN}== Step: Deploy camouflage website template ==${COLOR_RESET}"
    check_root

    echo -e "${COLOR_YELLOW}Choose a template source:${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}1. Simple web templates${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. SNI templates${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. Nothing (blank/SNI-only) templates${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. Random${COLOR_RESET}"
    reading "Choice:" template_choice

    local template_urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"
        "https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"
    )
    local selected_url
    case "$template_choice" in
        1) selected_url="${template_urls[0]}" ;;
        2) selected_url="${template_urls[1]}" ;;
        3) selected_url="${template_urls[2]}" ;;
        *) selected_url="${template_urls[$RANDOM % ${#template_urls[@]}]}" ;;
    esac

    cd /opt/ || fatal "Cannot access /opt"
    rm -f main.zip 2>/dev/null
    rm -rf simple-web-templates-main/ sni-templates-main/ nothing-sni-main/ 2>/dev/null

    echo -e "${COLOR_YELLOW}Downloading template...${COLOR_RESET}"
    ( while ! wget -q --timeout=30 --tries=10 --retry-connrefused "$selected_url"; do sleep 3; done ) &
    spinner $! "Downloading..."
    wait

    unzip -o main.zip &>/dev/null || fatal "Failed to unpack template archive."
    rm -f main.zip

    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        cd simple-web-templates-main/ || fatal "Unpack error."
        rm -rf assets ".gitattributes" "README.md" "_config.yml" 2>/dev/null
    elif [[ "$selected_url" == *"nothing-sni"* ]]; then
        cd nothing-sni-main/ || fatal "Unpack error."
        rm -rf .github README.md 2>/dev/null
    else
        cd sni-templates-main/ || fatal "Unpack error."
        rm -rf assets "README.md" "index.html" 2>/dev/null
    fi

    local RandomHTML
    if [[ "$selected_url" == *"nothing-sni"* ]]; then
        RandomHTML="$((RANDOM % 8 + 1)).html"
    else
        mapfile -t templates < <(find . -maxdepth 1 -type d -not -path . | sed 's|./||')
        RandomHTML="${templates[$RANDOM % ${#templates[@]}]}"
    fi

    if [[ "$selected_url" == *"distillium"* && "$RandomHTML" == "503 error pages" ]]; then
        cd "$RandomHTML" || fatal "Unpack error."
        local versions=("v1" "v2")
        RandomHTML="$RandomHTML/${versions[$RANDOM % ${#versions[@]}]}"
        cd ..
    fi

    # Light fingerprint randomization to avoid a static, recognizable template
    local random_meta_id random_comment random_class_suffix random_title_suffix random_footer_text random_id_suffix
    random_meta_id=$(openssl rand -hex 16)
    random_comment=$(openssl rand -hex 8)
    random_class_suffix=$(openssl rand -hex 4)
    random_title_suffix=$(openssl rand -hex 4)
    random_footer_text="Designed by RandomSite_${random_title_suffix}"
    random_id_suffix=$(openssl rand -hex 4)
    local random_meta_name="page-id"
    local random_class="style-${random_class_suffix}"
    local random_title="Page_${random_title_suffix}"

    find "./$RandomHTML" -type f -name "*.html" -exec sed -i \
        -e "s|<!-- Website template by freewebsitetemplates.com -->||" \
        -e "s|<!-- Theme by: WebThemez.com -->||" \
        -e "s|<a href=\"http://freewebsitetemplates.com\">Free Website Templates</a>|<span>${random_footer_text}</span>|" \
        -e "s|<a href=\"http://webthemez.com\" alt=\"webthemez\">WebThemez.com</a>|<span>${random_footer_text}</span>|" \
        -e "s|id=\"Content\"|id=\"rnd_${random_id_suffix}\"|" \
        -e "s|id=\"subscribe\"|id=\"sub_${random_id_suffix}\"|" \
        -e "s|<title>.*</title>|<title>${random_title}</title>|" \
        -e "s/<\/head>/<meta name=\"$random_meta_name\" content=\"$random_meta_id\">\n<!-- $random_comment -->\n<\/head>/" \
        -e "s/<body/<body class=\"$random_class\"/" \
        {} \;

    find "./$RandomHTML" -type f -name "*.css" -exec sed -i \
        -e "1i\\/* $random_comment */" \
        -e "1i.$random_class { display: block; }" \
        {} \;

    echo -e "${COLOR_GREEN}Selected template: ${RandomHTML}${COLOR_RESET}"

    mkdir -p /var/www/html
    rm -rf /var/www/html/*
    if [[ -d "${RandomHTML}" ]]; then
        cp -a "${RandomHTML}"/. "/var/www/html/"
    elif [[ -f "${RandomHTML}" ]]; then
        cp "${RandomHTML}" "/var/www/html/index.html"
    else
        fatal "Template not found after unpacking."
    fi

    cd /opt/
    rm -rf simple-web-templates-main/ sni-templates-main/ nothing-sni-main/

    echo -e "${COLOR_GREEN}Camouflage website deployed to /var/www/html.${COLOR_RESET}"
}

# ---------------------------------------------------------------------------
# Step 6: Configure firewall & start node
# ---------------------------------------------------------------------------

step_start_node() {
    echo -e "${COLOR_GREEN}== Step: Configure firewall & start node ==${COLOR_RESET}"
    check_root
    load_state
    require_var PANEL_IP "Panel server IP:"
    [ -f "$NODE_DIR/docker-compose.yml" ] || fatal "docker-compose.yml not found. Run the earlier steps first."

    ufw allow from "$PANEL_IP" to any port 21 > /dev/null 2>&1
    ufw reload > /dev/null 2>&1

    echo -e "${COLOR_YELLOW}Starting node containers...${COLOR_RESET}"
    cd "$NODE_DIR" || fatal "Cannot access $NODE_DIR"
    docker compose up -d > /dev/null 2>&1 &
    spinner $! "Starting..."
    wait

    echo -e "${COLOR_GREEN}Node containers started.${COLOR_RESET}"
}

# ---------------------------------------------------------------------------
# Step 7: Health check (last step of a full install)
# ---------------------------------------------------------------------------

step_health_check() {
    echo -e "${COLOR_GREEN}== Step: Health check ==${COLOR_RESET}"
    load_state
    require_var SELFSTEAL_DOMAIN "Self-steal domain to check:"

    printf "${COLOR_YELLOW}Checking that %s responds over HTTPS...${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN"
    local max_attempts=5
    local attempt=1
    local delay=15

    while [ $attempt -le $max_attempts ]; do
        printf "${COLOR_YELLOW}Attempt %s/%s...${COLOR_RESET}\n" "$attempt" "$max_attempts"
        if curl -s --fail --max-time 10 "https://$SELFSTEAL_DOMAIN" | grep -q "html"; then
            echo -e "${COLOR_GREEN}Node is up and responding.${COLOR_RESET}"
            return 0
        else
            error "Not reachable yet (attempt $attempt)."
            if [ $attempt -eq $max_attempts ]; then
                error "Node did not respond after $max_attempts attempts. Check docker logs and firewall rules."
                return 1
            fi
            sleep $delay
        fi
        ((attempt++))
    done
}

# ---------------------------------------------------------------------------
# Destructive step: Uninstall / reinstall node
# ---------------------------------------------------------------------------

step_uninstall_node() {
    echo -e "${COLOR_RED}== DESTRUCTIVE: Uninstall / reinstall node ==${COLOR_RESET}"
    check_root

    if [ ! -d "$NODE_DIR" ]; then
        error "$NODE_DIR does not exist, nothing to remove."
        return 1
    fi

    echo -e "${COLOR_RED}This will STOP and REMOVE the node's Docker containers, volumes and images${COLOR_RESET}"
    echo -e "${COLOR_RED}(as defined in $NODE_DIR/docker-compose.yml), then DELETE $NODE_DIR entirely,${COLOR_RESET}"
    echo -e "${COLOR_RED}including the saved domain/IP/certificate state.${COLOR_RESET}"
    echo -e "${COLOR_RED}It will also remove the host-level tuning applied by 'Install prerequisites'${COLOR_RESET}"
    echo -e "${COLOR_RED}(sysctl, nofile/nproc limits, systemd overrides) — including the IPv6${COLOR_RESET}"
    echo -e "${COLOR_RED}enable/disable switch from step 4, since it lives in the same sysctl file.${COLOR_RESET}"
    echo -e "${COLOR_RED}UFW rules and ufw-docker are NOT touched (avoids risking an SSH lockout).${COLOR_RESET}"
    echo -e "${COLOR_RED}Camouflage files in /var/www/html WILL be deleted (a fresh reinstall replaces them anyway).${COLOR_RESET}"
    echo -e "${COLOR_RED}TLS certificates in /etc/letsencrypt are NOT removed.${COLOR_RESET}"
    echo -e ""
    reading "Type y to confirm removal (y/N):" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${COLOR_YELLOW}Cancelled.${COLOR_RESET}"
        return 0
    fi

    if [ -f "$NODE_DIR/docker-compose.yml" ]; then
        cd "$NODE_DIR" || fatal "Cannot access $NODE_DIR"
        docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1 &
        spinner $! "Removing containers..."
        wait
    fi

    rm -rf "$NODE_DIR"
    echo -e "${COLOR_GREEN}$NODE_DIR removed.${COLOR_RESET}"

    rm -rf /var/www/html
    echo -e "${COLOR_GREEN}/var/www/html removed.${COLOR_RESET}"

    # Host-level tuning from 'Install prerequisites' (step 3) — the
    # counterpart of everything that step writes. SYSCTL_TUNING_FILE also
    # holds the IPv6 switch from step 4 (net.ipv6.conf.*.disable_ipv6) —
    # removing the whole file reverts that too, confirmed acceptable rather
    # than splitting the file by marker. UFW/ufw-docker deliberately left
    # alone — not exclusively the node's to own, and pulling the SSH allow
    # rule while UFW is active risks locking out the next connection.
    echo -e "${COLOR_YELLOW}Removing host-level tuning from 'Install prerequisites'...${COLOR_RESET}"
    rm -f "$SYSCTL_TUNING_FILE"
    rm -f /etc/security/limits.d/99-remnanode-nofile.conf
    rm -f /etc/systemd/system.conf.d/99-remnanode-nofile.conf
    rm -f /etc/systemd/system/docker.service.d/override.conf
    rm -f /etc/modules-load.d/remnanode-bbr.conf
    rm -f /etc/systemd/journald.conf.d/99-remnanode-size.conf

    for svc in remnanode-rps remnanode-nic-tune remnanode-thp-off remnanode-cpu-perf; do
        systemctl disable --now "${svc}.service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${svc}.service"
    done
    rm -f /usr/local/sbin/remnanode-rps-setup
    rm -f /usr/local/sbin/remnanode-nic-tune-setup

    systemctl daemon-reload >/dev/null 2>&1 || true
    # daemon-reexec (not just daemon-reload): DefaultLimitNOFILE/NPROC in the
    # system.conf.d file just removed are Manager-level settings, applied the
    # same way step 3 applies them when writing that file.
    systemctl daemon-reexec >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    systemctl restart systemd-journald >/dev/null 2>&1 || true

    echo -e "${COLOR_YELLOW}Note: kernel state already applied this boot (BBR, RPS masks, THP=never,${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}CPU governor, ring buffers) is not reverted live — removing the sysctl.d/${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}systemd files only stops them from reapplying after the next reboot.${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Docker's fd/proc limit override was removed but docker.service was not${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}restarted here (would restart every OTHER container on this host too) —${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}it takes effect on Docker's next restart/reboot.${COLOR_RESET}"
    echo -e "${COLOR_GREEN}Host-level tuning removed.${COLOR_RESET}"

    echo -e ""
    echo -e "${COLOR_RED}Optionally, 'docker system prune -a --volumes -f' removes ALL unused Docker images,${COLOR_RESET}"
    echo -e "${COLOR_RED}containers and volumes on this host, including ones from OTHER stacks if any.${COLOR_RESET}"
    reading "Run a full Docker system prune too? (y/N):" prune_confirm
    if [[ "$prune_confirm" == "y" || "$prune_confirm" == "Y" ]]; then
        docker system prune -a --volumes -f > /dev/null 2>&1 &
        spinner $! "Pruning Docker..."
        wait
        echo -e "${COLOR_GREEN}Docker system pruned.${COLOR_RESET}"
    fi

    echo -e "${COLOR_GREEN}Node removed. Run option 1 (or the individual steps) to reinstall.${COLOR_RESET}"
}

# ---------------------------------------------------------------------------
# Full installation (English) — runs all steps in order
# ---------------------------------------------------------------------------

full_install() {
    echo -e "${COLOR_GREEN}========================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN} Remnawave Node — Full Installation${COLOR_RESET}"
    echo -e "${COLOR_GREEN}========================================${COLOR_RESET}"

    step_system_upgrade
    step_install_prerequisites
    step_manage_ipv6
    step_setup_certificate
    step_configure_node
    step_deploy_template
    step_start_node
    step_health_check

    echo -e "${COLOR_GREEN}========================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN} Node installation complete.${COLOR_RESET}"
    echo -e "${COLOR_GREEN}========================================${COLOR_RESET}"
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

show_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}Remnawave Node Installer (Nginx)${COLOR_RESET}"
    echo -e "${COLOR_GRAY}Working directory: $NODE_DIR${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. Full node installation${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}2. Step: System update & upgrade (apt update && upgrade)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. Step: Install prerequisites (Docker, certbot, UFW, ufw-docker, packages)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. Step: Manage IPv6 (enable/disable)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. Step: Issue / attach TLS certificate${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}6. Step: Configure node & generate config files (panel IP, secret key, docker-compose.yml, nginx.conf)${COLOR_RESET}"
    echo -e "${COLOR_GRAY}   (needs step 5 done first)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}7. Step: Deploy camouflage website template${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}8. Step: Configure firewall & start node${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}9. Step: Health check${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_RED}10. Uninstall / reinstall node (destructive)${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. Exit${COLOR_RESET}"
    echo -e ""
}

main() {
    while true; do
        show_menu
        reading "Choice:" OPTION
        case "$OPTION" in
            1) full_install ;;
            2) step_system_upgrade ;;
            3) step_install_prerequisites ;;
            4) step_manage_ipv6 ;;
            5) step_setup_certificate ;;
            6) step_configure_node ;;
            7) step_deploy_template ;;
            8) step_start_node ;;
            9) step_health_check ;;
            10) step_uninstall_node ;;
            0) echo -e "${COLOR_YELLOW}Bye.${COLOR_RESET}"; exit 0 ;;
            *) error "Invalid choice." ;;
        esac
    done
}

main "$@"
