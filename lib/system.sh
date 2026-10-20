#!/usr/bin/env bash

rs_check_platform() {
    [[ -f /etc/os-release ]] || die '无法识别 Linux 发行版。'
    local ID='' VERSION_ID=''
    # shellcheck source=/dev/null
    source /etc/os-release
    case "$ID" in
        debian)
            if [[ ! "${VERSION_ID%%.*}" =~ ^[0-9]+$ ]] || (( ${VERSION_ID%%.*} < 12 )); then die '需要 Debian 12 或更高版本。'; fi ;;
        ubuntu)
            if [[ ! "${VERSION_ID%%.*}" =~ ^[0-9]+$ ]] || (( ${VERSION_ID%%.*} < 22 )); then die '需要 Ubuntu 22.04 或更高版本。'; fi ;;
        *) die '当前支持 Debian 12+、Ubuntu 22.04+。' ;;
    esac
    if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null; then
        die '需要运行中的 systemd；请在 VPS 宿主机运行，不要在普通容器内运行。'
    fi
}

rs_policy_text() {
    cat <<'POLICY'
#!/bin/sh
# reality-site temporary nginx policy v1
case "$1" in nginx|nginx.service) exit 101 ;; esac
exit 0
POLICY
}

rs_recover_policy() {
    if [[ -f "$POLICY_PATH" && ! -L "$POLICY_PATH" ]] && cmp -s "$POLICY_PATH" <(rs_policy_text); then
        rs_secure_file "$POLICY_PATH"
        RS_POLICY_CREATED=1
        rs_restore_policy
        info '已清理本工具上次中断遗留的 Nginx 安装启动限制。'
    fi
}

rs_restore_policy() {
    if (( RS_POLICY_CREATED )); then
        if [[ -f "$POLICY_PATH" && ! -L "$POLICY_PATH" ]] && cmp -s "$POLICY_PATH" <(rs_policy_text); then
            # This marker is created only if nginx was absent before install.
            # Keep it if disabling fails so the next run can recover safely.
            if [[ -x "$NGINX_BIN" ]] && ! systemctl disable nginx.service >/dev/null 2>&1; then
                warn '无法禁用本次新装 Nginx 的默认服务；保留恢复标记，请检查 systemctl disable nginx.service。'
                return 1
            fi
            rm -- "$POLICY_PATH" || return 1
            RS_POLICY_CREATED=0
        else
            warn "安装期间 $POLICY_PATH 已被其他程序更改，未删除该文件。"
            return 1
        fi
    fi
}

