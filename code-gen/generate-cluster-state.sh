#!/bin/bash

########################################################################################################################
#
# This script may be used to generate the initial Kubernetes configurations to push into the cluster-state repository
# for a particular tenant. This repo is referred to as the cluster state repo because the EKS clusters are always
# (within a few minutes) reflective of the code in this repo. This repo is the only interface for updates to the
# clusters. In other words, kubectl commands that alter the state of the cluster are verboten outside of this repo.
#
# The intended audience of this repo is primarily the Ping Professional Services and Support team, with limited access
# granted to Customer administrators. These users may further tweak the cluster state per the tenant's requirements.
# They are expected to have an understanding of Kubernetes manifest files and kustomize, a client-side tool used to make
# further customizations to the initial state generated by this script.
#
# The script generates Kubernetes manifest files for 4 different environments - dev, test, stage and prod. The
# manifest files for these environments contain deployments of both the Ping Cloud stack and the supporting tools
# necessary to provide an end-to-end solution.
#
# ------------
# Requirements
# ------------
# The script requires the following tools to be installed:
#   - openssl
#   - ssh-keygen
#   - ssh-keyscan
#   - base64
#   - envsubst
#
# ------------------
# Usage instructions
# ------------------
# The script does not take any parameters, but rather acts on environment variables. The environment variables will
# be substituted into the variables in the yaml template files. The following mandatory environment variables must be
# present before running this script:
#
# ----------------------------------------------------------------------------------------------------------------------
# Variable                    | Purpose
# ----------------------------------------------------------------------------------------------------------------------
# PING_IDENTITY_DEVOPS_USER   | A user with license to run Ping Software
# PING_IDENTITY_DEVOPS_KEY    | The key to the above user
#
# In addition, the following environment variables, if present, will be used for the following purposes:
#
# ----------------------------------------------------------------------------------------------------------------------
# Variable               | Purpose                                            | Default (if not present)
# ----------------------------------------------------------------------------------------------------------------------
# TENANT_NAME            | The name of the tenant, e.g. k8s-icecream. If      | PingPOC
#                        | provided, this value will be used for the cluster  |
#                        | name and must have the correct case (e.g. PingPOC  |
#                        | vs. pingpoc). If not provided, this variable is    |
#                        | not used, and the cluster name defaults to the CDE |
#                        | name.                                              |
#                        |                                                    |
# TENANT_DOMAIN          | The tenant's domain suffix that's common to all    | eks-poc.au1.ping-lab.cloud
#                        | CDEs e.g. k8s-icecream.com. The tenant domain in   |
#                        | each CDE is assumed to have the CDE name as the    |
#                        | prefix, followed by a hyphen. For example, for the |
#                        | above prefix, the tenant domain for stage is       |
#                        | assumed to be stage-k8s-icecream.com and a hosted  |
#                        | zone assumed to exist on Route53 for that domain.  |
#                        |                                                    |
# REGION                 | The region where the tenant environment is         | us-east-2
#                        | deployed. For PCPT, this is a required parameter   |
#                        | to Container Insights, an AWS-specific logging     |
#                        | and monitoring solution.                           |
#                        |                                                    |
# SIZE                   | Size of the environment, which pertains to the     | small
#                        | number of user identities. Legal values are        |
#                        | small, medium or large.                            |
#                        |                                                    |
# CLUSTER_STATE_REPO_URL | The URL of the cluster-state repo.                 | https://github.com/pingidentity/ping-cloud-base
#                        |                                                    |                        |                                                    |
# CONFIG_REPO_URL        | The URL of the config repo.                        | https://github.com/pingidentity/pingidentity-server-profiles
#                        |                                                    |
# CONFIG_REPO_BRANCH     | The branch within the config repo to use for       | pcpt
#                        | application configuration.                         |
#                        |                                                    |
# ARTIFACT_REPO_URL      | The URL for plugins (e.g. PF kits, PD extensions). | No default
#                        | For PCPT, this is an S3 bucket. If not provided,   |
#                        | the Ping stack will be provisioned without         |
#                        | plugins.                                           |
#                        |                                                    |
# LOG_ARCHIVE_URL        | The URL of the log archives. If provided, logs are | The string "unused"
#                        | periodically captured and sent to this URL.        |
#                        |                                                    |
# K8S_GIT_URL            | The Git URL of the Kubernetes base manifest files. | https://github.com/pingidentity/ping-cloud-base
#                        |                                                    |
# K8S_GIT_BRANCH         | The Git branch within the above Git URL.           | master
#                        |                                                    |
# REGISTRY_NAME          | The registry hostname for the Docker images used   | docker.io
#                        | by the Ping stack. This can be Docker hub, ECR     |
#                        | (1111111111.dkr.ecr.us-east-2.amazonaws.com), etc. |
#                        |                                                    |
# SSH_ID_PUB_FILE        | The file containing the public-key (in PEM format) | No default
#                        | used by FluxCD and the Ping containers to access   |
#                        | the cluster state and config repos, respectively.  |
#                        | If not provided, a new key-pair will be generated  |
#                        | by the script. If provided, the SSH_ID_KEY_FILE    |
#                        | must also be provided and correspond to this       |
#                        | public key.                                        |
#                        |                                                    |
# SSH_ID_KEY_FILE        | The file containing the private-key (in PEM        | No default
#                        | format) used by FluxCD and the Ping containers to  |
#                        | access the cluster state and config repos,         |
#                        | respectively. If not provided, a new key-pair      |
#                        | will be generated by the script. If provided, the  |
#                        | SSH_ID_PUB_FILE must also be provided and          |
#                        | correspond to this private key.                    |
#                        |                                                    |
# TARGET_DIR             | The directory where the manifest files will be     | /tmp/sandbox
#                        | generated. If the target directory exists, it will |
#                        | be deleted.                                        |
#                        |                                                    |
# IS_BELUGA_ENV          | An optional flag that may be provided to indicate  | false. Only intended for Beluga
#                        | that the cluster state is being generated for      | developers.
#                        | testing during Beluga development. If set to true, |
#                        | the cluster name is assumed to be the tenant name  |
#                        | and the tenant domain assumed to be the same       |
#                        | across all 4 CDEs. On the other hand, in PCPT, the |
#                        | cluster name for the CDEs are hardcoded to dev,    |
#                        | test, stage and prod. The domain names for the     |
#                        | CDEs are derived from the TENANT_DOMAIN variable   |
#                        | as documented above. This flag exists because the  |
#                        | Beluga developers only have access to one domain   |
#                        | and hosted zone in their Ping IAM account role.    |
########################################################################################################################

