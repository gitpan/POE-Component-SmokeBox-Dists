package POE::Component::SmokeBox::Dists;

use strict;
use warnings;
use Carp;
use Cwd;
use File::Spec ();
use File::Path (qw/mkpath/);
use URI;
use File::Fetch;
use CPAN::DistnameInfo;
use IO::Zlib;
use POE qw(Wheel::Run);

use vars qw($VERSION);

$VERSION = '0.06';

sub author {
  my $package = shift;
  return $package->_spawn( @_, command => 'author' );
}

sub distro {
  my $package = shift;
  return $package->_spawn( @_, command => 'distro' );
}

sub _spawn {
  my $package = shift;
  my %opts = @_;
  $opts{lc $_} = delete $opts{$_} for grep { !/^\_/ } keys %opts;
  foreach my $mandatory ( qw(event search) ) {
     next if $opts{ $mandatory };
     carp "The '$mandatory' parameter is a mandatory requirement\n";
     return;
  }
  my $options = delete $opts{options};
  my $self = bless \%opts, $package;
  $self->{session_id} = POE::Session->create(
     package_states => [
	$self => [qw(
			_start 
			_initialise 
			_dispatch 
			_spawn_fetch 
			_fetch_err 
			_fetch_close 
			_fetch_sout 
			_fetch_serr 
			_spawn_process
			_proc_close
			_proc_sout
			_sig_child)],
     ],
     heap => $self,
     ( ref($options) eq 'HASH' ? ( options => $options ) : () ),
  )->ID();

  return $self;
}

sub _start {
  my ($kernel,$sender,$self) = @_[KERNEL,SENDER,OBJECT];
  $self->{session_id} = $_[SESSION]->ID();
  if ( $kernel == $sender and !$self->{session} ) {
	croak "Not called from another POE session and 'session' wasn't set\n";
  }
  my $sender_id;
  if ( $self->{session} ) {
    if ( my $ref = $kernel->alias_resolve( $self->{session} ) ) {
	$sender_id = $ref->ID();
    }
    else {
	croak "Could not resolve 'session' to a valid POE session\n";
    }
  }
  else {
    $sender_id = $sender->ID();
  }
  $kernel->refcount_increment( $sender_id, __PACKAGE__ );
  $self->{session} = $sender_id;
  $kernel->detach_myself() if $kernel != $sender;
  $kernel->yield( '_initialise' );
  return;
}

sub _initialise {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $return = { };

  my $smokebox_dir = File::Spec->catdir( _smokebox_dir(), '.smokebox' );
  
  mkpath $smokebox_dir if ! -d $smokebox_dir;
  if ( ! -d $smokebox_dir ) {
     $return->{error} = "Could not create smokebox directory '$smokebox_dir': $!";
     $kernel->yield( '_dispatch', $return );
     return;
  }

  $self->{return} = $return;
  $self->{sb_dir} = $smokebox_dir;

  my $packages_file = File::Spec->catfile( $smokebox_dir, '02packages.details.txt.gz' );

  $self->{pack_file} = $packages_file;

  if ( -e $packages_file ) {
     my $mtime = ( stat( $packages_file ) )[9];
     if ( $self->{force} or ( time() - $mtime > 21600 ) ) {
        $kernel->yield( '_spawn_fetch', $smokebox_dir, $self->{url} );
	return;
     }
  }
  else {
     $kernel->yield( '_spawn_fetch', $smokebox_dir, $self->{url} );
     return;
  }
  
  # if packages file exists but is older than 6 hours, fetch.
  # if packages file does not exist, fetch.
  # otherwise it exists so spawn packages processing.

  $kernel->yield( '_spawn_process' );
  return;
}

sub _dispatch {
  my ($kernel,$self,$return) = @_[KERNEL,OBJECT,ARG0];
  $return->{$_} = $self->{$_} for grep { /^\_/ } keys %{ $self };
  $kernel->post( $self->{session}, $self->{event}, $return );
  $kernel->refcount_decrement( $self->{session}, __PACKAGE__ );
  return;
}

