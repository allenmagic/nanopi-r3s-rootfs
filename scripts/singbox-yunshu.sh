#!/bin/sh
# singbox-yunshu.sh —— 维护 sing-box 的 YunShu 分流域名规则集
#
# 源文件：/etc/sing-box/rules/yunshu-domains.txt
# 生成：  /etc/sing-box/rules/yunshu-domains.json（sing-box local source rule-set）
#
# 用法：
#   yunshu-domain list
#   yunshu-domain add corp.example.com
#   yunshu-domain del corp.example.com
#   yunshu-domain render        # 只生成 JSON
#   yunshu-domain apply         # 生成 + sing-box check + 重启 sing-box
#
set -eu

TXT="${YUNSHU_DOMAINS_TXT:-/etc/sing-box/rules/yunshu-domains.txt}"
JSON="${YUNSHU_DOMAINS_JSON:-/etc/sing-box/rules/yunshu-domains.json}"
CONF="${SINGBOX_CONF:-/etc/sing-box/config.json}"

_usage() {
    cat >&2 <<'EOF'
用法: yunshu-domain {list|add <domain>...|del <domain>...|render|apply}

  list     列出当前清单
  add      追加域名（自动去重）并重新生成 JSON
  del      删除域名（支持 example.com / *.example.com / *..example.com）
  render   仅由 txt 生成 JSON
  apply    render + sing-box check + 重启 sing-box
EOF
}

# 归一化一行：
#   - 去首尾空白/CR
#   - 跳过空行和 # 注释
#   - 去掉行内注释
#   - 去掉开头的 *.. / *. / *
#   - 只保留 [A-Za-z0-9._-]
_norm() {
    _d_="$1"
    _d_="$(printf '%s' "${_d_}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "${_d_}" in
        ''|'#'*) return 1 ;;
    esac
    _d_="${_d_%%[[:space:]]*}"
    case "${_d_}" in
        '*..'*) _d_="${_d_#\*..}" ;;
        '*.'*)  _d_="${_d_#\*.}" ;;
        '*'*)   _d_="${_d_#\*}" ;;
    esac
    [ -n "${_d_}" ] || return 1
    case "${_d_}" in
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    printf '%s\n' "${_d_}"
}

render() {
    [ -f "${TXT}" ] || { echo "缺少 ${TXT}" >&2; return 1; }

    _tmp="${JSON}.tmp.$$"
    _dom="${_tmp}.dom"
    _suf="${_tmp}.suf"
    _kw="${_tmp}.kw"
    : > "${_dom}"
    : > "${_suf}"
    : > "${_kw}"

    while IFS= read -r _line_ || [ -n "${_line_}" ]; do
        _d_="$(_norm "${_line_}" 2>/dev/null)" || continue
        case "${_d_}" in
            *.*)
                printf '%s\n' "${_d_}" >> "${_dom}"
                printf '.%s\n' "${_d_}" >> "${_suf}"
                ;;
            *)
                printf '%s\n' "${_d_}" >> "${_kw}"
                ;;
        esac
    done < "${TXT}"

    sort -u "${_dom}" > "${_dom}.s" && mv -f "${_dom}.s" "${_dom}"
    sort -u "${_suf}" > "${_suf}.s" && mv -f "${_suf}.s" "${_suf}"
    sort -u "${_kw}"  > "${_kw}.s"  && mv -f "${_kw}.s"  "${_kw}"

    _nd="$(wc -l < "${_dom}" | tr -d ' ')"
    _ns="$(wc -l < "${_suf}" | tr -d ' ')"
    _nk="$(wc -l < "${_kw}"  | tr -d ' ')"

    _join() {
        awk 'BEGIN { ORS = "" } { if (NR > 1) printf ","; printf "\"%s\"", $0 }' "$1"
    }

    {
        printf '{\n'
        printf '  "version": 1,\n'
        printf '  "rules": [\n'
        printf '    {\n'
        printf '      "domain": [%s],\n' "$(_join "${_dom}")"
        printf '      "domain_suffix": [%s],\n' "$(_join "${_suf}")"
        printf '      "domain_keyword": [%s]\n' "$(_join "${_kw}")"
        printf '    }\n'
        printf '  ]\n'
        printf '}\n'
    } > "${_tmp}"

    mv -f "${_tmp}" "${JSON}"
    rm -f "${_dom}" "${_suf}" "${_kw}" "${_dom}.s" "${_suf}.s" "${_kw}.s"
    echo "已生成 ${JSON}（domain=${_nd} suffix=${_ns} keyword=${_nk}）"
}

list() {
    [ -f "${TXT}" ] || { echo "缺少 ${TXT}" >&2; return 1; }
    cat "${TXT}"
}

add() {
    [ "$#" -gt 0 ] || { _usage; return 1; }
    for _a_ in "$@"; do
        case "${_a_}" in
            ''|*[!A-Za-z0-9.*_-]*) echo "非法域名: ${_a_}" >&2; return 1 ;;
        esac
        grep -qxF -- "${_a_}" "${TXT}" 2>/dev/null || printf '%s\n' "${_a_}" >> "${TXT}"
    done
    render
}

del() {
    [ "$#" -gt 0 ] || { _usage; return 1; }
    for _a_ in "$@"; do
        case "${_a_}" in
            '*..'*) _b_="${_a_#\*..}" ;;
            '*.'*)  _b_="${_a_#\*.}" ;;
            *)      _b_="${_a_}" ;;
        esac
        grep -vxF -e "${_a_}" -e "*.${_b_}" -e "*..${_b_}" "${TXT}" > "${TXT}.tmp" || true
        mv -f "${TXT}.tmp" "${TXT}"
    done
    render
}

apply() {
    [ -f "${JSON}" ] && cp -f "${JSON}" "${JSON}.bak"

    render || return 1

    if command -v sing-box >/dev/null 2>&1; then
        if ! sing-box check -c "${CONF}"; then
            echo "sing-box check 失败，回滚规则集" >&2
            [ -f "${JSON}.bak" ] && mv -f "${JSON}.bak" "${JSON}"
            return 1
        fi
    fi

    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box restart
    elif command -v sv >/dev/null 2>&1; then
        sv restart sing-box
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl restart sing-box
    else
        echo "找不到 rc-service/sv/systemctl，无法重启 sing-box" >&2
        return 1
    fi

    rm -f "${JSON}.bak"
}

case "${1:-}" in
    render) render ;;
    list)   list ;;
    add)    shift; add "$@" ;;
    del)    shift; del "$@" ;;
    apply)  apply ;;
    *)      _usage; exit 2 ;;
esac
