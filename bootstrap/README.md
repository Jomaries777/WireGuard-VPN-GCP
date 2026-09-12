# bootstrap — apply once, then leave alone

This folder holds the handful of things that must survive `terraform destroy` in the parent
folder: the hub's WireGuard identity, the service account that reads it, and optionally a DNS
zone so clients can pin a hostname instead of an IP.

It is a **separate Terraform state on purpose.** `lifecycle { prevent_destroy = true }` would
not work here — it doesn't exclude a resource from `terraform destroy`, it makes the whole
destroy fail. Separating lifecycles into separate states is the real mechanism. The reasoning,
with prices, is in [`../docs/stage-8-persistent-identity.md`](../docs/stage-8-persistent-identity.md).

**Standing cost:** $0.20/month if you enable DNS, otherwise $0.00. Secret Manager's free tier
covers everything this folder uses.

## Use it

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set project_id; add dns_domain if you have one
terraform init
terraform plan
terraform apply
```

Then copy the handoff block into the parent folder's `terraform.tfvars`:

```bash
terraform output -raw root_tfvars >> ../terraform.tfvars
```

If you set `dns_domain`, point your registrar's nameservers at the four values in
`terraform output dns_name_servers`. Until you do, the hostname will not resolve and no client
will connect.

The secret starts **empty**. The VM generates the hub key on its first boot and adds version 1
itself, so the private key never passes through your laptop or any state file. To do it
yourself instead, set `allow_vm_to_seed_key = false` and run:

```bash
brew install wireguard-tools
wg genkey | gcloud secrets versions add wg-us-hub-key --data-file=-
```

## Don't destroy this

Tearing this folder down deletes the hub key, which breaks every client config — the exact
problem the parent folder's Stage 8 exercise is about. If you genuinely want to start over,
destroy the parent folder first, then this one.
