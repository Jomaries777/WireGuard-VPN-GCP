# Stage 8 worked through — making the hub's identity survive destroy/apply

Stage 8 of the README ends with an exercise: the hub generates a new key pair on every
`apply`, so every client config breaks, and you're asked to work out how you'd fix that and
what each approach costs.

**Go and think about it before reading this.** The reasoning is the point, and the answer
below is more interesting if you've already formed your own.

---

## 1. State the problem precisely

`startup-script.sh` generates the hub's key pair on first boot:

```bash
if [ ! -f hub_private.key ]; then
  wg genkey | tee hub_private.key | wg pubkey > hub_public.key
fi
```

That guard survives a *reboot*, because the file is still on the disk. It does not survive a
*destroy*, because the disk goes with the VM — `boot_disk` is declared with
`initialize_params`, which means it's created with the instance and deleted with it.

So far so obvious. The more useful move is to ask what a client config actually pins, because
that's the real definition of "the hub's identity":

```ini
[Peer]
PublicKey = <hub public key>      # lost: generated on the boot disk
Endpoint  = <IP>:51820            # lost: google_compute_address is released on destroy
AllowedIPs = 0.0.0.0/0
```

And server-side, the peer list in `wg0.conf` is also on that disk, so every device has to be
re-added with `add-peer` too.

**Three things are destroyed, not one.** Persisting only the hub key gets you a third of the
way: you'd still edit the `Endpoint` line in every client and still SSH in to re-add every
peer. Since editing a client config is the cost we're trying to avoid, and you have to open
it anyway to change the endpoint, fixing only the key buys almost nothing. That reframing
drives everything below.

---

## 2. Get the cost model right first

This is where my first instinct was wrong, and it's worth being slow here, because the prices
invert the obvious answer.

Two facts about the default configuration (`e2-micro`, `us-west1`, 10 GB `pd-standard`):

**The VM and its disk are free.** GCP's Always Free tier includes one non-preemptible
`e2-micro` for 744 hours a month — a full month — in `us-west1`, `us-central1` or `us-east1`,
plus 30 GB-months of standard persistent disk. `variables.tf` defaults to `us-west1` and a
10 GB `pd-standard` disk, so it lands inside the free tier. (Per billing account, so another
`e2-micro` elsewhere eats the same allowance.)

**The external IPv4 is not free, and it costs more when idle.** Since February 2024 GCP
charges for all external IPv4 addresses:

| external IPv4 state | per hour | per month |
| --- | --- | --- |
| attached to a **running** standard VM | $0.005 | ~$3.65 |
| reserved but **unused**, or attached to a **stopped** VM | $0.010 | ~$7.30 |

Put those together and a counterintuitive result falls out:

> **Stopping the VM costs about twice what leaving it running costs.** The compute is free
> either way, so all you do by stopping it is move the IP from the in-use rate to the idle
> rate.

That single fact demolishes one of the two approaches the README suggests, and it means the
thing to optimise is not the VM at all. It's the IP.

Everything else in play, for scale:

| item | price | at this scale |
| --- | --- | --- |
| Secret Manager, active secret version | $0.06 / version / month | **$0.00** — free tier covers 6 versions |
| Secret Manager, access operations | $0.03 / 10,000 | **$0.00** — free tier covers 10,000/month; we use ~1 per boot |
| Cloud DNS managed zone | $0.20 / zone / month | $0.20 |
| Cloud DNS queries | $0.40 / million | rounds to $0.00 |
| standard regional snapshot | $0.05 / GB / month | ~$0.10 for a ~2 GB boot-disk snapshot |
| 10 GB `pd-standard` | ~$0.04 / GB / month | $0.00 under the free tier |
| **network egress** | **~$0.12 / GB** | **dominates everything else** |

Keep that last row in perspective. Every option here is worth a few dollars a month at most.
One evening of HD video is ~3 GB, about $0.35. The persistence decision is a rounding error
next to how much you *watch*, so optimise it for risk and for your own time, not for cents.

*Prices checked 2026-09-12 against the Secret Manager, VPC network, Cloud DNS and disk
pricing pages, at `us-central1`/`us-west1` baselines. Verify before relying on them; Google
changes them, and the 2024 IPv4 change is exactly the kind of thing that invalidates old
advice.*

---

## 3. The five options

### Option A — Secret Manager holds the hub key

Store the private key in Secret Manager; the VM fetches it at boot using its service account.

**Money:** $0.00. One secret version and one access per boot are both inside the free tier.

**Risk:**
- The private key now lives somewhere that *outlives a destroy*. That is the whole point, but
  it also means the safety property "destroy removes everything" no longer covers your
  identity. Abandon the project and the key lingers.
- Anyone with `secretAccessor` on that secret can read the hub key without touching the VM.
  Scope the binding to the one secret, not the project.
