#!/usr/bin/env perl

# This program is part of Percona Toolkit: http://www.percona.com/software/
# See "COPYRIGHT, LICENSE, AND WARRANTY" at the end of this file for legal
# notices and disclaimers.

use strict;
use warnings FATAL => 'all';

# This tool is "fat-packed": most of its dependent modules are embedded
# in this file.  Setting %INC to this file for each module makes Perl aware
# of this so it will not try to load the module from @INC.  See the tool's
# documentation for a full list of dependencies.
BEGIN {
   $INC{$_} = __FILE__ for map { (my $pkg = "$_.pm") =~ s!::!/!g; $pkg } (qw(
      Percona::Toolkit
      OptionParser
      Lmo::Utils
      Lmo::Meta
      Lmo::Object
      Lmo::Types
      Lmo
      DSNParser
      VersionParser
      Daemon
      PodParser
      TextResultSetParser
      Advisor
      AdvisorRules
      VariableAdvisorRules
      HTTP::Micro
      VersionCheck
   ));
}

# ###########################################################################
# Percona::Toolkit package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Percona/Toolkit.pm
#   t/lib/Percona/Toolkit.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Percona::Toolkit;

our $VERSION = '3.3.0';

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Carp qw(carp cluck);
use Data::Dumper qw();

require Exporter;
our @ISA         = qw(Exporter);
our @EXPORT_OK   = qw(
   have_required_args
   Dumper
   _d
);

sub have_required_args {
   my ($args, @required_args) = @_;
   my $have_required_args = 1;
   foreach my $arg ( @required_args ) {
      if ( !defined $args->{$arg} ) {
         $have_required_args = 0;
         carp "Argument $arg is not defined";
      }
   }
   cluck unless $have_required_args;  # print backtrace
   return $have_required_args;
}

sub Dumper {
   local $Data::Dumper::Indent    = 1;
   local $Data::Dumper::Sortkeys  = 1;
   local $Data::Dumper::Quotekeys = 0;
   Data::Dumper::Dumper(@_);
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;
}
# ###########################################################################
# End Percona::Toolkit package
# ###########################################################################

# ###########################################################################
# OptionParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/OptionParser.pm
#   t/lib/OptionParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package OptionParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use List::Util qw(max);
use Getopt::Long;
use Data::Dumper;

my $POD_link_re = '[LC]<"?([^">]+)"?>';

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw();
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   my ($program_name) = $PROGRAM_NAME =~ m/([.A-Za-z-]+)$/;
   $program_name ||= $PROGRAM_NAME;
   my $home = $ENV{HOME} || $ENV{HOMEPATH} || $ENV{USERPROFILE} || '.';

   my %attributes = (
      'type'       => 1,
      'short form' => 1,
      'group'      => 1,
      'default'    => 1,
      'cumulative' => 1,
      'negatable'  => 1,
      'repeatable' => 1,  # means it can be specified more than once
   );

   my $self = {
      head1             => 'OPTIONS',        # These args are used internally
      skip_rules        => 0,                # to instantiate another Option-
      item              => '--(.*)',         # Parser obj that parses the
      attributes        => \%attributes,     # DSN OPTIONS section.  Tools
      parse_attributes  => \&_parse_attribs, # don't tinker with these args.

      %args,

      strict            => 1,  # disabled by a special rule
      program_name      => $program_name,
      opts              => {},
      got_opts          => 0,
      short_opts        => {},
      defaults          => {},
      groups            => {},
      allowed_groups    => {},
      errors            => [],
      rules             => [],  # desc of rules for --help
      mutex             => [],  # rule: opts are mutually exclusive
      atleast1          => [],  # rule: at least one opt is required
      disables          => {},  # rule: opt disables other opts 
      defaults_to       => {},  # rule: opt defaults to value of other opt
      DSNParser         => undef,
      default_files     => [
         "/etc/percona-toolkit/percona-toolkit.conf",
         "/etc/percona-toolkit/$program_name.conf",
         "$home/.percona-toolkit.conf",
         "$home/.$program_name.conf",
      ],
      types             => {
         string => 's', # standard Getopt type
         int    => 'i', # standard Getopt type
         float  => 'f', # standard Getopt type
         Hash   => 'H', # hash, formed from a comma-separated list
         hash   => 'h', # hash as above, but only if a value is given
         Array  => 'A', # array, similar to Hash
         array  => 'a', # array, similar to hash
         DSN    => 'd', # DSN
         size   => 'z', # size with kMG suffix (powers of 2^10)
         time   => 'm', # time, with an optional suffix of s/h/m/d
      },
   };

   return bless $self, $class;
}

sub get_specs {
   my ( $self, $file ) = @_;
   $file ||= $self->{file} || __FILE__;
   my @specs = $self->_pod_to_specs($file);
   $self->_parse_specs(@specs);

   open my $fh, "<", $file or die "Cannot open $file: $OS_ERROR";
   my $contents = do { local $/ = undef; <$fh> };
   close $fh;
   if ( $contents =~ m/^=head1 DSN OPTIONS/m ) {
      PTDEBUG && _d('Parsing DSN OPTIONS');
      my $dsn_attribs = {
         dsn  => 1,
         copy => 1,
      };
      my $parse_dsn_attribs = sub {
         my ( $self, $option, $attribs ) = @_;
         map {
            my $val = $attribs->{$_};
            if ( $val ) {
               $val    = $val eq 'yes' ? 1
                       : $val eq 'no'  ? 0
                       :                 $val;
               $attribs->{$_} = $val;
            }
         } keys %$attribs;
         return {
            key => $option,
            %$attribs,
         };
      };
      my $dsn_o = new OptionParser(
         description       => 'DSN OPTIONS',
         head1             => 'DSN OPTIONS',
         dsn               => 0,         # XXX don't infinitely recurse!
         item              => '\* (.)',  # key opts are a single character
         skip_rules        => 1,         # no rules before opts
         attributes        => $dsn_attribs,
         parse_attributes  => $parse_dsn_attribs,
      );
      my @dsn_opts = map {
         my $opts = {
            key  => $_->{spec}->{key},
            dsn  => $_->{spec}->{dsn},
            copy => $_->{spec}->{copy},
            desc => $_->{desc},
         };
         $opts;
      } $dsn_o->_pod_to_specs($file);
      $self->{DSNParser} = DSNParser->new(opts => \@dsn_opts);
   }

   if ( $contents =~ m/^=head1 VERSION\n\n^(.+)$/m ) {
      $self->{version} = $1;
      PTDEBUG && _d($self->{version});
   }

   return;
}

sub DSNParser {
   my ( $self ) = @_;
   return $self->{DSNParser};
};

sub get_defaults_files {
   my ( $self ) = @_;
   return @{$self->{default_files}};
}

sub _pod_to_specs {
   my ( $self, $file ) = @_;
   $file ||= $self->{file} || __FILE__;
   open my $fh, '<', $file or die "Cannot open $file: $OS_ERROR";

   my @specs = ();
   my @rules = ();
   my $para;

   local $INPUT_RECORD_SEPARATOR = '';
   while ( $para = <$fh> ) {
      next unless $para =~ m/^=head1 $self->{head1}/;
      last;
   }

   while ( $para = <$fh> ) {
      last if $para =~ m/^=over/;
      next if $self->{skip_rules};
      chomp $para;
      $para =~ s/\s+/ /g;
      $para =~ s/$POD_link_re/$1/go;
      PTDEBUG && _d('Option rule:', $para);
      push @rules, $para;
   }

   die "POD has no $self->{head1} section" unless $para;

   do {
      if ( my ($option) = $para =~ m/^=item $self->{item}/ ) {
         chomp $para;
         PTDEBUG && _d($para);
         my %attribs;

         $para = <$fh>; # read next paragraph, possibly attributes

         if ( $para =~ m/: / ) { # attributes
            $para =~ s/\s+\Z//g;
            %attribs = map {
                  my ( $attrib, $val) = split(/: /, $_);
                  die "Unrecognized attribute for --$option: $attrib"
                     unless $self->{attributes}->{$attrib};
                  ($attrib, $val);
               } split(/; /, $para);
            if ( $attribs{'short form'} ) {
               $attribs{'short form'} =~ s/-//;
            }
            $para = <$fh>; # read next paragraph, probably short help desc
         }
         else {
            PTDEBUG && _d('Option has no attributes');
         }

         $para =~ s/\s+\Z//g;
         $para =~ s/\s+/ /g;
         $para =~ s/$POD_link_re/$1/go;

         $para =~ s/\.(?:\n.*| [A-Z].*|\Z)//s;
         PTDEBUG && _d('Short help:', $para);

         die "No description after option spec $option" if $para =~ m/^=item/;

         if ( my ($base_option) =  $option =~ m/^\[no\](.*)/ ) {
            $option = $base_option;
            $attribs{'negatable'} = 1;
         }

         push @specs, {
            spec  => $self->{parse_attributes}->($self, $option, \%attribs), 
            desc  => $para
               . (defined $attribs{default} ? " (default $attribs{default})" : ''),
            group => ($attribs{'group'} ? $attribs{'group'} : 'default'),
            attributes => \%attribs
         };
      }
      while ( $para = <$fh> ) {
         last unless $para;
         if ( $para =~ m/^=head1/ ) {
            $para = undef; # Can't 'last' out of a do {} block.
            last;
         }
         last if $para =~ m/^=item /;
      }
   } while ( $para );

   die "No valid specs in $self->{head1}" unless @specs;

   close $fh;
   return @specs, @rules;
}

sub _parse_specs {
   my ( $self, @specs ) = @_;
   my %disables; # special rule that requires deferred checking

   foreach my $opt ( @specs ) {
      if ( ref $opt ) { # It's an option spec, not a rule.
         PTDEBUG && _d('Parsing opt spec:',
            map { ($_, '=>', $opt->{$_}) } keys %$opt);

         my ( $long, $short ) = $opt->{spec} =~ m/^([\w-]+)(?:\|([^!+=]*))?/;
         if ( !$long ) {
            die "Cannot parse long option from spec $opt->{spec}";
         }
         $opt->{long} = $long;

         die "Duplicate long option --$long" if exists $self->{opts}->{$long};
         $self->{opts}->{$long} = $opt;

         if ( length $long == 1 ) {
            PTDEBUG && _d('Long opt', $long, 'looks like short opt');
            $self->{short_opts}->{$long} = $long;
         }

         if ( $short ) {
            die "Duplicate short option -$short"
               if exists $self->{short_opts}->{$short};
            $self->{short_opts}->{$short} = $long;
            $opt->{short} = $short;
         }
         else {
            $opt->{short} = undef;
         }

         $opt->{is_negatable}  = $opt->{spec} =~ m/!/        ? 1 : 0;
         $opt->{is_cumulative} = $opt->{spec} =~ m/\+/       ? 1 : 0;
         $opt->{is_repeatable} = $opt->{attributes}->{repeatable} ? 1 : 0;
         $opt->{is_required}   = $opt->{desc} =~ m/required/ ? 1 : 0;

         $opt->{group} ||= 'default';
         $self->{groups}->{ $opt->{group} }->{$long} = 1;

         $opt->{value} = undef;
         $opt->{got}   = 0;

         my ( $type ) = $opt->{spec} =~ m/=(.)/;
         $opt->{type} = $type;
         PTDEBUG && _d($long, 'type:', $type);


         $opt->{spec} =~ s/=./=s/ if ( $type && $type =~ m/[HhAadzm]/ );

         if ( (my ($def) = $opt->{desc} =~ m/default\b(?: ([^)]+))?/) ) {
            $self->{defaults}->{$long} = defined $def ? $def : 1;
            PTDEBUG && _d($long, 'default:', $def);
         }

         if ( $long eq 'config' ) {
            $self->{defaults}->{$long} = join(',', $self->get_defaults_files());
         }

         if ( (my ($dis) = $opt->{desc} =~ m/(disables .*)/) ) {
            $disables{$long} = $dis;
            PTDEBUG && _d('Deferring check of disables rule for', $opt, $dis);
         }

         $self->{opts}->{$long} = $opt;
      }
      else { # It's an option rule, not a spec.
         PTDEBUG && _d('Parsing rule:', $opt); 
         push @{$self->{rules}}, $opt;
         my @participants = $self->_get_participants($opt);
         my $rule_ok = 0;

         if ( $opt =~ m/mutually exclusive|one and only one/ ) {
            $rule_ok = 1;
            push @{$self->{mutex}}, \@participants;
            PTDEBUG && _d(@participants, 'are mutually exclusive');
         }
         if ( $opt =~ m/at least one|one and only one/ ) {
            $rule_ok = 1;
            push @{$self->{atleast1}}, \@participants;
            PTDEBUG && _d(@participants, 'require at least one');
         }
         if ( $opt =~ m/default to/ ) {
            $rule_ok = 1;
            $self->{defaults_to}->{$participants[0]} = $participants[1];
            PTDEBUG && _d($participants[0], 'defaults to', $participants[1]);
         }
         if ( $opt =~ m/restricted to option groups/ ) {
            $rule_ok = 1;
            my ($groups) = $opt =~ m/groups ([\w\s\,]+)/;
            my @groups = split(',', $groups);
            %{$self->{allowed_groups}->{$participants[0]}} = map {
               s/\s+//;
               $_ => 1;
            } @groups;
         }
         if( $opt =~ m/accepts additional command-line arguments/ ) {
            $rule_ok = 1;
            $self->{strict} = 0;
            PTDEBUG && _d("Strict mode disabled by rule");
         }

         die "Unrecognized option rule: $opt" unless $rule_ok;
      }
   }

   foreach my $long ( keys %disables ) {
      my @participants = $self->_get_participants($disables{$long});
      $self->{disables}->{$long} = \@participants;
      PTDEBUG && _d('Option', $long, 'disables', @participants);
   }

   return; 
}

sub _get_participants {
   my ( $self, $str ) = @_;
   my @participants;
   foreach my $long ( $str =~ m/--(?:\[no\])?([\w-]+)/g ) {
      die "Option --$long does not exist while processing rule $str"
         unless exists $self->{opts}->{$long};
      push @participants, $long;
   }
   PTDEBUG && _d('Participants for', $str, ':', @participants);
   return @participants;
}

sub opts {
   my ( $self ) = @_;
   my %opts = %{$self->{opts}};
   return %opts;
}

sub short_opts {
   my ( $self ) = @_;
   my %short_opts = %{$self->{short_opts}};
   return %short_opts;
}

sub set_defaults {
   my ( $self, %defaults ) = @_;
   $self->{defaults} = {};
   foreach my $long ( keys %defaults ) {
      die "Cannot set default for nonexistent option $long"
         unless exists $self->{opts}->{$long};
      $self->{defaults}->{$long} = $defaults{$long};
      PTDEBUG && _d('Default val for', $long, ':', $defaults{$long});
   }
   return;
}

sub get_defaults {
   my ( $self ) = @_;
   return $self->{defaults};
}

sub get_groups {
   my ( $self ) = @_;
   return $self->{groups};
}

sub _set_option {
   my ( $self, $opt, $val ) = @_;
   my $long = exists $self->{opts}->{$opt}       ? $opt
            : exists $self->{short_opts}->{$opt} ? $self->{short_opts}->{$opt}
            : die "Getopt::Long gave a nonexistent option: $opt";
   $opt = $self->{opts}->{$long};
   if ( $opt->{is_cumulative} ) {
      $opt->{value}++;
   }
   elsif ( ($opt->{type} || '') eq 's' && $val =~ m/^--?(.+)/ ) {
      my $next_opt = $1;
      if (    exists $self->{opts}->{$next_opt}
           || exists $self->{short_opts}->{$next_opt} ) {
         $self->save_error("--$long requires a string value");
         return;
      }
      else {
         if ($opt->{is_repeatable}) {
            push @{$opt->{value}} , $val;
         }
         else {
            $opt->{value} = $val;
         }
      }
   }
   else {
      if ($opt->{is_repeatable}) {
         push @{$opt->{value}} , $val;
      }
      else {
         $opt->{value} = $val;
      }
   }
   $opt->{got} = 1;
   PTDEBUG && _d('Got option', $long, '=', $val);
}

sub get_opts {
   my ( $self ) = @_; 

   foreach my $long ( keys %{$self->{opts}} ) {
      $self->{opts}->{$long}->{got} = 0;
      $self->{opts}->{$long}->{value}
         = exists $self->{defaults}->{$long}       ? $self->{defaults}->{$long}
         : $self->{opts}->{$long}->{is_cumulative} ? 0
         : undef;
   }
   $self->{got_opts} = 0;

   $self->{errors} = [];

   if ( @ARGV && $ARGV[0] =~/^--config=/ ) {
      $ARGV[0] = substr($ARGV[0],9);
      $ARGV[0] =~ s/^'(.*)'$/$1/;
      $ARGV[0] =~ s/^"(.*)"$/$1/;
      $self->_set_option('config', shift @ARGV);
   }
   if ( @ARGV && $ARGV[0] eq "--config" ) {
      shift @ARGV;
      $self->_set_option('config', shift @ARGV);
   }
   if ( $self->has('config') ) {
      my @extra_args;
      foreach my $filename ( split(',', $self->get('config')) ) {
         eval {
            push @extra_args, $self->_read_config_file($filename);
         };
         if ( $EVAL_ERROR ) {
            if ( $self->got('config') ) {
               die $EVAL_ERROR;
            }
            elsif ( PTDEBUG ) {
               _d($EVAL_ERROR);
            }
         }
      }
      unshift @ARGV, @extra_args;
   }

   Getopt::Long::Configure('no_ignore_case', 'bundling');
   GetOptions(
      map    { $_->{spec} => sub { $self->_set_option(@_); } }
      grep   { $_->{long} ne 'config' } # --config is handled specially above.
      values %{$self->{opts}}
   ) or $self->save_error('Error parsing options');

   if ( exists $self->{opts}->{version} && $self->{opts}->{version}->{got} ) {
      if ( $self->{version} ) {
         print $self->{version}, "\n";
         exit 0;
      }
      else {
         print "Error parsing version.  See the VERSION section of the tool's documentation.\n";
         exit 1;
      }
   }

   if ( @ARGV && $self->{strict} ) {
      $self->save_error("Unrecognized command-line options @ARGV");
   }

   foreach my $mutex ( @{$self->{mutex}} ) {
      my @set = grep { $self->{opts}->{$_}->{got} } @$mutex;
      if ( @set > 1 ) {
         my $err = join(', ', map { "--$self->{opts}->{$_}->{long}" }
                      @{$mutex}[ 0 .. scalar(@$mutex) - 2] )
                 . ' and --'.$self->{opts}->{$mutex->[-1]}->{long}
                 . ' are mutually exclusive.';
         $self->save_error($err);
      }
   }

   foreach my $required ( @{$self->{atleast1}} ) {
      my @set = grep { $self->{opts}->{$_}->{got} } @$required;
      if ( @set == 0 ) {
         my $err = join(', ', map { "--$self->{opts}->{$_}->{long}" }
                      @{$required}[ 0 .. scalar(@$required) - 2] )
                 .' or --'.$self->{opts}->{$required->[-1]}->{long};
         $self->save_error("Specify at least one of $err");
      }
   }

   $self->_check_opts( keys %{$self->{opts}} );
   $self->{got_opts} = 1;
   return;
}

sub _check_opts {
   my ( $self, @long ) = @_;
   my $long_last = scalar @long;
   while ( @long ) {
      foreach my $i ( 0..$#long ) {
         my $long = $long[$i];
         next unless $long;
         my $opt  = $self->{opts}->{$long};
         if ( $opt->{got} ) {
            if ( exists $self->{disables}->{$long} ) {
               my @disable_opts = @{$self->{disables}->{$long}};
               map { $self->{opts}->{$_}->{value} = undef; } @disable_opts;
               PTDEBUG && _d('Unset options', @disable_opts,
                  'because', $long,'disables them');
            }

            if ( exists $self->{allowed_groups}->{$long} ) {

               my @restricted_groups = grep {
                  !exists $self->{allowed_groups}->{$long}->{$_}
               } keys %{$self->{groups}};

               my @restricted_opts;
               foreach my $restricted_group ( @restricted_groups ) {
                  RESTRICTED_OPT:
                  foreach my $restricted_opt (
                     keys %{$self->{groups}->{$restricted_group}} )
                  {
                     next RESTRICTED_OPT if $restricted_opt eq $long;
                     push @restricted_opts, $restricted_opt
                        if $self->{opts}->{$restricted_opt}->{got};
                  }
               }

               if ( @restricted_opts ) {
                  my $err;
                  if ( @restricted_opts == 1 ) {
                     $err = "--$restricted_opts[0]";
                  }
                  else {
                     $err = join(', ',
                               map { "--$self->{opts}->{$_}->{long}" }
                               grep { $_ } 
                               @restricted_opts[0..scalar(@restricted_opts) - 2]
                            )
                          . ' or --'.$self->{opts}->{$restricted_opts[-1]}->{long};
                  }
                  $self->save_error("--$long is not allowed with $err");
               }
            }

         }
         elsif ( $opt->{is_required} ) { 
            $self->save_error("Required option --$long must be specified");
         }

         $self->_validate_type($opt);
         if ( $opt->{parsed} ) {
            delete $long[$i];
         }
         else {
            PTDEBUG && _d('Temporarily failed to parse', $long);
         }
      }

      die "Failed to parse options, possibly due to circular dependencies"
         if @long == $long_last;
      $long_last = @long;
   }

   return;
}