########################################################################################################################
# Substitute variables in all template files in the provided directory.
#
# Arguments
#   ${1} -> The directory that contains the template files.
########################################################################################################################

# The list of variables in the template files that will be substituted.
VARS='${PING_IDENTITY_DEVOPS_USER_BASE64}
${PING_IDENTITY_DEVOPS_KEY_BASE64}
${TENANT_DOMAIN}
${REGION}
${SIZE}
${CLUSTER_NAME}
${CLUSTER_STATE_REPO_URL}
${CLUSTER_STATE_REPO_HOST}
${CONFIG_REPO_URL}
${CONFIG_REPO_BRANCH}
${ARTIFACT_REPO_URL}
${LOG_ARCHIVE_URL}
${K8S_GIT_URL}
${K8S_GIT_BRANCH}
${REGISTRY_NAME}
${TLS_CRT_BASE64}
${TLS_KEY_BASE64}
${SSH_ID_PUB}
${SSH_ID_KEY_BASE64}
${KNOWN_HOSTS_CLUSTER_STATE_REPO}
${KNOWN_HOSTS_CONFIG_REPO}
${DNS_RECORD_SUFFIX}
${DNS_DOMAIN_PREFIX}
${ENVIRONMENT_GIT_PATH}
${PING_CLOUD_NAMESPACE}
${KUSTOMIZE_BASE}
${PING_CLOUD_NAMESPACE_RESOURCE}
${PING_DATA_CONSOLE_INGRESS_PATCH}
${PING_DIRECTORY_LDAP_ENDPOINT_PATCH}
${SERVICE_NGINX_PRIVATE_PATCH}
${DELETE_PING_CLOUD_NAMESPACE_PATCH_MERGE}'

