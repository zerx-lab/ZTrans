use rinf::{DartSignal, RustSignal};
use serde::{Deserialize, Serialize};

/// Dart 发送翻译请求到 Rust
#[derive(Deserialize, DartSignal)]
pub struct TranslateRequest {
    pub text: String,
    pub source_lang: String,
    pub target_lang: String,
}

/// Rust 返回翻译结果到 Dart
#[derive(Serialize, RustSignal)]
pub struct TranslateResponse {
    pub translated_text: String,
    pub error: String,
}
