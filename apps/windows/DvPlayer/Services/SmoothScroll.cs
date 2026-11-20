using System.Windows;
using System.Windows.Controls;

namespace DvPlayer.Services;

/// <summary>
/// 给 ScrollViewer 一个可以动画的水平偏移。
///
/// WPF 的 <see cref="ScrollViewer.HorizontalOffset"/> 是只读的，没法直接做
/// DoubleAnimation；挂一个附加属性，动画它，变化时再真正滚过去。
/// </summary>
public static class SmoothScroll
{
    public static readonly DependencyProperty OffsetProperty =
        DependencyProperty.RegisterAttached(
            "Offset",
            typeof(double),
            typeof(SmoothScroll),
            new PropertyMetadata(0.0, OnOffsetChanged));

    public static void SetOffset(DependencyObject element, double value) =>
        element.SetValue(OffsetProperty, value);

    public static double GetOffset(DependencyObject element) =>
        (double)element.GetValue(OffsetProperty);

    private static void OnOffsetChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is ScrollViewer viewer)
        {
            viewer.ScrollToHorizontalOffset((double)e.NewValue);
        }
    }
}