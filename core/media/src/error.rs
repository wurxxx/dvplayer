use serde::{Deserialize, Serialize};

/// 统一错误。
#[derive(Debug, thiserror::Error)]
pub enum MediaError {
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),

    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("api error {code}: {msg}")]
    Api { code: i64, msg: String },

    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, MediaError>;

/// 飞牛 / Emby 的通用响应外壳。
#[derive(Debug, Deserialize)]
pub struct ApiEnvelope<T> {
    #[serde(default)]
    pub code: i64,
    pub msg: Option<String>,
    pub data: Option<T>,
}

/// RFC 3986 百分号编码：只保留 unreserved，空格编成 %20。
pub fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for b in value.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// 只解 %XX，不把 `+` 当空格（等价于 JS 的 decodeURIComponent）。
pub fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 序列化辅助：紧凑 JSON，签名与发送共用同一份字符串。
pub fn compact_json<T: Serialize>(value: &T) -> Result<String> {
    Ok(serde_json::to_string(value)?)
}
