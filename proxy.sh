#!/usr/bin/env bash

set -euo pipefail

#############################################
# Squid Forward Proxy Setup Script v5.0.0
# Faster install path for small Debian/Ubuntu servers.
#
# Strategy:
# - Prefer distro package install via apt
# - Keep source build as explicit opt-in fallback
# - Only create swap for source builds on small systems
#############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

DEFAULT_PORT=3128
SCRIPT_REV="v5.0.0"
DEFAULT_SQUID_SERIES="v7"
DEFAULT_SQUID_VERSION="7.0.0-20250103-rb56774dd09"
DEFAULT_SQUID_TARBALL_EXT="gz"
SQUID_PREFIX="/usr/local/squid"
SQUID_LIBEXEC="/usr/local/squid/libexec"
SQUID_ETC_DIR="/etc/squid"
SQUID_LOG_DIR="/var/log/squid"
SQUID_SPOOL_DIR="/var/spool/squid"
SQUID_SRC_DIR="/usr/local/src/squid-build"
SQUID_PASSWD_FILE="/etc/squid/passwd"

SERVER_IP=""
OS=""
CODENAME=""
PRETTY=""
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
HTTP_PORT="${HTTP_PORT:-$DEFAULT_PORT}"
SQUID_WORKERS="1"
RECOMMENDED_CONCURRENCY="80"
BUILD_JOBS="1"
AUTH_CHILDREN="20 startup=10 idle=5"
SQUID_VERSION="${SQUID_VERSION:-$DEFAULT_SQUID_VERSION}"
SQUID_SERIES="${SQUID_SERIES:-$DEFAULT_SQUID_SERIES}"
SQUID_TARBALL_EXT="${SQUID_TARBALL_EXT:-$DEFAULT_SQUID_TARBALL_EXT}"
ENABLE_JEMALLOC="${ENABLE_JEMALLOC:-0}"
AUTO_YES="${AUTO_YES:-0}"
TARGET_NF_CONNTRACK_MAX="262144"
ACTUAL_SQUID_VERSION=""
INSTALL_METHOD="${INSTALL_METHOD:-auto}"
CHOSEN_INSTALL_METHOD=""
TOTAL_RAM_MB="1024"

if [ -t 0 ] && [ -t 1 ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    TTY_AVAILABLE=1
else
    TTY_AVAILABLE=0
fi

print_header() {
    if [ "$INTERACTIVE" -eq 1 ]; then
        clear || true
    fi
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo -e "${CYAN}|${NC} ${BOLD}Squid Forward Proxy Setup ${SCRIPT_REV}${NC}             ${CYAN}|${NC}"
    echo -e "${CYAN}|${NC} ${BOLD}Fast path: apt-first, source fallback${NC}           ${CYAN}|${NC}"
    echo -e "${CYAN}+--------------------------------------------------+${NC}"
    echo ""
}

print_separator() { echo -e "${BLUE}--------------------------------------------------${NC}"; }
print_success()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_error()     { echo -e "${RED}[ERR]${NC} $1"; }
print_warning()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_info()      { echo -e "${CYAN}[INFO]${NC} $1"; }

error_exit() {
    print_error "$1"
    exit 1
}

run_step() {
    local step_name="$1"
    shift

    "$@"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        error_exit "Step failed: $step_name (exit $rc)"
    fi
}

run_logged_command() {
    local label="$1"
    local logfile="$2"
    shift 2

    : > "$logfile"
    "$@" > "$logfile" 2>&1 &
    local cmd_pid=$!
    local start_ts=$SECONDS
    local last_size=0

    while kill -0 "$cmd_pid" 2>/dev/null; do
        sleep 5

        local elapsed=$(( SECONDS - start_ts ))
        local current_size=0
        if [ -f "$logfile" ]; then
            current_size=$(wc -c < "$logfile" 2>/dev/null || printf '0')
        fi

        if [ "$current_size" -gt "$last_size" ]; then
            printf "\r%s... %ss elapsed, log growing (%s bytes)" "$label" "$elapsed" "$current_size"
            last_size=$current_size
        else
            printf "\r%s... %ss elapsed, still running        " "$label" "$elapsed"
        fi
    done

    wait "$cmd_pid"
    local rc=$?
    local total_elapsed=$(( SECONDS - start_ts ))
    printf "\r"

    if [ "$rc" -ne 0 ]; then
        print_error "$label failed after ${total_elapsed}s. See $logfile"
        echo ""
        echo "Last 40 log lines:"
        tail -n 40 "$logfile" || true
        return "$rc"
    fi

    print_success "Done (${total_elapsed}s)"
}

read_proc_value() {
    local path="$1"

    if [ -r "$path" ]; then
        tr -d '[:space:]' < "$path"
        return 0
    fi

    return 1
}

verify_conntrack_tuning() {
    local current_max
    local current_count
    local current_buckets

    current_max=$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_max || true)
    current_count=$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_count || true)
    current_buckets=$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_buckets || true)

    if ! [[ "$current_max" =~ ^[0-9]+$ ]]; then
        error_exit "Could not read live nf_conntrack_max after sysctl apply"
    fi

    print_info "Live conntrack values: max=$current_max count=${current_count:-unknown} buckets=${current_buckets:-unknown}"

    if [ "$current_max" -lt "$TARGET_NF_CONNTRACK_MAX" ]; then
        error_exit "nf_conntrack_max stayed at $current_max (expected at least $TARGET_NF_CONNTRACK_MAX). Check sysctl output above."
    fi
}

