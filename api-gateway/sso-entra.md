# Dashboard SSO with Microsoft Entra ID (OIDC)

Same dashboard SSO path as Okta: OIDC Authorization Code + PKCE, with an Entra app registration. Create the app below, then your Subconscious FDE wires OIDC on the gateway. Full Okta-oriented detail: [sso-okta.md](sso-okta.md).

## 1. App registration

In Entra admin → **App registrations** → **New registration**:

| Setting | Value |
| --- | --- |
| Supported account types | Single tenant (typical) |
| Redirect URI (Web) | `https://<DOMAIN_NAME>/dashboard/auth/oidc/callback` |

Under **Certificates & secrets**, create a client secret. Under **API permissions**, ensure Microsoft Graph `openid`, `email`, `profile` (delegated) as needed for ID token claims.

Issuer URL (v2):

```text
https://login.microsoftonline.com/<tenant-id>/v2.0
```

Discovery:

```text
https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration
```

## 2. Hand values to your FDE

Give your FDE:

- Issuer URL (`https://login.microsoftonline.com/<tenant-id>/v2.0`)
- Application (client) ID
- Client secret (share through the channel they specify)
- Dashboard origin (`https://<DOMAIN_NAME>`)

They enable OIDC on the gateway with provider `entra` and scopes `openid`, `email`, `profile`.

## 3. Invite users, then SSO

1. Bootstrap admin signs in with password (day-0)
2. Invite operators with emails that match Entra UPN / email claim
3. Users choose **Sign in with SSO** on the login page

Open `https://<DOMAIN_NAME>/` to reach the dashboard (root redirects to `/dashboard`).

## Entra-specific notes

- Prefer the **email** claim. If your tenant only emits `preferred_username`, configure Entra optional claims so `email` is present on the ID token. The gateway requires email for identity matching.
- Multi-tenant / "accounts in any org" is not the default design; use a single tenant issuer unless Subconscious has approved a broader federation model.
- Password login remains break-glass; API keys remain for agents.
