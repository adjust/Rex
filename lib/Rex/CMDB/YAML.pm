#
# (c) Jan Gehring <jan.gehring@gmail.com>
#
# vim: set ts=2 sw=2 tw=0:
# vim: set expandtab:

package Rex::CMDB::YAML;

use strict;
use warnings;

# VERSION

use base qw(Rex::CMDB::Base);

use Rex::Commands -no => [qw/get/];
use Rex::Logger;
use YAML;
use Data::Dumper;
use Hash::Merge qw/merge/;

require Rex::Commands::File;

sub new {
  my $that  = shift;
  my $proto = ref($that) || $that;
  my $self  = {@_};

  $self->{merger} = Hash::Merge->new();
  # file => Hash for each YAML::Load($file)
  # file => undef if file is non-existent.
  $self->{loaded} = {};

  if ( !defined $self->{merge_behavior} ) {
    $self->{merger}->specify_behavior(
      {
        SCALAR => {
          SCALAR => sub { $_[0] },
          ARRAY  => sub { $_[0] },
          HASH   => sub { $_[0] },
        },
        ARRAY => {
          SCALAR => sub { $_[0] },
          ARRAY  => sub { $_[0] },
          HASH   => sub { $_[0] },
        },
        HASH => {
          SCALAR => sub { $_[0] },
          ARRAY  => sub { $_[0] },
          HASH   => sub { Hash::Merge::_merge_hashes( $_[0], $_[1] ) },
        },
      },
      'REX_DEFAULT',
    ); # first found value always wins

    $self->{merger}->set_behavior('REX_DEFAULT');
  }
  else {
    if ( ref $self->{merge_behavior} eq 'HASH' ) {
      $self->{merger}
        ->specify_behavior( $self->{merge_behavior}, 'USER_DEFINED' );
      $self->{merger}->set_behavior('USER_DEFINED');
    }
    else {
      $self->{merger}->set_behavior( $self->{merge_behavior} );
    }
  }

  bless( $self, $proto );

  return $self;
}

sub get {
  my ( $self, $item, $server ) = @_;

  # first open $server.yml
  # second open $environment/$server.yml
  # third open $environment/default.yml
  # forth open default.yml

  my (@files);

  if ( !ref $self->{path} ) {
    my $env       = environment;
    my $yaml_path = $self->{path};
    @files = (
      "$yaml_path/$env/$server.yml", "$yaml_path/$env/default.yml",
      "$yaml_path/$server.yml",      "$yaml_path/default.yml"
    );
  }
  elsif ( ref $self->{path} eq "CODE" ) {
    @files = $self->{path}->( $self, $item, $server );
  }
  elsif ( ref $self->{path} eq "ARRAY" ) {
    @files = @{ $self->{path} };
  }

  @files = map { $self->_parse_path($_) } @files;

  my $all = {};
  Rex::Logger::debug( Dumper( \@files ) );

  # configuration variables
  my $config_values = Rex::Config->get_all;
  my %template_vars;
  for my $key ( keys %{$config_values} ) {
    if ( !exists $template_vars{$key} ) {
      $template_vars{$key} = $config_values->{$key};
    }
  }
  $template_vars{environment} = Rex::Commands::environment();

  for my $filespec (@files) {
    for my $file ($self->_expand_yaml_refs($filespec, $all)) {
      my $yaml = $self->_load($file, \%template_vars);
      next unless defined $yaml; # Nothing to merge, move on.
      $all = $self->{merger}->merge( $all, $yaml );
    }
  }

  if ( !$item ) {
    return $all;
  }
  else {
    return $all->{$item};
  }

  Rex::Logger::debug("CMDB - no item ($item) found");

  return;
}

sub _load {
    my ( $self, $file, $template_vars ) = @_;
    my $yaml;

    if ( exists $self->{loaded}->{$file} ) {
      $yaml = $self->{loaded}->{$file};
    } elsif ( -f $file ) {
      Rex::Logger::debug("CMDB - Opening $file");

      my $content = eval { local ( @ARGV, $/ ) = ($file); <>; };
      my $t = Rex::Config->get_template_function();
      $content .= "\n"; # for safety
      $content = $t->( $content, $template_vars );

      $yaml = YAML::Load($content);
      $self->{loaded}->{$file} = $yaml;

    } else {
      $self->{loaded}->{$file} = undef; # ENOENT.
    }

    return $yaml;
}

# Parse YAML references in CMDB paths using the given hashref.
# _parse_refs("cmdb/defaults/[machine.defaults].yml",
#             {machine => {defaults => "foo"}}) = ["cmdb/defaults/foo.yml"]
# References to strings and arrays of strings are supported.
# Returns a list of path names with references expanded.
# TODO: Move this to Rex::Helper::Path
# TODO: `$self` is not really necessary for the two subroutines below.
sub _expand_yaml_refs {
    my ( $self, $filespec, $yaml ) = @_;
    my @files;
    my %refmap;

    # Step 1: Replace SCALAR references, map the ARRAYs.
    my $spec = $filespec;
    for my $refspec ($filespec =~ /\[([^\]]+)\]/g) {
      my $refval = $self->_expand_yaml_ref($refspec, $yaml);
      my $reftyp = ref $refval;

      if ($reftyp eq '') { # SCALAR
        $spec =~ s/\[\Q$refspec\E\]/$refval/g;
      } elsif ($reftyp eq 'ARRAY') {
        $refmap{$refspec} = $refval;
      }
    }

    # Step 2: Replace ARRAY references, populate @files.
    push @files, $spec;
    for my $refspec (keys %refmap) {
      my @out;

      for my $refent (@{$refmap{$refspec}}) {
        my @expand = map { $_ =~ s/\[\Q$refspec\E\]/$refent/gr; } @files;
        push @out, @expand;
      }

      @files = @out;
    }

    return @files;
}

sub _expand_yaml_ref {
    my ( $self, $refspec, $yaml ) = @_;

    return $refspec unless defined $yaml;

    my $refval = $yaml;
    for my $part ( split /\./, $refspec ) {
      return $refspec unless exists $refval->{$part};
      $refval = $refval->{$part};
    }

    my $reftyp = ref $refval;

    # Return the original string unless all references were resolved
    # either to a SCALAR or ARRAY.
    return $reftyp =~ /\A(|ARRAY)/ ? $refval : $refspec;
}

1;
