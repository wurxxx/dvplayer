using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 演职人员的作品页：点详情页里的头像进来，列出这个人参演的影片 / 剧集。
/// </summary>
public partial class PersonPage : Page
{
    private readonly string _personId;

    public PersonPage(string personId, string name)
    {
        _personId = personId;
        InitializeComponent();

        TitleText.Text = name;
        Loaded += OnLoaded;
        KeyDown += OnKeyDown;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (AppServices.Instance.Core is not { } core)
        {
            StatusText.Text = "未连接媒体源。";
            return;
        }

        StatusText.Text = "正在读取…";

        var result = await Task.Run(() => core.PersonWorks(_personId)).ConfigureAwait(true);
        if (!result.Ok)
        {
            StatusText.Text = "读取失败：" + (result.Error ?? "未知错误");
            return;
        }

        var works = result.Data ?? new List<MediaItemDto>();
        var cards = works.Select(item => new WorkCard
        {
            Id = item.Id,
            Title = item.Title,
            Sub = item.Year is > 0 ? item.Year.Value.ToString() : item.Kind == "series" ? "剧集" : "电影",
            PosterPath = item.PosterPath,
            Initial = Palette.InitialOf(item.Title),
        }).ToList();

        foreach (var card in cards)
        {
            card.UseGradient(card.Id + card.Title);
        }

        WorkGrid.ItemsSource = cards;
        StatusText.Text = cards.Count == 0 ? "没有找到这个人的作品。" : $"{cards.Count} 个作品";

        await Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    private void OnWorkClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        NavigationService?.Navigate(new SeriesPage(id));
    }

    private void OnBackClick(object sender, RoutedEventArgs e)
    {
        if (NavigationService?.CanGoBack == true)
        {
            NavigationService.GoBack();
        }
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            OnBackClick(sender, e);
            e.Handled = true;
        }
    }

    private sealed class WorkCard : CardVisual
    {
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
    }
}
