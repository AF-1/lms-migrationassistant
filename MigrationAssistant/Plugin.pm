#
# MigrationAssistant
# (c) 2026 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::MigrationAssistant::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Control::Request;
use Time::HiRes qw(time);
use POSIX qw(strftime);
use Slim::Schema;
use File::Spec::Functions qw(:ALL);
use File::Path qw(mkpath);
use Archive::Zip qw(:ERROR_CODES);
use YAML::XS qw(LoadFile);
use File::Temp qw(tempdir);
use FileHandle;
use Path::Class;
use XML::Parser;
use XML::Simple qw(XMLin);
use Unicode::Normalize;
use Digest::MD5 qw(md5_hex);

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.migrationassistant',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_MIGRATIONASSISTANT',
});
my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.migrationassistant');

my ($tpBackupParser, $tpBackupParserNB, $tpRestoreFH, $tpOpened, $tpInTrack, $tpInValue, $tpCurrentKey);
my %tpRestoreItem;

my ($tpRestoreFile, $tpRestoreDateAdded, $tpRestorePlayCountLastPlayed);
my ($tpRestoreCount, $tpRestoreStarted, $tpTotalTrackCount, $tpProcessedTrackCount, $tpRestoreErrors, $tpUnidentifiableCount, $tpUnmatchedCount, $tpRestoreDone, $tpBackupSourceOS, $tpBackupSourceCodepage, $tpPreferCodepageFirst);
my @tpUnmatchedTrackURLs;

my ($bkpZip, $bkpFile, $bkpTempDir, $bkpOutput, $bkpTotalTrackCount, $bkpProcessedTrackCount, $bkpStarted, $bkpErrors);
my @bkpPersistentTracks;

our @OUR_PLUGIN_DATA_FOLDERS;
my @DEFAULT_RESTORE_SKIP_PREFS;

sub initPlugin {
	my $class = shift;

	initPrefs();
	if (main::WEBUI) {
		require Plugins::MigrationAssistant::Settings::Backup;
		require Plugins::MigrationAssistant::Settings::Restore;
		Plugins::MigrationAssistant::Settings::Backup->new($class);
		Plugins::MigrationAssistant::Settings::Restore->new($class);
	}

	$class->SUPER::initPlugin(@_);
}

sub postinitPlugin {
	_requeuePendingRescanAfterRestart();
	_enablePendingInstalledPlugins();
}

sub initPrefs {
	$prefs->init({
		restorependingrescan => 0,
		restorecreatebaks => 1,
		backupinstalledplugins => 0,
		restorependinginstalledplugins => [],
	});
	$prefs->set('status_backuprestore', '0'); # 0 = idle, 1 = backup in progress, 2 = restore in progress
	$prefs->set('backuprestoreprogresspercentage', '0');
	$prefs->set('backuprestoreresult', '0'); # 0 = no result, 1 = backup success, 2 = backup error, 3 = restore success, 4 = restore error, 5 = restore success, requires rescan, 6 = restore success some tracks skipped, 7 = restore success requires rescan and some tracks skipped
	$prefs->set('restoreNeedsReload', 0);

	@OUR_PLUGIN_DATA_FOLDERS = (
		{ namespace => 'plugin.alternativeplaycount', pathkey => 'apcfolderpath' },
		{ namespace => 'plugin.customskip3', pathkey => 'customskipfolderpath' },
		{ namespace => 'plugin.dynamicplaylists4', pathkey => 'customplaylistfolder' },
		{ namespace => 'plugin.dynamicplaylistcreator', pathkey => 'customplaylistfolder' },
		{ namespace => 'plugin.ratingslight', pathkey => 'rlfolderpath' },
		{ namespace => 'plugin.virtuallibrarycreator', pathkey => 'customvirtuallibrariesfolder' },
	);
	@DEFAULT_RESTORE_SKIP_PREFS = (
		'server:server_uuid',
		'server:dbsource',
		'server:mediadirs',
		'server:playlistdir',
		'server:cachedir',
		'server:librarycachedir',
		'server:securitySecret',
		'server:bindAddress',
		'plugin.extensions:plugin',
		'plugin.alternativeplaycount:apcfolderpath',
		'plugin.alternativeplaycount:apcparentfolderpath',
		'plugin.customskip3:customskipfolderpath',
		'plugin.customskip3:customskipparentfolderpath',
		'plugin.dynamicplaylists4:customplaylistfolder',
		'plugin.dynamicplaylists4:customdirparentfolderpath',
		'plugin.dynamicplaylistcreator:customplaylistfolder',
		'plugin.dynamicplaylistcreator:customdirparentfolderpath',
		'plugin.ratingslight:rlfolderpath',
		'plugin.ratingslight:rlparentfolderpath',
		'plugin.virtuallibrarycreator:customvirtuallibrariesfolder',
		'plugin.virtuallibrarycreator:customdirparentfolderpath',
	);
}


## Backup

sub createBackup {
	if ($prefs->get('status_backuprestore')) {
		$log->warn('A backup or restore is already in progress, please wait for it to finish');
		return 0;
	}
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Cannot create a backup while a library scan is in progress');
		return 0;
	}

	my $backupFolder = $prefs->get('backupoutputfolder');
	return 0 unless $backupFolder && -d $backupFolder;

	$prefs->set('status_backuprestore', 1);
	$prefs->set('backuprestoreprogresspercentage', 0);
	$prefs->set('backuprestoreresult', 0);
	$bkpErrors = 0;
	$bkpStarted = time();

	my $prefsDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
	main::DEBUGLOG && $log->is_debug && $log->debug('prefsDir = '.Data::Dump::dump($prefsDir));
	my $pluginPrefsDir = catdir($prefsDir, 'plugin');

	$bkpZip = Archive::Zip->new();

	for my $rootPrefsFile (_prefsFilesIn($prefsDir)) {
		next unless -f $rootPrefsFile;
		my (undef, undef, $fileName) = splitpath($rootPrefsFile);
		_addPrefsFileToZip($rootPrefsFile, $fileName);
	}

	for my $pluginPrefsFile (_prefsFilesIn($pluginPrefsDir)) {
		next unless -f $pluginPrefsFile;
		my (undef, undef, $fileName) = splitpath($pluginPrefsFile);
		# zip entry names always use forward slashes, regardless of OS
		_addPrefsFileToZip($pluginPrefsFile, "plugin/$fileName");
	}

	$bkpTempDir = tempdir(CLEANUP => 1);
	$bkpFile = catfile($backupFolder, 'MigrationAssistant_backup_' . strftime('%Y%m%d_%H%M%S', localtime) . '.zip');

	main::DEBUGLOG && $log->is_debug && $log->debug('total backup time passed until exec of sub tasks = '.(time()-$bkpStarted));
	_backupPlaylistFolder();
	main::DEBUGLOG && $log->is_debug && $log->debug('total backup time passed after exec of _backupPlaylistFolder = '.(time()-$bkpStarted));
	_backupOpmlFiles($prefsDir);
	main::DEBUGLOG && $log->is_debug && $log->debug('total backup time passed after exec of _backupOpmlFiles = '.(time()-$bkpStarted));
	_backupLogConf($prefsDir);
	main::DEBUGLOG && $log->is_debug && $log->debug('total backup time passed after exec of _backupLogConf = '.(time()-$bkpStarted));
	_backupExtraSystemFolders();
	main::DEBUGLOG && $log->is_debug && $log->debug('total backup time passed after exec of _backupExtraSystemFolders = '.(time()-$bkpStarted));
	_backupCustomPaths();
	main::DEBUGLOG && $log->is_debug && $log->debug('total backup time passed after exec of _backupCustomPaths = '.(time()-$bkpStarted));
	_backupOurPluginDataFolders();
	main::DEBUGLOG && $log->is_debug && $log->debug('total backup time passed after exec of _backupOurPluginDataFolders = '.(time()-$bkpStarted));
	_backupInstalledPluginsFolder();
	main::DEBUGLOG && $log->is_debug && $log->debug('total backup time passed after exec of _backupInstalledPluginsFolder = '.(time()-$bkpStarted));
	_initTracksPersistentBackup();

	return 1;
}

sub _addPrefsFileToZip {
	my ($sourcePath, $zipEntryName) = @_;

	my $fileContent = eval {
		local $/;
		open(my $fh, '<:raw', $sourcePath) or die "$!";
		my $content = <$fh>;
		close $fh;
		$content;
	};
	if ($@ || !defined $fileContent) {
		$log->error("Could not read $sourcePath for backup archive - skipping it: " . ($@ || 'empty file'));
		return;
	}

	unless ($bkpZip->addString($fileContent, $zipEntryName)) {
		$log->error("Could not add $sourcePath to backup archive - skipping it");
	}
}

sub _prefsFilesIn {
	my $dir = shift;
	return () unless -d $dir;
	opendir(my $dh, $dir) or return ();
	my @files = map { catfile($dir, $_) } grep { /\.prefs$/i } readdir($dh);
	closedir($dh);
	return @files;
}

sub _backupDirToZip {
	my ($sourceDir, $zipPrefix) = @_;
	return 0 unless $sourceDir && -d $sourceDir;

	my @files;
	my @stack = ($sourceDir);
	while (my $dir = shift @stack) {
		opendir(my $dh, $dir) or next;
		for my $entry (readdir($dh)) {
			next if $entry eq '.' || $entry eq '..';
			next if _isJunkZipEntry($entry);
			my $fullPath = catfile($dir, $entry);
			if (-d $fullPath) {
				push @stack, $fullPath;
			} elsif (-f $fullPath) {
				push @files, $fullPath;
			}
		}
		closedir($dh);
	}
	return 0 unless @files;

	my $added = 0;
	for my $filePath (@files) {
		my $relPath = file($filePath)->relative($sourceDir);
		my $zipEntryName = "$zipPrefix/$relPath";
		$zipEntryName =~ s{\\}{/}g;

		my $fileContent = eval {
			local $/;
			open(my $fh, '<:raw', $filePath) or die "$!";
			my $content = <$fh>;
			close $fh;
			$content;
		};
		if ($@ || !defined $fileContent) {
			$log->error("Could not read $filePath for backup archive - skipping it: " . ($@ || 'empty file'));
			next;
		}
		if ($bkpZip->addString($fileContent, $zipEntryName)) {
			$added++;
		} else {
			$log->error("Could not add $filePath to backup archive - skipping it");
		}
	}
	return $added;
}

