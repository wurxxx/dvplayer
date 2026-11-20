using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 媒体库页。顶部一个源名、媒体 / 搜索 / 收藏
/// 分段，下面是 Hero 横幅、「我的媒体」库卡片、继续观看，以及每个库一行横向海报。
/// 点库卡片或某行的箭头进入原来的网格视图（可下钻目录、加载更多）。
/// </summary>
public partial class LibrariesPage : Page, INotifyPropertyChanged
{
    private const int PreviewPerLibrary = 12;
    private const double ScrollStep = 262;

    /// <summary>网格卡片之间的横向间距。列宽按可用宽度算，卡片跟着缩放宽。</summary>
    private const double CardGap = 16;
    private const double MinCardWidth = 175;

    public event PropertyChangedEventHandler? PropertyChanged;

    private static int PageSize => Math.Max(10, AppServices.Instance.Settings.PageSize);

    private List<MediaLibraryDto> _libraries = new();
    private List<LibraryCardItem> _libraryCards = new();
    private Task? _overviewTask;

    /// <summary>Hero 轮播的候选（有横版图的条目，最多 8 个）。</summary>
    private readonly List<HeroItem> _heroPool = new();
    private int _heroIndex;
    private int _heroVersion;

    /// <summary>已经落到背景上的那一张，避免重复淡入同一张图。</summary>
    private string? _shownHeroId;
    private string? _shownHeroPath;

    private readonly DispatcherTimer _heroTimer = new() { Interval = TimeSpan.FromSeconds(7) };

    // —— 启动计时（--timing 时写日志，定位首页为什么慢）——
    private static readonly System.Diagnostics.Stopwatch StartupClock =
        System.Diagnostics.Stopwatch.StartNew();

    private static bool Timing => Environment.GetCommandLineArgs().Contains("--timing");

