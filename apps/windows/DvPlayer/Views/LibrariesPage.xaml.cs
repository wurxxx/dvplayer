using System.Windows;
using System.Windows.Controls;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class LibrariesPage : Page
{
    private const int PageSize = 60;

    private string? _libraryId;
    private int _page;

    public LibrariesPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        var services = AppServices.Instance;
        if (!services.IsConnected)
        {
            StatusText.Text = "未连接媒体源，先去「设置」添加。";
            return;
        }

        var core = services.Core!;
        var result = await Task.Run(core.Libraries).ConfigureAwait(true);

        if (!result.Ok)
        {
            StatusText.Text = "读取媒体库失败：" + (result.Error ?? "未知错误");
            return;
        }

        var libraries = result.Data ?? new List<MediaLibraryDto>();
        LibraryBar.ItemsSource = libraries;

        if (libraries.Count > 0)
        {
            await LoadLibraryAsync(libraries[0].Id).ConfigureAwait(true);
        }
        else
        {
            StatusText.Text = "这个源里没有媒体库。";
        }
    }

    private async void OnLibraryClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string id })
        {
            await LoadLibraryAsync(id).ConfigureAwait(true);
        }
    }

    private async Task LoadLibraryAsync(string libraryId)
    {
        var services = AppServices.Instance;
        if (!services.IsConnected)
        {
            return;
        }

        _libraryId = libraryId;
        _page = 1;
        StatusText.Text = "正在加载…";

        var core = services.Core!;
        var result = await Task.Run(() => core.Items(libraryId, 1, PageSize)).ConfigureAwait(true);

        if (!result.Ok || result.Data is null)
        {
            StatusText.Text = "加载失败：" + (result.Error ?? "未知错误");
            return;
        }

        ItemGrid.ItemsSource = result.Data.Items.Select(ToCard).ToList();
        StatusText.Text = $"共 {result.Data.Total} 条";
        MoreButton.Visibility = result.Data.Items.Count < result.Data.Total
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private async void OnMoreClick(object sender, RoutedEventArgs e)
    {
        if (_libraryId is null || !AppServices.Instance.IsConnected)
        {
            return;
        }

        _page++;
        var core = AppServices.Instance.Core!;
        var page = _page;
        var result = await Task.Run(() => core.Items(_libraryId, page, PageSize)).ConfigureAwait(true);

        if (!result.Ok || result.Data is null)
        {
            _page--;
            return;
        }

        var existing = (ItemGrid.ItemsSource as List<ItemCard>) ?? new List<ItemCard>();
        existing.AddRange(result.Data.Items.Select(ToCard));
        ItemGrid.ItemsSource = existing;

        MoreButton.Visibility = existing.Count < result.Data.Total
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private static ItemCard ToCard(MediaItemDto item)
    {
        var subtitle = item.Kind;
        if (!string.IsNullOrEmpty(item.Resolution))
        {
            subtitle += " · " + item.Resolution;
        }

        if (item.RuntimeSeconds is > 0)
        {
            subtitle += " · " + TimeSpan.FromSeconds(item.RuntimeSeconds.Value).ToString(@"hh\:mm");
        }

        return new ItemCard(item.Title, subtitle);
    }

    private sealed record ItemCard(string Title, string Subtitle);
}