sub _sig_child {
  $poe_kernel->sig_handled();
}

sub _spawn_fetch {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{FETCH} = POE::Wheel::Run->new(
	Program     => \&_fetch,
	ProgramArgs => [ $self->{sb_dir}, $self->{url} ],
	StdoutEvent => '_fetch_sout',
	StderrEvent => '_fetch_serr',
	ErrorEvent  => '_fetch_err',             # Event to emit on errors.
	CloseEvent  => '_fetch_close',     # Child closed all output.
  );
  $kernel->sig_child( $self->{FETCH}->PID(), '_sig_chld' ) if $self->{FETCH};
  return;
}

sub _fetch_sout {
  return;
}

sub _fetch_serr {
  return;
}

sub _fetch_err {
  return;
}

sub _fetch_close {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  delete $self->{FETCH};
  if ( -e $self->{pack_file} ) {
     $kernel->yield( '_spawn_process' );
  }
  else {
     $self->{return}->{error} = 'Could not retrieve packages file';
     $kernel->yield( '_dispatch', $self->{return} );
  }
  return;
}

sub _spawn_process {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{dists} = [ ];
  $self->{PROCESS} = POE::Wheel::Run->new(
	Program     => \&_read_packages,
	ProgramArgs => [ $self->{pack_file}, $self->{command}, $self->{search} ],
	StdoutEvent => '_proc_sout',
	StderrEvent => '_fetch_serr',
	ErrorEvent  => '_fetch_err',             # Event to emit on errors.
	CloseEvent  => '_proc_close',     # Child closed all output.
  );
  $kernel->sig_child( $self->{PROCESS}->PID(), '_sig_chld' ) if $self->{PROCESS};
  return;
}

sub _proc_sout {
  my ($self,$line) = @_[OBJECT,ARG0];
  push @{ $self->{dists} }, $line;
  return;
}

sub _proc_close {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  delete $self->{PROCESS};
  $self->{return}->{dists} = delete $self->{dists};
  $kernel->yield( '_dispatch', $self->{return} );
  return;
}

sub _read_packages {
  my ($packages_file,$command,$search) = @_;
  my $fh = IO::Zlib->new( $packages_file, "rb" ) or die "$!\n";
  my %dists;
  while (<$fh>) {
     last if /^\s*$/;
  }
  while (<$fh>) {
    chomp;
    my $path = ( split ' ', $_ )[2];
    next unless $path;
    next if exists $dists{ $path };
    my $distinfo = CPAN::DistnameInfo->new( $path );
    next unless $distinfo->filename() =~ m!(\.tar\.gz|\.tgz|\.zip)$!i;
    if ( $command eq 'author' ) {
       next unless eval { $distinfo->cpanid() =~ /$search/ };
       print $path, "\n";
    }
    else {
       next unless eval { $distinfo->distvname() =~ /$search/ };
       print $path, "\n";
    }
    $dists{ $path } = 1;
  }
  return;
}

