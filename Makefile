# kubeadm learning cluster — command shortcuts
# Provider-specific bits are isolated to variables so an infra swap
# (aws → hetzner → on-prem) only changes this header.

INFRA_DIR      := infra/aws
SSH_KEY        := ~/.ssh/aws_k8s
# personal-admin since 2026-07-14: nodes carry an IAM instance profile, so
# pulumi needs iam:PassRole (beyond PowerUserAccess) to touch instances.
AWS_PROFILE    := personal-admin
PULUMI         := PULUMI_CONFIG_PASSPHRASE_FILE=$(HOME)/.config/pulumi/trk-k8s.passphrase pulumi

# node name → public IP, straight from the inventory contract
node_ip = $(shell cd $(INFRA_DIR) && $(PULUMI) stack output nodes | jq -r '.[] | select(.name=="$(1)").publicIp')

.PHONY: help login preview up destroy nodes outputs set-myip ssh-cp ssh-worker-1 ssh-worker-2 kubeconfig

help: ## list available targets
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

login: ## refresh AWS SSO credentials (run when sessions expire)
	aws sso login --profile $(AWS_PROFILE)

preview: ## show what pulumi would change
	cd $(INFRA_DIR) && $(PULUMI) preview

up: ## create/update the cluster machines
	cd $(INFRA_DIR) && $(PULUMI) up --yes

destroy: ## tear everything down (do this when done for the day)
	cd $(INFRA_DIR) && $(PULUMI) destroy --yes

nodes: ## print the node inventory (the provider-agnostic contract)
	@cd $(INFRA_DIR) && $(PULUMI) stack output nodes | jq .

outputs: ## print all stack outputs
	@cd $(INFRA_DIR) && $(PULUMI) stack output

set-myip: ## update the admin IP in stack config (run after your IP changes)
	cd $(INFRA_DIR) && $(PULUMI) config set myIp "$$(curl -s https://checkip.amazonaws.com)/32"
	@echo "now run: make up"

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
