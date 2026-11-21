using System.Windows;
using System.Windows.Controls;

namespace DvPlayer.Controls;

/// <summary>
/// 海报网格：WrapPanel + 按可用宽度自适应卡片尺寸。
///
/// 列数 = floor(可用宽度 / (MinCardWidth + Gap))，卡片宽度铺满格子、高度 2:3，
/// 所以窗口再宽也不会在右侧留一条空白。翻到下一列时卡片缩回去。
///
/// 用 ItemsControl 派生，是为了让所有页面共用这一份计算，页面只提供 ItemTemplate；
/// 模板里需要尺寸的地方绑 <c>CardWidth</c> / <c>CardHeight</c> / <c>CardSlot</c>：
/// <code>
/// &lt;controls:PosterGrid ItemTemplate="{StaticResource ...}" /&gt;
/// &lt;StackPanel Width="{Binding CardSlot,
///     RelativeSource={RelativeSource AncestorType=controls:PosterGrid}}"&gt;
/// </code>
/// </summary>
public class PosterGrid : ItemsControl
{
    /// <summary>卡片之间的横向间距。</summary>
    public const double Gap = 16;

    /// <summary>
    /// 卡片最小宽度。窗口窄到放不下几列时以它为准。
    /// 竖版海报默认 175；16:9 横卡（观看记录）要设大一点，不然窄窗口会挤成小豆腐块。
    /// </summary>
    public static readonly DependencyProperty MinCardWidthProperty = DependencyProperty.Register(
        nameof(MinCardWidth), typeof(double), typeof(PosterGrid),
        new PropertyMetadata(175d, OnLayoutChanged));

    /// <summary>
    /// 卡片宽高比（宽 / 高）。默认 2/3 是竖版海报 2:3；16:9 横卡填 1.7778。
    /// </summary>
    public static readonly DependencyProperty CardRatioProperty = DependencyProperty.Register(
        nameof(CardRatio), typeof(double), typeof(PosterGrid),
        new PropertyMetadata(2d / 3d, OnLayoutChanged));

    public static readonly DependencyProperty CardWidthProperty = DependencyProperty.Register(
        nameof(CardWidth), typeof(double), typeof(PosterGrid),
        new PropertyMetadata(148d, null));

    public static readonly DependencyProperty CardHeightProperty = DependencyProperty.Register(
        nameof(CardHeight), typeof(double), typeof(PosterGrid),
        new PropertyMetadata(222d, null));

    public static readonly DependencyProperty CardSlotProperty = DependencyProperty.Register(
        nameof(CardSlot), typeof(double), typeof(PosterGrid),
        new PropertyMetadata(148d + Gap, null));

    public static readonly DependencyProperty CardMarginProperty = DependencyProperty.Register(
        nameof(CardMargin), typeof(Thickness), typeof(PosterGrid),
        new PropertyMetadata(new Thickness(0, 0, 0, 22)));

    public PosterGrid()
    {
        ItemsPanel = new ItemsPanelTemplate(new FrameworkElementFactory(typeof(WrapPanel)));
        SizeChanged += (_, e) => Update(e.NewSize.Width);
    }

    /// <summary>卡片最小宽度。</summary>
    public double MinCardWidth
    {
        get => (double)GetValue(MinCardWidthProperty);
        set => SetValue(MinCardWidthProperty, value);
    }

    /// <summary>卡片宽高比（宽 / 高）。</summary>
    public double CardRatio
    {
        get => (double)GetValue(CardRatioProperty);
        set => SetValue(CardRatioProperty, value);
    }

    /// <summary>海报宽度。列数变化时重算。</summary>
    public double CardWidth
    {
        get => (double)GetValue(CardWidthProperty);
        private set => SetValue(CardWidthProperty, value);
    }

    /// <summary>海报高度，保持 2:3。</summary>
    public double CardHeight
    {
        get => (double)GetValue(CardHeightProperty);
        private set => SetValue(CardHeightProperty, value);
    }

    /// <summary>一个格子的宽度（卡片 + 右侧间距）。WrapPanel 靠它让一行正好铺满。</summary>
    public double CardSlot
    {
        get => (double)GetValue(CardSlotProperty);
        private set => SetValue(CardSlotProperty, value);
    }

    /// <summary>格子的外边距（下面用来留行距）。横向行里的卡片模板复用同一份时靠它兜底。</summary>
    public Thickness CardMargin
    {
        get => (Thickness)GetValue(CardMarginProperty);
        private set => SetValue(CardMarginProperty, value);
    }

    /// <summary>上一次套用的比例：只改比例不改窗口宽度时也要重算高度。</summary>
    private double _appliedRatio = 2d / 3d;

    private static void OnLayoutChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var grid = (PosterGrid)d;
        grid.Update(grid.ActualWidth);
    }

    private void Update(double available)
    {
        var minWidth = Math.Max(40, MinCardWidth);
        var ratio = CardRatio > 0.05 ? CardRatio : 2d / 3d;

        if (available < minWidth + Gap)
        {
            return;
        }

        var columns = Math.Max(1, (int)Math.Floor(available / (minWidth + Gap)));
        var slot = Math.Floor(available / columns * 100) / 100;
        var width = Math.Max(1, slot - Gap);

        if (Math.Abs(width - CardWidth) < 0.5 && Math.Abs(ratio - _appliedRatio) < 0.0001)
        {
            return;
        }

        _appliedRatio = ratio;
        CardWidth = width;
        CardHeight = Math.Max(1, Math.Round(width / ratio));
        CardSlot = slot;
    }
}
