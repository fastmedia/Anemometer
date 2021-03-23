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
      Transformers
      ReadKeyMini
      Diskstats
      DiskstatsGroupByAll
      DiskstatsGroupByDisk
      DiskstatsGroupBySample
      DiskstatsMenu
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
# Transformers package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Transformers.pm
#   t/lib/Transformers.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Transformers;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Time::Local qw(timegm timelocal);
use Digest::MD5 qw(md5_hex);
use B qw();

BEGIN {
   require Exporter;
   our @ISA         = qw(Exporter);
   our %EXPORT_TAGS = ();
   our @EXPORT      = ();
   our @EXPORT_OK   = qw(
      micro_t
      percentage_of
      secs_to_time
      time_to_secs
      shorten
      ts
      parse_timestamp
      unix_timestamp
      any_unix_timestamp
      make_checksum
      crc32
      encode_json
   );
}

our $mysql_ts  = qr/(\d\d)(\d\d)(\d\d) +(\d+):(\d+):(\d+)(\.\d+)?/;
our $proper_ts = qr/(\d\d\d\d)-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(\.\d+)?/;
our $n_ts      = qr/(\d{1,5})([shmd]?)/; # Limit \d{1,5} because \d{6} looks

sub micro_t {
   my ( $t, %args ) = @_;
   my $p_ms = defined $args{p_ms} ? $args{p_ms} : 0;  # precision for ms vals
   my $p_s  = defined $args{p_s}  ? $args{p_s}  : 0;  # precision for s vals
   my $f;

   $t = 0 if $t < 0;

   $t = sprintf('%.17f', $t) if $t =~ /e/;

   $t =~ s/\.(\d{1,6})\d*/\.$1/;

   if ($t > 0 && $t <= 0.000999) {
      $f = ($t * 1000000) . 'us';
   }
   elsif ($t >= 0.001000 && $t <= 0.999999) {
      $f = sprintf("%.${p_ms}f", $t * 1000);
      $f = ($f * 1) . 'ms'; # * 1 to remove insignificant zeros
   }
   elsif ($t >= 1) {
      $f = sprintf("%.${p_s}f", $t);
      $f = ($f * 1) . 's'; # * 1 to remove insignificant zeros
   }
   else {
      $f = 0;  # $t should = 0 at this point
   }

   return $f;
}

sub percentage_of {
   my ( $is, $of, %args ) = @_;
   my $p   = $args{p} || 0; # float precision
   my $fmt = $p ? "%.${p}f" : "%d";
   return sprintf $fmt, ($is * 100) / ($of ||= 1);
}

sub secs_to_time {
   my ( $secs, $fmt ) = @_;
   $secs ||= 0;
   return '00:00' unless $secs;

   $fmt ||= $secs >= 86_400 ? 'd'
          : $secs >= 3_600  ? 'h'
          :                   'm';

   return
      $fmt eq 'd' ? sprintf(
         "%d+%02d:%02d:%02d",
         int($secs / 86_400),
         int(($secs % 86_400) / 3_600),
         int(($secs % 3_600) / 60),
         $secs % 60)
      : $fmt eq 'h' ? sprintf(
         "%02d:%02d:%02d",
         int(($secs % 86_400) / 3_600),
         int(($secs % 3_600) / 60),
         $secs % 60)
      : sprintf(
         "%02d:%02d",
         int(($secs % 3_600) / 60),
         $secs % 60);
}

sub time_to_secs {
   my ( $val, $default_suffix ) = @_;
   die "I need a val argument" unless defined $val;
   my $t = 0;
   my ( $prefix, $num, $suffix ) = $val =~ m/([+-]?)(\d+)([a-z])?$/;
   $suffix = $suffix || $default_suffix || 's';
   if ( $suffix =~ m/[smhd]/ ) {
      $t = $suffix eq 's' ? $num * 1        # Seconds
         : $suffix eq 'm' ? $num * 60       # Minutes
         : $suffix eq 'h' ? $num * 3600     # Hours
         :                  $num * 86400;   # Days

      $t *= -1 if $prefix && $prefix eq '-';
   }
   else {
      die "Invalid suffix for $val: $suffix";
   }
   return $t;
}

sub shorten {
   my ( $num, %args ) = @_;
   my $p = defined $args{p} ? $args{p} : 2;     # float precision
   my $d = defined $args{d} ? $args{d} : 1_024; # divisor
   my $n = 0;
   my @units = ('', qw(k M G T P E Z Y));
   while ( $num >= $d && $n < @units - 1 ) {
      $num /= $d;
      ++$n;
   }
   return sprintf(
      $num =~ m/\./ || $n
         ? '%1$.'.$p.'f%2$s'
         : '%1$d',
      $num, $units[$n]);
}

sub ts {
   my ( $time, $gmt ) = @_;
   my ( $sec, $min, $hour, $mday, $mon, $year )
      = $gmt ? gmtime($time) : localtime($time);
   $mon  += 1;
   $year += 1900;
   my $val = sprintf("%d-%02d-%02dT%02d:%02d:%02d",
      $year, $mon, $mday, $hour, $min, $sec);
   if ( my ($us) = $time =~ m/(\.\d+)$/ ) {
      $us = sprintf("%.6f", $us);
      $us =~ s/^0\././;
      $val .= $us;
   }
   return $val;
}

sub parse_timestamp {
   my ( $val ) = @_;
   if ( my($y, $m, $d, $h, $i, $s, $f)
         = $val =~ m/^$mysql_ts$/ )
   {
      return sprintf "%d-%02d-%02d %02d:%02d:"
                     . (defined $f ? '%09.6f' : '%02d'),
                     $y + 2000, $m, $d, $h, $i, (defined $f ? $s + $f : $s);
   }
   elsif ( $val =~ m/^$proper_ts$/ ) {
      return $val;
   }
   return $val;
}

sub unix_timestamp {
   my ( $val, $gmt ) = @_;
   if ( my($y, $m, $d, $h, $i, $s, $us) = $val =~ m/^$proper_ts$/ ) {
      $val = $gmt
         ? timegm($s, $i, $h, $d, $m - 1, $y)
         : timelocal($s, $i, $h, $d, $m - 1, $y);
      if ( defined $us ) {
         $us = sprintf('%.6f', $us);
         $us =~ s/^0\././;
         $val .= $us;
      }
   }
   return $val;
}

sub any_unix_timestamp {
   my ( $val, $callback ) = @_;

   if ( my ($n, $suffix) = $val =~ m/^$n_ts$/ ) {
      $n = $suffix eq 's' ? $n            # Seconds
         : $suffix eq 'm' ? $n * 60       # Minutes
         : $suffix eq 'h' ? $n * 3600     # Hours
         : $suffix eq 'd' ? $n * 86400    # Days
         :                  $n;           # default: Seconds
      PTDEBUG && _d('ts is now - N[shmd]:', $n);
      return time - $n;
   }
   elsif ( $val =~ m/^\d{9,}/ ) {
      PTDEBUG && _d('ts is already a unix timestamp');
      return $val;
   }
   elsif ( my ($ymd, $hms) = $val =~ m/^(\d{6})(?:\s+(\d+:\d+:\d+))?/ ) {
      PTDEBUG && _d('ts is MySQL slow log timestamp');
      $val .= ' 00:00:00' unless $hms;
      return unix_timestamp(parse_timestamp($val));
   }
   elsif ( ($ymd, $hms) = $val =~ m/^(\d{4}-\d\d-\d\d)(?:[T ](\d+:\d+:\d+))?/) {
      PTDEBUG && _d('ts is properly formatted timestamp');
      $val .= ' 00:00:00' unless $hms;
      return unix_timestamp($val);
   }
   else {
      PTDEBUG && _d('ts is MySQL expression');
      return $callback->($val) if $callback && ref $callback eq 'CODE';
   }

   PTDEBUG && _d('Unknown ts type:', $val);
   return;
}

sub make_checksum {
   my ( $val ) = @_;
   my $checksum = uc substr(md5_hex($val), -16);
   PTDEBUG && _d($checksum, 'checksum for', $val);
   return $checksum;
}