sub _backupPlaylistFolder {
	my $playlistDir = $serverPrefs->get('playlistdir');
	return unless $playlistDir && -d $playlistDir;

	my $added = _backupDirToZip($playlistDir, 'playlists');
	main::INFOLOG && $log->is_info && $log->info("Backed up $added file(s) from playlist folder: $playlistDir") if $added;
}

sub _backupOpmlFiles {
	my $prefsDir = shift;
	opendir(my $dh, $prefsDir) or return;
	my @opmlFiles = grep { /\.opml(?:\.backup)?$/i && -f catfile($prefsDir, $_) } readdir($dh);
	closedir($dh);

	for my $fileName (@opmlFiles) {
		_addPrefsFileToZip(catfile($prefsDir, $fileName), "opmlfiles/$fileName");
	}
	main::INFOLOG && $log->is_info && $log->info('Backed up '.scalar(@opmlFiles).' OPML/Favorites file(s)') if @opmlFiles;
}

sub _backupLogConf {
	my $prefsDir = shift;
	my $logConfFile = catfile($prefsDir, 'log.conf');
	return unless -f $logConfFile;

	_addPrefsFileToZip($logConfFile, 'log.conf');
	main::INFOLOG && $log->is_info && $log->info('Backed up log.conf');
}

sub _backupExtraSystemFolders {
	for my $dirType (qw(Graphics HTML IR)) {
		# only back up if this OS provides a genuine per-user custom directory separate from its stock resource directory (currently only true on macOS)
		my @dirs = Slim::Utils::OSDetect::dirsFor($dirType);
		next unless @dirs > 1 && -d $dirs[0];

		my $added = _backupDirToZip($dirs[0], "extrafiles/\L$dirType");
		main::INFOLOG && $log->is_info && $log->info("Backed up $added file(s) from $dirType folder: $dirs[0]") if $added;
	}
}

sub _backupCustomPaths {
	my $customPaths = $prefs->get('extrabackuppaths') || [];
	my @manifestLines;

	my $idx = 0;
	for my $entry (@{$customPaths}) {
		my $source = $entry->{'source'};
		next unless $source && -d $source;

		if (_isForbiddenCustomPath($source)) {
			$log->error("Refusing to back up custom path (overlaps with a protected system folder): $source");
			next;
		}

		my $target = $entry->{'target'} || $source;
		my (undef, undef, $folderBaseName) = splitpath($source);
		$folderBaseName ||= 'data';
		my $added = _backupDirToZip($source, "custompaths/$idx/$folderBaseName");
		if ($added) {
			push @manifestLines, "$idx\t$source\t$target";
			main::INFOLOG && $log->is_info && $log->info("Backed up $added file(s) from custom path: $source (target: $target)");
		}
		$idx++;
	}

	if (@manifestLines) {
		$bkpZip->addString(join("\n", @manifestLines)."\n", 'custompaths/manifest.txt');
	}
}

sub _isForbiddenCustomPath {
	my $path = shift;
	return 1 unless $path;

	my @forbidden;
	push @forbidden, Slim::Utils::Prefs::dir();
	push @forbidden, Slim::Utils::OSDetect::dirsFor('cache');
	push @forbidden, Slim::Utils::OSDetect::dirsFor('Plugins');
	push @forbidden, @{$serverPrefs->get('mediadirs') || []};

	my $normalizedPath = File::Spec->canonpath($path);
	for my $forbiddenPath (@forbidden) {
		next unless $forbiddenPath;
		my $normalizedForbidden = File::Spec->canonpath($forbiddenPath);
		return 1 if $normalizedPath eq $normalizedForbidden;
		return 1 if index($normalizedPath, "$normalizedForbidden/") == 0 || index($normalizedPath, "$normalizedForbidden\\") == 0;
		return 1 if index($normalizedForbidden, "$normalizedPath/") == 0 || index($normalizedForbidden, "$normalizedPath\\") == 0;
	}
	return 0;
}

sub _backupOurPluginDataFolders {
	for my $entry (@OUR_PLUGIN_DATA_FOLDERS) {
		my $folderPath = eval { preferences($entry->{'namespace'})->get($entry->{'pathkey'}) };
		if ($@) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Could not read $entry->{'pathkey'} from $entry->{'namespace'} - plugin probably not installed: $@");
			next;
		}
		next unless $folderPath && -d $folderPath;

		my ($shortName) = $entry->{'namespace'} =~ /^plugin\.(.+)$/;
		my (undef, undef, $folderBaseName) = splitpath(File::Spec->canonpath($folderPath));
		$folderBaseName ||= 'data';
		my $added = _backupDirToZip($folderPath, "ourplugindata/$shortName/$folderBaseName");
		main::INFOLOG && $log->is_info && $log->info("Backed up $added file(s) from $entry->{'namespace'} data folder: $folderPath") if $added;
	}
}

sub _backupInstalledPluginsFolder {
	return unless $prefs->get('backupinstalledplugins');

	my $installedPluginsDir = catdir(Slim::Utils::OSDetect::dirsFor('cache'), 'InstalledPlugins', 'Plugins');
	return unless -d $installedPluginsDir;

	my @manifestLines;
	opendir(my $dh, $installedPluginsDir) or return;
	for my $folderName (readdir($dh)) {
		next if $folderName eq '.' || $folderName eq '..';
		my $pluginDir = catdir($installedPluginsDir, $folderName);
		next unless -d $pluginDir;

		my ($canonicalName, $version, $minLMSVersion) = _parseInstalledPluginManifest(catfile($pluginDir, 'install.xml'));
		push @manifestLines, join("\t", $folderName, ($canonicalName || ''), ($version || ''), ($minLMSVersion || ''));
	}
	closedir($dh);

	my $added = _backupDirToZip($installedPluginsDir, 'installedplugins');
	if ($added && @manifestLines) {
		$bkpZip->addString(join("\n", @manifestLines)."\n", 'installedplugins/manifest.txt');
	}
	main::INFOLOG && $log->is_info && $log->info("Backed up $added file(s) from InstalledPlugins folder: $installedPluginsDir") if $added;
}

sub _parseInstalledPluginManifest {
	my $installXmlFile = shift;
	return (undef, undef, undef) unless -f $installXmlFile;

	my $manifest = eval { XMLin($installXmlFile, SuppressEmpty => undef) };
	if ($@ || ref $manifest ne 'HASH') {
		$log->error("Could not parse $installXmlFile: " . ($@ || 'invalid data'));
		return (undef, undef, undef);
	}

	my $canonicalName;
	if ($manifest->{'module'} && $manifest->{'module'} =~ /^Plugins::(.*)::/) {
		$canonicalName = $1;
	} elsif ($manifest->{'module'} && $manifest->{'module'} =~ /^Slim::Plugin::(.*)::/) {
		$canonicalName = $1;
	}

	my $minLMSVersion = (ref $manifest->{'targetApplication'} eq 'HASH') ? $manifest->{'targetApplication'}->{'minVersion'} : undef;

	return ($canonicalName, $manifest->{'version'}, $minLMSVersion);
}

sub _initTracksPersistentBackup {
	my $dbh = Slim::Schema->dbh;
	my ($trackURL, $trackURLmd5, $added, $playCount, $lastPlayed, $remote, $trackMBID);

	@bkpPersistentTracks = ();
	my $sth = $dbh->prepare("select tracks_persistent.url, tracks_persistent.urlmd5, tracks_persistent.added, tracks_persistent.playCount, tracks_persistent.lastPlayed, tracks.remote, tracks_persistent.musicbrainz_id from tracks_persistent left join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where tracks_persistent.added is not null or tracks_persistent.playCount is not null or tracks_persistent.lastPlayed is not null");
	eval {
		$sth->execute();
		$sth->bind_columns(undef, \$trackURL, \$trackURLmd5, \$added, \$playCount, \$lastPlayed, \$remote, \$trackMBID);
		while ($sth->fetch()) {
			push (@bkpPersistentTracks, {'url' => $trackURL, 'urlmd5' => $trackURLmd5, 'added' => $added, 'playcount' => $playCount, 'lastplayed' => $lastPlayed, 'remote' => $remote, 'musicbrainzid' => $trackMBID});
		}
	};
	if ($@) {
		$log->error("Database error while reading tracks_persistent for backup: $@");
		$bkpErrors++;
		_finishBackup(0);
		return;
	}
	$sth->finish();
	main::DEBUGLOG && $log->is_debug && $log->debug('total backup time passed after getting eligible tracks_persisten tracks = '.(time()-$bkpStarted));

	$bkpTotalTrackCount = scalar(@bkpPersistentTracks);
	$bkpProcessedTrackCount = 0;

	unless ($bkpTotalTrackCount) {
		main::INFOLOG && $log->is_info && $log->info('No added/playCount/lastPlayed values found in tracks_persistent - nothing to back up');
		_finishBackup(0);
		return;
	}

	my $filename = catfile($bkpTempDir, 'trackspersistent_selectivestats.xml');
	$bkpOutput = FileHandle->new($filename, '>:utf8') or do {
		$log->error("Could not open $filename for writing");
		$bkpErrors++;
		_finishBackup(0);
		return;
	};

	my $osDetails = Slim::Utils::OSDetect::details();
	my $backupCodepage = getBackupCodepage();
	print $bkpOutput "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
	print $bkpOutput "<!-- MigrationAssistant backup of selected tracks_persistent values for ".$bkpTotalTrackCount.($bkpTotalTrackCount == 1 ? " track" : " tracks")." -->\n";
	print $bkpOutput "<!-- Created on OS: ".($osDetails->{'osName'} || $^O)."; OS family: ".($osDetails->{'os'} || 'unknown')." -->\n";
	print $bkpOutput "<!-- OS-Arch: ".($osDetails->{'osArch'} || 'unknown')."; Perl-Arch: ".($osDetails->{'binArch'} || 'unknown')."; FS: ".($osDetails->{'fsType'} || 'unknown')."; Perl $] -->\n";
	print $bkpOutput "<TracksPersistentSelectiveStats>\n";
	print $bkpOutput "\t<backupos>".($osDetails->{'os'} || $^O)."</backupos>\n";
	print $bkpOutput "\t<backupcodepage>".($backupCodepage || '')."</backupcodepage>\n";
	print $bkpOutput "\t<trackcount>".$bkpTotalTrackCount."</trackcount>\n";

	main::INFOLOG && $log->is_info && $log->info('Starting tracks_persistent backup export for '.$bkpTotalTrackCount.' tracks');
	Slim::Utils::Scheduler::add_task(\&_bkpScanFunction);
}

