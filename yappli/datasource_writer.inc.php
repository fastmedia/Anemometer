<?php
$conf['datasources']['writer'] = array(
	'host'	=> '__ANEMOMETER_MYSQL_HOST__',
	'port'	=> __ANEMOMETER_MYSQL_PORT__,
	'db'	=> '__ANEMOMETER_MYSQL_DB___writer',
	'user'	=> '__ANEMOMETER_MYSQL_USER__',
	'password' => '__ANEMOMETER_MYSQL_PASSWORD__',
	'tables' => array(
		'global_query_review' => 'global_query_review',
		'global_query_review_history' => 'global_query_review_history'
	),
	'source_type' => 'slow_query_log'
);

