#!/bin/bash
### Author: Oliver Schmidt 12.12.2011
### /sps/app64/InformaticaV8/server/bin/
#
# Backup of objects from informatica repository
# Workflow is the highest hierarchical Level --> backup from top down through hierarchy
# use it at own risk ! i am not responsible for any damage or errors caused by this script !

clear
echo "[INFA_EXPORT] - oneClick Informatica Repository 2 XML Exporter - based on FOLDER->Workflow"
echo "[Author] - Oliver Schmidt -- Date: 12.12.2011"

### ermittle Arbeitsverzeichnis
WORKING_DIR=`pwd`
INFA_DIR="/sps/app64/InformaticaV8/server/bin/"

### Connection-Log (löschen wenn bereits vorhanden !)
c_LOG='infa_connect.std'
if [ -f ${c_LOG} ]; then rm ${c_LOG}; fi

### Export Log (löschen wenn Vorhanden !)
LOGDIR='log'
if [ ! -d ${LOGDIR} ];
then mkdir ${LOGDIR};
else rmdir -R ${LOGDIR};
mkdir ${LOGDIR};
fi

### prüfe ob ExportVerzeichnis existiert -> ja -> lösche und lege es neu an, nein -> lege an
EXPORTDIR='XML-Export'
if [ ! -d ${EXPORTDIR} ];
then mkdir ${EXPORTDIR};
else rmdir -R ${EXPORTDIR};
mkdir ${EXPORTDIR};
fi

echo " "
echo "Please provide your repository username (case sensitive):";
read REPUSER;
echo "Enter your password:"
stty -echo
read PASSWORD
stty echo;
echo "Enter Repository Name: (e.g. PM_PROD_REPO)"
read REP_NAME
echo "Enter Name of Prod_Domain: (e.g. Prod_Domain)"
read PROD_DOMAIN;
echo " "
echo "[Status] - Verbinde mit Repository ..."

### Connect 2 InfaRepository
${INFA_DIR}/pmrep connect -r ${REP_NAME} -d ${PROD_DOMAIN} -n ${REPUSER} -x ${PASSWORD} > ${WORKING_DIR}/${c_LOG}
MESSAGE_f=`cat infa_connect.std | grep Failed`
MESSAGE_s=`cat infa_connect.std | grep onnected`
echo $MESSAGE
if echo "$MESSAGE_f" | grep -q "Failed"
then
echo "[Fehler] - $MESSAGE_f";
echo "exiting ..";
exit
else
echo "[Status] - $MESSAGE_s";
fi
echo " "

### ${INFA_DIR}/pmrep showconnectioninfo

#cd ${EXPORTDIR}

c_FOLDER=0
c_OBJ=0

INFA_FOLDER=`${INFA_DIR}/pmrep listobjects -o folder -r fueri4evar -l gxgcvvdt | grep fueri4evar | sed 's/fueri4evar/\n/g' | grep -v gxgcvvdt`
##INFA_FOLDER="DataWareHouse"
for FOLDER in ${INFA_FOLDER}; do
cd ${EXPORTDIR}
echo "[EXPORT - INFO]: Verarbeite Folder - ${FOLDER}"
let c_FOLDER=c_FOLDER+1
if [ ! -d ${FOLDER} ]; then mkdir ${FOLDER}; fi
cd ..
### get list of all workflows in Folder
WORKFLOWS=`${INFA_DIR}/pmrep listobjects -o workflow -f ${FOLDER} | grep workflow | sed 's/workflow//g'`
for WORKFLOW in ${WORKFLOWS}; do
echo "[EXPORT - INFO]: Verarbeite Workflow - ${WORKFLOW}"
let c_OBJ=c_OBJ+1
### export single Workflow
${INFA_DIR}/pmrep objectexport -o workflow -f ${FOLDER} -n ${WORKFLOW} -m -s -b -r -u ${WORKING_DIR}/${EXPORTDIR}/${FOLDER}/${WORKFLOW}.xml > ${LOGDIR}/${WORKFLOW}.log 2 > /dev/null
done
done

cd ${WORKING_DIR}

if [${c_OBJ} = 0]; then echo "[FEHLER] - Es wurden keine Objekte aus dem gewählten Repository exportiert! (${c_OBJ})"; rmdir -R ${EXPORTDIR}; exit; fi

echo "[EXPORT - SUMMARY] - ${c_OBJ} Objekte in ${c_FOLDER} Ordnern (Folders) erfolgreich exportiert. ExportLogs sind im Verzeichnis /log abgelegt !"

### for Security Reasons - remove saved connection-information
rm pmrep.cnx

exit 0