- The VM needs an identity that can read it. Today `main.tf` gives the VM the *default*
  compute service account with `cloud-platform` scope, which in older projects carries Editor
  on everything. Replacing that with a dedicated service account holding one role on one
  secret makes the VM **less** privileged than it is now. This option improves security as a
  side effect.
- New failure mode: if the fetch fails and the script falls back to generating a key, the
  tunnel comes up perfectly and no client can connect. Handle each outcome distinctly, and
  fail loudly rather than silently taking on a different identity.

**Catch:** the secret must not be in the destroy set. See §4.

### Option B — keep the boot disk, recreate only the instance

Declare a standalone `google_compute_disk`, set `auto_delete = false`, boot the instance from
it.

**Money:** $0.00 for the disk itself under the free tier — but it doesn't work as stated. A
`google_compute_disk` in the config is destroyed by `terraform destroy` like anything else.
To keep it you must take it out of the destroy set, and then you're doing §4 anyway, for a
resource that's much heavier than a secret.

**Risk:** a boot disk is a big mutable blob of state. It accumulates whatever the last apply
left behind, so `wg0.conf` may not match the current startup script. That's exactly the drift
Terraform exists to prevent, and it's the most valuable thing this project is teaching. High
risk, no money saved, more complexity.

### Option C — never destroy; stop the VM instead

**Money:** ~$7.30/month, because the IP moves to the idle rate while the compute stays free.
Leaving the VM *running* is ~$3.65/month. So the cheapest way to have a permanently stable
endpoint is to never stop the VM — and the "save money by stopping it" instinct is backwards.

**Risk:** near zero technically. No new APIs, no IAM, no secrets; the key, the peers and the
IP all persist because nothing is ever deleted. Honest assessment: for someone who uses the
VPN weekly and values their own time, this is defensible. It costs a few dollars a month and
zero thought.

But it gives up the discipline the project is built around, and it leaves a permanently
reachable box on the internet accruing patches you're not applying. Also, if egress is what
you're afraid of, note that a running VM doesn't generate egress on its own — an idle
endpoint is cheap. The reason to destroy is not the VM, it's the habit.

### Option D — snapshot the boot disk, restore on apply

**Money:** ~$0.10/month for a ~2 GB standard snapshot; ~$0.04 with an archive snapshot,
though those bill a 90-day minimum, which is longer than you'll want to keep any one image.

**Risk:** you've replaced config-as-code with a golden image. The OS freezes at snapshot time,
so you stop getting a freshly patched Ubuntu on each apply — one of the quiet benefits of
rebuilding from a public image. And the snapshot's contents silently outrank the startup
script, so editing the script stops having any effect and you get to spend an evening finding
out why. Cheap in dollars, expensive in the failure mode.

### Option E — don't persist anything; make re-provisioning free

The option the README doesn't hint at, and the one a platform engineer will suggest: if
re-pairing is cheap enough, persistence stops being a requirement. Have the startup script
generate the hub key *and* complete client configs, render them as QR codes with `qrencode`,
and print them. Re-adding a phone becomes a camera scan.

**Money:** $0.00.

**Risk:** the client private keys now come from the server, so they exist somewhere other than
the client — a genuine weakening of the model. Put them in serial-console output and anyone
with `compute.instances.getSerialPortOutput` can read every key, so write to a file and read
it over SSH instead. And it's still per-device manual work on every cycle; it just shrinks it
from minutes to seconds.

Worth naming because it's the *cattle, not pets* answer and the instinct generalises. It's not
the best fit here only because the fix for the endpoint (§5) also removes the need for it.

---

## 4. The thing that actually makes this work: the destroy boundary is a state boundary

Every option above shares one problem. Whatever holds your identity must survive
`terraform destroy`, and the only reliable way to arrange that is for Terraform not to own it
in the state you're destroying.

The tempting wrong answer:

```hcl
resource "google_secret_manager_secret" "hub_key" {
  lifecycle { prevent_destroy = true }   # does NOT do what you want
}
```

`prevent_destroy` does not exempt a resource from `terraform destroy`. It makes the whole
destroy **fail**, with the resource still there and nothing else torn down either. For a
project whose entire value proposition is one-command teardown, that turns a safety feature
into an outage in your billing. You'd be reaching for `terraform state rm` or `-target` every
time — precisely the hand-tuning IaC is meant to abolish.

The right answer is to split the stack along its lifecycle:

```
bootstrap/     long-lived. Applied once. Holds identity.   ~$0.20/month
   ├── secret container for the hub key
   ├── service account + IAM, scoped to that one secret
   ├── the Secret Manager API enablement
   └── DNS managed zone

./             disposable. terraform destroy / apply at will.
   ├── static IP, two firewall rules, the VM
   └── the DNS A record pointing at today's IP
```

