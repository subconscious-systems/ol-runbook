# Dashboard SSO with Okta (OIDC)

Configure Okta so operators can sign in to the Subconscious Inference System **dashboard** with corporate SSO. Inference APIs continue to use org API keys (`sk-gw-…`); SSO does not replace API authentication.

Create the Okta application below, then your Subconscious FDE wires OIDC on the gateway. Invite users (or create accounts) before first SSO login; there is no open JIT provisioning.

## Prerequisites

- Deployed API Gateway with a public dashboard origin, e.g. `https://gateway.example.com`
- Ability to create an Okta OIDC app

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

## 2. Hand values to your FDE

Give your FDE:

- Issuer URL
- Client ID
- Client secret (share through the channel they specify; do not put it in chat history or a ticket)
- Dashboard origin (`https://<DOMAIN_NAME>`)

They enable OIDC on the gateway. The callback defaults to `https://<DOMAIN_NAME>/dashboard/auth/oidc/callback`. Default scopes are `openid`, `email`, and `profile`.

## 3. Invite users before first SSO login

SSO does not auto-create open accounts. Day-0 still uses the bootstrap admin password. Then:

1. Sign in as bootstrap admin (password) at `https://<DOMAIN_NAME>/` (redirects to `/dashboard`)
2. Invite operators whose **email** matches the Okta email claim
3. Invited users choose **Sign in with SSO** on the login page

Uninvited users see a clear rejection page (no account created). Password login remains available as break-glass for the bootstrap admin.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| SSO button missing | Confirm with your FDE that OIDC is enabled on this gateway |
| Callback mismatch | Okta redirect URI vs `https://<DOMAIN_NAME>/dashboard/auth/oidc/callback` |
| Uninvited email | Invite the user (or create an active user) before SSO |

See also [sso-entra.md](sso-entra.md) for Microsoft Entra ID.
