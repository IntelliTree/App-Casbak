#! /usr/bin/env perl

use Test::More;
use Try::Tiny;
use Data::Dumper;
use Path::Class;
use Carp::Always;
use JSON;
use File::Spec;

use_ok('App::Casbak') or BAIL_OUT;

chdir('t') if -d 't';
-d 'cas_tmp' or BAIL_OUT('missing cas_tmp directory for testing file-based cas');

dir('./cas_tmp/casbak')->rmtree(0, 0);
mkdir('./cas_tmp/casbak')
	or die "Unable to create fresh ./cas_tmp/casbak";

my $cb;
isa_ok( ($cb=App::Casbak->init({ backupDir => './cas_tmp/casbak' })), 'App::Casbak', 'init()' );

is( $cb->backupDir, './cas_tmp/casbak', 'correct backupDir' );
isa_ok( $cb->cas, 'File::CAS', 'default cas' );
isa_ok( $cb->cas->store, 'File::CAS::Store::Simple', 'default store' );

ok( -f './cas_tmp/casbak/casbak.conf.json', 'config file exists' );
ok( -f './cas_tmp/casbak/casbak.log', 'log exists' );
ok( -f './cas_tmp/casbak/casbak.snapshots', 'snapshot index exists' );
ok( -d './cas_tmp/casbak/store', 'store created in correct dir' );

my $cb2= new_ok( 'App::Casbak', [ $cb->getConfig ], 'called new() with value of init()->getConfig' );
is_deeply( $cb2->getConfig, $cb->getConfig, 'new()->getConfig matches init()->getConfig' );

done_testing;
