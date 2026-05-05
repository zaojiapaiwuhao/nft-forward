#!/usr/bin/env bash
#
# nft-forward
# nftables 端口转发管理工具
#
# 支持：
#   - 单端口转发
#   - 多端口入、多端口出，一一对应
#   - 备注
#   - 批量导入
#   - 目标地址支持 IPv4 / 域名
#   - 手动重新解析域名并重载规则
#   - systemd timer 自动定时重新解析域名并重载规则
#   - 删除规则支持：单个 / 多个 / 范围 / all
#
# 说明：
#   - 本脚本仅管理 table ip port_forward
#   - 不会主动修改其他 nftables 表
#

set -o pipefail
umask 077

# ==============================
# 基础配置
# ==============================

CONF_DIR="/etc/nftables.d"
CONF_FILE="${CONF_DIR}/port-forward.conf"
DATA_FILE="${CONF_DIR}/port-forward.rules"
BACKUP_DIR="${CONF_DIR}/backups"
MAIN_CONF="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.d/99-nft-forward.conf"
LOG_FILE="/var/log/nft-forward.log"
LOCK_FILE="/run/nft-forward.lock"

TABLE_NAME="port_forward"
INCLUDE_LINE='include "/etc/nftables.d/*.conf"'

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SYSTEMD_SERVICE="/etc/systemd/system/nft-forward-reload.service"
SYSTEMD_TIMER="/etc/systemd/system/nft-forward-reload.timer"
DEFAULT_RELOAD_INTERVAL="6h"

declare -a RULES=()
declare -A RESOLVE_CACHE=()

# ==============================
# 输出函数
# ==============================

info() {
    printf '\033[32m[信息]\033[0m %s\n' "$1"
}

warn() {
    printf '\033[33m[警告]\033[0m %s\n' "$1"
}

err() {
    printf '\033[31m[错误]\033[0m %s\n' "$1" >&2
}

pause_return() {
    echo ""
    read -rp "按 Enter 返回上级菜单..." _
}

run_and_return() {
    "$@"
    pause_return
}

log_action() {
    local msg="$1"

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "请使用 root 权限运行。"
        exit 1
    fi
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            err "已有另一个实例正在运行，请稍后再试。"
            exit 1
        fi
    else
        warn "系统未安装 flock，无法启用并发锁保护。"
    fi
}

# ==============================
# 基础工具函数
# ==============================

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

trim_spaces() {
    local s="$1"

    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"

    echo "$s"
}

get_local_ip() {
    local ip=""

    if command -v ip >/dev/null 2>&1; then
        ip=$(
            ip route get 1.1.1.1 2>/dev/null |
            awk '
                {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "src" && (i + 1) <= NF) {
                            print $(i + 1)
                            exit
                        }
                    }
                }
            '
        )

        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi

        ip=$(
            ip -4 addr show scope global 2>/dev/null |
            awk '/inet / {
                split($2, a, "/")
                print a[1]
                exit
            }'
        )

        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    fi

    hostname -I 2>/dev/null | awk '{print $1}' || true
}

validate_port() {
    local port="$1"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [[ "$port" =~ ^0[0-9]+$ ]]; then
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        return 1
    fi

    return 0
}

normalize_port_list() {
    local input="$1"

    input="${input//[[:space:]]/}"
    input="${input#,}"
    input="${input%,}"

    if [[ -z "$input" ]]; then
        return 1
    fi

    if [[ "$input" == *,,* ]]; then
        return 1
    fi

    local IFS=','
    local -a ports=()
    read -ra ports <<< "$input"

    local p
    for p in "${ports[@]}"; do
        if ! validate_port "$p"; then
            return 1
        fi
    done

    echo "$input"
    return 0
}

count_ports() {
    local input="$1"
    local IFS=','
    local -a ports=()

    read -ra ports <<< "$input"
    echo "${#ports[@]}"
}

validate_ipv4() {
    local ip="$1"

    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    if [[ "$ip" =~ (^|\.)0[0-9]+ ]]; then
        return 1
    fi

    local IFS='.'
    local -a octets=()
    read -ra octets <<< "$ip"

    local octet
    for octet in "${octets[@]}"; do
        if (( octet > 255 )); then
            return 1
        fi
    done

    return 0
}

validate_domain() {
    local domain="$1"

    domain=$(trim_spaces "$domain")
    domain="${domain%.}"

    # 不允许带协议、路径、端口、空格
    if [[ "$domain" == *"://"* || "$domain" == *"/"* || "$domain" == *":"* || "$domain" =~ [[:space:]] ]]; then
        return 1
    fi

    # 支持常规域名和 punycode，例如 xn--xxxx.com
    if [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+([A-Za-z]{2,63}|xn--[A-Za-z0-9-]{2,59})$ ]]; then
        return 0
    fi

    return 1
}

validate_target() {
    local target="$1"

    target=$(trim_spaces "$target")

    if validate_ipv4 "$target"; then
        return 0
    fi

    if validate_domain "$target"; then
        return 0
    fi

    return 1
}

normalize_target() {
    local target="$1"

    target=$(trim_spaces "$target")
    target="${target%.}"

    if validate_ipv4 "$target"; then
        echo "$target"
    else
        echo "${target,,}"
    fi
}

