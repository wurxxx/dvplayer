using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class SettingsPage : Page
{
    public SettingsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged += OnConnectionChanged;

        FillKinds();
        RefreshSources();
        VersionText.Text = "DV Player · 核心 " + (AppServices.Instance.CoreVersion ?? "未加载");
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
    }

    /// <summary>别处连上/断开后，这一页的状态徽标跟着变。</summary>
    private void OnConnectionChanged(object? sender, EventArgs e) => Dispatcher.Invoke(RefreshSources);

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

        SourceList.ItemsSource = sources
            .Select(s =>
            {
                var connection = connections.FirstOrDefault(c => c.Id == s.Id);
                var kind = MediaText.SourceKindLabel(s.Kind);

                // 连接结果三分：没试过 / 连上 / 失败。
                var (badge, brush) = connection is null
                    ? ("未连接", "FaintBrush")
                    : connection.Ok
                        ? ("已连接", "AccentBrush")
                        : ("连接失败", "DangerBrush");

                var subtitle = connection is { Ok: false, Error: { Length: > 0 } error }
                    ? $"{kind} · {error}"
                    : $"{kind} · {s.Base}";

                return new SourceRow
                {
                    Id = s.Id,
                    Title = s.Name,
                    Subtitle = subtitle,
                    Badge = badge,
                    BadgeBrush = (Brush)Application.Current.Resources[brush]!,
                };
            })
            .ToList();

        EmptyHint.Visibility = sources.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ConnectAllButton.IsEnabled = sources.Count > 0;
    }

    private async void OnReconnectClick(object sender, RoutedEventArgs e)
    {
        await ReconnectAsync();
    }

    private async void OnRemoveClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id })
        {
            return;
        }

        var settings = AppServices.Instance.Settings;
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
            StatusText.Text = "已删除所有媒体源。";
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
            StatusText.Text = "服务器地址无效，例如 http://10.0.0.134:8005";
            return;
        }

        if (string.IsNullOrEmpty(user))
        {
            StatusText.Text = "请填写用户名。";
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

        StatusText.Text = "正在连接…";
        var (ok, error) = await ReconnectAsync(okOnNew: $"已连接：{name}");

        if (ok)
        {
            PassBox.Password = string.Empty;
        }
        else
        {
            StatusText.Text = "连接失败：" + (error ?? "未知错误");
        }
    }

    /// <summary>重建聚合句柄（加/删源之后必须重连，hub 是新建的）。</summary>
    private async Task<(bool Ok, string? Error)> ReconnectAsync(string? okOnNew = null)
    {
        StatusText.Text = "正在连接…";

        var (ok, error) = await AppServices.Instance.ConnectAllAsync().ConfigureAwait(true);

        RefreshSources();
        (Window.GetWindow(this) as MainWindow)?.RefreshSourceStatus();

        StatusText.Text = ok
            ? okOnNew ?? $"已连接 {AppServices.Instance.SourceSummary}"
            : "连接失败：" + (error ?? "未知错误");

        return (ok, error);
    }

    private sealed class SourceRow
    {
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string Subtitle { get; init; } = "";
        public string Badge { get; init; } = "";
        public Brush? BadgeBrush { get; init; }
    }

    /// <summary>下拉项：核心里是 kind，界面上显示中文名。</summary>
    private sealed record KindOption(string Kind, string Label);
}
