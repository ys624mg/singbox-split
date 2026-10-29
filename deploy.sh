#!/usr/bin/env bash
# =============================================================================
# sing-box-split —— 只把 Google / Gemini 的流量送到远端 SOCKS5，其余照常直连
#
#   A 机（本机, root）: sing-box + TUN(auto_redirect) 接管本机与 podman 容器流量
#   B 机（远端）      : SOCKS5 出口，Google 看到的就是它的 IP
#
# 子命令
#   install        安装 / 覆盖安装（默认）
#   verify         体检：服务、网卡、接管、出口 IP、Gemini 可达性
#   status         一行式状态
#   update-rules   刷新规则集（内容有变化才重启服务）
#   render-config  只打印将要写入的 config.json（不落盘、不需 root）
#   uninstall      回滚
#   help           帮助
#
# 最小用法
#   B_HOST=1.2.3.4 B_PORT=1080 B_USER=u B_PASS=p bash deploy.sh
#
# 设计取舍（详见 README.md）
#   1. 不用 TPROXY：要按域名分流 + 覆盖容器，TUN + auto_redirect 是唯一不牺牲 UDP 的方案。
#   2. 不用 bootstrap DNS：DoH 直连 8.8.8.8 并指定 SNI，去掉一级故障点。
#   3. 不用 python/jq：配置由纯 bash 生成，最小化镜像也能跑。
#   4. 不信任第三方镜像：二进制用 GitHub API 的 sha256 digest 校验。
# =============================================================================
set -Eeuo pipefail
umask 077

PROG="sing-box-split"
SELF_VERSION="2.0.0"

# ---------- 可覆盖的默认值 ----------
SB_VERSION="${SB_VERSION:-1.14.4}"     # 或 "latest"
ETC_DIR="${ETC_DIR:-/etc/sing-box}"
STATE_DIR="${STATE_DIR:-/var/lib/sing-box}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/sing-box}"
SELF_PATH="/usr/local/bin/sing-box-split"

B_HOST="${B_HOST:-}"
B_PORT="${B_PORT:-1080}"
B_USER="${B_USER:-}"
B_PASS="${B_PASS:-}"

TUN_NAME="${TUN_NAME:-singtun0}"
TUN_ADDR="${TUN_ADDR:-172.31.255.1/30}"
TUN_MTU="${TUN_MTU:-1500}"
MIXED_PORT="${MIXED_PORT:-7890}"
DNS_STRATEGY="${DNS_STRATEGY:-ipv4_only}"
DOH_ADDR="${DOH_ADDR:-8.8.8.8}"
DOH_SNI="${DOH_SNI:-dns.google}"
DNS_LOCAL="${DNS_LOCAL:-}"             # 空=自动探测
LOG_LEVEL="${LOG_LEVEL:-warn}"

USE_RULESET="${USE_RULESET:-auto}"     # auto|yes|no
AI_CATEGORY="${AI_CATEGORY:-no}"
AUTO_UPDATE="${AUTO_UPDATE:-no}"
DO_VERIFY="${DO_VERIFY:-yes}"
FORCE="${FORCE:-no}"
DRY_RUN="${DRY_RUN:-no}"

CONFIG="${ETC_DIR}/config.json"
CRED_FILE="${ETC_DIR}/proxy.env"
MARKER="${ETC_DIR}/.managed-by-${PROG}"
UNIT_FILE="/etc/systemd/system/sing-box.service"
SYSCTL_FILE="/etc/sysctl.d/99-sing-box-split.conf"
TIMER_UNIT="/etc/systemd/system/sing-box-ruleset.service"
TIMER_FILE="/etc/systemd/system/sing-box-ruleset.timer"

# ---------- 域名集合 ----------
# 只列 geosite-google 可能漏掉的部分：AI 端点 + .google 顶级域
GOOGLE_SUFFIX=(
  google.com google.dev googleapis.com gstatic.com googleusercontent.com
  ggpht.com googlevideo.com gvt1.com gvt2.com 1e100.net
  gemini.google.com aistudio.google.com makersuite.google.com
  notebooklm.google.com bard.google.com deepmind.com withgoogle.com
)
GOOGLE_KEYWORD=(generativelanguage aiplatform gemini makersuite)
GOOGLE_REGEX=(
  '^[a-z0-9-]+\.google$'
  '^[a-z0-9-]+\.google\.(com|co\.[a-z]{2}|[a-z]{2})$'
)
PRIVATE_CIDR=(
  10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8
  169.254.0.0/16 100.64.0.0/10 fc00::/7 fe80::/10
)

RS_TAGS=(geosite-google)
RS_FILES=(geosite-google.srs)
RS_BASE="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"

# ---------- 输出 ----------
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_C=''; C_B=''; C_0=''
fi
say()  { printf '%s[*]%s %s\n' "$C_C" "$C_0" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
trap 'printf "%s[x]%s 第 %s 行执行失败：%s\n" "$C_R" "$C_0" "$LINENO" "$BASH_COMMAND" >&2' ERR

# 临时目录统一登记，退出时清理（避免 --force 之外留下半成品）
TMP_PATHS=()
cleanup_tmp() {
  local p
  for p in ${TMP_PATHS[@]+"${TMP_PATHS[@]}"}; do rm -rf -- "$p"; done
}
trap cleanup_tmp EXIT

# ---------- 小工具 ----------
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# 把参数拼成 JSON 字符串数组：a b -> "a","b"
jlist() {
  local first=1 x
  for x in "$@"; do
    if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
    printf '"%s"' "$(json_escape "$x")"
  done
}

# 把参数用 ",\n" 连接（用于多行 JSON 元素）
join_items() {
  local first=1 x
  for x in "$@"; do
    if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
    printf '%s' "$x"
  done
}

need() { command -v "$1" >/dev/null 2>&1; }

# 不依赖 PATH 里是否有 sing-box（精简环境常缺 /usr/local/bin）
sb_version() {
  if [ -x "$BIN_PATH" ]; then
    "$BIN_PATH" version 2>/dev/null | head -1 | awk '{print $3}'
  elif need sing-box; then
    sing-box version 2>/dev/null | head -1 | awk '{print $3}'
  fi
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root：sudo -i 后重跑"
}

# 删除前校验路径，防止 ETC_DIR/STATE_DIR 被误设成 "/" 之类的灾难
assert_safe_dir() {
  local p="${1%/}"
  case "$p" in *..*) die "路径不允许包含 ..：'$1'" ;; esac
  case "$p" in
    ""|"/"|"/etc"|"/usr"|"/usr/local"|"/var"|"/var/lib"|"/root"|"/home"|"/tmp"|"/opt")
      die "拒绝操作危险路径：'$1'" ;;
  esac
  case "$p" in
    /?*) : ;;
    *) die "路径必须是绝对路径且非根：'$1'" ;;
  esac
}

