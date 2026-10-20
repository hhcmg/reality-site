#!/usr/bin/env bash
# Change only this tool's website identity. Xray and public DNS stay user-managed.

rs_domain_with_name() {
    # Dynamically scoped for the certificate/web helpers; never changes the caller.
    # shellcheck disable=SC2034
    local DOMAIN=$1
    shift
    ("$@")
}

rs_domain_validate_backup() {
    local STATE_FILE=$1
    (rs_load_state)
}

rs_domain_recover() (
    local marker="$DATA_DIR/.domain-change.pending" name backup old_target failed=0
    [[ -e $marker || -L $marker ]] || return 0
    rs_require_root
    rs_secure_dir "$DATA_DIR"
    rs_secure_file "$DATA_DIR/.managed-by"
    [[ $(cat "$DATA_DIR/.managed-by") == reality-site-v1 ]] || die '域名恢复的数据目录归属不匹配。'
    rs_secure_file "$marker"
    name=$(cat -- "$marker") || return 1
    [[ $name =~ ^domain\.[0-9]{8}T[0-9]{6}Z\.[[:alnum:]]+$ ]] || die '域名恢复标记无效，未修改文件。'
    rs_secure_dir "$DATA_DIR/backups"
    backup="$DATA_DIR/backups/$name"
    rs_cert_private_dir "$backup"
    rs_secure_file "$backup/state.json"
    rs_secure_file "$backup/nginx.conf"
    rs_secure_file "$backup/cert-target"
    rs_assert_owned_output "$backup/nginx.conf"
    # Validate the saved state before restoring it, without trusting shell input.
    rs_domain_validate_backup "$backup/state.json" || return 1
    old_target=$(cat -- "$backup/cert-target") || return 1
    [[ $old_target =~ ^generation\.[[:alnum:]]+$ ]] || die '旧证书代次标记无效。'
    rs_cert_paths
    rs_cert_private_dir "$CERT_DIR"
    rs_cert_private_dir "$CERT_DIR/$old_target"
    rs_secure_file "$CERT_DIR/$old_target/fullchain.pem"
    rs_secure_file "$CERT_DIR/$old_target/key.pem"
    rs_assert_owned_output "$DATA_DIR/nginx.conf"
    if [[ -e $STATE_FILE || -L $STATE_FILE ]]; then rs_secure_file "$STATE_FILE"; fi
    [[ -f $RS_UNIT_DIR/$SERVICE_NAME ]] || die '缺少本工具的网站服务，保留域名恢复标记。'
    rs_assert_owned_output "$RS_UNIT_DIR/$SERVICE_NAME"
    # Keep the journal until both disk state and the running service are restored.
    rs_cert_switch_link "$old_target" || failed=1
    rs_web_restore_mode_file "$backup/nginx.conf" "$DATA_DIR/nginx.conf" || failed=1
    rs_web_restore_mode_file "$backup/state.json" "$STATE_FILE" || failed=1
    if (( failed == 0 )); then
        if ! "$NGINX_BIN" -t -q -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf"; then
            failed=1
        elif systemctl is-active --quiet "$SERVICE_NAME"; then
            systemctl reload "$SERVICE_NAME" || failed=1
        else
            # The transaction requires a running site before it starts.
            systemctl start "$SERVICE_NAME" || failed=1
        fi
    fi
    if (( failed )); then
        warn "域名恢复未完成，已保留恢复标记；下次运行会重试。备份：$backup"
        return 1
    fi
    rm -f -- "$marker" || return 1
    warn "已恢复更换域名前的网站、证书和续期配置。备份：$backup"
)

rs_domain_check_new_site() {
    local attempt
    # nginx -s reload returns before all old workers have drained.
    for attempt in 1 2 3; do
        if (rs_web_check ''); then return 0; fi
        if (( attempt < 3 )); then sleep 1; fi
    done
    return 1
}

rs_domain_apply() (
    local config=$1 generation=$2
    rs_cert_switch_link "$generation" || return 1
    mv -f -- "$config" "$DATA_DIR/nginx.conf" || return 1
    "$NGINX_BIN" -t -q -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf" || return 1
    systemctl reload "$SERVICE_NAME" || return 1
    rs_domain_check_new_site || return 1
    rs_write_state ready || return 1
    # Commit only after the new domain is actually served and renewal state saved.
    rm -f -- "$DATA_DIR/.domain-change.pending" || return 1
)

