using System.Windows;
using System.Windows.Controls;
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

        SelectTag(StartPageBox, settings.StartPage);
        SelectContent(PageSizeBox, settings.PageSize.ToString());
        SelectTag(BufferSizeBox, settings.BufferSizeMb.ToString());
        SelectTag(HdrPeakBox, settings.HdrPeakNits.ToString());

        DanmakuSwitch.IsChecked = settings.DanmakuEnabled ?? false;
        SubtitleKeyBox.Password = settings.OpenSubtitlesApiKey ?? "";
        SubtitleUserBox.Text = settings.OpenSubtitlesUsername ?? "";
        SubtitlePassBox.Password = settings.OpenSubtitlesPassword ?? "";
        SubtitleLangBox.Text = settings.SubtitleLanguages ?? "";
        SubtitleLangBox.ToolTip = "默认 zh-cn,zh-tw,en";

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
        AboutPanel.Visibility = Visible(AboutSegment);

        static Visibility Visible(RadioButton button) =>
            button.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
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
        settings.DanmakuEnabled = DanmakuSwitch.IsChecked == true;
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
        settings.OpenSubtitlesApiKey = NullIfEmpty(SubtitleKeyBox.Password);
        settings.OpenSubtitlesUsername = NullIfEmpty(SubtitleUserBox.Text);
        settings.OpenSubtitlesPassword = NullIfEmpty(SubtitlePassBox.Password);
        settings.SubtitleLanguages = NullIfEmpty(SubtitleLangBox.Text);
        settings.Save();

        RefreshExtrasHints();
        StatusText.Text = "已保存";
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

    private static string? NullIfEmpty(string text)
    {
        var value = text.Trim();
        return value.Length == 0 ? null : value;
    }

    private void OnManageSourcesClick(object sender, RoutedEventArgs e) =>
        (Window.GetWindow(this) as MainWindow)?.NavigateTo("sources");
}