using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DvPlayer.Services;

namespace DvPlayer.Controls;

/// <summary>
/// 横向海报行 / 集行：只横向滚动，滚轮永远交给页面纵向滚动。
///
/// 这是踩过好几次的坑：行内的 <see cref="ScrollViewer"/> 会先把滚轮吃掉，鼠标停在
/// 封面上整页就滚不动了。所以统一用这个控件，滚轮在 Preview 阶段就转交给最近的
/// 纵向 <see cref="ScrollViewer"/>，横向只能用左右箭头（箭头走
/// <see cref="SmoothScroll.ScrollBy"/>）。
///
/// 页面里不要再手写 <c>HorizontalScrollBarVisibility</c> / <c>PreviewMouseWheel</c>：
/// <code>
/// &lt;controls:HorizontalRow x:Name="CastScroller"&gt;
///   &lt;ItemsControl ... /&gt;
/// &lt;/controls:HorizontalRow&gt;
/// </code>
/// </summary>
public class HorizontalRow : ScrollViewer
{
    public HorizontalRow()
    {
        HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden;
        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        Focusable = false;
    }

    /// <summary>按像素横向滚动一段，带缓出动画。箭头按钮都走这里。</summary>
    public void ScrollBy(double delta) => SmoothScroll.ScrollBy(this, delta);

    protected override void OnPreviewMouseWheel(MouseWheelEventArgs e)
    {
        base.OnPreviewMouseWheel(e);

        // 行自己不滚：把滚轮交给页面（或弹层里）的纵向滚动。
        if (FindVerticalScroll() is { } page)
        {
            page.ScrollToVerticalOffset(page.VerticalOffset - e.Delta * 0.5);
        }

        e.Handled = true;
    }

    /// <summary>往上找最近的、真正能纵向滚动的 ScrollViewer（行自己的纵向是 Disabled）。</summary>
    private ScrollViewer? FindVerticalScroll()
    {
        for (var parent = VisualTreeHelper.GetParent(this); parent is not null;
             parent = VisualTreeHelper.GetParent(parent))
        {
            if (parent is ScrollViewer { VerticalScrollBarVisibility: not ScrollBarVisibility.Disabled } scroll)
            {
                return scroll;
            }
        }

        return null;
    }
}
