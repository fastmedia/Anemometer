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
      Daemon
      Transformers
      TableParser
      Processlist
      TextResultSetParser
      MasterSlave
      Quoter
      QueryRewriter
      Retry
      Cxn
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
# TableParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/TableParser.pm
#   t/lib/TableParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package TableParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

local $EVAL_ERROR;
eval {
   require Quoter;
};

sub new {
   my ( $class, %args ) = @_;
   my $self = { %args };
   $self->{Quoter} ||= Quoter->new();
   return bless $self, $class;
}

sub Quoter { shift->{Quoter} }

sub get_create_table {
   my ( $self, $dbh, $db, $tbl ) = @_;
   die "I need a dbh parameter" unless $dbh;
   die "I need a db parameter"  unless $db;
   die "I need a tbl parameter" unless $tbl;
   my $q = $self->{Quoter};

   my $new_sql_mode
      = q{/*!40101 SET @OLD_SQL_MODE := @@SQL_MODE, }
      . q{@@SQL_MODE := '', }
      . q{@OLD_QUOTE := @@SQL_QUOTE_SHOW_CREATE, }
      . q{@@SQL_QUOTE_SHOW_CREATE := 1 */};

   my $old_sql_mode
      = q{/*!40101 SET @@SQL_MODE := @OLD_SQL_MODE, }
      . q{@@SQL_QUOTE_SHOW_CREATE := @OLD_QUOTE */};

   PTDEBUG && _d($new_sql_mode);
   eval { $dbh->do($new_sql_mode); };
   PTDEBUG && $EVAL_ERROR && _d($EVAL_ERROR);

   my $use_sql = 'USE ' . $q->quote($db);
   PTDEBUG && _d($dbh, $use_sql);
   $dbh->do($use_sql);

   my $show_sql = "SHOW CREATE TABLE " . $q->quote($db, $tbl);
   PTDEBUG && _d($show_sql);
   my $href;
   eval { $href = $dbh->selectrow_hashref($show_sql); };
   if ( my $e = $EVAL_ERROR ) {
      PTDEBUG && _d($old_sql_mode);
      $dbh->do($old_sql_mode);

      die $e;
   }

   PTDEBUG && _d($old_sql_mode);
   $dbh->do($old_sql_mode);

   my ($key) = grep { m/create (?:table|view)/i } keys %$href;
   if ( !$key ) {
      die "Error: no 'Create Table' or 'Create View' in result set from "
         . "$show_sql: " . Dumper($href);
   }

   return $href->{$key};
}

sub parse {
   my ( $self, $ddl, $opts ) = @_;
   return unless $ddl;

   if ( $ddl =~ m/CREATE (?:TEMPORARY )?TABLE "/ ) {
      $ddl = $self->ansi_to_legacy($ddl);
   }
   elsif ( $ddl !~ m/CREATE (?:TEMPORARY )?TABLE `/ ) {
      die "TableParser doesn't handle CREATE TABLE without quoting.";
   }

   my ($name)     = $ddl =~ m/CREATE (?:TEMPORARY )?TABLE\s+(`.+?`)/;
   (undef, $name) = $self->{Quoter}->split_unquote($name) if $name;

   $ddl =~ s/(`[^`\n]+`)/\L$1/gm;

   my $engine = $self->get_engine($ddl);

   my @defs   = $ddl =~ m/^(\s+`.*?),?$/gm;
   my @cols   = map { $_ =~ m/`([^`]+)`/ } @defs;
   PTDEBUG && _d('Table cols:', join(', ', map { "`$_`" } @cols));

   my %def_for;
   @def_for{@cols} = @defs;

   my (@nums, @null, @non_generated);
   my (%type_for, %is_nullable, %is_numeric, %is_autoinc, %is_generated);
   foreach my $col ( @cols ) {
      my $def = $def_for{$col};

      $def =~ s/``//g;

      my ( $type ) = $def =~ m/`[^`]+`\s([a-z]+)/;
      die "Can't determine column type for $def" unless $type;
      $type_for{$col} = $type;
      if ( $type =~ m/(?:(?:tiny|big|medium|small)?int|float|double|decimal|year)/ ) {
         push @nums, $col;
         $is_numeric{$col} = 1;
      }
      if ( $def !~ m/NOT NULL/ ) {
         push @null, $col;
         $is_nullable{$col} = 1;
      }
      if ( remove_quoted_text($def) =~ m/\WGENERATED\W/i ) {
          $is_generated{$col} = 1;
      } else {
          push @non_generated, $col;
      }
      $is_autoinc{$col} = $def =~ m/AUTO_INCREMENT/i ? 1 : 0;
   }

   my ($keys, $clustered_key) = $self->get_keys($ddl, $opts, \%is_nullable);

   my ($charset) = $ddl =~ m/DEFAULT CHARSET=(\w+)/;

   return {
      name               => $name,
      cols               => \@cols,
      col_posn           => { map { $cols[$_] => $_ } 0..$#cols },
      is_col             => { map { $_ => 1 } @non_generated },
      null_cols          => \@null,
      is_nullable        => \%is_nullable,
      non_generated_cols => \@non_generated,
      is_autoinc         => \%is_autoinc,
      is_generated       => \%is_generated,
      clustered_key      => $clustered_key,
      keys               => $keys,
      defs               => \%def_for,
      numeric_cols       => \@nums,
      is_numeric         => \%is_numeric,
      engine             => $engine,
      type_for           => \%type_for,
      charset            => $charset,
   };
}

sub remove_quoted_text {
   my ($string) = @_;
   $string =~ s/[^\\]`[^`]*[^\\]`//g; 
   $string =~ s/[^\\]"[^"]*[^\\]"//g; 
   $string =~ s/[^\\]'[^']*[^\\]'//g; 
   return $string;
}

sub sort_indexes {
   my ( $self, $tbl ) = @_;

   my @indexes
      = sort {
         (($a ne 'PRIMARY') <=> ($b ne 'PRIMARY'))
         || ( !$tbl->{keys}->{$a}->{is_unique} <=> !$tbl->{keys}->{$b}->{is_unique} )
         || ( $tbl->{keys}->{$a}->{is_nullable} <=> $tbl->{keys}->{$b}->{is_nullable} )
         || ( scalar(@{$tbl->{keys}->{$a}->{cols}}) <=> scalar(@{$tbl->{keys}->{$b}->{cols}}) )
      }
      grep {
         $tbl->{keys}->{$_}->{type} eq 'BTREE'
      }
      sort keys %{$tbl->{keys}};

   PTDEBUG && _d('Indexes sorted best-first:', join(', ', @indexes));
   return @indexes;
}

sub find_best_index {
   my ( $self, $tbl, $index ) = @_;
   my $best;
   if ( $index ) {
      ($best) = grep { uc $_ eq uc $index } keys %{$tbl->{keys}};
   }
   if ( !$best ) {
      if ( $index ) {
         die "Index '$index' does not exist in table";
      }
      else {
         ($best) = $self->sort_indexes($tbl);
      }
   }
   PTDEBUG && _d('Best index found is', $best);
   return $best;
}

sub find_possible_keys {
   my ( $self, $dbh, $database, $table, $quoter, $where ) = @_;
   return () unless $where;
   my $sql = 'EXPLAIN SELECT * FROM ' . $quoter->quote($database, $table)
      . ' WHERE ' . $where;
   PTDEBUG && _d($sql);
   my $expl = $dbh->selectrow_hashref($sql);
   $expl = { map { lc($_) => $expl->{$_} } keys %$expl };
   if ( $expl->{possible_keys} ) {
      PTDEBUG && _d('possible_keys =', $expl->{possible_keys});
      my @candidates = split(',', $expl->{possible_keys});
      my %possible   = map { $_ => 1 } @candidates;
      if ( $expl->{key} ) {
         PTDEBUG && _d('MySQL chose', $expl->{key});
         unshift @candidates, grep { $possible{$_} } split(',', $expl->{key});
         PTDEBUG && _d('Before deduping:', join(', ', @candidates));
         my %seen;
         @candidates = grep { !$seen{$_}++ } @candidates;
      }
      PTDEBUG && _d('Final list:', join(', ', @candidates));
      return @candidates;
   }
   else {
      PTDEBUG && _d('No keys in possible_keys');
      return ();
   }
}

sub check_table {
   my ( $self, %args ) = @_;
   my @required_args = qw(dbh db tbl);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dbh, $db, $tbl) = @args{@required_args};
   my $q      = $self->{Quoter} || 'Quoter';
   my $db_tbl = $q->quote($db, $tbl);
   PTDEBUG && _d('Checking', $db_tbl);

   $self->{check_table_error} = undef;

   my $sql = "SHOW TABLES FROM " . $q->quote($db)
           . ' LIKE ' . $q->literal_like($tbl);
   PTDEBUG && _d($sql);
   my $row;
   eval {
      $row = $dbh->selectrow_arrayref($sql);
   };
   if ( my $e = $EVAL_ERROR ) {
      PTDEBUG && _d($e);
      $self->{check_table_error} = $e;
      return 0;
   }
   if ( !$row->[0] || $row->[0] ne $tbl ) {
      PTDEBUG && _d('Table does not exist');
      return 0;
   }

   PTDEBUG && _d('Table', $db, $tbl, 'exists');
   return 1;

}

sub get_engine {
   my ( $self, $ddl, $opts ) = @_;
   my ( $engine ) = $ddl =~ m/\).*?(?:ENGINE|TYPE)=(\w+)/;
   PTDEBUG && _d('Storage engine:', $engine);
   return $engine || undef;
}

sub get_keys {
   my ( $self, $ddl, $opts, $is_nullable ) = @_;
   my $engine        = $self->get_engine($ddl);
   my $keys          = {};
   my $clustered_key = undef;

   KEY:
   foreach my $key ( $ddl =~ m/^  ((?:[A-Z]+ )?KEY .*)$/gm ) {

      next KEY if $key =~ m/FOREIGN/;

      my $key_ddl = $key;
      PTDEBUG && _d('Parsed key:', $key_ddl);

      if ( !$engine || $engine !~ m/MEMORY|HEAP/ ) {
         $key =~ s/USING HASH/USING BTREE/;
      }

      my ( $type, $cols ) = $key =~ m/(?:USING (\w+))? \((.+)\)/;
      my ( $special ) = $key =~ m/(FULLTEXT|SPATIAL)/;
      $type = $type || $special || 'BTREE';
      my ($name) = $key =~ m/(PRIMARY|`[^`]*`)/;
      my $unique = $key =~ m/PRIMARY|UNIQUE/ ? 1 : 0;
      my @cols;
      my @col_prefixes;
      foreach my $col_def ( $cols =~ m/`[^`]+`(?:\(\d+\))?/g ) {
         my ($name, $prefix) = $col_def =~ m/`([^`]+)`(?:\((\d+)\))?/;
         push @cols, $name;
         push @col_prefixes, $prefix;
      }
      $name =~ s/`//g;

      PTDEBUG && _d( $name, 'key cols:', join(', ', map { "`$_`" } @cols));

      $keys->{$name} = {
         name         => $name,
         type         => $type,
         colnames     => $cols,
         cols         => \@cols,
         col_prefixes => \@col_prefixes,
         is_unique    => $unique,
         is_nullable  => scalar(grep { $is_nullable->{$_} } @cols),
         is_col       => { map { $_ => 1 } @cols },
         ddl          => $key_ddl,
      };

      if ( ($engine || '') =~ m/InnoDB/i && !$clustered_key ) {
         my $this_key = $keys->{$name};
         if ( $this_key->{name} eq 'PRIMARY' ) {
            $clustered_key = 'PRIMARY';
         }
         elsif ( $this_key->{is_unique} && !$this_key->{is_nullable} ) {
            $clustered_key = $this_key->{name};
         }
         PTDEBUG && $clustered_key && _d('This key is the clustered key');
      }
   }

   return $keys, $clustered_key;
}

sub get_fks {
   my ( $self, $ddl, $opts ) = @_;
   my $q   = $self->{Quoter};
   my $fks = {};

   foreach my $fk (
      $ddl =~ m/CONSTRAINT .* FOREIGN KEY .* REFERENCES [^\)]*\)/mg )
   {
      my ( $name ) = $fk =~ m/CONSTRAINT `(.*?)`/;
      my ( $cols ) = $fk =~ m/FOREIGN KEY \(([^\)]+)\)/;
      my ( $parent, $parent_cols ) = $fk =~ m/REFERENCES (\S+) \(([^\)]+)\)/;

      my ($db, $tbl) = $q->split_unquote($parent, $opts->{database});
      my %parent_tbl = (tbl => $tbl);
      $parent_tbl{db} = $db if $db;

      if ( $parent !~ m/\./ && $opts->{database} ) {
         $parent = $q->quote($opts->{database}) . ".$parent";
      }

      $fks->{$name} = {
         name           => $name,
         colnames       => $cols,
         cols           => [ map { s/[ `]+//g; $_; } split(',', $cols) ],
         parent_tbl     => \%parent_tbl,
         parent_tblname => $parent,
         parent_cols    => [ map { s/[ `]+//g; $_; } split(',', $parent_cols) ],
         parent_colnames=> $parent_cols,
         ddl            => $fk,
      };
   }

   return $fks;
}

sub remove_auto_increment {
   my ( $self, $ddl ) = @_;
   $ddl =~ s/(^\).*?) AUTO_INCREMENT=\d+\b/$1/m;
   return $ddl;
}

sub get_table_status {
   my ( $self, $dbh, $db, $like ) = @_;
   my $q = $self->{Quoter};
   my $sql = "SHOW TABLE STATUS FROM " . $q->quote($db);
   my @params;
   if ( $like ) {
      $sql .= ' LIKE ?';
      push @params, $like;
   }
   PTDEBUG && _d($sql, @params);
   my $sth = $dbh->prepare($sql);
   eval { $sth->execute(@params); };
   if ($EVAL_ERROR) {
      PTDEBUG && _d($EVAL_ERROR);
      return;
   }
   my @tables = @{$sth->fetchall_arrayref({})};
   @tables = map {
      my %tbl; # Make a copy with lowercased keys
      @tbl{ map { lc $_ } keys %$_ } = values %$_;
      $tbl{engine} ||= $tbl{type} || $tbl{comment};
      delete $tbl{type};
      \%tbl;
   } @tables;
   return @tables;
}

