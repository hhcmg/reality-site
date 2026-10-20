#!/usr/bin/env bash
# Prepare a local HTTPS target for a REALITY inbound managed by 3x-ui.
set +a +C +v +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
unset CF_TOKEN CF_ZONE_ID CF_Token CF_Zone_ID CF_Key CF_Email SSLKEYLOGFILE 2>/dev/null || true

VERSION=1.3.0
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
APP_DIR=/opt/reality-site
DATA_DIR=/var/lib/reality-site
STATE_FILE=$DATA_DIR/state.json
NGINX_BIN=/usr/sbin/nginx
SERVICE_NAME=reality-site.service
TMP_DIR=
RS_WEB_STARTED=0
RS_INSTALL_PENDING=0
RS_POLICY_CREATED=0
RS_MODE_PENDING=0
RS_DOMAIN_PENDING=0
POLICY_PATH=/usr/sbin/policy-rc.d
RS_LOCK_FILE=/run/reality-site.lock
RS_SYSCTL_FILE=/etc/sysctl.d/99-reality-site-bbr.conf
RS_UNIT_DIR=/etc/systemd/system
DOMAIN='' PORT='' CERT_MODE='' ACME_EMAIL='' STATIC_SOURCE=''
WEB_MODE=static REDIRECT_URL=''

for module in common system cert web domain; do
    [[ -f "$SOURCE_DIR/lib/$module.sh" ]] || { printf '缺少模块：%s/lib/%s.sh\n' "$SOURCE_DIR" "$module" >&2; exit 1; }
done
# shellcheck source=lib/common.sh
source "$SOURCE_DIR/lib/common.sh"
# shellcheck source=lib/system.sh
source "$SOURCE_DIR/lib/system.sh"
# shellcheck source=lib/cert.sh
source "$SOURCE_DIR/lib/cert.sh"
# shellcheck source=lib/web.sh
source "$SOURCE_DIR/lib/web.sh"
# shellcheck source=lib/domain.sh
source "$SOURCE_DIR/lib/domain.sh"

rs_usage() {
    cat <<'HELP'
用法：sudo bash reality-site.sh [命令]
  无参数                       打开 SSH 交互菜单
  install                      安装本机 HTTPS 网站（交互向导）
  status                       查看网站、证书和服务状态
  check                        验证本机证书、TLS 1.3、HTTP/2 和网页
  panel                        显示需要手动填写到 3x-ui 的参数
  renew                        检查 Cloudflare DNS-01 证书续期
  import-cert FULLCHAIN KEY     导入证书，并切换为手动证书模式
  set-page HTML                替换自包含单文件网页
  set-mode static              切换为本地静态页（保留已上传网页）
  set-mode redirect HTTPS_URL  切换为 302 跳转（URL 用单引号包围）
  set-domain DOMAIN [CHAIN KEY] 更换域名；手动证书模式需提供证书链和私钥
  bbr                          启用当前内核的 BBR + fq（不安装内核）
  help / --help                查看帮助
  version / --version          查看版本

网站仅监听 127.0.0.1:8003（端口可选），不占用公网 80/443。
Xray 的安装、更新、入站、路由和重启全部由 3x-ui 管理。
HELP
}

