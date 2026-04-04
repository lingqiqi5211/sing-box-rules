#!/bin/bash
# build.sh - 主构建脚本
# 用法: bash scripts/build.sh
# 环境要求: bash, curl, git, python3, jq, sing-box, mihomo (后两者可自动下载)
#
# 构建流程:
#   1. 准备工作目录和工具
#   2. 下载上游规则源 (git sparse-checkout + curl)
#   3. 按类别合并多源规则
#   4. 去重、排序
#   5. 生成 meta .list / sing-box .json+.srs / mihomo .mrs

set -euo pipefail

# ============================================================================
# 路径和变量
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCES_CONF="$SCRIPT_DIR/sources.conf"

# 工作目录
TMP_DIR="$PROJECT_DIR/tmp"
UPSTREAM_DIR="$PROJECT_DIR/upstream"
OUTPUT_DIR="$PROJECT_DIR/output"

# 上游 git 仓库本地路径
META_RULES_DIR="$UPSTREAM_DIR/meta-rules-dat"
BM7_RULES_DIR="$UPSTREAM_DIR/ios_rule_script"

# 输出子目录
SINGBOX_OUT="$OUTPUT_DIR/singbox"
META_OUT="$OUTPUT_DIR/meta"
META_DOMAIN_OUT="$META_OUT/domain"
META_IPCIDR_OUT="$META_OUT/ipcidr"

# sing-box / mihomo 版本 (GitHub Actions 中可通过环境变量覆盖)
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.0}"
MIHOMO_VERSION="${MIHOMO_VERSION:-latest}"

# 加载工具函数
source "$SCRIPT_DIR/utils.sh"

# ============================================================================
# 准备工作
# ============================================================================

prepare() {
    log_info "=== 准备工作目录 ==="

    rm -rf "$TMP_DIR" "$OUTPUT_DIR"
    mkdir -p "$TMP_DIR" "$UPSTREAM_DIR"
    mkdir -p "$SINGBOX_OUT" "$META_OUT" "$META_DOMAIN_OUT" "$META_IPCIDR_OUT"

    # 检查必要工具
    for cmd in curl git python3 jq; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "缺少必要工具: $cmd"
            exit 1
        fi
    done
}

# ============================================================================
# 下载工具二进制
# ============================================================================

download_tools() {
    log_info "=== 下载构建工具 ==="

    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"

    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
    esac

    # 下载 sing-box
    if ! command -v sing-box &>/dev/null; then
        log_info "下载 sing-box v${SINGBOX_VERSION}..."
        local sb_url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-${os}-${arch}.tar.gz"
        curl -sSL "$sb_url" | tar xz -C "$TMP_DIR"
        SINGBOX_BIN="$TMP_DIR/sing-box-${SINGBOX_VERSION}-${os}-${arch}/sing-box"
        chmod +x "$SINGBOX_BIN"
    else
        SINGBOX_BIN="sing-box"
    fi
    log_info "sing-box: $($SINGBOX_BIN version 2>/dev/null | head -1 || echo 'ready')"

    # 下载 mihomo
    if ! command -v mihomo &>/dev/null; then
        log_info "下载 mihomo..."
        local mi_url
        if [[ "$MIHOMO_VERSION" == "latest" ]]; then
            # Prerelease-Alpha 的文件名包含动态版本号，需先获取
            local mi_ver
            mi_ver="$(curl -sSL https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/version.txt)" || {
                log_error "获取 mihomo 版本失败"
                exit 1
            }
            mi_ver="$(echo "$mi_ver" | tr -d '[:space:]')"
            log_info "mihomo 版本: $mi_ver"
            mi_url="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/mihomo-${os}-${arch}-${mi_ver}.gz"
        else
            mi_url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-${os}-${arch}.gz"
        fi
        curl -sSL "$mi_url" | gunzip > "$TMP_DIR/mihomo"
        chmod +x "$TMP_DIR/mihomo"
        MIHOMO_BIN="$TMP_DIR/mihomo"
    else
        MIHOMO_BIN="mihomo"
    fi
    log_info "mihomo: $($MIHOMO_BIN -v 2>/dev/null | head -1 || echo 'ready')"
}

