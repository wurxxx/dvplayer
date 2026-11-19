//! 打印某个条目下的子项（调试用）。
//!
//!   FN_USER=.. FN_PASS=.. cargo run -p dvplayer-media --example children <itemId>

use dvplayer_media::sources::FnOsSource;

fn main() {
    let base = std::env::var("FN_BASE").unwrap_or_else(|_| "http://10.0.0.134:8005".into());
    let user = std::env::var("FN_USER").expect("FN_USER");
    let pass = std::env::var("FN_PASS").expect("FN_PASS");
    let id = std::env::args().nth(1).expect("item id");

    let mut source = FnOsSource::new("probe".into(), "probe".into(), base, user, pass);
    source.login().expect("login");

    match source.children(&id, 1, 200) {
        Ok(page) => {
            println!("total={} items={}", page.total, page.items.len());
            for item in page.items.iter().take(12) {
                println!(
                    "{:?} s={:?} e={:?} dur={:?} poster={:?}\n    {:?}",
                    item.kind,
                    item.season_number,
                    item.episode_number,
                    item.runtime_seconds,
                    item.poster_path.as_deref().map(|p| &p[..p.len().min(40)]),
                    item.title
                );
            }
        }
        Err(err) => println!("ERR: {}", err),
    }
}
