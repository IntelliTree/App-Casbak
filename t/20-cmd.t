#! /usr/bin/env perl

use Test::More;
use Try::Tiny;
use Data::Dumper;
use File::Spec;
try { require Carp::Always; };

use_ok( 'App::Casbak::Cmd' ) || BAIL_OUT;

package DummyCommand;
use Moo;
extends 'App::Casbak::Cmd';

sub parse_argv {
	my ($class, $argv, $p)= @_;
	goto \&App::Casbak::Cmd::parse_argv
		unless defined $p;
	$p->{dummy}= 1;
	return $class, $p;
}

package main;

sub stdout_to_buf { my $bufref= shift; open(STDOUT, '>', $bufref) || die "open(BUF): $!"; }

subtest register_command => sub {
	ok( App::Casbak::Cmd->register_command(
		command     => 'dummy',
		class       => 'DummyCommand',
		description => "Dummy Command Description",
		pod         => sub { open my $fh, '<', \qq|=head1 SYNOPSIS\n\nDummy Command Synopsis\n\n| or die "$!" },
	), 'register dummy command' );
};

subtest version => sub {
	local *STDOUT;
	stdout_to_buf(\my $buf);

	my $cmd= new_ok( 'App::Casbak::Cmd', [ want_version => 1 ], 'cmd from hash' );
	is( $cmd->run(), 'no-op', 'ran successfully' );
	like( $buf, qr/version/i, 'printed version string' );
	
	done_testing;
};

subtest help => sub {
	local *STDOUT;
	stdout_to_buf(\my $buf);

	my $cmd= new_ok( 'App::Casbak::Cmd', [ want_help => 1 ], 'cmd from hash' );
	is( $cmd->run(), 'no-op', 'ran successfully' );
	like( $buf, qr/Dummy Command Description/i, 'list of subcommands' );
	
	done_testing;
};

subtest argv => sub {
	my @tests= (
		[ '--version'                     => { want_version => 1 } ],
		[ '--help'                        => { want_help    => 1 } ],
		[ '--version --help'              => { want_version => 1, want_help => 1 } ],
		[ '-Vvvv'                         => { want_version => 1, verbosity => 3 } ],
		[ 'dummy'                         => { dummy => 1 } ],
		[ '-D abc'                        => { casbak_args => { backup_dir => 'abc' } } ],
	);
	for (@tests) {
		my ($argv, $expected)= @$_;
		my ($class, $params)= App::Casbak::Cmd->parse_argv([ split / /, $argv ]);
		is_deeply( $params, $expected, $argv );
	}
	done_testing;
};

done_testing;
