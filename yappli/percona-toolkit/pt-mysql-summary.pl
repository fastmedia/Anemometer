#!/bin/sh

# This program is part of Percona Toolkit: http://www.percona.com/software/
# See "COPYRIGHT, LICENSE, AND WARRANTY" at the end of this file for legal
# notices and disclaimers.

set -u

# ###########################################################################
# log_warn_die package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/log_warn_die.sh
#   t/lib/bash/log_warn_die.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u

PTFUNCNAME=""
PTDEBUG="${PTDEBUG:-""}"
EXIT_STATUS=0

ts() {
   TS=$(date +%F-%T | tr ':-' '_')
   echo "$TS $*"
}

info() {
   [ ${OPT_VERBOSE:-3} -ge 3 ] && ts "$*"
}

log() {
   [ ${OPT_VERBOSE:-3} -ge 2 ] && ts "$*"
}

warn() {
   [ ${OPT_VERBOSE:-3} -ge 1 ] && ts "$*" >&2
   EXIT_STATUS=1
}

die() {
   ts "$*" >&2
   EXIT_STATUS=1
   exit 1
}

_d () {
   [ "$PTDEBUG" ] && echo "# $PTFUNCNAME: $(ts "$*")" >&2
}

# ###########################################################################
# End log_warn_die package
# ###########################################################################

# ###########################################################################
# parse_options package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/parse_options.sh
#   t/lib/bash/parse_options.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################





set -u

ARGV=""           # Non-option args (probably input files)
EXT_ARGV=""       # Everything after -- (args for an external command)
HAVE_EXT_ARGV=""  # Got --, everything else is put into EXT_ARGV
OPT_ERRS=0        # How many command line option errors
OPT_VERSION=""    # If --version was specified
OPT_HELP=""       # If --help was specified
OPT_ASK_PASS=""   # If --ask-pass was specified
PO_DIR=""         # Directory with program option spec files

usage() {
   local file="$1"

   local usage="$(grep '^Usage: ' "$file")"
   echo $usage
   echo
   echo "For more information, 'man $TOOL' or 'perldoc $file'."
}

usage_or_errors() {
   local file="$1"
   local version=""

   if [ "$OPT_VERSION" ]; then
      version=$(grep '^pt-[^ ]\+ [0-9]' "$file")
      echo "$version"
      return 1
   fi

   if [ "$OPT_HELP" ]; then
      usage "$file"
      echo
      echo "Command line options:"
      echo
      perl -e '
         use strict;
         use warnings FATAL => qw(all);
         my $lcol = 20;         # Allow this much space for option names.
         my $rcol = 80 - $lcol; # The terminal is assumed to be 80 chars wide.
         my $name;
         while ( <> ) {
            my $line = $_;
            chomp $line;
            if ( $line =~ s/^long:/  --/ ) {
               $name = $line;
            }
            elsif ( $line =~ s/^desc:// ) {
               $line =~ s/ +$//mg;
               my @lines = grep { $_      }
                           $line =~ m/(.{0,$rcol})(?:\s+|\Z)/g;
               if ( length($name) >= $lcol ) {
                  print $name, "\n", (q{ } x $lcol);
               }
               else {
                  printf "%-${lcol}s", $name;
               }
               print join("\n" . (q{ } x $lcol), @lines);
               print "\n";
            }
         }
      ' "$PO_DIR"/*
      echo
      echo "Options and values after processing arguments:"
      echo
      (
         cd "$PO_DIR"
         for opt in *; do
            local varname="OPT_$(echo "$opt" | tr a-z- A-Z_)"
            eval local varvalue=\$$varname
            if ! grep -q "type:" "$PO_DIR/$opt" >/dev/null; then
               if [ "$varvalue" -a "$varvalue" = "yes" ];
                  then varvalue="TRUE"
               else
                  varvalue="FALSE"
               fi
            fi
            printf -- "  --%-30s %s" "$opt" "${varvalue:-(No value)}"
            echo
         done
      )
      return 1
   fi

   if [ $OPT_ERRS -gt 0 ]; then
      echo
      usage "$file"
      return 1
   fi

   return 0
}

option_error() {
   local err="$1"
   OPT_ERRS=$(($OPT_ERRS + 1))
   echo "$err" >&2
}

parse_options() {
   local file="$1"
   shift

   ARGV=""
   EXT_ARGV=""
   HAVE_EXT_ARGV=""
   OPT_ERRS=0
   OPT_VERSION=""
   OPT_HELP=""
   OPT_ASK_PASS=""
   PO_DIR="$PT_TMPDIR/po"

   if [ ! -d "$PO_DIR" ]; then
      mkdir "$PO_DIR"
      if [ $? -ne 0 ]; then
         echo "Cannot mkdir $PO_DIR" >&2
         exit 1
      fi
   fi

   rm -rf "$PO_DIR"/*
   if [ $? -ne 0 ]; then
      echo "Cannot rm -rf $PO_DIR/*" >&2
      exit 1
   fi

   _parse_pod "$file"  # Parse POD into program option (po) spec files
   _eval_po            # Eval po into existence with default values

   if [ $# -ge 2 ] &&  [ "$1" = "--config" ]; then
      shift  # --config
      local user_config_files="$1"
      shift  # that ^
      local IFS=","
      for user_config_file in $user_config_files; do
         _parse_config_files "$user_config_file"
      done
   else
      _parse_config_files "/etc/percona-toolkit/percona-toolkit.conf" "/etc/percona-toolkit/$TOOL.conf"
      if [ "${HOME:-}" ]; then
         _parse_config_files "$HOME/.percona-toolkit.conf" "$HOME/.$TOOL.conf"
      fi
   fi

   _parse_command_line "${@:-""}"
}

_parse_pod() {
   local file="$1"

   PO_FILE="$file" PO_DIR="$PO_DIR" perl -e '
      $/ = "";
      my $file = $ENV{PO_FILE};
      open my $fh, "<", $file or die "Cannot open $file: $!";
      while ( defined(my $para = <$fh>) ) {
         next unless $para =~ m/^=head1 OPTIONS/;
         while ( defined(my $para = <$fh>) ) {
            last if $para =~ m/^=head1/;
            chomp;
            if ( $para =~ m/^=item --(\S+)/ ) {
               my $opt  = $1;
               my $file = "$ENV{PO_DIR}/$opt";
               open my $opt_fh, ">", $file or die "Cannot open $file: $!";
               print $opt_fh "long:$opt\n";
               $para = <$fh>;
               chomp;
               if ( $para =~ m/^[a-z ]+:/ ) {
                  map {
                     chomp;
                     my ($attrib, $val) = split(/: /, $_);
                     print $opt_fh "$attrib:$val\n";
                  } split(/; /, $para);
                  $para = <$fh>;
                  chomp;
               }
               my ($desc) = $para =~ m/^([^?.]+)/;
               print $opt_fh "desc:$desc.\n";
               close $opt_fh;
            }
         }
         last;
      }
   '
}

_eval_po() {
   local IFS=":"
   for opt_spec in "$PO_DIR"/*; do
      local opt=""
      local default_val=""
      local neg=0
      local size=0
      while read key val; do
         case "$key" in
            long)
               opt=$(echo $val | sed 's/-/_/g' | tr '[:lower:]' '[:upper:]')
               ;;
            default)
               default_val="$val"
               ;;
            "short form")
               ;;
            type)
               [ "$val" = "size" ] && size=1
               ;;
            desc)
               ;;
            negatable)
               if [ "$val" = "yes" ]; then
                  neg=1
               fi
               ;;
            *)
               echo "Invalid attribute in $opt_spec: $line" >&2
               exit 1
         esac 
      done < "$opt_spec"

      if [ -z "$opt" ]; then
         echo "No long attribute in option spec $opt_spec" >&2
         exit 1
      fi

      if [ $neg -eq 1 ]; then
         if [ -z "$default_val" ] || [ "$default_val" != "yes" ]; then
            echo "Option $opt_spec is negatable but not default: yes" >&2
            exit 1
         fi
      fi

      if [ $size -eq 1 -a -n "$default_val" ]; then
         default_val=$(size_to_bytes $default_val)
      fi

      eval "OPT_${opt}"="$default_val"
   done
}

_parse_config_files() {

   for config_file in "${@:-""}"; do
      test -f "$config_file" || continue

      while read config_opt; do

         echo "$config_opt" | grep '^[ ]*[^#]' >/dev/null 2>&1 || continue

         config_opt="$(echo "$config_opt" | sed -e 's/^ *//g' -e 's/ *$//g' -e 's/[ ]*=[ ]*/=/' -e 's/[ ]+#.*$//')"

         [ "$config_opt" = "" ] && continue

         echo "$config_opt" | grep -v 'version-check' >/dev/null 2>&1 || continue

         if ! [ "$HAVE_EXT_ARGV" ]; then
            config_opt="--$config_opt"
         fi

         _parse_command_line "$config_opt"

      done < "$config_file"

      HAVE_EXT_ARGV=""  # reset for each file

   done
}

_parse_command_line() {
   local opt=""
   local val=""
   local next_opt_is_val=""
   local opt_is_ok=""
   local opt_is_negated=""
   local real_opt=""
   local required_arg=""
   local spec=""

   for opt in "${@:-""}"; do
      if [ "$opt" = "--" -o "$opt" = "----" ]; then
         HAVE_EXT_ARGV=1
         continue
      fi
      if [ "$HAVE_EXT_ARGV" ]; then
         if [ "$EXT_ARGV" ]; then
            EXT_ARGV="$EXT_ARGV $opt"
         else
            EXT_ARGV="$opt"
         fi
         continue
      fi

      if [ "$next_opt_is_val" ]; then
         next_opt_is_val=""
         if [ $# -eq 0 ] || [ $(expr "$opt" : "\-") -eq 1 ]; then
            option_error "$real_opt requires a $required_arg argument"
            continue
         fi
         val="$opt"
         opt_is_ok=1
      else
         if [ $(expr "$opt" : "\-") -eq 0 ]; then
            if [ -z "$ARGV" ]; then
               ARGV="$opt"
            else
               ARGV="$ARGV $opt"
            fi
            continue
         fi

         real_opt="$opt"

         if $(echo $opt | grep '^--no[^-]' >/dev/null); then
            local base_opt=$(echo $opt | sed 's/^--no//')
            if [ -f "$PT_TMPDIR/po/$base_opt" ]; then
               opt_is_negated=1
               opt="$base_opt"
            else
               opt_is_negated=""
               opt=$(echo $opt | sed 's/^-*//')
            fi
         else
            if $(echo $opt | grep '^--no-' >/dev/null); then
               opt_is_negated=1
               opt=$(echo $opt | sed 's/^--no-//')
            else
               opt_is_negated=""
               opt=$(echo $opt | sed 's/^-*//')
            fi
         fi

         if $(echo $opt | grep '^[a-z-][a-z-]*=' >/dev/null 2>&1); then
            val="$(echo $opt | awk -F= '{print $2}')"
            opt="$(echo $opt | awk -F= '{print $1}')"
         fi

         if [ -f "$PT_TMPDIR/po/$opt" ]; then
            spec="$PT_TMPDIR/po/$opt"
         else
            spec=$(grep "^short form:-$opt\$" "$PT_TMPDIR"/po/* | cut -d ':' -f 1)
            if [ -z "$spec"  ]; then
               option_error "Unknown option: $real_opt"
               continue
            fi
         fi

         required_arg=$(cat "$spec" | awk -F: '/^type:/{print $2}')
         if [ "$required_arg" ]; then
            if [ "$val" ]; then
               opt_is_ok=1
            else
               next_opt_is_val=1
            fi
         else
            if [ "$val" ]; then
               option_error "Option $real_opt does not take a value"
               continue
            fi 
            if [ "$opt_is_negated" ]; then
               val=""
            else
               val="yes"
            fi
            opt_is_ok=1
         fi
      fi

      if [ "$opt_is_ok" ]; then
         opt=$(cat "$spec" | grep '^long:' | cut -d':' -f2 | sed 's/-/_/g' | tr '[:lower:]' '[:upper:]')

         if grep "^type:size" "$spec" >/dev/null; then
            val=$(size_to_bytes $val)
         fi

         eval "OPT_$opt"="'$val'"

         opt=""
         val=""
         next_opt_is_val=""
         opt_is_ok=""
         opt_is_negated=""
         real_opt=""
         required_arg=""
         spec=""
      fi
   done
}

size_to_bytes() {
   local size="$1"
   echo $size | perl -ne '%f=(B=>1, K=>1_024, M=>1_048_576, G=>1_073_741_824, T=>1_099_511_627_776); m/^(\d+)([kMGT])?/i; print $1 * $f{uc($2 || "B")};'
}

# ###########################################################################
# End parse_options package
# ###########################################################################

# ###########################################################################
# mysql_options package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/mysql_options.sh
#   t/lib/bash/mysql_options.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u

mysql_options() {
   local MYSQL_ARGS=""
   if [ -n "$OPT_DEFAULTS_FILE" ]; then
      MYSQL_ARGS="--defaults-file=$OPT_DEFAULTS_FILE"
   fi
   if [ -n "$OPT_PORT" ]; then
      MYSQL_ARGS="$MYSQL_ARGS --port=$OPT_PORT"
   fi
   if [ -n "$OPT_SOCKET" ]; then
      MYSQL_ARGS="$MYSQL_ARGS --socket=$OPT_SOCKET"
   fi
   if [ -n "$OPT_HOST" ]; then
      MYSQL_ARGS="$MYSQL_ARGS --host=$OPT_HOST"
   fi
   if [ -n "$OPT_USER" ]; then
      MYSQL_ARGS="$MYSQL_ARGS --user=$OPT_USER"
   fi
   if [ -n "$OPT_ASK_PASS" ]; then
      stty -echo
      >&2 printf "Enter MySQL password: "
      read GIVEN_PASS 
      stty echo
      printf "\n"
      MYSQL_ARGS="$MYSQL_ARGS --password=$GIVEN_PASS"
   elif [ -n "$OPT_PASSWORD" ]; then
      MYSQL_ARGS="$MYSQL_ARGS --password=$OPT_PASSWORD"
   fi
   
   echo $MYSQL_ARGS
}

arrange_mysql_options() {
   local opts="$1"
   
   local rearranged=""
   for opt in $opts; do
      if [ "$(echo $opt | awk -F= '{print $1}')" = "--defaults-file" ]; then
          rearranged="$opt $rearranged"
      else
         rearranged="$rearranged $opt"
      fi
   done
   
   echo "$rearranged"
}

# ###########################################################################
# End mysql_options package
# ###########################################################################

# ###########################################################################
# tmpdir package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/tmpdir.sh
#   t/lib/bash/tmpdir.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u

PT_TMPDIR=""

mk_tmpdir() {
   local dir="${1:-""}"

   if [ -n "$dir" ]; then
      if [ ! -d "$dir" ]; then
         mkdir "$dir" || die "Cannot make tmpdir $dir"
      fi
      PT_TMPDIR="$dir"
   else
      local tool="${0##*/}"
      local pid="$$"
      PT_TMPDIR=`mktemp -d -t "${tool}.${pid}.XXXXXX"` \
         || die "Cannot make secure tmpdir"
   fi
}

rm_tmpdir() {
   if [ -n "$PT_TMPDIR" ] && [ -d "$PT_TMPDIR" ]; then
      rm -rf "$PT_TMPDIR"
   fi
   PT_TMPDIR=""
}

# ###########################################################################
# End tmpdir package
# ###########################################################################

# ###########################################################################
# alt_cmds package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/alt_cmds.sh
#   t/lib/bash/alt_cmds.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u

_seq() {
   local i="$1"
   awk "BEGIN { for(i=1; i<=$i; i++) print i; }"
}

_pidof() {
   local cmd="$1"
   if ! pidof "$cmd" 2>/dev/null; then
      ps -eo pid,ucomm | awk -v comm="$cmd" '$2 == comm { print $1 }'
   fi
}

_lsof() {
   local pid="$1"
   if ! lsof -p $pid 2>/dev/null; then
      /bin/ls -l /proc/$pid/fd 2>/dev/null
   fi
}



_which() {
   if [ -x /usr/bin/which ]; then
      /usr/bin/which "$1" 2>/dev/null | awk '{print $1}'
   elif which which 1>/dev/null 2>&1; then
      which "$1" 2>/dev/null | awk '{print $1}'
   else
      echo "$1"
   fi
}

# ###########################################################################
# End alt_cmds package
# ###########################################################################

# ###########################################################################
# report_formatting package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/report_formatting.sh
#   t/lib/bash/report_formatting.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u

POSIXLY_CORRECT=1
export POSIXLY_CORRECT

fuzzy_formula='
   rounded = 0;
   if (fuzzy_var <= 10 ) {
      rounded   = 1;
   }
   factor = 1;
   while ( rounded == 0 ) {
      if ( fuzzy_var <= 50 * factor ) {
         fuzzy_var = sprintf("%.0f", fuzzy_var / (5 * factor)) * 5 * factor;
         rounded   = 1;
      }
      else if ( fuzzy_var <= 100  * factor) {
         fuzzy_var = sprintf("%.0f", fuzzy_var / (10 * factor)) * 10 * factor;
         rounded   = 1;
      }
      else if ( fuzzy_var <= 250  * factor) {
         fuzzy_var = sprintf("%.0f", fuzzy_var / (25 * factor)) * 25 * factor;
         rounded   = 1;
      }
      factor = factor * 10;
   }'

fuzz () {
   awk -v fuzzy_var="$1" "BEGIN { ${fuzzy_formula} print fuzzy_var;}"
}

fuzzy_pct () {
   local pct="$(awk -v one="$1" -v two="$2" 'BEGIN{ if (two > 0) { printf "%d", one/two*100; } else {print 0} }')";
   echo "$(fuzz "${pct}")%"
}

section () {
   local str="$1"
   awk -v var="${str} _" 'BEGIN {
      line = sprintf("# %-60s", var);
      i = index(line, "_");
      x = substr(line, i);
      gsub(/[_ \t]/, "#", x);
      printf("%s%s\n", substr(line, 1, i-1), x);
   }'
}

