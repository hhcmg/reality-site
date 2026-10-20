#!/usr/bin/env bash
# Local HTTPS target for a REALITY inbound managed separately by 3x-ui.
# Requires common.sh and the APP_DIR, DATA_DIR, DOMAIN, PORT globals.

rs_web_validate_context() {
    [[ ${DOMAIN:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "网站域名无效。"
    [[ ${PORT:-} =~ ^[0-9]{1,5}$ ]] || die "网站内部端口无效。"
    (( 10#$PORT >= 1024 && 10#$PORT <= 65535 )) || die "网站内部端口必须为 1024–65535，不能占用公网 80/443。"
    # Paths are embedded in nginx and systemd configuration, not shell commands.
    [[ ${DATA_DIR:-} =~ ^/[A-Za-z0-9_./-]+$ && $DATA_DIR != *'/../'* && $DATA_DIR != */.. ]] || die "网站数据目录无效。"
    [[ ${NGINX_BIN:-/usr/sbin/nginx} =~ ^/[A-Za-z0-9_./-]+$ ]] || die "Nginx 程序路径无效。"
    case "${WEB_MODE:-static}" in
        static) ;;
        redirect) rs_valid_redirect_url "${REDIRECT_URL:-}" || die "302 目标必须是有效的外部 HTTPS 地址。" ;;
        *) die "网站模式必须是 static 或 redirect。" ;;
    esac
}

rs_web_port_check() {
    rs_web_validate_context
    local listeners
    listeners=$(ss -H -ltn "( sport = :$PORT )") || die "无法检查 TCP 监听端口。"
    if [[ -n $listeners ]]; then
        die "TCP 端口 $PORT 已被占用；请选择其他内部端口，不会复用或停止现有服务。"
    fi
}

rs_web_render() {
    local output=${1:?missing output path} cert_path=${2:-$DATA_DIR/certs/live} temporary response cert_generation
    rs_web_validate_context
    # A staged domain change must test the candidate certificate, not the live one.
    cert_generation=${cert_path#"$DATA_DIR/certs/"}
    [[ $cert_path == "$DATA_DIR/certs/live" || ( $cert_path == "$DATA_DIR/certs/"* && $cert_generation =~ ^generation\.[[:alnum:]]+$ ) ]] || die '网站证书代次路径无效。'
    rs_assert_owned_output "$output"
    if [[ ${WEB_MODE:-static} == redirect ]]; then
        # The URL validator rejects nginx variables, quotes and control bytes.
        # Do not append $request_uri: the destination is exactly what was saved.
        printf -v response '        add_header Cache-Control "no-store" always;\n        return 302 "%s";' "$REDIRECT_URL"
    else
        # Keep nginx's $uri variables literal in the generated configuration.
        # shellcheck disable=SC2016
        response='        root '"$DATA_DIR"'/www;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }
        location ~ /\. {
            deny all;
        }'
    fi
    temporary=$(mktemp "${output}.tmp.XXXXXX") || return 1
    if ! cat >"$temporary" <<EOF
# Managed by reality-site
# Separate from /etc/nginx/nginx.conf.
user www-data;
# A single worker is sufficient for this small HTTPS REALITY target.
worker_processes 1;
pid $DATA_DIR/nginx/nginx.pid;
error_log $DATA_DIR/nginx/error.log warn;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    # Avoid unbounded per-request logs; keep error.log for diagnostics.
    access_log off;
    client_body_temp_path $DATA_DIR/nginx/client_temp;
    proxy_temp_path $DATA_DIR/nginx/proxy_temp;
    fastcgi_temp_path $DATA_DIR/nginx/fastcgi_temp;
    uwsgi_temp_path $DATA_DIR/nginx/uwsgi_temp;
    scgi_temp_path $DATA_DIR/nginx/scgi_temp;
    sendfile on;
    keepalive_timeout 65;
    server_tokens off;

    server {
        # Only the loopback address is exposed. Xray owns public TCP 443.
        listen 127.0.0.1:$PORT ssl http2;
        server_name $DOMAIN;
        ssl_certificate $cert_path/fullchain.pem;
        ssl_certificate_key $cert_path/key.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:reality_site_tls:10m;
        ssl_session_timeout 1d;
$response
    }
}
EOF
    then
        rm -f -- "$temporary"
        return 1
    fi
    if ! chmod 600 "$temporary" || ! mv -f -- "$temporary" "$output"; then
        rm -f -- "$temporary"
        return 1
    fi
}

rs_web_validate_page() {
    local source=${1:-} bytes
    [[ -n $source && -f $source && ! -L $source && -r $source ]] || die "网页必须是可读的普通 HTML 文件，不能是符号链接。"
    bytes=$(stat -c %s -- "$source") || die "无法读取网页文件大小。"
    (( bytes > 0 && bytes <= 10485760 )) || die "网页大小必须为 1 字节至 10 MiB。"
    LC_ALL=C grep -aiEq '<!doctype[[:space:]]+html|<html([[:space:]>])' "$source" || die "未发现 HTML 文档标记；请选择完整 HTML 文件。"
}

rs_web_set_page() {
    local source=${1:-} destination="$DATA_DIR/www/index.html" temporary backup=''
    rs_web_validate_page "$source"
    [[ -d $DATA_DIR/www && ! -L $DATA_DIR/www ]] || die "网站目录尚未创建或不安全。"
    [[ ! -L $destination ]] || die "拒绝替换符号链接网页。"
    [[ -d $DATA_DIR/backups && ! -L $DATA_DIR/backups ]] || die "备份目录尚未创建或不安全。"
    if [[ -e $destination ]]; then
        rs_secure_file "$destination"
        backup=$(mktemp "$DATA_DIR/backups/index.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX.html") || return 1
        if ! cp -- "$destination" "$backup" || ! chmod 600 "$backup"; then
            rm -f -- "$backup"
            die "备份现有网页失败，原网页未变更。"
        fi
    fi
    # Stage beside index.html so rename is atomic, even if /tmp is another mount.
    temporary=$(mktemp "$DATA_DIR/www/.index.XXXXXX") || return 1
    if ! cp -- "$source" "$temporary" || ! chown root:root "$temporary" || ! chmod 644 "$temporary"; then
        rm -f -- "$temporary"
        die "准备新网页失败，原网页未变更。"
    fi
    # Validate the copied bytes too, not only the potentially changing input file.
    if ! (rs_web_validate_page "$temporary"); then
        rm -f -- "$temporary"
        die "新网页校验失败，原网页未变更。"
    fi
    if ! mv -f -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        die "替换网页失败，原网页未变更。"
    fi
    info "网页已更新；仅复制该 HTML 文件，外部资源需自行保持可访问。"
    if [[ ${WEB_MODE:-static} == redirect ]]; then
        info "当前为 302 跳转模式，保存的网页尚未对外显示；执行 set-mode static 可恢复本地网页。"
    fi
    [[ -z $backup ]] || info "原网页备份：$backup"
}

rs_web_install() {
    rs_web_validate_context
    local path source=${STATIC_SOURCE:-${APP_DIR:?}/assets/index.html}
    local unit=${RS_UNIT_DIR:-/etc/systemd/system}/${SERVICE_NAME:-reality-site.service}
    local unit_stage
    # The main program owns DATA_DIR and coordinates repeat installs/rollback.
    for path in "$DATA_DIR/www" "$DATA_DIR/nginx" "$DATA_DIR/backups"; do
        [[ ! -L $path && ( ! -e $path || -d $path ) ]] || die "目录路径不安全：$path"
        install -d -o root -g root -m 755 "$path" || return 1
    done
    chmod 700 "$DATA_DIR/backups" || return 1
    for path in client_temp proxy_temp fastcgi_temp uwsgi_temp scgi_temp; do
        path="$DATA_DIR/nginx/$path"
        [[ ! -L $path && ( ! -e $path || -d $path ) ]] || die "临时目录路径不安全：$path"
        install -d -o www-data -g www-data -m 700 "$path" || return 1
    done
    if [[ -n ${STATIC_SOURCE:-} || ( ! -e $DATA_DIR/www/index.html && ! -L $DATA_DIR/www/index.html ) ]]; then
        rs_web_set_page "$source" || return 1
    else
        # Retry an interrupted install without replacing a user's saved page.
        rs_secure_file "$DATA_DIR/www/index.html"
        rs_web_validate_page "$DATA_DIR/www/index.html"
    fi
    rs_web_render "$DATA_DIR/nginx.conf" || return 1
    "${NGINX_BIN:-/usr/sbin/nginx}" -t -q -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf" || {
        warn "独立 Nginx 配置检查失败；未启动网站服务。"
        return 1
    }
    rs_assert_owned_output "$unit"
    unit_stage=$(mktemp "${unit}.tmp.XXXXXX") || return 1
    if ! cat >"$unit_stage" <<EOF
# Managed by reality-site
[Unit]
Description=Local HTTPS website for a 3x-ui REALITY target
After=network.target

[Service]
Type=forking
PIDFile=$DATA_DIR/nginx/nginx.pid
ExecStartPre=${NGINX_BIN:-/usr/sbin/nginx} -t -q -p $DATA_DIR/nginx/ -c $DATA_DIR/nginx.conf
ExecStart=${NGINX_BIN:-/usr/sbin/nginx} -p $DATA_DIR/nginx/ -c $DATA_DIR/nginx.conf
ExecReload=${NGINX_BIN:-/usr/sbin/nginx} -p $DATA_DIR/nginx/ -c $DATA_DIR/nginx.conf -s reload
KillSignal=SIGQUIT
KillMode=mixed
TimeoutStopSec=15s
Restart=on-failure
RestartSec=3s
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$DATA_DIR/nginx

[Install]
WantedBy=multi-user.target
EOF
    then
        rm -f -- "$unit_stage"
        return 1
    fi
    if ! chmod 644 "$unit_stage" || ! mv -f -- "$unit_stage" "$unit"; then
        rm -f -- "$unit_stage"
        return 1
    fi
    systemctl daemon-reload || return 1
    # Shared with the entry point's failed-install cleanup trap.
    # shellcheck disable=SC2034
    RS_WEB_STARTED=1
    if ! systemctl enable --now "${SERVICE_NAME:-reality-site.service}"; then
        systemctl stop "${SERVICE_NAME:-reality-site.service}" || true
        warn "本机网站启动失败，请检查：journalctl -u ${SERVICE_NAME:-reality-site.service} 和 $DATA_DIR/nginx/error.log"
        return 1
    fi
}

rs_web_check() {
    # Optional CA file supports isolated tests. No insecure/TLS-skip mode exists.
    local ca_file=${1:-} tls_output headers status location
    local -a openssl_ca=() curl_ca=()
    rs_web_validate_context
    if [[ -n $ca_file ]]; then
        [[ -f $ca_file && ! -L $ca_file && -r $ca_file ]] || die "CA 证书文件不可读。"
        openssl_ca=(-CAfile "$ca_file")
        curl_ca=(--cacert "$ca_file")
    fi
    if ! tls_output=$(timeout 15s openssl s_client -connect "127.0.0.1:$PORT" \
        -servername "$DOMAIN" -verify_hostname "$DOMAIN" -verify_return_error \
        -tls1_3 -alpn h2 "${openssl_ca[@]}" </dev/null 2>&1); then
        warn "本机 TLS 1.3/证书验证失败。请检查域名、证书有效期和网站服务。"
        return 1
    fi
    if ! grep -Fq 'ALPN protocol: h2' <<<"$tls_output"; then
        warn "本机 HTTPS 未协商出 h2，请检查 Nginx HTTP/2 支持。"
        return 1
    fi
    headers=$(mktemp "${TMP_DIR:-/tmp}/reality-site-headers.XXXXXX") || return 1
    # Never follow redirects: only the local target and its own certificate are tested.
    if ! status=$(curl -q --silent --show-error --fail --noproxy '*' --connect-timeout 5 \
        --max-time 15 --resolve "$DOMAIN:$PORT:127.0.0.1" "${curl_ca[@]}" \
        --dump-header "$headers" --write-out '%{http_code}' --output /dev/null "https://$DOMAIN:$PORT/"); then
        rm -f -- "$headers"
        warn "本机 HTTPS 首页读取失败。"
        return 1
    fi
    location=$(LC_ALL=C awk 'tolower(substr($0,1,9)) == "location:" { line=substr($0,10); sub(/^[ \t]+/,"",line); sub(/\r$/,"",line); print line }' "$headers")
    rm -f -- "$headers"
    if [[ ${WEB_MODE:-static} == redirect ]]; then
        if [[ $status != 302 || $location != "$REDIRECT_URL" ]]; then
            warn "本机 HTTPS 未返回预期的 302 状态码及 Location 地址。"
            return 1
        fi
        info "本机检查通过：TLS 1.3、域名/证书验证、ALPN h2、302 跳转地址。未访问外部目标。"
    else
        [[ $status == 200 ]] || { warn "本机静态首页未返回 HTTP 200。"; return 1; }
        info "本机检查通过：TLS 1.3、域名/证书验证、ALPN h2、HTTPS 静态首页。"
    fi
    info "此检查不验证公网 443；该入口仍需在 3x-ui 中配置 REALITY。"
}

rs_web_restore_mode_file() {
    local source=$1 destination=$2 temporary
    temporary=$(mktemp "${destination}.restore.XXXXXX") || return 1
    if ! cp -- "$source" "$temporary" || ! chmod 600 "$temporary" || ! mv -f -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
}

rs_web_rollback_mode() {
    [[ ${RS_MODE_PENDING:-0} == 1 ]] || return 0
    local failed=0
    rs_web_restore_mode_file "$RS_MODE_CONFIG_BACKUP" "$DATA_DIR/nginx.conf" || failed=1
    rs_web_restore_mode_file "$RS_MODE_STATE_BACKUP" "$STATE_FILE" || failed=1
    WEB_MODE=$RS_MODE_OLD_MODE
    REDIRECT_URL=$RS_MODE_OLD_URL
    [[ -z ${RS_MODE_STAGE:-} ]] || rm -f -- "$RS_MODE_STAGE"
    if (( failed == 0 )); then
        if ! "${NGINX_BIN:-/usr/sbin/nginx}" -t -q -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf" ||
            ! systemctl reload "${SERVICE_NAME:-reality-site.service}"; then
            failed=1
        fi
    fi
    RS_MODE_PENDING=0
    if (( failed )); then
        warn "网站模式回滚未完全成功，请检查本工具的服务。备份：$RS_MODE_CONFIG_BACKUP 和 $RS_MODE_STATE_BACKUP"
        return 1
    fi
    warn "已恢复切换前的网站配置及状态。"
}

rs_web_set_mode() {
    local mode=${1:-} url=${2:-} unit
    case "$mode" in
        static) [[ -z $url ]] || die "static 模式不接受跳转地址。" ;;
        redirect) rs_valid_redirect_url "$url" || die "302 目标必须是有效的外部 HTTPS 地址。" ;;
        *) die "网站模式必须是 static 或 redirect。" ;;
    esac
    rs_web_validate_context
    rs_secure_dir "$DATA_DIR/backups"
    rs_secure_file "$STATE_FILE"
    [[ $(jq -r .status "$STATE_FILE") == ready ]] || die "安装尚未完成，请先执行 install。"
    [[ -f $DATA_DIR/nginx.conf ]] || die "未发现本工具的网站配置。"
    rs_assert_owned_output "$DATA_DIR/nginx.conf"
    unit=${RS_UNIT_DIR:-/etc/systemd/system}/${SERVICE_NAME:-reality-site.service}
    [[ -f $unit ]] || die "未发现本工具的网站服务。"
    rs_assert_owned_output "$unit"
    systemctl is-active --quiet "${SERVICE_NAME:-reality-site.service}" || die "网站服务未运行，请先处理服务故障，再切换模式。"
    if [[ $mode == "${WEB_MODE:-static}" && $url == "${REDIRECT_URL:-}" ]]; then
        info "已是所选网站模式，无需变更。"
        return 0
    fi
    if [[ $mode == static ]]; then
        rs_secure_file "$DATA_DIR/www/index.html"
        rs_web_validate_page "$DATA_DIR/www/index.html"
    fi
    RS_MODE_CONFIG_BACKUP=$(mktemp "$DATA_DIR/backups/mode-nginx.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX.conf") || return 1
    if ! cp -- "$DATA_DIR/nginx.conf" "$RS_MODE_CONFIG_BACKUP" || ! chmod 600 "$RS_MODE_CONFIG_BACKUP"; then
        rm -f -- "$RS_MODE_CONFIG_BACKUP"
        return 1
    fi
    RS_MODE_STATE_BACKUP=$(mktemp "$DATA_DIR/backups/mode-state.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX.json") || return 1
    if ! cp -- "$STATE_FILE" "$RS_MODE_STATE_BACKUP" || ! chmod 600 "$RS_MODE_STATE_BACKUP"; then
        rm -f -- "$RS_MODE_STATE_BACKUP"
        return 1
    fi
    RS_MODE_STAGE=$(mktemp "$DATA_DIR/.nginx-mode.XXXXXX") || return 1
    printf '%s\n' '# Managed by reality-site' > "$RS_MODE_STAGE" || return 1
    RS_MODE_OLD_MODE=${WEB_MODE:-static}
    RS_MODE_OLD_URL=${REDIRECT_URL:-}
    RS_MODE_PENDING=1
    WEB_MODE=$mode
    REDIRECT_URL=$url
    if ! (rs_web_render "$RS_MODE_STAGE") ||
        ! "${NGINX_BIN:-/usr/sbin/nginx}" -t -q -p "$DATA_DIR/nginx/" -c "$RS_MODE_STAGE" ||
        ! mv -f -- "$RS_MODE_STAGE" "$DATA_DIR/nginx.conf" ||
        ! systemctl reload "${SERVICE_NAME:-reality-site.service}" ||
        ! rs_write_state ready; then
        rs_web_rollback_mode || true
        warn "网站模式切换失败。"
        return 1
    fi
    RS_MODE_PENDING=0
    RS_MODE_STAGE=''
    if [[ $mode == redirect ]]; then
        info "已切换为 302 跳转模式：$REDIRECT_URL"
        info "浏览器地址栏会跳转到外站；本地网页已保留，REALITY target/SNI 无需修改。"
    else
        info "已恢复本地静态网页；REALITY target/SNI 无需修改。"
    fi
}