substitute_vars() {
  SUBST_DIR=${1}
  for FILE in $(find "${SUBST_DIR}" -type f); do
    EXTENSION="${FILE##*.}"
    if test "${EXTENSION}" = 'tmpl'; then
      TARGET_FILE="${FILE%.*}"
      envsubst "${VARS}" < "${FILE}" > "${TARGET_FILE}"
      rm -f "${FILE}"
    fi
  done
}

########################################################################################################################
# Remove the file from its current location, substitute the variables in it using corresponding environment variables
# and print its final contents to stdout.
#
# Arguments
#   ${1} -> The name of the file to patch and remove.
########################################################################################################################
patch_remove_file() {
  FILE_TO_PATCH="${1}"
  FILE_NO_TMPL_EXT=${FILE_TO_PATCH%.tmpl}
  FILE_NO_TMPL_EXT=$(basename "${FILE_NO_TMPL_EXT}")

  TMP_DIR=$(mktemp -d)
  mv "${FILE_TO_PATCH}" "${TMP_DIR}"
  substitute_vars "${TMP_DIR}"

  cat "${TMP_DIR}/${FILE_NO_TMPL_EXT}"

  rm -rf "${TMP_DIR}"
}

# Ensure that this script works from any working directory.
SCRIPT_HOME=$(cd $(dirname ${0}); pwd)
pushd "${SCRIPT_HOME}"

# Source some utility methods.
. ../utils.sh

# Checking required tools and environment variables.
check_binaries "openssl" "ssh-keygen" "ssh-keyscan" "base64" "envsubst"
HAS_REQUIRED_TOOLS=${?}

check_env_vars "PING_IDENTITY_DEVOPS_USER" "PING_IDENTITY_DEVOPS_KEY"
HAS_REQUIRED_VARS=${?}

if test ${HAS_REQUIRED_TOOLS} -ne 0 || test ${HAS_REQUIRED_VARS} -ne 0; then
  # Go back to previous working directory, if different, before exiting.
  popd
  exit 1
fi

# Print out the values provided used for each variable.
echo "Initial TENANT_NAME: ${TENANT_NAME}"
echo "Initial TENANT_DOMAIN: ${TENANT_DOMAIN}"
echo "Initial REGION: ${REGION}"
echo "Initial SIZE: ${SIZE}"

echo "Initial CLUSTER_STATE_REPO_URL: ${CLUSTER_STATE_REPO_URL}"

echo "Initial CONFIG_REPO_URL: ${CONFIG_REPO_URL}"
echo "Initial CONFIG_REPO_BRANCH: ${CONFIG_REPO_BRANCH}"

echo "Initial ARTIFACT_REPO_URL: ${ARTIFACT_REPO_URL}"
echo "Initial LOG_ARCHIVE_URL: ${LOG_ARCHIVE_URL}"

echo "Initial K8S_GIT_URL: ${K8S_GIT_URL}"
echo "Initial K8S_GIT_BRANCH: ${K8S_GIT_BRANCH}"

echo "Initial REGISTRY_NAME: ${REGISTRY_NAME}"

echo "Initial SSH_ID_PUB_FILE: ${SSH_ID_PUB_FILE}"
echo "Initial SSH_ID_KEY_FILE: ${SSH_ID_KEY_FILE}"

echo "Initial TARGET_DIR: ${TARGET_DIR}"
echo "Initial IS_BELUGA_ENV: ${IS_BELUGA_ENV}"
echo ---