prompt_read() {
    local prompt="$1"
    local var_name="$2"

    if [ "$TTY_AVAILABLE" -eq 1 ]; then
        read -r -p "$prompt" "$var_name" < /dev/tty
    else
        read -r -p "$prompt" "$var_name"
    fi
}

generate_hex_token() {
    local bytes="$1"

    if command -v openssl > /dev/null 2>&1; then
        openssl rand -hex "$bytes"
        return 0
    fi

    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

ensure_proxy_credentials() {
    if [ -z "$PROXY_USER" ]; then
        PROXY_USER="u$(generate_hex_token 4)"
        print_info "Generated proxy username automatically"
    fi

    if [ -z "$PROXY_PASS" ]; then
        PROXY_PASS="$(generate_hex_token 24)"
        print_info "Generated strong proxy password automatically"
    fi
}

check_root() {
    if [ "${EUID}" -ne 0 ]; then
        error_exit "This script must be run as root. Use: sudo bash $0"
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        CODENAME="${VERSION_CODENAME:-}"
        PRETTY="${PRETTY_NAME:-$ID}"
    else
        error_exit "Cannot detect OS. Supports Debian/Ubuntu only."
    fi

    case "$OS" in
        ubuntu|debian)
            print_success "$PRETTY detected"
            ;;
        *)
            error_exit "Unsupported OS: $OS"
            ;;
    esac
}

detect_network() {
    print_separator
    echo -e "${BOLD}Detecting network environment...${NC}"
    echo ""

    SERVER_IP=$(curl -fsS -4 --max-time 5 ifconfig.me 2>/dev/null || \
                curl -fsS -4 --max-time 5 icanhazip.com 2>/dev/null || \
                curl -fsS -4 --max-time 5 ipinfo.io/ip 2>/dev/null || true)

    if [ -z "$SERVER_IP" ]; then
        error_exit "Could not detect public IP address"
    fi

    print_success "Public IP: $SERVER_IP"
    echo ""
}

