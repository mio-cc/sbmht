# miohh

miohh = **QQ 客户端 + 中间层** 的单一部署物：环境仿真启动 QQ、二维码登录 WebUI、内置 OneBot/WebUI 运行时（侵入式 hook，注入 `wrapper.node` 进程内）。

## 组成

| 目录 | 说明 |
|---|---|
| `bin/miohh` | 统一 CLI（安装/服务/登录/运维/诊断） |
| `envsim/` | 设备环境仿真（mount/UTS 沙箱、伪造 `/proc`/`machine-id`/时区、自动 DeviceProfile） |
| `runtime/serve.py` | 运行时编排：显示 → envsim 启动 QQ → 登录 WebUI → 内置 runtime |
| `runtime/bundled/` | 内置协议运行时（Node 24 + hook 原生件 + WebUI 前端），品牌已统一为 miohh |
| `tools/login_manager.py` | 二维码登录 WebUI（截图二维码 + 状态/快速登录接口） |
| `systemd/` | 服务单元、健康检查/备份 timer、logrotate |
| `scripts/` | healthcheck/diag/backup/restore/update/service/qq/account/wipe 等 |

## 快速开始（Linux x64）

```bash
tar -xzf miohh-<版本>-linux-x64.tar.gz
cd miohh-<版本>-linux-x64
sudo bash deploy.sh deploy          # 一键：依赖 + 钉版 QQ + miohh + systemd + 启动
sudo miohh env-check                # 部署环境门禁
sudo systemctl enable --now miohh   # 或 sudo miohh start（开发模式）
```

内置 runtime 默认端口（统一入口，仅 127.0.0.1）：
- **统一 WebUI `5099`**：`/` 是 runtime 控制台，`/login/` 是 QQ 扫码登录页
- 内部端口（不对外暴露）：runtime WebUI `15099`、登录服务 `16080`
- OneBot HTTP `3000` / WebSocket `3001`
- runtime WebUI 密码：`data/runtime/webui-password`

## 运维

```bash
miohh status            # 状态
miohh healthcheck       # 健康检查（timer 每分钟）
miohh diag              # 脱敏诊断包
miohh backup            # 备份（timer 每日）
miohh update --from X   # 升级；--rollback 回滚
miohh service install   # 安装/刷新 systemd 单元与 timer
miohh logs -f           # 日志
```

## 版本与校验

- `miohh version`
- 发布包内含 `manifest.sha256`；发布包自身校验文件：`miohh-<版本>-linux-x64.tar.gz.sha256`
- CI 门禁：`tools/ci_check.sh`（语法/契约/CLI/品牌扫描）；打包：`tools/make_package.sh`（自动跑发布门禁）

## 许可与声明

- 仅用于自有/已授权账号与合规用途；不得用于违反腾讯服务条款或当地法律的行为。
- 第三方组件许可与声明见 `NOTICE`；内置运行时随包携带自身 EULA/PRIVACY（`runtime/bundled/`）。
- 本项目与腾讯无关联，QQ 客户端需自行安装并遵守其许可。

## 从源码部署（Linux，公开仓库 HTTPS 免密钥）

```bash
# 公开仓库用 HTTPS 即可，无需 SSH key（SSH 地址才需要 key）
git clone https://github.com/mio-cc/sbmht.git miohh
cd miohh

# 仓库未包含 runtime 的 node 可执行文件（126MB，超 GitHub 单文件限制），任选其一：
#   A. 从发布包复制：cp miohh-0.1.0-linux-x64/runtime/bundled/node runtime/bundled/node
#   B. 使用系统 Node 24（^24.22.1 或 >=26.12.1）

sudo bash deploy.sh deploy     # 依赖 + 钉版 QQ + miohh + systemd + 启动 + 健康检查
sudo bash deploy.sh status
```

> 更新：`git -C miohh pull --ff-only` 后执行 `sudo bash deploy.sh pull`（或 `deploy.sh update --from <包>`）。
> 注意：公开仓库**拉取**免认证，但 **push** 仍需 Deploy Key / 账号 SSH key / PAT。