# Use defaults for other variables, if not present.
export TENANT_NAME="${TENANT_NAME:-PingPOC}"
TENANT_DOMAIN_NO_DOT_SUFFIX="${TENANT_DOMAIN%.}"
export TENANT_DOMAIN="${TENANT_DOMAIN_NO_DOT_SUFFIX:-eks-poc.au1.ping-lab.cloud}"
export REGION="${REGION:-us-east-2}"
export SIZE="${SIZE:-small}"

export CLUSTER_STATE_REPO_URL="${CLUSTER_STATE_REPO_URL:-git@github.com:pingidentity/ping-cloud-base.git}"

export CONFIG_REPO_URL="${CONFIG_REPO_URL:-https://github.com/pingidentity/pingidentity-server-profiles}"
export CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-pcpt}"

export ARTIFACT_REPO_URL="${ARTIFACT_REPO_URL}"
export LOG_ARCHIVE_URL="${LOG_ARCHIVE_URL:-unused}"

export K8S_GIT_URL="${K8S_GIT_URL:-https://github.com/pingidentity/ping-cloud-base}"
export K8S_GIT_BRANCH="${K8S_GIT_BRANCH:-master}"

export REGISTRY_NAME="${REGISTRY_NAME:-docker.io}"

export SSH_ID_PUB_FILE="${SSH_ID_PUB_FILE}"
export SSH_ID_KEY_FILE="${SSH_ID_KEY_FILE}"

export TARGET_DIR="${TARGET_DIR:-/tmp/sandbox}"
export IS_BELUGA_ENV="${IS_BELUGA_ENV}"

# Print out the values being used for each variable.
echo "Using TENANT_NAME: ${TENANT_NAME}"
echo "Using TENANT_DOMAIN: ${TENANT_DOMAIN}"
echo "Using REGION: ${REGION}"
echo "Using SIZE: ${SIZE}"

echo "Using CLUSTER_STATE_REPO_URL: ${CLUSTER_STATE_REPO_URL}"

echo "Using CONFIG_REPO_URL: ${CONFIG_REPO_URL}"
echo "Using CONFIG_REPO_BRANCH: ${CONFIG_REPO_BRANCH}"

echo "Using ARTIFACT_REPO_URL: ${ARTIFACT_REPO_URL}"
echo "Using LOG_ARCHIVE_URL: ${LOG_ARCHIVE_URL}"

echo "Using K8S_GIT_URL: ${K8S_GIT_URL}"
echo "Using K8S_GIT_BRANCH: ${K8S_GIT_BRANCH}"

echo "Using REGISTRY_NAME: ${REGISTRY_NAME}"

echo "Using SSH_ID_PUB_FILE: ${SSH_ID_PUB_FILE}"
echo "Using SSH_ID_KEY_FILE: ${SSH_ID_KEY_FILE}"

echo "Using TARGET_DIR: ${TARGET_DIR}"
echo "Using IS_BELUGA_ENV: ${IS_BELUGA_ENV}"
echo ---

export PING_IDENTITY_DEVOPS_USER_BASE64=$(base64_no_newlines "${PING_IDENTITY_DEVOPS_USER}")
export PING_IDENTITY_DEVOPS_KEY_BASE64=$(base64_no_newlines "${PING_IDENTITY_DEVOPS_KEY}")

SCRIPT_HOME=$(cd $(dirname ${0}); pwd)
TEMPLATES_HOME="${SCRIPT_HOME}/templates"

# Generate an SSH key pair for flux CD.
if test -z "${SSH_ID_PUB_FILE}" && test -z "${SSH_ID_KEY_FILE}"; then
  echo 'Generating key-pair for SSH access'
  generate_ssh_key_pair
elif test -z "${SSH_ID_PUB_FILE}" || test -z "${SSH_ID_KEY_FILE}"; then
  echo 'Provide SSH key-pair files via SSH_ID_PUB_FILE/SSH_ID_KEY_FILE env vars, or omit both for key-pair to be generated'
  exit 1
