# Frontend application yaml
# This file is created once during bootstrap and maintained in Git

apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app_name}
  namespace: ${argocd_namespace}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/refresh: hard
spec:
  project: ${argocd_project_name}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${app_namespace}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 25                    # High retry limit for missing images
      backoff:
        duration: 120s             # Start with 2 minutes
        factor: 2               # Gentle exponential backoff
        maxDuration: 20m          # Maximum 20 minutes between retries
    syncOptions:
      - CreateNamespace=true
  # Multi-source: CHART comes from app repo; VALUES come from gitops repo via ref
  sources:
    - repoURL: https://github.com/${github_org}/${github_application_repo}.git    # chart source
      targetRevision: ${argocd_target_revision}
      path: helm/
      helm:
        releaseName: ${helm_release_name}
        valueFiles:
          - $values/manifests/${app_name}/infra-values.yaml          # <-- infrastructure values (Terraform)
          - $values/manifests/${app_name}/digest-values.yaml         # <-- digest values (Application Repo)
          - $values/manifests/${app_name}/app-values.yaml            # <-- application values (static)
    - repoURL: https://github.com/${github_org}/${github_gitops_repo}.git     # values source
      targetRevision: ${argocd_target_revision}
      ref: values