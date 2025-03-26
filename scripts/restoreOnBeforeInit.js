import org.json.JSONObject;
var storage_unavailable_markup = "";
var storageInfo = getStorageNodeid();
var storageEnvDomain = storageInfo.storageEnvShortName;
var storageEnvMasterId = storageInfo.storageNodeId;
var checkSchemaCommand = "if grep -q '^SCHEME=' /.jelenv; then echo true; else echo false; fi";
var computeTypeCommand = "grep 'COMPUTE_TYPE=' /etc/jelastic/metainf.conf | cut -d'=' -f2";
var mysql_cluster_markup = "Be careful when restoring the dump from another DB environment (or environment with another replication schema) to the replicated MySQL/MariaDB/Percona solution.";
var recovery_addon_markup = "Please use Database Corruption Diagnostic add-on for check after restore, and Database Recovery Add-on for fix if it is needed.";

var checkSchema = api.env.control.ExecCmdById("${env.name}", session, ${targetNodes.master.id}, toJSON([{"command": checkSchemaCommand, "params": ""}]), false, "root");
if (checkSchema.result != 0) return checkSchema;
var computeTypeResp = api.env.control.ExecCmdById("${env.name}", session, ${targetNodes.master.id}, toJSON([{"command": computeTypeCommand, "params": ""}]), false, "root");
if (computeTypeResp.result != 0) return computeTypeResp;
var computeType = computeTypeResp.responses[0].out.trim();

resp = jelastic.env.control.GetEnvInfo(storageEnvDomain, session);
if (resp.result != 0 && resp.result != 11) return resp;
if (resp.result == 11) {
    storage_unavailable_markup = "Storage environment " + "${settings.storageName}" + " is deleted.";
} else if (resp.env.status == 1) {
    var baseUrl = jps.baseUrl;
    var updateResticOnStorageCommand = "wget --tries=10 -O /tmp/installUpdateRestic " + baseUrl + "/scripts/installUpdateRestic && mv -f /tmp/installUpdateRestic /usr/sbin/installUpdateRestic && chmod +x /usr/sbin/installUpdateRestic && /usr/sbin/installUpdateRestic";
    var respUpdate = api.env.control.ExecCmdById(storageEnvDomain, session, storageEnvMasterId, toJSON([{"command": updateResticOnStorageCommand, "params": ""}]), false, "root");
    if (respUpdate.result != 0) return respUpdate;
    var getBackupsAllEnvs = "wget --tries=10 -O /root/getBackupsAllEnvsJSON.sh " + baseUrl + "/scripts/getBackupsAllEnvsJSON.sh && chmod +x /root/getBackupsAllEnvsJSON.sh && /root/getBackupsAllEnvsJSON.sh";
    var backups = jelastic.env.control.ExecCmdById(storageEnvDomain, session, storageEnvMasterId, toJSON([{"command": getBackupsAllEnvs, "params": ""}]), false, "root").responses[0].out;
    var backupList = toNative(new JSONObject(String(backups)));

    var filteredEnvs = [];
    var filteredBackups = {};
    var filteredPitrEnvs = [];
    var filteredPitrStartTime = {};
    
    for (var env in backupList.envs) {
        if (backupList.envs.hasOwnProperty(env)) {
            var backupInfo = backupList.envs[env];

            if (backupInfo.server == computeType) {
                filteredEnvs.push({ caption: env, value: env });

                filteredBackups[env] = backupInfo.backups.map(function(backup) {
                    return { caption: backup, value: backup };
                });
                
                if (backupInfo.pitr === true) {
                  filteredPitrEnvs.push({ caption: env, value: env });
                  filteredPitrStartTime[env] = [{ caption: backupInfo.pitrStartTime, value: backupInfo.pitrStartTime }];
                }
            }
        }
    }
} else {
    storage_unavailable_markup = "Storage environment " + storageEnvDomain + " is unavailable (stopped/sleeping).";
}

function getStorageNodeid(){
    var storageEnv = '${settings.storageName}'
    var storageEnvShortName = storageEnv.split(".")[0]
    var resp = jelastic.environment.control.GetEnvInfo(storageEnvShortName, session)
    if (resp.result != 0) return resp
    for (var i = 0; resp.nodes; i++) {
        var node = resp.nodes[i]
        if (node.nodeGroup == 'storage' && node.ismaster) {
            return { result: 0, storageNodeId: node.id, storageEnvShortName: storageEnvShortName };
        }
    }
}

if (storage_unavailable_markup === "") {
    if ('${settings.isPitr}' == 'true') {
        settings.fields.push({
            "type": "toggle",
            "name": "isPitr",
            "caption": "PITR",
            "tooltip": "Point in time recovery",
            "value": true,
            "hidden": false,
            "showIf": {
              "true": [
               {
                    "caption": "Restore from",
                    "type": "list",
                    "name": "backupedEnvName",
                    "required": true,
                    "values": filteredPitrEnvs,
                    "default": filteredPitrEnvs[0],
                    "tooltip": "Select the environment to restore from"
                }, {
                    "caption": "PITR Start Time",
                    "type": "list",
                    "name": "pitrStartTime",
                    "required": true,
                    "tooltip": "PITR Start Time",
                    "dependsOn": {
                       "backupedEnvName" : filteredPitrStartTime
                    }
                }, {
                    "caption": "Time for restore",
                    "type": "string",
                    "name": "restoreTime",
                    "inputType": "datetime-local",
                    "cls": "x-form-text",
                    "required": true,
                    "tooltip": "Select specific date and time for point-in-time recovery"
                }
              ],
              "false": [
               {
                    "caption": "Restore from",
                    "type": "list",
                    "name": "backupedEnvName",
                    "required": true,
                    "default": filteredEnvs[0],
                    "values": filteredEnvs
                }, {
                    "caption": "Backup",
                    "type": "list",
                    "name": "backupDir",
                    "required": true,
                    "tooltip": "Select the time stamp for which you want to restore the DB dump",
                    "dependsOn": {
                        "backupedEnvName" : filteredBackups
                    }
                }
              ]
            }
        });
        if (checkSchema.responses[0].out == "true") {
            settings.fields.push(
                {"type": "displayfield", "cls": "warning", "height": 30, "hideLabel": true, "markup": mysql_cluster_markup}
            );
            settings.fields.push(
                {"type": "displayfield", "cls": "warning", "height": 30, "hideLabel": true, "markup": recovery_addon_markup}
            );
        }
    } else {
        settings.fields.push({
            "caption": "Restore from",
            "type": "list",
            "name": "backupedEnvName",
            "required": true,
            "default": filteredEnvs[0],
            "values": filteredEnvs
        }, {
            "caption": "Backup",
            "type": "list",
            "name": "backupDir",
            "required": true,
            "tooltip": "Select the time stamp for which you want to restore the DB dump",
            "dependsOn": {
                "backupedEnvName" : filteredBackups
            }
        });
        if (checkSchema.responses[0].out == "true") {
            settings.fields.push(
                {"type": "displayfield", "cls": "warning", "height": 30, "hideLabel": true, "markup": mysql_cluster_markup}
            );
            settings.fields.push(
                {"type": "displayfield", "cls": "warning", "height": 30, "hideLabel": true, "markup": recovery_addon_markup}
            );
        }
    }
} else {
    settings.fields.push(
        {"type": "displayfield", "cls": "warning", "height": 30, "hideLabel": true, "markup": storage_unavailable_markup}
    )
}

return settings;