sub _validate_type {
   my ( $self, $opt ) = @_;
   return unless $opt;

   if ( !$opt->{type} ) {
      $opt->{parsed} = 1;
      return;
   }

   my $val = $opt->{value};

   if ( $val && $opt->{type} eq 'm' ) {  # type time
      PTDEBUG && _d('Parsing option', $opt->{long}, 'as a time value');
      my ( $prefix, $num, $suffix ) = $val =~ m/([+-]?)(\d+)([a-z])?$/;
      if ( !$suffix ) {
         my ( $s ) = $opt->{desc} =~ m/\(suffix (.)\)/;
         $suffix = $s || 's';
         PTDEBUG && _d('No suffix given; using', $suffix, 'for',
            $opt->{long}, '(value:', $val, ')');
      }
      if ( $suffix =~ m/[smhd]/ ) {
         $val = $suffix eq 's' ? $num            # Seconds
              : $suffix eq 'm' ? $num * 60       # Minutes
              : $suffix eq 'h' ? $num * 3600     # Hours
              :                  $num * 86400;   # Days
         $opt->{value} = ($prefix || '') . $val;
         PTDEBUG && _d('Setting option', $opt->{long}, 'to', $val);
      }
      else {
         $self->save_error("Invalid time suffix for --$opt->{long}");
      }
   }
   elsif ( $val && $opt->{type} eq 'd' ) {  # type DSN
      PTDEBUG && _d('Parsing option', $opt->{long}, 'as a DSN');
      my $prev = {};
      my $from_key = $self->{defaults_to}->{ $opt->{long} };
      if ( $from_key ) {
         PTDEBUG && _d($opt->{long}, 'DSN copies from', $from_key, 'DSN');
         if ( $self->{opts}->{$from_key}->{parsed} ) {
            $prev = $self->{opts}->{$from_key}->{value};
         }
         else {
            PTDEBUG && _d('Cannot parse', $opt->{long}, 'until',
               $from_key, 'parsed');
            return;
         }
      }
      my $defaults = $self->{DSNParser}->parse_options($self);
      if (!$opt->{attributes}->{repeatable}) {
          $opt->{value} = $self->{DSNParser}->parse($val, $prev, $defaults);
      } else {
          my $values = [];
          for my $dsn_string (@$val) {
              push @$values, $self->{DSNParser}->parse($dsn_string, $prev, $defaults);
          }
          $opt->{value} = $values;
      }
   }
   elsif ( $val && $opt->{type} eq 'z' ) {  # type size
      PTDEBUG && _d('Parsing option', $opt->{long}, 'as a size value');
      $self->_parse_size($opt, $val);
   }
   elsif ( $opt->{type} eq 'H' || (defined $val && $opt->{type} eq 'h') ) {
      $opt->{value} = { map { $_ => 1 } split(/(?<!\\),\s*/, ($val || '')) };
   }
   elsif ( $opt->{type} eq 'A' || (defined $val && $opt->{type} eq 'a') ) {
      $opt->{value} = [ split(/(?<!\\),\s*/, ($val || '')) ];
   }
   else {
      PTDEBUG && _d('Nothing to validate for option',
         $opt->{long}, 'type', $opt->{type}, 'value', $val);
   }

   $opt->{parsed} = 1;
   return;
}

sub get {
   my ( $self, $opt ) = @_;
   my $long = (length $opt == 1 ? $self->{short_opts}->{$opt} : $opt);
   die "Option $opt does not exist"
      unless $long && exists $self->{opts}->{$long};
   return $self->{opts}->{$long}->{value};
}

sub got {
   my ( $self, $opt ) = @_;
   my $long = (length $opt == 1 ? $self->{short_opts}->{$opt} : $opt);
   die "Option $opt does not exist"
      unless $long && exists $self->{opts}->{$long};
   return $self->{opts}->{$long}->{got};
}

sub has {
   my ( $self, $opt ) = @_;
   my $long = (length $opt == 1 ? $self->{short_opts}->{$opt} : $opt);
   return defined $long ? exists $self->{opts}->{$long} : 0;
}

sub set {
   my ( $self, $opt, $val ) = @_;
   my $long = (length $opt == 1 ? $self->{short_opts}->{$opt} : $opt);
   die "Option $opt does not exist"
      unless $long && exists $self->{opts}->{$long};
   $self->{opts}->{$long}->{value} = $val;
   return;
}

sub save_error {
   my ( $self, $error ) = @_;
   push @{$self->{errors}}, $error;
   return;
}

sub errors {
   my ( $self ) = @_;
   return $self->{errors};
}

sub usage {
   my ( $self ) = @_;
   warn "No usage string is set" unless $self->{usage}; # XXX
   return "Usage: " . ($self->{usage} || '') . "\n";
}

sub descr {
   my ( $self ) = @_;
   warn "No description string is set" unless $self->{description}; # XXX
   my $descr  = ($self->{description} || $self->{program_name} || '')
              . "  For more details, please use the --help option, "
              . "or try 'perldoc $PROGRAM_NAME' "
              . "for complete documentation.";
   $descr = join("\n", $descr =~ m/(.{0,80})(?:\s+|$)/g)
      unless $ENV{DONT_BREAK_LINES};
   $descr =~ s/ +$//mg;
   return $descr;
}

sub usage_or_errors {
   my ( $self, $file, $return ) = @_;
   $file ||= $self->{file} || __FILE__;

   if ( !$self->{description} || !$self->{usage} ) {
      PTDEBUG && _d("Getting description and usage from SYNOPSIS in", $file);
      my %synop = $self->_parse_synopsis($file);
      $self->{description} ||= $synop{description};
      $self->{usage}       ||= $synop{usage};
      PTDEBUG && _d("Description:", $self->{description},
         "\nUsage:", $self->{usage});
   }

   if ( $self->{opts}->{help}->{got} ) {
      print $self->print_usage() or die "Cannot print usage: $OS_ERROR";
      exit 0 unless $return;
   }
   elsif ( scalar @{$self->{errors}} ) {
      print $self->print_errors() or die "Cannot print errors: $OS_ERROR";
      exit 1 unless $return;
   }

   return;
}

sub print_errors {
   my ( $self ) = @_;
   my $usage = $self->usage() . "\n";
   if ( (my @errors = @{$self->{errors}}) ) {
      $usage .= join("\n  * ", 'Errors in command-line arguments:', @errors)
              . "\n";
   }
   return $usage . "\n" . $self->descr();
}

sub print_usage {
   my ( $self ) = @_;
   die "Run get_opts() before print_usage()" unless $self->{got_opts};
   my @opts = values %{$self->{opts}};

   my $maxl = max(
      map {
         length($_->{long})               # option long name
         + ($_->{is_negatable} ? 4 : 0)   # "[no]" if opt is negatable
         + ($_->{type} ? 2 : 0)           # "=x" where x is the opt type
      }
      @opts);

   my $maxs = max(0,
      map {
         length($_)
         + ($self->{opts}->{$_}->{is_negatable} ? 4 : 0)
         + ($self->{opts}->{$_}->{type} ? 2 : 0)
      }
      values %{$self->{short_opts}});

   my $lcol = max($maxl, ($maxs + 3));
   my $rcol = 80 - $lcol - 6;
   my $rpad = ' ' x ( 80 - $rcol );

   $maxs = max($lcol - 3, $maxs);

   my $usage = $self->descr() . "\n" . $self->usage();

   my @groups = reverse sort grep { $_ ne 'default'; } keys %{$self->{groups}};
   push @groups, 'default';

   foreach my $group ( reverse @groups ) {
      $usage .= "\n".($group eq 'default' ? 'Options' : $group).":\n\n";
      foreach my $opt (
         sort { $a->{long} cmp $b->{long} }
         grep { $_->{group} eq $group }
         @opts )
      {
         my $long  = $opt->{is_negatable} ? "[no]$opt->{long}" : $opt->{long};
         my $short = $opt->{short};
         my $desc  = $opt->{desc};

         $long .= $opt->{type} ? "=$opt->{type}" : "";

         if ( $opt->{type} && $opt->{type} eq 'm' ) {
            my ($s) = $desc =~ m/\(suffix (.)\)/;
            $s    ||= 's';
            $desc =~ s/\s+\(suffix .\)//;
            $desc .= ".  Optional suffix s=seconds, m=minutes, h=hours, "
                   . "d=days; if no suffix, $s is used.";
         }
         $desc = join("\n$rpad", grep { $_ } $desc =~ m/(.{0,$rcol}(?!\W))(?:\s+|(?<=\W)|$)/g);
         $desc =~ s/ +$//mg;
         if ( $short ) {
            $usage .= sprintf("  --%-${maxs}s -%s  %s\n", $long, $short, $desc);
         }
         else {
            $usage .= sprintf("  --%-${lcol}s  %s\n", $long, $desc);
         }
      }
   }

   $usage .= "\nOption types: s=string, i=integer, f=float, h/H/a/A=comma-separated list, d=DSN, z=size, m=time\n";

   if ( (my @rules = @{$self->{rules}}) ) {
      $usage .= "\nRules:\n\n";
      $usage .= join("\n", map { "  $_" } @rules) . "\n";
   }
   if ( $self->{DSNParser} ) {
      $usage .= "\n" . $self->{DSNParser}->usage();
   }
   $usage .= "\nOptions and values after processing arguments:\n\n";
   foreach my $opt ( sort { $a->{long} cmp $b->{long} } @opts ) {
      my $val   = $opt->{value};
      my $type  = $opt->{type} || '';
      my $bool  = $opt->{spec} =~ m/^[\w-]+(?:\|[\w-])?!?$/;
      $val      = $bool              ? ( $val ? 'TRUE' : 'FALSE' )
                : !defined $val      ? '(No value)'
                : $type eq 'd'       ? $self->{DSNParser}->as_string($val)
                : $type =~ m/H|h/    ? join(',', sort keys %$val)
                : $type =~ m/A|a/    ? join(',', @$val)
                :                    $val;
      $usage .= sprintf("  --%-${lcol}s  %s\n", $opt->{long}, $val);
   }
   return $usage;
}

sub prompt_noecho {
   shift @_ if ref $_[0] eq __PACKAGE__;
   my ( $prompt ) = @_;
   local $OUTPUT_AUTOFLUSH = 1;
   print STDERR $prompt
      or die "Cannot print: $OS_ERROR";
   my $response;
   eval {
      require Term::ReadKey;
      Term::ReadKey::ReadMode('noecho');
      chomp($response = <STDIN>);
      Term::ReadKey::ReadMode('normal');
      print "\n"
         or die "Cannot print: $OS_ERROR";
   };
   if ( $EVAL_ERROR ) {
      die "Cannot read response; is Term::ReadKey installed? $EVAL_ERROR";
   }
   return $response;
}

sub _read_config_file {
   my ( $self, $filename ) = @_;
   open my $fh, "<", $filename or die "Cannot open $filename: $OS_ERROR\n";
   my @args;
   my $prefix = '--';
   my $parse  = 1;

   LINE:
   while ( my $line = <$fh> ) {
      chomp $line;
      next LINE if $line =~ m/^\s*(?:\#|\;|$)/;
      $line =~ s/\s+#.*$//g;
      $line =~ s/^\s+|\s+$//g;
      if ( $line eq '--' ) {
         $prefix = '';
         $parse  = 0;
         next LINE;
      }

      if (  $parse
            && !$self->has('version-check')
            && $line =~ /version-check/
      ) {
         next LINE;
      }

      if ( $parse
         && (my($opt, $arg) = $line =~ m/^\s*([^=\s]+?)(?:\s*=\s*(.*?)\s*)?$/)
      ) {
         push @args, grep { defined $_ } ("$prefix$opt", $arg);
      }
      elsif ( $line =~ m/./ ) {
         push @args, $line;
      }
      else {
         die "Syntax error in file $filename at line $INPUT_LINE_NUMBER";
      }
   }
   close $fh;
   return @args;
}

sub read_para_after {
   my ( $self, $file, $regex ) = @_;
   open my $fh, "<", $file or die "Can't open $file: $OS_ERROR";
   local $INPUT_RECORD_SEPARATOR = '';
   my $para;
   while ( $para = <$fh> ) {
      next unless $para =~ m/^=pod$/m;
      last;
   }
   while ( $para = <$fh> ) {
      next unless $para =~ m/$regex/;
      last;
   }
   $para = <$fh>;
   chomp($para);
   close $fh or die "Can't close $file: $OS_ERROR";
   return $para;
}

sub clone {
   my ( $self ) = @_;

   my %clone = map {
      my $hashref  = $self->{$_};
      my $val_copy = {};
      foreach my $key ( keys %$hashref ) {
         my $ref = ref $hashref->{$key};
         $val_copy->{$key} = !$ref           ? $hashref->{$key}
                           : $ref eq 'HASH'  ? { %{$hashref->{$key}} }
                           : $ref eq 'ARRAY' ? [ @{$hashref->{$key}} ]
                           : $hashref->{$key};
      }
      $_ => $val_copy;
   } qw(opts short_opts defaults);

   foreach my $scalar ( qw(got_opts) ) {
      $clone{$scalar} = $self->{$scalar};
   }

   return bless \%clone;     
}

sub _parse_size {
   my ( $self, $opt, $val ) = @_;

   if ( lc($val || '') eq 'null' ) {
      PTDEBUG && _d('NULL size for', $opt->{long});
      $opt->{value} = 'null';
      return;
   }

   my %factor_for = (k => 1_024, M => 1_048_576, G => 1_073_741_824);
   my ($pre, $num, $factor) = $val =~ m/^([+-])?(\d+)([kMG])?$/;
   if ( defined $num ) {
      if ( $factor ) {
         $num *= $factor_for{$factor};
         PTDEBUG && _d('Setting option', $opt->{y},
            'to num', $num, '* factor', $factor);
      }
      $opt->{value} = ($pre || '') . $num;
   }
   else {
      $self->save_error("Invalid size for --$opt->{long}: $val");
   }
   return;
}

sub _parse_attribs {
   my ( $self, $option, $attribs ) = @_;
   my $types = $self->{types};
   return $option
      . ($attribs->{'short form'} ? '|' . $attribs->{'short form'}   : '' )
      . ($attribs->{'negatable'}  ? '!'                              : '' )
      . ($attribs->{'cumulative'} ? '+'                              : '' )
      . ($attribs->{'type'}       ? '=' . $types->{$attribs->{type}} : '' );
}

sub _parse_synopsis {
   my ( $self, $file ) = @_;
   $file ||= $self->{file} || __FILE__;
   PTDEBUG && _d("Parsing SYNOPSIS in", $file);

   local $INPUT_RECORD_SEPARATOR = '';  # read paragraphs
   open my $fh, "<", $file or die "Cannot open $file: $OS_ERROR";
   my $para;
   1 while defined($para = <$fh>) && $para !~ m/^=head1 SYNOPSIS/;
   die "$file does not contain a SYNOPSIS section" unless $para;
   my @synop;
   for ( 1..2 ) {  # 1 for the usage, 2 for the description
      my $para = <$fh>;
      push @synop, $para;
   }
   close $fh;
   PTDEBUG && _d("Raw SYNOPSIS text:", @synop);
   my ($usage, $desc) = @synop;
   die "The SYNOPSIS section in $file is not formatted properly"
      unless $usage && $desc;

   $usage =~ s/^\s*Usage:\s+(.+)/$1/;
   chomp $usage;

   $desc =~ s/\n/ /g;
   $desc =~ s/\s{2,}/ /g;
   $desc =~ s/\. ([A-Z][a-z])/.  $1/g;
   $desc =~ s/\s+$//;

   return (
      description => $desc,
      usage       => $usage,
   );
};

sub set_vars {
   my ($self, $file) = @_;
   $file ||= $self->{file} || __FILE__;

   my %user_vars;
   my $user_vars = $self->has('set-vars') ? $self->get('set-vars') : undef;
   if ( $user_vars ) {
      foreach my $var_val ( @$user_vars ) {
         my ($var, $val) = $var_val =~ m/([^\s=]+)=(\S+)/;
         die "Invalid --set-vars value: $var_val\n" unless $var && defined $val;
         $user_vars{$var} = {
            val     => $val,
            default => 0,
         };
      }
   }

   my %default_vars;
   my $default_vars = $self->read_para_after($file, qr/MAGIC_set_vars/);
   if ( $default_vars ) {
      %default_vars = map {
         my $var_val = $_;
         my ($var, $val) = $var_val =~ m/([^\s=]+)=(\S+)/;
         die "Invalid --set-vars value: $var_val\n" unless $var && defined $val;
         $var => {
            val     => $val,
            default => 1,
         };
      } split("\n", $default_vars);
   }

   my %vars = (
      %default_vars, # first the tool's defaults
      %user_vars,    # then the user's which overwrite the defaults
   );
   PTDEBUG && _d('--set-vars:', Dumper(\%vars));
   return \%vars;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

if ( PTDEBUG ) {
   print STDERR '# ', $^X, ' ', $], "\n";
   if ( my $uname = `uname -a` ) {
      $uname =~ s/\s+/ /g;
      print STDERR "# $uname\n";
   }
   print STDERR '# Arguments: ',
      join(' ', map { my $a = "_[$_]_"; $a =~ s/\n/\n# /g; $a; } @ARGV), "\n";
}

1;
}
# ###########################################################################
# End OptionParser package
# ###########################################################################

# ###########################################################################
# Lmo::Utils package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Lmo/Utils.pm
#   t/lib/Lmo/Utils.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Lmo::Utils;

use strict;
use warnings qw( FATAL all );
require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK);

BEGIN {
   @ISA = qw(Exporter);
   @EXPORT = @EXPORT_OK = qw(
      _install_coderef
      _unimport_coderefs
      _glob_for
      _stash_for
   );
}

{
   no strict 'refs';
   sub _glob_for {
      return \*{shift()}
   }

   sub _stash_for {
      return \%{ shift() . "::" };
   }
}

sub _install_coderef {
   my ($to, $code) = @_;

   return *{ _glob_for $to } = $code;
}

sub _unimport_coderefs {
   my ($target, @names) = @_;
   return unless @names;
   my $stash = _stash_for($target);
   foreach my $name (@names) {
      if ($stash->{$name} and defined(&{$stash->{$name}})) {
         delete $stash->{$name};
      }
   }
}

1;
}
# ###########################################################################
# End Lmo::Utils package
# ###########################################################################

# ###########################################################################
# Lmo::Meta package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Lmo/Meta.pm
#   t/lib/Lmo/Meta.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Lmo::Meta;
use strict;
use warnings qw( FATAL all );

my %metadata_for;

sub new {
   my $class = shift;
   return bless { @_ }, $class
}

sub metadata_for {
   my $self    = shift;
   my ($class) = @_;

   return $metadata_for{$class} ||= {};
}

sub class { shift->{class} }

sub attributes {
   my $self = shift;
   return keys %{$self->metadata_for($self->class)}
}

sub attributes_for_new {
   my $self = shift;
   my @attributes;

   my $class_metadata = $self->metadata_for($self->class);
   while ( my ($attr, $meta) = each %$class_metadata ) {
      if ( exists $meta->{init_arg} ) {
         push @attributes, $meta->{init_arg}
               if defined $meta->{init_arg};
      }
      else {
         push @attributes, $attr;
      }
   }
   return @attributes;
}

1;
}
# ###########################################################################
# End Lmo::Meta package
# ###########################################################################

# ###########################################################################
# Lmo::Object package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Lmo/Object.pm
#   t/lib/Lmo/Object.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Lmo::Object;

use strict;
use warnings qw( FATAL all );

use Carp ();
use Scalar::Util qw(blessed);

use Lmo::Meta;
use Lmo::Utils qw(_glob_for);

sub new {
   my $class = shift;
   my $args  = $class->BUILDARGS(@_);

   my $class_metadata = Lmo::Meta->metadata_for($class);

   my @args_to_delete;
   while ( my ($attr, $meta) = each %$class_metadata ) {
      next unless exists $meta->{init_arg};
      my $init_arg = $meta->{init_arg};

      if ( defined $init_arg ) {
         $args->{$attr} = delete $args->{$init_arg};
      }
      else {
         push @args_to_delete, $attr;
      }
   }

   delete $args->{$_} for @args_to_delete;

   for my $attribute ( keys %$args ) {
      if ( my $coerce = $class_metadata->{$attribute}{coerce} ) {
         $args->{$attribute} = $coerce->($args->{$attribute});
      }
      if ( my $isa_check = $class_metadata->{$attribute}{isa} ) {
         my ($check_name, $check_sub) = @$isa_check;
         $check_sub->($args->{$attribute});
      }
   }

   while ( my ($attribute, $meta) = each %$class_metadata ) {
      next unless $meta->{required};
      Carp::confess("Attribute ($attribute) is required for $class")
         if ! exists $args->{$attribute}
   }

   my $self = bless $args, $class;

   my @build_subs;
   my $linearized_isa = mro::get_linear_isa($class);

   for my $isa_class ( @$linearized_isa ) {
      unshift @build_subs, *{ _glob_for "${isa_class}::BUILD" }{CODE};
   }
   my @args = %$args;
   for my $sub (grep { defined($_) && exists &$_ } @build_subs) {
      $sub->( $self, @args);
   }
   return $self;
}

sub BUILDARGS {
   shift; # No need for the classname
   if ( @_ == 1 && ref($_[0]) ) {
      Carp::confess("Single parameters to new() must be a HASH ref, not $_[0]")
         unless ref($_[0]) eq ref({});
      return {%{$_[0]}} # We want a new reference, always
   }
   else {
      return { @_ };
   }
}

sub meta {
   my $class = shift;
   $class    = Scalar::Util::blessed($class) || $class;
   return Lmo::Meta->new(class => $class);
}

