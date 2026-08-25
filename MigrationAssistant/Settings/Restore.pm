#
# MigrationAssistant
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::MigrationAssistant::Settings::Restore;

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
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/MigrationAssistant/settings/restore.html');
}

sub currentPage {
	return name();
}

sub pages {
	return [{ 'name' => name(), 'page' => page() }];
}

sub prefs {
	return ($prefs, qw(restorecreatebaks));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result;

	if (defined $paramRef->{'pref_restoreskipprefs'}) {
		my $restoreSkipPrefs = $paramRef->{'pref_restoreskipprefs'};
		$restoreSkipPrefs =~ s/^\s+|\s+$//g;
		$prefs->set('restoreskipprefs', $restoreSkipPrefs);
	}
	$paramRef->{'restoreskipprefs'} = $prefs->get('restoreskipprefs');

	if ($paramRef->{'listrestorecontents'} || $paramRef->{'restore'}) {
		my $selectedfile = $paramRef->{'pref_restorefile'};
		$paramRef->{'saveSettings'} = 1;
		main::DEBUGLOG && $log->is_debug && $log->debug('restorefile = '.Data::Dump::dump($selectedfile));
		if (!defined($selectedfile) || $selectedfile eq '') {
			$paramRef->{'restoremissingfile'} = 1;
		} elsif ($selectedfile !~ /\.zip$/i) {
			$paramRef->{'restoremissingfile'} = 2;
			$paramRef->{'restorefilefolder'} = $selectedfile;
		} elsif (!-f $selectedfile) {
			$paramRef->{'restoremissingfile'} = 3;
			$paramRef->{'restorefilefolder'} = $selectedfile;
		} else {
			$prefs->set('restorefile', $selectedfile);
			$paramRef->{'restorefilefolder'} = $selectedfile;
			my $archiveContents = Plugins::MigrationAssistant::Plugin::listBackupContents($selectedfile);
			if (!@{$archiveContents}) {
				$paramRef->{'restorenoitems'} = 1;
			} else {
				my %categoryCounts;
				$categoryCounts{$_->{'category'}}++ for @{$archiveContents};
				$paramRef->{'restorecategorycounts'} = \%categoryCounts;

				my %installSourceCounts;
				$installSourceCounts{$_->{'installsource'}}++ for grep { $_->{'category'} eq 'installedplugins' } @{$archiveContents};
				$paramRef->{'restoreinstallsourcecounts'} = \%installSourceCounts;

				if ($paramRef->{'restore'}) {
					my %selectedNamespaces;
					for my $item (@{$archiveContents}) {
						$selectedNamespaces{$item->{'namespace'}} = 1 if $paramRef->{"pref_selected_$item->{'namespace'}"};
					}
					main::DEBUGLOG && $log->is_debug && $log->debug('selected namespaces = '.Data::Dump::dump(\%selectedNamespaces));
					main::DEBUGLOG && $log->is_debug && $log->debug('restore params = '.Data::Dump::dump([ grep { /^pref_selected_/ } keys %$paramRef ]));

					if (%selectedNamespaces) {
						my ($restoreOk, undef, $anyNamespaceRestored) = Plugins::MigrationAssistant::Plugin::restoreFromBackup(\%selectedNamespaces);
						unless ($restoreOk) {
							$paramRef->{'restoreerror'} = 1;
							# keep showing the list on failure so the user can retry without listing again
							$paramRef->{'restorearchivecontents'} = $archiveContents;
						}
					} else {
						# nothing selected - just display the list again
						$paramRef->{'restorearchivecontents'} = $archiveContents;
					}
				} else {
					$paramRef->{'restorearchivecontents'} = $archiveContents;
				}
			}
		}
	}

	if ($paramRef->{'restart'} && ($prefs->get('backuprestoreresult') == 3 || $prefs->get('backuprestoreresult') == 5)) {
		$prefs->set('backuprestoreresult', 0);
		$paramRef = Slim::Web::Settings::Server::Plugins->restartServer($paramRef, 1);
	}
	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	$paramRef->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';
	$paramRef->{'activebackuprestore'} = 1 if $prefs->get('status_backuprestore');
	main::DEBUGLOG && $log->is_debug && $log->debug("\nstatus_backuprestore = ".Data::Dump::dump($prefs->get('status_backuprestore'))."\nbackuprestoreresult = ".Data::Dump::dump($prefs->get('backuprestoreresult'))."\nrestoreNeedsReload = ".Data::Dump::dump($prefs->get('restoreNeedsReload'))."\nparamRef restoreReload = ".Data::Dump::dump($paramRef->{'restoreReload'} )."\n");

	if ($prefs->get('restoreNeedsReload')) {
		$paramRef->{'restoreReload'} = 1;
		$prefs->set('restoreNeedsReload', 0);
	}
	if ($prefs->get('backuprestoreresult') == 3 || $prefs->get('backuprestoreresult') == 5) {
		$paramRef->{'path'} = 'plugins/MigrationAssistant/settings/restore.html';
		$paramRef = Slim::Web::Settings::Server::Plugins->getRestartMessage($paramRef, Slim::Utils::Strings::string('PLUGIN_MIGRATIONASSISTANT_SETTINGS_RESTORE_RESTART_BANNER'));
	}
}

1;
