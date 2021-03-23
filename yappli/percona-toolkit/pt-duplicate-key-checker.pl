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
      Quoter
      TableParser
      DSNParser
      OptionParser
      KeySize
      DuplicateKeyFinder
      Daemon
      Schema
      SchemaIterator
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

   return $val if $args{is_float};

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
# KeySize package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/KeySize.pm
#   t/lib/KeySize.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package KeySize;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my $self = { %args };
   return bless $self, $class;
}

sub get_key_size {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(name cols tbl_name tbl_struct dbh) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $name = $args{name};
   my @cols = @{$args{cols}};
   my $dbh  = $args{dbh};

   $self->{explain} = '';
   $self->{query}   = '';
   $self->{error}   = '';

   if ( @cols == 0 ) {
      $self->{error} = "No columns for key $name";
      return;
   }

   my $key_exists = $self->_key_exists(%args);
   PTDEBUG && _d('Key', $name, 'exists in', $args{tbl_name}, ':',
      $key_exists ? 'yes': 'no');

   my $sql = 'EXPLAIN SELECT ' . join(', ', @cols)
           . ' FROM ' . $args{tbl_name}
           . ($key_exists ? " FORCE INDEX (`$name`)" : '')
           . ' WHERE ';
   my @where_cols;
   foreach my $col ( @cols ) {
      push @where_cols, "$col=1";
   }
   if ( scalar(@cols) == 1 && !$args{only_eq} ) {
      push @where_cols, "$cols[0]<>1";
   }
   $sql .= join(' OR ', @where_cols);
   $self->{query} = $sql;
   PTDEBUG && _d('sql:', $sql);

   my $explain;
   my $sth = $dbh->prepare($sql);
   eval { $sth->execute(); };
   if ( $EVAL_ERROR ) {
      chomp $EVAL_ERROR;
      $self->{error} = "Cannot get size of $name key: $EVAL_ERROR";
      return;
   }
   $explain = $sth->fetchrow_hashref();

   $self->{explain} = $explain;
   my $key_len      = $explain->{key_len};
   my $rows         = $explain->{rows};
   my $chosen_key   = $explain->{key};  # May differ from $name
   PTDEBUG && _d('MySQL chose key:', $chosen_key, 'len:', $key_len,
      'rows:', $rows);

   if ( $chosen_key && $key_len eq '0' ) {
      if ( $args{recurse} ) {
         $self->{error} = "key_len = 0 in EXPLAIN:\n"
                        . _explain_to_text($explain);
         return;
      }
      else {
         return $self->get_key_size(
            %args,
            only_eq => 1,
            recurse => 1,
         );
      }
   }

   my $key_size = 0;
   if ( $key_len && $rows ) {
      if ( $chosen_key =~ m/,/ && $key_len =~ m/,/ ) {
         $self->{error} = "MySQL chose multiple keys: $chosen_key";
         return;
      }
      $key_size = $key_len * $rows;
   }
   else {
      $self->{error} = "key_len or rows NULL in EXPLAIN:\n"
                     . _explain_to_text($explain);
      return;
   }

   return $key_size, $chosen_key;
}

sub query {
   my ( $self ) = @_;
   return $self->{query};
}

sub explain {
   my ( $self ) = @_;
   return _explain_to_text($self->{explain});
}

sub error {
   my ( $self ) = @_;
   return $self->{error};
}

sub _key_exists {
   my ( $self, %args ) = @_;
   return exists $args{tbl_struct}->{keys}->{ lc $args{name} } ? 1 : 0;
}

sub _explain_to_text {
   my ( $explain ) = @_;
   return join("\n",
      map { "$_: ".($explain->{$_} ? $explain->{$_} : 'NULL') }
      sort keys %$explain
   );
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
# End KeySize package
# ###########################################################################

# ###########################################################################
# DuplicateKeyFinder package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/DuplicateKeyFinder.pm
#   t/lib/DuplicateKeyFinder.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package DuplicateKeyFinder;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my $self = {};
   return bless $self, $class;
}

sub get_duplicate_keys {
   my ( $self, $keys,  %args ) = @_;
   die "I need a keys argument" unless $keys;
   my %keys = %$keys;  # Copy keys because we remove non-duplicates.
   my $primary_key;
   my @unique_keys;
   my @normal_keys;
   my @fulltext_keys;
   my @dupes;

   KEY:
   foreach my $keyname ( reverse sort keys %keys ) {
      my $key = $keys{$keyname};

      $key->{real_cols} = [ @{$key->{cols}} ];

      $key->{len_cols}  = length $key->{colnames};

      if ( $key->{name} eq 'PRIMARY'
           || ($args{clustered_key} && $key->{name} eq $args{clustered_key}) ) {
         $primary_key = $key;
         PTDEBUG && _d('primary key:', $key->{name});
         next KEY;
      }

      my $is_fulltext = $key->{type} eq 'FULLTEXT' ? 1 : 0;
      if ( $args{ignore_order} || $is_fulltext  ) {
         my $ordered_cols = join(',', sort(split(/,/, $key->{colnames})));
         PTDEBUG && _d('Reordered', $key->{name}, 'cols from',
            $key->{colnames}, 'to', $ordered_cols); 
         $key->{colnames} = $ordered_cols;
      }

      my $push_to = $key->{is_unique} ? \@unique_keys : \@normal_keys;
      if ( !$args{ignore_structure} ) {
         $push_to = \@fulltext_keys if $is_fulltext;
      }
      push @$push_to, $key; 
   }

   push @normal_keys, $self->unconstrain_keys($primary_key, \@unique_keys);

   if ( $primary_key ) {
      PTDEBUG && _d('Comparing PRIMARY KEY to UNIQUE keys');
      push @dupes,
         $self->remove_prefix_duplicates([$primary_key], \@unique_keys, %args);

      PTDEBUG && _d('Comparing PRIMARY KEY to normal keys');
      push @dupes,
         $self->remove_prefix_duplicates([$primary_key], \@normal_keys, %args);
   }

   PTDEBUG && _d('Comparing UNIQUE keys to normal keys');
   push @dupes,
      $self->remove_prefix_duplicates(\@unique_keys, \@normal_keys, %args);

   PTDEBUG && _d('Comparing normal keys');
   push @dupes,
      $self->remove_prefix_duplicates(\@normal_keys, \@normal_keys, %args);

   PTDEBUG && _d('Comparing FULLTEXT keys');
   push @dupes,
      $self->remove_prefix_duplicates(\@fulltext_keys, \@fulltext_keys, %args, exact_duplicates => 1);

   my $clustered_key = $args{clustered_key} ? $keys{$args{clustered_key}}
                     : undef;
   PTDEBUG && _d('clustered key:',
      $clustered_key ? ($clustered_key->{name}, $clustered_key->{colnames})
                     : 'none');
   if ( $clustered_key
        && $args{clustered}
        && $args{tbl_info}->{engine}
        && $args{tbl_info}->{engine} =~ m/InnoDB/i )
   {
      PTDEBUG && _d('Removing UNIQUE dupes of clustered key');
      push @dupes,
         $self->remove_clustered_duplicates($clustered_key, \@unique_keys, %args);

      PTDEBUG && _d('Removing ordinary dupes of clustered key');
      push @dupes,
         $self->remove_clustered_duplicates($clustered_key, \@normal_keys, %args);
   }

   return \@dupes;
}

