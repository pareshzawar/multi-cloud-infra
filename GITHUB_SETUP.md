# GitHub Repository Setup Guide

Complete steps to publish this Terraform code to GitHub and enable CI/CD.

---

## Step 1 — Create the GitHub repository

```bash
# Option A: GitHub CLI (recommended)
gh repo create multi-cloud-infra --private --description "Multi-Cloud zero-cost infrastructure — Plan"

# Option B: Manual
# Go to github.com/new → name: multi-cloud-infra → Private → Create repository
```

---

## Step 2 — Initialise git and push

```bash
cd /path/to/infra

git init
git add .
git commit -m "feat: initial multi-cloud Terraform stack

- OCI: VCN, private subnet, NSGs, Flexible LB, Ampere A1
- AWS: VPC, private subnet, Vaultwarden EC2, S3 backups
- GCP: VPC, e2-micro gateway, Nginx Proxy Manager, Uptime Kuma
- Azure: Entra ID OIDC SSO for n8n, Uptime Kuma, WireGuard
- Budgets: $1 alerts on all 3 clouds
- GitHub Actions: plan on PR, apply on merge to main
- Cloudflare: DNS records + SSL/TLS settings"

git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/multi-cloud-infra.git
git push -u origin main
```

---

## Step 3 — Add GitHub Secrets

Go to **Settings → Secrets and variables → Actions → New repository secret**
for each of the following:

### OCI Secrets

| Secret Name | Where to find it |
|---|---|
| `OCI_TENANCY_OCID` | OCI Console → Profile → Tenancy |
| `OCI_USER_OCID` | OCI Console → Profile → User Settings |
| `OCI_FINGERPRINT` | OCI Console → Profile → API Keys |
| `OCI_REGION` | Your home region e.g. `ap-mumbai-1` |
| `OCI_COMPARTMENT_ID` | OCI Console → Identity → Compartments |
| `OCI_PRIVATE_KEY` | Contents of `~/.oci/oci_api_key.pem` (paste full PEM including headers) |

**Generate an OCI API key if you haven't:**
```bash
mkdir -p ~/.oci
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
chmod 600 ~/.oci/oci_api_key.pem
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
# Upload ~/.oci/oci_api_key_public.pem in OCI Console → Profile → API Keys
```

### AWS Secrets

| Secret Name | Where to find it |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS Console → IAM → Users → Security credentials |
| `AWS_SECRET_ACCESS_KEY` | Same as above (shown once on creation) |
| `AWS_REGION` | Your preferred region e.g. `ap-south-1` |
| `AWS_ACCOUNT_ID` | AWS Console → top-right account menu (12-digit number) |

**Create a least-privilege IAM user for Terraform:**
```bash
# AWS CLI — create Terraform user with minimal permissions
aws iam create-user --user-name terraform-deployer
aws iam attach-user-policy \
  --user-name terraform-deployer \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
aws iam create-access-key --user-name terraform-deployer
# Save the AccessKeyId and SecretAccessKey
```

### GCP Secrets

| Secret Name | Where to find it |
|---|---|
| `GCP_PROJECT_ID` | GCP Console → Project selector |
| `GCP_CREDENTIALS_JSON` | Service account JSON key (see below) |

**Create a GCP Service Account for Terraform:**
```bash
PROJECT_ID="your-project-id"

# Create service account
gcloud iam service-accounts create terraform-deployer \
  --display-name="Terraform Deployer" \
  --project=$PROJECT_ID

# Grant required roles
for role in \
  roles/compute.admin \
  roles/iam.serviceAccountUser \
  roles/billing.viewer \
  roles/monitoring.admin \
  roles/pubsub.admin; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:terraform-deployer@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="$role"
done

# Create and download JSON key
gcloud iam service-accounts keys create terraform-key.json \
  --iam-account=terraform-deployer@$PROJECT_ID.iam.gserviceaccount.com

# Paste the contents of terraform-key.json as GCP_CREDENTIALS_JSON secret
cat terraform-key.json

# Clean up local key file after pasting
rm terraform-key.json
```

### Azure Secrets

| Secret Name | Where to find it |
|---|---|
| `AZURE_TENANT_ID` | Azure Portal → Entra ID → Overview → Tenant ID |
| `AZURE_CLIENT_ID` | After creating Service Principal (see below) |
| `AZURE_CLIENT_SECRET` | After creating Service Principal (see below) |

