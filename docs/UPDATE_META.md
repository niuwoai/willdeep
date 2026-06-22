# WillDeep Update Metadata

WillDeep checks this URL on app launch:

```text
https://meta.niuwoai.com/willdeep/meta.json
```

The client only notifies the user and opens the download URL. It does not silently download or install updates.

## Example

```json
{
  "version": "1.63.0",
  "download_url": "https://meta.niuwoai.com/willdeep/WillDeep-1.63.0.dmg",
  "release_notes_url": "https://meta.niuwoai.com/willdeep/releases/1.63.0.html",
  "minimum_system_version": "13.7",
  "notes": "Bug fixes and update-check improvements."
}
```

## Fields

- `version` is required. Use semantic versions such as `1.63.0` or `1.63.0-rc1`.
- `download_url` is required and must be an absolute URL.
- `release_notes_url` is optional and must be an absolute URL when present.
- `minimum_system_version` is optional and is shown in the update alert.
- `notes` is optional and is shown in the update alert.

The client also accepts camelCase aliases: `downloadURL`, `releaseNotesURL`, and `minimumSystemVersion`.
