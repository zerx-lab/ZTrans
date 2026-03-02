use crate::signals::{TranslateRequest, TranslateResponse};
use reqwest::Client;
use rinf::{DartSignal, RustSignal};

pub async fn listen_translate_requests(client: Client) {
    let receiver = TranslateRequest::get_dart_signal_receiver();
    while let Some(signal) = receiver.recv().await {
        let req = signal.message;
        let client = client.clone();
        tokio::spawn(async move {
            let result =
                translate(&client, &req.text, &req.source_lang, &req.target_lang).await;
            match result {
                Ok(translated) => {
                    TranslateResponse {
                        translated_text: translated,
                        error: String::new(),
                    }
                    .send_signal_to_dart();
                }
                Err(e) => {
                    TranslateResponse {
                        translated_text: String::new(),
                        error: e.to_string(),
                    }
                    .send_signal_to_dart();
                }
            }
        });
    }
}

async fn translate(
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
