#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# ZTrans Arch Linux 打包脚本
# 构建 Flutter 应用并生成 .pkg.tar.zst 安装包
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCH_DIR="$SCRIPT_DIR/arch"
BUILD_DIR="$ARCH_DIR/build"

# 颜色输出
info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; }
ok()    { printf '\033[1;32m[OK]\033[0m %s\n' "$1"; }
err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$1" >&2; exit 1; }

# ── 检查依赖 ──────────────────────────────────
check_deps() {
    local missing=()
    command -v flutter   >/dev/null || missing+=(flutter)
    command -v makepkg   >/dev/null || missing+=(makepkg)
    command -v rsvg-convert >/dev/null || missing+=(rsvg-convert)

    if (( ${#missing[@]} )); then
        echo "缺少以下工具: ${missing[*]}"
        echo ""
        echo "安装方式:"
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                flutter)       echo "  flutter      → 安装 flutter SDK" ;;
                makepkg)       echo "  makepkg      → pacman -S base-devel" ;;
                rsvg-convert)  echo "  rsvg-convert → pacman -S librsvg" ;;
            esac
        done
        exit 1
    fi
}

# ── 构建 Flutter 应用 ────────────────────────
build_flutter() {
    info "构建 Flutter Linux release..."
    cd "$PROJECT_ROOT"
    flutter build linux --release
    ok "Flutter 构建完成"
}

# ── 生成图标 ──────────────────────────────────
generate_icons() {
    local svg="$PROJECT_ROOT/assets/logo.svg"
    local icon_dir="$BUILD_DIR/src/icons"

    if [[ ! -f "$svg" ]]; then
        err "找不到 $svg"
    fi

    info "从 SVG 生成 PNG 图标..."
    mkdir -p "$icon_dir"

    # 复制 SVG 原文件
    cp "$svg" "$icon_dir/ztrans.svg"

    # 生成各尺寸 PNG
    for size in 16 32 48 64 128 256 512; do
        rsvg-convert -w "$size" -h "$size" "$svg" -o "$icon_dir/ztrans-${size}.png"
    done

    ok "图标生成完成"
}

# ── 准备 makepkg 源目录 ──────────────────────
prepare_source() {
    local bundle_src="$PROJECT_ROOT/build/linux/x64/release/bundle"
    local kwin_script_src="$PROJECT_ROOT/packaging/kde/kwin/ztrans_popup"

    if [[ ! -d "$bundle_src" ]]; then
        err "找不到构建产物: $bundle_src"
    fi
    if [[ ! -d "$kwin_script_src" ]]; then
        err "找不到 KWin 脚本: $kwin_script_src"
    fi

    info "准备打包源文件..."

    # 清理旧构建
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/src"

    # 复制 Flutter 构建产物
    cp -a "$bundle_src" "$BUILD_DIR/src/bundle"

    # 复制 .desktop 文件
    cp "$ARCH_DIR/ztrans.desktop" "$BUILD_DIR/src/"

    # 复制 KWin 脚本
    mkdir -p "$BUILD_DIR/src/kwin"
    cp -a "$kwin_script_src" "$BUILD_DIR/src/kwin/"

    # 复制 PKGBUILD
    cp "$ARCH_DIR/PKGBUILD" "$BUILD_DIR/"

    ok "源文件准备完成"
}

# ── 执行 makepkg ─────────────────────────────
run_makepkg() {
    info "运行 makepkg..."
    cd "$BUILD_DIR"
    makepkg -f
    ok "打包完成!"

    # 显示生成的包
    local pkg
    pkg=$(ls -1 "$BUILD_DIR"/*.pkg.tar.zst 2>/dev/null | head -1)
    if [[ -n "$pkg" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  安装包: $pkg"
        echo "  安装:   sudo pacman -U $pkg"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# ── 主流程 ────────────────────────────────────
main() {
    info "开始 ZTrans Arch Linux 打包"
    echo ""

    check_deps
    build_flutter
    prepare_source
    generate_icons
    run_makepkg
}

main "$@"
