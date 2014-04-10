package App::Casbak;
use Moo 1.000007;
use Carp;
use Try::Tiny 0.11;
use JSON 'encode_json', 'decode_json';
use File::Spec 3.33;
use Module::Runtime 'check_module_name', 'require_module';
use DataStore::CAS::FS 0.011;
use Log::Any '$log';
#use DataStore::CAS::FS::Scanner;
#use DataStore::CAS::FS::Extractor;
require App::Casbak::Snapshot;

=head1 NAME

Casbak - backup utility built around DataStore::CAS::FS library

=head1 SYNOPSIS

  # Create a new backup
  my $cb= App::Casbak->init(
    casbak_dir => '~/backups,
    cas => 'DataStore::CAS::Simple',
    ...
  );
  
  # Store some files
  my $cb= App::Casbak->new( casbak_dir => '~/backups' );
  my $snap= $cb->get_snapshot(); # loads latest snapshot
  my $fs= DataStore::CAS::FS->new( root => $snap->root_entry );
  $cb->import_tree( fs => $fs, real => "~/foo", virt => '/' );
  $cb->save_snapshot( fs => $fs );
  
  # Extract some files
  my $snap= $cb->get_snapshot( '2013-04-01' );
  my $fs= DataStore::CAS::FS->new( root => $snap->root_entry );
  $cb->export_tree( fs => $fs, virt => '/', real => '/tmp/restore' );

=head1 DESCRIPTION

Casbak is a utility that creates backups of filesystems by storing them in
content-addressable-storage.  It is much like Git, but preserves as much
filesystem metadata as you want, and has the ability to selectively purge
old backups. (purging capability actually depends on the CAS backend; at the
moment it is designed but not implemented.  Coming soon.)

Casbak is a practical wrapper around the library DataStore::CAS::FS, which is
a virtual filesystem using DataStore::CAS as a storage backend.  If you want a
CAS implementation with fancy features like file-chunking and etc, all you
need to do is pick your favorite DataStore::CAS module, or write one yourself.
DataStore::CAS has an extremely simple API.

The Casbak utility is composed of this module (App::Casbak) and a number of
command classes under App::Casbak::Cmd namespace which implement the command
line interface.  You can easily extend Casbak by writing new perl modules in
the App::Casbak::Cmd:: namespace and adding them to your perl module path.

=cut

our $VERSION= "0.001000";

sub VersionMessage {
	require version;
	my $self= shift;
	my $v= "casbak backup utility\n"
		."Copyright (C) 2012-2013 Michael Conrad and IntelliTree Solutions llc\n"
		."App::Casbak version: ". version->parse(__PACKAGE__->VERSION)->normal ."\n"
		."DataStore::CAS::FS version: ". version->parse(DataStore::CAS::FS->VERSION)->normal ."\n"
		."DataStore::CAS version: ". version->parse(DataStore::CAS->VERSION)->normal ."\n"
		.(ref $self? ref($self->cas)." version: ". version->parse($self->cas->VERSION)->normal ."\n" : '')
		."\n"
		."casbak comes with ABSOLUTELY NO WARRANTY.\n"
		."This is free software, distributed under the same terms as Perl.\n";
	$v;
}

=head1 ATTRIBUTES

=head2 backup_dir

Directory of the Casbak files, like the configuration and the log.
The CAS itself might or might not live within this directory.

=head2 config

Plain Perl data describing the configuration of this backup.  Config should
contain all the constructor parameters needed for the rest of the lazy-built
fields.

Config itself can be lazy-built by loading the config file in backup_dir.

=head2 cas

An instance of DataStore::CAS (a subclass, since CAS is an abstract class)

Lazy-built from ->config->{cas}

=head2 scanner

An instance of DataStore::CAS::FS::Scanner, used to import files from
the real filesystem to the virtual filesystem.

Lazy-built from ->config->{scanner}

=head2 extractor

An instance of DataStore::CAS::FS::Extractor, used to export virtual files
out to the real filesystem.

Lazy-built from ->config->{extractor}

=head2 snapshot_index

A data structure describing the snapshots available in this repository.
Pay no attention to this field; instead use "get_snapshot" and related
methods.

=head2 date_format

The date formatter used to parse dates from the command line, and render them
back to the user.

The default for date_format is chosen when the backup is initialized, by
App::Casbak::Cmd::Init.  It depends on which modules are available on your
system, but DateTime::Format::Natural is the first choice.

Lazy-built from ->config->{date_format}

=head2 config_filename

Path to the config file (includes backup_dir)

=head2 log_filename

Path to the log file (includes backup_dir)

