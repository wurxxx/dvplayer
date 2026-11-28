using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using DvPlayer.Player;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 设置页。顶栏下面是分段（通用 / 列表 / 播放 / 关于），
/// 每一项是分组卡片里的一行「标题 + 说明 + 右侧控件」。
/// 媒体源不再混在这里，单独的「媒体源」页管。
/// </summary>
public partial class SettingsPage : Page
{
    private bool _ready;
    private bool _updateAutoChecked;
    private bool _checkingUpdate;
    private UpdateCheckResult? _updateResult;
    private CancellationTokenSource? _traktLogin;

    /// <summary>自定义取色：滑块在程序里赋初值时别当成用户改动。</summary>
    private bool _accentReady;

    /// <summary>取色面板里正在预览的颜色。</summary>
    private Color _accentDraft;

    /// <summary>这次打开面板有没有拖过滑块：没拖过就关掉，不该悄悄改成自定义色。</summary>
    private bool _accentCustomTouched;

    /// <summary>取色面板的宽度，和 XAML 里 Border 的 Width 一致（右对齐时要用）。</summary>
    private const double AccentPopupWidth = 238;
    private readonly System.Windows.Threading.DispatcherTimer _saveTimer = new()
    {
        Interval = TimeSpan.FromMilliseconds(500),
    };

    public SettingsPage()
    {
        InitializeComponent();
        _saveTimer.Tick += (_, _) =>
        {
            _saveTimer.Stop();
            SaveExtras();
        };
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
        AppServices.Instance.ConnectionChanged += OnConnectionChanged;

        LoadValues();
        RefreshSourceSummary();
        RefreshTraktState();

        AppVersionText.Text = AppServices.AppVersion;
        CoreVersionText.Text = AppServices.Instance.CoreVersion ?? "未加载";
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;

        // 还有没来得及写盘的输入：离开页面前补一次。
        if (_saveTimer.IsEnabled)
        {
            _saveTimer.Stop();
            SaveExtras();
        }
    }

    private void OnConnectionChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(RefreshSourceSummary);

    private void LoadValues()
    {
        var settings = AppServices.Instance.Settings;

        _ready = false;

        AutoConnectSwitch.IsChecked = settings.AutoConnect;
        ResolutionSwitch.IsChecked = settings.ShowResolution;
        ResumeSwitch.IsChecked = settings.ResumePlayback;
        PrefetchSwitch.IsChecked = settings.PrefetchNextEpisode;

        switch ((settings.Appearance ?? "system").ToLowerInvariant())
        {
            case "light":
                AppearanceLight.IsChecked = true;
                break;
            case "dark":
                AppearanceDark.IsChecked = true;
                break;
            default:
                AppearanceSystem.IsChecked = true;
                break;
        }

        SelectTag(StartPageBox, settings.StartPage);
        SelectContent(PageSizeBox, settings.PageSize.ToString());
        SelectTag(BufferSizeBox, settings.BufferSizeMb.ToString());
        SelectTag(HdrPeakBox, settings.HdrPeakNits.ToString());

        DanmakuSwitch.IsChecked = settings.DanmakuEnabled ?? false;
        TraktEnabledSwitch.IsChecked = settings.TraktEnabled ?? true;
        TraktIdBox.Text = settings.TraktClientId ?? "";
        TraktSecretBox.Password = settings.TraktClientSecret ?? "";
        SubtitleKeyBox.Password = settings.OpenSubtitlesApiKey ?? "";
        SubtitleUserBox.Text = settings.OpenSubtitlesUsername ?? "";
        SubtitlePassBox.Password = settings.OpenSubtitlesPassword ?? "";
        SubtitleLangBox.Text = settings.SubtitleLanguages ?? "";
        TmdbKeyBox.Password = settings.TmdbApiKey ?? "";
        TmdbProxyBox.Text = settings.TmdbProxy ?? "";
        MoviePilotUrlBox.Text = settings.MoviePilotUrl ?? "";
        MoviePilotTokenBox.Password = settings.MoviePilotToken ?? "";
        SubtitleLangBox.ToolTip = "默认 zh-cn,zh-tw,en";

        BuildAccentRow();

        _ready = true;
        RefreshExtrasHints();
    }

