#!/bin/bash

## env
HOUR_OFFSET=1
#for HOUR_OFFSET in `seq 7`
#do
CLUSTER="prod-audience-crypted"
LOG_GROUP=/aws/rds/cluster/prod-audience-crypted/slowquery
TMP_PREFIX="/tmp/slowlog.$$"
HOUR_PREV=$(TZ=UTC /bin/date +"%d/%m/%Y %H:" --date "${HOUR_OFFSET} hour ago")
HOUR_NOW=$(TZ=UTC /bin/date +"%d/%m/%Y %H:")
PASS_SYS=$(aws s3 cp s3://prod-yappli-credentials/monitor/anemometer.json - | jq -r .password)
EP_W=prod-slowquery-rw.yapp.li
#DB="slow_query_log"

## get db instance type
WRITERS=$(aws rds describe-db-clusters --db-cluster-identifier ${CLUSTER} | jq -cr '.DBClusters[].DBClusterMembers[] | [.DBInstanceIdentifier, .IsClusterWriter] | @tsv' | grep true | awk '{print $1}')
READERS=$(aws rds describe-db-clusters --db-cluster-identifier ${CLUSTER} | jq -cr '.DBClusters[].DBClusterMembers[] | [.DBInstanceIdentifier, .IsClusterWriter] | @tsv' | grep false | awk '{print $1}')

declare -A DBTYPE

for INSTANCE in $WRITERS
do
  DBTYPE[$INSTANCE]="writer"
done

for INSTANCE in $READERS
do
  DBTYPE[$INSTANCE]="reader"
done

## get slowlog
for INSTANCE in $WRITERS $READERS
do
  echo $INSTANCE / ${DBTYPE[$INSTANCE]}

  LOG_STREAM=${INSTANCE}
  DB="slow_query_log_${DBTYPE[$INSTANCE]}"

  MIN_PREV="00"
  for MIN in 05 10 15 20 25 30 35 40 45 50 55
  do
    START=${HOUR_PREV}${MIN_PREV}
    END=${HOUR_PREV}${MIN}
    TMP_FILE=${TMP_PREFIX}"."${DBTYPE[$INSTANCE]}"."${MIN_PREV}"."${INSTANCE}

    echo $START
    awslogs  get  $LOG_GROUP  $LOG_STREAM  -G  -S  --start="$START" --end="$END" >> $TMP_FILE

    MIN_PREV=${MIN}
  done

  START=${HOUR_PREV}"55"
  END=${HOUR_NOW}"00"
  TMP_FILE=${TMP_PREFIX}"."${DBTYPE[$INSTANCE]}".55""."${INSTANCE}

  echo $START
  awslogs  get  $LOG_GROUP  $LOG_STREAM  -G  -S  --start="$START" --end="$END" >> $TMP_FILE

done


## import slowlog to db
for TYPE in writer reader
do
  DB="slow_query_log_${TYPE}"

  for FILE in ${TMP_PREFIX}"."${TYPE}*
  do
    echo "import $FILE"
    export PERL_LWP_SSL_VERIFY_HOSTNAME=0
    INSTANCE=$(basename $FILE | sed -e 's/^.*\.//')
    pt-query-digest --user=anemometer --password=$PASS_SYS \
                    --review h=${EP_W},D=${DB},t=global_query_review \
                    --history h=${EP_W},D=${DB},t=global_query_review_history \
                    --no-report --limit=0% \
                    --filter=" \$event->{Bytes} = length(\$event->{arg}) and \$event->{hostname}=\"${INSTANCE}\"" \
		    $FILE
  done
done

rm ${TMP_PREFIX}*

#done
