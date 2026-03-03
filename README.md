# ztrans

Linux 桌面翻译工具，紧凑弹窗模式，使用 Flutter + Rust（Rinf）构建。

启动时自动读取剪贴板内容，失焦后退出，适合绑定快捷键快速调用。

## 功能

- **双翻译后端**：Google 翻译（免费）/ OpenAI 兼容接口（SSE 流式）
- **自动读取剪贴板**：启动时优先获取 PRIMARY selection，回退到 CLIPBOARD
- **流式输出**：OpenAI 后端逐 token 实时显示翻译结果
- **思考模式**：支持开启 OpenAI reasoning（如 deepseek-reasoner）
- **多主题**：Light / Dark / One Dark Pro
- **输入防抖**：600ms 自动触发，`Ctrl+Enter` 立即翻译
- **轻量窗口**：450×680 无边框置顶，不占任务栏，失焦自动退出
- **KDE 6 Wayland 定位**：附带 KWin 脚本，可将弹窗锚定到鼠标下方（空间不足时自动翻到上方）

## 构建依赖

- [Flutter SDK](https://docs.flutter.dev/get-started/install)（含 Linux desktop 支持）
- [Rust toolchain](https://www.rust-lang.org/tools/install)
- [Rinf CLI](https://rinf.cunarist.org)

```bash
cargo install rinf_cli
flutter doctor   # 确认 Linux desktop 工具链就绪
```

## 运行与构建

```bash
flutter run -d linux          # 调试模式
flutter build linux           # 发布构建，产物在 build/linux/x64/release/bundle/
```

## KDE Plasma 6 / Wayland

Wayland 下普通应用不能可靠地自行设置顶层窗口的绝对屏幕位置，因此 KDE 6 需要启用仓库内附带的 KWin 脚本来完成“快捷键呼出后贴近鼠标”的定位。

如果你是通过 `packaging/build-arch.sh` 构建并安装的包，KWin 脚本会被安装到系统目录 `/usr/share/kwin/scripts/ztrans_popup`。如果你是在开发环境直接运行仓库代码，可手动安装脚本包：

安装脚本包：

```bash
bash packaging/kde/install-kwin-script.sh
```

然后在 `系统设置 > 窗口管理 > KWin 脚本` 中启用 `ZTrans Popup Anchor`。

启用后，继续把 KDE 的全局快捷键绑定到：

```bash
ztrans
```

脚本会在窗口出现时自动将它放到鼠标所在位置的下方；如果下方空间不足，则自动放到鼠标上方。

## 修改 Rust 信号后

编辑 `native/hub/src/signals/mod.rs` 后必须重新生成 Dart 绑定：

```bash
rinf gen
```

## 项目结构

```
lib/
  src/
    pages/         # UI 页面（home_page.dart）
    settings/      # 设置状态（SettingsProvider）
    themes/        # 主题定义
    widgets/       # 自定义组件（TitleBar 等）
    bindings/      # 自动生成，勿手动编辑
native/hub/
  src/
    actors/        # Rust Actor（translator.rs）
    signals/       # Rinf 信号定义（mod.rs）
packaging/arch/    # Arch Linux PKGBUILD
```

## Arch Linux 打包

```bash
# 依赖：flutter、makepkg（base-devel）、rsvg-convert（librsvg）
bash packaging/build-arch.sh
# 生成 packaging/arch/build/ztrans-*.pkg.tar.zst
sudo pacman -U packaging/arch/build/ztrans-*.pkg.tar.zst
```

## 技术栈

| 层 | 技术 |
|---|---|
| UI | Flutter / Dart |
| 后端 | Rust + tokio（current_thread） |
| IPC | [Rinf](https://rinf.cunarist.org)（bincode 序列化） |
| 状态管理 | ChangeNotifier + SharedPreferences |
| 翻译 | Google Translate（免费）/ OpenAI 兼容 SSE |
