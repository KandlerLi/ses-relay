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

resource "aws_ses_domain_identity_verification" "this" {
  domain     = aws_ses_domain_identity.this.id
  depends_on = [aws_route53_record.ses_verification]
}

resource "aws_ses_domain_dkim" "this" {
  domain = aws_ses_domain_identity.this.domain
}

# Static keys: SES always issues 3 DKIM tokens, but their values are only known after apply.
resource "aws_route53_record" "dkim" {
  for_each = toset(["0", "1", "2"])

  zone_id = var.route53_zone_id
  name    = "${aws_ses_domain_dkim.this.dkim_tokens[tonumber(each.value)]}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.this.dkim_tokens[tonumber(each.value)]}.dkim.amazonses.com"]
}

resource "aws_ses_email_identity" "recipient" {
  email = var.alert_email
}

resource "aws_iam_user" "smtp" {
  name = "ses-relay-smtp"

  lifecycle {
    prevent_destroy = true
  }
}

# Machine credential without console login, so MFA can't apply: see README, "Security scan exceptions".
#trivy:ignore:AVD-AWS-0123
resource "aws_iam_group" "smtp" {
  name = "ses-relay-smtp"
}

resource "aws_iam_group_policy" "smtp" {
  name  = "send-from-verified-domain"
  group = aws_iam_group.smtp.name

  # SES authorizes against every identity in a send, so the verified recipient must be listed too.
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

resource "aws_iam_group_membership" "smtp" {
  name  = "ses-relay-smtp-members"
  group = aws_iam_group.smtp.name
  users = [aws_iam_user.smtp.name]
}

# The secret key is not the SMTP password: see README, "Deriving the SMTP password".
resource "aws_iam_access_key" "smtp" {
  user = aws_iam_user.smtp.name

  # Rotation by -replace mints the new key before the old one goes: see README.
  lifecycle {
    create_before_destroy = true
  }
}

# Apex, not mail.<domain>: that is a CNAME, and an MX must not point at one.
resource "aws_route53_record" "mx" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "MX"
  ttl     = 600
  records = ["10 ${var.domain_name}."]
}

resource "aws_route53_record" "spf" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 a:mail.${var.domain_name} include:amazonses.com -all"]
}

# Monitor-only for now: see README, "Mail DNS for Stalwart".
resource "aws_route53_record" "dmarc" {
  zone_id = var.route53_zone_id
  name    = "_dmarc.${var.domain_name}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none; rua=mailto:julian@${var.domain_name}"]
}
