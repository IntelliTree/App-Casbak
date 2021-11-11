package App::Casbak::Logger;
use strict;
use warnings;
use parent 'Log::Any::Adapter::Base';

BEGIN {
	my %levels= (
		trace    => -2,
		debug    => -1,
		info     =>  0,
		notice   =>  1,
		warning  =>  2,
		error    =>  3,
		critical =>  4,
	);

	my $prev_level= 0;
	# We implement the stock methods, and also 'fatal' so that the
	# message written to the log starts with the proper level name.
	foreach my $method ( Log::Any->logging_methods(), 'fatal' ) {
		my $level= $prev_level= defined $levels{$method}? $levels{$method} : $prev_level;
		no strict 'refs';
		no warnings 'redefine';

		*{__PACKAGE__ . "::$method"}= ($level >= 0)
			? sub { $level > (shift)->{_filter} and print STDERR "$method: ", @_, "\n"; }
			: sub {
				return unless $level > $_[0]{_filter};
				my $self= shift;
				print STDERR
					join(' ', "$method:",
						map { !defined $_? '<undef>' : !ref $_? $_ : $self->_dump($_) } @_
					),
					"\n";
			};
		*{__PACKAGE__ . "::is_$method"}= sub { $level > (shift)->{_filter} };
	}
}

sub _dump {
	my ($self, $data)= @_;
	my $x= Data::Dumper->new([$data])->Indent(0)->Terse(1)->Useqq(1)->Quotekeys(0)->Maxdepth(4)->Sortkeys(1)->Dump;
	substr($x, 1020)= '...' if length $x >= 1024;
	$x;
}

1;