1;
}
# ###########################################################################
# End Lmo::Object package
# ###########################################################################

# ###########################################################################
# Lmo::Types package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Lmo/Types.pm
#   t/lib/Lmo/Types.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Lmo::Types;

use strict;
use warnings qw( FATAL all );

use Carp ();
use Scalar::Util qw(looks_like_number blessed);


our %TYPES = (
   Bool   => sub { !$_[0] || (defined $_[0] && looks_like_number($_[0]) && $_[0] == 1) },
   Num    => sub { defined $_[0] && looks_like_number($_[0]) },
   Int    => sub { defined $_[0] && looks_like_number($_[0]) && $_[0] == int($_[0]) },
   Str    => sub { defined $_[0] },
   Object => sub { defined $_[0] && blessed($_[0]) },
   FileHandle => sub { local $@; require IO::Handle; fileno($_[0]) && $_[0]->opened },

   map {
      my $type = /R/ ? $_ : uc $_;
      $_ . "Ref" => sub { ref $_[0] eq $type }
   } qw(Array Code Hash Regexp Glob Scalar)
);

sub check_type_constaints {
   my ($attribute, $type_check, $check_name, $val) = @_;
   ( ref($type_check) eq 'CODE'
      ? $type_check->($val)
      : (ref $val eq $type_check
         || ($val && $val eq $type_check)
         || (exists $TYPES{$type_check} && $TYPES{$type_check}->($val)))
   )
   || Carp::confess(
        qq<Attribute ($attribute) does not pass the type constraint because: >
      . qq<Validation failed for '$check_name' with value >
      . (defined $val ? Lmo::Dumper($val) : 'undef') )
}

sub _nested_constraints {
   my ($attribute, $aggregate_type, $type) = @_;

   my $inner_types;
   if ( $type =~ /\A(ArrayRef|Maybe)\[(.*)\]\z/ ) {
      $inner_types = _nested_constraints($1, $2);
   }
   else {
      $inner_types = $TYPES{$type};
   }

   if ( $aggregate_type eq 'ArrayRef' ) {
      return sub {
         my ($val) = @_;
         return unless ref($val) eq ref([]);

         if ($inner_types) {
            for my $value ( @{$val} ) {
               return unless $inner_types->($value)
            }
         }
         else {
            for my $value ( @{$val} ) {
               return unless $value && ($value eq $type
                        || (Scalar::Util::blessed($value) && $value->isa($type)));
            }
         }
         return 1;
      };
   }
   elsif ( $aggregate_type eq 'Maybe' ) {
      return sub {
         my ($value) = @_;
         return 1 if ! defined($value);
         if ($inner_types) {
            return unless $inner_types->($value)
         }
         else {
            return unless $value eq $type
                        || (Scalar::Util::blessed($value) && $value->isa($type));
         }
         return 1;
      }
   }
   else {
      Carp::confess("Nested aggregate types are only implemented for ArrayRefs and Maybe");
   }
}

1;
}
# ###########################################################################
# End Lmo::Types package
# ###########################################################################

# ###########################################################################
# Lmo package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Lmo.pm
#   t/lib/Lmo.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
BEGIN {
$INC{"Lmo.pm"} = __FILE__;
package Lmo;
our $VERSION = '0.30_Percona'; # Forked from 0.30 of Mo.


use strict;
use warnings qw( FATAL all );

use Carp ();
use Scalar::Util qw(looks_like_number blessed);

use Lmo::Meta;
use Lmo::Object;
use Lmo::Types;

use Lmo::Utils;

my %export_for;
sub import {
   warnings->import(qw(FATAL all));
   strict->import();

   my $caller     = scalar caller(); # Caller's package
   my %exports = (
      extends  => \&extends,
      has      => \&has,
      with     => \&with,
      override => \&override,
      confess  => \&Carp::confess,
   );

   $export_for{$caller} = \%exports;

   for my $keyword ( keys %exports ) {
      _install_coderef "${caller}::$keyword" => $exports{$keyword};
   }

   if ( !@{ *{ _glob_for "${caller}::ISA" }{ARRAY} || [] } ) {
      @_ = "Lmo::Object";
      goto *{ _glob_for "${caller}::extends" }{CODE};
   }
}

sub extends {
   my $caller = scalar caller();
   for my $class ( @_ ) {
      _load_module($class);
   }
   _set_package_isa($caller, @_);
   _set_inherited_metadata($caller);
}

sub _load_module {
   my ($class) = @_;
   
   (my $file = $class) =~ s{::|'}{/}g;
   $file .= '.pm';
   { local $@; eval { require "$file" } } # or warn $@;
   return;
}

sub with {
   my $package = scalar caller();
   require Role::Tiny;
   for my $role ( @_ ) {
      _load_module($role);
      _role_attribute_metadata($package, $role);
   }
   Role::Tiny->apply_roles_to_package($package, @_);
}

sub _role_attribute_metadata {
   my ($package, $role) = @_;

   my $package_meta = Lmo::Meta->metadata_for($package);
   my $role_meta    = Lmo::Meta->metadata_for($role);

   %$package_meta = (%$role_meta, %$package_meta);
}

sub has {
   my $names  = shift;
   my $caller = scalar caller();

   my $class_metadata = Lmo::Meta->metadata_for($caller);
   
   for my $attribute ( ref $names ? @$names : $names ) {
      my %args   = @_;
      my $method = ($args{is} || '') eq 'ro'
         ? sub {
            Carp::confess("Cannot assign a value to a read-only accessor at reader ${caller}::${attribute}")
               if $#_;
            return $_[0]{$attribute};
         }
         : sub {
            return $#_
                  ? $_[0]{$attribute} = $_[1]
                  : $_[0]{$attribute};
         };

      $class_metadata->{$attribute} = ();

      if ( my $type_check = $args{isa} ) {
         my $check_name = $type_check;
         
         if ( my ($aggregate_type, $inner_type) = $type_check =~ /\A(ArrayRef|Maybe)\[(.*)\]\z/ ) {
            $type_check = Lmo::Types::_nested_constraints($attribute, $aggregate_type, $inner_type);
         }
         
         my $check_sub = sub {
            my ($new_val) = @_;
            Lmo::Types::check_type_constaints($attribute, $type_check, $check_name, $new_val);
         };
         
         $class_metadata->{$attribute}{isa} = [$check_name, $check_sub];
         my $orig_method = $method;
         $method = sub {
            $check_sub->($_[1]) if $#_;
            goto &$orig_method;
         };
      }

      if ( my $builder = $args{builder} ) {
         my $original_method = $method;
         $method = sub {
               $#_
                  ? goto &$original_method
                  : ! exists $_[0]{$attribute}
                     ? $_[0]{$attribute} = $_[0]->$builder
                     : goto &$original_method
         };
      }

      if ( my $code = $args{default} ) {
         Carp::confess("${caller}::${attribute}'s default is $code, but should be a coderef")
               unless ref($code) eq 'CODE';
         my $original_method = $method;
         $method = sub {
               $#_
                  ? goto &$original_method
                  : ! exists $_[0]{$attribute}
                     ? $_[0]{$attribute} = $_[0]->$code
                     : goto &$original_method
         };
      }

      if ( my $role = $args{does} ) {
         my $original_method = $method;
         $method = sub {
            if ( $#_ ) {
               Carp::confess(qq<Attribute ($attribute) doesn't consume a '$role' role">)
                  unless Scalar::Util::blessed($_[1]) && eval { $_[1]->does($role) }
            }
            goto &$original_method
         };
      }

      if ( my $coercion = $args{coerce} ) {
         $class_metadata->{$attribute}{coerce} = $coercion;
         my $original_method = $method;
         $method = sub {
            if ( $#_ ) {
               return $original_method->($_[0], $coercion->($_[1]))
            }
            goto &$original_method;
         }
      }

      _install_coderef "${caller}::$attribute" => $method;

      if ( $args{required} ) {
         $class_metadata->{$attribute}{required} = 1;
      }

      if ($args{clearer}) {
         _install_coderef "${caller}::$args{clearer}"
            => sub { delete shift->{$attribute} }
      }

      if ($args{predicate}) {
         _install_coderef "${caller}::$args{predicate}"
            => sub { exists shift->{$attribute} }
      }

      if ($args{handles}) {
         _has_handles($caller, $attribute, \%args);
      }

      if (exists $args{init_arg}) {
         $class_metadata->{$attribute}{init_arg} = $args{init_arg};
      }
   }
}

sub _has_handles {
   my ($caller, $attribute, $args) = @_;
   my $handles = $args->{handles};

   my $ref = ref $handles;
   my $kv;
   if ( $ref eq ref [] ) {
         $kv = { map { $_,$_ } @{$handles} };
   }
   elsif ( $ref eq ref {} ) {
         $kv = $handles;
   }
   elsif ( $ref eq ref qr// ) {
         Carp::confess("Cannot delegate methods based on a Regexp without a type constraint (isa)")
            unless $args->{isa};
         my $target_class = $args->{isa};
         $kv = {
            map   { $_, $_     }
            grep  { $_ =~ $handles }
            grep  { !exists $Lmo::Object::{$_} && $target_class->can($_) }
            grep  { !$export_for{$target_class}->{$_} }
            keys %{ _stash_for $target_class }
         };
   }
   else {
         Carp::confess("handles for $ref not yet implemented");
   }

   while ( my ($method, $target) = each %{$kv} ) {
         my $name = _glob_for "${caller}::$method";
         Carp::confess("You cannot overwrite a locally defined method ($method) with a delegation")
            if defined &$name;

         my ($target, @curried_args) = ref($target) ? @$target : $target;
         *$name = sub {
            my $self        = shift;
            my $delegate_to = $self->$attribute();
            my $error = "Cannot delegate $method to $target because the value of $attribute";
            Carp::confess("$error is not defined") unless $delegate_to;
            Carp::confess("$error is not an object (got '$delegate_to')")
               unless Scalar::Util::blessed($delegate_to) || (!ref($delegate_to) && $delegate_to->can($target));
            return $delegate_to->$target(@curried_args, @_);
         }
   }
}

sub _set_package_isa {
   my ($package, @new_isa) = @_;
   my $package_isa  = \*{ _glob_for "${package}::ISA" };
   @{*$package_isa} = @new_isa;
}

sub _set_inherited_metadata {
   my $class = shift;
   my $class_metadata = Lmo::Meta->metadata_for($class);
   my $linearized_isa = mro::get_linear_isa($class);
   my %new_metadata;

   for my $isa_class (reverse @$linearized_isa) {
      my $isa_metadata = Lmo::Meta->metadata_for($isa_class);
      %new_metadata = (
         %new_metadata,
         %$isa_metadata,
      );
   }
   %$class_metadata = %new_metadata;
}

sub unimport {
   my $caller = scalar caller();
   my $target = caller;
  _unimport_coderefs($target, keys %{$export_for{$caller}});
}

sub Dumper {
   require Data::Dumper;
   local $Data::Dumper::Indent    = 0;
   local $Data::Dumper::Sortkeys  = 0;
   local $Data::Dumper::Quotekeys = 0;
   local $Data::Dumper::Terse     = 1;

   Data::Dumper::Dumper(@_)
}

BEGIN {
   if ($] >= 5.010) {
      { local $@; require mro; }
   }
   else {
      local $@;
      eval {
         require MRO::Compat;
      } or do {
         *mro::get_linear_isa = *mro::get_linear_isa_dfs = sub {
            no strict 'refs';

            my $classname = shift;

            my @lin = ($classname);
            my %stored;
            foreach my $parent (@{"$classname\::ISA"}) {
               my $plin = mro::get_linear_isa_dfs($parent);
               foreach (@$plin) {
                     next if exists $stored{$_};
                     push(@lin, $_);
                     $stored{$_} = 1;
               }
            }
            return \@lin;
         };
      }
   }
}

sub override {
   my ($methods, $code) = @_;
   my $caller          = scalar caller;

   for my $method ( ref($methods) ? @$methods : $methods ) {
      my $full_method     = "${caller}::${method}";
      *{_glob_for $full_method} = $code;
   }
}

}
1;
}
# ###########################################################################
# End Lmo package
# ###########################################################################

# ###########################################################################
# DSNParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/DSNParser.pm
#   t/lib/DSNParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package DSNParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 0;
$Data::Dumper::Quotekeys = 0;

my $dsn_sep = qr/(?<!\\),/;

eval {
   require DBI;
};
my $have_dbi = $EVAL_ERROR ? 0 : 1;

sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(opts) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $self = {
      opts => {}  # h, P, u, etc.  Should come from DSN OPTIONS section in POD.
   };
   foreach my $opt ( @{$args{opts}} ) {
      if ( !$opt->{key} || !$opt->{desc} ) {
         die "Invalid DSN option: ", Dumper($opt);
      }
      PTDEBUG && _d('DSN option:',
         join(', ',
            map { "$_=" . (defined $opt->{$_} ? ($opt->{$_} || '') : 'undef') }
               keys %$opt
         )
      );
      $self->{opts}->{$opt->{key}} = {
         dsn  => $opt->{dsn},
         desc => $opt->{desc},
         copy => $opt->{copy} || 0,
      };
   }
   return bless $self, $class;
}

sub prop {
   my ( $self, $prop, $value ) = @_;
   if ( @_ > 2 ) {
      PTDEBUG && _d('Setting', $prop, 'property');
      $self->{$prop} = $value;
   }
   return $self->{$prop};
}

sub parse {
   my ( $self, $dsn, $prev, $defaults ) = @_;
   if ( !$dsn ) {
      PTDEBUG && _d('No DSN to parse');
      return;
   }
   PTDEBUG && _d('Parsing', $dsn);
   $prev     ||= {};
   $defaults ||= {};
   my %given_props;
   my %final_props;
   my $opts = $self->{opts};

   foreach my $dsn_part ( split($dsn_sep, $dsn) ) {
      $dsn_part =~ s/\\,/,/g;
      if ( my ($prop_key, $prop_val) = $dsn_part =~  m/^(.)=(.*)$/ ) {
         $given_props{$prop_key} = $prop_val;
      }
      else {
         PTDEBUG && _d('Interpreting', $dsn_part, 'as h=', $dsn_part);
         $given_props{h} = $dsn_part;
      }
   }

   foreach my $key ( keys %$opts ) {
      PTDEBUG && _d('Finding value for', $key);
      $final_props{$key} = $given_props{$key};
      if ( !defined $final_props{$key}  
           && defined $prev->{$key} && $opts->{$key}->{copy} )
      {
         $final_props{$key} = $prev->{$key};
         PTDEBUG && _d('Copying value for', $key, 'from previous DSN');
      }
      if ( !defined $final_props{$key} ) {
         $final_props{$key} = $defaults->{$key};
         PTDEBUG && _d('Copying value for', $key, 'from defaults');
      }
   }

   foreach my $key ( keys %given_props ) {
      die "Unknown DSN option '$key' in '$dsn'.  For more details, "
            . "please use the --help option, or try 'perldoc $PROGRAM_NAME' "
            . "for complete documentation."
         unless exists $opts->{$key};
   }
   if ( (my $required = $self->prop('required')) ) {
      foreach my $key ( keys %$required ) {
         die "Missing required DSN option '$key' in '$dsn'.  For more details, "
               . "please use the --help option, or try 'perldoc $PROGRAM_NAME' "
               . "for complete documentation."
            unless $final_props{$key};
      }
   }

   return \%final_props;
}

sub parse_options {
   my ( $self, $o ) = @_;
   die 'I need an OptionParser object' unless ref $o eq 'OptionParser';
   my $dsn_string
      = join(',',
          map  { "$_=".$o->get($_); }
          grep { $o->has($_) && $o->get($_) }
          keys %{$self->{opts}}
        );
   PTDEBUG && _d('DSN string made from options:', $dsn_string);
   return $self->parse($dsn_string);
}

sub as_string {
   my ( $self, $dsn, $props ) = @_;
   return $dsn unless ref $dsn;
   my @keys = $props ? @$props : sort keys %$dsn;
   return join(',',
      map  { "$_=" . ($_ eq 'p' ? '...' : $dsn->{$_}) }
      grep {
         exists $self->{opts}->{$_}
         && exists $dsn->{$_}
         && defined $dsn->{$_}
      } @keys);
}

sub usage {
   my ( $self ) = @_;
   my $usage
      = "DSN syntax is key=value[,key=value...]  Allowable DSN keys:\n\n"
      . "  KEY  COPY  MEANING\n"
      . "  ===  ====  =============================================\n";
   my %opts = %{$self->{opts}};
   foreach my $key ( sort keys %opts ) {
      $usage .= "  $key    "
             .  ($opts{$key}->{copy} ? 'yes   ' : 'no    ')
             .  ($opts{$key}->{desc} || '[No description]')
             . "\n";
   }
   $usage .= "\n  If the DSN is a bareword, the word is treated as the 'h' key.\n";
   return $usage;
}

sub get_cxn_params {
   my ( $self, $info ) = @_;
   my $dsn;
   my %opts = %{$self->{opts}};
   my $driver = $self->prop('dbidriver') || '';
   if ( $driver eq 'Pg' ) {
      $dsn = 'DBI:Pg:dbname=' . ( $info->{D} || '' ) . ';'
         . join(';', map  { "$opts{$_}->{dsn}=$info->{$_}" }
                     grep { defined $info->{$_} }
                     qw(h P));
   }
   else {
      $dsn = 'DBI:mysql:' . ( $info->{D} || '' ) . ';'
         . join(';', map  { "$opts{$_}->{dsn}=$info->{$_}" }
                     grep { defined $info->{$_} }
                     qw(F h P S A))
         . ';mysql_read_default_group=client'
         . ($info->{L} ? ';mysql_local_infile=1' : '');
   }
   PTDEBUG && _d($dsn);
   return ($dsn, $info->{u}, $info->{p});
}

sub fill_in_dsn {
   my ( $self, $dbh, $dsn ) = @_;
   my $vars = $dbh->selectall_hashref('SHOW VARIABLES', 'Variable_name');
   my ($user, $db) = $dbh->selectrow_array('SELECT USER(), DATABASE()');
   $user =~ s/@.*//;
   $dsn->{h} ||= $vars->{hostname}->{Value};
   $dsn->{S} ||= $vars->{'socket'}->{Value};
   $dsn->{P} ||= $vars->{port}->{Value};
   $dsn->{u} ||= $user;
   $dsn->{D} ||= $db;
}

sub get_dbh {
   my ( $self, $cxn_string, $user, $pass, $opts ) = @_;
   $opts ||= {};
   my $defaults = {
      AutoCommit         => 0,
      RaiseError         => 1,
      PrintError         => 0,
      ShowErrorStatement => 1,
      mysql_enable_utf8 => ($cxn_string =~ m/charset=utf8/i ? 1 : 0),
   };
   @{$defaults}{ keys %$opts } = values %$opts;
   if (delete $defaults->{L}) { # L for LOAD DATA LOCAL INFILE, our own extension
      $defaults->{mysql_local_infile} = 1;
   }

   if ( $opts->{mysql_use_result} ) {
      $defaults->{mysql_use_result} = 1;
   }

   if ( !$have_dbi ) {
      die "Cannot connect to MySQL because the Perl DBI module is not "
         . "installed or not found.  Run 'perl -MDBI' to see the directories "
         . "that Perl searches for DBI.  If DBI is not installed, try:\n"
         . "  Debian/Ubuntu  apt-get install libdbi-perl\n"
         . "  RHEL/CentOS    yum install perl-DBI\n"
         . "  OpenSolaris    pkg install pkg:/SUNWpmdbi\n";

   }

   my $dbh;
   my $tries = 2;
   while ( !$dbh && $tries-- ) {
      PTDEBUG && _d($cxn_string, ' ', $user, ' ', $pass, 
         join(', ', map { "$_=>$defaults->{$_}" } keys %$defaults ));

      $dbh = eval { DBI->connect($cxn_string, $user, $pass, $defaults) };

      if ( !$dbh && $EVAL_ERROR ) {
         if ( $EVAL_ERROR =~ m/locate DBD\/mysql/i ) {
            die "Cannot connect to MySQL because the Perl DBD::mysql module is "
               . "not installed or not found.  Run 'perl -MDBD::mysql' to see "
               . "the directories that Perl searches for DBD::mysql.  If "
               . "DBD::mysql is not installed, try:\n"
               . "  Debian/Ubuntu  apt-get install libdbd-mysql-perl\n"
               . "  RHEL/CentOS    yum install perl-DBD-MySQL\n"
               . "  OpenSolaris    pgk install pkg:/SUNWapu13dbd-mysql\n";
         }
         elsif ( $EVAL_ERROR =~ m/not a compiled character set|character set utf8/ ) {
            PTDEBUG && _d('Going to try again without utf8 support');
            delete $defaults->{mysql_enable_utf8};
         }
         if ( !$tries ) {
            die $EVAL_ERROR;
         }
      }
   }

   if ( $cxn_string =~ m/mysql/i ) {
      my $sql;

      if ( my ($charset) = $cxn_string =~ m/charset=([\w]+)/ ) {
         $sql = qq{/*!40101 SET NAMES "$charset"*/};
         PTDEBUG && _d($dbh, $sql);
         eval { $dbh->do($sql) };
         if ( $EVAL_ERROR ) {
            die "Error setting NAMES to $charset: $EVAL_ERROR";
         }
         PTDEBUG && _d('Enabling charset for STDOUT');
         if ( $charset eq 'utf8' ) {
            binmode(STDOUT, ':utf8')
               or die "Can't binmode(STDOUT, ':utf8'): $OS_ERROR";
         }
         else {
            binmode(STDOUT) or die "Can't binmode(STDOUT): $OS_ERROR";
         }
      }

      if ( my $vars = $self->prop('set-vars') ) {
         $self->set_vars($dbh, $vars);
      }

      $sql = 'SELECT @@SQL_MODE';
      PTDEBUG && _d($dbh, $sql);
      my ($sql_mode) = eval { $dbh->selectrow_array($sql) };
      if ( $EVAL_ERROR ) {
         die "Error getting the current SQL_MODE: $EVAL_ERROR";
      }

      $sql = 'SET @@SQL_QUOTE_SHOW_CREATE = 1'
            . '/*!40101, @@SQL_MODE=\'NO_AUTO_VALUE_ON_ZERO'
            . ($sql_mode ? ",$sql_mode" : '')
            . '\'*/';
      PTDEBUG && _d($dbh, $sql);
      eval { $dbh->do($sql) };
      if ( $EVAL_ERROR ) {
         die "Error setting SQL_QUOTE_SHOW_CREATE, SQL_MODE"
           . ($sql_mode ? " and $sql_mode" : '')
           . ": $EVAL_ERROR";
      }
   }
   my ($mysql_version) = eval { $dbh->selectrow_array('SELECT VERSION()') };
   if ($EVAL_ERROR) {
       die "Cannot get MySQL version: $EVAL_ERROR";
   }

   my (undef, $character_set_server) = eval { $dbh->selectrow_array("SHOW VARIABLES LIKE 'character_set_server'") };
   if ($EVAL_ERROR) {
       die "Cannot get MySQL var character_set_server: $EVAL_ERROR";
   }

   if ($mysql_version =~ m/^(\d+)\.(\d)\.(\d+).*/) {
       if ($1 >= 8 && $character_set_server =~ m/^utf8/) {
           $dbh->{mysql_enable_utf8} = 1;
           my $msg = "MySQL version $mysql_version >= 8 and character_set_server = $character_set_server\n".
                     "Setting: SET NAMES $character_set_server";
           PTDEBUG && _d($msg);
           eval { $dbh->do("SET NAMES 'utf8mb4'") };
           if ($EVAL_ERROR) {
               die "Cannot SET NAMES $character_set_server: $EVAL_ERROR";
           }
       }
   }

   PTDEBUG && _d('DBH info: ',
      $dbh,
      Dumper($dbh->selectrow_hashref(
         'SELECT DATABASE(), CONNECTION_ID(), VERSION()/*!50038 , @@hostname*/')),
      'Connection info:',      $dbh->{mysql_hostinfo},
      'Character set info:',   Dumper($dbh->selectall_arrayref(
                     "SHOW VARIABLES LIKE 'character_set%'", { Slice => {}})),
      '$DBD::mysql::VERSION:', $DBD::mysql::VERSION,
      '$DBI::VERSION:',        $DBI::VERSION,
   );

   return $dbh;
}

