using System;
using System.Collections.Generic;

namespace DvPlayer.Services;

/// <summary>详情页缓存条目：详情 + 演职人员 + 季 + 当前季的集。</summary>
public sealed record DetailSnapshot(
    MediaDetailDto Detail,
    List<PersonDto> People,
    List<MediaItemDto> Seasons,
    string? SeasonId,
    List<MediaItemDto> Episodes,
    int EpisodesTotal,
    int LocalSeasonCount,
    int LocalEpisodeCount,
    DateTime At);

/// <summary>
/// 详情页的短期缓存。
///
/// 飞牛的 `/item/list` 在同一台机器上实测 0.5–3 秒（服务端波动，
/// 和 page_size 不完全成正比）。同一部片来回进时不该每次都等，
/// 这里缓存两分钟。只放在内存里；收藏 / 标记看过之后主动 <see cref="Drop"/>，
/// 避免状态过期。
/// </summary>
public static class DetailCache
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, DetailSnapshot> Items = new();
    private static readonly TimeSpan Ttl = TimeSpan.FromSeconds(120);

    public static DetailSnapshot? Get(string id)
    {
        lock (Gate)
        {
            if (!Items.TryGetValue(id, out var snapshot))
            {
                return null;
            }

            if (DateTime.UtcNow - snapshot.At > Ttl)
            {
                Items.Remove(id);
                return null;
            }

            return snapshot;
        }
    }

    public static void Put(string id, DetailSnapshot snapshot)
    {
        lock (Gate)
        {
            Items[id] = snapshot;
        }
    }

    public static void Drop(string id)
    {
        lock (Gate)
        {
            Items.Remove(id);
        }
    }
}
