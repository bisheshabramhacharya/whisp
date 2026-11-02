using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Whisp.Core.Input;

public enum HotkeyDevice
{
    Keyboard,
    Mouse,
}

/// Mouse buttons that can be held to talk. Left and right click stay normal clicks.
public enum HotkeyMouseButton
{
    Middle = 1,
    /// XBUTTON1, the side button usually labelled Back.
    Back = 2,
    /// XBUTTON2, the side button usually labelled Forward.
    Forward = 3,
}

/// <summary>
/// The push-to-talk key: any keyboard key (by Windows virtual-key code) except Esc, or
/// the middle or a side mouse button. Saved in settings.json as text: "RightAlt" and
/// "RightCtrl" (the names older versions wrote), "Key:124" for other keys, and
/// "Mouse:Middle", "Mouse:Back" or "Mouse:Forward".
/// </summary>
[JsonConverter(typeof(HotkeyBindingJsonConverter))]
public readonly record struct HotkeyBinding(HotkeyDevice Device, int Code)
{
    public const int VkEscape = 0x1B;

    public static readonly HotkeyBinding RightAlt = Key(0xA5);
    public static readonly HotkeyBinding RightCtrl = Key(0xA3);
    public static readonly HotkeyBinding MiddleMouse = Mouse(HotkeyMouseButton.Middle);

    public static HotkeyBinding Key(int vk) => new(HotkeyDevice.Keyboard, vk);
    public static HotkeyBinding Mouse(HotkeyMouseButton button) => new(HotkeyDevice.Mouse, (int)button);

    public bool IsMouse => Device == HotkeyDevice.Mouse;

    /// Shift, Ctrl, Alt or Windows. Holding one of these alone does nothing in other apps,
    /// so Whisp lets it through and treats a quick chord (Alt+Tab) as "not dictating".
    public bool IsModifier => !IsMouse && IsModifierVk(Code);

    /// Alt and Windows keys open a menu (or Start) when released alone; Whisp masks that.
    public bool MasksRelease => !IsMouse && Code is 0x12 or 0xA4 or 0xA5 or 0x5B or 0x5C;

    /// Esc cancels a dictation, so it can't also start one.
    public bool IsAllowed => IsMouse ? Enum.IsDefined((HotkeyMouseButton)Code) : Code is > 0 and < 0xFF and not VkEscape;

    public static bool IsModifierVk(int vk) => vk is 0x10 or 0x11 or 0x12 or >= 0xA0 and <= 0xA5 or 0x5B or 0x5C;

    public override string ToString()
    {
        if (this == RightAlt) return "RightAlt";
        if (this == RightCtrl) return "RightCtrl";
        return IsMouse ? $"Mouse:{(HotkeyMouseButton)Code}" : $"Key:{Code}";
    }

    public static HotkeyBinding? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        text = text.Trim();
        HotkeyBinding? found = text switch
        {
            "RightAlt" => RightAlt,
            "RightCtrl" => RightCtrl,
            _ when text.StartsWith("Key:", StringComparison.OrdinalIgnoreCase)
                && int.TryParse(text[4..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var vk) => Key(vk),
            _ when text.StartsWith("Mouse:", StringComparison.OrdinalIgnoreCase)
                && Enum.TryParse<HotkeyMouseButton>(text[6..], ignoreCase: true, out var button) => Mouse(button),
            _ => null,
        };
        return found is { IsAllowed: true } ? found : null;
    }

    /// What the menu and status line call it: "Right Alt", "F13", "Middle mouse button".
    public string DisplayName => IsMouse
        ? (HotkeyMouseButton)Code switch
        {
            HotkeyMouseButton.Middle => "Middle mouse button",
            HotkeyMouseButton.Back => "Mouse Back button",
            HotkeyMouseButton.Forward => "Mouse Forward button",
            _ => $"Mouse button {Code}",
        }
        : KeyName(Code);

    private static string KeyName(int vk) => vk switch
    {
        >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        >= 0x60 and <= 0x69 => $"Numpad {vk - 0x60}",
        >= 0x70 and <= 0x87 => $"F{vk - 0x6F}",
        0x08 => "Backspace",
        0x09 => "Tab",
        0x0D => "Enter",
        0x10 => "Shift",
        0x11 => "Ctrl",
        0x12 => "Alt",
        0x13 => "Pause",
        0x14 => "Caps Lock",
        0x20 => "Space",
        0x21 => "Page Up",
        0x22 => "Page Down",
        0x23 => "End",
        0x24 => "Home",
        0x25 => "Left Arrow",
        0x26 => "Up Arrow",
        0x27 => "Right Arrow",
        0x28 => "Down Arrow",
        0x2C => "Print Screen",
        0x2D => "Insert",
        0x2E => "Delete",
        0x5B => "Left Windows",
        0x5C => "Right Windows",
        0x5D => "Menu key",
        0x6A => "Numpad *",
        0x6B => "Numpad +",
        0x6D => "Numpad -",
        0x6E => "Numpad .",
        0x6F => "Numpad /",
        0x90 => "Num Lock",
        0x91 => "Scroll Lock",
        0xA0 => "Left Shift",
        0xA1 => "Right Shift",
        0xA2 => "Left Ctrl",
        0xA3 => "Right Ctrl",
        0xA4 => "Left Alt",
        0xA5 => "Right Alt",
        0xAD => "Mute",
        0xAE => "Volume Down",
        0xAF => "Volume Up",
        0xB0 => "Next Track",
        0xB1 => "Previous Track",
        0xB3 => "Play/Pause",
        0xBA => ";",
        0xBB => "=",
        0xBC => ",",
        0xBD => "-",
        0xBE => ".",
        0xBF => "/",
        0xC0 => "`",
        0xDB => "[",
        0xDC => "\\",
        0xDD => "]",
        0xDE => "'",
        _ => $"Key 0x{vk:X2}",
    };
}

/// Reads and writes the settings.json text form. A value it can't read falls back to
/// Right Alt instead of throwing away every other setting.
public sealed class HotkeyBindingJsonConverter : JsonConverter<HotkeyBinding>
{
    public override HotkeyBinding Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            reader.Skip();
            return HotkeyBinding.RightAlt;
        }
        return HotkeyBinding.Parse(reader.GetString()) ?? HotkeyBinding.RightAlt;
    }

    public override void Write(Utf8JsonWriter writer, HotkeyBinding value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
}
