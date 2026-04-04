# 使用说明

## sing-box 配置示例

### 远程规则集

```jsonc
{
  "route": {
    "rule_set": [
      {
        "type": "remote",
        "tag": "ai",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/singbox/ai.srs",
        "download_detour": "direct",
        "update_interval": "24h0m0s"
      },
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/singbox/geoip-cn.srs",
        "download_detour": "direct",
        "update_interval": "24h0m0s"
      }
    ],
    "rules": [
      { "rule_set": "ai", "outbound": "proxy" },
      { "rule_set": "geoip-cn", "outbound": "direct" }
    ]
  }
}
```

### GitHub 加速

国内访问 GitHub raw 可能不稳定，可使用加速镜像：

```
https://ghfast.top/https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/singbox/ai.srs
```

## mihomo / Clash.Meta 配置示例

### Classical 文本规则 (.list)

```yaml
rule-providers:
  ai:
    type: http
    behavior: classical
    url: "https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/meta/ai.list"
    interval: 86400
    path: ./ruleset/ai.list

rules:
  - RULE-SET,ai,PROXY
```

### Domain 二进制规则 (.mrs)

```yaml
rule-providers:
  ai-domain:
    type: http
    behavior: domain
    url: "https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/meta/domain/ai.mrs"
    interval: 86400
    path: ./ruleset/ai-domain.mrs

  geoip-cn:
    type: http
    behavior: ipcidr
    url: "https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/meta/ipcidr/geoip-cn.mrs"
    interval: 86400
    path: ./ruleset/geoip-cn.mrs
```

> `.mrs` 二进制格式相比 `.list` 文本格式体积更小、加载更快，推荐硬路由等性能受限设备使用。
> domain 和 ipcidr 类型的 `.mrs` 规则在 mihomo 中有更好的匹配性能优化。

## 自定义规则

在 `custom/add/{规则名}.list` 中添加需要追加的条目，在 `custom/remove/{规则名}.list` 中添加需要排除的条目。

格式为 Surge classical：

```
DOMAIN,example.com
DOMAIN-SUFFIX,example.com
IP-CIDR,1.2.3.0/24,no-resolve
IP-CIDR6,2001:db8::/32,no-resolve
```

示例：追加一个域名到 AI 规则集

```bash
echo "DOMAIN-SUFFIX,my-ai-service.com" > custom/add/ai.list
```

示例：从 proxy 规则集中排除某域名

```bash
echo "DOMAIN,do-not-proxy.example.com" > custom/remove/proxy.list
```

## 完整 URL 格式

将 `{name}` 替换为规则列表中的规则集名称（如 `ai`、`geoip-cn`、`proxy` 等）。

| 格式 | URL |
|------|-----|
| sing-box JSON | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/singbox/{name}.json` |
| sing-box Binary | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/singbox/{name}.srs` |
| mihomo Classical | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/meta/{name}.list` |
| mihomo Domain Binary | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/meta/domain/{name}.mrs` |
| mihomo IP Binary | `https://raw.githubusercontent.com/lingqiqi5211/sing-box-rules/ruleset/meta/ipcidr/{name}.mrs` |

## 本地构建

### 依赖

- bash
- curl
- git
- python3
- jq

sing-box 和 mihomo 二进制文件会在构建时自动下载到 `bin/` 目录。

### 运行

```bash
chmod +x scripts/build.sh scripts/utils.sh
bash scripts/build.sh
```

构建输出在 `output/` 目录，结构与 `ruleset` 分支一致。

### 构建流程

1. **prepare** - 创建输出目录
2. **download_tools** - 下载 sing-box 和 mihomo 二进制
3. **download_upstream** - 拉取所有上游规则源
4. **merge_rules** - 合并、去重、拆分域名/IP
5. **compile_rules** - 编译为 `.srs` / `.mrs` 二进制
6. **generate_stats** - 生成规则统计信息
7. **cleanup** - 清理临时文件