# 一行式 SOCKS5 参数：IP:PORT:USER:PASS / USER:PASS@IP:PORT / IP:PORT
parse_socks_spec() {
  local spec=$1
  case "$spec" in
    *@*)
      local creds="${spec%@*}" hp="${spec#*@}"
      B_USER="${creds%%:*}"
      B_PASS="${creds#*:}"
      B_HOST="${hp%:*}"
      B_PORT="${hp##*:}"
      ;;
    *)
      local -a p=()
      IFS=':' read -r -a p <<<"$spec"
      case "${#p[@]}" in
        2) B_HOST="${p[0]}"; B_PORT="${p[1]}" ;;
        4) B_HOST="${p[0]}"; B_PORT="${p[1]}"; B_USER="${p[2]}"; B_PASS="${p[3]}" ;;
        *) die "--socks5 格式：IP:PORT:USER:PASS 或 USER:PASS@IP:PORT（密码含冒号请用 --b-pass 单独传）" ;;
      esac
      ;;
  esac
  [ -n "$B_HOST" ] && [ -n "$B_PORT" ] || die "--socks5 解析失败：$spec"
}

# ---------- 参数解析 ----------
usage() {
  cat <<'HELP'
sing-box-split —— Google / Gemini 定向分流（本机 + podman 容器）

用法:
  bash deploy.sh [子命令] [选项]

子命令:
  install         安装或覆盖安装（默认）
  verify          体检
  status          状态摘要
  update-rules    刷新规则集，内容有变才重启
  render-config   打印 config.json 到 stdout，不落盘
  uninstall       卸载（无交互；加 --purge 连二进制与规则集一起删）
  help            本帮助

连接 B 机（优先级：命令行 > 环境变量 > /etc/sing-box/proxy.env）
  --socks5 SPEC           一行式：IP:PORT:USER:PASS 或 USER:PASS@IP:PORT
  --b-host IP|域名        B 机地址
  --b-port PORT           SOCKS5 端口，默认 1080
  --b-user USER           SOCKS5 用户名
  --b-pass PASS           SOCKS5 密码（密码含冒号时用这个）

可选:
  --tun-name NAME         TUN 网卡名，默认 singtun0
  --tun-addr CIDR         TUN 地址，默认 172.31.255.1/30
  --mtu N                 TUN MTU，默认 1500
  --mixed-port N          本机 SOCKS/HTTP 入口端口，默认 7890
  --dns-local IP          直连流量的解析服务器，默认自动探测
  --doh IP[:SNI]          Google 侧 DoH，默认 8.8.8.8:dns.google
  --dns-strategy S        ipv4_only|prefer_ipv4|prefer_ipv6，默认 ipv4_only
  --log-level L           trace|debug|info|warn|error，默认 warn
  --sb-version V          sing-box 版本，默认 1.14.4，可写 latest
  --no-ruleset            不用 geosite 规则集，仅靠域名列表
  --ai-category           额外加载 geosite-category-ai-!cn
  --auto-update           安装每日刷新规则集的 systemd timer
  --container NAME        verify 时额外检查该容器
  --force                 覆盖非本脚本管理的既有配置
  --dry-run               只渲染配置，不写系统
  --fast                  急速模式：装完不跑体检（等同 --no-verify）
  --no-verify             安装后不体检
  --purge                 uninstall 时连二进制与规则集一起删

所有选项都支持 --opt=value 写法。

示例:
  # 急速安装（无交互，一条命令搞定）
  curl -fsSL <URL> -o /tmp/sb.sh && bash /tmp/sb.sh --socks5 1.2.3.4:1080:user:pass
  # 同上，跳过装后体检
  curl -fsSL <URL> -o /tmp/sb.sh && bash /tmp/sb.sh install --fast --socks5 1.2.3.4:1080:user:pass
  # 急速卸载（无交互）
  curl -fsSL <URL> -o /tmp/sb.sh && bash /tmp/sb.sh uninstall --purge
  # 其它
  bash deploy.sh verify --container my-app
  bash deploy.sh render-config --no-ruleset > /tmp/c.json && sing-box check -c /tmp/c.json
HELP
}

