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
