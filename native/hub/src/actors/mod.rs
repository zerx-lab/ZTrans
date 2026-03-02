mod translator;

use tokio::spawn;

pub async fn create_actors() {
    let client = reqwest::Client::new();
    spawn(translator::listen_translate_requests(client));
}
