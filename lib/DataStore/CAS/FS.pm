package DataStore::CAS::FS;
use 5.008;
use strict;
use warnings;
use Carp;
use Try::Tiny;
use DataStore::CAS;
use DataStore::CAS::FS::Dir;
use DataStore::CAS::FS::Scanner;
use File::Spec::Functions 'catfile', 'catdir', 'canonpath';

our $VERSION= '0.0100';

=head1 NAME

DataStore::CAS::FS - Filesystem on top of Content-Addressable Storage

=head1 SYNOPSIS

  # Create a new CAS::FS backed by 'DataStore::CAS::Simple', which stores
  #   everything in plain files.
  my $casfs= DataStore::CAS::FS->new(
    store => {
      CLASS => 'Simple',
      path => './foo/bar',
      create => 1,
      digest => 'SHA-256'
    }
  );
  
  # Create a CAS::FS on an existing store
  $casfs= DataStore::CAS::FS->new( store => $cas );
  
  # --- These pass through to the $cas module
  
  $hash= $casfs->put("Blah"); 
  $hash= $casfs->put_file("./foo/bar/baz");
  $file= $casfs->get($hash);
  
  # --- These are the extensions that store directory hierarchies
  
  # Recursively store directories from the real filesystem.
  # Make sure not to include the Store's path!
  my $root_hash= $casfs->put_dir("/home/my_user/stuff");
  
  # Store the same dir again, but only look at files whose size or
  #  timestamp have changed
  my $root_hash= $casfs->put_dir("/home/my_user/stuff",
                                 { dir_hint => $root_hash });
  
  # Fetch and decode a directory by its hash
  my $dir= $cas->get_dir($root_hash);
  
  # Walk the directory to a known path
  my $stuff= $dir->subdir('home','my_user')->subdir('stuff');
  
  # Same as above, but returns a DataStore::CAS::File instead of a
  #  decoded DataStore::CAS::FS::Dir
  my $stuff= $dir->file('home','my_user','stuff');

=head1 DESCRIPTION

DataStore::CAS::FS extends the content-addressable API to support directory
objects which let you store store traditional file hierarchies in the CAS,
and look up files by a path name (so long as you know the hash of the root).

The methods provided allow you to add files from the real filesystem, export
virtual trees back to the real filesystem, and traverse the virtual directory
hierarchy.  The DataStore::CAS backend provides readable and seekable file
handles.  There is *not* any support for access control, since those
concepts are system dependent.  The module DataStore::CAS::FS::Fuse has an
implementation of permission checking appropriate for Unix.

The directories can contain arbitrary metadata, making them suitable for
backing up filesystems from Unix, Windows, or other environments.
You can also pick directory encoding plugins to more efficiently encode
just the metadata you care about.

Each directory is serialized into a file which is stored in the CAS like any
other, resulting in a very clean implementation.  You cannot determine whether
a file is a directory or not without the context of the containing directory,
and you need to know the digest hash of the root directory in order to browse
the full filesystem.  On the up side, you can store any number of filesystems
in one CAS by maintaining a list of roots.

The root's digest hash encompases all the content of the entire tree, so the
root hash will change each time you alter any directory in the tree.  But, any
unchanged files in that tree will be re-used, since they still have the same
digest hash.  You can see great applications of this design in a number of
version control systems, notably Git.

DataStore::CAS::FS is mostly a wrapper around pluggable modules that handle
the details.  The primary object involved is a DataStore::CAS storage engine,
which performs the hashing and storage, and possibly compression or slicing.
The other main component is DataStore::CAS::FS::Scanner for scanning the real
filesystem to import directories, and various directory encoding classes like
DataStore::CAS::FS::Dir::Unix used to serialize and deserialize the
directories in an efficient manner for your system.

=head1 ATTRIBUTES

=head2 store

Read-only.  An instance of a class implementing 'DataStore::CAS'

=head2 scanner

Read-write.  An instance of DataStore::CAS::FS::Scanner, or subclass.
It is responsible for scanning real filesystem directories during "putDir".
If you didn't specify one in the constructor, one will be selected
automatically.

You may alter this instance or replace it at runtime however you like.
Just be aware that encoding a directory twice with different scanner settings
might result in different encodings, which would get stored twice.

=head2 hash_of_null

Read-only.  Passes through to store->hash_of_null

=head2 hash_of_empty_dir

This returns the canonical digest hash for an empty directory.
In other words, the return value of

  put_scalar( DataStore::CAS::FS::Dir->SerializeEntries([],{}) ).

This value is cached for performance.

It is possible to encode empty directories with any plugin, so
not all empty directories will have this key, but any time the
library knows it is writing an empty directory, it will use this
value instead of recalculating the hash of an empty dir.