sub get_hostname {
   my ( $self, $dbh ) = @_;
   if ( my ($host) = ($dbh->{mysql_hostinfo} || '') =~ m/^(\w+) via/ ) {
      return $host;
   }
   my ( $hostname, $one ) = $dbh->selectrow_array(
      'SELECT /*!50038 @@hostname, */ 1');
   return $hostname;
}

sub disconnect {
   my ( $self, $dbh ) = @_;
   PTDEBUG && $self->print_active_handles($dbh);
   $dbh->disconnect;
}

sub print_active_handles {
   my ( $self, $thing, $level ) = @_;
   $level ||= 0;
   printf("# Active %sh: %s %s %s\n", ($thing->{Type} || 'undef'), "\t" x $level,
      $thing, (($thing->{Type} || '') eq 'st' ? $thing->{Statement} || '' : ''))
      or die "Cannot print: $OS_ERROR";
   foreach my $handle ( grep {defined} @{ $thing->{ChildHandles} } ) {
      $self->print_active_handles( $handle, $level + 1 );
   }
}

sub copy {
   my ( $self, $dsn_1, $dsn_2, %args ) = @_;
   die 'I need a dsn_1 argument' unless $dsn_1;
   die 'I need a dsn_2 argument' unless $dsn_2;
   my %new_dsn = map {
      my $key = $_;
      my $val;
      if ( $args{overwrite} ) {
         $val = defined $dsn_1->{$key} ? $dsn_1->{$key} : $dsn_2->{$key};
      }
      else {
         $val = defined $dsn_2->{$key} ? $dsn_2->{$key} : $dsn_1->{$key};
      }
      $key => $val;
   } keys %{$self->{opts}};
   return \%new_dsn;
}

sub set_vars {
   my ($self, $dbh, $vars) = @_;

   return unless $vars;

   foreach my $var ( sort keys %$vars ) {
      my $val = $vars->{$var}->{val};

      (my $quoted_var = $var) =~ s/_/\\_/;
      my ($var_exists, $current_val);
      eval {
         ($var_exists, $current_val) = $dbh->selectrow_array(
            "SHOW VARIABLES LIKE '$quoted_var'");
      };
      my $e = $EVAL_ERROR;
      if ( $e ) {
         PTDEBUG && _d($e);
      }

      if ( $vars->{$var}->{default} && !$var_exists ) {
         PTDEBUG && _d('Not setting default var', $var,
            'because it does not exist');
         next;
      }

      if ( $current_val && $current_val eq $val ) {
         PTDEBUG && _d('Not setting var', $var, 'because its value',
            'is already', $val);
         next;
      }

      my $sql = "SET SESSION $var=$val";
      PTDEBUG && _d($dbh, $sql);
      eval { $dbh->do($sql) };
      if ( my $set_error = $EVAL_ERROR ) {
         chomp($set_error);
         $set_error =~ s/ at \S+ line \d+//;
         my $msg = "Error setting $var: $set_error";
         if ( $current_val ) {
            $msg .= "  The current value for $var is $current_val.  "
                  . "If the variable is read only (not dynamic), specify "
                  . "--set-vars $var=$current_val to avoid this warning, "
                  . "else manually set the variable and restart MySQL.";
         }
         warn $msg . "\n\n";
      }
   }

   return; 
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;
}
# ###########################################################################
# End DSNParser package
# ###########################################################################

# ###########################################################################
# VersionParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/VersionParser.pm
#   t/lib/VersionParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package VersionParser;

use Lmo;
use Scalar::Util qw(blessed);
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use overload (
   '""'     => "version",
   '<=>'    => "cmp",
   'cmp'    => "cmp",
   fallback => 1,
);

use Carp ();

our $VERSION = 0.01;

has major => (
    is       => 'ro',
    isa      => 'Int',
    required => 1,
);

has [qw( minor revision )] => (
    is  => 'ro',
    isa => 'Num',
);

has flavor => (
    is      => 'ro',
    isa     => 'Str',
    default => sub { 'Unknown' },
);

has innodb_version => (
    is      => 'ro',
    isa     => 'Str',
    default => sub { 'NO' },
);

sub series {
   my $self = shift;
   return $self->_join_version($self->major, $self->minor);
}

sub version {
   my $self = shift;
   return $self->_join_version($self->major, $self->minor, $self->revision);
}

sub is_in {
   my ($self, $target) = @_;

   return $self eq $target;
}

sub _join_version {
    my ($self, @parts) = @_;

    return join ".", map { my $c = $_; $c =~ s/^0\./0/; $c } grep defined, @parts;
}
sub _split_version {
   my ($self, $str) = @_;
   my @version_parts = map { s/^0(?=\d)/0./; $_ } $str =~ m/(\d+)/g;
   return @version_parts[0..2];
}

sub normalized_version {
   my ( $self ) = @_;
   my $result = sprintf('%d%02d%02d', map { $_ || 0 } $self->major,
                                                      $self->minor,
                                                      $self->revision);
   PTDEBUG && _d($self->version, 'normalizes to', $result);
   return $result;
}

sub comment {
   my ( $self, $cmd ) = @_;
   my $v = $self->normalized_version();

   return "/*!$v $cmd */"
}

my @methods = qw(major minor revision);
sub cmp {
   my ($left, $right) = @_;
   my $right_obj = (blessed($right) && $right->isa(ref($left)))
                   ? $right
                   : ref($left)->new($right);

   my $retval = 0;
   for my $m ( @methods ) {
      last unless defined($left->$m) && defined($right_obj->$m);
      $retval = $left->$m <=> $right_obj->$m;
      last if $retval;
   }
   return $retval;
}

sub BUILDARGS {
   my $self = shift;

   if ( @_ == 1 ) {
      my %args;
      if ( blessed($_[0]) && $_[0]->can("selectrow_hashref") ) {
         PTDEBUG && _d("VersionParser got a dbh, trying to get the version");
         my $dbh = $_[0];
         local $dbh->{FetchHashKeyName} = 'NAME_lc';
         my $query = eval {
            $dbh->selectall_arrayref(q/SHOW VARIABLES LIKE 'version%'/, { Slice => {} })
         };
         if ( $query ) {
            $query = { map { $_->{variable_name} => $_->{value} } @$query };
            @args{@methods} = $self->_split_version($query->{version});
            $args{flavor} = delete $query->{version_comment}
                  if $query->{version_comment};
         }
         elsif ( eval { ($query) = $dbh->selectrow_array(q/SELECT VERSION()/) } ) {
            @args{@methods} = $self->_split_version($query);
         }
         else {
            Carp::confess("Couldn't get the version from the dbh while "
                        . "creating a VersionParser object: $@");
         }
         $args{innodb_version} = eval { $self->_innodb_version($dbh) };
      }
      elsif ( !ref($_[0]) ) {
         @args{@methods} = $self->_split_version($_[0]);
      }

      for my $method (@methods) {
         delete $args{$method} unless defined $args{$method};
      }
      @_ = %args if %args;
   }

   return $self->SUPER::BUILDARGS(@_);
}

sub _innodb_version {
   my ( $self, $dbh ) = @_;
   return unless $dbh;
   my $innodb_version = "NO";

   my ($innodb) =
      grep { $_->{engine} =~ m/InnoDB/i }
      map  {
         my %hash;
         @hash{ map { lc $_ } keys %$_ } = values %$_;
         \%hash;
      }
      @{ $dbh->selectall_arrayref("SHOW ENGINES", {Slice=>{}}) };
   if ( $innodb ) {
      PTDEBUG && _d("InnoDB support:", $innodb->{support});
      if ( $innodb->{support} =~ m/YES|DEFAULT/i ) {
         my $vars = $dbh->selectrow_hashref(
            "SHOW VARIABLES LIKE 'innodb_version'");
         $innodb_version = !$vars ? "BUILTIN"
                         :          ($vars->{Value} || $vars->{value});
      }
      else {
         $innodb_version = $innodb->{support};  # probably DISABLED or NO
      }
   }

   PTDEBUG && _d("InnoDB version:", $innodb_version);
   return $innodb_version;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

no Lmo;
1;
}
# ###########################################################################
# End VersionParser package
# ###########################################################################

# ###########################################################################
# Daemon package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Daemon.pm
#   t/lib/Daemon.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Daemon;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use POSIX qw(setsid);

sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(o) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $o = $args{o};
   my $self = {
      o        => $o,
      log_file => $o->has('log') ? $o->get('log') : undef,
      PID_file => $o->has('pid') ? $o->get('pid') : undef,
   };

   check_PID_file(undef, $self->{PID_file});

   PTDEBUG && _d('Daemonized child will log to', $self->{log_file});
   return bless $self, $class;
}

sub daemonize {
   my ( $self ) = @_;

   PTDEBUG && _d('About to fork and daemonize');
   defined (my $pid = fork()) or die "Cannot fork: $OS_ERROR";
   if ( $pid ) {
      PTDEBUG && _d('Parent PID', $PID, 'exiting after forking child PID',$pid);
      exit;
   }

   PTDEBUG && _d('Daemonizing child PID', $PID);
   $self->{PID_owner} = $PID;
   $self->{child}     = 1;

   POSIX::setsid() or die "Cannot start a new session: $OS_ERROR";
   chdir '/'       or die "Cannot chdir to /: $OS_ERROR";

   $self->_make_PID_file();

   $OUTPUT_AUTOFLUSH = 1;

   PTDEBUG && _d('Redirecting STDIN to /dev/null');
   close STDIN;
   open  STDIN, '/dev/null'
      or die "Cannot reopen STDIN to /dev/null: $OS_ERROR";

   if ( $self->{log_file} ) {
      PTDEBUG && _d('Redirecting STDOUT and STDERR to', $self->{log_file});
      close STDOUT;
      open  STDOUT, '>>', $self->{log_file}
         or die "Cannot open log file $self->{log_file}: $OS_ERROR";

      close STDERR;
      open  STDERR, ">&STDOUT"
         or die "Cannot dupe STDERR to STDOUT: $OS_ERROR"; 
   }
   else {
      if ( -t STDOUT ) {
         PTDEBUG && _d('No log file and STDOUT is a terminal;',
            'redirecting to /dev/null');
         close STDOUT;
         open  STDOUT, '>', '/dev/null'
            or die "Cannot reopen STDOUT to /dev/null: $OS_ERROR";
      }
      if ( -t STDERR ) {
         PTDEBUG && _d('No log file and STDERR is a terminal;',
            'redirecting to /dev/null');
         close STDERR;
         open  STDERR, '>', '/dev/null'
            or die "Cannot reopen STDERR to /dev/null: $OS_ERROR";
      }
   }

   return;
}

sub check_PID_file {
   my ( $self, $file ) = @_;
   my $PID_file = $self ? $self->{PID_file} : $file;
   PTDEBUG && _d('Checking PID file', $PID_file);
   if ( $PID_file && -f $PID_file ) {
      my $pid;
      eval {
         chomp($pid = (slurp_file($PID_file) || ''));
      };
      if ( $EVAL_ERROR ) {
         die "The PID file $PID_file already exists but it cannot be read: "
            . $EVAL_ERROR;
      }
      PTDEBUG && _d('PID file exists; it contains PID', $pid);
      if ( $pid ) {
         my $pid_is_alive = kill 0, $pid;
         if ( $pid_is_alive ) {
            die "The PID file $PID_file already exists "
               . " and the PID that it contains, $pid, is running";
         }
         else {
            warn "Overwriting PID file $PID_file because the PID that it "
               . "contains, $pid, is not running";
         }
      }
      else {
         die "The PID file $PID_file already exists but it does not "
            . "contain a PID";
      }
   }
   else {
      PTDEBUG && _d('No PID file');
   }
   return;
}

sub make_PID_file {
   my ( $self ) = @_;
   if ( exists $self->{child} ) {
      die "Do not call Daemon::make_PID_file() for daemonized scripts";
   }
   $self->_make_PID_file();
   $self->{PID_owner} = $PID;
   return;
}

sub _make_PID_file {
   my ( $self ) = @_;

   my $PID_file = $self->{PID_file};
   if ( !$PID_file ) {
      PTDEBUG && _d('No PID file to create');
      return;
   }

   $self->check_PID_file();

   open my $PID_FH, '>', $PID_file
      or die "Cannot open PID file $PID_file: $OS_ERROR";
   print $PID_FH $PID
      or die "Cannot print to PID file $PID_file: $OS_ERROR";
   close $PID_FH
      or die "Cannot close PID file $PID_file: $OS_ERROR";

   PTDEBUG && _d('Created PID file:', $self->{PID_file});
   return;
}

sub _remove_PID_file {
   my ( $self ) = @_;
   if ( $self->{PID_file} && -f $self->{PID_file} ) {
      unlink $self->{PID_file}
         or warn "Cannot remove PID file $self->{PID_file}: $OS_ERROR";
      PTDEBUG && _d('Removed PID file');
   }
   else {
      PTDEBUG && _d('No PID to remove');
   }
   return;
}

sub DESTROY {
   my ( $self ) = @_;

   $self->_remove_PID_file() if ($self->{PID_owner} || 0) == $PID;

   return;
}

sub slurp_file {
   my ($file) = @_;
   return unless $file;
   open my $fh, "<", $file or die "Cannot open $file: $OS_ERROR";
   return do { local $/; <$fh> };
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;
}
# ###########################################################################
# End Daemon package
# ###########################################################################

# ###########################################################################
# PodParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/PodParser.pm
#   t/lib/PodParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package PodParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

my %parse_items_from = (
   'OPTIONS'     => 1,
   'DSN OPTIONS' => 1,
   'RULES'       => 1,
);

my %item_pattern_for = (
   'OPTIONS'     => qr/--(.*)/,
   'DSN OPTIONS' => qr/\* (.)/,
   'RULES'       => qr/(.*)/,
);

my %section_has_rules = (
   'OPTIONS'     => 1,
   'DSN OPTIONS' => 0,
   'RULES'       => 0,
);

sub new {
   my ( $class, %args ) = @_;
   my $self = {
      current_section => '',
      current_item    => '',
      items           => {},  # keyed off SECTION
      magic           => {},  # keyed off SECTION->magic ident (without MAGIC_)
      magic_ident     => '',  # set when next para is a magic para
   };
   return bless $self, $class;
}
 
sub get_items {
   my ( $self, $section ) = @_;
   return $section ? $self->{items}->{$section} : $self->{items};
}

sub get_magic {
   my ( $self, $section ) = @_;
   return $section ? $self->{magic}->{$section} : $self->{magic};
}

sub parse_from_file {
   my ( $self, $file ) = @_;
   return unless $file;
   PTDEBUG && _d('Parsing POD in', $file);
   open my $fh, "<", $file or die "Cannot open $file: $OS_ERROR";
   local $INPUT_RECORD_SEPARATOR = '';  # read paragraphs
   my $para;

   1 while defined($para = <$fh>) && $para !~ m/^=pod/;
   die "$file does not contain =pod" unless $para;

   while ( defined($para = <$fh>) && $para !~ m/^=cut/ ) {
      if ( $para =~ m/^=(head|item|over|back)/ ) {
         my ($cmd, $name) = $para =~ m/^=(\w+)(?:\s+(.+))?/;
         $name ||= '';
         PTDEBUG && _d('cmd:', $cmd, 'name:', $name);
         $self->command($cmd, $name);
      }
      elsif ( $parse_items_from{$self->{current_section}} ) {
         $self->textblock($para);
      }
   }

   close $fh;
}

sub command {
   my ( $self, $cmd, $name ) = @_;
   
   $name =~ s/\s+\Z//m;  # Remove \n and blank line after name.

   if  ( $cmd eq 'head1' ) {
      PTDEBUG && _d('In section', $name);
      $self->{current_section} = $name;
   }
   elsif ( $cmd eq 'over' ) {
      if ( $parse_items_from{$name} ) {
         PTDEBUG && _d('Start items in', $self->{current_section});
         $self->{items}->{$self->{current_section}} = {};
      }
   }
   elsif ( $cmd eq 'item' && $parse_items_from{$self->{current_section}} ) {
      my $pat = $item_pattern_for{ $self->{current_section} };
      my ($item) = $name =~ m/$pat/;
      if ( $item ) {
         PTDEBUG && _d($self->{current_section}, 'item:', $item);
         $self->{items}->{ $self->{current_section} }->{$item} = {
            desc => '',  # every item should have a desc
         };
         $self->{current_item} = $item;
      }
      else {
         warn "Item $name does not match $pat";
      }
   }
   elsif ( $cmd eq 'back' ) {
      if ( $parse_items_from{$self->{current_section}} ) {
         PTDEBUG && _d('End items in', $self->{current_section});
      }
   }
   else {
      $self->{current_section} = '';
   }
   
   return;
}

sub textblock {
   my ( $self, $para ) = @_;

   return unless $self->{current_section} && $self->{current_item};

   my $section = $self->{current_section};
   my $item    = $self->{items}->{$section}->{ $self->{current_item} };

   $para =~ s/\s+\Z//;

   if ( $para =~ m/^[a-z]\w+[:;] / ) {
      PTDEBUG && _d('Item attributes:', $para);
      map {
         my ($attrib, $val) = split(/: /, $_);
         $item->{$attrib} = defined $val ? $val : 1;
      } split(/; /, $para);
   }
   else {
      if ( $self->{magic_ident} ) {

         my ($leading_space) = $para =~ m/^(\s+)/;
         my $indent          = length($leading_space || '');
         if ( $indent ) {
            $para =~ s/^\s{$indent}//mg;
            $para =~ s/\s+$//;
            PTDEBUG && _d("MAGIC", $self->{magic_ident}, "para:", $para);
            $self->{magic}->{$self->{current_section}}->{$self->{magic_ident}}
               = $para;
         }
         else {
            PTDEBUG && _d("MAGIC", $self->{magic_ident},
               "para is not indented; treating as normal para");
         }

         $self->{magic_ident} = '';  # must unset this!
      }

      PTDEBUG && _d('Item desc:', substr($para, 0, 40),
         length($para) > 40 ? '...' : '');
      $para =~ s/\n+/ /g;
      $item->{desc} .= $para;

      if ( $para =~ m/MAGIC_(\w+)/ ) {
         $self->{magic_ident} = $1;  # XXX
         PTDEBUG && _d("MAGIC", $self->{magic_ident}, "follows");
      }
   }

   return;
}

sub verbatim {
   my ( $self, $para ) = @_;
   return;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;
}
# ###########################################################################
# End PodParser package
# ###########################################################################

# ###########################################################################
# TextResultSetParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/TextResultSetParser.pm
#   t/lib/TextResultSetParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package TextResultSetParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my %value_for = (
      'NULL' => undef,  # DBI::selectall_arrayref() does this
      ($args{value_for} ? %{$args{value_for}} : ()),
   );
   my $self = {
      %args,
      value_for => \%value_for,
   };
   return bless $self, $class;
}