parse_opts() {
  # 统一支持 --opt=value 写法：先拆成两个 token
  local -a argv=()
  local a
  for a in "$@"; do
    case "$a" in
      --?*=*) argv+=("${a%%=*}" "${a#*=}") ;;
      *)      argv+=("$a") ;;
    esac
  done
  set -- ${argv[@]+"${argv[@]}"}

  while [ $# -gt 0 ]; do
    case "$1" in
      --socks5)       parse_socks_spec "${2:?--socks5 需要一个参数}"; shift 2 ;;
      --b-host)       B_HOST="${2:?}"; shift 2 ;;
      --b-port)       B_PORT="${2:?}"; shift 2 ;;
      --b-user)       B_USER="${2:?}"; shift 2 ;;
      --b-pass)       B_PASS="${2:?}"; shift 2 ;;
      --tun-name)     TUN_NAME="${2:?}"; shift 2 ;;
      --tun-addr)     TUN_ADDR="${2:?}"; shift 2 ;;
      --mtu)          TUN_MTU="${2:?}"; shift 2 ;;
      --mixed-port)   MIXED_PORT="${2:?}"; shift 2 ;;
      --dns-local)    DNS_LOCAL="${2:?}"; shift 2 ;;
      --dns-strategy) DNS_STRATEGY="${2:?}"; shift 2 ;;
      --log-level)    LOG_LEVEL="${2:?}"; shift 2 ;;
      --sb-version)   SB_VERSION="${2:?}"; shift 2 ;;
      --container)    VERIFY_CTR="${2:?}"; shift 2 ;;
      --doh)
        DOH_ADDR="${2:?}"; shift 2
        case "$DOH_ADDR" in *:*) DOH_SNI="${DOH_ADDR#*:}"; DOH_ADDR="${DOH_ADDR%%:*}" ;; esac
        ;;
      --no-ruleset)   USE_RULESET=no; shift ;;
      --ai-category)  AI_CATEGORY=yes; shift ;;
      --auto-update)  AUTO_UPDATE=yes; shift ;;
      --force)        FORCE=yes; shift ;;
      --dry-run)      DRY_RUN=yes; shift ;;
      --fast)         DO_VERIFY=no; shift ;;
      --no-verify)    DO_VERIFY=no; shift ;;
      --purge)        PURGE=yes; shift ;;
      -y|--yes)       shift ;;   # 全流程本就无交互，保留此开关仅为兼容习惯
      -h|--help)      usage; exit 0 ;;
      *)              die "未知参数：$1（--help 查看用法）" ;;
    esac
  done
}
VERIFY_CTR=""
PURGE="no"

# ---------- 凭据 ----------
load_creds() {
  local env_host="$B_HOST" env_port="$B_PORT" env_user="$B_USER" env_pass="$B_PASS"
  if [ -r "$CRED_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CRED_FILE"
    B_HOST="${env_host:-${B_HOST:-}}"
    B_PORT="${env_port:-${B_PORT:-}}"
    B_USER="${env_user:-${B_USER:-}}"
    B_PASS="${env_pass:-${B_PASS:-}}"
  fi
  if [ -z "$B_HOST" ] || [ -z "$B_USER" ] || [ -z "$B_PASS" ]; then
    if [ -t 0 ]; then
      [ -n "$B_HOST" ] || read -r -p "B 机地址: " B_HOST
      [ -n "$B_PORT" ] || read -r -p "SOCKS5 端口 [1080]: " B_PORT
      B_PORT="${B_PORT:-1080}"
      [ -n "$B_USER" ] || read -r -p "SOCKS5 用户名: " B_USER
      [ -n "$B_PASS" ] || { read -r -s -p "SOCKS5 密码: " B_PASS; echo; }
    else
      die "缺少 B 机凭据。示例：
  B_HOST=1.2.3.4 B_USER=u B_PASS=p bash $0
  或首次交互式运行一次，凭据会存到 $CRED_FILE"
    fi
  fi
  [ -n "$B_HOST" ] && [ -n "$B_USER" ] && [ -n "$B_PASS" ] || die "B 机凭据不完整"
  case "$B_PORT" in ''|*[!0-9]*) die "端口必须是数字：$B_PORT" ;; esac
}

# verify/status 只需要 B 机地址，不应因为没存凭据就退出
load_creds_soft() {
  local env_host="$B_HOST"
  if [ -r "$CRED_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CRED_FILE"
    B_HOST="${env_host:-${B_HOST:-}}"
  fi
}

# ---------- 探测 ----------
detect_dns_local() {
  [ -n "$DNS_LOCAL" ] && { printf '%s' "$DNS_LOCAL"; return; }
  local f ns
  for f in /etc/resolv.conf /run/systemd/resolve/resolv.conf; do
    [ -r "$f" ] || continue
    ns=$(awk '$1=="nameserver" && $2 !~ /^(127\.|::1$|0\.0\.0\.0$)/ {print $2; exit}' "$f")
    if [ -n "$ns" ]; then printf '%s' "$ns"; return; fi
  done
  printf '1.1.1.1'
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  SB_ARCH=amd64 ;;
    aarch64|arm64) SB_ARCH=arm64 ;;
    armv7l|armv7)  SB_ARCH=armv7 ;;
    i386|i686)     SB_ARCH=386 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  SB_ASSET_SUFFIX=""
  if [ "$SB_ARCH" = amd64 ] || [ "$SB_ARCH" = arm64 ]; then
    if [ -e "/lib/ld-musl-$(uname -m).so.1" ]; then SB_ASSET_SUFFIX="-musl"; fi
  fi
}

resolve_b_ip() {
  local h=$1 ip=""
  [ -n "$h" ] || { printf ''; return 0; }
  if printf '%s' "$h" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then printf '%s' "$h"; return 0; fi
  case "$h" in *:*) printf '%s' "$h"; return 0 ;; esac
  # 注意：pipefail 下缺 getent/dig 会让整条管道失败，必须兜住
  if need getent; then
    ip="$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  fi
  if [ -z "$ip" ] && need dig; then
    ip="$(dig +short A "$h" 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
  fi
  printf '%s' "$ip"
  return 0
}