sub _bkpScanFunction {
	for (my $i = 0; $i < 500 && @bkpPersistentTracks; $i++) {
		my $persistentTrack = shift(@bkpPersistentTracks);
		my $remoteFlag = defined($persistentTrack->{'remote'}) ? $persistentTrack->{'remote'} : 0;
		my $relFilePath = ($remoteFlag == 0) ? getRelFilePath($persistentTrack->{'url'}) : '';

		eval {
			print $bkpOutput "\t<track>\n";
			print $bkpOutput "\t\t<url>".escape($persistentTrack->{'url'})."</url>\n";
			print $bkpOutput "\t\t<urlmd5>".$persistentTrack->{'urlmd5'}."</urlmd5>\n";
			print $bkpOutput "\t\t<relurl>".($relFilePath ? escape($relFilePath) : '')."</relurl>\n";
			print $bkpOutput "\t\t<remote>".$remoteFlag."</remote>\n";
			print $bkpOutput "\t\t<added>".(defined($persistentTrack->{'added'}) ? $persistentTrack->{'added'} : '')."</added>\n";
			print $bkpOutput "\t\t<playcount>".(defined($persistentTrack->{'playcount'}) ? $persistentTrack->{'playcount'} : '')."</playcount>\n";
			print $bkpOutput "\t\t<lastplayed>".(defined($persistentTrack->{'lastplayed'}) ? $persistentTrack->{'lastplayed'} : '')."</lastplayed>\n";
			print $bkpOutput "\t\t<musicbrainzid>".($persistentTrack->{'musicbrainzid'} || '')."</musicbrainzid>\n";
			print $bkpOutput "\t</track>\n";
		};
		if ($@) {
			$log->error("Error writing track to backup file: $@");
			$bkpErrors++;
		}

		$bkpProcessedTrackCount++;
	}

	if ($bkpTotalTrackCount) {
		$prefs->set('backuprestoreprogresspercentage', sprintf("%.0f", ($bkpProcessedTrackCount / $bkpTotalTrackCount) * 100));
	}

	return 1 if @bkpPersistentTracks;

	print $bkpOutput "</TracksPersistentSelectiveStats>\n";
	close $bkpOutput;
	$bkpOutput = undef;

	_finishBackup(1);
	return 0;
}

sub _finishBackup {
	my $addTracksPersistentFile = shift;

	if ($addTracksPersistentFile) {
		unless ($bkpZip->addFile(catfile($bkpTempDir, 'trackspersistent_selectivestats.xml'), 'trackspersistent_selectivestats.xml')) {
			$log->error("Could not add tracks_persistent backup data to backup archive - skipping it");
			$bkpErrors++;
		}
	}

	if ($bkpZip->writeToFileNamed($bkpFile) != AZ_OK) {
		$log->error("Could not write backup archive to $bkpFile");
		$bkpErrors++;
	} else {
		main::INFOLOG && $log->is_info && $log->info('Backup archive created: '.$bkpFile.' after '.(time() - $bkpStarted).' seconds');
	}

	$prefs->set('backuprestoreresult', $bkpErrors > 0 ? 2 : 1);
	$prefs->set('backuprestoreprogresspercentage', 100);

	$bkpZip = undef;
	$bkpOutput = undef;
	@bkpPersistentTracks = ();

	$prefs->set('status_backuprestore', 0);
}


## Restore

sub listBackupContents {
	my $zipFile = shift;
	return [] unless $zipFile && -f $zipFile;

	my $zip = Archive::Zip->new();
	if ($zip->read($zipFile) != AZ_OK) {
		$log->error("Could not read backup archive $zipFile");
		return [];
	}

	my @contents;
	my (%hasPlaylistBucket, %hasExtraSystem, %customPathIndices, %ourPluginShortNames, %installedPluginFolderNames, $customPathManifest, $installedPluginManifest, $hasOpml, $hasLogConf);

	for my $member ($zip->members) {
		my $fileName = $member->fileName;
		next if _isJunkZipEntry($fileName);
		next if $fileName =~ m{(?:^|/)migrationassistant\.prefs$}i;

		if ($fileName eq 'custompaths/manifest.txt') {
			$customPathManifest = $member->contents;
			next;
		}
		if ($fileName =~ m{^playlists/(.+)$}) {
			my ($ext) = $1 =~ /\.([^.\/]+)$/;
			$ext = lc($ext || '');
			my $bucket = ($ext =~ /^(?:m3u|m3u8|pls|cue)$/) ? 'media' : ($ext eq 'txt' ? 'text' : 'other');
			$hasPlaylistBucket{$bucket} = 1;
			next;
		}
		if ($fileName =~ m{^opmlfiles/}) {
			$hasOpml = 1;
			next;
		}
		if ($fileName eq 'log.conf') {
			$hasLogConf = 1;
			next;
		}
		if ($fileName =~ m{^extrafiles/(graphics|html|ir)/}) {
			$hasExtraSystem{$1} = 1;
			next;
		}
		if ($fileName =~ m{^custompaths/(\d+)/}) {
			$customPathIndices{$1} = 1;
			next;
		}
		if ($fileName =~ m{^ourplugindata/([^/]+)/}) {
			$ourPluginShortNames{$1} = 1;
			next;
		}
		if ($fileName eq 'installedplugins/manifest.txt') {
			$installedPluginManifest = $member->contents;
			next;
		}
		if ($fileName =~ m{^installedplugins/([^/]+)/}) {
			$installedPluginFolderNames{$1} = 1;
			next;
		}

		my @parts = split(m{/}, $fileName);
		my $baseName = $parts[-1];

		if ($baseName eq 'trackspersistent_selectivestats.xml') {
			push @contents, { namespace => 'dateadded', category => 'trackstats', label => string('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE_DATEADDED_LABEL'), checked => 1, filename => $fileName };
			push @contents, { namespace => 'playcountlastplayed', category => 'trackstats', label => string('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE_PLAYCOUNTLASTPLAYED_LABEL'), checked => 1, filename => $fileName };
			next;
		}

		my $namespace = _prefsNamespaceForZipEntry($fileName);
		next unless defined $namespace;

		if ($namespace =~ /^plugin\.(.+)$/) {
			my $shortName = $1;
			if ($shortName eq 'state' || $shortName eq 'extensions') {
				push @contents, { namespace => $namespace, category => 'server', label => $namespace, checked => 1, filename => $fileName };
			} else {
				my $displayName = _pluginDisplayNameForNamespace($namespace);
				if (defined $displayName) {
					push @contents, { namespace => $namespace, category => (_isFirstPartyPlugin($shortName) ? 'plugin_core' : 'plugin_thirdparty'), label => $displayName, checked => 1, filename => $fileName };
				} else {
					push @contents, { namespace => $namespace, category => 'plugin_notinstalled', label => $shortName, checked => 0, filename => $fileName };
				}
			}
		} else {
			push @contents, { namespace => $namespace, category => 'server', label => $namespace, checked => 1, filename => $fileName };
		}
	}

	my ($playlistDirWritable, $playlistDirExists) = _isTargetWritable($serverPrefs->get('playlistdir'));
	if ($hasPlaylistBucket{'media'}) {
		push @contents, { namespace => 'playlists_media', category => 'playlistfolder', label => string('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE_PLAYLISTS_MEDIA_LABEL'), checked => 1, writable => $playlistDirWritable, pathExists => $playlistDirExists };
	}
	if ($hasPlaylistBucket{'text'}) {
		push @contents, { namespace => 'playlists_text', category => 'playlistfolder', label => string('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE_PLAYLISTS_TEXT_LABEL'), checked => 1, writable => $playlistDirWritable, pathExists => $playlistDirExists };
	}
	if ($hasPlaylistBucket{'other'}) {
		push @contents, { namespace => 'playlists_other', category => 'playlistfolder', label => string('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE_PLAYLISTS_OTHER_LABEL'), checked => 1, writable => $playlistDirWritable, pathExists => $playlistDirExists };
	}
	if ($hasOpml) {
		push @contents, { namespace => 'opmlfiles', category => 'server', label => string('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE_OPMLFILES_LABEL'), checked => 1 };
	}
	if ($hasLogConf) {
		push @contents, { namespace => 'logconf', category => 'server', label => string('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE_LOGCONF_LABEL'), checked => 1 };
	}
	my %extraSystemDirTypeNames = (graphics => 'Graphics', html => 'HTML', ir => 'IR');
	for my $dirType (qw(graphics html ir)) {
		next unless $hasExtraSystem{$dirType};
		my ($targetDir) = Slim::Utils::OSDetect::dirsFor($extraSystemDirTypeNames{$dirType});
		my ($extraDirWritable, $extraDirExists) = _isTargetWritable($targetDir);
		push @contents, { namespace => "extrafiles_$dirType", category => 'server', label => string('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE_EXTRAFILES_'.uc($dirType).'_LABEL'), checked => 1, writable => $extraDirWritable, pathExists => $extraDirExists };
	}

	my %customPathInfo;
	if ($customPathManifest) {
		for my $line (split(/\n/, $customPathManifest)) {
			my ($idx, $source, $target) = split(/\t/, $line);
			next unless defined $idx;
			$customPathInfo{$idx} = { source => $source, target => $target };
		}
	}
	for my $idx (sort { $a <=> $b } keys %customPathIndices) {
		my $label = $customPathInfo{$idx} ? $customPathInfo{$idx}{'source'} : "custom path $idx";
		my $target = $customPathInfo{$idx} ? ($customPathInfo{$idx}{'target'} || $customPathInfo{$idx}{'source'}) : undef;
		my ($customPathWritable, $customPathExists) = _isTargetWritable($target);
		push @contents, { namespace => "custompath_$idx", category => 'custompaths', label => $label, checked => 1, writable => $customPathWritable, pathExists => $customPathExists };
	}

	for my $shortName (sort keys %ourPluginShortNames) {
		my $displayName = _pluginDisplayNameForNamespace("plugin.$shortName") || $shortName;
		push @contents, { namespace => "ourplugindata_$shortName", category => 'ourplugindata', label => $displayName, checked => 1 };
	}

	my %installedPluginInfo;
	if ($installedPluginManifest) {
		for my $line (split(/\n/, $installedPluginManifest)) {
			my ($folderName, $canonicalName, $version, $minLMSVersion) = split(/\t/, $line);
			next unless defined $folderName;
			$installedPluginInfo{$folderName} = { canonicalname => $canonicalName, version => $version, minlmsversion => $minLMSVersion };
		}
	}
	for my $folderName (sort keys %installedPluginFolderNames) {
		my $info = $installedPluginInfo{$folderName} || {};
		my $canonicalName = $info->{'canonicalname'} || $folderName;
		my $displayName = _pluginDisplayNameForNamespace("plugin.$canonicalName") || $folderName;
		my $alreadyInstalled = -d catdir(Slim::Utils::OSDetect::dirsFor('cache'), 'InstalledPlugins', 'Plugins', $folderName) ? 1 : 0;
		push @contents, { namespace => "installedplugin_$folderName", category => 'installedplugins', label => $displayName, checked => 0, alreadyinstalled => $alreadyInstalled, canonicalname => $canonicalName };
	}

	@contents = sort { $a->{'label'} cmp $b->{'label'} } @contents;
	my $idx = 0;
	for my $item (@contents) {
		$item->{'idx'} = $idx++;
	}

	return \@contents;
}

