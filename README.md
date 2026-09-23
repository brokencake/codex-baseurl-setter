# Codex Base URL 填写器

macOS 上双击就能改 Codex `config.toml` 里 `openai_base_url` 的小工具。
带开关：一键关闭自定义地址（回到 Codex 默认连接），再一键恢复。
自动备份、写入前验语法、顺手测一下地址通不通。

![icon](assets/icon.png)

## 解决什么问题

Codex 桌面版没有图形化的 Base URL 输入框，改地址只能手动开 `~/.codex/config.toml`。
而这个目录在访达里是隐藏的，TOML 少个引号整个文件就废、Codex 直接起不来。

这个脚本把这件事变成：双击 → 粘贴地址 → 回车。

## 用法

1. 下载后把 `Codex地址.command` 放到桌面（或任何你喜欢的位置）
2. 首次使用先给执行权限：

   ```bash
   chmod +x Codex地址.command
   ```

3. 双击，按菜单选择：

   | 选项 | 作用 |
   |---|---|
   | 1 | 开关：已开启时关闭自定义地址；已关闭时恢复上次记住的地址 |
   | 2 | 填写 / 修改自定义地址并开启 |
   | 3 | 从当前地址刷新模型清单（发布新模型后使用） |
   | 0 | 退出，不修改 |

关闭时，原地址以注释 `# codex-url-switch-saved = "..."` 记在 `config.toml` 开头，下次选 1 即可恢复。

关闭时如果配置了固定模型清单（`model_catalog_json`），也会一并停用并记成注释 `# codex-url-switch-saved-catalog = "..."`，否则切回默认连接后模型列表仍被旧清单限制。重新开启时自动恢复。

> 开关只切换地址，不切换登录方式。要改用 ChatGPT 账号登录，需在 Codex 里退出当前登录再重新选择。

### 刷新模型清单（选项 3）

用 API Key 登录时，Codex 不会自动从自定义地址拉取模型列表，只显示内置列表或 `model_catalog_json` 指定的清单文件。地址那边上了新模型，Codex 里就看不到。

选 3 后脚本会：

1. 读取 `auth.json` 里的 API Key（只用于这次请求，不显示、不写入）
2. 用本机 Codex 的版本号请求 `{URL}/models?client_version=…`，拿到 Codex 格式的模型清单
3. 存成 `~/.codex/model-catalogs/url-models-时间.json`（旧清单保留）
4. 把 `config.toml` 的 `model_catalog_json` 指向新文件（同样先备份、验语法）
5. 列出新增 / 移除的模型

然后 Cmd+Q 重启 Codex 即可，**不需要退出登录**。清单没变化时不改任何文件。

要求：自定义地址已开启、当前为 API Key 登录、地址支持 Codex 格式的 `/models` 接口。

首次双击如果被 Gatekeeper 拦下，在「系统设置 → 隐私与安全性」里点「仍要打开」。

### 输入可以很随便

以下几种写法效果一样，缺的部分会自动补：

```
192.168.1.100:3333
http://192.168.1.100:3333
http://192.168.1.100:3333/v1
"http://192.168.1.100:3333/v1/"
```

多余的引号、空格、结尾斜杠都会被清掉。

### 每次它都会做这些

| 步骤 | 说明 |
|---|---|
| 备份 | 存成 `~/.codex/config.vN.toml`，N 自动递增，不会覆盖旧的 |
| 验语法 | 写入前用 Python `tomllib` 解析新旧两版，确认除地址外其他配置完全一致，否则放弃修改 |
| 写入 | 先写临时文件再整体替换；期间若配置被其他程序改动则停止 |
| 连通测试 | 请求 `{URL}/models`，HTTP 200/401/403 都算服务在跑 |

直接回车、或者填的跟当前一样，都不会动文件。

**改完记得在 Codex 里按 Cmd+Q 完全退出再打开**，关窗口不生效。

## 图标（可选）

想让它在桌面上好认，双击 `设置图标.command`。

需要 pyobjc（`pip3 install pyobjc-framework-Cocoa`）。不想装的话手动贴也行：

1. 用「预览」打开 `assets/icon.png`，Cmd+A 全选，Cmd+C 拷贝
2. 选中 `Codex地址.command`，Cmd+I 打开简介
3. 点左上角那个小图标，Cmd+V 粘贴

> 图标存在文件的扩展属性里（`com.apple.ResourceFork` + `com.apple.FinderInfo`）。
> 之后改脚本请**原地改**（用编辑器或 `sed -i ''`）。删了重建、或者从别处覆盖过去，图标会丢。

## 环境要求

- macOS
- Python 3.11+（需要自带的 `tomllib` 验语法；找不到时脚本直接退出，不做任何修改）
- `curl`（系统自带）

## 免责

脚本会改你的 `~/.codex/config.toml`。每次都会先备份，但请自行确认备份存在。
作者不对任何数据丢失负责。

## License

PolyForm Noncommercial 1.0.0 —— 见 [LICENSE](LICENSE)

**可以**：自己用、改、学习、非商业地分享。
**需要事先取得作者书面同意**：任何商业用途（含内部商用、打包进付费产品、作为收费服务的一部分）。