sub _parse_tabular {
   my ( $text, @cols ) = @_;
   my %row;
   my @vals = $text =~ m/\| +([^\|]*?)(?= +\|)/msg;
   return (undef, \@vals) unless @cols;
   @row{@cols} = @vals;
   return (\%row, undef);
}

sub _parse_tab_sep {
   my ( $text, @cols ) = @_;
   my %row;
   my @vals = split(/\t/, $text);
   return (undef, \@vals) unless @cols;
   @row{@cols} = @vals;
   return (\%row, undef);
}

sub parse_vertical_row {
   my ( $self, $text ) = @_;
   my %row = $text =~ m/^\s*(\w+):(?: ([^\n]*))?/msg;
   if ( $self->{NAME_lc} ) {
      my %lc_row = map {
         my $key = lc $_;
         $key => $row{$_};
      } keys %row;
      return \%lc_row;
   }
   else {
      return \%row;
   }
}

sub parse {
   my ( $self, $text ) = @_;
   my $result_set;

   if ( $text =~ m/^\+---/m ) { # standard "tabular" output
      PTDEBUG && _d('Result set text is standard tabular');
      my $line_pattern  = qr/^(\| .*)[\r\n]+/m;
      $result_set
         = $self->parse_horizontal_row($text, $line_pattern, \&_parse_tabular);
   }
   elsif ( $text =~ m/^\w+\t\w+/m ) { # tab-separated
      PTDEBUG && _d('Result set text is tab-separated');
      my $line_pattern  = qr/^(.*?\t.*)[\r\n]+/m;
      $result_set
         = $self->parse_horizontal_row($text, $line_pattern, \&_parse_tab_sep);
   }
   elsif ( $text =~ m/\*\*\* \d+\. row/ ) { # "vertical" output
      PTDEBUG && _d('Result set text is vertical (\G)');
      foreach my $row ( split_vertical_rows($text) ) {
         push @$result_set, $self->parse_vertical_row($row);
      }
   }
   else {
      my $text_sample = substr $text, 0, 300;
      my $remaining   = length $text > 300 ? (length $text) - 300 : 0;
      chomp $text_sample;
      die "Cannot determine if text is tabular, tab-separated or vertical:\n"
         . "$text_sample\n"
         . ($remaining ? "(not showing last $remaining bytes of text)\n" : "");
   }

   if ( $self->{value_for} ) {
      foreach my $result_set ( @$result_set ) {
         foreach my $key ( keys %$result_set ) {
            next unless defined $result_set->{$key};
            $result_set->{$key} = $self->{value_for}->{ $result_set->{$key} }
               if exists $self->{value_for}->{ $result_set->{$key} };
         }
      }
   }

   return $result_set;
}


sub parse_horizontal_row {
   my ( $self, $text, $line_pattern, $sub ) = @_;
   my @result_sets = ();
   my @cols        = ();
   foreach my $line ( $text =~ m/$line_pattern/g ) {
      my ( $row, $cols ) = $sub->($line, @cols);
      if ( $row ) {
         push @result_sets, $row;
      }
      else {
         @cols = map { $self->{NAME_lc} ? lc $_ : $_ } @$cols;
      }
   }
   return \@result_sets;
}

sub split_vertical_rows {
   my ( $text ) = @_;
   my $ROW_HEADER = '\*{3,} \d+\. row \*{3,}';
   my @rows = $text =~ m/($ROW_HEADER.*?)(?=$ROW_HEADER|\z)/omgs;
   return @rows;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;
}
# ###########################################################################
# End TextResultSetParser package
# ###########################################################################

# ###########################################################################
# Advisor package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Advisor.pm
#   t/lib/Advisor.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Advisor;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(match_type) ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   my $self = {
      %args,
      rules          => [],  # Rules from all advisor modules.
      rule_index_for => {},  # Maps rules by ID to their array index in $rules.
      rule_info      => {},  # ID, severity, description, etc. for each rule.
   };

   return bless $self, $class;
}

sub load_rules {
   my ( $self, $advisor ) = @_;
   return unless $advisor;
   PTDEBUG && _d('Loading rules from', ref $advisor);

   my $i = scalar @{$self->{rules}};

   RULE:
   foreach my $rule ( $advisor->get_rules() ) {
      my $id = $rule->{id};
      if ( $self->{ignore_rules}->{"$id"} ) {
         PTDEBUG && _d("Ignoring rule", $id);
         next RULE;
      }
      die "Rule $id already exists and cannot be redefined"
         if defined $self->{rule_index_for}->{$id};
      push @{$self->{rules}}, $rule;
      $self->{rule_index_for}->{$id} = $i++;
   }

   return;
}

sub load_rule_info {
   my ( $self, $advisor ) = @_;
   return unless $advisor;
   PTDEBUG && _d('Loading rule info from', ref $advisor);
   my $rules = $self->{rules};
   foreach my $rule ( @$rules ) {
      my $id = $rule->{id};
      if ( $self->{ignore_rules}->{"$id"} ) {
         die "Rule $id was loaded but should be ignored";
      }
      my $rule_info = $advisor->get_rule_info($id);
      next unless $rule_info;
      die "Info for rule $id already exists and cannot be redefined"
         if $self->{rule_info}->{$id};
      $self->{rule_info}->{$id} = $rule_info;
   }
   return;
}


sub run_rules {
   my ( $self, %args ) = @_;
   my @matched_rules;
   my @matched_pos;
   my $rules      = $self->{rules};
   my $match_type = lc $self->{match_type};
   foreach my $rule ( @$rules ) {
      eval {
         my $match = $rule->{code}->(%args);
         if ( $match_type eq 'pos' ) {
            if ( defined $match ) {
               PTDEBUG && _d('Matches rule', $rule->{id}, 'near pos', $match);
               push @matched_rules, $rule->{id};
               push @matched_pos,   $match;
            }
         }
         elsif ( $match_type eq 'bool' ) {
            if ( $match ) {
               PTDEBUG && _d("Matches rule", $rule->{id});
               push @matched_rules, $rule->{id};
            }
         }
      };
      if ( $EVAL_ERROR ) {
         warn "Code for rule $rule->{id} caused an error: $EVAL_ERROR";
      }
   }
   return \@matched_rules, \@matched_pos;
};


sub get_rule_info {
   my ( $self, $id ) = @_;
   return unless $id;
   return $self->{rule_info}->{$id};
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;
}
# ###########################################################################
# End Advisor package
# ###########################################################################

# ###########################################################################
# AdvisorRules package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/AdvisorRules.pm
#   t/lib/AdvisorRules.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package AdvisorRules;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(PodParser) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $self = {
      %args,
      rules     => [],
      rule_info => {},
   };
   return bless $self, $class;
}

sub load_rule_info {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(file section ) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $rules = $args{rules} || $self->{rules};
   my $p     = $self->{PodParser};

   $p->parse_from_file($args{file});
   my $rule_items = $p->get_items($args{section});
   my %seen;
   foreach my $rule_id ( keys %$rule_items ) {
      my $rule = $rule_items->{$rule_id};
      die "Rule $rule_id has no description" unless $rule->{desc};
      die "Rule $rule_id has no severity"    unless $rule->{severity};
      die "Rule $rule_id is already defined"
         if exists $self->{rule_info}->{$rule_id};
      $self->{rule_info}->{$rule_id} = {
         id          => $rule_id,
         severity    => $rule->{severity},
         description => $rule->{desc},
      };
   }

   foreach my $rule ( @$rules ) {
      die "There is no info for rule $rule->{id} in $args{file}"
         unless $self->{rule_info}->{ $rule->{id} };
   }

   return;
}

sub get_rule_info {
   my ( $self, $id ) = @_;
   return unless $id;
   return $self->{rule_info}->{$id};
}

sub _reset_rule_info {
   my ( $self ) = @_;
   $self->{rule_info} = {};
   return;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;
}
# ###########################################################################
# End AdvisorRules package
# ###########################################################################

# ###########################################################################
# VariableAdvisorRules package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/VariableAdvisorRules.pm
#   t/lib/VariableAdvisorRules.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package VariableAdvisorRules;
use base 'AdvisorRules';

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my $self = $class->SUPER::new(%args);
   @{$self->{rules}} = $self->get_rules();
   PTDEBUG && _d(scalar @{$self->{rules}}, "rules");
   return $self;
}

sub get_rules {
   return
   {
      id   => 'auto_increment',
      code => sub {
         my ( %args ) = @_;
         my $vars = $args{variables};
         return unless defined $vars->{auto_increment_increment}
            && defined $vars->{auto_increment_offset};
         return    $vars->{auto_increment_increment} != 1
                || $vars->{auto_increment_offset}    != 1 ? 1 : 0;
      },
   },
   {
      id   => 'concurrent_insert',
      code => sub {
         my ( %args ) = @_;
         if (    $args{variables}->{concurrent_insert}
              && $args{variables}->{concurrent_insert} =~ m/[^\d]/ ) {
            return $args{variables}->{concurrent_insert} eq 'ALWAYS' ? 1 : 0;
         }
         return _var_gt($args{variables}->{concurrent_insert}, 1);
      },
   },
   {
      id   => 'connect_timeout',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{connect_timeout}, 10);
      },
   },
   {
      id   => 'debug',
      code => sub {
         my ( %args ) = @_;
         return $args{variables}->{debug} ? 1 : 0;
      },
   },
   {
      id   => 'delay_key_write',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{delay_key_write}, "ON");
      },
   },
   {
      id   => 'flush',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{flush}, "ON");
      },
   },
   {
      id   => 'flush_time',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{flush_time}, 0);
      },
   },
   {
      id   => 'have_bdb',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{have_bdb}, 'YES');
      },
   },
   {
      id   => 'init_connect',
      code => sub {
         my ( %args ) = @_;
         return $args{variables}->{init_connect} ? 1 : 0;
      },
   },
   {
      id   => 'init_file',
      code => sub {
         my ( %args ) = @_;
         return $args{variables}->{init_file} ? 1 : 0;
      },
   },
   {
      id   => 'init_slave',
      code => sub {
         my ( %args ) = @_;
         return $args{variables}->{init_slave} ? 1 : 0;
      },
   },
   {
      id   => 'innodb_additional_mem_pool_size',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{innodb_additional_mem_pool_size},
            20 * 1_048_576);  # 20M
      },
   },
   {
      id   => 'innodb_buffer_pool_size',
      code => sub {
         my ( %args ) = @_;
         return _var_eq($args{variables}->{innodb_buffer_pool_size},
            10 * 1_048_576);  # 10M
      },
   },
   {
      id   => 'innodb_checksums',
      code => sub {
         my ( %args ) = @_;
         return _var_sneq($args{variables}->{innodb_checksums}, "ON");
      },
   },
   {
      id   => 'innodb_doublewrite',
      code => sub {
         my ( %args ) = @_;
         return _var_sneq($args{variables}->{innodb_doublewrite}, "ON");
      },
   },
   {
      id   => 'innodb_fast_shutdown',
      code => sub {
         my ( %args ) = @_;
         return _var_neq($args{variables}->{innodb_fast_shutdown}, 1);
      },
   },
   {
      id   => 'innodb_flush_log_at_trx_commit-1',
      code => sub {
         my ( %args ) = @_;
         return _var_neq($args{variables}->{innodb_flush_log_at_trx_commit}, 1);
      },
   },
   {
      id   => 'innodb_flush_log_at_trx_commit-2',
      code => sub {
         my ( %args ) = @_;
         return _var_eq($args{variables}->{innodb_flush_log_at_trx_commit}, 0);
      },
   },
   {
      id   => 'innodb_force_recovery',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{innodb_force_recovery}, 0);
      },
   },
   {
      id   => 'innodb_lock_wait_timeout',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{innodb_lock_wait_timeout}, 50);
      },
   },
   {
      id   => 'innodb_log_buffer_size',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{innodb_log_buffer_size},
            16 * 1_048_576);  # 16M
      },
   },
   {
      id   => 'innodb_log_file_size',
      code => sub {
         my ( %args ) = @_;
         return _var_eq($args{variables}->{innodb_log_file_size},
            5 * 1_048_576);  # 5M
      },
   },
   {
      id   => 'innodb_max_dirty_pages_pct',
      code => sub {
         my ( %args ) = @_;
         my $mysql_version = $args{mysql_version};
         return _var_lt($args{variables}->{innodb_max_dirty_pages_pct},
            ($mysql_version < '5.5' ? 90 : 75));
      },
   },
   {
      id   => 'key_buffer_size',
      code => sub {
         my ( %args ) = @_;
         return _var_eq($args{variables}->{key_buffer_size},
            8 * 1_048_576);  # 8M
      },
   },
   {
      id   => 'large_pages',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{large_pages}, "ON");
      },
   },
   {
      id   => 'locked_in_memory',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{locked_in_memory}, "ON");
      },
   },
   {
      id   => 'log_warnings-1',
      code => sub {
         my ( %args ) = @_;
         return _var_eq($args{variables}->{log_warnings}, 0);
      },
   },
   {
      id   => 'log_warnings-2',
      code => sub {
         my ( %args ) = @_;
         return _var_eq($args{variables}->{log_warnings}, 1);
      },
   },
   {
      id   => 'low_priority_updates',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{low_priority_updates}, "ON");
      },
   },
   {
      id   => 'max_binlog_size',
      code => sub {
         my ( %args ) = @_;
         return _var_lt($args{variables}->{max_binlog_size},
            1 * 1_073_741_824);  # 1G
      },
   },
   {
      id   => 'max_connect_errors',
      code => sub {
         my ( %args ) = @_;
         return _var_eq($args{variables}->{max_connect_errors}, 10);
      },
   },
   {
      id   => 'max_connections',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{max_connections}, 1_000);
      },
   },

   {
      id   => 'myisam_repair_threads',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{myisam_repair_threads}, 1);
      },
   },
   {
      id   => 'old_passwords',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{old_passwords}, "ON");
      },
   },
   {
      id   => 'optimizer_prune_level',
      code => sub {
         my ( %args ) = @_;
         return _var_lt($args{variables}->{optimizer_prune_level}, 1);
      },
   },
   {
      id   => 'port',
      code => sub {
         my ( %args ) = @_;
         return _var_neq($args{variables}->{port}, 3306);
      },
   },
   {
      id   => 'query_cache_size-1',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{query_cache_size},
            128 * 1_048_576);  # 128M
      },
   },
   {
      id   => 'query_cache_size-2',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{query_cache_size},
            512 * 1_048_576);  # 512M
      },
   },
   {
      id   => 'read_buffer_size-1',
      code => sub {
         my ( %args ) = @_;
         return _var_neq($args{variables}->{read_buffer_size}, 131_072);
      },
   },
   {
      id   => 'read_buffer_size-2',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{read_buffer_size},
            8 * 1_048_576);  # 8M
      },
   },
   {
      id   => 'read_rnd_buffer_size-1',
      code => sub {
         my ( %args ) = @_;
         return _var_neq($args{variables}->{read_rnd_buffer_size}, 262_144);
      },
   },
   {
      id   => 'read_rnd_buffer_size-2',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{read_rnd_buffer_size},
            4 * 1_048_576);  # 4M
      },
   },
   {
      id   => 'relay_log_space_limit',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{relay_log_space_limit}, 0);
      },
   },
   
   {
      id   => 'slave_net_timeout',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{slave_net_timeout}, 60);
      },
   },
   {
      id   => 'slave_skip_errors',
      code => sub {
         my ( %args ) = @_;
         return $args{variables}->{slave_skip_errors}
             && $args{variables}->{slave_skip_errors} ne 'OFF' ? 1 : 0;
      },
   },
   {
      id   => 'sort_buffer_size-1',
      code => sub {
         my ( %args ) = @_;
         return _var_neq($args{variables}->{sort_buffer_size}, 2_097_144);
      },
   },
   {
      id   => 'sort_buffer_size-2',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{sort_buffer_size},
            4 * 1_048_576);  # 4M
      },
   },
   {
      id   => 'sql_notes',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{sql_notes}, "OFF");
      },
   },
   {
      id   => 'sync_frm',
      code => sub {
         my ( %args ) = @_;
         return _var_sneq($args{variables}->{sync_frm}, "ON");
      },
   },
   {
      id   => 'tx_isolation-1',
      code => sub {
         my ( %args ) = @_;
         return _var_sneq($args{variables}->{tx_isolation}, "REPEATABLE-READ");
      },
   },
   {
      id   => 'tx_isolation-2',
      code => sub {
         my ( %args ) = @_;
         return
               _var_sneq($args{variables}->{tx_isolation}, "REPEATABLE-READ")
            && _var_sneq($args{variables}->{tx_isolation}, "READ-COMMITTED")
            ? 1 : 0;
      },
   },
   {
      id   => 'expire_logs_days',
      code => sub {
         my ( %args ) = @_;
         return _var_eq($args{variables}->{expire_logs_days}, 0)
            && _var_seq($args{variables}->{log_bin}, "ON");
      },
   },
   {
      id   => 'innodb_file_io_threads',
      code => sub {
         my ( %args ) = @_;
         return _var_neq($args{variables}->{innodb_file_io_threads}, 4)
            && $OSNAME ne 'MSWin32' ? 1 : 0;
      },
   },
   {
      id   => 'innodb_data_file_path',
      code => sub {
         my ( %args ) = @_;
         return
            ($args{variables}->{innodb_data_file_path} || '') =~ m/autoextend/
            ? 1 : 0;
      },
   },
   {
      id   => 'innodb_flush_method',
      code => sub {
         my ( %args ) = @_;
         return _var_sneq($args{variables}->{innodb_flush_method}, 'O_DIRECT')
            && $OSNAME ne 'MSWin32' ? 1 : 0;
      },
   },
   {
      id   => 'innodb_locks_unsafe_for_binlog',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{innodb_locks_unsafe_for_binlog},
            "ON") && _var_seq($args{variables}->{log_bin}, "ON");
      },
   },
   {
      id   => 'innodb_support_xa',
      code => sub {
         my ( %args ) = @_;
         return _var_sneq($args{variables}->{innodb_support_xa}, "ON")
            && _var_seq($args{variables}->{log_bin}, "ON");
      },
   },
   {
      id   => 'log_bin',
      code => sub {
         my ( %args ) = @_;
         return _var_sneq($args{variables}->{log_bin}, "ON");
      },
   },
   {
      id   => 'log_output',
      code => sub {
         my ( %args ) = @_;
         return ($args{variables}->{log_output} || '') =~ m/TABLE/i ? 1 : 0;
      },
   },
   {
      id   => 'max_relay_log_size',
      code => sub {
         my ( %args ) = @_;
         return _var_gt($args{variables}->{max_relay_log_size}, 0)
            &&  _var_lt($args{variables}->{max_relay_log_size},
                  1 * 1_073_741_824)  ? 1 : 0;
      },
   },
   {
      id   => 'myisam_recover_options',
      code => sub {
         my ( %args ) = @_;
         return _var_seq($args{variables}->{myisam_recover_options}, "OFF")
            ||  _var_seq($args{variables}->{myisam_recover_options}, "DEFAULT")
               ? 1 : 0;
      },
   },
   {
      id   => 'storage_engine',
      code => sub {
         my ( %args ) = @_;
         return 0 unless $args{variables}->{storage_engine};
         return $args{variables}->{storage_engine} !~ m/InnoDB|MyISAM/i ? 1 : 0;
      },
   },
   {
      id   => 'sync_binlog',
      code => sub {
         my ( %args ) = @_;
         return
            _var_seq($args{variables}->{log_bin}, "ON")
            && (   _var_eq($args{variables}->{sync_binlog}, 0)
                || _var_gt($args{variables}->{sync_binlog}, 1)) ? 1 : 0;
      },
   },
   {
      id   => 'tmp_table_size',
      code => sub {
         my ( %args ) = @_;
         return ($args{variables}->{tmp_table_size} || 0)
              > ($args{variables}->{max_heap_table_size} || 0) ? 1 : 0;
      },
   },
   {
      id   => 'old mysql version',
      code => sub {
         my ( %args ) = @_;
         my $mysql_version = $args{mysql_version};
         return 0 unless $mysql_version;
         return 1 if   ($mysql_version == '3'   && $mysql_version < '3.23'  )
                    || ($mysql_version == '4'   && $mysql_version < '4.1.20')
                    || ($mysql_version == '5.0' && $mysql_version < '5.0.37')
                    || ($mysql_version == '5.1' && $mysql_version < '5.1.30');
         return 0;
      },
   },
   {
      id   => 'end-of-life mysql version',
      code => sub {
         my ( %args ) = @_;
         my $mysql_version = $args{mysql_version};
         return 0 unless $mysql_version;
         return $mysql_version < '5.1' ? 1 : 0;  # 5.1.x
      },
   },
};

sub _var_gt {
   my ($var, $val) = @_;
   return 0 unless defined $var;
   return $var > $val ? 1 : 0;
}

sub _var_lt {
   my ($var, $val) = @_;
   return 0 unless defined $var;
   return $var < $val ? 1 : 0;
}

sub _var_eq {
   my ($var, $val) = @_;
   return 0 unless defined $var;
   return $var == $val ? 1 : 0;
}

sub _var_neq {
   my ($var, $val) = @_;
   return 0 unless defined $var;
   return _var_eq($var, $val) ? 0 : 1;
}

sub _var_seq {
   my ($var, $val) = @_;
   return 0 unless defined $var;
   return $var eq $val ? 1 : 0;
}

sub _var_sneq {
   my ($var, $val) = @_;
   return 0 unless defined $var;
   return _var_seq($var, $val) ? 0 : 1;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;
}
# ###########################################################################
# End VariableAdvisorRules package
# ###########################################################################

