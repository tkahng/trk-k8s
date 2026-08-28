# kubeadm learning cluster — command shortcuts
# Provider-specific bits are isolated to variables so an infra swap
# (aws -> azure -> hetzner -> on-prem) only changes this header. Swapped
# three times now — aws->azure (ADR 009), azure->aws (ADR 010), and back
# to azure 2026-08-17 to burn credits before they expire Sept 4 — and
# cluster/ was untouched every time.

INFRA_DIR      := infra/azure
SSH_KEY        := ~/.ssh/azure_k8s
# Wrapper that loads the service principal + azblob state creds before every
# call (infra/azure/pulumi.sh). Replaces AWS's passphrase-file env var: the
# secrets provider is now Azure Key Vault, so nothing unrecoverable lives on
# this laptop.
PULUMI         := $(CURDIR)/infra/azure/pulumi.sh

# The persistent half of ADR 008's lifecycle boundary is NOT a Pulumi stack
# on Azure — resource groups model it natively, so foundation.sh creates
# rg-trk-k8s-persistent (state, Key Vault, later backups) and locks it
# CanNotDelete. `destroy` cannot touch it; that's the platform enforcing what
# a second Pulumi stack enforced by convention on AWS.
FOUNDATION     := infra/azure/foundation.sh

# --- Phase 8: the Talos comparison cluster -------------------------------
# A SEPARATE stack, resource group and kubeconfig, so the two clusters never
# fight over state or the 10-vCPU quota — but only one can exist at a time
# (3 nodes each = 10 vCPUs). `make destroy` before `make talos-up`.
# Its own pulumi.sh because the project directory differs; the stack is
# named `talos` and passed explicitly so a stray `pulumi stack select`
# elsewhere cannot retarget these commands.
TALOS_DIR      := infra/azure-talos
TALOS_PULUMI   := $(CURDIR)/infra/azure-talos/pulumi.sh --stack talos
TALOS_KUBECFG  := $(CURDIR)/kubeconfig-talos
TALOSCONFIG    := $(HOME)/.config/trk-k8s/talos/talosconfig

# node name → public IP, straight from the inventory contract
node_ip = $(shell cd $(INFRA_DIR) && $(PULUMI) stack output nodes | jq -r '.[] | select(.name=="$(1)").publicIp')

.PHONY: help login preview up destroy nodes outputs check-ip set-myip ssh-cp ssh-worker-1 ssh-worker-2 kubeconfig bootstrap platform rebuild foundation foundation-show \
	talos-image talos-up talos-preview talos-destroy talos-nodes talos-check-ip talos-bootstrap talos-kubeconfig talos-dashboard talos-rebuild

help: ## list available targets
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

login: ## refresh Azure CLI credentials (run when the session expires)
	az login

preview: ## show what pulumi would change
	cd $(INFRA_DIR) && $(PULUMI) preview

up: check-ip ## create/update the cluster machines
	cd $(INFRA_DIR) && $(PULUMI) up --yes

destroy: ## tear down the CLUSTER resource group (rg-trk-k8s-persistent survives — it is locked)
	cd $(INFRA_DIR) && $(PULUMI) destroy --yes

foundation: ## ONE TIME: create rg-trk-k8s-persistent (pulumi state, key vault, sp). Idempotent.
	$(FOUNDATION)

foundation-show: ## print the foundation config this repo is wired to
	@cat $(HOME)/.config/trk-k8s/azure-foundation.env | grep -v '^#'

nodes: ## print the node inventory (the provider-agnostic contract)
	@cd $(INFRA_DIR) && $(PULUMI) stack output nodes | jq .

outputs: ## print all stack outputs
	@cd $(INFRA_DIR) && $(PULUMI) stack output

# The SG only admits myIp for SSH/6443/NodePorts — if your public IP drifts
# (ISP lease, different network), every rebuild locks you out at "wait for
# SSH". Learned the hard way 2026-07-18; `up` now runs this preflight.
check-ip: ## sync stack config myIp with your current public IP (auto-runs before `up`)
	@current="$$(curl -sf --max-time 10 https://checkip.amazonaws.com)"; \
	if [ -z "$$current" ]; then echo "check-ip: WARN could not reach checkip.amazonaws.com, skipping"; exit 0; fi; \
	cd $(INFRA_DIR); configured="$$($(PULUMI) config get myIp)"; \
	if [ "$$current/32" != "$$configured" ]; then \
		echo "check-ip: myIp drift ($$configured -> $$current/32), updating stack config"; \
		$(PULUMI) config set myIp "$$current/32"; \
	else echo "check-ip: myIp OK ($$configured)"; fi

