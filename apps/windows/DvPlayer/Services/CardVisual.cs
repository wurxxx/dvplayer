using System.ComponentModel;
using System.Windows;
using System.Windows.Media;

namespace DvPlayer.Services;

/// <summary>
/// 卡片/缩略图的底图：先用渐变占位，海报下载完成后换成真图。
/// 用 ImageBrush 当 Border 的背景，圆角裁剪才正常。
/// </summary>
public abstract class CardVisual : INotifyPropertyChanged
{
    private Brush _background = Brushes.DimGray;
    private Visibility _placeholderVisibility = Visibility.Visible;

    public event PropertyChangedEventHandler? PropertyChanged;

    public Brush Background
    {
        get => _background;
        protected set
        {
            _background = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Background)));
        }
    }

    /// <summary>没有海报时显示首字占位。</summary>
    public Visibility PlaceholderVisibility
    {
        get => _placeholderVisibility;
        protected set
        {
            _placeholderVisibility = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(PlaceholderVisibility)));
        }
    }

    public void UseGradient(string key) => Background = Palette.GradientFor(key);

    /// <summary>派生类改了绑定属性后叫一声。</summary>
    protected void Raise(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public async Task ApplyPosterAsync(string? posterPath)
    {
        if (string.IsNullOrWhiteSpace(posterPath))
        {
            return;
        }

        var bitmap = await PosterLoader.LoadAsync(posterPath).ConfigureAwait(true);
        if (bitmap is null)
        {
            return;
        }

        var brush = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
        brush.Freeze();
        Background = brush;
        PlaceholderVisibility = Visibility.Collapsed;
    }
}