rs_cleanup() {
    local rc=$?
    trap - EXIT ERR INT TERM
    if (( RS_DOMAIN_PENDING )); then rs_domain_recover || true; fi
    if (( RS_MODE_PENDING )); then rs_web_rollback_mode || true; fi
    rs_restore_policy || true
    if (( RS_INSTALL_PENDING && RS_WEB_STARTED )); then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        if [[ -f "$RS_UNIT_DIR/reality-site-renew.timer" ]] &&
            (rs_assert_owned_output "$RS_UNIT_DIR/reality-site-renew.timer") >/dev/null 2>&1; then
            systemctl disable --now reality-site-renew.timer >/dev/null 2>&1 || true
        fi
        warn '安装尚未完成，已停止本工具的网站服务；数据已保留，可重新执行 install。'
    fi
    if [[ -n "$TMP_DIR" && "$TMP_DIR" == /tmp/reality-site.* && -d "$TMP_DIR" && ! -L "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    unset CF_TOKEN CF_ZONE_ID CF_Token CF_Zone_ID 2>/dev/null || true
    exit "$rc"
}

rs_panel() {
    cat <<PANEL

请在 3x-ui 面板中手动创建或修改入站：
  协议             VLESS
  传输             TCP / RAW
  安全             REALITY
  目标 / target    127.0.0.1:$PORT
  SNI/serverNames  $DOMAIN
  Xver             0
  客户端 Flow      xtls-rprx-vision
  公网入站端口     443（需由 3x-ui/Xray 监听，不是面板管理端口）
  密钥/Short ID    在面板中生成并使用面板导出的客户端链接

网站地址：https://$DOMAIN/
保存入站并使配置生效后，公网浏览器请求才能通过 Xray 到达网站。
此脚本尚未配置公网入站；本机 HTTPS 自检成功不代表公网节点已经可用。
将 REALITY target 改为外站或停止 Xray，会影响这个网站的公网访问。
Docker 内的 3x-ui 若不使用主机网络，127.0.0.1 不指向宿主机；请先解决容器到宿主机的访问路径。
PANEL
    if [[ "$WEB_MODE" == redirect ]]; then
        printf '\n当前网站模式：302 跳转至 %s\n' "$REDIRECT_URL"
        printf '跳转只改变浏览器网页访问；REALITY target 和 SNI 仍填写上面的本机目标及本站域名。\n'
    fi
}

rs_status() {
    printf 'reality-site %s\n域名：%s\n本机目标：127.0.0.1:%s\n证书模式：%s\n' "$VERSION" "$DOMAIN" "$PORT" "$CERT_MODE"
    printf '安装状态：%s\n' "$(jq -r .status "$STATE_FILE")"
    printf '网站模式：%s\n' "$WEB_MODE"
    if [[ "$WEB_MODE" == redirect ]]; then printf '302 跳转地址：%s\n' "$REDIRECT_URL"; fi
    printf '网站服务：%s\n' "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    printf '续期定时器：%s\n' "$(systemctl is-active reality-site-renew.timer 2>/dev/null || true)"
    if [[ -f "$DATA_DIR/certs/live/fullchain.pem" ]]; then
        openssl x509 -in "$DATA_DIR/certs/live/fullchain.pem" -noout -subject -issuer -dates
    fi
    printf '当前 TCP 监听：\n'
    ss -lntp "( sport = :$PORT )"
    printf '配置：%s/nginx.conf\n网页：%s/www/index.html\n' "$DATA_DIR" "$DATA_DIR"
}

rs_install() {
    rs_check_platform
    rs_recover_policy
    if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
        rs_load_state
        if [[ "$(jq -r .status "$STATE_FILE")" == ready ]]; then
            rs_prepare_directories
            rs_install_program
            if [[ "$CERT_MODE" == cloudflare ]]; then rs_cert_cf_sync_hook || die '程序已更新，但证书区域配置升级失败。'; fi
            info '已安装；已同步本安装包的程序文件，保留现有网站配置和证书。切换模式用 set-mode，更换域名用 set-domain。'
            rs_status
            rs_panel
            return
        fi
        warn '发现未完成的安装，将沿用已保存的域名、端口和证书方式重新准备。'
        if [[ -e "$RS_UNIT_DIR/reality-site.service" ]]; then
            rs_assert_owned_output "$RS_UNIT_DIR/reality-site.service"
            systemctl disable --now "$SERVICE_NAME"
        fi
        if [[ "$WEB_MODE" == static ]]; then
            rs_prompt STATIC_SOURCE '网页 HTML 的绝对路径（留空保留已有页面或使用默认页面）' ''
        fi
    else
        rs_prompt DOMAIN '用于本机网站及 REALITY SNI 的域名（如 cover.example.com）' ''
        DOMAIN=${DOMAIN,,}
        rs_valid_domain "$DOMAIN" || die '域名格式不正确；请填完整域名，不要带 https://、端口、路径或通配符。'
        rs_prompt PORT '本机 HTTPS 端口' '8003'
        rs_valid_port "$PORT" || die '端口必须是 1024–65535 的整数。'
        local cert_choice
        rs_prompt cert_choice '证书方式：1=Cloudflare 自动申请/续期，2=导入已有证书' '1'
        case "$cert_choice" in
            1) CERT_MODE=cloudflare; rs_prompt ACME_EMAIL 'ACME 账户邮箱' ''; rs_valid_email "$ACME_EMAIL" || die '邮箱格式不正确。' ;;
            2) CERT_MODE=manual; ACME_EMAIL= ;;
            *) die '证书方式只能选择 1 或 2。' ;;
        esac
        rs_choose_web_mode
        if [[ "$WEB_MODE" == static ]]; then
            rs_prompt STATIC_SOURCE '网页 HTML 的绝对路径（留空使用默认页面）' ''
        fi
    fi
    [[ -z "$STATIC_SOURCE" ]] || rs_web_validate_page "$STATIC_SOURCE"
    info "将准备 $DOMAIN 的本机 HTTPS 服务：127.0.0.1:$PORT。"
    info 'DNS 应直接指向本 VPS（Cloudflare 灰云）；证书使用 DNS 验证，不需要占用 80/443。'
    rs_install_dependencies
    rs_web_port_check
    rs_prepare_directories
    rs_install_program
    rs_write_state installing
    RS_INSTALL_PENDING=1
    rs_cert_setup
    rs_web_install
    RS_WEB_STARTED=1
    rs_web_check ''
    rs_configure_timer
    rs_write_state ready
    RS_INSTALL_PENDING=0
    info '本机 HTTPS 网站准备完成。'
    rs_panel
}

