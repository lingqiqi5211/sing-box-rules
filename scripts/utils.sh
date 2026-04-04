#!/bin/bash
# utils.sh - 规则处理工具函数
# 所有函数处理的中间格式为 Surge classical 格式:
#   DOMAIN,example.com
#   DOMAIN-SUFFIX,example.com
#   DOMAIN-KEYWORD,example
#   DOMAIN-REGEX,^example\.com$
#   DOMAIN-WILDCARD,*.example.com
#   IP-CIDR,1.2.3.0/24,no-resolve
#   IP-CIDR6,2001:db8::/32,no-resolve
#   PROCESS-NAME,example.exe

set -euo pipefail

# ============================================================================
# 文本清理
# ============================================================================

# 清理规则文本: 去除注释、空行、BOM、多余空白、Windows 换行符
# 用法: clean_list < input > output
clean_list() {
    sed 's/\xEF\xBB\xBF//g' | \
    sed 's/\r$//' | \
    sed 's/[[:space:]]*$//' | \
    grep -vE '^\s*$|^\s*#|^\s*;|^\s*//' | \
    sed 's/^[[:space:]]*//'
}

# ============================================================================
# 格式转换函数
# 将各种上游格式转换为统一的 Surge classical 格式
# ============================================================================

# 规范化 Surge/Clash classical 格式
# 处理: 去除注释、统一格式、去掉末尾逗号后的策略名
# 用法: normalize_surge < input > output
normalize_surge() {
    clean_list | \
    awk -F',' '{
        # 去掉可能存在的策略名 (第三个字段，非 no-resolve)
        type = $1
        value = $2
        extra = $3

        # 跳过无效行
        if (type == "" || value == "") next

        # 保留 no-resolve
        if (extra == "no-resolve") {
            print type "," value ",no-resolve"
        } else if (type ~ /^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-REGEX|DOMAIN-WILDCARD|PROCESS-NAME)$/) {
            print type "," value
        } else if (type ~ /^(IP-CIDR|IP-CIDR6)$/) {
            print type "," value ",no-resolve"
        } else {
            # 原样输出未识别的格式
            print $0
        }
    }'
}

# 转换 SukkaW Surge conf 格式
# 格式基本与 Surge classical 一致，需去除 skk.moe 内部注释和标记行
# 用法: convert_sukka < input > output
convert_sukka() {
    clean_list | \
    grep -v '\.skk\.moe' | \
    grep -v '^MANAGED-URL' | \
    grep -v '^POLICY-GROUP' | \
    normalize_surge
}

# 转换 Clash classical 格式 (ACL4SSR 等)
# 格式与 Surge classical 几乎相同
# 用法: convert_clash < input > output
convert_clash() {
    normalize_surge
}

# 转换 dnsmasq 格式 (felixonmars)
# 输入: server=/domain/114.114.114.114
# 输出: DOMAIN-SUFFIX,domain
# 用法: convert_dnsmasq < input > output
convert_dnsmasq() {
    clean_list | \
    grep '^server=/' | \
    awk -F'/' '{print "DOMAIN-SUFFIX," $2}'
}

# 转换 Loyalsoldier v2ray proxy-list 格式
# 输入: full:domain 或 regexp:pattern 或 bare-domain (作为 suffix)
# 用法: convert_v2ray_list < input > output
convert_v2ray_list() {
    clean_list | \
    python3 -c '
import sys, re

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line.startswith("full:"):
        print("DOMAIN," + line[5:])
    elif line.startswith("regexp:"):
        pattern = line[7:]
        try:
            re.compile(pattern)
            print("DOMAIN-REGEX," + pattern)
        except re.error:
            print(f"[WARN] 跳过无效正则: {pattern}", file=sys.stderr)
    else:
        print("DOMAIN-SUFFIX," + line)
'
}

# 转换 hosts 格式 (jmdugan blocklists 等)
# 输入: 0.0.0.0 domain 或 127.0.0.1 domain 或纯域名
# 用法: convert_hosts < input > output
convert_hosts() {
    clean_list | \
    awk '{
        if ($0 ~ /^(0\.0\.0\.0|127\.0\.0\.1)[[:space:]]/) {
            domain = $2
            if (domain != "" && domain != "localhost") {
                print "DOMAIN-SUFFIX," domain
            }
        } else if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^#/) {
            # 纯域名行
            print "DOMAIN-SUFFIX," $0
        }
    }'
}

# 转换纯 IP/CIDR 列表格式 (NobyDa/geoip 等)
# 输入: 每行一个 IP 或 CIDR
# 用法: convert_iplist < input > output
convert_iplist() {
    clean_list | \
    awk '{
        ip = $1
        if (ip == "") next
        if (ip ~ /:/) {
            # IPv6
            print "IP-CIDR6," ip ",no-resolve"
        } else {
            # IPv4
            print "IP-CIDR," ip ",no-resolve"
        }
    }'
}

