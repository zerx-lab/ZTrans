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
pub struct AppReady {}

/// Rust → Dart：确认当前进程是主实例，Dart 可以显示窗口
/// 委托实例不会发送此信号（会直接 process::exit）
#[derive(Serialize, RustSignal)]
pub struct InstanceReady {}

/// Rust → Dart：全局快捷键被触发
#[derive(Serialize, RustSignal)]
pub struct ShortcutTriggered {
    /// "capture-region-translate" | "translate-clipboard"
    pub action: String,
}

/// Dart → Rust：执行截图 + OCR
#[derive(Deserialize, DartSignal)]
pub struct CaptureAndTranslateRequest {
    pub request_id: String,
    pub ocr_model: String,
    pub ocr_base_url: String,
    pub ocr_api_key: String,
}

/// Rust → Dart：截图 OCR 识别结果（填入翻译框）
#[derive(Serialize, RustSignal)]
pub struct ShortcutCaptureResult {
    pub text: String,
    pub error: String,
    pub request_id: String,
}

/// Rust → Dart：全屏截图已就绪，Dart 应显示选区界面
#[derive(Serialize, RustSignal)]
pub struct ScreenCaptureReady {
    pub request_id: String,
    pub png_bytes: Vec<u8>,
    pub error: String,
}

/// Dart → Rust：用户已框选区域，发送裁剪后的 PNG 进行 OCR
#[derive(Deserialize, DartSignal)]
pub struct ScreenRegionSelected {
    pub request_id: String,
    pub png_bytes: Vec<u8>,
}

/// Dart → Rust：用户取消了截图选区
#[derive(Deserialize, DartSignal)]
pub struct ScreenCaptureCancelled {
    #[allow(dead_code)]
    pub request_id: String,
}
