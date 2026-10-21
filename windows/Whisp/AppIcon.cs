namespace Whisp;

internal static class AppIcon
{
    private static Icon? _icon;

    /// The icon embedded in Whisp.exe (Resources/whisp.ico).
    public static Icon Load() =>
        _icon ??= (Environment.ProcessPath is { } exe ? Icon.ExtractAssociatedIcon(exe) : null) ?? SystemIcons.Application;
}
