use crate::signals::{TranslateChunk, TranslateRequest, TranslateResponse};
use futures_util::StreamExt;
use reqwest::Client;
use rinf::{DartSignal, RustSignal};

const DEFAULT_SYSTEM_PROMPT: &str =
    "你是专业翻译助手。请将给定文本准确、自然地翻译成目标语言。只输出翻译结果，不附加解释或说明。";

struct OpenAiConfig {
    base_url: String,
    api_key: String,
    model: String,
    enable_thinking: bool,
    system_prompt: String,
}

pub async fn listen_translate_requests(client: Client) {
    let receiver = TranslateRequest::get_dart_signal_receiver();
    while let Some(signal) = receiver.recv().await {
        let req = signal.message;
        let client = client.clone();
        tokio::spawn(async move {
            if req.backend == "openai" {
                let cfg = OpenAiConfig {
                    base_url: req.openai_base_url.clone(),
                    api_key: req.openai_api_key.clone(),
                    model: req.openai_model.clone(),
                    enable_thinking: req.openai_thinking,
                    system_prompt: req.openai_system_prompt.clone(),
                };
                let result = translate_openai(
                    &client,
                    &req.text,
                    &req.source_lang,
                    &req.target_lang,
                    &req.request_id,
                    &cfg,
                )
                .await;
                if let Err(e) = result {
                    TranslateChunk {
                        chunk_text: String::new(),
                        request_id: req.request_id,
                        is_done: true,
                        error: e.to_string(),
                    }
                    .send_signal_to_dart();
                }
            } else {
                let result =
                    translate_google(&client, &req.text, &req.source_lang, &req.target_lang).await;
                match result {
                    Ok(translated) => {
                        TranslateResponse {
                            translated_text: translated,
                            error: String::new(),
                            request_id: req.request_id,
                        }
                        .send_signal_to_dart();
                    }
                    Err(e) => {
                        TranslateResponse {
                            translated_text: String::new(),
                            error: e.to_string(),
                            request_id: req.request_id,
                        }
                        .send_signal_to_dart();
                    }
                }
            }
        });
    }
}

async fn translate_google(
    client: &Client,
    text: &str,
    source_lang: &str,
    target_lang: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let encoded = urlencoding::encode(text);
    let url = format!(
        "https://translate.googleapis.com/translate_a/single?client=gtx&sl={}&tl={}&dt=t&q={}",
        source_lang, target_lang, encoded
    );

    let body: serde_json::Value = client.get(&url).send().await?.json().await?;

    // Google translate free API 格式：[[["translated","original",null,null,1]],null,"en"]
    let mut result = String::new();
    if let Some(outer) = body.get(0).and_then(|v| v.as_array()) {
        for segment in outer {
            if let Some(t) = segment.get(0).and_then(|v| v.as_str()) {
                result.push_str(t);
            }
        }
    }

    if result.is_empty() {
        return Err("翻译结果为空".into());
    }

    Ok(result)
}

fn lang_code_to_name(code: &str) -> &str {
    match code {
        "zh-CN" | "zh" => "中文（简体）",
        "en" => "English",
        "ja" => "日本語",
        "ko" => "한국어",
        "fr" => "Français",
        "de" => "Deutsch",
        "es" => "Español",
        "ru" => "Русский",
        other => other,
    }
}

async fn translate_openai(
    client: &Client,
    text: &str,
    source_lang: &str,
    target_lang: &str,
    request_id: &str,
    cfg: &OpenAiConfig,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let url = format!("{}/chat/completions", cfg.base_url.trim_end_matches('/'));
    let target_name = lang_code_to_name(target_lang);

    let system_content = if cfg.system_prompt.trim().is_empty() {
        DEFAULT_SYSTEM_PROMPT
    } else {
        cfg.system_prompt.trim()
    };
    let user_content = if source_lang == "auto" {
        format!("请将以下内容翻译为{}：\n\n{}", target_name, text)
    } else {
        let source_name = lang_code_to_name(source_lang);
        format!("请将以下{}内容翻译为{}：\n\n{}", source_name, target_name, text)
    };

    let mut body = serde_json::json!({
        "model": cfg.model,
        "messages": [
            {"role": "system", "content": system_content},
            {"role": "user", "content": user_content}
        ],
        "stream": true
    });

    if cfg.enable_thinking {
        body["enable_thinking"] = serde_json::Value::Bool(true);
        body["thinking_budget"] = serde_json::Value::Number(2048.into());
    }

    let response = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", cfg.api_key))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let err_text = response.text().await.unwrap_or_default();
        return Err(format!("API 错误 {}: {}", status, err_text).into());
    }

    let mut stream = response.bytes_stream();
    let mut buffer = String::new();

    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        buffer.push_str(&String::from_utf8_lossy(&chunk));

        while let Some(pos) = buffer.find('\n') {
            let line = buffer[..pos].trim().to_string();
            buffer = buffer[pos + 1..].to_string();

            if !line.starts_with("data: ") {
                continue;
            }
            let data = line[6..].trim();
            if data == "[DONE]" {
                TranslateChunk {
                    chunk_text: String::new(),
                    request_id: request_id.to_string(),
                    is_done: true,
                    error: String::new(),
                }
                .send_signal_to_dart();
                return Ok(());
            }
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(data) {
                // 跳过 reasoning_content（思考内容），只发送实际 content
                if let Some(content) = json["choices"][0]["delta"]["content"].as_str()
                    && !content.is_empty()
                {
                    TranslateChunk {
                        chunk_text: content.to_string(),
                        request_id: request_id.to_string(),
                        is_done: false,
                        error: String::new(),
                    }
                    .send_signal_to_dart();
                }
            }
        }
    }

    // 流结束但未收到 [DONE]
    TranslateChunk {
        chunk_text: String::new(),
        request_id: request_id.to_string(),
        is_done: true,
        error: String::new(),
    }
    .send_signal_to_dart();

    Ok(())
}
