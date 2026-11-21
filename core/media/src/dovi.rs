//! Dolby Vision P7 的 FEL / MEL 判定。
//!
//! mpv 的 `dolby-vision-profile` 只到主层（P7），增强层是 FEL 还是 MEL 要看
//! RPU 里的 `disable_residual_flag`：`false` = FEL（有残差）、`true` = MEL
//! （只有元数据）。ADR-0005 要求界面上分开标。
//!
//! 做法：把码流前缀读下来（本地文件直接读，网络源用 Range 取前 8 MB），
//! 扫 HEVC 的 type 62 NAL（RPU），交给 `dolby_vision` 解析。不需要外部
//! `dovi_tool`，两端共用这一份。

use std::fs::File;
use std::io::Read;

use dolby_vision::rpu::dovi_rpu::DoviRpu;

use crate::{HttpHeader, MediaError, Result};

/// 最多读这么多码流前缀。100 Mbps 的 4K 大约 0.6 秒，
/// 前几帧就带 RPU，够判定；再大只是拖慢网络源。
const MAX_PREFIX: usize = 8 * 1024 * 1024;

/// 一次 RPU 探测的结果。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DoviInfo {
    /// Dolby Vision profile（7 = 双层，FEL / MEL 都在这上面）。
    pub profile: u8,
    /// `"fel"` / `"mel"`。
    pub el_type: String,
    /// RPU 里的原始标志：`false` = FEL。
    pub disable_residual: bool,
}

/// 从码流前缀里判断 FEL / MEL。找不到 RPU 或解析失败返回 `None`。
pub fn detect(prefix: &[u8]) -> Option<DoviInfo> {
    // MKV / TS / 裸 HEVC 是 Annex-B；MP4 是 4 字节长度前缀。
    // 两种都试一遍，先成功先用。
    for payload in unspec62_payloads_annex_b(prefix) {
        if let Ok(rpu) = DoviRpu::parse_unspec62_nalu(payload) {
            return Some(info_from(rpu));
        }
    }

    for payload in unspec62_payloads_length_prefixed(prefix) {
        if let Ok(rpu) = DoviRpu::parse_unspec62_nalu(payload) {
            return Some(info_from(rpu));
        }
    }

    // MKV 的文件头是 EBML，从 0 开始按长度前缀走不通；直接在字节流里找
    // type 62 的 NAL 头（`7c 01`），再回头看它前面的 4 字节长度是否对得上。
    for payload in unspec62_payloads_loose(prefix) {
        if let Ok(rpu) = DoviRpu::parse_unspec62_nalu(payload) {
            return Some(info_from(rpu));
        }
    }

    None
}

/// 取播放地址的码流前缀并判定。`url` 可以是 http(s)，也可以是本地路径。
pub fn probe(url: &str, headers: &[HttpHeader], proxy: &str) -> Result<DoviInfo> {
    let prefix = if url.starts_with("http://") || url.starts_with("https://") {
        fetch_prefix(url, headers, proxy)?
    } else {
        read_prefix(url)?
    };

    detect(&prefix).ok_or_else(|| MediaError::Other("码流里没找到 Dolby Vision RPU".into()))
}

fn info_from(rpu: DoviRpu) -> DoviInfo {
    let disable_residual = rpu.header.disable_residual_flag;
    DoviInfo {
        profile: rpu.dovi_profile,
        el_type: if disable_residual { "mel" } else { "fel" }.to_string(),
        disable_residual,
    }
}

// ---------------------------------------------------------------- 码流

/// 网络源：带用户的请求头与代理，用 `Range` 只要前缀。
///
/// 服务器不认 Range 时会退回 200 全量，读满 `MAX_PREFIX` 就断开。
fn fetch_prefix(url: &str, headers: &[HttpHeader], proxy: &str) -> Result<Vec<u8>> {
    let client = crate::sources::http_client(proxy);
    let mut request = client
        .get(url)
        .header("Range", format!("bytes=0-{}", MAX_PREFIX - 1));
    for header in headers {
        request = request.header(&header.name, &header.value);
    }

    let response = request
        .send()
        .map_err(|err| MediaError::Other(format!("取码流失败：{err}")))?;
    let status = response.status();
    if !status.is_success() {
        return Err(MediaError::Other(format!("取码流失败：HTTP {}", status.as_u16())));
    }

    let mut data = Vec::with_capacity(MAX_PREFIX);
    response
        .take(MAX_PREFIX as u64)
        .read_to_end(&mut data)
        .map_err(|err| MediaError::Other(format!("读码流失败：{err}")))?;
    Ok(data)
}

fn read_prefix(path: &str) -> Result<Vec<u8>> {
    let file = File::open(path)
        .map_err(|err| MediaError::Other(format!("打开文件失败：{err}")))?;
    let mut data = Vec::with_capacity(MAX_PREFIX);
    file.take(MAX_PREFIX as u64)
        .read_to_end(&mut data)
        .map_err(|err| MediaError::Other(format!("读文件失败：{err}")))?;
    Ok(data)
}

// ---------------------------------------------------------------- NAL 扫描