resolve_target_ipv4() {
    local target="$1"

    target=$(trim_spaces "$target")
    target="${target%.}"

    if validate_ipv4 "$target"; then
        echo "$target"
        return 0
    fi

    if [[ -n "${RESOLVE_CACHE[$target]:-}" ]]; then
        echo "${RESOLVE_CACHE[$target]}"
        return 0
    fi

    local ip=""

    if command -v getent >/dev/null 2>&1; then
        ip=$(
            getent ahostsv4 "$target" 2>/dev/null |
            awk '{print $1}' |
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' |
            head -1
        )
    fi

    if [[ -z "$ip" ]] && command -v dig >/dev/null 2>&1; then
        ip=$(
            dig +short A "$target" 2>/dev/null |
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' |
            head -1
        )
    fi

    if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
        ip=$(
            nslookup "$target" 2>/dev/null |
            awk '
                /^Name:/ { found = 1 }
                found && /^Address: / {
                    print $2
                    exit
                }
            ' |
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' |
            head -1
        )
    fi

    if [[ -z "$ip" ]]; then
        return 1
    fi

    if ! validate_ipv4 "$ip"; then
        return 1
    fi

    RESOLVE_CACHE[$target]="$ip"
    echo "$ip"
    return 0
}

escape_comment_for_nft() {
    local comment="$1"

    comment="${comment//$'\n'/ }"
    comment="${comment//$'\r'/ }"
    comment="${comment//\\/\\\\}"
    comment="${comment//\"/\\\"}"

    echo "$comment"
}

sanitize_comment_for_db() {
    local comment="$1"

    comment="${comment//$'\n'/ }"
    comment="${comment//$'\r'/ }"
    comment="${comment//|/-}"
    comment=$(trim_spaces "$comment")

    echo "$comment"
}

# ==============================
# 规则数据管理
# ==============================

