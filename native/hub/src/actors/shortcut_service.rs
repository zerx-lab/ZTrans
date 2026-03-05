use crate::signals::{
    AppReady, CaptureAndTranslateRequest, ShortcutCaptureResult, ShortcutTriggered,
};
use base64::{Engine, engine::general_purpose};
use futures_util::StreamExt;
use reqwest::Client;
use rinf::{DartSignal, RustSignal, debug_print};
use std::time::Duration;

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
    // 阶段 1：通知 Dart 正在截图选区
    ShortcutCaptureResult {
        text: String::new(),
        error: String::new(),
        request_id: req.request_id.clone(),
        status: "capturing".to_string(),
    }
    .send_signal_to_dart();

    let png_bytes = match capture_region_interactive().await {
        Err(e) => {
            ShortcutCaptureResult {
                text: String::new(),
                error: e.to_string(),
                request_id: req.request_id,
                status: "error".to_string(),
            }
            .send_signal_to_dart();
            return;
        }
        Ok(bytes) => bytes,
    };

    // 检查图片尺寸，部分 OCR 模型（如 Deepseek）要求宽高均 >= 28px
    if let Err(e) = check_image_size(&png_bytes) {
        ShortcutCaptureResult {
            text: String::new(),
            error: e.to_string(),
            request_id: req.request_id,
            status: "error".to_string(),
        }
        .send_signal_to_dart();
        return;
    }

    // 阶段 2：通知 Dart 正在 OCR 识别
    ShortcutCaptureResult {
        text: String::new(),
        error: String::new(),
        request_id: req.request_id.clone(),
        status: "ocr".to_string(),
    }
    .send_signal_to_dart();

    let base64_image = general_purpose::STANDARD.encode(&png_bytes);

    // OCR API 调用加 60 秒超时，防止永久挂起
    let ocr_result = tokio::time::timeout(
        Duration::from_secs(60),
        call_ocr_api(
            &client,
            &req.ocr_base_url,
            &req.ocr_api_key,
            &req.ocr_model,
            &base64_image,
        ),
    )
    .await;

    let ocr_result = match ocr_result {
        Err(_) => Err(Box::<dyn std::error::Error + Send + Sync>::from(
            "OCR 识别超时（超过 60 秒），请检查网络或 API 配置",
        )),
        Ok(inner) => inner,
    };

    match ocr_result {
        Ok(text) => ShortcutCaptureResult {
            text,
            error: String::new(),
            request_id: req.request_id,
            status: "done".to_string(),
        }
        .send_signal_to_dart(),
        Err(e) => ShortcutCaptureResult {
            text: String::new(),
            error: e.to_string(),
            request_id: req.request_id,
            status: "error".to_string(),
        }
        .send_signal_to_dart(),
    }
}