    private static void SelectTag(ComboBox box, string tag)
    {
        foreach (var item in box.Items.OfType<ComboBoxItem>())
        {
            if ((item.Tag as string) == tag)
            {
                box.SelectedItem = item;
                return;
            }
        }

        box.SelectedIndex = 0;
    }

    private static void SelectContent(ComboBox box, string content)
    {
        foreach (var item in box.Items.OfType<ComboBoxItem>())
        {
            if ((item.Content as string) == content)
            {
                box.SelectedItem = item;
                return;
            }
        }

        box.SelectedIndex = 1;
    }

    private void RefreshSourceSummary()
    {
        var services = AppServices.Instance;
        var total = services.Settings.Sources.Count;
        var ok = services.Connections.Count(c => c.Ok);

        SourceSummaryText.Text = total == 0
            ? "还没有配置媒体源"
            : ok == total
                ? $"{total} 个源，全部已连接"
                : $"{total} 个源，{ok} 个已连接";
    }

    /// <summary>自检用：不用点分段按钮，直接切到某个设置分组。</summary>
    public void ShowTabForShot(string key)
    {
        switch (key)
        {
            case "list":
                ListSegment.IsChecked = true;
                break;
            case "play":
                PlaySegment.IsChecked = true;
                break;
            case "extras":
                ExtrasSegment.IsChecked = true;
                break;
            case "trakt":
                TraktSegment.IsChecked = true;
                break;
            case "about":
                AboutSegment.IsChecked = true;
                break;
            default:
                GeneralSegment.IsChecked = true;
                break;
        }
    }