init_dirs() {
    mkdir -p "$CONF_DIR" "$BACKUP_DIR" 2>/dev/null || {
        err "无法创建目录 $CONF_DIR"
        return 1
    }

    touch "$DATA_FILE" 2>/dev/null || {
        err "无法创建数据文件 $DATA_FILE"
        return 1
    }

    chmod 600 "$DATA_FILE" 2>/dev/null || true
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

validate_rule_parts() {
    local lports="$1"
    local target="$2"
    local dports="$3"
    local mode="${4:-normal}"

    local normalized_lports
    local normalized_dports
    local normalized_target

    normalized_lports=$(normalize_port_list "$lports") || {
        [[ "$mode" != "quiet" ]] && err "本机端口格式错误：$lports"
        return 1
    }

    normalized_dports=$(normalize_port_list "$dports") || {
        [[ "$mode" != "quiet" ]] && err "目标端口格式错误：$dports"
        return 1
    }

    normalized_target=$(normalize_target "$target")

    if ! validate_target "$normalized_target"; then
        if [[ "$mode" != "quiet" ]]; then
            err "目标地址格式错误：$target"
            err "目标地址必须是 IPv4 或域名，例如：1.2.3.4 / example.com"
        fi
        return 1
    fi

    local lc
    local dc

    lc=$(count_ports "$normalized_lports")
    dc=$(count_ports "$normalized_dports")

    if [[ "$lc" != "$dc" ]]; then
        [[ "$mode" != "quiet" ]] && err "端口数量不一致：$normalized_lports -> $normalized_dports"
        return 1
    fi

    V_LPORTS="$normalized_lports"
    V_TARGET="$normalized_target"
    V_DPORTS="$normalized_dports"

    return 0
}

load_rules() {
    RULES=()

    [[ -f "$DATA_FILE" ]] || return 0

    local line
    local lports target dports comment extra

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(trim_spaces "$line")

        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        IFS='|' read -r lports target dports comment extra <<< "$line"

        if [[ -n "${extra:-}" || -z "${lports:-}" || -z "${target:-}" || -z "${dports:-}" ]]; then
            warn "忽略数据文件中的无效行：$line"
            continue
        fi

        if ! validate_rule_parts "$lports" "$target" "$dports" "quiet"; then
            warn "忽略数据文件中的非法规则：$line"
            continue
        fi

        comment=$(sanitize_comment_for_db "${comment:-无备注}")
        comment="${comment:-无备注}"

        RULES+=("${V_LPORTS}|${V_TARGET}|${V_DPORTS}|${comment}")
    done < "$DATA_FILE"
}

save_rules() {
    local tmp

    tmp=$(mktemp "${DATA_FILE}.tmp.XXXXXX") || {
        err "无法创建临时数据文件。"
        return 1
    }

    chmod 600 "$tmp" 2>/dev/null || true

    local rule
    for rule in "${RULES[@]}"; do
        echo "$rule" >> "$tmp"
    done

    if mv -f "$tmp" "$DATA_FILE"; then
        chmod 600 "$DATA_FILE" 2>/dev/null || true
        return 0
    else
        rm -f "$tmp" 2>/dev/null || true
        err "保存数据文件失败。"
        return 1
    fi
}

backup_all() {
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true

    local ts
    ts=$(date '+%Y%m%d_%H%M%S')

    if [[ -f "$DATA_FILE" ]]; then
        cp -p "$DATA_FILE" "${BACKUP_DIR}/port-forward.rules.${ts}" 2>/dev/null || true
    fi

    if [[ -f "$CONF_FILE" ]]; then
        cp -p "$CONF_FILE" "${BACKUP_DIR}/port-forward.conf.${ts}" 2>/dev/null || true
    fi
}

rule_lport_conflict() {
    local new_lports="$1"
    local rule
    local old_lports old_target old_dports old_comment

    local IFS=','
    local -a new_arr=()
    read -ra new_arr <<< "$new_lports"

    for rule in "${RULES[@]}"; do
        IFS='|' read -r old_lports old_target old_dports old_comment <<< "$rule"

        local -a old_arr=()
        IFS=','
        read -ra old_arr <<< "$old_lports"

        local np op
        for np in "${new_arr[@]}"; do
            for op in "${old_arr[@]}"; do
                if [[ "$np" == "$op" ]]; then
                    echo "$np"
                    return 0
                fi
            done
        done
    done

    return 1
}

# ==============================
# nftables 配置生成与加载
# ==============================

write_conf_file() {
    RESOLVE_CACHE=()

    local local_ip
    local_ip=$(get_local_ip)

    if [[ -z "$local_ip" ]] || ! validate_ipv4 "$local_ip"; then
        err "无法获取本机 IPv4 地址。"
        return 1
    fi

    local tmp
    tmp=$(mktemp "${CONF_FILE}.tmp.XXXXXX") || {
        err "无法创建临时配置文件。"
        return 1
    }

    chmod 600 "$tmp" 2>/dev/null || true

    cat > "$tmp" <<EOF
#!/usr/sbin/nft -f

# 此文件由 nft-forward.sh 自动生成
# 请不要手动修改此文件
# 规则数据文件：${DATA_FILE}

define LOCAL_IP = ${local_ip}

table ip ${TABLE_NAME} {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

    local rule
    for rule in "${RULES[@]}"; do
        local lports target dports comment

        IFS='|' read -r lports target dports comment <<< "$rule"
        comment="${comment:-无备注}"

        if ! validate_rule_parts "$lports" "$target" "$dports" "quiet"; then
            err "规则数据非法，已停止生成配置：$rule"
            rm -f "$tmp"
            return 1
        fi

        local resolved_ip
        resolved_ip=$(resolve_target_ipv4 "$V_TARGET") || {
            err "无法解析目标地址：$V_TARGET"
            err "请检查域名 DNS 是否正常，或换成 IPv4。"
            rm -f "$tmp"
            return 1
        }

        local safe_comment
        safe_comment=$(escape_comment_for_nft "$comment")

        local IFS=','
        local -a lp_arr=()
        local -a dp_arr=()

        read -ra lp_arr <<< "$V_LPORTS"
        read -ra dp_arr <<< "$V_DPORTS"

        local i
        for ((i = 0; i < ${#lp_arr[@]}; i++)); do
            local lp="${lp_arr[$i]}"
            local dp="${dp_arr[$i]}"

            cat >> "$tmp" <<EOF

        tcp dport ${lp} dnat to ${resolved_ip}:${dp} comment "${safe_comment} [${lp}->${V_TARGET}:${dp}]"
        udp dport ${lp} dnat to ${resolved_ip}:${dp} comment "${safe_comment} [${lp}->${V_TARGET}:${dp}]"
EOF
        done
    done

    cat >> "$tmp" <<EOF
    }

    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

    local -A seen_snat=()

    for rule in "${RULES[@]}"; do
        local lports target dports comment

        IFS='|' read -r lports target dports comment <<< "$rule"

        if ! validate_rule_parts "$lports" "$target" "$dports" "quiet"; then
            err "规则数据非法，已停止生成配置：$rule"
            rm -f "$tmp"
            return 1
        fi

        local resolved_ip
        resolved_ip=$(resolve_target_ipv4 "$V_TARGET") || {
            err "无法解析目标地址：$V_TARGET"
            err "请检查域名 DNS 是否正常，或换成 IPv4。"
            rm -f "$tmp"
            return 1
        }

        local IFS=','
        local -a dp_arr=()
        read -ra dp_arr <<< "$V_DPORTS"

        local dp key
        for dp in "${dp_arr[@]}"; do
            key="${resolved_ip}:${dp}"

            if [[ -n "${seen_snat[$key]:-}" ]]; then
                continue
            fi

            seen_snat[$key]=1

            cat >> "$tmp" <<EOF

        ip daddr ${resolved_ip} tcp dport ${dp} ct status dnat snat to \$LOCAL_IP
        ip daddr ${resolved_ip} udp dport ${dp} ct status dnat snat to \$LOCAL_IP
EOF
        done
    done

    cat >> "$tmp" <<EOF
    }
}
EOF

    if mv -f "$tmp" "$CONF_FILE"; then
        chmod 600 "$CONF_FILE" 2>/dev/null || true
        return 0
    else
        rm -f "$tmp" 2>/dev/null || true
        err "写入 $CONF_FILE 失败。"
        return 1
    fi
}

reload_rules() {
    if ! command -v nft >/dev/null 2>&1; then
        err "nft 命令不存在，请先安装 nftables。"
        return 1
    fi

    if [[ ! -f "$CONF_FILE" ]]; then
        err "配置文件不存在：$CONF_FILE"
        return 1
    fi

    nft delete table ip "$TABLE_NAME" 2>/dev/null || true

    if nft -f "$CONF_FILE"; then
        info "nftables 规则已重新加载。"
        return 0
    else
        err "加载 $CONF_FILE 失败。"
        err "如当前规则被清空，可从 ${BACKUP_DIR} 恢复最近备份。"
        return 1
    fi
}

ensure_main_include() {
    if [[ ! -f "$MAIN_CONF" ]]; then
        cat > "$MAIN_CONF" <<EOF
#!/usr/sbin/nft -f

${INCLUDE_LINE}
EOF
        chmod 600 "$MAIN_CONF" 2>/dev/null || true
        info "已创建 $MAIN_CONF"
        return 0
    fi

    if ! grep -qxF "$INCLUDE_LINE" "$MAIN_CONF" 2>/dev/null; then
        echo "$INCLUDE_LINE" >> "$MAIN_CONF"
        info "已向 $MAIN_CONF 添加 include。"
    fi
}

enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || {
        warn "无法临时开启 IPv4 转发。"
    }

    mkdir -p "$(dirname "$SYSCTL_CONF")" 2>/dev/null || true
    touch "$SYSCTL_CONF" 2>/dev/null || true
    chmod 600 "$SYSCTL_CONF" 2>/dev/null || true

    if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "$SYSCTL_CONF" 2>/dev/null; then
        sed -i -E 's|^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*|net.ipv4.ip_forward=1|' "$SYSCTL_CONF"
    else
        echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
    fi

    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    info "已开启并持久化 IPv4 转发。"
}

enable_bbr_fq() {
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        warn "当前内核不支持 BBR，已跳过。"
        return 0
    fi

    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

    mkdir -p "$(dirname "$SYSCTL_CONF")" 2>/dev/null || true
    touch "$SYSCTL_CONF" 2>/dev/null || true
    chmod 600 "$SYSCTL_CONF" 2>/dev/null || true

    if grep -qE '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=' "$SYSCTL_CONF" 2>/dev/null; then
        sed -i -E 's|^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=.*|net.core.default_qdisc=fq|' "$SYSCTL_CONF"
    else
        echo "net.core.default_qdisc=fq" >> "$SYSCTL_CONF"
    fi

    if grep -qE '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=' "$SYSCTL_CONF" 2>/dev/null; then
        sed -i -E 's|^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=.*|net.ipv4.tcp_congestion_control=bbr|' "$SYSCTL_CONF"
    else
        echo "net.ipv4.tcp_congestion_control=bbr" >> "$SYSCTL_CONF"
    fi

    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    info "已尝试开启并持久化 BBR + fq。"
}

# ==============================
# 功能：安装 / 初始化
# ==============================

do_install() {
    echo ""

    local pkg_mgr
    pkg_mgr=$(detect_pkg_manager)

    if ! command -v nft >/dev/null 2>&1; then
        info "未检测到 nftables，准备安装。"

        case "$pkg_mgr" in
            apt)
                apt-get update -y && apt-get install -y nftables
                ;;
            dnf)
                dnf install -y nftables
                ;;
            yum)
                yum install -y nftables
                ;;
            pacman)
                pacman -Syu --noconfirm nftables
                ;;
            *)
                err "无法识别包管理器，请手动安装 nftables。"
                return 1
                ;;
        esac
    else
        info "nftables 已安装。"
        nft --version 2>/dev/null || true
    fi

    init_dirs || return 1
    ensure_main_include
    enable_ip_forward

    local bbr_confirm
    read -rp "是否开启 BBR + fq？[y/N]: " bbr_confirm

    if [[ "$bbr_confirm" =~ ^[Yy]$ ]]; then
        enable_bbr_fq
    fi

    load_rules
    backup_all
    write_conf_file || return 1
    reload_rules || return 1

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl enable --now nftables >/dev/null 2>&1; then
            info "nftables 服务已启用并启动。"
        else
            warn "nftables 服务启用失败，请手动检查 systemctl status nftables。"
        fi
    else
        warn "未检测到 systemctl，请确认 nftables 是否会随系统启动自动加载。"
    fi

    log_action "安装/初始化 nftables 端口转发工具"
    info "初始化完成。"
}