# ###########################################################################
# HTTP::Micro package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/HTTP/Micro.pm
#   t/lib/HTTP/Micro.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package HTTP::Micro;

our $VERSION = '0.01';

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Carp ();

my @attributes;
BEGIN {
    @attributes = qw(agent timeout);
    no strict 'refs';
    for my $accessor ( @attributes ) {
        *{$accessor} = sub {
            @_ > 1 ? $_[0]->{$accessor} = $_[1] : $_[0]->{$accessor};
        };
    }
}

sub new {
    my($class, %args) = @_;
    (my $agent = $class) =~ s{::}{-}g;
    my $self = {
        agent        => $agent . "/" . ($class->VERSION || 0),
        timeout      => 60,
    };
    for my $key ( @attributes ) {
        $self->{$key} = $args{$key} if exists $args{$key}
    }
    return bless $self, $class;
}

my %DefaultPort = (
    http => 80,
    https => 443,
);

sub request {
    my ($self, $method, $url, $args) = @_;
    @_ == 3 || (@_ == 4 && ref $args eq 'HASH')
      or Carp::croak(q/Usage: $http->request(METHOD, URL, [HASHREF])/);
    $args ||= {}; # we keep some state in this during _request

    my $response;
    for ( 0 .. 1 ) {
        $response = eval { $self->_request($method, $url, $args) };
        last unless $@ && $method eq 'GET'
            && $@ =~ m{^(?:Socket closed|Unexpected end)};
    }

    if (my $e = "$@") {
        $response = {
            success => q{},
            status  => 599,
            reason  => 'Internal Exception',
            content => $e,
            headers => {
                'content-type'   => 'text/plain',
                'content-length' => length $e,
            }
        };
    }
    return $response;
}

sub _request {
    my ($self, $method, $url, $args) = @_;

    my ($scheme, $host, $port, $path_query) = $self->_split_url($url);

    my $request = {
        method    => $method,
        scheme    => $scheme,
        host_port => ($port == $DefaultPort{$scheme} ? $host : "$host:$port"),
        uri       => $path_query,
        headers   => {},
    };

    my $handle  = HTTP::Micro::Handle->new(timeout => $self->{timeout});

    $handle->connect($scheme, $host, $port);

    $self->_prepare_headers_and_cb($request, $args);
    $handle->write_request_header(@{$request}{qw/method uri headers/});
    $handle->write_content_body($request) if $request->{content};

    my $response;
    do { $response = $handle->read_response_header }
        until (substr($response->{status},0,1) ne '1');

    if (!($method eq 'HEAD' || $response->{status} =~ /^[23]04/)) {
        $response->{content} = '';
        $handle->read_content_body(sub { $_[1]->{content} .= $_[0] }, $response);
    }

    $handle->close;
    $response->{success} = substr($response->{status},0,1) eq '2';
    return $response;
}

sub _prepare_headers_and_cb {
    my ($self, $request, $args) = @_;

    for ($args->{headers}) {
        next unless defined;
        while (my ($k, $v) = each %$_) {
            $request->{headers}{lc $k} = $v;
        }
    }
    $request->{headers}{'host'}         = $request->{host_port};
    $request->{headers}{'connection'}   = "close";
    $request->{headers}{'user-agent'} ||= $self->{agent};

    if (defined $args->{content}) {
        $request->{headers}{'content-type'} ||= "application/octet-stream";
        utf8::downgrade($args->{content}, 1)
            or Carp::croak(q/Wide character in request message body/);
        $request->{headers}{'content-length'} = length $args->{content};
        $request->{content} = $args->{content};
    }
    return;
}

sub _split_url {
    my $url = pop;

    my ($scheme, $authority, $path_query) = $url =~ m<\A([^:/?#]+)://([^/?#]*)([^#]*)>
      or Carp::croak(qq/Cannot parse URL: '$url'/);

    $scheme     = lc $scheme;
    $path_query = "/$path_query" unless $path_query =~ m<\A/>;

    my $host = (length($authority)) ? lc $authority : 'localhost';
       $host =~ s/\A[^@]*@//;   # userinfo
    my $port = do {
       $host =~ s/:([0-9]*)\z// && length $1
         ? $1
         : $DefaultPort{$scheme}
    };

    return ($scheme, $host, $port, $path_query);
}

} # HTTP::Micro

{
   package HTTP::Micro::Handle;

   use strict;
   use warnings FATAL => 'all';
   use English qw(-no_match_vars);

   use Carp       qw(croak);
   use Errno      qw(EINTR EPIPE);
   use IO::Socket qw(SOCK_STREAM);

   sub BUFSIZE () { 32768 }

   my $Printable = sub {
       local $_ = shift;
       s/\r/\\r/g;
       s/\n/\\n/g;
       s/\t/\\t/g;
       s/([^\x20-\x7E])/sprintf('\\x%.2X', ord($1))/ge;
       $_;
   };

   sub new {
       my ($class, %args) = @_;
       return bless {
           rbuf          => '',
           timeout       => 60,
           max_line_size => 16384,
           %args
       }, $class;
   }

   my $ssl_verify_args = {
       check_cn         => "when_only",
       wildcards_in_alt => "anywhere",
       wildcards_in_cn  => "anywhere"
   };

   sub connect {
       @_ == 4 || croak(q/Usage: $handle->connect(scheme, host, port)/);
       my ($self, $scheme, $host, $port) = @_;

       if ( $scheme eq 'https' ) {
           eval "require IO::Socket::SSL"
               unless exists $INC{'IO/Socket/SSL.pm'};
           croak(qq/IO::Socket::SSL must be installed for https support\n/)
               unless $INC{'IO/Socket/SSL.pm'};
       }
       elsif ( $scheme ne 'http' ) {
         croak(qq/Unsupported URL scheme '$scheme'\n/);
       }

       $self->{fh} = IO::Socket::INET->new(
           PeerHost  => $host,
           PeerPort  => $port,
           Proto     => 'tcp',
           Type      => SOCK_STREAM,
           Timeout   => $self->{timeout}
       ) or croak(qq/Could not connect to '$host:$port': $@/);

       binmode($self->{fh})
         or croak(qq/Could not binmode() socket: '$!'/);

       if ( $scheme eq 'https') {
           IO::Socket::SSL->start_SSL($self->{fh});
           ref($self->{fh}) eq 'IO::Socket::SSL'
               or die(qq/SSL connection failed for $host\n/);
           if ( $self->{fh}->can("verify_hostname") ) {
               $self->{fh}->verify_hostname( $host, $ssl_verify_args )
                  or die(qq/SSL certificate not valid for $host\n/);
           }
           else {
            my $fh = $self->{fh};
            _verify_hostname_of_cert($host, _peer_certificate($fh), $ssl_verify_args)
                  or die(qq/SSL certificate not valid for $host\n/);
            }
       }
         
       $self->{host} = $host;
       $self->{port} = $port;

       return $self;
   }

   sub close {
       @_ == 1 || croak(q/Usage: $handle->close()/);
       my ($self) = @_;
       CORE::close($self->{fh})
         or croak(qq/Could not close socket: '$!'/);
   }

   sub write {
       @_ == 2 || croak(q/Usage: $handle->write(buf)/);
       my ($self, $buf) = @_;

       my $len = length $buf;
       my $off = 0;

       local $SIG{PIPE} = 'IGNORE';

       while () {
           $self->can_write
             or croak(q/Timed out while waiting for socket to become ready for writing/);
           my $r = syswrite($self->{fh}, $buf, $len, $off);
           if (defined $r) {
               $len -= $r;
               $off += $r;
               last unless $len > 0;
           }
           elsif ($! == EPIPE) {
               croak(qq/Socket closed by remote server: $!/);
           }
           elsif ($! != EINTR) {
               croak(qq/Could not write to socket: '$!'/);
           }
       }
       return $off;
   }

   sub read {
       @_ == 2 || @_ == 3 || croak(q/Usage: $handle->read(len)/);
       my ($self, $len) = @_;

       my $buf  = '';
       my $got = length $self->{rbuf};

       if ($got) {
           my $take = ($got < $len) ? $got : $len;
           $buf  = substr($self->{rbuf}, 0, $take, '');
           $len -= $take;
       }

       while ($len > 0) {
           $self->can_read
             or croak(q/Timed out while waiting for socket to become ready for reading/);
           my $r = sysread($self->{fh}, $buf, $len, length $buf);
           if (defined $r) {
               last unless $r;
               $len -= $r;
           }
           elsif ($! != EINTR) {
               croak(qq/Could not read from socket: '$!'/);
           }
       }
       if ($len) {
           croak(q/Unexpected end of stream/);
       }
       return $buf;
   }

   sub readline {
       @_ == 1 || croak(q/Usage: $handle->readline()/);
       my ($self) = @_;

       while () {
           if ($self->{rbuf} =~ s/\A ([^\x0D\x0A]* \x0D?\x0A)//x) {
               return $1;
           }
           $self->can_read
             or croak(q/Timed out while waiting for socket to become ready for reading/);
           my $r = sysread($self->{fh}, $self->{rbuf}, BUFSIZE, length $self->{rbuf});
           if (defined $r) {
               last unless $r;
           }
           elsif ($! != EINTR) {
               croak(qq/Could not read from socket: '$!'/);
           }
       }
       croak(q/Unexpected end of stream while looking for line/);
   }

   sub read_header_lines {
       @_ == 1 || @_ == 2 || croak(q/Usage: $handle->read_header_lines([headers])/);
       my ($self, $headers) = @_;
       $headers ||= {};
       my $lines   = 0;
       my $val;

       while () {
            my $line = $self->readline;

            if ($line =~ /\A ([^\x00-\x1F\x7F:]+) : [\x09\x20]* ([^\x0D\x0A]*)/x) {
                my ($field_name) = lc $1;
                $val = \($headers->{$field_name} = $2);
            }
            elsif ($line =~ /\A [\x09\x20]+ ([^\x0D\x0A]*)/x) {
                $val
                  or croak(q/Unexpected header continuation line/);
                next unless length $1;
                $$val .= ' ' if length $$val;
                $$val .= $1;
            }
            elsif ($line =~ /\A \x0D?\x0A \z/x) {
               last;
            }
            else {
               croak(q/Malformed header line: / . $Printable->($line));
            }
       }
       return $headers;
   }

   sub write_header_lines {
       (@_ == 2 && ref $_[1] eq 'HASH') || croak(q/Usage: $handle->write_header_lines(headers)/);
       my($self, $headers) = @_;

       my $buf = '';
       while (my ($k, $v) = each %$headers) {
           my $field_name = lc $k;
            $field_name =~ /\A [\x21\x23-\x27\x2A\x2B\x2D\x2E\x30-\x39\x41-\x5A\x5E-\x7A\x7C\x7E]+ \z/x
               or croak(q/Invalid HTTP header field name: / . $Printable->($field_name));
            $field_name =~ s/\b(\w)/\u$1/g;
            $buf .= "$field_name: $v\x0D\x0A";
       }
       $buf .= "\x0D\x0A";
       return $self->write($buf);
   }

   sub read_content_body {
       @_ == 3 || @_ == 4 || croak(q/Usage: $handle->read_content_body(callback, response, [read_length])/);
       my ($self, $cb, $response, $len) = @_;
       $len ||= $response->{headers}{'content-length'};

       croak("No content-length in the returned response, and this "
           . "UA doesn't implement chunking") unless defined $len;

       while ($len > 0) {
           my $read = ($len > BUFSIZE) ? BUFSIZE : $len;
           $cb->($self->read($read), $response);
           $len -= $read;
       }

       return;
   }

   sub write_content_body {
       @_ == 2 || croak(q/Usage: $handle->write_content_body(request)/);
       my ($self, $request) = @_;
       my ($len, $content_length) = (0, $request->{headers}{'content-length'});

       $len += $self->write($request->{content});

       $len == $content_length
         or croak(qq/Content-Length missmatch (got: $len expected: $content_length)/);

       return $len;
   }

   sub read_response_header {
       @_ == 1 || croak(q/Usage: $handle->read_response_header()/);
       my ($self) = @_;

       my $line = $self->readline;

       $line =~ /\A (HTTP\/(0*\d+\.0*\d+)) [\x09\x20]+ ([0-9]{3}) [\x09\x20]+ ([^\x0D\x0A]*) \x0D?\x0A/x
         or croak(q/Malformed Status-Line: / . $Printable->($line));

       my ($protocol, $version, $status, $reason) = ($1, $2, $3, $4);

       return {
           status   => $status,
           reason   => $reason,
           headers  => $self->read_header_lines,
           protocol => $protocol,
       };
   }

   sub write_request_header {
       @_ == 4 || croak(q/Usage: $handle->write_request_header(method, request_uri, headers)/);
       my ($self, $method, $request_uri, $headers) = @_;

       return $self->write("$method $request_uri HTTP/1.1\x0D\x0A")
            + $self->write_header_lines($headers);
   }

   sub _do_timeout {
       my ($self, $type, $timeout) = @_;
       $timeout = $self->{timeout}
           unless defined $timeout && $timeout >= 0;

       my $fd = fileno $self->{fh};
       defined $fd && $fd >= 0
         or croak(q/select(2): 'Bad file descriptor'/);

       my $initial = time;
       my $pending = $timeout;
       my $nfound;

       vec(my $fdset = '', $fd, 1) = 1;

       while () {
           $nfound = ($type eq 'read')
               ? select($fdset, undef, undef, $pending)
               : select(undef, $fdset, undef, $pending) ;
           if ($nfound == -1) {
               $! == EINTR
                 or croak(qq/select(2): '$!'/);
               redo if !$timeout || ($pending = $timeout - (time - $initial)) > 0;
               $nfound = 0;
           }
           last;
       }
       $! = 0;
       return $nfound;
   }

   sub can_read {
       @_ == 1 || @_ == 2 || croak(q/Usage: $handle->can_read([timeout])/);
       my $self = shift;
       return $self->_do_timeout('read', @_)
   }

   sub can_write {
       @_ == 1 || @_ == 2 || croak(q/Usage: $handle->can_write([timeout])/);
       my $self = shift;
       return $self->_do_timeout('write', @_)
   }
}  # HTTP::Micro::Handle

my $prog = <<'EOP';
BEGIN {
   if ( defined &IO::Socket::SSL::CAN_IPV6 ) {
      *CAN_IPV6 = \*IO::Socket::SSL::CAN_IPV6;
   }
   else {
      constant->import( CAN_IPV6 => '' );
   }
   my %const = (
      NID_CommonName => 13,
      GEN_DNS => 2,
      GEN_IPADD => 7,
   );
   while ( my ($name,$value) = each %const ) {
      no strict 'refs';
      *{$name} = UNIVERSAL::can( 'Net::SSLeay', $name ) || sub { $value };
   }
}
{
   use Carp qw(croak);
   my %dispatcher = (
      issuer =>  sub { Net::SSLeay::X509_NAME_oneline( Net::SSLeay::X509_get_issuer_name( shift )) },
      subject => sub { Net::SSLeay::X509_NAME_oneline( Net::SSLeay::X509_get_subject_name( shift )) },
   );
   if ( $Net::SSLeay::VERSION >= 1.30 ) {
      $dispatcher{commonName} = sub {
         my $cn = Net::SSLeay::X509_NAME_get_text_by_NID(
            Net::SSLeay::X509_get_subject_name( shift ), NID_CommonName);
         $cn =~s{\0$}{}; # work around Bug in Net::SSLeay <1.33
         $cn;
      }
   } else {
      $dispatcher{commonName} = sub {
         croak "you need at least Net::SSLeay version 1.30 for getting commonName"
      }
   }

   if ( $Net::SSLeay::VERSION >= 1.33 ) {
      $dispatcher{subjectAltNames} = sub { Net::SSLeay::X509_get_subjectAltNames( shift ) };
   } else {
      $dispatcher{subjectAltNames} = sub {
         return;
      };
   }

   $dispatcher{authority} = $dispatcher{issuer};
   $dispatcher{owner}     = $dispatcher{subject};
   $dispatcher{cn}        = $dispatcher{commonName};

   sub _peer_certificate {
      my ($self, $field) = @_;
      my $ssl = $self->_get_ssl_object or return;

      my $cert = ${*$self}{_SSL_certificate}
         ||= Net::SSLeay::get_peer_certificate($ssl)
         or return $self->error("Could not retrieve peer certificate");

      if ($field) {
         my $sub = $dispatcher{$field} or croak
            "invalid argument for peer_certificate, valid are: ".join( " ",keys %dispatcher ).
            "\nMaybe you need to upgrade your Net::SSLeay";
         return $sub->($cert);
      } else {
         return $cert
      }
   }


   my %scheme = (
      ldap => {
         wildcards_in_cn    => 0,
         wildcards_in_alt => 'leftmost',
         check_cn         => 'always',
      },
      http => {
         wildcards_in_cn    => 'anywhere',
         wildcards_in_alt => 'anywhere',
         check_cn         => 'when_only',
      },
      smtp => {
         wildcards_in_cn    => 0,
         wildcards_in_alt => 0,
         check_cn         => 'always'
      },
      none => {}, # do not check
   );

   $scheme{www}  = $scheme{http}; # alias
   $scheme{xmpp} = $scheme{http}; # rfc 3920
   $scheme{pop3} = $scheme{ldap}; # rfc 2595
   $scheme{imap} = $scheme{ldap}; # rfc 2595
   $scheme{acap} = $scheme{ldap}; # rfc 2595
   $scheme{nntp} = $scheme{ldap}; # rfc 4642
   $scheme{ftp}  = $scheme{http}; # rfc 4217


   sub _verify_hostname_of_cert {
      my $identity = shift;
      my $cert = shift;
      my $scheme = shift || 'none';
      if ( ! ref($scheme) ) {
         $scheme = $scheme{$scheme} or croak "scheme $scheme not defined";
      }

      return 1 if ! %$scheme; # 'none'

      my $commonName = $dispatcher{cn}->($cert);
      my @altNames   = $dispatcher{subjectAltNames}->($cert);

      if ( my $sub = $scheme->{callback} ) {
         return $sub->($identity,$commonName,@altNames);
      }


      my $ipn;
      if ( CAN_IPV6 and $identity =~m{:} ) {
         $ipn = IO::Socket::SSL::inet_pton(IO::Socket::SSL::AF_INET6,$identity)
            or croak "'$identity' is not IPv6, but neither IPv4 nor hostname";
      } elsif ( $identity =~m{^\d+\.\d+\.\d+\.\d+$} ) {
         $ipn = IO::Socket::SSL::inet_aton( $identity ) or croak "'$identity' is not IPv4, but neither IPv6 nor hostname";
      } else {
         if ( $identity =~m{[^a-zA-Z0-9_.\-]} ) {
            $identity =~m{\0} and croak("name '$identity' has \\0 byte");
            $identity = IO::Socket::SSL::idn_to_ascii($identity) or
               croak "Warning: Given name '$identity' could not be converted to IDNA!";
         }
      }

      my $check_name = sub {
         my ($name,$identity,$wtyp) = @_;
         $wtyp ||= '';
         my $pattern;
         if ( $wtyp eq 'anywhere' and $name =~m{^([a-zA-Z0-9_\-]*)\*(.+)} ) {
            $pattern = qr{^\Q$1\E[a-zA-Z0-9_\-]*\Q$2\E$}i;
         } elsif ( $wtyp eq 'leftmost' and $name =~m{^\*(\..+)$} ) {
            $pattern = qr{^[a-zA-Z0-9_\-]*\Q$1\E$}i;
         } else {
            $pattern = qr{^\Q$name\E$}i;
         }
         return $identity =~ $pattern;
      };

      my $alt_dnsNames = 0;
      while (@altNames) {
         my ($type, $name) = splice (@altNames, 0, 2);
         if ( $ipn and $type == GEN_IPADD ) {
            return 1 if $ipn eq $name;

         } elsif ( ! $ipn and $type == GEN_DNS ) {
            $name =~s/\s+$//; $name =~s/^\s+//;
            $alt_dnsNames++;
            $check_name->($name,$identity,$scheme->{wildcards_in_alt})
               and return 1;
         }
      }

      if ( ! $ipn and (
         $scheme->{check_cn} eq 'always' or
         $scheme->{check_cn} eq 'when_only' and !$alt_dnsNames)) {
         $check_name->($commonName,$identity,$scheme->{wildcards_in_cn})
            and return 1;
      }

      return 0; # no match
   }
}
EOP

eval { require IO::Socket::SSL };
if ( $INC{"IO/Socket/SSL.pm"} ) {
   eval $prog;
   die $@ if $@;
}

1;
# ###########################################################################
# End HTTP::Micro package
# ###########################################################################

# ###########################################################################
# VersionCheck package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/VersionCheck.pm
#   t/lib/VersionCheck.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package VersionCheck;


use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);

use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
local $Data::Dumper::Indent    = 1;
local $Data::Dumper::Sortkeys  = 1;
local $Data::Dumper::Quotekeys = 0;

use Digest::MD5 qw(md5_hex);
use Sys::Hostname qw(hostname);
use File::Basename qw();
use File::Spec;
use FindBin qw();

eval {
   require Percona::Toolkit;
   require HTTP::Micro;
};

my $home    = $ENV{HOME} || $ENV{HOMEPATH} || $ENV{USERPROFILE} || '.';
my @vc_dirs = (
   '/etc/percona',
   '/etc/percona-toolkit',
   '/tmp',
   "$home",
);

