# API Gateway troubleshooting

Triage for alerts raised by a deployed API Gateway. Each section is linked directly from the alert that fires, so you can start here and work down.

## Router worker circuit breaker

Two alerts cover this, and the difference between them is the whole point.

| Alert | Severity | Means |
| --- | --- | --- |
| A model endpoint circuit breaker is open | Warning | One endpoint stopped taking traffic. Others may still serve the model. |
| A model has no endpoint left to serve it | Page | Every endpoint for one model is unusable. Requests for that model are failing. |

### What a circuit breaker is here

The router tracks failures per endpoint. After 5 failed inference requests inside 60 seconds it stops sending that endpoint traffic, which protects the model from a bad endpoint. It waits 30 seconds, then lets one request through to test, and needs 2 successes in a row before it fully reopens.

Traffic is what reopens it. A passing health check will not, because health and the breaker are tracked separately.

### Why a healthy endpoint can be the problem

An endpoint can pass every health check while its breaker is open. On preemptible or spot GPU capacity this is normal: the instance answers a health probe but cannot serve inference, or its replacement is still warming up. So "the endpoint looks healthy" does not clear it.

The gateway dashboard shows this. Open **Staff → Model groups**, pick the group, and look at the endpoint card. An open breaker shows a **breaker open** badge next to the health and sync status. The alert links straight to that card.

### What "open" does not mean

The router re-checks a breaker only when it next tries to route to that endpoint. If traffic moved elsewhere, nothing re-checks it, and the breaker stays open in the alert even though nothing is failing any more.

Read an open breaker as **failed, and not retried since**. It is not proof that anything is broken right now. This is why a single open breaker is a warning: what matters is whether the model still has somewhere to run.

### Triage

1. **Start with the severity.** A warning means customers are probably unaffected. Confirm on the model group page that another endpoint for the same model is active and registered.
2. **Check whether the capacity still exists.** If a spot instance was replaced, the endpoint may point at an address that is gone. The endpoint's route is on its card.
3. **Find out why it failed.** The routing dashboard, filtered to that endpoint's `model_endpoint`, carries its request count, error classes, time to first token, and duration. Failures during long generations look different from failures on every request.
4. **Send it a request.** Recovery needs real traffic. A chat completion against the model, or resuming normal load, is what lets the breaker probe and close. Nothing else will.
5. **Rule out configuration.** This alert only fires after an endpoint was registered and took traffic. If the endpoint never registered, its sync status reads `error` and that is a different problem: check the endpoint's last sync error on the same card.

### When the page fires

Every endpoint for the model is either failing health checks or circuit-broken, so requests for it are being refused.

1. Confirm the affected model from the alert's `logical_model`.
2. Bring back one endpoint. Restoring or replacing capacity for any single endpoint of that model clears the page.
3. If capacity exists but no endpoint is registered, check the model group page for endpoints stuck in `pending` or `error`, and retry the sync from the card.
4. Send a request once an endpoint is back, so its breaker can close.
