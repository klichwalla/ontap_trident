#!/bin/sh

### Description:
### This script will execute a snapmirror release via API for an Astra Trident managed persistent volume
### utilizing the ONTAP REST API
### 
### Author: Kevin Lichwalla
###
### Repository: https://github.com/klichwalla/ontap_trident
### 
### Change History
### 9/16/2022 - Initial version

### USER DEFINED
k8scmd=oc 			# oc, kubectl, etc.
NAMESPACE=trident   # namespace where trident is installed


###
if [[ -z $1 ]] ; then
        echo -e "ERROR: Persistent Volume Name parameter required"
        echo -e "       Example: $0 pvc-7b08c48d-7e1c-4462-813d-d07dd39376af"
        exit
fi

PVC=$1

echo "INFO: Checking $PVC for SnapMirror cleanup"

# oc get tridentvolume -n trident -o jsonpath="{.items[?(@.config.name=='pvc-dc7cd60f-f2ed-400b-b4ff-daf2b11e7362')].config.internalName}"
# oc get tridentvolume -n trident -o jsonpath="{.items[?(@.config.name=='pvc-dc7cd60f-f2ed-400b-b4ff-daf2b11e7362')].backendUUID}"

# query the tridentvolume crd detail to get the associated backend
BACKEND=`$k8scmd get tridentvolume -n ${NAMESPACE} -o jsonpath="{.items[?(@.config.name=='${PVC}')].backendUUID}"`
VOLUME=`$k8scmd get tridentvolume -n $NAMESPACE -o jsonpath="{.items[?(@.config.name=='${PVC}')].config.internalName}"`

if [[ ! -z $BACKEND ]] ; then
        echo -e "INFO: Found backend $BACKEND for $PVC"
else
        echo -e "ERROR: No trident information found for $PVC"
        exit
fi

if [[ ! -z $VOLUME ]] ; then
        echo -e "INFO: Found ONTAP volume $VOLUME for $PVC"
else
        echo -e "ERROR: No ONTAP volume found for $PVC"
fi


# get the SVM management address and credentials from the crd and secret
SVMMGMT=`$k8scmd get tbe -n $NAMESPACE -o jsonpath="{.items[?(@.backendUUID=='${BACKEND}')].config.ontap_config.managementLIF}"`
SVMNAME=`$k8scmd get tbe -n $NAMESPACE -o jsonpath="{.items[?(@.backendUUID=='${BACKEND}')].config.ontap_config.svm}"`
SECRET=`$k8scmd get tbe  -n $NAMESPACE -o jsonpath="{.items[?(@.backendUUID=='${BACKEND}')].config.ontap_config.username}" | cut -d ":" -f2`

if [[ ! -z $SVMMGMT ]] ; then
        echo -e "INFO: Found SVM management address $SVMMGMT for backend $BACKEND"
else
        echo -e "ERROR: Unable to find SVM managemetn address for backend $BACKEND"
fi

if [[ ! -z $SECRET ]] ; then
        echo -e "INFO: Found k8s secret $SECRET for backend $BACKEND"
else
        echo -e "ERROR: No k8s secret found for backend $BACKEND"
fi

# get the username
SVMUSER=`$k8scmd get secret $SECRET -n $NAMESPACE -o jsonpath="{.data.Username}" | base64 --decode`
SVMPASS=`$k8scmd get secret $SECRET -n $NAMESPACE -o jsonpath="{.data.Password}" | base64 --decode`

if [[ ! -z $SVMUSER ]]; then
        echo -e "INFO: Found SVM username"
else
        echo -e "ERROR: No SVM username found"
        exit
fi

if [[ ! -z $SVMPASS ]]; then
        echo -e "INFO: Found SVM credential"
else
        echo -e "ERROR: No SVM credential found"
        exit
fi

#sshpass -p $SVMPASS ssh -l $SVMUSER $SVMMGMT snapmirror list-destinations -source-path ${SVMNAME}:${VOLUME}
echo -e "INFO: Checking Snapmirror destinations for ${SVMNAME}:${VOLUME}"
echo -e "INFO: Executing REST call to $SVMMGMT"


SNAPMIRRORDEST=`curl -s -S -k -u ${SVMUSER}:${SVMPASS} -X GET "https://${SVMMGMT}/api/snapmirror/relationships?list_destinations_only=true&source.path=${SVMNAME}%3A${VOLUME}&return_records=true&return_timeout=15" -H "accept: application/json"`

SNAPMIRRORDESTCOUNT=`echo $SNAPMIRRORDEST | jq -j '.num_records'`