preflight() {
  require_root
  need curl || die "缺少 curl"
  need tar  || die "缺少 tar"
  [ -d /run/systemd/system ] || die "本机没有 systemd，本脚本不支持（OpenVZ/LXC 常缺）"
  [ -c /dev/net/tun ] || die "缺少 /dev/net/tun，无法用 TUN 模式（OpenVZ/LXC 常见）"

  if ! need nft; then
    die "缺少 nftables。auto_redirect 依赖它，否则容器流量不会被接管：
  apt install -y nftables   或   dnf install -y nftables"
  fi
  if [ ! -d /sys/module/nfnetlink_queue ] && ! modprobe nfnetlink_queue 2>/dev/null; then
    die "内核缺少 nfnetlink_queue，auto_redirect 无法工作。请换 KVM 机型或加载该模块"
  fi

  # 端口占用
  if need ss && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${MIXED_PORT}\$"; then
    if ! ss -ltnp 2>/dev/null | grep -qE "[:.]${MIXED_PORT}\s.*sing-box"; then
      die "端口 ${MIXED_PORT} 已被其它进程占用，用 --mixed-port 换一个"
    fi
  fi

  # TUN 网段冲突（排除本脚本自己的 tun 路由，否则重装会误报）
  if need ip; then
    local addr4; addr4="$(printf '%s' "$TUN_ADDR" | cut -d/ -f1)"
    if ip -4 route show 2>/dev/null | grep -F "$addr4" | grep -qv "dev ${TUN_NAME}"; then
      warn "TUN 地址 ${TUN_ADDR} 与既有路由冲突，用 --tun-addr 换一个"
    fi
  fi

  # 既有配置归属
  if [ -f "$CONFIG" ] && [ ! -f "$MARKER" ] && [ "$FORCE" != yes ]; then
    die "已存在 $CONFIG，且不是本脚本生成的。为避免覆盖别人的 sing-box：
  mv $CONFIG $CONFIG.foreign.\$(date +%s)   然后重跑
  或确认要覆盖后加 --force"
  fi
}

# ---------- 二进制 ----------
resolve_latest_version() {
  curl -fsSL -m 20 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]*"' | head -1 \
    | grep -o 'v[0-9][0-9.]*' | tr -d 'v' || true
}

# 用 GitHub API 的 digest 字段取 sha256（无需 jq）
resolve_digest() {
  local asset=$1
  curl -fsSL -m 25 -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${SB_VERSION}" 2>/dev/null \
    | tr '{' '\n' \
    | grep -F "\"name\": \"${asset}\"" \
    | grep -o '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]*"' | head -1 \
    | grep -o '[0-9a-f]\{64\}' || true
}

