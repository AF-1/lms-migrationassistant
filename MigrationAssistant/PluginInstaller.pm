#
# MigrationAssistant
# (c) 2026 AF
# Licensed under the GPLv3 - see LICENSE file
#
# Downloads and installs, live and without requiring a server restart, any
# plugin that was enabled in a restored extensions.prefs but is not
# currently installed.
#
# Catalog resolution and download are done with a plain blocking HTTP client
# (LWP::UserAgent) - this does NOT depend on LMS's own async networking
# reactor at all, which is deliberate: an earlier version of this module
# used Slim::Utils::ExtensionsManager::getAllPluginRepos and
# Slim::Utils::PluginDownloader->install() (the same async APIs LMS's own
# first-run Setup Wizard uses), but that depends on LMS's event loop being
# pumped correctly from within a synchronous restore request, and in testing
# that did not reliably complete. A plain blocking HTTP fetch sidesteps that
# entirely and was already proven to correctly resolve and download plugins.
#
# The one thing still borrowed from the Wizard's approach: after our own
# (already-verified, already-downloaded) zip is in place, we call
# Slim::Utils::PluginManager->init() and ->load() ourselves, live, in this
# same running process - the same two calls that make the Wizard's plugin
# installs available without a restart. Those are plain synchronous method
# calls with no event-loop dependency, so they don't have the same problem.
#
# We also still set plugin.state to 'needs-install' (and force it to disk)
# as a belt-and-suspenders fallback: if the live reload below doesn't fully
# take for some reason, a subsequent real server restart will still pick it
# up via LMS's normal pending-operations processing.
#

package Plugins::MigrationAssistant::PluginInstaller;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::OSDetect;
use Slim::Utils::PluginManager;
use Slim::Utils::Versions;
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(mkpath);
use Digest::SHA qw(sha1_hex);
use XML::Simple;
use LWP::UserAgent;
use IO::Socket::INET;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.migrationassistant',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_MIGRATIONSASSISTANT',
});

# same prefs namespace Slim::Utils::PluginManager itself uses for per-plugin
# install state ('enabled' | 'disabled' | 'needs-install' | 'needs-enable' | ...)
my $pluginStatePrefs = preferences('plugin.state');

# NOTE: the key holding user-added custom repository URLs below ('repos')
# was confirmed correct against a real extensions.prefs sample during
# development - it's a plain array of repo XML URLs.
my $extensionMgrPrefs = preferences('plugin.extensions');

use constant DEFAULT_REPO_URL => 'https://raw.githubusercontent.com/LMS-Community/lms-plugin-repository/master/extensions.xml';
use constant HTTP_TIMEOUT => 15;
use constant HARD_TIMEOUT_SECS => 20;
use constant PRECHECK_TIMEOUT_SECS => 5;

# cached for the lifetime of one restore run only - never persisted to disk
my $catalogCache;

# Runs $code with a hard wall-clock ceiling, using alarm() rather than relying
# solely on LWP::UserAgent's own timeout parameter. A fully unresponsive or
# firewalled host (packets silently dropped rather than rejected) can cause
# LWP's configured timeout to not fire reliably in some environments, leaving
# the whole restore hung on one dead repository. alarm() forcibly interrupts
# the blocked call regardless of what's happening underneath it.
# Returns ($result, undef) on success, or (undef, 'timed out') if $code did
# not complete within HARD_TIMEOUT_SECS.
sub _withHardTimeout {
	my $code = shift;
	my $result;

	eval {
		local $SIG{ALRM} = sub { die "migrationassistant-timeout\n" };
		alarm(HARD_TIMEOUT_SECS);
		$result = $code->();
		alarm(0);
	};
	alarm(0); # belt-and-suspenders - always clear, even if $code died before its own alarm(0) ran

	if ($@) {
		return (undef, 'timed out') if $@ eq "migrationassistant-timeout\n";
		die $@; # a real error from $code itself - let the caller's own eval/handling deal with it
	}
	return ($result, undef);
}

sub _normalize {
	my $s = lc(shift || '');
	$s =~ s/[^a-z0-9]//g;
	return $s;
}