Two states, two lifecycles. This is the transferable lesson, and it's the same reason real
platform teams keep a "bootstrap" or "foundation" stack apart from per-environment stacks:
**a resource's lifecycle, not its type, decides which state it belongs in.** The service
account sits in bootstrap for the same reason — an identity destroyed and recreated on every
cycle hits GCP's service-account soft-delete and IAM propagation edges for no benefit.

---

## 5. Fixing the endpoint without paying for an idle IP

Persisting the key still leaves the `Endpoint` line changing every cycle, and §2 says holding
the reserved IP through a destroy is the single most expensive option on the table (~$7.30/mo,
more than never destroying at all).

So don't pin an address. Pin a **name**:

- `bootstrap/` holds a Cloud DNS managed zone — $0.20/month, and it needs a domain you
  delegate to Google's nameservers.
- The root config writes an A record for today's IP on every apply, TTL 60.
- Clients pin `vpn.example.com:51820` and never change again.

Two caveats, both real:

1. WireGuard resolves `Endpoint` when the tunnel is **activated**, not continuously. After an
   apply you must deactivate and reactivate the tunnel to pick up the new address. You were
   going to toggle it anyway, so this costs nothing — but a client left "active" across a
   destroy/apply will fail its handshake with no useful error. Hence TTL 60: a stale cache
   should expire in a minute, not five.
2. No domain means no Cloud DNS zone. A free dynamic-DNS provider works and costs $0, at the
   price of a third-party dependency and an update token that itself needs storing. Or skip
   DNS, accept the churning IP, and read the new endpoint from `terraform output`.

**A nice second-order consequence:** once clients pin a hostname, the *reserved* IP has no
job left. `google_compute_address` exists in `main.tf` solely to keep the endpoint stable
across restarts. An ephemeral IP costs the same while attached, disappears cleanly on destroy,
and can't be left behind quietly billing at the idle rate if a destroy half-fails. Keeping it
is now a convenience, not a requirement. Left in place here so the README's Stage 1 reasoning
still matches the code, but removing it is a fair next exercise.

---

## 6. What this repo implements, and why

**Option A + DNS + declared peers**, all opt-in.

| | while destroyed | while up |
| --- | --- | --- |
| this design | **$0.20/month** (DNS zone; secret is free) | ~$0.005/hr for the IP, plus egress |
| persist the reserved IP instead | ~$7.30/month | — |
| stop the VM instead of destroying | ~$7.30/month | — |
| leave the VM running | — | ~$3.65/month |
| today, no persistence | $0.00 | ~$0.005/hr, plus a rebuilt identity every time |

Three decisions inside it worth defending:

**The VM writes the first key version itself.** The script asks for the latest version; on
`NOT_FOUND` it generates a key pair and adds version 1. So the private key is never on your
laptop, never in a shell history, and never in a Terraform state file. The cost is that the
VM's service account needs `secretVersionAdder` as well as `secretAccessor`. That is a real
widening — a compromised VM could add versions — but it's scoped to one secret, and the
alternative puts the key through your local machine. If you'd rather have the narrower grant,
generate it yourself once and drop the adder role:

```bash
brew install wireguard-tools
wg genkey | gcloud secrets versions add wg-us-hub-key --data-file=-
```

**Peers are declared, not added by hand.** Client *public* keys are not secrets, so a `peers`
map in `terraform.tfvars` costs nothing in money or exposure and removes the SSH step
entirely. The consequence to keep in mind: declared peers become the source of truth, so a
peer added with `add-peer` on the VM disappears on the next apply. That's correct behaviour
and it will still surprise you once.

**Every new variable defaults to today's behaviour.** `hub_key_secret_id = ""` means generate
on the VM exactly as before. Someone working through Stages 1-7 for the first time sees no
extra moving parts, and the exercise still reads as an exercise.

---

## 7. If you only remember three things

1. **Check the prices before trusting your instinct about them.** "Stop the VM to save money"
   is wrong here by a factor of two, and free-tier compute is why.
2. **`prevent_destroy` is not "exclude from destroy".** It fails the destroy. Separate
   lifecycles into separate states instead.
3. **Work out what's actually pinned.** The hub key was the visible symptom; the endpoint and
   the peer list were the other two thirds of the problem, and solving all three is what turns
   `apply` into something you can do without reading your own notes.

## Sources

- [Secret Manager pricing](https://cloud.google.com/secret-manager/pricing)
- [VPC network pricing (external IP addresses)](https://cloud.google.com/vpc/network-pricing)
- [External IPv4 pricing change announcement](https://cloud.google.com/vpc/pricing-announce-external-ips)
- [Free Google Cloud features (Always Free tier)](https://cloud.google.com/free/docs/free-cloud-features)
- [Disk and image pricing (snapshots)](https://cloud.google.com/compute/disks-image-pricing)
- [Cloud DNS pricing](https://cloud.google.com/dns/pricing)
