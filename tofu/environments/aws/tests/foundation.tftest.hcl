mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "default_registry_and_oidc_contract" {
  command = plan

  assert {
    condition = output.ecr_repository_names == {
      controller = "lucidity/bootc/controller"
      worker     = "lucidity/bootc/worker"
    }
    error_message = "The default controller and worker repository names changed unexpectedly."
  }

  assert {
    condition     = output.github_oidc_subject == "repo:HeartlandTranspersonalAlliance/lucidity:ref:refs/heads/main"
    error_message = "The GitHub OIDC trust must remain restricted to this repository's main branch."
  }
}

run "existing_oidc_provider" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = output.github_oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "An existing account-level GitHub OIDC provider must be reusable."
  }
}