# Proactively checks whether a repo's host is reachable at all, using a plain
# TCP connect bounded by IO::Socket::INET's own Timeout parameter - this is
# implemented internally via a non-blocking connect() + select() loop, NOT
# via Perl signals, so unlike alarm() it isn't defeated by a hanging DNS
# lookup or other uninterruptible blocking call. This is deliberately a
# cheap, separate pre-check rather than folding it into the real HTTP fetch,
# so a single down/unreachable custom repo gets skipped in a few seconds
# instead of stalling the whole restore, regardless of exactly how it's
# failing (dead host, firewalled/dropped packets, broken DNS, etc).
sub _isHostReachable {
	my $url = shift;
	my ($scheme, $host, $port) = $url =~ m{^(https?)://([^/:]+)(?::(\d+))?}i;
	return 1 unless $host; # couldn't parse it - don't block on our own parsing, let the real fetch attempt run and fail normally
	$port ||= (lc($scheme || 'https') eq 'https') ? 443 : 80;

	my $sock = eval {
		local $SIG{ALRM} = sub { die "precheck-timeout\n" };
		alarm(PRECHECK_TIMEOUT_SECS);
		my $s = IO::Socket::INET->new(
			PeerHost => $host,
			PeerPort => $port,
			Proto    => 'tcp',
			Timeout  => PRECHECK_TIMEOUT_SECS,
		);
		alarm(0);
		$s;
	};
	alarm(0);

	if ($sock) {
		close($sock);
		return 1;
	}
	return 0;
}

sub _repoUrls {
	my @urls = (DEFAULT_REPO_URL);

	my $custom = eval { $extensionMgrPrefs->get('repos') };
	if (ref $custom eq 'ARRAY') {
		push @urls, @{$custom};
	} elsif (ref $custom eq 'HASH') {
		push @urls, keys %{$custom};
	}
	return @urls;
}

sub _fetchCatalog {
	return $catalogCache if $catalogCache;

	my %catalog;

	for my $url (_repoUrls()) {
		unless (_isHostReachable($url)) {
			$log->warn("Plugin repository $url does not appear to be reachable - skipping it");
			next;
		}

		my ($resp, $timeoutReason) = eval {
			_withHardTimeout(sub {
				my $ua = LWP::UserAgent->new(timeout => HTTP_TIMEOUT);
				return $ua->get($url);
			});
		};
		if ($@) {
			$log->warn("Could not fetch plugin repository $url: $@");
			next;
		}
		if ($timeoutReason) {
			$log->warn("Timed out (after " . HARD_TIMEOUT_SECS . "s) fetching plugin repository $url - skipping it and moving on");
			next;
		}
		if (!$resp || !$resp->is_success) {
			$log->warn("Could not fetch plugin repository $url: " . ($resp ? $resp->status_line : 'no response'));
			next;
		}

		my $parsed = eval { XMLin($resp->decoded_content, ForceArray => 1, KeyAttr => []) };
		if ($@ || !$parsed) {
			$log->warn("Could not parse plugin repository XML from $url: " . ($@ || 'empty'));
			next;
		}

		_collectPluginEntries($parsed, \%catalog);
	}

	$catalogCache = \%catalog;
	return $catalogCache;
}

# XML::Simple's exact nesting of <plugin> elements isn't guaranteed identical
# across every repo file some third-party authors publish, so rather than
# assuming one fixed shape we walk the parsed structure recursively and pick
# up anything that looks like a plugin entry (has both a name and a url).
sub _collectPluginEntries {
	my ($node, $catalog) = @_;

	if (ref $node eq 'HASH') {
		if ($node->{'name'} && $node->{'url'}) {
			my $key = _normalize($node->{'name'});
			# first match wins - the default community repo is always fetched first
			$catalog->{$key} ||= {
				name      => $node->{'name'},
				url       => $node->{'url'},
				sha       => $node->{'sha'},
				version   => $node->{'version'},
				minTarget => $node->{'minTarget'},
				maxTarget => $node->{'maxTarget'},
			};
		}
		_collectPluginEntries($_, $catalog) for values %{$node};
	} elsif (ref $node eq 'ARRAY') {
		_collectPluginEntries($_, $catalog) for @{$node};
	}
}

sub findCatalogEntry {
	my $shortName = shift;
	my $catalog = _fetchCatalog();
	return $catalog->{ _normalize($shortName) };
}

sub _downloadedPluginsDir {
	my $dir = catdir(Slim::Utils::OSDetect::dirsFor('cache'), 'DownloadedPlugins');
	unless (-d $dir) {
		eval { mkpath($dir) };
	}
	return $dir;
}

# Downloads and checksum-verifies one plugin's zip into cache/DownloadedPlugins/.
# Returns (1, undef) on success, or (0, $reason) on failure. Does not touch
# plugin.state or attempt to load anything - see resolveAndInstallPlugins.
sub _downloadAndVerify {
	my $entry = shift;

	my $useUnsupported = eval { $extensionMgrPrefs->get('useUnsupported') };
	if (!$useUnsupported
		&& $entry->{'maxTarget'} && $entry->{'maxTarget'} ne '*'
		&& Slim::Utils::Versions->can('checkVersion')
		&& !Slim::Utils::Versions->checkVersion($::VERSION, $entry->{'minTarget'}, $entry->{'maxTarget'}))
	{
		return (0, "not compatible with this server version (requires $entry->{'minTarget'} - $entry->{'maxTarget'})");
	}

	my $zipPath = catfile(_downloadedPluginsDir(), $entry->{'name'} . '.zip');

	my ($resp, $timeoutReason) = eval {
		_withHardTimeout(sub {
			my $ua = LWP::UserAgent->new(timeout => HTTP_TIMEOUT);
			return $ua->get($entry->{'url'}, ':content_file' => $zipPath);
		});
	};
	if ($@) {
		unlink $zipPath if -f $zipPath;
		return (0, "download failed - $@");
	}
	if ($timeoutReason) {
		unlink $zipPath if -f $zipPath;
		return (0, 'download timed out after ' . HARD_TIMEOUT_SECS . 's - repository may be down');
	}
	if (!$resp || !$resp->is_success) {
		unlink $zipPath if -f $zipPath;
		return (0, 'download failed - ' . ($resp ? $resp->status_line : 'no response'));
	}

	if ($entry->{'sha'}) {
		my $sha1 = eval {
			open(my $fh, '<:raw', $zipPath) or die "$!";
			local $/;
			my $content = <$fh>;
			close $fh;
			sha1_hex($content);
		};
		if ($@ || lc($sha1 || '') ne lc($entry->{'sha'})) {
			unlink $zipPath if -f $zipPath;
			$log->error("Checksum mismatch downloading $entry->{'name'} - refusing to install");
			return (0, 'checksum did not match - download discarded');
		}
	}

	return (1, undef);
}

sub _isAlreadyInstalled {
	my $name = shift;
	return Plugins::MigrationAssistant::Plugin::_findPluginManifestEntryExact($name) ? 1 : 0;
}

# Resolves and downloads ONE plugin (arrayref item, exact case as used in
# extensions.prefs / extensions.xml). Deliberately does NOT touch
# Slim::Utils::PluginManager at all - that must only happen once, for the
# whole batch, via finalizeInstalls() below. Calling PluginManager->init()
# once per plugin (as an earlier version of this file did) triggers a full
# reprocessing of every already-loaded plugin's state on every single call -
# in testing this caused an already-installed, unrelated plugin to repeatedly
# re-run its own startup/safe-mode check dozens of times in a row, which looked
# indistinguishable from a hang. Keeping this function download-only and
# calling the PluginManager reload exactly once fixes that.
#
# Returns (1, undef) on success, or (0, $reason) on failure. On success, also
# records plugin.state = 'needs-install' (forced to disk) as a fallback in
# case finalizeInstalls()'s live reload doesn't fully take for some reason -
# a subsequent real restart will still pick it up via LMS's normal
# pending-operations processing.
sub downloadPlugin {
	my $name = shift;

	return (0, 'already installed') if _isAlreadyInstalled($name);

	my $entry = findCatalogEntry($name);
	unless ($entry) {
		return (0, 'not found in any configured plugin repository');
	}

	my ($ok, $reason) = _downloadAndVerify($entry);
	return (0, $reason) unless $ok;

	eval {
		$pluginStatePrefs->set($entry->{'name'}, 'needs-install');
		$pluginStatePrefs->savenow;
	};
	if ($@) {
		$log->warn("Downloaded $entry->{'name'} but could not record install state: $@");
	}

	return (1, undef);
}

# Call exactly ONCE, after every plugin in the batch has already been through
# downloadPlugin() above. Reprocesses pending install state and loads the
# newly-extracted plugin code into this already-running process - the same
# two calls Slim::Web::Settings::Server::Wizard makes once its own downloads
# finish - rather than waiting on a subsequent full server restart to do it.
# $downloadedNames is an arrayref of plugin names that downloadPlugin()
# already reported success for. Returns (\@queued, \@failed).
sub finalizeInstalls {
	my $downloadedNames = shift;
	my (@queued, @failed);

	return (\@queued, \@failed) unless $downloadedNames && @{$downloadedNames};

	main::INFOLOG && $log->is_info && $log->info('Reloading plugin manager once to pick up: ' . join(', ', @{$downloadedNames}));

	eval {
		Slim::Utils::PluginManager->init();
		Slim::Utils::PluginManager->load('', @{$downloadedNames});
	};
	if ($@) {
		$log->error("Error while loading newly installed plugins: $@");
	}

	for my $name (@{$downloadedNames}) {
		if (_isAlreadyInstalled($name)) {
			push @queued, $name;
		} else {
			push @failed, "$name (downloaded, but did not load - check server.log for PluginManager/PluginDownloader errors)";
		}
	}

	return (\@queued, \@failed);
}

1;