# ==============================
# 功能：查看规则
# ==============================

do_list() {
    echo ""

    init_dirs || return 1
    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有端口转发规则。"
        return 0
    fi

    printf "\n\033[1m%-6s %-28s %-38s %-24s\033[0m\n" "序号" "本机端口" "目标地址" "备注"
    echo "------------------------------------------------------------------------------------------------"

    local idx=1
    local rule

    for rule in "${RULES[@]}"; do
        local lports target dports comment

        IFS='|' read -r lports target dports comment <<< "$rule"
        comment="${comment:-无备注}"

        printf "%-6s %-28s %-38s %-24s\n" \
            "$idx" \
            "$lports" \
            "${target}:${dports}" \
            "$comment"

        ((idx++))
    done

    echo ""
}

# ==============================
# 功能：添加规则
# ==============================

do_add() {
    echo ""

    if ! command -v nft >/dev/null 2>&1; then
        err "nftables 未安装，请先选择【安装 / 初始化 nftables】。"
        return 1
    fi

    init_dirs || return 1
    load_rules

    local lports target dports comment

    while true; do
        read -rp "请输入本机端口，支持单端口或逗号分隔多端口，例如 8080 或 10001,10002: " lports
        lports=$(normalize_port_list "$lports") && break
        err "本机端口格式错误，请重新输入。"
    done

    while true; do
        read -rp "请输入目标 IPv4 地址或域名: " target
        target=$(normalize_target "$target")
        validate_target "$target" && break
        err "目标地址格式错误，请输入 IPv4 或域名，例如：1.2.3.4 / example.com"
    done

    while true; do
        read -rp "请输入目标端口，支持单端口或逗号分隔多端口，默认与本机端口一致: " dports
        dports="${dports:-$lports}"
        dports=$(normalize_port_list "$dports") && break
        err "目标端口格式错误，请重新输入。"
    done

    if ! validate_rule_parts "$lports" "$target" "$dports"; then
        return 1
    fi

    local conflict_port
    conflict_port=$(rule_lport_conflict "$V_LPORTS") && {
        err "本机端口 ${conflict_port} 已存在转发规则，请先删除旧规则。"
        return 1
    }

    read -rp "请输入备注，可留空: " comment
    comment=$(sanitize_comment_for_db "$comment")
    comment="${comment:-无备注}"

    echo ""
    echo "即将添加规则："
    echo "  本机端口: $V_LPORTS"
    echo "  目标地址: ${V_TARGET}:${V_DPORTS}"
    echo "  备注: $comment"

    if ! validate_ipv4 "$V_TARGET"; then
        local resolved_preview
        if resolved_preview=$(resolve_target_ipv4 "$V_TARGET"); then
            echo "  域名解析: ${V_TARGET} -> ${resolved_preview}"
        else
            err "域名当前无法解析：${V_TARGET}"
            return 1
        fi
    fi

    local confirm
    read -rp "确认添加？[Y/n]: " confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消。"
        return 0
    fi

    backup_all
    RULES+=("${V_LPORTS}|${V_TARGET}|${V_DPORTS}|${comment}")

    save_rules || return 1
    write_conf_file || return 1
    reload_rules || return 1

    log_action "新增规则: ${V_LPORTS} -> ${V_TARGET}:${V_DPORTS} comment=${comment}"
    info "规则添加成功。"
}