=head2 snapshot_index_filename

Path to the snapshot index (includes backup_dir)

=cut

has backup_dir         => ( is => 'ro', required => 1, default => sub { '.' } );
has config             => ( is => 'lazy' );
has cas                => ( is => 'lazy' );
has scanner            => ( is => 'lazy' );
has extractor          => ( is => 'lazy' );
has snapshot_index     => ( is => 'lazy' );
has date_format        => ( is => 'lazy' );

sub config_filename {
	File::Spec->catfile($_[0]->backup_dir, 'casbak.conf.json');
}
sub log_filename {
	File::Spec->catfile($_[0]->backup_dir, 'casbak.log');
}
sub snapshot_index_filename {
	File::Spec->catfile($_[0]->backup_dir, 'casbak.snapshots.tsv');
}

=head1 METHODS

=head2 write_log_entry( $type, $message, $data )

This writes one line of text to the log.  $type is a single string that helps
identify what sort of action was performed.  If $message is multi-line, it
will be collapsed to a single line.  $message also may not contain "{", as
this signifies the start of the $data, which is encoded as JSON.

The purpose of the log is to give the user a script-friendly transaction log
of everything that happened to the backup, in case they would like to b able
to track down lost revisions, or do forensics on a broken backup.  To this end,
App::Casbak tries to only write log entries for changes or significant events.

=cut

sub write_log_entry {
	my ($self, $type, $message, $data)= @_;
	# $type should be a single word
	$type =~ /^[A-Za-z_0-9]+$/
		or croak "Invalid log entry type: '$type'";
	# $message should never contain curly braces or newline.
	$message =~ tr/{}\n\r/()| /;
	my $line= join(' ', $self->canonical_date(time), $type, $message, encode_json($data));
	open (my $fh, '>>', $self->log_filename) or die "open(log): $!";
	(print $fh $line."\n") or die "write(log): $!";
	close $fh or die "close(log): $!";
}

=head2 canonical_date( $date_thing [, $virtual_now [, $custom_parser ]] )

Takes a date in a variety of formats and returns a string in
"YYYY-MM-DDTHH:MM:SSZ" format.

  my $date= $self->canonical_date( "2000-01-01Z" );
  my $date= $self->canonical_date( "25D" );
  my $date= $self->canonical_date( time() );
  my $date= $self->canonical_date( DateTime->new() );

Allowed formats include canonical date strings or recognizable fractions of
one, unix 'time()' integers, DateTime objects, or relative notations like
"25D" (25 days ago), "2W" (2 weeks ago), "2Y" (2 years ago), or "3M"
(3 months ago).

While mostly for testing purposes, there are two optional arguments of
'$virtual_now' and '$custom_parser'.  You can use the first to make relative
dates from a specific point in time instead of the moment the method was
called.  This *only* applies to the relative dates of the form "25D" which
are handled directly, and not by the date parser.  Your date parser might or
might not have a mechanism to override "now()".  You can use $custom_parser
to override which object is used to parse non-standard date formats.
(the usual way to specify a parser is with the ->date_format attribute,
which can be saved in the config file)

=cut

my %_suffix_to_date_field= ( D => 'days', W => 'weeks', M => 'months', Y => 'years' );
sub canonical_date {
	my ($self, $date, $now, $parser)= @_;
	if (!ref $date) {
		# is it already in a valid format?
		if ($date =~ /^\d\d\d\d-\d\d(-\d\d(T\d\d:\d\d(:\d\d)?)?)?Z$/) {
			# supply missing parts of date, after clipping off 'Z'
			# We can return here without needing to create a DateTime object.
			return substr($date, 0, -1) . substr('0000-01-01T00:00:00Z', length($date)-1);
		}

		# is it a single integer? (unix epoch time)
		if ($date =~ /^\d+$/) {
			my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)= gmtime($date);
			# We can return here without needing to create a DateTime object.
			return sprintf('%4d-%02d-%02dT%02d:%02d:%02dZ', $year+1900, $mon+1, $mday, $hour, $min, $sec);
		}

		# is it a relative date?
		if ($date =~ /^(\d+)([DWMY])$/) {
			require DateTime;
			my $dt= !defined $now? DateTime->now(time_zone => 'floating')
				: !ref $now? DateTime->from_epoch(epoch => $now, time_zone => 'floating')
				: do { my $d= $now->clone; $d->set_time_zone('floating'); $d; };
			$date= $dt->subtract($_suffix_to_date_field{$2} => $1, end_of_month => 'preserve');
		}
		# else we have to parse it
		else {
			$parser ||= $self->date_format;
			defined (my $dt= $parser->parse_datetime($date))
				or die "Invalid date: $date\n";
			# WHY!? WHY... *sigh*
			if ($parser->isa('DateTime::Format::Natural')) {
				die "Invalid date: $date\n"
					unless $parser->success;
			}
			$date= $dt;
		}
	}
	else {
		croak "Expected DateTime object but got ".ref($date)
			unless $date->isa('DateTime');
		$date= $date->clone();
	}

	# Convert timezone to UTC.  Floating is treated as local time.
	$date->set_time_zone('local')
		if ($date->time_zone eq 'floating');
	$date->set_time_zone('UTC')
		if ($date->time_zone ne 'UTC');

	return $date->ymd.'T'.$date->hms.'Z';
}

