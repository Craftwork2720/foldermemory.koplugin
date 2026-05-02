[![Download foldermemory.koplugin.zip](https://img.shields.io/badge/Download-foldermemory.koplugin.zip-blue?style=for-the-badge&logo=github&logoColor=white&labelColor=1f2328)](https://github.com/Craftwork2720/-private-wip-foldermemory.koplugin/releases/latest/download/foldermemory.koplugin.zip)

# foldermemory.koplugin

FolderMemory remembers your sort, display, and layout preferences for every folder, automatically. Instead of reconfiguring sort order, display mode, or layout each time, the plugin ensures a consistent browsing experience across your library.

<br>

<img src="screenshots/foldermemory-grids.png" width="500">

## What it does

When you navigate into a folder, **Folder Memory** remembers and restores:

- **Sort order** (by name, date, size, etc.)
- **Reverse sort** direction
- **Folders and files mixed** toggle
- **Book status filter** (new, reading, abandoned, complete, or any combination)
- **Display mode**: classic (filenames only), mosaic (cover images or text covers), detailed list (with images, metadata, or filenames)
- **Items per page**: mosaic grid columns × rows (portrait and landscape), list mode files per page

### Inheritance from parent folders

If a folder has no saved settings of its own, the plugin walks up the directory tree and uses the nearest ancestor's settings. If none is found, it falls back to a global default template you can configure.

This means you can save settings once on `Books/` and all subfolders (`Books/Fantasy/`, `Books/Sci-Fi/`, etc.) will inherit them — unless you override a specific folder. When inheritance is disabled, every folder without its own settings goes directly to the default template.

### Default template

A global `__default__` template is auto-created from your current KOReader settings on first install. You can edit it anytime via the plugin menu without affecting your current folder — it serves as a fallback for folders without their own saved settings and for virtual views (History, Favorites, Collections).

## How it works

- **Auto-save** — any change you make to sort, display mode, grid, or book status filter via KOReader's native menus or the Folder Memory menu is automatically captured and saved for the current folder.
- **Seamless restore** — settings are applied automatically when entering a folder
- **History, Favorites, Collections** — use the Items per page from default template

## Installation

Copy the `foldermemory.koplugin` folder to `koreader/plugins/` and restart KOReader.

## Usage

While in the file browser, open the top-left hamburger menu → **Folder memory**:

| Menu item | Description |
|-----------|-------------|
| **Configure this folder** | Edit sort, display mode, grid, and book status filter for the current folder. Changes are saved automatically and applied immediately. |
| **Clear saved settings for this folder** | Remove the current folder's saved settings — it will inherit from parent folders or fall back to defaults. |
| **Inherit settings from parent folders** | Toggle inheritance on/off. When off, folders without their own settings skip ancestors and go directly to the default template. |
| **Configure default settings** | Edit the `__default__` template. These changes never affect your current folder — they only define the fallback for unconfigured folders and virtual views. |
| **Clear all saved folder settings** | Remove all per-folder memory. The default template is preserved. |

## Compatibility

Tested on KOReader 2026.03 "Snowflake" and nightly. Should work on any recent version. Requires CoverBrowser plugin for display mode and grid features (the plugin gracefully degrades if CoverBrowser is not installed).

#### My [User Patches](https://github.com/Craftwork2720/koreader-patches) for KOReader. ❤️