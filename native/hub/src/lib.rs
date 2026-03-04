//! This `hub` crate is the
//! entry point of the Rust logic.

mod actors;
mod signals;

use actors::create_actors;
use rinf::{dart_shutdown, write_interface, RustSignal};
use signals::InstanceReady;
use tokio::spawn;

write_interface!();

fn ipc_socket_path() -> std::path::PathBuf {
    let runtime_dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    std::path::PathBuf::from(runtime_dir).join("ztrans-ipc.sock")
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    // 解析 --action 参数（如：ztrans --action capture-region-translate）
    let args: Vec<String> = std::env::args().collect();
    let initial_action = args
        .iter()
        .position(|a| a == "--action")
        .and_then(|i| args.get(i + 1))
        .cloned();

    // 如果有动作参数，尝试委托给已运行的实例
    if let Some(ref action) = initial_action
        && try_delegate_to_running(action).await
    {
        // 委托成功：直接杀掉进程，Flutter 窗口永远不会出现
        std::process::exit(0);
    }

    // 主实例：通知 Dart 可以显示窗口了
    InstanceReady {}.send_signal_to_dart();

    spawn(create_actors(initial_action));
    dart_shutdown().await;
}

/// 尝试通过 Unix socket 将动作发送给已有实例，成功返回 true
async fn try_delegate_to_running(action: &str) -> bool {
    use tokio::io::AsyncWriteExt;
    let sock = ipc_socket_path();
    if let Ok(mut stream) = tokio::net::UnixStream::connect(&sock).await {
        let _ = stream.write_all(action.as_bytes()).await;
        true
    } else {
        false
    }
}
