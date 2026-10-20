#!/usr/bin/env bash
# Certificate provisioning for the local HTTPS target. Never manages Xray.

RS_ACME_VERSION='3.1.4'
RS_ACME_COMMIT='3661fd86b6304115e42f43910e6dd452ab9866d6'
RS_ACME_SHA256='9af3ad3d775a5782246df4cdd4b4e7b9b3179deb63c509b10e3ba0433093a884'

rs_cert_paths() {
    ACME_HOME="$DATA_DIR/acme"
    CERT_DIR="$DATA_DIR/certs"
}

rs_cert_private_dir() {
    local dir=$1 owner mode
    if [[ -e "$dir" || -L "$dir" ]]; then
        [[ -d "$dir" && ! -L "$dir" ]] || die "证书目录不是普通目录：$dir"
        owner=$(stat -c '%u' -- "$dir")
        mode=$(stat -c '%a' -- "$dir")
        [[ "$owner" == 0 && "$mode" == 700 ]] || die "证书目录必须归 root 所有且权限为 0700：$dir"
    else
        install -d -o root -g root -m 0700 -- "$dir" || die "无法创建私有证书目录：$dir"
    fi
}

# The optional trust store is for offline validation tests; publish always uses
# the OS trust store. A PEM fullchain must start with the server certificate.
rs_cert_validate() {
    local fullchain=$1 key=$2 trust=${3:-/etc/ssl/certs/ca-certificates.crt}
    local leaf="$TMP_DIR/certificate-leaf.pem" cert_pub key_pub
    [[ -s "$fullchain" && -f "$fullchain" && ! -L "$fullchain" ]] || { warn '证书链文件不存在、为空或是软链接。'; return 1; }
    [[ -s "$key" && -f "$key" && ! -L "$key" ]] || { warn '私钥文件不存在、为空或是软链接。'; return 1; }
    openssl x509 -in "$fullchain" -out "$leaf" 2>/dev/null || { warn '无法读取 PEM 证书。'; return 1; }
    openssl x509 -in "$leaf" -checkend 86400 -noout >/dev/null 2>&1 || { warn '证书已过期或剩余有效期不足 24 小时。'; return 1; }
    openssl pkey -in "$key" -passin pass: -check -noout >/dev/null 2>&1 || { warn '私钥无效或已加密；Nginx 需要无需交互口令的私钥。'; return 1; }
    cert_pub=$(openssl x509 -in "$leaf" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) || return 1
    key_pub=$(openssl pkey -in "$key" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum) || return 1
    [[ "$cert_pub" == "$key_pub" ]] || { warn '证书和私钥不匹配。'; return 1; }
    openssl verify -CAfile "$trust" -no-CApath -purpose sslserver \
        -verify_hostname "$DOMAIN" -untrusted "$fullchain" "$leaf" >/dev/null 2>&1 \
        || { warn "证书未通过系统信任链、有效期或域名校验：$DOMAIN。请提供公有 CA 签发的完整证书链。"; return 1; }
}

rs_cert_switch_link() {
    local target=$1 link
    link=$(mktemp "$CERT_DIR/.live.XXXXXX") || return 1
    rm -f -- "$link" || return 1
    ln -s -- "$target" "$link" || return 1
    mv -Tf -- "$link" "$CERT_DIR/live"
}

rs_cert_publish() {
    local source_chain=$1 source_key=$2 generation old='' failed=0 active=0
    rs_require_root
    rs_cert_paths
    rs_cert_private_dir "$CERT_DIR"
    rs_secure_file "$source_chain"
    rs_secure_file "$source_key"
    if [[ -e "$DATA_DIR/nginx.conf" || -L "$DATA_DIR/nginx.conf" ]]; then
        rs_assert_owned_output "$DATA_DIR/nginx.conf"
    fi
    if [[ -L "$CERT_DIR/live" ]]; then
        old=$(readlink -- "$CERT_DIR/live")
        [[ "$old" =~ ^generation\.[[:alnum:]]+$ ]] || die '当前证书链接不是本程序创建的代次，拒绝覆盖。'
        rs_cert_private_dir "$CERT_DIR/$old"
    elif [[ -e "$CERT_DIR/live" ]]; then
        die 'certs/live 不是证书代次软链接，拒绝覆盖。'
    fi
    generation=$(mktemp -d "$CERT_DIR/generation.XXXXXXXX") || die '无法创建证书代次目录。'
    # Validate the private, immutable candidate rather than the caller's files.
    install -o root -g root -m 0600 -- "$source_chain" "$generation/fullchain.pem" || die '无法暂存证书链。'
    install -o root -g root -m 0600 -- "$source_key" "$generation/key.pem" || die '无法暂存私钥。'
    if ! rs_cert_validate "$generation/fullchain.pem" "$generation/key.pem"; then
        rm -f -- "$generation/fullchain.pem" "$generation/key.pem"
        rmdir -- "$generation"
        die '证书校验失败，现有证书未改变。'
    fi
    if [[ -n "$old" ]] && cmp -s -- "$generation/fullchain.pem" "$CERT_DIR/$old/fullchain.pem" \
        && cmp -s -- "$generation/key.pem" "$CERT_DIR/$old/key.pem"; then
        rm -f -- "$generation/fullchain.pem" "$generation/key.pem"
        rmdir -- "$generation"
        info '证书未发生变化，无需重新加载网站。'
        return 0
    fi
    rs_cert_switch_link "${generation##*/}" || die '无法切换证书代次。'
    if [[ -e "$DATA_DIR/nginx.conf" || -L "$DATA_DIR/nginx.conf" ]]; then
        systemctl is-active --quiet "$SERVICE_NAME" && active=1
        "$NGINX_BIN" -t -c "$DATA_DIR/nginx.conf" -p "$DATA_DIR/nginx/" || failed=1
        if (( failed == 0 && active == 1 )); then
            systemctl reload "$SERVICE_NAME" || failed=1
        fi
        if (( failed == 1 )); then
            if [[ -n "$old" ]]; then
                rs_cert_switch_link "$old" || die '证书应用失败，恢复旧证书链接也失败，请检查服务。'
                if (( active == 1 )); then
                    if "$NGINX_BIN" -t -c "$DATA_DIR/nginx.conf" -p "$DATA_DIR/nginx/"; then
                        systemctl reload "$SERVICE_NAME" || warn '旧证书已恢复，但 Nginx reload 失败。'
                    else
                        warn '旧证书已恢复，但 Nginx 配置仍未通过检查。'
                    fi
                fi
            else
                rm -f -- "$CERT_DIR/live"
            fi
            die '新证书未能应用，已恢复此前的证书状态。'
        fi
    fi
    info "证书已发布：$DOMAIN（旧代次保留以供恢复）。"
}