sub crc32 {
   my ( $string ) = @_;
   return unless $string;
   my $poly = 0xEDB88320;
   my $crc  = 0xFFFFFFFF;
   foreach my $char ( split(//, $string) ) {
      my $comp = ($crc ^ ord($char)) & 0xFF;
      for ( 1 .. 8 ) {
         $comp = $comp & 1 ? $poly ^ ($comp >> 1) : $comp >> 1;
      }
      $crc = (($crc >> 8) & 0x00FFFFFF) ^ $comp;
   }
   return $crc ^ 0xFFFFFFFF;
}

my $got_json = eval { require JSON };
sub encode_json {
   return JSON::encode_json(@_) if $got_json;
   my ( $data ) = @_;
   return (object_to_json($data) || '');
}


sub object_to_json {
   my ($obj) = @_;
   my $type  = ref($obj);

   if($type eq 'HASH'){
      return hash_to_json($obj);
   }
   elsif($type eq 'ARRAY'){
      return array_to_json($obj);
   }
   else {
      return value_to_json($obj);
   }
}

sub hash_to_json {
   my ($obj) = @_;
   my @res;
   for my $k ( sort { $a cmp $b } keys %$obj ) {
      push @res, string_to_json( $k )
         .  ":"
         . ( object_to_json( $obj->{$k} ) || value_to_json( $obj->{$k} ) );
   }
   return '{' . ( @res ? join( ",", @res ) : '' )  . '}';
}

sub array_to_json {
   my ($obj) = @_;
   my @res;

   for my $v (@$obj) {
      push @res, object_to_json($v) || value_to_json($v);
   }

   return '[' . ( @res ? join( ",", @res ) : '' ) . ']';
}

sub value_to_json {
   my ($value) = @_;

   return 'null' if(!defined $value);

   my $b_obj = B::svref_2object(\$value);  # for round trip problem
   my $flags = $b_obj->FLAGS;
   return $value # as is 
      if $flags & ( B::SVp_IOK | B::SVp_NOK ) and !( $flags & B::SVp_POK ); # SvTYPE is IV or NV?

   my $type = ref($value);

   if( !$type ) {
      return string_to_json($value);
   }
   else {
      return 'null';
   }

}

my %esc = (
   "\n" => '\n',
   "\r" => '\r',
   "\t" => '\t',
   "\f" => '\f',
   "\b" => '\b',
   "\"" => '\"',
   "\\" => '\\\\',
   "\'" => '\\\'',
);

sub string_to_json {
   my ($arg) = @_;

   $arg =~ s/([\x22\x5c\n\r\t\f\b])/$esc{$1}/g;
   $arg =~ s/\//\\\//g;
   $arg =~ s/([\x00-\x08\x0b\x0e-\x1f])/'\\u00' . unpack('H2', $1)/eg;

   utf8::upgrade($arg);
   utf8::encode($arg);

   return '"' . $arg . '"';
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
# End Transformers package
# ###########################################################################

# ###########################################################################
# ReadKeyMini package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/ReadKeyMini.pm
#   t/lib/ReadKeyMini.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{

BEGIN {

package ReadKeyMini;
BEGIN { $INC{"ReadKeyMini.pm"} ||= 1 }

use warnings;
use strict;
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use POSIX qw( :termios_h );
use Fcntl qw( F_SETFL F_GETFL );

use base  qw( Exporter );

BEGIN {
   our @EXPORT_OK = qw( GetTerminalSize ReadMode );
   *ReadMode        = *Term::ReadKey::ReadMode        = \&_ReadMode;
   *GetTerminalSize = *Term::ReadKey::GetTerminalSize = \&_GetTerminalSize;
}

my %modes = (
   original    => 0,
   restore     => 0,
   normal      => 1,
   noecho      => 2,
   cbreak      => 3,
   raw         => 4,
   'ultra-raw' => 5,
);

{
   my $fd_stdin = fileno(STDIN);
   my $flags;
   unless ( $PerconaTest::DONT_RESTORE_STDIN ) {
      $flags = fcntl(STDIN, F_GETFL, 0)
         or warn "Error getting STDIN flags with fcntl: $OS_ERROR";
   }
   my $term     = POSIX::Termios->new();
   $term->getattr($fd_stdin);
   my $oterm    = $term->getlflag();
   my $echo     = ECHO | ECHOK | ICANON;
   my $noecho   = $oterm & ~$echo;

   sub _ReadMode {
      my $mode = $modes{ $_[0] };
      if ( $mode == $modes{normal} ) {
         cooked();
      }
      elsif ( $mode == $modes{cbreak} || $mode == $modes{noecho} ) {
         cbreak( $mode == $modes{noecho} ? $noecho : $oterm );
      }
      else {
         die("ReadMore('$_[0]') not supported");
      }
   }

   sub cbreak {
      my ($lflag) = $_[0] || $noecho; 
      $term->setlflag($lflag);
      $term->setcc( VTIME, 1 );
      $term->setattr( $fd_stdin, TCSANOW );
   }

   sub cooked {
      $term->setlflag($oterm);
      $term->setcc( VTIME, 0 );
      $term->setattr( $fd_stdin, TCSANOW );
      if ( !$PerconaTest::DONT_RESTORE_STDIN ) {
         fcntl(STDIN, F_SETFL, int($flags))
            or warn "Error restoring STDIN flags with fcntl: $OS_ERROR";
      }
   }

   END { cooked() }
}

sub readkey {
   my $key = '';
   cbreak();
   sysread(STDIN, $key, 1);
   my $timeout = 0.1;
   if ( $key eq "\033" ) {
      my $x = '';
      STDIN->blocking(0);
      sysread(STDIN, $x, 2);
      STDIN->blocking(1);
      $key .= $x;
      redo if $key =~ /\[[0-2](?:[0-9];)?$/
   }
   cooked();
   return $key;
}


BEGIN {
   eval { no warnings; local $^W; require 'sys/ioctl.ph' };
   if ( !defined &TIOCGWINSZ ) {
      *TIOCGWINSZ = sub () {
              $^O eq 'linux'   ? 0x005413
            : $^O eq 'solaris' ? 0x005468
            :                    0x40087468;
      };
   }
}

sub _GetTerminalSize {
   if ( @_ ) {
      die "My::Term::ReadKey doesn't implement GetTerminalSize with arguments";
   }

   my $cols = $ENV{COLUMNS} || 80;
   my $rows = $ENV{LINES}   || 24;

   if ( open( TTY, "+<", "/dev/tty" ) ) { # Got a tty
      my $winsize = '';
      if ( ioctl( TTY, &TIOCGWINSZ, $winsize ) ) {
         ( $rows, $cols, my ( $xpixel, $ypixel ) ) = unpack( 'S4', $winsize );
         return ( $cols, $rows, $xpixel, $ypixel );
      }
   }

   if ( $rows = `tput lines 2>/dev/null` ) {
      chomp($rows);
      chomp($cols = `tput cols`);
   }
   elsif ( my $stty = `stty -a 2>/dev/null` ) {
      ($rows, $cols) = $stty =~ /([0-9]+) rows; ([0-9]+) columns;/;
   }
   else {
      ($cols, $rows) = @ENV{qw( COLUMNS LINES )};
      $cols ||= 80;
      $rows ||= 24;
   }

   return ( $cols, $rows );
}

}

1;
}
# ###########################################################################
# End ReadKeyMini package
# ###########################################################################

# ###########################################################################
# Diskstats package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Diskstats.pm
#   t/lib/Diskstats.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{

package Diskstats;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use IO::Handle;
use List::Util qw( max first );

use ReadKeyMini qw( GetTerminalSize );

my $max_lines;
BEGIN {
   (undef, $max_lines)       = GetTerminalSize();
   $max_lines              ||= 24;
   $Diskstats::printed_lines = $max_lines;
}

my $diskstat_colno_for;
BEGIN {
   $diskstat_colno_for = {
      MAJOR               => 0,
      MINOR               => 1,
      DEVICE              => 2,
      READS               => 3,
      READS_MERGED        => 4,
      READ_SECTORS        => 5,
      MS_SPENT_READING    => 6,
      WRITES              => 7,
      WRITES_MERGED       => 8,
      WRITTEN_SECTORS     => 9,
      MS_SPENT_WRITING    => 10,
      IOS_IN_PROGRESS     => 11,
      MS_SPENT_DOING_IO   => 12,
      MS_WEIGHTED         => 13,
      READ_KBS            => 14,
      WRITTEN_KBS         => 15,
      IOS_REQUESTED       => 16,
      IOS_IN_BYTES        => 17,
      SUM_IOS_IN_PROGRESS => 18,
   };
   require constant;
   constant->import($diskstat_colno_for);
}

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw(OptionParser);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($o) = @args{@required_args};

   my $columns = $o->get('columns-regex');
   my $devices = $o->get('devices-regex');

   my $headers = $o->get('headers');

   my $self = {
      filename           => '/proc/diskstats',
      block_size         => 512,
      show_inactive      => $o->get('show-inactive'),
      sample_time        => $o->get('sample-time') || 0,
      automatic_headers  => $headers->{'scroll'},
      space_samples      => $headers->{'group'},
      show_timestamps    => $o->get('show-timestamps'),
      columns_regex      => qr/$columns/,
      devices_regex      => $devices ? qr/$devices/ : undef,
      interactive        => 0,
      force_header       => 1,

      %args,

      delta_cols         => [  # Calc deltas for these cols, must be uppercase
         qw(
            READS
            READS_MERGED
            READ_SECTORS
            MS_SPENT_READING
            WRITES
            WRITES_MERGED
            WRITTEN_SECTORS
            MS_SPENT_WRITING
            READ_KBS
            WRITTEN_KBS
            MS_SPENT_DOING_IO
            MS_WEIGHTED
            READ_KBS
            WRITTEN_KBS
            IOS_REQUESTED
            IOS_IN_BYTES
            IOS_IN_PROGRESS
         )
      ],
      _stats_for         => {},
      _ordered_devs      => [],
      _active_devices    => {},
      _ts                => {},
      _first_stats_for   => {},
      _nochange_skips    => [],

      _length_ts_column  => 5,

      _save_curr_as_prev => 1,
   };

   if ( $self->{show_timestamps} ) {
      $self->{_length_ts_column} = 8;
   }

   $Diskstats::last_was_header = 0;

   return bless $self, $class;
}


sub first_ts_line {
   my ($self) = @_;
   return $self->{_ts}->{first}->{line};
}

sub set_first_ts_line {
   my ($self, $new_val) = @_;
   return $self->{_ts}->{first}->{line} = $new_val;
}

sub prev_ts_line {
   my ($self) = @_;
   return $self->{_ts}->{prev}->{line};
}

sub set_prev_ts_line {
   my ($self, $new_val) = @_;
   return $self->{_ts}->{prev}->{line} = $new_val;
}

sub curr_ts_line {
   my ($self) = @_;
   return $self->{_ts}->{curr}->{line};
}

sub set_curr_ts_line {
   my ($self, $new_val) = @_;
   return $self->{_ts}->{curr}->{line} = $new_val;
}

sub show_line_between_samples {
   my ($self) = @_;
   return $self->{space_samples};
}

sub set_show_line_between_samples {
   my ($self, $new_val) = @_;
   return $self->{space_samples} = $new_val;
}

sub show_timestamps {
   my ($self) = @_;
   return $self->{show_timestamps};
}

sub set_show_timestamps {
   my ($self, $new_val) = @_;
   return $self->{show_timestamps} = $new_val;
}

sub active_device {
   my ( $self, $dev ) = @_;
   return $self->{_active_devices}->{$dev};
}

sub set_active_device {
   my ($self, $dev, $val) = @_;
   return $self->{_active_devices}->{$dev} = $val;
}

sub clear_active_devices {
   my ( $self ) = @_;
   return $self->{_active_devices} = {};
}

sub automatic_headers {
   my ($self) = @_;
   return $self->{automatic_headers};
}

sub set_automatic_headers {
   my ($self, $new_val) = @_;
   return $self->{automatic_headers} = $new_val;
}

sub curr_ts {
   my ($self) = @_;
   return $self->{_ts}->{curr}->{ts} || 0;
}

sub set_curr_ts {
   my ($self, $val) = @_;
   $self->{_ts}->{curr}->{ts} = $val || 0;
}

sub prev_ts {
   my ($self) = @_;
   return $self->{_ts}->{prev}->{ts} || 0;
}

sub set_prev_ts {
   my ($self, $val) = @_;
   $self->{_ts}->{prev}->{ts} = $val || 0;
}

sub first_ts {
   my ($self) = @_;
   return $self->{_ts}->{first}->{ts} || 0;
}

sub set_first_ts {
   my ($self, $val) = @_;
   $self->{_ts}->{first}->{ts} = $val || 0;
}

sub show_inactive {
   my ($self) = @_;
   return $self->{show_inactive};
}

sub set_show_inactive {
   my ($self, $new_val) = @_;
   $self->{show_inactive} = $new_val;
}

sub sample_time {
   my ($self) = @_;
   return $self->{sample_time};
}

sub set_sample_time {
   my ($self, $new_val) = @_;
   if (defined($new_val)) {
      $self->{sample_time} = $new_val;
   }
}

sub interactive {
   my ($self) = @_;
   return $self->{interactive};
}

sub set_interactive {
   my ($self, $new_val) = @_;
   if (defined($new_val)) {
      $self->{interactive} = $new_val;
   }
}

sub columns_regex {
   my ( $self ) = @_;
   return $self->{columns_regex};
}

sub set_columns_regex {
   my ( $self, $new_re ) = @_;
   return $self->{columns_regex} = $new_re;
}

sub devices_regex {
   my ( $self ) = @_;
   return $self->{devices_regex};
}

sub set_devices_regex {
   my ( $self, $new_re ) = @_;
   return $self->{devices_regex} = $new_re;
}

sub filename {
   my ( $self ) = @_;
   return $self->{filename};
}

sub set_filename {
   my ( $self, $new_filename ) = @_;
   if ( $new_filename ) {
      return $self->{filename} = $new_filename;
   }
}

sub block_size {
   my ( $self ) = @_;
   return $self->{block_size};
}


sub ordered_devs {
   my ( $self, $replacement_list ) = @_;
   if ( $replacement_list ) {
      $self->{_ordered_devs} = $replacement_list;
   }
   return @{ $self->{_ordered_devs} };
}

sub add_ordered_dev {
   my ( $self, $new_dev ) = @_;
   if ( !$self->{_seen_devs}->{$new_dev}++ ) {
      push @{ $self->{_ordered_devs} }, $new_dev;
   }
   return;
}


sub force_header {
   my ($self) = @_;
   return $self->{force_header};
}

sub set_force_header {
   my ($self, $new_val) = @_;
   return $self->{force_header} = $new_val;
}

sub clear_state {
   my ($self, %args) = @_;
   $self->set_force_header(1);
   $self->clear_curr_stats();
   if ( $args{force} || !$self->interactive() ) {
      $self->clear_first_stats();
      $self->clear_prev_stats();
   }
   $self->clear_ts();
   $self->clear_ordered_devs();
}

sub clear_ts {
   my ($self) = @_;
   undef($_->{ts}) for @{ $self->{_ts} }{ qw( curr prev first ) };
}

sub clear_ordered_devs {
   my ($self) = @_;
   $self->{_seen_devs} = {};
   $self->ordered_devs( [] );
}

sub _clear_stats_common {
   my ( $self, $key, @args ) = @_;
   if (@args) {
      for my $dev (@args) {
         $self->{$key}->{$dev} = {};
      }
   }
   else {
      $self->{$key} = {};
   }
}

sub clear_curr_stats {
   my ( $self, @args ) = @_;

   if ( $self->has_stats() ) {
      $self->_save_curr_as_prev();
   }

   $self->_clear_stats_common( "_stats_for", @args );
}

sub clear_prev_stats {
   my ( $self, @args ) = @_;
   $self->_clear_stats_common( "_prev_stats_for", @args );
}

sub clear_first_stats {
   my ( $self, @args ) = @_;
   $self->_clear_stats_common( "_first_stats_for", @args );
}

sub stats_for {
   my ( $self, $dev ) = @_;
   $self->{_stats_for} ||= {};
   if ($dev) {
      return $self->{_stats_for}->{$dev};
   }
   return $self->{_stats_for};
}

sub prev_stats_for {
   my ( $self, $dev ) = @_;
   $self->{_prev_stats_for} ||= {};
   if ($dev) {
      return $self->{_prev_stats_for}->{$dev};
   }
   return $self->{_prev_stats_for};
}

sub first_stats_for {
   my ( $self, $dev ) = @_;
   $self->{_first_stats_for} ||= {};
   if ($dev) {
      return $self->{_first_stats_for}->{$dev};
   }
   return $self->{_first_stats_for};
}

sub has_stats {
   my ($self) = @_;
   my $stats  = $self->stats_for;

   for my $key ( keys %$stats ) {
      return 1 if $stats->{$key} && @{ $stats->{$key} }
   }

   return;
}

sub _save_curr_as_prev {
   my ( $self, $curr ) = @_;

   if ( $self->{_save_curr_as_prev} ) {
      $self->{_prev_stats_for} = $curr;
      for my $dev (keys %$curr) {
         $self->{_prev_stats_for}->{$dev}->[SUM_IOS_IN_PROGRESS] +=
            $curr->{$dev}->[IOS_IN_PROGRESS];
      }
      $self->set_prev_ts($self->curr_ts());
   }

   return;
}

sub _save_curr_as_first {
   my ($self, $curr) = @_;

   if ( !%{$self->{_first_stats_for}} ) {
      $self->{_first_stats_for} = {
         map { $_ => [@{$curr->{$_}}] } keys %$curr
      };
      $self->set_first_ts($self->curr_ts());
   }
}

sub trim {
   my ($c) = @_;
   $c =~ s/^\s+//;
   $c =~ s/\s+$//;
   return $c;
}

sub col_ok {
   my ( $self, $column ) = @_;
   my $regex = $self->columns_regex();
   return ($column =~ $regex) || (trim($column) =~ $regex);
}

our @columns_in_order = (
   [ "   rd_s" => "%7.1f",   "reads_sec", ],
   [ "rd_avkb" => "%7.1f",   "avg_read_sz", ],
   [ "rd_mb_s" => "%7.1f",   "mbytes_read_sec", ],
   [ "rd_mrg"  => "%5.0f%%", "read_merge_pct", ],
   [ "rd_cnc"  => "%6.1f",   "read_conc", ],
   [ "  rd_rt" => "%7.1f",   "read_rtime", ],
   [ "   wr_s" => "%7.1f",   "writes_sec", ],
   [ "wr_avkb" => "%7.1f",   "avg_write_sz", ],
   [ "wr_mb_s" => "%7.1f",   "mbytes_written_sec", ],
   [ "wr_mrg"  => "%5.0f%%", "write_merge_pct", ],
   [ "wr_cnc"  => "%6.1f",   "write_conc", ],
   [ "  wr_rt" => "%7.1f",   "write_rtime", ],
   [ "busy"    => "%3.0f%%", "busy", ],
   [ "in_prg"  => "%6d",     "in_progress", ],
   [ "   io_s" => "%7.1f",   "s_spent_doing_io", ],
   [ " qtime"  => "%6.1f",   "qtime", ],
   [ "stime"   => "%5.1f",   "stime", ],
);

{

   my %format_for = ( map { ( $_->[0] => $_->[1] ) } @columns_in_order, );

   sub _format_for {
      my ( $self, $col ) = @_;
      return $format_for{$col};
   }

}

{

   my %column_to_key = ( map { ( $_->[0] => $_->[2] ) } @columns_in_order, );

   sub _column_to_key {
      my ( $self, $col ) = @_;
      return $column_to_key{$col};
   }

}


sub design_print_formats {
   my ( $self,       %args )    = @_;
   my ( $dev_length, $columns ) = @args{qw( max_device_length columns )};
   $dev_length ||= max 6, map length, $self->ordered_devs();
   my ( $header, $format );

   $header = $format = qq{%+*s %-${dev_length}s };

   if ( !$columns ) {
      @$columns = grep { $self->col_ok($_) } map { $_->[0] } @columns_in_order;
   }
   elsif ( !ref($columns) || ref($columns) ne ref([]) ) {
      die "The columns argument to design_print_formats should be an arrayref";
   }

   $header .= join " ", @$columns;
   $format .= join " ", map $self->_format_for($_), @$columns;

   return ( $header, $format, $columns );
}

sub parse_diskstats_line {
   my ( $self, $line, $block_size ) = @_;

   # linux kernel source => Documentation/iostats.txt
   # 2.6+   => 14 fields
   # 4.18+  => 18 fields
   my @dev_stats = split ' ', $line;
   return unless @dev_stats == 14 or @dev_stats == 18;

   my $read_bytes    = $dev_stats[READ_SECTORS]    * $block_size;
   my $written_bytes = $dev_stats[WRITTEN_SECTORS] * $block_size;

   $dev_stats[READ_KBS]      = $read_bytes    / 1024;
   $dev_stats[WRITTEN_KBS]   = $written_bytes / 1024;
   $dev_stats[IOS_IN_BYTES]  = $read_bytes + $written_bytes;
   $dev_stats[IOS_REQUESTED]
      = $dev_stats[READS] + $dev_stats[WRITES]
      + $dev_stats[READS_MERGED] +$dev_stats[WRITES_MERGED];

   return $dev_stats[DEVICE], \@dev_stats;
}


sub parse_from {
   my ( $self, %args ) = @_;

   my $lines_read;
   if ($args{filehandle}) {
      $lines_read = $self->_parse_from_filehandle(
                        @args{qw( filehandle sample_callback )}
                     );
   }
   elsif ( $args{data} ) {
      open( my $fh, "<", ref($args{data}) ? $args{data} : \$args{data} )
         or die "Couldn't parse data: $OS_ERROR";
      $lines_read = $self->_parse_from_filehandle(
                        $fh, $args{sample_callback}
                     );
      close $fh or warn "Cannot close: $OS_ERROR";
   }
   else {
      my $filename = $args{filename} || $self->filename();
   
      open my $fh, "<", $filename
         or die "Cannot parse $filename: $OS_ERROR";
      $lines_read = $self->_parse_from_filehandle(
                        $fh, $args{sample_callback}
                     );
      close $fh or warn "Cannot close: $OS_ERROR";
   }

   return $lines_read;
}


sub _parse_from_filehandle {
   my ( $self, $filehandle, $sample_callback ) = @_;
   return $self->_parse_and_load_diskstats( $filehandle, $sample_callback );
}


sub _parse_and_load_diskstats {
   my ( $self, $fh, $sample_callback ) = @_;
   my $block_size = $self->block_size();
   my $current_ts = 0;
   my $new_cur    = {};
   my $last_ts_line;

   while ( my $line = <$fh> ) {
      if ( my ( $dev, $dev_stats )
               = $self->parse_diskstats_line($line, $block_size) )
      {
         $new_cur->{$dev} = $dev_stats;
         $self->add_ordered_dev($dev);
      }
      elsif ( my ($new_ts) = $line =~ /^TS\s+([0-9]+(?:\.[0-9]+)?)/ ) {
         PTDEBUG && _d("Timestamp:", $line);
         if ( $current_ts && %$new_cur ) {
            $self->_handle_ts_line($current_ts, $new_cur, $line, $sample_callback);
            $new_cur = {};
         }
         $current_ts = $new_ts;
         $last_ts_line = $line;
      }
      else {
         PTDEBUG && _d("Ignoring unknown diskstats line:", $line);
      }
   }

   if ( $current_ts && %{$new_cur} ) {
      $self->_handle_ts_line($current_ts, $new_cur, $last_ts_line, $sample_callback);
      $new_cur = {};
   }

   return $INPUT_LINE_NUMBER;
}

sub _handle_ts_line {
   my ($self, $current_ts, $new_cur, $line, $sample_callback) = @_;

   $self->set_first_ts_line( $line ) unless $self->first_ts_line();
   $self->set_prev_ts_line( $self->curr_ts_line() );
   $self->set_curr_ts_line( $line );

   $self->_save_curr_as_prev( $self->stats_for() );
   $self->{_stats_for} = $new_cur;
   $self->set_curr_ts($current_ts);
   $self->_save_curr_as_first( $new_cur );

   if ($sample_callback) {
      $self->$sample_callback($current_ts);
   }
   return;
}

sub _calc_read_stats {
   my ( $self, %args ) = @_;

   my @required_args = qw( delta_for elapsed devs_in_group );
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($delta_for, $elapsed, $devs_in_group) = @args{ @required_args };

   my %read_stats = (
      reads_sec       => $delta_for->{reads} / $elapsed,
      read_requests   => $delta_for->{reads_merged} + $delta_for->{reads},
      mbytes_read_sec => $delta_for->{read_kbs} / $elapsed / 1024,
      read_conc       => $delta_for->{ms_spent_reading} /
                           $elapsed / 1000 / $devs_in_group,
   );

   if ( $delta_for->{reads} > 0 ) {
      $read_stats{read_rtime} =
        $delta_for->{ms_spent_reading} / $read_stats{read_requests};
      $read_stats{avg_read_sz} =
        $delta_for->{read_kbs} / $delta_for->{reads};
   }
   else {
      $read_stats{read_rtime}  = 0;
      $read_stats{avg_read_sz} = 0;
   }

   $read_stats{read_merge_pct} =
     $read_stats{read_requests} > 0
     ? 100 * $delta_for->{reads_merged} / $read_stats{read_requests}
     : 0;

   return %read_stats;
}

sub _calc_write_stats {
   my ( $self, %args ) = @_;

   my @required_args = qw( delta_for elapsed devs_in_group );
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($delta_for, $elapsed, $devs_in_group) = @args{ @required_args };

   my %write_stats = (
      writes_sec         => $delta_for->{writes} / $elapsed,
      write_requests     => $delta_for->{writes_merged} + $delta_for->{writes},
      mbytes_written_sec => $delta_for->{written_kbs} / $elapsed / 1024,
      write_conc         => $delta_for->{ms_spent_writing} /
        $elapsed / 1000 /
        $devs_in_group,
   );

   if ( $delta_for->{writes} > 0 ) {
      $write_stats{write_rtime} =
        $delta_for->{ms_spent_writing} / $write_stats{write_requests};
      $write_stats{avg_write_sz} =
        $delta_for->{written_kbs} / $delta_for->{writes};
   }
   else {
      $write_stats{write_rtime}  = 0;
      $write_stats{avg_write_sz} = 0;
   }

   $write_stats{write_merge_pct} =
     $write_stats{write_requests} > 0
     ? 100 * $delta_for->{writes_merged} / $write_stats{write_requests}
     : 0;

   return %write_stats;
}



sub _calc_misc_stats {
   my ( $self, %args ) = @_;

   my @required_args = qw( delta_for elapsed devs_in_group stats );
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($delta_for, $elapsed, $devs_in_group, $stats) = @args{ @required_args };
   my %extra_stats;

   $extra_stats{busy}
      = 100
      * $delta_for->{ms_spent_doing_io}
      / ( 1000 * $elapsed * $devs_in_group ); # Highlighting failure: /

   my $number_of_ios        = $delta_for->{ios_requested}; # sum(delta[field1, 2, 5, 6])
   my $total_ms_spent_on_io = $delta_for->{ms_spent_reading}
                            + $delta_for->{ms_spent_writing};

   if ( $number_of_ios ) {
      my $average_ios = $number_of_ios + $delta_for->{ios_in_progress};
      if ( $average_ios ) {
         $extra_stats{qtime} =  $delta_for->{ms_weighted} / $average_ios
                           - $delta_for->{ms_spent_doing_io} / $number_of_ios;
      }
      else {
         PTDEBUG && _d("IOS_IN_PROGRESS is [", $delta_for->{ios_in_progress},
                       "], and the number of ios is [", $number_of_ios,
                       "], going to use 0 as qtime.");
         $extra_stats{qtime} = 0;
      }
      $extra_stats{stime}
         = $delta_for->{ms_spent_doing_io} / $number_of_ios;
   }
   else {
      $extra_stats{qtime} = 0;
      $extra_stats{stime} = 0;
   }

   $extra_stats{s_spent_doing_io}
      = $stats->{reads_sec} + $stats->{writes_sec};

   $extra_stats{line_ts} = $self->compute_line_ts(
      first_ts   => $self->first_ts(),
      curr_ts    => $self->curr_ts(),
   );

   return %extra_stats;
}

sub _calc_delta_for {
   my ( $self, $curr, $against ) = @_;
   my %deltas;
   foreach my $col ( @{$self->{delta_cols}} ) {
      my $colno = $diskstat_colno_for->{$col};
      $deltas{lc $col} = ($curr->[$colno] || 0) - ($against->[$colno] || 0);
   }
   return \%deltas;
}

sub _print_device_if {

   my ($self, $dev ) = @_;
   my $dev_re = $self->devices_regex();

   if ( $dev_re ) {
      $self->_mark_if_active($dev);
      return $dev if $dev =~ $dev_re;
   }
   else {   
      if ( $self->active_device($dev) ) {
         return $dev;
      }
      elsif ( $self->show_inactive() ) {
         $self->_mark_if_active($dev);
         return $dev;
      }
      else {
         return $dev if $self->_mark_if_active($dev);
      }
   }
   push @{$self->{_nochange_skips}}, $dev;
   return;
}

sub _mark_if_active {
   my ($self, $dev) = @_;

   return $dev if $self->active_device($dev);

   my $curr         = $self->stats_for($dev);
   my $first        = $self->first_stats_for($dev);

   return unless $curr && $first;

   if ( first { $curr->[$_] != $first->[$_] } READS..IOS_IN_BYTES ) {
      $self->set_active_device($dev, 1);
      return $dev;
   }
   return;
}

sub _calc_stats_for_deltas {
   my ( $self, $elapsed ) = @_;
   my @end_stats;
   my @devices = $self->ordered_devs();

   my $devs_in_group = $self->compute_devs_in_group();

   foreach my $dev ( grep { $self->_print_device_if($_) } @devices ) {
      my $curr    = $self->stats_for($dev);
      my $against = $self->delta_against($dev);

      next unless $curr && $against;

      my $delta_for       = $self->_calc_delta_for( $curr, $against );
      my $in_progress     = $curr->[IOS_IN_PROGRESS];
      my $tot_in_progress = $against->[SUM_IOS_IN_PROGRESS] || 0;

      my %stats = (
         $self->_calc_read_stats(
            delta_for     => $delta_for,
            elapsed       => $elapsed,
            devs_in_group => $devs_in_group,
         ),
         $self->_calc_write_stats(
            delta_for     => $delta_for,
            elapsed       => $elapsed,
            devs_in_group => $devs_in_group,
         ),
         in_progress =>
           $self->compute_in_progress( $in_progress, $tot_in_progress ),
      );

      my %extras = $self->_calc_misc_stats(
         delta_for     => $delta_for,
         elapsed       => $elapsed,
         devs_in_group => $devs_in_group,
         stats         => \%stats,
      );

      @stats{ keys %extras } = values %extras;

      $stats{dev} = $dev;

      push @end_stats, \%stats;
   }
   if ( @{$self->{_nochange_skips}} ) {
      my $devs = join ", ", @{$self->{_nochange_skips}};
      PTDEBUG && _d("Skipping [$devs], haven't changed from the first sample");
      $self->{_nochange_skips} = [];
   }
   return @end_stats;
}

sub _calc_deltas {
   my ( $self ) = @_;

   my $elapsed = $self->curr_ts() - $self->delta_against_ts();
   die "Time between samples should be > 0, is [$elapsed]" if $elapsed <= 0;

   return $self->_calc_stats_for_deltas($elapsed);
}

sub force_print_header {
   my ($self, @args) = @_;
   my $orig = $self->force_header();
   $self->set_force_header(1);
   $self->print_header(@args);
   $self->set_force_header($orig);
   return;
}

sub print_header {
   my ($self, $header, @args) = @_;
   if ( $self->force_header() ) {
      printf $header . "\n", $self->{_length_ts_column}, @args;
      $Diskstats::printed_lines--;
      $Diskstats::printed_lines ||= $max_lines;
      $Diskstats::last_was_header = 1;
   }
   return;
}

sub print_rows {
   my ($self, $format, $cols, $stat) = @_;

   printf $format . "\n", $self->{_length_ts_column}, @{ $stat }{ qw( line_ts dev ), @$cols };
   $Diskstats::printed_lines--;
   $Diskstats::last_was_header = 0;
}

sub print_deltas {
   my ( $self, %args ) = @_;

   my ( $header, $format, $cols ) = $self->design_print_formats(
      max_device_length => $args{max_device_length},
      columns           => $args{columns},
   );

   return unless $self->delta_against_ts();

   @$cols = map { $self->_column_to_key($_) } @$cols;

   my $header_method = $args{header_callback} || "print_header";
   my $rows_method   = $args{rows_callback}   || "print_rows";

   my @stats = $self->_calc_deltas();

   $Diskstats::printed_lines = $max_lines
      unless defined $Diskstats::printed_lines;

   if ( $self->{space_samples} && @stats && @stats > 1
         && !$Diskstats::last_was_header ) {
      print "\n";
      $Diskstats::printed_lines--;
   }

   if ( $self->automatic_headers() && $Diskstats::printed_lines <= @stats ) {
      $self->force_print_header( $header, "#ts", "device" );
   }
   else {
      $self->$header_method( $header, "#ts", "device" );
   }

   foreach my $stat ( @stats ) {
      $self->$rows_method( $format, $cols, $stat );
   }

   $Diskstats::printed_lines = $max_lines
      if $Diskstats::printed_lines <= 0;
}

sub compute_line_ts {
   my ( $self, %args ) = @_;
   my $line_ts;
   if ( $self->show_timestamps() ) {
      $line_ts = $self->ts_line_for_timestamp();
      if ( $line_ts && $line_ts =~ /([0-9]{2}:[0-9]{2}:[0-9]{2})/ ) {
         $line_ts = $1;
      }
      else {
         $line_ts = scalar localtime($args{curr_ts});
         $line_ts =~ s/.*(\d\d:\d\d:\d\d).*/$1/;
      }
   }
   else {
      $line_ts = sprintf( "%5.1f", $args{first_ts} > 0
                              ? $args{curr_ts} - $args{first_ts}
                              : 0 );
   }
   return $line_ts;
}

sub compute_in_progress {
   my ( $self, $in_progress, $tot_in_progress ) = @_;
   return $in_progress;
}

sub compute_devs_in_group {
   return 1;
}

sub ts_line_for_timestamp {
   die 'You must override ts_line_for_timestamp() in a subclass';
}

sub delta_against {
   die 'You must override delta_against() in a subclass';
}

sub delta_against_ts {
   die 'You must override delta_against_ts() in a subclass';
}

sub group_by {
   die 'You must override group_by() in a subclass';
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
# End Diskstats package
# ###########################################################################

# ###########################################################################
# DiskstatsGroupByAll package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/DiskstatsGroupByAll.pm
#   t/lib/DiskstatsGroupByAll.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{

package DiskstatsGroupByAll;

use warnings;
use strict;
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use base qw( Diskstats );

sub group_by {
   my ($self, %args) = @_;

   $self->clear_state() unless $self->interactive();

   $self->parse_from(
      filehandle      => $args{filehandle},
      filename        => $args{filename},
      data            => $args{data},
      sample_callback => sub {
            $self->print_deltas(
               header_callback => $args{header_callback} || sub {
                  my ($self, @args) = @_;
                  $self->print_header(@args);
                  $self->set_force_header(undef);
               },
               rows_callback   => $args{rows_callback},
            );
         },
   );

   return;
}


sub delta_against {
   my ($self, $dev) = @_;
   return $self->prev_stats_for($dev);
}

sub ts_line_for_timestamp {
   my ($self) = @_;
   return $self->prev_ts_line();
}

sub delta_against_ts {
   my ($self) = @_;
   return $self->prev_ts();
}

sub compute_line_ts {
   my ($self, %args) = @_;
   if ( $self->interactive() ) {
      $args{first_ts} = $self->prev_ts();
   }
   return $self->SUPER::compute_line_ts(%args);
}

1;
}
# ###########################################################################
# End DiskstatsGroupByAll package
# ###########################################################################

# ###########################################################################
# DiskstatsGroupByDisk package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/DiskstatsGroupByDisk.pm
#   t/lib/DiskstatsGroupByDisk.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{

package DiskstatsGroupByDisk;

use warnings;
use strict;
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use base qw( Diskstats );

use POSIX qw( ceil );

sub new {
   my ($class, %args) = @_;
   my $self = $class->SUPER::new(%args);
   $self->{_iterations}   = 0;
   return $self;
}

sub group_by {
   my ($self, %args) = @_;
   my @optional_args = qw( header_callback rows_callback );
   my ($header_callback, $rows_callback) = $args{ @optional_args };

   $self->clear_state() unless $self->interactive();

   my $original_offset = ($args{filehandle} || ref($args{data}))
                       ? tell($args{filehandle} || $args{data})
                       : undef;

   my $lines_read = $self->parse_from(
      sample_callback => sub {
         my ($self, $ts) = @_;

         if ( $self->has_stats() ) {
            $self->{_iterations}++;
            if ($self->interactive() && $self->{_iterations} >= 2) {
               my $elapsed = ( $self->curr_ts()  || 0 )
                           - ( $self->first_ts() || 0 );
               if ( $ts > 0 && ceil($elapsed) >= $self->sample_time() ) {
                  $self->print_deltas(
                     header_callback => sub {
                        my ($self, @args) = @_;

                        if ( $self->force_header() ) {
                           my $method = $args{header_callback}
                                        || "print_header";
                           $self->$method(@args);
                        }
                        $self->set_force_header(undef);
                     },
                     rows_callback   => $args{rows_callback},
                  );
                  return;
               }
            }
         }
      },
      filehandle => $args{filehandle},
      filename   => $args{filename},
      data       => $args{data},
   );

   if ($self->interactive()) {
      return $lines_read;
   }

   return if $self->{_iterations} < 2;

   $self->print_deltas(
      header_callback => $args{header_callback},
      rows_callback   => $args{rows_callback},
   );

   $self->clear_state();

   return $lines_read;
}

sub clear_state {
   my ($self, @args)   = @_;
   my $orig_print_h = $self->{force_header};
   $self->{_iterations} = 0;
   $self->SUPER::clear_state(@args);
   $self->{force_header} = $orig_print_h;
}

sub compute_line_ts {
   my ($self, %args) = @_;
   if ( $self->show_timestamps() ) {
      return $self->SUPER::compute_line_ts(%args);
   }
   else {
      return "{" . ($self->{_iterations} - 1) . "}";
   }
}

sub delta_against {
   my ($self, $dev) = @_;
   return $self->first_stats_for($dev);
}

sub ts_line_for_timestamp {
   my ($self) = @_;
   return $self->prev_ts_line();
}

sub delta_against_ts {
   my ($self) = @_;
   return $self->first_ts();
}

sub compute_in_progress {
   my ($self, $in_progress, $tot_in_progress) = @_;
   return $tot_in_progress / ($self->{_iterations} - 1);
}

1;
}
# ###########################################################################
# End DiskstatsGroupByDisk package
# ###########################################################################

