#! /usr/bin/env perl

use Test::More;
use Try::Tiny;
use Data::Dumper;
use Path::Class;
try { require Carp::Always; };
use JSON;
use File::Spec;
use Storable 'dclone';

use_ok('App::Casbak') or BAIL_OUT;

chdir('t') || die "chdir: $!" if -d 't';
-d 'cas_tmp' or BAIL_OUT('missing cas_tmp directory for testing file-based cas');

sub cleandir {
	dir('./cas_tmp/cas_simple')->rmtree(0, 0);
	mkdir('./cas_tmp/cas_simple') || die "mkdir: $!";
	dir('./cas_tmp/casbak')->rmtree(0, 0);
	mkdir('./cas_tmp/casbak') || die "mkdir: $!";
}

my $config= {
	cas => [ 'DataStore::CAS::Simple', undef, { path => '../cas_simple' } ],
	scanner => [ 'DataStore::CAS::FS::Scanner', undef ],
	extractor => [ 'DataStore::CAS::FS::Extractor', undef ],
	date_format => [ 'DateTime::Format::Natural', undef ],
};

subtest 'snapshot_index' => sub {
	my $entries= [];
	App::Casbak->_write_snapshot_index('./cas_tmp/casbak/foo', $entries);
	is_deeply( App::Casbak->_read_snapshot_index('./cas_tmp/casbak/foo'), $entries );

	$entries= [
		[ '2000-01-01T00:00:00Z', '12345678', 'Commit Message' ],
		[ '2001-01-01T00:00:00Z', '12345678', 'Commit Message 2' ],
	];
	App::Casbak->_write_snapshot_index('./cas_tmp/casbak/foo', $entries);
	is_deeply( App::Casbak->_read_snapshot_index('./cas_tmp/casbak/foo'), $entries );

	done_testing;
};

subtest 'constructor' => sub {
	cleandir();
	subtest 'new from init' => sub {
		my $cb= isa_ok( App::Casbak->init({ backup_dir => './cas_tmp/casbak', config => dclone($config) }), 'App::Casbak' );
		ok( -f './cas_tmp/cas_simple/conf/VERSION', 'cas initialized in correct dir' )
			or diag `find ./cas_tmp`;
		ok( -f './cas_tmp/casbak/casbak.conf.json', 'casbak initialized in correct dir' );
		done_testing;
	};

	cleandir();
	subtest 'new from config' => sub {
		my $cas= new_ok( 'DataStore::CAS::Simple', [ path => './cas_tmp/cas_simple', create => 1 ], 'create a cas' );
		my $cb= new_ok( 'App::Casbak', [ backup_dir => './cas_tmp/casbak', config => $config, snapshot_index => [] ] );
		isa_ok( $cb->cas, 'DataStore::CAS::Simple' );
		done_testing;
	};

	cleandir();
	subtest 'new from objects' => sub {
		my $cas= new_ok( 'DataStore::CAS::Simple', [ path => './cas_tmp/cas_simple', create => 1 ] );
		my $cb= new_ok( 'App::Casbak', [ backup_dir => './cas_tmp/casbak', cas => $cas, snapshot_index => [] ] );
		done_testing;
	};

	done_testing;
};

done_testing;
