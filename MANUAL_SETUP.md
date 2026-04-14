# MANUAL_SETUP.md
# Steps that cannot be automated via Terraform due to permission constraints
# Follow these after terraform apply completes successfully

---

## 1. Azure SSO — Manual App Registration

**When to use this:** If `terraform apply` fails with
`Authorization_RequestDenied: Insufficient privileges` for the azure-sso module,
set `azure_sso_create_apps = false` in your `terraform.tfvars` and create the
three app registrations manually using the steps below.

### Step 1 — Open the Entra portal

Go to: https://portal.azure.com
Sign in with your Microsoft account → click **Microsoft Entra ID** in the left sidebar.

### Step 2 — Create the n8n app registration

1. Click **App registrations** → **New registration**
2. Fill in:
   - **Name:** `n8n Workflow Automation`
   - **Supported account types:** `Accounts in this organizational directory only`
   - **Redirect URI:** `Web` → `https://n8n.yourdomain.com/rest/oauth2-credential/callback`
3. Click **Register**
4. On the app overview page, copy:
   - **Application (client) ID** → this is your `n8n_oidc_client_id`
   - **Directory (tenant) ID** → this is your `azure_tenant_id`
5. Click **Certificates & secrets** → **New client secret**
   - Description: `n8n-secret`
   - Expires: `24 months`
   - Click **Add**
   - **Copy the VALUE immediately** — it is shown only once

### Step 3 — Create the Uptime Kuma app registration

Repeat Step 2 with:
- **Name:** `Uptime Kuma Monitoring`
- **Redirect URI:** `https://status.yourdomain.com/auth/callback`

Copy its client ID and secret.

### Step 4 — Create the WireGuard app registration

Repeat Step 2 with:
- **Name:** `WireGuard Admin UI`
- **Redirect URI:** `https://wg.yourdomain.com/auth/callback`

Copy its client ID and secret.

### Step 5 — Add values to your docker-compose.yml on OCI A1

SSH into OCI A1 and edit `/opt/apps/docker-compose.yml`:

```yaml
n8n:
  environment:
    OIDC_ENABLED: "true"
    OIDC_ISSUER: "https://login.microsoftonline.com/YOUR_TENANT_ID/v2.0"
    OIDC_CLIENT_ID: "YOUR_N8N_CLIENT_ID"
    OIDC_CLIENT_SECRET: "YOUR_N8N_CLIENT_SECRET"
```

Then restart: `cd /opt/apps && docker compose restart n8n`

### Step 6 — Grant admin consent (do this once)

For each app registration:
1. Go to the app in Entra portal
2. Click **API permissions**
3. Click **Grant admin consent for [your tenant]**
4. Click **Yes**

### Step 7 — Enable MFA (free, strongly recommended)

1. Go to: https://portal.azure.com → **Entra ID** → **Properties**
2. Click **Manage Security Defaults**
3. Toggle **Security defaults** to **Enabled**
4. Install **Microsoft Authenticator** on your phone
5. Register at: https://aka.ms/mysecurityinfo

---

## 2. GCP Budget — Manual Setup

**When to use this:** If `terraform apply` fails with
`billingbudgets.googleapis.com API requires a quota project` or `403 Forbidden`.

### Step 1 — Enable the Billing Budgets API

```bash
gcloud services enable billingbudgets.googleapis.com \
  --project=YOUR_PROJECT_ID

# Set quota project for application default credentials
gcloud auth application-default set-quota-project YOUR_PROJECT_ID
```

### Step 2 — Get your billing account ID

```bash
gcloud billing accounts list
# Output looks like:
# ACCOUNT_ID            NAME                OPEN
# 012345-6789AB-CDEF01  My Billing Account  True

# Note the ACCOUNT_ID — add it to terraform.tfvars as gcp_billing_account_id
```

### Step 3 — Grant the required role

The service account needs `roles/billing.costsManager` on the billing account:

```bash
gcloud billing accounts add-iam-policy-binding YOUR_BILLING_ACCOUNT_ID \
  --member="serviceAccount:terraform-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/billing.costsManager"
```

### Step 4 — Create budget manually if Terraform still fails

Go to: https://console.cloud.google.com/billing → select your billing account
→ **Budgets & alerts** → **Create budget**

Fill in:
- **Name:** `monthly-cost-alert`
- **Projects:** select your project
- **Budget amount:** `$1.00`
- **Alert thresholds:** 50%, 90%, 100%
- **Notifications:** check "Email alerts to billing admins"
- Click **Save**

---

## 3. OCI Budget — Notes

The OCI budget Terraform resource uses `target_type = "COMPARTMENT"` (not `TENANCY`
which is invalid in OCI provider v6). The `targets` list should contain your
tenancy/root compartment OCID — this covers all spend in the tenancy.

