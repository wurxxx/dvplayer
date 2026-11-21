//! 本地调试用：直接调适配器，把错误原样打出来。
//!
//!   FN_USER=.. FN_PASS=.. cargo run -p dvplayer-media --example probe <itemId>

use dvplayer_media::sources::FnOsSource;

fn main() {
    let base = std::env::var("FN_BASE").unwrap_or_else(|_| "http://10.0.0.134:8005".into());
    let user = std::env::var("FN_USER").expect("FN_USER");
    let pass = std::env::var("FN_PASS").expect("FN_PASS");
    let id = std::env::args().nth(1).expect("item id");

    let mut source = FnOsSource::new("probe".into(), "probe".into(), base, user, pass, String::new());
    source.login().expect("login");

    match source.item_detail(&id) {
        Ok(detail) => println!("OK\n{:#?}", detail),
        Err(err) => println!("ERR: {}", err),
    }
}
