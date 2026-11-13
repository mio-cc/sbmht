# miohh 契约（contracts）

每个 QQ 版本一份 JSON，记录登录流程所需原生函数的模块内相对偏移（RVA）与特征，供
miohh runtime / native payload 在启动时校验与定位。

## 文件命名

```text
contracts/qq-<version>.json      例: qq-3.2.32-52194.json
```

## 生成方式

```bash
python3 tools/locate_login_funcs.py /opt/QQ/resources/app/wrapper.node \
  --out contracts/qq-3.2.32-52194.json
```

静态定位结果为**候选**，必须经过动态验证（PoC hook）后才可写入运行时契约。

## 字段

```json
{
  "binary": "wrapper.node",
  "sha256": "<二进制哈希>",
  "size": 149670240,
  "elf_min_vaddr": 0,
  "strings": { "<接口名>": [{"va":..., "rva":..., "ctx": "..."}] },
  "refs_by_key": { "<接口名>": [{"insn_rva":..., "func_rva":..., "target_rva":...}] },
  "callback_candidates": [{"func_rva":..., "keys":["pngBase64QrcodeData","qrcodeUrl"]}],
  "verified": false
}
```

`verified: true` 仅在动态 PoC 验证（hook 到目标函数、事件可复现）后由构建流程写入。
