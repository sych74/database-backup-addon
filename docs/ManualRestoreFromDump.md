# Restoring a Galera Cluster from a Database Dump

When working with a Galera Cluster, it’s important to consider certain limitations. Only InnoDB tables are replicated across nodes. 
Tables using other storage engines, such as mysql.* tables (which typically use the Aria or MyISAM engines), are not replicated. 
This means changes to these tables are not automatically synchronized and may lead to inconsistencies. 
For more details, refer to the MariaDB Galera Cluster Known Limitations.
