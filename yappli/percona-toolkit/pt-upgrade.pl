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
      Cxn
      Transformers
      Daemon
      Outfile
      Retry
      HTTP::Micro
      VersionCheck
      QueryRewriter
      VersionParser
      FileIterator
      QueryIterator
      EventExecutor
      UpgradeResults
      ResultWriter
      ResultIterator
      FakeSth
      SlowLogParser
      GeneralLogParser
      BinaryLogParser
      RawLogParser
      ProtocolParser
      TcpdumpParser
      MySQLProtocolParser
      Runtime
      Progress
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
# Outfile package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Outfile.pm
#   t/lib/Outfile.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Outfile;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my $self = {};
   return bless $self, $class;
}

sub write {
   my ( $self, $fh, $rows ) = @_;
   foreach my $row ( @$rows ) {
      print $fh escape($row), "\n"
         or die "Cannot write to outfile: $OS_ERROR\n";
   }
   return;
}

sub escape {
   my ( $row ) = @_;
   return join("\t", map {
      s/([\t\n\\])/\\$1/g if defined $_;  # Escape tabs etc
      defined $_ ? $_ : '\N';             # NULL = \N
   } @$row);
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
# End Outfile package
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
# QueryIterator package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/QueryIterator.pm
#   t/lib/QueryIterator.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package QueryIterator;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use POSIX qw(signal_h);
use Data::Dumper;

use Lmo;


has 'file_iter' => (
   is       => 'ro',
   isa      => 'CodeRef',
   required => 1,
);

has 'parser' => (
   is       => 'ro',
   isa      => 'CodeRef',
   required => 1,
);

has 'fingerprint' => (
   is       => 'ro',
   isa      => 'CodeRef',
   required => 1,
);

has 'oktorun' => (
   is       => 'ro',
   isa      => 'CodeRef',
   required => 1,
);


has 'filter' => (
   is       => 'ro',
   isa      => 'CodeRef',
   required => 0,
);

has 'read_only' => (
   is       => 'ro',
   isa      => 'Bool',
   required => 0,
   default  => 0,
);

has 'read_timeout' => (
   is       => 'ro',
   isa      => 'Int',
   required => 0,
   default  => 0,
);

has 'progress' => (
   is       => 'ro',
   isa      => 'Maybe[Str]',
   required => 0,
   default  => sub { return },
);


has '_progress' => (
   is       => 'rw',
   isa      => 'Maybe[Object]',
   required => 0,
   default  => sub { return },
);

has 'stats' => (
   is       => 'ro',
   isa      => 'HashRef',
   required => 0,
   default  => sub { return {} },
);

has '_fh' => (
   is       => 'rw',
   isa      => 'Maybe[FileHandle]',
   required => 0,
);

has '_file_name' => (
   is       => 'rw',
   isa      => 'Maybe[Str]',
   required => 0,
);

has '_file_size' => (
   is       => 'rw',
   isa      => 'Maybe[Int]',
   required => 0,
);

has '_offset' => (
   is       => 'rw',
   isa      => 'Maybe[Int]',
   required => 0,
);

has '_parser_args' => (
   is       => 'rw',
   isa      => 'HashRef',
   required => 0,
);

sub BUILDARGS {
   my $class = shift;
   my $args  = $class->SUPER::BUILDARGS(@_);

   my $filter_code;
   if ( my $filter = $args->{filter} ) {
      if ( -f $filter && -r $filter ) {
         PTDEBUG && _d('Reading file', $filter, 'for --filter code');
         open my $fh, "<", $filter or die "Cannot open $filter: $OS_ERROR";
         $filter = do { local $/ = undef; <$fh> };
         close $fh;
      }
      else {
         $filter = "( $filter )";  # issue 565
      }
      my $code = "sub {
         PTDEBUG && _d('callback: filter');
         my(\$event) = shift;
         $filter && return \$event;
      };";
      PTDEBUG && _d('--filter code:', $code);
      $filter_code = eval $code
         or die "Error compiling --filter code: $code\n$EVAL_ERROR";
   }
   else {
      $filter_code = sub { return 1 };
   }

   my $self = {
      %$args,
      filter => $filter_code,
   };

   return $self;
}

sub next {
   my ($self) = @_;

   if ( !$self->_fh ) {
      my ($fh, $file_name, $file_size) = $self->file_iter->();
      return unless $fh;

      PTDEBUG && _d('Reading', $file_name);
      $self->_fh($fh);
      $self->_file_name($file_name);
      $self->_file_size($file_size);

      my $parser_args = {};

      if ( my $read_timeout = $self->read_timeout ) {
         $parser_args->{next_event}
            = sub { return _read_timeout($fh, $read_timeout); };
      }
      else {
         $parser_args->{next_event} = sub { return <$fh>; };
      }

      $parser_args->{tell} = sub {
         my $offset = tell $fh;  # update global $offset
         $self->_offset($offset);
         return $offset;  # legacy: return global $offset
      };

      my $_progress;
      if ( my $spec = $self->progress ) {
         $_progress = new Progress(
            jobsize => $file_size,
            spec    => $spec,
            name    => $file_name,
         );
      }
      $self->_progress($_progress);

      $self->_parser_args($parser_args);
   }

   EVENT:
   while (
      $self->oktorun
      &&  (my $event = $self->parser->(%{ $self->_parser_args }) )
   ) {
      $self->stats->{queries_read}++;

      if ( my $pr = $self->_progress ) {
         $pr->update($self->_parser_args->{tell});
      }

      if ( ($event->{cmd} || '') ne 'Query' ) {
         PTDEBUG && _d('Skipping non-Query cmd');
         $self->stats->{not_query}++;
         next EVENT;
      }

      if ( !$event->{arg} ) {
         PTDEBUG && _d('Skipping empty arg');
         $self->stats->{empty_query}++;
         next EVENT;
      }

      if ( !$self->filter->($event) ) {
         $self->stats->{queries_filtered}++;
         next EVENT;
      }

      if ( $self->read_only ) {
         if ( $event->{arg} !~ m{^(?:/\*[^!].*?\*/)?\s*(?:SELECT|SET)}i ) {
            PTDEBUG && _d('Skipping non-SELECT query');
            $self->stats->{not_select}++;
            next EVENT;
         }
      }

      $event->{fingerprint} = $self->fingerprint->($event->{arg});

      return $event;
   }

   PTDEBUG && _d('Done reading', $self->_file_name);
   close $self->_fh if $self->_fh;
   $self->_fh(undef);
   $self->_file_name(undef);
   $self->_file_size(undef);

   return;
}