/// Annex-B：`00 00 01` / `00 00 00 01` 分隔，16 位 NAL header。
fn unspec62_payloads_annex_b(data: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut index = 0;

    while index + 3 <= data.len() {
        if data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1 {
            let header = index + 3;
            if header >= data.len() {
                break;
            }
            starts.push(header);
            index = header;
        } else {
            index += 1;
        }
    }

    let mut out = Vec::new();
    for (position, &start) in starts.iter().enumerate() {
        let mut end = starts
            .get(position + 1)
            .map(|&next| next.saturating_sub(3).max(start))
            .unwrap_or(data.len());
        // 4 字节起始码（`00 00 00 01`）的前一个 0 会被算进来，去掉尾部的 0。
        while end > start + 2 && data[end - 1] == 0 {
            end -= 1;
        }
        if end <= start + 2 || end > data.len() {
            continue;
        }
        let nalu = &data[start..end];
        if hevc_nal_type(nalu) == Some(62) {
            out.push(&nalu[2..]);
        }
    }
    out
}

/// 4 字节大端长度前缀（MP4 的 hvcC / mdat 里就是这种）。
fn unspec62_payloads_length_prefixed(data: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut index = 0;

    while index + 5 < data.len() {
        let length = u32::from_be_bytes([
            data[index],
            data[index + 1],
            data[index + 2],
            data[index + 3],
        ]) as usize;
        // 长度不合理就当作不是这种格式（随机字节很容易撞出大长度）。
        if length < 3 || length > data.len() - index - 4 {
            break;
        }
        let nalu = &data[index + 4..index + 4 + length];
        if hevc_nal_type(nalu) == Some(62) {
            out.push(&nalu[2..]);
        }
        index += 4 + length;
    }

    out
}

/// 容器（MKV 的 Block 里）不一定从 NAL 序列开头读得到：直接找
/// `7c 01`（type 62、layer 0、temporal_id 1），用前面的 4 字节当长度校验。
fn unspec62_payloads_loose(data: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut index = 4;

    while index + 2 < data.len() {
        if data[index] == 0x7c && data[index + 1] == 0x01 {
            let length = u32::from_be_bytes([
                data[index - 4],
                data[index - 3],
                data[index - 2],
                data[index - 1],
            ]) as usize;
            // 长度包含 2 字节 NAL 头；太大太小都当误报。
            if (3..=4 * 1024 * 1024).contains(&length) && index + length <= data.len() {
                out.push(&data[index + 2..index + length]);
            }
        }
        index += 1;
    }

    out
}

/// HEVC NAL 头：`forbidden(1) type(6) layer_id(6) temporal_id(3)`。
fn hevc_nal_type(nalu: &[u8]) -> Option<u8> {
    if nalu.len() < 2 {
        return None;
    }
    Some((nalu[0] >> 1) & 0x3f)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn annex_b(nal_type: u8, payload: &[u8]) -> Vec<u8> {
        let mut data = vec![0, 0, 0, 1, nal_type << 1, 1];
        data.extend_from_slice(payload);
        data.extend_from_slice(&[0, 0, 0, 1, 0x02, 1]);
        data
    }

    #[test]
    fn finds_rpu_nal_in_annex_b() {
        let data = annex_b(62, &[1, 2, 3]);
        let found = unspec62_payloads_annex_b(&data);
        assert_eq!(found, vec![&[1u8, 2, 3][..]]);
    }

    #[test]
    fn ignores_other_nal_types() {
        let data = annex_b(32, &[9, 9]);
        assert!(unspec62_payloads_annex_b(&data).is_empty());
    }

    #[test]
    fn finds_rpu_nal_in_length_prefixed() {
        let mut data = Vec::new();
        let nalu = [62u8 << 1, 1, 7, 8, 9];
        data.extend_from_slice(&(nalu.len() as u32).to_be_bytes());
        data.extend_from_slice(&nalu);
        assert_eq!(unspec62_payloads_length_prefixed(&data), vec![&[7u8, 8, 9][..]]);
    }

    /// MKV 里的 RPU：文件头是 EBML，只能靠宽松扫描找到。
    #[test]
    fn detects_fel_in_mkv_sample_when_available() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../samples/p7-fel.mkv");
        let Ok(file) = File::open(path) else { return };
        let mut data = Vec::new();
        if file.take(MAX_PREFIX as u64).read_to_end(&mut data).is_err() {
            return;
        }

        let info = detect(&data).expect("MKV 样本里应有 RPU");
        assert_eq!(info.profile, 7);
        assert_eq!(info.el_type, "fel");
    }

    /// 仓库里如果留着 M0 的 P7 样本，顺手验一次真 FEL。
    #[test]
    fn detects_real_fel_sample_when_available() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../out/p7-report/el_rpu.hevc");
        let Ok(file) = File::open(path) else { return };
        let mut data = Vec::new();
        if file.take(MAX_PREFIX as u64).read_to_end(&mut data).is_err() {
            return;
        }

        let info = detect(&data).expect("样本里应有 RPU");
        assert_eq!(info.profile, 7);
        assert_eq!(info.el_type, "fel");
    }
}
