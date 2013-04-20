package DataStore::CAS::FS;
use 5.008;
use strict;
use warnings;
use Carp;
use Try::Tiny;
use DataStore::CAS;
use DataStore::CAS::FS::Dir;
require File::Spec;

our $VERSION= '0.0100';
sub VersionParts {
	return (int($VERSION), (int($VERSION*100)%100), (int($VERSION*10000)%100));
}

=head1 NAME

DataStore::CAS::FS - Filesystem on top of Content-Addressable Storage

=head1 SYNOPSIS

  # Create a new empty filesystem
  my $casfs= DataStore::CAS::FS->new(
    store => DataStore::CAS::Simple->new(
      path => './foo/bar',
      create => 1,
      digest => 'SHA-256'
    )
  );
  
  # Open a multi-volume filesystem on an existing store
  $casfs= DataStore::CAS::FS->new( store => $cas, volume_dir => $digest_hash );
  
  # Open a single root directory on an existing store
  $casfs= DataStore::CAS::FS->new( store => $cas, root_dir => $digest_hash );
  
  # --- These pass through to the $cas module
  
  $hash= $casfs->put("Blah"); 
  $hash= $casfs->put_file("./foo/bar/baz");
  $file= $casfs->get($hash);
  
  # Open a path within the filesystem
  $handle= $casfs->path('','1','2','3','myfile')->open;
  
  # Make some changes
  $casfs->apply_path(['', '1', '2', 'myfile'], { ref => $some_new_file });
  $casfs->apply_path(['', '1', '2', 'myfile_copy'], { ref => $some_new_file });
  # Commit them
  $casfs->commit();
  
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

Read-only.  An instance of a class implementing 'DataStore::CAS'.

=head2 root_entry

A DataStore::CAS::Dir::Entry object describing the root of the tree.
Must be of type "dir".  Should have a name of "", but not required.
You can pick an arbitrary directory for a chroot-like-effect, but beware
of broken symlinks.

root_entry refers to an **immutable** directory.  If you make in-memory
overrides to the filesystem using apply_path or the various convenience
methods, root_entry will continue to refer to the original static filesystem.
If you then C<commit()> those changes, root_entry will be updated to refer
to the new filesystem.

You can create a list of filesystem snapshots by saving a copy of root_entry
each time you call C<commit()>.  They will all continue to exist within the
CAS.  Cleaning up the CAS is left as an exercise for the reader. (though
utility methods to help with this are planned)

=head2 case_insensitive

Read-only.  Defaults to false.  If set to true in the constructor, this causes
all directory entries to be compared in a case-insensitive manner, and all
directory objects to be loaded with case-insensitive lookup indexes.

Be careful not to share a directory cache between FS objects with opposing
case_insensitive settings.

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

sub store             { $_[0]{store} }
sub root_entry        { $_[0]{root_entry} }
sub case_insensitive  { $_[0]{case_insensitive} }

sub hash_of_null      { $_[0]->store->hash_of_null }
sub hash_of_empty_dir { $_[0]{hash_of_empty_dir} }

sub dir_cache         { $_[0]{dir_cache} }

# _path_overrides is a tree of nodes, each of the form:
# $node= {
#   entry   => $Dir_Entry,  # mandatory
#   dir     => $CAS_FS_Dir, # optional, created on demand
#   subtree => {
#     KEY1 => $node1,
#     KEY2 => $node2,
#     ...
#   }
# }
#
#  If 'case_insensitive' is true, the keys will all be upper-case, but the $Dir_Entry
#  objects will contain the correct-case name.
#
sub _path_overrides   { $_[0]{_path_overrides} }

=head1 METHODS

=head2 new( %args | \%args )

Parameters:

=over

=item store - required

An instance of DataStore::CAS

=item volume_dir - required

An instance of DataStore::CAS::FS::Dir, or an instance of DataStore::CAS::File
which contains one, or a digest hash of that File within the store.

=back

=cut

sub _calc_empty_dir_hash {
	my ($class, $store)= @_;
	my $empty= DataStore::CAS::FS::Dir->SerializeEntries([],{});
	return $store->put_scalar($empty);
}

