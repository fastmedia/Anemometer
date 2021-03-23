#!/usr/bin/env bash

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
# subshell package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/subshell.sh
#   t/lib/bash/subshell.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u

wait_for_subshells() {
   local max_wait=$1
   if [ "$(jobs)" ]; then
      log "Waiting up to $max_wait seconds for subprocesses to finish..."
      local slept=0
      while [ -n "$(jobs)" ]; do
         local subprocess_still_running=""
         for pid in $(jobs -p); do
            if kill -0 $pid >/dev/null 2>&1; then
               subprocess_still_running=1
            fi
         done
         if [ "$subprocess_still_running" ]; then
            sleep 1
            slept=$((slept + 1))
            [ $slept -ge $max_wait ] && break
         else
            break
         fi
      done
   fi
}

kill_all_subshells() {
   if [ "$(jobs)" ]; then
      for pid in $(jobs -p); do
         if kill -0 $pid >/dev/null 2>&1; then
            log "Killing subprocess $pid"
            kill $pid >/dev/null 2>&1
         fi
      done
   else
      log "All subprocesses have finished"
   fi
}

# ###########################################################################
# End subshell package
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
OPT_MYSQL_ONLY="" # If --mysql-only was specified
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
   if [ -n "$OPT_PASSWORD" ]; then
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
# safeguards package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/safeguards.sh
#   t/lib/bash/safeguards.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u

disk_space() {
   local filesystem="${1:-$PWD}"
   df -P -k "$filesystem"
}

check_disk_space() {
   local file="$1"
   local min_free_bytes="${2:-0}"
   local min_free_pct="${3:-0}"
   local bytes_margin="${4:-0}"

   local used_bytes=$(tail -n 1 "$file" | perl -ane 'print $F[2] * 1024')
   local free_bytes=$(tail -n 1 "$file" | perl -ane 'print $F[3] * 1024')
   local pct_used=$(tail -n 1 "$file" | perl -ane 'print ($F[4] =~ m/(\d+)/)')
   local pct_free=$((100 - $pct_used))

   local real_free_bytes=$free_bytes
   local real_pct_free=$pct_free

   if [ $bytes_margin -gt 0 ]; then
      used_bytes=$(($used_bytes + $bytes_margin))
      free_bytes=$(($free_bytes - $bytes_margin))
      pct_used=$(perl -e "print int(($used_bytes/($used_bytes + $free_bytes)) * 100)")

      pct_free=$((100 - $pct_used))
   fi

   if [ $free_bytes -lt $min_free_bytes -o $pct_free -lt $min_free_pct ]; then
      warn "Not enough free disk space:
    Limit: ${min_free_pct}% free, ${min_free_bytes} bytes free
   Actual: ${real_pct_free}% free, ${real_free_bytes} bytes free (- $bytes_margin bytes margin)
"
      cat "$file" >&2

      return 1  # not enough disk space
   fi

   return 0  # disk space is OK
}

# ###########################################################################
# End safeguards package
# ###########################################################################

# ###########################################################################
# daemon package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/daemon.sh
#   t/lib/bash/daemon.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################


set -u

make_pid_file() {
   local file="$1"
   local pid="$2"


   if [ -f "$file" ]; then
      local old_pid=$(cat "$file")
      if [ -z "$old_pid" ]; then
         die "PID file $file already exists but it is empty"
      else
         kill -0 $old_pid 2>/dev/null
         if [ $? -eq 0 ]; then
            die "PID file $file already exists and its PID ($old_pid) is running"
         else
            echo "Overwriting PID file $file because its PID ($old_pid)" \
                 "is not running"
         fi
      fi
   fi

   echo "$pid" > "$file"
   if [ $? -ne 0 ]; then
      die "Cannot create or write PID file $file"
   fi
}

remove_pid_file() {
   local file="$1"
   if [ -f "$file" ]; then
      rm "$file"
   fi
}

# ###########################################################################
# End daemon package
# ###########################################################################

# ###########################################################################
# collect package
# This package is a copy without comments from the original.  The original
# with comments and its test file can be found in the Bazaar repository at,
#   lib/bash/collect.sh
#   t/lib/bash/collect.sh
# See https://launchpad.net/percona-toolkit for more information.
# ###########################################################################



set -u

CMD_GDB="${CMD_GDB:-"$(_which gdb)"}"
CMD_IOSTAT="${CMD_IOSTAT:-"$(_which iostat)"}"
CMD_MPSTAT="${CMD_MPSTAT:-"$(_which mpstat)"}"
CMD_MYSQL="${CMD_MYSQL:-"$(_which mysql)"}"
CMD_MYSQLADMIN="${CMD_MYSQLADMIN:-"$(_which mysqladmin)"}"
CMD_OPCONTROL="${CMD_OPCONTROL:-"$(_which opcontrol)"}"
CMD_OPREPORT="${CMD_OPREPORT:-"$(_which opreport)"}"
CMD_PMAP="${CMD_PMAP:-"$(_which pmap)"}"
CMD_STRACE="${CMD_STRACE:-"$(_which strace)"}"
CMD_SYSCTL="${CMD_SYSCTL:-"$(_which sysctl)"}"
CMD_TCPDUMP="${CMD_TCPDUMP:-"$(_which tcpdump)"}"
CMD_VMSTAT="${CMD_VMSTAT:-"$(_which vmstat)"}"
CMD_DMESG="${CMD_DMESG:-"$(_which dmesg)"}"

[ -z "$CMD_SYSCTL" -a -x "/sbin/sysctl" ] && CMD_SYSCTL="/sbin/sysctl"

