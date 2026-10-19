# Dashboard SSO with Google Workspace (OIDC)

Configure Google Workspace so operators can sign in to the Subconscious Inference System **dashboard** with corporate SSO. Inference APIs continue to use org API keys (`sk-gw-…`); SSO does not replace API authentication.

Create the Google OAuth client below, then your Subconscious FDE wires OIDC on the gateway. Invite users (or create accounts) before first SSO login; there is no open JIT provisioning.

## Prerequisites

- Deployed API Gateway with a public dashboard origin, e.g. `https://gateway.example.com`
- A Google Workspace domain
- Access to the Google Cloud console with permission to create OAuth clients

## 1. Create a Google OAuth client

In the Google Cloud console, pick the project tied to your Workspace organization, then **APIs and Services** → **OAuth consent screen** first:

| Setting | Value |
| --- | --- |
| User type | **Internal** (Workspace org only; External requires verification) |
| App name | e.g. `Subconscious Dashboard` |
| Support email | Your team address |

Then **Credentials** → **Create credentials** → **OAuth client ID**:

| Setting | Value |
| --- | --- |
| Application type | Web application |
| Authorized redirect URI | `https://<DOMAIN_NAME>/dashboard/auth/oidc/callback` |

Google does not need extra setup for scopes; the gateway requests `openid`, `email`, and `profile`, which Internal apps may use without review.

Copy the **Client ID** and **Client secret**.

## 2. Hand values to your FDE

Give your FDE:

- Hosted domain (your Workspace domain, e.g. `example.com`)
- Client ID
- Client secret (share through the channel they specify; do not put it in chat history or a ticket)
- Dashboard origin (`https://<DOMAIN_NAME>`)

The issuer is always `https://accounts.google.com`; discovery is automatic. The FDE also configures the **hosted domain** (`hd`) restriction. With it, the sign-in flow restricts the Google account picker to your Workspace domain, and the gateway rejects ID tokens that do not carry your domain. Google otherwise authorizes any Google account, so do not skip this.

## 3. Enforce 2-step verification

SSO sign-ins happen on Google's login page, so your Workspace 2-step verification policy is the MFA for the dashboard. Enforce it in the Google Workspace admin console (**Security** → **Authentication** → **2-step verification**) for the organizational unit that holds your operators. The gateway never parses MFA state; your Google policy is the enforcement point.

## 4. Invite users before first SSO login

SSO does not auto-create open accounts. Day-0 still uses the bootstrap admin password. Then:

1. Sign in as bootstrap admin (password) at `https://<DOMAIN_NAME>/` (redirects to `/dashboard`)
2. Invite operators whose **email** matches their Google Workspace email
3. Invited users choose **Sign in with SSO** on the login page

Uninvited users see a clear rejection page (no account created). Password login remains available as break-glass for the bootstrap admin.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| SSO button missing | Confirm with your FDE that OIDC is enabled on this gateway |
| Callback mismatch | Google redirect URI vs `https://<DOMAIN_NAME>/dashboard/auth/oidc/callback` |
| `hd` rejection page | The Google account's hosted domain differs from the configured one; use the Workspace account |
| Uninvited email | Invite the user (or create an active user) before SSO |

See also [sso-okta.md](sso-okta.md) for Okta and [sso-entra.md](sso-entra.md) for Microsoft Entra ID. For deployments that turn password login off entirely, see [sso-only.md](sso-only.md).
