#!/usr/bin/env bash
# set -x
set -e

SCRIPT_NAME="$(basename $0)"

while getopts ":a:d:k:o:t:u:h" arg; do
  case $arg in
  a) ACTION=$OPTARG ;;
  d) CONFIG_DIR=$OPTARG ;;
  h)
    printf "Usage:\n"
    printf "%s -a ACTION -d CONFIG_DIR -k KUBECONFIG -o ORG -t PRIVATE_KEY_TEMPLATE -u USERNAME\n" "$SCRIPT_NAME"
    printf "\n"
    printf "\t\t-a\tAction (apply|delete)\n"
    printf "\t\t-d\tDirectory to store configs\n"
    printf "\t\t-h\tDisplay help\n"
    printf "\t\t-k\tPath to KUBECONFIG\n"
    printf "\t\t-o\tOrg name for SSL cert\n"
    printf "\t\t-t\tPath to PRIVATE_KEY_TEMPLATE\n"
    printf "\t\t-u\tUSERNAME to create\n"
    exit 0
    ;;
  k) KUBECONFIG=$OPTARG ;;
  o) ORG=$OPTARG ;;
  t) PRIVATE_KEY_TEMPLATE=$OPTARG ;;
  u) USERNAME=$OPTARG ;;
  \?)
    echo "Invalid Option: -$OPTARG" 1>&2
    exit 1
    ;;
  esac
done

# Ensure all required arguments are passed
if [[ $ACTION != "" ]] && [[ $KUBECONFIG != "" ]] && [[ $USERNAME != "" ]] && [[ $CONFIG_DIR != "" ]] && [[ $PRIVATE_KEY_TEMPLATE != "" ]] && [[ $ORG != "" ]]; then
  # Convert to lowercase as Kubernetes requires namespaces, etc. to be lowercase
  USERNAME=$(echo "$USERNAME" | awk '{print tolower($0)}')
  # Location for certs, configs, etc. to be stored
  KUBE_CONFIG_DIR="$CONFIG_DIR/$USERNAME"

  # Create Kube config directory if it doesn't exist
  if [[ ! -d "$KUBE_CONFIG_DIR" ]]; then
    mkdir -p "$KUBE_CONFIG_DIR"
  fi

  # User's KUBECONFIG file
  USER_KUBECONFIG="$KUBE_CONFIG_DIR/config"

  CONTEXTS=$(kubectl config view --kubeconfig="$KUBECONFIG" -o json | jq '.contexts')
  CLUSTERS=$(kubectl config view --kubeconfig="$KUBECONFIG" -o json | jq '.clusters')
  for context in $(echo "${CONTEXTS}" | jq -r '.[] | @base64'); do
    _jq() {
      echo "$context" | base64 --decode | jq -r "${1}"
    }
    # Use context name
    kubectl config use-context "$(_jq '.name')"
    # Get cluster name from context
    KUBE_CLUSTER_NAME=$(_jq '.context.cluster')
    # Export cluster name in order for jq to access the environment variable
    export KUBE_CLUSTER_NAME
    # Get cluster server for context used
    KUBE_CLUSTER_SERVER=$(echo "$CLUSTERS" | jq '.[]|select(.name==env.KUBE_CLUSTER_NAME)|.cluster.server')
    # Strip quotes from cluster server
    KUBE_CLUSTER_SERVER="$(echo "$KUBE_CLUSTER_SERVER" | tr -d '"')"
    # Define cluster cert
    KUBE_CLUSTER_CA_CERT="$KUBE_CONFIG_DIR/$KUBE_CLUSTER_NAME-ca.pem"

    # Get cluster certificate if it does not exist and save it
    if [[ ! -f $KUBE_CLUSTER_CA_CERT ]]; then
      kubectl config view --kubeconfig="$KUBECONFIG" -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' --raw | base64 --decode - >"$KUBE_CLUSTER_CA_CERT"
    fi

    USER_CLIENT_CRT="$KUBE_CONFIG_DIR/$USERNAME-$KUBE_CLUSTER_NAME.pem"
    USER_CLIENT_KEY="$KUBE_CONFIG_DIR/$USERNAME-$KUBE_CLUSTER_NAME-key.pem"
    USER_CLIENT_CSR="$KUBE_CONFIG_DIR/$USERNAME-$KUBE_CLUSTER_NAME.csr"
    USER_NAMESPACE="$USERNAME-$KUBE_CLUSTER_NAME"
    # If client certificate signing request does not exist: create and apply
    if [[ ! -f "$USER_CLIENT_CSR" ]]; then
      export USERNAME
      export ORG
      envsubst <"$PRIVATE_KEY_TEMPLATE" | cfssl genkey - | cfssljson -bare "${USER_CLIENT_CSR%.*}"
      cat <<EOF | kubectl "$ACTION" --kubeconfig="$KUBECONFIG" -f -
    apiVersion: certificates.k8s.io/v1beta1
    kind: CertificateSigningRequest
    metadata:
      name: $USERNAME
    spec:
      username: $USERNAME
      groups:
      - system:authenticated
      request: $(cat "$USER_CLIENT_CSR" | base64 | tr -d '\n')
      usages:
      - digital signature
      - key encipherment
      - client auth
EOF
      kubectl certificate approve "$USERNAME" --kubeconfig="$KUBECONFIG"
    fi
    # Get user certificate from cluster if it does not exist
    if [[ ! -f "$USER_CLIENT_CRT" ]]; then
      kubectl get csr "$USERNAME" --kubeconfig="$KUBECONFIG" -o jsonpath='{.status.certificate}' | base64 --decode >"$USER_CLIENT_CRT"
    fi
    # Generate user's KUBECONFIG
    kubectl config set-cluster "$KUBE_CLUSTER_NAME" --server="$KUBE_CLUSTER_SERVER" --certificate-authority="$KUBE_CLUSTER_CA_CERT" --kubeconfig="$USER_KUBECONFIG" --embed-certs
    kubectl config set-credentials "$USERNAME-$KUBE_CLUSTER_NAME" --client-certificate="$USER_CLIENT_CRT" --client-key="$USER_CLIENT_KEY" --embed-certs --kubeconfig="$USER_KUBECONFIG"
    kubectl config set-context "$USER_NAMESPACE" --cluster="$KUBE_CLUSTER_NAME" --namespace="$USER_NAMESPACE" --user="$USERNAME-$KUBE_CLUSTER_NAME" --kubeconfig="$USER_KUBECONFIG"

    # Manage users cluster namespace
    cat <<EOF | kubectl "$ACTION" --kubeconfig="$KUBECONFIG" -f -
  apiVersion: v1
  kind: Namespace
  metadata:
    name: $USER_NAMESPACE
EOF

    cat <<EOF >"$KUBE_CONFIG_DIR"/"$USERNAME"-"$KUBE_CLUSTER_NAME"-rbac-access.yaml
# RBACDefinition for cluster: $KUBE_CLUSTER_NAME
apiVersion: rbacmanager.reactiveops.io/v1beta1
kind: RBACDefinition
metadata:
    name: $USERNAME-access
rbacBindings:
- name: $USERNAME
  subjects:
  - kind: User
    name: $USERNAME
  roleBindings:
  - namespace: $USER_NAMESPACE
    clusterRole: admin
EOF
  done

else
  printf "Ensure to pass -a ACTION -d CONFIG_DIR -k KUBECONFIG -t PRIVATE_KEY_TEMPLATE -u USERNAME"
  exit 1
fi