sub _fetch {
  my $location = shift || return;
  my $url = shift;
  my @urls = qw(
    ftp://ftp.funet.fi/pub/CPAN/
    http://www.cpan.org/
    ftp://ftp.cpan.org/pub/CPAN/
  );
  unshift @urls, $url if $url;
  my $file;
  foreach my $url ( @urls ) {
    my $uri = URI->new( $url ) or next;
    my @segs = $uri->path_segments();
    pop @segs unless $segs[$#segs];
    $uri->path_segments( @segs, 'modules', '02packages.details.txt.gz' );
    my $ff = File::Fetch->new( uri => $uri->as_string() ) or next;
    $file = $ff->fetch( to => $location ) or next;
    last if $file;
  }
  return $file;
}

sub _smokebox_dir {
  return $ENV{PERL5_SMOKEBOX_DIR} 
     if  exists $ENV{PERL5_SMOKEBOX_DIR} 
     && defined $ENV{PERL5_SMOKEBOX_DIR};

  my @os_home_envs = qw( APPDATA HOME USERPROFILE WINDIR SYS$LOGIN );

  for my $env ( @os_home_envs ) {
      next unless exists $ENV{ $env };
      next unless defined $ENV{ $env } && length $ENV{ $env };
      return $ENV{ $env } if -d $ENV{ $env };
  }

  return cwd();
}

1;
__END__

=head1 NAME

POE::Component::SmokeBox::Dists - Search for CPAN distributions by cpanid or distribution name

=head1 SYNOPSIS

  use strict;
  use warnings;
  
  use POE;
  use POE::Component::SmokeBox::Dists;
  
  my $search = '^BINGOS$';
  
  POE::Session->create(
    package_states => [
  	'main' => [qw(_start _results)],
    ],
  );
  
  $poe_kernel->run();
  exit 0;
  
  sub _start {
    POE::Component::SmokeBox::Dists->author(
  	event => '_results',
  	search => $search,
    );
    return;
  }
  
  sub _results {
    my $ref = $_[ARG0];
    
    return if $ref->{error}; # Oh dear there was an error
  
    print $_, "\n" for @{ $ref->{dists} };
  
    return;
  }

=head1 DESCRIPTION

POE::Component::SmokeBox::Dists is a L<POE> component that provides non-blocking CPAN distribution 
searches. It is a wrapper around L<File::Fetch> for C<02packages.details.txt.gz> file retrieval,
L<IO::Zlib> for extraction and L<CPAN::DistnameInfo> for parsing the packages data.

Given either author ( ie. CPAN ID ) or distribution search criteria, expressed as a regular expression,
it will return to a requesting session all the CPAN distributions that match that pattern.

The component will retrieve the C<02packages.details.txt.gz> file to the C<.smokebox> directory. If
that file already exists, a newer version will only be retrieved if the file is older than 6 hours.
Specifying the C<force> parameter overrides this behaviour.

The C<02packages.details.txt.gz> is extracted and a L<CPAN::DistnameInfo> object built in order to 
run the search criteria. This process can take a little bit of time.

=head1 CONSTRUCTORS

There are two constructors:

=over

=item C<author>

Initiates an author search. Takes a number of parameters:

  'event', the name of the event to return results to, mandatory;
  'search', a regex pattern to match CPAN IDs against, mandatory;
  'session', specify an alternative session to send results to;
  'force', force the poco to refresh the packages file regardless of age;

=item C<distro>

Initiates a distribution search. Takes a number of parameters:

  'event', the name of the event to return results to, mandatory;
  'search', a regex pattern to match distributions against, mandatory;
  'session', specify an alternative session to send results to;
  'force', force the poco to refresh the packages file regardless of age;

=back

In both constructors, C<session> is only required if the component is not spawned from within
an existing L<POE::Session> or you wish the results event to be sent to an alternative 
existing L<POE::Session>.

=head1 OUTPUT EVENT

Once the component has finished, retrieving, extracting and processing an event will be sent. 

C<ARG0> will be a hashref, with the following data:

  'dists', an arrayref consisting of prefixed distributions;
  'error', only present if something went wrong with any of the stages;

=head1 ENVIRONMENT

The component uses the C<.smokebox> directory to stash the C<02packages.details.txt.gz> file.

This is usually located in the current user's home directory. Setting the environment variable C<PERL5_SMOKEBOX_DIR> will
effect where the C<.smokebox> directory is located.

=head1 AUTHOR

Chris C<BinGOs> Williams <chris@bingosnet.co.uk>

=head1 LICENSE

Copyright (C) Chris Williams

This module may be used, modified, and distributed under the same terms as Perl itself. Please see the license that came with your Perl distribution for details.

=head1 SEE ALSO

L<CPAN::DistnameInfo>

=cut
