#! /usr/bin/env perl

use Test::More;
use Try::Tiny;
use Data::Dumper;
use Path::Class;
use Carp::Always;
use JSON;
use File::Spec;

use_ok('App::Casbak::Cmd::Import') or BAIL_OUT;

subtest ctor => sub {
	my $cmd= new_ok( 'App::Casbak::Cmd::Import', [ ] );
	done_testing;
};

done_testing;
