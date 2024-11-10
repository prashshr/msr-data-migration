#!/bin/bash

# Directories for logs and files
LOG_DIR="msr-migration-logs"
FILE_DIR="msr-migration-files"
mkdir -p $LOG_DIR $FILE_DIR

# Log file with date and time
LOG_FILE="$LOG_DIR/migration_msr_data_$(date +'%Y-%m-%d_%H-%M-%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1


# Set default paths if environment variables are not provided
ENV_FILE=${ENV_FILE:-.msr_data_migration.env}
KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
TOKEN_LIMIT=${TOKEN_LIMIT:-100}
DEST_MSR_K8S_NAMESPACE=${DEST_MSR_K8S_NAMESPACE:-default}


echo -e "Using the environment variables file $ENV_FILE\n"

setupEnv() {

    if [ ! -f $ENV_FILE ]; then

        echo "Cannot find the environment variables file $ENV_FILE"

        echo; echo "Requirements:
        - Passwordless SSH access to source MKE and DTR nodes.
        - Destination K8s environment kubeconfig.
        - Username/password/token to access source and destination MSRs.
        - A running rethinkdb-cli pod on destination MSR.
        "

        # read -p "Hostname/IP of source UCP/MKE node (any one manager node eg. node-manager-1): " MKE_NODE
        # echo $MKE_NODE > .metadata.id
        # read -p "Hostname/IP of a source DTR/MSR node (any one DTR node eg. source-dtr-node-1): " SOURCE_MSR_NODE
        # echo $SOURCE_MSR_NODE >> .metadata.id
        # REPLICA_ID=$(ssh -o StrictHostKeyChecking=no -i ${SOURCE_MSR_SSH_KEY} ${SOURCE_MSR_SSH_USER}@${SOURCE_MSR_NODE} 'sudo  docker inspect -f "{{.Name}}" $(sudo  docker ps -q -f name=dtr-rethink)' | awk -F- '{print $3}')
        # echo $REPLICA_ID >> .metadata.id
        # read -p "URL of the source DTR/MSR: " SOURCE_MSR_URL
        # echo $SOURCE_MSR_URL >> .metadata.id
        # read -p "URL of the destination DTR/MSR: " DEST_MSR_URL
        # echo $DEST_MSR_URL >> .metadata.id
        # echo -e "\nAdded the metadata for the script"

        # #ssh -o StrictHostKeyChecking=no -i ${SOURCE_MSR_SSH_KEY} ${SOURCE_MSR_SSH_USER}@${SOURCE_MSR_NODE} "echo 'r.db(\"dtr2\").table(\"repositories\")' | sudo  docker run --rm -i --net dtr-ol -v \"dtr-ca-${REPLICA_ID}:/ca\" -e DTR_REPLICA_ID=$REPLICA_ID mirantis/rethinkcli:v2.2.0-ni non-interactive" > $FILE_DIR/repositories.json
        # #echo "Creating the repository file..."
        # #ssh -o StrictHostKeyChecking=no -i ${SOURCE_MSR_SSH_KEY} ${SSH_SOURCE_MSR_SSH_USERUSER}@${SOURCE_MSR_NODE} "echo 'r.db(\"dtr2\").table(\"tags\")' | sudo  docker run --rm -i --net dtr-ol -v \"dtr-ca-${REPLICA_ID}:/ca\" -e DTR_REPLICA_ID=$REPLICA_ID mirantis/rethinkcli:v2.2.0-ni non-interactive" > $FILE_DIR/tags.json
        # #echo "Creating the tags file..."
        # echo "Environment setup completed. Please use -h for the usage of the script!"

        echo -e "Example: '.msr_data_migration.env'\n
        KUBECONFIG=$HOME/.kube/config

        # Source cluster variables
        MKE_NODE=1.2.3.4
        MKE_NODE_SSH_KEY=$HOME/.ssh/id_rsa
        MKE_NODE_SSH_USER=ubuntu

        SOURCE_MSR_NODE=1.2.3.5
        SOURCE_MSR_SSH_KEY=$HOME/.ssh/id_rsa
        SOURCE_MSR_SSH_USER=ubuntu

        SOURCE_MSR_USERNAME=migration_user
        SOURCE_MSR_TOKEN=xxxxxxxxxx-xxxx-xxxx-807e-xxxxxxxxxx
        SOURCE_MSR_URL=source.msr.example.com

        # Destination cluster variables
        DEST_MSR_URL=destination.msr.example.com:34034
        DEST_MSR_USERNAME=migration_user
        DEST_MSR_TOKEN=xxxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx

        DEST_MSR_K8S_NAMESPACE=default

        PARALLEL_PROCESS_COUNT=5 (default 5)
        TOKEN_LIMIT=50 (default 50)
        "
        exit
    fi

    # Source environment variables from $ENV_FILE file
    source $ENV_FILE

    # Required environment variables
    REQUIRED_VARS=(
        KUBECONFIG
        MKE_NODE
        MKE_NODE_SSH_KEY
        MKE_NODE_SSH_USER
        SOURCE_MSR_NODE
        SOURCE_MSR_SSH_KEY
        SOURCE_MSR_SSH_USER
        SOURCE_MSR_URL
        DEST_MSR_URL
        SOURCE_MSR_USERNAME
        DEST_MSR_USERNAME
        SOURCE_MSR_TOKEN
        DEST_MSR_TOKEN
        DEST_MSR_K8S_NAMESPACE
        PARALLEL_PROCESS_COUNT
        TOKEN_LIMIT
    )

    # Array to store missing variables
    MISSING_VARS=()

    # Check each required variable and add missing ones to MISSING_VARS array
    for var in "${REQUIRED_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            MISSING_VARS+=("$var")
        fi
    done

    # If there are any missing variables, print them and exit
    if [ ${#MISSING_VARS[@]} -ne 0 ]; then
        echo "Error: The following required environment variables are not set:"
        for var in "${MISSING_VARS[@]}"; do
            echo "  - $var"
        done
        exit 1
    fi

    # Determining source DTR REPLICA_ID
    REPLICA_ID=$(ssh -o StrictHostKeyChecking=no -i ${SOURCE_MSR_SSH_KEY} ${SOURCE_MSR_SSH_USER}@${SOURCE_MSR_NODE} 'sudo  docker inspect -f "{{.Name}}" $(sudo  docker ps -q -f name=dtr-rethink)' | awk -F- '{print $3}')
    #echo "Determining source DTR REPLICA_ID: $REPLICA_ID"

    # Check if POD_NAME is set
    POD_NAME=$(kubectl get pod -l app.kubernetes.io/name=rethinkdb -l app.kubernetes.io/component=cli -o=name -A | awk -F"/" '{print $2}')
    if [ -z "$POD_NAME" ]; then
        echo "rethinkdb cli POD_NAME at the destination msr is not set. Please check your Kubernetes setup."
        exit 1
    fi
}


function migtationFiles() {
    setupEnv

    echo "====== Stage 1: Generating Migration Files ======"

    # Log the directories used
    echo "Log Directory: $LOG_DIR"
    echo "File Directory: $FILE_DIR"
    
    export DB_ADDR=$(ssh -o StrictHostKeyChecking=no -i ${MKE_NODE_SSH_KEY} ${MKE_NODE_SSH_USER}@${MKE_NODE} "sudo  docker info --format '{{.Swarm.NodeAddr}}'")
    echo "Database Address for Source Cluster: $DB_ADDR"

    # Define filenames and generate files
    declare -A files=(
        ["accounts.json"]="Accounts and user details"
        ["org_membership.json"]="Organization memberships"
        ["teams.json"]="Team definitions"
        ["client_tokens.json"]="User tokens"
        ["team_membership.json"]="Team memberships"
        ["repository_team_access.json"]="Repository team access mappings"
        ["repositories.json"]="Repository definitions"
        ["tags.json"]="Repository tags"
    )

    for file in "${!files[@]}"; do
        description="${files[$file]}"
        echo "Generating $file ($description)..."
    done

    ssh -o StrictHostKeyChecking=no -i ${MKE_NODE_SSH_KEY} ${MKE_NODE_SSH_USER}@${MKE_NODE} "echo 'r.db(\"enzi\").table(\"accounts\")' | sudo  docker run --rm -i -e DB_ADDRESS=${DB_ADDR} -v ucp-auth-api-certs:/tls squizzi/rethinkcli-ucp non-interactive" > "$FILE_DIR/accounts.json"
    ssh -o StrictHostKeyChecking=no -i ${MKE_NODE_SSH_KEY} ${MKE_NODE_SSH_USER}@${MKE_NODE} "echo 'r.db(\"enzi\").table(\"org_membership\")' | sudo  docker run --rm -i -e DB_ADDRESS=${DB_ADDR} -v ucp-auth-api-certs:/tls squizzi/rethinkcli-ucp non-interactive" > "$FILE_DIR/org_membership.json"
    ssh -o StrictHostKeyChecking=no -i ${MKE_NODE_SSH_KEY} ${MKE_NODE_SSH_USER}@${MKE_NODE} "echo 'r.db(\"enzi\").table(\"teams\")' | sudo  docker run --rm -i -e DB_ADDRESS=${DB_ADDR} -v ucp-auth-api-certs:/tls squizzi/rethinkcli-ucp non-interactive" > "$FILE_DIR/teams.json"
    ssh -o StrictHostKeyChecking=no -i ${SOURCE_MSR_SSH_KEY} ${SOURCE_MSR_SSH_USER}@${SOURCE_MSR_NODE} "echo 'r.db(\"dtr2\").table(\"client_tokens\")' | sudo  docker run --rm -i --net dtr-ol -v \"dtr-ca-${REPLICA_ID}:/ca\" -e DTR_REPLICA_ID=$REPLICA_ID mirantis/rethinkcli:v2.2.0-ni non-interactive" > "$FILE_DIR/client_tokens.json"
    ssh -o StrictHostKeyChecking=no -i ${MKE_NODE_SSH_KEY} ${MKE_NODE_SSH_USER}@${MKE_NODE} "echo 'r.db(\"enzi\").table(\"team_membership\")' | sudo  docker run --rm -i -e DB_ADDRESS=${DB_ADDR} -v ucp-auth-api-certs:/tls squizzi/rethinkcli-ucp non-interactive" > "$FILE_DIR/team_membership.json"
    ssh -o StrictHostKeyChecking=no -i ${SOURCE_MSR_SSH_KEY} ${SOURCE_MSR_SSH_USER}@${SOURCE_MSR_NODE} "echo 'r.db(\"dtr2\").table(\"repository_team_access\")' | sudo  docker run --rm -i --net dtr-ol -v \"dtr-ca-${REPLICA_ID}:/ca\" -e DTR_REPLICA_ID=$REPLICA_ID mirantis/rethinkcli:v2.2.0-ni non-interactive" > "$FILE_DIR/repository_team_access.json"
    ssh -o StrictHostKeyChecking=no -i ${SOURCE_MSR_SSH_KEY} ${SOURCE_MSR_SSH_USER}@${SOURCE_MSR_NODE} "echo 'r.db(\"dtr2\").table(\"repositories\")' | sudo  docker run --rm -i --net dtr-ol -v \"dtr-ca-${REPLICA_ID}:/ca\" -e DTR_REPLICA_ID=$REPLICA_ID mirantis/rethinkcli:v2.2.0-ni non-interactive" > "$FILE_DIR/repositories.json"
    echo "Generated $FILE_DIR/repositories.json (Repository definitions)."
    ssh -o StrictHostKeyChecking=no -i ${SOURCE_MSR_SSH_KEY} ${SOURCE_MSR_SSH_USER}@${SOURCE_MSR_NODE} "echo 'r.db(\"dtr2\").table(\"tags\")' | sudo  docker run --rm -i --net dtr-ol -v \"dtr-ca-${REPLICA_ID}:/ca\" -e DTR_REPLICA_ID=$REPLICA_ID mirantis/rethinkcli:v2.2.0-ni non-interactive" > "$FILE_DIR/tags.json"
    echo "Generated $FILE_DIR/tags.json (Repository tags)."
    jq -r .[].pk $FILE_DIR/tags.json > $FILE_DIR/tags.txt

    # List files created
    echo "====== Migration Files Generated Successfully ======"
    for file in "${!files[@]}"; do
        if [ -f "$FILE_DIR/$file" ]; then
            echo "  - $file (${files[$file]}) at $FILE_DIR/$file"
        else
            echo "  - $file (${files[$file]}) was not generated. Check the logs for errors."
        fi
    done
}


function migrateAccounts() {

    setupEnv

    # Process accounts and tokens
    #ACCOUNTS_UNFORMATTED=$(jq '.[] | select(.name!="admin1" and .name!="docker-datacenter" and .isOrg==false) | del(.accountLock.lockedTime)' $FILE_DIR/accounts.json | jq -s)
    ACCOUNTS_UNFORMATTED=$(jq '.[] | select(.isOrg==false) | del(.accountLock.lockedTime)' $FILE_DIR/accounts.json | jq -s)
    PRD_ORGS_UNFORMATTED=$(jq '.[] | select(.isOrg==true) | del(.accountLock.lockedTime)' $FILE_DIR/accounts.json | jq -s)

    ACCOUNTS=$(echo "$ACCOUNTS_UNFORMATTED" | jq -r '.[].id')
    PRD_ORGS=$(echo "$PRD_ORGS_UNFORMATTED" | jq -r '.[].id')

    # Prepare client tokens
    #jq '.[].lastUsed = ""' $FILE_DIR/client_tokens.json > $FILE_DIR/temp.json
    #jq '.[].createdAt = ""' $FILE_DIR/temp.json > $FILE_DIR/client_tokens.json && rm -rf $FILE_DIR/temp.json

    jq '.[] | del(.createdAt,.lastUsed)' $FILE_DIR/client_tokens.json | jq -s '.' > $FILE_DIR/temp.json
    mv $FILE_DIR/temp.json $FILE_DIR/client_tokens.json

    echo "====== Stage 2: Creating the accounts and adding their corresponding user tokens ======"

    # Process accounts and user tokens in parallel
    echo "$ACCOUNTS" | tr ' ' '\n' | parallel -j $PARALLEL_PROCESS_COUNT --no-notice --tag '
        USER_ID={}
        USER_JSON=$(jq ".[] | select(.id==\"$USER_ID\") | del(.accountLock.lockedTime)" '"$FILE_DIR"'/accounts.json | jq -s)

        # Check if USER_JSON is empty
        if [ -z "$USER_JSON" ]; then
            echo "No user found for ID $USER_ID. Skipping..."
            exit 0
        fi

        echo -e "\n===== Adding the user $(echo "$USER_JSON" | jq -r .[].name) ====="

        #echo "kubectl exec -n '"$DEST_MSR_K8S_NAMESPACE"' '"$POD_NAME"' ... insert ... "$USER_JSON""
        #kubectl exec -n '"$DEST_MSR_K8S_NAMESPACE"' '"$POD_NAME"' -- node --no-deprecation rethinkdb.js "r.db(\"enzi\").table(\"accounts\").insert($USER_JSON)"



	# Logic to force overwrite for the user "admin"
        USER_NAME=$(echo "$USER_JSON" | jq -r ".[].name")
        if [ "$USER_NAME" == "admin" ]; then
            echo -e "\n===== Forcing overwrite for user $USER_NAME ====="
            kubectl exec -n '"$DEST_MSR_K8S_NAMESPACE"' '"$POD_NAME"' -- node --no-deprecation rethinkdb.js "r.db(\"enzi\").table(\"accounts\").insert($USER_JSON, {conflict: \"replace\"})"
        else
            echo -e "\n===== Adding the user $USER_NAME ====="
            kubectl exec -n '"$DEST_MSR_K8S_NAMESPACE"' '"$POD_NAME"' -- node --no-deprecation rethinkdb.js "r.db(\"enzi\").table(\"accounts\").insert($USER_JSON)"
        fi

        
        C_TOKEN=$(jq ".[] | select(.accountID==\"$USER_ID\")" '"$FILE_DIR"'/client_tokens.json | jq -s)

        # Check if C_TOKEN is empty
        if [ -z "$C_TOKEN" ]; then
            echo "No tokens found for user $(echo "$USER_JSON" | jq -r .[].name). Skipping..."
            exit 0
        fi

        echo -e "\n==== This user has $(echo "$C_TOKEN" | jq -r .[].token | wc -l) tokens ====="
        TOKEN_COUNT=$(echo "$C_TOKEN" | jq -r .[].token)

	echo "Token count for user $(echo "$USER_JSON" | jq -r 	.[].name): $TOKEN_COUNT"

        if [ -z "$TOKEN_COUNT" ]; then
            echo "No tokens available to process for user $(echo "$USER_JSON" | jq -r .[].name). Skipping..."
            exit 0
        fi

        echo "TOKEN_COUNT: $TOKEN_COUNT"



	LIMIT_TOKEN_COUNT=$(echo "$C_TOKEN" | jq -r .[].token | wc -l)

	if [ "$LIMIT_TOKEN_COUNT" -gt '"$TOKEN_LIMIT"' ]; then
         echo "Token count is greater than 100. Migrating only the tokens labeled after 2024-07..."
	  FILTERED_TOKENS=$(echo "$C_TOKEN" | jq ".[] | select(.tokenLabel | test(\"2024-(08|07)\"))" | jq -r .token)
	  FILTEREED_TOKEN_COUNT=$(echo "$FILTERED_TOKENS" | wc -l)


	    if [ "$FILTEREED_TOKEN_COUNT" -gt '"$TOKEN_LIMIT"' ]; then
              echo "Even the filtered tokens count is $FILTEREED_TOKEN_COUNT, which is greater than 500. Skipping processing..."
              exit 0
           elif [ "$FILTEREED_TOKEN_COUNT" -le 101 ]; then
	          for token in $FILTERED_TOKENS; do
                   CLIENT_TOKEN=$token
                   CLIENT_TOKEN_JSON=$(echo "$C_TOKEN" | jq ".[] | select(.token==\"$CLIENT_TOKEN\")")
                   echo "Inserting for CLIENT_TOKEN: $CLIENT_TOKEN"
                   kubectl exec -n '"$DEST_MSR_K8S_NAMESPACE"' '"$POD_NAME"' -- node --no-deprecation rethinkdb.js "r.db(\"dtr2\").table(\"client_tokens\").insert($CLIENT_TOKEN_JSON)"
                 done
	     fi



       fi

#	for token in $TOKEN_COUNT; do
#		CLIENT_TOKEN=$token
#		CLIENT_TOKEN_JSON=$(echo "$C_TOKEN" | jq ".[] | select(.token==\"$CLIENT_TOKEN\")")
#		echo "Inserting for CLIENT_TOKEN: $CLIENT_TOKEN"
#		kubectl exec -n '"$DEST_MSR_K8S_NAMESPACE"' '"$POD_NAME"' -- node --no-deprecation rethinkdb.js "r.db(\"dtr2\").table(\"client_tokens\").insert($CLIENT_TOKEN_JSON)"
#      done

    '


    echo -e "\n==== Migration completed successfully! ===="

}

function migrateOrgs() {

    setupEnv

    # Process accounts and tokens
    #ACCOUNTS_UNFORMATTED=$(jq '.[] | select(.name!="admin1" and .name!="docker-datacenter" and .isOrg==false) | del(.accountLock.lockedTime)' $FILE_DIR/accounts.json | jq -s)
    ACCOUNTS_UNFORMATTED=$(jq '.[] | select(.isOrg==false) | del(.accountLock.lockedTime)' $FILE_DIR/accounts.json | jq -s)
    PRD_ORGS_UNFORMATTED=$(jq '.[] | select(.isOrg==true) | del(.accountLock.lockedTime)' $FILE_DIR/accounts.json | jq -s)

    ACCOUNTS=$(echo "$ACCOUNTS_UNFORMATTED" | jq -r '.[].id')
    PRD_ORGS=$(echo "$PRD_ORGS_UNFORMATTED" | jq -r '.[].id')

    echo "Accounts: $ACCOUNTS"  # Debugging output
    echo "Organizations: $PRD_ORGS"  # Debugging output

    if [ -n "$SOURCE_MSR_NODE" ]; then
        for ORG_ID in $PRD_ORGS; do
            echo "ORG_ID: $ORG_ID"
            echo "Processing ORG_ID: $ORG_ID"  # Debugging output

            ORG_JSON=$(jq ".[] | select(.id==\"$ORG_ID\") | del(.accountLock.lockedTime)" $FILE_DIR/accounts.json | jq -s)
            echo "ORG_JSON: $ORG_JSON"  # Debugging output

            if [[ -z "$ORG_JSON" ]]; then
                echo "No JSON found for ORG_ID: $ORG_ID"  # Debugging output
                continue
            fi

            ORG_NAME=$(echo "$ORG_JSON" | jq -r '.[].name')  # Extract organization name
            echo "Extracted ORG_NAME: $ORG_NAME"  # Debugging output

            ORG_MEMBERSHIP=$(jq ".[] | select(.orgID==\"$ORG_ID\")" $FILE_DIR/org_membership.json | jq -s)
            TEAM_ID=$(echo "$ORG_MEMBERSHIP" | jq -r '.[].orgID' | uniq)
            TEAM=$(jq ".[] | select(.orgID==\"$TEAM_ID\")" $FILE_DIR/teams.json | jq -s)
            TEAM_MEM=$(jq ".[] | select(.orgID==\"$TEAM_ID\")" $FILE_DIR/team_membership.json | jq -s)

            echo -e "\n===== Adding the organization $ORG_NAME ====="

            # Inserting organization
            echo "Inserting organization: $ORG_JSON"  # Debugging output
            INSERT_RESULT=$(kubectl exec -n $DEST_MSR_K8S_NAMESPACE $POD_NAME -- node --no-deprecation rethinkdb.js "r.db(\"enzi\").table(\"accounts\").insert($ORG_JSON)")
            echo "Insert result for: $ORG_NAME - $INSERT_RESULT"  # Debugging output

            # Inserting organization membership
            echo "Inserting membership for organization: $ORG_MEMBERSHIP"  # Debugging output
            INSERT_MEMBERSHIP_RESULT=$(kubectl exec -n $DEST_MSR_K8S_NAMESPACE $POD_NAME -- node --no-deprecation rethinkdb.js "r.db(\"enzi\").table(\"org_membership\").insert($ORG_MEMBERSHIP)")
            echo "Insert result for membership of: $ORG_NAME - $INSERT_MEMBERSHIP_RESULT"  # Debugging output

            # Inserting team
            echo "Inserting team: $TEAM"  # Debugging output
            INSERT_TEAM_RESULT=$(kubectl exec -n $DEST_MSR_K8S_NAMESPACE $POD_NAME -- node --no-deprecation rethinkdb.js "r.db(\"enzi\").table(\"teams\").insert($TEAM)")
            echo "Insert result for team of: $ORG_NAME - $INSERT_TEAM_RESULT"  # Debugging output

            # Inserting team membership
            echo "Inserting team membership: $TEAM_MEM"  # Debugging output
            INSERT_TEAM_MEM_RESULT=$(kubectl exec -n $DEST_MSR_K8S_NAMESPACE $POD_NAME -- node --no-deprecation rethinkdb.js "r.db(\"enzi\").table(\"team_membership\").insert($TEAM_MEM)")
            echo "Insert result for team membership of: $ORG_NAME - $INSERT_TEAM_MEM_RESULT"  # Debugging output
            echo;
        done
    else
        echo "SOURCE_MSR_NODE is not set, skipping organization migration."  # Debugging output
    fi

        # Inserting repository team access
        REPO_TEAM_ACCESS=$(jq ".[]" $FILE_DIR/repository_team_access.json | jq -s)
        kubectl exec -n $DEST_MSR_K8S_NAMESPACE $POD_NAME -- node --no-deprecation rethinkdb.js "r.db(\"dtr2\").table(\"repository_team_access\").insert($REPO_TEAM_ACCESS)"

}


function listTags() {

    setupEnv

    echo -e "\n===== Below are the list of tags, that would be migrated ======"
    awk -F '/' '{print $2}' $FILE_DIR/tags.txt | cat -n
    echo "You can manually edit the generated '$FILE_DIR/tags.txt' file to remove the unwanted repository:tag."
}


# function migrateRepos() {

#     setupEnv

#     # Create a backup of $FILE_DIR/tags.txt
#     cp $FILE_DIR/tags.txt "$LOG_DIR/tags-backup-$(date +%Y-%m-%d-%H-%M).txt"
    
#     # Extract repository names from $FILE_DIR/repositories.json
#     LIST=$(cat $FILE_DIR/repositories.json  | jq -r '.[]|.name')
#     LIST_COUNT=$(cat $FILE_DIR/repositories.json  | jq -r '.[]|.name' | wc -l)
#     echo -e "\n==== Starting the repositories migration ===="

#     echo -e "\nCount of repositories to be migrated: $LIST_COUNT"
#     echo "Repo List: $LIST"
#     echo "SOURCE_MSR_URL: $SOURCE_MSR_URL"
#     echo "DEST_MSR_URL: $DEST_MSR_URL"

#     # Use parallel to migrate repositories
#     echo "$LIST" | tr ' ' '\n' | parallel -j $PARALLEL_PROCESS_COUNT --no-notice --tag '
#         echo -e "\n===== Migrating the repo {} ===== "
#         REPO=$(jq ".[] | select(.name==\"{}\")" '"$FILE_DIR"'/repositories.json | jq -s)
#         echo "Repo: '"$REPO"'"
#         kubectl exec -n '"$DEST_MSR_K8S_NAMESPACE"' '"$POD_NAME"' -- node --no-deprecation rethinkdb.js "r.db(\"dtr2\").table(\"repositories\").insert($REPO)"
#     '

#     echo -e "\n==== Repositories Migration Completed. ===="
# }


function migrateRepos() {
    setupEnv

    # Backup tags.txt
    cp $FILE_DIR/tags.txt "$LOG_DIR/tags-backup-$(date +%Y-%m-%d-%H-%M).txt"

    # Extract unique repositories based on name and namespace
    LIST=$(cat $FILE_DIR/repositories.json | jq -r '.[] | "\(.namespaceName)/\(.name)"')
    LIST_COUNT=$(echo "$LIST" | wc -l)
    echo -e "\n==== Starting the repositories migration ===="
    echo -e "\nCount of repositories to be migrated: $LIST_COUNT"
    echo "Repo List: $LIST"

    # Debug: Show source and destination URLs
    echo "SOURCE_MSR_URL: $SOURCE_MSR_URL"
    echo "DEST_MSR_URL: $DEST_MSR_URL"

    # Migrate each repository in parallel
    echo "$LIST" | tr ' ' '\n' | parallel -j $PARALLEL_PROCESS_COUNT --no-notice --tag '
        REPO_INFO={}
        NAMESPACE=$(echo "$REPO_INFO" | cut -d"/" -f1)
        REPO_NAME=$(echo "$REPO_INFO" | cut -d"/" -f2)

        echo "===== Migrating repo $REPO_NAME from namespace $NAMESPACE ====="

        # Extract full repository metadata
        REPO=$(jq ".[] | select(.name==\"$REPO_NAME\" and .namespaceName==\"$NAMESPACE\")" '"$FILE_DIR"'/repositories.json | jq -s)

        if [ -z "$REPO" ]; then
            echo "Error: Repository metadata for $REPO_NAME in namespace $NAMESPACE not found. Skipping."
            exit 1
        fi

        # Debugging: Print the repository JSON
        echo "Repo JSON: $REPO"

        # Insert repository into the destination rethinkdb
        kubectl exec -n '"$DEST_MSR_K8S_NAMESPACE"' '"$POD_NAME"' -- node --no-deprecation rethinkdb.js "r.db(\"dtr2\").table(\"repositories\").insert($REPO)" || {
            echo "Error: Failed to migrate repository $REPO_NAME in namespace $NAMESPACE. Check logs."
        }
    '

    echo -e "\n==== Repositories Migration Completed. ===="
}



function migrateTags() {
    
    setupEnv

    LIST=$(cat $FILE_DIR/tags.txt | sort | uniq)
    LIST_COUNT=$(cat $FILE_DIR/tags.txt | sort | uniq | wc -l)

    SKOPEO_AUTH_FILE=".skopeo.auth"

    echo -e "Started at ===== $(date '+%D %T') =====\n" >> migratedImages.txt

    echo -e "\n Count of tags to be migrated: $LIST_COUNT"

    # Debugging: Check contents of LIST and URLs
    echo "Processing list of images:"
    echo "$LIST"
    echo "SOURCE_MSR_URL: $SOURCE_MSR_URL"
    echo "DEST_MSR_URL: $DEST_MSR_URL"

    # Use parallel for docker pull/push without shellquote or extra quotes
    echo "$LIST" | tac | parallel -j $PARALLEL_PROCESS_COUNT --no-notice --tag '
        IMAGE_NAME={}

        # Ensure IMAGE_NAME is not empty
        if [ -z "$IMAGE_NAME" ]; then
            echo "Error: IMAGE_NAME is empty. Skipping."
            exit 1
        fi

        # Remove any leading slashes from the image name
        IMAGE_NAME=$(echo "$IMAGE_NAME" | sed "s|^/||")

        echo "Image name: $IMAGE_NAME"

        # Copying image with skopeo
        echo "Copying image with skopeo: from docker://'"$SOURCE_MSR_URL"'/$IMAGE_NAME to docker://'"$DEST_MSR_URL"'/$IMAGE_NAME"
        skopeo copy --src-creds '"$SOURCE_MSR_USERNAME"':'"$SOURCE_MSR_TOKEN"' --dest-creds '"$DEST_MSR_USERNAME"':'"$DEST_MSR_TOKEN"' --src-tls-verify=false --dest-tls-verify=false docker://'"$SOURCE_MSR_URL"'/$IMAGE_NAME docker://'"$DEST_MSR_URL"'/$IMAGE_NAME

        echo "$IMAGE_NAME" >> migratedImages.txt
    '
}



# Run All Migrations
migrateAll() {
    setupEnv
    listTags
    migrateAccounts
    migrateOrgs
    migrateRepos
    migrateTags
    echo "All migrations completed successfully."
}



helpMsg() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -F, --files          Create required migration files (must be run first)."
    echo "  -a, --accounts       Migrate user accounts and their tokens."
    echo "  -o, --orgs           Migrate organizations, teams, and memberships."
    echo "  -r, --repos          Migrate repositories."
    echo "  -t, --tags           Migrate repository tags and associated images."
    echo "  -L, --list-tags      List all tags from 'tags.json'."
    echo "  -A, --migrate-all    Perform all migrations sequentially (requires '-F' first)."
    echo "  -h, --help           Display this help message."
    echo
    echo "Requirements:"
    echo "- Passwordless SSH access to source MKE and DTR nodes."
    echo "- Destination K8s environment kubeconfig."
    echo "- Username/password/token to access source and destination MSRs."
    echo "- A running rethinkdb-cli pod on the destination MSR."
    echo
    echo "Note: Run with '-F' to generate migration files before using other options."
}



# Check whether arguments were provided
if [ "$#" -eq 0 ]; then
    helpMsg
    exit 1
fi

# Parse the arguments
for arg in "$@"; do
    case $arg in
        -F|--files)
        migtationFiles
        shift  # Remove argument name from processing
        ;;
        -a|--accounts)
        migrateAccounts
        shift
        ;;
        -o|--orgs)
        migrateOrgs
        shift
        ;;
        -r|--repos)
        migrateRepos
        shift
        ;;
        -t|--tags)
        listTags
        migrateTags
        shift
        ;;
        -e|--env)
        setupEnv
        shift
        ;;
        -A|--migrate-all)
        migrateAll
        shift
        ;;
	    -L|--list-tags)
        listTags
        shift
        ;;
        -h|--help)
        helpMsg
        exit 0
        ;;
        *)
        echo "Invalid option: $arg"
        helpMsg
        exit 1
        ;;
    esac
done
