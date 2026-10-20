# reality-site：为 3x-ui 准备 REALITY 本机目标

当前版本：**1.3.0**。用于部署 REALITY“偷自己”所需的本机 HTTPS 网站，与 3x-ui 配套使用。

[下载发布包](https://github.com/hhcmg/reality-site/releases/latest) · [提交问题](https://github.com/hhcmg/reality-site/issues)

这个工具在 VPS 上准备一个带有效证书的本机 HTTPS 后端，供 3x-ui 管理的 Xray 使用。网页响应可选择**本地静态页面**或 **302 跳转到外部 HTTPS 网站**：

```text
公网 TCP 443 → 3x-ui 管理的 Xray
                 ├─ REALITY 认证通过 → 代理出口
                 └─ 普通浏览器连接   → 127.0.0.1:8003 → 静态页面 / 302 跳转
```

Xray 的安装、更新、节点配置和路由仍在 **3x-ui 面板**完成。本工具负责网站、证书和可选的当前内核 BBR 设置。

## 安装前准备

- Debian 12 或更新版本、Ubuntu 22.04 或更新版本，使用 systemd，以 root 或 sudo 运行。
- 一个由 Cloudflare 管理 DNS 的域名。将所选主机名的 A 记录指向本 VPS，设为 **仅 DNS（灰云）**。如果设置 AAAA，IPv6 也必须指向可正常访问的本 VPS。
- Cloudflare **API Token**，包含 `Zone / Zone / Read` 和 `Zone / DNS / Edit`（新界面可能显示 DNS Write）。资源范围可以是指定区域或账户所有区域，只要包含所用域名。**无需查找或填写 Zone ID，程序自动识别。** 不需要 Global API Key。
- 3x-ui 的面板端口与计划给节点使用的公网 TCP `443` 不冲突。

例如可用 `site.example.com`。已有面板域名也可以复用：面板在自己的端口，REALITY 在 `443`，二者的证书和配置仍各自管理。安装时会询问域名，不会写死示例值。

证书默认使用 Cloudflare DNS-01 验证，**申请和续期不需要监听公网 80 或 443**。也可以选择导入已有的公信任 HTTPS 证书；Cloudflare Origin CA 证书不能直接作为普通浏览器信任的证书使用。

## 安装

在 VPS 上下载发布包和校验文件，校验后解压运行；也可以从 [Releases](https://github.com/hhcmg/reality-site/releases) 下载这两个文件后上传到 VPS：

```bash
curl -fLO https://github.com/hhcmg/reality-site/releases/download/v1.3.0/reality-site-1.3.0.tar.gz &&
curl -fLO https://github.com/hhcmg/reality-site/releases/download/v1.3.0/reality-site-1.3.0.tar.gz.sha256 &&
sha256sum -c reality-site-1.3.0.tar.gz.sha256 &&
tar -xzf reality-site-1.3.0.tar.gz &&
cd reality-site &&
sudo bash ./reality-site.sh install
```

确认校验显示 `OK` 后再解压、执行安装。这会启动向导，不需要在脚本内修改域名或填写 Token。

如果使用源码部署，将整个仓库目录上传到 VPS，保留下面的相对位置：

```text
reality-site/
├─ reality-site.sh
├─ lib/
│  ├─ common.sh
│  ├─ system.sh
│  ├─ cert.sh
│  ├─ web.sh
│  └─ domain.sh
├─ assets/
│  └─ index.html
└─ README.md
```

进入上传目录运行：

```bash
sudo bash ./reality-site.sh install
```

按提示填写域名、证书方式和网页响应模式。本地静态模式可以导入自己的 HTML；302 模式填写完整的外部 HTTPS 地址。两种模式都需要自己域名的有效证书。Cloudflare API Token 使用隐藏输入，避免写入命令行历史。程序将需要用于续期的凭据保存在受限目录内，私有文件权限为 `0600`。

安装使用系统 Nginx 程序，但网站由独立的 `reality-site.service` 管理，使用自己的配置。它不会修改系统 Nginx 的已有站点配置。运行前会检查本机目标端口是否可用。

脚本按需通过 APT 安装 Nginx、curl、OpenSSL、jq、dnsutils、CA 证书及必要的系统工具。Cloudflare 模式另下载并校验固定版本的 acme.sh；不运行它的系统安装器、不创建其默认 cron 任务。脚本运行需要 `flock`；极简系统若缺少它，请先安装 `util-linux`。

首次安装 Nginx 包时，脚本临时阻止包的默认服务启动，并禁用这个新装的默认服务；只启动独立的网站服务。如果 Nginx 原本已经安装，其默认服务保持原状。如果已有管理员维护的 `policy-rc.d`，脚本会提示先按现有系统策略安装 Nginx，不覆盖该文件。

安装完成后使用正式入口：

```bash
sudo bash /opt/reality-site/reality-site.sh
```

不带参数会打开 SSH 交互菜单。重复执行 `install` 会更新正式入口中的程序文件并显示已安装状态，保留现有站点配置、网页和证书。

### 更新程序

将新安装包解压到上传目录，在该目录执行安装命令：

```bash
tar -xzf reality-site-1.3.0.tar.gz
cd reality-site
sudo bash ./reality-site.sh install
sudo bash /opt/reality-site/reality-site.sh version
```

应显示所安装发布包的版本，当前为 `1.3.0`。重复安装更新程序文件和本工具的 Cloudflare DNS 验证 hook，保留现有域名、内部端口、证书、网页及网页响应模式。更新不会自动更换域名、重新签发证书或改变当前页面响应。不要只上传入口脚本，必须同时更新 `lib/` 中的全部模块。可通过菜单第 `10` 项或下面的 `set-domain` 命令更换域名。

更新会保留已有凭据和当前域名的续期配置，不要求重新输入 Token，也不访问 Cloudflare 查询区域。若已有 Token 只有 DNS Edit，仍可续期已配置的当前域名；新安装或更换域名时的自动区域查询需要 Zone Read。授权“所有区域”的 Token 可以使用，只需确认同时拥有上述两项权限。

## 在 3x-ui 中配置节点

在面板添加或编辑入站，设置如下：

| 项目 | 值 |
|---|---|
| 协议 | VLESS |
| 公网监听端口 | `443` |
| 传输 | TCP / RAW |
| 安全 | REALITY |
| 目标 / target | `127.0.0.1:8003`，以脚本实际输出为准 |
| SNI / serverNames | 安装时填写的网站域名，例如 `site.example.com` |
| Xver | `0` |
| 客户端流控 | `xtls-rprx-vision` |
| 密钥、Short ID、客户端 ID | 由面板生成或保留已有设置 |

脚本的 `panel` 命令会显示本站应填写的值。面板版本不同，字段名称可能略有差别。

**目标必须是本机 HTTPS 后端，不能填指向本 VPS 的公网域名加 `:443`，否则会把连接送回 Xray，形成循环。** 也不要填面板的管理端口。

如果 3x-ui 在 Docker 容器中运行，容器里的 `127.0.0.1` 未必是宿主机。上述地址适用于原生安装或共享宿主机网络的部署；其他网络模式需要另行安排 Xray 到网站后端的可达路径，不能直接照填。

保存并使节点配置生效后，浏览器访问 `https://site.example.com` 才能通过公网 `443` 到达本机网站。脚本不会设置防火墙或云平台安全组，请自行保证节点的 TCP `443` 可达。

本项目的网站入口依赖 Xray：停止 Xray，或者将 REALITY 的 `target` 改成外站后，原域名的网站访问会受到影响。这不是独立的网站公网入口。

## 日常操作

下列命令均使用正式入口。参数中的文件路径位于 VPS 上。

| 操作 | 命令参数 |
|---|---|
| 查看状态 | `status` |
| 检查本机网站和证书 | `check` |
| 查看面板应填参数 | `panel` |
| 手动检查 Cloudflare 证书续期 | `renew` |
| 导入/替换已有证书 | `import-cert /path/fullchain.pem /path/privkey.pem` |
| 替换静态首页 | `set-page /path/index.html` |
| 使用本地静态页面 | `set-mode static` |
| 使用 302 跳转 | `set-mode redirect 'https://www.example.com/'` |
| 更换域名（Cloudflare 自动证书） | `set-domain new.example.com` |
| 更换域名（手动证书） | `set-domain new.example.com /path/fullchain.pem /path/privkey.pem` |
| 开启当前内核 BBR + fq | `bbr` |
| 查看帮助、版本 | `help`、`version` |

例如：

```bash
sudo bash /opt/reality-site/reality-site.sh check
sudo bash /opt/reality-site/reality-site.sh panel
sudo bash /opt/reality-site/reality-site.sh set-page /root/index.html
sudo bash /opt/reality-site/reality-site.sh set-mode redirect 'https://www.example.com/path?from=site&lang=zh'
sudo bash /opt/reality-site/reality-site.sh set-mode static
```

默认首页是单个静态 HTML 文件。自定义页面应将 CSS、JavaScript、图片等资源内嵌在 HTML 中，或者自行使用可访问的外部资源；`set-page` 不会连带复制旁边的资源文件夹。这里不需要 WordPress、PHP 或数据库。

### 两种网页响应模式

| 模式 | 浏览器访问自己域名后发生什么 | 地址栏 |
|---|---|---|
| `static` | 本机 Nginx 返回 `/var/lib/reality-site/www/` 内的静态网页 | 保留自己的域名 |
| `redirect` | 本机 Nginx 返回 HTTP 302，浏览器再直接访问指定外站 | 变成外部地址 |

302 模式将每个请求跳转到所填写的**同一个完整地址**，不会自动拼接原请求的路径或查询参数。命令行中的 URL 应用单引号包围，尤其是包含 `&` 等字符时。仅接受带域名的绝对 `https://` 地址；不接受与本站相同的主机名，以免直接循环跳转。不支持用户名/密码、IP 地址或未经编码的空格等字符；中文路径请先转换成百分号编码。

切换到 302 后，本地 HTML 文件仍保留；`set-page` 仍可更新它，但不会自动改变模式。运行 `set-mode static` 后即可重新显示保存的页面。切换前会校验配置，切换失败时尝试恢复原配置和状态；切换要求网站已经安装完成且独立的网站服务正在运行。

**无论选择哪种模式，3x-ui 中的 REALITY `target` 仍为 `127.0.0.1:8003`，SNI 仍为自己的域名。** 外部跳转地址只写入 Nginx 的 302 响应，不是 REALITY 的目标。自己的 HTTPS 证书仍由本工具申请和续期；切换网页模式无需更换证书或重启 Xray。

**本地静态页和 302 模式的 REALITY 目标握手都发生在本机 Xray 与 Nginx 之间。** 前提是 `target` 始终指向上述本机 HTTPS 后端（内部端口如有修改，以实际配置为准）。这里说的是 Xray 向目标借用 TLS 握手特征的这一段；客户端与 VPS 上 Xray 的 REALITY 握手仍经过公网。

302 是 TLS 握手完成后才返回的 HTTP 响应。本脚本使用 Nginx 的 `return 302`，只把外部地址写入 `Location` 响应头；Nginx 不会为此连接、下载或等待该外站。普通浏览器收到响应后，才根据跳转地址另行发起请求。因此，**只更换 302 跳转地址，不会因外站距离远、响应慢或不可达而增加 REALITY 的目标握手延迟，也不会直接降低已认证代理连接的传输速度**。外站的选择影响的是浏览器跳转后的页面加载与可用性；如果浏览器通过该节点访问外站，那次访问仍受 VPS 到外站线路的影响。

这与修改面板中的 REALITY `target` 不同：把 `target` 改成外站后，每条新建 REALITY 连接就需要等待该外站的建连及握手响应。上述判断依据本脚本的 Nginx 配置、[Nginx `return` 官方说明](https://nginx.org/en/docs/http/ngx_http_rewrite_module.html#return)及 [REALITY 官方握手实现](https://github.com/XTLS/REALITY/blob/8cdf7bf9c7f0/tls.go#L153-L454)。

`check` 会校验本机 TLS 1.3、证书和 HTTP/2，并检查静态模式首页返回 `200`，或 302 模式返回 `302` 且 `Location` 与保存地址一致。检查不会跟随跳转，也不会访问外部目标，不能判断外站是否可用。

Cloudflare 模式配置 systemd 定时任务检查证书续期。`renew` 是检查并按需续期，不保证每次运行都会重新签发证书。导入已有证书后，需要自行提供更新后的 fullchain 和私钥，再运行 `import-cert`；导入模式不代替原证书提供方的续期工具。

### 更换网站域名

先完成本工具的安装，并给新域名添加指向同一 VPS 的 A 记录，设为 **仅 DNS（灰云）**；如有 AAAA 记录，也需正确指向该 VPS。保留旧域名的 DNS 记录，直到新域名的公网网站和客户端都验证通过。

Cloudflare 证书模式执行：

```bash
sudo bash /opt/reality-site/reality-site.sh set-domain new.example.com
sudo bash /opt/reality-site/reality-site.sh check
sudo bash /opt/reality-site/reality-site.sh panel
```

命令沿用已保存的 Cloudflare Token 和 ACME 账户邮箱，**自动查询新域名所属区域并申请证书，无需输入 Zone ID**。支持从 `node.example.org` 换到 `node.example.net` 等跨区域场景，前提是 Token 对新区域同时具有 Zone Read 和 DNS Edit 权限。查询、签发或网站切换失败时，旧站点和旧域名的续期仍保留。命令不会修改 Token 的权限范围。

这里的“不需要 Zone ID”指不需要用户提供它；Cloudflare API 内部仍使用区域 ID，程序负责自动查询与保存。程序在现有 ACME 目录中保存 `cloudflare-zones.json`，按域名分别记录区域 ID；不会在为新域名申请证书时覆盖旧域名的区域。该文件由程序维护，不需要手工编辑。切换失败可能保留新域名的映射和 ACME 候选文件，它们不会改变当前网站或定时续期所使用的域名。

手动证书模式必须同时提供覆盖**新域名**的公信任 fullchain 和私钥，文件要求与 `import-cert` 相同：

```bash
sudo bash /opt/reality-site/reality-site.sh set-domain new.example.com /root/new-fullchain.pem /root/new-key.pem
```

更换后仍保持手动证书模式。Cloudflare 模式不接受这两个文件参数；若需要改变证书管理方式，请单独使用 `import-cert`。

更换要求安装已完成、独立的网站服务正在运行。程序先准备并校验新证书与 Nginx 配置，再切换并检查本机 HTTPS；失败时恢复原状态文件、Nginx 配置和证书链接。如果进程中途退出，下次运行正式入口会根据持久记录恢复未完成的切换。原配置与证书备份保留在受限的数据目录中。

内部端口、自定义 HTML、`static` / `redirect` 模式、完整的 302 目标和证书管理方式均保持不变。如果现有 302 目标的主机名恰好是新域名，会在申请证书前拒绝更换，避免循环跳转；应先用 `set-mode` 调整目标。输入当前域名会直接返回，不重新签发证书或 reload 网站。

本机更换成功后，还需在 **3x-ui 面板**中手动把 REALITY 的 `SNI / serverNames` 改为新域名；`target` 保持脚本输出的 `127.0.0.1:<内部端口>`。同步更新客户端的服务器地址和 SNI，并更新或重新导入订阅中的节点。脚本不会修改 3x-ui、Xray 或客户端配置。

确认 `check` 通过后，再验证 `https://new.example.com/` 的公网访问和客户端连接；都通过后，才删除不再需要的旧域名 DNS 记录。脚本不会自动删除旧 DNS 记录。Cloudflare 自动续期此后仅跟随当前新域名，停止为旧域名续期；旧 ACME 文件与证书代次保留备份，不会撤销（revoke）旧证书。若其他服务仍使用旧域名，请保留它们所需的 DNS 和续期安排。

`import-cert` 在证书初步校验通过后，先保存手动证书模式并停用自动续期，再发布新证书。如果此后发布或加载失败，旧证书会保留，但仍保持手动模式，防止自动续期覆盖人工导入；按报错修复后重新执行导入。

私钥必须与证书匹配，证书必须覆盖当前使用的域名。不要把私钥、Cloudflare Token 或包含它们的备份放到网站目录中。

导入的两个文件须为 root 所有、没有额外硬链接，且不能由组或其他用户写入；不直接接受符号链接。若已有证书使用 `/etc/letsencrypt/live/` 一类链接目录，可先复制为普通文件：

```bash
sudo install -m 600 /etc/letsencrypt/live/site.example.com/fullchain.pem /root/site-fullchain.pem
sudo install -m 600 /etc/letsencrypt/live/site.example.com/privkey.pem /root/site-key.pem
sudo bash /opt/reality-site/reality-site.sh import-cert /root/site-fullchain.pem /root/site-key.pem
```

这里的复制只用于本次导入，今后续期仍需重新导入更新后的文件。

## 端口与目录

| 服务 | 端口 | 管理者 |
|---|---|---|
| 本工具创建的 HTTPS 网站 | 默认 TCP `127.0.0.1:8003`，仅本机 | `reality-site.service` |
| REALITY 公网入口 | 建议 TCP `443` | 3x-ui / Xray |
| 3x-ui 面板 | 保持已有面板端口 | 3x-ui |

本工具不会给网站开放公网 `8003`，也不为它新增公网 `80` 或 `443` 监听。已有系统 Nginx 服务可能有自己的监听端口，应单独检查。

网站默认关闭访问日志（`access_log off`），保留 Nginx 错误日志用于排查。

项目使用两个固定根目录：

| 目录 | 内容 |
|---|---|
| `/opt/reality-site/` | 入口、程序模块和默认资源 |
| `/var/lib/reality-site/` | 站点配置、网页、证书、acme.sh 数据及运行日志等 |

systemd 服务/定时任务、可选的 sysctl 设置放到系统已有的 `/etc` 对应目录。APT 安装的软件仍使用发行版的标准目录，不属于这两个项目目录的限制范围。

## BBR + fq

`bbr` 只开启 **当前内核已提供的 BBR**，并设置默认队列规则 `fq`；不下载内核、不安装 BBR v3、不修改引导器，也不会自动重启服务器。

默认队列规则的 sysctl 设置不保证立即替换已有网卡上的队列。程序不会强制覆盖现有队列配置；可通过 `tc qdisc show` 查看实际情况。`mq` 根队列下使用 `fq` 子队列也是正常情况。

## 排查

先检查本机准备工作：

```bash
sudo bash /opt/reality-site/reality-site.sh status
sudo bash /opt/reality-site/reality-site.sh check
sudo systemctl status reality-site.service
sudo journalctl -u reality-site.service -n 50 --no-pager
```

本机检查通过，表示本机 HTTPS 后端已准备好，**不代表 3x-ui 的公网入站、DNS、客户端和防火墙也已配置正确**。公网打不开时，继续检查面板中的 `target`、SNI、Xver、公网监听端口及节点运行状态。

本工具不包含 Xray 更新、路由规则导入或 3x-ui 配置同步功能；请继续通过面板管理这些内容。

## 本地验证

源码附带 `tests/run.sh`，在 Linux 测试环境以 root 运行；需要 Bash、OpenSSL、curl、jq 等工具，安装 ShellCheck 后还会执行静态检查。

```bash
sudo bash tests/run.sh
```

系统操作测试使用临时目录和服务/sysctl 替身。网站测试在有 Nginx 时启动临时的 `127.0.0.1:18003` 实例，真实域名迁移测试使用 `127.0.0.1:18004`；结束后停止，不修改系统 Nginx 配置。没有 Nginx 时会明确跳过真实 TLS 测试。可用 `TEST_NGINX_BIN`、`TEST_NGINX_MIME_TYPES` 指定解包的测试程序和 MIME 文件，`TEST_JQ_BIN` 可指定单独的测试 jq 程序。

测试覆盖系统/状态/恢复、证书、网站、模式切换与域名更换。域名测试包括静态及 302 模式保留、Cloudflare 与手动证书参数、同域名无操作、自循环拒绝、证书与 Nginx 失败回滚、状态写入失败和中断恢复。网站测试可使用解包的 Ubuntu Nginx，验证实际 TLS 1.3、ALPN h2、静态页面与 302 的双向切换、准确的跳转地址、隐藏文件保护，以及网页和证书保留。真实域名迁移测试使用私有测试 CA，验证换域名后实际返回的新证书、静态页面与 302 响应，以及迁移后再次导入证书仍能正确生效。失败注入测试不会操作真实 systemd 服务或访问 Cloudflare。

Cloudflare 离线测试覆盖一个 Token 管理多个区域、独立子区域、多级域名后缀、区域查询失败、私有映射文件检查、旧版凭据无网络迁移、跨区域更换域名时保留旧凭据，以及验证 TXT 的创建/清理均使用对应域名的区域。升级 hook 写入失败时也会保留原 hook。

上述自动化测试不使用真实 Cloudflare Token，不验证生产环境的证书签发；部署后仍需检查实际续期和公网节点连通性。
