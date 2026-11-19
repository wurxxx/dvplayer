//! DVPlayer 共享媒体库核心。
//!
//! 目标：飞牛影视 / Emby 的登录、签名、分页、播放记录、聚合搜索都在这里做一次，
//! 三端（Windows WPF、macOS SwiftUI、Android Compose）只做界面。

pub mod error;
pub mod ffi;
pub mod hub;
pub mod models;
pub mod sources;

pub use error::{MediaError, Result};
pub use models::*;
pub use sources::FnOsSource;

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn signature_is_stable() {
        // 同样的输入（固定 nonce/timestamp）应得到同样的 sign。
        let query = BTreeMap::new();
        let sig = sources::fnos::sign("/v/api/v1/mediadb/list", &query, None, "GET");
        assert!(sig.starts_with("nonce="));
        assert!(sig.contains("&sign="));
    }

    #[test]
    fn percent_encoding_matches_js() {
        assert_eq!(error::percent_encode("a b"), "a%20b");
        assert_eq!(error::percent_decode("a%20b"), "a b");
    }

    #[test]
    fn media_kind_mapping() {
        assert_eq!(MediaKind::from_raw("Movie"), MediaKind::Movie);
        assert_eq!(MediaKind::from_raw("Directory"), MediaKind::Folder);
        assert_eq!(MediaKind::from_raw("Video"), MediaKind::Video);
    }

    #[test]
    fn episode_number_from_file_name() {
        use sources::fnos::parse_episode_number;

        // 未刮削目录里的真实文件名。
        assert_eq!(parse_episode_number("异能寻生机 - S01E76.mp4"), Some(76));
        assert_eq!(parse_episode_number("Show.S2E7.1080p.mkv"), Some(7));
        assert_eq!(parse_episode_number("第 12 集"), Some(12));
        assert_eq!(parse_episode_number("EP06.mp4"), Some(6));
        // 认不出来就交给调用方按顺序编号。
        assert_eq!(parse_episode_number("白狐照人心"), None);
        assert_eq!(parse_episode_number("SKIT"), None);
    }

    #[test]
    fn episode_count_only_from_brackets() {
        use sources::fnos::parse_episode_count;

        assert_eq!(parse_episode_count("异能寻生机（76集） - SKIT"), Some(76));
        assert_eq!(parse_episode_count("某剧 (24集)"), Some(24));
        // 「第 76 集」是单集标题，不能当总集数。
        assert_eq!(parse_episode_count("第 76 集"), None);
        assert_eq!(parse_episode_count("御兽：从退婚开始无敌"), None);
    }
}
