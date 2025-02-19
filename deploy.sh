#!/bin/bash

# Parse and validate command line options
usage() {
    echo "Usage: $0 [-i image:tag@sha256:*](required) [-f project.docker-compose.yml](required)"
    exit 1
}

# Parse and validate command line options
while getopts "i:f:" opt; do
    case $opt in
        i)  DOCKER_IMAGE_NEW=$OPTARG
            if ! [[ "${DOCKER_IMAGE_NEW}" =~ ^.*:.*@sha256:[a-z0-9]{64}$ ]]; then
                echo "Failure: Image ${DOCKER_IMAGE_NEW} did not pass validation checks, ensure sha256-hash is included"
                usage
            fi
            ;;
        f)  DOCKER_COMPOSE_FILE=$OPTARG
            # Docker Compose stack for which zero-downtime deploys are implemented, requires services "blue" and "green"
            if ! [ -f "${DOCKER_COMPOSE_FILE}" ]; then
                echo "Failure: ${DOCKER_COMPOSE_FILE} does not exist"
                usage
            fi
            ;;
        :)  echo 'Failure: Missing argument' >&2
            usage
            ;;
        *)  echo 'Failure: Error in command line parsing' >&2
            usage
            ;;
    esac
done
if [[ -z "${DOCKER_IMAGE_NEW}" || -z "${DOCKER_COMPOSE_FILE}" ]]; then
    echo "Failure: Required options missing"
    usage
fi


set -euxo pipefail


# Functions

http_health_check_live() {
    URL="$1"
    NODE_EXPECTED="$2"
    # perform up to 5 health checks every 3s, container may start slowly
    for i in {1..5}; do
        HTTP_STATUS=$(curl -k --silent --output /dev/null --write-out "%{http_code}" "https://${URL}")
        CUSTOM_HEADER=$(curl -k -I --silent --output /dev/null --write-out '%header{x-deployment-node}' "https://${URL}")

        if [[ "${HTTP_STATUS}" == '200' ]] && [[ "${CUSTOM_HEADER}" == "${NODE_EXPECTED}" ]]; then
            echo "Success: Staging node ${NODE_EXPECTED} answers with status code ${HTTP_STATUS}"
            return 0
        elif [[ "${HTTP_STATUS}" != '200' ]] && [[ "${CUSTOM_HEADER}" == "${NODE_EXPECTED}" ]]; then
            echo "Failure: Staging node ${NODE_EXPECTED} answers with status code ${HTTP_STATUS} [${1}/3]"
            sleep 3
        elif [[ "${HTTP_STATUS}" == '200' ]] && [[ "${CUSTOM_HEADER}" != "${NODE_EXPECTED}" ]]; then
            echo "Failure: Requests are not answered by Staging node ${NODE_EXPECTED} [${1}/3]"
            sleep 3
        else
            echo "Failure: Unknown error, status code ${HTTP_STATUS}, node ${CUSTOM_HEADER}"
            sleep 3
        fi
    done
    # if retries failed, do not exit script and return failure
    set +e
    return 1
}

http_health_check_staging() {
    URL="$1"
    NODE_EXPECTED="$2"
    # perform up to 5 health checks every 3s, container may start slowly
    for i in {1..5}; do
        HTTP_STATUS=$(curl --header 'X-Deployment-Status: staging' -k --silent --output /dev/null --write-out "%{http_code}" "https://${URL}")
        CUSTOM_HEADER=$(curl -I --header 'X-Deployment-Status: staging' -k --silent --output /dev/null --write-out '%header{x-deployment-node}' "https://${URL}")

        if [[ "${HTTP_STATUS}" == '200' ]] && [[ "${CUSTOM_HEADER}" == "${NODE_EXPECTED}" ]]; then
            echo "Success: Staging node ${NODE_EXPECTED} answers with status code ${HTTP_STATUS}"
            return 0
        elif [[ "${HTTP_STATUS}" != '200' ]] && [[ "${CUSTOM_HEADER}" == "${NODE_EXPECTED}" ]]; then
            echo "Failure: Staging node ${NODE_EXPECTED} answers with status code ${HTTP_STATUS} [${1}/3]"
            sleep 3
        elif [[ "${HTTP_STATUS}" == '200' ]] && [[ "${CUSTOM_HEADER}" != "${NODE_EXPECTED}" ]]; then
            echo "Failure: Requests are not answered by Staging node ${NODE_EXPECTED} [${1}/3]"
            sleep 3
        else
            echo "Failure: Unknown error, status code ${HTTP_STATUS}, node ${CUSTOM_HEADER}"
            sleep 3
        fi
    done
    # if retries failed, do not exit script and return failure
    set +e
    return 1
}

