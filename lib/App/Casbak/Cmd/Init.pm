package App::Casbak::Cmd::Init;
use Moo;
use Try::Tiny;
use Module::Runtime 'require_module', 'is_module_name';

extends 'App::Casbak::Cmd';

has user_config => ( is => 'rw', default => sub {+{}} );

__PACKAGE__->register_command(
	command     => 'init',
	class       => __PACKAGE__,
	description => "Initialize a new backup directory",
	pod         => __FILE__
);

sub parse_argv {
	my ($class, $argv, $p)= @_;
	$p||= {};
	my $config= {};
	$p->{casbak_args}{config}= $config;
	return $class->SUPER::parse_argv($argv, $p, {
		'storage-engine|s=s' => sub { _apply_cas($config, "$_[1]") },
		'dir-type|d=s'       => sub { _apply_dirtype($config, "$_[1]") },
		'digest=s'           => sub { _apply_digest($config, "$_[1]") },
		'<>'                 => sub { _apply_nameval($config, "$_[0]") }
	});
}

sub BUILD {
	my ($self, $args)= @_;

	# Check required settings
	defined $self->user_config->{cas}{CLASS} and length $self->user_config->{cas}{CLASS}
		or die "Storage engine (-s, or cas.CLASS) is required\n";

	# apply defaults
}

sub run {
	my $self= shift;
	
	my $cfg= ($self->casbak_args->{config} ||= {});

	$cfg->{cas}= $self->_build_module_args($self->user_config->{cas});

	$cfg->{scanner}= $self->_build_module_args($self->user_config->{scanner}, 'DataStore::CAS::FS::Scanner');
	
	$cfg->{extractor}= $self->_build_module_args($self->user_config->{extractor}, 'DataStore::CAS::FS::Extractor');

	$cfg->{date_format}= $self->_build_module_args($self->user_config->{extractor}, 'DateTime::Format::Natural');

	App::Casbak->init($self->casbak_args);
	'success';
}

sub _build_module_args {
	my ($self, $cfg, $default_class)= @_;
	my $class= delete $cfg->{CLASS} || $default_class;
	require_module($class) or die "Package $class is not available\n";
	my $version;
	if (defined $cfg->{VERSION}) {
		$class->VERSION( $version= delete $cfg->{VERSION} );
	} else {
		$version= $class->VERSION;
	}
	return [ $class, $version, (keys %$cfg? $cfg : ()) ];
}

sub _apply {
	my ($config, $path, $value)= @_;
	$path= [ split /\./, $path ] unless ref $path;
	
	my $node= $config;
	for (my $i= 0; $i < $#$path; $i++) {
		my $field= $path->[$i];
		$node->{$field} ||= {};
		if (!ref $node->{$field}) {
			warn "using implied ".join('.', @$path[0..$i]).".CLASS = ".$node->{$field}."\n";
			$node->{$field}= { CLASS => $node->{$field} };
		}
		$node= $node->{$field};
	}
	warn "Multiple values specified for ".join('.', @$path).".  Using '$value'.\n"
		if defined $node->{$path->[-1]};
	$node->{$path->[-1]}= $value;
}

sub _apply_nameval {
	my ($config, $str)= @_;
	($str =~ /^([A-Za-z_][A-Za-z0-9_.]*)=(.*)/)
		or die __PACKAGE__->syntax_error("Invalid name=value pair: '$str'");
	_apply('config', $1, $2);
}

our %_store_aliases= (
	simple  => { CLASS => 'DataStore::CAS::Simple', path => 'store' },
);
sub _apply_cas {
	my ($config, $spec)= @_;
	
	if (my $opts= $_store_aliases{lc $spec}) {
		_apply($config, "cas.$_" => $opts->{$_})
			for keys %$opts;
	} else {
		is_module_name($spec) or die "Invalid store spec '$spec'\n";
		_apply($config, 'cas.CLASS' => $spec);
	}
}

our %_dir_types= ( map { $_ => 1 } qw: universal minimal unix : );
sub _apply_dirtype {
	my ($config, $spec)= @_;

	if (my $opt= $_dir_types{lc $spec}) {
		_apply($config, 'scanner.dir_format' => $opt);
	} else {
		is_module_name($spec) or die "Invalid dirtype argument '$spec'\n";
		_apply($config, 'scanner.dir_format' => $spec);
	}
}

sub _apply_digest {
	my ($config, $digest)= @_;
	_apply($config, 'cas.digest' => $digest);
}

1;

__END__
=head1 NAME

casbak-init - initialize a casbak backup directory

=head1 SYNOPSIS

casbak [options] init [-s STORE_CLASS] [-d DIR_CLASS] [name=value ...]

STORE_CLASS is one of: 'Simple'

DIR_CLASS is one of: 'Universal', 'Minimal', 'Unix'

Each name=value pair is treated as an argument to the constructor of App::Casbak.
You may use dotted notation for sub-objects, like "cas.store.digest=SHA-256".

See the documentation for App::Casbak, File::CAS, File::CAS::Store::*
and File::CAS::Scanner for all available constructor parameters.
Most of the important ones are given distinct options and described below.

=head1 OPTIONS

=over 8

=item -D

=item --casbak-dir PATH

Specify an alternate directory in which to initialize the backup.
The default is the current directory.  (this is a general option,
but repeated here for emphasis)

=item -s

=item --store STORE_SPEC

This is a shorthand convenience for "cas.store.CLASS=".  You also do
not need to specify the full class name, and can use strings like
"Simple" to refer to File::CAS::Store::Simple.

Future popular stores might also have some sort of URI spec to indicate
both the type and the connection parameters in one convenient string.

=item --digest ALGORITHM_NAME

This is a shorthand for "cas.store.digest=", and should apply to most
stores.  This controls which hash algorithm is used to hash the files.
ALGORITHM_NAME is passed directly to perl's Digest module constructor.
See "perldoc Digest" for the list available on your system.

=item -d

=item --dirtype CLASS

File::CAS can use a variety of different classes to encode directories.
This chooses the default for the store.  You can override it later if needed.

Note that the filesystem scanner determines what metadata is collected,
and this only determines which of that collected metadata can/will be
preserved in the backup.

This is a convenience for setting "cas.scanner.dirClass="

=over 12

=item Universal

use File::CAS::Dir, which encodes all metadata in JSON, which isn't terribly
efficient but stores everything you have available.

=item Minimal

use File::CAS::Dir::Minimal, which encodes only a type, name, and value
(file digest, symlink target, device node, etc) and NO metadata like uid/gid,
permissions or even mtime.  This results in a very compact listing which
doesn't take much disk space.

Note that this is not suitable for incremental ('quick') backups because it
lacks a modify-timestamp.

=item Unix

use File::CAS::Dir::Unix, which stores all the useful Unix "stat()" values
in a relatively efficient (but portable) manner.  Timestamps are not limited
by 32-bit (which will become a major factor in the coming century).

=back

=back

=head1 SECURITY

See discussion in "casbak --help"

=cut