=head2 get_snapshot( $target_date )

Get the snapshot that was in effect on $target_date.  In other words, the
nearest snapshot that is older than or equal to $target_date.

Returns a Snapshot object, or undef If no snapshot existed at that time,
or if no snapshot has ever been recorded.

Throws an exception if it fails to load the snapshot entry from the CAS.

=cut

sub get_snapshot {
	my ($self, $target_date)= @_;
	my $array= $self->snapshot_index;
	return undef unless @$array;
	
	# if target_date is undef, return the latest snapshot
	my $item= defined $target_date?
		$self->_find_snapshot($array, $target_date)
		: $array->[-1];

	my ($err, $snap);
	try {
		my $file= $self->cas->get($item->[1]);
		my $dir= DataStore::CAS::FS::DirCodec->load($file);
		my $iter= $dir->iterator;
		my ($root_ent, $bogus)= ( $iter->(), $iter->() );
		defined $root_ent or die "no root entry\n";
		!defined $bogus or die "multiple root entries\n";
		defined $dir->metadata or die "metadata is missing\n";
		defined $dir->metadata->{timestamp} or die "metadata lacks a timestamp\n";
		$snap= App::Casbak::Snapshot->new(
			cas        => $self->cas,
			root_entry => $root_ent,
			metadata   => $dir->metadata,
		);
	}
	catch {
		chomp($err= $_);
	};
	die "Unable to load snapshot from $item->[1]: $err\n"
		unless defined $snap;
	return $snap;
}

