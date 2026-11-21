//! 扫一个本地目录，打印媒体库会出现的条目（调试用）。
//!
//!   cargo run -p dvplayer-media --example local -- /path/to/dir

use dvplayer_media::models::{ListQuery, MediaKind};
use dvplayer_media::sources::LocalSource;
use dvplayer_media::sources::MediaSource;

fn main() {
    let root = std::env::args().nth(1).expect("usage: local <dir-or-file>");
    let mut source = LocalSource::new(
        "local-probe".into(),
        "本地文件".into(),
        root.clone(),
        String::new(),
    );

    if let Err(err) = source.login() {
        println!("ERR: {err}");
        return;
    }

    for lib in source.libraries().unwrap() {
        println!("library {} {}", lib.id, lib.title);
    }

    let page = source
        .items("local", 1, 200, &ListQuery::default())
        .unwrap();
    println!("items total={} shown={}", page.total, page.items.len());

    for item in &page.items {
        println!(
            "{} {:?} year={:?} seasons={:?} episodes={:?} poster={:?}\n    {}",
            item.id,
            item.kind,
            item.year,
            item.season_count,
            item.episode_count,
            item.poster_path.is_some(),
            item.title
        );

        if item.kind == MediaKind::Series {
            let seasons = source.children(&item.id, 1, 200, &ListQuery::default()).unwrap();
            for season in &seasons.items {
                println!("    {:?} {}", season.kind, season.title);
                let episodes = source
                    .children(&season.id, 1, 200, &ListQuery::default())
                    .unwrap();
                for episode in episodes.items.iter().take(4) {
                    println!("        E{:?} {}", episode.episode_number, episode.title);
                }
            }
        }

        match source.play_source(&item.id) {
            Ok(play) => println!(
                "    play url={} disc={} pos={} dur={}",
                play.url, play.disc, play.position_seconds, play.duration_seconds
            ),
            Err(err) => println!("    play ERR: {err}"),
        }
    }
}
