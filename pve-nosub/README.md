# pve-nosub — no-subscription 换源 + 去订阅弹窗（持久化）

给**未购买订阅**的 PVE 母机做的两件日常事：

1. **换源**：禁用需要订阅的 enterprise 源，启用免费的 no-subscription 源（内容与 enterprise 同源同仓，只是更新节奏略慢）
2. **去弹窗**：去除每次登录 Web 控制台都弹出的「No valid subscription」窗口，并通过 apt 钩子**持久化**——升级覆盖 JS 文件后自动重新补丁，弹窗不会复活

兼容 PVE 7.x / 8.x / 9.x（Debian 11 / 12 / 13），自动识别两种仓库格式。

## 换源明细

| 版本 | 格式 | 处理 |
|---|---|---|
| PVE 9 (trixie) | deb822 `.sources` | `pve-enterprise.sources` / `ceph.sources` 中的 enterprise 段加 `Enabled: no`，no-subscription 段启用；没有 pve-no-subscription 源则新建官方格式的 `proxmox.sources` |
| PVE 7/8 (bullseye/bookworm) | 传统 `.list` | 注释 enterprise 行、取消注释官方预留的 no-subscription 行；没有则新建 `pve-no-subscription.list`；`ceph.list` 按原有 enterprise 行自动补对应版本的 no-subscription 源 |

Debian 官方源（`debian.sources` 等）不动。全部操作可重复执行，不会产生重复条目。

## 去弹窗的持久化原理

弹窗来自前端 JS（PVE 7/8/9 在 `proxmox-widget-toolkit/proxmoxlib.js`）里的订阅状态检查。包升级会把 JS 文件还原，弹窗复发——这是多数一次性补丁的通病。

本脚本的解法：

1. 补丁逻辑落在独立脚本 `/usr/local/bin/pve-nag-patch`（兼容新旧写法：`res.data.status`、可选链 `res?.data?.status`、PVE 6 及更早的多行 `Ext.Msg.show`）
2. 安装 apt 钩子 `/etc/apt/apt.conf.d/90pve-no-nag`（`DPkg::Post-Invoke-Success`），**每次 apt 安装/升级成功后自动重跑补丁**
3. 补丁前就地备份 `.nagbak`，`--restore` 可还原

## 使用

```bash
# 换源 + 去弹窗（默认不更新系统）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub/pve-nosub.sh)

# 追加系统更新：所有可更新项装到最新，全自动免交互
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub/pve-nosub.sh) --upgrade

# 回滚（恢复 enterprise 源、恢复弹窗、删除钩子与新建文件）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub/pve-nosub.sh) --restore
```

`--upgrade` 的免交互策略：跳过变更日志分页阅读（`APT_LISTCHANGES_FRONTEND=none`）、配置文件冲突保留现有配置（`confdef/confold`）、服务自动重启（`NEEDRESTART_MODE=a`）。内核更新后脚本会提示重启。

## 验证

```bash
# 源状态：enterprise 应为 Enabled: no / 被注释，no-subscription 应启用
grep -r . /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null | grep -i proxmox

# apt 钩子已安装
apt-config dump | grep pve-nag-patch

# 弹窗补丁已生效（应输出 false）
grep -o "res.data.status.toLowerCase() !== 'active'" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js || echo "已补丁"
```

弹窗去除后浏览器需 **Ctrl+F5 强制刷新**清缓存才生效。

## 备份与回滚

每次执行把改动前的文件按原路径备份到 `/root/pve-nosub-backup/<时间戳>/`，并写 `manifest`（`M`=改动过，`C`=新建的）。`--restore` 依据 manifest：先删新建文件（钩子、新建的源），再还原改动文件，最后恢复 `.nagbak` 弹窗 JS。

## 已知边界

- no-subscription 源不含 enterprise 的稳定性筛选，生产关键机请自行评估；订阅用户不应使用本脚本
- 若 PVE 未来版本改掉订阅检查的具体写法，补丁会「未命中」并告警，此时钩子保留、源配置不受影响
- 补丁只影响登录提示弹窗，不影响任何更新功能本身

## 文件清单

| 文件 | 说明 |
|---|---|
| `pve-nosub.sh` | 主脚本（默认换源+去弹窗；`--upgrade` / `--restore`） |
