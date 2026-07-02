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
    path: chart
    helm: {}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${REPO_NAME}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
EOF