rollback_container(){
    # Reset container to previous state
    echo "Remove unhealthy container ${CONTAINER_NEW}"
    docker compose -f "${DOCKER_COMPOSE_FILE}" down "${CONTAINER_NEW}"
    echo "Reset docker image version for ${CONTAINER_NEW} to ${DOCKER_IMAGE_OLD} in .env"
    if [[ "${CONTAINER_NEW}" == "blue" ]]; then
        sed -i "s|^DOCKER_IMAGE_BLUE=.*$|DOCKER_IMAGE_BLUE=${DOCKER_IMAGE_OLD}|g" .env
    elif [[ "${CONTAINER_NEW}" == "green" ]]; then
        sed -i "s|^DOCKER_IMAGE_GREEN=.*$|DOCKER_IMAGE_GREEN=${DOCKER_IMAGE_OLD}|g" .env
    fi
    echo "Container ${CONTAINER_NEW} rolled back to previous state"
    echo "Ensure Traefik dynamic configuration is reset to previous state"
    yq -yi --arg c "${CONTAINER_OLD}" '.http.routers[$c].rule = "Host(`__main__`) && ! Header(`X-Deployment-Status`, `staging`)"' nginx/dynamic/dynamic.yml
    yq -yi --arg c "${CONTAINER_NEW}" '.http.routers[$c].rule = "Host(`__main__`) && Header(`X-Deployment-Status`, `staging`)"' nginx/dynamic/dynamic.yml
    http_health_check_live "${URL_MAIN}" "${CONTAINER_OLD}"
    if [ $? -eq 1 ]; then
        echo "Failure: ${URL_MAIN} is still served by ${CONTAINER_NEW}"
        exit 1
    fi
    return 0
}


# Create lockfile to avoid race conditions due to multiple deploys
LOCKFILE=./deploy.lock
if [ -f "${LOCKFILE}" ]; then
    echo "Failure: Lock file exists - previous deployment either failed or is still running"
    exit 1
fi
touch "${LOCKFILE}"


# Dependency checks
if ! [[ $(dpkg -l yq) ]]; then
    echo "Failure: Dependency yq is missing ('apt install yq')"
    rm "${LOCKFILE}"
    exit 1
fi

if ! [ -f ".env" ]; then
    echo "Failure: .env is missing"
    rm "${LOCKFILE}"
    exit 1
else
    # requires URL_MAIN and CONTAINER_LIVE
    source .env
fi


# Pull docker image
echo "Pull docker image ${DOCKER_IMAGE_NEW}"
if ! [[ $(docker pull "${DOCKER_IMAGE_NEW}") ]]; then
    echo "Failure: ${DOCKER_IMAGE_NEW} is not available"
    rm "${LOCKFILE}"
    exit 1
fi


# Detect running container from Traefik dynamic configuration
echo "Get active container and image version"
CONTAINER_OLD="${CONTAINER_LIVE}"
if ! [[ "${CONTAINER_OLD}" =~ ^(blue|green)$ ]]; then
    echo "Failure: CONTAINER_LIVE in .env invalid or missing"
    rm "${LOCKFILE}"
    exit 1
else
    DOCKER_IMAGE_OLD=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_OLD}")
    echo "Container ${CONTAINER_OLD} currently runs image ${DOCKER_IMAGE_OLD}"
fi


# Update image version in .env
echo "Update image version of inactive container to ${DOCKER_IMAGE_NEW} in .env"
if [[ "${CONTAINER_OLD}" == "blue" ]]; then
    sed -i "s|^DOCKER_IMAGE_GREEN=.*$|DOCKER_IMAGE_GREEN=${DOCKER_IMAGE_NEW}|g" .env
    CONTAINER_NEW="green"
elif [[ "${CONTAINER_OLD}" == "green" ]]; then
    sed -i "s|^DOCKER_IMAGE_BLUE=.*$|DOCKER_IMAGE_BLUE=${DOCKER_IMAGE_NEW}|g" .env
    CONTAINER_NEW="blue"
fi

# Todo: Implement backups for rollbacks here
# Todo: Implement database locking here if required
# ./deploy_pre.sh


# Wait for container to start up and perform health checks
echo "Start ${CONTAINER_NEW} with docker image ${DOCKER_IMAGE_NEW}"
if docker compose -f "${DOCKER_COMPOSE_FILE}" up -d "${CONTAINER_NEW}"; then
    sleep 5
else
    echo "Failure: Container ${CONTAINER_NEW} startup error"
    rollback_container
    rm "${LOCKFILE}" && exit 1
fi

