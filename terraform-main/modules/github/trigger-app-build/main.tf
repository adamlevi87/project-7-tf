# terraform-main/modules/github/trigger-app-build/main.tf

resource "null_resource" "trigger_app_build" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Triggering base image management workflow for ${var.target_branch}..."
      
      curl -X POST \
        -H "Authorization: Bearer ${var.github_token}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${var.github_org}/${var.github_application_repo}/actions/workflows/base-image-management.yml/dispatches" \
        -d "{
          \"ref\": \"${var.target_branch}\",
          \"inputs\": {
            \"target_branch\": \"${var.target_branch}\",
            \"target_version\": \"latest\",
            \"skip_stage_0\": \"false\",
            \"skip_stage_1\": \"false\",
            \"skip_stage_2\": \"false\"
          }
        }"
      
      echo "Workflow triggered for ${var.target_branch}"
    EOT
  }
}
