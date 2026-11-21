//! 标题清理与归一。
//!
//! 本地源要按文件名推断标题，聚合搜索要去判断「两个源给的是不是同一部片」，
//! 两边用的是同一套规则：去掉发布标签（`2160p`、`BluRay`、`x265`…），
//! 去掉结尾年份，再做一次只留字母数字的归一。

/// 把文件名 / 发布名清成可读标题。
pub(crate) fn clean_title(raw: &str) -> String {
    let replaced: String = raw
        .chars()
        .map(|c| match c {
            '.' | '_' => ' ',
            '【' | '】' | '[' | ']' => ' ',
            _ => c,
        })
        .collect();

    let keep: Vec<&str> = replaced
        .split_whitespace()
        .filter(|word| !is_release_word(word))
        .collect();

    let mut text = keep.join(" ");
    // 去掉结尾的年份括号残留，如「电影 (2023)」→「电影」。
    text = text.trim().to_string();
    for pattern in [" (", "（"] {
        if let Some(index) = text.rfind(pattern) {
            let tail = &text[index..];
            if tail.contains(')') || tail.contains('）') {
                let inner: String = tail
                    .chars()
                    .filter(|c| c.is_ascii_digit())
                    .collect();
                if inner.len() == 4 {
                    text.truncate(index);
                }
            }
        }
    }
    text.trim().to_string()
}

/// 发布名里的常见标签，清标题时整词丢掉。
pub(crate) fn is_release_word(word: &str) -> bool {
    const WORDS: &[&str] = &[
        "2160p", "1080p", "720p", "480p", "4k", "8k", "uhd", "bluray", "blu-ray", "bdrip",
        "remux", "webrip", "web-dl", "webdl", "web", "hdtv", "dvdrip", "hdr", "hdr10", "hdr10+",
        "dv", "dovi", "sdr", "x264", "x265", "h264", "h265", "hevc", "avc", "10bit", "8bit",
        "aac", "ac3", "eac3", "ddp", "dd", "dts", "dtshd", "truehd", "atmos", "flac", "proper",
        "repack", "internal", "extended", "uncut", "remastered", "imax", "hmax", "60fps",
    ];
    let lower = word.to_lowercase();
    if WORDS.contains(&lower.as_str()) {
        return true;
    }
    // `DDP5.1`、`x265-ABC` 这类合成词。
    lower.starts_with("ddp")
        || lower.starts_with("aac")
        || lower.starts_with("x26")
        || lower.starts_with("h26")
        || lower.starts_with("dts")
}

/// 标题里 1900–2100 的独立四位数，当年份用。
pub(crate) fn year_of(text: &str) -> Option<i32> {
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i + 4 <= chars.len() {
        if chars[i..i + 4].iter().all(|c| c.is_ascii_digit()) {
            let raw: String = chars[i..i + 4].iter().collect();
            let before_ok = i == 0 || !chars[i - 1].is_ascii_alphanumeric();
            let after_ok = i + 4 == chars.len() || !chars[i + 4].is_ascii_alphanumeric();
            if before_ok && after_ok {
                if let Ok(year) = raw.parse::<i32>() {
                    if (1900..=2100).contains(&year) {
                        return Some(year);
                    }
                }
            }
        }
        i += 1;
    }
    None
}

/// 去重键用的归一：清标题后只留字母数字（中文也算），统一小写，
/// 并去掉结尾的 4 位年份——「Some Movie 2023」与「Some Movie」要能并成一条。
pub(crate) fn normalize_key(raw: &str) -> String {
    let key: String = clean_title(raw)
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect();

    // 「1917」「2001 A Space Odyssey」这类片名不能被误删：要求年份前还有字母。
    let chars: Vec<char> = key.chars().collect();
    if chars.len() > 4 {
        let split = chars.len() - 4;
        let tail = &chars[split..];
        if tail.iter().all(|c| c.is_ascii_digit()) {
            let year: String = tail.iter().collect();
            if let Ok(year) = year.parse::<i32>() {
                if (1900..=2100).contains(&year)
                    && chars[..split].iter().any(|c| c.is_alphabetic())
                {
                    return chars[..split].iter().collect();
                }
            }
        }
    }
    key
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_release_names() {
        assert_eq!(
            clean_title("Some.Movie.2023.2160p.BluRay.x265"),
            "Some Movie 2023"
        );
        assert_eq!(clean_title("电影 (2023)"), "电影");
    }

    #[test]
    fn normalize_drops_punctuation_and_case() {
        assert_eq!(normalize_key("Some Movie 2023"), "somemovie");
        assert_eq!(normalize_key("some.movie.2023"), "somemovie");
        assert_eq!(normalize_key("大风车.Big.Pinwheel"), "大风车bigpinwheel");
        assert_eq!(normalize_key("1917"), "1917");
    }

    #[test]
    fn finds_year_between_1900_and_2100() {
        assert_eq!(year_of("Movie 2023 2160p"), Some(2023));
        assert_eq!(year_of("Show S01E01 1080p"), None);
        assert_eq!(year_of("1234"), None);
    }
}
