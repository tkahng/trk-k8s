# kubeadm learning cluster — command shortcuts
# Provider-specific bits are isolated to variables so an infra swap
# (aws -> azure -> hetzner -> on-prem) only changes this header. Swapped
# four times now — aws->azure (ADR 009), azure->aws (ADR 010), back to
# azure (ADR 011), and azure->hetzner 2026-09-03 for Phase 9 — the first
# time infra/hetzner has ever run. cluster/ was untouched every time.
#
# The Azure-era Talos targets (Phase 8) and foundation.sh live in git
# history at 2913ee3; the Azure subscription is at zero (ADR 010 checklist
# re-run 2026-09-03).

INFRA_DIR      := infra/hetzner
SSH_KEY        := ~/.ssh/hetzner_k8s
# Pulumi state stays in the AWS S3 backend that survived every era
# (s3://tkahng-pulumi-state, profile personal-admin); secrets are
# passphrase-encrypted in the state file, as on AWS. Hetzner itself is
# reached with the project API token in stack config (hcloud:token).
AWS_PROFILE    := personal-admin
PULUMI         := AWS_PROFILE=$(AWS_PROFILE) PULUMI_CONFIG_PASSPHRASE_FILE=$(HOME)/.config/pulumi/trk-k8s.passphrase pulumi

# node name → public IP / ssh user, straight from the inventory contract.
# sshUser is part of the contract for exactly this swap: root on Hetzner,
# ubuntu on AWS/Azure.
node_ip   = $(shell cd $(INFRA_DIR) && $(PULUMI) stack output nodes | jq -r '.[] | select(.name=="$(1)").publicIp')
node_user = $(shell cd $(INFRA_DIR) && $(PULUMI) stack output nodes | jq -r '.[] | select(.name=="$(1)").sshUser')

.PHONY: help login preview up destroy nodes outputs check-ip add-ip ssh-cp ssh-worker-1 ssh-worker-2 kubeconfig bootstrap platform rebuild

help: ## list available targets
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

login: ## refresh AWS SSO credentials for the Pulumi state backend (run when sessions expire)
	aws sso login --profile $(AWS_PROFILE)

preview: ## show what pulumi would change
	cd $(INFRA_DIR) && $(PULUMI) preview

up: check-ip ## create/update the cluster machines
	cd $(INFRA_DIR) && $(PULUMI) up --yes

destroy: ## tear down the cluster machines (WAL archives live in S3 and survive)
	cd $(INFRA_DIR) && $(PULUMI) destroy --yes

nodes: ## print the node inventory (the provider-agnostic contract)
	@cd $(INFRA_DIR) && $(PULUMI) stack output nodes | jq .

outputs: ## print all stack outputs
	@cd $(INFRA_DIR) && $(PULUMI) stack output

# The firewall only admits myIp for SSH/6443/NodePorts. myIp is a
# comma-separated LIST and this target APPENDS rather than replaces: the
# admin works from two places and the laptop's IP flip-flops, and the
# kubeadm-era replace-on-drift guard re-locked us out mid-bootstrap twice
# (Phase 8 journal). Known addresses are kept; prune by hand with
# `pulumi config set myIp ...` when a location is retired.
check-ip: ## ensure your current public IP is among the admin IPs (auto-runs before `up`)
	@current="$$(curl -sf --max-time 10 https://checkip.amazonaws.com)"; \
	if [ -z "$$current" ]; then echo "check-ip: WARN could not reach checkip.amazonaws.com, skipping"; exit 0; fi; \
	cd $(INFRA_DIR); configured="$$($(PULUMI) config get myIp)"; \
	case ",$$configured," in \
		*",$$current/32,"*) echo "check-ip: $$current already admitted ($$configured)";; \
		*) echo "check-ip: appending $$current/32 to ($$configured)"; \
		   $(PULUMI) config set myIp "$$configured,$$current/32";; \
	esac

add-ip: ## admit another address ahead of time: make add-ip IP=203.0.113.7
	@test -n "$(IP)" || { echo "usage: make add-ip IP=<address>"; exit 1; }
	@cd $(INFRA_DIR); configured="$$($(PULUMI) config get myIp)"; \
	case ",$$configured," in \
		*",$(IP)/32,"*) echo "add-ip: $(IP) already admitted";; \
		*) $(PULUMI) config set myIp "$$configured,$(IP)/32"; echo "add-ip: admitted $(IP) — now run: make up";; \
	esac

bootstrap: ## kubeadm + cilium on the provisioned machines (runbooks 02+03, scripted)
	@cd $(INFRA_DIR) && $(PULUMI) stack output nodes > /tmp/trk-inventory.json
	cluster/bootstrap.sh /tmp/trk-inventory.json $(SSH_KEY)

# platform.sh has no hetzner branch yet (hcloud-csi + token secret +
# storageclass) — it lands after the Phase 9.0 closed-book diff. Until
# then `none` = local-path only.
platform: ## storage/ingress/tls/gitops addons (runbooks 04+05, scripted)
	cluster/platform.sh --provider=none

rebuild: ## the full drill: destroy -> up -> bootstrap -> platform
	$(MAKE) destroy
	$(MAKE) up
	$(MAKE) bootstrap
	$(MAKE) platform

kubeconfig: ## fetch admin kubeconfig from the control plane to ./kubeconfig (gitignored)
	scp -q -i $(SSH_KEY) $(call node_user,k8s-cp-1)@$(call node_ip,k8s-cp-1):.kube/config ./kubeconfig
	sed -i '' "s|https://10.0.1.10:6443|https://$(call node_ip,k8s-cp-1):6443|" ./kubeconfig
	@echo "use with: export KUBECONFIG=$$(pwd)/kubeconfig"

ssh-cp: ## ssh into the control plane
	ssh -i $(SSH_KEY) $(call node_user,k8s-cp-1)@$(call node_ip,k8s-cp-1)

ssh-worker-1: ## ssh into worker 1
	ssh -i $(SSH_KEY) $(call node_user,k8s-worker-1)@$(call node_ip,k8s-worker-1)

ssh-worker-2: ## ssh into worker 2
	ssh -i $(SSH_KEY) $(call node_user,k8s-worker-2)@$(call node_ip,k8s-worker-2)