sha256_of() {
  if need sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif need shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

install_binary() {
  detect_arch
  if [ "$DRY_RUN" = yes ] && ! need sing-box && [ ! -x "$BIN_PATH" ]; then
    warn "dry-run：未安装 sing-box，跳过下载与校验"
    return
  fi
  if [ "$SB_VERSION" = latest ]; then
    local v; v="$(resolve_latest_version)"
    [ -n "$v" ] || die "无法获取 sing-box 最新版本，请显式指定 --sb-version"
    SB_VERSION="$v"
  fi

  if [ "$(sb_version)" = "$SB_VERSION" ]; then
    ok "sing-box v${SB_VERSION} 已就位"
    return
  fi

  local name="sing-box-${SB_VERSION}-linux-${SB_ARCH}${SB_ASSET_SUFFIX}"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${name}.tar.gz"
  local want; want="$(resolve_digest "${name}.tar.gz")"
  [ -n "$want" ] || warn "拿不到官方 sha256（API 限流？），本次只做可用性校验"

  local tmp; tmp="$(mktemp -d)"; TMP_PATHS+=("$tmp")

  say "下载 ${name}.tar.gz"
  if ! curl -fsSL --connect-timeout 10 -m 180 "$url" -o "$tmp/sb.tgz"; then
    [ -n "$want" ] || die "直连 GitHub 失败，且无校验值，拒绝改用第三方镜像"
    warn "直连 GitHub 失败，改用镜像 ghfast.top（仍会校验 sha256）"
    curl -fsSL --connect-timeout 10 -m 180 "https://ghfast.top/${url}" -o "$tmp/sb.tgz" \
      || die "下载失败：A 机到 GitHub 与镜像都不通"
  fi

  if [ -n "$want" ]; then
    if ! need sha256sum && ! need shasum; then
      warn "系统没有 sha256sum/shasum，跳过完整性校验（建议装 coreutils）"
    else
      local got; got="$(sha256_of "$tmp/sb.tgz" || true)"
      [ "$got" = "$want" ] || die "sha256 不匹配，安装包可能被篡改
  期望 $want
  实得 ${got:-<无法计算>}"
      ok "sha256 校验通过"
    fi
  fi

  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 0755 "$tmp/${name}/sing-box" "$BIN_PATH"
  ok "已安装 $("$BIN_PATH" version | head -1)"
}

# ---------- 规则集 ----------
init_rs_lists() {
  if [ "$AI_CATEGORY" = yes ]; then
    RS_TAGS+=(geosite-ai)
    RS_FILES+=("geosite-category-ai-!cn.srs")
  fi
}

# auto 的语义：本地已有可用 .srs 就用，否则不用（安装流程里会先尝试下载）
# 同时剔除缺失的条目，避免配置引用不存在的本地文件
resolve_ruleset_choice() {
  [ "$USE_RULESET" = auto ] || return 0
  local -a kt=() kf=()
  local i f
  for i in "${!RS_FILES[@]}"; do
    f="${RS_FILES[$i]}"
    if [ -s "${STATE_DIR}/${f}" ] && [ "$(head -c 3 "${STATE_DIR}/${f}")" = "SRS" ]; then
      kt+=("${RS_TAGS[$i]}"); kf+=("$f")
    fi
  done
  if [ "${#kf[@]}" -eq 0 ]; then
    USE_RULESET=no
  else
    RS_TAGS=("${kt[@]}"); RS_FILES=("${kf[@]}"); USE_RULESET=yes
  fi
}

fetch_one_ruleset() {
  local file=$1 dest="${STATE_DIR}/$1" tmp="${STATE_DIR}/$1.part"
  local url="${RS_BASE}/${file}"

  say "拉取规则集 ${file}"
  rm -f "$tmp"
  if curl -fsSL --connect-timeout 8 -m 60 -x "socks5h://${B_HOST}:${B_PORT}" \
        --proxy-user "${B_USER}:${B_PASS}" -o "$tmp" "$url" 2>/dev/null; then
    :
  elif curl -fsSL --connect-timeout 8 -m 60 -o "$tmp" "$url" 2>/dev/null; then
    warn "经 B 机拉取失败，改直连成功"
  else
    rm -f "$tmp"; return 1
  fi

  # .srs 以魔数 "SRS" 开头，比"大于 1KB"可靠
  if [ "$(head -c 3 "$tmp" 2>/dev/null)" != "SRS" ] || [ "$(wc -c <"$tmp")" -lt 1024 ]; then
    warn "${file} 内容异常（不是有效 .srs），丢弃"
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$dest"
  ok "${file} 就绪（$(wc -c <"$dest") 字节）"
}

fetch_rulesets() {
  install -d -m 0755 "$STATE_DIR"
  if [ "$USE_RULESET" = no ]; then warn "按 --no-ruleset 跳过规则集"; return; fi
  init_rs_lists

  # 只保留真正可用的条目，避免配置里引用不存在的本地文件
  local -a keep_tags=() keep_files=()
  local i f
  for i in "${!RS_FILES[@]}"; do
    f="${RS_FILES[$i]}"
    if [ -s "${STATE_DIR}/${f}" ] && [ "$(head -c 3 "${STATE_DIR}/${f}")" = "SRS" ]; then
      ok "${f} 已存在（$(wc -c <"${STATE_DIR}/${f}") 字节）"
      keep_tags+=("${RS_TAGS[$i]}"); keep_files+=("$f"); continue
    fi
    if fetch_one_ruleset "$f"; then
      keep_tags+=("${RS_TAGS[$i]}"); keep_files+=("$f")
    fi
  done

  if [ "${#keep_files[@]}" -eq 0 ]; then
    warn "规则集全部不可用，回退为纯域名规则（Google/Gemini 分流仍生效）"
    USE_RULESET=no
  else
    RS_TAGS=("${keep_tags[@]}")
    RS_FILES=("${keep_files[@]}")
    USE_RULESET=yes
  fi
}

# ---------- 配置生成（纯函数：不读写系统，便于本地校验） ----------
render_config() {
  local dns_local="$1" use_rs="$2"

  local -a dns_rules route_rules rs_entries
  local t

  # DNS 规则
  dns_rules=()
  if [ "$use_rs" = yes ]; then
    for t in "${RS_TAGS[@]}"; do
      dns_rules+=("{ \"rule_set\": \"${t}\", \"server\": \"dns-proxy\" }")
    done
  fi
  dns_rules+=("{ \"domain_suffix\": [$(jlist "${GOOGLE_SUFFIX[@]}")], \"server\": \"dns-proxy\" }")
  dns_rules+=("{ \"domain_keyword\": [$(jlist "${GOOGLE_KEYWORD[@]}")], \"server\": \"dns-proxy\" }")
  dns_rules+=("{ \"domain_regex\": [$(jlist "${GOOGLE_REGEX[@]}")], \"server\": \"dns-proxy\" }")

  # 路由规则
  route_rules=(
    '{ "action": "sniff" }'
    '{ "protocol": "dns", "action": "hijack-dns" }'
    "{ \"ip_cidr\": [$(jlist "${PRIVATE_CIDR[@]}")], \"outbound\": \"direct\" }"
  )
  if [ "$use_rs" = yes ]; then
    for t in "${RS_TAGS[@]}"; do
      route_rules+=("{ \"rule_set\": \"${t}\", \"outbound\": \"proxy\" }")
    done
  fi
  route_rules+=("{ \"domain_suffix\": [$(jlist "${GOOGLE_SUFFIX[@]}")], \"outbound\": \"proxy\" }")
  route_rules+=("{ \"domain_keyword\": [$(jlist "${GOOGLE_KEYWORD[@]}")], \"outbound\": \"proxy\" }")
  route_rules+=("{ \"domain_regex\": [$(jlist "${GOOGLE_REGEX[@]}")], \"outbound\": \"proxy\" }")

  # rule_set 定义块（可选）
  local rs_block=""
  if [ "$use_rs" = yes ]; then
    rs_entries=()
    local i
    for i in "${!RS_TAGS[@]}"; do
      rs_entries+=("{ \"tag\": \"${RS_TAGS[$i]}\", \"type\": \"local\", \"format\": \"binary\", \"path\": \"$(json_escape "${STATE_DIR}/${RS_FILES[$i]}")\" }")
    done
    rs_block=$(printf '\n    "rule_set": [\n%s\n    ],' "$(join_items "${rs_entries[@]}" | sed 's/^/      /')")
  fi

  local excl
  excl="$(json_escape "${B_IP_RESOLVED}/${EXCL_PREFIX}")"

  cat <<JSON
{
  "log": {
    "level": "${LOG_LEVEL}",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-proxy",
        "type": "https",
        "server": "$(json_escape "$DOH_ADDR")",
        "detour": "proxy",
        "tls": { "server_name": "$(json_escape "$DOH_SNI")" }
      },
      {
        "tag": "dns-local",
        "type": "udp",
        "server": "$(json_escape "$dns_local")"
      }
    ],
    "rules": [
$(join_items "${dns_rules[@]}" | sed 's/^/      /')
    ],
    "final": "dns-local",
    "strategy": "${DNS_STRATEGY}"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "$(json_escape "$TUN_NAME")",
      "address": ["$(json_escape "$TUN_ADDR")"],
      "mtu": ${TUN_MTU},
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": false,
      "dns_mode": "hijack",
      "route_exclude_address": ["${excl}"]
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": ${MIXED_PORT}
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "proxy",
      "server": "$(json_escape "$B_HOST")",
      "server_port": ${B_PORT},
      "version": "5",
      "username": "$(json_escape "$B_USER")",
      "password": "$(json_escape "$B_PASS")",
      "udp_over_tcp": false
    },
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": { "server": "dns-local" },${rs_block}
    "rules": [
$(join_items "${route_rules[@]}" | sed 's/^/      /')
    ],
    "final": "direct"
  }
}
JSON
}

