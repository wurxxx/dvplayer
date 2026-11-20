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

    /// <summary>卡片最小宽度。窗口窄到放不下几列时以它为准。</summary>
    public const double MinCardWidth = 175;

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

    private void Update(double available)
    {
        if (available < MinCardWidth + Gap)
        {
            return;
        }

        var columns = Math.Max(1, (int)Math.Floor(available / (MinCardWidth + Gap)));
        var slot = Math.Floor(available / columns * 100) / 100;
        var width = Math.Max(1, slot - Gap);

        if (Math.Abs(width - CardWidth) < 0.5)
        {
            return;
        }

        CardWidth = width;
        CardHeight = Math.Round(width * 1.5);
        CardSlot = slot;
    }
}