sub _read_timeout {
   my ( $fh, $t ) = @_;
   return unless $fh;
   $t ||= 0;  # will reset alarm and cause read to wait forever

   my $mask   = POSIX::SigSet->new(&POSIX::SIGALRM);
   my $action = POSIX::SigAction->new(
      sub {
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
      $res = undef;  # res is a blank string after a timeout
   }
   return $res;
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
# End QueryIterator package
# ###########################################################################

# ###########################################################################
# EventExecutor package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/EventExecutor.pm
#   t/lib/EventExecutor.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package EventExecutor;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Time::HiRes qw(time);
use Data::Dumper;

use Lmo;

has 'default_database' => (
   is       => 'rw',
   isa      => 'Maybe[Str]',
   required => 0,
);


has 'stats' => (
   is       => 'ro',
   isa      => 'HashRef',
   required => 0,
   default  => sub { return {} },
);

sub exec_event {
   my ($self, %args) = @_;
   my @required_args = qw(host event);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $host  = $args{host};
   my $event = $args{event};

   my $results = {
      query_time => undef,
      sth        => undef,
      warnings   => undef,
      error      => undef,
   };

   eval {
      my $db = $event->{db} || $event->{Schema} || $self->default_database;
      if ( $db && (!$host->{current_db} || $host->{current_db} ne $db) ) {
         PTDEBUG && _d('New current db:', $db);
         $host->dbh->do("USE `$db`");
         $host->{current_db} = $db;
      }
      my $sth = $host->dbh->prepare($event->{arg});
      my $t0 = time;
      $sth->execute();
      my $t1 = time - $t0;
      $results->{query_time} = sprintf('%.6f', $t1);
      $results->{sth}        = $sth;
      $results->{warnings}   = $self->get_warnings(dbh => $host->dbh);
   };
   if ( my $e = $EVAL_ERROR ) {
      PTDEBUG && _d($e);
      chomp($e);
      $e =~ s/ at \S+ line \d+, \S+ line \d+\.$//;
      $results->{error} = $e;
   }
   PTDEBUG && _d('Result on', $host->name, Dumper($results));
   return $results;
}

sub get_warnings {
   my ($self, %args) = @_;
   my @required_args = qw(dbh);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $dbh = $args{dbh};
   my $warnings = $dbh->selectall_hashref('SHOW WARNINGS', 'code');
   return $warnings;
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
# End EventExecutor package
# ###########################################################################

# ###########################################################################
# UpgradeResults package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/UpgradeResults.pm
#   t/lib/UpgradeResults.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package UpgradeResults;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
use Digest::MD5 qw(md5_hex);

use Lmo;

has 'max_class_size' => (
    is       => 'ro',
    isa      => 'Int',
    required => 1,
);

has 'max_examples' => (
    is       => 'ro',
    isa      => 'Int',
    required => 1,
);

has 'classes' => (
    is       => 'rw',
    isa      => 'HashRef',
    required => 0,
    default  => sub { return {} },
);

sub save_diffs {
   my ($self, %args) = @_;

   my $event            = $args{event};
   my $query_time_diffs = $args{query_time_diffs};
   my $warning_diffs    = $args{warning_diffs};
   my $row_diffs        = $args{row_diffs};

   my $class = $self->class(event => $event);

   if ( my $query = $self->_can_save(event => $event, class => $class) ) {
      if ( $query_time_diffs
           && scalar @{$class->{query_time_diffs}} < $self->max_examples ) {
         push @{$class->{query_time_diffs}}, [
            $query,
            $query_time_diffs,
         ];
      }

      if ( $warning_diffs && @$warning_diffs
           && scalar @{$class->{warning_diffs}} < $self->max_examples ) {
         push @{$class->{warning_diffs}}, [
            $query,
            $warning_diffs,
         ];
      }

      if ( $row_diffs && @$row_diffs
           && scalar @{$class->{row_diffs}} < $self->max_examples ) {
         push @{$class->{row_diffs}}, [
            $query,
            $row_diffs,
         ];
      }
   }

   $self->report_if_ready(class => $class);

   return;
}

sub save_error {
   my ($self, %args) = @_;

   my $event  = $args{event};
   my $error1 = $args{error1};
   my $error2 = $args{error2};

   my $class = $self->class(event => $event);

   if ( my $query = $self->_can_save(event => $event, class => $class) ) {
      if ( scalar @{$class->{errors}} < $self->max_examples ) {
         push @{$class->{errors}}, [
            $query,
            $error1,
            $error2,
         ];
      }
   }

   $self->report_if_ready(class => $class);

   return;
}

sub save_failed_query {
   my ($self, %args) = @_;

   my $event  = $args{event};
   my $error1 = $args{error1};
   my $error2 = $args{error2};

   my $class = $self->class(event => $event);

   if ( my $query = $self->_can_save(event => $event, class => $class) ) {
      if ( scalar @{$class->{failures}} < $self->max_examples ) {
         push @{$class->{failures}}, [
            $query,
            $error1,
            $error2,
         ];
      }
   }

   $self->report_if_ready(class => $class);

   return;
}

sub _can_save {
   my ($self, %args) = @_;
   my $event = $args{event};
   my $class = $args{class};
   my $query = $event->{arg};
   if ( $class->{reported} ) {
      PTDEBUG && _d('Class already reported');
      return;
   }
   $class->{total_queries}++;
   if ( exists $class->{unique_queries}->{$query}
        || scalar keys %{$class->{unique_queries}} < $self->max_class_size ) {
      $class->{unique_queries}->{$query}++;
      return $query;
   }
   PTDEBUG && _d('Too many queries in class, discarding', $query);
   $class->{discarded}++;
   return;
}

sub class {
   my ($self, %args) = @_;
   my $event = $args{event};

   my $id      = uc(substr(md5_hex($event->{fingerprint}), -16));
   my $classes = $self->classes;
   my $class   = $classes->{$id};
   if ( !$class ) {
      $class = $self->_new_class(
         id    => $id,
         event => $event,
      );
      $classes->{$id} = $class;
   }
   return $class;
}

sub _new_class {
   my ($self, %args) = @_;
   my $id    = $args{id};
   my $event = $args{event};
   PTDEBUG && _d('New query class:', $id, $event->{fingerprint});
   my $class = {
      id               => $id,
      fingerprint      => $event->{fingerprint},
      discarded        => 0,
      unique_queries   => {
         $event->{arg} => 0,
      },
      failures         => [],  # error on both hosts
      errors           => [],  # error on one host
      query_time_diffs => [],
      warning_diffs    => [],
      row_diffs        => [],
   };
   return $class;
}

sub report_unreported_classes {
   my ($self) = @_;
   my $success = 1;
   my $classes = $self->classes;
   foreach my $id ( sort keys %$classes ) {
      eval {
         my $class = $classes->{$id};
         my $reason;
         if ( !scalar @{$class->{failures}} ) {
            $reason = 'it has diffs';
         }
         elsif (    scalar @{$class->{errors}}
                 || scalar @{$class->{query_time_diffs}}
                 || scalar @{$class->{warning_diffs}}
                 || scalar @{$class->{row_diffs}} ) {
            $reason = 'it has SQL errors and diffs';
         }
         else {
            $reason = 'it has SQL errors'
         }
         $self->report_class(
            class   => $class,
            reasons => ["$reason, but hasn't been reported yet"],
         );
         $class->{reported} = 1; 
      };
      if ( $EVAL_ERROR ) {
         $success = 1;
         warn Dumper($classes->{$id});
         warn "Error reporting query class $id: $EVAL_ERROR";
      }
   }
   return $success;
}

sub report_if_ready {
   my ($self, %args) = @_;
   my $class = $args{class};
   my $max_examples   = $self->max_examples;
   my $max_class_size = $self->max_class_size;
   my @report_reasons;

   if ( scalar keys %{$class->{unique_queries}} >= $max_class_size ) {
      push @report_reasons, "it's full (--max-class-size)";
   }

   if ( scalar @{$class->{query_time_diffs}} >= $max_examples ) {
      push @report_reasons, "there are $max_examples query diffs";
   }

   if ( scalar @{$class->{warning_diffs}} >= $max_examples ) {
      push @report_reasons, "there are $max_examples warning diffs";
   }

   if ( scalar @{$class->{row_diffs}} >= $max_examples ) {
      push @report_reasons, "there are $max_examples row diffs";
   }

   if ( scalar @{$class->{errors}} >= $max_examples ) {
      push @report_reasons, "there are $max_examples query errors";
   }

   if ( scalar @{$class->{failures}} >= $max_examples ) {
      push @report_reasons, "there are $max_examples failed queries";
   }

   if ( scalar @report_reasons ) {
      PTDEBUG && _d('Reporting class because', @report_reasons);
      $self->report_class(
         class   => $class,
         reasons => \@report_reasons,
      );
      $class->{reported} = 1; 
   }

   return;
}

sub report_class {
   my ($self, %args) = @_;
   my $class   = $args{class};
   my $reasons = $args{reasons};

   if ( $class->{reported} ) {
      PTDEBUG && _d('Class already reported');
      return;
   }

   PTDEBUG && _d('Reporting class', $class->{id}, $class->{fingerprint});

   $self->_print_class_header(
      class   => $class,
      reasons => $reasons,
   );

   if ( scalar @{$class->{failures}} ) {
      $self->_print_failures(
         failures => $class->{failures},
      );
   }

   if ( scalar @{$class->{errors}} ) {
      $self->_print_errors(
         errors => $class->{errors},
      );
   }

   if ( scalar @{$class->{query_time_diffs}} ) {
      $self->_print_diffs(
         diffs     => $class->{query_time_diffs},
         name      => 'Query time',
         formatter => \&_format_query_times,
      );
   }

   if ( scalar @{$class->{warning_diffs}} ) {
      $self->_print_diffs(
         diffs     => $class->{warning_diffs},
         name      => 'Warning',
         formatter => \&_format_warnings,
      );
   }

   if ( scalar @{$class->{row_diffs}} ) {
      $self->_print_diffs(
         diffs     => $class->{row_diffs},
         name      => 'Row',
         formatter => \&_format_rows,
      );
   }

   return;
}

my $class_header_format = <<'EOF';

%s
%s
%s

Reporting class because %s.

Total queries      %s
Unique queries     %s
Discarded queries  %s

%s
EOF

sub _print_class_header {
   my ($self, %args) = @_;
   my $class   = $args{class};
   my @reasons = @{ $args{reasons} };

   my $unique_queries = do {
      my $i = 0;
      map { $i += $_ } values %{$class->{unique_queries}};
      $i;
   };
   PTDEBUG && _d('Unique queries:', $unique_queries);

   my $reasons;
   if ( scalar @reasons > 1 ) {
      $reasons = join(', ', @reasons[0..($#reasons - 1)])
               . ', and ' . $reasons[-1];
   }
   else {
      $reasons = $reasons[0];
   }
   PTDEBUG && _d('Reasons:', $reasons);

   printf $class_header_format,
      ('#' x 72),
      ('# Query class ' . ($class->{id} || '?')),
      ('#' x 72),
      ($reasons                || '?'),
      (defined $class->{total_queries} ? $class->{total_queries} : '?'),
      (defined $unique_queries         ? $unique_queries         : '?'),
      (defined $class->{discarded}     ? $class->{discarded}     : '?'),
      ($class->{fingerprint}   || '?');

   return;
}

sub _print_diff_header {
   my ($self, %args) = @_;
   my $name  = $args{name}  || '?';
   my $count = $args{count} || '?';
   print "\n##\n## $name diffs: $count\n##\n";
   return;
}

sub _print_failures {
   my ($self, %args) = @_;
   my $failures = $args{failures};

   my $n_failures = scalar @$failures;

   print "\n##\n## SQL errors: $n_failures\n##\n";

   my $failno = 1;
   foreach my $failure ( @$failures ) {
      print "\n-- $failno.\n";
      if ( ($failure->[1] || '') eq ($failure->[2] || '') ) {
         print "\nOn both hosts:\n\n" . ($failure->[1] || '') . "\n";
      }
      else {
         printf "\n%s\n\nvs.\n\n%s\n",
            ($failure->[1] || ''),
            ($failure->[2] || '');
      }
      print "\n" . ($failure->[0] || '?') . "\n";
      $failno++;
   }

   return;
}

sub _print_errors {
   my ($self, %args) = @_;
   my $errors = $args{errors};

   $self->_print_diff_header(
      name  => 'Query errors',
      count => scalar @$errors,
   );

   my $fmt = "\n%s\n\nvs.\n\n%s\n";

   my $errorno = 1;
   foreach my $error ( @$errors ) {
      print "\n-- $errorno.\n";
      printf $fmt,
         ($error->[1] || 'No error'),
         ($error->[2] || 'No error');
      print "\n" . ($error->[0] || '?') . "\n";
      $errorno++;
   }

   return;
}

sub _print_diffs {
   my ($self, %args) = @_;
   my $diffs     = $args{diffs};
   my $name      = $args{name};
   my $formatter = $args{formatter};

   $self->_print_diff_header(
      name  => $name,
      count => scalar @$diffs,
   );

   my $diffno = 1;
   foreach my $diff ( @$diffs ) {
      my $query     = $diff->[0];
      my $diff_vals = $diff->[1];
      print "\n-- $diffno.\n";
      my $formatted_diff_vals = $formatter->($diff_vals);
      print $formatted_diff_vals || '?';
      print "\n" . ($query || '?') . "\n";
      $diffno++;
   }

   return;
}

my $warning_format = <<'EOL';
   Code: %s
  Level: %s
Message: %s
EOL

sub _format_warnings {
   my ($warnings) = @_;
   return unless $warnings && @$warnings;
   my @warnings;
   foreach my $warn ( @$warnings ) {
      my $code  = $warn->[0];
      my $warn1 = $warn->[1];
      my $warn2 = $warn->[2];
      my $host1_warn
         = $warn1 ? sprintf $warning_format, 
                       ($warn1->{Code}    || $warn1->{code}    || '?'),
                       ($warn1->{Level}   || $warn1->{level}   || '?'),
                       ($warn1->{Message} || $warn1->{message} || '?')
         :          "No warning $code\n";
      my $host2_warn
         = $warn2 ? sprintf $warning_format, 
                       ($warn2->{Code}    || $warn2->{code}    || '?'),
                       ($warn2->{Level}   || $warn2->{level}   || '?'),
                       ($warn2->{Message} || $warn2->{message} || '?')
         :          "No warning $code\n";

      my $warning = sprintf "\n%s\nvs.\n\n%s", $host1_warn, $host2_warn;
      push @warnings, $warning;
   }
   return join("\n\n", @warnings);
}

sub _format_rows {
   my ($rows) = @_;
   return unless $rows && @$rows;
   my @diffs;
   foreach my $row ( @$rows ) {
      if ( !defined $row->[1] || !defined $row->[2] ) {
         my $n_missing_rows = $row->[0];
         my $missing_rows   = $row->[1] || $row->[2];
         my $dir            = !defined $row->[1] ? '>' : '<';
         my $diff
            = '@ first ' . scalar @$missing_rows
            . ' of ' . ($n_missing_rows || '?') . " missing rows\n";
         foreach my $row ( @$missing_rows ) {
            $diff .= "$dir "
                   . join(',', map {defined $_ ? $_ : 'NULL'} @$row) . "\n";
         }
         push @diffs, $diff;
      }
      else {
         my $rowno = $row->[0];
         my $cols1 = $row->[1];
         my $cols2 = $row->[2];
         my $diff
            = "@ row " . ($rowno || '?') . "\n"
            . '< ' . join(',', map {defined $_ ? $_ : 'NULL'} @$cols1) . "\n"
            . '> ' . join(',', map {defined $_ ? $_ : 'NULL'} @$cols2) . "\n";
         push @diffs, $diff;
      }
   }
   return "\n" . join("\n", @diffs);
}

sub _format_query_times {
   my ($query_times) = @_;
   return unless $query_times;
   my $fmt = "\n%s vs. %s seconds (%sx increase)\n";
   my $diff = sprintf $fmt,
      ($query_times->[0] || '?'),
      ($query_times->[1] || '?'),
      ($query_times->[2] || '?');
   return $diff;
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
# End UpgradeResults package
# ###########################################################################

# ###########################################################################
# ResultWriter package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/ResultWriter.pm
#   t/lib/ResultWriter.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package ResultWriter;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;

use Lmo;

has 'dir' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has 'pretty' => (
    is       => 'ro',
    isa      => 'Bool',
    required => 0,
    default  => 0,
);

has 'default_database' => (
   is       => 'rw',
   isa      => 'Maybe[Str]',
   required => 0,
);

has 'current_database' => (
   is       => 'rw',
   isa      => 'Maybe[Str]',
   required => 0,
);

has '_query_fh' => (
    is       => 'rw',
    isa      => 'Maybe[FileHandle]',
    required => 0,
);

has '_results_fh' => (
    is       => 'rw',
    isa      => 'Maybe[FileHandle]',
    required => 0,
);

has '_rows_fh' => (
    is       => 'rw',
    isa      => 'Maybe[FileHandle]',
    required => 0,
);

sub BUILDARGS {
   my $class = shift;
   my $args  = $class->SUPER::BUILDARGS(@_);

   my $dir = $args->{dir};

   my $query_file = "$dir/query";
   open my $_query_fh, '>', $query_file
      or die "Cannot open $query_file for writing: $OS_ERROR";

   my $results_file = "$dir/results";
   open my $_results_fh, '>', $results_file
      or die "Cannot open $results_file for writing: $OS_ERROR";

   my $rows_file = "$dir/rows";
   open my $_rows_fh, '>', $rows_file
      or die "Cannot open $rows_file for writing: $OS_ERROR";

   my $self = {
      %$args,
      _query_fh   => $_query_fh,
      _results_fh => $_results_fh,
      _rows_fh    => $_rows_fh,
   };

   return $self;
}


sub save {
   my ($self, %args) = @_;

   my $host    = $args{host};
   my $event   = $args{event};
   my $results = $args{results};

   my $current_db = $self->current_database;
   my $db = $event->{db} || $event->{Schema} || $self->default_database;
   if ( $db && (!$current_db || $current_db ne $db) ) {
      PTDEBUG && _d('New current db:', $db);
      print { $self->_query_fh } "use `$db`;\n";
      $self->current_database($db);
   }
   print { $self->_query_fh } $event->{arg}, "\n##\n";

   if ( my $error = $results->{error} ) {
      print { $self->_results_fh }
         $self->dumper({ error => $error}, 'results'), "\n##\n";

      print { $self->_rows_fh } "\n##\n";
   }
   else {
      my $rows;
      if ( my $sth = $results->{sth} ) {
         # Only fetch rows of select statements
         # *except* when they are directed INTO 
         # a file or a variable. (issue lp:1421781)
         if ( $event->{arg} =~ m/(?:^\s*SELECT|(?:\*\/\s*SELECT))/i 
            &&  $event->{arg} !~ /INTO\s*(?:OUTFILE|DUMPFILE|@)/i ) {
            $rows = $sth->fetchall_arrayref();
         }
         eval {
            $sth->finish;
         };
         if ( $EVAL_ERROR ) {
            PTDEBUG && _d($EVAL_ERROR);
         }
      }
      print { $self->_rows_fh }
         ($rows ? $self->dumper($rows, 'rows') : ''), "\n##\n";

      delete $results->{error};
      delete $results->{sth};
      print { $self->_results_fh } $self->dumper($results, 'results'), "\n##\n";
   }

   return;
}

sub dumper {
   my ($self, $data, $name) = @_;
   if ( $self->pretty ) {
      local $Data::Dumper::Indent    = 1;
      local $Data::Dumper::Sortkeys  = 1;
      local $Data::Dumper::Quotekeys = 0;
      return Data::Dumper->Dump([$data], [$name]);
   }
   else {
      local $Data::Dumper::Indent    = 0;
      local $Data::Dumper::Sortkeys  = 0;
      local $Data::Dumper::Quotekeys = 0;
      return Data::Dumper->Dump([$data], [$name]);
   }
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
# End ResultWriter package
# ###########################################################################

# ###########################################################################
# ResultIterator package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/ResultIterator.pm
#   t/lib/ResultIterator.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package ResultIterator;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;

use Lmo;

has 'dir' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has 'progress' => (
   is       => 'ro',
   isa      => 'Maybe[Str]',
   required => 0,
   default  => sub { return },
);

has '_progress' => (
   is       => 'rw',
   isa      => 'Maybe[Object]',
   required => 0,
   default  => sub { return },
);

has '_query_fh' => (
    is       => 'rw',
    isa      => 'Maybe[FileHandle]',
    required => 0,
);

has '_results_fh' => (
    is       => 'rw',
    isa      => 'Maybe[FileHandle]',
    required => 0,
);

has '_rows_fh' => (
    is       => 'rw',
    isa      => 'Maybe[FileHandle]',
    required => 0,
);

sub BUILDARGS {
   my $class = shift;
   my $args  = $class->SUPER::BUILDARGS(@_);

   my $dir = $args->{dir};
   die "$dir does not exist\n" unless -d $dir;

   my $query_file = "$dir/query";
   PTDEBUG && _d('Query file:', $query_file);
   open my $_query_fh, '<', $query_file
      or die "Cannot open $query_file for writing: $OS_ERROR";

   my $results_file = "$dir/results";
   PTDEBUG && _d('Meta file:', $results_file);
   open my $_results_fh, '<', $results_file
      or die "Cannot open $results_file for writing: $OS_ERROR";

   my $rows_file = "$dir/rows";
   PTDEBUG && _d('Results file:', $rows_file);
   open my $_rows_fh, '<', $rows_file
      or die "Cannot open $rows_file for writing: $OS_ERROR";

   my $_progress;
   if ( my $spec = $args->{progress} ) {
      $_progress = new Progress(
         jobsize => -s $query_file,
         spec    => $spec,
         name    => $query_file,
      );
   }

   my $self = {
      %$args,
      _query_fh   => $_query_fh,
      _results_fh => $_results_fh,
      _rows_fh    => $_rows_fh,
      _progress   => $_progress,
   };

   return $self;
}

sub next {
   my ($self, %args) = @_;

   local $INPUT_RECORD_SEPARATOR = "\n##\n";

   my $_query_fh   = $self->_query_fh;
   my $_results_fh = $self->_results_fh;
   my $_rows_fh    = $self->_rows_fh;

   my $query   = <$_query_fh>;
   my $results = <$_results_fh>;
   my $rows    = <$_rows_fh>;

   if ( !$query ) {
      PTDEBUG && _d('No more results');
      return;
   }

   chomp($query);

   if ( $results ) {
      chomp($results);
      eval $results;
   }

   if ( $rows ) {
      chomp($rows);
      eval $rows;
   }

   $query =~ s/^use ([^;]+);\n//;

   my $db = $1;
   if ( $db ) {
      $db =~ s/^`//;
      $db =~ s/`$//;
      $results->{db} = $db;
   }

   $results->{query} = $query;
   $results->{rows}  = $rows;
      
   if ( my $pr = $self->_progress ) {
      $pr->update(sub { tell $_query_fh });
   }

   PTDEBUG && _d('Results:', Dumper($results));
   return $results;
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
# End ResultIterator package
# ###########################################################################

# ###########################################################################
# FakeSth package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/FakeSth.pm
#   t/lib/FakeSth.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package FakeSth;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, $rows ) = @_;
   my $n_rows = $rows && ref $rows eq 'ARRAY' ? scalar @$rows : 0;
   my $self = {
      rows   => $rows,
      n_rows => $n_rows,
   };
   return bless $self, $class;
}

sub fetchall_arrayref {
   my ( $self ) = @_;
   return $self->{rows};
}

sub finish {
   return;
}

1;
}
# ###########################################################################
# End FakeSth package
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

      $packet->{data} = $packet->{mysql_hdr} . $packet->{data} if $packet->{mysql_hdr};
      return 0 unless $self->uncompress_packet($packet, $session);
      remove_mysql_header($packet) if $packet->{mysql_hdr};
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
# This is a combination of modules and programs in one -- a runnable module.
# http://www.perl.com/pub/a/2006/07/13/lightning-articles.html?page=last
# Or, look it up in the Camel book on pages 642 and 643 in the 3rd edition.
#
# Check at the end of this package for the call to main() which actually runs
# the program.
# ###########################################################################
package pt_upgrade;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);

use Time::HiRes qw(time);
use List::Util qw(min);
use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

use Percona::Toolkit;
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use sigtrap 'handler', \&sig_int, 'normal-signals';

# Global variables.  Only really essential variables should be here.
my $oktorun     = 1;
my $exit_status = 0;
my $stats       = {};
         
my %modules_for_log_type = (
   slowlog => ['SlowLogParser'],
   binlog  => ['BinaryLogParser'],
   genlog  => ['GeneralLogParser'],
   tcpdump => ['TcpdumpParser','MySQLProtocolParser'],
   rawlog  => ['RawLogParser'],
);

sub main {
   local @ARGV = @_;  # set global ARGV for this package

   # Reset global vars, else tests will fail.
   $oktorun     = 1;
   $exit_status = 0;
   $stats       = {
      queries_read        => 0,
      queries_filtered    => 0,
      queries_with_diffs  => 0,
      queries_no_diffs    => 0,
      queries_with_errors => 0,
      failed_queries      => 0,
      not_select          => 0,
   };

   # ##########################################################################
   # Get configuration information.
   # ##########################################################################
   my $o  = new OptionParser();
   $o->get_specs();
   $o->get_opts();

   my $dp = $o->DSNParser();
   $dp->prop('set-vars', $o->set_vars());

   my @dsns;
   my @dirs;
   my @logs;
   my $report = $o->get('report');

   foreach my $arg ( @ARGV ) {
      if ( -f $arg ) {
         PTDEBUG && _d($arg, 'is a file');
         push @logs, $arg;
      }
      elsif ( -d $arg ) {
         PTDEBUG && _d($arg, 'is a dir');
         push @dirs, $arg;
      }
      else {
         PTDEBUG && _d($arg, 'is a DSN');
         push @dsns, $arg;
      }
   }

   if ( !$o->get('help') ) {
      if ( !@dsns ) {
         $o->save_error('No DSNs were specified.');
      }
      elsif ( @dsns > 2 ) {
         $o->save_error('Only one or two DSNs can be specified; got '
             . scalar @dsns . ': ' . join(', ', @dsns));
      }
      elsif ( my $dir = $o->get('save-results') ) {
         # 1 DSN, --save-results, and LOGS
         if ( @dsns > 1 ) {
            $o->save_error('Only one DSN can be specified with --save-results; '
               . 'got ' . scalar @dsns . ': ' . join(', ', @dsns));
         }
         if ( !@logs ) {
            $o->save_error('No log files specified; at least one is required.');
         }
         if ( @dirs ) {
            $o->save_error('No other directories can be specified with '
               . '--save-results; got ' . scalar @dirs . ': '
               . join(', ', @dirs));
         }
         if ( ! -d $dir ) {
            $o->save_error("$dir is not a directory.");
         }
      }
      elsif ( @dirs ) {
         # 1 DIR, and 1 DSN
         if ( @dirs > 1 ) {
            $o->save_error('Only one results directory can be specified; got '
               . scalar @dirs . ': ' . join(', ', @dirs));
         }
         if ( @dsns > 1 ) {
            $o->save_error('Only one DSN can be specified with a results '
               . 'directory; got ' . scalar @dsns . ': ' . join(', ', @dsns));
         }
         if ( @logs ) {
            $o->save_error('Log files cannot be specified with a results '
               . 'directory; got ' . scalar @logs . ': ' . join(', ', @logs));
         }
      }
      elsif ( !@logs ) {
         # 2 DSN and LOGS
         $o->save_error('No log files specified; at least one is required.');
      }
      elsif ( @dsns < 2 ) {
         # 1 DSN, LOGS, but no --save-results a 2nd DSN
         $o->save_error('A DSN and at least one log file was specified, '
            . 'but a second DSN or --save-results must also be specified.');
      }

      foreach my $val ( keys %$report ) {
         if ( $val !~ m/^(?:hosts|logs|queries|stats)$/ ) {
            $o->save_error("Invalid --report value: $val");
         }
      }

      if ( my $spec = $o->get('progress') ) {
         eval { Progress->validate_spec($spec) };
         if ( $EVAL_ERROR ) {
            chomp $EVAL_ERROR;
            $o->save_error("--progress $EVAL_ERROR");
         }
      }
   }

   $o->usage_or_errors();

   # ########################################################################
   # Get results dir and DSN strings from whatever we just parsed.
   # ########################################################################
   my $results_dir;
   my $host1_dsn_string;
   my $host2_dsn_string;
   if ( $o->get('save-results')) {
      $results_dir = $o->get('save-results');
      $host1_dsn_string = shift @dsns;
   }
   elsif ( @dirs ) {
      $results_dir = shift @dirs;
      $host2_dsn_string = shift @dsns;
   }
   else {
      $host1_dsn_string = shift @dsns;
      $host2_dsn_string = shift @dsns;
   }

   # ########################################################################
   # Connect to the hosts.
   # ########################################################################
   my $host1;
   my $host2;

   my $set_on_connect = sub {
      my ($dbh) = @_;
      if ( $o->get('disable-query-cache') ) {
         disable_query_cache($dbh);
      }
      return;
   };

   my $make_cxn = sub {
      my (%args) = @_;
      my $cxn = new Cxn(
         %args,
         DSNParser    => $dp,
         OptionParser => $o,
         set          => $set_on_connect,
      );
      eval { $cxn->connect() };  # connect or die trying
      if ( $EVAL_ERROR ) {
         die $EVAL_ERROR;
      }
      return $cxn;
   };

   if ( $host1_dsn_string ) {
      $host1 = $make_cxn->(
         dsn_string => $host1_dsn_string,
      );
   }
   if ( $host2_dsn_string ) {
      $host2 = $make_cxn->(
         dsn_string => $host2_dsn_string,
         prev_dsn   => $host1 ? $host1->dsn : undef,
      );
   }

   # ########################################################################
   # Do the version-check
   # ########################################################################
   if ( $o->get('version-check') && (!$o->has('quiet') || !$o->get('quiet')) ) {
      VersionCheck::version_check(
         force     => $o->got('version-check'),
         instances => [
            ($host1 ? { dbh => $host1->dbh, dsn => $host1->dsn } : ()),
            ($host2 ? { dbh => $host2->dbh, dsn => $host2->dsn } : ()),
         ],
      );
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
   # Check and maybe create the --upgrade-table.
   # ########################################################################
   if ( $host1 ) {
      check_upgrade_table(
         host          => $host1,
         upgrade_table => $o->get('upgrade-table'),
         OptionParser  => $o,
      );
   }

   if ( $host2 ) {
      check_upgrade_table(
         host          => $host2,
         upgrade_table => $o->get('upgrade-table'),
         OptionParser  => $o,
      );
   }

   # ######################################################################## 
   # Preprocess the log files.
   # ######################################################################## 
   my $parser = make_parser(
      type         => $o->get('type'),
      watch_server => $o->get('watch-server'),
   );
   if ( $report->{logs} ) {
      report_logs(
         logs        => \@logs,
         results_dir => $results_dir,
      );
   }

   # ########################################################################
   # Execute and compare the queries.
   # ########################################################################
   if ( $report->{hosts} ) {
      report_hosts(
         host1       => $host1,
         host2       => $host2,
         results_dir => $results_dir,
      );
   }

   my $run_time = Runtime->new(
      run_time => $o->get('run-time'),
      now      => sub { return time },
   );

   my %optional_args = (
      dry_run         => $o->get('dry-run'),
      database        => $o->get('database'),
      filter          => $o->get('filter'),
      ignore_warnings => $o->get('ignore-warnings'),
      read_only       => $o->get('read-only') ?  1 : 0,
      allowed_errors  => $o->get('continue-on-error') ? 100 : 0,
      progress        => $o->get('progress'),
   );

   if ( $host1 && $host2 ) {
      compare_host_to_host(
         logs            => \@logs,
         parser          => $parser,
         host1           => $host1,
         host2           => $host2,
         run_time        => $run_time,
         max_class_size  => $o->get('max-class-size'),
         max_examples    => $o->get('max-examples'),
         upgrade_table   => $o->get('upgrade-table'),
         %optional_args,
      );
   }
   elsif ( $host1 && $results_dir ) {
      save_results(
         logs          => \@logs,
         parser        => $parser,
         host          => $host1,
         results_dir   => $results_dir,
         run_time      => $run_time,
         upgrade_table => $o->get('upgrade-table'),
         %optional_args,
      );
   }
   elsif ( $results_dir && $host2 ) {
      compare_results_to_host(
         results_dir     => $results_dir,
         host            => $host2,
         run_time        => $run_time,
         max_class_size  => $o->get('max-class-size'),
         max_examples    => $o->get('max-examples'),
         upgrade_table   => $o->get('upgrade-table'),
         %optional_args,
      );
   }
   else {
      # Shouldn't get here, unless you're Ryan.
      die "Invalid combination of command line arguments, and pt-upgrade "
         . "failed to detect this error earlier.  Please report this bug "
         . "with the exact command line used to run the tool.\n";
   }

   PTDEBUG && _d('Stats:', Dumper($stats));
   if ( $report->{stats} ) {
      report_stats();
   }

   return $exit_status;
}

# ############################################################################
# Subroutines.
# ############################################################################

sub make_parser {
   my (%args) = @_;
   my $type = $args{type};

   # Optional args
   my $watch_server = $args{watch_server};

   my ($server, $port);
   if ( $watch_server ) {
      ($server, $port) = $watch_server
            =~ m/^((?:\d+\.\d+\.\d+\.\d+|[\w\.\-]+\w))(?:[\:\.](\S+))?/;
      PTDEBUG && _d('Watch server', $server, 'port', $port);
   }

   my @parsers;
   foreach my $module ( @{$modules_for_log_type{$type}} ) {
      my $parser = eval {
         $module->new(
            server     => $server,
            port       => $port,
            null_event => {},
         );
      };
      if ( $EVAL_ERROR ) {
         die "Error loading module $module for log type $type: $EVAL_ERROR";
      }
      push @parsers, $parser;
   }

   if ( @parsers == 1 ) {
      return sub { 
         my (%args) = @_;
         return $parsers[0]->parse_event(%args);
      };
   }

   my $parser = sub {
      my (%args) = @_;
      while ( my $event = $parsers[0]->parse_event(%args) ) {
         $args{event} = $event;
         $event = $parsers[1]->parse_event(%args);
         if ( $event && scalar %$event ) {
            return $event;
         }
      }
   };

   return $parser;
}

sub check_upgrade_table {
   my ( %args ) = @_;
   my @required_args = qw(host upgrade_table OptionParser);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($host, $upgrade_table, $o) = @args{@required_args};

   PTDEBUG && _d('Checking --upgrade-table', $upgrade_table);
   my $dbh        = $host->dbh;
   my $q          = 'Quoter';
   my ($db, $tbl) = $q->split_unquote($upgrade_table);

   # ########################################################################
   # Create the --upgrade-table database.
   # ########################################################################

   # If the repl db doesn't exit, auto-create it, maybe.
   my $show_db_sql = "SHOW DATABASES LIKE '$db'";
   PTDEBUG && _d($show_db_sql);
   my @db_exists = $dbh->selectrow_array($show_db_sql);
   if ( !@db_exists && !$o->get('create-upgrade-table') ) {
      die "--upgrade-table database $db on " . $host->name . " does not "
         . "exist and --no-create-upgrade-table was specified.  You need "
         . "to create the database.\n";
   }

   if ( $o->get('create-upgrade-table') ) {
      # Even if the db already exists, do this in case it does not exist
      # on a slave.
      my $create_db_sql
         = "CREATE DATABASE IF NOT EXISTS "
         . $q->quote($db)
         . " /* pt-upgrade */";
      PTDEBUG && _d($create_db_sql);
      eval {
         $dbh->do($create_db_sql);
      };
      if ( $EVAL_ERROR ) {
         # CREATE DATABASE IF NOT EXISTS failed but the db could already
         # exist and the error could be due, for example, to the user not
         # having privs to create it, but they still have privs to use it.
         if ( !@db_exists ) {
            warn $EVAL_ERROR;
            die "--upgrade-table database $db on " . $host->name
               . " does not exist and it cannot be created automatically.  "
               . "You need to create the database.\n";
         }
      }
   }

   # ########################################################################
   # Create the --upgrade-table table.
   # ########################################################################

   # Check if the repl table exists; if not, create it, maybe.
   my $tbl_exists = check_table(
      dbh => $dbh,
      db  => $db,
      tbl => $tbl,
   );
   PTDEBUG && _d('--upgrade-table table exists:', $tbl_exists ? 'yes' : 'no');

   if ( !$tbl_exists && !$o->get('create-upgrade-table') ) {
      die "--upgrade-table table $upgrade_table on " . $host->name
        . " does not exist and --no-create-upgrade-table was specified.  "
        . "You need to create the table.\n";
   }

   # Always create the table, unless --no-create-upgrade-table
   # was given; see https://bugs.launchpad.net/percona-toolkit/+bug/950294
   if ( $o->get('create-upgrade-table') ) {
      eval {
         PTDEBUG && _d('Creating --upgrade-table table', $upgrade_table); 
         my $sql = $o->read_para_after(__FILE__, qr/MAGIC_upgrade_table/);
         $sql =~ s/CREATE TABLE pt_upgrade/CREATE TABLE IF NOT EXISTS $upgrade_table/;
         $sql =~ s/;$//;
         PTDEBUG && _d($dbh, $sql);
         $dbh->do($sql);
      };
      if ( $EVAL_ERROR ) {
         if ( !$tbl_exists ) {
            warn $EVAL_ERROR;
            die "--upgrade table $tbl on " . $host->name . " does not exist "
               . "and it cannot be created automatically.  You need to "
               . "create the table.\n"
         }
      }
   }

   my $sql = "SELECT * FROM $upgrade_table LIMIT 1 "
           . "/* pt-upgrade check --upgrade-table */";
   eval {
      $dbh->do($sql);
   };
   if ( $EVAL_ERROR ) {
      die "Error querying the --upgrade-table $upgrade_table on "
         . $host->name . ": $EVAL_ERROR\n";
   }

   return;
}

# Copied from TableParser.
sub check_table {
   my ( %args ) = @_;
   my @required_args = qw(dbh db tbl);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dbh, $db, $tbl) = @args{@required_args};
   my $q      = 'Quoter';
   my $db_tbl = $q->quote($db, $tbl);
   PTDEBUG && _d('Checking', $db_tbl);

   my $sql = "SHOW TABLES FROM " . $q->quote($db)
           . ' LIKE ' . $q->literal_like($tbl);
   PTDEBUG && _d($sql);
   my $row;
   eval {
      $row = $dbh->selectrow_arrayref($sql);
   };
   if ( $EVAL_ERROR ) {
      PTDEBUG && _d($EVAL_ERROR);
      return 0;
   }
   if ( !$row->[0] || $row->[0] ne $tbl ) {
      PTDEBUG && _d('Table does not exist');
      return 0;
   }

   PTDEBUG && _d('Table', $db, $tbl, 'exists');
   return 1;
}

# Execute and compare queries on host1 and host2.
sub compare_host_to_host {
   my (%args) = @_;
   my @required_args = qw(logs parser host1 host2 max_class_size max_examples upgrade_table run_time);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $logs           = $args{logs};
   my $parser         = $args{parser};
   my $host1          = $args{host1};
   my $host2          = $args{host2};
   my $max_class_size = $args{max_class_size};
   my $max_examples   = $args{max_examples}; 
   my $upgrade_table  = $args{upgrade_table};
   my $run_time       = $args{run_time};

   # Optional args
   my $dry_run         = $args{dry_run};
   my $database        = $args{database};
   my $filter          = $args{filter};
   my $ignore_warnings = $args{ignore_warnings};
   my $read_only       = $args{read_only};
   my $allowed_errors  = $args{allowed_errors} || 0;
   my $progress        = $args{progress};

   # Get set up to execute and compare queries.
   my $clear_warnings_sql = "SELECT * FROM $upgrade_table LIMIT 1 "
                          . "/* pt-upgrade clear warnings */";
   my $clear_warnings_sth1 = $host1->dbh->prepare($clear_warnings_sql);
   my $clear_warnings_sth2 = $host2->dbh->prepare($clear_warnings_sql);

   my $results = UpgradeResults->new(
      max_class_size => $max_class_size,
      max_examples   => $max_examples,
   );

   my $qr = QueryRewriter->new();  # fingerprint

   my $file_iter = FileIterator->new();
   my $files = $file_iter->get_file_itr(@$logs);

   my $query_iter = QueryIterator->new(
      file_iter        => $files,
      parser           => $parser,
      fingerprint      => sub { return $qr->fingerprint(@_) },
      oktorun          => sub { return $oktorun },
      stats            => $stats,
      ($database     ? (default_database => $database)     : ()),
      ($filter       ? (filter           => $filter)       : ()),
      ($read_only    ? (read_only        => $read_only)    : ()),
      ($progress     ? (progress         => $progress)     : ()),
   );

   my $executor = EventExecutor->new(
      default_database => $database,
   );

   # Execute and compare queries.
   my $errors = 0;
   TRY:
   while ( $errors <= $allowed_errors ) {
      eval {
         EVENT:
         while (
            $oktorun
            && $run_time->have_time()
            && defined(my $event = $query_iter->next())
         ) {
            next if $dry_run;

            $clear_warnings_sth1->execute();
            my $results1 = $executor->exec_event(
               event => $event,
               host  => $host1,
            );

            $clear_warnings_sth2->execute();
            my $results2 = $executor->exec_event(
               event => $event,
               host  => $host2,
            );

            save_and_report_results(
               event           => $event,
               results         => $results,
               results1        => $results1,
               results2        => $results2,
               ignore_warnings => $ignore_warnings,
            );
         }
      };
      if ( $EVAL_ERROR ) {
         warn "Error: $EVAL_ERROR";
         $errors++;
         $exit_status |= 1;
      }

      PTDEBUG && _d('Done parsing events');
      last TRY;  # VERY IMPORTANT
   }

   # Did we finish because time ran out?
   $run_time->have_time() or $exit_status |= 8;

   # Report whatever is left.
   $results->report_unreported_classes() or $exit_status |= 1;

   return;
}

# Execute queries on host and save the results to various files in results_dir.
sub save_results {
   my (%args) = @_;
   my @required_args = qw(logs parser host results_dir upgrade_table run_time);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $logs           = $args{logs};
   my $parser         = $args{parser};
   my $host           = $args{host};
   my $results_dir    = $args{results_dir};
   my $upgrade_table  = $args{upgrade_table};
   my $run_time       = $args{run_time};
   PTDEBUG && _d('Save results to', $results_dir);

   # Optional args
   my $dry_run         = $args{dry_run};
   my $database        = $args{database};
   my $filter          = $args{filter};
   my $ignore_warnings = $args{ignore_warnings};
   my $read_only       = $args{read_only};
   my $allowed_errors  = $args{allowed_errors} || 0;
   my $progress        = $args{progress};

   # Get set up to execute queries and save the results.
   my $clear_warnings_sql = "SELECT * FROM $upgrade_table LIMIT 1 "
                          . "/* pt-upgrade clear warnings */";
   my $clear_warnings_sth = $host->dbh->prepare($clear_warnings_sql);

   my $results = ResultWriter->new(
      dir    => $results_dir,
      pretty => $ENV{PRETTY_RESULTS},
   );

   my $qr = QueryRewriter->new();  # fingerprint

   my $file_iter = FileIterator->new();
   my $files = $file_iter->get_file_itr(@$logs);

   my $query_iter = QueryIterator->new(
      file_iter        => $files,
      parser           => $parser,
      fingerprint      => sub { return $qr->fingerprint(@_) },
      oktorun          => sub { return $oktorun },
      stats            => $stats,
      ($database     ? (default_database => $database)     : ()),
      ($filter       ? (filter           => $filter)       : ()),
      ($read_only    ? (read_only        => $read_only)    : ()),
      ($progress     ? (progress         => $progress)     : ()),
   );

   my $executor = EventExecutor->new(
      default_database => $database,
   );

   $stats->{queries_written} = 0;

   # Execute queries and save the results.
   my $errors = 0;
   TRY:
   while ( $errors <= $allowed_errors ) {
      eval {
         EVENT:
         while (
            $oktorun
            && $run_time->have_time()
            && defined(my $event = $query_iter->next())
         ) {
            next if $dry_run;

            $clear_warnings_sth->execute();
            my $host_results = $executor->exec_event(
               event => $event,
               host  => $host,
            );

            $results->save(
               host    => $host,
               event   => $event,
               results => $host_results,
            );

            $stats->{queries_written}++;
         }
      };
      if ( $EVAL_ERROR ) {
         warn "Error: $EVAL_ERROR";
         $errors++;
         $exit_status |= 1;
      }

      PTDEBUG && _d('Done parsing events');
      last TRY;  # VERY IMPORTANT
   }

   # Did we finish because time ran out?
   $run_time->have_time() or $exit_status |= 8;

   return;
}

# Execute queries on host and compoare to results in results_dir.
sub compare_results_to_host {
   my (%args) = @_;
   my @required_args = qw(results_dir host max_class_size max_examples upgrade_table run_time);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $results_dir    = $args{results_dir};
   my $host           = $args{host};
   my $max_class_size = $args{max_class_size};
   my $max_examples   = $args{max_examples}; 
   my $upgrade_table  = $args{upgrade_table};
   my $run_time       = $args{run_time};
   PTDEBUG && _d('Compare', $results_dir, 'to', $host->name);

   # Optional args
   my $dry_run         = $args{dry_run};
   my $database        = $args{database};
   my $ignore_warnings = $args{ignore_warnings};
   my $allowed_errors  = $args{allowed_errors} || 0;
   my $progress        = $args{progress};

   my $clear_warnings_sql = "SELECT * FROM $upgrade_table LIMIT 1 "
                          . "/* pt-upgrade clear warnings */";
   my $clear_warnings_sth = $host->dbh->prepare($clear_warnings_sql);

   my $results = UpgradeResults->new(
      max_class_size => $max_class_size,
      max_examples   => $max_examples,
   );

   my $qr = QueryRewriter->new();  # fingerprint

   # Results from host1, obtained earlier with --save-results.
   my $result_iter = ResultIterator->new(
      dir      => $results_dir,
      progress => $progress,
   );

   # Results for host2, obtaining now.
   my $executor = EventExecutor->new(
      default_database => $database,
   );

   my $errors = 0;
   TRY:
   while ( $errors <= $allowed_errors ) {
      eval {
         EVENT:
         while (
            $oktorun
            && $run_time->have_time()
            && defined(my $results1 = $result_iter->next())
         ) {
            # Increment this stat manually because we're not using
            # a QueryIterator.
            # TODO: increment this stat in ResultIterator?
            $stats->{queries_read}++;

            next if $dry_run;

            $results1->{sth} = FakeSth->new($results1->{rows});

            my $event = {
               arg         => $results1->{query},
               db          => $results1->{db},
               fingerprint => $qr->fingerprint($results1->{query}),
            };

            $clear_warnings_sth->execute();
            my $results2 = $executor->exec_event(
               event => $event,
               host  => $host,
            );

            save_and_report_results(
               event           => $event,
               results         => $results,
               results1        => $results1,
               results2        => $results2,
               ignore_warnings => $ignore_warnings,
            );
         }
      };
      if ( $EVAL_ERROR ) {
         warn "Error: $EVAL_ERROR";
         $errors++;
         $exit_status |= 1;
      }

      PTDEBUG && _d('Done parsing results');
      last TRY;  # VERY IMPORTANT
   }

   # Did we finish because time ran out?
   $run_time->have_time() or $exit_status |= 8;

   # Report whatever is left.
   $results->report_unreported_classes() or $exit_status |= 1;

   return;
}

# Diff results1 and results2 and if different save them with results,
# the poorly named UpgradeResults object.
sub save_and_report_results {
   my (%args) = @_;
   my @required_args = qw(event results results1 results2);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $event    = $args{event};
   my $results  = $args{results};
   my $results1 = $args{results1};
   my $results2 = $args{results2};

   # Optional args
   my $ignore_warnings = $args{ignore_warnings};

   if ( $results1->{error} && $results2->{error} ) {
      PTDEBUG && _d('Failed query');
      $stats->{failed_queries}++;
      $results->save_failed_query(
         event  => $event,
         error1 => $results1->{error},
         error2 => $results2->{error},
      );
   }
   elsif (   ($results1->{error} && !$results2->{error})
          || ($results2->{error} && !$results1->{error}) ) {
      PTDEBUG && _d('Query error');
      $stats->{queries_with_errors}++;
      $results->save_error(
         event  => $event,
         error1 => $results1->{error},
         error2 => $results2->{error},
      );
   }
   else {
      my $query_time_diffs = diff_query_times(
         query_time1 => $results1->{query_time},
         query_time2 => $results2->{query_time},
      );

      my $warning_diffs = diff_warnings(
         warnings1       => $results1->{warnings},
         warnings2       => $results2->{warnings},
         ignore_warnings => $ignore_warnings,
      );

      # Only SELECT statements return rows, *except* when they are directed 
      # INTO a file or a variable.
      my $row_diffs;
      if ( $event->{arg} =~ m/(?:^\s*SELECT|(?:\*\/\s*SELECT))/i 
         &&  $event->{arg} !~ m/INTO\s*(?:OUTFILE|DUMPFILE|@)/i ) {
         $row_diffs = diff_rows(
            sth1 => $results1->{sth},
            sth2 => $results2->{sth},
         );
      }

      eval {
         foreach my $result ( $results1, $results2 ) {
            $result->{sth}->finish();
            delete $result->{sth};
         }
      };
      if ( $EVAL_ERROR ) {
         PTDEBUG && _d($EVAL_ERROR);
      }

      if (    ($query_time_diffs && scalar @$query_time_diffs)
           || ($warning_diffs    && scalar @$warning_diffs)
           || ($row_diffs        && scalar @$row_diffs) )
      {
         PTDEBUG && _d('Query diffs');
         $exit_status |= 4;
         $stats->{queries_with_diffs}++;
         $results->save_diffs(
            event            => $event,
            query_time_diffs => $query_time_diffs,
            warning_diffs    => $warning_diffs,
            row_diffs        => $row_diffs,
         );
      }
      else {
         PTDEBUG && _d('Query OK, no diffs');
         $stats->{queries_no_diffs}++;
      }
   }

   return;
}

sub disable_query_cache {
   my ($dbh) = @_;
   die "I need a dbh argument" unless $dbh;

   my $sql = 'SELECT @@query_cache_type';
   PTDEBUG && _d($sql);
   my $query_cache_type;
   eval { ($query_cache_type) = $dbh->selectrow_array($sql) };
   # There is no query cache in MySQL 8.0+
   if ( $EVAL_ERROR =~ m/Unknown system variable 'query_cache_type'/i ) {
       return;
   }
   PTDEBUG && _d($query_cache_type);
   return if ($query_cache_type || '') =~ m/OFF|0/;

   $sql = q/SET SESSION query_cache_type = OFF/;
   eval {
      PTDEBUG && _d($sql);
      $dbh->do($sql);
   };
   if ( $EVAL_ERROR ) {
      warn $EVAL_ERROR;
      die "Failed to $sql.  Disable the query cache "
         . "manually, or specify --no-disable-query-cache.\n";
   }

   return;
}

sub diff_query_times {
   my (%args) = @_;
   my @required_args = qw(query_time1 query_time2);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless defined $args{$arg};
   }
   my $t1 = $args{query_time1};
   my $t2 = $args{query_time2};
   PTDEBUG && _d('Diff query times', $t1, $t2);

   return unless $t1 && $t2 && $t1 != $t2;

   # We only care if the 2nd query time is greater.  The first query
   # time should be the base/reference system.
   return if $t2 < $t1;

   # From http://en.wikipedia.org/wiki/Order_of_magnitude: "We say two
   # numbers have the same order of magnitude of a number if the big
   # one divided by the little one is less than 10. For example, 23 and
   # 82 have the same order of magnitude, but 23 and 820 do not."
   my $incr = $t2 / $t1;
   return if $incr < 10;
   return [
      $t1,
      $t2,
      sprintf('%.1f', $incr),
   ];
}

sub diff_warnings {
   my (%args) = @_;
   my @required_args = qw(warnings1 warnings2);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $host1_warns = $args{warnings1};
   my $host2_warns = $args{warnings2};

   # Optional args
   my $ignore_warnings = $args{ignore_warnings};

   PTDEBUG && _d('Diff warnings');

   my %codes = map  { $_ => 1 }
               grep { !$ignore_warnings->{$_} }
               keys %$host1_warns, keys %$host2_warns;
   my @diffs;
   foreach my $code ( sort keys %codes ) {
      next if exists $host1_warns->{$code} && exists $host2_warns->{$code};
      push @diffs, [
         $code,
         $host1_warns->{$code},
         $host2_warns->{$code},
      ];
   }

   return \@diffs;
}

sub diff_rows {
   my (%args) = @_;
   my @required_args = qw(sth1 sth2);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $sth1 = $args{sth1};
   my $sth2 = $args{sth2};

   return unless $sth1 && $sth2;

   # Optional args
   my $max_diffs = $args{max_diffs} || 3;

   PTDEBUG && _d('Diff rows');
   my @diffs;

   my $rows1 = $sth1->fetchall_arrayref();
   my $rows2 = $sth2->fetchall_arrayref();

   my $n_rows1   = scalar @$rows1;
   my $n_rows2   = scalar @$rows2;
   my $max_rowno = min($n_rows1, $n_rows2);
   if ( $n_rows1 != $n_rows2 ) {
      my @missing_rows;
      if ( $n_rows1 > $n_rows2 ) {
         PTDEBUG && _d('host1 has more rows; host2 is missing rows');
         my $nth_missing_row = $n_rows1 < ($max_rowno + $max_diffs - 1)
                             ? $n_rows1 - 1
                             : $max_rowno + $max_diffs - 1;
         @missing_rows = @{$rows1}[$max_rowno..$nth_missing_row];
         push @diffs, [
            $n_rows1 - $n_rows2,
            \@missing_rows,
            undef,
         ];
      }
      else {
         PTDEBUG && _d('host2 has more rows; host1 is missing rows');
         my $nth_missing_row = $n_rows2 < ($max_rowno + $max_diffs - 1)
                             ? $n_rows2 - 1
                             : $max_rowno + $max_diffs - 1;
         @missing_rows = @{$rows2}[$max_rowno..$nth_missing_row];
         push @diffs, [
            $n_rows2 - $n_rows1,
            undef,
            \@missing_rows,
         ];
      }
   }

   my $rowno = -1;  # so first ++ will incr to 0
   while ( ++$rowno < $max_rowno && scalar(@diffs) < $max_diffs ) {
      my $row1 = $rows1->[$rowno];
      my $row2 = $rows2->[$rowno];
      if ( !identical_rows($row1, $row2) ) {
         PTDEBUG && _d('Row diff:', Dumper($row1), Dumper($row2));
         push @diffs, [
            ($rowno + 1),  # rows are 1-index, not zero-indexed
            $row1,
            $row2,
         ];
      }
   }

   return \@diffs;
}

sub identical_rows {
   my ($array1, $array2) = @_;

   return 0 if ($array1 && !$array2) || (!$array1 && $array2);
   return 1 if !$array1 && !$array2;

   my $size_array1 = scalar @$array1;
   my $size_array2 = scalar @$array2;
   if ( $size_array1 != $size_array2 ) {
      PTDEBUG && _d('Different number of columns:', $size_array1, $size_array2);
      return 0;
   }

   my $n_vals = $size_array1 - 1;  # arrays are zero-indexed
   for my $i ( 0..$n_vals ) {
      # NULL == NULL
      # https://bugs.launchpad.net/percona-toolkit/+bug/1168434
      next if !defined $array1->[$i] && !defined $array2->[$i];

      if ( defined $array1->[$i] && defined $array2->[$i] ) {
         return 0 unless $array1->[$i] eq $array2->[$i];
      }
      else {
         return 0;
      }
   }

   return 1;
} 

sub report_logs {
   my (%args) = @_;
   my $logs        = $args{logs};
   my $results_dir = $args{results_dir};

   print_header('Logs', '-');

   if ( @$logs ) {
      foreach my $log ( @$logs ) {
         printf "\nFile: %s\nSize: %s\n", $log, (-s $log || '?');
      }
   }
   elsif ( $results_dir ) {
      printf "\nResults directory: $results_dir\n";
   }

   return;
}

sub report_hosts {
   my (%args) = @_;
   my $host1       = $args{host1};
   my $host2       = $args{host2};
   my $results_dir = $args{results_dir};

   # Print which hosts we're comparing.
   my $v1 = $host1 ? VersionParser->new($host1->dbh) : undef;
   my $v2 = $host2 ? VersionParser->new($host2->dbh) : undef;
   my $hostname1 = $host1 ? get_hostname($host1->dbh) : undef;
   my $hostname2 = $host2 ? get_hostname($host2->dbh) : undef;

   print_header('Hosts', '-');

   if ( $host1 && $host2 ) {
      printf "
host1:

  DSN:       %s
  hostname:  %s
  MySQL:     %s

host2:

  DSN:       %s
  hostname:  %s
  MySQL:     %s
",
         ($host1->{dsn_name} || '?'),
         $hostname1,
         ($v1->flavor . ' ' . $v1->version),
         ($host2->{dsn_name} || '?'),
         $hostname2,
         ($v2->flavor . ' ' . $v2->version);
   }
   elsif ( $host1 && $results_dir ) {
      printf "
host1:

  DSN:       %s
  hostname:  %s
  MySQL:     %s

Saving results in %s
",
         ($host1->{dsn_name} || '?'),
         $hostname1,
         ($v1->flavor . ' ' . $v1->version),
         $results_dir;
   }
   elsif ( $results_dir && $host2 ) {
      printf "
host1:

  Reading results from %s

host2:

  DSN:       %s
  hostname:  %s
  MySQL:     %s
",
         $results_dir,
         ($host2->{dsn_name} || '?'),
         $hostname2,
         ($v2->flavor . ' ' . $v2->version);
   }
   else {
      print "\nUnknown hosts.\n";
   }

   return;
}

sub report_stats {
   print_header('Stats', '-');
   my $fmt = "%-20s  %d\n";
   print "\n";
   foreach my $stat ( sort keys %$stats ) {
      printf $fmt, $stat, $stats->{$stat} || 0;
   }
   return;
}

sub print_header {
   my ($name, $c) = @_;
   $name ||= '?';
   $c    ||= '#';
   print "\n#" . ($c x 71) . "\n";
   print "# $name\n";
   print "#" . ($c x 71) . "\n";
}

sub get_hostname {
   my ($dbh, $v) = @_;
   my ($hostname) = $dbh->selectrow_array(q{SELECT /*!50038 @@hostname */});
   if ( !$hostname ) {
      chomp($hostname = `hostname`);
   }
   return $hostname || '?';
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
      exit 1;
   }
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

pt-upgrade - Verify that query results are identical on different servers.

=head1 SYNOPSIS

Usage: pt-upgrade [OPTIONS] LOGS|RESULTS DSN [DSN]

pt-upgrade executes queries in the given MySQL C<LOGS> on each C<DSN>,
compares the results, and reports any significant differences.  The tool can
also save the results for later analyses.  C<LOGS> can be slow, general,
binary, tcpdump, and "raw".

Compare host2 to host1 using queries in C<slow.log>:

   pt-upgrade h=host1 h=host2 slow.log

Compare host2 to saved results from host1:

   pt-upgrade h=host1 --save-results host1_results/ slow.log

   pt-upgrade host1_results1/ h=host2

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

pt-upgrade helps determine if it is safe to upgrade (or downgrade) to
a new version of MySQL.  A safe and conservative upgrade plan has several
steps, one of which is ensuring that queries will produce identical results
on the new version of MySQL.

pt-upgrade executes queries from slow, general, binary, tcpdump, and
"raw" logs on two servers, compares many aspects of each query's exeuction
and results, and reports any signficant differences.  The two servers are
typically development servers, one running the current production version
of MySQL and the other running the new version of MySQL.

=head1 USE CASES

pt-upgrade has two use cases.  The first, canonical case is running "host
to host".  A log file and two DSN are given on the command line, one for
each MySQL server.  See the first example in the L<"SYNOPSIS">.  Queries
are executed and compared on each server as the tool runs.  Queries with
differences are printed as the tool runs, or when it finishes (see
L<"WHEN QUERIES ARE REPORTED">).  Nothing is saved to disk, so this use case
requires less hard disk space, but the queries must be executed on both
servers if the tool is ran again, even if one of the servers hasn't
changed.  If there are a lot of queries or executing them takes a
long time, and one server doesn't change, you may want to use the second
use case.

The second use case is running "reference results to host".  Reference
results are the complete results from a single MySQL server, saved to
disk.  In this case, you must first generate the reference results
with L<"--save-results">, then run the tool a second time to compare
another MySQL server to the results.  See the second example in the
L<"SYNOPSIS">.  Results are typically generated for the current version
of MySQL which doesn't change.  This use case can require I<a lot> of
disk space because the results (i.e. rows) for all queries must be saved,
plus other data about the queries.  If you plan to do many comparisons
against a fixed version of MySQL, this use case is more efficient.  Or if
you don't have access to both servers at the same time, this use case
allows you to "execute now, compare later".

=head1 IMPORTANT CONSIDERATIONS

=head2 CONSISTENCY

Consistent environments and consistent data are crucial for obtaining
an accurate report.  pt-upgrade should never be ran on a production
server or any active server because there is no easy way to ensure
a synchronous read for each query.  If data is changing on either server
while pt-upgrade is running, the report could contain more false-positives
than legitimate differences.  B<pt-upgrade assumes that both MySQL servers
are static, unchanging (except for any changes made by the tool if ran
with C<--no-read-only>).>  A read-only workload shouldn't affect the tool,
except maybe query times, so read-only slaves could be used.

=head2 COMPARED TO

In a host to host comparison, results from the first host establish the
norm to which results from the second host are compared.  In a reference
results to host comparison, the reference results are the norm to which
the host is compared.  Comparative phrases like "smaller than", "better
than", etc. mean compared to the norm.

For example, if the query time for an event is C<0.01> on the first host
and C<0.5> on the second host, that is a significant difference because
C<0.5> is worse than C<0.1>, and so the query will be reported.

=head2 READ-ONLY

By default, pt-upgrade only executes C<SELECT> and C<SET> statements.
(This does not include 'SELECT...INTO' statements, which do not return
rows but dump output to a file or variable.)
If you're using recreatable test or development servers and wish to
compare write statements too (e.g. C<INSERT>, C<UPDATE>, C<DELETE>),
then specify C<--no-read-only>.  If using a binary log, you must
specify C<--no-read-only> because binary logs don't contain C<SELECT>
statements.  See L<"--[no]read-only">.

=head2 TRANSACTIONS

The tool does not create its own transactions, but any transactions in
the C<LOG> are executed as-is.  Since logs are serial, transactions
shouldn't normally be an issue.  If, however, you need to compare queries
that are somehow transactionally related (in which case you probably
also need to disable L<"--[no]read-only">), then pt-upgrade probably
won't do what you need because it's not designed for this purpose.

pt-upgrade runs with C<autocommit=1> by default.

=head2 THROTTLING

pt-upgrade has no throttling options because the tool should only be ran
on dedicated testing or development servers.  B<Do not run pt-upgrade
on production servers!>  Consequently, the tool is CPU, memory, disk, and
network intensive.  It executes queries as fast as possible.

=head1 QUERY DIFFERENCES

Signficant query differences are determined by comparing these aspects
of each query from both hosts:

=over

=item Row count

The number of rows returned by the query should be the same.
This is reported as "missing rows" under "Row diffs".

=item Row data

The row data returned by the query should be the same.  All differences are
significant: whitespace, float-precision, etc.

=item Warnings

The query should either not produce any errors or warnings, or produce
the same errors or warnings.

=item Query time

A query rarely executes with a constant time, but its execution time
should be within the same order of magnitude or smaller.

=item Query errors

If a query causes a SQL error on only one host, this is reported as
"Query errors".  Since the query works on one host, its syntax is
probably valid, and the error is due to some condition unique to
the other host.

=item SQL errors

If a query causes a SQL error on both hosts, this is reported as
"SQL errors".  The SQL syntax of the query could be invalid.

=back

=head1 REPORT

As pt-upgrade runs, it prints queries with differences as soon as it can
(see L<"WHEN QUERIES ARE REPORTED">).  To prevent the report from
becoming too long, queries are not reported individually but grouped by
fingerprint into classes.  A query fingerprint is the abstracted form of
a query, created by removing literal values, normalizing whitespace, etc.
So these queries belong to the same class:

   SELECT c FROM t WHERE id = 1
   SELECT c FROM t WHERE id=5
   select  c  from  t  where  id  =  9

The fingerprint for those queries is:

   select c from t where id=?

Each query class can have up to L<"--max-class-size"> unique queries
(1,000 by default).  Up to L<"--max-examples"> are reported for each
type of difference, per query class.  By virtue of being in the same class,
an example of one query's difference is usually representative of all queries
with the same difference, so it's not necessary to report every example.
The total number of queries in a class with a particular difference is
indicated in the report.

=head2 EXAMPLE

 #-----------------------------------------------------------------------
 # Logs
 #-----------------------------------------------------------------------

 File: /opt/mysql/slow.log
 Size: 59700

 #-----------------------------------------------------------------------
 # Hosts
 #-----------------------------------------------------------------------

 host1:

   DSN:       h=127.1,P=12345
   hostname:  dev1
   MySQL:     MySQL 5.1.68

 host2:

   DSN:       h=127.1,P=12348
   hostname:  dev2
   MySQL:     MySQL 5.5.10

 ########################################################################
 # Query class AAD020567F8398EE
 ########################################################################

 Reporting class because it has diffs, but hasn't been reported yet.

 Total queries      1
 Unique queries     1
 Discarded queries  0

 insert into t (id, username) values(?+)

 ##
 ## Warning diffs: 1
 ##

 -- 1.

    Code: 1265
   Level: Warning
 Message: Data truncated for column 'username' at row 1

 vs.

 No warning 1265

 INSERT INTO t (id, username) VALUES (NULL, 'long_username')

 #-----------------------------------------------------------------------
 # Stats
 #-----------------------------------------------------------------------

 failed_queries        0
 not_select            0
 queries_filtered      0
 queries_no_diffs      0
 queries_read          1
 queries_with_diffs    1
 queries_with_errors   0

The "Query class <ID>" sections are the most important because they list
L<"QUERY DIFFERENCES">.  The first part of the section lists the reason
why the query class was report, followed by counts of queries in the class,
followed by the fingerprint which defines the class.

The rest of the query class section lists the L<"QUERY DIFFERENCES"> that
caused the class to be reported.  Each type of difference begins with
a double hash mark header that lists the type and total number of queries
in the class with the difference.  Then up to L<"--max-examples"> are listed,
numbered "-- 1.", "--- 2.", etc.  Each example lists the difference for
the first and second hosts (respective to the "Hosts" section), followed by
the first SQL statement that revealed the difference.

=head1 WHEN QUERIES ARE REPORTED

A query class is reported as soon as any one of the L<"QUERY DIFFERENCES">
or query errors has L<"--max-examples">.  Else, all queries with differences
are reported when the tool finishes.

For example, if two query time differences are found for a query class,
it is not reported yet.  Once a third query time diffence is found,
the query class is reported, including any other differences that may
have been found too.  Queries for the class will continue to be executed,
but the class will not be reported again.

=head1 OUTPUT

The L<"REPORT"> is printed to STDOUT as the tool runs.  Internal warnings,
errors, and L<"--progress"> are printed to STDERR.  To keep the two separate,
run the tool like:

   pt-upgrade ... 1>report 2>err &

Then C<tail -f err> while the tool is running to track its L<"--progress">.

=head1 EXIT STATUS

In general, the tool exits zero if it finishes normally and there were
no internal warnings or errors, and no L<"QUERY DIFFERENCES"> were found.
Else the tool exits non-zero with one or more of the following codes: 

=over

=item * 1

There were too many internal errors or warnings; see STDERR.
See also L<"--[no]continue-on-error">.

=item * 4

There were L<"QUERY DIFFERENCES">; see the L<"REPORT">.

=item * 8

L<"--run-time"> expired; the tool did not finish reading the logs or
reference results.

=back

Other exit codes indicate that the tool crashed or died unexpectedly.
The error that caused this should have printed to STDERR.

To check for a particular exit code, logical C<AND> (C<&>) the final exit
status with the exit code.  For example, exit status 5 implies codes 1 and 4
because C<5 & 1> is true, and C<5 & 4> is true.

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

=item --[no]continue-on-error

default: yes

Continue parsing even if there is an error.  The tool will not continue
forever: it stops after 100 errors, in which case there is probably a bug
in the tool or the input is invalid.

=item --[no]create-upgrade-table

default: yes

Create the L<"--upgrade-table"> database and table.

=item --daemonize

Fork to the background and detach from the shell.  POSIX
operating systems only.

=item --database

short form: -D; type: string

Default database when connecting to MySQL.

=item --defaults-file

short form: -F; type: string

Only read MySQL options from the given file.  You must give an absolute
pathname.

=item --[no]disable-query-cache

default: yes

C<SET SESSION query_cache_type = OFF> to disable the query cache.

=item --dry-run

Run but do not execute or compare queries.  This is useful for checking
command line options, connections to MySQL, and log or reference results
parsing.

=item --filter

type: string

Allow events for which this Perl code returns true.

See the same option in the documentation for pt-query-digest.

=item --help

Show help and exit.

=item --host

short form: -h; type: string

MySQL hostname or IP.

=item --ignore-warnings

type: Hash

Ignore these MySQL warning codes when comparing warnings.

=item --log

type: string

Print STDOUT and STDERR to this file when daemonized.  This option
only takes affect when L<"--daemonize"> is specified.  The file is created
if it doesn't exist, else output is appended to it.

=item --max-class-size

type: int; default: 1000

Max number of unique queries in each query class.  See L<"REPORT">.

=item --max-examples

type: int; default: 3

Max number of examples to list for each L<"QUERY DIFFERENCES">.  A query
class is reported as soon as this many examples for any type of query
difference are found.

=item --password

short form: -p; type: string

MySQL password for the L<"--user">.

=item --pid

type: string

Create the given PID file.  The tool won't start if the PID file already
exists and the PID it contains is different than the current PID.  However,
if the PID file exists and the PID it contains is no longer running, the
tool will overwrite the PID file with the current PID.  The PID file is
removed automatically when the tool exits.

=item --port

short form: -P; type: int

MySQL port number.

=item --progress

type: array; default: time,30

Print progress reports to STDERR.  The tool prints progress reports while
reading logs or reference results, roughly estimating how long until it
finishes.

The value is a comma-separated list with two parts.  The first part can be
percentage, time, or iterations; the second part specifies how often an update
should be printed, in percentage, seconds, or number of iterations.

=item --[no]read-only

default: yes

Execute only C<SELECT> and C<SET> statements.  If C<--no-read-only> is
specified, I<all> queries are exeucted: C<DROP>, C<DELETE>, C<UPDATE>, etc.
Even when running in default read-only mode, you should use a MySQL user
with only C<SELECT> privileges to insure against bugs in the tool.

=item --report

type: Hash; default: hosts, logs, queries, stats

Print these sections of the L<"REPORT">.

=item --run-time

type: time

How long to run before exiting.  By default, the tool runs until it
finishes reading the logs or reference results.

=item --save-results

type: string

Save reference results to this directory.  This option works only when
one DSN is specified, to generate reference results.  When comparing
a host to reference results, specify its results directory instead of
its DSN.  See the second example in the L<"SYNOPSIS">.

Reference results can use I<a lot> of disk space.

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

=item --type

type: string; default: slowlog

Type of log files.  Valid types are:

  VALUE    LOG TYPE
  =======  ===========================================
  slowlog  MySQL slow log
  genlog   MySQL general log
  binlog   MySQL binary log (converted by mysqlbinlog)
  tcpdump  TCP dump file generated by tcpdump command
  rawlog   Custom log with one SQL statement per line

=item --upgrade-table

type: string; default: percona_schema.pt_upgrade

Use this table to clear warnings.  To clear all warnings from previous
queries, pt-upgrade executes C<SELECT * FROM --upgrade-table LIMIT 1>
on each host before executing each query.

The table must be database-qualified.  The database and table are
automatically created unless C<--no-create-upgrade-table> is specified
(see L<"--[no]create-upgrade-table">).  If the table does not already
exist, it is created with this definition:

=for comment ignore-pt-internal-value
MAGIC_upgrade_table

   CREATE TABLE pt_upgrade (
     id INT NOT NULL PRIMARY KEY
   )

=item --user

short form: -u; type: string

MySQL user if not the current system user.

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

For more information, visit L<https://www.percona.com/version-check>.

=item --watch-server

type: string

Parse only events for this IP:port for L<"--type"> tcpdump.  All other
IP addresses are ignored.  If not specified, pt-upgrade watches all servers
by looking for any IP address using port 3306 or "mysql".  If you're watching
a server with a non-standard port, this won't work, so you must specify the
IP address and port to watch.

If you want to watch a mix of servers, some running on standard port 3306
and some running on non-standard ports, you need to create separate
tcpdump outputs for the non-standard port servers and then specify this
option for each.  At present pt-upgrade cannot auto-detect servers on
port 3306 and also be told to watch a server on a non-standard port.

=back

=head1 DSN OPTIONS

These DSN options are used to create a DSN.  Each option is given like
C<option=value>.  The options are case-sensitive, so P and p are not the
same option.  There cannot be whitespace before or after the C<=>, and
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

=item * L

copy: yes

Explicitly enable LOAD DATA LOCAL INFILE.

For some reason, some vendors compile libmysql without the
--enable-local-infile option, which disables the statement.  This can
lead to weird situations, like the server allowing LOCAL INFILE, but 
the client throwing exceptions if it's used.

However, as long as the server allows LOAD DATA, clients can easily
re-enable it; See L<https://dev.mysql.com/doc/refman/5.0/en/load-data-local.html>
and L<http://search.cpan.org/~capttofu/DBD-mysql/lib/DBD/mysql.pm>.
This option does exactly that.

Although we've not found a case where turning this option leads to errors or
differing behavior, to be on the safe side, this option is not
on by default.

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

   PTDEBUG=1 pt-upgrade ... > FILE 2>&1

Be careful: debugging output is voluminous and can generate several megabytes
of output.

=head1 SYSTEM REQUIREMENTS

You need Perl, DBI, DBD::mysql, and some core packages that ought to be
installed in any reasonably new version of Perl.

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-upgrade>.

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

Daniel Nichter

=head1 ABOUT PERCONA TOOLKIT

This tool is part of Percona Toolkit, a collection of advanced command-line
tools for MySQL developed by Percona.  Percona Toolkit was forked from two
projects in June, 2011: Maatkit and Aspersa.  Those projects were created by
Baron Schwartz and primarily developed by him and Daniel Nichter.  Visit
L<http://www.percona.com/software/> to learn about other free, open-source
software from Percona.

=head1 COPYRIGHT, LICENSE, AND WARRANTY

This program is copyright 2009-2018 Percona LLC and/or its affiliates.
Feedback and improvements are welcome.

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

pt-upgrade 3.3.0

=cut