echo "Ensure container ${CONTAINER_NEW} uses the new image ${DOCKER_IMAGE_NEW}"
if ! [[ "$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NEW}")" == "${DOCKER_IMAGE_NEW}" ]]; then
    echo "Failure: Container ${CONTAINER_NEW} still uses the old image"
    rollback_container
    rm "${LOCKFILE}" && exit 1
fi

echo "Get Docker integrated HEALTHCHECK status"
if [[ "$(docker container inspect --format='{{.State.Health.Status}}' "${CONTAINER_NEW}" 2>&1)" =~ 'map has no entry for key' ]]; then
    echo "Warning: Image ${DOCKER_IMAGE_NEW} has no integrated HEALTHCHECK, will skip to HTTP checks"
else
    # perform up to 5 health checks every 3s, container may start slowly
    for i in {1..5}; do
        HEALTHCHECK_STATUS="$(docker container inspect --format='{{.State.Health.Status}}' "${CONTAINER_NEW}")"
        case "${HEALTHCHECK_STATUS}" in
            starting)
                if [[ "${i}" -eq 5 ]]; then
                    echo "Failure: Docker HEALTHCHECK is stuck in starting state"
                    rollback_container
                    rm "${LOCKFILE}" && exit 1
                else
                    echo "Warning: Docker HEALTHCHECK is starting, will re-check (${i}/5)"
                    sleep 3
                fi
                ;;
            healthy)
                echo "Container ${CONTAINER_NEW} is healthy"
                break
                ;;
            unhealthy)
                echo "Failure: Container ${CONTAINER_NEW} is unhealthy"
                rollback_container
                rm "${LOCKFILE}" && exit 1
                ;;
            *)
                echo "Failure: Unknown HEALTHCHECK status for ${CONTAINER_NEW}"
                rollback_container
                rm "${LOCKFILE}" && exit 1
                ;;
        esac
    done
fi

# Todo: Implement migrations for new image here
# ./deploy_migrate.sh

# HTTP health checks for new container accessible via custom host header
echo "Ensure container ${CONTAINER_NEW} answers with HTTP status code 200"
http_health_check_staging "${URL_MAIN}" "${CONTAINER_NEW}"
if [ $? -eq 1 ]; then
    echo "Failure: HTTP healthchecks failed"
    rollback_container
    # Todo: Implement migration rollback as well, then lock can be removed
    # rm "${LOCKFILE}" && exit 1
    exit 1
fi

# Route live traffic to new container by switching rule for header-based routing
echo "Route traffic for https://${URL_MAIN} to ${CONTAINER_NEW} and wait 10s"
yq -yi --arg c "${CONTAINER_NEW}" '.http.routers[$c].rule = "Host(`__main__`) && ! Header(`X-Deployment-Status`, `staging`)"' nginx/dynamic/dynamic.yml
yq -yi --arg c "${CONTAINER_OLD}" '.http.routers[$c].rule = "Host(`__main__`) && Header(`X-Deployment-Status`, `staging`)"' nginx/dynamic/dynamic.yml
# see providersThrottleDuration and pollInterval in traefik/traefik.yml
sleep 10s

# HTTP health check for live traffic
echo "Ensure live traffic is answered by ${CONTAINER_NEW} with HTTP status code 200"
http_health_check_live "${URL_MAIN}" "${CONTAINER_NEW}"
if [ $? -eq 1 ]; then
    echo "Failure: HTTP healthchecks failed"
    rollback_container
    # Todo: Implement migration rollback as well, then lock can be removed
    # rm "${LOCKFILE}" && exit 1
    exit 1
fi

# Todo: Implement database unlocking here if required
# ./deploy_post.sh

# Cleanup
echo "Remove outdated container ${CONTAINER_OLD}"
docker compose -f "${DOCKER_COMPOSE_FILE}" down "${CONTAINER_OLD}"

# Update live container in .env
sed -i "s|^CONTAINER_LIVE=.*$|CONTAINER_LIVE=${CONTAINER_NEW}|g" .env

# Ensures that an old container version is never run when ${DOCKER_COMPOSE_FILE} is restarted.
echo "Update image version for now inactive container ${CONTAINER_OLD} to ${DOCKER_IMAGE_NEW} in .env"
if [[ "${CONTAINER_OLD}" == "blue" ]]; then
    sed -i "s|^DOCKER_IMAGE_BLUE=.*$|DOCKER_IMAGE_BLUE=${DOCKER_IMAGE_NEW}|g" .env
elif [[ "${CONTAINER_OLD}" == "green" ]]; then
    sed -i "s|^DOCKER_IMAGE_GREEN=.*$|DOCKER_IMAGE_GREEN=${DOCKER_IMAGE_NEW}|g" .env
fi

# Remove lockfile
echo "Deployment finished. Remove lockfile and exit"
rm "${LOCKFILE}"