rs_choose_web_mode() {
    local mode_choice
    rs_prompt mode_choice '网站模式：1=本地静态页，2=302 跳转到外部 HTTPS 网站' '1'
    case "$mode_choice" in
        1) WEB_MODE=static; REDIRECT_URL='' ;;
        2)
            WEB_MODE=redirect
            rs_prompt REDIRECT_URL '完整跳转地址（如 https://www.example.com/）' ''
            rs_valid_redirect_url "$REDIRECT_URL" || die '跳转地址必须是外部域名的有效 HTTPS URL；不支持本站域名、空白或配置特殊字符。'
            ;;
        *) die '网站模式只能选择 1 或 2。' ;;
    esac
}

rs_menu() {
    local choice
    cat <<'MENU'
1. 安装本机 HTTPS 网站
2. 查看状态
3. 本机 HTTPS 自检
4. 查看 3x-ui 填写参数
5. 检查证书续期
6. 替换网页
7. 导入证书
8. 开启当前内核 BBR + fq
9. 切换网站模式（静态页 / 302 跳转）
10. 更换网站域名（保留端口、网页和响应模式）
0. 退出
MENU
    rs_prompt choice '选择' '2'
    case "$choice" in
        1) rs_dispatch install ;;
        2) rs_dispatch status ;;
        3) rs_dispatch check ;;
        4) rs_dispatch panel ;;
        5) rs_dispatch renew ;;
        6) local page; rs_prompt page 'HTML 文件绝对路径' ''; rs_dispatch set-page "$page" ;;
        7) local chain key; rs_prompt chain '完整证书链 PEM 绝对路径' ''; rs_prompt key '私钥 PEM 绝对路径' ''; rs_dispatch import-cert "$chain" "$key" ;;
        8) rs_dispatch bbr ;;
        9)
            rs_load_state
            rs_choose_web_mode
            rs_dispatch set-mode "$WEB_MODE" "$REDIRECT_URL"
            ;;
        10)
            rs_load_state
            local next_domain chain key
            rs_prompt next_domain '新的网站及 REALITY SNI 域名' ''
            if [[ "$CERT_MODE" == manual && "${next_domain,,}" != "$DOMAIN" ]]; then
                rs_prompt chain '新域名完整证书链 PEM 的绝对路径' ''
                rs_prompt key '新域名私钥 PEM 的绝对路径' ''
                rs_dispatch set-domain "$next_domain" "$chain" "$key"
            else
                rs_dispatch set-domain "$next_domain"
            fi
            ;;
        0) return ;;
        *) die '无效选项。' ;;
    esac
}