else
  echo 'Using provided key-pair for SSH access'
  export SSH_ID_PUB=$(cat "${SSH_ID_PUB_FILE}")
  export SSH_ID_KEY_BASE64=$(base64_no_newlines "${SSH_ID_KEY_FILE}")
fi

# Get the known hosts contents for the cluster state repo host to pass it into flux.
parse_url "${CLUSTER_STATE_REPO_URL}"
echo "Obtaining known_hosts contents for cluster state repo host: ${URL_HOST}"
export KNOWN_HOSTS_CLUSTER_STATE_REPO=$(ssh-keyscan -H "${URL_HOST}" 2> /dev/null)

parse_url "${CONFIG_REPO_URL}"
echo "Obtaining known_hosts contents for config repo host: ${URL_HOST}"
export KNOWN_HOSTS_CONFIG_REPO=$(ssh-keyscan -H "${URL_HOST}" 2> /dev/null)

# Delete existing target directory and re-create it
rm -rf "${TARGET_DIR}"
mkdir -p "${TARGET_DIR}"

# Next build up the directory structure of the cluster-state repo
FLUXCD_DIR="${TARGET_DIR}/fluxcd"
mkdir -p "${FLUXCD_DIR}"

K8S_CONFIGS_DIR="${TARGET_DIR}/k8s-configs"
mkdir -p "${K8S_CONFIGS_DIR}"

# Now generate the yaml files for each environment
ENVIRONMENTS='dev test stage prod'

