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
      OptionParser
      DSNParser
      Daemon
      VersionCompare
   ));
}

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
# VersionCompare package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/VersionCompare.pm
#   t/lib/VersionCompare.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package VersionCompare;

use strict;
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub cmp {
   my ($v1, $v2) = @_;

   $v1 =~ s/[^\d\.]//;
   $v2 =~ s/[^\d\.]//;

   my @a = ( $v1 =~ /(\d+)\.?/g );
   my @b = ( $v2 =~ /(\d+)\.?/g );
   foreach my $n1 (@a) {
      $n1 += 0;
      if (!@b) {
         return 1;
      }
      my $n2 = shift @b;
      $n2 += 0;
      if ($n1 == $n2) {
          next;
      }
      else {
         return $n1 <=> $n2;
      }
   }
   return @b ? -1 : 0;
}


1;
}
# ###########################################################################
# End VersionCompare package
# ###########################################################################

# ###########################################################################
# This is a combination of modules and programs in one -- a runnable module.
# http://www.perl.com/pub/a/2006/07/13/lightning-articles.html?page=last
# Or, look it up in the Camel book on pages 642 and 643 in the 3rd edition.
#
# Check at the end of this package for the call to main() which actually runs
# the program.
# ###########################################################################
package pt_show_grants;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Quotekeys = 0;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;

