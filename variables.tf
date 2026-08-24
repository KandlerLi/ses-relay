variable "aws_region" {
  description = "AWS region in which to configure SES"
  type        = string
  default     = "eu-central-1"
}

variable "domain_name" {
  description = "Domain to verify as an SES sending identity (mail goes out as alerts@<domain_name>)"
  type        = string
  default     = "jkandler.de"

  validation {
    condition = length(var.domain_name) <= 253 && length(split(".", var.domain_name)) >= 2 && alltrue([
      for label in split(".", var.domain_name) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", label))
    ])
    error_message = "domain_name must be a lowercase fully qualified DNS name without a trailing dot."
  }
}

variable "route53_zone_id" {
  description = "ID of the existing public Route53 hosted zone for domain_name"
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must be a Route53 hosted-zone ID beginning with Z."
  }
}

# No default: this repo is public, so the address isn't committed to git
# history -- same pattern as aws-budget/homeserver-health-check's own
# alert_email. Supplied via TF_VAR_alert_email, sourced from this
# repository's own ALERT_EMAIL GitHub Actions variable.
variable "alert_email" {
  description = "Recipient address SES verifies and Alertmanager sends monitoring alerts to"
  type        = string
}

variable "tags" {
  description = "Tags applied to supported AWS resources"
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Project   = "ses-relay"
  }
}
