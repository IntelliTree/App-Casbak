#! /usr/bin/env perl

use Test::More;

BEGIN {
	use_ok $_ or BAIL_OUT("use $_")
		for qw(
			App::Casbak
			App::Casbak::Cmd
			App::Casbak::Cmd::Init
			App::Casbak::Cmd::Import
			App::Casbak::Cmd::Export
			App::Casbak::Cmd::Ls
		);
}

diag( "Testing App::Casbak $App::Casbak::VERSION, Perl $], $^X" );
done_testing;
