#!/bin/bash

. "${PROJECT_DIR}"/ci-scripts/common.sh "${1}"

if skipTest "${0}"; then
  log "Skipping test ${0}"
  exit 0
fi


expected_files() {
  UPLOAD_CSD_JOB_PODS=$(kubectl get pod -o name -n "${NAMESPACE}" -o name | grep "${1}" | cut -d/ -f2)
  for UPLOAD_CSD_JOB_POD in $UPLOAD_CSD_JOB_PODS
  do
    kubectl logs -n "${NAMESPACE}" ${UPLOAD_CSD_JOB_POD} |
    tail -1 |
    tr ' ' '\n' |
    sort
  done
}

actual_files() {
  BUCKET_URL_NO_PROTOCOL=${LOG_ARCHIVE_URL#s3://}
  BUCKET_NAME=$(echo "${BUCKET_URL_NO_PROTOCOL}" | cut -d/ -f1)
  DAYS_AGO=1
  DIRECTORY_NAME=pingaccess

  aws s3api list-objects \
    --bucket "${BUCKET_NAME}" \
    --prefix "${DIRECTORY_NAME}/support-data" \
    --query "reverse(sort_by(Contents[?LastModified>='${DAYS_AGO}'], &LastModified))[].Key" \
    --profile "${AWS_PROFILE}" |
  tr -d '",[]' |
  cut -d/ -f2 |
  sort
}

testPingAccessRuntimeCsdUpload() {

    UPLOAD_CSD_JOB_NAME=pingaccess-periodic-csd-upload
    UPLOAD_JOB="${PROJECT_DIR}/k8s-configs/ping-cloud/base/pingaccess/aws/periodic-csd-upload.yaml"

    log "Applying the CSD upload job"
    kubectl delete -f "${UPLOAD_JOB}" -n "${NAMESPACE}"
    kubectl apply -f "${UPLOAD_JOB}" -n "${NAMESPACE}"
    kubectl create job --from=cronjob/${UPLOAD_CSD_JOB_NAME} ${UPLOAD_CSD_JOB_NAME} -n "${NAMESPACE}"

    log "Waiting for CSD upload job to complete"
    kubectl wait --for=condition=complete --timeout=900s job.batch/${UPLOAD_CSD_JOB_NAME} -n "${NAMESPACE}"

    log "Expected CSD files:"
    expected_files "${UPLOAD_CSD_JOB_NAME}" | tee /tmp/expected.txt

    log "Actual CSD files:"
    actual_files | tee /tmp/actual.txt

    log "Verifying that the expected files were uploaded"
    NOT_UPLOADED=$(comm -23 /tmp/expected.txt /tmp/actual.txt)

    if ! test -z "${NOT_UPLOADED}"; then
      # Explicitly make this test fail so shunit2 knows how to process
      # the failure and print the message
      assertEquals "The following files were not uploaded: ${NOT_UPLOADED}" 0 1
    fi

    # Signal success to shunit2
    assertEquals 0 0
}

testPingAccessAdminCsdUpload() {

    UPLOAD_CSD_JOB_NAME=pingaccess-admin-periodic-csd-upload
    UPLOAD_JOB="${PROJECT_DIR}/k8s-configs/ping-cloud/base/pingaccess/aws/periodic-csd-upload.yaml"

    log "Applying the CSD upload job"
    kubectl delete -f "${UPLOAD_JOB}" -n "${NAMESPACE}"
    kubectl apply -f "${UPLOAD_JOB}" -n "${NAMESPACE}"
    kubectl create job --from=cronjob/${UPLOAD_CSD_JOB_NAME} ${UPLOAD_CSD_JOB_NAME} -n "${NAMESPACE}"

    log "Waiting for CSD upload job to complete"
    kubectl wait --for=condition=complete --timeout=900s job.batch/${UPLOAD_CSD_JOB_NAME} -n "${NAMESPACE}"

    log "Expected CSD files:"
    expected_files "${UPLOAD_CSD_JOB_NAME}" | tee /tmp/expected.txt

    log "Actual CSD files:"
    actual_files | tee /tmp/actual.txt

    log "Verifying that the expected files were uploaded"
    NOT_UPLOADED=$(comm -23 /tmp/expected.txt /tmp/actual.txt)

    if ! test -z "${NOT_UPLOADED}"; then
      # Explicitly make this test fail so shunit2 knows how to process
      # the failure and print the message
      assertEquals "The following files were not uploaded: ${NOT_UPLOADED}" 0 1
    fi

    # Signal success to shunit2
    assertEquals 0 0
}

# When arguments are passed to a script you must
# consume all of them before shunit is invoked
# or your script won't run.  For integration
# tests, you need this line.
shift $#

# load shunit
. ${SHUNIT_PATH}