sub main {
   @ARGV = @_;  # set global ARGV for this package

   # ########################################################################
   # Get configuration information.
   # ########################################################################
   my $o = new OptionParser();
   $o->get_specs();
   $o->get_opts();

   my $dp = $o->DSNParser();
   $dp->prop('set-vars', $o->set_vars());

   $o->usage_or_errors();

   # ########################################################################
   # If --pid, check it first since we'll die if it already exits.
   # ########################################################################
   my $daemon;
   if ( $o->get('pid') ) {
      # We're not daemoninzing, it just handles PID stuff.  Keep $daemon
      # in the the scope of main() because when it's destroyed it automatically
      # removes the PID file.
      $daemon = new Daemon(o=>$o);
      $daemon->make_PID_file();
   }

   # ########################################################################
   # Parse --only and --ignore users.
   # ########################################################################
   my @all_hosts;
   if ( my $users = $o->get('only') ) {
      my @users = map {
         my ( $user, $host ) = parse_user($_);
         PTDEBUG && _d('Parsed only', $_, 'as user', $user, 'and host', $host);
         { User => $user, Host => $host };
      }
      grep {
         if ( $_ !~ /\@/ ) {
            # If the user does not have an @, then get all grants for
            # the user on all hosts (issue 551).
            PTDEBUG && _d('Will get all grants for', $_, 'on all hosts');
            push @all_hosts, $_;
            0;
         }
         else {
            $_;
         }
      }
      grep { $_ =~ m/\S/ }
      @$users;
      $o->set('only', \@users);
   }
   if ( my $users = $o->get('ignore') ) {
      my %users = map {
         my ( $user, $host ) = parse_user($_);
         PTDEBUG && _d('Parsed ignore', $_, 'as user', $user, 'and host',$host);
         my $user_host = "'$user'\@'$host'";
         $user_host => 1;
      }
      grep { $_ =~ m/\S/ }
      @$users;
      $o->set('ignore', \%users);
   }

   # ########################################################################
   # Connect to the database.
   # ########################################################################
   if ( $o->get('ask-pass') ) {
      $o->set('password', OptionParser::prompt_noecho("Enter password: "));
   }

   my $dsn_defaults = $dp->parse_options($o);
   my $dsn          = @ARGV ? $dp->parse(shift @ARGV, $dsn_defaults)
                    :         $dsn_defaults;
   my $dbh          = $dp->get_dbh($dp->get_cxn_params($dsn),
                              { AutoCommit => 1, });

   my ( $version, $ts ) = $dbh->selectrow_array("SELECT VERSION(), NOW()");

   print join("\n",
      "-- Grants dumped by pt-show-grants",
      "-- Dumped from server " . ($dbh->{mysql_hostinfo} || '')
      . ($o->get('timestamp') ? ", MySQL $version at $ts" : ", MySQL $version"),
      ), "\n" if $o->get('header');

   # MySQL 8 roles must be excluded from the regular users list.
   # Roles can be identified because the user password is expired, the authentication
   # string is empty and the account is locked
   my $mysql8_where = '';
   if ($version !~ "-MariaDB" && VersionCompare::cmp($version, '8.0.0') >= 0) {
       $mysql8_where = ' WHERE NOT ( `account_locked`="Y" AND ' .
                                      ' `password_expired`="Y" AND ' .
                                      ' `authentication_string`="" ) ';
   }
   my $users = $o->get('only') || $dbh->selectall_arrayref(
      "SELECT DISTINCT User, Host FROM mysql.user $mysql8_where ORDER BY User, Host",
      { Slice => {} });
   if ( scalar @all_hosts ) {
      my $where = join(' OR ', map { "User='$_'" } @all_hosts);
      my $sql   = "SELECT DISTINCT User, Host FROM mysql.user WHERE $where "
                . "ORDER BY User, Host";
      PTDEBUG && _d($sql);
      push @$users, @{ $dbh->selectall_arrayref($sql, { Slice => {} }) };
   }
   my $ignore_users = $o->get('ignore');

   my $exit_status = 0;
   my $roles = get_roles($dbh, $users);
   if ($roles && scalar @$roles > 0) {
       print "-- Roles\n";
       my $count=0;

       for my $role (@$roles) {
           next if (!$o->get("include-unused-roles") && $role->{active} == 0);
           unshift @$users, { Host => $role->{host}, User => $role->{name}, IsRole => 1};
           $count++;
           printf('CREATE ROLE IF NOT EXISTS `%s`;'."\n", $role->{name});
       }

       if ($count == 0) {
           print "No active roles found\n";
       }
       print "-- End of roles listing\n";
   }

   USER:
   foreach my $u ( @$users ) {
      my $user_host = "'$u->{User}'\@'$u->{Host}'";
      if ( $ignore_users && $ignore_users->{$user_host} ) {
         PTDEBUG && _d('Ignoring user', $user_host);
         next USER;
      }
      else {
         PTDEBUG && _d('Checking user', $user_host);
      }

      # If MySQL 5.7.6+ then we need to use SHOW CREATE USER
      my @create_user;
      if (( VersionCompare::cmp($version, '5.7.6') >= 0 ) &&
          ( VersionCompare::cmp($version, '10.0.0') <= 0 )) {
         eval {
            @create_user = @{ $dbh->selectcol_arrayref("SHOW CREATE USER $user_host") };
         };
         if ( $EVAL_ERROR ) {
            PTDEBUG && _d($EVAL_ERROR);
            $exit_status = 1;
         }
         PTDEBUG && _d('CreateUser:', Dumper(\@create_user));
         # make this replication safe converting the CREATE USER into
         # CREATE USER IF NOT EXISTS and then doing an ALTER USER
            my $create = $create_user[0];
            my $alter  = $create;
            $create =~ s{CREATE USER}{CREATE USER IF NOT EXISTS};
            $create =~ s{ IDENTIFIED .*}{};
            $alter  =~ s{CREATE USER}{ALTER USER};
            @create_user = ( $create, $alter );
            PTDEBUG && _d('AdjustedCreateUser:', Dumper(\@create_user));
      }
      my @grants;
      eval {
         @grants = @{ $dbh->selectcol_arrayref("SHOW GRANTS FOR $user_host") };
      };
      if ( $EVAL_ERROR ) {
         PTDEBUG && _d($EVAL_ERROR);
         $exit_status = 1;
      }
      PTDEBUG && _d('Grants:', Dumper(\@grants));
      next unless @grants;

      if ( $o->get('separate') ) {
         # List each grant separately.
         @grants = map {
            my ( $grants, $on_what ) = $_ =~ m/GRANT (.*?) ON (.*)$/;
            map { "GRANT $_ ON $on_what" } split_grants($grants);
         } @grants;
         PTDEBUG && _d('Grants separated:', Dumper(\@grants));

         my $count;
         # If the row with IDENTIFIED BY has multiple grants, this will
         # create many such rows; strip it from all but the first.
         @grants = map {
            if ( $_ =~ m/IDENTIFIED BY/ ) {
               if ( $count++ ) {
                  $_ =~ s/ IDENTIFIED BY.*//;
               }
            }
            $_;
         } @grants;
         PTDEBUG && _d('Grants separated:', Dumper(\@grants));
      }
      else {
         # Sort the actual grants lexically within each row for consistency.
         @grants = map {
            $_ =~ s/GRANT (.*?) ON (`|\*)/"GRANT " . join(', ', sort(split_grants($1))) . " ON $2"/e;
            $_;
         } @grants;
         PTDEBUG && _d('Grants grouped:', Dumper(\@grants));
      }

      # Sort the grant rows for consistency too, but the one with the password
      # should always come first.
      @grants = sort {
         $b =~ m/IDENTIFIED BY/ <=> $a =~ m/IDENTIFIED BY/ || $a cmp $b
      } @grants;

      # Add @create_user if there
      @grants = ( @create_user, @grants ) if scalar @create_user > 0;
      PTDEBUG && _d('Grants sorted:', Dumper(\@grants));

      # Print REVOKE statements.
      if ( $o->get('revoke') ) {
         my @revoke = map {
            my $grant = $_;
            PTDEBUG && _d($grant);
            my ( $grants, $on_what, $user ) = $grant
               =~ m/GRANT (.*?) ON (.*?) TO ([`'][^'`]*[`']\@[`'][^'`]*[`'])/; # MySQL 8 uses ` instead of ' for `user`@`host`
            PTDEBUG && _d('grants:', $grants, 'on_what:', $on_what,
               'user:', $user);

            my @result;
            if ( $o->get('separate') ) {
               @result = map { "REVOKE $_ ON $on_what FROM $user" }
                  split_grants($grants);
            }
            else {
               @result = "REVOKE $grants ON $on_what FROM $user";
            }

            # The WITH GRANT OPTION must be revoked separately.
            if ( $grant =~ m/WITH GRANT OPTION/ ) {
               push @result, "REVOKE GRANT OPTION ON *.* FROM $user" if $user;
            }

            @result;
         } grep { /\bgrant\b/i } @grants;

         print join(
            "\n",
            "-- Revoke statements for $user_host",
            map {"$_;"} @revoke),
            "\n";
      }

      if ( $o->get('drop') && !defined($u->{IsRole}) ) {
         print join("\n",
            "DROP USER $user_host;",
            "DELETE FROM `mysql`.`user` WHERE `User`='$u->{User}' AND `Host`='$u->{Host}';",
            ), "\n";
      }

      print join( "\n", "-- Grants for $user_host",
         map {"$_;"} @grants ), "\n";

      if ( $o->get('flush') && $o->get('separate') ) {
         print "FLUSH PRIVILEGES;\n";
      }

      $exit_status = 0;
   }

   if ( $o->get('flush') && !$o->get('separate') ) {
      print "FLUSH PRIVILEGES;\n";
   }

   $dbh->disconnect();
   return $exit_status;
}

