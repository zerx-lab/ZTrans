use crate::signals::{
    AppReady, CaptureAndTranslateRequest, ShortcutCaptureResult, ShortcutTriggered,
};
use base64::{Engine, engine::general_purpose};
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

    // 等待 Dart 就绪信号，根据其配置决定是否注册 XDG 快捷键
    let ready_rx = AppReady::get_dart_signal_receiver();
    if let Some(pack) = ready_rx.recv().await
        && pack.message.use_xdg_shortcuts
    {
        tokio::spawn(listen_global_shortcuts());
    }

    // 如果启动时携带了动作参数，发送快捷键触发信号
    if let Some(action) = initial_action {
        let (selected_text, clipboard_text) = if action == "translate-clipboard" {
            read_selection_and_clipboard().await
        } else {
            (String::new(), String::new())
        };
        ShortcutTriggered {
            action,
            selected_text,
            clipboard_text,
        }
        .send_signal_to_dart();
    }

    // 主循环：处理来自 Dart 的截图请求
    let capture_rx = CaptureAndTranslateRequest::get_dart_signal_receiver();
    while let Some(pack) = capture_rx.recv().await {
        let req = pack.message;
        let client = client.clone();
        tokio::spawn(async move {
            handle_capture(client, req).await;
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
                        // 在窗口聚焦前预先读取选中文字和剪贴板
                        let (selected_text, clipboard_text) = if action == "translate-clipboard" {
                            read_selection_and_clipboard().await
                        } else {
                            (String::new(), String::new())
                        };
                        ShortcutTriggered {
                            action,
                            selected_text,
                            clipboard_text,
                        }
                        .send_signal_to_dart();
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
    let session = portal.create_session(Default::default()).await?;

    let shortcuts = [
        NewShortcut::new("capture-region-translate", "截取区域并翻译"),
        NewShortcut::new("translate-clipboard", "翻译剪贴板内容"),
    ];

    portal
        .bind_shortcuts(&session, &shortcuts, None, BindShortcutsOptions::default())
        .await?;

    debug_print!("[shortcut] 全局快捷键注册成功");

    let mut stream = portal.receive_activated().await?;
    while let Some(activated) = stream.next().await {
        let action = activated.shortcut_id().to_string();
        // 在窗口聚焦前预先读取选中文字和剪贴板
        let (selected_text, clipboard_text) = if action == "translate-clipboard" {
            read_selection_and_clipboard().await
        } else {
            (String::new(), String::new())
        };
        ShortcutTriggered {
            action,
            selected_text,
            clipboard_text,
        }
        .send_signal_to_dart();
    }

    Ok(())
}

/// 读取 primary selection（鼠标当前选中文字）和普通剪贴板内容。
/// 必须在窗口聚焦前调用，否则焦点转移可能清空 primary selection。
/// 返回 (selected_text, clipboard_text)，任一读取失败则对应为空字符串。
async fn read_selection_and_clipboard() -> (String, String) {
    // primary selection：鼠标当前选中的文字
    let selected_text = read_wl_paste(&["--primary", "--no-newline"]).await;
    // 普通剪贴板
    let clipboard_text = read_wl_paste(&["--no-newline"]).await;
    (selected_text, clipboard_text)
}

/// 调用 wl-paste 并返回去除首尾空白后的文字，失败时返回空字符串。
async fn read_wl_paste(args: &[&str]) -> String {
    use tokio::process::Command;
    match Command::new("wl-paste").args(args).output().await {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => String::new(),
    }
}

/// 使用 slurp 选区，然后截全屏并裁剪（适配 KDE Wayland）
async fn capture_region_interactive() -> Result<Vec<u8>, BoxError> {
    use tokio::process::Command;

    // Step 1: slurp 获取用户框选的区域坐标
    let slurp_out = Command::new("slurp")
        .output()
        .await
        .map_err(|_| -> BoxError { "slurp 不可用，请安装 slurp".into() })?;

    if !slurp_out.status.success() {
        return Err("截图已取消".into());
    }

    let region = String::from_utf8_lossy(&slurp_out.stdout)
        .trim()
        .to_string();
    if region.is_empty() {
        return Err("截图已取消".into());
    }

    let (x, y, w, h) = parse_slurp_region(&region)?;

    // Step 2: 优先用 grim 直接截选区（sway/wlroots 合成器）
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let tmp_path = std::env::temp_dir().join(format!("ztrans_{millis}.png"));

    let grim_ok = Command::new("grim")
        .args(["-g", &region])
        .arg(&tmp_path)
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false);

    if grim_ok && tmp_path.exists() {
        let bytes = tokio::fs::read(&tmp_path).await?;
        let _ = tokio::fs::remove_file(&tmp_path).await;
        return Ok(bytes);
    }

    // Step 3: grim 不可用（KDE Wayland 限制）→ XDG portal 截全屏 + Rust 裁剪
    debug_print!("[capture] grim 不可用，回退到 XDG portal + 裁剪");
    let full_png = capture_full_screen_portal().await?;
    crop_png_bytes(&full_png, x, y, w, h)
}

/// 解析 slurp 输出 "X,Y WxH"（坐标可能含小数）
fn parse_slurp_region(region: &str) -> Result<(u32, u32, u32, u32), BoxError> {
    let (xy_part, wh_part) = region
        .split_once(' ')
        .ok_or_else(|| -> BoxError { format!("无法解析 slurp 输出: {region}").into() })?;
    let (x_s, y_s) = xy_part
        .split_once(',')
        .ok_or_else(|| -> BoxError { format!("无法解析 slurp 坐标: {xy_part}").into() })?;
    let (w_s, h_s) = wh_part
        .split_once('x')
        .ok_or_else(|| -> BoxError { format!("无法解析 slurp 尺寸: {wh_part}").into() })?;
    Ok((
        x_s.trim().parse::<f64>()? as u32,
        y_s.trim().parse::<f64>()? as u32,
        w_s.trim().parse::<f64>()? as u32,
        h_s.trim().parse::<f64>()? as u32,
    ))
}

/// 裁剪 PNG 字节到指定区域
fn crop_png_bytes(
    full_png: &[u8],
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) -> Result<Vec<u8>, BoxError> {
    use image::GenericImageView;
    use std::io::Cursor;

    let img = image::load_from_memory(full_png)?;
    let (img_w, img_h) = img.dimensions();

    // 防止裁剪超出图像边界
    let x = x.min(img_w.saturating_sub(1));
    let y = y.min(img_h.saturating_sub(1));
    let width = width.min(img_w - x);
    let height = height.min(img_h - y);

    let cropped = img.crop_imm(x, y, width, height);
    let mut out = Vec::new();
    cropped.write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png)?;
    Ok(out)
}

