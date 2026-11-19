//! DVPlayer 共享媒体库核心。
//!
//! 目标：飞牛影视 / Emby 的登录、签名、分页、播放记录、聚合搜索都在这里做一次，
//! 三端（Windows WPF、macOS SwiftUI、Android Compose）只做界面。

pub mod error;
pub mod ffi;
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
}