/// 检查 PNG 图片的宽高是否满足最低要求（宽和高均需 >= 28px）
fn check_image_size(png_bytes: &[u8]) -> Result<(), BoxError> {
    use image::GenericImageView;

    let img = image::load_from_memory_with_format(png_bytes, image::ImageFormat::Png)
        .map_err(|e| -> BoxError { format!("无法解析截图：{e}").into() })?;
    let (w, h) = img.dimensions();
    if w < 28 || h < 28 {
        return Err(
            format!("截图区域太小（{w}×{h}px），请框选更大的区域（宽和高均需至少 28px）").into(),
        );
    }
    Ok(())
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
        "messages": [
            {
                "role": "system",
                "content": "你是OCR工具。将图片中人眼可见的文字原样输出，只输出纯文本，不输出任何标签、代码、标点装饰或链接语法。"
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": format!("data:image/png;base64,{}", base64_image)
                        }
                    }
                ]
            }
        ],
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

    /// 清洗 OCR 结果中残留的 HTML 标签和 Markdown 语法符号，返回纯文本。
    ///
    /// 处理顺序：
    /// 1. 去除 HTML/XML 标签（块级标签转换为换行，其余直接删除）
    /// 2. 去除 Markdown 行级装饰（标题 #、列表 -/*/+、分割线 ---、代码围栏 ```）
    /// 3. 去除 Markdown 行内装饰（反引号、粗斜体 */_、[text](url) 链接只保留 label）
    /// 4. 合并多余空行
    fn strip_markup(text: &str) -> String {
        // ── 第一步：去除 HTML 标签 ──────────────────────────────────────
        let mut buf = String::with_capacity(text.len());
        let mut chars = text.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch != '<' {
                buf.push(ch);
                continue;
            }
            let mut tag = String::new();
            let mut closed = false;
            for inner in chars.by_ref() {
                if inner == '>' {
                    closed = true;
                    break;
                }
                tag.push(inner);
            }
            if !closed {
                buf.push('<');
                buf.push_str(&tag);
                continue;
            }
            let tag_name = tag
                .trim_start_matches('/')
                .split_whitespace()
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();
            match tag_name.as_str() {
                "p" | "br" | "div" | "tr" | "li" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6"
                | "blockquote" | "pre" | "hr" => {
                    if !buf.ends_with('\n') {
                        buf.push('\n');
                    }
                }
                _ => {}
            }
        }

        // ── 第二步：逐行处理 Markdown 行级语法 ─────────────────────────
        let mut line_buf = String::with_capacity(buf.len());
        for line in buf.lines() {
            let t = line.trim();

            // 跳过纯分割线（--- / *** / ===，至少 3 个相同字符）
            if t.len() >= 3 && t.chars().all(|c| c == '-' || c == '*' || c == '=') {
                continue;
            }

            // 跳过代码围栏行（``` 或 ~~~）
            if t.starts_with("```") || t.starts_with("~~~") {
                continue;
            }

            // 去掉行首 Markdown 标题 # 符号
            let t = t.trim_start_matches('#').trim_start();

            // 去掉行首无序列表符号（- / * / + 后跟空格）
            let t = if (t.starts_with("- ") || t.starts_with("* ") || t.starts_with("+ "))
                && t.len() > 2
            {
                t[2..].trim_start()
            } else {
                t
            };

            // 去掉行首有序列表符号（"1. " / "12. " 等）
            let t = if let Some(pos) = t.find(". ") {
                let prefix = &t[..pos];
                if !prefix.is_empty() && prefix.chars().all(|c| c.is_ascii_digit()) {
                    t[pos + 2..].trim_start()
                } else {
                    t
                }
            } else {
                t
            };

            if !t.is_empty() {
                line_buf.push_str(t);
                line_buf.push('\n');
            } else {
                line_buf.push('\n');
            }
        }

        // ── 第三步：去除行内 Markdown 语法 ─────────────────────────────
        // [label](url)  →  label
        let mut inline = String::with_capacity(line_buf.len());
        let mut chars = line_buf.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch == '[' {
                // 收集 label
                let mut label = String::new();
                let mut found_bracket = false;
                for c in chars.by_ref() {
                    if c == ']' {
                        found_bracket = true;
                        break;
                    }
                    label.push(c);
                }
                if found_bracket && chars.peek() == Some(&'(') {
                    // 消费 (url)
                    chars.next(); // '('
                    let mut depth = 1u32;
                    for c in chars.by_ref() {
                        if c == '(' {
                            depth += 1;
                        }
                        if c == ')' {
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                        }
                    }
                    inline.push_str(&label);
                } else {
                    // 不是链接语法，原样保留
                    inline.push('[');
                    inline.push_str(&label);
                    if found_bracket {
                        inline.push(']');
                    }
                }
                continue;
            }
            inline.push(ch);
        }

        // 去掉行内反引号、粗斜体符号（` * _ ~~ ）
        let mut cleaned = String::with_capacity(inline.len());
        let mut chars = inline.chars().peekable();
        while let Some(ch) = chars.next() {
            match ch {
                '`' => {}       // 直接丢弃
                '*' | '_' => {} // 直接丢弃（粗/斜体）
                '~' if chars.peek() == Some(&'~') => {
                    chars.next(); // 丢弃第二个 ~（删除线）
                }
                _ => cleaned.push(ch),
            }
        }

        // ── 第四步：合并多余空行（最多保留一个空行）───────────────────
        let mut result = String::with_capacity(cleaned.len());
        let mut blank_count = 0u32;
        for line in cleaned.lines() {
            if line.trim().is_empty() {
                blank_count += 1;
                if blank_count <= 1 {
                    result.push('\n');
                }
            } else {
                blank_count = 0;
                result.push_str(line);
                result.push('\n');
            }
        }

        result.trim().to_string()
    }

    let json: serde_json::Value = resp.json().await?;
    let raw = json["choices"][0]["message"]["content"]
        .as_str()
        .ok_or_else(|| -> BoxError { "OCR 响应格式异常".into() })?
        .trim()
        .to_string();

    Ok(strip_markup(&raw))
}