sub _extractMemberContent {
	my $member = shift;
	my $content = eval { $member->contents };
	$log->error("Could not extract ".$member->fileName." from backup archive: ".($@ || 'unknown error')) unless defined $content;
	return $content;
}

sub _isJunkZipEntry {
	my $fileName = shift;
	return 1 if $fileName =~ m{(?:^|/)__MACOSX/};
	return 1 if $fileName =~ m{/$};
	my @parts = split(m{/}, $fileName);
	my $baseName = $parts[-1];
	return 1 if !defined($baseName) || $baseName eq '';
	return 1 if $baseName =~ /^\._/ || $baseName =~ /^(?:\.DS_Store|Thumbs\.db|desktop\.ini)$/i;
	return 1 if $baseName =~ /\.bak-\d{14}(?:\.bak-\d{14})*$/;
	return 0;
}

sub _prefsNamespaceForZipEntry {
	my $fileName = shift;
	my @parts = split(m{/}, $fileName);
	my $baseName = $parts[-1];
	return undef unless defined($baseName) && $baseName =~ /^(.+)\.prefs$/i;
	my $prefsName = $1;
	return (@parts >= 2 && $parts[-2] eq 'plugin') ? "plugin.$prefsName" : $prefsName;
}

sub _findPluginManifestEntryExact {
	my $shortName = shift;
	my $normalizedTarget = lc($shortName);
	$normalizedTarget =~ s/[^a-z0-9]//g;

	my $plugins = Slim::Utils::PluginManager->allPlugins();
	for my $pluginKey (keys %{$plugins}) {
		my $normalizedKey = lc($pluginKey);
		$normalizedKey =~ s/[^a-z0-9]//g;
		return $plugins->{$pluginKey} if $normalizedKey eq $normalizedTarget;
	}
	return undef;
}

sub _pluginDisplayNameForNamespace {
	my $namespace = shift;
	return undef unless $namespace =~ /^plugin\.(.+)$/;
	my $shortName = $1;

	my $manifestEntry = _findPluginManifestEntryExact($shortName);
	if ($manifestEntry && $manifestEntry->{'name'} && Slim::Utils::Strings::stringExists($manifestEntry->{'name'})) {
		return Slim::Utils::Strings::string($manifestEntry->{'name'});
	}

	# fallback: manifest lookup itself failed to match - try guessing common token naming conventions
	my @candidates = (uc($shortName));
	(my $underscored = $shortName) =~ s/-/_/g;
	push @candidates, uc($underscored) unless $underscored eq $shortName;
	(my $stripped = $shortName) =~ s/-//g;
	push @candidates, uc($stripped) unless $stripped eq $shortName;

	for my $suffix (@candidates) {
		my $token = 'PLUGIN_'.$suffix;
		return Slim::Utils::Strings::string($token) if Slim::Utils::Strings::stringExists($token);
	}
	return undef;
}

sub _isFirstPartyPlugin {
	my $shortName = shift;
	my $manifestEntry = _findPluginManifestEntryExact($shortName);
	return 0 unless $manifestEntry;
	my $module = $manifestEntry->{'module'};
	return ($module && $module =~ /^Slim::Plugin::/) ? 1 : 0;
}