sub get_duplicate_fks {
   my ( $self, $fks, %args ) = @_;
   die "I need a fks argument" unless $fks;
   my @fks = ();
   foreach my $key ( sort keys %$fks ) {
      push @fks, $fks->{$key};
   }
   my @dupes;

   foreach my $i ( 0..$#fks - 1 ) {
      next unless $fks[$i];
      foreach my $j ( $i+1..$#fks ) {
         next unless $fks[$j];

         my $i_cols  = join(',', sort @{$fks[$i]->{cols}} );
         my $j_cols  = join(',', sort @{$fks[$j]->{cols}} );
         my $i_pcols = join(',', sort @{$fks[$i]->{parent_cols}} );
         my $j_pcols = join(',', sort @{$fks[$j]->{parent_cols}} );

         if ( $fks[$i]->{parent_tblname} eq $fks[$j]->{parent_tblname}
              && $i_cols  eq $j_cols
              && $i_pcols eq $j_pcols ) {
            my $dupe = {
               key               => $fks[$j]->{name},
               cols              => [ @{$fks[$j]->{cols}} ],
               ddl               => $fks[$j]->{ddl},
               duplicate_of      => $fks[$i]->{name},
               duplicate_of_cols => [ @{$fks[$i]->{cols}} ],
               duplicate_of_ddl  => $fks[$i]->{ddl},
               reason            =>
                    "FOREIGN KEY $fks[$j]->{name} ($fks[$j]->{colnames}) "
                  . "REFERENCES $fks[$j]->{parent_tblname} "
                  . "($fks[$j]->{parent_colnames}) "
                  . 'is a duplicate of '
                  . "FOREIGN KEY $fks[$i]->{name} ($fks[$i]->{colnames}) "
                  . "REFERENCES $fks[$i]->{parent_tblname} "
                  ."($fks[$i]->{parent_colnames})",
               dupe_type         => 'fk',
            };
            push @dupes, $dupe;
            delete $fks[$j];
            $args{callback}->($dupe, %args) if $args{callback};
         }
      }
   }
   return \@dupes;
}

sub remove_prefix_duplicates {
   my ( $self, $left_keys, $right_keys, %args ) = @_;
   my @dupes;
   my $right_offset;
   my $last_left_key;
   my $last_right_key = scalar(@$right_keys) - 1;


   if ( $right_keys != $left_keys ) {

      @$left_keys = sort { lc($a->{colnames}) cmp lc($b->{colnames}) }
                    grep { defined $_; }
                    @$left_keys;
      @$right_keys = sort { lc($a->{colnames}) cmp lc($b->{colnames}) }
                     grep { defined $_; }
                    @$right_keys;

      $last_left_key = scalar(@$left_keys) - 1;

      $right_offset = 0;
   }
   else {

      @$left_keys = reverse sort { lc($a->{colnames}) cmp lc($b->{colnames}) }
                    grep { defined $_; }
                    @$left_keys;
      
      $last_left_key = scalar(@$left_keys) - 2;

      $right_offset = 1;
   }

   LEFT_KEY:
   foreach my $left_index ( 0..$last_left_key ) {
      next LEFT_KEY unless defined $left_keys->[$left_index];

      RIGHT_KEY:
      foreach my $right_index ( $left_index+$right_offset..$last_right_key ) {
         next RIGHT_KEY unless defined $right_keys->[$right_index];

         my $left_name      = $left_keys->[$left_index]->{name};
         my $left_cols      = $left_keys->[$left_index]->{colnames};
         my $left_len_cols  = $left_keys->[$left_index]->{len_cols};
         my $right_name     = $right_keys->[$right_index]->{name};
         my $right_cols     = $right_keys->[$right_index]->{colnames};
         my $right_len_cols = $right_keys->[$right_index]->{len_cols};

         PTDEBUG && _d('Comparing left', $left_name, '(',$left_cols,')',
            'to right', $right_name, '(',$right_cols,')');

         if (    substr($left_cols,  0, $right_len_cols)
              eq substr($right_cols, 0, $right_len_cols) ) {

            if ( $args{exact_duplicates} && ($right_len_cols<$left_len_cols) ) {
               PTDEBUG && _d($right_name, 'not exact duplicate of', $left_name);
               next RIGHT_KEY;
            }

            if ( exists $right_keys->[$right_index]->{unique_col} ) {
               PTDEBUG && _d('Cannot remove', $right_name,
                  'because is constrains col',
                  $right_keys->[$right_index]->{cols}->[0]);
               next RIGHT_KEY;
            }

            PTDEBUG && _d('Remove', $right_name);
            my $reason;
            if ( my $type = $right_keys->[$right_index]->{unconstrained} ) {
               $reason .= "Uniqueness of $right_name ignored because "
                  . $right_keys->[$right_index]->{constraining_key}->{name}
                  . " is a $type constraint\n"; 
            }
            my $exact_dupe = $right_len_cols < $left_len_cols ? 0 : 1;
            $reason .= $right_name
                     . ($exact_dupe ? ' is a duplicate of '
                                    : ' is a left-prefix of ')
                     . $left_name;
            my $dupe = {
               key               => $right_name,
               cols              => $right_keys->[$right_index]->{real_cols},
               ddl               => $right_keys->[$right_index]->{ddl},
               duplicate_of      => $left_name,
               duplicate_of_cols => $left_keys->[$left_index]->{real_cols},
               duplicate_of_ddl  => $left_keys->[$left_index]->{ddl},
               reason            => $reason,
               dupe_type         => $exact_dupe ? 'exact' : 'prefix',
            };
            push @dupes, $dupe;
            delete $right_keys->[$right_index];

            $args{callback}->($dupe, %args) if $args{callback};
         }
         else {
            PTDEBUG && _d($right_name, 'not left-prefix of', $left_name);
            next RIGHT_KEY;
         }
      } # RIGHT_KEY
   } # LEFT_KEY
   PTDEBUG && _d('No more keys');

   @$left_keys  = grep { defined $_; } @$left_keys;
   @$right_keys = grep { defined $_; } @$right_keys;

   return @dupes;
}

