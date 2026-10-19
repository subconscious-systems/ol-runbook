# SSO-only dashboard deployments

By default the dashboard offers two sign-in paths: OIDC SSO (when enabled) and email plus password. Some deployments turn password login **off** so corporate SSO is the only way in. This page describes what changes, and how break-glass works when SSO is unavailable.

Only your FDE can flip this setting; it is a gateway deployment value, not a dashboard toggle.

## What an SSO-only deployment does

| Surface | Behavior |
| --- | --- |
| Login page | Shows the SSO button only; no email/password form |
| `POST /dashboard/login` | Returns 404 before any credential checks |
| Password reset links | Mint and redemption both return 404 |
| Invite acceptance | The set-password form is gone; invitees sign in with SSO and their email match completes the invite |
| Profile password change | Refused; name and time preferences still save |

Sessions signed in before the flip keep working until they expire; the kill is on password **login**, not live sessions.

## Requirements

- OIDC SSO must be enabled and working. The gateway refuses to start with password login off but SSO off, so a half-configured flip cannot lock the deployment.
- A hosted-domain restriction (the Google Workspace `hd` param and claim, where the IdP is Google) is strongly recommended so only your domain's accounts can sign in.
- The invite flow becomes the only onboarding path: a superuser invites an operator by their IdP email, and the operator's first SSO sign-in creates the account. There is no open JIT provisioning.
- The bootstrap admin's email must equal a real IdP address. After the flip, the bootstrap password can no longer sign in; the SSO email match is the way in.

## Break-glass

If the IdP is down and you need dashboard access:

1. Ask your FDE to flip `passwordLoginEnabled` back to `true` and redeploy the gateway
2. Sign in with the bootstrap admin password
3. Flip SSO-only back on once SSO works again

The redeploy is the recovery window; plan for the deployment's normal rollout time.
