#
# MigrationAssistant
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::MigrationAssistant::Settings::Backup;

use strict;
use warnings;
use utf8;

use base qw(Plugins::MigrationAssistant::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.migrationassistant');
my $log = logger('plugin.migrationassistant');

sub new {
	my ($class, $plugin) = @_;
	$class->SUPER::new($plugin,1);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_MIGRATIONSASSISTANT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/MigrationAssistant/settings/backup.html');
}

sub currentPage {
	return name();
}

sub pages {
	my %page = (
		'name' => Slim::Web::HTTP::CSRF->protectName('PLUGIN_MIGRATIONSASSISTANT_SETTINGS_BACKUP'),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return $prefs;
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result;

	if (defined $paramRef->{'pref_extrabackuppath_source_0'}) {
		my (@extraBackupPaths, @extrapathrejected, @extrapathduplicate);
		my %sourceDone;
		for (my $n = 0; $n <= 10; $n++) {
			my $source = $paramRef->{"pref_extrabackuppath_source_$n"};
			next unless defined $source;
			$source =~ s/^\s+|\s+$//g;
			next unless length($source) > 0;
			$source = File::Spec->canonpath($source);

			my $target = $paramRef->{"pref_extrabackuppath_target_$n"} // '';
			$target =~ s/^\s+|\s+$//g;
			$target = length($target) > 0 ? File::Spec->canonpath($target) : $source;

			if ($sourceDone{$source}) {
				next;
			}
			if (Plugins::MigrationAssistant::Plugin::_isForbiddenCustomPath($source)) {
				push @extrapathrejected, $source;
				next;
			}

			my $isDuplicate = 0;
			for my $entry (@Plugins::MigrationAssistant::Plugin::OUR_PLUGIN_DATA_FOLDERS) {
				my $ourPath = eval { Plugins::MigrationAssistant::Plugin::preferences($entry->{'namespace'})->get($entry->{'pathkey'}) };
				next unless $ourPath;
				if (File::Spec->canonpath($ourPath) eq File::Spec->canonpath($source)) {
					$isDuplicate = 1;
					last;
				}
			}
			if ($isDuplicate) {
				push @extrapathduplicate, $source;
				next;
			}

			push(@extraBackupPaths, { source => $source, target => $target });
			$sourceDone{$source} = 1;
		}
		$prefs->set('extrabackuppaths', \@extraBackupPaths);
		$paramRef->{'extrapathrejected'} = \@extrapathrejected if @extrapathrejected;
		$paramRef->{'extrapathduplicate'} = \@extrapathduplicate if @extrapathduplicate;
	}

	if ($paramRef->{'backup'}) {
		my $selectedfolder = $paramRef->{'pref_backupoutputfolder'};
		$paramRef->{'backupoutputfolder'} = $selectedfolder;
		$paramRef->{'saveSettings'} = 1;
		main::DEBUGLOG && $log->is_debug && $log->debug('backupoutputfolder = '.Data::Dump::dump($selectedfolder));
		if (!defined($selectedfolder) || $selectedfolder eq '') {
			$paramRef->{'backupmissingoutputfolder'} = 1;
		} elsif (!-d $selectedfolder) {
			$paramRef->{'backupinvalidoutputfolder'} = 1;
		} else {
			$prefs->set('backupoutputfolder', $selectedfolder);
			unless (Plugins::MigrationAssistant::Plugin::createBackup()) {
				$paramRef->{'backuperror'} = 1;
			}
		}
	}

	$paramRef->{'extrabackuppaths'} = [];
	for my $entry (@{$prefs->get('extrabackuppaths') || []}) {
		push @{$paramRef->{'extrabackuppaths'}}, $entry;
	}
	if (scalar(@{$paramRef->{'extrabackuppaths'}}) + 1 < 10) {
		push @{$paramRef->{'extrabackuppaths'}}, { source => '', target => '' };
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	$paramRef->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';
	$paramRef->{'activebackuprestore'} = 1 if $prefs->get('status_backuprestore');
}

1;