sub remove_clustered_duplicates {
   my ( $self, $ck, $keys, %args ) = @_;
   die "I need a ck argument"   unless $ck;
   die "I need a keys argument" unless $keys;
   my $ck_cols = $ck->{colnames};

   my @dupes;
   KEY:
   for my $i ( 0 .. @$keys - 1 ) {
      my $key = $keys->[$i]->{colnames};
      if ( $key =~ m/$ck_cols$/ ) {
         PTDEBUG && _d("clustered key dupe:", $keys->[$i]->{name},
            $keys->[$i]->{colnames});
         my $dupe = {
            key               => $keys->[$i]->{name},
            cols              => $keys->[$i]->{real_cols},
            ddl               => $keys->[$i]->{ddl},
            duplicate_of      => $ck->{name},
            duplicate_of_cols => $ck->{real_cols},
            duplicate_of_ddl  => $ck->{ddl},
            reason            => "Key $keys->[$i]->{name} ends with a "
                               . "prefix of the clustered index",
            dupe_type         => 'clustered',
            short_key         => $self->shorten_clustered_duplicate(
                                    $ck_cols,
                                    join(',', map { "`$_`" }
                                       @{$keys->[$i]->{real_cols}})
                                 ),
         };
         push @dupes, $dupe;
         delete $keys->[$i];
         $args{callback}->($dupe, %args) if $args{callback};
      }
   }
   PTDEBUG && _d('No more keys');

   @$keys = grep { defined $_; } @$keys;

   return @dupes;
}

sub shorten_clustered_duplicate {
   my ( $self, $ck_cols, $dupe_key_cols ) = @_;
   return $ck_cols if $ck_cols eq $dupe_key_cols;
   $dupe_key_cols =~ s/$ck_cols$//;
   $dupe_key_cols =~ s/,+$//;
   return $dupe_key_cols;
}

sub unconstrain_keys {
   my ( $self, $primary_key, $unique_keys ) = @_;
   die "I need a unique_keys argument" unless $unique_keys;
   my %unique_cols;
   my @unique_sets;
   my %unconstrain;
   my @unconstrained_keys;

   PTDEBUG && _d('Unconstraining redundantly unique keys');

   UNIQUE_KEY:
   foreach my $unique_key ( $primary_key, @$unique_keys ) {
      next unless $unique_key; # primary key may be undefined
      my $cols = $unique_key->{cols};
      if ( @$cols == 1 ) {
         if ( !exists $unique_cols{$cols->[0]} ) {
            PTDEBUG && _d($unique_key->{name}, 'defines unique column:',
               $cols->[0]);
            $unique_cols{$cols->[0]}  = $unique_key;
            $unique_key->{unique_col} = 1;
         }
         else {
            PTDEBUG && _d($unique_key->{name},
               'redundantly constrains unique column:', $cols->[0]);
            $unique_key->{exact_dupe} = 1;
            $unique_key->{constraining_key} = $unique_cols{$cols->[0]};
         }
      }
      else {
         local $LIST_SEPARATOR = '-';
         PTDEBUG && _d($unique_key->{name}, 'defines unique set:', @$cols);
         push @unique_sets, { cols => $cols, key => $unique_key };
      }
   }

   UNIQUE_SET:
   foreach my $unique_set ( @unique_sets ) {
      my $n_unique_cols = 0;
      COL:
      foreach my $col ( @{$unique_set->{cols}} ) {
         if ( exists $unique_cols{$col} ) {
            PTDEBUG && _d('Unique set', $unique_set->{key}->{name},
               'has unique col', $col);
            last COL if ++$n_unique_cols > 1;
            $unique_set->{constraining_key} = $unique_cols{$col};
         }
      }
      if ( $n_unique_cols && $unique_set->{key}->{name} ne 'PRIMARY' ) {
         PTDEBUG && _d('Will unconstrain unique set',
            $unique_set->{key}->{name},
            'because it is redundantly constrained by key',
            $unique_set->{constraining_key}->{name},
            '(',$unique_set->{constraining_key}->{colnames},')');
         $unconstrain{$unique_set->{key}->{name}}
            = $unique_set->{constraining_key};
      }
   }

   for my $i ( 0..(scalar @$unique_keys-1) ) {
      if ( exists $unconstrain{$unique_keys->[$i]->{name}} ) {
         PTDEBUG && _d('Unconstraining weak', $unique_keys->[$i]->{name});
         $unique_keys->[$i]->{unconstrained} = 'stronger';
         $unique_keys->[$i]->{constraining_key}
            = $unconstrain{$unique_keys->[$i]->{name}};
         push @unconstrained_keys, $unique_keys->[$i];
         delete $unique_keys->[$i];
      }
      elsif ( $unique_keys->[$i]->{exact_dupe} ) {
         PTDEBUG && _d('Unconstraining dupe', $unique_keys->[$i]->{name});
         $unique_keys->[$i]->{unconstrained} = 'duplicate';
         push @unconstrained_keys, $unique_keys->[$i];
         delete $unique_keys->[$i];
      }
   }

   PTDEBUG && _d('No more keys');
   return @unconstrained_keys;
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
# End DuplicateKeyFinder package
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
# Schema package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/Schema.pm
#   t/lib/Schema.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package Schema;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw();
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   my $self = {
      %args,
      schema  => {},  # keyed on db->tbl
   };
   return bless $self, $class;
}

sub get_schema {
   my ( $self ) = @_;
   return $self->{schema};
}

sub get_table {
   my ( $self, $db_name, $tbl_name ) = @_;
   if ( exists $self->{schema}->{$db_name}
        && exists $self->{schema}->{$db_name}->{$tbl_name} ) {
      return $self->{schema}->{$db_name}->{$tbl_name};
   }
   return;
}



sub add_schema_object {
   my ( $self, $schema_object ) = @_;
   die "I need a schema_object argument" unless $schema_object;

   my ($db, $tbl) = @{$schema_object}{qw(db tbl)};
   if ( !$db || !$tbl ) {
      warn "No database or table for schema object";
      return;
   }

   my $tbl_struct = $schema_object->{tbl_struct};
   if ( !$tbl_struct ) {
      warn "No table structure for $db.$tbl";
      return;
   }

   $self->{schema}->{lc $db}->{lc $tbl} = $schema_object;


   return;
}