sub restoreFromBackup {
	my $selectedNamespaces = shift;

	unless ($selectedNamespaces && %{$selectedNamespaces}) {
		main::DEBUGLOG && $log->is_debug && $log->debug('restoreFromBackup called with no namespaces selected - nothing to do');
		return (0, 0);
	}

	if ($prefs->get('status_backuprestore')) {
		$log->error('A backup or restore is already in progress, please wait for it to finish');
		return (0, 0);
	}
	if (Slim::Music::Import->stillScanning) {
		$log->error('Cannot restore from backup while a library scan is in progress');
		return (0, 0);
	}

	my $restoreFile = $prefs->get('restorefile');
	return (0, 0) unless $restoreFile && -f $restoreFile;

	my $zip = Archive::Zip->new();
	if ($zip->read($restoreFile) != AZ_OK) {
		$log->error("Could not read backup archive $restoreFile");
		return (0, 0);
	}

	$prefs->set('status_backuprestore', 2);
	$prefs->set('restoreNeedsReload', 0);

	my $skipPrefs = _parseRestoreSkipPrefs($prefs->get('restoreskipprefs'));
	my %restoredOurPluginFolders;
	my %restoredInstalledPluginFolders;
	my $defaultSkipPrefs = _defaultSkipPrefsHash();
	my $tempDir = tempdir(CLEANUP => 1);

	# prefs dir
	my $prefsDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
	my $pluginPrefsDir = catdir($prefsDir, 'plugin');
	my ($prefsDirWritable, $prefsDirExists) = _isTargetWritable($prefsDir);
	unless ($prefsDirWritable) {
		$log->error("Cannot restore - preferences folder $prefsDir ".($prefsDirExists ? 'is not writable' : 'does not exist')." on this system, aborting restore");
		$prefs->set('status_backuprestore', 0);
		return (0, 0);
	}

	# custom paths
	my %customPathTargets;
	for my $manifestMember ($zip->members) {
		if ($manifestMember->fileName eq 'custompaths/manifest.txt') {
			for my $line (split(/\n/, $manifestMember->contents)) {
				my ($idx, $source, $target) = split(/\t/, $line);
				next unless defined $idx;
				$customPathTargets{$idx} = $target || $source;
			}
			last;
		}
	}
	for my $pathIdx (keys %customPathTargets) {
		next unless $selectedNamespaces->{"custompath_$pathIdx"};
		my ($pathWritable, $pathExists) = _isTargetWritable($customPathTargets{$pathIdx});
		unless ($pathWritable) {
			$log->error("Cannot restore custom path $customPathTargets{$pathIdx} - target folder ".($pathExists ? 'is not writable' : 'does not exist')." on this system, skipping this category");
			delete $customPathTargets{$pathIdx};
		}
	}

	# installed (extension-manager) plugin folders
	my %installedPluginCanonicalNames;
	for my $manifestMember ($zip->members) {
		if ($manifestMember->fileName eq 'installedplugins/manifest.txt') {
			for my $line (split(/\n/, $manifestMember->contents)) {
				my ($folderName, $canonicalName) = split(/\t/, $line);
				next unless defined $folderName;
				$installedPluginCanonicalNames{$folderName} = $canonicalName || $folderName;
			}
			last;
		}
	}

	# skip installed-plugin folders that already exist on this system
	# never silently overwrite an already-installed plugin
	my %skipExistingInstalledPluginFolders;
	for my $member ($zip->members) {
		next if _isJunkZipEntry($member->fileName);
		next unless $member->fileName =~ m{^installedplugins/([^/]+)/};
		my $folderName = $1;
		next if exists $skipExistingInstalledPluginFolders{$folderName};
		my $targetDir = catdir(Slim::Utils::OSDetect::dirsFor('cache'), 'InstalledPlugins', 'Plugins', $folderName);
		if (-d $targetDir) {
			$skipExistingInstalledPluginFolders{$folderName} = 1;
			main::INFOLOG && $log->is_info && $log->info("Skipping restore of installed-plugin folder '$folderName' - already present on this system, not overwriting");
		}
	}

	# playlist dir
	my $playlistDir = $serverPrefs->get('playlistdir');
	if ($playlistDir && grep { $selectedNamespaces->{$_} } qw(playlists_media playlists_text playlists_other)) {
		my ($playlistDirWritable, $playlistDirExists) = _isTargetWritable($playlistDir);
		unless ($playlistDirWritable) {
			$log->error("Cannot restore playlist folder contents - target folder $playlistDir ".($playlistDirExists ? 'is not writable' : 'does not exist')." on this system, skipping this category");
			undef $playlistDir;
		}
	}

	# extra system dirs
	my %extraSystemDirs;
	for my $dirType (qw(Graphics HTML IR)) {
		my ($dir) = Slim::Utils::OSDetect::dirsFor($dirType);
		next unless $dir && -d $dir;
		if ($selectedNamespaces->{'extrafiles_'.lc($dirType)}) {
			my ($dirWritable, $dirExists) = _isTargetWritable($dir);
			unless ($dirWritable) {
				$log->error("Cannot restore $dirType files - target folder $dir ".($dirExists ? 'is not writable' : 'does not exist')." on this system, skipping this category");
				next;
			}
		}
		$extraSystemDirs{lc($dirType)} = $dir;
	}

	# lock namespaces to be restored against concurrent live writes (readonly) as early as possible before doing any of the (slower) actual merge work below. Should minimize risk of LMS clobbering our changes
	my %namespacesToRestore;
	for my $member ($zip->members) {
		my $fileName = $member->fileName;
		next if _isJunkZipEntry($fileName);
		my $ns = _prefsNamespaceForZipEntry($fileName);
		next unless defined $ns;
		next if $selectedNamespaces && !$selectedNamespaces->{$ns};
		$namespacesToRestore{$ns} = 1;
	}
	for my $ns (keys %namespacesToRestore) {
		next if $ns eq 'plugin.migrationassistant';
		my $namespacePrefs = preferences($ns);
		eval { $namespacePrefs->{'readonly'} = 1 };
		$log->error("Could not set namespace $ns readonly during restore: $@") if $@;
		eval { $namespacePrefs->savenow };
		$log->error("Could not lock namespace $ns during restore (savenow failed): $@") if $@;
	}

	my $serverNamespaceRestored = 0;
	my $anyNamespaceRestored = 0;

	for my $member ($zip->members) {
		my $fileName = $member->fileName;
		next if _isJunkZipEntry($fileName);

		next if $fileName eq 'custompaths/manifest.txt';

		if ($fileName =~ m{^playlists/(.+)$}) {
			my $relPath = $1;
			my ($ext) = $relPath =~ /\.([^.\/]+)$/;
			$ext = lc($ext || '');
			my $bucket = ($ext =~ /^(?:m3u|m3u8|pls|cue)$/) ? 'media' : ($ext eq 'txt' ? 'text' : 'other');
			if ($selectedNamespaces->{"playlists_$bucket"} && $playlistDir) {
				my $content = _extractMemberContent($member);
				_safeWriteFile(catfile($playlistDir, split(m{/}, $relPath)), $content) if defined $content;
			}
			next;
		}
		if ($fileName =~ m{^opmlfiles/(.+)$}) {
			if ($selectedNamespaces->{'opmlfiles'}) {
				my $content = _extractMemberContent($member);
				_safeWriteFile(catfile($prefsDir, $1), $content) if defined $content;
			}
			next;
		}
		if ($fileName eq 'log.conf') {
			if ($selectedNamespaces->{'logconf'}) {
				my $content = _extractMemberContent($member);
				_safeWriteFile(catfile($prefsDir, 'log.conf'), $content) if defined $content;
			}
			next;
		}
		if ($fileName =~ m{^extrafiles/(graphics|html|ir)/(.+)$}) {
			my ($dirType, $relPath) = ($1, $2);
			if ($selectedNamespaces->{"extrafiles_$dirType"} && $extraSystemDirs{$dirType}) {
				my $content = _extractMemberContent($member);
				_safeWriteFile(catfile($extraSystemDirs{$dirType}, split(m{/}, $relPath)), $content) if defined $content;
			}
			next;
		}
		if ($fileName =~ m{^custompaths/(\d+)/(.+)$}) {
			my ($pathIdx, $relPath) = ($1, $2);
			if ($selectedNamespaces->{"custompath_$pathIdx"} && $customPathTargets{$pathIdx}) {
				my $content = _extractMemberContent($member);
				_safeWriteFile(catfile($customPathTargets{$pathIdx}, split(m{/}, $relPath)), $content) if defined $content;
			}
			next;
		}
		if ($fileName =~ m{^ourplugindata/([^/]+)/([^/]+)/(.+)$}) {
			my ($shortName, $folderBaseName, $relPath) = ($1, $2, $3);
			if ($selectedNamespaces->{"ourplugindata_$shortName"}) {
				my $targetDir = catdir($prefsDir, $folderBaseName);
				my $content = _extractMemberContent($member);
				if (defined $content && _safeWriteFile(catfile($targetDir, split(m{/}, $relPath)), $content)) {
					$restoredOurPluginFolders{$shortName} = $targetDir;
				}
			}
			next;
		}
		if ($fileName eq 'installedplugins/manifest.txt') {
			next;
		}
		if ($fileName =~ m{^installedplugins/([^/]+)/(.+)$}) {
			my ($folderName, $relPath) = ($1, $2);
			if ($selectedNamespaces->{"installedplugin_$folderName"} && !$skipExistingInstalledPluginFolders{$folderName}) {
				my $targetDir = catdir(Slim::Utils::OSDetect::dirsFor('cache'), 'InstalledPlugins', 'Plugins', $folderName);
				my $content = _extractMemberContent($member);
				if (defined $content && _safeWriteFile(catfile($targetDir, split(m{/}, $relPath)), $content)) {
					$restoredInstalledPluginFolders{$folderName} = 1;
				}
			}
			next;
		}

		my $namespace = _prefsNamespaceForZipEntry($fileName);
		next unless defined $namespace;
		next if $namespace eq 'plugin.migrationassistant';
		next if $selectedNamespaces && !$selectedNamespaces->{$namespace};

		my $tempFile = catfile($tempDir, 'restore.prefs');
		if ($member->extractToFileNamed($tempFile) != AZ_OK) {
			$log->error("Could not extract $fileName from backup archive");
			next;
		}

		my $backupData = eval { LoadFile($tempFile) };
		unlink $tempFile;

		if ($@ || ref $backupData ne 'HASH') {
			$log->error("Could not parse $fileName from backup archive: " . ($@ || 'invalid data'));
			next;
		}

		if (_mergePrefsFile($namespace, $backupData, $prefsDir, $pluginPrefsDir, $skipPrefs, $defaultSkipPrefs)) {
			$anyNamespaceRestored = 1;
			$serverNamespaceRestored = 1 if $namespace eq 'server';
		}
	}

	for my $shortName (keys %restoredOurPluginFolders) {
		my ($entry) = grep { $_->{'namespace'} eq "plugin.$shortName" } @OUR_PLUGIN_DATA_FOLDERS;
		next unless $entry;
		$anyNamespaceRestored = 1 if _mergePrefsFile("plugin.$shortName", { $entry->{'pathkey'} => $restoredOurPluginFolders{$shortName} }, $prefsDir, $pluginPrefsDir, {}, {});
	}

	if (%restoredInstalledPluginFolders) {
		my @pendingCanonicalNames = map { $installedPluginCanonicalNames{$_} || $_ } sort keys %restoredInstalledPluginFolders;
		$prefs->set('restorependinginstalledplugins', \@pendingCanonicalNames);
		main::INFOLOG && $log->is_info && $log->info('Restored installed-plugin folder(s), queued for extension manager enablement after next restart: '.join(', ', @pendingCanonicalNames));
	}

	if ($serverNamespaceRestored) {
		$prefs->set('restorependingrescan', 1);
	}

	my $restoreDateAdded = $selectedNamespaces && $selectedNamespaces->{'dateadded'} ? 1 : 0;
	my $restorePlayCountLastPlayed = $selectedNamespaces && $selectedNamespaces->{'playcountlastplayed'} ? 1 : 0;

	if ($restoreDateAdded || $restorePlayCountLastPlayed) {
		my $xmlMember;
		for my $member ($zip->members) {
			my $fileName = $member->fileName;
			next if _isJunkZipEntry($fileName);
			my @parts = split(m{/}, $fileName);
			if ($parts[-1] eq 'trackspersistent_selectivestats.xml') {
				$xmlMember = $member;
				last;
			}
		}
		if ($xmlMember) {
			my $xmlTempFile = catfile($tempDir, 'trackspersistent_selectivestats.xml');
			if ($xmlMember->extractToFileNamed($xmlTempFile) == AZ_OK) {
				$prefs->set('restoreNeedsReload', 1);
				_initTracksPersistentRestore($xmlTempFile, $restoreDateAdded, $restorePlayCountLastPlayed);
			} else {
				$log->error("Could not extract trackspersistent_selectivestats.xml from backup archive");
				_finishRestore(2);
			}
		} else {
			$log->error("Selected trackspersistent restore, but trackspersistent_selectivestats.xml is missing from the backup archive");
			_finishRestore(2);
		}
	} else {
		_finishRestore($prefs->get('restorependingrescan') ? 3 : 1);
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('restoreDateAdded='.$restoreDateAdded.' ## restorePlayCountLastPlayed='.$restorePlayCountLastPlayed.' ## status_backuprestore='.$prefs->get('status_backuprestore'));
	return (1, $prefs->get('restorependingrescan'), $anyNamespaceRestored);
}

sub _defaultSkipPrefsHash {
	my %skip;
	for my $entry (@DEFAULT_RESTORE_SKIP_PREFS) {
		my ($namespace, $key) = split(/:/, $entry, 2);
		next unless defined $key;
		$skip{$namespace}{$key} = 1;
	}
	return \%skip;
}

sub _isSkippedPref {
	my ($namespace, $key, $userSkipPrefs, $defaultSkipPrefs) = @_;
	return 1 if $defaultSkipPrefs->{$namespace}{$key};
	return 1 if $userSkipPrefs->{$namespace}{$key};
	return 0;
}

sub _prefsFilePathForNamespace {
	my ($namespace, $prefsDir, $pluginPrefsDir) = @_;
	if ($namespace =~ /^plugin\.(.+)$/) {
		return catfile($pluginPrefsDir, "$1.prefs");
	}
	return catfile($prefsDir, "$namespace.prefs");
}

sub _mergePrefsFile {
	my ($namespace, $backupData, $prefsDir, $pluginPrefsDir, $skipPrefs, $defaultSkipPrefs) = @_;

	my $targetFile = _prefsFilePathForNamespace($namespace, $prefsDir, $pluginPrefsDir);

	my $currentData = {};
	if (-f $targetFile) {
		$currentData = eval { LoadFile($targetFile) };
		if ($@ || ref $currentData ne 'HASH') {
			$log->error("Could not parse current $targetFile - skipping merge for namespace $namespace: " . ($@ || 'invalid data'));
			return 0;
		}
	}

	my $changed = 0;
	for my $key (keys %{$backupData}) {
		next if $key =~ /^_ts_/;
		next if _isSkippedPref($namespace, $key, $skipPrefs, $defaultSkipPrefs);

		$currentData->{$key} = $backupData->{$key};
		$changed = 1;

		my $tsKey = '_ts_'.$key;
		if (exists $backupData->{$tsKey}) {
			$currentData->{$tsKey} = $backupData->{$tsKey};
		}
	}

	return 0 unless $changed;

	unless (_safeWriteFile($targetFile, YAML::XS::Dump($currentData))) {
		$log->error("Could not write merged prefs file $targetFile for namespace $namespace");
		return 0;
	}

	main::INFOLOG && $log->is_info && $log->info("Restored preferences for namespace $namespace from backup (file merge)");
	return 1;
}

sub _parseRestoreSkipPrefs {
	my $raw = shift;
	my %skip;
	return \%skip unless $raw;

	for my $entry (split(/,/, $raw)) {
		$entry =~ s/^\s+|\s+$//g;
		next unless $entry;

		my ($namespace, $key) = split(/:/, $entry, 2);
		if (!defined($key) || $namespace eq '' || $key eq '') {
			$log->warn("Ignoring invalid restore skip entry '$entry' - expected format is 'namespace:prefname'");
			next;
		}

		$skip{$namespace}{$key} = 1;
	}

	return \%skip;
}

sub _requeuePendingRescanAfterRestart {
	return unless $prefs->get('restorependingrescan');

	$prefs->set('restorependingrescan', 0);
	my $request = Slim::Control::Request->new(undef, ['wipecache']);
	Slim::Music::Import->queueScanTask($request);
	main::INFOLOG && $log->is_info && $log->info('Re-queued rescan request after restart, following a preferences restore');
}

sub _enablePendingInstalledPlugins {
	my $pendingPlugins = $prefs->get('restorependinginstalledplugins');
	return unless $pendingPlugins && @{$pendingPlugins};

	for my $canonicalName (@{$pendingPlugins}) {
		eval { Slim::Utils::ExtensionsManager->enablePlugin($canonicalName) };
		$log->error("Could not enable restored plugin $canonicalName in extension manager: $@") if $@;
	}
	main::INFOLOG && $log->is_info && $log->info('Enabled '.scalar(@{$pendingPlugins}).' restored plugin(s) in the extension manager install list: '.join(', ', @{$pendingPlugins}));
	$prefs->set('restorependinginstalledplugins', []);
}

sub _isTargetWritable {
	my $dir = shift;
	return (0, 0) unless $dir;

	my $pathExists = -d $dir ? 1 : 0;
	while ($dir && !-d $dir) {
		my $parentDir = dir($dir)->parent->stringify;
		last if $parentDir eq $dir;
		$dir = $parentDir;
	}
	return ($dir && -w $dir, $pathExists);
}

sub _safeWriteFile {
	my ($destPath, $content) = @_;

	my (undef, $destDir, $baseName) = splitpath($destPath);
	unless (-d $destDir) {
		eval { mkpath($destDir) };
		if ($@ || !-d $destDir) {
			$log->error("Could not create directory $destDir: " . ($@ || 'unknown error'));
			return 0;
		}
	}

	if (-f $destPath && $prefs->get('restorecreatebaks')) {
		if (opendir(my $dh, $destDir)) {
			for my $entry (readdir($dh)) {
				next unless index($entry, "$baseName.bak-") == 0;
				unlink(catfile($destDir, $entry)) or $log->warn("Could not remove old BAK file $entry: $!");
			}
			closedir($dh);
		}

		my $bakPath = $destPath.'.bak-'.strftime('%Y%m%d%H%M%S', localtime);
		unless (rename($destPath, $bakPath)) {
			$log->error("Could not create BAK of existing file $destPath to $bakPath: $!");
			return 0;
		}
	}

	my $writeOk = eval {
		open(my $fh, '>:raw', $destPath) or die "$!";
		print $fh $content;
		close $fh;
		1;
	};
	unless ($writeOk) {
		$log->error("Could not write $destPath: " . ($@ || 'unknown error'));
		return 0;
	}
	return 1;
}


sub _initTracksPersistentRestore {
	my ($xmlFile, $restoreDateAdded, $restorePlayCountLastPlayed) = @_;

	$tpRestoreFile = $xmlFile;
	$tpRestoreDateAdded = $restoreDateAdded;
	$tpRestorePlayCountLastPlayed = $restorePlayCountLastPlayed;
	$tpTotalTrackCount = _getTracksPersistentBackupTrackCount($xmlFile);
	($tpBackupSourceOS, $tpBackupSourceCodepage) = _getTracksPersistentBackupSourceInfo($xmlFile);
	my $currentOSDetails = Slim::Utils::OSDetect::details();
	$tpPreferCodepageFirst = (defined $tpBackupSourceOS && $tpBackupSourceOS eq 'Windows' && ($currentOSDetails->{'os'} || '') ne 'Windows') ? 1 : 0;
	$tpProcessedTrackCount = 0;
	$tpRestoreErrors = 0;
	$tpUnidentifiableCount = 0;
	$tpUnmatchedCount = 0;
	@tpUnmatchedTrackURLs = ();

	if (defined($tpBackupParserNB)) {
		eval { $tpBackupParserNB->parse_done };
		$tpBackupParserNB = undef;
	}
	$tpBackupParser = XML::Parser->new(
		'ErrorContext' => 2,
		'ProtocolEncoding' => 'UTF-8',
		'NoExpand' => 1,
		'NoLWP' => 1,
		'Handlers' => {
			'Start' => \&_tpHandleStartElement,
			'Char' => \&_tpHandleCharElement,
			'End' => \&_tpHandleEndElement,
		},
	);

	$tpRestoreFH = undef;
	$tpOpened = 0;
	$tpRestoreCount = 0;
	$tpRestoreStarted = time();

	main::INFOLOG && $log->is_info && $log->info('Starting tracks_persistent restore from backup file');
	Slim::Utils::Scheduler::add_task(\&_tpRestoreScanFunction);
}

sub _getTracksPersistentBackupSourceInfo {
	my $xmlFile = shift;
	my ($sourceOS, $sourceCodepage);

	open(my $fh, '<', $xmlFile) or do {
		$log->warn("Could not open backup file to detect its source OS: $xmlFile ($!)");
		return (undef, undef);
	};
	for (1..15) {
		my $line = <$fh>;
		last unless defined $line;
		if ($line =~ /<backupos>(.*?)<\/backupos>/) {
			$sourceOS = $1 || undef;
		}
		if ($line =~ /<backupcodepage>(.*?)<\/backupcodepage>/) {
			$sourceCodepage = $1 || undef;
		}
		last if defined $sourceOS && defined $sourceCodepage;
	}
	close($fh);

	main::INFOLOG && $log->is_info && $log->info('Backup source OS: '.($sourceOS || 'unknown (pre-dates this field)').', codepage: '.($sourceCodepage || 'n/a'));

	return ($sourceOS, $sourceCodepage);
}

sub _getTracksPersistentBackupTrackCount {
	my $xmlFile = shift;
	my $count;

	open(my $fh, '<', $xmlFile) or return 0;
	for (1..15) {
		my $line = <$fh>;
		last unless defined $line;
		if ($line =~ /<trackcount>(\d+)<\/trackcount>/) {
			$count = $1;
			last;
		}
	}
	close($fh);

	if (!defined $count) {
		main::DEBUGLOG && $log->is_debug && $log->debug('No trackcount element found in backup file - falling back to counting <track> occurrences (older backup format)');
		open(my $fh2, '<', $xmlFile) or return 0;
		$count = 0;
		while (my $line = <$fh2>) {
			my $matches = () = $line =~ /<track>/g;
			$count += $matches;
		}
		close($fh2);
	}

	return $count || 0;
}

sub _tpRestoreScanFunction {
	if ($tpOpened != 1) {
		open($tpRestoreFH, '<', $tpRestoreFile) || do {
			$log->error("Could not open tracks_persistent backup file: $tpRestoreFile");
			_finishRestore(2);
			return 0;
		};
		$tpOpened = 1;
		$tpInTrack = 0;
		$tpInValue = 0;
		$tpRestoreDone = 0;
		%tpRestoreItem = ();
		$tpCurrentKey = undef;

		if (defined $tpBackupParser) {
			$tpBackupParserNB = $tpBackupParser->parse_start();
		} else {
			$log->error('No tpBackupParser was defined!');
		}
	}

	if (defined $tpBackupParserNB) {
		my ($line, $reachedEOF);
		{
			local $/ = '>';
			for (my $i = 0; $i < 25;) {
				my $singleLine = <$tpRestoreFH>;
				if (defined($singleLine)) {
					$line .= $singleLine;
					if ($singleLine =~ /(<\/track>)$/) {
						$i++;
					}
				} else {
					last;
				}
			}
			$reachedEOF = eof($tpRestoreFH);
		}
		$line //= '';
		$line =~ s/&#(\d*);/escape(chr($1))/ge;
		eval { $tpBackupParserNB->parse_more($line) };
		if ($@) {
			$log->error("Error parsing backup file: $@");
			$tpRestoreErrors++;
			_tpDoneScanning();
			return 0;
		}
		if ($tpRestoreDone) {
			_tpDoneScanning();
			return 0;
		}
		if ($reachedEOF) {
			$log->error('Backup file ended unexpectedly before the closing </TracksPersistentSelectiveStats> tag was found - the file may be incomplete, corrupted, or not a valid backup file.');
			$tpRestoreErrors++;
			_tpDoneScanning();
			return 0;
		}
		return 1;
	}

	$log->error('No tpBackupParserNB defined!');
	_finishRestore(2);
	return 0;
}

sub _finishRestore {
	my ($result, $skipped) = @_; # result: 1 = success, 2 = error, 3 = success, requires rescan (mapped to global result codes below)
	my $resultCode = $skipped ? { 1 => 6, 2 => 4, 3 => 7 }->{$result} : { 1 => 3, 2 => 4, 3 => 5 }->{$result};
	$prefs->set('backuprestoreresult', $resultCode);
	$prefs->set('backuprestoreprogresspercentage', 100);
	$prefs->set('status_backuprestore', 0);
}

sub _tpDoneScanning {
	if (defined $tpBackupParserNB) {
		eval { $tpBackupParserNB->parse_done };
	}

	$tpBackupParserNB = undef;
	$tpBackupParser = undef;
	$tpOpened = 0;
	close($tpRestoreFH) if $tpRestoreFH;
	$tpRestoreFH = undef;

	my $skippedCount = $tpUnidentifiableCount + $tpUnmatchedCount;
	my $elapsedSeconds = time() - $tpRestoreStarted;
	my $itemsWord = $tpRestoreCount == 1 ? 'track' : 'tracks';
	my $wikiURL = 'https://github.com/AF-1/sobras/wiki/Restoring-backups-across-operating-systems';

	if ($tpRestoreErrors) {
		my $errorMsg = "Track statistics restore completed after $elapsedSeconds seconds with errors. Restored $tpRestoreCount $itemsWord, $tpRestoreErrors item(s) failed to import due to a parsing or database error";
		$errorMsg .= " and $skippedCount item(s) were skipped (unmatched or unidentifiable)" if $skippedCount;
		$errorMsg .= " - check the server log for details. More info: $wikiURL\n\n";
		$log->error($errorMsg);
	} elsif ($skippedCount) {
		if (!$tpRestoreCount) {
			$log->error("Track statistics restore matched 0 of $tpProcessedTrackCount track(s) in the backup to a track in the current library - nothing was restored.");
		}
		if ($tpUnidentifiableCount) {
			$log->error("Track statistics restore: $tpUnidentifiableCount of $tpProcessedTrackCount track(s) had no usable identifier (no urlmd5, url or musicbrainz id) in the backup entry itself and were skipped - this usually indicates a corrupted or unusually old backup file. Enable INFO level logging before the next restore for a per-track list.");
		}
		if ($tpUnmatchedCount) {
			_tpWriteUnmatchedTracksToFile();
			$log->error("Track statistics restore: $tpUnmatchedCount of $tpProcessedTrackCount track(s) had a valid identifier in the backup but no matching track was found in the current library and those values were skipped - this can happen if those tracks were since deleted, moved or renamed. See MIGA_Restore-Unmatched-Tracks.txt in the LMS prefs folder for the full list.");
		}
		$log->error("Track statistics restore completed after $elapsedSeconds seconds with $skippedCount of $tpProcessedTrackCount track(s) skipped. More info: $wikiURL\n\n");
	} else {
		main::INFOLOG && $log->is_info && $log->info("Track statistics restore completed after $elapsedSeconds seconds. Restored $tpRestoreCount $itemsWord.\n\n");
	}
	@tpUnmatchedTrackURLs = ();

	_finishRestore($tpRestoreErrors > 0 ? 2 : ($prefs->get('restorependingrescan') ? 3 : 1), $skippedCount > 0);
}

sub _tpHandleStartElement {
	my ($p, $element) = @_;

	if ($tpInTrack) {
		$tpCurrentKey = $element;
		$tpInValue = 1;
		$tpRestoreItem{$tpCurrentKey} = '';
	}
	if ($element eq 'track') {
		$tpInTrack = 1;
	}
}

sub _tpHandleCharElement {
	my ($p, $value) = @_;

	if ($tpInValue && $tpCurrentKey) {
		$tpRestoreItem{$tpCurrentKey} .= $value;
	}
}

sub _tpHandleEndElement {
	my ($p, $element) = @_;
	$tpInValue = 0;

	if ($tpInTrack && $element eq 'track') {
		$tpInTrack = 0;

		my $curTrack = \%tpRestoreItem;
		my $fullTrackURLraw = $curTrack->{'url'};
		my $backupTrackURLmd5 = $curTrack->{'urlmd5'};
		my $isRemote = $curTrack->{'remote'};
		my $relTrackURLraw = $curTrack->{'relurl'};
		my $trackMBID = $curTrack->{'musicbrainzid'};

		my $fullTrackURL = Encode::decode('utf8', unescape($fullTrackURLraw));

		# encode_locale() matches whatever byte encoding this LMS instance itself used when it scanned
		# local files (UTF-8 on Linux/macOS, the active ANSI codepage on Windows) - falls back to plain
		# UTF-8 encoding on LMS versions that lack this function
		my $encodeForLocalPath = Slim::Utils::Unicode->can('encode_locale') ? \&Slim::Utils::Unicode::encode_locale : sub { return Encode::encode('utf8', $_[0]); };

		# a Windows source backup names its own codepage; without that field, still try the common
		# Western default unless the source is positively known to be non-Windows (Darwin/Linux)
		my $sourceCodepage = $tpBackupSourceCodepage || ((!defined $tpBackupSourceOS || $tpBackupSourceOS eq 'Windows') ? 'cp1252' : undef);

		# builds NFC and NFD variants from already-decoded text, re-encoded for this machine's locale;
		# $isFullURL also runs the result back through fileURLFromPath/pathFromFileURL for full URLs
		my $buildNfcNfdVariants = sub {
			my ($decodedText, $isFullURL) = @_;
			return (undef, undef) unless defined $decodedText;
			my $nfc = $encodeForLocalPath->(Unicode::Normalize::NFC($decodedText));
			my $nfd = $encodeForLocalPath->(Unicode::Normalize::NFD($decodedText));
			if ($isFullURL) {
				$nfc = Slim::Utils::Misc::fileURLFromPath(Slim::Utils::Misc::pathFromFileURL($nfc));
				$nfd = Slim::Utils::Misc::fileURLFromPath(Slim::Utils::Misc::pathFromFileURL($nfd));
			}
			return ($nfc, $nfd);
		};

		my ($fullTrackURLnfc, $fullTrackURLnfd, $fullTrackURLcpNfc, $fullTrackURLcpNfd);
		if ($fullTrackURLraw) {
			my $fullTrackURLrawBytes = unescape(unescape($fullTrackURLraw));

			($fullTrackURLnfc, $fullTrackURLnfd) = $buildNfcNfdVariants->(Encode::decode('utf8', $fullTrackURLrawBytes), 1);

			# a Windows source may have written its own file:// URL using the active ANSI codepage
			# instead of UTF-8 (e.g. a single 0xE3 byte for one accented character) - decode with that
			# codepage instead of UTF-8, then build the same NFC/NFD variants as above
			if ($sourceCodepage) {
				my $fullTrackURLcpDecoded = eval { Encode::decode($sourceCodepage, $fullTrackURLrawBytes) };
				main::DEBUGLOG && $log->is_debug && $log->debug("Could not decode full track URL as $sourceCodepage: $@") if $@;
				($fullTrackURLcpNfc, $fullTrackURLcpNfd) = $buildNfcNfdVariants->($fullTrackURLcpDecoded, 1) if defined $fullTrackURLcpDecoded;
			}
		}

		my ($relTrackURL, $relTrackURLnfc, $relTrackURLnfd, $relTrackURLcpNfc, $relTrackURLcpNfd);
		if ($relTrackURLraw) {
			$relTrackURL = Encode::decode('utf8', unescape($relTrackURLraw));
			$relTrackURL =~ s/^\.\///;

			# second unescape pass fully resolves double-encoded backup entries down to raw bytes;
			# NFC/NFD-normalizes to cover both migration directions (macOS decomposes, most other
			# filesystems compose), re-encoded for this machine's locale for a consistent fileURLFromPath() call
			my $relTrackURLrawBytes = unescape(unescape($relTrackURLraw));
			my $relTrackURLdecoded = Encode::decode('utf8', $relTrackURLrawBytes);
			$relTrackURLdecoded =~ s/^\.\///;

			($relTrackURLnfc, $relTrackURLnfd) = $buildNfcNfdVariants->($relTrackURLdecoded, 0);

			# same Windows-codepage fallback as above, applied to the relative path
			if ($sourceCodepage) {
				my $relTrackURLcpDecoded = eval { Encode::decode($sourceCodepage, $relTrackURLrawBytes) };
				main::DEBUGLOG && $log->is_debug && $log->debug("Could not decode relative track URL as $sourceCodepage: $@") if $@;
				if (defined $relTrackURLcpDecoded) {
					$relTrackURLcpDecoded =~ s/^\.\///;
					($relTrackURLcpNfc, $relTrackURLcpNfd) = $buildNfcNfdVariants->($relTrackURLcpDecoded, 0);
				}
			}
		}

		# build every plausible current URL for this track (the full backup URL + one reconstruction per configured media folder for local tracks) and check them against the tracks_persistent table
		my @candidateURLs;
		my %seenFullURL;
		for my $candidate ($tpPreferCodepageFirst ? ($fullTrackURLcpNfc, $fullTrackURLcpNfd, $fullTrackURL, $fullTrackURLnfc, $fullTrackURLnfd) : ($fullTrackURL, $fullTrackURLnfc, $fullTrackURLnfd, $fullTrackURLcpNfc, $fullTrackURLcpNfd)) {
			next unless $candidate;
			next if $seenFullURL{$candidate}++;
			push @candidateURLs, $candidate;
		}

		if (!($isRemote && $isRemote == 1) && $relTrackURL) {
			my $lmsmusicdirs = getMusicDirs();
			my $dirSep = File::Spec->canonpath("/");
			my %seenRawRelPath;
			my @rawRelPathVariants;
			for my $relPath ($tpPreferCodepageFirst ? ($relTrackURLcpNfc, $relTrackURLcpNfd, $relTrackURLnfc, $relTrackURLnfd) : ($relTrackURLnfc, $relTrackURLnfd, $relTrackURLcpNfc, $relTrackURLcpNfd)) {
				next unless $relPath;
				next if $seenRawRelPath{$relPath}++;
				push @rawRelPathVariants, $relPath;
			}
			foreach my $mediaDir (@{$lmsmusicdirs}) {
				if ($tpPreferCodepageFirst) {
					push @candidateURLs, map { Slim::Utils::Misc::fileURLFromPath($mediaDir.$dirSep.$_) } @rawRelPathVariants;
					push @candidateURLs, Slim::Utils::Misc::fileURLFromPath($mediaDir.$dirSep).$relTrackURL;
				} else {
					push @candidateURLs, Slim::Utils::Misc::fileURLFromPath($mediaDir.$dirSep).$relTrackURL;
					push @candidateURLs, map { Slim::Utils::Misc::fileURLFromPath($mediaDir.$dirSep.$_) } @rawRelPathVariants;
				}
			}
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('Candidate URLs for this track: '.Data::Dump::dump(\@candidateURLs));

		my @urlmd5Candidates;
		push @urlmd5Candidates, $backupTrackURLmd5 if $backupTrackURLmd5;
		for my $candidateURL (@candidateURLs) {
			my $freshUrlmd5 = md5_hex($candidateURL);
			push @urlmd5Candidates, $freshUrlmd5 unless grep { $_ eq $freshUrlmd5 } @urlmd5Candidates;
			if (Slim::Utils::Misc->can('safe_md5_hex')) {
				my $freshSafeUrlmd5 = Slim::Utils::Misc::safe_md5_hex($candidateURL);
				push @urlmd5Candidates, $freshSafeUrlmd5 unless grep { $_ eq $freshSafeUrlmd5 } @urlmd5Candidates;
			}
		}

		if (!@urlmd5Candidates && !$trackMBID) {
			$tpUnidentifiableCount++;
			main::INFOLOG && $log->is_info && $log->info("No valid urlmd5, url or musicbrainz id for this track - can't restore values. Backup URL was: ".Data::Dump::dump($fullTrackURL));
		} else {
			my (@setParts, @bindVals);
			if ($tpRestoreDateAdded) {
				my $added = (!defined($curTrack->{'added'}) || $curTrack->{'added'} eq '' || $curTrack->{'added'} !~ /^\d+$/) ? undef : $curTrack->{'added'} + 0;
				push @setParts, 'added = ?';
				push @bindVals, $added;
			}
			if ($tpRestorePlayCountLastPlayed) {
				my $playCount = (!defined($curTrack->{'playcount'}) || $curTrack->{'playcount'} eq '' || $curTrack->{'playcount'} !~ /^\d+$/) ? undef : $curTrack->{'playcount'} + 0;
				my $lastPlayed = (!defined($curTrack->{'lastplayed'}) || $curTrack->{'lastplayed'} eq '' || $curTrack->{'lastplayed'} !~ /^\d+$/) ? undef : $curTrack->{'lastplayed'} + 0;
				push @setParts, 'playCount = ?', 'lastPlayed = ?';
				push @bindVals, $playCount, $lastPlayed;
			}

			if (@setParts) {
				my $setClause = 'set '.join(', ', @setParts);
				my $dbh = Slim::Schema->dbh;

				my $updated = 0;
				for my $urlmd5Candidate (@urlmd5Candidates) {
					if ($urlmd5Candidate !~ /^[a-f0-9]{32}$/i) {
						$log->error("Invalid urlmd5 in backup file, skipping candidate: $urlmd5Candidate");
						next;
					}
					my $rowsAffected = eval { $dbh->do("update tracks_persistent $setClause where urlmd5 = ?", undef, @bindVals, $urlmd5Candidate) };
					if ($@) {
						$log->error("Database error: $@");
						$tpRestoreErrors++;
						next;
					}
					if ($rowsAffected && $rowsAffected > 0) {
						$updated = 1;
						$tpRestoreCount++;
						last;
					}
				}

				if (!$updated && $trackMBID) {
					if ($trackMBID !~ /^[a-zA-Z0-9\-]+$/) {
						$log->error("Invalid MBID in backup file, skipping track: $trackMBID");
					} else {
						my $rowsAffected = eval { $dbh->do("update tracks_persistent $setClause where musicbrainz_id = ?", undef, @bindVals, $trackMBID) };
						if ($@) {
							$log->error("Database error: $@");
							$tpRestoreErrors++;
						} elsif ($rowsAffected && $rowsAffected > 0) {
							$updated = 1;
							$tpRestoreCount++;
						}
					}
				}

				unless ($updated) {
					$tpUnmatchedCount++;
					push @tpUnmatchedTrackURLs, $fullTrackURL || '(no URL in backup entry)';
					main::DEBUGLOG && $log->is_debug && $log->debug("Could not find a matching track in the current library for this track - tried urlmd5 candidates: ".Data::Dump::dump(\@urlmd5Candidates).", musicbrainz id: ".Data::Dump::dump($trackMBID).". Backup URL was: ".Data::Dump::dump($fullTrackURL));
				}
			}
		}
		$tpProcessedTrackCount++;
		if ($tpTotalTrackCount) {
			$prefs->set('backuprestoreprogresspercentage', sprintf("%.0f", ($tpProcessedTrackCount / $tpTotalTrackCount) * 100));
		}
		%tpRestoreItem = ();
	}
	if ($element eq 'TracksPersistentSelectiveStats') {
		$tpRestoreDone = 1;
	}
}

sub _tpWriteUnmatchedTracksToFile {
	my $prefsDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
	my $filename = catfile($prefsDir, 'MIGA_Restore-Unmatched-Tracks.txt');
	my $output = FileHandle->new($filename, '>:utf8') or do {
		$log->error('Could not open '.$filename.' for writing. Does LMS have read/write permissions (755) for the prefs folder?');
		return;
	};
	print $output strftime("%Y-%m-%d -- %H:%M:%S", localtime time)."\n";
	print $output scalar(@tpUnmatchedTrackURLs)." track(s) could not be matched during the last restore:\n\n";
	print $output $_."\n" foreach @tpUnmatchedTrackURLs;
	close $output;
}


## misc

sub getMusicDirs {
	my $mediadirs = $serverPrefs->get('mediadirs');
	my $ignoreInAudioScan = $serverPrefs->get('ignoreInAudioScan');
	my $lmsmusicdirs = [];
	my %musicdircount;
	foreach my $thisdir (@{$mediadirs}, @{$ignoreInAudioScan}) {$musicdircount{$thisdir}++}
	foreach my $thisdir (keys %musicdircount) {
		if ($musicdircount{$thisdir} == 1) {
			push (@{$lmsmusicdirs}, $thisdir);
		}
	}
	return $lmsmusicdirs;
}

sub getBackupCodepage {
	return undef unless main::ISWINDOWS;
	my $codepage;
	eval {
		require Win32;
		my $cp = Win32::GetACP();
		$codepage = 'cp'.$cp if $cp;
	};
	main::DEBUGLOG && $log->is_debug && $log->debug('Could not determine Windows codepage: '.$@) if $@;
	return $codepage;
}

sub getRelFilePath {
	my $fullTrackURL = shift;
	my $relFilePath;
	my $lmsmusicdirs = getMusicDirs();
	main::DEBUGLOG && $log->is_debug && $log->debug('Valid LMS music dirs = '.Data::Dump::dump($lmsmusicdirs));

	foreach (@{$lmsmusicdirs}) {
		my $dirSep = File::Spec->canonpath("/");
		my $mediaDirPath = $_.$dirSep;
		my $fullTrackPath = Slim::Utils::Misc::pathFromFileURL($fullTrackURL);
		my $match = checkInFolder($fullTrackPath, $mediaDirPath);

		main::DEBUGLOG && $log->is_debug && $log->debug("Full file path \"$fullTrackPath\" is".($match == 1 ? "" : " NOT")." part of media dir \"".$mediaDirPath."\"");
		if ($match == 1) {
			$relFilePath = file($fullTrackPath)->relative($_);
			$relFilePath = Slim::Utils::Misc::fileURLFromPath($relFilePath);
			$relFilePath =~ s/^(file:)?\/+//isg;
			$relFilePath =~ s/^\.\///;
			main::DEBUGLOG && $log->is_debug && $log->debug('Saving RELATIVE file path: '.$relFilePath);
			last;
		}
	}
	if (!$relFilePath) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Couldn't get relative file path for \"$fullTrackURL\".");
	}
	return $relFilePath;
}

sub checkInFolder {
	my $path = shift || return;
	my $checkdir = shift;

	$path = Slim::Utils::Misc::fixPath($path) || return 0;
	$path = Slim::Utils::Misc::pathFromFileURL($path) || return 0;
	main::DEBUGLOG && $log->is_debug && $log->debug('path = '.$path.' -- checkdir = '.$checkdir);

	if ($checkdir && $path =~ /^\Q$checkdir\E/) {
		return 1;
	} else {
		return 0;
	}
}

sub pathForItem {
	my $item = shift;
	if (Slim::Music::Info::isFileURL($item) && !Slim::Music::Info::isFragment($item)) {
		my $path = Slim::Utils::Misc::fixPath($item) || return 0;
		return Slim::Utils::Misc::pathFromFileURL($path);
	}
	return $item;
}

sub getDisplayName {'PLUGIN_MIGRATIONASSISTANT'}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