**Create an Azure Service Principal for Terraform:**
```bash
# Login to Azure
az login

# Create service principal with Application Administrator role
SP=$(az ad sp create-for-rbac \
  --name "terraform-multi-cloud" \
  --role "Application Administrator" \
  --scopes /subscriptions/$(az account show --query id -o tsv))

echo "Client ID:     $(echo $SP | jq -r '.appId')"
echo "Client Secret: $(echo $SP | jq -r '.password')"
echo "Tenant ID:     $(echo $SP | jq -r '.tenant')"
# Paste these into GitHub secrets
```

### Cloudflare Secrets

| Secret Name | Where to find it |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare Dashboard → Profile → API Tokens → Create Token |
| `CLOUDFLARE_ZONE_ID` | Cloudflare Dashboard → your domain → Overview (right sidebar) |

**Create a scoped Cloudflare API token:**
- Go to: https://dash.cloudflare.com/profile/api-tokens
- Click **Create Token** → **Edit zone DNS** template
- Zone Resources: Include → Specific zone → your domain
- Copy the token

### Common Secrets

| Secret Name | Value |
|---|---|
| `SSH_PUBLIC_KEY` | Contents of `~/.ssh/id_ed25519.pub` (or generate new key) |
| `ALERT_EMAIL` | Your email address for all billing alerts |
| `DOMAIN_NAME` | Your domain e.g. `yourdomain.com` |
| `TAILSCALE_AUTH_KEY` | Tailscale Admin → Settings → Keys → Generate auth key (reusable) |

**Generate SSH key if needed:**
```bash
ssh-keygen -t ed25519 -C "multi-cloud-infra" -f ~/.ssh/multi-cloud
cat ~/.ssh/multi-cloud.pub   # Paste as SSH_PUBLIC_KEY secret
```

---

## Step 4 — Set up GitHub Environments

The CI/CD workflow uses a `production` environment with required reviewers for `terraform apply`.

1. Go to **Settings → Environments → New environment**
2. Name it `production`
3. Add **Required reviewers** → add your GitHub username
4. This means merging to `main` shows a review gate before `apply` runs

---

## Step 5 — Enable GitHub Actions

The workflow file is already at `.github/workflows/terraform.yml`.

After pushing:
1. Go to **Actions** tab
2. Click **I understand my workflows, go ahead and enable them**
3. The workflow triggers on the next push or PR

---

## Step 6 — Branch Protection (recommended)

Go to **Settings → Branches → Add branch protection rule**:

- Branch name pattern: `main`
- ✅ Require a pull request before merging
- ✅ Require status checks to pass: `Terraform Plan`
- ✅ Require linear history
- ✅ Do not allow bypassing the above settings

This means every infrastructure change goes through:
`feature branch → PR → terraform plan (automated) → review → merge → terraform apply`

---

## Step 7 — First Deploy

```bash
# Create a feature branch
git checkout -b feat/initial-deploy

# Push to trigger plan
git push origin feat/initial-deploy

# Open a PR on GitHub
gh pr create --title "Initial deploy" --body "Deploy full multi-cloud stack"

# GitHub Actions runs terraform plan automatically
# Review the plan output in the PR comments

# Merge the PR → triggers terraform apply in production environment
gh pr merge --squash
```

---

## Workflow Summary

```
Push to feature branch
        │
        ▼
    GitHub Actions
    terraform init
    terraform validate
    terraform fmt -check
    terraform plan ──────────────► Comment on PR with plan output
        │
   Merge to main
        │
        ▼
  Require approval
  (production env)
        │
        ▼
    terraform apply
        │
        ▼
   Infrastructure deployed
```

---

## Rotating Secrets

All secrets should be rotated every 90 days. GitHub Actions will fail if a
secret expires. Set calendar reminders for:

- Azure client secret: expires `2026-12-31` (set in azure-sso module)
- OCI API key: no expiry, but rotate annually as best practice
- AWS access key: rotate every 90 days
- Tailscale auth key: generate new reusable key if it expires

To rotate: update the secret in GitHub → Settings → Secrets,
then run `terraform apply` to propagate changes.