# ###########################################################################
# DiskstatsGroupBySample package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/DiskstatsGroupBySample.pm
#   t/lib/DiskstatsGroupBySample.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{

package DiskstatsGroupBySample;

use warnings;
use strict;
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use base qw( Diskstats );

use POSIX qw( ceil );

sub new {
   my ( $class, %args ) = @_;
   my $self = $class->SUPER::new(%args);
   $self->{_iterations}        = 0;
   $self->{_save_curr_as_prev} = 0;
   return $self;
}

sub group_by {
   my ( $self, %args ) = @_;
   my @optional_args   = qw( header_callback rows_callback );
   my ( $header_callback, $rows_callback ) = $args{ @optional_args };

   $self->clear_state() unless $self->interactive();

   $self->parse_from(
      sample_callback => $self->can("_sample_callback"),
      filehandle      => $args{filehandle},
      filename        => $args{filename},
      data            => $args{data},
   );

   return;
}

sub _sample_callback {
   my ( $self, $ts, %args ) = @_;
   my $printed_a_line = 0;

   if ( $self->has_stats() ) {
      $self->{_iterations}++;
   }

   my $elapsed = ($self->curr_ts() || 0)
               - ($self->prev_ts() || 0);

   if ( $ts > 0 && ceil($elapsed) >= $self->sample_time() ) {

      $self->print_deltas(
         max_device_length       => 6,
         header_callback         => sub {
            my ( $self, $header, @args ) = @_;

            if ( $self->force_header() ) {
               my $method = $args{header_callback} || "print_header";
               $self->$method( $header, @args );
               $self->set_force_header(undef);
            }
         },
         rows_callback => sub {
            my ( $self, $format, $cols, $stat ) = @_;
            my $method = $args{rows_callback} || "print_rows";
            $self->$method( $format, $cols, $stat );
            $printed_a_line = 1;
         }
      );
   }
   if ( $self->{_iterations} == 1 || $printed_a_line == 1 ) {
      $self->{_save_curr_as_prev} = 1;
      $self->_save_curr_as_prev( $self->stats_for() );
      $self->set_prev_ts_line( $self->curr_ts_line() );
      $self->{_save_curr_as_prev} = 0;
   }
   return;
}