=cut

sub store { $_[0]{store} }

sub scanner {
	$_[0]{scanner}= $_[1] if defined $_[1];
	$_[0]{scanner}
}

sub hash_of_null { $_[0]{store}->hash_of_null }

sub hash_of_empty_dir {
	my $self= shift;
	return $self->{hash_of_empty_dir} ||=
		do {
			my $empty= DataStore::CAS::FS::Dir->SerializeEntries([],{});
			$self->put_scalar($empty);
		};
}

=head1 METHODS

=head2 new( %args | \%args )

Parameters:

=over

=item store - required

It may be a class name like 'Simple' which refers to the
namespace DataStore::CAS::, or it may be a hashref of
parameters including the key 'CLASS', or it may be a fully
constructed object.

=item scanner - optional

Allows you to specify a scanner object which is used during
"put_dir" to collect metadata about the directory entries.
May be specified as a class name, a hashref including the
key 'CLASS', or a fully constructed object.

=item filter - optional

Alias for scanner->filter.  This object will become or
replace the filter in the scanner during the constructor.

=back

=cut

sub new {
	my $class= shift;
	my %p= ref($_[0])? %{$_[0]} : @_;
	
	defined $p{store} or croak "Missing required parameter 'store'";
	
	# coercion of store parameters to Store object
	if (!ref $p{store}) {
		$p{store}= { CLASS => $p{store} };
	}
	if (ref $p{store} eq 'HASH') {
		$p{store}= { %{$p{store}} }; # clone before we make changes
		my $class= delete $p{store}{CLASS} || 'DataStore::CAS::Simple';
		_require_class($class, delete $p{store}{VERSION});
		$class->isa('DataStore::CAS')
			or croak "'$class' is not a valid CAS class\n";
		$p{store}= $class->new($p{store});
	}
	
	# coercion of scanner parameters to Scanner object
	$p{scanner} ||= { };
	if (!ref $p{scanner}) {
		$p{scanner}= { CLASS => $p{scanner} };
	}
	if (ref $p{scanner} eq 'HASH') {
		$p{scanner}= { %{$p{scanner}} }; # clone before we make changes
		my $class= delete $p{scanner}{CLASS} || 'DataStore::CAS::FS::Scanner';
		_require_class($class, delete $p{scanner}{VERSION});
		$class->isa('DataStore::CAS::FS::Scanner')
			or croak "'$class' is not a valid Scanner class\n";
		$p{scanner}= $class->new($p{scanner});
	}
	
	$class->_ctor(\%p);
}

# Dynamically load a class if needed, and check its version.
# We test whether a class is loaded with the '->new' method,
#  because every class that we dynamically load is an object.
sub _require_class {
	my ($pkg, $version)= @_;

	# We're loading user-supplied class names.  Protect against code injection.
	($pkg =~ /^[A-Za-z][A-Za-z0-9_]*(::[A-Za-z][A-Za-z0-9_]*)*$/)
		or croak "Invalid perl package name: '$pkg'\n";

	unless ($pkg->can('new')) {
		my ($fail, $err)= do {
			local $@;
			((not eval "require $pkg;"), $@);
		};
		die $err if $fail;
	}
	
	if (defined $version) {
		defined *{$pkg.'::VERSION'}
			or croak "Package '$pkg' is missing a VERSION\n";
		no strict 'refs';
		my $v= ${$pkg.'::VERSION'};
		($v >= $version)
			or croak "Package '$pkg' version '$v' is less than required '$version'\n";
	}
	
	1;
}

our @_ctor_params= qw: scanner store :;
sub _ctor_params { @_ctor_params }

sub _ctor {
	my ($class, $params)= @_;
	my $p= { map { $_ => delete $params->{$_} } @_ctor_params };

	# die on leftovers
	croak "Invalid parameter: ".join(', ', keys %$params)
		if (keys %$params);

	# Validate our sub-objects
	defined $p->{store} and $p->{store}->isa('DataStore::CAS')
		or croak "Missing/invalid parameter 'store'";
	defined $p->{scanner} and $p->{scanner}->isa('DataStore::CAS::FS::Scanner')
		or croak "Missing/invalid parameter 'scanner'";

	# Pick suitable defaults for the dircache
	$p->{_dircache}= {};
	$p->{_dircache_recent}= [];
	$p->{_dircache_recent_idx}= 0;
	$p->{_dircache_recent_mask}= 63;
	bless $p, $class;
}

=head2 get( $hash [, \%flags ])

This passes through to DataStore::CAS, which looks up the hash and either
returns a File object or undef.

=cut