# ---------- 落盘 ----------
write_config() {
  install -d -m 0700 "$ETC_DIR"
  local dns_local; dns_local="$(detect_dns_local)"
  local tmp; tmp="$(mktemp "${ETC_DIR}/.config.XXXXXX")"

  render_config "$dns_local" "$USE_RULESET" >"$tmp"

  if [ "$DRY_RUN" = yes ]; then
    say "dry-run：配置已渲染到 $tmp（未启用）"
    if [ -x "$BIN_PATH" ]; then "$BIN_PATH" check -c "$tmp" && ok "配置校验通过"; fi
    rm -f "$tmp"
    return
  fi

  "$BIN_PATH" check -c "$tmp" || { rm -f "$tmp"; die "配置校验失败（见上方报错），未改动线上配置"; }

  if [ -f "$CONFIG" ]; then
    cp -a "$CONFIG" "${CONFIG}.bak.$(date +%s)"
    ls -1dt "${CONFIG}".bak.* 2>/dev/null | tail -n +6 | while read -r f; do rm -f -- "$f"; done
    say "旧配置已备份（保留最近 5 份）"
  fi
  chmod 0600 "$tmp"
  mv -f "$tmp" "$CONFIG"
  printf 'version=%s\ndate=%s\n' "$SELF_VERSION" "$(date -Iseconds)" >"$MARKER"
  chmod 0600 "$MARKER"
  ok "已写入 $CONFIG（本机直连 DNS：${dns_local}）"
}

write_creds() {
  [ "$DRY_RUN" = yes ] && return
  install -d -m 0700 "$ETC_DIR"
  printf 'B_HOST=%q\nB_PORT=%q\nB_USER=%q\nB_PASS=%q\n' \
    "$B_HOST" "$B_PORT" "$B_USER" "$B_PASS" >"$CRED_FILE"
  chmod 0600 "$CRED_FILE"
  ok "凭据已存 $CRED_FILE（0600）"
}

write_unit() {
  [ "$DRY_RUN" = yes ] && { say "dry-run：跳过 systemd unit"; return; }
  cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=sing-box (Google/Gemini split routing)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} run -D ${STATE_DIR} -c ${CONFIG} --disable-color
Restart=always
RestartSec=3s
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH

[Install]
WantedBy=multi-user.target
UNIT
  ok "已写入 $UNIT_FILE"
}

write_sysctl() {
  [ "$DRY_RUN" = yes ] && { say "dry-run：跳过 sysctl"; return; }
  cat >"$SYSCTL_FILE" <<'SYS'
# sing-box TUN：容器与 TUN 之间的非对称路由需要关闭反向路径过滤
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
SYS
  # 只应用本文件，不用 sysctl --system（避免连带重载全机 sysctl）
  sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "sysctl 应用失败，容器流量可能不通"
  ok "已应用 $SYSCTL_FILE"
}

maybe_self_install() {
  [ "$DRY_RUN" = yes ] && return
  if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")" != "$SELF_PATH" ]; then
    install -m 0755 "$0" "$SELF_PATH" && ok "已安装命令 $SELF_PATH"
  fi
}

write_update_timer() {
  [ "$AUTO_UPDATE" = yes ] || return
  if [ ! -x "$SELF_PATH" ]; then
    warn "脚本不是从文件运行的，无法安装自动更新 timer；可稍后手动 bash deploy.sh update-rules"
    return
  fi
  [ "$DRY_RUN" = yes ] && { say "dry-run：跳过 timer"; return; }
  cat >"$TIMER_UNIT" <<UNIT
[Unit]
Description=Refresh sing-box geosite rule-set
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SELF_PATH} update-rules
UNIT
  cat >"$TIMER_FILE" <<'TMR'
[Unit]
Description=Daily sing-box geosite rule-set refresh

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
TMR
  systemctl daemon-reload
  systemctl enable --now sing-box-ruleset.timer >/dev/null 2>&1 || warn "timer 启用失败"
  ok "已启用每日规则集刷新（sing-box-ruleset.timer）"
}

start_service() {
  [ "$DRY_RUN" = yes ] && { say "dry-run：不启停服务"; return; }
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box

  local i
  for i in $(seq 1 20); do
    systemctl is-active --quiet sing-box && break
    sleep 0.5
  done
  if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
    die "sing-box 启动失败（见上方日志）"
  fi
  ok "sing-box 已运行"
}

# ---------- 体检 ----------
probe_google_egress() {
  local resp sub
  resp=$(curl -s -m 12 "https://dns.google/resolve?name=o-o.myaddr.l.google.com&type=TXT" 2>/dev/null || true)
  [ -n "$resp" ] || return 1
  # 真值在 Answer[].data 里，形如 "edns0-client-subnet 1.2.3.0/24"
  sub=$(printf '%s' "$resp" | grep -o 'edns0-client-subnet [0-9.]*/[0-9]*' | head -1 | awk '{print $2}')
  [ -n "$sub" ] || return 1
  printf '%s' "$sub"
}

