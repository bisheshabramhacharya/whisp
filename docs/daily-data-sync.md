# Daily data and folder sync (v1)

In **History → Search & Edit History…**, search both the raw and final transcript. Editing changes the final text you copy or paste, not the original model output or saved audio. **Edit Dictionary…** manages capitalization terms and phrase replacements. **Microphone Settings…** changes the input for subsequent dictations and falls back to the system default if the selected microphone is disconnected.

To sync, use **Folder Sync…** and pick the same folder on each device (or corresponding folders in a tool such as Dropbox, iCloud Drive, or Syncthing). Whisp periodically checks the folder while running. It also offers **Sync Now**. No Whisp account or server is involved. Sync covers dictation text, including raw model output, and dictionary entries. These are readable files, not encrypted by Whisp: choose a folder you trust. Audio, hardware settings, and the selected folder path stay local. Disconnecting stops future exchanges; it does not remove data already received or files already written.

## Transport

The selected folder contains a `Whisp Sync v1` directory. Each operation is one UTF-8 JSON file named `<operation>.json`, where the operation is a lowercase hyphenated UUID:

```json
{"version":1,"record":{"kind":"dictionary","id":"4:cubeKubernetes","revision":1,"operation":"ab91ac9a-6b9f-4958-bf20-a5ea51ee7210","deleted":false,"value":"cube","detail":"Kubernetes"}}
```

- The record key is `(kind, id)`. `revision` is a nonnegative signed 64-bit integer. A new legacy seed has revision 0; a new normal record has revision 1. Edits and deletes increment the observed revision. The winner has the largest revision; at equal revision a delete wins, then the lexically larger operation UUID wins. No wall-clock synchronization is required. Edits to different records merge independently; simultaneous edits to the same record do not combine text.
- Operations are immutable and published by atomic rename from a sibling temporary file. Every update gets its own filename, so devices never need to replace a common file. A sync reads valid operations, durably saves the merge locally, and publishes missing winning operations. A malformed envelope, mismatched UUID, or unsupported format is skipped and retried later. Temporary and unrelated files are ignored.
- A deleted record is a tombstone: both string fields are empty. Tombstones are not automatically removed. Do not prune operation files as a way to delete records. There is no compaction in v1.
- `history`: `id` is the original dictation ID, `value` is the existing history JSON object encoded as a string (`id`, UTC ISO 8601 `date` at second resolution, `durationSec`, `raw`, `cleaned`, `latencyMs`), and `detail` is empty. The nested ID must match the record ID.
- `dictionary`: `value` is the nonempty word or source phrase and `detail` is its replacement (empty for a capitalization term). New entries typically use an ID made of the UTF-8 length of the lowercase source, a colon, the lowercase source and the replacement. An edit keeps that ID. Adding the old phrase again uses a fresh UUID if an edited record still occupies its original ID.
- `local`: local app preferences only. Never accept or publish this kind in the transport.

Each device saves its winning records, including tombstones and local preferences, in `daily-data.json` under its normal private app data directory (`{"version":1,"records":[…]}`). Do not select this private app directory itself as a provider-synced folder. Existing `history.jsonl` and `dictionary.json` are preserved as migration sources. New local dictations also append to the legacy history log for compatibility with recording analysis tools; that log does not receive sync or edits. The in-app editors are authoritative after migration; legacy data seeds missing records only and cannot override edits or resurrect deleted entries.