/// 通过 XDG Screenshot portal 截取全屏，返回 PNG 字节
async fn capture_full_screen_portal() -> Result<Vec<u8>, BoxError> {
    use ashpd::desktop::screenshot::Screenshot;

    let response = Screenshot::request()
        .interactive(false)
        .send()
        .await?
        .response()?;

    let uri_str = response.uri().to_string();
    let path = std::path::PathBuf::from(
        uri_str
            .strip_prefix("file://")
            .ok_or_else(|| -> BoxError { format!("截图 URI 格式无效: {uri_str}").into() })?,
    );

    let bytes = tokio::fs::read(&path).await?;
    let _ = tokio::fs::remove_file(&path).await;
    Ok(bytes)
}

async fn handle_capture(client: Client, req: CaptureAndTranslateRequest) {
    let png_bytes = match capture_region_interactive().await {
        Err(e) => {
            ShortcutCaptureResult {
                text: String::new(),
                error: e.to_string(),
                request_id: req.request_id,
            }
            .send_signal_to_dart();
            return;
        }
        Ok(bytes) => bytes,
    };

    let base64_image = general_purpose::STANDARD.encode(&png_bytes);
    let ocr_result = call_ocr_api(
        &client,
        &req.ocr_base_url,
        &req.ocr_api_key,
        &req.ocr_model,
        &base64_image,
    )
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