# 转换 sing-box rule-set JSON 为 Surge classical 格式
# 支持 v1/v2/v3 格式
# 用法: convert_singbox_json < input.json > output
convert_singbox_json() {
    python3 -c '
import json, sys

data = json.load(sys.stdin)
rules = data.get("rules", [])

for rule in rules:
    for domain in rule.get("domain", []):
        print(f"DOMAIN,{domain}")
    for suffix in rule.get("domain_suffix", []):
        print(f"DOMAIN-SUFFIX,{suffix}")
    for keyword in rule.get("domain_keyword", []):
        print(f"DOMAIN-KEYWORD,{keyword}")
    for regex in rule.get("domain_regex", []):
        print(f"DOMAIN-REGEX,{regex}")
    for cidr in rule.get("ip_cidr", []):
        if ":" in cidr:
            print(f"IP-CIDR6,{cidr},no-resolve")
        else:
            print(f"IP-CIDR,{cidr},no-resolve")
    for proc in rule.get("process_name", []):
        print(f"PROCESS-NAME,{proc}")
'
}

# ============================================================================
# 规则处理函数
# ============================================================================

# 域名去重: 移除已被 DOMAIN-SUFFIX 覆盖的子域名
# - DOMAIN 被同一 suffix 覆盖时移除
# - 更具体的 DOMAIN-SUFFIX 被更宽泛的 DOMAIN-SUFFIX 覆盖时移除
# - DOMAIN-WILDCARD 被 DOMAIN-SUFFIX 覆盖时移除
# 用法: domain_dedupe < input > output
domain_dedupe() {
    python3 -c '
import sys
from collections import defaultdict

lines = []
suffixes = set()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split(",", 2)
    rule_type = parts[0]
    value = parts[1] if len(parts) > 1 else ""
    extra = parts[2] if len(parts) > 2 else ""

    lines.append((rule_type, value, extra, line))
    if rule_type == "DOMAIN-SUFFIX":
        suffixes.add(value.lower())

seen = set()
output = []

for rule_type, value, extra, original in lines:
    val_lower = value.lower()

    # 检查是否已输出完全相同的行
    if original in seen:
        continue

    if rule_type == "DOMAIN":
        # 检查是否被某个 suffix 覆盖
        parts = val_lower.split(".")
        covered = False
        for i in range(len(parts)):
            candidate = ".".join(parts[i:])
            if candidate in suffixes:
                covered = True
                break
        if covered:
            continue

    elif rule_type == "DOMAIN-SUFFIX":
        # 检查是否被更宽泛的 suffix 覆盖
        parts = val_lower.split(".")
        covered = False
        for i in range(1, len(parts)):
            candidate = ".".join(parts[i:])
            if candidate in suffixes:
                covered = True
                break
        if covered:
            continue

    elif rule_type == "DOMAIN-WILDCARD":
        # *.example.com 被 DOMAIN-SUFFIX,example.com 覆盖
        if val_lower.startswith("*."):
            base = val_lower[2:]
            if base in suffixes:
                continue

    seen.add(original)
    output.append(original)

for line in output:
    print(line)
'
}

# 按规则类型排序
# 排序顺序: DOMAIN > DOMAIN-SUFFIX > DOMAIN-KEYWORD > DOMAIN-WILDCARD >
#           DOMAIN-REGEX > IP-CIDR > IP-CIDR6 > PROCESS-NAME
# 同类型内按值字母排序
# 用法: ruleset_sort < input > output
ruleset_sort() {
    awk -F',' '{
        type = $1
        if      (type == "DOMAIN")          order = 1
        else if (type == "DOMAIN-SUFFIX")   order = 2
        else if (type == "DOMAIN-KEYWORD")  order = 3
        else if (type == "DOMAIN-WILDCARD") order = 4
        else if (type == "DOMAIN-REGEX")    order = 5
        else if (type == "IP-CIDR")         order = 6
        else if (type == "IP-CIDR6")        order = 7
        else if (type == "PROCESS-NAME")    order = 8
        else                                order = 9
        print order "\t" $0
    }' | sort -t$'\t' -k1,1n -k2,2 | cut -f2-
}

# 去除完全重复的行 (保留顺序)
# 用法: dedup_lines < input > output
dedup_lines() {
    awk '!seen[$0]++'
}

# ============================================================================
# 输出转换函数
# ============================================================================