sub delta_against {
   my ( $self, $dev ) = @_;
   return $self->prev_stats_for($dev);
}

sub ts_line_for_timestamp {
   my ($self) = @_;
   return $self->prev_ts_line();
}

sub delta_against_ts {
   my ( $self ) = @_;
   return $self->prev_ts();
}

sub clear_state {
   my ( $self, @args )         = @_;
   $self->{_iterations}        = 0;
   $self->{_save_curr_as_prev} = 0;
   $self->SUPER::clear_state(@args);
}

sub compute_devs_in_group {
   my ($self) = @_;
   my $stats  = $self->stats_for();
   return scalar grep {
            $stats->{$_} && $self->_print_device_if($_)
         } $self->ordered_devs;
}

sub compute_dev {
   my ( $self, $devs ) = @_;
   $devs ||= $self->compute_devs_in_group();
   return "{" . $devs . "}" if $devs > 1;
   return (grep { $self->_print_device_if($_) } $self->ordered_devs())[0];
}

sub _calc_stats_for_deltas {
   my ( $self, $elapsed ) = @_;

   my $delta_for;

   foreach my $dev ( grep { $self->_print_device_if($_) } $self->ordered_devs() ) {
      my $curr    = $self->stats_for($dev);
      my $against = $self->delta_against($dev);

      next unless $curr && $against;

      my $delta = $self->_calc_delta_for( $curr, $against );
      $delta->{ios_in_progress} = $curr->[Diskstats::IOS_IN_PROGRESS];
      while ( my ( $k, $v ) = each %$delta ) {
         $delta_for->{$k} += $v;
      }
   }

   return unless $delta_for && %{$delta_for};

   my $in_progress     = $delta_for->{ios_in_progress};
   my $tot_in_progress = 0;
   my $devs_in_group   = $self->compute_devs_in_group() || 1;

   my %stats = (
      $self->_calc_read_stats(
         delta_for     => $delta_for,
         elapsed       => $elapsed,
         devs_in_group => $devs_in_group,
      ),
      $self->_calc_write_stats(
         delta_for     => $delta_for,
         elapsed       => $elapsed,
         devs_in_group => $devs_in_group,
      ),
      in_progress =>
         $self->compute_in_progress( $in_progress, $tot_in_progress ),
   );

   my %extras = $self->_calc_misc_stats(
      delta_for     => $delta_for,
      elapsed       => $elapsed,
      devs_in_group => $devs_in_group,
      stats         => \%stats,
   );

   @stats{ keys %extras } = values %extras;

   $stats{dev} = $self->compute_dev( $devs_in_group );

   $self->{_first_time_magic} = undef;
   if ( @{$self->{_nochange_skips}} ) {
      my $devs = join ", ", @{$self->{_nochange_skips}};
      PTDEBUG && _d("Skipping [$devs], haven't changed from the first sample");
      $self->{_nochange_skips} = [];
   }

   return \%stats;
}

