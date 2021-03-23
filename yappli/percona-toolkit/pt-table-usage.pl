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
      DSNParser
      Lmo::Utils
      Lmo::Meta
      Lmo::Object
      Lmo::Types
      Lmo
      OptionParser
      SlowLogParser
      Transformers
      QueryRewriter
      QueryParser
      VersionParser
      FileIterator
      SQLParser
      TableUsage
      Daemon
      Runtime
      Progress
      Pipeline
      Quoter
      TableParser
      MysqldumpParser
      SchemaQualifier
   ));
}

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

   $query =~ s/ (?:LOW_PRIORITY|IGNORE|STRAIGHT_JOIN)//ig;

   if ( $query =~ s/^\s*LOCK TABLES\s+//i ) {
      PTDEBUG && _d('Special table type: LOCK TABLES');
      $query =~ s/\s+(?:READ(?:\s+LOCAL)?|WRITE)\s*//gi;
      PTDEBUG && _d('Locked tables:', $query);
      $query = "FROM $query";
   }

   $query =~ s/\\["']//g;                # quoted strings
   $query =~ s/".*?"/?/sg;               # quoted strings
   $query =~ s/'.*?'/?/sg;               # quoted strings

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
# SQLParser r0
# Don't update this package!
# ###########################################################################

package SQLParser;

{ # package scope
use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

my $quoted_ident   = qr/`[^`]+`/;
my $unquoted_ident = qr/
   \@{0,2}         # optional @ or @@ for variables
   \w+             # the ident name
   (?:\([^\)]*\))? # optional function params
/x;

my $ident_alias = qr/
  \s+                                 # space before alias
  (?:(AS)\s+)?                        # optional AS keyword
  ((?>$quoted_ident|$unquoted_ident)) # alais
/xi;

my $table_ident = qr/(?:
   ((?:(?>$quoted_ident|$unquoted_ident)\.?){1,2}) # table
   (?:$ident_alias)?                               # optional alias
)/xo;

my $column_ident = qr/(?:
   ((?:(?>$quoted_ident|$unquoted_ident|\*)\.?){1,3}) # column
   (?:$ident_alias)?                                  # optional alias
)/xo;

my $function_ident = qr/
   \b
   (
      \w+      # function name
      \(       # opening parenthesis
      [^\)]+   # function args, if any
      \)       # closing parenthesis
   )
/x;

my %ignore_function = (
   INDEX => 1,
   KEY   => 1,
);

sub new {
   my ( $class, %args ) = @_;
   my $self = {
      %args,
   };
   return bless $self, $class;
}

sub parse {
   my ( $self, $query ) = @_;
   return unless $query;

   my $allowed_types = qr/(?:
       DELETE
      |INSERT
      |REPLACE
      |SELECT
      |UPDATE
      |CREATE
   )/xi;

   $query = $self->clean_query($query);

   my $type;
   if ( $query =~ s/^(\w+)\s+// ) {
      $type = lc $1;
      PTDEBUG && _d('Query type:', $type);
      die "Cannot parse " . uc($type) . " queries"
         unless $type =~ m/$allowed_types/i;
   }
   else {
      die "Query does not begin with a word";  # shouldn't happen
   }

   $query = $self->normalize_keyword_spaces($query);

   my @subqueries;
   if ( $query =~ m/(\(SELECT )/i ) {
      PTDEBUG && _d('Removing subqueries');
      @subqueries = $self->remove_subqueries($query);
      $query      = shift @subqueries;
   }
   elsif ( $type eq 'create' && $query =~ m/\s+SELECT/ ) {
      PTDEBUG && _d('CREATE..SELECT');
      ($subqueries[0]->{query}) = $query =~ m/\s+(SELECT .+)/;
      $query =~ s/\s+SELECT.+//;
   }

   my $parse_func = "parse_$type";
   my $struct     = $self->$parse_func($query);
   if ( !$struct ) {
      PTDEBUG && _d($parse_func, 'failed to parse query');
      return;
   }
   $struct->{type} = $type;
   $self->_parse_clauses($struct);

   if ( @subqueries ) {
      PTDEBUG && _d('Parsing subqueries');
      foreach my $subquery ( @subqueries ) {
         my $subquery_struct = $self->parse($subquery->{query});
         @{$subquery_struct}{keys %$subquery} = values %$subquery;
         push @{$struct->{subqueries}}, $subquery_struct;
      }
   }

   PTDEBUG && _d('Query struct:', Dumper($struct));
   return $struct;
}


sub _parse_clauses {
   my ( $self, $struct ) = @_;
   foreach my $clause ( keys %{$struct->{clauses}} ) {
      if ( $clause =~ m/ / ) {
         (my $clause_no_space = $clause) =~ s/ /_/g;
         $struct->{clauses}->{$clause_no_space} = $struct->{clauses}->{$clause};
         delete $struct->{clauses}->{$clause};
         $clause = $clause_no_space;
      }

      my $parse_func     = "parse_$clause";
      $struct->{$clause} = $self->$parse_func($struct->{clauses}->{$clause});

      if ( $clause eq 'select' ) {
         PTDEBUG && _d('Parsing subquery clauses');
         $struct->{select}->{type} = 'select';
         $self->_parse_clauses($struct->{select});
      }
   }
   return;
}

sub clean_query {
   my ( $self, $query ) = @_;
   return unless $query;

   $query =~ s/^\s*--.*$//gm;  # -- comments
   $query =~ s/\s+/ /g;        # extra spaces/flatten
   $query =~ s!/\*.*?\*/!!g;   # /* comments */
   $query =~ s/^\s+//;         # leading spaces
   $query =~ s/\s+$//;         # trailing spaces

   return $query;
}

sub normalize_keyword_spaces {
   my ( $self, $query ) = @_;

   $query =~ s/\b(VALUE(?:S)?)\(/$1 (/i;
   $query =~ s/\bON\(/on (/gi;
   $query =~ s/\bUSING\(/using (/gi;

   $query =~ s/\(\s+SELECT\s+/(SELECT /gi;

   return $query;
}

sub _parse_query {
   my ( $self, $query, $keywords, $first_clause, $clauses ) = @_;
   return unless $query;
   my $struct = {};

   1 while $query =~ s/$keywords\s+/$struct->{keywords}->{lc $1}=1, ''/gie;

   my @clause = grep { defined $_ }
      ($query =~ m/\G(.+?)(?:$clauses\s+|\Z)/gci);

   my $clause = $first_clause,
   my $value  = shift @clause;
   $struct->{clauses}->{$clause} = $value;
   PTDEBUG && _d('Clause:', $clause, $value);

   while ( @clause ) {
      $clause = shift @clause;
      $value  = shift @clause;
      $struct->{clauses}->{lc $clause} = $value;
      PTDEBUG && _d('Clause:', $clause, $value);
   }

   ($struct->{unknown}) = ($query =~ m/\G(.+)/);

   return $struct;
}

sub parse_delete {
   my ( $self, $query ) = @_;
   if ( $query =~ s/FROM\s+//i ) {
      my $keywords = qr/(LOW_PRIORITY|QUICK|IGNORE)/i;
      my $clauses  = qr/(FROM|WHERE|ORDER BY|LIMIT)/i;
      return $self->_parse_query($query, $keywords, 'from', $clauses);
   }
   else {
      die "DELETE without FROM: $query";
   }
}

sub parse_insert {
   my ( $self, $query ) = @_;
   return unless $query;
   my $struct = {};

   my $keywords   = qr/(LOW_PRIORITY|DELAYED|HIGH_PRIORITY|IGNORE)/i;
   1 while $query =~ s/$keywords\s+/$struct->{keywords}->{lc $1}=1, ''/gie;

   if ( $query =~ m/ON DUPLICATE KEY UPDATE (.+)/i ) {
      my $values = $1;
      die "No values after ON DUPLICATE KEY UPDATE: $query" unless $values;
      $struct->{clauses}->{on_duplicate} = $values;
      PTDEBUG && _d('Clause: on duplicate key update', $values);

      $query =~ s/\s+ON DUPLICATE KEY UPDATE.+//;
   }

   if ( my @into = ($query =~ m/
            (?:INTO\s+)?            # INTO, optional
            (.+?)\s+                # table ref
            (\([^\)]+\)\s+)?        # column list, optional
            (VALUE.?|SET|SELECT)\s+ # start of next caluse
         /xgci)
   ) {
      my $tbl  = shift @into;  # table ref
      $struct->{clauses}->{into} = $tbl;
      PTDEBUG && _d('Clause: into', $tbl);

      my $cols = shift @into;  # columns, maybe
      if ( $cols ) {
         $cols =~ s/[\(\)]//g;
         $struct->{clauses}->{columns} = $cols;
         PTDEBUG && _d('Clause: columns', $cols);
      }

      my $next_clause = lc(shift @into);  # VALUES, SET or SELECT
      die "INSERT/REPLACE without clause after table: $query"
         unless $next_clause;
      $next_clause = 'values' if $next_clause eq 'value';
      my ($values) = ($query =~ m/\G(.+)/gci);
      die "INSERT/REPLACE without values: $query" unless $values;
      $struct->{clauses}->{$next_clause} = $values;
      PTDEBUG && _d('Clause:', $next_clause, $values);
   }

   ($struct->{unknown}) = ($query =~ m/\G(.+)/);

   return $struct;
}
{
   no warnings;
   *parse_replace = \&parse_insert;
}

sub parse_select {
   my ( $self, $query ) = @_;

   my @keywords;
   my $final_keywords = qr/(FOR UPDATE|LOCK IN SHARE MODE)/i; 
   1 while $query =~ s/\s+$final_keywords/(push @keywords, $1), ''/gie;

   my $keywords = qr/(
       ALL
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
   )/xi;
   my $clauses = qr/(
       FROM
      |WHERE
      |GROUP\sBY
      |HAVING
      |ORDER\sBY
      |LIMIT
      |PROCEDURE
      |INTO OUTFILE
   )/xi;
   my $struct = $self->_parse_query($query, $keywords, 'columns', $clauses);

   map { s/ /_/g; $struct->{keywords}->{lc $_} = 1; } @keywords;

   return $struct;
}

sub parse_update {
   my $keywords = qr/(LOW_PRIORITY|IGNORE)/i;
   my $clauses  = qr/(SET|WHERE|ORDER BY|LIMIT)/i;
   return _parse_query(@_, $keywords, 'tables', $clauses);

}

sub parse_create {
   my ($self, $query) = @_;
   my ($obj, $name) = $query =~ m/
      (\S+)\s+
      (?:IF NOT EXISTS\s+)?
      (\S+)
   /xi;
   return {
      object  => lc $obj,
      name    => $name,
      unknown => undef,
   };
}

sub parse_from {
   my ( $self, $from ) = @_;
   return unless $from;
   PTDEBUG && _d('Parsing FROM', $from);

   my $using_cols;
   ($from, $using_cols) = $self->remove_using_columns($from);

   my $funcs;
   ($from, $funcs) = $self->remove_functions($from);

   my $comma_join = qr/(?>\s*,\s*)/;
   my $ansi_join  = qr/(?>
     \s+
     (?:(?:INNER|CROSS|STRAIGHT_JOIN|LEFT|RIGHT|OUTER|NATURAL)\s+)*
     JOIN
     \s+
   )/xi;

   my @tbls;     # all table refs, a hashref for each
   my $tbl_ref;  # current table ref hashref
   my $join;     # join info hahsref for current table ref
   foreach my $thing ( split /($comma_join|$ansi_join)/io, $from ) {
      die "Error parsing FROM clause" unless $thing;

      $thing =~ s/^\s+//;
      $thing =~ s/\s+$//;
      PTDEBUG && _d('Table thing:', $thing);

      if ( $thing =~ m/\s+(?:ON|USING)\s+/i ) {
         PTDEBUG && _d("JOIN condition");
         my ($tbl_ref_txt, $join_condition_verb, $join_condition_value)
            = $thing =~ m/^(.+?)\s+(ON|USING)\s+(.+)/i;

         $tbl_ref = $self->parse_table_reference($tbl_ref_txt);

         $join->{condition} = lc $join_condition_verb;
         if ( $join->{condition} eq 'on' ) {
            $join->{where} = $self->parse_where($join_condition_value, $funcs);
         }
         else { # USING
            $join->{columns} = $self->_parse_csv(shift @$using_cols);
         }
      }
      elsif ( $thing =~ m/(?:,|JOIN)/i ) {
         if ( $join ) {
            $tbl_ref->{join} = $join;
         }
         push @tbls, $tbl_ref;
         PTDEBUG && _d("Complete table reference:", Dumper($tbl_ref));

         $tbl_ref = undef;
         $join    = {};

         $join->{to} = $tbls[-1]->{tbl};
         if ( $thing eq ',' ) {
            $join->{type} = 'inner';
            $join->{ansi} = 0;
         }
         else { # ansi join
            my $type = $thing =~ m/^(.+?)\s+JOIN$/i ? lc $1 : 'inner';
            $join->{type} = $type;
            $join->{ansi} = 1;
         }
      }
      else {
         $tbl_ref = $self->parse_table_reference($thing);
         PTDEBUG && _d('Table reference:', Dumper($tbl_ref));
      }
   }

   if ( $tbl_ref ) {
      if ( $join ) {
         $tbl_ref->{join} = $join;
      }
      push @tbls, $tbl_ref;
      PTDEBUG && _d("Complete table reference:", Dumper($tbl_ref));
   }

   return \@tbls;
}

sub parse_table_reference {
   my ( $self, $tbl_ref ) = @_;
   return unless $tbl_ref;
   PTDEBUG && _d('Parsing table reference:', $tbl_ref);
   my %tbl;

   if ( $tbl_ref =~ s/
         \s+(
            (?:FORCE|USE|INGORE)\s
            (?:INDEX|KEY)
            \s*\([^\)]+\)\s*
         )//xi)
   {
      $tbl{index_hint} = $1;
      PTDEBUG && _d('Index hint:', $tbl{index_hint});
   }

   if ( $tbl_ref =~ m/$table_ident/ ) {
      my ($db_tbl, $as, $alias) = ($1, $2, $3); # XXX
      my $ident_struct = $self->parse_identifier('table', $db_tbl);
      $alias =~ s/`//g if $alias;
      @tbl{keys %$ident_struct} = values %$ident_struct;
      $tbl{explicit_alias} = 1 if $as;
      $tbl{alias}          = $alias if $alias;
   }
   else {
      die "Table ident match failed";  # shouldn't happen
   }

   return \%tbl;
}
{
   no warnings;  # Why? See same line above.
   *parse_into   = \&parse_from;
   *parse_tables = \&parse_from;
}

