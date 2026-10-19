namespace Whisp.Core.Text;

public static class Spacing
{
    /// Dictation is appended to a word/sentence (so needs a separating space) unless the
    /// cursor follows whitespace or an opening bracket/quote/slash: "foo(" + "bar" -> "foo(bar".
    public static bool NeedsSpace(char previous) =>
        !char.IsWhiteSpace(previous) && "([{/\\“‘".IndexOf(previous) < 0;
}