# Transaction flag is consumed by the entry point's EXIT/signal cleanup.
# shellcheck disable=SC2034
rs_domain_set() {
    [[ $# == 1 || $# == 3 ]] || die '用法：set-domain 新域名 [完整证书链 私钥]。'
    local next_domain=${1,,} old_domain=$DOMAIN generation backup marker stage
    local candidate="$TMP_DIR/domain-candidate.conf" final
    local old_target
    rs_require_root
    rs_valid_domain "$next_domain" || die '新域名格式不正确，请勿填写协议、端口、路径或通配符。'
    [[ $(jq -r .status "$STATE_FILE") == ready ]] || die '安装尚未完成，请先执行 install。'
    if [[ $next_domain == "$DOMAIN" ]]; then
        [[ $# == 1 ]] || die '域名未改变；替换证书请使用 import-cert。'
        info '已经使用该域名，无需重新申请证书或重载。'
        rs_panel
        return 0
    fi
    case "$CERT_MODE" in
        cloudflare) [[ $# == 1 ]] || die 'Cloudflare 模式更换域名会自动申请证书，不接受证书文件参数。' ;;
        manual) [[ $# == 3 ]] || die '手动证书模式需要：set-domain 新域名 FULLCHAIN KEY。' ;;
        *) die '不支持的证书模式。' ;;
    esac
    # All three settings must move together; do not silently create a 302 loop.
    if ! rs_domain_with_name "$next_domain" rs_valid_web_settings; then
        die '当前 302 地址与新域名冲突或无效，请先调整跳转地址再更换域名。'
    fi
    rs_secure_dir "$DATA_DIR/backups"
    rs_secure_file "$STATE_FILE"
    [[ -f $DATA_DIR/nginx.conf && -f $RS_UNIT_DIR/$SERVICE_NAME ]] || die '缺少本工具的网站配置或服务。'
    rs_assert_owned_output "$DATA_DIR/nginx.conf"
    rs_assert_owned_output "$RS_UNIT_DIR/$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" || die '网站服务未运行，请先处理服务故障，再更换域名。'
    rs_cert_paths
    rs_cert_private_dir "$CERT_DIR"
    [[ -L $CERT_DIR/live ]] || die '当前证书不是本工具管理的代次链接。'
    old_target=$(readlink -- "$CERT_DIR/live") || return 1
    [[ $old_target =~ ^generation\.[[:alnum:]]+$ ]] || die '当前证书链接不属于本工具。'
    rs_cert_private_dir "$CERT_DIR/$old_target"
    rs_secure_file "$CERT_DIR/$old_target/fullchain.pem"
    rs_secure_file "$CERT_DIR/$old_target/key.pem"
    marker="$DATA_DIR/.domain-change.pending"
    [[ ! -e $marker && ! -L $marker ]] || die '存在未恢复的域名操作，请重新运行正式入口以恢复。'
    # Migrate the legacy Zone ID under the old domain before DOMAIN is changed.
    if [[ "$CERT_MODE" == cloudflare ]]; then rs_cert_cf_sync_hook || return 1; fi

    generation=$(mktemp -d "$CERT_DIR/generation.XXXXXXXX") || return 1
    # The old site and state stay live throughout certificate issuance.
    info "正在为 $next_domain 准备证书，原网站仍使用 $old_domain。"
    if ! rs_domain_with_name "$next_domain" rs_cert_prepare_domain "$generation/fullchain.pem" "$generation/key.pem" "${@:2}"; then
        warn '新域名证书准备失败，原网站和续期配置未改变。'
        return 1
    fi
    # Stage beside nginx.conf so publication remains an atomic rename when /tmp
    # is a separate filesystem. An interrupted cross-device mv could truncate it.
    final=$(mktemp "$DATA_DIR/.nginx-domain.XXXXXXXX") || return 1
    printf '%s\n' '# Managed by reality-site' > "$final" || return 1
    if ! rs_domain_with_name "$next_domain" rs_web_render "$candidate" "$generation" ||
        ! "$NGINX_BIN" -t -q -p "$DATA_DIR/nginx/" -c "$candidate" ||
        ! rs_domain_with_name "$next_domain" rs_web_render "$final"; then
        rm -f -- "$final"
        warn '新域名网站配置检查失败，原网站未改变。'
        return 1
    fi
    backup=$(mktemp -d "$DATA_DIR/backups/domain.$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX") || return 1
    if ! cp -- "$STATE_FILE" "$backup/state.json" ||
        ! cp -- "$DATA_DIR/nginx.conf" "$backup/nginx.conf" ||
        ! printf '%s\n' "$old_target" > "$backup/cert-target" ||
        ! chmod 600 "$backup/state.json" "$backup/nginx.conf" "$backup/cert-target"; then
        return 1
    fi
    stage=$(mktemp "$DATA_DIR/.domain-journal.XXXXXXXX") || return 1
    if ! printf '%s\n' "${backup##*/}" > "$stage" || ! chmod 600 "$stage"; then
        rm -f -- "$stage"
        return 1
    fi
    # Set the cleanup flag first so a signal cannot skip a published journal.
    RS_DOMAIN_PENDING=1
    if ! mv -f -- "$stage" "$marker"; then
        RS_DOMAIN_PENDING=0
        rm -f -- "$stage"
        return 1
    fi
    if ! rs_domain_with_name "$next_domain" rs_domain_apply "$final" "${generation##*/}"; then
        rs_domain_recover || warn '请修复服务问题并重新运行脚本以完成恢复。'
        RS_DOMAIN_PENDING=0
        warn '更换域名未完成。'
        return 1
    fi
    RS_DOMAIN_PENDING=0
    rs_load_state
    info "域名已更换：$old_domain → $DOMAIN；端口、网页和响应模式均保留。"
    info "原配置备份：$backup；旧证书保留，不再为旧域名执行本工具的定时续期。"
    info '请更新 3x-ui 的 REALITY SNI 及客户端配置；确认公网节点和网站正常后，再删除旧 DNS 记录。'
    rs_panel
}