rs_dispatch() {
    local command=${1:-menu}
    shift || true
    case "$command" in
        install) [[ $# == 0 ]] || die 'install 不接受额外参数。'; rs_install ;;
        bbr) [[ $# == 0 ]] || die 'bbr 不接受额外参数。'; rs_enable_bbr ;;
        menu) rs_menu ;;
        status|check|panel|renew|set-page|import-cert|set-mode|set-domain)
            rs_load_state
            case "$command" in
                status|check|panel|renew) [[ $# == 0 ]] || die "$command 不接受额外参数。" ;;
                set-page) [[ $# == 1 ]] || die 'set-page 需要一个 HTML 文件路径。' ;;
                import-cert) [[ $# == 2 ]] || die 'import-cert 需要完整证书链和私钥两个路径。' ;;
                set-domain) [[ $# == 1 || $# == 3 ]] || die 'set-domain 需要新域名；手动证书模式还需要完整证书链和私钥路径。' ;;
                set-mode)
                    case "${1:-}" in
                        static) [[ $# == 1 || ( $# == 2 && -z $2 ) ]] || die '用法：set-mode static' ;;
                        redirect) [[ $# == 2 ]] || die '用法：set-mode redirect '\''https://www.example.com/'\''' ;;
                        *) die '模式必须为 static 或 redirect。' ;;
                    esac
                    ;;
            esac
            case "$command" in
                status) rs_status ;;
                check) rs_web_check '' ;;
                panel) rs_panel ;;
                renew) rs_cert_renew ;;
                set-page) rs_web_set_page "$1" ;;
                set-mode) rs_web_set_mode "$1" "${2:-}" ;;
                set-domain) rs_domain_set "$@" ;;
                import-cert)
                    rs_secure_file "$1"
                    rs_secure_file "$2"
                    rs_cert_validate "$1" "$2" || die '证书校验失败，证书模式和现有证书未改变。'
                    # Persist the mode first: a crash or later reload failure must
                    # never let the renewal timer overwrite a manually chosen cert.
                    CERT_MODE=manual
                    rs_write_state "$(jq -r .status "$STATE_FILE")"
                    rs_configure_timer
                    info '已保存手动证书模式；若后续发布失败，保留旧证书，请修正后重新导入。'
                    rs_cert_import "$1" "$2"
                    info '证书已导入；已切换手动证书模式，不再自动签发覆盖它。'
                    ;;
            esac
            ;;
        *) die "未知命令：$command。请使用 --help。" ;;
    esac
}

rs_main() {
    case "${1:-}" in
        --help|help|-h) rs_usage; return ;;
        --version|version) printf '%s\n' "$VERSION"; return ;;
    esac
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    rs_require_root
    [[ $(uname -s) == Linux ]] || die '请在 Linux VPS 上执行本工具。'
    command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux。'
    rs_lock
    TMP_DIR=$(mktemp -d /tmp/reality-site.XXXXXX)
    trap rs_cleanup EXIT
    trap 'printf "[错误] 第 %s 行执行失败（状态 %s）。\n" "$LINENO" "$?" >&2' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    rs_domain_recover || die '上次域名变更尚未恢复，请先修复上述问题。'
    rs_dispatch "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rs_main "$@"
fi
