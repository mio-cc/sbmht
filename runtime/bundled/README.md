# bundled runtime

本目录是 miohh 内置的 OneBot/WebUI 运行时（Node 24 + hook 原生件 + 前端资源）。

## Git 仓库说明

- `index.mjs`、`client/`、`native/` 等随仓库提交；
- **`node` 可执行文件（约 126MB）不提交**（超过 GitHub 单文件 100MB 限制）。

## 首次部署时补齐 node

任选一种：

1. 从发布包复制：解压 `miohh-<版本>-linux-x64.tar.gz` 后，把其中的
   `runtime/bundled/node` 放到本目录；
2. 使用系统 Node（引擎要求 `^24.22.1 || >=26.12.1`）：
   ```bash
   # 确认版本
   node --version
   ```
   然后设置 `MIOHH_RUNTIME` 相关启动逻辑会回退到 `node`（若本目录没有可执行文件）。

> `scripts/serve.sh` / `runtime/serve.py` 会优先使用本目录的 `node`，
> 不存在时回退到 PATH 中的 `node`。
