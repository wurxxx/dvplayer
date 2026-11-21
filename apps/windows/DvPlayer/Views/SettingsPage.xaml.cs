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

    public SettingsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
        AppServices.Instance.ConnectionChanged += OnConnectionChanged;

        LoadValues();
        RefreshSourceSummary();

        AppVersionText.Text = "0.1.0（" + typeof(SettingsPage).Assembly.GetName().Version + "）";
        CoreVersionText.Text = AppServices.Instance.CoreVersion ?? "未加载";
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
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

        _ready = true;
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

        settings.Save();
        StatusText.Text = "已保存";
    }

    private void OnManageSourcesClick(object sender, RoutedEventArgs e) =>
        (Window.GetWindow(this) as MainWindow)?.NavigateTo("sources");
}