    private void OnTabChanged(object sender, RoutedEventArgs e)
    {
        if (GeneralPanel is null)
        {
            return;
        }

        GeneralPanel.Visibility = Visible(GeneralSegment);
        ListPanel.Visibility = Visible(ListSegment);
        PlayPanel.Visibility = Visible(PlaySegment);
        ExtrasPanel.Visibility = Visible(ExtrasSegment);
        TraktPanel.Visibility = Visible(TraktSegment);
        AboutPanel.Visibility = Visible(AboutSegment);

        // 第一次打开「关于」自动查一次；服务层有 10 分钟缓存，切分段不会反复打接口。
        if (AboutSegment.IsChecked == true && !_updateAutoChecked)
        {
            _updateAutoChecked = true;
            _ = CheckUpdatesAsync(force: false);
        }

        static Visibility Visible(RadioButton button) =>
            button.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    // —— 关于：项目地址 / 更新检查 ——

    private void OnProjectLinkClick(object sender, System.Windows.Input.MouseButtonEventArgs e) =>
        OpenUrl(UpdateService.RepoUrl);

    private async void OnCheckUpdateClick(object sender, RoutedEventArgs e)
    {
        // 已经发现新版本：这个按钮变成「下载更新」，点了直接开浏览器的发布页。
        if (_updateResult is { Status: UpdateCheckStatus.Available, Url: { Length: > 0 } url })
        {
            OpenUrl(url);
            return;
        }

        await CheckUpdatesAsync(force: true);
    }

    private async Task CheckUpdatesAsync(bool force)
    {
        if (_checkingUpdate)
        {
            return;
        }

        _checkingUpdate = true;
        RenderUpdateState();

        try
        {
            _updateResult = await UpdateService.CheckAsync(AppServices.AppVersion, force)
                .ConfigureAwait(true);
        }
        finally
        {
            _checkingUpdate = false;
            RenderUpdateState();
        }
    }

    private void RenderUpdateState()
    {
        UpdateButton.IsEnabled = !_checkingUpdate;

        if (_checkingUpdate)
        {
            UpdateButton.Content = "检查中…";
            UpdateStatusText.Text = "正在检查…";
            UpdateStatusText.SetResourceReference(TextBlock.ForegroundProperty, "MutedBrush");
            return;
        }

        switch (_updateResult?.Status)
        {
            case UpdateCheckStatus.Available:
                UpdateButton.Content = "下载更新";
                UpdateStatusText.Text = _updateResult.Message;
                UpdateStatusText.SetResourceReference(TextBlock.ForegroundProperty, "AccentInkBrush");
                break;
            case UpdateCheckStatus.UpToDate:
                UpdateButton.Content = "重新检查";
                UpdateStatusText.Text = _updateResult.Message;
                UpdateStatusText.SetResourceReference(TextBlock.ForegroundProperty, "SuccessBrush");
                break;
            case UpdateCheckStatus.NoRelease:
                UpdateButton.Content = "重新检查";
                UpdateStatusText.Text = _updateResult.Message;
                UpdateStatusText.SetResourceReference(TextBlock.ForegroundProperty, "FaintBrush");
                break;
            case UpdateCheckStatus.Failed:
                UpdateButton.Content = "重新检查";
                UpdateStatusText.Text = _updateResult!.Message;
                UpdateStatusText.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
                break;
            default:
                UpdateButton.Content = "检查更新";
                UpdateStatusText.Text = "还没有检查过";
                UpdateStatusText.SetResourceReference(TextBlock.ForegroundProperty, "FaintBrush");
                break;
        }
    }

    /// <summary>外观分段：跟随系统 / 深色 / 浅色，当场生效并写回设置。</summary>
    private void OnAppearanceChanged(object sender, RoutedEventArgs e)
    {
        if (!_ready)
        {
            return;
        }

        var mode = AppearanceLight.IsChecked == true
            ? "light"
            : AppearanceDark.IsChecked == true
                ? "dark"
                : "system";

        var settings = AppServices.Instance.Settings;
        settings.Appearance = mode;
        settings.Save();
        ThemeService.Apply(mode);
        StatusText.Text = "已保存";
    }

    // —— 主题色 ——

    /// <summary>
    /// 预设色块：一行圆点，当前色打勾 + 外圈。写在代码里而不是 XAML，
    /// 是因为选中态要跟着 <see cref="ThemeService.Accent"/>（含 --accent 自检）走。
    /// </summary>
    private void BuildAccentRow()
    {
        AccentRow.Children.Clear();

        var stored = ThemeService.Accent;
        var selectedId = AccentTheme.Preset(stored)?.Id;
        var customColor = AccentTheme.Custom(stored);

        foreach (var preset in AccentTheme.Presets)
        {
            var selected = preset.Id == selectedId;
            var cell = new Grid { Width = 28, Height = 28 };

            cell.Children.Add(new Ellipse
            {
                Width = 20,
                Height = 20,
                Fill = new SolidColorBrush(preset.Fill),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });

            if (selected)
            {
                cell.Children.Add(new Ellipse
                {
                    Width = 24,
                    Height = 24,
                    Stroke = (Brush)FindResource("TextBrush"),
                    StrokeThickness = 1,
                    Opacity = 0.45,
                });
                cell.Children.Add(new TextBlock
                {
                    Text = "\uE73E",
                    FontFamily = (FontFamily)FindResource("IconFont"),
                    FontSize = 9.5,
                    Foreground = new SolidColorBrush(AccentTheme.OnFill(preset.Fill)),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }

            var button = new Button
            {
                Content = cell,
                Style = (Style)FindResource("SwatchButton"),
                Tag = preset.Id,
                ToolTip = preset.Title,
            };
            button.Click += OnAccentPresetClick;
            AccentRow.Children.Add(button);
        }

        // 自定义：当前就是自定义色时，按钮前面带一个小圆点显示它。
        if (customColor is { } custom)
        {
            var panel = new StackPanel { Orientation = Orientation.Horizontal };
            panel.Children.Add(new Ellipse
            {
                Width = 11,
                Height = 11,
                Fill = new SolidColorBrush(custom),
                Margin = new Thickness(0, 0, 5, 0),
                VerticalAlignment = VerticalAlignment.Center,
            });
            panel.Children.Add(new TextBlock
            {
                Text = "自定义",
                VerticalAlignment = VerticalAlignment.Center,
            });
            AccentCustomButton.Content = panel;
            AccentCustomButton.FontWeight = FontWeights.SemiBold;
            AccentCustomButton.SetResourceReference(Control.ForegroundProperty, "AccentInkBrush");
        }
        else
        {
            AccentCustomButton.Content = "自定义";
            AccentCustomButton.FontWeight = FontWeights.Normal;
            AccentCustomButton.SetResourceReference(Control.ForegroundProperty, "TextBrush");
        }
    }

    private void OnAccentPresetClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id })
        {
            return;
        }

        var settings = AppServices.Instance.Settings;
        settings.AccentColor = id;
        settings.Save();
        ThemeService.ApplyAccent(id);
        BuildAccentRow();
        StatusText.Text = "已保存";
    }