if [[ $SNAPMIRRORDESTCOUNT -eq 0 ]] ; then
        echo -e "WARNING: No SnapMirror relationships to release, exiting"
        exit
elif [[ $SNAPMIRRORDESTCOUNT -eq 1 ]] ; then
        echo -e "INFO: Found $SNAPMIRRORDESTCOUNT SnapMirror relationships"
        # { "records": [ { "uuid": "280ae167-33a1-11ed-a9f9-90e2ba9be1cc", "source": { "path": "ocp2:dev_pvc_dc7cd60f_f2ed_400b_b4ff_daf2b11e7362", "svm": { "name": "ocp2" } }, "destination": {"path": "ocp1:dp_dev_pvc_dc7cd60f_f2ed_400b_b4ff_daf2b11e7362", "svm": { "name": "ocp1" } } } ], "num_records": 1 }
        SNAPMIRRORUUID=`echo $SNAPMIRRORDEST | jq -j '.records[0].uuid'`
        SOURCEPATH=`echo $SNAPMIRRORDEST | jq -j '.records[0].source.path'`
        DESTPATH=`echo $SNAPMIRRORDEST | jq -j '.records[0].destination.path'`
        echo -e "INFO: Releasing SnapMirror destinations for SnapMirror relationship $SNAPMIRRORUUID"
        echo -e "INFO: $SOURCEPATH -> $DESTPATH"
        # echo -e $SNAPMIRRORDEST

        echo -e "INFO: Executing REST call to $SVMMGMT"
        SNAPMIRRORRELEASE=`curl -s -S -k -u ${SVMUSER}:${SVMPASS} -X DELETE "https://${SVMMGMT}/api/snapmirror/relationships/${SNAPMIRRORUUID}/?source_only=true&return_timeout=60"`

        ### monitor ONTAP job for status
        JOBCOMPLETE=NO
        declare -i RETRYCOUNT=0  # will retry 30 times at 10 seconds, 5 minutes
        until [[ $JOBCOMPLETE == "success" ]] || [[ $JOBCOMPLETE == "failure" ]] || [[ RETRYCOUNT -gt 30 ]]
        do
                        # sample api responses
                        #{ "job": { "uuid": "f6f4ca60-35fa-11ed-a9f9-90e2ba9be1cc", "_links": { "self": { "href": "/api/cluster/jobs/f6f4ca60-35fa-11ed-a9f9-90e2ba9be1cc" } } } }
                        #curl -k -u vsadmin:netapp123 -X GET "https://10.26.133.223//api/cluster/jobs/f6f4ca60-35fa-11ed-a9f9-90e2ba9be1cc" -H "accept: application/json"
                        #{
                        #  "uuid": "f6f4ca60-35fa-11ed-a9f9-90e2ba9be1cc",
                        #  "description": "DELETE /api/snapmirror/relationships/05dfb5b8-3390-11ed-a9f9-90e2ba9be1cc/",
                        #  "state": "success",
                        #  "message": "success",
                        #  "code": 0,
                        #  "start_time": "2022-09-16T14:05:51-06:00",
                        #  "end_time": "2022-09-16T14:05:54-06:00",
                        #  "svm": {
                        #    "name": "ocp2",
                        #    "uuid": "affdff96-5e8c-11ec-b28b-90e2ba9be1cc"
                        #  }
                        #}

                JOBUUID=`echo $SNAPMIRRORRELEASE | jq -j '.job.uuid'`
                JOBSTATUS=`curl -s -S -k -u ${SVMUSER}:${SVMPASS} -X GET "https://${SVMMGMT}/api/cluster/jobs/${JOBUUID}" -H "accept: application/json"`
                JOBCOMPLETE=`echo $JOBSTATUS | jq -j '.state'`
                echo -e "INFO: Job State - $JOBCOMPLETE, Retry Count ${RETRYCOUNT}/30"

                # only wait if we have to
                if [[ $JOBCOMPLETE != "success" ]] || [[ $JOBCOMPLETE == "failure" ]] ; then
                        sleep 10s
                        RETRYCOUNT+=1
                fi
        done

        if [[ $JOBCOMPLETE == "success" ]] ; then
                echo -e "SUCCESS: SnapMirror release for $PVC complete"
        else
                echo -e "ERROR: SnapMirror release for $PVC exited in status $JOBCOMPLETE"
                echo -e "$SNAPMIRRORRELEASE"
                exit
        fi
else
        echo -e "ERROR: More than 1 SnapMirror destination found - $SNAPMIRRORDESTCOUNT SnapMirror relationships identified"
        echo -e "       Manual cleanup required"
        exit
fi
## EOF
