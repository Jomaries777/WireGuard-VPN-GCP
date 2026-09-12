# US VPN with Terraform — Beginner Guide (macOS)

Build a WireGuard VPN endpoint in the US, defined entirely as code, so you can create and destroy it with one command.

**Time:** about an hour the first time, two minutes every time after.

---

## Stage 0 — Set your expectations first

**This will not get you into Netflix.** The big streaming services — Netflix, Hulu, Max, Peacock, Disney+ — keep blocklists of datacenter IP ranges, and every GCP, AWS and Azure range is on them. A self-hosted endpoint is among the easiest things for them to spot. You'll get a proxy error, not a video.

**What it does work for:** region-locked YouTube videos, many US news sites, US-only software downloads and pricing pages, and seeing how a site's CDN behaves from a different continent. That last one is actually useful in telecom work.

**The cost trap.** GCP charges roughly $0.12 per GB leaving the VM. An hour of HD video is about 3 GB, so roughly $0.35 per hour of watching. A long weekend can quietly cost more than a year of a commercial VPN. This is the single biggest reason to use Terraform here: `terraform destroy` removes everything in 60 seconds, and `terraform apply` brings it back whenever you need it.

**The terms-of-use point.** Circumventing geo-restrictions violates most streaming services' terms. Not illegal, but it's their contract and they can act on it.

---

## Stage 1 — What Infrastructure as Code actually gets you

Clicking through the Cloud Console works, but it has three problems: you can't remember what you clicked six months later, you can't repeat it reliably, and deleting everything means hunting down each resource individually — which is how people end up paying for forgotten VMs.

Terraform fixes all three. You describe what you want in text files, and it works out what to create, change, or delete.

Four commands are the whole workflow:

| Command | What it does |
|---|---|
| `terraform init` | Downloads the GCP provider plugin. Run once per folder. |
| `terraform plan` | Shows what *would* change. Changes nothing. |
| `terraform apply` | Makes it so. |
| `terraform destroy` | Deletes everything it created. |

The habit to build: **always run `plan` before `apply`**, and actually read the output. It's the difference between a tool you trust and a tool that surprises you.

---

## Stage 2 — Install the tools

Open **Terminal** (Applications → Utilities, or Cmd+Space and type "terminal").

**Homebrew first**, if you don't already have it. It's the package manager everything else on macOS installs through:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

On Apple Silicon Macs the installer finishes by telling you to add Homebrew to your PATH. Do what it says — usually:

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Skipping this is why people get "brew: command not found" immediately after a successful install.

**Then the two tools:**

