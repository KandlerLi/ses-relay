data "aws_route53_zone" "selected" {
  zone_id      = var.route53_zone_id
  private_zone = false
}

check "hosted_zone_matches_domain" {
  assert {
    condition     = trimsuffix(data.aws_route53_zone.selected.name, ".") == var.domain_name
    error_message = "route53_zone_id must identify the public hosted zone for domain_name."
  }
}

resource "aws_ses_domain_identity" "this" {
  domain = var.domain_name
}

resource "aws_route53_record" "ses_verification" {
  zone_id = var.route53_zone_id
  name    = "_amazonses.${var.domain_name}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.this.verification_token]
}

# Blocks until AWS actually confirms the TXT record above, so a later
# terraform apply against the identity (or anything depending on it)
# never races ahead of real verification.
resource "aws_ses_domain_identity_verification" "this" {
  domain     = aws_ses_domain_identity.this.id
  depends_on = [aws_route53_record.ses_verification]
}

resource "aws_ses_domain_dkim" "this" {
  domain = aws_ses_domain_identity.this.domain
}

# SES always issues exactly 3 DKIM tokens for a domain identity, but their
# values aren't known until apply -- for_each can't iterate an apply-time
# list directly (Terraform can't determine the resulting instance keys
# during plan). Iterating over static indices instead, and indexing into
# the token list per record, sidesteps that: the *keys* are known at plan
# time even though the *values* aren't.
resource "aws_route53_record" "dkim" {
  for_each = toset(["0", "1", "2"])

  zone_id = var.route53_zone_id
  name    = "${aws_ses_domain_dkim.this.dkim_tokens[tonumber(each.value)]}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.this.dkim_tokens[tonumber(each.value)]}.dkim.amazonses.com"]
}

# Verifies the recipient. Staying in SES's sandbox is sufficient for one
# personal recipient -- no need to request production access. Like the
# SNS subscription in homeserver-health-check, this triggers a one-click
# confirmation email Terraform can't complete on its own.
resource "aws_ses_email_identity" "recipient" {
  email = var.alert_email
}

# Scoped only to sending from this one verified domain -- not account-wide
# SES access, and not usable for anything but SendEmail/SendRawEmail.
resource "aws_iam_user" "smtp" {
  name = "ses-relay-smtp"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_user_policy" "smtp" {
  name = "send-from-verified-domain"
  user = aws_iam_user.smtp.name

  # SES's IAM authorization for SendRawEmail/SendEmail checks the caller
  # against every identity involved in the send, not just the sending
  # domain -- since the recipient is also a verified identity in this same
  # account (required for SES sandbox delivery), a policy scoped to only
  # the domain identity gets denied with "not authorized ... on resource
  # identity/<recipient>". Confirmed live: the recipient identity ARN had
  # to be added here before mail actually sent.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SendFromVerifiedDomain"
        Effect = "Allow"
        Action = ["ses:SendRawEmail", "ses:SendEmail"]
        Resource = [
          aws_ses_domain_identity.this.arn,
          aws_ses_email_identity.recipient.arn,
        ]
      },
    ]
  })
}

# The access key ID doubles as the SMTP username, used as-is. The secret
# access key is NOT the SMTP password -- see README's "Deriving the SMTP
# password" section for the one manual step this can't do on its own,
# and why that derivation deliberately happens outside Terraform state.
resource "aws_iam_access_key" "smtp" {
  user = aws_iam_user.smtp.name

  # create_before_destroy so a future `terraform apply
  # -replace=aws_iam_access_key.smtp` (the actual rotation mechanic --
  # this resource has no in-place rotation, only destroy+recreate)
  # mints the new key before deleting the old one. IAM permits up to 2
  # access keys per user, so this gives a real overlap window instead
  # of a moment with zero valid key while Alertmanager/Authelia could
  # be mid-send. Same fix as aws/dyndns's acme_dns01 access key
  # (2026-09-11), applied here for the same reason.
  lifecycle {
    create_before_destroy = true
  }
}
