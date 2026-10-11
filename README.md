# SES relay for jkandler.de

Terraform for an AWS SES sending identity for `jkandler.de`, originally
built to relay monitoring alert emails from [`home-infra`](https://github.com/KandlerLi/home-infra)'s
`monitoring` role (Prometheus/Grafana/Alertmanager) to
`julian.kandler@outlook.com`. The same domain identity and IAM
credential are now also reused by Authelia (password-reset mail) and by
the Stalwart mail server ([`k3s-apps`](https://github.com/KandlerLi/k3s-apps)' `modules/stalwart`) as its
outbound smart host, configured directly in Stalwart's own admin UI --
see "Stalwart's outbound relay" below.

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
  recipient). Staying in SES's sandbox was sufficient while this
  account only ever sent to that one personal recipient -- see
  "Stalwart's outbound relay" below for why that's no longer true.
- An IAM user scoped only to `ses:SendRawEmail`/`ses:SendEmail` from this
  one verified domain identity, with an access key Terraform generates
  for it. The policy authorizes sending as *any* address on the
  `jkandler.de` domain identity (`alerts@`, `julian@`, `info@`, ...),
  not just the one address Alertmanager happens to send as -- there is
  deliberately no per-mailbox IAM scoping. The policy also lists the
  verified recipient identity: SES authorizes a send against every
  identity involved, and a policy scoped to the domain alone was denied
  live with "not authorized ... on resource identity/<recipient>".
- `MX`, `SPF` and `DMARC` records for the Stalwart mail server, see
  "Mail DNS for Stalwart" below.

## Mail DNS for Stalwart

Inbound and authentication DNS for Stalwart lives here, beside the SES
records, because the SPF policy has to include SES.

- **MX** points at the apex `jkandler.de`, not `mail.jkandler.de`:
  `mail.` is a CNAME ([`dyndns`](https://github.com/KandlerLi/dyndns)'s
  subdomains) and an MX must not point at a CNAME. The apex A record is
  the one `dyndns` keeps current with the home IP.
- **SPF** allows SES (outbound relay) and `a:mail.jkandler.de` (anything
  the homeserver sends directly). It soft-fails (`~all`) for now; tighten
  to `-all` once real mail has flowed cleanly.
- **DMARC** is monitor-only (`p=none`), reports go to the mailbox itself.
  Raise it to quarantine/reject once the reports look clean.

## Security scan exceptions

The IAM user sits in a single-member group so the send policy isn't
attached to a user directly (trivy AWS-0143). AWS-0123 (MFA not
enforced) is suppressed on that group: the identity has no console
password or login profile, only the access key that doubles as its
SMTP username, so there is no session an MFA condition could attach to.

## Stalwart's outbound relay

Stalwart ([`k3s-apps`](https://github.com/KandlerLi/k3s-apps)' `modules/stalwart`) relays all outbound mail
through this same SES SMTP endpoint and credential, rather than
delivering directly from the k3s VM's own IP -- a fresh IP with zero
sending history would get flagged as spam almost everywhere. This is
configured directly in Stalwart's admin UI (`Settings -> SMTP ->
Outbound -> Relay Hosts`, plus a routing rule and disabling DANE/MTA-STS
enforcement for the relay under `Settings -> SMTP -> Outbound`), not in
this repo or in [`k3s-apps`](https://github.com/KandlerLi/k3s-apps) -- Stalwart stores this kind of runtime
setting in its own database, the same as the CORS and IP-allow-list
settings already documented in its own runbook. As with those, a
setting change here needs a Stalwart Pod restart to take effect.

**Why SES's sandbox mattered, and its current state.** In sandbox mode
SES only delivers to identities verified in this same account (why
`aws_ses_email_identity.recipient` exists at all) -- fine for
Alertmanager/Authelia, which only ever send to `julian.kandler@
outlook.com`, but Stalwart needs to send to arbitrary external
addresses. **Production access was granted 2026-09-21** (AWS Support
case 178988954600742): out of the sandbox in eu-central-1, 50,000
messages/day, 14 messages/second. Granting it changed nothing this
repo manages (still `ses:SendRawEmail`/`ses:SendEmail` from a single
verified domain) and it can't be requested through Terraform or the
CLI -- it's an AWS Support case with human review, requested once from
the SES console (*Account dashboard -> Request production access*).
The account is expected to keep a bounce/complaint handling process;
watch those rates in the SES console. Until a real send to a
non-verified recipient has been confirmed, treat "arbitrary recipients
work" as granted-but-unproven.

`aws_ses_email_identity.recipient` is now unnecessary for delivery but
harmless; it stays in place rather than being removed in the same
change as this doc update.

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

## Rotating the access key

`aws_iam_access_key` has no in-place rotation, only destroy and
recreate, so rotation is `terraform apply -replace=aws_iam_access_key.smtp`.
`create_before_destroy` makes that mint the new key before deleting the
old one (IAM allows two keys per user), so Alertmanager, Authelia and
Stalwart never see a moment without a valid key. Same pattern as
`dyndns`' ACME DNS-01 key.

## Prerequisites

- Terraform 1.10 or newer
- The `jkandler-terraform-state` S3 backend bucket
- AWS credentials with permission to manage SES identities, IAM, and the
  `jkandler.de` Route53 hosted zone when bootstrapping or recovering
  outside GitHub Actions

## Deploy

```bash
export TF_VAR_alert_email="you@example.com"
export TF_VAR_route53_zone_id="Z07879811I86VC8PAL8HX"
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