sub compute_line_ts {
   my ($self, %args) = @_;
   if ( $self->show_timestamps() ) {
      @args{ qw( first_ts curr_ts ) } = @args{ qw( curr_ts first_ts ) }
   }
   return $self->SUPER::compute_line_ts(%args);
}

1;
}
# ###########################################################################
# End DiskstatsGroupBySample package
# ###########################################################################

# ###########################################################################
# DiskstatsMenu package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/DiskstatsMenu.pm
#   t/lib/DiskstatsMenu.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package DiskstatsMenu;


use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use POSIX qw( fmod :sys_wait_h );

use IO::Handle;
use IO::Select;
use Time::HiRes  qw( gettimeofday );
use Scalar::Util qw( looks_like_number blessed );

use ReadKeyMini  qw( ReadMode );
use Transformers qw( ts       );

require DiskstatsGroupByAll;
require DiskstatsGroupByDisk;
require DiskstatsGroupBySample;

my %actions = (
   'A'  => \&group_by,
   'D'  => \&group_by,
   'S'  => \&group_by,
   'i'  => \&hide_inactive_disks,
   'z'  => get_new_value_for( "sample_time",
                       "Enter a new interval between samples in seconds: " ),
   'c'  => get_new_regex_for( "columns_regex",
                       "Enter a column pattern: " ),
   '/'  => get_new_regex_for( "devices_regex",
                       "Enter a disk/device pattern: " ),
   'q'  => sub { return 'last' },
   'p'  => sub {
            print "Paused - press any key to continue\n";
            pause(@_);
            return;
         },
   ' '  => \&print_header,
   "\n" => \&print_header,
   '?'  => \&help,
);

my %input_to_object = (
      D  => "DiskstatsGroupByDisk",
      A  => "DiskstatsGroupByAll",
      S  => "DiskstatsGroupBySample",
   );

sub new {
   return bless {}, shift;
}