sub get {
	(shift)->{store}->get(@_);
}

=head2 get_dir( $hash [, \%flags ])

This returns a de-serialized directory object found by its hash.  It is a
shorthand for 'get' on the Store, and deserializing enough of the result to
create a usable DataStore::CAS::FS::Dir object (or subclass).

Also, this method caches recently used directory objects, since they are
immutable. (but woe to those who break the API and modify their directory
objects!)

(Directories in DataStore::CAS::FS are just files which can be decoded by
 DataStore::CAS::FS::Dir (or various pluggable subclasses) to produce a set
 of DataStore::CAS::FS::Dir::Entry objects, which reference other hashes,
 which might be files or directories or other things)
 
Returns undef if the entry doesn't exist, but dies if an error occurs
while decoding one that exists.

=cut

sub get_dir {
	my ($self, $hash, $flags)= @_;
	my $dircache= $self->{_dircache};
	my $dir= $dircache->{$hash};
	unless (defined $ret) {
		my $file= $self->get($hash) or return undef;
		$dir= DataStore::CAS::FS::Dir->new($file);
		Scalar::Util::weaken($dircache->{$hash}= $dir);
		# We don't want a bunch of dead keys laying around in our cache, so we use a clever trick
		# of attaching an object to the directory whose destructor removes the key from our cache.
		# We use a blessed coderef to prevent seeing circular references while debugging.
		$dir->{_dircache_cleanup}=
			bless sub { delete $dircache->{$hash} },
				'DataStore::CAS::FS::DircacheCleanup';
	}
	# Hold a reference to any dir requested in the last N get_dir calls.
	my $i= $self->{_dircache_recent_idx}++ & $self->{_dircache_recent_mask};
	$self->{_dircache_recent}[$i]= $dir;
	$dir;
}

package DataStore::CAS::FS::DircacheCleanup;

sub DESTROY {
	&{$_[0]}; # Our 'object' is actually a blessed coderef that removes us from the cache.
}

package DataStore::CAS::FS;

sub _clear_dir_cache {
	my ($self)= @_;
	$self->{_dircache}= {};
	$self->{_dircache_recent}= [];
	$self->{_dircache_recent_idx}= 0;
}

=head2 put( $thing [, \%flags ] )

Same as DataStore::CAS, but also accepts Path::Class::Dir objects
which are passed to put_dir.

=cut

sub put {
	if (ref $_[1]) {
		goto $_[0]->can('put_dir') if ref($_[1])->isa('Path::Class::Dir');
	}
	(shift)->{store}->put(@_);
}
sub put_scalar { (shift)->{store}->put_scalar(@_) }
sub put_file   { (shift)->{store}->put_file(@_) }
sub put_handle { (shift)->{store}->put_handle(@_) }
sub validate   { (shift)->{store}->validate(@_) }

=head2 put_dir( $dir_path | Path::Class::Dir [, \%flags ] )

Pass a directory to ->scanner->store_dir, which will store it and all
subdirectories (minus those filtered by ->scanner->filter) into the CAS.

Returns the digest hash of the serialized directory.

If $flags->{dir_hint} is given, it instructs the directory scanner to
re-use the hashes of the old files whose name, size, and date match the
current state of the directory, rather than re-hashing every single file.
This makes scanning much faster, but removes the guarantee that you
actually get a complete backup of your files.
Also on the plus side, it reduces the wear and tear on your harddrive.
(but irrelevant for solid state drives)

dir_hint must be a DataStore::CAS::FS::Dir object or a hash of one that
has been stored previously.

=cut

sub put_dir {
	my ($self, $dir, $flags)= @_;
	$self->scanner->store_dir($self, $dir, $flags->{dir_hint});
}

=head2 resolve_path( $root_entry, \@path_names, [ \$error_out ] )

Returns an arrayref of DataStore::CAS::FS::Dir::Entry objects corresponding
to the specified path, starting with $root_entry.  This function essentially
performs the same operation as 'File::Spec->realpath', but for the virtual
filesystem, and gives you an array of directory entries instead of a string.

If the path contains symlinks or '..', they will be resolved properly.
Symbolic links are not followed if they are the final element of the path.
To force symbolic links to be resolved, simply append '.' to @path_names.

If the path does not exist, or cannot be resolved for some reason, this
method returns undef, and the error is stored in the optional parameter
$error_out.  If you would rather die on an unresolved path, use
'resolve_path_or_die()'.

If you want symbolic links to resolve properly, $root_entry must be the
actual root directory of the filesystem. Passing any other directory will
cause a chroot-like effect which you may or may not want.

=head2 resolve_path_or_die

Same as resolve_path, but calls 'croak' with the error message if the
resolve fails.

