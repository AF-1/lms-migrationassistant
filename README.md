Migration Assistant
====
![Min. LMS Version](https://img.shields.io/badge/dynamic/xml?url=https%3A%2F%2Fraw.githubusercontent.com%2FAF-1%2Fsobras%2Fmain%2Frepos%2Flms%2Fpublic.xml&cacheSeconds=172800&query=%2F%2F*%5Blocal-name()%3D'plugin'%20and%20%40name%3D'MigrationAssistant'%5D%2F%40minTarget&label=Min.%20LMS%20Version%20Required&color=darkgreen)<br>

<img src="MigrationAssistant/HTML/EN/plugins/MigrationAssistant/html/images/miga_icon_svg.png" align="right" width="70px">**Migration Assistant (MIGA)** creates a portable backup of your Lyrion Music Server (LMS) configuration and lets you selectively restore it on the same or a new installation. It's meant for anyone moving LMS to new hardware, a new OS or a fresh install, without having to manually reconfigure everything from scratch.<br clear="right">

<a href="https://github.com/AF-1/">⬅️ <b>Back to the list of all plugins</b></a>
<br><br>

> [!IMPORTANT]
> **Before using this plugin, please create your own backup of all relevant files.** Migration Assistant is provided "as is" - use at your own risk.<br>
> If you use [Ratings Light](https://github.com/AF-1/lms-ratingslight) and/or [Alternative Play Count](https://github.com/AF-1/lms-alternativeplaycount), please also create their own plugin backups before migrating - see below for why.

<br><br>

## Backup

A backup archive includes:

- LMS server preferences and all installed plugins' preferences<br><br>
- a small selection of per-track values: date added, play count, last played (LMS values, not APC)<br><br>
- your playlist folder (recursively, including subfolders), split into media playlists and other files<br><br>
- OPML/Favorites files<br><br>
- `log.conf` - logging settings<br><br>
- the Graphics, HTML, and IR custom folders<br><br>
- any additional custom folders you specify (e.g. a plugin's data folder), with a configurable target path for restoring to a different location<br><br>
- the data folders of the plugins Alternative Play Count, Custom Skip, Dynamic Playlists, Dynamic Playlist Creator, Ratings Light and Virtual Library Creator

<br>

### Installed Plugin Files (optional)

By default, a backup only includes plugin *preferences*, not the plugin files themselves. If you also want to back up and restore the actual files of plugins you installed through **Manage Plugins** (the Extension Manager) or manually - not plugins that came pre-installed with LMS - enable this on the backup settings page. This increases backup size.

On restore, you choose which of the backed-up plugins to actually reinstall. A few safeguards apply automatically:

- A plugin already present on the target system is never overwritten. It's skipped and clearly marked.
- A plugin whose backed-up minimum LMS version or platform doesn't match the target system is skipped and marked as incompatible.
- If a plugin folder was backed up on a different OS than the one you're restoring to and it looks like it might contain platform-specific binary files, you'll see a warning. The restore itself isn't blocked but it's worth checking that the plugin still works afterwards.
- Restored plugins are automatically re-enabled after the next restart, same as if you'd just installed them yourself.

This is a convenience feature. **Installing the plugins you need yourself, the normal way, remains the recommended approach.**

<br>

**Not included, on purpose:**

- **`library.db` and `persist.db`** - these aren't backed up. They're large and there's no need: `library.db` is rebuilt correctly by the rescan that follows a fresh install or a restore anyway and the per-track values Migration Assistant does carry over (date added, play count, date last played) are restored directly into `persist.db`. Ratings, extended play count data and play history are better restored through the backup/restore features of Ratings Light and Alternative Play Count, which is why I recommend backing those up separately beforehand.<br><br>
- **Protected system folders** - the LMS preferences folder, cache folder, Plugins folder and your configured media library folders can't be added as custom backup paths, since backing them up this way could conflict with, duplicate or corrupt data that's already handled elsewhere.<br><br>
- **Folders that duplicate a plugin's own data folder** - if a custom path you enter matches a data folder already covered automatically (see list above), it's skipped to avoid backing it up twice.

<br><br>

## Restore

**Restoring onto a freshly installed server?**
- Install LMS first and complete the setup wizard, setting your media folder path(s) and playlist folder path.
- Wait until the initial library scan has **fully** completed.
- Go to *LMS Settings > Manage Plugins* and install the plugins you want to use, the normal way, at the very least Migration Assistant itself since it's the tool doing the restoring.
- Only then continue with the steps below.

<br>

1. During the restoration process, do not play any songs or modify any settings, as they will remain read-only until the server restarts.<br><br>
2. Point Migration Assistant at a previously created backup archive.<br><br>
2. Preview its contents and choose exactly which items to restore - nothing is restored automatically or all-or-nothing.<br><br>
3. **Immediately after the restore is complete, the server must be restarted. This is mandatory.**<br>If anything you restored requires a *rescan*, you will be notified after the restore completes and must trigger the rescan manually **after restarting the server**.

<br>

### Restoring across systems

Restoring track statistics from a backup created on a different operating system (macOS/Linux/Windows) is supported. A small number of tracks whose file names use characters not allowed on the current operating system may remain unmatched. See the server log for details or [Restoring backups across operating systems](https://github.com/AF-1/sobras/wiki/Restoring-backups-across-operating-systems) for more info.

Migration Assistant also supports moving to a new system where your music library lives at a different path than before. Per-track values (date added, play count, last played) are matched by each track's path *relative to* your configured media folder, then reapplied against the media folder(s) configured on the target system. This should work even if the absolute path changes, as long as the folder structure underneath it stays the same.

Playlist files are backed up and restored as-is. If a playlist references tracks by absolute path, it will likely still point to the old path after restoring. The **PotPourri**(https://github.com/AF-1/#-potpourri) plugin can export playlist files with an updated path from the source system beforehand, if you need that.

<br><br><br>

## Installation

**Migration Assistant** is available from the LMS plugin library: `LMS > Settings > Manage Plugins`.<br>

If you want to test a new patch that hasn't made it into a release version yet, you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).
<br><br><br><br>


## Report a new issue

To report a new issue please file a GitHub [**issue report**](https://github.com/AF-1/lms-migrationassistant/issues/new/choose).
<br><br><br>

---

If this project was useful to you, you can star the repository using the <img src="screenshots/githubstar.png" width="20" height="20" alt="star" /> button in the top-right corner of this page.
<br><br><br>
