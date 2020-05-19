#!/usr/bin/env bash
set -x
set -e

SCRIPT_NAME="$(basename $0)"

while getopts ":a:d:k:o:t:u:h" arg; do
  case $arg in
  a) ACTION=$OPTARG ;;
  d) CONFIG_DIR=$OPTARG ;;
  h)
    echo "Usage:"
    echo "      $SCRIPT_NAME -a ACTION -d CONFIG_DIR -k KUBECONFIG -o ORG -t PRIVATE_KEY_TEMPLATE -u USERNAME"
    echo ""
    echo "      \t\t-a\tAction (apply|delete)"
    echo "      \t\t-d\tDirectory to store configs"
    echo "      \t\t-h\tDisplay help"
    echo "      \t\t-k\tPath to KUBECONFIG"
    echo "      \t\t-o\tOrg name for SSL cert"
    echo "      \t\t-t\tPath to PRIVATE_KEY_TEMPLATE"
    echo "      \t\t-u\tUSERNAME to create"
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
  KUBE_CONFIG_DIR="$CONFIG_DIR/$USERNAME/.kube"

  # Create Kube config directory if it doesn't exist
  if [[ ! -d "$KUBE_CONFIG_DIR" ]]; then
    mkdir -p "$KUBE_CONFIG_DIR"
  fi

  # User's KUBECONFIG file
  USER_KUBECONFIG="$KUBE_CONFIG_DIR/config"

  CONTEXTS=("$(kubectl config get-contexts --kubeconfig="$KUBECONFIG" -o name)")
  for context in "${CONTEXTS[@]}"; do
    kubectl config use-context "$context"
    KUBE_CLUSTER_NAME="$(kubectl config view --kubeconfig="$KUBECONFIG" -o jsonpath='{.clusters[0].name}')"
    KUBE_CLUSTER_SERVER="$(kubectl config view --kubeconfig="$KUBECONFIG" -o jsonpath='{.clusters[0].cluster.server}')"
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

    # Use rbac-manager? - https://fairwindsops.github.io/rbac-manager/
    # kubectl apply -f https://raw.githubusercontent.com/FairwindsOps/rbac-manager/master/deploy/all.yaml
    #     # Manage users admin role for their namespace
    #     cat <<EOF | kubectl $ACTION --kubeconfig="$KUBECONFIG_ENV" -f -
    # apiVersion: rbac.authorization.k8s.io/v1
    # kind: RoleBinding
    # metadata:
    #   name: $USERNAME-admin
    #   namespace: $USER_NAMESPACE
    # roleRef:
    #   apiGroup: rbac.authorization.k8s.io
    #   kind: ClusterRole
    #   name: admin
    # subjects:
    # - apiGroup: rbac.authorization.k8s.io
    #   kind: User
    #   name: $USERNAME
    # EOF
  done

else
  printf "Ensure to pass -a ACTION -d CONFIG_DIR -k KUBECONFIG -t PRIVATE_KEY_TEMPLATE -u USERNAME"
  exit 1
fi