=head2 resolve_path_partial

Same as resolve_path, but if the path doesn't exist, any missing directories
will be given placeholder Dir::Entry objects.  You can test whether the path
was resolved completely by checking whether $result->[-1]->type is defined.

=cut

sub resolve_path {
	my ($self, $root_entry, $path, $error_out)= @_;
	my $ret= $self->_resolve_path($root_entry, $path, 0);
	return $ret if ref($ret) eq 'ARRAY';
	$$error_out= $ret;
	return undef;
}

sub resolve_path_partial {
	my ($self, $root_entry, $path, $error_out)= @_;
	my $ret= $self->_resolve_path($root_entry, $path, 1);
	return $ret if ref($ret) eq 'ARRAY';
	$$error_out= $ret;
	return undef;
}

sub resolve_path_or_die {
	my ($self, $root_entry, $path)= @_;
	my $ret= $self->_resolve_path($root_entry, $path, 0);
	return $ret if ref($ret) eq 'ARRAY';
	croak $ret;
}

sub _resolvePath {
	my ($self, $root_entry, $path, $createMissing)= @_;

	my @path= ref($path)? @$path : File::Spec->splitdir($path);
	
	my @dirents= ( $root_entry );
	return "Root directory must be a directory"
		unless $root_entry->type eq 'dir';

	while (@path) {
		my $ent= $dirents[-1];
		my $dir;

		if ($ent->type eq 'symlink') {
			# Sanity check on symlink entry
			my $target= $ent->symlink;
			defined $target and length $target
				or return 'Invalid symbolic link "'.$ent->name.'"';
			
			# Resolve the path in the link before continuing on the remainder of the current path
			# TODO: File::Spec is not quite correct here, since the link could be from a
			#   foreign system. Need to come up with a way to interpret the link in terms
			#   of the system that it came from.
			unshift @path, File::Spec->splitdir($target);
			pop @dirents;
			
			# If an absolute link, we start over from the root
			@dirents= ( $root_entry )
				if File::Spec->file_name_is_absolute($target);
			
			next;
		}

		return 'Cannot descend into directory entry "'.$ent->name.'" of type "'.$ent->type.'"'
			unless ($ent->type eq 'dir');

		# If no hash listed, directory was not stored. (i.e. --exclude option during import)
		if (defined $ent->hash) {
			$dir= $self->get_dir($ent->hash);
			defined $dir
				or return 'Failed to open directory "'.$ent->name.'"';
		}
		else {
			return 'Directory "'.File::Spec->catdir(map { $_->name } @dirents).'" is not present in storage'
				unless $createMissing;
		}

		# Get the next path component, ignoring empty and '.'
		my $name= shift @path;
		next unless defined $name and length $name and ($name ne '.');

		# We handle '..' procedurally, moving up one real directory and *not* backing out of a symlink.
		# This is the same way the kernel does it, but perhaps shell behavior is preferred...
		if ($name eq '..') {
			return "Cannot access '..' at root directory"
				unless @dirents > 1;
			pop @dirents;
		}
		# If we're working on an available directory and the sub-entry exists, append it.
		elsif (defined $dir and defined ($ent= $dir->get_entry($name))) {
			push @dirents, $ent;
		}
		# Else it doesn't exist and we either fail or create it.
		else {
			return 'No such directory entry "'.$name.'" at "'.File::Spec->catdir(map { $_->name } @dirents).'"'
				unless $createMissing;

			# Here, we create a dummy entry for the $createMissing feature.
			# It is a directory if there are more path components to resolve.
			push @dirents, DataStore::CAS::FS::Dir::Entry->new(name => $name, (@path? (type=>'dir') : ()));
		}
	}
	
	\@dirents;
}

=head1 SEE ALSO

C<Brackup> - A similar-minded backup utility written in Perl, but without the
separation between library and application and with limited FUSE performance.

L<http://git-scm.com> - The world-famous version control tool

L<http://www.fossil-scm.org> - A similar but lesser known version control tool

L<https://github.com/apenwarr/bup> - A fantastic idea for a backup tool, which
operates on top of git packfiles, but has some glaring misfeatures that make it
unsuitable for general purpose use.  (doesn't save metadata?  no way to purge
old backups??)

L<http://rdiff-backup.nongnu.org/> - A popular incremental backup tool that
works great on the small scale but fails badly at large-scale production usage.
(exit 0 sometimes even when the backup fails? chance of leaving the backup in
a permanently broken state if interrupted? record deleted files... with files,
causing spool directory backups to contain 600,000 files in one directory?
nothing to optimize the case where a user renames a dir with 20GB of data in
it?)

=cut

1;
