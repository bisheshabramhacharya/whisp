using System.Globalization;
using System.IO.Compression;
using System.Xml.Linq;
using Whisp.Core.Text;

namespace Whisp.Core;

/// <summary>
/// Brings a Mac's Whisp data over: the dictionary, history, recordings and menu
/// settings. Takes the zip (or unzipped folder) made on the Mac by
/// scripts/export-for-windows.sh (see windows/README.md).
///
/// Everything merges into what's already here — nothing on this PC is overwritten:
/// dictionary words are added, history entries are added by id, recordings are copied
/// when missing, and settings found in the plist are applied.
/// </summary>
public static class MacImport
{
    public sealed record Report(int Terms, int Replacements, int History, int Recordings, int Settings, List<string> Notes)
    {
        public override string ToString()
        {
            var parts = new List<string>();
            if (Terms + Replacements > 0) parts.Add($"{Terms + Replacements} dictionary word{(Terms + Replacements == 1 ? "" : "s")}");
            if (History > 0) parts.Add($"{History} history entr{(History == 1 ? "y" : "ies")}");
            if (Recordings > 0) parts.Add($"{Recordings} recording{(Recordings == 1 ? "" : "s")}");
            if (Settings > 0) parts.Add($"{Settings} setting{(Settings == 1 ? "" : "s")}");
            var summary = parts.Count == 0 ? "Nothing new to import." : "Imported " + string.Join(", ", parts) + ".";
            return Notes.Count == 0 ? summary : summary + "\n\n" + string.Join("\n", Notes);
        }
    }

    public static Report Import(string source, AppPaths paths, AppSettings settings)
    {
        string? tempDir = null;
        try
        {
            var root = source;
            if (File.Exists(source))
            {
                tempDir = Path.Combine(Path.GetTempPath(), "whisp-import-" + Guid.NewGuid().ToString("N"));
                ZipFile.ExtractToDirectory(source, tempDir);
                root = tempDir;
            }
            if (!Directory.Exists(root)) throw new DirectoryNotFoundException(source);
            return ImportFolder(root, paths, settings);
        }
        finally
        {
            if (tempDir != null)
            {
                try { Directory.Delete(tempDir, recursive: true); } catch (IOException) { }
            }
        }
    }

    private static Report ImportFolder(string root, AppPaths paths, AppSettings settings)
    {
        var notes = new List<string>();
        paths.EnsureCreated();

        // macOS zips carry __MACOSX/ resource-fork shadows of every file; skip them.
        IEnumerable<string> Find(string pattern) => Directory
            .EnumerateFiles(root, pattern, SearchOption.AllDirectories)
            .Where(p => !p.Contains("__MACOSX", StringComparison.OrdinalIgnoreCase)
                        && !Path.GetFileName(p).StartsWith("._", StringComparison.Ordinal));

        // Dictionary
        int terms = 0, replacements = 0;
        if (Find("dictionary.json").FirstOrDefault() is { } dictionary)
        {
            var dest = paths.DictionaryFile;
            if (!File.Exists(dest))
            {
                File.Copy(dictionary, dest);
                terms = PersonalDictionary.LoadTerms(dest).Count;
                replacements = PersonalDictionary.LoadPairs(dest).Sum(p => p.From.Length);
                if (terms + replacements == 0 && File.ReadAllText(dest).Trim().Length > 2)
                    notes.Add("The Mac dictionary.json didn't parse; it was copied as-is so you can fix it.");
            }
            else
            {
                var beforeTerms = PersonalDictionary.LoadTerms(dest).Count;
                var beforeReplacements = PersonalDictionary.LoadPairs(dest).Sum(p => p.From.Length);
                foreach (var term in PersonalDictionary.LoadTerms(dictionary))
                    PersonalDictionary.AddTerm(term, dest);
                foreach (var (from, to) in PersonalDictionary.LoadPairs(dictionary))
                    foreach (var f in from)
                        PersonalDictionary.AddReplacement(f, to, dest);
                terms = PersonalDictionary.LoadTerms(dest).Count - beforeTerms;
                replacements = PersonalDictionary.LoadPairs(dest).Sum(p => p.From.Length) - beforeReplacements;
            }
        }
        else
        {
            notes.Add("No dictionary.json found.");
        }

        // History
        var history = 0;
        if (Find("history.jsonl").FirstOrDefault() is { } historyFile)
        {
            var incoming = new HistoryStore(historyFile).LoadAll();
            history = new HistoryStore(paths.HistoryFile).Merge(incoming);
        }

        // Recordings
        var recordings = 0;
        var wavs = Find("*.wav").Where(p => Path.GetFileName(Path.GetDirectoryName(p)) == "recordings").ToList();
        if (wavs.Count > 0)
        {
            Directory.CreateDirectory(paths.RecordingsDirectory);
            foreach (var wav in wavs)
            {
                var dest = Path.Combine(paths.RecordingsDirectory, Path.GetFileName(wav));
                if (File.Exists(dest)) continue;
                File.Copy(wav, dest);
                recordings++;
            }
        }

        // Settings
        var applied = 0;
        if (Find("*.plist").FirstOrDefault() is { } plist)
        {
            try
            {
                applied = ApplyPlist(plist, settings);
            }
            catch (Exception e) when (e is InvalidDataException or System.Xml.XmlException)
            {
                notes.Add($"Settings weren't imported: {e.Message}");
            }
        }

        return new Report(terms, replacements, history, recordings, applied, notes);
    }

    /// Applies the Mac menu settings found in an XML plist (`defaults export` output
    /// converted with `plutil -convert xml1`). Returns how many were applied.
    public static int ApplyPlist(string path, AppSettings settings)
    {
        var head = new byte[8];
        using (var f = File.OpenRead(path)) f.ReadExactly(head, 0, Math.Min(8, (int)f.Length));
        if (System.Text.Encoding.ASCII.GetString(head).StartsWith("bplist", StringComparison.Ordinal))
            throw new InvalidDataException("the settings file is a binary plist; convert it on the Mac with `plutil -convert xml1 <file>`");

        var dict = XDocument.Load(path).Root?.Element("dict")
            ?? throw new InvalidDataException("no <dict> in the plist");
        var values = new Dictionary<string, XElement>();
        XElement? key = null;
        foreach (var element in dict.Elements())
        {
            if (element.Name == "key")
            {
                key = element;
            }
            else if (key != null)
            {
                values[key.Value] = element;
                key = null;
            }
        }

        var applied = 0;
        bool? Bool(string name) => values.TryGetValue(name, out var v) ? v.Name.LocalName switch
        {
            "true" => true,
            "false" => false,
            "integer" => v.Value.Trim() != "0",
            _ => null,
        } : null;
        double? Number(string name) => values.TryGetValue(name, out var v)
            && v.Name.LocalName is "real" or "integer"
            && double.TryParse(v.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null;

        if (Bool("sounds") is bool sounds) { settings.Sounds = sounds; applied++; }
        if (Bool("autoMute") is bool autoMute) { settings.AutoMute = autoMute; applied++; }
        if (Bool("keepRecordings") is bool keep) { settings.KeepRecordings = keep; applied++; }
        if (Bool("alwaysShowPill") is bool always) { settings.AlwaysShowPill = always; applied++; }
        if (Bool("launchAtLoginDesired") is bool login) { settings.LaunchAtLogin = login; applied++; }
        if (Number("pillScale") is double scale && scale is > 0.2 and < 3) { settings.PillScale = scale; applied++; }
        // The Mac's pill position is in Mac screen points and its hotkey is a Mac key code;
        // neither means anything here, so they're left at the Windows defaults.
        return applied;
    }
}
