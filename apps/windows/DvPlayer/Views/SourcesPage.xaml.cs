using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DvPlayer.Dialogs;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 媒体源管理页。源是一张张卡片：顶栏一个刷新、一个添加，
/// 添加表单按需展开，不常驻占地方。
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
            "emby" => "Emby 用账号密码登录；也可以只填 API Key（用户名留空，密码框填 Key）。",
            "jellyfin" => "Jellyfin 用账号密码登录；也可以只填 API Key（用户名留空，密码框填 Key）。",
            _ => "飞牛影视用账号密码登录。",
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

    /// <summary>拖动排序：按下卡片、移动超过阈值、松手时换位置。</summary>
    private Point _sourceDragStart;
    private SourceCard? _sourceDragCard;
    private bool _sourceDragging;
    private FrameworkElement? _dragSourceCardVisual;
    private FrameworkElement? _dragHoverCardVisual;
    private Point _dragGhostOffset;
    /// <summary>
    /// 拖动开始时各卡片槽位（按位置记录，不随重排动画变化）。
    /// 落点按槽位算，卡片滑动时命中的旧位置不会造成来回跳。
    /// </summary>
    private List<Rect>? _cardSlots;

    private void OnSourceGridPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        _sourceDragStart = e.GetPosition(SourceGrid);
        _sourceDragCard = (e.OriginalSource as FrameworkElement)?.DataContext as SourceCard;
        _sourceDragging = false;
    }

    private void OnSourceGridPreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _sourceDragCard is null)
        {
            return;
        }

        var position = e.GetPosition(SourceGrid);
        if (!_sourceDragging &&
            Math.Abs(position.X - _sourceDragStart.X) < 8 &&
            Math.Abs(position.Y - _sourceDragStart.Y) < 8)
        {
            return;
        }

        if (!_sourceDragging)
        {
            _sourceDragging = true;
            Cursor = Cursors.SizeAll;
            // 卡片本身是 Hand 光标，拖动时用 ForceCursor 让整个网格压过子元素的设置。
            SourceGrid.Cursor = Cursors.SizeAll;
            SourceGrid.ForceCursor = true;

            // 捕获鼠标：拖到卡片网格外松手也要收到 MouseUp，
            // 否则 ghost、半透明卡片和 SizeAll 光标都会留在界面上。
            SourceGrid.CaptureMouse();
            _cardSlots = CaptureCardSlots();
            _dragSourceCardVisual = CardContainer(_sourceDragCard.Id);
            if (_dragSourceCardVisual is not null)
            {
                _dragSourceCardVisual.Opacity = 0.35;
                _dragGhostOffset = e.GetPosition(_dragSourceCardVisual);
                ShowDragGhost(_dragSourceCardVisual);
            }
        }

        // 快照跟着鼠标走。
        var layerPoint = e.GetPosition(DragLayer);
        Canvas.SetLeft(DragGhost, layerPoint.X - _dragGhostOffset.X);
        Canvas.SetTop(DragGhost, layerPoint.Y - _dragGhostOffset.Y);

        // 经过别的源就实时让位：按最近槽位判断，鼠标停在某一格时
        // 换过去后那一格正好是拖着的这张卡，不会再来回换。
        if (_cardSlots is { Count: > 0 } slots)
        {
            var nearest = 0;
            var best = double.MaxValue;
            for (var i = 0; i < slots.Count; i++)
            {
                var bounds = slots[i];
                var dx = position.X - (bounds.Left + bounds.Width / 2);
                var dy = position.Y - (bounds.Top + bounds.Height / 2);
                var distance = dx * dx + dy * dy;
                if (distance < best)
                {
                    best = distance;
                    nearest = i;
                }
            }

            if (nearest >= 0 && nearest < SourceGrid.Items.Count &&
                SourceGrid.Items[nearest] is SourceCard target &&
                target.Id != _sourceDragCard.Id)
            {
                MoveSource(_sourceDragCard.Id, target.Id);
            }
        }
    }

    /// <summary>把卡片截成一张图，作为拖动时跟随鼠标的「快照」。</summary>
    private void ShowDragGhost(FrameworkElement source)
    {
        var width = source.ActualWidth;
        var height = source.ActualHeight;
        if (width < 1 || height < 1)
        {
            return;
        }

        var dpi = VisualTreeHelper.GetDpi(source);
        var bitmap = new RenderTargetBitmap(
            (int)Math.Ceiling(width * dpi.DpiScaleX),
            (int)Math.Ceiling(height * dpi.DpiScaleY),
            96 * dpi.DpiScaleX,
            96 * dpi.DpiScaleY,
            PixelFormats.Pbgra32);
        bitmap.Render(source);

        DragGhost.Width = width;
        DragGhost.Height = height;
        DragGhost.Background = new ImageBrush(bitmap) { Stretch = Stretch.Fill };
        DragGhost.Visibility = Visibility.Visible;
    }

    private void HideDragGhost()
    {
        DragGhost.Visibility = Visibility.Collapsed;
        DragGhost.Background = null;
    }

    private static void RestoreCardVisual(FrameworkElement? element)
    {
        if (element is null)
        {
            return;
        }

        element.Opacity = 1;
        element.RenderTransform = Transform.Identity;
    }

    private FrameworkElement? CardContainer(string id)
    {
        for (var i = 0; i < SourceGrid.Items.Count; i++)
        {
            if (SourceGrid.ItemContainerGenerator.ContainerFromIndex(i) is FrameworkElement element &&
                element.DataContext is SourceCard card && card.Id == id)
            {
                return element;
            }
        }

        return null;
    }

    /// <summary>记录每张卡片重排前的位置，用来做位移动画。</summary>
    private Dictionary<string, Point> CaptureCardPositions()
    {
        var map = new Dictionary<string, Point>();
        for (var i = 0; i < SourceGrid.Items.Count; i++)
        {
            if (SourceGrid.ItemContainerGenerator.ContainerFromIndex(i) is FrameworkElement element &&
                element.DataContext is SourceCard card)
            {
                map[card.Id] = element.TranslatePoint(new Point(0, 0), SourceGrid);
            }
        }

        return map;
    }

    /// <summary>重排后从旧位置滑到新位置，而不是瞬间跳过去。</summary>
    private void AnimateReorder(Dictionary<string, Point> before)
    {
        SourceGrid.UpdateLayout();
        for (var i = 0; i < SourceGrid.Items.Count; i++)
        {
            if (SourceGrid.ItemContainerGenerator.ContainerFromIndex(i) is not FrameworkElement element ||
                element.DataContext is not SourceCard card ||
                !before.TryGetValue(card.Id, out var old))
            {
                continue;
            }

            var now = element.TranslatePoint(new Point(0, 0), SourceGrid);
            var dx = old.X - now.X;
            var dy = old.Y - now.Y;
            if (Math.Abs(dx) < 0.5 && Math.Abs(dy) < 0.5)
            {
                continue;
            }

            var transform = new TranslateTransform(dx, dy);
            element.RenderTransform = transform;
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            var duration = TimeSpan.FromMilliseconds(240);
            transform.BeginAnimation(TranslateTransform.XProperty,
                new DoubleAnimation(0, duration) { EasingFunction = ease });
            transform.BeginAnimation(TranslateTransform.YProperty,
                new DoubleAnimation(0, duration) { EasingFunction = ease });
        }
    }

    private void OnSourceGridPreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        var dragging = _sourceDragging;
        var source = _sourceDragCard;
        _sourceDragging = false;
        _sourceDragCard = null;
        _cardSlots = null;
        SourceGrid.ForceCursor = false;
        SourceGrid.Cursor = null;
        Cursor = Cursors.Arrow;

        if (SourceGrid.IsMouseCaptured)
        {
            SourceGrid.ReleaseMouseCapture();
        }

        RestoreCardVisual(_dragSourceCardVisual);
        RestoreCardVisual(_dragHoverCardVisual);
        _dragSourceCardVisual = null;
        _dragHoverCardVisual = null;
        HideDragGhost();

        // 没拖动就是单击：整张卡片都能进这个源的媒体首页（编辑 / 删除按钮除外）。
        if (!dragging)
        {
            if (source is not null && !IsInsideButton(e.OriginalSource as DependencyObject))
            {
                (Window.GetWindow(this) as MainWindow)?.OpenSourceById(source.Id);
                e.Handled = true;
            }
            return;
        }

        if (source is null)
        {
            return;
        }

        var target = NearestCardAt(e.GetPosition(SourceGrid));
        if (target is null || target.Id == source.Id)
        {
            return;
        }

        MoveSource(source.Id, target.Id);
        e.Handled = true;
    }

    /// <summary>点击落在这张卡片自己的编辑 / 删除按钮上时，交给按钮处理。</summary>
    private static bool IsInsideButton(DependencyObject? node)
    {
        for (; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (node is System.Windows.Controls.Primitives.ButtonBase)
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>捕获被系统抢走（Alt+Tab、弹窗）时按取消处理，别留下 ghost。</summary>
    private void OnSourceGridLostCapture(object sender, MouseEventArgs e)
    {
        if (!_sourceDragging)
        {
            return;
        }

        _sourceDragging = false;
        _sourceDragCard = null;
        _cardSlots = null;
        SourceGrid.ForceCursor = false;
        SourceGrid.Cursor = null;
        Cursor = Cursors.Arrow;
        RestoreCardVisual(_dragSourceCardVisual);
        RestoreCardVisual(_dragHoverCardVisual);
        _dragSourceCardVisual = null;
        _dragHoverCardVisual = null;
        HideDragGhost();
    }

    /// <summary>记录拖动开始时每张卡片的位置，作为固定的落点槽位。</summary>
    private List<Rect> CaptureCardSlots()
    {
        var slots = new List<Rect>();
        for (var i = 0; i < SourceGrid.Items.Count; i++)
        {
            if (SourceGrid.ItemContainerGenerator.ContainerFromIndex(i) is not FrameworkElement element)
            {
                continue;
            }

            var topLeft = element.TranslatePoint(new Point(0, 0), SourceGrid);
            slots.Add(new Rect(topLeft, new Size(element.ActualWidth, element.ActualHeight)));
        }

        return slots;
    }

    /// <summary>离这个点最近的槽位现在是哪张卡。</summary>
    private SourceCard? NearestCardAt(Point point)
    {
        if (_cardSlots is not { Count: > 0 } slots)
        {
            return null;
        }

        var nearest = -1;
        var best = double.MaxValue;
        for (var i = 0; i < slots.Count; i++)
        {
            var bounds = slots[i];
            var dx = point.X - (bounds.Left + bounds.Width / 2);
            var dy = point.Y - (bounds.Top + bounds.Height / 2);
            var distance = dx * dx + dy * dy;
            if (distance < best)
            {
                best = distance;
                nearest = i;
            }
        }

        return nearest >= 0 && nearest < SourceGrid.Items.Count
            ? SourceGrid.Items[nearest] as SourceCard
            : null;
    }

    /// <summary>
    /// 自检：指针停在第三张卡片不动，换过去后应该认出「就是自己」，不会来回跳。
    /// </summary>
    public void RunDragStabilityTest()
    {
        SourceGrid.UpdateLayout();
        if (SourceGrid.Items.Count < 3 || SourceGrid.Items[0] is not SourceCard drag)
        {
            Services.Trace.Write("drag test card skipped");
            return;
        }

        var before = string.Join(" | ", AppServices.Instance.Settings.Sources.Select(x => x.Name));
        _cardSlots = CaptureCardSlots();
        if (_cardSlots.Count < 3)
        {
            Services.Trace.Write("drag test card no slots");
            _cardSlots = null;
            return;
        }

        var bounds = _cardSlots[2];
        var point = new Point(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2);
        var first = NearestCardAt(point);
        if (first is not null)
        {
            MoveSource(drag.Id, first.Id);
        }

        SourceGrid.UpdateLayout();
        var second = NearestCardAt(point);
        var after = string.Join(" | ", AppServices.Instance.Settings.Sources.Select(x => x.Name));
        Services.Trace.Write($"drag test card before={before} first={first?.Id} " +
                             $"second={second?.Id} drag={drag.Id} order={after} " +
                             $"stable={second?.Id == drag.Id}");
        _cardSlots = null;
    }

    /// <summary>把 id 挪到 targetId 的位置，顺序写回设置并刷新两侧列表。</summary>
    private void MoveSource(string id, string targetId)
    {
        var sources = AppServices.Instance.Settings.Sources;
        var from = sources.FindIndex(s => s.Id == id);
        var to = sources.FindIndex(s => s.Id == targetId);
        if (from < 0 || to < 0 || from == to)
        {
            return;
        }

        var before = CaptureCardPositions();
        var item = sources[from];
        sources.RemoveAt(from);
        sources.Insert(to, item);
        AppServices.Instance.Settings.Save();
        Services.Trace.Write("source order " + string.Join(" | ", sources.Select(x => x.Name)));

        RefreshSources();
        (Window.GetWindow(this) as MainWindow)?.RefreshSourceStatus();
        Dispatcher.BeginInvoke(() =>
        {
            AnimateReorder(before);

            // 刷新会重建卡片容器，拖动中的那张要重新压暗。
            if (_sourceDragging && _sourceDragCard is { } dragged)
            {
                _dragSourceCardVisual = CardContainer(dragged.Id);
                if (_dragSourceCardVisual is not null)
                {
                    _dragSourceCardVisual.Opacity = 0.35;
                }
            }
        }, DispatcherPriority.Loaded);
    }

    /// <summary>左侧列表拖动排序后，这里跟着换顺序。</summary>
    public void ReloadOrder() => RefreshSources();

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

                // 连接结果四分：没试过 / 正在连 / 连上 / 失败。
                var (status, brush) = connection is null
                    ? ("尚未连接", "FaintBrush")
                    : connection.Connecting
                        ? ("正在连接…", "FaintBrush")
                        : connection.Ok
                            ? (ConnectedStatus(connection), "SuccessBrush")
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

    /// <summary>「已连接 · 09:00 · 延迟 12 ms」。没有时刻 / 延迟就只显示有的那部分。</summary>
    private static string ConnectedStatus(SourceConnection connection)
    {
        var parts = new List<string> { "已连接" };
        if (connection.ConnectedAt is { } at)
        {
            parts.Add(at.ToString("HH:mm"));
        }

        if (connection.LatencyMs is { } latency)
        {
            parts.Add(latency < 1 ? "延迟 <1 ms" : $"延迟 {latency} ms");
        }

        return string.Join(" · ", parts);
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
        if (_editingId == id)
        {
            // 编辑的就是这条：不收表单的话，之后点保存会用同一个 id 把它写回来。
            CloseAddPanel();
        }

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
                // 和服务器分支一样锁成「编辑这一条」：路径写错了再点保存是改它，
                // 不会又生成一条新的僵尸源。
                _editingId = localConfig.Id;
                AddTitle.Text = "编辑服务器";
                AddSubmitButton.Content = "保存并连接";
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
        // 被顶掉的可能是挂载过的源：不 Release 会留下盘符/会话。
        var deduped = settings.Sources
            .Where(s => s.Id != config.Id && s.Base == baseUri && s.Username == user)
            .ToList();
        foreach (var old in deduped)
        {
            NetMount.Release(old.Id);
            settings.Sources.Remove(old);
        }

        settings.Sources.RemoveAll(s => s.Id == config.Id);
        settings.Sources.Add(config);
        settings.LastSourceId = config.Id;
        settings.Save();

        AddStatus.Text = "正在连接…";
        var (ok, error) = await ReconnectAsync(null);

        // 「有一个源连上」不代表刚加的这一个连上了：按这个源自己的状态提示。
        var connection = AppServices.Instance.Connections.FirstOrDefault(c => c.Id == config.Id);
        if (ok && (connection?.Ok ?? false))
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
            // 源已经落盘（可能只是暂时离线）。把它锁成「正在编辑这一条」：
            // 用户改完直接点保存就是编辑，不会又生成一条僵尸源。
            _editingId = config.Id;
            AddTitle.Text = "编辑服务器";
            AddSubmitButton.Content = "保存并连接";
            var why = connection?.Error ?? error ?? "未知错误";
            AddStatus.Text = "已保存，但连接失败：" + why + "。改好后可直接重试。";
            (Window.GetWindow(this) as MainWindow)?.RefreshSourceStatus();
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