# ############################################################################
# Subroutines
# ############################################################################
sub parse_user {
   my ( $spec ) = @_;
   my ( $user, $host )
      = $spec =~ m/
         ^               # Beginning of line
         '?([^'@]*)'?    # Username optionally enclosed by '
         (?:
            @            # Followed by @
            '?([^']*?)'? # And host optionally enclosed by '
         )?              # ... which is all optional
         $               # End of line
         /xms;
   $host ||= '%';
   return ( $user, $host );
}

sub get_roles {
    my ($dbh, $users) = @_;
    my $query = <<__EOQ;
    SELECT DISTINCT user.user AS name, user.host, IF(from_user IS NULL,0, 1) AS active
      FROM mysql.user
 LEFT JOIN mysql.role_edges ON role_edges.from_user=user.user
     WHERE `account_locked`='Y'
       AND `password_expired`='Y'
       AND `authentication_string`=''
__EOQ
    if (scalar $users > 0) {
       my $user_names = join (", ", map { "'$_->{User}'" } @$users);
       $query .= " AND to_user IN ($user_names)";
    }
    PTDEBUG && _d("Getting roles");
    PTDEBUG && _d($query);
    my $roles;
    eval { $roles = $dbh->selectall_arrayref($query, { Slice => {} }) };
    if ($EVAL_ERROR) {
        PTDEBUG && _d("Cannot list roles: $EVAL_ERROR");
    }
    return $roles;
}

sub is_role {
    my ($users, $grant) = @_;
    foreach my $u ( @$users ) {
        my $user_host = "`$u->{User}`\@`$u->{Host}`";
        warn "> user_host: $user_host";
        if ($grant eq $user_host) {
            return 1;
        }
    }
    return 0;
}

