use crate::signals::{
    AppReady, CaptureAndTranslateRequest, ScreenCaptureCancelled, ScreenCaptureReady,
    ScreenRegionSelected, ShortcutCaptureResult, ShortcutTriggered,
};
use base64::{engine::general_purpose, Engine};
use futures_util::StreamExt;
use reqwest::Client;
use rinf::{DartSignal, RustSignal, debug_print};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

fn ipc_socket_path() -> std::path::PathBuf {
    let runtime_dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    std::path::PathBuf::from(runtime_dir).join("ztrans-ipc.sock")
}

pub async fn run_shortcut_service(client: Client, initial_action: Option<String>) {
    // 后台任务：Unix socket IPC 监听（接收来自新启动实例的命令）
    tokio::spawn(listen_ipc_socket());

    // 后台任务：XDG GlobalShortcuts portal（应用运行时的全局快捷键）
    tokio::spawn(listen_global_shortcuts());

    // 如果启动时携带了动作参数，等待 Dart 就绪握手后再触发
    if let Some(action) = initial_action {
        let ready_rx = AppReady::get_dart_signal_receiver();
        if ready_rx.recv().await.is_some() {
            ShortcutTriggered { action }.send_signal_to_dart();
        }
    }

    // 主循环：处理来自 Dart 的截图请求
    let capture_rx = CaptureAndTranslateRequest::get_dart_signal_receiver();
    let region_rx = ScreenRegionSelected::get_dart_signal_receiver();
    let cancel_rx = ScreenCaptureCancelled::get_dart_signal_receiver();

    // 用 channel 将选区结果/取消事件路由到正在等待的截图任务
    let (region_tx, region_bcast_rx) =
        tokio::sync::broadcast::channel::<Option<(String, Vec<u8>)>>(4);
    let region_tx2 = region_tx.clone();

    // 转发 ScreenRegionSelected → broadcast
    tokio::spawn(async move {
        while let Some(pack) = region_rx.recv().await {
            let msg = pack.message;
            let _ = region_tx.send(Some((msg.request_id, msg.png_bytes)));
        }
    });

    // 转发 ScreenCaptureCancelled → broadcast（None 表示取消）
    tokio::spawn(async move {
        while let Some(pack) = cancel_rx.recv().await {
            let _ = region_tx2.send(None);
            drop(pack); // request_id 忽略，仅用于唤醒等待者
        }
    });

    while let Some(pack) = capture_rx.recv().await {
        let req = pack.message;
        let client = client.clone();
        let mut rx = region_bcast_rx.resubscribe();
        let req_id = req.request_id.clone();
        tokio::spawn(async move {
            handle_capture(client, req, req_id, &mut rx).await;
        });
    }
}

/// 监听 Unix socket，将收到的动作转发为 ShortcutTriggered 信号
async fn listen_ipc_socket() {
    use tokio::io::AsyncReadExt;
    let sock_path = ipc_socket_path();
    let _ = tokio::fs::remove_file(&sock_path).await;
    let listener = match tokio::net::UnixListener::bind(&sock_path) {
        Ok(l) => l,
        Err(e) => {
            debug_print!("[ipc] 无法绑定 socket: {e}");
            return;
        }
    };
    loop {
        match listener.accept().await {
            Ok((mut stream, _)) => {
                let mut buf = Vec::new();
                if stream.read_to_end(&mut buf).await.is_ok() {
                    let action = String::from_utf8_lossy(&buf).trim().to_string();
                    if !action.is_empty() {
                        ShortcutTriggered { action }.send_signal_to_dart();
                    }
                }
            }
            Err(e) => debug_print!("[ipc] 接受连接失败: {e}"),
        }
    }
}

async fn listen_global_shortcuts() {
    match try_register_shortcuts().await {
        Ok(()) => {}
        Err(e) => debug_print!("[shortcut] 全局快捷键注册失败: {e}"),
    }
}

async fn try_register_shortcuts() -> Result<(), BoxError> {
    use ashpd::desktop::global_shortcuts::{BindShortcutsOptions, GlobalShortcuts, NewShortcut};

    let portal = GlobalShortcuts::new().await?;
    // CreateSessionOptions 在私有模块，通过类型推断传入 Default
    let session = portal.create_session(Default::default()).await?;

    let shortcuts = [
        NewShortcut::new("capture-region-translate", "截取区域并翻译"),
        NewShortcut::new("translate-clipboard", "翻译剪贴板内容"),
    ];

    portal
        .bind_shortcuts(
            &session,
            &shortcuts,
            None,
            BindShortcutsOptions::default(),
        )
        .await?;

    debug_print!("[shortcut] 全局快捷键注册成功");

    let mut stream = portal.receive_activated().await?;
    while let Some(activated) = stream.next().await {
        ShortcutTriggered {
            action: activated.shortcut_id().to_string(),
        }
        .send_signal_to_dart();
    }

    Ok(())
}