sub new {
	my $class= shift;
	my %p= ref($_[0])? %{$_[0]} : @_;

	croak "Missing required parameter 'store'"
		unless defined $p{store};
	croak "Invalid 'store' object"
		unless ref($p{store}) && $p{store}->can('get');

	# Create dircache if not given.
	$p{dir_cache} ||= DataStore::CAS::FS::DirCache->new();

	$p{hash_of_empty_dir}= $class->_calc_empty_dir_hash($p{store})
		unless defined $p{hash_of_empty_dir};

	# Root is a more flexible parameter than 'root_entry'.  If they specify
	# it, we convert it to the equivalent root_entry parameter.
	if (defined $p{root}) {
		defined $p{root_entry}
			and croak "Specify only one of 'root' or 'root_entry'";

		my $root= delete $p{root};
		my $hash;

		# Is it a scalar digest hash?
		if (!ref $root) {
			$hash= $root;
		}
		# Is is a Dir::Entry? or a hashref intended to be one?
		elsif (ref $root eq 'HASH' or ref($root)->isa('DataStore::CAS::FS::Dir::Entry')) {
			$p{root_entry}= $root;
		}
		# Is it a ::File or ::Dir object?
		elsif (ref($root)->can('hash')) {
			$hash= $root->hash;
		}
		else {
			# Try stringifying it and looking it up in the CAS
			$hash= "$root";
		}
		
		if (defined $hash) {
			$p{root_entry}= { type => 'dir', name => '', ref => $hash };
		}
	}

	if (defined $p{root_entry}) {
		if (ref $p{root_entry} eq 'HASH') {
			$p{root_entry}= DataStore::CAS::FS::Dir::Entry->new({
				type => 'dir',
				name => '',
				ref => $p{hash_of_empty_dir},
				%{$p{root_entry}}
			});
		}
	}

	$class->_ctor(\%p);
}

=head2 get( $hash [, \%flags ])

Alias for store->get

=cut

sub get {
	(shift)->store->get(@_);
}

=head2 get_dir( $hash|$file [, \%flags ])

This returns a de-serialized directory object found by its hash.  It is a
shorthand for 'get' on the Store, and deserializing enough of the result to
create a usable DataStore::CAS::FS::Dir object (or subclass).

Also, this method caches recently used directory objects, since they are
immutable. (but woe to those who break the API and modify their directory
objects!)

Returns undef if the digest hash isn't in the store, but dies if an error
occurs while decoding one that exists.

=cut

sub get_dir {
	my ($self, $hash_or_file, $flags)= @_;
	my ($hash, $file)= (ref $hash_or_file and $hash_or_file->can('hash'))
		? ( $hash_or_file->hash, $hash_or_file )
		: ( $hash_or_file, undef );
	
	my $dir= $self->dir_cache->get($hash);
	return $dir if defined $dir;
	
	# Return undef if the directory doesn't exist.
	return undef
		unless defined ($file ||= $self->store->get($hash));
	
	# Deserialize directory.  This can throw exceptions if it isn't a valid encoding.
	$dir= DataStore::CAS::FS::Dir->new($file);
	# Cache it
	$self->dir_cache->put($dir);
	return $dir;
}

=head2 put( $thing [, \%flags ] )

Alias for store->put

=head2 put_scalar

Alias for store->put_scalar

=head2 put_file

Alias for store->put_file

=head2 put_handle

Alias for store->put_handle

=head2 validate

Alias for store->validate

=cut

sub put        { (shift)->store->put(@_) }
sub put_scalar { (shift)->store->put_scalar(@_) }
sub put_file   { (shift)->store->put_file(@_) }
sub put_handle { (shift)->store->put_handle(@_) }
sub validate   { (shift)->store->validate(@_) }

=head2 path( @path_names )

Returns a DataStore::CAS::FS::Path object which provides frendly
object-oriented access to several other methods of CAS::FS. This object does
*nothing* other than curry parameters, for your convenience.  In particular,
the path isn't resolved until you try to use it, and might not be valid.

See resolve_path for notes about @path_names.  Especially note that your path
needs to start with the volume name, which will usually be ''.  Note that
you get this already if you take an absolute path and pass it to
File::Spec->splitdir.

