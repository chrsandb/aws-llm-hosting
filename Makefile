SHELL := /bin/bash

TF_DIR ?= terraform
PACKER_DIR ?= packer
TFVARS ?= examples/dev.tfvars
PACKER_VARS ?= backend.example.pkrvars.hcl
TFVARS_ABS := $(abspath $(TFVARS))

define require_cmd
	@command -v $(1) >/dev/null 2>&1 || { echo "Missing required command: $(1). Run ./scripts/install-dependencies-debian-ubuntu.sh or install it manually."; exit 1; }
endef

define validate_tfvars
	@./scripts/validate-terraform-tfvars.sh --tfvars $(TFVARS_ABS)
endef

.PHONY: init plan apply destroy cleanup fmt validate packer-init packer-build

init:
	$(call require_cmd,terraform)
	cd $(TF_DIR) && terraform init

plan:
	$(call require_cmd,terraform)
	$(validate_tfvars)
	cd $(TF_DIR) && terraform plan -var-file=$(TFVARS_ABS)

apply:
	$(call require_cmd,terraform)
	$(validate_tfvars)
	cd $(TF_DIR) && terraform apply -var-file=$(TFVARS_ABS)

destroy:
	$(call require_cmd,terraform)
	$(validate_tfvars)
	cd $(TF_DIR) && terraform destroy -var-file=$(TFVARS_ABS)

cleanup:
	$(call require_cmd,terraform)
	./scripts/cleanup-deployment.sh --tfvars $(TFVARS_ABS)

fmt:
	$(call require_cmd,terraform)
	cd $(TF_DIR) && terraform fmt -recursive
	$(call require_cmd,packer)
	packer fmt $(PACKER_DIR)

validate:
	$(call require_cmd,terraform)
	cd $(TF_DIR) && terraform validate
	$(call require_cmd,packer)
	packer validate -var-file=$(PACKER_DIR)/$(PACKER_VARS) $(PACKER_DIR)/backend-ami.pkr.hcl

packer-init:
	$(call require_cmd,packer)
	packer init $(PACKER_DIR)/backend-ami.pkr.hcl

packer-build:
	$(call require_cmd,packer)
	./scripts/packer-build-with-progress.sh --packer-dir $(PACKER_DIR) --packer-vars $(PACKER_VARS) --template backend-ami.pkr.hcl