sub find_column {
   my ( $self, %args ) = @_;
   my $ignore = $args{ignore};
   my $schema = $self->{schema};

   my ($col, $tbl, $db);
   if ( my $col_name = $args{col_name} ) {
      ($col, $tbl, $db) = reverse map { s/`//g; $_ } split /[.]/, $col_name;
      PTDEBUG && _d('Column', $col_name, 'has db', $db, 'tbl', $tbl,
         'col', $col);
   }
   else {
      ($col, $tbl, $db) = @args{qw(col tbl db)};
   }

   $db  = lc($db  || '');
   $tbl = lc($tbl || '');
   $col = lc($col || '');

   if ( !$col ) {
      PTDEBUG && _d('No column specified or parsed');
      return;
   }
   PTDEBUG && _d('Finding column', $col, 'in', $db, $tbl);

   if ( $db && !$schema->{$db} ) {
      PTDEBUG && _d('Database', $db, 'does not exist');
      return;
   }

   if ( $db && $tbl && !$schema->{$db}->{$tbl} ) {
      PTDEBUG && _d('Table', $tbl, 'does not exist in database', $db);
      return;
   }

   my @tbls;
   my @search_dbs = $db ? ($db) : keys %$schema;
   DATABASE:
   foreach my $search_db ( @search_dbs ) {
      my @search_tbls = $tbl ? ($tbl) : keys %{$schema->{$search_db}};

      TABLE:
      foreach my $search_tbl ( @search_tbls ) {
         next DATABASE unless exists $schema->{$search_db}->{$search_tbl};

         if ( $ignore
              && grep { $_->{db} eq $search_db && $_->{tbl} eq $search_tbl }
                 @$ignore ) {
            PTDEBUG && _d('Ignoring', $search_db, $search_tbl, $col);
            next TABLE;
         }

         my $tbl = $schema->{$search_db}->{$search_tbl};
         if ( $tbl->{tbl_struct}->{is_col}->{$col} ) {
            PTDEBUG && _d('Column', $col, 'exists in', $tbl->{db}, $tbl->{tbl});
            push @tbls, $tbl;
         }
      }
   }

   return \@tbls;
}

sub find_table {
   my ( $self, %args ) = @_;
   my $ignore = $args{ignore};
   my $schema = $self->{schema};

   my ($tbl, $db);
   if ( my $tbl_name = $args{tbl_name} ) {
      ($tbl, $db) = reverse map { s/`//g; $_ } split /[.]/, $tbl_name;
      PTDEBUG && _d('Table', $tbl_name, 'has db', $db, 'tbl', $tbl);
   }
   else {
      ($tbl, $db) = @args{qw(tbl db)};
   }

   $db  = lc($db  || '');
   $tbl = lc($tbl || '');

   if ( !$tbl ) {
      PTDEBUG && _d('No table specified or parsed');
      return;
   }
   PTDEBUG && _d('Finding table', $tbl, 'in', $db);

   if ( $db && !$schema->{$db} ) {
      PTDEBUG && _d('Database', $db, 'does not exist');
      return;
   }

   if ( $db && $tbl && !$schema->{$db}->{$tbl} ) {
      PTDEBUG && _d('Table', $tbl, 'does not exist in database', $db);
      return;
   }

   my @dbs;
   my @search_dbs = $db ? ($db) : keys %$schema;
   DATABASE:
   foreach my $search_db ( @search_dbs ) {
      if ( $ignore && grep { $_->{db} eq $search_db } @$ignore ) {
         PTDEBUG && _d('Ignoring', $search_db);
         next DATABASE;
      }

      if ( exists $schema->{$search_db}->{$tbl} ) {
         PTDEBUG && _d('Table', $tbl, 'exists in', $search_db);
         push @dbs, $search_db;
      }
   }

   return \@dbs;
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
# End Schema package
# ###########################################################################

# ###########################################################################
# SchemaIterator package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/SchemaIterator.pm
#   t/lib/SchemaIterator.t
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################
{
package SchemaIterator;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

my $open_comment = qr{/\*!\d{5} };
my $tbl_name     = qr{
   CREATE\s+
   (?:TEMPORARY\s+)?
   TABLE\s+
   (?:IF NOT EXISTS\s+)?
   ([^\(]+)
}x;


sub new {
   my ( $class, %args ) = @_;
   my @required_args = qw(OptionParser TableParser Quoter);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }

   my ($file_itr, $dbh) = @args{qw(file_itr dbh)};
   die "I need either a dbh or file_itr argument"
      if (!$dbh && !$file_itr) || ($dbh && $file_itr);

   my %resume;
   if ( my $table = $args{resume} ) {
      PTDEBUG && _d('Will resume from or after', $table);
      my ($db, $tbl) = $args{Quoter}->split_unquote($table);
      die "Resume table must be database-qualified: $table"
         unless $db && $tbl;
      $resume{db}  = $db;
      $resume{tbl} = $tbl;
   }

   my $self = {
      %args,
      resume  => \%resume,
      filters => _make_filters(%args),
   };

   return bless $self, $class;
}

sub _make_filters {
   my ( %args ) = @_;
   my @required_args = qw(OptionParser Quoter);
   foreach my $arg ( @required_args ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my ($o, $q) = @args{@required_args};

   my %filters;


   my @simple_filters = qw(
      databases         tables         engines
      ignore-databases  ignore-tables  ignore-engines);
   FILTER:
   foreach my $filter ( @simple_filters ) {
      if ( $o->has($filter) ) {
         my $objs = $o->get($filter);
         next FILTER unless $objs && scalar keys %$objs;
         my $is_table = $filter =~ m/table/ ? 1 : 0;
         foreach my $obj ( keys %$objs ) {
            die "Undefined value for --$filter" unless $obj;
            $obj = lc $obj;
            if ( $is_table ) {
               my ($db, $tbl) = $q->split_unquote($obj);
               $db ||= '*';
               PTDEBUG && _d('Filter', $filter, 'value:', $db, $tbl);
               $filters{$filter}->{$db}->{$tbl} = 1;
            }
            else { # database
               PTDEBUG && _d('Filter', $filter, 'value:', $obj);
               $filters{$filter}->{$obj} = 1;
            }
         }
      }
   }

   my @regex_filters = qw(
      databases-regex         tables-regex
      ignore-databases-regex  ignore-tables-regex);
   REGEX_FILTER:
   foreach my $filter ( @regex_filters ) {
      if ( $o->has($filter) ) {
         my $pat = $o->get($filter);
         next REGEX_FILTER unless $pat;
         $filters{$filter} = qr/$pat/;
         PTDEBUG && _d('Filter', $filter, 'value:', $filters{$filter});
      }
   }

   PTDEBUG && _d('Schema object filters:', Dumper(\%filters));
   return \%filters;
}

sub next {
   my ( $self ) = @_;

   if ( !$self->{initialized} ) {
      $self->{initialized} = 1;
      if ( $self->{resume}->{tbl} ) {
         if ( !$self->table_is_allowed(@{$self->{resume}}{qw(db tbl)}) ) {
            PTDEBUG && _d('Will resume after',
               join('.', @{$self->{resume}}{qw(db tbl)}));
            $self->{resume}->{after}->{tbl} = 1;
         }
         if ( !$self->database_is_allowed($self->{resume}->{db}) ) {
            PTDEBUG && _d('Will resume after', $self->{resume}->{db});
            $self->{resume}->{after}->{db}  = 1;
         }
      }
   }

   my $schema_obj;
   if ( $self->{file_itr} ) {
      $schema_obj= $self->_iterate_files();
   }
   else { # dbh
      $schema_obj= $self->_iterate_dbh();
   }

   if ( $schema_obj ) {
      if ( my $schema = $self->{Schema} ) {
         $schema->add_schema_object($schema_obj);
      }
      PTDEBUG && _d('Next schema object:',
         $schema_obj->{db}, $schema_obj->{tbl});
   }

   return $schema_obj;
}

sub _iterate_files {
   my ( $self ) = @_;

   if ( !$self->{fh} ) {
      my ($fh, $file) = $self->{file_itr}->();
      if ( !$fh ) {
         PTDEBUG && _d('No more files to iterate');
         return;
      }
      $self->{fh}   = $fh;
      $self->{file} = $file;
   }
   my $fh = $self->{fh};
   PTDEBUG && _d('Getting next schema object from', $self->{file});

   local $INPUT_RECORD_SEPARATOR = '';
   CHUNK:
   while (defined(my $chunk = <$fh>)) {
      if ($chunk =~ m/Database: (\S+)/) {
         my $db = $1; # XXX
         $db =~ s/^`//;  # strip leading `
         $db =~ s/`$//;  # and trailing `
         if ( $self->database_is_allowed($db)
              && $self->_resume_from_database($db) ) {
            $self->{db} = $db;
         }
      }
      elsif ($self->{db} && $chunk =~ m/CREATE TABLE/) {
         if ($chunk =~ m/DROP VIEW IF EXISTS/) {
            PTDEBUG && _d('Table is a VIEW, skipping');
            next CHUNK;
         }

         my ($tbl) = $chunk =~ m/$tbl_name/;
         $tbl      =~ s/^\s*`//;
         $tbl      =~ s/`\s*$//;
         if ( $self->_resume_from_table($tbl)
              && $self->table_is_allowed($self->{db}, $tbl) ) {
            my ($ddl) = $chunk =~ m/^(?:$open_comment)?(CREATE TABLE.+?;)$/ms;
            if ( !$ddl ) {
               warn "Failed to parse CREATE TABLE from\n" . $chunk;
               next CHUNK;
            }
            $ddl =~ s/ \*\/;\Z/;/;  # remove end of version comment
            my $tbl_struct = $self->{TableParser}->parse($ddl);
            if ( $self->engine_is_allowed($tbl_struct->{engine}) ) {
               return {
                  db         => $self->{db},
                  tbl        => $tbl,
                  name       => $self->{Quoter}->quote($self->{db}, $tbl),
                  ddl        => $ddl,
                  tbl_struct => $tbl_struct,
               };
            }
         }
      }
   }  # CHUNK

   PTDEBUG && _d('No more schema objects in', $self->{file});
   close $self->{fh};
   $self->{fh} = undef;

   return $self->_iterate_files();
}

sub _iterate_dbh {
   my ( $self ) = @_;
   my $q   = $self->{Quoter};
   my $tp  = $self->{TableParser};
   my $dbh = $self->{dbh};
   PTDEBUG && _d('Getting next schema object from dbh', $dbh);

   if ( !defined $self->{dbs} ) {
      my $sql = 'SHOW DATABASES';
      PTDEBUG && _d($sql);
      my @dbs = grep {
                  $self->_resume_from_database($_)
                  &&
                  $self->database_is_allowed($_)
                } @{$dbh->selectcol_arrayref($sql)};
      PTDEBUG && _d('Found', scalar @dbs, 'databases');
      $self->{dbs} = \@dbs;
   }

   DATABASE:
   while ( $self->{db} || defined(my $db = shift @{$self->{dbs}}) ) {
      if ( !$self->{db} ) {
         PTDEBUG && _d('Next database:', $db);
         $self->{db} = $db;
      }

      if ( !$self->{tbls} ) {
         my $sql = 'SHOW /*!50002 FULL*/ TABLES FROM ' . $q->quote($self->{db});
         PTDEBUG && _d($sql);
         my @tbls = map {
            $_->[0];  # (tbl, type)
         }
         grep {
            my ($tbl, $type) = @$_;
            (!$type || ($type ne 'VIEW'))
            && $self->_resume_from_table($tbl)
            && $self->table_is_allowed($self->{db}, $tbl);
         }

         eval { @{$dbh->selectall_arrayref($sql)}; };
         if ($EVAL_ERROR) {
             warn "Skipping $self->{db}...";
             $self->{db} = undef;
             next;
         }

         PTDEBUG && _d('Found', scalar @tbls, 'tables in database',$self->{db});
         $self->{tbls} = \@tbls;
      }

      TABLE:
      while ( my $tbl = shift @{$self->{tbls}} ) {
         my $ddl = eval { $tp->get_create_table($dbh, $self->{db}, $tbl) };
         if ( my $e = $EVAL_ERROR ) {
            my $table_name = "$self->{db}.$tbl";
            if ( $e =~ /\QTable '$table_name' doesn't exist/ ) {
               PTDEBUG && _d("$table_name no longer exists");
            }
            else {
               warn "Skipping $table_name because SHOW CREATE TABLE failed: $e";
            }
            next TABLE;
         }

         my $tbl_struct = $tp->parse($ddl);
         if ( $self->engine_is_allowed($tbl_struct->{engine}) ) {
            return {
               db         => $self->{db},
               tbl        => $tbl,
               name       => $q->quote($self->{db}, $tbl),
               ddl        => $ddl,
               tbl_struct => $tbl_struct,
            };
         }
      }

      PTDEBUG && _d('No more tables in database', $self->{db});
      $self->{db}   = undef;
      $self->{tbls} = undef;
   } # DATABASE

   PTDEBUG && _d('No more databases');
   return;
}

sub database_is_allowed {
   my ( $self, $db ) = @_;
   die "I need a db argument" unless $db;

   $db = lc $db;

   my $filter = $self->{filters};

   if ( $db =~ m/^(information_schema|performance_schema|lost\+found|percona_schema)$/ ) {
      PTDEBUG && _d('Database', $db, 'is a system database, ignoring');
      return 0;
   }

   if ( $self->{filters}->{'ignore-databases'}->{$db} ) {
      PTDEBUG && _d('Database', $db, 'is in --ignore-databases list');
      return 0;
   }

   if ( $filter->{'ignore-databases-regex'}
        && $db =~ $filter->{'ignore-databases-regex'} ) {
      PTDEBUG && _d('Database', $db, 'matches --ignore-databases-regex');
      return 0;
   }

   if ( $filter->{'databases'}
        && !$filter->{'databases'}->{$db} ) {
      PTDEBUG && _d('Database', $db, 'is not in --databases list, ignoring');
      return 0;
   }

   if ( $filter->{'databases-regex'}
        && $db !~ $filter->{'databases-regex'} ) {
      PTDEBUG && _d('Database', $db, 'does not match --databases-regex, ignoring');
      return 0;
   }

   return 1;
}

sub table_is_allowed {
   my ( $self, $db, $tbl ) = @_;
   die "I need a db argument"  unless $db;
   die "I need a tbl argument" unless $tbl;

   $db  = lc $db;
   $tbl = lc $tbl;

   my $filter = $self->{filters};

   return 0 if $db eq 'mysql' && $tbl =~ m/^(?:
       general_log
      |gtid_executed
      |innodb_index_stats
      |innodb_table_stats
      |slave_master_info
      |slave_relay_log_info
      |slave_worker_info
      |slow_log    
   )$/x;

   if ( $filter->{'ignore-tables'}->{'*'}->{$tbl} 
         || $filter->{'ignore-tables'}->{$db}->{$tbl}) {
      PTDEBUG && _d('Table', $tbl, 'is in --ignore-tables list');
      return 0;
   }

   if ( $filter->{'ignore-tables-regex'}
        && $tbl =~ $filter->{'ignore-tables-regex'} ) {
      PTDEBUG && _d('Table', $tbl, 'matches --ignore-tables-regex');
      return 0;
   }

   if ( $filter->{'tables'}
        && (!$filter->{'tables'}->{'*'}->{$tbl} && !$filter->{'tables'}->{$db}->{$tbl}) ) { 
      PTDEBUG && _d('Table', $tbl, 'is not in --tables list, ignoring');
      return 0;
   }

   if ( $filter->{'tables-regex'}
        && $tbl !~ $filter->{'tables-regex'} ) {
      PTDEBUG && _d('Table', $tbl, 'does not match --tables-regex, ignoring');
      return 0;
   }

   if ( $filter->{'tables'}
        && $filter->{'tables'}->{$tbl}
        && $filter->{'tables'}->{$tbl} ne '*'
        && $filter->{'tables'}->{$tbl} ne $db ) {
      PTDEBUG && _d('Table', $tbl, 'is only allowed in database',
         $filter->{'tables'}->{$tbl});
      return 0;
   }

   return 1;
}

sub engine_is_allowed {
   my ( $self, $engine ) = @_;

   if ( !$engine ) {
      PTDEBUG && _d('No engine specified; allowing the table');
      return 1;
   }

   $engine = lc $engine;

   my $filter = $self->{filters};

   if ( $filter->{'ignore-engines'}->{$engine} ) {
      PTDEBUG && _d('Engine', $engine, 'is in --ignore-databases list');
      return 0;
   }

   if ( $filter->{'engines'}
        && !$filter->{'engines'}->{$engine} ) {
      PTDEBUG && _d('Engine', $engine, 'is not in --engines list, ignoring');
      return 0;
   }

   return 1;
}

sub _resume_from_database {
   my ($self, $db) = @_;

   return 1 unless $self->{resume}->{db};
   if ( $db eq $self->{resume}->{db} ) {
      if ( !$self->{resume}->{after}->{db} ) {
         PTDEBUG && _d('Resuming from db', $db);
         delete $self->{resume}->{db};
         return 1;
      }
      else {
         PTDEBUG && _d('Resuming after db', $db);
         delete $self->{resume}->{db};
         delete $self->{resume}->{tbl};
      }
   }

   return 0;
}

sub _resume_from_table {
   my ($self, $tbl) = @_;

   return 1 unless $self->{resume}->{tbl};

   if ( $tbl eq $self->{resume}->{tbl} ) {
      if ( !$self->{resume}->{after}->{tbl} ) {
         PTDEBUG && _d('Resuming from table', $tbl);
         delete $self->{resume}->{tbl};
         return 1;
      }
      else {
         PTDEBUG && _d('Resuming after table', $tbl);
         delete $self->{resume}->{tbl};
      }
   }

   return 0;
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
# End SchemaIterator package
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

# #############################################################################
# This is a combination of modules and programs in one -- a runnable module.
# http://www.perl.com/pub/a/2006/07/13/lightning-articles.html?page=last
# Or, look it up in the Camel book on pages 642 and 643 in the 3rd edition.
#
# Check at the end of this package for the call to main() which actually runs
# the program.
# #############################################################################
package pt_duplicate_key_checker;

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);

use List::Util qw(max);

use Percona::Toolkit;
use constant PTDEBUG => $ENV{PTDEBUG} || 0;

$OUTPUT_AUTOFLUSH = 1;

my $max_width = 74;
my $hdr_width = $max_width - 2;  # for '# '
my $hdr_fmt   = "# %-${hdr_width}s\n";

sub main {
   local @ARGV = @_;  # set global ARGV for this package

   my %summary = ( 'items' => {'Total Indexes' => 0} );
   my %seen_tbl;

   my $q  = new Quoter();
   my $tp = new TableParser(Quoter => $q);

   # #######################################################################
   # Get configuration information and parse command line options.
   # #######################################################################
   my $o = new OptionParser();
   $o->get_specs();
   $o->get_opts();

   my $dp = $o->DSNParser();
   $dp->prop('set-vars', $o->set_vars());

   $o->usage_or_errors();

   # ########################################################################
   # If --pid, check it first since we'll die if it already exits.
   # ########################################################################
   my $daemon = Daemon->new(
      daemonize => 0,
      pid_file  => $o->get('pid'),
   );
   $daemon->run();

   # #######################################################################
   # Connect to MySQL.
   # #######################################################################
   if ( $o->got('ask-pass') ) {
      $o->set('password', OptionParser::prompt_noecho("Enter password: "));
   }
   my $dsn_defaults = $dp->parse_options($o);
   my $dsn          = @ARGV ? $dp->parse(shift @ARGV, $dsn_defaults)
                    :         $dsn_defaults;
   my $dbh          = $dp->get_dbh($dp->get_cxn_params($dsn),
                              { AutoCommit => 1, });

   # ########################################################################
   # Do the version-check
   # ########################################################################
   if ( $o->get('version-check') && (!$o->has('quiet') || !$o->get('quiet')) ) {
      VersionCheck::version_check(
         force     => $o->got('version-check'),
         instances => [ {dbh => $dbh, dsn => $dsn} ],
      );
   }

   # #######################################################################
   # Do the main work.
   # #######################################################################
   my $ks = $o->get('summary') ? new KeySize(q=>$q) : undef;
   my $dk = new DuplicateKeyFinder();

   my %tp_opts = (
      ignore_type  => $o->get('all-structs'),
      ignore_order => $o->get('ignore-order'),
      clustered    => $o->get('clustered'),
   );

   my $get_keys = $o->get('key-types') =~ m/k/ ? 1 : 0;
   my $get_fks  = $o->get('key-types') =~ m/f/ ? 1 : 0;

   my $schema     = new Schema();
   my $schema_itr = new SchemaIterator(
      dbh          => $dbh,
      OptionParser => $o,
      Quoter       => $q,
      TableParser  => $tp,
      Schema       => $schema,
   );
   TABLE:
   while ( my $tbl = $schema_itr->next() ) {
      eval {
         $tbl->{engine} = $tbl->{tbl_struct}->{engine};

         my ($keys, $clustered_key, $fks);
         if ( $get_keys ) {
            ($keys, $clustered_key)
               = $tp->get_keys($tbl->{ddl}, {});
         }
         if ( $get_fks ) {
            $fks = $tp->get_fks($tbl->{ddl},  {database => $tbl->{db}});
         }

         if ( ($keys && %$keys) || ($fks && %$fks) ) {
            if ( $o->got('verbose') ) {
               print_all_keys($keys, $tbl, \%seen_tbl) if $keys;
               print_all_keys($fks,  $tbl, \%seen_tbl) if $fks;
            }
            PTDEBUG && _d('Getting duplicate keys on',
               $tbl->{db}, $tbl->{tbl});
            if ( $keys ) {
               $dk->get_duplicate_keys(
                  $keys,
                  clustered_key => $clustered_key,
                  tbl_info      => $tbl,
                  callback      => \&print_duplicate_key,
                  %tp_opts,
                  # get_duplicate_keys() ignores these args but passes them
                  # to the callback:
                     dbh      => $dbh,
                     is_fk    => 0,
                     o        => $o,
                     ks       => $ks,
                     tp       => $tp,
                     q        => $q,
                     seen_tbl => \%seen_tbl,
                     summary  => \%summary,
               );
            }
            if ( $fks ) {
               $dk->get_duplicate_fks(
                  $fks,
                  tbl_info => $tbl,
                  callback => \&print_duplicate_key,
                  %tp_opts,
                  # get_duplicate_fks() ignores these args but passes them
                  # to the callback:
                     dbh   => $dbh,
                     is_fk => 1,
                     o     => $o,
                     ks    => $ks,
                     tp       => $tp,
                     q        => $q,
                     seen_tbl => \%seen_tbl,
                     summary  => \%summary,
               );
            }

            # Always count Total Keys so print_key_summary won't die
            # because %summary is empty.
            $summary{items}->{'Total Indexes'} += (scalar keys %$keys)
                                       + (scalar keys %$fks)
         }
      };
      if ( $EVAL_ERROR ) {
         warn "Error checking $tbl->{db}.$tbl->{tbl}: $EVAL_ERROR";
      }
   }  # TABLE

   print_key_summary(%summary) if $o->get('summary');

   return 0;
}

# ##########################################################################
# Subroutines
# ##########################################################################

sub print_all_keys {
   my ( $keys, $tbl_info, $seen_tbl ) = @_;
   return unless $keys;
   my $db  = $tbl_info->{db};
   my $tbl = $tbl_info->{tbl};
   if ( !$seen_tbl->{"$db$tbl"}++ ) {
      printf $hdr_fmt, ('#' x $hdr_width);
      printf $hdr_fmt, "$db.$tbl";
      printf $hdr_fmt, ('#' x $hdr_width);
   }
   # Print keys sorted by name (easier to test)
   foreach my $key (  sort {$a->{name} cmp $b->{name}} values %$keys ) {
      print "\n# $key->{name} ($key->{colnames})";
   }
   print "\n";
   return;
}

sub print_duplicate_key {
   my ( $dupe, %args ) = @_;
   return unless $dupe;
   foreach my $arg ( qw(tbl_info dbh is_fk o ks q tp seen_tbl) ) {
      die "I need a $arg argument" unless exists $args{$arg};
   }
   PTDEBUG && _d('Printing duplicate key', $dupe->{key});
   my $db       = $args{tbl_info}->{db};
   my $tbl      = $args{tbl_info}->{tbl};
   my $dbh      = $args{dbh};
   my $o        = $args{o};
   my $ks       = $args{ks};
   my $seen_tbl = $args{seen_tbl};
   my $q        = $args{q};
   my $tp       = $args{tp};
   my $summary  = $args{summary};
   my $struct   = $tp->parse($args{tbl_info}->{ddl});

   if ($dupe->{ddl} =~ /FULLTEXT/) {
      $summary->{has_fulltext_dupe}++;
   }

   if ( !$seen_tbl->{"$db$tbl"}++ ) {
      printf $hdr_fmt, ('#' x $hdr_width);
      printf $hdr_fmt, "$db.$tbl";
      printf $hdr_fmt, ('#' x $hdr_width);
      print "\n";
   }

   $dupe->{reason} =~ s/\n/\n# /g;
   print "# $dupe->{reason}\n";

   print "# Key definitions:\n";
   print "#   " . ($dupe->{ddl} || '') . "\n";
   print "#   " . ($dupe->{duplicate_of_ddl} || '') . "\n";

   print "# Column types:\n";
   my %seen;  # print each column only once
   foreach my $col ( @{$dupe->{cols}}, @{$dupe->{duplicate_of_cols}} ) {
      next if $seen{$col}++;
      PTDEBUG && _d('col', $col);
      print "#\t" . lc($struct->{defs}->{lc $col}) . "\n";
   }

   if ( $o->get('sql') ) {
      if ( $dupe->{dupe_type} ne 'clustered' ) {
         print "# To remove this duplicate "
            . ($args{is_fk} ? 'foreign key' : 'index')
            . ", execute:\n"
            . 'ALTER TABLE ' . $q->quote($db, $tbl)
            . ($args{is_fk} ? ' DROP FOREIGN KEY ' : ' DROP INDEX ')
            . "`$dupe->{key}`;\n";
      }
      else {
         # Suggest shortening clustered dupes instead of
         # removing them (issue 295).
         print "# To shorten this duplicate clustered index, execute:\n"
            . 'ALTER TABLE '.$q->quote($db, $tbl)." DROP INDEX `$dupe->{key}`, "
            . "ADD INDEX `$dupe->{key}` ($dupe->{short_key});\n";
      }
   }
   print "\n";

   if ( $o->get('summary') && $summary ) {
      $summary->{'items'}->{'Total Duplicate Indexes'} += 1;
      my ($size, $chosen_key) = $ks->get_key_size(
         name        => $dupe->{key},
         cols        => $dupe->{cols},
         tbl_name    => $q->quote($db, $tbl),
         tbl_struct  => $struct,
         dbh         => $dbh,
      );
      if ( $args{is_fk} ) {
         # Foreign keys have no size because they're just constraints.
         print "# MySQL uses the $chosen_key index for this "
            . "foreign key constraint\n\n";
      }
      else {
         $size ||= 0;

         # Create Size Duplicate Keys summary even if there's no valid keys.
         $summary->{'items'}->{'Size Duplicate Indexes'} += $size;

         if ( $size ) {
            if ( $chosen_key && $chosen_key ne $dupe->{key} ) {
               # This shouldn't happen. But in case it does, we should know.
               print "# MySQL chose the $chosen_key index despite FORCE INDEX\n\n";
            }
         }
      }
   }
   return;
}

sub print_key_summary {
   my ( %summary ) = @_;
   my $items = $summary{items};
   printf $hdr_fmt, ('#' x $hdr_width);
   printf $hdr_fmt, 'Summary of indexes';
   printf $hdr_fmt, ('#' x $hdr_width);
   print "\n";
   my $max_item = max(map { length($_) } keys %$items);
   my $line_fmt = "# %-${max_item}s  %-s";
   foreach my $item ( sort keys %$items ) {
      printf $line_fmt, $item, $items->{$item};
      if ( $item eq 'Size Duplicate Indexes' && $summary{has_fulltext_dupe} ) {
         print ' (not including FULLTEXT indexes)';
      }
      print "\n";
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

pt-duplicate-key-checker - Find duplicate indexes and foreign keys on MySQL tables.

=head1 SYNOPSIS

Usage: pt-duplicate-key-checker [OPTIONS] [DSN]

pt-duplicate-key-checker examines MySQL tables for duplicate or redundant
indexes and foreign keys.  Connection options are read from MySQL option files.

   pt-duplicate-key-checker --host host1

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

This program examines the output of SHOW CREATE TABLE on MySQL tables, and if
it finds indexes that cover the same columns as another index in the same
order, or cover an exact leftmost prefix of another index, it prints out
the suspicious indexes.  By default, indexes must be of the same type, so a
BTREE index is not a duplicate of a FULLTEXT index, even if they have the same
columns.  You can override this.

It also looks for duplicate foreign keys.  A duplicate foreign key covers the
same columns as another in the same table, and references the same parent
table.

The output ends with a short summary that includes an estimate of the total 
size, in bytes, that the duplicate indexes are using. This is calculated by 
multiplying the index length by the number of rows in their respective tables.

=head1 OPTIONS

This tool accepts additional command-line arguments.  Refer to the
L<"SYNOPSIS"> and usage information for details.

=over

=item --all-structs

Compare indexes with different structs (BTREE, HASH, etc).

By default this is disabled, because a BTREE index that covers the same columns
as a FULLTEXT index is not really a duplicate, for example.

=item --ask-pass

Prompt for a password when connecting to MySQL.

=item --charset

short form: -A; type: string

Default character set.  If the value is utf8, sets Perl's binmode on
STDOUT to utf8, passes the mysql_enable_utf8 option to DBD::mysql, and runs SET
NAMES UTF8 after connecting to MySQL.  Any other value sets binmode on STDOUT
without the utf8 layer, and runs SET NAMES after connecting to MySQL.

=item --[no]clustered

default: yes

PK columns appended to secondary key is duplicate.

Detects when a suffix of a secondary key is a leftmost prefix of the primary
key, and treats it as a duplicate key.  Only detects this condition on storage
engines whose primary keys are clustered (currently InnoDB and solidDB).

Clustered storage engines append the primary key columns to the leaf nodes of
all secondary keys anyway, so you might consider it redundant to have them
appear in the internal nodes as well.  Of course, you may also want them in the
internal nodes, because just having them at the leaf nodes won't help for some
queries.  It does help for covering index queries, however.

Here's an example of a key that is considered redundant with this option:

  PRIMARY KEY  (`a`)
  KEY `b` (`b`,`a`)

The use of such indexes is rather subtle.  For example, suppose you have the
following query:

  SELECT ... WHERE b=1 ORDER BY a;

This query will do a filesort if we remove the index on C<b,a>.  But if we
shorten the index on C<b,a> to just C<b> and also remove the ORDER BY, the query
should return the same results.

The tool suggests shortening duplicate clustered keys by dropping the key
and re-adding it without the primary key prefix.  The shortened clustered
key may still duplicate another key, but the tool cannot currently detect
when this happens without being ran a second time to re-check the newly
shortened clustered keys.  Therefore, if you shorten any duplicate clustered
keys, you should run the tool again.

=item --config

type: Array

Read this comma-separated list of config files; if specified, this must be the
first option on the command line.

=item --databases

short form: -d; type: hash

Check only this comma-separated list of databases.

=item --defaults-file

short form: -F; type: string

Only read mysql options from the given file.  You must give an absolute pathname.

=item --engines

short form: -e; type: hash

Check only tables whose storage engine is in this comma-separated list.

=item --help

Show help and exit.

=item --host

short form: -h; type: string

Connect to host.

=item --ignore-databases

type: Hash

Ignore this comma-separated list of databases.

=item --ignore-engines

type: Hash

Ignore this comma-separated list of storage engines.

=item --ignore-order

Ignore index order so KEY(a,b) duplicates KEY(b,a).

=item --ignore-tables

type: Hash

Ignore this comma-separated list of tables.  Table names may be qualified with
the database name.

=item --key-types

type: string; default: fk

Check for duplicate f=foreign keys, k=keys or fk=both.

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

=item --[no]sql

default: yes

Print DROP KEY statement for each duplicate key.  By default an ALTER TABLE
DROP KEY statement is printed below each duplicate key so that, if you want to
remove the duplicate key, you can copy-paste the statement into MySQL.

To disable printing these statements, specify C<--no-sql>.

=item --[no]summary

default: yes

Print summary of indexes at end of output.

=item --tables

short form: -t; type: hash

Check only this comma-separated list of tables.

Table names may be qualified with the database name.

=item --user

short form: -u; type: string

User for login if not current user.

=item --verbose

short form: -v

Output all keys and/or foreign keys found, not just redundant ones.

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

   PTDEBUG=1 pt-duplicate-key-checker ... > FILE 2>&1

Be careful: debugging output is voluminous and can generate several megabytes
of output.

=head1 SYSTEM REQUIREMENTS

You need Perl, DBI, DBD::mysql, and some core packages that ought to be
installed in any reasonably new version of Perl.

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-duplicate-key-checker>.

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

pt-duplicate-key-checker 3.3.0

=cut
