# BeautyBook

Two containers on the shared `meshcaster` network, both deployed from
`MeshCaster/Meshcaster.BeautyBook` via `.github/workflows/deploy.yml`:

| Container | Reached via | Host port |
|-----------|-------------|-----------|
| `beautybook-api` | nginx → `beautybook.in-vent.online` ([vhost](nginx/beautybook.conf)) | 5110 |
| `beautybook-admin` | Cloudflare tunnel → `beautybook-admin.in-vent.online` | none |
| `beautybook-my` | nginx → `beautybook-my.in-vent.online` | none |

The panel's hostname is **second-level on purpose**. Cloudflare's Universal SSL covers
`*.in-vent.online` and no deeper, so a third-level name like `admin.beautybook.in-vent.online`
cannot complete a TLS handshake at all — it resolves to Cloudflare and then fails, which reads like
an outage rather than a missing certificate. (`admin.mediathek.in-vent.online` has the same shape and
only works because **nginx** terminates TLS for it with a per-hostname Let's Encrypt certificate;
that does not transfer to a tunnel-served host.) Anything reached through the tunnel needs either a
second-level name or an Advanced Certificate.

The operator panel publishes no host port on purpose. nginx never proxies it, so it cannot be
reached by IP or by a stray `Host` header — only down the tunnel.

`beautybook-my` is the **same image** run a second time for salon owners, who cannot pass the
tunnel's Access policy because that policy is an operator email list. Its env file sets
`Panel__SalonOnly=true`, which makes it refuse the platform-wide pages to everyone — the image
picks between the two consoles by claim, so without that flag an operator signing in there would
have root CRUD over every salon from a public URL. It also deliberately omits
`Identity__ClientSecret`: the machine-to-machine token is only fetched for a root operator, and
there cannot be one, so the internet-facing container never holds the platform-wide credential.

Its env file (`/opt/meshcaster/beautybook-my.env`), created once:

```
Panel__SalonOnly=true
Identity__PanelClientId=beautybook-panel
Identity__PanelClientSecret=<same value as the admin instance>
```

Startup fails outright if `Panel__SalonOnly` is set without sign-in configured — honouring it
without an authentication scheme yields a 500 on every page, and ignoring it would publish the
platform-wide surface.

## Turning on salon-owner sign-in

The panel started life with **no login of its own**: Cloudflare Access authenticated an operator at
the edge and everyone who got through was implicitly a platform admin. It can now sign users in
against MeshCaster.Identity, which is what lets a salon owner manage their own catalog
(`/salon-admin`) while operators keep the platform-wide surface (`/api/admin`).

Both sides stay switched off until configured. The panel enables sign-in only when
`Identity:PanelClientId` **and** `Identity:PanelClientSecret` are set; Identity registers the client
only when `Seeding:BeautyBookPanelClient` is true. That is deliberate — turning either on before
the other locks people out, so the order below matters.

### 1. Generate the shared secret

```bash
openssl rand -base64 32
```

One value, used in two places. It must **differ** from `BeautyBook__AdminClientSecret`, which is the
machine-to-machine credential for the root surface — reusing it would give every person who signs in
the platform-wide client's credential.

### 2. Teach Identity about the client

On the host, add to Identity's env file:

```
BeautyBook__PanelClientSecret=<the secret>
Seeding__BeautyBookPanelClient=true
```

The redirect URIs themselves live in Identity's `appsettings.Production.json` and need nothing
here. Then redeploy Identity. OpenIddict matches redirect URIs **exactly**, and the seeder refuses to fall
back to its localhost development default outside Development — so a missing or wrong URI fails
startup by name rather than surfacing later as `invalid_redirect_uri` at sign-in.

> Identity is the platform's token issuer. If it fails to start, every service that validates a
> token against it goes with it. Check the deploy before moving on.

### 3. Teach the panel to use it

Add to `/opt/meshcaster/beautybook-admin.env`:

```
Identity__PanelClientId=beautybook-panel
Identity__PanelClientSecret=<the same secret>
Panel__RootUsers=you@example.com,colleague@example.com
Panel__RootUsers=you@example.com,colleague@example.com
```

`Identity__Authority` is already published in the image
(`https://identity.in-vent.online`). Redeploy the panel.

**`Panel__RootUsers` is not optional in practice.** It is the list of emails treated as platform
operators, and without it nobody reaches the platform-wide pages: the alternative test is Identity's
global `root` role, which is granted only by Identity's demo-data seeder and is therefore held by no
production account. Get it wrong and you sign in successfully, land on `/no-access`, and need
another deploy to get back — so check the addresses against the Identity accounts you actually sign
in with, and use the same comma-separated form above (docker env files understand no array syntax).

The panel logs a warning at startup when sign-in is on and this list is empty.

At this point every visitor is asked to sign in. Operators need the global `root` role in Identity;
a salon's own people need to be members of that salon's organization, which is what puts
`merchant_id` on their token.

### 4. Remove the Cloudflare Access policy

Zero Trust → Access → Applications → the app for `beautybook-admin.in-vent.online`.

Access authenticates against an **operator email allow-list**, so leaving it on means no salon owner
can reach the panel at all. The panel authenticates its own users now, and the API independently
re-derives the caller's salon from their token — a signed-in salon operator cannot reach another
salon's data, or the root surface, whichever URL they type.

Do this **last**. Until step 3 is deployed the panel still has no login, and dropping Access before
then would leave it open.

## Rolling back

Remove `Identity__PanelClientId` / `Identity__PanelClientSecret` / `Panel__RootUsers` from the
panel's env file and
redeploy. Sign-in switches off and the panel returns to its previous behaviour. Put the Access
policy back at the same time — without it the panel would then be open.

Leaving `Seeding__BeautyBookPanelClient=true` on Identity is harmless: the client simply sits
unused.