set-myip: check-ip ## manually sync the admin IP, then remind to apply (kept for muscle memory)
	@echo "now run: make up"

bootstrap: ## kubeadm + cilium on the provisioned machines (runbooks 02+03, scripted)
	@cd $(INFRA_DIR) && $(PULUMI) stack output nodes > /tmp/trk-inventory.json
	cluster/bootstrap.sh /tmp/trk-inventory.json $(SSH_KEY)

platform: ## storage/ingress/tls/gitops addons (runbooks 04+05, scripted)
	cluster/platform.sh --provider=azure

rebuild: ## the full drill: destroy -> up -> bootstrap -> platform
	$(MAKE) destroy
	$(MAKE) up
	$(MAKE) bootstrap
	$(MAKE) platform

kubeconfig: ## fetch admin kubeconfig from the control plane to ./kubeconfig (gitignored)
	scp -q -i $(SSH_KEY) ubuntu@$(call node_ip,k8s-cp-1):.kube/config ./kubeconfig
	sed -i '' "s|https://10.0.1.10:6443|https://$(call node_ip,k8s-cp-1):6443|" ./kubeconfig
	@echo "use with: export KUBECONFIG=$$(pwd)/kubeconfig"

ssh-cp: ## ssh into the control plane
	ssh -i $(SSH_KEY) ubuntu@$(call node_ip,k8s-cp-1)

ssh-worker-1: ## ssh into worker 1
	ssh -i $(SSH_KEY) ubuntu@$(call node_ip,k8s-worker-1)

ssh-worker-2: ## ssh into worker 2
	ssh -i $(SSH_KEY) ubuntu@$(call node_ip,k8s-worker-2)

# ===================== Phase 8 — Talos =====================
# Note there is no talos-ssh: Talos has no shell and no SSH daemon. Node
# access is `talosctl` on :50000, which is why talos-dashboard exists.

talos-image: ## ONE TIME per Talos version: build the Azure managed image (idempotent)
	$(TALOS_DIR)/image.sh

talos-check-ip: ## sync the Talos stack's myIp with your current public IP
	@current="$$(curl -sf --max-time 10 https://checkip.amazonaws.com)"; \
	if [ -z "$$current" ]; then echo "talos-check-ip: WARN could not reach checkip, skipping"; exit 0; fi; \
	cd $(TALOS_DIR); configured="$$($(TALOS_PULUMI) config get myIp)"; \
	if [ "$$current/32" != "$$configured" ]; then \
		echo "talos-check-ip: myIp drift ($$configured -> $$current/32), updating"; \
		$(TALOS_PULUMI) config set myIp "$$current/32"; \
	else echo "talos-check-ip: myIp OK ($$configured)"; fi

talos-preview: ## show what the Talos stack would change
	cd $(TALOS_DIR) && $(TALOS_PULUMI) preview

talos-up: talos-check-ip ## create the Talos machines (destroy the kubeadm cluster first — shared quota)
	cd $(TALOS_DIR) && $(TALOS_PULUMI) up --yes

talos-destroy: ## tear down the Talos machines (the managed image survives — it is in the locked RG)
	cd $(TALOS_DIR) && $(TALOS_PULUMI) destroy --yes

talos-nodes: ## print the Talos node inventory (same contract, sshUser is meaningless)
	@cd $(TALOS_DIR) && $(TALOS_PULUMI) stack output nodes | jq .

talos-bootstrap: ## machine configs + etcd bootstrap + kubeconfig (replaces prep-node/kubeadm entirely)
	@cd $(TALOS_DIR) && $(TALOS_PULUMI) stack output nodes > /tmp/talos-inventory.json
	cluster-talos/bootstrap.sh /tmp/talos-inventory.json

talos-kubeconfig: ## re-fetch the Talos kubeconfig to ./kubeconfig-talos
	@TALOSCONFIG=$(TALOSCONFIG) talosctl kubeconfig $(TALOS_KUBECFG) --force
	@echo "use with: export KUBECONFIG=$(TALOS_KUBECFG)"

talos-dashboard: ## live node view (the closest thing to ssh-ing into a Talos node)
	@TALOSCONFIG=$(TALOSCONFIG) talosctl dashboard

talos-rebuild: ## the Phase 8 drill: destroy -> up -> bootstrap
	$(MAKE) talos-destroy
	$(MAKE) talos-up
	$(MAKE) talos-bootstrap