choose_capacity_defaults() {
    TOTAL_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2; exit}' || true)
    if ! [[ "$TOTAL_RAM_MB" =~ ^[0-9]+$ ]]; then
        TOTAL_RAM_MB=1024
    fi

    local cpu_count
    cpu_count=$(nproc 2>/dev/null || true)
    if ! [[ "$cpu_count" =~ ^[0-9]+$ ]]; then
        cpu_count=1
    fi

    if [ "$TOTAL_RAM_MB" -le 1024 ]; then
        SQUID_WORKERS=1
        RECOMMENDED_CONCURRENCY=80
        BUILD_JOBS=1
        AUTH_CHILDREN="20 startup=10 idle=5"
    elif [ "$TOTAL_RAM_MB" -le 2048 ]; then
        SQUID_WORKERS=2
        RECOMMENDED_CONCURRENCY=150
        BUILD_JOBS=1
        AUTH_CHILDREN="16 startup=4 idle=2"
    elif [ "$TOTAL_RAM_MB" -le 4096 ]; then
        SQUID_WORKERS=3
        RECOMMENDED_CONCURRENCY=250
        BUILD_JOBS=$(( cpu_count > 2 ? 2 : cpu_count ))
        AUTH_CHILDREN="32 startup=8 idle=4"
    else
        SQUID_WORKERS=4
        RECOMMENDED_CONCURRENCY=400
        BUILD_JOBS=$(( cpu_count > 4 ? 4 : cpu_count ))
        AUTH_CHILDREN="64 startup=16 idle=8"
    fi

    if [ "$BUILD_JOBS" -lt 1 ]; then
        BUILD_JOBS=1
    fi
}

supports_apt_install() {
    case "$OS" in
        ubuntu|debian) return 0 ;;
        *) return 1 ;;
    esac
}

choose_install_method() {
    case "$INSTALL_METHOD" in
        apt|source)
            CHOSEN_INSTALL_METHOD="$INSTALL_METHOD"
            ;;
        auto)
            if supports_apt_install; then
                CHOSEN_INSTALL_METHOD="apt"
            else
                CHOSEN_INSTALL_METHOD="source"
            fi
            ;;
        *)
            error_exit "INSTALL_METHOD must be one of: auto, apt, source"
            ;;
    esac
}

