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
- **轻量窗口**：640×300 无边框置顶，不占任务栏，失焦自动退出

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
cd packaging/arch
makepkg -si
```

## 技术栈

| 层 | 技术 |
|---|---|
| UI | Flutter / Dart |
| 后端 | Rust + tokio（current_thread） |
| IPC | [Rinf](https://rinf.cunarist.org)（bincode 序列化） |
| 状态管理 | ChangeNotifier + SharedPreferences |
| 翻译 | Google Translate（免费）/ OpenAI 兼容 SSE |
