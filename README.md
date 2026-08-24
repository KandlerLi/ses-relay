# SES relay for homeserver alerting

Terraform for an AWS SES sending identity used only to relay monitoring
alert emails from `infra/home-infra`'s `monitoring` role (Prometheus/
Grafana/Alertmanager) to `julian.kandler@outlook.com`.

## Why this exists

Alertmanager's built-in email support only speaks plain SMTP username/
password auth. Personal Outlook.com accounts no longer support that at
all -- Microsoft retired app-password/basic-auth SMTP for consumer
accounts, leaving only OAuth2, which Alertmanager (like almost every
self-hosted alerting tool) can't do. SES issues real SMTP username/
password credentials that work with any standard SMTP client, costs
pennies at this volume, and can email *to* the existing Outlook address
even though it can no longer relay *through* Outlook's own SMTP.

## What this manages

- `aws_ses_domain_identity` + `aws_route53_record` (TXT) + `aws_ses_domain_identity_verification`:
  verifies `jkandler.de` as a sending domain, so mail goes out as
  `alerts@jkandler.de`.
- `aws_ses_domain_dkim` + three `aws_route53_record` (CNAME) entries:
  DKIM signing, for deliverability.
- `aws_ses_email_identity` for `julian.kandler@outlook.com` (the
  recipient). Staying in SES's sandbox is sufficient for one personal
  recipient -- no production-access request needed.
- An IAM user scoped only to `ses:SendRawEmail`/`ses:SendEmail` from this
  one verified domain identity, with an access key Terraform generates
  for it.

## One thing Terraform can't finish: the SNS-style manual step

`aws_ses_email_identity` triggers a one-click confirmation email AWS
sends to `alert_email`. No mail is delivered to that address until it's
clicked -- same requirement as the SNS subscription in
`homeserver-health-check`, just SES's version of it.

## Deriving the SMTP password

The SES SMTP *password* is not a value AWS stores anywhere -- it's a
deterministic transform of the IAM secret access key (documented by AWS,
the same algorithm the SES console's own "Create SMTP credentials"
wizard runs). Deliberately not computed inside Terraform: doing that
would put the actual, usable SMTP password in Terraform state, on top of
the raw IAM secret key that's already there. Instead:

```bash
terraform output -raw smtp_secret_access_key > /tmp/ses-secret-key
python3 scripts/derive_smtp_password.py "$(cat /tmp/ses-secret-key)" eu-central-1
rm /tmp/ses-secret-key
```

Copy the result into SOPS as `monitoring_ses_smtp_password` in
`home-infra`, alongside `monitoring_ses_smtp_username` (this repo's
`smtp_username` output -- the IAM access key ID itself, used as-is, no
derivation needed).

## Prerequisites

- Terraform 1.10 or newer
- The `jkandler-terraform-state` S3 backend bucket
- AWS credentials with permission to manage SES identities, IAM, and the
  `jkandler.de` Route53 hosted zone when bootstrapping or recovering
  outside GitHub Actions

## Deploy

```bash
export TF_VAR_alert_email="you@example.com"
terraform init
terraform plan
terraform apply
```

## Runner

Self-hosted home runner (`[self-hosted, home, debian]`), same as
`dyndns`/`website`/`aws-budget`/`homeserver-health-check`.

## Local validation

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```
