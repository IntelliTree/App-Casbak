#! /usr/bin/env perl

use Test::More;
use Try::Tiny;
use Data::Dumper;
use Path::Class;
use Carp::Always;
use JSON;
use File::Spec;
use Storable 'dclone';
use DateTime::Format::Natural;

use_ok('App::Casbak') or BAIL_OUT;

my @tests= (
	[ '2000-01-01T00:00:00Z' => '2000-01-01T00:00:00Z' ],
	[ '2000-01-01T00:00Z'    => '2000-01-01T00:00:00Z' ],
	[ '2000-01-01Z'          => '2000-01-01T00:00:00Z' ],
	[ '2000-01Z'             => '2000-01-01T00:00:00Z' ],
	[ 946684800              => '2000-01-01T00:00:00Z' ],
	[ 0                      => '1970-01-01T00:00:00Z' ],
	[ '0D'                   => '2000-01-01T00:00:00Z' ],
	[ '2D'                   => '1999-12-30T00:00:00Z' ],
	[ '1Y'                   => '1999-01-01T00:00:00Z' ],
	[ '5:00pm'               => '1999-12-31T22:00:00Z' ],
	[ '5:00'                 => '1999-12-31T10:00:00Z' ],
);
my $y2k= DateTime->from_epoch(epoch => 946684800);
my $fmt= DateTime::Format::Natural->new(
		datetime => DateTime->from_epoch(epoch => 946684800, time_zone => 'America/New_York'),
		time_zone => 'America/New_York'
	);
for (@tests) {
	my ($date, $canonical)= @$_;
	is( App::Casbak->canonical_date($date, $y2k, $fmt), $canonical );
}

done_testing;
