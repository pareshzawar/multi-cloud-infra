# Azure Entra ID SSO Setup Guide

## What you get for free

Azure Entra ID Free tier includes:
- ✅ Unlimited app registrations
- ✅ OIDC / OAuth2 / SAML SSO for custom apps
- ✅ MFA via Microsoft Authenticator
- ✅ Up to 50,000 MAU (monthly active users) — more than enough
- ❌ Conditional Access (requires P1 — ~$6/user/month)
- ❌ Identity Protection (requires P2)

For this stack, the **free tier is fully sufficient**.

---

## How it works in this stack

```
User opens https://n8n.yourdomain.com
    │
    ▼
n8n redirects to:
https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize
    │
    ▼
User logs in with Microsoft account (MFA if enabled)
    │
    ▼
Azure issues ID token (JWT)
    │
    ▼
n8n validates token → user is logged in
```

All three protected services (n8n, Uptime Kuma, WireGuard Admin) use the
same Entra ID tenant but have separate app registrations and client IDs.

---

## Step 1 — Prerequisites

You need one of:
- A Microsoft 365 / Office 365 subscription (any tier, including free trials)
- An Azure subscription (free tier works)
- A free Entra ID tenant (go to: https://entra.microsoft.com → sign up)

---

## Step 2 — What Terraform creates automatically

The `azure-sso` module creates:

1. **3 App Registrations** (n8n, Uptime Kuma, WireGuard)
2. **3 Service Principals** (enterprise app instances)
3. **3 Client Secrets** (OIDC credentials)
4. **Admin user assignment** (assigns your account to all apps)

After `terraform apply`, run:
```bash
terraform output azure_oidc_issuer
terraform output n8n_oidc_client_id
terraform output -raw n8n_oidc_client_secret   # -raw for secrets
```

---

## Step 3 — Grant admin consent (manual — required once)

Terraform creates the apps but cannot grant admin consent on your behalf.

1. Go to https://portal.azure.com → **Microsoft Entra ID**
2. Click **Enterprise Applications**
3. For each app (n8n, Uptime Kuma, WireGuard):
   - Click the app name
   - Go to **Permissions**
   - Click **Grant admin consent for [your tenant]**
   - Confirm

Without this, users will see a consent prompt on every login.

---

## Step 4 — Configure n8n OIDC

n8n supports OIDC via environment variables (already set in cloud-init):

```yaml
# In docker-compose.yml on OCI:
environment:
  OIDC_ENABLED: "true"
  OIDC_ISSUER: "https://login.microsoftonline.com/{TENANT_ID}/v2.0"
  OIDC_CLIENT_ID: "{N8N_CLIENT_ID}"
  OIDC_CLIENT_SECRET: "{N8N_CLIENT_SECRET}"
  OIDC_REDIRECT_URL: "https://n8n.yourdomain.com/rest/oauth2-credential/callback"
```

---

## Step 5 — Configure Uptime Kuma OIDC

Uptime Kuma supports OIDC in v1.23+:

1. Log into Uptime Kuma → **Settings → Security**
2. Enable **SSO (OIDC)**
3. Enter:
   - **Issuer URL**: `https://login.microsoftonline.com/{TENANT_ID}/v2.0`
   - **Client ID**: `{UPTIME_KUMA_CLIENT_ID}` (from terraform output)
   - **Client Secret**: `{UPTIME_KUMA_CLIENT_SECRET}`
   - **Redirect URI**: `https://status.yourdomain.com/auth/callback`
4. Save and test

---

## Step 6 — Enable MFA (strongly recommended — free)

1. Go to https://portal.azure.com → **Entra ID → Properties**
2. Click **Manage Security Defaults**
3. Set **Security defaults** to **Enabled**

This enforces MFA for all users via Microsoft Authenticator — completely free.

Alternatively, for per-user MFA:
1. **Entra ID → Users → select your user**
2. **Authentication methods → + Add method → Microsoft Authenticator**

---

## Step 7 — Add additional users (optional)

To allow other users (family, team) to access your services:

```bash
# Invite a user via Azure CLI
az ad user invite \
  --invited-user-display-name "User Name" \
  --invited-user-email-address user@example.com \
  --invite-redirect-url "https://yourdomain.com"
```

Then assign them to specific apps:
1. **Entra ID → Enterprise Applications → [app name] → Users and Groups**
2. Click **Add user/group**
3. Select the user → assign

Only users explicitly assigned to an app can log in (because
`app_role_assignment_required = true` is set in Terraform).

---

## OIDC Endpoints Reference

| Endpoint | URL |
|---|---|
| Discovery document | `https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration` |
| Authorization | `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize` |
| Token | `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token` |
| Logout | `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/logout` |
| JWKS | `https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys` |

Replace `{tenant}` with your Tenant ID (from `terraform output azure_oidc_issuer`).

---

## Troubleshooting

**"AADSTS50011: The redirect URI does not match"**
→ Check the redirect URI in your app registration exactly matches what the app sends.
→ In Azure Portal: App Registration → Authentication → Redirect URIs

**"AADSTS700016: Application not found in directory"**
→ Make sure you're using the correct Tenant ID
→ Run: `terraform output azure_oidc_issuer` to confirm

**"AADSTS65001: The user or administrator has not consented"**
→ Complete Step 3 (grant admin consent) in Azure Portal

**"User is not assigned to this application"**
→ Assign the user in Azure Portal: Enterprise Apps → [app] → Users and Groups
