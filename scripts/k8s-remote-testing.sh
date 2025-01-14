#!/bin/bash

set -eo pipefail

function f_log() {
  echo "******************************************************************"
  echo "** $*"
}

function f_show_help() {
  f_log "Supported arguments are:"
  echo "${0} (-n|--namespace) '<namespace>' (-t|--test) 'aeron-echo' (-m|--media-driver) 'dpdk'"
}

while [[ $# -gt 0 ]]
do
  option="${1}"
  case ${option} in
    -n|--namespace)
      K8S_NAMESPACE="${2}"
      shift
      shift
      ;;
    -t|--test)
      TEST_TO_RUN="${2}"
      if [[ "${TEST_TO_RUN}" != "aeron-echo" ]]
      then
        f_log "Error: only supported test is 'aeron-echo' at the moment"
        exit 1
      fi
      shift
      shift
      ;;
    -m|--media-driver)
      MEDIA_DRIVER="${2}"
      if [[ "${MEDIA_DRIVER}" != "dpdk" ]]
      then
        f_log "Error: only supported media driver is 'dpdk' at the moment"
        exit 1
      fi
      shift
      shift
      ;;
    -h|--help)
      f_show_help
      EXIT
      ;;
    *)
      echo "Error, unknown argument: ${option}"
      f_show_help
      exit 1
      ;;
  esac
done

# Standard vars
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
TEST_TO_RUN="${TEST_TO_RUN:-aeron-echo}"
MEDIA_DRIVER="${MEDIA_DRIVER:-dpdk}"

TIMESTAMP="$(date +"%Y-%m-%d-%H-%M-%S")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "${SCRIPT_DIR}"

function f_cleanup_k8s() {
  f_log "Deleting old benchmark setup"
  kubectl -n "${K8S_NAMESPACE}" delete --wait=true -k k8s/ || true
  kubectl -n "${K8S_NAMESPACE}" delete --wait=true endpointslices.discovery.k8s.io/aeron-benchmark-md1 || true
  kubectl -n "${K8S_NAMESPACE}" wait --for=delete endpointslices.discovery.k8s.io/aeron-benchmark-md1 --timeout=60s || true
  kubectl -n "${K8S_NAMESPACE}" wait --for=delete pod/aeron-benchmark-0 --timeout=60s || true
  kubectl -n "${K8S_NAMESPACE}" wait --for=delete pod/aeron-benchmark-1 --timeout=60s || true
}

# Delete the old incarnation of the pods
f_cleanup_k8s

# Generate new test pods
f_log "Generating new benchmark setup for: ${TEST_TO_RUN}"
case ${TEST_TO_RUN} in
  aeron-echo)
    TEST_CUSTOMISATION="
---
# This file is dynamically updated by the benchmarking script
# Any modifications will be lost
apiVersion: v1
kind: Pod
metadata:
  name: all
spec:
  containers:
    - name: benchmark
      args:
        - './benchmark-runner'
        - '--output-file'
        - 'aeron-echo_c-dpdk-k8s'
        - '--message-rate'
        - '100K'
        - '--message-length'
        - '288'
        - '--iterations'
        - '30'
        - 'aeron/echo-client'
"
    echo "${TEST_CUSTOMISATION}" > "${SCRIPT_DIR}/k8s/k8s-test-customisation.yml"
    ;;
  *)
    f_log "Unknown test case: ${TEST_TO_RUN}"
    ;;
esac


kubectl -n "${K8S_NAMESPACE}" apply --wait=true -k k8s/
kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready pod/aeron-benchmark-0
kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready pod/aeron-benchmark-1

# DPDK Media Driver
if [[ "${MEDIA_DRIVER}" == "dpdk" ]]
then
  AB0_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec -it aeron-benchmark-0 -c aeronmd-dpdk -- bash -c 'echo ${PCIDEVICE_INTEL_COM_AWS_DPDK_INFO}' | jq -r '.. | ."IPV4_ADDRESS"? | select(. != null)')"
  AB1_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec -it aeron-benchmark-1 -c aeronmd-dpdk -- bash -c 'echo ${PCIDEVICE_INTEL_COM_AWS_DPDK_INFO}' | jq -r '.. | ."IPV4_ADDRESS"? | select(. != null)')"
# Java Media Driver
elif [[ "${MEDIA_DRIVER}" == "java" ]]
  then
  AB0_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" get po  aeron-benchmark-0  -o json | jq -r ".status.podIP")"
  AB1_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" get po  aeron-benchmark-1  -o json | jq -r ".status.podIP")"
else
  f_log "No available media-driver config"
  exit 1
fi

f_log "Found Media driver IPs:"
echo "aeron-benchmark-0: ${AB0_MD_IP}"
echo "aeron-benchmark-1: ${AB1_MD_IP}"


# Generate endpoint slice with IPs
# Because we can use interfaces that have no obvious IPs, we need to have a way to generate DNS records for the test.
f_log "Generating endpointslice with DNS for media driver IPs"
ENDPOINT_SLICE="
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: aeron-benchmark-md1
  labels:
    kubernetes.io/service-name: aeron-benchmark-md
addressType: IPv4
ports:
  # Port/protocol is irrelevant as this is a headless service
  - port: 10000
    name: ''
    protocol: UDP
endpoints:
  - addresses:
      - ${AB0_MD_IP}
    hostname: aeron-benchmark-0
  - addresses:
      - ${AB1_MD_IP}
    hostname: aeron-benchmark-1
"

# Inject endpoint slice
echo "${ENDPOINT_SLICE}" | kubectl -n "${K8S_NAMESPACE}" apply -f -

# When the benchmark finishes, the benchmark containers stop, generating a NotReady condition
f_log "Waiting for benchmarks to finish"
kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready=false --timeout=360s pod/aeron-benchmark-0
kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready=false --timeout=360s pod/aeron-benchmark-1

f_log "Benchmarks finished, showing logs"

# Show the raw output
kubectl -n "${K8S_NAMESPACE}" logs -c benchmark aeron-benchmark-1

f_log "Collecting data"
mkdir -p "results/${TIMESTAMP}"

# Copy the tarball of results over
kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-benchmark-0:/dev/shm/results.tar.gz "results/${TIMESTAMP}/results-0.tar.gz"
kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-benchmark-1:/dev/shm/results.tar.gz "results/${TIMESTAMP}/results-1.tar.gz"

# Extract the useful files
for tarfile in results-1.tar.gz
do
    tar -C "results/${TIMESTAMP}" --strip-components=1 --wildcards -xf "results/${TIMESTAMP}/${tarfile}" '*.png'
    tar -C "results/${TIMESTAMP}" --strip-components=1 --wildcards -xf "results/${TIMESTAMP}/${tarfile}" '*.hgrm'
done

f_log "Results collected in: ${SCRIPT_DIR}/results/${TIMESTAMP}"

f_cleanup_k8s
