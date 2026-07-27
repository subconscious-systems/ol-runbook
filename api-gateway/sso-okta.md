# Dashboard SSO with Okta (OIDC)

Configure Okta so operators can sign in to the Subconscious Inference System
**dashboard** with corporate SSO. Inference APIs continue to use org API keys
(`sk-gw-…`); SSO does not replace API authentication.

Canonical install path: set fields on the **api-gateway-infra** Distr Docker
env. The runner writes non-secret OIDC settings into the gateway Helm fragment
and copies the client secret into AWS Secrets Manager → ESO → `gateway-secrets`.
Hand-editing gateway Helm overrides is wiped on the next infra auto-deploy.

## Prerequisites

- Gateway chart with dashboard OIDC support (and infra runner that emits OIDC)
- Public dashboard origin (`DOMAIN_NAME`), e.g. `https://gateway.example.com`
- Ability to create an Okta OIDC app and a Distr Hub Secret for the client secret

## 1. Create an Okta OIDC Web application

In Okta Admin → **Applications** → **Create App Integration**:

| Setting | Value |
| --- | --- |
| Sign-in method | OIDC - OpenID Connect |
| Application type | Web Application |
| Grant type | Authorization Code |
| Sign-in redirect URI | `https://<DOMAIN_NAME>/dashboard/auth/oidc/callback` |
| Sign-out redirect URI | `https://<DOMAIN_NAME>/dashboard/login` (optional) |
| Controlled access | Assign groups/users who may use the dashboard |

Copy the **Client ID**, **Client secret**, and issuer URL.

Typical issuer (Org Authorization Server):

```text
https://<your-okta-domain>
```

Or a custom authorization server:

```text
https://<your-okta-domain>/oauth2/<authorizationServerId>
```

Confirm discovery works:

```text
https://<issuer>/.well-known/openid-configuration
```

The IdP must release the **email** claim (and preferably `email_verified`).

## 2. Store the client secret in Distr Hub

Create a Hub Secret (masked), named like:

```text
{GATEWAY_DISTR_DEPLOYMENT_NAME}_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET
```

Example: `acme-api-gateway_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET`.

Reference it from the infra Docker env (see
[aws/sample-gateway-infra.env](aws/sample-gateway-infra.env) and
[aws/gateway-secrets.md](aws/gateway-secrets.md)):

```text
DASHBOARD_OIDC_CLIENT_SECRET={{.Secrets.<gw>_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET}}
```

On apply, the runner merges the resolved value into
`orangeline/{DEPLOY_NAME}/app` as
`SUBCONSCIOUS_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET` (ESO syncs into
`gateway-secrets`). Do **not** put the plaintext in Helm values.

## 3. Enable OIDC on the infra env

Set these plain Hub fields on the **api-gateway-infra** deployment (not the
gateway Helm app):

| Field | Example |
| --- | --- |
| `DASHBOARD_OIDC_ENABLED` | `true` |
| `DASHBOARD_OIDC_PROVIDER` | `okta` |
| `DASHBOARD_OIDC_ISSUER_URL` | `https://<your-okta-domain>` |
| `DASHBOARD_OIDC_CLIENT_ID` | Okta client ID |
| `DASHBOARD_OIDC_CLIENT_SECRET` | Hub Secret ref (step 2) |
| `DASHBOARD_OIDC_SCOPES` | `openid,email,profile` (default) |
| `DASHBOARD_OIDC_REDIRECT_URI` | leave empty unless overriding the default callback |

`DOMAIN_NAME` already drives `gateway.dashboardPublicUrl`; the callback defaults
to `https://<DOMAIN_NAME>/dashboard/auth/oidc/callback`.

Re-run the infra application with `GATEWAY_AUTO_DEPLOY=true` so the fragment is
pushed and the gateway Deployment rolls. Lasting SSO settings must live on this
infra env path — gateway Hub Helm overrides are overwritten by auto-deploy.

## 4. Invite users before first SSO login

SSO does **not** auto-create open accounts. Day-0 still uses the bootstrap admin
password. Then:

1. Sign in as bootstrap admin (password) at `https://<DOMAIN_NAME>/` (redirects
   to `/dashboard`)
2. Invite operators whose **email** matches the Okta email claim
3. Invited users choose **Sign in with SSO** on the login page

Uninvited users see a clear rejection page (no account created).

## Troubleshooting

| Symptom | Check |
| --- | --- |
| SSO button missing | `DASHBOARD_OIDC_ENABLED=true` on infra env; last auto-deploy succeeded |
| Callback mismatch | Okta redirect URI vs `https://<DOMAIN_NAME>/dashboard/auth/oidc/callback` |
| Secret / 5xx after enable | Hub Secret resolved; SM key `SUBCONSCIOUS_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET` present in `gateway-secrets` |
| Uninvited email | Invite the user (or create an active user) before SSO |
| Settings wiped after redeploy | You edited gateway Helm overrides — move fields to infra `DASHBOARD_OIDC_*` |

See also [sso-entra.md](sso-entra.md) for Microsoft Entra ID.