sub _find_snapshot {
	my ($self, $snapshot_list, $target_date)= @_;
	$target_date= $self->canonical_date($target_date);
	# Use binary search to find the snapshot.
	# Note we are comparing date strings in canonical _T_Z form (which sort alphabetically)
	my ($min, $max, $mid)= (-1, $#$snapshot_list);
	while ($min < $max) {
		$mid= ($min+$max+1)>>1;
		if ($target_date ge $snapshot_list->[$mid][0]) {
			$min= $mid;
		} else {
			$max= $mid-1;
		}
	}
	return undef if $max < 0;
	return $snapshot_list->[$min];
}

=head2 get_snapshot_or_die( $target_date )

Like get_snapshot, except that it also throws exceptions when no backup
existed on the target date, instead of returning undef.

=cut

sub get_snapshot_or_die {
	my ($self, $date)= @_;
	$self->get_snapshot($date)
		or die defined $date? "No snapshot existed on date $date\n" : "No snapshots recorded yet\n";
}

=head2 save_snapshot( $root_entry, $metadata )

Write a new snapshot and append it to the snapshot index.

$root_entry is a DataStore::CAS::FS::DirEnt object (or HASHREF equivalent)
which you ordinarily get from an instance of DataStore::CAS::FS after making
modifications to it.  The root is a directory entry instead of a single CAS
digest hash, so that we can preserve the metadata (mode, owner, etc) of the
root directory.  It can be as simple as:

  { type => 'dir', name => '', ref => $digest_hash }

$metadata is a free-form perl data structure, which will get encoded as JSON.
The strings in it should be Unicode (or lower ASCII).  If you need to store
raw octet strings, see DataStore::CAS::FS::NonUnicode.

If this method completes without an exception, it means your new snapshot is
saved into the CAS and the snapshot has been added to the index (on disk) so
calls to get_snapshot will find it, and new instances of Casbak created on
this backup_dir will see it as well.

=cut

sub save_snapshot {
	my ($self, $root_entry, $metadata)= @_;
	
	# Default the timestamp to 'now'
	$metadata->{timestamp}= time
		unless defined $metadata->{timestamp};
	
	my $array= $self->snapshot_index;
	# Timestamps must be in cronological order
	# (we could insert-sort here, but people should only ever be adding "new" snapshots...)
	!scalar(@$array)
		or $metadata->{timestamp} ge $array->[-1][0]
		or croak "New timestamp '$metadata->{timestamp}' must be later than last recorded timestamp '$array->[-1][0]'";
	
	# Serialize the new snapshot and store it in the CAS
	my $hash= DataStore::CAS::FS::DirCodec->store($self->cas, 'universal', [ $root_entry ], $metadata);
	
	# Append the new snapshot to the end of the snapshot index
	push @$array, [ $metadata->{timestamp}, $hash, $metadata->{comment} || '' ];
	# and write the new index file
	my $err;
	try { $self->_save_snapshot_index(); } catch { chomp($err= $_); };
	die "$err\n"
		."The entry that would have been written is: '$metadata->{timestamp} $hash'\n"
		if defined $err;
	$self->write_log_entry('SNAPSHOT', "Committed snapshot $hash", { digest_hash => $hash });
	1;
}

=head2 init( $constrctor_args )

Initialize a backup_dir, with the given arguments.

The arguments should be *only* the C<backup_dir> and C<config> attributes.
The C<backup_dir> will be checked to make sure it is empty, an instance will
be created using the arguments, and all the other attributes will be built
according to C<config>.  If everything seems good, this will then write out
the Casbak config file and initialize the log and snapshot_index.

If anything fails, it should die with a (hopefully) nice user-friendly error
message.

The constructor_args get munged slightly, so don't try to re-use them.

If the CAS you specify supports a "create" parameter, it will be set to true
before we construct the object.  If you really don't want the CAS to be
created, you should explicitly set "create => 0".

CAS classes which support a "path" parameter will receive a default of
"$backup_dir/store".

=cut

sub init {
	my ($class, $ctor_args)= @_;
	Trace('Casbak->init(): ', $ctor_args);

	# Default to current dir
	my $dir= defined $ctor_args->{backup_dir}? $ctor_args->{backup_dir} : ($ctor_args->{backup_dir}= '.');
	
	# Directory must exist and be empty
	-d $dir || mkdir $dir || die "Can't create directory \"$dir\"";
	my @entries= grep { $_ ne '.' && $_ ne '..' } <$dir/*>;
	-r $dir && -w $dir && -x $dir && 0 == @entries
		or die "Backups may only be initialized in an empty writeable directory\n";

	# Record our own version in the config
	$ctor_args->{config}{VERSION}= $class->VERSION;

	# Make a copy of config, which will be saved to the config file
	require JSON;
	my $json= JSON->new->utf8->pretty->canonical->encode($ctor_args->{config});
	
	# If we're using a relative 'path', add the 'create' parameter.
	my $cas_cfg= $ctor_args->{config}{cas}[2];
	$cas_cfg->{create}= 1
		if defined $cas_cfg && !defined $cas_cfg->{create}
			&& defined $cas_cfg->{path}
			&& !File::Spec->file_name_is_absolute($cas_cfg->{path});

	# Initialize snapshotIndex to prevent it from getting loaded from a file that doesn't exist yet.
	$ctor_args->{snapshot_index}= [];

	# See if we can run the constructor
	my $self= $class->new($ctor_args);
	# Then call each of the lazy-built attributes to make sure they work
	$self->cas;
	$self->scanner;
	$self->extractor;
	$self->date_format;

	# No exceptions? Looks good.  So now we save it.

	# write config file
	$self->_overwrite_or_die($self->config_filename, $json);
	# initialize snapshot index
	$self->_save_snapshot_index();
	# initialize log file (by writing to it)
	$self->write_log_entry('INIT', "Backup initialized", decode_json($json));

	return $self;
}

# lazy-build 'config' attribute by loading it from the config file in 'backup_dir'.
sub _build_config {
	my $self= shift;
	my $cfg_file= $self->config_filename;
	-f $cfg_file or die "Missing config file '$cfg_file'\n";
	-r $cfg_file or die "Permission denied for '$cfg_file'\n";
	my ($f, $json, $cfg);
	try {
		$json= $self->_slurp_or_die($cfg_file);
		$cfg= JSON->new->utf8->relaxed->decode($json);
	}
	catch {
		my $err= "$_";
		chomp($err);
		# Clean up JSON's error messages a bit...
		if (defined($json) and ($err =~ /^(.*), at character offset (\d+)/)) {
			my $lineNum= scalar split /\n/, substr($json, 0, $2).'x';
			my $context= '"'.substr($json, $2, 10).'..."';
			$err= "$1 at line $lineNum near $context";
		}
		# and now explain to the user what's going on
		die "Unable to load config file '$cfg_file': $err\n";
	};
	# Run a version check
	__PACKAGE__->VERSION($cfg->{VERSION});
	return $cfg;
}

# get a list of constructor args for some unknown class by inspecting config->$field_name
# returns a list of ($class, @args), where @args is usually just a single hashref.
sub _get_module_constructor_args {
	my ($self, $field_name, $thing_name, $required_methods)= @_;
	my $args= $self->config->{$field_name};
	defined ($args)
		or die "No $thing_name was passed to the constructor, and config.$field_name is missing\n";
	ref $args eq 'ARRAY' and 2 <= @$args
		or die "No $thing_name was passed to the constructor, and config.$field_name is invalid\n";
	my ($class, $version, @args)= @$args;

	# Load the class, and possibly check version.
	check_module_name($class);
	require_module($class);
	$class->VERSION($version)
		if defined $version;

	# Check features of the loaded class
	$class->can($_) || die "'$class' is not a valid $thing_name class\n"
		for (ref $required_methods? @$required_methods : ( $required_methods ));
	
	# use clone of $args
	# Could use dclone, but we've already loaded the JSON module, and thats where it came from anyway
	return ( $class, @{decode_json(encode_json(\@args))} );
}

# lazy-build cas from config->{cas}
sub _build_cas {
	my $self= shift;
	my ($class, @args)= $self->_get_module_constructor_args('cas', 'CAS', 'new_write_handle');

	# If the constructor has a 'path' parameter and it is relative, we convert
	# it to be relative to backup_dir.
	if (@args == 1 && ref $args[0] eq 'HASH' && defined $args[0]->{path}) {
		$args[0]->{path}= File::Spec->rel2abs($args[0]->{path}, $self->backup_dir)
			unless File::Spec->file_name_is_absolute($args[0]->{path});
	}
	$class->new(@args);
}

# lazy-build scanner from config->{scanner}
sub _build_scanner {
	my $self= shift;
	my ($class, @args)= $self->_get_module_constructor_args('scanner', 'Scanner', 'scan_dir');
	$class->new(@args);
}

# lazy-build extractor from config->{extractor}
sub _build_extractor {
	my $self= shift;
	my ($class, @args)= $self->_get_module_constructor_args('extractor', 'Extractor', 'extract');
	$class->new(@args);
}

# lazy-build snapshot_index from the snapshot index file in backup_dir
sub _build_snapshot_index {
	my $self= shift;
	$self->_read_snapshot_index($self->snapshot_index_filename);
}

# save the current value of snapshot_index back to the index file
sub _save_snapshot_index {
	my $self= shift;
	$self->_write_snapshot_index(
		$self->snapshot_index_filename,
		$self->snapshot_index
	);
}

# lazy-build date_format from config->{date_format}
sub _build_date_format {
	my $self= shift;
	my ($class, @args)= $self->_get_module_constructor_args('date_format', 'Date Format', 'parse_datetime');
	$class->new(@args);
}

sub _slurp_or_die {
	my ($class, $filename)= @_;
	local $/= undef;
	my $f;
	open($f, '<', $filename)
		&& defined(my $data= <$f>)
		&& close($f)
		or die "read($filename): $!\n";
	$data;
}

sub _overwrite_or_die {
	my ($class, $filename, $data)= @_;
	my $f;
	open($f, ">", $filename)
		&& (print $f $data)
		&& close($f)
		or die "write($filename): $!\n";
	1;
}

sub _write_snapshot_index {
	my ($class, $index_file, $snapshot_array)= @_;
	# Build a string of TSV (tab separated values)
	my $data= join '',
		"Timestamp\tHash\tComment\n",
		(map { join("\t", @$_)."\n" } @$snapshot_array);
	# Write it to a temp file, and then rename to the official name
	my $temp_file= $index_file . '.tmp';
	$class->_overwrite_or_die($temp_file, $data);
	rename $temp_file, $index_file
		or die "Cannot replace '$index_file': $!\n";
	1;
}

sub _read_snapshot_index {
	my ($class, $index_file)= @_;
	my $tsv= $class->_slurp_or_die($index_file);
	my @lines= split /\r?\n/, $tsv;
	my $header= shift @lines;
	$header eq "Timestamp\tHash\tComment"
		or die "Invalid snapshot index (wrong header) in '$index_file'\n";
	my @entries;
	for (@lines) {
		my @fields= split /\t/, $_, 3;
		scalar(@fields) == 3
			or die "Invalid entry in '$index_file': \"$_\"\n";
		push @entries, \@fields;
	}
	\@entries;
}

1;