# ============================================================================
# 下载上游源
# ============================================================================

download_upstream() {
    log_info "=== 下载上游规则源 ==="

    # --- Git sparse-checkout: MetaCubeX/meta-rules-dat ---
    log_info "下载 MetaCubeX/meta-rules-dat..."
    if [[ -d "$META_RULES_DIR" ]]; then
        rm -rf "$META_RULES_DIR"
    fi
    git clone --depth=1 --filter=blob:none --sparse \
        -b meta \
        https://github.com/MetaCubeX/meta-rules-dat.git \
        "$META_RULES_DIR" 2>/dev/null

    (
        cd "$META_RULES_DIR"
        git sparse-checkout set \
            geo-lite/geosite/classical \
            geo-lite/geoip/classical \
            geo/geosite/classical \
            geo/geoip/classical
    )
    log_info "MetaCubeX 规则下载完成"

    # --- Git sparse-checkout: blackmatrix7/ios_rule_script ---
    log_info "下载 blackmatrix7/ios_rule_script..."
    if [[ -d "$BM7_RULES_DIR" ]]; then
        rm -rf "$BM7_RULES_DIR"
    fi
    git clone --depth=1 --filter=blob:none --sparse \
        -b master \
        https://github.com/blackmatrix7/ios_rule_script.git \
        "$BM7_RULES_DIR" 2>/dev/null

    (
        cd "$BM7_RULES_DIR"
        git sparse-checkout set rule/Surge
    )
    log_info "blackmatrix7 规则下载完成"

    # --- Curl 下载零散源 ---
    log_info "下载零散上游源..."
    local curl_dir="$UPSTREAM_DIR/curl"
    mkdir -p "$curl_dir"

    # 从 sources.conf 中提取需要 curl 下载的 URL
    while IFS='|' read -r rule_name source_type url; do
        # 跳过注释和空行
        [[ "$rule_name" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$rule_name" ]] && continue

        case "$source_type" in
            curl-surge|curl-sukka|curl-clash|curl-v2ray|curl-dnsmasq|curl-hosts|curl-iplist|curl-singbox-json)
                local filename="${rule_name}__$(echo "$source_type" | sed 's/curl-//')__$(echo "$url" | md5sum | cut -c1-8)"
                local outfile="$curl_dir/${filename}"
                if [[ ! -f "$outfile" ]]; then
                    log_info "  下载 ${rule_name} (${source_type}): $(basename "$url")"
                    curl -sSL --retry 3 --max-time 30 "$url" -o "$outfile" || {
                        log_warn "  下载失败: $url"
                        continue
                    }
                fi
                ;;
        esac
    done < "$SOURCES_CONF"

    log_info "所有上游源下载完成"
}

# ============================================================================
# 获取单个源的规则内容 (已转换为 classical 格式)
# ============================================================================

get_source_content() {
    local rule_name="$1"
    local source_type="$2"
    local source_ref="$3"   # 文件路径或 URL

    case "$source_type" in
        meta-geosite)
            local file="$META_RULES_DIR/geo-lite/geosite/classical/${source_ref}.list"
            if [[ -f "$file" ]]; then
                normalize_surge < "$file"
            else
                log_warn "文件不存在: $file"
            fi
            ;;
        meta-geosite-full)
            local file="$META_RULES_DIR/geo/geosite/classical/${source_ref}.list"
            if [[ -f "$file" ]]; then
                normalize_surge < "$file"
            else
                log_warn "文件不存在: $file"
            fi
            ;;
        meta-geoip)
            local file="$META_RULES_DIR/geo-lite/geoip/classical/${source_ref}.list"
            if [[ -f "$file" ]]; then
                normalize_surge < "$file"
            else
                log_warn "文件不存在: $file"
            fi
            ;;
        meta-geoip-full)
            local file="$META_RULES_DIR/geo/geoip/classical/${source_ref}.list"
            if [[ -f "$file" ]]; then
                normalize_surge < "$file"
            else
                log_warn "文件不存在: $file"
            fi
            ;;
        surge)
            local file="$BM7_RULES_DIR/rule/Surge/${source_ref}.list"
            if [[ -f "$file" ]]; then
                normalize_surge < "$file"
            else
                log_warn "文件不存在: $file"
            fi
            ;;
        curl-surge)
            local filename="${rule_name}__surge__$(echo "$source_ref" | md5sum | cut -c1-8)"
            local file="$UPSTREAM_DIR/curl/${filename}"
            if [[ -f "$file" ]]; then
                normalize_surge < "$file"
            fi
            ;;
        curl-sukka)
            local filename="${rule_name}__sukka__$(echo "$source_ref" | md5sum | cut -c1-8)"
            local file="$UPSTREAM_DIR/curl/${filename}"
            if [[ -f "$file" ]]; then
                convert_sukka < "$file"
            fi
            ;;
        curl-clash)
            local filename="${rule_name}__clash__$(echo "$source_ref" | md5sum | cut -c1-8)"
            local file="$UPSTREAM_DIR/curl/${filename}"
            if [[ -f "$file" ]]; then
                convert_clash < "$file"
            fi
            ;;
        curl-v2ray)
            local filename="${rule_name}__v2ray__$(echo "$source_ref" | md5sum | cut -c1-8)"
            local file="$UPSTREAM_DIR/curl/${filename}"
            if [[ -f "$file" ]]; then
                convert_v2ray_list < "$file"
            fi
            ;;
        curl-dnsmasq)
            local filename="${rule_name}__dnsmasq__$(echo "$source_ref" | md5sum | cut -c1-8)"
            local file="$UPSTREAM_DIR/curl/${filename}"
            if [[ -f "$file" ]]; then
                convert_dnsmasq < "$file"
            fi
            ;;
        curl-hosts)
            local filename="${rule_name}__hosts__$(echo "$source_ref" | md5sum | cut -c1-8)"
            local file="$UPSTREAM_DIR/curl/${filename}"
            if [[ -f "$file" ]]; then
                convert_hosts < "$file"
            fi
            ;;
        curl-iplist)
            local filename="${rule_name}__iplist__$(echo "$source_ref" | md5sum | cut -c1-8)"
            local file="$UPSTREAM_DIR/curl/${filename}"
            if [[ -f "$file" ]]; then
                convert_iplist < "$file"
            fi
            ;;
        curl-singbox-json)
            local filename="${rule_name}__singbox-json__$(echo "$source_ref" | md5sum | cut -c1-8)"
            local file="$UPSTREAM_DIR/curl/${filename}"
            if [[ -f "$file" ]]; then
                convert_singbox_json < "$file"
            fi
            ;;
        *)
            log_warn "未知源类型: $source_type"
            ;;
    esac
}

