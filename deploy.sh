REPO_URL="$(git remote get-url origin)"
REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"
REPO_CURRENT_BRANCH="$(git branch --show-current)"

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for ArgoCD openshift-gitops to become Available..."

until [ "$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null)" = "Available" ]; do
  sleep 10
done

echo "ArgoCD openshift-gitops is Available."

oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-keda
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-custom-metrics-autoscaler-operator
  namespace: openshift-keda
spec:
  targetNamespaces:
    - openshift-keda
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-custom-metrics-autoscaler-operator
  namespace: openshift-keda
spec:
  channel: stable
  installPlanApproval: Automatic
  name: openshift-custom-metrics-autoscaler-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: keda.sh/v1alpha1
kind: KedaController
metadata:
  name: keda
  namespace: openshift-keda
spec:
  admissionWebhooks:
    logEncoder: console
    logLevel: info
  metricsServer:
    logLevel: "0"
  operator:
    logEncoder: console
    logLevel: info
  watchNamespace: ""
EOF

echo "Waiting for KEDA operator to become ready..."

until oc -n openshift-keda get deployment keda-operator \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^1'; do
  sleep 10
done

echo "KEDA operator is ready."

oc patch argocd openshift-gitops \
  -n openshift-gitops \
  --type merge \
  -p '{
    "spec": {
      "controller": {
        "appSync": "5s"
      },
      "extraConfig": {
        "timeout.reconciliation.jitter": "0s"
      }
    }
  }'

echo "Granting cluster-admin to the ArgoCD application controller service account..."

oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshift-gitops-argocd-application-controller-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: openshift-gitops-argocd-application-controller
  namespace: openshift-gitops
EOF

oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${REPO_NAME}-core
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REPO_CURRENT_BRANCH}
    path: raw
    helm: {}
  destination:
    server: https://kubernetes.default.svc
    namespace: jvm-stress-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
      - SkipDryRunOnMissingResource=true
EOF
