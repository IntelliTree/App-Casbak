package App::Casbak::Cmd::Commands;
use Moo;
use Try::Tiny;
use Module::Runtime 'require_module', 'is_module_name';
use Log::Any '$log';

extends 'App::Casbak::Cmd';

__PACKAGE__->register_command(
	command     => 'commands',
	class       => __PACKAGE__,
	description => "Show all installed commands",
	pod         => __FILE__,
);

sub parse_argv {
	my ($class, $argv, $p)= @_;
	$p||= {};
	return $class->SUPER::parse_argv($argv, $p, {});
}

sub run {
	my $self= shift;

	my $packages= $self->find_all_subcommands();
	for my $pkg (grep { $_ ne __PACKAGE__ } @$packages) {
		my $prev_count= keys %App::Casbak::Cmd::_Commands;
		try {
			Module::Runtime::require_module($pkg);
			keys %App::Casbak::Cmd::_Commands > $prev_count?
				$log->info("loaded $pkg")
				: $log->warn("module $pkg didn't register any commands");
		}
		catch {
			$log->warn("module $pkg failed to load");
		};
	}
	my ($widest)= sort { -($a <=> $b) } map { length } keys %App::Casbak::Cmd::_Commands;
	for my $info (sort { $a->{command} cmp $b->{command} } values %App::Casbak::Cmd::_Commands) {
		printf "%*s %s\n", -$widest, $info->{command}, $info->{description};
	}
	'success';
}

__END__
=head1 NAME

casbak-commands - print a list of all installed casbak sub-commands

=head1 SYNOPSIS