# ==============================
# 功能：删除规则
# ==============================

do_delete() {
    echo ""

    init_dirs || return 1
    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有规则可删除。"
        return 0
    fi

    do_list

    echo "删除格式示例："
    echo "  6           删除第 6 条"
    echo "  6,8,10      删除第 6、8、10 条"
    echo "  6-10        删除第 6 到第 10 条"
    echo "  6,8,10-15   混合删除"
    echo "  all         删除全部"
    echo "  0           取消"
    echo ""

    local input
    read -rp "请输入要删除的序号: " input

    input="${input//[[:space:]]/}"

    if [[ -z "$input" || "$input" == "0" ]]; then
        info "已取消。"
        return 0
    fi

    local total="${#RULES[@]}"
    local -a delete_indexes=()

    if [[ "$input" == "all" || "$input" == "ALL" ]]; then
        local i
        for ((i = 1; i <= total; i++)); do
            delete_indexes+=("$i")
        done
    else
        if [[ ! "$input" =~ ^[0-9,-]+$ ]]; then
            err "输入格式错误，只支持数字、逗号、范围，例如：1,3,5-8"
            return 1
        fi

        local IFS=','
        local -a parts=()
        read -ra parts <<< "$input"

        local part
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue

            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local start="${BASH_REMATCH[1]}"
                local end="${BASH_REMATCH[2]}"

                if (( start < 1 || end < 1 || start > total || end > total || start > end )); then
                    err "范围无效：${part}，当前有效序号是 1-${total}"
                    return 1
                fi

                local n
                for ((n = start; n <= end; n++)); do
                    delete_indexes+=("$n")
                done
            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                if (( part < 1 || part > total )); then
                    err "序号无效：${part}，当前有效序号是 1-${total}"
                    return 1
                fi

                delete_indexes+=("$part")
            else
                err "输入格式错误：${part}"
                return 1
            fi
        done
    fi

    if [[ ${#delete_indexes[@]} -eq 0 ]]; then
        err "没有有效的删除序号。"
        return 1
    fi

    local sorted_indexes
    sorted_indexes=$(printf "%s\n" "${delete_indexes[@]}" | sort -n -u -r)

    echo ""
    warn "即将删除以下规则："
    echo "--------------------------------------------------------------------------------"

    local idx
    while IFS= read -r idx; do
        local target_rule="${RULES[$((idx - 1))]}"
        local lports target dports comment

        IFS='|' read -r lports target dports comment <<< "$target_rule"

        printf "  %-4s 本机端口: %-28s 目标: %-38s 备注: %s\n" \
            "$idx" \
            "$lports" \
            "${target}:${dports}" \
            "${comment:-无备注}"
    done <<< "$sorted_indexes"

    echo "--------------------------------------------------------------------------------"

    local confirm
    read -rp "确认删除以上规则？[y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消。"
        return 0
    fi

    backup_all

    while IFS= read -r idx; do
        unset 'RULES[$((idx - 1))]'
    done <<< "$sorted_indexes"

    RULES=("${RULES[@]}")

    save_rules || return 1
    write_conf_file || return 1
    reload_rules || return 1

    log_action "批量删除规则: ${input}"
    info "规则已删除。"
}

# ==============================
# 功能：清空规则
# ==============================

do_clear_all() {
    echo ""

    init_dirs || return 1
    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有规则，无需清空。"
        return 0
    fi

    warn "即将清空全部 ${#RULES[@]} 条转发规则。"

    local confirm
    read -rp "确认清空？[y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消。"
        return 0
    fi

    backup_all
    RULES=()

    save_rules || return 1
    write_conf_file || return 1
    reload_rules || return 1

    log_action "清空所有规则"
    info "所有转发规则已清空。"
}

# ==============================
# 功能：批量导入
# ==============================

do_bulk_import() {
    echo ""

    if ! command -v nft >/dev/null 2>&1; then
        err "nftables 未安装，请先选择【安装 / 初始化 nftables】。"
        return 1
    fi

    init_dirs || return 1
    load_rules

    echo "请输入批量规则，一行一条，空行结束。"
    echo ""
    echo "格式："
    echo "  本机端口列表|目标地址|目标端口列表|备注"
    echo ""
    echo "示例："
    echo "  8080|192.168.1.10|80|网站"
    echo "  10001,10002,10003|example.com|20001,20002,20003|游戏服"
    echo ""

    local added=0
    local skipped=0
    local line

    while true; do
        read -r line || break

        [[ -z "$line" ]] && break
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        local lports target dports comment extra
        IFS='|' read -r lports target dports comment extra <<< "$line"

        if [[ -n "${extra:-}" || -z "${lports:-}" || -z "${target:-}" || -z "${dports:-}" ]]; then
            warn "跳过格式错误行：$line"
            ((skipped++))
            continue
        fi

        comment=$(sanitize_comment_for_db "${comment:-无备注}")
        comment="${comment:-无备注}"

        if ! validate_rule_parts "$lports" "$target" "$dports"; then
            warn "跳过无效规则：$line"
            ((skipped++))
            continue
        fi

        local conflict_port
        conflict_port=$(rule_lport_conflict "$V_LPORTS") && {
            warn "跳过端口冲突规则，本机端口 ${conflict_port} 已存在：$line"
            ((skipped++))
            continue
        }

        if ! validate_ipv4 "$V_TARGET"; then
            local resolved_preview
            if ! resolved_preview=$(resolve_target_ipv4 "$V_TARGET"); then
                warn "跳过无法解析域名的规则：$line"
                ((skipped++))
                continue
            fi
            info "域名解析：${V_TARGET} -> ${resolved_preview}"
        fi

        RULES+=("${V_LPORTS}|${V_TARGET}|${V_DPORTS}|${comment}")
        ((added++))
    done

    if (( added == 0 )); then
        warn "没有导入任何有效规则。"
        load_rules
        return 0
    fi

    echo ""
    echo "即将导入 ${added} 条规则，跳过 ${skipped} 条。"

    local confirm
    read -rp "确认导入？[Y/n]: " confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消。"
        load_rules
        return 0
    fi

    backup_all
    save_rules || return 1
    write_conf_file || return 1
    reload_rules || return 1

    log_action "批量导入规则: added=${added}, skipped=${skipped}"
    info "批量导入完成：成功 ${added} 条，跳过 ${skipped} 条。"
}

# ==============================
# 功能：重新解析域名并重载规则
# ==============================

do_reload_resolve() {
    echo ""

    if ! command -v nft >/dev/null 2>&1; then
        err "nftables 未安装，请先选择【安装 / 初始化 nftables】。"
        return 1
    fi

    init_dirs || return 1
    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有转发规则，无需重载。"
        return 0
    fi

    info "正在重新解析域名并生成 nftables 配置..."

    backup_all

    if ! write_conf_file; then
        err "重新生成配置失败，请检查域名是否可以解析。"
        return 1
    fi

    if ! reload_rules; then
        err "重载 nftables 规则失败。"
        return 1
    fi

    log_action "重新解析域名并重载 nftables 规则"
    info "已重新解析域名并重载规则。"
}

# ==============================
# 功能：自动定时重新解析域名并重载
# ==============================

validate_timer_interval() {
    local interval="$1"

    if [[ "$interval" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    if [[ "$interval" =~ ^[0-9]+(s|sec|second|seconds|m|min|minute|minutes|h|hr|hour|hours|d|day|days)$ ]]; then
        return 0
    fi

    return 1
}

do_install_auto_reload_timer() {
    echo ""

    if ! command -v systemctl >/dev/null 2>&1; then
        err "未检测到 systemctl，无法使用 systemd timer。"
        err "如果你的系统不用 systemd，可以改用 cron。"
        return 1
    fi

    if [[ ! -f "$SCRIPT_PATH" ]]; then
        err "无法确定当前脚本路径：$SCRIPT_PATH"
        return 1
    fi

    if ! command -v nft >/dev/null 2>&1; then
        err "nftables 未安装，请先选择【安装 / 初始化 nftables】。"
        return 1
    fi

    echo "自动重新解析域名并 reload，可用于域名 A 记录变化的场景。"
    echo ""
    echo "时间间隔示例："
    echo "  30sec"
    echo "  1min"
    echo "  5min"
    echo "  10min"
    echo "  1h"
    echo "  6h"
    echo "  1d"
    echo ""
    echo "默认：${DEFAULT_RELOAD_INTERVAL}"
    echo ""

    local interval
    read -rp "请输入自动重载间隔 [默认 ${DEFAULT_RELOAD_INTERVAL}]: " interval
    interval="${interval:-$DEFAULT_RELOAD_INTERVAL}"

    if ! validate_timer_interval "$interval"; then
        err "时间间隔格式错误：$interval"
        err "请使用例如 30sec / 5min / 1h / 6h / 1d"
        return 1
    fi

    cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=nft-forward domain resolve and reload
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash "${SCRIPT_PATH}" --reload-resolve
EOF

    cat > "$SYSTEMD_TIMER" <<EOF
[Unit]
Description=Run nft-forward domain resolve and reload periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=${interval}
AccuracySec=30sec
Persistent=true
Unit=nft-forward-reload.service

[Install]
WantedBy=timers.target
EOF

    chmod 644 "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER" 2>/dev/null || true

    systemctl daemon-reload || {
        err "systemctl daemon-reload 失败。"
        return 1
    }

    systemctl enable --now nft-forward-reload.timer || {
        err "启用 nft-forward-reload.timer 失败。"
        return 1
    }

    log_action "安装/更新自动重载定时任务 interval=${interval}"
    info "自动重载定时任务已启用，间隔：${interval}"
    echo ""
    echo "查看 timer 状态："
    echo "  systemctl status nft-forward-reload.timer"
    echo ""
    echo "查看执行日志："
    echo "  journalctl -u nft-forward-reload.service -n 50 --no-pager"
}

do_disable_auto_reload_timer() {
    echo ""

    if ! command -v systemctl >/dev/null 2>&1; then
        err "未检测到 systemctl。"
        return 1
    fi

    warn "即将停用自动重新解析域名并 reload 的定时任务。"

    local confirm
    read -rp "确认停用？[y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消。"
        return 0
    fi

    systemctl disable --now nft-forward-reload.timer >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER"

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed nft-forward-reload.service >/dev/null 2>&1 || true
    systemctl reset-failed nft-forward-reload.timer >/dev/null 2>&1 || true

    log_action "停用自动重载定时任务"
    info "自动重载定时任务已停用。"
}

do_show_auto_reload_timer() {
    echo ""

    if ! command -v systemctl >/dev/null 2>&1; then
        err "未检测到 systemctl。"
        return 1
    fi

    echo "========================================"
    echo "        自动重载定时任务状态"
    echo "========================================"

    if [[ -f "$SYSTEMD_TIMER" ]]; then
        systemctl status nft-forward-reload.timer --no-pager || true
    else
        warn "未安装 nft-forward-reload.timer。"
    fi

    echo ""
    echo "最近执行日志："
    journalctl -u nft-forward-reload.service -n 30 --no-pager 2>/dev/null || true
}

# ==============================
# 功能：诊断
# ==============================

do_diagnose() {
    echo ""
    echo "========================================"
    echo "             诊断 / 自检"
    echo "========================================"

    if command -v nft >/dev/null 2>&1; then
        info "nftables 已安装：$(nft --version 2>/dev/null)"
    else
        err "nftables 未安装。"
    fi

    local ip_forward
    ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "未知")

    if [[ "$ip_forward" == "1" ]]; then
        info "IPv4 转发已开启。"
    else
        warn "IPv4 转发未开启。"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled nftables >/dev/null 2>&1; then
            info "nftables 已设置开机启动。"
        else
            warn "nftables 未设置开机启动。"
        fi

        if systemctl is-active nftables >/dev/null 2>&1; then
            info "nftables 服务正在运行。"
        else
            warn "nftables 服务未运行。"
        fi
    else
        warn "未检测到 systemctl，跳过服务状态检查。"
    fi

    if [[ -f "$MAIN_CONF" ]] && grep -qxF "$INCLUDE_LINE" "$MAIN_CONF" 2>/dev/null; then
        info "$MAIN_CONF 已包含 include。"
    else
        warn "$MAIN_CONF 未包含 include，重启后可能无法自动加载规则。"
    fi

    if command -v nft >/dev/null 2>&1 && nft list table ip "$TABLE_NAME" >/dev/null 2>&1; then
        info "nftables 表 ip ${TABLE_NAME} 已加载。"
    else
        warn "nftables 表 ip ${TABLE_NAME} 未加载。"
    fi

    if [[ -f "$SYSTEMD_TIMER" ]]; then
        if systemctl is-enabled nft-forward-reload.timer >/dev/null 2>&1; then
            info "自动重载 timer 已启用。"
        else
            warn "自动重载 timer 已安装但未启用。"
        fi
    else
        warn "自动重载 timer 未安装。"
    fi

    init_dirs || return 1
    load_rules

    info "当前数据文件中有 ${#RULES[@]} 条有效规则。"

    if [[ ${#RULES[@]} -gt 0 ]]; then
        echo ""
        echo "--- 域名解析检查 ---"

        local rule
        for rule in "${RULES[@]}"; do
            local lports target dports comment

            IFS='|' read -r lports target dports comment <<< "$rule"

            if validate_ipv4 "$target"; then
                continue
            fi

            local rip
            if rip=$(resolve_target_ipv4 "$target"); then
                info "${target} -> ${rip}"
            else
                warn "${target} 无法解析"
            fi
        done
    fi

    echo ""
}

# ==============================
# 功能：卸载本工具规则并删除脚本
# ==============================

do_uninstall() {
    echo ""

    warn "此操作将卸载本工具创建的端口转发配置。"
    warn "将删除："
    warn "  - nftables 表 ip ${TABLE_NAME}"
    warn "  - ${CONF_FILE}"
    warn "  - ${DATA_FILE}"
    warn "  - 自动重载 systemd service / timer"
    warn "  - 本工具日志 ${LOG_FILE}"
    warn "  - 当前脚本文件 ${SCRIPT_PATH}"
    echo ""
    warn "不会卸载 nftables 软件包。"
    warn "不会删除你的其他 nftables 规则。"
    echo ""

    local confirm
    read -rp "确认卸载并删除脚本？[y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消。"
        return 0
    fi

    backup_all
    log_action "卸载本工具端口转发配置并删除脚本"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now nft-forward-reload.timer >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed nft-forward-reload.service >/dev/null 2>&1 || true
        systemctl reset-failed nft-forward-reload.timer >/dev/null 2>&1 || true
    fi

    if command -v nft >/dev/null 2>&1; then
        nft delete table ip "$TABLE_NAME" 2>/dev/null || true
    fi

    if [[ -f "$MAIN_CONF" ]]; then
        local tmp
        tmp=$(mktemp "${MAIN_CONF}.tmp.XXXXXX") || {
            err "无法创建临时文件。"
            return 1
        }

        grep -vxF "$INCLUDE_LINE" "$MAIN_CONF" > "$tmp" 2>/dev/null || true

        if mv -f "$tmp" "$MAIN_CONF"; then
            chmod 600 "$MAIN_CONF" 2>/dev/null || true
            info "已从 $MAIN_CONF 移除 include 行。"
        else
            rm -f "$tmp" 2>/dev/null || true
            warn "移除 include 行失败，请手动检查 $MAIN_CONF。"
        fi
    fi

    rm -f "$CONF_FILE" "$DATA_FILE" "$LOG_FILE" "$LOCK_FILE"

    rm -f "${BACKUP_DIR}"/port-forward.rules.* 2>/dev/null || true
    rm -f "${BACKUP_DIR}"/port-forward.conf.* 2>/dev/null || true
    rmdir "$BACKUP_DIR" 2>/dev/null || true

    if [[ -n "${SCRIPT_PATH:-}" && -f "$SCRIPT_PATH" && "$SCRIPT_PATH" != "/" ]]; then
        rm -f -- "$SCRIPT_PATH" 2>/dev/null || {
            warn "脚本自身删除失败，请手动删除：$SCRIPT_PATH"
        }
    fi

    info "卸载完成。"
    info "脚本和本工具相关文件已删除。"
    exit 0
}

# ==============================
# 二级菜单：域名解析 / 规则重载
# ==============================

domain_reload_menu() {
    while true; do
        echo ""
        echo "========================================"
        echo "       域名解析 / 规则重载"
        echo "========================================"
        echo "  1) 立即重新解析域名并重载规则"
        echo "  2) 安装 / 更新自动重载定时任务"
        echo "  3) 查看自动重载定时任务状态"
        echo "  4) 停用自动重载定时任务"
        echo "  0) 返回主菜单"
        echo "========================================"

        local choice
        read -rp "请选择操作 [0-4]: " choice

        case "$choice" in
            1) run_and_return do_reload_resolve ;;
            2) run_and_return do_install_auto_reload_timer ;;
            3) run_and_return do_show_auto_reload_timer ;;
            4) run_and_return do_disable_auto_reload_timer ;;
            0)
                return 0
                ;;
            *)
                err "无效选择，请输入 0-4。"
                ;;
        esac
    done
}

# ==============================
# 主菜单
# ==============================

main_menu() {
    while true; do
        echo ""
        echo "========================================"
        echo "    nftables 端口转发管理工具"
        echo "========================================"
        echo "  1) 安装 / 初始化 nftables"
        echo "  2) 查看现有端口转发"
        echo "  3) 新增端口转发"
        echo "  4) 删除端口转发"
        echo "  5) 一键清空所有转发"
        echo "  6) 批量导入转发规则"
        echo "  7) 诊断 / 自检"
        echo "  8) 域名解析 / 规则重载"
        echo "  9) 卸载本工具配置并删除脚本"
        echo "  10) 退出脚本"
        echo "========================================"

        local choice
        read -rp "请选择操作 [1-10]: " choice

        case "$choice" in
            1) run_and_return do_install ;;
            2) run_and_return do_list ;;
            3) run_and_return do_add ;;
            4) run_and_return do_delete ;;
            5) run_and_return do_clear_all ;;
            6) run_and_return do_bulk_import ;;
            7) run_and_return do_diagnose ;;
            8) domain_reload_menu ;;
            9) do_uninstall ;;
            10)
                info "再见。"
                exit 0
                ;;
            *)
                err "无效选择，请输入 1-10。"
                ;;
        esac
    done
}

# ==============================
# 命令行模式
# ==============================

handle_cli_args() {
    case "${1:-}" in
        --reload-resolve)
            check_root
            init_dirs || exit 1
            acquire_lock
            do_reload_resolve
            exit $?
            ;;
        --list)
            check_root
            init_dirs || exit 1
            acquire_lock
            do_list
            exit $?
            ;;
        --diagnose)
            check_root
            init_dirs || exit 1
            acquire_lock
            do_diagnose
            exit $?
            ;;
        --help|-h)
            echo "用法："
            echo "  $0                  启动交互菜单"
            echo "  $0 --reload-resolve 重新解析域名并重载 nftables"
            echo "  $0 --list           查看规则"
            echo "  $0 --diagnose       诊断 / 自检"
            exit 0
            ;;
        "")
            return 0
            ;;
        *)
            err "未知参数：$1"
            echo "使用 $0 --help 查看帮助。"
            exit 1
            ;;
    esac
}

# ==============================
# 入口
# ==============================

handle_cli_args "$1"

check_root
init_dirs || exit 1
acquire_lock
main_menu