set -o errexit
set -o nounset
set -x

REPO_ROOT=$(realpath $(dirname "${BASH_SOURCE[0]}")/../..)

cleanup() {
  if [ -n ${KUBECONFIG:-} ]; then
      kubectl get node -owide || echo "Unable to get nodes"
      kubectl get pod --all-namespaces=true -owide || echo "Unable to get pods"
  fi
  echo "gc the aks cluster"
  az aks delete -g "${RESOURCE_GROUP:-}" -n "${CLUSTER_NAME:-}" --yes
  az group delete -n "${RESOURCE_GROUP:-}" --yes
  rm -rf "k8s-conformance" --yes
  rm -rf "aks.kubeconfig" --yes
  rm -rf "results" --yes
}
trap cleanup EXIT

echo "Create an AKS cluster"
RESOURCE_GROUP="autogen-k8s-conformance-${GITHUB_ACCOUNT:-}-${AKS_VERSION:-}"
CLUSTER_NAME="aks"
AZURE_LOCATION="eastus2"

az group create --name "${RESOURCE_GROUP:-}" --location "${AZURE_LOCATION:-}"
az aks create -g "${RESOURCE_GROUP:-}" -n "${CLUSTER_NAME:-}" -k "${AKS_VERSION:-v1.25.4}" --node-count 2 --generate-ssh-keys
az aks get-credentials --resource-group "${RESOURCE_GROUP:-}" --name "${CLUSTER_NAME:-}" -f "aks.kubeconfig"
export KUBECONFIG="aks.kubeconfig"
kubectl get node -owide || echo "Unable to get nodes"

echo "Run conformance test"
go install github.com/vmware-tanzu/sonobuoy@latest
sonobuoy run --mode=certified-conformance --wait
sonobuoy status
sonobuoy logs
sonobuoy retrieve ./results -f sonobuoy_result.tar.gz
SONOBUOY_RESULT_PATH="results/sonobuoy_result.tar.gz"
tar zxf "${SONOBUOY_RESULT_PATH}" -C results

echo "Check test result"
SONOBUOY_RESULT_SUMMARY_PATH="results/sonobuoy_result_summary"
sonobuoy results "${SONOBUOY_RESULT_PATH}" > "${SONOBUOY_RESULT_SUMMARY_PATH}"
if grep -q "Failed tests:" "${SONOBUOY_RESULT_SUMMARY_PATH}"; then
  echo "AKS ${AKS_VERSION:-} conformance test failed"
  exit 1
fi

echo "Commit the change"
K8S_VERSION="$(echo ${AKS_VERSION:-}|cut -f-2 -d.)"
git clone "https://${GITHUB_ACCOUNT:-}:${GITHUB_TOKEN:-}@github.com/${GITHUB_ACCOUNT:-}/k8s-conformance.git"
mkdir -p "k8s-conformance/${K8S_VERSION:-}/aks"
cp ./results/plugins/e2e/results/global/e2e.log "k8s-conformance/${K8S_VERSION:-}/aks" || true
cp ./results/plugins/e2e/results/global/junit_01.xml "k8s-conformance/${K8S_VERSION:-}/aks" || true
cp "templates/PRODUCT.yaml" "k8s-conformance/${K8S_VERSION:-}/aks" || true
cp "templates/README.md" "k8s-conformance/${K8S_VERSION:-}/aks" || true

sed -i "s|{AKS_VERSION}|${AKS_VERSION:-}|g" "k8s-conformance/${K8S_VERSION:-}/aks/PRODUCT.yaml"
sed -i "s|{EMAIL}|${EMAIL:-}|g" "k8s-conformance/${K8S_VERSION:-}/aks/PRODUCT.yaml"
sed -i "s|{AKS_VERSION}|${AKS_VERSION:-}|g" "k8s-conformance/${K8S_VERSION:-}/aks/README.md"

pushd "k8s-conformance"
BRANCH_NAME="aks_conformance_test_result_for_${AKS_VERSION:-}"
git config --global user.name "${GITHUB_ACCOUNT}"
git config --global user.email "${EMAIL}"
git remote set-url origin "https://${GITHUB_ACCOUNT:-}:${GITHUB_TOKEN:-}@github.com/${GITHUB_ACCOUNT:-}/k8s-conformance.git"
git checkout -b "${BRANCH_NAME:-}"
git add "${K8S_VERSION:-}/aks"
git commit -m "Conformance results for ${K8S_VERSION:-}/AKS" -s
git push origin "${BRANCH_NAME:-}" --force
popd

echo "AKS ${AKS_VERSION:-} conformance test finished"