rs_cert_import() {
    [[ $# == 2 ]] || die '导入证书需要 fullchain.pem 和私钥两个文件路径。'
    rs_cert_publish "$1" "$2"
}

rs_cert_run_acme() (
    umask 077
    env -i HOME=/root USER=root LOGNAME=root SHELL=/bin/sh LC_ALL=C \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$ACME_HOME/acme.sh" --home "$ACME_HOME" --config-home "$ACME_HOME" \
        --cert-home "$ACME_HOME" --no-color "$@"
)

rs_cert_install_acme() {
    local archive="$TMP_DIR/acme.tar.gz" source_dir="$TMP_DIR/acme.sh-$RS_ACME_COMMIT"
    # Match literal upstream shell source; $HTTP_HEADER must not expand here.
    # shellcheck disable=SC2016
    local old='_ACME_CURL="curl --silent --dump-header $HTTP_HEADER "'
    # shellcheck disable=SC2016
    local patched='_ACME_CURL="curl -q --silent --dump-header $HTTP_HEADER "'
    rs_cert_private_dir "$ACME_HOME"
    if [[ -e "$ACME_HOME/acme.sh" || -L "$ACME_HOME/acme.sh" ]]; then
        rs_secure_file "$ACME_HOME/acme.sh"
        grep -Fxq "VER=$RS_ACME_VERSION" "$ACME_HOME/acme.sh" || die '已有 acme.sh 版本与本模块固定版本不同。'
        [[ $(grep -Fc -- "$patched" "$ACME_HOME/acme.sh") == 1 ]] || die '已有 acme.sh 缺少已审计的 curl -q 配置。'
        [[ -x "$ACME_HOME/acme.sh" ]] || die '已有 acme.sh 不可执行。'
        return 0
    fi
    info "下载并校验固定版本 acme.sh $RS_ACME_VERSION。"
    curl -q --noproxy '*' --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --silent --show-error --location --connect-timeout 15 --max-time 180 \
        "https://codeload.github.com/acmesh-official/acme.sh/tar.gz/$RS_ACME_COMMIT" -o "$archive" || die '下载 acme.sh 失败。'
    [[ "$(sha256sum -- "$archive" | awk '{print $1}')" == "$RS_ACME_SHA256" ]] || die 'acme.sh 下载文件 SHA-256 校验失败。'
    tar -xzf "$archive" -C "$TMP_DIR" || die '无法解压已校验的 acme.sh。'
    grep -Fxq "VER=$RS_ACME_VERSION" "$source_dir/acme.sh" || die 'acme.sh 源码版本不匹配。'
    [[ $(grep -Fc -- "$old" "$source_dir/acme.sh") == 1 ]] || die 'acme.sh curl 初始化代码与审计版本不一致。'
    # Keep the upstream variable reference literal in the patched shell source.
    # shellcheck disable=SC2016
    sed 's/_ACME_CURL="curl --silent --dump-header $HTTP_HEADER "/_ACME_CURL="curl -q --silent --dump-header $HTTP_HEADER "/' \
        "$source_dir/acme.sh" > "$TMP_DIR/acme-patched.sh" || die '无法准备 acme.sh。'
    sh -n "$TMP_DIR/acme-patched.sh" || die 'acme.sh 语法检查失败。'
    # Copy only the CLI; do not run the upstream installer or create its cron job.
    install -o root -g root -m 0700 -- "$TMP_DIR/acme-patched.sh" "$ACME_HOME/acme.sh" || die '无法安装 acme.sh。'
}

rs_cert_cf_api_get() {
    # `token` is local to the calling credential/discovery operation. Keep it
    # off argv and out of the exported environment, including curl's environment.
    printf 'header = "Authorization: Bearer %s"\n' "$token" |
        env -i LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        /usr/bin/curl -q --config - --noproxy '*' --proto '=https' --tlsv1.2 \
        --cacert /etc/ssl/certs/ca-certificates.crt --fail-with-body \
        --silent --show-error --connect-timeout 15 --max-time 45 \
        "https://api.cloudflare.com/client/v4/$1"
}

rs_cert_cf_discover_zone() (
    set +x
    local candidate=${1,,} response count zone_id
    rs_valid_domain "$candidate" || die '域名格式不正确，无法查询 Cloudflare 区域。'
    [[ "$token" =~ ^[A-Za-z0-9_-]{20,200}$ ]] || die 'Token 格式不正确。'
    # Exact queries, most-specific first; never guess the last two labels of
    # domains such as example.co.uk. Only an empty successful reply tries a parent.
    while [[ "$candidate" == *.* ]]; do
        if ! response=$(rs_cert_cf_api_get "zones?name=$candidate&match=all&page=1&per_page=50"); then
            die 'Cloudflare 区域查询失败；请检查网络、Token 的 Zone Read 权限及区域资源范围。'
        fi
        if ! jq -se --arg name "$candidate" '
            length == 1 and (.[0] |
                type == "object" and .success == true and (.result | type == "array")
                and all(.result[]; type == "object" and (.name | type == "string")
                    and (.name | ascii_downcase) == $name and (.id | type == "string"))
                and (if has("result_info") then
                    .result_info as $info | (.result | length) as $count |
                    ($info | type == "object")
                    and (if $info | has("total_count") then $info.total_count == $count else true end)
                    and (if $info | has("count") then $info.count == $count else true end)
                    and (if $info | has("page") then $info.page == 1 else true end)
                    and (if $info | has("total_pages") then
                        $info.total_pages == 0 or $info.total_pages == 1
                    else true end)
                else true end))
            ' <<< "$response" >/dev/null 2>&1; then
            die 'Cloudflare 区域响应异常或请求被拒绝；请确认 Zone Read 权限和区域资源范围。'
        fi
        count=$(jq -r '.result | length' <<< "$response") || exit 1
        if [[ "$count" == 1 ]]; then
            zone_id=$(jq -r '.result[0].id' <<< "$response") || exit 1
            [[ "$zone_id" =~ ^[A-Fa-f0-9]{32}$ ]] || die 'Cloudflare 返回的 Zone ID 格式无效。'
            info "已自动识别 Cloudflare 区域：$candidate。" >&2
            printf '%s\n' "$zone_id"
            exit 0
        elif [[ "$count" != 0 ]]; then
            die 'Cloudflare 返回多个同名区域，无法唯一确定 Zone ID。'
        fi
        candidate=${candidate#*.}
    done
    die '未找到对应的 Cloudflare 区域；请确认域名已添加，Token 包含该区域的 Zone Read 和 DNS Edit 权限。'
)

# Set the caller's unexported local token/zone; preserve the legacy two-line
# format so existing certificates can renew without a Zone Read permission.
rs_cert_cf_read_credentials() {
    local loaded_token='' loaded_zone='' extra=''
    export -n loaded_token loaded_zone
    rs_secure_file "$ACME_HOME/cloudflare.credentials" || return 1
    [[ $(stat -c '%a' -- "$ACME_HOME/cloudflare.credentials") == 600 ]] || die 'Cloudflare 凭据权限必须为 0600。'
    {
        IFS= read -r loaded_token || die 'Cloudflare 凭据缺少 Token。'
        IFS= read -r loaded_zone || die 'Cloudflare 凭据缺少区域 ID。'
        if IFS= read -r extra || [[ -n "$extra" ]]; then die 'Cloudflare 凭据文件格式异常。'; fi
    } < "$ACME_HOME/cloudflare.credentials"
    [[ "$loaded_token" =~ ^[A-Za-z0-9_-]{20,200}$ && "$loaded_zone" =~ ^[A-Fa-f0-9]{32}$ ]] || die 'Cloudflare 凭据格式不正确。'
    token=$loaded_token
    zone=$loaded_zone
}

rs_cert_cf_validate_zones() {
    local file="$ACME_HOME/cloudflare-zones.json"
    rs_secure_file "$file" || return 1
    [[ $(stat -c '%a' -- "$file") == 600 ]] || die 'Cloudflare 区域映射权限必须为 0600。'
    jq -se 'length == 1 and (.[0] | type == "object" and .schema == 1
        and (.zones | type == "object")
        and all(.zones | keys[]; length <= 237
            and test("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
            and (test("^[0-9.]+$") | not))
        and all(.zones[]; type == "string" and test("^[A-Fa-f0-9]{32}$")))' \
        "$file" >/dev/null 2>&1 || die 'Cloudflare 区域映射文件无效。'
}

rs_cert_cf_store_zone() {
    local mapped_domain=$1 zone_id=$2 next file="$ACME_HOME/cloudflare-zones.json"
    rs_valid_domain "$mapped_domain" || die '区域映射中的域名无效。'
    [[ "$zone_id" =~ ^[A-Fa-f0-9]{32}$ ]] || die '区域映射中的 Zone ID 无效。'
    rs_cert_private_dir "$ACME_HOME" || return 1
    if [[ -e "$file" || -L "$file" ]]; then rs_cert_cf_validate_zones || return 1; fi
    next=$(mktemp "$ACME_HOME/.zones.XXXXXXXX") || die '无法暂存区域映射。'
    if [[ -e "$file" ]]; then
        if ! jq --arg domain "$mapped_domain" --arg zone "$zone_id" '.zones[$domain] = $zone' "$file" > "$next"; then
            rm -f -- "$next"
            die '无法更新区域映射。'
        fi
    else
        if ! jq -n --arg domain "$mapped_domain" --arg zone "$zone_id" '{schema:1,zones:{($domain):$zone}}' > "$next"; then
            rm -f -- "$next"
            die '无法创建区域映射。'
        fi
    fi
    if ! chmod 600 "$next" || ! mv -Tf -- "$next" "$file"; then
        rm -f -- "$next"
        die '无法保存区域映射。'
    fi
}

# Called with the CURRENT site domain before entering a new-domain transaction.
# No API call: migrate old credentials locally, then atomically refresh the hook.
rs_cert_cf_sync_hook() (
    set +x
    umask 077
    local token='' zone='' next hook directory
    export -n token zone
    rs_require_root || exit 1
    rs_valid_domain "$DOMAIN" || die '当前域名无效，无法升级证书配置。'
    rs_cert_paths || exit 1
    for directory in "$ACME_HOME" "$ACME_HOME/dnsapi"; do
        [[ -d "$directory" && ! -L "$directory" ]] || die '缺少 ACME 目录，请先完成安装。'
        rs_cert_private_dir "$directory" || exit 1
    done
    rs_cert_cf_read_credentials || exit 1
    if [[ -e "$ACME_HOME/cloudflare-zones.json" || -L "$ACME_HOME/cloudflare-zones.json" ]]; then
        rs_cert_cf_validate_zones || exit 1
        jq -e --arg domain "$DOMAIN" '.zones | has($domain)' "$ACME_HOME/cloudflare-zones.json" >/dev/null \
            || die '区域映射缺少当前域名，未修改现有配置。'
    else
        rs_cert_cf_store_zone "$DOMAIN" "$zone" || exit 1
    fi
    token=''
    hook="$ACME_HOME/dnsapi/dns_realitysite.sh"
    if [[ -e "$hook" || -L "$hook" ]]; then rs_secure_file "$hook" || exit 1; fi
    next=$(mktemp "$ACME_HOME/dnsapi/.dns-realitysite.XXXXXXXX") || die '无法暂存 DNS hook。'
    if ! rs_cert_render_dns_hook "$next" || ! sh -n "$next" || ! chmod 700 "$next" || ! mv -Tf -- "$next" "$hook"; then
        rm -f -- "$next"
        die '无法更新 Cloudflare DNS hook。'
    fi
)

# Adding a candidate binding is harmless on rollback: the old binding and the
# shared credentials stay untouched, even if issuance or the site switch fails.
rs_cert_cf_prepare_domain() (
    set +x
    local token='' zone=''
    export -n token zone
    rs_cert_cf_read_credentials || exit 1
    rs_cert_cf_validate_zones || exit 1
    zone=$(rs_cert_cf_discover_zone "$DOMAIN") || exit 1
    rs_cert_cf_store_zone "$DOMAIN" "$zone"
)

rs_cert_cf_credentials() (
    set +x
    umask 077
    ulimit -c 0 2>/dev/null || true
    local token='' zone='' temp
    export -n token zone
    printf '%s\n' 'Cloudflare Token 需要 Zone Read + DNS Edit 权限；资源可为指定区域或所有区域。' >&2
    printf '%s\n' 'Zone ID 将根据域名自动识别，无需手动填写；请勿输入 Global API Key。' >&2
    IFS= read -r -s -p 'Cloudflare API Token（不回显）：' token </dev/tty || die '未读到 API Token。'
    printf '\n' >&2
    [[ "$token" =~ ^[A-Za-z0-9_-]{20,200}$ ]] || die 'Token 格式不正确。'
    zone=$(rs_cert_cf_discover_zone "$DOMAIN") || exit 1
    if [[ -e "$ACME_HOME/cloudflare.credentials" || -L "$ACME_HOME/cloudflare.credentials" ]]; then
        rs_secure_file "$ACME_HOME/cloudflare.credentials" || exit 1
    fi
    temp=$(mktemp "$ACME_HOME/.credentials.XXXXXX") || die '无法创建凭据文件。'
    printf '%s\n%s\n' "$token" "$zone" > "$temp" || die '无法写入凭据文件。'
    chmod 0600 "$temp" || die '无法设置凭据文件权限。'
    token=''
    mv -Tf -- "$temp" "$ACME_HOME/cloudflare.credentials" || die '无法保存凭据文件。'
    rs_cert_cf_store_zone "$DOMAIN" "$zone" || exit 1
)

# Prepare a frozen candidate for the domain transaction. The caller owns these
# temporary outputs and their cleanup; this never publishes or reloads them.
# Use a subshell and explicit checks because the transaction calls us under `if`.
rs_cert_prepare_domain() (
    umask 077
    [[ $# == 2 || $# == 4 ]] || die '准备域名证书需要两个输出路径，可另附证书链和私钥路径。'
    local output_chain=$1 output_key=$2 chain='' key='' result=0 path parent mode
    local canonical_chain canonical_key
    rs_require_root || exit 1
    rs_valid_domain "$DOMAIN" || die '新域名无效，无法准备证书。'
    rs_cert_paths || exit 1
    [[ "$output_chain" == /* && "$output_key" == /* ]] || die '候选证书输出必须使用绝对路径。'
    canonical_chain=$(readlink -m -- "$output_chain") || die '无法解析候选证书链路径。'
    canonical_key=$(readlink -m -- "$output_key") || die '无法解析候选私钥路径。'
    [[ "$canonical_chain" != "$canonical_key" ]] || die '候选证书链和私钥不能使用相同路径。'
    for path in "$output_chain" "$output_key"; do
        parent=$(dirname -- "$path") || die '无法解析候选证书输出目录。'
        rs_secure_dir "$parent" || exit 1
        if [[ -e "$path" || -L "$path" ]]; then
            rs_secure_file "$path" || exit 1
        fi
    done

    case "$CERT_MODE" in
        manual)
            [[ $# == 4 && "$3" == /* && "$4" == /* ]] || die '手动证书模式必须提供证书链和私钥的两个绝对路径。'
            chain=$3
            key=$4
            ;;
        cloudflare)
            [[ $# == 2 ]] || die 'Cloudflare 模式不接受手动证书参数。'
            # Do not create missing directories or repair existing files here:
            # domain changes reuse the original account and shared credentials.
            for path in "$ACME_HOME" "$ACME_HOME/dnsapi"; do
                [[ -d "$path" && ! -L "$path" ]] || die "ACME 目录不存在或不是普通目录：$path"
                rs_cert_private_dir "$path" || exit 1
            done
            for path in "$ACME_HOME/acme.sh" "$ACME_HOME/dnsapi/dns_realitysite.sh" "$ACME_HOME/cloudflare.credentials"; do
                rs_secure_file "$path" || exit 1
                mode=$(stat -c '%a' -- "$path") || die "无法检查 ACME 文件权限：$path"
                if [[ "$path" == "$ACME_HOME/cloudflare.credentials" ]]; then
                    [[ "$mode" == 600 ]] || die 'Cloudflare 凭据权限必须为 0600。'
                else
                    [[ "$mode" == 700 && -x "$path" ]] || die "ACME 程序和 DNS hook 权限必须为 0700：$path"
                fi
            done
            path="$ACME_HOME/${DOMAIN}_ecc"
            if [[ -e "$path" || -L "$path" ]]; then
                [[ -d "$path" && ! -L "$path" ]] || die '已有新域名 ACME 路径不是普通目录。'
                rs_cert_private_dir "$path" || exit 1
            fi
            rs_cert_cf_prepare_domain || exit 1
            rs_cert_run_acme --issue --server letsencrypt --dns dns_realitysite -d "$DOMAIN" --keylength ec-256 || result=$?
            [[ "$result" == 0 || "$result" == 2 ]] || die "ACME 签发失败（退出码 $result）；现有域名证书保持不变。"
            [[ -d "$path" && ! -L "$path" ]] || die 'ACME 未生成新域名的普通证书目录。'
            rs_cert_private_dir "$path" || exit 1
            chain="$path/fullchain.cer"
            key="$path/${DOMAIN}.key"
            ;;
        *) die '证书模式必须为 cloudflare 或 manual。' ;;
    esac

    rs_secure_file "$chain" || exit 1
    rs_secure_file "$key" || exit 1
    rs_cert_validate "$chain" "$key" || die '新域名证书校验失败，现有证书未改变。'
    install -T -o root -g root -m 0600 -- "$chain" "$output_chain" || die '无法暂存新域名证书链。'
    install -T -o root -g root -m 0600 -- "$key" "$output_key" || die '无法暂存新域名私钥。'
    rs_secure_file "$output_chain" || exit 1
    rs_secure_file "$output_key" || exit 1
    rs_cert_validate "$output_chain" "$output_key" || die '新域名候选证书副本校验失败，现有证书未改变。'
)

rs_cert_setup() {
    local chain key result=0
    rs_require_root
    rs_cert_paths
    case "$CERT_MODE" in
        manual)
            IFS= read -r -p '完整证书链 fullchain.pem 的绝对路径：' chain </dev/tty || die '未读取证书路径。'
            IFS= read -r -p '私钥的绝对路径：' key </dev/tty || die '未读取私钥路径。'
            [[ "$chain" == /* && "$key" == /* ]] || die '证书和私钥必须使用绝对路径。'
            rs_cert_import "$chain" "$key"
            ;;
        cloudflare)
            rs_cert_install_acme
            rs_cert_private_dir "$ACME_HOME/dnsapi"
            rs_cert_cf_credentials || die 'Cloudflare 凭据输入失败。'
            rs_cert_render_dns_hook "$TMP_DIR/dns_realitysite.sh"
            sh -n "$TMP_DIR/dns_realitysite.sh" || die 'Cloudflare DNS hook 语法检查失败。'
            install -o root -g root -m 0700 -- "$TMP_DIR/dns_realitysite.sh" "$ACME_HOME/dnsapi/dns_realitysite.sh" || die '无法安装 Cloudflare DNS hook。'
            rs_cert_run_acme --register-account --server letsencrypt --accountemail "$ACME_EMAIL" || die 'ACME 账户注册失败。'
            rs_cert_run_acme --issue --server letsencrypt --dns dns_realitysite -d "$DOMAIN" --keylength ec-256 || result=$?
            [[ "$result" == 0 || "$result" == 2 ]] || die "ACME 签发失败（退出码 $result）。"
            rs_cert_publish "$ACME_HOME/${DOMAIN}_ecc/fullchain.cer" "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.key"
            ;;
        *) die '证书模式必须为 cloudflare 或 manual。' ;;
    esac
}

rs_cert_renew() {
    local result=0
    rs_require_root
    rs_cert_paths
    [[ "$CERT_MODE" == cloudflare ]] || { info '手动证书不自动续期；请使用 import-cert 导入新证书。'; return 0; }
    rs_cert_private_dir "$ACME_HOME"
    rs_secure_file "$ACME_HOME/acme.sh"
    rs_secure_file "$ACME_HOME/cloudflare.credentials"
    rs_secure_file "$ACME_HOME/dnsapi/dns_realitysite.sh"
    rs_cert_cf_sync_hook || die '无法准备证书续期的区域配置。'
    rs_cert_run_acme --renew --server letsencrypt -d "$DOMAIN" --ecc || result=$?
    [[ "$result" == 0 || "$result" == 2 ]] || die "ACME 续期失败（退出码 $result）；现有证书保持不变。"
    # Also publish on skip: this retries an earlier successful issuance whose
    # Nginx reload failed, without issuing another certificate.
    rs_cert_publish "$ACME_HOME/${DOMAIN}_ecc/fullchain.cer" "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.key"
}

rs_cert_render_dns_hook() {
    local output="$1"
    cat > "$output" <<'HOOK' || return 1
#!/bin/sh

# Sourced by acme.sh. Keep top-level shell options and traps untouched.
# reality-site Cloudflare zone map v1
RS_CF_CREDENTIAL_FILE='__REALITY_ACME_HOME__/cloudflare.credentials'
RS_CF_ZONE_FILE='__REALITY_ACME_HOME__/cloudflare-zones.json'
RS_CF_API_BASE='https://api.cloudflare.com/client/v4'

_rs_cf_load_credentials() {
  [ -f "$RS_CF_CREDENTIAL_FILE" ] && [ ! -L "$RS_CF_CREDENTIAL_FILE" ] || return 1
  [ "$(/usr/bin/stat -c '%u' -- "$RS_CF_CREDENTIAL_FILE" 2>/dev/null)" = 0 ] || return 1
  [ "$(/usr/bin/stat -c '%a' -- "$RS_CF_CREDENTIAL_FILE" 2>/dev/null)" = 600 ] || return 1

  exec 3< "$RS_CF_CREDENTIAL_FILE" || return 1
  IFS= read -r RS_CF_TOKEN <&3 || { exec 3<&-; return 1; }
  IFS= read -r RS_CF_ZONE_ID <&3 || { exec 3<&-; return 1; }
  RS_CF_EXTRA=''
  if IFS= read -r RS_CF_EXTRA <&3 || [ -n "$RS_CF_EXTRA" ]; then
    exec 3<&-
    return 1
  fi
  exec 3<&-

  [ "${#RS_CF_TOKEN}" -ge 20 ] && [ "${#RS_CF_TOKEN}" -le 200 ] || return 1
  case "$RS_CF_TOKEN" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#RS_CF_ZONE_ID}" -eq 32 ] || return 1
  case "$RS_CF_ZONE_ID" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  return 0
}

_rs_cf_select_zone() {
  case "$1" in _acme-challenge.*) RS_CF_DOMAIN=${1#_acme-challenge.} ;; *) return 1 ;; esac
  RS_CF_DOMAIN=$(printf '%s' "$RS_CF_DOMAIN" | tr '[:upper:]' '[:lower:]') || return 1
  # Legacy hooks used the credential file's second line. A missing map remains
  # compatible; a present but invalid/incomplete map must never use that fallback.
  if [ ! -e "$RS_CF_ZONE_FILE" ] && [ ! -L "$RS_CF_ZONE_FILE" ]; then return 0; fi
  [ -f "$RS_CF_ZONE_FILE" ] && [ ! -L "$RS_CF_ZONE_FILE" ] || return 1
  [ "$(/usr/bin/stat -c '%u:%a:%h' -- "$RS_CF_ZONE_FILE" 2>/dev/null)" = '0:600:1' ] || return 1
  RS_CF_ZONE_ID=$(/usr/bin/jq -ser --arg domain "$RS_CF_DOMAIN" '
    if length == 1 and (.[0] | type == "object" and .schema == 1
      and (.zones | type == "object")
      and all(.zones | keys[]; length <= 237
        and test("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
        and (test("^[0-9.]+$") | not))
      and all(.zones[]; type == "string" and test("^[A-Fa-f0-9]{32}$")))
    then .[0].zones[$domain] // empty else empty end' "$RS_CF_ZONE_FILE" 2>/dev/null) || return 1
  [ "${#RS_CF_ZONE_ID}" -eq 32 ] || return 1
  case "$RS_CF_ZONE_ID" in *[!A-Fa-f0-9]*) return 1 ;; esac
  return 0
}

_rs_cf_validate_challenge() {
  [ "$#" -eq 2 ] || return 1
  [ "${#1}" -ge 4 ] && [ "${#1}" -le 253 ] || return 1
  case "$1" in ''|*[!A-Za-z0-9_.-]*|.*|*.|*..*) return 1 ;; esac
  [ "${#2}" -ge 20 ] && [ "${#2}" -le 512 ] || return 1
  case "$2" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  return 0
}

_rs_cf_api() {
  RS_CF_METHOD=$1
  RS_CF_URL=$2
  RS_CF_BODY_FILE=${3-}
  if [ -n "$RS_CF_BODY_FILE" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$RS_CF_TOKEN" |
      /usr/bin/curl -q --config - --noproxy '*' --proto '=https' --tlsv1.2 \
        --cacert /etc/ssl/certs/ca-certificates.crt --silent --show-error \
        --fail-with-body --connect-timeout 15 --max-time 45 \
        --request "$RS_CF_METHOD" --header 'Content-Type: application/json' \
        --data-binary "@${RS_CF_BODY_FILE}" "$RS_CF_URL"
  else
    printf 'header = "Authorization: Bearer %s"\n' "$RS_CF_TOKEN" |
      /usr/bin/curl -q --config - --noproxy '*' --proto '=https' --tlsv1.2 \
        --cacert /etc/ssl/certs/ca-certificates.crt --silent --show-error \
        --fail-with-body --connect-timeout 15 --max-time 45 \
        --request "$RS_CF_METHOD" "$RS_CF_URL"
  fi
}

_rs_cf_find_ids() {
  RS_CF_FIND_NAME=$1
  RS_CF_FIND_VALUE=$2
  RS_CF_PAGE=1
  while [ "$RS_CF_PAGE" -le 50 ]; do
    RS_CF_FIND_URL="${RS_CF_API_BASE}/zones/${RS_CF_ZONE_ID}/dns_records?type=TXT&name=${RS_CF_FIND_NAME}&page=${RS_CF_PAGE}&per_page=100"
    RS_CF_RESPONSE=$(_rs_cf_api GET "$RS_CF_FIND_URL") || return 1
    printf '%s' "$RS_CF_RESPONSE" |
      /usr/bin/jq -e '.success == true and (.result | type == "array")' >/dev/null || return 1
    printf '%s' "$RS_CF_RESPONSE" |
      /usr/bin/jq -r --arg name "$RS_CF_FIND_NAME" --arg value "$RS_CF_FIND_VALUE" \
        '.result[]? | select(.type == "TXT" and ((.name | ascii_downcase) == ($name | ascii_downcase)) and .content == $value) | .id'
    RS_CF_TOTAL_PAGES=$(printf '%s' "$RS_CF_RESPONSE" |
      /usr/bin/jq -r '.result_info.total_pages // 1') || return 1
    case "$RS_CF_TOTAL_PAGES" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$RS_CF_TOTAL_PAGES" -eq 0 ]; then
      [ "$RS_CF_PAGE" -eq 1 ] || return 1
      [ "$(printf '%s' "$RS_CF_RESPONSE" | /usr/bin/jq -r '.result | length')" -eq 0 ] || return 1
      return 0
    fi
    [ "$RS_CF_TOTAL_PAGES" -ge 1 ] && [ "$RS_CF_TOTAL_PAGES" -le 50 ] || return 1
    [ "$RS_CF_PAGE" -ge "$RS_CF_TOTAL_PAGES" ] && return 0
    RS_CF_PAGE=$((RS_CF_PAGE + 1))
  done
  return 1
}

_rs_cf_cleanup() {
  RS_CF_TOKEN=''
  RS_CF_ZONE_ID=''
  if [ -n "${RS_CF_PAYLOAD_FILE:-}" ]; then
    /bin/rm -f -- "$RS_CF_PAYLOAD_FILE"
  fi
}

dns_realitysite_add() (
  set +x
  umask 077
  ulimit -c 0 2>/dev/null || exit 1
  RS_CF_PAYLOAD_FILE=''
  trap '_rs_cf_cleanup' 0
  trap 'exit 1' 1 2 15
  _rs_cf_validate_challenge "$@" || { _err 'Invalid Cloudflare DNS challenge input.'; exit 1; }
  _rs_cf_load_credentials || { _err 'Cannot load protected Cloudflare credentials.'; exit 1; }
  _rs_cf_select_zone "$1" || { _err 'Cannot select Cloudflare zone for this domain.'; exit 1; }
  RS_CF_FULLDOMAIN=$1
  RS_CF_TXT_VALUE=$2

  RS_CF_RECORD_IDS=$(_rs_cf_find_ids "$RS_CF_FULLDOMAIN" "$RS_CF_TXT_VALUE") || {
    _err 'Cloudflare DNS lookup failed.'
    exit 1
  }
  [ -n "$RS_CF_RECORD_IDS" ] && exit 0

  RS_CF_PAYLOAD_FILE=$(/usr/bin/mktemp '__REALITY_ACME_HOME__/.reality-site-cf-payload.XXXXXX') || exit 1
  /usr/bin/jq -nc --arg name "$RS_CF_FULLDOMAIN" --arg content "$RS_CF_TXT_VALUE" \
    '{type:"TXT", name:$name, content:$content, ttl:120}' > "$RS_CF_PAYLOAD_FILE" || exit 1
  RS_CF_RESPONSE=$(_rs_cf_api POST \
    "${RS_CF_API_BASE}/zones/${RS_CF_ZONE_ID}/dns_records" "$RS_CF_PAYLOAD_FILE") || RS_CF_RESPONSE=''
  if printf '%s' "$RS_CF_RESPONSE" | /usr/bin/jq -e '.success == true' >/dev/null 2>&1; then
    exit 0
  fi

  # Treat a concurrently-created exact record as idempotent success.
  RS_CF_RECORD_IDS=$(_rs_cf_find_ids "$RS_CF_FULLDOMAIN" "$RS_CF_TXT_VALUE") || RS_CF_RECORD_IDS=''
  [ -n "$RS_CF_RECORD_IDS" ] && exit 0
  _err 'Cloudflare DNS record creation failed.'
  exit 1
)

dns_realitysite_rm() (
  set +x
  umask 077
  ulimit -c 0 2>/dev/null || exit 1
  RS_CF_PAYLOAD_FILE=''
  trap '_rs_cf_cleanup' 0
  trap 'exit 1' 1 2 15
  _rs_cf_validate_challenge "$@" || { _err 'Invalid Cloudflare DNS challenge input.'; exit 1; }
  _rs_cf_load_credentials || { _err 'Cannot load protected Cloudflare credentials.'; exit 1; }
  _rs_cf_select_zone "$1" || { _err 'Cannot select Cloudflare zone for this domain.'; exit 1; }
  RS_CF_FULLDOMAIN=$1
  RS_CF_TXT_VALUE=$2
  RS_CF_RECORD_IDS=$(_rs_cf_find_ids "$RS_CF_FULLDOMAIN" "$RS_CF_TXT_VALUE") || {
    _err 'Cloudflare DNS lookup failed during cleanup.'
    exit 1
  }
  [ -z "$RS_CF_RECORD_IDS" ] && exit 0

  RS_CF_OLD_IFS=$IFS
  IFS='
'
  for RS_CF_RECORD_ID in $RS_CF_RECORD_IDS; do
    IFS=$RS_CF_OLD_IFS
    [ "${#RS_CF_RECORD_ID}" -eq 32 ] || { _err 'Invalid Cloudflare DNS record id.'; exit 1; }
    case "$RS_CF_RECORD_ID" in *[!A-Fa-f0-9]*) _err 'Invalid Cloudflare DNS record id.'; exit 1 ;; esac
    RS_CF_RESPONSE=$(_rs_cf_api DELETE \
      "${RS_CF_API_BASE}/zones/${RS_CF_ZONE_ID}/dns_records/${RS_CF_RECORD_ID}") || {
        _err 'Cloudflare DNS record deletion failed.'
        exit 1
      }
    printf '%s' "$RS_CF_RESPONSE" | /usr/bin/jq -e '.success == true' >/dev/null || {
      _err 'Cloudflare DNS record deletion was rejected.'
      exit 1
    }
    IFS='
'
  done
  IFS=$RS_CF_OLD_IFS
  exit 0
)
HOOK
    [[ "$ACME_HOME" =~ ^/[A-Za-z0-9_./-]+$ ]] || die 'Unsafe ACME home path.'
    sed -i "s|__REALITY_ACME_HOME__|$ACME_HOME|g" "$output"
}
