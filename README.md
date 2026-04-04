# sing-box-rules

自用 sing-box / mihomo 代理规则集，多源合并、自动去重、每日构建。

## 特性

- **多源合并** - 每个规则集合并 2-5 个上游源，减少分流遗漏
- **智能去重** - 子域名被 suffix 覆盖时自动移除冗余条目
- **双格式输出** - sing-box (`.json` + `.srs` v3) 和 mihomo (`.list` + `.mrs`)
- **每日构建** - GitHub Actions 每日 06:30 (UTC+8) 自动更新
- **自定义规则** - 支持通过 `custom/add/` 和 `custom/remove/` 追加或排除条目

## 自用规则列表

> 不带 `-ip` 的规则集只含域名规则，`-ip` 后缀的只含 IP 规则。上游源中混合的 IP 规则会自动分离到对应的 `-ip` 规则集。

| 规则集 | 说明 | 源数 |
|--------|------|:----:|
| `ai` | AI 服务 (OpenAI/Claude/Gemini 等) | 4 |
| `apple-domain` | Apple 服务域名 | 2 |
| `apple-ip` | Apple 服务 IP | 1+ |
| `google-domain` | Google 服务域名 | 2 |
| `google-ip` | Google 服务 IP | 1+ |
| `google-cn` | Google 国内可直连 | 1 |
| `youtube` | YouTube 域名 | 2 |
| `youtube-ip` | YouTube IP (自动分离) | — |
| `twitter` | Twitter / X 域名 | 2 |
| `twitter-ip` | Twitter / X IP (自动分离) | — |
| `telegram` | Telegram 域名 | 1 |
| `telegram-ip` | Telegram IP | 1 |
| `tiktok` | TikTok | 3 |
| `github` | GitHub | 2 |
| `microsoft` | Microsoft 服务 | 2 |
| `onedrive` | OneDrive | 2 |
| `bahamut` | 巴哈姆特动画疯 | 2 |
| `steam` | Steam 国际 | 2 |
| `steam-cn` | Steam 国区 | 2 |
| `pixiv` | Pixiv | 1 |
| `ehentai` | E-Hentai | 1 |
| `emby` | Emby 媒体服务域名 | 1 |
| `emby-ip` | Emby IP (自动分离) | — |
| `proxy` | 代理兜底域名 (geolocation-!cn) | 4 |
| `proxy-ip` | 代理兜底 IP (自动分离) | — |
| `pcdn` | PCDN 屏蔽 (斗鱼/B站/爱奇艺等) | 自定义 |
| `geosite-cn` | 中国域名直连 | 2 |
| `geoip-cn` | 中国 IP 直连 | 2 |

## 使用方式

规则集文件发布在 [`ruleset`](https://github.com/lingqiqi5211/sing-box-rules/tree/ruleset) 分支。

### 引用地址

| 格式 | URL |
|------|-----|
| sing-box Binary (.srs) | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/singbox/{name}.srs` |
| sing-box JSON (.json) | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/singbox/{name}.json` |
| mihomo Classical (.list) | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/meta/{name}.list` |
| mihomo Domain (.mrs) | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/meta/domain/{name}.mrs` |
| mihomo IP (.mrs) | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/meta/ipcidr/{name}.mrs` |

> GitHub 加速镜像：`https://ghfast.top/` 前缀拼接上述 URL

详细配置示例参见 [docs/USAGE.md](docs/USAGE.md)。

## 文件结构

```
ruleset/                    # 构建输出 (ruleset 分支)
├── singbox/
│   ├── {name}.json         # sing-box JSON 规则集
│   └── {name}.srs          # sing-box 二进制规则集 (v3)
└── meta/
    ├── {name}.list          # mihomo classical 文本
    ├── domain/{name}.mrs    # mihomo domain 二进制
    └── ipcidr/{name}.mrs    # mihomo ipcidr 二进制
```

## 本地构建

```bash
# 依赖: bash, curl, git, python3, jq
# sing-box 和 mihomo 会自动下载

chmod +x scripts/build.sh scripts/utils.sh
bash scripts/build.sh

# 输出在 output/ 目录
```

## 数据源

| 项目 | 用途 |
|------|------|
| [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) | 主力规则源 |
| [blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script) | 第二规则源 |
| [ConnersHua/RuleGo](https://github.com/ConnersHua/RuleGo) | AI 规则补充 |
| [SukkaW/Surge](https://github.com/SukkaW/Surge) | AI + Proxy 补充 |
| [ACL4SSR/ACL4SSR](https://github.com/ACL4SSR/ACL4SSR) | AI 规则补充 |
| [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) | Proxy 兜底补充 |
| [felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list) | 中国域名 |
| [NobyDa/geoip](https://github.com/NobyDa/geoip) | 中国 IP |
| [jmdugan/blocklists](https://github.com/jmdugan/blocklists) | TikTok 补充 |
| [Repcz/Tool](https://github.com/Repcz/Tool) | Emby 规则 |

## License

[MIT](LICENSE)