# 拆分规则文件为 domain 和 ipcidr 两部分 (classical 格式，用于 meta .list)
# 用法: split_domain_ipcidr input.list domain_output.list ipcidr_output.list
split_domain_ipcidr() {
    local input="$1"
    local domain_out="$2"
    local ipcidr_out="$3"

    grep -E '^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-WILDCARD|DOMAIN-REGEX),' "$input" > "$domain_out" 2>/dev/null || true
    grep -E '^(IP-CIDR|IP-CIDR6),' "$input" > "$ipcidr_out" 2>/dev/null || true
}

# 将 classical domain 规则转换为 mihomo domain 纯文本格式 (用于 convert-ruleset)
# DOMAIN,x         -> x       (精确匹配，无前缀)
# DOMAIN-SUFFIX,x  -> +.x     (后缀匹配)
# DOMAIN-KEYWORD,x -> (跳过，domain 类型不支持)
# 用法: classical_to_mihomo_domain < input > output
classical_to_mihomo_domain() {
    awk -F',' '{
        if ($1 == "DOMAIN") {
            print $2
        } else if ($1 == "DOMAIN-SUFFIX") {
            print "+." $2
        }
    }'
}

# 将 classical ipcidr 规则转换为 mihomo ipcidr 纯文本格式 (用于 convert-ruleset)
# IP-CIDR,x,no-resolve  -> x
# IP-CIDR6,x,no-resolve -> x
# 用法: classical_to_mihomo_ipcidr < input > output
classical_to_mihomo_ipcidr() {
    awk -F',' '{
        if ($1 == "IP-CIDR" || $1 == "IP-CIDR6") {
            print $2
        }
    }'
}

# 将 Surge classical 格式转换为 sing-box rule-set JSON (version 3)
# 用法: to_singbox_json < input.list > output.json
to_singbox_json() {
    python3 -c '
import json, sys

rules = {
    "domain": [],
    "domain_suffix": [],
    "domain_keyword": [],
    "domain_regex": [],
    "ip_cidr": [],
    "process_name": []
}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split(",", 2)
    rule_type = parts[0]
    value = parts[1] if len(parts) > 1 else ""

    if rule_type == "DOMAIN":
        rules["domain"].append(value)
    elif rule_type == "DOMAIN-SUFFIX":
        rules["domain_suffix"].append(value)
    elif rule_type == "DOMAIN-KEYWORD":
        rules["domain_keyword"].append(value)
    elif rule_type in ("DOMAIN-REGEX", "DOMAIN-WILDCARD"):
        import re
        # DOMAIN-WILDCARD 转换为正则
        if rule_type == "DOMAIN-WILDCARD":
            # *.example.com -> (\.|^)example\.com$
            pattern = value.replace(".", r"\.")
            pattern = pattern.replace(r"\*\.", r"(\.|^)")
            pattern = pattern.replace("*", ".*")
        else:
            pattern = value
        # 校验正则语法
        try:
            re.compile(pattern)
            rules["domain_regex"].append(pattern)
        except re.error:
            print(f"[WARN] 跳过无效正则: {pattern}", file=sys.stderr)
    elif rule_type in ("IP-CIDR", "IP-CIDR6"):
        rules["ip_cidr"].append(value)
    elif rule_type == "PROCESS-NAME":
        rules["process_name"].append(value)

# 构建 sing-box rule-set v3 格式
rule_obj = {}
for key, values in rules.items():
    if values:
        rule_obj[key] = sorted(set(values))

output = {
    "version": 3,
    "rules": [rule_obj] if rule_obj else []
}

print(json.dumps(output, indent=2, ensure_ascii=False))
'
}

# ============================================================================
# 辅助函数
# ============================================================================

# 应用自定义规则: 合并 custom/add 并排除 custom/remove
# 用法: apply_custom RULE_NAME < input > output
apply_custom() {
    local rule_name="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_dir="$(dirname "$script_dir")"
    local add_file="$project_dir/custom/add/${rule_name}.list"
    local remove_file="$project_dir/custom/remove/${rule_name}.list"

    local tmp_input
    tmp_input=$(mktemp)
    cat > "$tmp_input"

    # 追加自定义规则
    if [[ -f "$add_file" ]]; then
        cat "$add_file" | clean_list >> "$tmp_input"
    fi

    # 排除自定义规则
    if [[ -f "$remove_file" ]]; then
        grep -vxF -f "$remove_file" "$tmp_input" || true
    else
        cat "$tmp_input"
    fi

    rm -f "$tmp_input"
}

# 日志输出
log_info() {
    echo "[INFO] $(date '+%H:%M:%S') $*"
}

log_warn() {
    echo "[WARN] $(date '+%H:%M:%S') $*" >&2
}

log_error() {
    echo "[ERROR] $(date '+%H:%M:%S') $*" >&2
}
