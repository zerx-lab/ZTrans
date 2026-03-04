mod shortcut_service;
mod translator;

use tokio::spawn;

pub async fn create_actors(initial_action: Option<String>) {
    let client = reqwest::Client::new();
    spawn(translator::listen_translate_requests(client.clone()));
    spawn(shortcut_service::run_shortcut_service(client, initial_action));
}
