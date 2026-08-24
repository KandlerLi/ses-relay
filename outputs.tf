output "smtp_host" {
  description = "SES SMTP endpoint for this region"
  value       = "email-smtp.${var.aws_region}.amazonaws.com"
}

output "smtp_username" {
  description = "SMTP username -- this is the IAM access key ID, used as-is, no derivation needed"
  value       = aws_iam_access_key.smtp.id
}

output "smtp_secret_access_key" {
  description = <<-EOT
    The raw IAM secret access key -- NOT the SMTP password. Run
    scripts/derive_smtp_password.py with this value to get the actual SMTP
    password; see README's "Deriving the SMTP password" section.
  EOT
  value       = aws_iam_access_key.smtp.secret
  sensitive   = true
}

output "from_address" {
  description = "Verified sending address"
  value       = "alerts@${var.domain_name}"
}

output "domain_identity_arn" {
  description = "ARN of the verified SES domain identity"
  value       = aws_ses_domain_identity.this.arn
}