```bash
brew install --cask gcloud-cli
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

If the first line errors saying the cask doesn't exist, try `brew install --cask google-cloud-sdk` — the package was renamed and which name works depends on your Homebrew version.

Quit Terminal entirely (Cmd+Q, not just closing the window) and reopen it, then verify:

```bash
gcloud --version
terraform --version
```

**Checkpoint:** both print version numbers.

---

## Stage 3 — Prepare your GCP project

```bash
gcloud auth login
gcloud projects create wg-us-vpn-<something-unique> --name="US VPN"
gcloud config set project wg-us-vpn-<something-unique>
```

Project IDs must be globally unique across all of Google Cloud, so add a few random characters.

Link billing: Cloud Console → Billing → link your billing account to this project. A VM won't create without it.

**Set a budget alert now, before anything else.** Billing → Budgets & alerts → Create budget, scoped to this project, set low. Do this before your first `apply`, not after your first surprise.

Enable the API and give Terraform credentials:

```bash
gcloud services enable compute.googleapis.com
gcloud auth application-default login
```

That second command is the one beginners miss. `gcloud auth login` authenticates *you*; `application-default login` creates a separate credential that tools like Terraform read. You need both.

**Checkpoint:** `gcloud compute zones list` prints a long list without errors.

---

## Stage 4 — Understand the files before you run them

Put the four provided files in a folder, say `~/us-vpn/`:

```bash
mkdir -p ~/us-vpn
cd ~/us-vpn
```

Read each one — they're short, and reading them now means the `plan` output in the next stage makes sense.

**`main.tf`** — the resources. A static IP, two firewall rules, and a VM. Notice `google_compute_address.vpn.address` referenced inside the VM block: that's Terraform wiring resources together, and it's also how it works out that the IP must be created before the VM.

**`variables.tf`** — the inputs. Every one has a default except `project_id`, so that's the only thing you must supply.

**`outputs.tf`** — what gets printed after `apply`. Your endpoint IP and the SSH command, so you don't go hunting in the Console.

**`startup-script.sh`** — runs on the VM's first boot. Installs WireGuard, generates the hub's keys, enables IP forwarding and NAT, starts the tunnel, and installs an `add-peer` helper.

**One thing to notice in the startup script:** the key generation is wrapped in `if [ ! -f hub_private.key ]`. Without that, every reboot would generate new keys and silently break every client config. Small detail, painful bug.

The repo also contains a `bootstrap/` folder and a `docs/` folder. Ignore both for now — they're the optional Stage 9, and nothing in Stages 1-8 needs them.

Create `terraform.tfvars` in the same folder:

```hcl
project_id = "wg-us-vpn-<your-unique-id>"
```

And a `.gitignore`, which matters more than it looks:

```
*.tfvars
*.tfstate
*.tfstate.*
.terraform/
```

**Why:** Terraform records everything it built in `terraform.tfstate`, in plain text, including anything sensitive. It's a local file you must never commit or sync to a public repo. This is the most common way people leak cloud credentials. If `~/us-vpn` sits inside iCloud Drive or Desktop-and-Documents sync, move it somewhere that isn't.

---

## Stage 5 — Create the infrastructure

```bash
cd ~/us-vpn
terraform init
terraform plan
```

Read the plan. It should say **4 to add, 0 to change, 0 to destroy** — the address, two firewall rules, and the instance. If it says anything about destroying, stop and work out why.

```bash
terraform apply
```

Type `yes` when prompted. Takes about a minute. At the end you'll see your outputs, including `endpoint`.

**Wait two minutes before the next stage.** `apply` finishes when the VM exists, but the startup script is still installing WireGuard inside it.

**Checkpoint:** `terraform output endpoint` prints an IP and port.

---

## Stage 6 — Add your Mac as a peer

Install **WireGuard** from the Mac App Store (published by WireGuard Development Team — free).

Open it, click **+** at the bottom left → **Add Empty Tunnel**. It generates a key pair and shows the public key at the top. Copy the public key.

Now SSH to the VM:

```bash
cd ~/us-vpn
eval "$(terraform output -raw ssh_command)"
```

First time, gcloud generates an SSH key for you — accept the prompts and leave the passphrase blank unless you want to type it every time.

On the VM:

```bash
sudo add-peer <paste-your-mac-public-key> 10.20.0.2
```

It prints the hub's public key. Copy that, then type `exit` to leave the VM.

Back in the WireGuard app, fill in the tunnel config:

```ini
[Interface]
PrivateKey = <already filled in by the app>
Address = 10.20.0.2/32
DNS = 8.8.8.8

[Peer]
PublicKey = <hub public key you just copied>
Endpoint = <your terraform endpoint output>
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

Save, then click **Activate**. macOS will ask permission to add VPN configurations the first time — approve it.

**The two lines that do the work here:**

`AllowedIPs = 0.0.0.0/0` means *everything* routes through the tunnel. That's what makes you appear American. (In your home tunnel you'd use a narrow range instead — that's the split-versus-full-tunnel choice.)

`DNS = 8.8.8.8` forces name lookups through the tunnel too. Leave it out and your Mac keeps asking your Philippine ISP's resolver, which geolocates you correctly no matter what your IP says. This is the mistake that makes people think their VPN "doesn't work."

**To add your phone as well:** install the WireGuard mobile app, create a tunnel from scratch, and run `sudo add-peer <phone-public-key> 10.20.0.3` on the VM. Same config, different `Address`. Each peer needs its own tunnel IP.

**Checkpoint:** on the VM, `sudo wg show` shows a recent handshake.

---

## Stage 7 — Verify properly

Two separate tests, both needed:

1. Visit any "what is my IP" site. It should show an Oregon address.
2. Visit **dnsleaktest.com** and run the extended test. Every server listed should be US-based. If you see a Philippine ISP, your DNS is leaking — check the `DNS =` line.

You can also confirm from the terminal while the tunnel is up:

```bash
curl ifconfig.me
```

Then try what you came for. Expect YouTube region locks to lift and the major streaming services not to.

**Latency note:** Manila to Oregon is roughly 150–200 ms round trip. Fine for buffered video, noticeable on calls, hopeless for games. Deactivate the tunnel when you're not using it — which also stops the egress meter.

---

## Stage 8 — Destroy it, then bring it back

This is the payoff, and you should practise it now rather than the first time you actually need it.

```bash
cd ~/us-vpn
terraform destroy
```

Type `yes`. Everything is gone, and your billing stops.

When you want it again:

```bash
terraform apply
```

One caveat to notice: the new VM generates a **new key pair**, so you'll redo Stage 6. Your client's own keys survive; only the hub's change.

**Your turn:** that's slightly annoying. Work out how you'd make the hub's identity survive a destroy/apply cycle. There are a few approaches — storing the key in Secret Manager and having the startup script fetch it, or keeping the boot disk and recreating only the instance. Think through what each costs you, in money and in risk. This is a real infrastructure design tradeoff, and reasoning through it is worth more than the answer.