NAME_VAL_LEN=12
name_val () {
   printf "%+*s | %s\n" "${NAME_VAL_LEN}" "$1" "$2"
}

shorten() {
   local num="$1"
   local prec="${2:-2}"
   local div="${3:-1024}"

   echo "$num" | awk -v prec="$prec" -v div="$div" '
      {
         num  = $1;
         unit = num >= 1125899906842624 ? "P" \
              : num >= 1099511627776    ? "T" \
              : num >= 1073741824       ? "G" \
              : num >= 1048576          ? "M" \
              : num >= 1024             ? "k" \
              :                           "";
         while ( num >= div ) {
            num /= div;
         }
         printf "%.*f%s", prec, num, unit;
      }
   '
}

group_concat () {
   sed -e '{H; $!d;}' -e 'x' -e 's/\n[[:space:]]*\([[:digit:]]*\)[[:space:]]*/, \1x/g' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/, //' "${1}"
}

# ###########################################################################
# End report_formatting package
# ###########################################################################

# ###########################################################################
# summary_common package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/summary_common.sh
#   t/lib/bash/summary_common.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u

CMD_FILE="$( _which file 2>/dev/null )"
CMD_NM="$( _which nm 2>/dev/null )"
CMD_OBJDUMP="$( _which objdump 2>/dev/null )"

get_nice_of_pid () {
   local pid="$1"
   local niceness="$(ps -p $pid -o nice | awk '$1 !~ /[^0-9]/ {print $1; exit}')"

   if [ -n "${niceness}" ]; then
      echo $niceness
   else
      local tmpfile="$PT_TMPDIR/nice_through_c.tmp.c"
      _d "Getting the niceness from ps failed, somehow. We are about to try this:"
      cat <<EOC > "$tmpfile"

int main(void) {
   int priority = getpriority(PRIO_PROCESS, $pid);
   if ( priority == -1 && errno == ESRCH ) {
      return 1;
   }
   else {
      printf("%d\\n", priority);
      return 0;
   }
}

EOC
      local c_comp=$(_which gcc)
      if [ -z "${c_comp}" ]; then
         c_comp=$(_which cc)
      fi
      _d "$tmpfile: $( cat "$tmpfile" )"
      _d "$c_comp -xc \"$tmpfile\" -o \"$tmpfile\" && eval \"$tmpfile\""
      $c_comp -xc "$tmpfile" -o "$tmpfile" 2>/dev/null && eval "$tmpfile" 2>/dev/null
      if [ $? -ne 0 ]; then
         echo "?"
         _d "Failed to get a niceness value for $pid"
      fi
   fi
}

get_oom_of_pid () {
   local pid="$1"
   local oom_adj=""

   if [ -n "${pid}" -a -e /proc/cpuinfo ]; then
      if [ -s "/proc/$pid/oom_score_adj" ]; then
         oom_adj=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null)
         _d "For $pid, the oom value is $oom_adj, retreived from oom_score_adj"
      else
         oom_adj=$(cat "/proc/$pid/oom_adj" 2>/dev/null)
         _d "For $pid, the oom value is $oom_adj, retreived from oom_adj"
      fi
   fi

   if [ -n "${oom_adj}" ]; then
      echo "${oom_adj}"
   else
      echo "?"
      _d "Can't find the oom value for $pid"
   fi
}

has_symbols () {
   local executable="$(_which "$1")"
   local has_symbols=""

   if    [ "${CMD_FILE}" ] \
      && [ "$($CMD_FILE "${executable}" | grep 'not stripped' )" ]; then
      has_symbols=1
   elif    [ "${CMD_NM}" ] \
        || [ "${CMD_OBJDMP}" ]; then
      if    [ "${CMD_NM}" ] \
         && [ !"$("${CMD_NM}" -- "${executable}" 2>&1 | grep 'File format not recognized' )" ]; then
         if [ -z "$( $CMD_NM -- "${executable}" 2>&1 | grep ': no symbols' )" ]; then
            has_symbols=1
         fi
      elif [ -z "$("${CMD_OBJDUMP}" -t -- "${executable}" | grep '^no symbols$' )" ]; then
         has_symbols=1
      fi
   fi

   if [ "${has_symbols}" ]; then
      echo "Yes"
   else
      echo "No"
   fi
}

setup_data_dir () {
   local existing_dir="$1"
   local data_dir=""
   if [ -z "$existing_dir" ]; then
      mkdir "$PT_TMPDIR/data" || die "Cannot mkdir $PT_TMPDIR/data"
      data_dir="$PT_TMPDIR/data"
   else
      if [ ! -d "$existing_dir" ]; then
         mkdir "$existing_dir" || die "Cannot mkdir $existing_dir"
      elif [ "$( ls -A "$existing_dir" )" ]; then
         die "--save-samples directory isn't empty, halting."
      fi
      touch "$existing_dir/test" || die "Cannot write to $existing_dir"
      rm "$existing_dir/test"    || die "Cannot rm $existing_dir/test"
      data_dir="$existing_dir"
   fi
   echo "$data_dir"
}

get_var () {
   local varname="$1"
   local file="$2"
   awk -v pattern="${varname}" '$1 == pattern { if (length($2)) { len = length($1); print substr($0, len+index(substr($0, len+1), $2)) } }' "${file}" | tr -d '\r'
}

# ###########################################################################
# End summary_common package
# ###########################################################################

# ###########################################################################
# collect_mysql_info package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/collect_mysql_info.sh
#   t/lib/bash/collect_mysql_info.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################



CMD_MYSQL="${CMD_MYSQL:-""}"
CMD_MYSQLDUMP="${CMD_MYSQLDUMP:-""}"

collect_mysqld_instances () {
   local variables_file="$1"

   local pids="$(_pidof mysqld)"

   if [ -n "$pids" ]; then

      for pid in $pids; do
         local nice="$( get_nice_of_pid $pid )"
         local oom="$( get_oom_of_pid $pid )"
         echo "internal::nice_of_$pid    $nice" >> "$variables_file"
         echo "internal::oom_of_$pid    $oom" >> "$variables_file"
      done

      pids="$(echo $pids | sed -e 's/ /,/g')"
      ps ww -p "$pids" 2>/dev/null
   else
      echo "mysqld doesn't appear to be running"
   fi

}

find_my_cnf_file() {
   local file="$1"
   local port="${2:-""}"

   local cnf_file=""

   if [ "$port" ]; then
      cnf_file="$(grep --max-count 1 "/mysqld.*--port=$port" "$file" \
         | awk 'BEGIN{RS=" "; FS="=";} $1 ~ /--defaults-file/ { print $2; }')"
   else
      cnf_file="$(grep --max-count 1 '/mysqld' "$file" \
         | awk 'BEGIN{RS=" "; FS="=";} $1 ~ /--defaults-file/ { print $2; }')"
   fi

   if [ -z "$cnf_file" ]; then
      if [ -e "/etc/my.cnf" ]; then
         cnf_file="/etc/my.cnf"
      elif [ -e "/etc/mysql/my.cnf" ]; then
         cnf_file="/etc/mysql/my.cnf"
      elif [ -e "/var/db/mysql/my.cnf" ]; then
         cnf_file="/var/db/mysql/my.cnf";
      fi
   fi

   echo "$cnf_file"
}

collect_mysql_variables () {
   $CMD_MYSQL $EXT_ARGV -ss  -e 'SHOW /*!40100 GLOBAL*/ VARIABLES'
}

collect_mysql_status () {
   $CMD_MYSQL $EXT_ARGV -ss -e 'SHOW /*!50000 GLOBAL*/ STATUS'
}

collect_mysql_databases () {
   $CMD_MYSQL $EXT_ARGV -ss -e 'SHOW DATABASES' 2>/dev/null
}

collect_mysql_plugins () {
   $CMD_MYSQL $EXT_ARGV -ss -e 'SHOW PLUGINS' 2>/dev/null
}

collect_mysql_slave_status () {
   $CMD_MYSQL $EXT_ARGV -ssE -e 'SHOW SLAVE STATUS' 2>/dev/null
}

collect_mysql_innodb_status () {
   $CMD_MYSQL $EXT_ARGV -ssE -e 'SHOW /*!50000 ENGINE*/ INNODB STATUS' 2>/dev/null
}

collect_mysql_ndb_status () {
   $CMD_MYSQL $EXT_ARGV -ssE -e 'show /*!50000 ENGINE*/ NDB STATUS' 2>/dev/null
}

collect_mysql_processlist () {
   $CMD_MYSQL $EXT_ARGV -ssE -e 'SHOW FULL PROCESSLIST' 2>/dev/null
}

collect_mysql_users () {
   $CMD_MYSQL $EXT_ARGV -ss -e 'SELECT COUNT(*), SUM(user=""), SUM(password=""), SUM(password NOT LIKE "*%") FROM mysql.user' 2>/dev/null
   if [ "$?" -ne 0 ]; then
       $CMD_MYSQL $EXT_ARGV -ss -e 'SELECT COUNT(*), SUM(user=""), SUM(authentication_string=""), SUM(authentication_string NOT LIKE "*%") FROM mysql.user WHERE account_locked <> "Y" AND password_expired <> "Y" AND authentication_string <> ""' 2>/dev/null
   fi
}

collect_mysql_roles () {
   QUERY="SELECT DISTINCT User 'Role Name', if(from_user is NULL,0, 1) Active FROM mysql.user LEFT JOIN mysql.role_edges ON from_user=user WHERE account_locked='Y' AND password_expired='Y' AND authentication_string=''\G"
   $CMD_MYSQL $EXT_ARGV -ss -e "$QUERY" 2>/dev/null
}