for ENV in ${ENVIRONMENTS}; do
  # Export all the environment variables required for envsubst
  export ENVIRONMENT_GIT_PATH=${ENV}

  # The base URL for kustomization files and environment will be different for each CDE.
  case "${ENV}" in
    dev | test)
      export KUSTOMIZE_BASE='test'
      ;;
    stage)
      export KUSTOMIZE_BASE='prod/small'
      ;;
    prod)
      export KUSTOMIZE_BASE="prod/${SIZE}"
      ;;
  esac

  if test "${IS_BELUGA_ENV}" = 'true'; then
    export CLUSTER_NAME="${TENANT_NAME}"
    export PING_CLOUD_NAMESPACE="ping-cloud-${ENV}"
    export DNS_RECORD_SUFFIX="-${ENV}"
    export DNS_DOMAIN_PREFIX=''
  else
    export CLUSTER_NAME="${ENV}"
    export PING_CLOUD_NAMESPACE='ping-cloud'
    export DNS_RECORD_SUFFIX=''
    export DNS_DOMAIN_PREFIX="${ENV}-"
  fi

  echo ---
  echo "For environment ${ENV}, using variable values:"
  echo "ENVIRONMENT_GIT_PATH: ${ENVIRONMENT_GIT_PATH}"
  echo "KUSTOMIZE_BASE: ${KUSTOMIZE_BASE}"
  echo "CLUSTER_NAME: ${CLUSTER_NAME}"
  echo "PING_CLOUD_NAMESPACE: ${PING_CLOUD_NAMESPACE}"
  echo "DNS_RECORD_SUFFIX: ${DNS_RECORD_SUFFIX}"
  echo "DNS_DOMAIN_PREFIX: ${DNS_DOMAIN_PREFIX}"

  # Generate a self-signed cert for the tenant domain.
  FQDN="${DNS_DOMAIN_PREFIX}${TENANT_DOMAIN}"
  echo "Generating certificate for domain: ${FQDN}"
  generate_tls_cert "${FQDN}"

  # Build the flux kustomization file for each environment
  echo "Generating flux yaml"

  ENV_FLUX_DIR="${FLUXCD_DIR}/${ENV}"
  mkdir -p "${ENV_FLUX_DIR}"

  cp "${TEMPLATES_HOME}"/fluxcd/* "${ENV_FLUX_DIR}"

  substitute_vars "${ENV_FLUX_DIR}"

  # Copy the shared cluster tools and Ping yaml templates into their target directories
  echo "Generating tools and ping yaml"

  ENV_DIR="${K8S_CONFIGS_DIR}/${ENV}"
  mkdir -p "${ENV_DIR}"

  cp -r "${TEMPLATES_HOME}"/cluster-tools "${ENV_DIR}"
  cp -r "${TEMPLATES_HOME}"/ping-cloud "${ENV_DIR}"

  # Copy the base files into the environment directory
  find "${TEMPLATES_HOME}" -type f -maxdepth 1 | xargs -I {} cp {} "${ENV_DIR}"

  ### Start some special-handling based on BELUGA environment and CDE type ###

  # If Beluga environment, we want:
  #
  #   - All URLs to land on a public subnet, so a VPN/bridge network is not
  #     required to access them.
  #   - The namespace for the ping stack for the environment to be created and
  #     the stock ping-cloud namespace to be deleted.
  #
  NGINX_FILE_TO_PATCH="${ENV_DIR}/cluster-tools/service-nginx-private-patch.yaml.tmpl"
  PD_FILE_TO_PATCH="${ENV_DIR}/ping-cloud/pingdirectory-ldap-endpoint-patch.yaml.tmpl"

  NAMESPACE_COMMENT="# All ping resources will live in the ${PING_CLOUD_NAMESPACE} namespace"
  if test "${IS_BELUGA_ENV}" = 'true'; then
    export PING_CLOUD_NAMESPACE_RESOURCE="${NAMESPACE_COMMENT}
- namespace.yaml"

    export DELETE_PING_CLOUD_NAMESPACE_PATCH_MERGE='### Delete ping-cloud namespace ###

- |-
  apiVersion: v1
  kind: Namespace
  metadata:
    name: ping-cloud
  $patch: delete'

    export SERVICE_NGINX_PRIVATE_PATCH=$(patch_remove_file "${NGINX_FILE_TO_PATCH}")
    export PING_DIRECTORY_LDAP_ENDPOINT_PATCH=$(patch_remove_file "${PD_FILE_TO_PATCH}")

  else
    export PING_CLOUD_NAMESPACE_RESOURCE="${NAMESPACE_COMMENT}"
    export DELETE_PING_CLOUD_NAMESPACE_PATCH_MERGE=''
    rm -f "${ENV_DIR}"/ping-cloud/namespace.yaml.tmpl

    export SERVICE_NGINX_PRIVATE_PATCH=''
    rm -f "${NGINX_FILE_TO_PATCH}"

    export PING_DIRECTORY_LDAP_ENDPOINT_PATCH=''
    rm -f "${PD_FILE_TO_PATCH}"
  fi

  # If it's a dev/test environment, then the pingdataconsole ingress must be kustomized.
  CONSOLE_FILE_TO_PATCH="${ENV_DIR}/ping-cloud/pingdataconsole-ingress-patch.yaml.tmpl"
  if test "${ENV}" = 'test' || test "${ENV}" = 'dev'; then
    export PING_DATA_CONSOLE_INGRESS_PATCH=$(patch_remove_file "${CONSOLE_FILE_TO_PATCH}")
  else
    export PING_DATA_CONSOLE_INGRESS_PATCH=''
    rm -f "${CONSOLE_FILE_TO_PATCH}"
  fi

  ### End special handling ###

  substitute_vars "${ENV_DIR}"
done

# Go back to previous working directory, if different
popd > /dev/null

echo
echo '------------------------'
echo '|  Next steps to take  |'
echo '------------------------'
echo "1) Push the ${TARGET_DIR}/k8s-configs directory onto the master branch of the tenant cluster-state repo:"
echo "${CLUSTER_STATE_REPO_URL}"
echo
echo "2) Add the following identity as the deploy key on the cluster-state (rw) and config repo (ro), if not already added:"
echo "${SSH_ID_PUB}"
echo
echo "3) Deploy flux onto each CDE by navigating to ${TARGET_DIR}/fluxcd and running:"
echo 'kustomize build | kubectl apply -f -'