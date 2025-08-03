config {
  format = "compact"
  # We run tflint from each terraform root separately (see the Makefile and
  # .github/workflows/terraform.yml). Called modules are inspected too, so that a
  # bad variable default in modules/ fails the env that instantiates it.
  module = true
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # eu-west-1 is the only region we deploy to. This makes instance-type and
  # service-availability rules actually mean something.
  deep_check = false
}

# Enforced. Every module here takes typed variables — an untyped variable is how
# you end up passing a string "4" as desired_count and only finding out at apply.
rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# DISABLED, deliberately: modules/rds-mysql predates the naming module and
# declares its variables at the top of main.tf. Turning this on means either
# rewriting a module that has had two commits in twelve months, or an ignore
# comment on every block in it. Neither is worth it. See CONTRIBUTING.md §4
# and PAY-1522.
rule "terraform_standard_module_structure" {
  enabled = false
}

# DISABLED: we tag through module.names.tags, which tflint cannot see through.
rule "aws_resource_missing_tags" {
  enabled = false
}