async fn handle_capture(
    client: Client,
    req: CaptureAndTranslateRequest,
    req_id: String,
    region_rx: &mut tokio::sync::broadcast::Receiver<Option<(String, Vec<u8>)>>,
) {
    // Phase 1: 通过 XDG portal 截全屏，发送给 Dart 显示选区界面
    let png_result = capture_full_screen().await;
    match png_result {
        Err(e) => {
            ShortcutCaptureResult {
                text: String::new(),
                error: e.to_string(),
                request_id: req.request_id,
            }
            .send_signal_to_dart();
            return;
        }
        Ok(png_bytes) => {
            ScreenCaptureReady {
                request_id: req_id.clone(),
                png_bytes,
                error: String::new(),
            }
            .send_signal_to_dart();
        }
    }

    // Phase 2: 等待 Dart 返回用户选择的区域（裁剪后的 PNG）
    // 超时 60 秒，超时或取消则中止
    let region_result = tokio::time::timeout(
        std::time::Duration::from_secs(60),
        wait_for_region(region_rx, &req_id),
    )
    .await;

    let cropped_png = match region_result {
        Err(_) => {
            // 超时
            ShortcutCaptureResult {
                text: String::new(),
                error: "截图选区超时".to_string(),
                request_id: req.request_id,
            }
            .send_signal_to_dart();
            return;
        }
        Ok(None) => {
            // 用户取消
            ShortcutCaptureResult {
                text: String::new(),
                error: "截图已取消".to_string(),
                request_id: req.request_id,
            }
            .send_signal_to_dart();
            return;
        }
        Ok(Some(bytes)) => bytes,
    };

    // Phase 3: OCR
    let base64_image = general_purpose::STANDARD.encode(&cropped_png);
    let ocr_result =
        call_ocr_api(&client, &req.ocr_base_url, &req.ocr_api_key, &req.ocr_model, &base64_image)
            .await;

    match ocr_result {
        Ok(text) => ShortcutCaptureResult {
            text,
            error: String::new(),
            request_id: req.request_id,
        }
        .send_signal_to_dart(),
        Err(e) => ShortcutCaptureResult {
            text: String::new(),
            error: e.to_string(),
            request_id: req.request_id,
        }
        .send_signal_to_dart(),
    }
}

/// 等待 broadcast 中属于本次请求的选区结果，忽略其他请求的消息
async fn wait_for_region(
    rx: &mut tokio::sync::broadcast::Receiver<Option<(String, Vec<u8>)>>,
    req_id: &str,
) -> Option<Vec<u8>> {
    loop {
        match rx.recv().await {
            Ok(None) => return None, // 取消信号（不含 request_id）
            Ok(Some((id, bytes))) if id == req_id => return Some(bytes),
            Ok(Some(_)) => continue, // 其他请求的消息，忽略
            Err(_) => return None,   // channel 关闭
        }
    }
}

/// 通过 XDG Screenshot portal 截取全屏，返回 PNG 字节
async fn capture_full_screen() -> Result<Vec<u8>, BoxError> {
    use ashpd::desktop::screenshot::Screenshot;

    let response = Screenshot::request()
        .interactive(false)
        .send()
        .await?
        .response()?;

    let uri = response.uri();
    // portal 返回 file:// URI，转换为路径
    // ashpd::Uri → file path（strip "file://" prefix）
    let uri_str = uri.to_string();
    let path = std::path::PathBuf::from(
        uri_str
            .strip_prefix("file://")
            .ok_or_else(|| -> BoxError { format!("截图 URI 格式无效: {uri_str}").into() })?,
    );

    let bytes = tokio::fs::read(&path).await?;
    // 删除 portal 生成的临时文件
    let _ = tokio::fs::remove_file(&path).await;
    Ok(bytes)
}

/// 调用 OpenAI 兼容 vision API 进行 OCR
async fn call_ocr_api(
    client: &Client,
    base_url: &str,
    api_key: &str,
    model: &str,
    base64_image: &str,
) -> Result<String, BoxError> {
    let url = format!("{}/chat/completions", base_url.trim_end_matches('/'));

    let body = serde_json::json!({
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {
                    "type": "image_url",
                    "image_url": {
                        "url": format!("data:image/png;base64,{}", base64_image)
                    }
                },
                {
                    "type": "text",
                    "text": "识别图片中所有文字，原样输出文字内容，不添加任何说明或格式。"
                }
            ]
        }],
        "max_tokens": 2048
    });

    let resp = client
        .post(&url)
        .header("Authorization", format!("Bearer {api_key}"))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await?;

    if !resp.status().is_success() {
        let status = resp.status();
        let err_text = resp.text().await.unwrap_or_default();
        return Err(format!("OCR API 错误 {status}: {err_text}").into());
    }

    let json: serde_json::Value = resp.json().await?;
    json["choices"][0]["message"]["content"]
        .as_str()
        .ok_or_else(|| -> BoxError { "OCR 响应格式异常".into() })
        .map(|s| s.trim().to_string())
}