{
   my $file    = 'percona-version-check';

   sub version_check_file {
      foreach my $dir ( @vc_dirs ) {
         if ( -d $dir && -w $dir ) {
            PTDEBUG && _d('Version check file', $file, 'in', $dir);
            return $dir . '/' . $file;
         }
      }
      PTDEBUG && _d('Version check file', $file, 'in', $ENV{PWD});
      return $file;  # in the CWD
   } 
}

sub version_check_time_limit {
   return 60 * 60 * 24;  # one day
}


sub version_check {
   my (%args) = @_;

   my $instances = $args{instances} || [];
   my $instances_to_check;

   PTDEBUG && _d('FindBin::Bin:', $FindBin::Bin);
   if ( !$args{force} ) {
      if ( $FindBin::Bin
           && (-d "$FindBin::Bin/../.bzr"    || 
               -d "$FindBin::Bin/../../.bzr" ||
               -d "$FindBin::Bin/../.git"    || 
               -d "$FindBin::Bin/../../.git" 
              ) 
         ) {
         PTDEBUG && _d("$FindBin::Bin/../.bzr disables --version-check");
         return;
      }
   }

   eval {
      foreach my $instance ( @$instances ) {
         my ($name, $id) = get_instance_id($instance);
         $instance->{name} = $name;
         $instance->{id}   = $id;
      }

      push @$instances, { name => 'system', id => 0 };

      $instances_to_check = get_instances_to_check(
         instances => $instances,
         vc_file   => $args{vc_file},  # testing
         now       => $args{now},      # testing
      );
      PTDEBUG && _d(scalar @$instances_to_check, 'instances to check');
      return unless @$instances_to_check;

      my $protocol = 'https';  
      eval { require IO::Socket::SSL; };
      if ( $EVAL_ERROR ) {
         PTDEBUG && _d($EVAL_ERROR);
         PTDEBUG && _d("SSL not available, won't run version_check");
         return;
      }
      PTDEBUG && _d('Using', $protocol);

      my $advice = pingback(
         instances => $instances_to_check,
         protocol  => $protocol,
         url       => $args{url}                       # testing
                   || $ENV{PERCONA_VERSION_CHECK_URL}  # testing
                   || "$protocol://v.percona.com",
      );
      if ( $advice ) {
         PTDEBUG && _d('Advice:', Dumper($advice));
         if ( scalar @$advice > 1) {
            print "\n# " . scalar @$advice . " software updates are "
               . "available:\n";
         }
         else {
            print "\n# A software update is available:\n";
         }
         print join("\n", map { "#   * $_" } @$advice), "\n\n";
      }
   };
   if ( $EVAL_ERROR ) {
      PTDEBUG && _d('Version check failed:', $EVAL_ERROR);
   }

   if ( @$instances_to_check ) {
      eval {
         update_check_times(
            instances => $instances_to_check,
            vc_file   => $args{vc_file},  # testing
            now       => $args{now},      # testing
         );
      };
      if ( $EVAL_ERROR ) {
         PTDEBUG && _d('Error updating version check file:', $EVAL_ERROR);
      }
   }

   if ( $ENV{PTDEBUG_VERSION_CHECK} ) {
      warn "Exiting because the PTDEBUG_VERSION_CHECK "
         . "environment variable is defined.\n";
      exit 255;
   }

   return;
}

sub get_instances_to_check {
   my (%args) = @_;

   my $instances = $args{instances};
   my $now       = $args{now}     || int(time);
   my $vc_file   = $args{vc_file} || version_check_file();

   if ( !-f $vc_file ) {
      PTDEBUG && _d('Version check file', $vc_file, 'does not exist;',
         'version checking all instances');
      return $instances;
   }

   open my $fh, '<', $vc_file or die "Cannot open $vc_file: $OS_ERROR";
   chomp(my $file_contents = do { local $/ = undef; <$fh> });
   PTDEBUG && _d('Version check file', $vc_file, 'contents:', $file_contents);
   close $fh;
   my %last_check_time_for = $file_contents =~ /^([^,]+),(.+)$/mg;

   my $check_time_limit = version_check_time_limit();
   my @instances_to_check;
   foreach my $instance ( @$instances ) {
      my $last_check_time = $last_check_time_for{ $instance->{id} };
      PTDEBUG && _d('Intsance', $instance->{id}, 'last checked',
         $last_check_time, 'now', $now, 'diff', $now - ($last_check_time || 0),
         'hours until next check',
         sprintf '%.2f',
            ($check_time_limit - ($now - ($last_check_time || 0))) / 3600);
      if ( !defined $last_check_time
           || ($now - $last_check_time) >= $check_time_limit ) {
         PTDEBUG && _d('Time to check', Dumper($instance));
         push @instances_to_check, $instance;
      }
   }

   return \@instances_to_check;
}

sub update_check_times {
   my (%args) = @_;

   my $instances = $args{instances};
   my $now       = $args{now}     || int(time);
   my $vc_file   = $args{vc_file} || version_check_file();
   PTDEBUG && _d('Updating last check time:', $now);

   my %all_instances = map {
      $_->{id} => { name => $_->{name}, ts => $now }
   } @$instances;

   if ( -f $vc_file ) {
      open my $fh, '<', $vc_file or die "Cannot read $vc_file: $OS_ERROR";
      my $contents = do { local $/ = undef; <$fh> };
      close $fh;

      foreach my $line ( split("\n", ($contents || '')) ) {
         my ($id, $ts) = split(',', $line);
         if ( !exists $all_instances{$id} ) {
            $all_instances{$id} = { ts => $ts };  # original ts, not updated
         }
      }
   }

   open my $fh, '>', $vc_file or die "Cannot write to $vc_file: $OS_ERROR";
   foreach my $id ( sort keys %all_instances ) {
      PTDEBUG && _d('Updated:', $id, Dumper($all_instances{$id}));
      print { $fh } $id . ',' . $all_instances{$id}->{ts} . "\n";
   }
   close $fh;

   return;
}

sub get_instance_id {
   my ($instance) = @_;

   my $dbh = $instance->{dbh};
   my $dsn = $instance->{dsn};

   my $sql = q{SELECT CONCAT(@@hostname, @@port)};
   PTDEBUG && _d($sql);
   my ($name) = eval { $dbh->selectrow_array($sql) };
   if ( $EVAL_ERROR ) {
      PTDEBUG && _d($EVAL_ERROR);
      $sql = q{SELECT @@hostname};
      PTDEBUG && _d($sql);
      ($name) = eval { $dbh->selectrow_array($sql) };
      if ( $EVAL_ERROR ) {
         PTDEBUG && _d($EVAL_ERROR);
         $name = ($dsn->{h} || 'localhost') . ($dsn->{P} || 3306);
      }
      else {
         $sql = q{SHOW VARIABLES LIKE 'port'};
         PTDEBUG && _d($sql);
         my (undef, $port) = eval { $dbh->selectrow_array($sql) };
         PTDEBUG && _d('port:', $port);
         $name .= $port || '';
      }
   }
   my $id = md5_hex($name);

   PTDEBUG && _d('MySQL instance:', $id, $name, Dumper($dsn));

   return $name, $id;
}


sub get_uuid {
    my $uuid_file = '/.percona-toolkit.uuid';
    foreach my $dir (@vc_dirs) {
        my $filename = $dir.$uuid_file;
        my $uuid=_read_uuid($filename);
        return $uuid if $uuid;
    }

    my $filename = $ENV{"HOME"} . $uuid_file;
    my $uuid = _generate_uuid();

    open(my $fh, '>', $filename) or die "Could not open file '$filename' $!";
    print $fh $uuid;
    close $fh;

    return $uuid;
}   

sub _generate_uuid {
    return sprintf+($}="%04x")."$}-$}-$}-$}-".$}x3,map rand 65537,0..7;
}

sub _read_uuid {
    my $filename = shift;
    my $fh;

    eval {
        open($fh, '<:encoding(UTF-8)', $filename);
    };
    return if ($EVAL_ERROR);

    my $uuid;
    eval { $uuid = <$fh>; };
    return if ($EVAL_ERROR);

    chomp $uuid;
    return $uuid;
}


sub pingback {
   my (%args) = @_;
   my @required_args = qw(url instances);
   foreach my $arg ( @required_args ) {
      die "I need a $arg arugment" unless $args{$arg};
   }
   my $url       = $args{url};
   my $instances = $args{instances};

   my $ua = $args{ua} || HTTP::Micro->new( timeout => 3 );

   my $response = $ua->request('GET', $url);
   PTDEBUG && _d('Server response:', Dumper($response));
   die "No response from GET $url"
      if !$response;
   die("GET on $url returned HTTP status $response->{status}; expected 200\n",
       ($response->{content} || '')) if $response->{status} != 200;
   die("GET on $url did not return any programs to check")
      if !$response->{content};

   my $items = parse_server_response(
      response => $response->{content}
   );
   die "Failed to parse server requested programs: $response->{content}"
      if !scalar keys %$items;
      
   my $versions = get_versions(
      items     => $items,
      instances => $instances,
   );
   die "Failed to get any program versions; should have at least gotten Perl"
      if !scalar keys %$versions;

   my $client_content = encode_client_response(
      items      => $items,
      versions   => $versions,
      general_id => get_uuid(),
   );

   my $client_response = {
      headers => { "X-Percona-Toolkit-Tool" => File::Basename::basename($0) },
      content => $client_content,
   };
   PTDEBUG && _d('Client response:', Dumper($client_response));

   $response = $ua->request('POST', $url, $client_response);
   PTDEBUG && _d('Server suggestions:', Dumper($response));
   die "No response from POST $url $client_response"
      if !$response;
   die "POST $url returned HTTP status $response->{status}; expected 200"
      if $response->{status} != 200;

   return unless $response->{content};

   $items = parse_server_response(
      response   => $response->{content},
      split_vars => 0,
   );
   die "Failed to parse server suggestions: $response->{content}"
      if !scalar keys %$items;
   my @suggestions = map { $_->{vars} }
                     sort { $a->{item} cmp $b->{item} }
                     values %$items;

   return \@suggestions;
}

sub encode_client_response {
   my (%args) = @_;
   my @required_args = qw(items versions general_id);
   foreach my $arg ( @required_args ) {
      die "I need a $arg arugment" unless $args{$arg};
   }
   my ($items, $versions, $general_id) = @args{@required_args};

   my @lines;
   foreach my $item ( sort keys %$items ) {
      next unless exists $versions->{$item};
      if ( ref($versions->{$item}) eq 'HASH' ) {
         my $mysql_versions = $versions->{$item};
         for my $id ( sort keys %$mysql_versions ) {
            push @lines, join(';', $id, $item, $mysql_versions->{$id});
         }
      }
      else {
         push @lines, join(';', $general_id, $item, $versions->{$item});
      }
   }

   my $client_response = join("\n", @lines) . "\n";
   return $client_response;
}

sub parse_server_response {
   my (%args) = @_;
   my @required_args = qw(response);
   foreach my $arg ( @required_args ) {
      die "I need a $arg arugment" unless $args{$arg};
   }
   my ($response) = @args{@required_args};

   my %items = map {
      my ($item, $type, $vars) = split(";", $_);
      if ( !defined $args{split_vars} || $args{split_vars} ) {
         $vars = [ split(",", ($vars || '')) ];
      }
      $item => {
         item => $item,
         type => $type,
         vars => $vars,
      };
   } split("\n", $response);

   PTDEBUG && _d('Items:', Dumper(\%items));

   return \%items;
}

my %sub_for_type = (
   os_version          => \&get_os_version,
   perl_version        => \&get_perl_version,
   perl_module_version => \&get_perl_module_version,
   mysql_variable      => \&get_mysql_variable,
);

sub valid_item {
   my ($item) = @_;
   return unless $item;
   if ( !exists $sub_for_type{ $item->{type} } ) {
      PTDEBUG && _d('Invalid type:', $item->{type});
      return 0;
   }
   return 1;
}

sub get_versions {
   my (%args) = @_;
   my @required_args = qw(items);
   foreach my $arg ( @required_args ) {
      die "I need a $arg arugment" unless $args{$arg};
   }
   my ($items) = @args{@required_args};

   my %versions;
   foreach my $item ( values %$items ) {
      next unless valid_item($item);
      eval {
         my $version = $sub_for_type{ $item->{type} }->(
            item      => $item,
            instances => $args{instances},
         );
         if ( $version ) {
            chomp $version unless ref($version);
            $versions{$item->{item}} = $version;
         }
      };
      if ( $EVAL_ERROR ) {
         PTDEBUG && _d('Error getting version for', Dumper($item), $EVAL_ERROR);
      }
   }

   return \%versions;
}


sub get_os_version {
   if ( $OSNAME eq 'MSWin32' ) {
      require Win32;
      return Win32::GetOSDisplayName();
   }

  chomp(my $platform = `uname -s`);
  PTDEBUG && _d('platform:', $platform);
  return $OSNAME unless $platform;

   chomp(my $lsb_release
            = `which lsb_release 2>/dev/null | awk '{print \$1}'` || '');
   PTDEBUG && _d('lsb_release:', $lsb_release);

   my $release = "";

   if ( $platform eq 'Linux' ) {
      if ( -f "/etc/fedora-release" ) {
         $release = `cat /etc/fedora-release`;
      }
      elsif ( -f "/etc/redhat-release" ) {
         $release = `cat /etc/redhat-release`;
      }
      elsif ( -f "/etc/system-release" ) {
         $release = `cat /etc/system-release`;
      }
      elsif ( $lsb_release ) {
         $release = `$lsb_release -ds`;
      }
      elsif ( -f "/etc/lsb-release" ) {
         $release = `grep DISTRIB_DESCRIPTION /etc/lsb-release`;
         $release =~ s/^\w+="([^"]+)".+/$1/;
      }
      elsif ( -f "/etc/debian_version" ) {
         chomp(my $rel = `cat /etc/debian_version`);
         $release = "Debian $rel";
         if ( -f "/etc/apt/sources.list" ) {
             chomp(my $code_name = `awk '/^deb/ {print \$3}' /etc/apt/sources.list | awk -F/ '{print \$1}'| awk 'BEGIN {FS="|"} {print \$1}' | sort | uniq -c | sort -rn | head -n1 | awk '{print \$2}'`);
             $release .= " ($code_name)" if $code_name;
         }
      }
      elsif ( -f "/etc/os-release" ) { # openSUSE
         chomp($release = `grep PRETTY_NAME /etc/os-release`);
         $release =~ s/^PRETTY_NAME="(.+)"$/$1/;
      }
      elsif ( `ls /etc/*release 2>/dev/null` ) {
         if ( `grep DISTRIB_DESCRIPTION /etc/*release 2>/dev/null` ) {
            $release = `grep DISTRIB_DESCRIPTION /etc/*release | head -n1`;
         }
         else {
            $release = `cat /etc/*release | head -n1`;
         }
      }
   }
   elsif ( $platform =~ m/(?:BSD|^Darwin)$/ ) {
      my $rel = `uname -r`;
      $release = "$platform $rel";
   }
   elsif ( $platform eq "SunOS" ) {
      my $rel = `head -n1 /etc/release` || `uname -r`;
      $release = "$platform $rel";
   }

   if ( !$release ) {
      PTDEBUG && _d('Failed to get the release, using platform');
      $release = $platform;
   }
   chomp($release);

   $release =~ s/^"|"$//g;

   PTDEBUG && _d('OS version =', $release);
   return $release;
}

sub get_perl_version {
   my (%args) = @_;
   my $item = $args{item};
   return unless $item;

   my $version = sprintf '%vd', $PERL_VERSION;
   PTDEBUG && _d('Perl version', $version);
   return $version;
}

sub get_perl_module_version {
   my (%args) = @_;
   my $item = $args{item};
   return unless $item;

   my $var     = '$' . $item->{item} . '::VERSION';
   my $version = eval "use $item->{item}; $var;";
   PTDEBUG && _d('Perl version for', $var, '=', $version);
   return $version;
}

sub get_mysql_variable {
   return get_from_mysql(
      show => 'VARIABLES',
      @_,
   );
}

sub get_from_mysql {
   my (%args) = @_;
   my $show      = $args{show};
   my $item      = $args{item};
   my $instances = $args{instances};
   return unless $show && $item;

   if ( !$instances || !@$instances ) {
      PTDEBUG && _d('Cannot check', $item,
         'because there are no MySQL instances');
      return;
   }

   if ($item->{item} eq 'MySQL' && $item->{type} eq 'mysql_variable') {
      @{$item->{vars}} = grep { $_ eq 'version' || $_ eq 'version_comment' } @{$item->{vars}};
   }
 

   my @versions;
   my %version_for;
   foreach my $instance ( @$instances ) {
      next unless $instance->{id};  # special system instance has id=0
      my $dbh = $instance->{dbh};
      local $dbh->{FetchHashKeyName} = 'NAME_lc';
      my $sql = qq/SHOW $show/;
      PTDEBUG && _d($sql);
      my $rows = $dbh->selectall_hashref($sql, 'variable_name');

      my @versions;
      foreach my $var ( @{$item->{vars}} ) {
         $var = lc($var);
         my $version = $rows->{$var}->{value};
         PTDEBUG && _d('MySQL version for', $item->{item}, '=', $version,
            'on', $instance->{name});
         push @versions, $version;
      }
      $version_for{ $instance->{id} } = join(' ', @versions);
   }

   return \%version_for;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;
}
# ###########################################################################
# End VersionCheck package
# ###########################################################################

# ###########################################################################
# This is a combination of modules and programs in one -- a runnable module.
# http://www.perl.com/pub/a/2006/07/13/lightning-articles.html?page=last
# Or, look it up in the Camel book on pages 642 and 643 in the 3rd edition.
#
# Check at the end of this package for the call to main() which actually runs
# the program.
# ###########################################################################
package pt_variable_advisor;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);

use Percona::Toolkit;
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub main {
   local @ARGV = @_;  # set global ARGV for this package

   # ########################################################################
   # Get configuration information.
   # ########################################################################
   my $o = new OptionParser();
   $o->get_specs();
   $o->get_opts();

   my $dp = $o->DSNParser();
   $dp->prop('set-vars', $o->set_vars());

   my $vars_from         = $o->get('source-of-variables');
   # my $status_from       = lc $o->get('source-of-status');
   # my $slave_status_from = lc $o->get('source-of-slave-status');

   my $need_dbh = $vars_from =~ m/^mysql$/i; # || $status_from eq 'mysql' etc.

   if ( !$o->get('help') ) {
      if ( $vars_from =~ m/^mysql$/i && @ARGV == 0 ) {
         $o->save_error("A DSN must be specified when --source-of-variables=mysql");
      }
   }

   $o->usage_or_errors();

   # #########################################################################
   # Check that any files given exit.
   # #########################################################################
   if ( $vars_from !~ m/^mysql|none^/i ) {
      die "The --source-of-variables file $vars_from does not exist"
         unless -f $vars_from;
   }

   # #########################################################################
   # Load rules from POD and plugins.
   # #########################################################################
   my $p   = new PodParser();
   my $var = new VariableAdvisorRules(PodParser => $p);
   my $adv = new Advisor(
      match_type   => "bool",
      ignore_rules => $o->get('ignore-rules'),
   );

   $var->load_rule_info(
      file    => __FILE__,
      section => 'RULES',
   );
   $adv->load_rules($var);
   $adv->load_rule_info($var);

   # TODO: load rules from plugins

   # #########################################################################
   # Make common modules.
   # #########################################################################
   my $trp = new TextResultSetParser();
   my %common_modules = (
      OptionParser        => $o,
      DSNParser           => $dp,
      TextResultSetParser => $trp,
   );

   # ##########################################################################
   # Connect to MySQL if any of the input sources is mysql.
   # ##########################################################################
   my ($dbh, $dsn);
   if ( $need_dbh ) {
      my $dsn_defaults = $dp->parse_options($o);
      $dsn             = $dp->parse(shift @ARGV, $dsn_defaults);

      if ( $o->get('ask-pass') ) {
         $dsn->{p} = OptionParser::prompt_noecho("Enter password: ");
      }

      $dbh = $dp->get_dbh($dp->get_cxn_params($dsn), {AutoCommit => 1});
      $dbh->{FetchHashKeyName} = 'NAME_lc';
      PTDEBUG && _d('Connected dbh', $dbh);
   }

   # ########################################################################
   # Daemonize now that everything is setup and ready to work.
   # ########################################################################
   my $daemon;
   if ( $o->get('daemonize') ) {
      $daemon = new Daemon(o=>$o);
      $daemon->daemonize();
      PTDEBUG && _d('I am a daemon now');
   }
   elsif ( $o->get('pid') ) {
      # We're not daemoninzing, it just handles PID stuff.
      $daemon = new Daemon(o=>$o);
      $daemon->make_PID_file();
   }

   # ########################################################################
   # Do the version-check
   # ########################################################################
   if ( $o->get('version-check') && (!$o->has('quiet') || !$o->get('quiet')) ) {
      VersionCheck::version_check(
         force     => $o->got('version-check'),
         instances => [ ($dbh ? { dbh => $dbh, dsn => $dsn } : ()) ],
      );
   }

   # #########################################################################
   # Get the variables and other MySQL info to pass to rules.
   # #########################################################################
   my $vars = get_variables(
      source => $vars_from,
      dbh    => $dbh,
      %common_modules,
   );

   my $mysql_version  = VersionParser->new($vars->{version});
   my $innodb_version = VersionParser->new($dbh)->innodb_version()
                           if $dbh;
   PTDEBUG && _d("MySQL version", $mysql_version,
      "InnoDB version", $innodb_version);

   # #########################################################################
   # Run rules, print advice.
   # #########################################################################
   my ($advice) = $adv->run_rules(
      variables      => $vars,
      mysql_version  => $mysql_version,
      innodb_version => $innodb_version,
      %common_modules,
   );

   print_advice(
      advice  => $advice,
      Advisor => $adv,
      %common_modules,
   );

   return 0;
}

