# 原环境（迁移到 Docker 之前）DSH 全量归档

| 项 | 值 |
|---|---|
| 文件 | `archive/original-env-20261124.tar.zst`（**gitignored，不入库不推送**） |
| 大小 | 403,949,733 字节（原始约 1.0 GB，zstd -3） |
| sha256 | `78781611de3a6e38a0c0d0011c58acf8cfea36d3aa5074c565d7b17e01167f4e` |
| 校验 | `zstd -t` 通过；全量解压 `tar -tf` 读通，76,267 个条目 |
| 打包时间 | 2026-11-24 22:15（原主机停服前） |

## 内容（原主机 HOME 相对路径）

- `.dsh/` —— 会话历史（37 个工作区全部会话）、skills、profile 配置与 node_modules、
  `.credentials.yaml`（API 凭据）、logs、storages、model-usage ledger
- `.config/zed/` —— 钉钉推送配置（dingtalk.json）
- `.config/systemd/user/dsh-{web,token-injector,postboot-check}.service` —— 三个用户单元
- `.local/lib/node_modules/@deepseek-ai/` + `.local/bin/dsh` —— 原主机全局 dsh 安装（928 MB）
- `coding/dsh-lan-fix/` —— 原环境注入代理、启动 URL 捕获、补丁与 LAN 配套脚本
- `coding/dsh-remote-test/` —— 旧版 UI 回归测试脚本与截图
- `coding/dsh-openwrt-zed.SKILL.md` —— 游离的 skill 副本

## 不包含（公用/已迁移，勿删）

- `~/.ssh`、`~/.git-credentials` —— 公用凭据，原主机保留（其他程序依赖）
- node / npm / pnpm 本体 —— 公用运行时，原主机保留
- 数据本体已通过 `migrate.sh --final` 迁入新环境卷（dsh-data / dsh-plugins / dsh-config）

## 为什么只本地不推送

归档含 API 凭据与完整会话历史，与本仓库的公开隐私口径冲突 —— 保留在
workspace（NAS）本地，`archive/` 已在 `.gitignore`。

## 恢复方法

在原主机（或等价 HOME 布局）下执行：

```bash
zstd -d original-env-20261124.tar.zst | tar -xf - -C <原HOME>/
```