collect_mysql_show_slave_hosts () {
   $CMD_MYSQL $EXT_ARGV -ssE -e 'SHOW SLAVE HOSTS' 2>/dev/null
}

collect_master_logs_status () {
   local master_logs_file="$1"
   local master_status_file="$2"
   $CMD_MYSQL $EXT_ARGV -ss -e 'SHOW MASTER LOGS' > "$master_logs_file" 2>/dev/null
   $CMD_MYSQL $EXT_ARGV -ss -e 'SHOW MASTER STATUS' > "$master_status_file" 2>/dev/null
}

collect_mysql_deferred_status () {
   local status_file="$1"
   collect_mysql_status > "$PT_TMPDIR/defer_gatherer"
   join "$status_file" "$PT_TMPDIR/defer_gatherer"
}

collect_internal_vars () {
   local mysqld_executables="${1:-""}"

   local FNV_64=""
   if $CMD_MYSQL $EXT_ARGV -e 'SELECT FNV_64("a")' >/dev/null 2>&1; then
      FNV_64="Enabled";
   else
      FNV_64="Unknown";
   fi

   local now="$($CMD_MYSQL $EXT_ARGV -ss -e 'SELECT NOW()')"
   local user="$($CMD_MYSQL $EXT_ARGV -ss -e 'SELECT CURRENT_USER()')"
   local trigger_count=$($CMD_MYSQL $EXT_ARGV -ss -e "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TRIGGERS" 2>/dev/null)

   echo "pt-summary-internal-mysql_executable    $CMD_MYSQL"
   echo "pt-summary-internal-now    $now"
   echo "pt-summary-internal-user   $user"
   echo "pt-summary-internal-FNV_64   $FNV_64"
   echo "pt-summary-internal-trigger_count   $trigger_count"

   if [ -e "$mysqld_executables" ]; then
      local i=1
      while read executable; do
         echo "pt-summary-internal-mysqld_executable_${i}   $(has_symbols "$executable")"
         i=$(($i + 1))
      done < "$mysqld_executables"
   fi
}

get_mysqldump_for () {
   local args="$1"
   local dbtodump="${2:-"--all-databases"}"

   $CMD_MYSQLDUMP $EXT_ARGV --no-data --skip-comments \
      --skip-add-locks --skip-add-drop-table --compact \
      --skip-lock-all-tables --skip-lock-tables --skip-set-charset \
      ${args} --databases $(local IFS=,; echo ${dbtodump})
}

get_mysqldump_args () {
   local file="$1"
   local trg_arg=""

   if $CMD_MYSQLDUMP --help --verbose 2>&1 | grep triggers >/dev/null; then
      trg_arg="--routines"
   fi

   if [ "${trg_arg}" ]; then
      local triggers="--skip-triggers"
      local trg=$(get_var "pt-summary-internal-trigger_count" "$file" )
      if [ -n "${trg}" ] && [ "${trg}" -gt 0 ]; then
         triggers="--triggers"
      fi
      trg_arg="${trg_arg} ${triggers}";
   fi
   echo "${trg_arg}"
}

collect_mysqld_executables () {
   local mysqld_instances="$1"

   local ps_opt="cmd="
   if [ "$(uname -s)" = "Darwin" ]; then
      ps_opt="command="
   fi

   for pid in $( grep '/mysqld' "$mysqld_instances" | awk '/^.*[0-9]/{print $1}' ); do
      ps -o $ps_opt -p $pid | sed -e 's/^\(.*mysqld\) .*/\1/'
   done | sort -u
}

collect_mysql_info () {
   local dir="$1"

   collect_mysql_variables     > "$dir/mysql-variables"
   collect_mysql_status        > "$dir/mysql-status"
   collect_mysql_databases     > "$dir/mysql-databases"
   collect_mysql_plugins       > "$dir/mysql-plugins"
   collect_mysql_slave_status  > "$dir/mysql-slave"
   collect_mysql_innodb_status > "$dir/innodb-status"
   collect_mysql_ndb_status    > "$dir/ndb-status"
   collect_mysql_processlist   > "$dir/mysql-processlist"   
   collect_mysql_users         > "$dir/mysql-users"
   collect_mysql_roles         > "$dir/mysql-roles"

   collect_mysqld_instances   "$dir/mysql-variables"  > "$dir/mysqld-instances"
   collect_mysqld_executables "$dir/mysqld-instances" > "$dir/mysqld-executables"
   collect_mysql_show_slave_hosts  "$dir/mysql-slave-hosts" > "$dir/mysql-slave-hosts"

   local binlog="$(get_var log_bin "$dir/mysql-variables")"
   if [ "${binlog}" ]; then
      collect_master_logs_status "$dir/mysql-master-logs" "$dir/mysql-master-status"
   fi

   local uptime="$(get_var Uptime "$dir/mysql-status")"
   local current_time="$($CMD_MYSQL $EXT_ARGV -ss -e \
                         "SELECT LEFT(NOW() - INTERVAL ${uptime} SECOND, 16)")"

   local port="$(get_var port "$dir/mysql-variables")"
   local cnf_file="$(find_my_cnf_file "$dir/mysqld-instances" ${port})"

   [ -e "$cnf_file" ] && cat "$cnf_file" > "$dir/mysql-config-file"

   local pid_file="$(get_var "pid_file" "$dir/mysql-variables")"
   local pid_file_exists=""
   [ -e "${pid_file}" ] && pid_file_exists=1
   echo "pt-summary-internal-pid_file_exists    $pid_file_exists" >> "$dir/mysql-variables"

   echo "pt-summary-internal-current_time    $current_time" >> "$dir/mysql-variables"
   echo "pt-summary-internal-Config_File_path    $cnf_file" >> "$dir/mysql-variables"
   collect_internal_vars "$dir/mysqld-executables" >> "$dir/mysql-variables"

   if [ "$OPT_DATABASES" -o "$OPT_ALL_DATABASES" ]; then
      local trg_arg="$(get_mysqldump_args "$dir/mysql-variables")"
      local dbs="${OPT_DATABASES:-""}"
      get_mysqldump_for "${trg_arg}" "$dbs" > "$dir/mysqldump"
   fi

   (
      sleep $OPT_SLEEP
      collect_mysql_deferred_status "$dir/mysql-status" > "$dir/mysql-status-defer"
   ) &
   _d "Forked child is $!"
}

# ###########################################################################
# End collect_mysql_info package
# ###########################################################################

# ###########################################################################
# report_mysql_info package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/report_mysql_info.sh
#   t/lib/bash/report_mysql_info.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u
POSIXLY_CORRECT=1

secs_to_time () {
   awk -v sec="$1" 'BEGIN {
      printf( "%d+%02d:%02d:%02d", sec / 86400, (sec % 86400) / 3600, (sec % 3600) / 60, sec % 60);
   }'
}

feat_on() {
   local file="$1"
   local varname="$2"
   [ -e "$file" ] || return

   if [ "$( grep "$varname" "${file}" )" ]; then
      local var="$(awk "\$1 ~ /^$2$/ { print \$2 }" $file)"
      if [ "${var}" = "ON" ]; then
         echo "Enabled"
      elif [ "${var}" = "OFF" -o "${var}" = "0" -o -z "${var}" ]; then
         echo "Disabled"
      elif [ "${3:-""}" = "ne" ]; then
         if [ "${var}" != "$4" ]; then
            echo "Enabled"
         else
            echo "Disabled"
         fi
      elif [ "${3:-""}" = "gt" ]; then
         if [ "${var}" -gt "$4" ]; then
            echo "Enabled"
         else
            echo "Disabled"
         fi
      elif [ "${var}" ]; then
         echo "Enabled"
      else
         echo "Disabled"
      fi
   else
      echo "Not Supported"
   fi
}

feat_on_renamed () {
   local file="$1"
   shift;

   for varname in "$@"; do
      local feat_on="$( feat_on "$file" $varname )"
      if [ "${feat_on:-"Not Supported"}" != "Not Supported" ]; then
         echo $feat_on
         return
      fi
   done

   echo "Not Supported"
}

get_table_cache () {
   local file="$1"

   [ -e "$file" ] || return

   local table_cache=""
   if [ "$( get_var table_open_cache "${file}" )" ]; then
      table_cache="$(get_var table_open_cache "${file}")"
   else
      table_cache="$(get_var table_cache "${file}")"
   fi
   echo ${table_cache:-0}
}

get_plugin_status () {
   local file="$1"
   local plugin="$2"

   local status="$(grep -w "$plugin" "$file" | awk '{ print $2 }')"

   echo ${status:-"Not found"}
}

collect_keyring_plugins() {
    $CMD_MYSQL $EXT_ARGV --table -ss -e 'SELECT PLUGIN_NAME, PLUGIN_STATUS FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_NAME LIKE "keyring%";'
}

collect_encrypted_tables() {
    $CMD_MYSQL $EXT_ARGV --table -ss -e "SELECT TABLE_SCHEMA, TABLE_NAME, CREATE_OPTIONS FROM INFORMATION_SCHEMA.TABLES WHERE CREATE_OPTIONS LIKE '%ENCRYPTION=\"Y\"%';"
}

collect_encrypted_tablespaces() {
    $CMD_MYSQL $EXT_ARGV --table -ss -e "SELECT SPACE, NAME, SPACE_TYPE from INFORMATION_SCHEMA.INNODB_SYS_TABLESPACES where FLAG&8192 = 8192;"
}