=cut

sub path {
	bless { filesystem => (shift), path_names => [ @_ ] },
		'DataStore::CAS::FS::Path';
}

=head2 resolve_path( \@path_names [, \%flags ] )

Returns an arrayref of DataStore::CAS::FS::Dir::Entry objects corresponding
to the canonical absolute specified path, starting with the root_entry.

First, a note on @path_names: you need to specify the volume, which for UNIX
is the empty string ''.  While volumes might seem like an unnecessary
concept, and I wasn't originally going to include that in my design, it helped
in 2 major ways: it allows us to store a regular ::Dir::Entry for the root
directory (which is useful for things like permissions and timestamp) and
allows us to record general metadata for the filesystem as a whole, within the
->metadata of the volume_dir.  As a side benefit, Windows users might
appreciate being able to save backups of multiple volumes in a way that
preserves their view of the system.  As another side benefit, it is compatible
with File::Spec->splitdir.

Next, a note on resolving paths: This function will follow symlinks in much
the same way Linux does.  If the path you specify ends with a symlink, the
result will be a Dir::Entry describing the symlink.  If the path you specify
ends with a symlink and a "" (equivalent of ending with a '/'), the symlink
will be resolved to a Dir::Entry for the target file or directory. (and if
it doesn't exist, you get an error)

Also, its worth noting that the directory objects in DataStore::CAS::FS are
strictly a tree, with no back-reference to the parent directory.  So, ".."
in the path will be resolved by removing one element from the path.  HOWEVER,
this still gives you a kernel-style resolve (rather than a shell-style resolve)
because if you specify "/1/foo/.." and foo is a symlink to "/1/2/3",
the ".." will back you up to "/1/2/" and not "/1/".

The tree-with-no-parent-reference design is also why we return an array of
the entire path, since you can't take a final directory and trace it backwards.

If the path does not exist, or cannot be resolved for some reason, this method
will either return undef or die, based on whether you provided the optional
'nodie' flag.

Flags:

=over

=item no_die => $bool

Return undef instead of dying

=item error_out => \$err_variable

If set to a scalar-ref, the scalar ref will receive the error message, if any.
You probably want to set 'nodie' as well.

=item partial => $bool

If the path doesn't exist, any missing directories will be given placeholder
Dir::Entry objects.  You can test whether the path was resolved completely by
checking whether $result->[-1]->type is defined.

=item mkdir => 1 || 2

If mkdir is 1, missing directories will be created on demand.

If mkdir is 2, 

=back

=cut

sub resolve_path {
	my ($self, $path, $flags)= @_;
	$flags ||= {};
	
	my $ret= $self->_resolve_path($path, { follow_symlinks => 1, %$flags });
	
	# Array means success, scalar means error.
	if (ref($ret) eq 'ARRAY') {
		# The user wants directory entries, not "nodes".
		$_= $_->{entry} for @$ret;
		return $ret;
	}

	# else, got an error...
	${$flags->{error_out}}= $ret
		if ref $flags->{error_out};
	croak $ret unless $flags->{no_die};
	return undef;
}

sub _resolve_path {
	my ($self, $path, $flags)= @_;

	my @path= ref($path)? @$path : File::Spec->splitdir($path);
	my @nodes= ( $self->_path_overrides || { entry => $self->root_entry } );
	
	return "Root directory must be a directory"
		unless $nodes[0]{entry}->type eq 'dir';

	my @mkdir_defaults= %{$flags->{mkdir_defaults}}
		if ref $flags->{mkdir_defaults};
	push @mkdir_defaults, type => 'dir', ref => undef;

	while (@path) {
		my $ent= $nodes[-1]{entry};
		my $dir;

		# Support for "symlink" is always UNIX-based (or compatible)
		# As support for other systems' symbolic paths are added, they
		# will be given unique '->type' values, and appropriate handling.
		if ($ent->type eq 'symlink' and $flags->{follow_symlinks}) {
			# Sanity check on symlink entry
			my $target= $ent->ref;
			defined $target and length $target
				or return 'Invalid symbolic link "'.$ent->name.'"';

			unshift @path, split('/', $target, -1);
			pop @nodes;
			
			# If an absolute link, we start over from the root
			@nodes= ( $nodes[0] )
				if $path[0] eq '';

			next;
		}

		if ($ent->type ne 'dir') {
			return 'Cannot descend into directory entry "'.$ent->name.'" of type "'.$ent->type.'"'
				unless $flags->{mkdir} > 1;
			# Here, mkdir flag converts entry into a directory
			$nodes[-1]{entry}= $ent->clone(@mkdir_defaults);
		}

		# Get the next path component, ignoring empty and '.'
		my $name= shift @path;
		next unless defined $name and length $name and ($name ne '.');

		# We handle '..' procedurally, moving up one real directory and *not* backing out of a symlink.
		# This is the same way the kernel does it, but perhaps shell behavior is preferred...
		if ($name eq '..') {
			return "Cannot access '..' at root directory"
				unless @nodes > 1;
			pop @nodes;
			next;
		}

		# If this directory has an in-memory override for this name, use it
		my $subnode;
		if ($nodes[-1]{subtree}) {
			my $key= $self->case_insensitive? uc $name : $name;
			$subnode= $nodes[-1]{subtree}{$key};
		}
		if (!defined $subnode) {
			# Else we need to find the name within the current directory

			# load it if it isn't cached
			if (!defined $nodes[-1]{dir} && defined $ent->ref) {
				defined ( $nodes[-1]{dir}= $self->get_dir($ent->ref) )
					or return 'Failed to open directory "'.$ent->name.' ('.$ent->ref.')"';
			}

			# If we're working on an available directory, try loading it
			my $subent= $nodes[-1]{dir}->get_entry($name)
				if defined $nodes[-1]{dir};
			$subnode= { entry => $subent }
				if defined $subent;
		}

		# If we haven't found one, or if it is 0 (deleted), either create or die.
		if (!$subnode) {
			# If we're supposed to create virtual entries, do so
			if ($flags->{mkdir} or $flags->{partial}) {
				$subnode= {
					entry => DataStore::CAS::FS::Dir::Entry->new(
						name => $name,
						# It is a directory if there are more path components to resolve.
						(@path? @mkdir_defaults : ())
					)
				};
			}
			# Else it doesn't exist and we fail.
			else {
				my $dir_path= File::Spec->catdir(map { $_->{entry}->name } @nodes);
				return "Directory \"$dir_path\" is not present in storage"
					unless defined $nodes[-1]{dir};
				return "No such directory entry \"$name\" at \"$dir_path\"";
			}
		}

		push @nodes, $subnode;
	}
	
	\@nodes;
}

=head2 set_path( $path, $Dir_Entry, $flags )

Temporarily override a directory entry at $path.  If $Dir_Entry is false, this
will cause $path to be unlinked.  If the name of Dir_Entry differs from the
final component of $path, it will act like a rename (which is the same as just
unlinking the old path and creating the new path)  If Dir_Entry is missing a
name, it will default to the final element of $path.

No fields of the old dir entry are used; if you want to preserve some of them,
you need to do that yourself (but see the handy ->clone(%overrides) method of
Dir::Entry)

If $path refers to nonexistent directories, they will be created as with
"mkdir -p", and receive the default metadata of C<$flags{default_dir_fields}>
(by default, nothing)  If $path travels through a non-directory (aside from
symlinks, unless C<$flags{follow_symlinks}> is set to 0) this will throw an
exception, unless you specify C<$flags{force_create}> which causes an
offending directory entry to be overwritten by a new subdirectory.

Note in particluar that if you specify

  apply_path( "/a_symlink/foo", $Dir_Entry, { follow_symlinks => 0, force_create => 1 })

"a_symlink" will be deleted and replaced with an actual directory.

None of the changes from apply_path are committed to the CAS until you call
C<commit()>.  Also, C<root_entry> does not change until you call C<commit()>,
though the root entry shown by "resolve_path" does.

You can return to the last committed state by calling C<rollback()>, which is
conceptually equivalent to C< $fs= DataStore::CAS::FS->new( $fs->root_entry ) >.

=cut

sub set_path {
	my ($self, $path, $newent, $flags)= @_;

	my $nodes= $self->_resolve_path($path, { follow_symlinks => 1, partial => 1, %$flags });
	croak $nodes unless ref $nodes;

	# replace the final entry, after applying defaults
	if (!$newent) {
		$newent= 0; # 0 means unlink
	} else {
		$newent= DataStore::CAS::FS::Dir::Entry->new({ %$newent })
			if ref $newent eq 'HASH';
		if (!(defined $newent->name && defined $newent->type)) {
			my $name= defined $newent->name? $newent->name
				: $nodes->[-1]->name;
			my $type= defined $newent->type? $newent->type
				: defined $nodes->[-1]->type? $nodes->[-1]->type
				: 'file';
			$newent= $newent->clone(name => $name, type => $type);
		}
	}
	$nodes->[-1]{entry}= $newent;
	$self->_apply_overrides($nodes);
}

=head2 update_path( $path, $changes, $flags )

Like set_path, but it applies a hashref (or arrayref) of $changes to the
directory entry which exists at the named path.  Use this to update a few
attributes of a directory entry without overwriting the entire thing.

=cut

sub update_path {
	my ($self, $path, $changes, $flags)= @_;

	my $nodes= $self->_resolve_path($path, { follow_symlinks => 1, partial => 1, %{$flags||{}} });
	croak $nodes unless ref $nodes;

	# update the final entry, after applying defaults
	my $entref= \$nodes->[-1]{entry};
	$$entref= $$entref->clone(
		defined $$entref->type? () : ( type => 'file' ),
		ref $changes eq 'HASH'? %$changes
			: ref $changes eq 'ARRAY'? @$changes
			: croak 'parameter "changes" must be a hashref or arrayref'
	);

	$self->_apply_overrides($nodes);
}

sub _apply_overrides {
	my ($self, $nodes)= @_;
	# Ensure that each node is connected to the previous via 'subtree'.
	# When we find the first connected node, we assume the rest are connected.
	my $i;
	for ($i= $#$nodes; $i > 0; $i--) {
		my $key= $self->case_insensitive? uc $nodes->[$i]{entry}->name : $nodes->[$i]{entry}->name;
		my $childref= \$nodes->[$i-1]{subtree}{$key};
		last if $$childref and $$childref eq $nodes->[$i];
		$$childref= $nodes->[$i];
	}
	# Finally, make sure the root override is set
	$self->{_path_overrides}= $nodes->[0]
		unless $i;
	1;
}

=head2 mkdir( $path )

Convenience method to create an empty directory at $path.

=cut

sub mkdir {
	my ($self, $path)= @_;
	$self->set_path($path, { type => 'dir', ref => $self->hash_of_empty_dir });
}

=head2 touch( $path )

Convenience method to update the timestamp of the directory entry at $path,
possibly creating it (as an empty file)

=cut

sub touch {
	my ($self, $path)= @_;
	$self->update_path($path, { mtime => time() });
}

=head2 unlink( $path )

Convenience method to remove the directory entry at $path.

=cut

sub unlink {
	my ($self, $path)= @_;
	$self->set_path($path, undef);
}
*rmdir = *unlink;

# TODO: write copy and move and rename

=head2 rollback

Revert the FS to the state of the last commit, or the initial state.

This basically just discards all the in-memory overrides created with
"apply_path" or its various convenience methods.

=cut

sub rollback {
	my $self= shift;
	$self->{_path_overrides}= undef;
	1;
}

=head2 commit

Merge all in-memory overrides from "apply_path" with the directories
they override to create new directories, and store those new directories
in the CAS.

After this operation, the root_entry will be changed to reflect the new
tree.

=cut

sub commit {
	my $self= shift;
	if ($self->_path_overrides) {
		my $root_node= $self->_path_overrides;
		croak "Root override must be a directory"
			unless $root_node->{entry}->type eq 'dir';
		my $hash= $self->_commit_recursive($root_node);
		$self->{root_entry}= $root_node->{entry}->clone(ref => $hash);
		$self->{_path_overrides}= undef;
	}
	1;
}

# Takes a subtree of the datastructure generated by apply_path and encodes it
# as a directory, recursively encoding any subtrees first, then returns the
# hash of that subdir.
sub _commit_recursive {
	my ($self, $node)= @_;

	my $subtree= $node->{subtree} || {};
	my @entries;

	# Walk the directory entries and filter out any that have been overridden.
	if (defined $node->{dir} || defined $node->{entry}->ref) {
		($node->{dir} ||= $self->get_dir($node->{entry}->ref))
			or croak 'Failed to open directory "'.$node->{entry}->name.' ('.$node->{entry}->ref.')"';
		
		my ($iter, $ent);
		for ($iter= $node->{dir}->iterator; defined ($ent= $iter->()); ) {
			my $key= $self->case_insensitive? uc $ent->name : $ent->name;
			push @entries, $ent
				unless defined $subtree->{$key};
		}
	}

	# Now append the modified entries.
	# Skip the "0"s, which represent files to unlink.
	for (grep { ref $_ } values %$subtree) {
		# Check if node is a dir and needs committed
		if ($_->{subtree} and $_->{entry}->type eq 'dir') {
			my $hash= $self->_commit_recursive($_);
			$_->{entry}= $_->{entry}->clone( ref => $hash );
			delete $_->{subtree};
			delete $_->{dir};
		}
		
		push @entries, $_->{entry};
	}
	# Now re-encode the directory, using the same type as orig_dir
	return $self->hash_of_empty_dir
		unless @entries;
	my $dir_cls= $node->{dir}? ref $node->{dir} : 'DataStore::CAS::FS::Dir';
	return $self->put_scalar( $dir_cls->SerializeEntries(\@entries, {}) );
}

=head1 EXTENDING

=head2 Constructor

The constructor of DataStore::CAS::FS is slightly non-standard.  The method
'new()' is in charge of all DWIM features, taking a wide range of parameters
and coercing them into the strict requirements for the constructor.  It then
passes these in a modifiable hashref to the private method '_ctor(\%params)'.

_ctor(\%params) is the actual constructor.  It should remove all the
parameters it knows about from the hashref, and then call the parent
constructor.  It should then apply its extracted parameters to the $self
object returned by the parent class.  This allows subclasses to change
the arguments that the superclass sees, and to catch invalid arguments.

=cut

our @_ctor_params= qw: store volume_dir root_entry hash_of_empty_dir dir_cache :;
sub _ctor_params { @_ctor_params }

sub _ctor {
	my ($class, $params)= @_;
	my $p= { map { $_ => delete $params->{$_} } @_ctor_params };

	# die on leftovers
	croak "Invalid parameter: ".join(', ', keys %$params)
		if (keys %$params);

	croak "Missing/Invalid parameter 'store'"
		unless defined $p->{store} and $p->{store}->can('get');

	$p->{dir_cache} ||= DataStore::CAS::FS::DirCache->new();
	croak "Missing/Invalid parameter 'dir_cache'"
		unless defined $p->{dir_cache} and $p->{dir_cache}->can('clear');

	$p->{hash_of_empty_dir}= $class->_calc_empty_dir_hash($p->{store})
		unless defined $p->{hash_of_empty_dir};

	croak "Constructor requires exactly one of volume_dir or root_entry"
		unless 1 == grep { defined } @{$p}{'volume_dir','root_entry'};

	if (defined $p->{volume_dir}) {
		croak "Invalid parameter 'volume_dir'"
			unless ref $p->{volume_dir}
				and ref($p->{volume_dir})->can('get_entry');
	}
	elsif (defined $p->{root_entry}) {
		croak "Invalid parameter 'root_entry'"
			unless ref $p->{root_entry}
				and ref($p->{root_entry})->can('type')
				and $p->{root_entry}->type eq 'dir'
				and defined $p->{root_entry}->ref;
	}

	my $self= bless $p, $class;

	# If they gave us a 'root_entry', make sure we can load it
	$self->get_dir($self->root_entry->ref)
		or croak "Unable to load root directory '".$self->root_entry->ref."'";

	return $self;
}

package DataStore::CAS::FS::Path;
use strict;
use warnings;
use Carp;

=head1 PATH OBJECTS

=cut

# main attributes
sub path_names     { $_[0]{path_names} }
sub path_ents      { $_[0]{path_ents} || $_[0]->resolve }
sub filesystem     { $_[0]{filesystem} }

# convenience accessors
sub path_name_list { @{$_[0]->path_names} }
sub path_ent_list  { @{$_[0]->path_ents} }
sub final_ent      { $_[0]->path_ents->[-1] }
sub type           { $_[0]->final_ent->type }

# methods
sub resolve {
	$_[0]{path_ents}= $_[0]{filesystem}->resolve_path($_[0]{path_names})
}

sub path {
	my $self= shift;
	bless {
		filesystem => $self->filesystem,
		path_names => [ @{$self->path_names}, @_ ]
	}, ref($self);
}

sub file       {
	defined(my $hash= $_[0]->final_ent->hash)
		or croak "Path is not a file";
	$_[0]->filesystem->get($hash);
}

sub open {
	$_[0]->file->open
}

package DataStore::CAS::FS::DirCache;
use strict;
use warnings;

=head1 DIRECTORY CACHE

Directories are uniquely identified by their hash, and directory objects are
immutable.  This creates a perfect opportunity for caching recent directories
and reusing the objects.

When you call C<$fs->get_dir($hash)>, $fs keeps a weak reference to that
directory which will persist until the directory object is garbage collected.
It will ALSO hold a strong reference to that directory for the next N calls
to C<$fs->get_dir($hash)>, where the default is 64.  You can change how many
references $fs holds by setting C<$fs->dir_cache->size(N)>.

The directory cache is *not* global, and a fresh one is created during the
constructor of the FS, if needed.  However, many FS instances can share the
same dir_cache object, and FS methods that return a new FS instance will pass
the old dir_cache object to the new instance.

If you want to implement your own dir_cache, don't bother subclassing the
built-in one; just create an object that meets this API:

=head1 size( [$new_size] )

Read/write accessor that returns the number of strong-references it will hold.

=head1 clear()

Clear all strong references and clear the weak-reference index.

=head1 get( $digest_hash )

Return a cached directory, or undef.

=head1 put( $dir )

Cache the Dir object.

=cut

sub size {
	if (@_ > 1) {
		my ($self, $new_size)= @_;
		$self->{size}= $new_size;
		$self->{_recent}= [];
		$self->{_recent_idx}= 0;
	}
	$_[0]{size};
}

sub new {
	my $class= shift;
	my %p= ref($_[0])? %{$_[0]} : @_;
	$p{size} ||= 32;
	$p{_by_hash} ||= {};
	$p{_recent} ||= [];
	$p{_recent_idx} ||= 0;
	bless \%p, $class;
}

sub clear {
	$_= undef for @{$_[0]{_recent}};
	$_[0]{_by_hash}= {};
}

sub get {
	return $_[0]{_by_hash}{$_[1]};
}

sub put {
	my ($self, $dir)= @_;
	# Hold onto a strong reference for a while.
	$self->{_recent}[ $self->{_recent_idx}++ ]= $dir;
	$self->{_recent_idx}= 0 if $self->{_recent_idx} > @{$self->{_recent}};
	# Index it using a weak reference.
	Scalar::Util::weaken( $self->{_by_hash}{$dir->hash}= $dir );
	# Now, a nifty hack: we attach an object to watch for the destriction of the
	# directory.  Lazy references will get rid of the dir object, but this cleans
	# up our _by_hash index.
	$dir->{'#DataStore::CAS::FS::DirCacheCleanup'}=
		bless [ $self->{_by_hash}, $dir->hash ], 'DataStore::CAS::FS::DirCacheCleanup';
}

package DataStore::CAS::FS::DirCacheCleanup;
use strict;
use warnings;

sub DESTROY { delete $_[0][0]{$_[0][1]}; }

1;

__END__

=head1 UNICODE vs. FILENAMES

=head2 Background

Unix operates on the philosophy that filenames are just bytes.  Much of Unix
userspace operates on the philosophy that these bytes should probably be valid
UTF-8 sequences (but of course, nothing enforces that).  Other operating
systems, like modern Windows, operate on the idea that everything is Unicode
and some backward-compatible APIs exist which can represent the Unicode as
Latin1 or whatnot on a best-effort basis.  I think the "Unicode everywhere"
philosophy is arguably a better way to go, but as this tool is primarily
designed with Unix in mind, and it is intend for saving backups of real
filesystems, it needs to be able to accurately store exactly what it find in
the filesystem.  Essentially this means it neeeds to be *able* to store
invalid UTF-8 sequences, -or- encode the octets as unicode codepoints up to
0xFF and later know to then write them out to the filesystem as octets instead
of UTF-8.

=head2 Use Cases

The primary concern is the user's experience when using this module.
While Perl has decent support for Unicode, it requires all filenames to be
strings of bytes. (i.e. strings with the unicode flag turned off)
Any time you pass a unicode string to a Perl function like open() or rename(),
perl converts it to a UTF-8 string of octets before performing the operation.
This gives you the desired result in Unix.
Unfortunately, Perl in Windows doesn't fare so well, because
it uses Windows' non-unicode API.  Reading filenames with non-latin1
characters returns garbage, and creating files with unicode strings containing
non-latin1 characters creates garbled filenames.  To properly handle unicode
outside of latin1 on Windows, you must avoid the Perl built-ins and tap
directly into the wide-character Windows API.

This creates a dilema: Should filenames be passed around the
DataStore::CAS::FS API as unicode, or octets, or some auto-detecting mix?
This dilema is further complicated because users of the library might not
have read this section of documentation, and it would be nice if The Right
Thing happened by default.

Imagine a scenario where a user has a directory named C<"\xDC"> (U with an
umlaut in latin-1) and another directory named C<"\xC3\x9C"> (U with an umlaut
in UTF-8).  "readdir" will report these as the strings I've just written, with
the unicode flag I<off>.  Modern Unix will render the first as a "?" and the
other as the U with umlaut, because it expects UTF-8 in the filesystem.

If a user is *unaware* of unicode issues, I argue it is better to pass around
strings of octets.  Example: the user is in "/home/\xC3\x9C", and calls "Cwd".
They get the string of octets C<"/home/\xD0">.  They then concatenate this
string with unicode C<"\x{1234}">.  Perl combines the two as
C<"/home/\x{C3}\x{9C}/\x{1234}">, however the C3 and 9C just silently went
from octets to unicode codepoints.  When the user tries opening the file, it
surprises them with "No such file or directory", because it tried opening
C<"/home/\xC3\x83\xC2\x9C/\xE1\x88\xB4">.

On the other hand, it would be more correct to define a class of "::FileName",
which when concatenated with a non-unicode string containing high bytes, would
encode itself as UTF-8 before returning.  This could have lots of unexpected
results though...

On Windows, perl is just generally broken for high-unicode filenames.
The octets approach works just fine for pure-ascii, meanwhile.  Those who need
unicode support will have found it from other modules, and when using this
module will also likely look for available flags to enable unicode.  However,
it might be good to emit a warning if a unicode flag isn't set.

Interesting reading for Windows: L<http://www.perlmonks.org/?node_id=526169>

=head2 Storage Formats

The storage format is supposed to be platform-independent.  JSON seems like a
good default encoding, however it requires strings to be in Unicode.  When you
encode a mix of unicode and octet strings, Perl's unicode flag is lost and
when reading them back out you can't tell which were which.  This means that
if you take a unicode-as-octets filename and encode it with JSON and decode it
again, perl will mangle it when you attempt to open the file, and fail.  It
also means that unicode-as-octets filenames will take extra bytes to encode.

The other option is to use a plain unicode string where possible, but names
which are not valid UTF-8 are written as C<{"bytes"=>$base64}>.

=head2 Conclusion

If the user is aware-enough to utf8::decode their file names, then they should
find it just as logical to utf8::decode the filenames from this module before
using them, or read this module's documentation to find the "unicode_filenames"
option.

The scanner for Windows platforms will read the UTF-16 from the Windows API,
and convert it to UTF-8 to match the behavior on Unix.  The Extractor on
Windows will reverse this process.  Extracting files with invalid UTF-8 on
Windows will fail.

The default storage format will use a Unicode-only format, and a special
notation to represent strings which are not unicode.  Other formats might
keep track of the unicode status of individual fields.

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