    private static void Trace(string stage)
    {
        if (!Timing)
        {
            return;
        }

        try
        {
            var dir = Path.Combine(Path.GetTempPath(), "dvplayer");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "startup.log"),
                $"{StartupClock.ElapsedMilliseconds,6} ms  {stage}{Environment.NewLine}");
        }
        catch
        {
            // 计时失败不影响首页。
        }
    }

    // —— 自适应卡片尺寸（跟着窗口宽度走）——
    private double _cardWidth = 148;

    /// <summary>海报宽度。列数变化时重算。</summary>
    public double CardWidth => _cardWidth;

    /// <summary>海报高度，保持 2:3。</summary>
    public double CardHeight => Math.Round(_cardWidth * 1.5);

    /// <summary>一个格子的宽度（卡片 + 右侧间距）。WrapPanel 用它保证一行正好铺满。</summary>
    public double CardSlot => Math.Round(_cardWidth + CardGap, 2);

    private string? _libraryId;
    private string _libraryTitle = "";

    /// <summary>当前列表的父节点（媒体库或某个目录）。</summary>
    private string? _parentId;
    private bool _childrenMode;

    /// <summary>目录路径，用于面包屑和「返回上层」。</summary>
    private readonly List<(string Id, string Title)> _stack = new();

    /// <summary>已经取到的全部卡片；顶栏搜索只过滤这一份，不再打服务器。</summary>
    private List<ItemCard> _allCards = new();

    /// <summary>当前显示的卡片。滚到底自动续页，往这里追加而不是整份重设。</summary>
    private readonly ObservableCollection<ItemCard> _visible = new();

    /// <summary>「继续观看」行。移除观看记录时直接从这里删一张。</summary>
    private readonly ObservableCollection<RecordCard> _continueCards = new();

    private int _total;
    private bool _loadingPage;
    private bool _hasMore;
    private DateTime _retryAfter = DateTime.MinValue;

    /// <summary>类别 / 排序 / 风格一变就换一个版本号，丢掉过期的分页结果。</summary>
    private int _browseVersion;

    private string _sortField = "added";
    private bool _sortDescending = true;

    private List<GenreDto> _genres = new();
    private string? _activeGenre;

    private int _page;

    public LibrariesPage()
    {
        InitializeComponent();
        ContinueRow.ItemsSource = _continueCards;
        SortBox.SelectedIndex = 0;
        UpdateSortIcon();
        _heroTimer.Tick += (_, _) => _ = ShowHeroAsync(_heroIndex + 1);
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _heroTimer.Stop();
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
    }

    private void OnConnectionChanged(object? sender, EventArgs e) =>
        // 登录在后台线程完成，重新拉数据必须回到 UI 线程。
        Dispatcher.BeginInvoke(() =>
        {
            // 页面已经被别的页替换，或者连接状态没变，就别再拉一遍。
            if (!IsVisible || (_loaded && ConnectionSignature() == _loadedSignature))
            {
                return;
            }

            OnLoaded(this, new RoutedEventArgs());
        });

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        // 冷启动时登录还没完成，连上之后靠这个事件重新拉一次。
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
        AppServices.Instance.ConnectionChanged += OnConnectionChanged;

        Trace("OnLoaded");

        // Loaded 会跟着导航重复触发，已经按同样的连接状态拉过就不再拉。
        if (_loaded && ConnectionSignature() == _loadedSignature)
        {
            return;
        }

        _overviewTask = LoadOverviewAsync();
        await _overviewTask.ConfigureAwait(true);
    }

    private bool _loaded;
    private string _loadedSignature = "";

    /// <summary>连接状态的指纹：源和连没连上，变了才需要重新拉。</summary>
    private static string ConnectionSignature() => string.Join("|",
        AppServices.Instance.Connections.Select(c => $"{c.Id}:{c.Ok}"));

    /// <summary>截图巡检用：等首页数据就绪后直接进第一个库的网格。</summary>
    public async Task ShowFirstLibraryAsync()
    {
        if (_overviewTask is not null)
        {
            await _overviewTask.ConfigureAwait(true);
        }

        if (_libraries.Count > 0)
        {
            await ShowLibraryAsync(_libraries[0].Id).ConfigureAwait(true);
        }
    }

    // —— 源首页 ——

    private bool _loading;
    private int _loadVersion;

    /// <summary>上次首页的数据。启动先把它画出来，实时数据回来再替换。</summary>
    private HomeSnapshot? _snapshot;

    /// <summary>
    /// 首页一次性要拉库列表、每库一页、播放记录、Hero 详情和一堆海报。
    /// 分两段跑：先把手上的东西画出来，Hero 详情和海报在后台补。
    /// </summary>
    private async Task LoadOverviewAsync()
    {
        // Loaded 和 ConnectionChanged 会连着触发好几次，重复加载会让首页更慢。
        if (_loading)
        {
            return;
        }

        _loading = true;
        var version = ++_loadVersion;
        try
        {
            await LoadOverviewCoreAsync(version).ConfigureAwait(true);
        }
        finally
        {
            _loading = false;
        }
    }

    private async Task LoadOverviewCoreAsync(int version)
    {
        var services = AppServices.Instance;
        if (!services.IsConnected || !IsVisible)
        {
            SourceTitle.Text = "媒体库";
            StatusText.Text = "未连接媒体源，先去「媒体源」添加。";
            return;
        }

        var core = services.Core!;
        var sourceId = services.Settings.LastSourceId;
        var sourceOk = sourceId is not null &&
                       services.Connections.Any(c => c.Id == sourceId && c.Ok);

        var sourceName = services.Connections.FirstOrDefault(c => c.Id == sourceId)?.Name
                         ?? services.Settings.Sources.FirstOrDefault(s => s.Id == sourceId)?.Name;
        SourceTitle.Text = sourceName
                           ?? services.Connections.FirstOrDefault(c => c.Ok)?.Name
                           ?? "媒体库";
        StatusText.Text = "正在读取…";

        if (sourceName is not null && !sourceOk)
        {
            StatusText.Text = "这个服务器没有连上，去「服务器」检查地址或账号。";
            return;
        }

        _heroTimer.Stop();
        _heroPool.Clear();

        // 先用上次的数据把首屏铺满（海报有磁盘缓存，秒开），再去拉实时数据。
        _snapshot = ReadSnapshot(sourceId);
        if (_snapshot is not null)
        {
            ApplySnapshot(_snapshot);
            Trace("缓存首屏");
        }

        var librariesResult = await Task.Run(core.Libraries).ConfigureAwait(true);
        Trace($"libraries: {librariesResult.Data?.Count ?? 0} 个");
        if (!librariesResult.Ok || librariesResult.Data is null)
        {
            if (_snapshot is null)
            {
                StatusText.Text = "读取媒体库失败：" + (librariesResult.Error ?? "未知错误");
            }

            return;
        }

        _libraries = librariesResult.Data;
        _loaded = true;
        _loadedSignature = ConnectionSignature();
        if (sourceOk)
        {
            var mine = _libraries.Where(l => l.SourceId == sourceId).ToList();
            if (mine.Count > 0)
            {
                _libraries = mine;
            }
        }

        LibrariesCount.Text = $"{_libraries.Count} 个";

        // 各库首页和播放记录同时发：记录不依赖库列表，没必要排在后面。
        var recordsTask = Task.Run(core.Records);
        var pages = await Task.WhenAll(_libraries.Select(library => Task.Run(() =>
        {
            var page = core.Items(library.Id, 1, PreviewPerLibrary);
            return (Library: library, Page: page);
        }))).ConfigureAwait(true);

        if (version != _loadVersion || !IsVisible)
        {
            return;
        }

        Trace("items 全部回来");

        _libraryCards = BuildLibraryCards(_libraries);

        var snapshots = pages
            .Where(p => p.Page.Ok && p.Page.Data is not null)
            .Select(p => new LibrarySnapshot
            {
                Library = p.Library,
                Items = p.Page.Data!.Items,
                Total = p.Page.Data.Total,
            })
            .ToList();

        var sections = BuildSections(snapshots);

        // 缓存里已经有详情版的 Hero 就先留着，别退回列表海报再闪一下。
        if (_heroPool.Count == 0)
        {
            ApplyHeroPool(null, snapshots);
        }

        LibraryCards.ItemsSource = _libraryCards;
        Sections.ItemsSource = sections;
        StatusText.Text = "";
        Trace("sections 画完");

        if (_heroPool.Count > 0)
        {
            await ShowHeroAsync(0).ConfigureAwait(true);
            Trace("hero 首帧（列表海报）");
        }
        else if (_libraries.Count > 0)
        {
            HeroTitle.Text = _libraries[0].Title;
            HeroMeta.Text = "";
            HeroOverview.Text = "这个库里还没有条目。";
        }

        // 详情补齐横版图和简介，不挡首屏。
        _ = UpgradeHeroAsync(snapshots, sourceId, version);

        // 继续观看（当前源的全部记录，取前 12 条未看完的）
        var recordsResult = await recordsTask.ConfigureAwait(true);
        if (recordsResult.Ok && recordsResult.Data is not null)
        {
            ApplyRecords(recordsResult.Data, sourceId, sourceOk);
            Trace("records 画完");
        }

        // 库卡片与分组里的海报最后补，先把结构画出来。
        var all = sections.SelectMany(s2 => s2.Items).ToList();
        await Task.WhenAll(all.Select(c => c.ApplyPosterAsync(c.PosterPath))).ConfigureAwait(true);
        await Task.WhenAll(_libraryCards
            .SelectMany(c => c.Arts)
            .Where(a => !string.IsNullOrWhiteSpace(a.Path))
            .Select(a => a.ApplyPosterAsync(a.Path))).ConfigureAwait(true);
        Trace("首屏海报下载完成");

        WriteSnapshot(sourceId, snapshots, _heroPool, recordsResult.Data);
    }

    // —— 首页数据装配（缓存和实时共用）——

    private static List<LibraryCardItem> BuildLibraryCards(IEnumerable<MediaLibraryDto> libraries) =>
        libraries
            .Select(library =>
            {
                var card = new LibraryCardItem
                {
                    Id = library.Id,
                    Title = library.Title,
                    Initial = Palette.InitialOf(library.Title),
                };
                card.UseGradient(library.Id + library.Title);
                return card;
            })
            .ToList();

    private List<LibrarySection> BuildSections(IReadOnlyList<LibrarySnapshot> pages)
    {
        var sections = new List<LibrarySection>();
        foreach (var page in pages)
        {
            sections.Add(new LibrarySection
            {
                Id = page.Library.Id,
                Title = page.Library.Title,
                CountLabel = $"{page.Total}",
                Items = page.Items.Select(ToCard).ToList(),
            });

            // 「我的媒体」用最近入库的三张海报拼图，和列表顺序一致。
            var card = _libraryCards.FirstOrDefault(c => c.Id == page.Library.Id);
            if (card is not null && card.Arts.Count == 0)
            {
                foreach (var item in page.Items
                             .Where(i => !string.IsNullOrWhiteSpace(i.PosterPath))
                             .Take(3))
                {
                    var art = new LibraryArt
                    {
                        Path = item.PosterPath,
                        Initial = Palette.InitialOf(item.Title),
                    };
                    art.UseGradient(item.Id + item.Title);
                    card.Arts.Add(art);
                }
            }
        }

        return sections;
    }

    /// <summary>
    /// Hero 候选：有详情就用详情（横版图 + 简介），没有就用列表里的海报顶一下。
    /// </summary>
    private void ApplyHeroPool(IReadOnlyList<MediaDetailDto>? details, IReadOnlyList<LibrarySnapshot> pages)
    {
        _heroPool.Clear();

        if (details is { Count: > 0 })
        {
            _heroPool.AddRange(details
                .Where(d => !string.IsNullOrWhiteSpace(d.BackdropPath) ||
                            !string.IsNullOrWhiteSpace(d.PosterPath))
                // 有横版图的排前面：竖版海报裁成横幅会放大、也不好看。
                .OrderBy(d => string.IsNullOrWhiteSpace(d.BackdropPath) ? 1 : 0)
                .ThenBy(d => string.IsNullOrWhiteSpace(d.Overview) ? 1 : 0)
                .ThenByDescending(d => d.Rating ?? 0)
                .Take(8)
                .Select(ToHero));
            return;
        }

        _heroPool.AddRange(pages
            .SelectMany(p => p.Items)
            .Where(item => !string.IsNullOrWhiteSpace(item.PosterPath))
            .Take(8)
            .Select(ToHeroFromItem));
    }

    private void ApplyRecords(IReadOnlyList<PlayRecordDto> records, string? sourceId, bool sourceOk)
    {
        var continuing = records
            .Where(r => !sourceOk || r.SourceId == sourceId)
            .Where(r => r.DurationSeconds <= 0 || r.PositionSeconds < r.DurationSeconds * 0.98)
            .OrderByDescending(r => r.LastPlayed ?? 0)
            .Take(12)
            .ToList();

        var cards = continuing.Select(ToRecordCard).ToList();
        _continueCards.Clear();
        foreach (var card in cards)
        {
            _continueCards.Add(card);
        }

        ContinueEmpty.Visibility = cards.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ContinueCount.Text = cards.Count == 0 ? "" : $"{cards.Count} ›";

        _ = Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    /// <summary>把上次的首页贴上去，不等网络。</summary>
    private void ApplySnapshot(HomeSnapshot snapshot)
    {
        if (snapshot.Pages.Count == 0)
        {
            return;
        }

        _libraries = snapshot.Pages.Select(p => p.Library).ToList();
        LibrariesCount.Text = $"{_libraries.Count} 个";
        _libraryCards = BuildLibraryCards(_libraries);
        LibraryCards.ItemsSource = _libraryCards;
        Sections.ItemsSource = BuildSections(snapshot.Pages);
        StatusText.Text = "";

        ApplyHeroPool(snapshot.Heroes, snapshot.Pages);
        if (_heroPool.Count > 0)
        {
            _ = ShowHeroAsync(0);
        }

        ApplyRecords(snapshot.Records, snapshot.SourceId, sourceOk: true);
    }

    // —— 首页快照 ——

    private static readonly System.Text.Json.JsonSerializerOptions SnapshotJson = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private static string SnapshotPath(string? sourceId)
    {
        var safe = new string((sourceId ?? "none")
            .Select(c => char.IsLetterOrDigit(c) ? c : '_')
            .ToArray());
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "dvplayer",
            $"home-{safe}.json");
    }

    private static HomeSnapshot? ReadSnapshot(string? sourceId)
    {
        try
        {
            var file = SnapshotPath(sourceId);
            if (!File.Exists(file))
            {
                return null;
            }

            return System.Text.Json.JsonSerializer.Deserialize<HomeSnapshot>(
                File.ReadAllText(file), SnapshotJson);
        }
        catch
        {
            return null;
        }
    }

    private void WriteSnapshot(
        string? sourceId, IReadOnlyList<LibrarySnapshot> pages,
        IReadOnlyList<HeroItem> heroes, IReadOnlyList<PlayRecordDto>? records)
    {
        try
        {
            var snapshot = new HomeSnapshot
            {
                SourceId = sourceId ?? "",
                Pages = pages.ToList(),
                Records = records?.ToList() ?? ReadSnapshot(sourceId)?.Records ?? new List<PlayRecordDto>(),
                SavedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            };

            // Hero 只存详情形式的条目才有简介；占位海报也一样能画，存下来省一趟网络。
            snapshot.Heroes = heroes
                .Select(h => new MediaDetailDto(
                    h.Id, h.Title, h.Kind, null, h.Overview, h.BackdropPath, h.BackdropPath,
                    null, null, null, null, null, null, null, null, null, null, null, null,
                    null, null))
                .ToList();

            var file = SnapshotPath(sourceId);
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, System.Text.Json.JsonSerializer.Serialize(snapshot, SnapshotJson));
        }
        catch
        {
            // 快照失败不影响首页。
        }
    }

    /// <summary>
    /// 后台把 Hero 候选补成详情（横版图 / 简介 / 评分）。
    /// 完成后若是同一条目就原地换成高清图，否则换成第一条有横版图的。
    /// </summary>
    private async Task UpgradeHeroAsync(
        IReadOnlyList<LibrarySnapshot> pages, string? sourceId, int version)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        var ids = pages
            .SelectMany(p => p.Items)
            .Where(item => !string.Equals(item.Kind, "folder", StringComparison.OrdinalIgnoreCase))
            .Select(item => item.Id)
            .Distinct()
            .Take(6)
            .ToList();

        if (ids.Count == 0)
        {
            // 第一页全是未刮削目录，直接去随机页碰运气。
            _ = ResampleHeroAsync(pages, sourceId, version);
            return;
        }

        using var gate = new SemaphoreSlim(6);
        var details = await Task.WhenAll(ids.Select(async id =>
        {
            await gate.WaitAsync().ConfigureAwait(false);
            try
            {
                return await Task.Run(() => core.ItemDetail(id)).ConfigureAwait(false);
            }
            finally
            {
                gate.Release();
            }
        })).ConfigureAwait(true);

        if (version != _loadVersion || !IsVisible)
        {
            return;
        }

        var list = details
            .Where(d => d.Ok && d.Data is not null)
            .Select(d => d.Data!)
            .ToList();

        if (list.Count == 0)
        {
            return;
        }

        Trace("hero 详情补齐");

        var currentId = _heroPool.Count > 0
            ? _heroPool[Math.Clamp(_heroIndex, 0, _heroPool.Count - 1)].Id
            : null;

        ApplyHeroPool(list, pages);
        if (_heroPool.Count == 0)
        {
            return;
        }

        // 同一条目就原地换成横版高清图，圆点位置尽量不动。
        var target = currentId is null ? 0 : _heroPool.FindIndex(h => h.Id == currentId);
        if (target < 0)
        {
            target = 0;
        }

        await ShowHeroAsync(target).ConfigureAwait(true);
        if (_heroPool.Count > 1)
        {
            _heroTimer.Start();
        }

        // Hero 详情写回快照，下次启动直接就是横版图。
        WriteSnapshot(sourceId, pages, _heroPool, null);

        // 第一页大多是没刮削的目录，只有竖版海报。后台再随机翻一页找横版图，
        // 慢一点没关系，横幅已经能看了。
        var hasBackdrop = list.Any(d =>
            !string.IsNullOrWhiteSpace(d.BackdropPath) && d.BackdropPath != d.PosterPath);
        if (!hasBackdrop)
        {
            _ = ResampleHeroAsync(pages, sourceId, version);
        }
    }

    /// <summary>随机翻页找有横版图的条目，找到了再把 Hero 换过去。</summary>
    private async Task ResampleHeroAsync(
        IReadOnlyList<LibrarySnapshot> pages, string? sourceId, int version)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        var details = new List<MediaDetailDto>();
        foreach (var page in pages)
        {
            details.AddRange(await SampleRandomPageDetailsAsync(
                core, page.Library.Id, page.Total, 12).ConfigureAwait(true));
        }

        if (version != _loadVersion || !IsVisible)
        {
            return;
        }

        var picked = details
            .Where(d => !string.IsNullOrWhiteSpace(d.BackdropPath) && d.BackdropPath != d.PosterPath)
            .ToList();

        if (picked.Count == 0)
        {
            return;
        }

        Trace("hero 换到横版图");

        // 全部详情都留着：有横版图的排前面，其余当后备，别让圆点只剩一个。
        var previous = _heroPool.ToList();
        ApplyHeroPool(details, pages);
        foreach (var hero in previous)
        {
            if (_heroPool.Count >= 8)
            {
                break;
            }

            if (_heroPool.All(h => h.Id != hero.Id))
            {
                _heroPool.Add(hero);
            }
        }

        await ShowHeroAsync(0).ConfigureAwait(true);
        if (_heroPool.Count > 1)
        {
            _heroTimer.Start();
        }

        WriteSnapshot(sourceId, pages, _heroPool, null);
    }

    /// <summary>随机翻一页，挑几条非目录条目取详情。</summary>
    private static async Task<List<MediaDetailDto>> SampleRandomPageDetailsAsync(
        MediaCore core, string libraryId, int total, int take)
    {
        const int pageSize = 100;
        var pages = Math.Max(1, (total + pageSize - 1) / pageSize);
        var page = pages > 1 ? Random.Shared.Next(2, pages + 1) : 1;

        var result = await Task.Run(() => core.Items(libraryId, page, pageSize)).ConfigureAwait(true);
        if (!result.Ok || result.Data is null)
        {
            return new List<MediaDetailDto>();
        }

        var ids = result.Data.Items
            .Where(item => !string.Equals(item.Kind, "folder", StringComparison.OrdinalIgnoreCase))
            .OrderBy(_ => Random.Shared.Next())
            .Take(take)
            .Select(item => item.Id)
            .ToList();

        if (ids.Count == 0)
        {
            return new List<MediaDetailDto>();
        }

        using var gate = new SemaphoreSlim(6);
        var details = await Task.WhenAll(ids.Select(async id =>
        {
            await gate.WaitAsync().ConfigureAwait(false);
            try
            {
                return await Task.Run(() => core.ItemDetail(id)).ConfigureAwait(false);
            }
            finally
            {
                gate.Release();
            }
        })).ConfigureAwait(true);

        return details
            .Where(d => d.Ok && d.Data is not null)
            .Select(d => d.Data!)
            .ToList();
    }

    private static HeroItem ToHeroFromItem(MediaItemDto item) => new()
    {
        Id = item.Id,
        Kind = item.Kind,
        Title = MediaText.Clean(item.Title),
        Meta = MediaText.Describe(item),
        Overview = "",
        Chips = new List<string>(),
        BackdropPath = item.PosterPath,
    };

    // —— Hero 轮播 ——

    private static HeroItem ToHero(MediaDetailDto item) => new()
    {
        Id = item.Id,
        Kind = item.Kind,
        Title = MediaText.Clean(item.Title),
        Meta = BuildMeta(item),
        Overview = Collapse(item.Overview),
        Chips = new[] { item.Resolution, item.ColorRange, item.AudioType }
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => v!.Trim())
            .Distinct()
            .ToList(),
        BackdropPath = item.BackdropPath ?? item.PosterPath,
    };

    /// <summary>简介里的换行和空行压成空格，免得三行文字被拆成两段。</summary>
    private static string Collapse(string? text) =>
        string.IsNullOrWhiteSpace(text)
            ? ""
            : string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static string BuildMeta(MediaDetailDto item)
    {
        var parts = new List<string>();
        if (item.Rating is > 0)
        {
            parts.Add($"★ {item.Rating:0.0}");
        }

        var year = !string.IsNullOrWhiteSpace(item.ReleaseDate) && item.ReleaseDate.Length >= 4
            ? item.ReleaseDate[..4]
            : null;
        if (!string.IsNullOrWhiteSpace(year))
        {
            parts.Add(year);
        }

        parts.Add(MediaText.KindLabel(item.Kind));

        var episodes = item.LocalEpisodeCount is > 1 ? item.LocalEpisodeCount : item.EpisodeCount;
        if (episodes is > 1)
        {
            parts.Add($"{episodes} 集");
        }

        return string.Join(" · ", parts);
    }

    /// <summary>切到第 index 条（循环）。背景做一次交叉淡入，文字立即换。</summary>
    private async Task ShowHeroAsync(int index)
    {
        if (_heroPool.Count == 0)
        {
            return;
        }

        var version = ++_heroVersion;
        var count = _heroPool.Count;
        _heroIndex = ((index % count) + count) % count;

        var hero = _heroPool[_heroIndex];
        HeroTitle.Text = hero.Title;
        HeroMeta.Text = hero.Meta;
        HeroOverview.Text = hero.Overview;
        HeroChips.ItemsSource = hero.Chips;
        HeroChips.Visibility = hero.Chips.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateDots();

        HeroPrev.IsEnabled = count > 1;
        HeroNext.IsEnabled = count > 1;

        // 同一张图已经在背景上了，就不必再淡入一次（实时数据回来时会走这里）。
        if (hero.Id == _shownHeroId && hero.BackdropPath == _shownHeroPath &&
            HeroBackdrop.Background is ImageBrush)
        {
            return;
        }

        var bitmap = await PosterLoader.LoadAsync(hero.BackdropPath, 1280).ConfigureAwait(true);
        if (version != _heroVersion)
        {
            return;
        }

        if (bitmap is null)
        {
            // 图没下来就留着上一张，别把横幅刷成空的。
            return;
        }

        var brush = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
        brush.Freeze();

        HeroFade.Background = brush;
        HeroFade.BeginAnimation(OpacityProperty,
            new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(320))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            });

        await Task.Delay(340).ConfigureAwait(true);
        if (version != _heroVersion)
        {
            return;
        }

        // 动画结束把图落到下层，下一次还能从 0 淡入。
        HeroBackdrop.Background = brush;
        _shownHeroId = hero.Id;
        _shownHeroPath = hero.BackdropPath;
        HeroFade.BeginAnimation(OpacityProperty, null);
        HeroFade.Opacity = 0;
    }

    private void UpdateDots()
    {
        HeroDots.ItemsSource = _heroPool
            .Select((_, i) => new HeroDot(i == _heroIndex))
            .ToList();
    }

    /// <summary>截图巡检用：切到「搜索」分段并填好关键词。</summary>
    public void ShowInlineSearchForShot(string query)
    {
        SearchSegment.IsChecked = true;
        InlineSearchBox.Text = query;
        InlineSearchBox.Focus();
    }

    /// <summary>截图巡检用：切到「收藏」分段。</summary>
    public void ShowFavoritesForShot() => FavoriteSegment.IsChecked = true;

    /// <summary>截图巡检用：把 Hero 左右箭头显示出来，确认位置和样式。</summary>
    public void PreviewHeroArrows() => FadeArrows(1);

    /// <summary>截图巡检用：滚到指定位置，看横幅下面几块。</summary>
    public void ScrollOverview(double offset) => OverviewRoot.ScrollToVerticalOffset(offset);

    /// <summary>
    /// 按可用宽度算列数与卡片宽度：卡片大约在 175–222 之间缩放，
    /// 宽度再涨到能塞下一列时，卡片缩回去、列数 +1。
    /// </summary>
    private void UpdateCardSize(double available)
    {
        if (available < MinCardWidth + CardGap)
        {
            return;
        }

        var columns = Math.Max(1, (int)Math.Floor(available / (MinCardWidth + CardGap)));
        var slot = Math.Floor(available / columns * 100) / 100;
        var width = Math.Max(1, slot - CardGap);

        if (Math.Abs(width - _cardWidth) < 0.5)
        {
            return;
        }

        _cardWidth = width;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CardWidth)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CardHeight)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CardSlot)));
    }

    private void OnBrowseSizeChanged(object sender, SizeChangedEventArgs e) =>
        UpdateCardSize(e.NewSize.Width);

    /// <summary>截图巡检用：把库内网格往下滚，触发自动加载。</summary>
    public void ScrollBrowse(double offset) => BrowseScroll.ScrollToVerticalOffset(offset);

    /// <summary>截图巡检用：打开网格第一张卡片的右键菜单（Popup 截图单独渲染）。</summary>
    public ContextMenu? OpenFirstCardMenu()
    {
        if (ItemGrid.ItemContainerGenerator.ContainerFromIndex(0) is not DependencyObject container)
        {
            return null;
        }

        var border = FindCard(container);
        if (border?.ContextMenu is null)
        {
            return null;
        }

        border.ContextMenu.PlacementTarget = border;
        border.ContextMenu.IsOpen = true;
        return border.ContextMenu;
    }

    /// <summary>截图巡检用：打开「继续观看」第一张卡片的右键菜单。</summary>
    public ContextMenu? OpenFirstContinueMenu()
    {
        if (ContinueRow.ItemContainerGenerator.ContainerFromIndex(0) is not DependencyObject container)
        {
            return null;
        }

        var border = FindCard(container);
        if (border?.ContextMenu is null)
        {
            return null;
        }

        border.ContextMenu.PlacementTarget = border;
        border.ContextMenu.IsOpen = true;
        return border.ContextMenu;
    }

    private static Border? FindCard(DependencyObject root)
    {
        if (root is Border { ContextMenu: not null } border)
        {
            return border;
        }

        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            if (FindCard(VisualTreeHelper.GetChild(root, i)) is { } found)
            {
                return found;
            }
        }

        return null;
    }

    /// <summary>截图巡检用：切到某个类别（all / tv / movie / genre / folder）。</summary>
    public void SelectCategoryForShot(string key)
    {
        var button = key.ToLowerInvariant() switch
        {
            "tv" => CatTv,
            "movie" => CatMovie,
            "folder" => CatFolder,
            "genre" => CatGenre,
            _ => CatAll,
        };
        button.IsChecked = true;
    }

    /// <summary>截图巡检用：选排序字段。</summary>
    public void SelectSortForShot(string field)
    {
        foreach (var item in SortBox.Items.OfType<ComboBoxItem>())
        {
            if (string.Equals(item.Tag as string, field, StringComparison.OrdinalIgnoreCase))
            {
                SortBox.SelectedItem = item;
                return;
            }
        }
    }

    private void StepHero(int delta)
    {
        _ = ShowHeroAsync(_heroIndex + delta);

        // 手动翻页后重新计时，别刚看完就自动跳走。
        if (_heroPool.Count > 1)
        {
            _heroTimer.Stop();
            _heroTimer.Start();
        }
    }

    private void OnHeroPrev(object sender, RoutedEventArgs e) => StepHero(-1);

    private void OnHeroNext(object sender, RoutedEventArgs e) => StepHero(1);

    private void OnHeroEnter(object sender, MouseEventArgs e)
    {
        _heroTimer.Stop();
        FadeArrows(1);
    }

    private void OnHeroLeave(object sender, MouseEventArgs e)
    {
        FadeArrows(0);

        if (_heroPool.Count > 1)
        {
            _heroTimer.Start();
        }
    }

    private void FadeArrows(double to)
    {
        var animation = new DoubleAnimation(to, TimeSpan.FromMilliseconds(180));
        HeroPrev.BeginAnimation(OpacityProperty, animation);
        HeroNext.BeginAnimation(OpacityProperty, animation);
    }

    /// <summary>点 Hero 进影片详情，不直接播放——详情页再决定从哪一集开始。</summary>
    private void OnHeroClick(object sender, MouseButtonEventArgs e)
    {
        if (_heroPool.Count == 0)
        {
            return;
        }

        NavigationService?.Navigate(new SeriesPage(_heroPool[_heroIndex].Id));
    }

    /// <summary>
    /// 顶栏一直浮在内容上：Hero 页用渐变压暗，滚动后渐变加深，但不做实底。
    /// 收藏 / 搜索面板和库内网格不需要这层。
    /// </summary>
    private void UpdateTopBar()
    {
        if (BrowseRoot.Visibility == Visibility.Visible)
        {
            TopBar.Visibility = Visibility.Collapsed;
            TopBarScrim.Visibility = Visibility.Collapsed;
            TopBarScrimStrong.Visibility = Visibility.Collapsed;
            return;
        }

        TopBar.Visibility = Visibility.Visible;
        TopBar.Background = Brushes.Transparent;

        var overview = FavoriteEmpty.Visibility != Visibility.Visible &&
                       SearchPanel.Visibility != Visibility.Visible;

        TopBarScrim.Visibility = overview ? Visibility.Visible : Visibility.Collapsed;
        TopBarScrimStrong.Visibility = overview ? Visibility.Visible : Visibility.Collapsed;

        if (overview)
        {
            // 0 → 72px 的滚动距离里，浓渐变从无到有。
            TopBarScrimStrong.Opacity = Math.Clamp((OverviewRoot.VerticalOffset - 12) / 72, 0, 1);
        }
    }

    private void OnOverviewScroll(object sender, ScrollChangedEventArgs e) => UpdateTopBar();

    /// <summary>回到媒体首页（点侧栏的服务器项时用）。</summary>
    public void SelectMediaTab()
    {
        BrowseRoot.Visibility = Visibility.Collapsed;
        OverviewPanel.Visibility = Visibility.Visible;
        FavoriteEmpty.Visibility = Visibility.Collapsed;
        SearchPanel.Visibility = Visibility.Collapsed;
        MediaSegment.IsChecked = true;
        UpdateTopBar();

        if (_heroPool.Count > 1)
        {
            _heroTimer.Start();
        }
    }

    // —— 页内搜索（只在当前服务器里找）——

    private int _inlineSearchVersion;

    private void OnInlineSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        UpdateInlineSearchPlaceholder();
        _ = RunInlineSearchAsync(InlineSearchBox.Text);
    }

    private void UpdateInlineSearchPlaceholder() =>
        InlineSearchPlaceholder.Visibility = string.IsNullOrEmpty(InlineSearchBox.Text)
            ? Visibility.Visible
            : Visibility.Collapsed;

    private void ShowInlineEmpty(string title, string hint)
    {
        InlineSearchEmptyTitle.Text = title;
        InlineSearchEmptyHint.Text = hint;
        InlineSearchEmptyHint.Visibility = string.IsNullOrEmpty(hint)
            ? Visibility.Collapsed
            : Visibility.Visible;
        InlineSearchEmpty.Visibility = Visibility.Visible;
        InlineSearchScroll.Visibility = Visibility.Collapsed;
    }

    /// <summary>
    /// 交给核心搜索（飞牛走 /search/list，Emby 走 SearchTerm），只留当前源的结果。
    /// 命中的可能是某一集，按父级归并成一张卡片，点进去就是那部剧。
    /// </summary>
    private async Task RunInlineSearchAsync(string raw)
    {
        var query = raw.Trim();
        var version = ++_inlineSearchVersion;

        if (query.Length == 0)
        {
            ShowInlineEmpty($"搜索「{SourceTitle.Text}」中的内容", "输入片名、剧名或关键词");
            return;
        }

        var core = AppServices.Instance.Core;
        if (core is null || !AppServices.Instance.IsConnected)
        {
            ShowInlineEmpty("还没有连接媒体源", "先去「服务器」添加一个");
            return;
        }

        ShowInlineEmpty("正在搜索…", "");

        var result = await Task.Run(() => core.Search(query)).ConfigureAwait(true);
        if (version != _inlineSearchVersion)
        {
            return;
        }

        if (!result.Ok || result.Data is null)
        {
            ShowInlineEmpty("搜索失败", result.Error ?? "未知错误");
            return;
        }

        var sourceId = AppServices.Instance.Settings.LastSourceId;
        var shown = result.Data
            .Where(i => sourceId is null || i.SourceId == sourceId)
            .GroupBy(i => string.IsNullOrWhiteSpace(i.ParentId) ? i.Id : i.ParentId!)
            .Select(g => g.OrderByDescending(i => i.LastPlayed ?? 0).First())
            .Select(item => string.IsNullOrWhiteSpace(item.ParentId)
                ? item
                : item with
                {
                    Id = item.ParentId!,
                    Title = string.IsNullOrWhiteSpace(item.ParentTitle) ? item.Title : item.ParentTitle!,
                    Kind = "series",
                })
            .ToList();

        if (version != _inlineSearchVersion)
        {
            return;
        }

        if (shown.Count == 0)
        {
            ShowInlineEmpty($"没有找到「{query}」", "试试剧名或更短的关键词");
            return;
        }

        var cards = shown.Select(ToCard).ToList();
        InlineSearchResults.ItemsSource = cards;
        InlineSearchStatus.Text = $"{cards.Count} 个结果";
        InlineSearchEmpty.Visibility = Visibility.Collapsed;
        InlineSearchScroll.Visibility = Visibility.Visible;

        await Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath))).ConfigureAwait(true);
    }

    private void OnTabChanged(object sender, RoutedEventArgs e)
    {
        // XAML 解析时 MediaSegment 的 IsChecked 先触发，后面的控件字段还没赋值。
        if (SearchSegment is null || FavoriteSegment is null || BrowseRoot is null ||
            SearchPanel is null)
        {
            return;
        }

        // 「搜索」是服务器页内的视图：只搜当前源的库，不跳全局搜索页。
        if (SearchSegment.IsChecked == true)
        {
            OverviewPanel.Visibility = Visibility.Collapsed;
            FavoriteEmpty.Visibility = Visibility.Collapsed;
            BrowseRoot.Visibility = Visibility.Collapsed;
            SearchPanel.Visibility = Visibility.Visible;
            _heroTimer.Stop();
            UpdateTopBar();
            UpdateInlineSearchPlaceholder();
            InlineSearchBox.Focus();
            return;
        }

        SearchPanel.Visibility = Visibility.Collapsed;

        var favorites = FavoriteSegment.IsChecked == true;
        OverviewPanel.Visibility = favorites ? Visibility.Collapsed : Visibility.Visible;
        FavoriteEmpty.Visibility = favorites ? Visibility.Visible : Visibility.Collapsed;
        BrowseRoot.Visibility = Visibility.Collapsed;
        UpdateTopBar();

        if (favorites)
        {
            _heroTimer.Stop();
        }
        else if (_heroPool.Count > 1)
        {
            _heroTimer.Start();
        }
    }

    private async void OnRefreshClick(object sender, RoutedEventArgs e)
    {
        BrowseRoot.Visibility = Visibility.Collapsed;
        OverviewPanel.Visibility = Visibility.Visible;
        FavoriteEmpty.Visibility = Visibility.Collapsed;
        SearchPanel.Visibility = Visibility.Collapsed;
        MediaSegment.IsChecked = true;
        UpdateTopBar();
        _heroTimer.Stop();
        await LoadOverviewAsync().ConfigureAwait(true);
    }

    private async void OnLibraryClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id })
        {
            await ShowLibraryAsync(id).ConfigureAwait(true);
        }
    }

    private async void OnSectionMoreClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string id })
        {
            await ShowLibraryAsync(id).ConfigureAwait(true);
        }
    }

    private void OnBackToOverview(object sender, RoutedEventArgs e)
    {
        BrowseRoot.Visibility = Visibility.Collapsed;
        OverviewPanel.Visibility = Visibility.Visible;
        SearchPanel.Visibility = Visibility.Collapsed;
        UpdateTopBar();

        if (_heroPool.Count > 1)
        {
            _heroTimer.Start();
        }
    }

    // —— 库内网格（原视图） ——

    private async Task ShowLibraryAsync(string libraryId)
    {
        var library = _libraries.FirstOrDefault(l => l.Id == libraryId);
        if (library is null)
        {
            return;
        }

        LibraryBar.ItemsSource = _libraries
            .Select(l => new LibraryChip(l.Id, l.Title, l.Id == libraryId))
            .ToList();
        LibraryScroll.Visibility = _libraries.Count > 1 ? Visibility.Visible : Visibility.Collapsed;

        _heroTimer.Stop();
        OverviewPanel.Visibility = Visibility.Collapsed;
        FavoriteEmpty.Visibility = Visibility.Collapsed;
        SearchPanel.Visibility = Visibility.Collapsed;
        BrowseRoot.Visibility = Visibility.Visible;
        UpdateTopBar();

        _libraryId = library.Id;
        _libraryTitle = library.Title;
        BrowseTitle.Text = library.Title;
        _stack.Clear();
        FilterBox.Text = string.Empty;
        _genres.Clear();
        _activeGenre = null;
        GenreBar.ItemsSource = null;

        await LoadAsync(library.Id, library.Title, children: false).ConfigureAwait(true);
    }

    private async void OnChipClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: string id })
        {
            return;
        }

        var chips = LibraryBar.ItemsSource as List<LibraryChip>;
        if (chips is null)
        {
            return;
        }

        foreach (var chip in chips)
        {
            chip.Active = chip.Id == id;
        }

        // LibraryChip 不是 INotifyPropertyChanged，重新赋值刷新选中态。
        LibraryBar.ItemsSource = null;
        LibraryBar.ItemsSource = chips;

        var active = chips.FirstOrDefault(c => c.Id == id);
        _libraryId = id;
        _libraryTitle = active?.Title ?? "";
        BrowseTitle.Text = _libraryTitle;
        _stack.Clear();
        FilterBox.Text = string.Empty;
        _genres.Clear();
        _activeGenre = null;
        GenreBar.ItemsSource = null;
        await LoadAsync(_libraryId, _libraryTitle, children: false).ConfigureAwait(true);
    }

    private async void OnCardClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        // 网格里的卡片、横向海报行、继续观看卡片共用这个处理器；
        // 只有网格卡片带 Kind，其它卡片都按可播放处理是不对的，
        // 所以这里先查网格数据，找不到再看行卡片。
        var card = _visible.FirstOrDefault(c => c.Id == id);
        if (card is not null)
        {
            if (card.IsPlayable)
            {
                await PlayWindow.OpenAsync(Window.GetWindow(this), id);
                return;
            }

            NavigationService?.Navigate(new SeriesPage(id));
            return;
        }

        var record = _continueCards.FirstOrDefault(c => c.ItemId == id);
        if (record is not null)
        {
            await PlayWindow.OpenAsync(Window.GetWindow(this), id);
            return;
        }

        // 库分组里的海报：先看详情，能播就直接播。
        var core = AppServices.Instance.Core;
        if (core is not null)
        {
            var detail = await Task.Run(() => core.ItemDetail(id)).ConfigureAwait(true);
            if (detail is { Ok: true, Data: not null } && MediaText.IsPlayable(detail.Data.Kind))
            {
                await PlayWindow.OpenAsync(Window.GetWindow(this), id);
                return;
            }
        }

        NavigationService?.Navigate(new SeriesPage(id));
    }

    // —— 卡片右键菜单 ——

    /// <summary>菜单项挂在卡片 Border 上，卡片的 Tag 就是条目 id。</summary>
    private static string? MenuItemId(object? sender)
    {
        if (sender is not MenuItem item)
        {
            return null;
        }

        var menu = item.Parent as ContextMenu
            ?? ItemsControl.ItemsControlFromItemContainer(item) as ContextMenu;
        return (menu?.PlacementTarget as FrameworkElement)?.Tag as string;
    }

    /// <summary>收藏 / 观看状态都是网络写操作，放后台线程，失败在状态行说。</summary>
    private async Task<bool> RunWriteAsync(Func<MediaCore, ApiResult<bool>> action)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return false;
        }

        var result = await Task.Run(() => action(core)).ConfigureAwait(true);
        if (result.Ok)
        {
            return true;
        }

        FlashStatus(result.Error ?? "操作失败");
        return false;
    }

    private async void OnMenuFavorite(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        if (await RunWriteAsync(core => core.SetFavorite(id, true)).ConfigureAwait(true))
        {
            FlashStatus("已添加到收藏夹");
        }
    }

    private async void OnMenuWatched(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        if (!await RunWriteAsync(core => core.SetWatched(id, true)).ConfigureAwait(true))
        {
            return;
        }

        // 看完了就不再出现在「继续观看」。
        RemoveContinueCard(id);
        FlashStatus("已标记为已观看");
    }

    private async void OnMenuUnwatched(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        if (await RunWriteAsync(core => core.SetWatched(id, false)).ConfigureAwait(true))
        {
            FlashStatus("已标记为未观看");
        }
    }

    private async void OnMenuRemoveRecord(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        if (!await RunWriteAsync(core => core.RemovePlayRecord(id)).ConfigureAwait(true))
        {
            return;
        }

        RemoveContinueCard(id);
        FlashStatus("已移除观看记录");
    }

    private async void OnMenuPlay(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        await PlayWindow.OpenAsync(Window.GetWindow(this), id);
    }

    private void RemoveContinueCard(string id)
    {
        var card = _continueCards.FirstOrDefault(c => c.ItemId == id);
        if (card is null)
        {
            return;
        }

        _continueCards.Remove(card);
        ContinueEmpty.Visibility = _continueCards.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ContinueCount.Text = _continueCards.Count == 0 ? "" : $"{_continueCards.Count} ›";
    }

    /// <summary>操作结果只在状态行闪一下，不打断列表和滚动位置。</summary>
    private async void FlashStatus(string message)
    {
        if (BrowseRoot.Visibility == Visibility.Visible)
        {
            BrowseStatus.Text = message;
            await Task.Delay(4000).ConfigureAwait(true);
            if (BrowseStatus.Text == message)
            {
                UpdateBrowseStatus();
            }
            return;
        }

        if (OverviewPanel.Visibility == Visibility.Visible)
        {
            StatusText.Text = message;
            await Task.Delay(4000).ConfigureAwait(true);
            if (StatusText.Text == message)
            {
                StatusText.Text = "";
            }
        }
    }

    private async void OnBackClick(object sender, MouseButtonEventArgs e)
    {
        if (_stack.Count == 0)
        {
            return;
        }

        _stack.RemoveAt(_stack.Count - 1);

        if (_stack.Count == 0)
        {
            await LoadAsync(_libraryId!, _libraryTitle, children: false).ConfigureAwait(true);
            return;
        }

        var parent = _stack[^1];
        await LoadAsync(parent.Id, parent.Title, children: true).ConfigureAwait(true);
    }

    private async Task LoadAsync(string parentId, string title, bool children)
    {
        if (!AppServices.Instance.IsConnected)
        {
            return;
        }

        _parentId = parentId;
        _childrenMode = children;
        UpdateBreadcrumb();

        if (CategoryKey == "genre")
        {
            await EnsureGenresAsync().ConfigureAwait(true);
        }

        await ReloadBrowseAsync().ConfigureAwait(true);
    }

    /// <summary>换类别 / 排序后从头拉第一页。</summary>
    private async Task ReloadBrowseAsync()
    {
        var version = ++_browseVersion;
        _page = 1;
        _hasMore = true;
        _loadingPage = false;
        _retryAfter = DateTime.MinValue;
        _allCards = new List<ItemCard>();
        _visible.Clear();
        _total = 0;
        BrowseStatus.Text = "正在加载…";
        BrowseFooter.Text = "";
        ItemGrid.ItemsSource = _visible;

        await LoadPageAsync(version).ConfigureAwait(true);
    }

    /// <summary>拉下一页并追加到列表末尾；滚到底由 OnBrowseScroll 触发。</summary>
    private async Task LoadPageAsync(int version)
    {
        if (_loadingPage || !_hasMore || _parentId is null || !AppServices.Instance.IsConnected)
        {
            return;
        }

        if (DateTime.UtcNow < _retryAfter)
        {
            return;
        }

        _loadingPage = true;
        // 首屏由状态行说「正在加载」，页脚只在后面续页时出现。
        BrowseFooter.Text = _allCards.Count > 0 ? "正在加载…" : "";
        Trace($"load page {_page} v{version} cat={CategoryKey}");

        var page = _page;
        var parentId = _parentId;
        var children = _childrenMode;
        var query = BuildQuery();
        var core = AppServices.Instance.Core!;

        try
        {
            var result = await Task.Run(() => children
                ? core.Children(parentId, page, PageSize, query)
                : core.Items(parentId, page, PageSize, query)).ConfigureAwait(true);

            if (version != _browseVersion)
            {
                return;
            }

            if (!result.Ok || result.Data is null)
            {
                _retryAfter = DateTime.UtcNow.AddSeconds(3);
                BrowseFooter.Text = "加载失败：" + (result.Error ?? "未知错误");
                return;
            }

            var cards = result.Data.Items.Select(ToCard).ToList();
            Trace($"page {page} ok n={cards.Count} total={result.Data.Total}");
            _page = page + 1;
            _total = result.Data.Total;
            _allCards.AddRange(cards);
            _hasMore = cards.Count > 0 && _allCards.Count < _total;

            AppendVisible(cards);
            UpdateBrowseStatus();
            BrowseFooter.Text = _hasMore ? "" : (_total > 0 ? "已全部加载" : "");

            await FillMissingPostersAsync(cards).ConfigureAwait(true);
        }
        finally
        {
            if (version == _browseVersion)
            {
                _loadingPage = false;
            }
        }
    }

    /// <summary>滚到离底 700px 就续下一页，不再让用户点按钮。</summary>
    private void OnBrowseScroll(object sender, ScrollChangedEventArgs e)
    {
        if (BrowseRoot.Visibility != Visibility.Visible || !_hasMore || _loadingPage)
        {
            return;
        }

        if (e.ExtentHeight - (e.VerticalOffset + e.ViewportHeight) < 700)
        {
            _ = LoadPageAsync(_browseVersion);
        }
    }

    /// <summary>
    /// 未刮削的目录（Directory）列表项不带封面，需要单独取一次详情拿第一张图。
    /// 并发限制在 8 个，避免一页 60 个请求把服务端打满。
    /// </summary>
    private static async Task FillMissingPostersAsync(List<ItemCard> cards)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        var pending = cards.Where(c => c.PosterPath is null && !c.IsPlayable).ToList();

        using var gate = new SemaphoreSlim(8);

        await Task.WhenAll(pending.Select(async card =>
        {
            await gate.WaitAsync().ConfigureAwait(true);
            try
            {
                var detail = await Task.Run(() => core.ItemDetail(card.Id)).ConfigureAwait(true);
                if (detail.Ok && !string.IsNullOrWhiteSpace(detail.Data?.PosterPath))
                {
                    await card.ApplyPosterAsync(detail.Data.PosterPath).ConfigureAwait(true);
                }
            }
            catch (Exception)
            {
                // 一张封面失败不影响列表。
            }
            finally
            {
                gate.Release();
            }
        }));

        await Task.WhenAll(cards.Where(c => c.PosterPath is not null)
            .Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    /// <summary>顶栏搜索：只在已取到的条目里过滤，滚到底仍然会继续取下一页。</summary>
    private void ApplyFilter()
    {
        var query = FilterBox?.Text?.Trim() ?? "";
        _visible.Clear();
        foreach (var card in _allCards.Where(c => Matches(c, query)))
        {
            _visible.Add(card);
        }

        UpdateBrowseStatus();
    }

    private static bool Matches(ItemCard card, string query) =>
        string.IsNullOrEmpty(query) ||
        card.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
        card.Sub.Contains(query, StringComparison.OrdinalIgnoreCase);

    private void AppendVisible(IEnumerable<ItemCard> cards)
    {
        var query = FilterBox?.Text?.Trim() ?? "";
        foreach (var card in cards.Where(c => Matches(c, query)))
        {
            _visible.Add(card);
        }
    }

    private void UpdateBrowseStatus()
    {
        var query = FilterBox?.Text?.Trim() ?? "";
        BrowseStatus.Text = string.IsNullOrEmpty(query)
            ? $"{_libraryTitle} · 共 {_total} 条" +
              (_allCards.Count < _total ? $" · 已加载 {_allCards.Count}" : "")
            : $"{_libraryTitle} · 筛出 {_visible.Count} 条（已加载 {_allCards.Count} 条）";
    }

    private void OnFilterChanged(object sender, TextChangedEventArgs e)
    {
        if (FilterPlaceholder is not null)
        {
            FilterPlaceholder.Visibility = string.IsNullOrEmpty(FilterBox.Text)
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        if (BrowseRoot.Visibility == Visibility.Visible)
        {
            ApplyFilter();
        }
    }

    // —— 类别 / 排序 / 风格 ——

    private string CategoryKey =>
        CatTv.IsChecked == true ? "tv"
        : CatMovie.IsChecked == true ? "movie"
        : CatFolder.IsChecked == true ? "folder"
        : CatGenre.IsChecked == true ? "genre"
        : "all";

    private ListQuery BuildQuery() => new()
    {
        Kinds = CategoryKey switch
        {
            "tv" => new List<string> { "tv" },
            "movie" => new List<string> { "movie" },
            "folder" => new List<string> { "folder" },
            _ => new List<string>(),
        },
        Genre = CategoryKey == "genre" ? _activeGenre : null,
        Sort = _sortField,
        Descending = _sortDescending,
    };

    private async void OnCategoryChanged(object sender, RoutedEventArgs e)
    {
        if (BrowseRoot is null || BrowseRoot.Visibility != Visibility.Visible)
        {
            return;
        }

        GenreScroll.Visibility = CategoryKey == "genre"
            ? Visibility.Visible
            : Visibility.Collapsed;

        if (CategoryKey == "genre")
        {
            await EnsureGenresAsync().ConfigureAwait(true);
        }

        await ReloadBrowseAsync().ConfigureAwait(true);
    }

    private async Task EnsureGenresAsync()
    {
        if (_genres.Count > 0 || _libraryId is null)
        {
            RenderGenres();
            return;
        }

        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        var result = await Task.Run(() => core.Genres(_libraryId)).ConfigureAwait(true);
        Trace($"genres scope={_libraryId} ok={result.Ok} n={result.Data?.Count} err={result.Error}");
        if (!result.Ok || result.Data is null)
        {
            RenderGenres();
            return;
        }

        _genres = result.Data;
        if (_activeGenre is null || _genres.All(g => g.Id != _activeGenre))
        {
            _activeGenre = _genres.FirstOrDefault()?.Id;
        }

        RenderGenres();
    }

    private void RenderGenres()
    {
        GenreBar.ItemsSource = _genres
            .Select(g => new GenreChip(g.Id, GenreLabel(g.Title), g.Id == _activeGenre))
            .ToList();
    }

    /// <summary>飞牛返回的是 TMDB 的英文风格名，界面上用中文。</summary>
    private static string GenreLabel(string title) => title switch
    {
        "Action" => "动作",
        "Adventure" => "冒险",
        "Animation" => "动画",
        "Comedy" => "喜剧",
        "Crime" => "犯罪",
        "Documentary" => "纪录",
        "Drama" => "剧情",
        "Family" => "家庭",
        "Fantasy" => "奇幻",
        "History" => "历史",
        "Horror" => "恐怖",
        "Music" => "音乐",
        "Mystery" => "悬疑",
        "Romance" => "爱情",
        "Science Fiction" => "科幻",
        "TV Movie" => "电视电影",
        "Thriller" => "惊悚",
        "War" => "战争",
        "War & Politics" => "战争与政治",
        "Western" => "西部",
        "Action & Adventure" => "动作冒险",
        "Sci-Fi & Fantasy" => "科幻奇幻",
        "Kids" => "儿童",
        "News" => "新闻",
        "Reality" => "真人秀",
        "Soap" => "肥皂剧",
        "Talk" => "脱口秀",
        "Sports" => "体育",
        "Finance" => "财经",
        "Education" => "教育",
        "Lifestyle" => "生活",
        "Local" => "本地",
        "Others" => "其他",
        _ => title,
    };

    private async void OnGenreClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: string id } || id == _activeGenre)
        {
            return;
        }

        _activeGenre = id;
        RenderGenres();
        await ReloadBrowseAsync().ConfigureAwait(true);
    }

    private async void OnSortChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SortBox.SelectedItem is not ComboBoxItem { Tag: string field })
        {
            return;
        }

        if (field != _sortField)
        {
            _sortField = field;
            // 名称默认升序，其它字段默认把最新的 / 最高分放前面。
            _sortDescending = field != "name";
            UpdateSortIcon();
        }

        if (BrowseRoot is { Visibility: Visibility.Visible })
        {
            await ReloadBrowseAsync().ConfigureAwait(true);
        }
    }

    private async void OnSortDirClick(object sender, RoutedEventArgs e)
    {
        _sortDescending = !_sortDescending;
        UpdateSortIcon();

        if (BrowseRoot is { Visibility: Visibility.Visible })
        {
            await ReloadBrowseAsync().ConfigureAwait(true);
        }
    }

    private void UpdateSortIcon()
    {
        // E74A 向上（升序），E74B 向下（降序）。
        SortDirIcon.Text = _sortDescending ? "\uE74B" : "\uE74A";
        SortDirButton.ToolTip = _sortDescending ? "当前降序，点击改升序" : "当前升序，点击改降序";
    }

    private void UpdateBreadcrumb()
    {
        var inFolder = _childrenMode && _stack.Count > 0;
        Breadcrumb.Visibility = inFolder ? Visibility.Visible : Visibility.Collapsed;

        if (inFolder)
        {
            var trail = string.Join("  ›  ", _stack.Select(s => s.Title));
            BreadcrumbText.Text = $"{_libraryTitle}  ›  {trail}";
        }
    }

    // —— 横向滚动 ——

    private void OnScrollLeft(object sender, RoutedEventArgs e) => ScrollRow(sender, -ScrollStep);

    private void OnScrollRight(object sender, RoutedEventArgs e) => ScrollRow(sender, ScrollStep);

    /// <summary>
    /// 横向行自己会吞掉滚轮（纵向滚动被禁用），鼠标停在封面上时整页就滚不动了。
    /// 这里把滚轮转交给外层纵向 ScrollViewer，横向只用箭头。
    /// </summary>
    private void OnRowWheel(object sender, MouseWheelEventArgs e)
    {
        if (sender is not DependencyObject node)
        {
            return;
        }

        var vertical = FindVerticalScroll(node);
        if (vertical is null)
        {
            return;
        }

        vertical.ScrollToVerticalOffset(vertical.VerticalOffset - e.Delta * 0.5);
        e.Handled = true;
    }

    private static ScrollViewer? FindVerticalScroll(DependencyObject node)
    {
        for (var parent = VisualTreeHelper.GetParent(node); parent is not null;
             parent = VisualTreeHelper.GetParent(parent))
        {
            if (parent is ScrollViewer { VerticalScrollBarVisibility: not ScrollBarVisibility.Disabled } scroll)
            {
                return scroll;
            }
        }

        return null;
    }

    private static void ScrollRow(object sender, double delta)
    {
        if (FindRow(sender) is { } row)
        {
            Animate(row, row.HorizontalOffset + delta);
        }
    }

    private static void Animate(ScrollViewer row, double target)
    {
        var clamped = Math.Clamp(target, 0, row.ScrollableWidth);

        row.BeginAnimation(SmoothScroll.OffsetProperty, null);
        SmoothScroll.SetOffset(row, row.HorizontalOffset);

        var animation = new DoubleAnimation(row.HorizontalOffset, clamped,
            TimeSpan.FromMilliseconds(260))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };

        row.BeginAnimation(SmoothScroll.OffsetProperty, animation);
    }

    private static ScrollViewer? FindRow(object sender)
    {
        if (sender is Button { Tag: ScrollViewer tagged })
        {
            return tagged;
        }

        if (sender is not DependencyObject node)
        {
            return null;
        }

        for (var parent = VisualTreeHelper.GetParent(node); parent is not null;
             parent = VisualTreeHelper.GetParent(parent))
        {
            if (parent is ScrollViewer scroll)
            {
                return scroll;
            }

            if (parent is Panel panel &&
                panel.Children.OfType<ScrollViewer>().FirstOrDefault() is { } inner)
            {
                return inner;
            }
        }

        return null;
    }

    // —— 数据装配 ——

    private static ItemCard ToCard(MediaItemDto item)
    {
        var showBadge = AppServices.Instance.Settings.ShowResolution &&
                        !string.IsNullOrEmpty(item.Resolution);

        var card = new ItemCard
        {
            Id = item.Id,
            Kind = item.Kind,
            Title = MediaText.Clean(item.Title),
            Sub = MediaText.Describe(item),
            Badge = showBadge ? item.Resolution! : "",
            BadgeVisibility = showBadge ? Visibility.Visible : Visibility.Collapsed,
            PosterPath = item.PosterPath,
            Initial = Palette.InitialOf(item.Title),
        };
        card.UseGradient(item.Id + item.Title);
        return card;
    }

    private static RecordCard ToRecordCard(PlayRecordDto record)
    {
        var progress = record.DurationSeconds <= 0
            ? 0
            : Math.Clamp((double)record.PositionSeconds / record.DurationSeconds, 0, 1);

        var title = MediaText.RecordTitle(record);
        var card = new RecordCard
        {
            ItemId = record.ItemId,
            Title = title,
            Sub = $"{(int)(progress * 100)}%",
            Time = Format(record.DurationSeconds),
            BarWidth = Math.Max(0, 248 * progress),
            PosterPath = record.PosterPath,
            Initial = Palette.InitialOf(title),
        };
        card.UseGradient(record.ItemId + title);
        return card;
    }

    private static string Format(long seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1
            ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}"
            : $"{t.Minutes:00}:{t.Seconds:00}";
    }

    private sealed class GenreChip
    {
        public GenreChip(string id, string title, bool active)
        {
            Id = id;
            Title = title;
            Active = active;
        }

        public string Id { get; }

        public string Title { get; }

        public bool Active { get; }
    }

    private sealed class LibraryChip
    {
        public LibraryChip(string id, string title, bool active)
        {
            Id = id;
            Title = title;
            Active = active;
        }

        public string Id { get; }

        public string Title { get; }

        public bool Active { get; set; }
    }

    private sealed class ItemCard : CardVisual
    {
        public string Id { get; init; } = "";
        public string Kind { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public Visibility BadgeVisibility { get; init; } = Visibility.Collapsed;

        public bool IsPlayable => MediaText.IsPlayable(Kind);
    }

    private sealed class RecordCard : CardVisual
    {
        public string ItemId { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Time { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public double BarWidth { get; init; }
    }

    private sealed class LibraryCardItem : CardVisual
    {
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string Initial { get; init; } = "";

        /// <summary>最近入库的三张海报，没凑齐时按实际张数分栏。</summary>
        public ObservableCollection<LibraryArt> Arts { get; } = new();

        public int ArtColumns => Math.Max(1, Arts.Count);
    }

    private sealed class LibraryArt : CardVisual
    {
        public string Initial { get; init; } = "";
        public string? Path { get; init; }
    }

    private sealed class HeroItem
    {
        public string Id { get; init; } = "";
        public string Kind { get; init; } = "";
        public string Title { get; init; } = "";
        public string Meta { get; init; } = "";
        public string Overview { get; init; } = "";
        public List<string> Chips { get; init; } = new();
        public string? BackdropPath { get; init; }
    }

    private sealed class HeroDot
    {
        public HeroDot(bool active) => Fill = active
            ? new SolidColorBrush(Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF))
            : new SolidColorBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF));

        public Brush Fill { get; }
    }

    private sealed class HomeSnapshot
    {
        public string SourceId { get; set; } = "";
        public List<LibrarySnapshot> Pages { get; set; } = new();
        public List<MediaDetailDto> Heroes { get; set; } = new();
        public List<PlayRecordDto> Records { get; set; } = new();
        public long SavedAt { get; set; }
    }

    private sealed class LibrarySnapshot
    {
        public MediaLibraryDto Library { get; set; } = null!;
        public List<MediaItemDto> Items { get; set; } = new();
        public int Total { get; set; }
    }

    private sealed class LibrarySection
    {
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string CountLabel { get; init; } = "";
        public List<ItemCard> Items { get; init; } = new();
    }
}