    /// <summary>自定义取色：从当前主色起步，拖动滑块即时生效。</summary>
    private void OnAccentCustomClick(object sender, RoutedEventArgs e)
    {
        var fill = AccentTheme.Custom(AppServices.Instance.Settings.AccentColor)
                   ?? ThemeService.AccentFill;

        _accentCustomTouched = false;
        _accentReady = false;
        AccentRed.Value = fill.R;
        AccentGreen.Value = fill.G;
        AccentBlue.Value = fill.B;
        _accentReady = true;

        UpdateAccentDraft(apply: false);

        // 右对齐到按钮：默认 Placement=Bottom 是左对齐，按钮本来就靠卡片右边，
        // 弹层再往右就出窗口了（窄屏 / 窗口贴边时右边一整列点不到）。
        AccentPopup.HorizontalOffset = AccentCustomButton.ActualWidth - AccentPopupWidth;
        AccentPopup.IsOpen = true;
    }

    private void OnAccentSliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!_accentReady)
        {
            return;
        }

        _accentCustomTouched = true;
        UpdateAccentDraft(apply: true);
    }

    private void UpdateAccentDraft(bool apply)
    {
        _accentDraft = Color.FromRgb(
            (byte)Math.Round(AccentRed.Value),
            (byte)Math.Round(AccentGreen.Value),
            (byte)Math.Round(AccentBlue.Value));

        AccentPreview.Background = new SolidColorBrush(_accentDraft);
        AccentHexText.Text = AccentTheme.HexText(_accentDraft);

        if (apply)
        {
            ThemeService.ApplyAccent(AccentTheme.CustomValue(_accentDraft));
        }
    }

    private void OnAccentDoneClick(object sender, RoutedEventArgs e) => AccentPopup.IsOpen = false;

    /// <summary>
    /// 取色面板收起时写回设置（点外面关掉也算选好了——面板里是即时预览，
    /// 没有「取消」这一说）。
    /// </summary>
    private void OnAccentPopupClosed(object? sender, EventArgs e)
    {
        if (!_accentReady)
        {
            return;
        }

        // 只打开看了一眼、没拖滑块：回到原来的设置（可能还是预设），
        // 别因为「点过自定义」就把预设悄悄改成一个同色的自定义色。
        if (!_accentCustomTouched)
        {
            ThemeService.ApplyAccent(AppServices.Instance.Settings.AccentColor);
            BuildAccentRow();
            return;
        }

        var value = AccentTheme.CustomValue(_accentDraft);
        var settings = AppServices.Instance.Settings;
        if (AccentTheme.Normalize(settings.AccentColor) != value)
        {
            settings.AccentColor = value;
            settings.Save();
            StatusText.Text = "已保存";
        }

        ThemeService.ApplyAccent(value);
        BuildAccentRow();
    }

    private void OnSettingChanged(object sender, RoutedEventArgs e)
    {
        if (!_ready)
        {
            return;
        }

        var settings = AppServices.Instance.Settings;
        settings.AutoConnect = AutoConnectSwitch.IsChecked == true;
        settings.ShowResolution = ResolutionSwitch.IsChecked == true;
        settings.ResumePlayback = ResumeSwitch.IsChecked == true;
        settings.PrefetchNextEpisode = PrefetchSwitch.IsChecked == true;
        settings.DanmakuEnabled = DanmakuSwitch.IsChecked == true;
        settings.TraktEnabled = TraktEnabledSwitch.IsChecked == true;
        settings.StartPage = (StartPageBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "libraries";

        if (PageSizeBox.SelectedItem is ComboBoxItem { Content: string size } && int.TryParse(size, out var pageSize))
        {
            settings.PageSize = pageSize;
        }

        if (BufferSizeBox.SelectedItem is ComboBoxItem { Tag: string buffer }
            && int.TryParse(buffer, out var bufferMb))
        {
            settings.BufferSizeMb = bufferMb;
        }

        if (HdrPeakBox.SelectedItem is ComboBoxItem { Tag: string hdrPeak }
            && int.TryParse(hdrPeak, out var hdrPeakNits))
        {
            settings.HdrPeakNits = hdrPeakNits;
        }

        settings.Save();
        StatusText.Text = "已保存";

        // 播放窗还开着的话，亮度参考立刻生效，不用等下一次播放。
        foreach (var window in Application.Current.Windows.OfType<PlayWindow>())
        {
            window.ApplyHdrPeakFromSettings();
        }
    }

    /// <summary>弹幕 / 字幕的文本框：边输入边写回 settings.json，不依赖配色或分段切换。</summary>
    private void OnSettingTextChanged(object sender, TextChangedEventArgs e) => ScheduleExtraSave();

    private void OnSettingPasswordChanged(object sender, RoutedEventArgs e) => ScheduleExtraSave();

    /// <summary>
    /// 输入时每个字符都写盘太频繁（而且写的是明文密码）：
    /// 停 500ms 再存一次，离开页面时补存。
    /// </summary>
    private void ScheduleExtraSave()
    {
        if (!_ready)
        {
            return;
        }

        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void SaveExtras()
    {
        if (!_ready)
        {
            return;
        }

        var settings = AppServices.Instance.Settings;
        var oldTmdbKey = settings.TmdbApiKey ?? "";
        settings.OpenSubtitlesApiKey = NullIfEmpty(SubtitleKeyBox.Password);
        settings.OpenSubtitlesUsername = NullIfEmpty(SubtitleUserBox.Text);
        settings.OpenSubtitlesPassword = NullIfEmpty(SubtitlePassBox.Password);
        settings.SubtitleLanguages = NullIfEmpty(SubtitleLangBox.Text);
        settings.TraktClientId = NullIfEmpty(TraktIdBox.Text);
        settings.TraktClientSecret = NullIfEmpty(TraktSecretBox.Password);
        settings.TmdbApiKey = NullIfEmpty(TmdbKeyBox.Password);
        settings.TmdbProxy = NullIfEmpty(TmdbProxyBox.Text);
        settings.MoviePilotUrl = NullIfEmpty(MoviePilotUrlBox.Text);
        settings.MoviePilotToken = NullIfEmpty(MoviePilotTokenBox.Password);
        settings.Save();

        // Key 填上 / 清空后重抓一次：当天缓存里可能只有豆瓣，
        // 不重抓的话回到推荐页会以为 Key 没生效。
        if (string.IsNullOrEmpty(oldTmdbKey) != string.IsNullOrEmpty(settings.TmdbApiKey))
        {
            _ = DailyService.RefreshAsync(force: true);
        }

        RefreshExtrasHints();
        RefreshTraktState();
        StatusText.Text = "已保存";
    }

    /// <summary>MoviePilot 连通性自检：只发一个只读请求，不会真的订阅。</summary>
    private async void OnTestPilotClick(object sender, RoutedEventArgs e)
    {
        PilotStatusText.SetResourceReference(TextBlock.ForegroundProperty, "FaintBrush");
        PilotStatusText.Text = "正在连接…";

        try
        {
            var message = await DailyService.CheckPilotAsync(
                MoviePilotUrlBox.Text, MoviePilotTokenBox.Password);
            PilotStatusText.SetResourceReference(TextBlock.ForegroundProperty, "SuccessBrush");
            PilotStatusText.Text = message;
        }
        catch (Exception ex)
        {
            PilotStatusText.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
            PilotStatusText.Text = ex.Message;
        }
    }

    private void RefreshExtrasHints()
    {
        if (DanmakuHint is null || SubtitleHint is null)
        {
            return;
        }

        var settings = AppServices.Instance.Settings;
        DanmakuHint.Text = DanmakuCredential.IsConfigured
            ? "已内置：播放页打开弹幕时会按「剧名 + 集号」自动匹配。"
            : "这个构建没有内置弹幕凭据（开发版）：打开弹幕不会联网。";

        var hasSubtitle = !string.IsNullOrWhiteSpace(settings.OpenSubtitlesApiKey);
        SubtitleHint.Text = hasSubtitle
            ? "已配置：播放页「更多 → 搜索字幕」会按当前剧集与语言去搜。"
            : "还没填 API Key：字幕搜索会提示缺什么，不会联网。";
    }

    // —— Trakt ——

    private void RefreshTraktState()
    {
        if (TraktStatusText is null)
        {
            return;
        }

        var client = TraktClient.Shared;
        var settings = AppServices.Instance.Settings;
        var loggedIn = client.IsLoggedIn;

        TraktCredentialPanel.Visibility = client.IsConfigured
            ? Visibility.Collapsed
            : Visibility.Visible;
        TraktConnectButton.IsEnabled = client.IsConfigured;
        TraktConnectButton.Visibility = loggedIn ? Visibility.Collapsed : Visibility.Visible;
        TraktLogoutButton.Visibility = loggedIn ? Visibility.Visible : Visibility.Collapsed;

        TraktStatusText.Text = loggedIn
            ? (string.IsNullOrWhiteSpace(settings.TraktUsername)
                ? "已连接"
                : $"已连接：{settings.TraktUsername}")
            : "未连接";

        TraktStatusHint.Text = loggedIn
            ? "播放时会按「剧名 + 集号」自动上报；电影按片名匹配。"
            : client.IsConfigured
                ? "点「连接 Trakt」，用设备码在网页上授权。"
                : "这个构建没有内置凭据：填了上面的 Client ID / Secret 才能连接。";

        TraktHint.Text = loggedIn
            ? "评分 / 收藏 / 待看也在详情页的「Trakt」按钮里。"
            : "";
    }

    private async void OnTraktConnectClick(object sender, RoutedEventArgs e)
    {
        var client = TraktClient.Shared;
        if (!client.IsConfigured)
        {
            RefreshTraktState();
            return;
        }

        _traktLogin?.Cancel();
        _traktLogin = new CancellationTokenSource();
        var token = _traktLogin.Token;

        try
        {
            var device = await client.StartDeviceLoginAsync(token);
            TraktDevicePanel.Visibility = Visibility.Visible;
            TraktDeviceCode.Text = device.UserCode;
            TraktStatusHint.Text = "等待在网页上确认…";
            TraktConnectButton.Visibility = Visibility.Collapsed;
            OpenUrl(device.VerificationUrl);

            var deadline = DateTime.UtcNow.AddSeconds(device.ExpiresIn);
            while (DateTime.UtcNow < deadline)
            {
                await Task.Delay(TimeSpan.FromSeconds(device.Interval), token);
                try
                {
                    await client.PollDeviceTokenAsync(device, token);
                    await client.FetchUsernameAsync(token);
                    TraktDevicePanel.Visibility = Visibility.Collapsed;
                    RefreshTraktState();
                    StatusText.Text = "已连接 Trakt";
                    return;
                }
                catch (TraktPendingException)
                {
                    // 还没确认，继续等。
                }
            }

            TraktDevicePanel.Visibility = Visibility.Collapsed;
            RefreshTraktState();
            TraktStatusHint.Text = "设备码过期了，重新连接一次";
        }
        catch (OperationCanceledException)
        {
            // 用户取消或离开页面。
        }
        catch (Exception ex)
        {
            TraktDevicePanel.Visibility = Visibility.Collapsed;
            RefreshTraktState();
            TraktStatusHint.Text = ex.Message;
        }
    }

    private async void OnTraktLogoutClick(object sender, RoutedEventArgs e)
    {
        _traktLogin?.Cancel();
        await TraktClient.Shared.LogoutAsync();
        TraktDevicePanel.Visibility = Visibility.Collapsed;
        RefreshTraktState();
        StatusText.Text = "已断开 Trakt";
    }

    private void OnTraktOpenActivateClick(object sender, RoutedEventArgs e) =>
        OpenUrl("https://trakt.tv/activate");

    private void OnTraktCancelClick(object sender, RoutedEventArgs e)
    {
        _traktLogin?.Cancel();
        TraktDevicePanel.Visibility = Visibility.Collapsed;
        RefreshTraktState();
    }

    private static void OpenUrl(string url)
    {
        try
        {
            System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception)
        {
            // 打不开浏览器不影响流程：码还在界面上。
        }
    }

    private static string? NullIfEmpty(string text)
    {
        var value = text.Trim();
        return value.Length == 0 ? null : value;
    }

    private void OnManageSourcesClick(object sender, RoutedEventArgs e) =>
        (Window.GetWindow(this) as MainWindow)?.NavigateTo("sources");
}