sub parse_where {
   my ( $self, $where, $functions ) = @_;
   return unless $where;
   PTDEBUG && _d("Parsing WHERE", $where);

   my $op_symbol = qr/
      (?:
       <=(?:>)?
      |>=
      |<>
      |!=
      |<
      |>
      |=
   )/xi;
   my $op_verb = qr/
      (?:
          (?:(?:NOT\s)?LIKE)
         |(?:IS(?:\sNOT\s)?)
         |(?:(?:\sNOT\s)?BETWEEN)
         |(?:(?:NOT\s)?IN)
      )
   /xi;
   my $op_pat = qr/
   (
      (?>
          (?:$op_symbol)  # don't need spaces around the symbols, e.g.: col=1
         |(?:\s+$op_verb) # must have space before verb op, e.g.: col LIKE ...
      )
   )/x;

   my $offset = 0;
   my $pred   = "";
   my @pred;
   my @has_op;
   while ( $where =~ m/\b(and|or)\b/gi ) {
      my $pos = (pos $where) - (length $1);  # pos at and|or, not after

      $pred = substr $where, $offset, ($pos-$offset);
      push @pred, $pred;
      push @has_op, $pred =~ m/$op_pat/o ? 1 : 0;

      $offset = $pos;
   }
   $pred = substr $where, $offset;
   push @pred, $pred;
   push @has_op, $pred =~ m/$op_pat/o ? 1 : 0;
   PTDEBUG && _d("Predicate fragments:", Dumper(\@pred));
   PTDEBUG && _d("Predicate frags with operators:", @has_op);

   my $n = scalar @pred - 1;
   for my $i ( 1..$n ) {
      $i   *= -1;
      my $j = $i - 1;  # preceding pred frag

      next if $pred[$j] !~ m/\s+between\s+/i  && $self->_is_constant($pred[$i]);

      if ( !$has_op[$i] ) {
         $pred[$j] .= $pred[$i];
         $pred[$i]  = undef;
      }
   }
   PTDEBUG && _d("Predicate fragments joined:", Dumper(\@pred));

   for my $i ( 0..@pred ) {
      $pred = $pred[$i];
      next unless defined $pred;
      my $n_single_quotes = ($pred =~ tr/'//);
      my $n_double_quotes = ($pred =~ tr/"//);
      if ( ($n_single_quotes % 2) || ($n_double_quotes % 2) ) {
         $pred[$i]     .= $pred[$i + 1];
         $pred[$i + 1]  = undef;
      }
   }
   PTDEBUG && _d("Predicate fragments balanced:", Dumper(\@pred));

   my @predicates;
   foreach my $pred ( @pred ) {
      next unless defined $pred;
      $pred =~ s/^\s+//;
      $pred =~ s/\s+$//;
      my $conj;
      if ( $pred =~ s/^(and|or)\s+//i ) {
         $conj = lc $1;
      }
      my ($col, $op, $val) = $pred =~ m/^(.+?)$op_pat(.+)$/o;
      if ( !$col || !$op ) {
         if ( $self->_is_constant($pred) ) {
            $val = lc $pred;
         }
         else {
            die "Failed to parse WHERE condition: $pred";
         }
      }

      if ( $col ) {
         $col =~ s/\s+$//;
         $col =~ s/^\(+//;  # no unquoted column name begins with (
      }
      if ( $op ) {
         $op  =  lc $op;
         $op  =~ s/^\s+//;
         $op  =~ s/\s+$//;
      }
      $val =~ s/^\s+//;
      
      if ( ($op || '') !~ m/IN/i && $val !~ m/^\w+\([^\)]+\)$/ ) {
         $val =~ s/\)+$//;
      }

      if ( $val =~ m/NULL|TRUE|FALSE/i ) {
         $val = lc $val;
      }

      if ( $functions ) {
         $col = shift @$functions if $col =~ m/__FUNC\d+__/;
         $val = shift @$functions if $val =~ m/__FUNC\d+__/;
      }

      push @predicates, {
         predicate => $conj,
         left_arg  => $col,
         operator  => $op,
         right_arg => $val,
      };
   }

   return \@predicates;
}

sub _is_constant {
   my ( $self, $val ) = @_;
   return 0 unless defined $val;
   $val =~ s/^\s*(?:and|or)\s+//;
   return
      $val =~ m/^\s*(?:TRUE|FALSE)\s*$/i || $val =~ m/^\s*-?\d+\s*$/ ? 1 : 0;
}

sub parse_having {
   my ( $self, $having ) = @_;
   return $having;
}

sub parse_group_by {
   my ( $self, $group_by ) = @_;
   return unless $group_by;
   PTDEBUG && _d('Parsing GROUP BY', $group_by);

   my $with_rollup = $group_by =~ s/\s+WITH ROLLUP\s*//i;

   my $idents = $self->parse_identifiers( $self->_parse_csv($group_by) );

   $idents->{with_rollup} = 1 if $with_rollup;

   return $idents;
}

sub parse_order_by {
   my ( $self, $order_by ) = @_;
   return unless $order_by;
   PTDEBUG && _d('Parsing ORDER BY', $order_by);
   my $idents = $self->parse_identifiers( $self->_parse_csv($order_by) );
   return $idents;
}

sub parse_limit {
   my ( $self, $limit ) = @_;
   return unless $limit;
   my $struct = {
      row_count => undef,
   };
   if ( $limit =~ m/(\S+)\s+OFFSET\s+(\S+)/i ) {
      $struct->{explicit_offset} = 1;
      $struct->{row_count}       = $1;
      $struct->{offset}          = $2;
   }
   else {
      my ($offset, $cnt) = $limit =~ m/(?:(\S+),\s+)?(\S+)/i;
      $struct->{row_count} = $cnt;
      $struct->{offset}    = $offset if defined $offset;
   }
   return $struct;
}

sub parse_values {
   my ( $self, $values ) = @_;
   return unless $values;
   $values =~ s/^\s*\(//;
   $values =~ s/\s*\)//;
   my $vals = $self->_parse_csv(
      $values,
      quoted_values => 1,
      remove_quotes => 0,
   );
   return $vals;
}

sub parse_set {
   my ( $self, $set ) = @_;
   PTDEBUG && _d("Parse SET", $set);
   return unless $set;
   my $vals = $self->_parse_csv($set);
   return unless $vals && @$vals;

   my @set;
   foreach my $col_val ( @$vals ) {
      my ($col, $val)  = $col_val =~ m/^([^=]+)\s*=\s*(.+)/;
      my $ident_struct = $self->parse_identifier('column', $col);
      my $set_struct   = {
         %$ident_struct,
         value => $val,
      };
      PTDEBUG && _d("SET:", Dumper($set_struct));
      push @set, $set_struct;
   }
   return \@set;
}

sub _parse_csv {
   my ( $self, $vals, %args ) = @_;
   return unless $vals;

   my @vals;
   if ( $args{quoted_values} ) {
      my $quote_char   = '';
      VAL:
      foreach my $val ( split(',', $vals) ) {
         PTDEBUG && _d("Next value:", $val);
         if ( $quote_char ) {
            PTDEBUG && _d("Value is part of previous quoted value");
            $vals[-1] .= ",$val";

            if ( $val =~ m/[^\\]*$quote_char$/ ) {
               if ( $args{remove_quotes} ) {
                  $vals[-1] =~ s/^\s*$quote_char//;
                  $vals[-1] =~ s/$quote_char\s*$//;
               }
               PTDEBUG && _d("Previous quoted value is complete:", $vals[-1]);
               $quote_char = '';
            }

            next VAL;
         }

         $val =~ s/^\s+//;

         if ( $val =~ m/^(['"])/ ) {
            PTDEBUG && _d("Value is quoted");
            $quote_char = $1;  # XXX
            if ( $val =~ m/.$quote_char$/ ) {
               PTDEBUG && _d("Value is complete");
               $quote_char = '';
               if ( $args{remove_quotes} ) {
                  $vals[-1] =~ s/^\s*$quote_char//;
                  $vals[-1] =~ s/$quote_char\s*$//;
               }
            }
            else {
               PTDEBUG && _d("Quoted value is not complete");
            }
         }
         else {
            $val =~ s/\s+$//;
         }

         PTDEBUG && _d("Saving value", ($quote_char ? "fragment" : ""));
         push @vals, $val;
      }
   }
   else {
      @vals = map { s/^\s+//; s/\s+$//; $_ } split(',', $vals);
   }

   return \@vals;
}
{
   no warnings;  # Why? See same line above.
   *parse_on_duplicate = \&_parse_csv;
}

sub parse_columns {
   my ( $self, $cols ) = @_;
   PTDEBUG && _d('Parsing columns list:', $cols);

   my @cols;
   pos $cols = 0;
   while (pos $cols < length $cols) {
      if ($cols =~ m/\G\s*$column_ident\s*(?>,|\Z)/gcxo) {
         my ($db_tbl_col, $as, $alias) = ($1, $2, $3); # XXX
         my $ident_struct = $self->parse_identifier('column', $db_tbl_col);
         $alias =~ s/`//g if $alias;
         my $col_struct = {
            %$ident_struct,
            ($as    ? (explicit_alias => 1)      : ()),
            ($alias ? (alias          => $alias) : ()),
         };
         push @cols, $col_struct;
      }
      else {
         die "Column ident match failed";  # shouldn't happen
      }
   }

   return \@cols;
}

sub remove_subqueries {
   my ( $self, $query ) = @_;

   my @start_pos;
   while ( $query =~ m/(\(SELECT )/gi ) {
      my $pos = (pos $query) - (length $1);
      push @start_pos, $pos;
   }

   @start_pos = reverse @start_pos;
   my @end_pos;
   for my $i ( 0..$#start_pos ) {
      my $closed = 0;
      pos $query = $start_pos[$i];
      while ( $query =~ m/([\(\)])/cg ) {
         my $c = $1;
         $closed += ($c eq '(' ? 1 : -1);
         last unless $closed;
      }
      push @end_pos, pos $query;
   }

   my @subqueries;
   my $len_adj = 0;
   my $n    = 0;
   for my $i ( 0..$#start_pos ) {
      PTDEBUG && _d('Query:', $query);
      my $offset = $start_pos[$i];
      my $len    = $end_pos[$i] - $start_pos[$i] - $len_adj;
      PTDEBUG && _d("Subquery $n start", $start_pos[$i],
            'orig end', $end_pos[$i], 'adj', $len_adj, 'adj end',
            $offset + $len, 'len', $len);

      my $struct   = {};
      my $token    = '__SQ' . $n . '__';
      my $subquery = substr($query, $offset, $len, $token);
      PTDEBUG && _d("Subquery $n:", $subquery);

      my $outer_start = $start_pos[$i + 1];
      my $outer_end   = $end_pos[$i + 1];
      if (    $outer_start && ($outer_start < $start_pos[$i])
           && $outer_end   && ($outer_end   > $end_pos[$i]) ) {
         PTDEBUG && _d("Subquery $n nested in next subquery");
         $len_adj += $len - length $token;
         $struct->{nested} = $i + 1;
      }
      else {
         PTDEBUG && _d("Subquery $n not nested");
         $len_adj = 0;
         if ( $subqueries[-1] && $subqueries[-1]->{nested} ) {
            PTDEBUG && _d("Outermost subquery");
         }
      }

      if ( $query =~ m/(?:=|>|<|>=|<=|<>|!=|<=>)\s*$token/ ) {
         $struct->{context} = 'scalar';
      }
      elsif ( $query =~ m/\b(?:IN|ANY|SOME|ALL|EXISTS)\s*$token/i ) {
         if ( $query !~ m/\($token\)/ ) {
            $query =~ s/$token/\($token\)/;
            $len_adj -= 2 if $struct->{nested};
         }
         $struct->{context} = 'list';
      }
      else {
         $struct->{context} = 'identifier';
      }
      PTDEBUG && _d("Subquery $n context:", $struct->{context});

      $subquery =~ s/^\s*\(//;
      $subquery =~ s/\s*\)\s*$//;

      $struct->{query} = $subquery;
      push @subqueries, $struct;
      $n++;
   }

   return $query, @subqueries;
}

sub remove_using_columns {
   my ($self, $from) = @_;
   return unless $from;
   PTDEBUG && _d('Removing cols from USING clauses');
   my $using = qr/
      \bUSING
      \s*
      \(
         ([^\)]+)
      \)
   /xi;
   my @cols;
   $from =~ s/$using/push @cols, $1; "USING ($#cols)"/eg;
   PTDEBUG && _d('FROM:', $from, Dumper(\@cols));
   return $from, \@cols;
}

sub replace_function {
   my ($func, $funcs) = @_;
   my ($func_name) = $func =~ m/^(\w+)/;
   if ( !$ignore_function{uc $func_name} ) {
      my $n = scalar @$funcs;
      push @$funcs, $func;
      return "__FUNC${n}__";
   }
   return $func;
}

sub remove_functions {
   my ($self, $clause) = @_;
   return unless $clause;
   PTDEBUG && _d('Removing functions from clause:', $clause);
   my @funcs;
   $clause =~ s/$function_ident/replace_function($1, \@funcs)/eg;
   PTDEBUG && _d('Function-stripped clause:', $clause, Dumper(\@funcs));
   return $clause, \@funcs;
}

sub parse_identifiers {
   my ( $self, $idents ) = @_;
   return unless $idents;
   PTDEBUG && _d("Parsing identifiers");

   my @ident_parts;
   foreach my $ident ( @$idents ) {
      PTDEBUG && _d("Identifier:", $ident);
      my $parts = {};

      if ( $ident =~ s/\s+(ASC|DESC)\s*$//i ) {
         $parts->{sort} = uc $1;  # XXX
      }

      if ( $ident =~ m/^\d+$/ ) {      # Position like 5
         PTDEBUG && _d("Positional ident");
         $parts->{position} = $ident;
      }
      elsif ( $ident =~ m/^\w+\(/ ) {  # Function like MIN(col)
         PTDEBUG && _d("Expression ident");
         my ($func, $expr) = $ident =~ m/^(\w+)\(([^\)]*)\)/;
         $parts->{function}   = uc $func;
         $parts->{expression} = $expr if $expr;
      }
      else {                           # Ref like (table.)column
         PTDEBUG && _d("Table/column ident");
         my ($tbl, $col)  = $self->split_unquote($ident);
         $parts->{table}  = $tbl if $tbl;
         $parts->{column} = $col;
      }
      push @ident_parts, $parts;
   }

   return \@ident_parts;
}

sub parse_identifier {
   my ( $self, $type, $ident ) = @_;
   return unless $type && $ident;
   PTDEBUG && _d("Parsing", $type, "identifier:", $ident);

   if ( $ident =~ m/^\w+\(/ ) {  # Function like MIN(col)
      my ($func, $expr) = $ident =~ m/^(\w+)\(([^\)]*)\)/;
      PTDEBUG && _d('Function', $func, 'arg', $expr);
      return { col => $ident } unless $expr;  # NOW()
      $ident = $expr;  # col from MAX(col)
   }

   my %ident_struct;
   my @ident_parts = map { s/`//g; $_; } split /[.]/, $ident;
   if ( @ident_parts == 3 ) {
      @ident_struct{qw(db tbl col)} = @ident_parts;
   }
   elsif ( @ident_parts == 2 ) {
      my @parts_for_type = $type eq 'column' ? qw(tbl col)
                         : $type eq 'table'  ? qw(db  tbl)
                         : die "Invalid identifier type: $type";
      @ident_struct{@parts_for_type} = @ident_parts;
   }
   elsif ( @ident_parts == 1 ) {
      my $part = $type eq 'column' ? 'col' : 'tbl';
      @ident_struct{($part)} = @ident_parts;
   }
   else {
      die "Invalid number of parts in $type reference: $ident";
   }
   
   if ( $self->{SchemaQualifier} ) {
      if ( $type eq 'column' && !$ident_struct{tbl} ) {
         my $qcol = $self->{SchemaQualifier}->qualify_column(
            column => $ident_struct{col},
         );
         $ident_struct{db}  = $qcol->{db}  if $qcol->{db};
         $ident_struct{tbl} = $qcol->{tbl} if $qcol->{tbl};
      }
      elsif ( $type eq 'table' && !$ident_struct{db} ) {
         my $db = $self->{SchemaQualifier}->get_database_for_table(
            table => $ident_struct{tbl},
         );
         $ident_struct{db} = $db if $db;
      }
   }

   PTDEBUG && _d($type, "identifier struct:", Dumper(\%ident_struct));
   return \%ident_struct;
}

sub split_unquote {
   my ( $self, $db_tbl, $default_db ) = @_;
   $db_tbl =~ s/`//g;
   my ( $db, $tbl ) = split(/[.]/, $db_tbl);
   if ( !$tbl ) {
      $tbl = $db;
      $db  = $default_db;
   }
   return ($db, $tbl);
}

sub is_identifier {
   my ( $self, $thing ) = @_;

   return 0 unless $thing;

   return 0 if $thing =~ m/\s*['"]/;

   return 0 if $thing =~ m/^\s*\d+(?:\.\d+)?\s*$/;

   return 0 if $thing =~ m/^\s*(?>
       NULL
      |DUAL
   )\s*$/xi;

   return 1 if $thing =~ m/^\s*$column_ident\s*$/;

   return 0;
}

sub set_SchemaQualifier {
   my ( $self, $sq ) = @_;
   $self->{SchemaQualifier} = $sq;
   return;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

} # package scope
1;

# ###########################################################################
# End SQLParser package
# ###########################################################################

# ###########################################################################
# TableUsage package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/TableUsage.pm
#   t/lib/TableUsage.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package TableUsage;

{ # package scope
use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw(QueryParser SQLParser);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   my $self = {
      constant_data_value => 'DUAL',

      %args,
   };

   return bless $self, $class;
}

sub get_table_usage {
   my ( $self, %args ) = @_;
   my @required_args = qw(query);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($query) = @args{@required_args};
   PTDEBUG && _d('Getting table access for',
      substr($query, 0, 100), (length $query > 100 ? '...' : ''));

   $self->{errors}          = [];
   $self->{query_reparsed}  = 0;     # only explain extended once
   $self->{ex_query_struct} = undef; # EXplain EXtended query struct
   $self->{schemas}         = undef; # db->tbl->cols from ^
   $self->{table_for}       = undef; # table alias from ^

   my $tables;
   my $query_struct;
   eval {
      $query_struct = $self->{SQLParser}->parse($query);
   };
   if ( $EVAL_ERROR ) {
      PTDEBUG && _d('Failed to parse query with SQLParser:', $EVAL_ERROR);
      if ( $EVAL_ERROR =~ m/Cannot parse/ ) {
         $tables = $self->_get_tables_used_from_query_parser(%args);
      }
      else {
         die $EVAL_ERROR;
      }
   }
   else {
      $tables = $self->_get_tables_used_from_query_struct(
         query_struct => $query_struct,
         %args,
      );
   }

   PTDEBUG && _d('Query table usage:', Dumper($tables));
   return $tables;
}

sub errors {
   my ($self) = @_;
   return $self->{errors};
}

sub _get_tables_used_from_query_parser {
   my ( $self, %args ) = @_;
   my @required_args = qw(query);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($query) = @args{@required_args};
   PTDEBUG && _d('Getting tables used from query parser');

   $query = $self->{QueryParser}->clean_query($query);
   my ($query_type) = $query =~ m/^\s*(\w+)\s+/;
   $query_type = uc $query_type;
   die "Query does not begin with a word" unless $query_type; # shouldn't happen

   if ( $query_type eq 'DROP' ) {
      my ($drop_what) = $query =~ m/^\s*DROP\s+(\w+)\s+/i;
      die "Invalid DROP query: $query" unless $drop_what;
      $query_type .= '_' . uc($drop_what);
   }

   my @tables_used;
   foreach my $table ( $self->{QueryParser}->get_tables($query) ) {
      $table =~ s/`//g;
      push @{$tables_used[0]}, {
         table   => $table,
         context => $query_type,
      };
   }

   return \@tables_used;
}

sub _get_tables_used_from_query_struct {
   my ( $self, %args ) = @_;
   my @required_args = qw(query_struct query);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($query_struct) = @args{@required_args};

   PTDEBUG && _d('Getting table used from query struct');

   my $query_type = uc $query_struct->{type};

   if ( $query_type eq 'CREATE' ) {
      PTDEBUG && _d('CREATE query');
      my $sel_tables;
      if ( my $sq_struct = $query_struct->{subqueries}->[0] ) {
         PTDEBUG && _d('CREATE query with SELECT');
         $sel_tables = $self->_get_tables_used_from_query_struct(
            %args,
            query        => $sq_struct->{query},
            query_struct => $sq_struct,
         );
      }
      return [
         [
            {
               context => 'CREATE',
               table   => $query_struct->{name},
            },
            ($sel_tables ? @{$sel_tables->[0]} : ()),
         ],
      ];
   }

   my $tables     = $self->_get_tables($query_struct);
   if ( !$tables || @$tables == 0 ) {
      PTDEBUG && _d("Query does not use any tables");
      return [
         [ { context => $query_type, table => $self->{constant_data_value} } ]
      ];
   }

   my ($where, $ambig);
   if ( $query_struct->{where} ) {
      ($where, $ambig) = $self->_get_tables_used_in_where(
         %args,
         tables  => $tables,
         where   => $query_struct->{where},
      );

      if ( $ambig && $self->{dbh} && !$self->{query_reparsed} ) {
         PTDEBUG && _d("Using EXPLAIN EXTENDED to disambiguate columns");
         if ( $self->_reparse_query(%args) ) {
            return $self->_get_tables_used_from_query_struct(%args);
         } 
         PTDEBUG && _d('Failed to disambiguate columns');
      }
   }

   my @tables_used;
   if ( $query_type eq 'UPDATE' && @{$query_struct->{tables}} > 1 ) {
      PTDEBUG && _d("Multi-table UPDATE");

      my @join_tables;
      foreach my $table ( @$tables ) {
         my $table = $self->_qualify_table_name(
            %args,
            tables => $tables,
            db     => $table->{db},
            tbl    => $table->{tbl},
         );
         my $table_usage = {
            context => 'JOIN',
            table   => $table,
         };
         PTDEBUG && _d("Table usage from TLIST:", Dumper($table_usage));
         push @join_tables, $table_usage;
      }
      if ( $where && $where->{joined_tables} ) {
         foreach my $table ( @{$where->{joined_tables}} ) {
            my $table_usage = {
               context => $query_type,
               table   => $table,
            };
            PTDEBUG && _d("Table usage from WHERE (implicit join):",
               Dumper($table_usage));
            push @join_tables, $table_usage;
         }
      }

      my @where_tables;
      if ( $where && $where->{filter_tables} ) {
         foreach my $table ( @{$where->{filter_tables}} ) {
            my $table_usage = {
               context => 'WHERE',
               table   => $table,
            };
            PTDEBUG && _d("Table usage from WHERE:", Dumper($table_usage));
            push @where_tables, $table_usage;
         }
      }

      my $set_tables = $self->_get_tables_used_in_set(
         %args,
         tables  => $tables,
         set     => $query_struct->{set},
      );
      foreach my $table ( @$set_tables ) {
         my @table_usage = (
            {  # the written table
               context => 'UPDATE',
               table   => $table->{table},
            },
            {  # source of data written to the written table
               context => 'SELECT',
               table   => $table->{value},
            },
         );
         PTDEBUG && _d("Table usage from UPDATE SET:", Dumper(\@table_usage));
         push @tables_used, [
            @table_usage,
            @join_tables,
            @where_tables,
         ];
      }
   } # multi-table UPDATE
   else {
      if ( $query_type eq 'SELECT' ) {
         my ($clist_tables, $ambig) = $self->_get_tables_used_in_columns(
            %args,
            tables  => $tables,
            columns => $query_struct->{columns},
         );

         if ( $ambig && $self->{dbh} && !$self->{query_reparsed} ) {
            PTDEBUG && _d("Using EXPLAIN EXTENDED to disambiguate columns");
            if ( $self->_reparse_query(%args) ) {
               return $self->_get_tables_used_from_query_struct(%args);
            } 
            PTDEBUG && _d('Failed to disambiguate columns');
         }

         foreach my $table ( @$clist_tables ) {
            my $table_usage = {
               context => 'SELECT',
               table   => $table,
            };
            PTDEBUG && _d("Table usage from CLIST:", Dumper($table_usage));
            push @{$tables_used[0]}, $table_usage;
         }
      }

      if ( @$tables > 1 || $query_type ne 'SELECT' ) {
         my $default_context = @$tables > 1 ? 'TLIST' : $query_type;
         foreach my $table ( @$tables ) {
            my $qualified_table = $self->_qualify_table_name(
               %args,
               tables => $tables,
               db     => $table->{db},
               tbl    => $table->{tbl},
            );

            my $context = $default_context;
            if ( $table->{join} && $table->{join}->{condition} ) {
                $context = 'JOIN';
               if ( $table->{join}->{condition} eq 'using' ) {
                  PTDEBUG && _d("Table joined with USING condition");
                  my $joined_table  = $self->_qualify_table_name(
                     %args,
                     tables => $tables,
                     tbl    => $table->{join}->{to},
                  );
                  $self->_change_context(
                     tables      => $tables,
                     table       => $joined_table,
                     tables_used => $tables_used[0],
                     old_context => 'TLIST',
                     new_context => 'JOIN',
                  );
               }
               elsif ( $table->{join}->{condition} eq 'on' ) {
                  PTDEBUG && _d("Table joined with ON condition");
                  my ($on_tables, $ambig) = $self->_get_tables_used_in_where(
                     %args,
                     tables => $tables,
                     where  => $table->{join}->{where},
                     clause => 'JOIN condition',  # just for debugging
                  );
                  PTDEBUG && _d("JOIN ON tables:", Dumper($on_tables));

                  if ( $ambig && $self->{dbh} && !$self->{query_reparsed} ) {
                     PTDEBUG && _d("Using EXPLAIN EXTENDED",
                        "to disambiguate columns");
                     if ( $self->_reparse_query(%args) ) {
                        return $self->_get_tables_used_from_query_struct(%args);
                     } 
                     PTDEBUG && _d('Failed to disambiguate columns'); 
                  }

                  foreach my $joined_table ( @{$on_tables->{joined_tables}} ) {
                     $self->_change_context(
                        tables      => $tables,
                        table       => $joined_table,
                        tables_used => $tables_used[0],
                        old_context => 'TLIST',
                        new_context => 'JOIN',
                     );
                  }
               }
               else {
                  warn "Unknown JOIN condition: $table->{join}->{condition}";
               }
            }

            my $table_usage = {
               context => $context,
               table   => $qualified_table,
            };
            PTDEBUG && _d("Table usage from TLIST:", Dumper($table_usage));
            push @{$tables_used[0]}, $table_usage;
         }
      }

      if ( $where && $where->{joined_tables} ) {
         foreach my $joined_table ( @{$where->{joined_tables}} ) {
            PTDEBUG && _d("Table joined implicitly in WHERE:", $joined_table);
            $self->_change_context(
               tables      => $tables,
               table       => $joined_table,
               tables_used => $tables_used[0],
               old_context => 'TLIST',
               new_context => 'JOIN',
            );
         }
      }

      if ( $query_type =~ m/(?:INSERT|REPLACE)/ ) {
         if ( $query_struct->{select} ) {
            PTDEBUG && _d("Getting tables used in INSERT-SELECT");
            my $select_tables = $self->_get_tables_used_from_query_struct(
               %args,
               query_struct => $query_struct->{select},
            );
            push @{$tables_used[0]}, @{$select_tables->[0]};
         }
         else {
            my $table_usage = {
               context => 'SELECT',
               table   => $self->{constant_data_value},
            };
            PTDEBUG && _d("Table usage from SET/VALUES:", Dumper($table_usage));
            push @{$tables_used[0]}, $table_usage;
         }
      }
      elsif ( $query_type eq 'UPDATE' ) {
         my $set_tables = $self->_get_tables_used_in_set(
            %args,
            tables => $tables,
            set    => $query_struct->{set},
         );
         foreach my $table ( @$set_tables ) {
            my $table_usage = {
               context => 'SELECT',
               table   => $table->{value_is_table} ? $table->{table}
                        :                            $self->{constant_data_value},
            };
            PTDEBUG && _d("Table usage from SET:", Dumper($table_usage));
            push @{$tables_used[0]}, $table_usage;
         }
      }

      if ( $where && $where->{filter_tables} ) {
         foreach my $table ( @{$where->{filter_tables}} ) {
            my $table_usage = {
               context => 'WHERE',
               table   => $table,
            };
            PTDEBUG && _d("Table usage from WHERE:", Dumper($table_usage));
            push @{$tables_used[0]}, $table_usage;
         }
      }
   }

   return \@tables_used;
}

sub _get_tables_used_in_columns {
   my ( $self, %args ) = @_;
   my @required_args = qw(tables columns);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($tables, $columns) = @args{@required_args};

   PTDEBUG && _d("Getting tables used in CLIST");
   my @tables;
   my $ambig = 0;  # found any ambiguous columns?
   if ( @$tables == 1 ) {
      PTDEBUG && _d("Single table SELECT:", $tables->[0]->{tbl});
      my $table = $self->_qualify_table_name(
         %args,
         db  => $tables->[0]->{db},
         tbl => $tables->[0]->{tbl},
      );
      @tables = ($table);
   }
   elsif ( @$columns == 1 && $columns->[0]->{col} eq '*' ) {
      if ( $columns->[0]->{tbl} ) {
         PTDEBUG && _d("SELECT all columns from one table");
         my $table = $self->_qualify_table_name(
            %args,
            db  => $columns->[0]->{db},
            tbl => $columns->[0]->{tbl},
         );
         @tables = ($table);
      }
      else {
         PTDEBUG && _d("SELECT all columns from all tables");
         foreach my $table ( @$tables ) {
            my $table = $self->_qualify_table_name(
               %args,
               tables => $tables,
               db     => $table->{db},
               tbl    => $table->{tbl},
            );
            push @tables, $table;
         }
      }
   }
   else {
      PTDEBUG && _d(scalar @$tables, "table SELECT");
      my %seen;
      my $colno = 0;
      COLUMN:
      foreach my $column ( @$columns ) {
         PTDEBUG && _d('Getting table for column', Dumper($column));
         if ( $column->{col} eq '*' && !$column->{tbl} ) {
            PTDEBUG && _d('Ignoring FUNC(*) column');
            $colno++;
            next;
         }
         $column = $self->_ex_qualify_column(
            col    => $column,
            colno  => $colno,
            n_cols => scalar @$columns,
         );
         if ( !$column->{tbl} ) {
            PTDEBUG && _d("Column", $column->{col}, "is not table-qualified;",
               "and query has multiple tables; cannot determine its table");
            $ambig++;
            next COLUMN;
         }
         my $table = $self->_qualify_table_name(
            %args,
            db  => $column->{db},
            tbl => $column->{tbl},
         );
         push @tables, $table if $table && !$seen{$table}++;
         $colno++;
      }
   }

   return (\@tables, $ambig);
}

sub _get_tables_used_in_where {
   my ( $self, %args ) = @_;
   my @required_args = qw(tables where);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($tables, $where) = @args{@required_args};
   my $sql_parser = $self->{SQLParser};

   PTDEBUG && _d("Getting tables used in", $args{clause} || 'WHERE');

   my %filter_tables;
   my %join_tables;
   my $ambig = 0;  # found any ambiguous tables?
   CONDITION:
   foreach my $cond ( @$where ) {
      PTDEBUG && _d("Condition:", Dumper($cond));
      my @tables;  # tables used in this condition
      my $n_vals        = 0;
      my $is_constant   = 0;
      my $unknown_table = 0;
      ARG:
      foreach my $arg ( qw(left_arg right_arg) ) {
         if ( !defined $cond->{$arg} ) {
            PTDEBUG && _d($arg, "is a constant value");
            $is_constant = 1;
            next ARG;
         }

         if ( $sql_parser->is_identifier($cond->{$arg}) ) {
            PTDEBUG && _d($arg, "is an identifier");
            my $ident_struct = $sql_parser->parse_identifier(
               'column',
               $cond->{$arg}
            );
            $ident_struct = $self->_ex_qualify_column(
               col       => $ident_struct,
               where_arg => $arg,
            );
            if ( !$ident_struct->{tbl} ) {
               if ( @$tables == 1 ) {
                  PTDEBUG && _d("Condition column is not table-qualified; ",
                     "using query's only table:", $tables->[0]->{tbl});
                  $ident_struct->{tbl} = $tables->[0]->{tbl};
               }
               else {
                  PTDEBUG && _d("Condition column is not table-qualified and",
                     "query has multiple tables; cannot determine its table");
                  if (  $cond->{$arg} !~ m/\w+\(/       # not a function
                     && $cond->{$arg} !~ m/^[\d.]+$/) { # not a number
                     $unknown_table = 1;
                  }
                  $ambig++;
                  next ARG;
               }
            }

            if ( !$ident_struct->{db} && @$tables == 1 && $tables->[0]->{db} ) {
               PTDEBUG && _d("Condition column is not database-qualified; ",
                  "using its table's database:", $tables->[0]->{db});
               $ident_struct->{db} = $tables->[0]->{db};
            }

            my $table = $self->_qualify_table_name(
               %args,
               %$ident_struct,
            );
            if ( $table ) {
               push @tables, $table;
            }
         }
         else {
            PTDEBUG && _d($arg, "is a value");
            $n_vals++;
         }
      }  # ARG

      if ( $is_constant || $n_vals == 2 ) {
         PTDEBUG && _d("Condition is a constant or two values");
         $filter_tables{$self->{constant_data_value}} = undef;
      }
      else {
         if ( @tables == 1 ) {
            if ( $unknown_table ) {
               PTDEBUG && _d("Condition joins table",
                  $tables[0], "to column from unknown table");
               $join_tables{$tables[0]} = undef;
            }
            else {
               PTDEBUG && _d("Condition filters table", $tables[0]);
               $filter_tables{$tables[0]} = undef;
            }
         }
         elsif ( @tables == 2 ) {
            PTDEBUG && _d("Condition joins tables",
               $tables[0], "and", $tables[1]);
            $join_tables{$tables[0]} = undef;
            $join_tables{$tables[1]} = undef;
         }
      }
   }  # CONDITION

   return (
      {
         filter_tables => [ sort keys %filter_tables ],
         joined_tables => [ sort keys %join_tables   ],
      },
      $ambig,
   );
}

sub _get_tables_used_in_set {
   my ( $self, %args ) = @_;
   my @required_args = qw(tables set);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($tables, $set) = @args{@required_args};
   my $sql_parser = $self->{SQLParser};

   PTDEBUG && _d("Getting tables used in SET");

   my @tables;
   if ( @$tables == 1 ) {
      my $table = $self->_qualify_table_name(
         %args,
         db  => $tables->[0]->{db},
         tbl => $tables->[0]->{tbl},
      );
      $tables[0] = {
         table => $table,
         value => $self->{constant_data_value}
      };
   }
   else {
      foreach my $cond ( @$set ) {
         next unless $cond->{tbl};
         my $table = $self->_qualify_table_name(
            %args,
            db  => $cond->{db},
            tbl => $cond->{tbl},
         );

         my $value          = $self->{constant_data_value};
         my $value_is_table = 0;
         if ( $sql_parser->is_identifier($cond->{value}) ) {
            my $ident_struct = $sql_parser->parse_identifier(
               'column',
               $cond->{value},
            );
            $value_is_table = 1;
            $value          = $self->_qualify_table_name(
               %args,
               db  => $ident_struct->{db},
               tbl => $ident_struct->{tbl},
            );
         }

         push @tables, {
            table          => $table,
            value          => $value,
            value_is_table => $value_is_table,
         };
      }
   }

   return \@tables;
}

sub _get_real_table_name {
   my ( $self, %args ) = @_;
   my @required_args = qw(tables name);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($tables, $name) = @args{@required_args};
   $name = lc $name;

   foreach my $table ( @$tables ) {
      if ( lc($table->{tbl}) eq $name
           || lc($table->{alias} || "") eq $name ) {
         PTDEBUG && _d("Real table name for", $name, "is", $table->{tbl});
         return $table->{tbl};
      }
   }
   PTDEBUG && _d("Table", $name, "does not exist in query");
   return;
}

sub _qualify_table_name {
   my ( $self, %args) = @_;
   my @required_args = qw(tables tbl);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($tables, $table) = @args{@required_args};

   PTDEBUG && _d("Qualifying table with database:", $table);

   my ($tbl, $db) = reverse split /[.]/, $table;

   if ( $self->{ex_query_struct} ) {
      $tables = $self->{ex_query_struct}->{from};
   }

   $tbl = $self->_get_real_table_name(tables => $tables, name => $tbl);
   return unless $tbl;  # shouldn't happen

   my $db_tbl;

   if ( $db ) {
      $db_tbl = "$db.$tbl";
   }
   elsif ( $args{db} ) {
      $db_tbl = "$args{db}.$tbl";
   }
   else {
      foreach my $tbl_info ( @$tables ) {
         if ( ($tbl_info->{tbl} eq $tbl) && $tbl_info->{db} ) {
            $db_tbl = "$tbl_info->{db}.$tbl";
            last;
         }
      }

      if ( !$db_tbl && $args{default_db} ) { 
         $db_tbl = "$args{default_db}.$tbl";
      }

      if ( !$db_tbl ) {
         PTDEBUG && _d("Cannot determine database for table", $tbl);
         $db_tbl = $tbl;
      }
   }

   PTDEBUG && _d("Table qualified with database:", $db_tbl);
   return $db_tbl;
}

sub _change_context {
   my ( $self, %args) = @_;
   my @required_args = qw(tables_used table old_context new_context tables);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($tables_used, $table, $old_context, $new_context) = @args{@required_args};
   PTDEBUG && _d("Change context of table", $table, "from", $old_context,
      "to", $new_context);
   foreach my $used_table ( @$tables_used ) {
      if (    $used_table->{table}   eq $table
           && $used_table->{context} eq $old_context ) {
         $used_table->{context} = $new_context;
         return;
      }
   }
   PTDEBUG && _d("Table", $table, "is not used; cannot set its context");
   return;
}

sub _explain_query {
   my ($self, $query, $db) = @_;
   my $dbh = $self->{dbh};

   my $sql;
   if ( $db ) {
      $sql = "USE `$db`";
      PTDEBUG && _d($dbh, $sql);
      $dbh->do($sql);
   }
  
   $self->{db_version} ||= VersionParser->new($dbh);
   if ( $self->{db_version} < '5.7.3' ) { 
      $sql = "EXPLAIN EXTENDED $query";
   }
   else {
      $sql = "EXPLAIN $query"; # EXTENDED is implicit as of 5.7.3
   }

   PTDEBUG && _d($dbh, $sql);
   eval {
      $dbh->do($sql);  # don't need the result
   };
   if ( $EVAL_ERROR ) {
      if ( $EVAL_ERROR =~ m/No database/i ) {
         PTDEBUG && _d($EVAL_ERROR);
         push @{$self->{errors}}, 'NO_DB_SELECTED';
         return;
      }
      die $EVAL_ERROR;
   }

   $sql = "SHOW WARNINGS";
   PTDEBUG && _d($dbh, $sql);
   my $warning = $dbh->selectrow_hashref($sql);
   PTDEBUG && _d(Dumper($warning));
   if (    ($warning->{level} || "") !~ m/Note/i
        || ($warning->{code}  || 0)  != 1003 ) {
      die "EXPLAIN EXTENDED failed:\n"
         . "  Level: " . ($warning->{level}   || "") . "\n"
         . "   Code: " . ($warning->{code}    || "") . "\n"
         . "Message: " . ($warning->{message} || "") . "\n";
   }

   return $self->ansi_to_legacy($warning->{message});
}

my $ansi_quote_re = qr/" [^"]* (?: "" [^"]* )* (?<=.) "/ismx;
sub ansi_to_legacy {
   my ($self, $sql) = @_;
   $sql =~ s/($ansi_quote_re)/ansi_quote_replace($1)/ge;
   return $sql;
}

sub ansi_quote_replace {
   my ($val) = @_;
   $val =~ s/^"|"$//g;
   $val =~ s/`/``/g;
   $val =~ s/""/"/g;
   return "`$val`";
}

sub _get_tables {
   my ( $self, $query_struct ) = @_;

   my $query_type = uc $query_struct->{type};
   my $tbl_refs   = $query_type =~ m/(?:SELECT|DELETE)/  ? 'from'
                  : $query_type =~ m/(?:INSERT|REPLACE)/ ? 'into'
                  : $query_type =~ m/UPDATE/             ? 'tables'
                  : die "Cannot find table references for $query_type queries";

   return $query_struct->{$tbl_refs};
}

sub _reparse_query {
   my ($self, %args) = @_;
   my @required_args = qw(query query_struct);
   my ($query, $query_struct) = @args{@required_args};
   PTDEBUG && _d("Reparsing query with EXPLAIN EXTENDED");

   $self->{query_reparsed} = 1;

   return unless uc($query_struct->{type}) eq 'SELECT';

   my $new_query = $self->_explain_query($query);
   return unless $new_query;  # failure

   my $schemas         = {};
   my $table_for       = $self->{table_for};
   my $ex_query_struct = $self->{SQLParser}->parse($new_query);

   map {
      if ( $_->{db} && $_->{tbl} ) {
         $schemas->{lc $_->{db}}->{lc $_->{tbl}} ||= {};
         if ( $_->{alias} ) {
            $table_for->{lc $_->{alias}} = {
               db  => lc $_->{db},
               tbl => lc $_->{tbl},
            };
         }
      }
   } @{$ex_query_struct->{from}};

   map {
      if ( $_->{db} && $_->{tbl} ) {
         $schemas->{lc $_->{db}}->{lc $_->{tbl}}->{lc $_->{col}} = 1;
      }
   } @{$ex_query_struct->{columns}};

   $self->{schemas}         = $schemas;
   $self->{ex_query_struct} = $ex_query_struct;

   return 1;  # success
}

sub _ex_qualify_column {
   my ($self, %args) = @_;
   my ($col, $colno, $n_cols, $where_arg) = @args{qw(col colno n_cols where_arg)};

   return $col unless $self->{ex_query_struct};
   my $ex = $self->{ex_query_struct};

   PTDEBUG && _d('Qualifying column',$col->{col},'with EXPLAIN EXTENDED query');

   return unless $col;

   return $col if $col->{db} && $col->{tbl};

   my $colname = lc $col->{col};

   if ( !$col->{tbl} ) {
      if ( $where_arg ) {
         PTDEBUG && _d('Searching WHERE conditions for column');
         CONDITION:
         foreach my $cond ( @{$ex->{where}} ) {
            if ( defined $cond->{$where_arg}
                 && $self->{SQLParser}->is_identifier($cond->{$where_arg}) ) {
               my $ident_struct = $cond->{"${where_arg}_ident_struct"};
               if ( !$ident_struct ) {
                  $ident_struct = $self->{SQLParser}->parse_identifier(
                     'column',
                     $cond->{$where_arg},
                  );
                  $cond->{"${where_arg}_ident_struct"} = $ident_struct;
               }
               if ( lc($ident_struct->{col}) eq $colname ) {
                  $col = $ident_struct;
                  last CONDITION;
               }
            }
         }
      }
      elsif ( defined $colno
           && $ex->{columns}->[$colno]
           && lc($ex->{columns}->[$colno]->{col}) eq $colname ) {
         PTDEBUG && _d('Exact match by col name and number');
         $col = $ex->{columns}->[$colno];
      }
      elsif ( defined $colno
              && scalar @{$ex->{columns}} == $n_cols ) {
         PTDEBUG && _d('Match by column number in CLIST');
         $col = $ex->{columns}->[$colno];
      }
      else {
         PTDEBUG && _d('Searching for unique column in every db.tbl');
         my ($uniq_db, $uniq_tbl);
         my $colcnt  = 0;
         my $schemas = $self->{schemas};
         DATABASE:
         foreach my $db ( keys %$schemas ) {
            TABLE:
            foreach my $tbl ( keys %{$schemas->{$db}} ) {
               if ( $schemas->{$db}->{$tbl}->{$colname} ) {
                  $uniq_db  = $db;
                  $uniq_tbl = $tbl;
                  last DATABASE if ++$colcnt > 1;
               }
            }
         }
         if ( $colcnt == 1 ) {
            $col->{db}  = $uniq_db;
            $col->{tbl} = $uniq_tbl;
         }
      }
   }

   if ( !$col->{db} && $col->{tbl} ) {
      PTDEBUG && _d('Column has table, needs db');
      if ( my $real_tbl = $self->{table_for}->{lc $col->{tbl}} ) {
         PTDEBUG && _d('Table is an alias');
         $col->{db}  = $real_tbl->{db};
         $col->{tbl} = $real_tbl->{tbl};
      }
      else {
         PTDEBUG && _d('Searching for unique table in every db');
         my $real_tbl = $self->_get_real_table_name(
            tables => $ex->{from},
            name   => $col->{tbl},
         );
         if ( $real_tbl ) {
            $real_tbl = lc $real_tbl;
            my $uniq_db;
            my $dbcnt   = 0;
            my $schemas = $self->{schemas};
            DATABASE:
            foreach my $db ( keys %$schemas ) {
               if ( exists $schemas->{$db}->{$real_tbl} ) {
                  $uniq_db  = $db;
                  last DATABASE if ++$dbcnt > 1;
               }
            }
            if ( $dbcnt == 1 ) {
               $col->{db}  = $uniq_db;
               $col->{tbl} = $real_tbl;
            }
         }
      }
   }

   PTDEBUG && _d('Qualified column:', Dumper($col));
   return $col;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

} # package scope
1;
}
# ###########################################################################
# End TableUsage package
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
# MysqldumpParser package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/MysqldumpParser.pm
#   t/lib/MysqldumpParser.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
package MysqldumpParser;

{ # package scope
use strict;
use warnings FATAL => 'all';

use English qw(-no_match_vars);
use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

use constant PTDEBUG => $ENV{PTDEBUG} || 0;

my $open_comment = qr{/\*!\d{5} };

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw();
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $self = {
      %args,
   };
   return bless $self, $class;
}

sub parse_create_tables {
   my ( $self, %args ) = @_;
   my @required_args = qw(file);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($file) = @args{@required_args};

   PTDEBUG && _d('Parsing CREATE TABLE from', $file);
   open my $fh, '<', $file
      or die "Cannot open $file: $OS_ERROR";

   local $INPUT_RECORD_SEPARATOR = '';

   my %schema;
   my $db = '';
   CHUNK:
   while (defined(my $chunk = <$fh>)) {
      PTDEBUG && _d('db:', $db, 'chunk:', $chunk);
      if ($chunk =~ m/Database: (\S+)/) {
         $db = $1; # XXX
         $db =~ s/^`//;  # strip leading `
         $db =~ s/`$//;  # and trailing `
         PTDEBUG && _d('New db:', $db);
      }
      elsif ($chunk =~ m/CREATE TABLE/) {
         PTDEBUG && _d('Chunk has CREATE TABLE');

         if ($chunk =~ m/DROP VIEW IF EXISTS/) {
            PTDEBUG && _d('Table is a VIEW, skipping');
            next CHUNK;
         }

         my ($create_table)
            = $chunk =~ m/^(?:$open_comment)?(CREATE TABLE.+?;)$/ms;
         if ( !$create_table ) {
            warn "Failed to parse CREATE TABLE from\n" . $chunk;
            next CHUNK;
         }
         $create_table =~ s/ \*\/;\Z/;/;  # remove end of version comment

         push @{$schema{$db}}, $create_table;
      }
      else {
         PTDEBUG && _d('Chunk has other data, ignoring');
      }
   }

   close $fh;

   return \%schema;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

} # package scope
1;

# ###########################################################################
# End MysqldumpParser package
# ###########################################################################

# ###########################################################################
# SchemaQualifier package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the SVN repository at,
#   lib/SchemaQualifier.pm
#   t/lib/SchemaQualifier.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
package SchemaQualifier;

{ # package scope
use strict;
use warnings FATAL => 'all';

use English qw(-no_match_vars);
use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw(TableParser Quoter);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $self = {
      %args,
      schema                => {},  # db > tbl > col
      duplicate_column_name => {},
      duplicate_table_name  => {},
   };
   return bless $self, $class;
}

sub schema {
   my ( $self ) = @_;
   return $self->{schema};
}

sub get_duplicate_column_names {
   my ( $self ) = @_;
   return keys %{$self->{duplicate_column_name}};
}

sub get_duplicate_table_names {
   my ( $self ) = @_;
   return keys %{$self->{duplicate_table_name}};
}

sub set_schema_from_mysqldump {
   my ( $self, %args ) = @_;
   my @required_args = qw(dump);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($dump) = @args{@required_args};

   my $schema = $self->{schema};
   my $tp     = $self->{TableParser};
   my %column_name;
   my %table_name;

   DATABASE:
   foreach my $db (keys %$dump) {
      if ( !$db ) {
         warn "Empty database from parsed mysqldump output";
         next DATABASE;
      }

      TABLE:
      foreach my $table_def ( @{$dump->{$db}} ) {
         if ( !$table_def ) {
            warn "Empty CREATE TABLE for database $db parsed from mysqldump output";
            next TABLE;
         }
         my $tbl_struct = $tp->parse($table_def);
         $schema->{$db}->{$tbl_struct->{name}} = $tbl_struct->{is_col};

         map { $column_name{$_}++ } @{$tbl_struct->{cols}};
         $table_name{$tbl_struct->{name}}++;
      }
   }

   map { $self->{duplicate_column_name}->{$_} = 1 }
   grep { $column_name{$_} > 1 }
   keys %column_name;

   map { $self->{duplicate_table_name}->{$_} = 1 }
   grep { $table_name{$_} > 1 }
   keys %table_name;

   PTDEBUG && _d('Schema:', Dumper($schema));
   return;
}

sub qualify_column {
   my ( $self, %args ) = @_;
   my @required_args = qw(column);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($column) = @args{@required_args};

   PTDEBUG && _d('Qualifying', $column);
   my ($col, $tbl, $db) = reverse map { s/`//g; $_ } split /[.]/, $column;
   PTDEBUG && _d('Column', $column, 'has db', $db, 'tbl', $tbl, 'col', $col);

   my %qcol = (
      db  => $db,
      tbl => $tbl,
      col => $col,
   );
   if ( !$qcol{tbl} ) {
      @qcol{qw(db tbl)} = $self->get_table_for_column(column => $qcol{col});
   }
   elsif ( !$qcol{db} ) {
      $qcol{db} = $self->get_database_for_table(table => $qcol{tbl});
   }
   else {
      PTDEBUG && _d('Column is already database-table qualified');
   }

   return \%qcol;
}

sub get_table_for_column {
   my ( $self, %args ) = @_;
   my @required_args = qw(column);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($col) = @args{@required_args};
   PTDEBUG && _d('Getting table for column', $col);

   if ( $self->{duplicate_column_name}->{$col} ) {
      PTDEBUG && _d('Column name is duplicate, cannot qualify it');
      return;
   }

   my $schema = $self->{schema};
   foreach my $db ( keys %{$schema} ) {
      foreach my $tbl ( keys %{$schema->{$db}} ) {
         if ( $schema->{$db}->{$tbl}->{$col} ) {
            PTDEBUG && _d('Column is in database', $db, 'table', $tbl);
            return $db, $tbl;
         }
      }
   }

   PTDEBUG && _d('Failed to find column in any table');
   return;
}

sub get_database_for_table {
   my ( $self, %args ) = @_;
   my @required_args = qw(table);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($tbl) = @args{@required_args};
   PTDEBUG && _d('Getting database for table', $tbl);
   
   if ( $self->{duplicate_table_name}->{$tbl} ) {
      PTDEBUG && _d('Table name is duplicate, cannot qualify it');
      return;
   }

   my $schema = $self->{schema};
   foreach my $db ( keys %{$schema} ) {
     if ( $schema->{$db}->{$tbl} ) {
       PTDEBUG && _d('Table is in database', $db);
       return $db;
     }
   }

   PTDEBUG && _d('Failed to find table in any database');
   return;
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

} # package scope
1;

# ###########################################################################
# End SchemaQualifier package
# ###########################################################################

# ###########################################################################
# This is a combination of modules and programs in one -- a runnable module.
# http://www.perl.com/pub/a/2006/07/13/lightning-articles.html?page=last
# Or, look it up in the Camel book on pages 642 and 643 in the 3rd edition.
#
# Check at the end of this package for the call to main() which actually runs
# the program.
# ###########################################################################
package pt_table_usage;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
use sigtrap 'handler', \&sig_int, 'normal-signals';
Transformers->import(qw(make_checksum));

my $oktorun = 1;

sub main {
   @ARGV    = @_;  # set global ARGV for this package
   $oktorun = 1;   # reset between tests else pipeline won't run

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
   # Connect to MySQl for --explain-extended.
   # ########################################################################
   my $explain_ext_dbh;
   if ( my $dsn = $o->get('explain-extended') ) {
      $explain_ext_dbh = get_cxn(
         dsn          => $dsn,
         OptionParser => $o,
         DSNParser    => $dp,
      );
   }

   # ########################################################################
   # Make common modules.
   # ########################################################################
   my $qp = new QueryParser();
   my $qr = new QueryRewriter(QueryParser => $qp);
   my $sp = new SQLParser();
   my $tu = new TableUsage(
      constant_data_value => $o->get('constant-data-value'),
      QueryParser         => $qp,
      SQLParser           => $sp,
      dbh                 => $explain_ext_dbh,
   );
   my %common_modules = (
      OptionParser  => $o,
      DSNParser     => $dp,
      QueryParser   => $qp,
      QueryRewriter => $qr,
   );

   # ########################################################################
   # Parse the --create-table-definitions files.
   # ########################################################################
   if ( my $files = $o->get('create-table-definitions') ) {
      my $q  = new Quoter();
      my $tp = new TableParser(Quoter => $q);
      my $sq = new SchemaQualifier(TableParser => $tp, Quoter => $q);

      my $dump_parser = new MysqldumpParser();
      FILE:
      foreach my $file ( @$files ) {
         my $dump = $dump_parser->parse_create_tables(file => $file);
         if ( !$dump || !keys %$dump ) {
            warn "No CREATE TABLE statements were found in $file";
            next FILE;
         }
         $sq->set_schema_from_mysqldump(dump => $dump); 
      }
      $sp->set_SchemaQualifier($sq);
   }

   # ########################################################################
   # Set up an array of callbacks.
   # ########################################################################
   my $pipeline_data = {
      # Add here any data to inject into the pipeline.
      # This hashref is $args in each pipeline process.
   };
   my $pipeline = new Pipeline(
      instrument        => 0,
      continue_on_error => $o->get('continue-on-error'),
   );

   { # prep
      $pipeline->add(
         name    => 'prep',
         process => sub {
            my ( $args ) = @_;
            # Stuff you'd like to do to make sure pipeline data is prepped
            # and ready to go...

            $args->{event} = undef;  # remove event from previous pass

            if ( $o->got('query') ) {
               if ( $args->{query} ) {
                  delete $args->{query};  # terminate
               }
               else {
                  $args->{query} = $o->get('query');  # analyze query once
               }
            }

            return $args;
         },
      );
   } # prep

   { # input
      my $fi        = new FileIterator();
      my $next_file = $fi->get_file_itr(@ARGV);
      my $input_fh; # the current input fh
      my $pr;       # Progress obj for ^

      $pipeline->add(
         name    => 'input',
         process => sub {
            my ( $args ) = @_;

            if ( $o->got('query') ) {
               PTDEBUG && _d("No input; using --query");
               return $args;
            }

            # Only get the next file when there's no fh or no more events in
            # the current fh.  This allows us to do collect-and-report cycles
            # (i.e. iterations) on huge files.  This doesn't apply to infinite
            # inputs because they don't set more_events false.
            if ( !$args->{input_fh} || !$args->{more_events} ) {
               if ( $args->{input_fh} ) {
                  close $args->{input_fh}
                     or die "Cannot close input fh: $OS_ERROR";
               }
               my ($fh, $filename, $filesize) = $next_file->();
               if ( $fh ) {
                  PTDEBUG && _d('Reading', $filename);

                  # Create callback to read next event.  Some inputs, like
                  # Processlist, may use something else but most next_event.
                  if ( my $read_time = $o->get('read-timeout') ) {
                     $args->{next_event}
                        = sub { return read_timeout($fh, $read_time); };
                  }
                  else {
                     $args->{next_event} = sub { return <$fh>; };
                  }
                  $args->{input_fh}    = $fh;
                  $args->{tell}        = sub { return tell $fh; };
                  $args->{more_events} = 1;

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
            $pr->update($args->{tell}) if $pr;
            return $args;
         },
      );
   } # input

   { # event
      if ( $o->got('query') ) {
         $pipeline->add(
            name    => '--query',
            process => sub {
               my ( $args ) = @_;
               if ( $args->{query} ) {
                  $args->{event}->{arg} = $args->{query};
               }
               return $args;
            },
         );
      }
      else {
         # Only slowlogs are supported, but if we want parse other formats,
         # just tweak the code below to be like pt-query-digest.
         my %alias_for = (
            slowlog   => ['SlowLogParser'],
         );
         my $type = ['slowlog'];
         $type    = $alias_for{$type->[0]} if $alias_for{$type->[0]};

         foreach my $module ( @$type ) {
            my $parser;
            eval {
               $parser = $module->new(
                  o => $o,
               );
            };
            if ( $EVAL_ERROR ) {
               die "Failed to load $module module: $EVAL_ERROR";
            }
            
            $pipeline->add(
               name    => ref $parser,
               process => sub {
                  my ( $args ) = @_;
                  if ( $args->{input_fh} ) {
                     my $event = $parser->parse_event(
                        event       => $args->{event},
                        next_event  => $args->{next_event},
                        tell        => $args->{tell},
                        oktorun     => sub { $args->{more_events} = $_[0]; },
                     );
                     if ( $event ) {
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
      }
   } # event

   { # terminator
      my $runtime = new Runtime(
         now      => sub { return time },
         run_time => $o->get('run-time'),
      );

      $pipeline->add(
         name    => 'terminator',
         process => sub {
            my ( $args ) = @_;

            # Stop running if there's no more input.
            if ( !$args->{input_fh} && !$args->{query} ) {
               PTDEBUG && _d("No more input, terminating pipeline");

               # This shouldn't happen, but I want to know if it does.
               warn "Event in the pipeline but no current input: "
                     . Dumper($args)
                  if $args->{event};

               $oktorun = 0;  # 2. terminate pipeline
               return;        # 1. exit pipeline early
            }

            # Stop running if --run-time has elapsed.
            if ( !$runtime->have_time() ) {
               PTDEBUG && _d("No more time, terminating pipeline");
               $oktorun = 0;  # 2. terminate pipeline
               return;        # 1. exit pipeline early
            }

            # There's input and time left so keep runnning...
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

   if ( $o->get('filter') ) { # filter
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

   { # table usage
      my $default_db = $o->get('database');
      my $id_attrib  = $o->get('id-attribute');
      my $queryno    = 1;

      $pipeline->add(
         name    => 'table usage',
         process => sub {
            my ( $args ) = @_;
            my $event = $args->{event};
            my $query = $event->{arg};
            return unless $query;

            my $query_id;
            if ( $id_attrib ) {
               if (   !exists $event->{$id_attrib}
                   || !defined $event->{$id_attrib}) {
                  PTDEBUG && _d("Event", $id_attrib, "attrib doesn't exist",
                     "or isn't defined, skipping");
                  return;
               }
               $query_id = $event->{$id_attrib};
            }
            else {
               $query_id = "0x" . make_checksum(
                  $qr->fingerprint($event->{original_arg} || $event->{arg}));
            }

            eval {
               my $table_usage = $tu->get_table_usage(
                  query      => $query,
                  default_db => $event->{db} || $default_db,
               );

               # TODO: I think this will happen for SELECT NOW(); i.e. not
               # sure what TableUsage returns for such queries.
               if ( !$table_usage || @$table_usage == 0 ) {
                  PTDEBUG && _d("Query does not use any tables");
                  return;
               }

               report_table_usage(
                  table_usage => $table_usage,
                  query_id    => $query_id,
                  TableUsage  => $tu,
                  %common_modules,
               ); 
            };
            if ( $EVAL_ERROR ) {
               if ( $EVAL_ERROR =~ m/Table .+? doesn't exist/ ) {
                  PTDEBUG && _d("Ignoring:", $EVAL_ERROR);
               }
               else {
                  warn "Error getting table usage: $EVAL_ERROR";
               }
               return;
            }

            return $args;
         },
      );
   } # table usage

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
   # Parse the input.
   # ########################################################################

   # Pump the pipeline until either no more input, or we're interrupted by
   # CTRL-C, or--this shouldn't happen--the pipeline causes an error.  All
   # work happens inside the pipeline via the procs we created above.
   my $exit_status = 0;
   eval {
      $pipeline->execute(
         oktorun       => \$oktorun,
         pipeline_data => $pipeline_data,
      );
   };
   if ( $EVAL_ERROR ) {
      warn "The pipeline caused an error: $EVAL_ERROR";
      $exit_status = 1;
   }
   PTDEBUG && _d("Pipeline data:", Dumper($pipeline_data));

   $explain_ext_dbh->disconnect() if $explain_ext_dbh;

   return $exit_status;
} # End main().

# ###########################################################################
# Subroutines.
# ###########################################################################
sub report_table_usage {
   my ( %args ) = @_;
   my @required_args = qw(table_usage query_id TableUsage);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($table_usage, $query_id, $tu) = @args{@required_args};
   PTDEBUG && _d("Reporting table usage");

   my $printed_errors = 0;
   my $target_tbl_num = 1;
   TABLE:
   foreach my $table ( @$table_usage ) {
      print "Query_id: $query_id." . ($target_tbl_num++) . "\n";

      if ( !$printed_errors ) {
         foreach my $error ( @{$tu->errors()} ) {
            print "ERROR $error\n";
         }
      }

      USAGE:
      foreach my $usage ( @$table ) {
         die "Invalid table usage: " . Dumper($usage)
            unless defined $usage->{context} && defined $usage->{table};

         print "$usage->{context} $usage->{table}\n";
      }
      print "\n";
   }

   return;
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
   $dbh->{FetchHashKeyName} = 'NAME_lc';
   return $dbh;
}

sub sig_int {
   my ( $signal ) = @_;
   if ( $oktorun ) {
      print STDERR "# Caught SIG$signal.\n";
      $oktorun = 0;
   }
   else {
      print STDERR "# Exiting on SIG$signal.\n";
      exit(1);
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

pt-table-usage - Analyze how queries use tables.

=head1 SYNOPSIS

Usage: pt-table-usage [OPTIONS] [FILES]

pt-table-usage reads queries from a log and analyzes how they use tables.  If no
FILE is specified, it reads STDIN.  It prints a report for each query.

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

pt-table-usage reads queries from a log and analyzes how they use tables.  The
log should be in MySQL's slow query log format.

Table usage is more than simply an indication of which tables the query reads or
writes.  It also indicates data flow: data in and data out.  The tool determines
the data flow by the contexts in which tables appear.  A single query can use a
table in several different contexts simultaneously.  The tool's output lists
every context for every table.  This CONTEXT-TABLE list indicates how data flows
between tables.  The L<"OUTPUT"> section lists the possible contexts and
describes how to read a table usage report.

The tool analyzes data flow down to the level of individual columns, so it is
helpful if columns are identified unambiguously in the query.  If a query uses
only one table, then all columns must be from that table, and there's no
difficulty.  But if a query uses multiple tables and the column names are not
table-qualified, then it is necessary to use C<EXPLAIN EXTENDED>, followed by
C<SHOW WARNINGS>, to determine to which tables the columns belong.

If the tool does not know the query's default database, which can occur when the
database is not printed in the log, then C<EXPLAIN EXTENDED> can fail. In this
case, you can specify a default database with L<"--database">. You can also use
the L<"--create-table-definitions"> option to help resolve ambiguities.

=head1 OUTPUT

The tool prints a usage report for each table in every query, similar to the
following:

  Query_id: 0x1CD27577D202A339.1
  UPDATE t1
  SELECT DUAL
  JOIN t1
  JOIN t2
  WHERE t1

  Query_id: 0x1CD27577D202A339.2
  UPDATE t2
  SELECT DUAL
  JOIN t1
  JOIN t2
  WHERE t1

The first line contains the query ID, which by default is the same as those
shown in pt-query-digest reports. It is an MD5 checksum of the query's
"fingerprint," which is what remains after removing literals, collapsing white
space, and a variety of other transformations. The query ID has two parts
separated by a period: the query ID and the table number. If you wish to use a
different value to identify the query, you can specify the L<"--id-attribute">
option.

The previous example shows two paragraphs for a single query, not two queries.
Note that the query ID is identical for the two, but the table number differs.
The table number increments by 1 for each table that the query updates.  Only
multi-table UPDATE queries can update multiple tables with a single query, so
the table number is 1 for all other types of queries.  (The tool does not
support multi-table DELETE queries.) The example output above is from this
query:

  UPDATE t1 AS a JOIN t2 AS b USING (id)
  SET a.foo="bar", b.foo="bat"
  WHERE a.id=1;

The C<SET> clause indicates that the query updates two tables: C<a> aliased as
C<t1>, and C<b> aliased as C<t2>.

After the first line, the tool prints a variable number of CONTEXT-TABLE lines.
Possible contexts are as follows:

=over

=item * SELECT

SELECT means that the query retrieves data from the table for one of two
reasons. The first is to be returned to the user as part of a result set. Only
SELECT queries return result sets, so the report always shows a SELECT context
for SELECT queries.  

The second case is when data flows to another table as part of an INSERT or
UPDATE.  For example, the UPDATE query in the example above has the usage:

  SELECT DUAL

This refers to:

  SET a.foo="bar", b.foo="bat"

The tool uses DUAL for any values that do not originate in a table, in this case
the literal values "bar" and "bat".  If that C<SET> clause were C<SET
a.foo=b.foo> instead, then the complete usage would be:

  Query_id: 0x1CD27577D202A339.1
  UPDATE t1
  SELECT t2
  JOIN t1
  JOIN t2
  WHERE t1

The presence of a SELECT context after another context, such as UPDATE or
INSERT, indicates where the UPDATE or INSERT retrieves its data.  The example
immediately above reflects an UPDATE query that updates rows in table C<t1>
with data from table C<t2>.

=item * Any other verb

Any other verb, such as INSERT, UPDATE, DELETE, etc. may be a context.  These
verbs indicate that the query modifies data in some way.  If a SELECT context
follows one of these verbs, then the query reads data from the SELECT table and
writes it to this table.  This happens, for example, with INSERT..SELECT or
UPDATE queries that use values from tables instead of constant values.

These query types are not supported: SET, LOAD, and multi-table DELETE.

=item * JOIN

The JOIN context lists tables that are joined, either with an explicit JOIN in
the FROM clause, or implicitly in the WHERE clause, such as C<t1.id = t2.id>.

=item * WHERE

The WHERE context lists tables that are used in the WHERE clause to filter
results.  This does not include tables that are implicitly joined in the
WHERE clause; those are listed as JOIN contexts.  For example:

  WHERE t1.id > 100 AND t1.id < 200 AND t2.foo IS NOT NULL

Results in:

  WHERE t1
  WHERE t2

The tool lists only distinct tables; that is why table C<t1> is listed only
once.

=item * TLIST

The TLIST context lists tables that the query accesses, but which do not appear
in any other context.  These tables are usually an implicit cartesian join.  For
example, the query C<SELECT * FROM t1, t2> results in:

  Query_id: 0xBDDEB6EDA41897A8.1
  SELECT t1
  SELECT t2
  TLIST t1
  TLIST t2

First of all, there are two SELECT contexts, because C<SELECT *> selects
rows from all tables; C<t1> and C<t2> in this case.  Secondly, the tables
are implicitly joined, but without any kind of join condition, which results
in a cartesian join as indicated by the TLIST context for each.

=back

=head1 EXIT STATUS

pt-table-usage exits 1 on any kind of error, or 0 if no errors.

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

=item --constant-data-value

type: string; default: DUAL

Table to print as the source for constant data (literals).  This is any data not
retrieved from tables (or subqueries, because subqueries are not supported).
This includes literal values such as strings ("foo") and numbers (42), or
functions such as C<NOW()>.  For example, in the query C<INSERT INTO t (c)
VALUES ('a')>, the string 'a' is constant data, so the table usage report is:

  INSERT t
  SELECT DUAL

The first line indicates that the query inserts data into table C<t>, and the
second line indicates that the inserted data comes from some constant value.

=item --[no]continue-on-error

default: yes

Continue to work even if there is an error.

=item --create-table-definitions

type: array

Read C<CREATE TABLE> definitions from this list of comma-separated files.
If you cannot use L<"--explain-extended"> to fully qualify table and column
names, you can save the output of C<mysqldump --no-data> to one or more files
and specify those files with this option.  The tool will parse all
C<CREATE TABLE> definitions from the files and use this information to
qualify table and column names.  If a column name appears in multiple tables,
or a table name appears in multiple databases, the ambiguities cannot be
resolved.

=item --daemonize

Fork to the background and detach from the shell.  POSIX
operating systems only.

=item --database

short form: -D; type: string

Default database.

=item --defaults-file

short form: -F; type: string

Only read mysql options from the given file.  You must give an absolute pathname.

=item --explain-extended

type: DSN

A server to execute EXPLAIN EXTENDED queries. This may be necessary to resolve
ambiguous (unqualified) column and table names.

=item --filter

type: string

Discard events for which this Perl code doesn't return true.

This option is a string of Perl code or a file containing Perl code that is
compiled into a subroutine with one argument: $event.  If the given value is a
readable file, then pt-table-usage reads the entire file and uses its contents
as the code.

Filters are implemented in the same fashion as in the pt-query-digest tool, so
please refer to its documentation for more information.

=item --help

Show help and exit.

=item --host

short form: -h; type: string

Connect to host.

=item --id-attribute

type: string

Identify each event using this attribute.  The default is to use a query ID,
which is an MD5 checksum of the query's fingerprint.

=item --log

type: string

Print all output to this file when daemonized.

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

=item --progress

type: array; default: time,30

Print progress reports to STDERR.  The value is a comma-separated list with two
parts.  The first part can be percentage, time, or iterations; the second part
specifies how often an update should be printed, in percentage, seconds, or
number of iterations.

=item --query

type: string

Analyze the specified query instead of reading a log file.

=item --read-timeout

type: time; default: 0

Wait this long for an event from the input; 0 to wait forever.

This option sets the maximum time to wait for an event from the input.  If an
event is not received after the specified time, the tool stops reading the
input and prints its reports.

This option requires the Perl POSIX module.

=item --run-time

type: time

How long to run before exiting.  The default is to run forever (you can
interrupt with CTRL-C).

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

copy: no

Default database.

=item * F

dsn: mysql_read_default_file; copy: no

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

dsn: mysql_socket; copy: no

Socket file to use for connection.

=item * u

dsn: user; copy: yes

User for login if not current user.

=back

=head1 ENVIRONMENT

The environment variable C<PTDEBUG> enables verbose debugging output to STDERR.
To enable debugging and capture all output to a file, run the tool like:

   PTDEBUG=1 pt-table-usage ... > FILE 2>&1

Be careful: debugging output is voluminous and can generate several megabytes
of output.

=head1 SYSTEM REQUIREMENTS

You need Perl, DBI, DBD::mysql, and some core packages that ought to be
installed in any reasonably new version of Perl.

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-table-usage>.

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

This program is copyright 2012-2018 Percona LLC and/or its affiliates.

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

pt-table-usage 3.3.0

=cut
