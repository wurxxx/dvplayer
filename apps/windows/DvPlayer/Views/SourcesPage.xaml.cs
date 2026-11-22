using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DvPlayer.Dialogs;
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

    /// <summary>正在编辑的源；null 表示是新增。</summary>
    private string? _editingId;

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

    /// <summary>类型按钮按核心支持的种类启用；核心没加载时至少保留飞牛。</summary>
    private void FillKinds()
    {
        var kinds = MediaCore.SupportedKinds();
        if (kinds.Count == 0)
        {
            kinds = new List<string> { "fnos" };
        }

        KindFnos.IsEnabled = kinds.Contains("fnos");
        KindEmby.IsEnabled = kinds.Contains("emby");
        KindJellyfin.IsEnabled = kinds.Contains("jellyfin");

        // 本地文件夹和文件协议源都走核心的 local 扫描，核心支持 local 就能用。
        var folder = kinds.Contains("local");
        KindLocal.IsEnabled = folder;
        KindSmb.IsEnabled = folder;
        KindNfs.IsEnabled = folder;
        KindWebdav.IsEnabled = folder;

        if (KindFnos.IsEnabled)
        {
            KindFnos.IsChecked = true;
        }
        else if (KindEmby.IsEnabled)
        {
            KindEmby.IsChecked = true;
        }
        else if (KindJellyfin.IsEnabled)
        {
            KindJellyfin.IsChecked = true;
        }
    }

    /// <summary>当前选中的类型。</summary>
    private string SelectedKind() =>
        KindEmby.IsChecked == true ? "emby"
        : KindJellyfin.IsChecked == true ? "jellyfin"
        : KindSmb.IsChecked == true ? "smb"
        : KindNfs.IsChecked == true ? "nfs"
        : KindWebdav.IsChecked == true ? "webdav"
        : KindLocal.IsChecked == true ? "local"
        : "fnos";

    private void SelectKind(string kind)
    {
        KindFnos.IsChecked = kind == "fnos";
        KindEmby.IsChecked = kind == "emby";
        KindJellyfin.IsChecked = kind == "jellyfin";
        KindSmb.IsChecked = kind is "smb" or "cifs";
        KindNfs.IsChecked = kind == "nfs";
        KindWebdav.IsChecked = kind == "webdav";
        KindLocal.IsChecked = kind == "local";
        UpdateKindUi();
    }

    /// <summary>表单标题 / 默认名里的类型称呼。</summary>
    private static string TypeNoun(string kind) => kind switch
    {
        "local" => "本地文件夹",
        "smb" or "cifs" => "SMB",
        "nfs" => "NFS",
        "webdav" => "WebDAV",
        "emby" => "Emby",
        "jellyfin" => "Jellyfin",
        _ => "服务器",
    };

    private const string DefaultBase = "http://10.0.0.134:8005";

    private void OnKindChanged(object sender, RoutedEventArgs e) => UpdateKindUi();

    /// <summary>每个类型要的字段不一样：本地要路径，文件协议要地址（加账号），服务器要地址加账号。</summary>
    private void UpdateKindUi()
    {
        // InitializeComponent 里 IsChecked="True" 会先触发一次，那时控件还没建全。
        if (CredentialPanel is null || BaseLabel is null || AddTitle is null || ProxyPanel is null)
        {
            return;
        }

        var kind = SelectedKind();
        var local = kind == "local";
        // 飞牛影视也要账号密码（原来漏了，加文件协议源时把凭据面板一起藏掉了）。
        var needsCredentials =
            kind is "fnos" or "feiniu" or "emby" or "jellyfin" or "smb" or "cifs" or "webdav";

        CredentialPanel.Visibility = needsCredentials ? Visibility.Visible : Visibility.Collapsed;
        Services.Trace.Write($"source form kind={kind} credentials={CredentialPanel.Visibility}");
        // 只有走 HTTP 的服务器才有代理：本地目录、SMB / NFS / WebDAV 是系统挂载。
        ProxyPanel.Visibility = kind is "fnos" or "feiniu" or "emby" or "jellyfin"
            ? Visibility.Visible
            : Visibility.Collapsed;
        BrowseButton.Visibility = local ? Visibility.Visible : Visibility.Collapsed;
        BaseLabel.Text = kind switch
        {
            "local" => "文件夹 / ISO",
            "smb" or "cifs" => "SMB 地址",
            "nfs" => "NFS 地址",
            "webdav" => "WebDAV 地址",
            _ => "服务器地址",
        };

        FormHint.Text = kind switch
        {
            "local" => "目录里的每个视频是一个条目；剧按 Season / S01E01 分季分集，ISO 原盘也能播。",
            "smb" or "cifs" => "写到共享名，例如 smb://192.168.1.10/影视；系统挂载后直接读本地路径，ISO 原盘也能播。",
            "nfs" => "Windows 需要先启用「NFS 客户端」功能；不需要账号密码就留空。",
            "webdav" => "Windows 需要启用「WebClient」服务（默认关闭），服务器要支持 WebDAV。",
            _ => "飞牛影视 / Emby / Jellyfin 用账号密码登录；Emby 也可以只填 API Key（用户名留空）。",
        };

        UserLabel.Text = kind is "emby" or "jellyfin"
            ? "用户名（可留空，只用 API Key）"
            : "用户名";
        PassLabel.Text = kind is "emby" or "jellyfin" ? "密码 / API Key" : "密码";

        AddTitle.Text = (_editingId is null ? "添加" : "编辑") + TypeNoun(kind);
        AddSubmitButton.Content = _editingId is null ? "添加并连接" : "保存并连接";

        // 切换类型时别把上一个类型的示例值留在框里。
        var sample = kind switch
        {
            "local" => string.Empty,
            "smb" or "cifs" => "smb://192.168.1.10/影视",
            "nfs" => "nfs://192.168.1.10:/volume1/media",
            "webdav" => "https://192.168.1.10:5006/dav",
            _ => DefaultBase,
        };
        var current = BaseBox.Text.Trim();
        if (string.IsNullOrEmpty(current) || IsSampleAddress(current))
        {
            BaseBox.Text = sample;
        }

        // 名称还是默认值（或空）就跟着类型走。
        if (string.IsNullOrWhiteSpace(NameBox.Text) || IsDefaultName(NameBox.Text))
        {
            NameBox.Text = TypeNoun(kind);
        }
    }

    private static readonly string[] SampleAddresses =
    {
        DefaultBase,
        "smb://192.168.1.10/影视",
        "nfs://192.168.1.10:/volume1/media",
        "https://192.168.1.10:5006/dav",
    };

    private static bool IsSampleAddress(string text) =>
        SampleAddresses.Contains(text);

    private static readonly string[] DefaultNames =
    {
        "飞牛影视", "Emby", "Jellyfin", "SMB", "NFS", "WebDAV", "本地文件夹",
    };

    private static bool IsDefaultName(string text) => DefaultNames.Contains(text);

    /// <summary>本地源选目录（ISO 也可以直接在地址框里填路径）。</summary>
    private void OnBrowseClick(object sender, RoutedEventArgs e)
    {
        var picker = new Microsoft.Win32.OpenFolderDialog
        {
            Title = "选择要加入媒体库的文件夹",
            Multiselect = false,
        };

        if (picker.ShowDialog(Window.GetWindow(this)) == true)
        {
            BaseBox.Text = picker.FolderName;
            if (string.IsNullOrWhiteSpace(NameBox.Text) ||
                NameBox.Text == "飞牛影视" || NameBox.Text == "本地文件")
            {
                NameBox.Text = System.IO.Path.GetFileName(
                    picker.FolderName.TrimEnd(System.IO.Path.DirectorySeparatorChar));
            }
        }
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
                    IconPath = SourceIcons.Pack(s.Kind),
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
            CloseAddPanel();
            return;
        }

        ResetAddPanel();
        AddPanel.Visibility = Visibility.Visible;
        NameBox.Focus();
    }

    /// <summary>收起表单并回到「新增」状态。</summary>
    private void CloseAddPanel()
    {
        AddPanel.Visibility = Visibility.Collapsed;
        AddStatus.Text = "";
        _editingId = null;
        ResetAddPanel();
    }

    private void ResetAddPanel()
    {
        AddTitle.Text = "添加服务器";
        AddSubmitButton.Content = "添加并连接";
        AddStatus.Text = "";
        NameBox.Text = "飞牛影视";
        BaseBox.Text = DefaultBase;
        UserBox.Text = string.Empty;
        PassBox.Password = string.Empty;
        ProxyBox.Text = string.Empty;
        SelectKind("fnos");
    }

    /// <summary>截图巡检用：打开第一个源的编辑表单。</summary>
    public void EditFirstSourceForShot()
    {
        var first = AppServices.Instance.Settings.Sources.FirstOrDefault();
        if (first is not null)
        {
            StartEdit(first.Id, scrollIntoView: false);
        }
    }

    private void OnEditClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string id })
        {
            StartEdit(id, scrollIntoView: true);
        }
    }

    /// <summary>编辑：把现有源填回表单，密码留空表示不改。</summary>
    private void StartEdit(string id, bool scrollIntoView)
    {
        var source = AppServices.Instance.Settings.Sources.FirstOrDefault(s => s.Id == id);
        if (source is null)
        {
            return;
        }

        _editingId = id;
        AddPanel.Visibility = Visibility.Visible;
        AddTitle.Text = "编辑服务器";
        AddSubmitButton.Content = "保存并连接";

        SelectKind(source.Kind);
        UpdateKindUi();

        NameBox.Text = source.Name;
        BaseBox.Text = source.Base;
        UserBox.Text = source.Username;
        PassBox.Password = string.Empty;
        ProxyBox.Text = source.Proxy;
        // NFS 没有密码框，别留一句「密码留空」让人找。
        AddStatus.Text = SelectedKind() == "nfs" ? string.Empty : "密码留空表示不修改。";

        NameBox.Focus();
        if (scrollIntoView)
        {
            AddPanel.BringIntoView();
        }
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

        // 删除要重连整库，误触代价不小，先确认（用 app 自己的深色确认框）。
        var confirmed = ConfirmDialog.Ask(Window.GetWindow(this),
            "删除服务器",
            $"删除服务器「{source.Name}」？\n播放记录与已收藏的进度都还在，\n重新添加这个源就能接上。",
            "删除");
        if (!confirmed)
        {
            return;
        }

        NetMount.Release(id);
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
        var proxy = ProxyBox.Text.Trim();
        var user = UserBox.Text.Trim();
        var pass = PassBox.Password;
        var kind = SelectedKind();

        // 本地文件夹：校验路径，不要账号密码，进度文件放本机配置目录。
        if (kind == "local")
        {
            if (!Directory.Exists(baseUri) && !File.Exists(baseUri))
            {
                AddStatus.Text = "路径不存在，先点「浏览…」选一个文件夹。";
                return;
            }

            var localSettings = AppServices.Instance.Settings;
            var localConfig = new SourceConfig(
                _editingId ?? "src-" + Guid.NewGuid().ToString("N")[..8],
                string.IsNullOrWhiteSpace(NameBox.Text) ? "本地文件" : NameBox.Text.Trim(),
                "local",
                baseUri,
                string.Empty,
                string.Empty,
                Path.GetDirectoryName(AppSettings.FilePath) ?? string.Empty);

            localSettings.Sources.RemoveAll(s => s.Id == localConfig.Id);
            localSettings.Sources.Add(localConfig);
            localSettings.LastSourceId = localConfig.Id;
            localSettings.Save();

            AddStatus.Text = "正在扫描…";
            var (localOk, localError) = await ReconnectAsync(null);
            if (localOk)
            {
                CloseAddPanel();
                StatusText.Text = "已添加本地文件夹：" + localConfig.Name;
                (Window.GetWindow(this) as MainWindow)?.OpenSourceById(localConfig.Id);
            }
            else
            {
                AddStatus.Text = "添加失败：" + (localError ?? "读不到这个目录");
            }

            return;
        }

        // 文件协议源：地址不是 http，交给系统去挂载；NFS 可以匿名。
        var mount = NetMount.IsMount(kind);
        if (mount && string.IsNullOrWhiteSpace(baseUri))
        {
            AddStatus.Text = kind switch
            {
                "nfs" => "填 NFS 地址，例如 nfs://192.168.1.10:/volume1/media",
                "webdav" => "填 WebDAV 地址，例如 https://192.168.1.10:5006/dav",
                _ => "填 SMB 地址，例如 smb://192.168.1.10/影视",
            };
            return;
        }

        if (!mount && !Uri.TryCreate(baseUri, UriKind.Absolute, out _))
        {
            AddStatus.Text = "服务器地址无效，例如 http://10.0.0.134:8005";
            return;
        }

        // Emby / Jellyfin 支持只填 API Key：用户名留空，密码框里放 Key。
        // 编辑时允许两项都留空（表示沿用原凭据）；NFS 匿名挂载不需要账号。
        var apiKeyOnly = kind is "emby" or "jellyfin";
        var anonymous = kind == "nfs";
        var editingExisting = _editingId is not null;
        if (!anonymous && !editingExisting &&
            string.IsNullOrEmpty(user) && (!apiKeyOnly || string.IsNullOrEmpty(pass)))
        {
            AddStatus.Text = apiKeyOnly
                ? "请填写用户名，或只填 API Key（密码框）。"
                : "请填写用户名。";
            return;
        }

        var settings = AppServices.Instance.Settings;
        var editing = _editingId is null
            ? null
            : settings.Sources.FirstOrDefault(s => s.Id == _editingId);

        // 编辑时密码留空 = 沿用原来的密码。
        var effectivePass = string.IsNullOrEmpty(pass) && editing is not null
            ? editing.Password
            : pass;

        if (!anonymous && editing is null && string.IsNullOrEmpty(effectivePass))
        {
            AddStatus.Text = "请填写密码或 API Key。";
            return;
        }

        // 文件协议源的配置保留原始类型和地址（表单回显），连接时才换成挂载后的本地路径。
        var dataDir = mount
            ? Path.GetDirectoryName(AppSettings.FilePath) ?? string.Empty
            : string.Empty;
        var config = new SourceConfig(
            editing?.Id ?? "src-" + Guid.NewGuid().ToString("N")[..8],
            name,
            kind,
            baseUri,
            user,
            effectivePass,
            dataDir,
            proxy);

        // 地址可能变了，先卸掉旧的挂载（重连时会按新地址重挂）。
        if (editing is not null)
        {
            NetMount.Release(editing.Id);
        }

        // 同一地址同一账号不重复加，按最新提交的为准（编辑自己不算重复）。
        settings.Sources.RemoveAll(s =>
            s.Id != config.Id && s.Base == baseUri && s.Username == user);
        settings.Sources.RemoveAll(s => s.Id == config.Id);
        settings.Sources.Add(config);
        settings.LastSourceId = config.Id;
        settings.Save();

        AddStatus.Text = "正在连接…";
        var (ok, error) = await ReconnectAsync(null);

        if (ok)
        {
            var wasEditing = _editingId is not null;
            PassBox.Password = string.Empty;
            CloseAddPanel();
            StatusText.Text = wasEditing
                ? "已保存并连接：" + name
                : "已添加并连接：" + name;
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
        public string IconPath { get; init; } = "";
        public string Base { get; init; } = "";
        public string StatusText { get; init; } = "";
        public Brush? StatusBrush { get; init; }
    }
}