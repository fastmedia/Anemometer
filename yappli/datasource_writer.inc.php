<?php
$conf['datasources']['writer'] = array(
	'host'	=> '__ANEMOMETER_MYSQL_HOST__',
	'port'	=> __ANEMOMETER_MYSQL_PORT__,
	'db'	=> '__ANEMOMETER_MYSQL_DB___writer',
	'user'	=> '__ANEMOMETER_MYSQL_USER__',
	'password' => '__ANEMOMETER_MYSQL_PASSWORD__',
	'tables' => array(
		'global_query_review' => 'fact',
		'global_query_review_history' => 'dimension'
	),
	'source_type' => 'slow_query_log'
);

