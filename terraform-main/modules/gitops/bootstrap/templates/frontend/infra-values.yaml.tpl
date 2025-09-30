# Frontend infrastructure values - managed by Terraform
# this is missing the version (digest) - saved in infra-values.yaml file & handled by
# the application repo (build & push and update digest)

image:
  repository: "${ecr_frontend_repo_url}"
  tag: ""
  pullPolicy: Always

namespace:
  name: ${frontend_namespace}
  create: true

service:
  type: "ClusterIP"
  port: 80

serviceAccount:
  create: true
  name: ${frontend_service_account_name}
  annotations:
    eks.amazonaws.com/role-arn: ${frontend_iam_role_arn}

containerPort: ${frontend_container_port}

ingress:
  enabled: true
  host: "${frontend_ingress_host}"
  ingressControllerClassResourceName: "alb"
  ingressPath: "/"
  annotations:
    alb.ingress.kubernetes.io/scheme: "internet-facing"
    alb.ingress.kubernetes.io/target-type: "ip"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/group.name: "${alb_group_name}"
    #SG list order argo,frontend
    alb.ingress.kubernetes.io/security-groups: "${alb_security_groups}"
    alb.ingress.kubernetes.io/certificate-arn: "${acm_certificate_arn}"
    # External DNS annotation (optional - helps external-dns identify the record)
    external-dns.alpha.kubernetes.io/hostname: "${frontend_external_dns_hostname}"

# In infra-values.yaml or app-values.yaml
cosign:
  enabled: true
  certificateIdentity: "https://github.com/${github_org}/${github_application_repo}"
  oidcIssuer: "https://token.actions.githubusercontent.com"
