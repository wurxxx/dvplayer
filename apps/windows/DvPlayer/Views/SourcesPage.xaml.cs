using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 媒体源管理页。源是一张张卡片，
/// 顶栏一个刷新、一个添加，添加表单按需展开，不常驻占地方。
/// </summary>
public partial class SourcesPage : Page
{
    public SourcesPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
        AppServices.Instance.ConnectionChanged += OnConnectionChanged;

        FillKinds();
        RefreshSources();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
    }

    private void OnConnectionChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(RefreshSources);

    /// <summary>类型下拉由核心给出；核心没加载时至少保留飞牛。</summary>
    private void FillKinds()
    {
        if (KindBox.Items.Count > 0)
        {
            return;
        }

        var kinds = MediaCore.SupportedKinds();
        if (kinds.Count == 0)
        {
            kinds = new List<string> { "fnos" };
        }

        KindBox.ItemsSource = kinds
            .Select(k => new KindOption(k, MediaText.SourceKindLabel(k)))
            .ToList();
        KindBox.SelectedIndex = 0;
    }

    private void RefreshSources()
    {
        var services = AppServices.Instance;
        var sources = services.Settings.Sources;
        var connections = services.Connections;

        SourceGrid.ItemsSource = sources
            .Select(s =>
            {
                var connection = connections.FirstOrDefault(c => c.Id == s.Id);
                var kind = MediaText.SourceKindLabel(s.Kind);

                // 连接结果三分：没试过 / 连上 / 失败。
                var (status, brush) = connection is null
                    ? ("尚未连接", "FaintBrush")
                    : connection.Ok
                        ? ("已连接 · " + DateTime.Now.ToString("HH:mm"), "SuccessBrush")
                        : ("连接失败：" + (connection.Error ?? "未知错误"), "DangerBrush");

                return new SourceCard
                {
                    Id = s.Id,
                    Name = s.Name,
                    KindLabel = kind,
                    Icon = s.Kind switch
                    {
                        "emby" or "jellyfin" => "\uE774",
                        _ => "\uE7F4",
                    },
                    Base = s.Base,
                    StatusText = status,
                    StatusBrush = (Brush)Application.Current.Resources[brush]!,
                };
            })
            .ToList();

        var ok = connections.Count(c => c.Ok);
        EmptyState.Visibility = sources.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ReconnectButton.IsEnabled = sources.Count > 0;

        StatusText.Text = sources.Count == 0
            ? ""
            : ok == sources.Count
                ? $"{sources.Count} 个服务器 · 全部已连接"
                : $"{sources.Count} 个服务器 · {ok} 个已连接";
    }

    private void OnAddToggleClick(object sender, RoutedEventArgs e)
    {
        if (AddPanel.Visibility == Visibility.Visible)
        {
            AddPanel.Visibility = Visibility.Collapsed;
            AddStatus.Text = "";
            return;
        }

        AddPanel.Visibility = Visibility.Visible;
        NameBox.Focus();
    }

    private async void OnReconnectClick(object sender, RoutedEventArgs e)
    {
        await ReconnectAsync("已重新连接全部服务器。");
    }

    private async void OnRemoveClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id })
        {
            return;
        }

        var settings = AppServices.Instance.Settings;
        var source = settings.Sources.FirstOrDefault(s => s.Id == id);
        if (source is null)
        {
            return;
        }

        // 删除要重连整库，误触代价不小，先确认。
        var answer = MessageBox.Show(Window.GetWindow(this)!,
            $"删除服务器「{source.Name}」？\n播放记录与已收藏的进度都还在，重新添加这个源就能接上。",
            "删除服务器", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.OK)
        {
            return;
        }

        settings.Sources.RemoveAll(s => s.Id == id);
        if (settings.LastSourceId == id)
        {
            settings.LastSourceId = null;
        }

        settings.Save();

        if (settings.Sources.Count == 0)
        {
            AppServices.Instance.Disconnect();
            RefreshSources();
            (Window.GetWindow(this) as MainWindow)?.RefreshSourceStatus();
            StatusText.Text = "已删除所有服务器。";
            return;
        }

        await ReconnectAsync("已删除，其它源重新连好了。");
    }

    private async void OnAddClick(object sender, RoutedEventArgs e)
    {
        var name = string.IsNullOrWhiteSpace(NameBox.Text) ? "飞牛影视" : NameBox.Text.Trim();
        var baseUri = BaseBox.Text.Trim();
        var user = UserBox.Text.Trim();
        var pass = PassBox.Password;
        var kind = (KindBox.SelectedItem as KindOption)?.Kind ?? "fnos";

        if (!Uri.TryCreate(baseUri, UriKind.Absolute, out _))
        {
            AddStatus.Text = "服务器地址无效，例如 http://10.0.0.134:8005";
            return;
        }

        // Emby / Jellyfin 支持只填 API Key：用户名留空，密码框里放 Key。
        var apiKeyOnly = kind is "emby" or "jellyfin";
        if (string.IsNullOrEmpty(user) && (!apiKeyOnly || string.IsNullOrEmpty(pass)))
        {
            AddStatus.Text = apiKeyOnly
                ? "请填写用户名，或只填 API Key（密码框）。"
                : "请填写用户名。";
            return;
        }

        var config = new SourceConfig(
            "src-" + Guid.NewGuid().ToString("N")[..8],
            name,
            kind,
            baseUri,
            user,
            pass);

        // 同一地址同一账号不重复加，按最新提交的为准。
        var settings = AppServices.Instance.Settings;
        settings.Sources.RemoveAll(s => s.Base == baseUri && s.Username == user);
        settings.Sources.Add(config);
        settings.LastSourceId = config.Id;
        settings.Save();

        AddStatus.Text = "正在连接…";
        var (ok, error) = await ReconnectAsync(null);

        if (ok)
        {
            AddStatus.Text = "已连接：" + name;
            PassBox.Password = string.Empty;
            AddPanel.Visibility = Visibility.Collapsed;
            AddStatus.Text = "";
            StatusText.Text = "已添加并连接：" + name;
        }
        else
        {
            AddStatus.Text = "连接失败：" + (error ?? "未知错误");
        }
    }

    /// <summary>重建聚合句柄（加/删源之后必须重连，hub 是新建的）。</summary>
    private async Task<(bool Ok, string? Error)> ReconnectAsync(string? okMessage)
    {
        StatusText.Text = "正在连接…";

        var (ok, error) = await AppServices.Instance.ConnectAllAsync().ConfigureAwait(true);

        RefreshSources();
        (Window.GetWindow(this) as MainWindow)?.RefreshSourceStatus();

        StatusText.Text = ok
            ? okMessage ?? $"已连接 {AppServices.Instance.SourceSummary}"
            : "连接失败：" + (error ?? "未知错误");

        return (ok, error);
    }

    private sealed class SourceCard
    {
        public string Id { get; init; } = "";
        public string Name { get; init; } = "";
        public string KindLabel { get; init; } = "";
        public string Icon { get; init; } = "";
        public string Base { get; init; } = "";
        public string StatusText { get; init; } = "";
        public Brush? StatusBrush { get; init; }
    }

    /// <summary>下拉项：核心里是 kind，界面上显示中文名。</summary>
    private sealed record KindOption(string Kind, string Label);
}