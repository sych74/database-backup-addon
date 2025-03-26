var respOut;
var pitr_conf_error_markup = "Database doesnt configured for PITR support. Please push apply for automatic configuring or close and manually configure acording to instruction and reinstall addon";
var pitr_conf_success_markup = "Database configured for PITR support";
var recovery_addon_markup = "Please use Database Corruption Diagnostic add-on for check after restore, and Database Recovery Add-on for fix if it is needed.";

var checkPitrCmd = "wget " + '${baseUrl}' + "/scripts/pitr.sh -O /root/pitr.sh &>> /var/log/run.log; bash /root/pitr.sh checkPitr " + '${settings.dbuser}' + " " + '${settings.dbpass}';
resp = jelastic.env.control.ExecCmdById('${env.envName}', session, '${nodes.sqldb.master.id}', toJSON([{ command: checkPitrCmd }]), true, "root");
if (resp.result != 0) return resp;
respOut = resp.responses[0].out;
respOut = JSON.parse(respOut);
if (respOut.result == 702) {
  settings.fields.push({
    caption: "PITR",
    type: "toggle",
    name: "isPitr",
    tooltip: "Point in time recovery",
    values: false,
    hidden:  false,
    disabled: true
  }, {
    type: "displayfield",
    cls: "warning",
    height: 30,
    hideLabel: true,
    markup: pitr_conf_error_markup
  });        
} else {
  settings.fields.push({
    caption: "PITR",
    type: "toggle",
    name: "isPitr",
    tooltip: "Point in time recovery",
    values: false,
    hidden:  false,
    disabled: false
  }, {
    type: "displayfield",
    cls: "success",
    height: 30,
    hideLabel: true,
    markup: pitr_conf_success_markup
  });
}
return settings;

