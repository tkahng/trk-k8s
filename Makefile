# kubeadm learning cluster — command shortcuts
# Provider-specific bits are isolated to variables so an infra swap
# (aws → hetzner → on-prem) only changes this header.

INFRA_DIR      := infra/aws
# Data that must outlive the cluster (ADR 008). NEVER destroyed by `destroy`
# or `rebuild` — that's the whole point.
PERSIST_DIR    := infra/aws-persistent
SSH_KEY        := ~/.ssh/aws_k8s
# personal-admin since 2026-07-14: nodes carry an IAM instance profile, so
# pulumi needs iam:PassRole (beyond PowerUserAccess) to touch instances.
AWS_PROFILE    := personal-admin
PULUMI         := PULUMI_CONFIG_PASSPHRASE_FILE=$(HOME)/.config/pulumi/trk-k8s.passphrase pulumi

# node name → public IP, straight from the inventory contract
node_ip = $(shell cd $(INFRA_DIR) && $(PULUMI) stack output nodes | jq -r '.[] | select(.name=="$(1)").publicIp')

.PHONY: help login preview up destroy nodes outputs check-ip set-myip ssh-cp ssh-worker-1 ssh-worker-2 kubeconfig bootstrap platform rebuild persist-up persist-outputs persist-destroy

help: ## list available targets
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

login: ## refresh AWS SSO credentials (run when sessions expire)
	aws sso login --profile $(AWS_PROFILE)

preview: ## show what pulumi would change
	cd $(INFRA_DIR) && $(PULUMI) preview

up: check-ip ## create/update the cluster machines
	cd $(INFRA_DIR) && $(PULUMI) up --yes

destroy: ## tear down the CLUSTER machines (backups survive — see persist-*)
	cd $(INFRA_DIR) && $(PULUMI) destroy --yes

persist-up: ## create/update the persistent data stack (backup bucket + IAM policy). Run once.
	cd $(PERSIST_DIR) && $(PULUMI) stack select --create prod && $(PULUMI) up --yes

persist-outputs: ## show persistent stack outputs (bucket name, policy arn)
	@cd $(PERSIST_DIR) && $(PULUMI) stack select prod && $(PULUMI) stack output

persist-destroy: ## DESTROYS YOUR POSTGRES BACKUPS. Not part of any lab cycle.
	@echo "This deletes the backup bucket and every backup in it (ADR 008)."
	@echo "The bucket has no ForceDestroy, so this FAILS unless you empty it first:"
	@echo "  aws s3 rm s3://trk-k8s-pg-backups --recursive --profile $(AWS_PROFILE)"
	@printf 'Type DELETE-BACKUPS to proceed: ' && read a && [ "$$a" = "DELETE-BACKUPS" ]
	cd $(PERSIST_DIR) && $(PULUMI) destroy --yes

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
	cluster/platform.sh

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
