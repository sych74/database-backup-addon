# Restore Galera Cluster from Database Dump

When manually restoring a database dump for the Galera cluster, it is essential to consider the **[MariaDB Galera Cluster - Known Limitations](https://mariadb.com/kb/en/mariadb-galera-cluster-known-limitations/)**.

> **Note:** No extra actions are required when working with the **Backup/Restore** add-on, all the relevant limitations are already considered. The instructions below are for the manual database dump restoration process only.

## Key Considerations

- **Only *InnoDB* tables** are replicated across nodes, while tables that use other storage engines are not. The most common examples are the *mysql.\** tables which typically use the *Aria* or *MyISAM* engines. Ensure you manually synchronize such tables across nodes if required.
- Be aware of the **cluster downtime** during the dump restoration process and plan accordingly to minimize the impact on applications relying on the database.
- Ensure that the **State Snapshot Transfer (SST)** method is configured for your cluster to provide a full data copy to the new nodes  (e.g., *xtrabackup* or *rsync*).

## Manual Restoration Steps

Follow the steps below to restore your Galera cluster from a database dump and ensure all nodes are correctly synchronized:

1\. Upload the database dump to the **/tmp/** directory to the master (first) node of the Galera cluster. For example, you can use:

- [built-in file manager](https://www.virtuozzo.com/application-platform-docs/configuration-file-manager/)

![file manager](/images/manual-galera-restoration/01-file-manager.png)

- [SFTP/SSH connection](https://www.virtuozzo.com/application-platform-docs/ssh-protocols/)

![SFTP connection](/images/manual-galera-restoration/02-sftp-connection.png)

- [FTP add-on](https://www.virtuozzo.com/application-platform-docs/ftp-ftps-support/)

![FTP add-on](/images/manual-galera-restoration/03-ftp-addon.png)

2\. Perform the following operations on **all non-master nodes**:

- Connect [via SSH](https://www.virtuozzo.com/application-platform-docs/ssh-access-overview/).
- Stop the MariaDB service.
- Delete the ***/var/lib/mysql/grastate.dat*** Galera state file. It will initiate a full state transfer (SST) upon service restart.

```
sudo jem service stop
rm /var/lib/mysql/grastate.dat
```

![Web SSH access](/images/manual-galera-restoration/04-web-ssh-access.png)

3\. Restore the dump on the first node by running the following command (provide the correct database credentials and dump file name):

```
mysql -u <username> -p <password> < /tmp/db_backup.sql
```

Alternatively, you can use tools like **phpMyAdmin** to perform an interactive restoration.

4\. Start the MariaDB services on the non-master nodes:

```
sudo jem service start
```

A full SST will be initiated upon the node rejoining the cluster, synchronizing all data including non-InnoDB tables.
