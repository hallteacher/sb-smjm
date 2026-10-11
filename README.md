# sb-smjm — Sing-box 一键多协议部署脚本

一行命令在 **VPS** 或 **Serv00 / Hostuno 共享主机**上部署 Sing-box，自动生成多协议节点链接、Base64 订阅与本地订阅服务，自带保活、开机自启与管理菜单。开发期模块化、发布时内联为单文件，`bash <(curl -Ls ...)` 拉下来直接跑，无需 clone 仓库。

## 特性

- 🚀 **一行部署**：VLESS-Reality-Vision / VMess-WS(+Argo) / Hysteria2 / TUIC v5 / AnyTLS 五协议同开
- 🧩 **双环境**：VPS（root + systemd）与 Serv00/Hostuno（无 root、FreeBSD）各有专用脚本
- 🔗 **自动订阅**：生成明文节点链接与 Base64 订阅，并起一个本地 HTTP 订阅服务，客户端直接填订阅地址；状态页直接显示可扫的订阅二维码（自动安装 `qrencode`）
- ☁️ **Argo 隧道**：支持临时隧道（免域名、trycloudflare）与固定 Token 隧道，VMess 套 CDN。临时隧道每次重启域名都会变，脚本会自动把新域名同步回订阅，不用手动重装
- 💾 **配置持久化**：所有参数存 `state.env`，重装/换机可沿用 UUID 与密钥
- ☁️ **云主机适配**：AWS/GCP 等云主机网卡上只有内网 IP，脚本自动走元数据服务（IMDSv2）/ 公共 IP 接口探测公网地址，安装时也可手动填「节点地址」，不会再把 `172.x` 写进全部节点
- 🔄 **保活兜底**：有 systemd 用 systemd，没有就 nohup + PID 文件 + crontab 每 5 分钟拉起
- 📦 **单文件分发**：`dist/` 下两个独立 `.sh`，除 curl/tar 外全靠系统自带

## 两套脚本怎么选

| | `sb.sh`（VPS 版） | `serv00.sh`（Serv00/Hostuno 版） |
| --- | --- | --- |
| 环境 | 独立 VPS，需 root | 共享主机，无 root、无 systemd、FreeBSD |
| 安装位置 | `/etc/sb-smjm`，二进制在 `/usr/local/bin` | 全部在 `$HOME/sb-smjm`（含二进制） |
| 协议 | VLESS-Reality / VMess-WS / Hysteria2 / TUIC v5 / AnyTLS | VLESS-Reality / VMess-WS / Hysteria2 |
| Argo 隧道 | ✅ 临时隧道 + 固定 Token | ❌（共享主机无法装 cloudflared） |
| 进程管理 | systemd 服务（无 systemd 时降级 cron） | nohup + PID 文件 + crontab 每 5 分钟保活 |
| 订阅服务 | ✅ 默认端口 8199 | ✅ 同上 |
| 快捷命令 | ✅ 装完全局可用 `sb` | ❌ 用 `bash serv00.sh` |

> VMess-WS-TLS（自有证书模式）代码内置，一键流程默认不启用；需要时把 `state.env` 里的 `ENABLE_VMESS_TLS` 改成 `y` 再重新生成配置即可。

## 快速开始

### VPS（需要 root）

**第一步：取得 root 权限**（多数云 VPS 默认就是 root 登录，`whoami` 显示 `root` 可跳过这步）：

```bash
sudo -i
```

**第二步：一键安装**（以下命令均默认已在 root shell 中执行，**不再带 sudo**）。命令自带「curl 引导」：**新系统没有 curl 时会自动安装（apt/dnf/yum/apk 自动适配），有 curl 则直接跳过**，其余依赖（openssl / tar / python3）由脚本内部自动补装，所以全新 VPS 上复制粘贴一条命令即可：

