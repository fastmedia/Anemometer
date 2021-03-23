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
      Lmo::Utils
      Lmo::Meta
      Lmo::Object
      Lmo::Types
      Lmo
      DSNParser
      Quoter
      OptionParser
      Transformers
      QueryRewriter
      Processlist
      TcpdumpParser
      MySQLProtocolParser
      SlowLogParser
      SlowLogWriter
      EventAggregator
      ReportFormatter
      QueryReportFormatter
      JSONReportFormatter
      EventTimeline
      QueryParser
      TableParser
      QueryReview
      QueryHistory
      Daemon
      BinaryLogParser
      GeneralLogParser
      RawLogParser
      ProtocolParser
      MasterSlave
      Progress
      FileIterator
      Runtime
      Pipeline
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
   my $checksum = uc md5_hex($val);
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

      if (    !$find_spec{replication_threads}
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
# TcpdumpParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/TcpdumpParser.pm
#   t/lib/TcpdumpParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package TcpdumpParser;

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
   my $self = {};
   return bless $self, $class;
}

sub parse_event {
   my ( $self, %args ) = @_;
   my @required_args = qw(next_event tell);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($next_event, $tell) = @args{@required_args};

   local $INPUT_RECORD_SEPARATOR = "\n20";

   my $pos_in_log = $tell->();
   while ( defined(my $raw_packet = $next_event->()) ) {
      next if $raw_packet =~ m/^$/;  # issue 564
      $pos_in_log -= 1 if $pos_in_log;

      $raw_packet =~ s/\n20\Z//;
      $raw_packet = "20$raw_packet" if $raw_packet =~ /\A20-\d\d-\d\d/; # workaround for year 2020 problem
      $raw_packet = "20$raw_packet" unless $raw_packet =~ m/\A20/;

      $raw_packet =~ s/0x0000:.+?(450.) /0x0000:  $1 /;

      my $packet = $self->_parse_packet($raw_packet);
      $packet->{pos_in_log} = $pos_in_log;
      $packet->{raw_packet} = $raw_packet;

      $args{stats}->{events_read}++ if $args{stats};

      return $packet;
   }

   $args{oktorun}->(0) if $args{oktorun};
   return;
}

sub _parse_packet {
   my ( $self, $packet ) = @_;
   die "I need a packet" unless $packet;

   my ( $ts, $source, $dest )  = $packet =~ m/\A(\S+ \S+).*? IP .*?(\S+) > (\S+):/;
   my ( $src_host, $src_port ) = $source =~ m/((?:\d+\.){3}\d+)\.(\w+)/;
   my ( $dst_host, $dst_port ) = $dest   =~ m/((?:\d+\.){3}\d+)\.(\w+)/;

   $src_port = $self->port_number($src_port);
   $dst_port = $self->port_number($dst_port);
   
   my $hex = qr/[0-9a-f]/;
   (my $data = join('', $packet =~ m/\s+0x$hex+:\s((?:\s$hex{2,4})+)/go)) =~ s/\s+//g; 

   my $ip_hlen = hex(substr($data, 1, 1)); # Num of 32-bit words in header.
   my $ip_plen = hex(substr($data, 4, 4)); # Num of BYTES in IPv4 datagram.
   my $complete = length($data) == 2 * $ip_plen ? 1 : 0;

   my $tcp_hlen = hex(substr($data, ($ip_hlen + 3) * 8, 1));

   my $seq = hex(substr($data, ($ip_hlen + 1) * 8, 8));
   my $ack = hex(substr($data, ($ip_hlen + 2) * 8, 8));

   my $flags = hex(substr($data, (($ip_hlen + 3) * 8) + 2, 2));

   $data = substr($data, ($ip_hlen + $tcp_hlen) * 8);

   my $pkt = {
      ts        => $ts,
      seq       => $seq,
      ack       => $ack,
      fin       => $flags & 0x01,
      syn       => $flags & 0x02,
      rst       => $flags & 0x04,
      src_host  => $src_host,
      src_port  => $src_port,
      dst_host  => $dst_host,
      dst_port  => $dst_port,
      complete  => $complete,
      ip_hlen   => $ip_hlen,
      tcp_hlen  => $tcp_hlen,
      dgram_len => $ip_plen,
      data_len  => $ip_plen - (($ip_hlen + $tcp_hlen) * 4),
      data      => $data ? substr($data, 0, 10).(length $data > 10 ? '...' : '')
                         : '',
   };
   PTDEBUG && _d('packet:', Dumper($pkt));
   $pkt->{data} = $data;
   return $pkt;
}

sub port_number {
   my ( $self, $port ) = @_;
   return unless $port;
   return $port eq 'mysql' ? 3306 : $port;
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
# End TcpdumpParser package
# ###########################################################################

# ###########################################################################
# MySQLProtocolParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/MySQLProtocolParser.pm
#   t/lib/MySQLProtocolParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package MySQLProtocolParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

eval {
   require IO::Uncompress::Inflate; # yum: perl-IO-Compress-Zlib
   IO::Uncompress::Inflate->import(qw(inflate $InflateError));
};

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

BEGIN { our @ISA = 'ProtocolParser'; }

use constant {
   COM_SLEEP               => '00',
   COM_QUIT                => '01',
   COM_INIT_DB             => '02',
   COM_QUERY               => '03',
   COM_FIELD_LIST          => '04',
   COM_CREATE_DB           => '05',
   COM_DROP_DB             => '06',
   COM_REFRESH             => '07',
   COM_SHUTDOWN            => '08',
   COM_STATISTICS          => '09',
   COM_PROCESS_INFO        => '0a',
   COM_CONNECT             => '0b',
   COM_PROCESS_KILL        => '0c',
   COM_DEBUG               => '0d',
   COM_PING                => '0e',
   COM_TIME                => '0f',
   COM_DELAYED_INSERT      => '10',
   COM_CHANGE_USER         => '11',
   COM_BINLOG_DUMP         => '12',
   COM_TABLE_DUMP          => '13',
   COM_CONNECT_OUT         => '14',
   COM_REGISTER_SLAVE      => '15',
   COM_STMT_PREPARE        => '16',
   COM_STMT_EXECUTE        => '17',
   COM_STMT_SEND_LONG_DATA => '18',
   COM_STMT_CLOSE          => '19',
   COM_STMT_RESET          => '1a',
   COM_SET_OPTION          => '1b',
   COM_STMT_FETCH          => '1c',
   SERVER_QUERY_NO_GOOD_INDEX_USED => 16,
   SERVER_QUERY_NO_INDEX_USED      => 32,
};

my %com_for = (
   '00' => 'COM_SLEEP',
   '01' => 'COM_QUIT',
   '02' => 'COM_INIT_DB',
   '03' => 'COM_QUERY',
   '04' => 'COM_FIELD_LIST',
   '05' => 'COM_CREATE_DB',
   '06' => 'COM_DROP_DB',
   '07' => 'COM_REFRESH',
   '08' => 'COM_SHUTDOWN',
   '09' => 'COM_STATISTICS',
   '0a' => 'COM_PROCESS_INFO',
   '0b' => 'COM_CONNECT',
   '0c' => 'COM_PROCESS_KILL',
   '0d' => 'COM_DEBUG',
   '0e' => 'COM_PING',
   '0f' => 'COM_TIME',
   '10' => 'COM_DELAYED_INSERT',
   '11' => 'COM_CHANGE_USER',
   '12' => 'COM_BINLOG_DUMP',
   '13' => 'COM_TABLE_DUMP',
   '14' => 'COM_CONNECT_OUT',
   '15' => 'COM_REGISTER_SLAVE',
   '16' => 'COM_STMT_PREPARE',
   '17' => 'COM_STMT_EXECUTE',
   '18' => 'COM_STMT_SEND_LONG_DATA',
   '19' => 'COM_STMT_CLOSE',
   '1a' => 'COM_STMT_RESET',
   '1b' => 'COM_SET_OPTION',
   '1c' => 'COM_STMT_FETCH',
);

my %flag_for = (
   'CLIENT_LONG_PASSWORD'     => 1,       # new more secure passwords 
   'CLIENT_FOUND_ROWS'        => 2,       # Found instead of affected rows 
   'CLIENT_LONG_FLAG'         => 4,       # Get all column flags 
   'CLIENT_CONNECT_WITH_DB'   => 8,       # One can specify db on connect 
   'CLIENT_NO_SCHEMA'         => 16,      # Don't allow database.table.column 
   'CLIENT_COMPRESS'          => 32,      # Can use compression protocol 
   'CLIENT_ODBC'              => 64,      # Odbc client 
   'CLIENT_LOCAL_FILES'       => 128,     # Can use LOAD DATA LOCAL 
   'CLIENT_IGNORE_SPACE'      => 256,     # Ignore spaces before '(' 
   'CLIENT_PROTOCOL_41'       => 512,     # New 4.1 protocol 
   'CLIENT_INTERACTIVE'       => 1024,    # This is an interactive client 
   'CLIENT_SSL'               => 2048,    # Switch to SSL after handshake 
   'CLIENT_IGNORE_SIGPIPE'    => 4096,    # IGNORE sigpipes 
   'CLIENT_TRANSACTIONS'      => 8192,    # Client knows about transactions 
   'CLIENT_RESERVED'          => 16384,   # Old flag for 4.1 protocol  
   'CLIENT_SECURE_CONNECTION' => 32768,   # New 4.1 authentication 
   'CLIENT_MULTI_STATEMENTS'  => 65536,   # Enable/disable multi-stmt support 
   'CLIENT_MULTI_RESULTS'     => 131072,  # Enable/disable multi-results 
);

use constant {
   MYSQL_TYPE_DECIMAL      => 0,
   MYSQL_TYPE_TINY         => 1,
   MYSQL_TYPE_SHORT        => 2,
   MYSQL_TYPE_LONG         => 3,
   MYSQL_TYPE_FLOAT        => 4,
   MYSQL_TYPE_DOUBLE       => 5,
   MYSQL_TYPE_NULL         => 6,
   MYSQL_TYPE_TIMESTAMP    => 7,
   MYSQL_TYPE_LONGLONG     => 8,
   MYSQL_TYPE_INT24        => 9,
   MYSQL_TYPE_DATE         => 10,
   MYSQL_TYPE_TIME         => 11,
   MYSQL_TYPE_DATETIME     => 12,
   MYSQL_TYPE_YEAR         => 13,
   MYSQL_TYPE_NEWDATE      => 14,
   MYSQL_TYPE_VARCHAR      => 15,
   MYSQL_TYPE_BIT          => 16,
   MYSQL_TYPE_NEWDECIMAL   => 246,
   MYSQL_TYPE_ENUM         => 247,
   MYSQL_TYPE_SET          => 248,
   MYSQL_TYPE_TINY_BLOB    => 249,
   MYSQL_TYPE_MEDIUM_BLOB  => 250,
   MYSQL_TYPE_LONG_BLOB    => 251,
   MYSQL_TYPE_BLOB         => 252,
   MYSQL_TYPE_VAR_STRING   => 253,
   MYSQL_TYPE_STRING       => 254,
   MYSQL_TYPE_GEOMETRY     => 255,
};

my %type_for = (
   0   => 'MYSQL_TYPE_DECIMAL',
   1   => 'MYSQL_TYPE_TINY',
   2   => 'MYSQL_TYPE_SHORT',
   3   => 'MYSQL_TYPE_LONG',
   4   => 'MYSQL_TYPE_FLOAT',
   5   => 'MYSQL_TYPE_DOUBLE',
   6   => 'MYSQL_TYPE_NULL',
   7   => 'MYSQL_TYPE_TIMESTAMP',
   8   => 'MYSQL_TYPE_LONGLONG',
   9   => 'MYSQL_TYPE_INT24',
   10  => 'MYSQL_TYPE_DATE',
   11  => 'MYSQL_TYPE_TIME',
   12  => 'MYSQL_TYPE_DATETIME',
   13  => 'MYSQL_TYPE_YEAR',
   14  => 'MYSQL_TYPE_NEWDATE',
   15  => 'MYSQL_TYPE_VARCHAR',
   16  => 'MYSQL_TYPE_BIT',
   246 => 'MYSQL_TYPE_NEWDECIMAL',
   247 => 'MYSQL_TYPE_ENUM',
   248 => 'MYSQL_TYPE_SET',
   249 => 'MYSQL_TYPE_TINY_BLOB',
   250 => 'MYSQL_TYPE_MEDIUM_BLOB',
   251 => 'MYSQL_TYPE_LONG_BLOB',
   252 => 'MYSQL_TYPE_BLOB',
   253 => 'MYSQL_TYPE_VAR_STRING',
   254 => 'MYSQL_TYPE_STRING',
   255 => 'MYSQL_TYPE_GEOMETRY',
);

my %unpack_type = (
   MYSQL_TYPE_NULL       => sub { return 'NULL', 0; },
   MYSQL_TYPE_TINY       => sub { return to_num(@_, 1), 1; },
   MySQL_TYPE_SHORT      => sub { return to_num(@_, 2), 2; },
   MYSQL_TYPE_LONG       => sub { return to_num(@_, 4), 4; },
   MYSQL_TYPE_LONGLONG   => sub { return to_num(@_, 8), 8; },
   MYSQL_TYPE_DOUBLE     => sub { return to_double(@_), 8; },
   MYSQL_TYPE_VARCHAR    => \&unpack_string,
   MYSQL_TYPE_VAR_STRING => \&unpack_string,
   MYSQL_TYPE_STRING     => \&unpack_string,
);

sub new {
   my ( $class, %args ) = @_;

   my $self = {
      server         => $args{server},
      port           => $args{port} || '3306',
      version        => '41',    # MySQL proto version; not used yet
      sessions       => {},
      o              => $args{o},
      fake_thread_id => 2**32,   # see _make_event()
      null_event     => $args{null_event},
   };
   PTDEBUG && $self->{server} && _d('Watching only server', $self->{server});
   return bless $self, $class;
}

sub parse_event {
   my ( $self, %args ) = @_;
   my @required_args = qw(event);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $packet = @args{@required_args};

   my $src_host = "$packet->{src_host}:$packet->{src_port}";
   my $dst_host = "$packet->{dst_host}:$packet->{dst_port}";

   if ( my $server = $self->{server} ) {  # Watch only the given server.
      $server .= ":$self->{port}";
      if ( $src_host ne $server && $dst_host ne $server ) {
         PTDEBUG && _d('Packet is not to or from', $server);
         return $self->{null_event};
      }
   }

   my $packet_from;
   my $client;
   if ( $src_host =~ m/:$self->{port}$/ ) {
      $packet_from = 'server';
      $client      = $dst_host;
   }
   elsif ( $dst_host =~ m/:$self->{port}$/ ) {
      $packet_from = 'client';
      $client      = $src_host;
   }
   else {
      PTDEBUG && _d('Packet is not to or from a MySQL server');
      return $self->{null_event};
   }
   PTDEBUG && _d('Client', $client);

   my $packetno = -1;
   if ( $packet->{data_len} >= 5 ) {
      $packetno = to_num(substr($packet->{data}, 6, 2));
   }
   if ( !exists $self->{sessions}->{$client} ) {
      if ( $packet->{syn} ) {
         PTDEBUG && _d('New session (SYN)');
      }
      elsif ( $packetno == 0 ) {
         PTDEBUG && _d('New session (packetno 0)');
      }
      else {
         PTDEBUG && _d('Ignoring mid-stream', $packet_from, 'data,',
            'packetno', $packetno);
         return $self->{null_event};
      }

      $self->{sessions}->{$client} = {
         client        => $client,
         ts            => $packet->{ts},
         state         => undef,
         compress      => undef,
         raw_packets   => [],
         buff          => '',
         sths          => {},
         attribs       => {},
         n_queries     => 0,
      };
   }
   my $session = $self->{sessions}->{$client};
   PTDEBUG && _d('Client state:', $session->{state});

   push @{$session->{raw_packets}}, $packet->{raw_packet};

   if ( $packet->{syn} && ($session->{n_queries} > 0 || $session->{state}) ) {
      PTDEBUG && _d('Client port reuse and last session did not quit');
      $self->fail_session($session,
            'client port reuse and last session did not quit');
      return $self->parse_event(%args);
   }

   if ( $packet->{data_len} == 0 ) {
      PTDEBUG && _d('TCP control:',
         map { uc $_ } grep { $packet->{$_} } qw(syn ack fin rst));
      if ( $packet->{'fin'}
           && ($session->{state} || '') eq 'server_handshake' ) {
         PTDEBUG && _d('Client aborted connection');
         my $event = {
            cmd => 'Admin',
            arg => 'administrator command: Connect',
            ts  => $packet->{ts},
         };
         $session->{attribs}->{Error_msg} = 'Client closed connection during handshake';
         $event = $self->_make_event($event, $packet, $session);
         delete $self->{sessions}->{$session->{client}};
         return $event;
      }
      return $self->{null_event};
   }

   if ( $session->{compress} ) {
      return unless $self->uncompress_packet($packet, $session);
   }

   if ( $session->{buff} && $packet_from eq 'client' ) {
      $session->{buff}      .= $packet->{data};
      $packet->{data}        = $session->{buff};
      $session->{buff_left} -= $packet->{data_len};

      $packet->{mysql_data_len} = $session->{mysql_data_len};
      $packet->{number}         = $session->{number};

      PTDEBUG && _d('Appending data to buff; expecting',
         $session->{buff_left}, 'more bytes');
   }
   else { 
      eval {
         remove_mysql_header($packet);
      };
      if ( $EVAL_ERROR ) {
         PTDEBUG && _d('remove_mysql_header() failed; failing session');
         $session->{EVAL_ERROR} = $EVAL_ERROR;
         $self->fail_session($session, 'remove_mysql_header() failed');
         return $self->{null_event};
      }
   }

   my $event;
   if ( $packet_from eq 'server' ) {
      $event = $self->_packet_from_server($packet, $session, $args{misc});
   }
   elsif ( $packet_from eq 'client' ) {
      if ( $session->{buff} ) {
         if ( $session->{buff_left} <= 0 ) {
            PTDEBUG && _d('Data is complete');
            $self->_delete_buff($session);
         }
         else {
            return $self->{null_event};  # waiting for more data; buff_left was reported earlier
         }
      }
      elsif ( $packet->{mysql_data_len} > ($packet->{data_len} - 4) ) {

         if ( $session->{cmd} && ($session->{state} || '') eq 'awaiting_reply' ) {
            PTDEBUG && _d('No server OK to previous command (frag)');
            $self->fail_session($session, 'no server OK to previous command');
            $packet->{data} = $packet->{mysql_hdr} . $packet->{data};
            return $self->parse_event(%args);
         }

         $session->{buff}           = $packet->{data};
         $session->{mysql_data_len} = $packet->{mysql_data_len};
         $session->{number}         = $packet->{number};

         $session->{buff_left}
            ||= $packet->{mysql_data_len} - ($packet->{data_len} - 4);

         PTDEBUG && _d('Data not complete; expecting',
            $session->{buff_left}, 'more bytes');
         return $self->{null_event};
      }

      if ( $session->{cmd} && ($session->{state} || '') eq 'awaiting_reply' ) {
         PTDEBUG && _d('No server OK to previous command');
         $self->fail_session($session, 'no server OK to previous command');
         $packet->{data} = $packet->{mysql_hdr} . $packet->{data};
         return $self->parse_event(%args);
      }

      $event = $self->_packet_from_client($packet, $session, $args{misc});
   }
   else {
      die 'Packet origin unknown';
   }

   PTDEBUG && _d('Done parsing packet; client state:', $session->{state});
   if ( $session->{closed} ) {
      delete $self->{sessions}->{$session->{client}};
      PTDEBUG && _d('Session deleted');
   }

   $args{stats}->{events_parsed}++ if $args{stats};
   return $event || $self->{null_event};
}

sub _packet_from_server {
   my ( $self, $packet, $session, $misc ) = @_;
   die "I need a packet"  unless $packet;
   die "I need a session" unless $session;

   PTDEBUG && _d('Packet is from server; client state:', $session->{state}); 

   if ( ($session->{server_seq} || '') eq $packet->{seq} ) {
      push @{ $session->{server_retransmissions} }, $packet->{seq};
      PTDEBUG && _d('TCP retransmission');
      return;
   }
   $session->{server_seq} = $packet->{seq};

   my $data = $packet->{data};


   my ( $first_byte ) = substr($data, 0, 2, '');
   PTDEBUG && _d('First byte of packet:', $first_byte);
   if ( !$first_byte ) {
      $self->fail_session($session, 'no first byte');
      return;
   }

   if ( !$session->{state} ) {
      if ( $first_byte eq '0a' && length $data >= 33 && $data =~ m/00{13}/ ) {
         my $handshake = parse_server_handshake_packet($data);
         if ( !$handshake ) {
            $self->fail_session($session, 'failed to parse server handshake');
            return;
         }
         $session->{state}     = 'server_handshake';
         $session->{thread_id} = $handshake->{thread_id};

         $session->{ts} = $packet->{ts} unless $session->{ts};
      }
      elsif ( $session->{buff} ) {
         $self->fail_session($session,
            'got server response before full buffer');
         return;
      }
      else {
         PTDEBUG && _d('Ignoring mid-stream server response');
         return;
      }
   }
   else {
      if ( $first_byte eq '00' ) { 
         if ( ($session->{state} || '') eq 'client_auth' ) {

            $session->{compress} = $session->{will_compress};
            delete $session->{will_compress};
            PTDEBUG && $session->{compress} && _d('Packets will be compressed');

            PTDEBUG && _d('Admin command: Connect');
            return $self->_make_event(
               {  cmd => 'Admin',
                  arg => 'administrator command: Connect',
                  ts  => $packet->{ts}, # Events are timestamped when they end
               },
               $packet, $session
            );
         }
         elsif ( $session->{cmd} ) {
            my $com = $session->{cmd}->{cmd};
            my $ok;
            if ( $com eq COM_STMT_PREPARE ) {
               PTDEBUG && _d('OK for prepared statement');
               $ok = parse_ok_prepared_statement_packet($data);
               if ( !$ok ) {
                  $self->fail_session($session,
                     'failed to parse OK prepared statement packet');
                  return;
               }
               my $sth_id = $ok->{sth_id};
               $session->{attribs}->{Statement_id} = $sth_id;

               $session->{sths}->{$sth_id} = $ok;
               $session->{sths}->{$sth_id}->{statement}
                  = $session->{cmd}->{arg};
            }
            else {
               $ok  = parse_ok_packet($data);
               if ( !$ok ) {
                  $self->fail_session($session, 'failed to parse OK packet');
                  return;
               }
            }

            my $arg;
            if ( $com eq COM_QUERY
                 || $com eq COM_STMT_EXECUTE || $com eq COM_STMT_RESET ) {
               $com = 'Query';
               $arg = $session->{cmd}->{arg};
            }
            elsif ( $com eq COM_STMT_PREPARE ) {
               $com = 'Query';
               $arg = "PREPARE $session->{cmd}->{arg}";
            }
            else {
               $arg = 'administrator command: '
                    . ucfirst(lc(substr($com_for{$com}, 4)));
               $com = 'Admin';
            }

            return $self->_make_event(
               {  cmd           => $com,
                  arg           => $arg,
                  ts            => $packet->{ts},
                  Insert_id     => $ok->{insert_id},
                  Warning_count => $ok->{warnings},
                  Rows_affected => $ok->{affected_rows},
               },
               $packet, $session
            );
         } 
         else {
            PTDEBUG && _d('Looks like an OK packet but session has no cmd');
         }
      }
      elsif ( $first_byte eq 'ff' ) {
         my $error = parse_error_packet($data);
         if ( !$error ) {
            $self->fail_session($session, 'failed to parse error packet');
            return;
         }
         my $event;

         if (   $session->{state} eq 'client_auth'
             || $session->{state} eq 'server_handshake' ) {
            PTDEBUG && _d('Connection failed');
            $event = {
               cmd      => 'Admin',
               arg      => 'administrator command: Connect',
               ts       => $packet->{ts},
               Error_no => $error->{errno},
            };
            $session->{attribs}->{Error_msg} = $error->{message};
            $session->{closed} = 1;  # delete session when done
            return $self->_make_event($event, $packet, $session);
         }
         elsif ( $session->{cmd} ) {
            my $com = $session->{cmd}->{cmd};
            my $arg;

            if ( $com eq COM_QUERY || $com eq COM_STMT_EXECUTE ) {
               $com = 'Query';
               $arg = $session->{cmd}->{arg};
            }
            else {
               $arg = 'administrator command: '
                    . ucfirst(lc(substr($com_for{$com}, 4)));
               $com = 'Admin';
            }

            $event = {
               cmd => $com,
               arg => $arg,
               ts  => $packet->{ts},
            };
            if ( $error->{errno} ) {
               $event->{Error_no} = $error->{errno};
            }
            $session->{attribs}->{Error_msg} = $error->{message};
            return $self->_make_event($event, $packet, $session);
         }
         else {
            PTDEBUG && _d('Looks like an error packet but client is not '
               . 'authenticating and session has no cmd');
         }
      }
      elsif ( $first_byte eq 'fe' && $packet->{mysql_data_len} < 9 ) {
         if ( $packet->{mysql_data_len} == 1
              && $session->{state} eq 'client_auth'
              && $packet->{number} == 2 )
         {
            PTDEBUG && _d('Server has old password table;',
               'client will resend password using old algorithm');
            $session->{state} = 'client_auth_resend';
         }
         else {
            PTDEBUG && _d('Got an EOF packet');
            $self->fail_session($session, 'got an unexpected EOF packet');
         }
      }
      else {
         if ( $session->{cmd} ) {
            PTDEBUG && _d('Got a row/field/result packet');
            my $com = $session->{cmd}->{cmd};
            PTDEBUG && _d('Responding to client', $com_for{$com});
            my $event = { ts  => $packet->{ts} };
            if ( $com eq COM_QUERY || $com eq COM_STMT_EXECUTE ) {
               $event->{cmd} = 'Query';
               $event->{arg} = $session->{cmd}->{arg};
            }
            else {
               $event->{arg} = 'administrator command: '
                    . ucfirst(lc(substr($com_for{$com}, 4)));
               $event->{cmd} = 'Admin';
            }

            if ( $packet->{complete} ) {
               my ( $warning_count, $status_flags )
                  = $data =~ m/fe(.{4})(.{4})\Z/;
               if ( $warning_count ) { 
                  $event->{Warnings} = to_num($warning_count);
                  my $flags = to_num($status_flags); # TODO set all flags?
                  $event->{No_good_index_used}
                     = $flags & SERVER_QUERY_NO_GOOD_INDEX_USED ? 1 : 0;
                  $event->{No_index_used}
                     = $flags & SERVER_QUERY_NO_INDEX_USED ? 1 : 0;
               }
            }

            return $self->_make_event($event, $packet, $session);
         }
         else {
            PTDEBUG && _d('Unknown in-stream server response');
         }
      }
   }

   return;
}

sub _packet_from_client {
   my ( $self, $packet, $session, $misc ) = @_;
   die "I need a packet"  unless $packet;
   die "I need a session" unless $session;

   PTDEBUG && _d('Packet is from client; state:', $session->{state}); 

   if ( ($session->{client_seq} || '') eq $packet->{seq} ) {
      push @{ $session->{client_retransmissions} }, $packet->{seq};
      PTDEBUG && _d('TCP retransmission');
      return;
   }
   $session->{client_seq} = $packet->{seq};

   my $data  = $packet->{data};
   my $ts    = $packet->{ts};

   if ( ($session->{state} || '') eq 'server_handshake' ) {
      PTDEBUG && _d('Expecting client authentication packet');
      my $handshake = parse_client_handshake_packet($data);
      if ( !$handshake ) {
         $self->fail_session($session, 'failed to parse client handshake');
         return;
      }
      $session->{state}         = 'client_auth';
      $session->{pos_in_log}    = $packet->{pos_in_log};
      $session->{user}          = $handshake->{user};
      $session->{db}            = $handshake->{db};

      $session->{will_compress} = $handshake->{flags}->{CLIENT_COMPRESS};
   }
   elsif ( ($session->{state} || '') eq 'client_auth_resend' ) {
      PTDEBUG && _d('Client resending password using old algorithm');
      $session->{state} = 'client_auth';
   }
   elsif ( ($session->{state} || '') eq 'awaiting_reply' ) {
      my $arg = $session->{cmd}->{arg} ? substr($session->{cmd}->{arg}, 0, 50)
              : 'unknown';
      PTDEBUG && _d('More data for previous command:', $arg, '...'); 
      return;
   }
   else {
      if ( $packet->{number} != 0 ) {
         $self->fail_session($session, 'client cmd not packet 0');
         return;
      }

      if ( !defined $session->{compress} ) {
         return unless $self->detect_compression($packet, $session);
         $data = $packet->{data};
      }

      my $com = parse_com_packet($data, $packet->{mysql_data_len});
      if ( !$com ) {
         $self->fail_session($session, 'failed to parse COM packet');
         return;
      }

      if ( $com->{code} eq COM_STMT_EXECUTE ) {
         PTDEBUG && _d('Execute prepared statement');
         my $exec = parse_execute_packet($com->{data}, $session->{sths});
         if ( !$exec ) {
            PTDEBUG && _d('Failed to parse execute packet');
            $session->{state} = undef;
            return;
         }
         $com->{data} = $exec->{arg};
         $session->{attribs}->{Statement_id} = $exec->{sth_id};
      }
      elsif ( $com->{code} eq COM_STMT_RESET ) {
         my $sth_id = get_sth_id($com->{data});
         if ( !$sth_id ) {
            $self->fail_session($session,
               'failed to parse prepared statement reset packet');
            return;
         }
         $com->{data} = "RESET $sth_id";
         $session->{attribs}->{Statement_id} = $sth_id;
      }

      $session->{state}      = 'awaiting_reply';
      $session->{pos_in_log} = $packet->{pos_in_log};
      $session->{ts}         = $ts;
      $session->{cmd}        = {
         cmd => $com->{code},
         arg => $com->{data},
      };

      if ( $com->{code} eq COM_QUIT ) { # Fire right away; will cleanup later.
         PTDEBUG && _d('Got a COM_QUIT');

         $session->{closed} = 1;  # delete session when done

         return $self->_make_event(
            {  cmd       => 'Admin',
               arg       => 'administrator command: Quit',
               ts        => $ts,
            },
            $packet, $session
         );
      }
      elsif ( $com->{code} eq COM_STMT_CLOSE ) {
         my $sth_id = get_sth_id($com->{data});
         if ( !$sth_id ) {
            $self->fail_session($session,
               'failed to parse prepared statement close packet');
            return;
         }
         delete $session->{sths}->{$sth_id};
         return $self->_make_event(
            {  cmd       => 'Query',
               arg       => "DEALLOCATE PREPARE $sth_id",
               ts        => $ts,
            },
            $packet, $session
         );
      }
   }

   return;
}

sub _make_event {
   my ( $self, $event, $packet, $session ) = @_;
   PTDEBUG && _d('Making event');

   $session->{raw_packets}  = [];
   $self->_delete_buff($session);

   if ( !$session->{thread_id} ) {
      PTDEBUG && _d('Giving session fake thread id', $self->{fake_thread_id});
      $session->{thread_id} = $self->{fake_thread_id}++;
   }

   my ($host, $port) = $session->{client} =~ m/((?:\d+\.){3}\d+)\:(\w+)/;
   my $new_event = {
      cmd        => $event->{cmd},
      arg        => $event->{arg},
      bytes      => length( $event->{arg} ),
      ts         => tcp_timestamp( $event->{ts} ),
      host       => $host,
      ip         => $host,
      port       => $port,
      db         => $session->{db},
      user       => $session->{user},
      Thread_id  => $session->{thread_id},
      pos_in_log => $session->{pos_in_log},
      Query_time => timestamp_diff($session->{ts}, $packet->{ts}),
      Rows_affected      => ($event->{Rows_affected} || 0),
      Warning_count      => ($event->{Warning_count} || 0),
      No_good_index_used => ($event->{No_good_index_used} ? 'Yes' : 'No'),
      No_index_used      => ($event->{No_index_used}      ? 'Yes' : 'No'),
   };
   @{$new_event}{keys %{$session->{attribs}}} = values %{$session->{attribs}};
   foreach my $opt_attrib ( qw(Error_no) ) {
      if ( defined $event->{$opt_attrib} ) {
         $new_event->{$opt_attrib} = $event->{$opt_attrib};
      }
   }
   PTDEBUG && _d('Properties of event:', Dumper($new_event));

   delete $session->{cmd};

   $session->{state} = undef;

   $session->{attribs} = {};

   $session->{n_queries}++;
   $session->{server_retransmissions} = [];
   $session->{client_retransmissions} = [];

   return $new_event;
}

sub tcp_timestamp {
   my ( $ts ) = @_;
   $ts =~ s/^\d\d(\d\d)-(\d\d)-(\d\d)/$1$2$3/;
   return $ts;
}

sub timestamp_diff {
   my ( $start, $end ) = @_;
   my $sd = substr($start, 0, 11, '');
   my $ed = substr($end,   0, 11, '');
   my ( $sh, $sm, $ss ) = split(/:/, $start);
   my ( $eh, $em, $es ) = split(/:/, $end);
   my $esecs = ($eh * 3600 + $em * 60 + $es);
   my $ssecs = ($sh * 3600 + $sm * 60 + $ss);
   if ( $sd eq $ed ) {
      return sprintf '%.6f', $esecs - $ssecs;
   }
   else { # Assume only one day boundary has been crossed, no DST, etc
      return sprintf '%.6f', ( 86_400 - $ssecs ) + $esecs;
   }
}

sub to_string {
   my ( $data ) = @_;
   return pack('H*', $data);
}

sub unpack_string {
   my ( $data ) = @_;
   my $len        = 0;
   my $encode_len = 0;
   ($data, $len, $encode_len) = decode_len($data);
   my $t = 'H' . ($len ? $len * 2 : '*');
   $data = pack($t, $data);
   return "\"$data\"", $encode_len + $len;
}

sub decode_len {
   my ( $data ) = @_;
   return unless $data;

   my $first_byte = to_num(substr($data, 0, 2, ''));

   my $len;
   my $encode_len;
   if ( $first_byte <= 251 ) {
      $len        = $first_byte;
      $encode_len = 1;
   }
   elsif ( $first_byte == 252 ) {
      $len        = to_num(substr($data, 4, ''));
      $encode_len = 2;
   }
   elsif ( $first_byte == 253 ) {
      $len        = to_num(substr($data, 6, ''));
      $encode_len = 3;
   }
   elsif ( $first_byte == 254 ) {
      $len        = to_num(substr($data, 16, ''));
      $encode_len = 8;
   }
   else {
      PTDEBUG && _d('data:', $data, 'first byte:', $first_byte);
      die "Invalid length encoded byte: $first_byte";
   }

   PTDEBUG && _d('len:', $len, 'encode len', $encode_len);
   return $data, $len, $encode_len;
}

sub to_num {
   my ( $str, $len ) = @_;
   if ( $len ) {
      $str = substr($str, 0, $len * 2);
   }
   my @bytes = $str =~ m/(..)/g;
   my $result = 0;
   foreach my $i ( 0 .. $#bytes ) {
      $result += hex($bytes[$i]) * (16 ** ($i * 2));
   }
   return $result;
}

sub to_double {
   my ( $str ) = @_;
   return unpack('d', pack('H*', $str));
}

sub get_lcb {
   my ( $string ) = @_;
   my $first_byte = hex(substr($$string, 0, 2, ''));
   if ( $first_byte < 251 ) {
      return $first_byte;
   }
   elsif ( $first_byte == 252 ) {
      return to_num(substr($$string, 0, 4, ''));
   }
   elsif ( $first_byte == 253 ) {
      return to_num(substr($$string, 0, 6, ''));
   }
   elsif ( $first_byte == 254 ) {
      return to_num(substr($$string, 0, 16, ''));
   }
}

sub parse_error_packet {
   my ( $data ) = @_;
   return unless $data;
   PTDEBUG && _d('ERROR data:', $data);
   if ( length $data < 16 ) {
      PTDEBUG && _d('Error packet is too short:', $data);
      return;
   }
   my $errno    = to_num(substr($data, 0, 4));
   my $marker   = to_string(substr($data, 4, 2));
   my $sqlstate = '';
   my $message  = '';
   if ( $marker eq '#' ) {
      $sqlstate = to_string(substr($data, 6, 10));
      $message  = to_string(substr($data, 16));
   }
   else {
      $marker  = '';
      $message = to_string(substr($data, 4));
   }
   return unless $message;
   my $pkt = {
      errno    => $errno,
      sqlstate => $marker . $sqlstate,
      message  => $message,
   };
   PTDEBUG && _d('Error packet:', Dumper($pkt));
   return $pkt;
}

sub parse_ok_packet {
   my ( $data ) = @_;
   return unless $data;
   PTDEBUG && _d('OK data:', $data);
   if ( length $data < 12 ) {
      PTDEBUG && _d('OK packet is too short:', $data);
      return;
   }
   my $affected_rows = get_lcb(\$data);
   my $insert_id     = get_lcb(\$data);
   my $status        = to_num(substr($data, 0, 4, ''));
   my $warnings      = to_num(substr($data, 0, 4, ''));
   my $message       = to_string($data);
   my $pkt = {
      affected_rows => $affected_rows,
      insert_id     => $insert_id,
      status        => $status,
      warnings      => $warnings,
      message       => $message,
   };
   PTDEBUG && _d('OK packet:', Dumper($pkt));
   return $pkt;
}

sub parse_ok_prepared_statement_packet {
   my ( $data ) = @_;
   return unless $data;
   PTDEBUG && _d('OK prepared statement data:', $data);
   if ( length $data < 8 ) {
      PTDEBUG && _d('OK prepared statement packet is too short:', $data);
      return;
   }
   my $sth_id     = to_num(substr($data, 0, 8, ''));
   my $num_cols   = to_num(substr($data, 0, 4, ''));
   my $num_params = to_num(substr($data, 0, 4, ''));
   my $pkt = {
      sth_id     => $sth_id,
      num_cols   => $num_cols,
      num_params => $num_params,
   };
   PTDEBUG && _d('OK prepared packet:', Dumper($pkt));
   return $pkt;
}

sub parse_server_handshake_packet {
   my ( $data ) = @_;
   return unless $data;
   PTDEBUG && _d('Server handshake data:', $data);
   my $handshake_pattern = qr{
      ^                 # -----                ----
      (.+?)00           # n Null-Term String   server_version
      (.{8})            # 4                    thread_id
      .{16}             # 8                    scramble_buff
      .{2}              # 1                    filler: always 0x00
      (.{4})            # 2                    server_capabilities
      .{2}              # 1                    server_language
      .{4}              # 2                    server_status
      .{26}             # 13                   filler: always 0x00
   }x;
   my ( $server_version, $thread_id, $flags ) = $data =~ m/$handshake_pattern/;
   my $pkt = {
      server_version => to_string($server_version),
      thread_id      => to_num($thread_id),
      flags          => parse_flags($flags),
   };
   PTDEBUG && _d('Server handshake packet:', Dumper($pkt));
   return $pkt;
}

sub parse_client_handshake_packet {
   my ( $data ) = @_;
   return unless $data;
   PTDEBUG && _d('Client handshake data:', $data);
   my ( $flags, $user, $buff_len ) = $data =~ m{
      ^
      (.{8})         # Client flags
      .{10}          # Max packet size, charset
      (?:00){23}     # Filler
      ((?:..)+?)00   # Null-terminated user name
      (..)           # Length-coding byte for scramble buff
   }x;

   if ( !$buff_len ) {
      PTDEBUG && _d('Did not match client handshake packet');
      return;
   }

   my $code_len = hex($buff_len);
   my $db;
   
   my $capability_flags = to_num($flags); # $flags is stored as little endian.

   if ($capability_flags & $flag_for{CLIENT_CONNECT_WITH_DB}) {
      ( $db ) = $data =~ m!
         ^.{64}${user}00..   # Everything matched before
         (?:..){$code_len}   # The scramble buffer
         (.*?)00.*\Z         # The database name
      !x;
   }

   my $pkt = {
      user  => to_string($user),
      db    => $db ? to_string($db) : '',
      flags => parse_flags($flags),
   };
   PTDEBUG && _d('Client handshake packet:', Dumper($pkt));
   return $pkt;
}

sub parse_com_packet {
   my ( $data, $len ) = @_;
   return unless $data && $len;
   PTDEBUG && _d('COM data:',
      (substr($data, 0, 100).(length $data > 100 ? '...' : '')),
      'len:', $len);
   my $code = substr($data, 0, 2);
   my $com  = $com_for{$code};
   if ( !$com ) {
      PTDEBUG && _d('Did not match COM packet');
      return;
   }
   if (    $code ne COM_STMT_EXECUTE
        && $code ne COM_STMT_CLOSE
        && $code ne COM_STMT_RESET )
   {
      $data = to_string(substr($data, 2, ($len - 1) * 2));
   }
   my $pkt = {
      code => $code,
      com  => $com,
      data => $data,
   };
   PTDEBUG && _d('COM packet:', Dumper($pkt));
   return $pkt;
}

sub parse_execute_packet {
   my ( $data, $sths ) = @_;
   return unless $data && $sths;

   my $sth_id = to_num(substr($data, 2, 8));
   return unless defined $sth_id;

   my $sth = $sths->{$sth_id};
   if ( !$sth ) {
      PTDEBUG && _d('Skipping unknown statement handle', $sth_id);
      return;
   }
   my $null_count  = int(($sth->{num_params} + 7) / 8) || 1;
   my $null_bitmap = to_num(substr($data, 20, $null_count * 2));
   PTDEBUG && _d('NULL bitmap:', $null_bitmap, 'count:', $null_count);
   
   substr($data, 0, 20 + ($null_count * 2), '');

   my $new_params = to_num(substr($data, 0, 2, ''));
   my @types; 
   if ( $new_params ) {
      PTDEBUG && _d('New param types');
      for my $i ( 0..($sth->{num_params}-1) ) {
         my $type = to_num(substr($data, 0, 4, ''));
         push @types, $type_for{$type};
         PTDEBUG && _d('Param', $i, 'type:', $type, $type_for{$type});
      }
      $sth->{types} = \@types;
   }
   else {
      @types = @{$sth->{types}} if $data;
   }


   my $arg  = $sth->{statement};
   PTDEBUG && _d('Statement:', $arg);
   for my $i ( 0..($sth->{num_params}-1) ) {
      my $val;
      my $len;  # in bytes
      if ( $null_bitmap & (2**$i) ) {
         PTDEBUG && _d('Param', $i, 'is NULL (bitmap)');
         $val = 'NULL';
         $len = 0;
      }
      else {
         if ( $unpack_type{$types[$i]} ) {
            ($val, $len) = $unpack_type{$types[$i]}->($data);
         }
         else {
            PTDEBUG && _d('No handler for param', $i, 'type', $types[$i]);
            $val = '?';
            $len = 0;
         }
      }

      PTDEBUG && _d('Param', $i, 'val:', $val);
      $arg =~ s/\?/$val/;

      substr($data, 0, $len * 2, '') if $len;
   }

   my $pkt = {
      sth_id => $sth_id,
      arg    => "EXECUTE $arg",
   };
   PTDEBUG && _d('Execute packet:', Dumper($pkt));
   return $pkt;
}

sub get_sth_id {
   my ( $data ) = @_;
   return unless $data;
   my $sth_id = to_num(substr($data, 2, 8));
   return $sth_id;
}

sub parse_flags {
   my ( $flags ) = @_;
   die "I need flags" unless $flags;
   PTDEBUG && _d('Flag data:', $flags);
   my %flags     = %flag_for;
   my $flags_dec = to_num($flags);
   foreach my $flag ( keys %flag_for ) {
      my $flagno    = $flag_for{$flag};
      $flags{$flag} = ($flags_dec & $flagno ? 1 : 0);
   }
   return \%flags;
}

sub uncompress_data {
   my ( $data, $len ) = @_;
   die "I need data" unless $data;
   die "I need a len argument" unless $len;
   die "I need a scalar reference to data" unless ref $data eq 'SCALAR';
   PTDEBUG && _d('Uncompressing data');
   our $InflateError;

   my $comp_bin_data = pack('H*', $$data);

   my $uncomp_bin_data = '';
   my $z = new IO::Uncompress::Inflate(
      \$comp_bin_data
   ) or die "IO::Uncompress::Inflate failed: $InflateError";
   my $status = $z->read(\$uncomp_bin_data, $len)
      or die "IO::Uncompress::Inflate failed: $InflateError";

   my $uncomp_data = unpack('H*', $uncomp_bin_data);

   return \$uncomp_data;
}

sub detect_compression {
   my ( $self, $packet, $session ) = @_;
   PTDEBUG && _d('Checking for client compression');
   my $com = parse_com_packet($packet->{data}, $packet->{mysql_data_len});
   if ( $com && $com->{code} eq COM_SLEEP ) {
      PTDEBUG && _d('Client is using compression');
      $session->{compress} = 1;

      $packet->{data} = $packet->{mysql_hdr} . $packet->{data};
      return 0 unless $self->uncompress_packet($packet, $session);
      remove_mysql_header($packet);
   }
   else {
      PTDEBUG && _d('Client is NOT using compression');
      $session->{compress} = 0;
   }
   return 1;
}

sub uncompress_packet {
   my ( $self, $packet, $session ) = @_;
   die "I need a packet"  unless $packet;
   die "I need a session" unless $session;


   my $data;
   my $comp_hdr;
   my $comp_data_len;
   my $pkt_num;
   my $uncomp_data_len;
   eval {
      $data            = \$packet->{data};
      $comp_hdr        = substr($$data, 0, 14, '');
      $comp_data_len   = to_num(substr($comp_hdr, 0, 6));
      $pkt_num         = to_num(substr($comp_hdr, 6, 2));
      $uncomp_data_len = to_num(substr($comp_hdr, 8, 6));
      PTDEBUG && _d('Compression header data:', $comp_hdr,
         'compressed data len (bytes)', $comp_data_len,
         'number', $pkt_num,
         'uncompressed data len (bytes)', $uncomp_data_len);
   };
   if ( $EVAL_ERROR ) {
      $session->{EVAL_ERROR} = $EVAL_ERROR;
      $self->fail_session($session, 'failed to parse compression header');
      return 0;
   }

   if ( $uncomp_data_len ) {
      eval {
         $data = uncompress_data($data, $uncomp_data_len);
         $packet->{data} = $$data;
      };
      if ( $EVAL_ERROR ) {
         $session->{EVAL_ERROR} = $EVAL_ERROR;
         $self->fail_session($session, 'failed to uncompress data');
         die "Cannot uncompress packet.  Check that IO::Uncompress::Inflate "
            . "is installed.\nError: $EVAL_ERROR";
      }
   }
   else {
      PTDEBUG && _d('Packet is not really compressed');
      $packet->{data} = $$data;
   }

   return 1;
}

sub remove_mysql_header {
   my ( $packet ) = @_;
   die "I need a packet" unless $packet;

   my $mysql_hdr      = substr($packet->{data}, 0, 8, '');
   my $mysql_data_len = to_num(substr($mysql_hdr, 0, 6));
   my $pkt_num        = to_num(substr($mysql_hdr, 6, 2));
   PTDEBUG && _d('MySQL packet: header data', $mysql_hdr,
      'data len (bytes)', $mysql_data_len, 'number', $pkt_num);

   $packet->{mysql_hdr}      = $mysql_hdr;
   $packet->{mysql_data_len} = $mysql_data_len;
   $packet->{number}         = $pkt_num;

   return;
}

sub _delete_buff {
   my ( $self, $session ) = @_;
   map { delete $session->{$_} } qw(buff buff_left mysql_data_len);
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
# End MySQLProtocolParser package
# ###########################################################################

# ###########################################################################
# SlowLogParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/SlowLogParser.pm
#   t/lib/SlowLogParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package SlowLogParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

sub new {
   my ( $class ) = @_;
   my $self = {
      pending => [],
      last_event_offset => undef,
   };
   return bless $self, $class;
}

my $slow_log_ts_line = qr/^# Time: ((?:[0-9: ]{15})|(?:[-0-9: T]{19}))/;
my $slow_log_uh_line = qr/# User\@Host: ([^\[]+|\[[^[]+\]).*?@ (\S*) \[(.*)\]\s*(?:Id:\s*(\d+))?/;
my $slow_log_hd_line = qr{
      ^(?:
      T[cC][pP]\s[pP]ort:\s+\d+ # case differs on windows/unix
      |
      [/A-Z].*mysqld,\sVersion.*(?:started\swith:|embedded\slibrary)
      |
      Time\s+Id\s+Command
      ).*\n
   }xm;

sub parse_event {
   my ( $self, %args ) = @_;
   my @required_args = qw(next_event tell);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($next_event, $tell) = @args{@required_args};

   my $pending = $self->{pending};
   local $INPUT_RECORD_SEPARATOR = ";\n#";
   my $trimlen    = length($INPUT_RECORD_SEPARATOR);
   my $pos_in_log = $tell->();
   my $stmt;

   EVENT:
   while (
         defined($stmt = shift @$pending)
      or defined($stmt = $next_event->())
   ) {
      my @properties = ('cmd', 'Query', 'pos_in_log', $pos_in_log);
      $self->{last_event_offset} = $pos_in_log;
      $pos_in_log = $tell->();

      if ( $stmt =~ s/$slow_log_hd_line//go ){ # Throw away header lines in log
         my @chunks = split(/$INPUT_RECORD_SEPARATOR/o, $stmt);
         if ( @chunks > 1 ) {
            PTDEBUG && _d("Found multiple chunks");
            $stmt = shift @chunks;
            unshift @$pending, @chunks;
         }
      }

      $stmt = '#' . $stmt unless $stmt =~ m/\A#/;
      $stmt =~ s/;\n#?\Z//;


      my ($got_ts, $got_uh, $got_ac, $got_db, $got_set, $got_embed);
      my $pos = 0;
      my $len = length($stmt);
      my $found_arg = 0;
      LINE:
      while ( $stmt =~ m/^(.*)$/mg ) { # /g is important, requires scalar match.
         $pos     = pos($stmt);  # Be careful not to mess this up!
         my $line = $1;          # Necessary for /g and pos() to work.
         PTDEBUG && _d($line);

         if ($line =~ m/^(?:#|use |SET (?:last_insert_id|insert_id|timestamp))/o) {

            if ( !$got_ts && (my ( $time ) = $line =~ m/$slow_log_ts_line/o)) {
               PTDEBUG && _d("Got ts", $time);
               push @properties, 'ts', $time;
               ++$got_ts;
               if ( !$got_uh
                  && ( my ( $user, $host, $ip, $thread_id ) = $line =~ m/$slow_log_uh_line/o )
               ) {
                  PTDEBUG && _d("Got user, host, ip", $user, $host, $ip);
                  $host ||= $ip;  # sometimes host is missing when using skip-name-resolve (LP #issue 1262456)
                  push @properties, 'user', $user, 'host', $host, 'ip', $ip;
                  if ( $thread_id ) {  
                     push @properties, 'Thread_id', $thread_id;
                 }
                 ++$got_uh;
               }
            }

            elsif ( !$got_uh
                  && ( my ( $user, $host, $ip, $thread_id ) = $line =~ m/$slow_log_uh_line/o )
            ) {
                  PTDEBUG && _d("Got user, host, ip", $user, $host, $ip);
                  $host ||= $ip;  # sometimes host is missing when using skip-name-resolve (LP #issue 1262456)
                  push @properties, 'user', $user, 'host', $host, 'ip', $ip;
                  if ( $thread_id ) {       
                     push @properties, 'Thread_id', $thread_id;
                 }
               ++$got_uh;
            }

            elsif (!$got_ac && $line =~ m/^# (?:administrator command:.*)$/) {
               PTDEBUG && _d("Got admin command");
               $line =~ s/^#\s+//;  # string leading "# ".
               push @properties, 'cmd', 'Admin', 'arg', $line;
               push @properties, 'bytes', length($properties[-1]);
               ++$found_arg;
               ++$got_ac;
            }

            elsif ( $line =~ m/^# +[A-Z][A-Za-z_]+: \S+/ ) { # Make the test cheap!
               PTDEBUG && _d("Got some line with properties");

               if ( $line =~ m/Schema:\s+\w+: / ) {
                  PTDEBUG && _d('Removing empty Schema attrib');
                  $line =~ s/Schema:\s+//;
                  PTDEBUG && _d($line);
               }

               my @temp = $line =~ m/(\w+):\s+(\S+|\Z)/g;
               push @properties, @temp;
            }

            elsif ( !$got_db && (my ( $db ) = $line =~ m/^use ([^;]+)/ ) ) {
               PTDEBUG && _d("Got a default database:", $db);
               push @properties, 'db', $db;
               ++$got_db;
            }

            elsif (!$got_set && (my ($setting) = $line =~ m/^SET\s+([^;]*)/)) {
               PTDEBUG && _d("Got some setting:", $setting);
               push @properties, split(/,|\s*=\s*/, $setting);
               ++$got_set;
            }

            if ( !$found_arg && $pos == $len ) {
               PTDEBUG && _d("Did not find arg, looking for special cases");
               local $INPUT_RECORD_SEPARATOR = ";\n";  # get next line
               if ( defined(my $l = $next_event->()) ) {
                  if ( $l =~ /^\s*[A-Z][a-z_]+: / ) {
                     PTDEBUG && _d("Found NULL query before", $l);
                     local $INPUT_RECORD_SEPARATOR = ";\n#";
                     my $rest_of_event = $next_event->();
                     push @{$self->{pending}}, $l . $rest_of_event;
                     push @properties, 'cmd', 'Query', 'arg', '/* No query */';
                     push @properties, 'bytes', 0;
                     $found_arg++;
                  }
                  else {
                     chomp $l;
                     $l =~ s/^\s+//;
                     PTDEBUG && _d("Found admin statement", $l);
                     push @properties, 'cmd', 'Admin', 'arg', $l;
                     push @properties, 'bytes', length($properties[-1]);
                     $found_arg++;
                  }
               }
               else {
                  PTDEBUG && _d("I can't figure out what to do with this line");
                  next EVENT;
               }
            }
         }
         else {
            PTDEBUG && _d("Got the query/arg line");
            my $arg = substr($stmt, $pos - length($line));
            push @properties, 'arg', $arg, 'bytes', length($arg);
            if ( $args{misc} && $args{misc}->{embed}
               && ( my ($e) = $arg =~ m/($args{misc}->{embed})/)
            ) {
               push @properties, $e =~ m/$args{misc}->{capture}/g;
            }
            last LINE;
         }
      }

      PTDEBUG && _d('Properties of event:', Dumper(\@properties));
      my $event = { @properties };
      if ( !$event->{arg} ) {
         PTDEBUG && _d('Partial event, no arg');
      }
      else {
         $self->{last_event_offset} = undef;
         if ( $args{stats} ) {
            $args{stats}->{events_read}++;
            $args{stats}->{events_parsed}++;
         }
      }
      return $event;
   } # EVENT

   @$pending = ();
   $args{oktorun}->(0) if $args{oktorun};
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
# End SlowLogParser package
# ###########################################################################

# ###########################################################################
# SlowLogWriter package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/SlowLogWriter.pm
#   t/lib/SlowLogWriter.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package SlowLogWriter;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class ) = @_;
   bless {}, $class;
}

sub write {
   my ( $self, $fh, $event, $field ) = @_;
   if ( $event->{ts} ) {
      print $fh "# Time: $event->{ts}\n";
   }
   if ( $event->{user} ) {
      printf $fh "# User\@Host: %s[%s] \@ %s []\n",
         $event->{user}, $event->{user}, $event->{host};
   }
   if ( $event->{ip} && $event->{port} ) {
      printf $fh "# Client: $event->{ip}:$event->{port}\n";
   }
   if ( $event->{Thread_id} ) {
      printf $fh "# Thread_id: $event->{Thread_id}\n";
   }

   my $percona_patched = exists $event->{QC_Hit} ? 1 : 0;

   printf $fh
      "# Query_time: %.6f  Lock_time: %.6f  Rows_sent: %d  Rows_examined: %d\n",
      map { $_ || 0 }
         @{$event}{qw(Query_time Lock_time Rows_sent Rows_examined)};

   if ( $percona_patched ) {
      printf $fh
         "# QC_Hit: %s  Full_scan: %s  Full_join: %s  Tmp_table: %s  Tmp_table_on_disk: %s\n# Filesort: %s  Filesort_on_disk: %s  Merge_passes: %d\n",
         map { $_ || 0 }
            @{$event}{qw(QC_Hit Full_scan Full_join Tmp_table Tmp_table_on_disk Filesort Filesort_on_disk Merge_passes)};

      if ( exists $event->{InnoDB_IO_r_ops} ) {
         printf $fh
            "#   InnoDB_IO_r_ops: %d  InnoDB_IO_r_bytes: %d  InnoDB_IO_r_wait: %s\n#   InnoDB_rec_lock_wait: %s  InnoDB_queue_wait: %s\n#   InnoDB_pages_distinct: %d\n",
            map { $_ || 0 }
               @{$event}{qw(InnoDB_IO_r_ops InnoDB_IO_r_bytes InnoDB_IO_r_wait InnoDB_rec_lock_wait InnoDB_queue_wait InnoDB_pages_distinct)};

      } 
      else {
         printf $fh "# No InnoDB statistics available for this query\n";
      }
   }

   if ( $event->{db} ) {
      printf $fh "use %s;\n", $event->{db};
   }
   if ( $event->{arg} =~ m/^administrator command/ ) {
      print $fh '# ';
   }
   if ($field && $event->{$field}) {
       print $fh $event->{$field}, ";\n";
   } else {
       print $fh $event->{arg}, ";\n";
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
# End SlowLogWriter package
# ###########################################################################

# ###########################################################################
# EventAggregator package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/EventAggregator.pm
#   t/lib/EventAggregator.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package EventAggregator;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use List::Util qw(min max);
use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

use Digest::MD5 qw(md5);

use constant BUCK_SIZE   => 1.05;
use constant BASE_LOG    => log(BUCK_SIZE);
use constant BASE_OFFSET => abs(1 - log(0.000001) / BASE_LOG); # 284.1617969
use constant NUM_BUCK    => 1000;
use constant MIN_BUCK    => .000001;

my @buck_vals = map { bucket_value($_); } (0..NUM_BUCK-1);

sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(groupby worst) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $attributes = $args{attributes} || {};
   my $self = {
      groupby        => $args{groupby},
      detect_attribs => scalar keys %$attributes == 0 ? 1 : 0,
      all_attribs    => [ keys %$attributes ],
      ignore_attribs => {
         map  { $_ => $args{attributes}->{$_} }
         grep { $_ ne $args{groupby} }
         @{$args{ignore_attributes}}
      },
      attributes     => {
         map  { $_ => $args{attributes}->{$_} }
         grep { $_ ne $args{groupby} }
         keys %$attributes
      },
      alt_attribs    => {
         map  { $_ => make_alt_attrib(@{$args{attributes}->{$_}}) }
         grep { $_ ne $args{groupby} }
         keys %$attributes
      },
      worst          => $args{worst},
      unroll_limit   => $ENV{PT_QUERY_DIGEST_CHECK_ATTRIB_LIMIT} || 1000,
      attrib_limit   => $args{attrib_limit},
      result_classes => {},
      result_globals => {},
      result_samples => {},
      class_metrics  => {},
      global_metrics => {},
      n_events       => 0,
      unrolled_loops => undef,
      type_for       => { %{$args{type_for} || { Query_time => 'num' }} },
   };
   return bless $self, $class;
}

sub reset_aggregated_data {
   my ( $self ) = @_;
   foreach my $class ( values %{$self->{result_classes}} ) {
      foreach my $attrib ( values %$class ) {
         delete @{$attrib}{keys %$attrib};
      }
   }
   foreach my $class ( values %{$self->{result_globals}} ) {
      delete @{$class}{keys %$class};
   }
   delete @{$self->{result_samples}}{keys %{$self->{result_samples}}};
   $self->{n_events} = 0;
}

sub aggregate {
   my ( $self, $event ) = @_;

   my $group_by = $event->{$self->{groupby}};
   return unless defined $group_by;

   $self->{n_events}++;
   PTDEBUG && _d('Event', $self->{n_events});

   return $self->{unrolled_loops}->($self, $event, $group_by)
      if $self->{unrolled_loops};

   if ( $self->{n_events} <= $self->{unroll_limit} ) {

      $self->add_new_attributes($event) if $self->{detect_attribs};

      ATTRIB:
      foreach my $attrib ( keys %{$self->{attributes}} ) {

         if ( !exists $event->{$attrib} ) {
            PTDEBUG && _d("attrib doesn't exist in event:", $attrib);
            my $alt_attrib = $self->{alt_attribs}->{$attrib}->($event);
            PTDEBUG && _d('alt attrib:', $alt_attrib);
            next ATTRIB unless $alt_attrib;
         }

         GROUPBY:
         foreach my $val ( ref $group_by ? @$group_by : ($group_by) ) {
            my $class_attrib  = $self->{result_classes}->{$val}->{$attrib} ||= {};
            my $global_attrib = $self->{result_globals}->{$attrib} ||= {};
            my $samples       = $self->{result_samples};
            my $handler = $self->{handlers}->{ $attrib };
            if ( !$handler ) {
               $handler = $self->make_handler(
                  event      => $event,
                  attribute  => $attrib,
                  alternates => $self->{attributes}->{$attrib},
                  worst      => $self->{worst} eq $attrib,
               );
               $self->{handlers}->{$attrib} = $handler;
            }
            next GROUPBY unless $handler;
            $samples->{$val} ||= $event; # Initialize to the first event.
            $handler->($event, $class_attrib, $global_attrib, $samples, $group_by);
         }
      }
   }
   else {
      $self->_make_unrolled_loops($event);
      $self->{unrolled_loops}->($self, $event, $group_by);
   }

   return;
}

sub _make_unrolled_loops {
   my ( $self, $event ) = @_;

   my $group_by = $event->{$self->{groupby}};

   my @attrs   = grep { $self->{handlers}->{$_} } keys %{$self->{attributes}};
   my $globs   = $self->{result_globals}; # Global stats for each
   my $samples = $self->{result_samples};

   my @lines = (
      'my ( $self, $event, $group_by ) = @_;',
      'my ($val, $class, $global, $idx);',
      (ref $group_by ? ('foreach my $group_by ( @$group_by ) {') : ()),
      'my $temp = $self->{result_classes}->{ $group_by }
         ||= { map { $_ => { } } @attrs };',
      '$samples->{$group_by} ||= $event;', # Always start with the first.
   );
   foreach my $i ( 0 .. $#attrs ) {
      push @lines, (
         '$class  = $temp->{\''  . $attrs[$i] . '\'};',
         '$global = $globs->{\'' . $attrs[$i] . '\'};',
         $self->{unrolled_for}->{$attrs[$i]},
      );
   }
   if ( ref $group_by ) {
      push @lines, '}'; # Close the loop opened above
   }
   @lines = map { s/^/   /gm; $_ } @lines; # Indent for debugging
   unshift @lines, 'sub {';
   push @lines, '}';

   my $code = join("\n", @lines);
   PTDEBUG && _d('Unrolled subroutine:', @lines);
   my $sub = eval $code;
   die $EVAL_ERROR if $EVAL_ERROR;
   $self->{unrolled_loops} = $sub;

   return;
}

sub results {
   my ( $self ) = @_;
   return {
      classes => $self->{result_classes},
      globals => $self->{result_globals},
      samples => $self->{result_samples},
   };
}

sub set_results {
   my ( $self, $results ) = @_;
   $self->{result_classes} = $results->{classes};
   $self->{result_globals} = $results->{globals};
   $self->{result_samples} = $results->{samples};
   return;
}

sub stats {
   my ( $self ) = @_;
   return {
      classes => $self->{class_metrics},
      globals => $self->{global_metrics},
   };
}

sub attributes {
   my ( $self ) = @_;
   return $self->{type_for};
}

sub set_attribute_types {
   my ( $self, $attrib_types ) = @_;
   $self->{type_for} = $attrib_types;
   return;
}

sub type_for {
   my ( $self, $attrib ) = @_;
   return $self->{type_for}->{$attrib};
}

sub make_handler {
   my ( $self, %args ) = @_;
   my @required_args = qw(event attribute);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($event, $attrib) = @args{@required_args};

   my $val;
   eval { $val= $self->_get_value(%args); };
   if ( $EVAL_ERROR ) {
      PTDEBUG && _d("Cannot make", $attrib, "handler:", $EVAL_ERROR);
      return;
   }
   return unless defined $val; # can't determine type if it's undef

   my $float_re = qr{[+-]?(?:(?=\d|[.])\d+(?:[.])\d{0,})(?:E[+-]?\d+)?}i;
   my $type = $self->type_for($attrib)           ? $self->type_for($attrib)
            : $attrib =~ m/_crc$/                ? 'string'
            : $val    =~ m/^(?:\d+|$float_re)$/o ? 'num'
            : $val    =~ m/^(?:Yes|No)$/         ? 'bool'
            :                                      'string';
   PTDEBUG && _d('Type for', $attrib, 'is', $type, '(sample:', $val, ')');
   $self->{type_for}->{$attrib} = $type;

   my @lines;

   my %track = (
      sum => $type =~ m/num|bool/    ? 1 : 0,  # sum of values
      unq => $type =~ m/bool|string/ ? 1 : 0,  # count of unique values seen
      all => $type eq 'num'          ? 1 : 0,  # all values in bucketed list
   );

   my $trf = ($type eq 'bool') ? q{(($val || '') eq 'Yes') ? 1 : 0}
           :                     undef;
   if ( $trf ) {
      push @lines, q{$val = } . $trf . ';';
   }

   if ( $attrib eq 'Query_time' ) {
      push @lines, (
         '$val =~ s/^(\d+(?:\.\d+)?).*/$1/;',
         '$event->{\''.$attrib.'\'} = $val;',
      );
   }

   if ( $type eq 'num' && $self->{attrib_limit} ) {
      push @lines, (
         "if ( \$val > $self->{attrib_limit} ) {",
         '   $val = $class->{last} ||= 0;',
         '}',
         '$class->{last} = $val;',
      );
   }

   my $lt = $type eq 'num' ? '<' : 'lt';
   my $gt = $type eq 'num' ? '>' : 'gt';
   foreach my $place ( qw($class $global) ) {
      my @tmp;  # hold lines until PLACE placeholder is replaced

      push @tmp, '++PLACE->{cnt};';  # count of all values seen

      if ( $attrib =~ m/_crc$/ ) {
         push @tmp, '$val = $val % 1_000;';
      }

      push @tmp, (
         'PLACE->{min} = $val if !defined PLACE->{min} || $val '
            . $lt . ' PLACE->{min};',
      );
      push @tmp, (
         'PLACE->{max} = $val if !defined PLACE->{max} || $val '
         . $gt . ' PLACE->{max};',
      );
      if ( $track{sum} ) {
         push @tmp, 'PLACE->{sum} += $val;';
      }

      if ( $track{all} ) {
         push @tmp, (
            'exists PLACE->{all} or PLACE->{all} = {};',
            '++PLACE->{all}->{ EventAggregator::bucket_idx($val) };',
         );
      }

      push @lines, map { s/PLACE/$place/g; $_ } @tmp;
   }

   if ( $track{unq} ) {
      push @lines, '++$class->{unq}->{$val}';
   }

   if ( $args{worst} ) {
      my $op = $type eq 'num' ? '>=' : 'ge';
      push @lines, (
         'if ( $val ' . $op . ' ($class->{max} || 0) ) {',
         '   $samples->{$group_by} = $event;',
         '}',
      );
   }

   my @unrolled = (
      "\$val = \$event->{'$attrib'};", 
      
      ( map  { "\$val = \$event->{'$_'} unless defined \$val;" }
        grep { $_ ne $attrib } @{$args{alternates}}
      ),
      
      'defined $val && do {',
         @lines,
      '};',
   );
   $self->{unrolled_for}->{$attrib} = join("\n", @unrolled);

   my @code = (
      'sub {',
         'my ( $event, $class, $global, $samples, $group_by ) = @_;',
         'my ($val, $idx);',

         $self->{unrolled_for}->{$attrib},

         'return;',
      '}',
   );
   $self->{code_for}->{$attrib} = join("\n", @code);
   PTDEBUG && _d($attrib, 'handler code:', $self->{code_for}->{$attrib});
   my $sub = eval $self->{code_for}->{$attrib};
   if ( $EVAL_ERROR ) {
      die "Failed to compile $attrib handler code: $EVAL_ERROR";
   }

   return $sub;
}

sub bucket_idx {
   my ( $val ) = @_;
   return 0 if $val < MIN_BUCK;
   my $idx = int(BASE_OFFSET + log($val)/BASE_LOG);
   return $idx > (NUM_BUCK-1) ? (NUM_BUCK-1) : $idx;
}

sub bucket_value {
   my ( $bucket ) = @_;
   return 0 if $bucket == 0;
   die "Invalid bucket: $bucket" if $bucket < 0 || $bucket > (NUM_BUCK-1);
   return (BUCK_SIZE**($bucket-1)) * MIN_BUCK;
}

{
   my @buck_tens;
   sub buckets_of {
      return @buck_tens if @buck_tens;

      my $start_bucket  = 0;
      my @base10_starts = (0);
      map { push @base10_starts, (10**$_)*MIN_BUCK } (1..7);

      for my $base10_bucket ( 0..($#base10_starts-1) ) {
         my $next_bucket = bucket_idx( $base10_starts[$base10_bucket+1] );
         PTDEBUG && _d('Base 10 bucket', $base10_bucket, 'maps to',
            'base 1.05 buckets', $start_bucket, '..', $next_bucket-1);
         for my $base1_05_bucket ($start_bucket..($next_bucket-1)) {
            $buck_tens[$base1_05_bucket] = $base10_bucket;
         }
         $start_bucket = $next_bucket;
      }

      map { $buck_tens[$_] = 7 } ($start_bucket..(NUM_BUCK-1));

      return @buck_tens;
   }
}

sub calculate_statistical_metrics {
   my ( $self, %args ) = @_;
   my $classes        = $self->{result_classes};
   my $globals        = $self->{result_globals};
   my $class_metrics  = $self->{class_metrics};
   my $global_metrics = $self->{global_metrics};
   PTDEBUG && _d('Calculating statistical_metrics');
   foreach my $attrib ( keys %$globals ) {
      if ( exists $globals->{$attrib}->{all} ) {
         $global_metrics->{$attrib}
            = $self->_calc_metrics(
               $globals->{$attrib}->{all},
               $globals->{$attrib},
            );
      }

      foreach my $class ( keys %$classes ) {
         if ( exists $classes->{$class}->{$attrib}->{all} ) {
            $class_metrics->{$class}->{$attrib}
               = $self->_calc_metrics(
                  $classes->{$class}->{$attrib}->{all},
                  $classes->{$class}->{$attrib}
               );
         }
      }
   }

   return;
}

sub _calc_metrics {
   my ( $self, $vals, $args ) = @_;
   my $statistical_metrics = {
      pct_95    => 0,
      stddev    => 0,
      median    => 0,
      cutoff    => undef,
   };

   return $statistical_metrics
      unless defined $vals && %$vals && $args->{cnt};

   my $n_vals = $args->{cnt};
   if ( $n_vals == 1 || $args->{max} == $args->{min} ) {
      my $v      = $args->{max} || 0;
      my $bucket = int(6 + ( log($v > 0 ? $v : MIN_BUCK) / log(10)));
      $bucket    = $bucket > 7 ? 7 : $bucket < 0 ? 0 : $bucket;
      return {
         pct_95 => $v,
         stddev => 0,
         median => $v,
         cutoff => $n_vals,
      };
   }
   elsif ( $n_vals == 2 ) {
      foreach my $v ( $args->{min}, $args->{max} ) {
         my $bucket = int(6 + ( log($v && $v > 0 ? $v : MIN_BUCK) / log(10)));
         $bucket = $bucket > 7 ? 7 : $bucket < 0 ? 0 : $bucket;
      }
      my $v      = $args->{max} || 0;
      my $mean = (($args->{min} || 0) + $v) / 2;
      return {
         pct_95 => $v,
         stddev => sqrt((($v - $mean) ** 2) *2),
         median => $mean,
         cutoff => $n_vals,
      };
   }

   my $cutoff = $n_vals >= 10 ? int ( $n_vals * 0.95 ) : $n_vals;
   $statistical_metrics->{cutoff} = $cutoff;

   my $total_left = $n_vals;
   my $top_vals   = $n_vals - $cutoff; # vals > 95th
   my $sum_excl   = 0;
   my $sum        = 0;
   my $sumsq      = 0;
   my $mid        = int($n_vals / 2);
   my $median     = 0;
   my $prev       = NUM_BUCK-1; # Used for getting median when $cutoff is odd
   my $bucket_95  = 0; # top bucket in 95th

   PTDEBUG && _d('total vals:', $total_left, 'top vals:', $top_vals, 'mid:', $mid);

   my @buckets = map { 0 } (0..NUM_BUCK-1);
   map { $buckets[$_] = $vals->{$_} } keys %$vals;
   $vals = \@buckets;  # repoint vals from given hashref to our array

   BUCKET:
   for my $bucket ( reverse 0..(NUM_BUCK-1) ) {
      my $val = $vals->[$bucket];
      next BUCKET unless $val; 

      $total_left -= $val;
      $sum_excl   += $val;
      $bucket_95   = $bucket if !$bucket_95 && $sum_excl > $top_vals;

      if ( !$median && $total_left <= $mid ) {
         $median = (($cutoff % 2) || ($val > 1)) ? $buck_vals[$bucket]
                 : ($buck_vals[$bucket] + $buck_vals[$prev]) / 2;
      }

      $sum    += $val * $buck_vals[$bucket];
      $sumsq  += $val * ($buck_vals[$bucket]**2);
      $prev   =  $bucket;
   }

   my $var      = $sumsq/$n_vals - ( ($sum/$n_vals) ** 2 );
   my $stddev   = $var > 0 ? sqrt($var) : 0;
   my $maxstdev = (($args->{max} || 0) - ($args->{min} || 0)) / 2;
   $stddev      = $stddev > $maxstdev ? $maxstdev : $stddev;

   PTDEBUG && _d('sum:', $sum, 'sumsq:', $sumsq, 'stddev:', $stddev,
      'median:', $median, 'prev bucket:', $prev,
      'total left:', $total_left, 'sum excl', $sum_excl,
      'bucket 95:', $bucket_95, $buck_vals[$bucket_95]);

   $statistical_metrics->{stddev} = $stddev;
   $statistical_metrics->{pct_95} = $buck_vals[$bucket_95];
   $statistical_metrics->{median} = $median;

   return $statistical_metrics;
}

sub metrics {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(attrib where) ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }
   my $attrib = $args{attrib};
   my $where   = $args{where};

   my $stats      = $self->results();
   my $metrics    = $self->stats();
   my $store      = $stats->{classes}->{$where}->{$attrib};
   my $global_cnt = $stats->{globals}->{$attrib}->{cnt};

   return {
      cnt    => $store->{cnt},
      pct    => $global_cnt && $store->{cnt} ? $store->{cnt} / $global_cnt : 0,
      sum    => $store->{sum},
      min    => $store->{min},
      max    => $store->{max},
      avg    => $store->{sum} && $store->{cnt} ? $store->{sum} / $store->{cnt} : 0,
      median => $metrics->{classes}->{$where}->{$attrib}->{median} || 0,
      pct_95 => $metrics->{classes}->{$where}->{$attrib}->{pct_95} || 0,
      stddev => $metrics->{classes}->{$where}->{$attrib}->{stddev} || 0,
   };
}

sub top_events {
   my ( $self, %args ) = @_;
   my $classes = $self->{result_classes};
   my @sorted = reverse sort { # Sorted list of $groupby values
      $classes->{$a}->{$args{attrib}}->{$args{orderby}}
         <=> $classes->{$b}->{$args{attrib}}->{$args{orderby}}
         || tiebreaker($classes->{$a}, $classes->{$b});
      } grep {
         defined $classes->{$_}->{$args{attrib}}->{$args{orderby}}
      } keys %$classes;  # this should first be sorted for test consistency, but many tests already in place would fail 
   my @chosen;  # top events
   my @other;   # other events (< top)
   my ($total, $count) = (0, 0);
   foreach my $groupby ( @sorted ) {
      if ( 
         (!$args{total} || $total < $args{total} )
         && ( !$args{count} || $count < $args{count} )
      ) {
         push @chosen, [$groupby, 'top', $count+1];
      }

      elsif ( $args{ol_attrib} && (!$args{ol_freq}
         || $classes->{$groupby}->{$args{ol_attrib}}->{cnt} >= $args{ol_freq})
      ) {
         my $stats = $self->{class_metrics}->{$groupby}->{$args{ol_attrib}};
         if ( ($stats->{pct_95} || 0) >= $args{ol_limit} ) {
            push @chosen, [$groupby, 'outlier', $count+1];
         }
         else {
            push @other, [$groupby, 'misc', $count+1];
         }
      }

      else {
         push @other, [$groupby, 'misc', $count+1];
      }

      $total += $classes->{$groupby}->{$args{attrib}}->{$args{orderby}};
      $count++;
   }
   return \@chosen, \@other;
}

sub tiebreaker {
    my ($a, $b) = @_;
   if (defined $a->{pos_in_log}) {
      return $a->{pos_in_log}->{max} cmp $b->{pos_in_log}->{max};
   }
   return 0;
     
}

sub add_new_attributes {
   my ( $self, $event ) = @_;
   return unless $event;

   map {
      my $attrib = $_;
      $self->{attributes}->{$attrib}  = [$attrib];
      $self->{alt_attribs}->{$attrib} = make_alt_attrib($attrib);
      push @{$self->{all_attribs}}, $attrib;
      PTDEBUG && _d('Added new attribute:', $attrib);
   }
   grep {
      $_ ne $self->{groupby}
      && !exists $self->{attributes}->{$_}
      && !exists $self->{ignore_attribs}->{$_}
   }
   keys %$event;

   return;
}

sub get_attributes {
   my ( $self ) = @_;
   return $self->{all_attribs};
}

sub events_processed {
   my ( $self ) = @_;
   return $self->{n_events};
}

sub make_alt_attrib {
   my ( @attribs ) = @_;

   my $attrib = shift @attribs;  # Primary attribute.
   return sub {} unless @attribs;  # No alternates.

   my @lines;
   push @lines, 'sub { my ( $event ) = @_; my $alt_attrib;';
   push @lines, map  {
         "\$alt_attrib = '$_' if !defined \$alt_attrib "
         . "&& exists \$event->{'$_'};"
      } @attribs;
   push @lines, 'return $alt_attrib; }';
   PTDEBUG && _d('alt attrib sub for', $attrib, ':', @lines);
   my $sub = eval join("\n", @lines);
   die if $EVAL_ERROR;
   return $sub;
}

sub merge {
   my ( @ea_objs ) = @_;
   PTDEBUG && _d('Merging', scalar @ea_objs, 'ea');
   return unless scalar @ea_objs;

   my $ea1   = shift @ea_objs;
   my $r1    = $ea1->results;
   my $worst = $ea1->{worst};  # for merging, finding worst sample

   my %attrib_types = %{ $ea1->attributes() };

   foreach my $ea ( @ea_objs ) {
      die "EventAggregator objects have different groupby: "
         . "$ea1->{groupby} and $ea->{groupby}"
         unless $ea1->{groupby} eq $ea->{groupby};
      die "EventAggregator objects have different worst: "
         . "$ea1->{worst} and $ea->{worst}"
         unless $ea1->{worst} eq $ea->{worst};
      
      my $attrib_types = $ea->attributes();
      map {
         $attrib_types{$_} = $attrib_types->{$_}
            unless exists $attrib_types{$_};
      } keys %$attrib_types;
   }

   my $r_merged = {
      classes => {},
      globals => _deep_copy_attribs($r1->{globals}),
      samples => {},
   };
   map {
      $r_merged->{classes}->{$_}
         = _deep_copy_attribs($r1->{classes}->{$_});

      @{$r_merged->{samples}->{$_}}{keys %{$r1->{samples}->{$_}}}
         = values %{$r1->{samples}->{$_}};
   } keys %{$r1->{classes}};

   for my $i ( 0..$#ea_objs ) {
      PTDEBUG && _d('Merging ea obj', ($i + 1));
      my $r2 = $ea_objs[$i]->results;

      eval {
         CLASS:
         foreach my $class ( keys %{$r2->{classes}} ) {
            my $r1_class = $r_merged->{classes}->{$class};
            my $r2_class = $r2->{classes}->{$class};

            if ( $r1_class && $r2_class ) {
               CLASS_ATTRIB:
               foreach my $attrib ( keys %$r2_class ) {
                  PTDEBUG && _d('merge', $attrib);
                  if ( $r1_class->{$attrib} && $r2_class->{$attrib} ) {
                     _add_attrib_vals($r1_class->{$attrib}, $r2_class->{$attrib});
                  }
                  elsif ( !$r1_class->{$attrib} ) {
                  PTDEBUG && _d('copy', $attrib);
                     $r1_class->{$attrib} =
                        _deep_copy_attrib_vals($r2_class->{$attrib})
                  }
               }
            }
            elsif ( !$r1_class ) {
               PTDEBUG && _d('copy class');
               $r_merged->{classes}->{$class} = _deep_copy_attribs($r2_class);
            }

            my $new_worst_sample;
            if ( $r_merged->{samples}->{$class} && $r2->{samples}->{$class} ) {
               if (   $r2->{samples}->{$class}->{$worst}
                    > $r_merged->{samples}->{$class}->{$worst} ) {
                  $new_worst_sample = $r2->{samples}->{$class}
               }
            }
            elsif ( !$r_merged->{samples}->{$class} ) {
               $new_worst_sample = $r2->{samples}->{$class};
            }
            if ( $new_worst_sample ) {
               PTDEBUG && _d('New worst sample:', $worst, '=',
                  $new_worst_sample->{$worst}, 'item:', substr($class, 0, 100));
               my %new_sample;
               @new_sample{keys %$new_worst_sample}
                  = values %$new_worst_sample;
               $r_merged->{samples}->{$class} = \%new_sample;
            }
         }
      };
      if ( $EVAL_ERROR ) {
         warn "Error merging class/sample: $EVAL_ERROR";
      }

      eval {
         GLOBAL_ATTRIB:
         PTDEBUG && _d('Merging global attributes');
         foreach my $attrib ( keys %{$r2->{globals}} ) {
            my $r1_global = $r_merged->{globals}->{$attrib};
            my $r2_global = $r2->{globals}->{$attrib};

            if ( $r1_global && $r2_global ) {
               PTDEBUG && _d('merge', $attrib);
               _add_attrib_vals($r1_global, $r2_global);
            }
            elsif ( !$r1_global ) {
               PTDEBUG && _d('copy', $attrib);
               $r_merged->{globals}->{$attrib}
                  = _deep_copy_attrib_vals($r2_global);
            }
         }
      };
      if ( $EVAL_ERROR ) {
         warn "Error merging globals: $EVAL_ERROR";
      }
   }

   my $ea_merged = new EventAggregator(
      groupby    => $ea1->{groupby},
      worst      => $ea1->{worst},
      attributes => { map { $_=>[$_] } keys %attrib_types },
   );
   $ea_merged->set_results($r_merged);
   $ea_merged->set_attribute_types(\%attrib_types);
   return $ea_merged;
}

sub _add_attrib_vals {
   my ( $vals1, $vals2 ) = @_;

   foreach my $val ( keys %$vals1 ) {
      my $val1 = $vals1->{$val};
      my $val2 = $vals2->{$val};

      if ( (!ref $val1) && (!ref $val2) ) {
         die "undefined $val value" unless defined $val1 && defined $val2;

         my $is_num = exists $vals1->{sum} ? 1 : 0;
         if ( $val eq 'max' ) {
            if ( $is_num ) {
               $vals1->{$val} = $val1 > $val2  ? $val1 : $val2;
            }
            else {
               $vals1->{$val} = $val1 gt $val2 ? $val1 : $val2;
            }
         }
         elsif ( $val eq 'min' ) {
            if ( $is_num ) {
               $vals1->{$val} = $val1 < $val2  ? $val1 : $val2;
            }
            else {
               $vals1->{$val} = $val1 lt $val2 ? $val1 : $val2;
            }
         }
         else {
            $vals1->{$val} += $val2;
         }
      }
      elsif ( (ref $val1 eq 'ARRAY') && (ref $val2 eq 'ARRAY') ) {
         die "Empty $val arrayref" unless @$val1 && @$val2;
         my $n_buckets = (scalar @$val1) - 1;
         for my $i ( 0..$n_buckets ) {
            $vals1->{$val}->[$i] += $val2->[$i];
         }
      }
      elsif ( (ref $val1 eq 'HASH')  && (ref $val2 eq 'HASH')  ) {
         die "Empty $val hashref" unless %$val1 and %$val2;
         map { $vals1->{$val}->{$_} += $val2->{$_} } keys %$val2;
      }
      else {
         PTDEBUG && _d('vals1:', Dumper($vals1));
         PTDEBUG && _d('vals2:', Dumper($vals2));
         die "$val type mismatch";
      }
   }

   return;
}

sub _deep_copy_attribs {
   my ( $attribs ) = @_;
   my $copy = {};
   foreach my $attrib ( keys %$attribs ) {
      $copy->{$attrib} = _deep_copy_attrib_vals($attribs->{$attrib});
   }
   return $copy;
}

sub _deep_copy_attrib_vals {
   my ( $vals ) = @_;
   my $copy;
   if ( ref $vals eq 'HASH' ) {
      $copy = {};
      foreach my $val ( keys %$vals ) {
         if ( my $ref_type = ref $val ) {
            if ( $ref_type eq 'ARRAY' ) {
               my $n_elems = (scalar @$val) - 1;
               $copy->{$val} = [ map { undef } ( 0..$n_elems ) ];
               for my $i ( 0..$n_elems ) {
                  $copy->{$val}->[$i] = $vals->{$val}->[$i];
               }
            }
            elsif ( $ref_type eq 'HASH' ) {
               $copy->{$val} = {};
               map { $copy->{$val}->{$_} += $vals->{$val}->{$_} }
                  keys %{$vals->{$val}}
            }
            else {
               die "I don't know how to deep copy a $ref_type reference";
            }
         }
         else {
            $copy->{$val} = $vals->{$val};
         }
      }
   }
   else {
      $copy = $vals;
   }
   return $copy;
}

sub _get_value {
   my ( $self, %args ) = @_;
   my ($event, $attrib, $alts) = @args{qw(event attribute alternates)};
   return unless $event && $attrib;

   my $value;
   if ( exists $event->{$attrib} ) {
      $value = $event->{$attrib};
   }
   elsif ( $alts ) {
      my $found_value = 0;
      foreach my $alt_attrib( @$alts ) {
         if ( exists $event->{$alt_attrib} ) {
            $value       = $event->{$alt_attrib};
            $found_value = 1;
            last;
         }
      }
      die "Event does not have attribute $attrib or any of its alternates"
         unless $found_value;
   }
   else {
      die "Event does not have attribute $attrib and there are no alterantes";
   }

   return $value;
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
# End EventAggregator package
# ###########################################################################

# ###########################################################################
# ReportFormatter package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/ReportFormatter.pm
#   t/lib/ReportFormatter.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package ReportFormatter;

use Lmo;
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use List::Util qw(min max);
use POSIX qw(ceil);

eval { require Term::ReadKey };
my $have_term = $EVAL_ERROR ? 0 : 1;


has underline_header => (
   is      => 'ro',
   isa     => 'Bool',
   default => sub { 1 },
);
has line_prefix => (
   is      => 'ro',
   isa     => 'Str',
   default => sub { '# ' },
);
has line_width => (
   is      => 'ro',
   isa     => 'Int',
   default => sub { 78 },
);
has column_spacing => (
   is      => 'ro',
   isa     => 'Str',
   default => sub { ' ' },
);
has extend_right => (
   is      => 'ro',
   isa     => 'Bool',
   default => sub { '' },
);
has truncate_line_mark => (
   is      => 'ro',
   isa     => 'Str',
   default => sub { '...' },
);
has column_errors => (
   is      => 'ro',
   isa     => 'Str',
   default => sub { 'warn' },
);
has truncate_header_side => (
   is      => 'ro',
   isa     => 'Str',
   default => sub { 'left' },
);
has strip_whitespace => (
   is      => 'ro',
   isa     => 'Bool',
   default => sub { 1 },
);
has title => (
   is        => 'rw',
   isa       => 'Str',
   predicate => 'has_title',
);


has n_cols => (
   is      => 'rw',
   isa     => 'Int',
   default => sub { 0 },
   init_arg => undef,
);

has cols => (
   is       => 'ro',
   isa      => 'ArrayRef',
   init_arg => undef,
   default  => sub { [] },
   clearer  => 'clear_cols',
);

has lines => (
   is       => 'ro',
   isa      => 'ArrayRef',
   init_arg => undef,
   default  => sub { [] },
   clearer  => 'clear_lines',
);

has truncate_headers => (
   is       => 'rw',
   isa      => 'Bool',
   default  => sub { undef },
   init_arg => undef,
   clearer  => 'clear_truncate_headers',
);

sub BUILDARGS {
   my $class = shift;
   my $args  = $class->SUPER::BUILDARGS(@_);

   if ( ($args->{line_width} || '') eq 'auto' ) {
      die "Cannot auto-detect line width because the Term::ReadKey module "
         . "is not installed" unless $have_term;
      ($args->{line_width}) = GetTerminalSize();
      PTDEBUG && _d('Line width:', $args->{line_width});
   }

   return $args;
}

sub set_columns {
   my ( $self, @cols ) = @_;
   my $min_hdr_wid = 0;  # check that header fits on line
   my $used_width  = 0;
   my @auto_width_cols;

   for my $i ( 0..$#cols ) {
      my $col      = $cols[$i];
      my $col_name = $col->{name};
      my $col_len  = length $col_name;
      die "Column does not have a name" unless defined $col_name;

      if ( $col->{width} ) {
         $col->{width_pct} = ceil(($col->{width} * 100) / $self->line_width());
         PTDEBUG && _d('col:', $col_name, 'width:', $col->{width}, 'chars =',
            $col->{width_pct}, '%');
      }

      if ( $col->{width_pct} ) {
         $used_width += $col->{width_pct};
      }
      else {
         PTDEBUG && _d('Auto width col:', $col_name);
         $col->{auto_width} = 1;
         push @auto_width_cols, $i;
      }

      $col->{truncate}        = 1 unless defined $col->{truncate};
      $col->{truncate_mark}   = '...' unless defined $col->{truncate_mark};
      $col->{truncate_side} ||= 'right';
      $col->{undef_value}     = '' unless defined $col->{undef_value};

      $col->{min_val} = 0;
      $col->{max_val} = 0;

      $min_hdr_wid        += $col_len;
      $col->{header_width} = $col_len;

      $col->{right_most} = 1 if $i == $#cols;

      push @{$self->cols}, $col;
   }

   $self->n_cols( scalar @cols );

   if ( ($used_width || 0) > 100 ) {
      die "Total width_pct for all columns is >100%";
   }

   if ( @auto_width_cols ) {
      my $wid_per_col = int((100 - $used_width) / scalar @auto_width_cols);
      PTDEBUG && _d('Line width left:', (100-$used_width), '%;',
         'each auto width col:', $wid_per_col, '%');
      map { $self->cols->[$_]->{width_pct} = $wid_per_col } @auto_width_cols;
   }

   $min_hdr_wid += ($self->n_cols() - 1) * length $self->column_spacing();
   PTDEBUG && _d('min header width:', $min_hdr_wid);
   if ( $min_hdr_wid > $self->line_width() ) {
      PTDEBUG && _d('Will truncate headers because min header width',
         $min_hdr_wid, '> line width', $self->line_width());
      $self->truncate_headers(1);
   }

   return;
}

sub add_line {
   my ( $self, @vals ) = @_;
   my $n_vals = scalar @vals;
   if ( $n_vals != $self->n_cols() ) {
      $self->_column_error("Number of values $n_vals does not match "
         . "number of columns " . $self->n_cols());
   }
   for my $i ( 0..($n_vals-1) ) {
      my $col   = $self->cols->[$i];
      my $val   = defined $vals[$i] ? $vals[$i] : $col->{undef_value};
      if ( $self->strip_whitespace() ) {
         $val =~ s/^\s+//g;
         $val =~ s/\s+$//;
         $vals[$i] = $val;
      }
      my $width = length $val;
      $col->{min_val} = min($width, ($col->{min_val} || $width));
      $col->{max_val} = max($width, ($col->{max_val} || $width));
   }
   push @{$self->lines}, \@vals;
   return;
}

sub get_report {
   my ( $self, %args ) = @_;

   $self->_calculate_column_widths();
   if ( $self->truncate_headers() ) {
      $self->_truncate_headers();
   }
   $self->_truncate_line_values(%args);

   my @col_fmts = $self->_make_column_formats();
   my $fmt      = $self->line_prefix()
                . join($self->column_spacing(), @col_fmts);
   PTDEBUG && _d('Format:', $fmt);

   (my $hdr_fmt = $fmt) =~ s/%([^-])/%-$1/g;

   my @lines;
   push @lines, $self->line_prefix() . $self->title() if $self->has_title();
   push @lines, $self->_truncate_line(
         sprintf($hdr_fmt, map { $_->{name} } @{$self->cols}),
         strip => 1,
         mark  => '',
   );

   if ( $self->underline_header() ) {
      my @underlines = map { '=' x $_->{print_width} } @{$self->cols};
      push @lines, $self->_truncate_line(
         sprintf($fmt, map { $_ || '' } @underlines),
         mark  => '',
      );
   }

   push @lines, map {
      my $vals = $_;
      my $i    = 0;
      my @vals = map {
            my $val = defined $_ ? $_ : $self->cols->[$i++]->{undef_value};
            $val = '' if !defined $val;
            $val =~ s/\n/ /g;
            $val;
      } @$vals;
      my $line = sprintf($fmt, @vals);
      if ( $self->extend_right() ) {
         $line;
      }
      else {
         $self->_truncate_line($line);
      }
   } @{$self->lines};

   $self->clear_cols();
   $self->clear_lines();
   $self->clear_truncate_headers();

   return join("\n", @lines) . "\n";
}

sub truncate_value {
   my ( $self, $col, $val, $width, $side ) = @_;
   return $val if length $val <= $width;
   return $val if $col->{right_most} && $self->extend_right();
   $side  ||= $col->{truncate_side};
   my $mark = $col->{truncate_mark};
   if ( $side eq 'right' ) {
      $val  = substr($val, 0, $width - length $mark);
      $val .= $mark;
   }
   elsif ( $side eq 'left') {
      $val = $mark . substr($val, -1 * $width + length $mark);
   }
   else {
      PTDEBUG && _d("I don't know how to", $side, "truncate values");
   }
   return $val;
}

sub _calculate_column_widths {
   my ( $self ) = @_;

   my $extra_space = 0;
   foreach my $col ( @{$self->cols} ) {
      my $print_width = int($self->line_width() * ($col->{width_pct} / 100));

      PTDEBUG && _d('col:', $col->{name}, 'width pct:', $col->{width_pct},
         'char width:', $print_width,
         'min val:', $col->{min_val}, 'max val:', $col->{max_val});

      if ( $col->{auto_width} ) {
         if ( $col->{min_val} && $print_width < $col->{min_val} ) {
            PTDEBUG && _d('Increased to min val width:', $col->{min_val});
            $print_width = $col->{min_val};
         }
         elsif ( $col->{max_val} &&  $print_width > $col->{max_val} ) {
            PTDEBUG && _d('Reduced to max val width:', $col->{max_val});
            $extra_space += $print_width - $col->{max_val};
            $print_width  = $col->{max_val};
         }
      }

      $col->{print_width} = $print_width;
      PTDEBUG && _d('print width:', $col->{print_width});
   }

   PTDEBUG && _d('Extra space:', $extra_space);
   while ( $extra_space-- ) {
      foreach my $col ( @{$self->cols} ) {
         if (    $col->{auto_width}
              && (    $col->{print_width} < $col->{max_val}
                   || $col->{print_width} < $col->{header_width})
         ) {
            $col->{print_width}++;
         }
      }
   }

   return;
}

sub _truncate_headers {
   my ( $self, $col ) = @_;
   my $side = $self->truncate_header_side();
   foreach my $col ( @{$self->cols} ) {
      my $col_name    = $col->{name};
      my $print_width = $col->{print_width};
      next if length $col_name <= $print_width;
      $col->{name}  = $self->truncate_value($col, $col_name, $print_width, $side);
      PTDEBUG && _d('Truncated hdr', $col_name, 'to', $col->{name},
         'max width:', $print_width);
   }
   return;
}

sub _truncate_line_values {
   my ( $self, %args ) = @_;
   my $n_vals = $self->n_cols() - 1;
   foreach my $vals ( @{$self->lines} ) {
      for my $i ( 0..$n_vals ) {
         my $col   = $self->cols->[$i];
         my $val   = defined $vals->[$i] ? $vals->[$i] : $col->{undef_value};
         my $width = length $val;

         if ( $col->{print_width} && $width > $col->{print_width} ) {
            if ( !$col->{truncate} ) {
               $self->_column_error("Value '$val' is too wide for column "
                  . $col->{name});
            }

            my $callback    = $args{truncate_callback};
            my $print_width = $col->{print_width};
            $val = $callback ? $callback->($col, $val, $print_width)
                 :             $self->truncate_value($col, $val, $print_width);
            PTDEBUG && _d('Truncated val', $vals->[$i], 'to', $val,
               '; max width:', $print_width);
            $vals->[$i] = $val;
         }
      }
   }
   return;
}

sub _make_column_formats {
   my ( $self ) = @_;
   my @col_fmts;
   my $n_cols = $self->n_cols() - 1;
   for my $i ( 0..$n_cols ) {
      my $col = $self->cols->[$i];

      my $width = $col->{right_most} && !$col->{right_justify} ? ''
                : $col->{print_width};

      my $col_fmt  = '%' . ($col->{right_justify} ? '' : '-') . $width . 's';
      push @col_fmts, $col_fmt;
   }
   return @col_fmts;
}

sub _truncate_line {
   my ( $self, $line, %args ) = @_;
   my $mark = defined $args{mark} ? $args{mark} : $self->truncate_line_mark();
   if ( $line ) {
      $line =~ s/\s+$// if $args{strip};
      my $len  = length($line);
      if ( $len > $self->line_width() ) {
         $line  = substr($line, 0, $self->line_width() - length $mark);
         $line .= $mark if $mark;
      }
   }
   return $line;
}

sub _column_error {
   my ( $self, $err ) = @_;
   my $msg = "Column error: $err";
   $self->column_errors() eq 'die' ? die $msg : warn $msg;
   return;
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
# End ReportFormatter package
# ###########################################################################

# ###########################################################################
# QueryReportFormatter package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/QueryReportFormatter.pm
#   t/lib/QueryReportFormatter.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package QueryReportFormatter;

use Lmo;
use English qw(-no_match_vars);
use POSIX qw(floor);

Transformers->import(qw(
   shorten micro_t parse_timestamp unix_timestamp make_checksum percentage_of
   crc32
));

use constant PTDEBUG           => $ENV{PTDEBUG} || 0;
use constant LINE_LENGTH       => 74;
use constant MAX_STRING_LENGTH => 10;

{ local $EVAL_ERROR; eval { require Quoter } };
{ local $EVAL_ERROR; eval { require ReportFormatter } };

has Quoter => (
   is      => 'ro',
   isa     => 'Quoter',
   default => sub { Quoter->new() },
);

has label_width => (
   is      => 'ro',
   isa     => 'Int',
);

has global_headers => (
   is      => 'ro',
   isa     => 'ArrayRef',
   default => sub { [qw(    total min max avg 95% stddev median)] },
);

has event_headers => (
   is      => 'ro',
   isa     => 'ArrayRef',
   default => sub { [qw(pct total min max avg 95% stddev median)] },
);

has show_all => (
   is      => 'ro',
   isa     => 'HashRef',
   default => sub { {} },
);

has ReportFormatter => (
   is      => 'ro',
   isa     => 'ReportFormatter',
   builder => '_build_report_formatter',
);

sub _build_report_formatter {
   return ReportFormatter->new(
      line_width       => LINE_LENGTH,
      extend_right     => 1,
   );
}

sub BUILDARGS {
   my $class = shift;
   my $args  = $class->SUPER::BUILDARGS(@_);

   foreach my $arg ( qw(OptionParser QueryRewriter) ) {
      die "I need a $arg argument" unless $args->{$arg};
   }

   my $label_width = $args->{label_width} ||= 12;
   PTDEBUG && _d('Label width:', $label_width);

   my $o = delete $args->{OptionParser};
   my $self = {
      %$args,
      options        => {
         shorten          => 1024,
         report_all       => $o->get('report-all'),
         report_histogram => $o->get('report-histogram'),
         output           => $o->got('output') ? $o->get('output') : '',
      },
      num_format     => '# %1$-'.$label_width.'s %2$3s %3$7s %4$7s %5$7s %6$7s %7$7s %8$7s %9$7s',
      bool_format    => '# %1$-'.$label_width.'s %2$3d%% yes, %3$3d%% no',
      string_format  => '# %1$-'.$label_width.'s %2$s',
      no_partitions  => 0,
      hidden_attrib  => {   # Don't sort/print these attribs in the reports.
         arg         => 1, # They're usually handled specially, or not
         fingerprint => 1, # printed at all.
         pos_in_log  => 1,
         ts          => 1,
      },
   };
   if (!defined($self->{max_hostname_length})) {
       $self->{max_hostname_length} = MAX_STRING_LENGTH;
   }
   if (!defined($self->{max_line_length})) {
       $self->{max_line_length} = LINE_LENGTH;
   }
   return $self;
}

sub print_reports {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(reports ea worst orderby groupby) ) {
      die "I need a $arg argument" unless exists $args{$arg};
   }
   my $reports = $args{reports};
   my $group   = $args{group};
   my $last_report;

   foreach my $report ( @$reports ) {
      PTDEBUG && _d('Printing', $report, 'report'); 
      my $report_output = $self->$report(%args);
      if ( $report_output ) {
         print "\n"
            if !$last_report || !($group->{$last_report} && $group->{$report});
         print $report_output;
      }
      else {
         PTDEBUG && _d('No', $report, 'report');
      }
      $last_report = $report;
   }

   return;
}

sub rusage {
   my ( $self ) = @_;
   my ( $rss, $vsz, $user, $system ) = ( 0, 0, 0, 0 );
   my $rusage = '';
   eval {
      my $mem = `ps -o rss,vsz -p $PID 2>&1`;
      ( $rss, $vsz ) = $mem =~ m/(\d+)/g;
      ( $user, $system ) = times();
      $rusage = sprintf "# %s user time, %s system time, %s rss, %s vsz\n",
         micro_t( $user,   p_s => 1, p_ms => 1 ),
         micro_t( $system, p_s => 1, p_ms => 1 ),
         shorten( ($rss || 0) * 1_024 ),
         shorten( ($vsz || 0) * 1_024 );
   };
   if ( $EVAL_ERROR ) {
      PTDEBUG && _d($EVAL_ERROR);
   }
   return $rusage ? $rusage : "# Could not get rusage\n";
}

sub date {
   my ( $self ) = @_;
   return "# Current date: " . (scalar localtime) . "\n";
}

sub hostname {
   my ( $self ) = @_;
   my $hostname = `hostname`;
   if ( $hostname ) {
      chomp $hostname;
      return "# Hostname: $hostname\n";
   }
   return;
}

sub files {
   my ( $self, %args ) = @_;
   if ( $args{files} ) {
      return "# Files: " . join(', ', map { $_->{name} } @{$args{files}}) . "\n";
   }
   return;
}

sub header {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(ea orderby) ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }
   my $ea      = $args{ea};
   my $orderby = $args{orderby};
   my $results = $ea->results();
   my @result;

   my $global_cnt = $results->{globals}->{$orderby}->{cnt} || 0;

   my ($qps, $conc) = (0, 0);
   if ( $global_cnt && $results->{globals}->{ts}
      && ($results->{globals}->{ts}->{max} || '')
         gt ($results->{globals}->{ts}->{min} || '')
   ) {
      eval {
         my $min  = parse_timestamp($results->{globals}->{ts}->{min});
         my $max  = parse_timestamp($results->{globals}->{ts}->{max});
         my $diff = unix_timestamp($max) - unix_timestamp($min);
         $qps     = $global_cnt / ($diff || 1);
         $conc    = $results->{globals}->{$args{orderby}}->{sum} / $diff;
      };
   }

   PTDEBUG && _d('global_cnt:', $global_cnt, 'unique:',
      scalar keys %{$results->{classes}}, 'qps:', $qps, 'conc:', $conc);
   my $line = sprintf(
      '# Overall: %s total, %s unique, %s QPS, %sx concurrency ',
      shorten($global_cnt, d=>1_000),
      shorten(scalar keys %{$results->{classes}}, d=>1_000),
      shorten($qps  || 0, d=>1_000),
      shorten($conc || 0, d=>1_000));
   $line .= ('_' x (LINE_LENGTH - length($line) + $self->label_width() - 12));
   push @result, $line;

   if ( my $ts = $results->{globals}->{ts} ) {
      my $time_range = $self->format_time_range($ts) || "unknown";
      push @result, "# Time range: $time_range";
   }

   if ( $results->{globals}->{rate_limit} ) {
      print "# Rate limits apply\n";
   }

   push @result, $self->make_global_header();

   my $attribs = $self->sort_attribs( $ea );

   foreach my $type ( qw(num innodb) ) {
      if ( $type eq 'innodb' && @{$attribs->{$type}} ) {
         push @result, "# InnoDB:";
      };

      NUM_ATTRIB:
      foreach my $attrib ( @{$attribs->{$type}} ) {
         next unless exists $results->{globals}->{$attrib};
         my $store   = $results->{globals}->{$attrib};
         my $metrics = $ea->stats()->{globals}->{$attrib};
         my $func    = $attrib =~ m/time|wait$/ ? \&micro_t : \&shorten;
         my @values  = ( 
            @{$store}{qw(sum min max)},
            $store->{sum} / $store->{cnt},
            @{$metrics}{qw(pct_95 stddev median)},
         );
         @values = map { defined $_ ? $func->($_) : '' } @values;

         push @result,
            sprintf $self->{num_format},
               $self->make_label($attrib), '', @values;
      }
   }

   if ( @{$attribs->{bool}} ) {
      push @result, "# Boolean:";
      my $printed_bools = 0;
      BOOL_ATTRIB:
      foreach my $attrib ( @{$attribs->{bool}} ) {
         next unless exists $results->{globals}->{$attrib};

         my $store = $results->{globals}->{$attrib};
         if ( $store->{sum} > 0 ) { 
            push @result,
               sprintf $self->{bool_format},
                  $self->make_label($attrib), $self->bool_percents($store);
            $printed_bools = 1;
         }
      }
      pop @result unless $printed_bools;
   }

   return join("\n", map { s/\s+$//; $_ } @result) . "\n";
}

sub query_report_values {
   my ($self, %args) = @_;
   foreach my $arg ( qw(ea worst orderby groupby) ) {
      die "I need a $arg argument" unless defined $arg;
   }
   my $ea      = $args{ea};
   my $groupby = $args{groupby};
   my $worst   = $args{worst};

   my $q   = $self->Quoter;
   my $qv  = $self->{QueryReview};
   my $qr  = $self->{QueryRewriter};

   my @values;
   ITEM:
   foreach my $top_event ( @$worst ) {
      my $item       = $top_event->[0];
      my $reason     = $args{explain_why} ? $top_event->[1] : '';
      my $rank       = $top_event->[2];
      my $stats      = $ea->results->{classes}->{$item};
      my $sample     = $ea->results->{samples}->{$item};
      my $samp_query = ($self->{options}->{output} eq 'secure-slowlog') ? $sample->{fingerprint} || '' : $sample->{arg} || '';

      my %item_vals = (
         item       => $item,
         samp_query => $samp_query,
         rank       => ($rank || 0),
         reason     => $reason,
      );

      my $review_vals;
      if ( $qv ) {
         $review_vals = $qv->get_review_info($item);
         next ITEM if $review_vals->{reviewed_by} && !$self->{options}->{report_all};
         for my $col ( $qv->review_cols() ) {
            push @{$item_vals{review_vals}}, [$col, $review_vals->{$col}];
         }
      }

      $item_vals{default_db} = $sample->{db}       ? $sample->{db}
                              : $stats->{db}->{unq} ? keys %{$stats->{db}->{unq}}
                              :                       undef;
      $item_vals{tables} = [$self->{QueryParser}->extract_tables(
            query      => $samp_query,
            default_db => $item_vals{default_db},
            Quoter     => $self->Quoter,
         )];

      if ( $samp_query && ($args{variations} && @{$args{variations}}) ) {
         $item_vals{crc} = crc32($samp_query);
      }

      push @values, \%item_vals;
   }
   return \@values;
}

sub query_report {
   my ( $self, %args ) = @_;

   my $ea      = $args{ea};
   my $groupby = $args{groupby};
   my $report_values = $self->query_report_values(%args);

   my $qr  = $self->{QueryRewriter};

   my $report = '';

   if ( $args{print_header} ) {
      $report .= "# " . ( '#' x 72 ) . "\n"
               . "# Report grouped by $groupby\n"
               . '# ' . ( '#' x 72 ) . "\n\n";
   }

   my $attribs = $self->sort_attribs( $ea );

   ITEM:
   foreach my $vals ( @$report_values ) {
      my $item = $vals->{item};
      $report .= "\n" if $vals->{rank} > 1;  # space between each event report
      $report .= $self->event_report(
         %args,
         item    => $item,
         sample  => $ea->results->{samples}->{$item},
         rank    => $vals->{rank},
         reason  => $vals->{reason},
         attribs => $attribs,
         db      => $vals->{default_db},
      );

      if ( $self->{options}->{report_histogram} ) {
         $report .= $self->chart_distro(
            %args,
            attrib => $self->{options}->{report_histogram},
            item   => $vals->{item},
         );
      }

      if ( $vals->{review_vals} ) {
         $report .= "# Review information\n";
         foreach my $elem ( @{$vals->{review_vals}} ) {
            my ($col, $val) = @$elem;
            if ( !$val || $val ne '0000-00-00 00:00:00' ) { # issue 202
               $report .= sprintf "# %13s: %-s\n", $col, ($val ? $val : '');
            }
         }
      }

      my $partitions_msg = $self->{no_partitions} ? '' : '/*!50100 PARTITIONS*/';
      if ( $groupby eq 'fingerprint' ) {
         my $samp_query = $qr->shorten($vals->{samp_query}, $self->{options}->{shorten})
            if $self->{options}->{shorten};

         PTDEBUG && _d("Fingerprint\n#    $vals->{item}\n");

         $report .= $self->tables_report($vals->{tables}, \%args);

         if ( $vals->{crc} ) {
            $report.= "# CRC " . ($vals->{crc} % 1_000) . "\n";
         }

         my $log_type = $args{log_type} || '';
         my $mark     = $args{no_v_format} ? '' : '\G';

         if ( $item =~ m/^(?:[\(\s]*select|insert|replace)/ ) {
            if ( $item =~ m/^(?:insert|replace)/ ) { # No EXPLAIN
               $report .= "$samp_query${mark}\n";
            }
            else {
               $report .= "# EXPLAIN $partitions_msg\n$samp_query${mark}\n"; 
               $report .= $self->explain_report($samp_query, $vals->{default_db});
            }
         }
         else {
            $report .= "$samp_query${mark}\n"; 
            my $converted = $qr->convert_to_select($samp_query);
            if ( $converted
                 && $converted =~ m/^[\(\s]*select/i ) {
               $report .= "# Converted for EXPLAIN\n# EXPLAIN $partitions_msg\n$converted${mark}\n";
            }
         }
      }
      else {
         if ( $groupby eq 'tables' ) {
            my ( $db, $tbl ) = $self->Quoter->split_unquote($item);
            $report .= $self->tables_report([ [$db, $tbl] ], \%args);
         }
         $report .= "$item\n";
      }
   }

   return $report;
}

sub event_report_values {
   my ($self, %args) = @_;

   my $ea   = $args{ea};
   my $item = $args{item};
   my $orderby = $args{orderby};
   my $results = $ea->results();

   my %vals;

   my $store = $results->{classes}->{$item};

   return unless $store;

   my $global_cnt = $results->{globals}->{$orderby}->{cnt};
   my $class_cnt  = $store->{$orderby}->{cnt};

   my ($qps, $conc) = (0, 0);
   if ( $global_cnt && $store->{ts}
      && ($store->{ts}->{max} || '')
         gt ($store->{ts}->{min} || '')
   ) {
      eval {
         my $min  = parse_timestamp($store->{ts}->{min});
         my $max  = parse_timestamp($store->{ts}->{max});
         my $diff = unix_timestamp($max) - unix_timestamp($min);
         $qps     = $class_cnt / $diff;
         $conc    = $store->{$orderby}->{sum} / $diff;
      };
   }

   $vals{groupby}     = $ea->{groupby};
   $vals{qps}         = $qps  || 0;
   $vals{concurrency} = $conc || 0;
   $vals{checksum}    = make_checksum($item);
   $vals{pos_in_log}  = $results->{samples}->{$item}->{pos_in_log} || 0;
   $vals{reason}      = $args{reason};
   $vals{variance_to_mean} = do {
      my $query_time = $ea->metrics(where => $item, attrib => 'Query_time');
      $query_time->{stddev}**2 / ($query_time->{avg} || 1)
   };

   $vals{counts} = {
      class_cnt        => $class_cnt,
      global_cnt       => $global_cnt,
   };

   if ( my $ts = $store->{ts}) {
      $vals{time_range} = $self->format_time_range($ts) || "unknown";
   }

   my $attribs = $args{attribs};
   if ( !$attribs ) {
      $attribs = $self->sort_attribs( $ea );
   }

   $vals{attributes} = { map { $_ => [] } qw(num innodb bool string) };

   foreach my $type ( qw(num innodb) ) {

      NUM_ATTRIB:
      foreach my $attrib ( @{$attribs->{$type}} ) {
         next NUM_ATTRIB unless exists $store->{$attrib};
         my $vals = $store->{$attrib};
         next unless scalar %$vals;

         my $pct;
         my $func    = $attrib =~ m/time|wait$/ ? \&micro_t : \&shorten;
         my $metrics = $ea->stats()->{classes}->{$item}->{$attrib};
         my @values = (
            @{$vals}{qw(sum min max)},
            $vals->{sum} / $vals->{cnt},
            @{$metrics}{qw(pct_95 stddev median)},
         );
         @values = map { defined $_ ? $func->($_) : '' } @values;
         $pct   = percentage_of(
            $vals->{sum}, $results->{globals}->{$attrib}->{sum});

         push @{$vals{attributes}{$type}},
               [ $attrib, $pct, @values ];
      }
   }

   if ( @{$attribs->{bool}} ) {
      BOOL_ATTRIB:
      foreach my $attrib ( @{$attribs->{bool}} ) {
         next BOOL_ATTRIB unless exists $store->{$attrib};
         my $vals = $store->{$attrib};
         next unless scalar %$vals;

         if ( $vals->{sum} > 0 ) {
            push @{$vals{attributes}{bool}},
                  [ $attrib, $self->bool_percents($vals) ];
         }
      }
   }

   if ( @{$attribs->{string}} ) {
      STRING_ATTRIB:
      foreach my $attrib ( @{$attribs->{string}} ) {
         next STRING_ATTRIB unless exists $store->{$attrib};
         my $vals = $store->{$attrib};
         next unless scalar %$vals;

         push @{$vals{attributes}{string}},
               [ $attrib, $vals ];
      }
   }


   return \%vals;
}


sub event_report {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(ea item orderby) ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }

   my $item = $args{item};
   my $val  = $self->event_report_values(%args);
   my @result;

   return "# No such event $item\n" unless $val;

   my $line = sprintf(
      '# %s %d: %s QPS, %sx concurrency, ID 0x%s at byte %.f ',
      ($val->{groupby} eq 'fingerprint' ? 'Query' : 'Item'),
      $args{rank} || 0,
      shorten($val->{qps}, d=>1_000),
      shorten($val->{concurrency}, d=>1_000),
      $val->{checksum},
      $val->{pos_in_log},
   );
   my $underscores = LINE_LENGTH - length($line) + $self->label_width() - 12;
   if ( $underscores < 0 ) {
      $underscores = 0;
   }
   $line .= ('_' x $underscores);
   push @result, $line;

   if ( $val->{reason} ) {
      push @result,
         "# This item is included in the report because it matches "
            . ($val->{reason} eq 'top' ? '--limit.' : '--outliers.');
   }

   push @result,
      sprintf("# Scores: V/M = %.2f", $val->{variance_to_mean} );

   if ( $val->{time_range} ) {
      push @result, "# Time range: $val->{time_range}";
   }

   push @result, $self->make_event_header();

   push @result,
      sprintf $self->{num_format}, 'Count',
         percentage_of($val->{counts}{class_cnt}, $val->{counts}{global_cnt}),
         $val->{counts}{class_cnt},
         map { '' } (1..8);


   my $attribs = $val->{attributes};

   foreach my $type ( qw(num innodb) ) {
      if ( $type eq 'innodb' && @{$attribs->{$type}} ) {
         push @result, "# InnoDB:";
      };

      NUM_ATTRIB:
      foreach my $attrib ( @{$attribs->{$type}} ) {
         my ($attrib_name, @vals) = @$attrib;
         push @result,
            sprintf $self->{num_format},
               $self->make_label($attrib_name), @vals;
      }
   }

   if ( @{$attribs->{bool}} ) {
      push @result, "# Boolean:";
      BOOL_ATTRIB:
      foreach my $attrib ( @{$attribs->{bool}} ) {
         my ($attrib_name, @vals) = @$attrib;
         push @result,
            sprintf $self->{bool_format},
               $self->make_label($attrib_name), @vals;
      }
   }

   if ( @{$attribs->{string}} ) {
      push @result, "# String:";
      STRING_ATTRIB:
      foreach my $attrib ( @{$attribs->{string}} ) {
         my ($attrib_name, $vals) = @$attrib;
         push @result,
            sprintf $self->{string_format},
               $self->make_label($attrib_name),
               $self->format_string_list($attrib_name, $vals, $val->{counts}{class_cnt});
      }
   }


   return join("\n", map { s/\s+$//; $_ } @result) . "\n";
}

sub chart_distro {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(ea item attrib) ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }
   my $ea     = $args{ea};
   my $item   = $args{item};
   my $attrib = $args{attrib};

   my $results = $ea->results();
   my $store   = $results->{classes}->{$item}->{$attrib};
   my $vals    = $store->{all};
   return "" unless defined $vals && scalar %$vals;

   my @buck_tens = $ea->buckets_of(10);
   my @distro = map { 0 } (0 .. 7);

   my @buckets = map { 0 } (0..999);
   map { $buckets[$_] = $vals->{$_} } keys %$vals;
   $vals = \@buckets;  # repoint vals from given hashref to our array

   map { $distro[$buck_tens[$_]] += $vals->[$_] } (1 .. @$vals - 1);

   my $vals_per_mark; # number of vals represented by 1 #-mark
   my $max_val        = 0;
   my $max_disp_width = 64;
   my $bar_fmt        = "# %5s%s";
   my @distro_labels  = qw(1us 10us 100us 1ms 10ms 100ms 1s 10s+);
   my @results        = "# $attrib distribution";

   foreach my $n_vals ( @distro ) {
      $max_val = $n_vals if $n_vals > $max_val;
   }
   $vals_per_mark = $max_val / $max_disp_width;

   foreach my $i ( 0 .. $#distro ) {
      my $n_vals  = $distro[$i];
      my $n_marks = $n_vals / ($vals_per_mark || 1);

      $n_marks = 1 if $n_marks < 1 && $n_vals > 0;

      my $bar = ($n_marks ? '  ' : '') . '#' x $n_marks;
      push @results, sprintf $bar_fmt, $distro_labels[$i], $bar;
   }

   return join("\n", @results) . "\n";
}

sub profile {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(ea worst groupby) ) {
      die "I need a $arg argument" unless defined $arg;
   }
   my $ea      = $args{ea};
   my $worst   = $args{worst};
   my $other   = $args{other};
   my $groupby = $args{groupby};

   my $qr  = $self->{QueryRewriter};

   my $results = $ea->results();
   my $total_r = $results->{globals}->{Query_time}->{sum} || 0;

   my @profiles;
   foreach my $top_event ( @$worst ) {
      my $item       = $top_event->[0];
      my $rank       = $top_event->[2];
      my $stats      = $ea->results->{classes}->{$item};
      my $sample     = $ea->results->{samples}->{$item};
      my $samp_query = $sample->{arg} || '';
      my $query_time = $ea->metrics(where => $item, attrib => 'Query_time');

      my %profile    = (
         rank   => $rank,
         r      => $stats->{Query_time}->{sum},
         cnt    => $stats->{Query_time}->{cnt},
         sample => $groupby eq 'fingerprint' ?
                    $qr->distill($samp_query, %{$args{distill_args}}) : $item,
         id     => $groupby eq 'fingerprint' ? make_checksum($item)   : '',
         vmr    => ($query_time->{stddev}**2) / ($query_time->{avg} || 1),
      ); 

      push @profiles, \%profile;
   }

   my $report = $self->ReportFormatter();
   $report->title('Profile');
   my @cols = (
      { name => 'Rank',          right_justify => 1,             },
      { name => 'Query ID', width => 35                          },
      { name => 'Response time', right_justify => 1,             },
      { name => 'Calls',         right_justify => 1,             },
      { name => 'R/Call',        right_justify => 1,             },
      { name => 'V/M',           right_justify => 1, width => 5, },
      { name => 'Item',                                          },
   );
   $report->set_columns(@cols);

   foreach my $item ( sort { $a->{rank} <=> $b->{rank} } @profiles ) {
      my $rt  = sprintf('%10.4f', $item->{r});
      my $rtp = sprintf('%4.1f%%', $item->{r} / ($total_r || 1) * 100);
      my $rc  = sprintf('%8.4f', $item->{r} / $item->{cnt});
      my $vmr = sprintf('%4.2f', $item->{vmr});
      my @vals = (
         $item->{rank},
         "0x$item->{id}",
         "$rt $rtp",
         $item->{cnt},
         $rc,
         $vmr,
         $item->{sample},
      );
      $report->add_line(@vals);
   }

   if ( $other && @$other ) {
      my $misc = {
            r   => 0,
            cnt => 0,
      };
      foreach my $other_event ( @$other ) {
         my $item      = $other_event->[0];
         my $stats     = $ea->results->{classes}->{$item};
         $misc->{r}   += $stats->{Query_time}->{sum};
         $misc->{cnt} += $stats->{Query_time}->{cnt};
      }
      my $rt  = sprintf('%10.4f', $misc->{r});
      my $rtp = sprintf('%4.1f%%', $misc->{r} / ($total_r || 1) * 100);
      my $rc  = sprintf('%8.4f', $misc->{r} / $misc->{cnt});
      $report->add_line(
         "MISC",
         "0xMISC",
         "$rt $rtp",
         $misc->{cnt},
         $rc,
         '0.0',  # variance-to-mean ratio is not meaningful here
         "<".scalar @$other." ITEMS>",
      );
   }

   return $report->get_report();
}

sub prepared {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(ea worst groupby) ) {
      die "I need a $arg argument" unless defined $arg;
   }
   my $ea      = $args{ea};
   my $worst   = $args{worst};
   my $groupby = $args{groupby};

   my $qr = $self->{QueryRewriter};

   my @prepared;       # prepared statements
   my %seen_prepared;  # report each PREP-EXEC pair once
   my $total_r = 0;

   foreach my $top_event ( @$worst ) {
      my $item       = $top_event->[0];
      my $rank       = $top_event->[2];
      my $stats      = $ea->results->{classes}->{$item};
      my $sample     = $ea->results->{samples}->{$item};
      my $samp_query = $sample->{arg} || '';

      $total_r += $stats->{Query_time}->{sum};
      next unless $stats->{Statement_id} && $item =~ m/^(?:prepare|execute) /;

      my ($prep_stmt, $prep, $prep_r, $prep_cnt);
      my ($exec_stmt, $exec, $exec_r, $exec_cnt);

      if ( $item =~ m/^prepare / ) {
         $prep_stmt           = $item;
         ($exec_stmt = $item) =~ s/^prepare /execute /;
      }
      else {
         ($prep_stmt = $item) =~ s/^execute /prepare /;
         $exec_stmt           = $item;
      }

      if ( !$seen_prepared{$prep_stmt}++ ) {
         if ( exists $ea->results->{classes}->{$exec_stmt} ) {
            $exec     = $ea->results->{classes}->{$exec_stmt};
            $exec_r   = $exec->{Query_time}->{sum};
            $exec_cnt = $exec->{Query_time}->{cnt};
         }
         else {
            PTDEBUG && _d('Statement prepared but not executed:', $item);
            $exec_r   = 0;
            $exec_cnt = 0;
         }

         if ( exists $ea->results->{classes}->{$prep_stmt} ) {
            $prep     = $ea->results->{classes}->{$prep_stmt};
            $prep_r   = $prep->{Query_time}->{sum};
            $prep_cnt = scalar keys %{$prep->{Statement_id}->{unq}},
         }
         else {
            PTDEBUG && _d('Statement executed but not prepared:', $item);
            $prep_r   = 0;
            $prep_cnt = 0;
         }

         push @prepared, {
            prep_r   => $prep_r, 
            prep_cnt => $prep_cnt,
            exec_r   => $exec_r,
            exec_cnt => $exec_cnt,
            rank     => $rank,
            sample   => $groupby eq 'fingerprint'
                          ? $qr->distill($samp_query, %{$args{distill_args}})
                          : $item,
            id       => $groupby eq 'fingerprint' ? make_checksum($item)
                                                  : '',
         };
      }
   }

   return unless scalar @prepared;

   my $report = $self->ReportFormatter();
   $report->title('Prepared statements');
   $report->set_columns(
      { name => 'Rank',          right_justify => 1, },
      { name => 'Query ID',                          },
      { name => 'PREP',          right_justify => 1, },
      { name => 'PREP Response', right_justify => 1, },
      { name => 'EXEC',          right_justify => 1, },
      { name => 'EXEC Response', right_justify => 1, },
      { name => 'Item',                              },
   );

   foreach my $item ( sort { $a->{rank} <=> $b->{rank} } @prepared ) {
      my $exec_rt  = sprintf('%10.4f', $item->{exec_r});
      my $exec_rtp = sprintf('%4.1f%%',$item->{exec_r}/($total_r || 1) * 100);
      my $prep_rt  = sprintf('%10.4f', $item->{prep_r});
      my $prep_rtp = sprintf('%4.1f%%',$item->{prep_r}/($total_r || 1) * 100);
      $report->add_line(
         $item->{rank},
         "0x$item->{id}",
         $item->{prep_cnt} || 0,
         "$prep_rt $prep_rtp",
         $item->{exec_cnt} || 0,
         "$exec_rt $exec_rtp",
         $item->{sample},
      );
   }
   return $report->get_report();
}

sub make_global_header {
   my ( $self ) = @_;
   my @lines;

   push @lines,
      sprintf $self->{num_format}, "Attribute", '', @{$self->global_headers()};

   push @lines,
      sprintf $self->{num_format},
         (map { "=" x $_ } $self->label_width()),
         (map { " " x $_ } qw(3)),  # no pct column in global header
         (map { "=" x $_ } qw(7 7 7 7 7 7 7));

   return @lines;
}

sub make_event_header {
   my ( $self ) = @_;

   return @{$self->{event_header_lines}} if $self->{event_header_lines};

   my @lines;
   push @lines,
      sprintf $self->{num_format}, "Attribute", @{$self->event_headers()};

   push @lines,
      sprintf $self->{num_format},
         map { "=" x $_ } ($self->label_width(), qw(3 7 7 7 7 7 7 7));

   $self->{event_header_lines} = \@lines;
   return @lines;
}

sub make_label {
   my ( $self, $val ) = @_;
   return '' unless $val;

   $val =~ s/_/ /g;

   if ( $val =~ m/^InnoDB/ ) {
      $val =~ s/^InnoDB //;
      $val = $val eq 'trx id' ? "InnoDB trxID"
           : substr($val, 0, $self->label_width());
   }

   $val = $val eq 'user'            ? 'Users'
        : $val eq 'db'              ? 'Databases'
        : $val eq 'Query time'      ? 'Exec time'
        : $val eq 'host'            ? 'Hosts'
        : $val eq 'Error no'        ? 'Errors'
        : $val eq 'bytes'           ? 'Query size'
        : $val eq 'Tmp disk tables' ? 'Tmp disk tbl'
        : $val eq 'Tmp table sizes' ? 'Tmp tbl size'
        : substr($val, 0, $self->label_width);

   return $val;
}

sub bool_percents {
   my ( $self, $vals ) = @_;
   my $p_true  = percentage_of($vals->{sum},  $vals->{cnt});
   my $p_false = percentage_of(($vals->{cnt} - $vals->{sum}), $vals->{cnt});
   return $p_true, $p_false;
}

sub format_string_list {
   my ( $self, $attrib, $vals, $class_cnt ) = @_;
   
   if ( !exists $vals->{unq} ) {
      return ($vals->{cnt});
   }

   my $show_all = $self->show_all();

   my $cnt_for = $vals->{unq};
   if ( 1 == keys %$cnt_for ) {
      my ($str) = keys %$cnt_for;
      $str = substr($str, 0, LINE_LENGTH - 30) . '...'
         if length $str > LINE_LENGTH - 30;
      return $str;
   }
   my $line = '';
   my @top = sort { $cnt_for->{$b} <=> $cnt_for->{$a} || $a cmp $b }
                  keys %$cnt_for;
   my $i = 0;
   foreach my $str ( @top ) {
      my $print_str;
      if ( $str =~ m/(?:\d+\.){3}\d+/ ) {
         $print_str = $str;  # Do not shorten IP addresses.
      }
      elsif ( $self->{max_hostname_length} > 0 and length $str > $self->{max_hostname_length} ) {
         $print_str = substr($str, 0, $self->{max_hostname_length}) . '...';
      } else {
         $print_str = $str;
      }
      my $p = percentage_of($cnt_for->{$str}, $class_cnt);
      $print_str .= " ($cnt_for->{$str}/$p%)";
      my $trim_length = LINE_LENGTH;
      if ($self->{max_hostname_length} == 0 or $self->{max_hostname_length} > LINE_LENGTH) {
          $trim_length = $self->{max_hostname_length};
      }
      if ( $self->{max_line_length} > 0 and !$show_all->{$attrib} ) {
         last if (length $line) + (length $print_str)  > $self->{max_line_length} - 27;
      }
      $line .= "$print_str, ";
      $i++;
   }

   $line =~ s/, $//;

   if ( $i < @top ) {
      $line .= "... " . (@top - $i) . " more";
   }

   return $line;
}

sub sort_attribs {
   my ( $self, $ea ) = @_;
   my $attribs = $ea->get_attributes();
   return unless $attribs && @$attribs;
   PTDEBUG && _d("Sorting attribs:", @$attribs);

   my @num_order = qw(
      Query_time
      Exec_orig_time
      Transmit_time
      Lock_time
      Rows_sent
      Rows_examined
      Rows_affected
      Rows_read
      Bytes_sent
      Merge_passes
      Tmp_tables
      Tmp_disk_tables
      Tmp_table_sizes
      bytes
   );
   my $i         = 0;
   my %num_order = map { $_ => $i++ } @num_order;

   my (@num, @innodb, @bool, @string);
   ATTRIB:
   foreach my $attrib ( @$attribs ) {
      next if $self->{hidden_attrib}->{$attrib};

      my $type = $ea->type_for($attrib) || 'string';
      if ( $type eq 'num' ) {
         if ( $attrib =~ m/^InnoDB_/ ) {
            push @innodb, $attrib;
         }
         else {
            push @num, $attrib;
         }
      }
      elsif ( $type eq 'bool' ) {
         push @bool, $attrib;
      }
      elsif ( $type eq 'string' ) {
         push @string, $attrib;
      }
      else {
         PTDEBUG && _d("Unknown attrib type:", $type, "for", $attrib);
      }
   }

   @num    = sort { pref_sort($a, $num_order{$a}, $b, $num_order{$b}) } @num;
   @innodb = sort { uc $a cmp uc $b } @innodb;
   @bool   = sort { uc $a cmp uc $b } @bool;
   @string = sort { uc $a cmp uc $b } @string;

   return {
      num     => \@num,
      innodb  => \@innodb,
      string  => \@string,
      bool    => \@bool,
   };
}

sub pref_sort {
   my ( $attrib_a, $order_a, $attrib_b, $order_b ) = @_;

   if ( !defined $order_a && !defined $order_b ) {
      return $attrib_a cmp $attrib_b;
   }

   if ( defined $order_a && defined $order_b ) {
      return $order_a <=> $order_b;
   }

   if ( !defined $order_a ) {
      return 1;
   }
   else {
      return -1;
   }
}

sub tables_report {
   my ( $self, $tables_ref, $args_ref ) = @_;
   return '' unless @$tables_ref;
   my $q      = $self->Quoter();
   my $tables = "";
   my $mark   = $args_ref->{no_v_format} ? '' : '\G';
   foreach my $db_tbl ( @$tables_ref ) {
      my ( $db, $tbl ) = @$db_tbl;
      $tables .= '#    SHOW TABLE STATUS'
               . ($db ? " FROM `$db`" : '')
               . " LIKE '$tbl'${mark}\n";
      $tables .= "#    SHOW CREATE TABLE "
               . $q->quote(grep { $_ } @$db_tbl)
               . "${mark}\n";
   }
   return $tables ? "# Tables\n$tables" : "# No tables\n";
}

sub explain_report {
   my ( $self, $query, $db ) = @_;
   return '' unless $query;

   my $dbh = $self->{dbh};
   my $q   = $self->Quoter();
   my $qp  = $self->{QueryParser};
   return '' unless $dbh && $q && $qp;

   my $explain = '';
   eval {
      if ( !$qp->has_derived_table($query) ) {
         if ( $db ) {
            PTDEBUG && _d($dbh, "USE", $db);
            $dbh->do("USE " . $q->quote($db));
         }
         my $sth;
         eval {
             $sth = $dbh->prepare("EXPLAIN /*!50100 PARTITIONS*/ $query");
             $sth->execute();
         };
         if ($EVAL_ERROR) { # MySQL 8.0+ doesn't support PARTITIONS
             $self->{no_partitions} = 1;
             $sth = $dbh->prepare("EXPLAIN $query");
             $sth->execute();
         }
         $sth->execute();
         my $i = 1;
         while ( my @row = $sth->fetchrow_array() ) {
            $explain .= "# *************************** $i. "
                      . "row ***************************\n";
            foreach my $j ( 0 .. $#row ) {
               # In some OSes/Perl versions, the filtered row can be reported with or without decimals.
               # Example, in Ubuntu 16.04 it is being printed as 100.00 while in Ubuntu 18.04 it is
               # being printed as 100.
               # To make it testeable, we need to have a consistent format across versions.
               my $value_format = $sth->{NAME}->[$j] eq 'filtered' ? "%.02f" : "%s";
               $explain .= sprintf "# %13s: $value_format\n", $sth->{NAME}->[$j],
                  defined $row[$j] ? $row[$j] : 'NULL';
            }
            $i++;  # next row number
         }
      }
   };
   if ( $EVAL_ERROR ) {
      PTDEBUG && _d("EXPLAIN failed:", $query, $EVAL_ERROR);
   }
   return $explain ? $explain : "# EXPLAIN failed: $EVAL_ERROR";
}

sub format_time_range {
   my ( $self, $vals ) = @_;
   my $min = parse_timestamp($vals->{min} || '');
   my $max = parse_timestamp($vals->{max} || '');

   if ( $min && $max && $min eq $max ) {
      return "all events occurred at $min";
   }

   my ($min_day) = split(' ', $min) if $min;
   my ($max_day) = split(' ', $max) if $max;
   if ( ($min_day || '') eq ($max_day || '') ) {
      (undef, $max) = split(' ', $max);
   }

   return $min && $max ? "$min to $max" : '';
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
# End QueryReportFormatter package
# ###########################################################################

# ###########################################################################
# JSONReportFormatter package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/JSONReportFormatter.pm
#   t/lib/JSONReportFormatter.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package JSONReportFormatter;
use Lmo;

use List::Util   qw(sum);
use Transformers qw(make_checksum parse_timestamp);

use constant PTDEBUG => $ENV{PTDEBUG} || 0;

my $have_json = eval { require JSON };

our $pretty_json = $ENV{PTTEST_PRETTY_JSON} || 0;
our $sorted_json = $ENV{PTTEST_PRETTY_JSON} || 0;


extends qw(QueryReportFormatter);

has 'QueryRewriter' => (
   is       => 'ro',
   isa      => 'Object',
   required => 1,
);

has 'QueryParser' => (
   is       => 'ro',
   isa      => 'Object',
   required => 1,
);

has 'Quoter' => (
   is       => 'ro',
   isa      => 'Object',
   required => 1,
);

has _json => (
   is       => 'ro',
   init_arg => undef,
   builder  => '_build_json',
);

has 'max_query_length' => (  
   is       => 'rw',
   isa      => 'Int',
   required => 0,
   default  => sub { return 10_000; }, # characters, not bytes
);

has 'max_fingerprint_length' => ( 
   is       => 'rw',
   isa      => 'Int',
   required => 0,
   default  => sub { return 5_000; }, # characters, not bytes
);

sub _build_json {
   return unless $have_json;
   return JSON->new->utf8
                   ->pretty($pretty_json)
                   ->canonical($sorted_json);
}

sub encode_json {
   my ($self, $encode) = @_;
   if ( my $json = $self->_json ) {
      return $json->encode($encode);
   }
   else {
      return Transformers::encode_json($encode);
   }
}

override [qw(rusage date hostname files header profile prepared)] => sub {
   return;
};

override event_report => sub {
   my ($self, %args) = @_;
   return $self->event_report_values(%args);
};

override query_report => sub {
   my ($self, %args) = @_;
   foreach my $arg ( qw(ea worst orderby groupby) ) {
      die "I need a $arg argument" unless defined $arg;
   }
   my $ea      = $args{ea};
   my $worst   = $args{worst};
   my $orderby = $args{orderby};
   my $groupby = $args{groupby};

   my $results = $ea->results();
   my @attribs = @{$ea->get_attributes()};

   my $q  = $self->Quoter;
   my $qr = $self->QueryRewriter;

   my $global_data = {
      metrics => {},
      files   => $args{files},
      ($args{resume} && scalar keys %{$args{resume}} ? (resume  => $args{resume}) : ()),
   };

   my $global_cnt = $results->{globals}->{$orderby}->{cnt} || 0;
   my $global_unq = scalar keys %{$results->{classes}};

   my ($qps, $conc) = (0, 0);
   if ( $global_cnt && $results->{globals}->{ts}
        && ($results->{globals}->{ts}->{max} || '')
            gt ($results->{globals}->{ts}->{min} || '') )
   {
      eval {
         my $min  = parse_timestamp($results->{globals}->{ts}->{min});
         my $max  = parse_timestamp($results->{globals}->{ts}->{max});
         my $diff = unix_timestamp($max) - unix_timestamp($min);
         $qps     = $global_cnt / ($diff || 1);
         $conc    = $results->{globals}->{$orderby}->{sum} / $diff;
      };
   }

   $global_data->{query_count}        = $global_cnt;
   $global_data->{unique_query_count} = $global_unq;
   $global_data->{queries_per_second} = $qps  if $qps;
   $global_data->{concurrency}        = $conc if $conc;

   if ( exists $results->{globals}->{rate_limit} ) {
      my $rate_limit = $results->{globals}->{rate_limit}->{min} || '';
      my ($type, $limit) = $rate_limit =~ m/^(\w+):(\d+)$/;
      if ( $type && $limit ) {
         $global_data->{rate_limit} = {
            type  => $type,
            limit => int($limit),
         };
      }
      else {
         $global_data->{rate_limit}->{error} = "Invalid rate limit: $rate_limit";
      }

      if (    ($results->{globals}->{rate_limit}->{min} || '')
           ne ($results->{globals}->{rate_limit}->{max} || '') ) {
         $global_data->{rate_limit}->{diff} = 1;
      }
   }

   my %hidden_attrib = (
      arg         => 1,
      fingerprint => 1,
      pos_in_log  => 1,
      ts          => 1,
   );

   foreach my $attrib ( grep { !$hidden_attrib{$_} } @attribs ) {
      my $type = $ea->type_for($attrib) || 'string';
      next if $type eq 'string';
      next unless exists $results->{globals}->{$attrib};

      my $store   = $results->{globals}->{$attrib};
      my $metrics = $ea->stats()->{globals}->{$attrib};
      my $int     = $attrib =~ m/(?:time|wait)$/ ? 0 : 1;

      my $real_attrib = $attrib eq 'bytes' ? 'Query_length' : $attrib;

      if ( $type eq 'num' ) {
         foreach my $m ( qw(sum min max) ) { 
            if ( $int ) {
               $global_data->{metrics}->{$real_attrib}->{$m}
                  = sprintf('%d', $store->{$m} || 0);
            }
            else {  # microsecond
               $global_data->{metrics}->{$real_attrib}->{$m}
                  = sprintf('%.6f',  $store->{$m} || 0);
            }
         }
         foreach my $m ( qw(pct_95 stddev median) ) {
            if ( $int ) {
               $global_data->{metrics}->{$real_attrib}->{$m}
                  = sprintf('%d', $metrics->{$m} || 0);
            }
            else {  # microsecond
               $global_data->{metrics}->{$real_attrib}->{$m}
                  = sprintf('%.6f',  $metrics->{$m} || 0);
            }
         }
         if ( $int ) {
            $global_data->{metrics}->{$real_attrib}->{avg}
               = sprintf('%d', $store->{sum} / $store->{cnt});
         }
         else {
            $global_data->{metrics}->{$real_attrib}->{avg}
               = sprintf('%.6f', $store->{sum} / $store->{cnt});
         }  
      }
      elsif ( $type eq 'bool' ) {
         my $store = $results->{globals}->{$real_attrib};
         $global_data->{metrics}->{$real_attrib}->{cnt}
            = sprintf('%d', $store->{sum});
      }
   }


   my @classes;
   foreach my $worst_info ( @$worst ) {
      my $item   = $worst_info->[0];
      my $stats  = $ea->results->{classes}->{$item};
      my $sample = $ea->results->{samples}->{$item};

      my $all_log_pos = $ea->{result_classes}->{$item}->{pos_in_log}->{all};
      my $times_seen  = sum values %$all_log_pos;

      my $distill     = $groupby eq 'fingerprint' ? $qr->distill($sample->{arg})
                      :                             undef;
      my $fingerprint = substr($item, 0, $self->max_fingerprint_length);
      my $checksum    = make_checksum($item);
      my $class       = {
         checksum    => $checksum,
         fingerprint => $fingerprint,
         distillate  => $distill,
         attribute   => $groupby,
         query_count => $times_seen,
         $args{anon} ? () : (
            example     => {
               query      => substr($sample->{arg}, 0, $self->max_query_length),
               ts         => $sample->{ts} ? parse_timestamp($sample->{ts}) : undef,
               Query_time => $sample->{Query_time},
            },
         ),
      };

      my %metrics;
      foreach my $attrib ( @attribs ) {
         my $real_attrib = $attrib eq 'bytes' ? 'Query_length' : $attrib;
         next if $real_attrib eq 'Rows_affected'
            && $distill && $distill =~ m/^(?:SELECT|SHOW|SET|ADMIN)/;
         $metrics{$real_attrib} = $ea->metrics(
            attrib => $attrib,
            where  => $item,
         );
      }

      foreach my $attrib ( keys %metrics ) {
         if ( ! grep { $_ } values %{$metrics{$attrib}} ) {
            delete $metrics{$attrib};
            next;
         }
         delete $metrics{pos_in_log};
         delete $metrics{$attrib}->{cnt};

         if ($attrib eq 'ts') {
            my $ts = delete $metrics{ts};
            foreach my $thing ( qw(min max) ) {
               next unless defined $ts && defined $ts->{$thing};
               $ts->{$thing} = parse_timestamp($ts->{$thing});
            }
            $class->{ts_min} = $ts->{min};
            $class->{ts_max} = $ts->{max};
         }
         else {
            my $type = $attrib eq 'Query_length' ? 'num' : $ea->type_for($attrib) || 'string';
            if ( $type eq 'string' ) {
               $metrics{$attrib} = { value => $metrics{$attrib}{max} }; 
            }
            elsif ( $type eq 'num' ) {
               foreach my $value ( values %{$metrics{$attrib}} ) {
                  next unless defined $value;
                  if ( $attrib =~ m/_(?:time|wait)$/ ) {
                     $value = sprintf('%.6f', $value);
                  }
                  else {
                     $value = sprintf('%d', $value);
                  }
               }
            }
            elsif ( $type eq 'bool' ) {
               $metrics{$attrib} = {
                  yes => sprintf('%d', $metrics{$attrib}->{sum}),
               };
            }
         }
      }

      my @tables;
      if ( $groupby eq 'fingerprint' ) {
         my $default_db = $sample->{db}       ? $sample->{db}
                        : $stats->{db}->{unq} ? keys %{$stats->{db}->{unq}}
                        :                       undef;
         my @table_names = $self->QueryParser->extract_tables(
            query      => $sample->{arg} || '',
            default_db => $default_db,
            Quoter     => $q,
         );
         my $mark = $args{no_v_format} ? '' : '\G';

         foreach my $db_tbl ( @table_names ) {
            my ( $db, $tbl ) = @$db_tbl;
            my $status
               = 'SHOW TABLE STATUS'
               . ($db ? " FROM `$db`" : '')
               . " LIKE '$tbl'${mark}";
            my $create
               = "SHOW CREATE TABLE "
               . $q->quote(grep { $_ } @$db_tbl)
               . ${mark};
            push @tables, { status => $status, create => $create };
         }

         if ( !$args{anon} ) {
            if ( $item =~ m/^(?:[\(\s]*select|insert|replace)/ ) {
               if ( $item =~ m/^(?:insert|replace)/ ) {
               }
               else {

               }
            }
            else {
               my $converted = $qr->convert_to_select(
                  $sample->{arg} || '',
               );
               if ( $converted && $converted =~ m/^[\(\s]*select/i ) {
                  $class->{example}->{as_select} = $converted;
               }
            }
         }
      }

      my $vals = $stats->{Query_time}->{all};
      if ( defined $vals && scalar %$vals ) {
         my @buck_tens = $ea->buckets_of(10);
         my @distro = map { 0 } (0 .. 7);
         my @buckets = map { 0 } (0..999);
         map { $buckets[$_] = $vals->{$_} } keys %$vals;
         $vals = \@buckets;  # repoint vals from given hashref to our array
         map { $distro[$buck_tens[$_]] += $vals->[$_] } (1 .. @$vals - 1);
         $class->{histograms}->{Query_time} = \@distro;
      } # histogram

      $class->{metrics} = \%metrics;
      if ( @tables ) {
         $class->{tables} = \@tables;
      }
      push @classes, $class;
   }

   my $data = {
      global  => $global_data,
      classes => \@classes,
   };
   my $json = $self->encode_json($data);
   $json .= "\n" unless $json =~ /\n\Z/;
   return $json;
};

no Lmo;
1;
}
# ###########################################################################
# End JSONReportFormatter package
# ###########################################################################

# ###########################################################################
# EventTimeline package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/EventTimeline.pm
#   t/lib/EventTimeline.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package EventTimeline;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

Transformers->import(qw(parse_timestamp secs_to_time unix_timestamp));

use constant KEY     => 0;
use constant CNT     => 1;
use constant ATT     => 2;

sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(groupby attributes) ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   my %is_groupby = map { $_ => 1 } @{$args{groupby}};

   return bless {
      groupby    => $args{groupby},
      attributes => [ grep { !$is_groupby{$_} } @{$args{attributes}} ],
      results    => [],
   }, $class;
}

sub reset_aggregated_data {
   my ( $self ) = @_;
   $self->{results} = [];
}

sub aggregate {
   my ( $self, $event ) = @_;
   my $handler = $self->{handler};
   if ( !$handler ) {
      $handler = $self->make_handler($event);
      $self->{handler} = $handler;
   }
   return unless $handler;
   $handler->($event);
}

sub results {
   my ( $self ) = @_;
   return $self->{results};
}

sub make_handler {
   my ( $self, $event ) = @_;

   my $float_re = qr{[+-]?(?:(?=\d|[.])\d*(?:[.])\d{0,})?(?:[E](?:[+-]?\d+)|)}i;
   my @lines; # lines of code for the subroutine

   foreach my $attrib ( @{$self->{attributes}} ) {
      my ($val) = $event->{$attrib};
      next unless defined $val; # Can't decide type if it's undef.

      my $type = $val  =~ m/^(?:\d+|$float_re)$/o ? 'num'
               : $val  =~ m/^(?:Yes|No)$/         ? 'bool'
               :                                    'string';
      PTDEBUG && _d('Type for', $attrib, 'is', $type, '(sample:', $val, ')');
      $self->{type_for}->{$attrib} = $type;

      push @lines, (
         "\$val = \$event->{$attrib};",
         'defined $val && do {',
         "# type: $type",
         "\$store = \$last->[ATT]->{$attrib} ||= {};",
      );

      if ( $type eq 'bool' ) {
         push @lines, q{$val = $val eq 'Yes' ? 1 : 0;};
         $type = 'num';
      }
      my $op   = $type eq 'num' ? '<' : 'lt';
      push @lines, (
         '$store->{min} = $val if !defined $store->{min} || $val '
            . $op . ' $store->{min};',
      );
      $op = ($type eq 'num') ? '>' : 'gt';
      push @lines, (
         '$store->{max} = $val if !defined $store->{max} || $val '
            . $op . ' $store->{max};',
      );
      if ( $type eq 'num' ) {
         push @lines, '$store->{sum} += $val;';
      }
      push @lines, '};';
   }

   unshift @lines, (
      'sub {',
      'my ( $event ) = @_;',
      'my ($val, $last, $store);', # NOTE: define all variables here
      '$last = $results->[-1];',
      'if ( !$last || '
         . join(' || ',
            map { "\$last->[KEY]->[$_] ne (\$event->{$self->{groupby}->[$_]} || 0)" }
                (0 .. @{$self->{groupby}} -1))
         . ' ) {',
      '  $last = [['
         . join(', ',
            map { "(\$event->{$self->{groupby}->[$_]} || 0)" }
                (0 .. @{$self->{groupby}} -1))
         . '], 0, {} ];',
      '  push @$results, $last;',
      '}',
      '++$last->[CNT];',
   );
   push @lines, '}';
   my $results = $self->{results}; # Referred to by the eval
   my $code = join("\n", @lines);
   $self->{code} = $code;

   PTDEBUG && _d('Timeline handler:', $code);
   my $sub = eval $code;
   die if $EVAL_ERROR;
   return $sub;
}

sub report {
   my ( $self, $results, $callback ) = @_;
   $callback->("# " . ('#' x 72) . "\n");
   $callback->("# " . join(',', @{$self->{groupby}}) . " report\n");
   $callback->("# " . ('#' x 72) . "\n");
   foreach my $res ( @$results ) {
      my $t;
      my @vals;
      if ( ($t = $res->[ATT]->{ts}) && $t->{min} ) {
         my $min = parse_timestamp($t->{min});
         push @vals, $min;
         if ( $t->{max} && $t->{max} gt $t->{min} ) {
            my $max  = parse_timestamp($t->{max});
            my $diff = secs_to_time(unix_timestamp($max) - unix_timestamp($min));
            push @vals, $diff;
         }
         else {
            push @vals, '0:00';
         }
      }
      else {
         push @vals, ('', '');
      }
      $callback->(sprintf("# %19s %7s %3d %s\n", @vals, $res->[CNT], $res->[KEY]->[0]));
   }
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
# End EventTimeline package
# ###########################################################################

# ###########################################################################
# QueryParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/QueryParser.pm
#   t/lib/QueryParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package QueryParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

our $tbl_ident = qr/(?:`[^`]+`|\w+)(?:\.(?:`[^`]+`|\w+))?/;
our $tbl_regex = qr{
         \b(?:FROM|JOIN|(?<!KEY\s)UPDATE|INTO) # Words that precede table names
         \b\s*
         \(?                                   # Optional paren around tables
         ($tbl_ident
            (?: (?:\s+ (?:AS\s+)? \w+)?, \s*$tbl_ident )*
         )
      }xio;
our $has_derived = qr{
      \b(?:FROM|JOIN|,)
      \s*\(\s*SELECT
   }xi;

our $data_def_stmts = qr/(?:CREATE|ALTER|TRUNCATE|DROP|RENAME)/i;

our $data_manip_stmts = qr/(?:INSERT|UPDATE|DELETE|REPLACE)/i;

sub new {
   my ( $class ) = @_;
   bless {}, $class;
}

sub get_tables {
   my ( $self, $query ) = @_;
   return unless $query;
   PTDEBUG && _d('Getting tables for', $query);

   my ( $ddl_stmt ) = $query =~ m/^\s*($data_def_stmts)\b/i;
   if ( $ddl_stmt ) {
      PTDEBUG && _d('Special table type:', $ddl_stmt);
      $query =~ s/IF\s+(?:NOT\s+)?EXISTS//i;
      if ( $query =~ m/$ddl_stmt DATABASE\b/i ) {
         PTDEBUG && _d('Query alters a database, not a table');
         return ();
      }
      if ( $ddl_stmt =~ m/CREATE/i && $query =~ m/$ddl_stmt\b.+?\bSELECT\b/i ) {
         my ($select) = $query =~ m/\b(SELECT\b.+)/is;
         PTDEBUG && _d('CREATE TABLE ... SELECT:', $select);
         return $self->get_tables($select);
      }
      my ($tbl) = $query =~ m/TABLE\s+($tbl_ident)(\s+.*)?/i;
      PTDEBUG && _d('Matches table:', $tbl);
      return ($tbl);
   }

   $query =~ s/(?:LOW_PRIORITY|IGNORE|STRAIGHT_JOIN|DELAYED)\s+/ /ig;

   if ( $query =~ s/^\s*LOCK TABLES\s+//i ) {
      PTDEBUG && _d('Special table type: LOCK TABLES');
      $query =~ s/\s+(?:READ(?:\s+LOCAL)?|WRITE)\s*//gi;
      PTDEBUG && _d('Locked tables:', $query);
      $query = "FROM $query";
   }

   $query =~ s/\\["']//g;   # quoted strings
   $query =~ s/".*?"/?/sg;  # quoted strings
   $query =~ s/'.*?'/?/sg;  # quoted strings

   if ( $query =~ m/\A\s*(?:INSERT|REPLACE)(?!\s+INTO)/i ) {
      $query =~ s/\A\s*((?:INSERT|REPLACE))\s+/$1 INTO /i;
   }

   if ( $query =~ m/\A\s*LOAD DATA/i ) {
      my ($tbl) = $query =~ m/INTO TABLE\s+(\S+)/i;
      return $tbl;
   }

   my @tables;
   foreach my $tbls ( $query =~ m/$tbl_regex/gio ) {
      PTDEBUG && _d('Match tables:', $tbls);

      next if $tbls =~ m/\ASELECT\b/i;

      foreach my $tbl ( split(',', $tbls) ) {
         $tbl =~ s/\s*($tbl_ident)(\s+.*)?/$1/gio;

         if ( $tbl !~ m/[a-zA-Z]/ ) {
            PTDEBUG && _d('Skipping suspicious table name:', $tbl);
            next;
         }

         push @tables, $tbl;
      }
   }
   return @tables;
}

sub has_derived_table {
   my ( $self, $query ) = @_;
   my $match = $query =~ m/$has_derived/;
   PTDEBUG && _d($query, 'has ' . ($match ? 'a' : 'no') . ' derived table');
   return $match;
}

sub get_aliases {
   my ( $self, $query, $list ) = @_;

   my $result = {
      DATABASE => {},
      TABLE    => {},
   };
   return $result unless $query;

   $query =~ s/ (?:LOW_PRIORITY|IGNORE|STRAIGHT_JOIN)//ig;

   $query =~ s/ (?:INNER|OUTER|CROSS|LEFT|RIGHT|NATURAL)//ig;

   my @tbl_refs;
   my ($tbl_refs, $from) = $query =~ m{
      (
         (FROM|INTO|UPDATE)\b\s*   # Keyword before table refs
         .+?                       # Table refs
      )
      (?:\s+|\z)                   # If the query does not end with the table
      (?:WHERE|ORDER|LIMIT|HAVING|SET|VALUES|\z) # Keyword after table refs
   }ix;

   if ( $tbl_refs ) {

      if ( $query =~ m/^(?:INSERT|REPLACE)/i ) {
         $tbl_refs =~ s/\([^\)]+\)\s*//;
      }

      PTDEBUG && _d('tbl refs:', $tbl_refs);

      my $before_tbl = qr/(?:,|JOIN|\s|$from)+/i;

      my $after_tbl  = qr/(?:,|JOIN|ON|USING|\z)/i;

      $tbl_refs =~ s/ = /=/g;

      while (
         $tbl_refs =~ m{
            $before_tbl\b\s*
               ( ($tbl_ident) (?:\s+ (?:AS\s+)? (\w+))? )
            \s*$after_tbl
         }xgio )
      {
         my ( $tbl_ref, $db_tbl, $alias ) = ($1, $2, $3);
         PTDEBUG && _d('Match table:', $tbl_ref);
         push @tbl_refs, $tbl_ref;
         $alias = $self->trim_identifier($alias);

         if ( $tbl_ref =~ m/^AS\s+\w+/i ) {
            PTDEBUG && _d('Subquery', $tbl_ref);
            $result->{TABLE}->{$alias} = undef;
            next;
         }

         my ( $db, $tbl ) = $db_tbl =~ m/^(?:(.*?)\.)?(.*)/;
         $db  = $self->trim_identifier($db);
         $tbl = $self->trim_identifier($tbl);
         $result->{TABLE}->{$alias || $tbl} = $tbl;
         $result->{DATABASE}->{$tbl}        = $db if $db;
      }
   }
   else {
      PTDEBUG && _d("No tables ref in", $query);
   }

   if ( $list ) {
      return \@tbl_refs;
   }
   else {
      return $result;
   }
}

sub split {
   my ( $self, $query ) = @_;
   return unless $query;
   $query = $self->clean_query($query);
   PTDEBUG && _d('Splitting', $query);

   my $verbs = qr{SELECT|INSERT|UPDATE|DELETE|REPLACE|UNION|CREATE}i;

   my @split_statements = grep { $_ } split(m/\b($verbs\b(?!(?:\s*\()))/io, $query);

   my @statements;
   if ( @split_statements == 1 ) {
      push @statements, $query;
   }
   else {
      for ( my $i = 0; $i <= $#split_statements; $i += 2 ) {
         push @statements, $split_statements[$i].$split_statements[$i+1];

         if ( $statements[-2] && $statements[-2] =~ m/on duplicate key\s+$/i ) {
            $statements[-2] .= pop @statements;
         }
      }
   }

   PTDEBUG && _d('statements:', map { $_ ? "<$_>" : 'none' } @statements);
   return @statements;
}

sub clean_query {
   my ( $self, $query ) = @_;
   return unless $query;
   $query =~ s!/\*.*?\*/! !g;  # Remove /* comment blocks */
   $query =~ s/^\s+//;         # Remove leading spaces
   $query =~ s/\s+$//;         # Remove trailing spaces
   $query =~ s/\s{2,}/ /g;     # Remove extra spaces
   return $query;
}

sub split_subquery {
   my ( $self, $query ) = @_;
   return unless $query;
   $query = $self->clean_query($query);
   $query =~ s/;$//;

   my @subqueries;
   my $sqno = 0;  # subquery number
   my $pos  = 0;
   while ( $query =~ m/(\S+)(?:\s+|\Z)/g ) {
      $pos = pos($query);
      my $word = $1;
      PTDEBUG && _d($word, $sqno);
      if ( $word =~ m/^\(?SELECT\b/i ) {
         my $start_pos = $pos - length($word) - 1;
         if ( $start_pos ) {
            $sqno++;
            PTDEBUG && _d('Subquery', $sqno, 'starts at', $start_pos);
            $subqueries[$sqno] = {
               start_pos => $start_pos,
               end_pos   => 0,
               len       => 0,
               words     => [$word],
               lp        => 1, # left parentheses
               rp        => 0, # right parentheses
               done      => 0,
            };
         }
         else {
            PTDEBUG && _d('Main SELECT at pos 0');
         }
      }
      else {
         next unless $sqno;  # next unless we're in a subquery
         PTDEBUG && _d('In subquery', $sqno);
         my $sq = $subqueries[$sqno];
         if ( $sq->{done} ) {
            PTDEBUG && _d('This subquery is done; SQL is for',
               ($sqno - 1 ? "subquery $sqno" : "the main SELECT"));
            next;
         }
         push @{$sq->{words}}, $word;
         my $lp = ($word =~ tr/\(//) || 0;
         my $rp = ($word =~ tr/\)//) || 0;
         PTDEBUG && _d('parentheses left', $lp, 'right', $rp);
         if ( ($sq->{lp} + $lp) - ($sq->{rp} + $rp) == 0 ) {
            my $end_pos = $pos - 1;
            PTDEBUG && _d('Subquery', $sqno, 'ends at', $end_pos);
            $sq->{end_pos} = $end_pos;
            $sq->{len}     = $end_pos - $sq->{start_pos};
         }
      }
   }

   for my $i ( 1..$#subqueries ) {
      my $sq = $subqueries[$i];
      next unless $sq;
      $sq->{sql} = join(' ', @{$sq->{words}});
      substr $query,
         $sq->{start_pos} + 1,  # +1 for (
         $sq->{len} - 1,        # -1 for )
         "__subquery_$i";
   }

   return $query, map { $_->{sql} } grep { defined $_ } @subqueries;
}

sub query_type {
   my ( $self, $query, $qr ) = @_;
   my ($type, undef) = $qr->distill_verbs($query);
   my $rw;
   if ( $type =~ m/^SELECT\b/ ) {
      $rw = 'read';
   }
   elsif ( $type =~ m/^$data_manip_stmts\b/
           || $type =~ m/^$data_def_stmts\b/  ) {
      $rw = 'write'
   }

   return {
      type => $type,
      rw   => $rw,
   }
}

sub get_columns {
   my ( $self, $query ) = @_;
   my $cols = [];
   return $cols unless $query;
   my $cols_def;

   if ( $query =~ m/^SELECT/i ) {
      $query =~ s/
         ^SELECT\s+
           (?:ALL
              |DISTINCT
              |DISTINCTROW
              |HIGH_PRIORITY
              |STRAIGHT_JOIN
              |SQL_SMALL_RESULT
              |SQL_BIG_RESULT
              |SQL_BUFFER_RESULT
              |SQL_CACHE
              |SQL_NO_CACHE
              |SQL_CALC_FOUND_ROWS
           )\s+
      /SELECT /xgi;
      ($cols_def) = $query =~ m/^SELECT\s+(.+?)\s+FROM/i;
   }
   elsif ( $query =~ m/^(?:INSERT|REPLACE)/i ) {
      ($cols_def) = $query =~ m/\(([^\)]+)\)\s*VALUE/i;
   }

   PTDEBUG && _d('Columns:', $cols_def);
   if ( $cols_def ) {
      @$cols = split(',', $cols_def);
      map {
         my $col = $_;
         $col = s/^\s+//g;
         $col = s/\s+$//g;
         $col;
      } @$cols;
   }

   return $cols;
}

sub parse {
   my ( $self, $query ) = @_;
   return unless $query;
   my $parsed = {};

   $query =~ s/\n/ /g;
   $query = $self->clean_query($query);

   $parsed->{query}   = $query,
   $parsed->{tables}  = $self->get_aliases($query, 1);
   $parsed->{columns} = $self->get_columns($query);

   my ($type) = $query =~ m/^(\w+)/;
   $parsed->{type} = lc $type;


   $parsed->{sub_queries} = [];

   return $parsed;
}

sub extract_tables {
   my ( $self, %args ) = @_;
   my $query      = $args{query};
   my $default_db = $args{default_db};
   my $q          = $self->{Quoter} || $args{Quoter};
   return unless $query;
   PTDEBUG && _d('Extracting tables');
   my @tables;
   my %seen;
   foreach my $db_tbl ( $self->get_tables($query) ) {
      next unless $db_tbl;
      next if $seen{$db_tbl}++; # Unique-ify for issue 337.
      my ( $db, $tbl ) = $q->split_unquote($db_tbl);
      push @tables, [ $db || $default_db, $tbl ];
   }
   return @tables;
}

sub trim_identifier {
   my ($self, $str) = @_;
   return unless defined $str;
   $str =~ s/`//g;
   $str =~ s/^\s+//;
   $str =~ s/\s+$//;
   return $str;
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
# End QueryParser package
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
# QueryReview package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/QueryReview.pm
#   t/lib/QueryReview.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package QueryReview;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

Transformers->import(qw(make_checksum parse_timestamp));

my %basic_cols = map { $_ => 1 }
   qw(checksum fingerprint sample first_seen last_seen reviewed_by
      reviewed_on comments);
my %skip_cols  = map { $_ => 1 } qw(fingerprint sample checksum);

sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw(dbh db_tbl tbl_struct quoter) ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   foreach my $col ( keys %basic_cols ) {
      die "Query review table $args{db_tbl} does not have a $col column"
         unless $args{tbl_struct}->{is_col}->{$col};
   }

   my $now = defined $args{ts_default} ? $args{ts_default} : 'NOW()';

   my $sql = <<"      SQL";
      INSERT INTO $args{db_tbl}
      (checksum, fingerprint, sample, first_seen, last_seen)
      VALUES(?, ?, ?, COALESCE(?, $now), COALESCE(?, $now))
      ON DUPLICATE KEY UPDATE
         first_seen = IF(
            first_seen IS NULL,
            COALESCE(?, $now),
            LEAST(first_seen, COALESCE(?, $now))),
         last_seen = IF(
            last_seen IS NULL,
            COALESCE(?, $now),
            GREATEST(last_seen, COALESCE(?, $now)))
      SQL
   PTDEBUG && _d('SQL to insert into review table:', $sql);
   my $insert_sth = $args{dbh}->prepare($sql);

   my @review_cols = grep { !$skip_cols{$_} } @{$args{tbl_struct}->{cols}};
   $sql = "SELECT "
        . join(', ', map { $args{quoter}->quote($_) } @review_cols)
        . ", checksum AS checksum_conv FROM $args{db_tbl}"
        . " WHERE checksum=?";
   PTDEBUG && _d('SQL to select from review table:', $sql);
   my $select_sth = $args{dbh}->prepare($sql);

   my $self = {
      dbh         => $args{dbh},
      db_tbl      => $args{db_tbl},
      insert_sth  => $insert_sth,
      select_sth  => $select_sth,
      tbl_struct  => $args{tbl_struct},
      quoter      => $args{quoter},
      ts_default  => $now,
   };
   return bless $self, $class;
}

sub get_review_info {
   my ( $self, $id ) = @_;
   $self->{select_sth}->execute(make_checksum($id));
   my $review_vals = $self->{select_sth}->fetchall_arrayref({});
   if ( $review_vals && @$review_vals == 1 ) {
      return $review_vals->[0];
   }
   return undef;
}

sub set_review_info {
   my ( $self, %args ) = @_;
   $self->{insert_sth}->execute(
      make_checksum($args{fingerprint}),
      @args{qw(fingerprint sample)},
      map { $args{$_} ? parse_timestamp($args{$_}) : undef }
         qw(first_seen last_seen first_seen first_seen last_seen last_seen));
}

sub review_cols {
   my ( $self ) = @_;
   return grep { !$skip_cols{$_} } @{$self->{tbl_struct}->{cols}};
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
# End QueryReview package
# ###########################################################################

# ###########################################################################
# QueryHistory package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/QueryHistory.pm
#   t/lib/QueryHistory.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package QueryHistory;

use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Lmo;

use Quoter;
use Transformers qw(make_checksum parse_timestamp);

has history_dbh => (
   is       => 'ro',
   required => 1,
);

has history_sth => (
   is => 'rw',
);

has history_metrics => (
   is => 'rw',
   isa => 'ArrayRef',
);

has column_pattern => (
   is       => 'ro',
   isa      => 'Regexp',
   required => 1,
);

has ts_default => (
   is      => 'ro',
   isa     => 'Str',
   default => sub { 'NOW()' },
);

sub set_history_options {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(table tbl_struct) ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   my $col_pat = $self->column_pattern();

   my @cols;
   my @metrics;
   foreach my $col ( @{$args{tbl_struct}->{cols}} ) {
      my ( $attr, $metric ) = $col =~ m/$col_pat/;
      next unless $attr && $metric;


      $attr = ucfirst $attr if $attr =~ m/_/;
      $attr = 'Filesort' if $attr eq 'filesort';

      $attr =~ s/^Qc_hit/QC_Hit/;  # Qc_hit is really QC_Hit
      $attr =~ s/^Innodb/InnoDB/g; # Innodb is really InnoDB
      $attr =~ s/_io_/_IO_/g;      # io is really IO

      push @cols, $col;
      push @metrics, [$attr, $metric];
   }

   my $ts_default = $self->ts_default;

   my $sql = "REPLACE INTO $args{table}("
      . join(', ',
         map { Quoter->quote($_) } ('checksum', 'sample', @cols))
      . ') VALUES (?, ?'
      . (@cols ? ', ' : '')  # issue 1265
      . join(', ', map {
         $_ eq 'ts_min' || $_ eq 'ts_max'
            ? "COALESCE(?, $ts_default)"
            : '?'
        } @cols) . ')';
   PTDEBUG && _d($sql);

   $self->history_sth($self->history_dbh->prepare($sql));
   $self->history_metrics(\@metrics);

   return;
}

sub set_review_history {
   my ( $self, $id, $sample, %data ) = @_;
   foreach my $thing ( qw(min max) ) {
      next unless defined $data{ts} && defined $data{ts}->{$thing};
      $data{ts}->{$thing} = parse_timestamp($data{ts}->{$thing});
   }
   $self->history_sth->execute(
      make_checksum($id),
      $sample,
      map { $data{$_->[0]}->{$_->[1]} } @{$self->history_metrics});
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
# End QueryHistory package
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
use Fcntl qw(:DEFAULT);

sub new {
   my ($class, %args) = @_;
   my $self = {
      log_file       => $args{log_file},
      pid_file       => $args{pid_file},
      daemonize      => $args{daemonize},
      force_log_file => $args{force_log_file},
      parent_exit    => $args{parent_exit},
      pid_file_owner => 0,
   };
   return bless $self, $class;
}

sub run {
   my ($self) = @_;

   my $daemonize      = $self->{daemonize};
   my $pid_file       = $self->{pid_file};
   my $log_file       = $self->{log_file};
   my $force_log_file = $self->{force_log_file};
   my $parent_exit    = $self->{parent_exit};

   PTDEBUG && _d('Starting daemon');

   if ( $pid_file ) {
      eval {
         $self->_make_pid_file(
            pid      => $PID,  # parent's pid
            pid_file => $pid_file,
         );
      };
      die "$EVAL_ERROR\n" if $EVAL_ERROR;
      if ( !$daemonize ) {
         $self->{pid_file_owner} = $PID;  # parent's pid
      }
   }

   if ( $daemonize ) {
      defined (my $child_pid = fork()) or die "Cannot fork: $OS_ERROR";
      if ( $child_pid ) {
         PTDEBUG && _d('Forked child', $child_pid);
         $parent_exit->($child_pid) if $parent_exit;
         exit 0;
      }
 
      POSIX::setsid() or die "Cannot start a new session: $OS_ERROR";
      chdir '/'       or die "Cannot chdir to /: $OS_ERROR";

      if ( $pid_file ) {
         $self->_update_pid_file(
            pid      => $PID,  # child's pid
            pid_file => $pid_file,
         );
         $self->{pid_file_owner} = $PID;
      }
   }

   if ( $daemonize || $force_log_file ) {
      PTDEBUG && _d('Redirecting STDIN to /dev/null');
      close STDIN;
      open  STDIN, '/dev/null'
         or die "Cannot reopen STDIN to /dev/null: $OS_ERROR";
      if ( $log_file ) {
         PTDEBUG && _d('Redirecting STDOUT and STDERR to', $log_file);
         close STDOUT;
         open  STDOUT, '>>', $log_file
            or die "Cannot open log file $log_file: $OS_ERROR";

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

      $OUTPUT_AUTOFLUSH = 1;
   }

   PTDEBUG && _d('Daemon running');
   return;
}

sub _make_pid_file {
   my ($self, %args) = @_;
   my @required_args = qw(pid pid_file);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   };
   my $pid      = $args{pid};
   my $pid_file = $args{pid_file};

   eval {
      sysopen(PID_FH, $pid_file, O_RDWR|O_CREAT|O_EXCL) or die $OS_ERROR;
      print PID_FH $PID, "\n";
      close PID_FH; 
   };
   if ( my $e = $EVAL_ERROR ) {
      if ( $e =~ m/file exists/i ) {
         my $old_pid = $self->_check_pid_file(
            pid_file => $pid_file,
            pid      => $PID,
         );
         if ( $old_pid ) {
            warn "Overwriting PID file $pid_file because PID $old_pid "
               . "is not running.\n";
         }
         $self->_update_pid_file(
            pid      => $PID,
            pid_file => $pid_file
         );
      }
      else {
         die "Error creating PID file $pid_file: $e\n";
      }
   }

   return;
}

sub _check_pid_file {
   my ($self, %args) = @_;
   my @required_args = qw(pid_file pid);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   };
   my $pid_file = $args{pid_file};
   my $pid      = $args{pid};

   PTDEBUG && _d('Checking if PID in', $pid_file, 'is running');

   if ( ! -f $pid_file ) {
      PTDEBUG && _d('PID file', $pid_file, 'does not exist');
      return;
   }

   open my $fh, '<', $pid_file
      or die "Error opening $pid_file: $OS_ERROR";
   my $existing_pid = do { local $/; <$fh> };
   chomp($existing_pid) if $existing_pid;
   close $fh
      or die "Error closing $pid_file: $OS_ERROR";

   if ( $existing_pid ) {
      if ( $existing_pid == $pid ) {
         warn "The current PID $pid already holds the PID file $pid_file\n";
         return;
      }
      else {
         PTDEBUG && _d('Checking if PID', $existing_pid, 'is running');
         my $pid_is_alive = kill 0, $existing_pid;
         if ( $pid_is_alive ) {
            die "PID file $pid_file exists and PID $existing_pid is running\n";
         }
      }
   }
   else {
      die "PID file $pid_file exists but it is empty.  Remove the file "
         . "if the process is no longer running.\n";
   }

   return $existing_pid;
}

sub _update_pid_file {
   my ($self, %args) = @_;
   my @required_args = qw(pid pid_file);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   };
   my $pid      = $args{pid};
   my $pid_file = $args{pid_file};

   open my $fh, '>', $pid_file
      or die "Cannot open $pid_file: $OS_ERROR";
   print { $fh } $pid, "\n"
      or die "Cannot print to $pid_file: $OS_ERROR";
   close $fh
      or warn "Cannot close $pid_file: $OS_ERROR";

   return;
}

sub remove_pid_file {
   my ($self, $pid_file) = @_;
   $pid_file ||= $self->{pid_file};
   if ( $pid_file && -f $pid_file ) {
      unlink $self->{pid_file}
         or warn "Cannot remove PID file $pid_file: $OS_ERROR";
      PTDEBUG && _d('Removed PID file');
   }
   else {
      PTDEBUG && _d('No PID to remove');
   }
   return;
}

sub DESTROY {
   my ($self) = @_;

   if ( $self->{pid_file_owner} == $PID ) {
      $self->remove_pid_file();
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
# End Daemon package
# ###########################################################################

# ###########################################################################
# BinaryLogParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/BinaryLogParser.pm
#   t/lib/BinaryLogParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package BinaryLogParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

my $binlog_line_1 = qr/at (\d+)$/m;
my $binlog_line_2 = qr/^#(\d{6}\s+\d{1,2}:\d\d:\d\d)\s+server\s+id\s+(\d+)\s+end_log_pos\s+(\d+)\s+(?:CRC32\s+0x[a-f0-9]{8}\s+)?(\S+)\s*([^\n]*)$/m;
my $binlog_line_2_rest = qr/thread_id=(\d+)\s+exec_time=(\d+)\s+error_code=(\d+)/m;

sub new {
   my ( $class, %args ) = @_;
   my $self = {
      delim     => undef,
      delim_len => 0,
   };
   return bless $self, $class;
}


sub parse_event {
   my ( $self, %args ) = @_;
   my @required_args = qw(next_event tell);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($next_event, $tell) = @args{@required_args};

   local $INPUT_RECORD_SEPARATOR = ";\n#";
   my $pos_in_log = $tell->();
   my $stmt;
   my ($delim, $delim_len) = ($self->{delim}, $self->{delim_len});

   EVENT:
   while ( defined($stmt = $next_event->()) ) {
      my @properties = ('pos_in_log', $pos_in_log);
      my ($ts, $sid, $end, $type, $rest);
      $pos_in_log = $tell->();
      $stmt =~ s/;\n#?\Z//;

      my ( $got_offset, $got_hdr );
      my $pos = 0;
      my $len = length($stmt);
      my $found_arg = 0;
      LINE:
      while ( $stmt =~ m/^(.*)$/mg ) { # /g requires scalar match.
         $pos     = pos($stmt);  # Be careful not to mess this up!
         my $line = $1;          # Necessary for /g and pos() to work.
         $line    =~ s/$delim// if $delim;
         PTDEBUG && _d($line);

         if ( $line =~ m/^\/\*.+\*\/;/ ) {
            PTDEBUG && _d('Comment line');
            next LINE;
         }
 
         if ( $line =~ m/^DELIMITER/m ) {
            my ( $del ) = $line =~ m/^DELIMITER (\S*)$/m;
            if ( $del ) {
               $self->{delim_len} = $delim_len = length $del;
               $self->{delim}     = $delim     = quotemeta $del;
               PTDEBUG && _d('delimiter:', $delim);
            }
            else {
               PTDEBUG && _d('Delimiter reset to ;');
               $self->{delim}     = $delim     = undef;
               $self->{delim_len} = $delim_len = 0;
            }
            next LINE;
         }

         next LINE if $line =~ m/End of log file/;

         if ( !$got_offset && (my ( $offset ) = $line =~ m/$binlog_line_1/m) ) {
            PTDEBUG && _d('Got the at offset line');
            push @properties, 'offset', $offset;
            $got_offset++;
         }

         elsif ( !$got_hdr && $line =~ m/^#(\d{6}\s+\d{1,2}:\d\d:\d\d)/ ) {
            ($ts, $sid, $end, $type, $rest) = $line =~ m/$binlog_line_2/m;
            PTDEBUG && _d('Got the header line; type:', $type, 'rest:', $rest);
            push @properties, 'cmd', 'Query', 'ts', $ts, 'server_id', $sid,
               'end_log_pos', $end;
            $got_hdr++;
         }

         elsif ( $line =~ m/^(?:#|use |SET)/i ) {

            if ( my ( $db ) = $line =~ m/^use ([^;]+)/ ) {
               PTDEBUG && _d("Got a default database:", $db);
               push @properties, 'db', $db;
            }

            elsif ( my ($setting) = $line =~ m/^SET\s+([^;]*)/ ) {
               PTDEBUG && _d("Got some setting:", $setting);
               push @properties, map { s/\s+//; lc } split(/,|\s*=\s*/, $setting);
            }

         }
         else {
            PTDEBUG && _d("Got the query/arg line at pos", $pos);
            $found_arg++;
            if ( $got_offset && $got_hdr ) {
               if ( $type eq 'Xid' ) {
                  my ($xid) = $rest =~ m/(\d+)/;
                  push @properties, 'Xid', $xid;
               }
               elsif ( $type eq 'Query' ) {
                  my ($i, $t, $c) = $rest =~ m/$binlog_line_2_rest/m;
                  push @properties, 'Thread_id', $i, 'Query_time', $t,
                                    'error_code', $c;
               }
               elsif ( $type eq 'Start:' ) {
                  PTDEBUG && _d("Binlog start");
               }
               else {
                  PTDEBUG && _d('Unknown event type:', $type);
                  next EVENT;
               }
            }
            else {
               PTDEBUG && _d("It's not a query/arg, it's just some SQL fluff");
               push @properties, 'cmd', 'Query', 'ts', undef;
            }

            my $delim_len = ($pos == length($stmt) ? $delim_len : 0);
            my $arg = substr($stmt, $pos - length($line) - $delim_len);

            $arg =~ s/$delim// if $delim; # Remove the delimiter.

            if ( $arg =~ m/^DELIMITER/m ) {
               my ( $del ) = $arg =~ m/^DELIMITER (\S*)$/m;
               if ( $del ) {
                  $self->{delim_len} = $delim_len = length $del;
                  $self->{delim}     = $delim     = quotemeta $del;
                  PTDEBUG && _d('delimiter:', $delim);
               }
               else {
                  PTDEBUG && _d('Delimiter reset to ;');
                  $del       = ';';
                  $self->{delim}     = $delim     = undef;
                  $self->{delim_len} = $delim_len = 0;
               }

               $arg =~ s/^DELIMITER.*$//m;  # Remove DELIMITER from arg.
            }

            $arg =~ s/;$//gm;  # Ensure ending ; are gone.
            $arg =~ s/\s+$//;  # Remove trailing spaces and newlines.

            push @properties, 'arg', $arg, 'bytes', length($arg);
            last LINE;
         }
      } # LINE

      if ( $found_arg ) {
         PTDEBUG && _d('Properties of event:', Dumper(\@properties));
         my $event = { @properties };
         if ( $args{stats} ) {
            $args{stats}->{events_read}++;
            $args{stats}->{events_parsed}++;
         }
         return $event;
      }
      else {
         PTDEBUG && _d('Event had no arg');
      }
   } # EVENT

   $args{oktorun}->(0) if $args{oktorun};
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
# End BinaryLogParser package
# ###########################################################################

# ###########################################################################
# GeneralLogParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/GeneralLogParser.pm
#   t/lib/GeneralLogParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package GeneralLogParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

sub new {
   my ( $class ) = @_;
   my $self = {
      pending => [],
      db_for  => {},
   };
   return bless $self, $class;
}

my $genlog_line_1= qr{
   \A
   (?:(\d{6}\s+\d{1,2}:\d\d:\d\d|\d{4}-\d{1,2}-\d{1,2}T\d\d:\d\d:\d\d\.\d+(?:Z|[-+]?\d\d:\d\d)?))? # Timestamp
   \s+
   (?:\s*(\d+))                     # Thread ID
   \s
   (\w+)                            # Command
   \s+
   (.*)                             # Argument
   \Z
}xs;

sub parse_event {
   my ( $self, %args ) = @_;
   my @required_args = qw(next_event tell);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($next_event, $tell) = @args{@required_args};

   my $pending = $self->{pending};
   my $db_for  = $self->{db_for};
   my $line;
   my $pos_in_log = $tell->();
   LINE:
   while (
         defined($line = shift @$pending)
      or defined($line = $next_event->())
   ) {
      PTDEBUG && _d($line);
      my ($ts, $thread_id, $cmd, $arg) = $line =~ m/$genlog_line_1/;
      if ( !($thread_id && $cmd) ) {
         PTDEBUG && _d('Not start of general log event');
         next;
      }
      my @properties = ('pos_in_log', $pos_in_log, 'ts', $ts,
         'Thread_id', $thread_id);

      $pos_in_log = $tell->();

      @$pending = ();
      if ( $cmd eq 'Query' ) {
         my $done = 0;
         do {
            $line = $next_event->();
            if ( $line ) {
               my (undef, $next_thread_id, $next_cmd)
                  = $line =~ m/$genlog_line_1/;
               if ( $next_thread_id && $next_cmd ) {
                  PTDEBUG && _d('Event done');
                  $done = 1;
                  push @$pending, $line;
               }
               else {
                  PTDEBUG && _d('More arg:', $line);
                  $arg .= $line;
               }
            }
            else {
               PTDEBUG && _d('No more lines');
               $done = 1;
            }
         } until ( $done );

         chomp $arg;
         push @properties, 'cmd', 'Query', 'arg', $arg;
         push @properties, 'bytes', length($properties[-1]);
         push @properties, 'db', $db_for->{$thread_id} if $db_for->{$thread_id};
      }
      else {
         push @properties, 'cmd', 'Admin';

         if ( $cmd eq 'Connect' ) {
            if ( $arg =~ m/^Access denied/ ) {
               $cmd = $arg;
            }
            else {
               my ($user) = $arg =~ m/(\S+)/;
               my ($db)   = $arg =~ m/on (\S+)/;
               my $host;
               ($user, $host) = split(/@/, $user);
               PTDEBUG && _d('Connect', $user, '@', $host, 'on', $db);

               push @properties, 'user', $user if $user;
               push @properties, 'host', $host if $host;
               push @properties, 'db',   $db   if $db;
               $db_for->{$thread_id} = $db;
            }
         }
         elsif ( $cmd eq 'Init' ) {
            $cmd = 'Init DB';
            $arg =~ s/^DB\s+//;
            my ($db) = $arg =~ /(\S+)/;
            PTDEBUG && _d('Init DB:', $db);
            push @properties, 'db',   $db   if $db;
            $db_for->{$thread_id} = $db;
         }

         push @properties, 'arg', "administrator command: $cmd";
         push @properties, 'bytes', length($properties[-1]);
      }

      push @properties, 'Query_time', 0;

      PTDEBUG && _d('Properties of event:', Dumper(\@properties));
      my $event = { @properties };
      if ( $args{stats} ) {
         $args{stats}->{events_read}++;
         $args{stats}->{events_parsed}++;
      }
      return $event;
   } # LINE

   @{$self->{pending}} = ();
   $args{oktorun}->(0) if $args{oktorun};
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
# End GeneralLogParser package
# ###########################################################################

# ###########################################################################
# RawLogParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/RawLogParser.pm
#   t/lib/RawLogParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package RawLogParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

sub new {
   my ( $class ) = @_;
   my $self = {
   };
   return bless $self, $class;
}

sub parse_event {
   my ( $self, %args ) = @_;
   my @required_args = qw(next_event tell);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($next_event, $tell) = @args{@required_args};

   my $line;
   my $pos_in_log = $tell->();
   LINE:
   while ( defined($line = $next_event->()) ) {
      PTDEBUG && _d($line);
      chomp($line);
      my @properties = (
         'pos_in_log', $pos_in_log,
         'cmd',        'Query',
         'bytes',      length($line),
         'Query_time', 0,
         'arg',        $line,
      );

      $pos_in_log = $tell->();

      PTDEBUG && _d('Properties of event:', Dumper(\@properties));
      my $event = { @properties };
      if ( $args{stats} ) {
         $args{stats}->{events_read}++;
         $args{stats}->{events_parsed}++;
      }

      return $event;
   }

   $args{oktorun}->(0) if $args{oktorun};
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
# End RawLogParser package
# ###########################################################################

# ###########################################################################
# ProtocolParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/ProtocolParser.pm
#   t/lib/ProtocolParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package ProtocolParser;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use File::Basename qw(basename);
use File::Temp qw(tempfile);

eval {
   require IO::Uncompress::Inflate; # yum: perl-IO-Compress-Zlib
   IO::Uncompress::Inflate->import(qw(inflate $InflateError));
};

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

sub new {
   my ( $class, %args ) = @_;

   my $self = {
      server      => $args{server},
      port        => $args{port},
      sessions    => {},
      o           => $args{o},
   };

   return bless $self, $class;
}

sub parse_event {
   my ( $self, %args ) = @_;
   my @required_args = qw(event);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $packet = @args{@required_args};

   if ( $self->{buffer} ) {
      my ($packet_from, $session) = $self->_get_session($packet);
      if ( $packet->{data_len} ) {
         if ( $packet_from eq 'client' ) {
            push @{$session->{client_packets}}, $packet;
            PTDEBUG && _d('Saved client packet');
         }
         else {
            push @{$session->{server_packets}}, $packet;
            PTDEBUG && _d('Saved server packet');
         }
      }

      return unless ($packet_from eq 'client')
                    && ($packet->{fin} || $packet->{rst});

      my $event;
      map {
         $event = $self->_parse_packet($_, $args{misc});
         $args{stats}->{events_parsed}++ if $args{stats};
      } sort { $a->{seq} <=> $b->{seq} }
      @{$session->{client_packets}};
      
      map {
         $event = $self->_parse_packet($_, $args{misc});
         $args{stats}->{events_parsed}++ if $args{stats};
      } sort { $a->{seq} <=> $b->{seq} }
      @{$session->{server_packets}};

      return $event;
   }

   if ( $packet->{data_len} == 0 ) {
      PTDEBUG && _d('No TCP data');
      return;
   }

   my $event = $self->_parse_packet($packet, $args{misc});
   $args{stats}->{events_parsed}++ if $args{stats};
   return $event;
}

sub _parse_packet {
   my ( $self, $packet, $misc ) = @_;

   my ($packet_from, $session) = $self->_get_session($packet);
   PTDEBUG && _d('State:', $session->{state});

   push @{$session->{raw_packets}}, $packet->{raw_packet}
      unless $misc->{recurse};

   if ( $session->{buff} ) {
      $session->{buff_left} -= $packet->{data_len};
      if ( $session->{buff_left} > 0 ) {
         PTDEBUG && _d('Added data to buff; expecting', $session->{buff_left},
            'more bytes');
         return;
      }

      PTDEBUG && _d('Got all data; buff left:', $session->{buff_left});
      $packet->{data}       = $session->{buff} . $packet->{data};
      $packet->{data_len}  += length $session->{buff};
      $session->{buff}      = '';
      $session->{buff_left} = 0;
   }

   $packet->{data} = pack('H*', $packet->{data}) unless $misc->{recurse};
   my $event;
   if ( $packet_from eq 'server' ) {
      $event = $self->_packet_from_server($packet, $session, $misc);
   }
   elsif ( $packet_from eq 'client' ) {
      $event = $self->_packet_from_client($packet, $session, $misc);
   }
   else {
      die 'Packet origin unknown';
   }
   PTDEBUG && _d('State:', $session->{state});

   if ( $session->{out_of_order} ) {
      PTDEBUG && _d('Session packets are out of order');
      push @{$session->{packets}}, $packet;
      $session->{ts_min}
         = $packet->{ts} if $packet->{ts} lt ($session->{ts_min} || '');
      $session->{ts_max}
         = $packet->{ts} if $packet->{ts} gt ($session->{ts_max} || '');
      if ( $session->{have_all_packets} ) {
         PTDEBUG && _d('Have all packets; ordering and processing');
         delete $session->{out_of_order};
         delete $session->{have_all_packets};
         map {
            $event = $self->_parse_packet($_, { recurse => 1 });
         } sort { $a->{seq} <=> $b->{seq} } @{$session->{packets}};
      }
   }

   PTDEBUG && _d('Done with packet; event:', Dumper($event));
   return $event;
}

sub _get_session {
   my ( $self, $packet ) = @_;

   my $src_host = "$packet->{src_host}:$packet->{src_port}";
   my $dst_host = "$packet->{dst_host}:$packet->{dst_port}";

   if ( my $server = $self->{server} ) {  # Watch only the given server.
      $server .= ":$self->{port}";
      if ( $src_host ne $server && $dst_host ne $server ) {
         PTDEBUG && _d('Packet is not to or from', $server);
         return;
      }
   }

   my $packet_from;
   my $client;
   if ( $src_host =~ m/:$self->{port}$/ ) {
      $packet_from = 'server';
      $client      = $dst_host;
   }
   elsif ( $dst_host =~ m/:$self->{port}$/ ) {
      $packet_from = 'client';
      $client      = $src_host;
   }
   else {
      warn 'Packet is not to or from server: ', Dumper($packet);
      return;
   }
   PTDEBUG && _d('Client:', $client);

   if ( !exists $self->{sessions}->{$client} ) {
      PTDEBUG && _d('New session');
      $self->{sessions}->{$client} = {
         client      => $client,
         state       => undef,
         raw_packets => [],
      };
   };
   my $session = $self->{sessions}->{$client};

   return $packet_from, $session;
}

sub _packet_from_server {
   die "Don't call parent class _packet_from_server()";
}

sub _packet_from_client {
   die "Don't call parent class _packet_from_client()";
}

sub make_event {
   my ( $self, $session, $packet ) = @_;
   die "Event has no attributes" unless scalar keys %{$session->{attribs}};
   die "Query has no arg attribute" unless $session->{attribs}->{arg};
   my $start_request = $session->{start_request} || 0;
   my $start_reply   = $session->{start_reply}   || 0;
   my $end_reply     = $session->{end_reply}     || 0;
   PTDEBUG && _d('Request start:', $start_request,
      'reply start:', $start_reply, 'reply end:', $end_reply);
   my $event = {
      Query_time    => $self->timestamp_diff($start_request, $start_reply),
      Transmit_time => $self->timestamp_diff($start_reply, $end_reply),
   };
   @{$event}{keys %{$session->{attribs}}} = values %{$session->{attribs}};
   return $event;
}

sub _get_errors_fh {
   my ( $self ) = @_;
   return $self->{errors_fh} if $self->{errors_fh};

   my $exec = basename($0);
   my ($errors_fh, $filename);
   if ( $filename = $ENV{PERCONA_TOOLKIT_TCP_ERRORS_FILE} ) {
      open $errors_fh, ">", $filename
         or die "Cannot open $filename for writing (supplied from "
              . "PERCONA_TOOLKIT_TCP_ERRORS_FILE): $OS_ERROR";
   }
   else {
      ($errors_fh, $filename) = tempfile("/tmp/$exec-errors.XXXXXXX", UNLINK => 0);
   }

   $self->{errors_file} = $filename;
   $self->{errors_fh}   = $errors_fh;
   return $errors_fh;
}

sub fail_session {
   my ( $self, $session, $reason ) = @_;
   PTDEBUG && _d('Failed session', $session->{client}, 'because', $reason);
   delete $self->{sessions}->{$session->{client}};

   return if $self->{_no_save_error};

   my $errors_fh = $self->_get_errors_fh();

   warn "TCP session $session->{client} had errors, will save them in $self->{errors_file}\n"
      unless $self->{_warned_for}->{$self->{errors_file}}++;

   my $raw_packets = delete $session->{raw_packets};
   $session->{reason_for_failure} = $reason;
   my $session_dump = '# ' . Dumper($session);
   chomp $session_dump;
   $session_dump =~ s/\n/\n# /g;
   print $errors_fh join("\n", $session_dump, @$raw_packets), "\n";
   return;
}

sub timestamp_diff {
   my ( $self, $start, $end ) = @_;
   return 0 unless $start && $end;
   my $sd = substr($start, 0, 11, '');
   my $ed = substr($end,   0, 11, '');
   my ( $sh, $sm, $ss ) = split(/:/, $start);
   my ( $eh, $em, $es ) = split(/:/, $end);
   my $esecs = ($eh * 3600 + $em * 60 + $es);
   my $ssecs = ($sh * 3600 + $sm * 60 + $ss);
   if ( $sd eq $ed ) {
      return sprintf '%.6f', $esecs - $ssecs;
   }
   else { # Assume only one day boundary has been crossed, no DST, etc
      return sprintf '%.6f', ( 86_400 - $ssecs ) + $esecs;
   }
}

sub uncompress_data {
   my ( $self, $data, $len ) = @_;
   die "I need data" unless $data;
   die "I need a len argument" unless $len;
   die "I need a scalar reference to data" unless ref $data eq 'SCALAR';
   PTDEBUG && _d('Uncompressing data');
   our $InflateError;

   my $comp_bin_data = pack('H*', $$data);

   my $uncomp_bin_data = '';
   my $z = new IO::Uncompress::Inflate(
      \$comp_bin_data
   ) or die "IO::Uncompress::Inflate failed: $InflateError";
   my $status = $z->read(\$uncomp_bin_data, $len)
      or die "IO::Uncompress::Inflate failed: $InflateError";

   my $uncomp_data = unpack('H*', $uncomp_bin_data);

   return \$uncomp_data;
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
# End ProtocolParser package
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
# Progress package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Progress.pm
#   t/lib/Progress.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Progress;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   foreach my $arg (qw(jobsize)) {
      die "I need a $arg argument" unless defined $args{$arg};
   }
   if ( (!$args{report} || !$args{interval}) ) {
      if ( $args{spec} && @{$args{spec}} == 2 ) {
         @args{qw(report interval)} = @{$args{spec}};
      }
      else {
         die "I need either report and interval arguments, or a spec";
      }
   }

   my $name  = $args{name} || "Progress";
   $args{start} ||= time();
   my $self;
   $self = {
      last_reported => $args{start},
      fraction      => 0,       # How complete the job is
      callback      => sub {
         my ($fraction, $elapsed, $remaining) = @_;
         printf STDERR "$name: %3d%% %s remain\n",
            $fraction * 100,
            Transformers::secs_to_time($remaining);
      },
      %args,
   };
   return bless $self, $class;
}

sub validate_spec {
   shift @_ if $_[0] eq 'Progress'; # Permit calling as Progress-> or Progress::
   my ( $spec ) = @_;
   if ( @$spec != 2 ) {
      die "spec array requires a two-part argument\n";
   }
   if ( $spec->[0] !~ m/^(?:percentage|time|iterations)$/ ) {
      die "spec array's first element must be one of "
        . "percentage,time,iterations\n";
   }
   if ( $spec->[1] !~ m/^\d+$/ ) {
      die "spec array's second element must be an integer\n";
   }
}

sub set_callback {
   my ( $self, $callback ) = @_;
   $self->{callback} = $callback;
}

sub start {
   my ( $self, $start ) = @_;
   $self->{start} = $self->{last_reported} = $start || time();
   $self->{first_report} = 0;
}

sub update {
   my ( $self, $callback, %args ) = @_;
   my $jobsize   = $self->{jobsize};
   my $now    ||= $args{now} || time;

   $self->{iterations}++; # How many updates have happened;

   if ( !$self->{first_report} && $args{first_report} ) {
      $args{first_report}->();
      $self->{first_report} = 1;
   }

   if ( $self->{report} eq 'time'
         && $self->{interval} > $now - $self->{last_reported}
   ) {
      return;
   }
   elsif ( $self->{report} eq 'iterations'
         && ($self->{iterations} - 1) % $self->{interval} > 0
   ) {
      return;
   }
   $self->{last_reported} = $now;

   my $completed = $callback->();
   $self->{updates}++; # How many times we have run the update callback

   return if $completed > $jobsize;

   my $fraction = $completed > 0 ? $completed / $jobsize : 0;

   if ( $self->{report} eq 'percentage'
         && $self->fraction_modulo($self->{fraction})
            >= $self->fraction_modulo($fraction)
   ) {
      $self->{fraction} = $fraction;
      return;
   }
   $self->{fraction} = $fraction;

   my $elapsed   = $now - $self->{start};
   my $remaining = 0;
   my $eta       = $now;
   if ( $completed > 0 && $completed <= $jobsize && $elapsed > 0 ) {
      my $rate = $completed / $elapsed;
      if ( $rate > 0 ) {
         $remaining = ($jobsize - $completed) / $rate;
         $eta       = $now + int($remaining);
      }
   }
   $self->{callback}->($fraction, $elapsed, $remaining, $eta, $completed);
}

sub fraction_modulo {
   my ( $self, $num ) = @_;
   $num *= 100; # Convert from fraction to percentage
   return sprintf('%d',
      sprintf('%d', $num / $self->{interval}) * $self->{interval});
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
# End Progress package
# ###########################################################################

# ###########################################################################
# FileIterator package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/FileIterator.pm
#   t/lib/FileIterator.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package FileIterator;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my $self = {
      %args,
   };
   return bless $self, $class;
}

sub get_file_itr {
   my ( $self, @filenames ) = @_;

   my @final_filenames;
   FILENAME:
   foreach my $fn ( @filenames ) {
      if ( !defined $fn ) {
         warn "Skipping undefined filename";
         next FILENAME;
      }
      if ( $fn ne '-' ) {
         if ( !-e $fn || !-r $fn ) {
            warn "$fn does not exist or is not readable";
            next FILENAME;
         }
      }
      push @final_filenames, $fn;
   }

   if ( !@filenames ) {
      push @final_filenames, '-';
      PTDEBUG && _d('Auto-adding "-" to the list of filenames');
   }

   PTDEBUG && _d('Final filenames:', @final_filenames);
   return sub {
      while ( @final_filenames ) {
         my $fn = shift @final_filenames;
         PTDEBUG && _d('Filename:', $fn);
         if ( $fn eq '-' ) { # Magical STDIN filename.
            return (*STDIN, undef, undef);
         }
         open my $fh, '<', $fn or warn "Cannot open $fn: $OS_ERROR";
         if ( $fh ) {
            return ( $fh, $fn, -s $fn );
         }
      }
      return (); # Avoids $f being set to 0 in list context.
   };
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
# End FileIterator package
# ###########################################################################

# ###########################################################################
# Runtime package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Runtime.pm
#   t/lib/Runtime.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Runtime;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw(now);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless exists $args{$arg};
   }

   my $run_time = $args{run_time};
   if ( defined $run_time ) {
      die "run_time must be > 0" if $run_time <= 0;
   }

   my $now = $args{now};
   die "now must be a callback" unless ref $now eq 'CODE';

   my $self = {
      run_time   => $run_time,
      now        => $now,
      start_time => undef,
      end_time   => undef,
      time_left  => undef,
      stop       => 0,
   };

   return bless $self, $class;
}

sub time_left {
   my ( $self, %args ) = @_;

   if ( $self->{stop} ) {
      PTDEBUG && _d("No time left because stop was called");
      return 0;
   }

   my $now = $self->{now}->(%args);
   PTDEBUG && _d("Current time:", $now);

   if ( !defined $self->{start_time} ) {
      $self->{start_time} = $now;
   }

   return unless defined $now;

   my $run_time = $self->{run_time};
   return unless defined $run_time;

   if ( !$self->{end_time} ) {
      $self->{end_time} = $now + $run_time;
      PTDEBUG && _d("End time:", $self->{end_time});
   }

   $self->{time_left} = $self->{end_time} - $now;
   PTDEBUG && _d("Time left:", $self->{time_left});
   return $self->{time_left};
}

sub have_time {
   my ( $self, %args ) = @_;
   my $time_left = $self->time_left(%args);
   return 1 if !defined $time_left;  # run forever
   return $time_left <= 0 ? 0 : 1;   # <=0s means run time has elapsed
}

sub time_elapsed {
   my ( $self, %args ) = @_;

   my $start_time = $self->{start_time};
   return 0 unless $start_time;

   my $now = $self->{now}->(%args);
   PTDEBUG && _d("Current time:", $now);

   my $time_elapsed = $now - $start_time;
   PTDEBUG && _d("Time elapsed:", $time_elapsed);
   if ( $time_elapsed < 0 ) {
      warn "Current time $now is earlier than start time $start_time";
   }
   return $time_elapsed;
}

sub reset {
   my ( $self ) = @_;
   $self->{start_time} = undef;
   $self->{end_time}   = undef;
   $self->{time_left}  = undef;
   $self->{stop}       = 0;
   PTDEBUG && _d("Reset run time");
   return;
}

sub stop {
   my ( $self ) = @_;
   $self->{stop} = 1;
   return;
}

sub start {
   my ( $self ) = @_;
   $self->{stop} = 0;
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
# End Runtime package
# ###########################################################################

# ###########################################################################
# Pipeline package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Pipeline.pm
#   t/lib/Pipeline.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Pipeline;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;
use Time::HiRes qw(time);

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw();
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }

   my $self = {
      instrument        => PTDEBUG,
      continue_on_error => 0,

      %args,

      procs           => [],  # coderefs for pipeline processes
      names           => [],  # names for each ^ pipeline proc
      instrumentation => {    # keyed on proc index in procs
         Pipeline => {
            time  => 0,
            calls => 0,
         },
      },
   };
   return bless $self, $class;
}

sub add {
   my ( $self, %args ) = @_;
   my @required_args = qw(process name);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }
   my ($process, $name) = @args{@required_args};

   push @{$self->{procs}}, $process;
   push @{$self->{names}}, $name;
   $self->{retries}->{$name} = $args{retry_on_error} || 100;
   if ( $self->{instrument} ) {
      $self->{instrumentation}->{$name} = { time => 0, calls => 0 };
   }
   PTDEBUG && _d("Added pipeline process", $name);

   return;
}

sub processes {
   my ( $self ) = @_;
   return @{$self->{names}};
}

sub execute {
   my ( $self, %args ) = @_;

   die "Cannot execute pipeline because no process have been added"
      unless scalar @{$self->{procs}};

   my $oktorun = $args{oktorun};
   die "I need an oktorun argument" unless $oktorun;
   die '$oktorun argument must be a reference' unless ref $oktorun;

   my $pipeline_data = $args{pipeline_data} || {};
   $pipeline_data->{oktorun} = $oktorun;

   my $stats = $args{stats};  # optional

   PTDEBUG && _d("Pipeline starting at", time);
   my $instrument = $self->{instrument};
   my $processes  = $self->{procs};
   EVENT:
   while ( $$oktorun ) {
      my $procno  = 0;  # so we can see which proc if one causes an error
      my $output;
      eval {
         PIPELINE_PROCESS:
         while ( $procno < scalar @{$self->{procs}} ) {
            my $call_start = $instrument ? time : 0;

            PTDEBUG && _d("Pipeline process", $self->{names}->[$procno]);
            $output = $processes->[$procno]->($pipeline_data);

            if ( $instrument ) {
               my $call_end = time;
               my $call_t   = $call_end - $call_start;
               $self->{instrumentation}->{$self->{names}->[$procno]}->{time} += $call_t;
               $self->{instrumentation}->{$self->{names}->[$procno]}->{count}++;
               $self->{instrumentation}->{Pipeline}->{time} += $call_t;
               $self->{instrumentation}->{Pipeline}->{count}++;
            }
            if ( !$output ) {
               PTDEBUG && _d("Pipeline restarting early after",
                  $self->{names}->[$procno]);
               if ( $stats ) {
                  $stats->{"pipeline_restarted_after_"
                     .$self->{names}->[$procno]}++;
               }
               last PIPELINE_PROCESS;
            }
            $procno++;
         }
      };
      if ( $EVAL_ERROR ) {
         my $name = $self->{names}->[$procno] || "";
         my $msg  = "Pipeline process " . ($procno + 1)
                  . " ($name) caused an error: "
                  . $EVAL_ERROR;
         if ( !$self->{continue_on_error} ) {
            die $msg . "Terminating pipeline because --continue-on-error "
               . "is false.\n";
         }
         elsif ( defined $self->{retries}->{$name} ) {
            my $n = $self->{retries}->{$name};
            if ( $n ) {
               warn $msg . "Will retry pipeline process $procno ($name) "
                  . "$n more " . ($n > 1 ? "times" : "time") . ".\n";
               $self->{retries}->{$name}--;
            }
            else {
               die $msg . "Terminating pipeline because process $procno "
                  . "($name) caused too many errors.\n";
            }
         }
         else {
            warn $msg;
         }
      }
   }

   PTDEBUG && _d("Pipeline stopped at", time);
   return;
}

sub instrumentation {
   my ( $self ) = @_;
   return $self->{instrumentation};
}

sub reset {
   my ( $self ) = @_;
   foreach my $proc_name ( @{$self->{names}} ) {
      if ( exists $self->{instrumentation}->{$proc_name} ) {
         $self->{instrumentation}->{$proc_name}->{calls} = 0;
         $self->{instrumentation}->{$proc_name}->{time}  = 0;
      }
   }
   $self->{instrumentation}->{Pipeline}->{calls} = 0;
   $self->{instrumentation}->{Pipeline}->{time}  = 0;
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
# End Pipeline package
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
package pt_query_digest;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Time::Local  qw(timelocal);
use Time::HiRes  qw(time usleep);
use List::Util   qw(max);
use Scalar::Util qw(looks_like_number);
use POSIX        qw(signal_h);
use Data::Dumper;

use Percona::Toolkit;

$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

$OUTPUT_AUTOFLUSH = 1;

Transformers->import(qw(
   shorten
   micro_t
   percentage_of
   ts
   make_checksum
   any_unix_timestamp
   parse_timestamp
   unix_timestamp
   crc32
));

use sigtrap 'handler', \&sig_int, 'normal-signals';

# Global variables.  Only really essential variables should be here.
my $oktorun = 1;
my $ep_dbh;  # For --explain
my $ps_dbh;  # For Processlist
my $aux_dbh; # For --aux-dsn (--since/--until "MySQL expression")

my $resume_file;
my $resume = {};
my $offset;
my $exit_status = 0;

(my $tool = __PACKAGE__) =~ tr/_/-/;

sub main {
   # Reset global vars, else tests will fail.
   local @ARGV  = @_;
   $oktorun     = 1;
   $resume      = {};
   $offset      = undef;
   $exit_status = 0;

   # ##########################################################################
   # Get configuration information.
   # ##########################################################################
   my $o = new OptionParser();
   $o->get_specs();
   $o->get_opts();

   my $dp = $o->DSNParser();
   $dp->prop('set-vars', $o->set_vars());

   my $aux_dsn;
   for my $i (0..$#ARGV) {
       next if -e $ARGV[$i];
       $aux_dsn = $dp->parse(splice(@ARGV, $i, 1));
       last;
   }
   
   # Frequently used options.
   my $review_dsn  = handle_special_defaults($o, 'review');
   my $history_dsn = handle_special_defaults($o, 'history');

   my @groupby    = @{$o->get('group-by')};
   my @orderby;
   if ( (grep { $_ =~ m/genlog|GeneralLogParser|rawlog|RawLogParser/ } @{$o->get('type')})
        && !$o->got('order-by') ) {
      @orderby = 'Query_time:cnt';
   }
   else { 
      @orderby = @{$o->get('order-by')};
   }

   if ( !$o->get('help') ) {
      if ( $o->get('outliers')
         && grep { $_ !~ m/^\w+:[0-9.]+(?::[0-9.]+)?$/ } @{$o->get('outliers')}
      ) {
         $o->save_error('--outliers requires two or three colon-separated fields');
      }
      if ( $o->get('progress') ) {
         eval { Progress->validate_spec($o->get('progress')) };
         if ( $EVAL_ERROR ) {
            chomp $EVAL_ERROR;
            $o->save_error("--progress $EVAL_ERROR");
         }
      }

      if ( my $patterns = $o->get('embedded-attributes') ) {
         $o->save_error("--embedded-attributes should be passed two "
           . "comma-separated patterns, got " . scalar(@$patterns) )
           unless scalar(@$patterns) == 2;
         for my $re (@$patterns) {
            no re 'eval';
            eval { qr/$re/ };
            if ( $EVAL_ERROR ) {
               $o->save_error("--embedded-attributes $EVAL_ERROR")
            }
         }
      }
   }

   # Set an orderby for each groupby; use the default orderby if there
   # are more groupby than orderby attribs.
   my $default_orderby = $o->get_defaults()->{'order-by'};
   foreach my $i ( 0..$#groupby ) {
      $orderby[$i] ||= $default_orderby;
   }
   $o->set('order-by', \@orderby);

   my $run_time_mode = lc $o->get('run-time-mode');
   my $run_time_interval; 
   eval {
      $run_time_interval = verify_run_time(
         run_mode => $run_time_mode,
         run_time => $o->get('run-time'),
      );
   };
   if ( $EVAL_ERROR ) {
      chomp $EVAL_ERROR;
      $o->save_error($EVAL_ERROR);
   }

   $o->usage_or_errors();

   # ########################################################################
   # Common modules.
   # #######################################################################
   my $q  = new Quoter();
   my $qp = new QueryParser();
   my $qr = new QueryRewriter(QueryParser=>$qp, match_embedded_numbers => $o->get('preserve-embedded-numbers') ? 1 : 0);
   my %common_modules = (
      OptionParser  => $o,
      DSNParser     => $dp,
      Quoter        => $q,
      QueryParser   => $qp,
      QueryRewriter => $qr,
   );

   # ########################################################################
   # Set up for --explain
   # ########################################################################
   if ( my $ep_dsn = $o->get('explain') ) {
      $ep_dbh = get_cxn(
         for          => '--explain',
         dsn          => $ep_dsn,
         OptionParser => $o,
         DSNParser    => $dp,
         opts         => { AutoCommit => 1 },
      );
      $ep_dbh->{InactiveDestroy}  = 1;  # Don't die on fork().
   }

   # ########################################################################
   # Set up for --review.
   # ########################################################################
   my $qv;      # QueryReview
   my $qv_dbh;  # For QueryReview

   my $tp = new TableParser(Quoter => $q);
   if ( $review_dsn ) {
      my %dsn_without_Dt = %$review_dsn;
      delete $dsn_without_Dt{D};
      delete $dsn_without_Dt{t};
      
      $qv_dbh = get_cxn(
         for          => '--review',
         dsn          => \%dsn_without_Dt,
         OptionParser => $o,
         DSNParser    => $dp,
         opts         => { AutoCommit => 1 },
      );
      $qv_dbh->{InactiveDestroy}  = 1;  # Don't die on fork().

      my @db_tbl = @{$review_dsn}{qw(D t)};
      my $db_tbl = $q->quote(@db_tbl);
      
      my $create_review_sql = $o->read_para_after(
         __FILE__, qr/\bMAGIC_create_review_table\b/);
      $create_review_sql =~ s/\bquery_review\b/$db_tbl/;
      
      create_review_tables(
          type             => 'review',
          dbh              => $qv_dbh,
          full_table       => $db_tbl,
          create_table_sql => $create_review_sql,
          create_table     => $o->get('create-review-table'),
          TableParser      => $tp,
      );

      # Set up the new QueryReview object.
      my $struct = $tp->parse($tp->get_create_table($qv_dbh, @db_tbl));
      $qv = new QueryReview(
         dbh         => $qv_dbh,
         db_tbl      => $db_tbl,
         tbl_struct  => $struct,
         quoter      => $q,
      );
   }

   # ########################################################################
   # Set up for --history.
   # ########################################################################
   my $qh;      # QueryHistory
   my $qh_dbh;
   if ( $history_dsn ) {
      my %dsn_without_Dt = %$history_dsn;
      delete $dsn_without_Dt{D};
      delete $dsn_without_Dt{t};
      my $qh_dbh = get_cxn(
         for          => '--history',
         dsn          => \%dsn_without_Dt,
         OptionParser => $o,
         DSNParser    => $dp,
         opts         => { AutoCommit => 1 },
      );
      $qh_dbh->{InactiveDestroy}  = 1;  # Don't die on fork().

      my @hdb_tbl = @{$history_dsn}{qw(D t)};
      my $hdb_tbl = $q->quote(@hdb_tbl);
      
      my $create_history_sql = $o->read_para_after(
         __FILE__, qr/\bMAGIC_create_history_table\b/);
      $create_history_sql =~ s/\bquery_history\b/$hdb_tbl/;

      create_review_tables(
         type             => 'history',
         dbh              => $qh_dbh,
         full_table       => $hdb_tbl,
         create_table_sql => $create_history_sql,
         create_table     => $o->get('create-history-table'),
         TableParser      => $tp,
      );
      
      my $tbl = $tp->parse($tp->get_create_table($qh_dbh, @hdb_tbl));
      my $pat = $o->read_para_after(__FILE__, qr/\bMAGIC_history_columns\b/);
      $pat    =~ s/\s+//g;
      $pat    = qr/^(.*?)_($pat)$/;

      $qh = QueryHistory->new(
                history_dbh    => $qh_dbh,
                column_pattern => $pat,
            );
      # And tell the QueryReview that it has more work to do.
      $qh->set_history_options(
         table      => $hdb_tbl,
         tbl_struct => $tbl,
      );
   }

   # ########################################################################
   # Create all the pipeline processes that do all the work: get input,
   # parse events, manage runtime, switch iterations, aggregate, etc.
   # ########################################################################

   # These four vars are passed to print_reports().
   my @ea;         # EventAggregator objs
   my @tl;         # EventTimeline obj
   my @read_files; # file names that have been parsed
   my %stats;      # various stats/counters used in some procs

   # The pipeline data hashref is passed to each proc.  Procs use this to
   # pass data through the pipeline.  The most importat data is the event.
   # Other data includes in the next_event callback, time and iters left,
   # etc.  This hashref is accessed inside a proc via the $args arg.
   my $pipeline_data = {
      iter  => 1,
      stats => \%stats,
   };

   my $pipeline = new Pipeline(
      continue_on_error => $o->get('continue-on-error'),
   );

   # ########################################################################
   # Procs before the terminator are, in general, responsible for getting
   # and event that procs after the terminator process before aggregation
   # at the end of the pipeline.  Therefore, these pre-terminator procs
   # should not assume an event exists.  If one does, they should let the
   # pipeline continue.  Only the terminator proc terminates the pipeline.
   # ########################################################################

   { # prep
      $pipeline->add(
         name    => 'prep',
         process => sub {
            my ( $args ) = @_;
            # Stuff you'd like to do to make sure pipeline data is prepped
            # and ready to go...

            $args->{event} = undef;  # remove event from previous pass

            return $args;
         },
      );
   } # prep

   { # input
      my $fi        = FileIterator->new();
      my $next_file = $fi->get_file_itr(@ARGV);
      my $input_fh; # the current input fh
      my $pr;       # Progress obj for ^

      $pipeline->add(
         name    => 'input',
         process => sub {
            my ( $args ) = @_;

            # Only get the next file when there's no fh or no more events in
            # the current fh.  This allows us to do collect-and-report cycles
            # (i.e. iterations) on huge files.  This doesn't apply to infinite
            # inputs because they don't set more_events false.
            if ( !$args->{input_fh} || !$args->{more_events} ) {

               # Close the current file.
               if ( $args->{input_fh} ) {
                  close $args->{input_fh}
                     or die "Cannot close input fh: $OS_ERROR";
               }

               # Open the next file.
               my ($fh, $filename, $filesize) = $next_file->();
               if ( $fh ) {
                  my $fileno = fileno $fh;
                  if ($fileno == 0) {
                     print "Reading from STDIN ...\n";
                  }
                  PTDEBUG && _d('Reading', $filename);
                  PTDEBUG && _d('File size:', $filesize);
                  # catch if user is trying to use an uncoverted (raw) binlog  # issue 1377888
                  if ( $filename &&  $o->get('type')->[0] eq 'binlog') {
                     if (is_raw_binlog($filename)) {
                        warn "Binlog file $filename must first be converted to text format using mysqlbinlog";
                        return 1;
                     }
                  }
                  push @read_files, { name => ($filename || "STDIN"), size => $filesize };

                  # Read the file offset for --resume.
                  if ( ($resume_file = $o->get('resume')) && $filename ) {
                     if ( -s $resume_file ) {
                        open my $resume_fh, "<", $resume_file
                           or die "Cannot open $resume_file: $OS_ERROR";
                        my $resume_offset = do { local $/; <$resume_fh> };
                        close $resume_fh
                           or die "Error close $resume_file: $OS_ERROR";
                        chomp($resume_offset) if $resume_offset;
                        if ( looks_like_number($resume_offset) ) {
                           PTDEBUG && _d('Resuming at offset', $resume_offset);
                           $resume->{simple} = 1;
                           seek $fh, $resume_offset, 0
                              or die "Error seeking to $resume_offset in "
                                 . "$resume_file: $OS_ERROR";
                           warn "# Resuming $filename from offset "
                              . "$resume_offset (file size: $filesize)...\n";
                        }
                        else {
                           $resume->{simple} = 0;  # enhanced resume file
                           map {
                              my $line = $_;
                              chomp $line;
                              my ($key, $value) = split('=', $line);
                              if ( !$key
                                   || !defined $value
                                   || !looks_like_number($value)
                                   || $value < 0 )
                              {
                                 $exit_status = 1;
                                 warn "Invalid line in --resume $resume_file: $line\n";
                                 $oktorun = 0;
                                 return;
                              }
                              $resume->{$key} = $value;
                           } split("\n", $resume_offset);
                           if ( $resume->{end_offset} &&
                                 $resume->{end_offset} <=
                                ($resume->{stop_offset} || 0) )
                           {
                              close $args->{input_fh} if $args->{input_fh};
                              $args->{input_fh}    = undef;
                              $args->{more_events} = 0;
                              $oktorun = 0;
                              $resume_file = '';
                              warn "# Not resuming $filename because "
                                 . "end_offset $resume->{end_offset} is "
                                 . "less than or equal to stop_offset "
                                 . ($resume->{stop_offset} || 0) . "\n";
                           }
                           else {
                              $resume_offset = $resume->{stop_offset}
                                            || $resume->{start_offset}
                                            || 0;
                              seek $fh, $resume_offset, 0
                                 or die "Error seeking to $resume_offset in "
                                    . "$resume_file: $OS_ERROR";
                              warn "# Resuming $filename from offset "
                                . "$resume_offset to "
                                . ($resume->{end_offset} ? $resume->{end_offset}
                                                         : "end of file")
                                . " (file size: $filesize)...\n";
                           }
                        }
                     }
                     else {
                        warn "# Resuming $filename from offset 0 because "
                           . "resume file $filename does not exist "
                           . "(file size: $filesize)...\n";
                        $resume->{simple}       = 0;
                        $resume->{start_offset} = 0;
                     }
                  }

                  # Create callback to read next event.  Some inputs, like
                  # Processlist, may use something else but most next_event.
                  if ( my $read_time = $o->get('read-timeout') ) {
                     $args->{next_event}
                        = sub { return read_timeout($fh, $read_time); };
                  }
                  else {
                     $args->{next_event} = sub { return <$fh>; };
                  }
                  $args->{filename}    = $filename;
                  $args->{input_fh}    = $fh;
                  $args->{tell}        = sub {
                     $offset = tell $fh;  # update global $offset
                     if ( $args->{filename} ) {
                        $args->{pos_for}->{$args->{filename}} = $offset;
                     }
                     return $offset;  # legacy: return global $offset
                  };
                  $args->{more_events} = 1;

                  # Reset in case we read two logs out of order by time.
                  $args->{past_since} = 0 if $o->get('since');
                  $args->{at_until}   = 0 if $o->get('until');

                  # Make a progress reporter, one per file.
                  if ( $o->get('progress') && $filename && -e $filename ) {
                     $pr = new Progress(
                        jobsize => $filesize,
                        spec    => $o->get('progress'),
                        name    => $filename,
                     );
                  }
               }
               else {
                  PTDEBUG && _d("No more input");
                  # This will cause terminator proc to terminate the pipeline.
                  $args->{input_fh}    = undef;
                  $args->{more_events} = 0;
               }
            }
            elsif ( $resume->{end_offset}
                    && $offset >= $resume->{end_offset} ) {
               PTDEBUG && _d('Offset', $offset, 'at end_offset',
                  $resume->{end_offset});
               close $args->{input_fh} if $args->{input_fh};
               $args->{input_fh}    = undef;
               $args->{more_events} = 0;
            }
            else {
               $pr->update($args->{tell}) if $pr;
            }
            return $args;
         },
      );
   } # input

   my $ps_dsn;
   my @parsers;
   { # event
      my $misc;
      if ( $ps_dsn = $o->get('processlist') ) {
         my $ms = new MasterSlave(
            OptionParser => $o,
            DSNParser    => $dp,
            Quoter       => $q,
         );
         my $pl = new Processlist(
            interval    => $o->get('interval') * 1_000_000,
            MasterSlave => $ms
         );
         my ( $sth, $cxn );
         my $cur_server = 'processlist';
         my $cur_time   = 0;

         if ( $o->get('ask-pass') ) {
            $ps_dsn->{p} = OptionParser::prompt_noecho("Enter password for "
               . "--processlist: ");
            $o->get('processlist', $ps_dsn);
         }

         my $code = sub {
            my $err;
            do {
               eval { $sth->execute; };
               $err = $EVAL_ERROR;
               if ( $err ) { # Try to reconnect when there's an error.
                  eval {
                     if ( !$ps_dbh || !$ps_dbh->ping ) {
                        PTDEBUG && _d('Getting a dbh from', $cur_server);
                        $ps_dbh = $dp->get_dbh(
                           $dp->get_cxn_params($o->get($cur_server)), {AutoCommit => 1});
                        $ps_dbh->{InactiveDestroy}  = 1;  # Don't die on fork().
                     }
                     $cur_time = time();
                     $sth      = $ps_dbh->prepare('SHOW FULL PROCESSLIST');
                     $cxn      = $ps_dbh->{mysql_thread_id};
                     $sth->execute();
                  };
                  $err = $EVAL_ERROR;
                  if ( $err ) {
                     warn $err;
                     sleep 1;
                  }
               }
            } until ( $sth && !$err );

            return [ grep { $_->[0] != $cxn } @{ $sth->fetchall_arrayref(); } ];
         };

         $pipeline->add(
            name    => ref $pl,
            process => sub {
               my ( $args ) = @_;
               my $event = $pl->parse_event(code => $code);
               if ( $event ) {
                  sanitize_event($event);
                  $args->{event} = $event;
               }
               return $args;
            },
         );
      }  # get events from processlist
      else {
         my %alias_for = (
            slowlog   => ['SlowLogParser'],
            binlog    => ['BinaryLogParser'],
            genlog    => ['GeneralLogParser'],
            tcpdump   => ['TcpdumpParser','MySQLProtocolParser'],
            rawlog    => ['RawLogParser'],
         );
         my $type = $o->get('type');
         $type    = $alias_for{$type->[0]} if $alias_for{$type->[0]};

         my ($server, $port);
         if ( my $watch_server = $o->get('watch-server') ) {
            # This should match all combinations of HOST and PORT except
            # "host-name.port" because "host.mysql" could be either
            # host "host" and port "mysql" or just host "host.mysql"
            # (e.g. if someone added "127.1 host.mysql" to etc/hosts).
            # So host-name* requires a colon between it and a port.
            ($server, $port) = $watch_server
                  =~ m/^((?:\d+\.\d+\.\d+\.\d+|[\w\.\-]+\w))(?:[\:\.](\S+))?/;
            PTDEBUG && _d('Watch server', $server, 'port', $port);
         }

         foreach my $module ( @$type ) {
            my $parser;
            eval {
               $parser = $module->new(
                  server => $server,
                  port   => $port,
                  o      => $o,
               );
            };
            if ( $EVAL_ERROR ) {
               if ( $EVAL_ERROR =~ m/perhaps you forgot to load/ ) {
                  # There is no module to handle --type, so wrong --type
                  die "'$module' is not a valid input type. "
                     . "Please check the documentation for --type.\n";
               }
               die "Failed to load $module module: $EVAL_ERROR";
            }
            push @parsers, $parser;

            $pipeline->add(
               name    => ref $parser,
               process => sub {
                  my ( $args ) = @_;
                  if ( $args->{input_fh} ) {
                     my $event = $parser->parse_event(
                        event       => $args->{event},
                        next_event  => $args->{next_event},
                        tell        => $args->{tell},
                        misc        => $args->{misc},
                        oktorun     => sub { $args->{more_events} = $_[0]; },
                        stats       => $args->{stats},
                     );
                     if ( $event ) {
                        sanitize_event($event);
                        $args->{event} = $event;
                        return $args;
                     }
                     PTDEBUG && _d("No more events, input EOF");
                     return;  # next input
                  }
                  # No input, let pipeline run so the last report is printed.
                  return $args;
               },
            );
         }
      }  # get events from log file

      if ( my $patterns = $o->get('embedded-attributes') ) {
         $misc->{embed}   = qr/$patterns->[0]/;
         $misc->{capture} = qr/$patterns->[1]/;
         PTDEBUG && _d('Patterns for embedded attributes:', $misc->{embed},
               $misc->{capture});
      }
      $pipeline_data->{misc} = $misc;
   } # event

   { # runtime
      my $now_callback;
      if ( $run_time_mode eq 'clock' ) {
         $now_callback = sub { return time; };
      }
      elsif ( $run_time_mode eq 'event' ) {
         $now_callback = sub {
            my ( %args ) = @_;
            my $event = $args{event};
            return unless $event && $event->{ts};
            PTDEBUG && _d("Log time:", $event->{ts});
            return unix_timestamp(parse_timestamp($event->{ts}));
         };
      }
      else {
         $now_callback = sub { return; };
      }
      $pipeline_data->{Runtime} = new Runtime(
         now      => $now_callback,
         run_time => $o->get('run-time'),
      );

      $pipeline->add(
         name    => 'runtime',
         process => sub {
            my ( $args ) = @_;
            if ( $run_time_mode eq 'interval' ) {
               my $event = $args->{event};
               return $args unless $event && $event->{ts};

               my $ts = $args->{unix_ts}
                  = unix_timestamp(parse_timestamp($event->{ts}));

               if ( !$args->{next_ts_interval} ) {
                  # We need to figure out what interval we're in and what
                  # interval is next.  So first we need to parse the ts.
                  if ( my($y, $m, $d, $h, $i, $s)
                        = $args->{event}->{ts} =~ m/^$Transformers::mysql_ts$/ ) {
                     my $rt = $o->get('run-time');
                     if ( $run_time_interval == 60 ) {
                        PTDEBUG && _d("Run-time interval in seconds");
                        my $this_minute = unix_timestamp(parse_timestamp(
                           "$y$m$d $h:$i:00"));
                        do { $this_minute += $rt } until $this_minute > $ts;
                        $args->{next_ts_interval} = $this_minute;
                     }
                     elsif ( $run_time_interval == 3600 ) {
                        PTDEBUG && _d("Run-time interval in minutes");
                        my $this_hour = unix_timestamp(parse_timestamp(
                           "$y$m$d $h:00:00"));
                        do { $this_hour += $rt } until $this_hour > $ts;
                        $args->{next_ts_interval} = $this_hour;
                     }
                     elsif ( $run_time_interval == 86400 ) {
                        PTDEBUG && _d("Run-time interval in days");
                        my $this_day = unix_timestamp(parse_timestamp(
                           "$y$m$d 00:00:00"));
                        $args->{next_ts_interval} = $this_day + $rt;
                     }
                     else {
                        die "Invalid run-time interval: $run_time_interval";
                     }
                     PTDEBUG && _d("First ts interval:",
                        $args->{next_ts_interval});
                  }
                  else {
                     PTDEBUG && _d("Failed to parse MySQL ts:",
                        $args->{event}->{ts});
                  }
               }
            }
            else {
               # Clock and event run-time modes need to check the time.
               $args->{time_left}
                  = $args->{Runtime}->time_left(event=>$args->{event});
            }

            return $args;
         },
      );
   } # runtime

   # Filter early for --since and --until.
   # If --since or --until is a MySQL expression, then any_unix_timestamp()
   # will need this callback to execute the expression.  We don't know what
   # type of time value the user gave, so we'll create the callback in any case.
   if ( $o->get('since') || $o->get('until') ) {
      if ( $aux_dsn ) {
         $aux_dbh = get_cxn(
            for          => '--aux',
            dsn          => $aux_dsn,
            OptionParser => $o,
            DSNParser    => $dp,
            opts         => { AutoCommit => 1 }
         );
         $aux_dbh->{InactiveDestroy}  = 1;  # Don't die on fork().
      }
      $aux_dbh ||= $qv_dbh || $qh_dbh || $ps_dbh || $ep_dbh;
      PTDEBUG && _d('aux dbh:', $aux_dbh);

      my $time_callback = sub {
         my ( $exp ) = @_;
         return unless $aux_dbh;
         my $sql = "SELECT UNIX_TIMESTAMP($exp)";
         PTDEBUG && _d($sql);
         return $aux_dbh->selectall_arrayref($sql)->[0]->[0];
      };
      if ( $o->get('since') ) {
         my $since = any_unix_timestamp($o->get('since'), $time_callback);
         die "Invalid --since value" unless $since;

         $pipeline->add(
            name    => 'since',
            process => sub {
               my ( $args ) = @_;
               my $event = $args->{event};
               return $args unless $event;
               if ( $args->{past_since} ) {
                  PTDEBUG && _d('Already past --since');
                  return $args;
               }
               if ( $event->{ts} ) {
                  my $ts = any_unix_timestamp($event->{ts}, $time_callback);
                  if ( ($ts || 0) >= $since ) {
                     PTDEBUG && _d('Event is at or past --since');
                     $args->{past_since} = 1;
                     return $args;
                  }
               }
               PTDEBUG && _d('Event is before --since (or ts unknown)');
               return;  # next event
            },
         );
      }
      if ( $o->get('until') ) {
         my $until = any_unix_timestamp($o->get('until'), $time_callback);
         die "Invalid --until value" unless $until;
         $pipeline->add(
            name    => 'until',
            process => sub {
               my ( $args ) = @_;
               my $event = $args->{event};
               return $args unless $event;
               if ( $args->{at_until} ) {
                  PTDEBUG && _d('Already past --until');
                  return;
               }
               if ( $event->{ts} ) {
                  my $ts = any_unix_timestamp($event->{ts}, $time_callback);
                  if ( ($ts || 0) >= $until ) {
                     PTDEBUG && _d('Event at or after --until');
                     $args->{at_until} = 1;
                     return;
                  }
               }
               PTDEBUG && _d('Event is before --until (or ts unknown)');
               return $args;
            },
         );
      }
   } # since/until

   { # iteration
      $pipeline->add(
         # This is a critical proc: if we die here, we probably need
         # to stop, else an infinite loop can develop:
         # https://bugs.launchpad.net/percona-toolkit/+bug/888114
         # We'll retry twice in case the problem is just one bad
         # query class, or something like that.
         retry_on_error => 2,
         name           => 'iteration',
         process        => sub {
            my ( $args ) = @_;

            # Start the (next) iteration.
            if ( !$args->{iter_start} ) {
               my $iter_start = $args->{iter_start} = time;
               PTDEBUG && _d('Iteration', $args->{iter},
                  'started at', ts($iter_start));
               
               if ( PTDEBUG ) {
                  _d("\n# Iteration $args->{iter} started at ",
                     ts($iter_start), "\n");
               }
            }

            # Determine if we should stop the current iteration.
            # If we do, then we report events collected during this
            # iter, then reset and increment for the next iter.
            my $report    = 0;
            my $time_left = $args->{time_left};
            if ( !$args->{more_events}
                 || defined $time_left && $time_left <= 0 ) {
               PTDEBUG && _d("Runtime elapsed or no more events, reporting");
               $report = 1;
            }
            elsif ( $run_time_mode eq 'interval'
                    && $args->{next_ts_interval}
                    && $args->{unix_ts} >= $args->{next_ts_interval} ) {
               PTDEBUG && _d("Event is in the next interval, reporting");

               # Get the next ts interval based on the current log ts.
               # Log ts can make big jumps, so just += $rt might not
               # set the next ts interval at a time past the current
               # log ts.
               my $rt = $o->get('run-time');
               do {
                  $args->{next_ts_interval} += $rt;
               } until $args->{next_ts_interval} >= $args->{unix_ts};

               $report = 1;
            }

            if ( $report ) {
               PTDEBUG && _d("Iteration", $args->{iter}, "stopped at",ts(time));

               save_resume_offset(
                  last_event_offset => $parsers[0]->{last_event_offset},
               );

               # Get this before calling print_reports() because that sub
               # resets each ea and we may need this later for stats.
               my $n_events_aggregated = $ea[0]->events_processed();

               if ( $n_events_aggregated ) {
                  print_reports(
                     eas             => \@ea,
                     tls             => \@tl,
                     groupby         => \@groupby,
                     orderby         => \@orderby,
                     files           => \@read_files,
                     Pipeline        => $pipeline,
                     QueryReview     => $qv,
                     QueryHistory    => $qh,
                     %common_modules,
                  );
               }
               else {
                  if ( $o->get('output') eq 'report' ) {
                     print "\n# No events processed.\n";
                  }
               }

               if ( PTDEBUG ) {
                  if ( keys %stats ) {
                     my $report = new ReportFormatter(
                        line_width => 74,
                     );
                     $report->set_columns(
                        { name => 'Statistic',                  },
                        { name => 'Count',    right_justify => 1 },
                        { name => '%/Events', right_justify => 1 },
                     );

                     # Have to add this one manually because currently
                     # EventAggregator::aggregate() doesn't know about stats.
                     # It's the same thing as events_processed() though.
                     $stats{events_aggregated} = $n_events_aggregated;

                     # Save value else events_read will be reset during the
                     # foreach loop below and mess up percentage_of().
                     my $n_events_read = $stats{events_read} || 0;

                     my %stats_sort_order = (
                        events_read       => 1,
                        events_parsed     => 2,
                        events_aggregated => 3,
                     );
                     my @stats = sort {
                           QueryReportFormatter::pref_sort(
                              $a, $stats_sort_order{$a},
                              $b, $stats_sort_order{$b})
                     } keys %stats;
                     foreach my $stat ( @stats ) {
                        $report->add_line(
                           $stat,
                           $stats{$stat} || 0,
                           percentage_of(
                              $stats{$stat} || 0,
                              $n_events_read,
                              p => 2),
                        );
                        $stats{$stat} = 0;  # Reset for next iteration.
                     }
                     print STDERR "\n" . $report->get_report();
                  }
                  else {
                     print STDERR "\n# No statistics values.\n";
                  }
               }

               # Decrement iters_left after finishing an iter because in the
               # default case, 1 iter, if we decr when the iter starts, then
               # terminator will think there's no iters left before the one
               # iter has finished.
               if ( my $max_iters = $o->get('iterations') ) {
                  $args->{iters_left} = $max_iters - $args->{iter};
                  PTDEBUG && _d($args->{iters_left}, "iterations left");
               }

               # Next iteration.
               $args->{iter}++;
               $args->{iter_start} = undef;

               # Runtime is per-iteration, so reset it, and reset time_left
               # else terminator will think runtime has elapsed when really
               # we may just be between iters.
               $args->{Runtime}->reset();
               $args->{time_left} = undef;
            }

            # Continue the pipeline even if we reported and went to the next
            # iter because there could be an event in the pipeline that is
            # the first in the next/new iter.
            return $args;
         },
      );
   } # iteration

   { # terminator
      $pipeline->add(
         name    => 'terminator',
         process => sub {
            my ( $args ) = @_;

            # The first sure-fire state that terminates the pipeline is
            # having no more input.
            if ( !$args->{input_fh} ) {
               PTDEBUG && _d("No more input, terminating pipeline");

               # This shouldn't happen, but I want to know if it does.
               warn "There's an event in the pipeline but no current input: "
                     . Dumper($args)
                  if $args->{event};

               $oktorun = 0;  # 2. terminate pipeline
               return;        # 1. exit pipeline early
            }

            # The second sure-first state is having no more iterations.
            my $iters_left = $args->{iters_left};
            if ( defined $iters_left && $iters_left <= 0 ) {
               PTDEBUG && _d("No more iterations, terminating pipeline");
               $oktorun = 0;  # 2. terminate pipeline
               return;        # 1. exit pipeline early
            }

            # There's time or iters left so keep running.
            if ( $args->{event} ) {
               PTDEBUG && _d("Event in pipeline, continuing");
               return $args;
            }
            else {
               PTDEBUG && _d("No event in pipeline, get next event");
               return;
            }
         },
      );
   } # terminator

   # ########################################################################
   # All pipeline processes after the terminator expect an event
   # (i.e. that $args->{event} exists and is a valid event).
   # ########################################################################

   if ( grep { $_ eq 'fingerprint' } @groupby ) {
      $pipeline->add(
         name    => 'fingerprint',
         process => sub {
            my ( $args ) = @_;
            my $event = $args->{event};
            # Skip events which do not have the groupby attribute.
            my $groupby_val = $event->{arg};
            return unless $groupby_val;
            $event->{fingerprint} = $qr->fingerprint($groupby_val);
            return $args;
         },
      );
   }

   # Make subs which map attrib aliases to their primary attrib.
   foreach my $alt_attrib ( @{$o->get('attribute-aliases')} ) {
      $pipeline->add(
         name    => 'attribute aliases',
         process => make_alt_attrib($alt_attrib),
      );
   }

   # Carry attribs forward for --inherit-attributes.
   my $inherited_attribs = $o->get('inherit-attributes');
   if ( @$inherited_attribs ) {
      my $last_val = {};
      $pipeline->add(
         name    => 'inherit attributes',
         process => sub {
            my ( $args ) = @_;
            my $event = $args->{event};
            foreach my $attrib ( @$inherited_attribs ) {
               if ( defined $event->{$attrib} ) {
                  # Event has val for this attrib; save it as the last val.
                  $last_val->{$attrib} = $event->{$attrib};
               }
               else {
                  # Inherit last val for this attrib (if there was a last val).
                  $event->{$attrib} = $last_val->{$attrib}
                     if defined $last_val->{$attrib};
               }
            }
            return $args;
         },
      );
   }

   { # variations
      my @variations = @{$o->get('variations')};
      if ( @variations ) {
         $pipeline->add(
            name    => 'variations',
            process => sub {
               my ( $args ) = @_;
               my $event = $args->{event};
               foreach my $attrib ( @variations ) {
                  my $checksum = crc32($event->{$attrib});
                  $event->{"${attrib}_crc"} = $checksum if defined $checksum;
               }
               return $args;
            },
         );
      }
   } # variations

   if ( grep { $_ eq 'tables' } @groupby ) {
      $pipeline->add(
         name    => 'tables',
         process => sub {
            my ( $args ) = @_;
            my $event = $args->{event};
            my $group_by_val = $event->{arg};
            return unless defined $group_by_val;
            $event->{tables} = [
               map {
                  # Canonicalize and add the db name in front
                  $_ =~ s/`//g;
                  if ( $_ !~ m/\./
                       && (my $db = $event->{db} || $event->{Schema}) ) {
                     $_ = "$db.$_";
                  }
                  $_;
               }
               $qp->get_tables($group_by_val)
            ];
            return $args;
         },
      );
   }

   { # distill
      my %distill_args;
      if ( grep { $_ eq 'distill' } @groupby ) {
         $pipeline->add(
            name    => 'distill',
            process => sub {
               my ( $args ) = @_;
               my $event = $args->{event};
               my $group_by_val = $event->{arg};
               return unless defined $group_by_val;
               $event->{distill} = $qr->distill($group_by_val, %distill_args);
               PTDEBUG && !$event->{distill} && _d('Cannot distill',
                  $event->{arg});
               return $args;
            },
         );
      }
   } # distill

   # Former --zero-admin
   $pipeline->add(
      name    => 'zero admin',
      process => sub {
         my ( $args ) = @_;
         my $event = $args->{event};
         if ( $event->{arg} && $event->{arg} =~ m/^administrator/ ) {
            $event->{Rows_sent}     = 0 if exists $event->{Rows_sent};
            $event->{Rows_examined} = 0 if exists $event->{Rows_examined};
            $event->{Rows_read}     = 0 if exists $event->{Rows_read};
            $event->{Rows_affected} = 0 if exists $event->{Rows_affected};
         }
         return $args;
      },
   );
   # zero admin
   
   # Filter after special attributes, like fingerprint, tables,
   # distill, etc., have been created.
   if ( $o->get('filter') ) {
      my $filter = $o->get('filter');
      if ( -f $filter && -r $filter ) {
         PTDEBUG && _d('Reading file', $filter, 'for --filter code');
         open my $fh, "<", $filter or die "Cannot open $filter: $OS_ERROR";
         $filter = do { local $/ = undef; <$fh> };
         close $fh;
      }
      else {
         $filter = "( $filter )";  # issue 565
      }
      my $code = 'sub { my ( $args ) = @_; my $event = $args->{event}; '
               . "$filter && return \$args; };";
      PTDEBUG && _d('--filter code:', $code);
      my $sub = eval $code
         or die "Error compiling --filter code: $code\n$EVAL_ERROR";

      $pipeline->add(
         name    => 'filter',
         process => $sub,
      );
   } # filter

   if ( $o->got('sample') ) {
      my $group_by_val = $groupby[0];
      my $num_samples  = $o->get('sample');
      if ( $group_by_val ) {
         my %seen;
         $pipeline->add(
            name    => 'sample',
            process => sub {
               my ( $args ) = @_;
               my $event = $args->{event};
               if ( ++$seen{$event->{$group_by_val}} <= $num_samples ) {
                  PTDEBUG && _d("--sample permits event",
                     $event->{$group_by_val});
                  return $args;
               }
               PTDEBUG && _d("--sample rejects event", $event->{$group_by_val});
               return;
            },
         );
      }
   } # sample

   if ( $o->get('output') =~ /slowlog/i ) {
      my $w = new SlowLogWriter();
      my $field = $o->get('output') eq 'secure-slowlog' ? 'fingerprint' : '';
      $pipeline->add(
         name    => '--output slowlog',
         process => sub {
            my ( $args ) = @_;
            my $event = $args->{event};
            PTDEBUG && _d('callback: --output slowlog');
            $w->write(*STDOUT, $event, $field);
            return $args;
         },
      );
   } # print

   # Combine "# Log_slow_rate_type: query  Log_slow_rate_limit: 2"
   # as rate_limit=>'query:2'.
   $pipeline->add(
      name    => 'rate limit',
      process => sub {
         my ( $args ) = @_;
         my $event = $args->{event};
         PTDEBUG && _d('callback: rate limit');
         if ( my $limit = $event->{Log_slow_rate_limit} ) {
            $event->{rate_limit} = ($event->{Log_slow_rate_type} || 'session') . ":$limit";
            delete $event->{Log_slow_rate_limit};
            delete $event->{Log_slow_rate_type};
         }
         return $args;
      },
   );


   # Finally, add aggregator obj for each groupby attrib to the callbacks.
   # These aggregating objs should be the last pipeline processes.
   foreach my $i ( 0..$#groupby  ) {
      my $groupby = $groupby[$i];

      # This shouldn't happen.
      die "No --order-by value for --group-by $groupby" unless $orderby[$i];

      my ( $orderby_attrib, $orderby_func ) = split(/:/, $orderby[$i]);

      # Create an EventAggregator for this groupby attrib and
      # add it to callbacks.
      my $type_for = {
         val           => 'string',
         key_print     => 'string',
         Status_code   => 'string',
         Statement_id  => 'string',
         Error_no      => 'string',
         Last_errno    => 'string',
         Thread_id     => 'string',
         InnoDB_trx_id => 'string',
         host          => 'string',
         ip            => 'string',
         port          => 'string',
         Killed        => 'bool',
         rate_limit    => 'string',
      };

      my $ea = new EventAggregator(
         groupby           => $groupby,
         attributes        => { },
         worst             => $orderby_attrib,
         attrib_limit      => $o->get('attribute-value-limit'),
         ignore_attributes => $o->get('ignore-attributes'),
         type_for          => $type_for,
      );
      push @ea, $ea;

      $pipeline->add(
         name    => "aggregate $groupby",
         process => sub {
            my ( $args ) = @_;
            $ea->aggregate($args->{event});
            return $args;
         },
      );

      # If user wants a timeline report, too, then create an EventTimeline
      # aggregator for this groupby attrib and add it to the callbacks, too.
      if ( $o->get('timeline') ) {
         my $tl = new EventTimeline(
            groupby    => [$groupby],
            attributes => [qw(Query_time ts)],
         );
         push @tl, $tl;

         $pipeline->add(
            name    => "timeline $groupby",
            process => sub {
               my ( $args ) = @_;
               $tl->aggregate($args->{event});
               return $args;
            },
         );
      }
   } # aggregate

   # ########################################################################
   # Daemonize now that everything is setup and ready to work.
   # ########################################################################
   my $daemon = Daemon->new(
      daemonize => $o->get('daemonize'),
      pid_file  => $o->get('pid'),
      log_file  => $o->get('log'),
   );
   $daemon->run();

   # ########################################################################
   # Do the version-check
   # ########################################################################
   if ( $o->get('version-check') && (!$o->has('quiet') || !$o->get('quiet')) ) {
      VersionCheck::version_check(
         force     => $o->got('version-check'),
         instances => [
            ($qv_dbh ? { dbh => $qv_dbh, dsn => $review_dsn  } : ()),
            ($qh_dbh ? { dbh => $qh_dbh, dsn => $history_dsn } : ()),
            ($ps_dbh ? { dbh => $ps_dbh, dsn => $ps_dsn      } : ()),
         ],
      );
   }

   # ##########################################################################
   # Parse the input.
   # ##########################################################################

   # Pump the pipeline until either no more input, or we're interrupted by
   # CTRL-C, or--this shouldn't happen--the pipeline causes an error.  All
   # work happens inside the pipeline via the procs we created above.
   eval {
      $pipeline->execute(
         oktorun       => \$oktorun,
         pipeline_data => $pipeline_data,
         stats         => \%stats,
      );
   };
   if ( $EVAL_ERROR ) {
      warn "The pipeline caused an error: $EVAL_ERROR";
   }
   PTDEBUG && _d("Pipeline data:", Dumper($pipeline_data));

   save_resume_offset(
      last_event_offset => $parsers[0]->{last_event_offset},
   );

   # Disconnect all open $dbh's
   map {
      $dp->disconnect($_);
      PTDEBUG && _d('Disconnected dbh', $_);
   }
   grep { $_ }
   ($qv_dbh, $qh_dbh, $ps_dbh, $ep_dbh, $aux_dbh);

   return $exit_status;
} # End main()

# ############################################################################
# Subroutines.
# ############################################################################

sub create_review_tables {
   my ( %args ) = @_;
   my @required_args = qw(dbh full_table TableParser type);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $create_table_sql = $args{create_table_sql};
   my ($dbh, $full_table, $tp, $type) = @args{@required_args};

   PTDEBUG && _d('Checking --review table', $full_table);

   # If the repl db doesn't exit, auto-create it, maybe.
   my ($db, $tbl)  = Quoter->split_unquote($full_table);
   my $show_db_sql = qq{SHOW DATABASES LIKE '$db'};
   PTDEBUG && _d($show_db_sql);
   my @db_exists = $dbh->selectrow_array($show_db_sql);
   if ( !@db_exists && !$args{create_table} ) {
      die "--$type database $db does not exist and "
        . "--no-create-$type-table was specified.  You need "
        . "to create the database.\n";
   }
   else {
      # Even if the db already exists, do this in case it does not exist
      # on a slave.
      my $create_db_sql
         = "CREATE DATABASE IF NOT EXISTS "
         . Quoter->quote($db)
         . " /* $tool */";
      PTDEBUG && _d($create_db_sql);
      eval {
         $dbh->do($create_db_sql);
      };
      if ( $EVAL_ERROR && !@db_exists ) {
         warn $EVAL_ERROR;
         die "--$type database $db does not exist and it cannot be "
            . "created automatically.  You need to create the database.\n";
      }
   }
   
   # USE the correct db
   my $sql = "USE " . Quoter->quote($db);
   PTDEBUG && _d($sql);
   $dbh->do($sql);

   # Check if the table exists; if not, create it, maybe.
   my $tbl_exists = $tp->check_table(
      dbh => $dbh,
      db  => $db,
      tbl => $tbl,
   );

   PTDEBUG && _d('Table exists: ', $tbl_exists ? 'yes' : 'no');

   if ( !$tbl_exists && !$args{create_table} ) {
      die "Table $full_table does not exist and "
        . "--no-create-$type-table was specified.  "
        . "You need to create the table.\n";
   }
   else {
      PTDEBUG && _d($dbh, $create_table_sql);
      eval {
         $dbh->do($create_table_sql);
      };
      if ( $EVAL_ERROR && !$args{create_table} ) {
         warn $EVAL_ERROR;
         die "--$type history table $full_table does not exist and it cannot be "
           . "created automatically.  You need to create the table.\n"
      }
   }
}

# TODO: This sub is poorly named since it does more than print reports:
# it aggregates, reports, does QueryReview stuff, etc.
sub print_reports {
   my ( %args ) = @_;
   my @required_args = qw(eas OptionParser);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   my ($o, $qv, $pipeline) = @args{qw(OptionParser QueryReview Pipeline)};
   my ($eas, $tls, $stats) = @args{qw(eas tls stats)};
   my $qh                  = $args{QueryHistory};

   my @reports = @{$o->get('report-format')};
   my @groupby = @{$args{groupby}};
   my @orderby = @{$args{orderby}};

   my $show_all = $o->get('show-all');

   for my $i ( 0..$#groupby ) {
      if ( $o->get('report') || $qv || $qh ) {
         $eas->[$i]->calculate_statistical_metrics();
      }

      my ($orderby_attrib, $orderby_func) = split(/:/, $orderby[$i]);
      $orderby_attrib = check_orderby_attrib($orderby_attrib, $eas->[$i], $o);
      PTDEBUG && _d('Doing reports for groupby', $groupby[$i], 'orderby',
         $orderby_attrib, $orderby_func);

      my ($worst, $other) = get_worst_queries(
         OptionParser   => $o,
         ea             => $eas->[$i],
         orderby_attrib => $orderby_attrib,
         orderby_func   => $orderby_func,
         limit          => $o->get('limit')->[$i] || '95%:20',
         outliers       => $o->get('outliers')->[$i],
      );

      if ( $o->get('report') ) {
         # XXX There's a bug here: --expected-range '','' will cause
         # Use of uninitialized value in numeric lt (<)
         # This bug is intentionally left unfixed at the moment because
         # we exploit it to test a more serious bug: an infinite loop:
         # https://bugs.launchpad.net/percona-toolkit/+bug/888114
         my $expected_range = $o->get('expected-range');
         my $explain_why    = $expected_range
                            && (   @$worst < $expected_range->[0]
                                || @$worst > $expected_range->[1]);

         # Print a header for this groupby/class if we're doing the
         # standard query report and there's more than one class or
         # there's one class but it's not the normal class grouped
         # by fingerprint.
         my $print_header = 0;
         if ( (grep { $_ eq 'query_report'; } @{$o->get('report-format')})
              && (@groupby > 1 || $groupby[$i] ne 'fingerprint') ) {
            $print_header = 1;
         }

         my $report_class = $o->get('output') =~ m/^json/i
                          ? 'JSONReportFormatter'
                          : 'QueryReportFormatter';
         my $qrf = $report_class->new(
            dbh                 => $ep_dbh,
            QueryReview         => $args{QueryReview},
            QueryRewriter       => $args{QueryRewriter},
            OptionParser        => $args{OptionParser},
            QueryParser         => $args{QueryParser},
            Quoter              => $args{Quoter},
            show_all            => $show_all,
            max_hostname_length => $o->get('max-hostname-length'),
            max_line_length     => $o->get('max-line-length'),
         );

         $qrf->print_reports(
            reports      => \@reports,
            ea           => $eas->[$i],
            worst        => $worst,
            other        => $other,
            orderby      => $orderby_attrib,
            groupby      => $groupby[$i],
            print_header => $print_header,
            explain_why  => $explain_why,
            files        => $args{files},
            log_type     => $o->get('type')->[0],
            no_v_format  => !$o->get('vertical-format'),
            variations   => $o->get('variations'),
            group        => { map { $_=>1 } qw(rusage date hostname files header) },
            resume       => $resume,
            anon         => $o->get('output') eq 'json-anon',
         );
      }

      if ( $qv ) {  # query review
         update_query_review_table(
            ea           => $eas->[$i],
            worst        => $worst,
            QueryReview  => $qv,
         );
      }
      if ( $qh ) { # query history
         update_query_history_table(
            ea           => $eas->[$i],
            worst        => $worst,
            QueryHistory => $qh,
         );      
      }

      if ( $o->get('timeline') ) {  # --timeline
         $tls->[$i]->report($tls->[$i]->results(), sub { print @_ });
         $tls->[$i]->reset_aggregated_data();
      }

      $eas->[$i]->reset_aggregated_data();  # Reset for next iteration.

      # Print header report only once.  So remove it from the
      # list of reports after the first groupby's reports.
      if ( $i == 0 ) {
         @reports = grep { $_ ne 'header' } @reports;
      }

   } # Each groupby

   if ( PTDEBUG ) {
      my $report = new ReportFormatter(
         line_width => 74,
      );
      $report->set_columns(
         { name => 'Process'                   },
         { name => 'Time',  right_justify => 1 },
         { name => 'Count', right_justify => 1 },
      );
      $report->title('Pipeline profile');
      my $instrument = $pipeline->instrumentation;
      my $total_time = $instrument->{Pipeline};
      foreach my $process_name ( $pipeline->processes() ) {
         my $t    = $instrument->{$process_name}->{time} || 0;
         my $tp   = sprintf('%.2f %4.1f%%', $t, $t / ($total_time || 1) * 100);
         $report->add_line($process_name, $tp,
            $instrument->{$process_name}->{count} || 0);
      }
      # Reset profile for next iteration.
      $pipeline->reset();

      _d($report->get_report());
   }

   return;
}

# Catches signals so we can exit gracefully.
sub sig_int {
   my ( $signal ) = @_;
   if ( $oktorun ) {
      print STDERR "# Caught SIG$signal.\n";
      $oktorun = 0;
   }
   else {
      print STDERR "# Exiting on SIG$signal.\n";
      save_resume_offset();
      exit(1);
   }
}

# Handle the special defaults for --review & --history
sub handle_special_defaults {
   my ($o, $opt) = @_;
   my $dsn = $o->get($opt);
   return unless $dsn;

   my $para = $o->read_para_after(
      __FILE__, qr/MAGIC_default_${opt}_table/);
   my ($default_table) = $para =~ m/default table is C<([^>]+)>/;
   die "Error parsing special default for --$opt"
      unless $default_table;
   my ($D, $t) = Quoter->split_unquote($default_table);
   $dsn->{D} ||= $D;
   $dsn->{t} ||= $t;
   
   return $dsn;
}

sub make_alt_attrib {
   my ( $alt_attrib ) = @_;
   my @alts   = split('\|', $alt_attrib);
   my $attrib = shift @alts;
   PTDEBUG && _d('Primary attrib:', $attrib, 'aliases:', @alts);
   my @lines;
   push @lines,
      'sub { my ( $args ) = @_; ',
      'my $event = $args->{event}; ',
      "if ( exists \$event->{'$attrib'} ) { ",
      (map { "delete \$event->{'$_'}; "; } @alts),
      'return $args; }',     
      # Primary attrib doesn't exist; look for alts
      (map {
         "if ( exists \$event->{'$_'} ) { "
         . "\$event->{'$attrib'} = \$event->{'$_'}; "
         . "delete \$event->{'$_'}; "
         . 'return $args; }';
      } @alts),
      'return $args; }';
   PTDEBUG && _d('attrib alias sub for', $attrib, ':', @lines);
   my $sub = eval join("\n", @lines);
   die if $EVAL_ERROR;
   return $sub;
}

# Checks that the orderby attrib exists in the ea, returns the default
# orderby attrib if not.
sub check_orderby_attrib {
   my ( $orderby_attrib, $ea, $o ) = @_;

   if ( !$ea->type_for($orderby_attrib) && $orderby_attrib ne 'Query_time' ) {
      my $default_orderby = $o->get_defaults()->{'order-by'};

      # Print the notice only if the query report is being printed, too.
      if ( grep { $_ eq 'query_report' } @{$o->get('report-format')} ) {
         print "--order-by attribute $orderby_attrib doesn't exist, "
            . "using $default_orderby\n";
      }

      # Fall back to the default orderby attrib.
      ( $orderby_attrib, undef ) = split(/:/, $default_orderby);
   }

   PTDEBUG && _d('orderby attrib:', $orderby_attrib);
   return $orderby_attrib;
}

# Read the fh and timeout after t seconds.
sub read_timeout {
   my ( $fh, $t ) = @_;
   return unless $fh;
   $t ||= 0;  # will reset alarm and cause read to wait forever

   # Set the SIGALRM handler.
   my $mask   = POSIX::SigSet->new(&POSIX::SIGALRM);
   my $action = POSIX::SigAction->new(
      sub {
         # This sub is called when a SIGALRM is received.
         die 'read timeout';
      },
      $mask,
   );
   my $oldaction = POSIX::SigAction->new();
   sigaction(&POSIX::SIGALRM, $action, $oldaction);

   my $res;
   eval {
      alarm $t;
      $res = <$fh>;
      alarm 0;
   };
   if ( $EVAL_ERROR ) {
      PTDEBUG && _d('Read error:', $EVAL_ERROR);
      die $EVAL_ERROR unless $EVAL_ERROR =~ m/read timeout/;
      $oktorun = 0;
      $res     = undef;  # res is a blank string after a timeout
   }
   return $res;
}

sub get_cxn {
   my ( %args ) = @_;
   my @required_args = qw(dsn OptionParser DSNParser);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dsn, $o, $dp) = @args{@required_args};

   if ( $o->get('ask-pass') ) {
      $dsn->{p} = OptionParser::prompt_noecho("Enter password "
         . ($args{for} ? "for $args{for}: " : ": "));
   }

   my $dbh = $dp->get_dbh($dp->get_cxn_params($dsn), $args{opts});
   PTDEBUG && _d('Connected dbh', $dbh);
   return $dbh;
}

sub get_worst_queries {
   my ( %args ) = @_;
   my $o              = $args{OptionParser};
   my $ea             = $args{ea};
   my $orderby_attrib = $args{orderby_attrib};
   my $orderby_func   = $args{orderby_func};
   my $limit          = $args{limit};
   my $outliers       = $args{outliers};

   # We don't report on all queries, just the worst, i.e. the top
   # however many.
   my ($total, $count);
   if ( $limit =~ m/^\d+$/ ) {
      $count = $limit;
   }
   else {
      # It's a percentage, so grab as many as needed to get to
      # that % of the file.
      ($total, $count) = $limit =~ m/(\d+)/g;
      $total *= ($ea->results->{globals}->{$orderby_attrib}->{sum} || 0) / 100;
   }
   my %top_spec = (
      attrib  => $orderby_attrib,
      orderby => $orderby_func || 'cnt',
      total   => $total,
      count   => $count,
   );
   if ( $args{outliers} ) {
      @top_spec{qw(ol_attrib ol_limit ol_freq)}
         = split(/:/, $args{outliers});
   }

   # The queries that will be reported.
   return $ea->top_events(%top_spec);
}

sub update_query_review_table {
   my ( %args ) = @_;
   foreach my $arg ( qw(ea worst QueryReview) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $ea    = $args{ea};
   my $worst = $args{worst};
   my $qv    = $args{QueryReview};

   my $attribs = $ea->get_attributes();

   PTDEBUG && _d('Updating query review tables'); 

   foreach my $worst_info ( @$worst ) {
      my $item        = $worst_info->[0];
      my $stats       = $ea->results->{classes}->{$item};
      my $sample      = $ea->results->{samples}->{$item};
      my $review_vals = $qv->get_review_info($item);
      $qv->set_review_info(
         fingerprint => $item,
         sample      => $sample->{arg} || '',
         first_seen  => $stats->{ts}->{min},
         last_seen   => $stats->{ts}->{max}
      );
   }

   return;
}

sub update_query_history_table {
   my ( %args ) = @_;
   foreach my $arg ( qw(ea worst QueryHistory) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $ea    = $args{ea};
   my $worst = $args{worst};
   my $qh    = $args{QueryHistory};

   my $attribs = $ea->get_attributes();

   PTDEBUG && _d('Updating query review tables'); 

   foreach my $worst_info ( @$worst ) {
      my $item        = $worst_info->[0];
      my $sample      = $ea->results->{samples}->{$item};

      my %history;
      foreach my $attrib ( @$attribs ) {
         $history{$attrib} = $ea->metrics(
            attrib => $attrib,
            where  => $item,
         );
      }
      $qh->set_review_history(
         $item, $sample->{arg} || '', %history);
   }

   return;
}


# Sub: verify_run_time
#   Verify that the given run mode and run time are valid.  If the run mode
#   is "interval", the time boundary (in seconds) for the run time is returned
#   if valid.  Else, undef is returned because modes "clock" and "event" have
#   no boundaries that need to be verified.  In any case the sub will die if
#   something is invalid, so the caller should eval their call.  The eval
#   error message is suitable for <OptionParser::save_error()>.
#
# Parameters:
#   %args - Arguments
#
# Required Arguments:
#   run_mode - Name of run mode (e.g. "clock", "event" or "interval")
#   run_time - Run time in seconds
#
# Returns:
#   Time boundary in seconds if run mode and time are valid; dies if
#   they are not.  Time boundary is undef except for interval run mode.
sub verify_run_time {
   my ( %args ) = @_;
   my $run_mode = lc $args{run_mode};
   my $run_time = defined $args{run_time} ? lc $args{run_time} : undef;
   PTDEBUG && _d("Verifying run time mode", $run_mode, "and time", $run_time);

   die "Invalid --run-time-mode: $run_mode\n"
      unless $run_mode =~ m/clock|event|interval/;

   if ( defined $run_time && $run_time < 0 ) {
      die "--run-time must be greater than zero\n";
   }

   my $boundary;
   if ( $run_mode eq 'interval' ) {
      if ( !defined $run_time || $run_time <= 0 ) {
         die "--run-time must be greater than zero for "
            . "--run-time-mode $run_mode\n";
      }

      if ( $run_time > 86400 ) {  # 1 day
         # Make sure run time is a whole day and not something like 25h.
         if ( $run_time % 86400 ) {
            die "Invalid --run-time argument for --run-time-mode $run_mode; "
            . "see documentation.\n"
         }
         $boundary = $run_time;
      }
      else {
         # If run time is sub-minute (some amount of seconds), it should
         # divide evenly into minute boundaries.  If it's sub-minute
         # (some amount of minutes), it should divide evenly into hour
         # boundaries.  If it's sub-hour, it should divide eventy into
         # day boundaries.
         $boundary = $run_time <= 60   ? 60     # seconds divide into minutes
                   : $run_time <= 3600 ? 3600   # minutes divide into hours
                   :                     86400; # hours divide into days
         if ( $boundary % $run_time ) {
            die "Invalid --run-time argument for --run-time-mode $run_mode; "
               . "see documentation.\n"
         }
      }
   }

   return $boundary;
}

sub save_resume_offset {
   my (%args) = @_;
   my $last_event_offset = $args{last_event_offset};

   if ( !$resume_file || !$offset ) {
      PTDEBUG && _d('Not saving resume offset because there is no '
         . 'resume file or offset:', $resume_file, $offset);
      return;
   }

   PTDEBUG && _d('Saving resume at offset', $offset, 'to', $resume_file);
   open my $resume_fh, '>', $resume_file
      or die "Error opening $resume_file: $OS_ERROR";

   if ( $resume->{simple} ) {
      print { $resume_fh } $offset, "\n";
      warn "\n# Saved resume file offset $offset to $resume_file\n";
   }
   else {
      # 2.2.3+ enhanced resume file
      $resume->{stop_offset} = defined $last_event_offset ? $last_event_offset
                             :                              $offset;
      foreach my $key ( sort keys %$resume ) {
         next if $key eq 'simple';
         print { $resume_fh } "$key=$resume->{$key}\n";
      }
      warn "\n# Saved resume file stop_offset $resume->{stop_offset} to "
         . "$resume_file\n";
   }

   close $resume_fh
      or die "Error close $resume_file: $OS_ERROR";

   return;
}

sub sanitize_event {
   my ($event) = @_;

   # Quoted and unquoted values should be treated the same
   # https://bugs.launchpad.net/percona-toolkit/+bug/1176010
   if ( $event->{db} ) {
      $event->{db} =~ s/^`//;
      $event->{db} =~ s/`$//;
   }
   if ( $event->{Schema} ) {
      $event->{Schema} =~ s/^`//;
      $event->{Schema} =~ s/`$//;
   }

   return;
}

# make an effort to check if file is a raw binlog
# (i.e. was not converted to text using mysqlbinlog)
sub is_raw_binlog {
   my $filename = shift;
   
   return -B $filename; 
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

# #############################################################################
# Documentation.
# #############################################################################

=pod

=head1 NAME

pt-query-digest - Analyze MySQL queries from logs, processlist, and tcpdump.

=head1 SYNOPSIS

Usage: pt-query-digest [OPTIONS] [FILES] [DSN]

pt-query-digest analyzes MySQL queries from slow, general, and binary log
files.  It can also analyze queries from C<SHOW PROCESSLIST> and MySQL
protocol data from tcpdump.  By default, queries are grouped by fingerprint
and reported in descending order of query time (i.e. the slowest queries
first).  If no C<FILES> are given, the tool reads C<STDIN>.  The optional
C<DSN> is used for certain options like L<"--since"> and L<"--until">.

Report the slowest queries from C<slow.log>:

   pt-query-digest slow.log

Report the slowest queries from the processlist on host1:

   pt-query-digest --processlist h=host1

Capture MySQL protocol data with tcppdump, then report the slowest queries:

   tcpdump -s 65535 -x -nn -q -tttt -i any -c 1000 port 3306 > mysql.tcp.txt

   pt-query-digest --type tcpdump mysql.tcp.txt

Save query data from C<slow.log> to host2 for later review and trend analysis:

   pt-query-digest --review h=host2 --no-report slow.log

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

pt-query-digest is a sophisticated but easy to use tool for analyzing
MySQL queries.  It can analyze queries from MySQL slow, general, and binary
logs. (Binary logs must first be converted to text, see L<"--type">).
It can also use C<SHOW PROCESSLIST> and MySQL protocol data from tcpdump.
By default, the tool reports which queries are the slowest, and therefore
the most important to optimize.  More complex and custom-tailored reports
can be created by using options like L<"--group-by">, L<"--filter">, and
L<"--embedded-attributes">.

Query analysis is a best-practice that should be done frequently.  To
make this easier, pt-query-digest has two features: query review
(L<"--review">) and query history (L<"--history">).  When the L<"--review">
option is used, all unique queries are saved to a database.  When the
tool is ran again with L<"--review">, queries marked as reviewed in
the database are not printed in the report.  This highlights new queries
that need to be reviewed.  When the L<"--history"> option is used,
query metrics (query time, lock time, etc.) for each unique query are
saved to database.  Each time the tool is ran with L<"--history">, the
more historical data is saved which can be used to trend and analyze
query performance over time.

=head1 ATTRIBUTES

pt-query-digest works on events, which are a collection of key-value pairs
called attributes.  You'll recognize most of the attributes right away:
C<Query_time>, C<Lock_time>, and so on.  You can just look at a slow log
and see them.  However, there are some that don't exist in the slow log,
and slow logs may actually include different kinds of attributes (for example,
you may have a server with the Percona patches).

See L<"ATTRIBUTES REFERENCE"> near the end of this documentation for a list
of common and L<"--type"> specific attributes.  A familiarity with these
attributes is necessary for working with L<"--filter">,
L<"--ignore-attributes">, and other attribute-related options.

With creative use of L<"--filter">, you can create new attributes derived
from existing attributes.  For example, to create an attribute called
C<Row_ratio> for examining the ratio of C<Rows_sent> to C<Rows_examined>,
specify a filter like:

  --filter '($event->{Row_ratio} = $event->{Rows_sent} / ($event->{Rows_examined})) && 1'

The C<&& 1> trick is needed to create a valid one-line syntax that is always
true, even if the assignment happens to evaluate false.  The new attribute will
automatically appears in the output:

  # Row ratio        1.00    0.00      1    0.50      1    0.71    0.50

Attributes created this way can be specified for L<"--order-by"> or any
option that requires an attribute.

=head1 OUTPUT

The default L<"--output"> is a query analysis report.  The L<"--[no]report">
option controls whether or not this report is printed.  Sometimes you may
want to parse all the queries but suppress the report, for example when using
L<"--review"> or L<"--history">.

There is one paragraph for each class of query analyzed.  A "class" of queries
all have the same value for the L<"--group-by"> attribute which is
C<fingerprint> by default.  (See L<"ATTRIBUTES">.)  A fingerprint is an
abstracted version of the query text with literals removed, whitespace
collapsed, and so forth.  The report is formatted so it's easy to paste into
emails without wrapping, and all non-query lines begin with a comment, so you
can save it to a .sql file and open it in your favorite syntax-highlighting
text editor.  There is a response-time profile at the beginning.

The output described here is controlled by L<"--report-format">.
That option allows you to specify what to print and in what order.
The default output in the default order is described here.

The report, by default, begins with a paragraph about the entire analysis run
The information is very similar to what you'll see for each class of queries in
the log, but it doesn't have some information that would be too expensive to
keep globally for the analysis.  It also has some statistics about the code's
execution itself, such as the CPU and memory usage, the local date and time
of the run, and a list of input file read/parsed.

Following this is the response-time profile over the events.  This is a
highly summarized view of the unique events in the detailed query report
that follows.  It contains the following columns:

 Column        Meaning
 ============  ==========================================================
 Rank          The query's rank within the entire set of queries analyzed
 Query ID      The query's fingerprint
 Response time The total response time, and percentage of overall total
 Calls         The number of times this query was executed
 R/Call        The mean response time per execution
 V/M           The Variance-to-mean ratio of response time
 Item          The distilled query

A final line whose rank is shown as MISC contains aggregate statistics on the
queries that were not included in the report, due to options such as
L<"--limit"> and L<"--outliers">.  For details on the variance-to-mean ratio,
please see http://en.wikipedia.org/wiki/Index_of_dispersion.

Next, the detailed query report is printed.  Each query appears in a paragraph.
Here is a sample, slightly reformatted so 'perldoc' will not wrap lines in a
terminal.  The following will all be one paragraph, but we'll break it up for
commentary.

 # Query 2: 0.01 QPS, 0.02x conc, ID 0xFDEA8D2993C9CAF3 at byte 160665

This line identifies the sequential number of the query in the sort order
specified by L<"--order-by">.  Then there's the queries per second, and the
approximate concurrency for this query (calculated as a function of the timespan
and total Query_time).  Next there's a query ID.  This ID is a hex version of
the query's checksum in the database, if you're using L<"--review">.  You can
select the reviewed query's details from the database with a query like C<SELECT
.... WHERE checksum=0xFDEA8D2993C9CAF3>.  

If you are investigating the report and want to print out every sample of a
particular query, then the following L<"--filter"> may be helpful:

   pt-query-digest slow.log           \
      --no-report                     \
      --output slowlog                \
      --filter '$event->{fingerprint} \
           && make_checksum($event->{fingerprint}) eq "FDEA8D2993C9CAF3"'

Notice that you must remove the C<0x> prefix from the checksum.

Finally, in case you want to find a sample of the query in the log file, there's
the byte offset where you can look.  (This is not always accurate, due to some
anomalies in the slow log format, but it's usually right.)  The position
refers to the worst sample, which we'll see more about below.

Next is the table of metrics about this class of queries.

 #           pct   total    min    max     avg     95%  stddev  median
 # Count       0       2
 # Exec time  13   1105s   552s   554s    553s    554s      2s    553s
 # Lock time   0   216us   99us  117us   108us   117us    12us   108us
 # Rows sent  20   6.26M  3.13M  3.13M   3.13M   3.13M   12.73   3.13M
 # Rows exam   0   6.26M  3.13M  3.13M   3.13M   3.13M   12.73   3.13M

The first line is column headers for the table.  The percentage is the percent
of the total for the whole analysis run, and the total is the actual value of
the specified metric.  For example, in this case we can see that the query
executed 2 times, which is 13% of the total number of queries in the file.  The
min, max and avg columns are self-explanatory.  The 95% column shows the 95th
percentile; 95% of the values are less than or equal to this value.  The
standard deviation shows you how tightly grouped the values are.  The standard
deviation and median are both calculated from the 95th percentile, discarding
the extremely large values.

The stddev, median and 95th percentile statistics are approximate.  Exact
statistics require keeping every value seen, sorting, and doing some
calculations on them.  This uses a lot of memory.  To avoid this, we keep 1000
buckets, each of them 5% bigger than the one before, ranging from .000001 up to
a very big number.  When we see a value we increment the bucket into which it
falls.  Thus we have fixed memory per class of queries.  The drawback is the
imprecision, which typically falls in the 5 percent range.

Next we have statistics on the users, databases and time range for the query.

 # Users       1   user1
 # Databases   2     db1(1), db2(1)
 # Time range 2008-11-26 04:55:18 to 2008-11-27 00:15:15

The users and databases are shown as a count of distinct values, followed by the
values.  If there's only one, it's shown alone; if there are many, we show each
of the most frequent ones, followed by the number of times it appears.

 # Query_time distribution
 #   1us
 #  10us
 # 100us
 #   1ms
 #  10ms  #####
 # 100ms  ####################
 #    1s  ##########
 #  10s+

The execution times show a logarithmic chart of time clustering.  Each query
goes into one of the "buckets" and is counted up.  The buckets are powers of
ten.  The first bucket is all values in the "single microsecond range" -- that
is, less than 10us.  The second is "tens of microseconds," which is from 10us
up to (but not including) 100us; and so on.  The charted attribute can be
changed by specifying L<"--report-histogram"> but is limited to time-based
attributes.

 # Tables
 #    SHOW TABLE STATUS LIKE 'table1'\G
 #    SHOW CREATE TABLE `table1`\G
 # EXPLAIN
 SELECT * FROM table1\G

This section is a convenience: if you're trying to optimize the queries you see
in the slow log, you probably want to examine the table structure and size.
These are copy-and-paste-ready commands to do that.

Finally, we see a sample of the queries in this class of query.  This is not a
random sample.  It is the query that performed the worst, according to the sort
order given by L<"--order-by">.  You will normally see a commented C<# EXPLAIN>
line just before it, so you can copy-paste the query to examine its EXPLAIN
plan. But for non-SELECT queries that isn't possible to do, so the tool tries to
transform the query into a roughly equivalent SELECT query, and adds that below.

If you want to find this sample event in the log, use the offset mentioned
above, and something like the following:

  tail -c +<offset> /path/to/file | head

See also L<"--report-format">.

=head1 QUERY REVIEW

A query L<"--review"> is the process of storing all the query fingerprints 
analyzed.  This has several benefits:

=over

=item *

You can add metadata to classes of queries, such as marking them for follow-up,
adding notes to queries, or marking them with an issue ID for your issue
tracking system.

=item *

You can refer to the stored values on subsequent runs so you'll know whether
you've seen a query before.  This can help you cut down on duplicated work.

=item *

You can store historical data such as the row count, query times, and generally
anything you can see in the report.

=back

To use this feature, you run pt-query-digest with the L<"--review"> option.  It
will store the fingerprints and other information into the table you specify.
Next time you run it with the same option, it will do the following:

=over

=item *

It won't show you queries you've already reviewed.  A query is considered to be
already reviewed if you've set a value for the C<reviewed_by> column.  (If you
want to see queries you've already reviewed, use the L<"--report-all"> option.)

=item *

Queries that you've reviewed, and don't appear in the output, will cause gaps in
the query number sequence in the first line of each paragraph.  And the value
you've specified for L<"--limit"> will still be honored.  So if you've reviewed all
queries in the top 10 and you ask for the top 10, you won't see anything in the
output.

=item *

If you want to see the queries you've already reviewed, you can specify
L<"--report-all">.  Then you'll see the normal analysis output, but you'll
also see the information from the review table, just below the execution time
graph.  For example,

  # Review information
  #      comments: really bad IN() subquery, fix soon!
  #    first_seen: 2008-12-01 11:48:57
  #   jira_ticket: 1933
  #     last_seen: 2008-12-18 11:49:07
  #      priority: high
  #   reviewed_by: xaprb
  #   reviewed_on: 2008-12-18 15:03:11

This metadata is useful because, as you analyze your queries, you get
your comments integrated right into the report.

=back

=head1 FINGERPRINTS

A query fingerprint is the abstracted form of a query, which makes it possible
to group similar queries together.  Abstracting a query removes literal values,
normalizes whitespace, and so on.  For example, consider these two queries:

  SELECT name, password FROM user WHERE id='12823';
  select name,   password from user
     where id=5;

Both of those queries will fingerprint to

  select name, password from user where id=?

Once the query's fingerprint is known, we can then talk about a query as though
it represents all similar queries.

What C<pt-query-digest> does is analogous to a GROUP BY statement in SQL.  (But
note that "multiple columns" doesn't define a multi-column grouping; it defines
multiple reports!) If your command-line looks like this,

  pt-query-digest               \
      --group-by fingerprint    \
      --order-by Query_time:sum \
      --limit 10                \
      slow.log

The corresponding pseudo-SQL looks like this:

  SELECT WORST(query BY Query_time), SUM(Query_time), ...
  FROM /path/to/slow.log
  GROUP BY FINGERPRINT(query)
  ORDER BY SUM(Query_time) DESC
  LIMIT 10

You can also use the value C<distill>, which is a kind of super-fingerprint.
See L<"--group-by"> for more.

Query fingerprinting accommodates many special cases, which have proven
necessary in the real world.  For example, an C<IN> list with 5 literals
is really equivalent to one with 4 literals, so lists of literals are
collapsed to a single one.  If you find something that is not fingerprinted
properly, please submit a bug report with a reproducible test case. 

Here is a list of transformations during fingerprinting, which might not
be exhaustive:

=over

=item *

Group all SELECT queries from mysqldump together, even if they are against
different tables.  The same applies to all queries from pt-table-checksum.

=item *

Shorten multi-value INSERT statements to a single VALUES() list.

=item *

Strip comments.

=item *

Abstract the databases in USE statements, so all USE statements are grouped
together.

=item *

Replace all literals, such as quoted strings.  For efficiency, the code that
replaces literal numbers is somewhat non-selective, and might replace some
things as numbers when they really are not.  Hexadecimal literals are also
replaced.  NULL is treated as a literal.  Numbers embedded in identifiers are
also replaced, so tables named similarly will be fingerprinted to the same
values (e.g. users_2009 and users_2010 will fingerprint identically).

=item *

Collapse all whitespace into a single space.

=item *

Lowercase the entire query.

=item *

Replace all literals inside of IN() and VALUES() lists with a single
placeholder, regardless of cardinality.

=item *

Collapse multiple identical UNION queries into a single one.

=back

=head1 OPTIONS

This tool accepts additional command-line arguments.  Refer to the
L<"SYNOPSIS"> and usage information for details.

=over

=item --ask-pass

Prompt for a password when connecting to MySQL.

=item --attribute-aliases

type: array; default: db|Schema

List of attribute|alias,etc.

Certain attributes have multiple names, like db and Schema.  If an event does
not have the primary attribute, pt-query-digest looks for an alias attribute.
If it finds an alias, it creates the primary attribute with the alias
attribute's value and removes the alias attribute.

If the event has the primary attribute, all alias attributes are deleted.

This helps simplify event attributes so that, for example, there will not
be report lines for both db and Schema.

=item --attribute-value-limit

type: int; default: 0 

A sanity limit for attribute values.

This option deals with bugs in slow logging functionality that causes large
values for attributes.  If the attribute's value is bigger than this, the
last-seen value for that class of query is used instead.
Disabled by default.

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

=item --[no]continue-on-error

default: yes

Continue parsing even if there is an error.  The tool will not continue
forever: it stops once any process causes 100 errors, in which case there
is probably a bug in the tool or the input is invalid.

=item --[no]create-history-table

default: yes

Create the L<"--history"> table if it does not exist.

This option causes the table specified by L<"--history"> to be created
with the default structure shown in the documentation for L<"--history">.

=item --[no]create-review-table

default: yes

Create the L<"--review"> table if it does not exist.

This option causes the table specified by L<"--review"> to be created
with the default structure shown in the documentation for L<"--review">.

=item --daemonize

Fork to the background and detach from the shell.  POSIX
operating systems only.

=item --database

short form: -D; type: string

Connect to this database.

=item --defaults-file

short form: -F; type: string

Only read mysql options from the given file.  You must give an absolute pathname.

=item --embedded-attributes

type: array

Two Perl regex patterns to capture pseudo-attributes embedded in queries.

Embedded attributes might be special attribute-value pairs that you've hidden
in comments.  The first regex should match the entire set of attributes (in
case there are multiple).  The second regex should match and capture
attribute-value pairs from the first regex.

For example, suppose your query looks like the following:

  SELECT * from users -- file: /login.php, line: 493;

You might run pt-query-digest with the following option:

  pt-query-digest --embedded-attributes ' -- .*','(\w+): ([^\,]+)'

The first regular expression captures the whole comment:

  " -- file: /login.php, line: 493;"

The second one splits it into attribute-value pairs and adds them to the event:

   ATTRIBUTE  VALUE
   =========  ==========
   file       /login.php
   line       493

B<NOTE>: All commas in the regex patterns must be escaped with \ otherwise
the pattern will break.

=item --expected-range

type: array; default: 5,10

Explain items when there are more or fewer than expected.

Defines the number of items expected to be seen in the report given by
L<"--[no]report">, as controlled by L<"--limit"> and L<"--outliers">.  If
there  are more or fewer items in the report, each one will explain why it was
included.

=item --explain

type: DSN

Run EXPLAIN for the sample query with this DSN and print results.

This works only when L<"--group-by"> includes fingerprint.  It causes
pt-query-digest to run EXPLAIN and include the output into the report.  For
safety, queries that appear to have a subquery that EXPLAIN will execute won't
be EXPLAINed.  Those are typically "derived table" queries of the form

  select ... from ( select .... ) der;

The EXPLAIN results are printed as a full vertical format in the event report,
which appears at the end of each event report in vertical style
(C<\G>) just like MySQL prints it.

=item --filter

type: string

Discard events for which this Perl code doesn't return true.

This option is a string of Perl code or a file containing Perl code that gets
compiled into a subroutine with one argument: $event.  This is a hashref.
If the given value is a readable file, then pt-query-digest reads the entire
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

If the filter code won't compile, pt-query-digest will die with an error.
If the filter code does compile, an error may still occur at runtime if the
code tries to do something wrong (like pattern match an undefined value).
pt-query-digest does not provide any safeguards so code carefully!

An example filter that discards everything but SELECT statements:

  --filter '$event->{arg} =~ m/^select/i'

This is compiled into a subroutine like the following:

  sub { $event = shift; ( $event->{arg} =~ m/^select/i ) && return $event; }

It is permissible for the code to have side effects (to alter C<$event>).

See L<"ATTRIBUTES REFERENCE"> for a list of common and L<"--type"> specific
attributes.

Here are more examples of filter code:

=over

=item Host/IP matches domain.com

--filter '($event->{host} || $event->{ip} || "") =~ m/domain.com/'

Sometimes MySQL logs the host where the IP is expected.  Therefore, we
check both.

=item User matches john

--filter '($event->{user} || "") =~ m/john/'

=item More than 1 warning

--filter '($event->{Warning_count} || 0) > 1'

=item Query does full table scan or full join

--filter '(($event->{Full_scan} || "") eq "Yes") || (($event->{Full_join} || "") eq "Yes")'

=item Query was not served from query cache

--filter '($event->{QC_Hit} || "") eq "No"'

=item Query is 1 MB or larger

--filter '$event->{bytes} >= 1_048_576'

=back

Since L<"--filter"> allows you to alter C<$event>, you can use it to do other
things, like create new attributes.  See L<"ATTRIBUTES"> for an example.

=item --group-by

type: Array; default: fingerprint

Which attribute of the events to group by.

In general, you can group queries into classes based on any attribute of the
query, such as C<user> or C<db>, which will by default show you which users
and which databases get the most C<Query_time>.  The default attribute,
C<fingerprint>, groups similar, abstracted queries into classes; see below
and see also L<"FINGERPRINTS">.

A report is printed for each L<"--group-by"> value (unless C<--no-report> is
given).  Therefore, C<--group-by user,db> means "report on queries with the
same user and report on queries with the same db"; it does not mean "report
on queries with the same user and db."  See also L<"OUTPUT">.

Every value must have a corresponding value in the same position in
L<"--order-by">.  However, adding values to L<"--group-by"> will automatically
add values to L<"--order-by">, for your convenience.

There are several magical values that cause some extra data mining to happen
before the grouping takes place:

=over

=item fingerprint

This causes events to be fingerprinted to abstract queries into
a canonical form, which is then used to group events together into a class.
See L<"FINGERPRINTS"> for more about fingerprinting.

=item tables

This causes events to be inspected for what appear to be tables, and
then aggregated by that.  Note that a query that contains two or more tables
will be counted as many times as there are tables; so a join against two tables
will count the Query_time against both tables.

=item distill

This is a sort of super-fingerprint that collapses queries down
into a suggestion of what they do, such as C<INSERT SELECT table1 table2>.

=back

=item --help

Show help and exit.

=item --history

type: DSN

Save metrics for each query class in the given table.  pt-query-digest saves
query metrics (query time, lock time, etc.) to this table so you can see how
query classes change over time.

=for comment ignore-pt-internal-value
MAGIC_default_history_table

The default table is C<percona_schema.query_history>.  Specify database
(D) and table (t) DSN options to override the default.  The database and
table are automatically created unless C<--no-create-history-table>
is specified (see L<"--[no]create-history-table">).

pt-query-digest inspects the columns in the table.  The table must have at
least the following columns:

  CREATE TABLE query_review_history (
    checksum     CHAR(32) NOT NULL,
    sample       TEXT NOT NULL
  );

Any columns not mentioned above are inspected to see if they follow a certain
naming convention.  The column is special if the name ends with an underscore
followed by any of these values:

=for comment ignore-pt-internal-value
MAGIC_history_columns

  pct|avg|cnt|sum|min|max|pct_95|stddev|median|rank

If the column ends with one of those values, then the prefix is interpreted as
the event attribute to store in that column, and the suffix is interpreted as
the metric to be stored.  For example, a column named C<Query_time_min> will be
used to store the minimum C<Query_time> for the class of events.

The table should also have a primary key, but that is up to you, depending on
how you want to store the historical data.  We suggest adding ts_min and ts_max
columns and making them part of the primary key along with the checksum.  But
you could also just add a ts_min column and make it a DATE type, so you'd get
one row per class of queries per day.

The following table definition is used for L<"--[no]create-history-table">:

=for comment ignore-pt-internal-value
MAGIC_create_history_table

 CREATE TABLE IF NOT EXISTS query_history (
   checksum             CHAR(32) NOT NULL,
   sample               TEXT NOT NULL,
   ts_min               DATETIME,
   ts_max               DATETIME,
   ts_cnt               FLOAT,
   Query_time_sum       FLOAT,
   Query_time_min       FLOAT,
   Query_time_max       FLOAT,
   Query_time_pct_95    FLOAT,
   Query_time_stddev    FLOAT,
   Query_time_median    FLOAT,
   Lock_time_sum        FLOAT,
   Lock_time_min        FLOAT,
   Lock_time_max        FLOAT,
   Lock_time_pct_95     FLOAT,
   Lock_time_stddev     FLOAT,
   Lock_time_median     FLOAT,
   Rows_sent_sum        FLOAT,
   Rows_sent_min        FLOAT,
   Rows_sent_max        FLOAT,
   Rows_sent_pct_95     FLOAT,
   Rows_sent_stddev     FLOAT,
   Rows_sent_median     FLOAT,
   Rows_examined_sum    FLOAT,
   Rows_examined_min    FLOAT,
   Rows_examined_max    FLOAT,
   Rows_examined_pct_95 FLOAT,
   Rows_examined_stddev FLOAT,
   Rows_examined_median FLOAT,
   -- Percona extended slowlog attributes 
   -- http://www.percona.com/docs/wiki/patches:slow_extended
   Rows_affected_sum             FLOAT,
   Rows_affected_min             FLOAT,
   Rows_affected_max             FLOAT,
   Rows_affected_pct_95          FLOAT,
   Rows_affected_stddev          FLOAT,
   Rows_affected_median          FLOAT,
   Rows_read_sum                 FLOAT,
   Rows_read_min                 FLOAT,
   Rows_read_max                 FLOAT,
   Rows_read_pct_95              FLOAT,
   Rows_read_stddev              FLOAT,
   Rows_read_median              FLOAT,
   Merge_passes_sum              FLOAT,
   Merge_passes_min              FLOAT,
   Merge_passes_max              FLOAT,
   Merge_passes_pct_95           FLOAT,
   Merge_passes_stddev           FLOAT,
   Merge_passes_median           FLOAT,
   InnoDB_IO_r_ops_min           FLOAT,
   InnoDB_IO_r_ops_max           FLOAT,
   InnoDB_IO_r_ops_pct_95        FLOAT,
   InnoDB_IO_r_ops_stddev        FLOAT,
   InnoDB_IO_r_ops_median        FLOAT,
   InnoDB_IO_r_bytes_min         FLOAT,
   InnoDB_IO_r_bytes_max         FLOAT,
   InnoDB_IO_r_bytes_pct_95      FLOAT,
   InnoDB_IO_r_bytes_stddev      FLOAT,
   InnoDB_IO_r_bytes_median      FLOAT,
   InnoDB_IO_r_wait_min          FLOAT,
   InnoDB_IO_r_wait_max          FLOAT,
   InnoDB_IO_r_wait_pct_95       FLOAT,
   InnoDB_IO_r_wait_stddev       FLOAT,
   InnoDB_IO_r_wait_median       FLOAT,
   InnoDB_rec_lock_wait_min      FLOAT,
   InnoDB_rec_lock_wait_max      FLOAT,
   InnoDB_rec_lock_wait_pct_95   FLOAT,
   InnoDB_rec_lock_wait_stddev   FLOAT,
   InnoDB_rec_lock_wait_median   FLOAT,
   InnoDB_queue_wait_min         FLOAT,
   InnoDB_queue_wait_max         FLOAT,
   InnoDB_queue_wait_pct_95      FLOAT,
   InnoDB_queue_wait_stddev      FLOAT,
   InnoDB_queue_wait_median      FLOAT,
   InnoDB_pages_distinct_min     FLOAT,
   InnoDB_pages_distinct_max     FLOAT,
   InnoDB_pages_distinct_pct_95  FLOAT,
   InnoDB_pages_distinct_stddev  FLOAT,
   InnoDB_pages_distinct_median  FLOAT,
   -- Boolean (Yes/No) attributes.  Only the cnt and sum are needed
   -- for these.  cnt is how many times is attribute was recorded,
   -- and sum is how many of those times the value was Yes.  So
   -- sum/cnt * 100 equals the percentage of recorded times that
   -- the value was Yes.
   QC_Hit_cnt          FLOAT,
   QC_Hit_sum          FLOAT,
   Full_scan_cnt       FLOAT,
   Full_scan_sum       FLOAT,
   Full_join_cnt       FLOAT,
   Full_join_sum       FLOAT,
   Tmp_table_cnt       FLOAT,
   Tmp_table_sum       FLOAT,
   Tmp_table_on_disk_cnt FLOAT,
   Tmp_table_on_disk_sum FLOAT,
   Filesort_cnt          FLOAT,
   Filesort_sum          FLOAT,
   Filesort_on_disk_cnt  FLOAT,
   Filesort_on_disk_sum  FLOAT,
   PRIMARY KEY(checksum, ts_min, ts_max)
 );

Note that we store the count (cnt) for the ts attribute only; it will be
redundant to store this for other attributes.

Starting from Percona Toolkit 3.0.11, the checksum function has been updated to use 32 chars in the MD5 sum.
This causes the checksum field in the history table will have a different value than in the previous versions of the tool.

=item --host

short form: -h; type: string

Connect to host.

=item --ignore-attributes

type: array; default: arg, cmd, insert_id, ip, port, Thread_id, timestamp, exptime, flags, key, res, val, server_id, offset, end_log_pos, Xid

Do not aggregate these attributes.  Some attributes are not query metrics
but metadata which doesn't need to be (or can't be) aggregated.

=item --inherit-attributes

type: array; default: db,ts

If missing, inherit these attributes from the last event that had them.

This option sets which attributes are inherited or carried forward to events
which do not have them.  For example, if one event has the db attribute equal
to "foo", but the next event doesn't have the db attribute, then it inherits
"foo" for its db attribute.

=item --interval

type: float; default: .1

How frequently to poll the processlist, in seconds.

=item --iterations

type: int; default: 1

How many times to iterate through the collect-and-report cycle.  If 0, iterate
to infinity.  Each iteration runs for L<"--run-time"> amount of time.  An
iteration is usually determined by an amount of time and a report is printed
when that amount of time elapses.  With L<"--run-time-mode"> C<interval>,
an interval is instead determined by the interval time you specify with
L<"--run-time">.  See L<"--run-time"> and L<"--run-time-mode"> for more
information.

=item --limit

type: Array; default: 95%:20

Limit output to the given percentage or count.

If the argument is an integer, report only the top N worst queries.  If the
argument is an integer followed by the C<%> sign, report that percentage of the
worst queries.  If the percentage is followed by a colon and another integer,
report the top percentage or the number specified by that integer, whichever
comes first.

The value is actually a comma-separated array of values, one for each item in
L<"--group-by">.  If you don't specify a value for any of those items, the
default is the top 95%.

See also L<"--outliers">.

=item --log

type: string

Print all output to this file when daemonized.

=item --max-hostname-length

type: int; default: 10

Trim host names in reports to this length. 0=Do not trim host names.

=item --max-line-length

type: int; default: 74

Trim lines to this length. 0=Do not trim lines.

=item --order-by

type: Array; default: Query_time:sum

Sort events by this attribute and aggregate function.

This is a comma-separated list of order-by expressions, one for each
L<"--group-by"> attribute.  The default C<Query_time:sum> is used for
L<"--group-by"> attributes without explicitly given L<"--order-by"> attributes
(that is, if you specify more L<"--group-by"> attributes than corresponding
L<"--order-by"> attributes).  The syntax is C<attribute:aggregate>.  See
L<"ATTRIBUTES"> for valid attributes.  Valid aggregates are:

   Aggregate Meaning
   ========= ============================
   sum       Sum/total attribute value
   min       Minimum attribute value
   max       Maximum attribute value
   cnt       Frequency/count of the query

For example, the default C<Query_time:sum> means that queries in the
query analysis report will be ordered (sorted) by their total query execution
time ("Exec time").  C<Query_time:max> orders the queries by their
maximum query execution time, so the query with the single largest
C<Query_time> will be list first.  C<cnt> refers more to the frequency
of the query as a whole, how often it appears; "Count" is its corresponding
line in the query analysis report.  So any attribute and C<cnt> should yield
the same report wherein queries are sorted by the number of times they
appear.

When parsing general logs (L<"--type"> C<genlog>), the default L<"--order-by">
becomes C<Query_time:cnt>.  General logs do not report query times so only
the C<cnt> aggregate makes sense because all query times are zero.

If you specify an attribute that doesn't exist in the events, then
pt-query-digest falls back to the default C<Query_time:sum> and prints a notice
at the beginning of the report for each query class.  You can create attributes
with L<"--filter"> and order by them; see L<"ATTRIBUTES"> for an example.

=item --outliers

type: array; default: Query_time:1:10

Report outliers by attribute:percentile:count.

The syntax of this option is a comma-separated list of colon-delimited strings.
The first field is the attribute by which an outlier is defined.  The second is
a number that is compared to the attribute's 95th percentile.  The third is
optional, and is compared to the attribute's cnt aggregate.  Queries that pass
this specification are added to the report, regardless of any limits you
specified in L<"--limit">.

For example, to report queries whose 95th percentile Query_time is at least 60
seconds and which are seen at least 5 times, use the following argument:

  --outliers Query_time:60:5

You can specify an --outliers option for each value in L<"--group-by">.

=item --output

type: string; default: report

How to format and print the query analysis results.  Accepted values are:

   VALUE          FORMAT
   =======        ==============================
   report         Standard query analysis report
   slowlog        MySQL slow log
   json           JSON, on array per query class
   json-anon      JSON without example queries
   secure-slowlog JSON without example queries

The entire C<report> output can be disabled by specifying C<--no-report>
(see L<"--[no]report">), and its sections can be disabled or rearranged
by specifying L<"--report-format">.

C<json> output was introduced in 2.2.1 and is still in development,
so the data structure may change in future versions.

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

=item --preserve-embedded-numbers

Preserve numbers in database/table names when fingerprinting queries.
The standar fingeprint method replaces numbers in db/tables names, making
a query like 'SELECT * FROM db1.table2' to be figerprinted as 'SELECT * FROM db?.table?'.
This option changes that behaviour and the fingerprint will become 
'SELECT * FROM db1.table2'.

=item --processlist

type: DSN

Poll this DSN's processlist for queries, with L<"--interval"> sleep between.

If the connection fails, pt-query-digest tries to reopen it once per second.

=item --progress

type: array; default: time,30

Print progress reports to STDERR.  The value is a comma-separated list with two
parts.  The first part can be percentage, time, or iterations; the second part
specifies how often an update should be printed, in percentage, seconds, or
number of iterations.

=item --read-timeout

type: time; default: 0

Wait this long for an event from the input; 0 to wait forever.

This option sets the maximum time to wait for an event from the input.  It
applies to all types of input except L<"--processlist">.  If an
event is not received after the specified time, the script stops reading the
input and prints its reports.  If L<"--iterations"> is 0 or greater than
1, the next iteration will begin, else the script will exit.

This option requires the Perl POSIX module.

=item --[no]report

default: yes

Print query analysis reports for each L<"--group-by"> attribute.  This is
the standard slow log analysis functionality.  See L<"OUTPUT"> for the
description of what this does and what the results look like.

If you don't need a report (for example, when using L<"--review"> or
L<"--history">), it is best to specify C<--no-report> because this allows
the tool to skip some expensive operations.

=item --report-all

Report all queries, even ones that have been reviewed.  This only affects
the C<report> L<"--output"> when using L<"--review">.  Otherwise, all
queries are always printed.

=item --report-format

type: Array; default: rusage,date,hostname,files,header,profile,query_report,prepared

Print these sections of the query analysis report.

  SECTION      PRINTS
  ============ ======================================================
  rusage       CPU times and memory usage reported by ps
  date         Current local date and time
  hostname     Hostname of machine on which pt-query-digest was run
  files        Input files read/parse
  header       Summary of the entire analysis run
  profile      Compact table of queries for an overview of the report
  query_report Detailed information about each unique query
  prepared     Prepared statements

The sections are printed in the order specified.  The rusage, date, files and
header sections are grouped together if specified together; other sections are
separated by blank lines.

See L<"OUTPUT"> for more information on the various parts of the query report.

=item --report-histogram

type: string; default: Query_time

Chart the distribution of this attribute's values.

The distribution chart is limited to time-based attributes, so charting
C<Rows_examined>, for example, will produce a useless chart.  Charts look
like:

  # Query_time distribution
  #   1us
  #  10us
  # 100us
  #   1ms
  #  10ms  ###########################
  # 100ms  ########################################################
  #    1s  ########
  #  10s+

See L<"OUTPUT"> for more information.

=item --resume

type: string

If specified, the tool writes the last file offset, if there is one,
to the given filename. When ran again with the same value for this option,
the tool reads the last file offset from the file, seeks to that position
in the log, and resumes parsing events from that point onward.

=item --review

type: DSN

Save query classes for later review, and don't report already reviewed classes.

=for comment ignore-pt-internal-value
MAGIC_default_review_table

The default table is C<percona_schema.query_review>.  Specify database
(D) and table (t) DSN options to override the default.  The database and
table are automatically created unless C<--no-create-review-table>
is specified (see L<"--[no]create-review-table">).

If the table was created manually, it must have at least the following columns.
You can add more columns for your own special purposes, but they won't be used
by pt-query-digest.

=for comment ignore-pt-internal-value
MAGIC_create_review_table:

  CREATE TABLE IF NOT EXISTS query_review (
     checksum     CHAR(32) NOT NULL PRIMARY KEY,
     fingerprint  TEXT NOT NULL,
     sample       TEXT NOT NULL,
     first_seen   DATETIME,
     last_seen    DATETIME,
     reviewed_by  VARCHAR(20),
     reviewed_on  DATETIME,
     comments     TEXT
  )

The columns are:

  COLUMN       MEANING
  ===========  ====================================================
  checksum     A 64-bit checksum of the query fingerprint
  fingerprint  The abstracted version of the query; its primary key
  sample       The query text of a sample of the class of queries
  first_seen   The smallest timestamp of this class of queries
  last_seen    The largest timestamp of this class of queries
  reviewed_by  Initially NULL; if set, query is skipped thereafter
  reviewed_on  Initially NULL; not assigned any special meaning
  comments     Initially NULL; not assigned any special meaning

Note that the C<fingerprint> column is the true primary key for a class of
queries.  The C<checksum> is just a cryptographic hash of this value, which
provides a shorter value that is very likely to also be unique.

After parsing and aggregating events, your table should contain a row for each
fingerprint.  This option depends on C<--group-by fingerprint> (which is the
default).  It will not work otherwise.

=item --run-time

type: time

How long to run for each L<"--iterations">.  The default is to run forever
(you can interrupt with CTRL-C).  Because L<"--iterations"> defaults to 1,
if you only specify L<"--run-time">, pt-query-digest runs for that amount of
time and then exits.  The two options are specified together to do
collect-and-report cycles.  For example, specifying L<"--iterations"> C<4>
L<"--run-time"> C<15m> with a continuous input (like STDIN or
L<"--processlist">) will cause pt-query-digest to run for 1 hour
(15 minutes x 4), reporting four times, once at each 15 minute interval.

=item --run-time-mode

type: string; default: clock

Set what the value of L<"--run-time"> operates on.  Following are the possible
values for this option:

=over

=item clock

L<"--run-time"> specifies an amount of real clock time during which the tool
should run for each L<"--iterations">.

=item event

L<"--run-time"> specifies an amount of log time.  Log time is determined by
timestamps in the log.  The first timestamp seen is remembered, and each
timestamp after that is compared to the first to determine how much log time
has passed.  For example, if the first timestamp seen is C<12:00:00> and the
next is C<12:01:30>, that is 1 minute and 30 seconds of log time.  The tool
will read events until the log time is greater than or equal to the specified
L<"--run-time"> value.

Since timestamps in logs are not always printed, or not always printed
frequently, this mode varies in accuracy.

=item interval

L<"--run-time"> specifies interval boundaries of log time into which events
are divided and reports are generated.  This mode is different from the
others because it doesn't specify how long to run.  The value of
L<"--run-time"> must be an interval that divides evenly into minutes, hours
or days.  For example, C<5m> divides evenly into hours (60/5=12, so 12
5 minutes intervals per hour) but C<7m> does not (60/7=8.6).

Specifying C<--run-time-mode interval --run-time 30m --iterations 0> is
similar to specifying C<--run-time-mode clock --run-time 30m --iterations 0>.
In the latter case, pt-query-digest will run forever, producing reports every
30 minutes, but this only works effectively with  continuous inputs like
STDIN and the processlist.  For fixed inputs, like log files, the former
example produces multiple reports by dividing the log into 30 minutes
intervals based on timestamps.

Intervals are calculated from the zeroth second/minute/hour in which a
timestamp occurs, not from whatever time it specifies.  For example,
with 30 minute intervals and a timestamp of C<12:10:30>, the interval
is I<not> C<12:10:30> to C<12:40:30>, it is C<12:00:00> to C<12:29:59>.
Or, with 1 hour intervals, it is C<12:00:00> to C<12:59:59>.
When a new timestamp exceeds the interval, a report is printed, and the
next interval is recalculated based on the new timestamp.

Since L<"--iterations"> is 1 by default, you probably want to specify
a new value else pt-query-digest will only get and report on the first
interval from the log since 1 interval = 1 iteration.  If you want to
get and report every interval in a log, specify L<"--iterations"> C<0>.

=back

=item --sample

type: int

Filter out all but the first N occurrences of each query.  The queries are
filtered on the first value in L<"--group-by">, so by default, this will filter
by query fingerprint.  For example, C<--sample 2> will permit two sample queries
for each fingerprint.  Useful in conjunction with C<--output slowlog> to print
the queries.  You probably want to set C<--no-report> to avoid the overhead of
aggregating and reporting if you're just using this to print out samples of
queries.  A complete example:

  pt-query-digest --sample 2 --no-report --output slowlog slow.log

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

=item --show-all

type: Hash

Show all values for these attributes.

By default pt-query-digest only shows as many of an attribute's value that
fit on a single line.  This option allows you to specify attributes for which
all values will be shown (line width is ignored).  This only works for
attributes with string values like user, host, db, etc.  Multiple attributes
can be specified, comma-separated.

=item --since

type: string

Parse only queries newer than this value (parse queries since this date).

This option allows you to ignore queries older than a certain value and parse
only those queries which are more recent than the value.  The value can be
several types:

  * Simple time value N with optional suffix: N[shmd], where
    s=seconds, h=hours, m=minutes, d=days (default s if no suffix
    given); this is like saying "since N[shmd] ago"
  * Full date with optional hours:minutes:seconds:
    YYYY-MM-DD [HH:MM:SS]
  * Short, MySQL-style date:
    YYMMDD [HH:MM:SS]
  * Any time expression evaluated by MySQL:
    CURRENT_DATE - INTERVAL 7 DAY

If you give a MySQL time expression, and you have not also specified a DSN
for L<"--explain">, L<"--processlist">, or L<"--review">, then you must specify
a DSN on the command line so that pt-query-digest can connect to MySQL to
evaluate the expression.

The MySQL time expression is wrapped inside a query like
"SELECT UNIX_TIMESTAMP(<expression>)", so be sure that the expression is
valid inside this query.  For example, do not use UNIX_TIMESTAMP() because
UNIX_TIMESTAMP(UNIX_TIMESTAMP()) returns 0.

Events are assumed to be in chronological: older events at the beginning of
the log and newer events at the end of the log.  L<"--since"> is strict: it
ignores all queries until one is found that is new enough.  Therefore, if
the query events are not consistently timestamped, some may be ignored which
are actually new enough.

See also L<"--until">.

=item --socket

short form: -S; type: string

Socket file to use for connection.

=item --timeline

Show a timeline of events.

This option makes pt-query-digest print another kind of report: a timeline of
the events.  Each query is still grouped and aggregate into classes according to
L<"--group-by">, but then they are printed in chronological order.  The timeline
report prints out the timestamp, interval, count and value of each classes.

If all you want is the timeline report, then specify C<--no-report> to
suppress the default query analysis report.  Otherwise, the timeline report
will be printed at the end before the response-time profile
(see L<"--report-format"> and L<"OUTPUT">).

For example, this:

  pt-query-digest /path/to/log --group-by distill --timeline

will print something like:

  # ########################################################
  # distill report
  # ########################################################
  # 2009-07-25 11:19:27 1+00:00:01   2 SELECT foo
  # 2009-07-27 11:19:30      00:01   2 SELECT bar
  # 2009-07-27 11:30:00 1+06:30:00   2 SELECT foo

=item --type

type: Array; default: slowlog

The type of input to parse.  The permitted types are

=over

=item binlog

Parse a binary log file that has first been converted to text using mysqlbinlog.

For example: 

   mysqlbinlog mysql-bin.000441 > mysql-bin.000441.txt

   pt-query-digest --type binlog mysql-bin.000441.txt

=item genlog

Parse a MySQL general log file.  General logs lack a lot of L<"ATTRIBUTES">,
notably C<Query_time>.  The default L<"--order-by"> for general logs
changes to C<Query_time:cnt>.

=item slowlog

Parse a log file in any variation of MySQL slow log format.

=item tcpdump

Inspect network packets and decode the MySQL client protocol, extracting queries
and responses from it.

pt-query-digest does not actually watch the network (i.e. it does NOT "sniff
packets").  Instead, it's just parsing the output of tcpdump.  You are
responsible for generating this output; pt-query-digest does not do it for you.
Then you send this to pt-query-digest as you would any log file: as files on the
command line or to STDIN.

The parser expects the input to be formatted with the following options: C<-x -n
-q -tttt>.  For example, if you want to capture output from your local machine,
you can do something like the following (the port must come last on FreeBSD):

  tcpdump -s 65535 -x -nn -q -tttt -i any -c 1000 port 3306 \
    > mysql.tcp.txt
  pt-query-digest --type tcpdump mysql.tcp.txt

The other tcpdump parameters, such as -s, -c, and -i, are up to you.  Just make
sure the output looks like this (there is a line break in the first line to
avoid man-page problems):

  2009-04-12 09:50:16.804849 IP 127.0.0.1.42167
         > 127.0.0.1.3306: tcp 37
      0x0000:  4508 0059 6eb2 4000 4006 cde2 7f00 0001
      0x0010:  ....

Remember tcpdump has a handy -c option to stop after it captures some number of
packets!  That's very useful for testing your tcpdump command.  Note that
tcpdump can't capture traffic on a Unix socket.  Read
L<http://bugs.mysql.com/bug.php?id=31577> if you're confused about this.

Devananda Van Der Veen explained on the MySQL Performance Blog how to capture
traffic without dropping packets on busy servers.  Dropped packets cause
pt-query-digest to miss the response to a request, then see the response to a
later request and assign the wrong execution time to the query.  You can change
the filter to something like the following to help capture a subset of the
queries.  (See L<http://www.mysqlperformanceblog.com/?p=6092> for details.)

  tcpdump -i any -s 65535 -x -n -q -tttt \
     'port 3306 and tcp[1] & 7 == 2 and tcp[3] & 7 == 2'

All MySQL servers running on port 3306 are automatically detected in the
tcpdump output.  Therefore, if the tcpdump out contains packets from
multiple servers on port 3306 (for example, 10.0.0.1:3306, 10.0.0.2:3306,
etc.), all packets/queries from all these servers will be analyzed
together as if they were one server.

If you're analyzing traffic for a MySQL server that is not running on port
3306, see L<"--watch-server">.

Also note that pt-query-digest may fail to report the database for queries
when parsing tcpdump output.  The database is discovered only in the initial
connect events for a new client or when <USE db> is executed.  If the tcpdump
output contains neither of these, then pt-query-digest cannot discover the
database.

Server-side prepared statements are supported.  SSL-encrypted traffic cannot be
inspected and decoded.

=item rawlog

Raw logs are not MySQL logs but simple text files with one SQL statement
per line, like:

  SELECT c FROM t WHERE id=1
  /* Hello, world! */ SELECT * FROM t2 LIMIT 1
  INSERT INTO t (a, b) VALUES ('foo', 'bar')
  INSERT INTO t SELECT * FROM monkeys

Since raw logs do not have any metrics, many options and features of
pt-query-digest do not work with them.

One use case for raw logs is ranking queries by count when the only
information available is a list of queries, from polling C<SHOW PROCESSLIST>
for example.

=back

=item --until

type: string

Parse only queries older than this value (parse queries until this date).

This option allows you to ignore queries newer than a certain value and parse
only those queries which are older than the value.  The value can be one of
the same types listed for L<"--since">.

Unlike L<"--since">, L<"--until"> is not strict: all queries are parsed until
one has a timestamp that is equal to or greater than L<"--until">.  Then
all subsequent queries are ignored.

=item --user

short form: -u; type: string

User for login if not current user.

=item --variations

type: Array

Report the number of variations in these attributes' values.

Variations show how many distinct values an attribute had within a class.
The usual value for this option is C<arg> which shows how many distinct queries
were in the class.  This can be useful to determine a query's cacheability.

Distinct values are determined by CRC32 checksums of the attributes' values.
These checksums are reported in the query report for attributes specified by
this option, like:

  # arg crc      109 (1/25%), 144 (1/25%)... 2 more

In that class there were 4 distinct queries.  The checksums of the first two
variations are shown, and each one occurred once (or, 25% of the time).

The counts of distinct variations is approximate because only 1,000 variations
are saved.  The mod (%) 1000 of the full CRC32 checksum is saved, so some
distinct checksums are treated as equal.

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

=item --[no]vertical-format

default: yes

Output a trailing "\G" in the reported SQL queries.

This makes the mysql client display the result using vertical format.
Non-native MySQL clients like phpMyAdmin do not support this.

=item --watch-server

type: string

This option tells pt-query-digest which server IP address and port (like
"10.0.0.1:3306") to watch when parsing tcpdump (for L<"--type"> tcpdump);
all other servers are ignored.  If you don't specify it,
pt-query-digest watches all servers by looking for any IP address using port
3306 or "mysql".  If you're watching a server with a non-standard port, this
won't work, so you must specify the IP address and port to watch.

If you want to watch a mix of servers, some running on standard port 3306
and some running on non-standard ports, you need to create separate
tcpdump outputs for the non-standard port servers and then specify this
option for each.  At present pt-query-digest cannot auto-detect servers on
port 3306 and also be told to watch a server on a non-standard port.

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

Default database to use when connecting to MySQL.

=item * F

dsn: mysql_read_default_file; copy: yes

Only read default options from the given file.

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

=item * t

The L<"--review"> or L<"--history"> table.

=item * u

dsn: user; copy: yes

User for login if not current user.

=back

=head1 ENVIRONMENT

The environment variable C<PTDEBUG> enables verbose debugging output to STDERR.
To enable debugging and capture all output to a file, run the tool like:

   PTDEBUG=1 pt-query-digest ... > FILE 2>&1

Be careful: debugging output is voluminous and can generate several megabytes
of output.

=head1 SYSTEM REQUIREMENTS

You need Perl, DBI, DBD::mysql, and some core packages that ought to be
installed in any reasonably new version of Perl.

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-query-digest>.

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

=head1 ATTRIBUTES REFERENCE

Events may have the following attributes.  If writing a L<"--filter">,
be sure to check that an attribute is defined in each event before
using it, else the filter code may crash the tool with a
"use of uninitialized value" error.

You can dump event attributes for any input like:

  $ pt-query-digest                  \
      slow.log                       \
      --filter 'print Dumper $event' \
      --no-report                    \
      --sample 1

That will produce a lot of output with "attribute => value" pairs like:

   $VAR1 = {
     Query_time => '0.033384',
     Rows_examined => '0',
     Rows_sent => '0',
     Thread_id => '10',
     Tmp_table => 'No',
     Tmp_table_on_disk => 'No',
     arg => 'SELECT col FROM tbl WHERE id=5',
     bytes => 103,
     cmd => 'Query',
     db => 'db1',
     fingerprint => 'select col from tbl where id=?',
     host => '',
     pos_in_log => 1334,
     ts => '071218 11:48:27',
     user => '[SQL_SLAVE]'
   };

=head2 COMMON

These attribute are common to all input L<"--type"> and L<"--processlist">,
except where noted.

=over

=item arg

The query text, or the command for admin commands like C<Ping>.

=item bytes

The byte length of the C<arg>.

=item cmd

"Query" or "Admin".

=item db

The current database.  The value comes from USE database statements.  
By default, C<Schema> is an alias which is automatically
changed to C<db>; see L<"--attribute-aliases">.

=item fingerprint 

An abstracted form of the query.  See L<"FINGERPRINTS">.

=item host

Client host which executed the query.

=item pos_in_log

The byte offset of the event in the log or tcpdump,
except for L<"--processlist">.

=item Query_time

The total time the query took, including lock time.

=item ts

The timestamp of when the query ended.

=back

=head2 SLOW, GENERAL, AND BINARY LOGS

Events have all available attributes from the log file.  Therefore, you only
need to look at the log file to see which events are available, but remember:
not all events have the same attributes.

Percona Server adds many attributes to the slow log; see
http://www.percona.com/docs/wiki/patches:slow_extended for more information.

=head2 TCPDUMP

These attributes are available when parsing L<"--type"> tcpdump.

=over

=item Error_no

The MySQL error number if the query caused an error.

=item ip

The client's IP address.  Certain log files may also contain this attribute.

=item No_good_index_used

Yes or No if no good index existed for the query (flag set by server).

=item No_index_used

Yes or No if the query did not use any index (flag set by server).

=item port

The client's port number.

=item Warning_count

The number of warnings, as otherwise shown by C<SHOW WARNINGS>.

=back

=head2 PROCESSLIST

If using L<"--processlist">, an C<id> attribute is available for
the process ID, in addition to the common attributes.

=head1 AUTHORS

Baron Schwartz, Daniel Nichter, and Brian Fraser

=head1 ABOUT PERCONA TOOLKIT

This tool is part of Percona Toolkit, a collection of advanced command-line
tools for MySQL developed by Percona.  Percona Toolkit was forked from two
projects in June, 2011: Maatkit and Aspersa.  Those projects were created by
Baron Schwartz and primarily developed by him and Daniel Nichter.  Visit
L<http://www.percona.com/software/> to learn about other free, open-source
software from Percona.

=head1 COPYRIGHT, LICENSE, AND WARRANTY

This program is copyright 2008-2018 Percona LLC and/or its affiliates.

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

pt-query-digest 3.3.0

=cut
