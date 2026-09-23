# Non-secret deployment configuration. Every variable here is required
# (no default in variables.tf) -- this file is the single explicit
# source, whether applied by CI or a human running `terraform apply`
# locally with no other setup. alert_email/route53_zone_id's values
# were already public in repo-infra's own committed config.yml, so
# committing them here doesn't newly expose anything.
aws_region      = "eu-central-1"
domain_name     = "jkandler.de"
route53_zone_id = "Z07879811I86VC8PAL8HX"
alert_email     = "julian.kandler@outlook.com"

tags = {
  ManagedBy = "Terraform"
  Project   = "ses-relay"
}