sub run_interactive {
   my ($self, %args) = @_;
   my @required_args = qw(OptionParser);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($o) = @args{@required_args};

   $o->{opts}->{current_group_by_obj}->{value} = undef;

   my ($tmp_fh, $filename, $child_pid, $child_fh);

   if ( $filename = $args{filename} ) {
      if ( ref $filename ) {
         $tmp_fh = $filename;
         undef $args{filename};
      }
      else {
         open $tmp_fh, "<", $filename
            or die "Cannot open $filename: $OS_ERROR";
      }
   }
   else {
      $filename = $o->get('save-samples');

      if ( $filename ) {
         unlink $filename;
         open my $tmp_fh, "+>", $filename
            or die "Cannot open $filename: $OS_ERROR";
      }

      $child_pid = open $child_fh, "-|";
   
      die "Cannot fork: $OS_ERROR" unless defined $child_pid;
      
      if ( !$child_pid ) {
         STDOUT->autoflush(1);
         local $PROGRAM_NAME = "$PROGRAM_NAME (data-gathering daemon)";
   
         close $tmp_fh if $tmp_fh;
   
         PTDEBUG && _d("Child is [$PROGRAM_NAME] in ps aux and similar");

         gather_samples(
               gather_while      => sub { getppid() },
               samples_to_gather => $o->get('iterations'),
               filename          => $filename,
               sample_interval   => $o->get('interval'),
         );
         if ( $filename ) {
            unlink $filename unless $o->get('save-samples');
         }
         exit(0);
      }
      else {
         PTDEBUG && _d("Forked, child is", $child_pid);
         $tmp_fh = $child_fh;
         $tmp_fh->blocking(0);
         Time::HiRes::sleep(0.5);
      }
   }

   PTDEBUG && _d(
         $filename
         ? ("Using file", $filename)
         : "Not using a file to store samples");

   local $SIG{CHLD} = 'IGNORE';
   local $SIG{PIPE} = 'IGNORE';

   STDOUT->autoflush;
   STDIN->blocking(0);

   my $sel      = IO::Select->new(\*STDIN);
   my $group_by = $o->get('group-by') || 'disk';
   my $class    =  $group_by =~ m/disk/i   ? 'DiskstatsGroupByDisk'
                 : $group_by =~ m/sample/i ? 'DiskstatsGroupBySample'
                 : $group_by =~ m/all/i    ? 'DiskstatsGroupByAll'
                 : die "Invalid --group-by: $group_by";
   $o->set("current_group_by_obj",
            $class->new( OptionParser => $o, interactive => 1 )
          );

   my $header_callback = $o->get("current_group_by_obj")
                           ->can("print_header");

   my $redraw = 0;

   if ( $args{filename} ) {
      PTDEBUG && _d("Passed a file from the command line,",
                    "rendering from scratch before looping");
      $redraw = 1;
      group_by(
         header_callback => $header_callback,
         select_obj      => $sel,
         OptionParser    => $o,
         filehandle      => $tmp_fh,
         input           => substr(ucfirst($group_by), 0, 1),
         redraw_all      => $redraw,
      );
      if ( !-t STDOUT && !tied *STDIN ) {
          PTDEBUG && _d("Not connected to a tty and not in testing. Quitting");
          return 0
      }
   }

   ReadKeyMini::cbreak();
   my $run = 1;
   MAIN_LOOP:
   while ($run) {
      my $refresh_interval = $o->get('interval');
      my $time  = scalar Time::HiRes::gettimeofday();
      my $sleep = ($refresh_interval - fmod( $time, $refresh_interval ))+0.5;

      if ( my $input = read_command_timeout( $sel, $sleep ) ) {
         if ($actions{$input}) {
            PTDEBUG && _d("Got [$input] and have an action for it");
            my $ret = $actions{$input}->(
                              select_obj   => $sel,
                              OptionParser => $o,
                              input        => $input,
                              filehandle   => $tmp_fh,
                              redraw_all   => $redraw,
                           ) || '';
            last MAIN_LOOP if $ret eq 'last';

            if ( $args{filename}
                  && !grep { $input eq $_ } qw( A S D ), ' ', "\n" )
            {
               PTDEBUG && _d("Got a file from the command line, redrawing",
                             "from the beginning after getting an option");
               my $obj = $o->get("current_group_by_obj");
               $obj->clear_state( force => 1 );
               local $obj->{force_header} = 1;
               group_by(
                  redraw_all      => 1,
                  select_obj      => $sel,
                  OptionParser    => $o,
                  input           => substr(ref($obj), 16, 1),
                  filehandle      => $tmp_fh,
               );
            }
         }
      }
      $o->get("current_group_by_obj")
        ->group_by( filehandle => $tmp_fh );

      if ( eof $tmp_fh ) {
         $tmp_fh->clearerr;
      }
      if ( !$args{filename} && $o->get('iterations')
            && waitpid($child_pid, WNOHANG) != 0 ) {
         PTDEBUG && _d("Child quit as expected after",
                       $o->get("iterations"),
                       "iterations. Quitting.");
         $run = 0;
      }
   }
   ReadKeyMini::cooked();

   if ( $child_pid && !$args{filename} && !defined $o->get('iterations')
            && kill 0, $child_pid ) {
      kill 9, $child_pid;
      waitpid $child_pid, 0;
   }

   return 0; # Exit status
}

sub read_command_timeout {
   my ($sel, $timeout) = @_;
   if ( $sel->can_read( $timeout ) ) {
      return scalar <STDIN>;
   }
   return;
}

sub gather_samples {
   my (%args)  = @_;
   my $samples = 0;
   my $sample_interval = $args{sample_interval};
   my @fhs;

   if ( my $filename = $args{filename} ) {
      open my $fh, ">>", $filename
         or die "Cannot open $filename for appending: $OS_ERROR";
      push @fhs, $fh;
   }

   STDOUT->autoflush(1);
   push @fhs, \*STDOUT;

   for my $fh ( @fhs ) {
      $fh->autoflush(1);
   }

   {
      my $time  = scalar(Time::HiRes::gettimeofday());
      my $sleep = $sample_interval - fmod( $time,
                              $sample_interval);
      PTDEBUG && _d("Child: Starting at [$time] "
                    . ($sleep < ($sample_interval * 0.2) ? '' : 'not ')
                    . "going to sleep");
      Time::HiRes::sleep($sleep) if $sleep < ($sample_interval * 0.2);

      open my $diskstats_fh, "<", "/proc/diskstats"
         or die "Cannot open /proc/diskstats: $OS_ERROR";

      my @to_print = timestamp();
      push @to_print, <$diskstats_fh>;
   
      for my $fh ( @fhs ) {
         print { $fh } @to_print;
      }
      close $diskstats_fh or die $OS_ERROR;
   }

   GATHER_DATA:
   while ( $args{gather_while}->() ) {
      my $time_of_day = scalar(Time::HiRes::gettimeofday());
      my $sleep = $sample_interval
             - fmod( $time_of_day, $sample_interval );
      Time::HiRes::sleep($sleep);

      open my $diskstats_fh, "<", "/proc/diskstats"
         or die "Cannot open /proc/diskstats: $OS_ERROR";

      my @to_print = timestamp();
      push @to_print, <$diskstats_fh>;

      for my $fh ( @fhs ) {
         print { $fh } @to_print;
      }
      close $diskstats_fh or die $OS_ERROR;

      $samples++;
      if ( defined($args{samples_to_gather})
            && $samples >= $args{samples_to_gather} ) {
         last GATHER_DATA;
      }
   }
   pop @fhs; # STDOUT
   for my $fh ( @fhs ) {
      close $fh or die $OS_ERROR;
   }
   return;
}

sub print_header {
   my (%args) = @_;
   my @required_args = qw( OptionParser );
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($o) = @args{@required_args};

   my $obj = $o->get("current_group_by_obj");
   my ($header) = $obj->design_print_formats();
   return $obj->force_print_header($header, "#ts", "device");
}

sub group_by {
   my (%args)  = @_;

   my @required_args = qw( OptionParser input );
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($o, $input) = @args{@required_args};

   my $old_obj = $o->get("current_group_by_obj");

   if ( ref( $o->get("current_group_by_obj") ) ne $input_to_object{$input} ) {
      $o->set("current_group_by_obj", undef);
      my $new_obj = $input_to_object{$input}->new(OptionParser=>$o, interactive => 1);
      $o->set( "current_group_by_obj", $new_obj );

      $new_obj->{_stats_for}  = $old_obj->{_stats_for};
      $new_obj->set_curr_ts($old_obj->curr_ts());

      $new_obj->{_prev_stats_for}  = $old_obj->{_prev_stats_for};
      $new_obj->set_prev_ts($old_obj->prev_ts());

      $new_obj->{_first_stats_for} = $old_obj->{_first_stats_for};
      $new_obj->set_first_ts($old_obj->first_ts());

      print_header(%args) unless $args{redraw_all};
   }

   for my $obj ( $o->get("current_group_by_obj") ) {
      if ( $args{redraw_all} ) {
         seek $args{filehandle}, 0, 0;
         if ( $obj->isa("DiskstatsGroupBySample") ) {
            $obj->set_interactive(1);
         }
         else {
            $obj->set_interactive(0);
         }
   
         my $print_header;
         my $header_callback = $args{header_callback} || sub {
                                 my ($self, @args) = @_;
                                 $self->print_header(@args) unless $print_header++
                              };
   
         $obj->group_by(
                  filehandle      => $args{filehandle},
                  header_callback => $header_callback,
               );
      }
      $obj->set_interactive(1);
      $obj->set_force_header(0);
   }

}

sub help {
   my (%args)     = @_;
   my $obj        = $args{OptionParser}->get("current_group_by_obj");
   my $mode       = substr ref($obj), 16, 1;
   my $column_re  = $args{OptionParser}->get('columns-regex');
   my $device_re  = $args{OptionParser}->get('devices-regex');
   my $interval   = $obj->sample_time() || '(none)';
   my $disp_int   = $args{OptionParser}->get('interval');
   my $inact_disk = $obj->show_inactive() ? 'no' : 'yes';

   for my $re ( $column_re, $device_re ) {
      $re ||= '(none)';
   }

   print <<"HELP";
   You can control this program by key presses:
   ------------------- Key ------------------- ---- Current Setting ----
   A, D, S) Set the group-by mode              $mode
   c) Enter a Perl regex to match column names $column_re
   /) Enter a Perl regex to match disk names   $device_re
   z) Set the sample size in seconds           $interval
   i) Hide inactive disks                      $inact_disk
   p) Pause the program
   q) Quit the program
   space) Print headers
   ------------------- Press any key to continue -----------------------
HELP

   pause(%args);
   return;
}

sub get_blocking_input {
   my ($message) = @_;

   STDIN->blocking(1);
   ReadKeyMini::cooked();

   print $message;
   chomp(my $new_opt = <STDIN>);

   ReadKeyMini::cbreak();
   STDIN->blocking(0);

   return $new_opt;
}

sub hide_inactive_disks {
   my (%args)  = @_;
   my $obj     = $args{OptionParser}->get("current_group_by_obj");
   my $new_val = !$obj->show_inactive();

   $args{OptionParser}->set('show-inactive', $new_val);
   $obj->set_show_inactive($new_val);

   return;
}

sub get_new_value_for {
   my ($looking_for, $message) = @_;
   (my $looking_for_o = $looking_for) =~ tr/_/-/;
   return sub {
      my (%args)       = @_;
      my $o            = $args{OptionParser};
      my $new_interval = get_blocking_input($message) || 0;
   
      die "Invalid timeout: $new_interval"
         unless looks_like_number($new_interval)
                  && ($new_interval = int($new_interval));

      my $obj = $o->get("current_group_by_obj");
      if ( my $setter = $obj->can("set_$looking_for") ) {
         $obj->$setter($new_interval);
      }
      $o->set($looking_for_o, $new_interval);
      return $new_interval;
   };
}