verify() {
  local ctr="${1:-}"
  local b_ip; b_ip="$(resolve_b_ip "${B_HOST:-}")"
  [ -n "$b_ip" ] || b_ip="${B_HOST:-?}"

  echo
  printf '%s=== 1. 服务与接管 ===%s\n' "$C_B" "$C_0"
  if systemctl is-active --quiet sing-box; then
    ok "sing-box $(sb_version) 运行中"
  else
    warn "sing-box 未运行"
  fi
  if ip link show "$TUN_NAME" >/dev/null 2>&1; then ok "$TUN_NAME 已建立"; else warn "未发现 $TUN_NAME"; fi

  local nft_out; nft_out="$(nft list ruleset 2>/dev/null || true)"
  if printf '%s' "$nft_out" | grep -qi 'sing-box'; then
    ok "nftables 中已有 sing-box 表（auto_redirect 生效）"
  else
    warn "nftables 中找不到 sing-box 表 → 容器流量可能没被接管"
  fi

  echo
  printf '%s=== 2. 出口比对 ===%s\n' "$C_B" "$C_0"
  local a_ip; a_ip="$(curl -s -m 12 https://api.ipify.org 2>/dev/null || curl -s -m 12 https://ifconfig.me/ip 2>/dev/null || true)"
  echo "  本机直连出口 : ${a_ip:-查询失败}"
  echo "  B 机地址     : ${b_ip}"

  local sub; sub="$(probe_google_egress || true)"
  if [ -n "$sub" ]; then
    echo "  Google 看到   : ${sub}"
    local gnet bnet
    gnet="$(printf '%s' "$sub" | cut -d/ -f1 | cut -d. -f1-3)"
    bnet="$(printf '%s' "$b_ip" | cut -d. -f1-3)"
    if [ "$gnet" = "$bnet" ]; then
      ok "Google 侧出口与 B 机同网段 → 分流生效"
    else
      warn "Google 侧出口(${gnet}.x) 与 B 机(${bnet}.x) 不同段（B 机若为 NAT 出口属正常，仅供参考）"
    fi
  else
    warn "拿不到 dns.google 的 EDNS 回显（Google 域名可能没走通）"
  fi

  echo
  printf '%s=== 3. 可达性与地区 ===%s\n' "$C_B" "$C_0"
  local code redir
  code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' https://www.google.com/ 2>/dev/null || true)
  redir=$(curl -s -m 15 -o /dev/null -w '%{redirect_url}' https://www.google.com/ 2>/dev/null || true)
  if [ "$code" = "200" ] && [ -z "$redir" ]; then
    ok "www.google.com = 200 且无跳转"
  else
    warn "www.google.com 状态码=${code} 跳转=${redir:-无}"
  fi

  local g1 g2
  g1=$(curl -s -m 15 -o /dev/null -w '%{http_code}' https://gemini.google.com/ 2>/dev/null || true)
  g2=$(curl -s -m 15 -o /dev/null -w '%{http_code}' https://generativelanguage.googleapis.com/v1/models 2>/dev/null || true)
  echo "  gemini.google.com                     = ${g1}"
  echo "  generativelanguage.googleapis.com     = ${g2}"

  echo
  printf '%s=== 4. DNS 泄漏 ===%s\n' "$C_B" "$C_0"
  local v4 v6
  v4=$(getent ahostsv4 www.google.com 2>/dev/null | awk '{print $1}' | head -2 | tr '\n' ' ')
  v6=$(getent ahostsv6 www.google.com 2>/dev/null | awk '{print $1}' | head -2 | tr '\n' ' ')
  echo "  A    : ${v4:-无}"
  echo "  AAAA : ${v6:-无}"
  if [ -n "${v6// /}" ] && ! ip -6 route show default 2>/dev/null | grep -q .; then
    warn "无 IPv6 默认路由却解析出 AAAA，程序可能先试 v6 而卡顿（strategy=${DNS_STRATEGY}）"
  else
    ok "未发现 AAAA 导致的 v6 泄漏"
  fi

  if [ -n "$ctr" ]; then
    echo
    printf '%s=== 5. 容器 %s ===%s\n' "$C_B" "$ctr" "$C_0"
    if podman exec "$ctr" sh -c '
        if command -v curl >/dev/null 2>&1; then
          echo -n "  容器直连出口 : "; curl -s -m 12 https://api.ipify.org; echo
          echo -n "  www.google   : "; curl -s -m 12 -o /dev/null -w "%{http_code}\n" https://www.google.com/
          echo -n "  gemini       : "; curl -s -m 12 -o /dev/null -w "%{http_code}\n" https://gemini.google.com/
        else
          echo "  容器内无 curl，跳过"
        fi' 2>/dev/null; then :; else
      warn "无法进入容器 ${ctr}（rootful 容器请确认名称）"
    fi
  fi

  echo
  printf '%s=== 6. 最近日志 ===%s\n' "$C_B" "$C_0"
  journalctl -u sing-box -n 12 --no-pager 2>/dev/null | tail -12 || true
}

# ---------- 子命令 ----------
do_install() {
  preflight
  load_creds
  B_IP_RESOLVED="$(resolve_b_ip "$B_HOST")"
  [ -n "$B_IP_RESOLVED" ] || die "无法解析 B 机地址：$B_HOST"
  case "$B_IP_RESOLVED" in *:*) EXCL_PREFIX=128 ;; *) EXCL_PREFIX=32 ;; esac

  install_binary
  fetch_rulesets
  write_config
  write_creds
  write_unit
  write_sysctl
  start_service
  maybe_self_install
  write_update_timer

  echo
  ok "安装完成"
  printf '  分流入口   : socks5h://127.0.0.1:%s（本机可用，其余流量直连）\n' "$MIXED_PORT"
  printf '  Google 出口: %s@%s:%s\n' "$B_USER" "$B_HOST" "$B_PORT"
  printf '  规则集     : %s\n' "$([ "$USE_RULESET" = yes ] && echo 已启用 || echo 未使用)"
  printf '  复验       : %s verify\n' "${SELF_PATH}"
  printf '  实时日志   : journalctl -u sing-box -f\n'
  echo
  if [ "$DO_VERIFY" = yes ] && [ "$DRY_RUN" != yes ]; then
    verify "$VERIFY_CTR"
  fi
  return 0
}

do_status() {
  local sv; sv="$(sb_version)"; [ -n "$sv" ] || sv="未安装"
  local act; act="$(systemctl is-active sing-box 2>/dev/null || true)"
  local tun="-"; ip link show "$TUN_NAME" >/dev/null 2>&1 && tun="$TUN_NAME"
  local cap="-"; nft list ruleset 2>/dev/null | grep -qi 'sing-box' && cap="nft ok"
  local rs="未使用"
  local f="${STATE_DIR}/geosite-google.srs"
  [ -s "$f" ] && rs="$(wc -c <"$f") 字节 / $(date -r "$f" +%F 2>/dev/null || echo '?')"
  printf '  版本   : %s\n  服务   : %s\n  TUN    : %s\n  接管   : %s\n  规则集 : %s\n' \
    "$sv" "${act:-未知}" "$tun" "$cap" "$rs"
}

do_update_rules() {
  require_root
  load_creds
  shopt -s nullglob
  local -a paths=("${STATE_DIR}"/geosite-*.srs)
  shopt -u nullglob
  if [ "${#paths[@]}" -eq 0 ]; then
    warn "${STATE_DIR} 下没有规则集文件，先用 install 跑一次"
    return 0
  fi

  local changed=0 p f dest tmp
  for p in "${paths[@]}"; do
    f="$(basename "$p")"
    dest="$p"; tmp="${dest}.new"
    if curl -fsSL --connect-timeout 8 -m 60 -x "socks5h://${B_HOST}:${B_PORT}" --proxy-user "${B_USER}:${B_PASS}" \
          -o "$tmp" "${RS_BASE}/${f}" 2>/dev/null \
       || curl -fsSL --connect-timeout 8 -m 60 -o "$tmp" "${RS_BASE}/${f}" 2>/dev/null; then
      if [ "$(head -c 3 "$tmp" 2>/dev/null)" = "SRS" ] && ! cmp -s "$tmp" "$dest"; then
        mv -f "$tmp" "$dest"; changed=1; ok "${f} 已更新"
      else
        rm -f "$tmp"; say "${f} 无变化"
      fi
    else
      rm -f "$tmp"; warn "${f} 拉取失败，保留旧文件"
    fi
  done
  if [ "$changed" -eq 1 ] && systemctl is-active --quiet sing-box; then
    systemctl restart sing-box && ok "已重启以加载新规则"
  fi
}

do_uninstall() {
  require_root
  assert_safe_dir "$ETC_DIR"
  assert_safe_dir "$STATE_DIR"

  # 无交互：先完整列出要删什么，然后直接执行
  printf '%s即将卸载以下内容（无交互，直接执行）%s\n' "$C_B" "$C_0"
  printf '  服务单元 : sing-box.service / sing-box-ruleset.timer\n'
  printf '  配置目录 : %s\n' "$ETC_DIR"
  printf '  sysctl   : %s\n' "$SYSCTL_FILE"
  if [ -f /etc/sysctl.d/99-sing-box.conf ]; then
    printf '  旧版残留 : /etc/sysctl.d/99-sing-box.conf  /root/vps-a-google-via-b\n'
  fi
  if [ "$PURGE" = yes ]; then
    printf '  二进制   : %s  %s\n' "$BIN_PATH" "$SELF_PATH"
    printf '  状态目录 : %s\n' "$STATE_DIR"
  fi
  echo

  # 1. 停服务（TUN 消失、路由与 nft 表随之回收）
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  systemctl disable --now sing-box-ruleset.timer >/dev/null 2>&1 || true
  pkill -x sing-box 2>/dev/null || true

  # 2. 删单元（含旧版脚本遗留的 sysctl 与 verify 目录）
  rm -f "$UNIT_FILE" "$TIMER_UNIT" "$TIMER_FILE" "$SYSCTL_FILE"
  rm -f /etc/sysctl.d/99-sing-box.conf
  rm -rf /root/vps-a-google-via-b
  systemctl daemon-reload

  # 3. 删配置
  rm -rf "$ETC_DIR"

  # 4. 恢复运行时 sysctl（ip_forward 保持 1：podman/docker 需要它）
  sysctl -w net.ipv4.conf.all.rp_filter=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.default.rp_filter=1 >/dev/null 2>&1 || true

  # 5. 兜底清 nft 表，否则流量会被黑洞
  if nft list tables 2>/dev/null | grep -q 'table inet sing-box'; then
    nft delete table inet sing-box 2>/dev/null || true
    say "已清理残留的 nft 表 inet sing-box"
  fi

  # 6. 可选：彻底删除二进制与规则集
  if [ "$PURGE" = yes ]; then
    rm -f "$BIN_PATH" "$SELF_PATH"
    rm -rf "$STATE_DIR"
    ok "已彻底删除（含二进制与规则集）"
  else
    ok "已卸载服务与配置（保留二进制与规则集，加 --purge 彻底删除）"
  fi

  # 7. 卸载后自检
  echo
  if ip link show "$TUN_NAME" >/dev/null 2>&1; then
    warn "网卡 ${TUN_NAME} 仍存在，稍等几秒再确认；若长期残留：ip link del ${TUN_NAME}"
  else
    ok "网卡 ${TUN_NAME} 已移除"
  fi
  if ip route show default 2>/dev/null | grep -q "dev ${TUN_NAME}"; then
    warn "默认路由仍指向 ${TUN_NAME}，网络可能不通，执行：ip route del default dev ${TUN_NAME}"
  else
    ok "默认路由已恢复正常"
  fi
}

# ---------- 入口 ----------
main() {
  local cmd=install
  if [ $# -gt 0 ]; then
    case "$1" in
      install|verify|status|update-rules|render-config|uninstall|help|-h|--help)
        cmd="$1"; shift ;;
    esac
  fi
  parse_opts "$@"

  case "$cmd" in
    help|-h|--help) usage ;;
    install)        do_install ;;
    status)         do_status ;;
    verify)         load_creds_soft; verify "$VERIFY_CTR" ;;
    update-rules)   do_update_rules ;;
    uninstall)      do_uninstall ;;
    render-config)
      B_HOST="${B_HOST:-198.51.100.10}"
      B_USER="${B_USER:-placeholder}"
      B_PASS="${B_PASS:-placeholder}"
      B_IP_RESOLVED="$(resolve_b_ip "$B_HOST")"
      [ -n "$B_IP_RESOLVED" ] || B_IP_RESOLVED="127.0.0.1"
      case "$B_IP_RESOLVED" in *:*) EXCL_PREFIX=128 ;; *) EXCL_PREFIX=32 ;; esac
      init_rs_lists
      resolve_ruleset_choice
      render_config "$(detect_dns_local)" "$USE_RULESET"
      ;;
    *) die "未知子命令：$cmd" ;;
  esac
}

main "$@"