Once you've formed your own view, [`docs/stage-8-persistent-identity.md`](docs/stage-8-persistent-identity.md) works through five options with current prices. Two things in it are worth knowing before you commit to an approach: in this region the VM and its disk are **free** under GCP's Always Free tier, and an external IP costs about **twice as much idle as in use**. Together those make "keep the boot disk and stop the VM" the most expensive option on the list, which is not where most people's intuition lands. Stage 9 below builds the cheap one.

---

## Stage 9 — Optional: keep the hub's identity across destroy cycles

Skip this until Stage 8 has annoyed you at least twice. It's the answer to that exercise, and
it costs **$0.20/month** while the VPN is destroyed, or $0.00 if you don't own a domain.

The idea: split the project into two Terraform states. The `bootstrap/` folder holds the things
that must outlive a destroy — the hub's key, the VM's service account, a DNS zone. The root
folder stays disposable exactly as it is now.

Why a separate folder rather than a `prevent_destroy` lifecycle rule: **`prevent_destroy` does
not exempt a resource from `terraform destroy`, it makes the whole destroy fail.** You'd get a
half-torn-down stack and a VM still billing. Separating lifecycles into separate states is the
mechanism that actually works, and it's what real platform teams do.

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars     # set project_id
terraform init
terraform apply
terraform output -raw root_tfvars >> ../terraform.tfvars
cd ..
```

That's it for the key — `bootstrap/` also enables the Secret Manager API, so there's nothing to
turn on by hand. The secret starts empty; the VM generates the hub key on its first boot and
publishes version 1 itself, so the private key never touches your laptop or any state file.

Two optional extras in `terraform.tfvars`, both worth it:

**A stable hostname.** If you own a domain, set `dns_domain = "example.com."` in
`bootstrap/terraform.tfvars` before applying, then point your registrar's nameservers at
`terraform output dns_name_servers`. Clients pin `vpn.example.com:51820` and never need editing
again. Without this the hub key survives but the IP still changes, so you'd still be editing
every client — which was most of the annoyance.

**Peers as code.** Declare your devices instead of SSHing in after every apply:

```hcl
peers = {
  macbook = { public_key = "<your Mac's public key>",   tunnel_ip = "10.20.0.2" }
  phone   = { public_key = "<your phone's public key>", tunnel_ip = "10.20.0.3" }
}
```

Client *public* keys are not secrets, so this costs nothing in risk. Note the consequence:
declared peers become the source of truth, so a peer added with `add-peer` on the VM will
disappear on the next apply. That's the right behaviour and it will still catch you once.

**Now do the test that matters:**

```bash
terraform apply && sleep 120
terraform output identity_survives_destroy
eval "$(terraform output -raw hub_public_key_command)"     # note the key
terraform destroy && terraform apply && sleep 120
eval "$(terraform output -raw hub_public_key_command)"     # same key
```

Same hub key, same endpoint name, peers already configured. Deactivate and reactivate the
tunnel in the WireGuard app — it resolves the `Endpoint` name at activation, not continuously,
so a tunnel left active across the cycle will fail its handshake until you toggle it.

**Checkpoint:** you edited no client config and never opened an SSH session.

---

## Checking your changes

If you edit any of these files, run this before you apply anything:

```bash
./scripts/check.sh
```

It checks formatting, validates both configs, renders the startup script and confirms the
result is valid bash, and proves the input validations still reject bad peer keys. It needs no
GCP project and takes a few seconds. GitHub Actions runs the same script on every pull request.

The one worth knowing about is the render. `terraform validate` does **not** evaluate
`templatefile()`, so a mistyped `${...}` in `startup-script.sh` passes validate and only fails
at apply, after you've waited for a VM to build. Rendering it up front turns a ten-minute
mistake into a two-second one.

---

## What you'll have learned

- **Terraform:** providers, resources, variables, outputs, implicit dependencies, state and why it's sensitive, the plan-then-apply habit, destroy as a normal operation
- **GCP:** projects and billing, API enablement, application default credentials, static IPs, firewall rules with target tags, startup scripts
- **Networking:** full versus split tunnel routing, source NAT, DNS leaks and why they defeat a working VPN, IP-based geolocation and its limits
- **From Stage 9, if you did it:** splitting one project across two states by lifecycle, why `prevent_destroy` isn't the tool it looks like, secrets fetched at boot from an instance's own identity, service accounts and least privilege, and reading a pricing page before trusting your instinct about cost

**The transferable bit:** this is the same discipline behind reproducible environments at work. When an infrastructure team says a change is "in the Terraform," you now know what that means — the code is the source of truth, and the console is just a view of it.
