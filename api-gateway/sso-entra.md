# Dashboard SSO with Microsoft Entra ID (OIDC)

Same dashboard SSO path as Okta — OIDC Authorization Code + PKCE — with an Entra
app registration. Configure via **api-gateway-infra** env fields (not hand-edited
gateway Helm overrides). Full Okta-oriented detail:
[sso-okta.md](sso-okta.md).

## 1. App registration

In Entra admin → **App registrations** → **New registration**:

| Setting | Value |
| --- | --- |
| Supported account types | Single tenant (typical) |
| Redirect URI (Web) | `https://<DOMAIN_NAME>/dashboard/auth/oidc/callback` |

Under **Certificates & secrets**, create a client secret. Under **API
permissions**, ensure Microsoft Graph `openid`, `email`, `profile` (delegated)
as needed for ID token claims.

Issuer URL (v2):

```text
https://login.microsoftonline.com/<tenant-id>/v2.0
```

Discovery:

```text
https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration
```

## 2. Infra env (canonical)

Hub Secret (masked):

```text
{GATEWAY_DISTR_DEPLOYMENT_NAME}_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET
```

Infra Docker env:

```text
DASHBOARD_OIDC_ENABLED=true
DASHBOARD_OIDC_PROVIDER=entra
DASHBOARD_OIDC_ISSUER_URL=https://login.microsoftonline.com/<tenant-id>/v2.0
DASHBOARD_OIDC_CLIENT_ID=<application-client-id>
DASHBOARD_OIDC_CLIENT_SECRET={{.Secrets.<gw>_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET}}
DASHBOARD_OIDC_SCOPES=openid,email,profile
```

Re-run infra with `GATEWAY_AUTO_DEPLOY=true`. See
[aws/gateway-secrets.md](aws/gateway-secrets.md) and
[aws/sample-gateway-infra.env](aws/sample-gateway-infra.env).

## 3. Invite users, then SSO

1. Bootstrap admin signs in with password (day-0)
2. Invite operators with emails that match Entra UPN / email claim
3. Users choose **Sign in with SSO** on the login page

Open `https://<DOMAIN_NAME>/` to reach the dashboard (root redirects to
`/dashboard`).

## Entra-specific notes

- Prefer the **email** claim. If your tenant only emits `preferred_username`,
  configure Entra optional claims so `email` is present on the ID token — the
  gateway requires email for identity matching.
- Multi-tenant / “accounts in any org” is not the default design; use a single
  tenant issuer unless Subconscious has approved a broader federation model.
- Password login remains break-glass; API keys remain for agents.