collect() {
   local d="$1"  # directory to save results in
   local p="$2"  # prefix for each result file

   local mysqld_pid=""
   if [ ! "$OPT_MYSQL_ONLY" ]; then
      mysqld_pid=$(_pidof mysqld | awk '{print $1; exit;}')
   fi

   if [ "$CMD_PMAP" -a "$mysqld_pid" ]; then
      if $CMD_PMAP --help 2>&1 | grep -- -x >/dev/null 2>&1 ; then
         $CMD_PMAP -x $mysqld_pid > "$d/$p-pmap"
      else
         $CMD_PMAP $mysqld_pid > "$d/$p-pmap"
      fi
   fi

   if [ "$CMD_GDB" -a "$OPT_COLLECT_GDB" -a "$mysqld_pid" ]; then
      $CMD_GDB                     \
         -ex "set pagination 0"    \
         -ex "thread apply all bt" \
         --batch -p $mysqld_pid    \
         >> "$d/$p-stacktrace"
   fi

   collect_mysql_variables "$d/$p-variables" &
   sleep .5

   local mysql_version="$(awk '/^version[^_]/{print substr($2,1,3)}' "$d/$p-variables")"

   local mysql_error_log="$(awk '/^log_error /{print $2}' "$d/$p-variables")"
   if [ -z "$mysql_error_log" -a "$mysqld_pid" ]; then
      mysql_error_log="$(ls -l /proc/$mysqld_pid/fd | awk '/ 2 ->/{print $NF}')"
   fi

   local tail_error_log_pid=""
   if [ "$mysql_error_log" -a ! "$OPT_MYSQL_ONLY" ]; then
      log "The MySQL error log seems to be $mysql_error_log"
      tail -f "$mysql_error_log" >"$d/$p-log_error" &
      tail_error_log_pid=$!

      $CMD_MYSQLADMIN $EXT_ARGV
   else
      log "Could not find the MySQL error log"
   fi 
   if [ "${mysql_version}" '>' "5.1" ]; then
      local mutex="SHOW ENGINE INNODB MUTEX"
   else
      local mutex="SHOW MUTEX STATUS"
   fi
   innodb_status 1
   tokudb_status 1
   rocksdb_status 1

   $CMD_MYSQL $EXT_ARGV -e "$mutex" >> "$d/$p-mutex-status1" &
   open_tables                      >> "$d/$p-opentables1"   &

   local tcpdump_pid=""
   if [ "$CMD_TCPDUMP" -a  "$OPT_COLLECT_TCPDUMP" ]; then
      local port=$(awk '/^port/{print $2}' "$d/$p-variables")
      if [ "$port" ]; then
         $CMD_TCPDUMP -i any -s 4096 -w "$d/$p-tcpdump" port ${port} &
         tcpdump_pid=$!
      fi
   fi

   local have_oprofile=""
   if [ "$CMD_OPCONTROL" -a "$OPT_COLLECT_OPROFILE" ]; then
      if $CMD_OPCONTROL --init; then
         $CMD_OPCONTROL --start --no-vmlinux
         have_oprofile="yes"
      fi
   elif [ "$CMD_STRACE" -a "$OPT_COLLECT_STRACE" -a "$mysqld_pid" ]; then
      $CMD_STRACE -T -s 0 -f -p $mysqld_pid -o "$d/$p-strace" &
      local strace_pid=$!
   fi

   if [ ! "$OPT_MYSQL_ONLY" ]; then 
      ps -eaF  >> "$d/$p-ps"  &
      top -bn${OPT_RUN_TIME} >> "$d/$p-top" &

      [ "$mysqld_pid" ] && _lsof $mysqld_pid >> "$d/$p-lsof" &

      if [ "$CMD_SYSCTL" ]; then
         $CMD_SYSCTL -a >> "$d/$p-sysctl" &
      fi

      if [ "$CMD_DMESG" ]; then
         local UPTIME=`cat /proc/uptime | awk '{ print $1 }'`
         local START_TIME=$(echo "$UPTIME 60" | awk '{print ($1 - $2)}')
         $CMD_DMESG  | perl -ne 'm/\[\s*(\d+)\./; if ($1 > '${START_TIME}') { print }' >> "$d/$p-dmesg" & 
      fi

      local cnt=$(($OPT_RUN_TIME / $OPT_SLEEP_COLLECT))
      if [ "$CMD_VMSTAT" ]; then
         $CMD_VMSTAT $OPT_SLEEP_COLLECT $cnt >> "$d/$p-vmstat" &
         $CMD_VMSTAT $OPT_RUN_TIME 2 >> "$d/$p-vmstat-overall" &
      fi
      if [ "$CMD_IOSTAT" ]; then
         $CMD_IOSTAT -dx $OPT_SLEEP_COLLECT $cnt >> "$d/$p-iostat" &
         $CMD_IOSTAT -dx $OPT_RUN_TIME 2 >> "$d/$p-iostat-overall" &
      fi
      if [ "$CMD_MPSTAT" ]; then
         $CMD_MPSTAT -P ALL $OPT_SLEEP_COLLECT $cnt >> "$d/$p-mpstat" &
         $CMD_MPSTAT -P ALL $OPT_RUN_TIME 1 >> "$d/$p-mpstat-overall" &
      fi

      $CMD_MYSQLADMIN $EXT_ARGV ext -i$OPT_SLEEP_COLLECT -c$cnt >>"$d/$p-mysqladmin" &
      local mysqladmin_pid=$!
   fi 

   local have_lock_waits_table=""
   $CMD_MYSQL $EXT_ARGV -e "SHOW TABLES FROM INFORMATION_SCHEMA" \
      | grep -i "INNODB_LOCK_WAITS" >/dev/null 2>&1
   if [ $? -eq 0 ]; then
      have_lock_waits_table="yes"
   fi

   log "Loop start: $(date +'TS %s.%N %F %T')"
   local start_time=$(date +'%s')
   local curr_time=$start_time
   local ps_instrumentation_enabled=$($CMD_MYSQL $EXT_ARGV -e 'SELECT ENABLED FROM performance_schema.setup_instruments WHERE NAME = "transaction";' \
                                      | sed "2q;d" | sed 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/')

   if [ !$ps_instrumentation_enabled = "yes" ]; then
      log "Performance Schema instrumentation is disabled"
   fi

   while [ $((curr_time - start_time)) -lt $OPT_RUN_TIME ]; do
      if [ ! "$OPT_MYSQL_ONLY" ]; then
         disk_space $d > $d/$p-disk-space
         check_disk_space          \
            $d/$p-disk-space       \
            "$OPT_DISK_BYTES_FREE" \
            "$OPT_DISK_PCT_FREE"   \
            || break

         sleep $(date +'%s.%N' | awk "{print $OPT_SLEEP_COLLECT - (\$1 % $OPT_SLEEP_COLLECT)}")
         local ts="$(date +"TS %s.%N %F %T")"

         if [ -d "/proc" ]; then
            if [ -f "/proc/diskstats" ]; then
               (echo $ts; cat /proc/diskstats) >> "$d/$p-diskstats" &
            fi
            if [ -f "/proc/stat" ]; then
               (echo $ts; cat /proc/stat) >> "$d/$p-procstat" &
            fi
            if [ -f "/proc/vmstat" ]; then
               (echo $ts; cat /proc/vmstat) >> "$d/$p-procvmstat" &
            fi
            if [ -f "/proc/meminfo" ]; then
               (echo $ts; cat /proc/meminfo) >> "$d/$p-meminfo" &
            fi
            if [ -f "/proc/slabinfo" ]; then
               (echo $ts; cat /proc/slabinfo) >> "$d/$p-slabinfo" &
            fi
            if [ -f "/proc/interrupts" ]; then
               (echo $ts; cat /proc/interrupts) >> "$d/$p-interrupts" &
            fi
         fi
         (echo $ts; df -k) >> "$d/$p-df" &
         (echo $ts; netstat -antp) >> "$d/$p-netstat"   &
         (echo $ts; netstat -s)    >> "$d/$p-netstat_s" &
     fi
      ($CMD_MYSQL $EXT_ARGV -e "SHOW FULL PROCESSLIST\G") \
         >> "$d/$p-processlist" &
      if [ "$have_lock_waits_table" ]; then
         (lock_waits)   >>"$d/$p-lock-waits" &
         (transactions) >>"$d/$p-transactions" &
      fi

      if [ "${mysql_version}" '>' "5.6" ] && [ $ps_instrumentation_enabled == "yes" ]; then
         ps_locks_transactions "$d/$p-ps-locks-transactions"
      fi

      if [ "${mysql_version}" '>' "5.6" ]; then
         (ps_prepared_statements) >> "$d/$p-prepared-statements" &
      fi

      slave_status "$d/$p-slave-status" "${mysql_version}" 

      curr_time=$(date +'%s')
   done
   log "Loop end: $(date +'TS %s.%N %F %T')"

   if [ "$have_oprofile" ]; then
      $CMD_OPCONTROL --stop
      $CMD_OPCONTROL --dump

      local oprofiled_pid=$(_pidof oprofiled | awk '{print $1; exit;}')
      if [ "$oprofiled_pid" ]; then
         kill $oprofiled_pid
      else
         warn "Cannot kill oprofiled because its PID cannot be determined"
      fi

      $CMD_OPCONTROL --save=pt_collect_$p

      local mysqld_path=$(_which mysqld);
      if [ "$mysqld_path" -a -f "$mysqld_path" ]; then
         $CMD_OPREPORT            \
            --demangle=smart      \
            --symbols             \
            --merge tgid          \
            session:pt_collect_$p \
            "$mysqld_path"        \
            > "$d/$p-opreport"
      else
         log "oprofile data saved to pt_collect_$p; you should be able"       \
              "to get a report by running something like 'opreport"           \
              "--demangle=smart --symbols --merge tgid session:pt_collect_$p" \
              "/path/to/mysqld'"                                              \
            > "$d/$p-opreport"
      fi
   elif [ "$CMD_STRACE" -a "$OPT_COLLECT_STRACE" ]; then
      kill -s 2 $strace_pid
      sleep 1
      kill -s 15 $strace_pid
      [ "$mysqld_pid" ] && kill -s 18 $mysqld_pid
   fi

   innodb_status 2
   tokudb_status 2
   rocksdb_status 2

   $CMD_MYSQL $EXT_ARGV -e "$mutex" >> "$d/$p-mutex-status2" &
   open_tables                      >> "$d/$p-opentables2"   &

   kill $mysqladmin_pid
   [ "$tail_error_log_pid" ] && kill $tail_error_log_pid
   [ "$tcpdump_pid" ]        && kill $tcpdump_pid

   hostname > "$d/$p-hostname"

   wait_for_subshells $OPT_RUN_TIME
   kill_all_subshells
   for file in "$d/$p-"*; do
      if [ -z "$(grep -v '^TS ' --max-count 10 "$file")" ]; then
         log "Removing empty file $file";
         rm "$file"
      fi
   done
}

open_tables() {
   local open_tables=$($CMD_MYSQLADMIN $EXT_ARGV ext | grep "Open_tables" | awk '{print $4}')
   if [ -n "$open_tables" -a $open_tables -le 1000 ]; then
      $CMD_MYSQL $EXT_ARGV -e 'SHOW OPEN TABLES' &
   else
      log "Too many open tables: $open_tables"
   fi
}

lock_waits() {
   local sql1="SELECT SQL_NO_CACHE
      CONCAT('thread ', b.trx_mysql_thread_id, ' from ', p.host) AS who_blocks,
      IF(p.command = \"Sleep\", p.time, 0) AS idle_in_trx,
      MAX(TIMESTAMPDIFF(SECOND, r.trx_wait_started, CURRENT_TIMESTAMP)) AS max_wait_time,
      COUNT(*) AS num_waiters
   FROM INFORMATION_SCHEMA.INNODB_LOCK_WAITS AS w
   INNER JOIN INFORMATION_SCHEMA.INNODB_TRX AS b ON b.trx_id = w.blocking_trx_id
   INNER JOIN INFORMATION_SCHEMA.INNODB_TRX AS r ON r.trx_id = w.requesting_trx_id
   LEFT JOIN INFORMATION_SCHEMA.PROCESSLIST AS p ON p.id = b.trx_mysql_thread_id
   GROUP BY who_blocks ORDER BY num_waiters DESC\G"
   $CMD_MYSQL $EXT_ARGV -e "$sql1"

   local sql2="SELECT SQL_NO_CACHE
      r.trx_id AS waiting_trx_id,
      r.trx_mysql_thread_id AS waiting_thread,
      TIMESTAMPDIFF(SECOND, r.trx_wait_started, CURRENT_TIMESTAMP) AS wait_time,
      r.trx_query AS waiting_query,
      l.lock_table AS waiting_table_lock,
      b.trx_id AS blocking_trx_id, b.trx_mysql_thread_id AS blocking_thread,
      SUBSTRING(p.host, 1, INSTR(p.host, ':') - 1) AS blocking_host,
      SUBSTRING(p.host, INSTR(p.host, ':') +1) AS blocking_port,
      IF(p.command = \"Sleep\", p.time, 0) AS idle_in_trx,
      b.trx_query AS blocking_query
   FROM INFORMATION_SCHEMA.INNODB_LOCK_WAITS AS w
   INNER JOIN INFORMATION_SCHEMA.INNODB_TRX AS b ON b.trx_id = w.blocking_trx_id
   INNER JOIN INFORMATION_SCHEMA.INNODB_TRX AS r ON r.trx_id = w.requesting_trx_id
   INNER JOIN INFORMATION_SCHEMA.INNODB_LOCKS AS l ON w.requested_lock_id = l.lock_id
   LEFT JOIN INFORMATION_SCHEMA.PROCESSLIST AS p ON p.id = b.trx_mysql_thread_id
   ORDER BY wait_time DESC\G"
   $CMD_MYSQL $EXT_ARGV -e "$sql2"
} 

transactions() {
   $CMD_MYSQL $EXT_ARGV -e "SELECT SQL_NO_CACHE * FROM INFORMATION_SCHEMA.INNODB_TRX ORDER BY trx_id\G"
   $CMD_MYSQL $EXT_ARGV -e "SELECT SQL_NO_CACHE * FROM INFORMATION_SCHEMA.INNODB_LOCKS ORDER BY lock_trx_id\G"
   $CMD_MYSQL $EXT_ARGV -e "SELECT SQL_NO_CACHE * FROM INFORMATION_SCHEMA.INNODB_LOCK_WAITS ORDER BY blocking_trx_id, requesting_trx_id\G"
}

tokudb_status() {
    local n=$1

    $CMD_MYSQL $EXT_ARGV -e "SHOW ENGINE TOKUDB STATUS\G" \
      >> "$d/$p-tokudbstatus$n" || rm -f "$d/$p-tokudbstatus$n"
}

innodb_status() {
   local n=$1

   local innostat=""

   $CMD_MYSQL $EXT_ARGV -e "SHOW /*!40100 ENGINE*/ INNODB STATUS\G" \
      >> "$d/$p-innodbstatus$n"
   grep "END OF INNODB" "$d/$p-innodbstatus$n" >/dev/null || {
      if [ -d /proc -a -d /proc/$mysqld_pid ]; then
         for fd in /proc/$mysqld_pid/fd/*; do
            file $fd | grep deleted >/dev/null && {
               grep 'INNODB' $fd >/dev/null && {
                  cat $fd > "$d/$p-innodbstatus$n"
                  break
               }
            }
         done
      fi
   }
}

rocksdb_status() {
    local n=$1

    has_rocksdb=`$CMD_MYSQL $EXT_ARGV -e "SHOW ENGINES" | grep -i 'rocksdb'`
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        $CMD_MYSQL $EXT_ARGV -e "SHOW ENGINE ROCKSDB STATUS\G" \
                   >> "$d/$p-rocksdbstatus$n" || rm -f "$d/$p-rocksdbstatus$n"
    fi
}

ps_locks_transactions() {
   local outfile=$1 
   
   $CMD_MYSQL $EXT_ARGV -e 'select @@performance_schema' | grep "1" &>/dev/null

   if [ $? -eq 0 ]; then
      local status="select t.processlist_id, ml.* from performance_schema.metadata_locks ml join performance_schema.threads t on (ml.owner_thread_id=t.thread_id)\G"
      echo -e "\n$status\n" >> $outfile
      $CMD_MYSQL $EXT_ARGV -e "$status" >> $outfile

      local status="select t.processlist_id, th.* from performance_schema.table_handles th left join performance_schema.threads t on (th.owner_thread_id=t.thread_id)\G"
      echo -e "\n$status\n" >> $outfile
      $CMD_MYSQL $EXT_ARGV -e "$status" >> $outfile

      local status="select t.processlist_id, et.* from performance_schema.events_transactions_current et join performance_schema.threads t using(thread_id)\G"
      echo -e "\n$status\n" >> $outfile
      $CMD_MYSQL $EXT_ARGV -e "$status" >> $outfile

      local status="select t.processlist_id, et.* from performance_schema.events_transactions_history_long et join performance_schema.threads t using(thread_id)\G"
      echo -e "\n$status\n" >> $outfile
      $CMD_MYSQL $EXT_ARGV -e "$status" >> $outfile
  else
      echo "Performance schema is not enabled" >> $outfile
   fi

}

ps_prepared_statements() {
   $CMD_MYSQL $EXT_ARGV -e "SELECT t.processlist_id, pse.* \
                            FROM performance_schema.prepared_statements_instances pse \
                            JOIN performance_schema.threads t \
                            ON (pse.OWNER_THREAD_ID=t.thread_id)\G"
}

slave_status() {
   local outfile=$1
   local mysql_version=$2

   local sql="SHOW SLAVE STATUS\G"   
   echo -e "\n$sql\n" >> $outfile
   $CMD_MYSQL $EXT_ARGV -e "$sql" >> $outfile
   if [ "${mysql_version}" '>' "5.6" ]; then
      local sql="SELECT * FROM performance_schema.replication_connection_configuration JOIN performance_schema.replication_applier_configuration USING(channel_name)\G"
      echo -e "\n$sql\n" >> $outfile
      $CMD_MYSQL $EXT_ARGV -e "$sql" >> $outfile

      sql="SELECT * FROM performance_schema.replication_connection_status\G"
      echo -e "\n$sql\n" >> $outfile
      $CMD_MYSQL $EXT_ARGV -e "$sql" >> $outfile

      sql="SELECT * FROM performance_schema.replication_applier_status JOIN performance_schema.replication_applier_status_by_coordinator USING(channel_name)\G"
      echo -e "\n$sql\n" >> $outfile
      $CMD_MYSQL $EXT_ARGV -e "$sql" >> $outfile
   fi
}


collect_mysql_variables() {
   local outfile=$1 

   local sql="SHOW GLOBAL VARIABLES"
   echo -e "\n$sql\n" >> $outfile
   $CMD_MYSQL $EXT_ARGV -e "$sql" >> $outfile

   sql="select * from performance_schema.variables_by_thread order by thread_id, variable_name;"
   echo -e "\n$sql\n" >> $outfile
   $CMD_MYSQL $EXT_ARGV -e "$sql" >> $outfile
   
   sql="select * from performance_schema.user_variables_by_thread order by thread_id, variable_name;"
   echo -e "\n$sql\n" >> $outfile
   $CMD_MYSQL $EXT_ARGV -e "$sql" >> $outfile
   
   sql="select * from performance_schema.status_by_thread order by thread_id, variable_name; "
   echo -e "\n$sql\n" >> $outfile
   $CMD_MYSQL $EXT_ARGV -e "$sql" >> $outfile

}

# ###########################################################################
# End collect package
# ###########################################################################

# ###########################################################################
# Global variables
# ###########################################################################
TRIGGER_FUNCTION=""
RAN_WITH=""
EXIT_REASON=""
TOOL="pt-stalk"
OKTORUN=1
ITER=1

# ###########################################################################
# Plugin hooks
# ###########################################################################

before_stalk() {
   :
}

before_collect() {
   :
}

after_collect() {
   :
}

after_collect_sleep() {
   :
}

after_interval_sleep() {
   :
}

after_stalk() {
   :
}

# ###########################################################################
# Subroutines
# ###########################################################################

grep_processlist() {
   local file="$1"
   local col="$2"
   local pat="${3:-""}"
   local gt="${4:-0}"
   local quiet="${5:-0}"

   awk "
      BEGIN {
         FS=\"|\"
         OFS=\" | \"
         n_cols=0
         found=0
      }

      /^\|/ {
         if ( n_cols ) {
            val=colno_for_name[\"$col\"]
            if ((\"$pat\"  && match(\$val, \"$pat\")) || ($gt && \$val > $gt) ) {
               found++
               if (!$quiet) print \$0
            }
         }
         else {
            for (i = 1; i <= NF; i++) {
               gsub(/^[ ]*/, \"\", \$i)
               gsub(/[ ]*$/, \"\", \$i)
               if ( \$i != \"\" ) {
                  name_for_colno[i]=\$i
                  colno_for_name[\$i]=i
                  n_cols++
               }
            }
         }
      }

      END {
         if ( found )
            exit 0
         exit 1
      }
   " "$file"
}

set_trg_func() {
   local func="$1"
   if [ -f "$func" ]; then
      # Trigger function is a file with Bash code; source it.
      . "$func"
      TRIGGER_FUNCTION="trg_plugin"
      return 0  # success
   else
      # Trigger function is name of a built-in function.
      func=$(echo "$func" | tr '[:upper:]' '[:lower:]')
      if [ "$func" = "status" -o "$func" = "processlist" ]; then
         TRIGGER_FUNCTION="trg_$func"
         return 0  # success
      fi
   fi
   return 1  # error
}

trg_status() {
   local var="$1"
   mysqladmin $EXT_ARGV extended-status \
      | grep "$OPT_VARIABLE " \
      | awk '{print $4}'
}

trg_processlist() {
   local var="$1"
   local tmpfile="$PT_TMPDIR/processlist"
   mysqladmin $EXT_ARGV processlist                      > "$tmpfile-1"
   grep_processlist "$tmpfile-1" "$var" "$OPT_MATCH" 0 0 > "$tmpfile-2"
   wc -l "$tmpfile-2" | awk '{print $1}'
   rm -f "$tmpfile"*
}

oktorun() {
   if [ $OKTORUN -eq 0 ]; then
      [ -z "$EXIT_REASON" ] && EXIT_REASON="OKTORUN is false"
      return 1  # stop running
   fi

   if [ -n "$OPT_ITERATIONS" ] && [ $ITER -gt $OPT_ITERATIONS ]; then
      [ -z "$EXIT_REASON" ] && EXIT_REASON="no more iterations"
      return 1  # stop running
   fi

   return 0  # continue running
}

sleep_ok() {
   local seconds="$1"
   local msg="${2:-""}"
   if oktorun; then
      [ "$msg" ] && log "$msg"
      sleep $seconds
   fi
}

purge_samples() {
   local dir="$1"
   local retention_time="$2"
   local retention_count="$3"
   local retention_size="$4"

   # Delete collect files which more than --retention-time days old.
   find "$dir" -type f -mtime +$retention_time -exec rm -f '{}' \;

   local oprofile_dir="/var/lib/oprofile/samples"
   if [ -d "$oprofile_dir" ]; then
      # "pt_collect_" here needs to match $CMD_OPCONTROL --save=pt_collect_$p
      # in collect().  TODO: fix this
      find "$oprofile_dir" -depth -type d -name 'pt_collect_*' \
         -mtime +$retention_time -exec rm -rf '{}' \;
   fi

   targetCnt=$(($retention_count + 0))
   if [ $targetCnt -gt 0 ]; then
      targetCnt=$(($retention_count + 1))
      files_to_delete=$(find $dir -type f -exec basename {} \; | cut -f1 -d- | sort -r | uniq | tail -n +${targetCnt})
      for prefix in $files_to_delete; do
          echo "deleting files ${dir}${prefix}* according to the --retention-count param"
          rm -f ${dir}${prefix}* 2>/dev/null
      done
   fi

   targetSize=$(($retention_size + 0))
   if [ $targetSize -gt 0 ]; then
      files_to_delete=$(find $dir -type f -exec basename {} \; | cut -f1 -d- | sort -r | uniq | tail -n +1)
      for prefix in $files_to_delete; do
          current_size=$(du -BM $dir | cut -f1 -d"M")
          if [ $current_size -gt $targetSize ]; then
             echo "deleting files ${dir}${prefix}* according to the --retention-size param"
             rm -f ${dir}${prefix}* 2>/dev/null
          else
             break
          fi
      done
   fi
}

sigtrap() {
   if [ $OKTORUN -eq 1 ]; then
      warn "Caught signal, exiting"
      OKTORUN=0
   else
      warn "Caught signal again, forcing exit"
      exit $EXIT_STATUS
   fi
}

stalk() {
   local cycles_true=0   # increment each time check is true, else set to 0
   local matched=""      # set to "yes" when check is true
   local last_prefix=""  # prefix of last collection

   while oktorun; do
      # Run the trigger which returns the value of whatever is being
      # checked.  When the value is > --threshold for at least --cycle
      # consecutive times, start collecting.
      if [ "$OPT_STALK" ]; then
         local value=$($TRIGGER_FUNCTION $OPT_VARIABLE)
         local trg_exit_status=$?
         if [ -z "$value" ]; then
            # No value.  Maybe we failed to connect to MySQL?
            warn "Detected value is empty; something failed?  Trigger exit status: $trg_exit_status"
            matched=""
            cycles_true=0
         elif (( $(echo "$value $OPT_THRESHOLD" | awk '{print ($1 > $2)}') )); then
            matched="yes"
            cycles_true=$(($cycles_true + 1))
         else
            matched=""
            cycles_true=0
         fi

         local msg="Check results: $OPT_FUNCTION($OPT_VARIABLE)=$value, matched=${matched:-no}, cycles_true=$cycles_true"
         if [ "$matched" ]; then
            log "$msg"
         else
            info "$msg"
         fi
      elif [ "$OPT_COLLECT" ]; then
         # Make the next if condition true.
         matched=1
         cycles_true=$OPT_CYCLES

         local msg="Not stalking; collect triggered immediately"
         log "$msg"
      fi

      if [ "$matched" -a $cycles_true -ge $OPT_CYCLES ]; then 
         # ##################################################################
         # Start collecting, maybe.
         # ##################################################################
         log "Collect $ITER triggered"
         log "MYSQL_ONLY: $OPT_MYSQL_ONLY"

         # Send email to whomever that collect has been triggered.
         if [ "$OPT_NOTIFY_BY_EMAIL" ]; then
            echo "$msg on $(hostname)" \
            | mail -s "Collect triggered on $(hostname)" \
              "$OPT_NOTIFY_BY_EMAIL"
         fi

         if [ "$OPT_COLLECT" ]; then
            local prefix="${OPT_PREFIX:-$(date +%F-%T | tr ':-' '_')}"
            # Check if we'll have enough disk space to collect.  Disk space
            # is also checked every interval while collecting.
            local margin="20971520"  # default 20M margin, unless:
            if [ -n "$last_prefix" ]; then
               margin=$(du -mc "$OPT_DEST"/"$last_prefix"-* | tail -n 1 | awk '{print $1'})
            fi 
            disk_space "$OPT_DEST" > "$OPT_DEST/$prefix-disk-space"
            check_disk_space                  \
               "$OPT_DEST/$prefix-disk-space" \
               "$OPT_DISK_BYTES_FREE"         \
               "$OPT_DISK_PCT_FREE"           \
               "$margin"
            if [ $? -eq 0 ]; then
               # There should be enough disk space, so collect.
               ts "$msg"                        >> "$OPT_DEST/$prefix-trigger"
               ts "pt-stalk ran with $RAN_WITH" >> "$OPT_DEST/$prefix-trigger"
               last_prefix="$prefix"

               # Plugin hook:
               before_collect

               # Fork and background the collect subroutine which will
               # run for --run-time seconds.  We (the parent) sleep
               # while its collecting (hopefully --sleep is longer than
               # --run-time).
               (
                  collect "$OPT_DEST" "$prefix"
               ) >> "$OPT_DEST/$prefix-output" 2>&1 &
               local collector_pid=$!
               log "Collect $ITER PID $collector_pid"

               # Plugin hook:
               after_collect $collector_pid
            else 
               # There will not be enough disk space, so do not collect.
               warn "Collect canceled because there will not be enough disk space after collecting another $margin MB"
            fi

            # Purge old collect files.
            if [ -d "$OPT_DEST" ]; then
               purge_samples "$OPT_DEST" "$OPT_RETENTION_TIME" "$OPT_RETENTION_COUNT" "$OPT_RETENTION_SIZE"
            fi
         fi

         # ##################################################################
         # Done collecting.
         # ##################################################################
         log "Collect $ITER done"
         ITER=$((ITER + 1))
         cycles_true=0
         sleep_ok "$OPT_SLEEP" "Sleeping $OPT_SLEEP seconds after collect"

         # Plugin hook:
         after_collect_sleep
      else
         # Trigger/check/value is ok, sleep until next check.
         sleep_ok "$OPT_INTERVAL"

         # Plugin hook:
         after_interval_sleep
      fi
   done

   # One final purge of old collect files, but only if in collect mode.
   if [ "$OPT_COLLECT" -a -d "$OPT_DEST" ]; then
      purge_samples "$OPT_DEST" "$OPT_RETENTION_TIME" "$OPT_RETENTION_COUNT" "$OPT_RETENTION_SIZE"
   fi

   # Before exiting, the last collector may still be running.
   # Wait for it to finish in case the tool is part of a script,
   # or part of a test, so the caller has access to the collected
   # data when the tool exists.  collect() waits an additional
   # --run-time seconds for itself to complete, which means we
   # have to wait for 2 * run-time like it plus some overhead else
   # we may get in sync with the collector and kill it a microsecond
   # before it kills itself, thus 3 * run-time.
   # https://bugs.launchpad.net/percona-toolkit/+bug/1070434
   wait_for_subshells $((OPT_RUN_TIME * 3))
   kill_all_subshells
}

# ###########################################################################
# Main program loop, called below if tool is ran from the command line.
# ###########################################################################

main() {
   trap sigtrap SIGHUP SIGINT SIGTERM

   # Note: $$ is the parent's PID, but we're a child proc.
   # Bash 4 has $BASHPID but we can't rely on that.  Consequently,
   # we don't know our own PID.  See the usage of $! below.
   RAN_WITH="--function=$OPT_FUNCTION --variable=$OPT_VARIABLE --threshold=$OPT_THRESHOLD --match=$OPT_MATCH --cycles=$OPT_CYCLES --interval=$OPT_INTERVAL --iterations=$OPT_ITERATIONS --run-time=$OPT_RUN_TIME --sleep=$OPT_SLEEP --dest=$OPT_DEST --prefix=$OPT_PREFIX --notify-by-email=$OPT_NOTIFY_BY_EMAIL --log=$OPT_LOG --pid=$OPT_PID --plugin=$OPT_PLUGIN"

   log "Starting $0 $RAN_WITH"

   # Test if we have root; warn if not, but it isn't critical.
   if [ "$(id -u)" != "0" ]; then
      log 'Not running with root privileges!';
   fi

   # Make a secure tmpdir.
   mk_tmpdir

   # Plugin hook:
   before_stalk

   # Stalk while oktorun.
   stalk

   # Plugin hook:
   after_stalk

   # Clean up.
   rm_tmpdir
   remove_pid_file "$OPT_PID"

   log "Exiting because $EXIT_REASON"
   log "$0 exit status $EXIT_STATUS"
   exit $EXIT_STATUS
}

# Execute the program if it was not included from another file.
# This makes it possible to include without executing, and thus test.
if    [ "${0##*/}" = "$TOOL" ] \
   || [ "${0##*/}" = "bash" -a "${_:-""}" = "$0" ]; then

   # Parse command line options.  We must do this first so we can
   # see if --daemonize was specified.
   mk_tmpdir
   parse_options "$0" "${@:-""}"

   # Verify and set TRIGGER_FUNCTION based on --function.
   if ! set_trg_func "$OPT_FUNCTION"; then
      option_error "Invalid --function value: $OPT_FUNCTION"
   fi

   # Verify and source the --plugin.
   if [ "$OPT_PLUGIN" ]; then
      if [ -f "$OPT_PLUGIN" ]; then
         . "$OPT_PLUGIN"
      else
         option_error "Invalid --plugin value: $OPT_PLUGIN is not a file"
      fi
   fi

   if [ -z "$OPT_STALK" -a "$OPT_COLLECT" ]; then
      # Not stalking; do immediate collect once.
      OPT_CYCLES=0
   fi

   usage_or_errors "$0"
   po_status=$?
   rm_tmpdir
   if [ $po_status -ne 0 ]; then
      [ $OPT_ERRS -gt 0 ] && exit 1
      exit 0
   fi

   # if ASK-PASS , request password on terminal without echoing. This will override --password
   if [ -n "$OPT_ASK_PASS" ]; then 
      stty_orig=`stty -g`           # save original terminal setting.
      echo -n "Enter MySQL password: ";
      stty -echo                    # turn-off echoing.
      read OPT_PASSWORD             # read the password
      stty $stty_orig               # restore terminal setting.
   fi

   MYSQL_ARGS="$(mysql_options)"
   EXT_ARGV="$(arrange_mysql_options "$EXT_ARGV $MYSQL_ARGS")"


   # Check that mysql and mysqladmin are in PATH.  If not, we're
   # already dead in the water, so don't bother with cmd line opts,
   # just error and exit.
   [ -n "$(mysql --help)" ] \
      || die "Cannot execute mysql.  Check that it is in PATH."
   [ -n "$(mysqladmin --help)" ] \
      || die "Cannot execute mysqladmin.  Check that it is in PATH."

   # Now that we have the cmd line opts, check that we can actually
   # connect to MySQL.
   [ -n "$(mysql $EXT_ARGV -e 'SELECT 1')" ] \
      || die "Cannot connect to MySQL.  Check that MySQL is running and that the options after -- are correct."

   # Check existence and access to the --dest dir if we're collecting.
   if [ "$OPT_COLLECT" ]; then
      if [ ! -d "$OPT_DEST" ]; then
         mkdir -p "$OPT_DEST" || die "Cannot make --dest $OPT_DEST"
      fi

      # Check access to the --dest dir.  By setting -x in the subshell,
      # if either command fails, the subshell will exit immediately and
      # $? will be non-zero.
      (
         set -e
         touch "$OPT_DEST/test"
         rm "$OPT_DEST/test"
      )
      if [ $? -ne 0 ]; then
         die "Cannot read and write files to --dest $OPT_DEST"
      fi
   fi

   if [ "$OPT_STALK" -a "$OPT_DAEMONIZE" ]; then
      # Check access to the --log file.
      touch "$OPT_LOG" || die "Cannot write to --log $OPT_LOG"

      # The PID file will at first have our (parent) PID.
      # This is fine for ensuring that only one of us is
      # running, but it's not fine if the user wants to use
      # the PID in the PID file to check or kill the child
      # process.  So we'll need to update the PID file with
      # the child's PID.
      make_pid_file "$OPT_PID" $$

      main "${@:-""}" </dev/null 1>>"$OPT_LOG" 2>&1 &

      # Update PID file with the child's PID.
      # The child PID is $BASHPID but that special var is only
      # in Bash 4+, so we can't rely on it.  Consequently, we
      # use $! to get the PID of the child we just forked.
      echo "$!" > "$OPT_PID"
   else
      [ "$OPT_STALK" ] && make_pid_file "$OPT_PID" $$
      main "${@:-""}"
   fi
fi

# ############################################################################
# Documentation
# ############################################################################
:<<'DOCUMENTATION'
=pod

=head1 NAME

pt-stalk - Collect forensic data about MySQL when problems occur.

=head1 SYNOPSIS

Usage: pt-stalk [OPTIONS]

pt-stalk waits for a trigger condition to occur, then collects data
to help diagnose problems.  The tool is designed to run as a daemon with root
privileges, so that you can diagnose intermittent problems that you cannot
observe directly.  You can also use it to execute a custom command, or to
collect data on demand without waiting for the trigger to occur.

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

Sometimes a problem happens infrequently and for a short time, giving you no
chance to see the system when it happens. How do you solve intermittent MySQL
problems when you can't observe them? That's why pt-stalk exists. In addition to
using it when there's a known problem on your servers, it is a good idea to run
pt-stalk all the time, even when you think nothing is wrong.  You will
appreciate the data it collects when a problem occurs, because problems such as
MySQL lockups or spikes in activity typically leave no evidence to use in root
cause analysis.

pt-stalk does two things: it watches a MySQL server and waits for a trigger
condition to occur, and it collects diagnostic data when that trigger occurs.
To avoid false-positives caused by short-lived problems, the trigger condition
must be true at least L<"--cycles"> times before a L<"--collect"> is triggered.

To use pt-stalk effectively, you need to define a good trigger.  A good trigger
is sensitive enough to fire reliably when a problem occurs, so that you don't
miss a chance to solve problems.  On the other hand, a good trigger isn't
prone to false positives, so you don't gather information when the server
is functioning normally.

The most reliable triggers for MySQL tend to be the number of connections to the
server, and the number of queries running concurrently. These are available in
the SHOW GLOBAL STATUS command as Threads_connected and Threads_running.
Sometimes Threads_connected is not a reliable indicator of trouble, but
Threads_running usually is.  Your job, as the tool's user, is to define an
appropriate trigger condition for the tool.  Choose carefully, because the
quality of your results will depend on the trigger you choose.

You define the trigger with the L<"--function">, L<"--variable">, 
L<"--threshold">, and L<"--cycles"> options.  The default values
for these options define a reasonable trigger, but you should adjust
or change them to suite your particular system and needs.

By default, pt-stalk tool watches MySQL forever until the trigger occurs,
then it collects diagnostic data for a while, and sleeps afterwards to avoid
repeatedly collecting data if the trigger remains true.  The general order of
operations is:

   while true; do
      if --variable from --function > --threshold; then
         cycles_true++
         if cycles_true >= --cycles; then
            --notify-by-email
            if --collect; then
               if --disk-bytes-free and --disk-pct-free ok; then
                  (--collect for --run-time seconds) &
               fi
               rm files in --dest older than --retention-time
            fi
            iter++
            cycles_true=0
         fi
         if iter < --iterations; then
            sleep --sleep seconds
         else
            break
         fi
      else
         if iter < --iterations; then
            sleep --interval seconds
         else
            break
         fi
      fi
   done
   rm old --dest files older than --retention-time
   if --collect process are still running; then
      wait up to --run-time * 3 seconds
      kill any remaining --collect processes 
   fi

The diagnostic data is written to files whose names begin with a timestamp, so
you can distinguish samples from each other in case the tool collects data
multiple times.  The pt-sift tool is designed to help you browse and analyze
the resulting data samples.

Although this sounds simple enough, in practice there are a number of
subtleties, such as detecting when the disk is beginning to fill up so that the
tool doesn't cause the server to run out of disk space.  This tool handles these
types of potential problems, so it's a good idea to use this tool instead of
writing something from scratch and possibly experiencing some of the hazards
this tool is designed to avoid.

=head1 CONFIGURING

You can use standard Percona Toolkit configuration files to set command line
options.

You will probably want to run the tool as a daemon and customize at least the
L<"--threshold">.  Here's a sample configuration file for triggering when
there are more than 20 queries running at once:

  daemonize
  threshold=20

If you don't run the tool as root, then you will need specify several options,
such as L<"--pid">, L<"--log">, and L<"--dest">, else the tool will probably
fail to start.

=head1 OPTIONS

=over

=item --ask-pass

Prompt for a password when connecting to MySQL.

=item --collect

default: yes; negatable: yes

Collect diagnostic data when the trigger occurs.  Specify C<--no-collect>
to make the tool watch the system but not collect data.

See also L<"--stalk">.

=item --collect-gdb

Collect GDB stacktraces.  This is achieved by attaching to MySQL and printing
stack traces from all threads. This will freeze the server for some period of
time, ranging from a second or so to much longer on very busy systems with a lot
of memory and many threads in the server.  For this reason, it is disabled by
default. However, if you are trying to diagnose a server stall or lockup,
freezing the server causes no additional harm, and the stack traces can be vital
for diagnosis.

In addition to freezing the server, there is also some risk of the server
crashing or performing badly after GDB detaches from it.

=item --collect-oprofile

Collect oprofile data.  This is achieved by starting an oprofile session,
letting it run for the collection time, and then stopping and saving the
resulting profile data in the system's default location.  Please read your
system's oprofile documentation to learn more about this.

=item --collect-strace

Collect strace data. This is achieved by attaching strace to the server, which
will make it run very slowly until strace detaches.  The same cautions apply as
those listed in --collect-gdb.  You should not enable this option together with
--collect-gdb, because GDB and strace can't attach to the server process
simultaneously.

=item --collect-tcpdump

Collect tcpdump data. This option causes tcpdump to capture all traffic on all
interfaces for the port on which MySQL is listening.  You can later use
pt-query-digest to decode the MySQL protocol and extract a log of query traffic
from it.

=item --config

type: string

Read this comma-separated list of config files.  If specified, this must be the
first option on the command line.

=item --cycles

type: int; default: 5

How many times L<"--variable"> must be greater than L<"--threshold"> before triggering L<"--collect">.  This helps prevent false positives, and makes
the trigger condition less likely to fire when the problem recovers quickly.

=item --daemonize

Daemonize the tool.  This causes the tool to fork into the background and log
its output as specified in --log.

=item --defaults-file

short form: -F; type: string

Only read mysql options from the given file.  You must give an absolute
pathname.

=item --dest

type: string; default: /var/lib/pt-stalk

Where to save diagnostic data from L<"--collect">.  Each time the tool
collects data, it writes to a new set of files, which are named with the
current system timestamp.

=item --disk-bytes-free

type: size; default: 100M

Do not L<"--collect"> if the disk has less than this much free space.
This prevents the tool from filling up the disk with diagnostic data.

If the L<"--dest"> directory contains a previously captured sample of data,
the tool will measure its size and use that as an estimate of how much data is
likely to be gathered this time, too.  It will then be even more pessimistic,
and will refuse to collect data unless the disk has enough free space to hold
the sample and still have the desired amount of free space.  For example, if
you'd like 100MB of free space and the previous diagnostic sample consumed
100MB, the tool won't collect any data unless the disk has 200MB free.

Valid size value suffixes are k, M, G, and T.

=item --disk-pct-free

type: int; default: 5

Do not L<"--collect"> if the disk has less than this percent free space.
This prevents the tool from filling up the disk with diagnostic data.

This option works similarly to L<"--disk-bytes-free"> but specifies a
percentage margin of safety instead of a bytes margin of safety.
The tool honors both options, and will not collect any data unless both
margins are satisfied.

=item --function

type: string; default: status

What to watch for the trigger.  The default value watches
C<SHOW GLOBAL STATUS>, but you can also watch C<SHOW PROCESSLIST> and specify
a file with your own custom code.  This function supplies the value of
L<"--variable">, which is then compared against L<"--threshold"> to see if the
the trigger condition is met.  Additional options may be required as
well; see below. Possible values are:

=over

=item * status

Watch C<SHOW GLOBAL STATUS> for the trigger.  The value of
L<"--variable"> then defines which status counter is the trigger.

=item * processlist

Watch C<SHOW FULL PROCESSLIST> for the trigger.  The trigger
value is the count of processes whose L<"--variable"> column matches the
L<"--match"> option.  For example, to trigger L<"--collect"> when more than
10 processes are in the "statistics" state, specify:

   --function processlist \
   --variable State       \
   --match statistics     \
   --threshold 10

=back

In addition, you can specify a file that contains your custom trigger
function, written in Unix shell script.  This can be a wrapper that executes
anything you wish.  If the argument to L<"--function"> is a file, then it
takes precedence over built-in functions, so if there is a file in the working
directory named "status" or "processlist" then the tool will use that file
even though are valid built-in values.

The file works by providing a function called C<trg_plugin>, and the tool
simply sources the file and executes the function.  For example, the file
might contain:

   trg_plugin() {
      mysql $EXT_ARGV -e "SHOW ENGINE INNODB STATUS" \
        | grep -c "has waited at"
   }

This snippet will count the number of mutex waits inside InnoDB.  It
illustrates the general principle: the function must output a number, which is
then compared to L<"--threshold"> as usual.  The C<$EXT_ARGV> variable
contains the MySQL options mentioned in the L<"SYNOPSIS"> above.

The file should not alter the tool's existing global variables.  Prefix any
file-specific global variables with C<PLUGIN_> or make them local.

=item --help

Print help and exit.

=item --host

short form: -h; type: string

Host to connect to.

=item --interval

type: int; default: 1

How often to check the if trigger is true, in seconds.

=item --iterations

type: int

How many times to L<"--collect"> diagnostic data.  By default, the tool
runs forever and collects data every time the trigger occurs.
Specify L<"--iterations"> to collect data a limited number of times.
This option is also useful with C<--no-stalk> to collect data once and
exit, for example.

=item --log

type: string; default: /var/log/pt-stalk.log

Print all output to this file when daemonized.

=item --match

type: string

The pattern to use when watching SHOW PROCESSLIST.  See L<"--function">
for details.

=item --notify-by-email

type: string

Send an email to these addresses for every L<"--collect">.

=item --password

short form: -p; type: string

Password to use when connecting.
If password contains commas they must be escaped with a backslash: "exam\,ple"

=item --pid

type: string; default: /var/run/pt-stalk.pid

Create the given PID file.  The tool won't start if the PID file already
exists and the PID it contains is different than the current PID.  However,
if the PID file exists and the PID it contains is no longer running, the
tool will overwrite the PID file with the current PID.  The PID file is
removed automatically when the tool exits.

=item --plugin

type: string

Load a plugin to hook into the tool and extend is functionality.
The specified file does not need to be executable, nor does its first line
need to be shebang line.  It only needs to define one or more of these
Bash functions:

=over

=item before_stalk

Called before stalking.

=item before_collect

Called when the trigger occurs, before running a L<"--collect">
subprocesses in the background.

=item after_collect

Called after running a collector process.  The PID of the collector process
is passed as the first argument.  This hook is called before
C<after_collect_sleep>.

=item after_collect_sleep

Called after sleeping L<"--sleep"> seconds for the collector process to finish.
This hook is called after C<after_collect>.

=item after_interval_sleep

Called after sleeping L<"--interval"> seconds after each trigger check.

=item after_stalk

Called after stalking.  Since pt-stalk stalks forever by default,
this hook is only called if L<"--iterations"> is specified.

=back

For example, a very simple plugin that touches a file when L<"--collect">
is triggered:

   before_collect() {
      touch /tmp/foo
   }

Since the plugin is completely sourced (imported) into the tool's namespace,
be careful not to define other functions or global variables that already
exist in the tool.  You should prefix all plugin-specific functions and
global variables with C<plugin_> or C<PLUGIN_>.

Plugins have access to all command line options but they should not modify
them.  Each option is a global variable like C<$OPT_DEST> which corresponds
to L<"--dest">.  Therefore, the global variable for each command line option
is C<OPT_> plus the option name in all caps with hyphens replaced by
underscores.

Plugins can stop the tool by setting the global variable C<OKTORUN>
to C<1>.  In this case, the global variable C<EXIT_REASON> should also
be set to indicate why the tool was stopped.

Plugin writers should keep in mind that the file destination prefix currently
in use should be accessed through the C<$prefix> variable, rather than
C<$OPT_PREFIX>.

=item --mysql-only

Trigger only MySQL related captures, ignoring all others. The only not MySQL related
value being collected is the disk space, because it is needed to calculate the
available free disk space to write the result files.
This option is useful for RDS instances.

=item --port

short form: -P; type: int

Port number to use for connection.

=item --prefix 

type: string

The filename prefix for diagnostic samples.  By default, all files created
by the same L<"--collect"> instance have a timestamp prefix based on the current
local time, like C<2011_12_06_14_02_02>, which is December 6, 2011 at 14:02:02.

=item --retention-count

type: int; default: 0

Keep the data for the last N runs. If N > 0, the program will keep the data for the last
N runs and will delete the older data.

=item --retention-size

type: int; default: 0

Keep up to --retention-size MB of data. It will keep at least 1 run even if the size is bigger
than the specified in this parameter

=item --retention-time

type: int; default: 30

Number of days to retain collected samples.  Any samples that are older will be
purged.

=item --run-time

type: int; default: 30

How long to L<"--collect"> diagnostic data when the trigger occurs.
The value is in seconds and should not be longer than L<"--sleep">.  It is
usually not necessary to change this; if the default 30 seconds doesn't
collect enough data, running longer is not likely to help because the system
or MySQL server is probably too busy to respond.  In fact, in many cases a
shorter collection period is appropriate.

This value is used two other times.  After collecting, the collect subprocess
will wait another L<"--run-time"> seconds for its commands to finish.  Some
commands can take awhile if the system is running very slowly (which can
likely be the case given that a collection was triggered).  Since empty files
are deleted, the extra wait gives commands time to finish and write their
data.  The value is potentially used again just before the tool exits to wait
again for any collect subprocesses to finish.  In most cases this won't
happen because of the aforementioned extra wait.  If it happens, the tool
will log "Waiting up to N seconds for subprocesses to finish..." where N is
three times L<"--run-time">.  In both cases, after waiting, the tool kills
all of its subprocesses.

=item --sleep

type: int; default: 300

How long to sleep after L<"--collect">.  This prevents the tool
from triggering continuously, which might be a problem if the collection process is intrusive.
It also prevents filling up the disk or gathering too much data to analyze
reasonably.

=item --sleep-collect

type: int; default: 1

How long to sleep between collection loop cycles.  This is useful with
C<--no-stalk> to do long collections.  For example, to collect data every
minute for an hour, specify: C<--no-stalk --run-time 3600 --sleep-collect 60>.

=item --socket

short form: -S; type: string

Socket file to use for connection.

=item --stalk

default: yes; negatable: yes

Watch the server and wait for the trigger to occur.  Specify C<--no-stalk>
to collect diagnostic data immediately, that is, without waiting for the
trigger to occur.  You probably also want to specify values for
L<"--interval">, L<"--iterations">, and L<"--sleep">.  For example, to
immediately collect data for 1 minute then exit, specify:

   --no-stalk --run-time 60 --iterations 1

L<"--cycles">, L<"--daemonize">, L<"--log"> and L<"--pid"> have no effect
with C<--no-stalk>.  Safeguard options, like L<"--disk-bytes-free"> and
L<"--disk-pct-free">, are still respected.

See also L<"--collect">.

=item --threshold

type: int; default: 25

The maximum acceptable value for L<"--variable">.  L<"--collect"> is
triggered when the value of L<"--variable"> is greater than L<"--threshold">
for L<"--cycles"> many times.  Currently, there is no way to define a lower
threshold to check for a L<"--variable"> value that is too low.

See also L<"--function">.

=item --user

short form: -u; type: string

User for login if not current user.

=item --variable

type: string; default: Threads_running

The variable to compare against L<"--threshold">.  See also L<"--function">.

=item --verbose

type: int; default: 2

Print more or less information while running.  Since the tool is designed
to be a long-running daemon, the default verbosity level only prints the
most important information.  If you run the tool interactively, you may
want to use a higher verbosity level.

  LEVEL PRINTS
  ===== =====================================
  0     Errors
  1     Warnings
  2     Matching triggers and collection info
  3     Non-matching triggers

=item --version

Print tool's version and exit.

=back

=head1 ENVIRONMENT

This tool does not require any environment variables for configuration,
although it can be influenced to work differently by through several
variables.  Keep in mind that these are expert settings, and should not
be used in most cases.

Specifically, the variables that can be set are:

=over

=item CMD_GDB

=item CMD_IOSTAT

=item CMD_MPSTAT

=item CMD_MYSQL

=item CMD_MYSQLADMIN

=item CMD_OPCONTROL

=item CMD_OPREPORT

=item CMD_PMAP

=item CMD_STRACE

=item CMD_SYSCTL

=item CMD_TCPDUMP

=item CMD_VMSTAT

=back

For example, during collection iostat is called with a -dx argument, but
because you have an NFS partition, you also need the -n flag there.  Instead
of editing the source, you can call pt-stalk as

    CMD_IOSTAT="iostat -n" pt-stalk ...

which will do exactly what you need.  Combined with the plugin hooks, this
gives you a fine-grained control of what the tool does.

It is possible to enable C<debug> mode in mysqladmin specifying:

C<CMD_MYSQLADMIN='mysqladmin debug' pt-stalk params ...>

=head1 SYSTEM REQUIREMENTS

This tool requires Bash v3 or newer.  Certain options require other programs:

=over

=item L<"--collect-gdb"> requires C<gdb>

=item L<"--collect-oprofile"> requires C<opcontrol> and C<opreport>

=item L<"--collect-strace"> requires C<strace>

=item L<"--collect-tcpdump"> requires C<tcpdump>

=back

=head1 BUGS

For a list of known bugs, see L<http://www.percona.com/bugs/pt-stalk>.

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

Baron Schwartz, Justin Swanhart, Fernando Ipar, Daniel Nichter,
and Brian Fraser

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

pt-stalk 3.3.0

=cut

DOCUMENTATION
