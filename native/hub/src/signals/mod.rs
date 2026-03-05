use rinf::{DartSignal, RustSignal};
use serde::{Deserialize, Serialize};

/// Dart 发送翻译请求到 Rust
#[derive(Deserialize, DartSignal)]
pub struct TranslateRequest {
    pub text: String,
    pub source_lang: String,
    pub target_lang: String,
    pub request_id: String,
    /// 后端: "google" 或 "openai"
    pub backend: String,
    pub openai_base_url: String,
    pub openai_api_key: String,
    pub openai_model: String,
    pub openai_thinking: bool,
    pub openai_system_prompt: String,
}

/// Rust 返回翻译结果到 Dart（Google 翻译，非流式）
#[derive(Serialize, RustSignal)]
pub struct TranslateResponse {
    pub translated_text: String,
    pub error: String,
    pub request_id: String,
}

/// Rust 返回流式翻译块到 Dart（OpenAI SSE）
#[derive(Serialize, RustSignal)]
pub struct TranslateChunk {
    pub chunk_text: String,
    pub request_id: String,
    pub is_done: bool,
    pub error: String,
}

/// Dart → Rust：Dart 端 UI 已就绪（所有 listener 已注册）
#[derive(Deserialize, DartSignal)]
pub struct AppReady {
    /// 是否通过 XDG GlobalShortcuts portal 注册全局快捷键（弹出配置界面）
    pub use_xdg_shortcuts: bool,
}

/// Rust → Dart：确认当前进程是主实例，Dart 可以显示窗口
/// 委托实例不会发送此信号（会直接 process::exit）
#[derive(Serialize, RustSignal)]
pub struct InstanceReady {}

/// Rust → Dart：全局快捷键被触发
#[derive(Serialize, RustSignal)]
pub struct ShortcutTriggered {
    /// "capture-region-translate" | "translate-clipboard"
    pub action: String,
    /// translate-clipboard 动作触发时，在窗口聚焦前读取的鼠标选中文字（primary selection）
    /// 若无选中文字则为空字符串
    pub selected_text: String,
    /// translate-clipboard 动作触发时，在窗口聚焦前读取的剪贴板文字
    /// 若读取失败则为空字符串
    pub clipboard_text: String,
}

/// Dart → Rust：执行截图 + OCR
#[derive(Deserialize, DartSignal)]
pub struct CaptureAndTranslateRequest {
    pub request_id: String,
    pub ocr_model: String,
    pub ocr_base_url: String,
    pub ocr_api_key: String,
}

/// Rust → Dart：截图 OCR 进度/结果信号
/// - status: "capturing" | "ocr" | "done" | "error"
///   capturing = 正在截图选区
///   ocr       = 正在调用 OCR 识别
///   done      = 识别完成（text 有值）
///   error     = 出错（error 有值）
#[derive(Serialize, RustSignal)]
pub struct ShortcutCaptureResult {
    pub text: String,
    pub error: String,
    pub request_id: String,
    /// 当前阶段: "capturing" | "ocr" | "done" | "error"
    pub status: String,
}