get_user_input() {
    print_separator
    echo -e "${BOLD}Configuration${NC}"
    echo ""

    ensure_proxy_credentials

    if ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$HTTP_PORT" -lt 1024 ] || [ "$HTTP_PORT" -gt 65535 ]; then
        if [ "$INTERACTIVE" -eq 1 ]; then
            while true; do
                if ! prompt_read "HTTP port [$DEFAULT_PORT]: " HTTP_PORT; then
                    error_exit "Input stream closed while reading port"
                fi
                HTTP_PORT=${HTTP_PORT:-$DEFAULT_PORT}
                if [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && [ "$HTTP_PORT" -ge 1024 ] && [ "$HTTP_PORT" -le 65535 ]; then
                    break
                fi
                print_error "Invalid port. Must be 1024-65535"
            done
        else
            error_exit "HTTP_PORT must be a valid integer between 1024-65535"
        fi
    fi

    echo ""
    echo -e "${BOLD}Installation Summary:${NC}"
    echo ""
    echo "  Server IP              : $SERVER_IP"
    echo "  Username               : $PROXY_USER"
    echo "  Password               : auto-generated"
    echo "  Port                   : $HTTP_PORT"
    echo "  Squid workers          : $SQUID_WORKERS"
    echo "  Auth children          : $AUTH_CHILDREN"
    echo "  RAM detected           : ${TOTAL_RAM_MB} MB"
    if [ "$CHOSEN_INSTALL_METHOD" = "apt" ]; then
        echo "  Install method         : apt package (fast path)"
        echo "  Expected duration      : short, network-bound"
    else
        echo "  Install method         : source compile (fallback/opt-in)"
        echo "  Pinned Squid release   : ${SQUID_SERIES}/${SQUID_VERSION}.tar.${SQUID_TARBALL_EXT}"
        echo "  Build jobs             : $BUILD_JOBS"
        echo "  Expected duration      : slow on small servers"
    fi
    if [ "$ENABLE_JEMALLOC" = "1" ]; then
        echo "  jemalloc preload       : enabled (opt-in)"
    else
        echo "  jemalloc preload       : disabled (default)"
    fi
    echo "  DNS                    : 1.1.1.1 8.8.8.8 8.8.4.4"
    echo "  Recommended concurrency: $RECOMMENDED_CONCURRENCY"
    echo ""

    if [ "$AUTO_YES" = "1" ]; then
        print_info "AUTO_YES=1 set, proceeding without confirmation"
    elif [ "$INTERACTIVE" -eq 1 ]; then
        if [ "$TTY_AVAILABLE" -eq 1 ]; then
            read -r -p "Proceed? (y/n): " -n 1 REPLY < /dev/tty || {
                echo ""
                error_exit "Input stream closed while waiting for confirmation"
            }
        elif ! read -r -p "Proceed? (y/n): " -n 1 REPLY; then
            echo ""
            error_exit "Input stream closed while waiting for confirmation"
        fi
        echo ""
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            exit 0
        fi
    else
        error_exit "Non-interactive mode requires AUTO_YES=1"
    fi
    echo ""
}

setup_swap_if_needed() {
    if [ "$CHOSEN_INSTALL_METHOD" != "source" ]; then
        print_info "Skipping swap setup on apt install path"
        return 0
    fi

    if [ "$TOTAL_RAM_MB" -gt 2048 ]; then
        print_info "Skipping swap setup: source build has sufficient RAM"
        return 0
    fi

    print_separator
    echo -e "${BOLD}Configuring swap for source build...${NC}"
    echo ""

    if swapon --show | grep -q .; then
        print_success "Swap already exists"
    else
        echo -n "Creating 2GB swap file... "
        if fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 > /dev/null 2>&1; then
            chmod 600 /swapfile
            mkswap /swapfile > /dev/null 2>&1
            swapon /swapfile
            grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            print_success "2GB swap enabled"
        else
            print_warning "Swap creation failed; continuing"
        fi
    fi

    sysctl -w vm.swappiness=10 > /dev/null 2>&1 || true
    echo ""
}

install_prerequisites() {
    print_separator
    echo -e "${BOLD}Installing base prerequisites...${NC}"
    echo ""

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        apache2-utils ca-certificates curl openssl \
        ufw conntrack

    if [ "$ENABLE_JEMALLOC" = "1" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libjemalloc2
        print_success "Optional jemalloc package installed"
    else
        print_info "Skipping jemalloc package install (default: disabled)"
    fi

    print_success "Base prerequisites installed"
    echo ""
}

install_squid_apt() {
    print_separator
    echo -e "${BOLD}Installing Squid via apt (fast path)...${NC}"
    echo ""

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq squid

    local squid_bin
    squid_bin=$(command -v squid 2>/dev/null || true)
    if [ -z "$squid_bin" ]; then
        error_exit "squid binary not found after apt install"
    fi

    local squid_ver
    squid_ver=$("$squid_bin" -v 2>&1 | head -1 || true)
    ACTUAL_SQUID_VERSION="$squid_ver"

    SQUID_PREFIX="/usr"
    SQUID_LIBEXEC="/usr/lib/squid"
    if [ ! -x "$SQUID_LIBEXEC/basic_ncsa_auth" ] && [ -x "/usr/libexec/squid/basic_ncsa_auth" ]; then
        SQUID_LIBEXEC="/usr/libexec/squid"
    fi

    print_success "Installed: $squid_ver"
    print_info "Binary: $squid_bin"
    echo ""
}

validate_pinned_release() {
    if [ -z "$SQUID_SERIES" ] || [ -z "$SQUID_VERSION" ] || [ -z "$SQUID_TARBALL_EXT" ]; then
        error_exit "Invalid Squid pin configuration"
    fi

    local test_url
    local probe_output
    local effective_url
    local content_type
    local http_code
    test_url="https://www.squid-cache.org/Versions/${SQUID_SERIES}/squid-${SQUID_VERSION}.tar.${SQUID_TARBALL_EXT}"

    probe_output=$(curl -fsSLI -o /dev/null -w '%{url_effective}\n%{content_type}\n%{http_code}\n' "$test_url") || {
        error_exit "Pinned Squid tarball not found: $test_url"
    }

    effective_url=$(printf '%s\n' "$probe_output" | sed -n '1p')
    content_type=$(printf '%s\n' "$probe_output" | sed -n '2p')
    http_code=$(printf '%s\n' "$probe_output" | sed -n '3p')

    if [ "$http_code" != "200" ]; then
        error_exit "Pinned Squid tarball returned HTTP $http_code: $test_url"
    fi

    if [ "$effective_url" != "$test_url" ]; then
        error_exit "Pinned Squid tarball redirected unexpectedly: $effective_url"
    fi

    case "$content_type" in
        application/*|binary/*)
            ;;
        *)
            error_exit "Pinned Squid tarball returned unexpected content type '$content_type'"
            ;;
    esac
}

build_squid_from_source() {
    print_separator
    echo -e "${BOLD}Building Squid from source...${NC}"
    echo ""

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential pkg-config perl m4 \
        libssl-dev libexpat1-dev libxml2-dev \
        zlib1g-dev libcppunit-dev libecap3-dev \
        libdb-dev libsasl2-dev libldap2-dev libpam0g-dev \
        xz-utils tar

    validate_pinned_release
    print_info "Using pinned Squid release: $SQUID_VERSION ($SQUID_SERIES, tar.$SQUID_TARBALL_EXT)"

    mkdir -p "$SQUID_SRC_DIR"
    rm -rf "$SQUID_SRC_DIR"/*

    local tarball="squid-${SQUID_VERSION}.tar.${SQUID_TARBALL_EXT}"
    local url="https://www.squid-cache.org/Versions/${SQUID_SERIES}/${tarball}"

    echo -n "Downloading ${tarball}... "
    curl -fsSL "$url" -o "$SQUID_SRC_DIR/$tarball"
    print_success "Done"

    local source_dir="$SQUID_SRC_DIR/source"
    rm -rf "$source_dir"
    mkdir -p "$source_dir"

    tar -xf "$SQUID_SRC_DIR/$tarball" -C "$source_dir" --strip-components=1

    if [ ! -x "$source_dir/configure" ]; then
        error_exit "Expected configure script not found after extraction: $source_dir/configure"
    fi

    cd "$source_dir"

    echo -n "Configuring build... "
    run_logged_command "Configuring build" "/tmp/squid-configure.log" ./configure \
        --prefix="$SQUID_PREFIX" \
        --sysconfdir="$SQUID_ETC_DIR" \
        --localstatedir=/var \
        --libexecdir="$SQUID_PREFIX/libexec" \
        --with-default-user=proxy \
        --with-openssl \
        --enable-auth-basic=NCSA \
        --disable-translation \
        --with-filedescriptors=100000

    echo -n "Compiling (jobs=$BUILD_JOBS)... "
    run_logged_command "Compiling (jobs=$BUILD_JOBS)" "/tmp/squid-build.log" make -j"$BUILD_JOBS"

    echo -n "Installing... "
    run_logged_command "Installing" "/tmp/squid-install.log" make install

    SQUID_LIBEXEC="$SQUID_PREFIX/libexec"
    ACTUAL_SQUID_VERSION=$("$SQUID_PREFIX/sbin/squid" -v 2>&1 | head -1 || true)
    print_success "Installed Squid ${SQUID_VERSION} at ${SQUID_PREFIX}"
    echo ""
}

stop_old_squid() {
    print_separator
    echo -e "${BOLD}Stopping old proxy services...${NC}"
    echo ""

    systemctl stop squid > /dev/null 2>&1 || true
    systemctl disable squid > /dev/null 2>&1 || true
    systemctl reset-failed squid > /dev/null 2>&1 || true

    pkill -TERM -x squid > /dev/null 2>&1 || true
    sleep 2
    pkill -KILL -x squid > /dev/null 2>&1 || true

    rm -f /run/squid.pid /run/squid/squid.pid

    print_success "Old squid processes stopped"
    echo ""
}

configure_dns() {
    print_separator
    echo -e "${BOLD}Configuring public DNS (1.1.1.1 / 8.8.8.8)...${NC}"
    echo ""

    local dns1="1.1.1.1"
    local dns2="8.8.8.8"
    local dns3="8.8.4.4"
    local configured=0

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        local resolved_conf="/etc/systemd/resolved.conf.d/squid-proxy-dns.conf"
        mkdir -p "$(dirname "$resolved_conf")"
        cat > "$resolved_conf" <<EOF
[Resolve]
DNS=$dns1 $dns2 $dns3
FallbackDNS=
DNSStubListener=yes
EOF
        systemctl restart systemd-resolved
        print_success "systemd-resolved configured with $dns1 $dns2 $dns3"
        configured=1
    fi

    local resolv_conf="/etc/resolv.conf"
    if [ -L "$resolv_conf" ] && [ "$configured" -eq 1 ]; then
        if resolvectl dns 2>/dev/null | grep -q "$dns1"; then
            print_success "/etc/resolv.conf managed by systemd-resolved (stub active)"
        else
            print_warning "systemd-resolved active but $dns1 not visible in resolvectl output"
        fi
    else
        if ! grep -q "# squid-proxy-dns" "$resolv_conf" 2>/dev/null; then
            cp "$resolv_conf" "${resolv_conf}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        fi
        cat > "$resolv_conf" <<EOF
# squid-proxy-dns — managed by proxy-fast.sh
nameserver $dns1
nameserver $dns2
nameserver $dns3
options timeout:2 attempts:3
EOF
        print_success "/etc/resolv.conf updated with $dns1 $dns2 $dns3"
    fi

    if getent hosts cloudflare.com > /dev/null 2>&1; then
        print_success "DNS resolution test passed (cloudflare.com)"
    else
        print_warning "DNS resolution test failed — check /etc/resolv.conf and network"
    fi

    echo ""
}

prepare_runtime() {
    print_separator
    echo -e "${BOLD}Preparing runtime directories and auth...${NC}"
    echo ""

    getent group proxy >/dev/null 2>&1 || groupadd --system proxy
    id -u proxy >/dev/null 2>&1 || useradd --system --gid proxy --home-dir /nonexistent --shell /usr/sbin/nologin proxy

    mkdir -p "$SQUID_ETC_DIR" "$SQUID_LOG_DIR" "$SQUID_SPOOL_DIR" /run/squid
    chown -R proxy:proxy "$SQUID_LOG_DIR" "$SQUID_SPOOL_DIR" /run/squid

    htpasswd -cb "$SQUID_PASSWD_FILE" "$PROXY_USER" "$PROXY_PASS" > /dev/null 2>&1
    chmod 640 "$SQUID_PASSWD_FILE"
    chown root:proxy "$SQUID_PASSWD_FILE" || true

    cat > /etc/logrotate.d/squid-v5 <<'EOF'
/var/log/squid/errors.log
/var/log/squid/cache.log
{
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0640 proxy proxy
    postrotate
        systemctl reload squid 2>/dev/null || true
    endscript
}
EOF

    print_success "Runtime directories and credentials prepared"
    echo ""
}

write_squid_config() {
    print_separator
    echo -e "${BOLD}Writing squid.conf (stable forward-proxy profile)...${NC}"
    echo ""

    cat > "$SQUID_ETC_DIR/squid.conf" <<EOF
# Squid Forward Proxy ${SCRIPT_REV}

workers $SQUID_WORKERS
max_filedescriptors 100000

http_port $HTTP_PORT
pid_filename /run/squid/squid.pid
coredump_dir $SQUID_SPOOL_DIR

auth_param basic program $SQUID_LIBEXEC/basic_ncsa_auth $SQUID_PASSWD_FILE
auth_param basic children $AUTH_CHILDREN
auth_param basic realm ForumCheckerProxy
auth_param basic credentialsttl 24 hours
acl authenticated proxy_auth REQUIRED

acl SSL_ports port 1-65535
acl Safe_ports port 1-65535
acl CONNECT method CONNECT

http_access allow CONNECT authenticated
http_access allow authenticated
http_access deny all

forwarded_for delete
request_header_access X-Forwarded-For deny all
request_header_access Via deny all
request_header_access Forwarded deny all
request_header_access X-Real-IP deny all
request_header_access Proxy-Connection deny all

reply_header_access X-Squid-Error deny all
reply_header_access X-Cache deny all
reply_header_access X-Cache-Lookup deny all

cache deny all
cache_mem 0 MB
maximum_object_size 0 KB
digest_generation off
pinger_enable off

access_log none
cache_store_log none
cache_log $SQUID_LOG_DIR/cache.log

dns_nameservers 1.1.1.1 8.8.8.8 8.8.4.4
dns_timeout 10 seconds
negative_ttl 1 minute

connect_timeout 15 seconds
read_timeout 40 seconds
request_timeout 40 seconds
client_idle_pconn_timeout 15 seconds
pconn_timeout 8 seconds
forward_timeout 15 seconds
shutdown_lifetime 3 seconds
client_persistent_connections off
server_persistent_connections off

half_closed_clients off
pipeline_prefetch 0

httpd_suppress_version_string on
icp_port 0
dead_peer_timeout 5 seconds
EOF

    print_success "squid.conf written"
    echo ""
}

write_sysctl_profile() {
    print_separator
    echo -e "${BOLD}Applying kernel tuning (safe profile)...${NC}"
    echo ""

    cat > /etc/sysctl.d/99-squid-proxy-v5.conf <<'EOF'
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.netfilter.nf_conntrack_max = 262144
vm.swappiness = 10
EOF

    modprobe nf_conntrack 2>/dev/null || true
    echo 'nf_conntrack' > /etc/modules-load.d/nf_conntrack.conf

    print_info "Applying sysctl profile from /etc/sysctl.d/99-squid-proxy-v5.conf"
    sysctl --system
    verify_conntrack_tuning
    conntrack -F > /dev/null 2>&1 || true

    cat > /etc/security/limits.d/squid-v5.conf <<'EOF'
*       soft    nofile    100000
*       hard    nofile    100000
proxy   soft    nofile    100000
proxy   hard    nofile    100000
EOF

    print_success "Kernel + limits profile applied"
    echo ""
}

find_jemalloc_so() {
    local ldconfig_path
    ldconfig_path=$(ldconfig -p 2>/dev/null | grep "libjemalloc\.so\.2" | awk '{print $NF}' | head -1)
    if [ -n "$ldconfig_path" ] && [ -f "$ldconfig_path" ]; then
        echo "$ldconfig_path"
        return 0
    fi
}

write_systemd_unit() {
    print_separator
    echo -e "${BOLD}Creating systemd unit...${NC}"
    echo ""

    local ld_preload_line=""
    if [ "$ENABLE_JEMALLOC" = "1" ]; then
        local jemalloc_so
        jemalloc_so=$(find_jemalloc_so)
        if [ -n "$jemalloc_so" ]; then
            ld_preload_line="Environment=LD_PRELOAD=$jemalloc_so"
            print_success "jemalloc enabled: $jemalloc_so"
        else
            error_exit "ENABLE_JEMALLOC=1 was requested, but libjemalloc.so.2 was not found"
        fi
    else
        print_info "jemalloc preload disabled; Squid will use the default allocator"
    fi

    cat > /etc/systemd/system/squid.service <<EOF
[Unit]
Description=Squid Web Proxy Server (custom v5 fast path)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=proxy
Group=proxy
RuntimeDirectory=squid
RuntimeDirectoryMode=0755
${ld_preload_line}
ExecStartPre=$SQUID_PREFIX/sbin/squid -k parse -f $SQUID_ETC_DIR/squid.conf
ExecStart=$SQUID_PREFIX/sbin/squid -N -f $SQUID_ETC_DIR/squid.conf
ExecReload=$SQUID_PREFIX/sbin/squid -k reconfigure -f $SQUID_ETC_DIR/squid.conf
LimitNOFILE=100000
LimitCORE=infinity
KillMode=mixed
TimeoutStopSec=45
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_success "systemd unit created"
    echo ""
}

configure_firewall() {
    print_separator
    echo -e "${BOLD}Configuring firewall...${NC}"
    echo ""

    if command -v ufw > /dev/null 2>&1; then
        ufw allow 22/tcp > /dev/null 2>&1 || true
        ufw allow "$HTTP_PORT/tcp" > /dev/null 2>&1 || true

        if ! ufw status | grep -q "Status: active"; then
            echo "y" | ufw enable > /dev/null 2>&1 || true
        else
            ufw reload > /dev/null 2>&1 || true
        fi
        print_success "UFW updated (SSH + $HTTP_PORT)"
    else
        print_info "UFW not installed; open TCP/$HTTP_PORT in your cloud firewall"
    fi

    echo ""
}

start_and_validate() {
    print_separator
    echo -e "${BOLD}Starting and validating Squid...${NC}"
    echo ""

    systemctl enable squid > /dev/null 2>&1
    systemctl restart squid
    sleep 3

    if ! systemctl is-active --quiet squid; then
        journalctl -u squid -n 80 --no-pager || true
        error_exit "Squid failed to start"
    fi

    local version_output
    version_output=$($SQUID_PREFIX/sbin/squid -v 2>&1 | head -1 || true)
    ACTUAL_SQUID_VERSION="$version_output"

    print_success "Squid is running"
    print_success "Version detected: $version_output"

    local local_url="http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT"
    local ok=0
    local i
    for i in $(seq 1 5); do
        if curl -s -o /dev/null -x "$local_url" --max-time 15 https://example.com; then
            ok=$((ok+1))
        fi
    done

    if [ "$ok" -lt 3 ]; then
        print_warning "Proxy test passed only $ok/5 times"
    else
        print_success "Proxy test passed $ok/5"
    fi

    echo ""
}

save_details() {
    cat > /root/proxy_details.txt <<EOF
Squid Forward Proxy ${SCRIPT_REV}
========================

Install method: $CHOSEN_INSTALL_METHOD
Squid version : ${ACTUAL_SQUID_VERSION:-unknown}
Server IP     : $SERVER_IP
Port          : $HTTP_PORT
Username      : $PROXY_USER
Password      : $PROXY_PASS

Connection:
http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT

Generated: $(date)
EOF

    chmod 600 /root/proxy_details.txt
}

display_results() {
    print_separator
    echo -e "${GREEN}${BOLD}Installation Complete${NC}"
    print_separator
    echo ""
    echo "Connection    : http://$PROXY_USER:$PROXY_PASS@$SERVER_IP:$HTTP_PORT"
    echo "Install method: $CHOSEN_INSTALL_METHOD"
    echo "Squid version : ${ACTUAL_SQUID_VERSION:-unknown}"
    echo "Details file  : /root/proxy_details.txt"
    echo ""
}

main() {
    run_step "print_header" print_header
    run_step "check_root" check_root
    run_step "check_os" check_os
    run_step "detect_network" detect_network
    run_step "choose_capacity_defaults" choose_capacity_defaults
    run_step "choose_install_method" choose_install_method
    run_step "get_user_input" get_user_input
    run_step "setup_swap_if_needed" setup_swap_if_needed
    run_step "install_prerequisites" install_prerequisites
    run_step "configure_dns" configure_dns
    run_step "stop_old_squid" stop_old_squid

    if [ "$CHOSEN_INSTALL_METHOD" = "apt" ]; then
        run_step "install_squid_apt" install_squid_apt
    else
        run_step "build_squid_from_source" build_squid_from_source
    fi

    run_step "prepare_runtime" prepare_runtime
    run_step "write_squid_config" write_squid_config
    run_step "write_sysctl_profile" write_sysctl_profile
    run_step "write_systemd_unit" write_systemd_unit
    run_step "configure_firewall" configure_firewall
    run_step "start_and_validate" start_and_validate
    run_step "save_details" save_details
    run_step "display_results" display_results
}

main "$@"