```bash
# ① 交互式菜单（推荐，全程提示，括号内为默认值）
command -v curl >/dev/null 2>&1 || { if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl; elif command -v dnf >/dev/null 2>&1; then dnf install -y curl; elif command -v yum >/dev/null 2>&1; then yum install -y curl; elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl; fi; }; bash <(curl -Ls https://raw.githubusercontent.com/hallteacher/sb-smjm/main/dist/sb.sh)

# ② 全自动一键部署：自动选 1、其余全部回车走默认
#    装完即得「五协议直连」：VMess = 服务器IP:8080（ws、无TLS），Argo/CF 默认关闭，无需手工改节点
command -v curl >/dev/null 2>&1 || { if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl; elif command -v dnf >/dev/null 2>&1; then dnf install -y curl; elif command -v yum >/dev/null 2>&1; then yum install -y curl; elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl; fi; }; printf '1\n\n\n' | bash <(curl -Ls https://raw.githubusercontent.com/hallteacher/sb-smjm/main/dist/sb.sh)

# ③ 系统已有 curl 时的最短写法（等同 ①）
bash <(curl -Ls https://raw.githubusercontent.com/hallteacher/sb-smjm/main/dist/sb.sh)
```

> **为什么需要装 curl？** `curl` 就是把安装脚本从 GitHub 下载到 VPS 的工具（`bash <(curl ...)`），极简 Debian 镜像出厂不带它，属于"先有鸡还是先有蛋"——上面的引导段就是为解决它而设。不想切换 root shell 的话，也可以单条临时提权：在命令最前面加 `sudo -E bash -c '...'` 包住整条（或先 `sudo apt install -y curl` 再用普通用户的 `sudo bash <(curl ...)`）。

装完后**任意目录**执行 `sb` 即可再次打开管理菜单（已注册到 `/usr/local/bin/sb`）。

### Serv00 / Hostuno

```bash
bash <(curl -Ls https://raw.githubusercontent.com/hallteacher/sb-smjm/main/dist/serv00.sh)
```

> ⚠️ **必做**：到面板 **Port reservations** 把用到的端口（默认 443 / 8080 / 8443）加进去放行，**TCP 和 UDP 都要加**，否则外面连不上。脚本启动前还会自检 curl / openssl / tar，缺任一个会直接报错提示去面板开启。

### 可选：一键把 VPS 重装成干净的 Debian 12

> ⚠️ **重装会清空系统盘上的所有数据**（包括已装好的 sing-box、订阅、Argo 配置），有重要文件请先备份。重装完成后重新跑上面的一键安装即可，全流程通常 20 分钟内搞定。

