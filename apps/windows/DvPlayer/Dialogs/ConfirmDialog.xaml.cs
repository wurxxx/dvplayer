using System.Windows;
using System.Windows.Input;

namespace DvPlayer.Dialogs;

/// <summary>
/// 深色确认框，替掉系统的 MessageBox。
///
/// 系统 MessageBox 是浅色弹窗，在深色界面里特别扎眼；这里用和页面一样的
/// 卡片（`#1F1F27` + 圆角 + 自带阴影），危险操作用红色按钮。
/// 回车 / Esc 都走「取消」，删除这类操作不靠回车误触。
/// </summary>
public partial class ConfirmDialog : Window
{
    public ConfirmDialog()
    {
        InitializeComponent();
    }

    /// <summary>确认 / 取消二选一，返回是否确认。</summary>
    public static bool Ask(Window? owner, string title, string message,
                           string confirmText = "确定", bool danger = true)
    {
        var dialog = new ConfirmDialog();
        dialog.Configure(title, message, confirmText, danger, showCancel: true);

        if (owner is not null && !ReferenceEquals(owner, dialog))
        {
            dialog.Owner = owner;
        }

        return dialog.ShowDialog() == true;
    }

    /// <summary>只有「好」的提示框，用来替掉原来的警告 / 错误弹窗。</summary>
    public static void Alert(Window? owner, string title, string message)
    {
        var dialog = new ConfirmDialog();
        dialog.Configure(title, message, "好", danger: false, showCancel: false);

        if (owner is not null && !ReferenceEquals(owner, dialog))
        {
            dialog.Owner = owner;
        }

        dialog.ShowDialog();
    }

    /// <summary>填内容。确认框和提示框共用同一套模板，这里控制文案与配色。</summary>
    public void Configure(string title, string message, string confirmText,
                          bool danger, bool showCancel)
    {
        TitleText.Text = title;
        MessageText.Text = message;
        ConfirmButton.Content = confirmText;

        CancelButton.Visibility = showCancel ? Visibility.Visible : Visibility.Collapsed;
        ConfirmButton.Style = (Style)FindResource(danger ? "DangerButton" : "AccentButton");
        IconGlyph.Foreground = (System.Windows.Media.Brush)FindResource(
            danger ? "DangerBrush" : "AccentBrush");
        IconGlyph.Text = danger ? "\uE7BA" : "\uE946";
        IconBadge.Background = new System.Windows.Media.SolidColorBrush(
            danger
                ? System.Windows.Media.Color.FromArgb(0x26, 0xFF, 0x6B, 0x6B)
                : System.Windows.Media.Color.FromArgb(0x26, 0xFF, 0xB0, 0x20));

        if (!showCancel)
        {
            // 只有「好」时，焦点给到它，回车直接关。
            ConfirmButton.IsDefault = true;
            CancelButton.IsCancel = false;
            ConfirmButton.Focus();
        }
    }

    private void OnConfirmClick(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }

    private void OnCancelClick(object sender, RoutedEventArgs e) => DialogResult = false;

    private void OnWindowMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left)
        {
            return;
        }

        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
            // 快速点击时鼠标已经抬起，忽略。
        }
    }
}
