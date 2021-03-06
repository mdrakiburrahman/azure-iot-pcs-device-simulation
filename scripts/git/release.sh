#!/usr/bin/env bash
# Copyright (c) Microsoft. All rights reserved.
# Note: Windows Bash doesn't support shebang extra params
set -e

while [ "$#" -gt 0 ]; do
    case "$1" in
        --release_version)              RELEASE_VERSION="$2" ;;
        --git_access_token)             GIT_ACCESS_TOKEN="$2" ;;
        --docker_user)                  DOCKER_USER="$2" ;;
        --docker_pwd)                   DOCKER_PWD="$2" ;;
        --from_docker_namespace)        FROM_DOCKER_NAMESPACE="$2" ;;
        --to_docker_namespace)          TO_DOCKER_NAMESPACE="$2" ;;
        --docker_tag)                   DOCKER_TAG="$2" ;;
        --description)                  DESCRIPTION="$2" ;;
        --pre_release)                  PRE_RELEASE="$2" ;;
        --local)                        LOCAL="$2" ;;
    esac
    shift
done

# Set default values for optional parameters
FROM_DOCKER_NAMESPACE=${FROM_DOCKER_NAMESPACE:-azureiotpcs}
TO_DOCKER_NAMESPACE=${TO_DOCKER_NAMESPACE:-azureiotpcs}
DOCKER_TAG=${DOCKER_TAG:-testing}
DESCRIPTION=${DESCRIPTION:-''}
PRE_RELEASE=${PRE_RELEASE:-false}
LOCAL=${LOCAL:-''}

APP_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && cd .. && cd .. && pwd )/"

NC="\033[0m" # no color
CYAN="\033[1;36m" # light cyan
YELLOW="\033[1;33m" # yellow
RED="\033[1;31m" # light red

failed() {
    SUB_MODULE=$1
    echo -e "${RED}Cannot find directory $SUB_MODULE${NC}"
    exit 1
}

usage() {
    echo -e "${RED}ERROR: $1 is a required option${NC}"
    echo "Usage: ./release"
    echo -e 'Options:
        --release_version       Version of this release (required)
        --git_access_token      Git access token to push tag (required)
        --docker_user           Username to login docker hub (required)
        --docker_pwd            Password to login docker hub (required)
        --from_docker_namespace Source namespace of docker image (default:azureiotpcs)
        --to_docker_namespace   Target namespace of docker image (default:azureiotpcs)
        --docker_tag            Source tag of docker image (default:testing)
        --description           Description of this release (default:empty)
        --pre_release           Publish as non-production release on github (default:false)
        --local                 Clean up the local repo at first (default:empty)
        '
    exit 1
}

check_input() {
    if [ ! -n "$RELEASE_VERSION" ]; then
        usage "release_version"
    fi
    if [ ! -n "$DOCKER_USER" ]; then
        usage "docker_user"
    fi
    echo $DOCKER_PWD | docker login -u $DOCKER_USER --password-stdin
}

tag_build_publish_repo() {
    SUB_MODULE=$1
    REPO_NAME=$2
    DOCKER_CONTAINER_NAME=${3:-$2}
    DESCRIPTION=$4

    echo
    echo -e "${CYAN}====================================     Start: Tagging the $REPO_NAME repo     ====================================${NC}"
    echo
    echo -e "Current working directory ${CYAN}$APP_HOME$SUB_MODULE${NC}"
    echo
    cd $APP_HOME$SUB_MODULE || failed $SUB_MODULE

    if [ -n "$LOCAL" ]; then
        echo "Cleaning the repo"
        git reset --hard origin/master
        git clean -xdf
    fi

    if [ "$REPO_NAME" == "pcs-config-dotnet" ]; then
        git checkout RemoveServiceDependency
    else
        git checkout master
    fi

    echo "set url"
    git remote set-url origin https://$GIT_ACCESS_TOKEN@github.com/Azure/$REPO_NAME.git

    echo "git pull"
    git pull --all --prune

    echo "git tag"
    git tag --force $RELEASE_VERSION

    echo "git push"
    git push https://$GIT_ACCESS_TOKEN@github.com/Azure/$REPO_NAME.git $RELEASE_VERSION

    echo
    echo -e "${CYAN}====================================     End: Tagging $REPO_NAME repo     ====================================${NC}"
    echo

    echo
    echo -e "${CYAN}====================================     Start: Release for $REPO_NAME     ====================================${NC}"
    echo

    # For documentation https://help.github.com/articles/creating-releases/
    DATA="{
        \"tag_name\": \"$RELEASE_VERSION\",
        \"target_commitish\": \"master\",
        \"name\": \"$RELEASE_VERSION\",
        \"body\": \"$DESCRIPTION\",
        \"draft\": false,
        \"prerelease\": $PRE_RELEASE
    }"

    curl -X POST --data "$DATA" https://api.github.com/repos/Azure/$REPO_NAME/releases?access_token=$GIT_ACCESS_TOKEN
    echo
    echo -e "${CYAN}====================================     End: Release for $REPO_NAME     ====================================${NC}"
    echo

    if [ -n "$SUB_MODULE" ] && [ "$REPO_NAME" != "pcs-cli" ]; then
        echo
        echo -e "${CYAN}====================================     Start: Building $REPO_NAME     ====================================${NC}"
        echo

        BUILD_PATH="scripts/docker/build"
        if [ "$SUB_MODULE" == "api-gateway" ]; then 
            BUILD_PATH="build"
        fi

        # Building docker containers
        echo "Building docker containers"
        echo $APP_HOME$SUB_MODULE/$BUILD_PATH
        /bin/bash $APP_HOME$SUB_MODULE/$BUILD_PATH

        echo
        echo -e "${CYAN}====================================     End: Building $REPO_NAME     ====================================${NC}"
        echo
        
        # Tag containers
        echo -e "${CYAN}Tagging $FROM_DOCKER_NAMESPACE/$DOCKER_CONTAINER_NAME:$DOCKER_TAG ==> $TO_DOCKER_NAMESPACE/$DOCKER_CONTAINER_NAME:$RELEASE_VERSION${NC}"
        echo
        docker tag $FROM_DOCKER_NAMESPACE/$DOCKER_CONTAINER_NAME:$DOCKER_TAG  $TO_DOCKER_NAMESPACE/$DOCKER_CONTAINER_NAME:$RELEASE_VERSION

        # Push containers
        echo -e "${CYAN}Pusing container $TO_DOCKER_NAMESPACE/$DOCKER_CONTAINER_NAME:$RELEASE_VERSION${NC}"
        docker push $TO_DOCKER_NAMESPACE/$DOCKER_CONTAINER_NAME:$RELEASE_VERSION
    fi
}

check_input

# DOTNET Microservices
# As of DS-2.0.6, only the Web UI and the Simulation service containers are
# refrenced by a new docker tag for each release (in docker-compse.yaml in the
# deployed VMs)
tag_build_publish_repo simulation-service     device-simulation-dotnet
tag_build_publish_repo webui                  pcs-simulation-webui              device-simulation-webui
tag_build_publish_repo pcs-diagnostics-dotnet pcs-diagnostics-dotnet
tag_build_publish_repo storage-service        pcs-storage-adapter-dotnet
tag_build_publish_repo pcs-config-dotnet      pcs-config-dotnet
#tag_build_publish_repo api-gateway            azure-iot-pcs-device-simulation   simulation-api-gateway

set +e