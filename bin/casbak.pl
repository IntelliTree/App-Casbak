#! /usr/bin/env perl

use strict;
use warnings;

# Since this command passes through to another, and any delay
# here just adds to the user's annoyance, we try not to load
# any modules unless we absolutely have to.
# Thus, custom args processing...
my @passthrough;
my %cmds= map { $_ => 1 } qw( init import export ls log mount );
while (my $arg= shift @ARGV) {
	if (($arg =~ /^-[^-]*V/) or $arg eq '--version') {
		require App::Casbak;
		print App::Casbak::VersionMessage()."\n";
		exit 0;
	}
	if (($arg =~ /^-[^-]*?/) or $arg eq '--help') {
		require Pod::Usage;
		Pod::Usage::pod2usage(-verbose => 2, -exitcode => 1);
	}
	if (($arg =~ /^-[^-]*D/) or $arg eq '--casbak-dir') {
		push @passthrough, $arg, shift(@ARGV);
	}
	elsif (substr($arg,0,1) eq '-') {
		push @passthrough, $arg;
	}
	elsif ($cmds{$arg}) {
		push @passthrough, @ARGV;
		exec( "casbak-$arg", @passthrough )
			or exec( "casbak-$arg.pl", @passthrough )
			or die "Error: Failed to execute casbak-$arg: $?\n";
	}
	else {
		die "Unknown command '$arg'\n"
			."Commands are : ".join(', ', keys %cmds)."\n"
			."See --help\n";
	}
}

require Pod::Usage;
Pod::Usage::pod2usage(-verbose => 0, -exitcode => 2);

__END__

=head1 NAME

casbak - backup tool using File::CAS

=head1 SYNOPSIS

  casbak [--casbak-dir=PATH] [-v|-q] COMMAND [--help]
  casbak --version
  casbak --help
  
  Commands: init, import, export, log, ls, mount
  
=head1 COMMANDS

=over 12

=item init

Initialize a backup directory

=item import

Import files into a backup

=item export

Export files from a backup back to the filesystem

=item log

View a log of all modifications performed on the backup directory

=item ls

List files in the backup

=item mount

Use FUSE to mount a snapshot from the backup as a filesystem

=back

=head1 OPTIONS

The following options are available for all casbak commands:

=over 20

=item -D

=item --casbak-dir PATH

Path to the backup directory.  Defaults to "."

=item -v

=item --verbose

Enable output messages, and can be specified multiple times to enable
'INFO', then 'DEBUG', then 'TRACE'.  Verbose and quiet cancel eachother.

=item -q

=item --quiet

Disable output messages, and can be specified multiple times to disable
'NOTICE', then 'WARNING', then 'ERROR'.  Verbose and quiet cancel eachother.

=item -V

=item --version

Print the version of casbak (the utility) and File::CAS (the perl module) and exit.

=item -?

=item --help

Print this help, or help for the sub-command.

=back

=head1 EXAMPLES

  cd /path/to/backup

  # Backup the directories /usr/bin, /usr/local/bin, and /bin
  # storing each in the same-named location of the backup's hierarchy
  casbak import /usr/bin /usr/local/bin /bin
  
  # Backup the directory /tmp/new_bin as /bin in the backup's hierarchy
  casbak import /tmp/new_bin --as /bin
  
  # Restore the directory /etc from 3 days ago
  casbak export --date=3D /etc/ /etc/
  
  # List all modifications that have been performed on this backup
  casbak log
  
  # List files in /usr/local/share from 2 weeks ago without extracting them
  casbak ls -d 2W /usr/local/share
  
  # List files in /usr/local/share as of March 1st
  casbak ls --date 2012-03-01 /usr/local/share
  
  # Mount the snapshot of the filesystem from a year ago (using FUSE)
  casbak mount -d 1Y /mnt/temp

=head1 SECURITY

Some care should be taken regarding the permissions of the backup directory.
Casbak uses a plugin-heavy design.  If an attacker were able to modify the
configuration file in the backup directory, they could cause arbitrary perl
modules to be loaded.  If the attacker also had control of a directory in
perl's library path (or the environment variables of the backup script),
they would be able to execute arbitrary code as the user running casbak.
There may also be other exploits possible by modifying the backup config
file.  Ensure that only highly priveleged users have access to the backup
directory.

(Really, these precautions are common sense, as someone able to modify a
 backup, or access password files stored in the backup, or modify the
 environment of a backup script, or write to your perl module path would
 have a myriad of other ways to compromise your system.)

=cut