sub split_grants {
   my ($grants) = @_;
   return unless $grants;
   my @grants;
   if ( $grants =~ m/(?:INSERT|SELECT|UPDATE) \(/ ) {
      PTDEBUG && _d('Splitting grants on keywords:', $grants);
      # TODO: the following .+? might break (e.g. on `annoying)column`).
      # Remember to update this whenever we switch to using
      # a common SQL regex module
      @grants = $grants =~ m/
            (
                (?:INSERT|SELECT|UPDATE)\s\(.+?\) # a column grants
              | [A-Z\s]+
            )
            (?:,\s)?    # Separted from the next grant, if any, by a comma
      /xg;
      # sort columns in column-level permissions (bug lp-1523730)
      @grants = map {
        $_ =~ s/(INSERT|SELECT|UPDATE)\s\((.+?)\)/"$1 (" . join(', ',sort(split(', ',$2))) . ')'/me;
        $_;
      } @grants;
   }
   else {
      PTDEBUG && _d('Splitting grants on comma:', $grants);
      @grants = split(', ', $grants);
   }
   PTDEBUG && _d('Grants split:', Dumper(\@grants));
   return @grants;
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

pt-show-grants - Canonicalize and print MySQL grants so you can effectively replicate, compare and version-control them.

=head1 SYNOPSIS

Usage: pt-show-grants [OPTIONS] [DSN]

pt-show-grants shows grants (user privileges) from a MySQL server.

Examples:

   pt-show-grants

   pt-show-grants --separate --revoke | diff othergrants.sql -

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

pt-show-grants extracts, orders, and then prints grants for MySQL user
accounts.

Why would you want this?  There are several reasons.

The first is to easily replicate users from one server to another; you can
simply extract the grants from the first server and pipe the output directly
into another server.

The second use is to place your grants into version control.  If you do a daily
automated grant dump into version control, you'll get lots of spurious
changesets for grants that don't change, because MySQL prints the actual grants
out in a seemingly random order.  For instance, one day it'll say

  GRANT DELETE, INSERT, UPDATE ON `test`.* TO 'foo'@'%';

And then another day it'll say

  GRANT INSERT, DELETE, UPDATE ON `test`.* TO 'foo'@'%';

The grants haven't changed, but the order has.  This script sorts the grants
within the line, between 'GRANT' and 'ON'.  If there are multiple rows from SHOW
GRANTS, it sorts the rows too, except that it always prints the row with the
user's password first, if it exists.  This removes three kinds of inconsistency
you'll get from running SHOW GRANTS, and avoids spurious changesets in version
control.

Third, if you want to diff grants across servers, it will be hard without
"canonicalizing" them, which pt-show-grants does.  The output is fully
diff-able.

With the L<"--revoke">, L<"--separate"> and other options, pt-show-grants
also makes it easy to revoke specific privileges from users.  This is tedious
otherwise.

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

=item --database

short form: -D; type: string

The database to use for the connection.

=item --defaults-file

short form: -F; type: string

Only read mysql options from the given file.  You must give an absolute
pathname.

=item --drop

Add DROP USER before each user in the output.

=item --flush

Add FLUSH PRIVILEGES after output.

You might need this on pre-4.1.1 servers if you want to drop a user completely.

=item --[no]header

default: yes

Print dump header.

The header precedes the dumped grants.  It looks like:

  -- Grants dumped by pt-show-grants 1.0.19
  -- Dumped from server Localhost via UNIX socket, MySQL 5.0.82-log at 2009-10-26 10:01:04

See also L<"--[no]timestamp">.

=item --help

Show help and exit.

=item --host

short form: -h; type: string

Connect to host.

=item --ignore

type: array

Ignore this comma-separated list of users.

=item --only

type: array

Only show grants for this comma-separated list of users.

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

=item --revoke

Add REVOKE statements for each GRANT statement.

=item --separate

List each GRANT or REVOKE separately.

The default output from MySQL's SHOW GRANTS command lists many privileges on a
single line.  With L<"--flush">, places a FLUSH PRIVILEGES after each user,
instead of once at the end of all the output.

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

=item --[no]include-unused-roles

When dumping MySQL 8+ roles, include unused roles.

=item --socket

short form: -S; type: string

Socket file to use for connection.

=item --[no]timestamp

default: yes

Add timestamp to the dump header.

See also L<"--[no]header">.

=item --user

short form: -u; type: string

User for login if not current user.

=item --version

Show version and exit.

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

   PTDEBUG=1 pt-show-grants ... > FILE 2>&1

Be careful: debugging output is voluminous and can generate several megabytes
of output.

=head1 SYSTEM REQUIREMENTS

You need Perl, DBI, DBD::mysql, and some core packages that ought to be
installed in any reasonably new version of Perl.

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-show-grants>.

Please report bugs at L<https://bugs.launchpad.net/percona-toolkit>.
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

Baron Schwartz

=head1 ABOUT PERCONA TOOLKIT

This tool is part of Percona Toolkit, a collection of advanced command-line
tools for MySQL developed by Percona.  Percona Toolkit was forked from two
projects in June, 2011: Maatkit and Aspersa.  Those projects were created by
Baron Schwartz and primarily developed by him and Daniel Nichter.  Visit
L<http://www.percona.com/software/> to learn about other free, open-source
software from Percona.

=head1 COPYRIGHT, LICENSE, AND WARRANTY

This program is copyright 2011-2018 Percona LLC and/or its affiliates,
2007-2011 Baron Schwartz.

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

pt-show-grants 3.3.0

=cut