sub get_new_regex_for {
   my ($looking_for, $message) = @_;
   (my $looking_for_o = $looking_for) =~ tr/_/-/;
   $looking_for = "set_$looking_for";
   return sub {
      my (%args)    = @_;
      my $o         = $args{OptionParser};
      my $new_regex = get_blocking_input($message);
   
      local $EVAL_ERROR;
      if ( $new_regex && (my $re = eval { qr/$new_regex/i }) ) {
         $o->get("current_group_by_obj")
           ->$looking_for( $re );

         $o->set($looking_for_o, $new_regex);
      }
      elsif ( !$EVAL_ERROR && !$new_regex ) {
         my $re;
         if ( $looking_for =~ /device/ ) {
            $re = undef;
         }
         else {
            $re = qr/.+/;
         }
         $o->get("current_group_by_obj")
           ->$looking_for( $re );
         $o->set($looking_for_o, '');
      }
      else {
         die "invalid regex specification: $EVAL_ERROR";
      }
      return;
   };
}

sub pause {
   my (%args) = @_;
   STDIN->blocking(1);
   $args{select_obj}->can_read();
   STDIN->blocking(0);
   scalar <STDIN>;
   return;
}

sub timestamp {
   my ($s, $m) = Time::HiRes::gettimeofday();
   return sprintf( "TS %d.%09d %s\n", $s, $m*1000, Transformers::ts( $s ) );
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
# End DiskstatsMenu package
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
{
package pt_diskstats;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;
use Percona::Toolkit;

sub main {
   local @ARGV = @_;  # set global ARGV for this package

   # ########################################################################
   # Get configuration information.
   # ########################################################################
   my $o = new OptionParser();
   $o->get_specs();
   $o->get_opts();

   # --sample-time only applies to --group-by sample.
   if ( PTDEBUG
        && $o->get('group-by') !~ m/sample/i
        && $o->get('sample-time') )
   {
      _d("Possibly useless use of --sample-time without --group-by sample");
   }

   if ( !$o->get('help') ) {
      if ( !$o->get('columns-regex') ) {
         $o->save_error("A regex pattern for --column-regex must be specified");
      }
   }

   $o->usage_or_errors();

   # ########################################################################
   # Do the version-check
   # ########################################################################
   if ( $o->get('version-check') && (!$o->has('quiet') || !$o->get('quiet')) ) {
      VersionCheck::version_check(
         force => $o->got('version-check'),
      );
   }

   # ########################################################################
   # Interactive mode. Delegate to DiskstatsMenu::run_interactive
   # ########################################################################
   my $diskstats = new DiskstatsMenu();
   return $diskstats->run_interactive(
      OptionParser => $o,
      filename     => $ARGV[0]
   );
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

1;
}

# #############################################################################
# Documentation.
# #############################################################################

=pod

=head1 NAME

pt-diskstats - An interactive I/O monitoring tool for GNU/Linux.

=head1 SYNOPSIS

Usage: pt-diskstats [OPTIONS] [FILES]

pt-diskstats prints disk I/O statistics for GNU/Linux.  It is somewhat similar
to iostat, but it is interactive and more detailed.  It can analyze samples
gathered from another machine.

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

The pt-diskstats tool is similar to iostat, but has some advantages. It prints
read and write statistics separately, and has more columns. It is menu-driven
and interactive, with several different ways to aggregate the data. It
integrates well with the L<pt-stalk> tool. It also does the "right thing" by
default, such as hiding disks that are idle.  These properties make it very
convenient for quickly drilling down into I/O performance and inspecting disk
behavior.

This program works in two modes. The default is to collect samples of
F</proc/diskstats> and print out the formatted statistics at intervals. The other
mode is to process a file that contains saved samples of F</proc/diskstats>; there
is a shell script later in this documentation that shows how to collect such a
file.

In both cases, the tool is interactively controlled by keystrokes, so you can
redisplay and slice the data flexibly and easily.  It loops forever, until you
exit with the 'q' key.  If you press the '?' key, you will bring up the
interactive help menu that shows which keys control the program.

When the program is gathering samples of F</proc/diskstats> and refreshing its
display, it prints information about the newest sample each time it refreshes.
When it is operating on a file of saved samples, it redraws the entire file's
contents every time you change an option.

The program doesn't print information about every block device on the system. It
hides devices that it has never observed to have any activity.  You can enable
and disable this by pressing the 'i' key.

=head1 OUTPUT

In the rest of this documentation, we will try to clarify the distinction
between block devices (/dev/sda1, for example), which the kernel presents to the
application via a filesystem, versus the (usually) physical device underneath
the block device, which could be a disk, a RAID controller, and so on.  We will
sometimes refer to logical I/O operations, which occur at the block device,
versus physical I/Os which are performed on the underlying device.  When we
refer to the queue, we are speaking of the queue associated with the block
device, which holds requests until they're issued to the physical device.

The program's output looks like the following sample, which is too wide for this
manual page, so we have formatted it as several samples with line breaks:

  #ts device rd_s rd_avkb rd_mb_s rd_mrg rd_cnc   rd_rt
  {6} sda     0.9     4.2     0.0     0%    0.0    17.9
  {6} sdb     0.4     4.0     0.0     0%    0.0    26.1
  {6} dm-0    0.0     4.0     0.0     0%    0.0    13.5
  {6} dm-1    0.8     4.0     0.0     0%    0.0    16.0

      ...    wr_s wr_avkb wr_mb_s wr_mrg wr_cnc   wr_rt
      ...    99.7     6.2     0.6    35%    3.7    23.7
      ...    14.5    15.8     0.2    75%    0.5     9.2
      ...     1.0     4.0     0.0     0%    0.0     2.3
      ...   117.7     4.0     0.5     0%    4.1    35.1

      ...              busy in_prg    io_s  qtime stime
      ...                6%      0   100.6   23.3   0.4
      ...                4%      0    14.9    8.6   0.6
      ...                0%      0     1.1    1.5   1.2
      ...                5%      0   118.5   34.5   0.4

The columns are as follows:

=over

=item #ts

This column's contents vary depending on the tool's aggregation mode.  In the
default mode, when each line contains information about a single disk but
possibly aggregates across several samples from that disk, this column shows the
number of samples that were included into the line of output, in {curly braces}.
In the example shown, each line of output aggregates {10} samples of
F</proc/diskstats>.

In the "all" group-by mode, this column shows timestamp offsets, relative to the
time the tool began aggregating or the timestamp of the previous lines printed,
depending on the mode.  The output can be confusing to explain, but it's rather
intuitive when you see the lines appearing on your screen periodically.

Similarly, in "sample" group-by mode, the number indicates the total time span
that is grouped into each sample.

If you specify L<"--show-timestamps">, this field instead shows the timestamp at
which the sample was taken; if multiple timestamps are present in a single line
of output, then the first timestamp is used.

=item device

The device name.  If there is more than one device, then instead the number
of devices aggregated into the line is shown, in {curly braces}.

=item rd_s

The average number of reads per second.  This is the number of I/O requests that
were sent to the underlying device.  This usually is a smaller number than the
number of logical IO requests made by applications.  More requests might have
been queued to the block device, but some of them usually are merged before
being sent to the disk.

This field is computed from the contents of F</proc/diskstats> as follows.  See
L<"KERNEL DOCUMENTATION"> below for the meaning of the field numbers:

   delta[field1] / delta[time]

=item rd_avkb

The average size of the reads, in kilobytes.  This field is computed as follows:

   2 * delta[field3] / delta[field1]

=item rd_mb_s

The average number of megabytes read per second.  Computed as follows:

   2 * delta[field3] / delta[time]

=item rd_mrg

The percentage of read requests that were merged together in the queue scheduler
before being sent to the physical device.  The field is computed as follows:

   100 * delta[field2] / (delta[field2] + delta[field1])

=item rd_cnc

The average concurrency of the read operations, as computed by Little's Law.
This is the end-to-end concurrency on the block device, not the underlying
disk's concurrency. It includes time spent in the queue.  The field is computed
as follows:

   delta[field4] / delta[time] / 1000 / devices-in-group

=item rd_rt

The average response time of the read operations, in milliseconds.  This is the
end-to-end response time, including time spent in the queue.  It is the response
time that the application making I/O requests sees, not the response time of the
physical disk underlying the block device.  It is computed as follows:

   delta[field4] / (delta[field1] + delta[field2])

=item wr_s, wr_avkb, wr_mb_s, wr_mrg, wr_cnc, wr_rt

These columns show write activity, and they match the corresponding columns for
read activity.

=item busy

The fraction of wall-clock time that the device had at least one request in
progress; this is what iostat calls %util, and indeed it is utilization,
depending on how you define utilization, but that is sometimes ambiguous in
common parlance.  It may also be called the residence time; the time during
which at least one request was resident in the system.  It is computed as
follows:

   100 * delta[field10] / (1000 * delta[time])

This field cannot exceed 100% unless there is a rounding error, but it is a
common mistake to think that a device that's busy all the time is saturated.  A
device such as a RAID volume should support concurrency higher than 1, and
solid-state drives can support very high concurrency.  Concurrency can grow
without bound, and is a more reliable indicator of how loaded the device really
is.

=item in_prg

The number of requests that were in progress.  Unlike the read and write
concurrencies, which are averages that are generated from reliable numbers, this
number is an instantaneous sample, and you can see that it might represent a
spike of requests, rather than the true long-term average.  If this number is
large, it essentially means that the device is heavily loaded.  It is computed
as follows:

   field9

=item ios_s

The average throughput of the physical device, in I/O operations per second
(IOPS).  This column shows the total IOPS the underlying device is handling.  It
is the sum of rd_s and wr_s.

=item qtime

The average queue time; that is, time a request spends in the device scheduler
queue before being sent to the physical device.  This is an average over reads
and writes.

It is computed in a slightly complex way: the average response time seen by the
application, minus the average service time (see the description of the next
column).  This is derived from the queueing theory formula for response time, R
= W + S: response time = queue time + service time.  This is solved for W, of
course, to give W = R - S.  The computation follows:

   delta[field11] / (delta[field1, 2, 5, 6] + delta[field9])
      - delta[field10] / delta[field1, 2, 5, 6]

See the description for C<stime> for more details and cautions.

=item stime

The average service time; that is, the time elapsed while the physical device
processes the request, after the request finishes waiting in the queue.  This is
an average over reads and writes.  It is computed from the queueing theory
utilization formula, U = SX, solved for S.  This means that utilization divided
by throughput gives service time:

   delta[field10] / (delta[field1, 2, 5, 6])

Note, however, that there can be some kernel bugs that cause field 9 in
F</proc/diskstats> to become negative, and this can cause field 10 to be wrong,
thus making the service time computation not wholly trustworthy.

Note that in the above formula we use utilization very specifically. It is a
duration, not a percentage.

You can compare the stime and qtime columns to see whether the response time for
reads and writes is spent in the queue or on the physical device.  However, you
cannot see the difference between reads and writes.  Changing the block device
scheduler algorithm might improve queue time greatly.  The default algorithm,
cfq, is very bad for servers, and should only be used on laptops and
workstations that perform tasks such as working with spreadsheets and surfing
the Internet.

=back

If you are used to using iostat, you might wonder where you can find the same
information in pt-diskstats.  Here are two samples of output from both tools on
the same machine at the same time, for F</dev/sda>, wrapped to fit:

        #ts dev rd_s rd_avkb rd_mb_s rd_mrg rd_cnc   rd_rt
   08:50:10 sda  0.0     0.0     0.0     0%    0.0     0.0
   08:50:20 sda  0.4     4.0     0.0     0%    0.0    15.5
   08:50:30 sda  2.1     4.4     0.0     0%    0.0    21.1
   08:50:40 sda  2.4     4.0     0.0     0%    0.0    15.4
   08:50:50 sda  0.1     4.0     0.0     0%    0.0    33.0

                wr_s wr_avkb wr_mb_s wr_mrg wr_cnc   wr_rt
                 7.7    25.5     0.2    84%    0.0     0.3
                49.6     6.8     0.3    41%    2.4    28.8
               210.1     5.6     1.1    28%    7.4    25.2
               297.1     5.4     1.6    26%   11.4    28.3
                11.9    11.7     0.1    66%    0.2     4.9

                        busy  in_prg   io_s  qtime   stime
                          1%       0    7.7    0.1     0.2
                          6%       0   50.0   28.1     0.7
                         12%       0  212.2   24.8     0.4
                         16%       0  299.5   27.8     0.4
                          1%       0   12.0    4.7     0.3

            Dev rrqm/s  wrqm/s   r/s    w/s  rMB/s  wMB/s
   08:50:10 sda   0.00   41.40  0.00   7.70   0.00   0.19
   08:50:20 sda   0.00   34.70  0.40  49.60   0.00   0.33
   08:50:30 sda   0.00   83.30  2.10 210.10   0.01   1.15
   08:50:40 sda   0.00  105.10  2.40 297.90   0.01   1.58
   08:50:50 sda   0.00   22.50  0.10  11.10   0.00   0.13

                   avgrq-sz avgqu-sz  await  svctm  %util
                      51.01     0.02   2.04   1.25   0.96
                      13.55     2.44  48.76   1.16   5.79
                      11.15     7.45  35.10   0.55  11.76
                      10.81    11.40  37.96   0.53  15.97
                      24.07     0.17  15.60   0.87   0.97

The correspondence between the columns is not one-to-one.  In particular:

=over

=item rrqm/s, wrqm/s

These columns in iostat are replaced by rd_mrg and wr_mrg in pt-diskstats.

=item avgrq-sz

This column is in sectors in iostat, and is a combination of reads and writes.
The pt-diskstats output breaks these out separately and shows them in kB.  You
can derive it via a weighted average of rd_avkb and wr_avkb in pt-diskstats, and
then multiply by 2 to get sectors (each sector is 512 bytes).

=item avgqu-sz

This column really represents concurrency at the block device scheduler.  The
pt-diskstats output shows concurrency for reads and writes separately: rd_cnc
and wr_cnc.

=item await

This column is the average response time from the beginning to the end of a
request to the block device, including queue time and service time, and is not
shown in pt-diskstats.  Instead, pt-diskstats shows individual response times at
the disk level for reads and writes (rd_rt and wr_rt), as well as queue time
versus service time for reads and writes in aggregate.

=item svctm

This column is the average service time at the disk, and is shown as stime in
pt-diskstats.

=item %util

This column is called busy in pt-diskstats.  Utilization is usually defined as
the portion of time during which there was at least one active request, not as a
percentage, which is why we chose to avoid this confusing term.

=back

=head1 COLLECTING DATA

It is straightforward to gather a sample of data for this tool.  Files should
have this format, with a timestamp line preceding each sample of statistics:

   TS <timestamp>
   <contents of /proc/diskstats>
   TS <timestamp>
   <contents of /proc/diskstats>
   ... et cetera

You can simply use pt-diskstats with L<"--save-samples"> to collect this data
for you.  If you wish to capture samples as part of some other tool, and use
pt-diskstats to analyze them, you can include a snippet of shell script such as
the following:

   INTERVAL=1
   while true; do
      sleep=$(date +%s.%N | awk "{print $INTERVAL - (\$1 % $INTERVAL)}")
      sleep $sleep
      date +"TS %s.%N %F %T" >> diskstats-samples.txt
      cat /proc/diskstats >> diskstats-samples.txt
   done

=head1 KERNEL DOCUMENTATION

This documentation supplements L<the official
documentation|http://www.kernel.org/doc/Documentation/iostats.txt> on the
contents of F</proc/diskstats>.  That documentation can sometimes be difficult
to understand for those who are not familiar with Linux kernel internals.  The
contents of F</proc/diskstats> are generated by the C<diskstats_show()> function
in the kernel source file F<block/genhd.c>.

Here is a sample of F</proc/diskstats> on a recent kernel.

   8 1 sda1 426 243 3386 2056 3 0 18 87 0 2135 2142

The fields in this sample are as follows.  The first three fields are the major
and minor device numbers (8, 1), and the device name (sda1). They are followed
by 11 fields of statistics:

=over

=item 1.

The number of reads completed.  This is the number of physical reads done by the
underlying disk, not the number of reads that applications made from the block
device.  This means that 426 actual reads have completed successfully to the
disk on which F</dev/sda1> resides.  Reads are not counted until they complete.

=item 2.

The number of reads merged because they were adjacent.  In the sample, 243 reads
were merged. This means that F</dev/sda1> actually received 869 logical reads,
but sent only 426 physical reads to the underlying physical device.

=item 3.

The number of sectors read successfully.  The 426 physical reads to the disk
read 3386 sectors.  Sectors are 512 bytes, so a total of about 1.65MB have been
read from F</dev/sda1>.

=item 4.

The number of milliseconds spent reading.  This counts only reads that have
completed, not reads that are in progress.  It counts the time spent from when
requests are placed on the queue until they complete, not the time that the
underlying disk spends servicing the requests. That is, it measures the total
response time seen by applications, not disk response times.

=item 5.

Ditto for field 1, but for writes.

=item 6.

Ditto for field 2, but for writes.

=item 7.

Ditto for field 3, but for writes.

=item 8.

Ditto for field 4, but for writes.

=item 9.

The number of I/Os currently in progress, that is, they've been scheduled by the
queue scheduler and issued to the disk (submitted to the underlying disk's
queue), but not yet completed.  There are bugs in some kernels that cause this
number, and thus fields 10 and 11, to be wrong sometimes.

=item 10.

The total number of milliseconds spent doing I/Os.  This is B<not> the total
response time seen by the applications; it is the total amount of time during
which at least one I/O was in progress.  If one I/O is issued at time 100,
another comes in at 101, and both of them complete at 102, then this field
increments by 2, not 3.

=item 11.

This field counts the total response time of all I/Os.  In contrast to field 10,
it counts double when two I/Os overlap.  In our previous example, this field
would increment by 3, not 2.

=back

=head1 OPTIONS

This tool accepts additional command-line arguments.  Refer to the
L<"SYNOPSIS"> and usage information for details.

=over

=item --columns-regex

type: string; default: .

Print columns that match this Perl regex.

=item --config

type: Array

Read this comma-separated list of config files; if specified, this must be the
first option on the command line.

=item --devices-regex

type: string

Print devices that match this Perl regex.

=item --group-by

type: string; default: all

Group-by mode: disk, sample, or all.  In B<disk> mode, each line of output
shows one disk device, with the statistics computed since the tool started.  In
B<sample> mode, each line of output shows one sample of statistics, with all
disks averaged together.  In B<all> mode, each line of output shows one sample
and one disk device.

=item --headers

type: Hash; default: group,scroll

If C<group> is present, each sample will be separated by a blank line, unless
the sample is only one line.  If C<scroll> is present, the tool will print the
headers as often as needed to prevent them from scrolling out of view. Note that
you can press the space bar, or the enter key, to reprint headers at will.

=item --help

Show help and exit.

=item --interval

type: int; default: 1

When in interactive mode, wait N seconds before printing to the screen.
Also, how often the tool should sample F</proc/diskstats>.

The tool attempts to gather statistics exactly on even intervals of clock time.
That is, if you specify a 5-second interval, it will try to capture samples at
12:00:00, 12:00:05, and so on; it will not gather at 12:00:01, 12:00:06 and so
forth.

This can lead to slightly odd delays in some circumstances, because the tool
waits one full cycle before printing out the first set of lines. (Unlike iostat
and vmstat, pt-diskstats does not start with a line representing the averages
since the computer was booted.)  Therefore, the rule has an exception to avoid
very long delays.  Suppose you specify a 10-second interval, but you start the
tool at 12:00:00.01.  The tool might wait until 12:00:20 to print its first
lines of output, and in the intervening 19.99 seconds, it would appear to do
nothing.

To alleviate this, the tool waits until the next even interval of time to
gather, unless more than 20% of that interval remains.  This means the tool will
never wait more than 120% of the sampling interval to produce output, e.g if you
start the tool at 12:00:53 with a 10-second sampling interval, then the first
sample will be only 7 seconds long, not 10 seconds.

=item --iterations

type: int

When in interactive mode, stop after N samples.  Run forever by default.

=item --sample-time

type: int; default: 1

In --group-by sample mode, include N seconds of samples per group.

=item --save-samples

type: string

File to save diskstats samples in; these can be used for later analysis.

=item --show-inactive

Show inactive devices.

=item --show-timestamps

Show a 'HH:MM:SS' timestamp in the C<#ts> column.  If multiple timestamps are
aggregated into one line, the first timestamp is shown.

=item --version

Show version and exit.

=item --[no]version-check

default: yes

Check for the latest version of Percona Toolkit, MySQL, and other programs.

This is a standard "check for updates automatically" feature, with two
additional features.  First, the tool checks its own version and also the
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
output.  This feature should never interfere with the normal operation of the
tool.  

For more information, visit L<https://www.percona.com/doc/percona-toolkit/LATEST/version-check.html>.

=back

=head1 ENVIRONMENT

The environment variable C<PTDEBUG> enables verbose debugging output to STDERR.
To enable debugging and capture all output to a file, run the tool like:

   PTDEBUG=1 pt-diskstats ... > FILE 2>&1

Be careful: debugging output is voluminous and can generate several megabytes
of output.

=head1 SYSTEM REQUIREMENTS

This tool requires Perl v5.8.0 or newer and the F</proc> filesystem, unless
reading from files.

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-diskstats>.

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

Baron Schwartz, Brian Fraser, and Daniel Nichter

=head1 ABOUT PERCONA TOOLKIT

This tool is part of Percona Toolkit, a collection of advanced command-line
tools for MySQL developed by Percona.  Percona Toolkit was forked from two
projects in June, 2011: Maatkit and Aspersa.  Those projects were created by
Baron Schwartz and primarily developed by him and Daniel Nichter.  Visit
L<http://www.percona.com/software/> to learn about other free, open-source
software from Percona.

=head1 COPYRIGHT, LICENSE, AND WARRANTY

This program is copyright 2011-2018 Percona LLC and/or its affiliates,
2010-2011 Baron Schwartz.

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

pt-diskstats 3.3.0

=cut