_NO_FALSE_NEGATIVES=""
parse_mysqld_instances () {
   local file="$1"
   local variables_file="$2"

   local socket=""
   local port=""
   local datadir=""
   local defaults_file=""

   [ -e "$file" ] || return

   echo "  Port  Data Directory             Nice OOM Socket"
   echo "  ===== ========================== ==== === ======"

   grep '/mysqld ' "$file" | while read line; do
      local pid=$(echo "$line" | awk '{print $1;}')
      for word in ${line}; do
         if echo "${word}" | grep -- "--socket=" > /dev/null; then
            socket="$(echo "${word}" | cut -d= -f2)"
         fi
         if echo "${word}" | grep -- "--port=" > /dev/null; then
            port="$(echo "${word}" | cut -d= -f2)"
         fi
         if echo "${word}" | grep -- "--datadir=" > /dev/null; then
            datadir="$(echo "${word}" | cut -d= -f2)"
         fi
         if echo "${word}" | grep -- "--defaults-file=" > /dev/null; then
            defaults_file="$(echo "${word}" | cut -d= -f2)"
         fi
      done
      
      if [ -n "${defaults_file:-""}" -a -r "${defaults_file:-""}" ]; then
         socket="${socket:-"$(grep "^socket\>" "$defaults_file" | tail -n1 | cut -d= -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')"}"
         port="${port:-"$(grep "^port\>" "$defaults_file" | tail -n1 | cut -d= -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')"}"
         datadir="${datadir:-"$(grep "^datadir\>" "$defaults_file" | tail -n1 | cut -d= -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')"}"
      fi

      local nice="$(get_var "internal::nice_of_$pid" "$variables_file")"
      local oom="$(get_var "internal::oom_of_$pid" "$variables_file")"
      if [ -n "${_NO_FALSE_NEGATIVES}" ]; then
         nice="?"
         oom="?"
      fi
      printf "  %5s %-26s %-4s %-3s %s\n" "${port}" "${datadir}" "${nice:-"?"}" "${oom:-"?"}" "${socket}"
      
      defaults_file=""
      socket=""
      port=""
      datadir=""
   done
}

get_mysql_timezone () {
   local file="$1"

   [ -e "$file" ] || return

   local tz="$(get_var time_zone "${file}")"
   if [ "${tz}" = "SYSTEM" ]; then
      tz="$(get_var system_time_zone "${file}")"
   fi
   echo "${tz}"
}

get_mysql_version () {
   local file="$1"

   name_val Version "$(get_var version "${file}") $(get_var version_comment "${file}")"
   name_val "Built On" "$(get_var version_compile_os "${file}") $(get_var version_compile_machine "${file}")"
}

get_mysql_uptime () {
   local uptime="$1"
   local restart="$2"
   uptime="$(secs_to_time ${uptime})"
   echo "${restart} (up ${uptime})"
}

summarize_binlogs () {
   local file="$1"

   [ -e "$file" ] || return

   local size="$(awk '{t += $2} END{printf "%0.f\n", t}' "$file")"
   name_val "Binlogs" $(wc -l "$file")
   name_val "Zero-Sized" $(grep -c '\<0$' "$file")
   name_val "Total Size" $(shorten ${size} 1)
}

format_users () {
   local file="$1"
   [ -e "$file" ] || return
   awk '{printf "%d users, %d anon, %d w/o pw, %d old pw\n", $1, $2, $3, $4}' "${file}"
}

format_binlog_filters () {
   local file="$1"
   [ -e "$file" ] || return
   name_val "binlog_do_db" "$(cut -f3 "$file")"
   name_val "binlog_ignore_db" "$(cut -f4 "$file")"
}

format_status_variables () {
   local file="$1"
   [ -e "$file" ] || return

   utime1="$(awk '/Uptime /{print $2}' "$file")";
   utime2="$(awk '/Uptime /{print $3}' "$file")";
   awk "
   BEGIN {
      utime1 = ${utime1};
      utime2 = ${utime2};
      udays  = utime1 / 86400;
      udiff  = utime2 - utime1;
      printf(\"%-35s %11s %11s %11s\\n\", \"Variable\", \"Per day\", \"Per second\", udiff \" secs\");
   }
   \$2 ~ /^[0-9]*\$/ {
      if ( \$2 > 0 && \$2 < 18446744073709551615 ) {
         if ( udays > 0 ) {
            fuzzy_var=\$2 / udays;
            ${fuzzy_formula};
            perday=fuzzy_var;
         }
         if ( utime1 > 0 ) {
            fuzzy_var=\$2 / utime1;
            ${fuzzy_formula};
            persec=fuzzy_var;
         }
         if ( udiff > 0 ) {
            fuzzy_var=(\$3 - \$2) / udiff;
            ${fuzzy_formula};
            nowsec=fuzzy_var;
         }
         perday = int(perday);
         persec = int(persec);
         nowsec = int(nowsec);
         if ( perday + persec + nowsec > 0 ) {
            perday_format=\"%11.f\";
            persec_format=\"%11.f\";
            nowsec_format=\"%11.f\";
            if ( perday == 0 ) { perday = \"\"; perday_format=\"%11s\"; }
            if ( persec == 0 ) { persec = \"\"; persec_format=\"%11s\"; }
            if ( nowsec == 0 ) { nowsec = \"\"; nowsec_format=\"%11s\"; }
            format=\"%-35s \" perday_format \" \" persec_format \" \" nowsec_format \"\\n\";
            printf(format, \$1, perday, persec, nowsec);
         }
      }
   }" "$file"
}

summarize_processlist () {
   local file="$1"

   [ -e "$file" ] || return

   for param in Command User Host db State; do
      echo
      printf '  %-30s %8s %7s %9s %9s\n' \
         "${param}" "COUNT(*)" Working "SUM(Time)" "MAX(Time)"
      echo "  ------------------------------" \
         "-------- ------- --------- ---------"
      cut -c1-80 "$file" \
         | awk "
         \$1 == \"${param}:\" {
            p = substr(\$0, index(\$0, \":\") + 2);
            if ( index(p, \":\") > 0 ) {
               p = substr(p, 1, index(p, \":\") - 1);
            }
            if ( length(p) > 30 ) {
               p = substr(p, 1, 30);
            }
         }
         \$1 == \"Time:\" {
            t = \$2;
            if ( t == \"NULL\" ) { 
                t = 0;
            }
         }
         \$1 == \"Command:\" {
            c = \$2;
         }
         \$1 == \"Info:\" {
            count[p]++;
            if ( c == \"Sleep\" ) {
               sleep[p]++;
            }
            if ( \"${param}\" == \"Command\" || c != \"Sleep\" ) {
               time[p] += t;
               if ( t > mtime[p] ) { mtime[p] = t; }
            }
         }
         END {
            for ( p in count ) {
               fuzzy_var=count[p]-sleep[p]; ${fuzzy_formula} fuzzy_work=fuzzy_var;
               fuzzy_var=count[p];          ${fuzzy_formula} fuzzy_count=fuzzy_var;
               fuzzy_var=time[p];           ${fuzzy_formula} fuzzy_time=fuzzy_var;
               fuzzy_var=mtime[p];          ${fuzzy_formula} fuzzy_mtime=fuzzy_var;
               printf \"  %-30s %8d %7d %9d %9d\n\", p, fuzzy_count, fuzzy_work, fuzzy_time, fuzzy_mtime;
            }
         }
      " | sort
   done
   echo
}

pretty_print_cnf_file () {
   local file="$1"

   [ -e "$file" ] || return

   perl -n -l -e '
      my $line = $_;
      if ( $line =~ /^\s*[a-zA-Z[]/ ) { 
         if ( $line=~/\s*(.*?)\s*=\s*(.*)\s*$/ ) { 
            printf("%-35s = %s\n", $1, $2)  
         } 
         elsif ( $line =~ /\s*\[/ ) { 
            print "\n$line" 
         } else {
            print $line
         } 
      }' "$file"

}


find_checkpoint_age() {
   local file="$1"
   awk '
   /Log sequence number/{
      if ( $5 ) {
         lsn = $5 + ($4 * 4294967296);
      }
      else {
         lsn = $4;
      }
   }
   /Last checkpoint at/{
      if ( $5 ) {
         print lsn - ($5 + ($4 * 4294967296));
      }
      else {
         print lsn - $4;
      }
   }
   ' "$file"
}

find_pending_io_reads() {
   local file="$1"

   [ -e "$file" ] || return

   awk '
   /Pending normal aio reads/ {
      normal_aio_reads  = substr($5, 1, index($5, ","));
   }
   /ibuf aio reads/ {
      ibuf_aio_reads = substr($4, 1, index($4, ","));
   }
   /pending preads/ {
      preads = $1;
   }
   /Pending reads/ {
      reads = $3;
   }
   END {
      printf "%d buf pool reads, %d normal AIO", reads, normal_aio_reads;
      printf ", %d ibuf AIO, %d preads", ibuf_aio_reads, preads;
   }
   ' "${file}"
}

find_pending_io_writes() {
   local file="$1"

   [ -e "$file" ] || return

   awk '
   /aio writes/ {
      aio_writes = substr($NF, 1, index($NF, ","));
   }
   /ibuf aio reads/ {
      log_ios = substr($7, 1, index($7, ","));
      sync_ios = substr($10, 1, index($10, ","));
   }
   /pending log writes/ {
      log_writes = $1;
      chkp_writes = $5;
   }
   /pending pwrites/ {
      pwrites = $4;
   }
   /Pending writes:/ {
      lru = substr($4, 1, index($4, ","));
      flush_list = substr($7, 1, index($7, ","));
      single_page = $NF;
   }
   END {
      printf "%d buf pool (%d LRU, %d flush list, %d page); %d AIO, %d sync, %d log IO (%d log, %d chkp); %d pwrites", lru + flush_list + single_page, lru, flush_list, single_page, aio_writes, sync_ios, log_ios, log_writes, chkp_writes, pwrites;
   }
   ' "${file}"
}

find_pending_io_flushes() {
   local file="$1"

   [ -e "$file" ] || return

   awk '
   /Pending flushes/ {
      log_flushes = substr($5, 1, index($5, ";"));
      buf_pool = $NF;
   }
   END {
      printf "%d buf pool, %d log", buf_pool, log_flushes;
   }
   ' "${file}"
}

summarize_undo_log_entries() {
   local file="$1"

   [ -e "$file" ] || return

   grep 'undo log entries' "${file}" \
      | sed -e 's/^.*undo log entries \([0-9]*\)/\1/' \
      | awk '
      {
         count++;
         sum += $1;
         if ( $1 > max ) {
            max = $1;
         }
      }
      END {
         printf "%d transactions, %d total undo, %d max undo\n", count, sum, max;
      }'
}

find_max_trx_time() {
   local file="$1"

   [ -e "$file" ] || return

   awk '
   BEGIN {
      max = 0;
   }
   /^---TRANSACTION.* sec,/ {
      for ( i = 0; i < 7; ++i ) {
         if ( $i == "sec," ) {
            j = i-1;
            if ( max < $j ) {
               max = $j;
            }
         }
      }
   }
   END {
      print max;
   }' "${file}"
}

find_transation_states () {
   local file="$1"
   local tmpfile="$PT_TMPDIR/find_transation_states.tmp"

   [ -e "$file" ] || return

   awk -F, '/^---TRANSACTION/{print $2}' "${file}"   \
                        | sed -e 's/ [0-9]* sec.*//' \
                        | sort                       \
                        | uniq -c > "${tmpfile}"
   group_concat "${tmpfile}"
}

format_innodb_status () {
   local file=$1

   [ -e "$file" ] || return

   name_val "Checkpoint Age"      "$(shorten $(find_checkpoint_age "${file}") 0)"
   name_val "InnoDB Queue"        "$(awk '/queries inside/{print}' "${file}")"
   name_val "Oldest Transaction"  "$(find_max_trx_time "${file}") Seconds";
   name_val "History List Len"    "$(awk '/History list length/{print $4}' "${file}")"
   name_val "Read Views"          "$(awk '/read views open inside/{print $1}' "${file}")"
   name_val "Undo Log Entries"    "$(summarize_undo_log_entries "${file}")"
   name_val "Pending I/O Reads"   "$(find_pending_io_reads "${file}")"
   name_val "Pending I/O Writes"  "$(find_pending_io_writes "${file}")"
   name_val "Pending I/O Flushes" "$(find_pending_io_flushes "${file}")"
   name_val "Transaction States"  "$(find_transation_states "${file}" )"
   if grep 'TABLE LOCK table' "${file}" >/dev/null ; then
      echo "Tables Locked"
      awk '/^TABLE LOCK table/{print $4}' "${file}" \
         | sort | uniq -c | sort -rn
   fi
   if grep 'has waited at' "${file}" > /dev/null ; then
      echo "Semaphore Waits"
      grep 'has waited at' "${file}" | cut -d' ' -f6-8 \
         | sort | uniq -c | sort -rn
   fi
   if grep 'reserved it in mode' "${file}" > /dev/null; then
      echo "Semaphore Holders"
      awk '/has reserved it in mode/{
         print substr($0, 1 + index($0, "("), index($0, ")") - index($0, "(") - 1);
      }' "${file}" | sort | uniq -c | sort -rn
   fi
   if grep -e 'Mutex at' -e 'lock on' "${file}" >/dev/null 2>&1; then
      echo "Mutexes/Locks Waited For"
      grep -e 'Mutex at' -e 'lock on' "${file}" | sed -e 's/^[XS]-//' -e 's/,.*$//' \
         | sort | uniq -c | sort -rn
   fi
}

format_ndb_status() {
   local file=$1

   [ -e "$file" ] || return
   egrep '^[ \t]*Name:|[ \t]*Status:' $file|sed 's/^[ \t]*//g'|while read line; do echo $line; echo $line | grep '^Status:'>/dev/null && echo ; done
}

format_keyring_plugins() {
    local keyring_plugins="$1"
    local encrypted_tables="$2"

    if [ -z "$keyring_plugins" ]; then 
        echo "No keyring plugins found"
        if [ ! -z "$encrypted_tables" ]; then
            echo "Warning! There are encrypted tables but keyring plugins are not loaded"
        fi
     else
        echo "Keyring plugins:"
        echo "'$keyring_plugins'"
    fi
}

format_encrypted_tables() {
   local encrypted_tables="$1"
   if [ ! -z "$encrypted_tables" ]; then
       echo "Encrypted tables:"
       echo "$encrypted_tables"
   fi
}

format_encrypted_tablespaces() {
   local encrypted_tablespaces="$1"
   if [ ! -z "$encrypted_tablespaces" ]; then
       echo "Encrypted tablespaces:"
       echo "$encrypted_tablespaces"
   fi
}

format_mysql_roles() {
   local file=$1
   [ -e "$file" ] || return
   cat $file
}

format_overall_db_stats () {
   local file="$1"
   local tmpfile="$PT_TMPDIR/format_overall_db_stats.tmp"

   [ -e "$file" ] || return

   echo
   awk '
      BEGIN {
         db      = "{chosen}";
         num_dbs = 0;
      }
      /^USE `.*`;$/ {
         db = substr($2, 2, length($2) - 3);
         if ( db_seen[db]++ == 0 ) {
            dbs[num_dbs] = db;
            num_dbs++;
         }
      }
      /^CREATE TABLE/ {
         if (num_dbs == 0) {
            num_dbs     = 1;
            db_seen[db] = 1;
            dbs[0]      = db;
         }
         counts[db ",tables"]++;
      }
      /CREATE ALGORITHM=/ {
         counts[db ",views"]++;
      }
      /03 CREATE.*03 PROCEDURE/ {
         counts[db ",sps"]++;
      }
      /03 CREATE.*03 FUNCTION/ {
         counts[db ",func"]++;
      }
      /03 CREATE.*03 TRIGGER/ {
         counts[db ",trg"]++;
      }
      /FOREIGN KEY/ {
         counts[db ",fk"]++;
      }
      /PARTITION BY/ {
         counts[db ",partn"]++;
      }
      END {
         mdb = length("Database");
         for ( i = 0; i < num_dbs; i++ ) {
            if ( length(dbs[i]) > mdb ) {
               mdb = length(dbs[i]);
            }
         }
         fmt = "  %-" mdb "s %6s %5s %3s %5s %5s %5s %5s\n";
         printf fmt, "Database", "Tables", "Views", "SPs", "Trigs", "Funcs", "FKs", "Partn";
         for ( i=0;i<num_dbs;i++ ) {
            db = dbs[i];
            printf fmt, db, counts[db ",tables"], counts[db ",views"], counts[db ",sps"], counts[db ",trg"], counts[db ",func"], counts[db ",fk"], counts[db ",partn"];
         }
      }
   ' "$file" > "$tmpfile"
   head -n2 "$tmpfile"
   tail -n +3 "$tmpfile" | sort

   echo
   awk '
      BEGIN {
         db          = "{chosen}";
         num_dbs     = 0;
         num_engines = 0;
      }
      /^USE `.*`;$/ {
         db = substr($2, 2, length($2) - 3);
         if ( db_seen[db]++ == 0 ) {
            dbs[num_dbs] = db;
            num_dbs++;
         }
      }
      /^\) ENGINE=/ {
         if (num_dbs == 0) {
            num_dbs     = 1;
            db_seen[db] = 1;
            dbs[0]      = db;
         }
         engine=substr($2, index($2, "=") + 1);
         if ( engine_seen[tolower(engine)]++ == 0 ) {
            engines[num_engines] = engine;
            num_engines++;
         }
         counts[db "," engine]++;
      }
      END {
         mdb = length("Database");
         for ( i=0;i<num_dbs;i++ ) {
            db = dbs[i];
            if ( length(db) > mdb ) {
               mdb = length(db);
            }
         }
         fmt = "  %-" mdb "s"
         printf fmt, "Database";
         for ( i=0;i<num_engines;i++ ) {
            engine = engines[i];
            fmts[engine] = " %" length(engine) "s";
            printf fmts[engine], engine;
         }
         print "";
         for ( i=0;i<num_dbs;i++ ) {
            db = dbs[i];
            printf fmt, db;
            for ( j=0;j<num_engines;j++ ) {
               engine = engines[j];
               printf fmts[engine], counts[db "," engine];
            }
            print "";
         }
      }
   ' "$file" > "$tmpfile"
   head -n1 "$tmpfile"
   tail -n +2 "$tmpfile" | sort

   echo
   awk '
      BEGIN {
         db        = "{chosen}";
         num_dbs   = 0;
         num_idxes = 0;
      }
      /^USE `.*`;$/ {
         db = substr($2, 2, length($2) - 3);
         if ( db_seen[db]++ == 0 ) {
            dbs[num_dbs] = db;
            num_dbs++;
         }
      }
      /KEY/ {
         if (num_dbs == 0) {
            num_dbs     = 1;
            db_seen[db] = 1;
            dbs[0]      = db;
         }
         idx="BTREE";
         if ( $0 ~ /SPATIAL/ ) {
            idx="SPATIAL";
         }
         if ( $0 ~ /FULLTEXT/ ) {
            idx="FULLTEXT";
         }
         if ( $0 ~ /USING RTREE/ ) {
            idx="RTREE";
         }
         if ( $0 ~ /USING HASH/ ) {
            idx="HASH";
         }
         if ( idx_seen[idx]++ == 0 ) {
            idxes[num_idxes] = idx;
            num_idxes++;
         }
         counts[db "," idx]++;
      }
      END {
         mdb = length("Database");
         for ( i=0;i<num_dbs;i++ ) {
            db = dbs[i];
            if ( length(db) > mdb ) {
               mdb = length(db);
            }
         }
         fmt = "  %-" mdb "s"
         printf fmt, "Database";
         for ( i=0;i<num_idxes;i++ ) {
            idx = idxes[i];
            fmts[idx] = " %" length(idx) "s";
            printf fmts[idx], idx;
         }
         print "";
         for ( i=0;i<num_dbs;i++ ) {
            db = dbs[i];
            printf fmt, db;
            for ( j=0;j<num_idxes;j++ ) {
               idx = idxes[j];
               printf fmts[idx], counts[db "," idx];
            }
            print "";
         }
      }
   ' "$file" > "$tmpfile"
   head -n1 "$tmpfile"
   tail -n +2 "$tmpfile" | sort

   echo
   awk '
      BEGIN {
         db          = "{chosen}";
         num_dbs     = 0;
         num_types = 0;
      }
      /^USE `.*`;$/ {
         db = substr($2, 2, length($2) - 3);
         if ( db_seen[db]++ == 0 ) {
            dbs[num_dbs] = db;
            num_dbs++;
         }
      }
      /^  `/ {
         if (num_dbs == 0) {
            num_dbs     = 1;
            db_seen[db] = 1;
            dbs[0]      = db;
         }
         str = $0;
         str = substr(str, index(str, "`") + 1);
         str = substr(str, index(str, "`") + 2);
         if ( index(str, " ") > 0 ) {
            str = substr(str, 1, index(str, " ") - 1);
         }
         if ( index(str, ",") > 0 ) {
            str = substr(str, 1, index(str, ",") - 1);
         }
         if ( index(str, "(") > 0 ) {
            str = substr(str, 1, index(str, "(") - 1);
         }
         type = str;
         if ( type_seen[type]++ == 0 ) {
            types[num_types] = type;
            num_types++;
         }
         counts[db "," type]++;
      }
      END {
         mdb = length("Database");
         for ( i=0;i<num_dbs;i++ ) {
            db = dbs[i];
            if ( length(db) > mdb ) {
               mdb = length(db);
            }
         }
         fmt = "  %-" mdb "s"
         mtlen = 0; # max type length
         for ( i=0;i<num_types;i++ ) {
            type = types[i];
            if ( length(type) > mtlen ) {
               mtlen = length(type);
            }
         }
         for ( i=1;i<=mtlen;i++ ) {
            printf "  %-" mdb "s", "";
            for ( j=0;j<num_types;j++ ) {
               type = types[j];
               if ( i > length(type) ) {
                  ch = " ";
               }
               else {
                  ch = substr(type, i, 1);
               }
               printf(" %3s", ch);
            }
            print "";
         }
         printf "  %-" mdb "s", "Database";
         for ( i=0;i<num_types;i++ ) {
            printf " %3s", "===";
         }
         print "";
         for ( i=0;i<num_dbs;i++ ) {
            db = dbs[i];
            printf fmt, db;
            for ( j=0;j<num_types;j++ ) {
               type = types[j];
               printf " %3s", counts[db "," type];
            }
            print "";
         }
      }
   ' "$file" > "$tmpfile"
   local hdr=$(grep -n Database "$tmpfile" | cut -d: -f1);
   head -n${hdr} "$tmpfile"
   tail -n +$((${hdr} + 1)) "$tmpfile" | sort
   echo
}

section_percona_server_features () {
   local file="$1"

   [ -e "$file" ] || return

   name_val "Table & Index Stats"   \
            "$(feat_on_renamed "$file" userstat_running userstat)"
   name_val "Multiple I/O Threads"  \
            "$(feat_on "$file" innodb_read_io_threads gt 1)"

   name_val "Corruption Resilient"  \
            "$(feat_on_renamed "$file" innodb_pass_corrupt_table innodb_corrupt_table_action)"

   name_val "Durable Replication"   \
            "$(feat_on_renamed "$file" innodb_overwrite_relay_log_info innodb_recovery_update_relay_log)"

   name_val "Import InnoDB Tables"  \
            "$(feat_on_renamed "$file" innodb_expand_import innodb_import_table_from_xtrabackup)"

   name_val "Fast Server Restarts"  \
            "$(feat_on_renamed "$file" innodb_auto_lru_dump innodb_buffer_pool_restore_at_startup)"
   
   name_val "Enhanced Logging"      \
            "$(feat_on "$file" log_slow_verbosity ne microtime)"
   name_val "Replica Perf Logging"  \
            "$(feat_on "$file" log_slow_slave_statements)"

   name_val "Response Time Hist."   \
            "$(feat_on_renamed "$file" enable_query_response_time_stats query_response_time_stats)"

   local smooth_flushing="$(feat_on_renamed "$file" innodb_adaptive_checkpoint innodb_adaptive_flushing_method)"
   if  [ "${smooth_flushing:-""}" != "Not Supported" ]; then
      if [ -n "$(get_var innodb_adaptive_checkpoint "$file")" ]; then
         smooth_flushing="$(feat_on "$file" "innodb_adaptive_checkpoint" ne none)"
      else
         smooth_flushing="$(feat_on "$file" "innodb_adaptive_flushing_method" ne native)"
      fi
   fi
   name_val "Smooth Flushing" "$smooth_flushing"
   
   name_val "HandlerSocket NoSQL"   \
            "$(feat_on "$file" handlersocket_port)"
   name_val "Fast Hash UDFs"   \
            "$(get_var "pt-summary-internal-FNV_64" "$file")"
}

section_myisam () {
   local variables_file="$1"
   local status_file="$2"

   [ -e "$variables_file" -a -e "$status_file" ] || return

   local buf_size="$(get_var key_buffer_size "$variables_file")"
   local blk_size="$(get_var key_cache_block_size "$variables_file")"
   local blk_unus="$(get_var Key_blocks_unused "$status_file")"
   local blk_unfl="$(get_var Key_blocks_not_flushed "$variables_file")"
   local unus=$((${blk_unus:-0} * ${blk_size:-0}))
   local unfl=$((${blk_unfl:-0} * ${blk_size:-0}))
   local used=$((${buf_size:-0} - ${unus}))

   name_val "Key Cache" "$(shorten ${buf_size} 1)"
   name_val "Pct Used" "$(fuzzy_pct ${used} ${buf_size})"
   name_val "Unflushed" "$(fuzzy_pct ${unfl} ${buf_size})"
}

section_innodb () {
   local variables_file="$1"
   local status_file="$2"

   [ -e "$variables_file" -a -e "$status_file" ] || return

   local version=$(get_var innodb_version "$variables_file")
   name_val Version ${version:-default}

   local bp_size="$(get_var innodb_buffer_pool_size "$variables_file")"
   name_val "Buffer Pool Size" "$(shorten "${bp_size:-0}" 1)"

   local bp_pags="$(get_var Innodb_buffer_pool_pages_total "$status_file")"
   local bp_free="$(get_var Innodb_buffer_pool_pages_free "$status_file")"
   local bp_dirt="$(get_var Innodb_buffer_pool_pages_dirty "$status_file")"
   local bp_fill=$((${bp_pags} - ${bp_free}))
   name_val "Buffer Pool Fill"   "$(fuzzy_pct ${bp_fill} ${bp_pags})"
   name_val "Buffer Pool Dirty"  "$(fuzzy_pct ${bp_dirt} ${bp_pags})"

   name_val "File Per Table"      $(get_var innodb_file_per_table "$variables_file")
   name_val "Page Size"           $(shorten $(get_var Innodb_page_size "$status_file") 0)

   local log_size="$(get_var innodb_log_file_size "$variables_file")"
   local log_file="$(get_var innodb_log_files_in_group "$variables_file")"
   local log_total=$(awk "BEGIN {printf \"%.2f\n\", ${log_size}*${log_file}}" )
   name_val "Log File Size"       \
            "${log_file} * $(shorten ${log_size} 1) = $(shorten ${log_total} 1)"
   name_val "Log Buffer Size"     \
            "$(shorten $(get_var innodb_log_buffer_size "$variables_file") 0)"
   name_val "Flush Method"        \
            "$(get_var innodb_flush_method "$variables_file")"
   name_val "Flush Log At Commit" \
            "$(get_var innodb_flush_log_at_trx_commit "$variables_file")"
   name_val "XA Support"          \
            "$(get_var innodb_support_xa "$variables_file")"
   name_val "Checksums"           \
            "$(get_var innodb_checksums "$variables_file")"
   name_val "Doublewrite"         \
            "$(get_var innodb_doublewrite "$variables_file")"
   name_val "R/W I/O Threads"     \
            "$(get_var innodb_read_io_threads "$variables_file") $(get_var innodb_write_io_threads "$variables_file")"
   name_val "I/O Capacity"        \
            "$(get_var innodb_io_capacity "$variables_file")"
   name_val "Thread Concurrency"  \
            "$(get_var innodb_thread_concurrency "$variables_file")"
   name_val "Concurrency Tickets" \
            "$(get_var innodb_concurrency_tickets "$variables_file")"
   name_val "Commit Concurrency"  \
            "$(get_var innodb_commit_concurrency "$variables_file")"
   name_val "Txn Isolation Level" \
            "$(get_var tx_isolation "$variables_file")"
   name_val "Adaptive Flushing"   \
            "$(get_var innodb_adaptive_flushing "$variables_file")"
   name_val "Adaptive Checkpoint" \
            "$(get_var innodb_adaptive_checkpoint "$variables_file")"
}

section_rocksdb () {
    local variables_file="$1"
    local status_file="$2"

    local NAME_VAL_LEN=32

    [ -e "$variables_file" -a -e "$status_file" ] || return

    name_val "Block Cache Size" "$(shorten $(get_var rocksdb_block_cache_size "$variables_file") 0)"
    name_val "Block Size" "$(shorten $(get_var rocksdb_block_size "$variables_file") 0)"
    name_val "Bytes Per Sync" "$(shorten $(get_var rocksdb_bytes_per_sync "$variables_file") 0)"
    name_val "Compaction Seq Deletes " "$(shorten $(get_var rocksdb_compaction_sequential_deletes "$variables_file") 0)"
    name_val "Compaction Seq Deletes Count SD" "$(get_var rocksdb_compaction_sequential_deletes_count_sd "$variables_file")"
    name_val "Compaction Seq Deletes Window" "$(shorten $(get_var rocksdb_compaction_sequential_deletes_window "$variables_file") 0)"
    name_val "Default CF Options" "$(get_var rocksdb_default_cf_options "$variables_file")"
    name_val "Max Background Jobs" "$(shorten $(get_var rocksdb_max_background_jobs "$variables_file") 0)"
    name_val "Max Block Cache Size" "$(shorten $(get_var rocksdb_max_block_cache_size "$variables_file") 0)"
    name_val "Max Block Size" "$(shorten $(get_var rocksdb_max_block_size "$variables_file") 0)"
    name_val "Max Open Files" "$(shorten $(get_var rocksdb_max_open_files "$variables_file") 0)"
    name_val "Max Total Wal Size" "$(shorten $(get_var rocksdb_max_total_wal_size "$variables_file") 0)"
    name_val "Rate Limiter Bytes Per Second" "$(shorten $(get_var rocksdb_rate_limiter_bytes_per_sec "$variables_file") 0)"
    name_val "Rate Limiter Bytes Per Sync" "$(shorten $(get_var rocksdb_bytes_per_sync "$variables_file") 0)"
    name_val "Rate Limiter Wal Bytes Per Sync" "$(shorten $(get_var rocksdb_wal_bytes_per_sync "$variables_file") 0)"
    name_val "Table Cache NumHardBits" "$(shorten $(get_var rocksdb_table_cache_numshardbits "$variables_file") 0)"
    name_val "Wal Bytes per Sync" "$(shorten $(get_var rocksdb_wal_bytes_per_sync "$variables_file") 0)"
}

section_noteworthy_variables () {
   local file="$1"

   [ -e "$file" ] || return

   name_val "Auto-Inc Incr/Offset" "$(get_var auto_increment_increment "$file")/$(get_var auto_increment_offset "$file")"
   for v in \
      default_storage_engine flush_time init_connect init_file sql_mode;
   do
      name_val "${v}" "$(get_var ${v} "$file")"
   done
   for v in \
      join_buffer_size sort_buffer_size read_buffer_size read_rnd_buffer_size \
      bulk_insert_buffer max_heap_table_size tmp_table_size \
      max_allowed_packet thread_stack;
   do
      name_val "${v}" "$(shorten $(get_var ${v} "$file") 0)"
   done
   for v in log log_error log_warnings log_slow_queries \
         log_queries_not_using_indexes log_slave_updates;
   do
      name_val "${v}" "$(get_var ${v} "$file")"
   done
}

_semi_sync_stats_for () {
   local target="$1"
   local file="$2"

   [ -e "$file" ] || return

   local semisync_status="$(get_var "Rpl_semi_sync_${target}_status" "${file}" )"
   local semisync_trace="$(get_var "rpl_semi_sync_${target}_trace_level" "${file}")"

   local trace_extra=""
   if [ -n "${semisync_trace}" ]; then
      if [ $semisync_trace -eq 1 ]; then
         trace_extra="general (for example, time function failures) "
      elif [ $semisync_trace -eq 16 ]; then
         trace_extra="detail (more verbose information) "
      elif [ $semisync_trace -eq 32 ]; then
         trace_extra="net wait (more information about network waits)"
      elif [ $semisync_trace -eq 64 ]; then
         trace_extra="function (information about function entry and exit)"
      else
         trace_extra="Unknown setting"
      fi
   fi
   
   name_val "${target} semisync status" "${semisync_status}"
   name_val "${target} trace level" "${semisync_trace}, ${trace_extra}"

   if [ "${target}" = "master" ]; then
      name_val "${target} timeout in milliseconds" \
               "$(get_var "rpl_semi_sync_${target}_timeout" "${file}")"
      name_val "${target} waits for slaves"        \
               "$(get_var "rpl_semi_sync_${target}_wait_no_slave" "${file}")"

      _d "Prepend Rpl_semi_sync_master_ to the following"
      for v in                                              \
         clients net_avg_wait_time net_wait_time net_waits  \
         no_times no_tx timefunc_failures tx_avg_wait_time  \
         tx_wait_time tx_waits wait_pos_backtraverse        \
         wait_sessions yes_tx;
      do
         name_val "${target} ${v}" \
                  "$( get_var "Rpl_semi_sync_master_${v}" "${file}" )"
      done
   fi
}

noncounters_pattern () {
   local noncounters_pattern=""

   for var in Compression Delayed_insert_threads Innodb_buffer_pool_pages_data \
      Innodb_buffer_pool_pages_dirty Innodb_buffer_pool_pages_free \
      Innodb_buffer_pool_pages_latched Innodb_buffer_pool_pages_misc \
      Innodb_buffer_pool_pages_total Innodb_data_pending_fsyncs \
      Innodb_data_pending_reads Innodb_data_pending_writes \
      Innodb_os_log_pending_fsyncs Innodb_os_log_pending_writes \
      Innodb_page_size Innodb_row_lock_current_waits Innodb_row_lock_time_avg \
      Innodb_row_lock_time_max Key_blocks_not_flushed Key_blocks_unused \
      Key_blocks_used Last_query_cost Max_used_connections Ndb_cluster_node_id \
      Ndb_config_from_host Ndb_config_from_port Ndb_number_of_data_nodes \
      Not_flushed_delayed_rows Open_files Open_streams Open_tables \
      Prepared_stmt_count Qcache_free_blocks Qcache_free_memory \
      Qcache_queries_in_cache Qcache_total_blocks Rpl_status \
      Slave_open_temp_tables Slave_running Ssl_cipher Ssl_cipher_list \
      Ssl_ctx_verify_depth Ssl_ctx_verify_mode Ssl_default_timeout \
      Ssl_session_cache_mode Ssl_session_cache_size Ssl_verify_depth \
      Ssl_verify_mode Ssl_version Tc_log_max_pages_used Tc_log_page_size \
      Threads_cached Threads_connected Threads_running \
      Uptime_since_flush_status;
   do
      if [ -z "${noncounters_pattern}" ]; then
         noncounters_pattern="${var}"
      else
         noncounters_pattern="${noncounters_pattern}\|${var}"
      fi
   done
   echo $noncounters_pattern
}

section_mysqld () {
   local executables_file="$1"
   local variables_file="$2"

   [ -e "$executables_file" -a -e "$variables_file" ] || return

   section "MySQL Executable"
   local i=1;
   while read executable; do
      name_val "Path to executable" "$executable"
      name_val "Has symbols" "$( get_var "pt-summary-internal-mysqld_executable_${i}" "$variables_file" )"
      i=$(($i + 1))
   done < "$executables_file"
}

section_slave_hosts () {
   local slave_hosts_file="$1"

   [ -e "$slave_hosts_file" ] || return

   section "Slave Hosts"
   if [ -s "$slave_hosts_file" ]; then
       cat "$slave_hosts_file"
   else
       echo "No slaves found"
   fi
}

section_mysql_files () {
   local variables_file="$1"

   section "MySQL Files"
   for file_name in pid_file slow_query_log_file general_log_file log_error; do
      local file="$(get_var "${file_name}" "$variables_file")"
      local name_out="$(echo "$file_name" | sed 'y/[a-z]/[A-Z]/')"
      if [ -e "${file}" ]; then
         name_val "$name_out" "$file"
         name_val "${name_out} Size" "$(du "$file" | awk '{print $1}')"
      else
         name_val "$name_out" "(does not exist)"
      fi
   done
}

section_percona_xtradb_cluster () {
   local mysql_var="$1"
   local mysql_status="$2"

   name_val "Cluster Name"    "$(get_var "wsrep_cluster_name" "$mysql_var")"
   name_val "Cluster Address" "$(get_var "wsrep_cluster_address" "$mysql_var")"
   name_val "Cluster Size"    "$(get_var "wsrep_cluster_size" "$mysql_status")"
   name_val "Cluster Nodes"   "$(get_var "wsrep_incoming_addresses" "$mysql_status")"

   name_val "Node Name"       "$(get_var "wsrep_node_name" "$mysql_var")"
   name_val "Node Status"     "$(get_var "wsrep_cluster_status" "$mysql_status")"

   name_val "SST Method"      "$(get_var "wsrep_sst_method" "$mysql_var")"
   name_val "Slave Threads"   "$(get_var "wsrep_slave_threads" "$mysql_var")"
   
   name_val "Ignore Split Brain" "$( parse_wsrep_provider_options "pc.ignore_sb" "$mysql_var" )"
   name_val "Ignore Quorum" "$( parse_wsrep_provider_options "pc.ignore_quorum" "$mysql_var" )"
   
   name_val "gcache Size"      "$( parse_wsrep_provider_options "gcache.size" "$mysql_var" )"
   name_val "gcache Directory" "$( parse_wsrep_provider_options "gcache.dir" "$mysql_var" )"
   name_val "gcache Name"      "$( parse_wsrep_provider_options "gcache.name" "$mysql_var" )"
}

parse_wsrep_provider_options () {
   local looking_for="$1"
   local mysql_var_file="$2"

   grep wsrep_provider_options "$mysql_var_file" \
   | perl -Mstrict -le '
      my $provider_opts = scalar(<STDIN>);
      my $looking_for   = $ARGV[0];
      my %opts          = $provider_opts =~ /(\S+)\s*=\s*(\S*)(?:;|$)/g;
      print $opts{$looking_for};
   ' "$looking_for"
}

report_jemalloc_enabled() {
  local JEMALLOC_STATUS=''
  local GENERAL_JEMALLOC_STATUS=0
  local JEMALLOC_LOCATION=''

  for pid in $(pidof mysqld); do
     grep -qc jemalloc /proc/${pid}/environ || ldd $(which mysqld) 2>/dev/null | grep -qc jemalloc
     jemalloc_status=$?
     if [ $jemalloc_status = 1 ]; then
       echo "jemalloc is not enabled in mysql config for process with id ${pid}" 
     else
       echo "jemalloc enabled in mysql config for process with id ${pid}"
       GENERAL_JEMALLOC_STATUS=1
     fi
  done

  if [ $GENERAL_JEMALLOC_STATUS -eq 1 ]; then
     JEMALLOC_LOCATION=$(find /usr/lib64/ /usr/lib/x86_64-linux-gnu /usr/lib -name "libjemalloc.*" 2>/dev/null | head -n 1)
     if [ -z "$JEMALLOC_LOCATION" ]; then
       echo "Jemalloc library not found"
     else
       echo "Using jemalloc from $JEMALLOC_LOCATION"
     fi
  fi
 
}

report_mysql_summary () {
   local dir="$1"

   local NAME_VAL_LEN=25


   section "Percona Toolkit MySQL Summary Report"
   name_val "System time" "`date -u +'%F %T UTC'` (local TZ: `date +'%Z %z'`)"
   section "Instances"
   parse_mysqld_instances "$dir/mysqld-instances" "$dir/mysql-variables"

   section_mysqld "$dir/mysqld-executables" "$dir/mysql-variables"

   section_slave_hosts "$dir/mysql-slave-hosts"
   local user="$(get_var "pt-summary-internal-user" "$dir/mysql-variables")"
   local port="$(get_var port "$dir/mysql-variables")"
   local now="$(get_var "pt-summary-internal-now" "$dir/mysql-variables")"
   section "Report On Port ${port}"
   name_val User "${user}"
   name_val Time "${now} ($(get_mysql_timezone "$dir/mysql-variables"))"
   name_val Hostname "$(get_var hostname "$dir/mysql-variables")"
   get_mysql_version "$dir/mysql-variables"

   local uptime="$(get_var Uptime "$dir/mysql-status")"
   local current_time="$(get_var "pt-summary-internal-current_time" "$dir/mysql-variables")"
   name_val Started "$(get_mysql_uptime "${uptime}" "${current_time}")"

   local num_dbs="$(grep -c . "$dir/mysql-databases")"
   name_val Databases "${num_dbs}"
   name_val Datadir "$(get_var datadir "$dir/mysql-variables")"

   local fuzz_procs=$(fuzz $(get_var Threads_connected "$dir/mysql-status"))
   local fuzz_procr=$(fuzz $(get_var Threads_running "$dir/mysql-status"))
   name_val Processes "${fuzz_procs} connected, ${fuzz_procr} running"

   local slave=""
   if [ -s "$dir/mysql-slave" ]; then slave=""; else slave="not "; fi
   local slavecount=$(grep -c 'Binlog Dump' "$dir/mysql-processlist")
   name_val Replication "Is ${slave}a slave, has ${slavecount} slaves connected"


   local pid_file="$(get_var "pid_file" "$dir/mysql-variables")"
   local PID_EXISTS=""
   if [ "$( get_var "pt-summary-internal-pid_file_exists" "$dir/mysql-variables" )" ]; then
      PID_EXISTS="(exists)"
   else
      PID_EXISTS="(does not exist)"
   fi
   name_val Pidfile "${pid_file} ${PID_EXISTS}"

   section "Processlist"
   summarize_processlist "$dir/mysql-processlist"

   section "Status Counters (Wait ${OPT_SLEEP} Seconds)"
   wait
   local noncounters_pattern="$(noncounters_pattern)"
   format_status_variables "$dir/mysql-status-defer" | grep -v "${noncounters_pattern}"

   section "Table cache"
   local open_tables=$(get_var "Open_tables" "$dir/mysql-status")
   local table_cache=$(get_table_cache "$dir/mysql-variables")
   name_val Size  $table_cache
   name_val Usage "$(fuzzy_pct ${open_tables} ${table_cache})"

   section "Key Percona Server features"
   section_percona_server_features "$dir/mysql-variables"

   section "Percona XtraDB Cluster"
   local has_wsrep=$($CMD_MYSQL $EXT_ARGV -ss -e 'show session variables like "%wsrep_on%";' | cut -f2 | grep -i "on")
   if [ -n "${has_wsrep:-""}" ]; then
      if [ "${has_wsrep:-""}" = "ON" ]; then
         section_percona_xtradb_cluster "$dir/mysql-variables" "$dir/mysql-status"
      else
         name_val "wsrep_on" "OFF"
      fi
   fi

   section "Plugins"
   name_val "InnoDB compression" "$(get_plugin_status "$dir/mysql-plugins" "INNODB_CMP")"

   local has_query_cache=$(get_var have_query_cache "$dir/mysql-variables")
   if [ "$has_query_cache" = 'YES' ]; then
      section "Query cache"
      local query_cache_size=$(get_var query_cache_size "$dir/mysql-variables")
      local used=$(( ${query_cache_size} - $(get_var Qcache_free_memory "$dir/mysql-status") ))
      local hrat=$(fuzzy_pct $(get_var Qcache_hits "$dir/mysql-status") $(get_var Qcache_inserts "$dir/mysql-status"))
      name_val query_cache_type $(get_var query_cache_type "$dir/mysql-variables")
      name_val Size "$(shorten ${query_cache_size} 1)"
      name_val Usage "$(fuzzy_pct ${used} ${query_cache_size})"
      name_val HitToInsertRatio "${hrat}"
   fi

   local semisync_enabled_master="$(get_var "rpl_semi_sync_master_enabled" "$dir/mysql-variables")"
   if [ -n "${semisync_enabled_master}" ]; then
      section "Semisynchronous Replication"
      if [ "$semisync_enabled_master" = "OFF" -o "$semisync_enabled_master" = "0" -o -z "$semisync_enabled_master" ]; then
         name_val "Master" "Disabled"
      else
         _semi_sync_stats_for "master" "$dir/mysql-variables"
      fi
      local semisync_enabled_slave="$(get_var rpl_semi_sync_slave_enabled "$dir/mysql-variables")"
      if    [ "$semisync_enabled_slave" = "OFF" -o "$semisync_enabled_slave" = "0" -o -z "$semisync_enabled_slave" ]; then
         name_val "Slave" "Disabled"
      else
         _semi_sync_stats_for "slave" "$dir/mysql-variables"
      fi
   fi

   section "Schema"
   if [ -s "$dir/mysqldump" ] \
      && grep 'CREATE TABLE' "$dir/mysqldump" >/dev/null 2>&1; then
         format_overall_db_stats "$dir/mysqldump"
   elif [ ! -e "$dir/mysqldump" -a "$OPT_READ_SAMPLES" ]; then
      echo "Skipping schema analysis because --read-samples $dir/mysqldump " \
         "does not exist"
   elif [ -z "$OPT_DATABASES" -a -z "$OPT_ALL_DATABASES" ]; then
      echo "Specify --databases or --all-databases to dump and summarize schemas"
   else
      echo "Skipping schema analysis due to apparent error in dump file"
   fi

   section "Noteworthy Technologies"
   if [ -s "$dir/mysqldump" ]; then
      if grep FULLTEXT "$dir/mysqldump" > /dev/null; then
         name_val "Full Text Indexing" "Yes"
      else
         name_val "Full Text Indexing" "No"
      fi
      if grep 'GEOMETRY\|POINT\|LINESTRING\|POLYGON' "$dir/mysqldump" > /dev/null; then
         name_val "Geospatial Types" "Yes"
      else
         name_val "Geospatial Types" "No"
      fi
      if grep 'FOREIGN KEY' "$dir/mysqldump" > /dev/null; then
         name_val "Foreign Keys" "Yes"
      else
         name_val "Foreign Keys" "No"
      fi
      if grep 'PARTITION BY' "$dir/mysqldump" > /dev/null; then
         name_val "Partitioning" "Yes"
      else
         name_val "Partitioning" "No"
      fi
      if grep -e 'ENGINE=InnoDB.*ROW_FORMAT' \
         -e 'ENGINE=InnoDB.*KEY_BLOCK_SIZE' "$dir/mysqldump" > /dev/null; then
         name_val "InnoDB Compression" "Yes"
      else
         name_val "InnoDB Compression" "No"
      fi
   fi
   local ssl="$(get_var Ssl_accepts "$dir/mysql-status")"
   if [ -n "$ssl" -a "${ssl:-0}" -gt 0 ]; then
      name_val "SSL" "Yes"
   else
      name_val "SSL" "No"
   fi
   local lock_tables="$(get_var Com_lock_tables "$dir/mysql-status")"
   if [ -n "$lock_tables" -a "${lock_tables:-0}" -gt 0 ]; then
      name_val "Explicit LOCK TABLES" "Yes"
   else
      name_val "Explicit LOCK TABLES" "No"
   fi
   local delayed_insert="$(get_var Delayed_writes "$dir/mysql-status")"
   if [ -n "$delayed_insert" -a "${delayed_insert:-0}" -gt 0 ]; then
      name_val "Delayed Insert" "Yes"
   else
      name_val "Delayed Insert" "No"
   fi
   local xat="$(get_var Com_xa_start "$dir/mysql-status")"
   if [ -n "$xat" -a "${xat:-0}" -gt 0 ]; then
      name_val "XA Transactions" "Yes"
   else
      name_val "XA Transactions" "No"
   fi
   local ndb_cluster="$(get_var "Ndb_cluster_node_id" "$dir/mysql-status")"
   if [ -n "$ndb_cluster" -a "${ndb_cluster:-0}" -gt 0 ]; then
      name_val "NDB Cluster" "Yes"
   else
      name_val "NDB Cluster" "No"
   fi
   local prep=$(( $(get_var "Com_stmt_prepare" "$dir/mysql-status") + $(get_var "Com_prepare_sql" "$dir/mysql-status") ))
   if [ "${prep}" -gt 0 ]; then
      name_val "Prepared Statements" "Yes"
   else
      name_val "Prepared Statements" "No"
   fi
   local prep_count="$(get_var Prepared_stmt_count "$dir/mysql-status")"
   if [ "${prep_count}" ]; then
      name_val "Prepared statement count" "${prep_count}"
   fi

   section "InnoDB"
   local have_innodb="$(get_var "have_innodb" "$dir/mysql-variables")"
   local innodb_version="$(get_var "innodb_version" "$dir/mysql-variables")"
   if [ "${have_innodb}" = "YES" ] || [ -n "${innodb_version}" ]; then
      section_innodb "$dir/mysql-variables" "$dir/mysql-status"

      if [ -s "$dir/innodb-status" ]; then
         format_innodb_status "$dir/innodb-status"
      fi
   fi

   local has_rocksdb=$($CMD_MYSQL $EXT_ARGV -ss -e 'SHOW ENGINES' 2>/dev/null | grep -i 'rocksdb')
   if [ ! -z "$has_rocksdb" ]; then
       section "RocksDB"
       section_rocksdb "$dir/mysql-variables" "$dir/mysql-status"
   fi

   if [ -s "$dir/ndb-status" ]; then
       section "NDB"
       format_ndb_status "$dir/ndb-status"
   fi

   section "MyISAM"
   section_myisam "$dir/mysql-variables" "$dir/mysql-status"

   section "Security"
   local users="$( format_users "$dir/mysql-users" )"
   name_val "Users" "${users}"
   name_val "Old Passwords" "$(get_var old_passwords "$dir/mysql-variables")"

   if [ -s "$dir/mysql-roles" ]; then
       section "Roles"
       format_mysql_roles "$dir/mysql-roles"
   fi

   section "Encryption"
   local keyring_plugins="$(collect_keyring_plugins)"
   local encrypted_tables=""
   local encrypted_tablespaces=""
   if [ "${OPT_LIST_ENCRYPTED_TABLES}" = 'yes' ]; then 
       encrypted_tables="$(collect_encrypted_tables)"
       encrypted_tablespaces="$(collect_encrypted_tablespaces)"
   fi

   format_keyring_plugins "$keyring_plugins" "$encrypted_tables"
   format_encrypted_tables "$encrypted_tables"
   format_encrypted_tablespaces "$encrypted_tablespaces"

   section "Binary Logging"

   if    [ -s "$dir/mysql-master-logs" ] \
      || [ -s "$dir/mysql-master-status" ]; then
      summarize_binlogs "$dir/mysql-master-logs"
      local format="$(get_var binlog_format "$dir/mysql-variables")"
      name_val binlog_format "${format:-STATEMENT}"
      name_val expire_logs_days "$(get_var expire_logs_days "$dir/mysql-variables")"
      name_val sync_binlog "$(get_var sync_binlog "$dir/mysql-variables")"
      name_val server_id "$(get_var server_id "$dir/mysql-variables")"
      format_binlog_filters "$dir/mysql-master-status"
   fi


   section "Noteworthy Variables"
   section_noteworthy_variables "$dir/mysql-variables"

   section "Configuration File"
   local cnf_file="$(get_var "pt-summary-internal-Config_File_path" "$dir/mysql-variables")"

   if [ -n "${cnf_file}" ]; then
      name_val "Config File" "${cnf_file}"
      pretty_print_cnf_file "$dir/mysql-config-file"
   else
      name_val "Config File" "Cannot autodetect or find, giving up"
   fi

   section "Memory management library"
   report_jemalloc_enabled

   section "The End"
}

# ###########################################################################
# End report_mysql_info package
# ###########################################################################

# ########################################################################
# Some global setup is necessary for cross-platform compatibility, even
# when sourcing this script for testing purposes.
# ########################################################################

TOOL="pt-mysql-summary"

# These vars are declared earlier in the collect_mysql_info package,
# but if they're still undefined here, try to find them in PATH.
[ "$CMD_MYSQL" ]     || CMD_MYSQL="$(_which mysql)"
[ "$CMD_MYSQLDUMP" ] || CMD_MYSQLDUMP="$( _which mysqldump )"

check_mysql () {
   # Check that mysql and mysqldump are in PATH.  If not, we're
   # already dead in the water, so don't bother with cmd line opts,
   # just error and exit.
   [ -n "$(${CMD_MYSQL} --help 2>/dev/null)" ] \
      || die "Cannot execute mysql.  Check that it is in PATH."
   [ -n "$(${CMD_MYSQLDUMP} --help 2>/dev/null)" ] \
      || die "Cannot execute mysqldump.  Check that it is in PATH."

   # Now that we have the cmd line opts, check that we can actually
   # connect to MySQL.
   [ -n "$(${CMD_MYSQL} ${EXT_ARGV} -e 'SHOW STATUS')" ] \
      || die "Cannot connect to MySQL.  Check that MySQL is running and that the options after -- are correct."

}

sigtrap() {
   warn "Caught signal, forcing exit"
   rm_tmpdir
   exit $EXIT_STATUS
}

# ##############################################################################
# The main() function is called at the end of the script.  This makes it
# testable.  Major bits of parsing are separated into functions for testability.
# ##############################################################################
main() {
   # Prepending SIG to these doesn't work with NetBSD's sh
   trap sigtrap HUP INT TERM

   local MYSQL_ARGS="$(mysql_options)"
   EXT_ARGV="$(arrange_mysql_options "$EXT_ARGV $MYSQL_ARGS")"

   # Check if mysql and mysqldump are there, otherwise bail out early.
   # But don't if they passed in --read-samples, since we don't need
   # a connection then.
   [ "$OPT_READ_SAMPLES" ] || check_mysql

   local RAN_WITH="--sleep=$OPT_SLEEP --databases=$OPT_DATABASES --save-samples=$OPT_SAVE_SAMPLES"

   _d "Starting $0 $RAN_WITH"

   # Begin by setting the $PATH to include some common locations that are not
   # always in the $PATH, including the "sbin" locations.  On SunOS systems,
   # prefix the path with the location of more sophisticated utilities.
   export PATH="${PATH}:/usr/local/bin:/usr/bin:/bin:/usr/libexec"
   export PATH="${PATH}:/usr/mysql/bin/:/usr/local/sbin:/usr/sbin:/sbin"
   export PATH="/usr/gnu/bin/:/usr/xpg4/bin/:${PATH}"

   _d "Going to use: mysql=${CMD_MYSQL} mysqldump=${CMD_MYSQLDUMP}"

   # Create the tmpdir for everything to run in
   mk_tmpdir

   # Set DATA_DIR where we'll save collected data files.
   local data_dir="$(setup_data_dir "${OPT_SAVE_SAMPLES:-""}")"
   if [ -z "$data_dir" ]; then
      exit $?
   fi

   if [ -n "$OPT_READ_SAMPLES" -a -d "$OPT_READ_SAMPLES" ]; then
      # --read-samples was set and is a directory, so the samples
      # will already be there.
      data_dir="$OPT_READ_SAMPLES"
   else
      # #####################################################################
      # Fetch most info, leave a child in the background gathering the rest
      # #####################################################################
      collect_mysql_info "${data_dir}" 2>"${data_dir}/collect.err"
   fi

   # ########################################################################
   # Format and pretty-print the data
   # ########################################################################
   report_mysql_summary "${data_dir}"

   rm_tmpdir

}

# Execute the program if it was not included from another file.
# This makes it possible to include without executing, and thus test.
if    [ "${0##*/}" = "$TOOL" ] \
   || [ "${0##*/}" = "bash" -a "${_:-""}" = "$0" ]; then

   # Set up temporary dir.
   mk_tmpdir
   # Parse command line options.
   parse_options "$0" "${@:-""}"

   # Verify that --sleep, if present, is positive
   if [ -n "$OPT_SLEEP" ] && [ "$OPT_SLEEP" -lt 0 ]; then
      option_error "Invalid --sleep value: $sleep"
   fi

   usage_or_errors "$0"
   po_status=$?
   rm_tmpdir

   if [ $po_status -ne 0 ]; then
      [ $OPT_ERRS -gt 0 ] && exit 1
      exit 0
   fi

   main "${@:-""}"
fi

# ############################################################################
# Documentation
# ############################################################################
:<<'DOCUMENTATION'
=pod

=head1 NAME

pt-mysql-summary - Summarize MySQL information nicely.

=head1 SYNOPSIS

Usage: pt-mysql-summary [OPTIONS]

pt-mysql-summary conveniently summarizes the status and configuration of a
MySQL database server so that you can learn about it at a glance.  It is not
a tuning tool or diagnosis tool.  It produces a report that is easy to diff
and can be pasted into emails without losing the formatting.  It should work
well on any modern UNIX systems.

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

pt-mysql-summary works by connecting to a MySQL database server and querying
it for status and configuration information.  It saves these bits of data
into files in a temporary directory, and then formats them neatly with awk
and other scripting languages.

To use, simply execute it.  Optionally add a double dash and then the same
command-line options you would use to connect to MySQL, such as the following:

  pt-mysql-summary --user=root

The tool interacts minimally with the server upon which it runs.  It assumes
that you'll run it on the same server you're inspecting, and therefore it
assumes that it will be able to find the my.cnf configuration file, for example.
However, it should degrade gracefully if this is not the case.  Note, however,
that its output does not indicate which information comes from the MySQL
database and which comes from the host operating system, so it is possible for
confusing output to be generated if you run the tool on one server and connect
to a MySQL database server running on another server.

=head1 OUTPUT

Many of the outputs from this tool are deliberately rounded to show their
magnitude but not the exact detail.  This is called fuzzy-rounding. The idea
is that it does not matter whether a server is running 918 queries per second
or 921 queries per second; such a small variation is insignificant, and only
makes the output hard to compare to other servers.  Fuzzy-rounding rounds in
larger increments as the input grows.  It begins by rounding to the nearest 5,
then the nearest 10, nearest 25, and then repeats by a factor of 10 larger
(50, 100, 250), and so on, as the input grows.

The following is a sample of the report that the tool produces:

  # Percona Toolkit MySQL Summary Report #######################
                System time | 2012-03-30 18:46:05 UTC
                              (local TZ: EDT -0400)
  # Instances ##################################################
    Port  Data Directory             Nice OOM Socket
    ===== ========================== ==== === ======
    12345 /tmp/12345/data            0    0   /tmp/12345.sock
    12346 /tmp/12346/data            0    0   /tmp/12346.sock
    12347 /tmp/12347/data            0    0   /tmp/12347.sock

The first two sections show which server the report was generated on and which
MySQL instances are running on the server. This is detected from the output of
C<ps> and does not always detect all instances and parameters, but often works
well.  From this point forward, the report will be focused on a single MySQL
instance, although several instances may appear in the above paragraph.

  # Report On Port 12345 #######################################
                       User | msandbox@%
                       Time | 2012-03-30 14:46:05 (EDT)
                   Hostname | localhost.localdomain
                    Version | 5.5.20-log MySQL Community Server (GPL)
                   Built On | linux2.6 i686
                    Started | 2012-03-28 23:33 (up 1+15:12:09)
                  Databases | 4
                    Datadir | /tmp/12345/data/
                  Processes | 2 connected, 2 running
                Replication | Is not a slave, has 1 slaves connected
                    Pidfile | /tmp/12345/data/12345.pid (exists)

This section is a quick summary of the MySQL instance: version, uptime, and
other very basic parameters. The Time output is generated from the MySQL server,
unlike the system date and time printed earlier, so you can see whether the
database and operating system times match.

  # Processlist ################################################

    Command                        COUNT(*) Working SUM(Time) MAX(Time)
    ------------------------------ -------- ------- --------- ---------
    Binlog Dump                           1       1    150000    150000
    Query                                 1       1         0         0

    User                           COUNT(*) Working SUM(Time) MAX(Time)
    ------------------------------ -------- ------- --------- ---------
    msandbox                              2       2    150000    150000

    Host                           COUNT(*) Working SUM(Time) MAX(Time)
    ------------------------------ -------- ------- --------- ---------
    localhost                             2       2    150000    150000

    db                             COUNT(*) Working SUM(Time) MAX(Time)
    ------------------------------ -------- ------- --------- ---------
    NULL                                  2       2    150000    150000

    State                          COUNT(*) Working SUM(Time) MAX(Time)
    ------------------------------ -------- ------- --------- ---------
    Master has sent all binlog to         1       1    150000    150000
    NULL                                  1       1         0         0

This section is a summary of the output from SHOW PROCESSLIST. Each sub-section
is aggregated by a different item, which is shown as the first column heading.
When summarized by Command, every row in SHOW PROCESSLIST is included, but
otherwise, rows whose Command is Sleep are excluded from the SUM and MAX
columns, so they do not skew the numbers too much. In the example shown, the
server is idle except for this tool itself, and one connected replica, which
is executing Binlog Dump.

The columns are the number of rows included, the number that are not in Sleep
status, the sum of the Time column, and the maximum Time column. The numbers are
fuzzy-rounded.

  # Status Counters (Wait 10 Seconds) ##########################
  Variable                            Per day  Per second     10 secs
  Binlog_cache_disk_use                     4                        
  Binlog_cache_use                         80                        
  Bytes_received                     15000000         175         200
  Bytes_sent                         15000000         175        2000
  Com_admin_commands                        1                        
  ...................(many lines omitted)............................
  Threads_created                          40                       1
  Uptime                                90000           1           1

This section shows selected counters from two snapshots of SHOW GLOBAL STATUS,
gathered approximately 10 seconds apart and fuzzy-rounded. It includes only
items that are incrementing counters; it does not include absolute numbers such
as the Threads_running status variable, which represents a current value, rather
than an accumulated number over time.

The first column is the variable name, and the second column is the counter from
the first snapshot divided by 86400 (the number of seconds in a day), so you can
see the magnitude of the counter's change per day. 86400 fuzzy-rounds to 90000,
so the Uptime counter should always be about 90000.

The third column is the value from the first snapshot, divided by Uptime and
then fuzzy-rounded, so it represents approximately how quickly the counter is
growing per-second over the uptime of the server.

The third column is the incremental difference from the first and second
snapshot, divided by the difference in uptime and then fuzzy-rounded. Therefore,
it shows how quickly the counter is growing per second at the time the report
was generated.

  # Table cache ################################################
                       Size | 400
                      Usage | 15%

This section shows the size of the table cache, followed by the percentage of
the table cache in use. The usage is fuzzy-rounded.

  # Key Percona Server features ################################
        Table & Index Stats | Not Supported
       Multiple I/O Threads | Enabled
       Corruption Resilient | Not Supported
        Durable Replication | Not Supported
       Import InnoDB Tables | Not Supported
       Fast Server Restarts | Not Supported
           Enhanced Logging | Not Supported
       Replica Perf Logging | Not Supported
        Response Time Hist. | Not Supported
            Smooth Flushing | Not Supported
        HandlerSocket NoSQL | Not Supported
             Fast Hash UDFs | Unknown

This section shows features that are available in Percona Server and whether
they are enabled or not. In the example shown, the server is standard MySQL, not
Percona Server, so the features are generally not supported.

  # Plugins ####################################################
         InnoDB compression | ACTIVE

This feature shows specific plugins and whether they are enabled.

  # Query cache ################################################
           query_cache_type | ON
                       Size | 0.0
                      Usage | 0%
           HitToInsertRatio | 0%

This section shows whether the query cache is enabled and its size, followed by
the percentage of the cache in use and the hit-to-insert ratio. The latter two
are fuzzy-rounded.

  # Schema #####################################################

    Database           Tables Views SPs Trigs Funcs   FKs Partn
    mysql                  24                                  
    performance_schema     17                                  
    sakila                 16     7   3     6     3    22      

    Database           MyISAM CSV PERFORMANCE_SCHEMA InnoDB
    mysql                  22   2                          
    performance_schema                            17       
    sakila                  8                            15

    Database           BTREE FULLTEXT
    mysql                 31         
    performance_schema               
    sakila                63        1

                         c   t   s   e   l   d   i   t   m   v   s
                         h   i   e   n   o   a   n   i   e   a   m
                         a   m   t   u   n   t   t   n   d   r   a
                         r   e       m   g   e       y   i   c   l
                             s           b   t       i   u   h   l
                             t           l   i       n   m   a   i
                             a           o   m       t   t   r   n
                             m           b   e           e       t
                             p                           x        
                                                         t        
    Database           === === === === === === === === === === ===
    mysql               61  10   6  78   5   4  26   3   4   5   3
    performance_schema               5          16          33    
    sakila               1  15   1   3       4   3  19      42  26

If you specify L<"--databases"> or L<"--all-databases">, the tool will print
the above section. This summarizes the number and type of objects in the
databases. It is generated by running C<mysqldump --no-data>, not by querying
the INFORMATION_SCHEMA, which can freeze a busy server.

The first sub-report in the section is the count of objects by type in each
database: tables, views, and so on. The second one shows how many tables use
various storage engines in each database. The third sub-report shows the number
of each type of indexes in each database.

The last section shows the number of columns of various data types in each
database. For compact display, the column headers are formatted vertically, so
you need to read downwards from the top. In this example, the first column is
C<char> and the second column is C<timestamp>. This example is truncated so it
does not wrap on a terminal.

All of the numbers in this portion of the output are exact, not fuzzy-rounded.

  # Noteworthy Technologies ####################################
         Full Text Indexing | Yes
           Geospatial Types | No
               Foreign Keys | Yes
               Partitioning | No
         InnoDB Compression | Yes
                        SSL | No
       Explicit LOCK TABLES | No
             Delayed Insert | No
            XA Transactions | No
                NDB Cluster | No
        Prepared Statements | No
   Prepared statement count | 0

This section shows some specific technologies used on this server. Some of them
are detected from the schema dump performed for the previous sections; others
can be detected by looking at SHOW GLOBAL STATUS.

  # InnoDB #####################################################
                    Version | 1.1.8
           Buffer Pool Size | 16.0M
           Buffer Pool Fill | 100%
          Buffer Pool Dirty | 0%
             File Per Table | OFF
                  Page Size | 16k
              Log File Size | 2 * 5.0M = 10.0M
            Log Buffer Size | 8M
               Flush Method | 
        Flush Log At Commit | 1
                 XA Support | ON
                  Checksums | ON
                Doublewrite | ON
            R/W I/O Threads | 4 4
               I/O Capacity | 200
         Thread Concurrency | 0
        Concurrency Tickets | 500
         Commit Concurrency | 0
        Txn Isolation Level | REPEATABLE-READ
          Adaptive Flushing | ON
        Adaptive Checkpoint | 
             Checkpoint Age | 0
               InnoDB Queue | 0 queries inside InnoDB, 0 queries in queue
         Oldest Transaction | 0 Seconds
           History List Len | 209
                 Read Views | 1
           Undo Log Entries | 1 transactions, 1 total undo, 1 max undo
          Pending I/O Reads | 0 buf pool reads, 0 normal AIO,
                              0 ibuf AIO, 0 preads
         Pending I/O Writes | 0 buf pool (0 LRU, 0 flush list, 0 page);
                              0 AIO, 0 sync, 0 log IO (0 log, 0 chkp);
                              0 pwrites
        Pending I/O Flushes | 0 buf pool, 0 log
         Transaction States | 1xnot started

This section shows important configuration variables for the InnoDB storage
engine. The buffer pool fill percent and dirty percent are fuzzy-rounded. The
last few lines are derived from the output of SHOW INNODB STATUS. It is likely
that this output will change in the future to become more useful.

  # MyISAM #####################################################
                  Key Cache | 16.0M
                   Pct Used | 10%
                  Unflushed | 0%

This section shows the size of the MyISAM key cache, followed by the percentage
of the cache in use and percentage unflushed (fuzzy-rounded).

  # Security ###################################################
                      Users | 2 users, 0 anon, 0 w/o pw, 0 old pw
              Old Passwords | OFF

This section is generated from queries to tables in the mysql system database.
It shows how many users exist, and various potential security risks such as
old-style passwords and users without passwords.

  # Binary Logging #############################################
                    Binlogs | 1
                 Zero-Sized | 0
                 Total Size | 21.8M
              binlog_format | STATEMENT
           expire_logs_days | 0
                sync_binlog | 0
                  server_id | 12345
               binlog_do_db | 
           binlog_ignore_db | 

This section shows configuration and status of the binary logs. If there are
zero-sized binary logs, then it is possible that the binlog index is out of sync
with the binary logs that actually exist on disk.

  # Noteworthy Variables #######################################
       Auto-Inc Incr/Offset | 1/1
     default_storage_engine | InnoDB
                 flush_time | 0
               init_connect | 
                  init_file | 
                   sql_mode | 
           join_buffer_size | 128k
           sort_buffer_size | 2M
           read_buffer_size | 128k
       read_rnd_buffer_size | 256k
         bulk_insert_buffer | 0.00
        max_heap_table_size | 16M
             tmp_table_size | 16M
         max_allowed_packet | 1M
               thread_stack | 192k
                        log | OFF
                  log_error | /tmp/12345/data/mysqld.log
               log_warnings | 1
           log_slow_queries | ON
  log_queries_not_using_indexes | OFF
          log_slave_updates | ON

This section shows several noteworthy server configuration variables that might
be important to know about when working with this server.

  # Configuration File #########################################
                Config File | /tmp/12345/my.sandbox.cnf
  [client]
  user                                = msandbox
  password                            = msandbox
  port                                = 12345
  socket                              = /tmp/12345/mysql_sandbox12345.sock
  [mysqld]
  port                                = 12345
  socket                              = /tmp/12345/mysql_sandbox12345.sock
  pid-file                            = /tmp/12345/data/mysql_sandbox12345.pid
  basedir                             = /home/baron/5.5.20
  datadir                             = /tmp/12345/data
  key_buffer_size                     = 16M
  innodb_buffer_pool_size             = 16M
  innodb_data_home_dir                = /tmp/12345/data
  innodb_log_group_home_dir           = /tmp/12345/data
  innodb_data_file_path               = ibdata1:10M:autoextend
  innodb_log_file_size                = 5M
  log-bin                             = mysql-bin
  relay_log                           = mysql-relay-bin
  log_slave_updates
  server-id                           = 12345
  report-host                         = 127.0.0.1
  report-port                         = 12345
  log-error                           = mysqld.log
  innodb_lock_wait_timeout            = 3
  # The End ####################################################

This section shows a pretty-printed version of the my.cnf file, with comments
removed and with whitespace added to align things for easy reading. The tool
tries to detect the my.cnf file by looking at the output of ps, and if it does
not find the location of the file there, it tries common locations until it
finds a file. Note that this file might not actually correspond with the server
from which the report was generated. This can happen when the tool isn't run on
the same server it's reporting on, or when detecting the location of the
configuration file fails.

=head1 OPTIONS

All options after -- are passed to C<mysql>.

=over

=item --all-databases

mysqldump and summarize all databases.  See L<"--databases">.

=item --ask-pass

Prompt for a password when connecting to MySQL.

=item --config

type: string

Read this comma-separated list of config files.  If specified, this must be the
first option on the command line.

=item --databases

type: string

mysqldump and summarize this comma-separated list of databases.  Specify
L<"--all-databases"> instead if you want to dump and summary all databases.

=item --defaults-file

short form: -F; type: string

Only read mysql options from the given file.  You must give an absolute
pathname.

=item --help

Print help and exit.

=item --host

short form: -h; type: string

Host to connect to.

=item --list-encrypted-tables

default: false

Include a list of the encrypted tables in all databases. This can cause slowdowns since
querying Information Schema tables can be slow.

=item --password

short form: -p; type: string

Password to use when connecting.
If password contains commas they must be escaped with a backslash: "exam\,ple"

=item --port

short form: -P; type: int

Port number to use for connection.

=item --read-samples

type: string

Create a report from the files found in this directory.

=item --save-samples

type: string

Save the data files used to generate the summary in this directory.

=item --sleep

type: int; default: 10

Seconds to sleep when gathering status counters.

=item --socket

short form: -S; type: string

Socket file to use for connection.

=item --user

short form: -u; type: string

User for login if not current user.

=item --version

Print tool's version and exit.

=back

=head1 ENVIRONMENT

This tool does not use any environment variables.

=head1 SYSTEM REQUIREMENTS

This tool requires Bash v3 or newer, Perl 5.8 or newer, and binutils.
These are generally already provided by most distributions.
On BSD systems, it may require a mounted procfs.

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-mysql-summary>.

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

pt-mysql-summary 3.3.0

=cut

DOCUMENTATION