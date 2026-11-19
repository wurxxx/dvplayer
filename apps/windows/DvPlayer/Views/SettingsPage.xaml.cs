using System.Windows;
using System.Windows.Controls;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class SettingsPage : Page
{
    public SettingsPage()
    {
        InitializeComponent();
        Loaded += (_, _) => RefreshSources();
    }

    private void RefreshSources()
    {
        SourceList.ItemsSource = AppServices.Instance.Settings.Sources
            .Select(s => new SourceRow(
                $"{s.Name} · {s.Base}",
                s.Id == AppServices.Instance.Settings.LastSourceId ? "当前" : ""))
            .ToList();
    }

    private async void OnAddClick(object sender, RoutedEventArgs e)
    {
        var name = string.IsNullOrWhiteSpace(NameBox.Text) ? "飞牛影视" : NameBox.Text.Trim();
        var baseUri = BaseBox.Text.Trim();
        var user = UserBox.Text.Trim();
        var pass = PassBox.Password;

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
            "fnos-" + Guid.NewGuid().ToString("N")[..8],
            name,
            "fnos",
            baseUri,
            user,
            pass);

        StatusText.Text = "正在连接…";

        var settings = AppServices.Instance.Settings;
        settings.Sources.RemoveAll(s => s.Base == baseUri && s.Username == user);
        settings.Sources.Add(config);
        settings.LastSourceId = config.Id;
        settings.Save();
        RefreshSources();

        var (ok, error) = await AppServices.Instance.ConnectAsync(config).ConfigureAwait(true);

        if (ok)
        {
            StatusText.Text = $"已连接：{name}";
            PassBox.Password = string.Empty;
            if (Window.GetWindow(this) is MainWindow main)
            {
                main.RefreshSourceStatus();
            }
        }
        else
        {
            StatusText.Text = "连接失败：" + (error ?? "未知错误");
        }
    }

    private sealed record SourceRow(string Title, string Badge);
}
