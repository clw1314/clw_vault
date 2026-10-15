#!/usr/bin/env bash
set -Eeuo pipefail

# 用法：
#   ./install-go.sh                  # 安装最新稳定版 Go
#   ./install-go.sh --xcaddy         # 安装最新稳定版 Go + xcaddy
#   ./install-go.sh 1.24.0           # 安装指定版本 Go
#   ./install-go.sh 1.24.0 --xcaddy  # 安装指定版本 Go + xcaddy

die() {
    echo "错误：$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：./install-go.sh [Go版本号] [--xcaddy]

参数：
  Go版本号     可选，例如 1.24.0 或 go1.24.0；默认安装最新稳定版
  --xcaddy     同时通过 APT 安装 xcaddy
  -h, --help   显示帮助
EOF
}

VERSION=""
INSTALL_XCADDY=0

for arg in "$@"; do
    case "$arg" in
        --xcaddy)
            INSTALL_XCADDY=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "未知选项：$arg"
            ;;
        *)
            [[ -z "$VERSION" ]] || die "只能指定一个 Go 版本"
            VERSION="${arg#go}"
            [[ "$VERSION" =~ ^1\.[0-9]+(\.[0-9]+)?$ ]] \
                || die "版本格式不正确，例如：1.24.0"
            VERSION="go${VERSION}"
            ;;
    esac
done

# 自动通过 sudo 提权
if [[ "$EUID" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 \
        || die "请使用 root 运行，或先安装并配置 sudo"
    exec sudo bash "$0" "$@"
fi

[[ -f /etc/debian_version ]] || die "此脚本面向 Debian 系统"

case "$(uname -m)" in
    x86_64)              ARCH="amd64" ;;
    aarch64|arm64)       ARCH="arm64" ;;
    armv6l|armv7l)       ARCH="armv6l" ;;
    i386|i486|i586|i686) ARCH="386" ;;
    ppc64le)             ARCH="ppc64le" ;;
    s390x)               ARCH="s390x" ;;
    riscv64)             ARCH="riscv64" ;;
    *) die "暂不支持的 CPU 架构：$(uname -m)" ;;
esac

echo "==> 安装基础依赖"
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl jq tar gzip

mkdir -p /usr/local
WORKDIR="$(mktemp -d /usr/local/.go-install.XXXXXX)"
trap 'rm -rf -- "$WORKDIR"' EXIT

CURL_ARGS=(
    --fail
    --location
    --show-error
    --silent
    --retry 3
    --connect-timeout 20
    --proto '=https'
    --proto-redir '=https'
)

# ---------- 安装 Go ----------

echo "==> 获取 Go 官方版本信息"

METADATA_URL="https://go.dev/dl/?mode=json"
if [[ -n "$VERSION" ]]; then
    METADATA_URL="${METADATA_URL}&include=all"
fi

curl "${CURL_ARGS[@]}" "$METADATA_URL" \
    -o "$WORKDIR/releases.json"

if [[ -z "$VERSION" ]]; then
    VERSION="$(
        jq -er '[.[] | select(.stable == true)][0].version' \
            "$WORKDIR/releases.json"
    )"
fi

PACKAGE="$(
    jq -r \
        --arg version "$VERSION" \
        --arg arch "$ARCH" \
        '.[] | select(.version == $version)
         | .files[]
         | select(.os == "linux"
                  and .arch == $arch
                  and .kind == "archive")
         | [.filename, .sha256]
         | @tsv' \
        "$WORKDIR/releases.json"
)"

[[ -n "$PACKAGE" ]] \
    || die "找不到 ${VERSION} 的 linux/${ARCH} 官方安装包"

IFS=$'\t' read -r FILENAME SHA256 <<< "$PACKAGE"

echo "==> 下载 ${VERSION}，架构：${ARCH}"
curl "${CURL_ARGS[@]}" "https://go.dev/dl/${FILENAME}" \
    -o "$WORKDIR/$FILENAME"

echo "==> 校验 SHA-256"
(
    cd "$WORKDIR"
    printf '%s  %s\n' "$SHA256" "$FILENAME" | sha256sum --check -
)

echo "==> 解压并检查安装包"
tar --no-same-owner -xzf "$WORKDIR/$FILENAME" -C "$WORKDIR"
[[ -x "$WORKDIR/go/bin/go" ]] || die "安装包中缺少 Go 可执行文件"

"$WORKDIR/go/bin/go" version

BACKUP=""
if [[ -e /usr/local/go || -L /usr/local/go ]]; then
    BACKUP="/usr/local/go.backup.$(date +%Y%m%d-%H%M%S).$$"
    echo "==> 备份旧 Go 至：$BACKUP"
    mv -- /usr/local/go "$BACKUP"
fi

if ! mv -- "$WORKDIR/go" /usr/local/go; then
    if [[ -n "$BACKUP" ]]; then
        mv -- "$BACKUP" /usr/local/go
    fi
    die "Go 安装失败，已尝试恢复旧安装"
fi

echo "==> 配置 Go 全局 PATH"
install -d -m 0755 /etc/profile.d
cat > /etc/profile.d/go.sh <<'EOF'
export PATH="/usr/local/go/bin:${GOPATH:-$HOME/go}/bin:$PATH"
EOF
chmod 0644 /etc/profile.d/go.sh

# 让本脚本后续命令立即使用新安装的 Go
export PATH="/usr/local/go/bin:$PATH"

echo "==> Go 安装完成"
go version

if [[ -n "$BACKUP" ]]; then
    echo "旧 Go 备份保留在：$BACKUP"
fi

# ---------- 可选：安装 xcaddy ----------

if [[ "$INSTALL_XCADDY" -eq 1 ]]; then
    echo "==> 安装 xcaddy 仓库所需依赖"
    apt-get install -y --no-install-recommends \
        debian-keyring \
        debian-archive-keyring \
        apt-transport-https \
        gnupg

    echo "==> 下载 xcaddy 仓库 GPG 密钥"
    curl "${CURL_ARGS[@]}" \
        "https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key" \
        -o "$WORKDIR/xcaddy-gpg.key"

    # 先在临时目录转换，再安装到目标位置，支持重复执行
    gpg --batch --yes --dearmor \
        --output "$WORKDIR/caddy-xcaddy-archive-keyring.gpg" \
        "$WORKDIR/xcaddy-gpg.key"

    echo "==> 下载 xcaddy APT 源配置"
    curl "${CURL_ARGS[@]}" \
        "https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt" \
        -o "$WORKDIR/caddy-xcaddy.list"

    [[ -s "$WORKDIR/caddy-xcaddy.list" ]] \
        || die "下载的 xcaddy APT 源配置为空"

    install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d

    install -m 0644 \
        "$WORKDIR/caddy-xcaddy-archive-keyring.gpg" \
        /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg

    install -m 0644 \
        "$WORKDIR/caddy-xcaddy.list" \
        /etc/apt/sources.list.d/caddy-xcaddy.list

    echo "==> 更新 APT 并安装 xcaddy"
    apt-get update
    apt-get install -y xcaddy

    echo "==> xcaddy 安装完成"
    xcaddy version
fi

echo
echo "全部安装完成！"
echo
echo "请在当前终端执行："
echo "  source /etc/profile.d/go.sh"
echo "  go version"

if [[ "$INSTALL_XCADDY" -eq 1 ]]; then
    echo "  xcaddy version"
fi