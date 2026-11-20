using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace DvPlayer.Controls;

/// <summary>
/// 搜索框整块都能点。文本框只认自己那一小块，点放大镜图标或左右内边距
/// （`Padding` 留出来的位置）会落在 Border 上，看起来像「点不进去」。
/// 挂上这个附加属性后，点边框任意位置都把焦点转给里面的 TextBox。
/// </summary>
public static class SearchBoxFocus
{
    public static readonly DependencyProperty EnabledProperty =
        DependencyProperty.RegisterAttached(
            "Enabled", typeof(bool), typeof(SearchBoxFocus),
            new PropertyMetadata(false, OnEnabledChanged));

    public static void SetEnabled(DependencyObject element, bool value) =>
        element.SetValue(EnabledProperty, value);

    public static bool GetEnabled(DependencyObject element) =>
        (bool)element.GetValue(EnabledProperty);

    private static void OnEnabledChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not Border border) return;

        border.MouseLeftButtonDown -= OnMouseDown;
        if (e.NewValue is true)
        {
            border.Cursor = Cursors.IBeam;
            border.MouseLeftButtonDown += OnMouseDown;
        }
    }

    private static void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border border) return;
        if (FindBox(border) is not { } box) return;
        if (box.IsFocused) return;

        box.Focus();
        box.CaretIndex = box.Text.Length;
    }

    private static TextBox? FindBox(DependencyObject root)
    {
        if (root is TextBox box) return box;

        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            if (FindBox(VisualTreeHelper.GetChild(root, i)) is { } found) return found;
        }
        return null;
    }
}