# ============================================================================
# 合并规则
# ============================================================================

merge_rules() {
    log_info "=== 合并规则 ==="

    # 收集所有规则名称
    local rule_names=()
    while IFS='|' read -r rule_name source_type url; do
        [[ "$rule_name" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$rule_name" ]] && continue

        # 去重规则名
        local found=0
        for existing in "${rule_names[@]:-}"; do
            if [[ "$existing" == "$rule_name" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            rule_names+=("$rule_name")
        fi
    done < "$SOURCES_CONF"

    # 扫描 custom/add/ 中的自定义规则集 (可能没有上游源)
    local custom_add_dir="$PROJECT_DIR/custom/add"
    if [[ -d "$custom_add_dir" ]]; then
        for custom_file in "$custom_add_dir"/*.list; do
            [[ ! -f "$custom_file" ]] && continue
            local cname
            cname="$(basename "$custom_file" .list)"
            local found=0
            for existing in "${rule_names[@]:-}"; do
                if [[ "$existing" == "$cname" ]]; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                rule_names+=("$cname")
            fi
        done
    fi

    # IP 暂存目录 (非 -ip 规则集中分离出的 IP 规则)
    local ip_staging_dir="$TMP_DIR/ip_staging"
    mkdir -p "$ip_staging_dir"

    # ---------------------------------------------------------------
    # 辅助函数: 确定 IP 规则的目标规则集名称
    #   apple-domain -> apple-ip
    #   google-domain -> google-ip
    #   其他 -> {name}-ip
    # ---------------------------------------------------------------
    _get_ip_target_name() {
        local name="$1"
        if [[ "$name" == *-domain ]]; then
            echo "${name%-domain}-ip"
        else
            echo "${name}-ip"
        fi
    }

    # ---------------------------------------------------------------
    # 辅助函数: 输出一个规则集的所有文件 (meta .list, singbox .json, 拆分 domain/ipcidr)
    # ---------------------------------------------------------------
    _output_ruleset() {
        local rname="$1"
        local src_file="$2"

        # --- 输出 meta .list ---
        cp "$src_file" "$META_OUT/${rname}.list"

        # --- 拆分 domain / ipcidr (用于 mihomo .mrs) ---
        split_domain_ipcidr "$src_file" \
            "$META_DOMAIN_OUT/${rname}.list" \
            "$META_IPCIDR_OUT/${rname}.list"

        # 清理空文件
        [[ ! -s "$META_DOMAIN_OUT/${rname}.list" ]] && rm -f "$META_DOMAIN_OUT/${rname}.list"
        [[ ! -s "$META_IPCIDR_OUT/${rname}.list" ]] && rm -f "$META_IPCIDR_OUT/${rname}.list"

        # --- 输出 sing-box JSON ---
        to_singbox_json < "$src_file" > "$SINGBOX_OUT/${rname}.json"
    }

    # ---------------------------------------------------------------
    # 第一轮: 合并各规则集，同时将非 -ip 规则集中的 IP 规则分离暂存
    # ---------------------------------------------------------------
    for rule_name in "${rule_names[@]}"; do
        log_info "处理规则集: $rule_name"

        local merged_file="$TMP_DIR/${rule_name}.merged"
        > "$merged_file"

        # 从 sources.conf 中读取该规则的所有源并合并
        local source_count=0
        while IFS='|' read -r rn st url; do
            [[ "$rn" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$rn" ]] && continue
            [[ "$rn" != "$rule_name" ]] && continue

            get_source_content "$rn" "$st" "$url" >> "$merged_file"
            source_count=$((source_count + 1))
        done < "$SOURCES_CONF"

        log_info "  合并了 $source_count 个源"

        # 应用自定义规则 (add/remove)
        local processed_file="$TMP_DIR/${rule_name}.processed"
        apply_custom "$rule_name" < "$merged_file" > "$processed_file"

        # 去重和排序
        local deduped_file="$TMP_DIR/${rule_name}.deduped"
        dedup_lines < "$processed_file" | domain_dedupe | ruleset_sort > "$deduped_file"

        # ----- IP 自动分离 -----
        # 以 -ip 结尾或以 geoip- 开头的规则集: 只保留 IP 规则
        # 其他规则集: 只保留域名规则，IP 规则自动分离到 {name}-ip
        local final_file="$TMP_DIR/${rule_name}.final"
        if [[ "$rule_name" == *-ip ]] || [[ "$rule_name" == geoip-* ]]; then
            # -ip 规则集: 只保留 IP 规则，丢弃域名规则
            grep -E '^(IP-CIDR|IP-CIDR6),' "$deduped_file" > "$final_file" 2>/dev/null || true
            local dropped
            dropped=$(grep -cE '^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-WILDCARD|DOMAIN-REGEX),' "$deduped_file" 2>/dev/null || true)
            [[ "$dropped" -gt 0 ]] 2>/dev/null && log_info "  $rule_name: 丢弃了 $dropped 条域名规则 (仅保留 IP)"
        else
            # 非 -ip 规则集: 只保留域名规则，IP 规则分离暂存
            grep -E '^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-WILDCARD|DOMAIN-REGEX),' "$deduped_file" > "$final_file" 2>/dev/null || true

            local ip_tmp="$TMP_DIR/${rule_name}.ip_split"
            grep -E '^(IP-CIDR|IP-CIDR6),' "$deduped_file" > "$ip_tmp" 2>/dev/null || true

            if [[ -s "$ip_tmp" ]]; then
                local ip_target
                ip_target="$(_get_ip_target_name "$rule_name")"
                local ip_count
                ip_count=$(wc -l < "$ip_tmp" | tr -d ' ')
                log_info "  $rule_name: 分离 $ip_count 条 IP 规则 -> $ip_target"

                # 追加到暂存文件
                cat "$ip_tmp" >> "$ip_staging_dir/${ip_target}.staged"
            fi
            rm -f "$ip_tmp"
        fi

        local line_count
        line_count=$(wc -l < "$final_file" | tr -d ' ')
        log_info "  最终规则数: $line_count"

        _output_ruleset "$rule_name" "$final_file"
    done

    # ---------------------------------------------------------------
    # 第二轮: 将暂存的 IP 规则合并到对应的 -ip 规则集
    # ---------------------------------------------------------------
    for staged_file in "$ip_staging_dir"/*.staged; do
        [[ ! -f "$staged_file" ]] && continue
        local ip_name
        ip_name="$(basename "$staged_file" .staged)"

        local staged_count
        staged_count=$(wc -l < "$staged_file" | tr -d ' ')
        log_info "合并暂存 IP 规则到 $ip_name ($staged_count 条)"

        if [[ -f "$META_OUT/${ip_name}.list" ]]; then
            # 已有 -ip 规则集，追加并重新去重
            local combined="$TMP_DIR/${ip_name}.combined"
            cat "$META_OUT/${ip_name}.list" "$staged_file" | dedup_lines | ruleset_sort > "$combined"

            local new_count
            new_count=$(wc -l < "$combined" | tr -d ' ')
            log_info "  $ip_name: 合并后 $new_count 条规则"

            _output_ruleset "$ip_name" "$combined"
        else
            # 新的 -ip 规则集 (上游没有定义，纯靠分离产生)
            local new_ip_file="$TMP_DIR/${ip_name}.final"
            dedup_lines < "$staged_file" | ruleset_sort > "$new_ip_file"

            local new_count
            new_count=$(wc -l < "$new_ip_file" | tr -d ' ')
            log_info "  新增规则集 $ip_name ($new_count 条规则)"

            _output_ruleset "$ip_name" "$new_ip_file"
        fi
    done

    rm -rf "$ip_staging_dir"
    log_info "所有规则合并完成"
}

# ============================================================================
# 编译二进制规则
# ============================================================================

compile_rules() {
    log_info "=== 编译二进制规则 ==="

    # --- 编译 sing-box .srs ---
    log_info "编译 sing-box .srs 文件..."
    for json_file in "$SINGBOX_OUT"/*.json; do
        local name
        name="$(basename "$json_file" .json)"
        local srs_file="$SINGBOX_OUT/${name}.srs"

        log_info "  编译 ${name}.srs"
        "$SINGBOX_BIN" rule-set compile --output "$srs_file" "$json_file" || {
            log_warn "  编译失败: ${name}.srs"
            continue
        }
    done

    # --- 编译 mihomo .mrs ---
    log_info "编译 mihomo .mrs 文件..."

    # domain .mrs (需要先转换为 mihomo 纯文本格式)
    for list_file in "$META_DOMAIN_OUT"/*.list; do
        [[ ! -f "$list_file" ]] && continue
        local name
        name="$(basename "$list_file" .list)"
        local mrs_file="$META_DOMAIN_OUT/${name}.mrs"
        local mihomo_txt="$TMP_DIR/${name}.domain.txt"

        # 将 classical 格式转换为 mihomo domain 文本格式
        classical_to_mihomo_domain < "$list_file" > "$mihomo_txt"

        log_info "  编译 domain/${name}.mrs"
        "$MIHOMO_BIN" convert-ruleset domain text \
            "$mihomo_txt" "$mrs_file" 2>/dev/null || {
            log_warn "  编译失败: domain/${name}.mrs"
            continue
        }
        rm -f "$mihomo_txt"
    done

    # ipcidr .mrs (需要先转换为 mihomo 纯文本格式)
    for list_file in "$META_IPCIDR_OUT"/*.list; do
        [[ ! -f "$list_file" ]] && continue
        local name
        name="$(basename "$list_file" .list)"
        local mrs_file="$META_IPCIDR_OUT/${name}.mrs"
        local mihomo_txt="$TMP_DIR/${name}.ipcidr.txt"

        # 将 classical 格式转换为 mihomo ipcidr 文本格式
        classical_to_mihomo_ipcidr < "$list_file" > "$mihomo_txt"

        log_info "  编译 ipcidr/${name}.mrs"
        "$MIHOMO_BIN" convert-ruleset ipcidr text \
            "$mihomo_txt" "$mrs_file" 2>/dev/null || {
            log_warn "  编译失败: ipcidr/${name}.mrs"
            continue
        }
        rm -f "$mihomo_txt"
    done

    log_info "所有二进制编译完成"
}

# ============================================================================
# 生成统计信息
# ============================================================================

generate_stats() {
    log_info "=== 生成统计信息 ==="

    echo "# 规则集构建统计" > "$OUTPUT_DIR/stats.md"
    echo "" >> "$OUTPUT_DIR/stats.md"
    echo "构建时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$OUTPUT_DIR/stats.md"
    echo "" >> "$OUTPUT_DIR/stats.md"
    echo "| 规则集 | 规则数 | 域名规则 | IP 规则 |" >> "$OUTPUT_DIR/stats.md"
    echo "|--------|--------|----------|---------|" >> "$OUTPUT_DIR/stats.md"

    for list_file in "$META_OUT"/*.list; do
        local name
        name="$(basename "$list_file" .list)"
        local total domain_count ip_count
        total=$(wc -l < "$list_file" | tr -d ' ')
        domain_count=$(grep -cE '^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-WILDCARD|DOMAIN-REGEX),' "$list_file" || true)
        ip_count=$(grep -cE '^(IP-CIDR|IP-CIDR6),' "$list_file" || true)
        echo "| $name | $total | $domain_count | $ip_count |" >> "$OUTPUT_DIR/stats.md"
    done

    log_info "统计信息已写入 output/stats.md"
}

# ============================================================================
# 清理
# ============================================================================

cleanup() {
    log_info "=== 清理临时文件 ==="
    rm -rf "$TMP_DIR"
    log_info "清理完成"
}

# ============================================================================
# 主流程
# ============================================================================

main() {
    log_info "=========================================="
    log_info " sing-box-rules 构建开始"
    log_info "=========================================="

    prepare
    download_tools
    download_upstream
    merge_rules
    compile_rules
    generate_stats
    cleanup

    log_info "=========================================="
    log_info " 构建完成！输出目录: $OUTPUT_DIR"
    log_info "=========================================="

    # 输出文件列表
    log_info "sing-box 规则集:"
    ls -lh "$SINGBOX_OUT"/*.srs 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'

    log_info "mihomo 规则集:"
    ls -lh "$META_OUT"/*.list 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
}

main "$@"