VPS 出厂系统五花八门（老旧 CentOS、魔改内核、装过一堆环境的机器）。如果想要一个干净的起点，可以用 [leitbogioro/Tools](https://github.com/leitbogioro/Tools) 的网络重装脚本，在 SSH 里一条命令把系统格式化并重装为 Debian 12（无需进服务商面板）：

```bash
# 以 root 执行；缺 wget 时自动补装（Debian/Ubuntu 系）
command -v wget >/dev/null 2>&1 || { apt-get update -y && apt-get install -y wget; }; wget --no-check-certificate -qO InstallNET.sh 'https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh' && bash InstallNET.sh -debian 12
```

命令跑完、看到 `[Finish] Input 'reboot' to continue the subsequential installation.` 提示后，**再手动输入 `reboot` 才会开始正式安装**（不重启就什么都不发生）：

```bash
reboot
```

要点：

- **输入 `reboot` 后 SSH 会断开，属正常现象** —— 机器重启进安装器，在后台格式化磁盘、从 Debian 官方源网络安装新系统，**大约 10~30 分钟**（视机器和网络而定），期间 SSH 连不上、ping 不通都不要慌，也别去服务商面板强制操作，耐心等；
- 重装完成后重新 SSH 登录：
  - **用户名** `root`；**默认密码** `LeitboGi0ro`；**端口**沿用你重装前用的端口（一般是 22）；
  - 密码容易看错，拆开记：**L**eitbo（开头大写 L）+ **G**i**0**ro（大写 G，中间是数字 `0` 不是字母 O），共 11 个字符；连不上时先检查是不是 `0`/`O`、大小写打错了，还不行就去服务商面板用 VNC 控制台登录查看；
- **登录后第一件事改密码**，两种方式任选其一：
  - 方式 A（已登录，推荐）：直接运行 `passwd root`，按提示输入两遍新密码；
  - 方式 B（重装时一步到位）：在重装命令后面加 `-password` 参数，装完密码就是你定的，无需再改：
    ```bash
    bash InstallNET.sh -debian 12 -password 'MyP@ss123'
    ```
  > 默认密码 `LeitboGi0ro` 是公开的，不改等于裸奔；`-password` 是 InstallNET.sh 的参数，别加到 `passwd` 命令后面；密码含特殊符号时务必用引号包住。
- 改完密码，回到上面「快速开始」跑一键安装命令即可；
- 服务器在大陆、GitHub 拉取困难时，把命令里的 `raw.githubusercontent.com/leitbogioro/Tools/master` 换成 `gitee.com/mb9e8j2/Tools/raw/master`；
- 不支持 GCP 官方模板的机器；Alpine 系统需先 `apk add bash wget` 并把 root shell 换成 bash（详见该脚本 README）。

## 安装过程逐项说明（VPS）

运行 `sb.sh` 选 1 后依次问以下问题，**方括号内是默认值，直接回车即采用**：

| 提示 | 默认值 | 说明 |
| --- | --- | --- |
| 设置节点备注名 | sb-smjm | 节点名前缀，最终节点名如 `sb-smjm-vless`，方便多机区分 |
| VLESS-Reality 端口 | 443 | Reality 伪装端口，建议保持 443 |
| VMess-WS 端口 | 8080 | 默认公网直连（明文 ws）；启用 Argo 后只监听 127.0.0.1 |
| Hysteria2 端口 | 8443 | UDP，防火墙需放行 UDP |
| TUIC v5 端口 | 8444 | UDP |
| AnyTLS 端口 | 8445 | TCP |
| 是否启用 Argo 临时隧道 | **n** | 默认不开：VMess 走 `IP:8080` 直连，无需手工改节点；显式输 y 才装 cloudflared 套 CDN（启动失败则明文暴露该端口） |
| 本地订阅服务端口 | 8199 | HTTP 订阅服务端口，也要放行 |
| 订阅路径密码 | 空 | 留空=不要密码；填了订阅地址变为 `http://IP:8199/<密码>/sub` |

UUID、Reality 密钥对、各协议密码、自签证书**全部自动随机生成**，不用手填。生成结果写入 `state.env`，下次执行自动沿用。

**VMess 的 ws 路径默认随机生成**（形如 `/vmess-1a2b3c4d`）：固定 `/vmess` 是全网扫描器都认识的指纹，随机路径可显著降低被主动扫描识别的概率。订阅会自动带上路径，客户端无需手填；旧默认 `/vmess` 的存量安装会在下次执行安装/重装时自动迁移到随机路径（客户端刷新一次订阅即同步）。

### Serv00 版的差异

提示更精简：节点备注名、VLESS/VMess/HY2 三个端口、VMess-WS 路径、Reality 伪装 SNI、TLS SNI、节点地址。其中**节点地址**建议留空自动检测；若检测不到公网 IP，填面板域名最稳（Serv00 通常没有独立公网 IPv4 入站）。

## 管理菜单（VPS）

| 选项 | 功能 |
| --- | --- |
| 1 | 一键安装（五协议直连 + 订阅，小白推荐） |
| 2 | 查看节点 / 订阅 / 运行状态 |
| 3 | 修改端口 / SNI / 重新生成密码（改完自动重启并刷新订阅） |
| 4 | 启动 / 重启 sing-box |
| 5 | 停止 sing-box |
| 6 | 安装 Argo 临时隧道（vmess 套 CDN，免域名） |
| 7 | 安装 Argo 固定 Token 隧道（绑定自己的域名） |
| 8 | 停止 Argo 隧道 |
| 9 | 更新 sing-box 内核（重新下载最新版二进制） |
| 10 | 安装 `sb` 快捷命令 |
| 11 | 设置开机自启 |
| 12 | 关于本脚本 / 博客 / 频道 |
| 13 | 修复 Argo 隧道 / 订阅（一键自愈） |
| 14 | 关闭 Argo：VMess 改公网直连 |
| 15 | 更新本脚本（拉取 GitHub 最新版，配置/订阅不受影响） |
| 0 | 退出 |

选项 3 可单独改：VLESS / HY2 / TUIC / AnyTLS 端口、Reality SNI（"偷的站"）、或一键重新生成全部密码与 Reality 密钥对。

## 管理菜单（Serv00）

| 选项 | 功能 |
| --- | --- |
| 1 | 一键安装（三协议 + 保活） |
| 2 | 查看节点 / 订阅 / 运行状态 |
| 3 | 启动 / 重启 sing-box |
| 4 | 停止 sing-box |
| 5 | 安装 / 刷新保活（crontab） |
| 6 | 卸载 |
| 7 | 关于本脚本 / 博客 / 频道 |
| 0 | 退出 |

## 命令行参数

**sb.sh（VPS）**（需在 root shell 中执行；普通用户先 `sudo -i`）

```bash
bash sb.sh                # 交互式菜单
bash sb.sh --install      # 直接一键安装（等同菜单选项 1）
bash sb.sh --status       # 查看节点与订阅（不进菜单）
bash sb.sh --update       # 更新 sing-box 内核
bash sb.sh --upgrade      # 更新本脚本到 GitHub 最新版（配置/订阅不受影响）
bash sb.sh --version      # 查看本脚本版本号
bash sb.sh --uninstall    # 卸载（需二次确认）
bash sb.sh --help         # 帮助
```

**serv00.sh**

```bash
bash serv00.sh                 # 交互式菜单
bash serv00.sh --install       # 直接安装
bash serv00.sh --status        # 查看节点与订阅
bash serv00.sh --uninstall     # 卸载
bash serv00.sh --help          # 帮助
```

> Serv00 版没有 `--update`：想升级 sing-box 时，删掉 `$HOME/sb-smjm/bin/sing-box` 后重新执行安装，会自动下载最新版。

## 节点与订阅

安装完成后生成三样东西：

1. **明文节点链接** — `$SB_DIR/nodes.txt`，每行一个 `vless://` / `vmess://` / `hysteria2://` / `tuic://` / `anytls://`，可直接复制进客户端
2. **Base64 订阅** — `$SB_DIR/sub.txt`，整段复制到客户端当"订阅内容"导入
3. **HTTP 订阅服务** — 在本机起静态服务托管订阅，客户端填订阅地址即可自动拉取

订阅地址格式：

```
无密码：  http://<服务器IP>:8199/sub
有密码：  http://<服务器IP>:8199/<你设的密码>/sub
```

> 订阅服务优先用 `python3 -m http.server`，没有 python3 时自动改用 `busybox httpd`；两者都没有则只保留订阅文件、不起服务（脚本会提示）。装了 `qrencode` 的话，状态页会直接打印订阅二维码，手机扫码即用。

## Argo 隧道（VMess 套 CDN）

把 VMess 流量套上 Cloudflare CDN，**不需要自己的域名**，还能绕部分运营商对 8080 等端口的 QoS。两种模式：

### 临时隧道（菜单选项 6）

- 自动下载 cloudflared，启动后从日志抓一个 `https://xxx.trycloudflare.com` 临时域名
- VMess 节点地址自动换成该域名、端口 443、TLS 开启，本机只监听 127.0.0.1
- ⚠️ **临时域名每次隧道重启都会换**（VPS 重启、cloudflared 崩溃、断网重连都会触发）。脚本会自动把新域名同步回订阅，**不用重装、也不用重跑选项 6**，在客户端重新拉取一次订阅即可；详见下方「客户端里 VMess 节点显示 -1？」

### 固定 Token 隧道（菜单选项 7）

- 在 Cloudflare 后台（Zero Trust → Networks → Tunnels）创建隧道，复制 Token 粘贴进来
- 在 CF 后台把你的域名（如 `sub.example.com`）指向 `http://127.0.0.1:<VMess端口>`
- 域名固定不变，适合长期使用；Argo 开机自启会一并设好

### 客户端里 VMess 节点显示 -1？（临时隧道必读）

**现象**：客户端测延迟时，只有 VMess 那条是 `-1`（地址列是 `xxx.trycloudflare.com`），其他直连服务器 IP 的节点全部正常。

**原因**：这条节点的链路是 `客户端 → Cloudflare 边缘(443/TLS) → xxx.trycloudflare.com → cloudflared → 127.0.0.1:<VMess端口> → sing-box`。而 `trycloudflare.com` 的临时域名**每次隧道重启都会重新随机分配，旧域名立即失效**——隧道只要重启过一次（VPS 重启、进程崩溃、断网重连），订阅里记的还是旧域名，这条节点就死了。这不是故障，是临时隧道的固有特性。

**处理**：客户端**重新拉取/刷新一次订阅**即可恢复（服务器端的订阅文件会被自动同步成新域名，见下）。建议把客户端的「自动更新订阅」设为每小时，基本可以做到无感。

**一键安装后还会不会再出现 -1？**

- **现在的新版脚本（默认不开 Argo）**：不会。VMess 直接生成 `服务器IP:8080` 直连节点，链路里没有隧道域名这一环，**从根上不存在漂移问题**。
- **旧安装 / 显式输 y 开启了 Argo 的**：装完的当下不会（安装时现场拿新域名生成订阅，所有节点全通）；之后隧道每次重启都会换新域名，客户端缓存的还是旧域名就会 -1 —— 服务器端订阅会在几秒~几分钟内自动更新（systemd 前台托管 + cron 每 5 分钟 `--argo-guard` 巡检 + 开机自启），**刷新订阅即愈**。不想要这条线就在 VPS 上跑 `bash /etc/sb-smjm/sb.sh --direct` 一键拆除。
- **想用 CDN 线又不想域名漂移**：菜单 7 的**固定 Token 隧道**，绑定自己的域名后域名永远不变，订阅永远有效。

**还是不通？先试一键自愈（SSH 到 VPS 执行，会自动拉起/重启隧道并重建订阅）：**

```bash
bash /etc/sb-smjm/sb.sh --heal     # 或打开 sb 菜单选 13
```

仍不通再按链路逐段排查：

```bash
# ① 当前隧道真实域名 vs 订阅里写的域名（不一致 = 域名过期，刷新订阅即可）
grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /etc/sb-smjm/argo.log | tail -n1
grep '^vmess://' /etc/sb-smjm/nodes.txt | head -1 | sed 's#vmess://##' | base64 -d  # 看 "add" 字段

# ② cloudflared / sing-box 进程状态与日志
systemctl status argo-smjm --no-pager
systemctl status sing-box --no-pager
tail -n 30 /etc/sb-smjm/argo.log

# ③ 本机回源通不通（返回 200/400 都算通；超时/拒绝才是断。端口、路径以 state.env 为准）
grep -E 'PORT_VMESS|VMESS_PATH' /etc/sb-smjm/state.env
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/vmess

# ④ VPS 到 Cloudflare 边缘通不通（用 ① 查到的当前域名）
curl -s -o /dev/null -w '%{http_code}\n' https://xxx.trycloudflare.com/vmess
```

> 对应处理：① 域名不一致 → 客户端刷新订阅；② 失败 → 看日志报错后用菜单 4 / 6 重启；③ 失败 → 核对 `state.env` 里的 `PORT_VMESS` / `VMESS_PATH`；④ 不通 → 该机房出站到 Cloudflare 被干扰，只能换固定 Token 隧道或弃用这条节点。另外 4 个直连节点与 Argo 完全无关，**永远不会因隧道重启而 -1**；VMess-Argo 这条可当 IP 被墙时的 CDN 备用线。

## 保活与开机自启

| 环境 | 机制 |
| --- | --- |
| VPS + systemd | 注册 `sing-box.service`、`argo-smjm.service` 与 `sb-sub.service`（订阅服务），开机自启、崩溃自动重启 |
| VPS 无 systemd | 生成 `boot.sh` + crontab `@reboot` 拉起 sing-box / Argo / 订阅服务 |
| Serv00 | crontab **每 5 分钟**检测 PID，掉了自动拉起（`$HOME/sb-smjm/keepalive.sh`） |

手动操作：VPS 用菜单 11 设开机自启，Serv00 用菜单 5 安装/刷新保活（Serv00 面板如果重启过机器，5 分钟内会自动恢复）。

## 安装目录与文件

**VPS** — `/etc/sb-smjm`

| 文件 | 内容 |
| --- | --- |
| `config.json` | sing-box 主配置（各协议 inbound） |
| `nodes.txt` / `sub.txt` | 明文节点 / Base64 订阅 |
| `state.env` | 全部参数（UUID、密钥、密码、端口、协议开关） |
| `cert.pem` | Hysteria2 / TUIC 用的自签证书 |
| `web/` | 订阅服务根目录 |
| `boot.sh` / `argo_boot.sh` | 无 systemd 时的启动脚本；`argo_boot.sh` 还负责临时隧道换域名后自动重建订阅 |
| `singbox.log` / `argo.log` | 运行日志（**排错先看这两个**） |

**Serv00** — `$HOME/sb-smjm`，同样一套，外加 `keepalive.sh`（保活脚本）、`singbox.pid`；二进制在 `$HOME/sb-smjm/bin/sing-box`。

## 常见问题

**Q：安装完连不上？**
A：九成是端口没放行。VPS 查云厂商安全组 + 本机 `ufw`/`firewalld`；Serv00 去面板 Port reservations 加端口（**TCP 和 UDP 都要加**，HY2 / TUIC 走 UDP）。

**Q：VLESS 的 443 被占用，或想改端口？**
A：菜单 3 可单独改各协议端口，改完自动重启并刷新订阅，客户端重新拉订阅即可。

**Q：订阅地址打不开？**
A：订阅端口（默认 8199）也要放行；另外服务器若没有 python3 / busybox 就起不了服务（脚本会提示），可只复制 `sub.txt` 内容手动导入。

**Q：Argo 临时隧道域名老变？**
A：临时域名每次启动都会重新随机分配，这是 Cloudflare 的限制，**没法固定**。脚本现在会自动处理：隧道一旦重启或挂掉，`argo_boot.sh`（cron `@reboot` + 每 5 分钟，systemd 下由 unit 前台托管）会重新读出当前域名、更新 `state.env` 并重建 `nodes.txt` / `sub.txt`，客户端重新拉一次订阅即可，不用重装。想彻底免折腾就用菜单 7 的固定 Token 隧道（域名不会变）。

**Q：状态页看不到订阅二维码 / 提示「未安装 qrencode」？**
A：二维码靠系统包 `qrencode` 渲染，旧版脚本从未安装它，所以几乎总是显示「未安装」。新版安装时会自动尝试安装（个别精简源没有该包时仅跳过二维码，不影响节点）。老版本手动 `apt install qrencode`（或 `dnf install qrencode`）后重开菜单即可。顺带修复：旧版菜单 2 的订阅地址永远显示「未启动」（`SUB_URL` 只在安装那一个进程里存在），新版改为从 `state.env` 实时推导，并显示订阅服务真实运行状态。

**Q：AWS 等云主机装完，客户端测延迟全部是 -1？**
A：云主机（AWS/GCP/阿里云等）的网卡上只有 VPC 内网 IP（如 `172.31.x.x`），公网 IP 是宿主侧 NAT 映射、不会出现在网卡上。旧版脚本只读网卡，把内网地址写进了全部节点链接，于是全线 -1。新版已修复：安装时优先用 AWS 元数据服务（IMDSv2）探测公网 IP（其余环境走公共 IP 接口），并新增「节点地址」输入项可手动覆盖。老版本应急修复：在 `/etc/sb-smjm/state.env` 加一行 `NODE_ADDR=你的公网IP`，执行 `bash /etc/sb-smjm/sb.sh --direct` 重建订阅即可。另外 AWS 安全组记得放行 TCP 443/8080/8445/8199 与 **UDP 8443/8444**。

**Q：客户端里 VMess 节点显示 -1？**
A：临时隧道域名过期了（只有这一条会 -1，其他直连节点不受影响）。服务器端订阅已被自动同步成新域名，**客户端重新拉取一次订阅**即可恢复。一键安装完成的当下不会 -1；想一劳永逸用菜单 7 固定 Token 隧道。完整排查步骤见「Argo 隧道」一节的「客户端里 VMess 节点显示 -1？」。

**Q：重装系统 / 换机器，能沿用旧 UUID 和节点吗？**
A：可以。备份旧 `state.env`，新机器装完后覆盖到新的 `$SB_DIR`，再执行菜单 1 或 3（一路回车）重新生成配置与订阅，UUID / 密钥 / 密码全部沿用。

**Q：脚本本身怎么更新？**
A：重新 `curl` 一遍最新脚本运行即可，`state.env` 会保留，相当于平滑升级。

**Q：想全自动部署（CI / 批量开机）怎么写参数？**
A：用 `printf` 按提示顺序喂答案，空行=用默认值（需在 root shell 中执行，普通用户先 `sudo -i`）。提示顺序：**备注名 → 节点地址（留空=自动探测公网 IP）→ 5 个端口 → 是否启用 Argo（默认 n）→ 订阅端口 → 订阅密码**。例如 VPS 版只要前三个端口改、其余默认：

```bash
printf '1\n\n\n443\n8081\n8443\n\n\n\n\n\n\n' | bash sb.sh
```

> 注意：末尾的空行喂给「是否启用 Argo」时采用默认值 **n**（不开隧道，VMess 公网直连）——旧版默认是 y，新版已反转；想开 Argo 就在对应位置显式喂一行 `y`。

**Q：sing-box 启动失败怎么办？**
A：菜单 4 重启会自动 `tail` 末尾 20 行日志；Serv00 看 `$HOME/sb-smjm/singbox.log`，VPS 看 `/etc/sb-smjm/singbox.log`。常见原因：端口冲突、端口未放行、配置被手改坏（删掉 `state.env` 重装可彻底重来）。

## 抗封锁说明（必读）

**一句话：脚本给的是「合格的伪装」，不是「免死金牌」。** 协议层面用的都是当前主流的抗封锁设计，但**不存在 100% 防封的节点**——封不封取决于「协议伪装 + IP 质量 + 流量特征」三者组合，脚本只解决第一项。

### 分协议抗封锁能力

| 协议 | 抗封锁原理 | 强度 | 本脚本的具体风险点 |
| --- | --- | --- | --- |
| **VLESS-Reality** | 偷真实网站的 TLS 握手（SNI 伪装），被主动探测时返回真实站点证书 | ⭐⭐⭐⭐⭐ 当前最强 | 默认偷 `www.yahoo.com`，全网共用同一 SNI 反而成了特征；机房 IP 被标记照样废 |
| **AnyTLS** | 新协议，流量长得像普通 HTTPS，设计目标就是对标 Reality 抗主动探测 | ⭐⭐⭐⭐ | 生态新、特征库没经过大规模实战；本脚本用**自签证书**，主动探测时不如真站可信 |
| **Hysteria2** | 基于 QUIC，伪装成 HTTP/3 | ⭐⭐⭐⭐ | 走 UDP，运营商 QoS 常限速/丢弃 UDP；大流量易触发 IP 审查；自签证书 |
| **TUIC v5** | 同 Hysteria2，QUIC 系 | ⭐⭐⭐⭐ | 同上（UDP + 自签证书） |
| **VMess-WS** | 走 WebSocket，套 Argo/CDN 后出口是 Cloudflare 的 IP | ⭐⭐⭐½ | **明文 + 默认固定路径 `/vmess`**：Argo 正常时只听 127.0.0.1 没问题；没装 Argo 或 Argo 启动失败，就是公网裸奔明文 WS，分分钟被扫出来 |

### 脚本已经做的加固

- **Argo 隧道（Cloudflare Tunnel）**：启用后 VMess 只监听 `127.0.0.1`，VPS 真实 IP 完全不暴露，封它等于封整个 Cloudflare，成本极高——这是最稳的一层（菜单 6 / 7）
- **Reality 的 SNI 偷取**：主动探测时返回真实第三方网站证书，GFW 无法靠特征区分
- **本地自建订阅**：订阅走自己 IP 的本地服务，不用公共订阅转换站，减少暴露面；可设路径密码

### 想更稳，自己动手改这几项

1. **换掉默认 Reality SNI**：菜单 3 → 选 5，改成自己挑的、与机房同区的流行 HTTPS 站（别用默认值，全网共用等于特征）
2. **换掉默认 WS 路径**：`state.env` 里的 `VMESS_PATH` 默认是固定的 `/vmess`，改成随机一串再重新生成配置（Serv00 版安装时直接会问）
3. **VMess 一定要套 Argo**：没 Argo 的明文 WS 是整套配置里最薄弱的一环；VPS 用菜单 6（临时）或 7（固定 Token，绑自己域名，域名不会变）
4. **订阅加密码**：安装时「订阅路径密码」别留空，否则谁扫到 8199 端口都能拿到你全部节点
5. **选干净 IP + 流量别太夸张**：廉价机房 IP 段早被重点照顾；单机 24h 满速跑，协议再真也会被行为分析盯上

> **推荐组合**：VPS 用 **VLESS-Reality（主）+ Hysteria2（备，不同端口分流）**；Serv00/共享主机用 **VLESS-Reality（主）+ Hysteria2（备）**，VMess-WS 没有 Argo 可套，明文暴露只配当备用或干脆关掉。

## 卸载

```bash
bash sb.sh --uninstall           # VPS（root shell，需二次确认）
bash serv00.sh --uninstall       # Serv00（需二次确认）
```

VPS 版会停服务、删 systemd unit、清 crontab、删 `/etc/sb-smjm` 与两个二进制（`sing-box`、`cloudflared`）及快捷命令 `sb`；Serv00 版保留 `bin/` 目录方便下次复用，可自行删除。

## 频道与博客

- 博客: https://smjmblog.blogspot.com/
- YouTube: https://www.youtube.com/@DECODING-w7d
- Telegram 群组: https://t.me/+tVg48WK48tlkNGVl

## 仓库结构

```text
sb-smjm/
├── sb.sh              # VPS 主脚本（开发态 source lib）
├── serv00.sh          # Serv00/Hostuno 专用
├── build.sh           # 打包：把 lib 内联进 dist/*.sh
├── lib/
│   ├── common.sh      # 输出/输入/随机数/系统检测/IP 检测
│   ├── install.sh     # sing-box/cloudflared 下载、systemd 服务管理
│   ├── config.sh      # 六种 inbound JSON 生成（含 vmess-ws-tls）
│   ├── argo.sh        # Argo 隧道（临时/固定 Token）+ 开机自启
│   └── subscription.sh# 节点链接 + Base64 订阅 + 本地订阅服务
├── tests/run_tests.sh # 本地逻辑测试（不需要 VPS）
└── dist/              # 构建产物（单文件，可直接 curl 运行）
```

## 开发与测试

```bash
bash build.sh            # 内联打包 + 语法检查
bash tests/run_tests.sh  # 本地测试：语法 / 单元 / 配置 / 链接 / 非交互管道
```

测试覆盖（108 项，全部通过）：

1. 所有脚本 `bash -n` 语法检查
2. `rand_uuid` / `rand_hex` / `rand_password` / `b64` / `url_encode` 单元测试
3. 五协议 inbound JSON 合法性
4. `build_config` 完整组装（6 个 inbound）
5. 节点链接生成与解析（vmess base64 解码、订阅有效性）
6. 非交互管道输入（`printf '2' | sb.sh`）
7. serv00.sh 专项（无 root 依赖、非交互、`--help`）
8. 频道链接完整性（博客 / YouTube / Telegram 三条在 common.sh 与 dist 产物中齐全）
9. 云主机公网 IP 探测回归（`is_private_ip` 私网段判定、`fetch_public_ip` 拒绝私网地址、`--direct` 重建后同步 web/ 订阅目录）

## 兼容性说明

- 编辑器写出 CRLF，`build.sh` 统一转 LF（bash 对 CRLF 敏感，仓库根 `.gitattributes` 也强制 LF）
- `rand_uuid` / `url_encode` 兜底链：`/proc/sys/kernel/random/uuid` → `uuidgen` → `python3` → `python`
- 无 systemd 时自动降级为 `nohup` + PID 文件 + crontab 保活
- 非交互模式通过 `read_input` 的 EOF 返回码退出菜单（不依赖 `read -t 0`，避免部分 bash 实现的 bug）
- Serv00 是 FreeBSD，二进制自动选 `freebsd-amd64/arm64/armv7` 包；`uname -m` 不在支持列表会直接报错
- 公网 IP 探测顺序：AWS 元数据（IMDSv2）→ 公共 IP 接口（ipify / ifconfig.me / ip.sb，全部短超时，个别被墙也不卡安装）→ 网卡兜底；网卡兜底若拿到私网段会 WARN 提示，云主机上不会再把 VPC 内网 IP 写进节点链接。离线环境或自动化测试可设 `SB_NO_NETWORK=1` 跳过一切外部探测

