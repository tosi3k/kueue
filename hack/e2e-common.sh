#!/usr/bin/env bash

# Copyright 2023 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export KUSTOMIZE="$ROOT_DIR"/bin/kustomize
export GINKGO="$ROOT_DIR"/bin/ginkgo
export KIND="$ROOT_DIR"/bin/kind
export YQ="$ROOT_DIR"/bin/yq

export JOBSET_MANIFEST="https://github.com/kubernetes-sigs/jobset/releases/download/${JOBSET_VERSION}/manifests.yaml"
export JOBSET_IMAGE=registry.k8s.io/jobset/jobset:${JOBSET_VERSION}
export JOBSET_CRDS=${ROOT_DIR}/dep-crds/jobset-operator/

export KUBEFLOW_MANIFEST_MANAGER=${ROOT_DIR}/test/e2e/config/multikueue/manager
export KUBEFLOW_MANIFEST_WORKER=${ROOT_DIR}/test/e2e/config/multikueue/worker
KUBEFLOW_IMAGE_VERSION=$($KUSTOMIZE build "$KUBEFLOW_MANIFEST_WORKER" | $YQ e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image | split(":") | .[1]')
export KUBEFLOW_IMAGE_VERSION
export KUBEFLOW_IMAGE=kubeflow/training-operator:${KUBEFLOW_IMAGE_VERSION}

export KUBEFLOW_MPI_MANIFEST="https://raw.githubusercontent.com/kubeflow/mpi-operator/${KUBEFLOW_MPI_VERSION}/deploy/v2beta1/mpi-operator.yaml"
export KUBEFLOW_MPI_IMAGE=mpioperator/mpi-operator:${KUBEFLOW_MPI_VERSION/#v}
export KUBEFLOW_MPI_CRD=${ROOT_DIR}/dep-crds/mpi-operator/kubeflow.org_mpijobs.yaml

# sleep image to use for testing.
export E2E_TEST_IMAGE=gcr.io/k8s-staging-perf-tests/sleep:v0.1.0@sha256:8d91ddf9f145b66475efda1a1b52269be542292891b5de2a7fad944052bab6ea

# $1 - cluster name
function cluster_cleanup {
	kubectl config use-context "kind-$1"
        $KIND export logs "$ARTIFACTS" --name "$1" || true
        kubectl describe pods -n kueue-system > "$ARTIFACTS/$1-kueue-system-pods.log" || true
        kubectl describe pods > "$ARTIFACTS/$1-default-pods.log" || true
        $KIND delete cluster --name "$1"
}

# $1 cluster name
# $2 cluster kind config
function cluster_create {
        $KIND create cluster --name "$1" --image "$E2E_KIND_VERSION" --config "$2" --wait 1m -v 5  > "$ARTIFACTS/$1-create.log" 2>&1 \
		||  { echo "unable to start the $1 cluster "; cat "$ARTIFACTS/$1-create.log" ; }
	kubectl config use-context "kind-$1"
        kubectl get nodes > "$ARTIFACTS/$1-nodes.log" || true
        kubectl describe pods -n kube-system > "$ARTIFACTS/$1-system-pods.log" || true
}

# $1 cluster
function cluster_kind_load {
	e2e_test_sleep_image_without_sha=${E2E_TEST_IMAGE%%@*}
	# We can load image by a digest but we cannot reference it by the digest that we pulled.
	# For more information https://github.com/kubernetes-sigs/kind/issues/2394#issuecomment-888713831.
	# Manually create tag for image with digest which is already pulled
	docker tag $E2E_TEST_IMAGE "$e2e_test_sleep_image_without_sha"
	cluster_kind_load_image "$1" "${e2e_test_sleep_image_without_sha}"
	cluster_kind_load_image "$1" "$IMAGE_TAG"
}

# $1 cluster
# $2 image
function cluster_kind_load_image {
        $KIND load docker-image "$2" --name "$1"
}

# $1 cluster
function cluster_kueue_deploy {
    kubectl config use-context "kind-${1}"
    kubectl apply --server-side -k test/e2e/config
}

#$1 - cluster name
function install_jobset {
    cluster_kind_load_image "${1}" "${JOBSET_IMAGE}"
    kubectl config use-context "kind-${1}"
    kubectl apply --server-side -f "${JOBSET_MANIFEST}"
}

#$1 - cluster name
function install_kubeflow {
    cluster_kind_load_image "${1}" "${KUBEFLOW_IMAGE}"
    kubectl config use-context "kind-${1}"
    kubectl apply -k "${KUBEFLOW_MANIFEST_WORKER}"
}

#$1 - cluster name
function install_mpi {
    cluster_kind_load_image "${1}" "${KUBEFLOW_MPI_IMAGE/#v}"
    kubectl config use-context "kind-${1}"
    kubectl apply --server-side -f "${KUBEFLOW_MPI_MANIFEST}"
}

INITIAL_IMAGE=$($YQ '.images[] | select(.name == "controller") | [.newName, .newTag] | join(":")' config/components/manager/kustomization.yaml)
export INITIAL_IMAGE

function restore_managers_image {
    (cd config/components/manager && $KUSTOMIZE edit set image controller="$INITIAL_IMAGE")
}
