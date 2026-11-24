# dsh-docker

官方 [DeepSeek Harness（dsh）](https://www.npmjs.com/package/@deepseek-ai/dsh) Web GUI 的容器化打包：
Portainer stack（compose）管理，经反代对外提供服务，数据全部落在卷上，镜像可迭代升级而不破坏数据。

## 双版本号

镜像有独立于 dsh 的打包版本，同时标明所打包的官方版本，三处对得上：

| 位置 | 示例 | 说明 |
|---|---|---|
| 镜像 tag | `ghcr.io/xylz0928/dsh-docker:1.0.5-dsh0.2.2-rc.5` | `<打包版本>-dsh<官方版本>`，另有 `latest` 指向最新构建 |
| OCI 标签 | `org.opencontainers.image.version=1.0.0`、`io.dsh.official-version=0.2.2-rc.5`、`io.dsh.revision=<git sha>` | `docker inspect` 直接可见 |
| 设置页 | 设置 → 最下方「Docker DSH」分区 | 镜像版本 / 打包官方版本 / 运行中版本 / 检查官方最新版按钮 |

改版本只动两个文件：`VERSION`（打包版本，本仓库有改动就递增）、`dsh-version`（官方 dsh 版本）。

## 架构

```
浏览器 → 反代(nginxwebui, 20443) → webs 网络 → dsh:3081 注入代理 → dsh:3080 dsh web
                                                   ↑
                              容器内捕获 dsh 的 launch token，自动完成 ?token= 换 cookie
```

- **注入代理**（`payload/token-injector.js`）：dsh ≥0.2 每次启动换 launch token，浏览器直连要手贴
  `?token=`；代理自动补 token 并在 401 时重试，WebSocket 原样透传。
- **dsh web 只绑容器 IP**：dsh 拒绝绑定通配地址（RCE 暴露面），entrypoint 自动探测容器 IP 写入
  `--patch` 覆盖层；容器 IP 每次重建会变，启动时重新生成，无需人工维护。
- **受信反代**：`DSH_PUBLIC_URL` 决定对外地址，受信 authority（Host 围栏）自动从中推导，
  额外的用 `DSH_TRUSTED_HOSTS` 追加。

## 部署（Portainer stack）

1. 准备宿主目录与数据卷（CIFS/NAS 路径按需修改；卷为 external，先建再部署）：

   ```bash
   mkdir -p /mnt/docker-files/dsh/workspace
   docker volume create dsh-config dsh-data dsh-plugins
   ```

2. 部署为 Portainer stack（三选一）：
   - Portainer UI → Stacks → Add stack → 粘贴本仓库 `docker-compose.yml`，环境变量按 `.env.example` 填；
   - 脚本走 API（创建或更新同名 stack，可重复执行）：
     `PORTAINER_URL=... PORTAINER_TOKEN=... ./scripts/portainer-deploy.sh`；
   - 宿主上 `docker compose --env-file .env up -d`（不进 Portainer，仅调试用）。
3. 反代（nginxwebui）新建站点 `https://<你的域名>:<端口>`，反代目标填容器：
   `http://dsh:3081`（与本 stack 同处 `webs` 网络时直接走容器名；不同网络则用宿主 IP + 映射端口）。
4. 打开反代地址，注入代理会自动完成登录换 cookie。

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_IMAGE_TAG` | `latest` | 镜像 tag（compose 侧） |
| `DSH_PUBLIC_URL` | 空 | **自己的 dsh 反代链接**，如 `https://dsh.mydomain.com:20443/`；受信 authority 自动推导 |
| `DSH_TRUSTED_HOSTS` | 空 | 额外受信 authority，逗号/空格分隔 |
| `TZ` | `Asia/Shanghai` | 容器时区；也可改用 compose 中注释掉的 `/etc/localtime` 挂载 |
| `DSH_WEB_PORT` | `3080` | dsh web 容器内端口 |
| `DSH_INJECTOR_PORT` | `3081` | 注入代理容器内端口（反代目标端口） |
| `DSH_PUBLISHED_BIND` | `127.0.0.1:3081` | 宿主实际发布的端口，仅用于设置页展示 |
| `DSH_WEB_HOST` | 自动探测 | 容器内 dsh 绑定 IP，一般不用设 |
| `DSH_NPM_REGISTRY` | `https://registry.npmjs.org` | 「检查官方版本」按钮查询的 npm 源 |

### 卷

| 挂载 | 内容 |
|---|---|
| `dsh-config:/home/dsh` | HOME 骨架：`.config`（钉钉等）、git 凭据、ssh config/known_hosts |
| `dsh-data:/home/dsh/.dsh` | **会话历史**、设置、DSH 凭据（api key）、skills、profiles |
| `dsh-plugins:/home/dsh/.dsh/plugins` | 插件，单独管理 |
| `/root/.ssh/id_rsa(.pub)`（ro）+ `/root/.ssh/dhost-known-hosts`（ro 种子）—— 必须挂 /root/.ssh（ssh 展开 ~ 用 passwd 家目录，不认 $HOME）；容器本地 known_hosts 由种子初始化，否则 ssh 的 rename 更新在 bind mount 上 EXDEV 失败、学习不落盘 | **宿主 root 的 SSH key**，容器内 git/ssh 以此身份访问远端 |

> **密钥边界**：仓库与镜像不携带任何密钥内容。私钥由各环境在 compose 里挂载自己的
> 宿主 `/root/.ssh`；“哪台节点信任这把钥匙”是**每套部署各自的本地动作**——把你自己
> 宿主的公钥追加到目标节点的 `authorized_keys`（OpenWrt 在 `/etc/dropbear/authorized_keys`），
> 镜像升级不会、也不应该触及这层信任关系。
| `/mnt/docker-files/dsh/workspace` → `/workspace` | **项目数据** = 容器工作目录 |
| 同上 → `/home/dsh/coding`、`/home/zed/coding/docker` | 兼容迁移会话与 skill 里的旧路径（不需要可删） |

改挂载/端口/环境变量后在 Portainer 里 Update the stack 即可；数据卷不受镜像更新影响。

## 设置页「Docker DSH」

设置对话框最下方的分区（插件 `plugin/`，经 `--patch` 覆盖层启用，无官方代码补丁）：

- 镜像版本 / 构建提交、打包官方 DSH 版本、运行中 DSH 版本（读启动清单的 release）
- 信任的反代（`DSH_PUBLIC_URL`）与全部受信 authority
- 开放的端口（容器内 web/injector + 宿主发布绑定）
- 当前时区（`TZ` 与 `/etc/localtime`）、容器当前时间（按容器时区走秒）
- **检查官方 DSH 版本** 按钮：宿主代理请求 npm registry（10 分钟缓存），与运行版本比对

## 账号登录（丢失后如何重新登录）

dsh 的 DeepSeek 账号 OAuth **只接受回环 origin**（`loginOrigin()` 仅放行
`http://localhost|127.0.0.1|[::1]:<port>`，官方注释即 “local or SSH-forwarded login”），
`https://你的域名` 无法完成登录。登录丢失时：

```bash
./scripts/login-tunnel.sh            # 本机 3080 → dhost 注入代理 3081
# 或手工：ssh -N -L 3080:127.0.0.1:3081 user@your-dhost
```

浏览器打开 `http://localhost:3080/` → 页面内登录 → 关闭隧道。
（浏览器若直接跑在 dhost 上，也可开 `http://127.0.0.1:3081/` —— compose 把注入代理
发布在宿主回环 `127.0.0.1:3081`。）

登录态（grant）存服务端 `~/.dsh/.credentials.yaml`，登录一次后 `https://你的域名`
各入口自动生效：注入代理会为每个 authority 自动完成 launch-token 换 cookie。

**登录是每账号一次、不是每设备一次**：grant 在服务端卷里，任意一台机器完成上面
这一次回环登录后，局域网所有设备（含手机）走域名即用，无需各自再登。

> 为什么不能直接把端口发布到局域网就登录：`loginOrigin()` 校验的是**浏览器地址栏**
> 的 origin（`callbackOrigin = window.location.origin`），打开 `http://<LAN-IP>:3081`
> 会在 `startSignIn` 处被 protocol 拒绝 —— 登录那一步地址栏必须是
> `http://localhost:<任意端口>`。LAN 端口只能当“设备本机回环垫片”的目标端。

### 应急：某台设备没有 ssh 客户端时（临时开 LAN 口 + 本机垫片）

1. 临时把 compose 的 ports 改为 `- "3081:3081"`（或绑 LAN IP）并 Update stack；
2. 该设备本机做回环转发，把 `localhost:3080` 送到 `your-dhost:3081`：
   - Windows 10+（管理员 cmd，零安装）：
     ```
     netsh interface portproxy add v4tov4 listenport=3080 listenaddress=127.0.0.1 connectport=3081 connectaddress=192.168.1.100
     ```
     登完删除：`netsh interface portproxy delete v4tov4 listenport=3080 listenaddress=127.0.0.1`
   - Linux/Mac：`socat TCP-LISTEN:3080,fork,bind=127.0.0.1 TCP:192.168.1.100:3081`
3. 浏览器开 `http://localhost:3080/` 登录 → 关垫片 → **把 ports 改回 `127.0.0.1:3081:3081`**。

⚠️ LAN 可达期间，局域网任何设备都能免密直进 dsh（launch-token 自动交换，
tinyauth 只在反代层）——所以只在登录窗口临时开，登完立即收回。

## 升级

1. 改 `dsh-version`（升官方 dsh）和/或 `VERSION`（本仓库打包改动）→ push；
2. GitHub Actions 构建并推送 `ghcr.io/xylz0928/dsh-docker:<版本>`（`.github/workflows/build.yml`）；
3. Portainer → 本 stack → Update，镜像重新拉取，容器重建；数据卷与挂载原地保留。

本地调试构建：`./scripts/build-local.sh`（在有 docker 的宿主上执行，产出与 Actions 相同的 tag）。

### 与官方包的关系（为什么升级是整包替换、零残留）

镜像里的 `@deepseek-ai/dsh` **原版安装、零改动**；所有定制都走官方扩展点旁挂在数据面：

| 定制 | 位置 | 机制 |
|---|---|---|
| 监听/受信反代/插件启用 | 启动时生成的 `/tmp/cordis.docker.patch.yml` | 官方 `--patch` 覆盖层，每次启动按环境重算 |
| 个人 profile 配置 | 卷内 `cordis.patch.yml` | 官方 profile 补丁层（配置，非代码） |
| Docker DSH 设置分区 | 卷内 profile 依赖 `dsh-docker` | 官方插件，按 version 幂等重装 |
| token 注入 | 镜像内独立进程 | sidecar，与 dsh 版本无关 |
| @ponydev/dsh-model-usage 三处修复 | 卷内 profile node_modules | **唯一文件级补丁**（第三方包，非官方 dsh），启动幂等重放、fail-soft |

升级后验收：`verify.sh` 全绿 + 启动日志无 `did not activate`（官方若改插件 id，
profile 对应配置条目会失活，属配置层问题）+ 设置页分区正常。
model-usage 补丁的退出条件：上游发版修复后锚点检测会提示“锚点未找到”，届时删掉
entrypoint 中的重放行即可。

### 换域名（反代地址变更）

1. 改 Portainer stack Env `DSH_PUBLIC_URL=https://新域名/` → Update
   （或 `DSH_PUBLIC_URL=... ./scripts/portainer-deploy.sh`）——受信 authority
   启动时自动重算，其余全部自动跟随：`verify.sh` 从容器 env 推导期望 Host、
   设置页实时展示受信列表、launch URL 按新 public-url 生成。
   过渡期新旧域名并存：追加 `DSH_TRUSTED_HOSTS=旧域名,旧域名:20443`。
2. 反代（nginxwebui）：新域名站点 `proxy_pass http://dsh:3081`；旧站点随后删除。
3. skill 中的 GUI 地址以 stack Env 的 `DSH_PUBLIC_URL` 为准，无需逐处改。

## 目录

```
Dockerfile                  基座 node:24-bookworm-slim + 运行期依赖 + 全局 dsh
docker-compose.yml          Portainer stack 定义
payload/entrypoint.sh       启动编排（IP 探测/覆盖层/插件安装/补丁重放/双进程监管）
payload/token-injector.js   launch token 注入代理
payload/patch-dsh-model-usage.py  本地补丁（小米 Token Plan 端点 / 错误码 / 多 frame zstd 回填）
plugin/                     设置页「Docker DSH」分区（host + client）
examples/cordis.patch.yml   新用户 profile 覆盖层示例
```