# ##########################################################################
# Subroutines
# ##########################################################################

# Sub: get_variables
#   Get SHOW VARIABLES from MySQL or a file.
#
# Parameters:
#   %args - Arguments
#
# Required Arguments:
#   source - "mysql" or a file name
#
# Optional Arguments:
#   dbh                 - dbh if source=="mysql"
#   TextResultSetParser - <TextResultSetParser> object if source==file
#
# Returns:
#   Hashref of SHOW /*40003 GLOBAL*/ VARIABLES values.
sub get_variables {
   my ( %args ) = @_;
   my @required_args = qw(source);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($source) = @args{@required_args};

   my $vars;
   if ( ($source || '') =~ m/^mysql$/i ) {
      my $dbh = $args{dbh};
      die "I need a dbh argument" unless $dbh;
      PTDEBUG && _d("Getting variables from dbh", $dbh);
      my $sql = "SHOW /*40003 GLOBAL*/ VARIABLES";
      PTDEBUG && _d($dbh, $sql);
      map { $vars->{$_->{variable_name}} = $_->{value}; }
         @{ $dbh->selectall_arrayref($sql, {Slice=>{}}) };
   }
   else {
      my $trp = $args{TextResultSetParser};
      die "I need a TextResultSetParser arg" unless $trp;
      PTDEBUG && _d("Getting variables from", $source);
      open my $fh, "<", $source or die "Cannot open $source: $OS_ERROR";
      my $contents = do { local $/ = undef; <$fh> };
      close $fh;
      map { $vars->{$_->{Variable_name}} = $_->{Value} }
         @{ $trp->parse($contents) };
   }

   return $vars;
}

# Sub: print_advice
#   Print information about rules that matched.
#
# Parameters:
#   %args - Arguments
#
# Required Arguments:
#   advice       - Arrayref of rule IDs, returned by <Advisor::run_rules()>
#   Advisor      - <Advisor> object
#   OptionParser - <OptionParser> object
sub print_advice {
   my ( %args ) = @_;
   my @required_args = qw(advice Advisor OptionParser);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($advice, $adv, $o) = @args{@required_args};
   my $verbose = $o->get('verbose');

   return unless scalar @$advice;

   foreach my $id ( @$advice ) {
      my $info = $adv->get_rule_info($id);
      my @desc = map {
         $_ .= '.' unless m/[.?]$/;
         $_;
      } split(/(?<=[.?])\s{1,2}/, $info->{description} || '');
      $desc[1] ||= "";  # Some desc have only 1 sentence.
      my $desc = $verbose == 1 ? $desc[0]             # terse
               : $verbose == 2 ? "$desc[0] $desc[1]"  # fuller
               : $verbose >  2 ? $info->{description} # complete
               :                 '';                  # none
      print "# ", uc $info->{severity}, " $id: $desc\n\n";
   }

   return;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

# ############################################################################
# Run the program.
# ############################################################################
if ( !caller ) { exit main(@ARGV); }

1; # Because this is a module as well as a script.

# ############################################################################
# Documentation
# ############################################################################

=pod

=head1 NAME

pt-variable-advisor - Analyze MySQL variables and advise on possible problems.

=head1 SYNOPSIS

Usage: pt-variable-advisor [OPTIONS] [DSN]

pt-variable-advisor analyzes variables and advises on possible problems.

Get SHOW VARIABLES from localhost:

  pt-variable-advisor localhost

Get SHOW VARIABLES output saved in vars.txt:

  pt-variable-advisor --source-of-variables vars.txt

=head1 RISKS

Percona Toolkit is mature, proven in the real world, and well tested,
but all database tools can pose a risk to the system and the database
server.  Before using this tool, please:

=over

=item * Read the tool's documentation

=item * Review the tool's known L<"BUGS">

=item * Test the tool on a non-production server

=item * Backup your production server and verify the backups

=back

=head1 DESCRIPTION

pt-variable-advisor examines C<SHOW VARIABLES> for bad values and settings
according to the L<"RULES"> described below.  It reports on variables that
match the rules, so you can find bad settings in your MySQL server.

At the time of this release, pt-variable-advisor only examples
C<SHOW VARIABLES>, but other input sources are planned like C<SHOW STATUS>
and C<SHOW SLAVE STATUS>.

=head1 RULES

These are the rules that pt-variable-advisor will apply to SHOW VARIABLES.
Each rule has three parts: an ID, a severity, and a description.

The rule's ID is a short, unique name for the rule.  It usually relates
to the variable that the rule examines.  If a variable is examined by
several rules, then the rules' IDs are numbered like "-1", "-2", "-N".

The rule's severity is an indication of how important it is that this
rule matched a query.  We use NOTE, WARN, and CRIT to denote these
levels.

The rule's description is a textual, human-readable explanation of
what it means when a variable matches this rule.  Depending on the
verbosity of the report you generate, you will see more of the text in
the description.  By default, you'll see only the first sentence,
which is sort of a terse synopsis of the rule's meaning.  At a higher
verbosity, you'll see subsequent sentences.

=over

=item auto_increment

severity: note

Are you trying to write to more than one server in a dual-master or
ring replication configuration?  This is potentially very dangerous and in
most cases is a serious mistake.  Most people's reasons for doing this are
actually not valid at all.

=item concurrent_insert

severity: note

Holes (spaces left by deletes) in MyISAM tables might never be
reused.

=item connect_timeout

severity: note 

A large value of this setting can create a denial of service
vulnerability.

=item debug

severity: crit

Servers built with debugging capability should not be used in
production because of the large performance impact.

=item delay_key_write

severity: warn

MyISAM index blocks are never flushed until necessary.  If there is
a server crash, data corruption on MyISAM tables can be much worse than
usual.

=item flush

severity: warn 

This option might decrease performance greatly.

=item flush_time

severity: warn 

This option might decrease performance greatly.

=item have_bdb

severity: note 

The BDB engine is deprecated.  If you aren't using it, you should
disable it with the skip_bdb option.

=item init_connect

severity: note

The init_connect option is enabled on this server.

=item init_file

severity: note 

The init_file option is enabled on this server.

=item init_slave

severity: note

The init_slave option is enabled on this server.

=item innodb_additional_mem_pool_size

severity: warn

This variable generally doesn't need to be larger than 20MB.

=item innodb_buffer_pool_size

severity: warn 

The InnoDB buffer pool size is unconfigured.  In a production
environment it should always be configured explicitly, and the default
10MB size is not good.

=item innodb_checksums

severity: warn 

InnoDB checksums are disabled.  Your data is not protected from
hardware corruption or other errors!

=item innodb_doublewrite

severity: warn 

InnoDB doublewrite is disabled.  Unless you use a filesystem that
protects against partial page writes, your data is not safe!

=item innodb_fast_shutdown

severity: warn

InnoDB's shutdown behavior is not the default.  This can lead to
poor performance, or the need to perform crash recovery upon startup.

=item innodb_flush_log_at_trx_commit-1

severity: warn 

InnoDB is not configured in strictly ACID mode.  If there
is a crash, some transactions can be lost.

=item innodb_flush_log_at_trx_commit-2

severity: warn

Setting innodb_flush_log_at_trx_commit to 0 has no performance
benefits over setting it to 2, and more types of data loss are possible.
If you are trying to change it from 1 for performance reasons, you should
set it to 2 instead of 0.

=item innodb_force_recovery

severity: warn 

InnoDB is in forced recovery mode!  This should be used only
temporarily when recovering from data corruption or other bugs, not for
normal usage.

=item innodb_lock_wait_timeout

severity: warn 

This option has an unusually long value, which can cause
system overload if locks are not being released.

=item innodb_log_buffer_size

severity: warn 

The InnoDB log buffer size generally should not be set larger than
16MB.  If you are doing large BLOB operations, InnoDB is not really a good
choice of engines anyway.

=item innodb_log_file_size

severity: warn 

The InnoDB log file size is set to its default value, which is not
usable on production systems.

=item innodb_max_dirty_pages_pct

severity: note 

The innodb_max_dirty_pages_pct is lower than the default.  This can
cause overly aggressive flushing and add load to the I/O system.

=item flush_time

severity: warn 

This setting is likely to cause very bad performance every
flush_time seconds.

=item key_buffer_size

severity: warn 

The key buffer size is set to its default value, which is not good 
for most production systems.  In a production environment, key_buffer_size
should be larger than the default 8MB size.

=item large_pages

severity: note 

Large pages are enabled.

=item locked_in_memory

severity: note 

The server is locked in memory with --memlock.

=item log_warnings-1

severity: note

Log_warnings is disabled, so unusual events such as statements
unsafe for replication and aborted connections will not be logged to the
error log.

=item log_warnings-2

severity: note

Log_warnings must be set greater than 1 to log unusual events such
as aborted connections.

=item low_priority_updates

severity: note 

The server is running with non-default lock priority for updates.
This could cause update queries to wait unexpectedly for read queries.

=item max_binlog_size

severity: note 

The max_binlog_size is smaller than the default of 1GB.

=item max_connect_errors

severity: note 

max_connect_errors should probably be set as large as your platform
allows.

=item max_connections

severity: warn 

If the server ever really has more than a thousand threads running,
then the system is likely to spend more time scheduling threads than
really doing useful work.  This variable's value should be considered in
light of your workload.

=item myisam_repair_threads

severity: note 

myisam_repair_threads > 1 enables multi-threaded repair, which is
relatively untested and is still listed as beta-quality code in the
official documentation.

=item old_passwords

severity: warn 

Old-style passwords are insecure.  They are sent in plain text
across the wire.

=item optimizer_prune_level

severity: warn 

The optimizer will use an exhaustive search when planning complex
queries, which can cause the planning process to take a long time.

=item port

severity: note 

The server is listening on a non-default port.

=item query_cache_size-1

severity: note 

The query cache does not scale to large sizes and can cause unstable
performance when larger than 128MB, especially on multi-core machines.

=item query_cache_size-2

severity: warn 

The query cache can cause severe performance problems when it is
larger than 256MB, especially on multi-core machines.

=item read_buffer_size-1

severity: note 

The read_buffer_size variable should generally be left at its
default unless an expert determines it is necessary to change it.

=item read_buffer_size-2

severity: warn 

The read_buffer_size variable should not be larger than 8MB.  It
should generally be left at its default unless an expert determines it is
necessary to change it.  Making it larger than 2MB can hurt performance
significantly, and can make the server crash, swap to death, or just
become extremely unstable.

=item read_rnd_buffer_size-1

severity: note 

The read_rnd_buffer_size variable should generally be left at its
default unless an expert determines it is necessary to change it.

=item read_rnd_buffer_size-2

severity: warn 

The read_rnd_buffer_size variable should not be larger than 4M.  It
should generally be left at its default unless an expert determines it is
necessary to change it.

=item relay_log_space_limit

severity: warn 

Setting relay_log_space_limit can cause replicas to stop fetching binary logs
from their master immediately. This could increase the risk that your data will
be lost if the master crashes. If the replicas have encountered a limit on relay
log space, then it is possible that the latest transactions exist only on the
master and no replica has retrieved them.

=item slave_net_timeout

severity: warn 

This variable is set too high.  This is too long to wait before
noticing that the connection to the master has failed and retrying.  This
should probably be set to 60 seconds or less.  It is also a good idea to
use pt-heartbeat to ensure that the connection does not appear to time out
when the master is simply idle.

=item slave_skip_errors

severity: crit 

You should not set this option.  If replication is having errors,
you need to find and resolve the cause of that; it is likely that your
slave's data is different from the master.  You can find out with
pt-table-checksum.

=item sort_buffer_size-1

severity: note 

The sort_buffer_size variable should generally be left at its
default unless an expert determines it is necessary to change it.

=item sort_buffer_size-2

severity: note 

The sort_buffer_size variable should generally be left at its
default unless an expert determines it is necessary to change it.  Making
it larger than a few MB can hurt performance significantly, and can make
the server crash, swap to death, or just become extremely unstable.

=item sql_notes

severity: note 

This server is configured not to log Note level warnings to the
error log.

=item sync_frm

severity: warn 

It is best to set sync_frm so that .frm files are flushed safely to
disk in case of a server crash.

=item tx_isolation-1

severity: note 

This server's transaction isolation level is non-default.

=item tx_isolation-2

severity: warn 

Most applications should use the default REPEATABLE-READ transaction
isolation level, or in a few cases READ-COMMITTED.

=item expire_logs_days

severity: warn

Binary logs are enabled, but automatic purging is not enabled.  If
you do not purge binary logs, your disk will fill up.  If you delete
binary logs externally to MySQL, you will cause unwanted behaviors.
Always ask MySQL to purge obsolete logs, never delete them externally.

=item innodb_file_io_threads

severity: note 

This option is useless except on Windows.

=item innodb_data_file_path

severity: note 

Auto-extending InnoDB files can consume a lot of disk space that is
very difficult to reclaim later.  Some people prefer to set
innodb_file_per_table and allocate a fixed-size file for ibdata1.

=item innodb_flush_method

severity: note 

Most production database servers that use InnoDB should set
innodb_flush_method to O_DIRECT to avoid double-buffering, unless the I/O
system is very low performance.

=item innodb_locks_unsafe_for_binlog

severity: warn 

This option makes point-in-time recovery from binary logs, and
replication, untrustworthy if statement-based logging is used.

=item innodb_support_xa

severity: warn 

MySQL's internal XA transaction support between InnoDB and the
binary log is disabled.  The binary log might not match InnoDB's state
after crash recovery, and replication might drift out of sync due to
out-of-order statements in the binary log.

=item log_bin

severity: warn 

Binary logging is disabled, so point-in-time recovery and
replication are not possible.

=item log_output

severity: warn 

Directing log output to tables has a high performance impact.

=item max_relay_log_size

severity: note 

A custom max_relay_log_size is defined.

=item myisam_recover_options

severity: warn 

myisam_recover_options should be set to some value such as
BACKUP,FORCE to ensure that table corruption is noticed.

=item storage_engine

severity: note 

The server is using a non-standard storage engine as default.

=item sync_binlog

severity: warn 

Binary logging is enabled, but sync_binlog isn't configured so that
every transaction is flushed to the binary log for durability.

=item tmp_table_size

severity: note 

The effective minimum size of in-memory implicit temporary tables
used internally during query execution is min(tmp_table_size,
max_heap_table_size), so max_heap_table_size should be at least as large
as tmp_table_size.

=item old mysql version

severity: warn

These are the recommended minimum version for each major release: 3.23, 4.1.20, 5.0.37, 5.1.30.  

=item end-of-life mysql version

severity: note

Every release older than 5.1 is now officially end-of-life.

=back

=head1 OPTIONS

This tool accepts additional command-line arguments.  Refer to the
L<"SYNOPSIS"> and usage information for details.

=over

=item --ask-pass

Prompt for a password when connecting to MySQL.

=item --charset

short form: -A; type: string

Default character set.  If the value is utf8, sets Perl's binmode on
STDOUT to utf8, passes the mysql_enable_utf8 option to DBD::mysql, and
runs SET NAMES UTF8 after connecting to MySQL.  Any other value sets
binmode on STDOUT without the utf8 layer, and runs SET NAMES after
connecting to MySQL.

=item --config

type: Array

Read this comma-separated list of config files; if specified, this must be the
first option on the command line.

=item --daemonize

Fork to the background and detach from the shell.  POSIX
operating systems only.

=item --database

short form: -D; type: string

Connect to this database.

=item --defaults-file

short form: -F; type: string

Only read mysql options from the given file.  You must give an absolute
pathname.

=item --help

Show help and exit.

=item --host

short form: -h; type: string

Connect to host.

=item --ignore-rules

type: hash

Ignore these rule IDs.

Specify a comma-separated list of rule IDs (e.g. LIT.001,RES.002,etc.)
to ignore.

=item --password

short form: -p; type: string

Password to use when connecting.
If password contains commas they must be escaped with a backslash: "exam\,ple"

=item --pid

type: string

Create the given PID file.  The tool won't start if the PID file already
exists and the PID it contains is different than the current PID.  However,
if the PID file exists and the PID it contains is no longer running, the
tool will overwrite the PID file with the current PID.  The PID file is
removed automatically when the tool exits.

=item --port

short form: -P; type: int

Port number to use for connection.

=item --set-vars

type: Array

Set the MySQL variables in this comma-separated list of C<variable=value> pairs.

By default, the tool sets:

=for comment ignore-pt-internal-value
MAGIC_set_vars

   wait_timeout=10000

Variables specified on the command line override these defaults.  For
example, specifying C<--set-vars wait_timeout=500> overrides the defaultvalue of C<10000>.

The tool prints a warning and continues if a variable cannot be set.

=item --socket

short form: -S; type: string

Socket file to use for connection.

=item --source-of-variables

type: string; default: mysql

Read C<SHOW VARIABLES> from this source.  Possible values are "mysql", "none"
or a file name.  If "mysql" is specified then you must also specify a DSN
on the command line.

=item --user

short form: -u; type: string

User for login if not current user.

=item --verbose

short form: -v; cumulative: yes; default: 1

Increase verbosity of output.  At the default level of verbosity, the
program prints only the first sentence of each rule's description.  At
higher levels, the program prints more of the description.

=item --version

Show version and exit.

=item --[no]version-check

default: yes

Check for the latest version of Percona Toolkit, MySQL, and other programs.

This is a standard "check for updates automatically" feature, with two
additional features. First, the tool checks its own version and also the
versions of the following software: operating system, Percona Monitoring and
Management (PMM), MySQL, Perl, MySQL driver for Perl (DBD::mysql), and
Percona Toolkit. Second, it checks for and warns about versions with known
problems. For example, MySQL 5.5.25 had a critical bug and was re-released
as 5.5.25a.

A secure connection to Percona’s Version Check database server is done to
perform these checks. Each request is logged by the server, including software
version numbers and unique ID of the checked system. The ID is generated by the
Percona Toolkit installation script or when the Version Check database call is
done for the first time.

Any updates or known problems are printed to STDOUT before the tool's normal
output. This feature should never interfere with the normal operation of the
tool.

For more information, visit L<https://www.percona.com/doc/percona-toolkit/LATEST/version-check.html>.

=back

=head1 DSN OPTIONS

These DSN options are used to create a DSN.  Each option is given like
C<option=value>.  The options are case-sensitive, so P and p are not the
same option.  There cannot be whitespace before or after the C<=> and
if the value contains whitespace it must be quoted.  DSN options are
comma-separated.  See the L<percona-toolkit> manpage for full details.

=over

=item * A

dsn: charset; copy: yes

Default character set.

=item * D

dsn: database; copy: yes

Default database.

=item * F

dsn: mysql_read_default_file; copy: yes

Only read default options from the given file

=item * h

dsn: host; copy: yes

Connect to host.

=item * p

dsn: password; copy: yes

Password to use when connecting.
If password contains commas they must be escaped with a backslash: "exam\,ple"

=item * P

dsn: port; copy: yes

Port number to use for connection.

=item * S

dsn: mysql_socket; copy: yes

Socket file to use for connection.

=item * u

dsn: user; copy: yes

User for login if not current user.

=back

=head1 ENVIRONMENT

The environment variable C<PTDEBUG> enables verbose debugging output to STDERR.
To enable debugging and capture all output to a file, run the tool like:

   PTDEBUG=1 pt-variable-advisor ... > FILE 2>&1

Be careful: debugging output is voluminous and can generate several megabytes
of output.

=head1 SYSTEM REQUIREMENTS

You need Perl, DBI, DBD::mysql, and some core packages that ought to be
installed in any reasonably new version of Perl.

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-variable-advisor>.

Please report bugs at L<https://jira.percona.com/projects/PT>.
Include the following information in your bug report:

=over

=item * Complete command-line used to run the tool

=item * Tool L<"--version">

=item * MySQL version of all servers involved

=item * Output from the tool including STDERR

=item * Input files (log/dump/config files, etc.)

=back

If possible, include debugging output by running the tool with C<PTDEBUG>;
see L<"ENVIRONMENT">.

=head1 DOWNLOADING

Visit L<http://www.percona.com/software/percona-toolkit/> to download the
latest release of Percona Toolkit.  Or, get the latest release from the
command line:

   wget percona.com/get/percona-toolkit.tar.gz

   wget percona.com/get/percona-toolkit.rpm

   wget percona.com/get/percona-toolkit.deb

You can also get individual tools from the latest release:

   wget percona.com/get/TOOL

Replace C<TOOL> with the name of any tool.

=head1 AUTHORS

Baron Schwartz and Daniel Nichter

=head1 ABOUT PERCONA TOOLKIT

This tool is part of Percona Toolkit, a collection of advanced command-line
tools for MySQL developed by Percona.  Percona Toolkit was forked from two
projects in June, 2011: Maatkit and Aspersa.  Those projects were created by
Baron Schwartz and primarily developed by him and Daniel Nichter.  Visit
L<http://www.percona.com/software/> to learn about other free, open-source
software from Percona.

=head1 COPYRIGHT, LICENSE, AND WARRANTY

This program is copyright 2010-2018 Percona LLC and/or its affiliates.

THIS PROGRAM IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, version 2; OR the Perl Artistic License.  On UNIX and similar
systems, you can issue `man perlgpl' or `man perlartistic' to read these
licenses.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 59 Temple
Place, Suite 330, Boston, MA  02111-1307  USA.

=head1 VERSION

pt-variable-advisor 3.3.0

=cut