rs_install_dependencies() {
    local -a packages=() pairs=(curl:curl openssl:openssl jq:jq dig:dnsutils tar:tar gzip:gzip ss:iproute2 flock:util-linux)
    local pair tool package
    for pair in "${pairs[@]}"; do
        tool=${pair%%:*}; package=${pair#*:}
        command -v "$tool" >/dev/null || packages+=("$package")
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    if [[ ! -x "$NGINX_BIN" ]]; then
        if command -v nginx >/dev/null || systemctl is-active --quiet nginx.service; then
            die '发现自定义 Nginx，但没有 /usr/sbin/nginx；请先确认安装布局，避免安装第二套覆盖现有软件。'
        fi
        packages+=(nginx)
        if [[ -e "$POLICY_PATH" || -L "$POLICY_PATH" ]]; then
            die "已有 $POLICY_PATH；请自行安装 nginx 后重试，本工具不会覆盖既有 APT 服务策略。"
        fi
        # Prevent the package's default site from starting on public port 80.
        (set -o noclobber; rs_policy_text > "$POLICY_PATH") || die '无法创建临时服务启动策略。'
        RS_POLICY_CREATED=1
        chmod 755 "$POLICY_PATH"
    fi
    if (( ${#packages[@]} )); then
        info "安装缺少的系统依赖：${packages[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends "${packages[@]}"
    fi
    rs_restore_policy || die '未能恢复 Nginx 安装服务策略。'
    [[ -x "$NGINX_BIN" ]] || die '缺少 Nginx 程序。'
    "$NGINX_BIN" -V 2>&1 | grep -q -- '--with-http_ssl_module' || die 'Nginx 缺少 HTTP SSL 模块。'
    "$NGINX_BIN" -V 2>&1 | grep -q -- '--with-http_v2_module' || die 'Nginx 缺少 HTTP/2 模块。'
    id www-data >/dev/null 2>&1 || die '缺少 www-data 用户；请使用发行版提供的 Nginx 包。'
}

rs_install_program() {
    local file directory stage mode
    local -a files=(lib/common.sh lib/system.sh lib/cert.sh lib/web.sh lib/domain.sh assets/index.html README.md reality-site.sh)
    if [[ "$SOURCE_DIR" == "$APP_DIR" ]]; then return; fi
    # Validate the complete bundle before replacing any installed program file.
    for file in "${files[@]}"; do
        [[ -f "$SOURCE_DIR/$file" && ! -L "$SOURCE_DIR/$file" ]] || die "安装包缺少普通文件：$file"
        if [[ -e "$APP_DIR/$file" || -L "$APP_DIR/$file" ]]; then rs_secure_file "$APP_DIR/$file"; fi
    done
    for directory in lib assets; do
        if [[ -e "$APP_DIR/$directory" || -L "$APP_DIR/$directory" ]]; then rs_secure_dir "$APP_DIR/$directory"; fi
        install -d -m 755 "$APP_DIR/$directory"
    done
    for file in "${files[@]}"; do
        mode=644
        [[ "$file" != reality-site.sh ]] || mode=755
        stage=$(mktemp "$APP_DIR/$file.tmp.XXXXXX") || return 1
        if ! install -m "$mode" -- "$SOURCE_DIR/$file" "$stage" || ! mv -f -- "$stage" "$APP_DIR/$file"; then
            rm -f -- "$stage"
            return 1
        fi
    done
}

rs_configure_timer() {
    local unit="$RS_UNIT_DIR/reality-site-renew.service" timer="$RS_UNIT_DIR/reality-site-renew.timer"
    rs_assert_owned_output "$unit"
    rs_assert_owned_output "$timer"
    if [[ "$CERT_MODE" != cloudflare ]]; then
        if [[ -f "$timer" ]]; then systemctl disable --now reality-site-renew.timer; fi
        return
    fi
    cat > "$unit" <<EOF
# Managed by reality-site
[Unit]
Description=Renew the REALITY local website certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
UMask=0077
ExecStart=/bin/bash $APP_DIR/reality-site.sh renew
TimeoutStartSec=30min
EOF
    cat > "$timer" <<'EOF'
# Managed by reality-site
[Unit]
Description=Daily certificate check for the REALITY local website

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$unit" "$timer"
    systemctl daemon-reload
    systemctl enable --now reality-site-renew.timer
}

rs_enable_bbr() {
    local conf=${RS_SYSCTL_FILE:-/etc/sysctl.d/99-reality-site-bbr.conf} old_cc old_qdisc available stage
    command -v sysctl >/dev/null || die '缺少 sysctl（procps）。'
    if command -v modprobe >/dev/null; then modprobe tcp_bbr 2>/dev/null || true; fi
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    [[ " $available " == *' bbr '* ]] || die '当前内核没有提供 BBR；未安装或更换内核。'
    # Loading sch_fq is optional when fq is built into the kernel.
    if command -v modprobe >/dev/null; then modprobe sch_fq 2>/dev/null || true; fi
    old_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    old_qdisc=$(sysctl -n net.core.default_qdisc) || die '当前环境不支持 default_qdisc。'
    rs_assert_owned_output "$conf"
    stage=$(mktemp "${conf}.tmp.XXXXXX") || die '无法创建 BBR 持久配置临时文件。'
    if ! { printf '%s\n' '# Managed by reality-site' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr' > "$stage" && chmod 644 "$stage"; }; then
        rm -f -- "$stage"
        die '无法准备 BBR 持久配置；内核设置未改变。'
    fi
    if ! sysctl -q -w net.core.default_qdisc=fq; then rm -f -- "$stage"; die '内核未接受 fq；未写入持久配置。'; fi
    if ! sysctl -q -w net.ipv4.tcp_congestion_control=bbr; then
        sysctl -q -w "net.core.default_qdisc=$old_qdisc" || true
        rm -f -- "$stage"
        die '启用 BBR 失败，已尝试恢复原默认队列。'
    fi
    if ! mv -f -- "$stage" "$conf"; then
        sysctl -q -w "net.ipv4.tcp_congestion_control=$old_cc" "net.core.default_qdisc=$old_qdisc" || true
        rm -f -- "$stage"
        die '无法持久保存 BBR 设置，已尝试恢复原值。'
    fi
    info '已启用当前内核提供的 BBR，并将默认队列设为 fq。'
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
    if command -v tc >/dev/null; then tc qdisc show || true; fi
    info '现有连接/网卡队列未被强制替换；默认队列会在相应队列重新创建时生效（例如维护重启后）。'
}