my $ansi_quote_re = qr/" [^"]* (?: "" [^"]* )* (?<=.) "/ismx;
sub ansi_to_legacy {
   my ($self, $ddl) = @_;
   $ddl =~ s/($ansi_quote_re)/ansi_quote_replace($1)/ge;
   return $ddl;
}

sub ansi_quote_replace {
   my ($val) = @_;
   $val =~ s/^"|"$//g;
   $val =~ s/`/``/g;
   $val =~ s/""/"/g;
   return "`$val`";
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
# End TableParser package
# ###########################################################################

# ###########################################################################
# Processlist package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Processlist.pm
#   t/lib/Processlist.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Processlist;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Time::HiRes qw(time usleep);
use List::Util qw(max);
use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

use constant PTDEBUG => $ENV{PTDEBUG} || 0;
use constant {
   ID      => 0,  
   USER    => 1,  
   HOST    => 2,
   DB      => 3,
   COMMAND => 4,
   TIME    => 5,
   STATE   => 6,
   INFO    => 7,
   START   => 8,  # Calculated start time of statement ($start - TIME)
   ETIME   => 9,  # Exec time of SHOW PROCESSLIST (margin of error in START)
   FSEEN   => 10, # First time ever seen
   PROFILE => 11, # Profile of individual STATE times
};


sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(MasterSlave) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $kill_busy_commands = {};
   if ($args{kill_busy_commands}) {
       for my $command (split /,/,$args{kill_busy_commands}) {
           $command =~ s/^\s+|\s+$//g;
           $kill_busy_commands->{$command} = 1;
       }
   } else {
       $kill_busy_commands->{Query} = 1;
   }
   $args{kill_busy_commands} = $kill_busy_commands;

   my $self = {
      %args,
      polls       => 0,
      last_poll   => 0,
      active_cxn  => {},  # keyed off ID
      event_cache => [],
      _reasons_for_matching => {},
   };
   return bless $self, $class;
}

sub parse_event {
   my ( $self, %args ) = @_;
   my @required_args = qw(code);
   foreach my $arg ( @required_args ) {
     die "I need a $arg argument" unless $args{$arg};
   }
   my ($code) = @args{@required_args};

   if ( @{$self->{event_cache}} ) {
      PTDEBUG && _d("Returning cached event");
      return shift @{$self->{event_cache}};
   }

   if ( $self->{interval} && $self->{polls} ) {
      PTDEBUG && _d("Sleeping between polls");
      usleep($self->{interval});
   }

   PTDEBUG && _d("Polling PROCESSLIST");
   my ($time, $etime) = @args{qw(time etime)};
   my $start          = $etime ? 0 : time;  # don't need start if etime given
   my $rows           = $code->();
   if ( !$rows ) {
      warn "Processlist callback did not return an arrayref";
      return;
   }
   $time  = time           unless $time;
   $etime = $time - $start unless $etime;
   $self->{polls}++;
   PTDEBUG && _d('Rows:', ($rows ? scalar @$rows : 0), 'in', $etime, 'seconds');

   my $active_cxn = $self->{active_cxn};
   my $curr_cxn   = {};
   my @new_cxn    = ();

   CURRENTLY_ACTIVE_CXN:
   foreach my $curr ( @$rows ) {

      $curr_cxn->{$curr->[ID]} = $curr;

      my $query_start = $time - ($curr->[TIME] || 0);

      if ( $active_cxn->{$curr->[ID]} ) {
         PTDEBUG && _d('Checking existing cxn', $curr->[ID]);
         my $prev      = $active_cxn->{$curr->[ID]}; # previous state of cxn
         my $new_query = 0;
         my $fudge     = ($curr->[TIME] || 0) =~ m/\D/ ? 0.001 : 1; # micro-t?

         if ( $prev->[INFO] ) {
            if ( !$curr->[INFO] || $prev->[INFO] ne $curr->[INFO] ) {
               PTDEBUG && _d('Info is different; new query');
               $new_query = 1;
            }
            elsif ( defined $curr->[TIME] && $curr->[TIME] < $prev->[TIME] ) {
               PTDEBUG && _d('Time is less than previous; new query');
               $new_query = 1;
            }
            elsif ( $curr->[INFO] && defined $curr->[TIME]
                    && $query_start - $etime - $prev->[START] > $fudge)
            {
               my $ms = $self->{MasterSlave};
               
               my $is_repl_thread = $ms->is_replication_thread({
                                        Command => $curr->[COMMAND],
                                        User    => $curr->[USER],
                                        State   => $curr->[STATE],
                                        Id      => $curr->[ID]});
               if ( $is_repl_thread ) {
                  PTDEBUG &&
                  _d(q{Query has restarted but it's a replication thread, ignoring});
               }
               else {
                  PTDEBUG && _d('Query restarted; new query',
                     $query_start, $etime, $prev->[START], $fudge);
                  $new_query = 1;
               }
            }

            if ( $new_query ) {
               $self->_update_profile($prev, $curr, $time);
               push @{$self->{event_cache}},
                  $self->make_event($prev, $time);
            }
         }

         if ( $curr->[INFO] ) {
            if ( $prev->[INFO] && !$new_query ) {
               PTDEBUG && _d("Query on cxn", $curr->[ID], "hasn't changed");
               $self->_update_profile($prev, $curr, $time);
            }
            else {
               PTDEBUG && _d('Saving new query, state', $curr->[STATE]);
               push @new_cxn, [
                  @{$curr}[0..7],           # proc info
                  int($query_start),        # START
                  $etime,                   # ETIME
                  $time,                    # FSEEN
                  { ($curr->[STATE] || "") => 0 }, # PROFILE
               ];
            }
         }
      } 
      else {
         PTDEBUG && _d('New cxn', $curr->[ID]);
         if ( $curr->[INFO] && defined $curr->[TIME] ) {
            PTDEBUG && _d('Saving query of new cxn, state', $curr->[STATE]);
            push @new_cxn, [
               @{$curr}[0..7],           # proc info
               int($query_start),        # START
               $etime,                   # ETIME
               $time,                    # FSEEN
               { ($curr->[STATE] || "") => 0 }, # PROFILE
            ];
         }
      }
   }  # CURRENTLY_ACTIVE_CXN

   PREVIOUSLY_ACTIVE_CXN:
   foreach my $prev ( values %$active_cxn ) {
      if ( !$curr_cxn->{$prev->[ID]} ) {
         PTDEBUG && _d('cxn', $prev->[ID], 'ended');
         push @{$self->{event_cache}},
            $self->make_event($prev, $time);
         delete $active_cxn->{$prev->[ID]};
      }
      elsif (   ($curr_cxn->{$prev->[ID]}->[COMMAND] || "") eq 'Sleep' 
             || !$curr_cxn->{$prev->[ID]}->[STATE]
             || !$curr_cxn->{$prev->[ID]}->[INFO] ) {
         PTDEBUG && _d('cxn', $prev->[ID], 'became idle');
         delete $active_cxn->{$prev->[ID]};
      }
   }

   map { $active_cxn->{$_->[ID]} = $_; } @new_cxn;

   $self->{last_poll} = $time;

   my $event = shift @{$self->{event_cache}};
   PTDEBUG && _d(scalar @{$self->{event_cache}}, "events in cache");
   return $event;
}

sub make_event {
   my ( $self, $row, $time ) = @_;

   my $observed_time = $time - $row->[FSEEN];
   my $Query_time    = max($row->[TIME], $observed_time);




   my $event = {
      id         => $row->[ID],
      db         => $row->[DB],
      user       => $row->[USER],
      host       => $row->[HOST],
      arg        => $row->[INFO],
      bytes      => length($row->[INFO]),
      ts         => Transformers::ts($row->[START] + $row->[TIME]), # Query END time
      Query_time => $Query_time,
      Lock_time  => $row->[PROFILE]->{Locked} || 0,
   };
   PTDEBUG && _d('Properties of event:', Dumper($event));
   return $event;
}

sub _get_active_cxn {
   my ( $self ) = @_;
   PTDEBUG && _d("Active cxn:", Dumper($self->{active_cxn}));
   return $self->{active_cxn};
}

sub _update_profile {
   my ( $self, $prev, $curr, $time ) = @_;
   return unless $prev && $curr;

   my $time_elapsed = $time - $self->{last_poll};


   if ( ($prev->[STATE] || "") eq ($curr->[STATE] || "") ) {
      PTDEBUG && _d("Query is still in", $curr->[STATE], "state");
      $prev->[PROFILE]->{$prev->[STATE] || ""} += $time_elapsed;
   }
   else {
      PTDEBUG && _d("Query changed from state", $prev->[STATE],
         "to", $curr->[STATE]);
      my $half_time = ($time_elapsed || 0) / 2;

      $prev->[PROFILE]->{$prev->[STATE] || ""} += $half_time;

      $prev->[STATE] = $curr->[STATE];
      $prev->[PROFILE]->{$curr->[STATE] || ""}  = $half_time;
   }

   return;
}

sub find {
   my ( $self, $proclist, %find_spec ) = @_;
   PTDEBUG && _d('find specs:', Dumper(\%find_spec));
   my $ms  = $self->{MasterSlave};

   my @matches;
   $self->{_reasons_for_matching} = undef;
   QUERY:
   foreach my $query ( @$proclist ) {
      PTDEBUG && _d('Checking query', Dumper($query));
      my $matched = 0;

      if ( !$find_spec{replication_threads}
           && $ms->is_replication_thread($query) ) {
         PTDEBUG && _d('Skipping replication thread');
         next QUERY;
      }

      if ( $find_spec{busy_time} && exists($self->{kill_busy_commands}->{$query->{Command} || ''}) ) {
         next QUERY unless defined($query->{Time});
         if ( $query->{Time} < $find_spec{busy_time} ) {
            PTDEBUG && _d("Query isn't running long enough");
            next QUERY;
         }
         my $reason = 'Exceeds busy time';
         PTDEBUG && _d($reason);
         push @{$self->{_reasons_for_matching}->{$query} ||= []}, $reason;
         $matched++;
      }

      if ( $find_spec{idle_time} && ($query->{Command} || '') eq 'Sleep' ) {
         next QUERY unless defined($query->{Time});
         if ( $query->{Time} < $find_spec{idle_time} ) {
            PTDEBUG && _d("Query isn't idle long enough");
            next QUERY;
         }
         my $reason = 'Exceeds idle time';
         PTDEBUG && _d($reason);
         push @{$self->{_reasons_for_matching}->{$query} ||= []}, $reason;
         $matched++;
      }
 
      PROPERTY:
      foreach my $property ( qw(Id User Host db State Command Info) ) {
         my $filter = "_find_match_$property";
         if ( defined $find_spec{ignore}->{$property}
              && $self->$filter($query, $find_spec{ignore}->{$property}) ) {
            PTDEBUG && _d('Query matches ignore', $property, 'spec');
            next QUERY;
         }
         if ( defined $find_spec{match}->{$property} ) {
            if ( !$self->$filter($query, $find_spec{match}->{$property}) ) {
               PTDEBUG && _d('Query does not match', $property, 'spec');
               next QUERY;
            }
            my $reason = 'Query matches ' . $property . ' spec';
            PTDEBUG && _d($reason);
            push @{$self->{_reasons_for_matching}->{$query} ||= []}, $reason;
            $matched++;
         }
      }
      if ( $matched || $find_spec{all} ) {
         PTDEBUG && _d("Query matched one or more specs, adding");
         push @matches, $query;
         next QUERY;
      }
      PTDEBUG && _d('Query does not match any specs, ignoring');
   } # QUERY

   return @matches;
}

sub _find_match_Id {
   my ( $self, $query, $property ) = @_;
   return defined $property && defined $query->{Id} && $query->{Id} == $property;
}

sub _find_match_User {
   my ( $self, $query, $property ) = @_;
   return defined $property && defined $query->{User}
      && $query->{User} =~ m/$property/;
}

sub _find_match_Host {
   my ( $self, $query, $property ) = @_;
   return defined $property && defined $query->{Host}
      && $query->{Host} =~ m/$property/;
}

sub _find_match_db {
   my ( $self, $query, $property ) = @_;
   return defined $property && defined $query->{db}
      && $query->{db} =~ m/$property/;
}

sub _find_match_State {
   my ( $self, $query, $property ) = @_;
   return defined $property && defined $query->{State}
      && $query->{State} =~ m/$property/;
}

sub _find_match_Command {
   my ( $self, $query, $property ) = @_;
   return defined $property && defined $query->{Command}
      && $query->{Command} =~ m/$property/;
}

sub _find_match_Info {
   my ( $self, $query, $property ) = @_;
   return defined $property && defined $query->{Info}
      && $query->{Info} =~ m/$property/;
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
# End Processlist package
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
# MasterSlave package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/MasterSlave.pm
#   t/lib/MasterSlave.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package MasterSlave;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub check_recursion_method {                                                       
   my ($methods) = @_;
   if ( @$methods != 1 ) {                                                         
      if ( grep({ !m/processlist|hosts/i } @$methods)                              
            && $methods->[0] !~ /^dsn=/i ) 
      {     
         die  "Invalid combination of recursion methods: "                         
            . join(", ", map { defined($_) ? $_ : 'undef' } @$methods) . ". "      
            . "Only hosts and processlist may be combined.\n"                      
      }                                                                            
   }     
   else {   
      my ($method) = @$methods;
      die "Invalid recursion method: " . ( $method || 'undef' )                    
         unless $method && $method =~ m/^(?:processlist$|hosts$|none$|cluster$|dsn=)/i;     
   }                                                                               
}

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw(OptionParser DSNParser Quoter);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $self = {
      %args,
      replication_thread => {},
   };
   return bless $self, $class;
}

sub get_slaves {
   my ($self, %args) = @_;
   my @required_args = qw(make_cxn);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($make_cxn) = @args{@required_args};

   my $slaves  = [];
   my $dp      = $self->{DSNParser};
   my $methods = $self->_resolve_recursion_methods($args{dsn});

   return $slaves unless @$methods;
   
   if ( grep { m/processlist|hosts/i } @$methods ) {
      my @required_args = qw(dbh dsn);
      foreach my $arg ( @required_args ) {
         die "I need a $arg argument" unless $args{$arg};
      }
      my ($dbh, $dsn) = @args{@required_args};
      my $o = $self->{OptionParser};

      $self->recurse_to_slaves(
         {  dbh            => $dbh,
            dsn            => $dsn,
            slave_user     => $o->got('slave-user') ? $o->get('slave-user') : '',
            slave_password => $o->got('slave-password') ? $o->get('slave-password') : '', 
            callback  => sub {
               my ( $dsn, $dbh, $level, $parent ) = @_;
               return unless $level;
               PTDEBUG && _d('Found slave:', $dp->as_string($dsn));
               my $slave_dsn = $dsn;
               if ($o->got('slave-user')) {
                  $slave_dsn->{u} = $o->get('slave-user');
                  PTDEBUG && _d("Using slave user ".$o->get('slave-user')." on ".$slave_dsn->{h}.":".$slave_dsn->{P});
               }
               if ($o->got('slave-password')) {
                  $slave_dsn->{p} = $o->get('slave-password');
                  PTDEBUG && _d("Slave password set");
               }
               push @$slaves, $make_cxn->(dsn => $slave_dsn, dbh => $dbh);
               return;
            },
         }
      );
   } elsif ( $methods->[0] =~ m/^dsn=/i ) {
      (my $dsn_table_dsn = join ",", @$methods) =~ s/^dsn=//i;
      $slaves = $self->get_cxn_from_dsn_table(
         %args,
         dsn_table_dsn => $dsn_table_dsn,
      );
   }
   elsif ( $methods->[0] =~ m/none/i ) {
      PTDEBUG && _d('Not getting to slaves');
   }
   else {
      die "Unexpected recursion methods: @$methods";
   }
   
   return $slaves;
}

sub _resolve_recursion_methods {
   my ($self, $dsn) = @_;
   my $o = $self->{OptionParser};
   if ( $o->got('recursion-method') ) {
      return $o->get('recursion-method');
   }
   elsif ( $dsn && ($dsn->{P} || 3306) != 3306 ) {
      PTDEBUG && _d('Port number is non-standard; using only hosts method');
      return [qw(hosts)];
   }
   else {
      return $o->get('recursion-method');
   }
}

sub recurse_to_slaves {
   my ( $self, $args, $level ) = @_;
   $level ||= 0;
   my $dp = $self->{DSNParser};
   my $recurse = $args->{recurse} || $self->{OptionParser}->get('recurse');
   my $dsn = $args->{dsn};
   my $slave_user = $args->{slave_user} || '';
   my $slave_password = $args->{slave_password} || '';

   my $methods = $self->_resolve_recursion_methods($dsn);
   PTDEBUG && _d('Recursion methods:', @$methods);
   if ( lc($methods->[0]) eq 'none' ) {
      PTDEBUG && _d('Not recursing to slaves');
      return;
   }

   my $slave_dsn = $dsn;
   if ($slave_user) {
      $slave_dsn->{u} = $slave_user;
      PTDEBUG && _d("Using slave user $slave_user on ".$slave_dsn->{h}.":".$slave_dsn->{P});
   }
   if ($slave_password) {
      $slave_dsn->{p} = $slave_password;
      PTDEBUG && _d("Slave password set");
   }

   my $dbh;
   eval {
      $dbh = $args->{dbh} || $dp->get_dbh(
         $dp->get_cxn_params($slave_dsn), { AutoCommit => 1 });
      PTDEBUG && _d('Connected to', $dp->as_string($slave_dsn));
   };
   if ( $EVAL_ERROR ) {
      print STDERR "Cannot connect to ", $dp->as_string($slave_dsn), "\n"
         or die "Cannot print: $OS_ERROR";
      return;
   }

   my $sql  = 'SELECT @@SERVER_ID';
   PTDEBUG && _d($sql);
   my ($id) = $dbh->selectrow_array($sql);
   PTDEBUG && _d('Working on server ID', $id);
   my $master_thinks_i_am = $dsn->{server_id};
   if ( !defined $id
       || ( defined $master_thinks_i_am && $master_thinks_i_am != $id )
       || $args->{server_ids_seen}->{$id}++
   ) {
      PTDEBUG && _d('Server ID seen, or not what master said');
      if ( $args->{skip_callback} ) {
         $args->{skip_callback}->($dsn, $dbh, $level, $args->{parent});
      }
      return;
   }

   $args->{callback}->($dsn, $dbh, $level, $args->{parent});

   if ( !defined $recurse || $level < $recurse ) {

      my @slaves =
         grep { !$_->{master_id} || $_->{master_id} == $id } # Only my slaves.
         $self->find_slave_hosts($dp, $dbh, $dsn, $methods);

      foreach my $slave ( @slaves ) {
         PTDEBUG && _d('Recursing from',
            $dp->as_string($dsn), 'to', $dp->as_string($slave));
         $self->recurse_to_slaves(
            { %$args, dsn => $slave, dbh => undef, parent => $dsn, slave_user => $slave_user, $slave_password => $slave_password }, $level + 1 );
      }
   }
}

sub find_slave_hosts {
   my ( $self, $dsn_parser, $dbh, $dsn, $methods ) = @_;

   PTDEBUG && _d('Looking for slaves on', $dsn_parser->as_string($dsn),
      'using methods', @$methods);

   my @slaves;
   METHOD:
   foreach my $method ( @$methods ) {
      my $find_slaves = "_find_slaves_by_$method";
      PTDEBUG && _d('Finding slaves with', $find_slaves);
      @slaves = $self->$find_slaves($dsn_parser, $dbh, $dsn);
      last METHOD if @slaves;
   }

   PTDEBUG && _d('Found', scalar(@slaves), 'slaves');
   return @slaves;
}

sub _find_slaves_by_processlist {
   my ( $self, $dsn_parser, $dbh, $dsn ) = @_;
   my @connected_slaves = $self->get_connected_slaves($dbh);
   my @slaves = $self->_process_slaves_list($dsn_parser, $dsn, \@connected_slaves);
   return @slaves;
}

sub _process_slaves_list {
   my ($self, $dsn_parser, $dsn, $connected_slaves) = @_;
   my @slaves = map  {
      my $slave        = $dsn_parser->parse("h=$_", $dsn);
      $slave->{source} = 'processlist';
      $slave;
   }
   grep { $_ }
   map  {
      my ( $host ) = $_->{host} =~ m/^(.*):\d+$/;
      if ( $host eq 'localhost' ) {
         $host = '127.0.0.1'; # Replication never uses sockets.
      }
      if ($host =~ m/::/) {
          $host = '['.$host.']';
      }
      $host;
   } @$connected_slaves;

   return @slaves;
}

sub _find_slaves_by_hosts {
   my ( $self, $dsn_parser, $dbh, $dsn ) = @_;

   my @slaves;
   my $sql = 'SHOW SLAVE HOSTS';
   PTDEBUG && _d($dbh, $sql);
   @slaves = @{$dbh->selectall_arrayref($sql, { Slice => {} })};

   if ( @slaves ) {
      PTDEBUG && _d('Found some SHOW SLAVE HOSTS info');
      @slaves = map {
         my %hash;
         @hash{ map { lc $_ } keys %$_ } = values %$_;
         my $spec = "h=$hash{host},P=$hash{port}"
            . ( $hash{user} ? ",u=$hash{user}" : '')
            . ( $hash{password} ? ",p=$hash{password}" : '');
         my $dsn           = $dsn_parser->parse($spec, $dsn);
         $dsn->{server_id} = $hash{server_id};
         $dsn->{master_id} = $hash{master_id};
         $dsn->{source}    = 'hosts';
         $dsn;
      } @slaves;
   }

   return @slaves;
}

sub get_connected_slaves {
   my ( $self, $dbh ) = @_;

   my $show = "SHOW GRANTS FOR ";
   my $user = 'CURRENT_USER()';
   my $sql = $show . $user;
   PTDEBUG && _d($dbh, $sql);

   my $proc;
   eval {
      $proc = grep {
         m/ALL PRIVILEGES.*?\*\.\*|PROCESS/
      } @{$dbh->selectcol_arrayref($sql)};
   };
   if ( $EVAL_ERROR ) {

      if ( $EVAL_ERROR =~ m/no such grant defined for user/ ) {
         PTDEBUG && _d('Retrying SHOW GRANTS without host; error:',
            $EVAL_ERROR);
         ($user) = split('@', $user);
         $sql    = $show . $user;
         PTDEBUG && _d($sql);
         eval {
            $proc = grep {
               m/ALL PRIVILEGES.*?\*\.\*|PROCESS/
            } @{$dbh->selectcol_arrayref($sql)};
         };
      }

      die "Failed to $sql: $EVAL_ERROR" if $EVAL_ERROR;
   }
   if ( !$proc ) {
      die "You do not have the PROCESS privilege";
   }

   $sql = 'SHOW FULL PROCESSLIST';
   PTDEBUG && _d($dbh, $sql);
   grep { $_->{command} =~ m/Binlog Dump/i }
   map  { # Lowercase the column names
      my %hash;
      @hash{ map { lc $_ } keys %$_ } = values %$_;
      \%hash;
   }
   @{$dbh->selectall_arrayref($sql, { Slice => {} })};
}

sub is_master_of {
   my ( $self, $master, $slave ) = @_;
   my $master_status = $self->get_master_status($master)
      or die "The server specified as a master is not a master";
   my $slave_status  = $self->get_slave_status($slave)
      or die "The server specified as a slave is not a slave";
   my @connected     = $self->get_connected_slaves($master)
      or die "The server specified as a master has no connected slaves";
   my (undef, $port) = $master->selectrow_array("SHOW VARIABLES LIKE 'port'");

   if ( $port != $slave_status->{master_port} ) {
      die "The slave is connected to $slave_status->{master_port} "
         . "but the master's port is $port";
   }

   if ( !grep { $slave_status->{master_user} eq $_->{user} } @connected ) {
      die "I don't see any slave I/O thread connected with user "
         . $slave_status->{master_user};
   }

   if ( ($slave_status->{slave_io_state} || '')
      eq 'Waiting for master to send event' )
   {
      my ( $master_log_name, $master_log_num )
         = $master_status->{file} =~ m/^(.*?)\.0*([1-9][0-9]*)$/;
      my ( $slave_log_name, $slave_log_num )
         = $slave_status->{master_log_file} =~ m/^(.*?)\.0*([1-9][0-9]*)$/;
      if ( $master_log_name ne $slave_log_name
         || abs($master_log_num - $slave_log_num) > 1 )
      {
         die "The slave thinks it is reading from "
            . "$slave_status->{master_log_file},  but the "
            . "master is writing to $master_status->{file}";
      }
   }
   return 1;
}

sub get_master_dsn {
   my ( $self, $dbh, $dsn, $dsn_parser ) = @_;
   my $master = $self->get_slave_status($dbh) or return undef;
   my $spec   = "h=$master->{master_host},P=$master->{master_port}";
   return       $dsn_parser->parse($spec, $dsn);
}

sub get_slave_status {
   my ( $self, $dbh ) = @_;

   if ( !$self->{not_a_slave}->{$dbh} ) {
      my $sth = $self->{sths}->{$dbh}->{SLAVE_STATUS}
            ||= $dbh->prepare('SHOW SLAVE STATUS');
      PTDEBUG && _d($dbh, 'SHOW SLAVE STATUS');
      $sth->execute();
      my ($sss_rows) = $sth->fetchall_arrayref({}); # Show Slave Status rows

      my $ss;
      if ( $sss_rows && @$sss_rows ) {
          if (scalar @$sss_rows > 1) {
              if (!$self->{channel}) {
                  die 'This server returned more than one row for SHOW SLAVE STATUS but "channel" was not specified on the command line';
              }
              my $slave_use_channels;
              for my $row (@$sss_rows) {
                  $row = { map { lc($_) => $row->{$_} } keys %$row }; # lowercase the keys
                  if ($row->{channel_name}) {
                      $slave_use_channels = 1;
                  }
                  if ($row->{channel_name} eq $self->{channel}) {
                      $ss = $row;
                      last;
                  }
              }
              if (!$ss && $slave_use_channels) {
                 die 'This server is using replication channels but "channel" was not specified on the command line';
              }
          } else {
              if ($sss_rows->[0]->{channel_name} && $sss_rows->[0]->{channel_name} ne $self->{channel}) {
                  die 'This server is using replication channels but "channel" was not specified on the command line';
              } else {
                  $ss = $sss_rows->[0];
              }
          }

          if ( $ss && %$ss ) {
             $ss = { map { lc($_) => $ss->{$_} } keys %$ss }; # lowercase the keys
             return $ss;
          }
          if (!$ss && $self->{channel}) {
              die "Specified channel name is invalid";
          }
      }

      PTDEBUG && _d('This server returns nothing for SHOW SLAVE STATUS');
      $self->{not_a_slave}->{$dbh}++;
  }
}

sub get_master_status {
   my ( $self, $dbh ) = @_;

   if ( $self->{not_a_master}->{$dbh} ) {
      PTDEBUG && _d('Server on dbh', $dbh, 'is not a master');
      return;
   }

   my $sth = $self->{sths}->{$dbh}->{MASTER_STATUS}
         ||= $dbh->prepare('SHOW MASTER STATUS');
   PTDEBUG && _d($dbh, 'SHOW MASTER STATUS');
   $sth->execute();
   my ($ms) = @{$sth->fetchall_arrayref({})};
   PTDEBUG && _d(
      $ms ? map { "$_=" . (defined $ms->{$_} ? $ms->{$_} : '') } keys %$ms
          : '');

   if ( !$ms || scalar keys %$ms < 2 ) {
      PTDEBUG && _d('Server on dbh', $dbh, 'does not seem to be a master');
      $self->{not_a_master}->{$dbh}++;
   }

  return { map { lc($_) => $ms->{$_} } keys %$ms }; # lowercase the keys
}

sub wait_for_master {
   my ( $self, %args ) = @_;
   my @required_args = qw(master_status slave_dbh);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($master_status, $slave_dbh) = @args{@required_args};
   my $timeout       = $args{timeout} || 60;

   my $result;
   my $waited;
   if ( $master_status ) {
      my $slave_status;
      eval {
          $slave_status = $self->get_slave_status($slave_dbh);
      };
      if ($EVAL_ERROR) {
          return {
              result => undef,
              waited => 0,
              error  =>'Wait for master: this is a multi-master slave but "channel" was not specified on the command line',
          };
      }
      my $server_version = VersionParser->new($slave_dbh);
      my $channel_sql = $server_version > '5.6' && $self->{channel} ? ", '$self->{channel}'" : '';
      my $sql = "SELECT MASTER_POS_WAIT('$master_status->{file}', $master_status->{position}, $timeout $channel_sql)";
      PTDEBUG && _d($slave_dbh, $sql);
      my $start = time;
      ($result) = $slave_dbh->selectrow_array($sql);

      $waited = time - $start;

      PTDEBUG && _d('Result of waiting:', $result);
      PTDEBUG && _d("Waited", $waited, "seconds");
   }
   else {
      PTDEBUG && _d('Not waiting: this server is not a master');
   }

   return {
      result => $result,
      waited => $waited,
   };
}

sub stop_slave {
   my ( $self, $dbh ) = @_;
   my $sth = $self->{sths}->{$dbh}->{STOP_SLAVE}
         ||= $dbh->prepare('STOP SLAVE');
   PTDEBUG && _d($dbh, $sth->{Statement});
   $sth->execute();
}

sub start_slave {
   my ( $self, $dbh, $pos ) = @_;
   if ( $pos ) {
      my $sql = "START SLAVE UNTIL MASTER_LOG_FILE='$pos->{file}', "
              . "MASTER_LOG_POS=$pos->{position}";
      PTDEBUG && _d($dbh, $sql);
      $dbh->do($sql);
   }
   else {
      my $sth = $self->{sths}->{$dbh}->{START_SLAVE}
            ||= $dbh->prepare('START SLAVE');
      PTDEBUG && _d($dbh, $sth->{Statement});
      $sth->execute();
   }
}

sub catchup_to_master {
   my ( $self, $slave, $master, $timeout ) = @_;
   $self->stop_slave($master);
   $self->stop_slave($slave);
   my $slave_status  = $self->get_slave_status($slave);
   my $slave_pos     = $self->repl_posn($slave_status);
   my $master_status = $self->get_master_status($master);
   my $master_pos    = $self->repl_posn($master_status);
   PTDEBUG && _d('Master position:', $self->pos_to_string($master_pos),
      'Slave position:', $self->pos_to_string($slave_pos));

   my $result;
   if ( $self->pos_cmp($slave_pos, $master_pos) < 0 ) {
      PTDEBUG && _d('Waiting for slave to catch up to master');
      $self->start_slave($slave, $master_pos);

      $result = $self->wait_for_master(
            master_status => $master_status,
            slave_dbh     => $slave,
            timeout       => $timeout,
            master_status => $master_status
      );
      if ($result->{error}) {
          die $result->{error};
      }
      if ( !defined $result->{result} ) {
         $slave_status = $self->get_slave_status($slave);
         if ( !$self->slave_is_running($slave_status) ) {
            PTDEBUG && _d('Master position:',
               $self->pos_to_string($master_pos),
               'Slave position:', $self->pos_to_string($slave_pos));
            $slave_pos = $self->repl_posn($slave_status);
            if ( $self->pos_cmp($slave_pos, $master_pos) != 0 ) {
               die "MASTER_POS_WAIT() returned NULL but slave has not "
                  . "caught up to master";
            }
            PTDEBUG && _d('Slave is caught up to master and stopped');
         }
         else {
            die "Slave has not caught up to master and it is still running";
         }
      }
   }
   else {
      PTDEBUG && _d("Slave is already caught up to master");
   }

   return $result;
}

sub catchup_to_same_pos {
   my ( $self, $s1_dbh, $s2_dbh ) = @_;
   $self->stop_slave($s1_dbh);
   $self->stop_slave($s2_dbh);
   my $s1_status = $self->get_slave_status($s1_dbh);
   my $s2_status = $self->get_slave_status($s2_dbh);
   my $s1_pos    = $self->repl_posn($s1_status);
   my $s2_pos    = $self->repl_posn($s2_status);
   if ( $self->pos_cmp($s1_pos, $s2_pos) < 0 ) {
      $self->start_slave($s1_dbh, $s2_pos);
   }
   elsif ( $self->pos_cmp($s2_pos, $s1_pos) < 0 ) {
      $self->start_slave($s2_dbh, $s1_pos);
   }

   $s1_status = $self->get_slave_status($s1_dbh);
   $s2_status = $self->get_slave_status($s2_dbh);
   $s1_pos    = $self->repl_posn($s1_status);
   $s2_pos    = $self->repl_posn($s2_status);

   if ( $self->slave_is_running($s1_status)
     || $self->slave_is_running($s2_status)
     || $self->pos_cmp($s1_pos, $s2_pos) != 0)
   {
      die "The servers aren't both stopped at the same position";
   }

}

sub slave_is_running {
   my ( $self, $slave_status ) = @_;
   return ($slave_status->{slave_sql_running} || 'No') eq 'Yes';
}

sub has_slave_updates {
   my ( $self, $dbh ) = @_;
   my $sql = q{SHOW VARIABLES LIKE 'log_slave_updates'};
   PTDEBUG && _d($dbh, $sql);
   my ($name, $value) = $dbh->selectrow_array($sql);
   return $value && $value =~ m/^(1|ON)$/;
}

sub repl_posn {
   my ( $self, $status ) = @_;
   if ( exists $status->{file} && exists $status->{position} ) {
      return {
         file     => $status->{file},
         position => $status->{position},
      };
   }
   else {
      return {
         file     => $status->{relay_master_log_file},
         position => $status->{exec_master_log_pos},
      };
   }
}

sub get_slave_lag {
   my ( $self, $dbh ) = @_;
   my $stat = $self->get_slave_status($dbh);
   return unless $stat;  # server is not a slave
   return $stat->{seconds_behind_master};
}

sub pos_cmp {
   my ( $self, $a, $b ) = @_;
   return $self->pos_to_string($a) cmp $self->pos_to_string($b);
}

sub short_host {
   my ( $self, $dsn ) = @_;
   my ($host, $port);
   if ( $dsn->{master_host} ) {
      $host = $dsn->{master_host};
      $port = $dsn->{master_port};
   }
   else {
      $host = $dsn->{h};
      $port = $dsn->{P};
   }
   return ($host || '[default]') . ( ($port || 3306) == 3306 ? '' : ":$port" );
}

sub is_replication_thread {
   my ( $self, $query, %args ) = @_; 
   return unless $query;

   my $type = lc($args{type} || 'all');
   die "Invalid type: $type"
      unless $type =~ m/^binlog_dump|slave_io|slave_sql|all$/i;

   my $match = 0;
   if ( $type =~ m/binlog_dump|all/i ) {
      $match = 1
         if ($query->{Command} || $query->{command} || '') eq "Binlog Dump";
   }
   if ( !$match ) {
      if ( ($query->{User} || $query->{user} || '') eq "system user" ) {
         PTDEBUG && _d("Slave replication thread");
         if ( $type ne 'all' ) { 
            my $state = $query->{State} || $query->{state} || '';

            if ( $state =~ m/^init|end$/ ) {
               PTDEBUG && _d("Special state:", $state);
               $match = 1;
            }
            else {
               my ($slave_sql) = $state =~ m/
                  ^(Waiting\sfor\sthe\snext\sevent
                   |Reading\sevent\sfrom\sthe\srelay\slog
                   |Has\sread\sall\srelay\slog;\swaiting
                   |Making\stemp\sfile
                   |Waiting\sfor\sslave\smutex\son\sexit)/xi; 

               $match = $type eq 'slave_sql' &&  $slave_sql ? 1
                      : $type eq 'slave_io'  && !$slave_sql ? 1
                      :                                       0;
            }
         }
         else {
            $match = 1;
         }
      }
      else {
         PTDEBUG && _d('Not system user');
      }

      if ( !defined $args{check_known_ids} || $args{check_known_ids} ) {
         my $id = $query->{Id} || $query->{id};
         if ( $match ) {
            $self->{replication_thread}->{$id} = 1;
         }
         else {
            if ( $self->{replication_thread}->{$id} ) {
               PTDEBUG && _d("Thread ID is a known replication thread ID");
               $match = 1;
            }
         }
      }
   }

   PTDEBUG && _d('Matches', $type, 'replication thread:',
      ($match ? 'yes' : 'no'), '; match:', $match);

   return $match;
}


sub get_replication_filters {
   my ( $self, %args ) = @_;
   my @required_args = qw(dbh);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dbh) = @args{@required_args};

   my %filters = ();

   my $status = $self->get_master_status($dbh);
   if ( $status ) {
      map { $filters{$_} = $status->{$_} }
      grep { defined $status->{$_} && $status->{$_} ne '' }
      qw(
         binlog_do_db
         binlog_ignore_db
      );
   }

   $status = $self->get_slave_status($dbh);
   if ( $status ) {
      map { $filters{$_} = $status->{$_} }
      grep { defined $status->{$_} && $status->{$_} ne '' }
      qw(
         replicate_do_db
         replicate_ignore_db
         replicate_do_table
         replicate_ignore_table 
         replicate_wild_do_table
         replicate_wild_ignore_table
      );

      my $sql = "SHOW VARIABLES LIKE 'slave_skip_errors'";
      PTDEBUG && _d($dbh, $sql);
      my $row = $dbh->selectrow_arrayref($sql);
      $filters{slave_skip_errors} = $row->[1] if $row->[1] && $row->[1] ne 'OFF';
   }

   return \%filters; 
}


sub pos_to_string {
   my ( $self, $pos ) = @_;
   my $fmt  = '%s/%020d';
   return sprintf($fmt, @{$pos}{qw(file position)});
}

sub reset_known_replication_threads {
   my ( $self ) = @_;
   $self->{replication_thread} = {};
   return;
}

sub get_cxn_from_dsn_table {
   my ($self, %args) = @_;
   my @required_args = qw(dsn_table_dsn make_cxn);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dsn_table_dsn, $make_cxn) = @args{@required_args};
   PTDEBUG && _d('DSN table DSN:', $dsn_table_dsn);

   my $dp = $self->{DSNParser};
   my $q  = $self->{Quoter};

   my $dsn = $dp->parse($dsn_table_dsn);
   my $dsn_table;
   if ( $dsn->{D} && $dsn->{t} ) {
      $dsn_table = $q->quote($dsn->{D}, $dsn->{t});
   }
   elsif ( $dsn->{t} && $dsn->{t} =~ m/\./ ) {
      $dsn_table = $q->quote($q->split_unquote($dsn->{t}));
   }
   else {
      die "DSN table DSN does not specify a database (D) "
        . "or a database-qualified table (t)";
   }

   my $dsn_tbl_cxn = $make_cxn->(dsn => $dsn);
   my $dbh         = $dsn_tbl_cxn->connect();
   my $sql         = "SELECT dsn FROM $dsn_table ORDER BY id";
   PTDEBUG && _d($sql);
   my $dsn_strings = $dbh->selectcol_arrayref($sql);
   my @cxn;
   if ( $dsn_strings ) {
      foreach my $dsn_string ( @$dsn_strings ) {
         PTDEBUG && _d('DSN from DSN table:', $dsn_string);
         push @cxn, $make_cxn->(dsn_string => $dsn_string);
      }
   }
   return \@cxn;
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
# End MasterSlave package
# ###########################################################################

# ###########################################################################
# Quoter package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Quoter.pm
#   t/lib/Quoter.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Quoter;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

sub new {
   my ( $class, %args ) = @_;
   return bless {}, $class;
}

sub quote {
   my ( $self, @vals ) = @_;
   foreach my $val ( @vals ) {
      $val =~ s/`/``/g;
   }
   return join('.', map { '`' . $_ . '`' } @vals);
}

sub quote_val {
   my ( $self, $val, %args ) = @_;

   return 'NULL' unless defined $val;          # undef = NULL
   return "''" if $val eq '';                  # blank string = ''
   return $val if $val =~ m/^0x[0-9a-fA-F]+$/  # quote hex data
                  && !$args{is_char};          # unless is_char is true

   $val =~ s/(['\\])/\\$1/g;
   return "'$val'";
}

sub split_unquote {
   my ( $self, $db_tbl, $default_db ) = @_;
   my ( $db, $tbl ) = split(/[.]/, $db_tbl);
   if ( !$tbl ) {
      $tbl = $db;
      $db  = $default_db;
   }
   for ($db, $tbl) {
      next unless $_;
      s/\A`//;
      s/`\z//;
      s/``/`/g;
   }
   
   return ($db, $tbl);
}

sub literal_like {
   my ( $self, $like ) = @_;
   return unless $like;
   $like =~ s/([%_])/\\$1/g;
   return "'$like'";
}

sub join_quote {
   my ( $self, $default_db, $db_tbl ) = @_;
   return unless $db_tbl;
   my ($db, $tbl) = split(/[.]/, $db_tbl);
   if ( !$tbl ) {
      $tbl = $db;
      $db  = $default_db;
   }
   $db  = "`$db`"  if $db  && $db  !~ m/^`/;
   $tbl = "`$tbl`" if $tbl && $tbl !~ m/^`/;
   return $db ? "$db.$tbl" : $tbl;
}

sub serialize_list {
   my ( $self, @args ) = @_;
   PTDEBUG && _d('Serializing', Dumper(\@args));
   return unless @args;

   my @parts;
   foreach my $arg  ( @args ) {
      if ( defined $arg ) {
         $arg =~ s/,/\\,/g;      # escape commas
         $arg =~ s/\\N/\\\\N/g;  # escape literal \N
         push @parts, $arg;
      }
      else {
         push @parts, '\N';
      }
   }

   my $string = join(',', @parts);
   PTDEBUG && _d('Serialized: <', $string, '>');
   return $string;
}

sub deserialize_list {
   my ( $self, $string ) = @_;
   PTDEBUG && _d('Deserializing <', $string, '>');
   die "Cannot deserialize an undefined string" unless defined $string;

   my @parts;
   foreach my $arg ( split(/(?<!\\),/, $string) ) {
      if ( $arg eq '\N' ) {
         $arg = undef;
      }
      else {
         $arg =~ s/\\,/,/g;
         $arg =~ s/\\\\N/\\N/g;
      }
      push @parts, $arg;
   }

   if ( !@parts ) {
      my $n_empty_strings = $string =~ tr/,//;
      $n_empty_strings++;
      PTDEBUG && _d($n_empty_strings, 'empty strings');
      map { push @parts, '' } 1..$n_empty_strings;
   }
   elsif ( $string =~ m/(?<!\\),$/ ) {
      PTDEBUG && _d('Last value is an empty string');
      push @parts, '';
   }

   PTDEBUG && _d('Deserialized', Dumper(\@parts));
   return @parts;
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
# End Quoter package
# ###########################################################################

# ###########################################################################
# QueryRewriter package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/QueryRewriter.pm
#   t/lib/QueryRewriter.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package QueryRewriter;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

our $verbs   = qr{^SHOW|^FLUSH|^COMMIT|^ROLLBACK|^BEGIN|SELECT|INSERT
                  |UPDATE|DELETE|REPLACE|^SET|UNION|^START|^LOCK}xi;
my $quote_re = qr/"(?:(?!(?<!\\)").)*"|'(?:(?!(?<!\\)').)*'/; # Costly!
my $bal;
$bal         = qr/
                  \(
                  (?:
                     (?> [^()]+ )    # Non-parens without backtracking
                     |
                     (??{ $bal })    # Group with matching parens
                  )*
                  \)
                 /x;

my $olc_re = qr/(?:--|#)[^'"\r\n]*(?=[\r\n]|\Z)/;  # One-line comments
my $mlc_re = qr#/\*[^!].*?\*/#sm;                  # But not /*!version */
my $vlc_re = qr#/\*.*?[0-9]+.*?\*/#sm;             # For SHOW + /*!version */
my $vlc_rf = qr#^(?:SHOW).*?/\*![0-9]+(.*?)\*/#sm;     # Variation for SHOW


sub new {
   my ( $class, %args ) = @_;
   my $self = { %args };
   return bless $self, $class;
}

sub strip_comments {
   my ( $self, $query ) = @_;
   return unless $query;
   $query =~ s/$mlc_re//go;
   $query =~ s/$olc_re//go;
   if ( $query =~ m/$vlc_rf/i ) { # contains show + version
      my $qualifier = $1 || '';
      $query =~ s/$vlc_re/$qualifier/go;
   }
   return $query;
}

sub shorten {
   my ( $self, $query, $length ) = @_;
   $query =~ s{
      \A(
         (?:INSERT|REPLACE)
         (?:\s+LOW_PRIORITY|DELAYED|HIGH_PRIORITY|IGNORE)?
         (?:\s\w+)*\s+\S+\s+VALUES\s*\(.*?\)
      )
      \s*,\s*\(.*?(ON\s+DUPLICATE|\Z)}
      {$1 /*... omitted ...*/$2}xsi;

   return $query unless $query =~ m/IN\s*\(\s*(?!select)/i;

   my $last_length  = 0;
   my $query_length = length($query);
   while (
      $length          > 0
      && $query_length > $length
      && $query_length < ( $last_length || $query_length + 1 )
   ) {
      $last_length = $query_length;
      $query =~ s{
         (\bIN\s*\()    # The opening of an IN list
         ([^\)]+)       # Contents of the list, assuming no item contains paren
         (?=\))           # Close of the list
      }
      {
         $1 . __shorten($2)
      }gexsi;
   }

   return $query;
}

sub __shorten {
   my ( $snippet ) = @_;
   my @vals = split(/,/, $snippet);
   return $snippet unless @vals > 20;
   my @keep = splice(@vals, 0, 20);  # Remove and save the first 20 items
   return
      join(',', @keep)
      . "/*... omitted "
      . scalar(@vals)
      . " items ...*/";
}

sub fingerprint {
   my ( $self, $query ) = @_;

   $query =~ m#\ASELECT /\*!40001 SQL_NO_CACHE \*/ \* FROM `# # mysqldump query
      && return 'mysqldump';
   $query =~ m#/\*\w+\.\w+:[0-9]/[0-9]\*/#     # pt-table-checksum, etc query
      && return 'percona-toolkit';
   $query =~ m/\Aadministrator command: /
      && return $query;
   $query =~ m/\A\s*(call\s+\S+)\(/i
      && return lc($1); # Warning! $1 used, be careful.
   if ( my ($beginning) = $query =~ m/\A((?:INSERT|REPLACE)(?: IGNORE)?\s+INTO.+?VALUES\s*\(.*?\))\s*,\s*\(/is ) {
      $query = $beginning; # Shorten multi-value INSERT statements ASAP
   }

   $query =~ s/$mlc_re//go;
   $query =~ s/$olc_re//go;
   $query =~ s/\Ause \S+\Z/use ?/i       # Abstract the DB in USE
      && return $query;

   $query =~ s/\\["']//g;                # quoted strings
   $query =~ s/".*?"/?/sg;               # quoted strings
   $query =~ s/'.*?'/?/sg;               # quoted strings

   $query =~ s/\bfalse\b|\btrue\b/?/isg; # boolean values 

   if ( $self->{match_md5_checksums} ) { 
      $query =~ s/([._-])[a-f0-9]{32}/$1?/g;
   }

   if ( !$self->{match_embedded_numbers} ) {
      $query =~ s/[0-9+-][0-9a-f.xb+-]*/?/g;
   }
   else {
      $query =~ s/\b[0-9+-][0-9a-f.xb+-]*/?/g;
   }

   if ( $self->{match_md5_checksums} ) {
      $query =~ s/[xb+-]\?/?/g;                
   }
   else {
      $query =~ s/[xb.+-]\?/?/g;
   }

   $query =~ s/\A\s+//;                  # Chop off leading whitespace
   chomp $query;                         # Kill trailing whitespace
   $query =~ tr[ \n\t\r\f][ ]s;          # Collapse whitespace
   $query = lc $query;
   $query =~ s/\bnull\b/?/g;             # Get rid of NULLs
   $query =~ s{                          # Collapse IN and VALUES lists
               \b(in|values?)(?:[\s,]*\([\s?,]*\))+
              }
              {$1(?+)}gx;
   $query =~ s{                          # Collapse UNION
               \b(select\s.*?)(?:(\sunion(?:\sall)?)\s\1)+
              }
              {$1 /*repeat$2*/}xg;
   $query =~ s/\blimit \?(?:, ?\?| offset \?)?/limit ?/; # LIMIT

   if ( $query =~ m/\bORDER BY /gi ) {  # Find, anchor on ORDER BY clause
      1 while $query =~ s/\G(.+?)\s+ASC/$1/gi && pos $query;
   }

   return $query;
}

sub distill_verbs {
   my ( $self, $query ) = @_;

   $query =~ m/\A\s*call\s+(\S+)\(/i && return "CALL $1";
   $query =~ m/\A\s*use\s+/          && return "USE";
   $query =~ m/\A\s*UNLOCK TABLES/i  && return "UNLOCK";
   $query =~ m/\A\s*xa\s+(\S+)/i     && return "XA_$1";

   if ( $query =~ m/\A\s*LOAD/i ) {
      my ($tbl) = $query =~ m/INTO TABLE\s+(\S+)/i;
      $tbl ||= '';
      $tbl =~ s/`//g;
      return "LOAD DATA $tbl";
   }

   if ( $query =~ m/\Aadministrator command:/ ) {
      $query =~ s/administrator command:/ADMIN/;
      $query = uc $query;
      return $query;
   }

   $query = $self->strip_comments($query);

   if ( $query =~ m/\A\s*SHOW\s+/i ) {
      PTDEBUG && _d($query);

      $query = uc $query;
      $query =~ s/\s+(?:SESSION|FULL|STORAGE|ENGINE)\b/ /g;
      $query =~ s/\s+COUNT[^)]+\)//g;

      $query =~ s/\s+(?:FOR|FROM|LIKE|WHERE|LIMIT|IN)\b.+//ms;

      $query =~ s/\A(SHOW(?:\s+\S+){1,2}).*\Z/$1/s;
      $query =~ s/\s+/ /g;
      PTDEBUG && _d($query);
      return $query;
   }

   eval $QueryParser::data_def_stmts;
   eval $QueryParser::tbl_ident;
   my ( $dds ) = $query =~ /^\s*($QueryParser::data_def_stmts)\b/i;
   if ( $dds) {
      $query =~ s/\s+IF(?:\s+NOT)?\s+EXISTS/ /i;
      my ( $obj ) = $query =~ m/$dds.+(DATABASE|TABLE)\b/i;
      $obj = uc $obj if $obj;
      PTDEBUG && _d('Data def statment:', $dds, 'obj:', $obj);
      my ($db_or_tbl)
         = $query =~ m/(?:TABLE|DATABASE)\s+($QueryParser::tbl_ident)(\s+.*)?/i;
      PTDEBUG && _d('Matches db or table:', $db_or_tbl);
      return uc($dds . ($obj ? " $obj" : '')), $db_or_tbl;
   }

   my @verbs = $query =~ m/\b($verbs)\b/gio;
   @verbs    = do {
      my $last = '';
      grep { my $pass = $_ ne $last; $last = $_; $pass } map { uc } @verbs;
   };

   if ( ($verbs[0] || '') eq 'SELECT' && @verbs > 1 ) {
      PTDEBUG && _d("False-positive verbs after SELECT:", @verbs[1..$#verbs]);
      my $union = grep { $_ eq 'UNION' } @verbs;
      @verbs    = $union ? qw(SELECT UNION) : qw(SELECT);
   }

   my $verb_str = join(q{ }, @verbs);
   return $verb_str;
}

sub __distill_tables {
   my ( $self, $query, $table, %args ) = @_;
   my $qp = $args{QueryParser} || $self->{QueryParser};
   die "I need a QueryParser argument" unless $qp;

   my @tables = map {
      $_ =~ s/`//g;
      $_ =~ s/(_?)[0-9]+/$1?/g;
      $_;
   } grep { defined $_ } $qp->get_tables($query);

   push @tables, $table if $table;

   @tables = do {
      my $last = '';
      grep { my $pass = $_ ne $last; $last = $_; $pass } @tables;
   };

   return @tables;
}

sub distill {
   my ( $self, $query, %args ) = @_;

   if ( $args{generic} ) {
      my ($cmd, $arg) = $query =~ m/^(\S+)\s+(\S+)/;
      return '' unless $cmd;
      $query = (uc $cmd) . ($arg ? " $arg" : '');
   }
   else {
      my ($verbs, $table)  = $self->distill_verbs($query, %args);

      if ( $verbs && $verbs =~ m/^SHOW/ ) {
         my %alias_for = qw(
            SCHEMA   DATABASE
            KEYS     INDEX
            INDEXES  INDEX
         );
         map { $verbs =~ s/$_/$alias_for{$_}/ } keys %alias_for;
         $query = $verbs;
      }
      elsif ( $verbs && $verbs =~ m/^LOAD DATA/ ) {
         return $verbs;
      }
      else {
         my @tables = $self->__distill_tables($query, $table, %args);
         $query     = join(q{ }, $verbs, @tables); 
      } 
   }

   if ( $args{trf} ) {
      $query = $args{trf}->($query, %args);
   }

   return $query;
}

sub convert_to_select {
   my ( $self, $query ) = @_;
   return unless $query;

   return if $query =~ m/=\s*\(\s*SELECT /i;

   $query =~ s{
                 \A.*?
                 update(?:\s+(?:low_priority|ignore))?\s+(.*?)
                 \s+set\b(.*?)
                 (?:\s*where\b(.*?))?
                 (limit\s*[0-9]+(?:\s*,\s*[0-9]+)?)?
                 \Z
              }
              {__update_to_select($1, $2, $3, $4)}exsi
      || $query =~ s{
                    \A.*?
                    (?:insert(?:\s+ignore)?|replace)\s+
                    .*?\binto\b(.*?)\(([^\)]+)\)\s*
                    values?\s*(\(.*?\))\s*
                    (?:\blimit\b|on\s+duplicate\s+key.*)?\s*
                    \Z
                 }
                 {__insert_to_select($1, $2, $3)}exsi
      || $query =~ s{
                    \A.*?
                    (?:insert(?:\s+ignore)?|replace)\s+
                    (?:.*?\binto)\b(.*?)\s*
                    set\s+(.*?)\s*
                    (?:\blimit\b|on\s+duplicate\s+key.*)?\s*
                    \Z
                 }
                 {__insert_to_select_with_set($1, $2)}exsi
      || $query =~ s{
                    \A.*?
                    delete\s+(.*?)
                    \bfrom\b(.*)
                    \Z
                 }
                 {__delete_to_select($1, $2)}exsi;
   $query =~ s/\s*on\s+duplicate\s+key\s+update.*\Z//si;
   $query =~ s/\A.*?(?=\bSELECT\s*\b)//ism;
   return $query;
}

sub convert_select_list {
   my ( $self, $query ) = @_;
   $query =~ s{
               \A\s*select(.*?)\bfrom\b
              }
              {$1 =~ m/\*/ ? "select 1 from" : "select isnull(coalesce($1)) from"}exi;
   return $query;
}

sub __delete_to_select {
   my ( $delete, $join ) = @_;
   if ( $join =~ m/\bjoin\b/ ) {
      return "select 1 from $join";
   }
   return "select * from $join";
}

sub __insert_to_select {
   my ( $tbl, $cols, $vals ) = @_;
   PTDEBUG && _d('Args:', @_);
   my @cols = split(/,/, $cols);
   PTDEBUG && _d('Cols:', @cols);
   $vals =~ s/^\(|\)$//g; # Strip leading/trailing parens
   my @vals = $vals =~ m/($quote_re|[^,]*${bal}[^,]*|[^,]+)/g;
   PTDEBUG && _d('Vals:', @vals);
   if ( @cols == @vals ) {
      return "select * from $tbl where "
         . join(' and ', map { "$cols[$_]=$vals[$_]" } (0..$#cols));
   }
   else {
      return "select * from $tbl limit 1";
   }
}

sub __insert_to_select_with_set {
   my ( $from, $set ) = @_;
   $set =~ s/,/ and /g;
   return "select * from $from where $set ";
}

sub __update_to_select {
   my ( $from, $set, $where, $limit ) = @_;
   return "select $set from $from "
      . ( $where ? "where $where" : '' )
      . ( $limit ? " $limit "      : '' );
}

sub wrap_in_derived {
   my ( $self, $query ) = @_;
   return unless $query;
   return $query =~ m/\A\s*select/i
      ? "select 1 from ($query) as x limit 1"
      : $query;
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
# End QueryRewriter package
# ###########################################################################

# ###########################################################################
# Retry package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Retry.pm
#   t/lib/Retry.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Retry;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Time::HiRes qw(sleep);

sub new {
   my ( $class, %args ) = @_;
   my $self = {
      %args,
   };
   return bless $self, $class;
}

sub retry {
   my ( $self, %args ) = @_;
   my @required_args = qw(try fail final_fail);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   };
   my ($try, $fail, $final_fail) = @args{@required_args};
   my $wait  = $args{wait}  || sub { sleep 1; };
   my $tries = $args{tries} || 3;

   my $last_error;
   my $tryno = 0;
   TRY:
   while ( ++$tryno <= $tries ) {
      PTDEBUG && _d("Try", $tryno, "of", $tries);
      my $result;
      eval {
         $result = $try->(tryno=>$tryno);
      };
      if ( $EVAL_ERROR ) {
         PTDEBUG && _d("Try code failed:", $EVAL_ERROR);
         $last_error = $EVAL_ERROR;

         if ( $tryno < $tries ) {   # more retries
            my $retry = $fail->(tryno=>$tryno, error=>$last_error);
            last TRY unless $retry;
            PTDEBUG && _d("Calling wait code");
            $wait->(tryno=>$tryno);
         }
      }
      else {
         PTDEBUG && _d("Try code succeeded");
         return $result;
      }
   }

   PTDEBUG && _d('Try code did not succeed');
   return $final_fail->(error=>$last_error);
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
# End Retry package
# ###########################################################################

# ###########################################################################
# Cxn package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Cxn.pm
#   t/lib/Cxn.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Cxn;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Scalar::Util qw(blessed);
use constant {
   PTDEBUG => $ENV{PTDEBUG} || 0,
   PERCONA_TOOLKIT_TEST_USE_DSN_NAMES => $ENV{PERCONA_TOOLKIT_TEST_USE_DSN_NAMES} || 0,
};

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw(DSNParser OptionParser);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   };
   my ($dp, $o) = @args{@required_args};

   my $dsn_defaults = $dp->parse_options($o);
   my $prev_dsn     = $args{prev_dsn};
   my $dsn          = $args{dsn};
   if ( !$dsn ) {
      $args{dsn_string} ||= 'h=' . ($dsn_defaults->{h} || 'localhost');

      $dsn = $dp->parse(
         $args{dsn_string}, $prev_dsn, $dsn_defaults);
   }
   elsif ( $prev_dsn ) {
      $dsn = $dp->copy($prev_dsn, $dsn);
   }

   my $dsn_name = $dp->as_string($dsn, [qw(h P S)])
               || $dp->as_string($dsn, [qw(F)])
               || '';

   my $self = {
      dsn             => $dsn,
      dbh             => $args{dbh},
      dsn_name        => $dsn_name,
      hostname        => '',
      set             => $args{set},
      NAME_lc         => defined($args{NAME_lc}) ? $args{NAME_lc} : 1,
      dbh_set         => 0,
      ask_pass        => $o->get('ask-pass'),
      DSNParser       => $dp,
      is_cluster_node => undef,
      parent          => $args{parent},
   };

   return bless $self, $class;
}

sub connect {
   my ( $self, %opts ) = @_;
   my $dsn = $opts{dsn} || $self->{dsn};
   my $dp  = $self->{DSNParser};

   my $dbh = $self->{dbh};
   if ( !$dbh || !$dbh->ping() ) {
      if ( $self->{ask_pass} && !$self->{asked_for_pass} && !defined $dsn->{p} ) {
         $dsn->{p} = OptionParser::prompt_noecho("Enter MySQL password: ");
         $self->{asked_for_pass} = 1;
      }
      $dbh = $dp->get_dbh(
         $dp->get_cxn_params($dsn),
         {
            AutoCommit => 1,
            %opts,
         },
      );
   }

   $dbh = $self->set_dbh($dbh);
   if ( $opts{dsn} ) {
      $self->{dsn}      = $dsn;
      $self->{dsn_name} = $dp->as_string($dsn, [qw(h P S)])
                       || $dp->as_string($dsn, [qw(F)])
                       || '';

   }
   PTDEBUG && _d($dbh, 'Connected dbh to', $self->{hostname},$self->{dsn_name});
   return $dbh;
}

sub set_dbh {
   my ($self, $dbh) = @_;

   if ( $self->{dbh} && $self->{dbh} == $dbh && $self->{dbh_set} ) {
      PTDEBUG && _d($dbh, 'Already set dbh');
      return $dbh;
   }

   PTDEBUG && _d($dbh, 'Setting dbh');

   $dbh->{FetchHashKeyName} = 'NAME_lc' if $self->{NAME_lc};

   my $sql = 'SELECT @@server_id /*!50038 , @@hostname*/';
   PTDEBUG && _d($dbh, $sql);
   my ($server_id, $hostname) = $dbh->selectrow_array($sql);
   PTDEBUG && _d($dbh, 'hostname:', $hostname, $server_id);
   if ( $hostname ) {
      $self->{hostname} = $hostname;
   }

   if ( $self->{parent} ) {
      PTDEBUG && _d($dbh, 'Setting InactiveDestroy=1 in parent');
      $dbh->{InactiveDestroy} = 1;
   }

   if ( my $set = $self->{set}) {
      $set->($dbh);
   }

   $self->{dbh}     = $dbh;
   $self->{dbh_set} = 1;
   return $dbh;
}

sub lost_connection {
   my ($self, $e) = @_;
   return 0 unless $e;
   return $e =~ m/MySQL server has gone away/
       || $e =~ m/Lost connection to MySQL server/
       || $e =~ m/Server shutdown in progress/;
}

sub dbh {
   my ($self) = @_;
   return $self->{dbh};
}

sub dsn {
   my ($self) = @_;
   return $self->{dsn};
}

sub name {
   my ($self) = @_;
   return $self->{dsn_name} if PERCONA_TOOLKIT_TEST_USE_DSN_NAMES;
   return $self->{hostname} || $self->{dsn_name} || 'unknown host';
}

sub description {
   my ($self) = @_;
   return sprintf("%s -> %s:%s", $self->name(), $self->{dsn}->{h}, $self->{dsn}->{P} || 'socket');
}

sub get_id {
   my ($self, $cxn) = @_;

   $cxn ||= $self;

   my $unique_id;
   if ($cxn->is_cluster_node()) {  # for cluster we concatenate various variables to maximize id 'uniqueness' across versions
      my $sql  = q{SHOW STATUS LIKE 'wsrep\_local\_index'};
      my (undef, $wsrep_local_index) = $cxn->dbh->selectrow_array($sql);
      PTDEBUG && _d("Got cluster wsrep_local_index: ",$wsrep_local_index);
      $unique_id = $wsrep_local_index."|"; 
      foreach my $val ('server\_id', 'wsrep\_sst\_receive\_address', 'wsrep\_node\_name', 'wsrep\_node\_address') {
         my $sql = "SHOW VARIABLES LIKE '$val'";
         PTDEBUG && _d($cxn->name, $sql);
         my (undef, $val) = $cxn->dbh->selectrow_array($sql);
         $unique_id .= "|$val";
      }
   } else {
      my $sql  = 'SELECT @@SERVER_ID';
      PTDEBUG && _d($sql);
      $unique_id = $cxn->dbh->selectrow_array($sql);
   }
   PTDEBUG && _d("Generated unique id for cluster:", $unique_id);
   return $unique_id;
}


sub is_cluster_node {
   my ($self, $cxn) = @_;

   $cxn ||= $self;

   my $sql = "SHOW VARIABLES LIKE 'wsrep\_on'";

   my $dbh;
   if ($cxn->isa('DBI::db')) {
      $dbh = $cxn;
      PTDEBUG && _d($sql); #don't invoke name() if it's not a Cxn!
   }
   else {
      $dbh = $cxn->dbh();      
      PTDEBUG && _d($cxn->name, $sql);
   }

   my $row = $dbh->selectrow_arrayref($sql);
   return $row && $row->[1] && ($row->[1] eq 'ON' || $row->[1] eq '1') ? 1 : 0;

}

sub remove_duplicate_cxns {
   my ($self, %args) = @_;
   my @cxns     = @{$args{cxns}};
   my $seen_ids = $args{seen_ids} || {};
   PTDEBUG && _d("Removing duplicates from ", join(" ", map { $_->name } @cxns));
   my @trimmed_cxns;

   for my $cxn ( @cxns ) {

      my $id = $cxn->get_id();
      PTDEBUG && _d('Server ID for ', $cxn->name, ': ', $id);

      if ( ! $seen_ids->{$id}++ ) {
         push @trimmed_cxns, $cxn
      }
      else {
         PTDEBUG && _d("Removing ", $cxn->name,
                       ", ID ", $id, ", because we've already seen it");
      }
   }

   return \@trimmed_cxns;
}

sub DESTROY {
   my ($self) = @_;

   PTDEBUG && _d('Destroying cxn');

   if ( $self->{parent} ) {
      PTDEBUG && _d($self->{dbh}, 'Not disconnecting dbh in parent');
   }
   elsif ( $self->{dbh}
           && blessed($self->{dbh})
           && $self->{dbh}->can("disconnect") )
   {
      PTDEBUG && _d($self->{dbh}, 'Disconnecting dbh on', $self->{hostname},
         $self->{dsn_name});
      $self->{dbh}->disconnect();
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
# End Cxn package
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
package pt_kill;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use POSIX qw(setsid);
use List::Util qw(max);
use Digest::MD5 qw(md5_hex);

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

Transformers->import(qw(ts));

use Percona::Toolkit;
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

$OUTPUT_AUTOFLUSH = 1;

my $o;

# ########################################################################
# Configuration info.
# ########################################################################

sub main {
   local @ARGV = @_;  # set global ARGV for this package

   # ########################################################################
   # Get configuration information.
   # ########################################################################
   $o = new OptionParser();
   $o->get_specs();
   $o->get_opts();

   my $dp = $o->DSNParser();
   $dp->prop('set-vars', $o->set_vars());

   if ( !$o->got('busy-time') ) {
      $o->set('interval', 30) unless $o->got('interval');
   }
   else {
      $o->set('interval', max(1, $o->get('busy-time') / 2))
         unless $o->got('interval');
   }

   # Disable opts that don't make sense when reading proclist
   # from a file (or STDIN).
   if ( $o->get('test-matching') ) {
      $o->set('run-time',    0);
      $o->set('interval',    0);
      $o->set('ignore-self', 0);
   }

   # TODO: parse valid values from POD
   my $victims = lc $o->get('victims');
   if ( !grep { $victims eq $_ } qw(oldest all all-but-oldest) ) {
      $o->save_error("Invalid value for --victims: $victims");
   }

   $o->usage_or_errors();

   # ########################################################################
   # First things first: if --stop was given, create the sentinel file.
   # ########################################################################
   if ( $o->get('stop') ) {
      my $sentinel = $o->get('sentinel');
      PTDEBUG && _d('Creating sentinel file', $sentinel);
      open my $fh, '>', $sentinel
         or die "Cannot open $sentinel: $OS_ERROR\n";
      print $fh "Remove this file to permit pt-kill to run.\n"
         or die "Cannot write to $sentinel: $OS_ERROR\n";
      close $fh
         or die "Cannot close $sentinel: $OS_ERROR\n";
      print "Successfully created file $sentinel\n";
      return 0;
   }

   # ########################################################################
   # Create the --filter sub.
   # ########################################################################
   my $filter_sub;
   if ( my $filter = $o->get('filter') ) {
      if ( -f $filter && -r $filter ) {
         PTDEBUG && _d('Reading file', $filter, 'for --filter code');
         open my $fh, "<", $filter or die "Cannot open $filter: $OS_ERROR";
         $filter = do { local $/ = undef; <$fh> };
         close $fh;
      }
      else {
         $filter = "( $filter )";  # issue 565
      }
      my $code = 'sub { my ( $event ) = @_; '
               . "$filter && return \$event; };";
      PTDEBUG && _d('--filter code:', $code);
      $filter_sub = eval $code
         or die "Error compiling --filter code: $code\n$EVAL_ERROR";
   }

   # ########################################################################
   # Make input sub that will either get processlist from MySQL or a file.
   # ########################################################################
   my $ms = new MasterSlave(
      OptionParser => $o,
      DSNParser    => $dp,
      Quoter       => "Quoter",
   );
   my $pl = new Processlist(MasterSlave => $ms, kill_busy_commands => $o->get('kill-busy-commands'));
   my $qr = new QueryRewriter();

   my $cxn;
   my $dbh;           # $cxn->dbh
   my $get_proclist;  # callback to SHOW PROCESSLIST
   my $proc_sth;
   my $kill;          # callback to KILL
   my $kill_sth;
   my $kill_sql;
   if ( $o->get('rds') ){
       $kill_sql = $o->get('kill-query') ? 'CALL mysql.rds_kill_query(?)' : 'CALL mysql.rds_kill(?)';
   }
   else{
       $kill_sql = $o->get('kill-query') ? 'KILL QUERY ?' : 'KILL ?';
   }
   my $files;
   if ( $files = $o->get('test-matching') ) {
      PTDEBUG && _d('Getting processlist from files:', @$files);
      my $trp = new TextResultSetParser();
      my $fh;
      $get_proclist = sub {
         if ( !$fh ) {
            my $file = shift @$files;
            die 'No more files' unless $file;
            if ( $file eq '-' ) {
               $fh = *STDIN;
            }
            else {
               if ( !open $fh, '<', $file ) {
                  warn "Cannot open $file: $OS_ERROR";
                  $fh = undef;
                  return;
               }
            }
         }

         if ( $fh ) {
            local $INPUT_RECORD_SEPARATOR = '';
            my $proclist_text = <$fh>;
            if ( $proclist_text ) {
               return $trp->parse($proclist_text);
            }
            else {
               # No more proclists in this file.
               $fh = undef;
            }
         }

         return;
      };
   }
   else {
      PTDEBUG && _d('Getting processlist from MySQL');
      $cxn = Cxn->new(
         dsn_string   => shift @ARGV,
         NAME_lc      => 0,
         parent       => $o->get('daemonize'),
         DSNParser    => $dp,
         OptionParser => $o,
      );
      $dbh = $cxn->connect();

      # Make the get_proclist and kill callbacks.  Use Retry in case
      # the connection to MySQL is lost, then the dbh and the sths
      # will need to be re-initialized.
      my $retry = Retry->new();

      $proc_sth = $dbh->prepare('SHOW FULL PROCESSLIST');
      $get_proclist = sub {
         return $retry->retry(
            # Retry for an hour: 1,200 tries x 3 seconds = 3600s/1hr
            tries => 1200,
            wait  => sub { sleep 3; }, 
            try => sub {
               $proc_sth->execute();
               return $proc_sth->fetchall_arrayref({});
            },
            fail => sub {
               my (%args) = @_;
               my $error = $args{error};
               # The 1st pattern means that MySQL itself died or was stopped.
               # The 2nd pattern means that our cxn was killed (KILL <id>).
               if (    $error =~ m/MySQL server has gone away/
                    || $error =~ m/Lost connection to MySQL server/ ) {
                  eval {
                     $dbh      = $cxn->connect();
                     $proc_sth = $dbh->prepare('SHOW FULL PROCESSLIST');
                     msg('Reconnected to ' . $cxn->name());
                  };
                  return 1 unless $EVAL_ERROR; # try again
               }
               return 0; # call final_fail
            },
            final_fail => sub {
               my (%args) = @_;
               die $args{error};
            },
         );
      };


      $kill_sth = $dbh->prepare($kill_sql);
      $kill = sub {
         my ($id) = @_;
         PTDEBUG && _d('Killing process', $id);
         return $retry->retry(
            tries => 2,
            try => sub {
               return $kill_sth->execute($id);
            },
            fail => sub {
               my (%args) = @_;
               my $error = $args{error};
               # The 1st pattern means that MySQL itself died or was stopped.
               # The 2nd pattern means that our cxn was killed (KILL <id>).
               if (    $error =~ m/MySQL server has gone away/
                    || $error =~ m/Lost connection to MySQL server/ ) {
                  eval {
                     $dbh      = $cxn->connect();
                     $kill_sth = $dbh->prepare($kill_sql);
                     msg('Reconnected to ' . $cxn->name());
                  };
                  return 1 unless $EVAL_ERROR; # try again
               }
               return 0; # call final_fail
            },
            final_fail => sub {
               my (%args) = @_;
               die $args{error};
            },
         );
      };
   }

   # Set up --log-dsn if specified.
   my ($log, $log_dsn, $log_sql, $log_sth, $log_cxn);
   my @processlist_columns = qw(
      Id User Host db Command
      Time State Info Time_ms
   );
   if ( $log_dsn = $o->get('log-dsn') ) {
      my $db    = $log_dsn->{D};
      my $table = $log_dsn->{t};
      die "--log-dsn does not specify a database (D) "
        . "or a database-qualified table (t)"
         unless defined $table && defined $db;
      PTDEBUG && _d('Connecting --log-dsn:', Dumper($log_dsn));
      $log_cxn = Cxn->new(
         dsn          => $log_dsn,
         NAME_lc      => 0,
         DSNParser    => $dp,
         OptionParser => $o,
      );
      my $log_dbh   = $log_cxn->connect();
      my $log_table = Quoter->quote($db, $table);
      PTDEBUG && _d('Connected --log-dsn:', Dumper($log_cxn->dsn));

      # Create the log-table table if it doesn't exist and --create-log-table
      # was passed in
      my $tp = TableParser->new( Quoter => "Quoter" );
      if ( !$tp->check_table( dbh => $log_dbh, db => $db, tbl => $table ) ) {
         if ($o->get('create-log-table') ) {
            my $sql = $o->read_para_after(
               __FILE__, qr/MAGIC_create_log_table/);
            $sql =~ s/kill_log/IF NOT EXISTS $log_table/;
            PTDEBUG && _d($sql);
            $log_dbh->do($sql);
         }
         else {
            die "--log-dsn table does not exist. Please create it or specify "
            . "--create-log-table.";
         }
      }

      # All the columns of the table that we care about
      my @all_log_columns = ( qw( server_id timestamp reason kill_error ),
                              @processlist_columns );

      my $sql = 'SELECT @@SERVER_ID';
      PTDEBUG && _d($sql);
      my ($server_id) = $dbh->selectrow_array($sql);

      $log_sql = "INSERT INTO $log_table ("
           . join(", ", @all_log_columns)
           . ") VALUES("
           . join(", ", $server_id, ("?") x (@all_log_columns-1))
           . ")";
      PTDEBUG && _d($sql);
      $log_sth = $log_dbh->prepare($log_sql); 

      my $retry = Retry->new();

      $log = sub {
         my (@params) = @_;
         PTDEBUG && _d('Logging values:', @params);
         return $retry->retry(
            tries => 3,
            wait  => sub { sleep 3; },
            try   => sub { return $log_sth->execute(@params); },
            fail  => sub {
               my (%args) = @_;
               my $error = $args{error};
               # The 1st pattern means that MySQL itself died or was stopped.
               # The 2nd pattern means that our cxn was killed (KILL <id>).
               if (    $error =~ m/MySQL server has gone away/
                    || $error =~ m/Lost connection to MySQL server/ ) {
                  eval {
                     $log_dbh = $log_cxn->connect();
                     $log_sth = $log_dbh->prepare($log_sql);
                     msg('Reconnected to ' . $cxn->name());
                  };
                  if ( $EVAL_ERROR ) {
                     warn "Fail code failed: $EVAL_ERROR";
                  }
                  return 1; # retry
               }
               return 0; # call final_fail
            },
            final_fail => sub {
               my (%args) = @_;
               die $args{error};
            },
         );
      };
   }

   # ########################################################################
   # Daemonize only after (potentially) asking for passwords for --ask-pass.
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

   # If we daemonized, the parent has already exited and we're the child.
   # We shared a copy of every Cxn with the parent, and the parent's copies
   # were destroyed but the dbhs were not disconnected because the parent
   # attrib was true.  Now, as the child, set it false so the dbhs will be
   # disconnected when our Cxn copies are destroyed.  If we didn't daemonize,
   # then we're not really a parent (since we have no children), so set it
   # false to auto-disconnect the dbhs when our Cxns are destroyed.
   $cxn->{parent} = 0 if $cxn;

   # ########################################################################
   # Do the version-check
   # ########################################################################
   if ( $o->get('version-check') && (!$o->has('quiet') || !$o->get('quiet')) ) {
      VersionCheck::version_check(
         force     => $o->got('version-check'),
         instances => [ ($dbh ? { dbh => $dbh, dsn => $cxn->dsn() } : ()) ],
      );
   }

   # ########################################################################
   # Start working.
   # ########################################################################
   msg("$PROGRAM_NAME starting");
   msg($dbh ? "Connected to host " . $cxn->name()
            : "Test matching files @$files");

   # Class-based match criteria.
   my $query_count    = $o->get('query-count');
   my $each_busy_time = $o->get('each-busy-time');
   my $any_busy_time  = $o->get('any-busy-time');
   my $group_by       = $o->get('group-by');
   if ( $group_by 
        && $group_by =~ m/id|user|host|db|command|time|state|info/i ) {
      # Processlist.pm is case-sensitive.  It matches Id, Host, db, etc.
      # So we'll do the same because if we set NAME_lc on the dbh then
      # we'll break our Processlist obj.
      $group_by = lc $group_by;
      $group_by = ucfirst $group_by unless $group_by eq 'db';
   }

   # Per-class match criteria.
   my %find_spec = (
      busy_time           => $o->get('busy-time'),
      idle_time           => $o->get('idle-time'),
      all                 => $o->get('match-all'),
      replication_threads => $o->get('replication-threads'),
      ignore => {
         Command  => $o->get('ignore-command'),
         db       => $o->get('ignore-db'),
         Host     => $o->get('ignore-host'),
         Id       => $o->get('ignore-self') ? $dbh->{mysql_thread_id} : undef,
         Info     => $o->get('ignore-info'),
         State    => $o->get('ignore-state'),
         User     => $o->get('ignore-user'),
      },
      match => {
         Command  => $o->get('match-command'),
         db       => $o->get('match-db'),
         Host     => $o->get('match-host'),
         Info     => $o->get('match-info'),
         State    => $o->get('match-state'),
         User     => $o->get('match-user'),
      },
   );
   msg("Find spec: " . Dumper(\%find_spec));

   my $sentinel = $o->get('sentinel');
   my $run_time = $o->get('run-time') || 0;
   my $start    = time();
   my $end      = $start + $run_time;  # When we should exit
   my $now      = $start;

   if ( $dbh ) {
      msg("Run-time: " . ($run_time ? "$run_time seconds" : "forever")
         . " at " . ($o->get('interval') || 0) . " second intervals");
   }

   # We don't care about the executed command, and we don't want
   # to wait for it, so we ignore dead children so we don't have
   # to reap them and they won't become zombies.
   # https://bugs.launchpad.net/percona-toolkit/+bug/919819
   if ( $o->get('execute-command') ) {
      $SIG{CHLD} = 'IGNORE';
   }

   while ( (!$run_time || $now < $end) && !-f $sentinel ) {
      msg('Checking processlist');
      my $proclist;
      eval { $proclist = $get_proclist->(); };
      if ( $EVAL_ERROR ) {
         last if $EVAL_ERROR =~ m/No more files/;
         die "Error getting SHOW PROCESSLIST: $EVAL_ERROR";
      }

      # Apply --filter to the processlist events.
      my $filtered_proclist;
      if ( $filter_sub && $proclist && @$proclist ) {
         foreach my $proc ( @$proclist ) {
            push @$filtered_proclist, $proc if $filter_sub->($proc);
         }
      }
      else {
         $filtered_proclist = $proclist;
      }

      $proclist = $filtered_proclist;

      my @queries;
      if ( $proclist ) {
         # ##################################################################
         # Group queries into classes.  If --group-by wasn't specified
         # then all queries will be put in the "default" class.
         # ##################################################################
         my $query_classes = group_queries(
            proclist       => $proclist,
            group_by       => $group_by,
            strip_comments => $o->get('strip-comments'),
            QueryRewriter  => $qr,
         );

         # ##################################################################
         # Find matching queries in each class.
         # ##################################################################
         CLASS:
         foreach my $class ( keys %$query_classes ) {
            PTDEBUG && _d('Finding matching queries in class', $class);

            my @matches = $pl->find($query_classes->{$class}, %find_spec);
            PTDEBUG && _d(scalar @matches, 'queries in class', $class);
            next CLASS unless scalar @matches;

            # ###############################################################
            # Apply class-based filters.
            # ###############################################################
            if ( $query_count && @matches < $query_count ) {
               PTDEBUG && _d('Not enough queries in class', $class,
                  '; has', scalar @matches, 'but needs at least', $query_count);
               next CLASS;
            }

            if ( $each_busy_time ) {
               foreach my $proc ( @matches ) {
                  if ( ($proc->{Time} || 0) <= $each_busy_time ) {
                     PTDEBUG && _d('This query in class', $class,
                        'hasn\'t been running long enough:', Dumper($proc));
                     next CLASS;
                  }
               }
            }
            elsif ( $any_busy_time ) {
               my $busy_enough = 0;
               foreach my $proc ( @matches ) {
                  if ( ($proc->{Time} || 0) > $any_busy_time ) {
                     $busy_enough = 1;
                     last;
                  }
               }
               if ( !$busy_enough ) {
                  PTDEBUG && _d('No query is busy enough in class', $class);
                  next CLASS;
               }
            }

            # ###############################################################
            # Select the victims (which of the matching queries to kill).
            # ###############################################################
            @matches = reverse sort {
                  ($a->{Time} || 0) <=> ($b->{Time} || 0) } @matches;
            if ( $victims eq 'oldest' ) {
               @matches = ($matches[0]);
            }
            elsif ( $victims eq 'all-but-oldest' ) {
               shift @matches;  # remove fist/oldest query
            }
            elsif ( $victims eq 'all' ) {
               # Don't do anything.
            }
            else {
               # Shouldn't happen.  Option val should be verified earlier.
               die "I don't know how to kill $victims";
            }

            # ###############################################################
            # Save matching queries in this class.
            # ###############################################################
            PTDEBUG && _d(scalar @matches, 'queries to kill in class', $class);
            push @queries, @matches;

         } # CLASS
         msg('Matched ' . scalar @queries . ' queries');

         MATCHING_QUERY:
         foreach my $query ( @queries ) {
            if ( $o->get('print') ) {
               printf "# %s %s %d (%s %d sec) %s\n",
                  ts(time), $o->get('kill-query') ? 'KILL QUERY' : 'KILL',
                  $query->{Id}, ($query->{Command} || 'NULL'), $query->{Time},
                  ($query->{Info} || 'NULL');
            }
            if ( $o->get('query-id') ) {
                  my $fp = $qr->fingerprint($query->{'Info'});
                  my $chksm = Transformers::make_checksum($fp);
                  print "Query ID: 0x$chksm\n";
            }
            if ( $o->get('execute-command') ) {
               exec_cmd($o->get('execute-command'));
               msg('Executed ' . $o->get('execute-command'));
            }
            if ( $o->get('kill') || $o->get('kill-query') ) {
               if ( $o->get('wait-before-kill') ) {
                  msg("Sleeping " . $o->get('wait-before-kill')
                     . " seconds before kill");
                  sleep $o->get('wait-before-kill');
               }
               local $@;
               eval { $kill->($query->{Id}) };
               if ( $log ) {
                  log_to_table(
                     log        => $log,
                     query      => $query,
                     proclist   => $pl,
                     columns    => \@processlist_columns,
                     eval_error => $EVAL_ERROR,
                  );
               }
               if ( $EVAL_ERROR ) {
                  msg("Error killing $query->{Id}: $EVAL_ERROR");
               }
               else {
                  msg("Killed $query->{Id}");
               }
            }
         }
      }
      else {
         msg('Processlist returned no queries');
      }

      if ( $dbh ) {
         if ( @queries && $o->get('wait-after-kill') ) {
            msg("Sleeping " . $o->get('wait-after-kill')
               . " seconds after killing queries");
            sleep $o->get('wait-after-kill');
         }
         else {
            msg("Sleeping " . $o->get('interval')
               . " seconds after normal interval");
            sleep $o->get('interval');
         }
      }

      $now = time();
   }

   msg("Sentinel file $sentinel exists") if $sentinel && -f $sentinel;
   msg("$PROGRAM_NAME ending");
   return 0;
}

# ############################################################################
# Subroutines.
# ############################################################################

# Forks and detaches from parent to execute the given command;
# does not block parent.
sub exec_cmd {
   my ( $cmd ) = @_;
   PTDEBUG && _d('exec cmd:', $cmd);
   return unless $cmd;

   my $pid = fork();
   if ( $pid ) {
      # parent
      PTDEBUG && _d('child pid:', $pid);
      return $pid;
   }

   # child
   POSIX::setsid() or die "Cannot start a new session: $OS_ERROR";
   my $retval = system($cmd);
   $retval = $retval >> 8;
   PTDEBUG && _d('child exit status:', $retval);
   exit $retval;
}

sub msg {
   my ( $msg ) = @_;
   print '# ', ts(time), " $msg\n" if $o->get('verbose');
   PTDEBUG && _d($msg);
   return;
}

sub log_to_table {
   my (%args) = @_;
   my ($log, $query, $pl, $processlist_columns)
            = @args{qw( log query proclist columns )};

   my $ts      = Transformers::ts(time());
   my $reasons = join "\n", map {
         defined($_) ? $_ : "Unkown reason"
      } @{ $pl->{_reasons_for_matching}->{$query} };
   $log->(
         $ts, $reasons, $args{eval_error},
         @{$query}{@$processlist_columns}
   );
}

sub group_queries {
   my ( %args ) = @_;
   my ($proclist, $group_by, $qr) = @args{qw(proclist group_by QueryRewriter)};
   PTDEBUG && _d("Grouping queries by", $group_by);

   # If there's proclist then there's nothing to do.  If there's no group by
   # then all the procs in the list are in the same class.
   return $proclist unless $proclist;
   return { 'default' => $proclist } unless $group_by;

   my $query_classes = {};
   foreach my $proc ( @$proclist ) {
      if ( $args{strip_comments} &&  $proc->{Info} ) {
         $proc->{Info} = $qr->strip_comments($proc->{Info});
      }

      my $class; 
      if ( $group_by eq 'fingerprint' ) {
         $class = $proc->{Info} ? $qr->fingerprint($proc->{Info}) : 'NULL'; 
      }
      else {
         $class = $proc->{$group_by} ? $proc->{$group_by} : 'NULL';
      }
      push @{$query_classes->{$class}}, $proc;
   }

   return $query_classes;
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

pt-kill - Kill MySQL queries that match certain criteria.

=head1 SYNOPSIS

Usage: pt-kill [OPTIONS] [DSN]

pt-kill kills MySQL connections.  pt-kill connects to MySQL and gets queries
from SHOW PROCESSLIST if no FILE is given.  Else, it reads queries from one
or more FILE which contains the output of SHOW PROCESSLIST.  If FILE is -,
pt-kill reads from STDIN.

Kill queries running longer than 60s:

  pt-kill --busy-time 60 --kill

Print, do not kill, queries running longer than 60s:

  pt-kill --busy-time 60 --print

Check for sleeping processes and kill them all every 10s:

  pt-kill --match-command Sleep --kill --victims all --interval 10

Print all login processes:

  pt-kill --match-state login --print --victims all

See which queries in the processlist right now would match:

   mysql -e "SHOW PROCESSLIST" > proclist.txt
   pt-kill --test-matching proclist.txt --busy-time 60 --print

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

pt-kill captures queries from SHOW PROCESSLIST, filters them, and then either
kills or prints them.  This is also known as a "slow query sniper" in some
circles.  The idea is to watch for queries that might be consuming too many
resources, and kill them.

For brevity, we talk about killing queries, but they may just be printed
(or some other future action) depending on what options are given.

Normally pt-kill connects to MySQL to get queries from SHOW PROCESSLIST.
Alternatively, it can read SHOW PROCESSLIST output from files.  In this case,
pt-kill does not connect to MySQL and L<"--kill"> has no effect.  You should
use L<"--print"> instead when reading files.  The ability to read a file
with L<"--test-matching"> allows you to capture SHOW PROCESSLIST and test it
later with pt-kill to make sure that your matches kill the proper queries.
There are a lot of special rules to follow, such as "don't kill replication
threads," so be careful not to kill something important!

Two important options to know are L<"--busy-time"> and L<"--victims">.
First, whereas most match/filter options match their corresponding value from
SHOW PROCESSLIST (e.g. L<"--match-command"> matches a query's Command value),
the Time value is matched by L<"--busy-time">.  See also L<"--interval">.

Second, L<"--victims"> controls which matching queries from each class are
killed.  By default, the matching query with the highest Time value is killed
(the oldest query).  See the next section, L<"GROUP, MATCH AND KILL">,
for more details.

Usually you need to specify at least one C<--match> option, else no
queries will match.  Or, you can specify L<"--match-all"> to match all queries
that aren't ignored by an C<--ignore> option.

=head1 GROUP, MATCH AND KILL

Queries pass through several steps to determine which exactly will be killed
(or printed--whatever action is specified).  Understanding these steps will
help you match precisely the queries you want.

The first step is grouping queries into classes.  The L<"--group-by"> option
controls grouping.  By default, this option has no value so all queries are
grouped into one default class.  All types of matching and filtering
(the next step) are applied per-class.  Therefore, you may need to group
queries in order to match/filter some classes but not others.

The second step is matching.  Matching implies filtering since if a query
doesn't match some criteria, it is removed from its class.
Matching happens for each class.  First, queries are filtered from their
class by the various C<Query Matches> options like L<"--match-user">.
Then, entire classes are filtered by the various C<Class Matches> options
like L<"--query-count">.

The third step is victim selection, that is, which matching queries in each
class to kill.  This is controlled by the L<"--victims"> option.  Although
many queries in a class may match, you may only want to kill the oldest
query, or all queries, etc.

The forth and final step is to take some action on all matching queries
from all classes.  The C<Actions> options specify which actions will be
taken.  At this step, there are no more classes, just a single list of
queries to kill, print, etc.

pt-kill will kill all the queries matching ANY of the specified criteria (logical OR).
For example, using:

  --busy-time 114 --match-command 'Query|Execute'

will kill all queries having busy-time > 114 C<OR> where the command is C<Query> or C<Execute>

If you want to kill only the queries where C<busy-time > 114> C<AND> the command is Query or 
Execute, you need to use L<"--kill-busy-commands>:

  --busy-time 114 --kill-busy-commands 'Query|Execute' 

=head1 OUTPUT

If only L<"--kill"> is given, then there is no output.  If only
L<"--print"> is given, then a timestamped KILL statement if printed
for every query that would have been killed, like:

  # 2009-07-15T15:04:01 KILL 8 (Query 42 sec) SELECT * FROM huge_table

The line shows a timestamp, the query's Id (8), its Time (42 sec) and its
Info (usually the query SQL).

If both L<"--kill"> and L<"--print"> are given, then matching queries are
killed and a line for each like the one above is printed.

Any command executed by L<"--execute-command"> is responsible for its own
output and logging.  After being executed, pt-kill has no control or interaction
with the command.

=head1 OPTIONS

Specify at least one of L<"--kill">, L<"--kill-query">, L<"--print">, L<"--execute-command"> or L<"--stop">.

L<"--any-busy-time"> and L<"--each-busy-time"> are mutually exclusive.

L<"--kill"> and L<"--kill-query"> are mutually exclusive.

L<"--daemonize"> and L<"--test-matching"> are mutually exclusive.

This tool accepts additional command-line arguments.  Refer to the
L<"SYNOPSIS"> and usage information for details.

=over

=item --ask-pass

Prompt for a password when connecting to MySQL.

=item --charset

short form: -A; type: string

Default character set.  If the value is utf8, sets Perl's binmode on
STDOUT to utf8, passes the mysql_enable_utf8 option to DBD::mysql, and runs SET
NAMES UTF8 after connecting to MySQL.  Any other value sets binmode on STDOUT
without the utf8 layer, and runs SET NAMES after connecting to MySQL.

=item --config

type: Array

Read this comma-separated list of config files; if specified, this must be the
first option on the command line.

=item --create-log-table

Create the L<"--log-dsn"> table if it does not exist.

This option causes the table specified by L<"--log-dsn"> to be created with the
default structure shown in the documentation for that option.

=item --daemonize

Fork to the background and detach from the shell.  POSIX operating systems
only.

=item --database

short form: -D; type: string

The database to use for the connection.

=item --defaults-file

short form: -F; type: string

Only read mysql options from the given file.  You must give an absolute
pathname.

=item --filter

type: string

Discard events for which this Perl code doesn't return true.

This option is a string of Perl code or a file containing Perl code that gets
compiled into a subroutine with one argument: $event.  This is a hashref.
If the given value is a readable file, then pt-kill reads the entire
file and uses its contents as the code.  The file should not contain
a shebang (#!/usr/bin/perl) line.

If the code returns true, the chain of callbacks continues; otherwise it ends.
The code is the last statement in the subroutine other than C<return $event>. 
The subroutine template is:

  sub { $event = shift; filter && return $event; }

Filters given on the command line are wrapped inside parentheses like like
C<( filter )>.  For complex, multi-line filters, you must put the code inside
a file so it will not be wrapped inside parentheses.  Either way, the filter
must produce syntactically valid code given the template.  For example, an
if-else branch given on the command line would not be valid:

  --filter 'if () { } else { }'  # WRONG

Since it's given on the command line, the if-else branch would be wrapped inside
parentheses which is not syntactically valid.  So to accomplish something more
complex like this would require putting the code in a file, for example
filter.txt:

  my $event_ok; if (...) { $event_ok=1; } else { $event_ok=0; } $event_ok

Then specify C<--filter filter.txt> to read the code from filter.txt.

If the filter code won't compile, pt-kill will die with an error.
If the filter code does compile, an error may still occur at runtime if the
code tries to do something wrong (like pattern match an undefined value).
pt-kill does not provide any safeguards so code carefully!

It is permissible for the code to have side effects (to alter C<$event>).


=item --group-by

type: string

Apply matches to each class of queries grouped by this SHOW PROCESSLIST column.
In addition to the basic columns of SHOW PROCESSLIST (user, host, command,
state, etc.), queries can be matched by C<fingerprint> which abstracts the
SQL query in the C<Info> column.

By default, queries are not grouped, so matches and actions apply to all
queries.  Grouping allows matches and actions to apply to classes of
similar queries, if any queries in the class match.

For example, detecting cache stampedes (see C<all-but-oldest> under
L<"--victims"> for an explanation of that term) requires that queries are
grouped by the C<arg> attribute.  This creates classes of identical queries
(stripped of comments).  So queries C<"SELECT c FROM t WHERE id=1"> and
C<"SELECT c FROM t WHERE id=1"> are grouped into the same class, but
query c<"SELECT c FROM t WHERE id=3"> is not identical to the first two
queries so it is grouped into another class. Then when L<"--victims">
C<all-but-oldest> is specified, all but the oldest query in each class is
killed for each class of queries that matches the match criteria.

=item --help

Show help and exit.

=item --host

short form: -h; type: string; default: localhost

Connect to host.

=item --interval

type: time

How often to check for queries to kill.  If L<"--busy-time"> is not given,
then the default interval is 30 seconds.  Else the default is half as often
as L<"--busy-time">.  If both L<"--interval"> and L<"--busy-time"> are given,
then the explicit L<"--interval"> value is used.

See also L<"--run-time">.

=item --log

type: string

Print all output to this file when daemonized.

=item --log-dsn

type: DSN

Store each query killed in this DSN.

The argument specifies a table to store all killed queries.  The DSN
passed in must have the databse (D) and table (t) options. The
table must have at least the following columns.  You can add more columns for
your own special purposes, but they won't be used by pt-kill.  The
following CREATE TABLE definition is also used for L<"--create-log-table">.
MAGIC_create_log_table:

   CREATE TABLE kill_log (
      kill_id     int(10) unsigned NOT NULL AUTO_INCREMENT,
      server_id   bigint(4) NOT NULL DEFAULT '0',
      timestamp   DATETIME,
      reason      TEXT,
      kill_error  TEXT,
      Id          bigint(4) NOT NULL DEFAULT '0',
      User        varchar(16) NOT NULL DEFAULT '',
      Host        varchar(64) NOT NULL DEFAULT '',
      db          varchar(64) DEFAULT NULL,
      Command     varchar(16) NOT NULL DEFAULT '',
      Time        int(7) NOT NULL DEFAULT '0',
      State       varchar(64) DEFAULT NULL,
      Info        longtext,
      Time_ms     bigint(21) DEFAULT '0', # NOTE, TODO: currently not used
      PRIMARY KEY (kill_id)
   ) DEFAULT CHARSET=utf8

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

=item --query-id

Prints an ID of the query that was just killed. This is 
equivalent to the "ID" output of pt-query-digest. This allows 
cross-referencing the output of both tools.

Example:

   Query ID 0xE9800998ECF8427E

Note that this is a digest (or hash) of the query's "fingerprint", 
so queries of the same form but with different values will have the same ID.
See pt-query-digest for more information.

=item --rds

Denotes the instance in question is on Amazon RDS. By default pt-kill runs
the MySQL command "kill" for L<"--kill"> and "kill query" L<"--kill-query">.
On RDS these two commands are not available and are replaced by function calls.
This option modifies L<"--kill"> to use "CALL mysql.rds_kill(thread-id)" instead
and L<"--kill-query"> to use "CALL mysql.rds_kill_query(thread-id)"

=item --run-time

type: time

How long to run before exiting.  By default pt-kill runs forever, or until
its process is killed or stopped by the creation of a L<"--sentinel"> file.
If this option is specified, pt-kill runs for the specified amount of time
and sleeps L<"--interval"> seconds between each check of the PROCESSLIST.

=item --sentinel

type: string; default: /tmp/pt-kill-sentinel

Exit if this file exists.

The presence of the file specified by L<"--sentinel"> will cause all
running instances of pt-kill to exit.  You might find this handy to stop cron
jobs gracefully if necessary.  See also L<"--stop">.

=item --slave-user

type: string

Sets the user to be used to connect to the slaves.
This parameter allows you to have a different user with less privileges on the
slaves but that user must exist on all slaves.

=item --slave-password

type: string

Sets the password to be used to connect to the slaves.
It can be used with --slave-user and the password for the user must be the same
on all slaves.

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

=item --stop

Stop running instances by creating the L<"--sentinel"> file.

Causes pt-kill to create the sentinel file specified by L<"--sentinel"> and
exit.  This should have the effect of stopping all running instances which are
watching the same sentinel file.

=item --[no]strip-comments

default: yes

Remove SQL comments from queries in the Info column of the PROCESSLIST.

=item --user

short form: -u; type: string

User for login if not current user.

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

=item --victims

type: string; default: oldest

Which of the matching queries in each class will be killed.  After classes
have been matched/filtered, this option specifies which of the matching
queries in each class will be killed (or printed, etc.).  The following
values are possible:

=over

=item oldest

Only kill the single oldest query.  This is to prevent killing queries that
aren't really long-running, they're just long-waiting.  This sorts matching
queries by Time and kills the one with the highest Time value.

=item all

Kill all queries in the class.

=item all-but-oldest

Kill all but the oldest query.  This is the inverse of the C<oldest> value.

This value can be used to prevent "cache stampedes", the condition where
several identical queries are executed and create a backlog while the first
query attempts to finish.  Since all queries are identical, all but the first
query are killed so that it can complete and populate the cache.

=back

=item --wait-after-kill

type: time

Wait after killing a query, before looking for more to kill.  The purpose of
this is to give blocked queries a chance to execute, so we don't kill a query
that's blocking a bunch of others, and then kill the others immediately
afterwards.

=item --wait-before-kill

type: time

Wait before killing a query.  The purpose of this is to give
L<"--execute-command"> a chance to see the matching query and gather other
MySQL or system information before it's killed.

=back

=head2 QUERY MATCHES

These options filter queries from their classes.  If a query does not
match, it is removed from its class.  The C<--ignore> options take precedence.
The matches for command, db, host, etc. correspond to the columns returned
by SHOW PROCESSLIST: Command, db, Host, etc.  All pattern matches are
case-sensitive by default, but they can be made case-insensitive by specifying
a regex pattern like C<(?i-xsm:select)>.

See also L<"GROUP, MATCH AND KILL">.

=over

=item --busy-time

type: time; group: Query Matches

Match queries that have been running for longer than this time.  The queries
must be in Command=Query status.  This matches a query's Time value as
reported by SHOW PROCESSLIST.

=item --idle-time

type: time; group: Query Matches

Match queries that have been idle/sleeping for longer than this time.
The queries must be in Command=Sleep status.  This matches a query's Time
value as reported by SHOW PROCESSLIST.

=item --ignore-command

type: string; group: Query Matches

Ignore queries whose Command matches this Perl regex.

See L<"--match-command">.

=item --ignore-db

type: string; group: Query Matches

Ignore queries whose db (database) matches this Perl regex.

See L<"--match-db">.

=item --ignore-host

type: string; group: Query Matches

Ignore queries whose Host matches this Perl regex.

See L<"--match-host">.

=item --ignore-info

type: string; group: Query Matches

Ignore queries whose Info (query) matches this Perl regex.

See L<"--match-info">.

=item --[no]ignore-self

default: yes; group: Query Matches

Don't kill pt-kill's own connection.

=item --ignore-state

type: string; group: Query Matches; default: Locked

Ignore queries whose State matches this Perl regex.  The default is to keep
threads from being killed if they are locked waiting for another thread.

See L<"--match-state">.

=item --ignore-user

type: string; group: Query Matches

Ignore queries whose user matches this Perl regex.

See L<"--match-user">.

=item --match-all

group: Query Matches

Match all queries that are not ignored.  If no ignore options are specified,
then every query matches (except replication threads, unless
L<"--replication-threads"> is also specified).  This option allows you to
specify negative matches, i.e. "match every query I<except>..." where the
exceptions are defined by specifying various C<--ignore> options.

This option is I<not> the same as L<"--victims"> C<all>.  This option matches
all queries within a class, whereas L<"--victims"> C<all> specifies that all
matching queries in a class (however they matched) will be killed.  Normally,
however, the two are used together because if, for example, you specify
L<"--victims"> C<oldest>, then although all queries may match, only the oldest
will be killed.

=item --match-command

type: string; group: Query Matches

Match only queries whose Command matches this Perl regex.

Common Command values are:

  Query
  Sleep
  Binlog Dump
  Connect
  Delayed insert
  Execute
  Fetch
  Init DB
  Kill
  Prepare
  Processlist
  Quit
  Reset stmt
  Table Dump

See L<http://dev.mysql.com/doc/refman/5.1/en/thread-commands.html> for a full
list and description of Command values.

=item --match-db

type: string; group: Query Matches

Match only queries whose db (database) matches this Perl regex.

=item --match-host

type: string; group: Query Matches

Match only queries whose Host matches this Perl regex.

The Host value often time includes the port like "host:port".

=item --match-info

type: string; group: Query Matches

Match only queries whose Info (query) matches this Perl regex.

The Info column of the processlist shows the query that is being executed
or NULL if no query is being executed.

=item --match-state

type: string; group: Query Matches

Match only queries whose State matches this Perl regex.

Common State values are:

  Locked
  login
  copy to tmp table
  Copying to tmp table
  Copying to tmp table on disk
  Creating tmp table
  executing
  Reading from net
  Sending data
  Sorting for order
  Sorting result
  Table lock
  Updating

See L<http://dev.mysql.com/doc/refman/5.1/en/general-thread-states.html> for
a full list and description of State values.

=item --match-user

type: string; group: Query Matches

Match only queries whose User matches this Perl regex.

=item --replication-threads

group: Query Matches

Allow matching and killing replication threads.

By default, matches do not apply to replication threads; i.e. replication
threads are completely ignored.  Specifying this option allows matches to
match (and potentially kill) replication threads on masters and slaves.

=item --test-matching

type: array; group: Query Matches

Files with processlist snapshots to test matching options against.  Since
the matching options can be complex, you can save snapshots of processlist
in files, then test matching options against queries in those files.

This option disables L<"--run-time">, L<"--interval">,
and L<"--[no]ignore-self">.

=back

=head2 CLASS MATCHES

These matches apply to entire query classes.  Classes are created by specifying
the L<"--group-by"> option, else all queries are members of a single, default
class.

See also L<"GROUP, MATCH AND KILL">.

=over

=item --any-busy-time

type: time; group: Class Matches

Match query class if any query has been running for longer than this time.
"Longer than" means that if you specify C<10>, for example, the class will
only match if there's at least one query that has been running for greater
than 10 seconds.

See L<"--each-busy-time"> for more details.

=item --each-busy-time

type: time; group: Class Matches

Match query class if each query has been running for longer than this time.
"Longer than" means that if you specify C<10>, for example, the class will
only match if each and every query has been running for greater than 10
seconds.

See also L<"--any-busy-time"> (to match a class if ANY query has been running
longer than the specified time) and L<"--busy-time">.

=item --query-count

type: int; group: Class Matches

Match query class if it has at least this many queries.  When queries are
grouped into classes by specifying L<"--group-by">, this option causes matches
to apply only to classes with at least this many queries.  If L<"--group-by">
is not specified then this option causes matches to apply only if there
are at least this many queries in the entire SHOW PROCESSLIST.

=item --verbose

short form: -v

Print information to STDOUT about what is being done.

=back

=head2 ACTIONS

These actions are taken for every matching query from all classes.
The actions are taken in this order: L<"--print">, L<"--execute-command">,
L<"--kill"> / L<"--kill-query">.  This order allows L<"--execute-command">
to see the output of L<"--print"> and the query before
L<"--kill"> / L<"--kill-query">.  This may be helpful because pt-kill does
not pass any information to L<"--execute-command">.

See also L<"GROUP, MATCH AND KILL">.

=over

=item --execute-command

type: string; group: Actions

Execute this command when a query matches.

After the command is executed, pt-kill has no control over it, so the command
is responsible for its own info gathering, logging, interval, etc.  The
command is executed each time a query matches, so be careful that the command
behaves well when multiple instances are ran.  No information from pt-kill is
passed to the command.

See also L<"--wait-before-kill">.

=item --kill

group: Actions

Kill the connection for matching queries.

This option makes pt-kill kill the connections (a.k.a. processes, threads) that
have matching queries.  Use L<"--kill-query"> if you only want to kill
individual queries and not their connections.

Unless L<"--print"> is also given, no other information is printed that shows
that pt-kill matched and killed a query.

See also L<"--wait-before-kill"> and L<"--wait-after-kill">.

=item --kill-busy-commands

type: string; default: Query

group: Actions

Comma sepatated list of commands that will be watched/killed if they ran for
more than L<"--busy-time"> seconds. Default: C<Query>

By default, L<"--busy-time"> kills only C<Query> commands but in some cases, it
is needed to make L<"--busy-time"> to watch and kill other commands. For example,
a prepared statement execution command is C<Execute> instead of C<Query>. In this
case, specifying C<--kill-busy-commands=Query,Execute> will also kill the prepared
stamente execution.

=item --kill-query

group: Actions

Kill matching queries.

This option makes pt-kill kill matching queries.  This requires MySQL 5.0 or
newer.  Unlike L<"--kill"> which kills the connection for matching queries,
this option only kills the query, not its connection.

=item --print

group: Actions

Print a KILL statement for matching queries; does not actually kill queries.

If you just want to see which queries match and would be killed without
actually killing them, specify L<"--print">.  To both kill and print
matching queries, specify both L<"--kill"> and L<"--print">.

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

=item * t

Table to log actions in, if passed through --log-dsn.

=back

=head1 ENVIRONMENT

The environment variable C<PTDEBUG> enables verbose debugging output to STDERR.
To enable debugging and capture all output to a file, run the tool like:

   PTDEBUG=1 pt-kill ... > FILE 2>&1

Be careful: debugging output is voluminous and can generate several megabytes
of output.

=head1 SYSTEM REQUIREMENTS

You need Perl, DBI, DBD::mysql, and some core packages that ought to be
installed in any reasonably new version of Perl.

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-kill>.

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

This program is copyright 2011-2018 Percona LLC and/or its affiliates,
2009-2011 Baron Schwartz.

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

pt-kill 3.3.0

=cut