If you prefer to create it manually:
1. Go to OCI Console → **Billing & Cost Management** → **Budgets**
2. Click **Create Budget**
3. Fill in:
   - **Name:** `monthly_cost_alert`
   - **Target:** select your root compartment
   - **Monthly Budget Amount:** `1`
   - **Threshold Metric:** `Actual Spend`
   - **Threshold %:** `100`
   - **Email Recipients:** your email

---

## 4. Remote State — Multi-Device Terraform

If you work from multiple devices (laptop at home, laptop at work, etc.),
you need Terraform state in a shared location — otherwise each device has
its own state and will try to recreate infrastructure that already exists.

### Bootstrap the OCI Object Storage bucket (run once, any device)

```bash
cd infra/modules/remote-state-bootstrap

# Create a minimal bootstrap tfvars
cat > bootstrap.tfvars << EOF
compartment_id = "ocid1.compartment.oc1..YOUR_COMPARTMENT"
user_ocid      = "ocid1.user.oc1..YOUR_USER_OCID"
bucket_name    = "terraform-state-multicloud"
region         = "ap-mumbai-1"
EOF

terraform init
terraform apply -var-file=bootstrap.tfvars

# Note the outputs:
terraform output namespace       # Your OCI namespace string
terraform output access_key_id   # S3-compatible access key
terraform output -raw secret_key # S3-compatible secret key
terraform output s3_endpoint     # The S3 endpoint URL
```

### Configure the backend in environments/prod/main.tf

Uncomment the backend block and fill in the values:

```hcl
backend "s3" {
  bucket                      = "terraform-state-multicloud"
  key                         = "prod/terraform.tfstate"
  region                      = "ap-mumbai-1"
  endpoint                    = "https://YOUR_NAMESPACE.compat.objectstorage.ap-mumbai-1.oraclecloud.com"
  access_key                  = "YOUR_ACCESS_KEY_ID"     # from terraform output
  secret_key                  = "YOUR_SECRET_KEY"        # from terraform output -raw secret_key
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  force_path_style            = true
}
```

### Migrate existing local state to remote

```bash
cd infra/environments/prod

# This reads local state and uploads it to OCI Object Storage
terraform init -migrate-state
# Type 'yes' when prompted

# Verify state is now remote
terraform state list   # Should work from any device after this
```

### Use from a second device

On any other device (laptop, CI/CD, etc.):

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/multi-cloud-infra
cd multi-cloud-infra/environments/prod

# Copy terraform.tfvars from password manager (or use env vars)
cp terraform.tfvars.example terraform.tfvars
# Fill in values

# Init downloads the remote state automatically
terraform init
terraform plan   # reads live state from OCI Object Storage
```

---

## 5. Second OCI Tenancy

If you have a second OCI account (different email address), each account gets
its own free allocation of 2x E2.1.Micro + Ampere A1. To use it:

### Step 1 — Generate a new OCI API key for the second tenancy

```bash
# Create a separate key file
mkdir -p ~/.oci
openssl genrsa -out ~/.oci/oci_api_key_2.pem 2048
chmod 600 ~/.oci/oci_api_key_2.pem
openssl rsa -pubout \
  -in ~/.oci/oci_api_key_2.pem \
  -out ~/.oci/oci_api_key_2_public.pem

# Upload oci_api_key_2_public.pem in OCI Console (second account)
# Profile → My profile → API Keys → Add API Key
```

### Step 2 — Add to terraform.tfvars

```hcl
# Second OCI tenancy
oci2_tenancy_ocid       = "ocid1.tenancy.oc1..SECOND_TENANCY"
oci2_user_ocid          = "ocid1.user.oc1..SECOND_USER"
oci2_fingerprint        = "aa:bb:cc:..."
oci2_region             = "ap-mumbai-1"
oci2_availability_domain = "..."
```

### Step 3 — Add provider alias and module in main.tf

```hcl
provider "oci" {
  alias        = "tenancy2"
  tenancy_ocid = var.oci2_tenancy_ocid
  user_ocid    = var.oci2_user_ocid
  fingerprint  = var.oci2_fingerprint
  private_key  = file("~/.oci/oci_api_key_2.pem")
  region       = var.oci2_region
}

module "oci2_compute" {
  source    = "../../modules/oci-compute2"
  providers = { oci = oci.tenancy2 }

  compartment_id      = var.oci2_tenancy_ocid
  availability_domain = var.oci2_availability_domain
  ssh_public_key      = var.ssh_public_key
  tailscale_auth_key  = var.tailscale_auth_key

  tags = local.common_tags
}
```

The second micro automatically joins your Tailscale mesh using the same auth key.
It appears as `oci2-extra` in `tailscale status`.
