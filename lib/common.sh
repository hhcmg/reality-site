#!/usr/bin/env bash

info() { printf '[信息] %s\n' "$*"; }
warn() { printf '[提示] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }
rs_require_root() { [[ $(id -u) == 0 ]] || die '请使用 sudo bash 或 root 执行。'; }

rs_prompt() {
    local variable=$1 prompt=$2 default=${3-} answer
    [[ -t 0 && -r /dev/tty ]] || die '该操作需要交互终端，请通过 SSH 运行。'
    printf '%s%s：' "$prompt" "${default:+ [$default]}" > /dev/tty
    IFS= read -r answer < /dev/tty || die '输入已取消。'
    printf -v "$variable" '%s' "${answer:-$default}"
}

rs_valid_domain() {
    local domain=$1 label
    [[ ${#domain} -le 237 && "$domain" == *.* && "$domain" != *..* && "$domain" != *. ]] || return 1
    [[ "$domain" =~ ^[a-z0-9.-]+$ && ! "$domain" =~ ^[0-9.]+$ ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}
rs_valid_port() { [[ "$1" =~ ^[1-9][0-9]{3,4}$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 )); }
rs_valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ && ${#1} -le 254 ]]; }

# Quoted Nginx strings still expand $variables and interpret backslashes.
# Accept an ASCII HTTPS URL; non-ASCII path bytes must be percent-encoded.
rs_valid_redirect_url() {
    local url=${1:-} authority host port='' tail percent_rest
    [[ ${#url} -le 2048 && "$url" == https://* ]] || return 1
    [[ ! "$url" =~ [^!-~] ]] || return 1
    # Each quoted case alternative matches one literal forbidden character.
    # shellcheck disable=SC1003
    case "$url" in *'$'*|*'\'*|*'"'*|*"'"*|*'{'*|*'}'*|*'`'*|*'<'*|*'>'*) return 1 ;; esac
    [[ ! "${url,,}" =~ %0[ad] ]] || return 1
    percent_rest=${url//%[[:xdigit:]][[:xdigit:]]/}
    [[ "$percent_rest" != *%* ]] || return 1
    tail=${url#https://}
    authority=${tail%%[/?#]*}
    [[ "$authority" != *@* && "$authority" != *'['* ]] || return 1
    host=${authority%%:*}
    host=${host,,}
    rs_valid_domain "$host" || return 1
    [[ "$host" != "${DOMAIN,,}" ]] || return 1
    if [[ "$authority" == *:* ]]; then
        port=${authority#*:}
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
        (( 10#$port <= 65535 )) || return 1
    fi
}

rs_valid_web_settings() {
    case "${WEB_MODE:-static}" in
        static) [[ -z ${REDIRECT_URL:-} ]] ;;
        redirect) rs_valid_redirect_url "${REDIRECT_URL:-}" ;;
        *) return 1 ;;
    esac
}

rs_secure_file() {
    local file=$1 owner mode links
    [[ -f "$file" && ! -L "$file" ]] || die "不是普通文件（不接受符号链接）：$file"
    IFS=' ' read -r owner mode links < <(stat -c '%u %a %h' -- "$file")
    if [[ "$owner" != 0 || "$links" != 1 ]] || (( (8#$mode & 022) != 0 )); then
        die "文件必须由 root 所有且不能被组/其他用户写入或有硬链接：$file"
    fi
}

rs_secure_dir() {
    local directory=$1 owner mode
    [[ -d "$directory" && ! -L "$directory" ]] || die "不是普通目录：$directory"
    IFS=' ' read -r owner mode < <(stat -c '%u %a' -- "$directory")
    if [[ "$owner" != 0 ]] || (( (8#$mode & 022) != 0 )); then die "目录必须由 root 控制：$directory"; fi
}

rs_assert_owned_output() {
    local file=$1
    if [[ -e "$file" || -L "$file" ]]; then
        rs_secure_file "$file"
        [[ $(head -n 1 -- "$file") == '# Managed by reality-site' ]] || die "拒绝覆盖不属于本工具的文件：$file"
    fi
}

rs_lock() {
    local file=${RS_LOCK_FILE:-/run/reality-site.lock}
    rs_secure_dir /run
    if [[ -e "$file" || -L "$file" ]]; then rs_secure_file "$file"; fi
    exec {RS_LOCK_FD}>> "$file"
    chmod 600 "$file"
    flock -n "$RS_LOCK_FD" || die '另一个 reality-site 操作正在执行，请稍后重试。'
    # Keep the inode: unlinking a flock lock would permit concurrent writers.
}

rs_managed_dir() {
    local directory=$1
    if [[ -e "$directory" || -L "$directory" ]]; then
        rs_secure_dir "$directory"
        rs_secure_file "$directory/.managed-by"
        [[ $(cat "$directory/.managed-by") == reality-site-v1 ]] || die "目录不属于本工具：$directory"
    else
        rs_secure_dir "$(dirname -- "$directory")"
        mkdir -m 755 -- "$directory"
        printf '%s\n' reality-site-v1 > "$directory/.managed-by"
    fi
}

rs_prepare_directories() {
    rs_managed_dir "$APP_DIR"
    rs_managed_dir "$DATA_DIR"
}

rs_write_state() {
    local status=$1 next
    [[ "$status" == ready || "$status" == installing ]] || die '无效安装状态。'
    rs_valid_web_settings || die '网站模式或跳转地址无效。'
    if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then rs_secure_file "$STATE_FILE"; fi
    next=$(mktemp "$DATA_DIR/.state.XXXXXX") || return 1
    if ! jq -n --arg domain "$DOMAIN" --argjson port "$PORT" --arg mode "$CERT_MODE" \
        --arg email "$ACME_EMAIL" --arg status "$status" --arg version "$VERSION" \
        --arg web_mode "${WEB_MODE:-static}" --arg redirect_url "${REDIRECT_URL:-}" \
        '{schema:2,domain:$domain,port:$port,cert_mode:$mode,acme_email:$email,status:$status,version:$version,web_mode:$web_mode,redirect_url:$redirect_url}' > "$next" \
        || ! chmod 600 "$next" || ! mv -f -- "$next" "$STATE_FILE"; then
        rm -f -- "$next"
        return 1
    fi
}

rs_load_state() {
    command -v jq >/dev/null || die '缺少 jq；请先执行 install。'
    rs_secure_dir "$DATA_DIR"
    rs_secure_file "$DATA_DIR/.managed-by"
    [[ $(cat "$DATA_DIR/.managed-by") == reality-site-v1 ]] || die '数据目录归属不匹配。'
    [[ -e "$STATE_FILE" ]] || die '尚未安装，请先执行 install。'
    rs_secure_file "$STATE_FILE"
    jq -e '(.schema == 1 or .schema == 2) and (.domain|type=="string") and (.port|type=="number") and (.acme_email|type=="string") and (.cert_mode=="cloudflare" or .cert_mode=="manual") and (.status=="ready" or .status=="installing") and (if .schema == 2 then ((.web_mode=="static" or .web_mode=="redirect") and (.redirect_url|type=="string")) else true end)' "$STATE_FILE" >/dev/null || die '状态文件无效，拒绝加载。'
    DOMAIN=$(jq -r .domain "$STATE_FILE")
    PORT=$(jq -r .port "$STATE_FILE")
    CERT_MODE=$(jq -r .cert_mode "$STATE_FILE")
    ACME_EMAIL=$(jq -r .acme_email "$STATE_FILE")
    WEB_MODE=$(jq -r 'if .schema == 1 then "static" else .web_mode end' "$STATE_FILE")
    REDIRECT_URL=$(jq -r 'if .schema == 1 then "" else .redirect_url end' "$STATE_FILE")
    if ! rs_valid_domain "$DOMAIN" || ! rs_valid_port "$PORT"; then die '状态文件中的域名/端口不合法。'; fi
    [[ "$CERT_MODE" == manual ]] || rs_valid_email "$ACME_EMAIL" || die '状态文件中的邮箱不合法。'
    rs_valid_web_settings || die '状态文件中的网站模式或跳转地址不合法。'
}
